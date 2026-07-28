import 'dart:async';
import 'dart:math';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/logger.dart';
import '../../../models/messages.dart';
import '../../../models/new_session_tab.dart';
import '../../../services/bridge_service.dart';
import '../cache/session_catalog_cache_repository.dart';
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

  bool sameAs(SessionCatalogQuery other) =>
      projectPath == other.projectPath &&
      provider == other.provider &&
      namedOnly == other.namedOnly &&
      searchQuery == other.searchQuery;

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
  final SessionCatalogCacheRepository? _catalogCache;
  StreamSubscription<RecentSessionsMessage>? _recentSub;
  StreamSubscription<List<String>>? _projectHistorySub;
  StreamSubscription<BridgeConnectionState>? _connectionSub;
  StreamSubscription<List<SessionInfo>>? _sessionIdentitySub;
  final _catalogSnapshotChanges = StreamController<void>.broadcast();
  Timer? _searchDebounce;
  late final Future<void> _preferencesLoaded;
  Future<void> _preferenceWriteSerial = Future<void>.value();
  SessionCatalogQuery _query = const SessionCatalogQuery();
  Set<String> _authoritativeProjectHistory = const {};
  List<RecentSession> _cachedSessions = const [];
  String? _loadedCacheFingerprint;
  int? _loadedCacheCatalogRevision;
  bool _loadedCacheComplete = false;
  String? _catalogExpansionRequestKey;
  int _filterMutationRevision = 0;
  int _queryRequestRevision = 0;
  int _cacheLoadGeneration = 0;
  int _networkCatalogSerial = 0;
  SessionCatalogQuery? _networkCatalogQuery;
  String? _networkCatalogTargetFingerprint;
  String? _lastCacheLoadFingerprint;

  SessionListCubit({
    required BridgeService bridge,
    SessionCatalogCacheRepository? catalogCache,
  }) : _bridge = bridge,
       _catalogCache = catalogCache,
       super(const SessionListState()) {
    _recentSub = _bridge.recentSessionResponses.listen(_onSessionsUpdate);
    _projectHistorySub = _bridge.projectHistoryStream.listen(
      _onProjectHistoryUpdate,
    );
    _preferencesLoaded = _loadPreferences();
    if (_catalogCache != null) {
      _connectionSub = _bridge.connectionStatus.listen((connectionState) {
        if (connectionState != BridgeConnectionState.disconnected) {
          unawaited(_loadCatalogCacheForCurrentTarget());
        }
      });
      _sessionIdentitySub = _bridge.sessionList.listen((_) {
        unawaited(_loadCatalogCacheForCurrentTarget());
      });
      unawaited(_loadCatalogCacheForCurrentTarget());
    }
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

  Stream<void> get catalogSnapshotChanges => _catalogSnapshotChanges.stream;

  bool get hasUsableCatalogForCurrentTarget {
    final currentTarget = _currentCacheTarget();
    if (currentTarget != null &&
        _bridge.hasAuthoritativeRecentSessionsForCurrentConnection &&
        _networkCatalogQuery?.sameAs(_queryForState()) == true &&
        _networkCatalogTargetFingerprint == currentTarget.fingerprint) {
      return true;
    }
    return currentTarget != null &&
        _loadedCacheComplete &&
        _loadedCacheFingerprint == currentTarget.fingerprint;
  }

  void _onSessionsUpdate(RecentSessionsMessage response) {
    if (!_query.matches(response)) return;
    final establishesNetworkCatalog =
        (response.requestScope == null ||
            response.requestScope == 'list' ||
            response.requestScope == 'catalog') &&
        (response.offset ?? 0) == 0;
    if (establishesNetworkCatalog) {
      _networkCatalogQuery = _query;
      _networkCatalogTargetFingerprint = _currentCacheTarget()?.fingerprint;
    }
    _networkCatalogSerial++;
    final cache = _catalogCache;
    final cacheTarget = _currentCacheTarget();
    if (cache != null && cacheTarget != null) {
      unawaited(
        cache
            .upsertResponse(target: cacheTarget, response: response)
            .catchError((Object error, StackTrace stackTrace) {
              logger.warning(
                '[SessionListCubit] Failed to persist session catalog cache',
                error,
                stackTrace,
              );
            }),
      );
    }

    var sessions = response.sessions;
    var hasMore = response.hasMore;
    final projectPath = response.projectPath;
    final isProjectPage =
        response.requestScope == 'project' &&
        projectPath != null &&
        projectPath.isNotEmpty;
    final canReuseCompleteCache =
        !isProjectPage &&
        (response.offset ?? 0) == 0 &&
        (response.requestScope == null || response.requestScope == 'list') &&
        _loadedCacheComplete &&
        response.catalogRevision != null &&
        response.catalogRevision == _loadedCacheCatalogRevision &&
        _loadedCacheFingerprint == _currentCacheTarget()?.fingerprint;
    if (canReuseCompleteCache) {
      _cachedSessions = _mergeCachedSessions(
        _cachedSessions,
        response.sessions,
      );
      sessions = _filterCachedSessions(_cachedSessions);
      hasMore = false;
    } else if (response.catalogRevision != null &&
        response.catalogRevision != _loadedCacheCatalogRevision) {
      _loadedCacheComplete = false;
      _loadedCacheCatalogRevision = response.catalogRevision;
    }
    final isCompleteCatalogResponse =
        response.requestScope == 'catalog' &&
        (response.offset ?? 0) == 0 &&
        response.projectPath == null &&
        response.provider == null &&
        response.namedOnly != true &&
        (response.searchQuery == null || response.searchQuery!.isEmpty) &&
        !response.hasMore;
    if (isCompleteCatalogResponse) {
      _cachedSessions = response.sessions;
      _loadedCacheFingerprint = _currentCacheTarget()?.fingerprint;
      _loadedCacheCatalogRevision = response.catalogRevision;
      _loadedCacheComplete = true;
      _catalogSnapshotChanges.add(null);
    }

    final newPaths = sessions
        .map((session) => session.projectPath)
        .where((path) => path.isNotEmpty)
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
          exhaustedProjectPaths: hasMore
              ? ({...state.exhaustedProjectPaths}..remove(projectPath))
              : {...state.exhaustedProjectPaths, projectPath},
        ),
      );
      return;
    }

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
    if (establishesNetworkCatalog && !isCompleteCatalogResponse) {
      _catalogSnapshotChanges.add(null);
    }
    _requestExpandedCatalogIfNeeded(
      response,
      canReuseCompleteCache: canReuseCompleteCache,
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
  Future<bool> refreshCatalog({
    bool Function()? isCurrentConnection,
  }) async {
    try {
      await _preferencesLoaded;
      if (isClosed || isCurrentConnection?.call() == false) return false;
      _bridge.requestProjectHistory();
      final requestRevision = ++_queryRequestRevision;
      return await _requestWithCurrentFiltersAfterPreferences(
        requestRevision,
        isCurrentConnection: isCurrentConnection,
      );
    } catch (error, stackTrace) {
      logger.warning(
        '[SessionListCubit] Failed to dispatch session catalog refresh',
        error,
        stackTrace,
      );
      return false;
    }
  }

  /// Ends connection-scoped work while retaining user intent and the last
  /// usable in-memory catalog for a same-target reconnect.
  void handleDisconnect() {
    _searchDebounce?.cancel();
    _queryRequestRevision++;
    _catalogExpansionRequestKey = null;
    _networkCatalogQuery = null;
    _networkCatalogTargetFingerprint = null;
    emit(
      state.copyWith(
        loadingProjectPaths: const {},
        isLoadingMore: false,
        isInitialLoading: state.sessions.isEmpty,
      ),
    );
  }

  /// Removes the rebuildable on-device catalog without hiding the current
  /// in-memory list. A disconnected reconnect must obtain a fresh catalog
  /// before the application-ready gate opens again.
  Future<void> clearPersistentCatalogCache() async {
    _cacheLoadGeneration++;
    await _catalogCache?.clearAll();
    if (isClosed) return;
    _loadedCacheFingerprint = null;
    _loadedCacheCatalogRevision = null;
    _loadedCacheComplete = false;
    _cachedSessions = const [];
    _lastCacheLoadFingerprint = _currentCacheTarget()?.fingerprint;
    _catalogSnapshotChanges.add(null);
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

  SessionCatalogCacheTarget? _currentCacheTarget() {
    final target = SessionCatalogCacheTarget.fromBridge(
      bridgeInstanceId: _bridge.cacheBridgeInstanceIdHint,
      codexSourceId: _bridge.cacheCodexSourceIdHint,
      logicalConnectionIdentity: _bridge.logicalConnectionIdentity,
      websocketUrl: _bridge.lastUrl,
    );
    return target.isValid ? target : null;
  }

  Future<void> _loadCatalogCacheForCurrentTarget() async {
    final cache = _catalogCache;
    final target = _currentCacheTarget();
    if (cache == null || target == null) return;
    if (_lastCacheLoadFingerprint == target.fingerprint) return;
    _lastCacheLoadFingerprint = target.fingerprint;
    final generation = ++_cacheLoadGeneration;
    final networkSerial = _networkCatalogSerial;
    await _preferencesLoaded;
    if (isClosed || generation != _cacheLoadGeneration) return;
    try {
      final snapshot = await cache.load(target);
      if (isClosed ||
          generation != _cacheLoadGeneration ||
          target.fingerprint != _currentCacheTarget()?.fingerprint) {
        return;
      }
      if (snapshot == null) {
        final sourceChanged =
            (_bridge.codexSourceId?.isNotEmpty ?? false) &&
            _loadedCacheFingerprint != null &&
            _loadedCacheFingerprint != target.fingerprint;
        if (sourceChanged &&
            networkSerial == _networkCatalogSerial &&
            !_bridge.hasAuthoritativeRecentSessionsForCurrentConnection) {
          _loadedCacheFingerprint = null;
          _loadedCacheCatalogRevision = null;
          _loadedCacheComplete = false;
          _cachedSessions = const [];
          emit(
            state.copyWith(
              sessions: const [],
              hasMore: false,
              isLoadingMore: false,
              isInitialLoading: true,
              loadingProjectPaths: const {},
            ),
          );
          _catalogSnapshotChanges.add(null);
          return;
        }
        if (_loadedCacheFingerprint == target.fingerprint) {
          _loadedCacheFingerprint = null;
          _loadedCacheCatalogRevision = null;
          _loadedCacheComplete = false;
          _cachedSessions = const [];
          _catalogSnapshotChanges.add(null);
        }
        return;
      }
      _loadedCacheFingerprint = target.fingerprint;
      _loadedCacheCatalogRevision = snapshot.catalogRevision;
      _loadedCacheComplete = snapshot.isComplete;
      _cachedSessions = snapshot.sessions;
      if (networkSerial == _networkCatalogSerial &&
          !_bridge.hasAuthoritativeRecentSessionsForCurrentConnection) {
        final visibleSessions = _filterCachedSessions(snapshot.sessions);
        emit(
          state.copyWith(
            sessions: visibleSessions,
            hasMore: false,
            isLoadingMore: false,
            isInitialLoading: false,
            accumulatedProjectPaths: {
              ..._authoritativeProjectHistory,
              ...snapshot.sessions
                  .map((session) => session.projectPath)
                  .where((path) => path.isNotEmpty),
            },
            loadingProjectPaths: const {},
          ),
        );
      }
      _catalogSnapshotChanges.add(null);
    } catch (error, stackTrace) {
      if (generation == _cacheLoadGeneration &&
          _lastCacheLoadFingerprint == target.fingerprint) {
        _lastCacheLoadFingerprint = null;
      }
      logger.warning(
        '[SessionListCubit] Failed to load session catalog cache',
        error,
        stackTrace,
      );
    }
  }

  List<RecentSession> _filterCachedSessions(Iterable<RecentSession> sessions) {
    final projectPath = _query.projectPath;
    final projectKey = projectPath == null
        ? null
        : _normalizedProjectPath(projectPath);
    final provider = _query.provider;
    final namedOnly = _query.namedOnly == true;
    final searchQuery = _query.searchQuery?.trim().toLowerCase();
    return sessions
        .where((session) {
          if (projectKey != null &&
              _normalizedProjectPath(session.projectPath) != projectKey) {
            return false;
          }
          if (provider != null && session.provider != provider) return false;
          if (namedOnly &&
              (session.name == null || session.name!.trim().isEmpty)) {
            return false;
          }
          if (searchQuery == null || searchQuery.isEmpty) return true;
          return [
            session.name,
            session.summary,
            session.firstPrompt,
            session.lastPrompt,
            session.projectPath,
            session.sessionId,
          ].whereType<String>().any(
            (value) => value.toLowerCase().contains(searchQuery),
          );
        })
        .toList(growable: false);
  }

  static List<RecentSession> _mergeCachedSessions(
    Iterable<RecentSession> cached,
    Iterable<RecentSession> live,
  ) {
    final merged = <String, RecentSession>{
      for (final session in cached) recentSessionPinKey(session): session,
      for (final session in live) recentSessionPinKey(session): session,
    }.values.toList();
    merged.sort((left, right) {
      final modifiedOrder = _compareIsoTimestamps(
        right.modified,
        left.modified,
      );
      if (modifiedOrder != 0) return modifiedOrder;
      return _compareIsoTimestamps(right.created, left.created);
    });
    return List<RecentSession>.unmodifiable(merged);
  }

  static int _compareIsoTimestamps(String left, String right) {
    final leftTime = DateTime.tryParse(left);
    final rightTime = DateTime.tryParse(right);
    if (leftTime != null && rightTime != null) {
      return leftTime.toUtc().compareTo(rightTime.toUtc());
    }
    return left.compareTo(right);
  }

  void _requestExpandedCatalogIfNeeded(
    RecentSessionsMessage response, {
    required bool canReuseCompleteCache,
  }) {
    final requestScope = response.requestScope;
    final isListResponse = requestScope == null || requestScope == 'list';
    final isCatalogResponse = requestScope == 'catalog';
    if (canReuseCompleteCache ||
        !response.hasMore ||
        (response.offset ?? 0) != 0 ||
        (!isListResponse && !isCatalogResponse)) {
      return;
    }
    final currentLimit = response.limit ?? response.sessions.length;
    final expansionLimit = isCatalogResponse
        ? max(1000, max(currentLimit, response.sessions.length) * 2)
        : null;
    final requestKey = [
      _bridge.authoritativeSessionListGeneration,
      response.catalogRevision ?? -1,
      response.queryGeneration ?? -1,
      requestScope ?? '',
      expansionLimit ?? 1000,
      response.provider ?? '',
      response.namedOnly == true ? 1 : 0,
      response.searchQuery ?? '',
      response.projectPath ?? '',
    ].join('\n');
    if (_catalogExpansionRequestKey == requestKey) return;
    _catalogExpansionRequestKey = requestKey;
    if (expansionLimit == null) {
      _bridge.requestRecentSessionsCatalog();
    } else {
      _bridge.requestRecentSessionsCatalog(limit: expansionLimit);
    }
  }

  /// Send a re-fetch request with all current filters applied.
  void _requestWithCurrentFilters() {
    final requestRevision = ++_queryRequestRevision;
    unawaited(_requestWithCurrentFiltersAfterPreferences(requestRevision));
  }

  Future<bool> _requestWithCurrentFiltersAfterPreferences(
    int requestRevision, {
    bool Function()? isCurrentConnection,
  }) async {
    try {
      await _preferencesLoaded;
      if (isClosed ||
          requestRevision != _queryRequestRevision ||
          isCurrentConnection?.call() == false) {
        return false;
      }
      _query = _queryForState();
      _bridge.switchFilter(
        projectPath: _query.projectPath,
        provider: _query.provider,
        namedOnly: _query.namedOnly,
        searchQuery: _query.searchQuery,
      );
      return true;
    } catch (error, stackTrace) {
      logger.warning(
        '[SessionListCubit] Failed to send filtered session catalog request',
        error,
        stackTrace,
      );
      return false;
    }
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
  Future<void> close() async {
    _cacheLoadGeneration++;
    _searchDebounce?.cancel();
    await _recentSub?.cancel();
    await _projectHistorySub?.cancel();
    await _connectionSub?.cancel();
    await _sessionIdentitySub?.cancel();
    await _catalogSnapshotChanges.close();
    await super.close();
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
