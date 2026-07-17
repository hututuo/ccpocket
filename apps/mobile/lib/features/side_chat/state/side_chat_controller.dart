import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../../models/messages.dart';
import '../../../services/bridge_service.dart';
import '../../../services/draft_service.dart';
import '../../../widgets/chat_selection_actions.dart';

const int sideChatInputMaxCharacters = sideChatProtocolMaxInputCharacters;
const int sideChatMaxTranscriptEntries = 400;
const int sideChatMaxTranscriptCharacters = 2000000;

enum SideChatLifecycle { closed, opening, open, closing, disconnected, failed }

enum SideChatEntryDelivery { sending, sent, failed }

class SideChatEntry {
  final String id;
  final String role;
  final String text;
  final SideChatEntryDelivery delivery;

  const SideChatEntry({
    required this.id,
    required this.role,
    required this.text,
    this.delivery = SideChatEntryDelivery.sent,
  });

  SideChatEntry copyWith({String? text, SideChatEntryDelivery? delivery}) =>
      SideChatEntry(
        id: id,
        role: role,
        text: text ?? this.text,
        delivery: delivery ?? this.delivery,
      );
}

class _PendingInput {
  final String requestId;
  final String clientMessageId;
  final String text;

  const _PendingInput({
    required this.requestId,
    required this.clientMessageId,
    required this.text,
  });
}

/// Standalone side-chat state machine.
///
/// It consumes only the Bridge local-feature stream, owns a separate draft
/// key, and never writes to ChatSessionCubit or the parent runtime/history.
class SideChatController extends ChangeNotifier {
  SideChatController({
    required this.parentSessionId,
    required this.bridge,
    required this.draftService,
    this.requestTimeout = const Duration(seconds: 12),
    String Function()? createId,
  }) : _createId = createId ?? const Uuid().v4,
       draft = draftService.getDraft(draftKeyFor(parentSessionId)) ?? '' {
    _eventSubscription = bridge
        .localFeatureMessagesForSession(parentSessionId)
        .listen(_onLocalFeatureMessage);
    _connectionSubscription = bridge.connectionStatus.listen(
      _onConnectionState,
    );
  }

  final String parentSessionId;
  final BridgeService bridge;
  final DraftService draftService;
  final Duration requestTimeout;
  final String Function() _createId;

  StreamSubscription<LocalFeatureServerMessage>? _eventSubscription;
  StreamSubscription<BridgeConnectionState>? _connectionSubscription;
  Timer? _openTimer;
  Timer? _closeTimer;
  Timer? _disposeCleanupTimer;
  bool _disposed = false;
  bool _disposeWaitingForOpen = false;
  bool _wantsOpen = false;
  bool _closeAfterOpen = false;
  String? _openRequestId;
  String? _closeRequestId;
  final Map<String, _PendingInput> _pendingInputs = {};
  final Map<String, SideChatPermissionRequest> _permissionResponses = {};
  final Map<String, SideChatQuestionRequest> _questionResponses = {};

  SideChatLifecycle lifecycle = SideChatLifecycle.closed;
  String? sideChatId;
  String? processStatus;
  String? errorCode;
  String? errorMessage;
  String draft;
  List<SideChatEntry> entries = const [];
  SideChatPermissionRequest? pendingPermission;
  SideChatQuestionRequest? pendingQuestion;

  static String draftKeyFor(String parentSessionId) =>
      'sidechat:$parentSessionId';

  bool get canSend =>
      lifecycle == SideChatLifecycle.open &&
      sideChatId != null &&
      draft.trim().isNotEmpty &&
      draft.length <= sideChatInputMaxCharacters;

  bool get isRunning => processStatus == 'running';

  void open() {
    if (_disposed) return;
    _wantsOpen = true;
    if (lifecycle == SideChatLifecycle.open ||
        lifecycle == SideChatLifecycle.opening) {
      return;
    }
    if (lifecycle == SideChatLifecycle.closing) return;
    if (sideChatId != null) {
      lifecycle = SideChatLifecycle.open;
      _notify();
      return;
    }
    _beginOpen();
  }

