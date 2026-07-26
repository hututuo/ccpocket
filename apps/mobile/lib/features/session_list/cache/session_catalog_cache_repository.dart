import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

import '../../../models/messages.dart';
import 'session_catalog_cache_database.dart';

class SessionCatalogCacheTarget {
  SessionCatalogCacheTarget._({
    required this.canonicalPartitionId,
    required this.aliasKeys,
  });

  factory SessionCatalogCacheTarget.fromBridge({
    String? bridgeInstanceId,
    String? logicalConnectionIdentity,
    String? websocketUrl,
  }) {
    final canonical = _opaqueKey('bridge', bridgeInstanceId);
    final aliases = <String>{
      ?_opaqueKey('logical', logicalConnectionIdentity),
      ?_opaqueKey('endpoint', _normalizedEndpoint(websocketUrl)),
    }.toList(growable: false);
    return SessionCatalogCacheTarget._(
      canonicalPartitionId: canonical,
      aliasKeys: aliases,
    );
  }

  final String? canonicalPartitionId;
  final List<String> aliasKeys;

  bool get isValid => canonicalPartitionId != null || aliasKeys.isNotEmpty;

  String get fingerprint => canonicalPartitionId ?? aliasKeys.join('|');

  static String? _opaqueKey(String prefix, String? value) {
    final normalized = value?.trim();
    if (normalized == null || normalized.isEmpty) return null;
    final digest = sha256.convert(utf8.encode(normalized));
    return '$prefix:$digest';
  }

  static String? _normalizedEndpoint(String? value) {
    final uri = Uri.tryParse(value?.trim() ?? '');
    if (uri == null || uri.host.isEmpty) return null;
    final scheme = uri.scheme.toLowerCase();
    final host = uri.host.toLowerCase();
    final displayHost = host.contains(':') ? '[$host]' : host;
    final secure = scheme == 'wss' || scheme == 'https';
    final port = uri.hasPort ? uri.port : (secure ? 443 : 80);
    final endpointPath = uri.path.isEmpty ? '/' : uri.path;
    // User info, query parameters, and fragments may contain credentials.
    return '$scheme://$displayHost:$port$endpointPath';
  }
}

class SessionCatalogCacheSnapshot {
  const SessionCatalogCacheSnapshot({
    required this.partitionId,
    required this.sessions,
    required this.catalogRevision,
    required this.isComplete,
    required this.cachedAt,
  });

  final String partitionId;
  final List<RecentSession> sessions;
  final int? catalogRevision;
  final bool isComplete;
  final DateTime cachedAt;
}

class SessionCatalogCacheRepository {
  SessionCatalogCacheRepository(this.database);

  static const maxEntriesPerPartition = 10_000;

  final SessionCatalogCacheDatabase database;
  Future<void> _mutationTail = Future<void>.value();

  Future<SessionCatalogCacheSnapshot?> load(
    SessionCatalogCacheTarget target,
  ) async {
    if (!target.isValid) return null;
    await _mutationTail;
    final db = await database.database;
    final partitionId = await _resolveReadablePartition(db, target);
    if (partitionId == null) return null;
    final metadata = await db.query(
      SessionCatalogCacheDatabase.partitionsTable,
      columns: ['last_server_revision', 'complete_revision', 'updated_at'],
      where: 'partition_id = ?',
      whereArgs: [partitionId],
      limit: 1,
    );
    if (metadata.isEmpty) return null;

    final rows = await db.query(
      SessionCatalogCacheDatabase.entriesTable,
      columns: ['session_json'],
      where: 'partition_id = ?',
      whereArgs: [partitionId],
      orderBy: 'modified_sort DESC, cached_at DESC',
      limit: maxEntriesPerPartition,
    );
    final sessions = <RecentSession>[];
    for (final row in rows) {
      try {
        final decoded = jsonDecode(row['session_json']! as String);
        if (decoded is Map<String, dynamic>) {
          sessions.add(RecentSession.fromJson(decoded));
        } else if (decoded is Map) {
          sessions.add(
            RecentSession.fromJson(Map<String, dynamic>.from(decoded)),
          );
        }
      } catch (_) {
        // This cache is rebuildable. A damaged row must not block every other
        // cached session or the live Bridge refresh that will replace it.
      }
    }
    if (rows.isNotEmpty && sessions.isEmpty) return null;
    final values = metadata.single;
    final serverRevision = values['last_server_revision'] as int?;
    final completeRevision = values['complete_revision'] as int?;
    return SessionCatalogCacheSnapshot(
      partitionId: partitionId,
      sessions: List<RecentSession>.unmodifiable(sessions),
      catalogRevision: serverRevision,
      isComplete:
          sessions.length == rows.length &&
          completeRevision != null &&
          (serverRevision == null || completeRevision == serverRevision),
      cachedAt: DateTime.fromMillisecondsSinceEpoch(
        values['updated_at']! as int,
        isUtc: true,
      ),
    );
  }

