import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart'
    show VoidCallback, protected, visibleForTesting;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/logger.dart';
import '../models/messages.dart';
import '../models/offline_pending_action.dart';
import '../utils/codex_plan_update.dart';
import '../utils/history_window_policy.dart';
import '../utils/network_endpoint.dart';
import 'bridge_service_base.dart';
import 'codex_goal_request_router.dart';
import 'desktop_continuity_backlog.dart';
import 'session_runtime_store.dart';

/// A mobile-owned hook that may observe one live session permission request
/// before it reaches ordinary chat UI subscribers.
///
/// Observers cannot suppress ordinary delivery. A failed observer is isolated,
/// and with no registered observer the official path is unchanged.
typedef SessionPermissionRequestObserver =
    void Function(String sessionId, PermissionRequestMessage request);

const backgroundNotificationDeliveryBridgeCapability =
    'background_notification_delivery_v1';
const pushRegistrationStatusBridgeCapability = 'push_registration_status_v1';

@visibleForTesting
Map<String, String> bridgePrivateHttpHeaders(String? websocketUrl) {
  final uri = websocketUrl == null ? null : Uri.tryParse(websocketUrl);
  final apiKey = uri?.queryParameters['token'];
  if (apiKey == null || apiKey.isEmpty) return const {};
  return {'Authorization': 'Bearer $apiKey'};
}

class _PermissionRequestObserverRegistration {
  const _PermissionRequestObserverRegistration(this.observer);

  final SessionPermissionRequestObserver observer;
}

typedef SessionHistoryBootstrapHandler =
    Future<bool> Function({
      required String runtimeSessionId,
      required String? provider,
      required String? providerSessionId,
      required String? projectPath,
      required bool force,
    });

class LocalSessionHistoryPage {
  const LocalSessionHistoryPage({
    required this.messages,
    required this.hasMore,
    this.timestampAnchor,
  });

  final List<ServerMessage> messages;
  final bool hasMore;
  final DateTime? timestampAnchor;
}

class LocalSessionUserIndexEntry {
  const LocalSessionUserIndexEntry({
    required this.message,
    required this.ordinal,
  });

  final UserInputMessage message;
  final int ordinal;
}

typedef SessionHistoryPageLoader =
    Future<LocalSessionHistoryPage?> Function({
      required String runtimeSessionId,
      required int limit,
    });

typedef SessionHistoryWindowLoader =
    Future<LocalSessionHistoryPage?> Function({
      required String runtimeSessionId,
      required int startOrdinal,
      required int limit,
    });

typedef SessionHistoryHasMore = bool Function(String runtimeSessionId);
typedef SessionHistoryAvailable = bool Function(String runtimeSessionId);
typedef SessionHistoryPageInvalidator = void Function(String runtimeSessionId);

typedef SessionHistoryUserIndexLoader =
    Future<List<LocalSessionUserIndexEntry>?> Function({
      required String runtimeSessionId,
    });

typedef SessionHistoryToolDetailLoader =
    Future<List<HistoryToolDetail>?> Function({
      required String runtimeSessionId,
      required List<String> toolUseIds,
    });

class _ExternalSessionHistoryMetadata {
  const _ExternalSessionHistoryMetadata({this.timestampAnchor});

  final DateTime? timestampAnchor;
}

class LocalSessionHistoryAvailabilityChange {
  const LocalSessionHistoryAvailabilityChange({
    required this.runtimeSessionId,
    required this.available,
  });

  final String runtimeSessionId;
  final bool available;
}

class _RemoteHistoryCursor {
  _RemoteHistoryCursor({
    required this.beforeSeq,
    required this.hasMore,
    this.beforeCursor,
  });

  int beforeSeq;
  bool hasMore;
  String? beforeCursor;
}

enum SessionLinkResolveSupport { resolved, unsupported, unavailable }

class SessionLinkResolveResult {
  final SessionLinkResolveSupport support;
  final SessionLinkResolutionMessage? resolution;

  const SessionLinkResolveResult._(this.support, this.resolution);

  const SessionLinkResolveResult.resolved(
    SessionLinkResolutionMessage resolution,
  ) : this._(SessionLinkResolveSupport.resolved, resolution);

  const SessionLinkResolveResult.unsupported()
    : this._(SessionLinkResolveSupport.unsupported, null);

  const SessionLinkResolveResult.unavailable()
    : this._(SessionLinkResolveSupport.unavailable, null);
}

class BridgeService implements BridgeServiceBase {
  void Function(ClientMessage message)? onOutgoingMessage;
  FutureOr<void> Function()? onDisconnect;

  WebSocketChannel? _channel;
  StreamSubscription? _channelSub;
  final _messageController = StreamController<ServerMessage>.broadcast();
  final _taggedMessageController =
      StreamController<(ServerMessage, String?)>.broadcast();
  final _localFeatureMessageController =
      StreamController<(LocalFeatureServerMessage, String?)>.broadcast();
  final _connectionController =
      StreamController<BridgeConnectionState>.broadcast();
  final _clientDeliveryModeStateController =
      StreamController<ClientDeliveryModeStateMessage>.broadcast();
  final _backgroundNotificationController =
      StreamController<BackgroundNotificationMessage>.broadcast();
  final _backgroundActivityStateController =
      StreamController<BackgroundActivityStateMessage>.broadcast();
  final _pushRegistrationStateController =
      StreamController<PushRegistrationStateMessage>.broadcast();
  final _sessionListController =
      StreamController<List<SessionInfo>>.broadcast();
  final _sessionHistoryAvailabilityController =
      StreamController<LocalSessionHistoryAvailabilityChange>.broadcast();
  final _sessionHistoryReconciledController =
      StreamController<String>.broadcast();
  final Map<String, int> _sessionHistoryReconciliationGenerations = {};
  int _sessionHistoryReconciliationSequence = 0;
  final _sessionHistorySyncChangedController =
      StreamController<String>.broadcast();
  final Set<String> _activeSessionHistorySyncs = {};
  final Set<String> _pendingForegroundHistorySyncs = {};
  final Map<String, Timer> _sessionHistorySyncTimeouts = {};
  final _codexModelCatalogController = StreamController<int>.broadcast();
  final _sessionStoppedController = StreamController<String>.broadcast();
  final _recentSessionsController =
      StreamController<List<RecentSession>>.broadcast();
  final _recentSessionResponsesController =
      StreamController<RecentSessionsMessage>.broadcast();
  final _galleryController = StreamController<List<GalleryImage>>.broadcast();
  final _fileListController = StreamController<List<String>>.broadcast();
  final _fileListMessageController =
      StreamController<FileListMessage>.broadcast();
  final _projectHistoryController = StreamController<List<String>>.broadcast();
  final _codexAutoReviewPolicyController = StreamController<bool>.broadcast();
  final _diffResultController = StreamController<DiffResultMessage>.broadcast();
  final _diffImageResultController =
      StreamController<DiffImageResultMessage>.broadcast();
  final _worktreeListController =
      StreamController<WorktreeListMessage>.broadcast();
  final _windowListController = StreamController<List<WindowInfo>>.broadcast();
  final _screenshotResultController =
      StreamController<ScreenshotResultMessage>.broadcast();
  final _offlinePendingActionsController =
      StreamController<List<OfflinePendingAction>>.broadcast();
  final _debugBundleController =
      StreamController<DebugBundleMessage>.broadcast();
  final _usageController = StreamController<UsageResultMessage>.broadcast();
  final _recordingListController =
      StreamController<RecordingListMessage>.broadcast();
  final _recordingContentController =
      StreamController<RecordingContentMessage>.broadcast();
  final _backupResultController =
      StreamController<PromptHistoryBackupResultMessage>.broadcast();
  final _restoreResultController =
      StreamController<PromptHistoryRestoreResultMessage>.broadcast();
  final _backupInfoController =
      StreamController<PromptHistoryBackupInfoMessage>.broadcast();
  final _promptHistorySyncController =
      StreamController<PromptHistorySyncResultMessage>.broadcast();
  final _promptHistoryMutationController =
      StreamController<PromptHistoryMutationResultMessage>.broadcast();
  final _promptHistoryStatusController =
      StreamController<PromptHistoryStatusMessage>.broadcast();
  final _fileContentController =
      StreamController<FileContentMessage>.broadcast();
  // ---- Git Operations (Phase 1-3) ----
  final _gitStageResultController =
      StreamController<GitStageResultMessage>.broadcast();
  final _gitUnstageResultController =
      StreamController<GitUnstageResultMessage>.broadcast();
  final _gitUnstageHunksResultController =
      StreamController<GitUnstageHunksResultMessage>.broadcast();
  final _gitCommitResultController =
      StreamController<GitCommitResultMessage>.broadcast();
  final _gitPushResultController =
      StreamController<GitPushResultMessage>.broadcast();
  final _gitBranchesResultController =
      StreamController<GitBranchesResultMessage>.broadcast();
  final _gitCreateBranchResultController =
      StreamController<GitCreateBranchResultMessage>.broadcast();
  final _gitCheckoutBranchResultController =
      StreamController<GitCheckoutBranchResultMessage>.broadcast();
  final _gitRevertFileResultController =
      StreamController<GitRevertFileResultMessage>.broadcast();
  final _gitRevertHunksResultController =
      StreamController<GitRevertHunksResultMessage>.broadcast();
  final _gitFetchResultController =
      StreamController<GitFetchResultMessage>.broadcast();
  final _gitPullResultController =
      StreamController<GitPullResultMessage>.broadcast();
  final _gitStatusResultController =
      StreamController<GitStatusResultMessage>.broadcast();
  final _gitRemoteStatusResultController =
      StreamController<GitRemoteStatusResultMessage>.broadcast();
  BridgeConnectionState _connectionState = BridgeConnectionState.disconnected;
  final List<ClientMessage> _messageQueue = [];
  List<SessionInfo> _sessions = [];
  int _authoritativeSessionListGeneration = 0;
  bool _hasAuthoritativeSessionListForCurrentConnection = false;
  List<RecentSession> _recentSessions = [];
  RecentSessionsMessage? _lastRecentSessionsMessage;
  String? _bridgeInstanceId;
  List<GalleryImage> _galleryImages = [];
  List<String> _projectHistory = [];
  List<String> _allowedDirs = [];
  List<String> _claudeModels = [];
  Map<String, List<String>> _claudeModelEfforts = {};
  List<String> _codexModels = [];
  Map<String, List<String>> _codexModelReasoningEfforts = {};
  Map<String, List<String>> _codexModelServiceTiers = {};
  int _codexModelCatalogRevision = 0;
  List<String> _codexProfiles = [];
  String? _defaultCodexProfile;
  bool _codexAutoReviewDisabled = false;
  String? _bridgeVersion;
  Set<String> _bridgeCapabilities = const {};
  BridgeClientDeliveryMode _desiredClientDeliveryMode =
      BridgeClientDeliveryMode.interactive;
  String _deliveryLocale = 'en';
  bool _deliveryPrivacyMode = false;
  List<String> _deliveryEnabledEventTypes = const [];
  int _deliveryModeRequestSequence = 0;
  int _pushRegistrationRequestSequence = 0;
  String? _latestDeliveryModeRequestId;
  final Map<String, Completer<ClientDeliveryModeStateMessage>>
      _pendingDeliveryModeRequests = {};
  final Map<String, _PendingPermissionChange> _pendingPermissionChanges = {};
  final CodexGoalRequestRouter _goalRequestRouter = CodexGoalRequestRouter();
  final Duration permissionChangeTimeout;
  final bool fileTransferClientSupported;
  final String? clientAppVersion;
  final Map<String, dynamic>? clientMobileRuntime;
  String? _promptHistoryBridgeId;
  UsageResultMessage? _lastUsageResult;
  final SessionRuntimeStore _runtimeStore = SessionRuntimeStore();
  final DesktopContinuityBacklog _desktopContinuityBacklog =
      DesktopContinuityBacklog();
  final Map<String, ({String provider, String providerSessionId})>
  _providerSessionBindingByRuntime = {};
  SessionHistoryBootstrapHandler? _sessionHistoryBootstrapHandler;
  SessionHistoryPageLoader? _sessionHistoryPageLoader;
  SessionHistoryWindowLoader? _sessionHistoryWindowLoader;
  SessionHistoryHasMore? _sessionHistoryHasMore;
  SessionHistoryAvailable? _sessionHistoryAvailable;
  SessionHistoryPageInvalidator? _sessionHistoryPageInvalidator;
  SessionHistoryUserIndexLoader? _sessionHistoryUserIndexLoader;
  SessionHistoryToolDetailLoader? _sessionHistoryToolDetailLoader;
  final Expando<_ExternalSessionHistoryMetadata> _externalSessionHistories =
      Expando<_ExternalSessionHistoryMetadata>('externalSessionHistory');
  final Map<String, int> _pendingHistoryDeltaSinceSeq = {};
  final Map<String, bool> _pendingHistoryDeltaAllowsFullFallback = {};

  /// Per-session generation of history sync requests (full or delta). A
  /// legacy `history` frame is only applied when it answers the latest
  /// generation — see [_acceptLegacyHistoryFrame].
  final Map<String, int> _historySyncGenerations = {};

  /// FIFO fences for outstanding legacy `get_history` requests. Responses on
  /// a WebSocket arrive in request order, so each incoming `history` frame
  /// pops the oldest fence.
  final Map<String, List<_LegacyHistoryFence>> _pendingLegacyHistoryFences =
      {};
  final Map<String, _RemoteHistoryCursor> _remoteHistoryCursors = {};
  final Map<String, Completer<HistoryPageMessage>>
      _pendingRemoteHistoryPages = {};
  final Map<String, Future<LocalSessionHistoryPage?>>
      _remoteHistoryPageFlights = {};
  int _nextRemoteHistoryPageRequestId = 0;
  final Map<String, Completer<HistoryToolDetailsMessage>>
      _pendingHistoryToolDetails = {};
  int _nextHistoryToolDetailRequestId = 0;
  final Map<String, ClientMessage> _inFlightPendingMessages = {};
  final Map<String, ClientMessage> _inFlightInputMessages = {};
  final Map<String, Timer> _inFlightPendingVisibilityTimers = {};
  final Set<String> _visibleInFlightPendingKeys = {};
  final Map<String, _DeliveryPendingInputState> _deliveryPendingInputs = {};
  final Map<String, Timer> _deliveryPendingVisibilityTimers = {};
  final Map<String, Completer<SessionLinkResolveResult>>
  _pendingSessionLinkResolutions = {};
  int _nextSessionLinkRequestId = 0;
  final Map<String, Set<String>> _respondedToolUseIds = {};
  final Map<String, Completer<ArtifactResolvedMessage>>
      _pendingArtifactResolutions = {};
  final Random _artifactRequestRandom = Random.secure();
  final List<_PendingLocalFeatureRequest> _pendingLocalFeatureRequests = [];
  final List<_PermissionRequestObserverRegistration>
  _permissionRequestObservers = [];
  List<LocalFeatureProtocolSlot>? _localFeatureProtocolSlotsForTest;
  DateTime Function() _localFeatureRequestClock = DateTime.now;
  Future<void> _fileReadSerial = Future<void>.value();
  _PendingFileRead? _pendingFileRead;
  List<OfflinePendingAction> _offlinePendingActions = const [];

  // Diff image cache: survives screen navigation, cleared on session stop.
  // Key: "$projectPath\n$filePath"
  final _diffImageCache = <String, DiffImageCacheEntry>{};

  // Pagination & filter state
  bool _recentSessionsHasMore = false;
  bool _appendMode = false;
  String? _currentProjectFilter;
  String? _currentProvider;
  bool? _currentNamedOnly;
  String? _currentSearchQuery;
  Timer? _sessionCatalogRefreshTimer;
  Timer? _sessionCatalogRefreshTimeout;
  bool _sessionCatalogRefreshInFlight = false;
  bool _sessionCatalogRefreshDirty = false;
  int _lastSessionCatalogRevision = 0;
  int _recentSessionsQueryGeneration = 0;
  int _recentSessionsRequestSequence = 0;
  final Map<String, String> _latestRecentSessionRequestByScope = {};
  _RecentSessionsRequest? _legacyRecentSessionsRequestInFlight;
  final List<_RecentSessionsRequest> _legacyRecentSessionsRequestQueue = [];
  static const _maxLegacyRecentSessionsRequestQueue = 32;
  static const _sessionCatalogRefreshDebounce = Duration(milliseconds: 250);
  static const _sessionCatalogRefreshRequestTimeout = Duration(seconds: 15);
  static const _sessionCatalogRefreshMinLimit = 20;
  static const _sessionCatalogRefreshMaxLimit = 200;
  static const _sessionCatalogCacheWarmLimit = 1000;
  static const _sessionHistorySyncTimeout = Duration(seconds: 20);

  // Auto-reconnect
  String? _lastUrl;
  String? _logicalConnectionIdentity;
  int _connectionEpoch = 0;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  static const _maxReconnectDelay = 30;
  bool _intentionalDisconnect = false;

  @override
  Stream<ServerMessage> get messages => _messageController.stream;
  @override
  Stream<BridgeConnectionState> get connectionStatus =>
      _connectionController.stream;
  @override
  Stream<List<SessionInfo>> get sessionList => _sessionListController.stream;
  Stream<LocalSessionHistoryAvailabilityChange>
  get sessionHistoryAvailabilityChanges =>
      _sessionHistoryAvailabilityController.stream;
  Stream<String> get sessionHistoryReconciliations =>
      _sessionHistoryReconciledController.stream;
  int sessionHistoryReconciliationGeneration(String sessionId) =>
      _sessionHistoryReconciliationGenerations[sessionId] ?? 0;
  Stream<String> get sessionHistorySyncChanges =>
      _sessionHistorySyncChangedController.stream;
  bool isSessionHistorySyncing(String sessionId) =>
      _activeSessionHistorySyncs.contains(sessionId);
  Stream<int> get codexModelCatalogChanges =>
      _codexModelCatalogController.stream;
  int get authoritativeSessionListGeneration =>
      _authoritativeSessionListGeneration;
  bool get hasAuthoritativeSessionListForCurrentConnection =>
      isConnected && _hasAuthoritativeSessionListForCurrentConnection;
  bool get hasAuthoritativeRecentSessionsForCurrentConnection =>
      isConnected && _lastRecentSessionsMessage != null;
  @override
  Stream<String> get stoppedSessions => _sessionStoppedController.stream;
  Stream<List<RecentSession>> get recentSessionsStream =>
      _recentSessionsController.stream;
  Stream<RecentSessionsMessage> get recentSessionResponses =>
      _recentSessionResponsesController.stream;
  Stream<List<GalleryImage>> get galleryStream => _galleryController.stream;
  Stream<List<String>> get projectHistoryStream =>
      _projectHistoryController.stream;
  Stream<bool> get codexAutoReviewPolicyStream =>
      _codexAutoReviewPolicyController.stream;
  @override
  Stream<List<String>> get fileList => _fileListController.stream;
  Stream<FileListMessage> get fileListMessages =>
      _fileListMessageController.stream;
  Stream<FileContentMessage> get fileContent => _fileContentController.stream;
  Stream<DiffResultMessage> get diffResults => _diffResultController.stream;
  Stream<DiffImageResultMessage> get diffImageResults =>
      _diffImageResultController.stream;
  Stream<WorktreeListMessage> get worktreeList =>
      _worktreeListController.stream;
  Stream<List<WindowInfo>> get windowList => _windowListController.stream;
  Stream<ScreenshotResultMessage> get screenshotResults =>
      _screenshotResultController.stream;
  Stream<List<OfflinePendingAction>> get offlinePendingActionsStream =>
      _offlinePendingActionsController.stream;
  Stream<DebugBundleMessage> get debugBundles => _debugBundleController.stream;
  Stream<UsageResultMessage> get usageResults => _usageController.stream;
  Stream<RecordingListMessage> get recordingList =>
      _recordingListController.stream;
  Stream<RecordingContentMessage> get recordingContent =>
      _recordingContentController.stream;
  Stream<PromptHistoryBackupResultMessage> get backupResults =>
      _backupResultController.stream;
  Stream<PromptHistoryRestoreResultMessage> get restoreResults =>
      _restoreResultController.stream;
  Stream<PromptHistoryBackupInfoMessage> get backupInfo =>
      _backupInfoController.stream;
  Stream<PromptHistorySyncResultMessage> get promptHistorySyncResults =>
      _promptHistorySyncController.stream;
  Stream<PromptHistoryMutationResultMessage> get promptHistoryMutationResults =>
      _promptHistoryMutationController.stream;
  Stream<PromptHistoryStatusMessage> get promptHistoryStatus =>
      _promptHistoryStatusController.stream;
  Stream<LocalFeatureServerMessage> get localFeatureMessages =>
      _localFeatureMessageController.stream.map((pair) => pair.$1);
  Stream<ClientDeliveryModeStateMessage> get clientDeliveryModeStates =>
      _clientDeliveryModeStateController.stream;
  Stream<BackgroundNotificationMessage> get backgroundNotifications =>
      _backgroundNotificationController.stream;
  Stream<BackgroundActivityStateMessage> get backgroundActivityStates =>
      _backgroundActivityStateController.stream;
  Stream<PushRegistrationStateMessage> get pushRegistrationStates =>
      _pushRegistrationStateController.stream;
  // Git Operations
  Stream<GitStageResultMessage> get gitStageResults =>
      _gitStageResultController.stream;
  Stream<GitUnstageResultMessage> get gitUnstageResults =>
      _gitUnstageResultController.stream;
  Stream<GitUnstageHunksResultMessage> get gitUnstageHunksResults =>
      _gitUnstageHunksResultController.stream;
  Stream<GitCommitResultMessage> get gitCommitResults =>
      _gitCommitResultController.stream;
  Stream<GitPushResultMessage> get gitPushResults =>
      _gitPushResultController.stream;
  Stream<GitBranchesResultMessage> get gitBranchesResults =>
      _gitBranchesResultController.stream;
  Stream<GitCreateBranchResultMessage> get gitCreateBranchResults =>
      _gitCreateBranchResultController.stream;
  Stream<GitCheckoutBranchResultMessage> get gitCheckoutBranchResults =>
      _gitCheckoutBranchResultController.stream;
  Stream<GitRevertFileResultMessage> get gitRevertFileResults =>
      _gitRevertFileResultController.stream;
  Stream<GitRevertHunksResultMessage> get gitRevertHunksResults =>
      _gitRevertHunksResultController.stream;
  Stream<GitFetchResultMessage> get gitFetchResults =>
      _gitFetchResultController.stream;
  Stream<GitPullResultMessage> get gitPullResults =>
      _gitPullResultController.stream;
  Stream<GitStatusResultMessage> get gitStatusResults =>
      _gitStatusResultController.stream;
  Stream<GitRemoteStatusResultMessage> get gitRemoteStatusResults =>
      _gitRemoteStatusResultController.stream;
  BridgeConnectionState get currentBridgeConnectionState => _connectionState;
  @override
  bool get isConnected => _connectionState == BridgeConnectionState.connected;
  bool get isTransportHealthy =>
      isConnected && _channel != null && _channel?.closeCode == null;
  List<SessionInfo> get sessions => _sessions;
  List<RecentSession> get recentSessions => _recentSessions;
  bool get recentSessionsHasMore => _recentSessionsHasMore;
  RecentSessionsMessage? get lastRecentSessionsMessage =>
      _lastRecentSessionsMessage;
  String? get bridgeInstanceId => _bridgeInstanceId;
  String? get currentProjectFilter => _currentProjectFilter;
  List<GalleryImage> get galleryImages => _galleryImages;
  List<String> get projectHistory => _projectHistory;
  List<String> get allowedDirs => _allowedDirs;
  List<String> get claudeModels => _claudeModels;
  Map<String, List<String>> get claudeModelEfforts => _claudeModelEfforts;
  List<String> get codexModels => _codexModels;
  Map<String, List<String>> get codexModelReasoningEfforts =>
      _codexModelReasoningEfforts;
  Map<String, List<String>> get codexModelServiceTiers =>
      _codexModelServiceTiers;
  int get codexModelCatalogRevision => _codexModelCatalogRevision;
  List<String> get codexProfiles => _codexProfiles;
  String? get defaultCodexProfile => _defaultCodexProfile;
  bool get codexAutoReviewDisabled => _codexAutoReviewDisabled;
  String? get bridgeVersion => _bridgeVersion;
  Set<String> get bridgeCapabilities => _bridgeCapabilities;
  bool get supportsBackgroundNotificationDelivery => _bridgeCapabilities
      .contains(backgroundNotificationDeliveryBridgeCapability);
  bool get supportsPushRegistrationStatus =>
      _bridgeCapabilities.contains(pushRegistrationStatusBridgeCapability);
  bool get supportsSessionCatalogWatch =>
      _bridgeCapabilities.contains(sessionCatalogWatchCapability);
  bool get supportsSessionCatalogRequestCorrelation =>
      _bridgeCapabilities.contains(sessionCatalogRequestCorrelationCapability);
  bool get supportsConversationContentEvents =>
      _bridgeCapabilities.contains(conversationContentEventCapability);
  BridgeClientDeliveryMode get desiredClientDeliveryMode =>
      _desiredClientDeliveryMode;
  String? get promptHistoryBridgeId => _promptHistoryBridgeId;
  UsageResultMessage? get lastUsageResult => _lastUsageResult;
  List<OfflinePendingAction> get offlinePendingActions =>
      _offlinePendingActions;

