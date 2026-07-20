import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ccpocket/features/conversation_mirror/storage/conversation_mirror_storage.dart';
import 'package:ccpocket/features/conversation_mirror/storage/conversation_mirror_database_delete.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory temporaryDirectory;
  late String databasePath;
  late ConversationMirrorDatabase mirrorDatabase;
  late ConversationMirrorStore store;

  Future<Database> openFfi(String databasePath, OpenDatabaseOptions options) =>
      databaseFactoryFfi.openDatabase(databasePath, options: options);

  Future<Database> openIndependentFfi(
    String databasePath,
    OpenDatabaseOptions options,
  ) => databaseFactoryFfi.openDatabase(
    databasePath,
    options: OpenDatabaseOptions(
      version: options.version,
      onConfigure: options.onConfigure,
      onCreate: options.onCreate,
      onUpgrade: options.onUpgrade,
      onDowngrade: options.onDowngrade,
      onOpen: options.onOpen,
      readOnly: options.readOnly,
      singleInstance: false,
    ),
  );

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'ccpocket_conversation_mirror_test_',
    );
    databasePath = path.join(
      temporaryDirectory.path,
      ConversationMirrorDatabase.fileName,
    );
    mirrorDatabase = ConversationMirrorDatabase(
      databasePath: databasePath,
      openDatabase: openFfi,
    );
    store = ConversationMirrorStore(mirrorDatabase);
  });

  tearDown(() async {
    await mirrorDatabase.close();
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  group('shadow snapshot activation', () {
    test('uses an independent removable database file', () async {
      expect(await mirrorDatabase.resolvedPath, databasePath);
      expect(path.basename(databasePath), 'conversation_mirror_v1.db');
      final db = await mirrorDatabase.database;
      expect(db, isNotNull);
      expect(Sqflite.firstIntValue(await db.rawQuery('PRAGMA auto_vacuum')), 2);
      expect(await File(databasePath).exists(), isTrue);
    });

    test(
      'close waits for an in-flight open and prevents reopen races',
      () async {
        final openGate = Completer<void>();
        final delayed = ConversationMirrorDatabase(
          databasePath: databasePath,
          openDatabase: (path, options) async {
            await openGate.future;
            return openFfi(path, options);
          },
        );

        final opening = delayed.database;
        final closing = delayed.close();
        openGate.complete();
        final opened = await opening;
        await closing;

        expect(opened.isOpen, isFalse);
        await expectLater(delayed.database, throwsA(isA<StateError>()));

        final failed = ConversationMirrorDatabase(
          databasePath: path.join(temporaryDirectory.path, 'failed-open.db'),
          openDatabase: (_, _) => Future.error(StateError('open failed')),
        );
        await expectLater(failed.database, throwsA(isA<StateError>()));
        await expectLater(failed.close(), completes);
      },
    );

    test('an interrupted generation keeps the old active copy', () async {
      const key = ConversationMirrorKey(
        bridgeInstanceId: 'bridge-a',
        provider: 'codex',
        providerSessionId: 'session-1',
      );
      final oldEntries = _entries(2, prefix: 'old');
      await _writeSnapshot(
        store,
        key,
        generation: 'generation-old',
        revision: _revision('old'),
        entries: oldEntries,
      );

      final replacement = _entries(3, prefix: 'replacement');
      await store.beginShadowGeneration(
        key: key,
        generation: 'generation-interrupted',
        revision: _revision('replacement'),
        entryCount: replacement.length,
        pageCount: 2,
        totalBytes: _totalBytes(replacement),
      );
      await store.appendShadowPage(
        key: key,
        generation: 'generation-interrupted',
        pageIndex: 0,
        pageCount: 2,
        entries: replacement.take(2).toList(),
      );

      await mirrorDatabase.close();
      mirrorDatabase = ConversationMirrorDatabase(
        databasePath: databasePath,
        openDatabase: openFfi,
      );
      store = ConversationMirrorStore(mirrorDatabase);

      final metadata = await store.readMetadata(key);
      final restored = await store.readEntries(key);
      expect(metadata?.activeGeneration, 'generation-old');
      expect(metadata?.revision, _revision('old'));
      expect(restored.map((entry) => entry.entryId), ['old-0', 'old-1']);

      final db = await mirrorDatabase.database;
      expect(
        Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM '
            '${ConversationMirrorDatabase.stagingTable}',
          ),
        ),
        0,
      );
      expect(
        Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM '
            '${ConversationMirrorDatabase.entriesTable} '
            'WHERE generation = ?',
            ['generation-interrupted'],
          ),
        ),
        0,
      );
    });

    test('repeated snapshot completion is idempotent', () async {
      const key = ConversationMirrorKey(
        bridgeInstanceId: 'bridge-a',
        provider: 'codex',
        providerSessionId: 'session-repeat-complete',
      );
      final entries = _entries(2, prefix: 'repeat-complete');
      final revision = _revision('repeat-complete');
      await _writeSnapshot(
        store,
        key,
        generation: 'generation-repeat-complete',
        revision: revision,
        entries: entries,
      );

      final repeated = await store.completeShadowGeneration(
        key: key,
        generation: 'generation-repeat-complete',
        revision: revision,
        entryCount: entries.length,
      );

      expect(repeated.activeGeneration, 'generation-repeat-complete');
      expect(repeated.revision, revision);
      expect(await store.readEntries(key), hasLength(2));
    });

    test(
      'incomplete completion leaves the prior generation readable',
      () async {
        const key = ConversationMirrorKey(
          bridgeInstanceId: 'bridge-a',
          provider: 'codex',
          providerSessionId: 'session-incomplete',
        );
        await _writeSnapshot(
          store,
          key,
          generation: 'generation-old',
          revision: _revision('old'),
          entries: _entries(1, prefix: 'old'),
        );
        final replacement = _entries(2, prefix: 'new');
        await store.beginShadowGeneration(
          key: key,
          generation: 'generation-new',
          revision: _revision('new'),
          entryCount: 2,
          pageCount: 2,
          totalBytes: _totalBytes(replacement),
        );
        await store.appendShadowPage(
          key: key,
          generation: 'generation-new',
          pageIndex: 0,
          pageCount: 2,
          entries: [replacement.first],
        );

        await expectLater(
          store.completeShadowGeneration(
            key: key,
            generation: 'generation-new',
            revision: _revision('new'),
            entryCount: 2,
          ),
          throwsA(isA<ConversationMirrorValidationException>()),
        );
        expect((await store.readMetadata(key))?.revision, _revision('old'));
        expect((await store.readEntries(key)).single.entryId, 'old-0');
      },
    );

    test(
      'read transaction pins the active generation during a WAL switch',
      () async {
        const key = ConversationMirrorKey(
          bridgeInstanceId: 'bridge-a',
          provider: 'codex',
          providerSessionId: 'session-read-race',
        );
        await _writeSnapshot(
          store,
          key,
          generation: 'generation-before-read',
          revision: _revision('before-read'),
          entries: _entries(2, prefix: 'before-read'),
        );

        final primaryDb = await mirrorDatabase.database;
        await primaryDb.rawQuery('PRAGMA journal_mode=WAL');
        final writerDatabase = ConversationMirrorDatabase(
          databasePath: databasePath,
          openDatabase: openIndependentFfi,
        );
        final writerDb = await writerDatabase.database;
        await writerDb.rawQuery('PRAGMA journal_mode=WAL');
        final writerStore = ConversationMirrorStore(writerDatabase);

        final replacement = _entries(3, prefix: 'after-read');
        await store.beginShadowGeneration(
          key: key,
          generation: 'generation-after-read',
          revision: _revision('after-read'),
          entryCount: replacement.length,
          pageCount: 1,
          totalBytes: _totalBytes(replacement),
        );
        await store.appendShadowPage(
          key: key,
          generation: 'generation-after-read',
          pageIndex: 0,
          pageCount: 1,
          entries: replacement,
        );

        var writerWasBlockedByRead = false;
        final pinnedReader = ConversationMirrorStore(
          mirrorDatabase,
          readTransactionHook: (generation) async {
            expect(generation, 'generation-before-read');
            await expectLater(
              writerStore.completeShadowGeneration(
                key: key,
                generation: 'generation-after-read',
                revision: _revision('after-read'),
                entryCount: replacement.length,
              ),
              throwsA(isA<DatabaseException>()),
            );
            writerWasBlockedByRead = true;
          },
        );
        try {
          final pinned = await pinnedReader.readEntries(key);
          expect(writerWasBlockedByRead, isTrue);
          expect(pinned.map((entry) => entry.entryId), [
            'before-read-0',
            'before-read-1',
          ]);
          await writerStore.completeShadowGeneration(
            key: key,
            generation: 'generation-after-read',
            revision: _revision('after-read'),
            entryCount: replacement.length,
          );
          expect((await store.readEntries(key)).map((entry) => entry.entryId), [
            'after-read-0',
            'after-read-1',
            'after-read-2',
          ]);
        } finally {
          await writerDatabase.close();
        }
      },
    );

    test('stale snapshot CAS cannot overwrite a patched active copy', () async {
      const key = ConversationMirrorKey(
        bridgeInstanceId: 'bridge-a',
        provider: 'codex',
        providerSessionId: 'session-snapshot-cas',
      );
      await _writeSnapshot(
        store,
        key,
        generation: 'generation-active',
        revision: _revision('snapshot-base'),
        entries: _entries(1, prefix: 'active'),
      );
      final staleSnapshot = _entries(1, prefix: 'stale');
      await store.beginShadowGeneration(
        key: key,
        generation: 'generation-stale',
        revision: _revision('stale-snapshot'),
        entryCount: 1,
        pageCount: 1,
        totalBytes: _totalBytes(staleSnapshot),
      );
      await store.appendShadowPage(
        key: key,
        generation: 'generation-stale',
        pageIndex: 0,
        pageCount: 1,
        entries: staleSnapshot,
      );
      await store.applyPatch(
        key: key,
        baseRevision: _revision('snapshot-base'),
        revision: _revision('desktop-patch'),
        upserts: [_entry('active-0', 0, text: 'desktop patch wins')],
      );

      await expectLater(
        store.completeShadowGeneration(
          key: key,
          generation: 'generation-stale',
          revision: _revision('stale-snapshot'),
          entryCount: 1,
        ),
        throwsA(
          isA<ConversationMirrorSnapshotConflictException>().having(
            (error) => error.actualRevision,
            'actual revision',
            _revision('desktop-patch'),
          ),
        ),
      );
      expect(
        (await store.readMetadata(key))?.activeGeneration,
        'generation-active',
      );
      expect(
        (await store.readMetadata(key))?.revision,
        _revision('desktop-patch'),
      );
      expect(
        (await store.readEntries(key)).single.message['text'],
        'desktop patch wins',
      );
      final db = await mirrorDatabase.database;
      expect(
        Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM '
            '${ConversationMirrorDatabase.entriesTable} '
            'WHERE generation = ?',
            ['generation-stale'],
          ),
        ),
        0,
      );
    });

    test('abort removes only a shadow generation and is idempotent', () async {
      const key = ConversationMirrorKey(
        bridgeInstanceId: 'bridge-a',
        provider: 'codex',
        providerSessionId: 'session-abort',
      );
      await _writeSnapshot(
        store,
        key,
        generation: 'generation-active',
        revision: _revision('abort-active'),
        entries: _entries(1, prefix: 'active'),
      );
      final shadow = _entries(2, prefix: 'abort-shadow');
      await store.beginShadowGeneration(
        key: key,
        generation: 'generation-shadow',
        revision: _revision('abort-shadow'),
        entryCount: shadow.length,
        pageCount: 1,
        totalBytes: _totalBytes(shadow),
      );
      await store.appendShadowPage(
        key: key,
        generation: 'generation-shadow',
        pageIndex: 0,
        pageCount: 1,
        entries: shadow,
      );

      expect(await store.abortShadowGeneration(key), isTrue);
      expect(await store.abortShadowGeneration(key), isFalse);
      expect((await store.readEntries(key)).single.entryId, 'active-0');
      await expectLater(
        store.abortShadowGeneration(key, generation: 'generation-active'),
        throwsA(isA<ConversationMirrorValidationException>()),
      );
      expect((await store.readEntries(key)).single.entryId, 'active-0');
    });

    test('loads 250 entries in ordinal order across bounded pages', () async {
      const key = ConversationMirrorKey(
        bridgeInstanceId: 'bridge-a',
        provider: 'codex',
        providerSessionId: 'session-large',
      );
      final entries = _entries(250, prefix: 'large');
      final metadata = await _writeSnapshot(
        store,
        key,
        generation: 'generation-large',
        revision: _revision('large'),
        entries: entries,
      );

      final stored = await store.readEntries(key);
      expect(metadata.entryCount, 250);
      expect(stored, hasLength(250));
      expect(stored.first.ordinal, 0);
      expect(stored.last.ordinal, 249);
      expect(stored.last.entryId, 'large-249');
      expect(
        (await store.readEntries(
          key,
          offset: 200,
          limit: 20,
        )).map((entry) => entry.ordinal),
        List<int>.generate(20, (index) => index + 200),
      );
    });

    test('persists an activated copy across app relaunch', () async {
      const key = ConversationMirrorKey(
        bridgeInstanceId: 'bridge-a',
        provider: 'claude',
        providerSessionId: 'session-relaunch',
      );
      await _writeSnapshot(
        store,
        key,
        generation: 'generation-persisted',
        revision: _revision('persisted'),
        entries: _entries(4, prefix: 'persisted'),
        autoSync: true,
        projectPath: '/projects/example',
      );

      await mirrorDatabase.close();
      mirrorDatabase = ConversationMirrorDatabase(
        databasePath: databasePath,
        openDatabase: openFfi,
      );
      store = ConversationMirrorStore(mirrorDatabase);

      final metadata = await store.readMetadata(key);
      expect(metadata?.revision, _revision('persisted'));
      expect(metadata?.autoSync, isTrue);
      expect(metadata?.projectPath, '/projects/example');
      expect(await store.readEntries(key), hasLength(4));
    });

    test(
      'accepts an exact page retry and rejects a conflicting retry',
      () async {
        const key = ConversationMirrorKey(
          bridgeInstanceId: 'bridge-a',
          provider: 'codex',
          providerSessionId: 'session-page-retry',
        );
        final entries = _entries(1, prefix: 'retry');
        await store.beginShadowGeneration(
          key: key,
          generation: 'generation-retry',
          revision: _revision('retry'),
          entryCount: 1,
          pageCount: 1,
          totalBytes: _totalBytes(entries),
        );
        await store.appendShadowPage(
          key: key,
          generation: 'generation-retry',
          pageIndex: 0,
          pageCount: 1,
          entries: entries,
        );
        await store.appendShadowPage(
          key: key,
          generation: 'generation-retry',
          pageIndex: 0,
          pageCount: 1,
          entries: entries,
        );

        await expectLater(
          store.appendShadowPage(
            key: key,
            generation: 'generation-retry',
            pageIndex: 0,
            pageCount: 1,
            entries: [_entry('retry-0', 0, text: 'different')],
          ),
          throwsA(isA<ConversationMirrorValidationException>()),
        );
      },
    );
  });

  group('incremental patches', () {
    test('deletes a tail entry and updates metadata atomically', () async {
      const key = ConversationMirrorKey(
        bridgeInstanceId: 'bridge-a',
        provider: 'codex',
        providerSessionId: 'session-delete',
      );
      await _writeSnapshot(
        store,
        key,
        generation: 'generation-active',
        revision: _revision('before-delete'),
        entries: _entries(3, prefix: 'delete'),
      );

      final result = await store.applyPatch(
        key: key,
        baseRevision: _revision('before-delete'),
        revision: _revision('after-delete'),
        deletes: ['delete-2'],
      );

      expect(result.outcome, ConversationMirrorPatchOutcome.applied);
      expect((await store.readMetadata(key))?.entryCount, 2);
      expect(
        (await store.readMetadata(key))?.revision,
        _revision('after-delete'),
      );
      expect((await store.readEntries(key)).map((entry) => entry.entryId), [
        'delete-0',
        'delete-1',
      ]);
    });

    test('detects a same-count content mutation by content hash', () async {
      const key = ConversationMirrorKey(
        bridgeInstanceId: 'bridge-a',
        provider: 'codex',
        providerSessionId: 'session-mutation',
      );
      await _writeSnapshot(
        store,
        key,
        generation: 'generation-active',
        revision: _revision('before-mutation'),
        entries: _entries(2, prefix: 'mutation'),
      );
      final replacement = _entry(
        'mutation-0',
        0,
        text: 'desktop changed this existing message',
      );

      final result = await store.applyPatch(
        key: key,
        baseRevision: _revision('before-mutation'),
        revision: _revision('after-mutation'),
        upserts: [replacement],
      );

      final stored = await store.readEntries(key);
      expect(result.applied, isTrue);
      expect(stored, hasLength(2));
      expect(stored.first.contentHash, replacement.contentHash);
      expect(
        stored.first.message['text'],
        'desktop changed this existing message',
      );
    });

    test('revision mismatch is explicit and performs no writes', () async {
      const key = ConversationMirrorKey(
        bridgeInstanceId: 'bridge-a',
        provider: 'codex',
        providerSessionId: 'session-cas',
      );
      await _writeSnapshot(
        store,
        key,
        generation: 'generation-active',
        revision: _revision('actual'),
        entries: _entries(1, prefix: 'cas'),
      );

      final result = await store.applyPatch(
        key: key,
        baseRevision: _revision('stale'),
        revision: _revision('must-not-apply'),
        deletes: ['cas-0'],
      );

      expect(result.outcome, ConversationMirrorPatchOutcome.revisionMismatch);
      expect(result.actualRevision, _revision('actual'));
      expect((await store.readMetadata(key))?.revision, _revision('actual'));
      expect(await store.readEntries(key), hasLength(1));
    });
  });

  group('identity, policy, and validation', () {
    test(
      'isolates identical provider session IDs by Bridge instance',
      () async {
        const keyA = ConversationMirrorKey(
          bridgeInstanceId: 'bridge-a',
          provider: 'codex',
          providerSessionId: 'same-session',
        );
        const keyB = ConversationMirrorKey(
          bridgeInstanceId: 'bridge-b',
          provider: 'codex',
          providerSessionId: 'same-session',
        );
        await _writeSnapshot(
          store,
          keyA,
          generation: 'generation-a',
          revision: _revision('bridge-a'),
          entries: _entries(1, prefix: 'bridge-a'),
        );
        await _writeSnapshot(
          store,
          keyB,
          generation: 'generation-b',
          revision: _revision('bridge-b'),
          entries: _entries(2, prefix: 'bridge-b'),
        );

        expect((await store.readEntries(keyA)).single.entryId, 'bridge-a-0');
        expect(await store.readEntries(keyB), hasLength(2));
        expect(
          (await store.readMetadata(keyA))?.revision,
          _revision('bridge-a'),
        );
        expect(
          (await store.readMetadata(keyB))?.revision,
          _revision('bridge-b'),
        );
      },
    );

    test('offline lookup returns only one unambiguous Bridge copy', () async {
      const keyA = ConversationMirrorKey(
        bridgeInstanceId: 'bridge-a',
        provider: 'codex',
        providerSessionId: 'offline-session',
      );
      const keyB = ConversationMirrorKey(
        bridgeInstanceId: 'bridge-b',
        provider: 'codex',
        providerSessionId: 'offline-session',
      );
      await _writeSnapshot(
        store,
        keyA,
        generation: 'offline-a',
        revision: _revision('offline-a'),
        entries: _entries(1, prefix: 'offline-a'),
        projectPath: '/projects/a',
      );

      final unique = await store.findUniqueLocalCopy(
        'codex',
        'offline-session',
        projectPath: '/projects/a',
      );
      expect(unique?.key, keyA);
      expect(
        await store.findUniqueLocalCopy(
          'codex',
          'offline-session',
          projectPath: '/projects/not-a',
        ),
        isNull,
      );

      await _writeSnapshot(
        store,
        keyB,
        generation: 'offline-b',
        revision: _revision('offline-b'),
        entries: _entries(1, prefix: 'offline-b'),
        projectPath: '/projects/b',
      );
      expect(
        await store.findUniqueLocalCopy('codex', 'offline-session'),
        isNull,
      );
      expect(
        await store.findUniqueLocalCopy(
          'codex',
          'offline-session',
          projectPath: '/projects/a',
        ),
        isNull,
      );
    });

    test('lists auto-sync copies and delete cascades all local data', () async {
      const key = ConversationMirrorKey(
        bridgeInstanceId: 'bridge-a',
        provider: 'codex',
        providerSessionId: 'session-policy',
      );
      await _writeSnapshot(
        store,
        key,
        generation: 'generation-policy',
        revision: _revision('policy'),
        entries: _entries(2, prefix: 'policy'),
        autoSync: true,
      );

      expect((await store.listAutoSync()).map((item) => item.key), [key]);
      expect((await store.listLocalCopies()).map((item) => item.key), [key]);
      await store.setAutoSync(key, false);
      expect(await store.listAutoSync(), isEmpty);
      expect((await store.listLocalCopies()).map((item) => item.key), [key]);
      await store.deleteLocalCopy(key);
      expect(await store.readMetadata(key), isNull);
      expect(await store.readEntries(key), isEmpty);
      final db = await mirrorDatabase.database;
      expect(
        Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM '
            '${ConversationMirrorDatabase.entriesTable}',
          ),
        ),
        0,
      );
    });

    test('rejects invalid raw envelopes and mismatched hashes', () async {
      const key = ConversationMirrorKey(
        bridgeInstanceId: 'bridge-a',
        provider: 'codex',
        providerSessionId: 'session-invalid',
      );
      await store.beginShadowGeneration(
        key: key,
        generation: 'generation-invalid',
        revision: _revision('invalid'),
        entryCount: 1,
        pageCount: 1,
        totalBytes: 1,
      );

      for (final invalid in [
        ConversationMirrorEntryInput(
          entryId: 'missing-type',
          ordinal: 0,
          contentHash: '0' * 64,
          message: const {'text': 'missing type'},
        ),
        ConversationMirrorEntryInput(
          entryId: 'not-json',
          ordinal: 0,
          contentHash: '0' * 64,
          message: {'type': 'user_input', 'value': Object()},
        ),
        ConversationMirrorEntryInput(
          entryId: 'bad-hash',
          ordinal: 0,
          contentHash: '0' * 64,
          message: const {'type': 'user_input', 'text': 'valid envelope'},
        ),
      ]) {
        await expectLater(
          store.appendShadowPage(
            key: key,
            generation: 'generation-invalid',
            pageIndex: 0,
            pageCount: 1,
            entries: [invalid],
          ),
          throwsA(isA<ConversationMirrorValidationException>()),
        );
      }
    });

    test('rejects oversized declared snapshots and entries', () async {
      final constrained = ConversationMirrorStore(
        mirrorDatabase,
        limits: const ConversationMirrorLimits(
          maxEntriesPerGeneration: 2,
          maxEntriesPerPage: 2,
          maxEntryBytes: 60,
          maxPageBytes: 200,
          maxTotalBytes: 200,
        ),
      );
      const key = ConversationMirrorKey(
        bridgeInstanceId: 'bridge-a',
        provider: 'codex',
        providerSessionId: 'session-limits',
      );
      await expectLater(
        constrained.beginShadowGeneration(
          key: key,
          generation: 'generation-too-many',
          revision: _revision('too-many'),
          entryCount: 3,
          pageCount: 2,
          totalBytes: 10,
        ),
        throwsA(isA<ConversationMirrorValidationException>()),
      );

      final oversized = _entry('oversized', 0, text: 'x' * 100);
      await constrained.beginShadowGeneration(
        key: key,
        generation: 'generation-oversized',
        revision: _revision('oversized'),
        entryCount: 1,
        pageCount: 1,
        totalBytes: _totalBytes([oversized]),
      );
      await expectLater(
        constrained.appendShadowPage(
          key: key,
          generation: 'generation-oversized',
          pageIndex: 0,
          pageCount: 1,
          entries: [oversized],
        ),
        throwsA(isA<ConversationMirrorValidationException>()),
      );
    });

    test(
      'hard-rejects snapshots and patches over the database-wide quota',
      () async {
        const keyA = ConversationMirrorKey(
          bridgeInstanceId: 'bridge-a',
          provider: 'codex',
          providerSessionId: 'quota-a',
        );
        const keyB = ConversationMirrorKey(
          bridgeInstanceId: 'bridge-a',
          provider: 'codex',
          providerSessionId: 'quota-b',
        );
        final entriesA = _entries(1, prefix: 'quota-a');
        final entriesB = _entries(1, prefix: 'quota-b');
        final databaseLimit = _totalBytes(entriesA) + _totalBytes(entriesB) - 1;
        final quotaStore = ConversationMirrorStore(
          mirrorDatabase,
          limits: ConversationMirrorLimits(maxDatabaseBytes: databaseLimit),
        );
        await _writeSnapshot(
          quotaStore,
          keyA,
          generation: 'quota-generation-a',
          revision: _revision('quota-a'),
          entries: entriesA,
        );

        await expectLater(
          quotaStore.beginShadowGeneration(
            key: keyB,
            generation: 'quota-generation-b',
            revision: _revision('quota-b'),
            entryCount: entriesB.length,
            pageCount: 1,
            totalBytes: _totalBytes(entriesB),
          ),
          throwsA(isA<ConversationMirrorValidationException>()),
        );
        expect(await quotaStore.readMetadata(keyB), isNull);

        await expectLater(
          quotaStore.applyPatch(
            key: keyA,
            baseRevision: _revision('quota-a'),
            revision: _revision('quota-expanded'),
            upserts: [_entry('quota-a-0', 0, text: 'expanded' * 100)],
          ),
          throwsA(isA<ConversationMirrorValidationException>()),
        );
        expect(
          (await quotaStore.readMetadata(keyA))?.revision,
          _revision('quota-a'),
        );
      },
    );

    test(
      'future mirror schema is rebuilt without touching ccpocket.db',
      () async {
        await mirrorDatabase.close();
        final officialPath = path.join(temporaryDirectory.path, 'ccpocket.db');
        final official = await databaseFactoryFfi.openDatabase(
          officialPath,
          options: OpenDatabaseOptions(
            version: 1,
            onCreate: (db, version) async {
              await db.execute('CREATE TABLE sentinel (value TEXT NOT NULL)');
              await db.insert('sentinel', {'value': 'official-kept'});
            },
          ),
        );
        await official.close();

        final futureMirror = await databaseFactoryFfi.openDatabase(
          databasePath,
          options: OpenDatabaseOptions(
            version: ConversationMirrorDatabase.schemaVersion + 1,
            onCreate: (db, version) async {
              await db.execute('CREATE TABLE future_only (value TEXT)');
            },
          ),
        );
        await futureMirror.close();

        mirrorDatabase = ConversationMirrorDatabase(
          databasePath: databasePath,
          openDatabase: openFfi,
        );
        store = ConversationMirrorStore(mirrorDatabase);
        final rebuilt = await mirrorDatabase.database;
        expect(
          Sqflite.firstIntValue(await rebuilt.rawQuery('PRAGMA user_version')),
          ConversationMirrorDatabase.schemaVersion,
        );
        expect(
          await rebuilt.query(
            'sqlite_master',
            where: 'type = ? AND name = ?',
            whereArgs: ['table', ConversationMirrorDatabase.metadataTable],
          ),
          hasLength(1),
        );
        expect(
          await rebuilt.query(
            'sqlite_master',
            where: 'type = ? AND name = ?',
            whereArgs: ['table', 'future_only'],
          ),
          isEmpty,
        );
        final stagingColumns = {
          for (final row in await rebuilt.rawQuery(
            'PRAGMA table_info(${ConversationMirrorDatabase.stagingTable})',
          ))
            row['name'],
        };
        expect(
          stagingColumns,
          containsAll(['base_active_generation', 'base_revision']),
        );

        final legacyPath = path.join(
          temporaryDirectory.path,
          'legacy-platform-mirror.db',
        );
        final futureLegacyMirror = await databaseFactoryFfi.openDatabase(
          legacyPath,
          options: OpenDatabaseOptions(
            version: ConversationMirrorDatabase.schemaVersion + 1,
            onCreate: (db, version) async {
              await db.execute('CREATE TABLE legacy_future_only (value TEXT)');
            },
          ),
        );
        await futureLegacyMirror.close();
        expect(
          await prepareConversationMirrorLegacyDatabaseForOpen(
            legacyPath,
            schemaVersion: ConversationMirrorDatabase.schemaVersion,
          ),
          isTrue,
        );
        final legacyCurrent = ConversationMirrorDatabase(
          databasePath: legacyPath,
          openDatabase: openFfi,
        );
        final legacyCurrentDb = await legacyCurrent.database;
        expect(
          Sqflite.firstIntValue(
            await legacyCurrentDb.rawQuery('PRAGMA user_version'),
          ),
          ConversationMirrorDatabase.schemaVersion,
        );
        await legacyCurrent.close();

        final officialAfter = await databaseFactoryFfi.openDatabase(
          officialPath,
        );
        expect(
          (await officialAfter.query('sentinel')).single['value'],
          'official-kept',
        );
        await officialAfter.close();
      },
    );

    test('detects corrupted raw JSON when reading', () async {
      const key = ConversationMirrorKey(
        bridgeInstanceId: 'bridge-a',
        provider: 'codex',
        providerSessionId: 'session-corrupt',
      );
      await _writeSnapshot(
        store,
        key,
        generation: 'generation-corrupt',
        revision: _revision('corrupt'),
        entries: _entries(1, prefix: 'corrupt'),
      );
      final db = await mirrorDatabase.database;
      await db.update(
        ConversationMirrorDatabase.entriesTable,
        {'message_json': '{invalid'},
        where: 'entry_id = ?',
        whereArgs: ['corrupt-0'],
      );

      await expectLater(
        store.readEntries(key),
        throwsA(isA<ConversationMirrorCorruptionException>()),
      );
    });

    test('detects missing active entries and hash-only corruption', () async {
      const missingKey = ConversationMirrorKey(
        bridgeInstanceId: 'bridge-a',
        provider: 'codex',
        providerSessionId: 'session-missing-entry',
      );
      await _writeSnapshot(
        store,
        missingKey,
        generation: 'generation-missing-entry',
        revision: _revision('missing-entry'),
        entries: _entries(2, prefix: 'missing-entry'),
      );
      final db = await mirrorDatabase.database;
      await db.delete(
        ConversationMirrorDatabase.entriesTable,
        where: 'provider_session_id = ? AND ordinal = ?',
        whereArgs: [missingKey.providerSessionId, 1],
      );
      await expectLater(
        store.readEntries(missingKey),
        throwsA(isA<ConversationMirrorCorruptionException>()),
      );

      const hashKey = ConversationMirrorKey(
        bridgeInstanceId: 'bridge-a',
        provider: 'codex',
        providerSessionId: 'session-bad-hash',
      );
      await _writeSnapshot(
        store,
        hashKey,
        generation: 'generation-bad-hash',
        revision: _revision('bad-hash'),
        entries: _entries(1, prefix: 'bad-hash'),
      );
      await db.update(
        ConversationMirrorDatabase.entriesTable,
        {'content_hash': '0' * 64},
        where: 'provider_session_id = ?',
        whereArgs: [hashKey.providerSessionId],
      );
      await expectLater(
        store.readEntries(hashKey),
        throwsA(isA<ConversationMirrorCorruptionException>()),
      );
    });
  });
}

