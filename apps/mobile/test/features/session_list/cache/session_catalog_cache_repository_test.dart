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