  bool hasPendingSessionStart({
    required String projectPath,
    required String provider,
  }) {
    return _allPendingSessionMessages().any((message) {
      final action = _offlinePendingActionFor(message);
      return action?.kind == OfflinePendingActionKind.start &&
          action?.provider == provider &&
          _samePendingProjectPath(action!.projectPath, projectPath);
    });
  }

  bool hasPendingSessionResume({
    required String sessionId,
    required String provider,
  }) {
    return _allPendingSessionMessages().any((message) {
      final action = _offlinePendingActionFor(message);
      return action?.kind == OfflinePendingActionKind.resume &&
          action?.provider == provider &&
          action?.sessionId == sessionId;
    });
  }

  Iterable<ClientMessage> _allPendingSessionMessages() sync* {
    yield* _messageQueue;
    yield* _inFlightPendingMessages.values;
  }

  BridgeService({
    this.permissionChangeTimeout = const Duration(seconds: 30),
    this.fileTransferClientSupported = false,
    this.clientAppVersion,
    this.clientMobileRuntime,
  }) {
    unawaited(_ensureOfflineQueueRestored());
  }

  /// Reads one file at a time so a legacy Bridge response without requestId
  /// cannot be confused with another in-flight File Peek request. New Bridges
  /// echo requestId, which is still checked together with the exact file path.
  Future<FileContentMessage> readFile({
    required String projectPath,
    required String filePath,
    int? maxLines,
    Duration timeout = const Duration(seconds: 15),
  }) {
    return _enqueueFileRead(
      filePath: filePath,
      requestType: 'read_file',
      timeout: timeout,
      buildRequest: (requestId) => ClientMessage.readFile(
        projectPath,
        filePath,
        requestId: requestId,
        maxLines: maxLines,
      ),
    );
  }

