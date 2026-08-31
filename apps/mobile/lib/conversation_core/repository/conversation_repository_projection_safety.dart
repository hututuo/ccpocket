part of 'conversation_repository.dart';

const Set<RepositoryFailureCode> _terminalProjectionRejectionCodes =
    <RepositoryFailureCode>{
      RepositoryFailureCode.staleEpoch,
      RepositoryFailureCode.staleGeneration,
      RepositoryFailureCode.staleRevision,
      RepositoryFailureCode.identityConflict,
    };

class _VerifiedProjectionInbox {
  const _VerifiedProjectionInbox({
    required this.projection,
    required this.payloadJson,
    required this.projectionDigest,
    required this.state,
  });

  final RuntimeProjectionEnvelope projection;
  final String payloadJson;
  final String projectionDigest;
  final String state;
}

class _VerifiedProjectionIdentity {
  const _VerifiedProjectionIdentity({
    required this.projectionId,
    required this.connectionEpoch,
    required this.sourceEpoch,
    required this.providerInstanceEpoch,
    required this.runtimeAuthorityGeneration,
    required this.sourceRevision,
    required this.projectionDigest,
    required this.disposition,
  });

  final String projectionId;
  final String connectionEpoch;
  final String sourceEpoch;
  final String providerInstanceEpoch;
  final int runtimeAuthorityGeneration;
  final int sourceRevision;
  final String projectionDigest;
  final String disposition;
}

bool _projectionHeadIdentityMatches(
  Map<String, Object?> head,
  RuntimeProjectionEnvelope projection,
  String projectionDigest,
) =>
    head['projection_id'] == projection.projectionId &&
    head['projection_digest'] == projectionDigest &&
    head['connection_epoch'] == projection.fence.connectionEpoch &&
    head['source_epoch'] == projection.fence.sourceEpoch &&
    head['provider_instance_epoch'] == projection.fence.providerInstanceEpoch &&
    head['runtime_authority_generation'] ==
        projection.fence.runtimeAuthorityGeneration &&
    head['source_revision'] == projection.sourceRevision;

bool _projectionIdentityMatches(
  _VerifiedProjectionIdentity identity,
  RuntimeProjectionEnvelope projection,
  String projectionDigest,
) =>
    identity.projectionId == projection.projectionId &&
    identity.projectionDigest == projectionDigest &&
    identity.connectionEpoch == projection.fence.connectionEpoch &&
    identity.sourceEpoch == projection.fence.sourceEpoch &&
    identity.providerInstanceEpoch == projection.fence.providerInstanceEpoch &&
    identity.runtimeAuthorityGeneration ==
        projection.fence.runtimeAuthorityGeneration &&
    identity.sourceRevision == projection.sourceRevision;

Future<_VerifiedProjectionIdentity?> _readVerifiedProjectionIdentity(
  DatabaseExecutor db,
  ThreadKey key,
  String projectionId, {
  bool allowAbsent = false,
}) async {
  final rows = await db.query(
    'projection_identity',
    columns: const <String>[
      'projection_id',
      'connection_epoch',
      'source_epoch',
      'provider_instance_epoch',
      'runtime_authority_generation',
      'source_revision',
      'projection_digest',
      'disposition',
    ],
    where: '${_keyWhere()} AND projection_id = ?',
    whereArgs: <Object?>[..._keyArgs(key), projectionId],
    limit: 1,
  );
  if (rows.isEmpty) {
    if (allowAbsent) return null;
    throw const ConversationRepositoryException(
      RepositoryFailureCode.invalidDatabaseIdentity,
      'projection identity row is missing',
    );
  }
  final row = rows.single;
  final storedProjectionId = row['projection_id'];
  final connectionEpoch = row['connection_epoch'];
  final sourceEpoch = row['source_epoch'];
  final providerInstanceEpoch = row['provider_instance_epoch'];
  final runtimeAuthorityGeneration = row['runtime_authority_generation'];
  final sourceRevision = row['source_revision'];
  final projectionDigest = row['projection_digest'];
  final disposition = row['disposition'];
  if (storedProjectionId is! String ||
      storedProjectionId != projectionId ||
      connectionEpoch is! String ||
      sourceEpoch is! String ||
      providerInstanceEpoch is! String ||
      runtimeAuthorityGeneration is! int ||
      sourceRevision is! int ||
      projectionDigest is! String ||
      disposition is! String ||
      !const <String>{'pending', 'applied', 'stale'}.contains(disposition)) {
    throw const ConversationRepositoryException(
      RepositoryFailureCode.invalidDatabaseIdentity,
      'projection identity row has invalid stored values',
    );
  }
  return _VerifiedProjectionIdentity(
    projectionId: storedProjectionId,
    connectionEpoch: connectionEpoch,
    sourceEpoch: sourceEpoch,
    providerInstanceEpoch: providerInstanceEpoch,
    runtimeAuthorityGeneration: runtimeAuthorityGeneration,
    sourceRevision: sourceRevision,
    projectionDigest: projectionDigest,
    disposition: disposition,
  );
}

