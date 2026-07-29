import 'dart:async';
import 'dart:convert';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';
import 'package:uuid/uuid.dart';

import '../../core/logger.dart';
import '../../l10n/app_localizations.dart';
import '../../utils/network_endpoint.dart';
import '../../utils/platform_helper.dart';

import '../../models/messages.dart';
import '../../models/machine.dart';
import '../../models/offline_pending_action.dart';
import '../../providers/bridge_cubits.dart';
import '../../providers/machine_manager_cubit.dart';
import '../../providers/unseen_sessions_cubit.dart';
import '../../providers/server_discovery_cubit.dart';
import '../../router/app_router.dart';
import '../../services/app_update_service.dart';
import '../../services/bridge_service.dart';
import '../../services/connection_url_parser.dart';
import '../../services/notification_service.dart';
import '../../services/platform_environment_service.dart';
import '../../services/server_discovery_service.dart';
import '../../services/ssh_bridge_tunnel_service.dart';
import '../../widgets/workspace_pane_chrome.dart';
import '../../widgets/adaptive_context_menu.dart';
import '../../widgets/new_session_sheet.dart';
import '../../widgets/rename_session_dialog.dart';
import '../conversation_mirror/conversation_mirror_session_actions.dart';
import '../conversation_content_sync/conversation_content_sync_service.dart';
import '../file_browser/file_browser_screen.dart';
import '../file_browser/file_mutation_authorization.dart';
import '../file_transfer/file_drop_ingress.dart';
import '../file_transfer/file_transfer_service.dart';
import '../file_transfer/file_transfer_strings.dart';
import '../session_archive/session_archive_cubit.dart';
import '../session_archive/session_archive_pending_requests.dart';
import '../session_archive/session_archive_screen.dart';
import '../session_archive/session_archive_strings.dart';
import '../settings/state/settings_cubit.dart';
import '../settings/state/settings_state.dart';
import 'desktop_session_list_continuity_tracker.dart';
import 'pending_session_binding.dart';
import 'services/session_resume_coordinator.dart';
import 'state/session_list_cubit.dart';
import 'state/session_list_state.dart';
import 'widgets/connect_form.dart';
import 'widgets/home_content.dart';
import 'widgets/machine_edit_sheet.dart';
import 'widgets/session_list_app_bar.dart';
import 'workspace_shell_screen.dart';

export 'services/session_resume_coordinator.dart'
    show
        CodexRecentResumeSettings,
        bridgePreservesCodexResumeSettings,
        codexResumePreservesSettingsCapability,
        factualCodexResumeSettings;

const _sessionRequestUuid = Uuid();
const _machineLogicalIdentityPrefix = 'machine:';

// ---- Testable helpers (top-level) ----

/// Keeps the connected home visible only after this exact Bridge target has
/// produced authoritative active-session and recent-session snapshots.
///
/// A WebSocket upgrade is transport readiness, not application readiness. The
/// latch survives a same-target reconnect so an already-open home does not
/// flash back to the connection picker, but a new target must prove both
/// application datasets independently.
class SessionHomeConnectionGate {
  bool _hasReadyTarget = false;
  String? _readyTargetKey;

  bool get hasReadyTarget => _hasReadyTarget;

  bool update({
    required BridgeConnectionState state,
    required String targetKey,
    required bool hasAuthoritativeSessionList,
    required bool hasAuthoritativeRecentSessions,
  }) {
    final previousReady = _hasReadyTarget;
    final previousKey = _readyTargetKey;
    if (_readyTargetKey != null &&
        targetKey != _readyTargetKey &&
        state != BridgeConnectionState.disconnected) {
      _hasReadyTarget = false;
      _readyTargetKey = null;
    }
    if (state == BridgeConnectionState.connected &&
        hasAuthoritativeSessionList &&
        hasAuthoritativeRecentSessions) {
      _hasReadyTarget = true;
      _readyTargetKey = targetKey;
    }
    return previousReady != _hasReadyTarget || previousKey != _readyTargetKey;
  }

  BridgeConnectionState presentationState({
    required BridgeConnectionState transportState,
    required bool hasAuthoritativeSessionList,
    required bool hasAuthoritativeRecentSessions,
  }) {
    if (transportState == BridgeConnectionState.connected &&
        (!hasAuthoritativeSessionList || !hasAuthoritativeRecentSessions)) {
      return _hasReadyTarget
          ? BridgeConnectionState.reconnecting
          : BridgeConnectionState.connecting;
    }
    return transportState;
  }

  bool shouldShowConnectedUi(BridgeConnectionState presentationState) =>
      _hasReadyTarget &&
      presentationState != BridgeConnectionState.disconnected;

  void acceptCachedTarget(String targetKey) {
    _hasReadyTarget = true;
    _readyTargetKey = targetKey;
  }

  void reset() {
    _hasReadyTarget = false;
    _readyTargetKey = null;
  }
}

/// Claims each authoritative session-list generation exactly once after its
/// transport is ready.
///
/// A local Bridge can deliver its first `session_list` frame before
/// `WebSocketChannel.ready` publishes `connected`. Both event orderings must
/// converge on the same catalog bootstrap instead of dropping the only trigger.
class SessionCatalogBootstrapGate {
  int _lastDispatchedGeneration = -1;
  int? _dispatchingGeneration;

  bool claim({
    required BridgeConnectionState connectionState,
    required bool selectionPending,
    required bool hasAuthoritativeSessionList,
    required int generation,
  }) {
    if (connectionState != BridgeConnectionState.connected ||
        selectionPending ||
        !hasAuthoritativeSessionList ||
        generation == _lastDispatchedGeneration ||
        generation == _dispatchingGeneration) {
      return false;
    }
    _dispatchingGeneration = generation;
    return true;
  }

  void completeDispatch(int generation, {required bool dispatched}) {
    if (_dispatchingGeneration != generation) return;
    _dispatchingGeneration = null;
    if (dispatched) _lastDispatchedGeneration = generation;
  }

  bool prepareRetry(int generation) {
    if (_dispatchingGeneration == generation ||
        _lastDispatchedGeneration != generation) {
      return false;
    }
    _lastDispatchedGeneration = -1;
    return true;
  }
}

enum SessionCatalogRecoveryAction {
  none,
  requestSessionList,
  retryCatalog,
  fail,
}

/// Bounded recovery for the two compatibility lanes.
///
/// A correlated Bridge can safely receive one new catalog request because a
/// late response carries its old request ID and is rejected. A legacy Bridge
/// cannot distinguish two in-flight responses, so it must reconnect instead
/// of blindly retrying on the same socket.
class SessionCatalogRecoveryPolicy {
  static const _maxSessionListRetries = 1;
  static const _maxCatalogRetries = 1;

  int _sessionListRetries = 0;
  int _catalogRetries = 0;

  void reset() {
    _sessionListRetries = 0;
    _catalogRetries = 0;
  }

  void recordSessionListRetry() {
    _sessionListRetries += 1;
  }

  void recordCatalogRetry() {
    _catalogRetries += 1;
  }

  SessionCatalogRecoveryAction nextAction({
    required bool hasAuthoritativeSessionList,
    required bool hasUsableCatalog,
    required bool supportsRequestCorrelation,
  }) {
    if (hasAuthoritativeSessionList && hasUsableCatalog) {
      return SessionCatalogRecoveryAction.none;
    }
    if (!hasAuthoritativeSessionList) {
      if (_sessionListRetries < _maxSessionListRetries) {
        return SessionCatalogRecoveryAction.requestSessionList;
      }
      return SessionCatalogRecoveryAction.fail;
    }
    if (!supportsRequestCorrelation) {
      return SessionCatalogRecoveryAction.fail;
    }
    if (_catalogRetries < _maxCatalogRetries) {
      return SessionCatalogRecoveryAction.retryCatalog;
    }
    return SessionCatalogRecoveryAction.fail;
  }
}

/// Rejects late async work from an older connection selection.
///
/// Health checks, secure-storage reads, and SSH tunnel preparation can all
/// finish after the user has selected a different Bridge. Only the latest
/// token may start a transport or persist its target.
class ConnectionAttemptFence {
  int _generation = 0;

  int begin() => ++_generation;

  void cancel() => _generation += 1;

  bool isCurrent(int token) => token == _generation;
}

enum BridgeConnectionEntryStage {
  preparingTarget,
  connectingTransport,
  loadingSessionStatus,
  loadingConversationCatalog,
}

class BridgeConnectionEntryProgress {
  final BridgeConnectionEntryStage stage;
  final double fraction;

  const BridgeConnectionEntryProgress({
    required this.stage,
    required this.fraction,
  });

  int get percent => (fraction * 100).round();
}

/// Converts real connection milestones into deterministic, user-visible
/// progress. These values represent completed stages, not elapsed-time guesses.
BridgeConnectionEntryProgress? bridgeConnectionEntryProgressFor({
  required BridgeConnectionState transportState,
  required bool selectionPending,
  required bool hasAuthoritativeSessionList,
  required bool hasAuthoritativeRecentSessions,
  required bool autoConnecting,
}) {
  if (selectionPending) {
    return const BridgeConnectionEntryProgress(
      stage: BridgeConnectionEntryStage.preparingTarget,
      fraction: 0,
    );
  }
  return switch (transportState) {
    BridgeConnectionState.connecting ||
    BridgeConnectionState.reconnecting => const BridgeConnectionEntryProgress(
      stage: BridgeConnectionEntryStage.connectingTransport,
      fraction: 0.25,
    ),
    BridgeConnectionState.connected when !hasAuthoritativeSessionList =>
      const BridgeConnectionEntryProgress(
        stage: BridgeConnectionEntryStage.loadingSessionStatus,
        fraction: 0.60,
      ),
    BridgeConnectionState.connected when !hasAuthoritativeRecentSessions =>
      const BridgeConnectionEntryProgress(
        stage: BridgeConnectionEntryStage.loadingConversationCatalog,
        fraction: 0.85,
      ),
    _ when autoConnecting => const BridgeConnectionEntryProgress(
      stage: BridgeConnectionEntryStage.preparingTarget,
      fraction: 0,
    ),
    _ => null,
  };
}

Future<bool> showExternalBridgeConnectionConfirmation({
  required BuildContext context,
  required String target,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      final l = AppLocalizations.of(dialogContext);
      return AlertDialog(
        title: Text(l.externalBridgeConnectionTitle),
        content: Text(l.externalBridgeConnectionBody(target)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l.connect),
          ),
        ],
      );
    },
  );
  return confirmed ?? false;
}

bool _sameSessionRequestProject(String expected, String? actual) {
  if (actual == null || actual.isEmpty) return false;

  String normalize(String value) {
    final trimmed = value.trim();
    if (trimmed == '/') return trimmed;
    return trimmed.replaceAll(RegExp(r'/+$'), '');
  }

  return normalize(expected) == normalize(actual);
}

/// Project name → session count, preserving first-seen order.
Map<String, int> projectCounts(List<RecentSession> sessions) {
  final counts = <String, int>{};
  for (final s in sessions) {
    counts[s.projectName] = (counts[s.projectName] ?? 0) + 1;
  }
  return counts;
}

/// Filter sessions by project name (null = no filter).
List<RecentSession> filterByProject(
  List<RecentSession> sessions,
  String? projectName,
) {
  if (projectName == null) return sessions;
  return sessions.where((s) => s.projectName == projectName).toList();
}

/// Unique project paths in first-seen order.
List<({String path, String name})> recentProjects(
  List<RecentSession> sessions,
) {
  final seen = <String>{};
  final result = <({String path, String name})>[];
  for (final s in sessions) {
    if (seen.add(s.projectPath)) {
      result.add((path: s.projectPath, name: s.projectName));
    }
  }
  return result;
}

Future<Machine?> findAutoConnectMachine(
  MachineManagerCubit? cubit,
  Uri uri, {
  Duration loadTimeout = const Duration(seconds: 3),
}) async {
  if (cubit == null) return null;
  await cubit.waitUntilLoaded(timeout: loadTimeout);
  return cubit.findByHostPort(uri.host, uri.hasPort ? uri.port : 8765);
}

/// Shorten absolute path by replacing $HOME with ~.
String shortenPath(String path) {
  final home = getHomeDirectory();
  if (home.isNotEmpty && path.startsWith(home)) {
    return '~${path.substring(home.length)}';
  }
  return path;
}

/// Provider-specific auto rename setting for new sessions.
bool autoRenameForProvider(SettingsState settings, Provider provider) {
  return switch (provider) {
    Provider.codex => settings.autoRenameCodexSessions,
    Provider.claude => settings.autoRenameClaudeSessions,
  };
}

/// Quote a shell argument so it can be pasted safely into POSIX shells.
String shellQuote(String value) {
  return "'${value.replaceAll("'", r"'\''")}'";
}

/// Build a provider-specific CLI resume command for handoff to another machine.
/// Uses resumeCwd (worktree path) when available so the CLI finds the session
/// in the correct project slug directory.
String buildResumeCommand(RecentSession session) {
  final cwd = (session.resumeCwd?.isNotEmpty ?? false)
      ? session.resumeCwd!
      : session.projectPath;
  final provider = session.provider == Provider.codex.value
      ? Provider.codex
      : Provider.claude;

  String resumeCommand;
  if (provider == Provider.codex) {
    resumeCommand = 'codex resume ${shellQuote(session.sessionId)}';
  } else {
    final buf = StringBuffer(
      'claude --resume ${shellQuote(session.sessionId)}',
    );
    final pm = session.effectivePermissionMode;
    if (pm == PermissionMode.bypassPermissions.value) {
      buf.write(' --dangerously-skip-permissions');
    } else if (pm == PermissionMode.auto.value) {
      buf.write(' --permission-mode auto');
    } else if (pm == PermissionMode.acceptEdits.value) {
      buf.write(' --permission-mode acceptEdits');
    } else if (pm == PermissionMode.plan.value) {
      buf.write(' --permission-mode plan');
    }
    resumeCommand = buf.toString();
  }

  return 'cd ${shellQuote(cwd)} && $resumeCommand';
}

/// Filter sessions by text query (matches name, firstPrompt, lastPrompt and summary).
List<RecentSession> filterByQuery(List<RecentSession> sessions, String query) {
  if (query.isEmpty) return sessions;
  final q = query.toLowerCase();
  return sessions.where((s) {
    return (s.name?.toLowerCase().contains(q) ?? false) ||
        s.firstPrompt.toLowerCase().contains(q) ||
        (s.lastPrompt?.toLowerCase().contains(q) ?? false) ||
        (s.summary?.toLowerCase().contains(q) ?? false);
  }).toList();
}

List<RecentSession> preserveFactualRecentSessions(
  List<RecentSession> sessions,
) => sessions;

NewSessionParams? mergeCodexDefaultsIntoInitialSessionDefaults(
  NewSessionParams? defaults,
  NewSessionParams? codexDefaults,
) {
  if (defaults == null) return codexDefaults;
  if (defaults.provider == Provider.codex || codexDefaults == null) {
    return defaults;
  }
  return defaults.copyWith(
    codexApprovalPolicy: codexDefaults.codexApprovalPolicy,
    codexPermissionsMode: codexDefaults.codexPermissionsMode,
    codexAutoReviewEnabled: codexDefaults.codexAutoReviewEnabled,
    codexApprovalPolicyOverridden: codexDefaults.codexApprovalPolicyOverridden,
    codexAutoReviewOverridden: codexDefaults.codexAutoReviewOverridden,
  );
}

// ---- Screen ----

class SessionListScreen extends StatefulWidget {
  final ValueNotifier<ConnectionParams?>? deepLinkNotifier;

