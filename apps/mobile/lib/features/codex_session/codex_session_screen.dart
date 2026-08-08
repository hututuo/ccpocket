import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:auto_route/auto_route.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../../constants/feature_flags.dart';
import '../../hooks/use_app_resume_callback.dart';
import '../../hooks/use_keyboard_scroll_adjustment.dart';
import '../../hooks/use_scroll_tracking.dart';
import '../../l10n/app_localizations.dart';
import '../../models/bridge_data_source_identity.dart';
import '../../models/messages.dart';
import '../../models/notification_preferences.dart';
import '../../providers/bridge_cubits.dart';
import '../../providers/machine_manager_cubit.dart';
import '../../router/session_stack_navigation.dart';
import '../../services/bridge_service.dart';
import '../../widgets/rename_session_dialog.dart';
import '../../services/chat_message_handler.dart';
import '../../services/draft_service.dart';
import '../../utils/composer_tokens.dart';
import '../../utils/codex_plan_update.dart';
import '../../services/notification_service.dart';
import '../../widgets/session_name_title.dart';
import '../../widgets/workspace_pane_chrome.dart';
import '../../utils/diff_parser.dart';
import '../../utils/network_endpoint.dart';
import '../../utils/terminal_launcher.dart';
import '../settings/state/settings_cubit.dart';
import '../../widgets/new_session_sheet.dart'
    show permissionModeFromRaw, sandboxModeFromRaw;
import '../session_list/pending_session_binding.dart';
import '../session_list/services/session_resume_coordinator.dart';
import '../session_list/state/session_list_cubit.dart';
import '../session_list/workspace_shell_screen.dart';
import '../conversation_content_sync/conversation_content_sync_service.dart';
import '../conversation_content_sync/conversation_route_focus_restorer.dart';
import '../codex_action_broker/codex_action_broker_interaction_frame.dart';
import '../codex_action_broker/codex_action_broker_service.dart';
import '../codex_core_actions/codex_core_actions_controller.dart';
import '../codex_core_actions/codex_core_actions_strings.dart';
import '../session_list/cache/session_catalog_cache_repository.dart';
import '../local_session_features/host/local_session_feature.dart';
import '../local_session_features/host/local_session_feature_host.dart';
import '../side_chat/state/ephemeral_side_chat_registry_service.dart';
import '../side_chat/widgets/auxiliary_floating_dock.dart';
import '../session_link/widgets/session_unavailable_view.dart';
import '../../widgets/approval_bar.dart';
import '../../widgets/bubbles/ask_user_question_widget.dart';
import '../../widgets/screenshot_sheet.dart';
import '../../widgets/plan_detail_sheet.dart';
import '../chat_session/state/chat_session_cubit.dart';
import '../chat_session/state/chat_session_state.dart';
import '../../theme/app_theme.dart';
import '../chat_session/state/streaming_state_cubit.dart';
import '../chat_session/widgets/chat_input_with_overlays.dart';
import '../chat_session/widgets/bottom_overlay_layout.dart';
import '../chat_session/widgets/chat_message_list.dart';
import '../chat_session/widgets/durable_session_preview.dart';
import '../chat_session/widgets/reconnect_banner.dart';
import '../chat_session/widgets/scroll_to_bottom_button.dart';
import '../chat_session/widgets/session_mode_bar.dart';
import '../chat_session/widgets/status_line_flexible_space.dart';
import '../explore/state/explore_state.dart';
import '../git/state/git_status_cubit.dart';
import '../git/state/git_view_cache_service.dart';
import '../../router/app_router.dart';
import '../claude_session/widgets/rewind_message_list_sheet.dart'
    show UserMessageHistoryLoaderSheet;
import 'state/codex_session_cubit.dart';
import 'widgets/codex_goal_card.dart';
import 'widgets/codex_goal_management.dart';
import 'widgets/codex_rewind_dialog.dart';
import 'widgets/tool_suggestion_card.dart';

const _fileListRefreshToolNames = {
  'Edit',
  'FileEdit',
  'MultiEdit',
  'Write',
  'NotebookEdit',
  'Bash',
};

const _durableAttachmentRequestUuid = Uuid();

class _NoopListenable implements Listenable {
  const _NoopListenable();

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}

/// Codex-specific chat screen.
///
/// Simpler than [ClaudeSessionScreen].
/// Shares UI components (`ChatMessageList`, `ChatInputWithOverlays`, etc.)
/// via [CodexSessionCubit] which extends [ChatSessionCubit].
@RoutePage()
class CodexSessionScreen extends StatefulWidget {
  final String sessionId;
  final String? projectPath;
  final String? gitBranch;
  final String? worktreePath;
  final bool isPending;
  final String? durableProviderSessionId;
  final String? initialSandboxMode;
  final String? initialPermissionMode;
  final String? initialApprovalPolicy;
  final String? initialApprovalsReviewer;
  final VoidCallback? onBackToSessions;
  final bool hideSessionBackButton;
  final bool hideAuxiliaryDock;
  final BridgeDataSourceIdentity? dataSourceIdentity;

  /// Auxiliary child conversations reuse the full Codex screen, but can
  /// selectively hide operations that the child-session workflow does not
  /// support. All ordinary session screens keep Fork enabled by default.
  final bool allowMessageFork;

  /// Notifier from the parent that may already hold a [SystemMessage]
  /// with subtype `session_created` (race condition fix).
  final ValueNotifier<SystemMessage?>? pendingSessionCreated;

  const CodexSessionScreen({
    super.key,
    required this.sessionId,
    this.projectPath,
    this.gitBranch,
    this.worktreePath,
    this.isPending = false,
    this.durableProviderSessionId,
    this.initialSandboxMode,
    this.initialPermissionMode,
    this.initialApprovalPolicy,
    this.initialApprovalsReviewer,
    this.pendingSessionCreated,
    this.onBackToSessions,
    this.hideSessionBackButton = false,
    this.hideAuxiliaryDock = false,
    this.dataSourceIdentity,
    this.allowMessageFork = true,
  });

  @override
  State<CodexSessionScreen> createState() => _CodexSessionScreenState();
}

@RoutePage(name: 'WorkspaceCodexSessionRoute')
class WorkspaceCodexSessionScreen extends StatelessWidget {
  final String sessionId;
  final String? projectPath;
  final String? gitBranch;
  final String? worktreePath;
  final bool isPending;
  final String? initialSandboxMode;
  final String? initialPermissionMode;
  final String? initialApprovalPolicy;
  final String? initialApprovalsReviewer;
  final ValueNotifier<SystemMessage?>? pendingSessionCreated;
  final VoidCallback? onBackToSessions;
  final bool hideSessionBackButton;

  const WorkspaceCodexSessionScreen({
    super.key,
    required this.sessionId,
    this.projectPath,
    this.gitBranch,
    this.worktreePath,
    this.isPending = false,
    this.initialSandboxMode,
    this.initialPermissionMode,
    this.initialApprovalPolicy,
    this.initialApprovalsReviewer,
    this.pendingSessionCreated,
    this.onBackToSessions,
    this.hideSessionBackButton = false,
  });

  @override
  Widget build(BuildContext context) {
    return CodexSessionScreen(
      sessionId: sessionId,
      projectPath: projectPath,
      gitBranch: gitBranch,
      worktreePath: worktreePath,
      isPending: isPending,
      initialSandboxMode: initialSandboxMode,
      initialPermissionMode: initialPermissionMode,
      initialApprovalPolicy: initialApprovalPolicy,
      initialApprovalsReviewer: initialApprovalsReviewer,
      pendingSessionCreated: pendingSessionCreated,
      onBackToSessions: onBackToSessions,
      hideSessionBackButton: hideSessionBackButton,
    );
  }
}

class _CodexSessionScreenState extends State<CodexSessionScreen> {
  late String _sessionId;
  late String? _projectPath;
  late String? _gitBranch;
  late String? _worktreePath;
  late bool _isPending;
  var _explorerCurrentPath = '';
  List<String> _recentPeekedFiles = const [];
  SandboxMode? _sandboxMode;
  PermissionMode? _permissionMode;
  CodexApprovalPolicy? _codexApprovalPolicy;
  String? _codexApprovalsReviewer;
  CodexPermissionsMode? _codexPermissionsMode;
  StreamSubscription<ServerMessage>? _sandboxRestartSub;
  StreamSubscription<String>? _sessionStoppedSub;
  StreamSubscription<ConversationContentCacheUpdate>? _cachedPreviewSub;
  StreamSubscription<List<SessionInfo>>? _identitySessionListSub;
  StreamSubscription<List<RecentSession>>? _identityRecentSessionsSub;
  StreamSubscription<void>? _identityCatalogSnapshotSub;
  ConversationHotWindowSnapshot? _cachedPreview;
  Object? _cachedPreviewLoadError;
  bool _cachedPreviewErrorSnackbarVisible = false;
  bool _loadingCachedPreview = false;
  bool _cachedPreviewDirty = false;
  String? _expectedCacheTargetFingerprint;
  String? _cachedPreviewTargetFingerprint;
  String? _loadingCachedPreviewTargetFingerprint;
  ChatComposerSubmission? _deferredSubmission;
  PendingSessionBinding? _retainedPendingBinding;
  PendingSessionBinding? _localAttachmentBinding;
  bool _durableRuntimeBindingAmbiguous = false;
  final Object _sessionRouteOwner = Object();
  Object? _sessionRouteIdentity;
  late BridgeDataSourceIdentity _dataSourceIdentity;
  late final DraftService _draftService;

  @override
  void initState() {
    super.initState();
    final bridge = context.read<BridgeService>();
    _draftService = context.read<DraftService>();
    _dataSourceIdentity =
        widget.dataSourceIdentity ?? bridge.dataSourceIdentity;
    _sessionId = widget.sessionId;
    _projectPath = widget.projectPath;
    _gitBranch = widget.gitBranch;
    _worktreePath = widget.worktreePath;
    _isPending = widget.isPending;
    _sandboxMode = sandboxModeFromRaw(widget.initialSandboxMode);
    _permissionMode = permissionModeFromRaw(widget.initialPermissionMode);
    _codexApprovalPolicy = codexApprovalPolicyFromRaw(
      widget.initialApprovalPolicy,
    );
    _codexApprovalsReviewer = widget.initialApprovalsReviewer;
    _restoreDeferredSubmission();
    final explorerHistory = bridge.getExplorerHistory(_sessionId);
    _explorerCurrentPath = explorerHistory.currentPath;
    _recentPeekedFiles = explorerHistory.recentPeekedFiles;

    if (_isPending) {
      _listenForSessionCreated();
    }
    _startDurablePreview();
    _listenForSandboxRestart();
    _listenForSessionStopped();
    _listenForAuthoritativeDataSourceIdentity(bridge);
  }

  void _listenForAuthoritativeDataSourceIdentity(BridgeService bridge) {
    _identitySessionListSub = bridge.sessionList.listen((sessions) {
      _reconcileAuthoritativeDataSourceIdentity(bridge);
      _reconcileDurableLiveRuntime(bridge, sessions);
      _requestRestoredDeferredAttachmentIfReady();
    });
    _identityRecentSessionsSub = bridge.recentSessionsStream.listen((_) {
      _reconcileAuthoritativeDataSourceIdentity(bridge);
      _reconcileDurableLiveRuntime(bridge, bridge.sessions);
      _requestRestoredDeferredAttachmentIfReady();
    });
    try {
      final sessionList = context.read<SessionListCubit>();
      _identityCatalogSnapshotSub = sessionList.catalogSnapshotChanges.listen((
        _,
      ) {
        if (!mounted) return;
        _reconcileAuthoritativeDataSourceIdentity(bridge);
        _reconcileDurableLiveRuntime(bridge, bridge.sessions);
        _requestRestoredDeferredAttachmentIfReady();
      });
    } catch (_) {
      // Official/isolated widget hosts may omit the optional v2 projection.
    }
    _reconcileAuthoritativeDataSourceIdentity(bridge);
    _reconcileDurableLiveRuntime(bridge, bridge.sessions);
    _requestRestoredDeferredAttachmentIfReady();
  }

  /// Keeps the transient runtime handle of a durable Codex page aligned with
  /// the current authoritative session snapshot.
  ///
  /// A v2 status can arrive before the matching runtime row (or Desktop can
  /// start/replace the runtime while this page is already open). The durable
  /// provider thread remains the page identity, while this handle is rebound
  /// only when exactly one current-source runtime proves that identity.
  void _reconcileDurableLiveRuntime(
    BridgeService bridge,
    List<SessionInfo> sessions,
  ) {
    if (!mounted || !bridge.hasAuthoritativeSessionListForCurrentConnection) {
      return;
    }
    final durableId = widget.durableProviderSessionId?.trim();
    if (durableId == null || durableId.isEmpty) return;

    final authenticatedIdentity = bridge.dataSourceIdentity;
    if (!_dataSourceIdentity.isSatisfiedBy(
      authenticatedIdentity,
      provider: Provider.codex.value,
    )) {
      _applyDurableLiveRuntimeBinding(
        bridge,
        runtimeSessionId: null,
        ambiguous: false,
      );
      return;
    }

    final candidatesById = <String, SessionInfo>{};
    for (final session in sessions) {
      if (session.provider != Provider.codex.value) continue;
      final providerThreadId = session.claudeSessionId?.trim();
      final provesDurableIdentity =
          providerThreadId == durableId ||
          ((providerThreadId == null || providerThreadId.isEmpty) &&
              session.id == durableId);
      if (provesDurableIdentity) {
        candidatesById[session.id] = session;
      }
    }

    final candidates = candidatesById.values.toList(growable: false);
    _applyDurableLiveRuntimeBinding(
      bridge,
      runtimeSessionId: candidates.length == 1 ? candidates.single.id : null,
      ambiguous: candidates.length > 1,
    );
  }

  void _applyDurableLiveRuntimeBinding(
    BridgeService bridge, {
    required String? runtimeSessionId,
    required bool ambiguous,
  }) {
    final normalized = runtimeSessionId?.trim();
    final nextRuntimeId = normalized == null || normalized.isEmpty
        ? null
        : normalized;
    final currentRuntimeId = _isPending ? null : _sessionId;
    if (currentRuntimeId == nextRuntimeId &&
        _durableRuntimeBindingAmbiguous == ambiguous) {
      return;
    }

    if (nextRuntimeId == null) {
      setState(() {
        _durableRuntimeBindingAmbiguous = ambiguous;
        _isPending = true;
      });
      _syncSessionRouteIdentity();
      return;
    }

    if (currentRuntimeId != null && currentRuntimeId != nextRuntimeId) {
      bridge.migrateExplorerHistory(currentRuntimeId, nextRuntimeId);
    }
    final explorerHistory = bridge.getExplorerHistory(nextRuntimeId);
    setState(() {
      _durableRuntimeBindingAmbiguous = false;
      _sessionId = nextRuntimeId;
      _isPending = false;
      _explorerCurrentPath = explorerHistory.currentPath;
      _recentPeekedFiles = explorerHistory.recentPeekedFiles;
    });
    _syncSessionRouteIdentity();
  }