void _assertProjectionIdentityMatchesInbox(
  _VerifiedProjectionIdentity identity,
  _VerifiedProjectionInbox inbox,
) {
  if (!_projectionIdentityMatches(
        identity,
        inbox.projection,
        inbox.projectionDigest,
      ) ||
      identity.disposition != inbox.state) {
    throw const ConversationRepositoryException(
      RepositoryFailureCode.invalidDatabaseIdentity,
      'projection identity does not match its durable inbox',
    );
  }
}

Future<void> _transitionProjectionIdentity(
  Transaction txn,
  ThreadKey key,
  _VerifiedProjectionIdentity identity,
  String nextDisposition,
) async {
  final updated = await txn.update(
    'projection_identity',
    <String, Object?>{'disposition': nextDisposition},
    where:
        '${_keyWhere()} AND projection_id = ? AND disposition = ? AND connection_epoch = ? AND source_epoch = ? AND provider_instance_epoch = ? AND runtime_authority_generation = ? AND source_revision = ? AND projection_digest = ?',
    whereArgs: <Object?>[
      ..._keyArgs(key),
      identity.projectionId,
      'pending',
      identity.connectionEpoch,
      identity.sourceEpoch,
      identity.providerInstanceEpoch,
      identity.runtimeAuthorityGeneration,
      identity.sourceRevision,
      identity.projectionDigest,
    ],
  );
  if (updated != 1) {
    throw const ConversationRepositoryException(
      RepositoryFailureCode.invalidDatabaseIdentity,
      'projection identity changed during disposition transition',
    );
  }
}

Future<void> _assertPendingProjectionIdentityCompleteness(
  DatabaseExecutor db,
) async {
  final rows = await db.rawQuery('''
    SELECT 1
    FROM projection_identity AS identity_row
    LEFT JOIN projection_inbox AS inbox
      ON inbox.bridge_identity_id = identity_row.bridge_identity_id
      AND inbox.bridge_instance_id = identity_row.bridge_instance_id
      AND inbox.codex_source_id = identity_row.codex_source_id
      AND inbox.provider_thread_id = identity_row.provider_thread_id
      AND inbox.projection_id = identity_row.projection_id
    WHERE identity_row.disposition = 'pending'
      AND (
        inbox.projection_id IS NULL
        OR inbox.state <> 'pending'
        OR inbox.connection_epoch <> identity_row.connection_epoch
        OR inbox.source_epoch <> identity_row.source_epoch
        OR inbox.provider_instance_epoch <> identity_row.provider_instance_epoch
        OR inbox.runtime_authority_generation <> identity_row.runtime_authority_generation
        OR inbox.source_revision <> identity_row.source_revision
        OR inbox.projection_digest <> identity_row.projection_digest
      )
    LIMIT 1
  ''');
  if (rows.isNotEmpty) {
    throw const ConversationRepositoryException(
      RepositoryFailureCode.invalidDatabaseIdentity,
      'pending projection identity lacks one exact pending inbox',
    );
  }
}

