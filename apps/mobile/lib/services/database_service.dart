import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../core/logger.dart';
import 'database_platform.dart';

typedef DatabaseServiceOpener =
    Future<Database> Function(String databasePath, OpenDatabaseOptions options);

/// Singleton service managing the sqflite [Database] lifecycle.
///
/// Handles database creation and schema migrations.
/// Returns `null` when the current platform has no available database backend.
class DatabaseService {
  DatabaseService({this.databasePath, this.openDatabaseOverride});

  final String? databasePath;
  final DatabaseServiceOpener? openDatabaseOverride;

  Database? _database;
  Future<Database?>? _opening;
  Future<void>? _closing;
  Future<_DatabaseOpenTarget>? _openTarget;

  static const _dbName = 'ccpocket.db';
  static const _dbVersion = 2;
  static const _requiredV2Tables = <String>{
    'prompt_history',
    'prompt_history_cache',
    'prompt_history_pending_local',
    'prompt_history_sync_status',
  };

  /// Get the database instance, initializing it if needed.
  ///
  /// Returns `null` on web platforms or when the database backend is not
  /// available in the current runtime.
  Future<Database?> get database {
    if (kIsWeb) return Future<Database?>.value();
    final current = _database;
    if (current != null) return Future<Database?>.value(current);
    final closing = _closing;
    if (closing != null) return _reopenAfter(closing);
    final inFlight = _opening;
    if (inFlight != null) return inFlight;

    late final Future<Database?> opening;
    opening = _openSafely().whenComplete(() {
      if (identical(_opening, opening)) _opening = null;
    });
    _opening = opening;
    return opening;
  }

  Future<Database?> _reopenAfter(Future<void> closing) async {
    await closing;
    return database;
  }

  Future<Database?> _openSafely() async {
    try {
      final opened = await _initDatabase();
      _database = opened;
      return opened;
    } catch (e) {
      // Missing platform backends and transient filesystem failures should not
      // poison the singleton for the rest of the process. The next accessor
      // retries through the same single-flight path.
      logger.warning('[DatabaseService] init failed; retry is allowed', e);
      return null;
    }
  }

  Future<Database> _initDatabase() async {
    final target = await (_openTarget ??= _resolveOpenTarget());
    final unversioned = await target.open(OpenDatabaseOptions());
    final currentVersion = await unversioned.getVersion();
    if (currentVersion >= _dbVersion) {
      try {
        await _validateKnownSchema(unversioned, currentVersion);
      } catch (_) {
        await unversioned.close();
        rethrow;
      }
      if (currentVersion > _dbVersion) {
        logger.warning(
          '[DatabaseService] opened newer schema v$currentVersion in '
          'compatibility mode without changing its version',
        );
      }
      return unversioned;
    }

    await unversioned.close();
    return target.open(
      OpenDatabaseOptions(
        version: _dbVersion,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      ),
    );
  }

  Future<_DatabaseOpenTarget> _resolveOpenTarget() async {
    final configuredPath = databasePath;
    final configuredOpen = openDatabaseOverride;
    if (configuredPath != null) {
      return _DatabaseOpenTarget(
        path: configuredPath,
        open: (options) => configuredOpen != null
            ? configuredOpen(configuredPath, options)
            : databaseFactory.openDatabase(configuredPath, options: options),
      );
    }
    if (configuredOpen != null) {
      throw ArgumentError(
        'databasePath is required when openDatabaseOverride is provided.',
      );
    }

    final platformConfig = await getPlatformDatabaseOpenConfig(_dbName);
    if (platformConfig != null) {
      return _DatabaseOpenTarget(
        path: platformConfig.path,
        open: platformConfig.openOptions,
      );
    }
    final path = await getDatabasesPath();
    final resolved = '$path/$_dbName';
    return _DatabaseOpenTarget(
      path: resolved,
      open: (options) =>
          databaseFactory.openDatabase(resolved, options: options),
    );
  }

  Future<void> _validateKnownSchema(Database db, int version) async {
    final placeholders = List.filled(_requiredV2Tables.length, '?').join(',');
    final rows = await db.rawQuery('''
      SELECT name
      FROM sqlite_master
      WHERE type = 'table' AND name IN ($placeholders)
      ''', _requiredV2Tables.toList(growable: false));
    final found = rows.map((row) => row['name']).whereType<String>().toSet();
    final missing = _requiredV2Tables.difference(found);
    if (missing.isNotEmpty) {
      throw StateError(
        'Database schema v$version is missing required tables: '
        '${missing.join(', ')}',
      );
    }
  }

  Future<void> _onCreate(Database db, int version) async {
    await _createPromptHistoryV1(db);
    await _createPromptHistoryV2(db);
  }

  Future<void> _createPromptHistoryV1(Database db) async {
    await db.execute('''
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

    await db.execute('''
      CREATE UNIQUE INDEX idx_prompt_text_project
      ON prompt_history (text, project_path)
    ''');

    await db.execute('''
      CREATE INDEX idx_prompt_last_used
      ON prompt_history (last_used_at DESC)
    ''');

    await db.execute('''
      CREATE INDEX idx_prompt_project
      ON prompt_history (project_path)
    ''');
  }

  Future<void> _createPromptHistoryV2(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS prompt_history_cache (
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

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_prompt_history_cache_last_used
      ON prompt_history_cache (last_used_at DESC)
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_prompt_history_cache_project
      ON prompt_history_cache (project_path)
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_prompt_history_cache_bridge
      ON prompt_history_cache (bridge_id)
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS prompt_history_pending_local (
        id TEXT NOT NULL,
        bridge_id TEXT NOT NULL,
        pending_local_at TEXT NOT NULL,
        PRIMARY KEY (id, bridge_id)
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS prompt_history_sync_status (
        bridge_id TEXT PRIMARY KEY,
        bridge_url TEXT NOT NULL,
        bridge_name TEXT NOT NULL DEFAULT '',
        last_sync_at TEXT,
        revision INTEGER NOT NULL DEFAULT 0,
        entry_count INTEGER NOT NULL DEFAULT 0,
        error TEXT
      )
    ''');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await _createPromptHistoryV2(db);
    }
  }

  /// Get the absolute path to the database file.
  Future<String> getDbPath() async {
    return (await (_openTarget ??= _resolveOpenTarget())).path;
  }

  /// Close the database connection.
  Future<void> close() {
    final existing = _closing;
    if (existing != null) return existing;
    late final Future<void> closing;
    closing = _performClose().whenComplete(() {
      if (identical(_closing, closing)) _closing = null;
    });
    _closing = closing;
    return closing;
  }

  Future<void> _performClose() async {
    final opening = _opening;
    _opening = null;
    final opened = opening == null ? null : await opening;
    final database = _database ?? opened;
    _database = null;
    await database?.close();
  }
}

class _DatabaseOpenTarget {
  const _DatabaseOpenTarget({required this.path, required this.open});

  final String path;
  final Future<Database> Function(OpenDatabaseOptions options) open;
}
