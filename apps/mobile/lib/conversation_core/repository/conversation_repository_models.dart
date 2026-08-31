// Public, provider-neutral value objects for the Mobile conversation replica.
//
// These objects are deliberately not a wire contract.  A generated contract
// mapper is the only component allowed to turn them into digest preimages.

import 'dart:convert';

const int _jsonMaxDepth = 64;
const int _jsonMaxNodes = 10000;
const int _jsonMaxBytes = 8 * 1024 * 1024;

Map<String, Object?> _normalizedJsonMap(
  Map<String, Object?> value,
  String field,
) {
  _guardJsonValue(value, field);
  final frozen = <String, Object?>{};
  for (final entry in value.entries) {
    frozen[entry.key] = _freezeJsonValue(entry.value);
  }
  return Map<String, Object?>.unmodifiable(frozen);
}

Object? _freezeJsonValue(Object? value) {
  if (value is Map) {
    final frozen = <Object?, Object?>{};
    for (final entry in value.entries) {
      frozen[entry.key] = _freezeJsonValue(entry.value);
    }
    return Map<Object?, Object?>.unmodifiable(frozen);
  }
  if (value is List) {
    return List<Object?>.unmodifiable(value.map<Object?>(_freezeJsonValue));
  }
  return value;
}

/// Checks public JSON before any recursive freeze or byte serialization.
/// Identity based active-node tracking makes self-referential Maps/Lists fail
/// with a typed error instead of overflowing the Dart stack.
void _guardJsonValue(Object? value, String field) {
  final active = Set<Object>.identity();
  var nodes = 0;
  var utf8Bytes = 0;

  void addBytes(Object? candidate) {
    if (candidate is String) {
      utf8Bytes += utf8.encode(candidate).length;
      if (utf8Bytes > _jsonMaxBytes) {
        throw ArgumentError.value(
          candidate,
          field,
          'nested JSON strings exceed $_jsonMaxBytes UTF-8 bytes',
        );
      }
    }
  }

  void visit(Object? candidate, int depth) {
    if (depth > _jsonMaxDepth) {
      throw ArgumentError.value(
        candidate,
        field,
        'JSON nesting exceeds $_jsonMaxDepth levels',
      );
    }
    nodes += 1;
    if (nodes > _jsonMaxNodes) {
      throw ArgumentError.value(
        candidate,
        field,
        'JSON node count exceeds $_jsonMaxNodes',
      );
    }
    if (candidate == null || candidate is bool) {
      return;
    }
    if (candidate is String) {
      addBytes(candidate);
      return;
    }
    if (candidate is int) {
      if (candidate < -9007199254740991 || candidate > 9007199254740991) {
        throw ArgumentError.value(
          candidate,
          field,
          'JSON integers must be safe integers',
        );
      }
      return;
    }
    if (candidate is double) {
      if (!candidate.isFinite) {
        throw ArgumentError.value(
          candidate,
          field,
          'JSON numbers must be finite',
        );
      }
      return;
    }
    if (candidate is! Map && candidate is! List) {
      throw ArgumentError.value(candidate, field, 'value must be JSON-safe');
    }
    if (!active.add(candidate)) {
      throw ArgumentError.value(candidate, field, 'cyclic JSON value');
    }
    if (candidate is Map) {
      for (final entry in candidate.entries) {
        if (entry.key is! String) {
          throw ArgumentError.value(
            entry.key,
            field,
            'JSON keys must be strings',
          );
        }
        addBytes(entry.key);
        visit(entry.value, depth + 1);
      }
    } else {
      for (final item in candidate as List) {
        visit(item, depth + 1);
      }
    }
    active.remove(candidate);
  }

  visit(value, 0);
}

/// Public only for storage adapters in the same product package.  This is a
/// guard, not a canonicalizer: it never sorts keys and must not be used to
/// produce a digest.
void validateRepositoryJson(Object? value, String field) {
  _guardJsonValue(value, field);
}

class SourcePartition {
  const SourcePartition({
    required this.bridgeIdentityId,
    required this.bridgeInstanceId,
    required this.codexSourceId,
  });

  final String bridgeIdentityId;
  final String bridgeInstanceId;
  final String codexSourceId;