Future<CommitReceipt> _commitRuntimeProjectionSafely(
  ConversationRepository repository,
  RuntimeProjectionEnvelope projection, {
  int? readLimit,
}) async {
  repository._requireDatabase();
  repository._requireContract();
  _validateRuntimeProjection(projection);
  final effectiveLimit = readLimit ?? repository.defaultWindowSize;
  _validateReadLimit(effectiveLimit);
  final artifact = repository._verifiedPreimage(
    repository._contractMapper.runtimeProjection(projection),
    'runtime projection',
  );
  final payload = _storageJson(
    _projectionStorageValue(projection),
    'projection inbox payload',
  );

  final admission = await _admitRuntimeProjectionSafely(
    repository,
    projection,
    projectionDigest: artifact.digest,
    payloadJson: payload,
  );

  // The fault remains deliberately after the durable admission transaction.
  // Recovery must be able to classify the exact pending row after a crash.
  if (!admission.wasDuplicate) {
    await repository.faultHook?.call(
      RepositoryFaultStage.afterInboxAdmission,
      projection.projectionId,
    );
  }
  if (admission.wasDuplicate && admission.wasAlreadyApplied) {
    if (!admission.shouldResumePublication) {
      final window = await _readWindow(
        repository,
        projection.key,
        limit: effectiveLimit,
        publicationEventId: null,
      );
      return CommitReceipt(
        envelopeId: projection.projectionId,
        wasDuplicate: true,
        wasPublished: false,
        window: window,
      );
    }
    final publication = await _publishPublicationOutbox(
      repository,
      projection.key,
      sourceEpoch: projection.fence.sourceEpoch,
      providerInstanceEpoch: projection.fence.providerInstanceEpoch,
      domain: 'projection',
      operationId: projection.projectionId,
      readLimit: effectiveLimit,
      requiredCurrentProjectionId: projection.projectionId,
    );
    final window = await _readWindow(
      repository,
      projection.key,
      limit: effectiveLimit,
      publicationEventId: publication.eventId,
    );
    return CommitReceipt(
      envelopeId: projection.projectionId,
      wasDuplicate: true,
      wasPublished: publication.wasPublished,
      window: window,
      publicationEventId: publication.eventId,
    );
  }

  late bool changed;
  try {
    changed = await repository._serialize(
      (db) => _applyProjectionInboxSafely(
        repository,
        db,
        projection.key,
        projection.projectionId,
      ),
    );
  } on ConversationRepositoryException catch (error) {
    if (_terminalProjectionRejectionCodes.contains(error.code)) {
      await repository._serialize((db) async {
        await _terminalizePendingProjection(
          repository,
          db,
          projection.key,
          projection.projectionId,
          expected: projection,
          requirePending: false,
        );
      });
    }
    rethrow;
  }

  final publication = await _publishPublicationOutbox(
    repository,
    projection.key,
    sourceEpoch: projection.fence.sourceEpoch,
    providerInstanceEpoch: projection.fence.providerInstanceEpoch,
    domain: 'projection',
    operationId: projection.projectionId,
    readLimit: effectiveLimit,
  );
  final window = await _readWindow(
    repository,
    projection.key,
    limit: effectiveLimit,
    publicationEventId: publication.eventId,
  );
  return CommitReceipt(
    envelopeId: projection.projectionId,
    wasDuplicate: !changed,
    wasPublished: publication.wasPublished,
    window: window,
    publicationEventId: publication.eventId,
  );
}

