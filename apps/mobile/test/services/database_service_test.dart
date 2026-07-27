import 'dart:io';

import 'package:ccpocket/services/database_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory temporaryDirectory;

  Future<Database> openFfi(String databasePath, OpenDatabaseOptions options) =>
      databaseFactoryFfi.openDatabase(databasePath, options: options);

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'ccpocket_database_service_test_',
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test(
    'shares one open attempt and retries after a transient failure',
    () async {
      final databasePath = path.join(temporaryDirectory.path, 'retry.db');
      var openCalls = 0;
      final service = DatabaseService(
        databasePath: databasePath,
        openDatabaseOverride: (path, options) async {
          openCalls++;
          if (openCalls == 1) {
            throw const FileSystemException('transient open failure');
          }
          return openFfi(path, options);
        },
      );

      final first = service.database;
      final concurrent = service.database;
      expect(identical(first, concurrent), isTrue);
      expect(await first, isNull);
      expect(await concurrent, isNull);
      expect(openCalls, 1);

      final recovered = await service.database;
      expect(recovered, isNotNull);
      expect(await recovered!.getVersion(), 2);
      expect(openCalls, 3);
      expect(
        await recovered.query(
          'sqlite_master',
          columns: ['name'],
          where: 'type = ? AND name = ?',
          whereArgs: ['table', 'prompt_history_pending_local'],
        ),
        isNotEmpty,
      );
      await service.close();
    },
  );

  test(
    'opens a newer additive schema without downgrading or deleting it',
    () async {
      final databasePath = path.join(temporaryDirectory.path, 'future.db');
      final seed = await databaseFactoryFfi.openDatabase(
        databasePath,
        options: OpenDatabaseOptions(
          version: 3,
          onCreate: (db, version) async {
            await _createRequiredTables(db);
            await db.execute(
              'CREATE TABLE future_marker (value TEXT NOT NULL)',
            );
            await db.insert('future_marker', {'value': 'preserved'});
          },
        ),
      );
      await seed.close();

      var openCalls = 0;
      final service = DatabaseService(
        databasePath: databasePath,
        openDatabaseOverride: (path, options) {
          openCalls++;
          return openFfi(path, options);
        },
      );
      final opened = await service.database;
      expect(opened, isNotNull);
      expect(await opened!.getVersion(), 3);
      expect(await opened.query('future_marker'), [
        {'value': 'preserved'},
      ]);
      expect(openCalls, 1);
      await service.close();

      final verified = await databaseFactoryFfi.openDatabase(databasePath);
      expect(await verified.getVersion(), 3);
      expect(await verified.query('future_marker'), [
        {'value': 'preserved'},
      ]);
      await verified.close();
    },
  );
}

Future<void> _createRequiredTables(Database db) async {
  await db.execute('CREATE TABLE prompt_history (id INTEGER PRIMARY KEY)');
  await db.execute('CREATE TABLE prompt_history_cache (id TEXT PRIMARY KEY)');
  await db.execute(
    'CREATE TABLE prompt_history_pending_local (id TEXT PRIMARY KEY)',
  );
  await db.execute(
    'CREATE TABLE prompt_history_sync_status (bridge_id TEXT PRIMARY KEY)',
  );
}