  /// Pre-populated sessions for UI testing (skips bridge connection).
  final List<RecentSession>? debugRecentSessions;
  final bool embedded;
  final VoidCallback? onTogglePaneVisibility;
  final ValueChanged<WorkspaceSessionSelection>? onSelectWorkspaceSession;

  const SessionListScreen({
    super.key,
    this.deepLinkNotifier,
    this.debugRecentSessions,
    this.embedded = false,
    this.onTogglePaneVisibility,
    this.onSelectWorkspaceSession,
  });

  @override
  State<SessionListScreen> createState() => _SessionListScreenState();
}

class _SessionListScreenState extends State<SessionListScreen>
    with WidgetsBindingObserver {
  static const _connectionReadinessWarningDelay = Duration(seconds: 3);

  bool _isAutoConnecting = false;
  final _connectionUiGate = SessionHomeConnectionGate();
  final _connectionAttemptFence = ConnectionAttemptFence();
  Timer? _connectionReadinessTimer;
  Future<void> Function()? _retryConnectionAttempt;
  bool _connectionAwaitingReadiness = false;
  bool _connectionTakingLonger = false;
  bool _connectionAttemptFailed = false;
  bool _connectionSelectionPending = false;

  /// Key to access HomeContent state for programmatic search (Cmd+K).
  final _homeContentKey = GlobalKey<HomeContentState>();

  // Debug screen: 5 consecutive taps on title
  int _debugTapCount = 0;
  DateTime? _lastDebugTapTime;

  final _pendingSessionBindings = <PendingSessionBinding>{};
  final _pendingClaudeDefaultsCorrections = <String, NewSessionParams>{};

  // Session-created and correlated failure events are routed only to the
  // pending operation that owns them. This listener never navigates by itself.
  StreamSubscription<ServerMessage>? _messageSub;
  StreamSubscription<BridgeConnectionState>? _archiveConnectionSub;
  StreamSubscription<RecentSessionsMessage>? _catalogReadinessSub;
  StreamSubscription<List<SessionInfo>>? _sessionListReadinessSub;
  StreamSubscription<void>? _catalogCacheReadinessSub;
  int _lastBoundBridgeIdentityGeneration = 0;
  Future<void> _bridgeIdentityBinding = Future<void>.value();
  late final SessionArchivePendingRequests _archivePendingRequests;
  final _catalogBootstrapGate = SessionCatalogBootstrapGate();
  final _catalogRecoveryPolicy = SessionCatalogRecoveryPolicy();

  // macOS app update
  AppUpdateInfo? _appUpdateInfo;
  bool _showMacOSNativeAppBanner = false;
  bool _homeFileDropActive = false;
  bool _homeFileDropStaging = false;

  // Unseen session tracking
  final _unseenCubit = UnseenSessionsCubit();
  StreamSubscription<List<SessionInfo>>? _activeSessionsSub;
  late final DesktopSessionListContinuityTracker _desktopContinuityTracker;

  static const _prefKeyUrl = 'bridge_url';
  static const _prefKeyMacOSNativeAppBannerDismissed =
      'macos_native_app_banner.dismissed';
  static const _prefKeySessionStartDefaults = 'session_start_defaults_v1';
  static const _prefKeySessionStartDefaultsLastProvider =
      'session_start_defaults_last_provider_v1';
  static const _prefKeyCodexSessionStartDefaults =
      'session_start_defaults_codex_v1';
  static const _prefKeyClaudeSessionStartDefaults =
      'session_start_defaults_claude_v1';
  static const _prefKeyClaudeSessionSettingsPrefix = 'claude_session_settings_';
  static const _prefKeyCodexProfileByProject = 'codex_profile_by_project_v1';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // session_created navigation (the only manual subscription)
    final bridge = context.read<BridgeService>();
    final sessionListCubit = context.read<SessionListCubit>();
    _connectionUiGate.update(
      state: bridge.currentBridgeConnectionState,
      targetKey: _connectionUiTargetKey(bridge),
      hasAuthoritativeSessionList:
          bridge.hasAuthoritativeSessionListForCurrentConnection,
      hasAuthoritativeRecentSessions:
          sessionListCubit.hasUsableCatalogForCurrentTarget,
    );
    _desktopContinuityTracker = DesktopSessionListContinuityTracker(bridge);
    _archivePendingRequests = SessionArchivePendingRequests(
      onResultUnknown: _handleArchiveResultUnknown,
    );
    _archiveConnectionSub = bridge.connectionStatus.listen((status) {
      if (status != BridgeConnectionState.connected) {
        _archivePendingRequests.connectionLost();
      }
      _syncConnectionUiGate(bridge, status);
      _refreshCatalogAfterAuthoritativeSessionList(bridge);
    });
    _catalogReadinessSub = bridge.recentSessionResponses.listen((_) {
      _syncConnectionUiGate(bridge, bridge.currentBridgeConnectionState);
    });
    _catalogCacheReadinessSub = sessionListCubit.catalogSnapshotChanges.listen((
      _,
    ) {
      if (mounted) setState(() {});
      _syncConnectionUiGate(bridge, bridge.currentBridgeConnectionState);
    });
    _sessionListReadinessSub = bridge.sessionList.listen((_) {
      _bindCurrentBridgeIdentityIfAuthoritative(bridge);
      _syncConnectionUiGate(bridge, bridge.currentBridgeConnectionState);
      _refreshCatalogAfterAuthoritativeSessionList(bridge);
    });
    _bindCurrentBridgeIdentityIfAuthoritative(bridge);
    _messageSub = bridge.messages.listen((msg) {
      if (msg is SystemMessage &&
          (msg.subtype == 'session_created' ||
              msg.subtype == 'session_start_failed' ||
              msg.subtype == 'session_resume_failed')) {
        final owner = dispatchPendingSessionMessage(
          _pendingSessionBindings,
          msg,
        );
        if (owner != null) {
          _pendingSessionBindings.remove(owner);
        }
        if (msg.subtype == 'session_created') {
          bridge.requestSessionList();
          unawaited(
            _syncPendingClaudeDefaultsWithSessionCreated(
              msg,
              ownedRequestId: owner?.requestId,
            ),
          );
          final sessionId = msg.sessionId;
          if (owner != null && sessionId != null) {
            _unseenCubit.markSeen(
              sessionId,
              scopeKey: _connectionUiTargetKey(bridge),
              dataSourceIdentity: bridge.dataSourceIdentity,
              provider: owner.provider,
            );
          }
        } else {
          _clearPendingClaudeDefaultsCorrection(
            msg,
            ownedRequestId: owner?.requestId,
          );
        }
        return;
      }

      if (msg is ArchiveResultMessage) {
        _handleArchiveResult(msg);
      }
    });
    widget.deepLinkNotifier?.addListener(_onDeepLink);
    NotificationService.instance.addListener(
      _handleActiveNotificationSessionChanged,
    );
    _loadPreferencesAndAutoConnect();

    // Feed active session updates to the unseen tracker.
    final activeCubit = context.read<ActiveSessionsCubit>();
    _updateUnseenSessions(activeCubit.state);
    _activeSessionsSub = activeCubit.stream.listen((sessions) {
      _updateUnseenSessions(sessions);
      _syncConnectionUiGate(bridge, bridge.currentBridgeConnectionState);
    });
    _refreshCatalogAfterAuthoritativeSessionList(bridge);
    unawaited(_loadMacOSNativeAppBannerState());
    _checkAppUpdate();
  }

  void _handleActiveNotificationSessionChanged() {
    if (!mounted) return;
    _updateUnseenSessions(context.read<ActiveSessionsCubit>().state);
  }

  void _updateUnseenSessions(List<SessionInfo> sessions) {
    final notifications = NotificationService.instance;
    final bridge = context.read<BridgeService>();
    _unseenCubit.updateSessions(
      sessions,
      scopeKey: _connectionUiTargetKey(bridge),
      dataSourceIdentity: bridge.dataSourceIdentity,
      legacyScopeKeys: [_connectionUiTargetKey(bridge)],
      visibleSessionId: notifications.activeSessionId,
      visibleProvider: notifications.activeProvider,
      visibleDataSourceIdentity: notifications.activeDataSourceIdentity,
    );
  }

  Future<void> _bindCurrentBridgeIdentity(BridgeService bridge) async {
    if (!mounted) return;
    final bridgeInstanceId = bridge.bridgeInstanceId?.trim();
    final logicalIdentity = bridge.logicalConnectionIdentity?.trim();
    if (logicalIdentity == null ||
        !logicalIdentity.startsWith(_machineLogicalIdentityPrefix)) {
      return;
    }
    final machineId = logicalIdentity.substring(
      _machineLogicalIdentityPrefix.length,
    );
    if (machineId.isEmpty) return;
    final machineManager = context.read<MachineManagerCubit?>();
    if (bridgeInstanceId == null || bridgeInstanceId.isEmpty) {
      await machineManager?.clearBridgeIdentity(machineId);
      return;
    }
    await machineManager?.bindBridgeIdentity(
      machineId: machineId,
      bridgeInstanceId: bridgeInstanceId,
      codexSourceId: bridge.codexSourceId,
    );
  }

  void _bindCurrentBridgeIdentityIfAuthoritative(BridgeService bridge) {
    final generation = bridge.authoritativeSessionListGeneration;
    if (generation <= _lastBoundBridgeIdentityGeneration) return;
    _lastBoundBridgeIdentityGeneration = generation;
    _bridgeIdentityBinding = _bridgeIdentityBinding
        .catchError((Object _) {})
        .then((_) => _bindCurrentBridgeIdentity(bridge));
    unawaited(_bridgeIdentityBinding);
  }

  Future<void> _loadMacOSNativeAppBannerState() async {
    final isIOSAppOnMac = await PlatformEnvironmentService.instance
        .isIOSAppOnMac();
    if (!isIOSAppOnMac) return;

    final prefs = await SharedPreferences.getInstance();
    final dismissed =
        prefs.getBool(_prefKeyMacOSNativeAppBannerDismissed) ?? false;
    if (!mounted || dismissed) return;
    setState(() => _showMacOSNativeAppBanner = true);
  }

  Future<void> _checkAppUpdate() async {
    final update = await AppUpdateService.instance.checkForUpdate();
    if (update != null &&
        !AppUpdateService.instance.isDismissedByUser &&
        mounted) {
      setState(() => _appUpdateInfo = update);
    }
  }

  void _dismissAppUpdate() {
    AppUpdateService.instance.dismissUpdate();
    setState(() => _appUpdateInfo = null);
  }

  Future<void> _dismissMacOSNativeAppBanner() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKeyMacOSNativeAppBannerDismissed, true);
    if (!mounted) return;
    setState(() => _showMacOSNativeAppBanner = false);
  }

  int _beginConnectionAttempt({
    required Future<void> Function() retry,
    required bool autoConnecting,
  }) {
    final token = _connectionAttemptFence.begin();
    _connectionReadinessTimer?.cancel();
    _retryConnectionAttempt = retry;
    _connectionUiGate.reset();
    _catalogRecoveryPolicy.reset();
    if (mounted) {
      setState(() {
        _isAutoConnecting = autoConnecting;
        _connectionAwaitingReadiness = false;
        _connectionTakingLonger = false;
        _connectionAttemptFailed = false;
        _connectionSelectionPending = true;
      });
    } else {
      _isAutoConnecting = autoConnecting;
      _connectionAwaitingReadiness = false;
      _connectionTakingLonger = false;
      _connectionAttemptFailed = false;
      _connectionSelectionPending = true;
    }
    return token;
  }

  bool _isCurrentConnectionAttempt(int token) =>
      mounted && _connectionAttemptFence.isCurrent(token);

  void _armConnectionReadinessWarning(int token) {
    if (!_isCurrentConnectionAttempt(token)) return;
    final bridge = context.read<BridgeService>();
    if (bridge.hasAuthoritativeSessionListForCurrentConnection &&
        context.read<SessionListCubit>().hasUsableCatalogForCurrentTarget) {
      setState(() {
        _connectionSelectionPending = false;
        _retryConnectionAttempt = null;
      });
      _refreshCatalogAfterAuthoritativeSessionList(bridge);
      _syncConnectionUiGate(bridge, bridge.currentBridgeConnectionState);
      return;
    }
    _connectionReadinessTimer?.cancel();
    setState(() {
      _connectionSelectionPending = false;
      _connectionAwaitingReadiness = true;
      _connectionTakingLonger = false;
      _connectionAttemptFailed = false;
    });
    _refreshCatalogAfterAuthoritativeSessionList(bridge);
    _scheduleConnectionReadinessTimeout(token);
  }

  void _scheduleConnectionReadinessTimeout(int token) {
    _connectionReadinessTimer?.cancel();
    _connectionReadinessTimer = Timer(
      _connectionReadinessWarningDelay,
      () => unawaited(_handleConnectionReadinessTimeout(token)),
    );
  }

  Future<void> _handleConnectionReadinessTimeout(int token) async {
    if (!_isCurrentConnectionAttempt(token) || !_connectionAwaitingReadiness) {
      return;
    }
    final bridge = context.read<BridgeService>();
    final sessionListCubit = context.read<SessionListCubit>();
    final action = _catalogRecoveryPolicy.nextAction(
      hasAuthoritativeSessionList:
          bridge.hasAuthoritativeSessionListForCurrentConnection,
      hasUsableCatalog: sessionListCubit.hasUsableCatalogForCurrentTarget,
      supportsRequestCorrelation:
          bridge.supportsSessionCatalogRequestCorrelation,
    );
    logger.info(
      '[session_catalog] event=readiness_timeout '
      'action=${action.name} '
      'authority=${bridge.hasAuthoritativeSessionListForCurrentConnection} '
      'catalog=${sessionListCubit.hasUsableCatalogForCurrentTarget}',
    );

    switch (action) {
      case SessionCatalogRecoveryAction.none:
        _syncConnectionUiGate(bridge, bridge.currentBridgeConnectionState);
        return;
      case SessionCatalogRecoveryAction.requestSessionList:
        try {
          bridge.requestSessionList();
        } catch (_) {
          _markConnectionReadinessFailed(token);
          return;
        }
        _catalogRecoveryPolicy.recordSessionListRetry();
        break;
      case SessionCatalogRecoveryAction.retryCatalog:
        final generation = bridge.authoritativeSessionListGeneration;
        _catalogBootstrapGate.prepareRetry(generation);
        if (_refreshCatalogAfterAuthoritativeSessionList(bridge)) {
          _catalogRecoveryPolicy.recordCatalogRetry();
        }
        break;
      case SessionCatalogRecoveryAction.fail:
        _markConnectionReadinessFailed(token);
        return;
    }

    if (!_isCurrentConnectionAttempt(token) || !_connectionAwaitingReadiness) {
      return;
    }
    setState(() {
      _connectionTakingLonger = true;
      _connectionAttemptFailed = false;
    });
    _scheduleConnectionReadinessTimeout(token);
  }

  void _markConnectionReadinessFailed(int token) {
    _connectionReadinessTimer?.cancel();
    _connectionReadinessTimer = null;
    if (!_isCurrentConnectionAttempt(token) || !_connectionAwaitingReadiness) {
      return;
    }
    setState(() {
      _connectionTakingLonger = false;
      _connectionAttemptFailed = true;
    });
  }

  void _invalidateConnectionAttempt() {
    _connectionAttemptFence.cancel();
    _connectionReadinessTimer?.cancel();
    _connectionReadinessTimer = null;
    _retryConnectionAttempt = null;
    _catalogRecoveryPolicy.reset();
    if (!mounted) return;
    setState(() {
      _isAutoConnecting = false;
      _connectionAwaitingReadiness = false;
      _connectionTakingLonger = false;
      _connectionAttemptFailed = false;
      _connectionSelectionPending = false;
    });
  }

  void _abortConnectionAttemptAndRestore(int token) {
    if (!_isCurrentConnectionAttempt(token)) return;
    _invalidateConnectionAttempt();
    if (!mounted) return;
    final bridge = context.read<BridgeService>();
    _syncConnectionUiGate(bridge, bridge.currentBridgeConnectionState);
  }

  void _failConnectionAttemptAndRestore(int token) {
    if (!_isCurrentConnectionAttempt(token)) return;
    final retry = _retryConnectionAttempt;
    _abortConnectionAttemptAndRestore(token);
    if (!mounted || _connectionUiGate.hasReadyTarget) return;
    setState(() {
      _retryConnectionAttempt = retry;
      _connectionAttemptFailed = true;
    });
  }

  Future<void> _retryCurrentConnection() async {
    final retry = _retryConnectionAttempt;
    if (retry == null) return;
    await retry();
  }

  void _enterWithCachedCatalog() {
    final bridge = context.read<BridgeService>();
    final catalog = context.read<SessionListCubit>();
    if (!catalog.hasCachedCatalogForCurrentTarget) return;
    _connectionReadinessTimer?.cancel();
    _connectionReadinessTimer = null;
    _connectionUiGate.acceptCachedTarget(_connectionUiTargetKey(bridge));
    setState(() {
      _isAutoConnecting = false;
      _connectionSelectionPending = false;
      _connectionAwaitingReadiness = false;
      _connectionTakingLonger = false;
      _connectionAttemptFailed = false;
    });
  }

  void _onDeepLink() {
    final params = widget.deepLinkNotifier?.value;
    if (params == null) return;
    // Reset notifier to avoid re-triggering
    widget.deepLinkNotifier?.value = null;
    unawaited(_confirmAndConnectExternalBridge(params));
  }

  Future<void> _confirmAndConnectExternalBridge(ConnectionParams params) async {
    final target = _bridgeLabelFromUrl(params.serverUrl);
    if (target == null) return;
    final confirmed = await showExternalBridgeConnectionConfirmation(
      context: context,
      target: target,
    );
    if (!mounted || !confirmed) return;
    await _connectWithParams(params.serverUrl, params.token);
  }

  Future<void> _loadPreferencesAndAutoConnect() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final url = prefs.getString(_prefKeyUrl);
    if (url != null && url.isNotEmpty) {
      final attempt = _beginConnectionAttempt(
        retry: _loadPreferencesAndAutoConnect,
        autoConnecting: true,
      );
      final bridge = context.read<BridgeService>();
      // Try to get API key from SecureStorage via MachineManagerCubit.
      String? apiKey;
      String? logicalConnectionIdentity;
      String? expectedBridgeInstanceId;
      String? expectedCodexSourceId;
      try {
        final uri = Uri.tryParse(url);
        if (uri != null) {
          final cubit = context.read<MachineManagerCubit?>();
          final machine = await findAutoConnectMachine(cubit, uri);
          if (!_isCurrentConnectionAttempt(attempt)) return;
          if (machine != null) {
            logicalConnectionIdentity = 'machine:${machine.id}';
            expectedBridgeInstanceId = machine.bridgeInstanceId;
            expectedCodexSourceId = machine.codexSourceId;
            apiKey = await cubit?.getApiKey(machine.id);
            if (!_isCurrentConnectionAttempt(attempt)) return;
            if (machine.sshJumpHost?.trim().isNotEmpty == true) {
              if (!_isCurrentConnectionAttempt(attempt)) return;
              await _connectToMachineConfig(machine, autoConnecting: true);
              return;
            }
          }
        }
      } catch (_) {
        // Ignore — autoConnect falls back to legacy SharedPreferences.
      }
      if (!_isCurrentConnectionAttempt(attempt)) return;
      late final bool attempted;
      try {
        attempted = await bridge.autoConnect(
          apiKey: apiKey,
          logicalConnectionIdentity: logicalConnectionIdentity,
          expectedBridgeInstanceId: expectedBridgeInstanceId,
          expectedCodexSourceId: expectedCodexSourceId,
        );
      } catch (_) {
        _failConnectionAttemptAndRestore(attempt);
        return;
      }
      if (!_isCurrentConnectionAttempt(attempt)) return;
      if (attempted) {
        _armConnectionReadinessWarning(attempt);
      } else {
        _failConnectionAttemptAndRestore(attempt);
      }
    }
  }

  Future<void> _connectWithParams(String rawUrl, String? apiKey) async {
    var url = rawUrl.trim();
    if (url.isEmpty) return;
    final attempt = _beginConnectionAttempt(
      retry: () => _connectWithParams(rawUrl, apiKey),
      autoConnecting: false,
    );
    // Allow shorthand: just IP or host:port without ws:// prefix
    if (!url.startsWith('ws://') && !url.startsWith('wss://')) {
      url = 'ws://$url';
    }

    final machineManagerCubit = context.read<MachineManagerCubit?>();
    final tunnelService = context.read<SshBridgeTunnelService?>();
    final bridge = context.read<BridgeService>();
    if (machineManagerCubit != null) {
      unawaited(machineManagerCubit.refreshLatestBridgeVersionIfStale());
    }
    final messenger = ScaffoldMessenger.of(context);

    // Health check before connecting
    late final Map<String, dynamic>? health;
    try {
      health = await BridgeService.checkHealth(url);
    } catch (error) {
      if (_isCurrentConnectionAttempt(attempt)) {
        messenger.showSnackBar(SnackBar(content: Text(error.toString())));
        _failConnectionAttemptAndRestore(attempt);
      }
      return;
    }
    if (!_isCurrentConnectionAttempt(attempt)) return;
    if (health == null) {
      final shouldConnect = await _showSetupGuide(url);
      if (!_isCurrentConnectionAttempt(attempt)) return;
      if (shouldConnect != true) {
        _abortConnectionAttemptAndRestore(attempt);
        return;
      }
    }

    if (!_isCurrentConnectionAttempt(attempt)) return;
    // Auto-save to Machines on successful health check (or user choosing to connect)
    final trimmedApiKey = apiKey?.trim() ?? '';
    String? logicalConnectionIdentity;
    String? expectedBridgeInstanceId;
    String? expectedCodexSourceId;
    try {
      if (machineManagerCubit != null) {
        // Parse host and port from URL
        final uri = Uri.tryParse(
          url
              .replaceFirst('ws://', 'http://')
              .replaceFirst('wss://', 'https://'),
        );
        if (uri != null) {
          final machine = await machineManagerCubit.recordConnection(
            host: uri.host,
            port: uri.port != 0 ? uri.port : 8765,
            apiKey: trimmedApiKey.isNotEmpty ? trimmedApiKey : null,
            useSsl: uri.scheme == 'https',
          );
          if (!_isCurrentConnectionAttempt(attempt)) return;
          logicalConnectionIdentity = 'machine:${machine.id}';
          expectedBridgeInstanceId = machine.bridgeInstanceId;
          expectedCodexSourceId = machine.codexSourceId;
        }
      }

      if (!_isCurrentConnectionAttempt(attempt)) return;
      if (tunnelService != null) {
        await tunnelService.closeAll();
      }
      if (!_isCurrentConnectionAttempt(attempt)) return;
      var connectUrl = url;
      if (trimmedApiKey.isNotEmpty) {
        final sep = connectUrl.contains('?') ? '&' : '?';
        connectUrl = '$connectUrl${sep}token=$trimmedApiKey';
      }
      bridge.connect(
        connectUrl,
        logicalConnectionIdentity: logicalConnectionIdentity,
        expectedBridgeInstanceId: expectedBridgeInstanceId,
        expectedCodexSourceId: expectedCodexSourceId,
      );
    } catch (error) {
      if (_isCurrentConnectionAttempt(attempt)) {
        messenger.showSnackBar(SnackBar(content: Text(error.toString())));
        _failConnectionAttemptAndRestore(attempt);
      }
      return;
    }
    bridge.savePreferences(url);
    _armConnectionReadinessWarning(attempt);
  }

  /// Show setup guide when health check fails. Returns true if user wants
  /// to try connecting anyway.
  Future<bool?> _showSetupGuide(String url) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) {
        final l = AppLocalizations.of(ctx);
        return AlertDialog(
          title: Row(
            children: [
              Icon(
                Icons.warning_amber_rounded,
                color: Theme.of(ctx).colorScheme.primary,
              ),
              SizedBox(width: 8),
              Expanded(child: Text(l.serverUnreachable)),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  l.serverUnreachableBody,
                  style: TextStyle(
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                SelectableText(
                  url,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(ctx).colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  l.setupSteps,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: Theme.of(ctx).colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 8),
                _SetupStep(
                  number: '1',
                  title: l.setupStep1Title,
                  command: l.setupStep1Command,
                ),
                _SetupStep(
                  number: '2',
                  title: l.setupStep2Title,
                  command: l.setupStep2Command,
                ),
                const SizedBox(height: 12),
                Text(
                  l.setupNetworkHint,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l.connectAnyway),
            ),
          ],
        );
      },
    );
  }

  Future<void> _scanQrCode() async {
    final result = await context.router.push<ConnectionParams>(
      const QrScanRoute(),
    );
    if (result != null && mounted) {
      _connectWithParams(result.serverUrl, result.token);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      final bridge = context.read<BridgeService>();
      bridge.ensureConnected();
      if (bridge.hasAuthoritativeSessionListForCurrentConnection) {
        unawaited(context.read<SessionListCubit>().refresh());
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connectionAttemptFence.cancel();
    _connectionReadinessTimer?.cancel();
    widget.deepLinkNotifier?.removeListener(_onDeepLink);
    NotificationService.instance.removeListener(
      _handleActiveNotificationSessionChanged,
    );
    _messageSub?.cancel();
    _archiveConnectionSub?.cancel();
    _catalogReadinessSub?.cancel();
    _sessionListReadinessSub?.cancel();
    _catalogCacheReadinessSub?.cancel();
    _archivePendingRequests.dispose();
    _activeSessionsSub?.cancel();
    _desktopContinuityTracker.close();
    for (final binding in _pendingSessionBindings.toList()) {
      binding.dispose();
    }
    _pendingSessionBindings.clear();
    _unseenCubit.close();
    super.dispose();
  }

  void _onTitleTap() {
    final now = DateTime.now();
    if (_lastDebugTapTime != null &&
        now.difference(_lastDebugTapTime!).inMilliseconds > 3000) {
      _debugTapCount = 0;
    }
    _lastDebugTapTime = now;
    _debugTapCount++;
    if (_debugTapCount >= 5) {
      _debugTapCount = 0;
      context.router.push(const DebugRoute());
    }
  }

  void _disconnect() {
    _invalidateConnectionAttempt();
    _connectionUiGate.reset();
    context.read<BridgeService>().disconnect();
    final tunnelService = context.read<SshBridgeTunnelService?>();
    if (tunnelService != null) {
      unawaited(tunnelService.closeAll());
    }
    WorkspaceShellScreen.maybeOf(context)?.resetWorkspace();
    context.read<SessionListCubit>().handleDisconnect();
  }

  void _syncConnectionUiGate(
    BridgeService bridge,
    BridgeConnectionState state,
  ) {
    final acceptsCurrentTransport = !_connectionSelectionPending;
    final changed = _connectionUiGate.update(
      state: state,
      targetKey: _connectionUiTargetKey(bridge),
      hasAuthoritativeSessionList:
          acceptsCurrentTransport &&
          bridge.hasAuthoritativeSessionListForCurrentConnection,
      hasAuthoritativeRecentSessions:
          acceptsCurrentTransport &&
          context.read<SessionListCubit>().hasUsableCatalogForCurrentTarget,
    );
    final isApplicationReady =
        acceptsCurrentTransport &&
        bridge.hasAuthoritativeSessionListForCurrentConnection &&
        context.read<SessionListCubit>().hasUsableCatalogForCurrentTarget;
    final readinessCompleted =
        isApplicationReady &&
        (_connectionAwaitingReadiness ||
            _connectionTakingLonger ||
            _connectionAttemptFailed ||
            _retryConnectionAttempt != null);
    final readinessFailed =
        state == BridgeConnectionState.disconnected &&
        _connectionAwaitingReadiness;
    final stopAutoConnecting =
        _isAutoConnecting &&
        (isApplicationReady || state == BridgeConnectionState.disconnected);
    if (readinessCompleted || readinessFailed) {
      _connectionReadinessTimer?.cancel();
      _connectionReadinessTimer = null;
      _catalogRecoveryPolicy.reset();
      logger.info(
        '[session_catalog] event=${readinessCompleted ? 'application_ready' : 'readiness_failed'} '
        'generation=${bridge.authoritativeSessionListGeneration}',
      );
    }
    if (!mounted ||
        (!changed &&
            !stopAutoConnecting &&
            !readinessCompleted &&
            !readinessFailed)) {
      return;
    }
    setState(() {
      if (stopAutoConnecting) _isAutoConnecting = false;
      if (readinessCompleted) {
        _connectionAwaitingReadiness = false;
        _connectionTakingLonger = false;
        _connectionAttemptFailed = false;
        _retryConnectionAttempt = null;
      } else if (readinessFailed) {
        _connectionAwaitingReadiness = false;
        _connectionTakingLonger = false;
        _connectionAttemptFailed = true;
      }
    });
  }

  bool _refreshCatalogAfterAuthoritativeSessionList(BridgeService bridge) {
    final generation = bridge.authoritativeSessionListGeneration;
    if (!mounted ||
        !_catalogBootstrapGate.claim(
          connectionState: bridge.currentBridgeConnectionState,
          selectionPending: _connectionSelectionPending,
          hasAuthoritativeSessionList:
              bridge.hasAuthoritativeSessionListForCurrentConnection,
          generation: generation,
        )) {
      return false;
    }
    final targetKey = _connectionUiTargetKey(bridge);
    logger.info(
      '[session_catalog] event=bootstrap_claimed generation=$generation',
    );
    unawaited(_dispatchCatalogBootstrap(bridge, generation, targetKey));
    return true;
  }

  Future<void> _dispatchCatalogBootstrap(
    BridgeService bridge,
    int generation,
    String targetKey,
  ) async {
    var dispatched = false;
    try {
      dispatched = await context.read<SessionListCubit>().refreshCatalog(
        isCurrentConnection: () =>
            mounted &&
            identical(context.read<BridgeService>(), bridge) &&
            !_connectionSelectionPending &&
            bridge.currentBridgeConnectionState ==
                BridgeConnectionState.connected &&
            bridge.hasAuthoritativeSessionListForCurrentConnection &&
            bridge.authoritativeSessionListGeneration == generation &&
            _connectionUiTargetKey(bridge) == targetKey,
      );
    } finally {
      _catalogBootstrapGate.completeDispatch(
        generation,
        dispatched: dispatched,
      );
      logger.info(
        '[session_catalog] event=bootstrap_completed '
        'generation=$generation dispatched=$dispatched',
      );
    }
  }

  String _connectionUiTargetKey(BridgeService bridge) {
    final logicalIdentity = bridge.logicalConnectionIdentity?.trim();
    if (logicalIdentity != null && logicalIdentity.isNotEmpty) {
      return 'logical:$logicalIdentity';
    }
    final url = bridge.lastUrl;
    final uri = url == null ? null : Uri.tryParse(url);
    if (uri == null) return 'url:${url ?? ''}';
    final port = uri.hasPort
        ? uri.port
        : switch (uri.scheme.toLowerCase()) {
            'wss' => 443,
            _ => 80,
          };
    return 'url:${uri.scheme.toLowerCase()}://'
        '${uri.host.toLowerCase()}:$port${uri.path}';
  }

  Future<void> _openSettings() async {
    final shell = WorkspaceShellScreen.maybeOf(context);
    if (widget.embedded && shell != null) {
      shell.openSettingsCenter();
      return;
    }
    await context.router.push(SettingsRoute());
  }

  void _openSupportSettings() {
    final shell = WorkspaceShellScreen.maybeOf(context);
    if (widget.embedded && shell != null) {
      shell.openSettingsCenter(focusSupport: true);
      return;
    }
    context.pushRoute(SettingsRoute(focusSupport: true));
  }

  void _openBridgeSettings() {
    final shell = WorkspaceShellScreen.maybeOf(context);
    if (widget.embedded && shell != null) {
      shell.openSettingsCenter(focusConnection: true);
      return;
    }
    context.pushRoute(SettingsRoute(focusConnection: true));
  }

  Future<void> _openGallery() async {
    final shell = WorkspaceShellScreen.maybeOf(context);
    if (widget.embedded && shell != null) {
      shell.openGlobalGalleryCenter();
      return;
    }
    await context.router.push(GalleryRoute());
  }

  Future<void> _openFileBrowser() async {
    final shell = WorkspaceShellScreen.maybeOf(context);
    if (widget.embedded && shell != null) {
      shell.openFileBrowserCenter();
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const FileBrowserScreen()),
    );
  }

  Future<void> _openArchivedSessions() => openSessionArchive(context);

  Future<void> _handleHomeFileDrop(PerformDropEvent event) async {
    if (!mounted) return;
    setState(() {
      _homeFileDropActive = false;
      _homeFileDropStaging = true;
    });
    final service = context.read<FileTransferService>();
    final copy = _HomeFileDropCopy.of(context);
    try {
      await consumeDroppedFiles(event, (payload) async {
        try {
          final ticket = await service.enqueueDroppedFile(
            filename: payload.filename,
            bytes: payload.bytes,
            expectedSizeBytes: payload.sizeBytes,
            authorizeMutation: (operation) =>
                requestFileMutationAuthorization(context, operation),
          );
          unawaited(_showHomeTransferResult(ticket, payload.filename));
        } catch (error) {
          _showHomeDropMessage(copy.unableToQueue(payload.filename, error));
        }
      });
    } catch (_) {
      _showHomeDropMessage(copy.unableToRead);
    } finally {
      if (mounted) setState(() => _homeFileDropStaging = false);
    }
  }

  Future<void> _showHomeTransferResult(
    FileTransferUploadTicket ticket,
    String filename,
  ) async {
    final copy = _HomeFileDropCopy.of(context);
    try {
      final result = await ticket.completion;
      if (!mounted) return;
      switch (result.status) {
        case FileTransferStatus.succeeded:
          _showHomeDropMessage(copy.sent(filename));
          break;
        case FileTransferStatus.paused:
          _showHomeDropMessage(copy.paused(filename));
          break;
        case FileTransferStatus.failed:
        case FileTransferStatus.cancelled:
          _showHomeDropMessage(copy.failedToSend(filename));
          break;
        case FileTransferStatus.preparing:
        case FileTransferStatus.queued:
        case FileTransferStatus.transferring:
          break;
      }
    } catch (error) {
      _showHomeDropMessage(copy.failedWithError(filename, error));
    }
  }

  void _showHomeDropMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _refresh() async {
    final machineManagerCubit = context.read<MachineManagerCubit?>();
    await context.read<SessionListCubit>().refresh();
    if (machineManagerCubit != null) {
      unawaited(machineManagerCubit.refreshLatestBridgeVersionIfStale());
    }
  }

  void _showNewSessionDialog() async {
    final defaults = await _loadInitialNewSessionDefaults();
    if (!mounted) return;
    final result = await _openNewSessionSheet(initialParams: defaults);
    if (result == null || !mounted) return;
    await _saveSessionStartDefaults(result);
    await _saveProjectCodexProfileFromParams(result);
    if (!mounted) return;
    _startNewSession(result);
  }

  Future<NewSessionParams?> _openNewSessionSheet({
    NewSessionParams? initialParams,
    bool lockProvider = false,
  }) async {
    final sessions =
        widget.debugRecentSessions ??
        context.read<SessionListCubit>().state.sessions;
    final history = context.read<ProjectHistoryCubit>().state;
    final bridge = context.read<BridgeService>();
    final settings = context.read<SettingsCubit>().state;
    return showNewSessionSheet(
      context: context,
      recentProjects: recentProjects(sessions),
      projectHistory: history,
      bridge: bridge,
      initialParams: initialParams,
      lockProvider: lockProvider,
      visibleTabs: settings.newSessionTabs,
      showExtendedCodexEfforts: settings.showExtendedCodexEfforts,
    );
  }

  void _startNewSession(NewSessionParams result) {
    final bridge = context.read<BridgeService>();
    if (_hasPendingStart(bridge, result)) return;

    final settings = context.read<SettingsCubit>().state;
    final isOffline = !bridge.isConnected;
    final canOpenPending =
        bridge.hasAuthoritativeSessionListForCurrentConnection;
    final requestId = _sessionRequestUuid.v4();
    final pendingBinding = canOpenPending
        ? _registerPendingSessionBinding(
            kind: PendingSessionRequestKind.start,
            requestId: requestId,
            provider: result.provider,
            projectPath: result.projectPath,
          )
        : null;
    _trackPendingClaudeDefaultsCorrection(requestId, result);
    final useCodexProfile =
        result.provider == Provider.codex &&
        (result.codexProfile?.isNotEmpty ?? false);
    final useCodexCustomPermissions =
        result.provider == Provider.codex &&
        (useCodexProfile ||
            result.codexPermissionsMode == CodexPermissionsMode.custom);
    bridge.send(
      ClientMessage.start(
        result.projectPath,
        permissionMode: result.provider == Provider.codex && useCodexProfile
            ? null
            : result.permissionMode.value,
        executionMode: result.provider == Provider.codex && useCodexProfile
            ? null
            : result.executionMode.value,
        approvalPolicy: result.provider == Provider.codex
            ? (useCodexCustomPermissions
                  ? null
                  : result.codexApprovalPolicy.value)
            : null,
        approvalsReviewer: result.provider == Provider.codex
            ? (useCodexCustomPermissions ? null : result.codexApprovalsReviewer)
            : null,
        codexPermissionsMode: result.provider == Provider.codex
            ? (useCodexCustomPermissions
                  ? CodexPermissionsMode.custom.value
                  : result.codexPermissionsMode.value)
            : null,
        planMode: result.provider == Provider.codex && useCodexProfile
            ? null
            : result.planMode,
        effort: result.provider == Provider.claude
            ? result.claudeEffort?.value
            : null,
        maxTurns: result.provider == Provider.claude
            ? result.claudeMaxTurns
            : null,
        maxBudgetUsd: result.provider == Provider.claude
            ? result.claudeMaxBudgetUsd
            : null,
        fallbackModel: result.provider == Provider.claude
            ? result.claudeFallbackModel
            : null,
        // --fork-session applies to resume/continue only.
        forkSession: null,
        persistSession: result.provider == Provider.claude
            ? result.claudePersistSession
            : null,
        useWorktree: result.useWorktree ? true : null,
        worktreeBranch: result.worktreeBranch,
        existingWorktreePath: result.existingWorktreePath,
        provider: result.provider.value,
        profile: result.provider == Provider.codex ? result.codexProfile : null,
        model: result.provider == Provider.claude
            ? result.claudeModel
            : (useCodexProfile ? null : result.model),
        sandboxMode:
            result.provider == Provider.codex && useCodexCustomPermissions
            ? null
            : result.sandboxMode?.value,
        modelReasoningEffort:
            result.provider == Provider.codex && useCodexProfile
            ? null
            : result.modelReasoningEffort?.value,
        serviceTier: result.provider == Provider.codex
            ? result.codexSpeed.value
            : null,
        networkAccessEnabled:
            result.provider == Provider.codex && useCodexCustomPermissions
            ? null
            : result.networkAccessEnabled,
        webSearchMode: result.provider == Provider.codex && useCodexProfile
            ? null
            : result.webSearchMode?.value,
        additionalWritableRoots:
            result.provider == Provider.codex && !useCodexCustomPermissions
            ? result.additionalWritableRoots
            : null,
        autoRename: autoRenameForProvider(settings, result.provider),
        startRequestId: requestId,
      ),
    );
    if (isOffline) {
      pendingBinding?.dispose();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).sessionQueuedForReconnect),
        ),
      );
      return;
    }
    if (!bridge.hasAuthoritativeSessionListForCurrentConnection ||
        pendingBinding == null) {
      pendingBinding?.dispose();
      return;
    }
    // The binding was registered before the wire send, so a very fast Bridge
    // response can be replayed by the pending page without global matching.
    final pendingId = 'pending_start_$requestId';
    _navigateToChat(
      pendingId,
      projectPath: result.projectPath,
      gitBranch: result.worktreeBranch,
      worktreePath: result.existingWorktreePath,
      isPending: true,
      provider: result.provider,
      permissionMode: result.permissionMode.value,
      sandboxMode: result.sandboxMode?.value,
      approvalPolicy: result.provider == Provider.codex
          ? result.codexApprovalPolicy.value
          : null,
      approvalsReviewer: result.provider == Provider.codex
          ? result.codexApprovalsReviewer
          : null,
      pendingSessionCreated: pendingBinding,
    );
  }

  static String _sessionStartDefaultsKeyForProvider(Provider provider) {
    return switch (provider) {
      Provider.codex => _prefKeyCodexSessionStartDefaults,
      Provider.claude => _prefKeyClaudeSessionStartDefaults,
    };
  }

  static Provider? _sessionStartDefaultsProviderFromRaw(String? raw) {
    return switch (raw) {
      'codex' => Provider.codex,
      'claude' => Provider.claude,
      _ => null,
    };
  }

  NewSessionParams? _decodeSessionStartDefaults(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return sessionStartDefaultsFromJson(json);
    } catch (_) {
      return null;
    }
  }

  Future<NewSessionParams?> _loadSessionStartDefaults({
    Provider? provider,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (provider != null) {
      final scoped = _decodeSessionStartDefaults(
        prefs.getString(_sessionStartDefaultsKeyForProvider(provider)),
      );
      if (scoped != null) return scoped;

      // Migration fallback from the old shared key. Only use it when the
      // stored provider matches, so Claude defaults cannot affect Codex.
      final legacy = _decodeSessionStartDefaults(
        prefs.getString(_prefKeySessionStartDefaults),
      );
      return legacy?.provider == provider ? legacy : null;
    }

    final lastProvider = _sessionStartDefaultsProviderFromRaw(
      prefs.getString(_prefKeySessionStartDefaultsLastProvider),
    );
    if (lastProvider != null) {
      final scoped = await _loadSessionStartDefaults(provider: lastProvider);
      if (scoped != null) return scoped;
    }

    final legacy = _decodeSessionStartDefaults(
      prefs.getString(_prefKeySessionStartDefaults),
    );
    if (legacy != null) return legacy;

    return await _loadSessionStartDefaults(provider: Provider.codex) ??
        await _loadSessionStartDefaults(provider: Provider.claude);
  }

  Future<void> _saveSessionStartDefaults(NewSessionParams params) async {
    final prefs = await SharedPreferences.getInstance();
    final json = sessionStartDefaultsToJson(params);
    await prefs.setString(
      _sessionStartDefaultsKeyForProvider(params.provider),
      jsonEncode(json),
    );
    await prefs.setString(
      _prefKeySessionStartDefaultsLastProvider,
      params.provider.value,
    );
  }

  void _trackPendingClaudeDefaultsCorrection(
    String requestId,
    NewSessionParams params,
  ) {
    if (params.provider != Provider.claude ||
        params.permissionMode != PermissionMode.auto) {
      return;
    }
    if (_pendingClaudeDefaultsCorrections.length >= 32) {
      _pendingClaudeDefaultsCorrections.remove(
        _pendingClaudeDefaultsCorrections.keys.first,
      );
    }
    _pendingClaudeDefaultsCorrections[requestId] = params;
  }

  Future<void> _syncPendingClaudeDefaultsWithSessionCreated(
    SystemMessage msg, {
    String? ownedRequestId,
  }) async {
    final requestId =
        ownedRequestId ??
        msg.startRequestId ??
        msg.resumeRequestId ??
        _singleLegacyClaudeDefaultsRequestId(msg);
    if (requestId == null) return;
    final pending = _pendingClaudeDefaultsCorrections.remove(requestId);
    if (pending == null) return;

    final actualMode =
        permissionModeFromRaw(msg.permissionMode) ?? PermissionMode.defaultMode;
    if (actualMode == pending.permissionMode) return;

    await _saveSessionStartDefaults(
      pending.copyWith(claudePermissionMode: actualMode),
    );
  }

  void _clearPendingClaudeDefaultsCorrection(
    SystemMessage msg, {
    String? ownedRequestId,
  }) {
    final requestId =
        ownedRequestId ??
        msg.startRequestId ??
        msg.resumeRequestId ??
        _singleLegacyClaudeDefaultsRequestId(msg);
    if (requestId != null) {
      _pendingClaudeDefaultsCorrections.remove(requestId);
    }
  }

  String? _singleLegacyClaudeDefaultsRequestId(SystemMessage msg) {
    final candidates = _pendingClaudeDefaultsCorrections.entries.where((entry) {
      final messageProvider = msg.provider;
      if (messageProvider != null &&
          messageProvider.isNotEmpty &&
          messageProvider != Provider.claude.value) {
        return false;
      }
      return _sameSessionRequestProject(
        entry.value.projectPath,
        msg.projectPath,
      );
    }).toList();
    return candidates.length == 1 ? candidates.single.key : null;
  }

  Future<NewSessionParams?> _loadInitialNewSessionDefaults() async {
    final defaults = await _loadSessionStartDefaults();
    final codexDefaults = await _loadSessionStartDefaults(
      provider: Provider.codex,
    );
    final mergedDefaults = mergeCodexDefaultsIntoInitialSessionDefaults(
      defaults,
      codexDefaults,
    );
    if (mergedDefaults == null) return null;
    if (mergedDefaults.provider != Provider.codex) {
      return mergedDefaults;
    }
    final savedProfile = await _loadProjectCodexProfile(
      mergedDefaults.projectPath,
    );
    if (savedProfile == null || savedProfile.isEmpty) return mergedDefaults;
    if (!mounted) return mergedDefaults;
    final available = context.read<BridgeService>().codexProfiles;
    if (available.isNotEmpty && !available.contains(savedProfile)) {
      return mergedDefaults;
    }
    return mergedDefaults.copyWith(codexProfile: savedProfile);
  }

  Future<Map<String, String>> _loadCodexProfilesByProject() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefKeyCodexProfileByProject);
    if (raw == null || raw.isEmpty) return {};
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return json.map((key, value) => MapEntry(key, value?.toString() ?? ''));
    } catch (_) {
      return {};
    }
  }

  Future<String?> _loadProjectCodexProfile(String projectPath) async {
    final normalized = projectPath.trim();
    if (normalized.isEmpty) return null;
    final saved = await _loadCodexProfilesByProject();
    final profile = saved[normalized];
    if (profile == null || profile.isEmpty) return null;
    return profile;
  }

  Future<void> _saveProjectCodexProfile(
    String projectPath,
    String? profile,
  ) async {
    final normalized = projectPath.trim();
    if (normalized.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final saved = await _loadCodexProfilesByProject();
    if (profile == null || profile.isEmpty) {
      saved.remove(normalized);
    } else {
      saved[normalized] = profile;
    }
    await prefs.setString(_prefKeyCodexProfileByProject, jsonEncode(saved));
  }

  Future<void> _saveProjectCodexProfileFromParams(NewSessionParams params) {
    if (params.provider != Provider.codex) {
      return Future.value();
    }
    final available = context.read<BridgeService>().codexProfiles;
    final selected = params.codexProfile;
    if (available.isNotEmpty &&
        selected != null &&
        selected.isNotEmpty &&
        !available.contains(selected)) {
      return _saveProjectCodexProfile(params.projectPath, null);
    }
    return _saveProjectCodexProfile(params.projectPath, selected);
  }

  List<RecentSession> _factualRecentSessions(List<RecentSession> sessions) {
    return preserveFactualRecentSessions(sessions);
  }

  // ---- Per-session Claude settings persistence ----

  static Future<void> saveClaudeSessionSettings(
    String sessionId,
    Map<String, dynamic> settings,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    // Merge with existing settings to preserve fields not being updated.
    final existing = await loadClaudeSessionSettings(sessionId);
    final merged = <String, dynamic>{...?existing, ...settings};
    await prefs.setString(
      '$_prefKeyClaudeSessionSettingsPrefix$sessionId',
      jsonEncode(merged),
    );
  }

  static Future<Map<String, dynamic>?> loadClaudeSessionSettings(
    String sessionId,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(
      '$_prefKeyClaudeSessionSettingsPrefix$sessionId',
    );
    if (raw == null || raw.isEmpty) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Build a settings map from NewSessionParams (Claude fields only).
  static Map<String, dynamic> _claudeSettingsFromParams(
    NewSessionParams params,
  ) {
    return <String, dynamic>{
      'permissionMode': params.permissionMode.value,
      'executionMode': params.executionMode.value,
      'planMode': params.planMode,
      if (params.sandboxMode != null) 'sandboxMode': params.sandboxMode!.value,
      if (params.claudeModel != null) 'claudeModel': params.claudeModel,
      if (params.claudeEffort != null)
        'claudeEffort': params.claudeEffort!.value,
      if (params.claudeFallbackModel != null)
        'claudeFallbackModel': params.claudeFallbackModel,
      if (params.claudeForkSession != null)
        'claudeForkSession': params.claudeForkSession,
      if (params.claudePersistSession != null)
        'claudePersistSession': params.claudePersistSession,
    };
  }

  Future<NewSessionParams> _newSessionFromRecentSession(
    RecentSession session,
  ) async {
    final provider = session.provider == Provider.codex.value
        ? Provider.codex
        : Provider.claude;
    final codexModels = context.read<BridgeService>().codexModels;
    final existingWorktreePath = session.resumeCwd;
    final hasExistingWorktree =
        existingWorktreePath != null && existingWorktreePath.isNotEmpty;

    // Load per-session Claude settings (saved from previous runs).
    final sessionSettings = provider == Provider.claude
        ? await loadClaudeSessionSettings(session.sessionId)
        : null;
    final codexApprovalPolicy =
        codexApprovalPolicyFromRaw(session.codexApprovalPolicy) ??
        codexApprovalPolicyFromLegacyExecutionMode(
          sessionSettings?['executionMode'] as String?,
        );
    final codexAutoReviewEnabled = isCodexAutoReviewApprovalsReviewer(
      session.codexApprovalsReviewer,
    );
    final codexPermissionsMode = codexPermissionsModeFromSettings(
      codexPermissionsMode: session.codexPermissionsMode,
      approvalPolicy: session.codexApprovalPolicy,
      approvalsReviewer: session.codexApprovalsReviewer,
      sandboxMode: session.codexSandboxMode,
    );

    return NewSessionParams(
      projectPath: session.projectPath,
      provider: provider,
      executionMode: deriveExecutionMode(
        provider: provider.value,
        executionMode: sessionSettings?['executionMode'] as String?,
        permissionMode: sessionSettings?['permissionMode'] as String?,
        approvalPolicy: session.codexApprovalPolicy,
      ),
      codexPermissionsMode: codexPermissionsMode,
      codexApprovalPolicy: codexApprovalPolicy,
      codexAutoReviewEnabled: codexAutoReviewEnabled,
      codexProfile: provider == Provider.codex ? session.codexProfile : null,
      codexApprovalPolicyOverridden: provider == Provider.codex,
      codexAutoReviewOverridden: provider == Provider.codex,
      codexModelOverridden: provider == Provider.codex,
      codexSandboxModeOverridden: provider == Provider.codex,
      codexReasoningEffortOverridden: provider == Provider.codex,
      codexNetworkAccessOverridden: provider == Provider.codex,
      codexWebSearchModeOverridden: provider == Provider.codex,
      planMode: derivePlanMode(
        planMode: sessionSettings?['planMode'] as bool?,
        permissionMode: sessionSettings?['permissionMode'] as String?,
      ),
      useWorktree: hasExistingWorktree,
      worktreeBranch: session.gitBranch.isNotEmpty ? session.gitBranch : null,
      existingWorktreePath: hasExistingWorktree ? existingWorktreePath : null,
      model:
          normalizeCodexModelForAvailableList(
            session.codexModel,
            codexModels,
          ) ??
          session.codexModel,
      sandboxMode: provider == Provider.codex
          ? sandboxModeFromRaw(session.codexSandboxMode)
          : sandboxModeFromRaw(sessionSettings?['sandboxMode'] as String?),
      modelReasoningEffort: reasoningEffortFromRaw(
        session.codexModelReasoningEffort,
      ),
      codexSpeed: codexSelectableSpeedFromRaw(session.codexServiceTier),
      networkAccessEnabled: session.codexNetworkAccessEnabled,
      webSearchMode: webSearchModeFromRaw(session.codexWebSearchMode),
      additionalWritableRoots: provider == Provider.codex
          ? session.codexAdditionalWritableRoots
          : const [],
      claudeModel: sessionSettings?['claudeModel'] as String?,
      claudeEffort: claudeEffortFromRaw(
        sessionSettings?['claudeEffort'] as String?,
      ),
      claudeFallbackModel: sessionSettings?['claudeFallbackModel'] as String?,
      claudeForkSession: sessionSettings?['claudeForkSession'] as bool?,
      claudePersistSession: sessionSettings?['claudePersistSession'] as bool?,
    );
  }

  void _showRunningSessionActions(
    SessionInfo session, [
    Offset? position,
  ]) async {
    final l = AppLocalizations.of(context);
    final action = await showAdaptiveActionMenu<String>(
      context: context,
      position: position,
      items: [
        ...conversationMirrorRunningActionItems(context, session),
        AdaptiveActionMenuItem(
          value: 'rename',
          icon: Icons.label_outline,
          label: l.rename,
        ),
        AdaptiveActionMenuItem(
          value: 'stop',
          icon: Icons.stop_circle_outlined,
          label: l.stopSession,
          destructive: true,
        ),
      ],
    );
    if (action == null || !mounted) return;

    if (await handleConversationMirrorRunningAction(context, session, action)) {
      return;
    }
    if (!mounted) return;

    if (action == 'rename') {
      final newName = await showRenameSessionDialog(
        context,
        currentName: session.name,
      );
      if (newName == null || !mounted) return;
      context.read<BridgeService>().renameSession(
        sessionId: session.id,
        name: newName.isEmpty ? null : newName,
      );
      // Running session list will auto-update via broadcastSessionList
      return;
    }

    if (action == 'stop') {
      context.read<BridgeService>().stopSession(session.id);
    }
  }

  void _showRecentSessionActions(
    RecentSession session, [
    Offset? position,
  ]) async {
    final l = AppLocalizations.of(context);
    final action = await showAdaptiveActionMenu<String>(
      context: context,
      position: position,
      items: [
        ...conversationMirrorActionItems(context, session),
        AdaptiveActionMenuItem(
          value: 'rename',
          icon: Icons.label_outline,
          label: l.rename,
        ),
        AdaptiveActionMenuItem(
          value: 'start_same',
          icon: Icons.play_arrow,
          label: l.startNewWithSameSettings,
        ),
        AdaptiveActionMenuItem(
          value: 'copy_resume_command',
          icon: Icons.terminal,
          label: l.copyResumeCommand,
          subtitle: l.copyResumeCommandSubtitle,
        ),
        AdaptiveActionMenuItem(
          value: 'start_edit',
          icon: Icons.tune,
          label: l.editSettingsThenStart,
        ),
        AdaptiveActionMenuItem(
          value: 'archive',
          icon: Icons.archive_outlined,
          label: l.archive,
          destructive: true,
        ),
      ],
    );
    if (action == null || !mounted) return;

    if (await handleConversationMirrorAction(context, session, action)) return;
    if (!mounted) return;

    if (action == 'rename') {
      final newName = await showRenameSessionDialog(
        context,
        currentName: session.name,
      );
      if (newName == null || !mounted) return;
      final effectiveName = newName.isEmpty ? null : newName;
      // Optimistically update the local state for instant UI feedback
      context.read<SessionListCubit>().updateSessionName(
        session.sessionId,
        effectiveName,
      );
      context.read<BridgeService>().renameSession(
        sessionId: session.sessionId,
        name: effectiveName,
        provider: session.provider,
        providerSessionId: session.sessionId,
        projectPath: session.projectPath,
        codexSourceId: session.codexSourceId,
      );
      // Also refresh from server to confirm persistence
      unawaited(context.read<SessionListCubit>().refresh());
      return;
    }

    if (action == 'start_same') {
      final params = await _newSessionFromRecentSession(session);
      if (!mounted) return;
      // Don't save as defaults — these are session-specific settings from a
      // recent session, not user-chosen defaults for future sessions.
      _startNewSession(params);
      return;
    }

    if (action == 'copy_resume_command') {
      await Clipboard.setData(ClipboardData(text: buildResumeCommand(session)));
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.resumeCommandCopied)));
      return;
    }

    if (action == 'start_edit') {
      final initialParams = await _newSessionFromRecentSession(session);
      if (!mounted) return;
      final edited = await _openNewSessionSheet(
        initialParams: initialParams,
        lockProvider: true,
      );
      if (edited == null || !mounted) return;
      await _saveSessionStartDefaults(edited);
      await _saveProjectCodexProfileFromParams(edited);
      if (!mounted) return;
      _resumeSessionWithParams(session, edited);
      return;
    }

    if (action == 'archive') {
      _archiveSession(session);
    }
  }

  void _handleArchiveResult(ArchiveResultMessage message) {
    final resolved = _archivePendingRequests.resolve(message);
    if (resolved == null) return;
    if (mounted) {
      setState(() {});
    }
    if (!mounted) return;
    final l = AppLocalizations.of(context);
    final text = message.success
        ? l.sessionArchived
        : (message.error?.isNotEmpty == true
              ? l.archiveFailedWithError(message.error!)
              : l.archiveFailed);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  void _handleArchiveResultUnknown(
    List<PendingArchiveRequest> requests,
    ArchiveResultUnknownReason reason,
  ) {
    if (!mounted || requests.isEmpty) return;
    setState(() {});
    final strings = SessionArchiveStrings.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          strings.archiveResultUnknown(
            disconnected: reason == ArchiveResultUnknownReason.disconnected,
          ),
        ),
      ),
    );
  }

  PendingSessionBinding _registerPendingSessionBinding({
    required PendingSessionRequestKind kind,
    required String requestId,
    required Provider provider,
    required String projectPath,
    String? providerSessionId,
    bool? allowLegacyFallback,
    Future<void> Function()? onAttachmentRequested,
  }) {
    final shouldAllowLegacyFallback =
        allowLegacyFallback ??
        !context.read<BridgeService>().bridgeCapabilities.contains(
          sessionRequestCorrelationCapability,
        );
    late final PendingSessionBinding binding;
    binding = PendingSessionBinding(
      kind: kind,
      requestId: requestId,
      provider: provider.value,
      projectPath: projectPath,
      providerSessionId: providerSessionId,
      allowLegacyFallback: shouldAllowLegacyFallback,
      onAttachmentRequested: onAttachmentRequested,
      onDisposed: () => _pendingSessionBindings.remove(binding),
    );
    _pendingSessionBindings.add(binding);
    return binding;
  }

  void _archiveSession(RecentSession session) {
    final provider = session.provider ?? Provider.claude.value;
    final identityKey = providerSessionIdentityKey(provider, session.sessionId);
    if (_archivePendingRequests.hasIdentity(identityKey)) return;
    final bridge = context.read<BridgeService>();
    if (!bridge.bridgeCapabilities.contains(codexSessionLifecycleCapability) &&
        _archivePendingRequests.hasSessionId(session.sessionId)) {
      return;
    }
    final requestId = _sessionRequestUuid.v4();
    final registered = _archivePendingRequests.register(
      requestId: requestId,
      sessionId: session.sessionId,
      provider: provider,
      identityKey: identityKey,
    );
    if (!registered) return;
    setState(() {});
    try {
      bridge.archiveSession(
        sessionId: session.sessionId,
        provider: provider,
        projectPath: session.projectPath,
        requestId: requestId,
        name: session.name,
        summary: session.summary,
        firstPrompt: session.firstPrompt,
        modified: session.modified,
        codexSourceId: session.codexSourceId,
      );
    } catch (error) {
      _archivePendingRequests.cancel(requestId);
      setState(() {});
      final l = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.archiveFailedWithError('$error'))),
      );
    }
  }

  void _navigateToChat(
    String sessionId, {
    String? durableProviderSessionId,
    String? projectPath,
    String? gitBranch,
    String? worktreePath,
    bool isPending = false,
    Provider? provider,
    String? permissionMode,
    String? sandboxMode,
    String? approvalPolicy,
    String? approvalsReviewer,
    ValueNotifier<SystemMessage?>? pendingSessionCreated,
  }) {
    final seenSessionId =
        durableProviderSessionId ?? (!isPending ? sessionId : null);
    final bridge = context.read<BridgeService>();
    if (seenSessionId != null) {
      _unseenCubit.markSeen(
        seenSessionId,
        scopeKey: _connectionUiTargetKey(bridge),
        dataSourceIdentity: bridge.dataSourceIdentity,
        provider: provider?.value,
        durableProviderSessionId: durableProviderSessionId,
      );
    }
    final pendingNotifier = isPending ? pendingSessionCreated : null;
    if (widget.embedded) {
      widget.onSelectWorkspaceSession?.call(
        WorkspaceSessionSelection(
          sessionId: isPending && durableProviderSessionId != null
              ? durableProviderSessionId
              : sessionId,
          durableProviderSessionId: durableProviderSessionId,
          projectPath: projectPath,
          gitBranch: gitBranch,
          worktreePath: worktreePath,
          isPending: isPending,
          provider: provider,
          permissionMode: permissionMode,
          sandboxMode: sandboxMode,
          approvalPolicy: approvalPolicy,
          approvalsReviewer: approvalsReviewer,
          pendingSessionCreated: pendingNotifier,
          dataSourceIdentity: bridge.dataSourceIdentity,
        ),
      );
      return;
    }

    final navigation = context.router.push(switch (provider) {
      Provider.codex => CodexSessionRoute(
        sessionId: sessionId,
        durableProviderSessionId: durableProviderSessionId,
        projectPath: projectPath,
        gitBranch: gitBranch,
        worktreePath: worktreePath,
        isPending: isPending,
        initialSandboxMode: sandboxMode,
        initialPermissionMode: permissionMode,
        initialApprovalPolicy: approvalPolicy,
        initialApprovalsReviewer: approvalsReviewer,
        pendingSessionCreated: pendingNotifier,
        dataSourceIdentity: bridge.dataSourceIdentity,
      ),
      _ => ClaudeSessionRoute(
        sessionId: sessionId,
        durableProviderSessionId: durableProviderSessionId,
        projectPath: projectPath,
        gitBranch: gitBranch,
        worktreePath: worktreePath,
        isPending: isPending,
        initialPermissionMode: permissionMode,
        initialSandboxMode: sandboxMode,
        pendingSessionCreated: pendingNotifier,
        dataSourceIdentity: bridge.dataSourceIdentity,
      ),
    });
    navigation.then((_) {
      if (!mounted) return;
      final isConnected =
          context.read<ConnectionCubit>().state ==
          BridgeConnectionState.connected;
      if (isConnected) {
        _refresh();
      }
    });
  }

  PendingSessionBinding _prepareDurableResume({
    required BridgeService bridge,
    required RecentSession session,
    required Provider provider,
    required String projectPath,
  }) {
    for (final binding in _pendingSessionBindings) {
      if (binding.kind == PendingSessionRequestKind.resume &&
          binding.provider == provider.value &&
          binding.providerSessionId == session.sessionId) {
        return binding;
      }
    }

    final hasQueuedResume = bridge.hasPendingSessionResume(
      sessionId: session.sessionId,
      provider: provider.value,
    );
    final queuedRequestId = hasQueuedResume
        ? bridge.pendingSessionResumeRequestId(
            sessionId: session.sessionId,
            provider: provider.value,
          )
        : null;
    late final PendingSessionBinding binding;
    binding = _registerPendingSessionBinding(
      kind: PendingSessionRequestKind.resume,
      requestId: queuedRequestId ?? _sessionRequestUuid.v4(),
      provider: provider,
      projectPath: projectPath,
      providerSessionId: session.sessionId,
      // Persisted requests created by an older client may not have a
      // correlation id even when the newly connected Bridge supports it.
      allowLegacyFallback: hasQueuedResume && queuedRequestId == null
          ? true
          : null,
      onAttachmentRequested: hasQueuedResume
          ? () async {}
          : () async {
              await SessionResumeCoordinator(
                bridge: bridge,
              ).resume(session, resumeRequestId: binding.requestId);
            },
    );
    return binding;
  }

  void _openDurableResume(
    RecentSession session, {
    required Provider provider,
    required PendingSessionBinding binding,
    required String projectPath,
    String? permissionMode,
    String? sandboxMode,
    String? approvalPolicy,
    String? approvalsReviewer,
  }) {
    _navigateToChat(
      'pending_resume_${binding.requestId}',
      durableProviderSessionId: session.sessionId,
      projectPath: projectPath,
      gitBranch: session.gitBranch,
      isPending: true,
      provider: provider,
      permissionMode: permissionMode ?? session.effectivePermissionMode,
      sandboxMode: sandboxMode ?? session.codexSandboxMode,
      approvalPolicy: approvalPolicy ?? session.codexApprovalPolicy,
      approvalsReviewer: approvalsReviewer ?? session.codexApprovalsReviewer,
      pendingSessionCreated: binding,
    );
  }

  void _resumeSession(RecentSession session) {
    final bridge = context.read<BridgeService>();
    final provider = session.provider == Provider.codex.value
        ? Provider.codex
        : Provider.claude;
    unawaited(
      context.read<ConversationContentSyncService>().markConversationRead(
        provider: provider.value,
        providerSessionId: session.sessionId,
      ),
    );
    final resumeProjectPath = session.resumeCwd?.isNotEmpty == true
        ? session.resumeCwd!
        : session.projectPath;
    final pendingBinding = _prepareDurableResume(
      bridge: bridge,
      session: session,
      provider: provider,
      projectPath: resumeProjectPath,
    );
    _openDurableResume(
      session,
      provider: provider,
      binding: pendingBinding,
      projectPath: resumeProjectPath,
    );
    // Opening a durable conversation is local-only. The binding requests a
    // live runtime exactly once when the user first sends or performs another
    // provider-side action.
  }

  /// Resume session with user-edited settings (from "Edit settings then start")
  void _resumeSessionWithParams(
    RecentSession session,
    NewSessionParams edited,
  ) {
    final bridge = context.read<BridgeService>();
    if (_isResumePending(bridge, session)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).resumeAlreadyQueued),
        ),
      );
      return;
    }
    final resumeProjectPath = session.resumeCwd?.isNotEmpty == true
        ? session.resumeCwd!
        : session.projectPath;
    final isCodex = edited.provider == Provider.codex;
    final requestId = _sessionRequestUuid.v4();
    final pendingBinding = _registerPendingSessionBinding(
      kind: PendingSessionRequestKind.resume,
      requestId: requestId,
      provider: edited.provider,
      projectPath: resumeProjectPath,
      providerSessionId: session.sessionId,
    );
    _openDurableResume(
      session,
      provider: edited.provider,
      binding: pendingBinding,
      projectPath: resumeProjectPath,
      permissionMode: edited.permissionMode.value,
      sandboxMode: edited.sandboxMode?.value,
      approvalPolicy: isCodex ? edited.codexApprovalPolicy.value : null,
      approvalsReviewer: isCodex ? edited.codexApprovalsReviewer : null,
    );
    _trackPendingClaudeDefaultsCorrection(requestId, edited);
    final useCodexProfile =
        isCodex && (edited.codexProfile?.isNotEmpty ?? false);
    final useCodexCustomPermissions =
        isCodex &&
        (useCodexProfile ||
            edited.codexPermissionsMode == CodexPermissionsMode.custom);
    bridge.resumeSession(
      session.sessionId,
      resumeProjectPath,
      permissionMode: isCodex && useCodexProfile
          ? null
          : edited.permissionMode.value,
      executionMode: isCodex && useCodexProfile
          ? null
          : edited.executionMode.value,
      approvalPolicy: isCodex
          ? (useCodexCustomPermissions
                ? null
                : edited.codexApprovalPolicy.value)
          : null,
      approvalsReviewer: isCodex
          ? (useCodexCustomPermissions ? null : edited.codexApprovalsReviewer)
          : null,
      codexPermissionsMode: isCodex
          ? (useCodexCustomPermissions
                ? CodexPermissionsMode.custom.value
                : edited.codexPermissionsMode.value)
          : null,
      planMode: isCodex && useCodexProfile ? null : edited.planMode,
      effort: !isCodex ? edited.claudeEffort?.value : null,
      maxTurns: !isCodex ? edited.claudeMaxTurns : null,
      maxBudgetUsd: !isCodex ? edited.claudeMaxBudgetUsd : null,
      fallbackModel: !isCodex ? edited.claudeFallbackModel : null,
      forkSession: !isCodex ? edited.claudeForkSession : null,
      persistSession: !isCodex ? edited.claudePersistSession : null,
      profile: isCodex ? edited.codexProfile : null,
      provider: session.provider,
      sandboxMode: isCodex && useCodexCustomPermissions
          ? null
          : edited.sandboxMode?.value,
      model: isCodex
          ? (useCodexProfile
                ? null
                : (normalizeCodexModelForAvailableList(
                        edited.model,
                        context.read<BridgeService>().codexModels,
                      ) ??
                      edited.model))
          : edited.claudeModel,
      modelReasoningEffort: isCodex && useCodexProfile
          ? null
          : (isCodex ? edited.modelReasoningEffort?.value : null),
      serviceTier: isCodex ? edited.codexSpeed.value : null,
      networkAccessEnabled: isCodex && useCodexCustomPermissions
          ? null
          : (isCodex ? edited.networkAccessEnabled : null),
      webSearchMode: isCodex && useCodexProfile
          ? null
          : (isCodex ? edited.webSearchMode?.value : null),
      additionalWritableRoots: isCodex && !useCodexCustomPermissions
          ? edited.additionalWritableRoots
          : null,
      resumeRequestId: requestId,
      codexSourceId: isCodex ? session.codexSourceId : null,
    );

    // Persist per-session Claude settings for future resumes.
    if (!isCodex) {
      unawaited(
        saveClaudeSessionSettings(
          session.sessionId,
          _claudeSettingsFromParams(edited),
        ),
      );
    } else {
      unawaited(_saveProjectCodexProfileFromParams(edited));
    }
  }

  bool _isResumePending(BridgeService bridge, RecentSession session) {
    final provider = session.provider ?? Provider.claude.value;
    return _pendingSessionBindings.any(
          (binding) =>
              binding.kind == PendingSessionRequestKind.resume &&
              binding.providerSessionId == session.sessionId &&
              binding.provider == provider,
        ) ||
        bridge.hasPendingSessionResume(
          sessionId: session.sessionId,
          provider: provider,
        );
  }

  bool _hasPendingStart(BridgeService bridge, NewSessionParams params) {
    return _pendingSessionBindings.any(
          (binding) =>
              binding.kind == PendingSessionRequestKind.start &&
              binding.projectPath == params.projectPath &&
              binding.provider == params.provider.value,
        ) ||
        bridge.hasPendingSessionStart(
          projectPath: params.projectPath,
          provider: params.provider.value,
        );
  }

  void _stopSession(String sessionId) {
    context.read<BridgeService>().stopSession(sessionId);
  }

  String? _connectedBridgeLabel({
    required SettingsState settingsState,
    required MachineManagerState? machineState,
  }) {
    if (widget.debugRecentSessions != null) return null;
    if (!settingsState.showBridgeNameInSessionList) return null;

    final machines = machineState?.machines ?? const <MachineWithStatus>[];
    if (machines.length < 2) return null;

    final activeMachineId = settingsState.activeMachineId;
    if (activeMachineId != null) {
      for (final item in machines) {
        if (item.machine.id == activeMachineId) {
          return item.machine.displayName;
        }
      }
    }

    final url = context.read<BridgeService>().lastUrl;
    final machine = _machineForBridgeUrl(machines, url);
    if (machine != null) return machine.displayName;
    return _bridgeLabelFromUrl(url);
  }

  Machine? _machineForBridgeUrl(List<MachineWithStatus> machines, String? url) {
    final uri = _bridgeUri(url);
    if (uri == null) return null;
    final port = uri.hasPort ? uri.port : 8765;
    for (final item in machines) {
      final machine = item.machine;
      if (endpointIdentityKey(machine.host, machine.port) ==
          endpointIdentityKey(uri.host, port)) {
        return machine;
      }
    }
    return null;
  }

  String? _bridgeLabelFromUrl(String? url) {
    final uri = _bridgeUri(url);
    if (uri == null || uri.host.isEmpty) return null;
    final port = uri.hasPort ? uri.port : 8765;
    return formatHostPort(uri.host, port);
  }

  Uri? _bridgeUri(String? url) {
    if (url == null || url.isEmpty) return null;
    return Uri.tryParse(
      url.replaceFirst('ws://', 'http://').replaceFirst('wss://', 'https://'),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Read state from cubits
    final slState = context.watch<SessionListCubit>().state;
    final transportConnectionState = widget.debugRecentSessions != null
        ? BridgeConnectionState.connected
        : context.watch<ConnectionCubit>().state;
    final bridge = context.read<BridgeService>();
    final hasAuthoritativeSessionList =
        widget.debugRecentSessions != null ||
        (!_connectionSelectionPending &&
            bridge.hasAuthoritativeSessionListForCurrentConnection);
    final hasAuthoritativeRecentSessions =
        widget.debugRecentSessions != null ||
        (!_connectionSelectionPending &&
            context.read<SessionListCubit>().hasUsableCatalogForCurrentTarget);
    final connectionState = widget.debugRecentSessions != null
        ? BridgeConnectionState.connected
        : _connectionUiGate.presentationState(
            transportState: transportConnectionState,
            hasAuthoritativeSessionList: hasAuthoritativeSessionList,
            hasAuthoritativeRecentSessions: hasAuthoritativeRecentSessions,
          );
    final sessions = context.watch<ActiveSessionsCubit>().state;
    final recentSessionsList = _factualRecentSessions(
      widget.debugRecentSessions ?? slState.sessions,
    );
    final discoveredServers = context.watch<ServerDiscoveryCubit>().state;

    final showConnectedUI =
        widget.debugRecentSessions != null ||
        _connectionUiGate.shouldShowConnectedUi(connectionState);
    final homeFileDropAvailable = context.select<FileTransferService?, bool>(
      (service) =>
          service != null &&
          service.platformSupported &&
          service.uploadAvailable,
    );

    final l = AppLocalizations.of(context);
    final connectionProgress = bridgeConnectionEntryProgressFor(
      transportState: transportConnectionState,
      selectionPending: _connectionSelectionPending,
      hasAuthoritativeSessionList: hasAuthoritativeSessionList,
      hasAuthoritativeRecentSessions: hasAuthoritativeRecentSessions,
      autoConnecting: _isAutoConnecting,
    );
    final connectionProgressLabel = switch (connectionProgress?.stage) {
      BridgeConnectionEntryStage.loadingSessionStatus => l.loadingSessionStatus,
      BridgeConnectionEntryStage.loadingConversationCatalog =>
        l.loadingConversationCatalog,
      BridgeConnectionEntryStage.preparingTarget ||
      BridgeConnectionEntryStage.connectingTransport => l.connectingToBridge,
      null => null,
    };
    final connectionNoticeLabel = _connectionAttemptFailed
        ? l.bridgeConnectionAttemptFailed
        : _connectionTakingLonger
        ? l.bridgeConnectionTakingLonger
        : null;

    // Try to get MachineManagerCubit if available
    final machineManagerCubit = context.watch<MachineManagerCubit?>();
    final machineState = machineManagerCubit?.state;
    final settingsState = context.watch<SettingsCubit>().state;
    final connectedBridgeLabel = _connectedBridgeLabel(
      settingsState: settingsState,
      machineState: machineState,
    );

    return BlocProvider<UnseenSessionsCubit>.value(
      value: _unseenCubit,
      child: BlocBuilder<UnseenSessionsCubit, Set<String>>(
        builder: (context, unseenSessionIds) =>
            BlocListener<ConnectionCubit, BridgeConnectionState>(
              listener: (context, nextState) {
                _syncConnectionUiGate(bridge, nextState);
              },
              child: CallbackShortcuts(
                bindings: <ShortcutActivator, VoidCallback>{
                  // Cmd+N: New Session
                  const SingleActivator(
                    LogicalKeyboardKey.keyN,
                    meta: true,
                  ): () {
                    if (showConnectedUI) _showNewSessionDialog();
                  },
                  // Cmd+K: Focus search
                  const SingleActivator(
                    LogicalKeyboardKey.keyK,
                    meta: true,
                  ): () {
                    _homeContentKey.currentState?.openSearch();
                  },
                },
                child: Focus(
                  autofocus: true,
                  child: _wrapHomeFileDrop(
                    enabled:
                        isIOSPlatform &&
                        showConnectedUI &&
                        homeFileDropAvailable,
                    child: _buildScaffoldBody(
                      context: context,
                      l: l,
                      showConnectedUI: showConnectedUI,
                      connectionState: connectionState,
                      sessions: sessions,
                      recentSessionsList: recentSessionsList,
                      slState: slState,
                      unseenSessionIds: unseenSessionIds,
                      discoveredServers: discoveredServers,
                      machineState: machineState,
                      machineManagerCubit: machineManagerCubit,
                      connectedBridgeLabel: connectedBridgeLabel,
                      connectionProgressLabel: connectionProgressLabel,
                      connectionProgressValue: connectionProgress?.fraction,
                      connectionNoticeLabel: connectionNoticeLabel,
                      onCancelConnection:
                          connectionProgressLabel != null ||
                              connectionNoticeLabel != null
                          ? _disconnect
                          : null,
                      onRetryConnection:
                          connectionNoticeLabel != null &&
                              _retryConnectionAttempt != null
                          ? () => unawaited(_retryCurrentConnection())
                          : null,
                      onUseCachedCatalog:
                          connectionNoticeLabel != null &&
                              context
                                  .read<SessionListCubit>()
                                  .hasCachedCatalogForCurrentTarget
                          ? _enterWithCachedCatalog
                          : null,
                    ),
                  ),
                ),
              ),
            ),
      ),
    );
  }

  Widget _wrapHomeFileDrop({required bool enabled, required Widget child}) {
    if (!enabled) return child;
    final visible = _homeFileDropActive || _homeFileDropStaging;
    final cs = Theme.of(context).colorScheme;
    final copy = _HomeFileDropCopy.of(context);
    return DropRegion(
      formats: droppedFileFormats,
      hitTestBehavior: HitTestBehavior.opaque,
      onDropOver: (event) => dropSessionContainsFile(event.session)
          ? DropOperation.copy
          : DropOperation.none,
      onDropEnter: (event) {
        if (mounted) {
          setState(
            () => _homeFileDropActive = dropSessionContainsFile(event.session),
          );
        }
      },
      onDropLeave: (_) {
        if (mounted) setState(() => _homeFileDropActive = false);
      },
      onDropEnded: (_) {
        if (mounted) setState(() => _homeFileDropActive = false);
      },
      onPerformDrop: _handleHomeFileDrop,
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          child,
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: visible ? 1 : 0,
                duration: const Duration(milliseconds: 160),
                child: AnimatedScale(
                  scale: visible ? 1 : 0.97,
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOutCubic,
                  child: Container(
                    margin: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: cs.primaryContainer.withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: cs.primary, width: 2),
                    ),
                    alignment: Alignment.center,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _homeFileDropStaging
                              ? Icons.sync_rounded
                              : Icons.computer_rounded,
                          size: 44,
                          color: cs.onPrimaryContainer,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _homeFileDropStaging
                              ? copy.staging
                              : copy.releaseToSend,
                          style: TextStyle(
                            color: cs.onPrimaryContainer,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        if (!_homeFileDropStaging) ...[
                          const SizedBox(height: 6),
                          Text(
                            copy.transportHint,
                            style: TextStyle(
                              color: cs.onPrimaryContainer.withValues(
                                alpha: 0.72,
                              ),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScaffoldBody({
    required BuildContext context,
    required AppLocalizations l,
    required bool showConnectedUI,
    required BridgeConnectionState connectionState,
    required List<SessionInfo> sessions,
    required List<RecentSession> recentSessionsList,
    required SessionListState slState,
    required Set<String> unseenSessionIds,
    required List<DiscoveredServer> discoveredServers,
    required MachineManagerState? machineState,
    required MachineManagerCubit? machineManagerCubit,
    required String? connectedBridgeLabel,
    required String? connectionProgressLabel,
    required double? connectionProgressValue,
    required String? connectionNoticeLabel,
    required VoidCallback? onCancelConnection,
    required VoidCallback? onRetryConnection,
    required VoidCallback? onUseCachedCatalog,
  }) {
    final chrome = resolveWorkspacePaneChrome(
      platform: Theme.of(context).platform,
      isAdaptiveWorkspace: false,
      isLeftPaneVisible: true,
      slot: WorkspacePaneSlot.center,
    );
    final body = _buildBodyContent(
      context: context,
      showConnectedUI: showConnectedUI,
      connectionState: connectionState,
      sessions: sessions,
      recentSessionsList: recentSessionsList,
      slState: slState,
      unseenSessionIds: unseenSessionIds,
      discoveredServers: discoveredServers,
      machineState: machineState,
      machineManagerCubit: machineManagerCubit,
      connectedBridgeLabel: connectedBridgeLabel,
      connectionProgressLabel: connectionProgressLabel,
      connectionProgressValue: connectionProgressValue,
      connectionNoticeLabel: connectionNoticeLabel,
      onCancelConnection: onCancelConnection,
      onRetryConnection: onRetryConnection,
      onUseCachedCatalog: onUseCachedCatalog,
    );

    if (widget.embedded) {
      return Material(
        color: Theme.of(context).colorScheme.surface,
        child: SafeArea(
          bottom: false,
          child: Stack(
            children: [
              Column(
                children: [
                  SessionListPaneHeader(
                    onTitleTap: _onTitleTap,
                    onOpenSettings: _openSettings,
                    onOpenFileBrowser: showConnectedUI
                        ? _openFileBrowser
                        : null,
                    onOpenGallery: showConnectedUI ? _openGallery : null,
                    onOpenArchivedSessions:
                        context
                            .read<BridgeService>()
                            .bridgeCapabilities
                            .contains(codexSessionLifecycleCapability)
                        ? _openArchivedSessions
                        : null,
                    onDisconnect: showConnectedUI ? _disconnect : null,
                    onTogglePaneVisibility: widget.onTogglePaneVisibility,
                    bridgeLabel: connectedBridgeLabel,
                  ),
                  Expanded(child: body),
                ],
              ),
              if (showConnectedUI &&
                  MediaQuery.of(context).viewInsets.bottom == 0)
                Positioned(
                  left: 16,
                  bottom: 16,
                  child: FloatingActionButton.extended(
                    key: const ValueKey('new_session_fab'),
                    onPressed: _showNewSessionDialog,
                    icon: const Icon(Icons.add),
                    label: Text(l.newSession),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: showConnectedUI && !_isAutoConnecting
          ? null
          : chrome.wrapAppBar(
              AppBar(
                toolbarHeight: chrome.toolbarHeight,
                title: GestureDetector(
                  onTap: _onTitleTap,
                  child: Text(l.appTitle),
                ),
                actions: [
                  IconButton(
                    key: const ValueKey('settings_button'),
                    icon: Badge(
                      isLabelVisible:
                          AppUpdateService.instance.cachedUpdate != null,
                      smallSize: 8,
                      child: const Icon(Icons.settings),
                    ),
                    onPressed: _openSettings,
                    tooltip: l.settings,
                  ),
                ],
              ),
            ),
      body: body,
      floatingActionButton:
          showConnectedUI && MediaQuery.of(context).viewInsets.bottom == 0
          ? Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: FloatingActionButton.extended(
                key: const ValueKey('new_session_fab'),
                onPressed: _showNewSessionDialog,
                icon: const Icon(Icons.add),
                label: Text(l.newSession),
              ),
            )
          : null,
    );
  }

  Widget _buildBodyContent({
    required BuildContext context,
    required bool showConnectedUI,
    required BridgeConnectionState connectionState,
    required List<SessionInfo> sessions,
    required List<RecentSession> recentSessionsList,
    required SessionListState slState,
    required Set<String> unseenSessionIds,
    required List<DiscoveredServer> discoveredServers,
    required MachineManagerState? machineState,
    required MachineManagerCubit? machineManagerCubit,
    required String? connectedBridgeLabel,
    required String? connectionProgressLabel,
    required double? connectionProgressValue,
    required String? connectionNoticeLabel,
    required VoidCallback? onCancelConnection,
    required VoidCallback? onRetryConnection,
    required VoidCallback? onUseCachedCatalog,
  }) {
    if (showConnectedUI) {
      final bridge = context.read<BridgeService>();
      final settingsState = context.watch<SettingsCubit>().state;
      final allowedProviderFilters = providerFiltersForEnabledTabs(
        settingsState.newSessionTabs,
      );
      final effectiveProviderFilter = coerceProviderFilter(
        slState.providerFilter,
        allowedProviderFilters,
      );
      if (effectiveProviderFilter != slState.providerFilter) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          context.read<SessionListCubit>().applyEnabledAgents(
            settingsState.newSessionTabs,
          );
        });
      }
      final content = StreamBuilder<List<OfflinePendingAction>>(
        stream: bridge.offlinePendingActionsStream,
        initialData: bridge.offlinePendingActions,
        builder: (context, snapshot) {
          final offlinePendingActions =
              snapshot.data ?? const <OfflinePendingAction>[];
          return RefreshIndicator(
            onRefresh: _refresh,
            child: HomeContent(
              key: _homeContentKey,
              connectionState: connectionState,
              bridgeVersion: bridge.bridgeVersion,
              latestBridgeVersion: machineState?.latestBridgeVersion,
              sessions: sessions,
              offlinePendingActions: offlinePendingActions,
              recentSessions: recentSessionsList,
              accumulatedProjectPaths: slState.accumulatedProjectPaths,
              collapsedProjectPaths: slState.collapsedProjectPaths,
              loadingProjectPaths: slState.loadingProjectPaths,
              exhaustedProjectPaths: slState.exhaustedProjectPaths,
              projectSessionDisplayLimits: slState.projectSessionDisplayLimits,
              pinnedSessionKeys: slState.pinnedSessionKeys,
              pinnedProjectPaths: slState.pinnedProjectPaths,
              searchQuery: slState.searchQuery,
              isLoadingMore: slState.isLoadingMore,
              isInitialLoading: slState.isInitialLoading,
              hasMoreSessions: slState.hasMore,
              archivingSessionIds: _archivePendingRequests.identityKeys,
              unseenSessionIds: unseenSessionIds,
              conversationStatuses: context
                  .read<SessionListCubit>()
                  .conversationStatuses,
              unreadConversationKeys: context
                  .read<SessionListCubit>()
                  .unreadConversationKeys,
              currentProjectFilter: context
                  .read<SessionListCubit>()
                  .currentProjectFilter,
              onNewSession: _showNewSessionDialog,
              onTapRunning:
                  (
                    sessionId, {
                    String? projectPath,
                    String? gitBranch,
                    String? worktreePath,
                    String? provider,
                    String? durableProviderSessionId,
                    String? permissionMode,
                    String? sandboxMode,
                    String? approvalPolicy,
                    String? approvalsReviewer,
                  }) => _navigateToChat(
                    sessionId,
                    projectPath: projectPath,
                    gitBranch: gitBranch,
                    worktreePath: worktreePath,
                    provider: provider == 'codex' ? Provider.codex : null,
                    durableProviderSessionId: durableProviderSessionId,
                    permissionMode: permissionMode,
                    sandboxMode: sandboxMode,
                    approvalPolicy: approvalPolicy,
                    approvalsReviewer: approvalsReviewer,
                  ),
              onStopSession: _stopSession,
              onCancelOfflinePendingAction: (actionId) =>
                  unawaited(bridge.cancelOfflinePendingAction(actionId)),
              onApprovePermission:
                  (sessionId, toolUseId, {bool clearContext = false}) {
                    _sendLiveSessionInteraction(
                      sessionId,
                      toolUseId,
                      ClientMessage.approve(
                        toolUseId,
                        sessionId: sessionId,
                        clearContext: clearContext,
                      ),
                    );
                  },
              onApproveAlways: (sessionId, toolUseId) {
                _sendLiveSessionInteraction(
                  sessionId,
                  toolUseId,
                  ClientMessage.approveAlways(toolUseId, sessionId: sessionId),
                );
              },
              onRejectPermission: (sessionId, toolUseId, {message}) {
                _sendLiveSessionInteraction(
                  sessionId,
                  toolUseId,
                  ClientMessage.reject(
                    toolUseId,
                    message: message,
                    sessionId: sessionId,
                  ),
                );
              },
              onAnswerQuestion: (sessionId, toolUseId, result) {
                _sendLiveSessionInteraction(
                  sessionId,
                  toolUseId,
                  ClientMessage.answer(toolUseId, result, sessionId: sessionId),
                );
              },
              onResumeSession: _resumeSession,
              onToggleRecentSessionPinned: (session) => context
                  .read<SessionListCubit>()
                  .toggleRecentSessionPinned(session),
              onLongPressRecentSession: _showRecentSessionActions,
              onArchiveSession: _archiveSession,
              onLongPressRunningSession: _showRunningSessionActions,
              onToggleRunningSessionPinned: (session) => context
                  .read<SessionListCubit>()
                  .toggleRunningSessionPinned(session),
              onSelectProject: (path) =>
                  context.read<SessionListCubit>().selectProject(path),
              onLoadMore: () => context.read<SessionListCubit>().loadMore(),
              onLoadMoreProject: (path) =>
                  context.read<SessionListCubit>().loadMoreProject(path),
              onToggleProjectCollapsed: (path) => unawaited(
                context.read<SessionListCubit>().toggleProjectCollapsed(path),
              ),
              onToggleProjectPinned: (path) =>
                  context.read<SessionListCubit>().toggleProjectPinned(path),
              providerFilter: effectiveProviderFilter,
              namedOnly: slState.namedOnly,
              onToggleProvider: () => context
                  .read<SessionListCubit>()
                  .toggleProviderFilter(allowedFilters: allowedProviderFilters),
              onToggleNamed: () =>
                  context.read<SessionListCubit>().toggleNamedOnly(),
              appUpdateInfo: _appUpdateInfo,
              onDismissAppUpdate: _dismissAppUpdate,
              showMacOSNativeAppBanner: _showMacOSNativeAppBanner,
              onDismissMacOSNativeAppBanner: _dismissMacOSNativeAppBanner,
              onOpenBridgeSettings: _openBridgeSettings,
              onOpenSupportSettings: _openSupportSettings,
              connectedBridgeLabel: connectedBridgeLabel,
            ),
          );
        },
      );

      if (widget.embedded) {
        return content;
      }

      final chrome = resolveWorkspacePaneChrome(
        platform: Theme.of(context).platform,
        isAdaptiveWorkspace: false,
        isLeftPaneVisible: true,
        slot: WorkspacePaneSlot.center,
      );

      return NestedScrollView(
        headerSliverBuilder: (context, innerBoxIsScrolled) => [
          if (chrome.topInset > 0)
            SliverToBoxAdapter(child: SizedBox(height: chrome.topInset)),
          SessionListSliverAppBar(
            onTitleTap: _onTitleTap,
            onDisconnect: _disconnect,
            onOpenFileBrowser: _openFileBrowser,
            onOpenArchivedSessions:
                bridge.bridgeCapabilities.contains(
                  codexSessionLifecycleCapability,
                )
                ? _openArchivedSessions
                : null,
            forceElevated: innerBoxIsScrolled,
            toolbarHeight: chrome.toolbarHeight,
            bridgeLabel: connectedBridgeLabel,
          ),
        ],
        body: content,
      );
    }

    return _ConnectFormWidget(
      discoveredServers: discoveredServers,
      machines: machineState?.machines ?? [],
      startingMachineId: machineState?.startingMachineId,
      updatingMachineId: machineState?.updatingMachineId,
      latestBridgeVersion: machineState?.latestBridgeVersion,
      isRefreshingMachines: machineState?.isLoading ?? false,
      onScanQrCode: _scanQrCode,
      onViewSetupGuide: () {
        final shell = WorkspaceShellScreen.maybeOf(context);
        if (widget.embedded && shell != null) {
          shell.openSetupGuideCenter();
          return;
        }
        context.router.push(SetupGuideRoute());
      },
      onConnectToDiscovered: _connectToDiscovered,
      onConnectToMachine: _connectToMachine,
      onStartMachine: _startMachine,
      onEditMachine: _editMachine,
      onDeleteMachine: _deleteMachine,
      onToggleFavorite: _toggleFavorite,
      onUpdateMachine: _updateMachine,
      onStopMachine: _stopMachine,
      onAddMachine: _addMachine,
      onRefreshMachines: () => machineManagerCubit?.refreshAll(),
      connectionProgressLabel: connectionProgressLabel,
      connectionProgressValue: connectionProgressValue,
      connectionNoticeLabel: connectionNoticeLabel,
      onCancelConnection: onCancelConnection,
      onRetryConnection: onRetryConnection,
      onUseCachedCatalog: onUseCachedCatalog,
    );
  }

  bool _sendLiveSessionInteraction(
    String sessionId,
    String toolUseId,
    ClientMessage message,
  ) {
    final bridge = context.read<BridgeService>();
    try {
      bridge.send(message);
    } catch (_) {
      return false;
    }
    bridge.markToolUseResponded(sessionId, toolUseId);
    bridge.clearSessionPermission(sessionId);
    return true;
  }

  void _connectToDiscovered(DiscoveredServer server) {
    if (server.authRequired) {
      // Open MachineEditSheet pre-filled with discovered server info
      _addMachineFromDiscovered(server);
      return;
    }
    _connectWithParams(server.wsUrl, null);
  }

  void _addMachineFromDiscovered(DiscoveredServer server) {
    final cubit = context.read<MachineManagerCubit>();
    final uri = Uri.tryParse(
      server.wsUrl
          .replaceFirst('ws://', 'http://')
          .replaceFirst('wss://', 'https://'),
    );
    final host = uri?.host ?? server.name;
    final port = uri?.port ?? 8765;
    final useSsl = uri?.scheme == 'https';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      constraints: macOSModalBottomSheetConstraints(context),
      backgroundColor: Colors.transparent,
      builder: (ctx) => MachineEditSheet(
        machine: Machine(
          id: '',
          host: host,
          port: port,
          name: server.name,
          useSsl: useSsl,
        ),
        onSave:
            ({
              required machine,
              apiKey,
              sshPassword,
              sshPrivateKey,
              sshJumpPassword,
              sshJumpPrivateKey,
            }) async {
              final newMachine = cubit.createNewMachine(
                name: machine.name,
                host: machine.host,
                port: machine.port,
                useSsl: machine.useSsl,
              );
              await cubit.addMachine(
                newMachine.copyWith(
                  useSsl: machine.useSsl,
                  sshEnabled: machine.sshEnabled,
                  sshUsername: machine.sshUsername,
                  sshPort: machine.sshPort,
                  sshAuthType: machine.sshAuthType,
                  sshJumpHost: machine.sshJumpHost,
                  sshJumpPort: machine.sshJumpPort,
                  sshJumpUsername: machine.sshJumpUsername,
                  sshJumpAuthType: machine.sshJumpAuthType,
                  isFavorite: true,
                ),
                apiKey: apiKey,
                sshPassword: sshPassword,
                sshPrivateKey: sshPrivateKey,
                sshJumpPassword: sshJumpPassword,
                sshJumpPrivateKey: sshJumpPrivateKey,
              );
            },
        onSaveAndConnect: (machine, apiKey) {
          _connectWithParams(machine.wsUrl, apiKey);
        },
        onTestConnection: cubit.testConnectionWithCredentials,
      ),
    );
  }

  // ---- Machine Management ----

  void _connectToMachine(MachineWithStatus m) async {
    await _connectToMachineConfig(m.machine);
  }

  Future<void> _connectToMachineConfig(
    Machine machine, {
    bool autoConnecting = false,
  }) async {
    final attempt = _beginConnectionAttempt(
      retry: () =>
          _connectToMachineConfig(machine, autoConnecting: autoConnecting),
      autoConnecting: autoConnecting,
    );
    final cubit = context.read<MachineManagerCubit>();
    final bridge = context.read<BridgeService>();
    final tunnelService = context.read<SshBridgeTunnelService?>();
    final messenger = ScaffoldMessenger.of(context);
    unawaited(cubit.refreshLatestBridgeVersionIfStale());
    late final String wsUrl;
    try {
      wsUrl = await cubit.buildWsUrl(
        machine.id,
        promptForPassword: () => _promptForPassword(machine.displayName),
      );
    } catch (e) {
      if (_isCurrentConnectionAttempt(attempt)) {
        messenger.showSnackBar(SnackBar(content: Text(e.toString())));
        _failConnectionAttemptAndRestore(attempt);
      }
      return;
    }
    if (!_isCurrentConnectionAttempt(attempt)) return;
    try {
      final apiKey = await cubit.getApiKey(machine.id);
      if (!_isCurrentConnectionAttempt(attempt)) return;

      // Record connection to update lastConnected
      await cubit.recordConnection(
        host: machine.host,
        port: machine.port,
        apiKey: apiKey,
        useSsl: machine.useSsl,
      );

      if (!_isCurrentConnectionAttempt(attempt)) return;
      bridge.connect(
        wsUrl,
        logicalConnectionIdentity: 'machine:${machine.id}',
        expectedBridgeInstanceId: machine.bridgeInstanceId,
        expectedCodexSourceId: machine.codexSourceId,
      );
    } catch (e) {
      if (_isCurrentConnectionAttempt(attempt)) {
        messenger.showSnackBar(SnackBar(content: Text(e.toString())));
        _failConnectionAttemptAndRestore(attempt);
      }
      return;
    }
    bridge.savePreferences(machine.wsUrl);
    if (tunnelService != null) {
      unawaited(tunnelService.closeAllExcept(machine.id));
    }
    _armConnectionReadinessWarning(attempt);
  }

  void _toggleFavorite(MachineWithStatus m) {
    context.read<MachineManagerCubit>().toggleFavorite(m.machine.id);
  }

  void _updateMachine(MachineWithStatus m) async {
    final cubit = context.read<MachineManagerCubit>();
    final l = AppLocalizations.of(context);

    String? password;
    if (m.machine.sshAuthType == SshAuthType.password) {
      final savedPassword = await cubit.getSshPassword(m.machine.id);
      password = savedPassword;
      if (password == null || password.isEmpty) {
        password = await _promptForPassword(m.machine.displayName);
        if (password == null) return; // User cancelled
      }
    }

    final success = await cubit.updateBridge(m.machine.id, password: password);

    if (success && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.bridgeServerUpdated)));
    } else if (mounted) {
      final error = cubit.state.error;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error ?? l.failedToUpdateServer)));
    }
  }

  void _startMachine(MachineWithStatus m) async {
    final cubit = context.read<MachineManagerCubit>();
    final l = AppLocalizations.of(context);

    String? password;
    if (m.machine.sshAuthType == SshAuthType.password) {
      final savedPassword = await cubit.getSshPassword(m.machine.id);
      password = savedPassword;
      if (password == null || password.isEmpty) {
        password = await _promptForPassword(m.machine.displayName);
        if (password == null) return; // User cancelled
      }
    }

    final success = await cubit.startBridge(m.machine.id, password: password);

    if (success && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.bridgeServerStarted)));
    } else if (mounted) {
      final error = cubit.state.error;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error ?? l.failedToStartServer)));
    }
  }

  void _stopMachine(MachineWithStatus m) async {
    final cubit = context.read<MachineManagerCubit>();
    final l = AppLocalizations.of(context);

    String? password;
    if (m.machine.sshAuthType == SshAuthType.password) {
      final savedPassword = await cubit.getSshPassword(m.machine.id);
      password = savedPassword;
      if (password == null || password.isEmpty) {
        password = await _promptForPassword(m.machine.displayName);
        if (password == null) return; // User cancelled
      }
    }

    final success = await cubit.stopBridge(m.machine.id, password: password);

    if (success && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.bridgeServerStopped)));
    } else if (mounted) {
      final error = cubit.state.error;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error ?? l.failedToStopServer)));
    }
  }

  Future<String?> _promptForPassword(String machineName) async {
    final controller = TextEditingController();
    final l = AppLocalizations.of(context);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.sshPassword),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l.sshPasswordPrompt(machineName)),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              obscureText: true,
              autofocus: true,
              decoration: InputDecoration(
                labelText: l.password,
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (v) => Navigator.pop(ctx, v),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: Text(l.connect),
          ),
        ],
      ),
    );
  }

  void _editMachine(MachineWithStatus m) async {
    final cubit = context.read<MachineManagerCubit>();
    final apiKey = await cubit.getApiKey(m.machine.id);
    final sshPassword = await cubit.getSshPassword(m.machine.id);
    final sshPrivateKey = await cubit.getSshPrivateKey(m.machine.id);
    final sshJumpPassword = await cubit.getSshJumpPassword(m.machine.id);
    final sshJumpPrivateKey = await cubit.getSshJumpPrivateKey(m.machine.id);

    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      constraints: macOSModalBottomSheetConstraints(context),
      backgroundColor: Colors.transparent,
      builder: (ctx) => MachineEditSheet(
        machine: m.machine,
        existingApiKey: apiKey,
        existingSshPassword: sshPassword,
        existingSshPrivateKey: sshPrivateKey,
        existingSshJumpPassword: sshJumpPassword,
        existingSshJumpPrivateKey: sshJumpPrivateKey,
        onSave:
            ({
              required machine,
              apiKey,
              sshPassword,
              sshPrivateKey,
              sshJumpPassword,
              sshJumpPrivateKey,
            }) async {
              await cubit.updateMachine(
                machine,
                apiKey: apiKey,
                sshPassword: sshPassword,
                sshPrivateKey: sshPrivateKey,
                sshJumpPassword: sshJumpPassword,
                sshJumpPrivateKey: sshJumpPrivateKey,
                clearCredentials:
                    !machine.sshEnabled ||
                    machine.sshAuthType != m.machine.sshAuthType,
                clearJumpCredentials:
                    machine.sshJumpHost == null ||
                    machine.sshJumpAuthType != m.machine.sshJumpAuthType,
              );
            },
        onTestConnection: cubit.testConnectionWithCredentials,
      ),
    );
  }

  void _deleteMachine(MachineWithStatus m) async {
    final l = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.deleteMachine),
        content: Text(l.deleteMachineConfirm(m.machine.displayName)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.delete),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      context.read<MachineManagerCubit>().deleteMachine(m.machine.id);
    }
  }

  void _addMachine() {
    final cubit = context.read<MachineManagerCubit>();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      constraints: macOSModalBottomSheetConstraints(context),
      backgroundColor: Colors.transparent,
      builder: (ctx) => MachineEditSheet(
        onSave:
            ({
              required machine,
              apiKey,
              sshPassword,
              sshPrivateKey,
              sshJumpPassword,
              sshJumpPrivateKey,
            }) async {
              final newMachine = cubit.createNewMachine(
                name: machine.name,
                host: machine.host,
                port: machine.port,
                useSsl: machine.useSsl,
              );
              await cubit.addMachine(
                newMachine.copyWith(
                  useSsl: machine.useSsl,
                  sshEnabled: machine.sshEnabled,
                  sshUsername: machine.sshUsername,
                  sshPort: machine.sshPort,
                  sshAuthType: machine.sshAuthType,
                  sshJumpHost: machine.sshJumpHost,
                  sshJumpPort: machine.sshJumpPort,
                  sshJumpUsername: machine.sshJumpUsername,
                  sshJumpAuthType: machine.sshJumpAuthType,
                  isFavorite: true, // New manually added machines are favorites
                ),
                apiKey: apiKey,
                sshPassword: sshPassword,
                sshPrivateKey: sshPrivateKey,
                sshJumpPassword: sshJumpPassword,
                sshJumpPrivateKey: sshJumpPrivateKey,
              );
            },
        onSaveAndConnect: (machine, apiKey) {
          _connectWithParams(machine.wsUrl, apiKey);
        },
        onTestConnection: cubit.testConnectionWithCredentials,
      ),
    );
  }
}

