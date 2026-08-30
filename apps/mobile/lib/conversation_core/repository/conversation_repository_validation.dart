part of 'conversation_repository.dart';

void _validateKey(ThreadKey key) {
  _requireIdentity(key.partition.bridgeIdentityId, 'bridgeIdentityId');
  _requireIdentity(key.partition.bridgeInstanceId, 'bridgeInstanceId');
  _requireIdentity(key.partition.codexSourceId, 'codexSourceId');
  _requireIdentity(key.providerThreadId, 'providerThreadId');
}

void _validateFence(EnvelopeFence fence, String field) {
  _requireIdentity(fence.connectionEpoch, '$field.connectionEpoch');
  _requireIdentity(fence.sourceEpoch, '$field.sourceEpoch');
  _requireIdentity(fence.providerInstanceEpoch, '$field.providerInstanceEpoch');
  if (!_isSafeUnsigned(fence.runtimeAuthorityGeneration)) {
    _invalid(
      '$field.runtimeAuthorityGeneration must be a non-negative safe integer',
    );
  }
}

void _validateMaterializationIdentity({
  required ThreadKey key,
  required String materializationId,
  required EnvelopeFence fence,
  required int sourceRevision,
  required int pageCount,
}) {
  _validateKey(key);
  _requireIdentity(materializationId, 'materializationId');
  _validateFence(fence, 'fence');
  if (!_isSafeUnsigned(sourceRevision)) {
    _invalid('sourceRevision must be a non-negative safe integer');
  }
  if (pageCount < 0 ||
      pageCount > ConversationRepository.maxMaterializationPages) {
    _invalid(
      'pageCount must be between 0 and ${ConversationRepository.maxMaterializationPages}',
    );
  }
}

void _validateProviderReadEvidence(MaterializationBegin begin) {
  final evidence = begin.providerReadEvidence;
  if (evidence == null) {
    _invalid(
      'providerReadEvidence is required; opaque digest alone is not evidence',
    );
  }
  _requireIdentity(evidence.method, 'providerReadEvidence.method');
  _requireIdentity(evidence.buildId, 'providerReadEvidence.buildId');
  _requireIdentity(evidence.resultKind, 'providerReadEvidence.resultKind');
  _requireDigest(evidence.resultDigest, 'providerReadEvidence.resultDigest');
  _requireDigest(
    evidence.evidenceDigest,
    'providerReadEvidence.evidenceDigest',
  );
  _requireDigest(
    evidence.coverageDigest,
    'providerReadEvidence.coverageDigest',
  );
  _requireDigest(
    begin.providerReadEvidenceDigest,
    'providerReadEvidenceDigest',
  );
  if (evidence.evidenceDigest != begin.providerReadEvidenceDigest) {
    _invalid('providerReadEvidence digest is not the begin evidence digest');
  }
}

void _validateCoverage(Coverage coverage, String field) {
  final lower = coverage.lowerOrdinal;
  final upper = coverage.upperOrdinal;
  if (lower != null && !_isSafeSigned(lower) ||
      upper != null && !_isSafeSigned(upper)) {
    _invalid('$field bounds must be signed safe integers');
  }
  if (lower != null && upper != null && lower > upper) {
    _invalid('$field lower ordinal exceeds upper ordinal');
  }
}

void _validateBegin(
  ConversationRepository repository,
  MaterializationBegin begin,
) {
  _validateMaterializationIdentity(
    key: begin.key,
    materializationId: begin.materializationId,
    fence: begin.fence,
    sourceRevision: begin.sourceRevision,
    pageCount: begin.pageCount,
  );
  _validateProviderReadEvidence(begin);
  _validateCoverage(begin.coverage, 'coverage');
  if (begin.totalItemCount < 0 ||
      begin.totalItemCount > repository.maxEntriesPerThread) {
    _invalid('totalItemCount is outside the configured hard bound');
  }
  if (begin.health == ReadHealth.error &&
      (begin.problemCode == null || begin.problemCode!.isEmpty)) {
    _invalid('error materialization requires a problemCode');
  }
  if (begin.problemCode != null) {
    _requireIdentity(begin.problemCode!, 'problemCode');
  }
  if (begin.requestId.isNotEmpty) {
    _requireIdentity(begin.requestId, 'requestId');
  }
  if (begin.readKind.isNotEmpty) _requireIdentity(begin.readKind, 'readKind');
  if (begin.pageCount == 0) {
    final proof = begin.emptyProof;
    if (proof == null ||
        begin.totalItemCount != 0 ||
        begin.health != ReadHealth.empty ||
        !begin.isSnapshot ||
        !begin.coverage.isComplete ||
        begin.coverage.lowerOrdinal != null ||
        begin.coverage.upperOrdinal != null) {
      _invalid(
        'zero-page materialization requires an exact authoritative empty proof',
      );
    }
    _validateEmptyProof(begin, proof);
  } else if (begin.emptyProof != null) {
    _invalid('non-empty materialization cannot carry an empty proof');
  }
}

