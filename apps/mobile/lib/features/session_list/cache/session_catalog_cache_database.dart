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
  static const schemaVersion = 5;

  static const partitionsTable = 'session_catalog_partitions';
  static const aliasesTable = 'session_catalog_aliases';
  static const entriesTable = 'session_catalog_entries';
  static const hotWindowsTable = 'conversation_hot_windows';
  static const hotEntriesTable = 'conversation_hot_entries';
  static const syncStatesTable = 'conversation_sync_states';
  static const statusesTable = 'conversation_sync_statuses';
  static const readWatermarksTable = 'conversation_read_watermarks';
  static const timelineStagesTable = 'conversation_timeline_stages';
  static const timelineStagePagesTable = 'conversation_timeline_stage_pages';
  static const timelineStageEntriesTable =
      'conversation_timeline_stage_entries';
  static const timelineStageDeletesTable =
      'conversation_timeline_stage_deletes';

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
    if (oldVersion < 2) {
      await _createHotConversationSchema(database);
    }
    if (oldVersion < 3) {
      await _createConversationSyncSchema(database);
    }
    if (oldVersion < 4) {
      if (oldVersion >= 2) {
        await database.execute(
          'ALTER TABLE $hotWindowsTable ADD COLUMN turns_next_cursor TEXT',
        );
      }
      if (oldVersion >= 3) {
        await database.execute(
          'ALTER TABLE $timelineStagesTable ADD COLUMN turns_next_cursor TEXT',
        );
      }
    }
    if (oldVersion < 5) {
      if (oldVersion >= 2) {
        await database.execute(
          'ALTER TABLE $hotWindowsTable '
          'ADD COLUMN latest_turn_complete INTEGER NOT NULL DEFAULT 1',
        );
        await database.execute(
          'ALTER TABLE $hotWindowsTable ADD COLUMN latest_turn_gap_json TEXT',
        );
        await database.execute(
          'ALTER TABLE $hotWindowsTable ADD COLUMN latest_turn_gap_cursor TEXT',
        );
      }
      if (oldVersion >= 3) {
        await database.execute(
          'ALTER TABLE $timelineStagesTable '
          'ADD COLUMN latest_turn_complete INTEGER NOT NULL DEFAULT 1',
        );
        await database.execute(
          'ALTER TABLE $timelineStagesTable '
          'ADD COLUMN latest_turn_gap_json TEXT',
        );
        await database.execute(
          'ALTER TABLE $timelineStagesTable '
          'ADD COLUMN latest_turn_gap_cursor TEXT',
        );
      }
    }
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

    await _createHotConversationSchema(database);
    await _createConversationSyncSchema(database);
  }

  static Future<void> _createHotConversationSchema(Database database) async {
    await database.execute('''
      CREATE TABLE IF NOT EXISTS $hotWindowsTable (
        partition_id TEXT NOT NULL,
        provider TEXT NOT NULL,
        provider_session_id TEXT NOT NULL,
        revision TEXT NOT NULL,
        entry_count INTEGER NOT NULL,
        has_earlier INTEGER NOT NULL,
        turns_next_cursor TEXT,
        latest_turn_complete INTEGER NOT NULL DEFAULT 1,
        latest_turn_gap_json TEXT,
        latest_turn_gap_cursor TEXT,
        source_entry_count INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (partition_id, provider, provider_session_id),
        FOREIGN KEY (partition_id)
          REFERENCES $partitionsTable (partition_id)
          ON DELETE CASCADE
      )
    ''');

    await database.execute('''
      CREATE TABLE IF NOT EXISTS $hotEntriesTable (
        partition_id TEXT NOT NULL,
        provider TEXT NOT NULL,
        provider_session_id TEXT NOT NULL,
        entry_id TEXT NOT NULL,
        entry_index INTEGER NOT NULL,
        content_hash TEXT NOT NULL,
        message_json TEXT NOT NULL,
        PRIMARY KEY (
          partition_id,
          provider,
          provider_session_id,
          entry_id
        ),
        FOREIGN KEY (partition_id, provider, provider_session_id)
          REFERENCES $hotWindowsTable (
            partition_id,
            provider,
            provider_session_id
          )
          ON DELETE CASCADE
      )
    ''');

    await database.execute('''
      CREATE INDEX IF NOT EXISTS conversation_hot_windows_recent
      ON $hotWindowsTable (partition_id, updated_at DESC)
    ''');

    await database.execute('''
      CREATE INDEX IF NOT EXISTS conversation_hot_entries_order
      ON $hotEntriesTable (
        partition_id,
        provider,
        provider_session_id,
        entry_index
      )
    ''');
  }

  static Future<void> _createConversationSyncSchema(Database database) async {
    await database.execute('''
      CREATE TABLE IF NOT EXISTS $syncStatesTable (
        partition_id TEXT PRIMARY KEY,
        catalog_state TEXT,
        status_state TEXT,
        priority_ready INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL,
        FOREIGN KEY (partition_id)
          REFERENCES $partitionsTable (partition_id)
          ON DELETE CASCADE
      )
    ''');

    await database.execute('''
      CREATE TABLE IF NOT EXISTS $statusesTable (
        partition_id TEXT NOT NULL,
        provider TEXT NOT NULL,
        provider_session_id TEXT NOT NULL,
        status_json TEXT NOT NULL,
        observed_sort INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (partition_id, provider, provider_session_id),
        FOREIGN KEY (partition_id)
          REFERENCES $partitionsTable (partition_id)
          ON DELETE CASCADE
      )
    ''');

    await database.execute('''
      CREATE TABLE IF NOT EXISTS $readWatermarksTable (
        partition_id TEXT NOT NULL,
        provider TEXT NOT NULL,
        provider_session_id TEXT NOT NULL,
        read_at TEXT NOT NULL,
        read_sort INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (partition_id, provider, provider_session_id),
        FOREIGN KEY (partition_id)
          REFERENCES $partitionsTable (partition_id)
          ON DELETE CASCADE
      )
    ''');

    await database.execute('''
      CREATE TABLE IF NOT EXISTS $timelineStagesTable (
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
        latest_turn_complete INTEGER NOT NULL DEFAULT 1,
        latest_turn_gap_json TEXT,
        latest_turn_gap_cursor TEXT,
        source_entry_count INTEGER NOT NULL,
        created_at INTEGER NOT NULL,
        PRIMARY KEY (
          partition_id,
          subscription_id,
          provider,
          provider_session_id,
          revision
        ),
        FOREIGN KEY (partition_id)
          REFERENCES $partitionsTable (partition_id)
          ON DELETE CASCADE
      )
    ''');

    await database.execute('''
      CREATE TABLE IF NOT EXISTS $timelineStagePagesTable (
        partition_id TEXT NOT NULL,
        subscription_id TEXT NOT NULL,
        provider TEXT NOT NULL,
        provider_session_id TEXT NOT NULL,
        revision TEXT NOT NULL,
        page_index INTEGER NOT NULL,
        PRIMARY KEY (
          partition_id,
          subscription_id,
          provider,
          provider_session_id,
          revision,
          page_index
        ),
        FOREIGN KEY (
          partition_id,
          subscription_id,
          provider,
          provider_session_id,
          revision
        ) REFERENCES $timelineStagesTable (
          partition_id,
          subscription_id,
          provider,
          provider_session_id,
          revision
        ) ON DELETE CASCADE
      )
    ''');

    await database.execute('''
      CREATE TABLE IF NOT EXISTS $timelineStageEntriesTable (
        partition_id TEXT NOT NULL,
        subscription_id TEXT NOT NULL,
        provider TEXT NOT NULL,
        provider_session_id TEXT NOT NULL,
        revision TEXT NOT NULL,
        page_index INTEGER NOT NULL,
        entry_id TEXT NOT NULL,
        entry_index INTEGER NOT NULL,
        content_hash TEXT NOT NULL,
        message_json TEXT NOT NULL,
        PRIMARY KEY (
          partition_id,
          subscription_id,
          provider,
          provider_session_id,
          revision,
          entry_id
        ),
        FOREIGN KEY (
          partition_id,
          subscription_id,
          provider,
          provider_session_id,
          revision
        ) REFERENCES $timelineStagesTable (
          partition_id,
          subscription_id,
          provider,
          provider_session_id,
          revision
        ) ON DELETE CASCADE
      )
    ''');

    await database.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS conversation_timeline_stage_order
      ON $timelineStageEntriesTable (
        partition_id,
        subscription_id,
        provider,
        provider_session_id,
        revision,
        entry_index
      )
    ''');

    await database.execute('''
      CREATE TABLE IF NOT EXISTS $timelineStageDeletesTable (
        partition_id TEXT NOT NULL,
        subscription_id TEXT NOT NULL,
        provider TEXT NOT NULL,
        provider_session_id TEXT NOT NULL,
        revision TEXT NOT NULL,
        page_index INTEGER NOT NULL,
        entry_id TEXT NOT NULL,
        PRIMARY KEY (
          partition_id,
          subscription_id,
          provider,
          provider_session_id,
          revision,
          entry_id
        ),
        FOREIGN KEY (
          partition_id,
          subscription_id,
          provider,
          provider_session_id,
          revision
        ) REFERENCES $timelineStagesTable (
          partition_id,
          subscription_id,
          provider,
          provider_session_id,
          revision
        ) ON DELETE CASCADE
      )
    ''');

    await database.execute('''
      CREATE INDEX IF NOT EXISTS conversation_sync_status_priority
      ON $statusesTable (partition_id, observed_sort DESC)
    ''');
    await database.execute('''
      CREATE INDEX IF NOT EXISTS conversation_read_watermarks_recent
      ON $readWatermarksTable (partition_id, read_sort DESC)
    ''');
    await database.execute('''
      CREATE INDEX IF NOT EXISTS conversation_timeline_stage_created
      ON $timelineStagesTable (partition_id, created_at)
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