  Future<void> upsertResponse({
    required SessionCatalogCacheTarget target,
    required RecentSessionsMessage response,
  }) {
    if (!target.isValid) return Future<void>.value();
    return _enqueueMutation(() async {
      final db = await database.database;
      await db.transaction((transaction) async {
        final partitionId = await _ensureWritablePartition(transaction, target);
        final now = DateTime.now().toUtc().millisecondsSinceEpoch;
        final authoritativeReplacement = _isAuthoritativeReplacement(response);
        if (authoritativeReplacement) {
          await transaction.delete(
            SessionCatalogCacheDatabase.entriesTable,
            where: 'partition_id = ?',
            whereArgs: [partitionId],
          );
        }
        for (final session in response.sessions) {
          await transaction.insert(
            SessionCatalogCacheDatabase.entriesTable,
            {
              'partition_id': partitionId,
              'provider': session.provider ?? Provider.claude.value,
              'project_path': session.projectPath,
              'session_id': session.sessionId,
              'session_json': jsonEncode(session.toJson()),
              'modified_sort': _sessionModifiedSort(session),
              'cached_at': now,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await _updatePartitionMetadata(
          transaction,
          partitionId: partitionId,
          response: response,
          authoritativeReplacement: authoritativeReplacement,
          now: now,
        );
        await _prunePartition(transaction, partitionId);
      });
    });
  }

  Future<void> deleteSession({
    required SessionCatalogCacheTarget target,
    required RecentSession session,
  }) {
    if (!target.isValid) return Future<void>.value();
    return _enqueueMutation(() async {
      final db = await database.database;
      final partitionId = await _resolveReadablePartition(db, target);
      if (partitionId == null) return;
      await db.delete(
        SessionCatalogCacheDatabase.entriesTable,
        where:
            'partition_id = ? AND provider = ? AND project_path = ? '
            'AND session_id = ?',
        whereArgs: [
          partitionId,
          session.provider ?? Provider.claude.value,
          session.projectPath,
          session.sessionId,
        ],
      );
      await db.update(
        SessionCatalogCacheDatabase.partitionsTable,
        {'updated_at': DateTime.now().toUtc().millisecondsSinceEpoch},
        where: 'partition_id = ?',
        whereArgs: [partitionId],
      );
    });
  }

  Future<void> clearAll() {
    return _enqueueMutation(() async {
      final db = await database.database;
      await db.delete(SessionCatalogCacheDatabase.partitionsTable);
    });
  }

  Future<int> countSessions(SessionCatalogCacheTarget target) async {
    if (!target.isValid) return 0;
    await _mutationTail;
    final db = await database.database;
    final partitionId = await _resolveReadablePartition(db, target);
    if (partitionId == null) return 0;
    final rows = await db.rawQuery(
      '''
      SELECT COUNT(*) AS entry_count
      FROM ${SessionCatalogCacheDatabase.entriesTable}
      WHERE partition_id = ?
      ''',
      [partitionId],
    );
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  Future<void> close() async {
    await _mutationTail;
    await database.close();
  }

  Future<void> _enqueueMutation(Future<void> Function() operation) {
    final next = _mutationTail.then((_) => operation());
    _mutationTail = next.catchError((_) {});
    return next;
  }

  static bool _isAuthoritativeReplacement(RecentSessionsMessage response) {
    final scope = response.requestScope;
    final isTopLevelScope =
        scope == null || scope == 'list' || scope == 'catalog';
    return isTopLevelScope &&
        (response.offset ?? 0) == 0 &&
        response.projectPath == null &&
        response.provider == null &&
        response.namedOnly != true &&
        (response.searchQuery == null || response.searchQuery!.isEmpty) &&
        !response.hasMore;
  }

  static int _sessionModifiedSort(RecentSession session) {
    final modified = DateTime.tryParse(session.modified);
    if (modified != null) return modified.toUtc().millisecondsSinceEpoch;
    final created = DateTime.tryParse(session.created);
    return created?.toUtc().millisecondsSinceEpoch ?? 0;
  }

  static Future<String?> _resolveReadablePartition(
    DatabaseExecutor database,
    SessionCatalogCacheTarget target,
  ) async {
    final canonical = target.canonicalPartitionId;
    if (canonical != null) {
      final canonicalRows = await database.query(
        SessionCatalogCacheDatabase.partitionsTable,
        columns: ['partition_id'],
        where: 'partition_id = ? AND canonical_key = ?',
        whereArgs: [canonical, canonical],
        limit: 1,
      );
      if (canonicalRows.isNotEmpty) return canonical;
      for (final alias in target.aliasKeys) {
        final aliasPartition = await _partitionForAlias(database, alias);
        if (aliasPartition == null) continue;
        final aliasMetadata = await _partitionMetadata(
          database,
          aliasPartition,
        );
        if (aliasMetadata?['canonical_key'] == null) return aliasPartition;
      }
      return null;
    }
    for (final alias in target.aliasKeys) {
      final partitionId = await _partitionForAlias(database, alias);
      if (partitionId != null) return partitionId;
    }
    return null;
  }

  static Future<String> _ensureWritablePartition(
    Transaction transaction,
    SessionCatalogCacheTarget target,
  ) async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final canonical = target.canonicalPartitionId;
    if (canonical == null) {
      for (final alias in target.aliasKeys) {
        final existing = await _partitionForAlias(transaction, alias);
        if (existing != null) {
          await _bindAliases(transaction, target.aliasKeys, existing, now);
          return existing;
        }
      }
      final provisional = target.aliasKeys.first;
      await transaction.insert(
        SessionCatalogCacheDatabase.partitionsTable,
        {'partition_id': provisional, 'canonical_key': null, 'updated_at': now},
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      await _bindAliases(transaction, target.aliasKeys, provisional, now);
      return provisional;
    }

    await transaction.insert(
      SessionCatalogCacheDatabase.partitionsTable,
      {
        'partition_id': canonical,
        'canonical_key': canonical,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    for (final alias in target.aliasKeys) {
      final previous = await _partitionForAlias(transaction, alias);
      if (previous == null || previous == canonical) continue;
      final metadata = await _partitionMetadata(transaction, previous);
      if (metadata != null && metadata['canonical_key'] == null) {
        await _mergeProvisionalPartition(
          transaction,
          sourcePartitionId: previous,
          targetPartitionId: canonical,
          now: now,
        );
      }
    }
    await _bindAliases(transaction, target.aliasKeys, canonical, now);
    return canonical;
  }

  static Future<String?> _partitionForAlias(
    DatabaseExecutor database,
    String alias,
  ) async {
    final rows = await database.query(
      SessionCatalogCacheDatabase.aliasesTable,
      columns: ['partition_id'],
      where: 'alias_key = ?',
      whereArgs: [alias],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.single['partition_id'] as String;
  }

  static Future<Map<String, Object?>?> _partitionMetadata(
    DatabaseExecutor database,
    String partitionId,
  ) async {
    final rows = await database.query(
      SessionCatalogCacheDatabase.partitionsTable,
      where: 'partition_id = ?',
      whereArgs: [partitionId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.single;
  }

  static Future<void> _bindAliases(
    Transaction transaction,
    Iterable<String> aliases,
    String partitionId,
    int now,
  ) async {
    for (final alias in aliases) {
      await transaction.insert(
        SessionCatalogCacheDatabase.aliasesTable,
        {'alias_key': alias, 'partition_id': partitionId, 'updated_at': now},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }

  static Future<void> _mergeProvisionalPartition(
    Transaction transaction, {
    required String sourcePartitionId,
    required String targetPartitionId,
    required int now,
  }) async {
    if (sourcePartitionId == targetPartitionId) return;
    final sourceMetadata = await _partitionMetadata(
      transaction,
      sourcePartitionId,
    );
    if (sourceMetadata == null || sourceMetadata['canonical_key'] != null) {
      return;
    }
    final sourceAliases = await transaction.query(
      SessionCatalogCacheDatabase.aliasesTable,
      columns: ['alias_key'],
      where: 'partition_id = ?',
      whereArgs: [sourcePartitionId],
    );
    final sourceEntries = await transaction.query(
      SessionCatalogCacheDatabase.entriesTable,
      where: 'partition_id = ?',
      whereArgs: [sourcePartitionId],
    );
    for (final sourceEntry in sourceEntries) {
      final provider = sourceEntry['provider']! as String;
      final projectPath = sourceEntry['project_path']! as String;
      final sessionId = sourceEntry['session_id']! as String;
      final targetRows = await transaction.query(
        SessionCatalogCacheDatabase.entriesTable,
        columns: ['modified_sort', 'cached_at'],
        where:
            'partition_id = ? AND provider = ? AND project_path = ? '
            'AND session_id = ?',
        whereArgs: [targetPartitionId, provider, projectPath, sessionId],
        limit: 1,
      );
      final sourceModified = sourceEntry['modified_sort']! as int;
      final sourceCachedAt = sourceEntry['cached_at']! as int;
      final targetIsNewer =
          targetRows.isNotEmpty &&
          (((targetRows.single['modified_sort']! as int) > sourceModified) ||
              ((targetRows.single['modified_sort']! as int) == sourceModified &&
                  (targetRows.single['cached_at']! as int) >= sourceCachedAt));
      if (targetIsNewer) continue;
      await transaction.insert(
        SessionCatalogCacheDatabase.entriesTable,
        {...sourceEntry, 'partition_id': targetPartitionId},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }

    final targetMetadata = await _partitionMetadata(
      transaction,
      targetPartitionId,
    );
    final sourceRevision = sourceMetadata['last_server_revision'] as int?;
    final targetRevision = targetMetadata?['last_server_revision'] as int?;
    final sourceComplete = sourceMetadata['complete_revision'] as int?;
    final targetComplete = targetMetadata?['complete_revision'] as int?;
    await transaction.update(
      SessionCatalogCacheDatabase.partitionsTable,
      {
        'last_server_revision': _maxNullable(sourceRevision, targetRevision),
        'complete_revision': _maxNullable(sourceComplete, targetComplete),
        'updated_at': now,
      },
      where: 'partition_id = ?',
      whereArgs: [targetPartitionId],
    );

    await transaction.delete(
      SessionCatalogCacheDatabase.partitionsTable,
      where: 'partition_id = ?',
      whereArgs: [sourcePartitionId],
    );
    await _bindAliases(
      transaction,
      sourceAliases.map((row) => row['alias_key']! as String),
      targetPartitionId,
      now,
    );
  }

  static Future<void> _updatePartitionMetadata(
    Transaction transaction, {
    required String partitionId,
    required RecentSessionsMessage response,
    required bool authoritativeReplacement,
    required int now,
  }) async {
    final current = await _partitionMetadata(transaction, partitionId);
    final currentServerRevision = current?['last_server_revision'] as int?;
    final currentCompleteRevision = current?['complete_revision'] as int?;
    final responseRevision = switch (response.catalogRevision) {
      final int revision when revision >= 0 => revision,
      _ => null,
    };
    final serverRevision = responseRevision ?? currentServerRevision;
    final completeRevision = authoritativeReplacement
        ? responseRevision ?? -1
        : responseRevision != null &&
              currentCompleteRevision != responseRevision
        ? null
        : currentCompleteRevision;
    await transaction.update(
      SessionCatalogCacheDatabase.partitionsTable,
      {
        'last_server_revision': serverRevision,
        'complete_revision': completeRevision,
        'updated_at': now,
      },
      where: 'partition_id = ?',
      whereArgs: [partitionId],
    );
  }

  static Future<void> _prunePartition(
    Transaction transaction,
    String partitionId,
  ) async {
    final countRows = await transaction.rawQuery(
      '''
      SELECT COUNT(*) AS entry_count
      FROM ${SessionCatalogCacheDatabase.entriesTable}
      WHERE partition_id = ?
      ''',
      [partitionId],
    );
    final count = Sqflite.firstIntValue(countRows) ?? 0;
    if (count <= maxEntriesPerPartition) return;
    await transaction.rawDelete(
      '''
      DELETE FROM ${SessionCatalogCacheDatabase.entriesTable}
      WHERE partition_id = ?
        AND rowid NOT IN (
          SELECT rowid
          FROM ${SessionCatalogCacheDatabase.entriesTable}
          WHERE partition_id = ?
          ORDER BY modified_sort DESC, cached_at DESC
          LIMIT ?
        )
      ''',
      [partitionId, partitionId, maxEntriesPerPartition],
    );
  }

  static int? _maxNullable(int? left, int? right) {
    if (left == null) return right;
    if (right == null) return left;
    return left > right ? left : right;
  }
}
