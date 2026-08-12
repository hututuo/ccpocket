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
    required this.windowComplete,
    required this.latestTurnComplete,
    required this.latestTurnGap,
    required this.latestTurnGapCursor,
    required this.sourceEntryCount,
    required this.cachedAt,
  });

  final String partitionId;
  final String provider;
  final String providerSessionId;
  final String revision;
  final List<ConversationContentWireEntry> entries;
  final bool hasEarlier;

  /// Opaque cursor for the next older turn page.
  final String? turnsNextCursor;
  final bool windowComplete;
  final bool latestTurnComplete;
  final ConversationSyncV2LatestTurnGap? latestTurnGap;

  /// Opaque cursor for continuing repair of the incomplete newest turn.
  final String? latestTurnGapCursor;
  final int sourceEntryCount;
  final DateTime cachedAt;
}

final Expando<String> _conversationPresentationRevisions = Expando<String>();

/// Stable identity for the rendered message window.
///
/// SQLite commit time and provider revision can advance for metadata-only
/// reconciliation. Replaying the same decoded messages for those commits makes
/// a cached conversation look as if it was torn down and loaded again. Cache
/// this bounded content fingerprint on the immutable snapshot instead.
String conversationPresentationRevision(
  ConversationHotWindowSnapshot snapshot,
) {
  final cached = _conversationPresentationRevisions[snapshot];
  if (cached != null) return cached;
  final hash = sha256.convert(
    utf8.encode(
      jsonEncode([
        for (final entry in snapshot.entries)
          [entry.entryId, entry.index, entry.contentHash],
      ]),
    ),
  );
  final revision =
      '${snapshot.entries.length}:'
      '$hash';
  _conversationPresentationRevisions[snapshot] = revision;
  return revision;
}

class ConversationUserIndexEntry {
  const ConversationUserIndexEntry({
    required this.providerTurnId,
    required this.providerItemId,
    required this.message,
  });

  final String providerTurnId;
  final String? providerItemId;
  final UserInputMessage message;
}

class ConversationUserIndexSnapshot {
  const ConversationUserIndexSnapshot({
    required this.revision,
    required this.entries,
    required this.complete,
    required this.cachedAt,
  });

  final String revision;
  final List<ConversationUserIndexEntry> entries;
  final bool complete;
  final DateTime cachedAt;
}

class ConversationUserIndexState {
  const ConversationUserIndexState({
    required this.revision,
    required this.complete,
    required this.cachedAt,
  });

  final String revision;
  final bool complete;
  final DateTime cachedAt;
}

class ConversationUserIndexStage {
  const ConversationUserIndexStage({
    required this.revision,
    required this.cursor,
    required this.pageDepth,
    required this.complete,
  });

  final String revision;
  final String? cursor;
  final int pageDepth;
  final bool complete;
}

class ConversationUserIndexPageEntry {
  const ConversationUserIndexPageEntry({
    required this.providerTurnId,
    required this.providerItemId,
    required this.rawMessage,
  });

  final String providerTurnId;
  final String? providerItemId;
  final Map<String, dynamic> rawMessage;
}

class ConversationUserTurnDetailSnapshot {
  const ConversationUserTurnDetailSnapshot({
    required this.revision,
    required this.messages,
    required this.complete,
    required this.cachedAt,
  });

  final String revision;
  final List<ServerMessage> messages;
  final bool complete;
  final DateTime cachedAt;
}

class ConversationUserTurnDetailStage {
  const ConversationUserTurnDetailStage({
    required this.revision,
    required this.cursor,
    required this.pageDepth,
    required this.complete,
  });

  final String revision;
  final String? cursor;
  final int pageDepth;
  final bool complete;
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
    this.stageRejected = false,
    this.committedRevision,
    this.lastAssistantOutputAt,
  });

  final bool pageStored;
  final bool windowCommitted;
  final bool baseRevisionMatched;
  final bool stageRejected;
  final String? committedRevision;

  /// Newest discrete assistant text timestamp introduced by this committed
  /// snapshot/patch, or null when the commit only changed tools/status.
  final String? lastAssistantOutputAt;
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

class SessionCatalogCachedConversation {
  const SessionCatalogCachedConversation({
    required this.provider,
    required this.providerSessionId,
    required this.entryCount,
    required this.updatedAt,
    this.session,
  });

  final String provider;
  final String providerSessionId;
  final int entryCount;
  final DateTime updatedAt;
  final RecentSession? session;
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
  SessionCatalogCacheRepository(
    this.database, {
    this.userCacheReadBarrierForTesting,
  });

  static const maxEntriesPerPartition = 10_000;
  static const maxHotWindowEntries = 2_000;
  static const _maxTimelineStageRows = maxHotWindowEntries * 2;
  static const _maxTimelineStagePages = 128;
  static const _maxTimelineStageBytes = 8 * 1024 * 1024;
  static const _maxIdentityLookupsPerQuery = 300;
  // Revision advertisement is only a reconnect optimization. Keep the initial
  // subscribe path deliberately small; omitted windows are safely replayed by
  // the Bridge after the socket is ready.
  static const _maxKnownRevisionValidationWindows = 16;
  static const _maxKnownRevisionValidationEntries = 1_000;

  final SessionCatalogCacheDatabase database;
  final Future<void> Function()? userCacheReadBarrierForTesting;
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
    if (rows.isEmpty && serverRevision == null && completeRevision == null) {
      return null;
    }
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
        final cachedSessionsByIdentity = await _cachedSessionsByIdentity(
          transaction,
          partitionId,
          response.sessions,
        );
        if (authoritativeReplacement) {
          await transaction.delete(
            SessionCatalogCacheDatabase.entriesTable,
            where: 'partition_id = ?',
            whereArgs: [partitionId],
          );
        }
        for (final incoming in response.sessions) {
          final provider = incoming.provider ?? Provider.claude.value;
          final cached =
              cachedSessionsByIdentity[_conversationIdentity(
                provider,
                incoming.sessionId,
              )];
          final merged = mergeIncompleteCodexSettings(
            incoming: incoming,
            cached: cached,
          );
          final latestAssistantOutputAt = _latestIsoTimestamp(
            merged.lastAssistantOutputAt,
            cached?.lastAssistantOutputAt,
          );
          final session =
              latestAssistantOutputAt == null ||
                  latestAssistantOutputAt == merged.lastAssistantOutputAt
              ? merged
              : merged.copyWithLastAssistantOutputAt(latestAssistantOutputAt);
          if (!authoritativeReplacement) {
            await transaction.delete(
              SessionCatalogCacheDatabase.entriesTable,
              where: 'partition_id = ? AND provider = ? AND session_id = ?',
              whereArgs: [partitionId, provider, session.sessionId],
            );
          }
          await transaction.insert(
            SessionCatalogCacheDatabase.entriesTable,
            {
              'partition_id': partitionId,
              'provider': provider,
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
      await db.transaction((transaction) async {
        await _clearRebuildableCache(
          transaction,
          where: null,
          whereArgs: const [],
        );
      });
    });
  }

