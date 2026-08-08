import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueNotifier, compute;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../../core/logger.dart';
import '../../../models/messages.dart';
import '../../../services/bridge_service.dart';
import '../../../services/chat_message_handler.dart';
import '../../../services/desktop_continuity_backlog.dart';
import '../../../utils/diagnostic_token.dart';
import '../../../utils/history_window_policy.dart';
import 'chat_session_state.dart';
import 'streaming_state_cubit.dart';

typedef ChatImageAttachment = ({Uint8List bytes, String mimeType});
typedef ChatImagePayloadEncoder =
    Future<List<Map<String, String>>> Function(
      List<ChatImageAttachment> images,
    );

Future<List<Map<String, String>>> _defaultChatImagePayloadEncoder(
  List<ChatImageAttachment> images,
) => compute(_encodeChatImagePayloads, [
  for (final image in images)
    <String, Object>{'bytes': image.bytes, 'mimeType': image.mimeType},
], debugLabel: 'chat-image-base64');

List<Map<String, String>> _encodeChatImagePayloads(
  List<Map<String, Object>> images,
) => images
    .map(
      (image) => <String, String>{
        'base64': base64Encode(image['bytes']! as Uint8List),
        'mimeType': image['mimeType']! as String,
      },
    )
    .toList(growable: false);

class LocalHistoryPagingState {
  const LocalHistoryPagingState({
    this.enabled = false,
    this.hasMore = false,
    this.loading = false,
    this.error,
  });

  final bool enabled;
  final bool hasMore;
  final bool loading;
  final Object? error;

  LocalHistoryPagingState copyWith({
    bool? enabled,
    bool? hasMore,
    bool? loading,
    Object? error,
    bool clearError = false,
  }) => LocalHistoryPagingState(
    enabled: enabled ?? this.enabled,
    hasMore: hasMore ?? this.hasMore,
    loading: loading ?? this.loading,
    error: clearError ? null : (error ?? this.error),
  );
}

typedef DetachedHistoryPageLoader =
    Future<({bool loaded, bool hasMore})> Function();
typedef DetachedHistoryToolDetailLoader =
    Future<List<HistoryToolDetail>?> Function(
      HistoryToolDetailGap gap,
      List<String> toolUseIds,
    );
typedef DetachedUserMessageIndexLoader =
    Future<({List<UserInputMessage> messages, bool complete})?> Function();
typedef DetachedUserTurnLoader =
    Future<List<ServerMessage>?> Function(String providerTurnId);

class HistoryToolDetailLoadState {
  const HistoryToolDetailLoadState({
    this.details = const [],
    this.nextOffset = 0,
    this.loading = false,
    this.complete = false,
    this.error,
  });

  final List<HistoryToolDetail> details;
  final int nextOffset;
  final bool loading;
  final bool complete;
  final Object? error;

  HistoryToolDetailLoadState copyWith({
    List<HistoryToolDetail>? details,
    int? nextOffset,
    bool? loading,
    bool? complete,
    Object? error,
    bool clearError = false,
  }) => HistoryToolDetailLoadState(
    details: details ?? this.details,
    nextOffset: nextOffset ?? this.nextOffset,
    loading: loading ?? this.loading,
    complete: complete ?? this.complete,
    error: clearError ? null : (error ?? this.error),
  );
}

class _CanonicalAliasLookup {
  const _CanonicalAliasLookup({
    required this.exactIndexes,
    required this.weakIndexes,
  });

  final Map<String, _CanonicalAliasBucket> exactIndexes;
  final Map<String, _CanonicalAliasBucket> weakIndexes;
}

class _CanonicalAliasBucket {
  _CanonicalAliasBucket(this.indexes)
    : _nextOffsets = List<int>.generate(
        indexes.length + 1,
        (index) => index,
        growable: false,
      );

  final List<int> indexes;
  final List<int> _nextOffsets;

  int firstAvailableOffset(int canonicalStart) =>
      nextAvailableOffset(_lowerBound(canonicalStart));

  int nextAvailableOffset(int offset) => _find(offset);

  void consumeCanonicalIndex(int canonicalIndex) {
    final offset = _lowerBound(canonicalIndex);
    if (offset >= indexes.length || indexes[offset] != canonicalIndex) return;
    _nextOffsets[offset] = _find(offset + 1);
  }

  int _find(int offset) {
    var root = offset;
    while (_nextOffsets[root] != root) {
      root = _nextOffsets[root];
    }
    while (_nextOffsets[offset] != offset) {
      final next = _nextOffsets[offset];
      _nextOffsets[offset] = root;
      offset = next;
    }
    return root;
  }

  int _lowerBound(int target) {
    var low = 0;
    var high = indexes.length;
    while (low < high) {
      final middle = low + ((high - low) >> 1);
      if (indexes[middle] < target) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low;
  }
}

class _RuntimeMutationLease {
  const _RuntimeMutationLease({
    required this.sessionId,
    required this.detached,
    required this.liveRuntimeGeneration,
    required this.sourceFingerprint,
    required this.authorityGeneration,
  });

  final String sessionId;
  final bool detached;
  final int liveRuntimeGeneration;
  final String? sourceFingerprint;
  final String? authorityGeneration;
}

class _ExpiredRuntimeMutationLease implements Exception {
  const _ExpiredRuntimeMutationLease();

  @override
  String toString() => 'The live runtime authority changed before dispatch.';
}

/// Manages the state of a single chat session.
///
/// Subscribes to [BridgeService.messagesForSession] and delegates message
/// processing to [ChatMessageHandler]. The resulting [ChatStateUpdate] is
/// applied to the immutable [ChatSessionState].
class ChatSessionCubit extends Cubit<ChatSessionState> {
  static const codexPermissionApplyStrategyCapability =
      'codex_permission_apply_strategy_v1';
  static const codexDesktopContinuityCapability =
      codexDesktopContinuityBridgeCapability;
  static const _uuid = Uuid();
  static const offlineQueuedInputPrefix = 'offline:';
  static const deliveryPendingQueuedInputPrefix = 'pending:';
  static const _goalMutationTimeout = Duration(seconds: 20);
  static const _goalReadTimeout = Duration(seconds: 12);
  static const _desktopContinuityWatchAckTimeout = Duration(seconds: 4);
  static const _desktopContinuityRetryBase = Duration(milliseconds: 750);
  static const _desktopContinuityRetryMax = Duration(seconds: 8);
  static const _statusHistoryRetryBase = Duration(seconds: 3);
  static const _statusHistoryRetryMaxAttempts = 4;
  static const _maxDetachedVisualPendingMessages = 256;

  final String sessionId;
  final Provider? provider;
  final BridgeService _bridge;
  final StreamingStateCubit _streamingCubit;
  final ChatImagePayloadEncoder _imagePayloadEncoder;
  final ChatMessageHandler _handler = ChatMessageHandler();
  final bool detachedPreview;
  final List<ServerMessage> initialHistoryMessages;

  String? _detachedLiveRuntimeSessionId;
  int _detachedLiveRuntimeGeneration = 0;
  bool _detachedAuthorityObserved = false;
  String? _detachedExecutionHost;
  String? _detachedControlState;
  String? _detachedAuthorityGeneration;
  int? _detachedAuthorityLiveRuntimeGeneration;
  String? _detachedAuthoritySourceFingerprint;
  String? _detachedActiveTurnId;
  String? _detachedPreservedVisualTurnId;
  bool _detachedVisualTurnValidationPending = false;
  final List<ServerMessage> _detachedPendingVisualMessages = [];
  String? _detachedRejectedAuthorityGeneration;
  bool _detachedProviderProjectionCurrent = false;
  final ValueNotifier<int> detachedLiveRuntimeRevision = ValueNotifier(0);
  final ValueNotifier<List<QueuedInputItem>> queuedInputs = ValueNotifier(
    const [],
  );
  int _queuedInputLimit = 1;

  int get queuedInputLimit => _queuedInputLimit;

  bool get codexInputQueueFull {
    if (!isCodex) return false;
    final supportsMultiple = _bridge.bridgeCapabilities.contains(
      codexMultiInputQueueCapability,
    );
    if (!supportsMultiple) {
      // Legacy Bridges only expose an authoritative single queued item. Do
      // not mistake locally in-flight submissions for an acknowledged queue:
      // the old transport may accept several immediate turns before deciding
      // whether one of them needs to wait.
      return state.queuedInput != null ||
          _deliveryPendingInputs.length >=
              BridgeService.maxDeliveryPendingInputsPerSession;
    }
    return queuedInputs.value.length + _deliveryPendingInputs.length >=
        _queuedInputLimit;
  }

  /// Transient Bridge attachment used by a durable, cache-first page.
  ///
  /// The public [sessionId] remains the durable provider identity so cache,
  /// drafts, disclosure state, and auxiliary panes never change identity when
  /// a runtime appears or is replaced.
  String? get detachedLiveRuntimeSessionId => _detachedLiveRuntimeSessionId;

  /// Exact provider turn fence exposed to the Mobile Action Broker UI.
  ///
  /// These values are observations only. The broker still independently
  /// checks authenticated source identity, its writer lease and request
  /// liveness before allowing a response.
  String? get detachedActionBrokerTurnId => _detachedActiveTurnId;
  String? get detachedActionBrokerAuthorityGeneration =>
      _detachedAuthorityGeneration;
  String? get detachedActionBrokerExecutionHost => _detachedExecutionHost;

  bool get canMutateAttachedRuntime => _runtimeSessionIdForMutation() != null;

  /// A Desktop-owned shared turn can be detached from this phone, but it must
  /// never be presented as an interruptible Bridge-owned process.
  bool get stopActionDetachesDesktopTurn =>
      isCodex &&
      detachedPreview &&
      state.externalDesktopTurnActive &&
      _detachedExecutionHost == 'desktopAppServer' &&
      _hasCurrentDetachedAuthorityLease &&
      _bridge.bridgeCapabilities.contains(codexRuntimeDetachCapability);

  CodexSettingsActionability get codexSettingsActionability {
    if (!isCodex || !detachedPreview) {
      return CodexSettingsActionability.editable;
    }
    if (_canBuildDurableSettingsMutationTarget) {
      return CodexSettingsActionability.editable;
    }
    if (state.externalDesktopTurnActive ||
        _detachedExecutionHost == 'desktopAppServer') {
      return CodexSettingsActionability.readOnlyDesktopOwner;
    }
    if (_detachedLiveRuntimeSessionId == null || !_detachedAuthorityObserved) {
      return CodexSettingsActionability.waitingForRuntime;
    }
    final runtimeSessionId = _runtimeSessionIdForMutation(
      allowSteerable: false,
    );
    if (runtimeSessionId != null &&
        _canBuildDetachedSettingsMutationTarget(runtimeSessionId)) {
      return CodexSettingsActionability.editable;
    }
    return CodexSettingsActionability.unavailable;
  }

  bool get codexModelSettingsKnown =>
      !isCodex ||
      !detachedPreview ||
      (state.codexModel?.trim().isNotEmpty == true &&
          state.codexModelReasoningEffort != null);

  bool get codexPlanModeKnown =>
      !isCodex || !detachedPreview || state.codexPermissionStateKnown;

  String get _projectionThreadToken =>
      diagnosticToken(provider?.value ?? 'unknown', sessionId);

  String _projectionSourceToken(String? sourceFingerprint) {
    final normalized = sourceFingerprint?.trim();
    return normalized == null || normalized.isEmpty
        ? 'none'
        : diagnosticToken('source', normalized);
  }

  bool _allowCodexSettingsMutation() {
    if (!isCodex ||
        codexSettingsActionability == CodexSettingsActionability.editable) {
      return true;
    }
    logger.warning(
      '[session:$sessionId] ignored Codex settings mutation: '
      '${codexSettingsActionability.name}',
    );
    return false;
  }

  String? get runtimeSessionIdForRead =>
      detachedPreview ? _detachedLiveRuntimeSessionId : sessionId;

  String? runtimeSessionIdForMutation({bool allowSteerable = true}) =>
      _runtimeSessionIdForMutation(allowSteerable: allowSteerable);

  String? _runtimeSessionIdForMutation({bool allowSteerable = true}) {
    if (!detachedPreview) return sessionId;
    final runtimeSessionId = _detachedLiveRuntimeSessionId;
    if (runtimeSessionId == null) return null;
    final supportsExactAuthority = _bridge.bridgeCapabilities.contains(
      conversationSyncV2Capability,
    );
    if (!_detachedAuthorityObserved) {
      return supportsExactAuthority ? null : runtimeSessionId;
    }
    if (supportsExactAuthority) {
      if (!_hasCurrentDetachedAuthorityLease) return null;
      if (_detachedControlState == 'writable') return runtimeSessionId;
      final executionHost = _detachedExecutionHost;
      final hostIsProven =
          executionHost == 'bridge' || executionHost == 'desktopAppServer';
      if (allowSteerable &&
          _detachedControlState == 'steerable' &&
          hostIsProven &&
          _detachedActiveTurnId?.isNotEmpty == true) {
        return runtimeSessionId;
      }
      return null;
    }
    if (_detachedExecutionHost == 'unknown') return null;
    return switch (_detachedControlState) {
      null
          when _detachedExecutionHost == null &&
              !state.externalDesktopTurnActive =>
        runtimeSessionId,
      'writable' => runtimeSessionId,
      'steerable' when allowSteerable => runtimeSessionId,
      _ => null,
    };
  }

  bool get _hasCurrentDetachedAuthorityLease {
    final authorityGeneration = _detachedAuthorityGeneration;
    final authoritySource = _detachedAuthoritySourceFingerprint;
    return _detachedProviderProjectionCurrent &&
        _detachedAuthorityObserved &&
        _detachedLiveRuntimeSessionId != null &&
        authorityGeneration != null &&
        authorityGeneration.isNotEmpty &&
        authoritySource != null &&
        authoritySource.isNotEmpty &&
        _detachedAuthorityLiveRuntimeGeneration ==
            _detachedLiveRuntimeGeneration &&
        authoritySource == _detachedProviderSourceFingerprint;
  }

  bool _canBuildDetachedSettingsMutationTarget(String runtimeSessionId) {
    final codexSourceId = _bridge.codexSourceId?.trim();
    final authorityGeneration = _detachedAuthorityGeneration?.trim();
    return detachedPreview &&
        _bridge.isConnected &&
        _bridge.hasAuthoritativeSessionListForCurrentConnection &&
        _hasCurrentDetachedAuthorityLease &&
        runtimeSessionId == _detachedLiveRuntimeSessionId &&
        codexSourceId != null &&
        codexSourceId.isNotEmpty &&
        authorityGeneration != null &&
        authorityGeneration.isNotEmpty;
  }

  bool get _canBuildDurableSettingsMutationTarget {
    final codexSourceId = _bridge.codexSourceId?.trim();
    final sourceFingerprint = _detachedProviderSourceFingerprint?.trim();
    return detachedPreview &&
        _detachedProviderProjectionCurrent &&
        _bridge.bridgeCapabilities.contains(
          codexDurableThreadSettingsCapability,
        ) &&
        _bridge.isConnected &&
        _bridge.hasAuthoritativeSessionListForCurrentConnection &&
        codexSourceId != null &&
        codexSourceId.isNotEmpty &&
        sourceFingerprint != null &&
        sourceFingerprint.isNotEmpty;
  }

  String? _runtimeSessionIdForSettingsMutation() {
    if (!detachedPreview) return sessionId;
    if (_canBuildDurableSettingsMutationTarget) return sessionId;
    return _runtimeSessionIdForMutation(allowSteerable: false);
  }

  CodexSettingsMutationTarget? _detachedSettingsMutationTarget(
    String runtimeSessionId,
  ) {
    if (!detachedPreview) return null;
    if (_canBuildDurableSettingsMutationTarget) {
      return CodexSettingsMutationTarget.durableThread(
        codexSourceId: _bridge.codexSourceId!.trim(),
        threadId: sessionId,
        operationId: _uuid.v4(),
      );
    }
    if (!_canBuildDetachedSettingsMutationTarget(runtimeSessionId)) {
      logger.warning(
        '[session:$sessionId] ignored detached settings mutation: '
        'incomplete authority envelope',
      );
      return null;
    }
    return CodexSettingsMutationTarget(
      codexSourceId: _bridge.codexSourceId!.trim(),
      threadId: sessionId,
      runtimeSessionId: runtimeSessionId,
      authorityGeneration: _detachedAuthorityGeneration!.trim(),
      operationId: _uuid.v4(),
    );
  }

  _RuntimeMutationLease? _captureRuntimeMutationLease({
    bool allowSteerable = true,
  }) {
    final runtimeSessionId = _runtimeSessionIdForMutation(
      allowSteerable: allowSteerable,
    );
    if (runtimeSessionId == null) return null;
    return _RuntimeMutationLease(
      sessionId: runtimeSessionId,
      detached: detachedPreview,
      liveRuntimeGeneration: _detachedLiveRuntimeGeneration,
      sourceFingerprint: _detachedProviderSourceFingerprint,
      authorityGeneration: _detachedAuthorityGeneration,
    );
  }

  bool _isRuntimeMutationLeaseCurrent(
    _RuntimeMutationLease lease, {
    bool allowSteerable = true,
  }) {
    if (lease.sessionId !=
        _runtimeSessionIdForMutation(allowSteerable: allowSteerable)) {
      return false;
    }
    if (!lease.detached) return true;
    return lease.liveRuntimeGeneration == _detachedLiveRuntimeGeneration &&
        lease.sourceFingerprint == _detachedProviderSourceFingerprint &&
        lease.authorityGeneration == _detachedAuthorityGeneration;
  }

  void _requireCurrentRuntimeMutationLease(_RuntimeMutationLease lease) {
    if (!_isRuntimeMutationLeaseCurrent(lease)) {
      throw const _ExpiredRuntimeMutationLease();
    }
  }

  bool _matchesBoundSessionId(String? candidate) {
    if (candidate == null) return true;
    return candidate == sessionId || candidate == _detachedLiveRuntimeSessionId;
  }

  StreamSubscription<ServerMessage>? _subscription;
  StreamSubscription<ServerMessage>? _detachedSettingsSubscription;
  StreamSubscription<BridgeConnectionState>? _goalConnectionSubscription;
  StreamSubscription<List<SessionInfo>>? _goalSessionListSubscription;
  StreamSubscription<List<SessionInfo>>? _runtimeSnapshotSubscription;
  StreamSubscription<int>? _codexModelCatalogSubscription;
  StreamSubscription<LocalSessionHistoryAvailabilityChange>?
  _localHistoryAvailabilitySubscription;
  StreamSubscription<String>? _historySyncSubscription;
  StreamSubscription<BridgeConnectionState>?
  _statusRefreshConnectionSubscription;
  StreamSubscription<LocalFeatureServerMessage>? _desktopContinuitySubscription;
  StreamSubscription<BridgeConnectionState>?
  _desktopContinuityConnectionSubscription;
  bool _pastHistoryLoaded = false;
  bool _historyBootstrapSucceeded = false;
  bool _historyFallbackRequested = false;
  bool _historyBootstrapInFlight = false;
  bool _statusHistoryBootstrapGraceUsed = false;
  bool _statusHistoryWaitingForReconnect = false;
  int _statusHistoryRetryAttempt = 0;
  // SessionInfo is the live session-list authority, while HistoryMessage is a
  // rebuildable transcript. Track authority per optional field so an older
  // Bridge can still fill omissions without letting stale init rows rebind a
  // newer Codex thread or toolbar configuration.
  bool _hasAuthoritativeSessionSnapshot = false;
  bool _sessionSnapshotOwnsThreadId = false;
  bool _sessionSnapshotOwnsProjectPath = false;
  bool _sessionSnapshotOwnsModel = false;
  bool _sessionSnapshotOwnsEffort = false;
  bool _sessionSnapshotOwnsSpeed = false;
  bool _statusFromHistoryFallback = false;
  bool _statusFromSessionSnapshot = false;
  bool _statusFromLiveMessage = false;
  DateTime? _detachedProviderStatusObservedAt;
  String? _detachedProviderStatusSignature;
  String? _detachedProviderSourceFingerprint;
  DateTime? _detachedProviderSettingsObservedAt;
  String? _detachedProviderSettingsSignature;
  bool _detachedProviderOwnsModel = false;
  bool _detachedProviderOwnsEffort = false;
  bool _detachedProviderOwnsSpeed = false;
  bool _awaitingFreshSessionListAfterReconnect = false;
  int _sessionListGenerationAtDisconnect = 0;
  int _lastConsumedSessionListGeneration = 0;
  Timer? _statusRefreshTimer;
  Timer? _goalMutationTimer;
  Timer? _goalReadTimer;
  Timer? _desktopContinuityReconcileTimer;
  Timer? _desktopContinuityWatchAckTimer;
  Timer? _desktopContinuityRetryTimer;
  int _desktopContinuityRetryAttempt = 0;
  bool _goalReadPending = false;
  bool _goalReadAwaitingThread = false;
  bool _goalUserRefreshPending = false;
  bool _codexGoalThreadReady = false;
  final Map<String, QueuedInputItem> _deliveryPendingInputs = {};
  Future<void> _inputDispatchTail = Future<void>.value();
  int _pendingInputDispatchCount = 0;
  final Set<String> _pendingInputDispatchIds = {};
  final Set<String> _canceledInputDispatchIds = {};
  final Set<String> _desktopContinuityItemKeys = {};
  final Set<String> _restoredDesktopContinuityItemKeys = {};
  final Map<String, ChatMessageHandler> _desktopContinuityHandlers = {};
  String? _restoredDesktopContinuityThreadId;
  String? _desktopContinuityStreamingTurnKey;
  String? _desktopContinuityRequestId;
  String? _desktopContinuityThreadId;
  String? _desktopContinuityProjectPath;
  String? _desktopContinuitySuppressedThreadId;
  final ValueNotifier<int> codexModelCatalogRevision = ValueNotifier(0);
  String? _desktopContinuitySuppressedProjectPath;
  bool _desktopContinuityWasExternalBeforeDisconnect = false;

  /// Exact service tier reported by the active runtime. Unknown future values
  /// remain visible read-only while [ChatSessionState.codexSpeed] carries the
  /// bounded UI behavior (`standard`, `fast`, or `unknown`).
  final ValueNotifier<String?> codexServiceTierRaw = ValueNotifier(null);

  /// Whether the current Desktop-continuity turn is owned by the runtime
  /// session bound to this screen and can therefore accept turn/steer.
  ///
  /// Old Bridge versions omit this additive proof, so the safe default is
  /// false even when a unique external turn ID is visible.
  final ValueNotifier<bool> externalDesktopTurnSteerable = ValueNotifier(false);

  /// Number of entries prepended from past_history, so that [replaceEntries]
  /// can preserve them while replacing in-memory history entries.
  int _pastEntryCount = 0;

  int _localHistoryPagingGeneration = 0;
  int _localMirrorEntryCount = 0;
  final Expando<int> _localHistoryOrdinalByNavigationEntry = Expando<int>(
    'localHistoryOrdinal',
  );
  final Expando<String> _targetHistoryTurnByEntry = Expando<String>(
    'targetHistoryTurn',
  );
  bool _discardLocalMirrorOnNextCanonicalHistory = false;
  final ValueNotifier<LocalHistoryPagingState> localHistoryPaging =
      ValueNotifier(const LocalHistoryPagingState());
  final DetachedHistoryPageLoader? _detachedHistoryPageLoader;
  DetachedHistoryToolDetailLoader? _detachedHistoryToolDetailLoader;
  DetachedUserMessageIndexLoader? _detachedUserMessageIndexLoader;
  DetachedUserTurnLoader? _detachedUserTurnLoader;
  final Map<String, int> _providerTurnOrderById = {};
  final ValueNotifier<bool> historySyncing = ValueNotifier(false);
  final ValueNotifier<int> historyToolDetailRevision = ValueNotifier(0);
  final Map<String, HistoryToolDetailLoadState> _historyToolDetailStates = {};
  final Map<String, Future<bool>> _historyToolDetailFlights = {};
  final ValueNotifier<int> localHistoryIndexRevision = ValueNotifier(0);
  bool _localHistoryUserIndexComplete = false;

  bool get localHistoryUserIndexComplete => _localHistoryUserIndexComplete;

  /// Rebinds source- and revision-scoped durable history loaders without
  /// replacing the mounted chat Cubit.
  ///
  /// A durable route intentionally keeps one Cubit alive to preserve draft,
  /// scroll and disclosure state. Consequently the closures captured by its
  /// constructor must be refreshed when authentication canonicalizes the
  /// source or a newer content revision commits; otherwise history navigation
  /// keeps querying the revision that was current when the page first opened.
  void updateDetachedHistoryLoaders({
    DetachedHistoryToolDetailLoader? toolDetailLoader,
    DetachedUserMessageIndexLoader? userMessageIndexLoader,
    DetachedUserTurnLoader? userTurnLoader,
  }) {
    if (!detachedPreview || isClosed) return;
    _detachedHistoryToolDetailLoader = toolDetailLoader;
    _detachedUserMessageIndexLoader = userMessageIndexLoader;
    _detachedUserTurnLoader = userTurnLoader;
    _localHistoryUserIndexComplete = false;
    _providerTurnOrderById.clear();
    localHistoryIndexRevision.value += 1;
  }

  /// Tool use IDs that have already been answered locally.
  static const _maxRespondedToolUseIds = 512;
  static const _maxDismissedCodexWarnings = 64;
  final _respondedToolUseIds = <String>{};
  final _dismissedCodexWarningKeys = <String>{};
  final Map<String, PermissionRequestMessage> _pendingPermissionRequests = {};