  void _beginOpen() {
    if (_disposed || !_wantsOpen || _openRequestId != null) return;
    if (!bridge.isConnected) {
      lifecycle = SideChatLifecycle.disconnected;
      errorCode = 'bridge_disconnected';
      errorMessage = null;
      _notify();
      return;
    }
    final requestId = _createId();
    _openRequestId = requestId;
    _closeAfterOpen = false;
    lifecycle = SideChatLifecycle.opening;
    errorCode = null;
    errorMessage = null;
    _notify();
    try {
      bridge.send(
        requestOpenSideChat(
          parentSessionId: parentSessionId,
          requestId: requestId,
        ),
      );
    } catch (_) {
      _failOpen(requestId, 'bridge_disconnected');
      return;
    }
    _openTimer?.cancel();
    _openTimer = Timer(requestTimeout, () {
      _failOpen(requestId, 'open_timeout');
    });
  }

  void _failOpen(String requestId, String code, [String? message]) {
    if (_openRequestId != requestId) return;
    _openRequestId = null;
    _openTimer?.cancel();
    lifecycle = _wantsOpen
        ? SideChatLifecycle.failed
        : SideChatLifecycle.closed;
    errorCode = _wantsOpen ? code : null;
    errorMessage = _wantsOpen ? message : null;
    _notify();
  }

  void close() {
    if (_disposed) return;
    _wantsOpen = false;
    pendingPermission = null;
    pendingQuestion = null;
    if (_openRequestId != null && sideChatId == null) {
      _closeAfterOpen = true;
      lifecycle = SideChatLifecycle.closing;
      _notify();
      return;
    }
    final activeId = sideChatId;
    if (activeId == null || !bridge.isConnected) {
      _finishClosed();
      return;
    }
    if (_closeRequestId == null) _sendClose(activeId);
  }

  void reopen() {
    if (_disposed) return;
    _wantsOpen = true;
    if (lifecycle == SideChatLifecycle.closing) return;
    if (sideChatId != null) {
      lifecycle = SideChatLifecycle.open;
      _notify();
      return;
    }
    _beginOpen();
  }

  void _sendClose(String activeId) {
    final requestId = _createId();
    _closeRequestId = requestId;
    lifecycle = SideChatLifecycle.closing;
    _notify();
    try {
      bridge.send(
        requestCloseSideChat(
          parentSessionId: parentSessionId,
          sideChatId: activeId,
          requestId: requestId,
        ),
      );
    } catch (_) {
      _closeRequestId = null;
      lifecycle = SideChatLifecycle.failed;
      errorCode = 'bridge_disconnected';
      _notify();
      return;
    }
    _closeTimer?.cancel();
    _closeTimer = Timer(requestTimeout, () {
      if (_closeRequestId != requestId) return;
      _closeRequestId = null;
      lifecycle = SideChatLifecycle.failed;
      errorCode = 'close_timeout';
      _notify();
    });
  }

  void updateDraft(String value) {
    if (_disposed || draft == value) return;
    draft = value;
    draftService.saveDraft(draftKeyFor(parentSessionId), draft);
    _notify();
  }

  void prefillSelection(String selectedText) {
    final normalized = normalizeChatSelection(selectedText);
    if (_disposed || normalized.isEmpty) return;
    final quote = normalized
        .split('\n')
        .map((line) => line.isEmpty ? '>' : '> $line')
        .join('\n');
    final next = draft.trim().isEmpty
        ? '$quote\n\n'
        : '${draft.trimRight()}\n\n$quote\n\n';
    updateDraft(next);
  }

  bool sendDraft() {
    if (!canSend || _disposed) return false;
    final activeId = sideChatId!;
    final text = draft.trim();
    final requestId = _createId();
    final clientMessageId = _createId();
    final pending = _PendingInput(
      requestId: requestId,
      clientMessageId: clientMessageId,
      text: draft,
    );
    _pendingInputs[requestId] = pending;
    entries = _boundedEntries([
      ...entries,
      SideChatEntry(
        id: clientMessageId,
        role: 'user',
        text: text,
        delivery: SideChatEntryDelivery.sending,
      ),
    ]);
    errorCode = null;
    errorMessage = null;
    _notify();
    try {
      bridge.send(
        requestSideChatInput(
          parentSessionId: parentSessionId,
          sideChatId: activeId,
          requestId: requestId,
          clientMessageId: clientMessageId,
          text: text,
        ),
      );
      return true;
    } catch (_) {
      _markInputFailed(requestId, 'bridge_disconnected');
      return false;
    }
  }