void _validateEmptyProof(MaterializationBegin begin, ReplicaEmptyProof proof) {
  if (proof.proofKind != ReplicaEmptyProofKind.providerAuthoritativeEmpty) {
    _invalid('empty proof kind is not supported by this generated seam');
  }
  _requireIdentity(proof.providerRevision, 'emptyProof.providerRevision');
  _requireDigest(
    proof.providerReadEvidenceDigest,
    'emptyProof.providerReadEvidenceDigest',
  );
  _requireDigest(proof.observationDigest, 'emptyProof.observationDigest');
  if (proof.providerReadEvidenceDigest != begin.providerReadEvidenceDigest) {
    _invalid('empty proof evidence digest does not match begin evidence');
  }
}

void _validatePage(
  ConversationRepository repository,
  MaterializationPage page,
) {
  _validateMaterializationIdentity(
    key: page.key,
    materializationId: page.materializationId,
    fence: page.fence,
    sourceRevision: page.sourceRevision,
    pageCount: page.pageCount,
  );
  if (page.pageCount == 0 ||
      page.pageIndex < 0 ||
      page.pageIndex >= page.pageCount) {
    _invalid('page index/count are inconsistent');
  }
  if (page.pageIndex == 0 && page.previousPageDigest != null ||
      page.pageIndex > 0 && page.previousPageDigest == null) {
    _invalid('previousPageDigest must exist exactly for non-first pages');
  }
  _requireDigest(page.pageDigest, 'pageDigest');
  if (page.previousPageDigest != null) {
    _requireDigest(page.previousPageDigest!, 'previousPageDigest');
  }
  final artifact = repository._verifiedPreimage(
    repository._contractMapper.pageBody(page.body),
    'page body',
  );
  if (artifact.bytes.length > ConversationRepository.maxPageBodyBytes) {
    throw const ConversationRepositoryException(
      RepositoryFailureCode.capacityExceeded,
      'materialization page body exceeds the 256 KiB hard bound',
    );
  }
  if (artifact.digest != page.pageDigest) {
    throw const ConversationRepositoryException(
      RepositoryFailureCode.digestMismatch,
      'pageDigest does not match the generated page preimage',
    );
  }
  _validateBodyIdentity(page.body);
}

void _validateCommit(MaterializationCommit commit) {
  _validateMaterializationIdentity(
    key: commit.key,
    materializationId: commit.materializationId,
    fence: commit.fence,
    sourceRevision: commit.sourceRevision,
    pageCount: commit.pageCount,
  );
  _requireDigest(
    commit.providerReadEvidenceDigest,
    'providerReadEvidenceDigest',
  );
  _requireDigest(commit.pageManifestDigest, 'pageManifestDigest');
  if (commit.pageCount == 0) {
    if (commit.finalPageDigest != null || commit.emptyProofDigest == null) {
      _invalid(
        'zero-page commit requires emptyProofDigest and no final digest',
      );
    }
    _requireDigest(commit.emptyProofDigest!, 'emptyProofDigest');
  } else {
    if (commit.finalPageDigest == null || commit.emptyProofDigest != null) {
      _invalid('non-empty commit requires finalPageDigest and no empty proof');
    }
    _requireDigest(commit.finalPageDigest!, 'finalPageDigest');
  }
}