Future<_ProjectionAdmission> _admitRuntimeProjectionSafely(
  ConversationRepository repository,
  RuntimeProjectionEnvelope projection, {
  required String projectionDigest,
  required String payloadJson,
}) {
  return repository._serialize((db) async {
    await _prepareCapacity(db, repository, projection.key);
    return db.transaction((txn) async {
      await _assertWriterLease(txn, repository);
      final identity = await _readVerifiedProjectionIdentity(
        txn,
        projection.key,
        projection.projectionId,
        allowAbsent: true,
      );
      if (identity != null) {
        if (!_projectionIdentityMatches(
          identity,
          projection,
          projectionDigest,
        )) {
          throw const ConversationRepositoryException(
            RepositoryFailureCode.identityConflict,
            'projection identity was reused with another digest or fence',
          );
        }
        final existing = await _readVerifiedProjectionInbox(
          repository,
          txn,
          projection.key,
          projection.projectionId,
          allowAbsent: identity.disposition != 'pending',
        );
        if (existing != null) {
          _assertProjectionIdentityMatchesInbox(identity, existing);
          if (existing.payloadJson != payloadJson) {
            throw const ConversationRepositoryException(
              RepositoryFailureCode.identityConflict,
              'projection identity was reused with another payload',
            );
          }
        }
        final headRows = await txn.query(
          'projection_head',
          columns: const <String>[
            'connection_epoch',
            'source_epoch',
            'provider_instance_epoch',
            'runtime_authority_generation',
            'source_revision',
            'projection_id',
            'projection_digest',
          ],
          where: _keyWhere(),
          whereArgs: _keyArgs(projection.key),
          limit: 1,
        );
        final currentHead = headRows.isEmpty ? null : headRows.single;
        final identityIsCurrent =
            currentHead?['projection_id'] == projection.projectionId;
        if (identity.disposition == 'applied' && currentHead == null) {
          throw const ConversationRepositoryException(
            RepositoryFailureCode.invalidDatabaseIdentity,
            'applied projection identity has no current repository head',
          );
        }
        if (identityIsCurrent && identity.disposition != 'applied') {
          throw const ConversationRepositoryException(
            RepositoryFailureCode.invalidDatabaseIdentity,
            'current projection head is not backed by an applied identity',
          );
        }
        if (identityIsCurrent &&
            !_projectionHeadIdentityMatches(
              currentHead!,
              projection,
              projectionDigest,
            )) {
          throw const ConversationRepositoryException(
            RepositoryFailureCode.invalidDatabaseIdentity,
            'current projection head does not match its identity ledger',
          );
        }
        return _ProjectionAdmission(
          wasDuplicate: true,
          wasAlreadyApplied: identity.disposition != 'pending',
          shouldResumePublication:
              identity.disposition == 'applied' && identityIsCurrent,
        );
      }

      final orphanInbox = await _readVerifiedProjectionInbox(
        repository,
        txn,
        projection.key,
        projection.projectionId,
        allowAbsent: true,
      );
      if (orphanInbox != null) {
        throw const ConversationRepositoryException(
          RepositoryFailureCode.invalidDatabaseIdentity,
          'projection inbox exists without permanent identity evidence',
        );
      }
      final orphanHead = await txn.query(
        'projection_head',
        columns: const <String>['projection_id'],
        where: '${_keyWhere()} AND projection_id = ?',
        whereArgs: <Object?>[
          ..._keyArgs(projection.key),
          projection.projectionId,
        ],
        limit: 1,
      );
      if (orphanHead.isNotEmpty) {
        throw const ConversationRepositoryException(
          RepositoryFailureCode.invalidDatabaseIdentity,
          'projection head exists without permanent identity evidence',
        );
      }

      // This check is in the same writer transaction as admission.  A
      // canonical fence cannot advance between validation and inbox insert.
      await _validateProjectionAgainstCanonicalFence(txn, projection);
      await txn.insert('projection_identity', <String, Object?>{
        ..._keyColumns(projection.key),
        'projection_id': projection.projectionId,
        'connection_epoch': projection.fence.connectionEpoch,
        'source_epoch': projection.fence.sourceEpoch,
        'provider_instance_epoch': projection.fence.providerInstanceEpoch,
        'runtime_authority_generation':
            projection.fence.runtimeAuthorityGeneration,
        'source_revision': projection.sourceRevision,
        'projection_digest': projectionDigest,
        'disposition': 'pending',
      });
      await txn.insert('projection_inbox', <String, Object?>{
        ..._keyColumns(projection.key),
        'projection_id': projection.projectionId,
        'connection_epoch': projection.fence.connectionEpoch,
        'source_epoch': projection.fence.sourceEpoch,
        'provider_instance_epoch': projection.fence.providerInstanceEpoch,
        'runtime_authority_generation':
            projection.fence.runtimeAuthorityGeneration,
        'source_revision': projection.sourceRevision,
        'projection_digest': projectionDigest,
        'payload_json': payloadJson,
        'state': 'pending',
        'gc_eligible': 0,
        'admitted_at': DateTime.now().millisecondsSinceEpoch,
      });
      await _validateCapacity(txn, repository, projection.key);
      return const _ProjectionAdmission(
        wasDuplicate: false,
        wasAlreadyApplied: false,
        shouldResumePublication: false,
      );
    });
  });
}

