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
    String? codexSourceId,
    String? logicalConnectionIdentity,
    String? websocketUrl,
  }) {
    final normalizedBridge = bridgeInstanceId?.trim();
    final normalizedCodexSource = codexSourceId?.trim();
    final canonicalIdentity = _bridgePartitionIdentity(
      bridgeInstanceId: normalizedBridge,
      codexSourceId: normalizedCodexSource,
    );
    final canonical = _opaqueKey('bridge', canonicalIdentity);
    String? sourceScopedAlias(String? value) {
      final normalized = value?.trim();
      if (normalized == null || normalized.isEmpty) return null;
      return normalizedCodexSource == null || normalizedCodexSource.isEmpty
          ? normalized
          : '$normalized\u0000$normalizedCodexSource';
    }

    final aliases = <String>{
      ?_opaqueKey('logical', sourceScopedAlias(logicalConnectionIdentity)),
      ?_opaqueKey(
        'endpoint',
        sourceScopedAlias(_normalizedEndpoint(websocketUrl)),
      ),
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

class ConversationHotWindowSnapshot {
  const ConversationHotWindowSnapshot({
    required this.partitionId,
    required this.provider,
    required this.providerSessionId,
    required this.revision,
    required this.entries,
    required this.hasEarlier,
    required this.turnsNextCursor,
    required this.sourceEntryCount,
    required this.cachedAt,
  });

  final String partitionId;
  final String provider;
  final String providerSessionId;
  final String revision;
  final List<ConversationContentWireEntry> entries;
  final bool hasEarlier;
  final String? turnsNextCursor;
  final int sourceEntryCount;
  final DateTime cachedAt;
}

class ConversationSyncCacheState {
  const ConversationSyncCacheState({
    required this.catalogState,
    required this.statusState,
    required this.priorityReady,
    required this.updatedAt,
  });

  const ConversationSyncCacheState.empty()
    : catalogState = null,
      statusState = null,
      priorityReady = false,
      updatedAt = null;

  final String? catalogState;
  final String? statusState;
  final bool priorityReady;
  final DateTime? updatedAt;
}

class ConversationTimelinePageCommit {
  const ConversationTimelinePageCommit({
    required this.pageStored,
    required this.windowCommitted,
    required this.baseRevisionMatched,
  });

  final bool pageStored;
  final bool windowCommitted;
  final bool baseRevisionMatched;
}

class SessionCatalogCacheStats {
  const SessionCatalogCacheStats({
    required this.sessionSummaries,
    required this.conversationWindows,
  });

  const SessionCatalogCacheStats.empty()
    : sessionSummaries = 0,
      conversationWindows = 0;

  final int sessionSummaries;
  final int conversationWindows;
}

class SessionCatalogCacheIdentity {
  const SessionCatalogCacheIdentity({
    required this.bridgeInstanceId,
    required this.provider,
    required this.providerSessionId,
    this.codexSourceId,
  });

  final String bridgeInstanceId;
  final String provider;
  final String providerSessionId;
  final String? codexSourceId;

  bool get isValid =>
      _bridgePartitionIdentity(
            bridgeInstanceId: bridgeInstanceId,
            codexSourceId: codexSourceId,
          ) !=
          null &&
      provider.trim().isNotEmpty &&
      providerSessionId.trim().isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is SessionCatalogCacheIdentity &&
      other.bridgeInstanceId == bridgeInstanceId &&
      other.provider == provider &&
      other.providerSessionId == providerSessionId &&
      other.codexSourceId == codexSourceId;

  @override
  int get hashCode =>
      Object.hash(bridgeInstanceId, provider, providerSessionId, codexSourceId);
}

String? _bridgePartitionIdentity({
  required String? bridgeInstanceId,
  required String? codexSourceId,
}) {
  final bridge = bridgeInstanceId?.trim();
  if (bridge == null || bridge.isEmpty) return null;
  final source = codexSourceId?.trim();
  return source == null || source.isEmpty ? bridge : '$bridge\u0000$source';
}

class SessionCatalogCacheRepository {
  SessionCatalogCacheRepository(this.database);

  static const maxEntriesPerPartition = 10_000;
  static const maxHotWindowEntries = 2_000;
  static const _maxIdentityLookupsPerQuery = 300;

  final SessionCatalogCacheDatabase database;
  Future<void> _mutationTail = Future<void>.value();
  bool _closed = false;

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
      await db.delete(
        SessionCatalogCacheDatabase.hotWindowsTable,
        where: 'partition_id = ? AND provider = ? AND provider_session_id = ?',
        whereArgs: [
          partitionId,
          session.provider ?? Provider.claude.value,
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

  Future<int> countAllSessions() async {
    await _mutationTail;
    final db = await database.database;
    final rows = await db.rawQuery('''
      SELECT COUNT(*) AS entry_count
      FROM ${SessionCatalogCacheDatabase.entriesTable}
      ''');
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  Future<SessionCatalogCacheStats> cacheStats() async {
    await _mutationTail;
    final db = await database.database;
    final rows = await db.rawQuery('''
      SELECT
        (SELECT COUNT(*)
         FROM ${SessionCatalogCacheDatabase.entriesTable}) AS session_count,
        (SELECT COUNT(*)
         FROM ${SessionCatalogCacheDatabase.hotWindowsTable}) AS window_count
      ''');
    final row = rows.single;
    return SessionCatalogCacheStats(
      sessionSummaries: row['session_count'] as int? ?? 0,
      conversationWindows: row['window_count'] as int? ?? 0,
    );
  }

  Future<RecentSession?> findSessionByIdentity({
    required String bridgeInstanceId,
    required String provider,
    required String providerSessionId,
    String? codexSourceId,
  }) async {
    final identity = SessionCatalogCacheIdentity(
      bridgeInstanceId: bridgeInstanceId,
      provider: provider,
      providerSessionId: providerSessionId,
      codexSourceId: codexSourceId,
    );
    return (await findSessionsByIdentities([identity]))[identity];
  }

  Future<Map<SessionCatalogCacheIdentity, RecentSession>>
  findSessionsByIdentities(
    Iterable<SessionCatalogCacheIdentity> identities,
  ) async {
    final requested = identities.where((identity) => identity.isValid).toSet();
    if (requested.isEmpty) return const {};
    await _mutationTail;
    final db = await database.database;

    final lookupByStorageIdentity =
        <
          ({String partitionId, String provider, String providerSessionId}),
          SessionCatalogCacheIdentity
        >{};
    for (final identity in requested) {
      final bridgePartitionIdentity = _bridgePartitionIdentity(
        bridgeInstanceId: identity.bridgeInstanceId,
        codexSourceId: identity.codexSourceId,
      );
      final partitionId = SessionCatalogCacheTarget._opaqueKey(
        'bridge',
        bridgePartitionIdentity,
      );
      if (partitionId == null) continue;
      lookupByStorageIdentity[(
            partitionId: partitionId,
            provider: identity.provider,
            providerSessionId: identity.providerSessionId,
          )] =
          identity;
    }

    final storageIdentities = lookupByStorageIdentity.keys.toList(
      growable: false,
    );
    final result = <SessionCatalogCacheIdentity, RecentSession>{};
    for (
      var offset = 0;
      offset < storageIdentities.length;
      offset += _maxIdentityLookupsPerQuery
    ) {
      final end = (offset + _maxIdentityLookupsPerQuery).clamp(
        0,
        storageIdentities.length,
      );
      final batch = storageIdentities.sublist(offset, end);
      final where = List.filled(
        batch.length,
        '(partition_id = ? AND provider = ? AND session_id = ?)',
      ).join(' OR ');
      final whereArgs = <Object?>[
        for (final identity in batch) ...[
          identity.partitionId,
          identity.provider,
          identity.providerSessionId,
        ],
      ];
      final rows = await db.query(
        SessionCatalogCacheDatabase.entriesTable,
        columns: ['partition_id', 'provider', 'session_id', 'session_json'],
        where: where,
        whereArgs: whereArgs,
        orderBy: 'modified_sort DESC, cached_at DESC',
      );
      for (final row in rows) {
        final identity =
            lookupByStorageIdentity[(
              partitionId: row['partition_id']! as String,
              provider: row['provider']! as String,
              providerSessionId: row['session_id']! as String,
            )];
        if (identity == null || result.containsKey(identity)) continue;
        try {
          final decoded = jsonDecode(row['session_json']! as String);
          if (decoded is Map<String, dynamic>) {
            result[identity] = RecentSession.fromJson(decoded);
          } else if (decoded is Map) {
            result[identity] = RecentSession.fromJson(
              Map<String, dynamic>.from(decoded),
            );
          }
        } catch (_) {
          // Display metadata is optional and the catalog is rebuildable. A
          // damaged row must not hide titles that were decoded successfully.
        }
      }
    }
    return Map.unmodifiable(result);
  }

  Future<List<ConversationContentCursor>> knownConversationRevisions(
    SessionCatalogCacheTarget target, {
    int limit = 512,
  }) async {
    if (!target.isValid || limit <= 0) return const [];
    await _mutationTail;
    final db = await database.database;
    final partitionId = await _resolveReadablePartition(db, target);
    if (partitionId == null) return const [];
    final rows = await db.query(
      SessionCatalogCacheDatabase.hotWindowsTable,
      columns: ['provider', 'provider_session_id', 'revision'],
      where: 'partition_id = ?',
      whereArgs: [partitionId],
      orderBy: 'updated_at DESC',
      limit: limit.clamp(1, 512),
    );
    return List<ConversationContentCursor>.unmodifiable(
      rows.map(
        (row) => ConversationContentCursor(
          provider: row['provider']! as String,
          providerSessionId: row['provider_session_id']! as String,
          revision: row['revision']! as String,
        ),
      ),
    );
  }

  Future<ConversationSyncCacheState> loadConversationSyncState(
    SessionCatalogCacheTarget target,
  ) async {
    if (!target.isValid) return const ConversationSyncCacheState.empty();
    await _mutationTail;
    final db = await database.database;
    final partitionId = await _resolveReadablePartition(db, target);
    if (partitionId == null) {
      return const ConversationSyncCacheState.empty();
    }
    final rows = await db.query(
      SessionCatalogCacheDatabase.syncStatesTable,
      where: 'partition_id = ?',
      whereArgs: [partitionId],
      limit: 1,
    );
    if (rows.isEmpty) return const ConversationSyncCacheState.empty();
    final row = rows.single;
    return ConversationSyncCacheState(
      catalogState: row['catalog_state'] as String?,
      statusState: row['status_state'] as String?,
      priorityReady: (row['priority_ready'] as int? ?? 0) != 0,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        row['updated_at']! as int,
        isUtc: true,
      ),
    );
  }

  Future<List<ConversationSyncV2Status>> loadConversationStatuses(
    SessionCatalogCacheTarget target, {
    int limit = 10_000,
  }) async {
    if (!target.isValid || limit <= 0) return const [];
    await _mutationTail;
    final db = await database.database;
    final partitionId = await _resolveReadablePartition(db, target);
    if (partitionId == null) return const [];
    final rows = await db.query(
      SessionCatalogCacheDatabase.statusesTable,
      columns: ['status_json'],
      where: 'partition_id = ?',
      whereArgs: [partitionId],
      orderBy: 'observed_sort DESC',
      limit: limit.clamp(1, maxEntriesPerPartition),
    );
    final statuses = <ConversationSyncV2Status>[];
    for (final row in rows) {
      try {
        final decoded = jsonDecode(row['status_json']! as String);
        if (decoded is Map) {
          statuses.add(
            ConversationSyncV2Status.fromJson(
              Map<String, dynamic>.from(decoded),
            ),
          );
        }
      } catch (_) {
        // The status projection is rebuildable; one bad row is isolated.
      }
    }
    return List.unmodifiable(statuses);
  }

  Future<List<ConversationSyncV2ReadWatermark>> loadReadWatermarks(
    SessionCatalogCacheTarget target, {
    int limit = 512,
  }) async {
    if (!target.isValid || limit <= 0) return const [];
    await _mutationTail;
    final db = await database.database;
    final partitionId = await _resolveReadablePartition(db, target);
    if (partitionId == null) return const [];
    final rows = await db.query(
      SessionCatalogCacheDatabase.readWatermarksTable,
      where: 'partition_id = ?',
      whereArgs: [partitionId],
      orderBy: 'read_sort DESC',
      limit: limit.clamp(1, 512),
    );
    return List.unmodifiable(
      rows.map(
        (row) => ConversationSyncV2ReadWatermark(
          provider: row['provider']! as String,
          providerSessionId: row['provider_session_id']! as String,
          readAt: row['read_at']! as String,
        ),
      ),
    );
  }

  Future<void> storeReadWatermark({
    required SessionCatalogCacheTarget target,
    required ConversationSyncV2ReadWatermark watermark,
  }) {
    if (!target.isValid) return Future<void>.value();
    return _enqueueMutation(() async {
      final db = await database.database;
      await db.transaction((transaction) async {
        final partitionId = await _ensureWritablePartition(transaction, target);
        final readSort =
            DateTime.tryParse(
              watermark.readAt,
            )?.toUtc().millisecondsSinceEpoch ??
            0;
        final rows = await transaction.query(
          SessionCatalogCacheDatabase.readWatermarksTable,
          columns: ['read_sort'],
          where:
              'partition_id = ? AND provider = ? '
              'AND provider_session_id = ?',
          whereArgs: [
            partitionId,
            watermark.provider,
            watermark.providerSessionId,
          ],
          limit: 1,
        );
        if (rows.isNotEmpty && (rows.single['read_sort']! as int) > readSort) {
          return;
        }
        await transaction.insert(
          SessionCatalogCacheDatabase.readWatermarksTable,
          {
            'partition_id': partitionId,
            'provider': watermark.provider,
            'provider_session_id': watermark.providerSessionId,
            'read_at': watermark.readAt,
            'read_sort': readSort,
            'updated_at': DateTime.now().toUtc().millisecondsSinceEpoch,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      });
    });
  }

  Future<void> beginConversationSync({
    required SessionCatalogCacheTarget target,
    required String subscriptionId,
  }) {
    if (!target.isValid) return Future<void>.value();
    return _enqueueMutation(() async {
      final db = await database.database;
      await db.transaction((transaction) async {
        final partitionId = await _ensureWritablePartition(transaction, target);
        final now = DateTime.now().toUtc().millisecondsSinceEpoch;
        await transaction.insert(
          SessionCatalogCacheDatabase.syncStatesTable,
          {'partition_id': partitionId, 'priority_ready': 0, 'updated_at': now},
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        await transaction.update(
          SessionCatalogCacheDatabase.syncStatesTable,
          {'priority_ready': 0, 'updated_at': now},
          where: 'partition_id = ?',
          whereArgs: [partitionId],
        );
        await transaction.delete(
          SessionCatalogCacheDatabase.timelineStagesTable,
          where: 'partition_id = ? AND subscription_id <> ?',
          whereArgs: [partitionId, subscriptionId],
        );
      });
    });
  }

  Future<void> applyConversationCatalogPage({
    required SessionCatalogCacheTarget target,
    required String codexSourceId,
    required String catalogState,
    required int pageIndex,
    required int pageCount,
    required List<ConversationSyncV2CatalogEntry> created,
    required List<ConversationSyncV2CatalogEntry> updated,
    required List<ConversationSyncV2Target> destroyed,
  }) {
    if (!target.isValid) return Future<void>.value();
    return _enqueueMutation(() async {
      final db = await database.database;
      await db.transaction((transaction) async {
        final partitionId = await _ensureWritablePartition(transaction, target);
        final now = DateTime.now().toUtc().millisecondsSinceEpoch;
        for (final entry in [...created, ...updated]) {
          await transaction.delete(
            SessionCatalogCacheDatabase.entriesTable,
            where: 'partition_id = ? AND provider = ? AND session_id = ?',
            whereArgs: [partitionId, entry.provider, entry.providerSessionId],
          );
          final session = entry.toRecentSession(codexSourceId: codexSourceId);
          await transaction.insert(
            SessionCatalogCacheDatabase.entriesTable,
            {
              'partition_id': partitionId,
              'provider': entry.provider,
              'project_path': entry.projectPath,
              'session_id': entry.providerSessionId,
              'session_json': jsonEncode(session.toJson()),
              'modified_sort':
                  DateTime.tryParse(
                    entry.recencyAt,
                  )?.toUtc().millisecondsSinceEpoch ??
                  0,
              'cached_at': now,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        for (final entry in destroyed) {
          await transaction.delete(
            SessionCatalogCacheDatabase.entriesTable,
            where: 'partition_id = ? AND provider = ? AND session_id = ?',
            whereArgs: [partitionId, entry.provider, entry.providerSessionId],
          );
          await transaction.delete(
            SessionCatalogCacheDatabase.statusesTable,
            where:
                'partition_id = ? AND provider = ? '
                'AND provider_session_id = ?',
            whereArgs: [partitionId, entry.provider, entry.providerSessionId],
          );
        }
        await _ensureSyncState(transaction, partitionId, now);
        if (pageIndex == pageCount - 1) {
          await transaction.update(
            SessionCatalogCacheDatabase.syncStatesTable,
            {'catalog_state': catalogState, 'updated_at': now},
            where: 'partition_id = ?',
            whereArgs: [partitionId],
          );
        }
        await transaction.update(
          SessionCatalogCacheDatabase.partitionsTable,
          {'updated_at': now},
          where: 'partition_id = ?',
          whereArgs: [partitionId],
        );
        await _prunePartition(transaction, partitionId);
      });
    });
  }

  Future<void> applyConversationStatusPage({
    required SessionCatalogCacheTarget target,
    required String statusState,
    required int pageIndex,
    required int pageCount,
    required List<ConversationSyncV2Status> changes,
  }) {
    if (!target.isValid) return Future<void>.value();
    return _enqueueMutation(() async {
      final db = await database.database;
      await db.transaction((transaction) async {
        final partitionId = await _ensureWritablePartition(transaction, target);
        final now = DateTime.now().toUtc().millisecondsSinceEpoch;
        for (final status in changes) {
          final observed =
              DateTime.tryParse(
                status.observedAt,
              )?.toUtc().millisecondsSinceEpoch ??
              0;
          final prior = await transaction.query(
            SessionCatalogCacheDatabase.statusesTable,
            columns: ['observed_sort'],
            where:
                'partition_id = ? AND provider = ? '
                'AND provider_session_id = ?',
            whereArgs: [partitionId, status.provider, status.providerSessionId],
            limit: 1,
          );
          if (prior.isNotEmpty &&
              (prior.single['observed_sort']! as int) > observed) {
            continue;
          }
          await transaction.insert(
            SessionCatalogCacheDatabase.statusesTable,
            {
              'partition_id': partitionId,
              'provider': status.provider,
              'provider_session_id': status.providerSessionId,
              'status_json': jsonEncode(status.toJson()),
              'observed_sort': observed,
              'updated_at': now,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await _ensureSyncState(transaction, partitionId, now);
        if (pageIndex == pageCount - 1) {
          await transaction.update(
            SessionCatalogCacheDatabase.syncStatesTable,
            {'status_state': statusState, 'updated_at': now},
            where: 'partition_id = ?',
            whereArgs: [partitionId],
          );
        }
      });
    });
  }

  Future<void> markConversationPriorityReady(SessionCatalogCacheTarget target) {
    if (!target.isValid) return Future<void>.value();
    return _enqueueMutation(() async {
      final db = await database.database;
      await db.transaction((transaction) async {
        final partitionId = await _ensureWritablePartition(transaction, target);
        final now = DateTime.now().toUtc().millisecondsSinceEpoch;
        await _ensureSyncState(transaction, partitionId, now);
        await transaction.update(
          SessionCatalogCacheDatabase.syncStatesTable,
          {'priority_ready': 1, 'updated_at': now},
          where: 'partition_id = ?',
          whereArgs: [partitionId],
        );
      });
    });
  }

  Future<void> completeConversationSync({
    required SessionCatalogCacheTarget target,
    required ConversationSyncV2NextState nextState,
  }) {
    if (!target.isValid) return Future<void>.value();
    return _enqueueMutation(() async {
      final db = await database.database;
      await db.transaction((transaction) async {
        final partitionId = await _ensureWritablePartition(transaction, target);
        final now = DateTime.now().toUtc().millisecondsSinceEpoch;
        await _ensureSyncState(transaction, partitionId, now);
        await transaction.update(
          SessionCatalogCacheDatabase.syncStatesTable,
          {
            'catalog_state': nextState.catalogState,
            'status_state': nextState.statusState,
            'updated_at': now,
          },
          where: 'partition_id = ?',
          whereArgs: [partitionId],
        );
      });
    });
  }

  Future<void> resetConversationSyncScope({
    required SessionCatalogCacheTarget target,
    required String scope,
    ConversationSyncV2Target? thread,
  }) {
    if (!target.isValid) return Future<void>.value();
    return _enqueueMutation(() async {
      final db = await database.database;
      await db.transaction((transaction) async {
        final partitionId = await _resolveReadablePartition(
          transaction,
          target,
        );
        if (partitionId == null) return;
        final now = DateTime.now().toUtc().millisecondsSinceEpoch;
        switch (scope) {
          case 'catalog':
            await transaction.delete(
              SessionCatalogCacheDatabase.entriesTable,
              where: 'partition_id = ?',
              whereArgs: [partitionId],
            );
            await _ensureSyncState(transaction, partitionId, now);
            await transaction.update(
              SessionCatalogCacheDatabase.syncStatesTable,
              {'catalog_state': null, 'priority_ready': 0, 'updated_at': now},
              where: 'partition_id = ?',
              whereArgs: [partitionId],
            );
          case 'status':
            await transaction.delete(
              SessionCatalogCacheDatabase.statusesTable,
              where: 'partition_id = ?',
              whereArgs: [partitionId],
            );
            await _ensureSyncState(transaction, partitionId, now);
            await transaction.update(
              SessionCatalogCacheDatabase.syncStatesTable,
              {'status_state': null, 'priority_ready': 0, 'updated_at': now},
              where: 'partition_id = ?',
              whereArgs: [partitionId],
            );
          case 'thread':
            if (thread == null) return;
            await transaction.delete(
              SessionCatalogCacheDatabase.hotWindowsTable,
              where:
                  'partition_id = ? AND provider = ? '
                  'AND provider_session_id = ?',
              whereArgs: [
                partitionId,
                thread.provider,
                thread.providerSessionId,
              ],
            );
            await transaction.delete(
              SessionCatalogCacheDatabase.timelineStagesTable,
              where:
                  'partition_id = ? AND provider = ? '
                  'AND provider_session_id = ?',
              whereArgs: [
                partitionId,
                thread.provider,
                thread.providerSessionId,
              ],
            );
          default:
            throw ArgumentError.value(scope, 'scope');
        }
      });
    });
  }

  Future<ConversationTimelinePageCommit> stageConversationTimelinePage({
    required SessionCatalogCacheTarget target,
    required String subscriptionId,
    required String provider,
    required String providerSessionId,
    required String revision,
    required String? baseRevision,
    required String mode,
    required int pageIndex,
    required int pageCount,
    required List<ConversationContentWireEntry> entries,
    required List<String> deletes,
    required bool hasEarlier,
    String? turnsNextCursor,
    required int sourceEntryCount,
  }) {
    if (!target.isValid) {
      return Future.value(
        const ConversationTimelinePageCommit(
          pageStored: false,
          windowCommitted: false,
          baseRevisionMatched: false,
        ),
      );
    }
    return _enqueueMutationResult(() async {
      final db = await database.database;
      return db.transaction((transaction) async {
        final partitionId = await _ensureWritablePartition(transaction, target);
        final keyWhere =
            'partition_id = ? AND subscription_id = ? AND provider = ? '
            'AND provider_session_id = ? AND revision = ?';
        final keyArgs = [
          partitionId,
          subscriptionId,
          provider,
          providerSessionId,
          revision,
        ];
        final now = DateTime.now().toUtc().millisecondsSinceEpoch;
        await transaction.insert(
          SessionCatalogCacheDatabase.timelineStagesTable,
          {
            'partition_id': partitionId,
            'subscription_id': subscriptionId,
            'provider': provider,
            'provider_session_id': providerSessionId,
            'revision': revision,
            'base_revision': baseRevision,
            'mode': mode,
            'page_count': pageCount,
            'has_earlier': hasEarlier ? 1 : 0,
            'turns_next_cursor': turnsNextCursor,
            'source_entry_count': sourceEntryCount,
            'created_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        final stages = await transaction.query(
          SessionCatalogCacheDatabase.timelineStagesTable,
          where: keyWhere,
          whereArgs: keyArgs,
          limit: 1,
        );
        if (stages.isEmpty) {
          throw StateError('Conversation timeline stage was not created.');
        }
        final stage = stages.single;
        if (stage['base_revision'] != baseRevision ||
            stage['mode'] != mode ||
            stage['page_count'] != pageCount ||
            stage['has_earlier'] != (hasEarlier ? 1 : 0) ||
            stage['turns_next_cursor'] != turnsNextCursor ||
            stage['source_entry_count'] != sourceEntryCount) {
          throw StateError('Conversation timeline stage metadata changed.');
        }
        final duplicate = await transaction.query(
          SessionCatalogCacheDatabase.timelineStagePagesTable,
          columns: ['page_index'],
          where: '$keyWhere AND page_index = ?',
          whereArgs: [...keyArgs, pageIndex],
          limit: 1,
        );
        if (duplicate.isEmpty) {
          await transaction
              .insert(SessionCatalogCacheDatabase.timelineStagePagesTable, {
                'partition_id': partitionId,
                'subscription_id': subscriptionId,
                'provider': provider,
                'provider_session_id': providerSessionId,
                'revision': revision,
                'page_index': pageIndex,
              });
          for (final entry in entries) {
            await transaction
                .insert(SessionCatalogCacheDatabase.timelineStageEntriesTable, {
                  'partition_id': partitionId,
                  'subscription_id': subscriptionId,
                  'provider': provider,
                  'provider_session_id': providerSessionId,
                  'revision': revision,
                  'page_index': pageIndex,
                  'entry_id': entry.entryId,
                  'entry_index': entry.index,
                  'content_hash': entry.contentHash,
                  'message_json': jsonEncode(entry.rawMessage),
                });
          }
          for (final entryId in deletes) {
            await transaction
                .insert(SessionCatalogCacheDatabase.timelineStageDeletesTable, {
                  'partition_id': partitionId,
                  'subscription_id': subscriptionId,
                  'provider': provider,
                  'provider_session_id': providerSessionId,
                  'revision': revision,
                  'page_index': pageIndex,
                  'entry_id': entryId,
                });
          }
        }
        final pageRows = await transaction.rawQuery('''
          SELECT COUNT(*) AS page_count
          FROM ${SessionCatalogCacheDatabase.timelineStagePagesTable}
          WHERE $keyWhere
          ''', keyArgs);
        final storedPages = Sqflite.firstIntValue(pageRows) ?? 0;
        if (storedPages < pageCount) {
          return const ConversationTimelinePageCommit(
            pageStored: true,
            windowCommitted: false,
            baseRevisionMatched: true,
          );
        }
        if (storedPages != pageCount) {
          throw StateError('Conversation timeline page count is invalid.');
        }
        final entryRows = await transaction.rawQuery('''
          SELECT COUNT(*) AS entry_count
          FROM ${SessionCatalogCacheDatabase.timelineStageEntriesTable}
          WHERE $keyWhere
          ''', keyArgs);
        final entryCount = Sqflite.firstIntValue(entryRows) ?? 0;
        if (entryCount > maxHotWindowEntries) {
          throw StateError('Conversation timeline exceeds the local bound.');
        }
        if (mode == 'patch') {
          final windows = await transaction.query(
            SessionCatalogCacheDatabase.hotWindowsTable,
            columns: ['revision'],
            where:
                'partition_id = ? AND provider = ? '
                'AND provider_session_id = ?',
            whereArgs: [partitionId, provider, providerSessionId],
            limit: 1,
          );
          if (windows.isEmpty || windows.single['revision'] != baseRevision) {
            await transaction.delete(
              SessionCatalogCacheDatabase.timelineStagesTable,
              where: keyWhere,
              whereArgs: keyArgs,
            );
            return const ConversationTimelinePageCommit(
              pageStored: true,
              windowCommitted: false,
              baseRevisionMatched: false,
            );
          }
          await transaction.rawDelete(
            '''
            DELETE FROM ${SessionCatalogCacheDatabase.hotEntriesTable}
            WHERE partition_id = ?
              AND provider = ?
              AND provider_session_id = ?
              AND entry_id IN (
                SELECT entry_id
                FROM ${SessionCatalogCacheDatabase.timelineStageDeletesTable}
                WHERE $keyWhere
              )
            ''',
            [partitionId, provider, providerSessionId, ...keyArgs],
          );
        } else if (mode == 'snapshot') {
          await transaction.delete(
            SessionCatalogCacheDatabase.hotEntriesTable,
            where:
                'partition_id = ? AND provider = ? '
                'AND provider_session_id = ?',
            whereArgs: [partitionId, provider, providerSessionId],
          );
          await transaction.insert(
            SessionCatalogCacheDatabase.hotWindowsTable,
            {
              'partition_id': partitionId,
              'provider': provider,
              'provider_session_id': providerSessionId,
              'revision': revision,
              'entry_count': 0,
              'has_earlier': hasEarlier ? 1 : 0,
              'turns_next_cursor': turnsNextCursor,
              'source_entry_count': sourceEntryCount,
              'updated_at': now,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        } else {
          throw StateError('Unsupported conversation timeline mode: $mode');
        }
        await transaction.rawInsert(
          '''
          INSERT OR REPLACE INTO
            ${SessionCatalogCacheDatabase.hotEntriesTable} (
              partition_id,
              provider,
              provider_session_id,
              entry_id,
              entry_index,
              content_hash,
              message_json
            )
          SELECT ?, ?, ?, entry_id, entry_index, content_hash, message_json
          FROM ${SessionCatalogCacheDatabase.timelineStageEntriesTable}
          WHERE $keyWhere
          ''',
          [partitionId, provider, providerSessionId, ...keyArgs],
        );
        final committedRows = await transaction.rawQuery(
          '''
          SELECT
            COUNT(*) AS entry_count,
            COUNT(DISTINCT entry_index) AS index_count
          FROM ${SessionCatalogCacheDatabase.hotEntriesTable}
          WHERE partition_id = ?
            AND provider = ?
            AND provider_session_id = ?
          ''',
          [partitionId, provider, providerSessionId],
        );
        final committedCount = committedRows.single['entry_count']! as int;
        final committedIndexCount = committedRows.single['index_count']! as int;
        if (committedCount > maxHotWindowEntries ||
            committedCount != committedIndexCount) {
          throw StateError('Committed conversation timeline is invalid.');
        }
        await transaction.update(
          SessionCatalogCacheDatabase.hotWindowsTable,
          {
            'entry_count': committedCount,
            'revision': revision,
            'has_earlier': hasEarlier ? 1 : 0,
            'turns_next_cursor': turnsNextCursor,
            'source_entry_count': sourceEntryCount,
            'updated_at': now,
          },
          where:
              'partition_id = ? AND provider = ? '
              'AND provider_session_id = ?',
          whereArgs: [partitionId, provider, providerSessionId],
        );
        await transaction.delete(
          SessionCatalogCacheDatabase.timelineStagesTable,
          where: keyWhere,
          whereArgs: keyArgs,
        );
        return const ConversationTimelinePageCommit(
          pageStored: true,
          windowCommitted: true,
          baseRevisionMatched: true,
        );
      });
    });
  }

  Future<void> clearConversationTimelineStages({
    required SessionCatalogCacheTarget target,
    String? subscriptionId,
  }) {
    if (!target.isValid) return Future<void>.value();
    return _enqueueMutation(() async {
      final db = await database.database;
      final partitionId = await _resolveReadablePartition(db, target);
      if (partitionId == null) return;
      await db.delete(
        SessionCatalogCacheDatabase.timelineStagesTable,
        where: subscriptionId == null
            ? 'partition_id = ?'
            : 'partition_id = ? AND subscription_id = ?',
        whereArgs: subscriptionId == null
            ? [partitionId]
            : [partitionId, subscriptionId],
      );
    });
  }

  Future<ConversationHotWindowSnapshot?> loadConversationWindow({
    required SessionCatalogCacheTarget target,
    required String provider,
    required String providerSessionId,
  }) async {
    if (!target.isValid) return null;
    await _mutationTail;
    final db = await database.database;
    final partitionId = await _resolveReadablePartition(db, target);
    if (partitionId == null) return null;
    final windows = await db.query(
      SessionCatalogCacheDatabase.hotWindowsTable,
      where: 'partition_id = ? AND provider = ? AND provider_session_id = ?',
      whereArgs: [partitionId, provider, providerSessionId],
      limit: 1,
    );
    if (windows.isEmpty) return null;
    final window = windows.single;
    final rows = await db.query(
      SessionCatalogCacheDatabase.hotEntriesTable,
      columns: ['entry_id', 'entry_index', 'content_hash', 'message_json'],
      where: 'partition_id = ? AND provider = ? AND provider_session_id = ?',
      whereArgs: [partitionId, provider, providerSessionId],
      orderBy: 'entry_index ASC',
      limit: maxHotWindowEntries,
    );
    final entries = <ConversationContentWireEntry>[];
    for (final row in rows) {
      try {
        final decoded = jsonDecode(row['message_json']! as String);
        if (decoded is! Map) return null;
        final entry = ConversationContentWireEntry(
          entryId: row['entry_id']! as String,
          index: row['entry_index']! as int,
          contentHash: row['content_hash']! as String,
          rawMessage: Map<String, dynamic>.unmodifiable(
            Map<String, dynamic>.from(decoded),
          ),
        );
        entry.decodeMessage();
        entries.add(entry);
      } catch (_) {
        // A single malformed row invalidates only this rebuildable window.
        return null;
      }
    }
    if (entries.length != window['entry_count']) return null;
    return ConversationHotWindowSnapshot(
      partitionId: partitionId,
      provider: provider,
      providerSessionId: providerSessionId,
      revision: window['revision']! as String,
      entries: List<ConversationContentWireEntry>.unmodifiable(entries),
      hasEarlier: (window['has_earlier']! as int) != 0,
      turnsNextCursor: window['turns_next_cursor'] as String?,
      sourceEntryCount: window['source_entry_count']! as int,
      cachedAt: DateTime.fromMillisecondsSinceEpoch(
        window['updated_at']! as int,
        isUtc: true,
      ),
    );
  }

  Future<void> replaceConversationWindow({
    required SessionCatalogCacheTarget target,
    required String provider,
    required String providerSessionId,
    required String revision,
    required List<ConversationContentWireEntry> entries,
    required bool hasEarlier,
    String? turnsNextCursor,
    required int sourceEntryCount,
  }) {
    if (!target.isValid) return Future<void>.value();
    if (entries.length > maxHotWindowEntries) {
      return Future<void>.error(
        StateError('Conversation hot window exceeds the local safety bound.'),
      );
    }
    return _enqueueMutation(() async {
      final db = await database.database;
      await db.transaction((transaction) async {
        final partitionId = await _ensureWritablePartition(transaction, target);
        final now = DateTime.now().toUtc().millisecondsSinceEpoch;
        await transaction.insert(
          SessionCatalogCacheDatabase.hotWindowsTable,
          {
            'partition_id': partitionId,
            'provider': provider,
            'provider_session_id': providerSessionId,
            'revision': revision,
            'entry_count': entries.length,
            'has_earlier': hasEarlier ? 1 : 0,
            'turns_next_cursor': turnsNextCursor,
            'source_entry_count': sourceEntryCount,
            'updated_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        await transaction.delete(
          SessionCatalogCacheDatabase.hotEntriesTable,
          where:
              'partition_id = ? AND provider = ? '
              'AND provider_session_id = ?',
          whereArgs: [partitionId, provider, providerSessionId],
        );
        for (final entry in entries) {
          await _insertHotEntry(
            transaction,
            partitionId: partitionId,
            provider: provider,
            providerSessionId: providerSessionId,
            entry: entry,
          );
        }
      });
    });
  }

  /// Prepends one bounded provider turn page without materializing the
  /// existing timeline in Dart memory.
  Future<ConversationHotWindowSnapshot?> prependConversationTurnsPage({
    required SessionCatalogCacheTarget target,
    required String provider,
    required String providerSessionId,
    required List<Map<String, dynamic>> rawMessages,
    required String? nextCursor,
  }) async {
    if (!target.isValid) return null;
    final candidates = <ConversationContentWireEntry>[];
    final seen = <String>{};
    for (var index = 0; index < rawMessages.length; index++) {
      final candidate = _historyPageEntry(rawMessages[index], index);
      if (candidate == null) continue;
      var entryId = candidate.entryId;
      if (!seen.add(entryId)) {
        entryId = '$entryId:${candidate.contentHash.substring(0, 16)}';
        if (!seen.add(entryId)) continue;
      }
      candidates.add(
        ConversationContentWireEntry(
          entryId: entryId,
          index: 0,
          contentHash: candidate.contentHash,
          rawMessage: candidate.rawMessage,
        ),
      );
    }
    await _enqueueMutation(() async {
      final db = await database.database;
      await db.transaction((transaction) async {
        final partitionId = await _resolveReadablePartition(
          transaction,
          target,
        );
        if (partitionId == null) return;
        final windows = await transaction.query(
          SessionCatalogCacheDatabase.hotWindowsTable,
          columns: ['source_entry_count'],
          where:
              'partition_id = ? AND provider = ? '
              'AND provider_session_id = ?',
          whereArgs: [partitionId, provider, providerSessionId],
          limit: 1,
        );
        if (windows.isEmpty) return;

        final existingIds = <String>{};
        if (candidates.isNotEmpty) {
          final placeholders = List.filled(candidates.length, '?').join(',');
          final rows = await transaction.query(
            SessionCatalogCacheDatabase.hotEntriesTable,
            columns: ['entry_id'],
            where:
                'partition_id = ? AND provider = ? '
                'AND provider_session_id = ? '
                'AND entry_id IN ($placeholders)',
            whereArgs: [
              partitionId,
              provider,
              providerSessionId,
              ...candidates.map((entry) => entry.entryId),
            ],
          );
          existingIds.addAll(rows.map((row) => row['entry_id']! as String));
        }
        final additions = candidates
            .where((entry) => !existingIds.contains(entry.entryId))
            .toList(growable: false);
        final minimumRows = await transaction.rawQuery(
          '''
          SELECT MIN(entry_index) AS minimum_index
          FROM ${SessionCatalogCacheDatabase.hotEntriesTable}
          WHERE partition_id = ?
            AND provider = ?
            AND provider_session_id = ?
          ''',
          [partitionId, provider, providerSessionId],
        );
        final minimum = minimumRows.single['minimum_index'] as int? ?? 0;
        final firstIndex = minimum - additions.length;
        for (var index = 0; index < additions.length; index++) {
          final entry = additions[index];
          await _insertHotEntry(
            transaction,
            partitionId: partitionId,
            provider: provider,
            providerSessionId: providerSessionId,
            entry: ConversationContentWireEntry(
              entryId: entry.entryId,
              index: firstIndex + index,
              contentHash: entry.contentHash,
              rawMessage: entry.rawMessage,
            ),
          );
        }
        final countRows = await transaction.rawQuery(
          '''
          SELECT COUNT(*) AS entry_count
          FROM ${SessionCatalogCacheDatabase.hotEntriesTable}
          WHERE partition_id = ?
            AND provider = ?
            AND provider_session_id = ?
          ''',
          [partitionId, provider, providerSessionId],
        );
        final count = Sqflite.firstIntValue(countRows) ?? 0;
        final previousSourceCount =
            windows.single['source_entry_count']! as int;
        await transaction.update(
          SessionCatalogCacheDatabase.hotWindowsTable,
          {
            'entry_count': count,
            'has_earlier': nextCursor == null ? 0 : 1,
            'turns_next_cursor': nextCursor,
            'source_entry_count': previousSourceCount + additions.length,
            'updated_at': DateTime.now().toUtc().millisecondsSinceEpoch,
          },
          where:
              'partition_id = ? AND provider = ? '
              'AND provider_session_id = ?',
          whereArgs: [partitionId, provider, providerSessionId],
        );
      });
    });
    return loadConversationWindow(
      target: target,
      provider: provider,
      providerSessionId: providerSessionId,
    );
  }

  Future<bool> applyConversationPatch({
    required SessionCatalogCacheTarget target,
    required String provider,
    required String providerSessionId,
    required String baseRevision,
    required String revision,
    required List<ConversationContentWireEntry> upserts,
    required List<String> deletes,
    required bool hasEarlier,
    String? turnsNextCursor,
    required int sourceEntryCount,
  }) {
    if (!target.isValid) return Future<bool>.value(false);
    return _enqueueMutationResult(() async {
      final db = await database.database;
      return db.transaction((transaction) async {
        final partitionId = await _resolveReadablePartition(
          transaction,
          target,
        );
        if (partitionId == null) return false;
        final rows = await transaction.query(
          SessionCatalogCacheDatabase.hotWindowsTable,
          columns: ['revision'],
          where:
              'partition_id = ? AND provider = ? '
              'AND provider_session_id = ?',
          whereArgs: [partitionId, provider, providerSessionId],
          limit: 1,
        );
        if (rows.isEmpty || rows.single['revision'] != baseRevision) {
          return false;
        }
        if (deletes.isNotEmpty) {
          final placeholders = List.filled(deletes.length, '?').join(',');
          await transaction.delete(
            SessionCatalogCacheDatabase.hotEntriesTable,
            where:
                'partition_id = ? AND provider = ? '
                'AND provider_session_id = ? '
                'AND entry_id IN ($placeholders)',
            whereArgs: [partitionId, provider, providerSessionId, ...deletes],
          );
        }
        for (final entry in upserts) {
          await _insertHotEntry(
            transaction,
            partitionId: partitionId,
            provider: provider,
            providerSessionId: providerSessionId,
            entry: entry,
          );
        }
        final countRows = await transaction.rawQuery(
          '''
          SELECT
            COUNT(*) AS entry_count,
            COUNT(DISTINCT entry_index) AS index_count
          FROM ${SessionCatalogCacheDatabase.hotEntriesTable}
          WHERE partition_id = ?
            AND provider = ?
            AND provider_session_id = ?
          ''',
          [partitionId, provider, providerSessionId],
        );
        final count = Sqflite.firstIntValue(countRows) ?? 0;
        final indexCount = countRows.single['index_count']! as int;
        if (count > maxHotWindowEntries || indexCount != count) {
          throw StateError(
            'Conversation hot window violates the local safety bound.',
          );
        }
        await transaction.update(
          SessionCatalogCacheDatabase.hotWindowsTable,
          {
            'revision': revision,
            'entry_count': count,
            'has_earlier': hasEarlier ? 1 : 0,
            'turns_next_cursor': turnsNextCursor,
            'source_entry_count': sourceEntryCount,
            'updated_at': DateTime.now().toUtc().millisecondsSinceEpoch,
          },
          where:
              'partition_id = ? AND provider = ? '
              'AND provider_session_id = ?',
          whereArgs: [partitionId, provider, providerSessionId],
        );
        return true;
      });
    });
  }

  Future<void> deleteConversationWindow({
    required SessionCatalogCacheTarget target,
    required String provider,
    required String providerSessionId,
  }) {
    if (!target.isValid) return Future<void>.value();
    return _enqueueMutation(() async {
      final db = await database.database;
      final partitionId = await _resolveReadablePartition(db, target);
      if (partitionId == null) return;
      await db.delete(
        SessionCatalogCacheDatabase.hotWindowsTable,
        where: 'partition_id = ? AND provider = ? AND provider_session_id = ?',
        whereArgs: [partitionId, provider, providerSessionId],
      );
    });
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _mutationTail;
    await database.close();
  }

  Future<void> _enqueueMutation(Future<void> Function() operation) {
    return _enqueueMutationResult<void>(operation);
  }

  Future<T> _enqueueMutationResult<T>(Future<T> Function() operation) {
    if (_closed) {
      return Future<T>.error(
        StateError('Session catalog cache repository is already closed.'),
      );
    }
    final next = _mutationTail.then((_) => operation());
    _mutationTail = next.then<void>((_) {}).catchError((_) {});
    return next;
  }

  static Future<void> _insertHotEntry(
    DatabaseExecutor database, {
    required String partitionId,
    required String provider,
    required String providerSessionId,
    required ConversationContentWireEntry entry,
  }) async {
    await database.insert(
      SessionCatalogCacheDatabase.hotEntriesTable,
      {
        'partition_id': partitionId,
        'provider': provider,
        'provider_session_id': providerSessionId,
        'entry_id': entry.entryId,
        'entry_index': entry.index,
        'content_hash': entry.contentHash,
        'message_json': jsonEncode(entry.rawMessage),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static ConversationContentWireEntry? _historyPageEntry(
    Map<String, dynamic> rawMessage,
    int index,
  ) {
    try {
      ServerMessage.fromJson(rawMessage);
      final encoded = jsonEncode(rawMessage);
      final contentHash = sha256.convert(utf8.encode(encoded)).toString();
      final type = rawMessage['type'] as String? ?? 'unknown';
      String? identity;
      if (type == 'user_input') {
        identity = rawMessage['userMessageUuid'] as String?;
        identity = identity?.trim().isNotEmpty == true
            ? 'user:$identity'
            : 'user:$contentHash';
      } else if (type == 'assistant') {
        final nested = rawMessage['message'];
        final messageId = nested is Map ? nested['id'] as String? : null;
        final stableId =
            (rawMessage['messageUuid'] as String?)?.trim().isNotEmpty == true
            ? rawMessage['messageUuid'] as String
            : messageId;
        identity = stableId?.trim().isNotEmpty == true
            ? 'assistant:$stableId'
            : 'assistant:$contentHash';
      } else if (type == 'tool_result') {
        final toolUseId = rawMessage['toolUseId'] as String?;
        identity = toolUseId?.trim().isNotEmpty == true
            ? 'tool-result:$toolUseId'
            : 'tool-result:$contentHash';
      }
      return ConversationContentWireEntry(
        entryId: identity ?? 'message:$type:$contentHash',
        index: index,
        contentHash: contentHash,
        rawMessage: Map.unmodifiable(rawMessage),
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> _ensureSyncState(
    DatabaseExecutor database,
    String partitionId,
    int now,
  ) async {
    await database.insert(
      SessionCatalogCacheDatabase.syncStatesTable,
      {'partition_id': partitionId, 'priority_ready': 0, 'updated_at': now},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
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

    final sourceHotWindows = await transaction.query(
      SessionCatalogCacheDatabase.hotWindowsTable,
      where: 'partition_id = ?',
      whereArgs: [sourcePartitionId],
    );
    for (final sourceWindow in sourceHotWindows) {
      final provider = sourceWindow['provider']! as String;
      final providerSessionId = sourceWindow['provider_session_id']! as String;
      final targetWindows = await transaction.query(
        SessionCatalogCacheDatabase.hotWindowsTable,
        columns: ['updated_at'],
        where: 'partition_id = ? AND provider = ? AND provider_session_id = ?',
        whereArgs: [targetPartitionId, provider, providerSessionId],
        limit: 1,
      );
      final sourceUpdatedAt = sourceWindow['updated_at']! as int;
      final targetIsNewer =
          targetWindows.isNotEmpty &&
          (targetWindows.single['updated_at']! as int) >= sourceUpdatedAt;
      if (targetIsNewer) continue;
      final sourceHotEntries = await transaction.query(
        SessionCatalogCacheDatabase.hotEntriesTable,
        where: 'partition_id = ? AND provider = ? AND provider_session_id = ?',
        whereArgs: [sourcePartitionId, provider, providerSessionId],
      );
      await transaction.insert(
        SessionCatalogCacheDatabase.hotWindowsTable,
        {...sourceWindow, 'partition_id': targetPartitionId},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      for (final sourceHotEntry in sourceHotEntries) {
        await transaction.insert(
          SessionCatalogCacheDatabase.hotEntriesTable,
          {...sourceHotEntry, 'partition_id': targetPartitionId},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
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
