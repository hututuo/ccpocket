import 'dart:async';
import 'dart:convert';

import 'package:ccpocket/features/session_list/cache/session_catalog_cache_database.dart';
import 'package:ccpocket/features/session_list/cache/session_catalog_cache_repository.dart';
import 'package:ccpocket/features/session_list/state/session_list_cubit.dart';
import 'package:ccpocket/features/session_list/state/session_list_state.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/models/new_session_tab.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Minimal mock for SessionListCubit tests.
class MockBridgeService extends BridgeService {
  final _recentSessionsController =
      StreamController<List<RecentSession>>.broadcast();
  final _recentSessionResponsesController =
      StreamController<RecentSessionsMessage>.broadcast();
  final _projectHistoryController = StreamController<List<String>>.broadcast();
  final _sessionListController =
      StreamController<List<SessionInfo>>.broadcast();
  final sentMessages = <ClientMessage>[];
  int sessionListRequestCount = 0;
  int catalogRequestCount = 0;

  bool _hasMore = false;
  String? _projectFilter;
  RecentSessionsMessage? _lastRecentSessionsMessage;
  String? testBridgeInstanceId;
  String? testLogicalConnectionIdentity;
  String? testLastUrl;

  @override
  Stream<List<RecentSession>> get recentSessionsStream =>
      _recentSessionsController.stream;

  @override
  Stream<RecentSessionsMessage> get recentSessionResponses =>
      _recentSessionResponsesController.stream;

  @override
  Stream<List<String>> get projectHistoryStream =>
      _projectHistoryController.stream;

  @override
  Stream<List<SessionInfo>> get sessionList => _sessionListController.stream;

  @override
  bool get recentSessionsHasMore => _hasMore;
  set recentSessionsHasMore(bool v) => _hasMore = v;

  @override
  RecentSessionsMessage? get lastRecentSessionsMessage =>
      _lastRecentSessionsMessage;

  @override
  String? get bridgeInstanceId => testBridgeInstanceId;

  @override
  String? get logicalConnectionIdentity => testLogicalConnectionIdentity;

  @override
  String? get lastUrl => testLastUrl;

  @override
  String? get currentProjectFilter => _projectFilter;

  void emitSessions(List<RecentSession> sessions, {bool hasMore = false}) {
    _hasMore = hasMore;
    _lastRecentSessionsMessage = RecentSessionsMessage(
      sessions: sessions,
      hasMore: hasMore,
    );
    emitResponse(_lastRecentSessionsMessage!);
    _recentSessionsController.add(sessions);
  }

  void emitResponse(RecentSessionsMessage response) {
    _lastRecentSessionsMessage = response;
    _hasMore = response.hasMore;
    _recentSessionResponsesController.add(response);
  }

  void emitProjectSessions(
    String projectPath,
    List<RecentSession> sessions, {
    bool hasMore = false,
  }) {
    _lastRecentSessionsMessage = RecentSessionsMessage(
      sessions: sessions,
      hasMore: hasMore,
      projectPath: projectPath,
      requestScope: 'project',
      queryGeneration: 1,
    );
    emitResponse(_lastRecentSessionsMessage!);
    _recentSessionsController.add(sessions);
  }

  void emitProjectHistory(List<String> paths) {
    _projectHistoryController.add(paths);
  }

  void emitSessionIdentity() {
    _sessionListController.add(const []);
  }

  @override
  void send(ClientMessage message) {
    sentMessages.add(message);
  }

  @override
  void requestSessionList() {
    sessionListRequestCount++;
  }

  @override
  void requestRecentSessions({int? limit, int? offset, String? projectPath}) {
    sentMessages.add(
      ClientMessage.listRecentSessions(
        limit: limit,
        offset: offset,
        projectPath: projectPath,
      ),
    );
  }

  @override
  void requestRecentSessionsCatalog({int limit = 1000}) {
    catalogRequestCount++;
  }

  @override
  void requestProjectHistory() {}