Future<bool> _applyProjectionInboxSafely(
  ConversationRepository repository,
  Database db,
  ThreadKey key,
  String projectionId,
) async {
  await _prepareCapacity(db, repository, key);
  return db.transaction((txn) async {
    await _assertWriterLease(txn, repository);
    final verified = await _readVerifiedProjectionInbox(
      repository,
      txn,
      key,
      projectionId,
    );
    if (verified == null || verified.state != 'pending') return false;
    final projection = verified.projection;
    final identity = await _readVerifiedProjectionIdentity(
      txn,
      key,
      projectionId,
    );
    if (identity == null) {
      throw const ConversationRepositoryException(
        RepositoryFailureCode.invalidDatabaseIdentity,
        'pending projection identity is missing',
      );
    }
    _assertProjectionIdentityMatchesInbox(identity, verified);

    await _rejectRetiredEpochs(txn, projection.key.partition, projection.fence);
    // Recheck the complete canonical fence inside the apply transaction.  This
    // closes the admission/apply race and guarantees stale authority has no
    // visible projection or publication effect.
    await _validateProjectionAgainstCanonicalFence(txn, projection);
    await _ensureProjectionThreadState(txn, projection);

    final headRows = await txn.query(
      'projection_head',
      where: _keyWhere(),
      whereArgs: _keyArgs(key),
      limit: 1,
    );
    final previousHead = headRows.isEmpty ? null : headRows.single;
    if (previousHead != null) {
      if (previousHead['projection_id'] == projection.projectionId &&
          !_projectionHeadIdentityMatches(
            previousHead,
            projection,
            verified.projectionDigest,
          )) {
        throw const ConversationRepositoryException(
          RepositoryFailureCode.identityConflict,
          'current projection identity changed before apply',
        );
      }
      final sameEpoch =
          previousHead['source_epoch'] == projection.fence.sourceEpoch &&
          previousHead['provider_instance_epoch'] ==
              projection.fence.providerInstanceEpoch;
      final sameFence =
          sameEpoch &&
          previousHead['connection_epoch'] == projection.fence.connectionEpoch;
      final headRevision = previousHead['source_revision']! as int;
      final headGeneration =
          previousHead['runtime_authority_generation']! as int;
      if (sameEpoch &&
          projection.fence.runtimeAuthorityGeneration == headGeneration &&
          projection.sourceRevision == headRevision &&
          projection.projectionId != previousHead['projection_id']) {
        throw const ConversationRepositoryException(
          RepositoryFailureCode.identityConflict,
          'two projection identities claim the same monotonic head',
        );
      }
      if (!sameFence &&
          projection.fence.runtimeAuthorityGeneration == headGeneration) {
        throw const ConversationRepositoryException(
          RepositoryFailureCode.staleEpoch,
          'runtime projection epoch changed without a newer authority generation',
        );
      }
      final older =
          projection.fence.runtimeAuthorityGeneration < headGeneration ||
          (sameEpoch &&
              projection.fence.runtimeAuthorityGeneration == headGeneration &&
              (projection.sourceRevision < headRevision ||
                  (projection.sourceRevision == headRevision &&
                      projection.projectionId !=
                          previousHead['projection_id'])));
      if (older) {
        final stale = await txn.update(
          'projection_inbox',
          const <String, Object?>{'state': 'stale', 'gc_eligible': 1},
          where: '${_keyWhere()} AND projection_id = ? AND state = ?',
          whereArgs: <Object?>[..._keyArgs(key), projectionId, 'pending'],
        );
        if (stale != 1) {
          throw const ConversationRepositoryException(
            RepositoryFailureCode.invalidDatabaseIdentity,
            'projection inbox changed during stale transition',
          );
        }
        await _transitionProjectionIdentity(txn, key, identity, 'stale');
        return false;
      }
    }

    await _advanceProjectionOnlyThreadState(txn, projection);

    final canReuseSnapshotMarkers =
        previousHead != null &&
        previousHead['source_epoch'] == projection.fence.sourceEpoch &&
        previousHead['provider_instance_epoch'] ==
            projection.fence.providerInstanceEpoch &&
        previousHead['connection_epoch'] == projection.fence.connectionEpoch &&
        previousHead['runtime_authority_generation'] ==
            projection.fence.runtimeAuthorityGeneration;
    final freshSnapshotMarker = previousHead == null
        ? ''
        : projection.projectionId;

    final operationSnapshotMarker = projection.operationSnapshotComplete
        ? projection.projectionId
        : canReuseSnapshotMarkers
        ? previousHead['operation_snapshot_marker']! as String
        : freshSnapshotMarker;
    final queueSnapshotMarker = projection.queueSnapshotComplete
        ? projection.projectionId
        : canReuseSnapshotMarkers
        ? previousHead['queue_snapshot_marker']! as String
        : freshSnapshotMarker;
    final interactionSnapshotMarker = projection.interactionSnapshotComplete
        ? projection.projectionId
        : canReuseSnapshotMarkers
        ? previousHead['interaction_snapshot_marker']! as String
        : freshSnapshotMarker;
    await _applyOperationProjections(
      txn,
      repository,
      projection,
      snapshotMarker: operationSnapshotMarker,
    );
    await _applyQueueProjections(
      txn,
      repository,
      projection,
      snapshotMarker: queueSnapshotMarker,
    );
    await _applyInteractionProjections(
      txn,
      repository,
      projection,
      snapshotMarker: interactionSnapshotMarker,
    );

    final headValues = <String, Object?>{
      ..._keyColumns(key),
      'connection_epoch': projection.fence.connectionEpoch,
      'source_epoch': projection.fence.sourceEpoch,
      'provider_instance_epoch': projection.fence.providerInstanceEpoch,
      'runtime_authority_generation':
          projection.fence.runtimeAuthorityGeneration,
      'source_revision': projection.sourceRevision,
      'projection_id': projection.projectionId,
      'projection_digest': verified.projectionDigest,
      'operation_snapshot_complete': projection.operationSnapshotComplete
          ? 1
          : 0,
      'queue_snapshot_complete': projection.queueSnapshotComplete ? 1 : 0,
      'interaction_snapshot_complete': projection.interactionSnapshotComplete
          ? 1
          : 0,
      'operation_snapshot_marker': operationSnapshotMarker,
      'queue_snapshot_marker': queueSnapshotMarker,
      'interaction_snapshot_marker': interactionSnapshotMarker,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    };
    if (previousHead == null) {
      await txn.insert('projection_head', headValues);
    } else {
      await txn.update(
        'projection_head',
        headValues
          ..removeWhere((name, _) => _keyColumns(key).containsKey(name)),
        where: _keyWhere(),
        whereArgs: _keyArgs(key),
      );
    }
    final applied = await txn.update(
      'projection_inbox',
      const <String, Object?>{'state': 'applied', 'gc_eligible': 0},
      where: '${_keyWhere()} AND projection_id = ? AND state = ?',
      whereArgs: <Object?>[..._keyArgs(key), projectionId, 'pending'],
    );
    if (applied != 1) {
      throw const ConversationRepositoryException(
        RepositoryFailureCode.invalidDatabaseIdentity,
        'projection inbox state changed during apply',
      );
    }
    await _transitionProjectionIdentity(txn, key, identity, 'applied');
    await _insertPublicationOutbox(
      txn,
      key: projection.key,
      sourceEpoch: projection.fence.sourceEpoch,
      providerInstanceEpoch: projection.fence.providerInstanceEpoch,
      domain: 'projection',
      operationId: projection.projectionId,
      appliedDigest: verified.projectionDigest,
    );
    await _validateCapacity(txn, repository, key);
    return true;
  });
}

