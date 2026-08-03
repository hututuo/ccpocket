import 'dart:io';

import 'package:ccpocket/features/session_list/cache/session_catalog_cache_database.dart';
import 'package:ccpocket/features/session_list/cache/session_catalog_cache_repository.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory temporaryDirectory;
  late String databasePath;
  late SessionCatalogCacheDatabase database;
  late SessionCatalogCacheRepository repository;

  Future<Database> openFfi(String databasePath, OpenDatabaseOptions options) =>
      databaseFactoryFfi.openDatabase(databasePath, options: options);

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'ccpocket_session_catalog_cache_test_',
    );
    databasePath = path.join(
      temporaryDirectory.path,
      SessionCatalogCacheDatabase.fileName,
    );
    database = SessionCatalogCacheDatabase(
      databasePath: databasePath,
      openDatabase: openFfi,
    );
    repository = SessionCatalogCacheRepository(database);
  });

  tearDown(() async {
    await repository.close();
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('partitions one Bridge cache by its selected Codex Home', () {
    final first = SessionCatalogCacheTarget.fromBridge(
      bridgeInstanceId: 'bridge-a',
      codexSourceId: 'codex-home-a',
      logicalConnectionIdentity: 'machine:mac-a',
    );
    final repeated = SessionCatalogCacheTarget.fromBridge(
      bridgeInstanceId: 'bridge-a',
      codexSourceId: 'codex-home-a',
      logicalConnectionIdentity: 'machine:mac-a',
    );
    final second = SessionCatalogCacheTarget.fromBridge(
      bridgeInstanceId: 'bridge-a',
      codexSourceId: 'codex-home-b',
      logicalConnectionIdentity: 'machine:mac-a',
    );
    final legacy = SessionCatalogCacheTarget.fromBridge(
      bridgeInstanceId: 'bridge-a',
    );

    expect(first.fingerprint, repeated.fingerprint);
    expect(first.fingerprint, isNot(second.fingerprint));
    expect(first.fingerprint, isNot(legacy.fingerprint));
    expect(first.aliasKeys, isNot(second.aliasKeys));
    expect(first.fingerprint, isNot(contains('codex-home-a')));
    expect(first.aliasKeys.join(), isNot(contains('codex-home-a')));
  });

  test('keeps display lookups isolated by Codex source', () async {
    final sourceATarget = SessionCatalogCacheTarget.fromBridge(
      bridgeInstanceId: 'bridge-shared',
      codexSourceId: 'codex-source-a',
    );
    await repository.upsertResponse(
      target: sourceATarget,
      response: RecentSessionsMessage(
        sessions: [_session(id: 'thread-shared', name: 'Source A title')],
      ),
    );

    final sourceA = SessionCatalogCacheIdentity(
      bridgeInstanceId: 'bridge-shared',
      codexSourceId: 'codex-source-a',
      provider: 'codex',
      providerSessionId: 'thread-shared',
    );
    final sourceB = SessionCatalogCacheIdentity(
      bridgeInstanceId: 'bridge-shared',
      codexSourceId: 'codex-source-b',
      provider: 'codex',
      providerSessionId: 'thread-shared',
    );
    final legacy = SessionCatalogCacheIdentity(
      bridgeInstanceId: 'bridge-shared',
      provider: 'codex',
      providerSessionId: 'thread-shared',
    );

    final matches = await repository.findSessionsByIdentities([
      sourceA,
      sourceB,
      legacy,
    ]);
    expect(matches[sourceA]?.name, 'Source A title');
    expect(matches[sourceB], isNull);
    expect(matches[legacy], isNull);
  });

  test(
    'uses a separate rebuildable database and round-trips metadata',
    () async {
      final target = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: 'bridge-a',
        logicalConnectionIdentity: 'machine:mac-a',
        websocketUrl: 'wss://mac-a.example:9443/socket?apiKey=secret',
      );
      final session = _session(
        id: 'thread-1',
        name: 'Cached thread',
        forkedFromThreadId: 'parent-thread',
      );

      await repository.upsertResponse(
        target: target,
        response: RecentSessionsMessage(
          sessions: [session],
          catalogRevision: 7,
        ),
      );

      final snapshot = await repository.load(target);
      expect(path.basename(databasePath), 'session_catalog_cache_v1.db');
      expect(await File(databasePath).exists(), isTrue);
      expect(snapshot?.catalogRevision, 7);
      expect(snapshot?.isComplete, isTrue);
      expect(snapshot?.sessions, hasLength(1));
      final restored = snapshot!.sessions.single;
      expect(restored.name, 'Cached thread');
      expect(restored.forkedFromThreadId, 'parent-thread');
      expect(
        restored.codexPermissionsMode,
        CodexPermissionsMode.autoReview.value,
      );
      expect(restored.codexAdditionalWritableRoots, ['/tmp/extra']);

      final db = await database.database;
      final aliases = await db.query(
        SessionCatalogCacheDatabase.aliasesTable,
        columns: ['alias_key'],
      );
      expect(aliases, isNotEmpty);
      expect(aliases.join(), isNot(contains('secret')));
      expect(aliases.join(), isNot(contains('mac-a.example')));
    },
  );

  test(
    'migrates a provisional alias cache after Bridge identity arrives',
    () async {
      final provisional = SessionCatalogCacheTarget.fromBridge(
        logicalConnectionIdentity: 'machine:mac-a',
        websocketUrl: 'ws://127.0.0.1:8765',
      );
      await repository.upsertResponse(
        target: provisional,
        response: RecentSessionsMessage(sessions: [_session(id: 'thread-1')]),
      );
      await repository.applyConversationStatusPage(
        target: provisional,
        statusState: 'provisional-status-state',
        pageIndex: 0,
        pageCount: 1,
        changes: const [
          ConversationSyncV2Status(
            provider: 'codex',
            providerSessionId: 'thread-1',
            activity: 'working',
            attention: 'approval',
            result: 'none',
            runtimeAttachment: 'loaded',
            source: 'bridgeRuntime',
            confidence: 'authoritative',
            observedAt: '2026-07-30T00:03:00.000Z',
          ),
        ],
      );
      await repository.storeReadWatermark(
        target: provisional,
        watermark: const ConversationSyncV2ReadWatermark(
          provider: 'codex',
          providerSessionId: 'thread-1',
          readAt: '2026-07-30T00:04:00.000Z',
        ),
      );
      await repository.markConversationPriorityReady(provisional);

      final canonical = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: 'bridge-a',
        logicalConnectionIdentity: 'machine:mac-a',
        websocketUrl: 'ws://127.0.0.1:8765',
      );
      expect((await repository.load(canonical))?.sessions, hasLength(1));

      await repository.upsertResponse(
        target: canonical,
        response: RecentSessionsMessage(
          sessions: [_session(id: 'thread-1', name: 'Canonical')],
          provider: 'codex',
          hasMore: true,
          catalogRevision: 2,
        ),
      );

      expect(
        (await repository.load(provisional))?.sessions.single.name,
        'Canonical',
      );
      expect(
        await repository.loadConversationSyncState(canonical),
        isA<ConversationSyncCacheState>()
            .having(
              (state) => state.statusState,
              'statusState',
              'provisional-status-state',
            )
            .having((state) => state.priorityReady, 'priorityReady', isTrue),
      );
      expect(await repository.loadConversationStatuses(canonical), [
        isA<ConversationSyncV2Status>()
            .having((status) => status.activity, 'activity', 'working')
            .having((status) => status.attention, 'attention', 'approval'),
      ]);
      expect(await repository.loadReadWatermarks(canonical), [
        isA<ConversationSyncV2ReadWatermark>().having(
          (watermark) => watermark.readAt,
          'readAt',
          '2026-07-30T00:03:00.000Z',
        ),
      ]);
      final db = await database.database;
      final partitionCount = Sqflite.firstIntValue(
        await db.rawQuery(
          'SELECT COUNT(*) FROM '
          '${SessionCatalogCacheDatabase.partitionsTable}',
        ),
      );
      expect(partitionCount, 1);
    },
  );

  test('treats catalog revision zero as a complete current revision', () async {
    final target = SessionCatalogCacheTarget.fromBridge(
      bridgeInstanceId: 'bridge-zero',
    );
    await repository.upsertResponse(
      target: target,
      response: RecentSessionsMessage(
        sessions: [_session(id: 'thread-zero')],
        catalogRevision: 0,
      ),
    );

    final snapshot = await repository.load(target);
    expect(snapshot?.catalogRevision, 0);
    expect(snapshot?.isComplete, isTrue);
  });

  test(
    'does not leak an old canonical cache when an endpoint is reused',
    () async {
      final oldBridge = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: 'bridge-old',
        websocketUrl: 'wss://shared.example/socket',
      );
      await repository.upsertResponse(
        target: oldBridge,
        response: RecentSessionsMessage(
          sessions: [_session(id: 'old-thread', name: 'Old Bridge')],
        ),
      );

      final newBridge = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: 'bridge-new',
        websocketUrl: 'wss://shared.example/socket',
      );
      expect(await repository.load(newBridge), isNull);

      await repository.upsertResponse(
        target: newBridge,
        response: RecentSessionsMessage(
          sessions: [_session(id: 'new-thread', name: 'New Bridge')],
        ),
      );

      expect(
        (await repository.load(newBridge))!.sessions.single.sessionId,
        'new-thread',
      );
      expect(
        (await repository.load(oldBridge))!.sessions.single.sessionId,
        'old-thread',
      );
    },
  );

  test(
    'does not promote an unproven route cache into a scoped Codex source',
    () async {
      final legacyRoute = SessionCatalogCacheTarget.fromBridge(
        logicalConnectionIdentity: 'machine:shared-route',
        websocketUrl: 'wss://shared.example/socket',
      );
      await repository.upsertResponse(
        target: legacyRoute,
        response: RecentSessionsMessage(
          sessions: [_session(id: 'legacy-thread', name: 'Legacy route')],
        ),
      );

      final authenticatedSource = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: 'bridge-new',
        codexSourceId: 'codex-home-new',
        logicalConnectionIdentity: 'machine:shared-route',
        websocketUrl: 'wss://shared.example/socket',
      );

      expect(await repository.load(authenticatedSource), isNull);
      expect(
        (await repository.load(legacyRoute))!.sessions.single.sessionId,
        'legacy-thread',
      );
    },
  );

  test(
    'partial revisions merge while a complete snapshot replaces stale rows',
    () async {
      final target = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: 'bridge-a',
      );
      await repository.upsertResponse(
        target: target,
        response: RecentSessionsMessage(
          sessions: [
            _session(id: 'thread-a', name: 'A1'),
            _session(id: 'thread-b', name: 'B1'),
          ],
          catalogRevision: 1,
        ),
      );

      await repository.upsertResponse(
        target: target,
        response: RecentSessionsMessage(
          sessions: [_session(id: 'thread-a', name: 'A2')],
          hasMore: true,
          provider: 'codex',
          catalogRevision: 2,
        ),
      );

      final partial = await repository.load(target);
      expect(partial?.sessions.map((session) => session.sessionId).toSet(), {
        'thread-a',
        'thread-b',
      });
      expect(partial?.isComplete, isFalse);
      expect(partial?.catalogRevision, 2);

      await repository.upsertResponse(
        target: target,
        response: RecentSessionsMessage(
          sessions: [_session(id: 'thread-a', name: 'A3')],
          catalogRevision: 2,
        ),
      );

      final complete = await repository.load(target);
      expect(complete?.sessions, hasLength(1));
      expect(complete?.sessions.single.name, 'A3');
      expect(complete?.isComplete, isTrue);
    },
  );

  test('supports per-session deletion and global cache clearing', () async {
    final target = SessionCatalogCacheTarget.fromBridge(
      bridgeInstanceId: 'bridge-a',
    );
    final first = _session(id: 'thread-a');
    final second = _session(id: 'thread-b');
    await repository.upsertResponse(
      target: target,
      response: RecentSessionsMessage(sessions: [first, second]),
    );

    await repository.deleteSession(target: target, session: first);
    expect(await repository.countSessions(target), 1);
    expect(await repository.countAllSessions(), 1);
    expect(
      (await repository.load(target))!.sessions.single.sessionId,
      'thread-b',
    );

    await repository.clearAll();
    expect(await repository.load(target), isNull);
    expect(await repository.countSessions(target), 0);
    expect(await repository.countAllSessions(), 0);
  });

  test(
    'reports the full rebuildable cache scope and resolves display data',
    () async {
      final target = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: 'bridge-display',
      );
      await repository.upsertResponse(
        target: target,
        response: RecentSessionsMessage(
          sessions: [_session(id: 'thread-display', name: 'Saved title')],
        ),
      );
      await repository.replaceConversationWindow(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-display',
        revision: 'revision-display',
        entries: [_entry('entry-display', 0, 'idle')],
        hasEarlier: false,
        sourceEntryCount: 1,
      );

      final stats = await repository.cacheStats();
      expect(stats.sessionSummaries, 1);
      expect(stats.conversationWindows, 1);
      expect(
        (await repository.findSessionByIdentity(
          bridgeInstanceId: 'bridge-display',
          provider: 'codex',
          providerSessionId: 'thread-display',
        ))?.name,
        'Saved title',
      );
      expect(
        await repository.findSessionByIdentity(
          bridgeInstanceId: 'another-bridge',
          provider: 'codex',
          providerSessionId: 'thread-display',
        ),
        isNull,
      );
      final cachedConversations = await repository.cachedConversations(target);
      expect(cachedConversations, hasLength(1));
      expect(cachedConversations.single.providerSessionId, 'thread-display');
      expect(cachedConversations.single.session?.name, 'Saved title');

      await repository.clearAll();
      final cleared = await repository.cacheStats();
      expect(cleared.sessionSummaries, 0);
      expect(cleared.conversationWindows, 0);
    },
  );

  test(
    'clears one rebuildable data source while preserving read watermarks',
    () async {
      final first = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: 'bridge-first',
        codexSourceId: 'source-first',
      );
      final second = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: 'bridge-second',
        codexSourceId: 'source-second',
      );
      for (final entry in [
        (target: first, id: 'thread-first'),
        (target: second, id: 'thread-second'),
      ]) {
        await repository.upsertResponse(
          target: entry.target,
          response: RecentSessionsMessage(
            sessions: [_session(id: entry.id, name: entry.id)],
          ),
        );
        await repository.replaceConversationWindow(
          target: entry.target,
          provider: 'codex',
          providerSessionId: entry.id,
          revision: 'revision-${entry.id}',
          entries: [_entry('entry-${entry.id}', 0, 'idle')],
          hasEarlier: false,
          sourceEntryCount: 1,
        );
      }
      await repository.storeReadWatermark(
        target: first,
        watermark: const ConversationSyncV2ReadWatermark(
          provider: 'codex',
          providerSessionId: 'thread-first',
          readAt: '2026-07-30T01:02:03.000Z',
        ),
        allowUnanchoredLegacySeed: true,
      );

      await repository.clearTarget(first);

      expect(
        await repository.cacheStatsForTarget(first),
        isA<SessionCatalogCacheStats>()
            .having((stats) => stats.sessionSummaries, 'summaries', 0)
            .having((stats) => stats.conversationWindows, 'windows', 0),
      );
      expect(await repository.loadReadWatermarks(first), [
        isA<ConversationSyncV2ReadWatermark>()
            .having(
              (watermark) => watermark.providerSessionId,
              'providerSessionId',
              'thread-first',
            )
            .having(
              (watermark) => watermark.readAt,
              'readAt',
              '2026-07-30T01:02:03.000Z',
            ),
      ]);
      expect(
        await repository.cacheStatsForTarget(second),
        isA<SessionCatalogCacheStats>()
            .having((stats) => stats.sessionSummaries, 'summaries', 1)
            .having((stats) => stats.conversationWindows, 'windows', 1),
      );
    },
  );

  test('resolves many display identities in bounded batches', () async {
    const sessionCount = 305;
    final identities = <SessionCatalogCacheIdentity>[];
    for (var index = 0; index < sessionCount; index++) {
      final bridgeId = 'bridge-batch-$index';
      final sessionId = 'thread-batch-$index';
      await repository.upsertResponse(
        target: SessionCatalogCacheTarget.fromBridge(
          bridgeInstanceId: bridgeId,
        ),
        response: RecentSessionsMessage(
          sessions: [_session(id: sessionId, name: 'Batch title $index')],
        ),
      );
      identities.add(
        SessionCatalogCacheIdentity(
          bridgeInstanceId: bridgeId,
          provider: 'codex',
          providerSessionId: sessionId,
        ),
      );
    }
    const missing = SessionCatalogCacheIdentity(
      bridgeInstanceId: 'bridge-missing',
      provider: 'codex',
      providerSessionId: 'thread-missing',
    );

    final sessions = await repository.findSessionsByIdentities([
      ...identities,
      identities.first,
      missing,
    ]);

    expect(sessions, hasLength(sessionCount));
    expect(sessions[identities.first]?.name, 'Batch title 0');
    expect(sessions[identities.last]?.name, 'Batch title 304');
    expect(sessions[missing], isNull);
  });

  test('atomically replaces and patches a hot conversation window', () async {
    final target = SessionCatalogCacheTarget.fromBridge(
      bridgeInstanceId: 'bridge-hot',
      logicalConnectionIdentity: 'machine:hot',
    );
    await repository.replaceConversationWindow(
      target: target,
      provider: 'codex',
      providerSessionId: 'thread-hot',
      revision: 'revision-1',
      entries: [_entry('entry-1', 0, 'idle')],
      hasEarlier: true,
      sourceEntryCount: 500,
    );

    expect(await repository.knownConversationRevisions(target), hasLength(1));
    final first = await repository.loadConversationWindow(
      target: target,
      provider: 'codex',
      providerSessionId: 'thread-hot',
    );
    expect(first?.revision, 'revision-1');
    expect(first?.hasEarlier, isTrue);
    expect(first?.entries.single.decodeMessage(), isA<StatusMessage>());

    expect(
      await repository.applyConversationPatch(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-hot',
        baseRevision: 'stale-revision',
        revision: 'revision-2',
        upserts: const [],
        deletes: const [],
        hasEarlier: true,
        sourceEntryCount: 500,
      ),
      isFalse,
    );
    expect(
      await repository.applyConversationPatch(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-hot',
        baseRevision: 'revision-1',
        revision: 'revision-2',
        upserts: [_entry('entry-2', 1, 'running')],
        deletes: const ['entry-1'],
        hasEarlier: false,
        sourceEntryCount: 1,
      ),
      isTrue,
    );

    final patched = await repository.loadConversationWindow(
      target: target,
      provider: 'codex',
      providerSessionId: 'thread-hot',
    );
    expect(patched?.revision, 'revision-2');
    expect(patched?.hasEarlier, isFalse);
    expect(patched?.entries.single.entryId, 'entry-2');
  });

  test('advertises only readable complete hot-window revisions', () async {
    final target = SessionCatalogCacheTarget.fromBridge(
      bridgeInstanceId: 'bridge-readable-revisions',
      codexSourceId: 'source-readable-revisions',
    );
    for (final thread in const [
      'valid',
      'malformed-json',
      'invalid-message',
      'count-mismatch',
      'out-of-range-index',
      'empty-entry-id',
    ]) {
      await repository.replaceConversationWindow(
        target: target,
        provider: 'codex',
        providerSessionId: thread,
        revision: 'revision-$thread',
        entries: [_entry('entry-$thread', 0, 'idle')],
        hasEarlier: false,
        sourceEntryCount: 1,
      );
    }
    await repository.replaceConversationWindow(
      target: target,
      provider: 'codex',
      providerSessionId: 'incomplete-empty',
      revision: 'revision-incomplete-empty',
      entries: const [],
      hasEarlier: true,
      latestTurnComplete: false,
      latestTurnGap: const ConversationSyncV2LatestTurnGap(
        missingEntryCount: 1,
        payloadOmitted: false,
        repair: 'turns_page',
      ),
      sourceEntryCount: 0,
    );
    await repository.replaceConversationWindow(
      target: target,
      provider: 'other',
      providerSessionId: 'invalid-provider',
      revision: 'revision-invalid-provider',
      entries: [_entry('entry-invalid-provider', 0, 'idle')],
      hasEarlier: false,
      sourceEntryCount: 1,
    );
    await repository.replaceConversationWindow(
      target: target,
      provider: 'codex',
      providerSessionId: '',
      revision: 'revision-empty-session',
      entries: [_entry('entry-empty-session', 0, 'idle')],
      hasEarlier: false,
      sourceEntryCount: 1,
    );
    await repository.replaceConversationWindow(
      target: target,
      provider: 'codex',
      providerSessionId: List.filled(257, 's').join(),
      revision: 'revision-long-session',
      entries: [_entry('entry-long-session', 0, 'idle')],
      hasEarlier: false,
      sourceEntryCount: 1,
    );
    await repository.replaceConversationWindow(
      target: target,
      provider: 'codex',
      providerSessionId: 'empty-revision',
      revision: '',
      entries: [_entry('entry-empty-revision', 0, 'idle')],
      hasEarlier: false,
      sourceEntryCount: 1,
    );
    await repository.replaceConversationWindow(
      target: target,
      provider: 'codex',
      providerSessionId: 'long-revision',
      revision: List.filled(129, 'r').join(),
      entries: [_entry('entry-long-revision', 0, 'idle')],
      hasEarlier: false,
      sourceEntryCount: 1,
    );

    final valid = await repository.loadConversationWindow(
      target: target,
      provider: 'codex',
      providerSessionId: 'valid',
    );
    final partitionId = valid!.partitionId;
    final db = await database.database;
    await db.update(
      SessionCatalogCacheDatabase.hotEntriesTable,
      {'message_json': '{not-json'},
      where: 'partition_id = ? AND provider = ? AND provider_session_id = ?',
      whereArgs: [partitionId, 'codex', 'malformed-json'],
    );
    await db.update(
      SessionCatalogCacheDatabase.hotEntriesTable,
      {'message_json': '{"type":7}'},
      where: 'partition_id = ? AND provider = ? AND provider_session_id = ?',
      whereArgs: [partitionId, 'codex', 'invalid-message'],
    );
    await db.update(
      SessionCatalogCacheDatabase.hotWindowsTable,
      {'entry_count': 2},
      where: 'partition_id = ? AND provider = ? AND provider_session_id = ?',
      whereArgs: [partitionId, 'codex', 'count-mismatch'],
    );
    await db.update(
      SessionCatalogCacheDatabase.hotEntriesTable,
      {'entry_index': -SessionCatalogCacheRepository.maxHotWindowEntries - 1},
      where: 'partition_id = ? AND provider = ? AND provider_session_id = ?',
      whereArgs: [partitionId, 'codex', 'out-of-range-index'],
    );
    await db.update(
      SessionCatalogCacheDatabase.hotEntriesTable,
      {'entry_id': ''},
      where: 'partition_id = ? AND provider = ? AND provider_session_id = ?',
      whereArgs: [partitionId, 'codex', 'empty-entry-id'],
    );

    expect(
      await repository.loadConversationWindow(
        target: target,
        provider: 'codex',
        providerSessionId: 'malformed-json',
      ),
      isNull,
    );
    expect(
      await repository.loadConversationWindow(
        target: target,
        provider: 'codex',
        providerSessionId: 'invalid-message',
      ),
      isNull,
    );
    expect(
      await repository.loadConversationWindow(
        target: target,
        provider: 'codex',
        providerSessionId: 'count-mismatch',
      ),
      isNull,
    );
    expect(
      (await repository.knownConversationRevisions(
        target,
      )).map((cursor) => cursor.providerSessionId),
      ['valid'],
    );
    expect(
      Sqflite.firstIntValue(
        await db.rawQuery(
          'SELECT COUNT(*) FROM '
          '${SessionCatalogCacheDatabase.hotWindowsTable} '
          'WHERE partition_id = ?',
          [partitionId],
        ),
      ),
      12,
    );
  });

  test('keeps hot windows isolated by canonical Bridge identity', () async {
    final oldTarget = SessionCatalogCacheTarget.fromBridge(
      bridgeInstanceId: 'bridge-old',
      websocketUrl: 'wss://shared.example/socket',
    );
    await repository.replaceConversationWindow(
      target: oldTarget,
      provider: 'codex',
      providerSessionId: 'thread-1',
      revision: 'old',
      entries: [_entry('entry-old', 0, 'idle')],
      hasEarlier: false,
      sourceEntryCount: 1,
    );
    final newTarget = SessionCatalogCacheTarget.fromBridge(
      bridgeInstanceId: 'bridge-new',
      websocketUrl: 'wss://shared.example/socket',
    );

    expect(
      await repository.loadConversationWindow(
        target: newTarget,
        provider: 'codex',
        providerSessionId: 'thread-1',
      ),
      isNull,
    );
  });

  test('commits v2 catalog and monotonic composite status state', () async {
    final target = SessionCatalogCacheTarget.fromBridge(
      bridgeInstanceId: 'bridge-v2',
      codexSourceId: 'source-v2',
    );
    const catalogEntry = ConversationSyncV2CatalogEntry(
      provider: 'codex',
      providerSessionId: 'thread-v2',
      revision: 'catalog-revision-1',
      projectPath: '/workspace/v2',
      name: 'Synced thread',
      firstPrompt: 'Hello',
      model: 'gpt-5.6-sol',
      modelReasoningEffort: 'ultra',
      serviceTier: 'fast',
      createdAt: '2026-07-30T00:00:00.000Z',
      modifiedAt: '2026-07-30T00:01:00.000Z',
      recencyAt: '2026-07-30T00:02:00.000Z',
      availability: 'durable',
    );
    await repository.applyConversationCatalogBatch(
      target: target,
      codexSourceId: 'source-v2',
      catalogState: 'catalog-state-1',
      created: const [catalogEntry],
      updated: const [],
      destroyed: const [],
    );
    await repository.applyConversationStatusBatch(
      target: target,
      statusState: 'status-state-1',
      changes: const [
        ConversationSyncV2Status(
          provider: 'codex',
          providerSessionId: 'thread-v2',
          activity: 'working',
          attention: 'approval',
          result: 'none',
          runtimeAttachment: 'loaded',
          source: 'appServer',
          confidence: 'authoritative',
          observedAt: '2026-07-30T00:03:00.000Z',
        ),
      ],
    );
    await repository.applyConversationStatusBatch(
      target: target,
      statusState: 'status-state-2',
      changes: const [
        ConversationSyncV2Status(
          provider: 'codex',
          providerSessionId: 'thread-v2',
          activity: 'idle',
          attention: 'none',
          result: 'none',
          runtimeAttachment: 'loaded',
          source: 'appServer',
          confidence: 'authoritative',
          observedAt: '2026-07-30T00:02:00.000Z',
        ),
      ],
    );

    final catalog = await repository.load(target);
    expect(catalog?.sessions.single.name, 'Synced thread');
    expect(catalog?.sessions.single.codexSourceId, 'source-v2');
    expect(catalog?.sessions.single.codexModel, 'gpt-5.6-sol');
    expect(catalog?.sessions.single.codexModelReasoningEffort, 'ultra');
    expect(catalog?.sessions.single.codexServiceTier, 'fast');
    final statuses = await repository.loadConversationStatuses(target);
    expect(statuses.single.activity, 'working');
    expect(statuses.single.attention, 'approval');
    final state = await repository.loadConversationSyncState(target);
    expect(state.catalogState, 'catalog-state-1');
    expect(state.statusState, 'status-state-2');
  });

  test(
    'merges sparse Codex settings but lets a complete snapshot clear them',
    () async {
      final target = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: 'bridge-v2-settings',
        codexSourceId: 'source-v2-settings',
      );
      await repository.applyConversationCatalogBatch(
        target: target,
        codexSourceId: 'source-v2-settings',
        catalogState: 'catalog-settings-complete',
        created: const [
          ConversationSyncV2CatalogEntry(
            provider: 'codex',
            providerSessionId: 'thread-v2-settings',
            revision: 'revision-settings-1',
            projectPath: '/workspace/settings',
            model: 'gpt-5.6-sol',
            modelReasoningEffort: 'ultra',
            serviceTier: 'fast',
            approvalPolicy: 'never',
            approvalsReviewer: 'user',
            sandboxMode: 'danger-full-access',
            collaborationMode: 'plan',
            networkAccessEnabled: true,
            webSearchMode: 'live',
            codexSettingsSnapshotComplete: true,
            createdAt: '2026-08-02T00:00:00.000Z',
            modifiedAt: '2026-08-02T00:01:00.000Z',
            recencyAt: '2026-08-02T00:01:00.000Z',
            availability: 'durable',
          ),
        ],
        updated: const [],
        destroyed: const [],
      );

      // The legacy directory path is still active during v2 startup and can
      // deliver a bounded, settings-sparse catalog after focused hydration.
      // It must share the same merge semantics instead of downgrading the
      // committed authoritative snapshot.
      await repository.upsertResponse(
        target: target,
        response: RecentSessionsMessage(
          requestScope: 'catalog',
          sessions: [
            RecentSession(
              sessionId: 'thread-v2-settings',
              provider: Provider.codex.value,
              codexSourceId: 'source-v2-settings',
              firstPrompt: 'Sparse legacy refresh',
              created: '2026-08-02T00:00:00.000Z',
              modified: '2026-08-02T00:01:30.000Z',
              gitBranch: 'main',
              projectPath: '/workspace/settings',
              isSidechain: false,
            ),
          ],
        ),
      );

      var session = (await repository.load(target))!.sessions.single;
      expect(session.codexModel, 'gpt-5.6-sol');
      expect(session.codexModelReasoningEffort, 'ultra');
      expect(session.codexServiceTier, 'fast');
      expect(session.codexApprovalPolicy, 'never');
      expect(session.codexApprovalsReviewer, 'user');
      expect(session.codexSandboxMode, 'danger-full-access');
      expect(session.codexCollaborationMode, 'plan');
      expect(session.codexSettingsSnapshotComplete, isTrue);

      await repository.applyConversationCatalogBatch(
        target: target,
        codexSourceId: 'source-v2-settings',
        catalogState: 'catalog-settings-sparse',
        created: const [],
        updated: const [
          ConversationSyncV2CatalogEntry(
            provider: 'codex',
            providerSessionId: 'thread-v2-settings',
            revision: 'revision-settings-2',
            projectPath: '/workspace/settings',
            createdAt: '2026-08-02T00:00:00.000Z',
            modifiedAt: '2026-08-02T00:02:00.000Z',
            recencyAt: '2026-08-02T00:02:00.000Z',
            availability: 'durable',
          ),
        ],
        destroyed: const [],
      );

      session = (await repository.load(target))!.sessions.single;
      expect(session.codexModel, 'gpt-5.6-sol');
      expect(session.codexModelReasoningEffort, 'ultra');
      expect(session.codexServiceTier, 'fast');
      expect(session.codexApprovalPolicy, 'never');
      expect(session.codexApprovalsReviewer, 'user');
      expect(session.codexSandboxMode, 'danger-full-access');
      expect(session.codexCollaborationMode, 'plan');
      expect(session.planMode, isTrue);
      expect(session.codexNetworkAccessEnabled, isTrue);
      expect(session.codexWebSearchMode, 'live');
      expect(session.codexSettingsSnapshotComplete, isTrue);

      await repository.applyConversationCatalogBatch(
        target: target,
        codexSourceId: 'source-v2-settings',
        catalogState: 'catalog-settings-cleared',
        created: const [],
        updated: const [
          ConversationSyncV2CatalogEntry(
            provider: 'codex',
            providerSessionId: 'thread-v2-settings',
            revision: 'revision-settings-3',
            projectPath: '/workspace/settings',
            model: 'gpt-5.6-sol',
            modelReasoningEffort: 'max',
            serviceTier: 'standard',
            approvalPolicy: 'on-request',
            approvalsReviewer: 'auto_review',
            sandboxMode: 'workspace-write',
            collaborationMode: 'default',
            networkAccessEnabled: false,
            codexSettingsSnapshotComplete: true,
            createdAt: '2026-08-02T00:00:00.000Z',
            modifiedAt: '2026-08-02T00:03:00.000Z',
            recencyAt: '2026-08-02T00:03:00.000Z',
            availability: 'durable',
          ),
        ],
        destroyed: const [],
      );

      session = (await repository.load(target))!.sessions.single;
      expect(session.codexModelReasoningEffort, 'max');
      expect(session.codexServiceTier, 'standard');
      expect(session.codexApprovalPolicy, 'on-request');
      expect(session.codexApprovalsReviewer, 'auto_review');
      expect(session.codexSandboxMode, 'workspace-write');
      expect(session.codexCollaborationMode, 'default');
      expect(session.planMode, isFalse);
      expect(session.codexNetworkAccessEnabled, isFalse);
      expect(session.codexWebSearchMode, isNull);
      expect(session.codexSettingsSnapshotComplete, isTrue);
    },
  );

  test('rejects direct partial catalog and status page mutations', () async {
    final target = SessionCatalogCacheTarget.fromBridge(
      bridgeInstanceId: 'bridge-partial-pages',
      codexSourceId: 'source-partial-pages',
    );
    await expectLater(
      repository.applyConversationCatalogPage(
        target: target,
        codexSourceId: 'source-partial-pages',
        catalogState: 'catalog-partial',
        pageIndex: 0,
        pageCount: 2,
        created: const [
          ConversationSyncV2CatalogEntry(
            provider: 'codex',
            providerSessionId: 'thread-partial',
            revision: 'revision-partial',
            projectPath: '/workspace/partial',
            createdAt: '2026-07-30T00:00:00.000Z',
            modifiedAt: '2026-07-30T00:01:00.000Z',
            recencyAt: '2026-07-30T00:01:00.000Z',
            availability: 'durable',
          ),
        ],
        updated: const [],
        destroyed: const [],
      ),
      throwsStateError,
    );
    await expectLater(
      repository.applyConversationStatusPage(
        target: target,
        statusState: 'status-partial',
        pageIndex: 0,
        pageCount: 2,
        changes: const [
          ConversationSyncV2Status(
            provider: 'codex',
            providerSessionId: 'thread-partial',
            activity: 'working',
            attention: 'none',
            result: 'none',
            runtimeAttachment: 'loaded',
            source: 'appServer',
            confidence: 'authoritative',
            observedAt: '2026-07-30T00:02:00.000Z',
          ),
        ],
      ),
      throwsStateError,
    );
    await repository.applyConversationCatalogBatch(
      target: target,
      codexSourceId: 'source-partial-pages',
      catalogState: 'catalog-superseded',
      created: const [
        ConversationSyncV2CatalogEntry(
          provider: 'codex',
          providerSessionId: 'thread-superseded',
          revision: 'revision-superseded',
          projectPath: '/workspace/superseded',
          createdAt: '2026-07-30T00:00:00.000Z',
          modifiedAt: '2026-07-30T00:03:00.000Z',
          recencyAt: '2026-07-30T00:03:00.000Z',
          availability: 'durable',
        ),
      ],
      updated: const [],
      destroyed: const [],
      isCurrent: () => false,
    );

    expect(await repository.load(target), isNull);
    expect(await repository.loadConversationStatuses(target), isEmpty);
  });

  test(
    'read watermark anchors to the latest authoritative status clock',
    () async {
      final target = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: 'bridge-read-clamp',
        codexSourceId: 'source-read-clamp',
      );
      await repository.applyConversationStatusPage(
        target: target,
        statusState: 'status-read-clamp',
        pageIndex: 0,
        pageCount: 1,
        changes: const [
          ConversationSyncV2Status(
            provider: 'codex',
            providerSessionId: 'thread-read-clamp',
            activity: 'idle',
            attention: 'none',
            result: 'completed',
            runtimeAttachment: 'notLoaded',
            source: 'appServer',
            confidence: 'authoritative',
            observedAt: '2026-07-30T00:02:00.000Z',
          ),
        ],
      );

      final clamped = await repository.storeReadWatermark(
        target: target,
        watermark: const ConversationSyncV2ReadWatermark(
          provider: 'codex',
          providerSessionId: 'thread-read-clamp',
          readAt: '2026-07-30T00:01:00.000Z',
        ),
      );
      expect(clamped?.readAt, '2026-07-30T00:02:00.000Z');

      final phoneClockAhead = await repository.storeReadWatermark(
        target: target,
        watermark: const ConversationSyncV2ReadWatermark(
          provider: 'codex',
          providerSessionId: 'thread-read-clamp',
          readAt: '2099-07-30T00:03:00.000Z',
        ),
      );
      expect(phoneClockAhead?.readAt, '2026-07-30T00:02:00.000Z');

      await repository.applyConversationStatusPage(
        target: target,
        statusState: 'status-read-clamp-2',
        pageIndex: 0,
        pageCount: 1,
        changes: const [
          ConversationSyncV2Status(
            provider: 'codex',
            providerSessionId: 'thread-read-clamp',
            activity: 'idle',
            attention: 'none',
            result: 'completed',
            runtimeAttachment: 'notLoaded',
            source: 'appServer',
            confidence: 'authoritative',
            observedAt: '2026-07-30T00:03:00.000Z',
          ),
        ],
      );

      final stale = await repository.storeReadWatermark(
        target: target,
        watermark: const ConversationSyncV2ReadWatermark(
          provider: 'codex',
          providerSessionId: 'thread-read-clamp',
          readAt: '2026-07-30T00:01:30.000Z',
        ),
      );
      expect(stale?.readAt, '2026-07-30T00:03:00.000Z');
      expect(
        (await repository.loadReadWatermarks(target)).single.readAt,
        '2026-07-30T00:03:00.000Z',
      );
    },
  );

  test(
    'stages v2 pages on disk and preserves untouched patch entries',
    () async {
      final target = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: 'bridge-stage',
        codexSourceId: 'source-stage',
      );
      final first = await repository.stageConversationTimelinePage(
        target: target,
        subscriptionId: 'subscription-1',
        provider: 'codex',
        providerSessionId: 'thread-stage',
        revision: 'revision-1',
        baseRevision: null,
        mode: 'snapshot',
        pageIndex: 0,
        pageCount: 2,
        entries: [_entry('entry-1', 0, 'idle')],
        deletes: const [],
        hasEarlier: true,
        sourceEntryCount: 50,
      );
      expect(first.pageStored, isTrue);
      expect(first.windowCommitted, isFalse);
      expect(
        await repository.loadConversationWindow(
          target: target,
          provider: 'codex',
          providerSessionId: 'thread-stage',
        ),
        isNull,
      );

      final second = await repository.stageConversationTimelinePage(
        target: target,
        subscriptionId: 'subscription-1',
        provider: 'codex',
        providerSessionId: 'thread-stage',
        revision: 'revision-1',
        baseRevision: null,
        mode: 'snapshot',
        pageIndex: 1,
        pageCount: 2,
        entries: [_entry('entry-2', 1, 'running')],
        deletes: const [],
        hasEarlier: true,
        sourceEntryCount: 50,
      );
      expect(second.windowCommitted, isTrue);
      final snapshot = await repository.loadConversationWindow(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-stage',
      );
      expect(snapshot?.entries.map((entry) => entry.entryId), [
        'entry-1',
        'entry-2',
      ]);

      final patched = await repository.stageConversationTimelinePage(
        target: target,
        subscriptionId: 'subscription-1',
        provider: 'codex',
        providerSessionId: 'thread-stage',
        revision: 'revision-2',
        baseRevision: 'revision-1',
        mode: 'patch',
        pageIndex: 0,
        pageCount: 1,
        entries: [_entry('entry-3', 2, 'idle')],
        deletes: const ['entry-1'],
        hasEarlier: false,
        sourceEntryCount: 2,
      );
      expect(patched.baseRevisionMatched, isTrue);
      expect(patched.windowCommitted, isTrue);
      final finalWindow = await repository.loadConversationWindow(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-stage',
      );
      expect(finalWindow?.revision, 'revision-2');
      expect(finalWindow?.entries.map((entry) => entry.entryId), [
        'entry-2',
        'entry-3',
      ]);

      final db = await database.database;
      expect(
        Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM '
            '${SessionCatalogCacheDatabase.timelineStagesTable}',
          ),
        ),
        0,
      );
    },
  );

  test(
    'persists assistant text ordering checkpoints across tool patches and catalog refreshes',
    () async {
      final target = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: 'bridge-assistant-order',
        codexSourceId: 'source-assistant-order',
      );
      const catalogEntry = ConversationSyncV2CatalogEntry(
        provider: 'codex',
        providerSessionId: 'thread-assistant-order',
        revision: 'catalog-1',
        projectPath: '/workspace/assistant-order',
        firstPrompt: 'Order this thread',
        createdAt: '2026-07-30T00:00:00.000Z',
        modifiedAt: '2026-07-30T00:01:00.000Z',
        recencyAt: '2026-07-30T00:01:00.000Z',
        availability: 'durable',
      );
      await repository.applyConversationCatalogPage(
        target: target,
        codexSourceId: 'source-assistant-order',
        catalogState: 'catalog-1',
        pageIndex: 0,
        pageCount: 1,
        created: const [catalogEntry],
        updated: const [],
        destroyed: const [],
      );

      final first = await repository.stageConversationTimelinePage(
        target: target,
        subscriptionId: 'subscription-assistant-order',
        provider: 'codex',
        providerSessionId: 'thread-assistant-order',
        revision: 'timeline-1',
        baseRevision: null,
        mode: 'snapshot',
        pageIndex: 0,
        pageCount: 1,
        entries: [
          _assistantEntry(
            'assistant-1',
            0,
            text: 'First visible update',
            receivedAt: '2026-07-30T00:02:00.000Z',
          ),
          _assistantEntry(
            'assistant-untimestamped',
            1,
            text: 'Visible legacy update without a timestamp',
          ),
        ],
        deletes: const [],
        hasEarlier: false,
        sourceEntryCount: 2,
      );
      expect(first.lastAssistantOutputAt, '2026-07-30T00:02:00.000Z');
      expect(
        (await repository.load(target))?.sessions.single.lastAssistantOutputAt,
        '2026-07-30T00:02:00.000Z',
      );

      final toolOnly = await repository.stageConversationTimelinePage(
        target: target,
        subscriptionId: 'subscription-assistant-order',
        provider: 'codex',
        providerSessionId: 'thread-assistant-order',
        revision: 'timeline-2',
        baseRevision: 'timeline-1',
        mode: 'patch',
        pageIndex: 0,
        pageCount: 1,
        entries: [
          _assistantToolEntry(
            'assistant-tool',
            2,
            receivedAt: '2026-07-30T00:03:00.000Z',
          ),
        ],
        deletes: const [],
        hasEarlier: false,
        sourceEntryCount: 3,
      );
      expect(toolOnly.lastAssistantOutputAt, isNull);

      final unknownOnly = await repository.stageConversationTimelinePage(
        target: target,
        subscriptionId: 'subscription-assistant-order',
        provider: 'codex',
        providerSessionId: 'thread-assistant-order',
        revision: 'timeline-3',
        baseRevision: 'timeline-2',
        mode: 'patch',
        pageIndex: 0,
        pageCount: 1,
        entries: [
          _assistantUnknownEntry(
            'assistant-unknown',
            3,
            receivedAt: '2026-07-30T00:03:30.000Z',
          ),
        ],
        deletes: const [],
        hasEarlier: false,
        sourceEntryCount: 4,
      );
      expect(unknownOnly.lastAssistantOutputAt, isNull);

      await repository.upsertResponse(
        target: target,
        response: RecentSessionsMessage(
          sessions: [_session(id: 'thread-assistant-order')],
          requestScope: 'catalog',
          offset: 0,
          hasMore: false,
        ),
      );
      expect(
        (await repository.load(target))?.sessions.single.lastAssistantOutputAt,
        '2026-07-30T00:02:00.000Z',
      );

      final movedSession = RecentSession.fromJson({
        ..._session(id: 'thread-assistant-order').toJson(),
        'projectPath': '/workspace/assistant-order-moved',
      });
      await repository.upsertResponse(
        target: target,
        response: RecentSessionsMessage(
          sessions: [movedSession],
          requestScope: 'list',
          offset: 20,
          hasMore: true,
        ),
      );
      final movedSnapshot = await repository.load(target);
      expect(movedSnapshot?.sessions, hasLength(1));
      expect(
        movedSnapshot?.sessions.single.projectPath,
        '/workspace/assistant-order-moved',
      );
      expect(
        movedSnapshot?.sessions.single.lastAssistantOutputAt,
        '2026-07-30T00:02:00.000Z',
      );

      await repository.applyConversationCatalogPage(
        target: target,
        codexSourceId: 'source-assistant-order',
        catalogState: 'catalog-2',
        pageIndex: 0,
        pageCount: 1,
        created: const [],
        updated: const [
          ConversationSyncV2CatalogEntry(
            provider: 'codex',
            providerSessionId: 'thread-assistant-order',
            revision: 'catalog-2',
            projectPath: '/workspace/assistant-order',
            firstPrompt: 'Order this thread',
            createdAt: '2026-07-30T00:00:00.000Z',
            modifiedAt: '2026-07-30T00:03:00.000Z',
            recencyAt: '2026-07-30T00:03:00.000Z',
            availability: 'durable',
          ),
        ],
        destroyed: const [],
      );
      expect(
        (await repository.load(target))?.sessions.single.lastAssistantOutputAt,
        '2026-07-30T00:02:00.000Z',
      );

      final second = await repository.stageConversationTimelinePage(
        target: target,
        subscriptionId: 'subscription-assistant-order',
        provider: 'codex',
        providerSessionId: 'thread-assistant-order',
        revision: 'timeline-4',
        baseRevision: 'timeline-3',
        mode: 'patch',
        pageIndex: 0,
        pageCount: 1,
        entries: [
          _assistantEntry(
            'assistant-2',
            4,
            text: 'Second visible update',
            receivedAt: '2026-07-30T00:04:00.000Z',
          ),
        ],
        deletes: const [],
        hasEarlier: false,
        sourceEntryCount: 5,
      );
      expect(second.lastAssistantOutputAt, '2026-07-30T00:04:00.000Z');
    },
  );

  test(
    'migrates v4 latest-turn metadata without rebuilding cached rows',
    () async {
      await repository.close();
      if (await File(databasePath).exists()) {
        await File(databasePath).delete();
      }
      final legacy = await databaseFactoryFfi.openDatabase(
        databasePath,
        options: OpenDatabaseOptions(
          version: 4,
          onCreate: (db, _) async {
            await db.execute('''
            CREATE TABLE ${SessionCatalogCacheDatabase.hotWindowsTable} (
              partition_id TEXT NOT NULL,
              provider TEXT NOT NULL,
              provider_session_id TEXT NOT NULL,
              revision TEXT NOT NULL,
              entry_count INTEGER NOT NULL,
              has_earlier INTEGER NOT NULL,
              turns_next_cursor TEXT,
              source_entry_count INTEGER NOT NULL,
              updated_at INTEGER NOT NULL
            )
          ''');
            await db.execute('''
            CREATE TABLE ${SessionCatalogCacheDatabase.timelineStagesTable} (
              partition_id TEXT NOT NULL,
              subscription_id TEXT NOT NULL,
              provider TEXT NOT NULL,
              provider_session_id TEXT NOT NULL,
              revision TEXT NOT NULL,
              base_revision TEXT,
              mode TEXT NOT NULL,
              page_count INTEGER NOT NULL,
              has_earlier INTEGER NOT NULL,
              turns_next_cursor TEXT,
              source_entry_count INTEGER NOT NULL,
              created_at INTEGER NOT NULL
            )
          ''');
          },
        ),
      );
      await legacy.close();

      database = SessionCatalogCacheDatabase(
        databasePath: databasePath,
        openDatabase: openFfi,
      );
      repository = SessionCatalogCacheRepository(database);
      final upgraded = await database.database;
      final hotColumns = await upgraded.rawQuery(
        'PRAGMA table_info(${SessionCatalogCacheDatabase.hotWindowsTable})',
      );
      final stageColumns = await upgraded.rawQuery(
        'PRAGMA table_info(${SessionCatalogCacheDatabase.timelineStagesTable})',
      );

      expect(
        hotColumns.map((column) => column['name']),
        contains('turns_next_cursor'),
      );
      expect(
        stageColumns.map((column) => column['name']),
        contains('turns_next_cursor'),
      );
      for (final columns in [hotColumns, stageColumns]) {
        final names = columns.map((column) => column['name']);
        expect(names, contains('latest_turn_complete'));
        expect(names, contains('latest_turn_gap_json'));
        expect(names, contains('latest_turn_gap_cursor'));
      }
    },
  );

  test(
    'rebuilds an incomplete latest turn with a separate resumable cursor',
    () async {
      final target = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: 'bridge-latest-turn',
        codexSourceId: 'source-latest-turn',
      );
      const gap = ConversationSyncV2LatestTurnGap(
        turnId: 'turn-current',
        missingEntryCount: 2,
        payloadOmitted: true,
        firstMissingSourceIndex: 10,
        repair: 'items_page',
      );
      await repository.stageConversationTimelinePage(
        target: target,
        subscriptionId: 'subscription-latest-turn',
        provider: 'codex',
        providerSessionId: 'thread-latest-turn',
        revision: 'revision-latest-turn',
        baseRevision: null,
        mode: 'snapshot',
        pageIndex: 0,
        pageCount: 1,
        entries: [_entry('current-entry', 0, 'running')],
        deletes: const [],
        hasEarlier: true,
        turnsNextCursor: 'older-turns-cursor',
        latestTurnComplete: false,
        latestTurnGap: gap,
        sourceEntryCount: 3,
      );

      final first = await repository.mergeConversationLatestTurnItemsPage(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-latest-turn',
        expectedRevision: 'revision-latest-turn',
        expectedTurnId: 'turn-current',
        rawMessages: const [
          {
            'type': 'user_input',
            'text': 'Current prompt',
            'userMessageUuid': 'user-current',
          },
        ],
        nextCursor: 'current-turn-page-2',
      );
      expect(first?.latestTurnComplete, isFalse);
      expect(first?.latestTurnGapCursor, 'current-turn-page-2');
      expect(first?.turnsNextCursor, 'older-turns-cursor');

      await repository.close();
      database = SessionCatalogCacheDatabase(
        databasePath: databasePath,
        openDatabase: openFfi,
      );
      repository = SessionCatalogCacheRepository(database);
      final rebuilt = await repository.loadConversationWindow(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-latest-turn',
      );
      expect(rebuilt?.latestTurnGap?.turnId, 'turn-current');
      expect(rebuilt?.latestTurnGapCursor, 'current-turn-page-2');
      expect(rebuilt?.turnsNextCursor, 'older-turns-cursor');

      final complete = await repository.mergeConversationLatestTurnItemsPage(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-latest-turn',
        expectedRevision: 'revision-latest-turn',
        expectedTurnId: 'turn-current',
        rawMessages: const [
          {
            'type': 'assistant',
            'message': {
              'id': 'assistant-current',
              'role': 'assistant',
              'content': [
                {'type': 'text', 'text': 'Current answer'},
              ],
            },
          },
        ],
        nextCursor: null,
      );
      expect(complete?.latestTurnComplete, isTrue);
      expect(complete?.latestTurnGap, isNull);
      expect(complete?.latestTurnGapCursor, isNull);
      expect(complete?.turnsNextCursor, 'older-turns-cursor');
      expect(
        complete?.entries.map((entry) => entry.entryId),
        containsAll([
          'current-entry',
          'user:user-current',
          'assistant:assistant-current',
        ]),
      );
    },
  );

  test(
    'falls back to safe latest-turn repair for damaged cache metadata',
    () async {
      final target = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: 'bridge-damaged-gap',
        codexSourceId: 'source-damaged-gap',
      );
      await repository.stageConversationTimelinePage(
        target: target,
        subscriptionId: 'subscription-damaged-gap',
        provider: 'codex',
        providerSessionId: 'thread-damaged-gap',
        revision: 'revision-damaged-gap',
        baseRevision: null,
        mode: 'snapshot',
        pageIndex: 0,
        pageCount: 1,
        entries: [_entry('entry-damaged-gap', 0, 'idle')],
        deletes: const [],
        hasEarlier: true,
        latestTurnComplete: false,
        latestTurnGap: const ConversationSyncV2LatestTurnGap(
          missingEntryCount: 1,
          payloadOmitted: false,
          repair: 'turns_page',
        ),
        sourceEntryCount: 2,
      );
      final db = await database.database;
      await db.update(SessionCatalogCacheDatabase.hotWindowsTable, {
        'latest_turn_gap_json': '{damaged',
      });

      final rebuilt = await repository.loadConversationWindow(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-damaged-gap',
      );
      expect(rebuilt?.latestTurnComplete, isFalse);
      expect(rebuilt?.latestTurnGap?.repair, 'turns_page');
      expect(rebuilt?.latestTurnGap?.turnId, isNull);
    },
  );

  test(
    'prepends turn pages idempotently and advances the stored cursor',
    () async {
      final target = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: 'bridge-turn-pages',
        codexSourceId: 'source-turn-pages',
      );
      await repository.stageConversationTimelinePage(
        target: target,
        subscriptionId: 'subscription-turn-pages',
        provider: 'codex',
        providerSessionId: 'thread-turn-pages',
        revision: 'revision-turn-pages',
        baseRevision: null,
        mode: 'snapshot',
        pageIndex: 0,
        pageCount: 1,
        entries: [_entry('current-entry', 0, 'idle')],
        deletes: const [],
        hasEarlier: true,
        turnsNextCursor: 'cursor-1',
        sourceEntryCount: 2,
      );

      final first = await repository.prependConversationTurnsPage(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-turn-pages',
        rawMessages: const [
          {
            'type': 'user_input',
            'text': 'Earlier prompt',
            'userMessageUuid': 'user-earlier',
          },
        ],
        nextCursor: 'cursor-2',
      );
      expect(first?.entries.map((entry) => entry.entryId), [
        'user:user-earlier',
        'current-entry',
      ]);
      expect(first?.turnsNextCursor, 'cursor-2');
      expect(first?.hasEarlier, isTrue);

      final repeated = await repository.prependConversationTurnsPage(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-turn-pages',
        rawMessages: const [
          {
            'type': 'user_input',
            'text': 'Earlier prompt',
            'userMessageUuid': 'user-earlier',
          },
        ],
        nextCursor: null,
      );
      expect(repeated?.entries.map((entry) => entry.entryId), [
        'user:user-earlier',
        'current-entry',
      ]);
      expect(repeated?.turnsNextCursor, isNull);
      expect(repeated?.hasEarlier, isFalse);
    },
  );

  test('rejects mutations after close begins', () async {
    final target = SessionCatalogCacheTarget.fromBridge(
      bridgeInstanceId: 'bridge-closed',
    );
    await repository.close();

    await expectLater(
      repository.upsertResponse(
        target: target,
        response: RecentSessionsMessage(
          sessions: [_session(id: 'thread-after-close')],
        ),
      ),
      throwsA(isA<StateError>()),
    );
  });
}