  @override
  void loadMoreRecentSessions({
    int pageSize = 20,
    String? projectPath,
    int? offset,
    String requestScope = 'list',
  }) {
    sentMessages.add(
      ClientMessage.listRecentSessions(
        offset: offset ?? 0,
        limit: pageSize,
        projectPath: projectPath,
        requestScope: requestScope,
      ),
    );
  }

  @override
  void switchProjectFilter(String? projectPath, {int pageSize = 20}) {
    _projectFilter = projectPath;
  }

  @override
  void switchFilter({
    String? projectPath,
    String? provider,
    bool? namedOnly,
    String? searchQuery,
    int pageSize = 20,
  }) {
    _projectFilter = projectPath;
    sentMessages.add(
      ClientMessage.listRecentSessions(
        limit: pageSize,
        offset: 0,
        projectPath: projectPath,
        provider: provider,
        namedOnly: namedOnly,
        searchQuery: searchQuery,
      ),
    );
  }

  @override
  void dispose() {
    _recentSessionsController.close();
    _recentSessionResponsesController.close();
    _projectHistoryController.close();
    _sessionListController.close();
  }
}

class FakeSessionCatalogCacheRepository extends SessionCatalogCacheRepository {
  FakeSessionCatalogCacheRepository()
    : super(SessionCatalogCacheDatabase(databasePath: ':memory:'));

  final snapshots = <String, SessionCatalogCacheSnapshot>{};
  final writes =
      <({SessionCatalogCacheTarget target, RecentSessionsMessage response})>[];
  int clearCalls = 0;

  @override
  Future<SessionCatalogCacheSnapshot?> load(
    SessionCatalogCacheTarget target,
  ) async => snapshots[target.fingerprint];

  @override
  Future<void> upsertResponse({
    required SessionCatalogCacheTarget target,
    required RecentSessionsMessage response,
  }) async {
    writes.add((target: target, response: response));
  }

  @override
  Future<void> clearAll() async {
    clearCalls++;
    snapshots.clear();
  }

  @override
  Future<void> close() async {}
}

RecentSession _session({
  required String id,
  String projectPath = '/home/user/project-a',
}) {
  return RecentSession(
    sessionId: id,
    firstPrompt: 'test prompt',
    created: '2025-01-01T00:00:00Z',
    modified: '2025-01-01T00:00:00Z',
    gitBranch: 'main',
    projectPath: projectPath,
    isSidechain: false,
  );
}

