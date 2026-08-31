part of 'conversation_repository.dart';

const _repositoryGcBatchSize = 32;

class _TrackedUsage {
  const _TrackedUsage({
    required this.mutableEntries,
    required this.mutableBytes,
    required this.retiredEntries,
    required this.retiredBytes,
  });

  final int mutableEntries;
  final int mutableBytes;
  final int retiredEntries;
  final int retiredBytes;
}

// Retained only to keep the cloud safety delta additive and reviewable. The
// facade is fenced to `_commitRuntimeProjectionSafely`.
// ignore: unused_element
Future<CommitReceipt> _commitRuntimeProjection(
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

  final admission = await repository._serialize((db) async {
    await _prepareCapacity(db, repository, projection.key);
    return db.transaction((txn) async {
      await _assertWriterLease(txn, repository);
      final rows = await txn.query(
        'projection_inbox',
        columns: const <String>['projection_digest', 'payload_json', 'state'],
        where: '${_keyWhere()} AND projection_id = ?',
        whereArgs: <Object?>[
          ..._keyArgs(projection.key),
          projection.projectionId,
        ],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        final row = rows.single;
        if (row['projection_digest'] != artifact.digest ||
            row['payload_json'] != payload) {
          throw const ConversationRepositoryException(
            RepositoryFailureCode.identityConflict,
            'projection identity was reused with another payload',
          );
        }
        return _ProjectionAdmission(
          wasDuplicate: true,
          wasAlreadyApplied: row['state'] != 'pending',
          publicationFence: null,
        );
      }
      await txn.insert('projection_inbox', <String, Object?>{
        ..._keyColumns(projection.key),
        'projection_id': projection.projectionId,
        'connection_epoch': projection.fence.connectionEpoch,
        'source_epoch': projection.fence.sourceEpoch,
        'provider_instance_epoch': projection.fence.providerInstanceEpoch,
        'runtime_authority_generation':
            projection.fence.runtimeAuthorityGeneration,
        'source_revision': projection.sourceRevision,
        'projection_digest': artifact.digest,
        'payload_json': payload,
        'state': 'pending',
        'gc_eligible': 0,
        'admitted_at': DateTime.now().millisecondsSinceEpoch,
      });
      await _validateCapacity(txn, repository, projection.key);
      return const _ProjectionAdmission(
        wasDuplicate: false,
        wasAlreadyApplied: false,
        publicationFence: null,
      );
    });
  });

  // The fault is deliberately after the admission transaction.  A crash at
  // this boundary leaves a durable inbox row that the next open can replay.
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

  final changed = await repository._serialize((db) async {
    return _applyProjectionInbox(
      repository,
      db,
      projection.key,
      projection.projectionId,
    );
  });
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

Future<bool> _applyProjectionInbox(
  ConversationRepository repository,
  Database db,
  ThreadKey key,
  String projectionId,
) async {
  await _prepareCapacity(db, repository, key);
  return db.transaction((txn) async {
    await _assertWriterLease(txn, repository);
    final rows = await txn.query(
      'projection_inbox',
      where: '${_keyWhere()} AND projection_id = ?',
      whereArgs: <Object?>[..._keyArgs(key), projectionId],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw const ConversationRepositoryException(
        RepositoryFailureCode.materializationNotFound,
        'runtime projection inbox row is missing',
      );
    }
    final row = rows.single;
    if (row['state'] != 'pending') return false;
    final projection = _decodeProjection(row['payload_json']! as String);
    _validateRuntimeProjection(projection);
    if (projection.projectionId != projectionId || projection.key != key) {
      throw const ConversationRepositoryException(
        RepositoryFailureCode.identityConflict,
        'projection inbox payload identity does not match its row',
      );
    }
    final projectionArtifact = repository._verifiedPreimage(
      repository._contractMapper.runtimeProjection(projection),
      'runtime projection inbox payload',
    );
    if (projectionArtifact.digest != row['projection_digest']) {
      throw const ConversationRepositoryException(
        RepositoryFailureCode.digestMismatch,
        'projection inbox bytes no longer match its digest',
      );
    }
    await _rejectRetiredEpochs(txn, projection.key.partition, projection.fence);
    await _validateProjectionAgainstCanonicalState(txn, projection);
    await _ensureProjectionThreadState(txn, projection);
    final headRows = await txn.query(
      'projection_head',
      where: _keyWhere(),
      whereArgs: _keyArgs(key),
      limit: 1,
    );
    final previousHead = headRows.isEmpty ? null : headRows.single;
    if (headRows.isNotEmpty) {
      final head = headRows.single;
      final sameEpoch =
          head['source_epoch'] == projection.fence.sourceEpoch &&
          head['provider_instance_epoch'] ==
              projection.fence.providerInstanceEpoch;
      final sameFence =
          sameEpoch &&
          head['connection_epoch'] == projection.fence.connectionEpoch;
      final headRevision = head['source_revision']! as int;
      final headGeneration = head['runtime_authority_generation']! as int;
      if (sameEpoch &&
          projection.fence.runtimeAuthorityGeneration == headGeneration &&
          projection.sourceRevision == headRevision &&
          projection.projectionId != head['projection_id']) {
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
                      projection.projectionId != head['projection_id'])));
      if (older) {
        await txn.update(
          'projection_inbox',
          const <String, Object?>{'state': 'stale', 'gc_eligible': 1},
          where: '${_keyWhere()} AND projection_id = ?',
          whereArgs: <Object?>[..._keyArgs(key), projectionId],
        );
        return false;
      }
    }
    final operationSnapshotMarker = projection.operationSnapshotComplete
        ? projection.projectionId
        : previousHead?['operation_snapshot_marker'] as String? ?? '';
    final queueSnapshotMarker = projection.queueSnapshotComplete
        ? projection.projectionId
        : previousHead?['queue_snapshot_marker'] as String? ?? '';
    final interactionSnapshotMarker = projection.interactionSnapshotComplete
        ? projection.projectionId
        : previousHead?['interaction_snapshot_marker'] as String? ?? '';
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
      'projection_digest': row['projection_digest'],
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
    final existingHead = await txn.query(
      'projection_head',
      columns: const <String>['projection_id'],
      where: _keyWhere(),
      whereArgs: _keyArgs(key),
      limit: 1,
    );
    if (existingHead.isEmpty) {
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
    await txn.update(
      'projection_inbox',
      const <String, Object?>{'state': 'applied', 'gc_eligible': 0},
      where: '${_keyWhere()} AND projection_id = ?',
      whereArgs: <Object?>[..._keyArgs(key), projectionId],
    );
    await _insertPublicationOutbox(
      txn,
      key: projection.key,
      sourceEpoch: projection.fence.sourceEpoch,
      providerInstanceEpoch: projection.fence.providerInstanceEpoch,
      domain: 'projection',
      operationId: projection.projectionId,
      appliedDigest: row['projection_digest']! as String,
    );
    await _validateCapacity(txn, repository, key);
    return true;
  });
}

