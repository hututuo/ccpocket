part of 'conversation_repository.dart';

Future<StagingReceipt> _beginMaterialization(
  ConversationRepository repository,
  MaterializationBegin begin,
) async {
  repository._requireDatabase();
  repository._requireContract();
  _validateBegin(repository, begin);
  final beginArtifact = repository._verifiedPreimage(
    repository._contractMapper.begin(begin),
    'materialization begin',
  );
  final emptyArtifact = begin.emptyProof == null
      ? null
      : repository._verifiedPreimage(
          repository._contractMapper.emptyProof(begin.emptyProof!),
          'empty proof',
        );
  return repository._serialize((db) async {
    await _prepareCapacity(db, repository, begin.key);
    return db.transaction((txn) async {
      await _assertWriterLease(txn, repository);
      final existing = await txn.query(
        'staged_materialization',
        columns: const <String>['begin_digest'],
        where: '${_stagingWhere()} AND materialization_id = ?',
        whereArgs: <Object?>[
          ..._stagingArgs(
            begin.key,
            begin.fence.sourceEpoch,
            begin.fence.providerInstanceEpoch,
          ),
          begin.materializationId,
        ],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        if (existing.single['begin_digest'] != beginArtifact.digest) {
          throw const ConversationRepositoryException(
            RepositoryFailureCode.identityConflict,
            'materialization identity was reused with another begin preimage',
          );
        }
        return StagingReceipt(
          materializationId: begin.materializationId,
          wasDuplicate: true,
        );
      }
      final state = await _readThreadState(txn, begin.key);
      _validateFenceTransitionAgainstState(
        state,
        begin.fence,
        begin.sourceRevision,
      );
      await txn.insert('staged_materialization', <String, Object?>{
        ..._keyColumns(begin.key),
        'source_epoch': begin.fence.sourceEpoch,
        'provider_instance_epoch': begin.fence.providerInstanceEpoch,
        'materialization_id': begin.materializationId,
        'connection_epoch': begin.fence.connectionEpoch,
        'runtime_authority_generation': begin.fence.runtimeAuthorityGeneration,
        'source_revision': begin.sourceRevision,
        'structural_coverage': begin.coverage.structural.name,
        'payload_coverage': begin.coverage.payload.name,
        'lower_ordinal': begin.coverage.lowerOrdinal,
        'upper_ordinal': begin.coverage.upperOrdinal,
        'health': begin.health.name,
        'problem_code': begin.problemCode,
        'is_snapshot': begin.isSnapshot ? 1 : 0,
        'page_count': begin.pageCount,
        'total_item_count': begin.totalItemCount,
        'provider_read_evidence_digest': begin.providerReadEvidenceDigest,
        'provider_read_method': begin.providerReadEvidence!.method,
        'provider_build_id': begin.providerReadEvidence!.buildId,
        'provider_result_kind': begin.providerReadEvidence!.resultKind,
        'provider_result_digest': begin.providerReadEvidence!.resultDigest,
        'provider_coverage_digest': begin.providerReadEvidence!.coverageDigest,
        'request_id': begin.requestId,
        'read_kind': begin.readKind,
        'empty_proof_kind': begin.emptyProof?.proofKind.name,
        'empty_provider_revision': begin.emptyProof?.providerRevision,
        'empty_observation_digest': begin.emptyProof?.observationDigest,
        'empty_proof_digest': emptyArtifact?.digest,
        'begin_digest': beginArtifact.digest,
        'begun_at': DateTime.now().millisecondsSinceEpoch,
      });
      await _validateCapacity(txn, repository, begin.key);
      return StagingReceipt(
        materializationId: begin.materializationId,
        wasDuplicate: false,
      );
    });
  });
}

Future<StagingReceipt> _stageMaterializationPage(
  ConversationRepository repository,
  MaterializationPage page,
) async {
  repository._requireDatabase();
  repository._requireContract();
  _validatePage(repository, page);
  final artifact = repository._verifiedPreimage(
    repository._contractMapper.pageBody(page.body),
    'page body',
  );
  final bodyJson = _storageJson(_pageStorageValue(page.body), 'page body');
  final bodyBytes = utf8.encode(bodyJson).length;
  return repository._serialize((db) async {
    await _prepareCapacity(db, repository, page.key);
    return db.transaction((txn) async {
      await _assertWriterLease(txn, repository);
      final begin = await _readStagedBegin(
        txn,
        page.key,
        page.fence.sourceEpoch,
        page.fence.providerInstanceEpoch,
        page.materializationId,
      );
      if (begin == null) {
        throw const ConversationRepositoryException(
          RepositoryFailureCode.materializationNotFound,
          'materialization begin is missing',
        );
      }
      _validatePageAgainstBegin(page, begin);
      final existing = await txn.query(
        'staged_materialization_page',
        columns: const <String>[
          'connection_epoch',
          'runtime_authority_generation',
          'source_revision',
          'page_count',
          'previous_page_digest',
          'page_digest',
          'body_json',
          'body_byte_size',
        ],
        where:
            '${_stagingWhere()} AND materialization_id = ? AND page_index = ?',
        whereArgs: <Object?>[
          ..._stagingArgs(
            page.key,
            page.fence.sourceEpoch,
            page.fence.providerInstanceEpoch,
          ),
          page.materializationId,
          page.pageIndex,
        ],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        final row = existing.single;
        final expected = <String, Object?>{
          'connection_epoch': page.fence.connectionEpoch,
          'runtime_authority_generation': page.fence.runtimeAuthorityGeneration,
          'source_revision': page.sourceRevision,
          'page_count': page.pageCount,
          'previous_page_digest': page.previousPageDigest,
          'page_digest': artifact.digest,
          'body_json': bodyJson,
          'body_byte_size': artifact.bytes.length,
        };
        if (expected.entries.any((entry) => row[entry.key] != entry.value)) {
          throw const ConversationRepositoryException(
            RepositoryFailureCode.identityConflict,
            'page identity was reused with another exact page header/body',
          );
        }
        return StagingReceipt(
          materializationId: page.materializationId,
          wasDuplicate: true,
        );
      }
      await txn.insert('staged_materialization_page', <String, Object?>{
        ..._keyColumns(page.key),
        'source_epoch': page.fence.sourceEpoch,
        'provider_instance_epoch': page.fence.providerInstanceEpoch,
        'materialization_id': page.materializationId,
        'page_index': page.pageIndex,
        'connection_epoch': page.fence.connectionEpoch,
        'runtime_authority_generation': page.fence.runtimeAuthorityGeneration,
        'source_revision': page.sourceRevision,
        'page_count': page.pageCount,
        'previous_page_digest': page.previousPageDigest,
        'page_digest': artifact.digest,
        'body_json': bodyJson,
        'body_byte_size': artifact.bytes.length,
        'staged_at': DateTime.now().millisecondsSinceEpoch,
      });
      if (bodyBytes > ConversationRepository.hardMaxBytes) {
        throw const ConversationRepositoryException(
          RepositoryFailureCode.capacityExceeded,
          'stored page body exceeds the hard byte bound',
        );
      }
      await _validateCapacity(txn, repository, page.key);
      return StagingReceipt(
        materializationId: page.materializationId,
        wasDuplicate: false,
      );
    });
  });
}

Future<void> _discardMaterialization(
  ConversationRepository repository,
  MaterializationBegin begin,
) async {
  repository._requireDatabase();
  _validateMaterializationIdentity(
    key: begin.key,
    materializationId: begin.materializationId,
    fence: begin.fence,
    sourceRevision: begin.sourceRevision,
    pageCount: begin.pageCount,
  );
  await repository._serialize((db) async {
    await db.transaction((txn) async {
      await _assertWriterLease(txn, repository);
      final where = '${_stagingWhere()} AND materialization_id = ?';
      final args = <Object?>[
        ..._stagingArgs(
          begin.key,
          begin.fence.sourceEpoch,
          begin.fence.providerInstanceEpoch,
        ),
        begin.materializationId,
      ];
      await txn.delete(
        'staged_materialization_page',
        where: where,
        whereArgs: args,
      );
      await txn.delete('staged_materialization', where: where, whereArgs: args);
    });
  });
}