ConversationContentWireEntry _entry(String id, int index, String status) {
  return ConversationContentWireEntry(
    entryId: id,
    index: index,
    contentHash: 'hash-$id-$status',
    rawMessage: {'type': 'status', 'status': status},
  );
}

ConversationContentWireEntry _assistantEntry(
  String id,
  int index, {
  required String text,
  String? receivedAt,
}) => ConversationContentWireEntry(
  entryId: id,
  index: index,
  contentHash: 'hash-$id-$text',
  rawMessage: {
    'type': 'assistant',
    'receivedAt': ?receivedAt,
    'message': {
      'id': id,
      'role': 'assistant',
      'content': [
        {'type': 'text', 'text': text},
      ],
    },
  },
);

ConversationContentWireEntry _assistantToolEntry(
  String id,
  int index, {
  required String receivedAt,
}) => ConversationContentWireEntry(
  entryId: id,
  index: index,
  contentHash: 'hash-$id-tool',
  rawMessage: {
    'type': 'assistant',
    'receivedAt': receivedAt,
    'message': {
      'id': id,
      'role': 'assistant',
      'content': [
        {
          'type': 'tool_use',
          'id': 'tool-$id',
          'name': 'Read',
          'input': {'path': '/tmp/example'},
        },
      ],
    },
  },
);

