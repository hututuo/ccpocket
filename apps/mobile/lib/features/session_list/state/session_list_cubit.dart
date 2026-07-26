import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/logger.dart';
import '../../../models/messages.dart';
import '../../../models/new_session_tab.dart';
import '../../../services/bridge_service.dart';
import 'session_list_state.dart';

const _collapsedProjectPathsKey = 'session_list_collapsed_project_paths';
const _pinnedSessionKeysKey = 'session_list_pinned_session_keys_v1';
const _pinnedProjectPathsKey = 'session_list_pinned_project_paths_v1';
const _projectInitialSessionDisplayLimit = 5;
const _projectSessionDisplayPageSize = 20;

class SessionCatalogQuery {
  const SessionCatalogQuery({
    this.projectPath,
    this.provider,
    this.namedOnly,
    this.searchQuery,
  });

  final String? projectPath;
  final String? provider;
  final bool? namedOnly;
  final String? searchQuery;

  bool matches(RecentSessionsMessage response) {
    // Older Bridges do not echo request correlation. BridgeService keeps
    // their per-socket list generation as the compatibility boundary.
    if (response.queryGeneration == null) return true;
    final targetsAnotherList =
        response.requestScope != 'project' &&
        response.projectPath != projectPath;
    return !targetsAnotherList &&
        response.provider == provider &&
        response.namedOnly == namedOnly &&
        response.searchQuery == searchQuery;
  }
}

String sessionPinKey({
  required String? provider,
  required String projectPath,
  required String sessionId,
}) => '${provider ?? Provider.claude.value}\n$projectPath\n$sessionId';

String recentSessionPinKey(RecentSession session) => sessionPinKey(
  provider: session.provider,
  projectPath: session.projectPath,
  sessionId: session.sessionId,
);

String? runningSessionPinKey(SessionInfo session) {
  final providerSessionId = session.claudeSessionId;
  if (providerSessionId == null || providerSessionId.isEmpty) return null;
  return sessionPinKey(
    provider: session.provider,
    projectPath: session.projectPath,
    sessionId: providerSessionId,
  );
}

List<T> prioritizePinned<T>(
  Iterable<T> items, {
  required bool Function(T item) isPinned,
  bool Function(T item)? isProjectPinned,
}) {
  final pinned = <T>[];
  final pinnedProjects = <T>[];
  final others = <T>[];
  for (final item in items) {
    if (isPinned(item)) {
      pinned.add(item);
    } else if (isProjectPinned?.call(item) ?? false) {
      pinnedProjects.add(item);
    } else {
      others.add(item);
    }
  }
  return [...pinned, ...pinnedProjects, ...others];
}

/// Manages session list state: sessions, filters, pagination, and
/// accumulated project paths.
///
/// All filters (project, provider, namedOnly, searchQuery) are applied
/// server-side. Filter changes trigger a re-fetch from offset 0 with
/// a skeleton loading state.
class SessionListCubit extends Cubit<SessionListState> {
  final BridgeService _bridge;
  StreamSubscription<RecentSessionsMessage>? _recentSub;
  StreamSubscription<List<String>>? _projectHistorySub;
  Timer? _searchDebounce;
  late final Future<void> _preferencesLoaded;
  Future<void> _preferenceWriteSerial = Future<void>.value();
  SessionCatalogQuery _query = const SessionCatalogQuery();
  Set<String> _authoritativeProjectHistory = const {};
  int _filterMutationRevision = 0;
  int _queryRequestRevision = 0;

  SessionListCubit({required BridgeService bridge})
    : _bridge = bridge,
      super(const SessionListState()) {
    _recentSub = _bridge.recentSessionResponses.listen(_onSessionsUpdate);
    _projectHistorySub = _bridge.projectHistoryStream.listen(
      _onProjectHistoryUpdate,
    );
    _preferencesLoaded = _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    final mutationRevision = _filterMutationRevision;
    final prefs = await SharedPreferences.getInstance();
    final providerStr = prefs.getString('session_list_provider');
    final namedOnly = prefs.getBool('session_list_named_only');
    final collapsedProjectPaths =
        prefs.getStringList(_collapsedProjectPathsKey)?.toSet() ??
        const <String>{};
    final pinnedSessionKeys =
        prefs.getStringList(_pinnedSessionKeysKey)?.toSet() ?? const <String>{};
    final pinnedProjectPaths =
        prefs.getStringList(_pinnedProjectPathsKey)?.toSet() ??
        const <String>{};

    var provider = ProviderFilter.all;
    if (providerStr == ProviderFilter.claude.name) {
      provider = ProviderFilter.claude;
    } else if (providerStr == ProviderFilter.codex.name) {
      provider = ProviderFilter.codex;
    }

    if (isClosed) return;
    final filtersWereNotChanged = mutationRevision == _filterMutationRevision;
    emit(
      state.copyWith(
        providerFilter: filtersWereNotChanged ? provider : state.providerFilter,
        namedOnly: filtersWereNotChanged ? namedOnly ?? false : state.namedOnly,
        collapsedProjectPaths: collapsedProjectPaths,
        pinnedSessionKeys: pinnedSessionKeys,
        pinnedProjectPaths: pinnedProjectPaths,
      ),
    );
    _query = _queryForState();
  }