void _validateRuntimeProjection(RuntimeProjectionEnvelope projection) {
  _validateKey(projection.key);
  _requireIdentity(projection.projectionId, 'projectionId');
  _validateFence(projection.fence, 'projection.fence');
  if (!_isSafeUnsigned(projection.sourceRevision)) {
    _invalid('projection sourceRevision must be a non-negative safe integer');
  }
  if (projection.operations.isEmpty &&
      projection.queueEntries.isEmpty &&
      projection.interactions.isEmpty &&
      !projection.operationSnapshotComplete &&
      !projection.queueSnapshotComplete &&
      !projection.interactionSnapshotComplete) {
    _invalid('projection must carry facts or an explicit complete snapshot');
  }
  final operationIds = <String>{};
  for (final value in projection.operations) {
    _requireIdentity(value.operationId, 'operationId');
    _requireIdentity(value.state, 'operation.state');
    if (!_isSafeUnsigned(value.revision) ||
        !operationIds.add(value.operationId)) {
      _invalid('operation identity or revision is invalid');
    }
  }
  final queueIds = <String>{};
  for (final value in projection.queueEntries) {
    _requireIdentity(value.queueEntryId, 'queueEntryId');
    _requireIdentity(value.state, 'queueEntry.state');
    if (value.operationId != null) {
      _requireIdentity(value.operationId!, 'queueEntry.operationId');
    }
    if (!_isSafeUnsigned(value.revision) ||
        !_isSafeUnsigned(value.position) ||
        !queueIds.add(value.queueEntryId)) {
      _invalid('queue entry identity or revision is invalid');
    }
  }
  final interactionIds = <String>{};
  for (final value in projection.interactions) {
    _requireIdentity(value.interactionId, 'interactionId');
    _requireIdentity(value.kind, 'interaction.kind');
    _requireIdentity(value.state, 'interaction.state');
    if (value.claimActorId != null) {
      _requireIdentity(value.claimActorId!, 'claimActorId');
    }
    if (!_isSafeUnsigned(value.revision) ||
        !interactionIds.add(value.interactionId)) {
      _invalid('interaction identity or revision is invalid');
    }
  }
}

void _validateBodyIdentity(MaterializationPageBody body) {
  final identities = <String>{};
  final timelines = <int>{};
  final turnItems = <String>{};
  final turns = <String, int>{};
  for (final item in body.items) {
    _requireIdentity(item.providerTurnId, 'providerTurnId');
    _requireIdentity(item.providerItemId, 'providerItemId');
    _requireIdentity(item.kind, 'item.kind');
    if (!_isSafeSigned(item.turnOrdinal) ||
        !_isSafeUnsigned(item.itemOrdinal) ||
        !_isSafeSigned(item.timelineOrdinal)) {
      _invalid('item ordinals are outside the safe integer bounds');
    }
    final identity = '${item.providerTurnId}\u0000${item.providerItemId}';
    if (!identities.add(identity)) {
      _invalid('duplicate provider item identity');
    }
    if (!timelines.add(item.timelineOrdinal)) {
      _invalid('duplicate timeline ordinal');
    }
    final turnItem = '${item.providerTurnId}\u0000${item.itemOrdinal}';
    if (!turnItems.add(turnItem)) _invalid('duplicate turn-local item ordinal');
    final priorTurn = turns[item.providerTurnId];
    if (priorTurn != null && priorTurn != item.turnOrdinal) {
      _invalid('provider turn identity has inconsistent ordinals');
    }
    turns[item.providerTurnId] = item.turnOrdinal;
  }
  final gaps = <String>{};
  for (final gap in body.gaps) {
    _requireIdentity(gap.gapId, 'gapId');
    if (!gaps.add(gap.gapId)) _invalid('duplicate gap identity');
    if (!_isSafeSigned(gap.startOrdinal) ||
        gap.endOrdinal != null &&
            (!_isSafeSigned(gap.endOrdinal!) ||
                gap.endOrdinal! < gap.startOrdinal)) {
      _invalid('gap ordinal range is invalid');
    }
  }
}