  Future<void> clearTarget(SessionCatalogCacheTarget target) {
    if (!target.isValid) return Future<void>.value();
    return _enqueueMutation(() async {
      final db = await database.database;
      await db.transaction((transaction) async {
        final partitionId = await _resolveReadablePartition(
          transaction,
          target,
        );
        if (partitionId == null) return;
        await _clearRebuildableCache(
          transaction,
          where: 'partition_id = ?',
          whereArgs: [partitionId],
        );
      });
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

  Future<SessionCatalogCacheStats> cacheStatsForTarget(
    SessionCatalogCacheTarget target,
  ) async {
    if (!target.isValid) return const SessionCatalogCacheStats.empty();
    await _mutationTail;
    final db = await database.database;
    final partitionId = await _resolveReadablePartition(db, target);
    if (partitionId == null) return const SessionCatalogCacheStats.empty();
    final rows = await db.rawQuery(
      '''
      SELECT
        (SELECT COUNT(*)
         FROM ${SessionCatalogCacheDatabase.entriesTable}
         WHERE partition_id = ?) AS session_count,
        (SELECT COUNT(*)
         FROM ${SessionCatalogCacheDatabase.hotWindowsTable}
         WHERE partition_id = ?) AS window_count
      ''',
      [partitionId, partitionId],
    );
    final row = rows.single;
    return SessionCatalogCacheStats(
      sessionSummaries: row['session_count'] as int? ?? 0,
      conversationWindows: row['window_count'] as int? ?? 0,
    );
  }

  Future<List<SessionCatalogCachedConversation>> cachedConversations(
    SessionCatalogCacheTarget target,
  ) async {
    if (!target.isValid) return const [];
    await _mutationTail;
    final db = await database.database;
    final partitionId = await _resolveReadablePartition(db, target);
    if (partitionId == null) return const [];
    final rows = await db.rawQuery(
      '''
      SELECT
        windows.provider,
        windows.provider_session_id,
        windows.entry_count,
        windows.updated_at,
        (
          SELECT entries.session_json
          FROM ${SessionCatalogCacheDatabase.entriesTable} AS entries
          WHERE entries.partition_id = windows.partition_id
            AND entries.provider = windows.provider
            AND entries.session_id = windows.provider_session_id
          ORDER BY entries.modified_sort DESC, entries.cached_at DESC
          LIMIT 1
        ) AS session_json
      FROM ${SessionCatalogCacheDatabase.hotWindowsTable} AS windows
      WHERE windows.partition_id = ?
      ORDER BY windows.updated_at DESC
      ''',
      [partitionId],
    );
    return List.unmodifiable(
      rows.map((row) {
        RecentSession? session;
        try {
          final encoded = row['session_json'] as String?;
          final decoded = encoded == null ? null : jsonDecode(encoded);
          if (decoded is Map) {
            session = RecentSession.fromJson(
              Map<String, dynamic>.from(decoded),
            );
          }
        } catch (_) {
          // Catalog display metadata is optional. The exact cache window can
          // still be managed by its provider identity.
        }
        return SessionCatalogCachedConversation(
          provider: row['provider']! as String,
          providerSessionId: row['provider_session_id']! as String,
          entryCount: row['entry_count']! as int,
          updatedAt: DateTime.fromMillisecondsSinceEpoch(
            row['updated_at']! as int,
            isUtc: true,
          ),
          session: session,
        );
      }),
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
    bool includeIncomplete = false,
  }) async {
    if (!target.isValid || limit <= 0) return const [];
    await _mutationTail;
    final db = await database.database;
    final partitionId = await _resolveReadablePartition(db, target);
    if (partitionId == null) return const [];
    final rows = await db.rawQuery(
      '''
      SELECT windows.*
      FROM ${SessionCatalogCacheDatabase.hotWindowsTable} AS windows
      WHERE windows.partition_id = ?
        AND windows.entry_count BETWEEN 0 AND ?
        ${includeIncomplete ? '' : 'AND windows.window_complete = 1'}
        AND NOT (
          windows.entry_count = 0
          AND windows.latest_turn_complete = 0
        )
        AND windows.entry_count = (
          SELECT COUNT(*)
          FROM ${SessionCatalogCacheDatabase.hotEntriesTable} AS entries
          WHERE entries.partition_id = windows.partition_id
            AND entries.provider = windows.provider
            AND entries.provider_session_id = windows.provider_session_id
        )
        AND windows.entry_count = (
          SELECT COUNT(DISTINCT entries.entry_index)
          FROM ${SessionCatalogCacheDatabase.hotEntriesTable} AS entries
          WHERE entries.partition_id = windows.partition_id
            AND entries.provider = windows.provider
            AND entries.provider_session_id = windows.provider_session_id
        )
      ORDER BY windows.updated_at DESC
      LIMIT ?
      ''',
      [
        partitionId,
        maxHotWindowEntries,
        limit.clamp(1, _maxKnownRevisionValidationWindows),
      ],
    );
    final revisions = <ConversationContentCursor>[];
    var decodedEntryCount = 0;
    for (final row in rows) {
      final provider = row['provider'];
      final providerSessionId = row['provider_session_id'];
      final entryCount = row['entry_count'];
      if (provider is! String ||
          providerSessionId is! String ||
          entryCount is! int ||
          decodedEntryCount + entryCount > _maxKnownRevisionValidationEntries) {
        continue;
      }
      // Advertising a revision is optional; omitting older/heavier windows
      // asks the Bridge to replay them. Bound semantic validation so a large
      // local cache cannot block the initial subscription.
      decodedEntryCount += entryCount;
      final snapshot = await _decodeConversationWindow(
        db: db,
        partitionId: partitionId,
        provider: provider,
        providerSessionId: providerSessionId,
        window: row,
      );
      if (snapshot == null ||
          (snapshot.entries.isEmpty && !snapshot.latestTurnComplete)) {
        continue;
      }
      revisions.add(
        ConversationContentCursor(
          provider: provider,
          providerSessionId: providerSessionId,
          revision: snapshot.revision,
          windowComplete: snapshot.windowComplete,
        ),
      );
    }
    return List<ConversationContentCursor>.unmodifiable(revisions);
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

  Future<ConversationSyncV2ReadWatermark?> storeReadWatermark({
    required SessionCatalogCacheTarget target,
    required ConversationSyncV2ReadWatermark watermark,
    bool allowUnanchoredLegacySeed = false,
  }) {
    if (!target.isValid) return Future.value();
    return _enqueueMutationResult(() async {
      final db = await database.database;
      return db.transaction((transaction) async {
        final partitionId = await _ensureWritablePartition(transaction, target);
        var effectiveReadAt = watermark.readAt;
        var readSort =
            DateTime.tryParse(
              effectiveReadAt,
            )?.toUtc().millisecondsSinceEpoch ??
            0;
        var statusBound = false;
        final statusRows = await transaction.query(
          SessionCatalogCacheDatabase.statusesTable,
          columns: ['status_json', 'observed_sort'],
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
        if (statusRows.isNotEmpty) {
          var observedAt = DateTime.fromMillisecondsSinceEpoch(
            statusRows.single['observed_sort']! as int,
            isUtc: true,
          ).toIso8601String();
          try {
            final status = jsonDecode(
              statusRows.single['status_json']! as String,
            );
            if (status is Map && status['observedAt'] is String) {
              observedAt = status['observedAt']! as String;
            }
          } catch (_) {
            // observed_sort remains an adequate conservative fallback.
          }
          final observed = DateTime.tryParse(observedAt)?.toUtc();
          if (observed != null) {
            effectiveReadAt = observed.toIso8601String();
            readSort = observed.millisecondsSinceEpoch;
            statusBound = true;
          }
        }
        if (!statusBound && !allowUnanchoredLegacySeed) return null;
        final rows = await transaction.query(
          SessionCatalogCacheDatabase.readWatermarksTable,
          columns: ['read_at', 'read_sort'],
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
        if (rows.isNotEmpty) {
          final storedReadAt = rows.single['read_at']! as String;
          if (statusBound && storedReadAt == effectiveReadAt) {
            return ConversationSyncV2ReadWatermark(
              provider: watermark.provider,
              providerSessionId: watermark.providerSessionId,
              readAt: storedReadAt,
            );
          }
          final stored = DateTime.tryParse(storedReadAt)?.toUtc();
          final effective = DateTime.tryParse(effectiveReadAt)?.toUtc();
          if (!statusBound &&
              ((stored != null &&
                      (effective == null || !effective.isAfter(stored))) ||
                  (stored == null &&
                      (rows.single['read_sort']! as int) >= readSort))) {
            return ConversationSyncV2ReadWatermark(
              provider: watermark.provider,
              providerSessionId: watermark.providerSessionId,
              readAt: storedReadAt,
            );
          }
        }
        await transaction.insert(
          SessionCatalogCacheDatabase.readWatermarksTable,
          {
            'partition_id': partitionId,
            'provider': watermark.provider,
            'provider_session_id': watermark.providerSessionId,
            'read_at': effectiveReadAt,
            'read_sort': readSort,
            'updated_at': DateTime.now().toUtc().millisecondsSinceEpoch,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        return ConversationSyncV2ReadWatermark(
          provider: watermark.provider,
          providerSessionId: watermark.providerSessionId,
          readAt: effectiveReadAt,
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
        // `priority_ready` describes the last atomically committed cache, not
        // the in-flight subscription. SessionListCubit separately clears its
        // live readiness when it receives `started`. Keeping the durable bit
        // here means a failed refresh cannot erase the only readable fallback
        // or make the next launch pretend that an already committed catalog is
        // incomplete.
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
    if (pageIndex != 0 || pageCount != 1) {
      return Future<void>.error(
        StateError(
          'Paged catalog changes must be committed as one logical batch.',
        ),
      );
    }
    return applyConversationCatalogBatch(
      target: target,
      codexSourceId: codexSourceId,
      catalogState: catalogState,
      created: created,
      updated: updated,
      destroyed: destroyed,
    );
  }

  /// Atomically applies every page from one logical catalog change batch.
  ///
  /// Callers must aggregate wire pages before entering this method. Keeping
  /// the transaction boundary at the logical batch prevents readers from
  /// observing a mixture of the old catalog and only some of the new pages.
  Future<void> applyConversationCatalogBatch({
    required SessionCatalogCacheTarget target,
    required String codexSourceId,
    required String catalogState,
    required List<ConversationSyncV2CatalogEntry> created,
    required List<ConversationSyncV2CatalogEntry> updated,
    required List<ConversationSyncV2Target> destroyed,
    bool Function()? isCurrent,
  }) {
    if (!target.isValid) return Future<void>.value();
    return _enqueueMutation(() async {
      void ensureCurrent() {
        if (isCurrent != null && !isCurrent()) {
          throw const _ConversationCacheBatchSuperseded();
        }
      }

      if (isCurrent != null && !isCurrent()) return;
      final db = await database.database;
      await _ignoreSupersededConversationBatch(
        db.transaction((transaction) async {
          ensureCurrent();
          final partitionId = await _ensureWritablePartition(
            transaction,
            target,
          );
          ensureCurrent();
          final now = DateTime.now().toUtc().millisecondsSinceEpoch;
          final incomingEntries = [...created, ...updated];
          final decodedSessions = incomingEntries
              .map(
                (entry) => entry.toRecentSession(codexSourceId: codexSourceId),
              )
              .toList(growable: false);
          final cachedSessionsByIdentity = await _cachedSessionsByIdentity(
            transaction,
            partitionId,
            decodedSessions,
          );
          for (var index = 0; index < incomingEntries.length; index++) {
            final entry = incomingEntries[index];
            final identity = _conversationIdentity(
              entry.provider,
              entry.providerSessionId,
            );
            final cachedSession = cachedSessionsByIdentity[identity];
            final decodedSession = mergeIncompleteCodexSettings(
              incoming: decodedSessions[index],
              cached: cachedSession,
            );
            final preservedAssistantOutputAt =
                cachedSession?.lastAssistantOutputAt;
            await transaction.delete(
              SessionCatalogCacheDatabase.entriesTable,
              where: 'partition_id = ? AND provider = ? AND session_id = ?',
              whereArgs: [partitionId, entry.provider, entry.providerSessionId],
            );
            final session = preservedAssistantOutputAt == null
                ? decodedSession
                : decodedSession.copyWithLastAssistantOutputAt(
                    preservedAssistantOutputAt,
                  );
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
          ensureCurrent();
          await _ensureSyncState(transaction, partitionId, now);
          await transaction.update(
            SessionCatalogCacheDatabase.syncStatesTable,
            {'catalog_state': catalogState, 'updated_at': now},
            where: 'partition_id = ?',
            whereArgs: [partitionId],
          );
          await transaction.update(
            SessionCatalogCacheDatabase.partitionsTable,
            {'updated_at': now},
            where: 'partition_id = ?',
            whereArgs: [partitionId],
          );
          await _prunePartition(transaction, partitionId);
          ensureCurrent();
        }),
      );
    });
  }

  Future<void> applyConversationStatusPage({
    required SessionCatalogCacheTarget target,
    required String statusState,
    required int pageIndex,
    required int pageCount,
    required List<ConversationSyncV2Status> changes,
  }) {
    if (pageIndex != 0 || pageCount != 1) {
      return Future<void>.error(
        StateError(
          'Paged status changes must be committed as one logical batch.',
        ),
      );
    }
    return applyConversationStatusBatch(
      target: target,
      statusState: statusState,
      changes: changes,
    );
  }

  /// Atomically applies every page from one logical status change batch.
  Future<void> applyConversationStatusBatch({
    required SessionCatalogCacheTarget target,
    required String statusState,
    required List<ConversationSyncV2Status> changes,
    bool Function()? isCurrent,
  }) {
    if (!target.isValid) return Future<void>.value();
    return _enqueueMutation(() async {
      void ensureCurrent() {
        if (isCurrent != null && !isCurrent()) {
          throw const _ConversationCacheBatchSuperseded();
        }
      }

      if (isCurrent != null && !isCurrent()) return;
      final db = await database.database;
      await _ignoreSupersededConversationBatch(
        db.transaction((transaction) async {
          ensureCurrent();
          final partitionId = await _ensureWritablePartition(
            transaction,
            target,
          );
          ensureCurrent();
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
              whereArgs: [
                partitionId,
                status.provider,
                status.providerSessionId,
              ],
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
          ensureCurrent();
          await _ensureSyncState(transaction, partitionId, now);
          await transaction.update(
            SessionCatalogCacheDatabase.syncStatesTable,
            {'status_state': statusState, 'updated_at': now},
            where: 'partition_id = ?',
            whereArgs: [partitionId],
          );
          ensureCurrent();
        }),
      );
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
            // A reset invalidates the incremental base, not the last committed
            // readable projection. Keep the hot window until the replacement
            // snapshot commits atomically; otherwise a routine scoped recovery
            // visibly blanks or rewinds an open conversation.
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
            await transaction.delete(
              SessionCatalogCacheDatabase.latestTurnRepairStagesTable,
              where:
                  'partition_id = ? AND provider = ? '
                  'AND provider_session_id = ?',
              whereArgs: [
                partitionId,
                thread.provider,
                thread.providerSessionId,
              ],
            );
            await transaction.update(
              SessionCatalogCacheDatabase.hotWindowsTable,
              {'latest_turn_gap_cursor': null},
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
    bool? windowComplete,
    bool advanceIncompleteWireRevision = false,
    bool latestTurnComplete = true,
    ConversationSyncV2LatestTurnGap? latestTurnGap,
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
    if (pageCount > _maxTimelineStagePages) {
      return Future.error(
        StateError('Conversation timeline page count exceeds the local bound.'),
      );
    }
    return _enqueueMutationResult(() async {
      final db = await database.database;
      return db.transaction((transaction) async {
        final commitsCompleteWindow = windowComplete ?? latestTurnComplete;
        final latestTurnGapJson = _encodeLatestTurnGap(
          latestTurnComplete: latestTurnComplete,
          gap: latestTurnGap,
        );
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
            'window_complete': commitsCompleteWindow ? 1 : 0,
            'latest_turn_complete': latestTurnComplete ? 1 : 0,
            'latest_turn_gap_json': latestTurnGapJson,
            'latest_turn_gap_cursor': null,
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
            stage['window_complete'] != (commitsCompleteWindow ? 1 : 0) ||
            stage['latest_turn_complete'] != (latestTurnComplete ? 1 : 0) ||
            stage['latest_turn_gap_json'] != latestTurnGapJson ||
            stage['latest_turn_gap_cursor'] != null ||
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
          final stagedEntryStats = await transaction.rawQuery('''
            SELECT
              COUNT(*) AS row_count,
              COALESCE(SUM(LENGTH(CAST(message_json AS BLOB))), 0) AS byte_count
            FROM ${SessionCatalogCacheDatabase.timelineStageEntriesTable}
            WHERE $keyWhere
            ''', keyArgs);
          final stagedDeleteStats = await transaction.rawQuery('''
            SELECT
              COUNT(*) AS row_count,
              COALESCE(SUM(LENGTH(CAST(entry_id AS BLOB))), 0) AS byte_count
            FROM ${SessionCatalogCacheDatabase.timelineStageDeletesTable}
            WHERE $keyWhere
            ''', keyArgs);
          final stagedRows =
              (stagedEntryStats.single['row_count']! as int) +
              (stagedDeleteStats.single['row_count']! as int);
          final stagedBytes =
              (stagedEntryStats.single['byte_count']! as int) +
              (stagedDeleteStats.single['byte_count']! as int);
          final incomingBytes =
              entries.fold<int>(
                0,
                (total, entry) =>
                    total + utf8.encode(jsonEncode(entry.rawMessage)).length,
              ) +
              deletes.fold<int>(
                0,
                (total, entryId) => total + utf8.encode(entryId).length,
              );
          if (stagedRows + entries.length + deletes.length >
                  _maxTimelineStageRows ||
              stagedBytes + incomingBytes > _maxTimelineStageBytes) {
            await transaction.delete(
              SessionCatalogCacheDatabase.timelineStagesTable,
              where: keyWhere,
              whereArgs: keyArgs,
            );
            return const ConversationTimelinePageCommit(
              pageStored: false,
              windowCommitted: false,
              baseRevisionMatched: true,
              stageRejected: true,
            );
          }
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
        final existingWindows = await transaction.query(
          SessionCatalogCacheDatabase.hotWindowsTable,
          columns: [
            'revision',
            'entry_count',
            'has_earlier',
            'turns_next_cursor',
            'window_complete',
            'source_entry_count',
          ],
          where:
              'partition_id = ? AND provider = ? '
              'AND provider_session_id = ?',
          whereArgs: [partitionId, provider, providerSessionId],
          limit: 1,
        );
        final existingWindow = existingWindows.isEmpty
            ? null
            : existingWindows.single;
        final additiveCommit = !commitsCompleteWindow && existingWindow != null;
        // An incomplete window is an additive observation, never replacement
        // authority. Old Bridges can still attach deletes or a newer wire
        // revision to latestTurnComplete=false frames; both are intentionally
        // ignored here. New Bridges are validated more strictly by the service.
        if (mode == 'patch') {
          if (existingWindow == null ||
              existingWindow['revision'] != baseRevision) {
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
          if (commitsCompleteWindow) {
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
          }
        } else if (mode == 'snapshot') {
          if (!additiveCommit) {
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
                'window_complete': commitsCompleteWindow ? 1 : 0,
                'latest_turn_complete': latestTurnComplete ? 1 : 0,
                'latest_turn_gap_json': latestTurnGapJson,
                'latest_turn_gap_cursor': null,
                'source_entry_count': sourceEntryCount,
                'updated_at': now,
              },
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          }
        } else {
          throw StateError('Unsupported conversation timeline mode: $mode');
        }
        if (additiveCommit) {
          final existingEntries = await transaction.query(
            SessionCatalogCacheDatabase.hotEntriesTable,
            columns: ['entry_id', 'entry_index'],
            where:
                'partition_id = ? AND provider = ? '
                'AND provider_session_id = ?',
            whereArgs: [partitionId, provider, providerSessionId],
            orderBy: 'entry_index ASC',
          );
          final stagedEntries = await transaction.query(
            SessionCatalogCacheDatabase.timelineStageEntriesTable,
            columns: [
              'entry_id',
              'entry_index',
              'content_hash',
              'message_json',
            ],
            where: keyWhere,
            whereArgs: keyArgs,
            orderBy: 'entry_index ASC',
          );
          final existingIds = <String>[];
          final existingPrefixIds = <String>{};
          for (final row in existingEntries) {
            final entryId = row['entry_id']! as String;
            final entryIndex = row['entry_index']! as int;
            existingIds.add(entryId);
            if (entryIndex < 0) existingPrefixIds.add(entryId);
          }
          final stagedIds = stagedEntries
              .map((row) => row['entry_id']! as String)
              .toList(growable: false);
          final mergedIds = _mergeAdditiveTimelineOrder(existingIds, stagedIds);
          if (mergedIds == null) {
            await transaction.delete(
              SessionCatalogCacheDatabase.timelineStagesTable,
              where: keyWhere,
              whereArgs: keyArgs,
            );
            return const ConversationTimelinePageCommit(
              pageStored: false,
              windowCommitted: false,
              baseRevisionMatched: true,
              stageRejected: true,
            );
          }
          var lastExistingPrefixPosition = -1;
          for (var index = 0; index < mergedIds.length; index++) {
            if (existingPrefixIds.contains(mergedIds[index])) {
              lastExistingPrefixPosition = index;
            }
          }
          final prefixExtent = lastExistingPrefixPosition + 1;
          final indexById = <String, int>{
            for (var index = 0; index < mergedIds.length; index++)
              mergedIds[index]: index - prefixExtent,
          };
          final reorder = transaction.batch();
          for (var index = 0; index < mergedIds.length; index++) {
            reorder.update(
              SessionCatalogCacheDatabase.hotEntriesTable,
              {'entry_index': indexById[mergedIds[index]]},
              where:
                  'partition_id = ? AND provider = ? '
                  'AND provider_session_id = ? AND entry_id = ?',
              whereArgs: [
                partitionId,
                provider,
                providerSessionId,
                mergedIds[index],
              ],
            );
          }
          await reorder.commit(noResult: true);
          final upserts = transaction.batch();
          for (final row in stagedEntries) {
            final entryId = row['entry_id']! as String;
            final stableIndex = indexById[entryId];
            if (stableIndex == null) {
              throw StateError('Partial timeline entry has no stable order.');
            }
            upserts.insert(
              SessionCatalogCacheDatabase.hotEntriesTable,
              {
                'partition_id': partitionId,
                'provider': provider,
                'provider_session_id': providerSessionId,
                'entry_id': entryId,
                'entry_index': stableIndex,
                'content_hash': row['content_hash'],
                'message_json': row['message_json'],
              },
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          }
          await upserts.commit(noResult: true);
        } else {
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
        }
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
        final committedRevision = additiveCommit
            ? advanceIncompleteWireRevision
                  ? revision
                  : existingWindow['revision']! as String
            : revision;
        final committedHasEarlier = additiveCommit
            ? (existingWindow['has_earlier']! as int) != 0 || hasEarlier
            : hasEarlier;
        final committedTurnsNextCursor = additiveCommit
            ? (existingWindow['turns_next_cursor'] as String?) ??
                  turnsNextCursor
            : turnsNextCursor;
        final existingSourceEntryCount = additiveCommit
            ? existingWindow['source_entry_count']! as int
            : 0;
        final committedSourceEntryCount = [
          existingSourceEntryCount,
          sourceEntryCount,
          committedCount,
        ].reduce((left, right) => left > right ? left : right);
        final repairStages = await transaction.query(
          SessionCatalogCacheDatabase.latestTurnRepairStagesTable,
          where:
              'partition_id = ? AND provider = ? '
              'AND provider_session_id = ?',
          whereArgs: [partitionId, provider, providerSessionId],
          limit: 1,
        );
        final repairStage = repairStages.isEmpty ? null : repairStages.single;
        var repairStageRowsStillCurrent = repairStage != null;
        if (repairStage != null) {
          final repairBaseRows = await transaction.query(
            SessionCatalogCacheDatabase.latestTurnRepairBaseEntriesTable,
            columns: ['entry_id', 'content_hash'],
            where:
                'partition_id = ? AND provider = ? '
                'AND provider_session_id = ? AND revision = ? AND turn_id = ?',
            whereArgs: [
              partitionId,
              provider,
              providerSessionId,
              repairStage['revision'],
              repairStage['turn_id'],
            ],
          );
          final repairBaseHashes = <String, String>{
            for (final row in repairBaseRows)
              row['entry_id']! as String: row['content_hash']! as String,
          };
          final stagedRows = await transaction.query(
            SessionCatalogCacheDatabase.latestTurnRepairEntriesTable,
            columns: ['entry_id', 'content_hash'],
            where:
                'partition_id = ? AND provider = ? '
                'AND provider_session_id = ? AND revision = ? AND turn_id = ?',
            whereArgs: [
              partitionId,
              provider,
              providerSessionId,
              repairStage['revision'],
              repairStage['turn_id'],
            ],
          );
          final stagedHashes = <String, String>{
            for (final row in stagedRows)
              row['entry_id']! as String: row['content_hash']! as String,
          };
          final currentRepairTurnRows = await transaction.query(
            SessionCatalogCacheDatabase.hotEntriesTable,
            columns: ['entry_id', 'content_hash', 'message_json'],
            where:
                'partition_id = ? AND provider = ? '
                'AND provider_session_id = ?',
            whereArgs: [partitionId, provider, providerSessionId],
          );
          for (final row in currentRepairTurnRows) {
            try {
              final raw = jsonDecode(row['message_json']! as String);
              if (raw is! Map ||
                  raw['historyTurnId'] != repairStage['turn_id']) {
                continue;
              }
              final entryId = row['entry_id']! as String;
              final contentHash = row['content_hash']! as String;
              if (repairBaseHashes[entryId] != contentHash &&
                  stagedHashes[entryId] != contentHash) {
                repairStageRowsStillCurrent = false;
                break;
              }
            } catch (_) {
              repairStageRowsStillCurrent = false;
              break;
            }
          }
        }
        final preserveRepairStage =
            repairStage != null &&
            repairStageRowsStillCurrent &&
            repairStage['revision'] == revision &&
            repairStage['revision'] == committedRevision &&
            !latestTurnComplete &&
            latestTurnGap?.repair == 'items_page' &&
            latestTurnGap?.turnId == repairStage['turn_id'];
        await transaction.update(
          SessionCatalogCacheDatabase.hotWindowsTable,
          {
            'entry_count': committedCount,
            'revision': committedRevision,
            'has_earlier': committedHasEarlier ? 1 : 0,
            'turns_next_cursor': committedTurnsNextCursor,
            'window_complete': commitsCompleteWindow ? 1 : 0,
            'latest_turn_complete': latestTurnComplete ? 1 : 0,
            'latest_turn_gap_json': latestTurnGapJson,
            'latest_turn_gap_cursor': preserveRepairStage
                ? repairStage['expected_cursor']
                : null,
            'source_entry_count': committedSourceEntryCount,
            'updated_at': now,
          },
          where:
              'partition_id = ? AND provider = ? '
              'AND provider_session_id = ?',
          whereArgs: [partitionId, provider, providerSessionId],
        );
        // A partial v2 live patch intentionally retains the acknowledged base
        // revision. Keep a resumable item-page repair only while its exact
        // revision, turn and repair family remain current. The terminal merge
        // below reconciles live rows observed after this stage was created.
        if (!preserveRepairStage) {
          await transaction.delete(
            SessionCatalogCacheDatabase.latestTurnRepairStagesTable,
            where:
                'partition_id = ? AND provider = ? '
                'AND provider_session_id = ?',
            whereArgs: [partitionId, provider, providerSessionId],
          );
        }
        final lastAssistantOutputAt = await _latestStagedAssistantOutputAt(
          transaction,
          keyWhere: keyWhere,
          keyArgs: keyArgs,
        );
        final advancedAssistantOutputAt = lastAssistantOutputAt == null
            ? null
            : await _advanceCachedAssistantOutputAt(
                transaction,
                partitionId: partitionId,
                provider: provider,
                providerSessionId: providerSessionId,
                candidate: lastAssistantOutputAt,
              );
        await transaction.delete(
          SessionCatalogCacheDatabase.timelineStagesTable,
          where: keyWhere,
          whereArgs: keyArgs,
        );
        return ConversationTimelinePageCommit(
          pageStored: true,
          windowCommitted: true,
          baseRevisionMatched: true,
          committedRevision: committedRevision,
          lastAssistantOutputAt: advancedAssistantOutputAt,
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
    return _decodeConversationWindow(
      db: db,
      partitionId: partitionId,
      provider: provider,
      providerSessionId: providerSessionId,
      window: windows.single,
    );
  }

  Future<ConversationHotWindowSnapshot?> _decodeConversationWindow({
    required Database db,
    required String partitionId,
    required String provider,
    required String providerSessionId,
    required Map<String, Object?> window,
  }) async {
    if ((provider != 'claude' && provider != 'codex') ||
        providerSessionId.trim().isEmpty ||
        providerSessionId.length > 256) {
      return null;
    }
    final entryCount = window['entry_count'];
    if (entryCount is! int ||
        entryCount < 0 ||
        entryCount > maxHotWindowEntries) {
      return null;
    }
    final rows = await db.query(
      SessionCatalogCacheDatabase.hotEntriesTable,
      columns: ['entry_id', 'entry_index', 'content_hash', 'message_json'],
      where: 'partition_id = ? AND provider = ? AND provider_session_id = ?',
      whereArgs: [partitionId, provider, providerSessionId],
      orderBy: 'entry_index ASC',
      limit: maxHotWindowEntries + 1,
    );
    if (rows.length != entryCount) return null;
    final entries = <ConversationContentWireEntry>[];
    final entryIndexes = <int>{};
    for (final row in rows) {
      try {
        final entryId = row['entry_id'];
        final entryIndex = row['entry_index'];
        final contentHash = row['content_hash'];
        final encodedMessage = row['message_json'];
        if (entryId is! String ||
            entryIndex is! int ||
            entryIndex < -maxHotWindowEntries ||
            contentHash is! String ||
            encodedMessage is! String ||
            !entryIndexes.add(entryIndex)) {
          return null;
        }
        final decoded = jsonDecode(encodedMessage);
        if (decoded is! Map) return null;
        final entry = ConversationContentWireEntry.fromJson(<String, dynamic>{
          'entryId': entryId,
          // Older turn pages intentionally prepend bounded negative local
          // indexes. Validate the remaining wire fields with the protocol
          // parser, then restore that local ordering value below.
          'index': entryIndex < 0 ? 0 : entryIndex,
          'contentHash': contentHash,
          'message': Map<String, dynamic>.from(decoded),
        });
        entry.decodeMessage();
        entries.add(
          ConversationContentWireEntry(
            entryId: entry.entryId,
            index: entryIndex,
            contentHash: entry.contentHash,
            rawMessage: entry.rawMessage,
          ),
        );
      } catch (_) {
        // A single malformed row invalidates only this rebuildable window.
        return null;
      }
    }
    try {
      final revision = window['revision'];
      final hasEarlier = window['has_earlier'];
      final windowCompleteValue = window['window_complete'];
      final latestTurnCompleteValue = window['latest_turn_complete'];
      final sourceEntryCount = window['source_entry_count'];
      final updatedAt = window['updated_at'];
      if (revision is! String ||
          revision.trim().isEmpty ||
          revision.length > 128 ||
          hasEarlier is! int ||
          (windowCompleteValue != null && windowCompleteValue is! int) ||
          (latestTurnCompleteValue != null &&
              latestTurnCompleteValue is! int) ||
          sourceEntryCount is! int ||
          sourceEntryCount < 0 ||
          updatedAt is! int) {
        return null;
      }
      final latestTurnComplete = (latestTurnCompleteValue as int? ?? 1) != 0;
      final windowComplete = (windowCompleteValue as int? ?? 1) != 0;
      final latestTurnGap = _decodeLatestTurnGap(
        latestTurnComplete: latestTurnComplete,
        encoded: window['latest_turn_gap_json'] as String?,
      );
      return ConversationHotWindowSnapshot(
        partitionId: partitionId,
        provider: provider,
        providerSessionId: providerSessionId,
        revision: revision,
        entries: List<ConversationContentWireEntry>.unmodifiable(entries),
        hasEarlier: hasEarlier != 0,
        turnsNextCursor: window['turns_next_cursor'] as String?,
        windowComplete: windowComplete,
        latestTurnComplete: latestTurnComplete,
        latestTurnGap: latestTurnGap,
        latestTurnGapCursor: latestTurnComplete
            ? null
            : window['latest_turn_gap_cursor'] as String?,
        sourceEntryCount: sourceEntryCount,
        cachedAt: DateTime.fromMillisecondsSinceEpoch(updatedAt, isUtc: true),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> replaceConversationWindow({
    required SessionCatalogCacheTarget target,
    required String provider,
    required String providerSessionId,
    required String revision,
    required List<ConversationContentWireEntry> entries,
    required bool hasEarlier,
    String? turnsNextCursor,
    bool windowComplete = true,
    bool latestTurnComplete = true,
    ConversationSyncV2LatestTurnGap? latestTurnGap,
    String? latestTurnGapCursor,
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
        final latestTurnGapJson = _encodeLatestTurnGap(
          latestTurnComplete: latestTurnComplete,
          gap: latestTurnGap,
        );
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
            'window_complete': windowComplete ? 1 : 0,
            'latest_turn_complete': latestTurnComplete ? 1 : 0,
            'latest_turn_gap_json': latestTurnGapJson,
            'latest_turn_gap_cursor': latestTurnComplete
                ? null
                : latestTurnGapCursor,
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
    required String expectedRevision,
    required String? expectedCursor,
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
    final applied = await _enqueueMutationResult(() async {
      final db = await database.database;
      return db.transaction((transaction) async {
        final partitionId = await _resolveReadablePartition(
          transaction,
          target,
        );
        if (partitionId == null) return false;
        final windows = await transaction.query(
          SessionCatalogCacheDatabase.hotWindowsTable,
          columns: ['revision', 'turns_next_cursor', 'source_entry_count'],
          where:
              'partition_id = ? AND provider = ? '
              'AND provider_session_id = ?',
          whereArgs: [partitionId, provider, providerSessionId],
          limit: 1,
        );
        if (windows.isEmpty) return false;
        final current = windows.single;
        if (current['revision'] != expectedRevision ||
            current['turns_next_cursor'] != expectedCursor) {
          return false;
        }

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
        final existingCountRows = await transaction.rawQuery(
          '''
          SELECT COUNT(*) AS entry_count
          FROM ${SessionCatalogCacheDatabase.hotEntriesTable}
          WHERE partition_id = ?
            AND provider = ?
            AND provider_session_id = ?
          ''',
          [partitionId, provider, providerSessionId],
        );
        final existingCount = Sqflite.firstIntValue(existingCountRows) ?? 0;
        if (existingCount + additions.length > maxHotWindowEntries) {
          return false;
        }
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
        if (firstIndex < -maxHotWindowEntries) return false;
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
        return true;
      });
    });
    if (!applied) return null;
    return loadConversationWindow(
      target: target,
      provider: provider,
      providerSessionId: providerSessionId,
    );
  }

  /// Atomically captures the readable latest-turn baseline before a provider
  /// page request is sent.
  ///
  /// Creating this stage after the response arrives is unsafe: live timeline
  /// commits during the network flight would be mistaken for the original
  /// baseline and a terminal repair could delete or overwrite those newer
  /// rows. A missing or superseded stage therefore fails closed.
  Future<bool> prepareConversationLatestTurnItemsRepair({
    required SessionCatalogCacheTarget target,
    required String provider,
    required String providerSessionId,
    required String expectedRevision,
    required String expectedTurnId,
    required String? expectedCursor,
  }) {
    if (!target.isValid) return Future.value(false);
    return _enqueueMutationResult(() async {
      final db = await database.database;
      return db.transaction((transaction) async {
        final partitionId = await _resolveReadablePartition(
          transaction,
          target,
        );
        if (partitionId == null) return false;
        final windows = await transaction.query(
          SessionCatalogCacheDatabase.hotWindowsTable,
          columns: [
            'revision',
            'latest_turn_complete',
            'latest_turn_gap_json',
            'latest_turn_gap_cursor',
          ],
          where:
              'partition_id = ? AND provider = ? '
              'AND provider_session_id = ?',
          whereArgs: [partitionId, provider, providerSessionId],
          limit: 1,
        );
        if (windows.isEmpty) return false;
        final window = windows.single;
        final complete = (window['latest_turn_complete'] as int? ?? 1) != 0;
        final gap = _decodeLatestTurnGap(
          latestTurnComplete: complete,
          encoded: window['latest_turn_gap_json'] as String?,
        );
        if (complete ||
            window['revision'] != expectedRevision ||
            gap?.repair != 'items_page' ||
            gap?.turnId != expectedTurnId ||
            window['latest_turn_gap_cursor'] != expectedCursor) {
          return false;
        }

        final stages = await transaction.query(
          SessionCatalogCacheDatabase.latestTurnRepairStagesTable,
          where:
              'partition_id = ? AND provider = ? '
              'AND provider_session_id = ?',
          whereArgs: [partitionId, provider, providerSessionId],
          limit: 1,
        );
        final stage = stages.isEmpty ? null : stages.single;
        if (stage != null) {
          return stage['revision'] == expectedRevision &&
              stage['turn_id'] == expectedTurnId &&
              stage['expected_cursor'] == expectedCursor;
        }
        if (expectedCursor != null) return false;

        await transaction
            .insert(SessionCatalogCacheDatabase.latestTurnRepairStagesTable, {
              'partition_id': partitionId,
              'provider': provider,
              'provider_session_id': providerSessionId,
              'revision': expectedRevision,
              'turn_id': expectedTurnId,
              'expected_cursor': null,
              'page_depth': 0,
              'entry_count': 0,
              'byte_count': 0,
              'updated_at': DateTime.now().toUtc().millisecondsSinceEpoch,
            });
        final baseRows = await transaction.query(
          SessionCatalogCacheDatabase.hotEntriesTable,
          columns: ['entry_id', 'content_hash', 'message_json'],
          where:
              'partition_id = ? AND provider = ? '
              'AND provider_session_id = ?',
          whereArgs: [partitionId, provider, providerSessionId],
        );
        for (final row in baseRows) {
          try {
            final decoded = jsonDecode(row['message_json']! as String);
            if (decoded is! Map || decoded['historyTurnId'] != expectedTurnId) {
              continue;
            }
            await transaction.insert(
              SessionCatalogCacheDatabase.latestTurnRepairBaseEntriesTable,
              {
                'partition_id': partitionId,
                'provider': provider,
                'provider_session_id': providerSessionId,
                'revision': expectedRevision,
                'turn_id': expectedTurnId,
                'entry_id': row['entry_id'],
                'content_hash': row['content_hash'],
              },
            );
          } catch (_) {
            // A malformed legacy row remains readable but cannot establish a
            // safe request-time identity fence for latest-turn replacement.
          }
        }
        return true;
      });
    });
  }

  /// Stages one ascending item page for an incomplete newest turn.
  ///
  /// The readable hot window is deliberately left untouched until the final
  /// page arrives. Publishing each page immediately used to append recovered
  /// early items after already-visible later items, so the same turn jumped
  /// around while repair progressed. The terminal page replaces only this
  /// turn in one SQLite transaction, preserving older cached turns.
  Future<ConversationHotWindowSnapshot?> mergeConversationLatestTurnItemsPage({
    required SessionCatalogCacheTarget target,
    required String provider,
    required String providerSessionId,
    required String expectedRevision,
    required String expectedTurnId,
    required List<Map<String, dynamic>> rawMessages,
    required String? expectedCursor,
    required String? nextCursor,
    bool pageComplete = true,
    ConversationSyncV2LatestTurnGap? latestTurnGap,
  }) async {
    if (!target.isValid) return null;
    final candidates = _historyPageEntries(rawMessages);
    final applied = await _enqueueMutationResult(() async {
      final db = await database.database;
      return db.transaction((transaction) async {
        final partitionId = await _resolveReadablePartition(
          transaction,
          target,
        );
        if (partitionId == null) return false;
        final windows = await transaction.query(
          SessionCatalogCacheDatabase.hotWindowsTable,
          columns: [
            'revision',
            'entry_count',
            'latest_turn_complete',
            'latest_turn_gap_json',
            'source_entry_count',
          ],
          where:
              'partition_id = ? AND provider = ? '
              'AND provider_session_id = ?',
          whereArgs: [partitionId, provider, providerSessionId],
          limit: 1,
        );
        if (windows.isEmpty) return false;
        final window = windows.single;
        final complete = (window['latest_turn_complete'] as int? ?? 1) != 0;
        final gap = _decodeLatestTurnGap(
          latestTurnComplete: complete,
          encoded: window['latest_turn_gap_json'] as String?,
        );
        if (complete ||
            window['revision'] != expectedRevision ||
            gap?.repair != 'items_page' ||
            gap?.turnId != expectedTurnId) {
          return false;
        }

        final stages = await transaction.query(
          SessionCatalogCacheDatabase.latestTurnRepairStagesTable,
          where:
              'partition_id = ? AND provider = ? '
              'AND provider_session_id = ?',
          whereArgs: [partitionId, provider, providerSessionId],
          limit: 1,
        );
        final stage = stages.isEmpty ? null : stages.single;
        if (stage == null ||
            stage['revision'] != expectedRevision ||
            stage['turn_id'] != expectedTurnId ||
            stage['expected_cursor'] != expectedCursor) {
          return false;
        }

        if (nextCursor != null && nextCursor == expectedCursor) {
          throw StateError(
            'Conversation latest turn repair returned a repeated cursor.',
          );
        }

        final pageDepth = stage['page_depth'] as int? ?? 0;
        for (var itemOrder = 0; itemOrder < candidates.length; itemOrder++) {
          final candidate = candidates[itemOrder];
          final encoded = jsonEncode(candidate.rawMessage);
          await transaction.insert(
            SessionCatalogCacheDatabase.latestTurnRepairEntriesTable,
            {
              'partition_id': partitionId,
              'provider': provider,
              'provider_session_id': providerSessionId,
              'revision': expectedRevision,
              'turn_id': expectedTurnId,
              'page_depth': pageDepth,
              'item_order': itemOrder,
              'entry_id': candidate.entryId,
              'content_hash': candidate.contentHash,
              'message_json': encoded,
            },
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        }
        final stagedStats = await transaction.rawQuery(
          '''
          SELECT
            COUNT(*) AS entry_count,
            COALESCE(SUM(LENGTH(CAST(message_json AS BLOB))), 0) AS byte_count
          FROM ${SessionCatalogCacheDatabase.latestTurnRepairEntriesTable}
          WHERE partition_id = ? AND provider = ?
            AND provider_session_id = ? AND revision = ? AND turn_id = ?
          ''',
          [
            partitionId,
            provider,
            providerSessionId,
            expectedRevision,
            expectedTurnId,
          ],
        );
        final stagedEntryCount = stagedStats.single['entry_count']! as int;
        final stagedByteCount = stagedStats.single['byte_count']! as int;
        if (stagedEntryCount > maxHotWindowEntries ||
            stagedByteCount > _maxTimelineStageBytes) {
          throw StateError(
            'Conversation latest turn repair exceeds the local safety bound.',
          );
        }
        final completed = nextCursor == null && pageComplete;
        if (!completed) {
          await transaction.update(
            SessionCatalogCacheDatabase.latestTurnRepairStagesTable,
            {
              'expected_cursor': nextCursor,
              'page_depth': pageDepth + 1,
              'entry_count': stagedEntryCount,
              'byte_count': stagedByteCount,
              'updated_at': DateTime.now().toUtc().millisecondsSinceEpoch,
            },
            where:
                'partition_id = ? AND provider = ? '
                'AND provider_session_id = ?',
            whereArgs: [partitionId, provider, providerSessionId],
          );
          await transaction.update(
            SessionCatalogCacheDatabase.hotWindowsTable,
            {
              'latest_turn_gap_json': jsonEncode(
                (pageComplete ? gap : (latestTurnGap ?? gap))!.toJson(),
              ),
              'latest_turn_gap_cursor': nextCursor,
            },
            where:
                'partition_id = ? AND provider = ? '
                'AND provider_session_id = ?',
            whereArgs: [partitionId, provider, providerSessionId],
          );
          return true;
        }

        final existingRows = await transaction.query(
          SessionCatalogCacheDatabase.hotEntriesTable,
          columns: ['entry_id', 'entry_index', 'content_hash', 'message_json'],
          where:
              'partition_id = ? AND provider = ? '
              'AND provider_session_id = ?',
          whereArgs: [partitionId, provider, providerSessionId],
          orderBy: 'entry_index ASC',
        );
        final retainedRows = existingRows
            .where((row) {
              try {
                final raw = jsonDecode(row['message_json']! as String);
                return raw is! Map || raw['historyTurnId'] != expectedTurnId;
              } catch (_) {
                return true;
              }
            })
            .toList(growable: false);
        final existingCurrentTurnRows = existingRows
            .where((row) {
              try {
                final raw = jsonDecode(row['message_json']! as String);
                return raw is Map && raw['historyTurnId'] == expectedTurnId;
              } catch (_) {
                return false;
              }
            })
            .toList(growable: false);
        final baseRows = await transaction.query(
          SessionCatalogCacheDatabase.latestTurnRepairBaseEntriesTable,
          columns: ['entry_id', 'content_hash'],
          where:
              'partition_id = ? AND provider = ? '
              'AND provider_session_id = ? AND revision = ? AND turn_id = ?',
          whereArgs: [
            partitionId,
            provider,
            providerSessionId,
            expectedRevision,
            expectedTurnId,
          ],
        );
        final baseHashes = <String, String>{
          for (final row in baseRows)
            row['entry_id']! as String: row['content_hash']! as String,
        };
        final stagedRows = await transaction.query(
          SessionCatalogCacheDatabase.latestTurnRepairEntriesTable,
          columns: ['entry_id', 'content_hash', 'message_json'],
          where:
              'partition_id = ? AND provider = ? '
              'AND provider_session_id = ? AND revision = ? AND turn_id = ?',
          whereArgs: [
            partitionId,
            provider,
            providerSessionId,
            expectedRevision,
            expectedTurnId,
          ],
          orderBy: 'page_depth ASC, item_order ASC',
        );
        final stagedById = <String, Map<String, Object?>>{
          for (final row in stagedRows) row['entry_id']! as String: row,
        };
        final newLiveRows = <Map<String, Object?>>[];
        for (final row in existingCurrentTurnRows) {
          final entryId = row['entry_id']! as String;
          final contentHash = row['content_hash']! as String;
          final baseHash = baseHashes[entryId];
          final stagedRow = stagedById[entryId];
          if (baseHash == null || baseHash != contentHash) {
            if (stagedRow != null && stagedRow['content_hash'] != contentHash) {
              throw StateError(
                'Conversation latest turn changed while its repair was active.',
              );
            }
            if (stagedRow == null) newLiveRows.add(row);
          }
        }
        final combinedCount =
            retainedRows.length + stagedRows.length + newLiveRows.length;
        if (combinedCount > maxHotWindowEntries) {
          throw StateError(
            'Conversation latest turn repair exceeds the local safety bound.',
          );
        }
        await transaction.delete(
          SessionCatalogCacheDatabase.hotEntriesTable,
          where:
              'partition_id = ? AND provider = ? '
              'AND provider_session_id = ?',
          whereArgs: [partitionId, provider, providerSessionId],
        );
        var entryIndex = 0;
        for (final row in [...retainedRows, ...stagedRows, ...newLiveRows]) {
          await transaction
              .insert(SessionCatalogCacheDatabase.hotEntriesTable, {
                'partition_id': partitionId,
                'provider': provider,
                'provider_session_id': providerSessionId,
                'entry_id': row['entry_id'],
                'entry_index': entryIndex++,
                'content_hash': row['content_hash'],
                'message_json': row['message_json'],
              });
        }
        await transaction.update(
          SessionCatalogCacheDatabase.hotWindowsTable,
          {
            'entry_count': combinedCount,
            'latest_turn_complete': 1,
            'latest_turn_gap_json': null,
            'latest_turn_gap_cursor': null,
            'source_entry_count':
                (window['source_entry_count']! as int) > combinedCount
                ? window['source_entry_count']
                : combinedCount,
            'updated_at': DateTime.now().toUtc().millisecondsSinceEpoch,
          },
          where:
              'partition_id = ? AND provider = ? '
              'AND provider_session_id = ?',
          whereArgs: [partitionId, provider, providerSessionId],
        );
        await transaction.delete(
          SessionCatalogCacheDatabase.latestTurnRepairStagesTable,
          where:
              'partition_id = ? AND provider = ? '
              'AND provider_session_id = ?',
          whereArgs: [partitionId, provider, providerSessionId],
        );
        return true;
      });
    });
    if (!applied) return null;
    return loadConversationWindow(
      target: target,
      provider: provider,
      providerSessionId: providerSessionId,
    );
  }

  /// Merges a bounded latest-turn summary without destroying richer rows.
  ///
  /// A turns-page summary does not prove coverage of the hot window or of the
  /// latest turn's item list. It may enrich an incomplete cache, but only a
  /// later complete canonical timeline may replace or mark that cache complete.
  Future<ConversationHotWindowSnapshot?>
  replaceConversationLatestTurnsRepairPage({
    required SessionCatalogCacheTarget target,
    required String provider,
    required String providerSessionId,
    required String expectedRevision,
    required List<Map<String, dynamic>> rawMessages,
    required String? turnsNextCursor,
  }) async {
    if (!target.isValid) return null;
    final entries = _historyPageEntries(rawMessages);
    if (entries.isEmpty) return null;
    if (entries.length > maxHotWindowEntries) {
      throw StateError(
        'Conversation latest turns repair exceeds the local safety bound.',
      );
    }
    final applied = await _enqueueMutationResult(() async {
      final db = await database.database;
      return db.transaction((transaction) async {
        final partitionId = await _resolveReadablePartition(
          transaction,
          target,
        );
        if (partitionId == null) return false;
        final windows = await transaction.query(
          SessionCatalogCacheDatabase.hotWindowsTable,
          columns: [
            'revision',
            'source_entry_count',
            'has_earlier',
            'turns_next_cursor',
            'latest_turn_complete',
            'latest_turn_gap_json',
          ],
          where:
              'partition_id = ? AND provider = ? '
              'AND provider_session_id = ?',
          whereArgs: [partitionId, provider, providerSessionId],
          limit: 1,
        );
        if (windows.isEmpty) return false;
        final window = windows.single;
        final complete = (window['latest_turn_complete'] as int? ?? 1) != 0;
        final gap = _decodeLatestTurnGap(
          latestTurnComplete: complete,
          encoded: window['latest_turn_gap_json'] as String?,
        );
        if (window['revision'] != expectedRevision ||
            complete ||
            gap?.repair != 'turns_page') {
          return false;
        }
        final existingRows = await transaction.query(
          SessionCatalogCacheDatabase.hotEntriesTable,
          columns: ['entry_id', 'entry_index'],
          where:
              'partition_id = ? AND provider = ? '
              'AND provider_session_id = ?',
          whereArgs: [partitionId, provider, providerSessionId],
        );
        final indexById = <String, int>{
          for (final row in existingRows)
            row['entry_id']! as String: row['entry_index']! as int,
        };
        final hasPagedPrefix = existingRows.any(
          (row) => (row['entry_index']! as int) < 0,
        );
        final newEntryCount = entries
            .where((entry) => !indexById.containsKey(entry.entryId))
            .length;
        if (existingRows.length + newEntryCount > maxHotWindowEntries) {
          throw StateError(
            'Conversation latest turns repair exceeds the local safety bound.',
          );
        }
        var appendIndex = existingRows.fold<int>(
          -1,
          (maximum, row) => (row['entry_index']! as int) > maximum
              ? row['entry_index']! as int
              : maximum,
        );
        for (final entry in entries) {
          if (indexById.containsKey(entry.entryId)) continue;
          final stableIndex = ++appendIndex;
          await _insertHotEntry(
            transaction,
            partitionId: partitionId,
            provider: provider,
            providerSessionId: providerSessionId,
            entry: ConversationContentWireEntry(
              entryId: entry.entryId,
              index: stableIndex,
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
        final committedCount = Sqflite.firstIntValue(countRows) ?? 0;
        final sourceEntryCount = window['source_entry_count']! as int;
        await transaction.update(
          SessionCatalogCacheDatabase.hotWindowsTable,
          {
            'entry_count': committedCount,
            'has_earlier': hasPagedPrefix
                ? window['has_earlier']
                : turnsNextCursor == null
                ? 0
                : 1,
            'turns_next_cursor': hasPagedPrefix
                ? window['turns_next_cursor']
                : turnsNextCursor,
            'window_complete': 0,
            'latest_turn_complete': 0,
            'latest_turn_gap_json': window['latest_turn_gap_json'],
            'latest_turn_gap_cursor': null,
            'source_entry_count': sourceEntryCount > committedCount
                ? sourceEntryCount
                : committedCount,
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
    if (!applied) return null;
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
    bool latestTurnComplete = true,
    ConversationSyncV2LatestTurnGap? latestTurnGap,
    required int sourceEntryCount,
  }) {
    if (!target.isValid) return Future<bool>.value(false);
    return _enqueueMutationResult(() async {
      final db = await database.database;
      return db.transaction((transaction) async {
        final latestTurnGapJson = _encodeLatestTurnGap(
          latestTurnComplete: latestTurnComplete,
          gap: latestTurnGap,
        );
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
        // Legacy/v1 patches are authoritative mutations of the readable hot
        // window but do not carry the v2 item-page staging generation. Any
        // resumable repair created for the old window must therefore be
        // invalidated before its next page can rewrite this newer patch.
        await transaction.delete(
          SessionCatalogCacheDatabase.latestTurnRepairStagesTable,
          where:
              'partition_id = ? AND provider = ? '
              'AND provider_session_id = ?',
          whereArgs: [partitionId, provider, providerSessionId],
        );
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
            'window_complete': 1,
            'latest_turn_complete': latestTurnComplete ? 1 : 0,
            'latest_turn_gap_json': latestTurnGapJson,
            'latest_turn_gap_cursor': null,
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
      await db.transaction((transaction) async {
        for (final table in [
          SessionCatalogCacheDatabase.timelineStagesTable,
          SessionCatalogCacheDatabase.latestTurnRepairStagesTable,
          SessionCatalogCacheDatabase.hotWindowsTable,
          SessionCatalogCacheDatabase.userIndexStatesTable,
        ]) {
          await transaction.delete(
            table,
            where:
                'partition_id = ? AND provider = ? '
                'AND provider_session_id = ?',
            whereArgs: [partitionId, provider, providerSessionId],
          );
        }
      });
    });
  }

  static Future<void> _clearRebuildableCache(
    Transaction transaction, {
    required String? where,
    required List<Object?> whereArgs,
  }) async {
    for (final table in [
      SessionCatalogCacheDatabase.timelineStagesTable,
      SessionCatalogCacheDatabase.latestTurnRepairStagesTable,
      SessionCatalogCacheDatabase.hotWindowsTable,
      SessionCatalogCacheDatabase.statusesTable,
      SessionCatalogCacheDatabase.syncStatesTable,
      SessionCatalogCacheDatabase.userIndexStatesTable,
      SessionCatalogCacheDatabase.entriesTable,
    ]) {
      await transaction.delete(
        table,
        where: where,
        whereArgs: where == null ? null : whereArgs,
      );
    }
    await transaction.update(
      SessionCatalogCacheDatabase.partitionsTable,
      {
        'last_server_revision': null,
        'complete_revision': null,
        'updated_at': DateTime.now().toUtc().millisecondsSinceEpoch,
      },
      where: where,
      whereArgs: where == null ? null : whereArgs,
    );
    // Read watermarks are user state, not a rebuildable cache. Keeping the
    // partition and aliases also lets all routes for the same Bridge retain
    // the same unread boundary after catalog/history data is rebuilt.
  }

  Future<ConversationUserIndexSnapshot?> loadConversationUserIndex({
    required SessionCatalogCacheTarget target,
    required String provider,
    required String providerSessionId,
  }) async {
    if (!target.isValid) return null;
    await _mutationTail;
    final db = await database.database;
    return db.transaction((transaction) async {
      final partitionId = await _resolveReadablePartition(transaction, target);
      if (partitionId == null) return null;
      final states = await transaction.query(
        SessionCatalogCacheDatabase.userIndexStatesTable,
        columns: ['active_revision', 'active_complete', 'updated_at'],
        where: 'partition_id = ? AND provider = ? AND provider_session_id = ?',
        whereArgs: [partitionId, provider, providerSessionId],
        limit: 1,
      );
      if (states.isEmpty) return null;
      final revision = states.single['active_revision'] as String?;
      if (revision == null || revision.isEmpty) return null;
      await userCacheReadBarrierForTesting?.call();
      final rows = await transaction.query(
        SessionCatalogCacheDatabase.userIndexEntriesTable,
        columns: ['provider_turn_id', 'provider_item_id', 'message_json'],
        where:
            'partition_id = ? AND provider = ? AND provider_session_id = ? '
            'AND revision = ?',
        whereArgs: [partitionId, provider, providerSessionId, revision],
        // Bridge pages are requested descending (newest first). Read older
        // pages first and reverse each page so navigation is chronological.
        orderBy: 'page_depth DESC, item_order DESC',
      );
      final entries = <ConversationUserIndexEntry>[];
      for (final row in rows) {
        try {
          final decoded = jsonDecode(row['message_json']! as String);
          if (decoded is! Map) continue;
          final message = ServerMessage.fromJson(
            Map<String, dynamic>.from(decoded),
          );
          if (message is! UserInputMessage ||
              message.isSynthetic ||
              message.isMeta) {
            continue;
          }
          entries.add(
            ConversationUserIndexEntry(
              providerTurnId: row['provider_turn_id']! as String,
              providerItemId: (row['provider_item_id'] as String?)?.trim(),
              message: message,
            ),
          );
        } catch (_) {
          // One rebuildable row must not hide the remaining usable index.
        }
      }
      return ConversationUserIndexSnapshot(
        revision: revision,
        entries: List.unmodifiable(entries),
        complete: states.single['active_complete'] == 1,
        cachedAt: DateTime.fromMillisecondsSinceEpoch(
          states.single['updated_at']! as int,
          isUtc: true,
        ),
      );
    });
  }

  /// Reads only the active user-index generation without decoding its rows.
  ///
  /// Background warmup uses this probe so an unchanged large index does not
  /// materialize every user prompt in memory just to discover it is current.
  Future<ConversationUserIndexState?> loadConversationUserIndexState({
    required SessionCatalogCacheTarget target,
    required String provider,
    required String providerSessionId,
  }) async {
    if (!target.isValid) return null;
    await _mutationTail;
    final db = await database.database;
    return db.transaction((transaction) async {
      final partitionId = await _resolveReadablePartition(transaction, target);
      if (partitionId == null) return null;
      final states = await transaction.query(
        SessionCatalogCacheDatabase.userIndexStatesTable,
        columns: ['active_revision', 'active_complete', 'updated_at'],
        where: 'partition_id = ? AND provider = ? AND provider_session_id = ?',
        whereArgs: [partitionId, provider, providerSessionId],
        limit: 1,
      );
      if (states.isEmpty) return null;
      final revision = states.single['active_revision'] as String?;
      if (revision == null || revision.isEmpty) return null;
      return ConversationUserIndexState(
        revision: revision,
        complete: states.single['active_complete'] == 1,
        cachedAt: DateTime.fromMillisecondsSinceEpoch(
          states.single['updated_at']! as int,
          isUtc: true,
        ),
      );
    });
  }

  Future<ConversationUserIndexStage?> prepareConversationUserIndex({
    required SessionCatalogCacheTarget target,
    required String provider,
    required String providerSessionId,
    required String revision,
  }) {
    if (!target.isValid || revision.trim().isEmpty) {
      return Future.value();
    }
    return _enqueueMutationResult(() async {
      final db = await database.database;
      return db.transaction((transaction) async {
        final partitionId = await _ensureWritablePartition(transaction, target);
        final where =
            'partition_id = ? AND provider = ? AND provider_session_id = ?';
        final whereArgs = [partitionId, provider, providerSessionId];
        final rows = await transaction.query(
          SessionCatalogCacheDatabase.userIndexStatesTable,
          where: where,
          whereArgs: whereArgs,
          limit: 1,
        );
        final current = rows.isEmpty ? null : rows.single;
        final activeRevision = current?['active_revision'] as String?;
        final activeComplete = current?['active_complete'] == 1;
        if (activeRevision == revision && activeComplete) {
          return ConversationUserIndexStage(
            revision: revision,
            cursor: null,
            pageDepth: 0,
            complete: true,
          );
        }
        final stagingRevision = current?['staging_revision'] as String?;
        if (stagingRevision == revision) {
          return ConversationUserIndexStage(
            revision: revision,
            cursor: current?['staging_cursor'] as String?,
            pageDepth: current?['staging_page_depth'] as int? ?? 0,
            complete: false,
          );
        }
        if (activeRevision == null) {
          await transaction.delete(
            SessionCatalogCacheDatabase.userIndexEntriesTable,
            where: '$where AND revision != ?',
            whereArgs: [...whereArgs, revision],
          );
        } else {
          await transaction.delete(
            SessionCatalogCacheDatabase.userIndexEntriesTable,
            where: '$where AND revision != ? AND revision != ?',
            whereArgs: [...whereArgs, activeRevision, revision],
          );
        }
        final now = DateTime.now().toUtc().millisecondsSinceEpoch;
        final stateValues = {
          'active_revision': activeRevision,
          'active_complete': activeComplete ? 1 : 0,
          'staging_revision': revision,
          'staging_cursor': null,
          'staging_page_depth': 0,
          'updated_at': now,
        };
        if (current == null) {
          await transaction
              .insert(SessionCatalogCacheDatabase.userIndexStatesTable, {
                'partition_id': partitionId,
                'provider': provider,
                'provider_session_id': providerSessionId,
                ...stateValues,
              });
        } else {
          await transaction.update(
            SessionCatalogCacheDatabase.userIndexStatesTable,
            stateValues,
            where: where,
            whereArgs: whereArgs,
          );
        }
        await transaction.delete(
          SessionCatalogCacheDatabase.userIndexEntriesTable,
          where: '$where AND revision = ?',
          whereArgs: [...whereArgs, revision],
        );
        return ConversationUserIndexStage(
          revision: revision,
          cursor: null,
          pageDepth: 0,
          complete: false,
        );
      });
    });
  }

  Future<ConversationUserIndexStage?> commitConversationUserIndexPage({
    required SessionCatalogCacheTarget target,
    required String provider,
    required String providerSessionId,
    required String revision,
    required String? expectedCursor,
    required int pageDepth,
    required String? nextCursor,
    required List<ConversationUserIndexPageEntry> entries,
  }) {
    if (!target.isValid) return Future.value();
    return _enqueueMutationResult(() async {
      final db = await database.database;
      return db.transaction((transaction) async {
        final partitionId = await _resolveReadablePartition(
          transaction,
          target,
        );
        if (partitionId == null) return null;
        final where =
            'partition_id = ? AND provider = ? AND provider_session_id = ?';
        final whereArgs = [partitionId, provider, providerSessionId];
        final states = await transaction.query(
          SessionCatalogCacheDatabase.userIndexStatesTable,
          where: where,
          whereArgs: whereArgs,
          limit: 1,
        );
        if (states.isEmpty) return null;
        final state = states.single;
        if (state['staging_revision'] != revision ||
            state['staging_cursor'] != expectedCursor ||
            state['staging_page_depth'] != pageDepth) {
          return null;
        }
        for (var itemOrder = 0; itemOrder < entries.length; itemOrder++) {
          final entry = entries[itemOrder];
          final providerTurnId = entry.providerTurnId.trim();
          final providerItemId = entry.providerItemId?.trim() ?? '';
          if (providerTurnId.isEmpty) continue;
          final raw = Map<String, dynamic>.from(entry.rawMessage);
          if (providerItemId.isEmpty) {
            raw.remove('providerItemId');
          } else {
            raw['providerItemId'] = providerItemId;
          }
          raw['historyTurnId'] = providerTurnId;
          final entryIdentity = _userIndexEntryIdentity(
            providerItemId: providerItemId,
            rawMessage: raw,
            pageDepth: pageDepth,
            itemOrder: itemOrder,
          );
          final timestamp = DateTime.tryParse(
            (raw['receivedAt'] ?? raw['sourceTimestamp'] ?? raw['timestamp'])
                    as String? ??
                '',
          );
          await transaction.insert(
            SessionCatalogCacheDatabase.userIndexEntriesTable,
            {
              'partition_id': partitionId,
              'provider': provider,
              'provider_session_id': providerSessionId,
              'revision': revision,
              'provider_turn_id': providerTurnId,
              'provider_item_id': providerItemId.isEmpty
                  ? null
                  : providerItemId,
              'entry_identity': entryIdentity,
              'page_depth': pageDepth,
              'item_order': itemOrder,
              'message_json': jsonEncode(raw),
              'timestamp_sort': timestamp?.toUtc().millisecondsSinceEpoch ?? 0,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        final now = DateTime.now().toUtc().millisecondsSinceEpoch;
        final complete = nextCursor == null;
        await transaction.update(
          SessionCatalogCacheDatabase.userIndexStatesTable,
          complete
              ? {
                  'active_revision': revision,
                  'active_complete': 1,
                  'staging_revision': null,
                  'staging_cursor': null,
                  'staging_page_depth': 0,
                  'updated_at': now,
                }
              : {
                  'staging_cursor': nextCursor,
                  'staging_page_depth': pageDepth + 1,
                  'updated_at': now,
                },
          where: where,
          whereArgs: whereArgs,
        );
        if (complete) {
          await transaction.delete(
            SessionCatalogCacheDatabase.userIndexEntriesTable,
            where: '$where AND revision != ?',
            whereArgs: [...whereArgs, revision],
          );
        }
        return ConversationUserIndexStage(
          revision: revision,
          cursor: nextCursor,
          pageDepth: pageDepth + 1,
          complete: complete,
        );
      });
    });
  }

  Future<ConversationUserTurnDetailSnapshot?> loadConversationUserTurnDetail({
    required SessionCatalogCacheTarget target,
    required String provider,
    required String providerSessionId,
    required String providerTurnId,
  }) async {
    if (!target.isValid || providerTurnId.trim().isEmpty) return null;
    await _mutationTail;
    final db = await database.database;
    return db.transaction((transaction) async {
      final partitionId = await _resolveReadablePartition(transaction, target);
      if (partitionId == null) return null;
      final where =
          'partition_id = ? AND provider = ? AND provider_session_id = ? '
          'AND provider_turn_id = ?';
      final whereArgs = [
        partitionId,
        provider,
        providerSessionId,
        providerTurnId,
      ];
      final states = await transaction.query(
        SessionCatalogCacheDatabase.userTurnDetailsTable,
        columns: ['revision', 'complete', 'updated_at'],
        where: where,
        whereArgs: whereArgs,
        orderBy: 'complete DESC, updated_at DESC',
        limit: 1,
      );
      if (states.isEmpty) return null;
      final revision = states.single['revision']! as String;
      await userCacheReadBarrierForTesting?.call();
      final rows = await transaction.query(
        SessionCatalogCacheDatabase.userTurnDetailItemsTable,
        columns: ['message_json'],
        where: '$where AND revision = ?',
        whereArgs: [...whereArgs, revision],
        orderBy: 'page_depth ASC, item_order ASC',
      );
      final messages = <ServerMessage>[];
      for (final row in rows) {
        try {
          final decoded = jsonDecode(row['message_json']! as String);
          if (decoded is! Map) continue;
          messages.add(
            ServerMessage.fromJson(Map<String, dynamic>.from(decoded)),
          );
        } catch (_) {
          // Detail pages are rebuildable. Skip one malformed row and keep the
          // remaining bounded turn usable.
        }
      }
      return ConversationUserTurnDetailSnapshot(
        revision: revision,
        messages: List.unmodifiable(messages),
        complete: states.single['complete'] == 1,
        cachedAt: DateTime.fromMillisecondsSinceEpoch(
          states.single['updated_at']! as int,
          isUtc: true,
        ),
      );
    });
  }

  Future<ConversationUserTurnDetailStage?> prepareConversationUserTurnDetail({
    required SessionCatalogCacheTarget target,
    required String provider,
    required String providerSessionId,
    required String providerTurnId,
    required String revision,
  }) {
    final normalizedTurnId = providerTurnId.trim();
    if (!target.isValid ||
        normalizedTurnId.isEmpty ||
        revision.trim().isEmpty) {
      return Future.value();
    }
    return _enqueueMutationResult(() async {
      final db = await database.database;
      return db.transaction((transaction) async {
        final partitionId = await _ensureWritablePartition(transaction, target);
        final now = DateTime.now().toUtc().millisecondsSinceEpoch;
        await transaction.insert(
          SessionCatalogCacheDatabase.userIndexStatesTable,
          {
            'partition_id': partitionId,
            'provider': provider,
            'provider_session_id': providerSessionId,
            'active_revision': null,
            'active_complete': 0,
            'staging_revision': null,
            'staging_cursor': null,
            'staging_page_depth': 0,
            'updated_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        final threadWhere =
            'partition_id = ? AND provider = ? AND provider_session_id = ?';
        final threadWhereArgs = [partitionId, provider, providerSessionId];
        await transaction.delete(
          SessionCatalogCacheDatabase.userTurnDetailsTable,
          where: '$threadWhere AND complete = 0 AND revision != ?',
          whereArgs: [...threadWhereArgs, revision],
        );
        final where =
            'partition_id = ? AND provider = ? AND provider_session_id = ? '
            'AND provider_turn_id = ? AND revision = ?';
        final whereArgs = [
          partitionId,
          provider,
          providerSessionId,
          normalizedTurnId,
          revision,
        ];
        final rows = await transaction.query(
          SessionCatalogCacheDatabase.userTurnDetailsTable,
          where: where,
          whereArgs: whereArgs,
          limit: 1,
        );
        if (rows.isNotEmpty) {
          final current = rows.single;
          if (current['complete'] == 1) {
            return ConversationUserTurnDetailStage(
              revision: current['revision']! as String,
              cursor: null,
              pageDepth: current['page_depth']! as int,
              complete: true,
            );
          }
          return ConversationUserTurnDetailStage(
            revision: revision,
            cursor: current['next_cursor'] as String?,
            pageDepth: current['page_depth']! as int,
            complete: false,
          );
        }
        await transaction
            .insert(SessionCatalogCacheDatabase.userTurnDetailsTable, {
              'partition_id': partitionId,
              'provider': provider,
              'provider_session_id': providerSessionId,
              'provider_turn_id': normalizedTurnId,
              'revision': revision,
              'next_cursor': null,
              'page_depth': 0,
              'complete': 0,
              'updated_at': now,
            });
        return ConversationUserTurnDetailStage(
          revision: revision,
          cursor: null,
          pageDepth: 0,
          complete: false,
        );
      });
    });
  }

  Future<ConversationUserTurnDetailStage?>
  commitConversationUserTurnDetailPage({
    required SessionCatalogCacheTarget target,
    required String provider,
    required String providerSessionId,
    required String providerTurnId,
    required String revision,
    required String? expectedCursor,
    required int pageDepth,
    required String? nextCursor,
    required List<Map<String, dynamic>> rawMessages,
  }) {
    if (!target.isValid) return Future.value();
    return _enqueueMutationResult(() async {
      final db = await database.database;
      return db.transaction((transaction) async {
        final partitionId = await _resolveReadablePartition(
          transaction,
          target,
        );
        if (partitionId == null) return null;
        final where =
            'partition_id = ? AND provider = ? AND provider_session_id = ? '
            'AND provider_turn_id = ? AND revision = ?';
        final whereArgs = [
          partitionId,
          provider,
          providerSessionId,
          providerTurnId,
          revision,
        ];
        final rows = await transaction.query(
          SessionCatalogCacheDatabase.userTurnDetailsTable,
          where: where,
          whereArgs: whereArgs,
          limit: 1,
        );
        if (rows.isEmpty) return null;
        final state = rows.single;
        if (state['next_cursor'] != expectedCursor ||
            state['page_depth'] != pageDepth ||
            state['complete'] == 1) {
          return null;
        }
        for (var itemOrder = 0; itemOrder < rawMessages.length; itemOrder++) {
          final raw = Map<String, dynamic>.from(rawMessages[itemOrder]);
          raw['historyTurnId'] = providerTurnId;
          await transaction.insert(
            SessionCatalogCacheDatabase.userTurnDetailItemsTable,
            {
              'partition_id': partitionId,
              'provider': provider,
              'provider_session_id': providerSessionId,
              'provider_turn_id': providerTurnId,
              'revision': revision,
              'page_depth': pageDepth,
              'item_order': itemOrder,
              'message_json': jsonEncode(raw),
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        final complete = nextCursor == null;
        final now = DateTime.now().toUtc().millisecondsSinceEpoch;
        await transaction.update(
          SessionCatalogCacheDatabase.userTurnDetailsTable,
          {
            'next_cursor': nextCursor,
            'page_depth': pageDepth + 1,
            'complete': complete ? 1 : 0,
            'updated_at': now,
          },
          where: where,
          whereArgs: whereArgs,
        );
        if (complete) {
          await transaction.delete(
            SessionCatalogCacheDatabase.userTurnDetailsTable,
            where:
                'partition_id = ? AND provider = ? '
                'AND provider_session_id = ? AND provider_turn_id = ? '
                'AND revision != ?',
            whereArgs: [
              partitionId,
              provider,
              providerSessionId,
              providerTurnId,
              revision,
            ],
          );
        }
        return ConversationUserTurnDetailStage(
          revision: revision,
          cursor: nextCursor,
          pageDepth: pageDepth + 1,
          complete: complete,
        );
      });
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

  static Future<void> _ignoreSupersededConversationBatch(
    Future<void> operation,
  ) async {
    try {
      await operation;
    } on _ConversationCacheBatchSuperseded {
      // The SQLite transaction has rolled back. A newer connection/source
      // generation owns the live cache now.
    }
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

  static String _userIndexEntryIdentity({
    required String providerItemId,
    required Map<String, dynamic> rawMessage,
    required int pageDepth,
    required int itemOrder,
  }) {
    if (providerItemId.isNotEmpty) return 'provider:$providerItemId';
    final legacyUuid = (rawMessage['userMessageUuid'] as String?)?.trim();
    if (legacyUuid != null && legacyUuid.isNotEmpty) {
      return 'legacy:uuid:$legacyUuid:page:$pageDepth:item:$itemOrder';
    }
    return 'legacy:ordinal:page:$pageDepth:item:$itemOrder';
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
      final historyTurnId = (rawMessage['historyTurnId'] as String?)?.trim();
      String scoped(String identity) => historyTurnId?.isNotEmpty == true
          ? 'turn:$historyTurnId:$identity'
          : identity;
      String? identity;
      if (type == 'user_input') {
        final providerItemId = (rawMessage['providerItemId'] as String?)
            ?.trim();
        final legacyUuid = (rawMessage['userMessageUuid'] as String?)?.trim();
        identity = providerItemId?.isNotEmpty == true
            ? 'user-provider:$providerItemId'
            : legacyUuid?.isNotEmpty == true
            ? scoped('user:$legacyUuid')
            : 'user:$contentHash';
      } else if (type == 'assistant') {
        final nested = rawMessage['message'];
        final messageId = nested is Map ? nested['id'] as String? : null;
        final stableId =
            (rawMessage['messageUuid'] as String?)?.trim().isNotEmpty == true
            ? rawMessage['messageUuid'] as String
            : messageId;
        identity = stableId?.trim().isNotEmpty == true
            ? scoped('assistant:$stableId')
            : 'assistant:$contentHash';
      } else if (type == 'tool_result') {
        final toolUseId = rawMessage['toolUseId'] as String?;
        identity = toolUseId?.trim().isNotEmpty == true
            ? scoped('tool-result:$toolUseId')
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

  static List<ConversationContentWireEntry> _historyPageEntries(
    List<Map<String, dynamic>> rawMessages,
  ) {
    final entries = <ConversationContentWireEntry>[];
    final seen = <String>{};
    for (var index = 0; index < rawMessages.length; index++) {
      final candidate = _historyPageEntry(rawMessages[index], index);
      if (candidate == null) continue;
      var entryId = candidate.entryId;
      if (!seen.add(entryId)) {
        entryId = '$entryId:${candidate.contentHash.substring(0, 16)}';
        if (!seen.add(entryId)) continue;
      }
      entries.add(
        ConversationContentWireEntry(
          entryId: entryId,
          index: index,
          contentHash: candidate.contentHash,
          rawMessage: candidate.rawMessage,
        ),
      );
    }
    return List.unmodifiable(entries);
  }

  static String? _encodeLatestTurnGap({
    required bool latestTurnComplete,
    required ConversationSyncV2LatestTurnGap? gap,
  }) {
    if (latestTurnComplete) return null;
    if (gap == null) {
      throw StateError(
        'An incomplete latest turn must include a repair directive.',
      );
    }
    return jsonEncode(gap.toJson());
  }

  static ConversationSyncV2LatestTurnGap? _decodeLatestTurnGap({
    required bool latestTurnComplete,
    required String? encoded,
  }) {
    if (latestTurnComplete) return null;
    try {
      final decoded = jsonDecode(encoded ?? '');
      if (decoded is! Map) throw const FormatException();
      return ConversationSyncV2LatestTurnGap.fromJson(
        Map<String, dynamic>.from(decoded),
      );
    } catch (_) {
      // This cache is rebuildable. Preserve the incomplete marker and use the
      // safest read-only repair when an old or damaged row lacks metadata.
      return const ConversationSyncV2LatestTurnGap(
        missingEntryCount: 0,
        payloadOmitted: true,
        repair: 'turns_page',
      );
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

  static Future<String?> _latestStagedAssistantOutputAt(
    DatabaseExecutor database, {
    required String keyWhere,
    required List<Object?> keyArgs,
  }) async {
    final rows = await database.query(
      SessionCatalogCacheDatabase.timelineStageEntriesTable,
      columns: ['message_json'],
      where: keyWhere,
      whereArgs: keyArgs,
      orderBy: 'entry_index DESC',
      limit: maxHotWindowEntries,
    );
    for (final row in rows) {
      try {
        final decoded = jsonDecode(row['message_json']! as String);
        if (decoded is! Map) continue;
        final message = ServerMessage.fromJson(
          Map<String, dynamic>.from(decoded),
        );
        if (message is! AssistantServerMessage ||
            !message.message.content.any(isVisibleAssistantTextContent)) {
          continue;
        }
        final timestamp = serverMessageTimestamp(message);
        if (timestamp == null) continue;
        return timestamp.value.toUtc().toIso8601String();
      } catch (_) {
        // The enclosing timeline validation owns malformed-entry recovery.
        // A missing optional ordering checkpoint must not reject a valid page.
      }
    }
    return null;
  }

  static Future<String?> _advanceCachedAssistantOutputAt(
    DatabaseExecutor database, {
    required String partitionId,
    required String provider,
    required String providerSessionId,
    required String candidate,
  }) async {
    final candidateTime = DateTime.tryParse(candidate)?.toUtc();
    if (candidateTime == null) return null;
    final rows = await database.query(
      SessionCatalogCacheDatabase.entriesTable,
      columns: ['project_path', 'session_json'],
      where: 'partition_id = ? AND provider = ? AND session_id = ?',
      whereArgs: [partitionId, provider, providerSessionId],
    );
    if (rows.isEmpty) return candidateTime.toIso8601String();
    var advanced = false;
    for (final row in rows) {
      try {
        final decoded = jsonDecode(row['session_json']! as String);
        if (decoded is! Map) continue;
        final session = RecentSession.fromJson(
          Map<String, dynamic>.from(decoded),
        );
        final current = DateTime.tryParse(
          session.lastAssistantOutputAt ?? '',
        )?.toUtc();
        if (current != null && !candidateTime.isAfter(current)) continue;
        final updated = session.copyWithLastAssistantOutputAt(
          candidateTime.toIso8601String(),
        );
        await database.update(
          SessionCatalogCacheDatabase.entriesTable,
          {'session_json': jsonEncode(updated.toJson())},
          where:
              'partition_id = ? AND provider = ? AND project_path = ? '
              'AND session_id = ?',
          whereArgs: [
            partitionId,
            provider,
            row['project_path'],
            providerSessionId,
          ],
        );
        advanced = true;
      } catch (_) {
        // Catalog cache rows are rebuildable; leave a damaged row untouched.
      }
    }
    return advanced ? candidateTime.toIso8601String() : null;
  }

  static Future<Map<String, RecentSession>> _cachedSessionsByIdentity(
    DatabaseExecutor database,
    String partitionId,
    Iterable<RecentSession> incoming,
  ) async {
    final identities = <String, (String, String)>{};
    for (final session in incoming) {
      final provider = session.provider ?? Provider.claude.value;
      identities[_conversationIdentity(provider, session.sessionId)] = (
        provider,
        session.sessionId,
      );
    }
    if (identities.isEmpty) return const {};

    final sessions = <String, RecentSession>{};
    final values = identities.values.toList(growable: false);
    const identitiesPerQuery = 200;
    for (var start = 0; start < values.length; start += identitiesPerQuery) {
      final candidateEnd = start + identitiesPerQuery;
      final end = candidateEnd < values.length ? candidateEnd : values.length;
      final chunk = values.sublist(start, end);
      final identityPredicate = List.filled(
        chunk.length,
        '(provider = ? AND session_id = ?)',
      ).join(' OR ');
      final rows = await database.query(
        SessionCatalogCacheDatabase.entriesTable,
        columns: ['provider', 'session_id', 'session_json'],
        where: 'partition_id = ? AND ($identityPredicate)',
        whereArgs: [
          partitionId,
          for (final (provider, sessionId) in chunk) ...[provider, sessionId],
        ],
      );
      for (final row in rows) {
        try {
          final decoded = jsonDecode(row['session_json']! as String);
          if (decoded is! Map) continue;
          final session = RecentSession.fromJson(
            Map<String, dynamic>.from(decoded),
          );
          sessions[_conversationIdentity(
                row['provider']! as String,
                row['session_id']! as String,
              )] =
              session;
        } catch (_) {
          // The cache is rebuildable; one damaged prior row must not block
          // the authoritative catalog transaction.
        }
      }
    }
    return sessions;
  }

  /// Applies sparse Codex settings and provider-independent Desktop project
  /// semantics to persistent and in-memory catalog projections.
  ///
  /// A regular catalog refresh is intentionally allowed to omit expensive
  /// settings fields or Desktop project metadata. Once an authoritative
  /// snapshot has been committed, a later sparse refresh must not erase it.
  /// A complete incoming snapshot is authoritative and may explicitly clear
  /// or replace fields.
  static RecentSession mergeIncompleteCodexSettings({
    required RecentSession incoming,
    required RecentSession? cached,
  }) {
    if (cached == null) return incoming;
    final preserveSettings =
        incoming.provider == Provider.codex.value &&
        !incoming.codexSettingsSnapshotComplete;
    final preserveProjectGrouping =
        !incoming.projectGroupingSnapshotComplete &&
        cached.projectGroupingSnapshotComplete;
    if (!preserveSettings && !preserveProjectGrouping) return incoming;
    final collaborationKnown = incoming.codexCollaborationMode != null;
    final incomingHasPermissionFacts =
        incoming.codexApprovalPolicy != null ||
        incoming.codexApprovalsReviewer != null ||
        incoming.codexSandboxMode != null ||
        collaborationKnown;
    return RecentSession(
      sessionId: incoming.sessionId,
      provider: incoming.provider,
      codexSourceId: incoming.codexSourceId,
      rawPermissionMode:
          incoming.rawPermissionMode ??
          (preserveSettings && !incomingHasPermissionFacts
              ? cached.rawPermissionMode
              : null),
      forkedFromThreadId: incoming.forkedFromThreadId,
      name: incoming.name,
      agentNickname: incoming.agentNickname,
      agentRole: incoming.agentRole,
      summary: incoming.summary,
      firstPrompt: incoming.firstPrompt,
      lastPrompt: incoming.lastPrompt,
      created: incoming.created,
      modified: incoming.modified,
      contentRevision: incoming.contentRevision ?? cached.contentRevision,
      lastAssistantOutputAt: incoming.lastAssistantOutputAt,
      gitBranch: incoming.gitBranch,
      projectPath: incoming.projectPath,
      resumeCwd: incoming.resumeCwd,
      projectGroupKind: preserveProjectGrouping
          ? incoming.projectGroupKind ?? cached.projectGroupKind
          : incoming.projectGroupKind,
      projectGroupId: preserveProjectGrouping
          ? incoming.projectGroupId ?? cached.projectGroupId
          : incoming.projectGroupId,
      projectGroupName: preserveProjectGrouping
          ? incoming.projectGroupName ?? cached.projectGroupName
          : incoming.projectGroupName,
      projectGroupPath: preserveProjectGrouping
          ? incoming.projectGroupPath ?? cached.projectGroupPath
          : incoming.projectGroupPath,
      projectGroupingSnapshotComplete:
          incoming.projectGroupingSnapshotComplete || preserveProjectGrouping,
      isSidechain: incoming.isSidechain,
      codexApprovalPolicy:
          incoming.codexApprovalPolicy ??
          (preserveSettings ? cached.codexApprovalPolicy : null),
      codexApprovalsReviewer:
          incoming.codexApprovalsReviewer ??
          (preserveSettings ? cached.codexApprovalsReviewer : null),
      codexPermissionsMode:
          incoming.codexPermissionsMode ??
          (preserveSettings && !incomingHasPermissionFacts
              ? cached.codexPermissionsMode
              : null),
      executionMode:
          incoming.executionMode ??
          (preserveSettings && incoming.codexApprovalPolicy == null
              ? cached.executionMode
              : null),
      planMode: collaborationKnown || !preserveSettings
          ? incoming.planMode
          : cached.planMode,
      codexSandboxMode:
          incoming.codexSandboxMode ??
          (preserveSettings ? cached.codexSandboxMode : null),
      codexCollaborationMode:
          incoming.codexCollaborationMode ??
          (preserveSettings ? cached.codexCollaborationMode : null),
      codexModel:
          incoming.codexModel ?? (preserveSettings ? cached.codexModel : null),
      codexProfile:
          incoming.codexProfile ??
          (preserveSettings ? cached.codexProfile : null),
      codexModelReasoningEffort:
          incoming.codexModelReasoningEffort ??
          (preserveSettings ? cached.codexModelReasoningEffort : null),
      codexServiceTier:
          incoming.codexServiceTier ??
          (preserveSettings ? cached.codexServiceTier : null),
      codexNetworkAccessEnabled:
          incoming.codexNetworkAccessEnabled ??
          (preserveSettings ? cached.codexNetworkAccessEnabled : null),
      codexWebSearchMode:
          incoming.codexWebSearchMode ??
          (preserveSettings ? cached.codexWebSearchMode : null),
      codexAdditionalWritableRoots:
          incoming.codexAdditionalWritableRoots.isNotEmpty || !preserveSettings
          ? incoming.codexAdditionalWritableRoots
          : cached.codexAdditionalWritableRoots,
      codexSettingsSnapshotComplete:
          incoming.codexSettingsSnapshotComplete ||
          (preserveSettings && cached.codexSettingsSnapshotComplete),
    );
  }

  static String _conversationIdentity(String provider, String sessionId) =>
      '$provider\u0000$sessionId';

  static String? _latestIsoTimestamp(String? first, String? second) {
    final firstTime = DateTime.tryParse(first ?? '')?.toUtc();
    final secondTime = DateTime.tryParse(second ?? '')?.toUtc();
    if (firstTime == null) return secondTime?.toIso8601String();
    if (secondTime == null) return firstTime.toIso8601String();
    return (firstTime.isAfter(secondTime) ? firstTime : secondTime)
        .toIso8601String();
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

    final sourceSyncRows = await transaction.query(
      SessionCatalogCacheDatabase.syncStatesTable,
      where: 'partition_id = ?',
      whereArgs: [sourcePartitionId],
      limit: 1,
    );
    if (sourceSyncRows.isNotEmpty) {
      final sourceSync = sourceSyncRows.single;
      final targetSyncRows = await transaction.query(
        SessionCatalogCacheDatabase.syncStatesTable,
        where: 'partition_id = ?',
        whereArgs: [targetPartitionId],
        limit: 1,
      );
      final targetSync = targetSyncRows.isEmpty ? null : targetSyncRows.single;
      final sourceUpdatedAt = sourceSync['updated_at']! as int;
      final targetUpdatedAt = targetSync?['updated_at'] as int? ?? -1;
      final newer = sourceUpdatedAt > targetUpdatedAt ? sourceSync : targetSync;
      await transaction.insert(
        SessionCatalogCacheDatabase.syncStatesTable,
        {
          'partition_id': targetPartitionId,
          'catalog_state': newer?['catalog_state'],
          'status_state': newer?['status_state'],
          'priority_ready':
              ((sourceSync['priority_ready'] as int? ?? 0) != 0 ||
                  (targetSync?['priority_ready'] as int? ?? 0) != 0)
              ? 1
              : 0,
          'updated_at': sourceUpdatedAt > targetUpdatedAt
              ? sourceUpdatedAt
              : targetUpdatedAt,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }

    final sourceStatuses = await transaction.query(
      SessionCatalogCacheDatabase.statusesTable,
      where: 'partition_id = ?',
      whereArgs: [sourcePartitionId],
    );
    for (final sourceStatus in sourceStatuses) {
      final provider = sourceStatus['provider']! as String;
      final providerSessionId = sourceStatus['provider_session_id']! as String;
      final targetRows = await transaction.query(
        SessionCatalogCacheDatabase.statusesTable,
        columns: ['observed_sort', 'updated_at'],
        where:
            'partition_id = ? AND provider = ? '
            'AND provider_session_id = ?',
        whereArgs: [targetPartitionId, provider, providerSessionId],
        limit: 1,
      );
      final sourceObserved = sourceStatus['observed_sort']! as int;
      final sourceUpdatedAt = sourceStatus['updated_at']! as int;
      final targetIsNewer =
          targetRows.isNotEmpty &&
          (((targetRows.single['observed_sort']! as int) > sourceObserved) ||
              ((targetRows.single['observed_sort']! as int) == sourceObserved &&
                  (targetRows.single['updated_at']! as int) >=
                      sourceUpdatedAt));
      if (targetIsNewer) continue;
      await transaction.insert(
        SessionCatalogCacheDatabase.statusesTable,
        {...sourceStatus, 'partition_id': targetPartitionId},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }

    final sourceWatermarks = await transaction.query(
      SessionCatalogCacheDatabase.readWatermarksTable,
      where: 'partition_id = ?',
      whereArgs: [sourcePartitionId],
    );
    for (final sourceWatermark in sourceWatermarks) {
      final provider = sourceWatermark['provider']! as String;
      final providerSessionId =
          sourceWatermark['provider_session_id']! as String;
      final targetRows = await transaction.query(
        SessionCatalogCacheDatabase.readWatermarksTable,
        columns: ['read_sort', 'updated_at'],
        where:
            'partition_id = ? AND provider = ? '
            'AND provider_session_id = ?',
        whereArgs: [targetPartitionId, provider, providerSessionId],
        limit: 1,
      );
      final sourceReadSort = sourceWatermark['read_sort']! as int;
      final sourceUpdatedAt = sourceWatermark['updated_at']! as int;
      final targetIsNewer =
          targetRows.isNotEmpty &&
          (((targetRows.single['read_sort']! as int) > sourceReadSort) ||
              ((targetRows.single['read_sort']! as int) == sourceReadSort &&
                  (targetRows.single['updated_at']! as int) >=
                      sourceUpdatedAt));
      if (targetIsNewer) continue;
      await transaction.insert(
        SessionCatalogCacheDatabase.readWatermarksTable,
        {...sourceWatermark, 'partition_id': targetPartitionId},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }

    await _mergeConversationUserCaches(
      transaction,
      sourcePartitionId: sourcePartitionId,
      targetPartitionId: targetPartitionId,
      now: now,
    );

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

    // Incomplete timeline stages are connection/subscription scoped and
    // rebuildable. Deleting the provisional partition intentionally drops
    // them instead of replaying stale pages under an authenticated identity.
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

  static Future<void> _mergeConversationUserCaches(
    Transaction transaction, {
    required String sourcePartitionId,
    required String targetPartitionId,
    required int now,
  }) async {
    final sourceStates = await transaction.query(
      SessionCatalogCacheDatabase.userIndexStatesTable,
      where: 'partition_id = ?',
      whereArgs: [sourcePartitionId],
    );
    for (final sourceState in sourceStates) {
      final provider = sourceState['provider']! as String;
      final providerSessionId = sourceState['provider_session_id']! as String;
      final threadWhere =
          'partition_id = ? AND provider = ? AND provider_session_id = ?';
      final sourceThreadArgs = [sourcePartitionId, provider, providerSessionId];
      final targetThreadArgs = [targetPartitionId, provider, providerSessionId];
      final sourceActiveRevision = sourceState['active_revision'] as String?;
      final sourceHasCompleteIndex =
          sourceState['active_complete'] == 1 &&
          sourceActiveRevision != null &&
          sourceActiveRevision.isNotEmpty;
      final sourceCompleteDetails = await transaction.query(
        SessionCatalogCacheDatabase.userTurnDetailsTable,
        where: '$threadWhere AND complete = 1',
        whereArgs: sourceThreadArgs,
        orderBy: 'updated_at DESC',
      );
      if (!sourceHasCompleteIndex && sourceCompleteDetails.isEmpty) {
        // Provisional staging cursors are connection-scoped and are discarded
        // rather than being resumed after source authentication changes.
        continue;
      }

      final targetStates = await transaction.query(
        SessionCatalogCacheDatabase.userIndexStatesTable,
        where: threadWhere,
        whereArgs: targetThreadArgs,
        limit: 1,
      );
      final targetState = targetStates.isEmpty ? null : targetStates.single;
      final targetActiveRevision = targetState?['active_revision'] as String?;
      final targetHasCompleteIndex =
          targetState?['active_complete'] == 1 &&
          targetActiveRevision != null &&
          targetActiveRevision.isNotEmpty;
      final sourceUpdatedAt = sourceState['updated_at']! as int;
      final useSourceIndex = sourceHasCompleteIndex && !targetHasCompleteIndex;

      if (targetState == null) {
        await transaction
            .insert(SessionCatalogCacheDatabase.userIndexStatesTable, {
              'partition_id': targetPartitionId,
              'provider': provider,
              'provider_session_id': providerSessionId,
              'active_revision': useSourceIndex ? sourceActiveRevision : null,
              'active_complete': useSourceIndex ? 1 : 0,
              'staging_revision': null,
              'staging_cursor': null,
              'staging_page_depth': 0,
              'updated_at': useSourceIndex ? sourceUpdatedAt : now,
            });
      } else if (useSourceIndex) {
        await transaction.update(
          SessionCatalogCacheDatabase.userIndexStatesTable,
          {
            'active_revision': sourceActiveRevision,
            'active_complete': 1,
            'staging_revision': null,
            'staging_cursor': null,
            'staging_page_depth': 0,
            'updated_at': sourceUpdatedAt,
          },
          where: threadWhere,
          whereArgs: targetThreadArgs,
        );
      }

      if (useSourceIndex) {
        await transaction.delete(
          SessionCatalogCacheDatabase.userIndexEntriesTable,
          where: threadWhere,
          whereArgs: targetThreadArgs,
        );
        final sourceEntries = await transaction.query(
          SessionCatalogCacheDatabase.userIndexEntriesTable,
          where: '$threadWhere AND revision = ?',
          whereArgs: [...sourceThreadArgs, sourceActiveRevision],
        );
        for (final sourceEntry in sourceEntries) {
          await transaction.insert(
            SessionCatalogCacheDatabase.userIndexEntriesTable,
            {...sourceEntry, 'partition_id': targetPartitionId},
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      }

      for (final sourceDetail in sourceCompleteDetails) {
        final providerTurnId = sourceDetail['provider_turn_id']! as String;
        final revision = sourceDetail['revision']! as String;
        final sourceDetailUpdatedAt = sourceDetail['updated_at']! as int;
        final targetDetails = await transaction.query(
          SessionCatalogCacheDatabase.userTurnDetailsTable,
          columns: ['updated_at'],
          where: '$threadWhere AND provider_turn_id = ? AND complete = 1',
          whereArgs: [...targetThreadArgs, providerTurnId],
          orderBy: 'updated_at DESC',
          limit: 1,
        );
        if (targetDetails.isNotEmpty &&
            (targetDetails.single['updated_at']! as int) >=
                sourceDetailUpdatedAt) {
          continue;
        }
        await transaction.insert(
          SessionCatalogCacheDatabase.userTurnDetailsTable,
          {...sourceDetail, 'partition_id': targetPartitionId},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        final sourceItems = await transaction.query(
          SessionCatalogCacheDatabase.userTurnDetailItemsTable,
          where: '$threadWhere AND provider_turn_id = ? AND revision = ?',
          whereArgs: [...sourceThreadArgs, providerTurnId, revision],
        );
        for (final sourceItem in sourceItems) {
          await transaction.insert(
            SessionCatalogCacheDatabase.userTurnDetailItemsTable,
            {...sourceItem, 'partition_id': targetPartitionId},
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await transaction.delete(
          SessionCatalogCacheDatabase.userTurnDetailsTable,
          where: '$threadWhere AND provider_turn_id = ? AND revision != ?',
          whereArgs: [...targetThreadArgs, providerTurnId, revision],
        );
      }
    }
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

class _ConversationCacheBatchSuperseded implements Exception {
  const _ConversationCacheBatchSuperseded();
}

/// Merges an incomplete ordered observation into an existing hot window.
///
/// Existing rows keep their relative order. New rows are inserted immediately
/// before the next overlapping stable-ID anchor; a trailing run is appended.
/// Reversed anchors prove the partial projection is inconsistent with the
/// committed cache, so the caller must reject it and wait for a complete
/// replacement instead of guessing from timestamps.
List<String>? _mergeAdditiveTimelineOrder(
  List<String> existingIds,
  List<String> incomingIds,
) {
  final existingPositions = <String, int>{
    for (var index = 0; index < existingIds.length; index++)
      existingIds[index]: index,
  };
  final incomingUnique = <String>[];
  final seenIncoming = <String>{};
  for (final entryId in incomingIds) {
    if (seenIncoming.add(entryId)) incomingUnique.add(entryId);
  }

  var lastAnchorPosition = -1;
  for (final entryId in incomingUnique) {
    final position = existingPositions[entryId];
    if (position == null) continue;
    if (position <= lastAnchorPosition) return null;
    lastAnchorPosition = position;
  }

  final beforeAnchor = <String, List<String>>{};
  final pending = <String>[];
  for (final entryId in incomingUnique) {
    if (existingPositions.containsKey(entryId)) {
      if (pending.isNotEmpty) {
        beforeAnchor[entryId] = List<String>.of(pending);
        pending.clear();
      }
    } else {
      pending.add(entryId);
    }
  }

  return [
    for (final entryId in existingIds) ...[...?beforeAnchor[entryId], entryId],
    ...pending,
  ];
}