Future<CommitReceipt> _commitMaterialization(
  ConversationRepository repository,
  MaterializationCommit commit, {
  int? readLimit,
}) async {
  repository._requireDatabase();
  repository._requireContract();
  _validateCommit(commit);
  final effectiveLimit = readLimit ?? repository.defaultWindowSize;
  _validateReadLimit(effectiveLimit);
  late _CanonicalEnvelope envelope;
  final wasDuplicate = await repository._serialize((db) async {
    await _prepareCapacity(db, repository, commit.key);
    return db.transaction((txn) async {
      await _assertWriterLease(txn, repository);
      final finalized = await txn.query(
        'committed_envelope',
        columns: const <String>[
          'envelope_digest',
          'connection_epoch',
          'runtime_authority_generation',
          'source_revision',
          'page_count',
          'final_page_digest',
          'page_manifest_digest',
          'provider_read_evidence_digest',
          'empty_proof_digest',
        ],
        where:
            '${_keyWhere()} AND source_epoch = ? AND provider_instance_epoch = ? AND envelope_id = ?',
        whereArgs: <Object?>[
          ..._keyArgs(commit.key),
          commit.fence.sourceEpoch,
          commit.fence.providerInstanceEpoch,
          commit.materializationId,
        ],
        limit: 1,
      );
      if (finalized.isNotEmpty) {
        final row = finalized.single;
        final expected = <String, Object?>{
          'connection_epoch': commit.fence.connectionEpoch,
          'runtime_authority_generation':
              commit.fence.runtimeAuthorityGeneration,
          'source_revision': commit.sourceRevision,
          'page_count': commit.pageCount,
          'final_page_digest': commit.finalPageDigest,
          'page_manifest_digest': commit.pageManifestDigest,
          'provider_read_evidence_digest': commit.providerReadEvidenceDigest,
          'empty_proof_digest': commit.emptyProofDigest,
        };
        for (final entry in expected.entries) {
          if (row[entry.key] != entry.value) {
            throw const ConversationRepositoryException(
              RepositoryFailureCode.identityConflict,
              'committed materialization identity was reused with different content',
            );
          }
        }
        await _deleteStaging(txn, commit);
        return true;
      }
      final begin = await _readStagedBegin(
        txn,
        commit.key,
        commit.fence.sourceEpoch,
        commit.fence.providerInstanceEpoch,
        commit.materializationId,
      );
      if (begin == null) {
        throw const ConversationRepositoryException(
          RepositoryFailureCode.materializationNotFound,
          'materialization begin is missing',
        );
      }
      _validateCommitAgainstBegin(commit, begin);
      final pages = await txn.query(
        'staged_materialization_page',
        where: '${_stagingWhere()} AND materialization_id = ?',
        whereArgs: <Object?>[
          ..._stagingArgs(
            commit.key,
            commit.fence.sourceEpoch,
            commit.fence.providerInstanceEpoch,
          ),
          commit.materializationId,
        ],
        orderBy: 'page_index ASC',
      );
      envelope = _sealMaterialization(repository, begin, pages, commit);
      _validateEnvelope(repository, envelope);
      await repository.faultHook?.call(
        RepositoryFaultStage.afterValidation,
        envelope.envelopeId,
      );
      final envelopeArtifact = repository._verifiedPreimage(
        repository._contractMapper.envelope(
          RepositoryEnvelopeInput(
            envelopeId: envelope.envelopeId,
            key: envelope.key,
            fence: envelope.fence,
            sourceRevision: envelope.sourceRevision,
            coverage: envelope.coverage,
            health: envelope.health,
            problemCode: envelope.problemCode,
            isSnapshot: envelope.isSnapshot,
            pageCount: envelope.pageCount,
            totalItemCount: envelope.totalItemCount,
            providerReadEvidenceDigest: envelope.providerReadEvidenceDigest,
            emptyProof: envelope.emptyProof,
            items: envelope.items,
            gaps: envelope.gaps,
          ),
        ),
        'materialization envelope',
      );
      final orderArtifact = repository._verifiedPreimage(
        repository._contractMapper.orderProof(
          RepositoryOrderInput(
            key: envelope.key,
            materializationId: envelope.envelopeId,
            items: envelope.items,
            gaps: envelope.gaps,
          ),
        ),
        'materialization order proof',
      );
      await _applyEnvelope(
        txn,
        repository,
        envelope,
        envelopeArtifact.digest,
        orderArtifact.digest,
        finalPageDigest: commit.finalPageDigest,
        pageManifestDigest: commit.pageManifestDigest,
      );
      await _deleteStaging(txn, commit);
      await _validateCapacity(txn, repository, commit.key);
      await repository.faultHook?.call(
        RepositoryFaultStage.afterTransactionWrites,
        envelope.envelopeId,
      );
      return false;
    });
  });
  if (!wasDuplicate) {
    await repository.faultHook?.call(
      RepositoryFaultStage.afterCommit,
      envelope.envelopeId,
    );
  }
  final publication = await _publishPublicationOutbox(
    repository,
    commit.key,
    sourceEpoch: commit.fence.sourceEpoch,
    providerInstanceEpoch: commit.fence.providerInstanceEpoch,
    domain: 'materialization',
    operationId: commit.materializationId,
    readLimit: effectiveLimit,
  );
  final window = await _readWindow(
    repository,
    commit.key,
    limit: effectiveLimit,
    publicationEventId: publication.eventId,
  );
  return CommitReceipt(
    envelopeId: commit.materializationId,
    wasDuplicate: wasDuplicate,
    wasPublished: publication.wasPublished,
    window: window,
    publicationEventId: publication.eventId,
  );
}

Future<void> _insertPublicationOutbox(
  Transaction txn, {
  required ThreadKey key,
  required String sourceEpoch,
  required String providerInstanceEpoch,
  required String domain,
  required String operationId,
  required String appliedDigest,
}) async {
  final eventId = _publicationEventId(
    key: key,
    sourceEpoch: sourceEpoch,
    providerInstanceEpoch: providerInstanceEpoch,
    domain: domain,
    operationId: operationId,
  );
  final existing = await txn.query(
    'publication_outbox',
    columns: const <String>['applied_digest', 'event_id'],
    where: _outboxWhere(),
    whereArgs: _outboxArgs(
      key,
      sourceEpoch,
      providerInstanceEpoch,
      domain,
      operationId,
    ),
    limit: 1,
  );
  if (existing.isNotEmpty) {
    if (existing.single['applied_digest'] != appliedDigest ||
        existing.single['event_id'] != eventId) {
      throw const ConversationRepositoryException(
        RepositoryFailureCode.identityConflict,
        'publication outbox identity was reused with another event identity or digest',
      );
    }
    return;
  }
  final now = DateTime.now().millisecondsSinceEpoch;
  await txn.insert('publication_outbox', <String, Object?>{
    ..._keyColumns(key),
    'source_epoch': sourceEpoch,
    'provider_instance_epoch': providerInstanceEpoch,
    'domain': domain,
    'operation_id': operationId,
    'event_id': eventId,
    'applied_digest': appliedDigest,
    'phase': 'applied',
    'notification_state': 'pending',
    'delivery_token': null,
    'delivery_claimed_at': null,
    'applied_at': now,
    'published_at': null,
  });
}

class _PublicationResult {
  const _PublicationResult({required this.wasPublished, this.eventId});

  final bool wasPublished;
  final String? eventId;
}

class _PublicationClaim {
  const _PublicationClaim({
    required this.wasPublished,
    required this.shouldDeliver,
    required this.eventId,
    this.isEligible = true,
  });

  final bool wasPublished;
  final bool shouldDeliver;
  final String eventId;
  final bool isEligible;
}

String _publicationEventId({
  required ThreadKey key,
  required String sourceEpoch,
  required String providerInstanceEpoch,
  required String domain,
  required String operationId,
}) {
  final identity = jsonEncode(<String>[
    key.partition.bridgeIdentityId,
    key.partition.bridgeInstanceId,
    key.partition.codexSourceId,
    key.providerThreadId,
    sourceEpoch,
    providerInstanceEpoch,
    domain,
    operationId,
  ]);
  // This is an opaque, length-safe identity encoding, not a contract digest.
  return 'publication-v1.${base64Url.encode(utf8.encode(identity))}';
}

bool _publicationClaimFresh(Object? value) {
  if (value is! int) return false;
  return DateTime.now().millisecondsSinceEpoch - value <=
      ConversationRepository.writerLeaseTimeout.inMilliseconds;
}

