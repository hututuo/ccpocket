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
      final existing = await _readVerifiedProjectionInbox(
        repository,
        txn,
        projection.key,
        projection.projectionId,
        allowAbsent: true,
      );
      if (existing != null) {
        if (existing.projectionDigest != projectionDigest ||
            existing.payloadJson != payloadJson) {
          throw const ConversationRepositoryException(
            RepositoryFailureCode.identityConflict,
            'projection identity was reused with another payload',
          );
        }
        return _ProjectionAdmission(
          wasDuplicate: true,
          wasAlreadyApplied: existing.state != 'pending',
        );
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
        where: '${_keyWhere()} AND projection_id = ?',
        whereArgs: <Object?>[
          ..._keyArgs(projection.key),
          projection.projectionId,
        ],
        limit: 1,
      );
      if (headRows.isNotEmpty) {
        if (!_projectionHeadIdentityMatches(
          headRows.single,
          projection,
          projectionDigest,
        )) {
          throw const ConversationRepositoryException(
            RepositoryFailureCode.identityConflict,
            'current projection identity was reused with another digest or fence',
          );
        }
        // An exact current head remains authoritative even if an older GC or
        // manually damaged database lost its larger inbox payload.  Do not
        // recreate the publication identity or reinterpret the same ID.
        return const _ProjectionAdmission(
          wasDuplicate: true,
          wasAlreadyApplied: true,
        );
      }

      // This check is in the same writer transaction as admission.  A
      // canonical fence cannot advance between validation and inbox insert.
      await _validateProjectionAgainstCanonicalFence(txn, projection);
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
        await txn.update(
          'projection_inbox',
          const <String, Object?>{'state': 'stale', 'gc_eligible': 1},
          where: '${_keyWhere()} AND projection_id = ? AND state = ?',
          whereArgs: <Object?>[..._keyArgs(key), projectionId, 'pending'],
        );
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
    await _validateCapacity(txn, repository, key);
    return true;
  });
}
