import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/logger.dart';
import '../../../models/messages.dart';
import '../../../models/new_session_tab.dart';
import '../../../services/bridge_service.dart';
import '../../../utils/diagnostic_token.dart';
import '../../conversation_content_sync/conversation_content_sync_service.dart';
import '../cache/session_catalog_cache_repository.dart';
import 'session_list_state.dart';

const _collapsedProjectPathsKey = 'session_list_collapsed_project_paths';
const _pinnedSessionKeysKey = 'session_list_pinned_session_keys_v1';
const _pinnedProjectPathsKey = 'session_list_pinned_project_paths_v1';
const _projectInitialSessionDisplayLimit = 5;
const _projectSessionDisplayPageSize = 20;
const _maximumCatalogExpansionLimit = 1000;

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
/// Provider, named and search filters are applied server-side. Legacy path
/// filters remain server-side; Desktop-owned project IDs are presentation
/// keys and are applied locally to the complete catalog projection.
class SessionListCubit extends Cubit<SessionListState> {
  final BridgeService _bridge;
  final SessionCatalogCacheRepository? _catalogCache;
  final ConversationContentSyncService? _conversationSync;
  StreamSubscription<RecentSessionsMessage>? _recentSub;
  StreamSubscription<List<String>>? _projectHistorySub;
  StreamSubscription<BridgeConnectionState>? _connectionSub;
  StreamSubscription<List<SessionInfo>>? _sessionIdentitySub;
  StreamSubscription<ConversationSyncCacheUpdate>? _conversationSyncSub;
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
  String? _v2StateFingerprint;
  bool _v2CachedPriorityReady = false;
  bool _v2PriorityReady = false;
  bool _syncCacheReloadRunning = false;
  bool _syncCacheReloadPending = false;
  Map<String, ConversationSyncV2Status> _conversationStatuses = const {};
  Map<String, String> _conversationReadWatermarks = const {};