  /// Reads a source artifact through an identity-authorized one-shot RPC.
  /// The Bridge derives the current project/worktree roots from [sessionId].
  Future<FileContentMessage> readArtifactSource({
    required String sessionId,
    required String messageId,
    required String artifactId,
    required String filePath,
    int? maxLines,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if ([sessionId, messageId, artifactId, filePath]
        .any((value) => value.trim().isEmpty)) {
      throw ArgumentError('Artifact source identity is incomplete.');
    }
    try {
      return await _enqueueFileRead(
        filePath: filePath,
        requestType: 'read_artifact_source',
        timeout: timeout,
        buildRequest: (requestId) => ClientMessage.readArtifactSource(
          requestId: requestId,
          sessionId: sessionId,
          messageId: messageId,
          artifactId: artifactId,
          filePath: filePath,
          maxLines: maxLines,
        ),
      );
    } on TimeoutException catch (error) {
      throw ArtifactSourceReadException(
        code: 'artifact_source_read_timeout',
        message: error.message ?? 'Timed out while reading the artifact source.',
      );
    } on StateError catch (error) {
      final message = error.message.toString();
      final code = message.contains('does not support')
          ? 'artifact_source_read_unsupported'
          : message.contains('changed')
          ? 'bridge_changed'
          : 'bridge_disconnected';
      throw ArtifactSourceReadException(code: code, message: message);
    }
  }

  Future<FileContentMessage> _enqueueFileRead({
    required String filePath,
    required String requestType,
    required Duration timeout,
    required ClientMessage Function(String requestId) buildRequest,
  }) {
    final result = _fileReadSerial.then(
      (_) => _readFileOnce(
        filePath: filePath,
        requestType: requestType,
        timeout: timeout,
        buildRequest: buildRequest,
      ),
    );
    _fileReadSerial = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<FileContentMessage> _readFileOnce({
    required String filePath,
    required String requestType,
    required Duration timeout,
    required ClientMessage Function(String requestId) buildRequest,
  }) async {
    if (!isConnected) {
      throw StateError('Bridge is not connected.');
    }
    final requestEpoch = _connectionEpoch;
    final requestId = _newFileReadRequestId();
    bool matchesResponse(FileContentMessage message) {
      final responseRequestId = message.requestId?.trim();
      if (responseRequestId != null && responseRequestId.isNotEmpty) {
        return responseRequestId == requestId && message.filePath == filePath;
      }
      return requestType == 'read_file' && message.filePath == filePath;
    }
    final responseCompleter = Completer<FileContentMessage>();
    final pendingRead = _PendingFileRead(
      requestType: requestType,
      completer: responseCompleter,
    );
    _pendingFileRead = pendingRead;
    late final StreamSubscription<FileContentMessage> responseSubscription;
    responseSubscription = fileContent.listen(
      (message) {
        if (matchesResponse(message) && !responseCompleter.isCompleted) {
          responseCompleter.complete(message);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!responseCompleter.isCompleted) {
          responseCompleter.completeError(error, stackTrace);
        }
      },
      onDone: () {
        if (!responseCompleter.isCompleted) {
          responseCompleter.completeError(
            StateError('Bridge file response stream closed.'),
          );
        }
      },
    );
    final connectionSubscription = connectionStatus.listen((state) {
      if (state != BridgeConnectionState.connected &&
          !responseCompleter.isCompleted) {
        responseCompleter.completeError(
          StateError('Bridge disconnected while reading the file.'),
        );
      }
    });
    final errorSubscription = messages.listen((message) {
      final isUnsupportedRead =
          message is ErrorMessage &&
          message.errorCode == 'unsupported_message' &&
          message.message == requestType;
      final isLegacyInvalidFormat =
          message is ErrorMessage &&
          message.errorCode == null &&
          message.message == 'Invalid message format';
      if ((isUnsupportedRead || isLegacyInvalidFormat) &&
          !responseCompleter.isCompleted) {
        responseCompleter.completeError(
          StateError('Bridge does not support this file read request.'),
        );
      }
    });

    late final FileContentMessage response;
    try {
      send(buildRequest(requestId));
      response = await responseCompleter.future.timeout(timeout);
    } finally {
      if (identical(_pendingFileRead, pendingRead)) {
        _pendingFileRead = null;
      }
      await responseSubscription.cancel();
      await connectionSubscription.cancel();
      await errorSubscription.cancel();
    }
    if (!isConnected || _connectionEpoch != requestEpoch) {
      throw StateError('Bridge changed while reading the file.');
    }
    return response;
  }

  String _newFileReadRequestId() {
    final random = _artifactRequestRandom.nextInt(0x7fffffff).toRadixString(16);
    return 'file-${DateTime.now().microsecondsSinceEpoch}-$random';
  }

  /// Resolves a Bridge-owned artifact reference to a short-lived URL on the
  /// currently connected Bridge. Absolute URLs from the server are rejected so
  /// an artifact response cannot redirect the client to another origin.
  Future<ResolvedArtifact> resolveArtifact({
    required String sessionId,
    required String messageId,
    required String artifactId,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final requestEpoch = _connectionEpoch;
    final baseUrl = httpBaseUrl;
    if (!isConnected || baseUrl == null) {
      throw const ArtifactResolveException(
        code: 'bridge_disconnected',
        message: 'Bridge is not connected.',
      );
    }
    if (sessionId.isEmpty || messageId.isEmpty || artifactId.isEmpty) {
      throw const ArtifactResolveException(
        code: 'invalid_artifact_request',
        message: 'The file reference is incomplete.',
      );
    }

    final requestId = _newArtifactRequestId();
    final completer = Completer<ArtifactResolvedMessage>();
    _pendingArtifactResolutions[requestId] = completer;

    try {
      try {
        send(
          ClientMessage.resolveArtifact(
            requestId: requestId,
            sessionId: sessionId,
            messageId: messageId,
            artifactId: artifactId,
          ),
        );
      } catch (error, stackTrace) {
        logger.warning(
          'WS artifact resolution dispatch failed',
          error,
          stackTrace,
        );
        final connectionChanged =
            _connectionEpoch != requestEpoch || httpBaseUrl != baseUrl;
        _failArtifactResolution(
          requestId,
          ArtifactResolveException(
            code: connectionChanged
                ? 'bridge_changed'
                : 'bridge_disconnected',
            message: connectionChanged
                ? 'Bridge changed while preparing the file.'
                : 'Bridge disconnected while preparing the file.',
          ),
        );
      }
      final response = await completer.future.timeout(
        timeout,
        onTimeout: () => throw const ArtifactResolveException(
          code: 'artifact_resolve_timeout',
          message: 'Timed out while preparing the file.',
        ),
      );
      if (!isConnected) {
        throw const ArtifactResolveException(
          code: 'bridge_disconnected',
          message: 'Bridge disconnected while preparing the file.',
        );
      }
      if (_connectionEpoch != requestEpoch || httpBaseUrl != baseUrl) {
        throw const ArtifactResolveException(
          code: 'bridge_changed',
          message: 'Bridge changed while preparing the file.',
        );
      }
      if (response.artifactId != artifactId) {
        throw const ArtifactResolveException(
          code: 'artifact_response_mismatch',
          message: 'Bridge returned a mismatched file reference.',
        );
      }
      if (!response.isSuccess) {
        throw ArtifactResolveException(
          code: response.errorCode ?? 'artifact_resolve_failed',
          message: response.error ?? 'Unable to prepare the file.',
        );
      }
      final url = resolveArtifactRelativeUrl(baseUrl, response.relativeUrl!);
      return ResolvedArtifact(
        artifactId: response.artifactId,
        url: url,
        expiresAt: response.expiresAt,
      );
    } finally {
      _pendingArtifactResolutions.remove(requestId);
    }
  }

  String _newArtifactRequestId() {
    final random = _artifactRequestRandom.nextInt(0x7fffffff).toRadixString(16);
    return 'artifact-${DateTime.now().microsecondsSinceEpoch}-$random';
  }

  void _completeArtifactResolution(ArtifactResolvedMessage message) {
    final completer = _pendingArtifactResolutions.remove(message.requestId);
    if (completer != null && !completer.isCompleted) {
      completer.complete(message);
    }
  }

  void _failArtifactResolution(
    String requestId,
    ArtifactResolveException error,
  ) {
    final completer = _pendingArtifactResolutions.remove(requestId);
    if (completer != null && !completer.isCompleted) {
      completer.completeError(error);
    }
  }

  bool _consumeArtifactInfrastructureMessage(ServerMessage message) {
    if (message is ArtifactResolvedMessage) {
      _completeArtifactResolution(message);
      return true;
    }
    if (message is! ErrorMessage) return false;

    var consumed = false;
    final pendingRead = _pendingFileRead;
    final isExplicitUnsupportedRead =
        pendingRead != null &&
        !pendingRead.completer.isCompleted &&
        message.errorCode == 'unsupported_message' &&
        message.message == pendingRead.requestType;
    final isLegacyInvalidFormat =
        message.errorCode == null && message.message == 'Invalid message format';
    final isLegacyUnsupportedArtifactRead =
        pendingRead != null &&
        !pendingRead.completer.isCompleted &&
        pendingRead.requestType == 'read_artifact_source' &&
        isLegacyInvalidFormat;
    if (isExplicitUnsupportedRead || isLegacyUnsupportedArtifactRead) {
      pendingRead.completer.completeError(
        StateError('Bridge does not support ${pendingRead.requestType}.'),
      );
      consumed = true;
    }

    final isExplicitUnsupported =
        message.errorCode == 'unsupported_message' &&
        message.message == 'resolve_artifact';
    final isLegacyUnsupportedResolve =
        _pendingArtifactResolutions.isNotEmpty &&
        message.errorCode == null &&
        message.message == 'Invalid message format';
    if (isExplicitUnsupported || isLegacyUnsupportedResolve) {
      _failPendingArtifactResolutions(
        const ArtifactResolveException(
          code: 'artifact_resolve_unsupported',
          message: 'Bridge does not support file resolution.',
        ),
      );
      consumed = true;
    }
    return consumed;
  }

  bool _consumeLocalFeatureInfrastructureMessage(
    ServerMessage message, {
    String? sessionId,
  }) {
    if (message is ErrorMessage) {
      final pending = _takePendingLocalFeatureRequestForError(message);
      if (pending == null) return false;
      final request = pending.descriptor;
      final localError = LocalFeatureRequestErrorMessage(
        featureId: request.featureId,
        ownerSessionId: request.ownerSessionId,
        requestType: request.requestType,
        requestId: request.requestId,
        message: message.message,
        errorCode: message.errorCode,
      );
      _localFeatureMessageController.add((localError, request.ownerSessionId));
      return true;
    }
    if (message is! LocalFeatureServerMessage) return false;
    if (message is CodexDesktopContinuityEventMessage) {
      _patchExternalDesktopTurn(message);
    }
    _clearPendingLocalFeatureRequestForTerminal(message);
    final localSessionId = message.sessionId ?? sessionId;
    _localFeatureMessageController.add((message, localSessionId));
    _messageController.add(message);
    return true;
  }

  _PendingLocalFeatureRequest? _registerPendingLocalFeatureRequest(
    ClientMessage message,
  ) {
    final descriptor = LocalFeatureProtocolHost.describeRequest(
      message,
      protocolSlots: _localFeatureProtocolSlotsForTest,
    );
    if (descriptor == null) return null;

    final now = _localFeatureRequestClock();
    _prunePendingLocalFeatureRequests(now);
    while (_pendingLocalFeatureRequests.length >=
        _maxPendingLocalFeatureRequests) {
      _pendingLocalFeatureRequests.removeAt(0);
    }
    final pending = _PendingLocalFeatureRequest(
      descriptor: descriptor,
      epoch: _connectionEpoch,
      expiresAt: now.add(_localFeatureRequestTtl),
    );
    _pendingLocalFeatureRequests.add(pending);
    return pending;
  }

  void _rollbackPendingLocalFeatureRequest(
    _PendingLocalFeatureRequest? pending,
  ) {
    if (pending != null) _pendingLocalFeatureRequests.remove(pending);
  }

  _PendingLocalFeatureRequest? _takePendingLocalFeatureRequestForError(
    ErrorMessage error,
  ) {
    _prunePendingLocalFeatureRequests(_localFeatureRequestClock());
    if (error.errorCode == null && error.message == 'Invalid message format') {
      return null;
    }

    if (error.errorCode == 'unsupported_message') {
      final index = _pendingLocalFeatureRequests.indexWhere(
        (pending) => pending.descriptor.requestType == error.message,
      );
      if (index < 0) return null;
      return _pendingLocalFeatureRequests.removeAt(index);
    }

    for (var index = 0; index < _pendingLocalFeatureRequests.length; index++) {
      final pending = _pendingLocalFeatureRequests[index];
      final request = pending.descriptor;
      final matchesFeatureError = LocalFeatureProtocolHost.matchesRequestError(
        request,
        error,
        protocolSlots: _localFeatureProtocolSlotsForTest,
      );
      if (!matchesFeatureError) continue;
      _pendingLocalFeatureRequests.removeAt(index);
      return pending;
    }
    return null;
  }

  void _clearPendingLocalFeatureRequestForTerminal(
    LocalFeatureServerMessage message,
  ) {
    _prunePendingLocalFeatureRequests(_localFeatureRequestClock());
    for (var index = 0; index < _pendingLocalFeatureRequests.length; index++) {
      final pending = _pendingLocalFeatureRequests[index];
      if (!LocalFeatureProtocolHost.matchesTerminalResponse(
        pending.descriptor,
        message,
        protocolSlots: _localFeatureProtocolSlotsForTest,
      )) {
        continue;
      }
      _pendingLocalFeatureRequests.removeAt(index);
      return;
    }
  }

  void _prunePendingLocalFeatureRequests(DateTime now) {
    _pendingLocalFeatureRequests.removeWhere(
      (pending) =>
          pending.epoch != _connectionEpoch || !pending.expiresAt.isAfter(now),
    );
  }

  void _clearPendingLocalFeatureRequests() {
    _pendingLocalFeatureRequests.clear();
  }

  @visibleForTesting
  void completeArtifactResolutionForTest(ArtifactResolvedMessage message) {
    _completeArtifactResolution(message);
  }

  @visibleForTesting
  bool consumeArtifactInfrastructureMessageForTest(ServerMessage message) {
    return _consumeArtifactInfrastructureMessage(message);
  }

  @visibleForTesting
  bool consumeLocalFeatureInfrastructureMessageForTest(
    ServerMessage message, {
    String? sessionId,
  }) {
    return _consumeLocalFeatureInfrastructureMessage(
      message,
      sessionId: sessionId,
    );
  }

  @visibleForTesting
  void setLocalFeatureProtocolSlotsForTest(
    Iterable<LocalFeatureProtocolSlot> slots,
  ) {
    _clearPendingLocalFeatureRequests();
    _localFeatureProtocolSlotsForTest = List.unmodifiable(slots);
  }

  @visibleForTesting
  void setLocalFeatureRequestClockForTest(DateTime Function() clock) {
    _localFeatureRequestClock = clock;
  }

  @visibleForTesting
  List<LocalFeatureRequestDescriptor> get pendingLocalFeatureRequestsForTest {
    _prunePendingLocalFeatureRequests(_localFeatureRequestClock());
    return List.unmodifiable(
      _pendingLocalFeatureRequests.map((pending) => pending.descriptor),
    );
  }

  /// Register an optional mobile-only permission observation seam.
  ///
  /// Observers run in registration order. The returned callback removes
  /// exactly this registration and is safe to invoke more than once.
  VoidCallback registerPermissionRequestObserver(
    SessionPermissionRequestObserver observer,
  ) {
    final registration = _PermissionRequestObserverRegistration(observer);
    _permissionRequestObservers.add(registration);
    var active = true;
    return () {
      if (!active) return;
      active = false;
      _permissionRequestObservers.remove(registration);
    };
  }

  void _notifyPermissionRequestObservers(
    String sessionId,
    PermissionRequestMessage request,
  ) {
    for (final registration
        in List<_PermissionRequestObserverRegistration>.of(
          _permissionRequestObservers,
        )) {
      try {
        registration.observer(sessionId, request);
      } catch (error, stackTrace) {
        logger.error(
          '[bridge] Permission observer failed for '
          '${request.toolUseId}',
          error,
          stackTrace,
        );
      }
    }
  }

  @visibleForTesting
  void notifyPermissionRequestObserversForTest(
    String sessionId,
    PermissionRequestMessage request,
  ) => _notifyPermissionRequestObservers(sessionId, request);

  @visibleForTesting
  void clearPendingLocalFeatureRequestsForTest() {
    _clearPendingLocalFeatureRequests();
  }

  @visibleForTesting
  int get queuedMessageCountForTest => _messageQueue.length;

  @visibleForTesting
  Future<void> flushQueuedMessagesForTest() => _flushMessageQueueAsync();

  void _failPendingArtifactResolutions(ArtifactResolveException error) {
    final completers = _pendingArtifactResolutions.values.toList();
    _pendingArtifactResolutions.clear();
    for (final completer in completers) {
      if (!completer.isCompleted) completer.completeError(error);
    }
  }

  static Uri resolveArtifactRelativeUrl(String baseUrl, String relativeUrl) {
    final relative = Uri.tryParse(relativeUrl);
    final base = Uri.tryParse(baseUrl);
    final isArtifactPath = RegExp(
      r'^/artifacts/[A-Za-z0-9_-]{43}$',
    ).hasMatch(relativeUrl);
    if (relative == null ||
        base == null ||
        !isArtifactPath ||
        relative.hasScheme ||
        relative.hasAuthority ||
        (base.scheme != 'http' && base.scheme != 'https')) {
      throw const ArtifactResolveException(
        code: 'invalid_artifact_url',
        message: 'Bridge returned an invalid file URL.',
      );
    }
    final origin = Uri.parse(
      '${base.toString().replaceFirst(RegExp(r'/+$'), '')}/',
    );
    final resolved = origin.resolveUri(relative);
    if (resolved.scheme != base.scheme ||
        resolved.host != base.host ||
        resolved.port != base.port) {
      throw const ArtifactResolveException(
        code: 'invalid_artifact_url',
        message: 'Bridge returned an invalid file URL.',
      );
    }
    return resolved;
  }

  /// The last WebSocket URL used for connection (or reconnection).
  String? get lastUrl => _lastUrl;

  /// Stable caller-owned identity for the configured machine, when known.
  ///
  /// This is intentionally local-only and never enters the Bridge protocol.
  String? get logicalConnectionIdentity => _logicalConnectionIdentity;

  void _rememberPromptHistoryBridgeId(String? value) {
    if (value != null && value.isNotEmpty) {
      _promptHistoryBridgeId = value;
    }
  }

  QueuedInputItem? deliveryPendingInputForSession(
    String sessionId, {
    bool includeHidden = false,
  }) {
    final pending = _deliveryPendingInputs[sessionId];
    if (pending == null || (!includeHidden && !pending.visible)) return null;
    return pending.item;
  }

  void setDeliveryPendingInput(
    String sessionId,
    QueuedInputItem item, {
    Duration visibleAfter = Duration.zero,
  }) {
    _deliveryPendingVisibilityTimers.remove(sessionId)?.cancel();
    _deliveryPendingInputs[sessionId] = _DeliveryPendingInputState(item);
    if (visibleAfter == Duration.zero || visibleAfter.isNegative) {
      showDeliveryPendingInput(sessionId, itemId: item.itemId);
      return;
    }
    _deliveryPendingVisibilityTimers[sessionId] = Timer(visibleAfter, () {
      _deliveryPendingVisibilityTimers.remove(sessionId);
      showDeliveryPendingInput(sessionId, itemId: item.itemId);
    });
  }

  void showDeliveryPendingInput(String sessionId, {required String itemId}) {
    final pending = _deliveryPendingInputs[sessionId];
    if (pending == null || pending.item.itemId != itemId) return;
    if (pending.visible) return;
    pending.visible = true;
    _patchSessionQueuedInput(sessionId, pending.item);
  }

  void clearDeliveryPendingInput(String sessionId, {String? itemId}) {
    final pending = _deliveryPendingInputs[sessionId];
    if (pending == null) return;
    if (itemId != null && pending.item.itemId != itemId) return;
    _deliveryPendingVisibilityTimers.remove(sessionId)?.cancel();
    _deliveryPendingInputs.remove(sessionId);
    final idx = _sessions.indexWhere((session) => session.id == sessionId);
    if (idx < 0) return;
    if (_sessions[idx].queuedInput?.itemId == pending.item.itemId) {
      _patchSessionQueuedInput(sessionId, null);
    }
  }

  /// Derive HTTP base URL from the WebSocket URL.
  /// Example: ws://host:8765/path?query=1 -> http://host:8765
  @override
  String? get httpBaseUrl {
    final url = _lastUrl;
    if (url == null) return null;
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    final scheme = uri.scheme == 'wss' ? 'https' : 'http';
    return formatUriOrigin(
      scheme: scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
    );
  }

  static const _prefKeyUrl = 'bridge_url';
  static const _prefKeyApiKey = 'bridge_api_key';
  static const _prefKeyOfflinePendingMessages =
      'bridge_offline_pending_messages_v1';
  static const _inFlightPendingVisibilityDelay = Duration(milliseconds: 600);
  static const _localFeatureRequestTtl = Duration(seconds: 20);
  static const _maxPendingLocalFeatureRequests = 256;

  Future<void>? _offlineQueueRestore;
  int _offlineQueueGeneration = 0;

  void _setBridgeConnectionState(BridgeConnectionState state) {
    if (state != BridgeConnectionState.connected) {
      _hasAuthoritativeSessionListForCurrentConnection = false;
    }
    _connectionState = state;
    _connectionController.add(state);
  }

  void _invalidatePermissionApplyCapabilities({bool notifySessions = true}) {
    _hasAuthoritativeSessionListForCurrentConnection = false;
    _bridgeCapabilities = const {};
    _sessions = _sessions
        .map(
          (session) => session.copyWith(
            codexPermissionApplyStrategySupported: false,
            // Desktop watcher state belongs to this exact WebSocket epoch.
            externalDesktopTurnActive: false,
          ),
        )
        .toList(growable: false);
    if (notifySessions) {
      _sessionListController.add(_sessions);
    }
  }

  _PendingPermissionChange? _registerPendingPermissionChange(
    ClientMessage message,
  ) {
    if (message.type != 'set_permission_mode') return null;
    final sessionId = message.sessionId;
    final permissionChangeId = message.permissionChangeId;
    if (sessionId == null || permissionChangeId == null) return null;

    _pendingPermissionChanges.remove(permissionChangeId)?.timer.cancel();
    late final _PendingPermissionChange pending;
    final timer = Timer(permissionChangeTimeout, () {
      if (!identical(_pendingPermissionChanges[permissionChangeId], pending)) {
        return;
      }
      _pendingPermissionChanges.remove(permissionChangeId);
      _emitPermissionChangeFailure(
        pending,
        'Permission change timed out before the Bridge confirmed it.',
      );
    });
    pending = _PendingPermissionChange(
      sessionId: sessionId,
      permissionChangeId: permissionChangeId,
      timer: timer,
    );
    _pendingPermissionChanges[permissionChangeId] = pending;
    return pending;
  }

  void _completePendingPermissionChange(ServerMessage message) {
    final permissionChangeId = switch (message) {
      SystemMessage(:final permissionChangeId) => permissionChangeId,
      ErrorMessage(:final permissionChangeId) => permissionChangeId,
      _ => null,
    };
    if (permissionChangeId == null) return;
    _pendingPermissionChanges.remove(permissionChangeId)?.timer.cancel();
  }

  void _rollbackPendingPermissionChange(_PendingPermissionChange? pending) {
    if (pending == null) return;
    if (identical(
      _pendingPermissionChanges[pending.permissionChangeId],
      pending,
    )) {
      _pendingPermissionChanges.remove(pending.permissionChangeId);
    }
    pending.timer.cancel();
  }

  void _failPendingPermissionChanges(String message) {
    if (_pendingPermissionChanges.isEmpty) return;
    final pending = _pendingPermissionChanges.values.toList(growable: false);
    _pendingPermissionChanges.clear();
    for (final operation in pending) {
      operation.timer.cancel();
      _emitPermissionChangeFailure(operation, message);
    }
  }

  void _cancelPendingPermissionChanges() {
    for (final operation in _pendingPermissionChanges.values) {
      operation.timer.cancel();
    }
    _pendingPermissionChanges.clear();
  }

  void _emitPermissionChangeFailure(
    _PendingPermissionChange pending,
    String message,
  ) {
    final error = ErrorMessage(
      message: message,
      errorCode: 'set_permission_mode_rejected',
      sessionId: pending.sessionId,
      permissionChangeId: pending.permissionChangeId,
    );
    _taggedMessageController.add((error, pending.sessionId));
    _messageController.add(error);
  }

  void connect(String url, {String? logicalConnectionIdentity}) {
    _failPendingPermissionChanges(
      'Bridge connection changed before the permission change was confirmed.',
    );
    // A retained session list is not authoritative for the new socket. In
    // particular, broadcasting a cached pending approval here can race the
    // asynchronous connection-state listener and replay it under a different
    // logical machine identity. Keep the capability cache conservative, but
    // wait for the new Bridge's session_list before publishing sessions.
    _invalidatePermissionApplyCapabilities(notifySessions: false);
    _failPendingArtifactResolutions(
      const ArtifactResolveException(
        code: 'bridge_changed',
        message: 'Bridge changed while preparing the file.',
      ),
    );
    final previousUrl = _lastUrl;
    final trimmedLogicalIdentity = logicalConnectionIdentity?.trim();
    final nextLogicalIdentity = trimmedLogicalIdentity?.isEmpty == true
        ? null
        : trimmedLogicalIdentity;
    final isBridgeSwitch =
        previousUrl != null &&
        (!_sameBridgeTarget(previousUrl, url) ||
            _logicalConnectionIdentity != nextLogicalIdentity);
    _connectionEpoch++;
    _resetLegacyRecentSessionsTransport();
    _failPendingHistoryRequests(clearCursors: false);
    // Legacy history responses in flight on the old socket can never arrive
    // on the new connection; stale fences would desync the FIFO pairing.
    _pendingLegacyHistoryFences.clear();
    _clearPendingLocalFeatureRequests();
    _goalRequestRouter.clear();
    final epoch = _connectionEpoch;
    _intentionalDisconnect = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _channelSub?.cancel();
    _channelSub = null;
    _channel?.sink.close();
    _channel = null;
    _lastUsageResult = null;
    _promptHistoryBridgeId = null;
    if (isBridgeSwitch) {
      _clearBridgeScopedState(clearOfflineQueue: true);
    }
    _lastUrl = url;
    _logicalConnectionIdentity = nextLogicalIdentity;

    _setBridgeConnectionState(BridgeConnectionState.connecting);
    try {
      final channel = WebSocketChannel.connect(Uri.parse(url));
      _channel = channel;
      _channelSub = channel.stream.listen(
        (data) {
          if (epoch != _connectionEpoch) return;
          try {
            final json = jsonDecode(data as String) as Map<String, dynamic>;
            if (_shouldSuppressBackgroundWireMessage(json)) return;
            var sessionId = json['sessionId'] as String?;
            var msg = ServerMessage.fromJson(json);
            if (msg is HistoryPageMessage) {
              _completeRemoteHistoryPage(msg);
              return;
            }
            if (msg is HistoryToolDetailsMessage) {
              _completeHistoryToolDetails(msg);
              return;
            }
            if (msg is ClientDeliveryModeStateMessage) {
              _completeDeliveryModeRequest(msg);
              return;
            }
            if (msg is BackgroundNotificationMessage) {
              _backgroundNotificationController.add(msg);
              return;
            }
            if (msg is BackgroundActivityStateMessage) {
              _backgroundActivityStateController.add(msg);
              return;
            }
            if (msg is PushRegistrationStateMessage) {
              _pushRegistrationStateController.add(msg);
              return;
            }
            if (msg is ErrorMessage && _isDeliveryModeProtocolError(msg)) {
              _failPendingDeliveryModeRequests(resetDesiredMode: true);
            }
            final routedGoalSessionId = _goalRequestRouter.route(
              msg,
              wireSessionId: sessionId,
            );
            if (sessionId == null && routedGoalSessionId != null) {
              sessionId = routedGoalSessionId;
              msg = _withEffectiveGoalSessionId(msg, routedGoalSessionId);
            }
            if (sessionId != null && msg is! StatusMessage) {
              _patchSessionActivity(
                sessionId,
                json['activityAt'] as String?,
              );
            }
            _completePendingPermissionChange(msg);
            if (msg is SessionListMessage) {
              for (final session in msg.sessions) {
                _rememberProviderSessionBinding(
                  session.id,
                  session.provider,
                  session.claudeSessionId,
                );
              }
            } else if (sessionId != null && msg is SystemMessage) {
              _rememberProviderSessionBinding(
                sessionId,
                msg.provider,
                msg.claudeSessionId,
              );
            }
            if (_consumeArtifactInfrastructureMessage(msg)) return;
            if (_consumeLocalFeatureInfrastructureMessage(
              msg,
              sessionId: sessionId,
            )) {
              return;
            }
            if (sessionId != null && msg is HistoryDeltaMessage) {
              _handleHistoryDelta(sessionId, msg);
              return;
            }
            if (sessionId != null && msg is HistorySnapshotMessage) {
              _handleHistorySnapshot(sessionId, msg);
              return;
            }
            if (sessionId != null) {
              if (msg is HistoryMessage &&
                  !_acceptLegacyHistoryFrame(sessionId)) {
                logger.info(
                  'Dropping stale legacy history frame for session '
                  '$sessionId',
                );
                _emitSessionHistoryReconciliation(sessionId);
                return;
              }
              if (msg is HistoryMessage) {
                _rememberRemoteHistoryWindow(
                  sessionId,
                  msg.historyWindow,
                );
                msg = HistoryMessage(
                  messages: selectTurnAwareServerMessageWindow(msg.messages),
                  historyWindow: msg.historyWindow,
                );
              }
              _cacheAcceptedInFlightInput(msg, sessionId: sessionId);
              final historyProjectionChanged = _runtimeStore.applyServerMessage(
                sessionId,
                msg,
                historySeq:
                    _readHistorySeq(json['historySeq']) ??
                    (msg is InputAckMessage ? msg.acceptedSeq : null),
              );
              // History from an older Bridge may still contain an unbounded
              // canonical transcript. Keep durable/full history in the
              // conversation mirror, but publish only the runtime store's
              // bounded tail into the render pipeline.
              if (msg is HistoryMessage && historyProjectionChanged) {
                msg = HistoryMessage(
                  messages: _runtimeStore.messages(sessionId),
                  historyWindow: msg.historyWindow,
                );
              }
              if (msg is HistoryMessage) {
                _emitSessionHistoryReconciliation(sessionId);
              }
            }
            _clearDeliveredDeliveryPendingInput(msg, sessionId: sessionId);
            _clearDeliveredInFlightInput(msg, sessionId: sessionId);
            switch (msg) {
              case SessionListMessage(
                :final sessions,
                :final droppedSessionCount,
                :final bridgeInstanceId,
                :final allowedDirs,
                :final claudeModels,
                :final claudeModelEfforts,
                :final codexModels,
                :final codexModelReasoningEfforts,
                :final codexModelServiceTiers,
                :final codexProfiles,
                :final defaultCodexProfile,
                :final codexAutoReviewDisabled,
                :final bridgeVersion,
                :final bridgeCapabilities,
              ):
                if (droppedSessionCount > 0) {
                  logger.warning(
                    'session_list contained $droppedSessionCount malformed '
                    'session entries; showing the remaining '
                    '${sessions.length}',
                  );
                }
                _hasAuthoritativeSessionListForCurrentConnection = true;
                _authoritativeSessionListGeneration++;
                _bridgeInstanceId = bridgeInstanceId;
                _rememberPromptHistoryBridgeId(bridgeInstanceId);
                final externalBySession = <String, bool>{
                  for (final session in _sessions)
                    if (session.externalDesktopTurnActive) session.id: true,
                };
                _sessions = _applyLocalDeliveryPendingInputs(
                  sessions
                      .map(
                        (session) => externalBySession[session.id] == true
                            ? session.copyWith(externalDesktopTurnActive: true)
                            : session,
                      )
                      .toList(growable: false),
                );
                _allowedDirs = allowedDirs;
                _claudeModels = claudeModels;
                _claudeModelEfforts = claudeModelEfforts;
                _codexModels = codexModels;
                _codexModelReasoningEfforts = codexModelReasoningEfforts;
                _codexModelServiceTiers = codexModelServiceTiers;
                _codexProfiles = codexProfiles;
                _defaultCodexProfile = defaultCodexProfile;
                _codexAutoReviewDisabled = codexAutoReviewDisabled;
                _codexAutoReviewPolicyController.add(codexAutoReviewDisabled);
                _bridgeVersion = bridgeVersion;
                _bridgeCapabilities = bridgeCapabilities.toSet();
                _sendNextLegacyRecentSessionsRequest();
                // Catalog metadata belongs to the same authoritative
                // session-list snapshot. Publish it before notifying session
                // listeners so already-open chats never observe the previous
                // model/effort/tier catalog for a new snapshot.
                _codexModelCatalogRevision++;
                _codexModelCatalogController.add(_codexModelCatalogRevision);
                _clearPendingStartActionsForSessions(_sessions);
                _sessionListController.add(_sessions);
              case RecentSessionsMessage():
                final recentResponse = _correlateRecentSessionsResponse(msg);
                if (recentResponse == null ||
                    !_isCurrentRecentSessionsResponse(recentResponse)) {
                  break;
                }
                final sessions = recentResponse.sessions;
                final hasMore = recentResponse.hasMore;
                final isProjectMerge =
                    recentResponse.requestScope == 'project' &&
                    recentResponse.projectPath != null &&
                    recentResponse.projectPath!.isNotEmpty;
                if (isProjectMerge) {
                  _recentSessions = _mergeRecentSessions(
                    _recentSessions,
                    sessions,
                  );
                } else if (recentResponse.requestScope == 'catalog') {
                  final catalogLimit = recentResponse.limit ?? sessions.length;
                  _recentSessionsHasMore =
                      hasMore || _recentSessions.length > catalogLimit;
                  _recentSessions = _replaceRecentSessionsCatalogPrefix(
                    _recentSessions,
                    sessions,
                    catalogLimit,
                  );
                  _finishSessionCatalogRefresh();
                } else {
                  _recentSessionsHasMore = hasMore;
                  if (recentResponse.requestScope == 'append' ||
                      (recentResponse.requestScope == null && _appendMode)) {
                    _recentSessions = _mergeRecentSessions(
                      _recentSessions,
                      sessions,
                    );
                  } else {
                    _recentSessions = sessions;
                  }
                  _appendMode = false;
                }
                final response = RecentSessionsMessage(
                  sessions: List<RecentSession>.unmodifiable(_recentSessions),
                  hasMore: isProjectMerge ? hasMore : _recentSessionsHasMore,
                  limit: recentResponse.limit,
                  offset: recentResponse.offset,
                  projectPath: recentResponse.projectPath,
                  requestScope: recentResponse.requestScope,
                  requestId: recentResponse.requestId,
                  queryGeneration: recentResponse.queryGeneration,
                  catalogRevision: recentResponse.catalogRevision,
                  provider: recentResponse.provider,
                  namedOnly: recentResponse.namedOnly,
                  searchQuery: recentResponse.searchQuery,
                );
                _lastRecentSessionsMessage = response;
                final revision = recentResponse.catalogRevision;
                if (revision != null &&
                    revision > _lastSessionCatalogRevision) {
                  _lastSessionCatalogRevision = revision;
                }
                _recentSessionResponsesController.add(response);
                _recentSessionsController.add(_recentSessions);
              case SessionCatalogChangedMessage(:final revision):
                _handleSessionCatalogChanged(revision);
              case PastHistoryMessage():
                _taggedMessageController.add((msg, sessionId));
                _messageController.add(msg);
              case GalleryListMessage(:final images):
                _galleryImages = images;
                _galleryController.add(images);
              case GalleryNewImageMessage(:final image):
                _galleryImages = [image, ..._galleryImages];
                _galleryController.add(_galleryImages);
              case FileContentMessage():
                _fileContentController.add(msg);
              case FileListMessage(:final files):
                _fileListController.add(files);
                _fileListMessageController.add(msg);
              case ProjectHistoryMessage(:final projects):
                _projectHistory = projects;
                _projectHistoryController.add(projects);
              case DiffResultMessage():
                _diffResultController.add(msg);
              case DiffImageResultMessage():
                _diffImageResultController.add(msg);
              case WorktreeListMessage():
                _worktreeListController.add(msg);
              case WindowListMessage(:final windows):
                _windowListController.add(windows);
              case ScreenshotResultMessage():
                _screenshotResultController.add(msg);
              case DebugBundleMessage():
                _debugBundleController.add(msg);
              case UsageResultMessage():
                _lastUsageResult = msg;
                _usageController.add(msg);
              case RecordingListMessage():
                _recordingListController.add(msg);
              case RecordingContentMessage():
                _recordingContentController.add(msg);
              case PromptHistoryBackupResultMessage():
                _backupResultController.add(msg);
              case PromptHistoryRestoreResultMessage():
                _restoreResultController.add(msg);
              case PromptHistoryBackupInfoMessage():
                _backupInfoController.add(msg);
              case PromptHistorySyncResultMessage():
                _rememberPromptHistoryBridgeId(msg.bridgeInstanceId);
                _promptHistorySyncController.add(msg);
              case PromptHistoryMutationResultMessage():
                _rememberPromptHistoryBridgeId(msg.bridgeInstanceId);
                _promptHistoryMutationController.add(msg);
              case PromptHistoryStatusMessage():
                _rememberPromptHistoryBridgeId(msg.bridgeInstanceId);
                _promptHistoryStatusController.add(msg);
              // Git Operations
              case GitStageResultMessage():
                _gitStageResultController.add(msg);
              case GitUnstageResultMessage():
                _gitUnstageResultController.add(msg);
              case GitUnstageHunksResultMessage():
                _gitUnstageHunksResultController.add(msg);
              case GitCommitResultMessage():
                _gitCommitResultController.add(msg);
              case GitPushResultMessage():
                _gitPushResultController.add(msg);
              case GitBranchesResultMessage():
                _gitBranchesResultController.add(msg);
              case GitCreateBranchResultMessage():
                _gitCreateBranchResultController.add(msg);
              case GitCheckoutBranchResultMessage():
                _gitCheckoutBranchResultController.add(msg);
              case GitRevertFileResultMessage():
                _gitRevertFileResultController.add(msg);
              case GitRevertHunksResultMessage():
                _gitRevertHunksResultController.add(msg);
              case GitFetchResultMessage():
                _gitFetchResultController.add(msg);
              case GitPullResultMessage():
                _gitPullResultController.add(msg);
              case GitStatusResultMessage():
                _gitStatusResultController.add(msg);
              case GitRemoteStatusResultMessage():
                _gitRemoteStatusResultController.add(msg);
              case ArchiveResultMessage(:final success):
                if (success) {
                  // Refresh the recent sessions list to reflect the archived session
                  requestRecentSessions();
                }
                _messageController.add(msg);
              case ArchivedSessionsResultMessage():
                _messageController.add(msg);
              case SessionLifecycleResultMessage(:final success):
                if (success) requestRecentSessions();
                _messageController.add(msg);
              case WorktreeRemovedMessage():
                _messageController.add(msg);
              case ConversationQueueMessage(:final items):
                if (sessionId != null) {
                  _patchSessionQueuedInput(
                    sessionId,
                    items.isNotEmpty ? items.first : null,
                  );
                }
                _taggedMessageController.add((msg, sessionId));
                _messageController.add(msg);
              case GoalStateMessage():
                if (sessionId == null) {
                  logger.warning(
                    'Ignoring an unscoped Goal state with no unique live request owner.',
                  );
                } else {
                  _taggedMessageController.add((msg, sessionId));
                }
                _messageController.add(msg);
              case AssistantServerMessage(:final message):
                if (sessionId != null) {
                  _patchSessionLastMessage(sessionId, message);
                }
                _taggedMessageController.add((msg, sessionId));
                _messageController.add(msg);
              case PermissionRequestMessage():
                if (sessionId != null) {
                  _notifyPermissionRequestObservers(sessionId, msg);
                  _patchSessionPermission(sessionId, msg);
                }
                _taggedMessageController.add((msg, sessionId));
                _messageController.add(msg);
              case PermissionResolvedMessage():
                if (sessionId != null) {
                  clearSessionPermission(sessionId);
                }
                _taggedMessageController.add((msg, sessionId));
                _messageController.add(msg);
              case SystemMessage(:final permissionMode):
                if (msg.subtype == 'session_created' ||
                    msg.subtype == 'session_start_failed') {
                  _clearPendingSessionActionFor(msg);
                } else if (msg.subtype == 'session_resume_started') {
                  _markPendingSessionActionProcessing(msg);
                } else if (msg.subtype == 'session_resume_failed') {
                  _clearFailedResumeAction(msg);
                }
                if (sessionId != null && permissionMode != null) {
                  _patchSessionPermissionMode(
                    sessionId,
                    permissionMode,
                    provider: msg.provider,
                    executionMode: msg.executionMode,
                    planMode: msg.planMode,
                    approvalPolicy: msg.approvalPolicy,
                    approvalsReviewer: msg.approvalsReviewer,
                    codexPermissionsMode: msg.codexPermissionsMode,
                  );
                }
                if (sessionId != null) {
                  _patchSessionSystemSettings(sessionId, msg);
                }
                _taggedMessageController.add((msg, sessionId));
                _messageController.add(msg);
              case StatusMessage(:final status, :final activityAt):
                // Patch cached session list so the session list screen
                // reflects status changes in real-time.
                if (sessionId != null) {
                  _patchSessionStatus(
                    sessionId,
                    status,
                    activityAt: activityAt,
                  );
                }
                _taggedMessageController.add((msg, sessionId));
                _messageController.add(msg);
              case ResultMessage(:final subtype) when subtype == 'stopped':
                if (sessionId != null) {
                  clearExplorerHistory(sessionId);
                  _sessions = _sessions
                      .where((session) => session.id != sessionId)
                      .toList();
                  _sessionListController.add(_sessions);
                  _sessionStoppedController.add(sessionId);
                  clearDiffImageCache();
                }
                _taggedMessageController.add((msg, sessionId));
                _messageController.add(msg);
              case ErrorMessage(:final message):
                if (msg.errorCode == 'unsupported_message' &&
                    message == 'get_history_delta') {
                  _fallbackPendingHistoryDeltaRequests();
                }
                if (msg.errorCode == 'unsupported_message' &&
                    message == 'resolve_session_link') {
                  _completePendingSessionLinkResolutionsAsUnsupported();
                } else {
                  logger.error('Bridge error: $message');
                  if (sessionId == null && _isUnscopedGoalProtocolError(msg)) {
                    logger.warning(
                      'Ignoring an unscoped Goal error with no live request '
                      'owner.',
                    );
                  } else {
                    _taggedMessageController.add((msg, sessionId));
                  }
                  _messageController.add(msg);
                }
              case SessionLinkResolutionMessage(:final requestId):
                final completer = _pendingSessionLinkResolutions.remove(
                  requestId,
                );
                if (completer != null && !completer.isCompleted) {
                  completer.complete(SessionLinkResolveResult.resolved(msg));
                }
              default:
                _taggedMessageController.add((msg, sessionId));
                _messageController.add(msg);
            }
          } catch (e, st) {
            logger.error('WS parse error', e, st);
            final errorMsg = ErrorMessage(message: 'Parse error: $e');
            _taggedMessageController.add((errorMsg, null));
            _messageController.add(errorMsg);
          }
        },
        onError: (error, stackTrace) {
          if (epoch != _connectionEpoch) return;
          logger.error('WS stream error', error, stackTrace);
          _failPendingHistoryRequests(clearCursors: false);
          _clearPendingLocalFeatureRequests();
          _goalRequestRouter.clear();
          _failPendingPermissionChanges(
            'Bridge disconnected before the permission change was confirmed.',
          );
          _invalidatePermissionApplyCapabilities();
          _setBridgeConnectionState(BridgeConnectionState.disconnected);
          _failPendingArtifactResolutions(
            const ArtifactResolveException(
              code: 'bridge_disconnected',
              message: 'Bridge disconnected while preparing the file.',
            ),
          );
          _requeueInFlightInputMessages();
          _requeueInFlightPendingMessages();
          _scheduleReconnect();
        },
        onDone: () {
          if (epoch != _connectionEpoch) return;
          _channel = null;
          _failPendingHistoryRequests(clearCursors: false);
          _clearPendingLocalFeatureRequests();
          _goalRequestRouter.clear();
          _failPendingPermissionChanges(
            'Bridge disconnected before the permission change was confirmed.',
          );
          _invalidatePermissionApplyCapabilities();
          if (!_intentionalDisconnect) {
            _setBridgeConnectionState(BridgeConnectionState.disconnected);
            _failPendingArtifactResolutions(
              const ArtifactResolveException(
                code: 'bridge_disconnected',
                message: 'Bridge disconnected while preparing the file.',
              ),
            );
            _requeueInFlightInputMessages();
            _requeueInFlightPendingMessages();
            _scheduleReconnect();
          } else {
            _setBridgeConnectionState(BridgeConnectionState.disconnected);
          }
        },
      );
      unawaited(
        channel.ready
            .then((_) {
              if (epoch != _connectionEpoch ||
                  !identical(_channel, channel) ||
                  _intentionalDisconnect) {
                return;
              }
              _setBridgeConnectionState(BridgeConnectionState.connected);
              _reconnectAttempt = 0;
              send(
                ClientMessage.clientCapabilities(
                  appVersion: clientAppVersion,
                  fileTransferSupported: fileTransferClientSupported,
                  mobileRuntime: clientMobileRuntime,
                ),
              );
              _flushMessageQueue();
              if (_desiredClientDeliveryMode ==
                  BridgeClientDeliveryMode.notificationsOnly) {
                unawaited(_reassertDesiredClientDeliveryMode());
              }
            })
            .catchError((Object error, StackTrace stackTrace) {
              if (epoch != _connectionEpoch || _intentionalDisconnect) return;
              logger.error('WS handshake failed', error, stackTrace);
              _setBridgeConnectionState(BridgeConnectionState.disconnected);
              _requeueInFlightInputMessages();
              _requeueInFlightPendingMessages();
              _scheduleReconnect();
            }),
      );
    } catch (e, st) {
      logger.error('WS connect failed', e, st);
      _clearPendingLocalFeatureRequests();
      _goalRequestRouter.clear();
      _failPendingPermissionChanges(
        'Bridge connection failed before the permission change was confirmed.',
      );
      _invalidatePermissionApplyCapabilities();
      _setBridgeConnectionState(BridgeConnectionState.disconnected);
      _scheduleReconnect();
    }
  }

  bool _sameBridgeTarget(String left, String right) {
    final leftUri = Uri.tryParse(left);
    final rightUri = Uri.tryParse(right);
    if (leftUri == null || rightUri == null) return left == right;
    return _bridgeTargetKey(leftUri) == _bridgeTargetKey(rightUri);
  }

  String _bridgeTargetKey(Uri uri) {
    final scheme = uri.scheme.toLowerCase();
    final host = canonicalHostIdentity(uri.host);
    final port = uri.hasPort ? uri.port : (scheme == 'wss' ? 443 : 80);
    final path = uri.path.isEmpty ? '/' : uri.path;
    return '${formatUriOrigin(scheme: scheme, host: host, port: port)}$path';
  }

  void _clearBridgeScopedState({required bool clearOfflineQueue}) {
    _resetSessionCatalogRefresh();
    _failPendingHistoryRequests(clearCursors: true);
    _clearPendingLocalFeatureRequests();
    _goalRequestRouter.clear();
    _failPendingArtifactResolutions(
      const ArtifactResolveException(
        code: 'bridge_changed',
        message: 'Bridge changed while preparing the file.',
      ),
    );
    _completePendingSessionLinkResolutionsAsUnsupported();
    _sessions = const [];
    _recentSessions = const [];
    _lastRecentSessionsMessage = null;
    _bridgeInstanceId = null;
    _recentSessionsHasMore = false;
    _appendMode = false;
    _currentProjectFilter = null;
    _recentSessionsQueryGeneration++;
    _latestRecentSessionRequestByScope.clear();
    _resetLegacyRecentSessionsTransport();
    _galleryImages = const [];
    _projectHistory = const [];
    _allowedDirs = const [];
    _claudeModels = const [];
    _claudeModelEfforts = const {};
    _codexModels = const [];
    _codexModelReasoningEfforts = const {};
    _codexModelServiceTiers = const {};
    _codexModelCatalogRevision++;
    _codexModelCatalogController.add(_codexModelCatalogRevision);
    _codexProfiles = const [];
    _defaultCodexProfile = null;
    _codexAutoReviewDisabled = false;
    _bridgeVersion = null;
    _bridgeCapabilities = const {};
    _promptHistoryBridgeId = null;
    _lastUsageResult = null;
    _pendingHistoryDeltaSinceSeq.clear();
    _pendingHistoryDeltaAllowsFullFallback.clear();
    // Frames from a torn-down socket can never arrive on the new one.
    _pendingLegacyHistoryFences.clear();
    _sessionHistoryReconciliationGenerations.clear();
    _clearSessionHistorySyncTracking();
    _providerSessionBindingByRuntime.clear();
    _respondedToolUseIds.clear();
    _deliveryPendingInputs.clear();
    for (final timer in _deliveryPendingVisibilityTimers.values) {
      timer.cancel();
    }
    _deliveryPendingVisibilityTimers.clear();
    _runtimeStore.clearAll();
    _desktopContinuityBacklog.clear();
    clearDiffImageCache();

    _sessionListController.add(_sessions);
    _recentSessionsController.add(_recentSessions);
    _galleryController.add(_galleryImages);
    _projectHistoryController.add(_projectHistory);
    _fileListController.add(const []);
    _fileListMessageController.add(const FileListMessage(files: []));

    if (clearOfflineQueue) {
      _clearOfflinePendingState();
    }
  }

  void _clearOfflinePendingState() {
    _offlineQueueGeneration++;
    _messageQueue.clear();
    _inFlightPendingMessages.clear();
    _inFlightInputMessages.clear();
    for (final timer in _inFlightPendingVisibilityTimers.values) {
      timer.cancel();
    }
    _inFlightPendingVisibilityTimers.clear();
    _visibleInFlightPendingKeys.clear();
    _offlinePendingActions = const [];
    _offlinePendingActionsController.add(_offlinePendingActions);
    _offlineQueueRestore = Future.value();
    unawaited(_clearPersistedOfflinePendingMessages());
  }

  Future<void> _clearPersistedOfflinePendingMessages() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefKeyOfflinePendingMessages);
    } catch (error, stackTrace) {
      logger.warning(
        'Failed to clear offline pending messages',
        error,
        stackTrace,
      );
    }
  }