SessionInfo _runningSession({String? providerSessionId}) {
  return SessionInfo(
    id: 'bridge-session',
    provider: Provider.claude.value,
    projectPath: '/a/proj1',
    claudeSessionId: providerSessionId,
    status: 'idle',
    createdAt: '2025-01-01T00:00:00Z',
    lastActivityAt: '2025-01-01T00:00:00Z',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SessionListCubit cubit;
  late MockBridgeService mockBridge;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockBridge = MockBridgeService();
    cubit = SessionListCubit(bridge: mockBridge);
  });

  tearDown(() {
    cubit.close();
    mockBridge.dispose();
  });

  group('SessionListCubit', () {
    test('prioritizePinned keeps stable priority buckets', () {
      final ordered = prioritizePinned(
        const ['normal-a', 'project-pinned', 'session-pinned', 'normal-b'],
        isPinned: (item) => item == 'session-pinned',
        isProjectPinned: (item) => item == 'project-pinned',
      );

      expect(ordered, const [
        'session-pinned',
        'project-pinned',
        'normal-a',
        'normal-b',
      ]);
    });

    test('session and project pins are persisted', () async {
      final session = _session(id: 'pinned-session', projectPath: '/a/proj1');

      await cubit.toggleRecentSessionPinned(session);
      await cubit.toggleProjectPinned('/a/proj1');
      await Future<void>.delayed(Duration.zero);

      expect(cubit.isRecentSessionPinned(session), isTrue);
      expect(cubit.isProjectPinned('/a/proj1'), isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getStringList('session_list_pinned_session_keys_v1'),
        contains(recentSessionPinKey(session)),
      );
      expect(
        prefs.getStringList('session_list_pinned_project_paths_v1'),
        contains('/a/proj1'),
      );
    });

    test('persisted session and project pins are restored', () async {
      final session = _session(id: 'restored-pin', projectPath: '/a/proj1');
      await cubit.close();
      mockBridge.dispose();
      SharedPreferences.setMockInitialValues({
        'session_list_pinned_session_keys_v1': [recentSessionPinKey(session)],
        'session_list_pinned_project_paths_v1': ['/a/proj1'],
      });
      mockBridge = MockBridgeService();
      cubit = SessionListCubit(bridge: mockBridge);

      await Future<void>.delayed(Duration.zero);

      expect(cubit.isRecentSessionPinned(session), isTrue);
      expect(cubit.isProjectPinned('/a/proj1'), isTrue);
    });

    test(
      'pin toggle waits for preference restoration before updating',
      () async {
        final restored = _session(id: 'restored-pin', projectPath: '/a/proj1');
        final added = _session(id: 'added-pin', projectPath: '/a/proj2');
        await cubit.close();
        mockBridge.dispose();
        SharedPreferences.setMockInitialValues({
          'session_list_pinned_session_keys_v1': [
            recentSessionPinKey(restored),
          ],
        });
        mockBridge = MockBridgeService();
        cubit = SessionListCubit(bridge: mockBridge);

        await cubit.toggleRecentSessionPinned(added);

        expect(cubit.isRecentSessionPinned(restored), isTrue);
        expect(cubit.isRecentSessionPinned(added), isTrue);
      },
    );

    test(
      'running session can only be pinned after provider ID resolves',
      () async {
        final pending = _runningSession();

        await cubit.toggleRunningSessionPinned(pending);
        expect(cubit.isRunningSessionPinned(pending), isFalse);
        expect(cubit.state.pinnedSessionKeys, isEmpty);

        final resolved = _runningSession(providerSessionId: 'provider-session');
        await cubit.toggleRunningSessionPinned(resolved);

        expect(cubit.isRunningSessionPinned(resolved), isTrue);
        expect(
          runningSessionPinKey(resolved),
          sessionPinKey(
            provider: Provider.claude.value,
            projectPath: '/a/proj1',
            sessionId: 'provider-session',
          ),
        );
      },
    );

    test('initial state is empty', () {
      expect(cubit.state.sessions, isEmpty);
      expect(cubit.state.hasMore, isFalse);
      expect(cubit.state.isLoadingMore, isFalse);
      expect(cubit.state.searchQuery, isEmpty);
      expect(cubit.state.accumulatedProjectPaths, isEmpty);
    });

    test('sessions update from stream', () async {
      mockBridge.emitSessions([_session(id: 's1'), _session(id: 's2')]);
      await Future.microtask(() {});

      expect(cubit.state.sessions, hasLength(2));
      expect(cubit.state.sessions[0].sessionId, 's1');
    });

    test('hasMore reflects bridge state', () async {
      mockBridge.emitSessions([_session(id: 's1')], hasMore: true);
      await Future.microtask(() {});

      expect(cubit.state.hasMore, isTrue);
    });

    test(
      'top-level exhaustion applies only to projects in that response',
      () async {
        mockBridge.emitSessions([
          _session(id: 's1', projectPath: '/a/proj1'),
          _session(id: 's2', projectPath: '/b/proj2'),
        ]);
        await Future.microtask(() {});

        expect(cubit.state.hasMore, isFalse);
        expect(cubit.state.exhaustedProjectPaths, {'/a/proj1', '/b/proj2'});
      },
    );

    test(
      'non-project response keeps project show more available when more pages exist',
      () async {
        mockBridge.emitSessions([
          _session(id: 's1', projectPath: '/a/proj1'),
        ], hasMore: true);
        await Future.microtask(() {});

        expect(cubit.state.hasMore, isTrue);
        expect(cubit.state.exhaustedProjectPaths, isEmpty);
      },
    );

    test('sessions update accumulates project paths', () async {
      mockBridge.emitSessions([
        _session(id: 's1', projectPath: '/a/proj1'),
        _session(id: 's2', projectPath: '/b/proj2'),
      ]);
      await Future.microtask(() {});

      expect(cubit.state.accumulatedProjectPaths, {'/a/proj1', '/b/proj2'});
    });

    test('project history merges into accumulated paths', () async {
      // First, emit sessions to set some paths
      mockBridge.emitSessions([_session(id: 's1', projectPath: '/a/proj1')]);
      await Future.microtask(() {});

      // Then, project history adds more
      mockBridge.emitProjectHistory(['/a/proj1', '/c/proj3']);
      await Future.microtask(() {});

      expect(cubit.state.accumulatedProjectPaths, {'/a/proj1', '/c/proj3'});
    });

    test('empty project history authoritatively clears stale paths', () async {
      mockBridge.emitProjectHistory(['/stale/project']);
      await Future.microtask(() {});
      expect(cubit.state.accumulatedProjectPaths, {'/stale/project'});

      mockBridge.emitProjectHistory(const []);
      await Future.microtask(() {});

      expect(cubit.state.accumulatedProjectPaths, isEmpty);
    });

    test('refresh restores persisted filters before its first query', () async {
      await cubit.close();
      mockBridge.dispose();
      SharedPreferences.setMockInitialValues({
        'session_list_provider': 'codex',
        'session_list_named_only': true,
      });
      mockBridge = MockBridgeService();
      cubit = SessionListCubit(bridge: mockBridge);

      await cubit.refresh();

      final request =
          jsonDecode(mockBridge.sentMessages.last.toJson())
              as Map<String, dynamic>;
      expect(request['provider'], 'codex');
      expect(request['namedOnly'], isTrue);
    });

    test(
      'catalog bootstrap does not recursively request session list',
      () async {
        await cubit.refreshCatalog();

        expect(mockBridge.sessionListRequestCount, 0);
        expect(mockBridge.sentMessages, hasLength(1));

        await cubit.refresh();

        expect(mockBridge.sessionListRequestCount, 1);
      },
    );

    test(
      'restores a target-scoped cached catalog before live refresh',
      () async {
        await cubit.close();
        mockBridge.dispose();
        mockBridge = MockBridgeService()
          ..testLogicalConnectionIdentity = 'machine:mac-a'
          ..testLastUrl = 'wss://mac-a.example/socket';
        final cache = FakeSessionCatalogCacheRepository();
        final target = SessionCatalogCacheTarget.fromBridge(
          logicalConnectionIdentity: mockBridge.testLogicalConnectionIdentity,
          websocketUrl: mockBridge.testLastUrl,
        );
        cache.snapshots[target.fingerprint] = SessionCatalogCacheSnapshot(
          partitionId: 'cached-partition',
          sessions: [_session(id: 'cached-session')],
          catalogRevision: 4,
          isComplete: true,
          cachedAt: DateTime.utc(2026, 7, 25),
        );

        cubit = SessionListCubit(bridge: mockBridge, catalogCache: cache);
        await pumpEventQueue();

        expect(cubit.state.sessions.single.sessionId, 'cached-session');
        expect(cubit.state.isInitialLoading, isFalse);
        expect(cubit.hasUsableCatalogForCurrentTarget, isTrue);

        mockBridge.emitSessions([_session(id: 'live-session')]);
        await pumpEventQueue();

        expect(cubit.state.sessions.single.sessionId, 'live-session');
        expect(cache.writes, hasLength(1));
      },
    );

    test(
      'never reuses a cached catalog after canonical Bridge changes',
      () async {
        await cubit.close();
        mockBridge.dispose();
        mockBridge = MockBridgeService()
          ..testBridgeInstanceId = 'bridge-a'
          ..testLastUrl = 'wss://shared.example/socket';
        final cache = FakeSessionCatalogCacheRepository();
        final oldTarget = SessionCatalogCacheTarget.fromBridge(
          bridgeInstanceId: 'bridge-a',
          websocketUrl: mockBridge.testLastUrl,
        );
        cache.snapshots[oldTarget.fingerprint] = SessionCatalogCacheSnapshot(
          partitionId: 'bridge-a',
          sessions: [_session(id: 'old-session')],
          catalogRevision: 1,
          isComplete: true,
          cachedAt: DateTime.utc(2026, 7, 25),
        );
        cubit = SessionListCubit(bridge: mockBridge, catalogCache: cache);
        await pumpEventQueue();
        expect(cubit.hasUsableCatalogForCurrentTarget, isTrue);

        mockBridge.testBridgeInstanceId = 'bridge-b';
        mockBridge.emitSessionIdentity();
        await pumpEventQueue();

        expect(cubit.hasUsableCatalogForCurrentTarget, isFalse);
        expect(cubit.state.sessions.single.sessionId, 'old-session');
      },
    );

    test(
      'clearing persistent cache closes the disconnected readiness gate',
      () async {
        await cubit.close();
        mockBridge.dispose();
        mockBridge = MockBridgeService()
          ..testBridgeInstanceId = 'bridge-a'
          ..testLastUrl = 'wss://mac-a.example/socket';
        final cache = FakeSessionCatalogCacheRepository();
        final target = SessionCatalogCacheTarget.fromBridge(
          bridgeInstanceId: mockBridge.testBridgeInstanceId,
          websocketUrl: mockBridge.testLastUrl,
        );
        cache.snapshots[target.fingerprint] = SessionCatalogCacheSnapshot(
          partitionId: 'bridge-a',
          sessions: [_session(id: 'cached-session')],
          catalogRevision: 3,
          isComplete: true,
          cachedAt: DateTime.utc(2026, 7, 25),
        );
        cubit = SessionListCubit(bridge: mockBridge, catalogCache: cache);
        await pumpEventQueue();
        expect(cubit.hasUsableCatalogForCurrentTarget, isTrue);

        await cubit.clearPersistentCatalogCache();

        expect(cache.clearCalls, 1);
        expect(cubit.state.sessions.single.sessionId, 'cached-session');
        expect(cubit.hasUsableCatalogForCurrentTarget, isFalse);
      },
    );

    test(
      'same catalog revision keeps the complete cache without a warm scan',
      () async {
        await cubit.close();
        mockBridge.dispose();
        mockBridge = MockBridgeService()
          ..testBridgeInstanceId = 'bridge-a'
          ..testLastUrl = 'wss://mac-a.example/socket';
        final cache = FakeSessionCatalogCacheRepository();
        final target = SessionCatalogCacheTarget.fromBridge(
          bridgeInstanceId: mockBridge.testBridgeInstanceId,
          websocketUrl: mockBridge.testLastUrl,
        );
        cache.snapshots[target.fingerprint] = SessionCatalogCacheSnapshot(
          partitionId: 'bridge-a',
          sessions: [
            _session(id: 'cached-a'),
            _session(id: 'cached-b'),
          ],
          catalogRevision: 9,
          isComplete: true,
          cachedAt: DateTime.utc(2026, 7, 25),
        );
        cubit = SessionListCubit(bridge: mockBridge, catalogCache: cache);
        await pumpEventQueue();

        mockBridge.emitResponse(
          RecentSessionsMessage(
            sessions: [_session(id: 'cached-a')],
            hasMore: true,
            requestScope: 'list',
            offset: 0,
            catalogRevision: 9,
          ),
        );
        await pumpEventQueue();

        expect(
          cubit.state.sessions.map((session) => session.sessionId).toSet(),
          {'cached-a', 'cached-b'},
        );
        expect(cubit.state.hasMore, isFalse);
        expect(mockBridge.catalogRequestCount, 0);
      },
    );

    test('changed catalog revision performs one bounded warm scan', () async {
      await cubit.close();
      mockBridge.dispose();
      mockBridge = MockBridgeService()
        ..testBridgeInstanceId = 'bridge-a'
        ..testLastUrl = 'wss://mac-a.example/socket';
      final cache = FakeSessionCatalogCacheRepository();
      final target = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: mockBridge.testBridgeInstanceId,
        websocketUrl: mockBridge.testLastUrl,
      );
      cache.snapshots[target.fingerprint] = SessionCatalogCacheSnapshot(
        partitionId: 'bridge-a',
        sessions: [_session(id: 'stale')],
        catalogRevision: 8,
        isComplete: true,
        cachedAt: DateTime.utc(2026, 7, 25),
      );
      cubit = SessionListCubit(bridge: mockBridge, catalogCache: cache);
      await pumpEventQueue();

      final firstPage = RecentSessionsMessage(
        sessions: [_session(id: 'live-a')],
        hasMore: true,
        requestScope: 'list',
        offset: 0,
        queryGeneration: 1,
        catalogRevision: 9,
      );
      mockBridge.emitResponse(firstPage);
      mockBridge.emitResponse(firstPage);
      await pumpEventQueue();

      expect(mockBridge.catalogRequestCount, 1);
      expect(cubit.state.sessions.single.sessionId, 'live-a');

      mockBridge.emitResponse(
        RecentSessionsMessage(
          sessions: [
            _session(id: 'live-a'),
            _session(id: 'live-b'),
          ],
          requestScope: 'catalog',
          offset: 0,
          catalogRevision: 9,
        ),
      );
      await pumpEventQueue();

      expect(cubit.state.sessions, hasLength(2));
      expect(cubit.state.hasMore, isFalse);
    });

    test(
      'selectProject triggers server re-fetch with isInitialLoading',
      () async {
        cubit.selectProject('/a/proj1');
        await Future.microtask(() {});

        expect(cubit.state.isInitialLoading, isTrue);
        expect(mockBridge.sentMessages, isNotEmpty);
      },
    );

    test('selectProject(null) triggers re-fetch', () async {
      cubit.selectProject('/a/proj1');
      await Future.microtask(() {});
      mockBridge.sentMessages.clear();
      cubit.selectProject(null);
      await Future.microtask(() {});

      expect(cubit.state.isInitialLoading, isTrue);
      expect(mockBridge.sentMessages, isNotEmpty);
    });

    test('setSearchQuery updates query', () {
      cubit.setSearchQuery('hello');

      expect(cubit.state.searchQuery, 'hello');
    });

    test('setSearchQuery triggers server request after debounce', () async {
      cubit.setSearchQuery('hello');

      // Before debounce, no server request yet (beyond initial state)
      final beforeDebounce = mockBridge.sentMessages.length;

      // Wait for debounce
      await Future.delayed(const Duration(milliseconds: 350));

      expect(mockBridge.sentMessages.length, greaterThan(beforeDebounce));
      expect(cubit.state.isInitialLoading, isTrue);
    });

    test(
      'correlated stale search result cannot overwrite current query',
      () async {
        cubit.setSearchQuery('current');
        await Future.delayed(const Duration(milliseconds: 350));

        mockBridge.emitResponse(
          RecentSessionsMessage(
            sessions: [_session(id: 'stale')],
            queryGeneration: 1,
            searchQuery: 'previous',
            requestScope: 'list',
          ),
        );
        await Future.microtask(() {});
        expect(cubit.state.sessions, isEmpty);
        expect(cubit.state.isInitialLoading, isTrue);

        mockBridge.emitResponse(
          RecentSessionsMessage(
            sessions: [_session(id: 'current')],
            queryGeneration: 2,
            searchQuery: 'current',
            requestScope: 'list',
          ),
        );
        await Future.microtask(() {});
        expect(cubit.state.sessions.single.sessionId, 'current');
        expect(cubit.state.isInitialLoading, isFalse);
      },
    );

    test('toggleProviderFilter triggers server re-fetch', () async {
      cubit.toggleProviderFilter();
      await Future.microtask(() {});

      expect(cubit.state.providerFilter, isNot(equals(null)));
      expect(cubit.state.isInitialLoading, isTrue);
      expect(mockBridge.sentMessages, isNotEmpty);
    });

    test('enabled agents constrain provider filter', () async {
      cubit.applyEnabledAgents(const [NewSessionTab.codex]);
      await Future.microtask(() {});

      expect(cubit.state.providerFilter, ProviderFilter.codex);
      expect(
        mockBridge.sentMessages.last.toJson(),
        contains('"provider":"codex"'),
      );

      mockBridge.sentMessages.clear();
      cubit.toggleProviderFilter(
        allowedFilters: providerFiltersForEnabledTabs(const [
          NewSessionTab.codex,
        ]),
      );

      expect(cubit.state.providerFilter, ProviderFilter.codex);
      expect(mockBridge.sentMessages, isEmpty);
    });

    test('toggleNamedOnly triggers server re-fetch', () async {
      cubit.toggleNamedOnly();
      await Future.microtask(() {});

      expect(cubit.state.namedOnly, isTrue);
      expect(cubit.state.isInitialLoading, isTrue);
      expect(mockBridge.sentMessages, isNotEmpty);
    });

    test('loadMore sets isLoadingMore and calls bridge', () async {
      mockBridge.emitSessions([_session(id: 's0')], hasMore: true);
      await Future.microtask(() {});
      cubit.loadMore();

      expect(cubit.state.isLoadingMore, isTrue);
      expect(mockBridge.sentMessages, isNotEmpty);
    });

    test('loadMore isLoadingMore resets when sessions arrive', () async {
      mockBridge.emitSessions([_session(id: 's0')], hasMore: true);
      await Future.microtask(() {});
      cubit.loadMore();
      expect(cubit.state.isLoadingMore, isTrue);

      // Sessions arrive, clearing loading state
      mockBridge.emitSessions([_session(id: 's1')]);
      await Future.microtask(() {});

      expect(cubit.state.isLoadingMore, isFalse);
    });

    test('loadMore ignores duplicate in-flight requests', () async {
      mockBridge.emitSessions([_session(id: 's0')], hasMore: true);
      await Future.microtask(() {});

      cubit.loadMore();
      cubit.loadMore();

      expect(mockBridge.sentMessages, hasLength(1));
    });

    test(
      'loadMoreProject requests project-scoped page from current count',
      () async {
        mockBridge.emitSessions([
          _session(id: 's1', projectPath: '/a/proj1'),
          _session(id: 's2', projectPath: '/a/proj1'),
          _session(id: 's3', projectPath: '/b/proj2'),
        ], hasMore: true);
        await Future.microtask(() {});

        cubit.loadMoreProject('/a/proj1');

        expect(cubit.state.loadingProjectPaths, contains('/a/proj1'));
        expect(cubit.state.projectSessionDisplayLimits['/a/proj1'], 25);
        final json = mockBridge.sentMessages.last.toJson();
        expect(json, contains('"projectPath":"/a/proj1"'));
        expect(json, contains('"offset":2'));
        expect(json, contains('"limit":20'));
        expect(json, contains('"requestScope":"project"'));
      },
    );

    test(
      'project pagination normalizes trailing separators for offsets',
      () async {
        mockBridge.emitSessions([
          _session(id: 's1', projectPath: '/a/proj1/'),
        ], hasMore: true);
        await Future.microtask(() {});

        cubit.loadMoreProject('/a/proj1');

        final json = mockBridge.sentMessages.last.toJson();
        expect(json, contains('"offset":1'));
      },
    );

    test(
      'loadMoreProject reveals already loaded hidden sessions without fetch',
      () async {
        mockBridge.emitSessions([
          for (var i = 0; i < 7; i++)
            _session(id: 's$i', projectPath: '/a/proj1'),
        ]);
        await Future.microtask(() {});

        cubit.loadMoreProject('/a/proj1');

        expect(cubit.state.projectSessionDisplayLimits['/a/proj1'], 25);
        expect(cubit.state.loadingProjectPaths, isNot(contains('/a/proj1')));
        expect(mockBridge.sentMessages, isEmpty);
      },
    );

    test(
      'offset-zero refresh preserves expanded project display limit',
      () async {
        final sessions = [
          for (var i = 0; i < 7; i++)
            _session(id: 's$i', projectPath: '/a/proj1'),
        ];
        mockBridge.emitSessions(sessions);
        await Future.microtask(() {});
        cubit.loadMoreProject('/a/proj1');
        expect(cubit.state.projectSessionDisplayLimits['/a/proj1'], 25);

        mockBridge.emitSessions(sessions);
        await Future.microtask(() {});

        expect(cubit.state.projectSessionDisplayLimits['/a/proj1'], 25);
      },
    );

    test('disconnect preserves expanded project display limit', () async {
      mockBridge.emitSessions([
        for (var i = 0; i < 7; i++)
          _session(id: 's$i', projectPath: '/a/proj1'),
      ]);
      await Future.microtask(() {});
      cubit.loadMoreProject('/a/proj1');

      cubit.handleDisconnect();

      expect(cubit.state.projectSessionDisplayLimits['/a/proj1'], 25);
    });

    test(
      'project-scoped response clears loading and marks exhausted',
      () async {
        cubit.loadMoreProject('/a/proj1');
        expect(cubit.state.loadingProjectPaths, contains('/a/proj1'));

        mockBridge.emitProjectSessions('/a/proj1', const [], hasMore: false);
        await Future.microtask(() {});

        expect(cubit.state.loadingProjectPaths, isNot(contains('/a/proj1')));
        expect(cubit.state.exhaustedProjectPaths, contains('/a/proj1'));
      },
    );

    test('toggleProjectCollapsed persists collapsed project path', () async {
      await cubit.toggleProjectCollapsed('/a/proj1');

      expect(cubit.state.collapsedProjectPaths, contains('/a/proj1'));
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getStringList('session_list_collapsed_project_paths'),
        contains('/a/proj1'),
      );
    });

    test('disconnect preserves user filters and cached catalog', () async {
      mockBridge.emitSessions([_session(id: 's1')]);
      await Future.microtask(() {});
      cubit.setSearchQuery('test');

      cubit.handleDisconnect();

      expect(cubit.state.searchQuery, 'test');
      expect(cubit.state.sessions.single.sessionId, 's1');
      expect(
        cubit.state.accumulatedProjectPaths,
        contains('/home/user/project-a'),
      );
      expect(cubit.state.isInitialLoading, isFalse);
    });

    test('initial state has isInitialLoading true', () {
      expect(cubit.state.isInitialLoading, isTrue);
    });

    test('isInitialLoading becomes false when sessions arrive', () async {
      expect(cubit.state.isInitialLoading, isTrue);

      mockBridge.emitSessions([_session(id: 's1')]);
      await Future.microtask(() {});

      expect(cubit.state.isInitialLoading, isFalse);
    });

    test('isInitialLoading becomes false even with empty sessions', () async {
      expect(cubit.state.isInitialLoading, isTrue);

      mockBridge.emitSessions([]);
      await Future.microtask(() {});

      expect(cubit.state.isInitialLoading, isFalse);
    });

    test('disconnect keeps a usable loaded catalog visible', () async {
      mockBridge.emitSessions([_session(id: 's1')]);
      await Future.microtask(() {});
      expect(cubit.state.isInitialLoading, isFalse);

      cubit.handleDisconnect();

      expect(cubit.state.isInitialLoading, isFalse);
      expect(cubit.state.sessions.single.sessionId, 's1');
    });

    test('disconnect without a catalog retains the initial skeleton', () {
      cubit.handleDisconnect();

      expect(cubit.state.sessions, isEmpty);
      expect(cubit.state.isInitialLoading, isTrue);
    });
  });
}
