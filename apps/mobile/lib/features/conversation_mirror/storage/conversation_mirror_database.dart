import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import '../../../services/database_platform.dart';
import 'conversation_mirror_database_delete.dart';

typedef ConversationMirrorDatabaseOpener =
    Future<Database> Function(String databasePath, OpenDatabaseOptions options);

/// Owns the removable conversation-mirror database.
///
/// This database is deliberately separate from `ccpocket.db`, so removing the
/// feature cannot leave the official database at an unsupported schema version.
class ConversationMirrorDatabase {
  ConversationMirrorDatabase({this.databasePath, this.openDatabase});

  static const fileName = 'conversation_mirror_v1.db';
  static const schemaVersion = 1;

  static const metadataTable = 'conversation_mirror_metadata';
  static const displayMetadataTable = 'conversation_mirror_display_metadata';
  static const entriesTable = 'conversation_mirror_entries';
  static const stagingTable = 'conversation_mirror_staging';
  static const stagingPagesTable = 'conversation_mirror_staging_pages';

  final String? databasePath;
  final ConversationMirrorDatabaseOpener? openDatabase;
  Future<Database>? _databaseFuture;
  bool _closed = false;

  Future<Database> get database {
    if (_closed) {
      return Future.error(
        StateError('Conversation mirror database is already closed.'),
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
    final Database db;
    if (customOpen != null) {
      db = await customOpen(await resolvedPath, _openOptions());
    } else {
      if (kIsWeb) {
        throw UnsupportedError(
          'Conversation mirror storage is unavailable on web.',
        );
      }
      final platformConfig = databasePath == null
          ? await getPlatformDatabaseOpenConfig(fileName)
          : null;
      if (platformConfig != null) {
        db = await _openPlatformWithDowngradeRecovery(platformConfig);
      } else {
        db = await databaseFactory.openDatabase(
          await resolvedPath,
          options: _openOptions(),
        );
      }
    }
    // The existing Linux/Windows opener does not expose onConfigure. Setting
    // the pragma after open keeps foreign-key enforcement identical there.
    await db.execute('PRAGMA foreign_keys = ON');
    await _createDisplayMetadataSchema(db);
    await _enableIncrementalAutoVacuum(db);
    await _cleanupInterruptedGenerations(db);
    return db;
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

  static Future<Database> _openWithPlatformConfig(
    PlatformDatabaseOpenConfig platformConfig,
  ) => platformConfig.open(
    version: schemaVersion,
    onCreate: _createSchema,
    onUpgrade: _upgradeSchema,
  );

  static Future<Database> _openPlatformWithDowngradeRecovery(
    PlatformDatabaseOpenConfig platformConfig,
  ) async {
    await prepareConversationMirrorLegacyDatabaseForOpen(
      platformConfig.path,
      schemaVersion: schemaVersion,
    );
    return _openWithPlatformConfig(platformConfig);
  }

  static Future<void> _upgradeSchema(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    // v1 is the pre-release baseline. A future breaking schema must use a new
    // database filename (for example conversation_mirror_v2.db) so an older
    // binary cannot reinterpret newer user_version state.
  }

  static Future<void> _createSchema(Database db, int version) async {
    await db.execute('''
      CREATE TABLE $metadataTable (
        bridge_instance_id TEXT NOT NULL,
        provider TEXT NOT NULL,
        provider_session_id TEXT NOT NULL,
        active_generation TEXT,
        revision TEXT,
        entry_count INTEGER NOT NULL DEFAULT 0,
        bytes INTEGER NOT NULL DEFAULT 0,
        auto_sync INTEGER NOT NULL DEFAULT 0,
        project_path TEXT NOT NULL DEFAULT '',
        last_synced_at TEXT,
        error TEXT,
        PRIMARY KEY (
          bridge_instance_id,
          provider,
          provider_session_id
        )
      )
    ''');

    await _createDisplayMetadataSchema(db);

    await db.execute('''
      CREATE TABLE $entriesTable (
        bridge_instance_id TEXT NOT NULL,
        provider TEXT NOT NULL,
        provider_session_id TEXT NOT NULL,
        generation TEXT NOT NULL,
        entry_id TEXT NOT NULL,
        ordinal INTEGER NOT NULL,
        content_hash TEXT NOT NULL,
        message_json TEXT NOT NULL,
        entry_bytes INTEGER NOT NULL,
        PRIMARY KEY (
          bridge_instance_id,
          provider,
          provider_session_id,
          generation,
          entry_id
        ),
        FOREIGN KEY (
          bridge_instance_id,
          provider,
          provider_session_id
        ) REFERENCES $metadataTable (
          bridge_instance_id,
          provider,
          provider_session_id
        ) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE UNIQUE INDEX conversation_mirror_entries_ordinal
      ON $entriesTable (
        bridge_instance_id,
        provider,
        provider_session_id,
        generation,
        ordinal
      )
    ''');

    await db.execute('''
      CREATE TABLE $stagingTable (
        bridge_instance_id TEXT NOT NULL,
        provider TEXT NOT NULL,
        provider_session_id TEXT NOT NULL,
        generation TEXT NOT NULL,
        target_revision TEXT NOT NULL,
        base_active_generation TEXT,
        base_revision TEXT,
        expected_entry_count INTEGER NOT NULL,
        expected_page_count INTEGER NOT NULL,
        expected_bytes INTEGER NOT NULL,
        actual_entry_count INTEGER NOT NULL DEFAULT 0,
        actual_bytes INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        PRIMARY KEY (
          bridge_instance_id,
          provider,
          provider_session_id,
          generation
        ),
        FOREIGN KEY (
          bridge_instance_id,
          provider,
          provider_session_id
        ) REFERENCES $metadataTable (
          bridge_instance_id,
          provider,
          provider_session_id
        ) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE $stagingPagesTable (
        bridge_instance_id TEXT NOT NULL,
        provider TEXT NOT NULL,
        provider_session_id TEXT NOT NULL,
        generation TEXT NOT NULL,
        page_index INTEGER NOT NULL,
        page_digest TEXT NOT NULL,
        entry_count INTEGER NOT NULL,
        bytes INTEGER NOT NULL,
        PRIMARY KEY (
          bridge_instance_id,
          provider,
          provider_session_id,
          generation,
          page_index
        ),
        FOREIGN KEY (
          bridge_instance_id,
          provider,
          provider_session_id,
          generation
        ) REFERENCES $stagingTable (
          bridge_instance_id,
          provider,
          provider_session_id,
          generation
        ) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE INDEX conversation_mirror_auto_sync
      ON $metadataTable (auto_sync, last_synced_at)
    ''');
  }

  /// Additive display metadata stays in a separate table so older v1 clients
  /// can keep reading the same mirror database without a schema downgrade.
  static Future<void> _createDisplayMetadataSchema(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $displayMetadataTable (
        bridge_instance_id TEXT NOT NULL,
        provider TEXT NOT NULL,
        provider_session_id TEXT NOT NULL,
        name TEXT,
        summary TEXT,
        first_prompt TEXT,
        updated_at TEXT NOT NULL,
        PRIMARY KEY (
          bridge_instance_id,
          provider,
          provider_session_id
        ),
        FOREIGN KEY (
          bridge_instance_id,
          provider,
          provider_session_id
        ) REFERENCES $metadataTable (
          bridge_instance_id,
          provider,
          provider_session_id
        ) ON DELETE CASCADE
      )
    ''');
  }

  static Future<void> _enableIncrementalAutoVacuum(Database db) async {
    final current = Sqflite.firstIntValue(
      await db.rawQuery('PRAGMA auto_vacuum'),
    );
    if (current == 2) return;
    // This one-time conversion happens only for the independent rebuildable
    // mirror database. Later user removals can reclaim tail pages incrementally
    // instead of blocking on a full VACUUM.
    await db.execute('PRAGMA auto_vacuum = INCREMENTAL');
    await db.execute('VACUUM');
  }

  /// A generation becomes durable only when metadata points at it. Any other
  /// generation is an interrupted shadow transfer and is safe to discard when
  /// the app next opens this feature database.
  static Future<void> _cleanupInterruptedGenerations(Database db) async {
    await db.transaction((txn) async {
      final interrupted = await txn.query(
        stagingTable,
        columns: [
          'bridge_instance_id',
          'provider',
          'provider_session_id',
          'generation',
        ],
      );
      for (final generation in interrupted) {
        // Shadow entry rows and their staging marker are committed together.
        // Starting from the normally tiny staging set avoids scanning every
        // active entry on each database open. The active-generation guard
        // preserves the last known-good copy if the database is inconsistent.
        await txn.execute(
          '''
          DELETE FROM $entriesTable
          WHERE bridge_instance_id = ?
            AND provider = ?
            AND provider_session_id = ?
            AND generation = ?
            AND NOT EXISTS (
              SELECT 1
              FROM $metadataTable AS metadata
              WHERE metadata.bridge_instance_id =
                      $entriesTable.bridge_instance_id
                AND metadata.provider = $entriesTable.provider
                AND metadata.provider_session_id =
                      $entriesTable.provider_session_id
                AND metadata.active_generation = $entriesTable.generation
            )
          ''',
          [
            generation['bridge_instance_id'],
            generation['provider'],
            generation['provider_session_id'],
            generation['generation'],
          ],
        );
      }
      await txn.delete(stagingTable);
    });
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
      // A failed open owns no live database handle. Closing remains idempotent
      // and must not rethrow an initialization error already reported upstream.
      return;
    }
    await database.close();
  }
}
