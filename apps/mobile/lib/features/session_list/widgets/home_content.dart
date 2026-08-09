import 'dart:async';
import 'dart:convert';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:provider/provider.dart' hide Provider;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:skeletonizer/skeletonizer.dart';

import '../../../constants/app_constants.dart';
import '../../../l10n/app_localizations.dart';
import '../../../models/machine.dart';
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
import '../../mobile_update/mobile_update_screen.dart';
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
  final String key;
  final String projectPath;
  final String projectName;
  final Set<String> legacyProjectPaths;
  final bool canLoadFromBridge;
  final List<UnifiedSessionListItem> sessions;

  const _ProjectSessionGroup({
    required this.key,
    required this.projectPath,
    required this.projectName,
    required this.legacyProjectPaths,
    required this.canLoadFromBridge,
    required this.sessions,
  });
}

ValueKey<String> _conversationRowKey(String identityKey) =>
    ValueKey('conversation_$identityKey');

List<_ProjectSessionGroup> _groupSessionsByProject({
  required Iterable<String> projectKeys,
  required List<UnifiedSessionListItem> sessions,
  required String projectlessName,
}) {
  final sessionsByKey = <String, List<UnifiedSessionListItem>>{};
  final pathByKey = <String, String>{};
  final nameByKey = <String, String>{};
  final legacyPathsByKey = <String, Set<String>>{};
  final bridgePagingByKey = <String, bool>{};
  for (final session in sessions) {
    final key = session.projectGroupingKey;
    if (key.isEmpty) continue;
    sessionsByKey
        .putIfAbsent(key, () => <UnifiedSessionListItem>[])
        .add(session);
    pathByKey.putIfAbsent(key, () => session.effectiveProjectGroupPath);
    nameByKey.putIfAbsent(
      key,
      () => session.isDesktopProjectless
          ? projectlessName
          : session.projectGroupingName,
    );
    final legacyPaths = legacyPathsByKey.putIfAbsent(key, () => <String>{});
    if (session.projectPath.isNotEmpty) legacyPaths.add(session.projectPath);
    if (session.effectiveProjectGroupPath.isNotEmpty) {
      legacyPaths.add(session.effectiveProjectGroupPath);
    }
    bridgePagingByKey.putIfAbsent(key, () => key == session.projectPath);
  }
  return [
    for (final key in projectKeys)
      if (key.isNotEmpty && (sessionsByKey[key]?.isNotEmpty ?? false))
        _ProjectSessionGroup(
          key: key,
          projectPath: pathByKey[key] ?? key,
          projectName: nameByKey[key] ?? pathBasename(key),
          legacyProjectPaths: Set.unmodifiable(
            legacyPathsByKey[key] ?? const <String>{},
          ),
          canLoadFromBridge: bridgePagingByKey[key] ?? true,
          sessions: sessionsByKey[key] ?? const [],
        ),
  ];
}

Map<String, Set<String>> _projectLegacyAliasOwners(
  Iterable<UnifiedSessionListItem> sessions,
) {
  final owners = <String, Set<String>>{};
  for (final session in sessions) {
    final projectKey = session.projectGroupingKey;
    if (projectKey.isEmpty) continue;
    if (_isStableDesktopProjectKey(projectKey) &&
        session.recent?.projectGroupingSnapshotComplete != true) {
      continue;
    }
    for (final alias in {
      session.projectPath,
      session.effectiveProjectGroupPath,
    }) {
      if (alias.isEmpty) continue;
      owners.putIfAbsent(alias, () => <String>{}).add(projectKey);
    }
  }
  return owners;
}

bool _isStableDesktopProjectKey(String key) =>
    key.startsWith('desktop-project:');

bool _legacyAliasBelongsOnlyToGroup(
  String alias,
  _ProjectSessionGroup group,
  Map<String, Set<String>> legacyAliasOwners,
) {
  final owners = legacyAliasOwners[alias];
  return _isStableDesktopProjectKey(group.key) &&
      owners?.length == 1 &&
      owners?.single == group.key;
}

bool _groupContainsProjectKey(
  Set<String> values,
  _ProjectSessionGroup group,
  Map<String, Set<String>> legacyAliasOwners,
) =>
    values.contains(group.key) ||
    group.legacyProjectPaths.any(
      (alias) =>
          values.contains(alias) &&
          _legacyAliasBelongsOnlyToGroup(alias, group, legacyAliasOwners),
    );