  String? get currentProjectFilter => _query.projectPath;

  bool get hasCatalogSnapshot => !state.isInitialLoading;

  void _onSessionsUpdate(RecentSessionsMessage response) {
    if (!_query.matches(response)) return;
    final sessions = response.sessions;
    final projectPath = response.projectPath;
    final isProjectPage =
        response.requestScope == 'project' &&
        projectPath != null &&
        projectPath.isNotEmpty;
    final newPaths = sessions
        .map((s) => s.projectPath)
        .where((p) => p.isNotEmpty)
        .toSet();
    final merged = {..._authoritativeProjectHistory, ...newPaths};

    if (isProjectPage) {
      emit(
        state.copyWith(
          sessions: sessions,
          isInitialLoading: false,
          accumulatedProjectPaths: merged,
          loadingProjectPaths: {...state.loadingProjectPaths}
            ..remove(projectPath),
          exhaustedProjectPaths: response.hasMore
              ? ({...state.exhaustedProjectPaths}..remove(projectPath))
              : {...state.exhaustedProjectPaths, projectPath},
        ),
      );
      return;
    }

    final hasMore = response.hasMore;
    final finishesPagination =
        response.requestScope == null ||
        response.requestScope == 'list' ||
        response.requestScope == 'append';
    final exhaustedProjectPaths = {...state.exhaustedProjectPaths};
    if (!hasMore) {
      exhaustedProjectPaths.addAll(newPaths);
      final filteredProjectPath = response.projectPath;
      if (filteredProjectPath != null && filteredProjectPath.isNotEmpty) {
        exhaustedProjectPaths.add(filteredProjectPath);
      }
    }
    emit(
      state.copyWith(
        sessions: sessions,
        hasMore: hasMore,
        isLoadingMore: finishesPagination ? false : state.isLoadingMore,
        isInitialLoading: false,
        accumulatedProjectPaths: merged,
        loadingProjectPaths: response.requestScope == 'list'
            ? const {}
            : state.loadingProjectPaths,
        exhaustedProjectPaths: exhaustedProjectPaths,
      ),
    );
  }

  void _onProjectHistoryUpdate(List<String> projects) {
    _authoritativeProjectHistory = projects.toSet();
    final sessionPaths = state.sessions
        .map((session) => session.projectPath)
        .where((path) => path.isNotEmpty);
    emit(
      state.copyWith(
        accumulatedProjectPaths: {
          ..._authoritativeProjectHistory,
          ...sessionPaths,
        },
      ),
    );
  }

  // ---- Filter commands (all trigger server re-fetch) ----

  /// Switch project filter. Resets sessions on the server side and fetches
  /// from offset 0 for the selected project.
  void selectProject(String? projectPath) {
    _filterMutationRevision++;
    _query = SessionCatalogQuery(
      projectPath: projectPath,
      provider: _providerToString(state.providerFilter),
      namedOnly: state.namedOnly ? true : null,
      searchQuery: state.searchQuery.isNotEmpty ? state.searchQuery : null,
    );
    emit(
      state.copyWith(
        isInitialLoading: true,
        loadingProjectPaths: const {},
        exhaustedProjectPaths: const {},
      ),
    );
    _requestWithCurrentFilters();
  }