Future<void> _recoverProjectionInboxSafely(
  ConversationRepository repository,
  Database db,
) async {
  await _assertPendingProjectionIdentityCompleteness(db);
  if (!repository._usesGeneratedContract &&
      !(repository._allowFixtureContract && repository._usesFixtureContract)) {
    // Preserve the original fail-closed contract gate.  Pending rows remain
    // durable until an authorized mapper can verify their exact preimages.
    return;
  }

  const batchSize = 32;
  int? cursorAdmittedAt;
  String? cursorProjectionId;
  String? cursorBridgeIdentityId;
  String? cursorBridgeInstanceId;
  String? cursorCodexSourceId;
  String? cursorProviderThreadId;
  while (true) {
    final afterCursor = cursorAdmittedAt == null
        ? null
        : <Object?>[
            cursorAdmittedAt,
            cursorProjectionId,
            cursorBridgeIdentityId,
            cursorBridgeInstanceId,
            cursorCodexSourceId,
            cursorProviderThreadId,
          ];
    final rows = await db.query(
      'projection_inbox',
      columns: const <String>[
        'bridge_identity_id',
        'bridge_instance_id',
        'codex_source_id',
        'provider_thread_id',
        'projection_id',
        'admitted_at',
      ],
      where: afterCursor == null ? 'state = ?' : 'state = ? AND (admitted_at, projection_id, bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id) > (?, ?, ?, ?, ?, ?)',
      whereArgs: afterCursor == null
          ? const <Object?>['pending']
          : <Object?>['pending', ...afterCursor],
      orderBy: 'admitted_at ASC, projection_id ASC, bridge_identity_id ASC, bridge_instance_id ASC, codex_source_id ASC, provider_thread_id ASC',
      limit: batchSize,
    );
    if (rows.isEmpty) return;

    for (final row in rows) {
      final key = ThreadKey(
        partition: SourcePartition(
          bridgeIdentityId: row['bridge_identity_id']! as String,
          bridgeInstanceId: row['bridge_instance_id']! as String,
          codexSourceId: row['codex_source_id']! as String,
        ),
        providerThreadId: row['provider_thread_id']! as String,
      );
      final projectionId = row['projection_id']! as String;
      _VerifiedProjectionInbox? verified;
      try {
        verified = await _readVerifiedProjectionInbox(
          repository,
          db,
          key,
          projectionId,
        );
        if (verified == null) {
          throw const ConversationRepositoryException(
            RepositoryFailureCode.invalidDatabaseIdentity,
            'pending projection disappeared during recovery',
          );
        }
        await _applyProjectionInboxSafely(repository, db, key, projectionId);
      } on ConversationRepositoryException catch (error) {
        if (!_terminalProjectionRejectionCodes.contains(error.code)) rethrow;
        await _terminalizePendingProjection(
          repository,
          db,
          key,
          projectionId,
          expected: verified?.projection,
          requirePending: true,
        );
      }
    }

    final last = rows.last;
    cursorAdmittedAt = last['admitted_at']! as int;
    cursorProjectionId = last['projection_id']! as String;
    cursorBridgeIdentityId = last['bridge_identity_id']! as String;
    cursorBridgeInstanceId = last['bridge_instance_id']! as String;
    cursorCodexSourceId = last['codex_source_id']! as String;
    cursorProviderThreadId = last['provider_thread_id']! as String;
  }
}