void _validatePublicationPhaseState({
  required Object? phase,
  required Object? notificationState,
  required Object? deliveryToken,
  required Object? deliveryClaimedAt,
}) {
  final validMatrix =
      (phase == 'applied' && notificationState == 'pending') ||
      (phase == 'published' &&
          (notificationState == 'pending' ||
              notificationState == 'delivering' ||
              notificationState == 'notified'));
  final validDeliveryShape = notificationState == 'delivering'
      ? deliveryToken is String && deliveryClaimedAt is int
      : (notificationState == 'pending' || notificationState == 'notified') &&
            deliveryToken == null &&
            deliveryClaimedAt == null;
  if (!validMatrix || !validDeliveryShape) {
    throw const ConversationRepositoryException(
      RepositoryFailureCode.invalidDatabaseIdentity,
      'publication outbox contains an unknown phase/state matrix',
    );
  }
}

Future<RepositoryWindow> _readPublicationWindow(
  ConversationRepository repository,
  Database database,
  ThreadKey key,
  String eventId,
  int readLimit,
) {
  if (identical(database, repository._database)) {
    return _readWindow(
      repository,
      key,
      limit: readLimit,
      publicationEventId: eventId,
    );
  }
  return database.readTransaction(
    (txn) => _readWindowInTransaction(
      repository,
      txn,
      key,
      limit: readLimit,
      publicationEventId: eventId,
    ),
  );
}

Future<T> _withPublicationWriter<T>(
  ConversationRepository repository,
  Database database,
  Future<T> Function() operation,
) {
  if (identical(database, repository._database)) {
    return repository._serialize((_) => operation());
  }
  // During open() the database is leased but is intentionally not exposed via
  // _database until inbox/outbox recovery completes.  No public writer can
  // race this direct transaction in that interval.
  return operation();
}

Future<_PublicationResult> _publishPublicationOutbox(
  ConversationRepository repository,
  ThreadKey key, {
  required String sourceEpoch,
  required String providerInstanceEpoch,
  required String domain,
  required String operationId,
  required int readLimit,
  _ProjectionPublicationFence? requiredProjectionFence,
}) async {
  final database = repository._requireDatabase();
  return _publishPublicationOutboxOnDatabase(
    repository,
    database,
    key,
    sourceEpoch: sourceEpoch,
    providerInstanceEpoch: providerInstanceEpoch,
    domain: domain,
    operationId: operationId,
    readLimit: readLimit,
    requiredProjectionFence: requiredProjectionFence,
  );
}

Future<_PublicationResult> _publishPublicationOutboxOnDatabase(
  ConversationRepository repository,
  Database database,
  ThreadKey key, {
  required String sourceEpoch,
  required String providerInstanceEpoch,
  required String domain,
  required String operationId,
  required int readLimit,
  bool reclaimActiveDelivery = false,
  _ProjectionPublicationFence? requiredProjectionFence,
}) async {
  final expectedEventId = _publicationEventId(
    key: key,
    sourceEpoch: sourceEpoch,
    providerInstanceEpoch: providerInstanceEpoch,
    domain: domain,
    operationId: operationId,
  );
  final rows = await database.query(
    'publication_outbox',
    columns: const <String>[
      'phase',
      'notification_state',
      'event_id',
      'delivery_token',
      'delivery_claimed_at',
    ],
    where: _outboxWhere(),
    whereArgs: _outboxArgs(
      key,
      sourceEpoch,
      providerInstanceEpoch,
      domain,
      operationId,
    ),
    limit: 1,
  );
  if (rows.isEmpty) return const _PublicationResult(wasPublished: false);
  final phase = rows.single['phase'];
  final notificationState = rows.single['notification_state'];
  if (rows.single['event_id'] != expectedEventId) {
    throw const ConversationRepositoryException(
      RepositoryFailureCode.identityConflict,
      'publication outbox event identity does not match its durable key',
    );
  }
  _validatePublicationPhaseState(
    phase: phase,
    notificationState: notificationState,
    deliveryToken: rows.single['delivery_token'],
    deliveryClaimedAt: rows.single['delivery_claimed_at'],
  );
  if (notificationState == 'notified') {
    return const _PublicationResult(wasPublished: false);
  }
  final window = await _readPublicationWindow(
    repository,
    database,
    key,
    expectedEventId,
    readLimit,
  );
  await repository.faultHook?.call(
    RepositoryFaultStage.afterReadback,
    operationId,
  );
  final claim = await _withPublicationWriter(repository, database, () async {
    return database.transaction((txn) async {
      await _assertWriterLease(txn, repository);
      if (requiredProjectionFence != null) {
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
          whereArgs: _keyArgs(key),
          limit: 1,
        );
        final state = await _readThreadState(txn, key);
        if (headRows.length != 1 ||
            state == null ||
            !requiredProjectionFence.matchesHead(headRows.single) ||
            !requiredProjectionFence.matchesState(state) ||
            !_projectionHeadIsCurrentAgainstState(headRows.single, state)) {
          return _PublicationClaim(
            wasPublished: false,
            shouldDeliver: false,
            eventId: expectedEventId,
            isEligible: false,
          );
        }
      }
      final currentRows = await txn.query(
        'publication_outbox',
        columns: const <String>[
          'phase',
          'notification_state',
          'event_id',
          'delivery_token',
          'delivery_claimed_at',
        ],
        where: _outboxWhere(),
        whereArgs: _outboxArgs(
          key,
          sourceEpoch,
          providerInstanceEpoch,
          domain,
          operationId,
        ),
        limit: 1,
      );
      if (currentRows.length != 1 ||
          currentRows.single['event_id'] != expectedEventId) {
        throw const ConversationRepositoryException(
          RepositoryFailureCode.identityConflict,
          'publication outbox row changed identity during claim',
        );
      }
      final current = currentRows.single;
      final currentPhase = current['phase'];
      final currentState = current['notification_state'];
      _validatePublicationPhaseState(
        phase: currentPhase,
        notificationState: currentState,
        deliveryToken: current['delivery_token'],
        deliveryClaimedAt: current['delivery_claimed_at'],
      );
      if (currentState == 'notified') {
        return _PublicationClaim(
          wasPublished: false,
          shouldDeliver: false,
          eventId: expectedEventId,
        );
      }
      final claimIsActive =
          !reclaimActiveDelivery &&
          currentState == 'delivering' &&
          _publicationClaimFresh(current['delivery_claimed_at']);
      if (claimIsActive) {
        return _PublicationClaim(
          wasPublished: false,
          shouldDeliver: false,
          eventId: expectedEventId,
        );
      }
      if (currentPhase == 'applied') {
        await txn.update(
          'publication_outbox',
          <String, Object?>{
            'phase': 'published',
            'published_at': DateTime.now().millisecondsSinceEpoch,
          },
          where: '${_outboxWhere()} AND phase = ?',
          whereArgs: <Object?>[
            ..._outboxArgs(
              key,
              sourceEpoch,
              providerInstanceEpoch,
              domain,
              operationId,
            ),
            'applied',
          ],
        );
      } else if (currentPhase != 'published') {
        throw const ConversationRepositoryException(
          RepositoryFailureCode.invalidDatabaseIdentity,
          'publication outbox contains an unknown phase',
        );
      }
      if (!repository._updatesController.hasListener) {
        // No consumer is present, so leave the row pending for the listener
        // drain.  Durable publication is allowed; durable notification is not.
        return _PublicationClaim(
          wasPublished: true,
          shouldDeliver: false,
          eventId: expectedEventId,
        );
      }
      final updated = await txn.update(
        'publication_outbox',
        <String, Object?>{
          'notification_state': 'delivering',
          'delivery_token': repository._ownerToken,
          'delivery_claimed_at': DateTime.now().millisecondsSinceEpoch,
        },
        where: '${_outboxWhere()} AND notification_state IN (?, ?)',
        whereArgs: <Object?>[
          ..._outboxArgs(
            key,
            sourceEpoch,
            providerInstanceEpoch,
            domain,
            operationId,
          ),
          'pending',
          'delivering',
        ],
      );
      if (updated != 1) {
        throw const ConversationRepositoryException(
          RepositoryFailureCode.writerLeaseUnavailable,
          'publication outbox claim changed during delivery fencing',
        );
      }
      return _PublicationClaim(
        wasPublished: true,
        shouldDeliver: true,
        eventId: expectedEventId,
      );
    });
  });
  if (!claim.isEligible) {
    return const _PublicationResult(wasPublished: false);
  }
  if (!claim.wasPublished) {
    return _PublicationResult(wasPublished: false, eventId: claim.eventId);
  }
  if (!claim.shouldDeliver) {
    await repository.faultHook?.call(
      RepositoryFaultStage.afterPublicationCommit,
      operationId,
    );
    return _PublicationResult(wasPublished: true, eventId: claim.eventId);
  }
  await repository.faultHook?.call(
    RepositoryFaultStage.afterPublicationCommit,
    operationId,
  );
  if (!repository._updatesController.hasListener) {
    // A consumer can disappear after the claim transaction.  Releasing the
    // claim keeps the durable event pending rather than silently notifying it.
    await _withPublicationWriter(repository, database, () async {
      await database.transaction((txn) async {
        await _assertWriterLease(txn, repository);
        await txn.update(
          'publication_outbox',
          const <String, Object?>{
            'notification_state': 'pending',
            'delivery_token': null,
            'delivery_claimed_at': null,
          },
          where:
              '${_outboxWhere()} AND notification_state = ? AND delivery_token = ?',
          whereArgs: <Object?>[
            ..._outboxArgs(
              key,
              sourceEpoch,
              providerInstanceEpoch,
              domain,
              operationId,
            ),
            'delivering',
            repository._ownerToken,
          ],
        );
      });
    });
    return _PublicationResult(wasPublished: true, eventId: claim.eventId);
  }
  repository._rememberDeliveredPublication(claim.eventId);
  repository._updatesController.add(window);
  return _PublicationResult(wasPublished: true, eventId: claim.eventId);
}

