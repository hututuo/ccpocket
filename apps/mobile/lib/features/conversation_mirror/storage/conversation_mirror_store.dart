import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import 'conversation_mirror_database.dart';
import 'conversation_mirror_models.dart';

/// Transactional local mirror of provider conversations.
///
/// Snapshot transfers are written into a shadow generation. Only
/// [completeShadowGeneration] changes the active generation; an interrupted
/// transfer therefore cannot replace the last known-good local conversation.
class ConversationMirrorStore {
  ConversationMirrorStore(
    this._database, {
    this.limits = const ConversationMirrorLimits(),
    this.readTransactionHook,
  }) {
    if (limits.maxEntriesPerGeneration <= 0 ||
        limits.maxEntriesPerPage <= 0 ||
        limits.maxEntryBytes <= 0 ||
        limits.maxPageBytes <= 0 ||
        limits.maxTotalBytes <= 0 ||
        limits.maxDatabaseBytes <= 0) {
      throw ArgumentError.value(limits, 'limits', 'Limits must be positive.');
    }
  }

  static const _keyWhere =
      'bridge_instance_id = ? AND provider = ? AND provider_session_id = ?';

  final ConversationMirrorDatabase _database;
  final ConversationMirrorLimits limits;

  /// Deterministic race-test seam invoked after the active generation is read
  /// but before its entries are queried, while the read transaction is open.
  @visibleForTesting
  final Future<void> Function(String generation)? readTransactionHook;