  void respondPermission(SideChatPermissionDecision decision) {
    final activeId = sideChatId;
    final permission = pendingPermission;
    if (_disposed || activeId == null || permission == null) return;
    final requestId = _createId();
    try {
      bridge.send(
        requestSideChatPermissionResponse(
          parentSessionId: parentSessionId,
          sideChatId: activeId,
          requestId: requestId,
          permissionRequestId: permission.requestId,
          decision: decision,
        ),
      );
      _permissionResponses[requestId] = permission;
      pendingPermission = null;
      _notify();
    } catch (_) {
      errorCode = 'bridge_disconnected';
      _notify();
    }
  }

  void answerQuestion(String questionRequestId, String answer) {
    final activeId = sideChatId;
    final question = pendingQuestion;
    if (_disposed ||
        activeId == null ||
        question == null ||
        question.requestId != questionRequestId ||
        answer.trim().isEmpty) {
      return;
    }
    final requestId = _createId();
    try {
      bridge.send(
        requestSideChatAnswer(
          parentSessionId: parentSessionId,
          sideChatId: activeId,
          requestId: requestId,
          questionRequestId: questionRequestId,
          answer: answer,
        ),
      );
      _questionResponses[requestId] = question;
      pendingQuestion = null;
      _notify();
    } catch (_) {
      errorCode = 'bridge_disconnected';
      _notify();
    }
  }

  void interrupt() {
    final activeId = sideChatId;
    if (_disposed || activeId == null || !bridge.isConnected) return;
    try {
      bridge.send(
        requestSideChatInterrupt(
          parentSessionId: parentSessionId,
          sideChatId: activeId,
          requestId: _createId(),
        ),
      );
    } catch (_) {
      errorCode = 'bridge_disconnected';
      _notify();
    }
  }

  void _onLocalFeatureMessage(LocalFeatureServerMessage message) {
    if (message is SideChatEventMessage) {
      _onEvent(message);
      return;
    }
    if (message is! LocalFeatureRequestErrorMessage ||
        message.featureId != 'side_chat' ||
        message.ownerSessionId != parentSessionId) {
      return;
    }
    final requestId = message.requestId;
    final isCorrelated = switch (message.requestType) {
      'open_side_chat' => requestId != null && requestId == _openRequestId,
      'side_chat_input' =>
        requestId != null && _pendingInputs.containsKey(requestId),
      'side_chat_permission_response' =>
        requestId != null && _permissionResponses.containsKey(requestId),
      'side_chat_answer' =>
        requestId != null && _questionResponses.containsKey(requestId),
      'side_chat_interrupt' => requestId != null && sideChatId != null,
      'close_side_chat' => requestId != null && requestId == _closeRequestId,
      _ => false,
    };
    if (!isCorrelated) return;
    _handleError(
      SideChatEventMessage(
        event: SideChatEventKind.error,
        parentSessionId: parentSessionId,
        sideChatId: sideChatId,
        requestId: requestId,
        error: SideChatErrorPayload(
          code: message.errorCode == 'unsupported_message'
              ? 'bridge_update_required'
              : message.errorCode,
          message: message.message,
        ),
      ),
    );
  }

  void _onEvent(SideChatEventMessage event) {
    if (event.parentSessionId != parentSessionId) return;
    if (_disposed) {
      _handleDisposedEvent(event);
      return;
    }

    if (event.event == SideChatEventKind.opened) {
      _handleOpened(event);
      return;
    }
    if (event.event == SideChatEventKind.error &&
        _openRequestId != null &&
        event.requestId == _openRequestId) {
      _handleError(event);
      return;
    }
    final activeId = sideChatId;
    if (activeId == null || event.sideChatId != activeId) return;

    switch (event.event) {
      case SideChatEventKind.opened:
        break;
      case SideChatEventKind.inputAccepted:
        _handleInputAccepted(event);
      case SideChatEventKind.message:
        _appendServerMessage(event.message!);
      case SideChatEventKind.status:
        _handleStatus(event);
      case SideChatEventKind.permissionRequest:
        pendingPermission = event.permission;
        pendingQuestion = null;
        processStatus = 'waiting_approval';
        _notify();
      case SideChatEventKind.question:
        pendingQuestion = event.question;
        pendingPermission = null;
        processStatus = 'waiting_approval';
        _notify();
      case SideChatEventKind.closed:
        if (_closeRequestId != null &&
            event.requestId != null &&
            event.requestId != _closeRequestId) {
          return;
        }
        _finishClosed();
        if (_wantsOpen) _beginOpen();
      case SideChatEventKind.error:
        _handleError(event);
    }
  }

