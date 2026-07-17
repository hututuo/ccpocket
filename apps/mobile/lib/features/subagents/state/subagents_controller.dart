import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../../models/messages.dart'
    show
        BridgeConnectionState,
        LocalFeatureRequestErrorMessage,
        LocalFeatureServerMessage,
        SubagentHistoryMessage,
        SubagentInfo,
        SubagentListMessage,
        requestSubagentHistory,
        requestSubagents;
import '../../../services/bridge_service.dart';

/// Standalone SSOT for the read-only subagent browser.
///
/// It needs only a parent session id and BridgeService, so it works from a
/// workspace sibling pane where no ChatSessionCubit ancestor exists.
class SubagentsController extends ChangeNotifier {
  static const _uuid = Uuid();

  SubagentsController({
    required this.sessionId,
    required this.bridge,
    this.requestTimeout = const Duration(seconds: 12),
  }) {
    _subscription = bridge
        .localFeatureMessagesForSession(sessionId)
        .listen(_onMessage);
    _connectionSubscription = bridge.connectionStatus.listen(
      _onConnectionState,
    );
  }

  final String sessionId;
  final BridgeService bridge;
  final Duration requestTimeout;
  StreamSubscription<LocalFeatureServerMessage>? _subscription;
  StreamSubscription<BridgeConnectionState>? _connectionSubscription;
  String? _listRequestId;
  final Map<String, String> _historyRequestIds = {};
  Timer? _listTimeout;
  final Map<String, Timer> _historyTimeouts = {};
  bool _disposed = false;
  bool _pendingRefresh = false;
  String? _pendingHistoryThreadId;

  List<SubagentInfo> subagents = const [];
  bool listTruncated = false;
  bool listLoading = false;
  String? listError;
  final Map<String, SubagentHistoryMessage> histories = {};
  final Set<String> historyLoadingIds = {};
  final Map<String, String> historyErrors = {};

  bool get _hasInFlight =>
      _listRequestId != null || _historyRequestIds.isNotEmpty;

  void refresh() {
    if (_disposed) return;
    if (!bridge.isConnected) {
      listLoading = false;
      listError = 'bridge_disconnected';
      notifyListeners();
      return;
    }
    if (_hasInFlight) {
      _pendingRefresh = true;
      return;
    }
    final requestId = _uuid.v4();
    _listRequestId = requestId;
    _listTimeout?.cancel();
    listLoading = true;
    listError = null;
    notifyListeners();
    try {
      bridge.send(requestSubagents(sessionId: sessionId, requestId: requestId));
      _listTimeout = Timer(requestTimeout, () {
        if (_listRequestId != requestId) return;
        _listRequestId = null;
        listLoading = false;
        listError = 'unsupported';
        notifyListeners();
        _drainPending();
      });
    } catch (_) {
      if (_listRequestId != requestId) return;
      _listRequestId = null;
      listLoading = false;
      listError = 'bridge_disconnected';
      notifyListeners();
      _drainPending();
    }
  }

  void loadHistory(String threadId) {
    if (_disposed) return;
    final normalized = threadId.trim();
    if (normalized.isEmpty) return;
    if (!bridge.isConnected) {
      historyErrors[normalized] = 'bridge_disconnected';
      notifyListeners();
      return;
    }
    if (_hasInFlight) {
      final previous = _pendingHistoryThreadId;
      if (previous != null && previous != normalized) {
        historyLoadingIds.remove(previous);
      }
      _pendingHistoryThreadId = normalized;
      historyLoadingIds.add(normalized);
      notifyListeners();
      return;
    }
    final requestId = _uuid.v4();
    _historyRequestIds[normalized] = requestId;
    _historyTimeouts.remove(normalized)?.cancel();
    historyLoadingIds.add(normalized);
    historyErrors.remove(normalized);
    notifyListeners();
    try {
      bridge.send(
        requestSubagentHistory(
          sessionId: sessionId,
          threadId: normalized,
          requestId: requestId,
        ),
      );
      _historyTimeouts[normalized] = Timer(requestTimeout, () {
        if (_historyRequestIds[normalized] != requestId) return;
        _historyRequestIds.remove(normalized);
        _historyTimeouts.remove(normalized);
        historyLoadingIds.remove(normalized);
        historyErrors[normalized] = 'unsupported';
        notifyListeners();
        _drainPending();
      });
    } catch (_) {
      if (_historyRequestIds[normalized] != requestId) return;
      _historyRequestIds.remove(normalized);
      historyLoadingIds.remove(normalized);
      historyErrors[normalized] = 'bridge_disconnected';
      notifyListeners();
      _drainPending();
    }
  }