Future<ConversationMirrorMetadata> _writeSnapshot(
  ConversationMirrorStore store,
  ConversationMirrorKey key, {
  required String generation,
  required String revision,
  required List<ConversationMirrorEntryInput> entries,
  bool? autoSync,
  String? projectPath,
}) async {
  const pageSize = 100;
  final pageCount = entries.isEmpty
      ? 0
      : (entries.length + pageSize - 1) ~/ pageSize;
  await store.beginShadowGeneration(
    key: key,
    generation: generation,
    revision: revision,
    entryCount: entries.length,
    pageCount: pageCount,
    totalBytes: _totalBytes(entries),
    autoSync: autoSync,
    projectPath: projectPath,
  );
  for (var pageIndex = 0; pageIndex < pageCount; pageIndex++) {
    final start = pageIndex * pageSize;
    final end = (start + pageSize).clamp(0, entries.length);
    await store.appendShadowPage(
      key: key,
      generation: generation,
      pageIndex: pageIndex,
      pageCount: pageCount,
      entries: entries.sublist(start, end),
    );
  }
  return store.completeShadowGeneration(
    key: key,
    generation: generation,
    revision: revision,
    entryCount: entries.length,
  );
}

List<ConversationMirrorEntryInput> _entries(
  int count, {
  required String prefix,
}) => List.generate(
  count,
  (index) => _entry('$prefix-$index', index, text: '$prefix message $index'),
);

ConversationMirrorEntryInput _entry(
  String entryId,
  int ordinal, {
  required String text,
}) {
  final message = <String, dynamic>{'type': 'user_input', 'text': text};
  return ConversationMirrorEntryInput(
    entryId: entryId,
    ordinal: ordinal,
    contentHash: sha256.convert(utf8.encode(jsonEncode(message))).toString(),
    message: message,
  );
}

int _totalBytes(List<ConversationMirrorEntryInput> entries) => entries.fold(
  0,
  (total, entry) => total + utf8.encode(jsonEncode(entry.message)).length,
);

String _revision(String seed) =>
    sha256.convert(utf8.encode('revision:$seed')).toString();
