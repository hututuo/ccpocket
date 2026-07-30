import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:provider/provider.dart' hide Provider;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:skeletonizer/skeletonizer.dart';

import '../../../constants/app_constants.dart';
import '../../../l10n/app_localizations.dart';
import '../../../models/messages.dart';
import '../../../models/offline_pending_action.dart';
import '../../../services/app_update_service.dart';
import '../../../services/draft_service.dart';
import '../../../services/notification_service.dart';
import '../../../services/revenuecat_service.dart';
import '../../../services/support_banner_service.dart';
import '../../../theme/app_theme.dart';
import '../../../theme/provider_style.dart';
import '../../../router/app_router.dart';
import '../../../widgets/pin_toggle_button.dart';
import '../../../widgets/session_card.dart';
import '../../../widgets/workspace_pane_chrome.dart';
import '../../conversation_mirror/conversation_mirror_service.dart';
import '../../conversation_mirror/conversation_mirror_target.dart';
import '../../file_transfer/file_transfer_service.dart';
import '../../file_transfer/received_file_inbox_banner.dart';
import '../session_list_projection.dart';
import '../state/session_list_cubit.dart';
import '../state/session_list_state.dart';
import '../workspace_shell_screen.dart';
import 'section_header.dart';
import 'session_filter_bar.dart';
import 'session_list_empty_state.dart';
import 'app_update_banner.dart';
import 'bridge_update_banner.dart';
import 'macos_native_app_banner.dart';
import 'session_reconnect_banner.dart';
import 'support_banner.dart';

class _ProjectSessionGroup {
  final String projectPath;
  final String projectName;
  final List<UnifiedSessionListItem> sessions;

  const _ProjectSessionGroup({
    required this.projectPath,
    required this.projectName,
    required this.sessions,
  });
}

List<_ProjectSessionGroup> _groupSessionsByProject({
  required Iterable<String> projectPaths,
  required List<UnifiedSessionListItem> sessions,
}) {
  final grouped = <String, List<UnifiedSessionListItem>>{
    for (final path in projectPaths)
      if (path.isNotEmpty) path: <UnifiedSessionListItem>[],
  };
  for (final session in sessions) {
    grouped.putIfAbsent(session.projectPath, () => <UnifiedSessionListItem>[]);
    grouped[session.projectPath]!.add(session);
  }
  return [
    for (final entry in grouped.entries)
      _ProjectSessionGroup(
        projectPath: entry.key,
        projectName: pathBasename(entry.key),
        sessions: entry.value,
      ),
  ];
}

String _recentSessionCardText(
  RecentSession session,
  SessionDisplayMode displayMode,
) {
  return switch (displayMode) {
    SessionDisplayMode.first =>
      session.firstPrompt.isNotEmpty
          ? session.firstPrompt
          : session.displayText,
    SessionDisplayMode.last =>
      (session.lastPrompt ?? session.firstPrompt).isNotEmpty
          ? (session.lastPrompt ?? session.firstPrompt)
          : session.displayText,
    SessionDisplayMode.summary =>
      (session.summary ?? session.firstPrompt).isNotEmpty
          ? (session.summary ?? session.firstPrompt)
          : session.displayText,
  };
}

SessionInfo _sessionInfoForUnifiedCard(
  UnifiedSessionListItem item,
  SessionDisplayMode displayMode,
) {
  final runtime = item.running;
  final catalog = item.recent;
  if (catalog == null) return runtime!;

  String preferRuntime(String? runtimeValue, String catalogValue) {
    final value = runtimeValue?.trim();
    return value == null || value.isEmpty ? catalogValue : runtimeValue!;
  }

  String? preferOptional(String? runtimeValue, String? catalogValue) {
    final value = runtimeValue?.trim();
    return value == null || value.isEmpty ? catalogValue : runtimeValue;
  }

  return SessionInfo(
    id: runtime?.id ?? catalog.sessionId,
    provider: preferOptional(runtime?.provider, catalog.provider),
    projectPath: preferRuntime(runtime?.projectPath, catalog.projectPath),
    claudeSessionId: preferOptional(
      runtime?.claudeSessionId,
      catalog.sessionId,
    ),
    forkedFromSessionId: runtime?.forkedFromSessionId,
    forkedFromThreadId:
        runtime?.forkedFromThreadId ?? catalog.forkedFromThreadId,
    name: preferOptional(runtime?.name, catalog.name),
    agentNickname: preferOptional(
      runtime?.agentNickname,
      catalog.agentNickname,
    ),
    agentRole: preferOptional(runtime?.agentRole, catalog.agentRole),
    status: runtime?.status ?? 'idle',
    createdAt: preferRuntime(runtime?.createdAt, catalog.created),
    // The durable catalog timestamp is the stable list/card timestamp. Runtime
    // attachment is transient and must not make a row jump or show a different
    // clock merely because an app-server watcher attached.
    lastActivityAt: catalog.modified.isNotEmpty
        ? catalog.modified
        : (runtime?.lastActivityAt ?? catalog.created),
    gitBranch: preferRuntime(runtime?.gitBranch, catalog.gitBranch),
    lastMessage: preferRuntime(
      runtime?.lastMessage,
      _recentSessionCardText(catalog, displayMode),
    ),
    worktreePath: runtime?.worktreePath,
    worktreeBranch: runtime?.worktreeBranch,
    permissionMode: runtime?.permissionMode ?? catalog.rawPermissionMode,
    executionMode: runtime?.executionMode ?? catalog.executionMode,
    planMode: runtime?.planMode ?? catalog.planMode,
    model: runtime?.model,
    codexApprovalPolicy:
        runtime?.codexApprovalPolicy ?? catalog.codexApprovalPolicy,
    codexApprovalsReviewer:
        runtime?.codexApprovalsReviewer ?? catalog.codexApprovalsReviewer,
    codexPermissionsMode:
        runtime?.codexPermissionsMode ?? catalog.codexPermissionsMode,
    codexSandboxMode: runtime?.codexSandboxMode ?? catalog.codexSandboxMode,
    codexModel: runtime?.codexModel ?? catalog.codexModel,
    codexProfile: runtime?.codexProfile ?? catalog.codexProfile,
    codexModelReasoningEffort:
        runtime?.codexModelReasoningEffort ?? catalog.codexModelReasoningEffort,
    codexServiceTier: runtime?.codexServiceTier ?? catalog.codexServiceTier,
    codexNetworkAccessEnabled:
        runtime?.codexNetworkAccessEnabled ?? catalog.codexNetworkAccessEnabled,
    codexWebSearchMode:
        runtime?.codexWebSearchMode ?? catalog.codexWebSearchMode,
    codexAdditionalWritableRoots:
        runtime?.codexAdditionalWritableRoots ??
        catalog.codexAdditionalWritableRoots,
    codexPermissionApplyStrategySupported:
        runtime?.codexPermissionApplyStrategySupported ?? false,
    externalDesktopTurnActive: runtime?.externalDesktopTurnActive ?? false,
    codexNativePlanModeSupported: runtime?.codexNativePlanModeSupported,
    codexGoalControlSupported: runtime?.codexGoalControlSupported,
    pendingPermission: runtime?.pendingPermission,
    queuedInput: runtime?.queuedInput,
  );
}