  void _reconcileAuthoritativeDataSourceIdentity(BridgeService bridge) {
    if (!mounted || !bridge.hasAuthoritativeSessionListForCurrentConnection) {
      return;
    }
    final durableId = widget.durableProviderSessionId?.trim();
    final providerSessionId = durableId == null || durableId.isEmpty
        ? _sessionId
        : durableId;
    final runtimeConfirmsThread = bridge.sessions.any(
      (session) =>
          session.provider == Provider.codex.value &&
          (session.id == _sessionId ||
              session.claudeSessionId == providerSessionId),
    );
    final catalogConfirmsThread =
        bridge.hasAuthoritativeRecentSessionsForCurrentConnection &&
        bridge.recentSessions.any(
          (session) =>
              session.provider == Provider.codex.value &&
              session.sessionId == providerSessionId,
        );
    final projectedCatalogConfirmsThread =
        _currentProjectedDurableSession(bridge, providerSessionId) != null;
    if (!runtimeConfirmsThread &&
        !catalogConfirmsThread &&
        !projectedCatalogConfirmsThread) {
      return;
    }

    final authenticatedIdentity = bridge.dataSourceIdentity;
    final next = _dataSourceIdentity.reconciledWithAuthenticated(
      authenticatedIdentity,
      provider: Provider.codex.value,
      allowProvisionalRouteUpgrade: true,
    );
    if (!next.isSatisfiedBy(
      authenticatedIdentity,
      provider: Provider.codex.value,
    )) {
      // Keep the already-rendered offline snapshot, but never reload it from
      // a different authenticated Bridge/Codex source that happens to contain
      // the same durable thread id.
      return;
    }
    final previousIdentity = _dataSourceIdentity;
    if (next != previousIdentity) {
      setState(() => _dataSourceIdentity = next);
      _syncSessionRouteIdentity();
      final shell = WorkspaceShellScreen.maybeOf(context);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            _dataSourceIdentity != next ||
            !next.isSatisfiedBy(
              bridge.dataSourceIdentity,
              provider: Provider.codex.value,
            )) {
          return;
        }
        shell?.reconcileSelectedSessionDataSourceIdentity(
          provider: Provider.codex,
          routeIdentitySessionId: providerSessionId,
          previousIdentity: previousIdentity,
          authenticatedIdentity: authenticatedIdentity,
        );
      });
    }
    // The route may already carry the same canonical identity as a cache
    // hint. The service itself still used a provisional route target before
    // authentication, so identity equality alone cannot suppress this check.
    _reloadDurablePreviewForCurrentTarget();
  }

  /// Resolves the exact v2 catalog row for the authenticated Bridge/source.
  ///
  /// The legacy `recentSessions` list is intentionally bounded and may not
  /// contain a durable conversation already rendered from the v2 SQLite
  /// catalog. Falling back to that legacy list made first-send attachment fail
  /// for otherwise valid cached conversations. The source fingerprint fence
  /// keeps equal thread ids from another Codex Home from being resumed.
  RecentSession? _currentProjectedDurableSession(
    BridgeService bridge,
    String providerSessionId,
  ) {
    try {
      final sessionList = context.read<SessionListCubit>();
      final projectionFingerprint = sessionList.conversationSourceFingerprint;
      if (projectionFingerprint == null || projectionFingerprint.isEmpty) {
        return null;
      }
      final sync = context.read<ConversationContentSyncService>();
      final authenticatedFingerprint = sync.cacheTargetFingerprintForDataSource(
        bridge.dataSourceIdentity,
      );
      if (projectionFingerprint != authenticatedFingerprint) return null;
      return sessionList.conversationMetadataFor(
        Provider.codex.value,
        providerSessionId,
      );
    } catch (_) {
      // Official/isolated widget hosts may omit the optional v2 projection.
      return null;
    }
  }

  void _startDurablePreview() {
    final durableId = widget.durableProviderSessionId;
    if (durableId == null || durableId.isEmpty) return;
    try {
      final sync = context.read<ConversationContentSyncService>();
      _expectedCacheTargetFingerprint = sync
          .cacheTargetFingerprintForDataSource(_dataSourceIdentity);
      if (sync.matchesCurrentDataSource(
        _dataSourceIdentity,
        provider: Provider.codex.value,
      )) {
        sync.setFocusedConversation(
          provider: Provider.codex.value,
          providerSessionId: durableId,
        );
      }
      _cachedPreviewSub = sync.updates
          .where(
            (update) =>
                update.targetFingerprint == _expectedCacheTargetFingerprint &&
                update.provider == Provider.codex.value &&
                update.providerSessionId == durableId,
          )
          .listen((_) => _loadDurablePreview());
      _loadDurablePreview();
    } catch (_) {
      // Official/isolated widget hosts may not provide the optional cache.
    }
  }

  void _restoreDurableConversationFocusIfCurrentSource() {
    final durableId = widget.durableProviderSessionId?.trim();
    if (durableId == null || durableId.isEmpty) return;
    try {
      final sync = context.read<ConversationContentSyncService>();
      if (!sync.matchesCurrentDataSource(
        _dataSourceIdentity,
        provider: Provider.codex.value,
      )) {
        return;
      }
      sync.setFocusedConversation(
        provider: Provider.codex.value,
        providerSessionId: durableId,
      );
    } catch (_) {
      // Official/isolated hosts may omit the optional cache service.
    }
  }

  void _reloadDurablePreviewForCurrentTarget() {
    final durableId = widget.durableProviderSessionId;
    if (durableId == null || durableId.isEmpty) return;
    ConversationContentSyncService sync;
    try {
      sync = context.read<ConversationContentSyncService>();
    } catch (_) {
      return;
    }
    if (sync.hasAuthoritativeDataSourceConflict(
      _dataSourceIdentity,
      provider: Provider.codex.value,
    )) {
      return;
    }
    final targetFingerprint = sync.cacheTargetFingerprintForDataSource(
      _dataSourceIdentity,
    );
    final expectedFingerprintChanged =
        _expectedCacheTargetFingerprint != targetFingerprint;
    if (expectedFingerprintChanged) {
      // The chat Cubit is intentionally kept alive across route/IP identity
      // canonicalization. Rebuild only the updater props so its source fence
      // can accept the newly authenticated catalog in-place; assigning this
      // field outside setState leaves a cold page pinned to the provisional
      // fingerprint until the route is closed and opened again.
      setState(() => _expectedCacheTargetFingerprint = targetFingerprint);
    }
    if (sync.matchesCurrentDataSource(
      _dataSourceIdentity,
      provider: Provider.codex.value,
    )) {
      sync.setFocusedConversation(
        provider: Provider.codex.value,
        providerSessionId: durableId,
      );
    }
    if (_cachedPreviewTargetFingerprint == targetFingerprint &&
        (!_loadingCachedPreview ||
            _loadingCachedPreviewTargetFingerprint == targetFingerprint)) {
      return;
    }
    if (_cachedPreview != null &&
        _cachedPreviewTargetFingerprint != targetFingerprint) {
      setState(() => _cachedPreview = null);
    }
    _loadDurablePreview();
  }

  void _loadDurablePreview() {
    final durableId = widget.durableProviderSessionId;
    if (durableId == null) return;
    ConversationContentSyncService sync;
    try {
      sync = context.read<ConversationContentSyncService>();
    } catch (_) {
      return;
    }
    if (sync.hasAuthoritativeDataSourceConflict(
      _dataSourceIdentity,
      provider: Provider.codex.value,
    )) {
      return;
    }
    final targetFingerprint = sync.cacheTargetFingerprintForDataSource(
      _dataSourceIdentity,
    );
    if (_expectedCacheTargetFingerprint != null &&
        _expectedCacheTargetFingerprint != targetFingerprint) {
      return;
    }
    _expectedCacheTargetFingerprint ??= targetFingerprint;
    if (_loadingCachedPreview) {
      // A same-target timeline commit can land while the previous SQLite read
      // is still in flight. Coalesce it into one follow-up read instead of
      // dropping the new revision.
      _cachedPreviewDirty = true;
      return;
    }
    _loadingCachedPreview = true;
    _loadingCachedPreviewTargetFingerprint = targetFingerprint;
    _cachedPreviewDirty = false;
    final cacheCommitEpoch = sync.cacheCommitEpoch;
    unawaited(
      sync
          .loadCachedWindow(
            provider: Provider.codex.value,
            providerSessionId: durableId,
            expectedDataSourceIdentity: _dataSourceIdentity,
          )
          .then((snapshot) {
            if (!mounted ||
                widget.durableProviderSessionId != durableId ||
                sync.hasAuthoritativeDataSourceConflict(
                  _dataSourceIdentity,
                  provider: Provider.codex.value,
                )) {
              if (mounted && widget.durableProviderSessionId == durableId) {
                _cachedPreviewDirty = true;
              }
              return;
            }
            if (sync.cacheCommitEpoch != cacheCommitEpoch) {
              _cachedPreviewDirty = true;
              return;
            }
            // A cache commit can arrive while this SQLite read is in flight.
            // Never flash the now-stale result before the coalesced follow-up
            // read; doing so can visibly rewind an active conversation.
            if (_cachedPreviewDirty) return;
            final currentPreview = _cachedPreview;
            if (snapshot == null && currentPreview != null) return;
            if (snapshot != null &&
                currentPreview != null &&
                _cachedPreviewTargetFingerprint == targetFingerprint &&
                snapshot.cachedAt.isBefore(currentPreview.cachedAt)) {
              return;
            }
            setState(() {
              _cachedPreview = snapshot;
              _cachedPreviewTargetFingerprint = targetFingerprint;
              _cachedPreviewLoadError = null;
            });
          })
          .catchError((Object error) {
            debugPrint('Failed to load cached Codex preview: $error');
            if (!mounted || widget.durableProviderSessionId != durableId) {
              return;
            }
            if (sync.cacheCommitEpoch != cacheCommitEpoch) {
              _cachedPreviewDirty = true;
              return;
            }
            if (_cachedPreviewDirty) return;
            setState(() => _cachedPreviewLoadError = error);
            if (_cachedPreviewErrorSnackbarVisible) return;
            _cachedPreviewErrorSnackbarVisible = true;
            final messenger = ScaffoldMessenger.of(context);
            messenger
                .showSnackBar(
                  SnackBar(
                    content: Text(AppLocalizations.of(context).turnLoadFailed),
                    action: SnackBarAction(
                      label: AppLocalizations.of(context).retry,
                      onPressed: _retryDurablePreviewLoad,
                    ),
                  ),
                )
                .closed
                .whenComplete(() => _cachedPreviewErrorSnackbarVisible = false);
          })
          .whenComplete(() {
            if (mounted && widget.durableProviderSessionId == durableId) {
              _loadingCachedPreview = false;
              _loadingCachedPreviewTargetFingerprint = null;
              if (sync.hasAuthoritativeDataSourceConflict(
                _dataSourceIdentity,
                provider: Provider.codex.value,
              )) {
                _cachedPreviewDirty = true;
              }
              if (_cachedPreviewDirty) {
                _cachedPreviewDirty = false;
                _loadDurablePreview();
              }
            }
          }),
    );
  }

  void _retryDurablePreviewLoad() {
    if (!mounted || _cachedPreviewLoadError == null) return;
    setState(() => _cachedPreviewLoadError = null);
    if (_loadingCachedPreview) {
      _cachedPreviewDirty = true;
      return;
    }
    _loadDurablePreview();
  }

  Future<({bool loaded, bool hasMore})> _loadOlderDurableHistory() async {
    final durableId = widget.durableProviderSessionId;
    if (durableId == null || durableId.isEmpty) {
      return (loaded: false, hasMore: false);
    }
    final result = await context
        .read<ConversationContentSyncService>()
        .loadOlderTurns(
          provider: Provider.codex.value,
          providerSessionId: durableId,
          expectedDataSourceIdentity: _dataSourceIdentity,
        );
    return (loaded: result.loaded, hasMore: result.hasMore);
  }

  Future<bool> _repairLatestTurn() async =>
      (await context.read<ConversationContentSyncService>().repairLatestTurn(
        provider: Provider.codex.value,
        providerSessionId: widget.durableProviderSessionId!,
        expectedDataSourceIdentity: _dataSourceIdentity,
      )).loaded;

  bool _isCurrentDurablePreviewTargetConfirmed() {
    try {
      final sync = context.read<ConversationContentSyncService>();
      return sync.matchesCurrentDataSource(
            _dataSourceIdentity,
            provider: Provider.codex.value,
          ) &&
          !sync.hasAuthoritativeDataSourceConflict(
            _dataSourceIdentity,
            provider: Provider.codex.value,
          );
    } catch (_) {
      return false;
    }
  }

  ValueNotifier<SystemMessage?>? get _effectivePendingSessionCreated =>
      _localAttachmentBinding ?? widget.pendingSessionCreated;

  PendingSessionBinding? _ensureDurableAttachmentBinding() {
    if (_durableRuntimeBindingAmbiguous) return null;
    final existingLocal = _localAttachmentBinding;
    if (existingLocal != null && !existingLocal.isDisposed) {
      return existingLocal;
    }
    final external = widget.pendingSessionCreated;
    if (external is PendingSessionBinding &&
        !external.isDisposed &&
        external.value == null &&
        external.failure.value == null) {
      return external;
    }
    final durableId = widget.durableProviderSessionId?.trim();
    if (durableId == null || durableId.isEmpty) return null;
    final bridge = context.read<BridgeService>();
    if (!_dataSourceIdentity.isSatisfiedBy(
      bridge.dataSourceIdentity,
      provider: Provider.codex.value,
    )) {
      return null;
    }
    final projectPath = _projectPath?.trim();
    if (projectPath == null || projectPath.isEmpty) return null;

    late final PendingSessionBinding binding;
    binding = PendingSessionBinding(
      kind: PendingSessionRequestKind.resume,
      requestId: _durableAttachmentRequestUuid.v4(),
      provider: Provider.codex.value,
      projectPath: projectPath,
      providerSessionId: durableId,
      allowLegacyFallback: !bridge.bridgeCapabilities.contains(
        sessionRequestCorrelationCapability,
      ),
      onAttachmentRequested: () async {
        if (!_dataSourceIdentity.isSatisfiedBy(
          bridge.dataSourceIdentity,
          provider: Provider.codex.value,
        )) {
          throw StateError(
            'The connected Bridge/Codex source no longer matches this page.',
          );
        }
        RecentSession? recent = _currentProjectedDurableSession(
          bridge,
          durableId,
        );
        for (final candidate in bridge.recentSessions) {
          if (recent != null) break;
          if (candidate.provider == Provider.codex.value &&
              candidate.sessionId == durableId) {
            recent = candidate;
            break;
          }
        }
        if (recent == null) {
          throw StateError(
            'The durable Codex catalog entry is unavailable; refresh the '
            'conversation list before attaching.',
          );
        }
        await SessionResumeCoordinator(
          bridge: bridge,
        ).resume(recent, resumeRequestId: binding.requestId);
      },
      onDisposed: () {
        if (identical(_localAttachmentBinding, binding)) {
          _localAttachmentBinding = null;
        }
      },
    );
    _localAttachmentBinding = binding;
    return binding;
  }

  bool _queueDeferredSubmission(ChatComposerSubmission submission) {
    if (!_isPending || _deferredSubmission != null) return false;
    final binding = _ensureDurableAttachmentBinding();
    if (binding == null) return false;
    _listenForSessionCreated();
    setState(() => _deferredSubmission = submission);
    unawaited(binding.requestAttachment());
    return true;
  }

  bool _requestDeferredCompactAttachment() {
    if (!_isPending) return false;
    final binding = _ensureDurableAttachmentBinding();
    if (binding == null) return false;
    _listenForSessionCreated();
    unawaited(binding.requestAttachment());
    return true;
  }

  /// Restarts a persisted first-send after the socket and v2 catalog recover.
  ///
  /// The draft itself is intentionally durable, but restoring it without
  /// re-requesting the live attachment leaves the page forever at
  /// "Loading live session status". [PendingSessionBinding] and Bridge request
  /// ids make repeated readiness callbacks idempotent.
  void _requestRestoredDeferredAttachmentIfReady() {
    if (!mounted || !_isPending || _deferredSubmission == null) return;
    final external = widget.pendingSessionCreated;
    final hasReusableExternalBinding =
        external is PendingSessionBinding &&
        !external.isDisposed &&
        external.value == null &&
        external.failure.value == null;
    if (!hasReusableExternalBinding) {
      final durableId = widget.durableProviderSessionId?.trim();
      if (durableId == null || durableId.isEmpty) return;
      final bridge = context.read<BridgeService>();
      final hasAttachmentMetadata =
          _currentProjectedDurableSession(bridge, durableId) != null ||
          bridge.recentSessions.any(
            (session) =>
                session.provider == Provider.codex.value &&
                session.sessionId == durableId,
          );
      if (!hasAttachmentMetadata) return;
    }
    final binding = _ensureDurableAttachmentBinding();
    if (binding == null ||
        binding.isDisposed ||
        binding.value != null ||
        binding.failure.value != null) {
      return;
    }
    _listenForSessionCreated();
    unawaited(binding.requestAttachment());
  }

  void _consumeDeferredSubmission(ChatComposerSubmission submission) {
    if (_deferredSubmission != submission) return;
    final durableId = widget.durableProviderSessionId;
    if (durableId != null && durableId.isNotEmpty) {
      _draftService.deletePendingSubmission(
        durableId,
        clientMessageId: submission.clientMessageId,
      );
    }
    if (!mounted) {
      _deferredSubmission = null;
      return;
    }
    setState(() => _deferredSubmission = null);
  }

  void _restoreDeferredSubmission() {
    if (!_isPending) return;
    final durableId = widget.durableProviderSessionId;
    if (durableId == null || durableId.isEmpty) return;
    final submission = _draftService.getPendingSubmission(durableId);
    if (submission == null) return;
    _deferredSubmission = (
      clientMessageId: submission.clientMessageId,
      text: submission.text,
      images: submission.images.isEmpty ? null : submission.images,
      mentionablePaths: submission.mentionablePaths,
      additionalMentions: submission.additionalMentions,
    );
  }

  void _preserveDeferredSubmissionAsDraft() {
    final submission = _deferredSubmission;
    if (submission == null) return;
    _deferredSubmission = null;
    final durableId = widget.durableProviderSessionId;
    if (durableId == null || durableId.isEmpty) return;
    unawaited(
      _draftService
          .savePendingSubmission(
            durableId,
            PendingChatSubmissionDraft(
              clientMessageId: submission.clientMessageId,
              text: submission.text,
              images: submission.images ?? const [],
              mentionablePaths: submission.mentionablePaths,
              additionalMentions: submission.additionalMentions,
            ),
          )
          .catchError((Object error) {
            debugPrint('Failed to preserve deferred Codex input: $error');
          }),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final routeIdentity = ModalRoute.of(context)?.settings;
    if (!identical(_sessionRouteIdentity, routeIdentity)) {
      final previousIdentity = _sessionRouteIdentity;
      if (previousIdentity != null) {
        SessionRouteRegistry.instance.remove(
          routeIdentity: previousIdentity,
          owner: _sessionRouteOwner,
        );
      }
      _sessionRouteIdentity = routeIdentity;
    }
    _syncSessionRouteIdentity();
  }

  void _syncSessionRouteIdentity() {
    final routeIdentity = _sessionRouteIdentity;
    if (routeIdentity == null) return;
    SessionRouteRegistry.instance.update(
      routeIdentity: routeIdentity,
      owner: _sessionRouteOwner,
      sessionId: widget.durableProviderSessionId ?? _sessionId,
      provider: 'codex',
      dataSourceIdentity: _dataSourceIdentity,
    );
    if (ModalRoute.of(context)?.isCurrent ?? false) {
      NotificationService.instance.setActiveSession(
        sessionId: widget.durableProviderSessionId ?? _sessionId,
        provider: 'codex',
        dataSourceIdentity: _dataSourceIdentity,
      );
    }
  }

  void _listenForSessionCreated() {
    final pendingBinding =
        _effectivePendingSessionCreated ?? _ensureDurableAttachmentBinding();
    if (pendingBinding is PendingSessionBinding) {
      if (identical(_retainedPendingBinding, pendingBinding)) return;
      _retainPendingBinding(pendingBinding);
      final buffered = pendingBinding.value;
      if (buffered != null && buffered.sessionId != null) {
        _resolveSession(buffered);
        return;
      }
      pendingBinding.addListener(_onPendingSessionCreated);
      pendingBinding.failure.addListener(_onPendingSessionFailed);
      if (pendingBinding.failure.value != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _onPendingSessionFailed();
        });
      }
      return;
    }

    // Legacy notifier hosts may still buffer the correlated result. They must
    // not fall back to listening to every project-wide session_created event:
    // two same-project durable threads could otherwise claim one runtime.
    final buffered = widget.pendingSessionCreated?.value;
    if (buffered != null && buffered.sessionId != null) {
      _resolveSession(buffered);
      return;
    }
    widget.pendingSessionCreated?.addListener(_onPendingSessionCreated);
  }

  void _retainPendingBinding(PendingSessionBinding binding) {
    if (identical(_retainedPendingBinding, binding)) return;
    _retainedPendingBinding?.release();
    binding.retain();
    _retainedPendingBinding = binding;
  }

  void _detachPendingBinding(ValueNotifier<SystemMessage?>? binding) {
    binding?.removeListener(_onPendingSessionCreated);
    if (binding is PendingSessionBinding) {
      binding.failure.removeListener(_onPendingSessionFailed);
    }
    final retained = _retainedPendingBinding;
    if (retained != null && identical(retained, binding)) {
      _retainedPendingBinding = null;
      retained.release();
    }
  }

  void _onPendingSessionCreated() {
    final msg = _effectivePendingSessionCreated?.value;
    if (msg != null && msg.sessionId != null && mounted && _isPending) {
      _resolveSession(msg);
    }
  }

  void _onPendingSessionFailed() {
    final binding = _effectivePendingSessionCreated;
    if (binding is! PendingSessionBinding ||
        binding.failure.value == null ||
        !mounted ||
        !_isPending) {
      return;
    }
    final durableId = widget.durableProviderSessionId;
    if (durableId != null && durableId.isNotEmpty) {
      final text =
          binding.failure.value?.errorMessage ??
          AppLocalizations.of(context).failedToStartServer;
      binding.prepareAttachmentRetry();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(text),
          action: SnackBarAction(
            label: AppLocalizations.of(context).retry,
            onPressed: () => unawaited(binding.requestAttachment()),
          ),
        ),
      );
      return;
    }
    binding.removeListener(_onPendingSessionCreated);
    binding.failure.removeListener(_onPendingSessionFailed);
    _preserveDeferredSubmissionAsDraft();
    final messenger = ScaffoldMessenger.of(context);
    final text =
        binding.failure.value?.errorMessage ??
        AppLocalizations.of(context).failedToStartServer;
    final onBack = widget.onBackToSessions;
    if (onBack != null) {
      onBack();
    } else {
      context.router.maybePop();
    }
    messenger.showSnackBar(SnackBar(content: Text(text)));
  }

  /// Listen for sandbox mode restart events.
  /// When the bridge destroys the old session and creates a new one with
  /// a different sandbox mode, we switch to the new session seamlessly.
  void _listenForSandboxRestart() {
    final bridge = context.read<BridgeService>();
    _sandboxRestartSub = bridge.messages.listen((msg) {
      final localBinding = _localAttachmentBinding;
      if (msg is SystemMessage &&
          localBinding != null &&
          !localBinding.isDisposed) {
        dispatchPendingSessionMessage([localBinding], msg);
      }
      if (msg is SystemMessage &&
          msg.subtype == 'session_created' &&
          msg.sourceSessionId == _sessionId &&
          msg.sessionId != null &&
          msg.sessionId != _sessionId &&
          !_isPending &&
          mounted) {
        _switchSession(msg);
      }
    });
  }

  /// Switch to a new session (e.g. after sandbox mode change).
  void _switchSession(SystemMessage msg) {
    final oldId = _sessionId;
    final newId = msg.sessionId!;
    final draftService = _draftService;
    final bridge = context.read<BridgeService>();
    bridge.migrateExplorerHistory(oldId, newId);
    final explorerHistory = bridge.getExplorerHistory(newId);
    draftService.migrateDraft(oldId, newId);
    draftService.migrateImageDraft(oldId, newId);
    setState(() {
      _durableRuntimeBindingAmbiguous = false;
      _sessionId = newId;
      _projectPath = msg.projectPath ?? _projectPath;
      _worktreePath = msg.worktreePath ?? _worktreePath;
      _gitBranch = msg.worktreeBranch ?? _gitBranch;
      _sandboxMode = sandboxModeFromRaw(msg.sandboxMode) ?? _sandboxMode;
      _permissionMode =
          permissionModeFromRaw(msg.permissionMode) ?? _permissionMode;
      _codexApprovalPolicy =
          codexApprovalPolicyFromRaw(msg.approvalPolicy) ??
          _codexApprovalPolicy;
      _codexApprovalsReviewer =
          msg.approvalsReviewer ?? _codexApprovalsReviewer;
      _codexPermissionsMode =
          codexPermissionsModeFromRaw(msg.codexPermissionsMode) ??
          _codexPermissionsMode;
      _explorerCurrentPath = explorerHistory.currentPath;
      _recentPeekedFiles = explorerHistory.recentPeekedFiles;
    });
    _syncSessionRouteIdentity();
  }

  void _resolveSession(SystemMessage msg) {
    final binding = _effectivePendingSessionCreated;
    binding?.removeListener(_onPendingSessionCreated);
    if (binding is PendingSessionBinding) {
      binding.failure.removeListener(_onPendingSessionFailed);
    }
    final oldId = _sessionId;
    final newId = msg.sessionId!;
    // Migrate draft from pending ID to real session ID
    final draftService = _draftService;
    draftService.migrateDraft(oldId, newId);
    draftService.migrateImageDraft(oldId, newId);
    final durableId = widget.durableProviderSessionId;
    if (durableId != null && durableId != oldId && durableId != newId) {
      draftService.migrateDraft(durableId, newId);
      draftService.migrateImageDraft(durableId, newId);
    }
    setState(() {
      _durableRuntimeBindingAmbiguous = false;
      _sessionId = newId;
      _projectPath = msg.projectPath ?? _projectPath;
      _gitBranch = msg.worktreeBranch ?? _gitBranch;
      _worktreePath = msg.worktreePath ?? _worktreePath;
      _sandboxMode = sandboxModeFromRaw(msg.sandboxMode) ?? _sandboxMode;
      _permissionMode =
          permissionModeFromRaw(msg.permissionMode) ?? _permissionMode;
      _codexApprovalPolicy =
          codexApprovalPolicyFromRaw(msg.approvalPolicy) ??
          _codexApprovalPolicy;
      _codexApprovalsReviewer =
          msg.approvalsReviewer ?? _codexApprovalsReviewer;
      _codexPermissionsMode =
          codexPermissionsModeFromRaw(msg.codexPermissionsMode) ??
          _codexPermissionsMode;
      _isPending = false;
    });
    _syncSessionRouteIdentity();
  }

  void _listenForSessionStopped() {
    final bridge = context.read<BridgeService>();
    _sessionStoppedSub = bridge.stoppedSessions.listen((stoppedSessionId) {
      if (!mounted || stoppedSessionId != _sessionId) return;
      final previousLocalBinding = _localAttachmentBinding;
      if (previousLocalBinding != null) {
        _detachPendingBinding(previousLocalBinding);
      } else {
        _detachPendingBinding(widget.pendingSessionCreated);
      }
      setState(() {
        _durableRuntimeBindingAmbiguous = false;
        _explorerCurrentPath = '';
        _recentPeekedFiles = const [];
        if (widget.durableProviderSessionId?.trim().isNotEmpty == true) {
          _isPending = true;
        }
      });
      if (_isPending) {
        _ensureDurableAttachmentBinding();
        _listenForSessionCreated();
      }
    });
  }

  void updateExplorerState({
    required String currentPath,
    required List<String> recentPeekedFiles,
  }) {
    context.read<BridgeService>().setExplorerHistory(
      _sessionId,
      currentPath: currentPath,
      recentPeekedFiles: recentPeekedFiles,
    );
    setState(() {
      _explorerCurrentPath = currentPath;
      _recentPeekedFiles = recentPeekedFiles;
    });
  }

  @override
  void didUpdateWidget(covariant CodexSessionScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final bridge = context.read<BridgeService>();
    final identityCandidate =
        widget.dataSourceIdentity ?? bridge.dataSourceIdentity;
    final nextIdentity = _dataSourceIdentity.reconciledWithAuthenticated(
      identityCandidate,
      provider: Provider.codex.value,
    );
    final identityChanged = nextIdentity != _dataSourceIdentity;
    final pendingLifecycleChanged =
        oldWidget.pendingSessionCreated != widget.pendingSessionCreated ||
        oldWidget.isPending != widget.isPending;
    if (oldWidget.sessionId == widget.sessionId &&
        oldWidget.projectPath == widget.projectPath &&
        oldWidget.worktreePath == widget.worktreePath &&
        oldWidget.gitBranch == widget.gitBranch &&
        oldWidget.isPending == widget.isPending &&
        oldWidget.durableProviderSessionId == widget.durableProviderSessionId &&
        oldWidget.pendingSessionCreated == widget.pendingSessionCreated &&
        oldWidget.initialPermissionMode == widget.initialPermissionMode &&
        oldWidget.initialSandboxMode == widget.initialSandboxMode &&
        oldWidget.initialApprovalPolicy == widget.initialApprovalPolicy &&
        oldWidget.initialApprovalsReviewer == widget.initialApprovalsReviewer &&
        !identityChanged) {
      return;
    }

    if (pendingLifecycleChanged) {
      final localBinding = _localAttachmentBinding;
      if (localBinding != null &&
          oldWidget.pendingSessionCreated != widget.pendingSessionCreated) {
        _detachPendingBinding(localBinding);
      }
      _detachPendingBinding(oldWidget.pendingSessionCreated);
    }
    final explorerHistory = bridge.getExplorerHistory(widget.sessionId);
    setState(() {
      _dataSourceIdentity = nextIdentity;
      _sessionId = widget.sessionId;
      _projectPath = widget.projectPath;
      _worktreePath = widget.worktreePath;
      _gitBranch = widget.gitBranch;
      _isPending = widget.isPending;
      _sandboxMode = sandboxModeFromRaw(widget.initialSandboxMode);
      _permissionMode = permissionModeFromRaw(widget.initialPermissionMode);
      _codexApprovalPolicy = codexApprovalPolicyFromRaw(
        widget.initialApprovalPolicy,
      );
      _codexApprovalsReviewer = widget.initialApprovalsReviewer;
      _explorerCurrentPath = explorerHistory.currentPath;
      _recentPeekedFiles = explorerHistory.recentPeekedFiles;
    });
    _syncSessionRouteIdentity();
    if (identityChanged) {
      _reloadDurablePreviewForCurrentTarget();
    }
    if (_isPending && pendingLifecycleChanged) {
      _listenForSessionCreated();
    }
  }

  @override
  void dispose() {
    final routeIdentity = _sessionRouteIdentity;
    if (routeIdentity != null) {
      SessionRouteRegistry.instance.remove(
        routeIdentity: routeIdentity,
        owner: _sessionRouteOwner,
      );
    }
    if (_isPending) {
      _preserveDeferredSubmissionAsDraft();
    }
    _detachPendingBinding(
      _localAttachmentBinding ?? widget.pendingSessionCreated,
    );
    _sandboxRestartSub?.cancel();
    _sessionStoppedSub?.cancel();
    _cachedPreviewSub?.cancel();
    _identitySessionListSub?.cancel();
    _identityRecentSessionsSub?.cancel();
    _identityCatalogSnapshotSub?.cancel();
    final durableId = widget.durableProviderSessionId;
    if (durableId != null) {
      try {
        context.read<ConversationContentSyncService>().clearFocusedConversation(
          provider: Provider.codex.value,
          providerSessionId: durableId,
        );
      } catch (_) {}
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final durableId = widget.durableProviderSessionId;
    final cachedPreview = _cachedPreview;
    final latestTurnRecoveryVisible =
        cachedPreview != null &&
        cachedPreview.entries.isEmpty &&
        !cachedPreview.latestTurnComplete &&
        _isCurrentDurablePreviewTargetConfirmed();
    if (durableId != null && durableId.isNotEmpty) {
      return ConversationRouteFocusRestorer(
        onRouteCurrent: _restoreDurableConversationFocusIfCurrentSource,
        child: _CodexProviders(
          key: ValueKey('durable-codex-$durableId'),
          sessionId: durableId,
          sessionInsightsSessionId: durableId,
          projectPath: _projectPath,
          gitBranch: _gitBranch,
          worktreePath: _worktreePath,
          sandboxMode: _sandboxMode,
          permissionMode: _permissionMode,
          codexApprovalPolicy: _codexApprovalPolicy,
          codexApprovalsReviewer: _codexApprovalsReviewer,
          codexPermissionsMode: _codexPermissionsMode,
          detachedPreview: true,
          hideAuxiliaryDock: widget.hideAuxiliaryDock,
          previewRevision: cachedPreview == null
              ? ''
              : '${cachedPreview.revision}:'
                    '${cachedPreview.entries.length}:'
                    '${cachedPreview.cachedAt.microsecondsSinceEpoch}',
          historyRevision: cachedPreview?.revision ?? '',
          initialHistoryMessages:
              cachedPreview?.entries
                  .map((entry) => entry.decodeMessage())
                  .toList(growable: false) ??
              const [],
          initialHistoryHasEarlier: cachedPreview?.hasEarlier ?? false,
          detachedHistoryPageLoader: _loadOlderDurableHistory,
          latestTurnRecoveryVisible: latestTurnRecoveryVisible,
          onLatestTurnRecoveryRetry: _repairLatestTurn,
          expectedSourceFingerprint: _expectedCacheTargetFingerprint,
          liveRuntimeSessionId: _isPending ? null : _sessionId,
          deferredSubmissionPending: _deferredSubmission != null,
          onDeferredSubmit: _queueDeferredSubmission,
          onDeferredCompact: _requestDeferredCompactAttachment,
          initialSubmission: _deferredSubmission,
          onInitialSubmissionConsumed: _consumeDeferredSubmission,
          onBackToSessions: widget.onBackToSessions,
          hideSessionBackButton: widget.hideSessionBackButton,
          allowMessageFork: false,
          dataSourceIdentity: _dataSourceIdentity,
        ),
      );
    }
    if (_isPending) {
      final shell = WorkspaceShellScreen.maybeOf(context);
      final chrome = _resolveSessionPaneChrome(context, shell);
      final leading = _sessionAppBarLeading(
        context,
        shell,
        chrome: chrome,
        onBackToSessions: widget.onBackToSessions,
        hideSessionBackButton: widget.hideSessionBackButton,
      );
      return Scaffold(
        appBar: chrome.wrapAppBar(
          AppBar(
            toolbarHeight: chrome.toolbarHeight,
            leading: chrome.wrapLeading(leading),
            automaticallyImplyLeading: false,
            leadingWidth: chrome.resolveLeadingWidth(
              hasLeading: leading != null,
              baseWidth: chrome.useMacOSAdaptiveChrome
                  ? kWorkspaceMacOSToolbarLeadingSlotWidth
                  : 64,
            ),
          ),
        ),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator.adaptive(),
              const SizedBox(height: 16),
              Text(
                durableId == null
                    ? AppLocalizations.of(context).creatingSession
                    : AppLocalizations.of(context).loadingSessionStatus,
                style: const TextStyle(fontSize: 16),
              ),
            ],
          ),
        ),
      );
    }

    return _CodexProviders(
      key: ValueKey('codex-$_sessionId'),
      sessionId: _sessionId,
      sessionInsightsSessionId: widget.durableProviderSessionId,
      projectPath: _projectPath,
      gitBranch: _gitBranch,
      worktreePath: _worktreePath,
      explorerCurrentPath: _explorerCurrentPath,
      recentPeekedFiles: _recentPeekedFiles,
      sandboxMode: _sandboxMode,
      permissionMode: _permissionMode,
      codexApprovalPolicy: _codexApprovalPolicy,
      codexApprovalsReviewer: _codexApprovalsReviewer,
      codexPermissionsMode: _codexPermissionsMode,
      hideAuxiliaryDock: widget.hideAuxiliaryDock,
      initialSubmission: _deferredSubmission,
      onInitialSubmissionConsumed: _consumeDeferredSubmission,
      onBackToSessions: widget.onBackToSessions,
      hideSessionBackButton: widget.hideSessionBackButton,
      allowMessageFork: widget.allowMessageFork,
      dataSourceIdentity: _dataSourceIdentity,
    );
  }
}