  int? _readHistorySeq(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return null;
  }

  void _handleHistoryDelta(String sessionId, HistoryDeltaMessage msg) {
    final previousSnapshot = _runtimeStore.snapshot(sessionId);
    final hadCachedTimeline = previousSnapshot.messages.isNotEmpty;
    final previousLatestSeq = previousSnapshot.historySeq;
    final previousCachedSeq = previousSnapshot.cachedHistorySeq;
    final shouldReplace =
        hadCachedTimeline &&
        ((previousCachedSeq == 0 && msg.fromSeq <= 1) ||
            (msg.fromSeq <= previousCachedSeq + 1 &&
                msg.fromSeq <= previousLatestSeq));
    _pendingHistoryDeltaSinceSeq.remove(sessionId);
    _pendingHistoryDeltaAllowsFullFallback.remove(sessionId);
    final historyProjectionChanged = _runtimeStore.applyServerMessage(
      sessionId,
      msg,
    );

    if (shouldReplace || historyProjectionChanged) {
      final history = HistoryMessage(
        messages: _runtimeStore.messages(sessionId),
      );
      _taggedMessageController.add((history, sessionId));
      _messageController.add(history);
    } else {
      final messages = msg.entries.map((entry) => entry.message).toList();
      for (final message in messages) {
        _taggedMessageController.add((message, sessionId));
        _messageController.add(message);
      }
    }

    final status = msg.status;
    if (status != null) {
      _patchSessionStatus(sessionId, status);
      final statusMessage = StatusMessage(status: status);
      _runtimeStore.applyServerMessage(sessionId, statusMessage);
      _taggedMessageController.add((statusMessage, sessionId));
      _messageController.add(statusMessage);
    }
    _emitSessionHistoryReconciliation(sessionId);
  }

  void _handleHistorySnapshot(String sessionId, HistorySnapshotMessage msg) {
    _pendingHistoryDeltaSinceSeq.remove(sessionId);
    _pendingHistoryDeltaAllowsFullFallback.remove(sessionId);
    _rememberRemoteHistoryWindow(sessionId, msg.historyWindow);
    _runtimeStore.applyServerMessage(sessionId, msg);

    final history = HistoryMessage(
      messages: _runtimeStore.messages(sessionId),
      historyWindow: msg.historyWindow,
    );
    _taggedMessageController.add((history, sessionId));
    _messageController.add(history);

    final status = msg.status;
    if (status != null) {
      _patchSessionStatus(sessionId, status);
      final statusMessage = StatusMessage(status: status);
      _runtimeStore.applyServerMessage(sessionId, statusMessage);
      _taggedMessageController.add((statusMessage, sessionId));
      _messageController.add(statusMessage);
    }
    _emitSessionHistoryReconciliation(sessionId);
  }

  void _rememberRemoteHistoryWindow(
    String sessionId,
    HistoryWindowInfo? window,
  ) {
    if (window == null ||
        window.capability != turnAwareHistoryWindowCapability ||
        window.fromSeq <= 0) {
      return;
    }
    _remoteHistoryCursors[sessionId] = _RemoteHistoryCursor(
      beforeSeq: window.fromSeq,
      hasMore: window.hasMore,
      beforeCursor: window.cursor,
    );
  }

  void _completeRemoteHistoryPage(HistoryPageMessage message) {
    final completer = _pendingRemoteHistoryPages[message.requestId];
    if (completer != null && !completer.isCompleted) {
      completer.complete(message);
    }
  }

  void _completeHistoryToolDetails(HistoryToolDetailsMessage message) {
    final completer = _pendingHistoryToolDetails[message.requestId];
    if (completer != null && !completer.isCompleted) {
      completer.complete(message);
    }
  }

  void _failPendingHistoryRequests({required bool clearCursors}) {
    _finishActiveSessionHistorySyncs();
    final completers = _pendingRemoteHistoryPages.values.toList();
    final toolCompleters = _pendingHistoryToolDetails.values.toList();
    _pendingRemoteHistoryPages.clear();
    _pendingHistoryToolDetails.clear();
    _remoteHistoryPageFlights.clear();
    if (clearCursors) _remoteHistoryCursors.clear();
    for (final completer in completers) {
      if (!completer.isCompleted) {
        completer.completeError(
          StateError('Bridge disconnected while loading older history.'),
        );
      }
    }
    for (final completer in toolCompleters) {
      if (!completer.isCompleted) {
        completer.completeError(
          StateError('Bridge disconnected while loading tool details.'),
        );
      }
    }
  }

  void _emitSessionHistoryReconciliation(String sessionId) {
    _finishSessionHistorySync(sessionId);
    _sessionHistoryReconciliationSequence++;
    _sessionHistoryReconciliationGenerations[sessionId] =
        _sessionHistoryReconciliationSequence;
    _sessionHistoryReconciledController.add(sessionId);
  }

  void _fallbackPendingHistoryDeltaRequests() {
    if (_pendingHistoryDeltaSinceSeq.isEmpty) return;
    final sessionIds = List<String>.from(_pendingHistoryDeltaSinceSeq.keys);
    _pendingHistoryDeltaSinceSeq.clear();
    final allowsFullFallback = Map<String, bool>.from(
      _pendingHistoryDeltaAllowsFullFallback,
    );
    _pendingHistoryDeltaAllowsFullFallback.clear();
    for (final sessionId in sessionIds) {
      if (allowsFullFallback[sessionId] == true) {
        _pendingForegroundHistorySyncs.add(sessionId);
        _recordLegacyHistoryRequest(sessionId);
        send(ClientMessage.getHistory(sessionId));
      } else {
        _finishSessionHistorySync(sessionId);
      }
    }
  }

  String? _beginPendingSessionHistorySync(ClientMessage message) {
    if (_pendingForegroundHistorySyncs.isEmpty ||
        (message.type != 'get_history' &&
            message.type != 'get_history_delta')) {
      return null;
    }
    final json = jsonDecode(message.toJson()) as Map<String, dynamic>;
    final sessionId = json['sessionId'] as String?;
    if (sessionId == null ||
        !_pendingForegroundHistorySyncs.remove(sessionId)) {
      return null;
    }
    final wasActive = _activeSessionHistorySyncs.contains(sessionId);
    _activeSessionHistorySyncs.add(sessionId);
    _sessionHistorySyncTimeouts.remove(sessionId)?.cancel();
    _sessionHistorySyncTimeouts[sessionId] = Timer(
      _sessionHistorySyncTimeout,
      () => _finishSessionHistorySync(sessionId),
    );
    if (!wasActive) {
      _sessionHistorySyncChangedController.add(sessionId);
    }
    return sessionId;
  }

  void _finishSessionHistorySync(String sessionId) {
    _pendingForegroundHistorySyncs.remove(sessionId);
    _sessionHistorySyncTimeouts.remove(sessionId)?.cancel();
    if (_activeSessionHistorySyncs.remove(sessionId)) {
      _sessionHistorySyncChangedController.add(sessionId);
    }
  }

  void _finishActiveSessionHistorySyncs() {
    if (_activeSessionHistorySyncs.isEmpty) return;
    final sessionIds = _activeSessionHistorySyncs.toList(growable: false);
    _activeSessionHistorySyncs.clear();
    for (final timer in _sessionHistorySyncTimeouts.values) {
      timer.cancel();
    }
    _sessionHistorySyncTimeouts.clear();
    for (final sessionId in sessionIds) {
      _sessionHistorySyncChangedController.add(sessionId);
    }
  }

  void _clearSessionHistorySyncTracking() {
    _pendingForegroundHistorySyncs.clear();
    _finishActiveSessionHistorySyncs();
  }

  void _scheduleReconnect() {
    if (_intentionalDisconnect || _lastUrl == null) return;
    if (_reconnectTimer?.isActive ?? false) {
      _setBridgeConnectionState(BridgeConnectionState.reconnecting);
      return;
    }

    _reconnectAttempt++;
    final delay = min(pow(2, _reconnectAttempt).toInt(), _maxReconnectDelay);
    _setBridgeConnectionState(BridgeConnectionState.reconnecting);
    _reconnectTimer = Timer(Duration(seconds: delay), () {
      if (_lastUrl != null && !_intentionalDisconnect) {
        connect(
          _lastUrl!,
          logicalConnectionIdentity: _logicalConnectionIdentity,
        );
      }
    });
  }

  @override
  void send(ClientMessage message) {
    onOutgoingMessage?.call(message);
    if (_isEphemeralRpc(message)) {
      if (message.type != 'resolve_artifact') {
        final pendingPermissionChange = _registerPendingPermissionChange(
          message,
        );
        final pendingLocalRequest = _registerPendingLocalFeatureRequest(
          message,
        );
        final pendingGoalRequest = _goalRequestRouter.register(message);
        try {
          sendEphemeralRpc(message);
        } catch (error, stackTrace) {
          _rollbackPendingPermissionChange(pendingPermissionChange);
          _rollbackPendingLocalFeatureRequest(pendingLocalRequest);
          _goalRequestRouter.rollback(pendingGoalRequest);
          logger.warning('WS ephemeral RPC send failed', error, stackTrace);
          rethrow;
        }
        return;
      }
      try {
        sendArtifactResolutionRequest(message);
      } on ArtifactResolveException catch (error) {
        _failPendingArtifactResolutions(error);
      } catch (error, stackTrace) {
        logger.warning(
          'WS artifact resolution send failed',
          error,
          stackTrace,
        );
        _failPendingArtifactResolutions(
          const ArtifactResolveException(
            code: 'bridge_disconnected',
            message: 'Bridge disconnected while preparing the file.',
          ),
        );
      }
      return;
    }
    if (_channel != null && isConnected) {
      if (!_trackInFlightPendingMessage(message)) return;
      _trackInFlightInputMessage(message);
      final historySyncSessionId = _beginPendingSessionHistorySync(message);
      try {
        _channel!.sink.add(message.toJson());
      } catch (error, stackTrace) {
        if (historySyncSessionId != null) {
          _finishSessionHistorySync(historySyncSessionId);
          _pendingForegroundHistorySyncs.add(historySyncSessionId);
        }
        logger.warning('WS send failed; queued message', error, stackTrace);
        _queueOfflineMessage(message);
        _setBridgeConnectionState(BridgeConnectionState.disconnected);
        _scheduleReconnect();
      }
    } else {
      _queueOfflineMessage(message);
    }
  }

