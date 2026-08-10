import 'dart:async';
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

  test('presentation revision ignores metadata-only cache commits', () {
    ConversationHotWindowSnapshot snapshot({
      required String revision,
      required String contentHash,
      required DateTime cachedAt,
    }) => ConversationHotWindowSnapshot(
      partitionId: 'partition',
      provider: Provider.codex.value,
      providerSessionId: 'thread',
      revision: revision,
      entries: [
        ConversationContentWireEntry(
          entryId: 'user-1',
          index: 0,
          contentHash: contentHash,
          rawMessage: const {'type': 'user_input', 'text': 'Cached prompt'},
        ),
      ],
      hasEarlier: false,
      turnsNextCursor: null,
      latestTurnComplete: true,
      latestTurnGap: null,
      latestTurnGapCursor: null,
      sourceEntryCount: 1,
      cachedAt: cachedAt,
    );

    final first = snapshot(
      revision: 'revision-1',
      contentHash: 'content-1',
      cachedAt: DateTime.utc(2026, 8, 10, 1),
    );
    final metadataOnly = snapshot(
      revision: 'revision-2',
      contentHash: 'content-1',
      cachedAt: DateTime.utc(2026, 8, 10, 2),
    );
    final changed = snapshot(
      revision: 'revision-3',
      contentHash: 'content-2',
      cachedAt: DateTime.utc(2026, 8, 10, 3),
    );

    expect(
      conversationPresentationRevision(metadataOnly),
      conversationPresentationRevision(first),
    );
    expect(
      conversationPresentationRevision(changed),
      isNot(conversationPresentationRevision(first)),
    );
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
      var userIndexStage = await repository.prepareConversationUserIndex(
        target: provisional,
        provider: 'codex',
        providerSessionId: 'thread-1',
        revision: 'user-index-complete',
      );
      userIndexStage = await repository.commitConversationUserIndexPage(
        target: provisional,
        provider: 'codex',
        providerSessionId: 'thread-1',
        revision: 'user-index-complete',
        expectedCursor: userIndexStage!.cursor,
        pageDepth: userIndexStage.pageDepth,
        nextCursor: null,
        entries: const [
          ConversationUserIndexPageEntry(
            providerTurnId: 'turn-1',
            providerItemId: 'user-item-1',
            rawMessage: {'type': 'user_input', 'text': 'partition-safe prompt'},
          ),
        ],
      );
      expect(userIndexStage?.complete, isTrue);
      var detailStage = await repository.prepareConversationUserTurnDetail(
        target: provisional,
        provider: 'codex',
        providerSessionId: 'thread-1',
        providerTurnId: 'turn-1',
        revision: 'detail-complete',
      );
      detailStage = await repository.commitConversationUserTurnDetailPage(
        target: provisional,
        provider: 'codex',
        providerSessionId: 'thread-1',
        providerTurnId: 'turn-1',
        revision: 'detail-complete',
        expectedCursor: detailStage!.cursor,
        pageDepth: detailStage.pageDepth,
        nextCursor: null,
        rawMessages: const [
          {
            'type': 'user_input',
            'text': 'partition-safe prompt',
            'providerItemId': 'user-item-1',
          },
        ],
      );
      expect(detailStage?.complete, isTrue);

      userIndexStage = await repository.prepareConversationUserIndex(
        target: provisional,
        provider: 'codex',
        providerSessionId: 'thread-1',
        revision: 'user-index-interrupted',
      );
      await repository.commitConversationUserIndexPage(
        target: provisional,
        provider: 'codex',
        providerSessionId: 'thread-1',
        revision: 'user-index-interrupted',
        expectedCursor: userIndexStage!.cursor,
        pageDepth: userIndexStage.pageDepth,
        nextCursor: 'not-finished',
        entries: const [],
      );
      detailStage = await repository.prepareConversationUserTurnDetail(
        target: provisional,
        provider: 'codex',
        providerSessionId: 'thread-1',
        providerTurnId: 'turn-interrupted',
        revision: 'detail-interrupted',
      );
      await repository.commitConversationUserTurnDetailPage(
        target: provisional,
        provider: 'codex',
        providerSessionId: 'thread-1',
        providerTurnId: 'turn-interrupted',
        revision: 'detail-interrupted',
        expectedCursor: detailStage!.cursor,
        pageDepth: detailStage.pageDepth,
        nextCursor: 'not-finished',
        rawMessages: const [],
      );

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
      final migratedIndex = await repository.loadConversationUserIndex(
        target: canonical,
        provider: 'codex',
        providerSessionId: 'thread-1',
      );
      expect(migratedIndex?.revision, 'user-index-complete');
      expect(migratedIndex?.complete, isTrue);
      expect(
        migratedIndex?.entries.single.message.text,
        'partition-safe prompt',
      );
      final migratedDetail = await repository.loadConversationUserTurnDetail(
        target: canonical,
        provider: 'codex',
        providerSessionId: 'thread-1',
        providerTurnId: 'turn-1',
      );
      expect(migratedDetail?.revision, 'detail-complete');
      expect(migratedDetail?.complete, isTrue);
      expect(migratedDetail?.messages, hasLength(1));
      expect(
        await repository.loadConversationUserTurnDetail(
          target: canonical,
          provider: 'codex',
          providerSessionId: 'thread-1',
          providerTurnId: 'turn-interrupted',
        ),
        isNull,
      );
      final db = await database.database;
      final migratedState = await db.query(
        SessionCatalogCacheDatabase.userIndexStatesTable,
        columns: ['active_revision', 'staging_revision'],
      );
      expect(migratedState.single['active_revision'], 'user-index-complete');
      expect(migratedState.single['staging_revision'], isNull);
      final partitionCount = Sqflite.firstIntValue(
        await db.rawQuery(
          'SELECT COUNT(*) FROM '
          '${SessionCatalogCacheDatabase.partitionsTable}',
        ),
      );
      expect(partitionCount, 1);
      expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
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

  test('thread reset preserves the last committed hot window', () async {
    final target = SessionCatalogCacheTarget.fromBridge(
      bridgeInstanceId: 'bridge-thread-reset',
      codexSourceId: 'source-thread-reset',
    );
    await repository.replaceConversationWindow(
      target: target,
      provider: 'codex',
      providerSessionId: 'thread-reset',
      revision: 'revision-before-reset',
      entries: [_entry('visible-before-reset', 0, 'running')],
      hasEarlier: true,
      sourceEntryCount: 10,
    );

    await repository.resetConversationSyncScope(
      target: target,
      scope: 'thread',
      thread: const ConversationSyncV2Target(
        provider: 'codex',
        providerSessionId: 'thread-reset',
      ),
    );

    final retained = await repository.loadConversationWindow(
      target: target,
      provider: 'codex',
      providerSessionId: 'thread-reset',
    );
    expect(retained?.revision, 'revision-before-reset');
    expect(retained?.entries.single.entryId, 'visible-before-reset');
  });

  test(
    'starting a refresh preserves the last committed priority cache',
    () async {
      final target = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: 'bridge-priority-refresh',
        codexSourceId: 'source-priority-refresh',
      );
      await repository.markConversationPriorityReady(target);

      await repository.beginConversationSync(
        target: target,
        subscriptionId: 'subscription-refresh',
      );

      expect(
        (await repository.loadConversationSyncState(target)).priorityReady,
        isTrue,
      );
    },
  );

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

  test(
    'persists Desktop project identity across sparse refreshes and moves',
    () async {
      final target = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: 'bridge-project-groups',
        codexSourceId: 'source-project-groups',
      );
      await repository.applyConversationCatalogBatch(
        target: target,
        codexSourceId: 'source-project-groups',
        catalogState: 'catalog-project-1',
        created: const [
          ConversationSyncV2CatalogEntry(
            provider: 'codex',
            providerSessionId: 'thread-project',
            revision: 'revision-project-1',
            projectPath: '/private/worktrees/feature-a',
            projectGroupKind: 'desktopProject',
            projectGroupId: 'project-ccpocket',
            projectGroupName: 'CC Pocket Mobile',
            projectGroupPath: '/workspace/ccpocket',
            projectGroupingSnapshotComplete: true,
            createdAt: '2026-08-09T00:00:00.000Z',
            modifiedAt: '2026-08-09T00:01:00.000Z',
            recencyAt: '2026-08-09T00:01:00.000Z',
            availability: 'durable',
          ),
        ],
        updated: const [],
        destroyed: const [],
      );

      await repository.upsertResponse(
        target: target,
        response: const RecentSessionsMessage(
          requestScope: 'catalog',
          sessions: [
            RecentSession(
              sessionId: 'thread-project',
              provider: 'codex',
              firstPrompt: 'Sparse refresh',
              created: '2026-08-09T00:00:00.000Z',
              modified: '2026-08-09T00:02:00.000Z',
              gitBranch: 'main',
              projectPath: '/private/worktrees/feature-a',
              isSidechain: false,
            ),
          ],
        ),
      );

      var session = (await repository.load(target))!.sessions.single;
      expect(session.projectGroupingKey, 'desktop-project:project-ccpocket');
      expect(session.projectName, 'CC Pocket Mobile');
      expect(session.effectiveProjectGroupPath, '/workspace/ccpocket');
      expect(session.projectGroupingSnapshotComplete, isTrue);

      await repository.applyConversationCatalogBatch(
        target: target,
        codexSourceId: 'source-project-groups',
        catalogState: 'catalog-project-2',
        created: const [],
        updated: const [
          ConversationSyncV2CatalogEntry(
            provider: 'codex',
            providerSessionId: 'thread-project',
            revision: 'revision-project-2',
            projectPath: '/private/worktrees/feature-a',
            projectGroupKind: 'projectless',
            projectGroupingSnapshotComplete: true,
            createdAt: '2026-08-09T00:00:00.000Z',
            modifiedAt: '2026-08-09T00:03:00.000Z',
            recencyAt: '2026-08-09T00:03:00.000Z',
            availability: 'durable',
          ),
        ],
        destroyed: const [],
      );

      session = (await repository.load(target))!.sessions.single;
      expect(session.projectGroupingKey, desktopProjectlessGroupingKey);
      expect(session.projectGroupId, isNull);
      expect(session.projectGroupName, isNull);
      expect(session.projectGroupingSnapshotComplete, isTrue);
    },
  );

  test(
    'preserves Claude Desktop grouping across sparse legacy refreshes',
    () async {
      final target = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: 'bridge-claude-project-groups',
        codexSourceId: 'source-claude-project-groups',
      );
      await repository.applyConversationCatalogBatch(
        target: target,
        codexSourceId: 'source-claude-project-groups',
        catalogState: 'catalog-claude-project-1',
        created: const [
          ConversationSyncV2CatalogEntry(
            provider: 'claude',
            providerSessionId: 'claude-project-thread',
            revision: 'revision-claude-project-1',
            projectPath: '/workspace/claude-project',
            projectGroupKind: 'desktopProject',
            projectGroupId: 'project-shared',
            projectGroupName: 'Shared Workspace',
            projectGroupPath: '/workspace/shared',
            projectGroupingSnapshotComplete: true,
            createdAt: '2026-08-09T00:00:00.000Z',
            modifiedAt: '2026-08-09T00:01:00.000Z',
            recencyAt: '2026-08-09T00:01:00.000Z',
            availability: 'durable',
          ),
        ],
        updated: const [],
        destroyed: const [],
      );

      await repository.upsertResponse(
        target: target,
        response: const RecentSessionsMessage(
          requestScope: 'catalog',
          sessions: [
            RecentSession(
              sessionId: 'claude-project-thread',
              provider: 'claude',
              firstPrompt: 'Sparse Claude refresh',
              created: '2026-08-09T00:00:00.000Z',
              modified: '2026-08-09T00:02:00.000Z',
              gitBranch: 'main',
              projectPath: '/workspace/claude-project',
              isSidechain: false,
            ),
          ],
        ),
      );

      var session = (await repository.load(target))!.sessions.single;
      expect(session.projectGroupingKey, 'desktop-project:project-shared');
      expect(session.projectName, 'Shared Workspace');
      expect(session.effectiveProjectGroupPath, '/workspace/shared');
      expect(session.projectGroupingSnapshotComplete, isTrue);

      await repository.applyConversationCatalogBatch(
        target: target,
        codexSourceId: 'source-claude-project-groups',
        catalogState: 'catalog-claude-project-2',
        created: const [],
        updated: const [
          ConversationSyncV2CatalogEntry(
            provider: 'claude',
            providerSessionId: 'claude-project-thread',
            revision: 'revision-claude-project-2',
            projectPath: '/workspace/claude-project',
            projectGroupKind: 'projectless',
            projectGroupingSnapshotComplete: true,
            createdAt: '2026-08-09T00:00:00.000Z',
            modifiedAt: '2026-08-09T00:03:00.000Z',
            recencyAt: '2026-08-09T00:03:00.000Z',
            availability: 'durable',
          ),
        ],
        destroyed: const [],
      );

      session = (await repository.load(target))!.sessions.single;
      expect(session.projectGroupingKey, desktopProjectlessGroupingKey);
      expect(session.projectGroupId, isNull);
      expect(session.projectGroupingSnapshotComplete, isTrue);
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

      final incompleteRefresh = await repository.stageConversationTimelinePage(
        target: target,
        subscriptionId: 'subscription-1',
        provider: 'codex',
        providerSessionId: 'thread-stage',
        revision: 'revision-3',
        baseRevision: null,
        mode: 'snapshot',
        pageIndex: 0,
        pageCount: 1,
        entries: const [],
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
      expect(incompleteRefresh.windowCommitted, isTrue);
      final preservedWindow = await repository.loadConversationWindow(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-stage',
      );
      expect(preservedWindow?.revision, 'revision-3');
      expect(preservedWindow?.latestTurnComplete, isFalse);
      expect(preservedWindow?.entries.map((entry) => entry.entryId), [
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
    'migrates v5 user caches and preserves them across close and reopen',
    () async {
      await repository.close();
      if (await File(databasePath).exists()) {
        await File(databasePath).delete();
      }
      final legacy = await databaseFactoryFfi.openDatabase(
        databasePath,
        options: OpenDatabaseOptions(
          version: 5,
          onCreate: (db, _) async {
            await db.execute('''
              CREATE TABLE ${SessionCatalogCacheDatabase.partitionsTable} (
                partition_id TEXT PRIMARY KEY,
                canonical_key TEXT UNIQUE,
                last_server_revision INTEGER,
                complete_revision INTEGER,
                updated_at INTEGER NOT NULL
              )
            ''');
            await db.execute('''
              CREATE TABLE ${SessionCatalogCacheDatabase.aliasesTable} (
                alias_key TEXT PRIMARY KEY,
                partition_id TEXT NOT NULL,
                updated_at INTEGER NOT NULL,
                FOREIGN KEY (partition_id)
                  REFERENCES ${SessionCatalogCacheDatabase.partitionsTable}
                    (partition_id)
                  ON DELETE CASCADE
              )
            ''');
            await db.insert(SessionCatalogCacheDatabase.partitionsTable, {
              'partition_id': 'legacy-v5-partition',
              'canonical_key': 'legacy-v5-partition',
              'updated_at': 1,
            });
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
      expect(await upgraded.getVersion(), 7);
      expect(
        await upgraded.query(
          SessionCatalogCacheDatabase.partitionsTable,
          where: 'partition_id = ?',
          whereArgs: ['legacy-v5-partition'],
        ),
        hasLength(1),
      );
      final tableNames = (await upgraded.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      )).map((row) => row['name']);
      expect(
        tableNames,
        containsAll([
          SessionCatalogCacheDatabase.userIndexStatesTable,
          SessionCatalogCacheDatabase.userIndexEntriesTable,
          SessionCatalogCacheDatabase.userTurnDetailsTable,
          SessionCatalogCacheDatabase.userTurnDetailItemsTable,
        ]),
      );
      final itemForeignKeys = await upgraded.rawQuery(
        'PRAGMA foreign_key_list('
        '${SessionCatalogCacheDatabase.userTurnDetailItemsTable})',
      );
      expect(
        itemForeignKeys.where(
          (row) => row['from'] == 'revision' && row['to'] == 'revision',
        ),
        isNotEmpty,
      );

      final target = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: 'bridge-v5-upgrade',
      );
      var indexStage = await repository.prepareConversationUserIndex(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-v5-upgrade',
        revision: 'index-v6',
      );
      await repository.commitConversationUserIndexPage(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-v5-upgrade',
        revision: 'index-v6',
        expectedCursor: indexStage!.cursor,
        pageDepth: indexStage.pageDepth,
        nextCursor: null,
        entries: const [
          ConversationUserIndexPageEntry(
            providerTurnId: 'turn-v5-upgrade',
            providerItemId: 'item-v5-upgrade',
            rawMessage: {'type': 'user_input', 'text': 'survives reopen'},
          ),
        ],
      );
      var detailStage = await repository.prepareConversationUserTurnDetail(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-v5-upgrade',
        providerTurnId: 'turn-v5-upgrade',
        revision: 'detail-v6',
      );
      await repository.commitConversationUserTurnDetailPage(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-v5-upgrade',
        providerTurnId: 'turn-v5-upgrade',
        revision: 'detail-v6',
        expectedCursor: detailStage!.cursor,
        pageDepth: detailStage.pageDepth,
        nextCursor: null,
        rawMessages: const [
          {'type': 'user_input', 'text': 'survives reopen'},
        ],
      );

      await repository.close();
      database = SessionCatalogCacheDatabase(
        databasePath: databasePath,
        openDatabase: openFfi,
      );
      repository = SessionCatalogCacheRepository(database);
      final reopenedIndex = await repository.loadConversationUserIndex(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-v5-upgrade',
      );
      final reopenedDetail = await repository.loadConversationUserTurnDetail(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-v5-upgrade',
        providerTurnId: 'turn-v5-upgrade',
      );
      expect(reopenedIndex?.revision, 'index-v6');
      expect(reopenedIndex?.entries.single.message.text, 'survives reopen');
      expect(reopenedDetail?.revision, 'detail-v6');
      expect(reopenedDetail?.complete, isTrue);
      expect(
        await (await database.database).rawQuery('PRAGMA foreign_key_check'),
        isEmpty,
      );
    },
  );

  test('repairs the legacy v6 turn-detail key without losing rows', () async {
    await repository.close();
    if (await File(databasePath).exists()) {
      await File(databasePath).delete();
    }
    final legacy = await databaseFactoryFfi.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: 6,
        onCreate: (db, _) async {
          await db.execute('PRAGMA foreign_keys = ON');
          await db.execute('''
            CREATE TABLE ${SessionCatalogCacheDatabase.partitionsTable} (
              partition_id TEXT PRIMARY KEY,
              canonical_key TEXT UNIQUE,
              last_server_revision INTEGER,
              complete_revision INTEGER,
              updated_at INTEGER NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE ${SessionCatalogCacheDatabase.userIndexStatesTable} (
              partition_id TEXT NOT NULL,
              provider TEXT NOT NULL,
              provider_session_id TEXT NOT NULL,
              active_revision TEXT,
              active_complete INTEGER NOT NULL DEFAULT 0,
              staging_revision TEXT,
              staging_cursor TEXT,
              staging_page_depth INTEGER NOT NULL DEFAULT 0,
              updated_at INTEGER NOT NULL,
              PRIMARY KEY (partition_id, provider, provider_session_id),
              FOREIGN KEY (partition_id)
                REFERENCES ${SessionCatalogCacheDatabase.partitionsTable}
                  (partition_id)
                ON DELETE CASCADE
            )
          ''');
          await db.execute('''
            CREATE TABLE ${SessionCatalogCacheDatabase.userTurnDetailsTable} (
              partition_id TEXT NOT NULL,
              provider TEXT NOT NULL,
              provider_session_id TEXT NOT NULL,
              provider_turn_id TEXT NOT NULL,
              revision TEXT NOT NULL,
              next_cursor TEXT,
              page_depth INTEGER NOT NULL DEFAULT 0,
              complete INTEGER NOT NULL,
              updated_at INTEGER NOT NULL,
              PRIMARY KEY (
                partition_id,
                provider,
                provider_session_id,
                provider_turn_id
              ),
              FOREIGN KEY (partition_id, provider, provider_session_id)
                REFERENCES ${SessionCatalogCacheDatabase.userIndexStatesTable} (
                  partition_id,
                  provider,
                  provider_session_id
                )
                ON DELETE CASCADE
            )
          ''');
          await db.execute('''
            CREATE TABLE ${SessionCatalogCacheDatabase.userTurnDetailItemsTable} (
              partition_id TEXT NOT NULL,
              provider TEXT NOT NULL,
              provider_session_id TEXT NOT NULL,
              provider_turn_id TEXT NOT NULL,
              revision TEXT NOT NULL,
              page_depth INTEGER NOT NULL,
              item_order INTEGER NOT NULL,
              message_json TEXT NOT NULL,
              PRIMARY KEY (
                partition_id,
                provider,
                provider_session_id,
                provider_turn_id,
                revision,
                page_depth,
                item_order
              ),
              FOREIGN KEY (
                partition_id,
                provider,
                provider_session_id,
                provider_turn_id
              ) REFERENCES ${SessionCatalogCacheDatabase.userTurnDetailsTable} (
                partition_id,
                provider,
                provider_session_id,
                provider_turn_id
              ) ON DELETE CASCADE
            )
          ''');
          await db.insert(SessionCatalogCacheDatabase.partitionsTable, {
            'partition_id': 'legacy-v6-partition',
            'canonical_key': 'legacy-v6-partition',
            'updated_at': 1,
          });
          await db.insert(SessionCatalogCacheDatabase.userIndexStatesTable, {
            'partition_id': 'legacy-v6-partition',
            'provider': 'codex',
            'provider_session_id': 'legacy-v6-thread',
            'active_revision': 'legacy-v6-index',
            'active_complete': 1,
            'staging_revision': null,
            'staging_cursor': null,
            'staging_page_depth': 0,
            'updated_at': 1,
          });
          await db.insert(SessionCatalogCacheDatabase.userTurnDetailsTable, {
            'partition_id': 'legacy-v6-partition',
            'provider': 'codex',
            'provider_session_id': 'legacy-v6-thread',
            'provider_turn_id': 'legacy-v6-turn',
            'revision': 'legacy-v6-revision',
            'next_cursor': null,
            'page_depth': 1,
            'complete': 1,
            'updated_at': 1,
          });
          await db
              .insert(SessionCatalogCacheDatabase.userTurnDetailItemsTable, {
                'partition_id': 'legacy-v6-partition',
                'provider': 'codex',
                'provider_session_id': 'legacy-v6-thread',
                'provider_turn_id': 'legacy-v6-turn',
                'revision': 'legacy-v6-revision',
                'page_depth': 0,
                'item_order': 0,
                'message_json': '{"type":"user_input","text":"legacy"}',
              });
        },
      ),
    );
    await legacy.close();

    database = SessionCatalogCacheDatabase(
      databasePath: databasePath,
      openDatabase: openFfi,
    );
    repository = SessionCatalogCacheRepository(database);
    final repaired = await database.database;
    expect(await repaired.getVersion(), 7);
    final detailColumns = await repaired.rawQuery(
      'PRAGMA table_info(${SessionCatalogCacheDatabase.userTurnDetailsTable})',
    );
    expect(
      detailColumns.singleWhere((column) => column['name'] == 'revision')['pk'],
      5,
    );
    expect(
      await repaired.query(SessionCatalogCacheDatabase.userTurnDetailsTable),
      hasLength(1),
    );
    expect(
      await repaired.query(
        SessionCatalogCacheDatabase.userTurnDetailItemsTable,
      ),
      hasLength(1),
    );
    final repairedIndexState = await repaired.query(
      SessionCatalogCacheDatabase.userIndexStatesTable,
      columns: ['active_revision', 'active_complete', 'staging_revision'],
    );
    expect(repairedIndexState.single['active_revision'], isNull);
    expect(repairedIndexState.single['active_complete'], 0);
    expect(repairedIndexState.single['staging_revision'], isNull);
    await repaired.insert(SessionCatalogCacheDatabase.userTurnDetailsTable, {
      'partition_id': 'legacy-v6-partition',
      'provider': 'codex',
      'provider_session_id': 'legacy-v6-thread',
      'provider_turn_id': 'legacy-v6-turn',
      'revision': 'second-v6-revision',
      'next_cursor': null,
      'page_depth': 0,
      'complete': 0,
      'updated_at': 2,
    });
    expect(
      await repaired.query(SessionCatalogCacheDatabase.userTurnDetailsTable),
      hasLength(2),
    );
    expect(await repaired.rawQuery('PRAGMA foreign_key_check'), isEmpty);
  });

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
        expectedRevision: 'revision-turn-pages',
        expectedCursor: 'cursor-1',
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
        expectedRevision: 'revision-turn-pages',
        expectedCursor: 'cursor-2',
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

  test(
    'prepends different provider users even when legacy UUIDs collide',
    () async {
      final target = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: 'bridge-provider-user-pages',
        codexSourceId: 'source-provider-user-pages',
      );
      await repository.stageConversationTimelinePage(
        target: target,
        subscriptionId: 'subscription-provider-user-pages',
        provider: 'codex',
        providerSessionId: 'thread-provider-user-pages',
        revision: 'revision-provider-user-pages',
        baseRevision: null,
        mode: 'snapshot',
        pageIndex: 0,
        pageCount: 1,
        entries: [_entry('current-entry', 0, 'idle')],
        deletes: const [],
        hasEarlier: true,
        turnsNextCursor: 'cursor-provider-users',
        sourceEntryCount: 3,
      );

      final snapshot = await repository.prependConversationTurnsPage(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-provider-user-pages',
        expectedRevision: 'revision-provider-user-pages',
        expectedCursor: 'cursor-provider-users',
        rawMessages: const [
          {
            'type': 'user_input',
            'text': 'first prompt',
            'providerItemId': 'provider-user-first',
            'userMessageUuid': 'codex:user-turn:1',
          },
          {
            'type': 'user_input',
            'text': 'second prompt',
            'providerItemId': 'provider-user-second',
            'userMessageUuid': 'codex:user-turn:1',
          },
        ],
        nextCursor: null,
      );

      expect(snapshot?.entries.map((entry) => entry.entryId), [
        'user-provider:provider-user-first',
        'user-provider:provider-user-second',
        'current-entry',
      ]);
    },
  );

  test(
    'rejects an older turn page after the canonical window revision advances',
    () async {
      final target = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: 'bridge-stale-turn-page',
        codexSourceId: 'source-stale-turn-page',
      );
      await repository.stageConversationTimelinePage(
        target: target,
        subscriptionId: 'subscription-stale-turn-page-r1',
        provider: 'codex',
        providerSessionId: 'thread-stale-turn-page',
        revision: 'revision-one',
        baseRevision: null,
        mode: 'snapshot',
        pageIndex: 0,
        pageCount: 1,
        entries: [_entry('current-r1', 0, 'idle')],
        deletes: const [],
        hasEarlier: true,
        turnsNextCursor: 'cursor-one',
        sourceEntryCount: 2,
      );

      await repository.stageConversationTimelinePage(
        target: target,
        subscriptionId: 'subscription-stale-turn-page-r2',
        provider: 'codex',
        providerSessionId: 'thread-stale-turn-page',
        revision: 'revision-two',
        baseRevision: null,
        mode: 'snapshot',
        pageIndex: 0,
        pageCount: 1,
        entries: [_entry('current-r2', 0, 'working')],
        deletes: const [],
        hasEarlier: true,
        turnsNextCursor: 'cursor-two',
        sourceEntryCount: 2,
      );

      final stale = await repository.prependConversationTurnsPage(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-stale-turn-page',
        expectedRevision: 'revision-one',
        expectedCursor: 'cursor-one',
        rawMessages: const [
          {
            'type': 'user_input',
            'text': 'stale earlier prompt',
            'userMessageUuid': 'stale-user',
          },
        ],
        nextCursor: null,
      );

      expect(stale, isNull);
      final current = await repository.loadConversationWindow(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-stale-turn-page',
      );
      expect(current?.revision, 'revision-two');
      expect(current?.turnsNextCursor, 'cursor-two');
      expect(current?.entries.map((entry) => entry.entryId), ['current-r2']);
    },
  );

  test(
    'prepends legacy page identities separately for distinct provider turns',
    () async {
      final target = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: 'bridge-legacy-turn-pages',
        codexSourceId: 'source-legacy-turn-pages',
      );
      await repository.stageConversationTimelinePage(
        target: target,
        subscriptionId: 'subscription-legacy-turn-pages',
        provider: 'codex',
        providerSessionId: 'thread-legacy-turn-pages',
        revision: 'revision-legacy-turn-pages',
        baseRevision: null,
        mode: 'snapshot',
        pageIndex: 0,
        pageCount: 1,
        entries: [_entry('current-entry', 0, 'idle')],
        deletes: const [],
        hasEarlier: true,
        turnsNextCursor: 'cursor-legacy-turn-pages',
        sourceEntryCount: 3,
      );

      final snapshot = await repository.prependConversationTurnsPage(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-legacy-turn-pages',
        expectedRevision: 'revision-legacy-turn-pages',
        expectedCursor: 'cursor-legacy-turn-pages',
        rawMessages: const [
          {
            'type': 'user_input',
            'text': 'first prompt',
            'userMessageUuid': 'codex:user-turn:1',
            'historyTurnId': 'provider-turn-first',
          },
          {
            'type': 'user_input',
            'text': 'second prompt',
            'userMessageUuid': 'codex:user-turn:1',
            'historyTurnId': 'provider-turn-second',
          },
          {
            'type': 'assistant',
            'messageUuid': 'codex-item-1',
            'historyTurnId': 'provider-turn-first',
            'message': {
              'id': 'codex-item-1',
              'role': 'assistant',
              'content': [
                {'type': 'text', 'text': 'first answer'},
              ],
              'model': '',
            },
          },
          {
            'type': 'assistant',
            'messageUuid': 'codex-item-1',
            'historyTurnId': 'provider-turn-second',
            'message': {
              'id': 'codex-item-1',
              'role': 'assistant',
              'content': [
                {'type': 'text', 'text': 'second answer'},
              ],
              'model': '',
            },
          },
        ],
        nextCursor: null,
      );

      expect(snapshot?.entries.map((entry) => entry.entryId), [
        'turn:provider-turn-first:user:codex:user-turn:1',
        'turn:provider-turn-second:user:codex:user-turn:1',
        'turn:provider-turn-first:assistant:codex-item-1',
        'turn:provider-turn-second:assistant:codex-item-1',
        'current-entry',
      ]);
    },
  );

  test(
    'user index keeps the active revision visible until staging completes',
    () async {
      final target = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: 'bridge-user-index-stage',
        codexSourceId: 'source-user-index-stage',
      );
      var stage = await repository.prepareConversationUserIndex(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-user-index-stage',
        revision: 'revision-1',
      );
      stage = await repository.commitConversationUserIndexPage(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-user-index-stage',
        revision: 'revision-1',
        expectedCursor: stage!.cursor,
        pageDepth: stage.pageDepth,
        nextCursor: null,
        entries: const [
          ConversationUserIndexPageEntry(
            providerTurnId: 'turn-old',
            providerItemId: 'item-old',
            rawMessage: {
              'type': 'user_input',
              'text': 'old active prompt',
              'timestamp': '2026-08-01T01:02:03.000Z',
            },
          ),
        ],
      );
      expect(stage?.complete, isTrue);
      final firstState = await repository.loadConversationUserIndexState(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-user-index-stage',
      );
      expect(firstState?.revision, 'revision-1');
      expect(firstState?.complete, isTrue);

      stage = await repository.prepareConversationUserIndex(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-user-index-stage',
        revision: 'revision-2',
      );
      stage = await repository.commitConversationUserIndexPage(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-user-index-stage',
        revision: 'revision-2',
        expectedCursor: stage!.cursor,
        pageDepth: stage.pageDepth,
        nextCursor: 'older-page',
        entries: const [
          ConversationUserIndexPageEntry(
            providerTurnId: 'turn-new',
            providerItemId: 'item-new',
            rawMessage: {
              'type': 'user_input',
              'text': 'newest prompt',
              'timestamp': '2026-08-02T01:02:03.000Z',
            },
          ),
          ConversationUserIndexPageEntry(
            providerTurnId: 'turn-middle-new',
            providerItemId: 'item-middle-new',
            rawMessage: {
              'type': 'user_input',
              'text': 'middle newer prompt',
              'timestamp': '2026-08-01T01:02:03.000Z',
            },
          ),
        ],
      );
      final whileStaging = await repository.loadConversationUserIndex(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-user-index-stage',
      );
      expect(whileStaging?.revision, 'revision-1');
      expect(whileStaging?.entries.single.message.text, 'old active prompt');
      final stagingState = await repository.loadConversationUserIndexState(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-user-index-stage',
      );
      expect(stagingState?.revision, 'revision-1');
      expect(stagingState?.complete, isTrue);

      stage = await repository.commitConversationUserIndexPage(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-user-index-stage',
        revision: 'revision-2',
        expectedCursor: stage!.cursor,
        pageDepth: stage.pageDepth,
        nextCursor: null,
        entries: const [
          ConversationUserIndexPageEntry(
            providerTurnId: 'turn-middle-old',
            providerItemId: 'item-middle-old',
            rawMessage: {
              'type': 'user_input',
              'text': 'middle older prompt',
              'timestamp': '2026-07-31T01:02:03.000Z',
            },
          ),
          ConversationUserIndexPageEntry(
            providerTurnId: 'turn-oldest',
            providerItemId: 'item-oldest',
            rawMessage: {
              'type': 'user_input',
              'text': 'oldest prompt',
              'timestamp': '2026-07-30T01:02:03.000Z',
            },
          ),
        ],
      );
      final completed = await repository.loadConversationUserIndex(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-user-index-stage',
      );
      expect(completed?.revision, 'revision-2');
      expect(completed?.complete, isTrue);
      final completedState = await repository.loadConversationUserIndexState(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-user-index-stage',
      );
      expect(completedState?.revision, 'revision-2');
      expect(completedState?.complete, isTrue);
      expect(completed?.entries.map((entry) => entry.providerTurnId), [
        'turn-oldest',
        'turn-middle-old',
        'turn-middle-new',
        'turn-new',
      ]);
      expect(completed?.entries.map((entry) => entry.message.providerItemId), [
        'item-oldest',
        'item-middle-old',
        'item-middle-new',
        'item-new',
      ]);
    },
  );

  test(
    'new revisions discard interrupted staging rows for one thread',
    () async {
      final target = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: 'bridge-staging-cleanup',
        codexSourceId: 'source-staging-cleanup',
      );
      var indexStage = await repository.prepareConversationUserIndex(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-staging-cleanup',
        revision: 'index-interrupted',
      );
      await repository.commitConversationUserIndexPage(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-staging-cleanup',
        revision: 'index-interrupted',
        expectedCursor: indexStage!.cursor,
        pageDepth: indexStage.pageDepth,
        nextCursor: 'older-index-page',
        entries: const [
          ConversationUserIndexPageEntry(
            providerTurnId: 'turn-interrupted',
            providerItemId: 'item-interrupted',
            rawMessage: {'type': 'user_input', 'text': 'interrupted index'},
          ),
        ],
      );
      var detailStage = await repository.prepareConversationUserTurnDetail(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-staging-cleanup',
        providerTurnId: 'turn-interrupted',
        revision: 'detail-interrupted',
      );
      await repository.commitConversationUserTurnDetailPage(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-staging-cleanup',
        providerTurnId: 'turn-interrupted',
        revision: 'detail-interrupted',
        expectedCursor: detailStage!.cursor,
        pageDepth: detailStage.pageDepth,
        nextCursor: 'older-detail-page',
        rawMessages: const [
          {'type': 'user_input', 'text': 'interrupted detail'},
        ],
      );

      indexStage = await repository.prepareConversationUserIndex(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-staging-cleanup',
        revision: 'index-current',
      );
      detailStage = await repository.prepareConversationUserTurnDetail(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-staging-cleanup',
        providerTurnId: 'turn-current',
        revision: 'detail-current',
      );
      expect(indexStage?.revision, 'index-current');
      expect(detailStage?.revision, 'detail-current');

      final db = await database.database;
      for (final table in [
        SessionCatalogCacheDatabase.userIndexEntriesTable,
        SessionCatalogCacheDatabase.userTurnDetailsTable,
        SessionCatalogCacheDatabase.userTurnDetailItemsTable,
      ]) {
        expect(
          Sqflite.firstIntValue(
            await db.rawQuery(
              'SELECT COUNT(*) FROM $table WHERE revision LIKE ?',
              ['%-interrupted'],
            ),
          ),
          0,
        );
      }
      expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    },
  );

  test(
    'user index scopes legacy UUID fallback by provider turn without overwriting',
    () async {
      final target = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: 'bridge-user-index-turn-scope',
        codexSourceId: 'source-user-index-turn-scope',
      );
      var stage = await repository.prepareConversationUserIndex(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-user-index-turn-scope',
        revision: 'revision-turn-scope',
      );
      stage = await repository.commitConversationUserIndexPage(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-user-index-turn-scope',
        revision: 'revision-turn-scope',
        expectedCursor: stage!.cursor,
        pageDepth: stage.pageDepth,
        nextCursor: null,
        entries: const [
          ConversationUserIndexPageEntry(
            providerTurnId: 'turn-a',
            providerItemId: null,
            rawMessage: {
              'type': 'user_input',
              'text': 'same legacy prompt A',
              'userMessageUuid': 'codex:user-turn:1',
            },
          ),
          ConversationUserIndexPageEntry(
            providerTurnId: 'turn-b',
            providerItemId: null,
            rawMessage: {
              'type': 'user_input',
              'text': 'same legacy prompt B',
              'userMessageUuid': 'codex:user-turn:1',
            },
          ),
        ],
      );
      expect(stage?.complete, isTrue);

      final snapshot = await repository.loadConversationUserIndex(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-user-index-turn-scope',
      );
      expect(snapshot?.entries, hasLength(2));
      expect(snapshot?.entries.map((entry) => entry.providerTurnId), [
        'turn-b',
        'turn-a',
      ]);
      expect(
        snapshot?.entries.every((entry) => entry.providerItemId == null),
        isTrue,
      );
      expect(snapshot?.entries.map((entry) => entry.message.historyTurnId), [
        'turn-b',
        'turn-a',
      ]);
    },
  );

  test(
    'turn detail pages persist in provider order and resume safely',
    () async {
      final target = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: 'bridge-turn-detail',
        codexSourceId: 'source-turn-detail',
      );
      var stage = await repository.prepareConversationUserTurnDetail(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-turn-detail',
        providerTurnId: 'turn-target',
        revision: 'revision-detail',
      );
      stage = await repository.commitConversationUserTurnDetailPage(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-turn-detail',
        providerTurnId: 'turn-target',
        revision: 'revision-detail',
        expectedCursor: stage!.cursor,
        pageDepth: stage.pageDepth,
        nextCursor: 'page-2',
        rawMessages: const [
          {
            'type': 'user_input',
            'text': 'target prompt',
            'providerItemId': 'target-user-item',
          },
        ],
      );
      stage = await repository.commitConversationUserTurnDetailPage(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-turn-detail',
        providerTurnId: 'turn-target',
        revision: 'revision-detail',
        expectedCursor: stage!.cursor,
        pageDepth: stage.pageDepth,
        nextCursor: null,
        rawMessages: const [
          {
            'type': 'assistant',
            'message': {
              'id': 'assistant-target',
              'role': 'assistant',
              'content': [
                {'type': 'text', 'text': 'target answer'},
              ],
            },
          },
        ],
      );
      expect(stage?.complete, isTrue);

      final detail = await repository.loadConversationUserTurnDetail(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-turn-detail',
        providerTurnId: 'turn-target',
      );
      expect(detail?.complete, isTrue);
      expect(detail?.messages, hasLength(2));
      expect(
        (detail?.messages.first as UserInputMessage).historyTurnId,
        'turn-target',
      );
      expect(
        (detail?.messages.last as AssistantServerMessage).historyTurnId,
        'turn-target',
      );

      var replacement = await repository.prepareConversationUserTurnDetail(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-turn-detail',
        providerTurnId: 'turn-target',
        revision: 'newer-catalog-revision',
      );
      expect(replacement?.complete, isFalse);
      expect(replacement?.revision, 'newer-catalog-revision');
      expect(
        (await repository.loadConversationUserTurnDetail(
          target: target,
          provider: 'codex',
          providerSessionId: 'thread-turn-detail',
          providerTurnId: 'turn-target',
        ))?.revision,
        'revision-detail',
      );

      replacement = await repository.commitConversationUserTurnDetailPage(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-turn-detail',
        providerTurnId: 'turn-target',
        revision: 'newer-catalog-revision',
        expectedCursor: replacement!.cursor,
        pageDepth: replacement.pageDepth,
        nextCursor: 'newer-page-2',
        rawMessages: const [
          {'type': 'user_input', 'text': 'newer prompt'},
        ],
      );
      expect(
        (await repository.loadConversationUserTurnDetail(
          target: target,
          provider: 'codex',
          providerSessionId: 'thread-turn-detail',
          providerTurnId: 'turn-target',
        ))?.revision,
        'revision-detail',
      );
      replacement = await repository.commitConversationUserTurnDetailPage(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-turn-detail',
        providerTurnId: 'turn-target',
        revision: 'newer-catalog-revision',
        expectedCursor: replacement!.cursor,
        pageDepth: replacement.pageDepth,
        nextCursor: null,
        rawMessages: const [
          {
            'type': 'assistant',
            'message': {
              'id': 'assistant-newer',
              'role': 'assistant',
              'content': [
                {'type': 'text', 'text': 'newer answer'},
              ],
            },
          },
        ],
      );
      expect(replacement?.complete, isTrue);
      final replaced = await repository.loadConversationUserTurnDetail(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-turn-detail',
        providerTurnId: 'turn-target',
      );
      expect(replaced?.revision, 'newer-catalog-revision');
      expect(
        (replaced?.messages.first as UserInputMessage).text,
        'newer prompt',
      );
      final db = await database.database;
      expect(
        Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM '
            '${SessionCatalogCacheDatabase.userTurnDetailsTable} '
            'WHERE provider_turn_id = ?',
            ['turn-target'],
          ),
        ),
        1,
      );
    },
  );

  test(
    'user cache readers keep one SQLite snapshot during revision publish',
    () async {
      final target = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: 'bridge-read-snapshot',
        codexSourceId: 'source-read-snapshot',
      );
      var indexStage = await repository.prepareConversationUserIndex(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-read-snapshot',
        revision: 'index-old',
      );
      indexStage = await repository.commitConversationUserIndexPage(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-read-snapshot',
        revision: 'index-old',
        expectedCursor: indexStage!.cursor,
        pageDepth: indexStage.pageDepth,
        nextCursor: null,
        entries: const [
          ConversationUserIndexPageEntry(
            providerTurnId: 'turn-read-snapshot',
            providerItemId: 'item-index-old',
            rawMessage: {'type': 'user_input', 'text': 'old index'},
          ),
        ],
      );
      indexStage = await repository.prepareConversationUserIndex(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-read-snapshot',
        revision: 'index-new',
      );
      indexStage = await repository.commitConversationUserIndexPage(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-read-snapshot',
        revision: 'index-new',
        expectedCursor: indexStage!.cursor,
        pageDepth: indexStage.pageDepth,
        nextCursor: 'index-page-2',
        entries: const [
          ConversationUserIndexPageEntry(
            providerTurnId: 'turn-read-snapshot',
            providerItemId: 'item-index-new',
            rawMessage: {'type': 'user_input', 'text': 'new index'},
          ),
        ],
      );

      var detailStage = await repository.prepareConversationUserTurnDetail(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-read-snapshot',
        providerTurnId: 'turn-read-snapshot',
        revision: 'detail-old',
      );
      detailStage = await repository.commitConversationUserTurnDetailPage(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-read-snapshot',
        providerTurnId: 'turn-read-snapshot',
        revision: 'detail-old',
        expectedCursor: detailStage!.cursor,
        pageDepth: detailStage.pageDepth,
        nextCursor: null,
        rawMessages: const [
          {'type': 'user_input', 'text': 'old detail'},
        ],
      );
      detailStage = await repository.prepareConversationUserTurnDetail(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-read-snapshot',
        providerTurnId: 'turn-read-snapshot',
        revision: 'detail-new',
      );
      detailStage = await repository.commitConversationUserTurnDetailPage(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-read-snapshot',
        providerTurnId: 'turn-read-snapshot',
        revision: 'detail-new',
        expectedCursor: detailStage!.cursor,
        pageDepth: detailStage.pageDepth,
        nextCursor: 'detail-page-2',
        rawMessages: const [
          {'type': 'user_input', 'text': 'new detail'},
        ],
      );

      await repository.close();
      Future<void> Function()? readBarrier;
      database = SessionCatalogCacheDatabase(
        databasePath: databasePath,
        openDatabase: openFfi,
      );
      repository = SessionCatalogCacheRepository(
        database,
        userCacheReadBarrierForTesting: () async {
          await readBarrier?.call();
        },
      );

      final indexReadReached = Completer<void>();
      final releaseIndexRead = Completer<void>();
      readBarrier = () async {
        indexReadReached.complete();
        await releaseIndexRead.future;
      };
      final oldIndexRead = repository.loadConversationUserIndex(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-read-snapshot',
      );
      await indexReadReached.future;
      readBarrier = null;
      var indexPublishCompleted = false;
      final indexPublish = repository
          .commitConversationUserIndexPage(
            target: target,
            provider: 'codex',
            providerSessionId: 'thread-read-snapshot',
            revision: 'index-new',
            expectedCursor: indexStage!.cursor,
            pageDepth: indexStage.pageDepth,
            nextCursor: null,
            entries: const [],
          )
          .whenComplete(() => indexPublishCompleted = true);
      await Future<void>.delayed(Duration.zero);
      expect(indexPublishCompleted, isFalse);
      releaseIndexRead.complete();
      final oldIndex = await oldIndexRead;
      expect(oldIndex?.revision, 'index-old');
      expect(oldIndex?.entries.single.message.text, 'old index');
      await indexPublish;
      final newIndex = await repository.loadConversationUserIndex(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-read-snapshot',
      );
      expect(newIndex?.revision, 'index-new');
      expect(newIndex?.entries.single.message.text, 'new index');

      final detailReadReached = Completer<void>();
      final releaseDetailRead = Completer<void>();
      readBarrier = () async {
        detailReadReached.complete();
        await releaseDetailRead.future;
      };
      final oldDetailRead = repository.loadConversationUserTurnDetail(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-read-snapshot',
        providerTurnId: 'turn-read-snapshot',
      );
      await detailReadReached.future;
      readBarrier = null;
      var detailPublishCompleted = false;
      final detailPublish = repository
          .commitConversationUserTurnDetailPage(
            target: target,
            provider: 'codex',
            providerSessionId: 'thread-read-snapshot',
            providerTurnId: 'turn-read-snapshot',
            revision: 'detail-new',
            expectedCursor: detailStage!.cursor,
            pageDepth: detailStage.pageDepth,
            nextCursor: null,
            rawMessages: const [],
          )
          .whenComplete(() => detailPublishCompleted = true);
      await Future<void>.delayed(Duration.zero);
      expect(detailPublishCompleted, isFalse);
      releaseDetailRead.complete();
      final oldDetail = await oldDetailRead;
      expect(oldDetail?.revision, 'detail-old');
      expect(
        (oldDetail?.messages.single as UserInputMessage).text,
        'old detail',
      );
      await detailPublish;
      final newDetail = await repository.loadConversationUserTurnDetail(
        target: target,
        provider: 'codex',
        providerSessionId: 'thread-read-snapshot',
        providerTurnId: 'turn-read-snapshot',
      );
      expect(newDetail?.revision, 'detail-new');
      expect(
        (newDetail?.messages.single as UserInputMessage).text,
        'new detail',
      );
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