int _groupDisplayLimit(
  Map<String, int> limits,
  _ProjectSessionGroup group,
  Map<String, Set<String>> legacyAliasOwners,
) {
  var result = limits[group.key] ?? 5;
  for (final path in group.legacyProjectPaths) {
    if (!_legacyAliasBelongsOnlyToGroup(path, group, legacyAliasOwners)) {
      continue;
    }
    final legacy = limits[path];
    if (legacy != null && legacy > result) result = legacy;
  }
  return result;
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

/// Destructive conversation actions must fail closed while the canonical
/// app-server says a turn is active or while shared control is unresolved.
/// A missing status remains the legacy compatibility path.
bool conversationDestructiveActionBlocked(ConversationSyncV2Status? status) =>
    status != null &&
    (status.activity == 'working' ||
        status.activity == 'compacting' ||
        status.activity == 'unknown' ||
        status.confidence == 'unknown' ||
        status.controlState == 'reconciling');

SessionInfo _sessionInfoForUnifiedCard(
  UnifiedSessionListItem item,
  SessionDisplayMode displayMode, {
  DateTime? orderingActivityAt,
}) {
  final runtime = item.running;
  final catalog = item.recent;
  final syncStatus = item.syncStatus;
  final desktopTurnActive =
      syncStatus?.executionHost == 'desktopAppServer' &&
      (syncStatus?.activity == 'working' ||
          syncStatus?.activity == 'compacting');
  if (catalog == null) {
    return runtime!.copyWith(
      lastActivityAt: orderingActivityAt?.toIso8601String(),
      externalDesktopTurnActive:
          runtime.externalDesktopTurnActive || desktopTurnActive,
    );
  }

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
    // The catalog is provider-owned metadata. Its nullable name is also an
    // authoritative clear, so a stale runtime attachment must not win after a
    // Desktop rename or clear.
    name: catalog.name,
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
    lastActivityAt:
        orderingActivityAt?.toIso8601String() ??
        (catalog.modified.isNotEmpty
            ? catalog.modified
            : (runtime?.lastActivityAt ?? catalog.created)),
    lastAssistantOutputAt:
        runtime?.lastAssistantOutputAt ?? catalog.lastAssistantOutputAt,
    gitBranch: preferRuntime(runtime?.gitBranch, catalog.gitBranch),
    // The display-mode chip is an explicit request to view provider catalog
    // metadata (first prompt, last prompt, or summary). A transient runtime
    // attachment often carries its own latest text; letting that value win
    // made the chip appear to do nothing for watched/running conversations.
    lastMessage: _recentSessionCardText(catalog, displayMode),
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
    externalDesktopTurnActive:
        (runtime?.externalDesktopTurnActive ?? false) || desktopTurnActive,
    codexNativePlanModeSupported: runtime?.codexNativePlanModeSupported,
    codexGoalControlSupported: runtime?.codexGoalControlSupported,
    pendingPermission: runtime?.pendingPermission,
    queuedInput: runtime?.queuedInput,
    queuedInputs: runtime?.queuedInputs ?? const [],
    queuedInputLimit: runtime?.queuedInputLimit ?? 1,
  );
}

class HomeContent extends StatefulWidget {
  final BridgeConnectionState connectionState;
  final String? bridgeVersion;
  final int? bridgeCompatibilityRevision;
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
  final String projectOrderScope;
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
    this.bridgeCompatibilityRevision,
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
    this.projectOrderScope = 'unknown-bridge',
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
  static const _projectOrderPreferenceKey =
      'session_list_project_order_by_source_v1';
  static const _maximumStoredProjectScopes = 64;
  static const _maximumStoredProjectsPerScope = 2048;
  static const _maximumProjectOrderBytes = 1024 * 1024;
  static Future<void>? _projectOrderGlobalWriteTail;