const _publicationRecoveryBatchSize = 32;

Future<void> _validatePublicationOutboxMatrix(Database database) async {
  // A single, bounded-result invariant probe runs before contract/listener
  // gates.  It examines only the durable state columns and stops at the first
  // violation; publication payloads and history are never materialized.  The
  // phase/state index covers the ordinary recovery branches, while this
  // open-time probe intentionally trades one linear outbox check for complete
  // fail-closed coverage of rows that SQLite CHECK constraints may not catch
  // after an external writable-schema or constraint-bypass operation.
  final invalidRows = await database.rawQuery('''
    SELECT phase, notification_state, delivery_token, delivery_claimed_at
    FROM publication_outbox
    WHERE phase IS NULL
       OR notification_state IS NULL
       OR NOT (
         (phase = 'applied' AND notification_state = 'pending'
           AND delivery_token IS NULL AND delivery_claimed_at IS NULL)
         OR
         (phase = 'published' AND notification_state = 'pending'
           AND delivery_token IS NULL AND delivery_claimed_at IS NULL)
         OR
         (phase = 'published' AND notification_state = 'delivering'
           AND delivery_token IS NOT NULL AND delivery_claimed_at IS NOT NULL)
         OR
         (phase = 'published' AND notification_state = 'notified'
           AND delivery_token IS NULL AND delivery_claimed_at IS NULL)
       )
    LIMIT 1
  ''');
  if (invalidRows.isEmpty) return;
  final row = invalidRows.single;
  _validatePublicationPhaseState(
    phase: row['phase'],
    notificationState: row['notification_state'],
    deliveryToken: row['delivery_token'],
    deliveryClaimedAt: row['delivery_claimed_at'],
  );
  // The SQL predicate above is deliberately exhaustive.  Keep a defensive
  // throw in case a future SQLite adapter changes NULL/affinity semantics.
  throw const ConversationRepositoryException(
    RepositoryFailureCode.invalidDatabaseIdentity,
    'publication outbox contains an invalid phase/state matrix',
  );
}

Future<void> _recoverPublicationOutboxRows(
  ConversationRepository repository,
  Database database,
) async {
  await _validatePublicationOutboxMatrix(database);
  if (!repository._usesGeneratedContract &&
      !(repository._allowFixtureContract && repository._usesFixtureContract)) {
    // Pending notifications remain durable until a contract-authorized reader
    // can reconstruct the exact visible window.
    return;
  }
  if (!repository._updatesController.hasListener) return;
  final recoveringDuringOpen = !identical(database, repository._database);
  for (final phase in const <String>['published', 'applied']) {
    while (repository._updatesController.hasListener) {
      final cutoff =
          DateTime.now().millisecondsSinceEpoch -
          ConversationRepository.writerLeaseTimeout.inMilliseconds;
      final rows = await database.query(
        'publication_outbox',
        columns: const <String>[
          'bridge_identity_id',
          'bridge_instance_id',
          'codex_source_id',
          'provider_thread_id',
          'source_epoch',
          'provider_instance_epoch',
          'domain',
          'operation_id',
          'event_id',
          'notification_state',
          'delivery_token',
          'delivery_claimed_at',
        ],
        where: 'phase = ? AND notification_state = ?',
        whereArgs: <Object?>[phase, 'pending'],
        orderBy: 'published_at ASC, event_id ASC',
        limit: _publicationRecoveryBatchSize,
      );
      final recoveryRows = rows.isNotEmpty
          ? rows
          : await database.query(
              'publication_outbox',
              columns: const <String>[
                'bridge_identity_id',
                'bridge_instance_id',
                'codex_source_id',
                'provider_thread_id',
                'source_epoch',
                'provider_instance_epoch',
                'domain',
                'operation_id',
                'event_id',
                'notification_state',
                'delivery_token',
                'delivery_claimed_at',
              ],
              where: recoveringDuringOpen
                  ? 'phase = ? AND notification_state = ? AND (delivery_token IS NULL OR delivery_token <> ?)'
                  : 'phase = ? AND notification_state = ? AND (delivery_claimed_at IS NULL OR delivery_claimed_at < ?)',
              whereArgs: recoveringDuringOpen
                  ? <Object?>[phase, 'delivering', repository._ownerToken]
                  : <Object?>[phase, 'delivering', cutoff],
              orderBy: 'published_at ASC, event_id ASC',
              limit: _publicationRecoveryBatchSize,
            );
      if (recoveryRows.isEmpty) break;
      for (final row in recoveryRows) {
        final values = <String?>[
          row['bridge_identity_id'] as String?,
          row['bridge_instance_id'] as String?,
          row['codex_source_id'] as String?,
          row['provider_thread_id'] as String?,
          row['source_epoch'] as String?,
          row['provider_instance_epoch'] as String?,
          row['domain'] as String?,
          row['operation_id'] as String?,
          row['event_id'] as String?,
        ];
        if (values.any((value) => value == null || value.isEmpty)) {
          throw const ConversationRepositoryException(
            RepositoryFailureCode.invalidDatabaseIdentity,
            'publication outbox recovery row has incomplete identity',
          );
        }
        final key = ThreadKey(
          partition: SourcePartition(
            bridgeIdentityId: values[0]!,
            bridgeInstanceId: values[1]!,
            codexSourceId: values[2]!,
          ),
          providerThreadId: values[3]!,
        );
        final expectedEventId = _publicationEventId(
          key: key,
          sourceEpoch: values[4]!,
          providerInstanceEpoch: values[5]!,
          domain: values[6]!,
          operationId: values[7]!,
        );
        if (expectedEventId != values[8]) {
          throw const ConversationRepositoryException(
            RepositoryFailureCode.identityConflict,
            'publication recovery row event identity is not bijective',
          );
        }
        await _publishPublicationOutboxOnDatabase(
          repository,
          database,
          key,
          sourceEpoch: values[4]!,
          providerInstanceEpoch: values[5]!,
          domain: values[6]!,
          operationId: values[7]!,
          readLimit: repository.defaultWindowSize,
          reclaimActiveDelivery: recoveringDuringOpen,
        );
      }
    }
  }
}

Future<Map<String, Object?>?> _readStagedBegin(
  DatabaseExecutor db,
  ThreadKey key,
  String sourceEpoch,
  String providerInstanceEpoch,
  String materializationId,
) async {
  final rows = await db.query(
    'staged_materialization',
    where: '${_stagingWhere()} AND materialization_id = ?',
    whereArgs: <Object?>[
      ..._stagingArgs(key, sourceEpoch, providerInstanceEpoch),
      materializationId,
    ],
    limit: 1,
  );
  return rows.isEmpty ? null : rows.single;
}