class HomeContent extends StatefulWidget {
  final BridgeConnectionState connectionState;
  final String? bridgeVersion;
  final String? latestBridgeVersion;
  final List<SessionInfo> sessions;
  final List<OfflinePendingAction> offlinePendingActions;
  final List<RecentSession> recentSessions;
  final Set<String> accumulatedProjectPaths;
  final Set<String> collapsedProjectPaths;
  final Set<String> loadingProjectPaths;
  final Set<String> exhaustedProjectPaths;
  final Map<String, int> projectSessionDisplayLimits;
  final Set<String> pinnedSessionKeys;
  final Set<String> pinnedProjectPaths;
  final String searchQuery;
  final bool isLoadingMore;
  final bool isInitialLoading;
  final bool hasMoreSessions;
  final Set<String> archivingSessionIds;
  final Set<String> unseenSessionIds;
  final Map<String, ConversationSyncV2Status> conversationStatuses;
  final Set<String> unreadConversationKeys;
  final String? currentProjectFilter;
  final VoidCallback onNewSession;
  final void Function(
    String sessionId, {
    String? projectPath,
    String? gitBranch,
    String? worktreePath,
    String? provider,
    String? durableProviderSessionId,
    String? permissionMode,
    String? sandboxMode,
    String? approvalPolicy,
    String? approvalsReviewer,
  })
  onTapRunning;
  final ValueChanged<String> onStopSession;
  final ValueChanged<String>? onCancelOfflinePendingAction;
  final void Function(String sessionId, String toolUseId, {bool clearContext})?
  onApprovePermission;
  final void Function(String sessionId, String toolUseId)? onApproveAlways;
  final void Function(String sessionId, String toolUseId, {String? message})?
  onRejectPermission;
  final void Function(String sessionId, String toolUseId, String result)?
  onAnswerQuestion;
  final ValueChanged<RecentSession> onResumeSession;
  final ValueChanged<RecentSession>? onToggleRecentSessionPinned;
  final void Function(RecentSession session, Offset? position)
  onLongPressRecentSession;
  final ValueChanged<RecentSession> onArchiveSession;
  final void Function(SessionInfo session, Offset? position)
  onLongPressRunningSession;
  final ValueChanged<SessionInfo>? onToggleRunningSessionPinned;
  final ValueChanged<String?> onSelectProject;
  final VoidCallback onLoadMore;
  final ValueChanged<String>? onLoadMoreProject;
  final ValueChanged<String>? onToggleProjectCollapsed;
  final ValueChanged<String>? onToggleProjectPinned;
  final ProviderFilter providerFilter;
  final bool namedOnly;
  final VoidCallback onToggleProvider;
  final VoidCallback onToggleNamed;
  final AppUpdateInfo? appUpdateInfo;
  final VoidCallback? onDismissAppUpdate;
  final bool showMacOSNativeAppBanner;
  final VoidCallback? onDismissMacOSNativeAppBanner;
  final VoidCallback? onOpenMacOSNativeAppReleases;
  final VoidCallback? onOpenBridgeSettings;
  final VoidCallback? onOpenSupportSettings;
  final bool? showInlineStopButtonOverride;
  final String? connectedBridgeLabel;

