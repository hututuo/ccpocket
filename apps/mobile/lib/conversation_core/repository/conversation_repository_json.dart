part of 'conversation_repository.dart';

String _storageJson(Object? value, String field, {int? maxBytes}) {
  try {
    validateRepositoryJson(value, field);
    final encoded = jsonEncode(value);
    final bytes = utf8.encode(encoded).length;
    final bound = maxBytes ?? ConversationRepository.hardMaxBytes;
    if (bytes > bound) {
      throw ConversationRepositoryException(
        RepositoryFailureCode.capacityExceeded,
        '$field exceeds $bound bytes',
      );
    }
    return encoded;
  } on ConversationRepositoryException {
    rethrow;
  } on Object catch (error) {
    throw ConversationRepositoryException(
      RepositoryFailureCode.jsonGuardRejected,
      '$field is not serializable JSON: $error',
    );
  }
}

Map<String, Object?> _storageMap(String encoded, String field) {
  try {
    final decoded = jsonDecode(encoded);
    validateRepositoryJson(decoded, field);
    if (decoded is! Map) {
      throw StateError('$field must decode to an object');
    }
    final result = <String, Object?>{};
    for (final entry in decoded.entries) {
      if (entry.key is! String) {
        throw StateError('$field contains a non-string key');
      }
      result[entry.key as String] = entry.value;
    }
    return result;
  } on ConversationRepositoryException {
    rethrow;
  } on Object catch (error) {
    throw ConversationRepositoryException(
      RepositoryFailureCode.jsonGuardRejected,
      'stored $field is invalid JSON: $error',
    );
  }
}

Map<String, Object?> _itemStorageValue(CanonicalItem item) => <String, Object?>{
  'providerTurnId': item.providerTurnId,
  'providerItemId': item.providerItemId,
  'turnOrdinal': item.turnOrdinal,
  'itemOrdinal': item.itemOrdinal,
  'timelineOrdinal': item.timelineOrdinal,
  'kind': item.kind,
  'normalizedPayload': item.normalizedPayload,
  'presentationProjection': item.presentationProjection,
};

Map<String, Object?> _gapStorageValue(TypedGap gap) => <String, Object?>{
  'gapId': gap.gapId,
  'kind': gap.kind.name,
  'startOrdinal': gap.startOrdinal,
  'endOrdinal': gap.endOrdinal,
  'details': gap.details,
};

Map<String, Object?> _pageStorageValue(MaterializationPageBody body) =>
    <String, Object?>{
      'items': body.items.map(_itemStorageValue).toList(growable: false),
      'gaps': body.gaps.map(_gapStorageValue).toList(growable: false),
    };

MaterializationPageBody _decodePageBody(String encoded) {
  final value = _storageMap(encoded, 'page body');
  final rawItems = value['items'];
  final rawGaps = value['gaps'];
  if (rawItems is! List || rawGaps is! List) {
    throw const ConversationRepositoryException(
      RepositoryFailureCode.invalidEnvelope,
      'stored page body must contain items and gaps arrays',
    );
  }
  Map<String, Object?> asMap(Object? candidate, String field) {
    if (candidate is! Map) {
      throw ConversationRepositoryException(
        RepositoryFailureCode.invalidEnvelope,
        '$field must be an object',
      );
    }
    final result = <String, Object?>{};
    for (final entry in candidate.entries) {
      if (entry.key is! String) {
        throw ConversationRepositoryException(
          RepositoryFailureCode.invalidEnvelope,
          '$field has a non-string key',
        );
      }
      result[entry.key as String] = entry.value;
    }
    return result;
  }

  CanonicalItem decodeItem(Object? candidate) {
    final item = asMap(candidate, 'stored item');
    Map<String, Object?> objectField(String name) =>
        asMap(item[name], 'stored item.$name');
    return CanonicalItem(
      providerTurnId: item['providerTurnId']! as String,
      providerItemId: item['providerItemId']! as String,
      turnOrdinal: item['turnOrdinal']! as int,
      itemOrdinal: item['itemOrdinal']! as int,
      timelineOrdinal: item['timelineOrdinal']! as int,
      kind: item['kind']! as String,
      normalizedPayload: objectField('normalizedPayload'),
      presentationProjection: objectField('presentationProjection'),
    );
  }

  TypedGap decodeGap(Object? candidate) {
    final gap = asMap(candidate, 'stored gap');
    final kindName = gap['kind'];
    final kind = GapKind.values.firstWhere(
      (value) => value.name == kindName,
      orElse: () => throw const ConversationRepositoryException(
        RepositoryFailureCode.invalidEnvelope,
        'stored gap kind is unknown',
      ),
    );
    return TypedGap(
      gapId: gap['gapId']! as String,
      kind: kind,
      startOrdinal: gap['startOrdinal']! as int,
      endOrdinal: gap['endOrdinal'] as int?,
      details: asMap(gap['details'], 'stored gap.details'),
    );
  }

  return MaterializationPageBody(
    items: rawItems.map(decodeItem).toList(growable: false),
    gaps: rawGaps.map(decodeGap).toList(growable: false),
  );
}