void _validateEnvelope(
  ConversationRepository repository,
  _CanonicalEnvelope envelope,
) {
  _validateKey(envelope.key);
  _requireIdentity(envelope.envelopeId, 'envelopeId');
  _validateFence(envelope.fence, 'envelope.fence');
  if (!_isSafeUnsigned(envelope.sourceRevision)) {
    _invalid('envelope sourceRevision is outside the safe integer range');
  }
  _requireDigest(
    envelope.providerReadEvidenceDigest,
    'providerReadEvidenceDigest',
  );
  _validateCoverage(envelope.coverage, 'envelope.coverage');
  if (envelope.pageCount == 0) {
    if (envelope.pageIndex != -1 || envelope.emptyProof == null) {
      _invalid('zero-page envelope requires an empty proof');
    }
  } else if (envelope.pageIndex < 0 ||
      envelope.pageIndex >= envelope.pageCount ||
      envelope.emptyProof != null) {
    _invalid('envelope page index/count is inconsistent');
  }
  if ((envelope.health == ReadHealth.empty ||
          envelope.health == ReadHealth.error) &&
      envelope.items.isNotEmpty) {
    _invalid('empty/error envelopes cannot carry canonical items');
  }
  if (envelope.health == ReadHealth.error &&
      (envelope.problemCode == null || envelope.problemCode!.isEmpty)) {
    _invalid('error envelope requires a problemCode');
  }
  if (envelope.problemCode != null) {
    _requireIdentity(envelope.problemCode!, 'problemCode');
  }
  _validateBodyIdentity(
    MaterializationPageBody(items: envelope.items, gaps: envelope.gaps),
  );
  final lower = envelope.coverage.lowerOrdinal;
  final upper = envelope.coverage.upperOrdinal;
  for (final item in envelope.items) {
    if (lower != null && item.timelineOrdinal < lower ||
        upper != null && item.timelineOrdinal > upper) {
      _invalid('item is outside its declared coverage bounds');
    }
  }
  var structuralGap = false;
  var payloadGap = false;
  for (final gap in envelope.gaps) {
    if (lower != null && gap.startOrdinal < lower ||
        upper != null && gap.startOrdinal > upper ||
        gap.endOrdinal != null &&
            (lower != null && gap.endOrdinal! < lower ||
                upper != null && gap.endOrdinal! > upper)) {
      _invalid('gap is outside its declared coverage bounds');
    }
    payloadGap |= gap.kind == GapKind.payload;
    structuralGap |= gap.kind != GapKind.payload;
  }
  if (envelope.coverage.structural == StructuralCoverage.complete &&
          structuralGap ||
      envelope.coverage.structural == StructuralCoverage.partial &&
          !structuralGap) {
    _invalid('structural coverage does not match typed gaps');
  }
  if (envelope.coverage.payload == PayloadCoverage.complete && payloadGap ||
      envelope.coverage.payload == PayloadCoverage.partial && !payloadGap) {
    _invalid('payload coverage does not match typed gaps');
  }
  if (envelope.health == ReadHealth.empty) {
    if (envelope.emptyProof != null) {
      if (!envelope.coverage.isComplete ||
          envelope.items.isNotEmpty ||
          envelope.gaps.isNotEmpty) {
        _invalid('authoritative empty proof requires complete empty coverage');
      }
    } else if (envelope.coverage.structural != StructuralCoverage.partial ||
        !structuralGap) {
      _invalid('unproven empty observation requires a structural gap');
    }
  }
  if (envelope.coverage.structural == StructuralCoverage.complete &&
      envelope.items.isNotEmpty) {
    final ordinals = envelope.items.map((item) => item.timelineOrdinal).toList()
      ..sort();
    for (var index = 1; index < ordinals.length; index += 1) {
      if (ordinals[index] != ordinals[index - 1] + 1) {
        _invalid('complete coverage contains a timeline ordinal hole');
      }
    }
  }
  if (envelope.items.length > repository.maxEntriesPerThread) {
    _invalid('envelope item count exceeds the configured hard bound');
  }
}

bool _isSafeUnsigned(int value) => value >= 0 && value <= 9007199254740991;

bool _isSafeSigned(int value) =>
    value >= -9007199254740991 && value <= 9007199254740991;

void _requireDigest(String value, String field) {
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
    _invalid('$field must be a lowercase SHA-256 digest');
  }
}

void _requireIdentity(String value, String field, {int maxLength = 1024}) {
  if (value.isEmpty || value.trim() != value || value.length > maxLength) {
    _invalid('$field must be a non-empty bounded opaque identifier');
  }
}

Never _invalid(String message) {
  throw ConversationRepositoryException(
    RepositoryFailureCode.invalidEnvelope,
    message,
  );
}
