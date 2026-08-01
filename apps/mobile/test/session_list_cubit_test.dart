import 'dart:async';
import 'dart:convert';

import 'package:ccpocket/features/conversation_content_sync/conversation_content_sync_service.dart';
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
  final catalogRequestLimits = <int>[];
  bool testHasAuthoritativeRecentSessions = false;
  bool testSupportsConversationSyncV2 = false;
  bool throwOnSwitchFilter = false;
  void Function()? onRequestProjectHistory;

  bool _hasMore = false;
  String? _projectFilter;
  RecentSessionsMessage? _lastRecentSessionsMessage;
  String? testBridgeInstanceId;
  String? testCodexSourceId;
  String? testCacheBridgeInstanceIdHint;
  String? testCacheCodexSourceIdHint;
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
  bool get hasAuthoritativeRecentSessionsForCurrentConnection =>
      testHasAuthoritativeRecentSessions;

  @override
  bool get supportsConversationSyncV2 => testSupportsConversationSyncV2;

  @override
  String? get bridgeInstanceId => testBridgeInstanceId;

  @override
  String? get codexSourceId => testCodexSourceId;

  @override
  String? get cacheBridgeInstanceIdHint =>
      testBridgeInstanceId ?? testCacheBridgeInstanceIdHint;

  @override
  String? get cacheCodexSourceIdHint => testBridgeInstanceId != null
      ? testCodexSourceId
      : testCacheCodexSourceIdHint;

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
    catalogRequestLimits.add(limit);
  }

  @override
  void requestProjectHistory() {
    onRequestProjectHistory?.call();
  }

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
    if (throwOnSwitchFilter) {
      throw StateError('catalog dispatch failed');
    }
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
  final syncStates = <String, ConversationSyncCacheState>{};
  final statuses = <String, List<ConversationSyncV2Status>>{};
  final watermarks = <String, List<ConversationSyncV2ReadWatermark>>{};
  final writes =
      <({SessionCatalogCacheTarget target, RecentSessionsMessage response})>[];
  int clearCalls = 0;
  int loadCalls = 0;

  @override
  Future<SessionCatalogCacheSnapshot?> load(
    SessionCatalogCacheTarget target,
  ) async {
    loadCalls++;
    return snapshots[target.fingerprint];
  }

  @override
  Future<ConversationSyncCacheState> loadConversationSyncState(
    SessionCatalogCacheTarget target,
  ) async =>
      syncStates[target.fingerprint] ??
      const ConversationSyncCacheState.empty();

  @override
  Future<List<ConversationSyncV2Status>> loadConversationStatuses(
    SessionCatalogCacheTarget target, {
    int limit = 10_000,
  }) async => statuses[target.fingerprint] ?? const [];

  @override
  Future<List<ConversationSyncV2ReadWatermark>> loadReadWatermarks(
    SessionCatalogCacheTarget target, {
    int limit = 512,
  }) async => watermarks[target.fingerprint] ?? const [];

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
    syncStates.clear();
    statuses.clear();
    watermarks.clear();
  }

  @override
  Future<void> close() async {}
}

class FakeConversationContentSyncService
    extends ConversationContentSyncService {
  FakeConversationContentSyncService({
    required super.bridge,
    required super.cache,
  });

  final _updates = StreamController<ConversationSyncCacheUpdate>.broadcast();

  @override
  Stream<ConversationSyncCacheUpdate> get syncUpdates => _updates.stream;

  void emit(ConversationSyncCacheUpdate update) => _updates.add(update);

  @override
  Future<void> dispose() async {
    await _updates.close();
    await super.dispose();
  }
}