  SessionListCubit({
    required BridgeService bridge,
    SessionCatalogCacheRepository? catalogCache,
    ConversationContentSyncService? conversationSync,
  }) : _bridge = bridge,
       _catalogCache = catalogCache,
       _conversationSync = conversationSync,
       super(const SessionListState()) {
    _recentSub = _bridge.recentSessionResponses.listen(_onSessionsUpdate);
    _projectHistorySub = _bridge.projectHistoryStream.listen(
      _onProjectHistoryUpdate,
    );
    _preferencesLoaded = _loadPreferences();
    if (_catalogCache != null) {
      _connectionSub = _bridge.connectionStatus.listen((connectionState) {
        if (_bridge.supportsConversationSyncV2 &&
            connectionState != BridgeConnectionState.connected) {
          _v2PriorityReady = false;
          _catalogSnapshotChanges.add(null);
        }
        if (connectionState != BridgeConnectionState.disconnected) {
          unawaited(_loadCatalogCacheForCurrentTarget());
        }
      });
      _sessionIdentitySub = _bridge.sessionList.listen((_) {
        unawaited(_loadCatalogCacheForCurrentTarget());
      });
      _conversationSyncSub = _conversationSync?.syncUpdates.listen(
        _onConversationSyncUpdate,
      );
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

  String? get currentProjectFilter => state.selectedProjectKey;

  Stream<void> get catalogSnapshotChanges => _catalogSnapshotChanges.stream;

  /// Returns the latest committed provider-owned metadata even when the home
  /// list is currently filtered to another project.
  RecentSession? catalogSessionFor(
    String providerSessionId, {
    String? provider,
  }) {
    RecentSession? findIn(Iterable<RecentSession> sessions) {
      for (final session in sessions) {
        if (session.sessionId != providerSessionId) continue;
        final sessionProvider = session.provider ?? Provider.claude.value;
        if (provider == null || sessionProvider == provider) return session;
      }
      return null;
    }

    // A network catalog page is committed to [state.sessions] before the
    // rebuildable disk snapshot is necessarily rewritten. Prefer that newer
    // projection for visible threads, then fall back to the complete cache for
    // threads hidden by the current home filter.
    return findIn(state.sessions) ?? findIn(_cachedSessions);
  }

  /// Opaque authenticated Bridge/source partition for detached projections.
  /// A route/IP change that resolves to the same Bridge/source keeps the same
  /// fingerprint, while a different Codex Home cannot reuse stale facts.
  String? get conversationSourceFingerprint =>
      _currentCacheTarget()?.fingerprint;

  bool get hasUsableCatalogForCurrentTarget {
    final currentTarget = _currentCacheTarget();
    if (_bridge.supportsConversationSyncV2) {
      return currentTarget != null &&
          _v2PriorityReady &&
          _v2StateFingerprint == currentTarget.fingerprint;
    }
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

  /// Whether a previously committed v2 priority snapshot is available for an
  /// explicit user-selected cached entry. This must not unlock automatic home
  /// navigation: only [hasUsableCatalogForCurrentTarget] reflects the current
  /// socket subscription.
  bool get hasCachedCatalogForCurrentTarget {
    final currentTarget = _currentCacheTarget();
    if (_bridge.supportsConversationSyncV2) {
      return currentTarget != null &&
          _v2CachedPriorityReady &&
          _loadedCacheFingerprint == currentTarget.fingerprint &&
          _cachedSessions.isNotEmpty;
    }
    return currentTarget != null &&
        _loadedCacheComplete &&
        _loadedCacheFingerprint == currentTarget.fingerprint;
  }

  ConversationSyncV2Status? conversationStatusFor(RecentSession session) =>
      _conversationStatuses['${session.provider ?? Provider.claude.value}\u0000'
          '${session.sessionId}'];

  Map<String, ConversationSyncV2Status> get conversationStatuses =>
      _conversationStatuses;

  RecentSession? conversationMetadataFor(
    String provider,
    String providerSessionId,
  ) {
    final key = _conversationKey(provider, providerSessionId);
    for (final session in _cachedSessions) {
      if (_conversationKey(
            session.provider ?? Provider.claude.value,
            session.sessionId,
          ) ==
          key) {
        return session;
      }
    }
    for (final session in state.sessions) {
      if (_conversationKey(
            session.provider ?? Provider.claude.value,
            session.sessionId,
          ) ==
          key) {
        return session;
      }
    }
    return null;
  }

  Set<String> get unreadConversationKeys => Set.unmodifiable(
    _conversationStatuses.entries
        .where((entry) => _isConversationResultUnread(entry.value))
        .map((entry) => entry.key),
  );

  bool _isConversationResultUnread(ConversationSyncV2Status status) {
    if (status.result == 'none') return false;
    final readAt = DateTime.tryParse(
      _conversationReadWatermarks[status.key] ?? '',
    );
    final observedAt = DateTime.tryParse(status.observedAt);
    return readAt == null || observedAt == null || readAt.isBefore(observedAt);
  }

  bool _isCompleteLogicalPageBatch(ConversationSyncCacheUpdate update) {
    final pageCount = update.pageCount;
    final pageIndex = update.pageIndex;
    if (pageCount == null) return true;
    if (pageCount <= 0 || pageIndex == null) return false;
    return pageIndex == pageCount - 1;
  }

  void _onConversationSyncUpdate(ConversationSyncCacheUpdate update) {
    var reloadCache = false;
    final target = _currentCacheTarget();
    if (update.targetFingerprint != null &&
        update.targetFingerprint != target?.fingerprint) {
      return;
    }
    final canApplyCommittedDelta =
        update.targetFingerprint != null &&
        update.targetFingerprint == target?.fingerprint &&
        _loadedCacheFingerprint == update.targetFingerprint;
    switch (update.kind) {
      case ConversationSyncCacheUpdateKind.started:
        _v2PriorityReady = false;
        _catalogSnapshotChanges.add(null);
      case ConversationSyncCacheUpdateKind.reset:
        final resetsGlobalState =
            update.provider == null || update.providerSessionId == null;
        if (resetsGlobalState) {
          _v2PriorityReady = false;
          _catalogSnapshotChanges.add(null);
          reloadCache = true;
        }
      case ConversationSyncCacheUpdateKind.priorityReady:
        _v2PriorityReady = true;
        if (canApplyCommittedDelta) {
          _v2StateFingerprint = update.targetFingerprint;
          _v2CachedPriorityReady = true;
          _loadedCacheComplete = true;
        } else {
          reloadCache = true;
        }
        _catalogSnapshotChanges.add(null);
      case ConversationSyncCacheUpdateKind.catalog:
        if (!_isCompleteLogicalPageBatch(update)) return;
        if (canApplyCommittedDelta && update.codexSourceId != null) {
          _applyCommittedCatalogDelta(update);
        } else {
          reloadCache = true;
        }
      case ConversationSyncCacheUpdateKind.status:
        if (!_isCompleteLogicalPageBatch(update)) return;
        if (canApplyCommittedDelta) {
          _applyCommittedStatusDelta(update.statusChanges);
        } else {
          reloadCache = true;
        }
      case ConversationSyncCacheUpdateKind.readWatermark:
        if (canApplyCommittedDelta && update.readWatermark != null) {
          _applyCommittedReadWatermark(
            update.readWatermark!,
            replaceExisting: update.replaceExistingReadWatermark,
          );
        } else {
          reloadCache = true;
        }
      case ConversationSyncCacheUpdateKind.timeline:
        if (canApplyCommittedDelta &&
            update.provider != null &&
            update.providerSessionId != null &&
            update.lastAssistantOutputAt != null) {
          _applyCommittedAssistantOutputCheckpoint(update);
        }
      case ConversationSyncCacheUpdateKind.completed:
        break;
    }
    if (reloadCache) {
      _queueSyncCacheReload();
    }
  }

  void _applyCommittedCatalogDelta(ConversationSyncCacheUpdate update) {
    final codexSourceId = update.codexSourceId!;
    final existingByKey = {
      for (final session in _cachedSessions)
        _conversationKey(
          session.provider ?? Provider.claude.value,
          session.sessionId,
        ): session,
    };
    final replacedKeys = {for (final entry in update.catalogUpserts) entry.key};
    final destroyedKeys = {
      for (final entry in update.catalogDestroyed) entry.key,
    };
    final retained = _cachedSessions.where((session) {
      final key = _conversationKey(
        session.provider ?? Provider.claude.value,
        session.sessionId,
      );
      return !replacedKeys.contains(key) && !destroyedKeys.contains(key);
    });
    var preservedCompleteCodexSettings = 0;
    final preservedThreadTokens = <String>[];
    final upserts = update.catalogUpserts
        .map((entry) {
          final incoming = entry.toRecentSession(codexSourceId: codexSourceId);
          final key = _conversationKey(
            incoming.provider ?? Provider.claude.value,
            incoming.sessionId,
          );
          final existing = existingByKey[key];
          final session = _preserveAssistantOutputCheckpoint(
            incoming,
            existing,
          );
          if (!entry.codexSettingsSnapshotComplete &&
              existing?.codexSettingsSnapshotComplete == true &&
              session.codexSettingsSnapshotComplete) {
            preservedCompleteCodexSettings += 1;
            if (preservedThreadTokens.length < 5) {
              preservedThreadTokens.add(
                diagnosticToken(entry.provider, entry.providerSessionId),
              );
            }
          }
          return session;
        })
        .toList(growable: false);
    if (preservedCompleteCodexSettings > 0) {
      logger.info(
        '[settings_projection] event=sparse_catalog_preserved '
        'count=$preservedCompleteCodexSettings '
        'threads=${preservedThreadTokens.join(',')}',
      );
    }
    _cachedSessions = _mergeCachedSessions(retained, upserts);
    if (destroyedKeys.isNotEmpty) {
      _conversationStatuses = Map.unmodifiable(
        Map<String, ConversationSyncV2Status>.from(_conversationStatuses)
          ..removeWhere((key, _) => destroyedKeys.contains(key)),
      );
      _conversationReadWatermarks = Map.unmodifiable(
        Map<String, String>.from(_conversationReadWatermarks)
          ..removeWhere((key, _) => destroyedKeys.contains(key)),
      );
    }
    _emitCommittedCatalogProjection();
  }

  void _applyCommittedAssistantOutputCheckpoint(
    ConversationSyncCacheUpdate update,
  ) {
    final candidate = DateTime.tryParse(update.lastAssistantOutputAt!)?.toUtc();
    if (candidate == null) return;
    final key = _conversationKey(update.provider!, update.providerSessionId!);
    RecentSession advance(RecentSession session) {
      final sessionKey = _conversationKey(
        session.provider ?? Provider.claude.value,
        session.sessionId,
      );
      if (sessionKey != key) return session;
      final current = DateTime.tryParse(
        session.lastAssistantOutputAt ?? '',
      )?.toUtc();
      if (current != null && !candidate.isAfter(current)) return session;
      return session.copyWithLastAssistantOutputAt(candidate.toIso8601String());
    }

    var changed = false;
    _cachedSessions = List<RecentSession>.unmodifiable(
      _cachedSessions.map((session) {
        final next = advance(session);
        changed = changed || !identical(next, session);
        return next;
      }),
    );
    if (changed) {
      _emitCommittedCatalogProjection();
      return;
    }
    final visible = state.sessions.map(advance).toList(growable: false);
    if (visible.indexed.any(
      (entry) => !identical(entry.$2, state.sessions[entry.$1]),
    )) {
      _cachedSessions = _mergeCachedSessions(
        _cachedSessions,
        visible.where(
          (session) =>
              _conversationKey(
                session.provider ?? Provider.claude.value,
                session.sessionId,
              ) ==
              key,
        ),
      );
      emit(state.copyWith(sessions: visible));
      _catalogSnapshotChanges.add(null);
    }
  }

  void _applyCommittedStatusDelta(List<ConversationSyncV2Status> changes) {
    if (changes.isEmpty) return;
    final next = Map<String, ConversationSyncV2Status>.from(
      _conversationStatuses,
    );
    var changed = false;
    for (final incoming in changes) {
      final existing = next[incoming.key];
      if (existing != null &&
          _compareIsoTimestamps(incoming.observedAt, existing.observedAt) < 0) {
        continue;
      }
      next[incoming.key] = incoming;
      changed = true;
    }
    if (!changed) return;
    _conversationStatuses = Map.unmodifiable(next);
    _catalogSnapshotChanges.add(null);
  }

  void _applyCommittedReadWatermark(
    ConversationSyncV2ReadWatermark watermark, {
    required bool replaceExisting,
  }) {
    final existing = _conversationReadWatermarks[watermark.key];
    if (existing == watermark.readAt ||
        (!replaceExisting &&
            existing != null &&
            _compareIsoTimestamps(watermark.readAt, existing) <= 0)) {
      return;
    }
    _conversationReadWatermarks = Map.unmodifiable({
      ..._conversationReadWatermarks,
      watermark.key: watermark.readAt,
    });
    _catalogSnapshotChanges.add(null);
  }

  void _emitCommittedCatalogProjection() {
    final visibleSessions = _filterCachedSessions(_cachedSessions);
    emit(
      state.copyWith(
        sessions: visibleSessions,
        hasMore: false,
        isLoadingMore: false,
        isInitialLoading: false,
        accumulatedProjectPaths: {
          ..._authoritativeProjectHistory,
          ..._cachedSessions
              .map((session) => session.projectPath)
              .where((path) => path.isNotEmpty),
        },
        loadingProjectPaths: const {},
      ),
    );
    _catalogSnapshotChanges.add(null);
  }

  static String _conversationKey(String provider, String providerSessionId) =>
      '$provider\u0000$providerSessionId';

  void _queueSyncCacheReload() {
    if (isClosed || _catalogCache == null) return;
    if (_syncCacheReloadRunning) {
      _syncCacheReloadPending = true;
      return;
    }
    _syncCacheReloadRunning = true;
    unawaited(_drainSyncCacheReloads());
  }

  Future<void> _drainSyncCacheReloads() async {
    try {
      do {
        _syncCacheReloadPending = false;
        await _loadCatalogCacheForCurrentTarget(force: true);
      } while (_syncCacheReloadPending && !isClosed);
    } finally {
      _syncCacheReloadRunning = false;
    }
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

    var sessions = _preserveAssistantOutputCheckpoints(
      response.sessions,
      _cachedSessions,
    );
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
      _cachedSessions = _mergeCachedSessions(_cachedSessions, sessions);
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
      _cachedSessions = sessions;
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

  /// Switch project filter. Desktop project IDs stay client-side; only legacy
  /// filesystem groups are sent to the Bridge as projectPath filters.
  void selectProject(String? projectKey) {
    _filterMutationRevision++;
    final requiresServerRefresh =
        projectKey == null || !isDesktopProjectGroupingKey(projectKey);
    emit(
      state.copyWith(
        selectedProjectKey: projectKey,
        isInitialLoading: requiresServerRefresh,
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
  void loadMoreProject(String projectKey) {
    if (projectKey.isEmpty || state.loadingProjectPaths.contains(projectKey)) {
      return;
    }
    final isDesktopGroup = isDesktopProjectGroupingKey(projectKey);
    final normalizedProjectKey = isDesktopGroup
        ? projectKey
        : _normalizedProjectPath(projectKey);
    final loadedCount = state.sessions
        .where(
          (session) => isDesktopGroup
              ? session.projectGroupingKey == projectKey
              : _normalizedProjectPath(session.projectPath) ==
                    normalizedProjectKey,
        )
        .length;
    final currentLimit =
        state.projectSessionDisplayLimits[projectKey] ??
        _projectInitialSessionDisplayLimit;
    final nextLimit = currentLimit + _projectSessionDisplayPageSize;
    final shouldFetch =
        !isDesktopGroup &&
        nextLimit > loadedCount &&
        !state.exhaustedProjectPaths.contains(projectKey);
    emit(
      state.copyWith(
        projectSessionDisplayLimits: {
          ...state.projectSessionDisplayLimits,
          projectKey: nextLimit,
        },
        loadingProjectPaths: shouldFetch
            ? {...state.loadingProjectPaths, projectKey}
            : state.loadingProjectPaths,
      ),
    );
    if (!shouldFetch) return;
    _bridge.loadMoreRecentSessions(
      projectPath: projectKey,
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
    final aliases = _projectPresentationAliases(projectPath);
    final wasCollapsed = aliases.any(next.contains);
    next.removeAll(aliases);
    if (!wasCollapsed) {
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
    final aliases = _projectPresentationAliases(projectPath);
    final wasPinned = aliases.any(next.contains);
    next.removeAll(aliases);
    if (!wasPinned) next.add(projectPath);
    emit(state.copyWith(pinnedProjectPaths: next));
    await _persistStringSet(_pinnedProjectPathsKey, next);
  }

  Set<String> _projectPresentationAliases(String projectKey) {
    final aliases = <String>{projectKey};
    if (!isDesktopProjectGroupingKey(projectKey)) return aliases;
    for (final session in [..._cachedSessions, ...state.sessions]) {
      if (session.projectGroupingKey != projectKey) continue;
      if (session.projectPath.isNotEmpty) aliases.add(session.projectPath);
      if (session.effectiveProjectGroupPath.isNotEmpty) {
        aliases.add(session.effectiveProjectGroupPath);
      }
    }
    return aliases;
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
  Future<bool> refreshCatalog({bool Function()? isCurrentConnection}) async {
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
    _resetPersistentCacheProjection();
  }

  Future<void> clearPersistentCatalogCacheForTarget(
    SessionCatalogCacheTarget target,
  ) async {
    _cacheLoadGeneration++;
    await _catalogCache?.clearTarget(target);
    if (isClosed || target.fingerprint != _currentCacheTarget()?.fingerprint) {
      return;
    }
    _resetPersistentCacheProjection();
  }

  void _resetPersistentCacheProjection() {
    _loadedCacheFingerprint = null;
    _loadedCacheCatalogRevision = null;
    _loadedCacheComplete = false;
    _cachedSessions = const [];
    _v2StateFingerprint = null;
    _v2CachedPriorityReady = false;
    _v2PriorityReady = false;
    _conversationStatuses = const {};
    _conversationReadWatermarks = const {};
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

  Future<void> _loadCatalogCacheForCurrentTarget({bool force = false}) async {
    final cache = _catalogCache;
    final target = _currentCacheTarget();
    if (cache == null || target == null) return;
    if (!force && _lastCacheLoadFingerprint == target.fingerprint) return;
    _lastCacheLoadFingerprint = target.fingerprint;
    final generation = ++_cacheLoadGeneration;
    final networkSerial = _networkCatalogSerial;
    await _preferencesLoaded;
    if (isClosed || generation != _cacheLoadGeneration) return;
    try {
      final snapshot = await cache.load(target);
      final syncState = _bridge.supportsConversationSyncV2
          ? await cache.loadConversationSyncState(target)
          : const ConversationSyncCacheState.empty();
      final statuses = _bridge.supportsConversationSyncV2
          ? await cache.loadConversationStatuses(target)
          : const <ConversationSyncV2Status>[];
      final readWatermarks = _bridge.supportsConversationSyncV2
          ? await cache.loadReadWatermarks(target)
          : const <ConversationSyncV2ReadWatermark>[];
      if (isClosed ||
          generation != _cacheLoadGeneration ||
          target.fingerprint != _currentCacheTarget()?.fingerprint) {
        return;
      }
      _v2StateFingerprint = target.fingerprint;
      _v2CachedPriorityReady = syncState.priorityReady;
      _conversationStatuses = Map.unmodifiable({
        for (final status in statuses) status.key: status,
      });
      _conversationReadWatermarks = Map.unmodifiable({
        for (final watermark in readWatermarks) watermark.key: watermark.readAt,
      });
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
          _v2StateFingerprint = null;
          _v2CachedPriorityReady = false;
          _v2PriorityReady = false;
          _conversationStatuses = const {};
          _conversationReadWatermarks = const {};
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
      _loadedCacheComplete =
          snapshot.isComplete ||
          (_bridge.supportsConversationSyncV2 && _v2CachedPriorityReady);
      _cachedSessions = snapshot.sessions;
      if (networkSerial == _networkCatalogSerial &&
          (_bridge.supportsConversationSyncV2 ||
              !_bridge.hasAuthoritativeRecentSessionsForCurrentConnection)) {
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
    final selectedProjectKey = state.selectedProjectKey;
    final normalizedProjectKey =
        selectedProjectKey == null ||
            isDesktopProjectGroupingKey(selectedProjectKey)
        ? selectedProjectKey
        : _normalizedProjectPath(selectedProjectKey);
    final provider = _query.provider;
    final namedOnly = _query.namedOnly == true;
    final searchQuery = _query.searchQuery?.trim().toLowerCase();
    return sessions
        .where((session) {
          if (normalizedProjectKey != null) {
            final sessionProjectKey =
                isDesktopProjectGroupingKey(normalizedProjectKey)
                ? session.projectGroupingKey
                : _normalizedProjectPath(session.projectPath);
            if (sessionProjectKey != normalizedProjectKey) return false;
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
            session.projectGroupName,
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
    final mergedByKey = <String, RecentSession>{
      for (final session in cached)
        _conversationKey(
          session.provider ?? Provider.claude.value,
          session.sessionId,
        ): session,
    };
    for (final session in live) {
      final key = _conversationKey(
        session.provider ?? Provider.claude.value,
        session.sessionId,
      );
      mergedByKey[key] = _preserveAssistantOutputCheckpoint(
        session,
        mergedByKey[key],
      );
    }
    final merged = mergedByKey.values.toList();
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

  List<RecentSession> _preserveAssistantOutputCheckpoints(
    Iterable<RecentSession> incoming,
    Iterable<RecentSession> existing,
  ) {
    final existingByKey = <String, RecentSession>{};
    for (final session in existing) {
      final key = _conversationKey(
        session.provider ?? Provider.claude.value,
        session.sessionId,
      );
      existingByKey[key] = _preserveAssistantOutputCheckpoint(
        session,
        existingByKey[key],
      );
    }
    var preservedCompleteCodexSettings = 0;
    final preservedThreadTokens = <String>[];
    final result = incoming
        .map((session) {
          final key = _conversationKey(
            session.provider ?? Provider.claude.value,
            session.sessionId,
          );
          final previous = existingByKey[key];
          final merged = _preserveAssistantOutputCheckpoint(session, previous);
          if (!session.codexSettingsSnapshotComplete &&
              previous?.codexSettingsSnapshotComplete == true &&
              merged.codexSettingsSnapshotComplete) {
            preservedCompleteCodexSettings += 1;
            if (preservedThreadTokens.length < 5) {
              preservedThreadTokens.add(
                diagnosticToken(
                  session.provider ?? Provider.claude.value,
                  session.sessionId,
                ),
              );
            }
          }
          return merged;
        })
        .toList(growable: false);
    if (preservedCompleteCodexSettings > 0) {
      logger.info(
        '[settings_projection] event=legacy_catalog_preserved '
        'count=$preservedCompleteCodexSettings '
        'threads=${preservedThreadTokens.join(',')}',
      );
    }
    return List<RecentSession>.unmodifiable(result);
  }

  static RecentSession _preserveAssistantOutputCheckpoint(
    RecentSession incoming,
    RecentSession? existing,
  ) {
    final merged = SessionCatalogCacheRepository.mergeIncompleteCodexSettings(
      incoming: incoming,
      cached: existing,
    );
    if (existing == null) return merged;
    final existingTime = DateTime.tryParse(
      existing.lastAssistantOutputAt ?? '',
    )?.toUtc();
    if (existingTime == null) return merged;
    final incomingTime = DateTime.tryParse(
      merged.lastAssistantOutputAt ?? '',
    )?.toUtc();
    if (incomingTime != null && !existingTime.isAfter(incomingTime)) {
      return merged;
    }
    return merged.copyWithLastAssistantOutputAt(existingTime.toIso8601String());
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
        ? currentLimit < _maximumCatalogExpansionLimit
              ? _maximumCatalogExpansionLimit
              : null
        : _maximumCatalogExpansionLimit;
    if (expansionLimit == null) return;
    final requestKey = [
      _bridge.authoritativeSessionListGeneration,
      response.catalogRevision ?? -1,
      response.queryGeneration ?? -1,
      requestScope ?? '',
      expansionLimit,
      response.provider ?? '',
      response.namedOnly == true ? 1 : 0,
      response.searchQuery ?? '',
      response.projectPath ?? '',
    ].join('\n');
    if (_catalogExpansionRequestKey == requestKey) return;
    _catalogExpansionRequestKey = requestKey;
    _bridge.requestRecentSessionsCatalog(limit: expansionLimit);
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
    projectPath: isDesktopProjectGroupingKey(state.selectedProjectKey)
        ? null
        : state.selectedProjectKey,
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
    _syncCacheReloadPending = false;
    _searchDebounce?.cancel();
    await _recentSub?.cancel();
    await _projectHistorySub?.cancel();
    await _connectionSub?.cancel();
    await _sessionIdentitySub?.cancel();
    await _conversationSyncSub?.cancel();
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