ConversationContentWireEntry _assistantUnknownEntry(
  String id,
  int index, {
  required String receivedAt,
}) => ConversationContentWireEntry(
  entryId: id,
  index: index,
  contentHash: 'hash-$id-unknown',
  rawMessage: {
    'type': 'assistant',
    'receivedAt': receivedAt,
    'message': {
      'id': id,
      'role': 'assistant',
      'content': [
        {'type': 'future_tool_action', 'payload': 'ignored'},
      ],
    },
  },
);

RecentSession _session({
  required String id,
  String? name,
  String? forkedFromThreadId,
}) {
  return RecentSession(
    sessionId: id,
    provider: Provider.codex.value,
    rawPermissionMode: 'default',
    forkedFromThreadId: forkedFromThreadId,
    name: name,
    summary: 'Summary $id',
    firstPrompt: 'Prompt $id',
    lastPrompt: 'Last $id',
    created: '2026-07-25T12:00:00.000Z',
    modified: id == 'thread-b'
        ? '2026-07-25T12:02:00.000Z'
        : '2026-07-25T12:01:00.000Z',
    gitBranch: 'main',
    projectPath: '/workspace/project',
    resumeCwd: '/workspace/project',
    isSidechain: false,
    codexApprovalPolicy: CodexApprovalPolicy.onRequest.value,
    codexApprovalsReviewer: 'auto_review',
    codexPermissionsMode: CodexPermissionsMode.autoReview.value,
    executionMode: ExecutionMode.defaultMode.value,
    codexSandboxMode: 'workspace-write',
    codexModel: 'gpt-5.3-codex-spark',
    codexProfile: 'default',
    codexModelReasoningEffort: 'high',
    codexServiceTier: 'fast',
    codexNetworkAccessEnabled: true,
    codexWebSearchMode: 'live',
    codexAdditionalWritableRoots: const ['/tmp/extra'],
  );
}