  const HomeContent({
    super.key,
    required this.connectionState,
    this.bridgeVersion,
    this.latestBridgeVersion,
    required this.sessions,
    this.offlinePendingActions = const [],
    required this.recentSessions,
    required this.accumulatedProjectPaths,
    this.collapsedProjectPaths = const {},
    this.loadingProjectPaths = const {},
    this.exhaustedProjectPaths = const {},
    this.projectSessionDisplayLimits = const {},
    this.pinnedSessionKeys = const {},
    this.pinnedProjectPaths = const {},
    required this.searchQuery,
    required this.isLoadingMore,
    required this.isInitialLoading,
    required this.hasMoreSessions,
    this.archivingSessionIds = const {},
    this.unseenSessionIds = const {},
    this.conversationStatuses = const {},
    this.unreadConversationKeys = const {},
    required this.currentProjectFilter,
    required this.onNewSession,
    required this.onTapRunning,
    required this.onStopSession,
    this.onCancelOfflinePendingAction,
    this.onApprovePermission,
    this.onApproveAlways,
    this.onRejectPermission,
    this.onAnswerQuestion,
    required this.onResumeSession,
    this.onToggleRecentSessionPinned,
    required this.onLongPressRecentSession,
    required this.onArchiveSession,
    required this.onLongPressRunningSession,
    this.onToggleRunningSessionPinned,
    required this.onSelectProject,
    required this.onLoadMore,
    this.onLoadMoreProject,
    this.onToggleProjectCollapsed,
    this.onToggleProjectPinned,
    required this.providerFilter,
    required this.namedOnly,
    required this.onToggleProvider,
    required this.onToggleNamed,
    this.appUpdateInfo,
    this.onDismissAppUpdate,
    this.showMacOSNativeAppBanner = false,
    this.onDismissMacOSNativeAppBanner,
    this.onOpenMacOSNativeAppReleases,
    this.onOpenBridgeSettings,
    this.onOpenSupportSettings,
    this.showInlineStopButtonOverride,
    this.connectedBridgeLabel,
  });

  @override
  State<HomeContent> createState() => HomeContentState();
}

class HomeContentState extends State<HomeContent> {
  static const _displayModePreferenceKey = 'session_list_display_mode';
  // Keep the established key so existing users retain their chosen layout.
  static const _groupRecentSessionsPreferenceKey =
      'session_list_group_recent_sessions';

  bool _isSearching = false;
  bool _updateBannerDismissed = false;
  bool _showSupportBanner = false;
  bool _groupByProject = true;
  final _searchController = TextEditingController();
  SessionDisplayMode _displayMode = SessionDisplayMode.first;
  RevenueCatService? _revenueCatService;
  VoidCallback? _catalogStateListener;
  SupportBannerService? _supportBannerService;
  VoidCallback? _supportBannerListener;

