import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

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
import '../../router/app_router.dart';
import '../../router/session_stack_navigation.dart';
import '../../services/bridge_service.dart';
import '../../services/chat_message_handler.dart';
import '../../services/draft_service.dart';
import '../../utils/composer_tokens.dart';
import '../../services/notification_service.dart';
import '../../theme/app_theme.dart';
import '../../utils/diff_parser.dart';
import '../../utils/network_endpoint.dart';
import '../../utils/terminal_launcher.dart';
import '../session_list/pending_session_binding.dart';
import '../session_list/workspace_shell_screen.dart';
import '../conversation_content_sync/conversation_content_sync_service.dart';
import '../conversation_content_sync/conversation_route_focus_restorer.dart';
import '../session_list/cache/session_catalog_cache_repository.dart';
import '../session_link/widgets/session_unavailable_view.dart';
import '../settings/state/settings_cubit.dart';
import '../../widgets/approval_bar.dart';
import '../../widgets/bubbles/ask_user_question_widget.dart';
import '../../widgets/message_bubble.dart';
import '../../widgets/new_session_sheet.dart'
    show permissionModeFromRaw, sandboxModeFromRaw;
import '../../widgets/plan_detail_sheet.dart';
import '../../widgets/rename_session_dialog.dart';
import '../../widgets/screenshot_sheet.dart';
import '../../widgets/session_name_title.dart';
import '../../widgets/workspace_pane_chrome.dart';
import '../chat_session/state/chat_session_cubit.dart';
import '../chat_session/state/chat_session_state.dart';
import '../chat_session/state/streaming_state_cubit.dart';
import '../chat_session/session_manual_refresh.dart';
import '../chat_session/widgets/bottom_overlay_layout.dart';
import '../chat_session/widgets/chat_input_with_overlays.dart';
import '../chat_session/widgets/chat_message_list.dart';
import '../chat_session/widgets/durable_session_preview.dart';
import '../chat_session/widgets/reconnect_banner.dart';
import '../chat_session/widgets/scroll_to_bottom_button.dart';
import '../chat_session/widgets/session_mode_bar.dart';
import '../chat_session/widgets/status_line_flexible_space.dart';
import '../explore/state/explore_state.dart';
import '../git/state/git_status_cubit.dart';
import '../git/state/git_view_cache_service.dart';
import 'widgets/rewind_action_sheet.dart';
import 'widgets/rewind_message_list_sheet.dart'
    show UserMessageHistoryLoaderSheet;
import 'widgets/usage_summary_bar.dart';

const _fileListRefreshToolNames = {
  'Edit',
  'FileEdit',
  'MultiEdit',
  'Write',
  'NotebookEdit',
  'Bash',
};

class _NoopListenable implements Listenable {
  const _NoopListenable();

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}

/// Outer widget that creates screen-scoped [ChatSessionCubit] and
/// [StreamingStateCubit] via [MultiBlocProvider], replacing Riverpod's
/// Family (autoDispose) pattern.
///
/// When [isPending] is true, shows a loading overlay until [session_created]
/// is received from the bridge, then swaps to the real session.
@RoutePage()
class ClaudeSessionScreen extends StatefulWidget {
  final String sessionId;
  final String? projectPath;
  final String? gitBranch;
  final String? worktreePath;
  final bool isPending;
  final String? durableProviderSessionId;
  final String? initialPermissionMode;
  final String? initialSandboxMode;
  final VoidCallback? onBackToSessions;
  final bool hideSessionBackButton;
  final BridgeDataSourceIdentity? dataSourceIdentity;

  /// Notifier from the parent that may already hold a [SystemMessage]
  /// with subtype `session_created` (race condition fix).
  final ValueNotifier<SystemMessage?>? pendingSessionCreated;

  const ClaudeSessionScreen({
    super.key,
    required this.sessionId,
    this.projectPath,
    this.gitBranch,
    this.worktreePath,
    this.isPending = false,
    this.durableProviderSessionId,
    this.initialPermissionMode,
    this.initialSandboxMode,
    this.pendingSessionCreated,
    this.onBackToSessions,
    this.hideSessionBackButton = false,
    this.dataSourceIdentity,
  });

  @override
  State<ClaudeSessionScreen> createState() => _ClaudeSessionScreenState();
}

@RoutePage(name: 'WorkspaceClaudeSessionRoute')
class WorkspaceClaudeSessionScreen extends StatelessWidget {
  final String sessionId;
  final String? projectPath;
  final String? gitBranch;
  final String? worktreePath;
  final bool isPending;
  final String? initialPermissionMode;
  final String? initialSandboxMode;
  final ValueNotifier<SystemMessage?>? pendingSessionCreated;
  final VoidCallback? onBackToSessions;
  final bool hideSessionBackButton;

  const WorkspaceClaudeSessionScreen({
    super.key,
    required this.sessionId,
    this.projectPath,
    this.gitBranch,
    this.worktreePath,
    this.isPending = false,
    this.initialPermissionMode,
    this.initialSandboxMode,
    this.pendingSessionCreated,
    this.onBackToSessions,
    this.hideSessionBackButton = false,
  });