  @override
  bool operator ==(Object other) {
    return other is SourcePartition &&
        other.bridgeIdentityId == bridgeIdentityId &&
        other.bridgeInstanceId == bridgeInstanceId &&
        other.codexSourceId == codexSourceId;
  }

  @override
  int get hashCode =>
      Object.hash(bridgeIdentityId, bridgeInstanceId, codexSourceId);
}

class ThreadKey {
  const ThreadKey({required this.partition, required this.providerThreadId});

  final SourcePartition partition;
  final String providerThreadId;

  @override
  bool operator ==(Object other) {
    return other is ThreadKey &&
        other.partition == partition &&
        other.providerThreadId == providerThreadId;
  }

  @override
  int get hashCode => Object.hash(partition, providerThreadId);
}

class EnvelopeFence {
  const EnvelopeFence({
    required this.connectionEpoch,
    required this.sourceEpoch,
    required this.providerInstanceEpoch,
    required this.runtimeAuthorityGeneration,
  });

  final String connectionEpoch;
  final String sourceEpoch;
  final String providerInstanceEpoch;
  final int runtimeAuthorityGeneration;
}

/// Exact read evidence is supplied by the generated protocol mapper.
/// Repository validation only checks its closed shape and identity binding; it
/// never invents a second evidence digest.
class ProviderReadEvidence {
  const ProviderReadEvidence({
    required this.method,
    required this.buildId,
    required this.resultKind,
    required this.resultDigest,
    required this.evidenceDigest,
    required this.coverageDigest,
  });

  final String method;
  final String buildId;
  final String resultKind;
  final String resultDigest;
  final String evidenceDigest;
  final String coverageDigest;
}

enum StructuralCoverage { complete, partial }

enum PayloadCoverage { complete, partial }

enum ReadHealth { healthy, empty, degraded, error }

enum GapKind { ordinal, payload, unavailable }

class Coverage {
  const Coverage({
    required this.structural,
    required this.payload,
    this.lowerOrdinal,
    this.upperOrdinal,
  });

  final StructuralCoverage structural;
  final PayloadCoverage payload;
  final int? lowerOrdinal;
  final int? upperOrdinal;

  bool get isComplete =>
      structural == StructuralCoverage.complete &&
      payload == PayloadCoverage.complete;
}

class TypedGap {
  TypedGap({
    required this.gapId,
    required this.kind,
    required this.startOrdinal,
    this.endOrdinal,
    Map<String, Object?> details = const <String, Object?>{},
  }) : details = _normalizedJsonMap(details, 'details');

  final String gapId;
  final GapKind kind;
  final int startOrdinal;
  final int? endOrdinal;
  final Map<String, Object?> details;
}

class CanonicalItem {
  CanonicalItem({
    required this.providerTurnId,
    required this.providerItemId,
    required this.turnOrdinal,
    required this.itemOrdinal,
    required this.timelineOrdinal,
    required this.kind,
    required Map<String, Object?> normalizedPayload,
    Map<String, Object?> presentationProjection = const <String, Object?>{},
  }) : normalizedPayload = _normalizedJsonMap(
         normalizedPayload,
         'normalizedPayload',
       ),
       presentationProjection = _normalizedJsonMap(
         presentationProjection,
         'presentationProjection',
       );

  final String providerTurnId;
  final String providerItemId;
  final int turnOrdinal;
  final int itemOrdinal;
  final int timelineOrdinal;
  final String kind;
  final Map<String, Object?> normalizedPayload;
  final Map<String, Object?> presentationProjection;
}

class OperationProjection {
  OperationProjection({
    required this.operationId,
    required this.revision,
    required this.state,
    required this.isTerminal,
    Map<String, Object?> value = const <String, Object?>{},
  }) : value = _normalizedJsonMap(value, 'operationProjection');

  final String operationId;
  final int revision;
  final String state;
  final bool isTerminal;
  final Map<String, Object?> value;
}

class QueueEntryProjection {
  QueueEntryProjection({
    required this.queueEntryId,
    required this.revision,
    required this.position,
    required this.state,
    this.operationId,
    Map<String, Object?> value = const <String, Object?>{},
  }) : value = _normalizedJsonMap(value, 'queueEntryProjection');