  Future<void> beginShadowGeneration({
    required ConversationMirrorKey key,
    required String generation,
    required String revision,
    required int entryCount,
    required int pageCount,
    required int totalBytes,
    bool? autoSync,
    String? projectPath,
  }) async {
    _validateKey(key);
    _validateGeneration(generation);
    _validateRevision(revision);
    _validateSnapshotShape(
      entryCount: entryCount,
      pageCount: pageCount,
      totalBytes: totalBytes,
    );
    if (projectPath != null) _validateProjectPath(projectPath);

    final db = await _database.database;
    await db.transaction((txn) async {
      final current = await _queryMetadata(txn, key);
      final baseActiveGeneration = current?['active_generation'] as String?;
      final baseRevision = current?['revision'] as String?;
      if (current == null) {
        await txn.insert(ConversationMirrorDatabase.metadataTable, {
          ..._keyColumns(key),
          'active_generation': null,
          'revision': null,
          'entry_count': 0,
          'bytes': 0,
          'auto_sync': autoSync == true ? 1 : 0,
          'project_path': projectPath ?? '',
          'last_synced_at': null,
          'error': null,
        });
      } else {
        if (baseActiveGeneration == generation) {
          throw ConversationMirrorValidationException(
            'Shadow generation must differ from the active generation.',
          );
        }
        final updates = <String, Object?>{};
        if (autoSync != null) updates['auto_sync'] = autoSync ? 1 : 0;
        if (projectPath != null) updates['project_path'] = projectPath;
        if (updates.isNotEmpty) {
          await txn.update(
            ConversationMirrorDatabase.metadataTable,
            updates,
            where: _keyWhere,
            whereArgs: _keyArgs(key),
          );
        }
      }

      // One shadow transfer per conversation. Starting a new one abandons any
      // older incomplete transfer while preserving the active generation.
      await txn.delete(
        ConversationMirrorDatabase.stagingTable,
        where: _keyWhere,
        whereArgs: _keyArgs(key),
      );
      if (baseActiveGeneration == null) {
        await txn.delete(
          ConversationMirrorDatabase.entriesTable,
          where: _keyWhere,
          whereArgs: _keyArgs(key),
        );
      } else {
        await txn.delete(
          ConversationMirrorDatabase.entriesTable,
          where: '$_keyWhere AND generation != ?',
          whereArgs: [..._keyArgs(key), baseActiveGeneration],
        );
      }

      final currentDatabaseBytes = await _databasePayloadBytes(txn);
      if (currentDatabaseBytes + totalBytes > limits.maxDatabaseBytes) {
        throw ConversationMirrorValidationException(
          'Snapshot would exceed the ${limits.maxDatabaseBytes}-byte '
          'conversation mirror database limit.',
        );
      }

      await txn.insert(ConversationMirrorDatabase.stagingTable, {
        ..._keyColumns(key),
        'generation': generation,
        'target_revision': revision,
        'base_active_generation': baseActiveGeneration,
        'base_revision': baseRevision,
        'expected_entry_count': entryCount,
        'expected_page_count': pageCount,
        'expected_bytes': totalBytes,
        'actual_entry_count': 0,
        'actual_bytes': 0,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
    });
  }

  Future<void> appendShadowPage({
    required ConversationMirrorKey key,
    required String generation,
    required int pageIndex,
    required int pageCount,
    required List<ConversationMirrorEntryInput> entries,
    bool transportFragmented = false,
  }) async {
    _validateKey(key);
    _validateGeneration(generation);
    if (pageIndex < 0) {
      throw const ConversationMirrorValidationException(
        'Page index must be non-negative.',
      );
    }
    if (pageCount <= 0) {
      throw const ConversationMirrorValidationException(
        'Page count must be positive when appending a page.',
      );
    }
    if (entries.isEmpty) {
      throw const ConversationMirrorValidationException(
        'Snapshot pages must not be empty.',
      );
    }
    if (entries.length > limits.maxEntriesPerPage) {
      throw ConversationMirrorValidationException(
        'Page contains ${entries.length} entries; limit is '
        '${limits.maxEntriesPerPage}.',
      );
    }

    final prepared = _prepareEntries(
      entries,
      maxEntryBytes: transportFragmented
          ? limits.maxTotalBytes
          : limits.maxEntryBytes,
    );
    final pageBytes = prepared.fold<int>(0, (sum, entry) => sum + entry.bytes);
    final maxPageBytes = transportFragmented
        ? limits.maxTotalBytes
        : limits.maxPageBytes;
    if (pageBytes > maxPageBytes) {
      throw ConversationMirrorValidationException(
        'Page is $pageBytes bytes; limit is $maxPageBytes.',
      );
    }
    _validateDistinctInputs(prepared);
    final pageDigest = _pageDigest(prepared);

    final db = await _database.database;
    await db.transaction((txn) async {
      final staging = await _queryStaging(txn, key, generation);
      if (staging == null) {
        throw const ConversationMirrorValidationException(
          'No matching shadow generation is in progress.',
        );
      }
      final expectedPageCount = staging['expected_page_count'] as int;
      final expectedEntryCount = staging['expected_entry_count'] as int;
      if (pageCount != expectedPageCount) {
        throw ConversationMirrorValidationException(
          'Page count $pageCount does not match snapshot page count '
          '$expectedPageCount.',
        );
      }
      if (pageIndex >= expectedPageCount) {
        throw ConversationMirrorValidationException(
          'Page index $pageIndex is outside page count $expectedPageCount.',
        );
      }
      for (final entry in prepared) {
        if (entry.input.ordinal >= expectedEntryCount) {
          throw ConversationMirrorValidationException(
            'Entry ${entry.input.entryId} has ordinal '
            '${entry.input.ordinal}, outside entry count $expectedEntryCount.',
          );
        }
      }

      final existingPage = await txn.query(
        ConversationMirrorDatabase.stagingPagesTable,
        columns: ['page_digest'],
        where: '$_keyWhere AND generation = ? AND page_index = ?',
        whereArgs: [..._keyArgs(key), generation, pageIndex],
        limit: 1,
      );
      if (existingPage.isNotEmpty) {
        if (existingPage.single['page_digest'] == pageDigest) return;
        throw ConversationMirrorValidationException(
          'Page $pageIndex was already stored with different content.',
        );
      }

      // The primary key and ordinal index already enforce generation-wide
      // uniqueness. Query only the at-most-100 candidates from this page so
      // appending page N does not rescan all entries from pages 0...N-1.
      final entryIdPlaceholders = List.filled(prepared.length, '?').join(', ');
      final ordinalPlaceholders = List.filled(prepared.length, '?').join(', ');
      final existingEntries = await txn.query(
        ConversationMirrorDatabase.entriesTable,
        columns: ['entry_id', 'ordinal'],
        where:
            '$_keyWhere AND generation = ? AND '
            '(entry_id IN ($entryIdPlaceholders) OR '
            'ordinal IN ($ordinalPlaceholders))',
        whereArgs: [
          ..._keyArgs(key),
          generation,
          ...prepared.map((entry) => entry.input.entryId),
          ...prepared.map((entry) => entry.input.ordinal),
        ],
      );
      final existingIds = {
        for (final row in existingEntries) row['entry_id'] as String,
      };
      final existingOrdinals = {
        for (final row in existingEntries) row['ordinal'] as int,
      };
      for (final entry in prepared) {
        if (existingIds.contains(entry.input.entryId)) {
          throw ConversationMirrorValidationException(
            'Entry ${entry.input.entryId} occurs in more than one page.',
          );
        }
        if (existingOrdinals.contains(entry.input.ordinal)) {
          throw ConversationMirrorValidationException(
            'Ordinal ${entry.input.ordinal} occurs in more than one page.',
          );
        }
      }

      final actualEntryCount = staging['actual_entry_count'] as int;
      final actualBytes = staging['actual_bytes'] as int;
      final nextEntryCount = actualEntryCount + prepared.length;
      final nextBytes = actualBytes + pageBytes;
      if (nextEntryCount > expectedEntryCount ||
          nextEntryCount > limits.maxEntriesPerGeneration) {
        throw ConversationMirrorValidationException(
          'Snapshot entry total exceeds its declared or configured limit.',
        );
      }
      if (nextBytes > (staging['expected_bytes'] as int) ||
          nextBytes > limits.maxTotalBytes) {
        throw ConversationMirrorValidationException(
          'Snapshot byte total exceeds its declared or configured limit.',
        );
      }
      final currentDatabaseBytes = await _databasePayloadBytes(txn);
      if (currentDatabaseBytes + pageBytes > limits.maxDatabaseBytes) {
        throw ConversationMirrorValidationException(
          'Snapshot page would exceed the ${limits.maxDatabaseBytes}-byte '
          'conversation mirror database limit.',
        );
      }

      final batch = txn.batch();
      for (final entry in prepared) {
        batch.insert(ConversationMirrorDatabase.entriesTable, {
          ..._keyColumns(key),
          'generation': generation,
          'entry_id': entry.input.entryId,
          'ordinal': entry.input.ordinal,
          'content_hash': entry.input.contentHash,
          'message_json': entry.messageJson,
          'entry_bytes': entry.bytes,
        });
      }
      await batch.commit(noResult: true);
      await txn.insert(ConversationMirrorDatabase.stagingPagesTable, {
        ..._keyColumns(key),
        'generation': generation,
        'page_index': pageIndex,
        'page_digest': pageDigest,
        'entry_count': prepared.length,
        'bytes': pageBytes,
      });
      await txn.update(
        ConversationMirrorDatabase.stagingTable,
        {'actual_entry_count': nextEntryCount, 'actual_bytes': nextBytes},
        where: '$_keyWhere AND generation = ?',
        whereArgs: [..._keyArgs(key), generation],
      );
    });
  }

  Future<ConversationMirrorMetadata> completeShadowGeneration({
    required ConversationMirrorKey key,
    required String generation,
    required String revision,
    required int entryCount,
    DateTime? lastSyncedAt,
  }) async {
    _validateKey(key);
    _validateGeneration(generation);
    _validateRevision(revision);
    if (entryCount < 0) {
      throw const ConversationMirrorValidationException(
        'Entry count must be non-negative.',
      );
    }

    final db = await _database.database;
    ConversationMirrorSnapshotConflictException? conflict;
    final completed = await db.transaction<ConversationMirrorMetadata?>((
      txn,
    ) async {
      final staging = await _queryStaging(txn, key, generation);
      if (staging == null) {
        final active = await _queryMetadata(txn, key);
        if (active?['active_generation'] == generation &&
            active?['revision'] == revision &&
            active?['entry_count'] == entryCount) {
          return _metadataFromRow(active!);
        }
        throw const ConversationMirrorValidationException(
          'No matching shadow generation is in progress.',
        );
      }
      final targetRevision = staging['target_revision'] as String;
      final baseActiveGeneration = staging['base_active_generation'] as String?;
      final baseRevision = staging['base_revision'] as String?;
      final expectedEntryCount = staging['expected_entry_count'] as int;
      final expectedPageCount = staging['expected_page_count'] as int;
      final expectedBytes = staging['expected_bytes'] as int;
      final actualEntryCount = staging['actual_entry_count'] as int;
      final actualBytes = staging['actual_bytes'] as int;
      if (revision != targetRevision) {
        throw ConversationMirrorValidationException(
          'Completion revision $revision does not match snapshot revision '
          '$targetRevision.',
        );
      }

      final current = await _queryMetadata(txn, key);
      final actualActiveGeneration = current?['active_generation'] as String?;
      final actualRevision = current?['revision'] as String?;
      if (current == null ||
          actualActiveGeneration != baseActiveGeneration ||
          actualRevision != baseRevision) {
        conflict = ConversationMirrorSnapshotConflictException(
          expectedActiveGeneration: baseActiveGeneration,
          expectedRevision: baseRevision,
          actualActiveGeneration: actualActiveGeneration,
          actualRevision: actualRevision,
        );
        await _abortShadowInTransaction(
          txn,
          key,
          generation: generation,
          rejectActiveGeneration: false,
        );
        return null;
      }
      if (entryCount != expectedEntryCount ||
          actualEntryCount != expectedEntryCount) {
        throw ConversationMirrorValidationException(
          'Snapshot entry count is incomplete: expected $expectedEntryCount, '
          'stored $actualEntryCount, completed as $entryCount.',
        );
      }
      if (actualBytes != expectedBytes) {
        throw ConversationMirrorValidationException(
          'Snapshot byte count is incomplete: expected $expectedBytes, '
          'stored $actualBytes.',
        );
      }

      final pages = await txn.query(
        ConversationMirrorDatabase.stagingPagesTable,
        columns: ['page_index'],
        where: '$_keyWhere AND generation = ?',
        whereArgs: [..._keyArgs(key), generation],
        orderBy: 'page_index ASC',
      );
      if (pages.length != expectedPageCount) {
        throw ConversationMirrorValidationException(
          'Snapshot page count is incomplete: expected $expectedPageCount, '
          'stored ${pages.length}.',
        );
      }
      for (var index = 0; index < pages.length; index++) {
        if (pages[index]['page_index'] != index) {
          throw ConversationMirrorValidationException(
            'Snapshot is missing page $index.',
          );
        }
      }

      final syncedAt = (lastSyncedAt ?? DateTime.now()).toUtc();
      final updated = await txn.update(
        ConversationMirrorDatabase.metadataTable,
        {
          'active_generation': generation,
          'revision': revision,
          'entry_count': actualEntryCount,
          'bytes': actualBytes,
          'last_synced_at': syncedAt.toIso8601String(),
          'error': null,
        },
        where: _keyWhere,
        whereArgs: _keyArgs(key),
      );
      if (updated != 1) {
        throw const ConversationMirrorCorruptionException(
          'Snapshot metadata disappeared before completion.',
        );
      }

      // The metadata switch and old-generation cleanup share this transaction.
      // A crash before commit therefore leaves the prior generation active.
      await txn.delete(
        ConversationMirrorDatabase.entriesTable,
        where: '$_keyWhere AND generation != ?',
        whereArgs: [..._keyArgs(key), generation],
      );
      await txn.delete(
        ConversationMirrorDatabase.stagingTable,
        where: _keyWhere,
        whereArgs: _keyArgs(key),
      );

      final row = await _queryMetadata(txn, key);
      if (row == null) {
        throw const ConversationMirrorCorruptionException(
          'Snapshot metadata disappeared after completion.',
        );
      }
      return _metadataFromRow(row);
    });
    if (conflict case final snapshotConflict?) throw snapshotConflict;
    return completed!;
  }

  /// Aborts one (or the current) shadow transfer without deleting the active
  /// local copy. Calls are serialized by the same SQLite transaction queue as
  /// snapshot pages, patches, activation, and local-copy deletion.
  Future<bool> abortShadowGeneration(
    ConversationMirrorKey key, {
    String? generation,
  }) async {
    _validateKey(key);
    if (generation != null) _validateGeneration(generation);
    final db = await _database.database;
    return db.transaction((txn) async {
      return _abortShadowInTransaction(
        txn,
        key,
        generation: generation,
        rejectActiveGeneration: true,
      );
    });
  }

  Future<ConversationMirrorPatchResult> applyPatch({
    required ConversationMirrorKey key,
    required String baseRevision,
    required String revision,
    List<ConversationMirrorEntryInput> upserts = const [],
    List<String> deletes = const [],
    DateTime? lastSyncedAt,
  }) async {
    _validateKey(key);
    _validateRevision(baseRevision);
    _validateRevision(revision);
    final prepared = _prepareEntries(upserts);
    _validateDistinctInputs(prepared);
    final upsertBytes = prepared.fold<int>(
      0,
      (sum, entry) => sum + entry.bytes,
    );
    if (upsertBytes > limits.maxPageBytes) {
      throw ConversationMirrorValidationException(
        'Patch upserts are $upsertBytes bytes; limit is '
        '${limits.maxPageBytes}.',
      );
    }
    final deleteIds = <String>{};
    for (final entryId in deletes) {
      _validateEntryId(entryId);
      if (!deleteIds.add(entryId)) {
        throw ConversationMirrorValidationException(
          'Patch deletes entry $entryId more than once.',
        );
      }
    }
    final upsertIds = prepared.map((entry) => entry.input.entryId).toSet();
    final overlap = deleteIds.intersection(upsertIds);
    if (overlap.isNotEmpty) {
      throw ConversationMirrorValidationException(
        'Patch both deletes and upserts entry ${overlap.first}.',
      );
    }

    final db = await _database.database;
    return db.transaction((txn) async {
      final row = await _queryMetadata(txn, key);
      final activeGeneration = row?['active_generation'] as String?;
      final actualRevision = row?['revision'] as String?;
      if (row == null || activeGeneration == null) {
        return ConversationMirrorPatchResult(
          outcome: ConversationMirrorPatchOutcome.noActiveGeneration,
          baseRevision: baseRevision,
          actualRevision: actualRevision,
          revision: null,
        );
      }
      if (actualRevision != baseRevision) {
        return ConversationMirrorPatchResult(
          outcome: ConversationMirrorPatchOutcome.revisionMismatch,
          baseRevision: baseRevision,
          actualRevision: actualRevision,
          revision: null,
        );
      }

      final existingRows = await txn.query(
        ConversationMirrorDatabase.entriesTable,
        columns: ['entry_id', 'ordinal', 'entry_bytes'],
        where: '$_keyWhere AND generation = ?',
        whereArgs: [..._keyArgs(key), activeGeneration],
      );
      final nextById = <String, _ProjectedEntry>{
        for (final existing in existingRows)
          existing['entry_id'] as String: _ProjectedEntry(
            ordinal: existing['ordinal'] as int,
            bytes: existing['entry_bytes'] as int,
          ),
      };
      for (final entryId in deleteIds) {
        nextById.remove(entryId);
      }
      for (final entry in prepared) {
        nextById[entry.input.entryId] = _ProjectedEntry(
          ordinal: entry.input.ordinal,
          bytes: entry.bytes,
        );
      }

      final ordinals = <int>{};
      var nextBytes = 0;
      for (final projected in nextById.values) {
        if (!ordinals.add(projected.ordinal)) {
          throw ConversationMirrorValidationException(
            'Patch produces duplicate ordinal ${projected.ordinal}.',
          );
        }
        nextBytes += projected.bytes;
      }
      final nextEntryCount = nextById.length;
      if (nextEntryCount > limits.maxEntriesPerGeneration) {
        throw ConversationMirrorValidationException(
          'Patch produces $nextEntryCount entries; limit is '
          '${limits.maxEntriesPerGeneration}.',
        );
      }
      if (nextBytes > limits.maxTotalBytes) {
        throw ConversationMirrorValidationException(
          'Patch produces $nextBytes bytes; limit is '
          '${limits.maxTotalBytes}.',
        );
      }
      final activeBytes = existingRows.fold<int>(
        0,
        (sum, row) => sum + (row['entry_bytes'] as int),
      );
      final currentDatabaseBytes = await _databasePayloadBytes(txn);
      final projectedDatabaseBytes =
          currentDatabaseBytes - activeBytes + nextBytes;
      if (projectedDatabaseBytes > limits.maxDatabaseBytes) {
        throw ConversationMirrorValidationException(
          'Patch would exceed the ${limits.maxDatabaseBytes}-byte '
          'conversation mirror database limit.',
        );
      }
      for (final ordinal in ordinals) {
        if (ordinal < 0 || ordinal >= nextEntryCount) {
          throw ConversationMirrorValidationException(
            'Patch produces non-contiguous ordinal $ordinal for '
            '$nextEntryCount entries.',
          );
        }
      }

      for (final entryId in {...deleteIds, ...upsertIds}) {
        await txn.delete(
          ConversationMirrorDatabase.entriesTable,
          where: '$_keyWhere AND generation = ? AND entry_id = ?',
          whereArgs: [..._keyArgs(key), activeGeneration, entryId],
        );
      }
      for (final entry in prepared) {
        await txn.insert(ConversationMirrorDatabase.entriesTable, {
          ..._keyColumns(key),
          'generation': activeGeneration,
          'entry_id': entry.input.entryId,
          'ordinal': entry.input.ordinal,
          'content_hash': entry.input.contentHash,
          'message_json': entry.messageJson,
          'entry_bytes': entry.bytes,
        });
      }

      final syncedAt = (lastSyncedAt ?? DateTime.now()).toUtc();
      await txn.update(
        ConversationMirrorDatabase.metadataTable,
        {
          'revision': revision,
          'entry_count': nextEntryCount,
          'bytes': nextBytes,
          'last_synced_at': syncedAt.toIso8601String(),
          'error': null,
        },
        where: _keyWhere,
        whereArgs: _keyArgs(key),
      );
      return ConversationMirrorPatchResult(
        outcome: ConversationMirrorPatchOutcome.applied,
        baseRevision: baseRevision,
        actualRevision: baseRevision,
        revision: revision,
      );
    });
  }

  Future<ConversationMirrorMetadata?> readMetadata(
    ConversationMirrorKey key,
  ) async {
    _validateKey(key);
    final row = await _queryMetadata(await _database.database, key);
    return row == null ? null : _metadataFromRow(row);
  }

  Future<List<ConversationMirrorEntry>> readEntries(
    ConversationMirrorKey key, {
    int offset = 0,
    int? limit,
  }) async {
    _validateKey(key);
    if (offset < 0 || (limit != null && limit <= 0)) {
      throw const ConversationMirrorValidationException(
        'Entry offset must be non-negative and limit must be positive.',
      );
    }
    final db = await _database.database;
    return db.transaction((txn) async {
      final metadata = await _queryMetadata(txn, key);
      final generation = metadata?['active_generation'] as String?;
      if (generation == null) return const <ConversationMirrorEntry>[];
      await readTransactionHook?.call(generation);

      final rows = await txn.query(
        ConversationMirrorDatabase.entriesTable,
        where: '$_keyWhere AND generation = ?',
        whereArgs: [..._keyArgs(key), generation],
        orderBy: 'ordinal ASC',
        limit: limit ?? (offset > 0 ? -1 : null),
        offset: offset > 0 ? offset : null,
      );
      for (var index = 0; index < rows.length; index++) {
        final expectedOrdinal = offset + index;
        if (rows[index]['ordinal'] != expectedOrdinal) {
          throw ConversationMirrorCorruptionException(
            'Stored conversation has a missing or duplicate ordinal at '
            '$expectedOrdinal.',
          );
        }
      }
      if (offset == 0 && limit == null) {
        final expectedCount = metadata?['entry_count'] as int? ?? 0;
        final expectedBytes = metadata?['bytes'] as int? ?? 0;
        final actualBytes = rows.fold<int>(
          0,
          (total, row) => total + (row['entry_bytes'] as int),
        );
        if (rows.length != expectedCount || actualBytes != expectedBytes) {
          throw ConversationMirrorCorruptionException(
            'Stored conversation metadata does not match its active entries.',
          );
        }
      }
      return rows.map(_entryFromRow).toList(growable: false);
    });
  }

  /// Reads only user-input envelopes from the active generation.
  ///
  /// SQLite performs the JSON type filter so large assistant/tool payloads do
  /// not cross the Dart boundary when the message-history picker only needs a
  /// lightweight prompt index. The fallback keeps custom/older SQLite test
  /// engines functional if JSON1 is unavailable.
  Future<List<ConversationMirrorEntry>> readUserEntries(
    ConversationMirrorKey key,
  ) async {
    _validateKey(key);
    final db = await _database.database;
    return db.transaction((txn) async {
      final metadata = await _queryMetadata(txn, key);
      final generation = metadata?['active_generation'] as String?;
      if (generation == null) return const <ConversationMirrorEntry>[];
      await readTransactionHook?.call(generation);

      final args = [..._keyArgs(key), generation];
      late final List<Map<String, Object?>> rows;
      try {
        rows = await txn.rawQuery('''
          SELECT * FROM ${ConversationMirrorDatabase.entriesTable}
          WHERE $_keyWhere
            AND generation = ?
            AND json_extract(message_json, '\$.type') = 'user_input'
          ORDER BY ordinal ASC
          ''', args);
      } on DatabaseException {
        final candidates = await txn.query(
          ConversationMirrorDatabase.entriesTable,
          where: '$_keyWhere AND generation = ?',
          whereArgs: args,
          orderBy: 'ordinal ASC',
        );
        rows = candidates
            .where((row) {
              try {
                final decoded = jsonDecode(row['message_json'] as String);
                return decoded is Map && decoded['type'] == 'user_input';
              } catch (_) {
                return false;
              }
            })
            .toList(growable: false);
      }
      return rows.map(_entryFromRow).toList(growable: false);
    });
  }

  Future<List<ConversationMirrorMetadata>> listAutoSync() async {
    final rows = await (await _database.database).query(
      ConversationMirrorDatabase.metadataTable,
      where: 'auto_sync = 1',
      orderBy: 'last_synced_at DESC, provider_session_id ASC',
    );
    return rows.map(_metadataFromRow).toList(growable: false);
  }

  /// Lists every complete phone copy, including copies whose automatic watch
  /// has been paused. The Home resident section filters [autoSync] itself,
  /// while keeping paused-copy badges available after an app restart.
  Future<List<ConversationMirrorMetadata>> listLocalCopies() async {
    final rows = await (await _database.database).query(
      ConversationMirrorDatabase.metadataTable,
      where: 'active_generation IS NOT NULL',
      orderBy: 'last_synced_at DESC, provider_session_id ASC',
    );
    return rows.map(_metadataFromRow).toList(growable: false);
  }

  /// Finds an unambiguous offline copy before the current Bridge identity is
  /// known. This deliberately does not choose between copies from two Bridge
  /// installations, even if only one happens to match [projectPath].
  Future<ConversationMirrorMetadata?> findUniqueLocalCopy(
    String provider,
    String providerSessionId, {
    String? projectPath,
  }) async {
    _validateProvider(provider);
    _validateIdentifier(
      providerSessionId,
      'Provider session ID',
      maxLength: 512,
    );
    if (projectPath != null) _validateProjectPath(projectPath);
    final rows = await (await _database.database).query(
      ConversationMirrorDatabase.metadataTable,
      where:
          'provider = ? AND provider_session_id = ? '
          'AND active_generation IS NOT NULL',
      whereArgs: [provider, providerSessionId],
      limit: 2,
    );
    if (rows.length != 1) return null;
    final metadata = _metadataFromRow(rows.single);
    if (projectPath != null &&
        projectPath.isNotEmpty &&
        metadata.projectPath != projectPath) {
      return null;
    }
    return metadata;
  }

  Future<void> setAutoSync(
    ConversationMirrorKey key,
    bool autoSync, {
    String? projectPath,
  }) async {
    _validateKey(key);
    if (projectPath != null) _validateProjectPath(projectPath);
    final db = await _database.database;
    await db.transaction((txn) async {
      await _ensureMetadata(txn, key, projectPath: projectPath);
      await txn.update(
        ConversationMirrorDatabase.metadataTable,
        {'auto_sync': autoSync ? 1 : 0, 'project_path': ?projectPath},
        where: _keyWhere,
        whereArgs: _keyArgs(key),
      );
    });
  }

  Future<void> setSyncError(
    ConversationMirrorKey key,
    String? error, {
    String? projectPath,
  }) async {
    _validateKey(key);
    if (error != null && error.length > 4096) {
      throw const ConversationMirrorValidationException(
        'Sync error is longer than 4096 characters.',
      );
    }
    if (projectPath != null) _validateProjectPath(projectPath);
    final db = await _database.database;
    await db.transaction((txn) async {
      await _ensureMetadata(txn, key, projectPath: projectPath);
      await txn.update(
        ConversationMirrorDatabase.metadataTable,
        {'error': error, 'project_path': ?projectPath},
        where: _keyWhere,
        whereArgs: _keyArgs(key),
      );
    });
  }

  Future<void> deleteLocalCopy(ConversationMirrorKey key) async {
    _validateKey(key);
    final db = await _database.database;
    final deleted = await db.delete(
      ConversationMirrorDatabase.metadataTable,
      where: _keyWhere,
      whereArgs: _keyArgs(key),
    );
    if (deleted > 0) await db.execute('PRAGMA incremental_vacuum');
  }

  Future<bool> _abortShadowInTransaction(
    DatabaseExecutor db,
    ConversationMirrorKey key, {
    required String? generation,
    required bool rejectActiveGeneration,
  }) async {
    final metadata = await _queryMetadata(db, key);
    final activeGeneration = metadata?['active_generation'] as String?;
    final generations = <String>{};
    if (generation != null) {
      generations.add(generation);
    } else {
      final rows = await db.query(
        ConversationMirrorDatabase.stagingTable,
        columns: ['generation'],
        where: _keyWhere,
        whereArgs: _keyArgs(key),
      );
      generations.addAll(rows.map((row) => row['generation'] as String));
    }

    var changed = false;
    for (final shadowGeneration in generations) {
      if (shadowGeneration == activeGeneration) {
        if (rejectActiveGeneration) {
          throw const ConversationMirrorValidationException(
            'The active generation cannot be aborted as a shadow transfer.',
          );
        }
        continue;
      }
      final deletedStaging = await db.delete(
        ConversationMirrorDatabase.stagingTable,
        where: '$_keyWhere AND generation = ?',
        whereArgs: [..._keyArgs(key), shadowGeneration],
      );
      final deletedEntries = await db.delete(
        ConversationMirrorDatabase.entriesTable,
        where: '$_keyWhere AND generation = ?',
        whereArgs: [..._keyArgs(key), shadowGeneration],
      );
      changed = changed || deletedStaging > 0 || deletedEntries > 0;
    }
    return changed;
  }

  Future<int> _databasePayloadBytes(DatabaseExecutor db) async {
    final rows = await db.rawQuery(
      'SELECT '
      'COALESCE(('
      '  SELECT SUM(bytes) '
      '  FROM ${ConversationMirrorDatabase.metadataTable}'
      '), 0) + '
      'COALESCE(('
      '  SELECT SUM(actual_bytes) '
      '  FROM ${ConversationMirrorDatabase.stagingTable}'
      '), 0) AS total_bytes',
    );
    final value = rows.single['total_bytes'];
    if (value is int) return value;
    if (value is num) return value.toInt();
    throw const ConversationMirrorCorruptionException(
      'Conversation mirror database byte total is invalid.',
    );
  }

  Future<void> _ensureMetadata(
    DatabaseExecutor db,
    ConversationMirrorKey key, {
    String? projectPath,
  }) async {
    await db.insert(
      ConversationMirrorDatabase.metadataTable,
      {
        ..._keyColumns(key),
        'active_generation': null,
        'revision': null,
        'entry_count': 0,
        'bytes': 0,
        'auto_sync': 0,
        'project_path': projectPath ?? '',
        'last_synced_at': null,
        'error': null,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<Map<String, Object?>?> _queryMetadata(
    DatabaseExecutor db,
    ConversationMirrorKey key,
  ) async {
    final rows = await db.query(
      ConversationMirrorDatabase.metadataTable,
      where: _keyWhere,
      whereArgs: _keyArgs(key),
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<Map<String, Object?>?> _queryStaging(
    DatabaseExecutor db,
    ConversationMirrorKey key,
    String generation,
  ) async {
    final rows = await db.query(
      ConversationMirrorDatabase.stagingTable,
      where: '$_keyWhere AND generation = ?',
      whereArgs: [..._keyArgs(key), generation],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  static Map<String, Object?> _keyColumns(ConversationMirrorKey key) => {
    'bridge_instance_id': key.bridgeInstanceId,
    'provider': key.provider,
    'provider_session_id': key.providerSessionId,
  };

  static List<Object?> _keyArgs(ConversationMirrorKey key) => [
    key.bridgeInstanceId,
    key.provider,
    key.providerSessionId,
  ];

  ConversationMirrorMetadata _metadataFromRow(Map<String, Object?> row) {
    final rawLastSyncedAt = row['last_synced_at'] as String?;
    return ConversationMirrorMetadata(
      key: ConversationMirrorKey(
        bridgeInstanceId: row['bridge_instance_id'] as String,
        provider: row['provider'] as String,
        providerSessionId: row['provider_session_id'] as String,
      ),
      activeGeneration: row['active_generation'] as String?,
      revision: row['revision'] as String?,
      entryCount: row['entry_count'] as int,
      bytes: row['bytes'] as int,
      autoSync: row['auto_sync'] == 1,
      projectPath: row['project_path'] as String,
      lastSyncedAt: rawLastSyncedAt == null
          ? null
          : DateTime.tryParse(rawLastSyncedAt)?.toUtc(),
      error: row['error'] as String?,
    );
  }

  ConversationMirrorEntry _entryFromRow(Map<String, Object?> row) {
    final messageJson = row['message_json'] as String;
    final expectedBytes = row['entry_bytes'] as int;
    final actualBytes = utf8.encode(messageJson).length;
    if (actualBytes != expectedBytes) {
      throw ConversationMirrorCorruptionException(
        'Stored entry ${row['entry_id']} has an invalid byte count.',
      );
    }
    final message = _decodeMessageJson(messageJson, row['entry_id'] as String);
    final contentHash = row['content_hash'] as String;
    if (_contentHash(messageJson) != contentHash) {
      throw ConversationMirrorCorruptionException(
        'Stored entry ${row['entry_id']} has an invalid content hash.',
      );
    }
    return ConversationMirrorEntry(
      generation: row['generation'] as String,
      entryId: row['entry_id'] as String,
      ordinal: row['ordinal'] as int,
      contentHash: contentHash,
      message: message,
    );
  }

  List<_PreparedEntry> _prepareEntries(
    List<ConversationMirrorEntryInput> entries, {
    int? maxEntryBytes,
  }) => entries
      .map(
        (entry) => _prepareEntry(
          entry,
          maxEntryBytes: maxEntryBytes ?? limits.maxEntryBytes,
        ),
      )
      .toList(growable: false);

  _PreparedEntry _prepareEntry(
    ConversationMirrorEntryInput input, {
    required int maxEntryBytes,
  }) {
    _validateEntryId(input.entryId);
    if (input.ordinal < 0) {
      throw ConversationMirrorValidationException(
        'Entry ${input.entryId} has a negative ordinal.',
      );
    }
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(input.contentHash)) {
      throw ConversationMirrorValidationException(
        'Entry ${input.entryId} has an invalid SHA-256 content hash.',
      );
    }
    final messageJson = _encodeMessage(input.message, input.entryId);
    final bytes = utf8.encode(messageJson).length;
    if (bytes > maxEntryBytes) {
      throw ConversationMirrorValidationException(
        'Entry ${input.entryId} is $bytes bytes; limit is '
        '$maxEntryBytes.',
      );
    }
    final actualHash = _contentHash(messageJson);
    if (actualHash != input.contentHash) {
      throw ConversationMirrorValidationException(
        'Entry ${input.entryId} content hash does not match its message.',
      );
    }
    return _PreparedEntry(input: input, messageJson: messageJson, bytes: bytes);
  }

  static void _validateDistinctInputs(List<_PreparedEntry> entries) {
    final ids = <String>{};
    final ordinals = <int>{};
    for (final entry in entries) {
      if (!ids.add(entry.input.entryId)) {
        throw ConversationMirrorValidationException(
          'Entry ${entry.input.entryId} occurs more than once.',
        );
      }
      if (!ordinals.add(entry.input.ordinal)) {
        throw ConversationMirrorValidationException(
          'Ordinal ${entry.input.ordinal} occurs more than once.',
        );
      }
    }
  }

  static String _encodeMessage(Map<String, dynamic> message, String entryId) {
    final type = message['type'];
    if (type is! String || type.trim().isEmpty) {
      throw ConversationMirrorValidationException(
        'Entry $entryId is not a valid raw message envelope.',
      );
    }
    try {
      final encoded = jsonEncode(message);
      _decodeMessageJson(encoded, entryId);
      return encoded;
    } on ConversationMirrorStorageException {
      rethrow;
    } catch (error) {
      throw ConversationMirrorValidationException(
        'Entry $entryId is not valid JSON: $error',
      );
    }
  }

  static Map<String, dynamic> _decodeMessageJson(
    String messageJson,
    String entryId,
  ) {
    try {
      final decoded = jsonDecode(messageJson);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('message must be a JSON object');
      }
      final type = decoded['type'];
      if (type is! String || type.trim().isEmpty) {
        throw const FormatException('message type is missing');
      }
      return decoded;
    } catch (error) {
      throw ConversationMirrorCorruptionException(
        'Stored entry $entryId is not a valid raw message envelope: $error',
      );
    }
  }

  static String _contentHash(String messageJson) =>
      sha256.convert(utf8.encode(messageJson)).toString();

  static String _pageDigest(List<_PreparedEntry> entries) {
    final encoded = jsonEncode([
      for (final entry in entries)
        {
          'entryId': entry.input.entryId,
          'ordinal': entry.input.ordinal,
          'contentHash': entry.input.contentHash,
          'messageJson': entry.messageJson,
        },
    ]);
    return sha256.convert(utf8.encode(encoded)).toString();
  }

  void _validateSnapshotShape({
    required int entryCount,
    required int pageCount,
    required int totalBytes,
  }) {
    if (entryCount < 0 || pageCount < 0 || totalBytes < 0) {
      throw const ConversationMirrorValidationException(
        'Snapshot counts and bytes must be non-negative.',
      );
    }
    if (entryCount > limits.maxEntriesPerGeneration) {
      throw ConversationMirrorValidationException(
        'Snapshot contains $entryCount entries; limit is '
        '${limits.maxEntriesPerGeneration}.',
      );
    }
    if (totalBytes > limits.maxTotalBytes) {
      throw ConversationMirrorValidationException(
        'Snapshot is $totalBytes bytes; limit is ${limits.maxTotalBytes}.',
      );
    }
    if (entryCount == 0 && pageCount != 0) {
      throw const ConversationMirrorValidationException(
        'An empty snapshot must have zero pages.',
      );
    }
    if (entryCount > 0) {
      final minimumPages =
          (entryCount + limits.maxEntriesPerPage - 1) ~/
          limits.maxEntriesPerPage;
      if (pageCount < minimumPages || pageCount > entryCount) {
        throw ConversationMirrorValidationException(
          'Page count $pageCount cannot contain $entryCount entries with a '
          '${limits.maxEntriesPerPage}-entry page limit.',
        );
      }
    }
  }

  static void _validateKey(ConversationMirrorKey key) {
    _validateIdentifier(
      key.bridgeInstanceId,
      'Bridge instance ID',
      maxLength: 256,
    );
    _validateIdentifier(
      key.providerSessionId,
      'Provider session ID',
      maxLength: 512,
    );
    _validateProvider(key.provider);
  }

  static void _validateProvider(String provider) {
    if (provider != 'codex' && provider != 'claude') {
      throw ConversationMirrorValidationException(
        'Unsupported provider: $provider.',
      );
    }
  }

  static void _validateGeneration(String generation) =>
      _validateIdentifier(generation, 'Generation', maxLength: 256);

  static void _validateEntryId(String entryId) =>
      _validateIdentifier(entryId, 'Entry ID', maxLength: 512);

  static void _validateProjectPath(String projectPath) {
    if (projectPath.length > 4096) {
      throw const ConversationMirrorValidationException(
        'Project path is longer than 4096 characters.',
      );
    }
  }

  static void _validateRevision(String revision) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(revision)) {
      throw const ConversationMirrorValidationException(
        'Revision must be a lowercase SHA-256 digest.',
      );
    }
  }

  static void _validateIdentifier(
    String value,
    String label, {
    required int maxLength,
  }) {
    if (value.trim().isEmpty || value.length > maxLength) {
      throw ConversationMirrorValidationException(
        '$label must contain 1 to $maxLength characters.',
      );
    }
  }
}

class _PreparedEntry {
  const _PreparedEntry({
    required this.input,
    required this.messageJson,
    required this.bytes,
  });

  final ConversationMirrorEntryInput input;
  final String messageJson;
  final int bytes;
}

class _ProjectedEntry {
  const _ProjectedEntry({required this.ordinal, required this.bytes});

  final int ordinal;
  final int bytes;
}