// ---------------------------------------------------------------------------
// Provider wrapper — creates CodexSessionCubit + StreamingStateCubit
// ---------------------------------------------------------------------------

class _CodexProviders extends StatelessWidget {
  final String sessionId;
  final String? sessionInsightsSessionId;
  final String? projectPath;
  final String? gitBranch;
  final String? worktreePath;
  final String explorerCurrentPath;
  final List<String> recentPeekedFiles;
  final SandboxMode? sandboxMode;
  final PermissionMode? permissionMode;
  final CodexApprovalPolicy? codexApprovalPolicy;
  final String? codexApprovalsReviewer;
  final CodexPermissionsMode? codexPermissionsMode;
  final VoidCallback? onBackToSessions;
  final bool hideSessionBackButton;
  final bool hideAuxiliaryDock;
  final bool allowMessageFork;
  final bool detachedPreview;
  final String previewRevision;
  final String historyRevision;
  final List<ServerMessage> initialHistoryMessages;
  final bool initialHistoryHasEarlier;
  final DetachedHistoryPageLoader? detachedHistoryPageLoader;
  final bool latestTurnRecoveryVisible;
  final LatestTurnRepairCallback? onLatestTurnRecoveryRetry;
  final String? expectedSourceFingerprint;
  final String? liveRuntimeSessionId;
  final bool deferredSubmissionPending;
  final ChatComposerSubmitCallback? onDeferredSubmit;
  final bool Function()? onDeferredCompact;
  final ChatComposerSubmission? initialSubmission;
  final ValueChanged<ChatComposerSubmission>? onInitialSubmissionConsumed;
  final BridgeDataSourceIdentity dataSourceIdentity;