RecentSession _session({
  required String id,
  String projectPath = '/home/user/project-a',
  String modified = '2025-01-01T00:00:00Z',
  String? provider,
  String? codexSourceId,
}) {
  return RecentSession(
    sessionId: id,
    provider: provider,
    codexSourceId: codexSourceId,
    firstPrompt: 'test prompt',
    created: '2025-01-01T00:00:00Z',
    modified: modified,
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
        expect(await cubit.refreshCatalog(), isTrue);

        expect(mockBridge.sessionListRequestCount, 0);
        expect(mockBridge.sentMessages, hasLength(1));

        await cubit.refresh();

        expect(mockBridge.sessionListRequestCount, 1);
      },
    );

    test('catalog bootstrap reports a dispatch failure', () async {
      mockBridge.throwOnSwitchFilter = true;

      expect(await cubit.refreshCatalog(), isFalse);
      expect(mockBridge.sentMessages, isEmpty);
    });

    test(
      'catalog bootstrap rechecks its connection fence before send',
      () async {
        var isCurrentConnection = true;
        mockBridge.onRequestProjectHistory = () {
          isCurrentConnection = false;
        };

        expect(
          await cubit.refreshCatalog(
            isCurrentConnection: () => isCurrentConnection,
          ),
          isFalse,
        );
        expect(mockBridge.sentMessages, isEmpty);
      },
    );

    test(
      'network catalog readiness requires the current top-level query',
      () async {
        mockBridge
          ..testHasAuthoritativeRecentSessions = true
          ..testLastUrl = 'wss://mac-a.example/socket';
        mockBridge.emitResponse(
          RecentSessionsMessage(
            sessions: [_session(id: 'project-page')],
            hasMore: false,
            projectPath: '/another/project',
            requestScope: 'project',
            queryGeneration: 1,
          ),
        );
        await Future.microtask(() {});

        expect(cubit.hasUsableCatalogForCurrentTarget, isFalse);

        mockBridge.emitResponse(
          RecentSessionsMessage(
            sessions: [_session(id: 'top-level')],
            hasMore: false,
            requestScope: 'list',
            queryGeneration: 1,
          ),
        );
        await Future.microtask(() {});

        expect(cubit.hasUsableCatalogForCurrentTarget, isTrue);

        cubit.handleDisconnect();
        expect(cubit.hasUsableCatalogForCurrentTarget, isFalse);
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

    test('v2 readiness waits for the committed priority checkpoint', () async {
      await cubit.close();
      mockBridge.dispose();
      mockBridge = MockBridgeService()
        ..testSupportsConversationSyncV2 = true
        ..testCacheBridgeInstanceIdHint = 'bridge-v2'
        ..testCacheCodexSourceIdHint = 'source-v2'
        ..testLogicalConnectionIdentity = 'machine:mac-v2'
        ..testLastUrl = 'wss://mac-v2.example/socket';
      final cache = FakeSessionCatalogCacheRepository();
      final target = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: 'bridge-v2',
        codexSourceId: 'source-v2',
        logicalConnectionIdentity: 'machine:mac-v2',
        websocketUrl: 'wss://mac-v2.example/socket',
      );
      cache.snapshots[target.fingerprint] = SessionCatalogCacheSnapshot(
        partitionId: 'bridge-v2-source-v2',
        sessions: [_session(id: 'cached-v2')],
        catalogRevision: null,
        isComplete: false,
        cachedAt: DateTime.utc(2026, 7, 30),
      );
      cache.syncStates[target.fingerprint] = ConversationSyncCacheState(
        catalogState: 'catalog-1',
        statusState: 'status-1',
        priorityReady: false,
        updatedAt: DateTime.utc(2026, 7, 30),
      );

      cubit = SessionListCubit(bridge: mockBridge, catalogCache: cache);
      await pumpEventQueue();
      expect(cubit.state.sessions.single.sessionId, 'cached-v2');
      expect(cubit.hasUsableCatalogForCurrentTarget, isFalse);

      await cubit.close();
      cache.syncStates[target.fingerprint] = ConversationSyncCacheState(
        catalogState: 'catalog-1',
        statusState: 'status-1',
        priorityReady: true,
        updatedAt: DateTime.utc(2026, 7, 30, 0, 1),
      );
      cubit = SessionListCubit(bridge: mockBridge, catalogCache: cache);
      await pumpEventQueue();
      expect(cubit.hasUsableCatalogForCurrentTarget, isFalse);
      expect(cubit.hasCachedCatalogForCurrentTarget, isTrue);
    });

    test(
      'v2 body updates do not reload the catalog or revoke readiness',
      () async {
        await cubit.close();
        mockBridge.dispose();
        mockBridge = MockBridgeService()
          ..testSupportsConversationSyncV2 = true
          ..testCacheBridgeInstanceIdHint = 'bridge-v2'
          ..testCacheCodexSourceIdHint = 'source-v2'
          ..testLogicalConnectionIdentity = 'machine:mac-v2'
          ..testLastUrl = 'wss://mac-v2.example/socket';
        final cache = FakeSessionCatalogCacheRepository();
        final target = SessionCatalogCacheTarget.fromBridge(
          bridgeInstanceId: 'bridge-v2',
          codexSourceId: 'source-v2',
          logicalConnectionIdentity: 'machine:mac-v2',
          websocketUrl: 'wss://mac-v2.example/socket',
        );
        cache.snapshots[target.fingerprint] = SessionCatalogCacheSnapshot(
          partitionId: 'bridge-v2-source-v2',
          sessions: [_session(id: 'cached-v2')],
          catalogRevision: null,
          isComplete: false,
          cachedAt: DateTime.utc(2026, 7, 30),
        );
        cache.syncStates[target.fingerprint] = ConversationSyncCacheState(
          catalogState: 'catalog-1',
          statusState: 'status-1',
          priorityReady: true,
          updatedAt: DateTime.utc(2026, 7, 30),
        );
        final sync = FakeConversationContentSyncService(
          bridge: BridgeServiceConversationContentSyncGateway(mockBridge),
          cache: cache,
        );
        addTearDown(sync.dispose);

        cubit = SessionListCubit(
          bridge: mockBridge,
          catalogCache: cache,
          conversationSync: sync,
        );
        await pumpEventQueue();
        sync.emit(
          const ConversationSyncCacheUpdate(
            kind: ConversationSyncCacheUpdateKind.priorityReady,
          ),
        );
        await pumpEventQueue();
        expect(cubit.hasUsableCatalogForCurrentTarget, isTrue);
        final loadsAfterPriority = cache.loadCalls;

        sync.emit(
          const ConversationSyncCacheUpdate(
            kind: ConversationSyncCacheUpdateKind.started,
            targetFingerprint: 'another-data-source',
          ),
        );
        await pumpEventQueue();
        expect(cubit.hasUsableCatalogForCurrentTarget, isTrue);

        sync
          ..emit(
            const ConversationSyncCacheUpdate(
              kind: ConversationSyncCacheUpdateKind.timeline,
              provider: 'codex',
              providerSessionId: 'cached-v2',
              revision: 'timeline-2',
            ),
          )
          ..emit(
            const ConversationSyncCacheUpdate(
              kind: ConversationSyncCacheUpdateKind.completed,
            ),
          )
          ..emit(
            const ConversationSyncCacheUpdate(
              kind: ConversationSyncCacheUpdateKind.reset,
              provider: 'codex',
              providerSessionId: 'cached-v2',
            ),
          );
        await pumpEventQueue();

        expect(cache.loadCalls, loadsAfterPriority);
        expect(cubit.hasUsableCatalogForCurrentTarget, isTrue);

        sync.emit(
          const ConversationSyncCacheUpdate(
            kind: ConversationSyncCacheUpdateKind.reset,
          ),
        );
        await pumpEventQueue();

        expect(cache.loadCalls, loadsAfterPriority + 1);
        expect(cubit.hasUsableCatalogForCurrentTarget, isFalse);
      },
    );

    test(
      'v2 committed deltas update the in-memory projection without full cache reloads',
      () async {
        await cubit.close();
        mockBridge.dispose();
        mockBridge = MockBridgeService()
          ..testSupportsConversationSyncV2 = true
          ..testCacheBridgeInstanceIdHint = 'bridge-v2'
          ..testCacheCodexSourceIdHint = 'source-v2'
          ..testLogicalConnectionIdentity = 'machine:mac-v2'
          ..testLastUrl = 'wss://mac-v2.example/socket';
        final cache = FakeSessionCatalogCacheRepository();
        final target = SessionCatalogCacheTarget.fromBridge(
          bridgeInstanceId: 'bridge-v2',
          codexSourceId: 'source-v2',
          logicalConnectionIdentity: 'machine:mac-v2',
          websocketUrl: 'wss://mac-v2.example/socket',
        );
        cache.snapshots[target.fingerprint] = SessionCatalogCacheSnapshot(
          partitionId: 'bridge-v2-source-v2',
          sessions: [
            _session(
              id: 'thread-old',
              provider: 'codex',
              codexSourceId: 'source-v2',
            ),
            _session(
              id: 'thread-destroyed',
              provider: 'codex',
              codexSourceId: 'source-v2',
            ),
          ],
          catalogRevision: null,
          isComplete: false,
          cachedAt: DateTime.utc(2026, 7, 30),
        );
        cache.syncStates[target.fingerprint] = ConversationSyncCacheState(
          catalogState: 'catalog-1',
          statusState: 'status-1',
          priorityReady: true,
          updatedAt: DateTime.utc(2026, 7, 30),
        );
        final sync = FakeConversationContentSyncService(
          bridge: BridgeServiceConversationContentSyncGateway(mockBridge),
          cache: cache,
        );
        addTearDown(sync.dispose);
        cubit = SessionListCubit(
          bridge: mockBridge,
          catalogCache: cache,
          conversationSync: sync,
        );
        await pumpEventQueue();
        final loadsBeforeDeltas = cache.loadCalls;

        sync
          ..emit(
            ConversationSyncCacheUpdate(
              kind: ConversationSyncCacheUpdateKind.catalog,
              targetFingerprint: target.fingerprint,
              codexSourceId: 'source-v2',
              pageIndex: 0,
              pageCount: 2,
              catalogUpserts: const [
                ConversationSyncV2CatalogEntry(
                  provider: 'codex',
                  providerSessionId: 'thread-partial',
                  revision: 'revision-partial',
                  projectPath: '/home/user/project-partial',
                  createdAt: '2026-07-30T00:00:00.000Z',
                  modifiedAt: '2026-07-30T00:10:00.000Z',
                  recencyAt: '2026-07-30T00:10:00.000Z',
                  availability: 'durable',
                  name: 'Must not be visible yet',
                ),
              ],
            ),
          )
          ..emit(
            ConversationSyncCacheUpdate(
              kind: ConversationSyncCacheUpdateKind.status,
              targetFingerprint: target.fingerprint,
              pageIndex: 0,
              pageCount: 2,
              statusChanges: const [
                ConversationSyncV2Status(
                  provider: 'codex',
                  providerSessionId: 'thread-old',
                  activity: 'working',
                  attention: 'none',
                  result: 'none',
                  runtimeAttachment: 'loaded',
                  source: 'appServer',
                  confidence: 'authoritative',
                  observedAt: '2026-07-30T00:09:00.000Z',
                ),
              ],
            ),
          );
        await pumpEventQueue();

        expect(cache.loadCalls, loadsBeforeDeltas);
        expect(
          cubit.state.sessions.map((session) => session.sessionId),
          isNot(contains('thread-partial')),
        );
        expect(
          cubit.conversationStatusFor(
            cubit.state.sessions.firstWhere(
              (session) => session.sessionId == 'thread-old',
            ),
          ),
          isNull,
        );

        sync
          ..emit(
            ConversationSyncCacheUpdate(
              kind: ConversationSyncCacheUpdateKind.catalog,
              targetFingerprint: target.fingerprint,
              codexSourceId: 'source-v2',
              catalogUpserts: const [
                ConversationSyncV2CatalogEntry(
                  provider: 'codex',
                  providerSessionId: 'thread-old',
                  revision: 'revision-2',
                  projectPath: '/home/user/project-b',
                  createdAt: '2026-07-30T00:00:00.000Z',
                  modifiedAt: '2026-07-30T00:03:00.000Z',
                  recencyAt: '2026-07-30T00:03:00.000Z',
                  availability: 'durable',
                  name: 'Updated thread',
                ),
                ConversationSyncV2CatalogEntry(
                  provider: 'codex',
                  providerSessionId: 'thread-new',
                  revision: 'revision-1',
                  projectPath: '/home/user/project-c',
                  createdAt: '2026-07-30T00:01:00.000Z',
                  modifiedAt: '2026-07-30T00:04:00.000Z',
                  recencyAt: '2026-07-30T00:04:00.000Z',
                  availability: 'durable',
                  name: 'New thread',
                ),
              ],
              catalogDestroyed: const [
                ConversationSyncV2Target(
                  provider: 'codex',
                  providerSessionId: 'thread-destroyed',
                ),
              ],
            ),
          )
          ..emit(
            ConversationSyncCacheUpdate(
              kind: ConversationSyncCacheUpdateKind.status,
              targetFingerprint: target.fingerprint,
              statusChanges: const [
                ConversationSyncV2Status(
                  provider: 'codex',
                  providerSessionId: 'thread-old',
                  activity: 'working',
                  attention: 'none',
                  result: 'completed',
                  runtimeAttachment: 'loaded',
                  source: 'appServer',
                  confidence: 'authoritative',
                  observedAt: '2026-07-30T00:05:00.000Z',
                ),
              ],
            ),
          )
          ..emit(
            ConversationSyncCacheUpdate(
              kind: ConversationSyncCacheUpdateKind.status,
              targetFingerprint: target.fingerprint,
              statusChanges: const [
                ConversationSyncV2Status(
                  provider: 'codex',
                  providerSessionId: 'thread-old',
                  activity: 'idle',
                  attention: 'none',
                  result: 'none',
                  runtimeAttachment: 'notLoaded',
                  source: 'appServer',
                  confidence: 'authoritative',
                  observedAt: '2026-07-30T00:04:00.000Z',
                ),
              ],
            ),
          );
        await pumpEventQueue();

        expect(cache.loadCalls, loadsBeforeDeltas);
        expect(cubit.state.sessions.map((session) => session.sessionId), [
          'thread-new',
          'thread-old',
        ]);
        expect(cubit.state.sessions.last.name, 'Updated thread');
        expect(
          cubit.conversationStatusFor(cubit.state.sessions.last)?.activity,
          'working',
        );
        expect(cubit.unreadConversationKeys, contains('codex\u0000thread-old'));

        sync.emit(
          ConversationSyncCacheUpdate(
            kind: ConversationSyncCacheUpdateKind.timeline,
            targetFingerprint: target.fingerprint,
            provider: 'codex',
            providerSessionId: 'thread-old',
            revision: 'timeline-2',
            lastAssistantOutputAt: '2026-07-30T00:05:30.000Z',
          ),
        );
        await pumpEventQueue();

        expect(cache.loadCalls, loadsBeforeDeltas);
        expect(
          cubit.state.sessions
              .singleWhere((session) => session.sessionId == 'thread-old')
              .lastAssistantOutputAt,
          '2026-07-30T00:05:30.000Z',
        );

        sync.emit(
          ConversationSyncCacheUpdate(
            kind: ConversationSyncCacheUpdateKind.catalog,
            targetFingerprint: target.fingerprint,
            codexSourceId: 'source-v2',
            catalogUpserts: const [
              ConversationSyncV2CatalogEntry(
                provider: 'codex',
                providerSessionId: 'thread-old',
                revision: 'revision-3',
                projectPath: '/home/user/project-b',
                createdAt: '2026-07-30T00:00:00.000Z',
                modifiedAt: '2026-07-30T00:07:00.000Z',
                recencyAt: '2026-07-30T00:07:00.000Z',
                availability: 'durable',
                name: 'Updated again',
              ),
            ],
          ),
        );
        await pumpEventQueue();

        expect(cache.loadCalls, loadsBeforeDeltas);
        expect(
          cubit.state.sessions
              .singleWhere((session) => session.sessionId == 'thread-old')
              .lastAssistantOutputAt,
          '2026-07-30T00:05:30.000Z',
        );

        sync.emit(
          ConversationSyncCacheUpdate(
            kind: ConversationSyncCacheUpdateKind.readWatermark,
            targetFingerprint: target.fingerprint,
            readWatermark: const ConversationSyncV2ReadWatermark(
              provider: 'codex',
              providerSessionId: 'thread-old',
              readAt: '2026-07-30T00:06:00.000Z',
            ),
          ),
        );
        await pumpEventQueue();

        expect(cache.loadCalls, loadsBeforeDeltas);
        expect(
          cubit.unreadConversationKeys,
          isNot(contains('codex\u0000thread-old')),
        );

        sync.emit(
          ConversationSyncCacheUpdate(
            kind: ConversationSyncCacheUpdateKind.status,
            targetFingerprint: target.fingerprint,
            statusChanges: const [
              ConversationSyncV2Status(
                provider: 'codex',
                providerSessionId: 'thread-old',
                activity: 'idle',
                attention: 'none',
                result: 'completed',
                runtimeAttachment: 'notLoaded',
                source: 'appServer',
                confidence: 'authoritative',
                observedAt: '2026-07-30T00:07:00.000Z',
              ),
            ],
          ),
        );
        await pumpEventQueue();
        expect(cubit.unreadConversationKeys, contains('codex\u0000thread-old'));

        sync.emit(
          ConversationSyncCacheUpdate(
            kind: ConversationSyncCacheUpdateKind.readWatermark,
            targetFingerprint: target.fingerprint,
            readWatermark: const ConversationSyncV2ReadWatermark(
              provider: 'codex',
              providerSessionId: 'thread-old',
              readAt: '2026-07-30T00:08:00.000Z',
            ),
          ),
        );
        await pumpEventQueue();
        expect(
          cubit.unreadConversationKeys,
          isNot(contains('codex\u0000thread-old')),
        );

        sync.emit(
          ConversationSyncCacheUpdate(
            kind: ConversationSyncCacheUpdateKind.readWatermark,
            targetFingerprint: target.fingerprint,
            readWatermark: const ConversationSyncV2ReadWatermark(
              provider: 'codex',
              providerSessionId: 'thread-old',
              readAt: '2099-07-30T00:00:00.000Z',
            ),
          ),
        );
        sync.emit(
          ConversationSyncCacheUpdate(
            kind: ConversationSyncCacheUpdateKind.readWatermark,
            targetFingerprint: target.fingerprint,
            readWatermark: const ConversationSyncV2ReadWatermark(
              provider: 'codex',
              providerSessionId: 'thread-old',
              readAt: '2026-07-30T00:07:00.000Z',
            ),
            replaceExistingReadWatermark: true,
          ),
        );
        sync.emit(
          ConversationSyncCacheUpdate(
            kind: ConversationSyncCacheUpdateKind.status,
            targetFingerprint: target.fingerprint,
            statusChanges: const [
              ConversationSyncV2Status(
                provider: 'codex',
                providerSessionId: 'thread-old',
                activity: 'idle',
                attention: 'none',
                result: 'completed',
                runtimeAttachment: 'notLoaded',
                source: 'appServer',
                confidence: 'authoritative',
                observedAt: '2027-07-30T00:00:00.000Z',
              ),
            ],
          ),
        );
        await pumpEventQueue();
        expect(cubit.unreadConversationKeys, contains('codex\u0000thread-old'));

        mockBridge.emitResponse(
          RecentSessionsMessage(
            sessions: [
              _session(
                id: 'thread-old',
                provider: 'codex',
                codexSourceId: 'source-v2',
                projectPath: '/home/user/project-moved',
              ),
            ],
            requestScope: 'catalog',
            offset: 0,
            hasMore: false,
            catalogRevision: 77,
          ),
        );
        await pumpEventQueue();
        expect(
          cubit.state.sessions.single.lastAssistantOutputAt,
          '2026-07-30T00:05:30.000Z',
        );
        expect(
          cubit.state.sessions.single.projectPath,
          '/home/user/project-moved',
        );

        mockBridge.emitResponse(
          RecentSessionsMessage(
            sessions: [
              _session(
                id: 'thread-old',
                provider: 'codex',
                codexSourceId: 'source-v2',
                projectPath: '/home/user/project-moved-again',
              ),
            ],
            requestScope: 'list',
            offset: 0,
            hasMore: false,
            catalogRevision: 77,
          ),
        );
        await pumpEventQueue();
        expect(cubit.state.sessions, hasLength(1));
        expect(
          cubit.state.sessions.single.lastAssistantOutputAt,
          '2026-07-30T00:05:30.000Z',
        );
        expect(
          cubit.state.sessions.single.projectPath,
          '/home/user/project-moved-again',
        );
      },
    );

    test(
      'saved Bridge and Codex source hints prewarm canonical cache before identity frame',
      () async {
        await cubit.close();
        mockBridge.dispose();
        mockBridge = MockBridgeService()
          ..testCacheBridgeInstanceIdHint = 'bridge-a'
          ..testCacheCodexSourceIdHint = 'codex-home-a'
          ..testLogicalConnectionIdentity = 'machine:route-b'
          ..testLastUrl = 'wss://route-b.example/socket';
        final cache = FakeSessionCatalogCacheRepository();
        final canonicalTarget = SessionCatalogCacheTarget.fromBridge(
          bridgeInstanceId: 'bridge-a',
          codexSourceId: 'codex-home-a',
          logicalConnectionIdentity: 'machine:route-a',
          websocketUrl: 'wss://route-a.example/socket',
        );
        cache.snapshots[canonicalTarget.fingerprint] =
            SessionCatalogCacheSnapshot(
              partitionId: 'bridge-a-home-a',
              sessions: [_session(id: 'canonical-cached-session')],
              catalogRevision: 7,
              isComplete: true,
              cachedAt: DateTime.utc(2026, 7, 28),
            );

        cubit = SessionListCubit(bridge: mockBridge, catalogCache: cache);
        await pumpEventQueue();

        expect(cache.loadCalls, 1);
        expect(
          cubit.state.sessions.single.sessionId,
          'canonical-cached-session',
        );
        expect(cubit.state.isInitialLoading, isFalse);
        expect(cubit.hasUsableCatalogForCurrentTarget, isTrue);
        expect(mockBridge.testBridgeInstanceId, isNull);
      },
    );

    test(
      'authoritative identity mismatch switches to the matching canonical partition',
      () async {
        await cubit.close();
        mockBridge.dispose();
        mockBridge = MockBridgeService()
          ..testCacheBridgeInstanceIdHint = 'bridge-a'
          ..testCacheCodexSourceIdHint = 'codex-home-a'
          ..testLogicalConnectionIdentity = 'machine:shared-route'
          ..testLastUrl = 'wss://shared.example/socket';
        final cache = FakeSessionCatalogCacheRepository();
        final hintedTarget = SessionCatalogCacheTarget.fromBridge(
          bridgeInstanceId: 'bridge-a',
          codexSourceId: 'codex-home-a',
          logicalConnectionIdentity: mockBridge.testLogicalConnectionIdentity,
          websocketUrl: mockBridge.testLastUrl,
        );
        final authoritativeTarget = SessionCatalogCacheTarget.fromBridge(
          bridgeInstanceId: 'bridge-b',
          codexSourceId: 'codex-home-b',
          logicalConnectionIdentity: mockBridge.testLogicalConnectionIdentity,
          websocketUrl: mockBridge.testLastUrl,
        );
        cache.snapshots[hintedTarget.fingerprint] = SessionCatalogCacheSnapshot(
          partitionId: 'bridge-a-home-a',
          sessions: [_session(id: 'hinted-bridge-session')],
          catalogRevision: 1,
          isComplete: true,
          cachedAt: DateTime.utc(2026, 7, 28),
        );
        cache.snapshots[authoritativeTarget.fingerprint] =
            SessionCatalogCacheSnapshot(
              partitionId: 'bridge-b-home-b',
              sessions: [_session(id: 'authoritative-bridge-session')],
              catalogRevision: 2,
              isComplete: true,
              cachedAt: DateTime.utc(2026, 7, 28),
            );
        cubit = SessionListCubit(bridge: mockBridge, catalogCache: cache);
        await pumpEventQueue();
        expect(cubit.state.sessions.single.sessionId, 'hinted-bridge-session');

        mockBridge
          ..testBridgeInstanceId = 'bridge-b'
          ..testCodexSourceId = 'codex-home-b';
        mockBridge.emitSessionIdentity();
        await pumpEventQueue();

        expect(cache.loadCalls, 2);
        expect(
          cubit.state.sessions.single.sessionId,
          'authoritative-bridge-session',
        );
        expect(cubit.hasUsableCatalogForCurrentTarget, isTrue);
      },
    );

    test(
      'legacy Bridge without stable identity keeps route-scoped cache partitions',
      () async {
        await cubit.close();
        mockBridge.dispose();
        mockBridge = MockBridgeService()
          ..testLogicalConnectionIdentity = 'machine:legacy-route-a'
          ..testLastUrl = 'ws://10.0.0.10:8765';
        final cache = FakeSessionCatalogCacheRepository();
        final routeATarget = SessionCatalogCacheTarget.fromBridge(
          logicalConnectionIdentity: 'machine:legacy-route-a',
          websocketUrl: 'ws://10.0.0.10:8765',
        );
        final routeBTarget = SessionCatalogCacheTarget.fromBridge(
          logicalConnectionIdentity: 'machine:legacy-route-b',
          websocketUrl: 'ws://100.64.0.10:8765',
        );
        cache.snapshots[routeATarget.fingerprint] = SessionCatalogCacheSnapshot(
          partitionId: 'legacy-route-a',
          sessions: [_session(id: 'legacy-route-a-session')],
          catalogRevision: null,
          isComplete: true,
          cachedAt: DateTime.utc(2026, 7, 28),
        );
        cache.snapshots[routeBTarget.fingerprint] = SessionCatalogCacheSnapshot(
          partitionId: 'legacy-route-b',
          sessions: [_session(id: 'legacy-route-b-session')],
          catalogRevision: null,
          isComplete: true,
          cachedAt: DateTime.utc(2026, 7, 28),
        );
        cubit = SessionListCubit(bridge: mockBridge, catalogCache: cache);
        await pumpEventQueue();
        expect(cubit.state.sessions.single.sessionId, 'legacy-route-a-session');

        mockBridge
          ..testLogicalConnectionIdentity = 'machine:legacy-route-b'
          ..testLastUrl = 'ws://100.64.0.10:8765';
        mockBridge.emitSessionIdentity();
        await pumpEventQueue();

        expect(cache.loadCalls, 2);
        expect(cubit.state.sessions.single.sessionId, 'legacy-route-b-session');
        expect(cubit.hasUsableCatalogForCurrentTarget, isTrue);
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
      'never reuses a cached catalog after selected Codex Home changes',
      () async {
        await cubit.close();
        mockBridge.dispose();
        mockBridge = MockBridgeService()
          ..testBridgeInstanceId = 'bridge-a'
          ..testCodexSourceId = 'codex-home-a'
          ..testLastUrl = 'wss://shared.example/socket';
        final cache = FakeSessionCatalogCacheRepository();
        final oldTarget = SessionCatalogCacheTarget.fromBridge(
          bridgeInstanceId: 'bridge-a',
          codexSourceId: 'codex-home-a',
          websocketUrl: mockBridge.testLastUrl,
        );
        cache.snapshots[oldTarget.fingerprint] = SessionCatalogCacheSnapshot(
          partitionId: 'bridge-a-home-a',
          sessions: [_session(id: 'old-home-session')],
          catalogRevision: 1,
          isComplete: true,
          cachedAt: DateTime.utc(2026, 7, 25),
        );
        cubit = SessionListCubit(bridge: mockBridge, catalogCache: cache);
        await pumpEventQueue();
        expect(cubit.hasUsableCatalogForCurrentTarget, isTrue);

        mockBridge.testCodexSourceId = 'codex-home-b';
        mockBridge.emitSessionIdentity();
        await pumpEventQueue();

        expect(cache.loadCalls, 2);
        expect(cubit.hasUsableCatalogForCurrentTarget, isFalse);
        expect(cubit.state.sessions, isEmpty);
        expect(cubit.state.isInitialLoading, isTrue);
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

    test(
      'complete cache merge sorts mixed ISO offsets by actual time',
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
            _session(id: 'actually-newer', modified: '2026-07-25T00:30:00Z'),
            _session(
              id: 'actually-older',
              modified: '2026-07-25T08:15:00+08:00',
            ),
          ],
          catalogRevision: 9,
          isComplete: true,
          cachedAt: DateTime.utc(2026, 7, 25),
        );
        cubit = SessionListCubit(bridge: mockBridge, catalogCache: cache);
        await pumpEventQueue();

        mockBridge.emitResponse(
          RecentSessionsMessage(
            sessions: [
              _session(id: 'actually-newer', modified: '2026-07-25T00:30:00Z'),
            ],
            hasMore: true,
            requestScope: 'list',
            offset: 0,
            catalogRevision: 9,
          ),
        );
        await pumpEventQueue();

        expect(cubit.state.sessions.map((session) => session.sessionId), [
          'actually-newer',
          'actually-older',
        ]);
      },
    );

    test(
      'legacy live response does not freeze a complete cache from an older Bridge',
      () async {
        await cubit.close();
        mockBridge.dispose();
        mockBridge = MockBridgeService()
          ..testBridgeInstanceId = 'bridge-a'
          ..testLastUrl = 'wss://legacy.example/socket';
        final cache = FakeSessionCatalogCacheRepository();
        final target = SessionCatalogCacheTarget.fromBridge(
          bridgeInstanceId: mockBridge.testBridgeInstanceId,
          websocketUrl: mockBridge.testLastUrl,
        );
        cache.snapshots[target.fingerprint] = SessionCatalogCacheSnapshot(
          partitionId: 'bridge-a',
          sessions: [
            _session(id: 'stale-deleted-session'),
            _session(id: 'live-session'),
          ],
          catalogRevision: null,
          isComplete: true,
          cachedAt: DateTime.utc(2026, 7, 25),
        );
        cubit = SessionListCubit(bridge: mockBridge, catalogCache: cache);
        await pumpEventQueue();

        mockBridge.emitResponse(
          RecentSessionsMessage(
            sessions: [_session(id: 'live-session')],
            hasMore: true,
            requestScope: 'list',
            offset: 0,
          ),
        );
        await pumpEventQueue();

        expect(cubit.state.sessions.map((session) => session.sessionId), [
          'live-session',
        ]);
        expect(cubit.state.hasMore, isTrue);
      },
    );

    test(
      'runtime session broadcasts do not repeatedly decode the catalog',
      () async {
        await cubit.close();
        mockBridge.dispose();
        mockBridge = MockBridgeService()
          ..testBridgeInstanceId = 'bridge-a'
          ..testLastUrl = 'wss://mac-a.example/socket';
        final cache = FakeSessionCatalogCacheRepository();
        cubit = SessionListCubit(bridge: mockBridge, catalogCache: cache);
        await pumpEventQueue();
        expect(cache.loadCalls, 1);

        mockBridge.emitSessionIdentity();
        mockBridge.emitSessionIdentity();
        mockBridge.emitSessionIdentity();
        await pumpEventQueue();

        expect(cache.loadCalls, 1);

        mockBridge.testBridgeInstanceId = 'bridge-b';
        mockBridge.emitSessionIdentity();
        await pumpEventQueue();
        expect(cache.loadCalls, 2);
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
      'incomplete catalog refreshes expand until the snapshot is complete',
      () async {
        mockBridge.emitResponse(
          RecentSessionsMessage(
            sessions: List.generate(250, (index) => _session(id: 's$index')),
            hasMore: true,
            limit: 200,
            offset: 0,
            requestScope: 'catalog',
            catalogRevision: 10,
          ),
        );
        await pumpEventQueue();

        expect(mockBridge.catalogRequestLimits, [1000]);

        mockBridge.emitResponse(
          RecentSessionsMessage(
            sessions: List.generate(1100, (index) => _session(id: 's$index')),
            hasMore: true,
            limit: 1000,
            offset: 0,
            requestScope: 'catalog',
            catalogRevision: 10,
          ),
        );
        mockBridge.emitResponse(
          RecentSessionsMessage(
            sessions: List.generate(1100, (index) => _session(id: 's$index')),
            hasMore: true,
            limit: 1000,
            offset: 0,
            requestScope: 'catalog',
            catalogRevision: 10,
          ),
        );
        await pumpEventQueue();

        expect(mockBridge.catalogRequestLimits, [1000, 2200]);
      },
    );

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