  Future<ClientDeliveryModeStateMessage?> setClientDeliveryMode({
    required BridgeClientDeliveryMode mode,
    String locale = 'en',
    bool privacyMode = false,
    List<String> enabledEventTypes = const [],
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final requestId = 'delivery-${++_deliveryModeRequestSequence}';
    _desiredClientDeliveryMode = mode;
    _deliveryLocale = locale;
    _deliveryPrivacyMode = privacyMode;
    _deliveryEnabledEventTypes = List.unmodifiable(enabledEventTypes);
    _latestDeliveryModeRequestId = requestId;
    if (!isTransportHealthy) {
      return null;
    }
    final completer = Completer<ClientDeliveryModeStateMessage>();
    _pendingDeliveryModeRequests[requestId] = completer;
    try {
      send(
        ClientMessage.setClientDeliveryMode(
          mode: mode,
          requestId: requestId,
          locale: locale,
          privacyMode: privacyMode,
          enabledEventTypes: enabledEventTypes,
        ),
      );
      return await completer.future.timeout(timeout);
    } catch (error, stackTrace) {
      if (_latestDeliveryModeRequestId == requestId &&
          mode == BridgeClientDeliveryMode.notificationsOnly) {
        _desiredClientDeliveryMode = BridgeClientDeliveryMode.interactive;
      }
      logger.warning(
        'Client delivery mode was not acknowledged',
        error,
        stackTrace,
      );
      return null;
    } finally {
      _pendingDeliveryModeRequests.remove(requestId);
    }
  }

  Future<void> _reassertDesiredClientDeliveryMode() async {
    if (_desiredClientDeliveryMode !=
        BridgeClientDeliveryMode.notificationsOnly) {
      return;
    }
    await setClientDeliveryMode(
      mode: BridgeClientDeliveryMode.notificationsOnly,
      locale: _deliveryLocale,
      privacyMode: _deliveryPrivacyMode,
      enabledEventTypes: _deliveryEnabledEventTypes,
    );
  }

  bool _shouldSuppressBackgroundWireMessage(Map<String, dynamic> json) {
    if (_desiredClientDeliveryMode !=
        BridgeClientDeliveryMode.notificationsOnly) {
      return false;
    }
    final wireType = json['type'] as String?;
    if (wireType == 'client_delivery_mode_state_v1' ||
        wireType == 'background_notification_v1' ||
        wireType == 'background_activity_state_v1' ||
        wireType == 'push_registration_state_v1') {
      return false;
    }
    if (wireType != 'error') return true;
    return !_isRawDeliveryModeProtocolError(json);
  }

  bool _isRawDeliveryModeProtocolError(Map<String, dynamic> json) {
    return json['errorCode'] == 'background_delivery_client_unsupported' ||
        (json['errorCode'] == 'unsupported_message' &&
            json['message'] == 'set_client_delivery_mode');
  }

  void _completeDeliveryModeRequest(ClientDeliveryModeStateMessage message) {
    _clientDeliveryModeStateController.add(message);
    _backgroundActivityStateController.add(
      BackgroundActivityStateMessage(
        activeWorkCount: message.activeWorkCount,
        occurredAt: DateTime.now(),
      ),
    );
    final completer = _pendingDeliveryModeRequests[message.requestId];
    if (completer != null && !completer.isCompleted) {
      completer.complete(message);
    }
  }

  bool _isDeliveryModeProtocolError(ErrorMessage message) {
    return message.errorCode == 'background_delivery_client_unsupported' ||
        (message.errorCode == 'unsupported_message' &&
            message.message == 'set_client_delivery_mode');
  }

  void _failPendingDeliveryModeRequests({required bool resetDesiredMode}) {
    if (resetDesiredMode) {
      _desiredClientDeliveryMode = BridgeClientDeliveryMode.interactive;
    }
    for (final completer in _pendingDeliveryModeRequests.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          StateError('Background delivery mode is unavailable.'),
        );
      }
    }
    _pendingDeliveryModeRequests.clear();
  }

  /// Sends a one-shot artifact RPC only on the current socket. Unlike regular
  /// client messages, it is never eligible for offline queueing or replay.
  @protected
  void sendArtifactResolutionRequest(ClientMessage message) {
    try {
      sendEphemeralRpc(message);
    } catch (error, stackTrace) {
      logger.warning(
        'WS artifact resolution send failed',
        error,
        stackTrace,
      );
      throw const ArtifactResolveException(
        code: 'bridge_disconnected',
        message: 'Bridge disconnected while preparing the file.',
      );
    }
  }

  /// Sends an ephemeral RPC on the live socket without tracking or queueing.
  @protected
  void sendEphemeralRpc(ClientMessage message) {
    final channel = _channel;
    if (channel == null || !isConnected) {
      throw StateError('Bridge is not connected.');
    }
    try {
      channel.sink.add(message.toJson());
    } catch (error, stackTrace) {
      logger.warning(
        'WS ephemeral RPC send failed (${message.type})',
        error,
        stackTrace,
      );
      _setBridgeConnectionState(BridgeConnectionState.disconnected);
      _scheduleReconnect();
      throw StateError('Bridge disconnected while sending ${message.type}.');
    }
  }

  bool _isEphemeralRpc(ClientMessage message) =>
      message.delivery == ClientMessageDelivery.ephemeral ||
      message.type == 'resolve_artifact' ||
      message.type == 'read_file' ||
      message.type == 'read_artifact_source';

  void _queueOfflineMessage(ClientMessage message) {
    if (_isEphemeralRpc(message)) {
      if (message.type == 'resolve_artifact') {
        _failPendingArtifactResolutions(
          const ArtifactResolveException(
            code: 'bridge_disconnected',
            message: 'Bridge disconnected while preparing the file.',
          ),
        );
      }
      return;
    }
    final dedupeKey = _offlineMessageDedupeKey(message);
    if (dedupeKey != null) {
      _clearInFlightPendingMessage(dedupeKey);
      _clearInFlightInputMessage(dedupeKey);
    }
    final didAdd = _addQueuedMessageIfAbsent(message);
    if (didAdd || _isPersistableOfflineMessage(message)) {
      _publishOfflinePendingActions();
    }
    if (_isPersistableOfflineMessage(message)) {
      unawaited(_persistOfflinePendingMessages());
    }
  }

  bool _addQueuedMessageIfAbsent(ClientMessage message) {
    final dedupeKey = _offlineMessageDedupeKey(message);
    final shouldSkip =
        dedupeKey != null &&
        _messageQueue.any((queued) {
          return _offlineMessageDedupeKey(queued) == dedupeKey;
        });
    if (shouldSkip) return false;
    _messageQueue.add(message);
    return true;
  }

  bool _trackInFlightPendingMessage(ClientMessage message) {
    final dedupeKey = _offlineMessageDedupeKey(message);
    if (dedupeKey == null || _offlinePendingActionFor(message) == null) {
      return true;
    }
    final isQueued = _messageQueue.any((queued) {
      return _offlineMessageDedupeKey(queued) == dedupeKey;
    });
    if (isQueued || _inFlightPendingMessages.containsKey(dedupeKey)) {
      _publishOfflinePendingActions();
      return false;
    }
    _inFlightPendingMessages[dedupeKey] = message;
    _scheduleInFlightPendingVisibility(dedupeKey);
    return true;
  }

  void _scheduleInFlightPendingVisibility(String dedupeKey) {
    _inFlightPendingVisibilityTimers[dedupeKey]?.cancel();
    _inFlightPendingVisibilityTimers[dedupeKey] = Timer(
      _inFlightPendingVisibilityDelay,
      () {
        _inFlightPendingVisibilityTimers.remove(dedupeKey);
        if (!_inFlightPendingMessages.containsKey(dedupeKey)) return;
        _visibleInFlightPendingKeys.add(dedupeKey);
        _publishOfflinePendingActions();
      },
    );
  }

  void _clearInFlightPendingMessage(String dedupeKey) {
    _inFlightPendingMessages.remove(dedupeKey);
    _visibleInFlightPendingKeys.remove(dedupeKey);
    _inFlightPendingVisibilityTimers.remove(dedupeKey)?.cancel();
  }

  void _trackInFlightInputMessage(ClientMessage message) {
    if (message.type != 'input') return;
    final dedupeKey = _offlineMessageDedupeKey(message);
    if (dedupeKey == null) return;
    _inFlightInputMessages[dedupeKey] = message;
  }

  void _cacheAcceptedInFlightInput(
    ServerMessage message, {
    required String sessionId,
  }) {
    if (message is! InputAckMessage) return;
    if (message.queued == true) return;
    final clientMessageId = message.clientMessageId;
    if (clientMessageId == null || clientMessageId.isEmpty) return;
    final key = 'input:$sessionId:$clientMessageId';
    final input = _inFlightInputMessages[key];
    if (input == null) return;

    final json = jsonDecode(input.toJson()) as Map<String, dynamic>;
    final text = json['text'] as String?;
    if (text == null) return;
    final images = json['images'] as List?;
    if (images != null && images.isNotEmpty) {
      // The ack does not include ImageStore URLs. Let the next history delta
      // fetch the canonical user_input so image-only messages remain visible
      // after leaving and re-entering the running session.
      return;
    }

    _runtimeStore.applyServerMessage(
      sessionId,
      UserInputMessage(
        text: text,
        clientMessageId: clientMessageId,
        imageCount: images?.length ?? 0,
        timestamp: DateTime.now().toUtc().toIso8601String(),
      ),
      historySeq: message.acceptedSeq,
    );
  }

  void _clearInFlightInputMessage(String dedupeKey) {
    _inFlightInputMessages.remove(dedupeKey);
  }

  void _clearDeliveredDeliveryPendingInput(
    ServerMessage message, {
    required String? sessionId,
  }) {
    if (sessionId == null) return;
    switch (message) {
      case InputAckMessage(:final clientMessageId, :final queued):
        if (clientMessageId == null || queued) return;
        clearDeliveryPendingInput(
          sessionId,
          itemId: 'pending:$clientMessageId',
        );
      case InputRejectedMessage(:final clientMessageId):
        if (clientMessageId == null) return;
        clearDeliveryPendingInput(
          sessionId,
          itemId: 'pending:$clientMessageId',
        );
      case AssistantServerMessage():
        clearDeliveryPendingInput(sessionId);
      default:
        return;
    }
  }

  void _clearDeliveredInFlightInput(
    ServerMessage message, {
    required String? sessionId,
  }) {
    switch (message) {
      case InputAckMessage(:final clientMessageId) ||
          InputRejectedMessage(:final clientMessageId):
        if (clientMessageId == null) return;
        _clearInFlightInputMessage('input:${sessionId ?? ''}:$clientMessageId');
      case AssistantServerMessage():
        if (sessionId == null) return;
        final prefix = 'input:$sessionId:';
        for (final key in List<String>.from(_inFlightInputMessages.keys)) {
          if (!key.startsWith(prefix)) continue;
          _clearInFlightInputMessage(key);
          return;
        }
      default:
        return;
    }
  }

  void _requeueInFlightInputMessages() {
    if (_inFlightInputMessages.isEmpty) return;
    final messages = List<ClientMessage>.from(_inFlightInputMessages.values);
    _inFlightInputMessages.clear();
    var didAdd = false;
    for (final message in messages) {
      didAdd = _addQueuedMessageIfAbsent(message) || didAdd;
    }
    if (didAdd) {
      unawaited(_persistOfflinePendingMessages());
    }
  }

  void _requeueInFlightPendingMessages() {
    if (_inFlightPendingMessages.isEmpty) return;
    final messages = List<ClientMessage>.from(_inFlightPendingMessages.values);
    for (final dedupeKey in _inFlightPendingMessages.keys) {
      _inFlightPendingVisibilityTimers.remove(dedupeKey)?.cancel();
      _visibleInFlightPendingKeys.remove(dedupeKey);
    }
    _inFlightPendingMessages.clear();
    var didAdd = false;
    for (final message in messages) {
      didAdd = _addQueuedMessageIfAbsent(message) || didAdd;
    }
    _publishOfflinePendingActions();
    if (didAdd) {
      unawaited(_persistOfflinePendingMessages());
    }
  }

  void _flushMessageQueue() {
    unawaited(_flushMessageQueueAsync());
  }

  Future<void> _flushMessageQueueAsync() async {
    await _ensureOfflineQueueRestored();
    if (_messageQueue.isEmpty || !isConnected) return;
    final queued = _messageQueue
        .where((message) => !_isEphemeralRpc(message))
        .toList(growable: false);
    _messageQueue.clear();
    await _persistOfflinePendingMessages();
    _publishOfflinePendingActions();
    for (final msg in queued) {
      send(msg);
    }
  }

  Future<void> _ensureOfflineQueueRestored() {
    return _offlineQueueRestore ??= _restoreOfflinePendingMessages();
  }

  bool _isPersistableOfflineMessage(ClientMessage message) {
    return switch (message.type) {
      'input' ||
      'start' ||
      'resume_session' ||
      'rename_session' ||
      'update_queued_input' ||
      'cancel_queued_input' => true,
      _ => false,
    };
  }

  String? _offlineMessageDedupeKey(ClientMessage message) {
    final json = jsonDecode(message.toJson()) as Map<String, dynamic>;
    return switch (message.type) {
      'input' when json['clientMessageId'] is String =>
        'input:${json['sessionId'] ?? ''}:${json['clientMessageId']}',
      'resume_session' =>
        'resume:${json['provider'] ?? 'claude'}:${json['sessionId']}',
      'start' =>
        'start:${_canonicalJson(
          Map<String, dynamic>.from(json)..remove('startRequestId'),
        )}',
      _ => null,
    };
  }

  String _offlinePendingActionId(ClientMessage message) {
    final key =
        _offlineMessageDedupeKey(message) ??
        _canonicalJson(jsonDecode(message.toJson()) as Map<String, dynamic>);
    return base64Url.encode(utf8.encode(key)).replaceAll('=', '');
  }

  String _canonicalJson(Object? value) {
    if (value is Map) {
      final normalized = <String, Object?>{};
      for (final key in value.keys.map((k) => k.toString()).toList()..sort()) {
        normalized[key] = _canonicalValue(value[key]);
      }
      return jsonEncode(normalized);
    }
    return jsonEncode(_canonicalValue(value));
  }

  Object? _canonicalValue(Object? value) {
    if (value is Map) {
      return {
        for (final key in value.keys.map((k) => k.toString()).toList()..sort())
          key: _canonicalValue(value[key]),
      };
    }
    if (value is List) {
      return value.map(_canonicalValue).toList();
    }
    return value;
  }

  OfflinePendingAction? _offlinePendingActionFor(
    ClientMessage message, {
    bool canCancel = true,
  }) {
    final json = jsonDecode(message.toJson()) as Map<String, dynamic>;
    final projectPath = json['projectPath'] as String?;
    if (projectPath == null || projectPath.isEmpty) return null;
    final provider = json['provider'] as String? ?? Provider.claude.value;
    final createdAt = DateTime.now();
    final state = canCancel
        ? OfflinePendingActionState.queuedForReconnect
        : OfflinePendingActionState.processing;
    return switch (message.type) {
      'start' => OfflinePendingAction(
        id: _offlinePendingActionId(message),
        kind: OfflinePendingActionKind.start,
        projectPath: projectPath,
        provider: provider,
        createdAt: createdAt,
        state: state,
        canCancel: canCancel,
      ),
      'resume_session' => OfflinePendingAction(
        id: _offlinePendingActionId(message),
        kind: OfflinePendingActionKind.resume,
        projectPath: projectPath,
        provider: provider,
        createdAt: createdAt,
        state: state,
        canCancel: canCancel,
        sessionId: json['sessionId'] as String?,
      ),
      _ => null,
    };
  }

  void _publishOfflinePendingActions() {
    final actions = <OfflinePendingAction>[];
    final seen = <String>{};
    for (final message in _messageQueue) {
      final action = _offlinePendingActionFor(message);
      if (action == null || !seen.add(action.id)) continue;
      actions.add(action);
    }
    for (final entry in _inFlightPendingMessages.entries) {
      if (!_visibleInFlightPendingKeys.contains(entry.key)) continue;
      final message = entry.value;
      final action = _offlinePendingActionFor(message, canCancel: false);
      if (action == null || !seen.add(action.id)) continue;
      actions.add(action);
    }
    _offlinePendingActions = List.unmodifiable(actions);
    _offlinePendingActionsController.add(_offlinePendingActions);
  }

  bool _samePendingProjectPath(String a, String b) {
    String normalize(String value) {
      final trimmed = value.trim();
      if (trimmed == '/') return trimmed;
      return trimmed.replaceAll(RegExp(r'/+$'), '');
    }

    return normalize(a) == normalize(b);
  }

  bool _compatiblePendingProjectPath(String a, String b) {
    if (_samePendingProjectPath(a, b)) return true;

    String basename(String value) {
      final normalized = value.trim().replaceAll(RegExp(r'/+$'), '');
      final parts = normalized.split('/').where((part) => part.isNotEmpty);
      return parts.isEmpty ? normalized : parts.last;
    }

    final left = basename(a);
    final right = basename(b);
    return left.isNotEmpty && left == right;
  }

  Future<void> cancelOfflinePendingAction(String actionId) async {
    await _ensureOfflineQueueRestored();
    _messageQueue.removeWhere((message) {
      final action = _offlinePendingActionFor(message);
      return action?.id == actionId;
    });
    for (final entry in List.of(_inFlightPendingMessages.entries)) {
      final message = entry.value;
      final action = _offlinePendingActionFor(message, canCancel: false);
      if (action?.id == actionId) {
        _clearInFlightPendingMessage(entry.key);
      }
    }
    _publishOfflinePendingActions();
    await _persistOfflinePendingMessages();
  }

  void _clearPendingSessionActionFor(SystemMessage message) {
    final provider = message.provider ?? Provider.claude.value;
    final projectPath = message.projectPath;
    final claudeSessionId = message.claudeSessionId;
    final sourceSessionId = message.sourceSessionId;
    final resumeRequestId = message.resumeRequestId;

    bool matches(ClientMessage pending) {
      final action = _offlinePendingActionFor(pending);
      if (action == null || action.provider != provider) return false;
      if (action.kind == OfflinePendingActionKind.start) return false;
      if (resumeRequestId != null) {
        final json =
            jsonDecode(pending.toJson()) as Map<String, dynamic>;
        return json['resumeRequestId'] == resumeRequestId;
      }
      if (projectPath != null &&
          !_samePendingProjectPath(action.projectPath, projectPath)) {
        return false;
      }
      return action.sessionId == claudeSessionId ||
          action.sessionId == sourceSessionId ||
          (claudeSessionId == null && sourceSessionId == null);
    }

    var removed = false;
    for (final entry in List.of(_inFlightPendingMessages.entries)) {
      if (!_shouldClearPendingStartForSessionCreated(
        entry.value,
        provider: provider,
        projectPath: projectPath,
        startRequestId: message.startRequestId,
      )) {
        if (!matches(entry.value)) continue;
      }
      _clearInFlightPendingMessage(entry.key);
      removed = true;
      break;
    }
    if (!removed) {
      final before = _messageQueue.length;
      var didRemove = false;
      _messageQueue.removeWhere((pending) {
        if (didRemove) return false;
        if (!_shouldClearPendingStartForSessionCreated(
          pending,
          provider: provider,
          projectPath: projectPath,
          startRequestId: message.startRequestId,
        )) {
          if (!matches(pending)) return false;
        }
        didRemove = true;
        return true;
      });
      removed = before != _messageQueue.length;
      if (removed) {
        unawaited(_persistOfflinePendingMessages());
      }
    }
    if (removed) {
      _publishOfflinePendingActions();
    }
  }

  void _markPendingSessionActionProcessing(SystemMessage message) {
    final sourceSessionId = message.sourceSessionId;
    if (sourceSessionId == null || sourceSessionId.isEmpty) return;
    final provider = message.provider ?? Provider.claude.value;
    final projectPath = message.projectPath;
    final resumeRequestId = message.resumeRequestId;

    for (final entry in _inFlightPendingMessages.entries) {
      final action = _offlinePendingActionFor(entry.value, canCancel: false);
      if (action == null ||
          action.kind != OfflinePendingActionKind.resume ||
          action.provider != provider ||
          action.sessionId != sourceSessionId) {
        continue;
      }
      if (resumeRequestId != null) {
        final json =
            jsonDecode(entry.value.toJson()) as Map<String, dynamic>;
        if (json['resumeRequestId'] != resumeRequestId) continue;
      }
      if (projectPath != null &&
          !_compatiblePendingProjectPath(action.projectPath, projectPath)) {
        continue;
      }

      _inFlightPendingVisibilityTimers.remove(entry.key)?.cancel();
      _visibleInFlightPendingKeys.add(entry.key);
      _publishOfflinePendingActions();
      return;
    }
  }

  void _clearFailedResumeAction(SystemMessage message) {
    final sourceSessionId = message.sourceSessionId;
    if (sourceSessionId == null || sourceSessionId.isEmpty) return;
    final provider = message.provider ?? Provider.claude.value;
    final resumeRequestId = message.resumeRequestId;

    bool matches(ClientMessage pending) {
      final action = _offlinePendingActionFor(pending);
      if (action?.kind != OfflinePendingActionKind.resume ||
          action?.provider != provider ||
          action?.sessionId != sourceSessionId) {
        return false;
      }
      if (resumeRequestId == null) return true;
      final json = jsonDecode(pending.toJson()) as Map<String, dynamic>;
      return json['resumeRequestId'] == resumeRequestId;
    }

    var removed = false;
    for (final entry in List.of(_inFlightPendingMessages.entries)) {
      if (!matches(entry.value)) continue;
      _clearInFlightPendingMessage(entry.key);
      removed = true;
      break;
    }
    if (!removed) {
      var didRemove = false;
      _messageQueue.removeWhere((pending) {
        if (didRemove || !matches(pending)) return false;
        didRemove = true;
        return true;
      });
      removed = didRemove;
      if (removed) {
        unawaited(_persistOfflinePendingMessages());
      }
    }
    if (removed) {
      _publishOfflinePendingActions();
    }
  }

  bool _shouldClearPendingStartForSessionCreated(
    ClientMessage pending, {
    required String provider,
    required String? projectPath,
    required String? startRequestId,
  }) {
    final action = _offlinePendingActionFor(pending);
    if (action == null ||
        action.kind != OfflinePendingActionKind.start ||
        action.provider != provider) {
      return false;
    }
    if (startRequestId != null) {
      final json = jsonDecode(pending.toJson()) as Map<String, dynamic>;
      return json['startRequestId'] == startRequestId;
    }
    if (projectPath == null || projectPath.isEmpty) {
      return true;
    }
    if (_compatiblePendingProjectPath(action.projectPath, projectPath)) {
      return true;
    }
    return false;
  }

  void _clearPendingStartActionsForSessions(List<SessionInfo> sessions) {
    if (_bridgeCapabilities.contains(sessionRequestCorrelationCapability)) {
      return;
    }
    if (sessions.isEmpty ||
        (_messageQueue.isEmpty && _inFlightPendingMessages.isEmpty)) {
      return;
    }

    bool overlapsActiveSession(OfflinePendingAction action) {
      if (action.kind != OfflinePendingActionKind.start) return false;
      final sameProviderSessions = sessions.where((session) {
        final provider = session.provider ?? Provider.claude.value;
        return provider == action.provider;
      }).toList();
      if (sameProviderSessions.isEmpty) return false;
      return sameProviderSessions.any(
        (session) => _compatiblePendingProjectPath(
          action.projectPath,
          session.projectPath,
        ),
      );
    }

    var removed = false;
    for (final entry in List.of(_inFlightPendingMessages.entries)) {
      final action = _offlinePendingActionFor(entry.value, canCancel: false);
      if (action == null || !overlapsActiveSession(action)) continue;
      _clearInFlightPendingMessage(entry.key);
      removed = true;
    }

    final before = _messageQueue.length;
    _messageQueue.removeWhere((message) {
      final action = _offlinePendingActionFor(message);
      return action != null && overlapsActiveSession(action);
    });
    final removedQueued = before != _messageQueue.length;
    removed = removed || removedQueued;

    if (!removed) return;
    if (removedQueued) {
      unawaited(_persistOfflinePendingMessages());
    }
    _publishOfflinePendingActions();
  }

  Future<void> _restoreOfflinePendingMessages() async {
    final generation = _offlineQueueGeneration;
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = prefs.getStringList(_prefKeyOfflinePendingMessages);
      if (encoded == null || encoded.isEmpty) return;
      if (generation != _offlineQueueGeneration) return;

      final existingJson = _messageQueue
          .map((message) => message.toJson())
          .toSet();
      final existingDedupeKeys = _messageQueue
          .map(_offlineMessageDedupeKey)
          .whereType<String>()
          .toSet();
      existingDedupeKeys.addAll(_inFlightPendingMessages.keys);
      for (final raw in encoded) {
        try {
          final json = jsonDecode(raw);
          if (json is! Map<String, dynamic>) continue;
          final message = ClientMessage.raw(json);
          if (!_isPersistableOfflineMessage(message)) continue;
          final dedupeKey = _offlineMessageDedupeKey(message);
          final isDuplicate = dedupeKey != null
              ? !existingDedupeKeys.add(dedupeKey)
              : !existingJson.add(message.toJson());
          if (!isDuplicate) {
            if (generation != _offlineQueueGeneration) return;
            _messageQueue.add(message);
          }
        } catch (error, stackTrace) {
          logger.warning(
            'Failed to restore offline pending message',
            error,
            stackTrace,
          );
        }
      }
      _publishOfflinePendingActions();
    } catch (error, stackTrace) {
      if (_isSharedPreferencesUnavailable(error)) {
        return;
      }
      logger.warning(
        'Failed to load offline pending messages',
        error,
        stackTrace,
      );
    }
  }

  bool _isSharedPreferencesUnavailable(Object error) {
    if (error is MissingPluginException) return true;
    final message = error.toString();
    return message.contains('Binding has not yet been initialized');
  }

  Future<void> _persistOfflinePendingMessages() async {
    await _ensureOfflineQueueRestored();
    final pending = _messageQueue
        .where(_isPersistableOfflineMessage)
        .map((message) => message.toJson())
        .toList();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (pending.isEmpty) {
        await prefs.remove(_prefKeyOfflinePendingMessages);
      } else {
        await prefs.setStringList(_prefKeyOfflinePendingMessages, pending);
      }
    } catch (error, stackTrace) {
      logger.warning(
        'Failed to persist offline pending messages',
        error,
        stackTrace,
      );
    }
  }

  @override
  void requestSessionList() {
    send(ClientMessage.listSessions());
  }

  Future<SessionLinkResolveResult> resolveSessionLink(
    String sessionId, {
    String provider = 'claude',
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final deadline = DateTime.now().add(timeout);
    if (!isConnected) {
      try {
        await connectionStatus
            .firstWhere((state) => state == BridgeConnectionState.connected)
            .timeout(timeout);
      } on TimeoutException {
        return const SessionLinkResolveResult.unavailable();
      }
      if (!isConnected) {
        return const SessionLinkResolveResult.unavailable();
      }
    }

    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      return const SessionLinkResolveResult.unavailable();
    }
    final requestId = 'session-link-${++_nextSessionLinkRequestId}';
    final completer = Completer<SessionLinkResolveResult>();
    _pendingSessionLinkResolutions[requestId] = completer;
    send(
      ClientMessage.resolveSessionLink(
        requestId: requestId,
        sessionId: sessionId,
        provider: provider,
      ),
    );
    try {
      return await completer.future.timeout(
        remaining,
        onTimeout: () => const SessionLinkResolveResult.unavailable(),
      );
    } finally {
      _pendingSessionLinkResolutions.remove(requestId);
      _messageQueue.removeWhere((message) {
        final json = jsonDecode(message.toJson()) as Map<String, dynamic>;
        return json['type'] == 'resolve_session_link' &&
            json['requestId'] == requestId;
      });
    }
  }

  void _completePendingSessionLinkResolutionsAsUnsupported() {
    final pending = _pendingSessionLinkResolutions.values.toList();
    _pendingSessionLinkResolutions.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) {
        completer.complete(const SessionLinkResolveResult.unsupported());
      }
    }
  }

  void requestRecentSessions({int? limit, int? offset, String? projectPath}) {
    final startsNewQuery = offset == null || offset == 0;
    if (startsNewQuery) _appendMode = false;
    _sendRecentSessionsRequest(
      limit: limit,
      offset: offset,
      projectPath: projectPath ?? _currentProjectFilter,
      requestScope: 'list',
      startsNewQuery: startsNewQuery,
    );
  }

  /// Warms the rebuildable local metadata cache without changing the active
  /// list query generation. The response remains filter-compatible with the
  /// currently visible catalog and is bounded by the Bridge scan limit.
  void requestRecentSessionsCatalog({
    int limit = _sessionCatalogCacheWarmLimit,
  }) {
    _sendRecentSessionsRequest(
      limit: limit,
      offset: 0,
      projectPath: _currentProjectFilter,
      requestScope: 'catalog',
      startsNewQuery: false,
    );
  }

  /// Load the next page of recent sessions (append mode).
  void loadMoreRecentSessions({
    int pageSize = 20,
    String? projectPath,
    int? offset,
    String requestScope = 'append',
  }) {
    final requestedProjectPath = projectPath ?? _currentProjectFilter;
    _appendMode = true;
    _sendRecentSessionsRequest(
      limit: pageSize,
      offset: offset ?? _recentSessions.length,
      projectPath: requestedProjectPath,
      requestScope: requestScope,
      startsNewQuery: false,
    );
  }

  /// Switch project filter: fetches from offset 0 for the new project.
  /// Old sessions remain visible until the server response arrives.
  void switchProjectFilter(String? projectPath, {int pageSize = 20}) {
    _currentProjectFilter = projectPath;
    _appendMode = false;
    _sendRecentSessionsRequest(
      limit: pageSize,
      offset: 0,
      projectPath: projectPath,
      requestScope: 'list',
      startsNewQuery: true,
    );
  }

  /// Switch all filters at once and re-fetch from offset 0.
  void switchFilter({
    String? projectPath,
    String? provider,
    bool? namedOnly,
    String? searchQuery,
    int pageSize = 20,
  }) {
    _currentProjectFilter = projectPath;
    _currentProvider = provider;
    _currentNamedOnly = namedOnly;
    _currentSearchQuery = searchQuery;
    _appendMode = false;
    _sendRecentSessionsRequest(
      limit: pageSize,
      offset: 0,
      projectPath: projectPath,
      requestScope: 'list',
      startsNewQuery: true,
    );
  }

  void _sendRecentSessionsRequest({
    required String requestScope,
    required bool startsNewQuery,
    int? limit,
    int? offset,
    String? projectPath,
  }) {
    if (startsNewQuery) {
      _recentSessionsQueryGeneration++;
      _latestRecentSessionRequestByScope.clear();
    }
    final requestId =
        'catalog-$_connectionEpoch-$_recentSessionsQueryGeneration-'
        '${++_recentSessionsRequestSequence}';
    final scopeKey = _recentSessionRequestScopeKey(requestScope, projectPath);
    _latestRecentSessionRequestByScope[scopeKey] = requestId;
    final request = _RecentSessionsRequest(
      limit: limit,
      offset: offset,
      projectPath: projectPath,
      requestScope: requestScope,
      requestId: requestId,
      queryGeneration: _recentSessionsQueryGeneration,
      provider: _currentProvider,
      namedOnly: _currentNamedOnly,
      searchQuery: _currentSearchQuery,
    );
    if (supportsSessionCatalogRequestCorrelation) {
      send(request.toClientMessage());
      return;
    }
    _enqueueLegacyRecentSessionsRequest(
      request,
      startsNewQuery: startsNewQuery,
    );
  }

  void _enqueueLegacyRecentSessionsRequest(
    _RecentSessionsRequest request, {
    required bool startsNewQuery,
  }) {
    if (startsNewQuery) {
      _legacyRecentSessionsRequestQueue.clear();
    } else {
      final scopeKey = _recentSessionRequestScopeKey(
        request.requestScope,
        request.projectPath,
      );
      _legacyRecentSessionsRequestQueue.removeWhere(
        (queued) =>
            _recentSessionRequestScopeKey(
              queued.requestScope,
              queued.projectPath,
            ) ==
            scopeKey,
      );
    }
    _legacyRecentSessionsRequestQueue.add(request);
    if (_legacyRecentSessionsRequestQueue.length >
        _maxLegacyRecentSessionsRequestQueue) {
      _legacyRecentSessionsRequestQueue.removeAt(0);
    }
    _sendNextLegacyRecentSessionsRequest();
  }

  void _sendNextLegacyRecentSessionsRequest() {
    if (_legacyRecentSessionsRequestInFlight != null ||
        _legacyRecentSessionsRequestQueue.isEmpty ||
        !isConnected) {
      return;
    }
    final request = _legacyRecentSessionsRequestQueue.removeAt(0);
    _legacyRecentSessionsRequestInFlight = request;
    send(request.toClientMessage());
  }

  RecentSessionsMessage? _correlateRecentSessionsResponse(
    RecentSessionsMessage response,
  ) {
    final inFlight = _legacyRecentSessionsRequestInFlight;
    if (inFlight == null) {
      return response.requestId == null &&
              supportsSessionCatalogRequestCorrelation
          ? null
          : response;
    }

    if (response.requestId != null &&
        response.requestId != inFlight.requestId) {
      return response;
    }
    _legacyRecentSessionsRequestInFlight = null;
    _sendNextLegacyRecentSessionsRequest();
    if (response.requestId != null) return response;
    return inFlight.correlate(response);
  }

  void _resetLegacyRecentSessionsTransport() {
    _legacyRecentSessionsRequestInFlight = null;
    _legacyRecentSessionsRequestQueue.clear();
  }

  bool _isCurrentRecentSessionsResponse(RecentSessionsMessage message) {
    final responseGeneration = message.queryGeneration;
    if (responseGeneration != null &&
        responseGeneration != _recentSessionsQueryGeneration) {
      return false;
    }
    final requestId = message.requestId;
    if (requestId == null) {
      return false;
    }
    final scopeKey = _recentSessionRequestScopeKey(
      message.requestScope ?? 'list',
      message.projectPath,
    );
    return _latestRecentSessionRequestByScope[scopeKey] == requestId;
  }

  static String _recentSessionRequestScopeKey(
    String requestScope,
    String? projectPath,
  ) => '$requestScope\n${projectPath ?? ''}';

  void _handleSessionCatalogChanged(int revision) {
    if (revision <= 0 || revision <= _lastSessionCatalogRevision) return;
    _lastSessionCatalogRevision = revision;
    _scheduleSessionCatalogRefresh();
  }

  void _scheduleSessionCatalogRefresh() {
    if (!supportsSessionCatalogWatch ||
        !isConnected ||
        _desiredClientDeliveryMode != BridgeClientDeliveryMode.interactive) {
      return;
    }
    _sessionCatalogRefreshDirty = true;
    if (_sessionCatalogRefreshInFlight || _sessionCatalogRefreshTimer != null) {
      return;
    }
    _sessionCatalogRefreshTimer = Timer(
      _sessionCatalogRefreshDebounce,
      _requestSessionCatalogRefresh,
    );
  }

  void _requestSessionCatalogRefresh() {
    _sessionCatalogRefreshTimer?.cancel();
    _sessionCatalogRefreshTimer = null;
    if (!isConnected ||
        !supportsSessionCatalogWatch ||
        _desiredClientDeliveryMode != BridgeClientDeliveryMode.interactive) {
      return;
    }
    if (_sessionCatalogRefreshInFlight) {
      _sessionCatalogRefreshDirty = true;
      return;
    }

    _sessionCatalogRefreshDirty = false;
    _sessionCatalogRefreshInFlight = true;
    final limit = max(
      _sessionCatalogRefreshMinLimit,
      min(_recentSessions.length, _sessionCatalogRefreshMaxLimit),
    );
    _sendRecentSessionsRequest(
      limit: limit,
      offset: 0,
      projectPath: _currentProjectFilter,
      requestScope: 'catalog',
      startsNewQuery: false,
    );
    _sessionCatalogRefreshTimeout?.cancel();
    _sessionCatalogRefreshTimeout = Timer(
      _sessionCatalogRefreshRequestTimeout,
      () {
        _sessionCatalogRefreshTimeout = null;
        _sessionCatalogRefreshInFlight = false;
        if (_sessionCatalogRefreshDirty) {
          _scheduleSessionCatalogRefresh();
        }
      },
    );
  }

  void _finishSessionCatalogRefresh() {
    _sessionCatalogRefreshTimeout?.cancel();
    _sessionCatalogRefreshTimeout = null;
    _sessionCatalogRefreshInFlight = false;
    if (!_sessionCatalogRefreshDirty || _sessionCatalogRefreshTimer != null) {
      return;
    }
    _sessionCatalogRefreshTimer = Timer(
      _sessionCatalogRefreshDebounce,
      _requestSessionCatalogRefresh,
    );
  }

  void _resetSessionCatalogRefresh() {
    _sessionCatalogRefreshTimer?.cancel();
    _sessionCatalogRefreshTimeout?.cancel();
    _sessionCatalogRefreshTimer = null;
    _sessionCatalogRefreshTimeout = null;
    _sessionCatalogRefreshInFlight = false;
    _sessionCatalogRefreshDirty = false;
    _lastSessionCatalogRevision = 0;
  }

  @override
  void requestSessionHistory(String sessionId) {
    _pendingForegroundHistorySyncs.add(sessionId);
    _requestSessionHistory(sessionId, allowFullFallback: true);
  }

  /// Requests only the bounded delta path used by iOS background work.
  ///
  /// An older Bridge may reject `get_history_delta`. In that case the request
  /// intentionally ends without falling back to an unbounded full-history
  /// payload; the next foreground reconciliation retains the normal fallback.
  void requestSessionHistoryDeltaOnly(String sessionId) {
    _requestSessionHistory(sessionId, allowFullFallback: false);
  }

  void _requestSessionHistory(
    String sessionId, {
    required bool allowFullFallback,
  }) {
    final snapshot = _runtimeStore.snapshot(sessionId);
    final canRequestDelta =
        snapshot.messages.isNotEmpty ||
        (!allowFullFallback && snapshot.cachedHistorySeq > 0);
    if (canRequestDelta) {
      _pendingHistoryDeltaSinceSeq[sessionId] = snapshot.cachedHistorySeq;
      // The latest caller owns the fallback policy. In particular, a bounded
      // background request must be able to replace a stale foreground
      // permission left behind by a timed-out delta request.
      _pendingHistoryDeltaAllowsFullFallback[sessionId] = allowFullFallback;
      _bumpHistorySyncGeneration(sessionId);
      send(
        ClientMessage.getHistoryDelta(
          sessionId,
          sinceSeq: snapshot.cachedHistorySeq,
        ),
      );
      return;
    }
    if (allowFullFallback) {
      _recordLegacyHistoryRequest(sessionId);
      send(ClientMessage.getHistory(sessionId));
    }
  }

  int _bumpHistorySyncGeneration(String sessionId) {
    return _historySyncGenerations[sessionId] =
        (_historySyncGenerations[sessionId] ?? 0) + 1;
  }

  void _recordLegacyHistoryRequest(String sessionId) {
    final snapshot = _runtimeStore.snapshot(sessionId);
    _pendingLegacyHistoryFences
        .putIfAbsent(sessionId, () => [])
        .add(
          _LegacyHistoryFence(
            generation: _bumpHistorySyncGeneration(sessionId),
            contentEpoch: snapshot.contentEpoch,
            storeWasEmpty: snapshot.messages.isEmpty,
          ),
        );
  }

  /// Generation fence for legacy full-history frames (no seq information).
  ///
  /// Without this, a late `history` frame wholesale-replaced the runtime
  /// store — wiping real-time messages that arrived after the frame's
  /// content basis — and reset the seq watermark to 0, forcing the next
  /// delta request into a full re-pull (messages vanish, then reappear).
  bool _acceptLegacyHistoryFrame(String sessionId) {
    final fences = _pendingLegacyHistoryFences[sessionId];
    _LegacyHistoryFence? fence;
    if (fences != null && fences.isNotEmpty) {
      fence = fences.removeAt(0);
      if (fences.isEmpty) _pendingLegacyHistoryFences.remove(sessionId);
    }
    final snapshot = _runtimeStore.snapshot(sessionId);
    // Hydrating an empty store loses nothing.
    if (snapshot.messages.isEmpty) return true;
    // Unsolicited full frame over live content: never wholesale-replace.
    if (fence == null) return false;
    // A newer sync request owns the session now; this frame is stale.
    if (fence.generation != (_historySyncGenerations[sessionId] ?? 0)) {
      return false;
    }
    if (fence.storeWasEmpty) {
      // Initial load raced by live messages: the frame is still the only
      // backlog source — unless seq-synced content landed meanwhile, which
      // a legacy frame (watermark reset to 0) must not destroy.
      return snapshot.cachedHistorySeq == 0;
    }
    // Resync over existing content is only safe while nothing newer arrived.
    return snapshot.contentEpoch == fence.contentEpoch;
  }

  void refreshBranch(String sessionId) {
    send(ClientMessage.refreshBranch(sessionId));
  }

  void requestMessageImages({
    required String claudeSessionId,
    required String messageUuid,
  }) {
    send(
      ClientMessage.getMessageImages(
        claudeSessionId: claudeSessionId,
        messageUuid: messageUuid,
      ),
    );
  }

  void resumeSession(
    String sessionId,
    String projectPath, {
    String? permissionMode,
    String? executionMode,
    String? approvalPolicy,
    String? approvalsReviewer,
    String? codexPermissionsMode,
    bool? planMode,
    String? effort,
    int? maxTurns,
    double? maxBudgetUsd,
    String? fallbackModel,
    bool? forkSession,
    bool? persistSession,
    String? profile,
    String? provider,
    String? sandboxMode,
    String? model,
    String? modelReasoningEffort,
    String? serviceTier,
    bool? networkAccessEnabled,
    String? webSearchMode,
    List<String>? additionalWritableRoots,
    String? resumeRequestId,
  }) {
    send(
      ClientMessage.resumeSession(
        sessionId,
        projectPath,
        permissionMode: permissionMode,
        executionMode: executionMode,
        approvalPolicy: approvalPolicy,
        approvalsReviewer: approvalsReviewer,
        codexPermissionsMode: codexPermissionsMode,
        planMode: planMode,
        effort: effort,
        maxTurns: maxTurns,
        maxBudgetUsd: maxBudgetUsd,
        fallbackModel: fallbackModel,
        forkSession: forkSession,
        persistSession: persistSession,
        profile: profile,
        provider: provider,
        sandboxMode: sandboxMode,
        model: model,
        modelReasoningEffort: modelReasoningEffort,
        serviceTier: serviceTier,
        networkAccessEnabled: networkAccessEnabled,
        webSearchMode: webSearchMode,
        additionalWritableRoots: additionalWritableRoots,
        resumeRequestId: resumeRequestId,
      ),
    );
  }

  Future<bool> updateOfflinePendingInput({
    required String sessionId,
    required String clientMessageId,
    required String text,
    List<Map<String, String>>? skills,
    List<Map<String, String>>? mentions,
  }) async {
    await _ensureOfflineQueueRestored();
    var updated = false;
    for (var i = 0; i < _messageQueue.length; i++) {
      final json =
          jsonDecode(_messageQueue[i].toJson()) as Map<String, dynamic>;
      if (json['type'] != 'input' ||
          json['sessionId'] != sessionId ||
          json['clientMessageId'] != clientMessageId) {
        continue;
      }
      json['text'] = text;
      if (skills != null && skills.isNotEmpty) {
        json['skills'] = skills;
        json['skill'] = skills.first;
      } else {
        json.remove('skills');
        json.remove('skill');
      }
      if (mentions != null && mentions.isNotEmpty) {
        json['mentions'] = mentions;
      } else {
        json.remove('mentions');
      }
      _messageQueue[i] = ClientMessage.raw(json);
      updated = true;
      break;
    }
    if (!updated) return false;
    _publishOfflinePendingActions();
    await _persistOfflinePendingMessages();
    return true;
  }

  Future<bool> cancelOfflinePendingInput({
    required String sessionId,
    required String clientMessageId,
  }) async {
    await _ensureOfflineQueueRestored();
    final before = _messageQueue.length;
    _messageQueue.removeWhere((message) {
      final json = jsonDecode(message.toJson()) as Map<String, dynamic>;
      return json['type'] == 'input' &&
          json['sessionId'] == sessionId &&
          json['clientMessageId'] == clientMessageId;
    });
    if (before == _messageQueue.length) return false;
    _publishOfflinePendingActions();
    await _persistOfflinePendingMessages();
    return true;
  }

  @override
  void stopSession(String sessionId) {
    send(ClientMessage.stopSession(sessionId));
    clearExplorerHistory(sessionId);
    _sessionStoppedController.add(sessionId);
    clearDiffImageCache();
  }

  ExplorerHistorySnapshot getExplorerHistory(String sessionId) {
    return _runtimeStore.getExplorerHistory(sessionId);
  }

  List<ServerMessage> cachedSessionMessages(String sessionId) {
    return _runtimeStore.messages(sessionId);
  }

  /// Stores list-level Desktop continuity until a conversation screen takes
  /// over the exact watch. Only the list tracker calls this method, so an open
  /// conversation never processes the same live payload through two paths.
  bool recordBackgroundDesktopContinuity(
    CodexDesktopContinuityEventMessage message,
  ) {
    final acceptedPayload = _desktopContinuityBacklog.record(message);
    _patchExternalDesktopTurn(message);
    final payload = message.payload;
    if (!acceptedPayload || payload == null) return false;
    _runtimeStore.applyServerMessage(message.sessionId, payload);
    _patchExternalDesktopPreview(message.sessionId, payload);
    return true;
  }

  DesktopContinuityBacklogSnapshot? takeBackgroundDesktopContinuity(
    String sessionId, {
    String? threadId,
  }) {
    return _desktopContinuityBacklog.take(sessionId, threadId: threadId);
  }

  void clearBackgroundDesktopContinuity(String sessionId) {
    _desktopContinuityBacklog.clearSession(sessionId);
  }

  Set<String> respondedToolUseIds(String sessionId) =>
      Set.unmodifiable(_respondedToolUseIds[sessionId] ?? const {});

  void markToolUseResponded(String sessionId, String toolUseId) {
    final ids = _respondedToolUseIds.putIfAbsent(sessionId, () => <String>{});
    ids.add(toolUseId);
    if (ids.length > 512) ids.remove(ids.first);
  }

  @override
  int cachedSessionHistorySeq(String sessionId) {
    return _runtimeStore.cachedHistorySeq(sessionId);
  }

  int cachedSessionContentEpoch(String sessionId) {
    return _runtimeStore.snapshot(sessionId).contentEpoch;
  }

  void setExplorerHistory(
    String sessionId, {
    required String currentPath,
    required List<String> recentPeekedFiles,
  }) {
    final normalizedPath = currentPath.trim();
    final normalizedFiles = recentPeekedFiles
        .map((file) => file.trim())
        .where((file) => file.isNotEmpty)
        .take(10)
        .toList();
    if (normalizedPath.isEmpty && normalizedFiles.isEmpty) {
      _runtimeStore.setExplorerHistory(
        sessionId,
        currentPath: '',
        recentPeekedFiles: const [],
      );
      return;
    }
    _runtimeStore.setExplorerHistory(
      sessionId,
      currentPath: normalizedPath,
      recentPeekedFiles: normalizedFiles,
    );
  }

  void migrateExplorerHistory(String fromSessionId, String toSessionId) {
    _runtimeStore.migrateSession(fromSessionId, toSessionId);
    _remoteHistoryPageFlights.remove(fromSessionId);
    final remoteHistoryCursor = _remoteHistoryCursors.remove(fromSessionId);
    if (remoteHistoryCursor != null) {
      _remoteHistoryCursors[toSessionId] = remoteHistoryCursor;
    }
    final reconciliationGeneration = _sessionHistoryReconciliationGenerations
        .remove(fromSessionId);
    if (reconciliationGeneration != null) {
      _sessionHistoryReconciliationGenerations[toSessionId] =
          reconciliationGeneration;
    }
    final providerBinding = _providerSessionBindingByRuntime.remove(
      fromSessionId,
    );
    if (providerBinding != null) {
      _providerSessionBindingByRuntime[toSessionId] = providerBinding;
    }
  }

  void clearExplorerHistory(String sessionId) {
    _remoteHistoryPageFlights.remove(sessionId);
    _remoteHistoryCursors.remove(sessionId);
    _pendingHistoryDeltaSinceSeq.remove(sessionId);
    _pendingHistoryDeltaAllowsFullFallback.remove(sessionId);
    _finishSessionHistorySync(sessionId);
    _runtimeStore.clearSession(sessionId);
    _sessionHistoryReconciliationGenerations.remove(sessionId);
    _desktopContinuityBacklog.clearSession(sessionId);
    _providerSessionBindingByRuntime.remove(sessionId);
    _respondedToolUseIds.remove(sessionId);
  }

  void configureSessionHistoryBootstrap(
    SessionHistoryBootstrapHandler? handler,
  ) {
    _sessionHistoryBootstrapHandler = handler;
  }

  bool get hasSessionHistoryBootstrap =>
      _sessionHistoryBootstrapHandler != null;

  void configureSessionHistoryPaging({
    SessionHistoryPageLoader? loader,
    SessionHistoryWindowLoader? windowLoader,
    SessionHistoryHasMore? hasMore,
    SessionHistoryAvailable? available,
    SessionHistoryPageInvalidator? invalidate,
  }) {
    _sessionHistoryPageLoader = loader;
    _sessionHistoryWindowLoader = windowLoader;
    _sessionHistoryHasMore = hasMore;
    _sessionHistoryAvailable = available;
    _sessionHistoryPageInvalidator = invalidate;
  }

  void configureSessionHistoryUserIndex(
    SessionHistoryUserIndexLoader? loader,
  ) {
    _sessionHistoryUserIndexLoader = loader;
  }

  void configureSessionHistoryToolDetails(
    SessionHistoryToolDetailLoader? loader,
  ) {
    _sessionHistoryToolDetailLoader = loader;
  }

  bool get hasSessionHistoryUserIndex =>
      _sessionHistoryUserIndexLoader != null;

  Future<List<LocalSessionUserIndexEntry>?> tryLoadLocalSessionUserIndex({
    required String runtimeSessionId,
  }) {
    final loader = _sessionHistoryUserIndexLoader;
    if (loader == null) return Future.value();
    return loader(runtimeSessionId: runtimeSessionId);
  }

  bool get hasSessionHistoryPaging => _sessionHistoryPageLoader != null;
  bool get hasSessionHistoryWindowLoading =>
      _sessionHistoryWindowLoader != null;

  bool hasLocalSessionHistory(String runtimeSessionId) =>
      _sessionHistoryAvailable?.call(runtimeSessionId) ??
      _sessionHistoryPageLoader != null;

  bool hasOlderLocalSessionHistory(String runtimeSessionId) =>
      _sessionHistoryHasMore?.call(runtimeSessionId) ?? false;

  bool hasRemoteSessionHistoryPaging(String runtimeSessionId) =>
      _bridgeCapabilities.contains(historyPageCapability) &&
      _remoteHistoryCursors.containsKey(runtimeSessionId);

  bool hasOlderRemoteSessionHistory(String runtimeSessionId) =>
      hasRemoteSessionHistoryPaging(runtimeSessionId) &&
      (_remoteHistoryCursors[runtimeSessionId]?.hasMore ?? false);

  void invalidateLocalSessionHistoryPaging(String runtimeSessionId) {
    _sessionHistoryPageInvalidator?.call(runtimeSessionId);
    _remoteHistoryPageFlights.remove(runtimeSessionId);
  }

  /// Notifies an already-open chat that its optional local history index or
  /// paging cursor became available, changed, or was invalidated.
  ///
  /// This stays process-local: older Bridges do not need a protocol change,
  /// and official clients that never configure mirror paging are unaffected.
  void notifySessionHistoryAvailabilityChanged(
    String runtimeSessionId, {
    required bool available,
  }) {
    if (_sessionHistoryAvailabilityController.isClosed) return;
    _sessionHistoryAvailabilityController.add(
      LocalSessionHistoryAvailabilityChange(
        runtimeSessionId: runtimeSessionId,
        available: available,
      ),
    );
  }

  Future<LocalSessionHistoryPage?> tryLoadOlderLocalSessionHistory({
    required String runtimeSessionId,
    int limit = 200,
  }) {
    final loader = _sessionHistoryPageLoader;
    final localAvailable =
        loader != null &&
        (_sessionHistoryAvailable?.call(runtimeSessionId) ?? true);
    if (localAvailable) {
      return loader(
        runtimeSessionId: runtimeSessionId,
        limit: limit.clamp(1, 200),
      );
    }
    return _loadOlderRemoteSessionHistory(runtimeSessionId);
  }

  Future<LocalSessionHistoryPage?> _loadOlderRemoteSessionHistory(
    String runtimeSessionId, {
    Duration timeout = const Duration(seconds: 12),
  }) {
    final existing = _remoteHistoryPageFlights[runtimeSessionId];
    if (existing != null) return existing;
    final cursor = _remoteHistoryCursors[runtimeSessionId];
    if (cursor == null ||
        !cursor.hasMore ||
        !_bridgeCapabilities.contains(historyPageCapability) ||
        !isTransportHealthy) {
      return Future.value(
        cursor == null
            ? null
            : const LocalSessionHistoryPage(messages: [], hasMore: false),
      );
    }
    final flight = _requestRemoteHistoryPage(
      runtimeSessionId,
      cursor,
      timeout: timeout,
    );
    _remoteHistoryPageFlights[runtimeSessionId] = flight;
    return flight.whenComplete(() {
      if (identical(_remoteHistoryPageFlights[runtimeSessionId], flight)) {
        _remoteHistoryPageFlights.remove(runtimeSessionId);
      }
    });
  }

  Future<LocalSessionHistoryPage?> _requestRemoteHistoryPage(
    String runtimeSessionId,
    _RemoteHistoryCursor cursor, {
    required Duration timeout,
  }) async {
    final requestId =
        'history-page-${++_nextRemoteHistoryPageRequestId}-${cursor.beforeSeq}';
    final completer = Completer<HistoryPageMessage>();
    _pendingRemoteHistoryPages[requestId] = completer;
    try {
      sendEphemeralRpc(
        ClientMessage.getHistoryPage(
          requestId: requestId,
          sessionId: runtimeSessionId,
          beforeSeq: cursor.beforeSeq,
          beforeCursor: cursor.beforeCursor,
        ),
      );
      final response = await completer.future.timeout(timeout);
      if (response.error != null) {
        logger.warning(response.error!);
        return null;
      }
      if (!identical(_remoteHistoryCursors[runtimeSessionId], cursor)) {
        return null;
      }
      cursor
        ..beforeSeq = response.nextBeforeSeq
        ..beforeCursor = response.nextBeforeCursor
        ..hasMore = response.hasMore;
      return LocalSessionHistoryPage(
        messages: List.unmodifiable(
          response.entries.map((entry) => entry.message),
        ),
        hasMore: response.hasMore,
      );
    } on TimeoutException catch (error, stackTrace) {
      logger.warning(
        '[history:$runtimeSessionId] Older history page timed out',
        error,
        stackTrace,
      );
      return null;
    } catch (error, stackTrace) {
      logger.warning(
        '[history:$runtimeSessionId] Older history page failed',
        error,
        stackTrace,
      );
      return null;
    } finally {
      _pendingRemoteHistoryPages.remove(requestId);
    }
  }

  Future<List<HistoryToolDetail>?> requestHistoryToolDetails({
    required String runtimeSessionId,
    required List<String> toolUseIds,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final normalizedIds = toolUseIds
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty && value.length <= 256)
        .toSet()
        .take(8)
        .toList(growable: false);
    if (normalizedIds.isEmpty) return null;

    final localById = <String, HistoryToolDetail>{};
    final localLoader = _sessionHistoryToolDetailLoader;
    if (localLoader != null) {
      try {
        final local = await localLoader(
          runtimeSessionId: runtimeSessionId,
          toolUseIds: normalizedIds,
        );
        for (final detail in local ?? const <HistoryToolDetail>[]) {
          if (normalizedIds.contains(detail.toolUseId)) {
            localById[detail.toolUseId] = detail;
          }
        }
      } catch (error, stackTrace) {
        logger.warning(
          '[history:$runtimeSessionId] Local tool detail lookup failed',
          error,
          stackTrace,
        );
      }
    }
    final missingIds = normalizedIds
        .where((toolUseId) => !localById.containsKey(toolUseId))
        .toList(growable: false);
    List<HistoryToolDetail> orderedDetails(
      Map<String, HistoryToolDetail> details,
    ) => [
      for (final toolUseId in normalizedIds) ?details[toolUseId],
    ];
    if (missingIds.isEmpty) {
      return List.unmodifiable(orderedDetails(localById));
    }
    if (!_bridgeCapabilities.contains(historyToolDetailCapability) ||
        !isTransportHealthy) {
      return localById.isEmpty
          ? null
          : List.unmodifiable(orderedDetails(localById));
    }
    final epoch = _connectionEpoch;
    final logicalIdentity = _logicalConnectionIdentity;
    final requestId = 'history-tools-${++_nextHistoryToolDetailRequestId}';
    final completer = Completer<HistoryToolDetailsMessage>();
    _pendingHistoryToolDetails[requestId] = completer;
    try {
      sendEphemeralRpc(
        ClientMessage.getHistoryToolDetails(
          requestId: requestId,
          sessionId: runtimeSessionId,
          toolUseIds: missingIds,
        ),
      );
      final response = await completer.future.timeout(timeout);
      if (epoch != _connectionEpoch ||
          logicalIdentity != _logicalConnectionIdentity ||
          response.sessionId != runtimeSessionId) {
        return null;
      }
      if (response.error != null) {
        logger.warning(response.error!);
        return localById.isEmpty
            ? null
            : List.unmodifiable(orderedDetails(localById));
      }
      for (final detail in response.details) {
        if (missingIds.contains(detail.toolUseId)) {
          localById[detail.toolUseId] = detail;
        }
      }
      return List.unmodifiable(orderedDetails(localById));
    } on TimeoutException catch (error, stackTrace) {
      logger.warning(
        '[history:$runtimeSessionId] Tool detail request timed out',
        error,
        stackTrace,
      );
      return localById.isEmpty
          ? null
          : List.unmodifiable(orderedDetails(localById));
    } catch (error, stackTrace) {
      logger.warning(
        '[history:$runtimeSessionId] Tool detail request failed',
        error,
        stackTrace,
      );
      return localById.isEmpty
          ? null
          : List.unmodifiable(orderedDetails(localById));
    } finally {
      _pendingHistoryToolDetails.remove(requestId);
    }
  }

  Future<LocalSessionHistoryPage?> tryLoadLocalSessionHistoryWindow({
    required String runtimeSessionId,
    required int startOrdinal,
    int limit = 200,
  }) {
    final loader = _sessionHistoryWindowLoader;
    if (loader == null) return Future.value();
    return loader(
      runtimeSessionId: runtimeSessionId,
      startOrdinal: startOrdinal,
      limit: limit.clamp(1, 200),
    );
  }

  String? providerSessionIdForRuntime(
    String runtimeSessionId, {
    String? provider,
  }) {
    final remembered = _providerSessionBindingByRuntime[runtimeSessionId];
    if (remembered != null &&
        (provider == null || remembered.provider == provider)) {
      return remembered.providerSessionId;
    }
    final index = _sessions.indexWhere(
      (session) =>
          session.id == runtimeSessionId &&
          (provider == null || session.provider == provider),
    );
    return index < 0 ? null : _sessions[index].claudeSessionId;
  }

  List<String> runtimeSessionIdsForProviderSession(
    String provider,
    String providerSessionId,
  ) {
    final ids = <String>{
      for (final entry in _providerSessionBindingByRuntime.entries)
        if (entry.value.provider == provider &&
            entry.value.providerSessionId == providerSessionId)
          entry.key,
      for (final session in _sessions)
        if (session.provider == provider &&
            session.claudeSessionId == providerSessionId)
          session.id,
    };
    return List.unmodifiable(ids);
  }

  Future<bool> tryBootstrapSessionHistory({
    required String runtimeSessionId,
    required String? provider,
    required String? projectPath,
    bool force = false,
  }) async {
    final handler = _sessionHistoryBootstrapHandler;
    if (handler == null) return false;
    return handler(
      runtimeSessionId: runtimeSessionId,
      provider: provider,
      providerSessionId: providerSessionIdForRuntime(
        runtimeSessionId,
        provider: provider,
      ),
      projectPath: projectPath,
      force: force,
    );
  }

  /// Publishes a reconstructable external snapshot through the existing chat
  /// pipeline without assigning Bridge runtime history sequence semantics.
  void publishExternalSessionHistory(
    String runtimeSessionId,
    List<ServerMessage> messages, {
    DateTime? timestampAnchor,
  }) {
    final history = buildExternalSessionHistory(
      messages,
      timestampAnchor: timestampAnchor,
    );
    // A mirror revision is not a Bridge history sequence. Keep this snapshot
    // transient so it cannot reset or falsely advance the canonical runtime
    // cursor used by history_delta/history_snapshot reconciliation.
    _taggedMessageController.add((history, runtimeSessionId));
    _messageController.add(history);
  }

  HistoryMessage buildExternalSessionHistory(
    List<ServerMessage> messages, {
    DateTime? timestampAnchor,
  }) {
    final history = HistoryMessage(messages: List.unmodifiable(messages));
    _externalSessionHistories[history] = _ExternalSessionHistoryMetadata(
      timestampAnchor: timestampAnchor,
    );
    return history;
  }

  bool isExternalSessionHistory(HistoryMessage message) =>
      _externalSessionHistories[message] != null;

  DateTime? externalSessionHistoryTimestampAnchor(HistoryMessage message) =>
      _externalSessionHistories[message]?.timestampAnchor;

  void _rememberProviderSessionBinding(
    String runtimeSessionId,
    String? provider,
    String? providerSessionId,
  ) {
    if (provider == null ||
        provider.trim().isEmpty ||
        providerSessionId == null ||
        providerSessionId.trim().isEmpty) {
      return;
    }
    _providerSessionBindingByRuntime[runtimeSessionId] = (
      provider: provider,
      providerSessionId: providerSessionId,
    );
  }

  /// Rename a session. For running sessions, [sessionId] is the bridge id.
  /// For recent sessions, include [provider], [providerSessionId], and [projectPath].
  void renameSession({
    required String sessionId,
    String? name,
    String? provider,
    String? providerSessionId,
    String? projectPath,
  }) {
    send(
      ClientMessage.renameSession(
        sessionId: sessionId,
        name: name,
        provider: provider,
        providerSessionId: providerSessionId,
        projectPath: projectPath,
      ),
    );
  }

  void archiveSession({
    required String sessionId,
    required String provider,
    required String projectPath,
    String? requestId,
    String? name,
    String? summary,
    String? firstPrompt,
    String? modified,
  }) {
    send(
      ClientMessage.archiveSession(
        sessionId: sessionId,
        provider: provider,
        projectPath: projectPath,
        requestId: requestId,
        name: name,
        summary: summary,
        firstPrompt: firstPrompt,
        modified: modified,
      ),
    );
  }

  void requestProjectHistory() {
    send(ClientMessage.listProjectHistory());
  }

  void requestDebugBundle(
    String sessionId, {
    int? traceLimit,
    bool includeDiff = true,
  }) {
    send(
      ClientMessage.getDebugBundle(
        sessionId,
        traceLimit: traceLimit,
        includeDiff: includeDiff,
      ),
    );
  }

  void requestUsage() {
    send(ClientMessage.getUsage());
  }

  void requestPromptHistorySync({
    required String clientId,
    String? clientName,
    int? sinceRevision,
  }) {
    send(
      ClientMessage.syncPromptHistory(
        clientId: clientId,
        clientName: clientName,
        sinceRevision: sinceRevision,
      ),
    );
  }

  void removeProjectHistory(String path) {
    send(ClientMessage.removeProjectHistory(path));
  }

  void requestWorktreeList(String projectPath) {
    send(ClientMessage.listWorktrees(projectPath));
  }

  void removeWorktree(String projectPath, String worktreePath) {
    send(ClientMessage.removeWorktree(projectPath, worktreePath));
  }

  void requestGallery({String? project, String? sessionId}) {
    send(ClientMessage.listGallery(project: project, sessionId: sessionId));
  }

  void requestWindowList() {
    send(ClientMessage.listWindows());
  }

  void takeScreenshot({
    required String mode,
    int? windowId,
    required String projectPath,
    String? sessionId,
  }) {
    send(
      ClientMessage.takeScreenshot(
        mode: mode,
        windowId: windowId,
        projectPath: projectPath,
        sessionId: sessionId,
      ),
    );
  }

  @override
  void requestFileList(String projectPath) {
    send(ClientMessage.listFiles(projectPath));
  }

  @override
  void interrupt(String sessionId) {
    send(ClientMessage.interrupt(sessionId: sessionId));
  }

  String registerPushToken({
    required String token,
    required String platform,
    String? locale,
    bool? privacyMode,
    List<String>? enabledEventTypes,
    bool? approvalActionsSupported,
  }) {
    final requestId = 'push-register-${++_pushRegistrationRequestSequence}';
    send(
      ClientMessage.pushRegister(
        token: token,
        platform: platform,
        requestId: requestId,
        locale: locale,
        privacyMode: privacyMode,
        enabledEventTypes: enabledEventTypes,
        approvalActionsSupported: approvalActionsSupported,
      ),
    );
    return requestId;
  }

  String unregisterPushToken(String token) {
    final requestId = 'push-unregister-${++_pushRegistrationRequestSequence}';
    send(ClientMessage.pushUnregister(token, requestId: requestId));
    return requestId;
  }

  /// Update the cached [_sessions] list when a [StatusMessage] arrives,
  /// so the session list screen reflects the change in real-time.
  void _patchSessionStatus(
    String sessionId,
    ProcessStatus status, {
    String? activityAt,
  }) {
    final statusStr = switch (status) {
      ProcessStatus.starting => 'starting',
      ProcessStatus.idle => 'idle',
      ProcessStatus.running => 'running',
      ProcessStatus.waitingApproval => 'waiting_approval',
      ProcessStatus.compacting => 'compacting',
    };
    final idx = _sessions.indexWhere((s) => s.id == sessionId);
    if (idx < 0) return;
    final current = _sessions[idx];
    final nextActivityAt = _newerSessionActivity(
      current.lastActivityAt,
      activityAt,
    );
    if (current.status == statusStr &&
        current.pendingPermission == null &&
        nextActivityAt == null) {
      return;
    }
    // Clear pendingPermission when status moves away from waiting_approval
    final shouldClear =
        statusStr != 'waiting_approval' && current.pendingPermission != null;
    _sessions = List.of(_sessions)
      ..[idx] = current.copyWith(
        status: statusStr,
        lastActivityAt: nextActivityAt,
        clearPermission: shouldClear,
      );
    _sessionListController.add(_sessions);
  }

  void _patchSessionActivity(String sessionId, String? activityAt) {
    final idx = _sessions.indexWhere((session) => session.id == sessionId);
    if (idx < 0) return;
    final current = _sessions[idx];
    final nextActivityAt = _newerSessionActivity(
      current.lastActivityAt,
      activityAt,
    );
    if (nextActivityAt == null) return;
    _sessions = List.of(_sessions)
      ..[idx] = current.copyWith(lastActivityAt: nextActivityAt);
    _sessionListController.add(_sessions);
  }

  String? _newerSessionActivity(String current, String? candidate) {
    final next = DateTime.tryParse(candidate ?? '');
    if (next == null) return null;
    final previous = DateTime.tryParse(current);
    if (previous != null &&
        next.difference(previous).inMilliseconds < 1000) {
      return null;
    }
    return next.toUtc().toIso8601String();
  }

  void _patchExternalDesktopTurn(CodexDesktopContinuityEventMessage message) {
    _patchSessionActivity(message.sessionId, message.timestamp);
    final active = switch (message.event) {
      CodexDesktopContinuityEventKind.watching ||
      CodexDesktopContinuityEventKind.state =>
        message.state == CodexDesktopContinuityState.running,
      CodexDesktopContinuityEventKind.unwatched ||
      CodexDesktopContinuityEventKind.error => false,
      _ => null,
    };
    if (active == null) return;
    final idx = _sessions.indexWhere(
      (session) => session.id == message.sessionId,
    );
    if (idx < 0) return;
    final current = _sessions[idx];
    if (current.externalDesktopTurnActive == active) return;
    _sessions = List.of(_sessions)
      ..[idx] = current.copyWith(externalDesktopTurnActive: active);
    _sessionListController.add(_sessions);
  }

  void _patchExternalDesktopPreview(String sessionId, ServerMessage payload) {
    if (payload is! AssistantServerMessage) return;
    final text = payload.message.content
        .whereType<TextContent>()
        .map((content) => content.text.trim())
        .where((content) => content.isNotEmpty)
        .join('\n')
        .trim();
    if (text.isEmpty) return;
    final runes = text.runes.toList(growable: false);
    final preview = runes.length <= 500
        ? text
        : String.fromCharCodes(runes.skip(runes.length - 500));
    final idx = _sessions.indexWhere((session) => session.id == sessionId);
    if (idx < 0 || _sessions[idx].lastMessage == preview) return;
    _sessions = List.of(_sessions)
      ..[idx] = _sessions[idx].copyWith(lastMessage: preview);
    _sessionListController.add(_sessions);
  }

  /// Attach a [PermissionRequestMessage] to the cached session for real-time
  /// display. The server also includes this in session_list responses, but
  /// this method provides instant UI feedback without waiting for the next
  /// session_list refresh.
  void _patchSessionPermission(
    String sessionId,
    PermissionRequestMessage permission,
  ) {
    final idx = _sessions.indexWhere((s) => s.id == sessionId);
    if (idx < 0) return;
    _sessions = List.of(_sessions)
      ..[idx] = _sessions[idx].copyWith(pendingPermission: permission);
    _sessionListController.add(_sessions);
  }

  void _patchSessionPermissionMode(
    String sessionId,
    String permissionMode, {
    String? provider,
    String? executionMode,
    bool? planMode,
    String? approvalPolicy,
    String? approvalsReviewer,
    String? codexPermissionsMode,
  }) {
    final idx = _sessions.indexWhere((s) => s.id == sessionId);
    if (idx < 0) return;
    final current = _sessions[idx];
    _patchSessionModes(
      sessionId,
      permissionMode: permissionMode,
      executionMode:
          executionModeFromRaw(executionMode)?.value ??
          deriveExecutionMode(
            provider: provider ?? current.provider,
            executionMode: executionMode,
            permissionMode: permissionMode,
            approvalPolicy: approvalPolicy ?? current.codexApprovalPolicy,
          ).value,
      planMode:
          planMode ??
          derivePlanMode(planMode: planMode, permissionMode: permissionMode),
      approvalPolicy: approvalPolicy,
      approvalsReviewer: approvalsReviewer,
      codexPermissionsMode: codexPermissionsMode,
    );
  }

  void patchSessionModes(
    String sessionId, {
    required String permissionMode,
    required String executionMode,
    required bool planMode,
    String? approvalPolicy,
    String? approvalsReviewer,
    String? codexPermissionsMode,
  }) {
    _patchSessionModes(
      sessionId,
      permissionMode: permissionMode,
      executionMode: executionMode,
      planMode: planMode,
      approvalPolicy: approvalPolicy,
      approvalsReviewer: approvalsReviewer,
      codexPermissionsMode: codexPermissionsMode,
    );
  }

  void _patchSessionModes(
    String sessionId, {
    required String permissionMode,
    required String executionMode,
    required bool planMode,
    String? approvalPolicy,
    String? approvalsReviewer,
    String? codexPermissionsMode,
  }) {
    final idx = _sessions.indexWhere((s) => s.id == sessionId);
    if (idx < 0) return;
    final current = _sessions[idx];
    if (current.permissionMode == permissionMode &&
        current.executionMode == executionMode &&
        current.planMode == planMode &&
        (codexPermissionsMode == null ||
            current.codexPermissionsMode == codexPermissionsMode) &&
        (approvalsReviewer == null ||
            current.codexApprovalsReviewer == approvalsReviewer)) {
      return;
    }
    _sessions = List.of(_sessions)
      ..[idx] = current.copyWith(
        permissionMode: permissionMode,
        executionMode: executionMode,
        planMode: planMode,
        codexApprovalPolicy: approvalPolicy ?? current.codexApprovalPolicy,
        codexApprovalsReviewer:
            approvalsReviewer ?? current.codexApprovalsReviewer,
        codexPermissionsMode:
            codexPermissionsMode ?? current.codexPermissionsMode,
      );
    _sessionListController.add(_sessions);
  }

  void _patchSessionSystemSettings(String sessionId, SystemMessage message) {
    final idx = _sessions.indexWhere((s) => s.id == sessionId);
    if (idx < 0) return;
    final current = _sessions[idx];
    final codexModel = sanitizeCodexModelName(message.model);
    _sessions = List.of(_sessions)
      ..[idx] = current.copyWith(
        permissionMode: message.permissionMode ?? current.permissionMode,
        executionMode: message.executionMode ?? current.executionMode,
        planMode: message.planMode ?? current.planMode,
        model: message.provider == Provider.claude.value ? message.model : null,
        codexApprovalPolicy: resolveCodexApprovalPolicy(
          approvalPolicy: message.approvalPolicy ?? current.codexApprovalPolicy,
          executionMode: message.executionMode ?? current.executionMode,
        ),
        codexApprovalsReviewer:
            message.approvalsReviewer ?? current.codexApprovalsReviewer,
        codexPermissionsMode:
            message.codexPermissionsMode ?? current.codexPermissionsMode,
        codexSandboxMode: message.provider == Provider.codex.value
            ? (message.sandboxMode ?? current.codexSandboxMode)
            : current.codexSandboxMode,
        codexModel: message.provider == Provider.codex.value
            ? (codexModel ?? current.codexModel)
            : current.codexModel,
        codexModelReasoningEffort:
            message.modelReasoningEffort ?? current.codexModelReasoningEffort,
        codexServiceTier:
            message.serviceTier ?? current.codexServiceTier,
        codexNetworkAccessEnabled:
            message.networkAccessEnabled ?? current.codexNetworkAccessEnabled,
        codexWebSearchMode: message.webSearchMode ?? current.codexWebSearchMode,
      );
    _sessionListController.add(_sessions);
  }

  /// Update the cached lastMessage when an [AssistantMessage] arrives so the
  /// session list card shows the latest response in real-time.
  void _patchSessionLastMessage(String sessionId, AssistantMessage message) {
    final idx = _sessions.indexWhere((s) => s.id == sessionId);
    if (idx < 0) return;
    final current = _sessions[idx];
    final messageModel = sanitizeCodexModelName(message.model) ?? '';
    final text = message.content
        .map(_assistantContentPreviewText)
        .where((text) => text.isNotEmpty)
        .join(' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final shouldPatchModel =
        current.provider == Provider.codex.value &&
        messageModel.isNotEmpty &&
        messageModel != current.codexModel;
    if (text.isEmpty && !shouldPatchModel) return;
    final preview = text.length > 100 ? text.substring(0, 100) : text;
    _sessions = List.of(_sessions)
      ..[idx] = current.copyWith(
        lastMessage: text.isNotEmpty ? preview : null,
        codexModel: shouldPatchModel ? messageModel : null,
      );
    _sessionListController.add(_sessions);
  }

  String _assistantContentPreviewText(AssistantContent content) {
    return switch (content) {
      TextContent(:final text) => text,
      ToolUseContent(:final name, :final input)
          when isCodexUpdatePlanTool(name) =>
        codexPlanUpdateTextFromInput(input) ?? '',
      _ => '',
    };
  }

  /// Clear pending permission from a cached session after the user has
  /// acted on it (approve/reject/answer). Provides instant UI feedback
  /// without waiting for the server status change.
  void clearSessionPermission(String sessionId) {
    final idx = _sessions.indexWhere((s) => s.id == sessionId);
    if (idx < 0) return;
    _sessions = List.of(_sessions)
      ..[idx] = _sessions[idx].copyWith(clearPermission: true);
    _sessionListController.add(_sessions);
  }

  void patchSessionCodexModel(
    String sessionId,
    String model, {
    String? modelReasoningEffort,
  }) {
    final idx = _sessions.indexWhere((s) => s.id == sessionId);
    if (idx < 0) return;
    final current = _sessions[idx];
    if (current.codexModel == model &&
        (modelReasoningEffort == null ||
            current.codexModelReasoningEffort == modelReasoningEffort)) {
      return;
    }
    _sessions = List.of(_sessions)
      ..[idx] = current.copyWith(
        codexModel: model,
        codexModelReasoningEffort:
            modelReasoningEffort ?? current.codexModelReasoningEffort,
      );
    _sessionListController.add(_sessions);
  }

  void patchSessionCodexSpeed(String sessionId, String serviceTier) {
    final idx = _sessions.indexWhere((s) => s.id == sessionId);
    if (idx < 0) return;
    final current = _sessions[idx];
    if (current.codexServiceTier == serviceTier) return;
    _sessions = List.of(_sessions)
      ..[idx] = current.copyWith(codexServiceTier: serviceTier);
    _sessionListController.add(_sessions);
  }

  void _patchSessionQueuedInput(String sessionId, QueuedInputItem? item) {
    final idx = _sessions.indexWhere((s) => s.id == sessionId);
    if (idx < 0) return;
    _sessions = List.of(_sessions)
      ..[idx] = _sessions[idx].copyWith(
        queuedInput: item,
        clearQueuedInput: item == null,
      );
    _sessionListController.add(_sessions);
  }

  List<SessionInfo> _applyLocalDeliveryPendingInputs(
    List<SessionInfo> sessions,
  ) {
    return sessions.map((session) {
      final pending = deliveryPendingInputForSession(session.id);
      if (pending == null) return session;
      return session.copyWith(queuedInput: pending);
    }).toList();
  }

  List<RecentSession> _mergeRecentSessions(
    List<RecentSession> current,
    List<RecentSession> incoming,
  ) {
    if (current.isEmpty) return incoming;
    if (incoming.isEmpty) return current;
    final merged = List<RecentSession>.of(current);
    final indices = <String, int>{
      for (var index = 0; index < merged.length; index++)
        _recentSessionIdentity(merged[index]): index,
    };
    for (final session in incoming) {
      final key = _recentSessionIdentity(session);
      final existingIndex = indices[key];
      if (existingIndex == null) {
        indices[key] = merged.length;
        merged.add(session);
      } else {
        merged[existingIndex] = session;
      }
    }
    return merged;
  }

  List<RecentSession> _replaceRecentSessionsCatalogPrefix(
    List<RecentSession> current,
    List<RecentSession> incoming,
    int requestedLimit,
  ) {
    final prefixLength = min(current.length, max(0, requestedLimit));
    if (prefixLength >= current.length) return incoming;
    final incomingKeys = incoming.map(_recentSessionIdentity).toSet();
    final tail = current
        .skip(prefixLength)
        .where(
          (session) => !incomingKeys.contains(_recentSessionIdentity(session)),
        );
    return [...incoming, ...tail];
  }

  String _recentSessionIdentity(RecentSession session) =>
      '${session.provider ?? Provider.claude.value}\u0000${session.sessionId}';

  void patchSessionPermissionMode(String sessionId, String permissionMode) {
    _patchSessionPermissionMode(sessionId, permissionMode);
  }

  void patchSessionSandboxMode(String sessionId, String sandboxMode) {
    final idx = _sessions.indexWhere((s) => s.id == sessionId);
    if (idx < 0) return;
    final current = _sessions[idx];
    if (current.codexSandboxMode == sandboxMode) return;
    _sessions = List.of(_sessions)
      ..[idx] = current.copyWith(codexSandboxMode: sandboxMode);
    _sessionListController.add(_sessions);
  }

  ServerMessage _withEffectiveGoalSessionId(
    ServerMessage message,
    String sessionId,
  ) => switch (message) {
    ErrorMessage(
      message: final errorMessage,
      :final errorCode,
      :final permissionChangeId,
      :final goalChangeId,
    ) =>
      ErrorMessage(
        message: errorMessage,
        errorCode: errorCode,
        sessionId: sessionId,
        permissionChangeId: permissionChangeId,
        goalChangeId: goalChangeId,
      ),
    GoalStateMessage(
      :final goal,
      :final goalChangeId,
      :final goalOperationSequence,
    ) =>
      GoalStateMessage(
        sessionId: sessionId,
        goal: goal,
        goalChangeId: goalChangeId,
        goalOperationSequence: goalOperationSequence,
      ),
    _ => message,
  };

  bool _isUnscopedGoalProtocolError(ErrorMessage error) {
    final code = error.errorCode;
    if (error.goalChangeId?.isNotEmpty == true) return true;
    if (code?.startsWith('goal_') == true) return true;
    return code == 'unsupported_message' &&
        const {'get_goal', 'set_goal', 'clear_goal'}.contains(error.message);
  }

  @override
  Stream<ServerMessage> messagesForSession(String sessionId) {
    return _taggedMessageController.stream
        .where((pair) => pair.$2 == null || pair.$2 == sessionId)
        .map((pair) => pair.$1);
  }

  @override
  Stream<LocalFeatureServerMessage> localFeatureMessagesForSession(
    String sessionId,
  ) {
    return _localFeatureMessageController.stream
        .where((pair) => pair.$2 == sessionId)
        .map((pair) => pair.$1);
  }

  /// Try to auto-connect using saved preferences.
  ///
  /// [apiKey] should be provided from [FlutterSecureStorage] via
  /// [MachineManagerService]. Falls back to legacy [SharedPreferences]
  /// for migration.
  Future<bool> autoConnect({
    String? apiKey,
    String? logicalConnectionIdentity,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString(_prefKeyUrl);
    if (url == null || url.isEmpty) return false;

    // Prefer caller-provided apiKey (from SecureStorage), fall back to
    // legacy SharedPreferences value for backward compatibility.
    final effectiveApiKey = apiKey ?? prefs.getString(_prefKeyApiKey);

    var connectUrl = url;
    if (effectiveApiKey != null && effectiveApiKey.isNotEmpty) {
      final sep = connectUrl.contains('?') ? '&' : '?';
      connectUrl = '$connectUrl${sep}token=$effectiveApiKey';
    }

    // Migrate: remove legacy plaintext API key from SharedPreferences.
    if (prefs.containsKey(_prefKeyApiKey)) {
      await prefs.remove(_prefKeyApiKey);
    }

    connect(
      connectUrl,
      logicalConnectionIdentity: logicalConnectionIdentity,
    );
    return true;
  }

  /// Save connection URL to preferences.
  ///
  /// API keys are stored separately via [FlutterSecureStorage] in
  /// [MachineManagerService], not in [SharedPreferences].
  Future<void> savePreferences(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKeyUrl, url);
    // API key is no longer stored in SharedPreferences (plaintext).
    // It is managed by MachineManagerService via FlutterSecureStorage.
    // Clean up any legacy value.
    if (prefs.containsKey(_prefKeyApiKey)) {
      await prefs.remove(_prefKeyApiKey);
    }
  }

  /// Check if the Bridge server is reachable via /health endpoint.
  /// Returns the health JSON on success, null on failure.
  static Future<Map<String, dynamic>?> checkHealth(String wsUrl) async {
    try {
      final uri = Uri.tryParse(wsUrl);
      if (uri == null) return null;
      final scheme = uri.scheme == 'wss' ? 'https' : 'http';
      final healthUrl =
          '${formatUriOrigin(scheme: scheme, host: uri.host, port: uri.hasPort ? uri.port : null)}/health';
      final response = await http
          .get(Uri.parse(healthUrl))
          .timeout(const Duration(seconds: 3));
      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Upload an image to the gallery from base64 data.
  /// Returns the GalleryImage on success, null on failure.
  Future<GalleryImage?> uploadImageBase64({
    required String base64Data,
    required String mimeType,
    required String projectPath,
    String? sessionId,
  }) async {
    final baseUrl = httpBaseUrl;
    if (baseUrl == null) return null;

    try {
      final response = await http
          .post(
            Uri.parse('$baseUrl/api/gallery/upload'),
            headers: {
              'Content-Type': 'application/json',
              ...bridgePrivateHttpHeaders(_lastUrl),
            },
            body: jsonEncode({
              'base64': base64Data,
              'mimeType': mimeType,
              'projectPath': projectPath,
              'sessionId': ?sessionId,
            }),
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 201) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final imageJson = json['image'] as Map<String, dynamic>;
        return GalleryImage.fromJson(imageJson);
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  /// Delete a gallery image by ID.
  /// Returns true on success, false on failure.
  /// On success, immediately removes the image from the local cache
  /// and pushes the updated list to [galleryStream].
  Future<bool> deleteGalleryImage(String id) async {
    final baseUrl = httpBaseUrl;
    if (baseUrl == null) return false;

    try {
      final response = await http
          .delete(
            Uri.parse('$baseUrl/api/gallery/$id'),
            headers: bridgePrivateHttpHeaders(_lastUrl),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        _galleryImages = _galleryImages.where((img) => img.id != id).toList();
        _galleryController.add(_galleryImages);
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Verify WebSocket health and reconnect if the connection is stale.
  ///
  /// Call this when the app returns to foreground — iOS may silently kill
  /// background WebSocket connections without triggering [onDone]/[onError].
  void ensureConnected() {
    if (_lastUrl == null) return;
    if (_connectionState == BridgeConnectionState.connected) {
      // The channel may appear "connected" but the underlying socket is dead.
      // A non-null closeCode means the socket has already been closed.
      if (_channel?.closeCode != null) {
        _scheduleReconnect();
      }
    } else if (_connectionState == BridgeConnectionState.disconnected) {
      connect(
        _lastUrl!,
        logicalConnectionIdentity: _logicalConnectionIdentity,
      );
    }
    // If reconnecting, do nothing — already in progress.
  }

  void disconnect() {
    _failPendingPermissionChanges(
      'Bridge disconnected before the permission change was confirmed.',
    );
    _connectionEpoch++;
    _intentionalDisconnect = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _channelSub?.cancel();
    _channelSub = null;
    _channel?.sink.close();
    _channel = null;
    _setBridgeConnectionState(BridgeConnectionState.disconnected);
    _clearBridgeScopedState(clearOfflineQueue: true);
    final disconnectCallback = onDisconnect;
    if (disconnectCallback != null) {
      unawaited(Future<void>.sync(disconnectCallback));
    }
  }

  // ---------------------------------------------------------------------------
  // Diff image cache
  // ---------------------------------------------------------------------------

  static String _diffImageCacheKey(String projectPath, String filePath) =>
      '$projectPath\n$filePath';

  /// Retrieve cached image bytes for a diff file.
  DiffImageCacheEntry? getDiffImageCache(String projectPath, String filePath) =>
      _diffImageCache[_diffImageCacheKey(projectPath, filePath)];

  /// Store image bytes in the diff cache.
  void setDiffImageCache(
    String projectPath,
    String filePath,
    DiffImageCacheEntry entry,
  ) {
    _diffImageCache[_diffImageCacheKey(projectPath, filePath)] = entry;
  }

  /// Clear all cached diff images.
  void clearDiffImageCache() => _diffImageCache.clear();

  void dispose() {
    _intentionalDisconnect = true;
    _resetSessionCatalogRefresh();
    _failPendingHistoryRequests(clearCursors: true);
    _clearSessionHistorySyncTracking();
    _completePendingSessionLinkResolutionsAsUnsupported();
    _reconnectTimer?.cancel();
    _cancelPendingPermissionChanges();
    _clearPendingLocalFeatureRequests();
    _goalRequestRouter.clear();
    _failPendingDeliveryModeRequests(resetDesiredMode: true);
    _permissionRequestObservers.clear();
    for (final timer in _inFlightPendingVisibilityTimers.values) {
      timer.cancel();
    }
    _inFlightPendingVisibilityTimers.clear();
    for (final timer in _deliveryPendingVisibilityTimers.values) {
      timer.cancel();
    }
    _deliveryPendingVisibilityTimers.clear();
    _deliveryPendingInputs.clear();
    _inFlightInputMessages.clear();
    _failPendingArtifactResolutions(
      const ArtifactResolveException(
        code: 'bridge_disposed',
        message: 'Bridge connection was closed.',
      ),
    );
    _channelSub?.cancel();
    _channelSub = null;
    _channel?.sink.close();
    _channel = null;
    _messageController.close();
    _taggedMessageController.close();
    _localFeatureMessageController.close();
    _connectionController.close();
    _clientDeliveryModeStateController.close();
    _backgroundNotificationController.close();
    _backgroundActivityStateController.close();
    _pushRegistrationStateController.close();
    _sessionListController.close();
    _sessionHistoryAvailabilityController.close();
    _sessionHistoryReconciledController.close();
    _sessionHistorySyncChangedController.close();
    _codexModelCatalogController.close();
    _sessionStoppedController.close();
    _recentSessionsController.close();
    _recentSessionResponsesController.close();
    _galleryController.close();
    _fileListController.close();
    _fileListMessageController.close();
    _projectHistoryController.close();
    _codexAutoReviewPolicyController.close();
    _diffResultController.close();
    _diffImageResultController.close();
    _worktreeListController.close();
    _windowListController.close();
    _screenshotResultController.close();
    _offlinePendingActionsController.close();
    _debugBundleController.close();
    _usageController.close();
    _backupResultController.close();
    _restoreResultController.close();
    _backupInfoController.close();
    _promptHistorySyncController.close();
    _promptHistoryMutationController.close();
    _promptHistoryStatusController.close();
    // Git Operations
    _gitStageResultController.close();
    _gitUnstageResultController.close();
    _gitUnstageHunksResultController.close();
    _gitCommitResultController.close();
    _gitPushResultController.close();
    _gitBranchesResultController.close();
    _gitCreateBranchResultController.close();
    _gitCheckoutBranchResultController.close();
    _gitRevertFileResultController.close();
    _gitRevertHunksResultController.close();
    _gitFetchResultController.close();
    _gitPullResultController.close();
    _gitStatusResultController.close();
    _gitRemoteStatusResultController.close();
    clearDiffImageCache();
  }
}

class _PendingFileRead {
  const _PendingFileRead({
    required this.requestType,
    required this.completer,
  });

  final String requestType;
  final Completer<FileContentMessage> completer;
}

class _PendingLocalFeatureRequest {
  const _PendingLocalFeatureRequest({
    required this.descriptor,
    required this.epoch,
    required this.expiresAt,
  });

  final LocalFeatureRequestDescriptor descriptor;
  final int epoch;
  final DateTime expiresAt;
}

class _PendingPermissionChange {
  const _PendingPermissionChange({
    required this.sessionId,
    required this.permissionChangeId,
    required this.timer,
  });

  final String sessionId;
  final String permissionChangeId;
  final Timer timer;
}

class _RecentSessionsRequest {
  const _RecentSessionsRequest({
    required this.limit,
    required this.offset,
    required this.projectPath,
    required this.requestScope,
    required this.requestId,
    required this.queryGeneration,
    required this.provider,
    required this.namedOnly,
    required this.searchQuery,
  });

  final int? limit;
  final int? offset;
  final String? projectPath;
  final String requestScope;
  final String requestId;
  final int queryGeneration;
  final String? provider;
  final bool? namedOnly;
  final String? searchQuery;

  ClientMessage toClientMessage() => ClientMessage.listRecentSessions(
    limit: limit,
    offset: offset,
    projectPath: projectPath,
    requestScope: requestScope,
    requestId: requestId,
    queryGeneration: queryGeneration,
    provider: provider,
    namedOnly: namedOnly,
    searchQuery: searchQuery,
  );

  RecentSessionsMessage correlate(RecentSessionsMessage response) =>
      RecentSessionsMessage(
        sessions: response.sessions,
        hasMore: response.hasMore,
        limit: response.limit ?? limit,
        offset: response.offset ?? offset,
        projectPath: response.projectPath ?? projectPath,
        requestScope: response.requestScope ?? requestScope,
        requestId: requestId,
        queryGeneration: queryGeneration,
        catalogRevision: response.catalogRevision,
        provider: provider,
        namedOnly: namedOnly,
        searchQuery: searchQuery,
      );
}

class _DeliveryPendingInputState {
  _DeliveryPendingInputState(this.item);

  final QueuedInputItem item;
  bool visible = false;
}

class ResolvedArtifact {
  final String artifactId;
  final Uri url;
  final String? expiresAt;

  const ResolvedArtifact({
    required this.artifactId,
    required this.url,
    this.expiresAt,
  });
}

class ArtifactResolveException implements Exception {
  final String code;
  final String message;

  const ArtifactResolveException({required this.code, required this.message});

  @override
  String toString() => 'ArtifactResolveException($code): $message';
}

class ArtifactSourceReadException implements Exception {
  final String code;
  final String message;

  const ArtifactSourceReadException({required this.code, required this.message});

  @override
  String toString() => 'ArtifactSourceReadException($code): $message';
}

/// Snapshot of a session's runtime-store state taken when a legacy
/// `get_history` request was sent, used to fence its full-frame response.
class _LegacyHistoryFence {
  final int generation;
  final int contentEpoch;
  final bool storeWasEmpty;

  const _LegacyHistoryFence({
    required this.generation,
    required this.contentEpoch,
    required this.storeWasEmpty,
  });
}

/// Cached diff image data for a single file.
class DiffImageCacheEntry {
  final int? oldSize;
  final int? newSize;
  final Uint8List? oldBytes;
  final Uint8List? newBytes;

  const DiffImageCacheEntry({
    this.oldSize,
    this.newSize,
    this.oldBytes,
    this.newBytes,
  });
}