  final String queueEntryId;
  final String? operationId;
  final int revision;
  final int position;
  final String state;
  final Map<String, Object?> value;
}

class InteractionProjection {
  InteractionProjection({
    required this.interactionId,
    required this.revision,
    required this.kind,
    required this.state,
    this.claimActorId,
    this.claimExpiresAt,
    Map<String, Object?> value = const <String, Object?>{},
  }) : value = _normalizedJsonMap(value, 'interactionProjection');

  final String interactionId;
  final int revision;
  final String kind;
  final String state;
  final String? claimActorId;
  final DateTime? claimExpiresAt;
  final Map<String, Object?> value;
}

enum ReplicaEmptyProofKind { providerAuthoritativeEmpty }

class ReplicaEmptyProof {
  const ReplicaEmptyProof({
    required this.proofKind,
    required this.providerReadEvidenceDigest,
    required this.observationDigest,
    this.providerRevision = '',
  });

  final ReplicaEmptyProofKind proofKind;
  final String providerReadEvidenceDigest;
  final String observationDigest;
  final String providerRevision;
}

class MaterializationBegin {
  const MaterializationBegin({
    required this.materializationId,
    required this.key,
    required this.fence,
    required this.sourceRevision,
    required this.coverage,
    required this.health,
    required this.pageCount,
    required this.totalItemCount,
    required this.providerReadEvidenceDigest,
    this.providerReadEvidence,
    this.requestId = '',
    this.readKind = '',
    this.problemCode,
    this.isSnapshot = false,
    this.emptyProof,
  });

  final String materializationId;
  final ThreadKey key;
  final EnvelopeFence fence;
  final int sourceRevision;
  final Coverage coverage;
  final ReadHealth health;
  final String? problemCode;
  final int pageCount;
  final int totalItemCount;
  final String providerReadEvidenceDigest;
  final ProviderReadEvidence? providerReadEvidence;
  final String requestId;
  final String readKind;
  final bool isSnapshot;
  final ReplicaEmptyProof? emptyProof;
}

class MaterializationPageBody {
  MaterializationPageBody({
    List<CanonicalItem> items = const <CanonicalItem>[],
    List<TypedGap> gaps = const <TypedGap>[],
  }) : items = List<CanonicalItem>.unmodifiable(items),
       gaps = List<TypedGap>.unmodifiable(gaps);

  final List<CanonicalItem> items;
  final List<TypedGap> gaps;
}

class RuntimeProjectionEnvelope {
  RuntimeProjectionEnvelope({
    required this.projectionId,
    required this.key,
    required this.fence,
    required this.sourceRevision,
    List<OperationProjection> operations = const <OperationProjection>[],
    List<QueueEntryProjection> queueEntries = const <QueueEntryProjection>[],
    List<InteractionProjection> interactions = const <InteractionProjection>[],
    this.operationSnapshotComplete = false,
    this.queueSnapshotComplete = false,
    this.interactionSnapshotComplete = false,
  }) : operations = List<OperationProjection>.unmodifiable(operations),
       queueEntries = List<QueueEntryProjection>.unmodifiable(queueEntries),
       interactions = List<InteractionProjection>.unmodifiable(interactions);

  final String projectionId;
  final ThreadKey key;
  final EnvelopeFence fence;
  final int sourceRevision;
  final List<OperationProjection> operations;
  final List<QueueEntryProjection> queueEntries;
  final List<InteractionProjection> interactions;
  final bool operationSnapshotComplete;
  final bool queueSnapshotComplete;
  final bool interactionSnapshotComplete;
}

class MaterializationPage {
  const MaterializationPage({
    required this.materializationId,
    required this.key,
    required this.fence,
    required this.sourceRevision,
    required this.pageIndex,
    required this.pageCount,
    required this.pageDigest,
    required this.body,
    this.previousPageDigest,
  });

  final String materializationId;
  final ThreadKey key;
  final EnvelopeFence fence;
  final int sourceRevision;
  final int pageIndex;
  final int pageCount;
  final String? previousPageDigest;
  final String pageDigest;
  final MaterializationPageBody body;
}