  const _CodexProviders({
    super.key,
    required this.sessionId,
    this.sessionInsightsSessionId,
    this.projectPath,
    this.gitBranch,
    this.worktreePath,
    this.explorerCurrentPath = '',
    this.recentPeekedFiles = const [],
    this.sandboxMode,
    this.permissionMode,
    this.codexApprovalPolicy,
    this.codexApprovalsReviewer,
    this.codexPermissionsMode,
    this.onBackToSessions,
    this.hideSessionBackButton = false,
    this.hideAuxiliaryDock = false,
    this.allowMessageFork = true,
    this.detachedPreview = false,
    this.previewRevision = '',
    this.historyRevision = '',
    this.initialHistoryMessages = const [],
    this.initialHistoryHasEarlier = false,
    this.detachedHistoryPageLoader,
    this.latestTurnRecoveryVisible = false,
    this.onLatestTurnRecoveryRetry,
    this.expectedSourceFingerprint,
    this.liveRuntimeSessionId,
    this.deferredSubmissionPending = false,
    this.onDeferredSubmit,
    this.onDeferredCompact,
    this.initialSubmission,
    this.onInitialSubmissionConsumed,
    required this.dataSourceIdentity,
  });

  @override
  Widget build(BuildContext context) {
    final bridge = context.read<BridgeService>();
    final DetachedHistoryToolDetailLoader? toolDetailLoader = detachedPreview
        ? (gap, toolUseIds) =>
              context.read<ConversationContentSyncService>().loadToolDetails(
                provider: Provider.codex.value,
                providerSessionId: sessionId,
                gap: gap,
                toolUseIds: toolUseIds,
                expectedDataSourceIdentity: dataSourceIdentity,
              )
        : null;
    final DetachedUserMessageIndexLoader? userMessageIndexLoader =
        detachedPreview && historyRevision.isNotEmpty
        ? () async {
            final snapshot = await context
                .read<ConversationContentSyncService>()
                .loadUserMessageIndex(
                  provider: Provider.codex.value,
                  providerSessionId: sessionId,
                  revision: historyRevision,
                  expectedDataSourceIdentity: dataSourceIdentity,
                );
            if (snapshot == null) return null;
            return (
              messages: snapshot.entries
                  .map((entry) => entry.message)
                  .toList(growable: false),
              complete:
                  snapshot.complete && snapshot.revision == historyRevision,
            );
          }
        : null;
    final DetachedUserTurnLoader? userTurnLoader =
        detachedPreview && historyRevision.isNotEmpty
        ? (providerTurnId) =>
              context.read<ConversationContentSyncService>().loadUserTurnWindow(
                provider: Provider.codex.value,
                providerSessionId: sessionId,
                providerTurnId: providerTurnId,
                revision: historyRevision,
                expectedDataSourceIdentity: dataSourceIdentity,
              )
        : null;
    return MultiBlocProvider(
      providers: [
        BlocProvider(create: (_) => StreamingStateCubit()),
        // Register as ChatSessionCubit so shared widgets can find it.
        BlocProvider<ChatSessionCubit>(
          create: (context) {
            final cubit = CodexSessionCubit(
              sessionId: sessionId,
              bridge: bridge,
              streamingCubit: context.read<StreamingStateCubit>(),
              initialExplorerCurrentPath: explorerCurrentPath,
              initialRecentPeekedFiles: recentPeekedFiles,
              initialSandboxMode: sandboxMode,
              initialPermissionMode: permissionMode,
              initialCodexApprovalPolicy: codexApprovalPolicy,
              initialCodexApprovalsReviewer: codexApprovalsReviewer,
              initialCodexPermissionsMode: codexPermissionsMode,
              initialProjectPath: projectPath,
              detachedPreview: detachedPreview,
              initialHistoryMessages: initialHistoryMessages,
              initialLiveRuntimeSessionId: liveRuntimeSessionId,
              detachedHistoryPageLoader: detachedHistoryPageLoader,
              detachedHistoryToolDetailLoader: toolDetailLoader,
              detachedUserMessageIndexLoader: userMessageIndexLoader,
              detachedUserTurnLoader: userTurnLoader,
              initialHistoryHasEarlier: initialHistoryHasEarlier,
            );
            final submission = initialSubmission;
            if (!detachedPreview && submission != null) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (cubit.isClosed) return;
                final accepted = cubit.sendMessage(
                  submission.text,
                  clientMessageId: submission.clientMessageId,
                  images: submission.images,
                  mentionablePaths: submission.mentionablePaths,
                  additionalMentions: submission.additionalMentions,
                );
                if (accepted) {
                  onInitialSubmissionConsumed?.call(submission);
                }
              });
            }
            return cubit;
          },
        ),
      ],
      child: DurableSessionPreviewUpdater(
        revision: previewRevision,
        messages: initialHistoryMessages,
        hasEarlier: initialHistoryHasEarlier,
        statusProvider: detachedPreview ? Provider.codex.value : null,
        statusProviderSessionId: detachedPreview ? sessionId : null,
        expectedSourceFingerprint: detachedPreview
            ? expectedSourceFingerprint
            : null,
        liveRuntimeSessionId: detachedPreview ? liveRuntimeSessionId : null,
        onLiveRuntimeReady: !detachedPreview || initialSubmission == null
            ? null
            : (cubit) {
                final submission = initialSubmission!;
                final accepted = cubit.sendMessage(
                  submission.text,
                  clientMessageId: submission.clientMessageId,
                  images: submission.images,
                  mentionablePaths: submission.mentionablePaths,
                  additionalMentions: submission.additionalMentions,
                );
                if (accepted) {
                  onInitialSubmissionConsumed?.call(submission);
                }
                return accepted;
              },
        durableHistoryLoaderRevision: historyRevision,
        durableHistoryLoaderSourceFingerprint: expectedSourceFingerprint,
        detachedHistoryToolDetailLoader: toolDetailLoader,
        detachedUserMessageIndexLoader: userMessageIndexLoader,
        detachedUserTurnLoader: userTurnLoader,
        child: _CodexChatBody(
          sessionId: sessionId,
          liveRuntimeSessionId: detachedPreview
              ? liveRuntimeSessionId
              : sessionId,
          sessionInsightsSessionId: sessionInsightsSessionId,
          projectPath: projectPath,
          gitBranch: gitBranch,
          worktreePath: worktreePath,
          onBackToSessions: onBackToSessions,
          hideSessionBackButton: hideSessionBackButton,
          hideAuxiliaryDock: hideAuxiliaryDock,
          allowMessageFork: allowMessageFork,
          detachedPreview: detachedPreview,
          deferredSubmissionPending: deferredSubmissionPending,
          onDeferredSubmit: onDeferredSubmit,
          onDeferredCompact: onDeferredCompact,
          dataSourceIdentity: dataSourceIdentity,
          latestTurnRecoveryVisible: latestTurnRecoveryVisible,
          onLatestTurnRecoveryRetry: onLatestTurnRecoveryRetry,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Chat body — streamlined for Codex
// ---------------------------------------------------------------------------

class _CodexChatBody extends HookWidget {
  final String sessionId;
  final String? liveRuntimeSessionId;
  final String? sessionInsightsSessionId;
  final String? projectPath;
  final String? gitBranch;
  final String? worktreePath;
  final VoidCallback? onBackToSessions;
  final bool hideSessionBackButton;
  final bool hideAuxiliaryDock;
  final bool allowMessageFork;
  final bool detachedPreview;
  final bool deferredSubmissionPending;
  final bool latestTurnRecoveryVisible;
  final LatestTurnRepairCallback? onLatestTurnRecoveryRetry;
  final ChatComposerSubmitCallback? onDeferredSubmit;
  final bool Function()? onDeferredCompact;
  final BridgeDataSourceIdentity dataSourceIdentity;

  const _CodexChatBody({
    required this.sessionId,
    this.liveRuntimeSessionId,
    this.sessionInsightsSessionId,
    this.projectPath,
    this.gitBranch,
    this.worktreePath,
    this.onBackToSessions,
    this.hideSessionBackButton = false,
    this.hideAuxiliaryDock = false,
    this.allowMessageFork = true,
    this.detachedPreview = false,
    this.deferredSubmissionPending = false,
    this.latestTurnRecoveryVisible = false,
    this.onLatestTurnRecoveryRetry,
    this.onDeferredSubmit,
    this.onDeferredCompact,
    required this.dataSourceIdentity,
  });

  @override
  Widget build(BuildContext context) {
    final appColors = Theme.of(context).extension<AppColors>()!;
    final l = AppLocalizations.of(context);
    final bridge = context.read<BridgeService>();
    final shell = WorkspaceShellScreen.maybeOf(context);
    final presentationListenable = shell?.presentationListenable;
    // Mutable branch state (refreshed from Bridge)
    final currentBranch = useState(gitBranch);
    final showRemoteGitStatusBadge = context.select(
      (SettingsCubit cubit) => cubit.state.showRemoteGitStatusBadge,
    );

    // Custom hooks
    final lifecycleState = useAppLifecycleState();
    final isBackground =
        lifecycleState != null && lifecycleState != AppLifecycleState.resumed;
    final isBackgroundRef = useRef(isBackground);
    isBackgroundRef.value = isBackground;
    useOnAppLifecycleStateChange((_, current) {
      isBackgroundRef.value = current != AppLifecycleState.resumed;
    });
    // Durable cache-first routes can replace entry heights as newer revisions
    // arrive. A raw pixel offset from an earlier revision can therefore reopen
    // on an unrelated old message. Keep raw persistence only for the legacy
    // runtime-owned route; durable routes start from their current latest edge.
    final scroll = useScrollTracking(
      sessionId,
      persistRawOffset: !detachedPreview,
    );
    useKeyboardScrollAdjustment(scroll.controller);

    // Chat input controller
    final chatInputController = useMemoized(ComposerTextEditingController.new);
    useEffect(() => chatInputController.dispose, [chatInputController]);
    final planFeedbackController = useTextEditingController();
    final draftService = context.read<DraftService>();
    final bridgeRuntimeSessionId = detachedPreview
        ? liveRuntimeSessionId
        : sessionId;
    final workspaceStateKey = workspaceSessionStateKey(
      provider: Provider.codex.value,
      durableSessionId: sessionId,
      dataSourceIdentity: dataSourceIdentity,
    );
    EphemeralSideChatRegistryService? ephemeralSideChatRegistry;
    try {
      ephemeralSideChatRegistry = context
          .read<EphemeralSideChatRegistryService>();
    } catch (_) {}

    // --- Draft persistence: restore on mount, auto-save on change ---
    useEffect(() {
      final draft = draftService.getDraft(sessionId);
      if (draft != null && draft.isNotEmpty) {
        chatInputController.text = draft;
        chatInputController.selection = TextSelection.collapsed(
          offset: draft.length,
        );
      }

      Timer? debounce;
      void onChanged() {
        debounce?.cancel();
        debounce = Timer(const Duration(milliseconds: 500), () {
          draftService.saveDraft(sessionId, chatInputController.text);
        });
      }

      chatInputController.addListener(onChanged);
      return () {
        debounce?.cancel();
        // Flush current text on dispose (navigating away)
        draftService.saveDraft(sessionId, chatInputController.text);
        chatInputController.removeListener(onChanged);
      };
    }, [sessionId]);
    // Collapse tool results notifier (shared widget needs it)
    final collapseToolResults = useMemoized(() => ValueNotifier<int>(0));
    useEffect(() => collapseToolResults.dispose, const []);

    // Scroll-to-user-entry notifier (for message history jump)
    final scrollToUserEntry = useMemoized(
      () => ValueNotifier<UserChatEntry?>(null),
    );
    useEffect(() => scrollToUserEntry.dispose, const []);

    // Diff selection from GitScreen navigation
    final diffSelectionFromNav = useState<DiffSelection?>(null);
    final codexCliJoinCommand = useState(
      bridgeRuntimeSessionId == null
          ? null
          : _latestCodexCliJoinCommand(
              bridge.cachedSessionMessages(bridgeRuntimeSessionId),
            ),
    );

    // --- Bloc state ---
    final chatSessionCubit = context.read<ChatSessionCubit>();
    final sessionInsightsAuthorityGenerationProvider =
        useMemoized<String? Function()>(
          () =>
              () => chatSessionCubit.detachedActionBrokerAuthorityGeneration,
          [chatSessionCubit],
        );
    useValueListenable(chatSessionCubit.detachedLiveRuntimeRevision);
    final authoritativeQueuedInputs = useValueListenable(
      chatSessionCubit.queuedInputs,
    );
    final sessionState = context.watch<ChatSessionCubit>().state;
    final bridgeState = context.watch<ConnectionCubit>().state;
    final actionBroker = useMemoized(
      () => CodexActionBrokerService(
        bridge: bridge,
        threadId: sessionId,
        expectedBridgeInstanceId: dataSourceIdentity.bridgeInstanceId,
        expectedCodexSourceId: dataSourceIdentity.codexSourceId,
        enabled: detachedPreview,
        runtimeFence: () => CodexActionBrokerRuntimeFence(
          turnId: chatSessionCubit.detachedActionBrokerTurnId,
          authorityGeneration:
              chatSessionCubit.detachedActionBrokerAuthorityGeneration,
          executionHost: chatSessionCubit.detachedActionBrokerExecutionHost,
        ),
      ),
      [
        bridge,
        chatSessionCubit,
        sessionId,
        detachedPreview,
        dataSourceIdentity.bridgeInstanceId,
        dataSourceIdentity.codexSourceId,
      ],
    );
    useListenable(actionBroker);
    useEffect(() {
      actionBroker.start();
      return actionBroker.dispose;
    }, [actionBroker]);
    final runtimeMutationSessionId = chatSessionCubit
        .runtimeSessionIdForMutation(allowSteerable: false);
    final coreActionSessionId = detachedPreview
        ? runtimeMutationSessionId ?? sessionId
        : sessionId;
    final compactActionController = useMemoized(
      () => CodexCoreActionsController(
        sessionId: coreActionSessionId,
        bridge: bridge,
        sessionIdIsCurrent: detachedPreview
            ? (candidate) =>
                  !chatSessionCubit.isClosed &&
                  chatSessionCubit.runtimeSessionIdForMutation(
                        allowSteerable: false,
                      ) ==
                      candidate
            : null,
      ),
      [coreActionSessionId, bridge],
    );
    final deferredCompactPending = useState(false);
    void showCompactFeedback(String message) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    }

    useEffect(() {
      String? lastFeedbackKey;
      void onCompactActionChanged() {
        if (compactActionController.actionLoading) {
          lastFeedbackKey = null;
          return;
        }
        final result = compactActionController.lastActionResult;
        final errorCode = compactActionController.actionErrorCode;
        if (result?.action != 'compact' && errorCode == null) return;
        final feedbackKey = result != null
            ? '${result.requestId}:${result.status}:${result.errorCode ?? ''}'
            : '$errorCode:${compactActionController.actionError ?? ''}';
        if (feedbackKey == lastFeedbackKey) return;
        lastFeedbackKey = feedbackKey;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!context.mounted) return;
          final strings = CodexCoreActionsStrings.of(context);
          final message = result?.accepted == true
              ? strings.accepted
              : codexCoreActionErrorText(
                  strings,
                  errorCode ?? result?.errorCode ?? result?.status ?? 'failed',
                  compactActionController.actionError ?? result?.message,
                );
          showCompactFeedback(message);
        });
      }

      compactActionController
        ..addListener(onCompactActionChanged)
        ..start();
      return () {
        compactActionController
          ..removeListener(onCompactActionChanged)
          ..dispose();
      };
    }, [compactActionController]);

    bool requestCompactImmediately() {
      final strings = CodexCoreActionsStrings.of(context);
      if (runtimeMutationSessionId == null ||
          runtimeMutationSessionId != compactActionController.sessionId) {
        if (detachedPreview && (onDeferredCompact?.call() ?? false)) {
          deferredCompactPending.value = true;
          showCompactFeedback(strings.preparingCompact);
          return true;
        }
        showCompactFeedback(strings.failed);
        return false;
      }
      if (!compactActionController.connected) {
        showCompactFeedback(strings.disconnected);
        return false;
      }
      if (compactActionController.actionLoading) {
        deferredCompactPending.value = false;
        showCompactFeedback(strings.compacting);
        return true;
      }
      final started = compactActionController.requestCompact();
      if (started) deferredCompactPending.value = false;
      showCompactFeedback(started ? strings.compacting : strings.failed);
      return started;
    }

    useEffect(
      () {
        if (!deferredCompactPending.value ||
            runtimeMutationSessionId == null ||
            runtimeMutationSessionId != compactActionController.sessionId ||
            !compactActionController.connected) {
          return null;
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!context.mounted || !deferredCompactPending.value) return;
          requestCompactImmediately();
        });
        return null;
      },
      [
        deferredCompactPending.value,
        runtimeMutationSessionId,
        compactActionController,
        bridgeState,
      ],
    );

    final localFeatureContext = CodexSessionFeatureContext(
      context: context,
      sessionId: sessionId,
      sessionInsightsSessionId: sessionInsightsSessionId,
      runtimeMutationSessionId: runtimeMutationSessionId,
      durableCacheIdentityConfirmed: detachedPreview,
      bridge: bridge,
      inputController: chatInputController,
      draftService: draftService,
      codexModel: sessionState.codexModel,
      authorityGenerationProvider: sessionInsightsAuthorityGenerationProvider,
      requestCompact: requestCompactImmediately,
      openPane: (featureId, {arguments = const {}}) =>
          _openLocalFeaturePaneOrSheet(
            context,
            featureId: featureId,
            sessionId: sessionId,
            arguments: featureId == 'session_insights'
                ? {
                    ...arguments,
                    'authorityGenerationProvider':
                        sessionInsightsAuthorityGenerationProvider,
                  }
                : featureId == 'side_chat' &&
                      sessionInsightsSessionId?.isNotEmpty == true
                ? {
                    ...arguments,
                    'parentProviderSessionId': sessionInsightsSessionId,
                  }
                : featureId == 'subagents' && detachedPreview
                ? {
                    ...arguments,
                    'providerThreadId': sessionInsightsSessionId ?? sessionId,
                    'codexSourceId': dataSourceIdentity.codexSourceId,
                  }
                : featureId == 'codex_core_actions' && detachedPreview
                ? {
                    ...arguments,
                    'durableRoute': true,
                    'runtimeSessionId': runtimeMutationSessionId,
                    'runtimeSessionIdResolver': () => chatSessionCubit.isClosed
                        ? null
                        : chatSessionCubit.runtimeSessionIdForMutation(
                            allowSteerable: false,
                          ),
                    'runtimeRevisionListenable':
                        chatSessionCubit.detachedLiveRuntimeRevision,
                  }
                : arguments,
          ),
    );
    final effectiveProjectPath = _firstNonEmptyProjectPath(
      projectPath,
      sessionState.projectPath,
    );
    final chatFileRoot = resolveChatFileRoot(
      worktreePath: worktreePath,
      projectPath: effectiveProjectPath,
    );
    final gitProjectPath = chatFileRoot;
    final gitBadgeTone = _gitBadgeToneOf(
      context,
      sessionId,
      gitProjectPath,
      showRemoteGitStatusBadge: showRemoteGitStatusBadge,
    );
    final parentState = context
        .findAncestorStateOfType<_CodexSessionScreenState>();
    bool submitWhileAttaching(ChatComposerSubmission submission) {
      if (submission.text.trim().toLowerCase() == '/compact' &&
          (submission.images == null || submission.images!.isEmpty)) {
        final accepted = requestCompactImmediately();
        if (accepted) {
          // The composer persists every custom submission before invoking us.
          // `/compact` is a core action, not a chat message; retaining that
          // draft could replay it as ordinary input or compact twice later.
          draftService.deletePendingSubmission(
            sessionId,
            clientMessageId: submission.clientMessageId,
          );
        }
        return accepted;
      }
      final waitsForAttachment = onDeferredSubmit?.call(submission) ?? false;
      if (waitsForAttachment) {
        final queuedLocally = !context.read<BridgeService>().isConnected;
        chatSessionCubit.showDeferredSubmission(
          submission.text,
          images: submission.images,
          queuedLocally: queuedLocally,
        );
        if (queuedLocally) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(l.queuedLocally)));
        }
        return true;
      }
      final sent = chatSessionCubit.sendMessage(
        submission.text,
        clientMessageId: submission.clientMessageId,
        images: submission.images,
        mentionablePaths: submission.mentionablePaths,
        additionalMentions: submission.additionalMentions,
      );
      if (sent) {
        draftService.deletePendingSubmission(
          sessionId,
          clientMessageId: submission.clientMessageId,
        );
      }
      return sent;
    }

    Future<bool> sendFloatingTodo(String text) async {
      final submission = (
        clientMessageId: const Uuid().v4(),
        text: text,
        images: null,
        mentionablePaths: const <String>[],
        additionalMentions: const <Map<String, String>>[],
      );
      // Keep the floating action on the same authority and queue boundary as
      // the composer. A detached page without a current writable lease uses
      // the existing durable-attachment path; it never writes Bridge input
      // directly or bypasses ownedElsewhere checks.
      if (detachedPreview && !chatSessionCubit.canMutateAttachedRuntime) {
        try {
          await draftService.savePendingSubmission(
            sessionId,
            PendingChatSubmissionDraft(
              clientMessageId: submission.clientMessageId,
              text: submission.text,
              images: const [],
              mentionablePaths: const [],
              additionalMentions: const [],
            ),
          );
        } catch (_) {
          return false;
        }
        final accepted = submitWhileAttaching(submission);
        if (!accepted) {
          draftService.deletePendingSubmission(
            sessionId,
            clientMessageId: submission.clientMessageId,
          );
        }
        return accepted;
      }
      return chatSessionCubit.sendMessage(
        submission.text,
        clientMessageId: submission.clientMessageId,
      );
    }

    final canCopyCodexCliJoinCommand =
        codexCliJoinCommand.value != null &&
        _hasSentUserMessage(sessionState.entries);
    void handleExploreResult(ExploreScreenResult result) {
      if (!context.mounted) return;
      parentState?.updateExplorerState(
        currentPath: result.currentPath,
        recentPeekedFiles: result.recentPeekedFiles,
      );
      final cubit = context.read<ChatSessionCubit>();
      cubit.setExplorerCurrentPath(result.currentPath);
      cubit.setRecentPeekedFiles(result.recentPeekedFiles);
    }

    void handleFilePeekOpened(String filePath) {
      if (!context.mounted) return;
      final currentPath =
          parentState?._explorerCurrentPath ?? sessionState.explorerCurrentPath;
      final recentPeekedFiles = updateRecentPeekedFiles(
        parentState?._recentPeekedFiles ?? sessionState.recentPeekedFiles,
        filePath,
      );
      parentState?.updateExplorerState(
        currentPath: currentPath,
        recentPeekedFiles: recentPeekedFiles,
      );
      context.read<ChatSessionCubit>().setRecentPeekedFiles(recentPeekedFiles);
    }

    useEffect(() {
      final shell = WorkspaceShellScreen.maybeOf(context);
      shell?.registerSessionToolPaneBindings(
        sessionId: sessionId,
        workspaceStateKey: workspaceStateKey,
        diffSelectionNotifier: diffSelectionFromNav,
        onExploreResultChanged: handleExploreResult,
        onFilePeekOpened: handleFilePeekOpened,
      );
      return () => shell?.unregisterSessionToolPaneBindings(
        sessionId,
        workspaceStateKey: workspaceStateKey,
      );
    }, [sessionId, workspaceStateKey]);

    useEffect(() {
      final runtimeSessionId = bridgeRuntimeSessionId;
      codexCliJoinCommand.value = runtimeSessionId == null
          ? null
          : _latestCodexCliJoinCommand(
              bridge.cachedSessionMessages(runtimeSessionId),
            );
      return null;
    }, [bridgeRuntimeSessionId]);

    useEffect(() {
      final runtimeSessionId = bridgeRuntimeSessionId;
      if (runtimeSessionId == null) return null;
      final sub = bridge.messagesForSession(runtimeSessionId).listen((msg) {
        if (msg case SystemMessage(
          sessionId: final messageSessionId?,
          :final codexCliJoin,
        ) when messageSessionId == runtimeSessionId) {
          final command = codexCliJoin?.command.trim();
          if (codexCliJoin?.isValid == true &&
              command != null &&
              command.isNotEmpty) {
            codexCliJoinCommand.value = command;
          }
        }
      });
      return sub.cancel;
    }, [bridgeRuntimeSessionId]);

    // --- Side effects subscription ---
    useEffect(() {
      final sub = chatSessionCubit.sideEffects.listen(
        (effects) => _executeSideEffects(
          effects,
          sessionId: sessionId,
          dataSourceIdentity: dataSourceIdentity,
          isBackground: isBackgroundRef.value,
          approval: chatSessionCubit.state.approval,
          l: l,
          collapseToolResults: collapseToolResults,
          planFeedbackController: planFeedbackController,
          scrollToBottom: scroll.scrollToBottom,
        ),
      );
      return sub.cancel;
    }, [sessionId]);

    useEffect(() {
      final codexCubit = chatSessionCubit as CodexSessionCubit;
      final sub = codexCubit.uiIntents.listen((intent) {
        if (!context.mounted || isBackgroundRef.value) return;
        switch (intent) {
          case CodexSessionUiIntent.manage:
            unawaited(CodexGoalManagement.showManager(context));
          case CodexSessionUiIntent.edit:
            final goal = chatSessionCubit.state.goal;
            if (goal == null) {
              unawaited(CodexGoalManagement.showManager(context));
            } else {
              unawaited(CodexGoalManagement.showEditor(context, goal));
            }
          case CodexSessionUiIntent.permissions:
            showCodexPermissionsMenu(context, chatSessionCubit);
          case CodexSessionUiIntent.plan:
            unawaited(
              togglePlanMode(
                context,
                chatSessionCubit,
                onBeforeRestart: () async {
                  draftService.saveDraft(sessionId, chatInputController.text);
                },
              ),
            );
          case CodexSessionUiIntent.planUnavailable:
            showCodexNativePlanModeUnavailable(context);
          case CodexSessionUiIntent.skills:
            chatInputController
              ..text = r'$'
              ..selection = const TextSelection.collapsed(offset: 1);
          case CodexSessionUiIntent.compactImmediately:
            requestCompactImmediately();
          case CodexSessionUiIntent.review:
            unawaited(
              localFeatureContext.openPane(
                'codex_core_actions',
                arguments: const {'section': 'review'},
              ),
            );
          case CodexSessionUiIntent.mcp:
            unawaited(
              localFeatureContext.openPane(
                'codex_core_actions',
                arguments: const {'section': 'mcp'},
              ),
            );
          case CodexSessionUiIntent.model:
            showCodexModelMenu(context, chatSessionCubit);
          case CodexSessionUiIntent.context:
            final durableInsightsSessionId = sessionInsightsSessionId?.trim();
            unawaited(
              localFeatureContext.openPane(
                'session_insights',
                arguments: {
                  if (durableInsightsSessionId != null &&
                      durableInsightsSessionId.isNotEmpty)
                    'sessionInsightsSessionId': durableInsightsSessionId,
                },
              ),
            );
        }
      });
      return sub.cancel;
    }, [sessionId, compactActionController, runtimeMutationSessionId]);

    useEffect(() {
      if (isBackground || bridgeState != BridgeConnectionState.connected) {
        return null;
      }
      chatSessionCubit.requestGoal();
      final timer = Timer.periodic(const Duration(seconds: 5), (_) {
        chatSessionCubit.requestGoal();
      });
      return timer.cancel;
    }, [sessionId, isBackground, bridgeState]);

    useEffect(
      () {
        final error = sessionState.goalMutationError;
        if (error == null || error.isEmpty || isBackground) return null;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!context.mounted) return;
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(
                content: Text(
                  CodexGoalManagement.errorLabel(
                    sessionState.goalMutationErrorKind,
                    error,
                    l,
                  ),
                ),
              ),
            );
          chatSessionCubit.clearGoalMutationError();
        });
        return null;
      },
      [
        sessionState.goalMutationError,
        sessionState.goalMutationErrorKind,
        isBackground,
      ],
    );

    // --- Initial requests on mount ---
    useEffect(
      () {
        if (detachedPreview) return null;
        final bridge = context.read<BridgeService>();
        final path = gitProjectPath;
        if (!isBackground && chatFileRoot != null) {
          bridge.requestFileList(chatFileRoot);
        }
        if (!isBackground && path != null && path.isNotEmpty) {
          try {
            context.read<GitStatusCubit>().refresh(
              sessionId: sessionId,
              projectPath: path,
              includeRemote: showRemoteGitStatusBadge,
            );
          } catch (_) {}
        }
        if (!isBackground) {
          bridge.requestSessionList();
          bridge.refreshBranch(sessionId);
        }
        return null;
      },
      [
        sessionId,
        chatFileRoot,
        gitProjectPath,
        showRemoteGitStatusBadge,
        detachedPreview,
      ],
    );

    useEffect(
      () {
        if (chatFileRoot == null) return null;
        final runtimeSessionId = bridgeRuntimeSessionId;
        if (runtimeSessionId == null) return null;

        final bridge = context.read<BridgeService>();
        GitStatusCubit? gitStatusCubit;
        GitViewCacheService? gitViewCache;
        try {
          gitStatusCubit = context.read<GitStatusCubit>();
          gitViewCache = context.read<GitViewCacheService>();
        } catch (_) {}
        final sub = bridge.messagesForSession(runtimeSessionId).listen((msg) {
          if (isBackgroundRef.value) return;
          if (msg case ToolResultMessage(
            :final toolName,
          ) when _fileListRefreshToolNames.contains(toolName)) {
            bridge.requestFileList(chatFileRoot);
          } else if (msg case ResultMessage(:final fileEdits)) {
            if ((fileEdits ?? 0) > 0) {
              bridge.requestFileList(chatFileRoot);
            }
            gitStatusCubit?.refresh(
              sessionId: sessionId,
              projectPath: gitProjectPath!,
              includeRemote: showRemoteGitStatusBadge,
            );
            gitViewCache?.refreshIfPresent(sessionId);
          }
        });
        return sub.cancel;
      },
      [
        bridgeRuntimeSessionId,
        chatFileRoot,
        gitProjectPath,
        showRemoteGitStatusBadge,
      ],
    );

    // --- Listen for branch updates ---
    useEffect(() {
      final sub = context.read<BridgeService>().messages.listen((msg) {
        if (msg is BranchUpdateMessage && msg.sessionId == sessionId) {
          currentBranch.value = msg.branch.isNotEmpty ? msg.branch : null;
        }
      });
      return sub.cancel;
    }, [sessionId]);

    // --- App resume: verify WebSocket health + refresh history ---
    // Only triggers on genuine resume from paused/hidden/detached, not from
    // inactive (e.g. Android notification shade).
    useAppResumeCallback(lifecycleState, () {
      if (detachedPreview) return;
      final bridge = context.read<BridgeService>();
      bridge.ensureConnected();
      if (bridge.isConnected) {
        final cubit = context.read<ChatSessionCubit>();
        cubit.refreshHistory();
        cubit.requestGoal();
        if (chatFileRoot != null) {
          bridge.requestFileList(chatFileRoot);
        }
        if (gitProjectPath != null && gitProjectPath.isNotEmpty) {
          try {
            context.read<GitStatusCubit>().refresh(
              sessionId: sessionId,
              projectPath: gitProjectPath,
              includeRemote: showRemoteGitStatusBadge,
            );
          } catch (_) {}
        }
        bridge.requestSessionList();
        bridge.refreshBranch(sessionId);
      }
    });

    // --- Destructure state ---
    final status = sessionState.status;
    final approval = sessionState.approval;
    final inPlanMode = sessionState.inPlanMode;
    final queuedInputs = authoritativeQueuedInputs.isNotEmpty
        ? authoritativeQueuedInputs
        : (sessionState.queuedInput == null
              ? const <QueuedInputItem>[]
              : [sessionState.queuedInput!]);
    final currentGoal = CodexGoalManagement.cardData(sessionState.goal);

    // Approval state pattern matching (Codex: permission + ask-user only)
    String? pendingToolUseId;
    PermissionRequestMessage? pendingPermission;
    String? askToolUseId;
    Map<String, dynamic>? askInput;

    switch (approval) {
      case ApprovalPermission(:final toolUseId, :final request):
        pendingToolUseId = toolUseId;
        pendingPermission = request;
        askToolUseId = null;
        askInput = null;
      case ApprovalAskUser(:final toolUseId, :final input):
        pendingToolUseId = null;
        pendingPermission = null;
        askToolUseId = toolUseId;
        askInput = input;
      case ApprovalNone():
        pendingToolUseId = null;
        pendingPermission = null;
        askToolUseId = null;
        askInput = null;
    }

    final brokerRequest = actionBroker.visibleRequest;
    final brokerPresentation = actionBroker.presentation;
    final brokerOwnsApprovalSurface =
        detachedPreview &&
        actionBroker.capabilityNegotiated &&
        actionBroker.ownsDetachedInteraction(
          waitingApproval: sessionState.status == ProcessStatus.waitingApproval,
        );
    if (brokerOwnsApprovalSurface) {
      if (brokerPresentation?.usesAskUserUi == true) {
        pendingToolUseId = null;
        pendingPermission = null;
        askToolUseId = brokerRequest?.opaqueRequestId;
        askInput = brokerPresentation?.permission.input;
      } else {
        pendingToolUseId = brokerRequest?.opaqueRequestId;
        pendingPermission = brokerPresentation?.permission;
        askToolUseId = null;
        askInput = null;
      }
    }

    final isPlanApproval = pendingPermission?.toolName == 'ExitPlanMode';
    final isToolSuggestion =
        !brokerOwnsApprovalSurface &&
        (pendingPermission?.isToolSuggestion ?? false);

    Future<void> openToolSuggestionUrl(String rawUrl) async {
      final uri = Uri.tryParse(rawUrl);
      final launched =
          uri != null &&
          uri.hasAuthority &&
          (uri.scheme == 'https' || uri.scheme == 'http') &&
          await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!launched && context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l.toolSuggestionOpenFailed)));
      }
    }

    void installSuggestedTool() {
      if (brokerOwnsApprovalSurface ||
          pendingToolUseId == null ||
          pendingPermission == null) {
        return;
      }
      context.read<ChatSessionCubit>().installToolSuggestion(pendingToolUseId);
      final installUrl = pendingPermission.toolSuggestionInstallUrl;
      if (pendingPermission.toolSuggestionType == 'connector' &&
          installUrl != null &&
          installUrl.isNotEmpty) {
        unawaited(openToolSuggestionUrl(installUrl));
      }
    }

    void approveToolUse() {
      if (pendingToolUseId == null) return;
      if (brokerOwnsApprovalSurface) {
        unawaited(
          actionBroker.respond(
            CodexActionBrokerDecision.approve,
            opaqueRequestId: pendingToolUseId,
          ),
        );
      } else {
        context.read<ChatSessionCubit>().approve(pendingToolUseId);
      }
      planFeedbackController.clear();
    }

    void rejectToolUse() {
      if (pendingToolUseId == null) return;
      final feedback = isPlanApproval
          ? planFeedbackController.text.trim()
          : null;
      if (brokerOwnsApprovalSurface) {
        unawaited(
          actionBroker.respond(
            CodexActionBrokerDecision.reject,
            opaqueRequestId: pendingToolUseId,
          ),
        );
      } else {
        context.read<ChatSessionCubit>().reject(
          pendingToolUseId,
          message: feedback != null && feedback.isNotEmpty ? feedback : null,
        );
      }
      planFeedbackController.clear();
    }

    void approveWithClearContext() {
      if (brokerOwnsApprovalSurface || pendingToolUseId == null) return;
      context.read<ChatSessionCubit>().approve(
        pendingToolUseId,
        clearContext: true,
      );
      planFeedbackController.clear();
    }

    void approveAlwaysToolUse() {
      if (pendingToolUseId == null) return;
      HapticFeedback.mediumImpact();
      if (brokerOwnsApprovalSurface) {
        unawaited(
          actionBroker.respond(
            CodexActionBrokerDecision.approveAlways,
            opaqueRequestId: pendingToolUseId,
          ),
        );
      } else {
        context.read<ChatSessionCubit>().approveAlways(pendingToolUseId);
      }
    }

    void answerQuestion(String toolUseId, String result) {
      if (brokerOwnsApprovalSurface) {
        if (brokerRequest?.opaqueRequestId != toolUseId) return;
        unawaited(
          actionBroker.respond(
            CodexActionBrokerDecision.answer,
            opaqueRequestId: toolUseId,
            answer: result,
          ),
        );
        return;
      }
      context.read<ChatSessionCubit>().answer(toolUseId, result);
    }

    Widget buildApprovalSurface() => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (askToolUseId case final askId? when askInput != null)
          AskUserQuestionWidget(
            key: ValueKey(
              brokerOwnsApprovalSurface
                  ? 'broker_question_${askId}_${actionBroker.viewEpoch}'
                  : 'question_$askId',
            ),
            toolUseId: askId,
            input: askInput,
            agentName: 'Codex',
            onAnswer: answerQuestion,
            scrollable: false,
          ),
        if (pendingToolUseId != null &&
            isToolSuggestion &&
            pendingPermission != null)
          ToolSuggestionCard(
            key: ValueKey('tool_suggestion_$pendingToolUseId'),
            appColors: appColors,
            permission: pendingPermission,
            onInstall: installSuggestedTool,
            onComplete: approveToolUse,
            onReject: rejectToolUse,
            onOpenUrl: (url) => unawaited(openToolSuggestionUrl(url)),
          ),
        if (pendingToolUseId != null && !isToolSuggestion)
          ApprovalBar(
            key: ValueKey('approval_$pendingToolUseId'),
            appColors: appColors,
            pendingPermission: pendingPermission,
            isPlanApproval: isPlanApproval,
            planApprovalUiMode: PlanApprovalUiMode.codex,
            planFeedbackController: planFeedbackController,
            onApprove: approveToolUse,
            onReject: rejectToolUse,
            onApproveAlways: approveAlwaysToolUse,
            onApproveClearContext: !brokerOwnsApprovalSurface && isPlanApproval
                ? approveWithClearContext
                : null,
            onViewPlan: isPlanApproval
                ? () {
                    final originalText = _extractPlanText(
                      pendingPermission,
                      sessionState.entries,
                    );
                    if (originalText == null) return;
                    showPlanDetailSheet(context, originalText);
                  }
                : null,
          ),
      ],
    );

    final hasProjectedApproval =
        (askToolUseId != null && askInput != null) || pendingToolUseId != null;
    final Widget? interactionOverlay = brokerOwnsApprovalSurface
        ? CodexActionBrokerInteractionFrame(
            phase: actionBroker.phase,
            onRefresh: actionBroker.refresh,
            onReject:
                brokerPresentation?.usesAskUserUi == true &&
                    brokerRequest?.allowedActions.contains(
                          CodexActionBrokerDecision.reject,
                        ) ==
                        true
                ? () => unawaited(
                    actionBroker.respond(
                      CodexActionBrokerDecision.reject,
                      opaqueRequestId: brokerRequest!.opaqueRequestId,
                    ),
                  )
                : null,
            child: hasProjectedApproval ? buildApprovalSurface() : null,
          )
        : hasProjectedApproval
        ? buildApprovalSurface()
        : null;

    // --- Build ---
    return BlocListener<ConnectionCubit, BridgeConnectionState>(
      listener: (context, state) {
        if (state == BridgeConnectionState.connected) {
          _retryFailedMessages(context);
          context.read<ChatSessionCubit>().refreshHistory();
        }
      },
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.escape): () {
            Navigator.of(context).maybePop();
          },
          // Cmd+Shift+P: cycle permission mode
          const SingleActivator(
            LogicalKeyboardKey.keyP,
            meta: true,
            shift: true,
          ): () {
            final cubit = context.read<ChatSessionCubit>();
            showCodexPermissionsMenu(context, cubit);
          },
          // Cmd+Enter: approve pending tool use
          const SingleActivator(LogicalKeyboardKey.enter, meta: true): () {
            if (pendingToolUseId != null) approveToolUse();
          },
        },
        child: Focus(
          autofocus: true,
          child: ListenableBuilder(
            listenable: presentationListenable ?? const _NoopListenable(),
            builder: (context, child) {
              final currentShell = WorkspaceShellScreen.maybeOf(context);
              final isSinglePane = currentShell?.isSinglePane ?? true;
              final chrome = _resolveSessionPaneChrome(context, currentShell);
              final leading = _sessionAppBarLeading(
                context,
                currentShell,
                chrome: chrome,
                onBackToSessions: onBackToSessions,
                hideSessionBackButton: hideSessionBackButton,
              );
              final showMessageHistoryAction = !isSinglePane;
              final double defaultTitleSpacing = isSinglePane
                  ? NavigationToolbar.kMiddleSpacing
                  : (leading == null ? 16 : 12);

              return Scaffold(
                appBar: chrome.wrapAppBar(
                  AppBar(
                    toolbarHeight: chrome.toolbarHeight,
                    leading: chrome.wrapLeading(leading),
                    automaticallyImplyLeading: false,
                    leadingWidth: chrome.resolveLeadingWidth(
                      hasLeading: leading != null,
                      baseWidth: chrome.useMacOSAdaptiveChrome
                          ? kWorkspaceMacOSToolbarLeadingSlotWidth
                          : 64.0,
                    ),
                    titleSpacing: chrome.resolveTitleSpacing(
                      hasLeading: leading != null,
                      fallback: defaultTitleSpacing,
                    ),
                    title: chrome.wrapTitle(
                      SessionNameTitle(
                        sessionId: sessionId,
                        projectPath: effectiveProjectPath,
                      ),
                    ),
                    flexibleSpace: StatusLineFlexibleSpace(
                      status: status,
                      inPlanMode: inPlanMode,
                    ),
                    actions: [
                      if (effectiveProjectPath != null)
                        IconButton(
                          key: const ValueKey('appbar_explore_button'),
                          icon: Icon(
                            Icons.folder_outlined,
                            size: 18,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 32,
                            minHeight: 32,
                          ),
                          tooltip: l.explorer,
                          onPressed: () async {
                            final shell = WorkspaceShellScreen.maybeOf(context);
                            final initialPath =
                                parentState?._explorerCurrentPath ??
                                sessionState.explorerCurrentPath;
                            final recentPeekedFiles =
                                parentState?._recentPeekedFiles ??
                                sessionState.recentPeekedFiles;
                            if (shell?.canOpenToolPane ?? false) {
                              shell!.openExplorePane(
                                sessionId: sessionId,
                                projectPath: effectiveProjectPath,
                                initialFiles: context
                                    .read<FileListCubit>()
                                    .state,
                                initialPath: initialPath,
                                recentPeekedFiles: recentPeekedFiles,
                                onResultChanged: handleExploreResult,
                              );
                              return;
                            }
                            final result = await context.router.push(
                              ExploreRoute(
                                sessionId: sessionId,
                                projectPath: effectiveProjectPath,
                                initialFiles: context
                                    .read<FileListCubit>()
                                    .state,
                                initialPath: initialPath,
                                recentPeekedFiles: recentPeekedFiles,
                              ),
                            );
                            if (result is! ExploreScreenResult ||
                                !context.mounted) {
                              return;
                            }
                            handleExploreResult(result);
                          },
                        ),
                      if (effectiveProjectPath != null)
                        IconButton(
                          key: const ValueKey('appbar_view_changes'),
                          icon: Badge(
                            isLabelVisible: gitBadgeTone != null,
                            backgroundColor: _gitBadgeColor(
                              context,
                              gitBadgeTone,
                            ),
                            smallSize: 8,
                            child: Icon(
                              Icons.difference,
                              size: 18,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 32,
                            minHeight: 32,
                          ),
                          onPressed: () {
                            _openGitScreen(
                              context,
                              worktreePath ?? effectiveProjectPath,
                              diffSelectionFromNav,
                              sessionId: sessionId,
                              worktreePath: worktreePath,
                              onFilePeekOpened: handleFilePeekOpened,
                            );
                          },
                        ),
                      if (showMessageHistoryAction)
                        IconButton(
                          key: const ValueKey('appbar_message_history_button'),
                          icon: Icon(
                            Icons.history,
                            size: 18,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 32,
                            minHeight: 32,
                          ),
                          tooltip: l.messageHistory,
                          onPressed: () {
                            _showUserMessageHistory(
                              context,
                              scrollToUserEntry,
                              sessionId,
                              chatInputController,
                              draftService,
                            );
                          },
                        ),
                      if (canCopyCodexCliJoinCommand)
                        IconButton(
                          key: const ValueKey('appbar_copy_codex_join_button'),
                          icon: Icon(
                            Icons.terminal,
                            size: 18,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 32,
                            minHeight: 32,
                          ),
                          tooltip: l.copyCodexCliJoinCommand,
                          onPressed: () => _copyCodexCliJoinCommand(
                            context,
                            codexCliJoinCommand.value!,
                          ),
                        ),
                      PopupMenuButton<String>(
                        key: const ValueKey('session_overflow_menu'),
                        icon: Icon(
                          Icons.more_horiz,
                          size: 18,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                        onSelected: (value) {
                          final localFeatureId =
                              LocalSessionFeatureHost.featureIdFromMenuValue(
                                value,
                              );
                          if (localFeatureId != null) {
                            unawaited(
                              localFeatureContext.openPane(
                                localFeatureId,
                                arguments: const {},
                              ),
                            );
                            return;
                          }
                          switch (value) {
                            case 'history':
                              _showUserMessageHistory(
                                context,
                                scrollToUserEntry,
                                sessionId,
                                chatInputController,
                                draftService,
                              );
                            case 'screenshot':
                              if (effectiveProjectPath == null) return;
                              showScreenshotSheet(
                                context: context,
                                bridge: context.read<BridgeService>(),
                                projectPath: effectiveProjectPath,
                                sessionId: sessionId,
                              );
                            case 'gallery':
                              _openGalleryScreen(context, sessionId: sessionId);
                            case 'rename':
                              _renameSession(context, sessionId);
                            case 'goal':
                              unawaited(
                                CodexGoalManagement.showManager(context),
                              );
                            case 'terminal':
                              _openInTerminal(context, effectiveProjectPath);
                            case 'collapse_all':
                              collapseToolResults.value++;
                          }
                        },
                        itemBuilder: (context) {
                          final terminalConfig = context
                              .read<SettingsCubit>()
                              .state
                              .terminalApp;
                          final l = AppLocalizations.of(context);
                          return [
                            PopupMenuItem(
                              key: const ValueKey('menu_rename'),
                              value: 'rename',
                              child: ListTile(
                                leading: const Icon(
                                  Icons.edit_outlined,
                                  size: 20,
                                ),
                                title: Text(l.rename),
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                              ),
                            ),
                            PopupMenuItem(
                              key: const ValueKey('menu_goal'),
                              value: 'goal',
                              enabled:
                                  sessionState.goalSupport !=
                                  CodexGoalSupport.unsupported,
                              child: ListTile(
                                leading: const Icon(
                                  Icons.track_changes,
                                  size: 20,
                                ),
                                title: Text(
                                  currentGoal == null
                                      ? sessionState.goalStateLoaded
                                            ? l.goalStart
                                            : l.goalTitle
                                      : l.goalManage,
                                ),
                                subtitle:
                                    sessionState.goalSupport ==
                                        CodexGoalSupport.unsupported
                                    ? Text(l.goalUnavailable)
                                    : null,
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                              ),
                            ),
                            if (!showMessageHistoryAction)
                              PopupMenuItem(
                                key: const ValueKey('menu_message_history'),
                                value: 'history',
                                child: ListTile(
                                  leading: const Icon(
                                    Icons.chat_outlined,
                                    size: 20,
                                  ),
                                  title: Text(l.messageHistory),
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                ),
                              ),
                            if (effectiveProjectPath != null)
                              PopupMenuItem(
                                key: const ValueKey('menu_screenshot'),
                                value: 'screenshot',
                                child: ListTile(
                                  leading: const Icon(
                                    Icons.screenshot_monitor,
                                    size: 20,
                                  ),
                                  title: Text(l.screenshot),
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                ),
                              ),
                            PopupMenuItem(
                              key: const ValueKey('menu_gallery'),
                              value: 'gallery',
                              child: ListTile(
                                leading: const Icon(
                                  Icons.collections,
                                  size: 20,
                                ),
                                title: Text(l.gallery),
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                              ),
                            ),
                            PopupMenuItem(
                              key: const ValueKey('menu_collapse_all'),
                              value: 'collapse_all',
                              child: ListTile(
                                leading: const Icon(
                                  Icons.unfold_less_double,
                                  size: 20,
                                ),
                                title: Text(
                                  Localizations.localeOf(
                                            context,
                                          ).languageCode ==
                                          'zh'
                                      ? '一键全部折叠'
                                      : 'Collapse all',
                                ),
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                              ),
                            ),
                            ...LocalSessionFeatureHost.overflowMenuItems(
                              localFeatureContext,
                            ),
                            if (FeatureFlags.current.isEnabled(
                                  AppFeature.terminalAppIntegration,
                                ) &&
                                terminalConfig.isConfigured &&
                                effectiveProjectPath != null)
                              PopupMenuItem(
                                key: const ValueKey('menu_terminal'),
                                value: 'terminal',
                                child: ListTile(
                                  leading: const Icon(Icons.terminal, size: 20),
                                  title: Text(l.openInTerminal),
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                ),
                              ),
                          ];
                        },
                      ),
                    ],
                  ),
                ),
                body: sessionState.sessionUnavailable
                    ? SessionUnavailableView(
                        onOpenRecentSessions:
                            onBackToSessions ??
                            () {
                              context.router.replaceAll([AdaptiveHomeRoute()]);
                            },
                      )
                    : child,
              );
            },
            child: Stack(
              children: [
                Positioned.fill(
                  child: Column(
                    children: [
                      if (bridgeState == BridgeConnectionState.reconnecting ||
                          bridgeState == BridgeConnectionState.disconnected)
                        ReconnectBanner(bridgeState: bridgeState),
                      if (detachedPreview && deferredSubmissionPending)
                        DurableSessionBindingBanner(
                          queuedLocally:
                              bridgeState != BridgeConnectionState.connected,
                        ),
                      if (!isBackground)
                        ...LocalSessionFeatureHost.statusWidgets(
                          localFeatureContext,
                        ),
                      if (detachedPreview &&
                          latestTurnRecoveryVisible &&
                          sessionState.entries.isEmpty &&
                          onLatestTurnRecoveryRetry != null)
                        DurableLatestTurnRecoveryBanner(
                          onRetry: onLatestTurnRecoveryRetry!,
                        ),
                      Expanded(
                        child: BottomOverlayLayout(
                          overlay: interactionOverlay == null
                              ? null
                              : NotificationListener<ScrollNotification>(
                                  onNotification: (notification) {
                                    if (notification
                                        is UserScrollNotification) {
                                      FocusScope.of(context).unfocus();
                                    }
                                    return false;
                                  },
                                  child: SingleChildScrollView(
                                    reverse: true,
                                    child: interactionOverlay,
                                  ),
                                ),
                          topOverlay: Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            child: Center(
                              child: SessionModeBar(
                                trailingWidgets:
                                    LocalSessionFeatureHost.modeBarWidgets(
                                      localFeatureContext,
                                    ),
                                showExtendedCodexEfforts: context
                                    .watch<SettingsCubit>()
                                    .state
                                    .showExtendedCodexEfforts,
                                onBeforeRestart: () async {
                                  draftService.saveDraft(
                                    sessionId,
                                    chatInputController.text,
                                  );
                                },
                              ),
                            ),
                          ),
                          floatingButtonBuilder: (overlayHeight) {
                            if (!scroll.isScrolledUp) {
                              return const SizedBox.shrink();
                            }
                            return Positioned(
                              right: 12,
                              bottom: overlayHeight + 12,
                              child: ScrollToBottomButton(
                                onPressed: () {
                                  if (scroll.controller.hasClients) {
                                    scroll.controller.animateTo(
                                      0.0,
                                      duration: const Duration(
                                        milliseconds: 200,
                                      ),
                                      curve: Curves.easeOut,
                                    );
                                  }
                                },
                              ),
                            );
                          },
                          content: ChatMessageList(
                            sessionId: sessionId,
                            scrollController: scroll.controller,
                            httpBaseUrl: context
                                .read<BridgeService>()
                                .httpBaseUrl,
                            projectPath: chatFileRoot,
                            onRetryMessage: (entry) {
                              final accepted = context
                                  .read<ChatSessionCubit>()
                                  .retryMessage(entry);
                              if (accepted || !context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    l.conversationRetryWaitingForRuntime,
                                  ),
                                ),
                              );
                            },
                            onRewindMessage: (entry) {
                              _showCodexRewindDialog(
                                context,
                                entry,
                                sessionId: sessionId,
                                inputController: chatInputController,
                                draftService: draftService,
                              );
                            },
                            onForkMessage: allowMessageFork
                                ? (message) {
                                    unawaited(
                                      _forkCodexFromAssistant(context, message),
                                    );
                                  }
                                : null,
                            selectionActions:
                                LocalSessionFeatureHost.selectionActions(
                                  localFeatureContext,
                                ),
                            scrollToUserEntry: scrollToUserEntry,
                            collapseToolResults: collapseToolResults,
                            bottomPadding: 8,
                            isCodex: true,
                            onFilePeekOpened: context
                                .read<ChatSessionCubit>()
                                .recordPeekedFile,
                          ),
                        ),
                      ),
                      if (approval is ApprovalNone)
                        if (currentGoal != null)
                          CodexGoalCard(
                            goal: currentGoal,
                            busy: sessionState.goalMutation != null,
                            busyLabel: CodexGoalManagement.mutationLabel(
                              sessionState.goalMutation?.kind,
                              l,
                            ),
                            controlsEnabled:
                                bridgeState ==
                                    BridgeConnectionState.connected &&
                                sessionState.goalStateLoaded &&
                                sessionState.goalSupport ==
                                    CodexGoalSupport.supported &&
                                sessionState.goal?.hasUnknownStatus != true,
                            disabledLabel:
                                CodexGoalManagement.controlsDisabledLabel(
                                  sessionState,
                                  sessionState.goal!,
                                  l,
                                ),
                            onEdit: () => unawaited(
                              CodexGoalManagement.showEditor(
                                context,
                                sessionState.goal,
                              ),
                            ),
                            onTogglePaused: () {
                              final goal = sessionState.goal;
                              if (goal == null) return;
                              if (goal.status ==
                                      CodexThreadGoalStatus.blocked ||
                                  goal.status ==
                                      CodexThreadGoalStatus.usageLimited) {
                                context.read<ChatSessionCubit>().resumeGoal();
                                return;
                              }
                              context
                                  .read<ChatSessionCubit>()
                                  .toggleGoalPaused();
                            },
                            onResolveBudget:
                                chatSessionCubit.supportsAdvancedGoalControl
                                ? () => unawaited(
                                    CodexGoalManagement.showEditor(
                                      context,
                                      sessionState.goal,
                                      resumeAfterSave: true,
                                    ),
                                  )
                                : null,
                            onClear: () => unawaited(
                              CodexGoalManagement.confirmClear(
                                context,
                                sessionState.goal!,
                              ),
                            ),
                          ),
                      if (approval is ApprovalNone)
                        if (queuedInputs.isNotEmpty)
                          ValueListenableBuilder<bool>(
                            valueListenable: context
                                .read<ChatSessionCubit>()
                                .externalDesktopTurnSteerable,
                            builder: (context, turnSteerable, _) => ConstrainedBox(
                              constraints: const BoxConstraints(maxHeight: 260),
                              child: ListView.builder(
                                key: const ValueKey('codex_queue_list'),
                                shrinkWrap: true,
                                itemCount: queuedInputs.length,
                                itemBuilder: (context, index) {
                                  final item = queuedInputs[index];
                                  final isOffline =
                                      ChatSessionCubit.isOfflineQueuedInput(
                                        item,
                                      );
                                  final isDeliveryPending =
                                      ChatSessionCubit.isDeliveryPendingQueuedInput(
                                        item,
                                      );
                                  return CodexQueuedInputPanel(
                                    key: ValueKey('codex_queue_${item.itemId}'),
                                    item: item,
                                    isOfflinePending: isOffline,
                                    isDeliveryPending: isDeliveryPending,
                                    onSteer:
                                        isOffline ||
                                            isDeliveryPending ||
                                            (sessionState
                                                    .externalDesktopTurnActive &&
                                                !turnSteerable)
                                        ? null
                                        : () => chatSessionCubit
                                              .steerQueuedInput(item),
                                    onEdit: () => unawaited(
                                      moveQueuedInputToComposer(
                                        inputController: chatInputController,
                                        item: item,
                                        cancelQueuedInput: () =>
                                            chatSessionCubit.cancelQueuedInput(
                                              item,
                                            ),
                                      ),
                                    ),
                                    onCancel: () => unawaited(
                                      chatSessionCubit.cancelQueuedInput(item),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                      if (approval is ApprovalNone)
                        ChatInputWithOverlays(
                          sessionId: sessionId,
                          status: status,
                          onScrollToBottom: scroll.scrollToBottom,
                          inputController: chatInputController,
                          hintText: l.codexMessagePlaceholder,
                          inputBlocked:
                              (detachedPreview && deferredSubmissionPending) ||
                              chatSessionCubit.codexInputQueueFull,
                          onSubmit: detachedPreview
                              ? submitWhileAttaching
                              : null,
                          initialDiffSelection: diffSelectionFromNav.value,
                          onDiffSelectionConsumed: () {},
                          onDiffSelectionCleared: () =>
                              diffSelectionFromNav.value = null,
                          onOpenGitScreen: effectiveProjectPath != null
                              ? (_) => _openGitScreen(
                                  context,
                                  worktreePath ?? effectiveProjectPath,
                                  diffSelectionFromNav,
                                  sessionId: sessionId,
                                  worktreePath: worktreePath,
                                  onFilePeekOpened: handleFilePeekOpened,
                                )
                              : null,
                        ),
                    ],
                  ),
                ),
                if (!hideAuxiliaryDock && ephemeralSideChatRegistry != null)
                  Positioned.fill(
                    child: AuxiliaryFloatingDock(
                      key: ValueKey(
                        'auxiliary_dock_'
                        '${sessionInsightsSessionId ?? sessionId}',
                      ),
                      sessionId: sessionId,
                      durableSessionId:
                          sessionInsightsSessionId ??
                          sessionState.claudeSessionId,
                      parentProviderSessionId:
                          sessionInsightsSessionId ?? sessionId,
                      detachedSubagentsProviderThreadId: detachedPreview
                          ? sessionInsightsSessionId ?? sessionId
                          : null,
                      detachedSubagentsCodexSourceId: detachedPreview
                          ? dataSourceIdentity.codexSourceId
                          : null,
                      bridgeService: bridge,
                      registryService: ephemeralSideChatRegistry,
                      legacyRuntimeParentSessionId: detachedPreview
                          ? liveRuntimeSessionId
                          : sessionId,
                      onSendTodo: sendFloatingTodo,
                      onOpenSideChat:
                          (parentSessionId, parentProviderSessionId, entry) =>
                              _openLocalFeaturePaneOrSheet(
                                context,
                                featureId: 'side_chat',
                                sessionId: parentSessionId,
                                arguments: entry == null
                                    ? {
                                        'forceNew': true,
                                        'parentProviderSessionId':
                                            parentProviderSessionId,
                                      }
                                    : {
                                        'childSessionId': entry.childSessionId,
                                        'parentProviderSessionId':
                                            parentProviderSessionId,
                                      },
                              ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Widget? _sessionAppBarLeading(
  BuildContext context,
  WorkspaceShellScreenState? shell, {
  required WorkspacePaneChrome chrome,
  VoidCallback? onBackToSessions,
  bool hideSessionBackButton = false,
}) {
  final l = AppLocalizations.of(context);
  if (!hideSessionBackButton && onBackToSessions != null) {
    return BackButton(
      key: const ValueKey('session_back_button'),
      onPressed: onBackToSessions,
    );
  }
  if (shell?.shouldShowLeftPaneButton ?? false) {
    final theme = Theme.of(context);
    final fabTheme = theme.floatingActionButtonTheme;
    return IconButton(
      key: const ValueKey('show_left_pane_button'),
      onPressed: shell!.toggleLeftPaneVisibility,
      tooltip: l.showSessions,
      style: chrome.useMacOSAdaptiveChrome
          ? chrome.compactButtonStyle()
          : IconButton.styleFrom(
              backgroundColor:
                  fabTheme.backgroundColor ??
                  theme.colorScheme.primaryContainer,
              foregroundColor:
                  fabTheme.foregroundColor ??
                  theme.colorScheme.onPrimaryContainer,
            ),
      icon: const Icon(Icons.chevron_right),
    );
  }
  if (hideSessionBackButton) {
    return null;
  }
  return BackButton(
    key: const ValueKey('session_back_button'),
    onPressed: () => Navigator.of(context).maybePop(),
  );
}

WorkspacePaneChrome _resolveSessionPaneChrome(
  BuildContext context,
  WorkspaceShellScreenState? shell,
) {
  return resolveWorkspacePaneChrome(
    platform: Theme.of(context).platform,
    isAdaptiveWorkspace: shell != null && !shell.isSinglePane,
    isLeftPaneVisible: shell?.isLeftPaneVisible ?? false,
    slot: WorkspacePaneSlot.center,
  );
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

enum _GitBadgeTone { dirty, remote }

String? _firstNonEmptyProjectPath(String? primary, String? fallback) {
  if (primary?.trim().isNotEmpty == true) return primary;
  if (fallback?.trim().isNotEmpty == true) return fallback;
  return null;
}

_GitBadgeTone? _gitBadgeToneOf(
  BuildContext context,
  String sessionId,
  String? projectPath, {
  required bool showRemoteGitStatusBadge,
}) {
  if (projectPath == null || projectPath.isEmpty) return null;
  try {
    return context.select((GitStatusCubit cubit) {
      final entry = cubit.state.entryFor(sessionId);
      if (entry?.projectPath != projectPath) return null;
      if (entry?.showDirtyBadge == true) return _GitBadgeTone.dirty;
      if (entry?.showRemoteBadge(enabled: showRemoteGitStatusBadge) == true) {
        return _GitBadgeTone.remote;
      }
      return null;
    });
  } catch (_) {
    return null;
  }
}

Color? _gitBadgeColor(BuildContext context, _GitBadgeTone? tone) {
  final error = Theme.of(context).colorScheme.error;
  return switch (tone) {
    _GitBadgeTone.dirty => error,
    _GitBadgeTone.remote => error.withValues(alpha: 0.45),
    null => null,
  };
}

Future<void> _openGitScreen(
  BuildContext context,
  String projectPath,
  ValueNotifier<DiffSelection?> diffSelectionNotifier, {
  String? sessionId,
  String? worktreePath,
  ValueChanged<String>? onFilePeekOpened,
}) async {
  final shell = WorkspaceShellScreen.maybeOf(context);
  if (shell?.canOpenToolPane ?? false) {
    shell!.openGitPane(
      projectPath: projectPath,
      sessionId: sessionId,
      worktreePath: worktreePath,
      diffSelectionNotifier: diffSelectionNotifier,
      onFilePeekOpened: onFilePeekOpened,
    );
    return;
  }
  final selection = await context.router.push<DiffSelection>(
    GitRoute(
      projectPath: projectPath,
      sessionId: sessionId,
      worktreePath: worktreePath,
      onFilePeekOpened: onFilePeekOpened,
    ),
  );
  if (selection != null) {
    diffSelectionNotifier.value = selection.isEmpty ? null : selection;
  }
}

Future<void> _openLocalFeaturePaneOrSheet(
  BuildContext context, {
  required String featureId,
  required String sessionId,
  Map<String, Object?> arguments = const {},
}) async {
  final descriptor = LocalSessionFeatureHost.paneDescriptor(featureId);
  if (descriptor == null) return;

  final shell = WorkspaceShellScreen.maybeOf(context);
  if (shell?.openLocalFeaturePane(
        featureId: featureId,
        sessionId: sessionId,
        arguments: arguments,
      ) ??
      false) {
    return;
  }

  final bridge = context.read<BridgeService>();
  await showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (sheetContext) => FractionallySizedBox(
      heightFactor: descriptor.sheetHeightFactor,
      child: descriptor.builder(
        WorkspaceFeaturePaneContext(
          context: sheetContext,
          sessionId: sessionId,
          bridge: bridge,
          arguments: arguments,
          onClose: () => Navigator.of(sheetContext).pop(),
        ),
      ),
    ),
  );
}

void _openGalleryScreen(BuildContext context, {required String sessionId}) {
  final shell = WorkspaceShellScreen.maybeOf(context);
  if (shell?.canOpenToolPane ?? false) {
    shell!.openSessionGalleryPane(sessionId: sessionId);
    return;
  }
  context.router.push(GalleryRoute(sessionId: sessionId));
}

void _executeSideEffects(
  Set<ChatSideEffect> effects, {
  required String sessionId,
  required BridgeDataSourceIdentity dataSourceIdentity,
  required bool isBackground,
  required ApprovalState approval,
  required AppLocalizations l,
  required TextEditingController planFeedbackController,
  required ValueNotifier<int> collapseToolResults,
  required VoidCallback scrollToBottom,
}) {
  for (final effect in effects) {
    switch (effect) {
      case ChatSideEffect.heavyHaptic:
        HapticFeedback.heavyImpact();
      case ChatSideEffect.mediumHaptic:
        HapticFeedback.mediumImpact();
      case ChatSideEffect.lightHaptic:
        HapticFeedback.lightImpact();
      case ChatSideEffect.collapseToolResults:
        collapseToolResults.value++;
      case ChatSideEffect.clearPlanFeedback:
        planFeedbackController.clear();
      case ChatSideEffect.notifyApprovalRequired:
        if (isBackground) {
          final permission = _notificationPermissionFor(approval);
          if (permission != null) {
            NotificationService.instance.showApprovalNotification(
              permission,
              l: l,
              id: 1,
              payload: encodeSessionNotificationPayload(
                sessionId: sessionId,
                provider: Provider.codex.value,
                eventType: NotificationPreferences.approvalRequiredEvent,
                permissionId: permission.toolUseId,
                dataSourceIdentity: dataSourceIdentity,
              ),
            );
          }
        }
      case ChatSideEffect.notifyAskQuestion:
        if (isBackground) {
          final permission = _notificationPermissionFor(approval);
          if (permission != null) {
            NotificationService.instance.showApprovalNotification(
              permission,
              l: l,
              id: 2,
              payload: encodeSessionNotificationPayload(
                sessionId: sessionId,
                provider: Provider.codex.value,
                eventType: NotificationPreferences.askUserQuestionEvent,
                permissionId: permission.toolUseId,
                dataSourceIdentity: dataSourceIdentity,
              ),
            );
          }
        }
      case ChatSideEffect.notifySessionComplete:
        if (isBackground) {
          NotificationService.instance.showSessionCompleteNotification(
            title: l.sessionCompleteTitle,
            body: l.sessionDone,
            id: 3,
            payload: encodeSessionNotificationPayload(
              sessionId: sessionId,
              provider: Provider.codex.value,
              eventType: NotificationPreferences.sessionCompletedEvent,
              dataSourceIdentity: dataSourceIdentity,
            ),
          );
        }
      case ChatSideEffect.scrollToBottom:
        scrollToBottom();
    }
  }
}

PermissionRequestMessage? _notificationPermissionFor(ApprovalState approval) {
  return switch (approval) {
    ApprovalPermission(:final request) => request,
    ApprovalAskUser(:final toolUseId, :final input) => PermissionRequestMessage(
      toolUseId: toolUseId,
      toolName: 'AskUserQuestion',
      input: input,
    ),
    ApprovalNone() => null,
    _ => null,
  };
}

Future<void> _openInTerminal(BuildContext context, String? projectPath) async {
  if (!FeatureFlags.current.isEnabled(AppFeature.terminalAppIntegration)) {
    return;
  }
  if (projectPath == null) return;
  final config = context.read<SettingsCubit>().state.terminalApp;
  if (!config.isConfigured) return;

  final bridge = context.read<BridgeService>();
  final url = bridge.lastUrl;
  final uri = url != null
      ? Uri.tryParse(
          url
              .replaceFirst('ws://', 'http://')
              .replaceFirst('wss://', 'https://'),
        )
      : null;
  final host = normalizeHostInput(uri?.host ?? '');

  // Resolve SSH user from machine config
  String? sshUser;
  try {
    final machines = context.read<MachineManagerCubit>().state.machines;
    for (final item in machines) {
      if (canonicalHostIdentity(item.machine.host) ==
          canonicalHostIdentity(host)) {
        sshUser = item.machine.sshUsername;
        break;
      }
    }
  } catch (_) {
    // MachineManagerCubit may not be available
  }

  final launched = await launchTerminalApp(
    config: config,
    host: host,
    sshUser: sshUser,
    projectPath: projectPath,
  );

  if (!launched && context.mounted) {
    final l = AppLocalizations.of(context);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l.terminalAppNotInstalled)));
  }
}

Future<void> _renameSession(BuildContext context, String sessionId) async {
  final bridge = context.read<BridgeService>();
  final sessions = bridge.sessions;
  final session = sessions.where((s) => s.id == sessionId).firstOrNull;
  final newName = await showRenameSessionDialog(
    context,
    currentName: session?.name,
  );
  if (newName == null || !context.mounted) return;
  bridge.renameSession(
    sessionId: sessionId,
    name: newName.isEmpty ? null : newName,
  );
}

void _showUserMessageHistory(
  BuildContext context,
  ValueNotifier<UserChatEntry?> scrollToUserEntry,
  String sessionId,
  TextEditingController inputController,
  DraftService draftService,
) {
  final cubit = context.read<ChatSessionCubit>();

  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    constraints: macOSModalBottomSheetConstraints(context),
    useSafeArea: true,
    builder: (_) => UserMessageHistoryLoaderSheet(
      loadMessages: cubit.loadAllUserMessagesForNavigation,
      isUserMessageIndexComplete: () => cubit.localHistoryUserIndexComplete,
      refreshListenable: cubit.localHistoryIndexRevision,
      onScrollToMessage: (msg) async {
        final loaded = await cubit.revealUserMessage(msg);
        if (loaded == null) return false;
        scrollToUserEntry.value = loaded;
        return true;
      },
      onRewindMessage: (msg) => _showCodexRewindDialog(
        context,
        msg,
        sessionId: sessionId,
        inputController: inputController,
        draftService: draftService,
      ),
    ),
  );
}

void _showCodexRewindDialog(
  BuildContext context,
  UserChatEntry message, {
  required String sessionId,
  required TextEditingController inputController,
  required DraftService draftService,
}) {
  final cubit = context.read<ChatSessionCubit>();

  if (message.messageUuid == null) return;

  showDialog<void>(
    context: context,
    builder: (dialogContext) {
      return CodexRewindDialog(
        messageText: message.text,
        onConfirm: () {
          Navigator.of(dialogContext).pop();
          _restoreRewindMessageToComposer(
            inputController: inputController,
            draftService: draftService,
            sessionId: sessionId,
            text: message.text,
          );
          cubit.rewind(message.messageUuid!, 'conversation');
        },
      );
    },
  );
}

Future<void> _forkCodexFromAssistant(
  BuildContext context,
  AssistantServerMessage message,
) async {
  final cubit = context.read<ChatSessionCubit>();
  final l = AppLocalizations.of(context);
  final targetUuid = _previousUserUuidForAssistant(
    cubit.state.entries,
    message,
  );
  if (targetUuid == null) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l.forkTargetNotFound)));
    return;
  }

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      return AlertDialog(
        title: Text(l.forkConversationTitle),
        content: Text(l.forkConversationBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l.fork),
          ),
        ],
      );
    },
  );
  if (confirmed != true || !context.mounted) return;

  cubit.forkSession(targetUuid);
}