void _validatePageAgainstBegin(
  MaterializationPage page,
  Map<String, Object?> begin,
) {
  final expected = <String, Object?>{
    'connection_epoch': page.fence.connectionEpoch,
    'source_epoch': page.fence.sourceEpoch,
    'provider_instance_epoch': page.fence.providerInstanceEpoch,
    'runtime_authority_generation': page.fence.runtimeAuthorityGeneration,
    'source_revision': page.sourceRevision,
    'page_count': page.pageCount,
  };
  for (final entry in expected.entries) {
    if (begin[entry.key] != entry.value) {
      throw const ConversationRepositoryException(
        RepositoryFailureCode.identityConflict,
        'page header/fence does not match materialization begin',
      );
    }
  }
}

void _validateCommitAgainstBegin(
  MaterializationCommit commit,
  Map<String, Object?> begin,
) {
  final expected = <String, Object?>{
    'connection_epoch': commit.fence.connectionEpoch,
    'source_epoch': commit.fence.sourceEpoch,
    'provider_instance_epoch': commit.fence.providerInstanceEpoch,
    'runtime_authority_generation': commit.fence.runtimeAuthorityGeneration,
    'source_revision': commit.sourceRevision,
    'page_count': commit.pageCount,
    'provider_read_evidence_digest': commit.providerReadEvidenceDigest,
    'empty_proof_digest': commit.emptyProofDigest,
  };
  for (final entry in expected.entries) {
    if (begin[entry.key] != entry.value) {
      throw const ConversationRepositoryException(
        RepositoryFailureCode.identityConflict,
        'commit header/fence does not match materialization begin',
      );
    }
  }
}

MaterializationBegin _materializationBeginFromRow(
  Map<String, Object?> row,
  MaterializationCommit commit,
) {
  String requiredString(String name) {
    final value = row[name];
    if (value is! String) {
      throw ConversationRepositoryException(
        RepositoryFailureCode.invalidEnvelope,
        'stored materialization begin field $name is invalid',
      );
    }
    return value;
  }

  int requiredInt(String name) {
    final value = row[name];
    if (value is! int) {
      throw ConversationRepositoryException(
        RepositoryFailureCode.invalidEnvelope,
        'stored materialization begin field $name is invalid',
      );
    }
    return value;
  }

  T enumValue<T extends Enum>(Iterable<T> values, String name, String field) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    throw ConversationRepositoryException(
      RepositoryFailureCode.invalidEnvelope,
      'stored materialization begin field $field has an unknown value',
    );
  }

  final storedKey = ThreadKey(
    partition: SourcePartition(
      bridgeIdentityId: requiredString('bridge_identity_id'),
      bridgeInstanceId: requiredString('bridge_instance_id'),
      codexSourceId: requiredString('codex_source_id'),
    ),
    providerThreadId: requiredString('provider_thread_id'),
  );
  if (storedKey != commit.key ||
      requiredString('materialization_id') != commit.materializationId) {
    throw const ConversationRepositoryException(
      RepositoryFailureCode.identityConflict,
      'staged materialization identity was changed after admission',
    );
  }
  final emptyKind = row['empty_proof_kind'] as String?;
  final emptyProof = emptyKind == null
      ? null
      : ReplicaEmptyProof(
          proofKind: enumValue(
            ReplicaEmptyProofKind.values,
            emptyKind,
            'empty_proof_kind',
          ),
          providerRevision: requiredString('empty_provider_revision'),
          providerReadEvidenceDigest: requiredString(
            'provider_read_evidence_digest',
          ),
          observationDigest: requiredString('empty_observation_digest'),
        );
  final evidence = ProviderReadEvidence(
    method: requiredString('provider_read_method'),
    buildId: requiredString('provider_build_id'),
    resultKind: requiredString('provider_result_kind'),
    resultDigest: requiredString('provider_result_digest'),
    evidenceDigest: requiredString('provider_read_evidence_digest'),
    coverageDigest: requiredString('provider_coverage_digest'),
  );
  return MaterializationBegin(
    materializationId: commit.materializationId,
    key: commit.key,
    fence: EnvelopeFence(
      connectionEpoch: requiredString('connection_epoch'),
      sourceEpoch: requiredString('source_epoch'),
      providerInstanceEpoch: requiredString('provider_instance_epoch'),
      runtimeAuthorityGeneration: requiredInt('runtime_authority_generation'),
    ),
    sourceRevision: requiredInt('source_revision'),
    coverage: Coverage(
      structural: enumValue(
        StructuralCoverage.values,
        requiredString('structural_coverage'),
        'structural_coverage',
      ),
      payload: enumValue(
        PayloadCoverage.values,
        requiredString('payload_coverage'),
        'payload_coverage',
      ),
      lowerOrdinal: row['lower_ordinal'] as int?,
      upperOrdinal: row['upper_ordinal'] as int?,
    ),
    health: enumValue(ReadHealth.values, requiredString('health'), 'health'),
    problemCode: row['problem_code'] as String?,
    pageCount: requiredInt('page_count'),
    totalItemCount: requiredInt('total_item_count'),
    providerReadEvidenceDigest: requiredString('provider_read_evidence_digest'),
    providerReadEvidence: evidence,
    requestId: requiredString('request_id'),
    readKind: requiredString('read_kind'),
    isSnapshot: requiredInt('is_snapshot') == 1,
    emptyProof: emptyProof,
  );
}

_CanonicalEnvelope _sealMaterialization(
  ConversationRepository repository,
  Map<String, Object?> begin,
  List<Map<String, Object?>> pages,
  MaterializationCommit commit,
) {
  final storedBegin = _materializationBeginFromRow(begin, commit);
  _validateBegin(repository, storedBegin);
  final beginArtifact = repository._verifiedPreimage(
    repository._contractMapper.begin(storedBegin),
    'staged materialization begin',
  );
  if (beginArtifact.digest != begin['begin_digest']) {
    throw const ConversationRepositoryException(
      RepositoryFailureCode.digestMismatch,
      'staged materialization begin no longer matches its generated preimage',
    );
  }
  if (pages.length != commit.pageCount) {
    throw ConversationRepositoryException(
      RepositoryFailureCode.materializationIncomplete,
      'expected ${commit.pageCount} pages but found ${pages.length}',
    );
  }
  final items = <CanonicalItem>[];
  final gaps = <TypedGap>[];
  final pageDigests = <String>[];
  String? previous;
  for (var index = 0; index < pages.length; index += 1) {
    final page = pages[index];
    if (page['page_index'] != index ||
        page['page_count'] != commit.pageCount ||
        page['previous_page_digest'] != previous ||
        page['connection_epoch'] != commit.fence.connectionEpoch ||
        page['runtime_authority_generation'] !=
            commit.fence.runtimeAuthorityGeneration ||
        page['source_revision'] != commit.sourceRevision) {
      throw const ConversationRepositoryException(
        RepositoryFailureCode.digestMismatch,
        'staged page chain is not contiguous or is fenced to another commit',
      );
    }
    final body = _decodePageBody(page['body_json']! as String);
    _validateBodyIdentity(body);
    final artifact = repository._verifiedPreimage(
      repository._contractMapper.pageBody(body),
      'staged page body',
    );
    final storedDigest = page['page_digest']! as String;
    if (artifact.digest != storedDigest ||
        artifact.bytes.length != page['body_byte_size']) {
      throw const ConversationRepositoryException(
        RepositoryFailureCode.digestMismatch,
        'staged page body no longer matches the generated preimage',
      );
    }
    items.addAll(body.items);
    gaps.addAll(body.gaps);
    pageDigests.add(storedDigest);
    previous = storedDigest;
  }
  if (previous != commit.finalPageDigest) {
    throw const ConversationRepositoryException(
      RepositoryFailureCode.digestMismatch,
      'final page digest does not match the staged chain',
    );
  }
  final manifest = repository._verifiedPreimage(
    repository._contractMapper.pageManifest(pageDigests),
    'page manifest',
  );
  if (manifest.digest != commit.pageManifestDigest) {
    throw const ConversationRepositoryException(
      RepositoryFailureCode.digestMismatch,
      'page manifest does not match the staged page chain',
    );
  }
  if (items.length != begin['total_item_count']) {
    throw const ConversationRepositoryException(
      RepositoryFailureCode.materializationIncomplete,
      'staged item count does not match materialization begin',
    );
  }
  ReplicaEmptyProof? emptyProof;
  final proofKind = begin['empty_proof_kind'] as String?;
  if (proofKind != null) {
    final kind = ReplicaEmptyProofKind.values.firstWhere(
      (candidate) => candidate.name == proofKind,
      orElse: () => throw const ConversationRepositoryException(
        RepositoryFailureCode.invalidEnvelope,
        'stored empty proof kind is unknown',
      ),
    );
    emptyProof = ReplicaEmptyProof(
      proofKind: kind,
      providerRevision: begin['empty_provider_revision']! as String,
      providerReadEvidenceDigest:
          begin['provider_read_evidence_digest']! as String,
      observationDigest: begin['empty_observation_digest']! as String,
    );
    final artifact = repository._verifiedPreimage(
      repository._contractMapper.emptyProof(emptyProof),
      'staged empty proof',
    );
    if (artifact.digest != commit.emptyProofDigest) {
      throw const ConversationRepositoryException(
        RepositoryFailureCode.digestMismatch,
        'empty proof does not match the staged typed proof',
      );
    }
  } else if (commit.emptyProofDigest != null) {
    throw const ConversationRepositoryException(
      RepositoryFailureCode.digestMismatch,
      'commit carries an empty proof that the begin does not carry',
    );
  }
  final structural = gaps.any((gap) => gap.kind != GapKind.payload)
      ? StructuralCoverage.partial
      : StructuralCoverage.complete;
  final payload = gaps.any((gap) => gap.kind == GapKind.payload)
      ? PayloadCoverage.partial
      : PayloadCoverage.complete;
  final ordinals = <int>[
    ...items.map((item) => item.timelineOrdinal),
    for (final gap in gaps) gap.startOrdinal,
    for (final gap in gaps)
      if (gap.endOrdinal != null) gap.endOrdinal!,
  ]..sort();
  final lower = ordinals.isEmpty ? null : ordinals.first;
  final upper = ordinals.isEmpty ? null : ordinals.last;
  if (begin['structural_coverage'] != structural.name ||
      begin['payload_coverage'] != payload.name ||
      begin['lower_ordinal'] != lower ||
      begin['upper_ordinal'] != upper) {
    throw const ConversationRepositoryException(
      RepositoryFailureCode.invalidEnvelope,
      'staged body does not match declared coverage',
    );
  }
  return _CanonicalEnvelope(
    envelopeId: commit.materializationId,
    key: commit.key,
    fence: commit.fence,
    sourceRevision: commit.sourceRevision,
    coverage: Coverage(
      structural: structural,
      payload: payload,
      lowerOrdinal: lower,
      upperOrdinal: upper,
    ),
    health: ReadHealth.values.firstWhere(
      (value) => value.name == begin['health'],
    ),
    problemCode: begin['problem_code'] as String?,
    isSnapshot: begin['is_snapshot'] == 1,
    pageCount: commit.pageCount,
    totalItemCount: items.length,
    providerReadEvidenceDigest: commit.providerReadEvidenceDigest,
    emptyProof: emptyProof,
    items: items,
    gaps: gaps,
  );
}