  @override
  void initState() {
    super.initState();
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final modeStr = prefs.getString(_displayModePreferenceKey);
    final groupByProject =
        prefs.getBool(_groupRecentSessionsPreferenceKey) ?? true;
    if (!mounted) return;
    setState(() {
      if (modeStr != null) {
        _displayMode = SessionDisplayMode.values.firstWhere(
          (m) => m.name == modeStr,
          orElse: () => SessionDisplayMode.first,
        );
      }
      _groupByProject = groupByProject;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final revenueCatService = context.read<RevenueCatService>();
    if (!identical(_revenueCatService, revenueCatService)) {
      if (_revenueCatService != null && _catalogStateListener != null) {
        _revenueCatService!.catalogState.removeListener(_catalogStateListener!);
      }
      _revenueCatService = revenueCatService;
      _catalogStateListener = () => _refreshSupportBannerVisibility();
      revenueCatService.catalogState.addListener(_catalogStateListener!);
      _refreshSupportBannerVisibility();
    }

    final supportBannerService = context.read<SupportBannerService>();
    if (!identical(_supportBannerService, supportBannerService)) {
      if (_supportBannerService != null && _supportBannerListener != null) {
        _supportBannerService!.removeListener(_supportBannerListener!);
      }
      _supportBannerService = supportBannerService;
      _supportBannerListener = () => _refreshSupportBannerVisibility();
      supportBannerService.addListener(_supportBannerListener!);
      _refreshSupportBannerVisibility();
    }
  }

  void _toggleDisplayMode() async {
    final next = switch (_displayMode) {
      SessionDisplayMode.first => SessionDisplayMode.last,
      SessionDisplayMode.last => SessionDisplayMode.summary,
      SessionDisplayMode.summary => SessionDisplayMode.first,
    };
    setState(() => _displayMode = next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_displayModePreferenceKey, next.name);
  }

  void _toggleSessionListMode() async {
    final next = !_groupByProject;
    setState(() => _groupByProject = next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_groupRecentSessionsPreferenceKey, next);
  }

  @override
  void didUpdateWidget(covariant HomeContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 外部から searchQuery がクリアされたら検索UIも閉じる
    if (widget.searchQuery.isEmpty && oldWidget.searchQuery.isNotEmpty) {
      setState(() => _isSearching = false);
      _searchController.clear();
    }
    // Reset dismiss state when reconnected (new bridgeVersion received)
    if (widget.bridgeVersion != oldWidget.bridgeVersion) {
      _updateBannerDismissed = false;
      _refreshSupportBannerVisibility();
    }
  }

  @override
  void dispose() {
    if (_revenueCatService != null && _catalogStateListener != null) {
      _revenueCatService!.catalogState.removeListener(_catalogStateListener!);
    }
    if (_supportBannerService != null && _supportBannerListener != null) {
      _supportBannerService!.removeListener(_supportBannerListener!);
    }
    _searchController.dispose();
    super.dispose();
  }

  void _toggleSearch() {
    setState(() {
      _isSearching = !_isSearching;
      if (!_isSearching) {
        _searchController.clear();
        context.read<SessionListCubit>().setSearchQuery('');
      }
    });
  }

  /// Open search field programmatically (e.g. from keyboard shortcut).
  void openSearch() {
    if (!_isSearching) {
      _toggleSearch();
    }
  }

  Widget? _buildAppUpdateBanner() {
    if (widget.appUpdateInfo == null) return null;
    return AppUpdateBanner(
      updateInfo: widget.appUpdateInfo!,
      onDismiss: widget.onDismissAppUpdate,
    );
  }

  Widget? _buildMacOSNativeAppBanner() {
    if (!widget.showMacOSNativeAppBanner) return null;
    return MacOSNativeAppBanner(
      onDismiss: widget.onDismissMacOSNativeAppBanner,
      onOpen: widget.onOpenMacOSNativeAppReleases,
    );
  }

  Widget? _buildUpdateBanner() {
    if (_updateBannerDismissed) return null;
    if (!BridgeUpdateBanner.shouldShow(
      widget.bridgeVersion,
      AppConstants.expectedBridgeVersion,
      latestBridgeVersion: widget.latestBridgeVersion,
    )) {
      return null;
    }
    return BridgeUpdateBanner(
      currentVersion: widget.bridgeVersion!,
      expectedVersion: AppConstants.expectedBridgeVersion,
      latestBridgeVersion: widget.latestBridgeVersion,
      onTap:
          widget.onOpenBridgeSettings ??
          () => context.pushRoute(SettingsRoute(focusConnection: true)),
      onDismiss: () => setState(() => _updateBannerDismissed = true),
    );
  }

  bool _hasVisibleBridgeUpdateBanner() {
    return !_updateBannerDismissed &&
        BridgeUpdateBanner.shouldShow(
          widget.bridgeVersion,
          AppConstants.expectedBridgeVersion,
          latestBridgeVersion: widget.latestBridgeVersion,
        );
  }

  Future<void> _refreshSupportBannerVisibility() async {
    final revenueCatService = _revenueCatService;
    if (revenueCatService == null) return;

    final supportBannerService = context.read<SupportBannerService>();
    final shouldShow = await supportBannerService.shouldShow(
      hasBridgeUpdate: _hasVisibleBridgeUpdateBanner(),
      catalog: revenueCatService.catalogState.value,
    );
    if (!mounted || shouldShow == _showSupportBanner) return;
    setState(() {
      _showSupportBanner = shouldShow;
    });
  }

  Widget? _buildSupportBanner() {
    if (!_showSupportBanner) return null;
    return SupportBanner(
      onTap:
          widget.onOpenSupportSettings ??
          () => context.pushRoute(SettingsRoute(focusSupport: true)),
      onDismiss: () async {
        await context.read<SupportBannerService>().dismiss();
        if (!mounted) return;
        setState(() {
          _showSupportBanner = false;
        });
      },
    );
  }

  Widget? _buildConnectedBridgeBanner(BuildContext context) {
    final label = widget.connectedBridgeLabel;
    if (label == null || label.isEmpty) return null;
    if (WorkspaceShellScreen.maybeOf(context) == null) return null;
    final chrome = resolveWorkspacePaneChrome(
      platform: Theme.of(context).platform,
      isAdaptiveWorkspace: true,
      isLeftPaneVisible: true,
      slot: WorkspacePaneSlot.left,
    );
    if (!chrome.useMacOSAdaptiveChrome) return null;

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: colorScheme.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Icon(
                Icons.dns_outlined,
                size: 14,
                color: colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final shell = WorkspaceShellScreen.maybeOf(context);
    final fileTransferService = context.read<FileTransferService?>();
    return ListenableBuilder(
      listenable: Listenable.merge([
        NotificationService.instance,
        ?fileTransferService,
        if (shell != null) shell.presentationListenable,
      ]),
      builder: (context, _) => _buildContent(context),
    );
  }

  void _openRunningSession(SessionInfo session) {
    widget.onTapRunning(
      session.id,
      projectPath: session.projectPath,
      gitBranch: session.worktreePath != null
          ? session.worktreeBranch
          : session.gitBranch,
      worktreePath: session.worktreePath,
      provider: session.provider,
      durableProviderSessionId: session.claudeSessionId,
      permissionMode: session.permissionMode,
      sandboxMode: session.codexSandboxMode,
      approvalPolicy: session.codexApprovalPolicy,
      approvalsReviewer: session.codexApprovalsReviewer,
    );
  }

  Widget _buildContent(BuildContext context) {
    final l = AppLocalizations.of(context);
    final appColors = Theme.of(context).extension<AppColors>()!;
    final hasPendingActions = widget.offlinePendingActions.isNotEmpty;
    final mirrorService = context.watch<ConversationMirrorService?>();
    final mirrorBridgeId = mirrorService?.currentBridgeInstanceId;
    final hasKnownProjects = widget.accumulatedProjectPaths.isNotEmpty;
    final isReconnecting =
        widget.connectionState == BridgeConnectionState.reconnecting;
    final updateBanner = _buildUpdateBanner();
    final supportBannerService = context.read<SupportBannerService>();
    final supportBanner =
        updateBanner == null || supportBannerService.shouldForceShowInDebug
        ? _buildSupportBanner()
        : null;
    final appUpdateBanner = _buildAppUpdateBanner();
    final macOSNativeAppBanner = _buildMacOSNativeAppBanner();
    final shell = WorkspaceShellScreen.maybeOf(context);
    final selectedSession = shell?.selectedSession;
    final selectedSessionId = selectedSession?.sessionId;
    final selectedSessionProvider = selectedSession?.provider?.value;
    final showInlineStopButton =
        widget.showInlineStopButtonOverride ?? shell != null;
    final connectedBridgeBanner = _buildConnectedBridgeBanner(context);
    final fileTransferService = context.read<FileTransferService?>();
    final receivedFileBanner =
        fileTransferService != null &&
            fileTransferService.unreadReceivedCount > 0
        ? ReceivedFileInboxBanner(service: fileTransferService)
        : null;

    // Keep a single conversation identity across live runtimes, the provider
    // catalog, and phone-resident mirror fallbacks. The richer provider entry
    // is appended last so it wins when a local fallback has the same identity.
    final catalogSessions =
        <RecentSession>[
          if (mirrorService != null)
            for (final metadata in mirrorService.residentMetadata)
              if (mirrorBridgeId == null ||
                  metadata.key.bridgeInstanceId == mirrorBridgeId)
                ConversationMirrorTarget.fromMetadata(
                  metadata,
                ).toRecentSession(),
          ...widget.recentSessions,
        ].where(
          (session) => recentSessionMatchesListFilters(
            session,
            providerFilter: widget.providerFilter,
            projectPath: widget.currentProjectFilter,
            namedOnly: widget.namedOnly,
            searchQuery: widget.searchQuery,
          ),
        );
    final runningSessions = widget.sessions.where(
      (session) => runningSessionMatchesListFilters(
        session,
        providerFilter: widget.providerFilter,
        projectPath: widget.currentProjectFilter,
        namedOnly: widget.namedOnly,
        searchQuery: widget.searchQuery,
      ),
    );
    final pendingResumeSessionIds = widget.offlinePendingActions
        .where((action) => action.kind == OfflinePendingActionKind.resume)
        .map((action) => action.sessionId)
        .whereType<String>()
        .toSet();
    final unifiedSessions = buildUnifiedSessionList(
      runningSessions: runningSessions,
      recentSessions: catalogSessions,
      pendingResumeSessionIds: pendingResumeSessionIds,
      pinnedSessionKeys: widget.pinnedSessionKeys,
      unseenSessionIds: widget.unseenSessionIds,
      conversationStatuses: widget.conversationStatuses,
      unreadConversationKeys: widget.unreadConversationKeys,
    );
    final alwaysVisibleSessionKeys = {
      for (final item in unifiedSessions)
        if (sessionListItemBypassesDisplayLimit(
          item,
          unseenSessionIds: widget.unseenSessionIds,
        ))
          item.identityKey,
    };
    final hasConversationSessions = unifiedSessions.isNotEmpty;
    final allProjectPaths = orderProjectPathsForGroupedView(
      knownProjectPaths: <String>[
        if (widget.currentProjectFilter != null) widget.currentProjectFilter!,
        if (widget.currentProjectFilter == null)
          ...widget.accumulatedProjectPaths,
      ],
      sessions: unifiedSessions,
      pinnedSessionKeys: widget.pinnedSessionKeys,
      pinnedProjectPaths: widget.pinnedProjectPaths,
    );
    final groupedSessions = _groupSessionsByProject(
      projectPaths: allProjectPaths,
      sessions: unifiedSessions,
    );

    final hasActiveFilter =
        widget.currentProjectFilter != null ||
        widget.providerFilter != ProviderFilter.all ||
        widget.namedOnly ||
        widget.searchQuery.isNotEmpty;

    Widget buildUnifiedSessionRow(UnifiedSessionListItem item) {
      final running = item.running;
      final recent = item.recent;
      final cardSession = _sessionInfoForUnifiedCard(item, _displayMode);
      final isProcessing =
          recent != null &&
          widget.archivingSessionIds.contains(
            providerSessionIdentityKey(
              recent.provider ?? Provider.claude.value,
              recent.sessionId,
            ),
          );
      final stableKey = ValueKey('conversation_${item.identityKey}');
      final slidableKey = ValueKey('conversation_slidable_${item.identityKey}');
      final row = Slidable(
        key: slidableKey,
        endActionPane: ActionPane(
          motion: const BehindMotion(),
          extentRatio: 0.18,
          children: [
            CustomSlidableAction(
              onPressed: (_) {
                if (running != null) {
                  widget.onStopSession(running.id);
                } else if (recent != null) {
                  widget.onArchiveSession(recent);
                }
              },
              backgroundColor: Colors.transparent,
              padding: EdgeInsets.zero,
              child: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.error,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  running != null
                      ? Icons.stop_circle_outlined
                      : Icons.archive_outlined,
                  color: Colors.white,
                  size: 22,
                ),
              ),
            ),
          ],
        ),
        child: KeyedSubtree(
          key: ValueKey('conversation_card_${item.identityKey}'),
          child: RunningSessionCard(
            session: cardSession,
            catalogSession: recent,
            stableIdentity: item.identityKey,
            conversationStatus: item.syncStatus,
            displayMode: _displayMode,
            draftText: recent == null
                ? null
                : context.read<DraftService>().getDraft(recent.sessionId),
            isProcessing: isProcessing,
            isPinned:
                item.pinKey != null &&
                widget.pinnedSessionKeys.contains(item.pinKey),
            onTogglePinned: item.pinKey == null
                ? null
                : running != null && widget.onToggleRunningSessionPinned != null
                ? () => widget.onToggleRunningSessionPinned!(running)
                : recent != null && widget.onToggleRecentSessionPinned != null
                ? () => widget.onToggleRecentSessionPinned!(recent)
                : null,
            isUnseen:
                item.syncUnread ||
                (running != null &&
                    widget.unseenSessionIds.contains(running.id)),
            isSelected:
                running != null &&
                selectedSessionId == running.id &&
                selectedSessionProvider == running.provider,
            onLongPress: running != null
                ? () => widget.onLongPressRunningSession(running, null)
                : recent != null
                ? () => widget.onLongPressRecentSession(recent, null)
                : null,
            onShowActions: running != null
                ? (position) =>
                      widget.onLongPressRunningSession(running, position)
                : recent != null
                ? (position) =>
                      widget.onLongPressRecentSession(recent, position)
                : null,
            onStop: running != null && showInlineStopButton
                ? () => widget.onStopSession(running.id)
                : null,
            onTap: running != null
                ? () => _openRunningSession(running)
                : () => widget.onResumeSession(recent!),
            onApprove: running == null
                ? null
                : (toolUseId, {bool clearContext = false}) => widget
                      .onApprovePermission
                      ?.call(running.id, toolUseId, clearContext: clearContext),
            onApproveAlways: running == null
                ? null
                : (toolUseId) =>
                      widget.onApproveAlways?.call(running.id, toolUseId),
            onReject: running == null
                ? null
                : (toolUseId, {String? message}) => widget.onRejectPermission
                      ?.call(running.id, toolUseId, message: message),
            onAnswer: running == null
                ? null
                : (toolUseId, result) => widget.onAnswerQuestion?.call(
                    running.id,
                    toolUseId,
                    result,
                  ),
          ),
        ),
      );
      return KeyedSubtree(key: stableKey, child: row);
    }

    if (!hasPendingActions &&
        !hasConversationSessions &&
        !hasKnownProjects &&
        !hasActiveFilter) {
      // Show skeleton while initial data is loading
      if (widget.isInitialLoading) {
        return ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(12),
          children: [
            if (isReconnecting) const SessionReconnectBanner(),
            ?receivedFileBanner,
            ?connectedBridgeBanner,
            ?updateBanner,
            ?supportBanner,
            ?appUpdateBanner,
            ?macOSNativeAppBanner,
            SectionHeader(
              icon: Icons.history,
              label: l.recentSessions,
              color: appColors.subtleText,
            ),
            const SizedBox(height: 8),
            const _SessionListSkeleton(),
          ],
        );
      }

      return ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          if (isReconnecting) const SessionReconnectBanner(),
          ?receivedFileBanner,
          ?connectedBridgeBanner,
          ?updateBanner,
          ?supportBanner,
          ?macOSNativeAppBanner,
          const SizedBox(height: 80),
          SessionListEmptyState(onNewSession: widget.onNewSession),
        ],
      );
    }

    return ListView(
      key: const ValueKey('session_list'),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(12),
      children: [
        if (isReconnecting) const SessionReconnectBanner(),
        ?receivedFileBanner,
        ?connectedBridgeBanner,
        ?updateBanner,
        ?supportBanner,
        ?macOSNativeAppBanner,
        if (widget.isInitialLoading ||
            hasPendingActions ||
            hasConversationSessions ||
            hasKnownProjects ||
            hasActiveFilter) ...[
          SectionHeader(
            icon: Icons.history,
            label: l.recentSessions,
            color: appColors.subtleText,
            trailing: IconButton(
              key: const ValueKey('search_button'),
              icon: Icon(
                _isSearching ? Icons.close : Icons.search,
                size: 18,
                color: appColors.subtleText,
              ),
              onPressed: _toggleSearch,
              tooltip: l.search,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              visualDensity: VisualDensity.compact,
            ),
          ),
          if (_isSearching) ...[
            const SizedBox(height: 4),
            TextField(
              key: const ValueKey('search_field'),
              controller: _searchController,
              autofocus: true,
              onTapOutside: (_) => FocusScope.of(context).unfocus(),
              decoration: InputDecoration(
                hintText: l.searchSessions,
                prefixIcon: Icon(
                  Icons.search,
                  size: 18,
                  color: appColors.subtleText,
                ),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(
                    color: appColors.subtleText.withValues(alpha: 0.3),
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(
                    color: appColors.subtleText.withValues(alpha: 0.3),
                  ),
                ),
              ),
              style: const TextStyle(fontSize: 14),
              onChanged: (v) =>
                  context.read<SessionListCubit>().setSearchQuery(v),
            ),
          ],
          const SizedBox(height: 8),
          SessionFilterBar(
            displayMode: _displayMode,
            onToggleDisplayMode: _toggleDisplayMode,
            groupByProject: _groupByProject,
            onToggleSessionListMode: _toggleSessionListMode,
            providerFilter: widget.providerFilter,
            onToggleProviderFilter: widget.onToggleProvider,
            projects:
                prioritizePinned(
                  widget.accumulatedProjectPaths,
                  isPinned: widget.pinnedProjectPaths.contains,
                ).map((path) {
                  return (path: path, name: pathBasename(path));
                }).toList(),
            currentProjectFilter: widget.currentProjectFilter,
            onProjectFilterChanged: widget.onSelectProject,
            namedOnly: widget.namedOnly,
            onToggleNamed: widget.onToggleNamed,
          ),
          const SizedBox(height: 8),
          for (final action in widget.offlinePendingActions)
            OfflinePendingSessionCard(
              key: ValueKey('pending_session_${action.id}'),
              action: action,
              onCancel:
                  widget.onCancelOfflinePendingAction == null ||
                      !action.canCancel
                  ? null
                  : () => widget.onCancelOfflinePendingAction!(action.id),
            ),
          if (widget.isInitialLoading) ...[
            for (final item in unifiedSessions.where(
              (item) => item.running != null,
            ))
              buildUnifiedSessionRow(item),
            const _SessionListSkeleton(),
          ] else ...[
            if ((!_groupByProject && unifiedSessions.isEmpty) ||
                (_groupByProject && groupedSessions.isEmpty))
              _RecentSessionsEmptyResult(
                title: hasActiveFilter
                    ? l.noSessionsMatchFilters
                    : l.noRecentSessions,
                subtitle: hasActiveFilter ? l.adjustFiltersAndSearch : null,
              )
            else if (!_groupByProject) ...[
              for (final item in unifiedSessions) buildUnifiedSessionRow(item),
              if (widget.hasMoreSessions) ...[
                const SizedBox(height: 8),
                _LoadMoreRecentSessionsButton(
                  isLoadingMore: widget.isLoadingMore,
                  onLoadMore: widget.onLoadMore,
                ),
                const SizedBox(height: 8),
              ],
            ] else
              for (final group in groupedSessions)
                _ProjectRecentSessionGroup(
                  group: group,
                  isCollapsed: widget.collapsedProjectPaths.contains(
                    group.projectPath,
                  ),
                  isLoadingMore: widget.loadingProjectPaths.contains(
                    group.projectPath,
                  ),
                  displayLimit:
                      widget.projectSessionDisplayLimits[group.projectPath] ??
                      5,
                  alwaysVisibleSessionKeys: alwaysVisibleSessionKeys,
                  canLoadFromBridge:
                      widget.currentProjectFilter == null &&
                      !widget.exhaustedProjectPaths.contains(group.projectPath),
                  isPinned: widget.pinnedProjectPaths.contains(
                    group.projectPath,
                  ),
                  onToggleCollapsed: () =>
                      widget.onToggleProjectCollapsed?.call(group.projectPath),
                  onTogglePinned: widget.onToggleProjectPinned == null
                      ? null
                      : () => widget.onToggleProjectPinned!(group.projectPath),
                  onLoadMore: () =>
                      widget.onLoadMoreProject?.call(group.projectPath),
                  itemBuilder: buildUnifiedSessionRow,
                ),
            if (widget.currentProjectFilter != null &&
                widget.hasMoreSessions) ...[
              const SizedBox(height: 8),
              _LoadMoreRecentSessionsButton(
                isLoadingMore: widget.isLoadingMore,
                onLoadMore: widget.onLoadMore,
              ),
              const SizedBox(height: 8),
            ],
          ],
        ],
      ],
    );
  }
}