  bool _isSearching = false;
  bool _updateBannerDismissed = false;
  bool _showSupportBanner = false;
  bool _groupByProject = true;
  final _searchController = TextEditingController();
  SessionDisplayMode _displayMode = SessionDisplayMode.first;
  List<String> _projectOrder = const [];
  ({String scope, List<String> order})? _pendingProjectOrder;
  String? _loadedProjectOrderScope;
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
    final projectOrders = _readProjectOrders(prefs);
    final scope = _normalizedProjectOrderScope(widget.projectOrderScope);
    if (!mounted) return;
    if (scope != _normalizedProjectOrderScope(widget.projectOrderScope)) {
      unawaited(_loadProjectOrderForCurrentScope());
      return;
    }
    setState(() {
      if (modeStr != null) {
        _displayMode = SessionDisplayMode.values.firstWhere(
          (m) => m.name == modeStr,
          orElse: () => SessionDisplayMode.first,
        );
      }
      _groupByProject = groupByProject;
      _loadedProjectOrderScope = scope;
      _projectOrder = List.unmodifiable(projectOrders[scope] ?? const []);
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
    if (widget.projectOrderScope != oldWidget.projectOrderScope) {
      unawaited(_loadProjectOrderForCurrentScope());
    }
  }

  Future<void> _loadProjectOrderForCurrentScope() async {
    final scope = _normalizedProjectOrderScope(widget.projectOrderScope);
    if (_loadedProjectOrderScope == scope) return;
    final prefs = await SharedPreferences.getInstance();
    final orders = _readProjectOrders(prefs);
    if (!mounted ||
        scope != _normalizedProjectOrderScope(widget.projectOrderScope)) {
      return;
    }
    setState(() {
      _loadedProjectOrderScope = scope;
      _projectOrder = List.unmodifiable(orders[scope] ?? const []);
      _pendingProjectOrder = null;
    });
  }

  List<String> _applyProjectOrder(List<String> naturalOrder) {
    final currentScope = _normalizedProjectOrderScope(widget.projectOrderScope);
    // A scope change can render once before SharedPreferences finishes
    // loading. Never project the previous Bridge/source's manual order into
    // that interim frame; use the new source's natural order until its own
    // persisted order is available.
    final persistedOrder = _loadedProjectOrderScope == currentScope
        ? _projectOrder
        : const <String>[];
    final available = naturalOrder.toSet();
    final result = <String>[
      for (final key in persistedOrder)
        if (available.remove(key)) key,
      ...naturalOrder.where(available.contains),
    ];
    if (_loadedProjectOrderScope == currentScope) {
      _ensureProjectOrderPersisted(result);
    }
    return List.unmodifiable(result);
  }

  void _ensureProjectOrderPersisted(List<String> order) {
    final scope = _normalizedProjectOrderScope(widget.projectOrderScope);
    if (_loadedProjectOrderScope != scope ||
        _sameStringList(_projectOrder, order) ||
        (_pendingProjectOrder?.scope == scope &&
            _sameStringList(_pendingProjectOrder?.order, order))) {
      return;
    }
    _pendingProjectOrder = (scope: scope, order: List.unmodifiable(order));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final pending = _pendingProjectOrder;
      if (!mounted ||
          pending == null ||
          pending.scope != scope ||
          _loadedProjectOrderScope != scope ||
          _normalizedProjectOrderScope(widget.projectOrderScope) != scope) {
        return;
      }
      _pendingProjectOrder = null;
      // The current frame already rendered this exact natural order. Adopt it
      // without another rebuild so stable conversation elements are not
      // detached merely because presentation order was first persisted.
      _projectOrder = pending.order;
      unawaited(_persistProjectOrder(pending.order, scope: scope));
    });
  }

  void _moveProject(
    List<String> visibleOrder,
    String source,
    String target,
    bool placeAfter,
  ) {
    if (_loadedProjectOrderScope !=
        _normalizedProjectOrderScope(widget.projectOrderScope)) {
      return;
    }
    if (source == target) return;
    final order = <String>[
      ..._projectOrder,
      for (final key in visibleOrder)
        if (!_projectOrder.contains(key)) key,
    ];
    if (!order.remove(source)) return;
    var targetIndex = order.indexOf(target);
    if (targetIndex < 0) return;
    if (placeAfter) targetIndex += 1;
    order.insert(targetIndex.clamp(0, order.length).toInt(), source);
    setState(() {
      _pendingProjectOrder = null;
      _projectOrder = List.unmodifiable(order);
    });
    unawaited(
      _persistProjectOrder(
        order,
        scope: _normalizedProjectOrderScope(widget.projectOrderScope),
      ),
    );
  }

  Future<void> _persistProjectOrder(
    List<String> order, {
    required String scope,
  }) async {
    final snapshot = order
        .take(_maximumStoredProjectsPerScope)
        .toList(growable: false);
    Future<void> write() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        final orders = _readProjectOrders(prefs);
        orders.remove(scope);
        orders[scope] = snapshot;
        while (orders.length > _maximumStoredProjectScopes) {
          orders.remove(orders.keys.first);
        }
        final encoded = _encodeProjectOrdersWithinBudget(
          orders,
          currentScope: scope,
        );
        await prefs.setString(_projectOrderPreferenceKey, encoded);
      } catch (_) {
        // Ordering is rebuildable presentation state. Keep the in-memory order
        // usable and allow the next reorder to retry persistence.
      }
    }

    final previous = _projectOrderGlobalWriteTail;
    final operation = previous == null
        ? Future<void>.sync(write)
        : previous.then((_) => write());
    late final Future<void> settled;
    settled = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _projectOrderGlobalWriteTail = settled;
    unawaited(
      settled.whenComplete(() {
        if (identical(_projectOrderGlobalWriteTail, settled)) {
          _projectOrderGlobalWriteTail = null;
        }
      }),
    );
    await operation;
  }

  static String _encodeProjectOrdersWithinBudget(
    Map<String, List<String>> orders, {
    required String currentScope,
  }) {
    while (true) {
      final encoded = jsonEncode(orders);
      if (utf8.encode(encoded).length <= _maximumProjectOrderBytes) {
        return encoded;
      }
      if (orders.length > 1) {
        orders.remove(orders.keys.first);
        continue;
      }
      final current = orders[currentScope] ?? const <String>[];
      if (current.isEmpty) return jsonEncode(<String, List<String>>{});
      orders[currentScope] = current
          .take(current.length ~/ 2)
          .toList(growable: false);
    }
  }

  static Map<String, List<String>> _readProjectOrders(
    SharedPreferences preferences,
  ) {
    final raw = preferences.getString(_projectOrderPreferenceKey);
    if (raw == null || raw.length > _maximumProjectOrderBytes) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final result = <String, List<String>>{};
      for (final entry in decoded.entries.take(_maximumStoredProjectScopes)) {
        final scope = _validProjectOrderValue(entry.key);
        final values = entry.value;
        if (scope == null || values is! List) continue;
        final unique = <String>{};
        for (final value in values.take(_maximumStoredProjectsPerScope)) {
          final key = _validProjectOrderValue(value);
          if (key != null) unique.add(key);
        }
        result[scope] = unique.toList(growable: false);
      }
      return result;
    } catch (_) {
      return {};
    }
  }

  static String _normalizedProjectOrderScope(String value) =>
      _validProjectOrderValue(value) ?? 'unknown-bridge';

  static String? _validProjectOrderValue(Object? value) {
    if (value is! String) return null;
    final normalized = value.trim();
    if (normalized.isEmpty ||
        normalized.length > 4096 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(normalized)) {
      return null;
    }
    return normalized;
  }

  static bool _sameStringList(List<String>? left, List<String>? right) {
    if (identical(left, right)) return true;
    if (left == null || right == null || left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
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
      bridgeCompatibilityRevision: widget.bridgeCompatibilityRevision,
    )) {
      return null;
    }
    final compatibility = compareClientBridgeCompatibility(
      bridgeRevision: widget.bridgeCompatibilityRevision,
      mobileRevision: AppConstants.clientBridgeCompatibilityRevision,
    );
    return BridgeUpdateBanner(
      currentVersion: widget.bridgeVersion!,
      bridgeCompatibilityRevision: widget.bridgeCompatibilityRevision,
      onTap: compatibility == ClientBridgeCompatibility.mobileOlder
          ? () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => const MobileUpdateScreen(),
              ),
            )
          : widget.onOpenBridgeSettings ??
                () => context.pushRoute(SettingsRoute(focusConnection: true)),
      onDismiss: () => setState(() => _updateBannerDismissed = true),
    );
  }

  bool _hasVisibleBridgeUpdateBanner() {
    return !_updateBannerDismissed &&
        BridgeUpdateBanner.shouldShow(
          widget.bridgeVersion,
          bridgeCompatibilityRevision: widget.bridgeCompatibilityRevision,
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

  void _openRunningSession(UnifiedSessionListItem item) {
    final session = item.running!;
    widget.onTapRunning(
      session.id,
      projectPath: session.projectPath,
      gitBranch: session.worktreePath != null
          ? session.worktreeBranch
          : session.gitBranch,
      worktreePath: session.worktreePath,
      provider: item.provider,
      durableProviderSessionId: item.providerSessionId,
      permissionMode: session.permissionMode,
      sandboxMode: session.codexSandboxMode,
      approvalPolicy: session.codexApprovalPolicy,
      approvalsReviewer: session.codexApprovalsReviewer,
    );
  }

  Widget _buildContent(BuildContext context) {
    final l = AppLocalizations.of(context);
    final appColors = Theme.of(context).extension<AppColors>()!;
    final pendingStartActions = widget.offlinePendingActions
        .where(
          (action) =>
              action.kind == OfflinePendingActionKind.start &&
              (action.sessionId?.trim().isEmpty ?? true),
        )
        .toList(growable: false);
    final pendingResumeActionsByIdentity = <String, OfflinePendingAction>{};
    for (final action in widget.offlinePendingActions) {
      if (action.kind != OfflinePendingActionKind.resume) continue;
      final durableId = action.sessionId?.trim();
      if (durableId == null || durableId.isEmpty) continue;
      final identity = providerSessionIdentityKey(action.provider, durableId);
      final current = pendingResumeActionsByIdentity[identity];
      if (current == null ||
          (current.state != OfflinePendingActionState.processing &&
              action.state == OfflinePendingActionState.processing)) {
        pendingResumeActionsByIdentity[identity] = action;
      }
    }
    final hasPendingActions = pendingStartActions.isNotEmpty;
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
            projectPath: null,
            namedOnly: widget.namedOnly,
            searchQuery: widget.searchQuery,
          ),
        );
    final runningSessions = widget.sessions.where(
      (session) => runningSessionMatchesListFilters(
        session,
        providerFilter: widget.providerFilter,
        projectPath: null,
        namedOnly: widget.namedOnly,
        searchQuery: widget.searchQuery,
      ),
    );
    final allUnifiedSessions = buildUnifiedSessionList(
      runningSessions: runningSessions,
      recentSessions: catalogSessions,
      pinnedSessionKeys: widget.pinnedSessionKeys,
      unseenSessionIds: widget.unseenSessionIds,
      conversationStatuses: widget.conversationStatuses,
      unreadConversationKeys: widget.unreadConversationKeys,
    );
    final hasActiveFilter =
        widget.currentProjectFilter != null ||
        widget.providerFilter != ProviderFilter.all ||
        widget.namedOnly ||
        widget.searchQuery.isNotEmpty;
    final canUseLegacyProjectAliases =
        !hasActiveFilter && !widget.isInitialLoading && !widget.hasMoreSessions;
    final legacyAliasOwners = canUseLegacyProjectAliases
        ? _projectLegacyAliasOwners(allUnifiedSessions)
        : const <String, Set<String>>{};
    final unifiedSessions = widget.currentProjectFilter == null
        ? allUnifiedSessions
        : allUnifiedSessions
              .where(
                (session) =>
                    isDesktopProjectGroupingKey(widget.currentProjectFilter)
                    ? session.projectGroupingKey == widget.currentProjectFilter
                    : session.projectPath == widget.currentProjectFilter,
              )
              .toList(growable: false);
    final alwaysVisibleSessionKeys = {
      for (final item in unifiedSessions)
        if (sessionListItemBypassesDisplayLimit(
          item,
          unseenSessionIds: widget.unseenSessionIds,
        ))
          item.identityKey,
    };
    final hasConversationSessions = unifiedSessions.isNotEmpty;
    final representedProjectPaths = {
      for (final session in allUnifiedSessions) session.projectPath,
    };
    final effectivePinnedProjectKeys = {
      ...widget.pinnedProjectPaths,
      for (final entry in legacyAliasOwners.entries)
        if (entry.value.length == 1 &&
            _isStableDesktopProjectKey(entry.value.single) &&
            widget.pinnedProjectPaths.contains(entry.key))
          entry.value.single,
    };
    final naturalProjectKeys = orderProjectPathsForGroupedView(
      knownProjectPaths: <String>[
        if (widget.currentProjectFilter != null) widget.currentProjectFilter!,
        ...widget.accumulatedProjectPaths.where(
          (path) => !representedProjectPaths.contains(path),
        ),
      ],
      sessions: allUnifiedSessions,
      pinnedSessionKeys: widget.pinnedSessionKeys,
      pinnedProjectPaths: effectivePinnedProjectKeys,
      unseenSessionIds: widget.unseenSessionIds,
    );
    final allProjectKeys = _applyProjectOrder(naturalProjectKeys);
    final allGroupedSessions = _groupSessionsByProject(
      projectKeys: allProjectKeys,
      sessions: allUnifiedSessions,
      projectlessName: l.unassignedProject,
    );
    final groupedSessions = widget.currentProjectFilter == null
        ? allGroupedSessions
        : !isDesktopProjectGroupingKey(widget.currentProjectFilter)
        ? _groupSessionsByProject(
            projectKeys: allProjectKeys,
            sessions: unifiedSessions,
            projectlessName: l.unassignedProject,
          )
        : allGroupedSessions
              .where((group) => group.key == widget.currentProjectFilter)
              .toList(growable: false);

    Widget buildUnifiedSessionRow(UnifiedSessionListItem item) {
      final running = item.running;
      final recent = item.recent;
      final orderingActivityAt = sessionListOrderingActivityFor(
        item,
        unseenSessionIds: widget.unseenSessionIds,
      );
      final cardSession = _sessionInfoForUnifiedCard(
        item,
        _displayMode,
        orderingActivityAt: orderingActivityAt,
      );
      final destructiveActionBlocked =
          cardSession.externalDesktopTurnActive ||
          conversationDestructiveActionBlocked(item.syncStatus);
      final pendingResumeAction =
          pendingResumeActionsByIdentity[item.identityKey];
      final isProcessing =
          recent != null &&
          widget.archivingSessionIds.contains(
            providerSessionIdentityKey(
              recent.provider ?? Provider.claude.value,
              recent.sessionId,
            ),
          );
      final stableKey = _conversationRowKey(item.identityKey);
      final slidableKey = ValueKey('conversation_slidable_${item.identityKey}');
      final row = Slidable(
        key: slidableKey,
        endActionPane: destructiveActionBlocked
            ? null
            : ActionPane(
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
            pendingResumeAction: pendingResumeAction,
            onCancelPendingResume:
                pendingResumeAction == null ||
                    !pendingResumeAction.canCancel ||
                    widget.onCancelOfflinePendingAction == null
                ? null
                : () => widget.onCancelOfflinePendingAction!(
                    pendingResumeAction.id,
                  ),
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
            onStop:
                running != null &&
                    !running.externalDesktopTurnActive &&
                    showInlineStopButton
                ? () => widget.onStopSession(running.id)
                : null,
            onTap: running != null
                ? () => _openRunningSession(item)
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

    final contentEntries = <Object>[
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
          projects: allGroupedSessions
              .map((group) => (path: group.key, name: group.projectName))
              .toList(growable: false),
          currentProjectFilter: widget.currentProjectFilter,
          onProjectFilterChanged: widget.onSelectProject,
          namedOnly: widget.namedOnly,
          onToggleNamed: widget.onToggleNamed,
        ),
        const SizedBox(height: 8),
        for (final action in pendingStartActions)
          OfflinePendingSessionCard(
            key: ValueKey('pending_session_${action.id}'),
            action: action,
            onCancel:
                widget.onCancelOfflinePendingAction == null || !action.canCancel
                ? null
                : () => widget.onCancelOfflinePendingAction!(action.id),
          ),
        if (widget.isInitialLoading) ...[
          for (final item in unifiedSessions.where(
            (item) => item.running != null,
          ))
            item,
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
            ...unifiedSessions,
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
                key: ValueKey('project_group_${group.key}'),
                group: group,
                isCollapsed: _groupContainsProjectKey(
                  widget.collapsedProjectPaths,
                  group,
                  legacyAliasOwners,
                ),
                isLoadingMore: _groupContainsProjectKey(
                  widget.loadingProjectPaths,
                  group,
                  legacyAliasOwners,
                ),
                displayLimit: _groupDisplayLimit(
                  widget.projectSessionDisplayLimits,
                  group,
                  legacyAliasOwners,
                ),
                alwaysVisibleSessionKeys: alwaysVisibleSessionKeys,
                canLoadFromBridge:
                    group.canLoadFromBridge &&
                    widget.currentProjectFilter == null &&
                    !widget.exhaustedProjectPaths.contains(group.key),
                isPinned: _groupContainsProjectKey(
                  widget.pinnedProjectPaths,
                  group,
                  legacyAliasOwners,
                ),
                onToggleCollapsed: () =>
                    widget.onToggleProjectCollapsed?.call(group.key),
                onTogglePinned: widget.onToggleProjectPinned == null
                    ? null
                    : () => widget.onToggleProjectPinned!(group.key),
                onLoadMore: () => widget.onLoadMoreProject?.call(group.key),
                reorderEnabled:
                    widget.currentProjectFilter == null &&
                    _loadedProjectOrderScope ==
                        _normalizedProjectOrderScope(
                          widget.projectOrderScope,
                        ) &&
                    groupedSessions.length > 1,
                onMoveProject: (source, target, placeAfter) =>
                    _moveProject(allProjectKeys, source, target, placeAfter),
                itemBuilder: buildUnifiedSessionRow,
              ),
          if (widget.currentProjectFilter != null &&
              !isDesktopProjectGroupingKey(widget.currentProjectFilter) &&
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
    ];

    final childIndexByKey = <Key, int>{};
    for (var index = 0; index < contentEntries.length; index++) {
      final entry = contentEntries[index];
      if (entry case final UnifiedSessionListItem item) {
        childIndexByKey[_conversationRowKey(item.identityKey)] = index;
      } else if (entry case final Widget widget when widget.key != null) {
        childIndexByKey[widget.key!] = index;
      }
    }

    return ListView.builder(
      key: const ValueKey('session_list'),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(12),
      itemCount: contentEntries.length,
      findChildIndexCallback: (key) => childIndexByKey[key],
      itemBuilder: (context, index) {
        final entry = contentEntries[index];
        if (entry is UnifiedSessionListItem) {
          return buildUnifiedSessionRow(entry);
        }
        return entry as Widget;
      },
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
  final bool reorderEnabled;
  final void Function(String source, String target, bool placeAfter)
  onMoveProject;
  final Widget Function(UnifiedSessionListItem item) itemBuilder;

  const _ProjectRecentSessionGroup({
    super.key,
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
    required this.reorderEnabled,
    required this.onMoveProject,
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
    final content = Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ProjectRecentSessionHeader(
            projectPath: group.key,
            projectName: group.projectName,
            isCollapsed: isCollapsed,
            isPinned: isPinned,
            onTap: onToggleCollapsed,
            onTogglePinned: onTogglePinned,
            reorderEnabled: reorderEnabled,
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
                    key: ValueKey('project_show_more_${group.key}'),
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
    if (!reorderEnabled) return content;
    return Builder(
      builder: (dropTargetContext) => DragTarget<String>(
        key: ValueKey('project_drop_${group.key}'),
        onWillAcceptWithDetails: (details) => details.data != group.key,
        onAcceptWithDetails: (details) {
          final renderObject = dropTargetContext.findRenderObject();
          final box = renderObject is RenderBox ? renderObject : null;
          final localOffset = box?.globalToLocal(details.offset);
          final placeAfter =
              box != null &&
              localOffset != null &&
              localOffset.dy > box.size.height / 2;
          onMoveProject(details.data, group.key, placeAfter);
        },
        builder: (context, candidates, _) => DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: candidates.isEmpty
                ? null
                : Border.all(color: Theme.of(context).colorScheme.primary),
          ),
          child: content,
        ),
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
  final bool reorderEnabled;

  const _ProjectRecentSessionHeader({
    required this.projectPath,
    required this.projectName,
    required this.isCollapsed,
    required this.isPinned,
    required this.onTap,
    required this.onTogglePinned,
    required this.reorderEnabled,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final header = Material(
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
    if (!reorderEnabled) return header;
    return LongPressDraggable<String>(
      key: ValueKey('project_drag_$projectPath'),
      data: projectPath,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(10),
        color: colorScheme.surface,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 280),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Text(
              projectName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.45, child: header),
      child: header,
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