Map<String, Object?> _projectionStorageValue(
  RuntimeProjectionEnvelope projection,
) => <String, Object?>{
  'projectionId': projection.projectionId,
  'sourcePartition': <String, Object?>{
    'bridgeIdentityId': projection.key.partition.bridgeIdentityId,
    'bridgeInstanceId': projection.key.partition.bridgeInstanceId,
    'codexSourceId': projection.key.partition.codexSourceId,
  },
  'providerThreadId': projection.key.providerThreadId,
  'fence': <String, Object?>{
    'connectionEpoch': projection.fence.connectionEpoch,
    'sourceEpoch': projection.fence.sourceEpoch,
    'providerInstanceEpoch': projection.fence.providerInstanceEpoch,
    'runtimeAuthorityGeneration': projection.fence.runtimeAuthorityGeneration,
  },
  'sourceRevision': projection.sourceRevision,
  'operationSnapshotComplete': projection.operationSnapshotComplete,
  'queueSnapshotComplete': projection.queueSnapshotComplete,
  'interactionSnapshotComplete': projection.interactionSnapshotComplete,
  'operations': projection.operations
      .map(
        (value) => <String, Object?>{
          'operationId': value.operationId,
          'revision': value.revision,
          'state': value.state,
          'isTerminal': value.isTerminal,
          'value': value.value,
        },
      )
      .toList(growable: false),
  'queueEntries': projection.queueEntries
      .map(
        (value) => <String, Object?>{
          'queueEntryId': value.queueEntryId,
          'operationId': value.operationId,
          'revision': value.revision,
          'position': value.position,
          'state': value.state,
          'value': value.value,
        },
      )
      .toList(growable: false),
  'interactions': projection.interactions
      .map(
        (value) => <String, Object?>{
          'interactionId': value.interactionId,
          'revision': value.revision,
          'kind': value.kind,
          'state': value.state,
          'claimActorId': value.claimActorId,
          'claimExpiresAt': value.claimExpiresAt?.millisecondsSinceEpoch,
          'value': value.value,
        },
      )
      .toList(growable: false),
};

