import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../../core/logger.dart';
import '../../../models/messages.dart';
import '../../../services/bridge_service.dart';
import '../../../services/chat_message_handler.dart';
import 'chat_session_state.dart';
import 'streaming_state_cubit.dart';

/// Manages the state of a single chat session.
///
/// Subscribes to [BridgeService.messagesForSession] and delegates message
/// processing to [ChatMessageHandler]. The resulting [ChatStateUpdate] is
/// applied to the immutable [ChatSessionState].
class ChatSessionCubit extends Cubit<ChatSessionState> {
  static const codexPermissionApplyStrategyCapability =
      'codex_permission_apply_strategy_v1';
  static const _uuid = Uuid();
  static const offlineQueuedInputPrefix = 'offline:';
  static const deliveryPendingQueuedInputPrefix = 'pending:';
  static const _deliveryPendingDelay = Duration(milliseconds: 600);
  static const _goalMutationTimeout = Duration(seconds: 20);
  static const _goalReadTimeout = Duration(seconds: 12);

  final String sessionId;
  final Provider? provider;
  final BridgeService _bridge;
  final StreamingStateCubit _streamingCubit;
  final ChatMessageHandler _handler = ChatMessageHandler();

  StreamSubscription<ServerMessage>? _subscription;
  StreamSubscription<BridgeConnectionState>? _goalConnectionSubscription;
  StreamSubscription<List<SessionInfo>>? _goalSessionListSubscription;
  bool _pastHistoryLoaded = false;
  bool _historyBootstrapSucceeded = false;
  bool _historyFallbackRequested = false;
  Timer? _statusRefreshTimer;
  Timer? _goalMutationTimer;
  Timer? _goalReadTimer;
  bool _goalReadPending = false;
  bool _goalUserRefreshPending = false;
  final Map<String, Timer> _deliveryPendingTimers = {};
  final Map<String, QueuedInputItem> _deliveryPendingInputs = {};

  /// Number of entries prepended from past_history, so that [replaceEntries]
  /// can preserve them while replacing in-memory history entries.
  int _pastEntryCount = 0;

  /// Tool use IDs that have already been answered locally.
  static const _maxRespondedToolUseIds = 512;
  final _respondedToolUseIds = <String>{};
  final Map<String, PermissionRequestMessage> _pendingPermissionRequests = {};

  void _markToolUseResponded(String toolUseId) {
    _bridge.markToolUseResponded(sessionId, toolUseId);
    _respondedToolUseIds.add(toolUseId);
    if (_respondedToolUseIds.length > _maxRespondedToolUseIds) {
      _respondedToolUseIds.remove(_respondedToolUseIds.first);
    }
  }

  PermissionMode? _pendingPermissionRollback;
  ExecutionMode? _pendingExecutionRollback;
  CodexApprovalPolicy? _pendingCodexApprovalRollback;
  String? _pendingCodexApprovalsReviewerRollback;
  CodexPermissionsMode? _pendingCodexPermissionsModeRollback;
  bool? _pendingPlanRollback;
  SandboxMode? _pendingSandboxRollback;
  String? _pendingPermissionChangeId;
  ProcessStatus? _pendingPermissionRestartStatusRollback;
  ApprovalState? _pendingPermissionRestartApprovalRollback;

  /// Whether this session is a Codex session.
  bool get isCodex => provider == Provider.codex;

  bool get isPermissionChangePending => _pendingPermissionChangeId != null;

  bool get isGoalMutationPending => state.goalMutation != null;

  bool get supportsAdvancedGoalControl => state.advancedGoalControlSupported;

  bool get bridgeSupportsCodexPermissionApplyStrategy =>
      _bridge.bridgeCapabilities.contains(
        codexPermissionApplyStrategyCapability,
      );

  bool get supportsCodexPermissionApplyStrategy {
    if (!bridgeSupportsCodexPermissionApplyStrategy) {
      return false;
    }
    return _bridge.sessions.any(
      (session) =>
          session.id == sessionId &&
          session.codexPermissionApplyStrategySupported,
    );
  }

  List<String> get codexModels => _bridge.codexModels;

  Map<String, List<String>> get codexModelReasoningEfforts =>
      _bridge.codexModelReasoningEfforts;

  Map<String, List<String>> get codexModelServiceTiers =>
      _bridge.codexModelServiceTiers;

  String _nextOptimisticCodexUserTurnUuid() {
    final userTurnCount = state.entries.whereType<UserChatEntry>().length;
    return 'codex:user-turn:${userTurnCount + 1}';
  }

  static bool isOfflineQueuedInput(QueuedInputItem? item) =>
      item?.itemId.startsWith(offlineQueuedInputPrefix) ?? false;

  static String? offlineQueuedClientMessageId(QueuedInputItem? item) {
    if (!isOfflineQueuedInput(item)) return null;
    return item!.itemId.substring(offlineQueuedInputPrefix.length);
  }

  static bool isDeliveryPendingQueuedInput(QueuedInputItem? item) =>
      item?.itemId.startsWith(deliveryPendingQueuedInputPrefix) ?? false;

  static String? deliveryPendingClientMessageId(QueuedInputItem? item) {
    if (!isDeliveryPendingQueuedInput(item)) return null;
    return item!.itemId.substring(deliveryPendingQueuedInputPrefix.length);
  }

  ChatSessionCubit({
    required this.sessionId,
    this.provider,
    required BridgeService bridge,
    required StreamingStateCubit streamingCubit,
    String initialExplorerCurrentPath = '',
    List<String> initialRecentPeekedFiles = const [],
    PermissionMode? initialPermissionMode,
    SandboxMode? initialSandboxMode,
    CodexApprovalPolicy? initialCodexApprovalPolicy,
    String? initialCodexApprovalsReviewer,
    CodexPermissionsMode? initialCodexPermissionsMode,
    String? initialProjectPath,
  }) : _bridge = bridge,
       _streamingCubit = streamingCubit,
       super(
         ChatSessionState(
           permissionMode: initialPermissionMode ?? PermissionMode.defaultMode,
           executionMode: deriveExecutionMode(
             provider: provider?.value,
             permissionMode: initialPermissionMode?.value,
           ),
           codexApprovalPolicy: provider == Provider.codex
               ? (initialCodexApprovalPolicy == CodexApprovalPolicy.onFailure
                     ? CodexApprovalPolicy.onRequest
                     : initialCodexApprovalPolicy ??
                           codexApprovalPolicyFromLegacyExecutionMode(
                             deriveExecutionMode(
                               provider: provider?.value,
                               permissionMode: initialPermissionMode?.value,
                             ).value,
                           ))
               : CodexApprovalPolicy.onRequest,
           codexApprovalsReviewer:
               provider == Provider.codex &&
                   isCodexAutoReviewApprovalsReviewer(
                     initialCodexApprovalsReviewer,
                   )
               ? 'auto_review'
               : 'user',
           codexPermissionsMode: provider == Provider.codex
               ? (initialCodexPermissionsMode ??
                     (initialCodexApprovalPolicy != null ||
                             initialSandboxMode != null ||
                             initialCodexApprovalsReviewer != null
                         ? codexPermissionsModeFromSettings(
                             approvalPolicy: initialCodexApprovalPolicy?.value,
                             approvalsReviewer: initialCodexApprovalsReviewer,
                             sandboxMode: initialSandboxMode?.value,
                           )
                         : CodexPermissionsMode.defaultPermissions))
               : CodexPermissionsMode.defaultPermissions,
           planMode: initialPermissionMode == PermissionMode.plan,
           sandboxMode:
               initialSandboxMode ??
               (provider == Provider.codex ? SandboxMode.on : SandboxMode.off),
           inPlanMode: initialPermissionMode == PermissionMode.plan,
           explorerCurrentPath: initialExplorerCurrentPath.trim(),
           recentPeekedFiles: initialRecentPeekedFiles
               .map((file) => file.trim())
               .where((file) => file.isNotEmpty)
               .take(10)
               .toList(),
           projectPath: initialProjectPath,
         ),
       ) {
    _respondedToolUseIds.addAll(_bridge.respondedToolUseIds(sessionId));
    // Subscribe to messages for this session
    _subscription = _bridge.messagesForSession(sessionId).listen(_onMessage);

    if (isCodex) {
      _goalConnectionSubscription = _bridge.connectionStatus.listen(
        _onGoalConnectionState,
      );
      _goalSessionListSubscription = _bridge.sessionList.listen(
        _updateCodexRuntimeSupportFromSessions,
      );
      _updateCodexRuntimeSupportFromSessions(_bridge.sessions);
    }

    _restoreCachedRuntimeMessages();
    _restoreDeliveryPendingInput();
    if (isCodex &&
        _bridge
            .cachedSessionMessages(sessionId)
            .any(
              (message) =>
                  message is SystemMessage && message.subtype == 'init',
            )) {
      requestGoal();
    }

    // Optional local mirrors get the first chance to render a reconstructable
    // snapshot. The unchanged path stays synchronous for official builds.
    if (_bridge.hasSessionHistoryBootstrap) {
      unawaited(_requestInitialHistory());
    } else {
      _bridge.requestSessionHistory(sessionId);
    }

    // Re-query history while status is "starting" to handle lost broadcasts
    _startStatusRefreshTimer();
  }