  @override
  Widget build(BuildContext context) {
    return ClaudeSessionScreen(
      sessionId: sessionId,
      projectPath: projectPath,
      gitBranch: gitBranch,
      worktreePath: worktreePath,
      isPending: isPending,
      initialPermissionMode: initialPermissionMode,
      initialSandboxMode: initialSandboxMode,
      pendingSessionCreated: pendingSessionCreated,
      onBackToSessions: onBackToSessions,
      hideSessionBackButton: hideSessionBackButton,
    );
  }
}

class _ClaudeSessionScreenState extends State<ClaudeSessionScreen> {
  late String _sessionId;
  late String? _projectPath;
  late String? _worktreePath;
  late String? _gitBranch;
  late bool _isPending;
  var _explorerCurrentPath = '';
  List<String> _recentPeekedFiles = const [];
  PermissionMode? _permissionMode;
  SandboxMode? _sandboxMode;
  StreamSubscription<ServerMessage>? _sessionSwitchSub;
  StreamSubscription<String>? _sessionStoppedSub;
  StreamSubscription<ConversationContentCacheUpdate>? _cachedPreviewSub;
  StreamSubscription<List<SessionInfo>>? _identitySessionListSub;
  StreamSubscription<List<RecentSession>>? _identityRecentSessionsSub;
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
  final Object _sessionRouteOwner = Object();
  Object? _sessionRouteIdentity;
  late BridgeDataSourceIdentity _dataSourceIdentity;

  @override
  void initState() {
    super.initState();
    final bridge = context.read<BridgeService>();
    _dataSourceIdentity =
        widget.dataSourceIdentity ?? bridge.dataSourceIdentity;
    _sessionId = widget.sessionId;
    _projectPath = widget.projectPath;
    _worktreePath = widget.worktreePath;
    _gitBranch = widget.gitBranch;
    _isPending = widget.isPending;
    _permissionMode = permissionModeFromRaw(widget.initialPermissionMode);
    _sandboxMode = sandboxModeFromRaw(widget.initialSandboxMode);
    _restoreDeferredSubmission();
    final explorerHistory = bridge.getExplorerHistory(_sessionId);
    _explorerCurrentPath = explorerHistory.currentPath;
    _recentPeekedFiles = explorerHistory.recentPeekedFiles;

    if (_isPending) {
      _listenForSessionCreated();
    }
    _startDurablePreview();
    _listenForSessionSwitch();
    _listenForSessionStopped();
    _listenForAuthoritativeDataSourceIdentity(bridge);
  }

  void _listenForAuthoritativeDataSourceIdentity(BridgeService bridge) {
    _identitySessionListSub = bridge.sessionList.listen((_) {
      _reconcileAuthoritativeDataSourceIdentity(bridge);
    });
    _identityRecentSessionsSub = bridge.recentSessionsStream.listen((_) {
      _reconcileAuthoritativeDataSourceIdentity(bridge);
    });
    _reconcileAuthoritativeDataSourceIdentity(bridge);
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
          session.provider == Provider.claude.value &&
          (session.id == _sessionId ||
              session.claudeSessionId == providerSessionId),
    );
    final catalogConfirmsThread =
        bridge.hasAuthoritativeRecentSessionsForCurrentConnection &&
        bridge.recentSessions.any(
          (session) =>
              session.provider == Provider.claude.value &&
              session.sessionId == providerSessionId,
        );
    if (!runtimeConfirmsThread && !catalogConfirmsThread) return;