RuntimeProjectionEnvelope _decodeProjection(String encoded) {
  final root = _storageMap(encoded, 'projection inbox');
  Map<String, Object?> asMap(Object? value, String field) {
    if (value is! Map) {
      throw ConversationRepositoryException(
        RepositoryFailureCode.invalidEnvelope,
        '$field must be an object',
      );
    }
    final result = <String, Object?>{};
    for (final entry in value.entries) {
      if (entry.key is! String) {
        throw ConversationRepositoryException(
          RepositoryFailureCode.invalidEnvelope,
          '$field has a non-string key',
        );
      }
      result[entry.key as String] = entry.value;
    }
    return result;
  }

  final partition = asMap(root['sourcePartition'], 'projection source');
  final fence = asMap(root['fence'], 'projection fence');
  final key = ThreadKey(
    partition: SourcePartition(
      bridgeIdentityId: partition['bridgeIdentityId']! as String,
      bridgeInstanceId: partition['bridgeInstanceId']! as String,
      codexSourceId: partition['codexSourceId']! as String,
    ),
    providerThreadId: root['providerThreadId']! as String,
  );
  final operations = (root['operations']! as List)
      .map((value) {
        final row = asMap(value, 'projection operation');
        return OperationProjection(
          operationId: row['operationId']! as String,
          revision: row['revision']! as int,
          state: row['state']! as String,
          isTerminal: row['isTerminal']! as bool,
          value: asMap(row['value'], 'projection operation.value'),
        );
      })
      .toList(growable: false);
  final queueEntries = (root['queueEntries']! as List)
      .map((value) {
        final row = asMap(value, 'projection queue entry');
        return QueueEntryProjection(
          queueEntryId: row['queueEntryId']! as String,
          operationId: row['operationId'] as String?,
          revision: row['revision']! as int,
          position: row['position']! as int,
          state: row['state']! as String,
          value: asMap(row['value'], 'projection queue entry.value'),
        );
      })
      .toList(growable: false);
  final interactions = (root['interactions']! as List)
      .map((value) {
        final row = asMap(value, 'projection interaction');
        final expiresAt = row['claimExpiresAt'] as int?;
        return InteractionProjection(
          interactionId: row['interactionId']! as String,
          revision: row['revision']! as int,
          kind: row['kind']! as String,
          state: row['state']! as String,
          claimActorId: row['claimActorId'] as String?,
          claimExpiresAt: expiresAt == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(expiresAt, isUtc: true),
          value: asMap(row['value'], 'projection interaction.value'),
        );
      })
      .toList(growable: false);
  return RuntimeProjectionEnvelope(
    projectionId: root['projectionId']! as String,
    key: key,
    fence: EnvelopeFence(
      connectionEpoch: fence['connectionEpoch']! as String,
      sourceEpoch: fence['sourceEpoch']! as String,
      providerInstanceEpoch: fence['providerInstanceEpoch']! as String,
      runtimeAuthorityGeneration: fence['runtimeAuthorityGeneration']! as int,
    ),
    sourceRevision: root['sourceRevision']! as int,
    operations: operations,
    queueEntries: queueEntries,
    interactions: interactions,
    operationSnapshotComplete: root['operationSnapshotComplete']! as bool,
    queueSnapshotComplete: root['queueSnapshotComplete']! as bool,
    interactionSnapshotComplete: root['interactionSnapshotComplete']! as bool,
  );
}

ContractPreimage _verifyContractPreimage(
  ConversationRepository repository,
  ContractPreimage value,
  String field,
) {
  final profileMatches = identical(
    value.authorityProfile,
    repository._contractMapper.authorityProfile,
  );
  if (!profileMatches ||
      value.authorityId != repository._contractMapper.authorityId ||
      value.authorityId.trim().isEmpty ||
      value.bytes.length > ConversationRepository.hardMaxBytes) {
    throw ConversationRepositoryException(
      RepositoryFailureCode.contractUnavailable,
      '$field preimage is not bound to the selected contract authority',
    );
  }
  final actualDigest = sha256.convert(value.bytes).toString();
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(value.digest) ||
      actualDigest != value.digest) {
    throw ConversationRepositoryException(
      RepositoryFailureCode.digestMismatch,
      '$field preimage digest does not match its bytes',
    );
  }
  if (repository._usesGeneratedContract) {
    if (value.algorithm != 'SHA256_RFC8785') {
      throw ConversationRepositoryException(
        RepositoryFailureCode.contractUnavailable,
        '$field generated preimage is not labelled SHA256_RFC8785',
      );
    }
  } else if (!repository._allowFixtureContract ||
      !repository._usesFixtureContract ||
      !value.algorithm.startsWith('TEST_FIXTURE_')) {
    throw ConversationRepositoryException(
      RepositoryFailureCode.contractUnavailable,
      '$field uses a non-generated contract outside explicit fixture mode',
    );
  }
  return value;
}