  void _markToolUseResponded(String toolUseId) {
    _bridge.markToolUseResponded(
      runtimeSessionIdForRead ?? sessionId,
      toolUseId,
    );
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
  bool? _pendingCodexPermissionStateKnownRollback;
  bool? _pendingPlanRollback;
  SandboxMode? _pendingSandboxRollback;
  bool _pendingCodexModelMutation = false;
  String? _pendingCodexModelRollback;
  ReasoningEffort? _pendingCodexEffortRollback;
  bool _pendingCodexSpeedMutation = false;
  CodexSpeed? _pendingCodexSpeedRollback;
  String? _pendingCodexServiceTierRollback;
  String? _pendingPermissionChangeId;
  ProcessStatus? _pendingPermissionRestartStatusRollback;
  ApprovalState? _pendingPermissionRestartApprovalRollback;

  /// Whether this session is a Codex session.
  bool get isCodex => provider == Provider.codex;

  bool get isPermissionChangePending => _pendingPermissionChangeId != null;

  bool get isGoalMutationPending => state.goalMutation != null;

  bool get supportsAdvancedGoalControl => state.advancedGoalControlSupported;

  bool get bridgeSupportsCodexPermissionApplyStrategy => _bridge
      .bridgeCapabilities
      .contains(codexPermissionApplyStrategyCapability);

  bool get supportsCodexPermissionApplyStrategy {
    // The durable shared-writer contract always applies detached permission
    // changes to subsequent turns and does not require a transient runtime.
    if (_canBuildDurableSettingsMutationTarget) {
      return true;
    }
    if (!bridgeSupportsCodexPermissionApplyStrategy) {
      return false;
    }
    final runtimeSessionId = runtimeSessionIdForRead;
    return runtimeSessionId != null &&
        _bridge.sessions.any(
          (session) =>
              session.id == runtimeSessionId &&
              session.codexPermissionApplyStrategySupported,
        );
  }

  List<String> get codexModels => _bridge.codexModels;

  Map<String, List<String>> get codexModelReasoningEfforts =>
      _bridge.codexModelReasoningEfforts;

  Map<String, List<String>> get codexModelServiceTiers =>
      _bridge.codexModelServiceTiers;

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

  static String? queuedInputClientMessageId(QueuedInputItem? item) {
    if (item == null) return null;
    final explicit = item.clientMessageId?.trim();
    if (explicit != null && explicit.isNotEmpty) return explicit;
    return offlineQueuedClientMessageId(item) ??
        deliveryPendingClientMessageId(item);
  }

  QueuedInputItem? _mergeQueuedInputUpdate(
    QueuedInputItem? current,
    QueuedInputItem? incoming,
  ) {
    if (incoming == null) return current;
    if (current == null || !queuedInputItemsShareIdentity(current, incoming)) {
      return incoming;
    }
    return incoming.mergeDeliveryStateFrom(current);
  }

  void _setAuthoritativeQueuedInputs(
    List<QueuedInputItem> incoming,
    int limit,
  ) {
    final previous = queuedInputs.value;
    final merged = incoming
        .map((item) {
          for (final old in previous) {
            if (queuedInputItemsShareIdentity(old, item)) {
              return item.mergeDeliveryStateFrom(old);
            }
          }
          return item;
        })
        .toList(growable: false);
    _queuedInputLimit = limit < 1 ? 1 : limit;
    if (_sameQueuedInputList(previous, merged)) return;
    queuedInputs.value = List.unmodifiable(merged);
  }

  bool _sameQueuedInputList(
    List<QueuedInputItem> left,
    List<QueuedInputItem> right,
  ) {
    if (identical(left, right)) return true;
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }

  QueuedInputItem? _advanceQueuedInputDelivery(
    QueuedInputItem? item,
    String? clientMessageId,
    QueuedInputDeliveryStage stage, {
    String? error,
  }) {
    if (item == null ||
        clientMessageId == null ||
        queuedInputClientMessageId(item) != clientMessageId) {
      return item;
    }
    return item.withDeliveryStage(stage, error: error);
  }

  QueuedInputItem? _advanceAuthoritativeQueuedInputDelivery(
    String? clientMessageId,
    QueuedInputDeliveryStage stage, {
    String? error,
  }) {
    if (clientMessageId == null || queuedInputs.value.isEmpty) return null;
    var changed = false;
    final next = queuedInputs.value
        .map((item) {
          if (queuedInputClientMessageId(item) != clientMessageId) return item;
          final advanced = item.withDeliveryStage(stage, error: error);
          changed = changed || advanced != item;
          return advanced;
        })
        .toList(growable: false);
    if (changed) queuedInputs.value = List.unmodifiable(next);
    return next.isEmpty ? null : next.first;
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
    ChatImagePayloadEncoder? imagePayloadEncoder,
    this.detachedPreview = false,
    this.initialHistoryMessages = const [],
    String? initialLiveRuntimeSessionId,
    DetachedHistoryPageLoader? detachedHistoryPageLoader,
    DetachedHistoryToolDetailLoader? detachedHistoryToolDetailLoader,
    DetachedUserMessageIndexLoader? detachedUserMessageIndexLoader,
    DetachedUserTurnLoader? detachedUserTurnLoader,
    bool initialHistoryHasEarlier = false,
  }) : _bridge = bridge,
       _streamingCubit = streamingCubit,
       _detachedHistoryPageLoader = detachedHistoryPageLoader,
       _detachedHistoryToolDetailLoader = detachedHistoryToolDetailLoader,
       _detachedUserMessageIndexLoader = detachedUserMessageIndexLoader,
       _detachedUserTurnLoader = detachedUserTurnLoader,
       _imagePayloadEncoder =
           imagePayloadEncoder ?? _defaultChatImagePayloadEncoder,
       super(
         ChatSessionState(
           status: detachedPreview
               ? ProcessStatus.idle
               : ProcessStatus.starting,
           permissionMode: initialPermissionMode ?? PermissionMode.defaultMode,
           executionMode: deriveExecutionMode(
             provider: provider?.value,
             permissionMode: initialPermissionMode?.value,
           ),
           codexPermissionStateKnown:
               provider != Provider.codex ||
               initialPermissionMode != null ||
               initialCodexApprovalPolicy != null ||
               initialCodexApprovalsReviewer?.trim().isNotEmpty == true ||
               initialCodexPermissionsMode != null,
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
    if (detachedPreview) {
      localHistoryPaging.value = LocalHistoryPagingState(
        enabled: detachedHistoryPageLoader != null,
        hasMore: initialHistoryHasEarlier,
      );
      _restoreInitialHistoryMessages();
      updateDetachedLiveRuntime(initialLiveRuntimeSessionId);
      if (isCodex) {
        _detachedSettingsSubscription = _bridge
            .messagesForSession(sessionId)
            .where(_isDetachedSettingsResponse)
            .listen(_onMessage);
        codexModelCatalogRevision.value = _bridge.codexModelCatalogRevision;
        _codexModelCatalogSubscription = _bridge.codexModelCatalogChanges
            .listen((revision) => codexModelCatalogRevision.value = revision);
        _runtimeSnapshotSubscription = _bridge.sessionList.listen(
          _synchronizeDetachedCodexRuntimeSnapshot,
        );
        _synchronizeDetachedCodexRuntimeSnapshot(_bridge.sessions);
      }
      return;
    }
    _respondedToolUseIds.addAll(_bridge.respondedToolUseIds(sessionId));
    // Subscribe to messages for this session
    _subscription = _bridge.messagesForSession(sessionId).listen(_onMessage);
    _localHistoryAvailabilitySubscription = _bridge
        .sessionHistoryAvailabilityChanges
        .listen(_onLocalHistoryAvailabilityChanged);
    historySyncing.value = _bridge.isSessionHistorySyncing(sessionId);
    _historySyncSubscription = _bridge.sessionHistorySyncChanges.listen((
      changedSessionId,
    ) {
      if (changedSessionId != sessionId || isClosed) return;
      historySyncing.value = _bridge.isSessionHistorySyncing(sessionId);
    });
    _statusRefreshConnectionSubscription = _bridge.connectionStatus.listen(
      _onStatusRefreshConnectionState,
    );
    _runtimeSnapshotSubscription = _bridge.sessionList.listen(
      _synchronizeRuntimeSnapshot,
    );
    _synchronizeRuntimeSnapshot(_bridge.sessions);

    if (isCodex) {
      _goalConnectionSubscription = _bridge.connectionStatus.listen(
        _onGoalConnectionState,
      );
      _goalSessionListSubscription = _bridge.sessionList.listen(
        _updateCodexRuntimeSupportFromSessions,
      );
      _updateCodexRuntimeSupportFromSessions(_bridge.sessions);
      codexModelCatalogRevision.value = _bridge.codexModelCatalogRevision;
      _codexModelCatalogSubscription = _bridge.codexModelCatalogChanges.listen(
        (revision) => codexModelCatalogRevision.value = revision,
      );
      _desktopContinuitySubscription = _bridge
          .localFeatureMessagesForSession(sessionId)
          .listen(_onDesktopContinuityMessage);
      _desktopContinuityConnectionSubscription = _bridge.connectionStatus
          .listen(_onDesktopContinuityConnectionState);
    }

    final backgroundContinuity = isCodex
        ? _bridge.takeBackgroundDesktopContinuity(
            sessionId,
            threadId: state.claudeSessionId,
          )
        : null;
    _restoreCachedRuntimeMessages();
    if (backgroundContinuity != null) {
      _restoreBackgroundDesktopContinuity(backgroundContinuity);
    }
    _restoreDeliveryPendingInput();
    if (isCodex &&
        _bridge
            .cachedSessionMessages(sessionId)
            .any(
              (message) =>
                  message is SystemMessage && message.subtype == 'init',
            )) {
      final runtime = _runtimeSessionFrom(_bridge.sessions);
      if (runtime != null &&
          ProcessStatus.fromString(runtime.status) != ProcessStatus.starting &&
          state.claudeSessionId?.trim().isNotEmpty == true) {
        _codexGoalThreadReady = true;
      }
      requestGoal();
    }

    // Optional local mirrors get the first chance to render a reconstructable
    // snapshot. The unchanged path stays synchronous for official builds.
    if (_bridge.hasSessionHistoryBootstrap) {
      unawaited(_requestInitialHistory());
    } else {
      _historyFallbackRequested = true;
      _bridge.requestSessionHistory(sessionId);
    }

    // Re-query history while status is "starting" to handle lost broadcasts
    _startStatusRefreshTimer();
  }

  bool _isDetachedSettingsResponse(ServerMessage message) {
    if (message is SystemMessage) {
      return message.sessionId == sessionId &&
          message.provider == Provider.codex.value &&
          (message.subtype == 'set_permission_mode' ||
              message.subtype == 'set_codex_model' ||
              message.subtype == 'set_codex_speed');
    }
    if (message is! ErrorMessage || message.sessionId != sessionId) {
      return false;
    }
    final code = message.errorCode;
    return code == 'set_permission_mode_rejected' ||
        code == 'set_sandbox_mode_rejected' ||
        code == 'set_codex_model_rejected' ||
        code == 'set_codex_speed_rejected' ||
        code == 'codex_durable_thread_settings_unavailable' ||
        code == 'codex_durable_thread_settings_not_found' ||
        code == 'codex_shared_runtime_settings_stale_authority' ||
        code == 'codex_shared_runtime_settings_operation_conflict' ||
        code == 'codex_shared_runtime_settings_busy';
  }

  void _restoreInitialHistoryMessages() {
    updateDetachedPreviewHistory(initialHistoryMessages);
  }

  /// Rebinds only the live transport overlay of a durable conversation.
  ///
  /// Canonical history continues to arrive through the durable SQLite cache.
  /// Full history/snapshot frames from the runtime are therefore rejected here
  /// so a transient attachment cannot replace, duplicate, or reorder the
  /// cache-owned timeline.
  void updateDetachedLiveRuntime(String? runtimeSessionId) {
    if (!detachedPreview || isClosed) return;
    final normalized = runtimeSessionId?.trim();
    final next = normalized == null || normalized.isEmpty ? null : normalized;
    if (next == _detachedLiveRuntimeSessionId) return;

    final previousRuntimeSessionId = _detachedLiveRuntimeSessionId;
    final hasVisualTimeline =
        _handler.currentStreaming != null ||
        _streamingCubit.state.isStreaming ||
        _streamingCubit.state.text.isNotEmpty ||
        _streamingCubit.state.thinking.isNotEmpty ||
        state.entries.any((entry) => entry is StreamingChatEntry);
    if (hasVisualTimeline) {
      final activeTurnId = _detachedActiveTurnId?.trim();
      _detachedPreservedVisualTurnId = activeTurnId?.isNotEmpty == true
          ? activeTurnId
          : null;
      _detachedVisualTurnValidationPending = true;
      _detachedPendingVisualMessages.clear();
    } else {
      _detachedPreservedVisualTurnId = null;
      _detachedVisualTurnValidationPending = false;
      _detachedPendingVisualMessages.clear();
    }
    final generation = ++_detachedLiveRuntimeGeneration;
    unawaited(_subscription?.cancel());
    _subscription = null;
    _detachedLiveRuntimeSessionId = next;
    if (previousRuntimeSessionId != null &&
        previousRuntimeSessionId != next &&
        _detachedAuthorityGeneration != null) {
      _detachedRejectedAuthorityGeneration = _detachedAuthorityGeneration;
    }
    _clearDetachedRuntimeTransients(
      previousRuntimeSessionId,
      preserveProviderProjection: true,
      preserveVisualTimeline: true,
    );
    _detachedAuthorityObserved = false;
    _detachedExecutionHost = null;
    _detachedControlState = null;
    _detachedAuthorityGeneration = null;
    _detachedAuthorityLiveRuntimeGeneration = null;
    _detachedAuthoritySourceFingerprint = null;
    _detachedActiveTurnId = null;
    _detachedProviderStatusObservedAt = null;
    _detachedProviderStatusSignature = null;
    externalDesktopTurnSteerable.value = false;
    detachedLiveRuntimeRevision.value += 1;
    if (next == null) {
      _synchronizeDetachedCodexRuntimeSnapshot(_bridge.sessions);
      return;
    }

    _respondedToolUseIds.addAll(_bridge.respondedToolUseIds(next));
    _subscription = _bridge.messagesForSession(next).listen((message) {
      if (isClosed ||
          generation != _detachedLiveRuntimeGeneration ||
          _detachedLiveRuntimeSessionId != next) {
        return;
      }
      if (message is HistoryMessage ||
          message is PastHistoryMessage ||
          message is HistorySnapshotMessage ||
          message is HistoryDeltaMessage ||
          message is HistoryPageMessage ||
          message is HistoryToolDetailsMessage) {
        return;
      }
      if (_bufferDetachedVisualMessageUntilTurnValidation(message)) return;
      _onMessage(message);
    });
    _synchronizeDetachedCodexRuntimeSnapshot(_bridge.sessions);
  }

  void _clearDetachedRuntimeTransients(
    String? previousRuntimeSessionId, {
    bool preserveProviderProjection = false,
    bool preserveVisualTimeline = false,
  }) {
    if (previousRuntimeSessionId != null) {
      for (final item in _deliveryPendingInputs.values) {
        _bridge.clearDeliveryPendingInput(
          previousRuntimeSessionId,
          itemId: item.itemId,
        );
      }
    }
    _deliveryPendingInputs.clear();
    _setAuthoritativeQueuedInputs(const [], 1);
    _pendingPermissionRequests.clear();
    _clearPendingPermissionModeRollback(_pendingPermissionChangeId);
    _clearPendingCodexModelRollback();
    _clearPendingCodexSpeedRollback();
    if (!preserveVisualTimeline) {
      _resetDetachedVisualTimelineInternals();
    }
    final durableEntries = preserveVisualTimeline
        ? state.entries
        : state.entries
              .where((entry) => entry is! StreamingChatEntry)
              .toList(growable: false);
    emit(
      state.copyWith(
        entries: durableEntries,
        status:
            preserveProviderProjection &&
                _detachedProviderProjectionCurrent &&
                state.status != ProcessStatus.waitingApproval
            ? state.status
            : ProcessStatus.unknown,
        approval: const ApprovalState.none(),
        queuedInput: null,
        externalDesktopTurnActive: false,
        externalDesktopTurnId: null,
      ),
    );
  }

  bool _bufferDetachedVisualMessageUntilTurnValidation(ServerMessage message) {
    if (!_detachedVisualTurnValidationPending ||
        (message is! StreamDeltaMessage && message is! ThinkingDeltaMessage)) {
      return false;
    }
    if (_detachedPendingVisualMessages.length >=
        _maxDetachedVisualPendingMessages) {
      final buffered = List<ServerMessage>.of(_detachedPendingVisualMessages)
        ..add(message);
      _clearDetachedVisualTimeline();
      for (final pending in buffered) {
        if (isClosed) return true;
        _onMessage(pending);
      }
      return true;
    }
    _detachedPendingVisualMessages.add(message);
    return true;
  }

  void _validateDetachedVisualTurn({
    required bool active,
    required String result,
    required String? activeTurnId,
  }) {
    if (!_detachedVisualTurnValidationPending) return;
    final normalizedTurnId = activeTurnId?.trim();
    final hasTurnId = normalizedTurnId?.isNotEmpty == true;
    if (active && result == 'none' && !hasTurnId) {
      // The status is still incomplete. Keep the old visual surface isolated
      // and continue buffering only deltas until an exact turn or terminal
      // state arrives.
      return;
    }
    final preservedTurnId = _detachedPreservedVisualTurnId;
    final sameTurn =
        active &&
        result == 'none' &&
        // A missing old turn id is lack of evidence, not proof that a later
        // authoritative active id belongs to a different turn. Preserve the
        // visible live surface unless two known ids conflict or the provider
        // reports a terminal state.
        (preservedTurnId == null || preservedTurnId == normalizedTurnId);
    final buffered = List<ServerMessage>.of(_detachedPendingVisualMessages);
    if (!sameTurn) _clearDetachedVisualTimeline();
    _detachedPreservedVisualTurnId = null;
    _detachedVisualTurnValidationPending = false;
    _detachedPendingVisualMessages.clear();
    if (!active || result != 'none') return;
    for (final pending in buffered) {
      if (isClosed) return;
      _onMessage(pending);
    }
  }

  void _resetDetachedVisualTimelineInternals() {
    _handler.currentStreaming = null;
    _streamingCubit.reset();
    _desktopContinuityHandlers.clear();
    _desktopContinuityItemKeys.clear();
    _restoredDesktopContinuityItemKeys.clear();
    _desktopContinuityStreamingTurnKey = null;
    _detachedPreservedVisualTurnId = null;
    _detachedVisualTurnValidationPending = false;
    _detachedPendingVisualMessages.clear();
  }

  void _clearDetachedVisualTimeline() {
    _resetDetachedVisualTimelineInternals();
    final durableEntries = state.entries
        .where((entry) => entry is! StreamingChatEntry)
        .toList(growable: false);
    if (durableEntries.length != state.entries.length) {
      emit(state.copyWith(entries: durableEntries));
    }
  }

  /// Reconciles a newer durable cache snapshot without recreating the screen
  /// or its disclosure/scroll state.
  void updateDetachedPreviewHistory(
    List<ServerMessage> messages, {
    bool? hasEarlier,
  }) {
    if (!detachedPreview || isClosed) return;
    if (hasEarlier != null && _detachedHistoryPageLoader != null) {
      localHistoryPaging.value = localHistoryPaging.value.copyWith(
        enabled: true,
        hasMore: hasEarlier,
        loading: false,
        clearError: true,
      );
    }
    // An empty cache row does not currently carry enough provenance to
    // distinguish stale durable entries from accepted live/optimistic entries.
    // Keep the visible projection until the cache protocol supplies that fence.
    if (messages.isEmpty) return;
    try {
      final history = HistoryMessage(messages: messages);
      final update = _handler.handle(
        history,
        isBackground: true,
        isCodex: isCodex,
        ignoredToolUseIds: const {},
      );
      _applyUpdate(update, history);
      if (state.status == ProcessStatus.starting) {
        emit(state.copyWith(status: ProcessStatus.idle));
      }
    } catch (error, stackTrace) {
      logger.warning(
        '[session:$sessionId] Failed to decode durable cached history',
        error,
        stackTrace,
      );
    }
  }

  /// Projects the already committed conversation-sync status into a detached
  /// durable view without resuming the provider thread or acquiring writer
  /// ownership. Source identity is enforced by the cache partition upstream;
  /// the durable provider identity and observed time are fenced again here.
  void updateDetachedProviderStatus(
    ConversationSyncV2Status? status, {
    String? sourceFingerprint,
  }) {
    if (!detachedPreview || isClosed) return;
    final sourceChanged = _adoptDetachedProviderSource(sourceFingerprint);
    if (status == null) {
      final authorityChanged =
          _detachedAuthorityObserved ||
          _detachedExecutionHost != null ||
          _detachedControlState != null ||
          _detachedAuthorityGeneration != null ||
          _detachedAuthorityLiveRuntimeGeneration != null ||
          _detachedAuthoritySourceFingerprint != null ||
          _detachedActiveTurnId != null;
      _detachedAuthorityObserved = false;
      _detachedExecutionHost = null;
      _detachedControlState = null;
      _detachedAuthorityGeneration = null;
      _detachedAuthorityLiveRuntimeGeneration = null;
      _detachedAuthoritySourceFingerprint = null;
      _detachedActiveTurnId = null;
      if (authorityChanged && !sourceChanged) {
        detachedLiveRuntimeRevision.value += 1;
      }
      if (sourceChanged || _detachedProviderStatusObservedAt != null) {
        _detachedProviderStatusObservedAt = null;
        _detachedProviderStatusSignature = null;
        externalDesktopTurnSteerable.value = false;
        final current = sourceChanged
            ? _stateWithoutDetachedProviderSettings(state)
            : state;
        emit(
          current.copyWith(
            status: ProcessStatus.unknown,
            externalDesktopTurnActive: false,
            externalDesktopTurnId: null,
          ),
        );
      }
      return;
    }
    if (status.providerSessionId != sessionId ||
        (provider != null && status.provider != provider!.value)) {
      return;
    }
    final observedAt = DateTime.tryParse(status.observedAt)?.toUtc();
    if (observedAt == null) return;
    _detachedProviderProjectionCurrent = true;
    final previousObservedAt = _detachedProviderStatusObservedAt;
    if (previousObservedAt != null && observedAt.isBefore(previousObservedAt)) {
      return;
    }
    final signature = [
      status.activity,
      status.attention,
      status.result,
      status.runtimeAttachment,
      status.source,
      status.confidence,
      status.observedAt,
      status.attentionRequestId ?? '',
      status.executionHost ?? '',
      status.activeTurnId ?? '',
      status.controlState ?? '',
      status.authorityGeneration ?? '',
    ].join('\u0000');
    if (previousObservedAt == observedAt &&
        signature == _detachedProviderStatusSignature) {
      return;
    }

    final nextStatus = status.attention != 'none'
        ? ProcessStatus.waitingApproval
        : switch (status.activity) {
            'working' => ProcessStatus.running,
            'compacting' => ProcessStatus.compacting,
            'idle' => ProcessStatus.idle,
            _ => ProcessStatus.unknown,
          };
    final active =
        status.activity == 'working' || status.activity == 'compacting';
    final executionHost = status.executionHost;
    final authorityGeneration = status.authorityGeneration?.trim();
    final replaysRejectedAuthority =
        authorityGeneration?.isNotEmpty == true &&
        authorityGeneration == _detachedRejectedAuthorityGeneration;
    _detachedAuthorityObserved = !replaysRejectedAuthority;
    _detachedExecutionHost = replaysRejectedAuthority ? null : executionHost;
    _detachedControlState = replaysRejectedAuthority
        ? null
        : status.controlState;
    _detachedAuthorityGeneration = replaysRejectedAuthority
        ? null
        : authorityGeneration;
    _detachedAuthorityLiveRuntimeGeneration = replaysRejectedAuthority
        ? null
        : _detachedLiveRuntimeGeneration;
    _detachedAuthoritySourceFingerprint = replaysRejectedAuthority
        ? null
        : _detachedProviderSourceFingerprint;
    if (!replaysRejectedAuthority && authorityGeneration?.isNotEmpty == true) {
      _detachedRejectedAuthorityGeneration = null;
    }
    final usesLegacyHostFallback = executionHost == null;
    final externallyOwnedCodexTurn =
        isCodex &&
        active &&
        (usesLegacyHostFallback
            ? status.source != 'bridgeRuntime'
            : executionHost == 'desktopAppServer');
    final activeTurnId = status.activeTurnId?.trim();
    final hasActiveTurnId = activeTurnId?.isNotEmpty == true;
    if (!replaysRejectedAuthority) {
      _validateDetachedVisualTurn(
        active: active,
        result: status.result,
        activeTurnId: activeTurnId,
      );
    }
    _detachedActiveTurnId = replaysRejectedAuthority || !hasActiveTurnId
        ? null
        : activeTurnId;
    final exactAuthority = _hasCurrentDetachedAuthorityLease;
    final hostIsProven =
        executionHost == 'bridge' || executionHost == 'desktopAppServer';
    final controllable =
        !replaysRejectedAuthority &&
        exactAuthority &&
        hostIsProven &&
        hasActiveTurnId &&
        status.controlState == 'steerable';
    _detachedProviderStatusObservedAt = observedAt;
    _detachedProviderStatusSignature = signature;
    externalDesktopTurnSteerable.value =
        externallyOwnedCodexTurn && controllable;
    detachedLiveRuntimeRevision.value += 1;
    final current = sourceChanged
        ? _stateWithoutDetachedProviderSettings(state)
        : state;
    emit(
      current.copyWith(
        status: nextStatus,
        externalDesktopTurnActive: externallyOwnedCodexTurn,
        externalDesktopTurnId: externallyOwnedCodexTurn && hasActiveTurnId
            ? activeTurnId
            : null,
      ),
    );
    logger.info(
      '[status_projection] event=status_applied '
      'thread=$_projectionThreadToken '
      'source=${_projectionSourceToken(_detachedProviderSourceFingerprint)} '
      'activity=${status.activity} attention=${status.attention} '
      'host=${status.executionHost ?? 'unknown'} '
      'control=${status.controlState ?? 'unknown'} '
      'authority=${authorityGeneration?.isNotEmpty == true} '
      'current=$_detachedProviderProjectionCurrent',
    );
  }

  /// Hydrates factual model settings for a detached Codex thread from the
  /// source-scoped durable catalog. Missing fields remain unknown instead of
  /// being fabricated from the new-session defaults.
  void updateDetachedProviderSettings(
    RecentSession? session, {
    String? sourceFingerprint,
  }) {
    if (!detachedPreview || !isCodex || isClosed) return;
    final sourceChanged = _adoptDetachedProviderSource(sourceFingerprint);
    if (session == null) {
      if (sourceChanged) _clearDetachedProviderSettings();
      return;
    }
    if (session.sessionId != sessionId ||
        session.provider != Provider.codex.value) {
      return;
    }
    final observedAt = DateTime.tryParse(session.modified)?.toUtc();
    if (observedAt == null) return;
    _detachedProviderProjectionCurrent = true;
    final previousObservedAt = _detachedProviderSettingsObservedAt;
    if (previousObservedAt != null && observedAt.isBefore(previousObservedAt)) {
      return;
    }
    final model = session.codexModel?.trim();
    final effort = reasoningEffortByValue(session.codexModelReasoningEffort);
    final serviceTier = session.codexServiceTier?.trim();
    final rawPermissionMode = session.rawPermissionMode?.trim();
    PermissionMode? parsedPermissionMode;
    for (final mode in PermissionMode.values) {
      if (mode.value == rawPermissionMode) {
        parsedPermissionMode = mode;
        break;
      }
    }
    final approvalPolicy = codexApprovalPolicyFromRaw(
      session.codexApprovalPolicy,
    );
    final approvalsReviewer = session.codexApprovalsReviewer?.trim();
    final permissionsMode = codexPermissionsModeFromRaw(
      session.codexPermissionsMode,
    );
    final sandboxMode = switch (session.codexSandboxMode) {
      'danger-full-access' || 'off' => SandboxMode.off,
      'workspace-write' || 'read-only' || 'on' => SandboxMode.on,
      _ => null,
    };
    final collaborationMode = session.codexCollaborationMode?.trim();
    final isCompleteSnapshot = session.codexSettingsSnapshotComplete;
    final legacyHasPermissionFacts =
        parsedPermissionMode != null ||
        approvalPolicy != null ||
        approvalsReviewer?.isNotEmpty == true ||
        permissionsMode != null;
    final hasCompletePermissionTuple =
        approvalPolicy != null &&
        sandboxMode != null &&
        (collaborationMode == 'plan' || collaborationMode == 'default');
    final hasPermissionFacts = isCompleteSnapshot
        ? hasCompletePermissionTuple
        : legacyHasPermissionFacts;
    PermissionMode? derivedPermissionMode = parsedPermissionMode;
    if (derivedPermissionMode == null && hasPermissionFacts) {
      final derivedRaw = session.permissionMode;
      for (final mode in PermissionMode.values) {
        if (mode.value == derivedRaw) {
          derivedPermissionMode = mode;
          break;
        }
      }
    }
    final derivedPermissionsMode =
        permissionsMode ??
        (hasPermissionFacts
            ? codexPermissionsModeFromSettings(
                approvalPolicy: approvalPolicy?.value,
                approvalsReviewer: approvalsReviewer,
                sandboxMode: session.codexSandboxMode,
              )
            : null);
    final derivedApprovalPolicy =
        approvalPolicy ??
        (derivedPermissionsMode == null
            ? null
            : approvalPolicyForCodexPermissionsMode(derivedPermissionsMode));
    final derivedApprovalsReviewer = approvalsReviewer?.isNotEmpty == true
        ? approvalsReviewer
        : (derivedPermissionsMode == null
              ? null
              : approvalsReviewerForCodexPermissionsMode(
                  derivedPermissionsMode,
                ));
    final derivedSandboxMode =
        sandboxMode ??
        (derivedPermissionsMode == null
            ? null
            : sandboxModeForCodexPermissionsMode(derivedPermissionsMode));
    final signature = [
      model ?? '',
      effort?.value ?? '',
      serviceTier ?? '',
      rawPermissionMode ?? '',
      approvalPolicy?.value ?? '',
      approvalsReviewer ?? '',
      permissionsMode?.value ?? '',
      session.codexSandboxMode ?? '',
      collaborationMode ?? '',
      isCompleteSnapshot,
      session.planMode,
      session.modified,
    ].join('\u0000');
    if (previousObservedAt == observedAt &&
        _detachedProviderSettingsSignature == signature) {
      return;
    }
    _detachedProviderSettingsObservedAt = observedAt;
    _detachedProviderSettingsSignature = signature;
    _detachedProviderOwnsModel =
        isCompleteSnapshot || model?.isNotEmpty == true;
    _detachedProviderOwnsEffort = isCompleteSnapshot || effort != null;
    _detachedProviderOwnsSpeed =
        isCompleteSnapshot || (serviceTier != null && serviceTier.isNotEmpty);

    final nextSpeed = codexRuntimeSpeedFromRaw(serviceTier);
    if (serviceTier != null && serviceTier.isNotEmpty) {
      codexServiceTierRaw.value = serviceTier;
    } else if (isCompleteSnapshot) {
      codexServiceTierRaw.value = null;
    }
    final resetMissingFacts = sourceChanged || isCompleteSnapshot;
    final projectedPlanMode = collaborationMode == 'plan'
        ? true
        : collaborationMode == 'default'
        ? false
        : session.resolvedPlanMode;
    emit(
      state.copyWith(
        permissionMode: hasPermissionFacts
            ? (derivedPermissionMode ?? PermissionMode.defaultMode)
            : (resetMissingFacts
                  ? PermissionMode.defaultMode
                  : state.permissionMode),
        executionMode: hasPermissionFacts
            ? session.resolvedExecutionMode
            : (resetMissingFacts
                  ? ExecutionMode.defaultMode
                  : state.executionMode),
        codexPermissionStateKnown:
            hasPermissionFacts ||
            (!resetMissingFacts && state.codexPermissionStateKnown),
        codexApprovalPolicy: hasPermissionFacts
            ? (derivedApprovalPolicy ?? CodexApprovalPolicy.onRequest)
            : (resetMissingFacts
                  ? CodexApprovalPolicy.onRequest
                  : state.codexApprovalPolicy),
        codexApprovalsReviewer: hasPermissionFacts
            ? (derivedApprovalsReviewer ?? 'user')
            : (resetMissingFacts ? 'user' : state.codexApprovalsReviewer),
        codexPermissionsMode: hasPermissionFacts
            ? (derivedPermissionsMode ?? CodexPermissionsMode.custom)
            : (resetMissingFacts
                  ? CodexPermissionsMode.defaultPermissions
                  : state.codexPermissionsMode),
        sandboxMode: hasPermissionFacts
            ? (derivedSandboxMode ?? SandboxMode.on)
            : (resetMissingFacts ? SandboxMode.on : state.sandboxMode),
        planMode: hasPermissionFacts
            ? projectedPlanMode
            : (resetMissingFacts ? false : state.planMode),
        inPlanMode: hasPermissionFacts
            ? projectedPlanMode
            : (resetMissingFacts ? false : state.inPlanMode),
        codexModel: model == null || model.isEmpty
            ? resetMissingFacts
                  ? null
                  : state.codexModel
            : model,
        codexModelReasoningEffort:
            effort ??
            (resetMissingFacts ? null : state.codexModelReasoningEffort),
        codexSpeed: nextSpeed == null || nextSpeed == CodexSpeed.unknown
            ? resetMissingFacts
                  ? CodexSpeed.unknown
                  : state.codexSpeed
            : nextSpeed,
      ),
    );
    logger.info(
      '[settings_projection] event=settings_applied '
      'thread=$_projectionThreadToken '
      'source=${_projectionSourceToken(_detachedProviderSourceFingerprint)} '
      'complete=$isCompleteSnapshot '
      'model=${model?.isNotEmpty == true} '
      'effort=${effort?.value ?? 'unknown'} '
      'tier=${serviceTier?.isNotEmpty == true ? serviceTier : 'unknown'} '
      'permission=$hasPermissionFacts '
      'collaboration=${collaborationMode ?? 'unknown'} '
      'modelKnown=$codexModelSettingsKnown '
      'planKnown=$codexPlanModeKnown '
      'actionability=${codexSettingsActionability.name}',
    );
  }

  bool _adoptDetachedProviderSource(String? sourceFingerprint) {
    final normalized = sourceFingerprint?.trim();
    if (normalized == null || normalized.isEmpty) return false;
    if (_detachedProviderSourceFingerprint == normalized) return false;
    final previousSource = _detachedProviderSourceFingerprint;
    final firstAuthoritativeSource = previousSource == null;
    if (firstAuthoritativeSource && !_detachedVisualTurnValidationPending) {
      final hasVisualTimeline =
          _handler.currentStreaming != null ||
          _streamingCubit.state.isStreaming ||
          _streamingCubit.state.text.isNotEmpty ||
          _streamingCubit.state.thinking.isNotEmpty ||
          state.entries.any((entry) => entry is StreamingChatEntry);
      if (hasVisualTimeline) {
        final activeTurnId = _detachedActiveTurnId?.trim();
        _detachedPreservedVisualTurnId = activeTurnId?.isNotEmpty == true
            ? activeTurnId
            : null;
        _detachedVisualTurnValidationPending = true;
        _detachedPendingVisualMessages.clear();
      }
    }
    _clearDetachedRuntimeTransients(
      _detachedLiveRuntimeSessionId,
      // The first authoritative fingerprint confirms the provisional route;
      // it is not evidence that the already visible live stream came from a
      // different source. Two known, unequal fingerprints are a real source
      // replacement and still clear the old runtime projection.
      preserveVisualTimeline: firstAuthoritativeSource,
    );
    _detachedProviderSourceFingerprint = normalized;
    _detachedProviderStatusObservedAt = null;
    _detachedProviderStatusSignature = null;
    _detachedAuthorityObserved = false;
    _detachedExecutionHost = null;
    _detachedControlState = null;
    _detachedAuthorityGeneration = null;
    _detachedAuthorityLiveRuntimeGeneration = null;
    _detachedAuthoritySourceFingerprint = null;
    _detachedActiveTurnId = null;
    _detachedRejectedAuthorityGeneration = null;
    _detachedProviderProjectionCurrent = false;
    _detachedProviderSettingsObservedAt = null;
    _detachedProviderSettingsSignature = null;
    _detachedProviderOwnsModel = false;
    _detachedProviderOwnsEffort = false;
    _detachedProviderOwnsSpeed = false;
    codexServiceTierRaw.value = null;
    detachedLiveRuntimeRevision.value += 1;
    logger.info(
      '[settings_projection] event=source_changed '
      'thread=$_projectionThreadToken '
      'from=${_projectionSourceToken(previousSource)} '
      'to=${_projectionSourceToken(normalized)}',
    );
    return true;
  }

  /// Suspends mutations while the page's source partition is being
  /// re-authenticated without discarding already committed durable facts.
  ///
  /// Route aliases can briefly disagree with the canonical Bridge/source
  /// fingerprint during reconnect or IP changes. That transition must revoke
  /// runtime authority immediately, but it must not make model, effort,
  /// permissions, or provider activity flicker to unknown. A confirmed source
  /// mismatch invalidates live status separately after priority sync while
  /// the original source's durable settings remain visible but read-only.
  void suspendDetachedProviderProjection({
    String reason = 'source_reconciliation',
    String? observedSourceFingerprint,
    String? expectedSourceFingerprint,
    bool? catalogUsable,
  }) {
    if (!detachedPreview || isClosed) return;
    final authorityChanged =
        _detachedProviderProjectionCurrent ||
        _detachedAuthorityObserved ||
        _detachedExecutionHost != null ||
        _detachedControlState != null ||
        _detachedAuthorityGeneration != null ||
        _detachedAuthorityLiveRuntimeGeneration != null ||
        _detachedAuthoritySourceFingerprint != null ||
        _detachedActiveTurnId != null;
    _detachedProviderProjectionCurrent = false;
    _detachedAuthorityObserved = false;
    _detachedExecutionHost = null;
    _detachedControlState = null;
    _detachedAuthorityGeneration = null;
    _detachedAuthorityLiveRuntimeGeneration = null;
    _detachedAuthoritySourceFingerprint = null;
    _detachedActiveTurnId = null;
    externalDesktopTurnSteerable.value = false;
    if (authorityChanged) {
      detachedLiveRuntimeRevision.value += 1;
      emit(
        state.copyWith(
          externalDesktopTurnActive: false,
          externalDesktopTurnId: null,
        ),
      );
    }
    logger.info(
      '[settings_projection] event=projection_suspended '
      'thread=$_projectionThreadToken reason=$reason '
      'observed=${_projectionSourceToken(observedSourceFingerprint)} '
      'expected=${_projectionSourceToken(expectedSourceFingerprint)} '
      'catalogUsable=${catalogUsable ?? 'unknown'} '
      'authorityChanged=$authorityChanged',
    );
  }

  void _clearDetachedProviderSettings() {
    _detachedProviderSettingsObservedAt = null;
    _detachedProviderSettingsSignature = null;
    _detachedProviderOwnsModel = false;
    _detachedProviderOwnsEffort = false;
    _detachedProviderOwnsSpeed = false;
    codexServiceTierRaw.value = null;
    emit(_stateWithoutDetachedProviderSettings(state));
  }

  ChatSessionState _stateWithoutDetachedProviderSettings(
    ChatSessionState current,
  ) => current.copyWith(
    permissionMode: PermissionMode.defaultMode,
    executionMode: ExecutionMode.defaultMode,
    codexPermissionStateKnown: false,
    codexApprovalPolicy: CodexApprovalPolicy.onRequest,
    codexApprovalsReviewer: 'user',
    codexPermissionsMode: CodexPermissionsMode.defaultPermissions,
    sandboxMode: SandboxMode.on,
    planMode: false,
    inPlanMode: false,
    codexModel: null,
    codexModelReasoningEffort: null,
    codexSpeed: CodexSpeed.unknown,
  );

  /// Adds the user's first message to a detached durable view while the live
  /// runtime attaches. An online attachment remains an ordinary send; only a
  /// genuinely disconnected outbox item is presented as locally queued.
  bool showDeferredSubmission(
    String text, {
    List<({Uint8List bytes, String mimeType})>? images,
    bool queuedLocally = false,
  }) {
    if (!detachedPreview || isClosed || text.trim().isEmpty) return false;
    emit(
      state.copyWith(
        entries: [
          ...state.entries,
          UserChatEntry(
            text,
            sessionId: sessionId,
            imageBytesList: images?.map((image) => image.bytes).toList(),
            imageCount: images?.length ?? 0,
            status: queuedLocally
                ? MessageStatus.queued
                : MessageStatus.sending,
            timestamp: DateTime.now().toUtc(),
          ),
        ],
      ),
    );
    return true;
  }

  void _startStatusRefreshTimer() {
    _statusRefreshTimer?.cancel();
    _statusRefreshTimer = null;
    _statusHistoryRetryAttempt = 0;
    _statusHistoryBootstrapGraceUsed = false;
    if (state.status != ProcessStatus.starting || isClosed) return;
    if (!_bridge.isConnected) {
      _statusHistoryWaitingForReconnect = true;
      return;
    }
    _statusHistoryWaitingForReconnect = false;
    _scheduleStatusHistoryRetry();
  }

  void _scheduleStatusHistoryRetry() {
    if (isClosed ||
        state.status != ProcessStatus.starting ||
        _statusHistoryRetryAttempt >= _statusHistoryRetryMaxAttempts) {
      return;
    }
    final delay = _statusHistoryRetryBase * (1 << _statusHistoryRetryAttempt);
    _statusRefreshTimer = Timer(delay, () {
      _statusRefreshTimer = null;
      if (isClosed || state.status != ProcessStatus.starting) return;
      if (!_bridge.isConnected) {
        _statusHistoryWaitingForReconnect = true;
        return;
      }
      if (!_statusHistoryBootstrapGraceUsed &&
          (_historyBootstrapInFlight ||
              (_historyBootstrapSucceeded && !_historyFallbackRequested))) {
        _statusHistoryBootstrapGraceUsed = true;
        _scheduleStatusHistoryRetry();
        return;
      }
      _historyFallbackRequested = true;
      _bridge.requestSessionHistory(sessionId);
      _statusHistoryRetryAttempt += 1;
      _scheduleStatusHistoryRetry();
    });
  }

  void _onStatusRefreshConnectionState(BridgeConnectionState connectionState) {
    if (isClosed) return;
    if (connectionState != BridgeConnectionState.connected) {
      _statusHistoryWaitingForReconnect = true;
      if (connectionState == BridgeConnectionState.disconnected) {
        _handler.resetTransientStreaming();
        _streamingCubit.reset();
        _statusFromLiveMessage = false;
        if (!isCodex) _resetSessionSnapshotAuthorityForConnection();
      }
      if (state.status == ProcessStatus.starting) {
        _statusRefreshTimer?.cancel();
        _statusRefreshTimer = null;
      }
      return;
    }
    if (!_statusHistoryWaitingForReconnect) return;
    _statusHistoryWaitingForReconnect = false;
    _historyFallbackRequested = true;
    _bridge.requestSessionHistory(sessionId);
    if (state.status == ProcessStatus.starting) _startStatusRefreshTimer();
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
    _goalReadAwaitingThread = false;
    _goalUserRefreshPending = false;
    _codexGoalThreadReady = false;
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

  void _onDesktopContinuityConnectionState(
    BridgeConnectionState connectionState,
  ) {
    if (!isCodex || isClosed) return;
    if (connectionState == BridgeConnectionState.connected) {
      _ensureDesktopContinuityWatch();
      return;
    }
    _desktopContinuityReconcileTimer?.cancel();
    _desktopContinuityReconcileTimer = null;
    // A continuity terminal can hand a queued phone turn to the Bridge and
    // deliberately leave the visible status at running after the external
    // flag has cleared. Keep the binding itself as the downgrade/reconnect
    // fence so an older Bridge can replace that synthetic status with its
    // authoritative session-list value.
    final hadContinuityBinding = _desktopContinuityRequestId != null;
    if (hadContinuityBinding) {
      _desktopContinuityWasExternalBeforeDisconnect = true;
    }
    // The server-side registration belongs to the disconnected socket. Retire
    // it locally so a reconnect creates exactly one fresh watch; repeated
    // connected notifications then remain idempotent.
    _retireDesktopContinuityBinding();
    _desktopContinuityRetryAttempt = 0;
    _desktopContinuitySuppressedThreadId = null;
    _desktopContinuitySuppressedProjectPath = null;
    _resetSessionSnapshotAuthorityForConnection();
    if (state.externalDesktopTurnActive) {
      emit(
        state.copyWith(
          externalDesktopTurnActive: false,
          externalDesktopTurnId: null,
        ),
      );
    }
  }

  void _ensureDesktopContinuityWatch({
    String? threadId,
    String? projectPath,
    bool force = false,
  }) {
    if (!isCodex ||
        !_bridge.isConnected ||
        isClosed ||
        _awaitingFreshSessionListAfterReconnect ||
        !_bridge.bridgeCapabilities.contains(
          codexDesktopContinuityCapability,
        )) {
      return;
    }
    final nextThreadId = (threadId ?? state.claudeSessionId)?.trim();
    final nextProjectPath = (projectPath ?? state.projectPath)?.trim();
    if (nextThreadId == null ||
        nextThreadId.isEmpty ||
        nextProjectPath == null ||
        nextProjectPath.isEmpty) {
      return;
    }
    final sameSuppressedIdentity =
        _desktopContinuitySuppressedThreadId == nextThreadId &&
        _desktopContinuitySuppressedProjectPath == nextProjectPath;
    if (sameSuppressedIdentity) return;
    _desktopContinuitySuppressedThreadId = null;
    _desktopContinuitySuppressedProjectPath = null;
    if (!force && _desktopContinuityRetryTimer != null) return;
    if (!force &&
        _desktopContinuityThreadId == nextThreadId &&
        _desktopContinuityProjectPath == nextProjectPath &&
        _desktopContinuityRequestId != null) {
      return;
    }
    _unwatchDesktopContinuity();
    _desktopContinuityRetryTimer?.cancel();
    _desktopContinuityRetryTimer = null;
    final requestId = _uuid.v4();
    _desktopContinuityRequestId = requestId;
    _desktopContinuityThreadId = nextThreadId;
    _desktopContinuityProjectPath = nextProjectPath;
    _desktopContinuityItemKeys.clear();
    if (_restoredDesktopContinuityThreadId == nextThreadId) {
      _desktopContinuityItemKeys.addAll(_restoredDesktopContinuityItemKeys);
    }
    _desktopContinuityHandlers.clear();
    _desktopContinuityStreamingTurnKey = null;
    _bridge.send(
      requestCodexDesktopContinuityWatch(
        requestId: requestId,
        sessionId: sessionId,
        threadId: nextThreadId,
        projectPath: nextProjectPath,
      ),
    );
    _desktopContinuityWatchAckTimer?.cancel();
    _desktopContinuityWatchAckTimer = Timer(
      _desktopContinuityWatchAckTimeout,
      () {
        if (isClosed || _desktopContinuityRequestId != requestId) return;
        logger.warning(
          '[session:$sessionId] Desktop continuity watch timed out; retrying',
        );
        _retireDesktopContinuityBinding(cancelRetry: false);
        _scheduleDesktopContinuityRetry();
      },
    );
  }

  void _unwatchDesktopContinuity() {
    final requestId = _desktopContinuityRequestId;
    final threadId = _desktopContinuityThreadId;
    if (requestId != null &&
        threadId != null &&
        _bridge.isConnected &&
        !isClosed) {
      _bridge.send(
        requestCodexDesktopContinuityUnwatch(
          requestId: requestId,
          sessionId: sessionId,
          threadId: threadId,
        ),
      );
    }
    _retireDesktopContinuityBinding();
  }

  void _retireDesktopContinuityBinding({bool cancelRetry = true}) {
    _desktopContinuityWatchAckTimer?.cancel();
    _desktopContinuityWatchAckTimer = null;
    if (cancelRetry) {
      _desktopContinuityRetryTimer?.cancel();
      _desktopContinuityRetryTimer = null;
    }
    _desktopContinuityRequestId = null;
    _desktopContinuityThreadId = null;
    _desktopContinuityProjectPath = null;
    _desktopContinuityItemKeys.clear();
    _desktopContinuityHandlers.clear();
    _desktopContinuityStreamingTurnKey = null;
    externalDesktopTurnSteerable.value = false;
  }

  void _acknowledgeDesktopContinuityWatch() {
    _desktopContinuityWatchAckTimer?.cancel();
    _desktopContinuityWatchAckTimer = null;
    _desktopContinuityRetryTimer?.cancel();
    _desktopContinuityRetryTimer = null;
    _desktopContinuityRetryAttempt = 0;
  }

  void _scheduleDesktopContinuityRetry() {
    if (isClosed ||
        !_bridge.isConnected ||
        _desktopContinuityRetryTimer != null) {
      return;
    }
    final multiplier = 1 << _desktopContinuityRetryAttempt.clamp(0, 4);
    final delayMs = (_desktopContinuityRetryBase.inMilliseconds * multiplier)
        .clamp(
          _desktopContinuityRetryBase.inMilliseconds,
          _desktopContinuityRetryMax.inMilliseconds,
        )
        .toInt();
    _desktopContinuityRetryAttempt += 1;
    _desktopContinuityRetryTimer = Timer(Duration(milliseconds: delayMs), () {
      _desktopContinuityRetryTimer = null;
      _ensureDesktopContinuityWatch();
    });
  }

  void _onDesktopContinuityMessage(LocalFeatureServerMessage rawMessage) {
    if (!isCodex || isClosed) return;
    if (rawMessage is LocalFeatureRequestErrorMessage &&
        rawMessage.featureId == 'codex_desktop_continuity') {
      logger.info(
        '[session:$sessionId] Desktop continuity unavailable: '
        '${rawMessage.message}',
      );
      if (rawMessage.requestId == null ||
          rawMessage.requestId == _desktopContinuityRequestId) {
        _desktopContinuitySuppressedThreadId = _desktopContinuityThreadId;
        _desktopContinuitySuppressedProjectPath = _desktopContinuityProjectPath;
        _retireDesktopContinuityBinding();
      }
      return;
    }
    if (rawMessage is! CodexDesktopContinuityEventMessage ||
        !rawMessage.usesSupportedSemantics ||
        rawMessage.sessionId != sessionId ||
        rawMessage.requestId != _desktopContinuityRequestId ||
        rawMessage.threadId != _desktopContinuityThreadId) {
      return;
    }
    if (rawMessage.event != CodexDesktopContinuityEventKind.error) {
      _acknowledgeDesktopContinuityWatch();
    }
    final trailingBackgroundContinuity = _bridge
        .takeBackgroundDesktopContinuity(
          sessionId,
          threadId: rawMessage.threadId,
        );
    if (trailingBackgroundContinuity != null) {
      _restoreBackgroundDesktopContinuity(trailingBackgroundContinuity);
    }
    switch (rawMessage.event) {
      case CodexDesktopContinuityEventKind.watching:
        if (rawMessage.state == CodexDesktopContinuityState.running) {
          _desktopContinuityWasExternalBeforeDisconnect = false;
          _setExternalDesktopRunning(
            rawMessage.turnId,
            turnSteerable: rawMessage.turnSteerable,
          );
        } else if (rawMessage.state == CodexDesktopContinuityState.idle) {
          final shouldSettleBaseline =
              _desktopContinuityWasExternalBeforeDisconnect ||
              state.externalDesktopTurnActive ||
              state.status == ProcessStatus.starting ||
              (_statusFromSessionSnapshot &&
                  state.status == ProcessStatus.running);
          _desktopContinuityWasExternalBeforeDisconnect = false;
          if (shouldSettleBaseline) _finishExternalDesktopTurn(rawMessage);
        }
        return;
      case CodexDesktopContinuityEventKind.state:
        if (rawMessage.state == CodexDesktopContinuityState.running) {
          _desktopContinuityWasExternalBeforeDisconnect = false;
          _setExternalDesktopRunning(
            rawMessage.turnId,
            turnSteerable: rawMessage.turnSteerable,
          );
        } else if (rawMessage.state == CodexDesktopContinuityState.idle) {
          _desktopContinuityWasExternalBeforeDisconnect = false;
          _finishExternalDesktopTurn(rawMessage);
        }
        return;
      case CodexDesktopContinuityEventKind.message:
        if (state.externalDesktopTurnActive &&
            state.externalDesktopTurnId != null &&
            state.externalDesktopTurnId == rawMessage.turnId) {
          externalDesktopTurnSteerable.value = rawMessage.turnSteerable;
        }
        final itemKey = rawMessage.itemKey;
        final payload = rawMessage.payload;
        if (itemKey == null ||
            payload == null ||
            !_desktopContinuityItemKeys.add(itemKey)) {
          return;
        }
        while (_desktopContinuityItemKeys.length > 4096) {
          _desktopContinuityItemKeys.remove(_desktopContinuityItemKeys.first);
        }
        _applyExternalDesktopPayload(payload, turnId: rawMessage.turnId);
        return;
      case CodexDesktopContinuityEventKind.error:
        logger.warning(
          '[session:$sessionId] Desktop continuity error '
          '${rawMessage.errorCode}: ${rawMessage.error}',
        );
        if (rawMessage.errorCode == 'runtime_rehydrate_failed') {
          _statusFromHistoryFallback = false;
          _statusFromSessionSnapshot = false;
          emit(
            state.copyWith(
              status: ProcessStatus.idle,
              externalDesktopTurnActive: false,
              externalDesktopTurnId: null,
            ),
          );
          _bridge.requestSessionHistory(sessionId);
          _applyExternalDesktopPayload(
            ErrorMessage(
              message:
                  rawMessage.error ??
                  'Desktop history synchronized, but the mobile runtime could not be refreshed.',
              errorCode: rawMessage.errorCode,
            ),
          );
          return;
        }
        final shouldRetry = rawMessage.errorCode != 'path_not_allowed';
        if (!shouldRetry) {
          _desktopContinuitySuppressedThreadId = rawMessage.threadId;
          _desktopContinuitySuppressedProjectPath =
              _desktopContinuityProjectPath;
        }
        _retireDesktopContinuityBinding(cancelRetry: false);
        _bridge.requestSessionList();
        _bridge.requestSessionHistory(sessionId);
        if (shouldRetry) _scheduleDesktopContinuityRetry();
        return;
      case CodexDesktopContinuityEventKind.unwatched:
      case CodexDesktopContinuityEventKind.unknown:
        return;
    }
  }

  void _setExternalDesktopRunning(
    String? turnId, {
    required bool turnSteerable,
  }) {
    _desktopContinuityReconcileTimer?.cancel();
    _desktopContinuityReconcileTimer = null;
    _statusFromHistoryFallback = false;
    _statusFromSessionSnapshot = false;
    externalDesktopTurnSteerable.value = turnId != null && turnSteerable;
    if (state.externalDesktopTurnActive &&
        state.externalDesktopTurnId == turnId &&
        state.status == ProcessStatus.running) {
      return;
    }
    emit(
      state.copyWith(
        status: ProcessStatus.running,
        externalDesktopTurnActive: true,
        externalDesktopTurnId: turnId,
      ),
    );
  }

  void _finishExternalDesktopTurn(CodexDesktopContinuityEventMessage message) {
    _statusFromHistoryFallback = false;
    _statusFromSessionSnapshot = false;
    externalDesktopTurnSteerable.value = false;
    emit(
      state.copyWith(
        status: message.handoffQueued
            ? ProcessStatus.running
            : ProcessStatus.idle,
        externalDesktopTurnActive: false,
        externalDesktopTurnId: null,
        approval: const ApprovalState.none(),
      ),
    );
    _desktopContinuityReconcileTimer?.cancel();
    if (message.historyReady) {
      _desktopContinuityReconcileTimer = null;
      _bridge.requestSessionHistory(sessionId);
      return;
    }
    _desktopContinuityReconcileTimer = Timer(
      const Duration(milliseconds: 900),
      () {
        if (isClosed || state.externalDesktopTurnActive) return;
        _bridge.requestSessionHistory(sessionId);
      },
    );
  }

  void _applyExternalDesktopPayload(ServerMessage message, {String? turnId}) {
    try {
      final turnKey = turnId ?? '__unattributed_desktop_turn__';
      final handler = _desktopContinuityHandlers.putIfAbsent(
        turnKey,
        ChatMessageHandler.new,
      );
      while (_desktopContinuityHandlers.length > 32) {
        final oldest = _desktopContinuityHandlers.keys.first;
        if (oldest == turnKey && _desktopContinuityHandlers.length == 1) break;
        _desktopContinuityHandlers.remove(oldest);
      }
      if ((message is ThinkingDeltaMessage || message is StreamDeltaMessage) &&
          _desktopContinuityStreamingTurnKey != turnKey) {
        // The shared visual streaming surface can display only one turn at a
        // time. Reset it when explicit Desktop turn identity changes, while
        // each turn's handler keeps its own reasoning accumulator for the
        // correct completed assistant message.
        _streamingCubit.reset();
        _desktopContinuityStreamingTurnKey = turnKey;
      }
      final update = handler.handle(
        message,
        isBackground: true,
        isCodex: true,
        ignoredToolUseIds: _respondedToolUseIds,
      );
      _applyUpdate(
        update,
        message,
        allowUserDelivery: false,
        sourceHandler: handler,
        affectVisibleStreaming:
            _desktopContinuityStreamingTurnKey == null ||
            _desktopContinuityStreamingTurnKey == turnKey,
      );
    } catch (error, stackTrace) {
      logger.error(
        '[session:$sessionId] Failed to apply Desktop continuity payload',
        error,
        stackTrace,
      );
    }
  }

  void _updateCodexRuntimeSupportFromSessions(List<SessionInfo> sessions) {
    if (!isCodex || isClosed || !_bridge.isConnected) return;
    final incomingGeneration = _bridge.authoritativeSessionListGeneration;
    if (_awaitingFreshSessionListAfterReconnect) {
      if (!_bridge.hasAuthoritativeSessionListForCurrentConnection ||
          incomingGeneration <= _sessionListGenerationAtDisconnect) {
        return;
      }
      _awaitingFreshSessionListAfterReconnect = false;
    }
    if (incomingGeneration > _lastConsumedSessionListGeneration) {
      _lastConsumedSessionListGeneration = incomingGeneration;
    }
    _syncCodexContinuityBindingFromSessions(sessions);
    _updateNativePlanModeSupportFromSessions(sessions);
    _updateGoalSupportFromSessions(sessions);
    // BridgeService publishes the session-list stream immediately before its
    // capability snapshot is visible to listeners. Retry in the next
    // microtask so a reconnect can arm continuity without sending an unknown
    // request to an older Bridge.
    scheduleMicrotask(() {
      if (isClosed || !_bridge.isConnected) return;
      if (_bridge.bridgeCapabilities.contains(
        codexDesktopContinuityCapability,
      )) {
        _ensureDesktopContinuityWatch();
        return;
      }
      final hadContinuityBinding = _desktopContinuityRequestId != null;
      if (!hadContinuityBinding &&
          !_desktopContinuityWasExternalBeforeDisconnect) {
        return;
      }
      var authoritativeStatus = ProcessStatus.idle;
      final runtimeSessionId = runtimeSessionIdForRead;
      for (final session in sessions) {
        if (runtimeSessionId != null && session.id == runtimeSessionId) {
          authoritativeStatus = ProcessStatus.fromString(session.status);
          break;
        }
      }
      _desktopContinuityWasExternalBeforeDisconnect = false;
      // Do not send an unwatch request to a Bridge that did not advertise the
      // feature. Retire the stale local binding so later capability snapshots
      // cannot accept messages from the previous Bridge instance.
      _desktopContinuityRequestId = null;
      _desktopContinuityThreadId = null;
      _desktopContinuityProjectPath = null;
      _desktopContinuityItemKeys.clear();
      _desktopContinuityHandlers.clear();
      _desktopContinuityStreamingTurnKey = null;
      emit(
        state.copyWith(
          status: authoritativeStatus,
          externalDesktopTurnActive: false,
          externalDesktopTurnId: null,
        ),
      );
      _bridge.requestSessionHistory(sessionId);
    });
  }

  void _resetSessionSnapshotAuthorityForConnection() {
    // A snapshot can only outrank HistoryMessage while it belongs to the
    // current Bridge socket. After reconnect, the visible state is merely a
    // fallback until the new peer supplies either SessionInfo or history.
    _statusFromHistoryFallback = true;
    _statusFromSessionSnapshot = false;
    _statusFromLiveMessage = false;
    _hasAuthoritativeSessionSnapshot = false;
    _sessionSnapshotOwnsThreadId = false;
    _sessionSnapshotOwnsProjectPath = false;
    _sessionSnapshotOwnsModel = false;
    _sessionSnapshotOwnsEffort = false;
    _sessionSnapshotOwnsSpeed = false;
    // Connection and session-list notifications use separate broadcast
    // streams. A very fast reconnect can increment BridgeService's global
    // generation before this queued disconnect callback runs. Fence against
    // the last generation this cubit actually consumed, otherwise the first
    // genuinely fresh list is mistaken for stale data and ignored.
    _sessionListGenerationAtDisconnect = _lastConsumedSessionListGeneration;
    _awaitingFreshSessionListAfterReconnect = true;
  }

  void _syncCodexContinuityBindingFromSessions(List<SessionInfo> sessions) {
    if (!isCodex || isClosed || !_bridge.isConnected) return;
    SessionInfo? snapshot;
    final runtimeSessionId = runtimeSessionIdForRead;
    for (final session in sessions) {
      if (runtimeSessionId != null &&
          session.id == runtimeSessionId &&
          session.provider == Provider.codex.value) {
        snapshot = session;
        break;
      }
    }
    if (snapshot == null) return;

    final hadAuthoritativeSessionSnapshot = _hasAuthoritativeSessionSnapshot;
    _hasAuthoritativeSessionSnapshot = true;
    final snapshotStatus = ProcessStatus.fromString(snapshot.status);
    final threadId = snapshot.claudeSessionId?.trim();
    final projectPath = snapshot.projectPath.trim();
    final previousThreadId = state.claudeSessionId?.trim();
    final hasRuntimeThread =
        threadId?.isNotEmpty == true &&
        snapshotStatus != ProcessStatus.starting;
    if (threadId?.isNotEmpty == true && threadId != previousThreadId) {
      _codexGoalThreadReady = hasRuntimeThread;
    } else if (hasRuntimeThread) {
      _codexGoalThreadReady = true;
    }
    _sessionSnapshotOwnsThreadId |= threadId?.isNotEmpty == true;
    _sessionSnapshotOwnsProjectPath |= projectPath.isNotEmpty;
    final nextThreadId = threadId == null || threadId.isEmpty
        ? state.claudeSessionId
        : threadId;
    final nextProjectPath = projectPath.isEmpty
        ? state.projectPath
        : projectPath;
    final shouldApplySnapshotStatus =
        !state.externalDesktopTurnActive &&
        (state.status == ProcessStatus.starting ||
            state.status == ProcessStatus.idle ||
            _statusFromSessionSnapshot ||
            (!hadAuthoritativeSessionSnapshot && _statusFromHistoryFallback));
    final nextStatus = shouldApplySnapshotStatus
        ? snapshotStatus
        : state.status;
    if (shouldApplySnapshotStatus) {
      _statusFromSessionSnapshot = true;
      _statusFromHistoryFallback = false;
    }

    var nextPermissionMode = state.permissionMode;
    var nextExecutionMode = state.executionMode;
    var nextApprovalPolicy = state.codexApprovalPolicy;
    var nextApprovalsReviewer = state.codexApprovalsReviewer;
    var nextPermissionsMode = state.codexPermissionsMode;
    var nextCodexPermissionStateKnown = state.codexPermissionStateKnown;
    var nextSandboxMode = state.sandboxMode;
    var nextPlanMode = state.planMode;
    var nextInPlanMode = state.inPlanMode;
    final hasPermissionSignals =
        snapshot.permissionMode?.trim().isNotEmpty == true ||
        snapshot.codexApprovalPolicy?.trim().isNotEmpty == true ||
        snapshot.codexApprovalsReviewer?.trim().isNotEmpty == true ||
        snapshot.codexPermissionsMode?.trim().isNotEmpty == true ||
        snapshot.codexSandboxMode?.trim().isNotEmpty == true;
    final hasCodexPermissionPolicySignals =
        snapshot.permissionMode?.trim().isNotEmpty == true ||
        snapshot.codexApprovalPolicy?.trim().isNotEmpty == true ||
        snapshot.codexApprovalsReviewer?.trim().isNotEmpty == true ||
        snapshot.codexPermissionsMode?.trim().isNotEmpty == true;
    // A next-turn permission mutation is optimistic until its correlated ACK.
    // A stale session_list snapshot must not roll that group back meanwhile.
    if (_pendingPermissionChangeId == null && hasPermissionSignals) {
      nextCodexPermissionStateKnown =
          nextCodexPermissionStateKnown || hasCodexPermissionPolicySignals;
      final rawPermissionMode = snapshot.permissionMode?.trim();
      var hasExplicitPermissionMode = false;
      for (final mode in PermissionMode.values) {
        if (mode.value == rawPermissionMode) {
          nextPermissionMode = mode;
          hasExplicitPermissionMode = true;
        }
      }
      final hasExecutionSignals =
          rawPermissionMode?.isNotEmpty == true ||
          snapshot.codexApprovalPolicy?.trim().isNotEmpty == true;
      if (hasExecutionSignals) {
        nextExecutionMode =
            executionModeFromRaw(snapshot.executionMode) ??
            deriveExecutionMode(
              provider: Provider.codex.value,
              executionMode: snapshot.executionMode,
              permissionMode: snapshot.permissionMode,
              approvalPolicy: snapshot.codexApprovalPolicy,
            );
        final explicitApprovalPolicy = codexApprovalPolicyFromRaw(
          snapshot.codexApprovalPolicy,
        );
        nextApprovalPolicy =
            explicitApprovalPolicy ??
            (rawPermissionMode?.isNotEmpty == true
                ? codexApprovalPolicyFromLegacyExecutionMode(
                    nextExecutionMode.value,
                  )
                : nextApprovalPolicy);
      }
      if (snapshot.codexApprovalsReviewer?.trim().isNotEmpty == true) {
        nextApprovalsReviewer =
            isCodexAutoReviewApprovalsReviewer(snapshot.codexApprovalsReviewer)
            ? 'auto_review'
            : 'user';
      }
      final explicitPermissionsMode = codexPermissionsModeFromRaw(
        snapshot.codexPermissionsMode,
      );
      nextSandboxMode = switch (snapshot.codexSandboxMode) {
        'danger-full-access' || 'off' => SandboxMode.off,
        'workspace-write' || 'read-only' || 'on' => SandboxMode.on,
        _ => nextSandboxMode,
      };
      if (explicitPermissionsMode != null) {
        nextPermissionsMode = explicitPermissionsMode;
      } else if (snapshot.codexApprovalPolicy?.trim().isNotEmpty == true ||
          snapshot.codexApprovalsReviewer?.trim().isNotEmpty == true ||
          snapshot.codexSandboxMode?.trim().isNotEmpty == true) {
        nextPermissionsMode = codexPermissionsModeFromSettings(
          approvalPolicy:
              snapshot.codexApprovalPolicy ?? nextApprovalPolicy.value,
          approvalsReviewer:
              snapshot.codexApprovalsReviewer ?? nextApprovalsReviewer,
          sandboxMode:
              snapshot.codexSandboxMode ??
              (nextSandboxMode == SandboxMode.off
                  ? 'danger-full-access'
                  : 'workspace-write'),
        );
      }
      if (rawPermissionMode?.isNotEmpty == true || snapshot.planMode) {
        nextPlanMode = snapshot.resolvedPlanMode;
        nextInPlanMode = nextPlanMode;
      }
      if (!hasExplicitPermissionMode && hasExecutionSignals) {
        nextPermissionMode = legacyPermissionModeFromModes(
          Provider.codex,
          executionMode: nextExecutionMode,
          planMode: nextPlanMode,
        );
      }
    }

    final nextModel =
        sanitizeCodexModelName(snapshot.codexModel ?? snapshot.model) ??
        state.codexModel;
    final nextEffort =
        reasoningEffortByValue(snapshot.codexModelReasoningEffort) ??
        state.codexModelReasoningEffort;
    final nextSpeed = snapshot.codexServiceTier?.trim().isNotEmpty == true
        ? codexSpeedFromRaw(snapshot.codexServiceTier)
        : state.codexSpeed;
    _sessionSnapshotOwnsModel |=
        sanitizeCodexModelName(snapshot.codexModel ?? snapshot.model) != null;
    _sessionSnapshotOwnsEffort |=
        reasoningEffortByValue(snapshot.codexModelReasoningEffort) != null;
    _sessionSnapshotOwnsSpeed |=
        snapshot.codexServiceTier?.trim().isNotEmpty == true;
    if (nextThreadId == state.claudeSessionId &&
        nextProjectPath == state.projectPath &&
        nextStatus == state.status &&
        nextPermissionMode == state.permissionMode &&
        nextExecutionMode == state.executionMode &&
        nextCodexPermissionStateKnown == state.codexPermissionStateKnown &&
        nextApprovalPolicy == state.codexApprovalPolicy &&
        nextApprovalsReviewer == state.codexApprovalsReviewer &&
        nextPermissionsMode == state.codexPermissionsMode &&
        nextSandboxMode == state.sandboxMode &&
        nextPlanMode == state.planMode &&
        nextInPlanMode == state.inPlanMode &&
        nextModel == state.codexModel &&
        nextEffort == state.codexModelReasoningEffort &&
        nextSpeed == state.codexSpeed) {
      _flushDeferredGoalRead();
      return;
    }
    final goalThreadChanged =
        nextThreadId?.trim().isNotEmpty == true &&
        nextThreadId?.trim() != previousThreadId;
    emit(
      state.copyWith(
        claudeSessionId: nextThreadId,
        projectPath: nextProjectPath,
        status: nextStatus,
        permissionMode: nextPermissionMode,
        executionMode: nextExecutionMode,
        codexPermissionStateKnown: nextCodexPermissionStateKnown,
        codexApprovalPolicy: nextApprovalPolicy,
        codexApprovalsReviewer: nextApprovalsReviewer,
        codexPermissionsMode: nextPermissionsMode,
        sandboxMode: nextSandboxMode,
        planMode: nextPlanMode,
        inPlanMode: nextInPlanMode,
        codexModel: nextModel,
        codexModelReasoningEffort: nextEffort,
        codexSpeed: nextSpeed,
        goal: goalThreadChanged ? null : state.goal,
        goalStateLoaded: goalThreadChanged ? false : state.goalStateLoaded,
        goalOperationSequence: goalThreadChanged
            ? null
            : state.goalOperationSequence,
      ),
    );
    _flushDeferredGoalRead();
  }

  void _synchronizeRuntimeSnapshot(List<SessionInfo> sessions) {
    if (isClosed) return;
    if (!isCodex) {
      _synchronizeClaudeRuntimeSnapshot(sessions);
      return;
    }
    final runtime = _runtimeSessionFrom(sessions);
    if (runtime == null) return;
    _updateCodexServiceTierRaw(runtime.codexServiceTier);
    final normalizedTier = runtime.codexServiceTier?.trim();
    if ((normalizedTier == null || normalizedTier.isEmpty) &&
        state.codexSpeed == CodexSpeed.unknown) {
      emit(state.copyWith(codexSpeed: CodexSpeed.standard));
    }
    _restoreRuntimeInteractions(runtime);
  }

  void _synchronizeClaudeRuntimeSnapshot(List<SessionInfo> sessions) {
    if (isCodex || isClosed || !_bridge.isConnected) return;
    final incomingGeneration = _bridge.authoritativeSessionListGeneration;
    if (_awaitingFreshSessionListAfterReconnect) {
      if (!_bridge.hasAuthoritativeSessionListForCurrentConnection ||
          incomingGeneration <= _sessionListGenerationAtDisconnect) {
        return;
      }
      _awaitingFreshSessionListAfterReconnect = false;
    }
    if (incomingGeneration > _lastConsumedSessionListGeneration) {
      _lastConsumedSessionListGeneration = incomingGeneration;
    }
    final runtime = _runtimeSessionFrom(sessions);
    if (runtime == null || runtime.provider != Provider.claude.value) return;
    final snapshotStatus = ProcessStatus.fromString(runtime.status);
    _hasAuthoritativeSessionSnapshot = true;
    _statusFromSessionSnapshot = true;
    _statusFromHistoryFallback = false;
    _statusFromLiveMessage = false;
    if (snapshotStatus != state.status) {
      emit(state.copyWith(status: snapshotStatus));
    }
  }

  void _synchronizeDetachedCodexRuntimeSnapshot(List<SessionInfo> sessions) {
    if (!detachedPreview || !isCodex || isClosed) return;
    _updateNativePlanModeSupportFromSessions(sessions);
    _updateGoalSupportFromSessions(sessions);
    final runtime = _runtimeSessionFrom(sessions);
    if (runtime != null) {
      _restoreRuntimeInteractions(runtime);
    }
  }

  SessionInfo? _runtimeSessionFrom(List<SessionInfo> sessions) {
    final runtimeSessionId = runtimeSessionIdForRead;
    if (runtimeSessionId == null) return null;
    for (final session in sessions) {
      if (session.id == runtimeSessionId) return session;
    }
    return null;
  }

  void _updateCodexServiceTierRaw(String? raw) {
    final normalized = raw?.trim();
    final next = normalized == null || normalized.isEmpty ? null : normalized;
    if (codexServiceTierRaw.value != next) {
      codexServiceTierRaw.value = next;
    }
  }

  String? get unsupportedCodexServiceTier {
    final raw = codexServiceTierRaw.value;
    return codexRuntimeSpeedFromRaw(raw) == CodexSpeed.unknown ? raw : null;
  }

  void _restoreRuntimeInteractions(SessionInfo runtime) {
    if (!isCodex || isClosed) return;
    final current = state;
    var approval = current.approval;
    var queuedInput = current.queuedInput;
    var changed = false;

    final pending = runtime.pendingPermission;
    if (pending != null && !_respondedToolUseIds.contains(pending.toolUseId)) {
      _pendingPermissionRequests[pending.toolUseId] = pending;
      if (!_approvalMatchesPending(approval, pending)) {
        approval = pending.usesAskUserUi
            ? ApprovalState.askUser(
                toolUseId: pending.toolUseId,
                input: pending.input,
              )
            : ApprovalState.permission(
                toolUseId: pending.toolUseId,
                request: pending,
              );
        changed = true;
      }
    }

    final runtimeQueues = runtime.queuedInputs.isNotEmpty
        ? runtime.queuedInputs
        : (runtime.queuedInput == null
              ? const <QueuedInputItem>[]
              : [runtime.queuedInput!]);
    _setAuthoritativeQueuedInputs(runtimeQueues, runtime.queuedInputLimit);
    final runtimeQueue = runtimeQueues.isEmpty ? null : runtimeQueues.first;
    if (runtimeQueue != null && !_sameQueuedInput(queuedInput, runtimeQueue)) {
      queuedInput = runtimeQueue;
      changed = true;
    }

    if (changed) {
      emit(state.copyWith(approval: approval, queuedInput: queuedInput));
    }
  }

  bool _approvalMatchesPending(
    ApprovalState approval,
    PermissionRequestMessage pending,
  ) => pending.usesAskUserUi
      ? approval is ApprovalAskUser && approval.toolUseId == pending.toolUseId
      : approval is ApprovalPermission &&
            approval.toolUseId == pending.toolUseId;

  bool _sameQueuedInput(QueuedInputItem? left, QueuedInputItem right) =>
      left != null &&
      left.itemId == right.itemId &&
      left.text == right.text &&
      left.createdAt == right.createdAt &&
      left.updatedAt == right.updatedAt &&
      left.imageCount == right.imageCount;

  void _captureCodexServiceTier(ServerMessage message) {
    if (!isCodex) return;
    if (message is SystemMessage &&
        message.provider == Provider.codex.value &&
        message.serviceTier != null) {
      _updateCodexServiceTierRaw(message.serviceTier);
      return;
    }
    if (message is! HistoryMessage ||
        (detachedPreview && _detachedProviderOwnsSpeed)) {
      return;
    }
    for (final nested in message.messages.reversed) {
      if (nested is SystemMessage &&
          nested.provider == Provider.codex.value &&
          nested.serviceTier != null) {
        _updateCodexServiceTierRaw(nested.serviceTier);
        return;
      }
    }
  }

  void _updateNativePlanModeSupportFromSessions(List<SessionInfo> sessions) {
    if (!isCodex || isClosed) return;
    final runtimeSessionId = runtimeSessionIdForRead;
    bool? supported;
    for (final session in sessions) {
      if (runtimeSessionId != null && session.id == runtimeSessionId) {
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
    final runtimeSessionId = runtimeSessionIdForRead;
    bool? supported;
    for (final session in sessions) {
      if (runtimeSessionId != null && session.id == runtimeSessionId) {
        supported = session.codexGoalControlSupported;
        break;
      }
    }
    if (supported == null) {
      if (detachedPreview &&
          (state.goalSupport != CodexGoalSupport.unknown ||
              state.advancedGoalControlSupported)) {
        emit(
          state.copyWith(
            goalSupport: CodexGoalSupport.unknown,
            advancedGoalControlSupported: false,
          ),
        );
      }
      return;
    }
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
    final pagingGeneration = ++_localHistoryPagingGeneration;
    var handled = false;
    _historyBootstrapInFlight = true;
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
    } finally {
      _historyBootstrapInFlight = false;
    }
    if (isClosed) return;
    if (pagingGeneration != _localHistoryPagingGeneration) return;
    _historyBootstrapSucceeded = handled;
    if (!handled) {
      localHistoryPaging.value = const LocalHistoryPagingState();
      if (!_historyFallbackRequested) {
        _historyFallbackRequested = true;
        _bridge.requestSessionHistory(sessionId);
      }
      return;
    }
    localHistoryPaging.value = _currentLocalHistoryPagingState();
    _settleStatusFromRuntimeAfterLocalBootstrap();
  }

  LocalHistoryPagingState _currentLocalHistoryPagingState() {
    final localAvailable =
        _bridge.hasSessionHistoryPaging &&
        _bridge.hasLocalSessionHistory(sessionId);
    final remoteAvailable = _bridge.hasRemoteSessionHistoryPaging(sessionId);
    final available = localAvailable || remoteAvailable;
    return LocalHistoryPagingState(
      enabled: available,
      hasMore: localAvailable
          ? _bridge.hasOlderLocalSessionHistory(sessionId)
          : remoteAvailable && _bridge.hasOlderRemoteSessionHistory(sessionId),
    );
  }

  void _onLocalHistoryAvailabilityChanged(
    LocalSessionHistoryAvailabilityChange change,
  ) {
    if (isClosed || change.runtimeSessionId != sessionId) return;
    _localHistoryUserIndexComplete = false;
    localHistoryPaging.value = change.available
        ? _currentLocalHistoryPagingState()
        : const LocalHistoryPagingState();
    localHistoryIndexRevision.value += 1;
  }

  void _settleStatusFromRuntimeAfterLocalBootstrap() {
    final runtime = _runtimeSessionFrom(_bridge.sessions);
    if (runtime == null) return;

    // A current-connection SessionInfo can settle the visible status before
    // the local mirror finishes loading. Preserve that authority, but still
    // perform the one canonical history read required to reconcile transient
    // approvals, queues, tool activity, and active streaming state.
    if (state.status == ProcessStatus.starting) {
      final runtimeStatus = ProcessStatus.fromString(runtime.status);
      if (runtimeStatus != ProcessStatus.starting) {
        _restoreRuntimeInteractions(runtime);
        _statusRefreshTimer?.cancel();
        _statusRefreshTimer = null;
        emit(state.copyWith(status: runtimeStatus));
      }
    }
    final needsCanonicalRuntimeReconciliation =
        state.status == ProcessStatus.running ||
        state.status == ProcessStatus.waitingApproval ||
        state.status == ProcessStatus.compacting;
    if (needsCanonicalRuntimeReconciliation && !_historyFallbackRequested) {
      // The durable mirror intentionally excludes transient approvals, queues,
      // partial tool activity, and active streaming state. SessionInfo restores
      // the actionable controls immediately; one canonical history read then
      // reconciles the remaining live runtime details.
      _historyFallbackRequested = true;
      _bridge.requestSessionHistory(sessionId);
    }
  }

  void _disableLocalHistoryPaging({bool expectCanonicalHistory = false}) {
    if (expectCanonicalHistory && _localMirrorEntryCount > 0) {
      _discardLocalMirrorOnNextCanonicalHistory = true;
    }
    if (_localHistoryUserIndexComplete) {
      _localHistoryUserIndexComplete = false;
      localHistoryIndexRevision.value += 1;
    }
    _localHistoryPagingGeneration += 1;
    localHistoryPaging.value = const LocalHistoryPagingState();
    _bridge.invalidateLocalSessionHistoryPaging(sessionId);
  }

  Future<bool> loadOlderLocalHistory() async {
    if (detachedPreview) {
      return _loadOlderDetachedHistory();
    }
    final currentPaging = localHistoryPaging.value;
    if (isClosed ||
        !currentPaging.enabled ||
        !currentPaging.hasMore ||
        currentPaging.loading) {
      return false;
    }
    final generation = _localHistoryPagingGeneration;
    localHistoryPaging.value = currentPaging.copyWith(
      loading: true,
      clearError: true,
    );
    try {
      final page = await _bridge.tryLoadOlderLocalSessionHistory(
        runtimeSessionId: sessionId,
      );
      if (isClosed || generation != _localHistoryPagingGeneration) {
        return false;
      }
      if (page == null) {
        localHistoryPaging.value = _currentLocalHistoryPagingState();
        return false;
      }
      if (page.messages.isNotEmpty) {
        final history = HistoryMessage(messages: page.messages);
        final decoded = _handler.handle(
          history,
          isBackground: true,
          isCodex: isCodex,
          ignoredToolUseIds: _respondedToolUseIds,
          historyTimestampAnchor: page.timestampAnchor,
        );
        _applyUpdate(
          ChatStateUpdate(
            entriesToPrepend: decoded.entriesToAdd,
            toolUseIdsToHide: decoded.toolUseIdsToHide,
            localHistoryPage: true,
          ),
          history,
        );
      }
      localHistoryPaging.value = LocalHistoryPagingState(
        enabled: true,
        hasMore: page.hasMore,
      );
      return true;
    } catch (error, stackTrace) {
      if (isClosed || generation != _localHistoryPagingGeneration) {
        return false;
      }
      logger.warning(
        '[session:$sessionId] Failed to load older local history',
        error,
        stackTrace,
      );
      localHistoryPaging.value = localHistoryPaging.value.copyWith(
        loading: false,
        error: error,
      );
      return false;
    }
  }

  Future<bool> _loadOlderDetachedHistory() async {
    final loader = _detachedHistoryPageLoader;
    final currentPaging = localHistoryPaging.value;
    if (isClosed ||
        loader == null ||
        !currentPaging.enabled ||
        !currentPaging.hasMore ||
        currentPaging.loading) {
      return false;
    }
    localHistoryPaging.value = currentPaging.copyWith(
      loading: true,
      clearError: true,
    );
    try {
      final result = await loader();
      if (isClosed) return false;
      if (!result.loaded && result.hasMore) {
        // A page that made no progress is not a successful load. Treating it
        // as success leaves hasMore=true with no error, so the list's automatic
        // paging control loops forever behind a spinner and Retry never gets a
        // terminal state to replace.
        throw StateError('Conversation history page made no progress.');
      }
      localHistoryPaging.value = LocalHistoryPagingState(
        enabled: true,
        hasMore: result.hasMore,
      );
      return result.loaded;
    } catch (error, stackTrace) {
      if (isClosed) return false;
      logger.warning(
        '[session:$sessionId] Failed to load older durable history',
        error,
        stackTrace,
      );
      localHistoryPaging.value = localHistoryPaging.value.copyWith(
        loading: false,
        error: error,
      );
      return false;
    }
  }

  HistoryToolDetailLoadState historyToolDetailState(String gapId) =>
      _historyToolDetailStates[gapId] ?? const HistoryToolDetailLoadState();

  Future<bool> loadHistoryToolDetailGap(HistoryToolDetailGap gap) {
    final existing = _historyToolDetailFlights[gap.gapId];
    if (existing != null) return existing;
    final flight = _loadHistoryToolDetailGap(gap);
    _historyToolDetailFlights[gap.gapId] = flight;
    return flight.whenComplete(() {
      if (identical(_historyToolDetailFlights[gap.gapId], flight)) {
        _historyToolDetailFlights.remove(gap.gapId);
      }
    });
  }

  Future<bool> _loadHistoryToolDetailGap(HistoryToolDetailGap gap) async {
    final current = historyToolDetailState(gap.gapId);
    if (isClosed || current.loading || current.complete) return false;
    final requestedIds = gap.toolUseIds
        .skip(current.nextOffset)
        .take(8)
        .toList(growable: false);
    if (requestedIds.isEmpty) {
      _historyToolDetailStates[gap.gapId] = current.copyWith(complete: true);
      historyToolDetailRevision.value += 1;
      return false;
    }
    _historyToolDetailStates[gap.gapId] = current.copyWith(
      loading: true,
      clearError: true,
    );
    historyToolDetailRevision.value += 1;
    try {
      final details = _detachedHistoryToolDetailLoader == null
          ? await _bridge.requestHistoryToolDetails(
              runtimeSessionId: sessionId,
              toolUseIds: requestedIds,
            )
          : await _detachedHistoryToolDetailLoader!(gap, requestedIds);
      if (isClosed || !_historyToolDetailGapIsActive(gap.gapId)) {
        return false;
      }
      if (details == null) {
        throw StateError('History tool details are unavailable.');
      }
      final latest = historyToolDetailState(gap.gapId);
      final merged = <String, HistoryToolDetail>{
        for (final detail in latest.details) detail.toolUseId: detail,
        for (final detail in details) detail.toolUseId: detail,
      };
      final nextOffset = current.nextOffset + requestedIds.length;
      _historyToolDetailStates[gap.gapId] = HistoryToolDetailLoadState(
        details: List.unmodifiable(merged.values),
        nextOffset: nextOffset,
        complete: nextOffset >= gap.toolUseIds.length,
      );
      historyToolDetailRevision.value += 1;
      return true;
    } catch (error, stackTrace) {
      if (isClosed || !_historyToolDetailGapIsActive(gap.gapId)) {
        return false;
      }
      logger.warning(
        '[session:$sessionId] Failed to load history tool details',
        error,
        stackTrace,
      );
      _historyToolDetailStates[gap.gapId] = current.copyWith(
        loading: false,
        error: error,
      );
      historyToolDetailRevision.value += 1;
      return false;
    }
  }

  bool _historyToolDetailGapIsActive(String gapId) {
    for (final entry in state.entries) {
      if (entry case ServerChatEntry(
        message: AssistantServerMessage(:final historyToolDetailGaps),
      )) {
        for (final gap in historyToolDetailGaps) {
          if (gap.gapId == gapId) return true;
        }
      }
    }
    return false;
  }

  void _pruneHistoryToolDetailStates(List<ChatEntry> entries) {
    if (_historyToolDetailStates.isEmpty) return;
    final activeGapIds = <String>{};
    for (final entry in entries) {
      if (entry case ServerChatEntry(
        message: AssistantServerMessage(:final historyToolDetailGaps),
      )) {
        activeGapIds.addAll(historyToolDetailGaps.map((gap) => gap.gapId));
      }
    }
    final before = _historyToolDetailStates.length;
    _historyToolDetailStates.removeWhere(
      (gapId, _) => !activeGapIds.contains(gapId),
    );
    if (_historyToolDetailStates.length != before) {
      historyToolDetailRevision.value += 1;
    }
  }

  // ---------------------------------------------------------------------------
  // Message processing
  // ---------------------------------------------------------------------------

  void _restoreBackgroundDesktopContinuity(
    DesktopContinuityBacklogSnapshot snapshot,
  ) {
    final boundThreadId = state.claudeSessionId?.trim();
    if (boundThreadId != null &&
        boundThreadId.isNotEmpty &&
        boundThreadId != snapshot.threadId) {
      return;
    }
    if (_restoredDesktopContinuityThreadId != snapshot.threadId) {
      _restoredDesktopContinuityItemKeys.clear();
    }
    _restoredDesktopContinuityThreadId = snapshot.threadId;
    _restoredDesktopContinuityItemKeys.addAll(snapshot.itemKeys);
    _desktopContinuityItemKeys.addAll(snapshot.itemKeys);

    if (snapshot.state == CodexDesktopContinuityState.running) {
      _setExternalDesktopRunning(
        snapshot.turnId,
        turnSteerable: snapshot.turnSteerable,
      );
    } else if (snapshot.state == CodexDesktopContinuityState.idle) {
      _statusFromHistoryFallback = false;
      _statusFromSessionSnapshot = false;
      externalDesktopTurnSteerable.value = false;
      emit(
        state.copyWith(
          status: snapshot.handoffQueued
              ? ProcessStatus.running
              : ProcessStatus.idle,
          externalDesktopTurnActive: false,
          externalDesktopTurnId: null,
          approval: const ApprovalState.none(),
        ),
      );
    }

    for (final buffered in snapshot.transientPayloads) {
      _applyExternalDesktopPayload(buffered.payload, turnId: buffered.turnId);
    }
    if (snapshot.truncated) {
      logger.info(
        '[session:$sessionId] Desktop continuity buffer was bounded; '
        'canonical history refresh will reconcile the omitted prefix',
      );
    }
  }

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
      final runtime = _runtimeSessionFrom(_bridge.sessions);
      if (runtime != null) _restoreRuntimeInteractions(runtime);
    } catch (e, st) {
      logger.error(
        '[session:$sessionId] Failed to restore cached runtime messages',
        e,
        st,
      );
    }
  }

  void _restoreDeliveryPendingInput() {
    if (!isCodex) return;
    final pendingInputs = _bridge.deliveryPendingInputsForSession(sessionId);
    if (pendingInputs.isEmpty) return;
    final restoredEntries = <UserChatEntry>[];
    for (final pending in pendingInputs) {
      final clientMessageId = deliveryPendingClientMessageId(pending);
      if (clientMessageId == null) continue;
      _deliveryPendingInputs[clientMessageId] = pending;
      final alreadyVisible = state.entries.any(
        (entry) =>
            entry is UserChatEntry && entry.clientMessageId == clientMessageId,
      );
      if (alreadyVisible) continue;
      restoredEntries.add(
        UserChatEntry(
          pending.text,
          sessionId: sessionId,
          clientMessageId: clientMessageId,
          imageCount: pending.imageCount,
          status: MessageStatus.sending,
          timestamp: DateTime.tryParse(pending.createdAt)?.toLocal(),
        ),
      );
    }
    if (restoredEntries.isEmpty) return;
    emit(state.copyWith(entries: [...state.entries, ...restoredEntries]));
  }

  void _onMessage(ServerMessage msg) {
    var isLocalMirrorSnapshot = false;
    var discardLocalMirrorEntries = false;
    if (state.externalDesktopTurnActive &&
        msg is StatusMessage &&
        (msg.status == ProcessStatus.idle ||
            msg.status == ProcessStatus.starting)) {
      // The Bridge-owned app-server is idle while Codex Desktop independently
      // owns the durable thread. Its local status must not erase the external
      // running state that the rollout monitor has already established.
      return;
    }
    if (msg is SystemMessage &&
        msg.subtype == 'set_permission_mode' &&
        _captureSupersededPermissionAcknowledgement(msg)) {
      return;
    }
    _captureCodexServiceTier(msg);
    // Log errors prominently
    if (msg is ErrorMessage) {
      logger.error('[session:$sessionId] Error from bridge: ${msg.message}');
      _rollbackFailedModeChange(msg);
      if (isCodex && _handleGoalError(msg)) {
        return;
      }
      if (_isSessionNotFound(msg)) {
        _statusRefreshTimer?.cancel();
        _statusRefreshTimer = null;
        emit(state.copyWith(sessionUnavailable: true));
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
        final runtimeSessionId = runtimeSessionIdForRead;
        if (runtimeSessionId != null) {
          _bridge.patchSessionSandboxMode(
            runtimeSessionId,
            incomingSandbox.value,
          );
        }
      }
    }
    if (msg is SystemMessage && msg.provider == Provider.codex.value) {
      if (msg.subtype == 'set_codex_model') {
        if (_applyCodexModelAcknowledgement(msg)) {
          _clearPendingCodexModelRollback();
        }
      } else if (msg.subtype == 'set_codex_speed') {
        if (_applyCodexSpeedAcknowledgement(msg)) {
          _clearPendingCodexSpeedRollback();
        }
      }
      if (msg.settingsPersistence == 'runtime_only') {
        logger.warning(
          '[settings_projection] event=runtime_only_ack '
          'subtype=${msg.subtype} '
          'session=${diagnosticToken('session', sessionId)}',
        );
      }
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
      isLocalMirrorSnapshot = _bridge.isExternalSessionHistory(msg);
      if (!isLocalMirrorSnapshot && msg.historyWindow != null) {
        localHistoryPaging.value = _currentLocalHistoryPagingState();
      }
      if (localHistoryPaging.value.enabled) {
        if (isLocalMirrorSnapshot) {
          _localHistoryPagingGeneration += 1;
          localHistoryPaging.value = _currentLocalHistoryPagingState();
        }
      }
      if (!isLocalMirrorSnapshot && _discardLocalMirrorOnNextCanonicalHistory) {
        discardLocalMirrorEntries = true;
        _discardLocalMirrorOnNextCanonicalHistory = false;
      }
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
        historyTimestampAnchor: msg is HistoryMessage
            ? _bridge.externalSessionHistoryTimestampAnchor(msg)
            : null,
      );
      _applyUpdate(
        update,
        msg,
        isLocalMirrorSnapshot: isLocalMirrorSnapshot,
        discardLocalMirrorEntries: discardLocalMirrorEntries,
      );
      if (msg is HistoryMessage) {
        // Canonical and mirror history are durable snapshots, while pending
        // approvals/questions live only in the active runtime. Re-apply the
        // authoritative runtime interaction after history has rebuilt state so
        // a stale idle tail cannot dismiss a still-pending Plan approval.
        final runtime = _runtimeSessionFrom(_bridge.sessions);
        if (runtime != null) _restoreRuntimeInteractions(runtime);
      }
      if (isCodex && msg is SystemMessage && msg.subtype == 'init') {
        final threadId = state.claudeSessionId?.trim();
        _codexGoalThreadReady = threadId?.isNotEmpty == true;
        requestGoal();
      }
      if (msg is StatusMessage) {
        _statusFromHistoryFallback = false;
        _statusFromSessionSnapshot = false;
        _statusFromLiveMessage = true;
      }
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
    if (!_matchesBoundSessionId(error.sessionId)) return true;

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
    _goalReadAwaitingThread = false;
    _goalUserRefreshPending = false;
  }

  void _flushDeferredGoalRead() {
    if (!_goalReadAwaitingThread ||
        !_codexGoalThreadReady ||
        state.claudeSessionId?.trim().isNotEmpty != true) {
      return;
    }
    requestGoal();
  }

  void _applyGoalState(GoalStateMessage message) {
    if (!_matchesBoundSessionId(message.sessionId)) return;
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

  MessageStatus _mergeUserDeliveryStatus(
    MessageStatus current,
    MessageStatus incoming,
  ) {
    if (current == MessageStatus.providerAccepted ||
        current == MessageStatus.providerRejected) {
      return current;
    }
    if (incoming == MessageStatus.providerAccepted ||
        incoming == MessageStatus.providerRejected) {
      return incoming;
    }
    if (incoming == MessageStatus.bridgeAccepted) {
      return MessageStatus.bridgeAccepted;
    }
    if (current == MessageStatus.bridgeAccepted &&
        incoming == MessageStatus.sent) {
      // Ordinary online delivery has a single visible receipt. The second
      // check is reserved for an input that Bridge authoritatively placed in
      // the next-turn queue, where it is rendered by the queue panel.
      return MessageStatus.bridgeAccepted;
    }
    if (current == MessageStatus.bridgeAccepted &&
        incoming == MessageStatus.queued) {
      return current;
    }
    return incoming;
  }

  MessageStatus _preserveStagedUserStatus(MessageStatus current) {
    return switch (current) {
      MessageStatus.bridgeAccepted ||
      MessageStatus.providerAccepted ||
      MessageStatus.providerRejected => current,
      _ => MessageStatus.sent,
    };
  }

  void _applyUpdate(
    ChatStateUpdate update,
    ServerMessage originalMsg, {
    bool allowUserDelivery = true,
    ChatMessageHandler? sourceHandler,
    bool affectVisibleStreaming = true,
    bool isLocalMirrorSnapshot = false,
    bool discardLocalMirrorEntries = false,
  }) {
    final messageHandler = sourceHandler ?? _handler;
    final current = state;
    final preservePendingCodexPermissions =
        isCodex &&
        isPermissionChangePending &&
        (originalMsg is HistoryMessage ||
            (originalMsg is SystemMessage &&
                originalMsg.subtype != 'set_permission_mode'));
    final updateHasCodexPermissionPolicySignals =
        isCodex &&
        (update.permissionMode != null ||
            update.executionMode != null ||
            update.codexApprovalPolicy != null ||
            update.codexApprovalsReviewer?.trim().isNotEmpty == true ||
            update.codexPermissionsMode != null);
    final historyStatusIsFallbackOnly =
        originalMsg is HistoryMessage &&
        ((isCodex && _hasAuthoritativeSessionSnapshot) ||
            (!isCodex && _statusFromLiveMessage) ||
            (detachedPreview && _detachedProviderStatusObservedAt != null));
    final effectiveStatus = historyStatusIsFallbackOnly
        ? current.status
        : update.status;
    final markUserMessagesSent =
        update.markUserMessagesSent && allowUserDelivery;
    final userMessageStatus = allowUserDelivery
        ? update.userMessageStatus
        : null;

    // --- Streaming state (separate cubit) ---
    if (update.resetStreaming) {
      messageHandler.currentStreaming = null;
      if (affectVisibleStreaming) _streamingCubit.reset();
    }

    // Handle stream delta → streaming cubit
    if (originalMsg is StreamDeltaMessage) {
      if (affectVisibleStreaming) {
        _streamingCubit.appendText(originalMsg.text);
      }
      return; // No main state update needed for deltas
    }
    if (originalMsg is ThinkingDeltaMessage) {
      if (affectVisibleStreaming) {
        _streamingCubit.appendThinking(originalMsg.text);
      }
      return;
    }

    // --- Build new entries list ---
    var entries = current.entries;
    var didModifyEntries = false;

    // When assistant message arrives and streaming was active, reset streaming
    if (originalMsg is AssistantServerMessage &&
        messageHandler.currentStreaming == null &&
        affectVisibleStreaming) {
      _streamingCubit.reset();
    }

    // Prepend entries (past history)
    if (update.entriesToPrepend.isNotEmpty) {
      if (update.localHistoryPage) {
        _localMirrorEntryCount += update.entriesToPrepend.length;
      } else {
        _pastEntryCount += update.entriesToPrepend.length;
      }
      entries = [...update.entriesToPrepend, ...entries];
      didModifyEntries = true;
    }

    // Advance at most one user message status per server event.
    // This keeps FIFO behavior when multiple user messages are queued.
    //
    // - queued ack: first sending -> queued
    // - sent ack / assistant/result: first queued -> sent
    //   (fallback to first sending -> sent for non-queued path)
    if (markUserMessagesSent || userMessageStatus != null) {
      final targetStatus =
          userMessageStatus ??
          (update.markUserMessagesQueued
              ? MessageStatus.queued
              : MessageStatus.sent);
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
        final nextStatus = _mergeUserDeliveryStatus(entry.status, targetStatus);
        if (nextStatus != entry.status) {
          final updatedEntry = UserChatEntry(
            entry.text,
            sessionId: entry.sessionId,
            clientMessageId: entry.clientMessageId,
            providerItemId: entry.providerItemId,
            historyTurnId: entry.historyTurnId,
            imageBytesList: entry.imageBytesList,
            imageUrls: entry.imageUrls,
            imageCount: entry.imageCount,
            status: nextStatus,
            messageUuid: entry.messageUuid,
            timestamp: entry.timestamp,
            timestampIsAuthoritative: entry.timestampIsAuthoritative,
          );
          entries = [...entries];
          entries[targetIndex] = updatedEntry;
          didModifyEntries = true;
        }
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
                : e.status == MessageStatus.sending) &&
            e.status != MessageStatus.bridgeAccepted &&
            e.status != MessageStatus.providerAccepted &&
            e.status != MessageStatus.providerRejected) {
          changed = true;
          return UserChatEntry(
            e.text,
            sessionId: e.sessionId,
            clientMessageId: e.clientMessageId,
            providerItemId: e.providerItemId,
            historyTurnId: e.historyTurnId,
            imageBytesList: e.imageBytesList,
            imageUrls: e.imageUrls,
            imageCount: e.imageCount,
            status: MessageStatus.failed,
            messageUuid: e.messageUuid,
            timestamp: e.timestamp,
            timestampIsAuthoritative: e.timestampIsAuthoritative,
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
        :providerItemId,
        :historyTurnId,
        :imageCount,
        :imageUrls,
        :timestamp,
        :timestampIsAuthoritative,
      ) = update.userUuidUpdate!;
      var matchedUserEntry = false;
      var matchedIndex = -1;
      for (int i = entries.length - 1; i >= 0; i--) {
        final e = entries[i];
        if (e is! UserChatEntry) continue;
        final bothProviderIdsKnown =
            e.providerItemId?.isNotEmpty == true &&
            providerItemId?.isNotEmpty == true;
        final matches = bothProviderIdsKnown
            ? e.providerItemId == providerItemId
            : (clientMessageId != null &&
                      e.clientMessageId == clientMessageId) ||
                  (uuid != null && e.messageUuid == uuid);
        if (matches) {
          matchedIndex = i;
          break;
        }
      }
      // The app-server user item event does not always echo clientUserMessageId.
      // Correlate it only with the oldest unresolved local envelope of the
      // same shape. Never match two entries that already have provider ids.
      if (matchedIndex == -1 && providerItemId?.isNotEmpty == true) {
        matchedIndex = entries.indexWhere(
          (entry) =>
              entry is UserChatEntry &&
              entry.providerItemId?.isNotEmpty != true &&
              entry.clientMessageId?.isNotEmpty == true &&
              entry.status != MessageStatus.sent &&
              entry.text == text &&
              entry.imageCount == imageCount,
        );
      }
      // Legacy Bridges can lack both provider and client identities. Keep the
      // old fallback restricted to an unresolved entry, never a stable turn.
      if (matchedIndex == -1 &&
          providerItemId == null &&
          clientMessageId == null) {
        matchedIndex = entries.indexWhere(
          (entry) =>
              entry is UserChatEntry &&
              entry.providerItemId?.isNotEmpty != true &&
              entry.messageUuid == null &&
              entry.status != MessageStatus.sent &&
              entry.text == text,
        );
      }
      if (matchedIndex != -1) {
        final e = entries[matchedIndex] as UserChatEntry;
        matchedUserEntry = true;
        final shouldReplaceTimestamp =
            timestamp != null &&
            ((timestampIsAuthoritative &&
                    (!e.timestampIsAuthoritative ||
                        e.timestamp != timestamp)) ||
                (!timestampIsAuthoritative &&
                    !e.timestampIsAuthoritative &&
                    e.timestamp != timestamp));
        if (e.messageUuid != uuid ||
            e.providerItemId != providerItemId ||
            e.historyTurnId != historyTurnId ||
            shouldReplaceTimestamp) {
          entries = [...entries];
          entries[matchedIndex] = UserChatEntry(
            e.text,
            sessionId: e.sessionId,
            clientMessageId: e.clientMessageId ?? clientMessageId,
            providerItemId: providerItemId ?? e.providerItemId,
            historyTurnId: historyTurnId ?? e.historyTurnId,
            imageBytesList: e.imageBytesList,
            imageUrls: imageUrls.isNotEmpty ? imageUrls : e.imageUrls,
            imageCount: imageCount > 0 ? imageCount : e.imageCount,
            status: _preserveStagedUserStatus(e.status),
            messageUuid: uuid ?? e.messageUuid,
            timestamp: shouldReplaceTimestamp ? timestamp : e.timestamp,
            timestampIsAuthoritative: shouldReplaceTimestamp
                ? timestampIsAuthoritative
                : e.timestampIsAuthoritative,
          );
          didModifyEntries = true;
        }
      }
      if (!matchedUserEntry) {
        entries = [
          ...entries,
          UserChatEntry(
            text,
            sessionId: sessionId,
            clientMessageId: clientMessageId,
            providerItemId: providerItemId,
            historyTurnId: historyTurnId,
            imageCount: imageCount,
            imageUrls: imageUrls,
            status: MessageStatus.sent,
            messageUuid: uuid,
            timestamp: timestamp,
            timestampIsAuthoritative: timestampIsAuthoritative,
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
      final allExistingNonPast = entries.skip(_pastEntryCount).toList();
      final localMirrorPrefix = _localMirrorEntryCount.clamp(
        0,
        allExistingNonPast.length,
      );
      final preservePagedLocalMirror =
          originalMsg is HistoryMessage &&
          !isLocalMirrorSnapshot &&
          !discardLocalMirrorEntries &&
          localHistoryPaging.value.enabled &&
          localMirrorPrefix > 0;

      if (preservePagedLocalMirror) {
        final existingMirrorEntries = allExistingNonPast
            .take(localMirrorPrefix)
            .toList(growable: false);
        final canonicalTail = _canonicalTailForPagedLocalMirror(
          mirrorEntries: existingMirrorEntries,
          canonicalEntries: nonStreamingEntries,
        );
        final merged = _mergeCanonicalHistoryIntoPagedEntries(
          existingEntries: allExistingNonPast,
          canonicalEntries: canonicalTail,
        );
        entries = [...pastEntries, ...merged];
        _localMirrorEntryCount = _mirrorPrefixExtent(
          mergedEntries: merged,
          mirrorEntries: existingMirrorEntries,
        );
        didModifyEntries = true;
      } else {
        final existingNonPast =
            (isLocalMirrorSnapshot || discardLocalMirrorEntries) &&
                localMirrorPrefix > 0
            ? allExistingNonPast.skip(localMirrorPrefix).toList()
            : allExistingNonPast;
        final mergedHistoryEntries = _mergeRicherLiveAssistantEntries(
          existingEntries: existingNonPast,
          historyEntries: nonStreamingEntries,
        );

        final reconciledHistoryEntries = _mergeHistoryWithPreservedLiveEntries(
          existingNonPast: existingNonPast,
          historyEntries: mergedHistoryEntries,
        );

        entries = [...pastEntries, ...reconciledHistoryEntries];
        if (isLocalMirrorSnapshot) {
          _localMirrorEntryCount = _mirrorPrefixExtent(
            mergedEntries: reconciledHistoryEntries,
            mirrorEntries: mergedHistoryEntries,
          );
        } else if (discardLocalMirrorEntries) {
          _localMirrorEntryCount = 0;
        }

        // Preserve local data (image bytes, timestamps) from existing entries
        // that the server history does not contain.
        // Match by strong identity first. Older Bridge history can omit both
        // ids, so text remains a last-resort fallback, but each chronological
        // occurrence may be consumed only once. A single-value text map makes
        // repeated prompts share the last turn's images and timestamp.
        final existingUsers = existingNonPast.whereType<UserChatEntry>().toList(
          growable: false,
        );
        final consumedExistingUserIndexes = <int>{};
        UserChatEntry? takeExistingUserData(UserChatEntry incoming) {
          int find(bool Function(UserChatEntry candidate) matches) {
            for (var index = 0; index < existingUsers.length; index++) {
              if (consumedExistingUserIndexes.contains(index)) continue;
              if (matches(existingUsers[index])) return index;
            }
            return -1;
          }

          var matchIndex = -1;
          final incomingProviderItemId = incoming.providerItemId;
          if (incomingProviderItemId?.isNotEmpty == true) {
            matchIndex = find(
              (candidate) => candidate.providerItemId == incomingProviderItemId,
            );
          }
          final incomingUuid = incoming.messageUuid;
          if (matchIndex == -1 && incomingUuid?.isNotEmpty == true) {
            matchIndex = find((candidate) {
              final candidateProviderItemId = candidate.providerItemId;
              if (incomingProviderItemId?.isNotEmpty == true &&
                  candidateProviderItemId?.isNotEmpty == true &&
                  candidateProviderItemId != incomingProviderItemId) {
                return false;
              }
              return candidate.messageUuid == incomingUuid;
            });
          }
          final incomingClientId = incoming.clientMessageId;
          if (matchIndex == -1 && incomingClientId?.isNotEmpty == true) {
            matchIndex = find(
              (candidate) => candidate.clientMessageId == incomingClientId,
            );
          }
          if (matchIndex == -1) {
            matchIndex = find((candidate) {
              if (candidate.text != incoming.text) return false;
              final candidateProviderItemId = candidate.providerItemId;
              if (incomingProviderItemId?.isNotEmpty == true &&
                  candidateProviderItemId?.isNotEmpty == true) {
                return false;
              }
              final candidateUuid = candidate.messageUuid;
              if (incomingUuid?.isNotEmpty == true &&
                  candidateUuid?.isNotEmpty == true) {
                return false;
              }
              final candidateClientId = candidate.clientMessageId;
              if (incomingClientId?.isNotEmpty == true &&
                  candidateClientId?.isNotEmpty == true) {
                return false;
              }
              return true;
            });
          }
          if (matchIndex == -1) return null;
          consumedExistingUserIndexes.add(matchIndex);
          return existingUsers[matchIndex];
        }

        if (existingUsers.isNotEmpty) {
          for (int i = 0; i < entries.length; i++) {
            final e = entries[i];
            if (e is! UserChatEntry) continue;
            final existing = takeExistingUserData(e);
            if (existing == null) continue;
            final needsImages =
                e.imageBytesList.isEmpty && existing.imageBytesList.isNotEmpty;
            final existingTimestampIsPreferred =
                existing.timestampIsAuthoritative &&
                !e.timestampIsAuthoritative;
            final needsTimestamp =
                existingTimestampIsPreferred ||
                (!e.timestampIsAuthoritative &&
                    existing.timestamp != e.timestamp);
            if (needsImages || needsTimestamp) {
              entries[i] = UserChatEntry(
                e.text,
                sessionId: e.sessionId,
                clientMessageId: e.clientMessageId,
                providerItemId: e.providerItemId,
                historyTurnId: e.historyTurnId,
                imageBytesList: needsImages
                    ? existing.imageBytesList
                    : e.imageBytesList,
                imageUrls: e.imageUrls,
                imageCount: e.imageCount,
                status: e.status,
                messageUuid: e.messageUuid,
                timestamp: needsTimestamp ? existing.timestamp : e.timestamp,
                timestampIsAuthoritative: needsTimestamp
                    ? existing.timestampIsAuthoritative
                    : e.timestampIsAuthoritative,
              );
            }
          }
        }

        didModifyEntries = true;
      }
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
    if (effectiveStatus != null && effectiveStatus != ProcessStatus.starting) {
      _statusRefreshTimer?.cancel();
      _statusRefreshTimer = null;
    }
    final shouldRestartStatusHistory =
        !current.externalDesktopTurnActive &&
        effectiveStatus == ProcessStatus.starting &&
        current.status != ProcessStatus.starting;

    // --- Update hidden tool use IDs (for subagent summary compression) ---
    var hiddenToolUseIds = current.hiddenToolUseIds;
    if (update.toolUseIdsToHide.isNotEmpty) {
      hiddenToolUseIds = {...hiddenToolUseIds, ...update.toolUseIdsToHide};
    }

    var nextEntries = didModifyEntries ? entries : current.entries;
    if (_dismissedCodexWarningKeys.isNotEmpty) {
      nextEntries = nextEntries
          .where((entry) => !_isDismissedCodexWarningEntry(entry))
          .toList(growable: false);
    }
    if (didModifyEntries && _historyToolDetailStates.isNotEmpty) {
      _pruneHistoryToolDetailStates(nextEntries);
    }

    // --- Apply state update ---
    final historyUsesSessionSnapshotAuthority =
        originalMsg is HistoryMessage && isCodex;
    final historyUsesDetachedSettingsAuthority =
        originalMsg is HistoryMessage &&
        detachedPreview &&
        _detachedProviderSettingsObservedAt != null;
    final newClaudeSessionId =
        historyUsesSessionSnapshotAuthority && _sessionSnapshotOwnsThreadId
        ? current.claudeSessionId
        : (update.claudeSessionId ?? current.claudeSessionId);
    final newProjectPath =
        historyUsesSessionSnapshotAuthority && _sessionSnapshotOwnsProjectPath
        ? current.projectPath
        : (update.projectPath?.trim().isNotEmpty == true
              ? update.projectPath
              : current.projectPath);
    final deliveryMessageClientId = switch (originalMsg) {
      InputAckMessage(:final clientMessageId) => clientMessageId,
      InputDeliveryStatusMessage(:final clientMessageId) => clientMessageId,
      InputRejectedMessage(:final clientMessageId) => clientMessageId,
      _ => null,
    };
    final keepPendingQueueCorrelation = switch (originalMsg) {
      InputAckMessage(:final queued) => queued,
      InputDeliveryStatusMessage(:final queued) => queued,
      _ => false,
    };
    if (deliveryMessageClientId != null && !keepPendingQueueCorrelation) {
      _bridge.clearDeliveryPendingInput(
        sessionId,
        itemId: '$deliveryPendingQueuedInputPrefix$deliveryMessageClientId',
      );
    }

    if (update.queuedInputs != null) {
      _setAuthoritativeQueuedInputs(
        update.queuedInputs!,
        update.queuedInputLimit ?? _queuedInputLimit,
      );
    } else if (update.clearQueuedInput) {
      _setAuthoritativeQueuedInputs(const [], _queuedInputLimit);
    }
    var nextQueuedInput = update.clearQueuedInput
        ? null
        : _mergeQueuedInputUpdate(current.queuedInput, update.queuedInput);
    if (originalMsg is ConversationQueueMessage) {
      final resolvedQueue = List<QueuedInputItem>.of(queuedInputs.value);
      for (var index = 0; index < resolvedQueue.length; index++) {
        var item = resolvedQueue[index];
        var queueClientMessageId = queuedInputClientMessageId(item);
        if (queueClientMessageId == null) {
          // Older Bridges did not echo clientMessageId. Correlate only a
          // unique same-text pending item; never guess across duplicates.
          final legacyPendingMatches = _deliveryPendingInputs.entries
              .where((entry) => entry.value.text == item.text)
              .toList(growable: false);
          final legacyQueueMatches = resolvedQueue
              .where((candidate) => candidate.text == item.text)
              .length;
          if (legacyPendingMatches.length == 1 && legacyQueueMatches == 1) {
            final match = legacyPendingMatches.single;
            queueClientMessageId = match.key;
            item = item.mergeDeliveryStateFrom(match.value);
          }
        }
        if (queueClientMessageId != null) {
          final optimisticIndex = nextEntries.indexWhere(
            (entry) =>
                entry is UserChatEntry &&
                entry.clientMessageId == queueClientMessageId,
          );
          if (optimisticIndex != -1) {
            final optimistic = nextEntries[optimisticIndex] as UserChatEntry;
            final queueStage = switch (optimistic.status) {
              MessageStatus.providerAccepted =>
                QueuedInputDeliveryStage.providerAccepted,
              MessageStatus.providerRejected =>
                QueuedInputDeliveryStage.providerRejected,
              _ => QueuedInputDeliveryStage.bridgeAccepted,
            };
            item = item.withDeliveryStage(queueStage);
            nextEntries = [
              ...nextEntries.take(optimisticIndex),
              ...nextEntries.skip(optimisticIndex + 1),
            ];
          }
          _deliveryPendingInputs.remove(queueClientMessageId);
          _bridge.clearDeliveryPendingInput(
            sessionId,
            itemId: '$deliveryPendingQueuedInputPrefix$queueClientMessageId',
          );
        }
        resolvedQueue[index] = item;
      }
      _setAuthoritativeQueuedInputs(resolvedQueue, originalMsg.limit);
      nextQueuedInput = resolvedQueue.isEmpty ? null : resolvedQueue.first;
    }
    QueuedInputItem? deliveredPendingInput;
    String? deliveredPendingClientMessageId;
    if (originalMsg is InputAckMessage && originalMsg.queued == false) {
      final offlineClientMessageId = offlineQueuedClientMessageId(
        nextQueuedInput,
      );
      final acknowledgedClientMessageId =
          originalMsg.clientMessageId ?? offlineClientMessageId;
      final hiddenDeliveryPending = acknowledgedClientMessageId != null
          ? _deliveryPendingInputs.remove(acknowledgedClientMessageId)
          : null;
      final offlineMatch =
          offlineClientMessageId != null &&
          offlineClientMessageId == acknowledgedClientMessageId;
      final deliveryMatch =
          deliveryPendingClientMessageId(nextQueuedInput) ==
          acknowledgedClientMessageId;
      if (offlineMatch || deliveryMatch) {
        deliveredPendingInput = nextQueuedInput;
        deliveredPendingClientMessageId = acknowledgedClientMessageId;
        if (acknowledgedClientMessageId != null) {
          _deliveryPendingInputs.remove(acknowledgedClientMessageId);
        }
      } else if (hiddenDeliveryPending != null) {
        deliveredPendingInput = hiddenDeliveryPending;
        deliveredPendingClientMessageId = acknowledgedClientMessageId;
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
    if (originalMsg is InputDeliveryStatusMessage) {
      if (!originalMsg.queued || nextQueuedInput != null) {
        _deliveryPendingInputs.remove(originalMsg.clientMessageId);
      }
      if (isDeliveryPendingQueuedInput(nextQueuedInput) &&
          queuedInputClientMessageId(nextQueuedInput) ==
              originalMsg.clientMessageId) {
        nextQueuedInput = null;
      } else {
        nextQueuedInput = _advanceQueuedInputDelivery(
          nextQueuedInput,
          originalMsg.clientMessageId,
          originalMsg.stage == InputDeliveryStage.providerAccepted
              ? QueuedInputDeliveryStage.providerAccepted
              : QueuedInputDeliveryStage.providerRejected,
          error: originalMsg.error,
        );
      }
      final authoritativeHead = _advanceAuthoritativeQueuedInputDelivery(
        originalMsg.clientMessageId,
        originalMsg.stage == InputDeliveryStage.providerAccepted
            ? QueuedInputDeliveryStage.providerAccepted
            : QueuedInputDeliveryStage.providerRejected,
        error: originalMsg.error,
      );
      if (authoritativeHead != null &&
          queuedInputItemsShareIdentity(
            authoritativeHead,
            nextQueuedInput ?? authoritativeHead,
          )) {
        nextQueuedInput = authoritativeHead;
      }
    }
    if (originalMsg is InputAckMessage && originalMsg.queued == true) {
      // Keep the internal correlation until the authoritative queue snapshot
      // arrives. Legacy snapshots may omit clientMessageId and need this
      // one-message bridge to migrate the optimistic bubble without guessing.
      if (originalMsg.stage == InputAckStage.bridgeAccepted) {
        nextQueuedInput = _advanceQueuedInputDelivery(
          nextQueuedInput,
          originalMsg.clientMessageId,
          QueuedInputDeliveryStage.bridgeAccepted,
        );
        final authoritativeHead = _advanceAuthoritativeQueuedInputDelivery(
          originalMsg.clientMessageId,
          QueuedInputDeliveryStage.bridgeAccepted,
        );
        if (authoritativeHead != null &&
            queuedInputItemsShareIdentity(
              authoritativeHead,
              nextQueuedInput ?? authoritativeHead,
            )) {
          nextQueuedInput = authoritativeHead;
        }
      }
    }
    if (originalMsg is! InputAckMessage &&
        markUserMessagesSent &&
        isDeliveryPendingQueuedInput(nextQueuedInput)) {
      deliveredPendingInput = nextQueuedInput;
      deliveredPendingClientMessageId = deliveryPendingClientMessageId(
        nextQueuedInput,
      );
      nextQueuedInput = null;
      if (deliveredPendingClientMessageId != null) {
        _deliveryPendingInputs.remove(deliveredPendingClientMessageId);
        _bridge.clearDeliveryPendingInput(
          sessionId,
          itemId:
              '$deliveryPendingQueuedInputPrefix$deliveredPendingClientMessageId',
        );
      }
    } else if (originalMsg is! InputAckMessage &&
        markUserMessagesSent &&
        _deliveryPendingInputs.isNotEmpty) {
      final entry = _deliveryPendingInputs.entries.first;
      _deliveryPendingInputs.remove(entry.key);
      deliveredPendingInput = entry.value;
      deliveredPendingClientMessageId = entry.key;
      _bridge.clearDeliveryPendingInput(
        sessionId,
        itemId: '$deliveryPendingQueuedInputPrefix${entry.key}',
      );
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
        status: current.externalDesktopTurnActive
            ? ProcessStatus.running
            : (effectiveStatus ?? current.status),
        entries: nextEntries,
        approval: approval,
        totalCost: usage.totalCost,
        totalDuration: usage.totalDuration,
        inPlanMode: preservePendingCodexPermissions
            ? current.inPlanMode
            : (update.inPlanMode ?? current.inPlanMode),
        permissionMode: preservePendingCodexPermissions
            ? current.permissionMode
            : (update.permissionMode ?? current.permissionMode),
        executionMode: preservePendingCodexPermissions
            ? current.executionMode
            : (update.executionMode ?? current.executionMode),
        codexPermissionStateKnown: preservePendingCodexPermissions
            ? current.codexPermissionStateKnown
            : (current.codexPermissionStateKnown ||
                  updateHasCodexPermissionPolicySignals),
        codexApprovalPolicy: preservePendingCodexPermissions
            ? current.codexApprovalPolicy
            : (update.codexApprovalPolicy ?? current.codexApprovalPolicy),
        codexApprovalsReviewer: preservePendingCodexPermissions
            ? current.codexApprovalsReviewer
            : (update.codexApprovalsReviewer ?? current.codexApprovalsReviewer),
        codexPermissionsMode: preservePendingCodexPermissions
            ? current.codexPermissionsMode
            : (update.codexPermissionsMode ?? current.codexPermissionsMode),
        sandboxMode: preservePendingCodexPermissions
            ? current.sandboxMode
            : (update.sandboxMode ?? current.sandboxMode),
        codexModel:
            (historyUsesSessionSnapshotAuthority &&
                    _sessionSnapshotOwnsModel) ||
                (historyUsesDetachedSettingsAuthority &&
                    _detachedProviderOwnsModel)
            ? current.codexModel
            : (update.codexModel ?? current.codexModel),
        codexModelReasoningEffort:
            (historyUsesSessionSnapshotAuthority &&
                    _sessionSnapshotOwnsEffort) ||
                (historyUsesDetachedSettingsAuthority &&
                    _detachedProviderOwnsEffort)
            ? current.codexModelReasoningEffort
            : (update.codexModelReasoningEffort ??
                  current.codexModelReasoningEffort),
        codexSpeed:
            (historyUsesSessionSnapshotAuthority &&
                    _sessionSnapshotOwnsSpeed) ||
                (historyUsesDetachedSettingsAuthority &&
                    _detachedProviderOwnsSpeed)
            ? current.codexSpeed
            : (update.codexSpeed ?? current.codexSpeed),
        planMode: preservePendingCodexPermissions
            ? current.planMode
            : (update.planMode ?? current.planMode),
        slashCommands: update.slashCommands ?? current.slashCommands,
        queuedInput: nextQueuedInput,
        claudeSessionId: newClaudeSessionId,
        projectPath: newProjectPath,
        hiddenToolUseIds: hiddenToolUseIds,
      ),
    );
    if (shouldRestartStatusHistory) {
      _startStatusRefreshTimer();
    }
    if (originalMsg is HistoryMessage &&
        effectiveStatus != null &&
        effectiveStatus != current.status) {
      _statusFromHistoryFallback = isCodex
          ? !_hasAuthoritativeSessionSnapshot
          : !_statusFromLiveMessage;
      _statusFromSessionSnapshot = false;
    }

    if (isCodex &&
        (newClaudeSessionId != _desktopContinuityThreadId ||
            newProjectPath != _desktopContinuityProjectPath)) {
      _ensureDesktopContinuityWatch(
        threadId: newClaudeSessionId,
        projectPath: newProjectPath,
      );
    }

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

  List<ChatEntry> _mergeHistoryWithPreservedLiveEntries({
    required List<ChatEntry> existingNonPast,
    required List<ChatEntry> historyEntries,
  }) {
    final lastUserIndex = existingNonPast.lastIndexWhere(
      (entry) => entry is UserChatEntry,
    );
    final candidates = existingNonPast
        .skip(lastUserIndex == -1 ? 0 : lastUserIndex)
        .toList(growable: false);
    final historyCurrentUserIndex = lastUserIndex == -1
        ? -1
        : historyEntries.lastIndexWhere(
            (entry) => _entriesEquivalentForTurnBoundary(
              entry,
              existingNonPast[lastUserIndex],
            ),
          );
    // A durable page can receive a live assistant item before SQLite has
    // committed the optimistic user envelope that preceded it. In that case
    // the last local user has no canonical match yet, but a stable assistant
    // id may already exist earlier in the freshly committed cache window.
    // Let strong/scoped aliases reconcile across the whole durable window;
    // runtime-only pages retain the stricter current-turn boundary.
    final minimumCanonicalIndex = detachedPreview
        ? 0
        : lastUserIndex == -1
        ? 0
        : historyCurrentUserIndex == -1
        ? historyEntries.length
        : historyCurrentUserIndex;
    return _weavePreservedEntriesIntoCanonicalHistory(
      canonicalEntries: historyEntries,
      existingEntries: candidates,
      minimumCanonicalIndex: minimumCanonicalIndex,
      unanchoredExistingBeforeCanonical: false,
      allowBroadLegacyAliases: true,
    );
  }

  /// Keeps the downloaded mirror as a progressively pageable prefix while a
  /// canonical runtime snapshot refreshes the overlapping/live tail.
  ///
  /// A canonical history can be wider than the turn-aware render window. When
  /// it overlaps the local prefix, entries before the first stable overlap are
  /// older than the rendered mirror window and must remain available only via
  /// paging; appending them at the live tail would reorder the conversation.
  List<ChatEntry> _canonicalTailForPagedLocalMirror({
    required List<ChatEntry> mirrorEntries,
    required List<ChatEntry> canonicalEntries,
  }) {
    final projectedCanonicalEntries = selectTurnAwareChatEntryWindow(
      canonicalEntries,
    );
    for (
      var canonicalIndex = 0;
      canonicalIndex < projectedCanonicalEntries.length;
      canonicalIndex++
    ) {
      final canonical = projectedCanonicalEntries[canonicalIndex];
      var mirrorIndex = _indexOfEquivalentEntry(mirrorEntries, canonical);
      if (mirrorIndex == -1 && _isCanonicalAssistantEntry(canonical)) {
        mirrorIndex = _indexOfProvisionalAssistantAlias(
          mirrorEntries,
          canonical,
        );
      }
      if (mirrorIndex != -1) {
        return projectedCanonicalEntries.sublist(canonicalIndex);
      }
    }
    // No shared stable envelope normally means the canonical snapshot begins
    // after the last downloaded envelope (for example a newly started turn).
    // Provider-thread identity is already fenced by the Bridge binding, so
    // append it as a live tail instead of discarding the offline copy.
    return projectedCanonicalEntries;
  }

  List<ChatEntry> _mergeCanonicalHistoryIntoPagedEntries({
    required List<ChatEntry> existingEntries,
    required List<ChatEntry> canonicalEntries,
  }) {
    return _weavePreservedEntriesIntoCanonicalHistory(
      canonicalEntries: canonicalEntries,
      existingEntries: existingEntries,
      minimumCanonicalIndex: 0,
      // With no shared envelope these are two adjacent windows: downloaded
      // mirror first, newer canonical/runtime tail second.
      unanchoredExistingBeforeCanonical: true,
      allowBroadLegacyAliases: false,
    );
  }

  int _mirrorPrefixExtent({
    required List<ChatEntry> mergedEntries,
    required List<ChatEntry> mirrorEntries,
  }) {
    if (mergedEntries.isEmpty || mirrorEntries.isEmpty) return 0;
    final aliasLookup = _buildCanonicalAliasLookup(mergedEntries);
    final consumedMergedIndexes = <int>{};
    var lastMirrorIndex = -1;
    for (final mirrorEntry in mirrorEntries) {
      final index = _indexOfCanonicalAliasInRange(
        mergedEntries,
        mirrorEntry,
        consumedMergedIndexes,
        aliasLookup: aliasLookup,
        start: lastMirrorIndex + 1,
        end: mergedEntries.length,
        allowBroadLegacyAliases: true,
      );
      if (index == -1) continue;
      _consumeCanonicalAlias(
        aliasLookup,
        consumedMergedIndexes,
        index,
        mergedEntries[index],
      );
      lastMirrorIndex = index;
    }
    // Canonical items inserted between two mirror anchors belong to the same
    // locally available window. Extending the prefix through the final mirror
    // anchor keeps later paging contiguous without classifying a live tail
    // after that anchor as downloaded history.
    return lastMirrorIndex + 1;
  }

  /// Reconciles a canonical ordered snapshot with live/cache-only entries
  /// without flattening every unmatched entry onto the end of the transcript.
  ///
  /// Stable provider ids (and bounded legacy aliases) act as anchors. An
  /// unmatched live entry stays after its preceding canonical anchor and
  /// before the next one, preserving the order observed on the socket while
  /// leaving canonical order authoritative. No display timestamp participates
  /// in ordering.
  List<ChatEntry> _weavePreservedEntriesIntoCanonicalHistory({
    required List<ChatEntry> canonicalEntries,
    required List<ChatEntry> existingEntries,
    required int minimumCanonicalIndex,
    required bool unanchoredExistingBeforeCanonical,
    required bool allowBroadLegacyAliases,
  }) {
    final canonical = List<ChatEntry>.from(canonicalEntries);
    final minimum = minimumCanonicalIndex < 0
        ? 0
        : minimumCanonicalIndex > canonical.length
        ? canonical.length
        : minimumCanonicalIndex;
    final before = List.generate(
      canonical.length,
      (_) => <ChatEntry>[],
      growable: false,
    );
    final after = List.generate(
      canonical.length,
      (_) => <ChatEntry>[],
      growable: false,
    );
    final aliasLookup = _buildCanonicalAliasLookup(canonical);
    final consumedCanonicalIndexes = <int>{};
    final leadingUnanchored = <ChatEntry>[];
    var lastAnchor = minimum - 1;
    var foundAnchor = false;

    for (final existing in existingEntries) {
      final forwardStart = lastAnchor + 1 > minimum ? lastAnchor + 1 : minimum;
      var matchIndex = _indexOfCanonicalAliasInRange(
        canonical,
        existing,
        consumedCanonicalIndexes,
        aliasLookup: aliasLookup,
        start: forwardStart,
        end: canonical.length,
        allowBroadLegacyAliases: allowBroadLegacyAliases,
      );
      if (matchIndex == -1 && lastAnchor >= minimum) {
        // If the existing list was already scrambled, consume an equivalent
        // canonical entry behind the current anchor but never move the anchor
        // backwards. The canonical sequence repairs that old ordering.
        matchIndex = _indexOfCanonicalAliasInRange(
          canonical,
          existing,
          consumedCanonicalIndexes,
          aliasLookup: aliasLookup,
          start: minimum,
          end: lastAnchor + 1 > canonical.length
              ? canonical.length
              : lastAnchor + 1,
          allowBroadLegacyAliases: allowBroadLegacyAliases,
        );
        if (matchIndex != -1) {
          _consumeCanonicalAlias(
            aliasLookup,
            consumedCanonicalIndexes,
            matchIndex,
            canonical[matchIndex],
          );
          canonical[matchIndex] = _mergeCanonicalMirrorEntry(
            existing,
            canonical[matchIndex],
          );
          continue;
        }
      }
      if (matchIndex != -1) {
        _consumeCanonicalAlias(
          aliasLookup,
          consumedCanonicalIndexes,
          matchIndex,
          canonical[matchIndex],
        );
        canonical[matchIndex] = _mergeCanonicalMirrorEntry(
          existing,
          canonical[matchIndex],
        );
        if (!foundAnchor && leadingUnanchored.isNotEmpty) {
          before[matchIndex].addAll(leadingUnanchored);
          leadingUnanchored.clear();
        }
        foundAnchor = true;
        lastAnchor = matchIndex;
        continue;
      }
      if (!_shouldPreserveEntryAcrossHistoryReplace(existing)) continue;
      if (foundAnchor) {
        after[lastAnchor].add(existing);
      } else {
        leadingUnanchored.add(existing);
      }
    }

    if (!foundAnchor) {
      return unanchoredExistingBeforeCanonical
          ? [...leadingUnanchored, ...canonical]
          : [...canonical, ...leadingUnanchored];
    }

    final merged = <ChatEntry>[];
    for (var index = 0; index < canonical.length; index++) {
      merged
        ..addAll(before[index])
        ..add(canonical[index])
        ..addAll(after[index]);
    }
    return merged;
  }

  int _indexOfCanonicalAliasInRange(
    List<ChatEntry> canonicalEntries,
    ChatEntry existing,
    Set<int> excludedIndexes, {
    required _CanonicalAliasLookup aliasLookup,
    required int start,
    required int end,
    required bool allowBroadLegacyAliases,
  }) {
    final exactMatch = _firstIndexedAliasMatch(
      aliasLookup.exactIndexes,
      _entryExactAliasKeys(existing),
      canonicalEntries,
      excludedIndexes,
      start: start,
      end: end,
      predicate: (canonical) => _entriesEquivalent(canonical, existing),
    );
    if (exactMatch != -1) return exactMatch;

    // Older history can omit one side of a pending user message's stable
    // correlation. Restrict that fallback to the same text/image signature
    // before applying the original equivalence predicate.
    if (existing is UserChatEntry) {
      final weakKey = _entryWeakKey(existing);
      final stableKey = _entryStableKey(existing);
      final candidateScopes = stableKey == null
          ? existing.status == MessageStatus.sent
                ? const ['user-pending']
                : const ['base']
          : existing.status == MessageStatus.sent
          ? const ['user-no-stable-pending']
          : const ['user-no-stable', 'user-stable'];
      final userFallback = _firstIndexedAliasMatch(
        aliasLookup.weakIndexes,
        weakKey == null
            ? const []
            : candidateScopes.map(
                (scope) => _scopedWeakAliasKey(scope, weakKey),
              ),
        canonicalEntries,
        excludedIndexes,
        start: start,
        end: end,
        predicate: (canonical) => _entriesEquivalent(
          canonical,
          existing,
          // A pending local user has a client ID before provider history can
          // assign its durable UUID. The turn-boundary search constrains this
          // weak match to the corresponding canonical occurrence.
          allowWeakMatch: existing.status != MessageStatus.sent,
        ),
      );
      if (userFallback != -1) return userFallback;
      // A broad text-only match must never merge two sent user messages with
      // different stable identities. The scoped fallback above already
      // covers the only compatible legacy case: one side lacks correlation
      // and at least one side is still pending.
      return -1;
    }

    if (existing is ServerChatEntry &&
        existing.message is AssistantServerMessage) {
      final weakKey = _entryWeakKey(existing);
      final provisionalMatch = _firstIndexedAliasMatch(
        aliasLookup.weakIndexes,
        weakKey == null
            ? const []
            : [_scopedWeakAliasKey('assistant-with-uuid', weakKey)],
        canonicalEntries,
        excludedIndexes,
        start: start,
        end: end,
        predicate: (canonical) =>
            _isProvisionalAssistantAlias(existing, canonical),
      );
      if (provisionalMatch != -1) return provisionalMatch;
      // Two stable assistant ids with the same text remain distinct.
      return -1;
    }
    if (!allowBroadLegacyAliases && !_canWeakMatchAppendedEntry(existing)) {
      return -1;
    }
    final weakKey = _entryWeakKey(existing);
    return _firstIndexedAliasMatch(
      aliasLookup.weakIndexes,
      weakKey == null ? const [] : [_scopedWeakAliasKey('base', weakKey)],
      canonicalEntries,
      excludedIndexes,
      start: start,
      end: end,
      predicate: (canonical) =>
          _entriesEquivalent(canonical, existing, allowWeakMatch: true),
    );
  }

  _CanonicalAliasLookup _buildCanonicalAliasLookup(List<ChatEntry> entries) {
    final exactIndexLists = <String, List<int>>{};
    final weakIndexLists = <String, List<int>>{};
    for (var index = 0; index < entries.length; index++) {
      final entry = entries[index];
      for (final key in _entryExactAliasKeys(entry)) {
        (exactIndexLists[key] ??= <int>[]).add(index);
      }
      for (final key in _entryWeakAliasLookupKeys(entry)) {
        (weakIndexLists[key] ??= <int>[]).add(index);
      }
    }
    return _CanonicalAliasLookup(
      exactIndexes: {
        for (final entry in exactIndexLists.entries)
          entry.key: _CanonicalAliasBucket(entry.value),
      },
      weakIndexes: {
        for (final entry in weakIndexLists.entries)
          entry.key: _CanonicalAliasBucket(entry.value),
      },
    );
  }

  void _consumeCanonicalAlias(
    _CanonicalAliasLookup lookup,
    Set<int> consumedIndexes,
    int index,
    ChatEntry canonicalEntry,
  ) {
    if (!consumedIndexes.add(index)) return;
    for (final key in _entryExactAliasKeys(canonicalEntry)) {
      lookup.exactIndexes[key]?.consumeCanonicalIndex(index);
    }
    for (final key in _entryWeakAliasLookupKeys(canonicalEntry)) {
      lookup.weakIndexes[key]?.consumeCanonicalIndex(index);
    }
  }

  Iterable<String> _entryExactAliasKeys(ChatEntry entry) sync* {
    if (entry case ServerChatEntry(
      message: AssistantServerMessage(:final messageUuid, :final message),
    )) {
      if (message.id.isNotEmpty) yield 'assistant:id:${message.id}';
      if (messageUuid?.isNotEmpty == true) {
        yield 'assistant:uuid:$messageUuid';
      }
      return;
    }
    final stableKey = _entryStableKey(entry);
    if (stableKey != null) yield stableKey;
  }

  Iterable<String> _entryWeakAliasLookupKeys(ChatEntry entry) sync* {
    final weakKey = _entryWeakKey(entry);
    if (weakKey == null) return;
    yield _scopedWeakAliasKey('base', weakKey);
    if (entry is UserChatEntry) {
      final hasStableKey = _entryStableKey(entry) != null;
      final isPending = entry.status != MessageStatus.sent;
      if (hasStableKey) {
        yield _scopedWeakAliasKey('user-stable', weakKey);
      }
      if (!hasStableKey) {
        yield _scopedWeakAliasKey('user-no-stable', weakKey);
        if (isPending) {
          yield _scopedWeakAliasKey('user-no-stable-pending', weakKey);
        }
      }
      if (isPending) {
        yield _scopedWeakAliasKey('user-pending', weakKey);
      }
    } else if (entry case ServerChatEntry(
      message: AssistantServerMessage(:final messageUuid),
    )) {
      if (messageUuid?.isNotEmpty == true) {
        yield _scopedWeakAliasKey('assistant-with-uuid', weakKey);
      }
    }
  }

  String _scopedWeakAliasKey(String scope, String weakKey) =>
      '$scope\u0000$weakKey';

  int _firstIndexedAliasMatch(
    Map<String, _CanonicalAliasBucket> indexByKey,
    Iterable<String> keys,
    List<ChatEntry> canonicalEntries,
    Set<int> excludedIndexes, {
    required int start,
    required int end,
    required bool Function(ChatEntry canonical) predicate,
  }) {
    var earliest = -1;
    for (final key in keys) {
      final bucket = indexByKey[key];
      if (bucket == null) continue;
      var offset = bucket.firstAvailableOffset(start);
      while (offset < bucket.indexes.length) {
        final index = bucket.indexes[offset];
        if (index >= end || (earliest != -1 && index >= earliest)) break;
        if (!excludedIndexes.contains(index) &&
            predicate(canonicalEntries[index])) {
          earliest = index;
          break;
        }
        offset = bucket.nextAvailableOffset(offset + 1);
      }
    }
    return earliest;
  }

  ChatEntry _mergeCanonicalMirrorEntry(
    ChatEntry existing,
    ChatEntry canonical,
  ) {
    if (existing is UserChatEntry && canonical is UserChatEntry) {
      final preferredTimestamp = _preferredTimestamp(existing, canonical);
      return UserChatEntry(
        canonical.text.isNotEmpty ? canonical.text : existing.text,
        sessionId: canonical.sessionId ?? existing.sessionId,
        clientMessageId: existing.clientMessageId ?? canonical.clientMessageId,
        providerItemId: canonical.providerItemId ?? existing.providerItemId,
        historyTurnId: canonical.historyTurnId ?? existing.historyTurnId,
        imageBytesList: existing.imageBytesList.isNotEmpty
            ? existing.imageBytesList
            : canonical.imageBytesList,
        imageUrls: canonical.imageUrls.isNotEmpty
            ? canonical.imageUrls
            : existing.imageUrls,
        imageCount: canonical.imageCount > 0
            ? canonical.imageCount
            : existing.imageCount,
        status: canonical.status == MessageStatus.sent
            ? _preserveStagedUserStatus(existing.status)
            : existing.status,
        messageUuid: canonical.messageUuid ?? existing.messageUuid,
        timestamp: preferredTimestamp?.value,
        timestampIsAuthoritative: preferredTimestamp?.isAuthoritative ?? false,
      );
    }
    return _mergeEquivalentEntry(existing, canonical);
  }

  bool _entriesEquivalentForTurnBoundary(ChatEntry a, ChatEntry b) {
    if (a is UserChatEntry && b is UserChatEntry) {
      final aProviderItemId = a.providerItemId;
      final bProviderItemId = b.providerItemId;
      if (aProviderItemId?.isNotEmpty == true &&
          bProviderItemId?.isNotEmpty == true) {
        return aProviderItemId == bProviderItemId;
      }
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
    final consumedExistingIndexes = <int>{};
    return historyEntries.map((historyEntry) {
      var existingIndex = _indexOfEquivalentEntryExcluding(
        existingEntries,
        historyEntry,
        consumedExistingIndexes,
      );
      if (existingIndex == -1) {
        existingIndex = _indexOfProvisionalAssistantAlias(
          existingEntries,
          historyEntry,
          excludedIndexes: consumedExistingIndexes,
        );
      }
      if (existingIndex == -1) return historyEntry;
      final existingEntry = existingEntries[existingIndex];

      final sameMergeableMessageKind =
          (existingEntry is ServerChatEntry &&
              historyEntry is ServerChatEntry &&
              existingEntry.message is AssistantServerMessage &&
              historyEntry.message is AssistantServerMessage) ||
          (existingEntry is ServerChatEntry &&
              historyEntry is ServerChatEntry &&
              existingEntry.message is ToolResultMessage &&
              historyEntry.message is ToolResultMessage);
      if (!sameMergeableMessageKind) return historyEntry;
      consumedExistingIndexes.add(existingIndex);
      return _mergeEquivalentEntry(existingEntry, historyEntry);
    }).toList();
  }

  ({List<ChatEntry> entries, bool didChange}) _appendEntriesDeduped(
    List<ChatEntry> current,
    List<ChatEntry> additions,
  ) {
    var next = current;
    var didChange = false;

    for (final addition in additions) {
      var matchIndex = _indexOfEquivalentEntry(next, addition);
      if (matchIndex == -1 && _isCanonicalAssistantEntry(addition)) {
        final lastUserIndex = next.lastIndexWhere((e) => e is UserChatEntry);
        matchIndex = _indexOfProvisionalAssistantAlias(
          next,
          addition,
          start: lastUserIndex + 1,
        );
      }
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
    return entry is ServerChatEntry &&
        (entry.message is ResultMessage ||
            entry.message is GuardianApprovalMessage);
  }

  bool _isCanonicalAssistantEntry(ChatEntry entry) {
    if (entry case ServerChatEntry(
      message: AssistantServerMessage(:final messageUuid),
    )) {
      return messageUuid?.isNotEmpty == true;
    }
    if (entry is ServerChatEntry &&
        (entry.message is ResultMessage ||
            entry.message is GuardianApprovalMessage)) {
      return true;
    }
    return false;
  }

  bool _isProvisionalAssistantAlias(ChatEntry existing, ChatEntry canonical) {
    if (existing is! ServerChatEntry || canonical is! ServerChatEntry) {
      return false;
    }
    final existingMessage = existing.message;
    final canonicalMessage = canonical.message;
    if (existingMessage is! AssistantServerMessage ||
        canonicalMessage is! AssistantServerMessage) {
      return false;
    }
    if (existingMessage.messageUuid?.isNotEmpty == true ||
        canonicalMessage.messageUuid?.isNotEmpty != true) {
      return false;
    }
    return _entriesEquivalent(existing, canonical, allowWeakMatch: true);
  }

  int _indexOfProvisionalAssistantAlias(
    List<ChatEntry> entries,
    ChatEntry canonical, {
    int start = 0,
    Set<int> excludedIndexes = const {},
  }) {
    for (var i = start; i < entries.length; i++) {
      if (excludedIndexes.contains(i)) continue;
      if (_isProvisionalAssistantAlias(entries[i], canonical)) return i;
    }
    return -1;
  }

  int _indexOfEquivalentEntryExcluding(
    List<ChatEntry> entries,
    ChatEntry target,
    Set<int> excludedIndexes,
  ) {
    for (var i = 0; i < entries.length; i++) {
      if (excludedIndexes.contains(i)) continue;
      if (_entriesEquivalent(entries[i], target)) return i;
    }
    return -1;
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
    if (a is UserChatEntry && b is UserChatEntry) {
      final aProviderItemId = a.providerItemId;
      final bProviderItemId = b.providerItemId;
      if (aProviderItemId?.isNotEmpty == true &&
          bProviderItemId?.isNotEmpty == true) {
        return aProviderItemId == bProviderItemId;
      }
      final aClientId = a.clientMessageId;
      final bClientId = b.clientMessageId;
      if (aClientId != null &&
          aClientId.isNotEmpty &&
          bClientId != null &&
          aClientId == bClientId) {
        return true;
      }
      final aUuid = a.messageUuid;
      final bUuid = b.messageUuid;
      if (aUuid != null &&
          aUuid.isNotEmpty &&
          bUuid != null &&
          aUuid == bUuid) {
        return true;
      }
    }
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
      final providerItemId = entry.providerItemId;
      if (providerItemId != null && providerItemId.isNotEmpty) {
        return 'user:provider:$providerItemId';
      }
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
        :final settingsPersistence,
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
          settingsPersistence,
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
      case GuardianApprovalMessage(
        :final risk,
        :final status,
        :final reason,
        :final authorization,
        :final reviewId,
        :final targetItemId,
        :final action,
      ):
        return [
          'guardian_approval',
          risk.name,
          status.name,
          authorization,
          reviewId,
          targetItemId,
          if (action != null) jsonEncode(action),
          reason,
        ].join('\u0001');
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
          entry.message is! InputDeliveryStatusMessage &&
          entry.message is! InputRejectedMessage &&
          entry.message is! ConversationQueueMessage;
    }
    return false;
  }

  ChatEntry _mergeEquivalentEntry(ChatEntry existing, ChatEntry incoming) {
    if (existing is UserChatEntry && incoming is UserChatEntry) {
      final preferredTimestamp = _preferredTimestamp(existing, incoming);
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
        providerItemId: incoming.providerItemId ?? existing.providerItemId,
        historyTurnId: incoming.historyTurnId ?? existing.historyTurnId,
        imageBytesList: imageBytes,
        imageUrls: imageUrls,
        imageCount: imageCount,
        status: incoming.status == MessageStatus.sent
            ? _preserveStagedUserStatus(existing.status)
            : existing.status,
        messageUuid: existing.messageUuid ?? incoming.messageUuid,
        timestamp: preferredTimestamp?.value,
        timestampIsAuthoritative: preferredTimestamp?.isAuthoritative ?? false,
      );
    }
    if (existing is ServerChatEntry && incoming is ServerChatEntry) {
      final preferredTimestamp = _preferredTimestamp(existing, incoming);
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
        var useIncomingContent =
            _assistantContentWeight(incomingContent) >=
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
            historyToolDetailGaps: useIncomingContent
                ? incomingMessage.historyToolDetailGaps
                : existingMessage.historyToolDetailGaps,
            artifactContentIndexOffset: useIncomingContent
                ? incomingMessage.artifactContentIndexOffset
                : existingMessage.artifactContentIndexOffset,
          ),
          timestamp: preferredTimestamp?.value,
          timestampIsAuthoritative:
              preferredTimestamp?.isAuthoritative ?? false,
        );
      }
      if (existingMessage is ToolResultMessage &&
          incomingMessage is ToolResultMessage) {
        return ServerChatEntry(
          ToolResultMessage(
            toolUseId: incomingMessage.toolUseId,
            content:
                incomingMessage.content.length >= existingMessage.content.length
                ? incomingMessage.content
                : existingMessage.content,
            toolName: incomingMessage.toolName ?? existingMessage.toolName,
            images: _mergeImages(
              existingMessage.images,
              incomingMessage.images,
            ),
            userMessageUuid:
                incomingMessage.userMessageUuid ??
                existingMessage.userMessageUuid,
            artifacts: _mergeArtifacts(
              existingMessage.artifacts,
              incomingMessage.artifacts,
            ),
          ),
          timestamp: preferredTimestamp?.value,
          timestampIsAuthoritative:
              preferredTimestamp?.isAuthoritative ?? false,
        );
      }
    }
    return existing;
  }

  ({DateTime value, bool isAuthoritative})? _preferredTimestamp(
    ChatEntry existing,
    ChatEntry incoming,
  ) {
    if (incoming.timestampIsAuthoritative ||
        !existing.timestampIsAuthoritative) {
      return (
        value: incoming.timestamp,
        isAuthoritative: incoming.timestampIsAuthoritative,
      );
    }
    return (
      value: existing.timestamp,
      isAuthoritative: existing.timestampIsAuthoritative,
    );
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
    // Identity is the link site (href + occurrence), not the target's
    // classification: kind and projectRelativePath can legitimately change
    // across Bridge versions for the same candidate, and a re-registration
    // after registry eviction must replace the stale chip, not duplicate it.
    return [
      artifact.source,
      artifact.textContentIndex ?? -1,
      originalHref,
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
  bool sendMessage(
    String text, {
    String? clientMessageId,
    List<({Uint8List bytes, String mimeType})>? images,
    Iterable<String>? mentionablePaths,
    Iterable<Map<String, String>>? additionalMentions,
  }) {
    final runtimeLease = _captureRuntimeMutationLease();
    if (runtimeLease == null) return false;
    final bridgeSessionId = runtimeLease.sessionId;
    final explicitMentions =
        additionalMentions?.toList(growable: false) ??
        const <Map<String, String>>[];
    if (text.trim().isEmpty &&
        (images == null || images.isEmpty) &&
        explicitMentions.isEmpty) {
      return false;
    }
    if (isCodex &&
        (images == null || images.isEmpty) &&
        explicitMentions.isEmpty) {
      final command = text.trim();
      switch (command) {
        case '/goal':
          requestGoal();
          return true;
        case '/goal edit':
          requestGoal();
          return true;
        case '/goal pause':
          setGoalStatus(CodexThreadGoalStatus.paused);
          return true;
        case '/goal resume':
          setGoalStatus(CodexThreadGoalStatus.active);
          return true;
        case '/goal clear':
          clearGoal();
          return true;
        default:
          if (command.startsWith('/goal ')) {
            setGoalObjective(command.substring('/goal '.length));
            return true;
          }
      }
    }
    final isOffline = !_bridge.isConnected;
    if (isCodex) {
      if (isOffline && state.queuedInput != null) return false;
      final supportsMultiple = _bridge.bridgeCapabilities.contains(
        codexMultiInputQueueCapability,
      );
      if (supportsMultiple) {
        final occupied =
            queuedInputs.value.length + _deliveryPendingInputs.length;
        if (occupied >= _queuedInputLimit) return false;
      } else if (state.queuedInput != null ||
          _deliveryPendingInputs.length >=
              BridgeService.maxDeliveryPendingInputsPerSession) {
        return false;
      }
    }

    final effectiveClientMessageId = clientMessageId?.trim().isNotEmpty == true
        ? clientMessageId!.trim()
        : _uuid.v4();
    final baseSeq = isOffline
        ? _bridge.cachedSessionHistorySeq(bridgeSessionId)
        : null;
    final structuredMentions = isCodex
        ? _extractCodexStructuredInputs(
            text,
            mentionablePaths: mentionablePaths,
            additionalMentions: explicitMentions,
          )
        : (
            skills: const <Map<String, String>>[],
            mentions: const <Map<String, String>>[],
          );

    final shouldUseOfflineQueuePanel = isCodex && isOffline;
    // Whether the provider will accept this turn immediately or queue it is a
    // Bridge-owned fact. Keep one optimistic bubble until the authoritative
    // input_ack/conversation_queue response decides the final presentation.
    final shouldAddLocalEntry = !shouldUseOfflineQueuePanel;
    if (shouldAddLocalEntry) {
      final entry = UserChatEntry(
        text,
        sessionId: sessionId,
        clientMessageId: effectiveClientMessageId,
        imageBytesList: images?.map((i) => i.bytes).toList(),
        status: isOffline ? MessageStatus.queued : MessageStatus.sending,
      );
      emit(state.copyWith(entries: [...state.entries, entry]));
    } else if (shouldUseOfflineQueuePanel) {
      emit(
        state.copyWith(
          queuedInput: QueuedInputItem(
            itemId: '$offlineQueuedInputPrefix$effectiveClientMessageId',
            text: text,
            createdAt: DateTime.now().toUtc().toIso8601String(),
            clientMessageId: effectiveClientMessageId,
            imageCount: images?.length ?? 0,
            skills: structuredMentions.skills,
            mentions: structuredMentions.mentions,
          ),
        ),
      );
    }

    final deliveryPendingItem = isCodex && !isOffline
        ? QueuedInputItem(
            itemId:
                '$deliveryPendingQueuedInputPrefix$effectiveClientMessageId',
            text: text,
            createdAt: DateTime.now().toUtc().toIso8601String(),
            clientMessageId: effectiveClientMessageId,
            imageCount: images?.length ?? 0,
            skills: structuredMentions.skills,
            mentions: structuredMentions.mentions,
          )
        : null;

    _dispatchInputInOrder(
      runtimeLease: runtimeLease,
      text: text,
      clientMessageId: effectiveClientMessageId,
      baseSeq: baseSeq,
      images: images?.toList(growable: false) ?? const [],
      skills: structuredMentions.skills,
      mentions: structuredMentions.mentions,
      deliveryPendingItem: deliveryPendingItem,
    );
    return true;
  }

  void _dispatchInputInOrder({
    required _RuntimeMutationLease runtimeLease,
    required String text,
    required String clientMessageId,
    required int? baseSeq,
    required List<ChatImageAttachment> images,
    required List<Map<String, String>> skills,
    required List<Map<String, String>> mentions,
    required QueuedInputItem? deliveryPendingItem,
  }) {
    if (images.isEmpty && _pendingInputDispatchCount == 0) {
      try {
        _dispatchPreparedInput(
          runtimeLease: runtimeLease,
          text: text,
          clientMessageId: clientMessageId,
          baseSeq: baseSeq,
          skills: skills,
          mentions: mentions,
          deliveryPendingItem: deliveryPendingItem,
        );
      } catch (error, stackTrace) {
        _handleInputDispatchFailure(
          bridgeSessionId: runtimeLease.sessionId,
          text: text,
          clientMessageId: clientMessageId,
          images: images,
          error: error,
          stackTrace: stackTrace,
        );
      }
      return;
    }

    _pendingInputDispatchCount++;
    _pendingInputDispatchIds.add(clientMessageId);
    final predecessor = _inputDispatchTail;
    final task = () async {
      try {
        await predecessor;
        if (_canceledInputDispatchIds.remove(clientMessageId)) return;
        _requireCurrentRuntimeMutationLease(runtimeLease);
        final imagePayloads = images.isEmpty
            ? null
            : await _imagePayloadEncoder(images);
        if (_canceledInputDispatchIds.remove(clientMessageId)) return;
        _requireCurrentRuntimeMutationLease(runtimeLease);
        _dispatchPreparedInput(
          runtimeLease: runtimeLease,
          text: text,
          clientMessageId: clientMessageId,
          baseSeq: baseSeq,
          imagePayloads: imagePayloads,
          skills: skills,
          mentions: mentions,
          deliveryPendingItem: deliveryPendingItem,
        );
      } catch (error, stackTrace) {
        _handleInputDispatchFailure(
          bridgeSessionId: runtimeLease.sessionId,
          text: text,
          clientMessageId: clientMessageId,
          images: images,
          error: error,
          stackTrace: stackTrace,
        );
      }
    }();
    _inputDispatchTail = task.whenComplete(() {
      _pendingInputDispatchCount--;
      _pendingInputDispatchIds.remove(clientMessageId);
      _canceledInputDispatchIds.remove(clientMessageId);
    });
  }

  void _dispatchPreparedInput({
    required _RuntimeMutationLease runtimeLease,
    required String text,
    required String clientMessageId,
    required int? baseSeq,
    List<Map<String, String>>? imagePayloads,
    required List<Map<String, String>> skills,
    required List<Map<String, String>> mentions,
    required QueuedInputItem? deliveryPendingItem,
  }) {
    _requireCurrentRuntimeMutationLease(runtimeLease);
    final bridgeSessionId = runtimeLease.sessionId;
    if (deliveryPendingItem != null) {
      if (!_bridge.setDeliveryPendingInput(
        bridgeSessionId,
        deliveryPendingItem,
      )) {
        throw StateError(
          'Too many unacknowledged inputs are waiting for this session.',
        );
      }
      if (!isClosed) {
        _deliveryPendingInputs[clientMessageId] = deliveryPendingItem;
      }
    }
    _bridge.send(
      ClientMessage.input(
        text,
        sessionId: bridgeSessionId,
        clientMessageId: clientMessageId,
        baseSeq: baseSeq,
        images: imagePayloads,
        skill: skills.isNotEmpty ? skills.first : null,
        skills: skills,
        mentions: mentions,
      ),
    );
  }

  void _handleInputDispatchFailure({
    required String bridgeSessionId,
    required String text,
    required String clientMessageId,
    required List<ChatImageAttachment> images,
    required Object error,
    required StackTrace stackTrace,
  }) {
    logger.warning(
      '[session:$sessionId] Failed to prepare or send input '
      'clientMessageId=$clientMessageId',
      error,
      stackTrace,
    );
    _deliveryPendingInputs.remove(clientMessageId);
    _bridge.clearDeliveryPendingInput(
      bridgeSessionId,
      itemId: '$deliveryPendingQueuedInputPrefix$clientMessageId',
    );
    if (isClosed) return;

    var matchedEntry = false;
    final nextEntries = state.entries.map((entry) {
      if (entry is! UserChatEntry || entry.clientMessageId != clientMessageId) {
        return entry;
      }
      matchedEntry = true;
      return UserChatEntry(
        entry.text,
        sessionId: entry.sessionId,
        clientMessageId: entry.clientMessageId,
        providerItemId: entry.providerItemId,
        historyTurnId: entry.historyTurnId,
        imageBytesList: entry.imageBytesList,
        imageUrls: entry.imageUrls,
        imageCount: entry.imageCount,
        status: MessageStatus.failed,
        messageUuid: entry.messageUuid,
        timestamp: entry.timestamp,
        timestampIsAuthoritative: entry.timestampIsAuthoritative,
      );
    }).toList();
    if (!matchedEntry) {
      nextEntries.add(
        UserChatEntry(
          text,
          sessionId: sessionId,
          clientMessageId: clientMessageId,
          imageBytesList: images.map((image) => image.bytes).toList(),
          imageCount: images.length,
          status: MessageStatus.failed,
        ),
      );
    }
    final queuedItem = state.queuedInput;
    final queuedClientMessageId =
        offlineQueuedClientMessageId(queuedItem) ??
        deliveryPendingClientMessageId(queuedItem);
    emit(
      state.copyWith(
        entries: nextEntries,
        queuedInput: queuedClientMessageId == clientMessageId
            ? null
            : queuedItem,
      ),
    );
  }

  void requestGoal({bool userInitiated = false}) {
    final runtimeSessionId = runtimeSessionIdForRead;
    if (runtimeSessionId == null) return;
    if (!isCodex || state.goalMutation != null) return;
    final effectiveUserInitiated =
        userInitiated || (_goalReadAwaitingThread && _goalUserRefreshPending);
    if (state.goalSupport == CodexGoalSupport.unsupported &&
        !effectiveUserInitiated) {
      return;
    }
    if (_goalReadPending) {
      _goalUserRefreshPending =
          _goalUserRefreshPending || effectiveUserInitiated;
      return;
    }
    if (!_bridge.isConnected) {
      if (effectiveUserInitiated) {
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
    if (!_codexGoalThreadReady ||
        state.claudeSessionId?.trim().isNotEmpty != true) {
      // A resumed session can publish its durable id before app-server has
      // actually bound that thread. Keep one coalesced read intent and retry
      // only after system/init or a non-starting authoritative SessionInfo.
      _goalReadAwaitingThread = true;
      _goalUserRefreshPending =
          _goalUserRefreshPending || effectiveUserInitiated;
      return;
    }
    try {
      _goalReadAwaitingThread = false;
      _goalReadPending = true;
      _goalUserRefreshPending = effectiveUserInitiated;
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
      _bridge.send(ClientMessage.getGoal(runtimeSessionId));
    } catch (error) {
      _completeGoalRead();
      emit(
        state.copyWith(
          goalStateLoaded: false,
          goalSupport: CodexGoalSupport.unknown,
          goalLoadErrorKind: CodexGoalErrorKind.readFailed,
          goalMutationError: effectiveUserInitiated ? error.toString() : null,
          goalMutationErrorKind: effectiveUserInitiated
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
      (changeId, runtimeSessionId) => ClientMessage.setGoal(
        sessionId: runtimeSessionId,
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
      (changeId, runtimeSessionId) => ClientMessage.setGoal(
        sessionId: runtimeSessionId,
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
      (changeId, runtimeSessionId) => ClientMessage.setGoal(
        sessionId: runtimeSessionId,
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
      (changeId, runtimeSessionId) => ClientMessage.setGoal(
        sessionId: runtimeSessionId,
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
      (changeId, runtimeSessionId) => ClientMessage.clearGoal(
        runtimeSessionId,
        goalChangeId: changeId,
        expectedGoalOperationSequence: state.goalOperationSequence,
      ),
    );
  }

  bool _beginGoalMutation(
    CodexGoalMutation mutation,
    ClientMessage Function(String changeId, String runtimeSessionId)
    buildMessage,
  ) {
    if (!isCodex || state.goalMutation != null) return false;
    final runtimeSessionId = _runtimeSessionIdForMutation(
      allowSteerable: false,
    );
    if (runtimeSessionId == null) return false;
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
      _bridge.send(buildMessage(mutation.id, runtimeSessionId));
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

  Future<bool> updateQueuedInput(QueuedInputItem item, String text) async {
    final runtimeSessionId = _runtimeSessionIdForMutation();
    if (runtimeSessionId == null) return false;
    if (!isCodex || text.trim().isEmpty) return false;
    if (isDeliveryPendingQueuedInput(item)) return false;
    final structuredMentions = _extractCodexStructuredInputs(text);
    final offlineClientMessageId = offlineQueuedClientMessageId(item);
    if (offlineClientMessageId != null) {
      final updated = QueuedInputItem(
        itemId: item.itemId,
        text: text,
        createdAt: item.createdAt,
        updatedAt: DateTime.now().toUtc().toIso8601String(),
        clientMessageId: item.clientMessageId,
        deliveryStage: item.deliveryStage,
        deliveryError: item.deliveryError,
        imageCount: item.imageCount,
        skills: structuredMentions.skills,
        mentions: structuredMentions.mentions,
      );
      final updatedInOutbox = await _bridge.updateOfflinePendingInput(
        sessionId: runtimeSessionId,
        clientMessageId: offlineClientMessageId,
        text: text,
        skills: structuredMentions.skills,
        mentions: structuredMentions.mentions,
      );
      if (!updatedInOutbox || isClosed) return false;
      if (state.queuedInput?.itemId == item.itemId) {
        emit(state.copyWith(queuedInput: updated));
      }
      return true;
    }
    try {
      _bridge.send(
        ClientMessage.updateQueuedInput(
          sessionId: runtimeSessionId,
          itemId: item.itemId,
          text: text,
          skills: structuredMentions.skills,
          mentions: structuredMentions.mentions,
        ),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  void steerQueuedInput(QueuedInputItem item) {
    final runtimeSessionId = _runtimeSessionIdForMutation();
    if (runtimeSessionId == null) return;
    if (!isCodex ||
        isOfflineQueuedInput(item) ||
        isDeliveryPendingQueuedInput(item)) {
      return;
    }
    if (state.externalDesktopTurnActive &&
        (state.externalDesktopTurnId == null ||
            !externalDesktopTurnSteerable.value)) {
      // A visible Desktop turn is not necessarily owned by this Bridge
      // runtime. Keep the item queued until exact session ownership is proven.
      return;
    }
    final externalTurn = state.externalDesktopTurnActive;
    final requiresExactExternalAuthority =
        externalTurn &&
        detachedPreview &&
        _bridge.bridgeCapabilities.contains(conversationSyncV2Capability);
    final codexSourceId = requiresExactExternalAuthority
        ? _bridge.codexSourceId?.trim()
        : null;
    final authorityGeneration = requiresExactExternalAuthority
        ? _detachedAuthorityGeneration?.trim()
        : null;
    if (requiresExactExternalAuthority &&
        (codexSourceId == null ||
            codexSourceId.isEmpty ||
            authorityGeneration == null ||
            authorityGeneration.isEmpty ||
            !_hasCurrentDetachedAuthorityLease)) {
      // Never let a queued guide cross an attachment/source generation merely
      // because its transient runtime session id was reused.
      return;
    }
    _bridge.send(
      ClientMessage.steerQueuedInput(
        sessionId: runtimeSessionId,
        itemId: item.itemId,
        expectedTurnId: state.externalDesktopTurnId,
        codexSourceId: codexSourceId,
        threadId: requiresExactExternalAuthority ? sessionId : null,
        authorityGeneration: authorityGeneration,
      ),
    );
  }

  Future<bool> cancelQueuedInput(QueuedInputItem item) async {
    final runtimeSessionId = _runtimeSessionIdForMutation();
    if (runtimeSessionId == null) return false;
    if (!isCodex) return false;
    if (isDeliveryPendingQueuedInput(item)) {
      final clientMessageId = deliveryPendingClientMessageId(item);
      if (clientMessageId != null) {
        _deliveryPendingInputs.remove(clientMessageId);
      }
      _bridge.clearDeliveryPendingInput(runtimeSessionId, itemId: item.itemId);
      if (state.queuedInput?.itemId == item.itemId) {
        emit(state.copyWith(queuedInput: null));
      }
      return true;
    }
    final offlineClientMessageId = offlineQueuedClientMessageId(item);
    if (offlineClientMessageId != null) {
      if (_pendingInputDispatchIds.contains(offlineClientMessageId)) {
        _canceledInputDispatchIds.add(offlineClientMessageId);
        if (state.queuedInput?.itemId == item.itemId) {
          emit(state.copyWith(queuedInput: null));
        }
        return true;
      }
      final canceledInOutbox = await _bridge.cancelOfflinePendingInput(
        sessionId: runtimeSessionId,
        clientMessageId: offlineClientMessageId,
      );
      if (!canceledInOutbox || isClosed) return false;
      if (state.queuedInput?.itemId == item.itemId) {
        emit(state.copyWith(queuedInput: null));
      }
      return true;
    }
    try {
      _bridge.send(
        ClientMessage.cancelQueuedInput(
          sessionId: runtimeSessionId,
          itemId: item.itemId,
        ),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Approve a pending tool execution.
  void approve(String toolUseId, {bool clearContext = false}) {
    final runtimeSessionId = _runtimeSessionIdForMutation();
    if (runtimeSessionId == null) return;
    final isExitPlanApproval = _isExitPlanApproval(toolUseId);
    logger.info(
      '[session:$sessionId] approve toolUseId=$toolUseId'
      '${clearContext ? ' clearContext' : ''}',
    );
    if (!_sendInteractiveResponse(
      ClientMessage.approve(
        toolUseId,
        clearContext: clearContext,
        sessionId: runtimeSessionId,
      ),
    )) {
      return;
    }
    _markToolUseResponded(toolUseId);
    _emitNextApprovalOrNone(
      toolUseId,
      exitPlanModeResolved: isExitPlanApproval,
    );
  }

  /// Approve a tool and always allow it in the future.
  void approveAlways(String toolUseId) {
    final runtimeSessionId = _runtimeSessionIdForMutation();
    if (runtimeSessionId == null) return;
    final isExitPlanApproval = _isExitPlanApproval(toolUseId);
    if (!_sendInteractiveResponse(
      ClientMessage.approveAlways(toolUseId, sessionId: runtimeSessionId),
    )) {
      return;
    }
    _markToolUseResponded(toolUseId);
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
    final runtimeSessionId = _runtimeSessionIdForMutation();
    if (runtimeSessionId == null) return;
    logger.info(
      '[session:$sessionId] install tool suggestion toolUseId=$toolUseId',
    );
    _sendInteractiveResponse(
      ClientMessage.installToolSuggestion(
        toolUseId,
        sessionId: runtimeSessionId,
      ),
    );
  }

  bool _sendInteractiveResponse(ClientMessage message) {
    try {
      _bridge.send(message);
      return true;
    } catch (error, stackTrace) {
      logger.warning(
        '[session:$sessionId] live interaction was not sent',
        error,
        stackTrace,
      );
      return false;
    }
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
          ? ApprovalState.askUser(toolUseId: next.toolUseId, input: next.input)
          : ApprovalState.permission(toolUseId: next.toolUseId, request: next);
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
    final runtimeSessionId = _runtimeSessionIdForMutation();
    if (runtimeSessionId == null) return;
    logger.info(
      '[session:$sessionId] reject toolUseId=$toolUseId'
      '${message != null ? ' msg=$message' : ''}',
    );
    if (!_sendInteractiveResponse(
      ClientMessage.reject(
        toolUseId,
        message: message,
        sessionId: runtimeSessionId,
      ),
    )) {
      return;
    }
    _markToolUseResponded(toolUseId);
    // Rejecting ExitPlanMode means "continue planning"; it does not resolve
    // Plan mode. Also advance to any other live interaction instead of hiding
    // the entire pending queue.
    _emitNextApprovalOrNone(toolUseId);
  }

  /// Answer an AskUserQuestion.
  void answer(String toolUseId, String result) {
    final runtimeSessionId = _runtimeSessionIdForMutation();
    if (runtimeSessionId == null) return;
    if (!_sendInteractiveResponse(
      ClientMessage.answer(toolUseId, result, sessionId: runtimeSessionId),
    )) {
      return;
    }
    _markToolUseResponded(toolUseId);
    _emitNextApprovalOrNone(toolUseId);
  }

  /// Interrupt the current operation.
  void interrupt() {
    if (stopActionDetachesDesktopTurn) {
      stop();
      return;
    }
    final runtimeSessionId = _runtimeSessionIdForMutation();
    if (runtimeSessionId == null) return;
    _bridge.interrupt(runtimeSessionId);
  }

  /// Change permission mode for Claude sessions.
  void setPermissionMode(PermissionMode mode) {
    final runtimeSessionId = _runtimeSessionIdForMutation(
      allowSteerable: false,
    );
    if (runtimeSessionId == null) return;
    logger.info('[session:$sessionId] setPermissionMode=${mode.value}');
    _pendingPermissionRollback = state.permissionMode;
    emit(
      state.copyWith(
        permissionMode: mode,
        inPlanMode: mode == PermissionMode.plan,
      ),
    );
    _bridge.patchSessionPermissionMode(runtimeSessionId, mode.value);
    _bridge.send(
      ClientMessage.setPermissionMode(mode.value, sessionId: runtimeSessionId),
    );

    // Persist per-session so that future resumes use this mode.
    final claudeSid = state.claudeSessionId;
    if (claudeSid != null && claudeSid.isNotEmpty) {
      _SessionSettingsHelper.save(claudeSid, {'permissionMode': mode.value});
    }
  }

  void setSessionModes({ExecutionMode? executionMode, bool? planMode}) {
    final runtimeSessionId = isCodex
        ? _runtimeSessionIdForSettingsMutation()
        : _runtimeSessionIdForMutation(allowSteerable: false);
    if (runtimeSessionId == null) return;
    if (!_allowCodexSettingsMutation()) return;
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
    final detachedTarget = isCodex
        ? _detachedSettingsMutationTarget(runtimeSessionId)
        : null;
    if (detachedPreview && isCodex && detachedTarget == null) return;
    final nextExecution = executionMode ?? state.executionMode;
    final nextPlanMode = planMode ?? state.planMode;
    final legacyMode = legacyPermissionModeFromModes(
      provider ?? Provider.claude,
      executionMode: nextExecution,
      planMode: nextPlanMode,
    );
    final codexPermissionsMode =
        isCodex &&
            state.codexPermissionStateKnown &&
            state.codexPermissionsMode != CodexPermissionsMode.custom
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
    _pendingCodexPermissionStateKnownRollback = state.codexPermissionStateKnown;
    _pendingPlanRollback = state.planMode;

    if (!detachedPreview) {
      emit(
        state.copyWith(
          permissionMode: legacyMode,
          executionMode: nextExecution,
          planMode: nextPlanMode,
          inPlanMode: nextPlanMode,
        ),
      );
      _bridge.patchSessionModes(
        runtimeSessionId,
        permissionMode: legacyMode.value,
        executionMode: nextExecution.value,
        planMode: nextPlanMode,
        approvalPolicy: codexApprovalPolicy,
        approvalsReviewer: codexApprovalsReviewer,
        codexPermissionsMode: codexPermissionsMode?.value,
      );
    }
    _bridge.send(
      ClientMessage.setSessionMode(
        legacyMode: legacyMode.value,
        executionMode: nextExecution.value,
        approvalPolicy: codexApprovalPolicy,
        approvalsReviewer: codexApprovalsReviewer,
        codexPermissionsMode: codexPermissionsMode?.value,
        planMode: nextPlanMode,
        sessionId: detachedTarget == null ? runtimeSessionId : null,
        detachedTarget: detachedTarget,
      ),
    );

    final claudeSid = state.claudeSessionId;
    if (!detachedPreview && claudeSid != null && claudeSid.isNotEmpty) {
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
    final runtimeSessionId = _runtimeSessionIdForSettingsMutation();
    if (runtimeSessionId == null) return;
    if (!_allowCodexSettingsMutation()) return;
    if (isPermissionChangePending) {
      logger.warning(
        '[session:$sessionId] Permission change pending; ignoring approval update',
      );
      return;
    }
    final detachedTarget = _detachedSettingsMutationTarget(runtimeSessionId);
    if (detachedPreview && detachedTarget == null) return;
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
    _pendingCodexPermissionStateKnownRollback = state.codexPermissionStateKnown;
    _pendingPlanRollback = state.planMode;

    const legacyMode = PermissionMode.acceptEdits;
    final derivedExecution = policy == CodexApprovalPolicy.never
        ? ExecutionMode.fullAccess
        : ExecutionMode.defaultMode;

    if (!detachedPreview) {
      emit(
        state.copyWith(
          permissionMode: legacyMode,
          executionMode: derivedExecution,
          codexPermissionStateKnown: true,
          codexApprovalPolicy: policy,
          codexApprovalsReviewer: normalizedReviewer,
          planMode: false,
          inPlanMode: false,
        ),
      );
      _bridge.patchSessionModes(
        runtimeSessionId,
        permissionMode: legacyMode.value,
        executionMode: derivedExecution.value,
        planMode: false,
        approvalPolicy: policy.value,
        approvalsReviewer: normalizedReviewer,
      );
    }
    _bridge.send(
      ClientMessage.setSessionMode(
        legacyMode: legacyMode.value,
        executionMode: derivedExecution.value,
        approvalPolicy: policy.value,
        approvalsReviewer: normalizedReviewer,
        planMode: false,
        sessionId: detachedTarget == null ? runtimeSessionId : null,
        detachedTarget: detachedTarget,
      ),
    );
  }

  void setCodexPermissionsMode(
    CodexPermissionsMode mode, {
    CodexPermissionApplyStrategy? applyStrategy,
  }) {
    final runtimeSessionId = _runtimeSessionIdForSettingsMutation();
    if (runtimeSessionId == null) return;
    if (!_allowCodexSettingsMutation()) return;
    if (detachedPreview &&
        applyStrategy == CodexPermissionApplyStrategy.restartNow) {
      logger.warning(
        '[session:$sessionId] ignored detached permission restart request',
      );
      return;
    }
    if (applyStrategy != null && _pendingPermissionChangeId != null) {
      logger.warning(
        '[session:$sessionId] Permission change already pending; ignoring duplicate request',
      );
      return;
    }
    final detachedTarget = _detachedSettingsMutationTarget(runtimeSessionId);
    if (detachedPreview && detachedTarget == null) return;
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
    _pendingCodexPermissionStateKnownRollback = state.codexPermissionStateKnown;
    _pendingSandboxRollback = state.sandboxMode;
    _pendingPlanRollback = state.planMode;
    final permissionChangeId = applyStrategy == null ? null : _uuid.v4();
    _pendingPermissionChangeId = permissionChangeId;
    if (applyStrategy == CodexPermissionApplyStrategy.restartNow) {
      _pendingPermissionRestartStatusRollback = state.status;
      _pendingPermissionRestartApprovalRollback = state.approval;
    }

    if (!detachedPreview) {
      emit(
        state.copyWith(
          permissionMode: legacyMode,
          executionMode: derivedExecution,
          codexPermissionStateKnown: true,
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
        runtimeSessionId,
        permissionMode: legacyMode.value,
        executionMode: derivedExecution.value,
        planMode: state.planMode,
        approvalPolicy: mode == CodexPermissionsMode.custom
            ? null
            : policy.value,
        approvalsReviewer: mode == CodexPermissionsMode.custom
            ? null
            : approvalsReviewer,
        codexPermissionsMode: mode.value,
      );
      if (sandboxMode != null) {
        _bridge.patchSessionSandboxMode(runtimeSessionId, sandboxMode.value);
      }
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
          sessionId: detachedTarget == null ? runtimeSessionId : null,
          detachedTarget: detachedTarget,
        ),
      );
    } catch (_) {
      _onMessage(
        ErrorMessage(
          message: 'Bridge is not connected; permission change was not sent.',
          errorCode: 'set_permission_mode_rejected',
          sessionId: runtimeSessionId,
          permissionChangeId: permissionChangeId,
        ),
      );
    }
  }

  void setCodexModel(String model, {ReasoningEffort? reasoningEffort}) {
    final runtimeSessionId = _runtimeSessionIdForSettingsMutation();
    if (runtimeSessionId == null) return;
    if (!isCodex) return;
    if (!_allowCodexSettingsMutation()) return;
    if (state.externalDesktopTurnActive &&
        !_canBuildDurableSettingsMutationTarget) {
      return;
    }
    final normalizedModel = sanitizeCodexModelName(model);
    if (normalizedModel == null) return;
    final nextReasoningEffort =
        reasoningEffort ?? state.codexModelReasoningEffort;
    if (normalizedModel == state.codexModel &&
        nextReasoningEffort == state.codexModelReasoningEffort) {
      return;
    }
    final detachedTarget = _detachedSettingsMutationTarget(runtimeSessionId);
    if (detachedPreview && detachedTarget == null) return;
    logger.info(
      '[session:$sessionId] setCodexModel=$normalizedModel '
      'reasoning=${nextReasoningEffort?.value}',
    );
    _pendingCodexModelMutation = true;
    _pendingCodexModelRollback = state.codexModel;
    _pendingCodexEffortRollback = state.codexModelReasoningEffort;
    if (!detachedPreview) {
      emit(
        state.copyWith(
          codexModel: normalizedModel,
          codexModelReasoningEffort: nextReasoningEffort,
        ),
      );
      _bridge.patchSessionCodexModel(
        runtimeSessionId,
        normalizedModel,
        modelReasoningEffort: nextReasoningEffort?.value,
      );
    }
    _bridge.send(
      ClientMessage.setCodexModel(
        normalizedModel,
        modelReasoningEffort: nextReasoningEffort?.value,
        sessionId: detachedTarget == null ? runtimeSessionId : null,
        detachedTarget: detachedTarget,
      ),
    );
  }

  void setCodexSpeed(CodexSpeed speed) {
    final runtimeSessionId = _runtimeSessionIdForSettingsMutation();
    if (runtimeSessionId == null) return;
    if (!_allowCodexSettingsMutation()) return;
    if (state.externalDesktopTurnActive &&
        !_canBuildDurableSettingsMutationTarget) {
      return;
    }
    if (!isCodex || speed == CodexSpeed.unknown || speed == state.codexSpeed) {
      return;
    }
    final detachedTarget = _detachedSettingsMutationTarget(runtimeSessionId);
    if (detachedPreview && detachedTarget == null) return;
    logger.info('[session:$sessionId] setCodexSpeed=${speed.value}');
    _pendingCodexSpeedMutation = true;
    _pendingCodexSpeedRollback = state.codexSpeed;
    _pendingCodexServiceTierRollback = codexServiceTierRaw.value;
    if (!detachedPreview) {
      _updateCodexServiceTierRaw(speed.value);
      emit(state.copyWith(codexSpeed: speed));
      _bridge.patchSessionCodexSpeed(runtimeSessionId, speed.value);
    }
    _bridge.send(
      ClientMessage.setCodexSpeed(
        speed.value,
        sessionId: detachedTarget == null ? runtimeSessionId : null,
        detachedTarget: detachedTarget,
      ),
    );
  }

  /// Change sandbox mode (Claude & Codex).
  /// Bridge destroys and resumes the session with new sandbox settings.
  void setSandboxMode(SandboxMode mode) {
    final runtimeSessionId = isCodex
        ? _runtimeSessionIdForSettingsMutation()
        : _runtimeSessionIdForMutation(allowSteerable: false);
    if (runtimeSessionId == null) return;
    if (isCodex && !_allowCodexSettingsMutation()) return;
    final detachedTarget = isCodex
        ? _detachedSettingsMutationTarget(runtimeSessionId)
        : null;
    if (detachedPreview && isCodex && detachedTarget == null) return;
    _pendingSandboxRollback = state.sandboxMode;
    if (!detachedPreview) {
      emit(state.copyWith(sandboxMode: mode));
      if (isCodex) {
        _bridge.patchSessionSandboxMode(runtimeSessionId, mode.value);
      }
    }
    _bridge.send(
      ClientMessage.setSandboxMode(
        mode.value,
        sessionId: detachedTarget == null ? runtimeSessionId : null,
        detachedTarget: detachedTarget,
      ),
    );
    // Persist per-session so that future resumes use this mode.
    final claudeSid = state.claudeSessionId;
    if (!detachedPreview && claudeSid != null && claudeSid.isNotEmpty) {
      _SessionSettingsHelper.save(claudeSid, {'sandboxMode': mode.value});
    }
  }

  void _rollbackFailedModeChange(ErrorMessage msg) {
    if (msg.errorCode == 'codex_settings_owned_elsewhere') {
      _rollbackCodexSettingsOwnedElsewhere();
    } else if (msg.errorCode == 'set_codex_model_rejected') {
      _rollbackPendingCodexRuntimeSettings(model: true);
    } else if (msg.errorCode == 'set_codex_speed_rejected') {
      _rollbackPendingCodexRuntimeSettings(speed: true);
    }
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
      final previousCodexPermissionStateKnown =
          _pendingCodexPermissionStateKnownRollback ??
          state.codexPermissionStateKnown;
      _pendingPermissionRollback = null;
      if (previous != null) {
        emit(
          state.copyWith(
            permissionMode: previous,
            executionMode: _pendingExecutionRollback ?? state.executionMode,
            codexPermissionStateKnown: previousCodexPermissionStateKnown,
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
        final restoreCanonicalCodexPermissions =
            isCodex && previousCodexPermissionStateKnown;
        final runtimeSessionId = runtimeSessionIdForRead;
        if (runtimeSessionId != null) {
          _bridge.patchSessionModes(
            runtimeSessionId,
            permissionMode: previous.value,
            executionMode:
                (_pendingExecutionRollback ?? state.executionMode).value,
            planMode: _pendingPlanRollback ?? (previous == PermissionMode.plan),
            approvalPolicy: restoreCanonicalCodexPermissions
                ? (_pendingCodexApprovalRollback ?? state.codexApprovalPolicy)
                      .value
                : null,
            approvalsReviewer: restoreCanonicalCodexPermissions
                ? (_pendingCodexApprovalsReviewerRollback ??
                      state.codexApprovalsReviewer)
                : null,
            codexPermissionsMode: restoreCanonicalCodexPermissions
                ? (_pendingCodexPermissionsModeRollback ??
                          state.codexPermissionsMode)
                      .value
                : null,
          );
        }
        final previousSandbox = _pendingSandboxRollback;
        if (isCodex && previousSandbox != null && runtimeSessionId != null) {
          _bridge.patchSessionSandboxMode(
            runtimeSessionId,
            previousSandbox.value,
          );
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
      _pendingCodexPermissionStateKnownRollback = null;
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
          final runtimeSessionId = runtimeSessionIdForRead;
          if (runtimeSessionId != null) {
            _bridge.patchSessionSandboxMode(runtimeSessionId, previous.value);
          }
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

  void _rollbackCodexSettingsOwnedElsewhere() {
    _rollbackPendingCodexRuntimeSettings(model: true, speed: true);
  }

  void _rollbackPendingCodexRuntimeSettings({
    bool model = false,
    bool speed = false,
  }) {
    final rollbackModel = model && _pendingCodexModelMutation;
    final rollbackSpeed = speed && _pendingCodexSpeedMutation;
    if (!rollbackModel && !rollbackSpeed) return;
    final previousModel = _pendingCodexModelRollback;
    final previousEffort = _pendingCodexEffortRollback;
    final previousSpeed = _pendingCodexSpeedRollback ?? state.codexSpeed;
    final previousTier = _pendingCodexServiceTierRollback;
    emit(
      state.copyWith(
        codexModel: rollbackModel ? previousModel : state.codexModel,
        codexModelReasoningEffort: rollbackModel
            ? previousEffort
            : state.codexModelReasoningEffort,
        codexSpeed: rollbackSpeed ? previousSpeed : state.codexSpeed,
      ),
    );
    final runtimeSessionId = runtimeSessionIdForRead;
    if (rollbackModel) {
      if (runtimeSessionId != null) {
        _bridge.restoreSessionCodexModel(
          runtimeSessionId,
          model: previousModel,
          modelReasoningEffort: previousEffort?.value,
        );
      }
      _clearPendingCodexModelRollback();
    }
    if (rollbackSpeed) {
      _updateCodexServiceTierRaw(previousTier);
      if (runtimeSessionId != null) {
        _bridge.restoreSessionCodexSpeed(runtimeSessionId, previousTier);
      }
      _clearPendingCodexSpeedRollback();
    }
  }

  void _clearPendingCodexModelRollback() {
    _pendingCodexModelMutation = false;
    _pendingCodexModelRollback = null;
    _pendingCodexEffortRollback = null;
  }

  void _clearPendingCodexSpeedRollback() {
    _pendingCodexSpeedMutation = false;
    _pendingCodexSpeedRollback = null;
    _pendingCodexServiceTierRollback = null;
  }

  bool _applyCodexModelAcknowledgement(SystemMessage message) {
    final model = sanitizeCodexModelName(message.model ?? '');
    if (model == null) return false;
    final effort =
        reasoningEffortByValue(message.modelReasoningEffort) ??
        state.codexModelReasoningEffort;
    if (state.codexModel != model ||
        state.codexModelReasoningEffort != effort) {
      emit(
        state.copyWith(codexModel: model, codexModelReasoningEffort: effort),
      );
    }
    final runtimeSessionId = runtimeSessionIdForRead;
    if (runtimeSessionId != null) {
      _bridge.patchSessionCodexModel(
        runtimeSessionId,
        model,
        modelReasoningEffort: effort?.value,
      );
    }
    logger.info(
      '[settings_projection] event=model_ack_applied '
      'thread=$_projectionThreadToken model=$model '
      'effort=${effort?.value ?? 'unknown'}',
    );
    return true;
  }

  bool _applyCodexSpeedAcknowledgement(SystemMessage message) {
    final serviceTier = message.serviceTier?.trim();
    final speed = codexRuntimeSpeedFromRaw(serviceTier);
    if (serviceTier == null || serviceTier.isEmpty || speed == null) {
      return false;
    }
    _updateCodexServiceTierRaw(serviceTier);
    if (state.codexSpeed != speed) {
      emit(state.copyWith(codexSpeed: speed));
    }
    final runtimeSessionId = runtimeSessionIdForRead;
    if (runtimeSessionId != null) {
      _bridge.patchSessionCodexSpeed(runtimeSessionId, serviceTier);
    }
    logger.info(
      '[settings_projection] event=speed_ack_applied '
      'thread=$_projectionThreadToken tier=$serviceTier',
    );
    return true;
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
    final runtimeSessionId = runtimeSessionIdForRead;
    if (runtimeSessionId != null) {
      _bridge.patchSessionModes(
        runtimeSessionId,
        permissionMode: rollbackPermissionMode.value,
        executionMode: state.executionMode.value,
        planMode: false,
        approvalPolicy: state.codexPermissionStateKnown
            ? state.codexApprovalPolicy.value
            : null,
        approvalsReviewer: state.codexPermissionStateKnown
            ? state.codexApprovalsReviewer
            : null,
        codexPermissionsMode: state.codexPermissionStateKnown
            ? state.codexPermissionsMode.value
            : null,
      );
    }
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
    _pendingCodexPermissionStateKnownRollback = null;
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
    if (message.permissionMode?.trim().isNotEmpty == true ||
        message.executionMode?.trim().isNotEmpty == true ||
        message.approvalPolicy?.trim().isNotEmpty == true ||
        message.approvalsReviewer?.trim().isNotEmpty == true ||
        message.codexPermissionsMode?.trim().isNotEmpty == true) {
      _pendingCodexPermissionStateKnownRollback = true;
    }
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

  bool _isSessionNotFound(ErrorMessage msg) {
    if (msg.errorCode == 'session_not_found') {
      return msg.sessionId != null && _matchesBoundSessionId(msg.sessionId);
    }
    // Compatibility with Bridges released before structured error codes.
    final runtimeSessionId = runtimeSessionIdForRead;
    return msg.message == 'Session $sessionId not found' ||
        (runtimeSessionId != null &&
            msg.message == 'Session $runtimeSessionId not found');
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
    if (stopActionDetachesDesktopTurn) {
      final runtimeSessionId = _detachedLiveRuntimeSessionId;
      final codexSourceId = _bridge.codexSourceId?.trim();
      final authorityGeneration = _detachedAuthorityGeneration?.trim();
      if (runtimeSessionId == null ||
          codexSourceId == null ||
          codexSourceId.isEmpty ||
          authorityGeneration == null ||
          authorityGeneration.isEmpty) {
        return;
      }
      _bridge.send(
        ClientMessage.detachCodexRuntime(
          sessionId: runtimeSessionId,
          codexSourceId: codexSourceId,
          threadId: sessionId,
          authorityGeneration: authorityGeneration,
        ),
      );
      return;
    }
    final runtimeSessionId = _runtimeSessionIdForMutation();
    if (runtimeSessionId == null) return;
    _bridge.stopSession(runtimeSessionId);
  }

  /// Request a dry-run preview of file rewind.
  void rewindDryRun(String targetUuid) {
    final runtimeSessionId = _runtimeSessionIdForMutation(
      allowSteerable: false,
    );
    if (runtimeSessionId == null) return;
    emit(state.copyWith(rewindPreview: null));
    _bridge.send(ClientMessage.rewindDryRun(runtimeSessionId, targetUuid));
  }

  /// Execute a rewind operation.
  /// [mode] is one of: "conversation", "code", "both".
  void rewind(String targetUuid, String mode) {
    final runtimeSessionId = _runtimeSessionIdForMutation(
      allowSteerable: false,
    );
    if (runtimeSessionId == null) return;
    _bridge.send(ClientMessage.rewind(runtimeSessionId, targetUuid, mode));
  }

  void forkSession(String targetUuid) {
    final runtimeSessionId = _runtimeSessionIdForMutation(
      allowSteerable: false,
    );
    if (runtimeSessionId == null) return;
    _bridge.send(ClientMessage.forkSession(runtimeSessionId, targetUuid));
  }

  /// Hides one warning text for the lifetime of this open session screen.
  /// Canonical history refreshes can replay transient Codex warnings, so keep
  /// a bounded fingerprint set and filter matching replays until the Cubit is
  /// disposed. A newly opened screen may show a newly relevant warning again.
  void dismissCodexWarning(ErrorMessage warning) {
    if (warning.errorCode != 'codex_warning') return;
    final key = _codexWarningKey(warning);
    if (!_dismissedCodexWarningKeys.add(key)) return;
    while (_dismissedCodexWarningKeys.length > _maxDismissedCodexWarnings) {
      _dismissedCodexWarningKeys.remove(_dismissedCodexWarningKeys.first);
    }
    final entries = state.entries
        .where((entry) => !_isDismissedCodexWarningEntry(entry))
        .toList(growable: false);
    if (entries.length != state.entries.length) {
      emit(state.copyWith(entries: entries));
    }
  }

  String _codexWarningKey(ErrorMessage warning) =>
      '${warning.errorCode}\u0000${warning.message}';

  bool _isDismissedCodexWarningEntry(ChatEntry entry) {
    return entry is ServerChatEntry &&
        entry.message is ErrorMessage &&
        _dismissedCodexWarningKeys.contains(
          _codexWarningKey(entry.message as ErrorMessage),
        );
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

  Future<List<UserChatEntry>> loadAllUserMessagesForNavigation() async {
    final detachedIndexLoader = _detachedUserMessageIndexLoader;
    if (detachedIndexLoader != null) {
      try {
        final index = await detachedIndexLoader();
        if (index != null) {
          _localHistoryUserIndexComplete = index.complete;
          _providerTurnOrderById.clear();
          final entries = <UserChatEntry>[];
          for (var order = 0; order < index.messages.length; order++) {
            final message = index.messages[order];
            final turnId = message.historyTurnId?.trim();
            if (turnId != null && turnId.isNotEmpty) {
              _providerTurnOrderById.putIfAbsent(turnId, () => order);
            }
            entries.add(_userEntryFromHistoryIndex(message));
          }
          return _mergeNavigationIndexWithLiveEntries(entries);
        }
      } catch (error, stackTrace) {
        logger.warning(
          '[session:$sessionId] Failed to load durable user-message index',
          error,
          stackTrace,
        );
      }
    }
    List<LocalSessionUserIndexEntry>? indexed;
    try {
      indexed = await _bridge.tryLoadLocalSessionUserIndex(
        runtimeSessionId: sessionId,
      );
    } catch (error, stackTrace) {
      logger.warning(
        '[session:$sessionId] Failed to load local user-message index',
        error,
        stackTrace,
      );
    }
    _localHistoryUserIndexComplete = indexed != null;
    if (indexed == null) return allUserMessages;
    _providerTurnOrderById.clear();
    final result = <UserChatEntry>[];
    for (final indexedEntry in indexed) {
      final entry = _userEntryFromHistoryIndex(indexedEntry.message);
      _localHistoryOrdinalByNavigationEntry[entry] = indexedEntry.ordinal;
      result.add(entry);
    }
    return _mergeNavigationIndexWithLiveEntries(result);
  }

  List<UserChatEntry> _mergeNavigationIndexWithLiveEntries(
    List<UserChatEntry> result,
  ) {
    for (final live in allUserMessages) {
      final index = result.indexWhere((entry) {
        return _entriesEquivalentForTurnBoundary(entry, live);
      });
      if (index == -1) {
        result.add(live);
      } else {
        final indexedEntry = result[index];
        final ordinal = _localHistoryOrdinalByNavigationEntry[indexedEntry];
        final merged =
            _mergeCanonicalMirrorEntry(indexedEntry, live) as UserChatEntry;
        if (ordinal != null) {
          _localHistoryOrdinalByNavigationEntry[merged] = ordinal;
        }
        result[index] = merged;
      }
    }
    return List.unmodifiable(result);
  }

  UserChatEntry _userEntryFromHistoryIndex(UserInputMessage message) {
    final messageTimestamp = serverMessageTimestamp(message);
    return UserChatEntry(
      message.text,
      sessionId: sessionId,
      clientMessageId: message.clientMessageId,
      providerItemId: message.providerItemId,
      historyTurnId: message.historyTurnId,
      imageUrls: message.imageUrls,
      imageCount: message.imageCount,
      status: MessageStatus.sent,
      messageUuid: message.userMessageUuid,
      timestamp:
          messageTimestamp?.value.toLocal() ??
          (message.timestamp == null
              ? null
              : DateTime.tryParse(message.timestamp!)?.toLocal()),
      timestampIsAuthoritative: messageTimestamp?.isAuthoritative ?? false,
    );
  }

  Future<UserChatEntry?> revealUserMessage(UserChatEntry target) async {
    UserChatEntry? findLoaded() {
      for (final entry in state.entries.whereType<UserChatEntry>()) {
        if (_entriesEquivalentForTurnBoundary(entry, target)) return entry;
      }
      return null;
    }

    var loaded = findLoaded();
    if (loaded != null) return loaded;
    final providerTurnId = target.historyTurnId?.trim();
    final detachedTurnLoader = _detachedUserTurnLoader;
    if (providerTurnId != null &&
        providerTurnId.isNotEmpty &&
        detachedTurnLoader != null) {
      try {
        final messages = await detachedTurnLoader(providerTurnId);
        if (messages != null && messages.isNotEmpty && !isClosed) {
          _mergeLoadedProviderTurn(providerTurnId, messages);
          loaded = findLoaded();
          if (loaded != null) return loaded;
        }
      } catch (error, stackTrace) {
        logger.warning(
          '[session:$sessionId] Failed to load provider turn window',
          error,
          stackTrace,
        );
      }
    }
    final currentPaging = localHistoryPaging.value;
    if (isClosed || !currentPaging.enabled || currentPaging.loading) {
      return null;
    }

    final targetOrdinal = _localHistoryOrdinalByNavigationEntry[target];
    final canLoadTargetWindow =
        targetOrdinal != null && _bridge.hasSessionHistoryWindowLoading;
    if (!canLoadTargetWindow && !currentPaging.hasMore) return null;

    final generation = _localHistoryPagingGeneration;
    localHistoryPaging.value = currentPaging.copyWith(
      loading: true,
      clearError: true,
    );
    if (canLoadTargetWindow) {
      // Let the modal loading barrier paint before the database read starts.
      await Future<void>.delayed(Duration.zero);
      try {
        final page = await _bridge.tryLoadLocalSessionHistoryWindow(
          runtimeSessionId: sessionId,
          startOrdinal: targetOrdinal,
        );
        if (isClosed || generation != _localHistoryPagingGeneration) {
          return null;
        }
        if (page == null) {
          localHistoryPaging.value = _currentLocalHistoryPagingState();
          return null;
        }
        _replaceLocalMirrorWindow(page);
        loaded = findLoaded();
        localHistoryPaging.value = LocalHistoryPagingState(
          enabled: true,
          hasMore: page.hasMore,
        );
        return loaded;
      } catch (error, stackTrace) {
        if (isClosed || generation != _localHistoryPagingGeneration) {
          return null;
        }
        logger.warning(
          '[session:$sessionId] Failed to load target history window',
          error,
          stackTrace,
        );
        localHistoryPaging.value = localHistoryPaging.value.copyWith(
          loading: false,
          error: error,
        );
        return null;
      }
    }

    // Compatibility fallback for a paging provider without random-access
    // windows: buffer sequential pages and publish only once the target page
    // is available, avoiding a full conversation rebuild after every page.
    final pages = <LocalSessionHistoryPage>[];
    var pagesPublished = false;
    void publishBufferedPages() {
      if (pagesPublished || pages.isEmpty) return;
      final bufferedMessages = <ServerMessage>[
        for (final page in pages.reversed) ...page.messages,
      ];
      final history = HistoryMessage(messages: bufferedMessages);
      final decoded = _handler.handle(
        history,
        isBackground: true,
        isCodex: isCodex,
        ignoredToolUseIds: _respondedToolUseIds,
        historyTimestampAnchor: pages.last.timestampAnchor,
      );
      _applyUpdate(
        ChatStateUpdate(
          entriesToPrepend: decoded.entriesToAdd,
          toolUseIdsToHide: decoded.toolUseIdsToHide,
          localHistoryPage: true,
        ),
        history,
      );
      pagesPublished = true;
    }

    var remainingPages = 500;
    var hasMore = currentPaging.hasMore;
    try {
      var targetBuffered = false;
      while (!targetBuffered && hasMore && remainingPages-- > 0) {
        final page = await _bridge.tryLoadOlderLocalSessionHistory(
          runtimeSessionId: sessionId,
        );
        if (isClosed || generation != _localHistoryPagingGeneration) {
          return null;
        }
        if (page == null) break;
        pages.add(page);
        hasMore = page.hasMore;
        targetBuffered = page.messages.whereType<UserInputMessage>().any(
          (message) => _entriesEquivalentForTurnBoundary(
            _userEntryFromHistoryIndex(message),
            target,
          ),
        );
        // Give the loading overlay a frame between database pages.
        await Future<void>.delayed(Duration.zero);
      }

      publishBufferedPages();
      loaded = findLoaded();
      localHistoryPaging.value = LocalHistoryPagingState(
        enabled: true,
        hasMore: hasMore,
      );
    } catch (error, stackTrace) {
      if (isClosed || generation != _localHistoryPagingGeneration) {
        return null;
      }
      try {
        publishBufferedPages();
        loaded = findLoaded();
      } catch (_) {
        // Preserve the original read/decode error below.
      }
      logger.warning(
        '[session:$sessionId] Failed to preload history target',
        error,
        stackTrace,
      );
      localHistoryPaging.value = localHistoryPaging.value.copyWith(
        loading: false,
        error: error,
      );
    }
    return loaded;
  }

  void _mergeLoadedProviderTurn(
    String providerTurnId,
    List<ServerMessage> messages,
  ) {
    final decoded = _handler.handle(
      HistoryMessage(messages: messages),
      isBackground: true,
      isCodex: isCodex,
      ignoredToolUseIds: _respondedToolUseIds,
    );
    final incoming = decoded.entriesToAdd
        .where((entry) => entry is! StreamingChatEntry)
        .toList(growable: false);
    if (incoming.isEmpty) return;
    for (final entry in incoming) {
      _targetHistoryTurnByEntry[entry] = providerTurnId;
    }

    final retained = <({ChatEntry entry, String? turnId})>[];
    String? currentTurnId;
    for (final entry in state.entries) {
      final explicit = _explicitHistoryTurnId(entry);
      if (entry is UserChatEntry) {
        // A new unresolved optimistic user entry is a new turn boundary and
        // must never inherit the previous provider turn.
        currentTurnId = explicit;
      } else if (explicit != null) {
        currentTurnId = explicit;
      }
      if (currentTurnId == providerTurnId) continue;
      retained.add((entry: entry, turnId: currentTurnId));
    }

    final targetOrder = _providerTurnOrderById[providerTurnId];
    var insertionIndex = _pastEntryCount.clamp(0, retained.length);
    if (targetOrder == null) {
      insertionIndex = retained.length;
    } else {
      for (var index = 0; index < retained.length; index++) {
        final turnId = retained[index].turnId;
        final order = turnId == null ? null : _providerTurnOrderById[turnId];
        if (order == null) continue;
        if (order > targetOrder) break;
        insertionIndex = index + 1;
      }
    }
    final nextEntries = <ChatEntry>[
      for (var index = 0; index < insertionIndex; index++)
        retained[index].entry,
      ...incoming,
      for (var index = insertionIndex; index < retained.length; index++)
        retained[index].entry,
    ];
    emit(
      state.copyWith(
        entries: nextEntries,
        hiddenToolUseIds: {
          ...state.hiddenToolUseIds,
          ...decoded.toolUseIdsToHide,
        },
      ),
    );
  }

  String? _explicitHistoryTurnId(ChatEntry entry) {
    final indexed = _targetHistoryTurnByEntry[entry];
    if (indexed != null && indexed.isNotEmpty) return indexed;
    if (entry is UserChatEntry) {
      final value = entry.historyTurnId?.trim();
      return value == null || value.isEmpty ? null : value;
    }
    if (entry case ServerChatEntry(:final message)) {
      final value = switch (message) {
        AssistantServerMessage(:final historyTurnId) => historyTurnId,
        ToolResultMessage(:final historyTurnId) => historyTurnId,
        UserInputMessage(:final historyTurnId) => historyTurnId,
        _ => null,
      }?.trim();
      return value == null || value.isEmpty ? null : value;
    }
    return null;
  }

  void _replaceLocalMirrorWindow(LocalSessionHistoryPage page) {
    if (page.messages.isEmpty) return;
    final history = HistoryMessage(messages: page.messages);
    final decoded = _handler.handle(
      history,
      isBackground: true,
      isCodex: isCodex,
      ignoredToolUseIds: _respondedToolUseIds,
      historyTimestampAnchor: page.timestampAnchor,
    );
    final mirrorEntries = decoded.entriesToAdd
        .where((entry) => entry is! StreamingChatEntry)
        .toList(growable: false);
    if (mirrorEntries.isEmpty) return;

    final pastEntries = state.entries
        .take(_pastEntryCount)
        .toList(growable: false);
    final allExistingNonPast = state.entries
        .skip(_pastEntryCount)
        .toList(growable: false);
    final existingMirrorPrefix = _localMirrorEntryCount.clamp(
      0,
      allExistingNonPast.length,
    );
    final canonicalTail = allExistingNonPast
        .skip(existingMirrorPrefix)
        .toList(growable: false);
    final merged = _mergeCanonicalHistoryIntoPagedEntries(
      existingEntries: mirrorEntries,
      canonicalEntries: canonicalTail,
    );
    _localMirrorEntryCount = _mirrorPrefixExtent(
      mergedEntries: merged,
      mirrorEntries: mirrorEntries,
    );
    var nextEntries = <ChatEntry>[...pastEntries, ...merged];
    if (_dismissedCodexWarningKeys.isNotEmpty) {
      nextEntries = nextEntries
          .where((entry) => !_isDismissedCodexWarningEntry(entry))
          .toList(growable: false);
    }
    emit(
      state.copyWith(
        entries: nextEntries,
        hiddenToolUseIds: {
          ...state.hiddenToolUseIds,
          ...decoded.toolUseIdsToHide,
        },
      ),
    );
  }

  /// Re-fetch session history from the bridge server.
  ///
  /// Resets [_pastHistoryLoaded] so the next [PastHistoryMessage] is processed,
  /// restoring approval state that may have arrived while disconnected.
  void refreshHistory() {
    if (detachedPreview) return;
    _pastHistoryLoaded = false;
    _pastEntryCount = 0;
    _disableLocalHistoryPaging(
      expectCanonicalHistory: !_bridge.hasSessionHistoryBootstrap,
    );
    if (!_bridge.hasSessionHistoryBootstrap) {
      _bridge.requestSessionHistory(sessionId);
      return;
    }
    unawaited(_refreshMirroredHistory());
  }

  Future<void> _refreshMirroredHistory() async {
    final pagingGeneration = ++_localHistoryPagingGeneration;
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
    if (isClosed || pagingGeneration != _localHistoryPagingGeneration) return;
    if (!handled) {
      _discardLocalMirrorOnNextCanonicalHistory = _localMirrorEntryCount > 0;
      localHistoryPaging.value = const LocalHistoryPagingState();
      _historyFallbackRequested = true;
      _bridge.requestSessionHistory(sessionId);
      return;
    }
    _discardLocalMirrorOnNextCanonicalHistory = false;
    _historyFallbackRequested = false;
    localHistoryPaging.value = _currentLocalHistoryPagingState();
  }

  /// Retry a failed user message.
  /// Retries [entry] when the current runtime mutation lease is authoritative.
  ///
  /// Returns false without changing the visible message when a detached
  /// conversation is still waiting for its runtime authority projection. This
  /// lets the UI explain the real retry gate instead of making a tap appear to
  /// do nothing.
  bool retryMessage(UserChatEntry entry) {
    final runtimeLease = _captureRuntimeMutationLease();
    if (runtimeLease == null) return false;
    final clientMessageId = _uuid.v4();
    final retrySessionId = runtimeLease.sessionId;
    final isOffline = !_bridge.isConnected;
    final baseSeq = isOffline
        ? _bridge.cachedSessionHistorySeq(retrySessionId)
        : null;
    final deliveryPendingItem = isCodex && !isOffline
        ? QueuedInputItem(
            itemId: '$deliveryPendingQueuedInputPrefix$clientMessageId',
            text: entry.text,
            createdAt: DateTime.now().toUtc().toIso8601String(),
            clientMessageId: clientMessageId,
            imageCount: entry.imageCount,
          )
        : null;
    emit(
      state.copyWith(
        entries: state.entries.map((e) {
          if (identical(e, entry)) {
            return UserChatEntry(
              entry.text,
              sessionId: retrySessionId,
              clientMessageId: clientMessageId,
              providerItemId: entry.providerItemId,
              historyTurnId: entry.historyTurnId,
              imageBytesList: entry.imageBytesList,
              imageUrls: entry.imageUrls,
              imageCount: entry.imageCount,
              status: isOffline ? MessageStatus.queued : MessageStatus.sending,
              messageUuid: entry.messageUuid,
              timestamp: entry.timestamp,
              timestampIsAuthoritative: entry.timestampIsAuthoritative,
            );
          }
          return e;
        }).toList(),
      ),
    );
    // Use the same ordered preparation, runtime-generation fence, pending
    // delivery correlation, and failure transition as a normal submission.
    // The old direct send could leave this bubble spinning forever when the
    // socket queued the frame or the runtime changed during dispatch.
    _dispatchInputInOrder(
      runtimeLease: runtimeLease,
      text: entry.text,
      clientMessageId: clientMessageId,
      baseSeq: baseSeq,
      images: const [],
      skills: const [],
      mentions: const [],
      deliveryPendingItem: deliveryPendingItem,
    );
    return true;
  }

  ({List<Map<String, String>> skills, List<Map<String, String>> mentions})
  _extractCodexStructuredInputs(
    String text, {
    Iterable<String>? mentionablePaths,
    Iterable<Map<String, String>>? additionalMentions,
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
    for (final additional
        in additionalMentions ?? const <Map<String, String>>[]) {
      final name = additional['name']?.trim() ?? '';
      final mentionPath = additional['path']?.trim() ?? '';
      if (name.isEmpty || mentionPath.isEmpty) continue;
      final key = '$name|$mentionPath';
      if (seenMentions.add(key)) {
        mentions.add({'name': name, 'path': mentionPath});
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
    _unwatchDesktopContinuity();
    _statusRefreshTimer?.cancel();
    _goalMutationTimer?.cancel();
    _goalReadTimer?.cancel();
    _desktopContinuityReconcileTimer?.cancel();
    _goalConnectionSubscription?.cancel();
    _goalSessionListSubscription?.cancel();
    _runtimeSnapshotSubscription?.cancel();
    _codexModelCatalogSubscription?.cancel();
    _localHistoryAvailabilitySubscription?.cancel();
    _historySyncSubscription?.cancel();
    _statusRefreshConnectionSubscription?.cancel();
    codexModelCatalogRevision.dispose();
    codexServiceTierRaw.dispose();
    queuedInputs.dispose();
    externalDesktopTurnSteerable.dispose();
    detachedLiveRuntimeRevision.dispose();
    _desktopContinuitySubscription?.cancel();
    _desktopContinuityConnectionSubscription?.cancel();
    _deliveryPendingInputs.clear();
    _detachedSettingsSubscription?.cancel();
    _subscription?.cancel();
    _sideEffectsController.close();
    _bridge.invalidateLocalSessionHistoryPaging(sessionId);
    localHistoryIndexRevision.dispose();
    historyToolDetailRevision.dispose();
    _historyToolDetailStates.clear();
    _historyToolDetailFlights.clear();
    localHistoryPaging.dispose();
    historySyncing.dispose();
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