class _LoadMoreRecentSessionsButton extends StatelessWidget {
  final bool isLoadingMore;
  final VoidCallback onLoadMore;

  const _LoadMoreRecentSessionsButton({
    required this.isLoadingMore,
    required this.onLoadMore,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Center(
      child: isLoadingMore
          ? const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : TextButton.icon(
              key: const ValueKey('load_more_button'),
              onPressed: onLoadMore,
              icon: const Icon(Icons.expand_more, size: 18),
              label: Text(l.loadMore),
            ),
    );
  }
}

class _RecentSessionsEmptyResult extends StatelessWidget {
  final String title;
  final String? subtitle;

  const _RecentSessionsEmptyResult({required this.title, this.subtitle});

  @override
  Widget build(BuildContext context) {
    final appColors = Theme.of(context).extension<AppColors>()!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        child: Row(
          children: [
            Icon(Icons.filter_alt_off, color: appColors.subtleText),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: TextStyle(
                        fontSize: 12,
                        color: appColors.subtleText,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProjectRecentSessionGroup extends StatelessWidget {
  final _ProjectSessionGroup group;
  final bool isCollapsed;
  final bool isLoadingMore;
  final int displayLimit;
  final Set<String> alwaysVisibleSessionKeys;
  final bool canLoadFromBridge;
  final bool isPinned;
  final VoidCallback onToggleCollapsed;
  final VoidCallback? onTogglePinned;
  final VoidCallback onLoadMore;
  final Widget Function(UnifiedSessionListItem item) itemBuilder;

  const _ProjectRecentSessionGroup({
    required this.group,
    required this.isCollapsed,
    required this.isLoadingMore,
    required this.displayLimit,
    required this.alwaysVisibleSessionKeys,
    required this.canLoadFromBridge,
    required this.isPinned,
    required this.onToggleCollapsed,
    required this.onTogglePinned,
    required this.onLoadMore,
    required this.itemBuilder,
  });

  @override
  Widget build(BuildContext context) {
    final lastAlwaysVisibleIndex = group.sessions.lastIndexWhere(
      (session) => alwaysVisibleSessionKeys.contains(session.identityKey),
    );
    final requiredVisibleCount = lastAlwaysVisibleIndex + 1;
    final effectiveDisplayLimit = requiredVisibleCount > displayLimit
        ? requiredVisibleCount
        : displayLimit;
    final visibleSessions = group.sessions.take(effectiveDisplayLimit).toList();
    final hasHiddenLoadedSessions =
        group.sessions.length > effectiveDisplayLimit;
    final canShowMore = hasHiddenLoadedSessions || canLoadFromBridge;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ProjectRecentSessionHeader(
            projectPath: group.projectPath,
            projectName: group.projectName,
            isCollapsed: isCollapsed,
            isPinned: isPinned,
            onTap: onToggleCollapsed,
            onTogglePinned: onTogglePinned,
          ),
          if (!isCollapsed) ...[
            const SizedBox(height: 4),
            for (final session in visibleSessions) itemBuilder(session),
            if (isLoadingMore)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else if (canShowMore)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(left: 28, top: 2, bottom: 4),
                  child: InkWell(
                    key: ValueKey('project_show_more_${group.projectPath}'),
                    borderRadius: BorderRadius.circular(6),
                    onTap: onLoadMore,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 5,
                      ),
                      child: Text(
                        AppLocalizations.of(context).showMore,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ),
              )
            else if (group.sessions.isEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 40, top: 4, bottom: 8),
                child: Text(
                  AppLocalizations.of(context).noRecentSessions,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _ProjectRecentSessionHeader extends StatelessWidget {
  final String projectPath;
  final String projectName;
  final bool isCollapsed;
  final bool isPinned;
  final VoidCallback onTap;
  final VoidCallback? onTogglePinned;

  const _ProjectRecentSessionHeader({
    required this.projectPath,
    required this.projectName,
    required this.isCollapsed,
    required this.isPinned,
    required this.onTap,
    required this.onTogglePinned,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey('project_header_$projectPath'),
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Row(
            children: [
              AnimatedRotation(
                turns: isCollapsed ? 0 : 0.25,
                duration: const Duration(milliseconds: 160),
                child: Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  projectName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              PinToggleButton(
                key: ValueKey('pin_project_$projectPath'),
                isPinned: isPinned,
                onPressed: onTogglePinned,
                pinTooltip: AppLocalizations.of(context).pinProject,
                unpinTooltip: AppLocalizations.of(context).unpinProject,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class OfflinePendingSessionCard extends StatelessWidget {
  const OfflinePendingSessionCard({
    super.key,
    required this.action,
    this.onCancel,
  });

  final OfflinePendingAction action;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final appColors = Theme.of(context).extension<AppColors>()!;
    final l = AppLocalizations.of(context);
    final provider = providerFromRaw(action.provider);
    final providerStyle = providerStyleFor(context, provider);
    final statusColor = colorScheme.tertiary;
    final isProcessing = action.state == OfflinePendingActionState.processing;
    final status = isProcessing
        ? switch (action.kind) {
            OfflinePendingActionKind.start =>
              l.pendingActionProcessingStartStatus,
            OfflinePendingActionKind.resume => l.pendingActionProcessingStatus,
          }
        : l.pendingActionStatus;
    final subtitle = switch ((action.state, action.kind)) {
      (
        OfflinePendingActionState.queuedForReconnect,
        OfflinePendingActionKind.start,
      ) =>
        l.pendingActionWillCreateOnReconnect,
      (
        OfflinePendingActionState.queuedForReconnect,
        OfflinePendingActionKind.resume,
      ) =>
        l.pendingActionWillResumeOnReconnect,
      (OfflinePendingActionState.processing, OfflinePendingActionKind.start) =>
        l.pendingActionProcessingStartDescription,
      (OfflinePendingActionState.processing, OfflinePendingActionKind.resume) =>
        l.pendingActionProcessingResumeDescription,
    };
    final title = switch ((action.state, action.kind)) {
      (
        OfflinePendingActionState.queuedForReconnect,
        OfflinePendingActionKind.start,
      ) =>
        l.offlinePendingNewSessionTitle,
      (
        OfflinePendingActionState.queuedForReconnect,
        OfflinePendingActionKind.resume,
      ) =>
        l.offlinePendingResumeTitle,
      (OfflinePendingActionState.processing, OfflinePendingActionKind.start) =>
        l.pendingActionProcessingStartTitle,
      (OfflinePendingActionState.processing, OfflinePendingActionKind.resume) =>
        l.pendingActionProcessingResumeTitle,
    };

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3, horizontal: 0),
      elevation: 0,
      color: colorScheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: statusColor.withValues(alpha: 0.5), width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: statusColor.withValues(alpha: 0.08),
            child: Row(
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: statusColor,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  status,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: statusColor,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 11,
                      color: statusColor.withValues(alpha: 0.82),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (onCancel != null)
                  IconButton(
                    key: const ValueKey('pending_session_cancel_button'),
                    onPressed: onCancel,
                    tooltip: l.tooltipCancelPendingAction,
                    icon: const Icon(Icons.close),
                    iconSize: 18,
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 32,
                      height: 28,
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: providerStyle.background,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: providerStyle.border,
                          width: 0.5,
                        ),
                      ),
                      child: Text(
                        action.projectName,
                        style: TextStyle(
                          fontWeight: FontWeight.w500,
                          fontSize: 12,
                          color: providerStyle.foreground,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(
                      isProcessing ? Icons.cloud_sync : Icons.cloud_off,
                      size: 13,
                      color: appColors.subtleText,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        isProcessing ? l.processingOnBridge : l.queuedLocally,
                        style: TextStyle(
                          fontSize: 11,
                          color: appColors.subtleText,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Skeleton placeholder that mimics a list of [RecentSessionCard] widgets.
///
/// Uses [Skeletonizer] to render dummy cards with a shimmer animation,
/// providing visual feedback while the initial session list is loading.
class _SessionListSkeleton extends StatelessWidget {
  const _SessionListSkeleton();

  static const _dummySessions = [
    RecentSession(
      sessionId: 'skeleton-1',
      firstPrompt: 'Implement the new feature for user authentication flow',
      created: '2025-01-01T00:00:00Z',
      modified: '2025-01-01T01:00:00Z',
      gitBranch: 'feat/auth',
      projectPath: '/projects/my-app',
      isSidechain: false,
    ),
    RecentSession(
      sessionId: 'skeleton-2',
      firstPrompt: 'Fix the CI pipeline build failure on main branch',
      created: '2025-01-01T00:00:00Z',
      modified: '2025-01-01T01:00:00Z',
      gitBranch: 'fix/ci',
      projectPath: '/projects/backend',
      isSidechain: false,
    ),
    RecentSession(
      sessionId: 'skeleton-3',
      firstPrompt: 'Add dark mode support to the settings page',
      created: '2025-01-01T00:00:00Z',
      modified: '2025-01-01T01:00:00Z',
      gitBranch: 'main',
      projectPath: '/projects/mobile',
      isSidechain: false,
    ),
    RecentSession(
      sessionId: 'skeleton-4',
      firstPrompt: 'Refactor database queries for better performance',
      created: '2025-01-01T00:00:00Z',
      modified: '2025-01-01T01:00:00Z',
      gitBranch: 'perf/db',
      projectPath: '/projects/api',
      isSidechain: false,
    ),
    RecentSession(
      sessionId: 'skeleton-5',
      firstPrompt: 'Update documentation for the REST API endpoints',
      created: '2025-01-01T00:00:00Z',
      modified: '2025-01-01T01:00:00Z',
      gitBranch: 'docs',
      projectPath: '/projects/docs',
      isSidechain: false,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Skeletonizer(
      child: Column(
        children: [
          for (final session in _dummySessions)
            RecentSessionCard(session: session, onTap: () {}),
        ],
      ),
    );
  }
}
