import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import '../../../services/database_platform.dart';

typedef SessionCatalogCacheDatabaseOpener =
    Future<Database> Function(String databasePath, OpenDatabaseOptions options);

/// Owns the rebuildable recent-session catalog cache.
///
/// The catalog deliberately lives outside `ccpocket.db`: clearing or replacing
/// this file must never remove prompt history or force the official database
/// through a custom schema migration.
class SessionCatalogCacheDatabase {
  SessionCatalogCacheDatabase({this.databasePath, this.openDatabase});

  static const fileName = 'session_catalog_cache_v1.db';
  static const schemaVersion = 1;

  static const partitionsTable = 'session_catalog_partitions';
  static const aliasesTable = 'session_catalog_aliases';
  static const entriesTable = 'session_catalog_entries';

  final String? databasePath;
  final SessionCatalogCacheDatabaseOpener? openDatabase;

  Future<Database>? _databaseFuture;
  bool _closed = false;

  Future<Database> get database {
    if (_closed) {
      return Future.error(
        StateError('Session catalog cache database is already closed.'),
      );
    }
    return _databaseFuture ??= _open();
  }

  Future<String> get resolvedPath async {
    if (databasePath case final configuredPath?) return configuredPath;
    if (!kIsWeb) {
      final platformConfig = await getPlatformDatabaseOpenConfig(fileName);
      if (platformConfig != null) return platformConfig.path;
    }
    return path.join(await getDatabasesPath(), fileName);
  }

  Future<Database> _open() async {
    final customOpen = openDatabase;
    final Database database;
    if (customOpen != null) {
      database = await customOpen(await resolvedPath, _openOptions());
    } else {
      if (kIsWeb) {
        throw UnsupportedError(
          'Session catalog cache storage is unavailable on web.',
        );
      }
      final platformConfig = databasePath == null
          ? await getPlatformDatabaseOpenConfig(fileName)
          : null;
      if (platformConfig != null) {
        database = await platformConfig.open(
          version: schemaVersion,
          onCreate: _createSchema,
          onUpgrade: _upgradeSchema,
        );
      } else {
        database = await databaseFactory.openDatabase(
          await resolvedPath,
          options: _openOptions(),
        );
      }
    }
    await database.execute('PRAGMA foreign_keys = ON');
    return database;
  }

  static OpenDatabaseOptions _openOptions() => OpenDatabaseOptions(
    version: schemaVersion,
    onConfigure: (database) async {
      await database.execute('PRAGMA foreign_keys = ON');
    },
    onCreate: _createSchema,
    onUpgrade: _upgradeSchema,
    onDowngrade: onDatabaseDowngradeDelete,
  );

  static Future<void> _upgradeSchema(
    Database database,
    int oldVersion,
    int newVersion,
  ) async {
    // Breaking changes use a new cache filename. Older app binaries must never
    // reinterpret a future rebuildable cache schema.
  }

  static Future<void> _createSchema(Database database, int version) async {
    await database.execute('''
      CREATE TABLE $partitionsTable (
        partition_id TEXT PRIMARY KEY,
        canonical_key TEXT UNIQUE,
        last_server_revision INTEGER,
        complete_revision INTEGER,
        updated_at INTEGER NOT NULL
      )
    ''');

    await database.execute('''
      CREATE TABLE $aliasesTable (
        alias_key TEXT PRIMARY KEY,
        partition_id TEXT NOT NULL,
        updated_at INTEGER NOT NULL,
        FOREIGN KEY (partition_id)
          REFERENCES $partitionsTable (partition_id)
          ON DELETE CASCADE
      )
    ''');

    await database.execute('''
      CREATE TABLE $entriesTable (
        partition_id TEXT NOT NULL,
        provider TEXT NOT NULL,
        project_path TEXT NOT NULL,
        session_id TEXT NOT NULL,
        session_json TEXT NOT NULL,
        modified_sort INTEGER NOT NULL,
        cached_at INTEGER NOT NULL,
        PRIMARY KEY (
          partition_id,
          provider,
          project_path,
          session_id
        ),
        FOREIGN KEY (partition_id)
          REFERENCES $partitionsTable (partition_id)
          ON DELETE CASCADE
      )
    ''');

    await database.execute('''
      CREATE INDEX session_catalog_entries_recent
      ON $entriesTable (partition_id, modified_sort DESC, cached_at DESC)
    ''');

    await database.execute('''
      CREATE INDEX session_catalog_alias_partition
      ON $aliasesTable (partition_id)
    ''');
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final opening = _databaseFuture;
    _databaseFuture = null;
    if (opening == null) return;
    final Database database;
    try {
      database = await opening;
    } catch (_) {
      return;
    }
    await database.close();
  }
}