    final authenticatedIdentity = bridge.dataSourceIdentity;
    final next = _dataSourceIdentity.reconciledWithAuthenticated(
      authenticatedIdentity,
      provider: Provider.claude.value,
      allowProvisionalRouteUpgrade: true,
    );
    if (!next.isSatisfiedBy(
      authenticatedIdentity,
      provider: Provider.claude.value,
    )) {
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
              provider: Provider.claude.value,
            )) {
          return;
        }
        shell?.reconcileSelectedSessionDataSourceIdentity(
          provider: Provider.claude,
          routeIdentitySessionId:
              widget.isPending && durableId?.isNotEmpty == true
              ? durableId!
              : _sessionId,
          previousIdentity: previousIdentity,
          authenticatedIdentity: authenticatedIdentity,
        );
      });
    }
    _reloadDurablePreviewForCurrentTarget();
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
        provider: Provider.claude.value,
      )) {
        sync.setFocusedConversation(
          provider: Provider.claude.value,
          providerSessionId: durableId,
        );
      }
      _cachedPreviewSub = sync.updates
          .where(
            (update) =>
                update.targetFingerprint == _expectedCacheTargetFingerprint &&
                update.provider == Provider.claude.value &&
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
        provider: Provider.claude.value,
      )) {
        return;
      }
      sync.setFocusedConversation(
        provider: Provider.claude.value,
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
      provider: Provider.claude.value,
    )) {
      return;
    }
    final targetFingerprint = sync.cacheTargetFingerprintForDataSource(
      _dataSourceIdentity,
    );
    final expectedFingerprintChanged =
        _expectedCacheTargetFingerprint != targetFingerprint;
    if (expectedFingerprintChanged) {
      // Preserve the mounted chat subtree while updating the source fence.
      // Without a rebuild, a canonical catalog can finish in the background
      // while the page keeps the provisional fingerprint until re-entry.
      setState(() => _expectedCacheTargetFingerprint = targetFingerprint);
    }
    if (sync.matchesCurrentDataSource(
      _dataSourceIdentity,
      provider: Provider.claude.value,
    )) {
      sync.setFocusedConversation(
        provider: Provider.claude.value,
        providerSessionId: durableId,
      );
    }
    if (_cachedPreviewTargetFingerprint == targetFingerprint &&
        (!_loadingCachedPreview ||
            _loadingCachedPreviewTargetFingerprint == targetFingerprint)) {
      return;
    }
    // Authentication can canonicalize an IP/route cache key to the stable
    // Bridge identity without changing the visible conversation. Retain the
    // last committed window until the confirmed target finishes loading; the
    // source-conflict fence above still rejects a different machine.
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
      provider: Provider.claude.value,
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
            provider: Provider.claude.value,
            providerSessionId: durableId,
            expectedDataSourceIdentity: _dataSourceIdentity,
          )
          .then((snapshot) {
            if (!mounted ||
                widget.durableProviderSessionId != durableId ||
                !_isPending ||
                sync.hasAuthoritativeDataSourceConflict(
                  _dataSourceIdentity,
                  provider: Provider.claude.value,
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
            debugPrint('Failed to load cached Claude preview: $error');
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
                provider: Provider.claude.value,
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
          provider: Provider.claude.value,
          providerSessionId: durableId,
          expectedDataSourceIdentity: _dataSourceIdentity,
        );
    return (loaded: result.loaded, hasMore: result.hasMore);
  }

  Future<bool> _repairLatestTurn() async =>
      (await context.read<ConversationContentSyncService>().repairLatestTurn(
        provider: Provider.claude.value,
        providerSessionId: widget.durableProviderSessionId!,
        expectedDataSourceIdentity: _dataSourceIdentity,
      )).loaded;

  bool _isCurrentDurablePreviewTargetConfirmed() {
    try {
      final sync = context.read<ConversationContentSyncService>();
      return sync.matchesCurrentDataSource(
            _dataSourceIdentity,
            provider: Provider.claude.value,
          ) &&
          !sync.hasAuthoritativeDataSourceConflict(
            _dataSourceIdentity,
            provider: Provider.claude.value,
          );
    } catch (_) {
      return false;
    }
  }

  bool _queueDeferredSubmission(ChatComposerSubmission submission) {
    if (!_isPending || _deferredSubmission != null) return false;
    setState(() => _deferredSubmission = submission);
    final binding = widget.pendingSessionCreated;
    if (binding is PendingSessionBinding) {
      unawaited(binding.requestAttachment());
    }
    return true;
  }

  void _consumeDeferredSubmission(ChatComposerSubmission submission) {
    if (_deferredSubmission != submission) return;
    final durableId = widget.durableProviderSessionId;
    if (durableId != null && durableId.isNotEmpty) {
      context.read<DraftService>().deletePendingSubmission(
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
    final submission = context.read<DraftService>().getPendingSubmission(
      durableId,
    );
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
    final draftService = context.read<DraftService>();
    unawaited(
      draftService
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
            debugPrint('Failed to preserve deferred Claude input: $error');
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
      sessionId: _sessionId,
      provider: 'claude',
      dataSourceIdentity: _dataSourceIdentity,
    );
    if (ModalRoute.of(context)?.isCurrent ?? false) {
      NotificationService.instance.setActiveSession(
        sessionId: _sessionId,
        provider: 'claude',
        dataSourceIdentity: _dataSourceIdentity,
      );
    }
  }

  void _listenForSessionCreated() {
    final pendingBinding = widget.pendingSessionCreated;
    if (pendingBinding is PendingSessionBinding) {
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
    final msg = widget.pendingSessionCreated?.value;
    if (msg != null && msg.sessionId != null && mounted && _isPending) {
      _resolveSession(msg);
    }
  }

  void _onPendingSessionFailed() {
    final binding = widget.pendingSessionCreated;
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

  /// Listen for session switches (clear context, rewind, etc.).
  /// When the bridge destroys the old session and creates a new one with
  /// sourceSessionId pointing to this session, we switch seamlessly.
  void _listenForSessionSwitch() {
    final bridge = context.read<BridgeService>();
    _sessionSwitchSub = bridge.messages.listen((msg) {
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

  void _resolveSession(SystemMessage msg) {
    widget.pendingSessionCreated?.removeListener(_onPendingSessionCreated);
    final binding = widget.pendingSessionCreated;
    if (binding is PendingSessionBinding) {
      binding.failure.removeListener(_onPendingSessionFailed);
    }
    final oldId = _sessionId;
    final newId = msg.sessionId!;
    // Migrate draft from pending ID to real session ID
    final draftService = context.read<DraftService>();
    draftService.migrateDraft(oldId, newId);
    draftService.migrateImageDraft(oldId, newId);
    final durableId = widget.durableProviderSessionId;
    if (durableId != null && durableId != oldId && durableId != newId) {
      draftService.migrateDraft(durableId, newId);
      draftService.migrateImageDraft(durableId, newId);
    }
    setState(() {
      _sessionId = newId;
      _projectPath = msg.projectPath ?? _projectPath;
      _worktreePath = msg.worktreePath ?? _worktreePath;
      _gitBranch = msg.worktreeBranch ?? _gitBranch;
      _permissionMode =
          permissionModeFromRaw(msg.permissionMode) ?? _permissionMode;
      _sandboxMode = sandboxModeFromRaw(msg.sandboxMode) ?? _sandboxMode;
      _isPending = false;
    });
    _syncSessionRouteIdentity();
  }

  void _listenForSessionStopped() {
    final bridge = context.read<BridgeService>();
    _sessionStoppedSub = bridge.stoppedSessions.listen((stoppedSessionId) {
      if (!mounted || stoppedSessionId != _sessionId) return;
      setState(() {
        _explorerCurrentPath = '';
        _recentPeekedFiles = const [];
      });
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

  /// Switch to a new session (e.g. after clear context / sandbox toggle).
  void _switchSession(SystemMessage msg) {
    final oldId = _sessionId;
    final newId = msg.sessionId!;
    final draftService = context.read<DraftService>();
    final bridge = context.read<BridgeService>();
    bridge.migrateExplorerHistory(oldId, newId);
    final explorerHistory = bridge.getExplorerHistory(newId);
    draftService.migrateDraft(oldId, newId);
    draftService.migrateImageDraft(oldId, newId);
    setState(() {
      _sessionId = newId;
      _projectPath = msg.projectPath ?? _projectPath;
      _worktreePath = msg.worktreePath ?? _worktreePath;
      _gitBranch = msg.worktreeBranch ?? _gitBranch;
      _permissionMode =
          permissionModeFromRaw(msg.permissionMode) ?? _permissionMode;
      _sandboxMode = sandboxModeFromRaw(msg.sandboxMode) ?? _sandboxMode;
      _explorerCurrentPath = explorerHistory.currentPath;
      _recentPeekedFiles = explorerHistory.recentPeekedFiles;
    });
    _syncSessionRouteIdentity();
  }

  @override
  void didUpdateWidget(covariant ClaudeSessionScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final bridge = context.read<BridgeService>();
    final identityCandidate =
        widget.dataSourceIdentity ?? bridge.dataSourceIdentity;
    final nextIdentity = _dataSourceIdentity.reconciledWithAuthenticated(
      identityCandidate,
      provider: Provider.claude.value,
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
        !identityChanged) {
      return;
    }

    if (pendingLifecycleChanged) {
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
      _permissionMode = permissionModeFromRaw(widget.initialPermissionMode);
      _sandboxMode = sandboxModeFromRaw(widget.initialSandboxMode);
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
    _detachPendingBinding(widget.pendingSessionCreated);
    _sessionSwitchSub?.cancel();
    _sessionStoppedSub?.cancel();
    _cachedPreviewSub?.cancel();
    _identitySessionListSub?.cancel();
    _identityRecentSessionsSub?.cancel();
    final durableId = widget.durableProviderSessionId;
    if (durableId != null) {
      try {
        context.read<ConversationContentSyncService>().clearFocusedConversation(
          provider: Provider.claude.value,
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
    if (_isPending && durableId != null) {
      return ConversationRouteFocusRestorer(
        onRouteCurrent: _restoreDurableConversationFocusIfCurrentSource,
        child: _ChatScreenProviders(
          key: ValueKey('durable-claude-$durableId'),
          sessionId: durableId,
          projectPath: _projectPath,
          gitBranch: _gitBranch,
          worktreePath: _worktreePath,
          permissionMode: _permissionMode,
          sandboxMode: _sandboxMode,
          detachedPreview: true,
          previewRevision: cachedPreview == null
              ? ''
              : conversationPresentationRevision(cachedPreview),
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
          deferredSubmissionPending: _deferredSubmission != null,
          onDeferredSubmit: _queueDeferredSubmission,
          onBackToSessions: widget.onBackToSessions,
          hideSessionBackButton: widget.hideSessionBackButton,
          dataSourceIdentity: _dataSourceIdentity,
        ),
      );
    }
    if (_isPending) {
      final l = AppLocalizations.of(context);
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
                durableId == null ? l.creatingSession : l.loadingSessionStatus,
                style: const TextStyle(fontSize: 16),
              ),
            ],
          ),
        ),
      );
    }

    final providers = _ChatScreenProviders(
      key: ValueKey(_sessionId),
      sessionId: _sessionId,
      projectPath: _projectPath,
      gitBranch: _gitBranch,
      worktreePath: _worktreePath,
      explorerCurrentPath: _explorerCurrentPath,
      recentPeekedFiles: _recentPeekedFiles,
      permissionMode: _permissionMode,
      sandboxMode: _sandboxMode,
      initialSubmission: _deferredSubmission,
      onInitialSubmissionConsumed: _consumeDeferredSubmission,
      onBackToSessions: widget.onBackToSessions,
      hideSessionBackButton: widget.hideSessionBackButton,
      dataSourceIdentity: _dataSourceIdentity,
    );
    return durableId == null
        ? providers
        : ConversationRouteFocusRestorer(
            onRouteCurrent: _restoreDurableConversationFocusIfCurrentSource,
            child: providers,
          );
  }
}

/// Wrapper that creates screen-scoped cubits once per session.
class _ChatScreenProviders extends StatelessWidget {
  final String sessionId;
  final String? projectPath;
  final String? gitBranch;
  final String? worktreePath;
  final String explorerCurrentPath;
  final List<String> recentPeekedFiles;
  final PermissionMode? permissionMode;
  final SandboxMode? sandboxMode;
  final VoidCallback? onBackToSessions;
  final bool hideSessionBackButton;
  final bool detachedPreview;
  final String previewRevision;
  final String historyRevision;
  final List<ServerMessage> initialHistoryMessages;
  final bool initialHistoryHasEarlier;
  final DetachedHistoryPageLoader? detachedHistoryPageLoader;
  final bool latestTurnRecoveryVisible;
  final LatestTurnRepairCallback? onLatestTurnRecoveryRetry;
  final String? expectedSourceFingerprint;
  final bool deferredSubmissionPending;
  final ChatComposerSubmitCallback? onDeferredSubmit;
  final ChatComposerSubmission? initialSubmission;
  final ValueChanged<ChatComposerSubmission>? onInitialSubmissionConsumed;
  final BridgeDataSourceIdentity dataSourceIdentity;

  const _ChatScreenProviders({
    super.key,
    required this.sessionId,
    this.projectPath,
    this.gitBranch,
    this.worktreePath,
    this.explorerCurrentPath = '',
    this.recentPeekedFiles = const [],
    this.permissionMode,
    this.sandboxMode,
    this.onBackToSessions,
    this.hideSessionBackButton = false,
    this.detachedPreview = false,
    this.previewRevision = '',
    this.historyRevision = '',
    this.initialHistoryMessages = const [],
    this.initialHistoryHasEarlier = false,
    this.detachedHistoryPageLoader,
    this.latestTurnRecoveryVisible = false,
    this.onLatestTurnRecoveryRetry,
    this.expectedSourceFingerprint,
    this.deferredSubmissionPending = false,
    this.onDeferredSubmit,
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
                provider: Provider.claude.value,
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
                  provider: Provider.claude.value,
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
                provider: Provider.claude.value,
                providerSessionId: sessionId,
                providerTurnId: providerTurnId,
                revision: historyRevision,
                expectedDataSourceIdentity: dataSourceIdentity,
              )
        : null;
    return MultiBlocProvider(
      providers: [
        BlocProvider(create: (_) => StreamingStateCubit()),
        BlocProvider(
          create: (context) {
            final cubit = ChatSessionCubit(
              sessionId: sessionId,
              provider: Provider.claude,
              bridge: bridge,
              streamingCubit: context.read<StreamingStateCubit>(),
              initialExplorerCurrentPath: explorerCurrentPath,
              initialRecentPeekedFiles: recentPeekedFiles,
              initialPermissionMode: permissionMode,
              initialSandboxMode: sandboxMode,
              initialProjectPath: projectPath,
              detachedPreview: detachedPreview,
              initialHistoryMessages: initialHistoryMessages,
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
        statusProvider: detachedPreview ? Provider.claude.value : null,
        statusProviderSessionId: detachedPreview ? sessionId : null,
        expectedSourceFingerprint: detachedPreview
            ? expectedSourceFingerprint
            : null,
        durableHistoryLoaderRevision: historyRevision,
        durableHistoryLoaderSourceFingerprint: expectedSourceFingerprint,
        detachedHistoryToolDetailLoader: toolDetailLoader,
        detachedUserMessageIndexLoader: userMessageIndexLoader,
        detachedUserTurnLoader: userTurnLoader,
        child: _ChatScreenBody(
          sessionId: sessionId,
          projectPath: projectPath,
          gitBranch: gitBranch,
          worktreePath: worktreePath,
          onBackToSessions: onBackToSessions,
          hideSessionBackButton: hideSessionBackButton,
          detachedPreview: detachedPreview,
          deferredSubmissionPending: deferredSubmissionPending,
          onDeferredSubmit: onDeferredSubmit,
          dataSourceIdentity: dataSourceIdentity,
          latestTurnRecoveryVisible: latestTurnRecoveryVisible,
          onLatestTurnRecoveryRetry: onLatestTurnRecoveryRetry,
        ),
      ),
    );
  }
}

class _ChatScreenBody extends HookWidget {
  final String sessionId;
  final String? projectPath;
  final String? gitBranch;
  final String? worktreePath;
  final VoidCallback? onBackToSessions;
  final bool hideSessionBackButton;
  final bool detachedPreview;
  final bool deferredSubmissionPending;
  final bool latestTurnRecoveryVisible;
  final LatestTurnRepairCallback? onLatestTurnRecoveryRetry;
  final ChatComposerSubmitCallback? onDeferredSubmit;
  final BridgeDataSourceIdentity dataSourceIdentity;

  const _ChatScreenBody({
    required this.sessionId,
    this.projectPath,
    this.gitBranch,
    this.worktreePath,
    this.onBackToSessions,
    this.hideSessionBackButton = false,
    this.detachedPreview = false,
    this.deferredSubmissionPending = false,
    this.latestTurnRecoveryVisible = false,
    this.onLatestTurnRecoveryRetry,
    this.onDeferredSubmit,
    required this.dataSourceIdentity,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final appColors = Theme.of(context).extension<AppColors>()!;
    final bridge = context.read<BridgeService>();
    final shell = WorkspaceShellScreen.maybeOf(context);
    final presentationListenable = shell?.presentationListenable;
    final workspaceStateKey = workspaceSessionStateKey(
      provider: Provider.claude.value,
      durableSessionId: sessionId,
      dataSourceIdentity: dataSourceIdentity,
    );

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
    final scroll = useScrollTracking(sessionId);
    useKeyboardScrollAdjustment(scroll.controller);

    // Plan feedback controller (for plan approval rejection message)
    final planFeedbackController = useTextEditingController();

    // Chat input controller (managed here to preserve text across rebuilds)
    final chatInputController = useMemoized(ComposerTextEditingController.new);
    useEffect(() => chatInputController.dispose, [chatInputController]);
    final draftService = context.read<DraftService>();
    final manualRefreshRunning = useState(false);

    Future<void> refreshConversation() async {
      if (manualRefreshRunning.value) return;
      manualRefreshRunning.value = true;
      ConversationContentSyncService? contentSync;
      try {
        contentSync = context.read<ConversationContentSyncService>();
      } catch (_) {}
      try {
        await refreshSessionFromBridge(
          bridge: bridge,
          chatSession: context.read<ChatSessionCubit>(),
          contentSync: contentSync,
          provider: Provider.claude.value,
          pageSessionId: sessionId,
          expectedDataSourceIdentity: dataSourceIdentity,
          runtimeSessionId: detachedPreview ? null : sessionId,
          detachedPreview: detachedPreview,
        );
      } finally {
        if (context.mounted) manualRefreshRunning.value = false;
      }
    }

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

    // Collapse tool results notifier
    final collapseToolResults = useMemoized(() => ValueNotifier<int>(0));
    useEffect(() => collapseToolResults.dispose, const []);

    // Scroll-to-user-entry notifier (set by message history sheet)
    final scrollToUserEntry = useMemoized(
      () => ValueNotifier<UserChatEntry?>(null),
    );
    useEffect(() => scrollToUserEntry.dispose, const []);

    // Diff selection from GitScreen navigation
    final diffSelectionFromNav = useState<DiffSelection?>(null);

    // --- Bloc state ---
    final chatSessionCubit = context.read<ChatSessionCubit>();
    final sessionState = context.watch<ChatSessionCubit>().state;
    final bridgeState = context.watch<ConnectionCubit>().state;
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
        .findAncestorStateOfType<_ClaudeSessionScreenState>();
    bool submitWhileAttaching(ChatComposerSubmission submission) {
      final accepted = onDeferredSubmit?.call(submission) ?? false;
      if (!accepted) return false;
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

    final tokenUsage = _collectTokenUsage(sessionState.entries);
    final toolUsage = _collectToolUsage(sessionState.entries);

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

    useEffect(() {
      if (chatFileRoot == null) return null;

      final bridge = context.read<BridgeService>();
      GitStatusCubit? gitStatusCubit;
      GitViewCacheService? gitViewCache;
      try {
        gitStatusCubit = context.read<GitStatusCubit>();
        gitViewCache = context.read<GitViewCacheService>();
      } catch (_) {}
      final sub = bridge.messagesForSession(sessionId).listen((msg) {
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
    }, [sessionId, chatFileRoot, gitProjectPath, showRemoteGitStatusBadge]);

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
    // If still connected, refresh history directly (BlocListener won't fire).
    // If disconnected, ensureConnected triggers reconnect → BlocListener
    // fires → refreshHistory is called there.
    useAppResumeCallback(lifecycleState, () {
      if (detachedPreview) return;
      final bridge = context.read<BridgeService>();
      bridge.ensureConnected();
      if (bridge.isConnected) {
        context.read<ChatSessionCubit>().refreshHistory();
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

    // Approval state pattern matching
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

    final isPlanApproval = pendingPermission?.toolName == 'ExitPlanMode';

    // --- Action callbacks ---
    void approveToolUse() {
      if (pendingToolUseId == null) return;
      context.read<ChatSessionCubit>().approve(pendingToolUseId);
      planFeedbackController.clear();
    }

    void approveWithClearContext() {
      if (pendingToolUseId == null) return;
      context.read<ChatSessionCubit>().approve(
        pendingToolUseId,
        clearContext: true,
      );
      planFeedbackController.clear();
    }

    void rejectToolUse() {
      if (pendingToolUseId == null) return;
      final feedback = isPlanApproval
          ? planFeedbackController.text.trim()
          : null;
      context.read<ChatSessionCubit>().reject(
        pendingToolUseId,
        message: feedback != null && feedback.isNotEmpty ? feedback : null,
      );
      planFeedbackController.clear();
    }

    void approveAlwaysToolUse() {
      if (pendingToolUseId == null) return;
      HapticFeedback.mediumImpact();
      context.read<ChatSessionCubit>().approveAlways(pendingToolUseId);
    }

    void answerQuestion(String toolUseId, String result) {
      context.read<ChatSessionCubit>().answer(toolUseId, result);
    }

    // --- Build ---
    return BlocListener<ConnectionCubit, BridgeConnectionState>(
      listener: (context, state) {
        if (state == BridgeConnectionState.connected) {
          _retryFailedMessages(context, sessionId);
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
            showPermissionModeMenu(context, cubit);
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
                        provider: Provider.claude.value,
                      ),
                    ),
                    flexibleSpace: StatusLineFlexibleSpace(
                      status: status,
                      inPlanMode: inPlanMode,
                    ),
                    actions: [
                      IconButton(
                        key: const ValueKey(
                          'appbar_refresh_conversation_button',
                        ),
                        icon: manualRefreshRunning.value
                            ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.refresh, size: 18),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                        tooltip: l.refresh,
                        onPressed: manualRefreshRunning.value
                            ? null
                            : () => unawaited(refreshConversation()),
                      ),
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
            child: Column(
              children: [
                UsageSummaryBar(
                  totalCost: sessionState.totalCost,
                  totalDuration: sessionState.totalDuration,
                  inputTokens: tokenUsage.inputTokens,
                  cachedInputTokens: tokenUsage.cachedInputTokens,
                  outputTokens: tokenUsage.outputTokens,
                  toolCalls: toolUsage.toolCalls,
                  fileEdits: toolUsage.fileEdits,
                ),
                if (bridgeState == BridgeConnectionState.reconnecting ||
                    bridgeState == BridgeConnectionState.disconnected)
                  ReconnectBanner(bridgeState: bridgeState),
                if (detachedPreview && deferredSubmissionPending)
                  DurableSessionBindingBanner(
                    queuedLocally:
                        bridgeState != BridgeConnectionState.connected,
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
                    overlay:
                        askToolUseId == null &&
                            askInput == null &&
                            pendingToolUseId == null
                        ? null
                        : NotificationListener<ScrollNotification>(
                            onNotification: (notification) {
                              if (notification is UserScrollNotification) {
                                FocusScope.of(context).unfocus();
                              }
                              return false;
                            },
                            child: SingleChildScrollView(
                              reverse: true,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (askToolUseId != null && askInput != null)
                                    AskUserQuestionWidget(
                                      toolUseId: askToolUseId,
                                      input: askInput,
                                      agentName: 'Claude',
                                      onAnswer: answerQuestion,
                                      scrollable: false,
                                    ),
                                  if (pendingToolUseId != null)
                                    ApprovalBar(
                                      key: ValueKey(
                                        'approval_$pendingToolUseId',
                                      ),
                                      appColors: appColors,
                                      pendingPermission: pendingPermission,
                                      isPlanApproval: isPlanApproval,
                                      planFeedbackController:
                                          planFeedbackController,
                                      onApprove: approveToolUse,
                                      onReject: rejectToolUse,
                                      onApproveAlways: approveAlwaysToolUse,
                                      onApproveClearContext: isPlanApproval
                                          ? approveWithClearContext
                                          : null,
                                      onViewPlan: isPlanApproval
                                          ? () {
                                              final originalText =
                                                  _extractPlanText(
                                                    sessionState.entries,
                                                  );
                                              if (originalText == null) return;
                                              showPlanDetailSheet(
                                                context,
                                                originalText,
                                              );
                                            }
                                          : null,
                                    ),
                                ],
                              ),
                            ),
                          ),
                    topOverlay: Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: SessionModeBar(
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
                      if (!scroll.isScrolledUp) return const SizedBox.shrink();
                      return Positioned(
                        right: 12,
                        bottom: overlayHeight + 12,
                        child: ScrollToBottomButton(
                          onPressed: () {
                            if (scroll.controller.hasClients) {
                              scroll.controller.animateTo(
                                0.0,
                                duration: const Duration(milliseconds: 200),
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
                      httpBaseUrl: context.read<BridgeService>().httpBaseUrl,
                      projectPath: chatFileRoot,
                      onRetryMessage: (entry) {
                        context.read<ChatSessionCubit>().retryMessage(entry);
                      },
                      onRewindMessage: (entry) {
                        _showRewindActionSheet(
                          context,
                          entry,
                          sessionId: sessionId,
                          inputController: chatInputController,
                          draftService: draftService,
                        );
                      },
                      collapseToolResults: collapseToolResults,
                      scrollToUserEntry: scrollToUserEntry,
                      bottomPadding: 8,
                      isCodex: false,
                      onFilePeekOpened: context
                          .read<ChatSessionCubit>()
                          .recordPeekedFile,
                    ),
                  ),
                ),
                if (approval is ApprovalNone)
                  ChatInputWithOverlays(
                    sessionId: sessionId,
                    status: status,
                    onScrollToBottom: scroll.scrollToBottom,
                    inputController: chatInputController,
                    inputBlocked: detachedPreview && deferredSubmissionPending,
                    onSubmit: detachedPreview ? submitWhileAttaching : null,
                    initialDiffSelection: diffSelectionFromNav.value,
                    onDiffSelectionConsumed: () {
                      // Don't null — keep for AppBar navigation.
                      // The value is cleared via onDiffSelectionCleared.
                    },
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

// ---------------------------------------------------------------------------
// Navigation helpers
// ---------------------------------------------------------------------------

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

void _openGalleryScreen(BuildContext context, {required String sessionId}) {
  final shell = WorkspaceShellScreen.maybeOf(context);
  if (shell?.canOpenToolPane ?? false) {
    shell!.openSessionGalleryPane(sessionId: sessionId);
    return;
  }
  context.router.push(GalleryRoute(sessionId: sessionId));
}

// ---------------------------------------------------------------------------
// Top-level helpers
// ---------------------------------------------------------------------------

void _executeSideEffects(
  Set<ChatSideEffect> effects, {
  required String sessionId,
  required BridgeDataSourceIdentity dataSourceIdentity,
  required bool isBackground,
  required ApprovalState approval,
  required AppLocalizations l,
  required ValueNotifier<int> collapseToolResults,
  required TextEditingController planFeedbackController,
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
                provider: Provider.claude.value,
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
                provider: Provider.claude.value,
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
              provider: Provider.claude.value,
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

/// Walk entries in reverse to find the latest [AssistantServerMessage] that
/// contains an `ExitPlanMode` tool use, then extract the plan text.
///
/// Tries TextContent first; if it's too short (real SDK writes the plan to a
/// file via Write tool), searches ALL entries for a Write tool targeting
/// `.claude/plans/`.
String? _extractPlanText(List<ChatEntry> entries) {
  for (var i = entries.length - 1; i >= 0; i--) {
    final entry = entries[i];
    if (entry is ServerChatEntry && entry.message is AssistantServerMessage) {
      final assistant = entry.message as AssistantServerMessage;
      final contents = assistant.message.content;
      final hasExitPlan = contents.any(
        (c) => c is ToolUseContent && c.name == 'ExitPlanMode',
      );
      if (hasExitPlan) {
        final textPlan = contents
            .whereType<TextContent>()
            .map((c) => c.text)
            .join('\n\n');
        if (textPlan.split('\n').length >= 10) return textPlan;
        // Fall back: search ALL entries for a Write tool targeting .claude/plans/
        final writtenPlan = findPlanFromWriteTool(entries);
        return writtenPlan ?? textPlan;
      }
    }
  }
  return null;
}

/// Search all entries for a Write tool that targets `.claude/plans/` and
/// return its `content` input.  The Write tool is often in a different
/// [AssistantServerMessage] than the ExitPlanMode tool use.
String? findPlanFromWriteTool(List<ChatEntry> entries) {
  for (var i = entries.length - 1; i >= 0; i--) {
    final entry = entries[i];
    if (entry is! ServerChatEntry) continue;
    final msg = entry.message;
    if (msg is! AssistantServerMessage) continue;
    for (final c in msg.message.content) {
      if (c is! ToolUseContent || c.name != 'Write') continue;
      final filePath = c.input['file_path']?.toString() ?? '';
      if (!filePath.contains('.claude/plans/')) continue;
      final content = c.input['content']?.toString();
      if (content != null && content.isNotEmpty) return content;
    }
  }
  return null;
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
      // Claude history does not use the optional Codex phone mirror.
      isUserMessageIndexComplete: () => true,
      onScrollToMessage: (msg) async {
        final loaded = await cubit.revealUserMessage(msg);
        if (loaded == null) return false;
        scrollToUserEntry.value = loaded;
        return true;
      },
      onRewindMessage: (msg) => _showRewindActionSheet(
        context,
        msg,
        sessionId: sessionId,
        inputController: inputController,
        draftService: draftService,
      ),
    ),
  );
}

void _showRewindActionSheet(
  BuildContext context,
  UserChatEntry message, {
  required String sessionId,
  required TextEditingController inputController,
  required DraftService draftService,
}) {
  final cubit = context.read<ChatSessionCubit>();

  // Request dry-run preview
  if (message.messageUuid != null) {
    cubit.rewindDryRun(message.messageUuid!);
  }

  showModalBottomSheet<void>(
    context: context,
    builder: (_) {
      return StreamBuilder<ChatSessionState>(
        stream: cubit.stream,
        initialData: cubit.state,
        builder: (ctx, snapshot) {
          final preview = snapshot.data?.rewindPreview;

          return RewindActionSheet(
            userMessage: message,
            preview: preview,
            isLoadingPreview: preview == null,
            onRewind: (mode) {
              Navigator.of(ctx).pop();
              if (message.messageUuid != null) {
                if (mode != RewindMode.code) {
                  _restoreRewindMessageToComposer(
                    inputController: inputController,
                    draftService: draftService,
                    sessionId: sessionId,
                    text: message.text,
                  );
                }
                cubit.rewind(message.messageUuid!, mode.value);
              }
            },
          );
        },
      );
    },
  );
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

void _retryFailedMessages(BuildContext context, String sessionId) {
  final cubit = context.read<ChatSessionCubit>();
  for (final entry in cubit.state.entries) {
    if (entry is UserChatEntry && entry.status.canRetry) {
      cubit.retryMessage(entry);
    }
  }
}

({int inputTokens, int cachedInputTokens, int outputTokens}) _collectTokenUsage(
  List<ChatEntry> entries,
) {
  var inputTokens = 0;
  var cachedInputTokens = 0;
  var outputTokens = 0;

  for (final entry in entries) {
    if (entry is! ServerChatEntry) continue;
    final msg = entry.message;
    if (msg is! ResultMessage) continue;
    inputTokens += msg.inputTokens ?? 0;
    cachedInputTokens += msg.cachedInputTokens ?? 0;
    outputTokens += msg.outputTokens ?? 0;
  }

  return (
    inputTokens: inputTokens,
    cachedInputTokens: cachedInputTokens,
    outputTokens: outputTokens,
  );
}

({int toolCalls, int fileEdits}) _collectToolUsage(List<ChatEntry> entries) {
  var toolCalls = 0;
  var fileEdits = 0;

  for (final entry in entries) {
    if (entry is! ServerChatEntry) continue;
    final msg = entry.message;
    if (msg is! ResultMessage) continue;
    toolCalls += msg.toolCalls ?? 0;
    fileEdits += msg.fileEdits ?? 0;
  }

  return (toolCalls: toolCalls, fileEdits: fileEdits);
}