String? _previousUserUuidForAssistant(
  List<ChatEntry> entries,
  AssistantServerMessage message,
) {
  final index = entries.indexWhere(
    (entry) => entry is ServerChatEntry && identical(entry.message, message),
  );
  if (index <= 0) return null;

  for (var i = index - 1; i >= 0; i--) {
    final entry = entries[i];
    if (entry is UserChatEntry &&
        entry.messageUuid != null &&
        entry.messageUuid!.isNotEmpty) {
      return entry.messageUuid;
    }
  }
  return null;
}

void _restoreRewindMessageToComposer({
  required TextEditingController inputController,
  required DraftService draftService,
  required String sessionId,
  required String text,
}) {
  inputController.value = TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: text.length),
  );
  draftService.saveDraft(sessionId, text);
}

@visibleForTesting
Future<bool> moveQueuedInputToComposer({
  required TextEditingController inputController,
  required QueuedInputItem item,
  required Future<bool> Function() cancelQueuedInput,
}) async {
  if (!await cancelQueuedInput()) return false;
  inputController.value = TextEditingValue(
    text: item.text,
    selection: TextSelection.collapsed(offset: item.text.length),
  );
  return true;
}

class CodexQueuedInputPanel extends StatelessWidget {
  const CodexQueuedInputPanel({
    super.key,
    required this.item,
    required this.onSteer,
    required this.onEdit,
    required this.onCancel,
    this.isOfflinePending = false,
    this.isDeliveryPending = false,
  });