// Retained only to keep the cloud safety delta additive and reviewable. Open
// recovery is fenced to `_recoverProjectionInboxSafely`.
// ignore: unused_element
Future<void> _recoverProjectionInbox(
  ConversationRepository repository,
  Database db,
) async {
  if (!repository._usesGeneratedContract &&
      !(repository._allowFixtureContract && repository._usesFixtureContract)) {
    // No generated mapper means no projection can be materialized.  Keeping
    // pending rows is safe and makes the missing contract visible on retry.
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
    if (rows.isEmpty) break;
    for (final row in rows) {
      final key = ThreadKey(
        partition: SourcePartition(
          bridgeIdentityId: row['bridge_identity_id']! as String,
          bridgeInstanceId: row['bridge_instance_id']! as String,
          codexSourceId: row['codex_source_id']! as String,
        ),
        providerThreadId: row['provider_thread_id']! as String,
      );
      await _applyProjectionInbox(
        repository,
        db,
        key,
        row['projection_id']! as String,
      );
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

Future<void> _ensureProjectionThreadState(
  Transaction txn,
  RuntimeProjectionEnvelope projection,
) async {
  final existing = await _readThreadState(txn, projection.key);
  if (existing != null) return;
  await txn.insert('thread_state', <String, Object?>{
    ..._keyColumns(projection.key),
    'state_kind': 'projection_only',
    'connection_epoch': projection.fence.connectionEpoch,
    'source_epoch': projection.fence.sourceEpoch,
    'provider_instance_epoch': projection.fence.providerInstanceEpoch,
    'runtime_authority_generation': projection.fence.runtimeAuthorityGeneration,
    'source_revision': 0,
    'current_envelope_id': null,
    'current_envelope_digest': null,
    'last_good_revision': -1,
    'last_good_connection_epoch': null,
    'last_good_source_epoch': null,
    'last_good_provider_instance_epoch': null,
    'last_good_runtime_authority_generation': null,
    'last_good_envelope_id': null,
    'last_good_envelope_digest': null,
    'structural_coverage': StructuralCoverage.partial.name,
    'payload_coverage': PayloadCoverage.partial.name,
    'lower_ordinal': null,
    'upper_ordinal': null,
    'health': ReadHealth.degraded.name,
    'problem_code': 'runtime_projection_only',
    'updated_at': DateTime.now().millisecondsSinceEpoch,
  });
}

Future<void> _validateProjectionAgainstCanonicalState(
  Transaction txn,
  RuntimeProjectionEnvelope projection,
) async {
  final state = await _readThreadState(txn, projection.key);
  if (state == null) return;
  if (state['source_epoch'] != projection.fence.sourceEpoch ||
      state['provider_instance_epoch'] !=
          projection.fence.providerInstanceEpoch) {
    throw const ConversationRepositoryException(
      RepositoryFailureCode.staleEpoch,
      'runtime projection is not bound to the canonical source/provider epoch',
    );
  }
}

Future<void> _applyOperationProjections(
  Transaction txn,
  ConversationRepository repository,
  RuntimeProjectionEnvelope projection, {
  required String snapshotMarker,
}) async {
  for (final value in projection.operations) {
    final digest = repository
        ._verifiedPreimage(
          repository._contractMapper.operationProjection(value),
          'operation projection',
        )
        .digest;
    final encoded = _storageJson(value.value, 'operation value');
    final rows = await txn.query(
      'operation_projection',
      where: '${_keyWhere()} AND operation_id = ?',
      whereArgs: <Object?>[..._keyArgs(projection.key), value.operationId],
      limit: 1,
    );
    if (rows.isNotEmpty) {
      final prior = rows.single;
      final priorRevision = prior['revision']! as int;
      if (value.revision < priorRevision) continue;
      if (value.revision == priorRevision) {
        if (prior['value_digest'] != digest) {
          throw const ConversationRepositoryException(
            RepositoryFailureCode.identityConflict,
            'operation revision was reused with different content',
          );
        }
        if (prior['is_active'] != 1 ||
            prior['gc_eligible'] != 0 ||
            prior['snapshot_marker'] != snapshotMarker ||
            prior['source_projection_id'] != projection.projectionId) {
          await txn.update(
            'operation_projection',
            <String, Object?>{
              'is_active': 1,
              'gc_eligible': 0,
              'snapshot_marker': snapshotMarker,
              'source_projection_id': projection.projectionId,
            },
            where: '${_keyWhere()} AND operation_id = ?',
            whereArgs: <Object?>[
              ..._keyArgs(projection.key),
              value.operationId,
            ],
          );
        }
        continue;
      }
      if (prior['is_terminal'] == 1 && !value.isTerminal) {
        throw const ConversationRepositoryException(
          RepositoryFailureCode.identityConflict,
          'terminal operation projection cannot become non-terminal',
        );
      }
      await txn.update(
        'operation_projection',
        <String, Object?>{
          'revision': value.revision,
          'state': value.state,
          'is_terminal': value.isTerminal ? 1 : 0,
          'value_json': encoded,
          'value_digest': digest,
          'is_active': 1,
          'gc_eligible': 0,
          'snapshot_marker': snapshotMarker,
          'source_projection_id': projection.projectionId,
        },
        where: '${_keyWhere()} AND operation_id = ?',
        whereArgs: <Object?>[..._keyArgs(projection.key), value.operationId],
      );
    } else {
      await txn.insert('operation_projection', <String, Object?>{
        ..._keyColumns(projection.key),
        'operation_id': value.operationId,
        'revision': value.revision,
        'state': value.state,
        'is_terminal': value.isTerminal ? 1 : 0,
        'value_json': encoded,
        'value_digest': digest,
        'is_active': 1,
        'gc_eligible': 0,
        'snapshot_marker': snapshotMarker,
        'source_projection_id': projection.projectionId,
      });
    }
  }
}

Future<void> _applyQueueProjections(
  Transaction txn,
  ConversationRepository repository,
  RuntimeProjectionEnvelope projection, {
  required String snapshotMarker,
}) async {
  for (final value in projection.queueEntries) {
    final digest = repository
        ._verifiedPreimage(
          repository._contractMapper.queueEntryProjection(value),
          'queue entry projection',
        )
        .digest;
    final encoded = _storageJson(value.value, 'queue entry value');
    final rows = await txn.query(
      'queue_entry_projection',
      where: '${_keyWhere()} AND queue_entry_id = ?',
      whereArgs: <Object?>[..._keyArgs(projection.key), value.queueEntryId],
      limit: 1,
    );
    if (rows.isNotEmpty) {
      final prior = rows.single;
      final priorRevision = prior['revision']! as int;
      if (value.revision < priorRevision) continue;
      if (value.revision == priorRevision) {
        if (prior['value_digest'] != digest) {
          throw const ConversationRepositoryException(
            RepositoryFailureCode.identityConflict,
            'queue entry revision was reused with different content',
          );
        }
        if (prior['is_active'] != 1 ||
            prior['gc_eligible'] != 0 ||
            prior['snapshot_marker'] != snapshotMarker ||
            prior['source_projection_id'] != projection.projectionId) {
          await txn.update(
            'queue_entry_projection',
            <String, Object?>{
              'is_active': 1,
              'gc_eligible': 0,
              'snapshot_marker': snapshotMarker,
              'source_projection_id': projection.projectionId,
            },
            where: '${_keyWhere()} AND queue_entry_id = ?',
            whereArgs: <Object?>[
              ..._keyArgs(projection.key),
              value.queueEntryId,
            ],
          );
        }
        continue;
      }
      await txn.update(
        'queue_entry_projection',
        <String, Object?>{
          'operation_id': value.operationId,
          'revision': value.revision,
          'position': value.position,
          'state': value.state,
          'value_json': encoded,
          'value_digest': digest,
          'is_active': 1,
          'gc_eligible': 0,
          'snapshot_marker': snapshotMarker,
          'source_projection_id': projection.projectionId,
        },
        where: '${_keyWhere()} AND queue_entry_id = ?',
        whereArgs: <Object?>[..._keyArgs(projection.key), value.queueEntryId],
      );
    } else {
      await txn.insert('queue_entry_projection', <String, Object?>{
        ..._keyColumns(projection.key),
        'queue_entry_id': value.queueEntryId,
        'operation_id': value.operationId,
        'revision': value.revision,
        'position': value.position,
        'state': value.state,
        'value_json': encoded,
        'value_digest': digest,
        'is_active': 1,
        'gc_eligible': 0,
        'snapshot_marker': snapshotMarker,
        'source_projection_id': projection.projectionId,
      });
    }
  }
}

Future<void> _applyInteractionProjections(
  Transaction txn,
  ConversationRepository repository,
  RuntimeProjectionEnvelope projection, {
  required String snapshotMarker,
}) async {
  for (final value in projection.interactions) {
    final digest = repository
        ._verifiedPreimage(
          repository._contractMapper.interactionProjection(value),
          'interaction projection',
        )
        .digest;
    final encoded = _storageJson(value.value, 'interaction value');
    final rows = await txn.query(
      'interaction_projection',
      where: '${_keyWhere()} AND interaction_id = ?',
      whereArgs: <Object?>[..._keyArgs(projection.key), value.interactionId],
      limit: 1,
    );
    if (rows.isNotEmpty) {
      final prior = rows.single;
      final priorRevision = prior['revision']! as int;
      if (value.revision < priorRevision) continue;
      if (value.revision == priorRevision) {
        if (prior['value_digest'] != digest) {
          throw const ConversationRepositoryException(
            RepositoryFailureCode.identityConflict,
            'interaction revision was reused with different content',
          );
        }
        if (prior['is_active'] != 1 ||
            prior['gc_eligible'] != 0 ||
            prior['snapshot_marker'] != snapshotMarker ||
            prior['source_projection_id'] != projection.projectionId) {
          await txn.update(
            'interaction_projection',
            <String, Object?>{
              'is_active': 1,
              'gc_eligible': 0,
              'snapshot_marker': snapshotMarker,
              'source_projection_id': projection.projectionId,
            },
            where: '${_keyWhere()} AND interaction_id = ?',
            whereArgs: <Object?>[
              ..._keyArgs(projection.key),
              value.interactionId,
            ],
          );
        }
        continue;
      }
      await txn.update(
        'interaction_projection',
        <String, Object?>{
          'revision': value.revision,
          'kind': value.kind,
          'state': value.state,
          'claim_actor_id': value.claimActorId,
          'claim_expires_at': value.claimExpiresAt?.millisecondsSinceEpoch,
          'value_json': encoded,
          'value_digest': digest,
          'is_active': 1,
          'gc_eligible': 0,
          'snapshot_marker': snapshotMarker,
          'source_projection_id': projection.projectionId,
        },
        where: '${_keyWhere()} AND interaction_id = ?',
        whereArgs: <Object?>[..._keyArgs(projection.key), value.interactionId],
      );
    } else {
      await txn.insert('interaction_projection', <String, Object?>{
        ..._keyColumns(projection.key),
        'interaction_id': value.interactionId,
        'revision': value.revision,
        'kind': value.kind,
        'state': value.state,
        'claim_actor_id': value.claimActorId,
        'claim_expires_at': value.claimExpiresAt?.millisecondsSinceEpoch,
        'value_json': encoded,
        'value_digest': digest,
        'is_active': 1,
        'gc_eligible': 0,
        'snapshot_marker': snapshotMarker,
        'source_projection_id': projection.projectionId,
      });
    }
  }
}

Future<void> _markProjectionGcEligibleAfterAck(
  Transaction txn,
  Map<String, Object?> outbox,
) async {
  if (outbox['domain'] != 'projection') return;
  final bridgeIdentityId = outbox['bridge_identity_id'];
  final bridgeInstanceId = outbox['bridge_instance_id'];
  final codexSourceId = outbox['codex_source_id'];
  final providerThreadId = outbox['provider_thread_id'];
  final projectionId = outbox['operation_id'];
  if (bridgeIdentityId is! String ||
      bridgeInstanceId is! String ||
      codexSourceId is! String ||
      providerThreadId is! String ||
      projectionId is! String) {
    throw const ConversationRepositoryException(
      RepositoryFailureCode.invalidDatabaseIdentity,
      'projection publication identity is malformed',
    );
  }
  final key = ThreadKey(
    partition: SourcePartition(
      bridgeIdentityId: bridgeIdentityId,
      bridgeInstanceId: bridgeInstanceId,
      codexSourceId: codexSourceId,
    ),
    providerThreadId: providerThreadId,
  );
  for (final table in const <String>[
    'operation_projection',
    'queue_entry_projection',
    'interaction_projection',
  ]) {
    await txn.update(
      table,
      const <String, Object?>{'gc_eligible': 1},
      where: '${_keyWhere()} AND source_projection_id = ?',
      whereArgs: <Object?>[..._keyArgs(key), projectionId],
    );
  }
  await txn.update(
    'projection_inbox',
    const <String, Object?>{'gc_eligible': 1},
    where: '${_keyWhere()} AND projection_id = ? AND state = ?',
    whereArgs: <Object?>[..._keyArgs(key), projectionId, 'applied'],
  );
}

Future<void> _collectRepositoryGarbage(
  DatabaseExecutor db,
  ThreadKey key,
) async {
  // Every phase below is deliberately capped.  The usage trigger gives the
  // normal path an O(1) budget check; a pressure event performs only a small
  // amount of rebuildable cleanup and can be revisited by later mutations.
  await _deletePublishedOutboxBatch(db, key);
  await _deleteStaleInboxBatch(db, key);

  // Inactive projections and resolved gaps are rebuildable.  A complete
  // snapshot can reintroduce an omitted row at the same row revision; if a
  // pressure event deletes that old row, the next valid snapshot inserts the
  // immutable identity again.
  for (final table in const <String>[
    'operation_projection',
    'queue_entry_projection',
    'interaction_projection',
    'typed_gap',
  ]) {
    await _deleteInactiveBatch(db, table, key);
  }
  final projectionHeadRows = await db.query(
    'projection_head',
    columns: const <String>[
      'operation_snapshot_marker',
      'queue_snapshot_marker',
      'interaction_snapshot_marker',
    ],
    where: _keyWhere(),
    whereArgs: _keyArgs(key),
    limit: 1,
  );
  if (projectionHeadRows.isNotEmpty) {
    final head = projectionHeadRows.single;
    for (final entry in <String, String?>{
      'operation_projection': head['operation_snapshot_marker'] as String?,
      'queue_entry_projection': head['queue_snapshot_marker'] as String?,
      'interaction_projection': head['interaction_snapshot_marker'] as String?,
    }.entries) {
      final marker = entry.value;
      if (marker != null) {
        await _deleteSupersededProjectionBatch(db, entry.key, key, marker);
      }
    }
  }

  final stateRows = await db.query(
    'thread_state',
    columns: const <String>[
      'state_kind',
      'connection_epoch',
      'source_epoch',
      'provider_instance_epoch',
      'runtime_authority_generation',
      'source_revision',
      'current_envelope_id',
      'current_envelope_digest',
      'last_good_revision',
      'last_good_connection_epoch',
      'last_good_source_epoch',
      'last_good_provider_instance_epoch',
      'last_good_runtime_authority_generation',
      'last_good_envelope_id',
      'last_good_envelope_digest',
    ],
    where: _keyWhere(),
    whereArgs: _keyArgs(key),
    limit: 1,
  );
  final state = stateRows.isEmpty ? null : stateRows.single;
  await _deleteEnvelopeBatch(db, key, state);
  await _deleteStagingBatch(db, key, state);
}

Future<void> _deletePublishedOutboxBatch(
  DatabaseExecutor db,
  ThreadKey key,
) async {
  final rows = await db.query(
    'publication_outbox',
    columns: const <String>[
      'source_epoch',
      'provider_instance_epoch',
      'domain',
      'operation_id',
    ],
    where: '${_keyWhere()} AND phase = ? AND notification_state = ?',
    whereArgs: <Object?>[..._keyArgs(key), 'published', 'notified'],
    orderBy: 'published_at ASC, operation_id ASC',
    limit: _repositoryGcBatchSize,
  );
  for (final row in rows) {
    final sourceEpoch = row['source_epoch'];
    final providerEpoch = row['provider_instance_epoch'];
    final domain = row['domain'];
    final operationId = row['operation_id'];
    if (sourceEpoch is! String ||
        providerEpoch is! String ||
        domain is! String ||
        operationId is! String) {
      continue;
    }
    await db.delete(
      'publication_outbox',
      where: _outboxWhere(),
      whereArgs: _outboxArgs(
        key,
        sourceEpoch,
        providerEpoch,
        domain,
        operationId,
      ),
    );
  }
}

Future<void> _deleteStaleInboxBatch(DatabaseExecutor db, ThreadKey key) async {
  final headRows = await db.query(
    'projection_head',
    columns: const <String>['projection_id'],
    where: _keyWhere(),
    whereArgs: _keyArgs(key),
    limit: 1,
  );
  final currentProjectionId = headRows.isEmpty
      ? null
      : headRows.single['projection_id'] as String?;
  // ACK advances gc_eligible in the same transaction as notification_state.
  // The candidate index therefore sees only rows whose publication no longer
  // needs readback, while the exact current head remains durable identity
  // evidence even after its publication has been acknowledged.
  final rows = await db.query(
    'projection_inbox',
    columns: const <String>['projection_id'],
    where:
        '${_keyWhere()} AND gc_eligible = ? AND state IN (?, ?)${currentProjectionId == null ? '' : ' AND projection_id <> ?'}',
    whereArgs: <Object?>[
      ..._keyArgs(key),
      1,
      'applied',
      'stale',
      ?currentProjectionId,
    ],
    orderBy: 'state ASC, admitted_at ASC, projection_id ASC',
    limit: _repositoryGcBatchSize,
  );
  for (final row in rows) {
    final projectionId = row['projection_id'];
    if (projectionId is! String) continue;
    await db.delete(
      'projection_inbox',
      where:
          '${_keyWhere()} AND projection_id = ? AND gc_eligible = ?${currentProjectionId == null ? '' : ' AND projection_id <> ?'}',
      whereArgs: <Object?>[
        ..._keyArgs(key),
        projectionId,
        1,
        ?currentProjectionId,
      ],
    );
  }
}

Future<void> _deleteInactiveBatch(
  DatabaseExecutor db,
  String table,
  ThreadKey key,
) async {
  final idColumn = switch (table) {
    'operation_projection' => 'operation_id',
    'queue_entry_projection' => 'queue_entry_id',
    'interaction_projection' => 'interaction_id',
    'typed_gap' => 'gap_id',
    _ => throw ArgumentError.value(table, 'table'),
  };
  final rows = await db.query(
    table,
    columns: <String>[idColumn],
    where: '${_keyWhere()} AND is_active = 0',
    whereArgs: _keyArgs(key),
    orderBy: '$idColumn ASC',
    limit: _repositoryGcBatchSize,
  );
  for (final row in rows) {
    final id = row[idColumn];
    if (id is! String) continue;
    await db.delete(
      table,
      where: '${_keyWhere()} AND $idColumn = ? AND is_active = 0',
      whereArgs: <Object?>[..._keyArgs(key), id],
    );
  }
}

Future<void> _deleteSupersededProjectionBatch(
  DatabaseExecutor db,
  String table,
  ThreadKey key,
  String snapshotMarker,
) async {
  final idColumn = switch (table) {
    'operation_projection' => 'operation_id',
    'queue_entry_projection' => 'queue_entry_id',
    'interaction_projection' => 'interaction_id',
    _ => throw ArgumentError.value(table, 'table'),
  };
  // ACK publishes GC eligibility into the projection rows before the outbox
  // can be reclaimed.  Retention is therefore part of the indexed candidate
  // predicate rather than a post-LIMIT filter that can starve later rows.
  final rows = <Map<String, Object?>>[
    ...await db.query(
      table,
      columns: <String>[idColumn, 'snapshot_marker'],
      where:
          '${_keyWhere()} AND is_active = 1 AND gc_eligible = 1 AND snapshot_marker < ?',
      whereArgs: <Object?>[..._keyArgs(key), snapshotMarker],
      orderBy: 'snapshot_marker ASC, $idColumn ASC',
      limit: _repositoryGcBatchSize,
    ),
  ];
  if (rows.length < _repositoryGcBatchSize) {
    rows.addAll(
      await db.query(
        table,
        columns: <String>[idColumn, 'snapshot_marker'],
        where:
            '${_keyWhere()} AND is_active = 1 AND gc_eligible = 1 AND snapshot_marker > ?',
        whereArgs: <Object?>[..._keyArgs(key), snapshotMarker],
        orderBy: 'snapshot_marker ASC, $idColumn ASC',
        limit: _repositoryGcBatchSize - rows.length,
      ),
    );
  }
  for (final row in rows) {
    final id = row[idColumn];
    final rowSnapshotMarker = row['snapshot_marker'];
    if (id is! String || rowSnapshotMarker is! String) {
      continue;
    }
    await db.delete(
      table,
      where:
          '${_keyWhere()} AND $idColumn = ? AND is_active = 1 AND gc_eligible = 1 AND snapshot_marker = ?',
      whereArgs: <Object?>[..._keyArgs(key), id, rowSnapshotMarker],
    );
  }
}

Future<bool> _hasPendingOutbox(
  DatabaseExecutor db,
  ThreadKey key, {
  required String sourceEpoch,
  required String providerEpoch,
  required String domain,
  required String operationId,
}) async {
  final rows = await db.query(
    'publication_outbox',
    columns: const <String>['phase'],
    where: '${_outboxWhere()} AND notification_state IN (?, ?)',
    whereArgs: <Object?>[
      ..._outboxArgs(key, sourceEpoch, providerEpoch, domain, operationId),
      'pending',
      'delivering',
    ],
    limit: 1,
  );
  return rows.isNotEmpty;
}

Future<void> _deleteEnvelopeBatch(
  DatabaseExecutor db,
  ThreadKey key,
  Map<String, Object?>? state,
) async {
  // `thread_state` is the durable binding between the visible head and the
  // immutable proof row.  Never infer that binding from a matching
  // fence/revision: multiple envelopes may legitimately have the same source
  // revision, and the oldest one is not necessarily the one that won.
  final preserved = <String, String>{};

  Future<void> preserveBoundEnvelope({
    required String label,
    required Object? sourceEpoch,
    required Object? providerEpoch,
    required Object? connectionEpoch,
    required Object? generation,
    required Object? revision,
    required Object? envelopeId,
    required Object? envelopeDigest,
  }) async {
    final allNull = <Object?>[
      sourceEpoch,
      providerEpoch,
      connectionEpoch,
      generation,
      envelopeId,
      envelopeDigest,
    ].every((value) => value == null);
    if (revision == -1 && allNull) return;
    if (sourceEpoch is! String ||
        providerEpoch is! String ||
        connectionEpoch is! String ||
        generation is! int ||
        revision is! int ||
        envelopeId is! String ||
        envelopeDigest is! String) {
      throw ConversationRepositoryException(
        RepositoryFailureCode.invalidDatabaseIdentity,
        '$label envelope binding is incomplete',
      );
    }
    final rows = await db.query(
      'committed_envelope',
      columns: const <String>[
        'envelope_digest',
        'connection_epoch',
        'runtime_authority_generation',
        'source_revision',
      ],
      where:
          '${_keyWhere()} AND source_epoch = ? AND provider_instance_epoch = ? AND envelope_id = ?',
      whereArgs: <Object?>[
        ..._keyArgs(key),
        sourceEpoch,
        providerEpoch,
        envelopeId,
      ],
      limit: 1,
    );
    if (rows.length != 1 ||
        rows.single['envelope_digest'] != envelopeDigest ||
        rows.single['connection_epoch'] != connectionEpoch ||
        rows.single['runtime_authority_generation'] != generation ||
        rows.single['source_revision'] != revision) {
      throw ConversationRepositoryException(
        RepositoryFailureCode.invalidDatabaseIdentity,
        '$label envelope binding does not match its immutable proof row',
      );
    }
    preserved['$sourceEpoch\u0000$providerEpoch\u0000$envelopeId'] =
        envelopeDigest;
  }

  if (state != null) {
    _validateThreadStateBinding(state);
    if (state['current_envelope_id'] != null) {
      await preserveBoundEnvelope(
        label: 'current',
        sourceEpoch: state['source_epoch'],
        providerEpoch: state['provider_instance_epoch'],
        connectionEpoch: state['connection_epoch'],
        generation: state['runtime_authority_generation'],
        revision: state['source_revision'],
        envelopeId: state['current_envelope_id'],
        envelopeDigest: state['current_envelope_digest'],
      );
    }
    await preserveBoundEnvelope(
      label: 'last-good',
      sourceEpoch: state['last_good_source_epoch'],
      providerEpoch: state['last_good_provider_instance_epoch'],
      connectionEpoch: state['last_good_connection_epoch'],
      generation: state['last_good_runtime_authority_generation'],
      revision: state['last_good_revision'],
      envelopeId: state['last_good_envelope_id'],
      envelopeDigest: state['last_good_envelope_digest'],
    );
  }

  final rows = await db.query(
    'committed_envelope',
    columns: const <String>[
      'source_epoch',
      'provider_instance_epoch',
      'envelope_id',
      'connection_epoch',
      'source_revision',
    ],
    where: _keyWhere(),
    whereArgs: _keyArgs(key),
    orderBy: 'committed_at ASC, envelope_id ASC',
    limit: _repositoryGcBatchSize,
  );
  for (final row in rows) {
    final sourceEpoch = row['source_epoch'];
    final providerEpoch = row['provider_instance_epoch'];
    final envelopeId = row['envelope_id'];
    final connectionEpoch = row['connection_epoch'];
    final revision = row['source_revision'];
    if (sourceEpoch is! String ||
        providerEpoch is! String ||
        envelopeId is! String ||
        connectionEpoch is! String ||
        revision is! int) {
      continue;
    }
    final identity = '$sourceEpoch\u0000$providerEpoch\u0000$envelopeId';
    if (preserved.containsKey(identity)) continue;
    final pending = await _hasPendingOutbox(
      db,
      key,
      sourceEpoch: sourceEpoch,
      providerEpoch: providerEpoch,
      domain: 'materialization',
      operationId: envelopeId,
    );
    if (pending) continue;
    await db.delete(
      'committed_envelope',
      where:
          '${_keyWhere()} AND source_epoch = ? AND provider_instance_epoch = ? AND envelope_id = ?',
      whereArgs: <Object?>[
        ..._keyArgs(key),
        sourceEpoch,
        providerEpoch,
        envelopeId,
      ],
    );
  }
}

Future<bool> _isRetiredStagingFence(
  DatabaseExecutor db,
  ThreadKey key,
  Map<String, Object?> row,
) async {
  final checks = <String, Object?>{
    'connection': row['connection_epoch'],
    'source': row['source_epoch'],
    'provider_instance': row['provider_instance_epoch'],
  };
  for (final entry in checks.entries) {
    if (entry.value is! String) continue;
    final rows = await db.query(
      'retired_epoch',
      columns: const <String>['epoch_value'],
      where: '${_partitionWhere()} AND epoch_kind = ? AND epoch_value = ?',
      whereArgs: <Object?>[
        ..._partitionArgs(key.partition),
        entry.key,
        entry.value,
      ],
      limit: 1,
    );
    if (rows.isNotEmpty) return true;
  }
  return false;
}

Future<void> _deleteStagingBatch(
  DatabaseExecutor db,
  ThreadKey key,
  Map<String, Object?>? state,
) async {
  final rows = await db.query(
    'staged_materialization',
    columns: const <String>[
      'source_epoch',
      'provider_instance_epoch',
      'materialization_id',
      'connection_epoch',
      'source_revision',
    ],
    where: _keyWhere(),
    whereArgs: _keyArgs(key),
    orderBy: 'begun_at DESC, materialization_id DESC',
    limit: _repositoryGcBatchSize,
  );
  var keptCurrent = false;
  var keptFuture = false;
  var keptAny = false;
  for (final row in rows) {
    final sourceEpoch = row['source_epoch'];
    final providerEpoch = row['provider_instance_epoch'];
    final materializationId = row['materialization_id'];
    final revision = row['source_revision'];
    if (sourceEpoch is! String ||
        providerEpoch is! String ||
        materializationId is! String ||
        revision is! int) {
      continue;
    }
    final retired = await _isRetiredStagingFence(db, key, row);
    final current =
        state != null &&
        sourceEpoch == state['source_epoch'] &&
        providerEpoch == state['provider_instance_epoch'];
    final future =
        state == null || revision >= (state['source_revision']! as int);
    final keep =
        !retired &&
        (state == null
            ? !keptAny
            : current
            ? !keptCurrent && future
            : !keptFuture && future);
    if (keep) {
      keptAny = true;
      if (current) {
        keptCurrent = true;
      } else {
        keptFuture = true;
      }
      continue;
    }
    await db.delete(
      'staged_materialization',
      where:
          '${_keyWhere()} AND source_epoch = ? AND provider_instance_epoch = ? AND materialization_id = ?',
      whereArgs: <Object?>[
        ..._keyArgs(key),
        sourceEpoch,
        providerEpoch,
        materializationId,
      ],
    );
  }
}

Future<void> _validateCapacity(
  DatabaseExecutor db,
  ConversationRepository repository,
  ThreadKey key,
) async {
  // replica_usage is maintained by exact SQLite triggers, so the normal
  // mutation path is constant-time.  Rebuildable GC runs only at/near the
  // mutable budget and is capped to a small batch.  Anti-rollback evidence is
  // intentionally retained forever but excluded from this reclaimable quota;
  // otherwise an unbounded source-epoch history could permanently brick new
  // writes while still requiring every evidence row for safe rejection.
  final usage = await _readTrackedUsage(repository, db, key);
  if (usage.mutableEntries > repository.maxEntriesPerThread ||
      usage.mutableBytes > repository.maxBytesPerThread) {
    await _validateCapacityScan(db, repository, key);
  }
}

const _repositoryGcPassesPerMutation = 2;

Future<void> _prepareCapacity(
  Database db,
  ConversationRepository repository,
  ThreadKey key,
) async {
  for (var pass = 0; pass < _repositoryGcPassesPerMutation; pass += 1) {
    final usage = await _readTrackedUsage(repository, db, key);
    if (!_usageNearCapacity(usage, repository) &&
        usage.mutableEntries <= repository.maxEntriesPerThread &&
        usage.mutableBytes <= repository.maxBytesPerThread) {
      return;
    }
    // Each pass has its own transaction.  Reclaimable rows therefore remain
    // reclaimed even when the user mutation that triggered pressure later
    // fails or is rolled back.
    await db.transaction((txn) async {
      await _assertWriterLease(txn, repository);
      await _collectRepositoryGarbage(txn, key);
    });
  }
  final usage = await _readTrackedUsage(repository, db, key);
  if (usage.mutableEntries > repository.maxEntriesPerThread ||
      usage.mutableBytes > repository.maxBytesPerThread) {
    await _validateCapacityScan(db, repository, key);
  }
}

Future<int> _readDataVersion(DatabaseExecutor db) async {
  final rows = await db.rawQuery('PRAGMA data_version');
  if (rows.length != 1 || rows.single['data_version'] is! int) {
    throw const ConversationRepositoryException(
      RepositoryFailureCode.invalidDatabaseIdentity,
      'SQLite data_version is unavailable for usage attestation',
    );
  }
  return rows.single['data_version']! as int;
}

Future<_TrackedUsage> _readTrackedUsage(
  ConversationRepository repository,
  DatabaseExecutor db,
  ThreadKey key,
) async {
  final dataVersion = await _readDataVersion(db);
  if (repository._usageDataVersion != dataVersion) {
    // SQLite data_version is stable across this connection's own commits and
    // changes when another connection commits.  Any external commit can
    // affect an arbitrary partition, so invalidate every cached scope.
    repository._usageDataVersion = dataVersion;
    repository._verifiedUsageKeys.clear();
    repository._verifiedUsagePartitions.clear();
  }
  final usage = await _readTrackedUsageRows(db, key);
  final needsIndependentAttestation =
      !repository._verifiedUsageKeys.contains(key) ||
      !repository._verifiedUsagePartitions.contains(key.partition);
  if (needsIndependentAttestation) {
    final recomputed = await _recomputeTrackedUsage(db, key);
    if (recomputed.mutableEntries != usage.mutableEntries ||
        recomputed.mutableBytes != usage.mutableBytes ||
        recomputed.retiredEntries != usage.retiredEntries ||
        recomputed.retiredBytes != usage.retiredBytes) {
      throw const ConversationRepositoryException(
        RepositoryFailureCode.invalidDatabaseIdentity,
        'replica usage counters do not match independently recomputed rows',
      );
    }
    repository._verifiedUsageKeys.add(key);
    repository._verifiedUsagePartitions.add(key.partition);
  }
  return usage;
}

Future<_TrackedUsage> _readTrackedUsageRows(
  DatabaseExecutor db,
  ThreadKey key,
) async {
  final usageRows = await db.query(
    'replica_usage',
    columns: const <String>[
      'entry_count',
      'byte_count',
      'guard_entry_count',
      'guard_byte_count',
    ],
    where: _keyWhere(),
    whereArgs: _keyArgs(key),
    limit: 1,
  );
  final retiredRows = await db.query(
    'replica_usage',
    columns: const <String>[
      'entry_count',
      'byte_count',
      'guard_entry_count',
      'guard_byte_count',
    ],
    where: '${_partitionWhere()} AND provider_thread_id = ?',
    whereArgs: <Object?>[..._partitionArgs(key.partition), ''],
    limit: 1,
  );
  final usageAuditRows = await db.query(
    'replica_usage_audit',
    columns: const <String>['entry_count', 'byte_count'],
    where: _keyWhere(),
    whereArgs: _keyArgs(key),
    limit: 1,
  );
  final retiredAuditRows = await db.query(
    'replica_usage_audit',
    columns: const <String>['entry_count', 'byte_count'],
    where: '${_partitionWhere()} AND provider_thread_id = ?',
    whereArgs: <Object?>[..._partitionArgs(key.partition), ''],
    limit: 1,
  );
  final usageRow = usageRows.isEmpty ? null : usageRows.single;
  final retiredRow = retiredRows.isEmpty ? null : retiredRows.single;
  final usageAuditRow = usageAuditRows.isEmpty ? null : usageAuditRows.single;
  final retiredAuditRow = retiredAuditRows.isEmpty
      ? null
      : retiredAuditRows.single;
  if (usageRow == null) {
    for (final table in _usageTables.where(
      (table) => table != 'retired_epoch',
    )) {
      final rows = await db.rawQuery(
        'SELECT 1 FROM $table WHERE ${_keyWhere()} LIMIT 1',
        _keyArgs(key),
      );
      if (rows.isNotEmpty) {
        throw const ConversationRepositoryException(
          RepositoryFailureCode.invalidDatabaseIdentity,
          'thread replica usage row is missing for durable data',
        );
      }
    }
  }
  if (retiredRow == null) {
    final rows = await db.rawQuery(
      'SELECT 1 FROM retired_epoch WHERE ${_partitionWhere()} LIMIT 1',
      _partitionArgs(key.partition),
    );
    if (rows.isNotEmpty) {
      throw const ConversationRepositoryException(
        RepositoryFailureCode.invalidDatabaseIdentity,
        'partition replica usage row is missing for retired evidence',
      );
    }
  }
  void verifyUsageRow(
    Map<String, Object?>? row,
    Map<String, Object?>? auditRow,
    String label,
  ) {
    if ((row == null) != (auditRow == null)) {
      throw ConversationRepositoryException(
        RepositoryFailureCode.invalidDatabaseIdentity,
        '$label replica usage audit mirror is missing',
      );
    }
    if (row == null || auditRow == null) return;
    final entries = _asInt(row['entry_count']);
    final bytes = _asInt(row['byte_count']);
    if (entries < 0 ||
        bytes < 0 ||
        _asInt(row['guard_entry_count']) != entries + _usageGuardEntryOffset ||
        _asInt(row['guard_byte_count']) != bytes + _usageGuardByteOffset ||
        _asInt(auditRow['entry_count']) != entries ||
        _asInt(auditRow['byte_count']) != bytes) {
      throw ConversationRepositoryException(
        RepositoryFailureCode.invalidDatabaseIdentity,
        '$label replica usage accounting or audit mirror is inconsistent',
      );
    }
  }

  verifyUsageRow(usageRow, usageAuditRow, 'thread');
  verifyUsageRow(retiredRow, retiredAuditRow, 'partition');
  return _TrackedUsage(
    mutableEntries: usageRow == null ? 0 : _asInt(usageRow['entry_count']),
    mutableBytes: usageRow == null ? 0 : _asInt(usageRow['byte_count']),
    retiredEntries: retiredRow == null ? 0 : _asInt(retiredRow['entry_count']),
    retiredBytes: retiredRow == null ? 0 : _asInt(retiredRow['byte_count']),
  );
}

bool _usageNearCapacity(
  _TrackedUsage usage,
  ConversationRepository repository,
) {
  return usage.mutableEntries * 4 >= repository.maxEntriesPerThread * 3 ||
      usage.mutableBytes * 4 >= repository.maxBytesPerThread * 3;
}

Future<_TrackedUsage> _recomputeTrackedUsage(
  DatabaseExecutor db,
  ThreadKey key,
) async {
  var entries = 0;
  var bytes = 0;
  Future<void> add(
    String table,
    String countExpression,
    String byteExpression,
    List<Object?> args,
  ) async {
    final rows = await db.rawQuery(
      'SELECT $countExpression AS row_count, $byteExpression AS byte_count FROM $table WHERE ${_keyWhere()}',
      args,
    );
    entries += _asInt(rows.single['row_count']);
    bytes += _asInt(rows.single['byte_count']);
  }

  await add(
    'canonical_item',
    'COUNT(*)',
    _capacityBytes(<String>[
      'bridge_identity_id',
      'bridge_instance_id',
      'codex_source_id',
      'provider_thread_id',
      'provider_turn_id',
      'provider_item_id',
      'turn_ordinal',
      'item_ordinal',
      'timeline_ordinal',
      'kind',
      'normalized_payload_json',
      'presentation_projection_json',
      'item_digest',
      'byte_size',
      'source_revision',
    ]),
    _keyArgs(key),
  );
  await add(
    'typed_gap',
    'COUNT(*)',
    _capacityBytes(<String>[
      'bridge_identity_id',
      'bridge_instance_id',
      'codex_source_id',
      'provider_thread_id',
      'gap_id',
      'kind',
      'start_ordinal',
      'end_ordinal',
      'details_json',
      'gap_digest',
      'is_active',
      'source_revision',
    ]),
    _keyArgs(key),
  );
  await add(
    'committed_envelope',
    'COUNT(*)',
    _capacityBytes(<String>[
      'bridge_identity_id',
      'bridge_instance_id',
      'codex_source_id',
      'provider_thread_id',
      'source_epoch',
      'provider_instance_epoch',
      'envelope_id',
      'envelope_digest',
      'connection_epoch',
      'runtime_authority_generation',
      'source_revision',
      'page_index',
      'page_count',
      'final_page_digest',
      'page_manifest_digest',
      'item_count',
      'gap_count',
      'island_count',
      'structural_coverage',
      'payload_coverage',
      'lower_ordinal',
      'upper_ordinal',
      'order_digest',
      'last_good_disposition',
      'provider_read_evidence_digest',
      'empty_proof_digest',
      'committed_at',
    ]),
    _keyArgs(key),
  );
  await add(
    'staged_materialization',
    'COUNT(*)',
    _capacityBytes(<String>[
      'bridge_identity_id',
      'bridge_instance_id',
      'codex_source_id',
      'provider_thread_id',
      'source_epoch',
      'provider_instance_epoch',
      'materialization_id',
      'connection_epoch',
      'runtime_authority_generation',
      'source_revision',
      'structural_coverage',
      'payload_coverage',
      'lower_ordinal',
      'upper_ordinal',
      'health',
      'problem_code',
      'is_snapshot',
      'page_count',
      'total_item_count',
      'provider_read_evidence_digest',
      'provider_read_method',
      'provider_build_id',
      'provider_result_kind',
      'provider_result_digest',
      'provider_coverage_digest',
      'request_id',
      'read_kind',
      'empty_proof_kind',
      'empty_provider_revision',
      'empty_observation_digest',
      'empty_proof_digest',
      'begin_digest',
      'begun_at',
    ]),
    _keyArgs(key),
  );
  await add(
    'staged_materialization_page',
    'COUNT(*)',
    _capacityBytes(<String>[
      'bridge_identity_id',
      'bridge_instance_id',
      'codex_source_id',
      'provider_thread_id',
      'source_epoch',
      'provider_instance_epoch',
      'materialization_id',
      'page_index',
      'connection_epoch',
      'runtime_authority_generation',
      'source_revision',
      'page_count',
      'previous_page_digest',
      'page_digest',
      'body_json',
      'body_byte_size',
      'staged_at',
    ]),
    _keyArgs(key),
  );
  await add(
    'thread_state',
    'COUNT(*)',
    _capacityBytes(<String>[
      'bridge_identity_id',
      'bridge_instance_id',
      'codex_source_id',
      'provider_thread_id',
      'state_kind',
      'connection_epoch',
      'source_epoch',
      'provider_instance_epoch',
      'runtime_authority_generation',
      'source_revision',
      'current_envelope_id',
      'current_envelope_digest',
      'last_good_revision',
      'last_good_connection_epoch',
      'last_good_source_epoch',
      'last_good_provider_instance_epoch',
      'last_good_runtime_authority_generation',
      'last_good_envelope_id',
      'last_good_envelope_digest',
      'structural_coverage',
      'payload_coverage',
      'lower_ordinal',
      'upper_ordinal',
      'health',
      'problem_code',
      'updated_at',
    ]),
    _keyArgs(key),
  );
  await add(
    'operation_projection',
    'COUNT(*)',
    _capacityBytes(<String>[
      'bridge_identity_id',
      'bridge_instance_id',
      'codex_source_id',
      'provider_thread_id',
      'operation_id',
      'revision',
      'state',
      'is_terminal',
      'value_json',
      'value_digest',
      'is_active',
      'gc_eligible',
      'snapshot_marker',
      'source_projection_id',
    ]),
    _keyArgs(key),
  );
  await add(
    'queue_entry_projection',
    'COUNT(*)',
    _capacityBytes(<String>[
      'bridge_identity_id',
      'bridge_instance_id',
      'codex_source_id',
      'provider_thread_id',
      'queue_entry_id',
      'operation_id',
      'revision',
      'position',
      'state',
      'value_json',
      'value_digest',
      'is_active',
      'gc_eligible',
      'snapshot_marker',
      'source_projection_id',
    ]),
    _keyArgs(key),
  );
  await add(
    'interaction_projection',
    'COUNT(*)',
    _capacityBytes(<String>[
      'bridge_identity_id',
      'bridge_instance_id',
      'codex_source_id',
      'provider_thread_id',
      'interaction_id',
      'revision',
      'kind',
      'state',
      'claim_actor_id',
      'claim_expires_at',
      'value_json',
      'value_digest',
      'is_active',
      'gc_eligible',
      'snapshot_marker',
      'source_projection_id',
    ]),
    _keyArgs(key),
  );
  await add(
    'projection_identity',
    'COUNT(*)',
    _capacityBytes(<String>[
      'bridge_identity_id',
      'bridge_instance_id',
      'codex_source_id',
      'provider_thread_id',
      'projection_id',
      'connection_epoch',
      'source_epoch',
      'provider_instance_epoch',
      'runtime_authority_generation',
      'source_revision',
      'projection_digest',
      'disposition',
    ]),
    _keyArgs(key),
  );
  await add(
    'projection_inbox',
    'COUNT(*)',
    _capacityBytes(<String>[
      'bridge_identity_id',
      'bridge_instance_id',
      'codex_source_id',
      'provider_thread_id',
      'projection_id',
      'connection_epoch',
      'source_epoch',
      'provider_instance_epoch',
      'runtime_authority_generation',
      'source_revision',
      'projection_digest',
      'payload_json',
      'state',
      'gc_eligible',
      'admitted_at',
    ]),
    _keyArgs(key),
  );
  await add(
    'projection_head',
    'COUNT(*)',
    _capacityBytes(<String>[
      'bridge_identity_id',
      'bridge_instance_id',
      'codex_source_id',
      'provider_thread_id',
      'connection_epoch',
      'source_epoch',
      'provider_instance_epoch',
      'runtime_authority_generation',
      'source_revision',
      'projection_id',
      'projection_digest',
      'operation_snapshot_complete',
      'queue_snapshot_complete',
      'interaction_snapshot_complete',
      'operation_snapshot_marker',
      'queue_snapshot_marker',
      'interaction_snapshot_marker',
      'updated_at',
    ]),
    _keyArgs(key),
  );
  await add(
    'publication_outbox',
    'COUNT(*)',
    _capacityBytes(<String>[
      'bridge_identity_id',
      'bridge_instance_id',
      'codex_source_id',
      'provider_thread_id',
      'source_epoch',
      'provider_instance_epoch',
      'domain',
      'operation_id',
      'event_id',
      'applied_digest',
      'phase',
      'notification_state',
      'delivery_token',
      'delivery_claimed_at',
      'applied_at',
      'published_at',
    ]),
    _keyArgs(key),
  );
  final retiredRows = await db.rawQuery(
    'SELECT COUNT(*) AS row_count, '
    '${_capacityBytes(_schemaColumns['retired_epoch']!.map((column) => column.name).toList())} AS byte_count '
    'FROM retired_epoch WHERE ${_partitionWhere()}',
    _partitionArgs(key.partition),
  );
  final retired = retiredRows.single;
  return _TrackedUsage(
    mutableEntries: entries,
    mutableBytes: bytes,
    retiredEntries: _asInt(retired['row_count']),
    retiredBytes: _asInt(retired['byte_count']),
  );
}

Future<void> _validateCapacityScan(
  DatabaseExecutor db,
  ConversationRepository repository,
  ThreadKey key,
) async {
  final usage = await _recomputeTrackedUsage(db, key);
  if (usage.mutableEntries > repository.maxEntriesPerThread ||
      usage.mutableBytes > repository.maxBytesPerThread) {
    throw const ConversationRepositoryException(
      RepositoryFailureCode.capacityExceeded,
      'conversation replica exceeds its bounded row/byte budget',
    );
  }
}

String _capacityBytes(List<String> columns) {
  return 'COALESCE(SUM(${_capacityRow(columns)}), 0)';
}

String _capacityRow(List<String> columns) {
  return columns
      .map((column) => 'COALESCE(LENGTH(CAST($column AS BLOB)), 0)')
      .join(' + ');
}

void _validateReadLimit(int limit) {
  if (limit <= 0 || limit > ConversationRepository.maxWindowSize) {
    _invalid(
      'read limit must be between 1 and ${ConversationRepository.maxWindowSize}',
    );
  }
}