class MaterializationCommit {
  const MaterializationCommit({
    required this.materializationId,
    required this.key,
    required this.fence,
    required this.sourceRevision,
    required this.pageCount,
    required this.finalPageDigest,
    required this.pageManifestDigest,
    required this.providerReadEvidenceDigest,
    this.emptyProofDigest,
  });

  final String materializationId;
  final ThreadKey key;
  final EnvelopeFence fence;
  final int sourceRevision;
  final int pageCount;
  final String? finalPageDigest;
  final String pageManifestDigest;
  final String providerReadEvidenceDigest;
  final String? emptyProofDigest;
}

class StagingReceipt {
  const StagingReceipt({
    required this.materializationId,
    required this.wasDuplicate,
  });

  final String materializationId;
  final bool wasDuplicate;
}

class RepositoryWindow {
  RepositoryWindow({
    required this.key,
    required this.fence,
    required this.sourceRevision,
    required this.lastGoodRevision,
    required this.lastGoodSourceEpoch,
    required this.lastGoodProviderInstanceEpoch,
    required this.coverage,
    required this.health,
    required this.hasEarlier,
    required List<CanonicalItem> items,
    required List<TypedGap> gaps,
    required List<OperationProjection> operations,
    required List<QueueEntryProjection> queueEntries,
    required List<InteractionProjection> interactions,
    this.publicationEventId,
    this.problemCode,
  }) : items = List<CanonicalItem>.unmodifiable(items),
       gaps = List<TypedGap>.unmodifiable(gaps),
       operations = List<OperationProjection>.unmodifiable(operations),
       queueEntries = List<QueueEntryProjection>.unmodifiable(queueEntries),
       interactions = List<InteractionProjection>.unmodifiable(interactions);

  final ThreadKey key;
  final EnvelopeFence? fence;
  final int sourceRevision;
  final int lastGoodRevision;
  final String? lastGoodSourceEpoch;
  final String? lastGoodProviderInstanceEpoch;
  final Coverage coverage;
  final ReadHealth health;
  final String? problemCode;
  final bool hasEarlier;
  final List<CanonicalItem> items;
  final List<TypedGap> gaps;
  final List<OperationProjection> operations;
  final List<QueueEntryProjection> queueEntries;
  final List<InteractionProjection> interactions;

  /// Stable durable publication identity when this window was delivered from
  /// the publication outbox.  Consumers must acknowledge it explicitly with
  /// [ConversationRepository.acknowledgePublication].
  final String? publicationEventId;
}

class CommitReceipt {
  const CommitReceipt({
    required this.envelopeId,
    required this.wasDuplicate,
    required this.wasPublished,
    required this.window,
    this.publicationEventId,
  });

  final String envelopeId;
  final bool wasDuplicate;
  final bool wasPublished;
  final RepositoryWindow window;

  /// Stable durable publication identity, if this call handed an event to a
  /// listener or left a published event pending for a later listener.
  final String? publicationEventId;
}

enum RepositoryFailureCode {
  invalidEnvelope,
  materializationNotFound,
  materializationIncomplete,
  digestMismatch,
  staleGeneration,
  staleEpoch,
  staleRevision,
  identityConflict,
  capacityExceeded,
  invalidDatabaseIdentity,
  writerLeaseUnavailable,
  contractUnavailable,
  jsonGuardRejected,
  notOpen,
}

class ConversationRepositoryException implements Exception {
  const ConversationRepositoryException(this.code, this.message);

  final RepositoryFailureCode code;
  final String message;

  @override
  String toString() => 'ConversationRepositoryException($code, $message)';
}

enum RepositoryFaultStage {
  afterValidation,
  afterInboxAdmission,
  afterTransactionWrites,
  afterCommit,
  afterReadback,
  afterPublicationCommit,
}

typedef RepositoryFaultHook = Future<void> Function(
  RepositoryFaultStage stage,
  String operationId,
);

enum RepositoryReadStage { afterState }

typedef RepositoryReadHook = Future<void> Function(
  RepositoryReadStage stage,
  ThreadKey key,
);

/// Optional test/system hook used to prove dead-owner lease reclamation
/// without sending signals or inspecting another application process from
/// Flutter.  The production default relies on the durable heartbeat timeout.
typedef RepositoryProcessLivenessProbe = Future<bool> Function(int pid);