Future<void> _applyEnvelope(
  Transaction txn,
  ConversationRepository repository,
  _CanonicalEnvelope envelope,
  String envelopeDigest,
  String orderDigest, {
  required String? finalPageDigest,
  required String pageManifestDigest,
}) async {
  final previous = await _readThreadState(txn, envelope.key);
  final transition = _evaluateFenceTransition(previous, envelope.fence);
  await _rejectRetiredEpochs(txn, envelope.key.partition, envelope.fence);
  _validateMonotonicEnvelope(previous, envelope, transition);
  if (previous == null) {
    await _insertThreadState(txn, envelope, envelopeDigest);
  } else {
    await _retireChangedEpochs(
      txn,
      envelope.key.partition,
      previous,
      transition,
    );
  }
  final strong = _publishesStrongHead(envelope);
  final establishesEmpty =
      envelope.emptyProof != null &&
      (previous == null || (previous['last_good_revision']! as int) < 0);
  final replacesTimeline =
      strong &&
      (envelope.isSnapshot ||
          transition.timelineEpochChanged ||
          (previous != null &&
              !transition.timelineEpochChanged &&
              envelope.coverage.isComplete));
  if (replacesTimeline || establishesEmpty) {
    await txn.delete(
      'canonical_item',
      where: _keyWhere(),
      whereArgs: _keyArgs(envelope.key),
    );
    await txn.update(
      'typed_gap',
      const <String, Object?>{'is_active': 0},
      where: _keyWhere(),
      whereArgs: _keyArgs(envelope.key),
    );
  }
  if (_canApplyItems(previous, envelope)) {
    await _applyItems(txn, repository, envelope);
    await _applyGaps(txn, repository, envelope, replaceSet: replacesTimeline);
  }
  await _writeThreadState(
    txn,
    previous,
    envelope,
    envelopeDigest: envelopeDigest,
    preservesLastGood: !strong && !establishesEmpty,
  );
  await txn.insert('committed_envelope', <String, Object?>{
    ..._keyColumns(envelope.key),
    'source_epoch': envelope.fence.sourceEpoch,
    'provider_instance_epoch': envelope.fence.providerInstanceEpoch,
    'envelope_id': envelope.envelopeId,
    'envelope_digest': envelopeDigest,
    'connection_epoch': envelope.fence.connectionEpoch,
    'runtime_authority_generation': envelope.fence.runtimeAuthorityGeneration,
    'source_revision': envelope.sourceRevision,
    'page_index': envelope.pageIndex,
    'page_count': envelope.pageCount,
    'final_page_digest': finalPageDigest,
    'page_manifest_digest': pageManifestDigest,
    'item_count': envelope.items.length,
    'gap_count': envelope.gaps.length,
    'island_count': _materializedIslandCount(envelope.items),
    'structural_coverage': envelope.coverage.structural.name,
    'payload_coverage': envelope.coverage.payload.name,
    'lower_ordinal': envelope.coverage.lowerOrdinal,
    'upper_ordinal': envelope.coverage.upperOrdinal,
    'order_digest': orderDigest,
    'last_good_disposition': strong
        ? (replacesTimeline ? 'replace' : 'advance')
        : establishesEmpty
        ? 'establish_empty'
        : 'retain',
    'provider_read_evidence_digest': envelope.providerReadEvidenceDigest,
    'empty_proof_digest': envelope.emptyProof == null
        ? null
        : repository
              ._verifiedPreimage(
                repository._contractMapper.emptyProof(envelope.emptyProof!),
                'empty proof',
              )
              .digest,
    'committed_at': DateTime.now().millisecondsSinceEpoch,
  });
  await _insertPublicationOutbox(
    txn,
    key: envelope.key,
    sourceEpoch: envelope.fence.sourceEpoch,
    providerInstanceEpoch: envelope.fence.providerInstanceEpoch,
    domain: 'materialization',
    operationId: envelope.envelopeId,
    appliedDigest: envelopeDigest,
  );
}

Future<void> _applyItems(
  Transaction txn,
  ConversationRepository repository,
  _CanonicalEnvelope envelope,
) async {
  for (final item in envelope.items) {
    final itemArtifact = repository._verifiedPreimage(
      repository._contractMapper.item(item),
      'canonical item',
    );
    final normalizedJson = _storageJson(
      item.normalizedPayload,
      'normalized payload',
    );
    final presentationJson = _storageJson(
      item.presentationProjection,
      'presentation projection',
    );
    final identityRows = await txn.query(
      'canonical_item',
      columns: const <String>['item_digest'],
      where: '${_keyWhere()} AND provider_turn_id = ? AND provider_item_id = ?',
      whereArgs: <Object?>[
        ..._keyArgs(envelope.key),
        item.providerTurnId,
        item.providerItemId,
      ],
      limit: 1,
    );
    if (identityRows.isNotEmpty) {
      if (identityRows.single['item_digest'] != itemArtifact.digest) {
        throw const ConversationRepositoryException(
          RepositoryFailureCode.identityConflict,
          'provider item identity was reused with different content',
        );
      }
      continue;
    }
    final ordinalRows = await txn.query(
      'canonical_item',
      columns: const <String>['provider_turn_id', 'provider_item_id'],
      where: '${_keyWhere()} AND timeline_ordinal = ?',
      whereArgs: <Object?>[..._keyArgs(envelope.key), item.timelineOrdinal],
      limit: 1,
    );
    if (ordinalRows.isNotEmpty) {
      throw const ConversationRepositoryException(
        RepositoryFailureCode.identityConflict,
        'timeline ordinal is owned by another provider item',
      );
    }
    final turnRows = await txn.query(
      'canonical_item',
      columns: const <String>['turn_ordinal'],
      where: '${_keyWhere()} AND provider_turn_id = ?',
      whereArgs: <Object?>[..._keyArgs(envelope.key), item.providerTurnId],
      limit: 1,
    );
    if (turnRows.isNotEmpty &&
        turnRows.single['turn_ordinal'] != item.turnOrdinal) {
      throw const ConversationRepositoryException(
        RepositoryFailureCode.identityConflict,
        'provider turn identity was reused with another turn ordinal',
      );
    }
    final turnItemRows = await txn.query(
      'canonical_item',
      columns: const <String>['provider_item_id'],
      where: '${_keyWhere()} AND provider_turn_id = ? AND item_ordinal = ?',
      whereArgs: <Object?>[
        ..._keyArgs(envelope.key),
        item.providerTurnId,
        item.itemOrdinal,
      ],
      limit: 1,
    );
    if (turnItemRows.isNotEmpty) {
      throw const ConversationRepositoryException(
        RepositoryFailureCode.identityConflict,
        'turn-local item ordinal is owned by another provider item',
      );
    }
    await txn.insert('canonical_item', <String, Object?>{
      ..._keyColumns(envelope.key),
      'provider_turn_id': item.providerTurnId,
      'provider_item_id': item.providerItemId,
      'turn_ordinal': item.turnOrdinal,
      'item_ordinal': item.itemOrdinal,
      'timeline_ordinal': item.timelineOrdinal,
      'kind': item.kind,
      'normalized_payload_json': normalizedJson,
      'presentation_projection_json': presentationJson,
      'item_digest': itemArtifact.digest,
      'byte_size': itemArtifact.bytes.length,
      'source_revision': envelope.sourceRevision,
    });
  }
}