Future<void> _validateProjectionAgainstCanonicalFence(
  DatabaseExecutor db,
  RuntimeProjectionEnvelope projection,
) async {
  final state = await _readThreadState(db, projection.key);
  if (state == null || state['state_kind'] != 'canonical') return;

  if (state['source_epoch'] != projection.fence.sourceEpoch ||
      state['provider_instance_epoch'] !=
          projection.fence.providerInstanceEpoch) {
    throw const ConversationRepositoryException(
      RepositoryFailureCode.staleEpoch,
      'runtime projection is not bound to the canonical source/provider epoch',
    );
  }

  final canonicalGeneration = state['runtime_authority_generation']! as int;
  final projectionGeneration = projection.fence.runtimeAuthorityGeneration;
  if (projectionGeneration < canonicalGeneration) {
    throw const ConversationRepositoryException(
      RepositoryFailureCode.staleGeneration,
      'runtime projection authority generation is older than the canonical fence',
    );
  }
  if (projectionGeneration == canonicalGeneration &&
      state['connection_epoch'] != projection.fence.connectionEpoch) {
    throw const ConversationRepositoryException(
      RepositoryFailureCode.staleEpoch,
      'runtime projection connection epoch conflicts with the canonical fence',
    );
  }
  if (projectionGeneration == canonicalGeneration &&
      projection.sourceRevision < (state['source_revision']! as int)) {
    throw const ConversationRepositoryException(
      RepositoryFailureCode.staleRevision,
      'runtime projection revision is older than the canonical source revision',
    );
  }
}

Future<void> _advanceProjectionOnlyThreadState(
  Transaction txn,
  RuntimeProjectionEnvelope projection,
) async {
  final state = await _readThreadState(txn, projection.key);
  if (state == null || state['state_kind'] != 'projection_only') return;
  final updated = await txn.update(
    'thread_state',
    <String, Object?>{
      'connection_epoch': projection.fence.connectionEpoch,
      'source_epoch': projection.fence.sourceEpoch,
      'provider_instance_epoch': projection.fence.providerInstanceEpoch,
      'runtime_authority_generation':
          projection.fence.runtimeAuthorityGeneration,
      'source_revision': projection.sourceRevision,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    },
    where: '${_keyWhere()} AND state_kind = ?',
    whereArgs: <Object?>[..._keyArgs(projection.key), 'projection_only'],
  );
  if (updated != 1) {
    throw const ConversationRepositoryException(
      RepositoryFailureCode.invalidDatabaseIdentity,
      'projection-only thread state changed during apply',
    );
  }
}