  final QueuedInputItem item;
  final VoidCallback? onSteer;
  final VoidCallback? onEdit;
  final VoidCallback? onCancel;
  final bool isOfflinePending;
  final bool isDeliveryPending;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final l = AppLocalizations.of(context);
    final imageLabel = item.imageCount > 0
        ? ' · ${l.queuedInputImageCount(item.imageCount)}'
        : '';
    final title = isOfflinePending
        ? '${l.queuedInputForReconnect}$imageLabel'
        : isDeliveryPending
        ? '${l.queuedInputPendingDelivery}$imageLabel'
        : '${l.queuedInputForNextTurn}$imageLabel';
    final deliveryIcon = switch (item.deliveryStage) {
      QueuedInputDeliveryStage.bridgeAccepted => Icon(
        Icons.check,
        key: const ValueKey('codex_queue_bridge_accepted'),
        size: 18,
        color: cs.primary,
      ),
      QueuedInputDeliveryStage.providerAccepted => Icon(
        Icons.done_all,
        key: const ValueKey('codex_queue_provider_accepted'),
        size: 18,
        color: cs.primary,
      ),
      QueuedInputDeliveryStage.providerRejected => Icon(
        Icons.error_outline,
        key: const ValueKey('codex_queue_provider_rejected'),
        size: 18,
        color: cs.error,
      ),
      null => Icon(
        Icons.schedule,
        key: const ValueKey('codex_queue_waiting'),
        size: 18,
        color: cs.primary,
      ),
    };