Future<void> _applyGaps(
  Transaction txn,
  ConversationRepository repository,
  _CanonicalEnvelope envelope, {
  required bool replaceSet,
}) async {
  if (replaceSet) {
    final existing = await txn.query(
      'typed_gap',
      columns: const <String>['gap_id'],
      where: _keyWhere(),
      whereArgs: _keyArgs(envelope.key),
    );
    final retained = envelope.gaps.map((gap) => gap.gapId).toSet();
    for (final row in existing) {
      final gapId = row['gap_id']! as String;
      if (!retained.contains(gapId)) {
        await txn.update(
          'typed_gap',
          const <String, Object?>{'is_active': 0},
          where: '${_keyWhere()} AND gap_id = ?',
          whereArgs: <Object?>[..._keyArgs(envelope.key), gapId],
        );
      }
    }
  }
  for (final gap in envelope.gaps) {
    final artifact = repository._verifiedPreimage(
      repository._contractMapper.gap(gap),
      'typed gap',
    );
    final rows = await txn.query(
      'typed_gap',
      columns: const <String>['gap_digest', 'is_active'],
      where: '${_keyWhere()} AND gap_id = ?',
      whereArgs: <Object?>[..._keyArgs(envelope.key), gap.gapId],
      limit: 1,
    );
    if (rows.isNotEmpty) {
      if (rows.single['gap_digest'] != artifact.digest ||
          rows.single['is_active'] != 1) {
        throw const ConversationRepositoryException(
          RepositoryFailureCode.identityConflict,
          'typed gap identity is immutable or has already been resolved',
        );
      }
      continue;
    }
    await txn.insert('typed_gap', <String, Object?>{
      ..._keyColumns(envelope.key),
      'gap_id': gap.gapId,
      'kind': gap.kind.name,
      'start_ordinal': gap.startOrdinal,
      'end_ordinal': gap.endOrdinal,
      'details_json': _storageJson(gap.details, 'gap details'),
      'gap_digest': artifact.digest,
      'is_active': 1,
      'source_revision': envelope.sourceRevision,
    });
  }
}

Future<void> _deleteStaging(
  Transaction txn,
  MaterializationCommit commit,
) async {
  final where = '${_stagingWhere()} AND materialization_id = ?';
  final args = <Object?>[
    ..._stagingArgs(
      commit.key,
      commit.fence.sourceEpoch,
      commit.fence.providerInstanceEpoch,
    ),
    commit.materializationId,
  ];
  await txn.delete(
    'staged_materialization_page',
    where: where,
    whereArgs: args,
  );
  await txn.delete('staged_materialization', where: where, whereArgs: args);
}

Future<Map<String, Object?>?> _readThreadState(
  DatabaseExecutor db,
  ThreadKey key,
) async {
  final rows = await db.query(
    'thread_state',
    where: _keyWhere(),
    whereArgs: _keyArgs(key),
    limit: 1,
  );
  if (rows.isEmpty) return null;
  final state = rows.single;
  _validateThreadStateBinding(state);
  return state;
}

void _validateThreadStateBinding(Map<String, Object?> state) {
  final stateKind = state['state_kind'];
  if (stateKind != 'canonical' && stateKind != 'projection_only') {
    throw const ConversationRepositoryException(
      RepositoryFailureCode.invalidDatabaseIdentity,
      'thread_state kind is unknown',
    );
  }
  final currentId = state['current_envelope_id'];
  final currentDigest = state['current_envelope_digest'];
  if ((stateKind == 'canonical' &&
          (currentId == null || currentDigest == null)) ||
      (stateKind == 'projection_only' &&
          (currentId != null || currentDigest != null)) ||
      ((currentId == null) != (currentDigest == null)) ||
      (currentId != null && currentId is! String) ||
      (currentDigest != null && currentDigest is! String)) {
    throw const ConversationRepositoryException(
      RepositoryFailureCode.invalidDatabaseIdentity,
      'thread_state current envelope binding is incomplete',
    );
  }

  final revision = state['last_good_revision'];
  final lastGoodFields = <Object?>[
    state['last_good_connection_epoch'],
    state['last_good_source_epoch'],
    state['last_good_provider_instance_epoch'],
    state['last_good_runtime_authority_generation'],
    state['last_good_envelope_id'],
    state['last_good_envelope_digest'],
  ];
  final allLastGoodNull = lastGoodFields.every((value) => value == null);
  final allLastGoodPresent = lastGoodFields.every((value) => value != null);
  if (revision is! int ||
      (revision == -1 && !allLastGoodNull) ||
      (revision >= 0 && !allLastGoodPresent) ||
      revision < -1 ||
      (allLastGoodPresent &&
          (state['last_good_connection_epoch'] is! String ||
              state['last_good_source_epoch'] is! String ||
              state['last_good_provider_instance_epoch'] is! String ||
              state['last_good_runtime_authority_generation'] is! int ||
              state['last_good_envelope_id'] is! String ||
              state['last_good_envelope_digest'] is! String))) {
    throw const ConversationRepositoryException(
      RepositoryFailureCode.invalidDatabaseIdentity,
      'thread_state last-good envelope binding is incomplete',
    );
  }
  if (stateKind == 'projection_only' && (revision != -1 || !allLastGoodNull)) {
    throw const ConversationRepositoryException(
      RepositoryFailureCode.invalidDatabaseIdentity,
      'projection-only thread_state cannot carry a canonical last-good proof',
    );
  }
}

_FenceTransition _evaluateFenceTransition(
  Map<String, Object?>? state,
  EnvelopeFence fence,
) {
  if (state == null) {
    return const _FenceTransition(
      connectionChanged: false,
      sourceChanged: false,
      providerChanged: false,
    );
  }
  return _FenceTransition(
    connectionChanged: state['connection_epoch'] != fence.connectionEpoch,
    sourceChanged: state['source_epoch'] != fence.sourceEpoch,
    providerChanged:
        state['provider_instance_epoch'] != fence.providerInstanceEpoch,
  );
}

void _validateFenceTransitionAgainstState(
  Map<String, Object?>? state,
  EnvelopeFence fence,
  int revision,
) {
  if (state == null) return;
  final transition = _evaluateFenceTransition(state, fence);
  if (!transition.timelineEpochChanged &&
      revision < (state['source_revision']! as int)) {
    throw const ConversationRepositoryException(
      RepositoryFailureCode.staleRevision,
      'materialization revision is older than the current source revision',
    );
  }
}

