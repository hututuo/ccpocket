import 'dart:async';

import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:ccpocket/services/database_service.dart';
import 'package:ccpocket/services/prompt_history_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition was not reached before $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('bridgeIdForUrl canonicalizes IPv6 and default ports', () {
    final service = PromptHistoryService(DatabaseService());

    expect(service.bridgeIdForUrl('ws://[0:0:0:0:0:0:0:1]'), '[::1]:80');
    expect(service.bridgeIdForUrl('ws://[::1]:80'), '[::1]:80');
    expect(service.bridgeIdForUrl('wss://EXAMPLE.com'), 'example.com:443');
    expect(service.bridgeIdForUrl('wss://example.com:443'), 'example.com:443');
  });

  test('coalesces concurrent syncs for the same bridge', () async {
    final databaseService = _BlockingDatabaseService();
    final service = PromptHistoryService(databaseService);
    const target = PromptHistorySyncTarget(
      bridgeId: 'bridge-a',
      bridgeUrl: 'ws://bridge-a.invalid',
      bridgeName: 'Bridge A',
    );

    final first = service.syncBridge(target);
    final duplicate = service.syncBridge(target);

    expect(duplicate, same(first));

    databaseService.complete(null);
    expect(await first, isNull);

    final next = service.syncBridge(target);
    expect(next, isNot(same(first)));
    expect(await next, isNull);
  });

  group('current Bridge startup sync', () {
    late Database database;
    late PromptHistoryService service;

    setUpAll(sqfliteFfiInit);

    setUp(() async {
      database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await database.execute('''
        CREATE TABLE prompt_history_sync_status (
          bridge_id TEXT PRIMARY KEY,
          bridge_url TEXT NOT NULL,
          bridge_name TEXT NOT NULL,
          last_sync_at TEXT,
          revision INTEGER NOT NULL DEFAULT 0,
          entry_count INTEGER NOT NULL DEFAULT 0,
          error TEXT
        )
      ''');
      await database.execute('''
        CREATE TABLE prompt_history_cache (
          id TEXT NOT NULL,
          bridge_id TEXT NOT NULL,
          bridge_url TEXT NOT NULL,
          bridge_name TEXT NOT NULL DEFAULT '',
          text TEXT NOT NULL,
          project_path TEXT NOT NULL DEFAULT '',
          total_use_count INTEGER NOT NULL DEFAULT 0,
          is_favorite INTEGER NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL,
          last_used_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          favorite_updated_at TEXT,
          deleted_at TEXT,
          command_kind TEXT NOT NULL DEFAULT 'none',
          client_stats_json TEXT NOT NULL DEFAULT '{}',
          session_stats_json TEXT NOT NULL DEFAULT '{}',
          synced_revision INTEGER NOT NULL DEFAULT 0,
          synced_at TEXT NOT NULL,
          PRIMARY KEY (id, bridge_id)
        )
      ''');
      await database.execute('''
        CREATE TABLE prompt_history (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          text TEXT NOT NULL,
          project_path TEXT NOT NULL DEFAULT '',
          use_count INTEGER NOT NULL DEFAULT 1,
          is_favorite INTEGER NOT NULL DEFAULT 0,
          created_at INTEGER NOT NULL,
          last_used_at INTEGER NOT NULL
        )
      ''');
      service = PromptHistoryService(_StaticDatabaseService(database));
    });

    tearDown(() => database.close());

    test('stable Bridge identity skips an unchanged full snapshot', () async {
      await database.insert('prompt_history_sync_status', {
        'bridge_id': 'bridge-stable',
        'bridge_url': 'ws://10.0.0.2:8765',
        'bridge_name': 'Mac',
        'last_sync_at': '2026-07-30T00:00:00Z',
        'revision': 7,
        'entry_count': 3,
        'error': null,
      });
      final bridge = _PromptHistoryBridgeService(
        status: const PromptHistoryStatusMessage(
          bridgeInstanceId: 'bridge-stable',
          revision: 7,
          entryCount: 3,
        ),
      );

      final statuses = await service.syncAll(bridgeService: bridge);

      expect(bridge.syncRequests, 0);
      expect(statuses, hasLength(1));
      expect(statuses.single.bridgeId, 'bridge-stable');
      expect(statuses.single.revision, 7);
    });

    test(
      'changed advertised revision requests the snapshot on main socket',
      () async {
        await database.insert('prompt_history_sync_status', {
          'bridge_id': 'bridge-stable',
          'bridge_url': 'ws://10.0.0.2:8765',
          'bridge_name': 'Mac',
          'last_sync_at': '2026-07-30T00:00:00Z',
          'revision': 7,
          'entry_count': 3,
          'error': null,
        });
        final bridge = _PromptHistoryBridgeService(
          status: const PromptHistoryStatusMessage(
            bridgeInstanceId: 'bridge-stable',
            revision: 8,
            entryCount: 4,
          ),
          result: const PromptHistorySyncResultMessage(
            success: false,
            bridgeInstanceId: 'bridge-stable',
            error: 'test rejection',
          ),
        );

        await service.syncAll(bridgeService: bridge);

        expect(bridge.syncRequests, 1);
      },
    );

    test(
      'legacy authority accepts and adopts stable id from sync result',
      () async {
        final bridge = _PromptHistoryBridgeService(
          status: null,
          bridgeInstanceIdValue: null,
          promptHistoryBridgeIdValue: null,
          result: PromptHistorySyncResultMessage(
            success: true,
            bridgeInstanceId: 'legacy-prompt-store',
            revision: 3,
            syncedAt: '2026-07-30T00:00:00Z',
            entries: [
              _serverEntry(
                id: 'entry-1',
                text: 'legacy prompt',
                useCount: 1,
                updatedAt: '2026-07-30T00:00:00Z',
              ),
            ],
          ),
        );

        final statuses = await service.syncAll(bridgeService: bridge);

        expect(bridge.syncRequests, 1);
        expect(statuses.single.bridgeId, 'legacy-prompt-store');
        expect(statuses.single.revision, 3);
        final aliases = await service.getBridgeAliasMap();
        expect(aliases['10.0.0.2:8765'], 'legacy-prompt-store');
      },
    );

    test('all routes migrate to one stable Bridge cache identity', () async {
      final bridge = _PromptHistoryBridgeService(
        status: null,
        result: const PromptHistorySyncResultMessage(
          success: true,
          bridgeInstanceId: 'bridge-stable',
          revision: 1,
          syncedAt: '2026-07-30T00:00:00Z',
        ),
      );
      const target = PromptHistorySyncTarget(
        bridgeId: 'bridge-stable',
        bridgeUrl: 'ws://10.0.0.2:8765',
        bridgeName: 'Mac',
        bridgeAliases: ['10.0.0.2:8765', '100.64.0.2:8765'],
      );

      await service.syncCurrentBridge(target: target, bridgeService: bridge);

      final aliases = await service.getBridgeAliasMap();
      expect(aliases['10.0.0.2:8765'], 'bridge-stable');
      expect(aliases['100.64.0.2:8765'], 'bridge-stable');
    });

    test('startup sync and manual import share one response lane', () async {
      await database.insert('prompt_history', {
        'text': 'legacy prompt to import',
        'project_path': '/repo',
        'use_count': 1,
        'is_favorite': 0,
        'created_at': 1,
        'last_used_at': 2,
      });
      final bridge = _PromptHistoryBridgeService(
        status: null,
        autoRespond: false,
      );

      final startup = service.syncAll(bridgeService: bridge);
      await _waitUntil(() => bridge.syncRequests == 1);
      final import = service.importLegacyToCurrentBridge(bridgeService: bridge);
      await Future<void>.delayed(Duration.zero);
      expect(bridge.importRequests, 0);

      bridge.emit(
        const PromptHistorySyncResultMessage(
          success: true,
          bridgeInstanceId: 'bridge-stable',
          revision: 1,
          syncedAt: '2026-07-30T00:00:00Z',
        ),
      );
      await _waitUntil(() => bridge.importRequests == 1);
      bridge.emit(
        const PromptHistorySyncResultMessage(
          success: true,
          bridgeInstanceId: 'bridge-stable',
          revision: 2,
          syncedAt: '2026-07-30T00:00:01Z',
        ),
      );

      await startup;
      expect(await import, isTrue);
      expect(bridge.requestOrder, [
        'sync_prompt_history',
        'import_prompt_history_v1',
      ]);
    });

    test(
      'correlated main-socket response ignores a stale prior result',
      () async {
        await database.insert('prompt_history', {
          'text': 'legacy prompt to import',
          'project_path': '/repo',
          'use_count': 1,
          'is_favorite': 0,
          'created_at': 1,
          'last_used_at': 2,
        });
        final bridge = _PromptHistoryBridgeService(
          status: null,
          autoRespond: false,
          supportsCorrelation: true,
        );

        final startup = service.syncAll(bridgeService: bridge);
        await _waitUntil(() => bridge.lastSyncRequestId != null);
        final firstRequestId = bridge.lastSyncRequestId!;
        bridge.emit(
          PromptHistorySyncResultMessage(
            success: true,
            requestId: firstRequestId,
            bridgeInstanceId: 'bridge-stable',
            revision: 1,
            syncedAt: '2026-07-30T00:00:00Z',
          ),
        );
        await startup;

        var importCompleted = false;
        final import = service
            .importLegacyToCurrentBridge(bridgeService: bridge)
            .whenComplete(() => importCompleted = true);
        await _waitUntil(() => bridge.lastImportRequestId != null);
        final secondRequestId = bridge.lastImportRequestId!;
        expect(secondRequestId, isNot(firstRequestId));

        bridge.emit(
          PromptHistorySyncResultMessage(
            success: true,
            requestId: firstRequestId,
            bridgeInstanceId: 'bridge-stable',
            revision: 99,
            syncedAt: '2026-07-30T00:00:01Z',
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(importCompleted, isFalse);

        bridge.emit(
          PromptHistorySyncResultMessage(
            success: true,
            requestId: secondRequestId,
            bridgeInstanceId: 'bridge-stable',
            revision: 2,
            syncedAt: '2026-07-30T00:00:02Z',
          ),
        );
        expect(await import, isTrue);
      },
    );

    test('legacy response lane stays closed after a timeout', () async {
      final shortTimeoutService = PromptHistoryService(
        _StaticDatabaseService(database),
        syncTimeout: const Duration(milliseconds: 25),
      );
      final bridge = _PromptHistoryBridgeService(
        status: null,
        autoRespond: false,
      );

      await shortTimeoutService.syncAll(bridgeService: bridge);
      expect(bridge.syncRequests, 1);

      await shortTimeoutService.syncAll(bridgeService: bridge);
      expect(bridge.syncRequests, 1);
    });

    test('prompt history response operations are never queued for replay', () {
      final sync = ClientMessage.syncPromptHistory(clientId: 'phone');
      final import = ClientMessage.importPromptHistoryV1(
        clientId: 'phone',
        entries: const [],
      );

      expect(sync.delivery, ClientMessageDelivery.ephemeral);
      expect(import.delivery, ClientMessageDelivery.ephemeral);
    });

    test('legacy unsupported sync fails immediately without timeout', () async {
      final bridge = _PromptHistoryBridgeService(
        status: null,
        autoRespond: false,
      );

      final sync = service.syncAll(bridgeService: bridge);
      await _waitUntil(() => bridge.syncRequests == 1);
      bridge.emitError(
        const ErrorMessage(
          message: 'sync_prompt_history',
          errorCode: 'unsupported_message',
        ),
      );

      final statuses = await sync;
      expect(statuses.single.error, 'sync_prompt_history');
    });
  });

  group('optimistic cache reconciliation', () {
    late Database database;
    late PromptHistoryService service;

    setUpAll(sqfliteFfiInit);

    setUp(() async {
      database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await database.execute('''
        CREATE TABLE prompt_history_cache (
          id TEXT NOT NULL,
          bridge_id TEXT NOT NULL,
          bridge_url TEXT NOT NULL,
          bridge_name TEXT NOT NULL DEFAULT '',
          text TEXT NOT NULL,
          project_path TEXT NOT NULL DEFAULT '',
          total_use_count INTEGER NOT NULL DEFAULT 0,
          is_favorite INTEGER NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL,
          last_used_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          favorite_updated_at TEXT,
          deleted_at TEXT,
          command_kind TEXT NOT NULL DEFAULT 'none',
          client_stats_json TEXT NOT NULL DEFAULT '{}',
          session_stats_json TEXT NOT NULL DEFAULT '{}',
          synced_revision INTEGER NOT NULL DEFAULT 0,
          synced_at TEXT NOT NULL,
          PRIMARY KEY (id, bridge_id)
        )
      ''');
      service = PromptHistoryService(_StaticDatabaseService(database));
    });

    tearDown(() => database.close());

    test('a new optimistic prompt does not erase sibling cache rows', () async {
      await service.recordCacheUseForTest(
        bridgeId: 'bridge-a',
        text: 'first prompt',
        projectPath: '/repo',
        usedAt: '2026-01-01T00:00:00Z',
      );
      await service.recordCacheUseForTest(
        bridgeId: 'bridge-a',
        text: 'second prompt',
        projectPath: '/repo',
        usedAt: '2026-01-01T00:00:01Z',
      );

      final rows = await database.query('prompt_history_cache');
      expect(rows.map((row) => row['text']).toSet(), {
        'first prompt',
        'second prompt',
      });
    });

    test('stale sync cannot overwrite an unacknowledged local use', () async {
      const firstUse = '2026-01-01T00:00:00Z';
      const secondUse = '2026-01-01T00:00:01Z';
      await service.recordCacheUseForTest(
        bridgeId: 'bridge-a',
        text: 'tracked prompt',
        projectPath: '/repo',
        usedAt: firstUse,
      );
      final initial = (await database.query(
        'prompt_history_cache',
        limit: 1,
      )).single;
      final id = initial['id']! as String;

      await service.replaceCacheSnapshotForTest(
        bridgeId: 'bridge-a',
        syncedAt: firstUse,
        entries: [
          _serverEntry(
            id: id,
            text: 'tracked prompt',
            useCount: 1,
            updatedAt: firstUse,
          ),
        ],
      );
      await service.recordCacheUseForTest(
        bridgeId: 'bridge-a',
        text: 'tracked prompt',
        projectPath: '/repo',
        usedAt: secondUse,
      );

      await service.replaceCacheSnapshotForTest(
        bridgeId: 'bridge-a',
        syncedAt: secondUse,
        entries: [
          _serverEntry(
            id: id,
            text: 'tracked prompt',
            useCount: 1,
            updatedAt: firstUse,
          ),
        ],
      );
      var row = (await database.query('prompt_history_cache', limit: 1)).single;
      expect(row['total_use_count'], 2);
      var pending = (await database.query(
        'prompt_history_pending_local',
        limit: 1,
      )).single;
      expect(pending['pending_local_at'], secondUse);

      await service.replaceCacheSnapshotForTest(
        bridgeId: 'bridge-a',
        syncedAt: secondUse,
        entries: [
          _serverEntry(
            id: id,
            text: 'tracked prompt',
            useCount: 2,
            updatedAt: secondUse,
          ),
        ],
      );
      row = (await database.query('prompt_history_cache', limit: 1)).single;
      expect(row['total_use_count'], 2);
      final pendingRows = await database.query('prompt_history_pending_local');
      expect(pendingRows, isEmpty);
    });
  });

  group('PromptHistoryEntry', () {
    test('merges entries from multiple bridges for display', () {
      final first = PromptHistoryEntry(
        id: 'ph_1',
        text: '/test',
        projectPath: '/repo',
        useCount: 2,
        isFavorite: false,
        createdAt: DateTime.utc(2026, 1, 1),
        lastUsedAt: DateTime.utc(2026, 1, 2),
        updatedAt: DateTime.utc(2026, 1, 2),
        commandKind: 'slash',
        bridgeIds: const ['bridge-a'],
        bridgeNames: const ['A'],
        clientStats: const {
          'phone': PromptHistoryClientStat(
            useCount: 2,
            lastUsedAt: '2026-01-02T00:00:00.000Z',
          ),
        },
        sessionStats: const {},
      );
      final second = PromptHistoryEntry(
        id: 'ph_1',
        text: '/test',
        projectPath: '/repo',
        useCount: 3,
        isFavorite: true,
        createdAt: DateTime.utc(2026, 1, 3),
        lastUsedAt: DateTime.utc(2026, 1, 4),
        updatedAt: DateTime.utc(2026, 1, 4),
        commandKind: 'slash',
        bridgeIds: const ['bridge-b'],
        bridgeNames: const ['B'],
        clientStats: const {
          'phone': PromptHistoryClientStat(
            useCount: 1,
            lastUsedAt: '2026-01-04T00:00:00.000Z',
          ),
        },
        sessionStats: const {
          'session': PromptHistorySessionStat(
            useCount: 3,
            lastUsedAt: '2026-01-04T00:00:00.000Z',
          ),
        },
      );

      final merged = first.merge(second);

      expect(merged.useCount, 5);
      expect(merged.isFavorite, isTrue);
      expect(merged.lastUsedAt, DateTime.utc(2026, 1, 4));
      expect(merged.bridgeIds, containsAll(['bridge-a', 'bridge-b']));
      expect(merged.clientStats['phone']?.useCount, 3);
      expect(merged.sessionStats['session']?.useCount, 3);
    });

    test('compares mixed ISO precision by instant instead of text order', () {
      final first = _entry(
        id: 'ph_1',
        projectPath: '/repo',
        bridgeId: 'bridge-a',
        text: '/test',
        clientStats: const {
          'phone': PromptHistoryClientStat(
            useCount: 1,
            lastUsedAt: '2026-01-01T00:00:00Z',
          ),
        },
      );
      final second = _entry(
        id: 'ph_1',
        projectPath: '/repo',
        bridgeId: 'bridge-b',
        text: '/test',
        clientStats: const {
          'phone': PromptHistoryClientStat(
            useCount: 1,
            lastUsedAt: '2026-01-01T00:00:00.500+00:00',
          ),
        },
      );

      final merged = first.merge(second);

      expect(
        merged.clientStats['phone']?.lastUsedAt,
        '2026-01-01T00:00:00.500+00:00',
      );
    });

    test('merges different raw entries by displayed prompt text', () {
      final commandXml = PromptHistoryEntry(
        id: 'ph_xml',
        text:
            '<command-message><command-name>\$release-app</command-name></command-message>',
        projectPath: '/repo/a',
        useCount: 11,
        isFavorite: false,
        createdAt: DateTime.utc(2026, 1, 1),
        lastUsedAt: DateTime.utc(2026, 1, 2),
        updatedAt: DateTime.utc(2026, 1, 2),
        commandKind: 'skill',
        bridgeIds: const ['bridge-a'],
        bridgeNames: const ['A'],
        clientStats: const {},
        sessionStats: const {},
        sources: const [
          PromptHistorySource(id: 'ph_xml', bridgeId: 'bridge-a'),
        ],
      );
      final displayText = PromptHistoryEntry(
        id: 'ph_plain',
        text: r'$release-app',
        projectPath: '/repo/b',
        useCount: 41,
        isFavorite: true,
        createdAt: DateTime.utc(2026, 1, 3),
        lastUsedAt: DateTime.utc(2026, 1, 4),
        updatedAt: DateTime.utc(2026, 1, 4),
        commandKind: 'skill',
        bridgeIds: const ['bridge-b'],
        bridgeNames: const ['B'],
        clientStats: const {},
        sessionStats: const {},
        sources: const [
          PromptHistorySource(id: 'ph_plain', bridgeId: 'bridge-b'),
        ],
      );

      final prompts = PromptHistoryService.mergeEntriesForDisplay([
        commandXml,
        displayText,
      ]);

      expect(prompts, hasLength(1));
      expect(prompts.single.id, 'ph_plain');
      expect(prompts.single.text, r'$release-app');
      expect(prompts.single.useCount, 52);
      expect(prompts.single.isFavorite, isTrue);
      expect(prompts.single.bridgeIds, containsAll(['bridge-a', 'bridge-b']));
      expect(
        prompts.single.sources.map((source) => source.id),
        containsAll(['ph_xml', 'ph_plain']),
      );
    });

    test('merges only entries that survived filters', () {
      final sameProject = _entry(
        id: 'same',
        projectPath: '/workspace/current',
        bridgeId: 'bridge-a',
        text: 'LGTMコミットして',
      );
      final otherProject = _entry(
        id: 'other',
        projectPath: '/workspace/other',
        bridgeId: 'bridge-b',
        text: 'LGTMコミットして',
      );

      final filtered = [sameProject, otherProject]
          .where(
            (entry) => PromptHistoryService.matchesFilters(
              entry,
              filters: const PromptHistoryFilters(currentProjectOnly: true),
              clientId: 'phone',
              currentProjectPath: '/workspace/current',
            ),
          )
          .toList();
      final prompts = PromptHistoryService.mergeEntriesForDisplay(filtered);

      expect(prompts, hasLength(1));
      expect(prompts.single.useCount, 1);
      expect(prompts.single.bridgeIds, ['bridge-a']);
    });

    test('reports active filters', () {
      expect(const PromptHistoryFilters().hasActiveFilter, isFalse);
      expect(
        const PromptHistoryFilters(currentProjectOnly: true).hasActiveFilter,
        isTrue,
      );
    });

    test('matches open project only by project path', () {
      final currentProjectEntry = _entry(
        id: 'current',
        projectPath: '/workspace/current',
      );
      final otherProjectEntry = _entry(
        id: 'other',
        projectPath: '/workspace/other',
      );

      expect(
        PromptHistoryService.matchesFilters(
          currentProjectEntry,
          filters: const PromptHistoryFilters(currentProjectOnly: true),
          clientId: 'phone',
          currentProjectPath: '/workspace/current',
        ),
        isTrue,
      );
      expect(
        PromptHistoryService.matchesFilters(
          otherProjectEntry,
          filters: const PromptHistoryFilters(currentProjectOnly: true),
          clientId: 'phone',
          currentProjectPath: '/workspace/current',
        ),
        isFalse,
      );
    });

    test('does not apply open project when the project filter is off', () {
      final otherProjectEntry = _entry(
        id: 'other',
        projectPath: '/workspace/other',
      );

      expect(
        PromptHistoryService.matchesFilters(
          otherProjectEntry,
          filters: const PromptHistoryFilters(),
          clientId: 'phone',
          currentProjectPath: '/workspace/current',
        ),
        isTrue,
      );
    });
  });

  test('open project filter does not match empty project paths', () {
    final entry = _entry(id: 'empty', projectPath: '');

    expect(
      PromptHistoryService.matchesFilters(
        entry,
        filters: const PromptHistoryFilters(currentProjectOnly: true),
        clientId: 'phone',
        currentProjectPath: '',
      ),
      isFalse,
    );
    expect(
      PromptHistoryService.matchesFilters(
        entry,
        filters: const PromptHistoryFilters(currentProjectOnly: true),
        clientId: 'phone',
        currentProjectPath: '/workspace/current',
      ),
      isFalse,
    );
  });
}

class _BlockingDatabaseService extends DatabaseService {
  final _database = Completer<Database?>();

  @override
  Future<Database?> get database => _database.future;

  void complete(Database? database) {
    _database.complete(database);
  }
}

class _PromptHistoryBridgeService extends BridgeService {
  _PromptHistoryBridgeService({
    required this.status,
    this.result,
    this.bridgeInstanceIdValue = 'bridge-stable',
    this.promptHistoryBridgeIdValue = 'bridge-stable',
    this.autoRespond = true,
    this.supportsCorrelation = false,
  });

  final PromptHistoryStatusMessage? status;
  final PromptHistorySyncResultMessage? result;
  final String? bridgeInstanceIdValue;
  final String? promptHistoryBridgeIdValue;
  final bool autoRespond;
  final bool supportsCorrelation;
  final _results = StreamController<PromptHistorySyncResultMessage>.broadcast();
  final _errors = StreamController<ErrorMessage>.broadcast();
  int syncRequests = 0;
  int importRequests = 0;
  final List<String> requestOrder = [];
  String? lastSyncRequestId;
  String? lastImportRequestId;

  @override
  bool get isConnected => true;

  @override
  String? get lastUrl => 'ws://10.0.0.2:8765';

  @override
  String? get bridgeInstanceId => bridgeInstanceIdValue;

  @override
  String? get promptHistoryBridgeId => promptHistoryBridgeIdValue;

  @override
  PromptHistoryStatusMessage? get lastPromptHistoryStatus => status;

  @override
  bool get supportsPromptHistoryRequestCorrelation => supportsCorrelation;

  @override
  Stream<PromptHistorySyncResultMessage> get promptHistorySyncResults =>
      _results.stream;

  @override
  Stream<ErrorMessage> get promptHistoryOperationErrors => _errors.stream;

  @override
  void requestPromptHistorySync({
    required String clientId,
    required String requestId,
    String? clientName,
    int? sinceRevision,
  }) {
    syncRequests += 1;
    lastSyncRequestId = requestId;
    requestOrder.add('sync_prompt_history');
    final response = result;
    if (autoRespond && response != null) {
      scheduleMicrotask(() => _results.add(response));
    }
  }

  @override
  void requestPromptHistoryImport({
    required String clientId,
    required String requestId,
    String? clientName,
    required List<PromptHistoryServerEntry> entries,
  }) {
    importRequests += 1;
    lastImportRequestId = requestId;
    requestOrder.add('import_prompt_history_v1');
    final response = result;
    if (autoRespond && response != null) {
      scheduleMicrotask(() => _results.add(response));
    }
  }

  void emit(PromptHistorySyncResultMessage response) {
    _results.add(response);
  }

  void emitError(ErrorMessage error) {
    _errors.add(error);
  }
}

class _StaticDatabaseService extends DatabaseService {
  _StaticDatabaseService(this.value);

  final Database value;

  @override
  Future<Database?> get database async => value;
}

PromptHistoryServerEntry _serverEntry({
  required String id,
  required String text,
  required int useCount,
  required String updatedAt,
}) {
  return PromptHistoryServerEntry(
    id: id,
    text: text,
    projectPath: '/repo',
    totalUseCount: useCount,
    isFavorite: false,
    createdAt: '2026-01-01T00:00:00Z',
    lastUsedAt: updatedAt,
    updatedAt: updatedAt,
    commandKind: 'none',
    clientStats: {
      'test-client': PromptHistoryClientStat(
        useCount: useCount,
        lastUsedAt: updatedAt,
      ),
    },
    sessionStats: const {},
  );
}

PromptHistoryEntry _entry({
  required String id,
  required String projectPath,
  String text = '',
  String bridgeId = 'bridge-a',
  Map<String, PromptHistoryClientStat> clientStats = const {},
  Map<String, PromptHistorySessionStat> sessionStats = const {},
}) {
  return PromptHistoryEntry(
    id: id,
    text: text.isEmpty ? 'prompt $id' : text,
    projectPath: projectPath,
    useCount: 1,
    isFavorite: false,
    createdAt: DateTime.utc(2026),
    lastUsedAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
    commandKind: 'none',
    bridgeIds: [bridgeId],
    bridgeNames: const ['Bridge A'],
    clientStats: clientStats,
    sessionStats: sessionStats,
    sources: [PromptHistorySource(id: id, bridgeId: bridgeId)],
  );
}