    return Material(
      key: const ValueKey('codex_queue_panel'),
      color: cs.surfaceContainerHighest,
      child: SafeArea(
        top: false,
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: deliveryIcon,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: textTheme.labelMedium?.copyWith(
                        color: cs.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      item.text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodyMedium?.copyWith(
                        color: cs.onSurface,
                      ),
                    ),
                    if (item.deliveryStage ==
                            QueuedInputDeliveryStage.providerRejected &&
                        item.deliveryError?.trim().isNotEmpty == true) ...[
                      const SizedBox(height: 3),
                      Text(
                        item.deliveryError!,
                        key: const ValueKey('codex_queue_delivery_error'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall?.copyWith(color: cs.error),
                      ),
                    ],
                  ],
                ),
              ),
              if (!isDeliveryPending)
                IconButton(
                  key: const ValueKey('codex_queue_steer_button'),
                  tooltip: l.tooltipSteerQueuedMessage,
                  icon: const Icon(Icons.subdirectory_arrow_left, size: 20),
                  onPressed: onSteer,
                ),
              if (!isDeliveryPending) ...[
                IconButton(
                  key: const ValueKey('codex_queue_edit_button'),
                  tooltip: l.tooltipMoveQueuedMessageToInput,
                  icon: const Icon(Icons.edit_outlined, size: 20),
                  onPressed: onEdit,
                ),
                IconButton(
                  key: const ValueKey('codex_queue_cancel_button'),
                  tooltip: l.tooltipCancelQueuedMessage,
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: onCancel,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

void _retryFailedMessages(BuildContext context) {
  final cubit = context.read<ChatSessionCubit>();
  for (final entry in cubit.state.entries) {
    if (entry is UserChatEntry && entry.status.canRetry) {
      cubit.retryMessage(entry);
    }
  }
}

String? _latestCodexCliJoinCommand(List<ServerMessage> messages) {
  for (final msg in messages.reversed) {
    if (msg case SystemMessage(
      :final codexCliJoin,
    ) when codexCliJoin?.isValid == true) {
      return codexCliJoin!.command.trim();
    }
  }
  return null;
}

bool _hasSentUserMessage(List<ChatEntry> entries) {
  return entries.any(
    (entry) => entry is UserChatEntry && entry.status == MessageStatus.sent,
  );
}

Future<void> _copyCodexCliJoinCommand(
  BuildContext context,
  String command,
) async {
  await Clipboard.setData(ClipboardData(text: command));
  if (!context.mounted) return;
  final l = AppLocalizations.of(context);
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(l.codexCliJoinCommandCopied)));
}

String? _extractPlanText(
  PermissionRequestMessage? pendingPermission,
  List<ChatEntry> entries,
) {
  final raw = pendingPermission?.input['plan'];
  if (raw is String && raw.trim().isNotEmpty) {
    return raw;
  }

  for (var i = entries.length - 1; i >= 0; i--) {
    final entry = entries[i];
    if (entry is! ServerChatEntry) continue;
    final msg = entry.message;
    if (msg is! AssistantServerMessage) continue;

    for (final content in msg.message.content) {
      if (content is ToolUseContent && isCodexUpdatePlanTool(content.name)) {
        final text = codexPlanUpdateTextFromInput(content.input);
        if (text != null) return text;
      }
    }

    final text = msg.message.content
        .whereType<TextContent>()
        .map((c) => c.text.trim())
        .where((t) => t.isNotEmpty)
        .join('\n\n');
    if (text.startsWith('Plan update:')) {
      return text;
    }
  }

  return null;
}