  void _startStatusRefreshTimer() {
    var mirrorStartingTicks = 0;
    _statusRefreshTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (state.status != ProcessStatus.starting) {
        _statusRefreshTimer?.cancel();
        _statusRefreshTimer = null;
        return;
      }
      if (_historyBootstrapSucceeded && !_historyFallbackRequested) {
        mirrorStartingTicks += 1;
        if (mirrorStartingTicks < 2) return;
        _historyFallbackRequested = true;
      }
      _bridge.requestSessionHistory(sessionId);
    });
  }

  void _onGoalConnectionState(BridgeConnectionState connectionState) {
    if (!isCodex || isClosed) return;
    if (connectionState == BridgeConnectionState.connected) {
      _updateCodexRuntimeSupportFromSessions(_bridge.sessions);
      requestGoal();
      return;
    }
    _failPendingGoalMutation(
      'Goal change was not confirmed because the Bridge disconnected.',
      kind: CodexGoalErrorKind.disconnected,
    );
    _goalReadTimer?.cancel();
    _goalReadTimer = null;
    _goalReadPending = false;
    _goalUserRefreshPending = false;
    if (state.codexNativePlanModeSupport !=
            CodexNativePlanModeSupport.unknown ||
        state.goalSupport != CodexGoalSupport.unknown ||
        state.goalStateLoaded ||
        state.goalLoadErrorKind != CodexGoalErrorKind.disconnected) {
      emit(
        state.copyWith(
          codexNativePlanModeSupport: CodexNativePlanModeSupport.unknown,
          goalSupport: CodexGoalSupport.unknown,
          goalStateLoaded: false,
          advancedGoalControlSupported: false,
          goalOperationSequence: null,
          goalLoadErrorKind: CodexGoalErrorKind.disconnected,
        ),
      );
    }
  }

  void _updateCodexRuntimeSupportFromSessions(List<SessionInfo> sessions) {
    _updateNativePlanModeSupportFromSessions(sessions);
    _updateGoalSupportFromSessions(sessions);
  }

  void _updateNativePlanModeSupportFromSessions(List<SessionInfo> sessions) {
    if (!isCodex || isClosed) return;
    bool? supported;
    for (final session in sessions) {
      if (session.id == sessionId) {
        supported = session.codexNativePlanModeSupported;
        break;
      }
    }
    final next = switch (supported) {
      true => CodexNativePlanModeSupport.supported,
      false => CodexNativePlanModeSupport.unsupported,
      null => CodexNativePlanModeSupport.unknown,
    };
    if (state.codexNativePlanModeSupport != next) {
      emit(state.copyWith(codexNativePlanModeSupport: next));
    }
  }

  void _updateGoalSupportFromSessions(List<SessionInfo> sessions) {
    if (!isCodex || isClosed) return;
    bool? supported;
    for (final session in sessions) {
      if (session.id == sessionId) {
        supported = session.codexGoalControlSupported;
        break;
      }
    }
    if (supported == null) return;
    final next = supported
        ? CodexGoalSupport.supported
        : CodexGoalSupport.unsupported;
    if (state.goalSupport != next ||
        state.advancedGoalControlSupported != supported) {
      emit(
        state.copyWith(
          goalSupport: next,
          advancedGoalControlSupported: supported,
        ),
      );
    }
  }

  Future<void> _requestInitialHistory() async {
    var handled = false;
    try {
      handled = await _bridge.tryBootstrapSessionHistory(
        runtimeSessionId: sessionId,
        provider: provider?.value,
        projectPath: state.projectPath,
      );
    } catch (error, stackTrace) {
      logger.warning(
        '[session:$sessionId] Local history bootstrap failed; using Bridge',
        error,
        stackTrace,
      );
    }
    if (isClosed) return;
    _historyBootstrapSucceeded = handled;
    if (!handled) {
      _historyFallbackRequested = true;
      _bridge.requestSessionHistory(sessionId);
    }
  }

  // ---------------------------------------------------------------------------
  // Message processing
  // ---------------------------------------------------------------------------

  void _restoreCachedRuntimeMessages() {
    final cachedMessages = _bridge.cachedSessionMessages(sessionId);
    if (cachedMessages.isEmpty) return;
    try {
      _replacePendingPermissionsFromHistory(cachedMessages);
      final history = HistoryMessage(messages: cachedMessages);
      final update = _handler.handle(
        history,
        isBackground: true,
        isCodex: isCodex,
        ignoredToolUseIds: _respondedToolUseIds,
      );
      _applyUpdate(update, history);
    } catch (e, st) {
      logger.error(
        '[session:$sessionId] Failed to restore cached runtime messages',
        e,
        st,
      );
    }
  }

  void _restoreDeliveryPendingInput() {
    if (!isCodex || state.queuedInput != null) return;
    final pending = _bridge.deliveryPendingInputForSession(
      sessionId,
      includeHidden: true,
    );
    final clientMessageId = deliveryPendingClientMessageId(pending);
    if (pending != null && clientMessageId != null) {
      _deliveryPendingInputs[clientMessageId] = pending;
    }
    final item = _bridge.deliveryPendingInputForSession(sessionId);
    if (item == null) return;
    emit(state.copyWith(queuedInput: item));
  }

  void _onMessage(ServerMessage msg) {
    if (msg is SystemMessage &&
        msg.subtype == 'set_permission_mode' &&
        _captureSupersededPermissionAcknowledgement(msg)) {
      return;
    }
    // Log errors prominently
    if (msg is ErrorMessage) {
      logger.error('[session:$sessionId] Error from bridge: ${msg.message}');
      _rollbackFailedModeChange(msg);
      if (isCodex && _handleGoalError(msg)) {
        return;
      }
    }
    if (msg is SystemMessage && msg.subtype == 'set_permission_mode') {
      _clearPendingPermissionModeRollback(msg.permissionChangeId);
      final incomingSandbox = switch (msg.sandboxMode) {
        'danger-full-access' || 'off' => SandboxMode.off,
        'workspace-write' || 'read-only' || 'on' => SandboxMode.on,
        _ => null,
      };
      if (incomingSandbox != null && incomingSandbox != state.sandboxMode) {
        emit(state.copyWith(sandboxMode: incomingSandbox));
        _bridge.patchSessionSandboxMode(sessionId, incomingSandbox.value);
      }
    }
    if (isCodex && msg is SystemMessage && msg.subtype == 'init') {
      requestGoal();
    }

    // Prevent duplicate past_history processing
    if (msg is PastHistoryMessage) {
      if (_pastHistoryLoaded) return;
      _pastHistoryLoaded = true;
    }

    // Handle rewind preview separately — store in dedicated state field
    if (msg is RewindPreviewMessage) {
      emit(state.copyWith(rewindPreview: msg));
      return;
    }
    if (msg is GoalStateMessage) {
      _applyGoalState(msg);
      return;
    }
    if (msg is HistoryMessage) {
      _replacePendingPermissionsFromHistory(msg.messages);
    } else if (msg is PermissionRequestMessage &&
        !_respondedToolUseIds.contains(msg.toolUseId)) {
      _pendingPermissionRequests[msg.toolUseId] = msg;
    } else if (msg is StatusMessage &&
        (msg.status == ProcessStatus.idle ||
            msg.status == ProcessStatus.starting)) {
      _pendingPermissionRequests.clear();
    } else if (msg is ResultMessage && msg.subtype == 'stopped') {
      _pendingPermissionRequests.clear();
    }
    if (msg is PermissionResolvedMessage) {
      _pendingPermissionRequests.remove(msg.toolUseId);
      _markToolUseResponded(msg.toolUseId);
      _emitNextApprovalOrNone(msg.toolUseId);
    }

    try {
      final resolvesExitPlan =
          isCodex &&
          msg is ToolResultMessage &&
          _pendingPermissionRequests.containsKey(msg.toolUseId) &&
          _isExitPlanApproval(msg.toolUseId);
      final resolvesPermission =
          isCodex &&
          msg is ToolResultMessage &&
          _pendingPermissionRequests.containsKey(msg.toolUseId);
      final update = _handler.handle(
        msg,
        isBackground: true,
        isCodex: isCodex,
        ignoredToolUseIds: _respondedToolUseIds,
      );
      _applyUpdate(update, msg);
      if (msg is ToolResultMessage && resolvesPermission) {
        _pendingPermissionRequests.remove(msg.toolUseId);
        _markToolUseResponded(msg.toolUseId);
        _emitNextApprovalOrNone(
          msg.toolUseId,
          exitPlanModeResolved: resolvesExitPlan,
        );
      }
    } catch (e, st) {
      logger.error(
        '[session:$sessionId] Failed to handle message: '
        '${msg.runtimeType}',
        e,
        st,
      );
    }
  }

  bool _handleGoalError(ErrorMessage error) {
    final code = error.errorCode;
    final changeId = error.goalChangeId?.trim();
    final isCorrelatedGoalError = changeId != null && changeId.isNotEmpty;
    final isPreGoalBridgeRejection =
        (code == 'unsupported_message' &&
            const {
              'get_goal',
              'set_goal',
              'clear_goal',
            }.contains(error.message)) ||
        (code == null &&
            error.message == 'Invalid message format' &&
            (_goalReadPending || state.goalMutation != null));
    if ((code == null || !code.startsWith('goal_')) &&
        !isCorrelatedGoalError &&
        !isPreGoalBridgeRejection) {
      return false;
    }
    if (error.sessionId != null && error.sessionId != sessionId) return true;

    final isUnsupported =
        isPreGoalBridgeRejection ||
        code == 'goal_get_unsupported' ||
        code == 'goal_set_unsupported' ||
        code == 'goal_clear_unsupported' ||
        code == 'goal_status_unsupported';
    if (isUnsupported) {
      _completeGoalRead();
      final hadPendingMutation = state.goalMutation != null;
      _failPendingGoalMutation(
        error.message,
        kind: CodexGoalErrorKind.unsupported,
      );
      emit(
        state.copyWith(
          goalStateLoaded: true,
          goalSupport: CodexGoalSupport.unsupported,
          advancedGoalControlSupported: false,
          goalLoadErrorKind: null,
          goalMutationError: hadPendingMutation
              ? state.goalMutationError
              : null,
          goalMutationErrorKind: hadPendingMutation
              ? state.goalMutationErrorKind
              : null,
        ),
      );
      return true;
    }
    if (code == 'goal_get_failed') {
      final showError = _goalUserRefreshPending;
      _completeGoalRead();
      emit(
        state.copyWith(
          goalSupport: CodexGoalSupport.unknown,
          goalStateLoaded: false,
          goalLoadErrorKind: CodexGoalErrorKind.readFailed,
          goalMutationError: showError ? error.message : null,
          goalMutationErrorKind: showError
              ? CodexGoalErrorKind.readFailed
              : null,
        ),
      );
      return true;
    }

    final pending = state.goalMutation;
    if (pending != null &&
        changeId != null &&
        changeId.isNotEmpty &&
        changeId != pending.id) {
      return true;
    }
    final conflict = code == 'goal_conflict';
    final errorKind = switch (code) {
      'goal_clear_failed' => CodexGoalErrorKind.clearFailed,
      'goal_set_failed' => CodexGoalErrorKind.updateFailed,
      _ when conflict => CodexGoalErrorKind.conflict,
      _ => CodexGoalErrorKind.updateFailed,
    };
    _failPendingGoalMutation(error.message, kind: errorKind);
    if (conflict) requestGoal();
    return true;
  }

  void _completeGoalRead() {
    _goalReadTimer?.cancel();
    _goalReadTimer = null;
    _goalReadPending = false;
    _goalUserRefreshPending = false;
  }

  void _applyGoalState(GoalStateMessage message) {
    if (message.sessionId != null && message.sessionId != sessionId) return;
    _completeGoalRead();
    final incoming = message.goal;
    final current = state.goal;
    final incomingSequence = message.goalOperationSequence;
    final currentSequence = state.goalOperationSequence;

    final pending = state.goalMutation;
    var acknowledgesPending = false;
    if (pending != null) {
      final changeId = message.goalChangeId?.trim();
      acknowledgesPending = changeId != null && changeId.isNotEmpty
          ? changeId == pending.id
          : incomingSequence == null &&
                _goalStateMatchesMutation(incoming, pending);
    }

    final isStaleSequence =
        incomingSequence != null &&
        currentSequence != null &&
        incomingSequence < currentSequence;
    final isStaleTimestamp =
        incoming != null &&
        current != null &&
        incoming.threadId == current.threadId &&
        incoming.updatedAt < current.updatedAt;
    final isSequenceLessAckAfterAdvance =
        acknowledgesPending &&
        incomingSequence == null &&
        pending?.expectedOperationSequence != null &&
        currentSequence != null &&
        currentSequence > pending!.expectedOperationSequence!;
    if (isStaleSequence || isStaleTimestamp || isSequenceLessAckAfterAdvance) {
      if (acknowledgesPending) {
        _goalMutationTimer?.cancel();
        _goalMutationTimer = null;
        emit(
          state.copyWith(
            goalMutation: null,
            goalMutationError: null,
            goalMutationErrorKind: null,
          ),
        );
      }
      return;
    }

    if (acknowledgesPending) {
      _goalMutationTimer?.cancel();
      _goalMutationTimer = null;
    }

    emit(
      state.copyWith(
        goal: incoming,
        goalStateLoaded: true,
        goalSupport: CodexGoalSupport.supported,
        goalLoadErrorKind: null,
        goalOperationSequence: incomingSequence ?? state.goalOperationSequence,
        goalMutation: acknowledgesPending ? null : state.goalMutation,
        goalMutationError: acknowledgesPending ? null : state.goalMutationError,
        goalMutationErrorKind: acknowledgesPending
            ? null
            : state.goalMutationErrorKind,
      ),
    );
  }

  bool _goalStateMatchesMutation(CodexGoal? goal, CodexGoalMutation mutation) {
    if (mutation.kind == CodexGoalMutationKind.clear) return goal == null;
    if (goal == null) return false;
    if (mutation.objective != null && goal.objective != mutation.objective) {
      return false;
    }
    if (mutation.status != null && goal.status != mutation.status) {
      return false;
    }
    if (mutation.includesTokenBudget &&
        goal.tokenBudget != mutation.tokenBudget) {
      return false;
    }
    return true;
  }

  void _failPendingGoalMutation(String message, {CodexGoalErrorKind? kind}) {
    if (isClosed || state.goalMutation == null) return;
    _goalMutationTimer?.cancel();
    _goalMutationTimer = null;
    emit(
      state.copyWith(
        goalMutation: null,
        goalMutationError: message.trim(),
        goalMutationErrorKind: kind,
      ),
    );
  }

  void clearGoalMutationError() {
    if (state.goalMutationError == null) return;
    emit(state.copyWith(goalMutationError: null, goalMutationErrorKind: null));
  }

  void _applyUpdate(ChatStateUpdate update, ServerMessage originalMsg) {
    final current = state;

    // --- Streaming state (separate cubit) ---
    if (update.resetStreaming) {
      _handler.currentStreaming = null;
      _streamingCubit.reset();
    }

    // Handle stream delta → streaming cubit
    if (originalMsg is StreamDeltaMessage) {
      _streamingCubit.appendText(originalMsg.text);
      return; // No main state update needed for deltas
    }
    if (originalMsg is ThinkingDeltaMessage) {
      _streamingCubit.appendThinking(originalMsg.text);
      return;
    }

    // --- Build new entries list ---
    var entries = current.entries;
    var didModifyEntries = false;

    // When assistant message arrives and streaming was active, reset streaming
    if (originalMsg is AssistantServerMessage &&
        _handler.currentStreaming == null) {
      _streamingCubit.reset();
    }

    // Prepend entries (past history)
    if (update.entriesToPrepend.isNotEmpty) {
      _pastEntryCount += update.entriesToPrepend.length;
      entries = [...update.entriesToPrepend, ...entries];
      didModifyEntries = true;
    }

    // Advance at most one user message status per server event.
    // This keeps FIFO behavior when multiple user messages are queued.
    //
    // - queued ack: first sending -> queued
    // - sent ack / assistant/result: first queued -> sent
    //   (fallback to first sending -> sent for non-queued path)
    if (update.markUserMessagesSent) {
      final targetStatus = update.markUserMessagesQueued
          ? MessageStatus.queued
          : MessageStatus.sent;
      int targetIndex = -1;
      final clientMessageId = update.userStatusClientMessageId;
      if (clientMessageId != null) {
        targetIndex = entries.indexWhere(
          (e) => e is UserChatEntry && e.clientMessageId == clientMessageId,
        );
      } else if (update.markUserMessagesQueued) {
        targetIndex = entries.indexWhere(
          (e) => e is UserChatEntry && e.status == MessageStatus.sending,
        );
      } else {
        targetIndex = entries.indexWhere(
          (e) => e is UserChatEntry && e.status == MessageStatus.queued,
        );
        if (targetIndex == -1) {
          targetIndex = entries.indexWhere(
            (e) => e is UserChatEntry && e.status == MessageStatus.sending,
          );
        }
      }
      if (targetIndex != -1) {
        final entry = entries[targetIndex] as UserChatEntry;
        final updatedEntry = UserChatEntry(
          entry.text,
          sessionId: entry.sessionId,
          clientMessageId: entry.clientMessageId,
          imageBytesList: entry.imageBytesList,
          imageUrls: entry.imageUrls,
          imageCount: entry.imageCount,
          status: targetStatus,
          messageUuid: entry.messageUuid,
          timestamp: entry.timestamp,
        );
        entries = [...entries];
        entries[targetIndex] = updatedEntry;
        didModifyEntries = true;
      }
    }

    // Mark user messages as failed (rejected by bridge)
    if (update.markUserMessagesFailed) {
      var changed = false;
      final clientMessageId = update.userStatusClientMessageId;
      final updated = entries.map((e) {
        if (e is UserChatEntry &&
            (clientMessageId != null
                ? e.clientMessageId == clientMessageId
                : e.status == MessageStatus.sending)) {
          changed = true;
          return UserChatEntry(
            e.text,
            sessionId: e.sessionId,
            clientMessageId: e.clientMessageId,
            imageBytesList: e.imageBytesList,
            imageUrls: e.imageUrls,
            imageCount: e.imageCount,
            status: MessageStatus.failed,
            messageUuid: e.messageUuid,
            timestamp: e.timestamp,
          );
        }
        return e;
      }).toList();
      if (changed) {
        entries = updated;
        didModifyEntries = true;
      }
    }

    // Apply UUID update from SDK echo (makes the user entry rewindable)
    if (update.userUuidUpdate != null) {
      final (
        :text,
        :uuid,
        :clientMessageId,
        :imageCount,
        :imageUrls,
        :timestamp,
      ) = update.userUuidUpdate!;
      var matchedUserEntry = false;
      for (int i = entries.length - 1; i >= 0; i--) {
        final e = entries[i];
        if (e is UserChatEntry &&
            ((e.messageUuid == uuid) ||
                (clientMessageId != null &&
                    e.clientMessageId == clientMessageId) ||
                (e.messageUuid == null &&
                    clientMessageId == null &&
                    e.text == text))) {
          matchedUserEntry = true;
          if (e.messageUuid != uuid) {
            e.messageUuid = uuid;
            didModifyEntries = true;
          }
          break;
        }
      }
      if (!matchedUserEntry) {
        entries = [
          ...entries,
          UserChatEntry(
            text,
            sessionId: sessionId,
            clientMessageId: clientMessageId,
            imageCount: imageCount,
            imageUrls: imageUrls,
            status: MessageStatus.sent,
            messageUuid: uuid,
            timestamp: timestamp == null
                ? null
                : DateTime.tryParse(timestamp)?.toLocal(),
          ),
        ];
        didModifyEntries = true;
      }
    }

    // Add new entries (skip streaming entries — those go to StreamingState)
    final nonStreamingEntries = update.entriesToAdd
        .where((e) => e is! StreamingChatEntry)
        .toList();
    if (update.replaceEntries) {
      // History is a full snapshot — replace all non-past-history entries
      // to prevent duplicates when get_history is received multiple times.
      final pastEntries = entries.take(_pastEntryCount).toList();
      final existingNonPast = entries.skip(_pastEntryCount).toList();
      final mergedHistoryEntries = _mergeRicherLiveAssistantEntries(
        existingEntries: existingNonPast,
        historyEntries: nonStreamingEntries,
      );

      final extraLiveEntries = _entriesToPreserveAfterHistoryReplace(
        existingNonPast: existingNonPast,
        historyEntries: mergedHistoryEntries,
      );

      entries = [...pastEntries, ...mergedHistoryEntries, ...extraLiveEntries];

      // Preserve local data (image bytes, timestamps) from existing entries
      // that the server history does not contain.
      // Match by messageUuid (preferred) or text content (fallback for
      // entries whose UUID hasn't been assigned yet).
      final existingUserData = <String, UserChatEntry>{};
      for (final e in existingNonPast) {
        if (e is UserChatEntry) {
          if (e.messageUuid != null) {
            existingUserData[e.messageUuid!] = e;
          } else {
            existingUserData['text:${e.text}'] = e;
          }
        }
      }
      if (existingUserData.isNotEmpty) {
        for (int i = 0; i < entries.length; i++) {
          final e = entries[i];
          if (e is! UserChatEntry) continue;
          final existing =
              (e.messageUuid != null
                  ? existingUserData[e.messageUuid!]
                  : null) ??
              existingUserData['text:${e.text}'];
          if (existing == null) continue;
          final needsImages =
              e.imageBytesList.isEmpty && existing.imageBytesList.isNotEmpty;
          final needsTimestamp = existing.timestamp != e.timestamp;
          if (needsImages || needsTimestamp) {
            entries[i] = UserChatEntry(
              e.text,
              sessionId: e.sessionId,
              clientMessageId: e.clientMessageId,
              imageBytesList: needsImages
                  ? existing.imageBytesList
                  : e.imageBytesList,
              imageUrls: e.imageUrls,
              imageCount: e.imageCount,
              status: e.status,
              messageUuid: e.messageUuid,
              timestamp: existing.timestamp,
            );
          }
        }
      }

      didModifyEntries = true;
    } else if (nonStreamingEntries.isNotEmpty) {
      final result = _appendEntriesDeduped(entries, nonStreamingEntries);
      entries = result.entries;
      didModifyEntries = result.didChange;
    }

    // --- Build new approval state ---
    ApprovalState approval = current.approval;
    if (update.resetPending && update.resetAsk) {
      approval = const ApprovalState.none();
    } else if (update.resetPending) {
      if (approval is ApprovalPermission) {
        approval = const ApprovalState.none();
      }
    } else if (update.resetAsk) {
      if (approval is ApprovalAskUser) {
        approval = const ApprovalState.none();
      }
    }

    if (update.pendingPermission != null) {
      final toolUseId = update.pendingToolUseId;
      if (toolUseId != null && !_respondedToolUseIds.contains(toolUseId)) {
        approval = ApprovalState.permission(
          toolUseId: toolUseId,
          request: update.pendingPermission!,
        );
      }
    }
    if (update.askToolUseId != null) {
      final toolUseId = update.askToolUseId!;
      if (!_respondedToolUseIds.contains(toolUseId)) {
        approval = ApprovalState.askUser(
          toolUseId: toolUseId,
          input: update.askInput ?? {},
        );
      }
    }

    // Stop status refresh timer when status changes from starting
    if (update.status != null && update.status != ProcessStatus.starting) {
      _statusRefreshTimer?.cancel();
      _statusRefreshTimer = null;
    }

    // --- Update hidden tool use IDs (for subagent summary compression) ---
    var hiddenToolUseIds = current.hiddenToolUseIds;
    if (update.toolUseIdsToHide.isNotEmpty) {
      hiddenToolUseIds = {...hiddenToolUseIds, ...update.toolUseIdsToHide};
    }

    var nextEntries = didModifyEntries ? entries : current.entries;

    // --- Apply state update ---
    final newClaudeSessionId =
        update.claudeSessionId ?? current.claudeSessionId;
    final newProjectPath = update.projectPath?.trim().isNotEmpty == true
        ? update.projectPath
        : current.projectPath;
    if (originalMsg
        case InputAckMessage(:final clientMessageId) ||
            InputRejectedMessage(:final clientMessageId)
        when clientMessageId != null) {
      _deliveryPendingTimers.remove(clientMessageId)?.cancel();
      _bridge.clearDeliveryPendingInput(
        sessionId,
        itemId: '$deliveryPendingQueuedInputPrefix$clientMessageId',
      );
    } else if (update.markUserMessagesSent) {
      for (final timer in _deliveryPendingTimers.values) {
        timer.cancel();
      }
      _deliveryPendingTimers.clear();
      _bridge.clearDeliveryPendingInput(sessionId);
    }

    var nextQueuedInput = update.clearQueuedInput
        ? null
        : (update.queuedInput ?? current.queuedInput);
    QueuedInputItem? deliveredPendingInput;
    String? deliveredPendingClientMessageId;
    if (originalMsg is InputAckMessage && originalMsg.queued == false) {
      final hiddenDeliveryPending = originalMsg.clientMessageId != null
          ? _deliveryPendingInputs.remove(originalMsg.clientMessageId)
          : null;
      final offlineMatch =
          offlineQueuedClientMessageId(nextQueuedInput) ==
          originalMsg.clientMessageId;
      final deliveryMatch =
          deliveryPendingClientMessageId(nextQueuedInput) ==
          originalMsg.clientMessageId;
      if (deliveryMatch) {
        deliveredPendingInput = nextQueuedInput;
        deliveredPendingClientMessageId = originalMsg.clientMessageId;
        if (originalMsg.clientMessageId != null) {
          _deliveryPendingInputs.remove(originalMsg.clientMessageId);
        }
      } else if (hiddenDeliveryPending != null) {
        deliveredPendingInput = hiddenDeliveryPending;
        deliveredPendingClientMessageId = originalMsg.clientMessageId;
      }
      if (offlineMatch || deliveryMatch) {
        nextQueuedInput = null;
      }
    }
    if (originalMsg is InputRejectedMessage) {
      if (originalMsg.clientMessageId != null) {
        _deliveryPendingInputs.remove(originalMsg.clientMessageId);
      }
      if (deliveryPendingClientMessageId(nextQueuedInput) ==
          originalMsg.clientMessageId) {
        nextQueuedInput = null;
      }
    }
    if (originalMsg is InputAckMessage && originalMsg.queued == true) {
      if (originalMsg.clientMessageId != null) {
        _deliveryPendingInputs.remove(originalMsg.clientMessageId);
      }
    }
    if (originalMsg is! InputAckMessage &&
        update.markUserMessagesSent &&
        isDeliveryPendingQueuedInput(nextQueuedInput)) {
      deliveredPendingInput = nextQueuedInput;
      deliveredPendingClientMessageId = deliveryPendingClientMessageId(
        nextQueuedInput,
      );
      nextQueuedInput = null;
      if (deliveredPendingClientMessageId != null) {
        _deliveryPendingInputs.remove(deliveredPendingClientMessageId);
      }
    } else if (originalMsg is! InputAckMessage &&
        update.markUserMessagesSent &&
        _deliveryPendingInputs.isNotEmpty) {
      final entry = _deliveryPendingInputs.entries.first;
      _deliveryPendingInputs.remove(entry.key);
      deliveredPendingInput = entry.value;
      deliveredPendingClientMessageId = entry.key;
    }
    if (deliveredPendingInput != null) {
      nextEntries = _appendDeliveredPendingInputEntry(
        nextEntries,
        deliveredPendingInput,
        deliveredPendingClientMessageId,
        beforeTrailingAssistant: originalMsg is AssistantServerMessage,
      );
    }
    if (isDeliveryPendingQueuedInput(current.queuedInput) &&
        current.queuedInput?.itemId != nextQueuedInput?.itemId) {
      _bridge.clearDeliveryPendingInput(
        sessionId,
        itemId: current.queuedInput!.itemId,
      );
    }
    final usage = _calculateUsageTotals(nextEntries);

    emit(
      current.copyWith(
        status: update.status ?? current.status,
        entries: nextEntries,
        approval: approval,
        totalCost: usage.totalCost,
        totalDuration: usage.totalDuration,
        inPlanMode: update.inPlanMode ?? current.inPlanMode,
        permissionMode: update.permissionMode ?? current.permissionMode,
        executionMode: update.executionMode ?? current.executionMode,
        codexApprovalPolicy:
            update.codexApprovalPolicy ?? current.codexApprovalPolicy,
        codexApprovalsReviewer:
            update.codexApprovalsReviewer ?? current.codexApprovalsReviewer,
        codexPermissionsMode:
            update.codexPermissionsMode ?? current.codexPermissionsMode,
        codexModel: update.codexModel ?? current.codexModel,
        codexModelReasoningEffort:
            update.codexModelReasoningEffort ??
            current.codexModelReasoningEffort,
        codexSpeed: update.codexSpeed ?? current.codexSpeed,
        planMode: update.planMode ?? current.planMode,
        slashCommands: update.slashCommands ?? current.slashCommands,
        queuedInput: nextQueuedInput,
        claudeSessionId: newClaudeSessionId,
        projectPath: newProjectPath,
        hiddenToolUseIds: hiddenToolUseIds,
      ),
    );

    // Persist initial Claude settings when claudeSessionId is first known.
    if (update.claudeSessionId != null &&
        current.claudeSessionId == null &&
        provider != Provider.codex) {
      unawaited(
        _SessionSettingsHelper.save(update.claudeSessionId!, {
          'permissionMode': current.permissionMode.value,
          'sandboxMode': current.sandboxMode.value,
        }),
      );
    }

    // --- Fire side effects ---
    if (update.sideEffects.isNotEmpty) {
      _sideEffectsController.add(update.sideEffects);
    }
  }

  _UsageTotals _calculateUsageTotals(List<ChatEntry> entries) {
    double totalCost = 0;
    double durationMs = 0;
    var hasDuration = false;

    for (final entry in entries) {
      if (entry is! ServerChatEntry) continue;
      final msg = entry.message;
      if (msg is! ResultMessage) continue;

      if (msg.cost != null) {
        totalCost += msg.cost!;
      }
      if (msg.duration != null && msg.duration! >= 0) {
        durationMs += msg.duration!;
        hasDuration = true;
      }
    }

    return _UsageTotals(
      totalCost: totalCost,
      totalDuration: hasDuration
          ? Duration(milliseconds: durationMs.round())
          : null,
    );
  }

  List<ChatEntry> _entriesToPreserveAfterHistoryReplace({
    required List<ChatEntry> existingNonPast,
    required List<ChatEntry> historyEntries,
  }) {
    final lastUserIndex = existingNonPast.lastIndexWhere(
      (entry) => entry is UserChatEntry,
    );
    final candidates = existingNonPast.skip(
      lastUserIndex == -1 ? 0 : lastUserIndex,
    );
    final preserved = <ChatEntry>[];
    final historyCurrentUserIndex = lastUserIndex == -1
        ? -1
        : historyEntries.lastIndexWhere(
            (entry) => _entriesEquivalentForTurnBoundary(
              entry,
              existingNonPast[lastUserIndex],
            ),
          );
    final covered = lastUserIndex == -1
        ? [...historyEntries]
        : historyCurrentUserIndex == -1
        ? <ChatEntry>[]
        : historyEntries.skip(historyCurrentUserIndex).toList();

    for (final candidate in candidates) {
      if (_indexOfEquivalentEntry(covered, candidate, allowWeakMatch: true) !=
          -1) {
        continue;
      }
      if (!_shouldPreserveEntryAcrossHistoryReplace(candidate)) continue;
      preserved.add(candidate);
      covered.add(candidate);
    }
    return preserved;
  }

  bool _entriesEquivalentForTurnBoundary(ChatEntry a, ChatEntry b) {
    if (a is UserChatEntry && b is UserChatEntry) {
      final aUuid = a.messageUuid;
      final bUuid = b.messageUuid;
      if (aUuid?.isNotEmpty == true && bUuid?.isNotEmpty == true) {
        return aUuid == bUuid;
      }
      final aClientId = a.clientMessageId;
      final bClientId = b.clientMessageId;
      if (aClientId?.isNotEmpty == true && bClientId?.isNotEmpty == true) {
        return aClientId == bClientId;
      }
      return _entriesEquivalent(a, b, allowWeakMatch: true);
    }
    final aKey = _entryStableKey(a);
    final bKey = _entryStableKey(b);
    if (aKey != null && bKey != null) return aKey == bKey;
    return _entriesEquivalent(a, b, allowWeakMatch: true);
  }

  List<ChatEntry> _mergeRicherLiveAssistantEntries({
    required List<ChatEntry> existingEntries,
    required List<ChatEntry> historyEntries,
  }) {
    return historyEntries.map((historyEntry) {
      final historyAssistant = _assistantMessageFromEntry(historyEntry);
      if (historyAssistant == null) return historyEntry;

      final existingIndex = _indexOfEquivalentEntry(
        existingEntries,
        historyEntry,
      );
      if (existingIndex == -1) return historyEntry;
      final existingEntry = existingEntries[existingIndex];
      final existingAssistant = _assistantMessageFromEntry(existingEntry);
      if (existingAssistant == null) return historyEntry;

      return _hasRenderableAssistantContent(existingAssistant) &&
              !_hasRenderableAssistantContent(historyAssistant)
          ? existingEntry
          : historyEntry;
    }).toList();
  }

  AssistantMessage? _assistantMessageFromEntry(ChatEntry entry) {
    if (entry case ServerChatEntry(
      message: AssistantServerMessage(:final message),
    )) {
      return message;
    }
    return null;
  }

  bool _hasRenderableAssistantContent(AssistantMessage message) {
    return message.content.any(
      (content) => switch (content) {
        TextContent(:final text) => text.trim().isNotEmpty,
        ThinkingContent(:final thinking) => thinking.trim().isNotEmpty,
        ToolUseContent() => true,
      },
    );
  }

  ({List<ChatEntry> entries, bool didChange}) _appendEntriesDeduped(
    List<ChatEntry> current,
    List<ChatEntry> additions,
  ) {
    var next = current;
    var didChange = false;

    for (final addition in additions) {
      var matchIndex = _indexOfEquivalentEntry(next, addition);
      if (matchIndex == -1 && _canWeakMatchAppendedEntry(addition)) {
        final lastUserIndex = next.lastIndexWhere((e) => e is UserChatEntry);
        matchIndex = _indexOfEquivalentEntry(
          next,
          addition,
          start: lastUserIndex + 1,
          allowWeakMatch: true,
        );
      }
      if (matchIndex != -1) {
        final merged = _mergeEquivalentEntry(next[matchIndex], addition);
        if (!identical(merged, next[matchIndex])) {
          next = [...next];
          next[matchIndex] = merged;
          didChange = true;
        }
        continue;
      }
      if (!didChange) next = [...next];
      next.add(addition);
      didChange = true;
    }

    return (entries: next, didChange: didChange);
  }

  bool _canWeakMatchAppendedEntry(ChatEntry entry) {
    if (entry case ServerChatEntry(
      message: AssistantServerMessage(:final messageUuid),
    )) {
      return messageUuid?.isNotEmpty == true;
    }
    return entry is ServerChatEntry && entry.message is ResultMessage;
  }

  int _indexOfEquivalentEntry(
    List<ChatEntry> entries,
    ChatEntry target, {
    int start = 0,
    bool allowWeakMatch = false,
  }) {
    for (var i = start; i < entries.length; i++) {
      if (_entriesEquivalent(
        entries[i],
        target,
        allowWeakMatch: allowWeakMatch,
      )) {
        return i;
      }
    }
    return -1;
  }

  bool _entriesEquivalent(
    ChatEntry a,
    ChatEntry b, {
    bool allowWeakMatch = false,
  }) {
    if (a is ServerChatEntry && b is ServerChatEntry) {
      final aMessage = a.message;
      final bMessage = b.message;
      if (aMessage is AssistantServerMessage &&
          bMessage is AssistantServerMessage) {
        final aId = aMessage.message.id;
        final bId = bMessage.message.id;
        if (aId.isNotEmpty && bId.isNotEmpty && aId == bId) return true;
        final aUuid = aMessage.messageUuid;
        final bUuid = bMessage.messageUuid;
        if (aUuid != null &&
            aUuid.isNotEmpty &&
            bUuid != null &&
            aUuid == bUuid) {
          return true;
        }
      }
    }
    final aKey = _entryStableKey(a);
    final bKey = _entryStableKey(b);
    if (aKey != null && bKey != null && aKey == bKey) return true;

    if (allowWeakMatch) {
      final aWeakKey = _entryWeakKey(a);
      final bWeakKey = _entryWeakKey(b);
      if (aWeakKey != null && bWeakKey != null) return aWeakKey == bWeakKey;
    }

    if (aKey != null && bKey != null) return false;

    if (a is UserChatEntry && b is UserChatEntry) {
      // Older Bridge versions may not include clientMessageId in restored
      // history. Use text only as a last-resort match for local pending entries.
      return (a.status != MessageStatus.sent ||
              b.status != MessageStatus.sent) &&
          a.text == b.text &&
          a.imageCount == b.imageCount;
    }
    return false;
  }

  String? _entryStableKey(ChatEntry entry) {
    if (entry is UserChatEntry) {
      final uuid = entry.messageUuid;
      if (uuid != null && uuid.isNotEmpty) return 'user:uuid:$uuid';
      final clientMessageId = entry.clientMessageId;
      if (clientMessageId != null && clientMessageId.isNotEmpty) {
        return 'user:client:$clientMessageId';
      }
      return null;
    }
    if (entry is ServerChatEntry) {
      return _serverMessageStableKey(entry.message);
    }
    return null;
  }

  String? _entryWeakKey(ChatEntry entry) {
    if (entry is UserChatEntry) {
      return ['user', entry.text, entry.imageCount].join('\u0001');
    }
    if (entry is ServerChatEntry) {
      return _serverMessageWeakKey(entry.message);
    }
    return null;
  }

  String? _serverMessageStableKey(ServerMessage message) {
    switch (message) {
      case AssistantServerMessage(:final messageUuid, :final message):
        if (messageUuid != null && messageUuid.isNotEmpty) {
          return 'assistant:uuid:$messageUuid';
        }
        if (message.id.isNotEmpty) return 'assistant:id:${message.id}';
        return null;
      case ToolResultMessage(:final toolUseId):
        return 'tool_result:$toolUseId';
      case PermissionRequestMessage(:final toolUseId):
        return 'permission_request:$toolUseId';
      case PermissionResolvedMessage(:final toolUseId):
        return 'permission_resolved:$toolUseId';
      default:
        return null;
    }
  }

  String? _serverMessageWeakKey(ServerMessage message) {
    switch (message) {
      case SystemMessage(
        :final subtype,
        :final sessionId,
        :final claudeSessionId,
        :final provider,
        :final projectPath,
        :final permissionMode,
        :final executionMode,
        :final approvalPolicy,
        :final approvalsReviewer,
        :final codexPermissionsMode,
        :final sandboxMode,
        :final model,
        :final modelReasoningEffort,
        :final sourceSessionId,
        :final tipCode,
      ):
        return [
          'system',
          subtype,
          sessionId,
          claudeSessionId,
          provider,
          projectPath,
          permissionMode,
          executionMode,
          approvalPolicy,
          approvalsReviewer,
          codexPermissionsMode,
          sandboxMode,
          model,
          modelReasoningEffort,
          sourceSessionId,
          tipCode,
        ].join('\u0001');
      case AssistantServerMessage(:final message):
        return 'assistant:content:${_assistantContentSignature(message)}';
      case ResultMessage(
        :final subtype,
        :final stopReason,
        :final result,
        :final error,
      ):
        return ['result', subtype, stopReason, result, error].join('\u0001');
      case ErrorMessage(:final message, :final errorCode):
        return ['error', errorCode, message].join('\u0001');
      case ToolUseSummaryMessage(:final summary, :final precedingToolUseIds):
        return [
          'tool_use_summary',
          summary,
          ...precedingToolUseIds,
        ].join('\u0001');
      default:
        return null;
    }
  }

  String _assistantContentSignature(AssistantMessage message) {
    return message.content
        .map((content) {
          return switch (content) {
            TextContent(:final text) => 'text:$text',
            ThinkingContent(:final thinking) => 'thinking:$thinking',
            ToolUseContent(:final id, :final name) => 'tool_use:$id:$name',
          };
        })
        .join('\u0001');
  }

  bool _shouldPreserveEntryAcrossHistoryReplace(ChatEntry entry) {
    if (entry is UserChatEntry) return true;
    if (entry is ServerChatEntry) {
      return entry.message is! StatusMessage &&
          entry.message is! InputAckMessage &&
          entry.message is! InputRejectedMessage &&
          entry.message is! ConversationQueueMessage;
    }
    return false;
  }

  ChatEntry _mergeEquivalentEntry(ChatEntry existing, ChatEntry incoming) {
    if (existing is UserChatEntry && incoming is UserChatEntry) {
      final imageBytes = existing.imageBytesList.isNotEmpty
          ? existing.imageBytesList
          : incoming.imageBytesList;
      final imageUrls = incoming.imageUrls.isNotEmpty
          ? incoming.imageUrls
          : existing.imageUrls;
      final imageCount = incoming.imageCount > 0
          ? incoming.imageCount
          : existing.imageCount;
      return UserChatEntry(
        existing.text.isNotEmpty ? existing.text : incoming.text,
        sessionId: existing.sessionId ?? incoming.sessionId,
        clientMessageId: existing.clientMessageId ?? incoming.clientMessageId,
        imageBytesList: imageBytes,
        imageUrls: imageUrls,
        imageCount: imageCount,
        status: incoming.status == MessageStatus.sent
            ? MessageStatus.sent
            : existing.status,
        messageUuid: existing.messageUuid ?? incoming.messageUuid,
        timestamp: existing.timestamp,
      );
    }
    if (existing is ServerChatEntry && incoming is ServerChatEntry) {
      final existingMessage = existing.message;
      final incomingMessage = incoming.message;
      if (existingMessage is AssistantServerMessage &&
          incomingMessage is AssistantServerMessage) {
        final existingContent = existingMessage.message.content;
        final incomingContent = incomingMessage.message.content;
        final existingOwner = existingMessage.artifactMessageId;
        final incomingOwner = incomingMessage.artifactMessageId;
        final sameArtifactOwner =
            existingOwner.isNotEmpty && existingOwner == incomingOwner;
        var useIncomingContent = _assistantContentWeight(incomingContent) >=
            _assistantContentWeight(existingContent);
        var mergedId = incomingMessage.message.id.isNotEmpty
            ? incomingMessage.message.id
            : existingMessage.message.id;
        var mergedUuid =
            incomingMessage.messageUuid ?? existingMessage.messageUuid;
        late final List<ArtifactRef> artifacts;
        if (sameArtifactOwner) {
          artifacts = _mergeArtifacts(
            existingMessage.artifacts,
            incomingMessage.artifacts,
          );
        } else if (incomingMessage.artifacts.isNotEmpty) {
          // Artifact authorization is bound to one owner message key. Never
          // union refs from a UUID-equivalent message with a different id.
          artifacts = incomingMessage.artifacts;
          mergedId = incomingMessage.message.id;
          mergedUuid = incomingMessage.messageUuid;
          useIncomingContent = true;
        } else if (existingMessage.artifacts.isNotEmpty) {
          artifacts = existingMessage.artifacts;
          mergedId = existingMessage.message.id;
          mergedUuid = existingMessage.messageUuid;
          useIncomingContent = false;
        } else {
          artifacts = const [];
        }
        final content = useIncomingContent ? incomingContent : existingContent;
        return ServerChatEntry(
          AssistantServerMessage(
            message: AssistantMessage(
              id: mergedId,
              role: incomingMessage.message.role.isNotEmpty
                  ? incomingMessage.message.role
                  : existingMessage.message.role,
              content: content,
              model: incomingMessage.message.model.isNotEmpty
                  ? incomingMessage.message.model
                  : existingMessage.message.model,
            ),
            messageUuid: mergedUuid,
            artifacts: artifacts,
            artifactContentIndexOffset: useIncomingContent
                ? incomingMessage.artifactContentIndexOffset
                : existingMessage.artifactContentIndexOffset,
          ),
          timestamp: existing.timestamp,
        );
      }
      if (existingMessage is ToolResultMessage &&
          incomingMessage is ToolResultMessage) {
        return ServerChatEntry(
          ToolResultMessage(
            toolUseId: incomingMessage.toolUseId,
            content: incomingMessage.content.length >=
                    existingMessage.content.length
                ? incomingMessage.content
                : existingMessage.content,
            toolName: incomingMessage.toolName ?? existingMessage.toolName,
            images: _mergeImages(
              existingMessage.images,
              incomingMessage.images,
            ),
            userMessageUuid: incomingMessage.userMessageUuid ??
                existingMessage.userMessageUuid,
            artifacts: _mergeArtifacts(
              existingMessage.artifacts,
              incomingMessage.artifacts,
            ),
          ),
          timestamp: existing.timestamp,
        );
      }
    }
    return existing;
  }

  int _assistantContentWeight(List<AssistantContent> content) {
    return content.fold<int>(0, (total, item) {
      final weight = switch (item) {
        TextContent(:final text) => text.length,
        ThinkingContent(:final thinking) => thinking.length,
        ToolUseContent(:final input) => input.toString().length + 1,
      };
      return total + weight;
    });
  }

  List<ArtifactRef> _mergeArtifacts(
    List<ArtifactRef> existing,
    List<ArtifactRef> incoming,
  ) {
    final merged = List<ArtifactRef>.from(existing);
    for (final artifact in incoming) {
      var index = merged.indexWhere((item) => item.id == artifact.id);
      final semanticKey = _markdownArtifactSemanticKey(artifact);
      if (index < 0 && semanticKey != null) {
        index = merged.indexWhere(
          (item) => _markdownArtifactSemanticKey(item) == semanticKey,
        );
      }
      if (index >= 0) {
        // The latest Bridge descriptor is authoritative after registry
        // retention, eviction, or recovery assigns a replacement opaque id.
        merged[index] = artifact;
      } else {
        merged.add(artifact);
      }
    }
    return List<ArtifactRef>.unmodifiable(merged);
  }

  String? _markdownArtifactSemanticKey(ArtifactRef artifact) {
    final originalHref = artifact.originalHref;
    if (originalHref == null) return null;
    return [
      artifact.source,
      artifact.kind,
      artifact.textContentIndex ?? -1,
      originalHref,
      artifact.projectRelativePath ?? '',
      artifact.line ?? -1,
      artifact.column ?? -1,
    ].join('\u0000');
  }

  List<ImageRef> _mergeImages(
    List<ImageRef> existing,
    List<ImageRef> incoming,
  ) {
    final merged = <String, ImageRef>{
      for (final image in existing) image.id: image,
      for (final image in incoming) image.id: image,
    };
    return merged.values.toList(growable: false);
  }

  List<ChatEntry> _appendDeliveredPendingInputEntry(
    List<ChatEntry> entries,
    QueuedInputItem? item,
    String? clientMessageId, {
    bool beforeTrailingAssistant = false,
  }) {
    if (item == null) return entries;
    final alreadyVisible = entries.any((entry) {
      if (entry is! UserChatEntry) return false;
      if (clientMessageId != null && entry.clientMessageId == clientMessageId) {
        return true;
      }
      return entry.text == item.text && entry.status == MessageStatus.sent;
    });
    if (alreadyVisible) return entries;
    final entry = UserChatEntry(
      item.text,
      sessionId: sessionId,
      clientMessageId: clientMessageId,
      imageCount: item.imageCount,
      status: MessageStatus.sent,
    );
    final trailingEntry = entries.lastOrNull;
    if (beforeTrailingAssistant &&
        trailingEntry is ServerChatEntry &&
        trailingEntry.message is AssistantServerMessage) {
      return [...entries.take(entries.length - 1), entry, entries.last];
    }
    return [...entries, entry];
  }

  // ---------------------------------------------------------------------------
  // Side effects stream
  // ---------------------------------------------------------------------------

  final _sideEffectsController =
      StreamController<Set<ChatSideEffect>>.broadcast();

  /// Stream of side effects that the UI layer must execute (haptics, etc.).
  Stream<Set<ChatSideEffect>> get sideEffects => _sideEffectsController.stream;

  void setExplorerCurrentPath(String path) {
    final normalized = path.trim();
    if (normalized == state.explorerCurrentPath) return;
    emit(state.copyWith(explorerCurrentPath: normalized));
  }

  void setRecentPeekedFiles(List<String> files) {
    final normalized = files
        .map((file) => file.trim())
        .where((file) => file.isNotEmpty)
        .take(10)
        .toList();
    if (_listEquals(normalized, state.recentPeekedFiles)) return;
    emit(state.copyWith(recentPeekedFiles: normalized));
  }

  void recordPeekedFile(String path) {
    final next = updateRecentPeekedFiles(state.recentPeekedFiles, path);
    if (_listEquals(next, state.recentPeekedFiles)) return;
    emit(state.copyWith(recentPeekedFiles: next));
  }

  // ---------------------------------------------------------------------------
  // Commands (Path B: UI → Cubit → Bridge)
  // ---------------------------------------------------------------------------

  /// Send a user message, optionally with image attachments.
  void sendMessage(
    String text, {
    List<({Uint8List bytes, String mimeType})>? images,
    Iterable<String>? mentionablePaths,
  }) {
    if (text.trim().isEmpty && (images == null || images.isEmpty)) return;
    if (isCodex && (images == null || images.isEmpty)) {
      final command = text.trim();
      switch (command) {
        case '/goal':
          requestGoal();
          return;
        case '/goal edit':
          requestGoal();
          return;
        case '/goal pause':
          setGoalStatus(CodexThreadGoalStatus.paused);
          return;
        case '/goal resume':
          setGoalStatus(CodexThreadGoalStatus.active);
          return;
        case '/goal clear':
          clearGoal();
          return;
        default:
          if (command.startsWith('/goal ')) {
            setGoalObjective(command.substring('/goal '.length));
            return;
          }
      }
    }
    if (isCodex && state.queuedInput != null) return;

    final clientMessageId = _uuid.v4();
    final isOffline = !_bridge.isConnected;
    final baseSeq = isOffline
        ? _bridge.cachedSessionHistorySeq(sessionId)
        : null;
    final structuredMentions = isCodex
        ? _extractCodexStructuredInputs(
            text,
            mentionablePaths: mentionablePaths,
          )
        : (
            skills: const <Map<String, String>>[],
            mentions: const <Map<String, String>>[],
          );

    final shouldUseOfflineQueuePanel = isCodex && isOffline;
    final shouldAddLocalEntry =
        !isCodex ||
        (!shouldUseOfflineQueuePanel && state.status == ProcessStatus.idle);
    if (shouldAddLocalEntry) {
      final entry = UserChatEntry(
        text,
        sessionId: sessionId,
        clientMessageId: clientMessageId,
        imageBytesList: images?.map((i) => i.bytes).toList(),
        status: isOffline ? MessageStatus.queued : MessageStatus.sending,
        messageUuid: isCodex ? _nextOptimisticCodexUserTurnUuid() : null,
      );
      emit(state.copyWith(entries: [...state.entries, entry]));
    } else if (shouldUseOfflineQueuePanel) {
      emit(
        state.copyWith(
          queuedInput: QueuedInputItem(
            itemId: '$offlineQueuedInputPrefix$clientMessageId',
            text: text,
            createdAt: DateTime.now().toUtc().toIso8601String(),
            imageCount: images?.length ?? 0,
            skills: structuredMentions.skills,
            mentions: structuredMentions.mentions,
          ),
        ),
      );
    }

    // Encode images as Base64 for WebSocket transmission
    List<Map<String, String>>? imagePayloads;
    if (images != null && images.isNotEmpty) {
      imagePayloads = images
          .map((i) => {'base64': base64Encode(i.bytes), 'mimeType': i.mimeType})
          .toList();
    }

    final deliveryPendingItem = isCodex && !isOffline
        ? QueuedInputItem(
            itemId: '$deliveryPendingQueuedInputPrefix$clientMessageId',
            text: text,
            createdAt: DateTime.now().toUtc().toIso8601String(),
            imageCount: images?.length ?? 0,
            skills: structuredMentions.skills,
            mentions: structuredMentions.mentions,
          )
        : null;
    if (deliveryPendingItem != null) {
      _deliveryPendingInputs[clientMessageId] = deliveryPendingItem;
      _bridge.setDeliveryPendingInput(
        sessionId,
        deliveryPendingItem,
        visibleAfter: _deliveryPendingDelay,
      );
    }

    _bridge.send(
      ClientMessage.input(
        text,
        sessionId: sessionId,
        clientMessageId: clientMessageId,
        baseSeq: baseSeq,
        images: imagePayloads,
        skill: structuredMentions.skills.isNotEmpty
            ? structuredMentions.skills.first
            : null,
        skills: structuredMentions.skills,
        mentions: structuredMentions.mentions,
      ),
    );
    if (isCodex && !isOffline) {
      _scheduleDeliveryPendingQueue(
        clientMessageId: clientMessageId,
        item: deliveryPendingItem!,
      );
    }
  }

  void requestGoal({bool userInitiated = false}) {
    if (!isCodex || state.goalMutation != null) return;
    if (state.goalSupport == CodexGoalSupport.unsupported && !userInitiated) {
      return;
    }
    if (_goalReadPending) {
      _goalUserRefreshPending = _goalUserRefreshPending || userInitiated;
      return;
    }
    if (!_bridge.isConnected) {
      if (userInitiated) {
        _setGoalOperationError(
          'Connect to the Bridge before managing this goal.',
          kind: CodexGoalErrorKind.connectRequired,
        );
      }
      if (state.goalLoadErrorKind != CodexGoalErrorKind.disconnected) {
        emit(
          state.copyWith(
            goalStateLoaded: false,
            goalSupport: CodexGoalSupport.unknown,
            goalLoadErrorKind: CodexGoalErrorKind.disconnected,
          ),
        );
      }
      return;
    }
    try {
      _goalReadPending = true;
      _goalUserRefreshPending = userInitiated;
      _goalReadTimer?.cancel();
      _goalReadTimer = Timer(_goalReadTimeout, () {
        if (!_goalReadPending || isClosed) return;
        final showError = _goalUserRefreshPending;
        _completeGoalRead();
        emit(
          state.copyWith(
            goalStateLoaded: false,
            goalSupport: CodexGoalSupport.unknown,
            goalLoadErrorKind: CodexGoalErrorKind.readFailed,
            goalMutationError: showError
                ? 'Goal state could not be loaded from the Bridge.'
                : null,
            goalMutationErrorKind: showError
                ? CodexGoalErrorKind.readFailed
                : null,
          ),
        );
      });
      if (state.goalLoadErrorKind != null ||
          state.goalSupport == CodexGoalSupport.unsupported) {
        emit(
          state.copyWith(
            goalSupport: CodexGoalSupport.unknown,
            goalStateLoaded: false,
            goalLoadErrorKind: null,
          ),
        );
      }
      _bridge.send(ClientMessage.getGoal(sessionId));
    } catch (error) {
      _completeGoalRead();
      emit(
        state.copyWith(
          goalStateLoaded: false,
          goalSupport: CodexGoalSupport.unknown,
          goalLoadErrorKind: CodexGoalErrorKind.readFailed,
          goalMutationError: userInitiated ? error.toString() : null,
          goalMutationErrorKind: userInitiated
              ? CodexGoalErrorKind.readFailed
              : null,
        ),
      );
    }
  }

  bool startGoal(
    String objective, {
    int? tokenBudget,
    bool includeTokenBudget = false,
  }) {
    final normalized = objective.trim();
    if (!_isValidGoalObjective(normalized)) return false;
    return _beginGoalMutation(
      CodexGoalMutation(
        id: _uuid.v4(),
        kind: CodexGoalMutationKind.create,
        objective: normalized,
        status: CodexThreadGoalStatus.active,
        includesTokenBudget: includeTokenBudget,
        tokenBudget: tokenBudget,
        expectedOperationSequence: state.goalOperationSequence,
      ),
      (changeId) => ClientMessage.setGoal(
        sessionId: sessionId,
        objective: normalized,
        status: CodexThreadGoalStatus.active,
        tokenBudget: tokenBudget,
        includeTokenBudget: includeTokenBudget,
        goalChangeId: changeId,
        expectedGoalOperationSequence: state.goalOperationSequence,
      ),
    );
  }

  bool editGoal(
    String objective, {
    int? tokenBudget,
    bool includeTokenBudget = false,
    bool includeObjective = true,
  }) {
    if (state.goal == null) {
      return startGoal(
        objective,
        tokenBudget: tokenBudget,
        includeTokenBudget: includeTokenBudget,
      );
    }
    final normalized = objective.trim();
    if (includeObjective && !_isValidGoalObjective(normalized)) return false;
    if (!includeObjective && !includeTokenBudget) return true;
    return _beginGoalMutation(
      CodexGoalMutation(
        id: _uuid.v4(),
        kind: includeTokenBudget
            ? CodexGoalMutationKind.updateBudget
            : CodexGoalMutationKind.edit,
        objective: includeObjective ? normalized : null,
        includesTokenBudget: includeTokenBudget,
        tokenBudget: tokenBudget,
        expectedOperationSequence: state.goalOperationSequence,
      ),
      (changeId) => ClientMessage.setGoal(
        sessionId: sessionId,
        objective: includeObjective ? normalized : null,
        tokenBudget: tokenBudget,
        includeTokenBudget: includeTokenBudget,
        goalChangeId: changeId,
        expectedGoalOperationSequence: state.goalOperationSequence,
      ),
    );
  }

  bool setGoalObjective(String objective) => editGoal(objective);

  bool toggleGoalPaused() {
    final goal = state.goal;
    if (!isCodex || goal == null) return false;
    return goal.status == CodexThreadGoalStatus.paused
        ? resumeGoal()
        : setGoalStatus(CodexThreadGoalStatus.paused);
  }

  bool resumeGoal({
    String? objective,
    int? tokenBudget,
    bool includeTokenBudget = false,
  }) {
    final goal = state.goal;
    if (goal == null) return false;
    final normalizedObjective = objective?.trim();
    if (normalizedObjective != null &&
        !_isValidGoalObjective(normalizedObjective)) {
      return false;
    }
    if (goal.status == CodexThreadGoalStatus.budgetLimited &&
        (!includeTokenBudget ||
            (tokenBudget != null && tokenBudget <= goal.tokensUsed))) {
      _setGoalOperationError(
        'Raise the token budget above the used amount, or remove the budget, before resuming.',
        kind: CodexGoalErrorKind.budgetResumeRequired,
      );
      return false;
    }
    return _beginGoalMutation(
      CodexGoalMutation(
        id: _uuid.v4(),
        kind: CodexGoalMutationKind.resume,
        objective: normalizedObjective,
        status: CodexThreadGoalStatus.active,
        includesTokenBudget: includeTokenBudget,
        tokenBudget: tokenBudget,
        expectedOperationSequence: state.goalOperationSequence,
      ),
      (changeId) => ClientMessage.setGoal(
        sessionId: sessionId,
        objective: normalizedObjective,
        status: CodexThreadGoalStatus.active,
        tokenBudget: tokenBudget,
        includeTokenBudget: includeTokenBudget,
        goalChangeId: changeId,
        expectedGoalOperationSequence: state.goalOperationSequence,
      ),
    );
  }

  bool setGoalStatus(CodexThreadGoalStatus status) {
    if (!isCodex || state.goal == null) return false;
    if (status != CodexThreadGoalStatus.active &&
        status != CodexThreadGoalStatus.paused) {
      return false;
    }
    if (status == CodexThreadGoalStatus.active) return resumeGoal();
    return _beginGoalMutation(
      CodexGoalMutation(
        id: _uuid.v4(),
        kind: CodexGoalMutationKind.pause,
        status: status,
        expectedOperationSequence: state.goalOperationSequence,
      ),
      (changeId) => ClientMessage.setGoal(
        sessionId: sessionId,
        status: status,
        goalChangeId: changeId,
        expectedGoalOperationSequence: state.goalOperationSequence,
      ),
    );
  }

  bool clearGoal() {
    if (!isCodex || state.goal == null) return false;
    return _beginGoalMutation(
      CodexGoalMutation(
        id: _uuid.v4(),
        kind: CodexGoalMutationKind.clear,
        expectedOperationSequence: state.goalOperationSequence,
      ),
      (changeId) => ClientMessage.clearGoal(
        sessionId,
        goalChangeId: changeId,
        expectedGoalOperationSequence: state.goalOperationSequence,
      ),
    );
  }

  bool _beginGoalMutation(
    CodexGoalMutation mutation,
    ClientMessage Function(String changeId) buildMessage,
  ) {
    if (!isCodex || state.goalMutation != null) return false;
    if (state.goalSupport == CodexGoalSupport.unsupported) {
      _setGoalOperationError(
        'This Codex runtime does not support Goal controls.',
        kind: CodexGoalErrorKind.unsupported,
      );
      return false;
    }
    if (!_bridge.isConnected) {
      _setGoalOperationError(
        'Goal controls require a live Bridge connection and are never queued offline.',
        kind: CodexGoalErrorKind.connectRequired,
      );
      return false;
    }
    if (!state.goalStateLoaded ||
        state.goalSupport != CodexGoalSupport.supported) {
      _setGoalOperationError(
        'Load the current Goal from the Bridge before changing it.',
        kind: CodexGoalErrorKind.readFailed,
      );
      return false;
    }
    if (state.goal?.hasUnknownStatus == true) {
      _setGoalOperationError(
        'This Goal uses a newer status and is read-only on this app version.',
        kind: CodexGoalErrorKind.unknownStatus,
      );
      return false;
    }
    if (mutation.includesTokenBudget &&
        mutation.tokenBudget != null &&
        mutation.tokenBudget! <= 0) {
      _setGoalOperationError(
        'Token budget must be a positive number.',
        kind: CodexGoalErrorKind.invalidBudget,
      );
      return false;
    }

    emit(
      state.copyWith(
        goalMutation: mutation,
        goalMutationError: null,
        goalMutationErrorKind: null,
      ),
    );
    _goalMutationTimer?.cancel();
    _goalMutationTimer = Timer(_goalMutationTimeout, () {
      if (state.goalMutation?.id != mutation.id) return;
      _failPendingGoalMutation(
        'Goal change timed out. The current Goal will be refreshed.',
        kind: CodexGoalErrorKind.timeout,
      );
      requestGoal();
    });
    try {
      _bridge.send(buildMessage(mutation.id));
      return true;
    } catch (error) {
      if (state.goalMutation?.id == mutation.id) {
        _failPendingGoalMutation(error.toString());
      }
      return false;
    }
  }

  bool _isValidGoalObjective(String objective) {
    if (objective.isNotEmpty && objective.length <= 4000) return true;
    _setGoalOperationError(
      objective.isEmpty
          ? 'Enter a goal objective.'
          : 'Goal objectives are limited to 4,000 characters.',
      kind: objective.isEmpty
          ? CodexGoalErrorKind.objectiveRequired
          : CodexGoalErrorKind.objectiveTooLong,
    );
    return false;
  }

  void _setGoalOperationError(String message, {CodexGoalErrorKind? kind}) {
    if (isClosed) return;
    emit(
      state.copyWith(
        goalMutationError: message.trim(),
        goalMutationErrorKind: kind,
      ),
    );
  }

  void _scheduleDeliveryPendingQueue({
    required String clientMessageId,
    required QueuedInputItem item,
  }) {
    _deliveryPendingTimers[clientMessageId]?.cancel();
    _deliveryPendingTimers[clientMessageId] = Timer(_deliveryPendingDelay, () {
      _deliveryPendingTimers.remove(clientMessageId);
      if (isClosed || state.queuedInput != null) return;
      _bridge.showDeliveryPendingInput(sessionId, itemId: item.itemId);

      final entries = state.entries;
      final entryIndex = entries.indexWhere(
        (entry) =>
            entry is UserChatEntry &&
            entry.clientMessageId == clientMessageId &&
            entry.status == MessageStatus.sending,
      );
      final nextEntries = entryIndex == -1
          ? entries
          : [...entries.take(entryIndex), ...entries.skip(entryIndex + 1)];
      emit(state.copyWith(entries: nextEntries, queuedInput: item));
    });
  }

  void updateQueuedInput(QueuedInputItem item, String text) {
    if (!isCodex || text.trim().isEmpty) return;
    if (isDeliveryPendingQueuedInput(item)) return;
    final structuredMentions = _extractCodexStructuredInputs(text);
    final offlineClientMessageId = offlineQueuedClientMessageId(item);
    if (offlineClientMessageId != null) {
      final updated = QueuedInputItem(
        itemId: item.itemId,
        text: text,
        createdAt: item.createdAt,
        updatedAt: DateTime.now().toUtc().toIso8601String(),
        imageCount: item.imageCount,
        skills: structuredMentions.skills,
        mentions: structuredMentions.mentions,
      );
      emit(state.copyWith(queuedInput: updated));
      unawaited(
        _bridge.updateOfflinePendingInput(
          sessionId: sessionId,
          clientMessageId: offlineClientMessageId,
          text: text,
          skills: structuredMentions.skills,
          mentions: structuredMentions.mentions,
        ),
      );
      return;
    }
    _bridge.send(
      ClientMessage.updateQueuedInput(
        sessionId: sessionId,
        itemId: item.itemId,
        text: text,
        skills: structuredMentions.skills,
        mentions: structuredMentions.mentions,
      ),
    );
  }

  void steerQueuedInput(QueuedInputItem item) {
    if (!isCodex ||
        isOfflineQueuedInput(item) ||
        isDeliveryPendingQueuedInput(item)) {
      return;
    }
    _bridge.send(
      ClientMessage.steerQueuedInput(sessionId: sessionId, itemId: item.itemId),
    );
  }

  void cancelQueuedInput(QueuedInputItem item) {
    if (!isCodex) return;
    if (isDeliveryPendingQueuedInput(item)) {
      final clientMessageId = deliveryPendingClientMessageId(item);
      if (clientMessageId != null) {
        _deliveryPendingInputs.remove(clientMessageId);
      }
      _bridge.clearDeliveryPendingInput(sessionId, itemId: item.itemId);
      if (state.queuedInput?.itemId == item.itemId) {
        emit(state.copyWith(queuedInput: null));
      }
      return;
    }
    final offlineClientMessageId = offlineQueuedClientMessageId(item);
    if (offlineClientMessageId != null) {
      emit(state.copyWith(queuedInput: null));
      unawaited(
        _bridge.cancelOfflinePendingInput(
          sessionId: sessionId,
          clientMessageId: offlineClientMessageId,
        ),
      );
      return;
    }
    _bridge.send(
      ClientMessage.cancelQueuedInput(
        sessionId: sessionId,
        itemId: item.itemId,
      ),
    );
  }

  /// Approve a pending tool execution.
  void approve(String toolUseId, {bool clearContext = false}) {
    final isExitPlanApproval = _isExitPlanApproval(toolUseId);
    logger.info(
      '[session:$sessionId] approve toolUseId=$toolUseId'
      '${clearContext ? ' clearContext' : ''}',
    );
    _markToolUseResponded(toolUseId);
    _bridge.send(
      ClientMessage.approve(
        toolUseId,
        clearContext: clearContext,
        sessionId: sessionId,
      ),
    );
    _emitNextApprovalOrNone(
      toolUseId,
      exitPlanModeResolved: isExitPlanApproval,
    );
  }

  /// Approve a tool and always allow it in the future.
  void approveAlways(String toolUseId) {
    final isExitPlanApproval = _isExitPlanApproval(toolUseId);
    _markToolUseResponded(toolUseId);
    _bridge.send(ClientMessage.approveAlways(toolUseId, sessionId: sessionId));
    _emitNextApprovalOrNone(
      toolUseId,
      exitPlanModeResolved: isExitPlanApproval,
    );
  }

  /// Begin installing a plugin or connector suggested by Codex.
  ///
  /// Unlike a normal approval, the request remains visible while Bridge
  /// installs the plugin or waits for external connector authentication.
  void installToolSuggestion(String toolUseId) {
    logger.info(
      '[session:$sessionId] install tool suggestion toolUseId=$toolUseId',
    );
    _bridge.send(
      ClientMessage.installToolSuggestion(toolUseId, sessionId: sessionId),
    );
  }

  /// Find next pending permission after resolving [resolvedToolUseId].
  ///
  /// Advances to the next live pending permission without rescanning completed
  /// transcript history from older turns.
  void _emitNextApprovalOrNone(
    String resolvedToolUseId, {
    bool exitPlanModeResolved = false,
  }) {
    _pendingPermissionRequests.remove(resolvedToolUseId);
    for (final id in _respondedToolUseIds) {
      _pendingPermissionRequests.remove(id);
    }

    final resolvedPermissionMode = exitPlanModeResolved
        ? legacyPermissionModeFromModes(
            provider ?? Provider.claude,
            executionMode: state.executionMode,
            planMode: false,
          )
        : state.permissionMode;

    if (_pendingPermissionRequests.isNotEmpty) {
      final next = _pendingPermissionRequests.values.first;
      final nextApproval = next.usesAskUserUi
          ? ApprovalState.askUser(
              toolUseId: next.toolUseId,
              input: next.input,
            )
          : ApprovalState.permission(
              toolUseId: next.toolUseId,
              request: next,
            );
      emit(
        state.copyWith(
          approval: nextApproval,
          permissionMode: resolvedPermissionMode,
          planMode: next.toolName == 'ExitPlanMode'
              ? true
              : (exitPlanModeResolved ? false : state.planMode),
          inPlanMode: next.toolName == 'ExitPlanMode'
              ? true
              : (exitPlanModeResolved ? false : state.inPlanMode),
        ),
      );
    } else {
      emit(
        state.copyWith(
          approval: const ApprovalState.none(),
          permissionMode: resolvedPermissionMode,
          planMode: exitPlanModeResolved ? false : state.planMode,
          inPlanMode: exitPlanModeResolved ? false : state.inPlanMode,
        ),
      );
    }
  }

  void _replacePendingPermissionsFromHistory(List<ServerMessage> messages) {
    _pendingPermissionRequests.clear();
    ProcessStatus? lastStatus;
    for (final message in messages) {
      if (message is StatusMessage) {
        lastStatus = message.status;
        if (message.status == ProcessStatus.idle ||
            message.status == ProcessStatus.starting) {
          _pendingPermissionRequests.clear();
        }
      } else if (message is PermissionRequestMessage &&
          !_respondedToolUseIds.contains(message.toolUseId)) {
        _pendingPermissionRequests[message.toolUseId] = message;
      } else if (message is PermissionResolvedMessage) {
        _pendingPermissionRequests.remove(message.toolUseId);
      } else if (message is ToolResultMessage) {
        _pendingPermissionRequests.remove(message.toolUseId);
      } else if (message is ResultMessage && message.subtype == 'stopped') {
        _pendingPermissionRequests.clear();
      }
    }
    if (lastStatus != ProcessStatus.waitingApproval) {
      _pendingPermissionRequests.clear();
    }
  }

  bool _isExitPlanApproval(String toolUseId) {
    final pending = _pendingPermissionRequests[toolUseId];
    if (pending != null) return pending.toolName == 'ExitPlanMode';
    final approval = state.approval;
    if (approval is ApprovalPermission &&
        approval.toolUseId == toolUseId &&
        approval.request.toolName == 'ExitPlanMode') {
      return true;
    }

    for (final entry in state.entries.reversed) {
      if (entry is! ServerChatEntry) continue;
      final msg = entry.message;
      if (msg is PermissionRequestMessage && msg.toolUseId == toolUseId) {
        return msg.toolName == 'ExitPlanMode';
      }
    }
    return false;
  }

  /// Reject a pending tool execution.
  void reject(String toolUseId, {String? message}) {
    logger.info(
      '[session:$sessionId] reject toolUseId=$toolUseId'
      '${message != null ? ' msg=$message' : ''}',
    );
    _markToolUseResponded(toolUseId);
    _bridge.send(
      ClientMessage.reject(toolUseId, message: message, sessionId: sessionId),
    );
    emit(
      state.copyWith(approval: const ApprovalState.none(), inPlanMode: false),
    );
  }

  /// Answer an AskUserQuestion.
  void answer(String toolUseId, String result) {
    _markToolUseResponded(toolUseId);
    _bridge.send(ClientMessage.answer(toolUseId, result, sessionId: sessionId));
    emit(state.copyWith(approval: const ApprovalState.none()));
  }

  /// Interrupt the current operation.
  void interrupt() {
    _bridge.interrupt(sessionId);
  }

  /// Change permission mode for Claude sessions.
  void setPermissionMode(PermissionMode mode) {
    logger.info('[session:$sessionId] setPermissionMode=${mode.value}');
    _pendingPermissionRollback = state.permissionMode;
    emit(
      state.copyWith(
        permissionMode: mode,
        inPlanMode: mode == PermissionMode.plan,
      ),
    );
    _bridge.patchSessionPermissionMode(sessionId, mode.value);
    _bridge.send(
      ClientMessage.setPermissionMode(mode.value, sessionId: sessionId),
    );

    // Persist per-session so that future resumes use this mode.
    final claudeSid = state.claudeSessionId;
    if (claudeSid != null && claudeSid.isNotEmpty) {
      _SessionSettingsHelper.save(claudeSid, {'permissionMode': mode.value});
    }
  }

  void setSessionModes({ExecutionMode? executionMode, bool? planMode}) {
    if (isCodex && isPermissionChangePending) {
      logger.warning(
        '[session:$sessionId] Permission change pending; ignoring mode update',
      );
      return;
    }
    if (isCodex &&
        planMode == true &&
        state.codexNativePlanModeSupport ==
            CodexNativePlanModeSupport.unsupported) {
      logger.warning(
        '[session:$sessionId] Native Plan mode is unsupported; ignoring mode update',
      );
      return;
    }
    final nextExecution = executionMode ?? state.executionMode;
    final nextPlanMode = planMode ?? state.planMode;
    final legacyMode = legacyPermissionModeFromModes(
      provider ?? Provider.claude,
      executionMode: nextExecution,
      planMode: nextPlanMode,
    );
    final codexPermissionsMode =
        isCodex && state.codexPermissionsMode != CodexPermissionsMode.custom
        ? state.codexPermissionsMode
        : null;
    final codexApprovalPolicy = codexPermissionsMode != null
        ? state.codexApprovalPolicy.value
        : null;
    final codexApprovalsReviewer = codexPermissionsMode != null
        ? state.codexApprovalsReviewer
        : null;

    logger.info(
      '[session:$sessionId] setSessionModes '
      'execution=${nextExecution.value} plan=$nextPlanMode',
    );

    _pendingPermissionRollback = state.permissionMode;
    _pendingExecutionRollback = state.executionMode;
    _pendingPlanRollback = state.planMode;

    emit(
      state.copyWith(
        permissionMode: legacyMode,
        executionMode: nextExecution,
        planMode: nextPlanMode,
        inPlanMode: nextPlanMode,
      ),
    );
    _bridge.patchSessionModes(
      sessionId,
      permissionMode: legacyMode.value,
      executionMode: nextExecution.value,
      planMode: nextPlanMode,
      approvalPolicy: codexApprovalPolicy,
      approvalsReviewer: codexApprovalsReviewer,
      codexPermissionsMode: codexPermissionsMode?.value,
    );
    _bridge.send(
      ClientMessage.setSessionMode(
        legacyMode: legacyMode.value,
        executionMode: nextExecution.value,
        approvalPolicy: codexApprovalPolicy,
        approvalsReviewer: codexApprovalsReviewer,
        codexPermissionsMode: codexPermissionsMode?.value,
        planMode: nextPlanMode,
        sessionId: sessionId,
      ),
    );

    final claudeSid = state.claudeSessionId;
    if (claudeSid != null && claudeSid.isNotEmpty) {
      _SessionSettingsHelper.save(claudeSid, {
        'permissionMode': legacyMode.value,
        'executionMode': nextExecution.value,
        'planMode': nextPlanMode,
      });
    }
  }

  void setCodexApprovalPolicy(
    CodexApprovalPolicy policy, {
    String approvalsReviewer = 'user',
  }) {
    if (isPermissionChangePending) {
      logger.warning(
        '[session:$sessionId] Permission change pending; ignoring approval update',
      );
      return;
    }
    final normalizedReviewer =
        policy == CodexApprovalPolicy.onRequest &&
            isCodexAutoReviewApprovalsReviewer(approvalsReviewer)
        ? 'auto_review'
        : 'user';
    logger.info('[session:$sessionId] setCodexApprovalPolicy=${policy.value}');
    _pendingPermissionRollback = state.permissionMode;
    _pendingExecutionRollback = state.executionMode;
    _pendingCodexApprovalRollback = state.codexApprovalPolicy;
    _pendingCodexApprovalsReviewerRollback = state.codexApprovalsReviewer;
    _pendingPlanRollback = state.planMode;

    const legacyMode = PermissionMode.acceptEdits;
    final derivedExecution = policy == CodexApprovalPolicy.never
        ? ExecutionMode.fullAccess
        : ExecutionMode.defaultMode;

    emit(
      state.copyWith(
        permissionMode: legacyMode,
        executionMode: derivedExecution,
        codexApprovalPolicy: policy,
        codexApprovalsReviewer: normalizedReviewer,
        planMode: false,
        inPlanMode: false,
      ),
    );
    _bridge.patchSessionModes(
      sessionId,
      permissionMode: legacyMode.value,
      executionMode: derivedExecution.value,
      planMode: false,
      approvalPolicy: policy.value,
      approvalsReviewer: normalizedReviewer,
    );
    _bridge.send(
      ClientMessage.setSessionMode(
        legacyMode: legacyMode.value,
        executionMode: derivedExecution.value,
        approvalPolicy: policy.value,
        approvalsReviewer: normalizedReviewer,
        planMode: false,
        sessionId: sessionId,
      ),
    );
  }

  void setCodexPermissionsMode(
    CodexPermissionsMode mode, {
    CodexPermissionApplyStrategy? applyStrategy,
  }) {
    if (applyStrategy != null && _pendingPermissionChangeId != null) {
      logger.warning(
        '[session:$sessionId] Permission change already pending; ignoring duplicate request',
      );
      return;
    }
    final policy =
        approvalPolicyForCodexPermissionsMode(mode) ??
        state.codexApprovalPolicy;
    final approvalsReviewer =
        approvalsReviewerForCodexPermissionsMode(mode) ??
        state.codexApprovalsReviewer;
    final sandboxMode = sandboxModeForCodexPermissionsMode(mode);
    final derivedExecution = mode == CodexPermissionsMode.fullAccess
        ? ExecutionMode.fullAccess
        : ExecutionMode.defaultMode;
    const legacyMode = PermissionMode.acceptEdits;

    logger.info('[session:$sessionId] setCodexPermissionsMode=${mode.value}');
    _pendingPermissionRollback = state.permissionMode;
    _pendingExecutionRollback = state.executionMode;
    _pendingCodexApprovalRollback = state.codexApprovalPolicy;
    _pendingCodexApprovalsReviewerRollback = state.codexApprovalsReviewer;
    _pendingCodexPermissionsModeRollback = state.codexPermissionsMode;
    _pendingSandboxRollback = state.sandboxMode;
    _pendingPlanRollback = state.planMode;
    final permissionChangeId = applyStrategy == null ? null : _uuid.v4();
    _pendingPermissionChangeId = permissionChangeId;
    if (applyStrategy == CodexPermissionApplyStrategy.restartNow) {
      _pendingPermissionRestartStatusRollback = state.status;
      _pendingPermissionRestartApprovalRollback = state.approval;
    }

    emit(
      state.copyWith(
        permissionMode: legacyMode,
        executionMode: derivedExecution,
        codexApprovalPolicy: policy,
        codexApprovalsReviewer: approvalsReviewer,
        codexPermissionsMode: mode,
        sandboxMode: sandboxMode ?? state.sandboxMode,
        planMode: state.planMode,
        inPlanMode: state.inPlanMode,
        status: applyStrategy == CodexPermissionApplyStrategy.restartNow
            ? ProcessStatus.starting
            : state.status,
        approval: applyStrategy == CodexPermissionApplyStrategy.restartNow
            ? const ApprovalState.none()
            : state.approval,
      ),
    );
    _bridge.patchSessionModes(
      sessionId,
      permissionMode: legacyMode.value,
      executionMode: derivedExecution.value,
      planMode: state.planMode,
      approvalPolicy: mode == CodexPermissionsMode.custom ? null : policy.value,
      approvalsReviewer: mode == CodexPermissionsMode.custom
          ? null
          : approvalsReviewer,
      codexPermissionsMode: mode.value,
    );
    if (sandboxMode != null) {
      _bridge.patchSessionSandboxMode(sessionId, sandboxMode.value);
    }
    try {
      _bridge.send(
        ClientMessage.setSessionMode(
          legacyMode: legacyMode.value,
          executionMode: derivedExecution.value,
          approvalPolicy: mode == CodexPermissionsMode.custom
              ? null
              : policy.value,
          approvalsReviewer: mode == CodexPermissionsMode.custom
              ? null
              : approvalsReviewer,
          codexPermissionsMode: mode.value,
          planMode: state.planMode,
          applyStrategy: applyStrategy,
          permissionChangeId: permissionChangeId,
          sessionId: sessionId,
        ),
      );
    } catch (_) {
      _onMessage(
        ErrorMessage(
          message: 'Bridge is not connected; permission change was not sent.',
          errorCode: 'set_permission_mode_rejected',
          sessionId: sessionId,
          permissionChangeId: permissionChangeId,
        ),
      );
    }
  }

  void setCodexModel(String model, {ReasoningEffort? reasoningEffort}) {
    if (!isCodex) return;
    final normalizedModel = sanitizeCodexModelName(model);
    if (normalizedModel == null) return;
    final nextReasoningEffort =
        reasoningEffort ?? state.codexModelReasoningEffort;
    logger.info(
      '[session:$sessionId] setCodexModel=$normalizedModel '
      'reasoning=${nextReasoningEffort?.value}',
    );
    emit(
      state.copyWith(
        codexModel: normalizedModel,
        codexModelReasoningEffort: nextReasoningEffort,
      ),
    );
    _bridge.patchSessionCodexModel(
      sessionId,
      normalizedModel,
      modelReasoningEffort: nextReasoningEffort?.value,
    );
    _bridge.send(
      ClientMessage.setCodexModel(
        normalizedModel,
        modelReasoningEffort: nextReasoningEffort?.value,
        sessionId: sessionId,
      ),
    );
  }

  void setCodexSpeed(CodexSpeed speed) {
    if (!isCodex || speed == state.codexSpeed) return;
    logger.info('[session:$sessionId] setCodexSpeed=${speed.value}');
    emit(state.copyWith(codexSpeed: speed));
    _bridge.patchSessionCodexSpeed(sessionId, speed.value);
    _bridge.send(
      ClientMessage.setCodexSpeed(speed.value, sessionId: sessionId),
    );
  }

  /// Change sandbox mode (Claude & Codex).
  /// Bridge destroys and resumes the session with new sandbox settings.
  void setSandboxMode(SandboxMode mode) {
    _pendingSandboxRollback = state.sandboxMode;
    emit(state.copyWith(sandboxMode: mode));
    if (isCodex) {
      _bridge.patchSessionSandboxMode(sessionId, mode.value);
    }
    _bridge.send(
      ClientMessage.setSandboxMode(mode.value, sessionId: sessionId),
    );
    // Persist per-session so that future resumes use this mode.
    final claudeSid = state.claudeSessionId;
    if (claudeSid != null && claudeSid.isNotEmpty) {
      _SessionSettingsHelper.save(claudeSid, {'sandboxMode': mode.value});
    }
  }

  void _rollbackFailedModeChange(ErrorMessage msg) {
    final nativePlanModeUnsupported =
        msg.errorCode == 'codex_native_plan_mode_unsupported';
    if (_isPermissionModeFailure(msg)) {
      final pendingChangeId = _pendingPermissionChangeId;
      if (pendingChangeId != null &&
          msg.permissionChangeId != pendingChangeId) {
        if (nativePlanModeUnsupported) {
          _applyNativePlanModeUnsupportedRollback();
        }
        return;
      }
      final previous = _pendingPermissionRollback;
      _pendingPermissionRollback = null;
      if (previous != null) {
        emit(
          state.copyWith(
            permissionMode: previous,
            executionMode: _pendingExecutionRollback ?? state.executionMode,
            codexApprovalPolicy:
                _pendingCodexApprovalRollback ?? state.codexApprovalPolicy,
            codexApprovalsReviewer:
                _pendingCodexApprovalsReviewerRollback ??
                state.codexApprovalsReviewer,
            codexPermissionsMode:
                _pendingCodexPermissionsModeRollback ??
                state.codexPermissionsMode,
            sandboxMode: _pendingSandboxRollback ?? state.sandboxMode,
            planMode: _pendingPlanRollback ?? (previous == PermissionMode.plan),
            inPlanMode:
                _pendingPlanRollback ?? (previous == PermissionMode.plan),
            status: _pendingPermissionRestartStatusRollback ?? state.status,
            approval:
                _pendingPermissionRestartApprovalRollback ?? state.approval,
          ),
        );
        _bridge.patchSessionModes(
          sessionId,
          permissionMode: previous.value,
          executionMode:
              (_pendingExecutionRollback ?? state.executionMode).value,
          planMode: _pendingPlanRollback ?? (previous == PermissionMode.plan),
          approvalPolicy:
              (_pendingCodexApprovalRollback ?? state.codexApprovalPolicy)
                  .value,
          approvalsReviewer:
              _pendingCodexApprovalsReviewerRollback ??
              state.codexApprovalsReviewer,
          codexPermissionsMode:
              (_pendingCodexPermissionsModeRollback ??
                      state.codexPermissionsMode)
                  .value,
        );
        final previousSandbox = _pendingSandboxRollback;
        if (isCodex && previousSandbox != null) {
          _bridge.patchSessionSandboxMode(sessionId, previousSandbox.value);
        }
        final claudeSid = state.claudeSessionId;
        if (claudeSid != null && claudeSid.isNotEmpty) {
          _SessionSettingsHelper.save(claudeSid, {
            'permissionMode': previous.value,
            'executionMode':
                (_pendingExecutionRollback ?? state.executionMode).value,
            'planMode':
                _pendingPlanRollback ?? (previous == PermissionMode.plan),
          });
        }
      }
      _pendingExecutionRollback = null;
      _pendingCodexApprovalRollback = null;
      _pendingCodexApprovalsReviewerRollback = null;
      _pendingCodexPermissionsModeRollback = null;
      _pendingPlanRollback = null;
      _pendingSandboxRollback = null;
      _pendingPermissionChangeId = null;
      _pendingPermissionRestartStatusRollback = null;
      _pendingPermissionRestartApprovalRollback = null;
    }

    if (nativePlanModeUnsupported) {
      _applyNativePlanModeUnsupportedRollback();
    }

    if (_isSandboxModeFailure(msg)) {
      final previous = _pendingSandboxRollback;
      _pendingSandboxRollback = null;
      if (previous != null) {
        emit(state.copyWith(sandboxMode: previous));
        if (isCodex) {
          _bridge.patchSessionSandboxMode(sessionId, previous.value);
        }
        final claudeSid = state.claudeSessionId;
        if (claudeSid != null && claudeSid.isNotEmpty) {
          _SessionSettingsHelper.save(claudeSid, {
            'sandboxMode': previous.value,
          });
        }
      }
    }
  }

  void _applyNativePlanModeUnsupportedRollback() {
    final needsModeReset =
        state.planMode ||
        state.inPlanMode ||
        state.permissionMode == PermissionMode.plan;
    final legacyMode = legacyPermissionModeFromModes(
      provider ?? Provider.codex,
      executionMode: state.executionMode,
      planMode: false,
    );
    final rollbackPermissionMode = needsModeReset
        ? legacyMode
        : state.permissionMode;
    if (needsModeReset ||
        state.codexNativePlanModeSupport !=
            CodexNativePlanModeSupport.unsupported) {
      emit(
        state.copyWith(
          permissionMode: rollbackPermissionMode,
          planMode: false,
          inPlanMode: false,
          codexNativePlanModeSupport: CodexNativePlanModeSupport.unsupported,
        ),
      );
    }
    if (!needsModeReset) return;
    _bridge.patchSessionModes(
      sessionId,
      permissionMode: rollbackPermissionMode.value,
      executionMode: state.executionMode.value,
      planMode: false,
      approvalPolicy: state.codexApprovalPolicy.value,
      approvalsReviewer: state.codexApprovalsReviewer,
      codexPermissionsMode: state.codexPermissionsMode.value,
    );
    final providerSessionId = state.claudeSessionId;
    if (providerSessionId != null && providerSessionId.isNotEmpty) {
      _SessionSettingsHelper.save(providerSessionId, {
        'permissionMode': rollbackPermissionMode.value,
        'executionMode': state.executionMode.value,
        'planMode': false,
      });
    }
  }

  void _clearPendingPermissionModeRollback(String? permissionChangeId) {
    final pendingChangeId = _pendingPermissionChangeId;
    if (pendingChangeId != null && permissionChangeId != pendingChangeId) {
      return;
    }
    _pendingPermissionRollback = null;
    _pendingExecutionRollback = null;
    _pendingCodexApprovalRollback = null;
    _pendingCodexApprovalsReviewerRollback = null;
    _pendingCodexPermissionsModeRollback = null;
    _pendingPlanRollback = null;
    _pendingSandboxRollback = null;
    _pendingPermissionChangeId = null;
    _pendingPermissionRestartStatusRollback = null;
    _pendingPermissionRestartApprovalRollback = null;
  }

  /// Keep a late acknowledgement from an older operation from replacing the
  /// optimistic state of the permission change currently in flight.
  ///
  /// The old acknowledgement is still authoritative for the rollback base: if
  /// the newer operation fails, the UI must return to the permission state the
  /// Bridge actually confirmed, not the state captured before that late ACK.
  bool _captureSupersededPermissionAcknowledgement(SystemMessage message) {
    final pendingChangeId = _pendingPermissionChangeId;
    final acknowledgedChangeId = message.permissionChangeId;
    if (pendingChangeId == null ||
        acknowledgedChangeId == null ||
        acknowledgedChangeId == pendingChangeId) {
      return false;
    }

    for (final mode in PermissionMode.values) {
      if (mode.value == message.permissionMode) {
        _pendingPermissionRollback = mode;
        break;
      }
    }
    _pendingExecutionRollback =
        executionModeFromRaw(message.executionMode) ??
        _pendingExecutionRollback;
    _pendingCodexApprovalRollback =
        codexApprovalPolicyFromRaw(message.approvalPolicy) ??
        _pendingCodexApprovalRollback;
    if (message.approvalsReviewer != null) {
      _pendingCodexApprovalsReviewerRollback = message.approvalsReviewer;
    }
    _pendingCodexPermissionsModeRollback =
        codexPermissionsModeFromRaw(message.codexPermissionsMode) ??
        _pendingCodexPermissionsModeRollback;
    if (message.planMode != null) {
      _pendingPlanRollback = message.planMode;
    }
    final sandboxMode = switch (message.sandboxMode) {
      'danger-full-access' || 'off' => SandboxMode.off,
      'workspace-write' || 'read-only' || 'on' => SandboxMode.on,
      _ => null,
    };
    if (sandboxMode != null) {
      _pendingSandboxRollback = sandboxMode;
    }
    logger.info(
      '[session:$sessionId] Deferred superseded permission acknowledgement '
      '$acknowledgedChangeId while $pendingChangeId is pending',
    );
    return true;
  }

  bool _isPermissionModeFailure(ErrorMessage msg) {
    return msg.errorCode == 'set_permission_mode_rejected' ||
        msg.errorCode == 'codex_native_plan_mode_unsupported' ||
        msg.errorCode == 'codex_native_plan_mode_probe_retry' ||
        msg.errorCode == 'auto_mode_unavailable' ||
        msg.message.startsWith('Failed to set permission mode:') ||
        msg.message.startsWith(
          'Failed to restart session for permission mode change:',
        );
  }

  bool _isSandboxModeFailure(ErrorMessage msg) {
    return msg.errorCode == 'set_sandbox_mode_rejected' ||
        msg.message.startsWith('Failed to set sandbox mode:') ||
        msg.message.startsWith(
          'Failed to restart session for sandbox mode change:',
        );
  }

  /// Stop the session.
  void stop() {
    _bridge.stopSession(sessionId);
  }

  /// Request a dry-run preview of file rewind.
  void rewindDryRun(String targetUuid) {
    emit(state.copyWith(rewindPreview: null));
    _bridge.send(ClientMessage.rewindDryRun(sessionId, targetUuid));
  }

  /// Execute a rewind operation.
  /// [mode] is one of: "conversation", "code", "both".
  void rewind(String targetUuid, String mode) {
    _bridge.send(ClientMessage.rewind(sessionId, targetUuid, mode));
  }

  void forkSession(String targetUuid) {
    _bridge.send(ClientMessage.forkSession(sessionId, targetUuid));
  }

  /// All user messages with a UUID (rewindable via the SDK).
  List<UserChatEntry> get rewindableUserMessages {
    return state.entries
        .whereType<UserChatEntry>()
        .where((e) => e.messageUuid != null)
        .toList();
  }

  /// All user messages in the session (for display in message history).
  List<UserChatEntry> get allUserMessages {
    return state.entries.whereType<UserChatEntry>().toList();
  }

  /// Re-fetch session history from the bridge server.
  ///
  /// Resets [_pastHistoryLoaded] so the next [PastHistoryMessage] is processed,
  /// restoring approval state that may have arrived while disconnected.
  void refreshHistory() {
    _pastHistoryLoaded = false;
    _pastEntryCount = 0;
    if (!_bridge.hasSessionHistoryBootstrap) {
      _bridge.requestSessionHistory(sessionId);
      return;
    }
    unawaited(_refreshMirroredHistory());
  }

  Future<void> _refreshMirroredHistory() async {
    var handled = false;
    try {
      handled = await _bridge.tryBootstrapSessionHistory(
        runtimeSessionId: sessionId,
        provider: provider?.value,
        projectPath: state.projectPath,
        force: true,
      );
    } catch (error, stackTrace) {
      logger.warning(
        '[session:$sessionId] Mirror refresh failed; using Bridge history',
        error,
        stackTrace,
      );
    }
    if (!handled && !isClosed) {
      _bridge.requestSessionHistory(sessionId);
    }
  }

  /// Retry a failed user message.
  void retryMessage(UserChatEntry entry) {
    final clientMessageId = _uuid.v4();
    final retrySessionId = entry.sessionId ?? sessionId;
    final isOffline = !_bridge.isConnected;
    emit(
      state.copyWith(
        entries: state.entries.map((e) {
          if (identical(e, entry)) {
            return UserChatEntry(
              entry.text,
              sessionId: retrySessionId,
              clientMessageId: clientMessageId,
              imageBytesList: entry.imageBytesList,
              imageUrls: entry.imageUrls,
              imageCount: entry.imageCount,
              status: isOffline ? MessageStatus.queued : MessageStatus.sending,
              messageUuid: entry.messageUuid,
              timestamp: entry.timestamp,
            );
          }
          return e;
        }).toList(),
      ),
    );
    _bridge.send(
      ClientMessage.input(
        entry.text,
        sessionId: retrySessionId,
        clientMessageId: clientMessageId,
        baseSeq: isOffline
            ? _bridge.cachedSessionHistorySeq(retrySessionId)
            : null,
      ),
    );
  }

  ({List<Map<String, String>> skills, List<Map<String, String>> mentions})
  _extractCodexStructuredInputs(
    String text, {
    Iterable<String>? mentionablePaths,
  }) {
    final skills = <Map<String, String>>[];
    final mentions = <Map<String, String>>[];
    final seenSkills = <String>{};
    final seenMentions = <String>{};
    final entityByToken = {
      for (final item in state.slashCommands) item.command: item,
    };
    final matches = RegExp(
      r'(?<![A-Za-z0-9_:/.-])\$([A-Za-z0-9][A-Za-z0-9_:/.-]*)',
    ).allMatches(text);
    for (final match in matches) {
      final token = '\$${match.group(1)!}';
      final item = entityByToken[token];
      if (item == null) continue;
      if (item.skillInfo != null) {
        final payload = item.skillInfo!.toJson();
        final key = '${payload['name']}|${payload['path']}';
        if (seenSkills.add(key)) skills.add(payload);
      } else if (item.appInfo != null) {
        final payload = item.appInfo!.toJson();
        final key = '${payload['name']}|${payload['path']}';
        if (seenMentions.add(key)) mentions.add(payload);
      }
    }
    final pluginMatches = RegExp(
      r'(?<![A-Za-z0-9_:/.-])@([A-Za-z0-9][A-Za-z0-9_:/.-]*)',
    ).allMatches(text);
    for (final match in pluginMatches) {
      final token = '@${match.group(1)!}';
      final item = entityByToken[token];
      if (item?.pluginInfo == null) continue;
      final payload = item!.pluginInfo!.toJson();
      final key = '${payload['name']}|${payload['path']}';
      if (seenMentions.add(key)) mentions.add(payload);
    }
    final projectMentionPaths = _normalizeProjectMentionPaths(
      mentionablePaths ?? const <String>[],
    );
    if (projectMentionPaths.isNotEmpty) {
      final projectMatches = RegExp(
        r'(?<![A-Za-z0-9_:/.-])@(\S+)',
      ).allMatches(text);
      for (final match in projectMatches) {
        final rawPath = match.group(1)!;
        final token = '@$rawPath';
        if (entityByToken[token]?.pluginInfo != null) continue;

        final mentionPath = _resolveProjectMentionPath(
          rawPath,
          projectMentionPaths,
        );
        if (mentionPath == null) continue;

        final payloadPath = _resolveProjectMentionPayloadPath(
          mentionPath,
          state.projectPath,
        );
        final payload = {'name': mentionPath, 'path': payloadPath};
        final key = '${payload['name']}|${payload['path']}';
        if (seenMentions.add(key)) mentions.add(payload);
      }
    }
    return (skills: skills, mentions: mentions);
  }

  Set<String> _normalizeProjectMentionPaths(Iterable<String> paths) {
    final normalized = <String>{};
    for (final path in paths) {
      final trimmed = path.trim();
      if (trimmed.isEmpty) continue;
      normalized.add(trimmed);
    }
    return normalized;
  }

  String? _resolveProjectMentionPath(String rawPath, Set<String> paths) {
    if (paths.contains(rawPath)) return rawPath;

    final stripped = rawPath.replaceFirst(RegExp(r'[,.;:!?]+$'), '');
    if (stripped != rawPath && paths.contains(stripped)) return stripped;

    if (!rawPath.endsWith('/') && paths.contains('$rawPath/')) {
      return '$rawPath/';
    }
    return null;
  }

  String _resolveProjectMentionPayloadPath(
    String mentionPath,
    String? projectPath,
  ) {
    if (mentionPath.startsWith('/') || projectPath == null) {
      return mentionPath;
    }
    final root = projectPath.trim();
    if (root.isEmpty) return mentionPath;
    return root.endsWith('/') ? '$root$mentionPath' : '$root/$mentionPath';
  }

  @override
  Future<void> close() {
    _statusRefreshTimer?.cancel();
    _goalMutationTimer?.cancel();
    _goalReadTimer?.cancel();
    _goalConnectionSubscription?.cancel();
    _goalSessionListSubscription?.cancel();
    for (final timer in _deliveryPendingTimers.values) {
      timer.cancel();
    }
    _deliveryPendingTimers.clear();
    _deliveryPendingInputs.clear();
    _subscription?.cancel();
    _sideEffectsController.close();
    return super.close();
  }
}