  void _onMessage(LocalFeatureServerMessage message) {
    switch (message) {
      case LocalFeatureRequestErrorMessage():
        if (message.featureId != 'subagents') return;
        final requestId = message.requestId;
        if (message.requestType == 'get_subagents' &&
            requestId != null &&
            requestId == _listRequestId) {
          _listRequestId = null;
          _listTimeout?.cancel();
          listLoading = false;
          listError = 'unsupported';
          notifyListeners();
          _drainPending();
          return;
        }
        if (message.requestType == 'get_subagent_history' &&
            requestId != null) {
          String? threadId;
          for (final entry in _historyRequestIds.entries) {
            if (entry.value == requestId) {
              threadId = entry.key;
              break;
            }
          }
          if (threadId == null) return;
          _historyRequestIds.remove(threadId);
          _historyTimeouts.remove(threadId)?.cancel();
          historyLoadingIds.remove(threadId);
          historyErrors[threadId] = 'unsupported';
          notifyListeners();
          _drainPending();
        }
      case SubagentListMessage():
        if (message.sessionId != sessionId) return;
        final expectedRequestId = _listRequestId;
        if (expectedRequestId == null ||
            message.requestId != expectedRequestId) {
          return;
        }
        _listRequestId = null;
        _listTimeout?.cancel();
        listLoading = false;
        listError = _normalizedError(message.error);
        if (message.error == null) {
          subagents = message.subagents;
          listTruncated = message.truncated;
        }
        notifyListeners();
        _drainPending();
      case SubagentHistoryMessage():
        if (message.sessionId != sessionId) return;
        final threadId = message.threadId;
        if (threadId.isEmpty) return;
        final expected = _historyRequestIds[threadId];
        if (expected == null || message.requestId != expected) {
          return;
        }
        _historyRequestIds.remove(threadId);
        _historyTimeouts.remove(threadId)?.cancel();
        historyLoadingIds.remove(threadId);
        if (message.error == null) {
          histories[threadId] = message;
          historyErrors.remove(threadId);
        } else {
          historyErrors[threadId] = _normalizedError(message.error)!;
        }
        final incoming = message.subagent;
        if (incoming != null) {
          final index = subagents.indexWhere(
            (agent) => agent.threadId == incoming.threadId,
          );
          final next = List<SubagentInfo>.from(subagents);
          if (index < 0) {
            next.add(incoming);
          } else {
            next[index] = incoming;
          }
          subagents = List.unmodifiable(next);
        }
        notifyListeners();
        _drainPending();
      default:
        break;
    }
  }

  void _onConnectionState(BridgeConnectionState state) {
    if (_disposed) return;
    if (state == BridgeConnectionState.connected) {
      refresh();
      return;
    }

    _listTimeout?.cancel();
    _listRequestId = null;
    listLoading = false;
    listError = 'bridge_disconnected';
    for (final timer in _historyTimeouts.values) {
      timer.cancel();
    }
    for (final threadId in _historyRequestIds.keys) {
      historyErrors[threadId] = 'bridge_disconnected';
    }
    _historyTimeouts.clear();
    _historyRequestIds.clear();
    historyLoadingIds.clear();
    _pendingRefresh = false;
    _pendingHistoryThreadId = null;
    notifyListeners();
  }

  void _drainPending() {
    if (_disposed || _hasInFlight || !bridge.isConnected) return;
    final pendingHistory = _pendingHistoryThreadId;
    if (pendingHistory != null) {
      _pendingHistoryThreadId = null;
      loadHistory(pendingHistory);
      return;
    }
    if (_pendingRefresh) {
      _pendingRefresh = false;
      refresh();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _subscription?.cancel();
    _connectionSubscription?.cancel();
    _listTimeout?.cancel();
    for (final timer in _historyTimeouts.values) {
      timer.cancel();
    }
    _historyTimeouts.clear();
    super.dispose();
  }
}

String? _normalizedError(String? error) {
  if (error == null) return null;
  final normalized = error.toLowerCase();
  if (normalized.contains('unsupported') ||
      normalized.contains('invalid message')) {
    return 'unsupported';
  }
  return error;
}