Future<void> _rejectRetiredEpochs(
  DatabaseExecutor db,
  SourcePartition partition,
  EnvelopeFence fence,
) async {
  for (final entry in <String, String>{
    'connection': fence.connectionEpoch,
    'source': fence.sourceEpoch,
    'provider_instance': fence.providerInstanceEpoch,
  }.entries) {
    final rows = await db.query(
      'retired_epoch',
      columns: const <String>['epoch_value'],
      where: '${_partitionWhere()} AND epoch_kind = ? AND epoch_value = ?',
      whereArgs: <Object?>[
        ..._partitionArgs(partition),
        entry.key,
        entry.value,
      ],
      limit: 1,
    );
    if (rows.isNotEmpty) {
      throw ConversationRepositoryException(
        RepositoryFailureCode.staleEpoch,
        '${entry.key} epoch is retired',
      );
    }
  }
}

Future<void> _retireChangedEpochs(
  Transaction txn,
  SourcePartition partition,
  Map<String, Object?> previous,
  _FenceTransition transition,
) async {
  final values = <String, String>{};
  if (transition.connectionChanged) {
    values['connection'] = previous['connection_epoch']! as String;
  }
  if (transition.sourceChanged) {
    values['source'] = previous['source_epoch']! as String;
  }
  if (transition.providerChanged) {
    values['provider_instance'] =
        previous['provider_instance_epoch']! as String;
  }
  for (final entry in values.entries) {
    final existing = await txn.query(
      'retired_epoch',
      columns: const <String>['epoch_value'],
      where: '${_partitionWhere()} AND epoch_kind = ? AND epoch_value = ?',
      whereArgs: <Object?>[
        ..._partitionArgs(partition),
        entry.key,
        entry.value,
      ],
      limit: 1,
    );
    if (existing.isNotEmpty) continue;
    final countRows = await txn.rawQuery(
      'SELECT COUNT(*) AS row_count FROM retired_epoch WHERE ${_partitionWhere()} AND epoch_kind = ?',
      <Object?>[..._partitionArgs(partition), entry.key],
    );
    if (_asInt(countRows.single['row_count']) >=
        ConversationRepository.maxRetiredEpochValuesPerKind) {
      throw ConversationRepositoryException(
        RepositoryFailureCode.capacityExceeded,
        'retired ${entry.key} epoch evidence reached its bounded cap',
      );
    }
    await txn.insert('retired_epoch', <String, Object?>{
      ..._partitionColumns(partition),
      'epoch_kind': entry.key,
      'epoch_value': entry.value,
      'retired_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }
}

void _validateMonotonicEnvelope(
  Map<String, Object?>? state,
  _CanonicalEnvelope envelope,
  _FenceTransition transition,
) {
  if (state == null) return;
  final generation = state['runtime_authority_generation']! as int;
  final revision = state['source_revision']! as int;
  if (!transition.providerChanged &&
      envelope.fence.runtimeAuthorityGeneration < generation) {
    throw const ConversationRepositoryException(
      RepositoryFailureCode.staleGeneration,
      'runtime authority generation is older than the current fence',
    );
  }
  if (!transition.timelineEpochChanged && envelope.sourceRevision < revision) {
    throw const ConversationRepositoryException(
      RepositoryFailureCode.staleRevision,
      'source revision is older than the current source revision',
    );
  }
}

Future<void> _insertThreadState(
  Transaction txn,
  _CanonicalEnvelope envelope,
  String envelopeDigest,
) async {
  await txn.insert('thread_state', <String, Object?>{
    ..._keyColumns(envelope.key),
    'state_kind': 'canonical',
    'connection_epoch': envelope.fence.connectionEpoch,
    'source_epoch': envelope.fence.sourceEpoch,
    'provider_instance_epoch': envelope.fence.providerInstanceEpoch,
    'runtime_authority_generation': envelope.fence.runtimeAuthorityGeneration,
    'source_revision': envelope.sourceRevision,
    'current_envelope_id': envelope.envelopeId,
    'current_envelope_digest': envelopeDigest,
    'last_good_revision': -1,
    'last_good_connection_epoch': null,
    'last_good_source_epoch': null,
    'last_good_provider_instance_epoch': null,
    'last_good_runtime_authority_generation': null,
    'last_good_envelope_id': null,
    'last_good_envelope_digest': null,
    'structural_coverage': envelope.coverage.structural.name,
    'payload_coverage': envelope.coverage.payload.name,
    'lower_ordinal': envelope.coverage.lowerOrdinal,
    'upper_ordinal': envelope.coverage.upperOrdinal,
    'health': envelope.health.name,
    'problem_code': envelope.problemCode,
    'updated_at': DateTime.now().millisecondsSinceEpoch,
  });
}

Future<void> _writeThreadState(
  Transaction txn,
  Map<String, Object?>? previous,
  _CanonicalEnvelope envelope, {
  required String envelopeDigest,
  required bool preservesLastGood,
}) async {
  final oldLastGood = previous == null
      ? -1
      : previous['last_good_revision']! as int;
  final strong = _publishesStrongHead(envelope);
  final establishesEmpty = envelope.emptyProof != null && oldLastGood < 0;
  final publishLastGood = strong || establishesEmpty;
  final lastGood = publishLastGood ? envelope.sourceRevision : oldLastGood;
  await txn.update(
    'thread_state',
    <String, Object?>{
      'state_kind': 'canonical',
      'connection_epoch': envelope.fence.connectionEpoch,
      'source_epoch': envelope.fence.sourceEpoch,
      'provider_instance_epoch': envelope.fence.providerInstanceEpoch,
      'runtime_authority_generation': envelope.fence.runtimeAuthorityGeneration,
      'source_revision': envelope.sourceRevision,
      'current_envelope_id': envelope.envelopeId,
      'current_envelope_digest': envelopeDigest,
      'last_good_revision': lastGood,
      'last_good_connection_epoch': publishLastGood
          ? envelope.fence.connectionEpoch
          : previous?['last_good_connection_epoch'],
      'last_good_source_epoch': publishLastGood
          ? envelope.fence.sourceEpoch
          : previous?['last_good_source_epoch'],
      'last_good_provider_instance_epoch': publishLastGood
          ? envelope.fence.providerInstanceEpoch
          : previous?['last_good_provider_instance_epoch'],
      'last_good_runtime_authority_generation': publishLastGood
          ? envelope.fence.runtimeAuthorityGeneration
          : previous?['last_good_runtime_authority_generation'],
      'last_good_envelope_id': publishLastGood
          ? envelope.envelopeId
          : previous?['last_good_envelope_id'],
      'last_good_envelope_digest': publishLastGood
          ? envelopeDigest
          : previous?['last_good_envelope_digest'],
      'structural_coverage': preservesLastGood && previous != null
          ? previous['structural_coverage']
          : envelope.coverage.structural.name,
      'payload_coverage': preservesLastGood && previous != null
          ? previous['payload_coverage']
          : envelope.coverage.payload.name,
      'lower_ordinal': preservesLastGood && previous != null
          ? previous['lower_ordinal']
          : envelope.coverage.lowerOrdinal,
      'upper_ordinal': preservesLastGood && previous != null
          ? previous['upper_ordinal']
          : envelope.coverage.upperOrdinal,
      'health': envelope.health.name,
      'problem_code': envelope.problemCode,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    },
    where: _keyWhere(),
    whereArgs: _keyArgs(envelope.key),
  );
}

bool _publishesStrongHead(_CanonicalEnvelope envelope) {
  final exactEmpty =
      envelope.health == ReadHealth.empty &&
      envelope.emptyProof != null &&
      envelope.coverage.isComplete &&
      envelope.items.isEmpty &&
      envelope.gaps.isEmpty;
  final completeContent =
      envelope.health == ReadHealth.healthy &&
      envelope.coverage.isComplete &&
      envelope.items.isNotEmpty;
  return exactEmpty || completeContent;
}

bool _canApplyItems(
  Map<String, Object?>? previous,
  _CanonicalEnvelope envelope,
) {
  // A partial/degraded read is an observation, not an authority to rewrite
  // visible canonical bytes.  The only exception is an initial materializing
  // read where no canonical head exists yet; once a head exists, content and
  // gaps remain last-good until a strong complete/verified-empty snapshot wins.
  if (previous == null) return true;
  return _publishesStrongHead(envelope);
}

int _materializedIslandCount(List<CanonicalItem> items) {
  if (items.isEmpty) return 0;
  final ordinals = items.map((item) => item.timelineOrdinal).toList()..sort();
  var islands = 1;
  for (var index = 1; index < ordinals.length; index += 1) {
    if (ordinals[index] != ordinals[index - 1] + 1) islands += 1;
  }
  return islands;
}