class _UsageTotals {
  final double totalCost;
  final Duration? totalDuration;

  const _UsageTotals({required this.totalCost, required this.totalDuration});
}

List<String> updateRecentPeekedFiles(
  List<String> current,
  String path, {
  int limit = 10,
}) {
  final normalized = path.trim();
  if (normalized.isEmpty) return current;
  final next = [normalized, ...current.where((file) => file != normalized)];
  return next.take(limit).toList();
}

bool _listEquals(List<String> a, List<String> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Lightweight helper to persist per-session Claude settings.
///
/// Uses the same SharedPreferences key convention as
/// [SessionListScreen.saveClaudeSessionSettings] so the session list
/// can read them back when resuming.
class _SessionSettingsHelper {
  static const _prefix = 'claude_session_settings_';

  static Future<void> save(
    String sessionId,
    Map<String, dynamic> settings,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = '$_prefix$sessionId';
      final raw = prefs.getString(key);
      Map<String, dynamic> existing = {};
      if (raw != null) {
        try {
          existing = jsonDecode(raw) as Map<String, dynamic>;
        } catch (_) {}
      }
      final merged = <String, dynamic>{...existing, ...settings};
      await prefs.setString(key, jsonEncode(merged));
    } catch (_) {
      // SharedPreferences may not be available in test environments.
    }
  }
}