  /// Set search query with debounce (server-side).
  void setSearchQuery(String query) {
    _filterMutationRevision++;
    emit(state.copyWith(searchQuery: query));
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      if (isClosed) return;
      emit(
        state.copyWith(
          isInitialLoading: true,
          loadingProjectPaths: const {},
          exhaustedProjectPaths: const {},
        ),
      );
      _requestWithCurrentFilters();
    });
  }

  /// Toggle provider filter: All → Codex → Claude → All.
  void toggleProviderFilter({List<ProviderFilter>? allowedFilters}) {
    final options = allowedFilters == null || allowedFilters.isEmpty
        ? const [
            ProviderFilter.all,
            ProviderFilter.codex,
            ProviderFilter.claude,
          ]
        : allowedFilters;
    final currentIndex = options.indexOf(state.providerFilter);
    final next = options[(currentIndex + 1) % options.length];
    setProviderFilter(next);
  }

  void setProviderFilter(ProviderFilter next) {
    if (state.providerFilter == next) return;
    _filterMutationRevision++;
    emit(
      state.copyWith(
        providerFilter: next,
        isInitialLoading: true,
        loadingProjectPaths: const {},
        exhaustedProjectPaths: const {},
      ),
    );
    _requestWithCurrentFilters();
    unawaited(
      _queuePreferenceWrite(
        (prefs) => prefs.setString('session_list_provider', next.name),
      ),
    );
  }

  void applyEnabledAgents(List<NewSessionTab> enabledTabs) {
    final allowed = providerFiltersForEnabledTabs(enabledTabs);
    final next = coerceProviderFilter(state.providerFilter, allowed);
    setProviderFilter(next);
  }

  /// Toggle named-only filter on/off.
  void toggleNamedOnly() {
    final next = !state.namedOnly;
    _filterMutationRevision++;
    emit(
      state.copyWith(
        namedOnly: next,
        isInitialLoading: true,
        loadingProjectPaths: const {},
        exhaustedProjectPaths: const {},
      ),
    );
    _requestWithCurrentFilters();
    unawaited(
      _queuePreferenceWrite(
        (prefs) => prefs.setBool('session_list_named_only', next),
      ),
    );
  }

  /// Load more sessions (pagination).
  void loadMore() {
    if (state.isLoadingMore || !state.hasMore) return;
    emit(state.copyWith(isLoadingMore: true));
    _bridge.loadMoreRecentSessions();
  }

  /// Load the next project-scoped page without replacing other projects.
  void loadMoreProject(String projectPath) {
    if (projectPath.isEmpty ||
        state.loadingProjectPaths.contains(projectPath)) {
      return;
    }
    final projectKey = _normalizedProjectPath(projectPath);
    final loadedCount = state.sessions
        .where(
          (session) =>
              _normalizedProjectPath(session.projectPath) == projectKey,
        )
        .length;
    final currentLimit =
        state.projectSessionDisplayLimits[projectPath] ??
        _projectInitialSessionDisplayLimit;
    final nextLimit = currentLimit + _projectSessionDisplayPageSize;
    final shouldFetch =
        nextLimit > loadedCount &&
        !state.exhaustedProjectPaths.contains(projectPath);
    emit(
      state.copyWith(
        projectSessionDisplayLimits: {
          ...state.projectSessionDisplayLimits,
          projectPath: nextLimit,
        },
        loadingProjectPaths: shouldFetch
            ? {...state.loadingProjectPaths, projectPath}
            : state.loadingProjectPaths,
      ),
    );
    if (!shouldFetch) return;
    _bridge.loadMoreRecentSessions(
      projectPath: projectPath,
      offset: loadedCount,
      pageSize: _projectSessionDisplayPageSize,
      requestScope: 'project',
    );
  }

  Future<void> toggleProjectCollapsed(String projectPath) async {
    if (projectPath.isEmpty) return;
    await _preferencesLoaded;
    if (isClosed) return;
    final next = {...state.collapsedProjectPaths};
    if (!next.remove(projectPath)) {
      next.add(projectPath);
    }
    emit(state.copyWith(collapsedProjectPaths: next));
    await _queuePreferenceWrite(
      (prefs) =>
          prefs.setStringList(_collapsedProjectPathsKey, next.toList()..sort()),
    );
  }

  bool isRecentSessionPinned(RecentSession session) =>
      state.pinnedSessionKeys.contains(recentSessionPinKey(session));

  bool isRunningSessionPinned(SessionInfo session) {
    final key = runningSessionPinKey(session);
    return key != null && state.pinnedSessionKeys.contains(key);
  }

  bool isProjectPinned(String projectPath) =>
      state.pinnedProjectPaths.contains(projectPath);

  Future<void> toggleRecentSessionPinned(RecentSession session) async {
    await _preferencesLoaded;
    if (isClosed) return;
    await _toggleSessionPin(recentSessionPinKey(session));
  }

  Future<void> toggleRunningSessionPinned(SessionInfo session) async {
    final key = runningSessionPinKey(session);
    if (key == null) return;
    await _preferencesLoaded;
    if (isClosed) return;
    await _toggleSessionPin(key);
  }

  Future<void> _toggleSessionPin(String key) async {
    final next = {...state.pinnedSessionKeys};
    if (!next.remove(key)) next.add(key);
    emit(state.copyWith(pinnedSessionKeys: next));
    await _persistStringSet(_pinnedSessionKeysKey, next);
  }

  Future<void> toggleProjectPinned(String projectPath) async {
    if (projectPath.isEmpty) return;
    await _preferencesLoaded;
    if (isClosed) return;
    final next = {...state.pinnedProjectPaths};
    if (!next.remove(projectPath)) next.add(projectPath);
    emit(state.copyWith(pinnedProjectPaths: next));
    await _persistStringSet(_pinnedProjectPathsKey, next);
  }

  Future<void> _persistStringSet(String key, Set<String> values) async {
    final sorted = values.toList()..sort();
    await _queuePreferenceWrite((prefs) => prefs.setStringList(key, sorted));
  }

  /// Request fresh data from the server.
  Future<void> refresh() async {
    await _preferencesLoaded;
    if (isClosed) return;
    _bridge.requestSessionList();
    await refreshCatalog();
  }

  /// Refresh catalog metadata without recursively requesting another
  /// authoritative session-list snapshot.
  Future<void> refreshCatalog() async {
    await _preferencesLoaded;
    if (isClosed) return;
    _bridge.requestProjectHistory();
    final requestRevision = ++_queryRequestRevision;
    await _requestWithCurrentFiltersAfterPreferences(requestRevision);
  }

  /// Ends connection-scoped work while retaining user intent and the last
  /// usable in-memory catalog for a same-target reconnect.
  void handleDisconnect() {
    _searchDebounce?.cancel();
    _queryRequestRevision++;
    emit(
      state.copyWith(
        loadingProjectPaths: const {},
        isLoadingMore: false,
        isInitialLoading: state.sessions.isEmpty,
      ),
    );
  }

  /// Optimistically update a session's name in the local state.
  void updateSessionName(String sessionId, String? name) {
    final updated = state.sessions.map((s) {
      if (s.sessionId == sessionId) {
        return name == null
            ? s.copyWithName(clearName: true)
            : s.copyWithName(name: name);
      }
      return s;
    }).toList();
    emit(state.copyWith(sessions: updated));
  }

  // ---- Private helpers ----

  /// Send a re-fetch request with all current filters applied.
  void _requestWithCurrentFilters() {
    final requestRevision = ++_queryRequestRevision;
    unawaited(_requestWithCurrentFiltersAfterPreferences(requestRevision));
  }

  Future<void> _requestWithCurrentFiltersAfterPreferences(
    int requestRevision,
  ) async {
    await _preferencesLoaded;
    if (isClosed || requestRevision != _queryRequestRevision) return;
    _query = _queryForState();
    _bridge.switchFilter(
      projectPath: _query.projectPath,
      provider: _query.provider,
      namedOnly: _query.namedOnly,
      searchQuery: _query.searchQuery,
    );
  }

  SessionCatalogQuery _queryForState() => SessionCatalogQuery(
    projectPath: _query.projectPath,
    provider: _providerToString(state.providerFilter),
    namedOnly: state.namedOnly ? true : null,
    searchQuery: state.searchQuery.isNotEmpty ? state.searchQuery : null,
  );

  Future<void> _queuePreferenceWrite(
    Future<bool> Function(SharedPreferences prefs) write,
  ) {
    final next = _preferenceWriteSerial.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      await write(prefs);
    });
    _preferenceWriteSerial = next.catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      logger.warning(
        '[SessionListCubit] Failed to persist session-list preference',
        error,
        stackTrace,
      );
    });
    return _preferenceWriteSerial;
  }

  static String _normalizedProjectPath(String value) {
    var normalized = value.trim().replaceAll('\\', '/');
    while (normalized.length > 1 && normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }

  /// Convert [ProviderFilter] enum to the wire-format string (or null for all).
  static String? _providerToString(ProviderFilter f) => switch (f) {
    ProviderFilter.all => null,
    ProviderFilter.claude => 'claude',
    ProviderFilter.codex => 'codex',
  };

  @override
  Future<void> close() {
    _searchDebounce?.cancel();
    _recentSub?.cancel();
    _projectHistorySub?.cancel();
    return super.close();
  }
}

List<ProviderFilter> providerFiltersForEnabledTabs(
  List<NewSessionTab> enabledTabs,
) {
  return switch (enabledAgentsModeFromTabs(enabledTabs)) {
    EnabledAgentsMode.both => const [
      ProviderFilter.all,
      ProviderFilter.codex,
      ProviderFilter.claude,
    ],
    EnabledAgentsMode.codex => const [ProviderFilter.codex],
    EnabledAgentsMode.claude => const [ProviderFilter.claude],
  };
}

ProviderFilter coerceProviderFilter(
  ProviderFilter current,
  List<ProviderFilter> allowedFilters,
) {
  if (allowedFilters.contains(current)) return current;
  return allowedFilters.firstOrNull ?? ProviderFilter.all;
}
