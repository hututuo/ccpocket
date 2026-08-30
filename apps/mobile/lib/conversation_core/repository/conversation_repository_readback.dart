part of 'conversation_repository.dart';

Future<RepositoryWindow> _readWindow(
  ConversationRepository repository,
  ThreadKey key, {
  int? beforeOrdinal,
  int? limit,
  String? publicationEventId,
}) {
  final db = repository._requireDatabase();
  _validateKey(key);
  final effectiveLimit = limit ?? repository.defaultWindowSize;
  _validateReadLimit(effectiveLimit);
  if (beforeOrdinal != null && !_isSafeSigned(beforeOrdinal)) {
    _invalid('beforeOrdinal must be a signed safe integer');
  }
  return repository._trackRead(
    () => db.readTransaction(
      (txn) => _readWindowInTransaction(
        repository,
        txn,
        key,
        beforeOrdinal: beforeOrdinal,
        limit: effectiveLimit,
        publicationEventId: publicationEventId,
      ),
    ),
  );
}

Future<RepositoryWindow> _readWindowInTransaction(
  ConversationRepository repository,
  DatabaseExecutor db,
  ThreadKey key, {
  required int limit,
  int? beforeOrdinal,
  String? publicationEventId,
}) async {
  final state = await _readThreadState(db, key);
  if (state == null) return _emptyWindow(key);
  await _verifyThreadStateEnvelopeBindings(db, key, state);
  // A non-empty replica is production data, not a best-effort cache.  Do not
  // silently decode it when generated contract outputs are unavailable.
  repository._requireContract();
  await repository.readHook?.call(RepositoryReadStage.afterState, key);
  final itemRows = await db.query(
    'canonical_item',
    where: beforeOrdinal == null
        ? _keyWhere()
        : '${_keyWhere()} AND timeline_ordinal < ?',
    whereArgs: beforeOrdinal == null
        ? _keyArgs(key)
        : <Object?>[..._keyArgs(key), beforeOrdinal],
    orderBy: 'timeline_ordinal DESC',
    limit: limit,
  );
  final items = itemRows.reversed
      .map((row) => _decodeItem(repository, row))
      .toList(growable: false);
  final gapsRows = await db.query(
    'typed_gap',
    where: '${_keyWhere()} AND is_active = 1',
    whereArgs: _keyArgs(key),
    orderBy: 'start_ordinal ASC, gap_id ASC',
  );
  final earlierBoundary = items.isNotEmpty
      ? items.first.timelineOrdinal
      : beforeOrdinal;
  var hasEarlier = false;
  if (earlierBoundary != null) {
    final earlier = await db.rawQuery(
      'SELECT 1 FROM canonical_item WHERE ${_keyWhere()} AND timeline_ordinal < ? LIMIT 1',
      <Object?>[..._keyArgs(key), earlierBoundary],
    );
    hasEarlier = earlier.isNotEmpty;
  }
  if (!hasEarlier) {
    hasEarlier = gapsRows.any((row) {
      if (row['kind'] == GapKind.payload.name) return false;
      if (earlierBoundary == null) return true;
      return (row['start_ordinal']! as int) < earlierBoundary;
    });
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
  final projectionHead = projectionHeadRows.isEmpty
      ? const <String, Object?>{}
      : projectionHeadRows.single;
  String snapshotMarker(String name) {
    final value = projectionHead[name] ?? '';
    if (value is! String) {
      throw ConversationRepositoryException(
        RepositoryFailureCode.invalidDatabaseIdentity,
        'projection head $name is not a valid snapshot marker',
      );
    }
    return value;
  }

  final operationMarker = snapshotMarker('operation_snapshot_marker');
  final queueMarker = snapshotMarker('queue_snapshot_marker');
  final interactionMarker = snapshotMarker('interaction_snapshot_marker');
  final operationRows = await db.query(
    'operation_projection',
    where: '${_keyWhere()} AND is_active = 1 AND snapshot_marker = ?',
    whereArgs: <Object?>[..._keyArgs(key), operationMarker],
    orderBy: 'operation_id ASC',
  );
  final queueRows = await db.query(
    'queue_entry_projection',
    where: '${_keyWhere()} AND is_active = 1 AND snapshot_marker = ?',
    whereArgs: <Object?>[..._keyArgs(key), queueMarker],
    orderBy: 'position ASC, queue_entry_id ASC',
  );
  final interactionRows = await db.query(
    'interaction_projection',
    where: '${_keyWhere()} AND is_active = 1 AND snapshot_marker = ?',
    whereArgs: <Object?>[..._keyArgs(key), interactionMarker],
    orderBy: 'interaction_id ASC',
  );
  return RepositoryWindow(
    key: key,
    publicationEventId: publicationEventId,
    fence: EnvelopeFence(
      connectionEpoch: state['connection_epoch']! as String,
      sourceEpoch: state['source_epoch']! as String,
      providerInstanceEpoch: state['provider_instance_epoch']! as String,
      runtimeAuthorityGeneration: state['runtime_authority_generation']! as int,
    ),
    sourceRevision: state['source_revision']! as int,
    lastGoodRevision: state['last_good_revision']! as int,
    lastGoodSourceEpoch: state['last_good_source_epoch'] as String?,
    lastGoodProviderInstanceEpoch:
        state['last_good_provider_instance_epoch'] as String?,
    coverage: Coverage(
      structural: _structuralCoverage(state['structural_coverage']! as String),
      payload: _payloadCoverage(state['payload_coverage']! as String),
      lowerOrdinal: state['lower_ordinal'] as int?,
      upperOrdinal: state['upper_ordinal'] as int?,
    ),
    health: _readHealth(state['health']! as String),
    problemCode: state['problem_code'] as String?,
    hasEarlier: hasEarlier,
    items: items,
    gaps: gapsRows
        .map((row) => _decodeGap(repository, row))
        .toList(growable: false),
    operations: operationRows
        .map((row) => _decodeOperation(repository, row))
        .toList(growable: false),
    queueEntries: queueRows
        .map((row) => _decodeQueue(repository, row))
        .toList(growable: false),
    interactions: interactionRows
        .map((row) => _decodeInteraction(repository, row))
        .toList(growable: false),
  );
}

Future<void> _verifyThreadStateEnvelopeBindings(
  DatabaseExecutor db,
  ThreadKey key,
  Map<String, Object?> state,
) async {
  Future<void> verify({
    required String label,
    required Object? sourceEpoch,
    required Object? providerEpoch,
    required Object? connectionEpoch,
    required Object? generation,
    required Object? revision,
    required Object? envelopeId,
    required Object? envelopeDigest,
  }) async {
    if (envelopeId == null) return;
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
  }

  await verify(
    label: 'current',
    sourceEpoch: state['source_epoch'],
    providerEpoch: state['provider_instance_epoch'],
    connectionEpoch: state['connection_epoch'],
    generation: state['runtime_authority_generation'],
    revision: state['source_revision'],
    envelopeId: state['current_envelope_id'],
    envelopeDigest: state['current_envelope_digest'],
  );
  if (state['last_good_revision'] == -1) return;
  await verify(
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

RepositoryWindow _emptyWindow(ThreadKey key) => RepositoryWindow(
  key: key,
  fence: null,
  sourceRevision: -1,
  lastGoodRevision: -1,
  lastGoodSourceEpoch: null,
  lastGoodProviderInstanceEpoch: null,
  coverage: const Coverage(
    structural: StructuralCoverage.partial,
    payload: PayloadCoverage.partial,
  ),
  health: ReadHealth.degraded,
  problemCode: 'replica_not_materialized',
  hasEarlier: false,
  items: const <CanonicalItem>[],
  gaps: const <TypedGap>[],
  operations: const <OperationProjection>[],
  queueEntries: const <QueueEntryProjection>[],
  interactions: const <InteractionProjection>[],
);

CanonicalItem _decodeItem(
  ConversationRepository repository,
  Map<String, Object?> row,
) {
  final item = CanonicalItem(
    providerTurnId: row['provider_turn_id']! as String,
    providerItemId: row['provider_item_id']! as String,
    turnOrdinal: row['turn_ordinal']! as int,
    itemOrdinal: row['item_ordinal']! as int,
    timelineOrdinal: row['timeline_ordinal']! as int,
    kind: row['kind']! as String,
    normalizedPayload: _storageMap(
      row['normalized_payload_json']! as String,
      'normalized payload',
    ),
    presentationProjection: _storageMap(
      row['presentation_projection_json']! as String,
      'presentation projection',
    ),
  );
  if (repository._usesGeneratedContract ||
      (repository._allowFixtureContract && repository._usesFixtureContract)) {
    final artifact = repository._verifiedPreimage(
      repository._contractMapper.item(item),
      'stored canonical item',
    );
    if (artifact.digest != row['item_digest']) {
      throw const ConversationRepositoryException(
        RepositoryFailureCode.digestMismatch,
        'stored canonical item digest is invalid',
      );
    }
  }
  return item;
}

TypedGap _decodeGap(
  ConversationRepository repository,
  Map<String, Object?> row,
) {
  final gap = TypedGap(
    gapId: row['gap_id']! as String,
    kind: _gapKind(row['kind']! as String),
    startOrdinal: row['start_ordinal']! as int,
    endOrdinal: row['end_ordinal'] as int?,
    details: _storageMap(row['details_json']! as String, 'gap details'),
  );
  if (repository._usesGeneratedContract ||
      (repository._allowFixtureContract && repository._usesFixtureContract)) {
    final artifact = repository._verifiedPreimage(
      repository._contractMapper.gap(gap),
      'stored typed gap',
    );
    if (artifact.digest != row['gap_digest']) {
      throw const ConversationRepositoryException(
        RepositoryFailureCode.digestMismatch,
        'stored typed gap digest is invalid',
      );
    }
  }
  return gap;
}

OperationProjection _decodeOperation(
  ConversationRepository repository,
  Map<String, Object?> row,
) {
  final operation = OperationProjection(
    operationId: row['operation_id']! as String,
    revision: row['revision']! as int,
    state: row['state']! as String,
    isTerminal: row['is_terminal'] == 1,
    value: _storageMap(row['value_json']! as String, 'operation value'),
  );
  if (repository._usesGeneratedContract ||
      (repository._allowFixtureContract && repository._usesFixtureContract)) {
    final artifact = repository._verifiedPreimage(
      repository._contractMapper.operationProjection(operation),
      'stored operation projection',
    );
    if (artifact.digest != row['value_digest']) {
      throw const ConversationRepositoryException(
        RepositoryFailureCode.digestMismatch,
        'stored operation projection digest is invalid',
      );
    }
  }
  return operation;
}

QueueEntryProjection _decodeQueue(
  ConversationRepository repository,
  Map<String, Object?> row,
) {
  final queueEntry = QueueEntryProjection(
    queueEntryId: row['queue_entry_id']! as String,
    operationId: row['operation_id'] as String?,
    revision: row['revision']! as int,
    position: row['position']! as int,
    state: row['state']! as String,
    value: _storageMap(row['value_json']! as String, 'queue entry value'),
  );
  if (repository._usesGeneratedContract ||
      (repository._allowFixtureContract && repository._usesFixtureContract)) {
    final artifact = repository._verifiedPreimage(
      repository._contractMapper.queueEntryProjection(queueEntry),
      'stored queue entry projection',
    );
    if (artifact.digest != row['value_digest']) {
      throw const ConversationRepositoryException(
        RepositoryFailureCode.digestMismatch,
        'stored queue entry projection digest is invalid',
      );
    }
  }
  return queueEntry;
}

InteractionProjection _decodeInteraction(
  ConversationRepository repository,
  Map<String, Object?> row,
) {
  final expiresAt = row['claim_expires_at'] as int?;
  final interaction = InteractionProjection(
    interactionId: row['interaction_id']! as String,
    revision: row['revision']! as int,
    kind: row['kind']! as String,
    state: row['state']! as String,
    claimActorId: row['claim_actor_id'] as String?,
    claimExpiresAt: expiresAt == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(expiresAt, isUtc: true),
    value: _storageMap(row['value_json']! as String, 'interaction value'),
  );
  if (repository._usesGeneratedContract ||
      (repository._allowFixtureContract && repository._usesFixtureContract)) {
    final artifact = repository._verifiedPreimage(
      repository._contractMapper.interactionProjection(interaction),
      'stored interaction projection',
    );
    if (artifact.digest != row['value_digest']) {
      throw const ConversationRepositoryException(
        RepositoryFailureCode.digestMismatch,
        'stored interaction projection digest is invalid',
      );
    }
  }
  return interaction;
}

StructuralCoverage _structuralCoverage(String value) =>
    StructuralCoverage.values.firstWhere(
      (candidate) => candidate.name == value,
      orElse: () => throw const ConversationRepositoryException(
        RepositoryFailureCode.invalidDatabaseIdentity,
        'stored structural coverage is unknown',
      ),
    );

PayloadCoverage _payloadCoverage(String value) =>
    PayloadCoverage.values.firstWhere(
      (candidate) => candidate.name == value,
      orElse: () => throw const ConversationRepositoryException(
        RepositoryFailureCode.invalidDatabaseIdentity,
        'stored payload coverage is unknown',
      ),
    );

ReadHealth _readHealth(String value) => ReadHealth.values.firstWhere(
  (candidate) => candidate.name == value,
  orElse: () => throw const ConversationRepositoryException(
    RepositoryFailureCode.invalidDatabaseIdentity,
    'stored read health is unknown',
  ),
);

GapKind _gapKind(String value) => GapKind.values.firstWhere(
  (candidate) => candidate.name == value,
  orElse: () => throw const ConversationRepositoryException(
    RepositoryFailureCode.invalidDatabaseIdentity,
    'stored gap kind is unknown',
  ),
);