Future<_VerifiedProjectionInbox?> _readVerifiedProjectionInbox(
  ConversationRepository repository,
  DatabaseExecutor db,
  ThreadKey key,
  String projectionId, {
  bool allowAbsent = false,
}) async {
  final rows = await db.query(
    'projection_inbox',
    columns: const <String>[
      'connection_epoch',
      'source_epoch',
      'provider_instance_epoch',
      'runtime_authority_generation',
      'source_revision',
      'projection_digest',
      'payload_json',
      'state',
      'gc_eligible',
    ],
    where: '${_keyWhere()} AND projection_id = ?',
    whereArgs: <Object?>[..._keyArgs(key), projectionId],
    limit: 1,
  );
  if (rows.isEmpty) {
    if (allowAbsent) return null;
    throw const ConversationRepositoryException(
      RepositoryFailureCode.invalidDatabaseIdentity,
      'projection inbox row is missing',
    );
  }

  final row = rows.single;
  final state = row['state'];
  final payloadJson = row['payload_json'];
  final projectionDigest = row['projection_digest'];
  final gcEligible = row['gc_eligible'];
  if (state is! String ||
      !const <String>{'pending', 'applied', 'stale'}.contains(state) ||
      payloadJson is! String ||
      projectionDigest is! String ||
      gcEligible is! int ||
      (gcEligible != 0 && gcEligible != 1) ||
      (state == 'pending' && gcEligible != 0) ||
      (state == 'stale' && gcEligible != 1)) {
    throw const ConversationRepositoryException(
      RepositoryFailureCode.invalidDatabaseIdentity,
      'projection inbox row has invalid stored state or types',
    );
  }

  final stored = _decodeProjection(payloadJson);
  _validateRuntimeProjection(stored);
  if (stored.key != key || stored.projectionId != projectionId) {
    throw const ConversationRepositoryException(
      RepositoryFailureCode.invalidDatabaseIdentity,
      'projection inbox payload identity does not match its row',
    );
  }
  final expectedHeader = <String, Object?>{
    'connection_epoch': stored.fence.connectionEpoch,
    'source_epoch': stored.fence.sourceEpoch,
    'provider_instance_epoch': stored.fence.providerInstanceEpoch,
    'runtime_authority_generation': stored.fence.runtimeAuthorityGeneration,
    'source_revision': stored.sourceRevision,
  };
  if (expectedHeader.entries.any((entry) => row[entry.key] != entry.value)) {
    throw const ConversationRepositoryException(
      RepositoryFailureCode.invalidDatabaseIdentity,
      'projection inbox header does not match its verified payload',
    );
  }
  final storedPayload = _storageJson(
    _projectionStorageValue(stored),
    'projection inbox payload',
  );
  if (storedPayload != payloadJson) {
    throw const ConversationRepositoryException(
      RepositoryFailureCode.invalidDatabaseIdentity,
      'projection inbox payload does not match repository storage encoding',
    );
  }
  final artifact = repository._verifiedPreimage(
    repository._contractMapper.runtimeProjection(stored),
    'runtime projection inbox payload',
  );
  if (artifact.digest != projectionDigest) {
    throw const ConversationRepositoryException(
      RepositoryFailureCode.digestMismatch,
      'projection inbox bytes no longer match their digest',
    );
  }

  return _VerifiedProjectionInbox(
    projection: stored,
    payloadJson: payloadJson,
    projectionDigest: projectionDigest,
    state: state,
  );
}

Future<bool> _terminalizePendingProjection(
  ConversationRepository repository,
  Database db,
  ThreadKey key,
  String projectionId, {
  RuntimeProjectionEnvelope? expected,
  required bool requirePending,
}) async {
  await _prepareCapacity(db, repository, key);
  return db.transaction((txn) async {
    await _assertWriterLease(txn, repository);
    final verified = await _readVerifiedProjectionInbox(
      repository,
      txn,
      key,
      projectionId,
      allowAbsent: !requirePending,
    );
    if (verified == null || verified.state != 'pending') {
      if (requirePending) {
        throw const ConversationRepositoryException(
          RepositoryFailureCode.invalidDatabaseIdentity,
          'rejected projection is no longer pending',
        );
      }
      return false;
    }
    final identity = await _readVerifiedProjectionIdentity(
      txn,
      key,
      projectionId,
    );
    if (identity == null) {
      throw const ConversationRepositoryException(
        RepositoryFailureCode.invalidDatabaseIdentity,
        'pending projection identity is missing during terminalization',
      );
    }
    _assertProjectionIdentityMatchesInbox(identity, verified);

    if (expected != null) {
      final expectedPayload = _storageJson(
        _projectionStorageValue(expected),
        'projection inbox payload',
      );
      final expectedArtifact = repository._verifiedPreimage(
        repository._contractMapper.runtimeProjection(expected),
        'rejected runtime projection',
      );
      if (verified.payloadJson != expectedPayload ||
          verified.projectionDigest != expectedArtifact.digest) {
        if (requirePending) {
          throw const ConversationRepositoryException(
            RepositoryFailureCode.invalidDatabaseIdentity,
            'pending projection changed identity before terminalization',
          );
        }
        return false;
      }
    }

    final updated = await txn.update(
      'projection_inbox',
      const <String, Object?>{'state': 'stale', 'gc_eligible': 1},
      where: '${_keyWhere()} AND projection_id = ? AND state = ?',
      whereArgs: <Object?>[..._keyArgs(key), projectionId, 'pending'],
    );
    if (updated != 1) {
      throw const ConversationRepositoryException(
        RepositoryFailureCode.invalidDatabaseIdentity,
        'pending projection changed during terminalization',
      );
    }
    await _transitionProjectionIdentity(txn, key, identity, 'stale');
    await _validateCapacity(txn, repository, key);
    return true;
  });
}
