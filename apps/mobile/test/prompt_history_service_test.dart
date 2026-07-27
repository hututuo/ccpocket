import 'dart:async';

import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/database_service.dart';
import 'package:ccpocket/services/prompt_history_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
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