class _HomeFileDropCopy extends FileTransferStrings {
  _HomeFileDropCopy(super.languageTag);
  factory _HomeFileDropCopy.of(BuildContext context) =>
      _HomeFileDropCopy(Localizations.localeOf(context).toLanguageTag());

  String get staging => addingToTransferQueue;
  String get transportHint => secureConnectionTransferHint;
  String get unableToRead => droppedFileUnreadable;
  String sent(String filename) => sentToMac(filename);
  String paused(String filename) => transferPaused(filename);
  String failedToSend(String filename) => sendFailed(filename);
  String failedWithError(String filename, Object error) =>
      '${failedToSend(filename)} $error';
}

class _SetupStep extends StatelessWidget {
  final String number;
  final String title;
  final String command;

  const _SetupStep({
    required this.number,
    required this.title,
    required this.command,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 10,
            backgroundColor: cs.primaryContainer,
            child: Text(
              number,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: cs.onPrimaryContainer,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontSize: 13)),
                const SizedBox(height: 2),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    command,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ConnectFormWidget extends StatelessWidget {
  final List<DiscoveredServer> discoveredServers;
  final List<MachineWithStatus> machines;
  final String? startingMachineId;
  final String? updatingMachineId;
  final String? latestBridgeVersion;
  final bool isRefreshingMachines;
  final VoidCallback onScanQrCode;
  final VoidCallback onViewSetupGuide;
  final ValueChanged<DiscoveredServer> onConnectToDiscovered;
  final ValueChanged<MachineWithStatus> onConnectToMachine;
  final ValueChanged<MachineWithStatus> onStartMachine;
  final ValueChanged<MachineWithStatus> onEditMachine;
  final ValueChanged<MachineWithStatus> onDeleteMachine;
  final ValueChanged<MachineWithStatus> onToggleFavorite;
  final ValueChanged<MachineWithStatus> onUpdateMachine;
  final ValueChanged<MachineWithStatus> onStopMachine;
  final VoidCallback onAddMachine;
  final VoidCallback? onRefreshMachines;
  final String? connectionProgressLabel;
  final double? connectionProgressValue;
  final String? connectionNoticeLabel;
  final VoidCallback? onCancelConnection;
  final VoidCallback? onRetryConnection;
  final VoidCallback? onUseCachedCatalog;

  const _ConnectFormWidget({
    required this.discoveredServers,
    required this.machines,
    this.startingMachineId,
    this.updatingMachineId,
    this.latestBridgeVersion,
    this.isRefreshingMachines = false,
    required this.onScanQrCode,
    required this.onViewSetupGuide,
    required this.onConnectToDiscovered,
    required this.onConnectToMachine,
    required this.onStartMachine,
    required this.onEditMachine,
    required this.onDeleteMachine,
    required this.onToggleFavorite,
    required this.onUpdateMachine,
    required this.onStopMachine,
    required this.onAddMachine,
    this.onRefreshMachines,
    this.connectionProgressLabel,
    this.connectionProgressValue,
    this.connectionNoticeLabel,
    this.onCancelConnection,
    this.onRetryConnection,
    this.onUseCachedCatalog,
  });

  @override
  Widget build(BuildContext context) {
    return ConnectForm(
      discoveredServers: discoveredServers,
      onScanQrCode: onScanQrCode,
      onViewSetupGuide: onViewSetupGuide,
      onConnectToDiscovered: onConnectToDiscovered,
      // Machine management
      machines: machines,
      startingMachineId: startingMachineId,
      updatingMachineId: updatingMachineId,
      latestBridgeVersion: latestBridgeVersion,
      isRefreshingMachines: isRefreshingMachines,
      onConnectToMachine: onConnectToMachine,
      onStartMachine: onStartMachine,
      onEditMachine: onEditMachine,
      onDeleteMachine: onDeleteMachine,
      onToggleFavorite: onToggleFavorite,
      onUpdateMachine: onUpdateMachine,
      onStopMachine: onStopMachine,
      onAddMachine: onAddMachine,
      onRefreshMachines: onRefreshMachines,
      connectionProgressLabel: connectionProgressLabel,
      connectionProgressValue: connectionProgressValue,
      connectionNoticeLabel: connectionNoticeLabel,
      onCancelConnection: onCancelConnection,
      onRetryConnection: onRetryConnection,
      onUseCachedCatalog: onUseCachedCatalog,
    );
  }
}