  void _handleOpened(SideChatEventMessage event) {
    final expectedRequestId = _openRequestId;
    if (expectedRequestId == null || event.requestId != expectedRequestId) {
      return;
    }
    _openTimer?.cancel();
    _openRequestId = null;
    // Every successful open represents a new ephemeral Codex child. Retaining
    // the prior child's transcript would falsely imply that its context was
    // restored across close, exit, or Bridge reconnection.
    entries = const [];
    sideChatId = event.sideChatId;
    processStatus = 'idle';
    errorCode = null;
    errorMessage = null;
    if (_closeAfterOpen || !_wantsOpen) {
      _closeAfterOpen = false;
      _sendClose(sideChatId!);
      return;
    }
    lifecycle = SideChatLifecycle.open;
    _notify();
  }

  void _handleInputAccepted(SideChatEventMessage event) {
    final pending = _pendingInputs[event.requestId];
    if (pending == null || pending.clientMessageId != event.clientMessageId) {
      return;
    }
    if (event.queued) {
      // This acknowledges only that the Bridge accepted the item into its
      // child queue. Keep the local echo and draft pending until the Bridge
      // confirms that it actually reached the Codex child.
      _notify();
      return;
    }
    _pendingInputs.remove(event.requestId);
    _replaceEntryDelivery(pending.clientMessageId, SideChatEntryDelivery.sent);
    if (draft == pending.text) {
      draft = '';
      draftService.deleteDraft(draftKeyFor(parentSessionId));
    }
    _notify();
  }

  void _appendServerMessage(SideChatTranscriptMessage message) {
    final existingIndex = entries.indexWhere((entry) => entry.id == message.id);
    if (existingIndex >= 0) {
      final next = List<SideChatEntry>.from(entries);
      next[existingIndex] = SideChatEntry(
        id: message.id,
        role: message.role,
        text: message.text,
      );
      entries = _boundedEntries(next);
      _notify();
      return;
    }
    entries = _boundedEntries([
      ...entries,
      SideChatEntry(id: message.id, role: message.role, text: message.text),
    ]);
    _notify();
  }

  void _handleStatus(SideChatEventMessage event) {
    processStatus = event.status;
    final requestId = event.requestId;
    if (requestId != null) {
      _permissionResponses.remove(requestId);
      _questionResponses.remove(requestId);
    }
    _notify();
  }

  void _handleError(SideChatEventMessage event) {
    final openRequestId = _openRequestId;
    if (openRequestId != null && event.requestId == openRequestId) {
      _failOpen(
        openRequestId,
        event.error!.code ?? 'open_failed',
        event.error!.message,
      );
      return;
    }
    final requestId = event.requestId;
    if (requestId != null && _pendingInputs.containsKey(requestId)) {
      final pending = _pendingInputs[requestId]!;
      if (event.clientMessageId == null ||
          event.clientMessageId == pending.clientMessageId) {
        _markInputFailed(
          requestId,
          event.error!.code ?? 'input_failed',
          event.error!.message,
        );
      }
      return;
    }
    if (requestId != null) {
      final permission = _permissionResponses.remove(requestId);
      if (permission != null) {
        pendingPermission = permission;
        errorCode = event.error!.code ?? 'permission_response_failed';
        errorMessage = event.error!.message;
        _notify();
        return;
      }
      final question = _questionResponses.remove(requestId);
      if (question != null) {
        pendingQuestion = question;
        errorCode = event.error!.code ?? 'question_response_failed';
        errorMessage = event.error!.message;
        _notify();
        return;
      }
    }
    if (_closeRequestId != null && event.requestId == _closeRequestId) {
      _closeTimer?.cancel();
      _closeRequestId = null;
      lifecycle = SideChatLifecycle.failed;
    }
    errorCode = event.error!.code ?? 'side_chat_error';
    errorMessage = event.error!.message;
    _notify();
  }

  void _markInputFailed(String requestId, String code, [String? message]) {
    final pending = _pendingInputs.remove(requestId);
    if (pending == null) return;
    _replaceEntryDelivery(
      pending.clientMessageId,
      SideChatEntryDelivery.failed,
    );
    errorCode = code;
    errorMessage = message;
    _notify();
  }

  void _replaceEntryDelivery(String id, SideChatEntryDelivery delivery) {
    entries = List.unmodifiable(
      entries.map(
        (entry) => entry.id == id ? entry.copyWith(delivery: delivery) : entry,
      ),
    );
  }

  List<SideChatEntry> _boundedEntries(List<SideChatEntry> next) {
    if (next.isEmpty) return const [];

    final reversed = <SideChatEntry>[];
    var remainingCharacters = sideChatMaxTranscriptCharacters;
    for (
      var index = next.length - 1;
      index >= 0 && reversed.length < sideChatMaxTranscriptEntries;
      index--
    ) {
      final entry = next[index];
      if (entry.text.length <= remainingCharacters) {
        reversed.add(entry);
        remainingCharacters -= entry.text.length;
        continue;
      }
      if (reversed.isEmpty && remainingCharacters > 0) {
        reversed.add(
          entry.copyWith(text: entry.text.substring(0, remainingCharacters)),
        );
      }
      break;
    }
    return List.unmodifiable(reversed.reversed);
  }

  void _finishClosed() {
    _openTimer?.cancel();
    _closeTimer?.cancel();
    _openRequestId = null;
    _closeRequestId = null;
    sideChatId = null;
    processStatus = null;
    pendingPermission = null;
    pendingQuestion = null;
    _permissionResponses.clear();
    _questionResponses.clear();
    lifecycle = SideChatLifecycle.closed;
    _markAllPendingFailed();
    _notify();
  }

  void _markAllPendingFailed() {
    if (_pendingInputs.isEmpty) return;
    final pendingIds = _pendingInputs.values
        .map((pending) => pending.clientMessageId)
        .toSet();
    _pendingInputs.clear();
    entries = List.unmodifiable(
      entries.map(
        (entry) => pendingIds.contains(entry.id)
            ? entry.copyWith(delivery: SideChatEntryDelivery.failed)
            : entry,
      ),
    );
  }

  void _onConnectionState(BridgeConnectionState state) {
    if (_disposed) {
      if (state != BridgeConnectionState.connected) _finishDisposeCleanup();
      return;
    }
    if (state == BridgeConnectionState.connected) {
      if (_wantsOpen && sideChatId == null && _openRequestId == null) {
        _beginOpen();
      }
      return;
    }
    _openTimer?.cancel();
    _closeTimer?.cancel();
    _openRequestId = null;
    _closeRequestId = null;
    sideChatId = null;
    processStatus = null;
    pendingPermission = null;
    pendingQuestion = null;
    _permissionResponses.clear();
    _questionResponses.clear();
    _markAllPendingFailed();
    lifecycle = _wantsOpen
        ? SideChatLifecycle.disconnected
        : SideChatLifecycle.closed;
    errorCode = _wantsOpen ? 'bridge_disconnected' : null;
    errorMessage = null;
    _notify();
  }

  void _handleDisposedEvent(SideChatEventMessage event) {
    if (!_disposeWaitingForOpen ||
        event.event != SideChatEventKind.opened ||
        event.requestId != _openRequestId ||
        event.sideChatId == null) {
      return;
    }
    try {
      bridge.send(
        requestCloseSideChat(
          parentSessionId: parentSessionId,
          sideChatId: event.sideChatId!,
          requestId: _createId(),
        ),
      );
    } catch (_) {
      // The Bridge owns child cleanup on socket loss.
    }
    _finishDisposeCleanup();
  }

  void _finishDisposeCleanup() {
    _disposeCleanupTimer?.cancel();
    _disposeWaitingForOpen = false;
    _eventSubscription?.cancel();
    _eventSubscription = null;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _wantsOpen = false;
    _connectionSubscription?.cancel();
    _connectionSubscription = null;
    _openTimer?.cancel();
    _closeTimer?.cancel();

    final activeId = sideChatId;
    if (activeId != null && _closeRequestId == null && bridge.isConnected) {
      try {
        bridge.send(
          requestCloseSideChat(
            parentSessionId: parentSessionId,
            sideChatId: activeId,
            requestId: _createId(),
          ),
        );
      } catch (_) {
        // The Bridge owns child cleanup on socket loss.
      }
    }

    _disposeWaitingForOpen =
        activeId == null && _openRequestId != null && bridge.isConnected;
    _disposed = true;
    if (_disposeWaitingForOpen) {
      _disposeCleanupTimer = Timer(requestTimeout, _finishDisposeCleanup);
    } else {
      _eventSubscription?.cancel();
      _eventSubscription = null;
    }
    super.dispose();
  }
}
