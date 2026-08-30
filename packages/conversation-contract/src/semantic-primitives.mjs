import {canonicalUtf8, jcsDigest} from './canonical.mjs';

export const PROFILE_ID = 'pvmc1.phone-core.v1';
export const CODEX_BUILD_SHA256 = '98491713ffb196061003ee148636e743997cc31d76144ba7c53462269896891d';
export const MAX_PROVIDER_TURN_BYTES = 4 * 1024 * 1024;
export const MAX_PUBLICATION_PAGE_BYTES = 256 * 1024;
export const MAX_CONTROL_PAYLOAD_BYTES = 57_344;
export const MAX_CONTROL_FRAME_BYTES = 65_536;
export const MAX_TURN_IMAGE_COUNT = 5;
export const MAX_IMAGE_BYTES = 10 * 1024 * 1024;
export const MAX_INLINE_TEXT_BYTES = 40_960;

export const SOURCE = Object.freeze({
  bridgeIdentityId: 'bi-1',
  bridgeInstanceId: 'bridge-1',
  codexSourceId: 'codex-1',
});

const CERTIFICATION_DOMAIN = 'ccpocket.codex-adapter-certification.v1';
const READ_PLAN_DOMAIN = 'ccpocket.timeline-read-plan.v1';
const READ_SPEC_DOMAIN = 'ccpocket.timeline-provider-read-spec.v1';
const READ_RESULT_DOMAIN = 'ccpocket.timeline-provider-read-result.v1';
const READ_EVIDENCE_DOMAIN = 'ccpocket.timeline-provider-read-evidence.v1';
const REPAIR_DOMAIN = 'ccpocket.gap-repair-intent.v1';
const PAGE_DOMAIN = 'ccpocket.materialization-page.v1';
const ORDER_DOMAIN = 'ccpocket.materialization-order.v1';
const COVERAGE_DOMAIN = 'ccpocket.materialization-coverage.v1';
const MANIFEST_DOMAIN = 'ccpocket.materialization-manifest.v1';
const BEGIN_DOMAIN = 'ccpocket.materialization-begin.v1';
const ORDER_PROOF_DOMAIN = 'ccpocket.order-proof.v1';
const PAYLOAD_COMMITMENT_DOMAIN = 'ccpocket.timeline-payload-commitment.v1';
const OPERATION_DOMAIN = 'ccpocket.operation-fingerprint.v1';
const PRECONDITION_DOMAIN = 'ccpocket.operation-precondition.v1';

// TIMELINE wire values carry only the historical flat id + digest reference;
// this closed global preimage is the authority that digest resolves to.  It
// deliberately excludes sourcePartition: source/scope/epoch fencing belongs
// to the read plan/spec/evidence, while this record certifies the Codex adapter
// globally.
const DEFAULT_CERTIFICATION_ID = 'codex-cert-0.151.0';
const CERTIFICATION_METHODS = Object.freeze({
  supported: Object.freeze(['thread/turns/list']),
  unsupported: Object.freeze(['thread/items/list', 'thread/timeline/list']),
});
const CERTIFICATION_SCHEMA = Object.freeze({
  profileId: PROFILE_ID,
  readPlan: 'TimelineReadPlanV1',
  readSpec: 'TimelineProviderReadSpecV1',
  normalizedResult: 'TimelineProviderReadResultV1',
  readBody: 'TimelineProviderReadBodyV1',
  readEvidence: 'TimelineProviderReadEvidenceV1',
});
const CERTIFICATION_PROBE = Object.freeze({
  runtime: Object.freeze({
    'thread/turns/list': 'AVAILABLE',
    'thread/items/list': 'RUNTIME_UNAVAILABLE',
    'thread/timeline/list': 'RUNTIME_UNAVAILABLE',
  }),
  cursor: 'OPAQUE_CURSOR_V1',
  sortDirection: Object.freeze(['asc', 'desc']),
  itemsView: Object.freeze(['notLoaded', 'full']),
});
const CERTIFICATION_SEMANTICS = Object.freeze({
  identity: 'TURN_REF_ITEM_REF_V1',
  ordering: 'CODEX_THREAD_TURNS_PROVIDER_ORDER_V1',
  itemOrdering: 'TURN_ORDINAL_ITEM_ORDINAL_TIMELINE_ORDINAL_CONTIGUITY_V1',
  predecessorEdge: 'PREDECESSOR_REFERENCE_EDGE_V1',
});
const CERTIFICATION_STATUS = Object.freeze({
  historyRead: 'CERTIFIED',
  ordering: 'CERTIFIED',
  cursor: 'CERTIFIED',
  identity: 'CERTIFIED',
  mutation: 'NOT_CERTIFIED',
  capacity: 'CERTIFIED',
});
const CERTIFICATION_PREIMAGE = Object.freeze({
  certificationVersion: 'CodexAdapterCertificationV1',
  digestDomain: CERTIFICATION_DOMAIN,
  certificationId: DEFAULT_CERTIFICATION_ID,
  codexExecutableDigest: CODEX_BUILD_SHA256,
  providerBuildDigest: CODEX_BUILD_SHA256,
  methods: CERTIFICATION_METHODS,
  schema: CERTIFICATION_SCHEMA,
  probe: CERTIFICATION_PROBE,
  semantics: CERTIFICATION_SEMANTICS,
  status: CERTIFICATION_STATUS,
  certificationRevision: 1,
});
const DEFAULT_CERTIFICATION_DIGEST = jcsDigest(CERTIFICATION_PREIMAGE);

const CERTIFICATION_PROBE_FACTS = Object.freeze({
  providerMethod: 'thread/turns/list',
  runtime: CERTIFICATION_PROBE.runtime,
  cursor: CERTIFICATION_PROBE.cursor,
  sortDirection: CERTIFICATION_PROBE.sortDirection,
  itemsView: CERTIFICATION_PROBE.itemsView,
  identity: CERTIFICATION_SEMANTICS.identity,
  ordering: CERTIFICATION_SEMANTICS.ordering,
});

function sourceOf(value) {
  return value?.sourcePartition ?? value?.source ?? SOURCE;
}

function withoutUndefined(value) {
  return Object.fromEntries(Object.entries(value).filter(([, entry]) => entry !== undefined));
}

function certification(id = 'codex-cert-0.151.0') {
  if (id !== DEFAULT_CERTIFICATION_ID) {
    return {codexCertificationId: id, codexCertificationDigest: null};
  }
  return {
    codexCertificationId: id,
    codexCertificationDigest: DEFAULT_CERTIFICATION_DIGEST,
  };
}

/**
 * Build the immutable certification/probe authority used by strict semantic
 * observations.  `codexCertificationDigest` is a catalog value, never a
 * hash of caller-provided id plus the executable hash.
 */
export function codexAdapterCertification({id = DEFAULT_CERTIFICATION_ID} = {}) {
  if (id !== DEFAULT_CERTIFICATION_ID) throw new RangeError('unknown Codex adapter certification');
  return {
    certificationVersion: 'CodexAdapterCertificationV1',
    codexCertificationId: id,
    codexExecutableDigest: CODEX_BUILD_SHA256,
    providerBuildDigest: CODEX_BUILD_SHA256,
    methods: structuredClone(CERTIFICATION_METHODS),
    schema: structuredClone(CERTIFICATION_SCHEMA),
    probe: structuredClone(CERTIFICATION_PROBE),
    semantics: structuredClone(CERTIFICATION_SEMANTICS),
    status: structuredClone(CERTIFICATION_STATUS),
    certificationRevision: 1,
    codexCertificationDigest: DEFAULT_CERTIFICATION_DIGEST,
  };
}

export function codexAdapterCertificationPreimage() {
  return structuredClone(CERTIFICATION_PREIMAGE);
}

export function codexAdapterProbeFacts() {
  return structuredClone(CERTIFICATION_PROBE_FACTS);
}

export function epoch({
  connectionEpoch = 1,
  sourceEpoch = 1,
  providerInstanceEpoch = 1,
  runtimeAuthorityGeneration = 1,
  sourcePartition,
  source,
} = {}) {
  return {
    sourcePartition: sourcePartition ?? source ?? SOURCE,
    connectionEpoch,
    sourceEpoch,
    providerInstanceEpoch,
    runtimeAuthorityGeneration,
  };
}

/** A relational source-admission observation, not a self-certifying source flag. */
export function sourceAdmissionObservation({
  source = SOURCE,
  authenticatedConnectionEpoch = 2,
  authenticatedSourceEpoch = 3,
  currentConnectionEpoch = authenticatedConnectionEpoch + 1,
  currentSourceEpoch = authenticatedSourceEpoch + 1,
  providerInstanceEpoch = 4,
  runtimeAuthorityGeneration = 5,
  attemptedSourcePartition = source,
} = {}) {
  return {
    authenticated: epoch({
      source,
      connectionEpoch: authenticatedConnectionEpoch,
      sourceEpoch: authenticatedSourceEpoch,
      providerInstanceEpoch,
      runtimeAuthorityGeneration,
    }),
    current: epoch({
      source,
      connectionEpoch: currentConnectionEpoch,
      sourceEpoch: currentSourceEpoch,
      providerInstanceEpoch: providerInstanceEpoch + 1,
      runtimeAuthorityGeneration: runtimeAuthorityGeneration + 1,
    }),
    attemptedSourcePartition,
  };
}

export function threadRef(providerThreadId = 'thread-1', sourcePartition = SOURCE) {
  return {sourcePartition, providerThreadId};
}

export function turnRef(turnId = 'turn-1', thread = threadRef()) {
  return {threadRef: thread, turnId};
}

export function itemRef(itemId = 'item-1', turn = turnRef()) {
  return {turnRef: turn, itemId};
}

export function subject(thread = threadRef()) {
  return {domain: 'TIMELINE', threadRef: thread};
}

export function materializationSubject(timelineSubject = subject(), materializationId = 'mat-1') {
  return {...timelineSubject, materializationId};
}

export function readPlan({
  sourcePartition = SOURCE,
  subjectScope,
  thread = threadRef('thread-1', sourcePartition),
  providerMethod = 'thread/turns/list',
  sortDirection = 'asc',
  orderingContract = 'CODEX_THREAD_TURNS_PROVIDER_ORDER_V1',
} = {}) {
  const scope = subjectScope ?? subject(thread);
  const preimage = {
    digestDomain: READ_PLAN_DOMAIN,
    sourcePartition,
    subjectScope: scope,
    providerMethod,
    sortDirection,
    orderingContract,
  };
  return {...preimage, readPlanDigest: jcsDigest(preimage)};
}

export function readSpec({
  sourcePartition = SOURCE,
  subjectScope,
  thread = threadRef('thread-1', sourcePartition),
  providerMethod = 'thread/turns/list',
  sortDirection = 'asc',
  itemsView = 'full',
  limit = 1,
  cursor = null,
  plan,
  orderingContract = 'CODEX_THREAD_TURNS_PROVIDER_ORDER_V1',
  selector,
} = {}) {
  const scope = subjectScope ?? subject(thread);
  const resolvedItemsView = itemsView === 'FULL' ? 'full' : itemsView === 'NOT_LOADED' ? 'notLoaded' : itemsView;
  const resolvedSortDirection = selector === 'TAIL' ? 'desc' : sortDirection;
  const resolvedPlan = plan ?? readPlan({sourcePartition, subjectScope: scope, thread, providerMethod, sortDirection: resolvedSortDirection, orderingContract});
  const preimage = {
    digestDomain: READ_SPEC_DOMAIN,
    sourcePartition,
    subjectScope: scope,
    readPlanDigest: resolvedPlan.readPlanDigest,
    providerMethod,
    sortDirection: resolvedSortDirection,
    itemsView: resolvedItemsView,
    limit,
    cursor,
  };
  // The signed preimage carries the domain tag; the runtime/read-spec value
  // is the closed preimage plus its resulting digest. Keeping the literal
  // domain on the actual value makes the generated decoder and the oracle
  // reject cross-domain/specification substitution.
  return {
    digestDomain: READ_SPEC_DOMAIN,
    sourcePartition,
    subjectScope: scope,
    readPlanDigest: resolvedPlan.readPlanDigest,
    providerMethod,
    sortDirection: resolvedSortDirection,
    itemsView: resolvedItemsView,
    limit,
    cursor,
    readSpecDigest: jcsDigest(preimage),
  };
}

function resultPreimage({sourcePartition, subjectScope, readPlanDigest, readSpecDigest, returnedCursor, resultKind = 'FULL_TURNS', orderedTurns = [], orderedTurnIndexes = [], oversizedTurn, resultCount}) {
  return {
    digestDomain: READ_RESULT_DOMAIN,
    resultKind,
    sourcePartition,
    subjectScope,
    readPlanDigest,
    readSpecDigest,
    returnedCursor,
    resultCount: resultCount ?? (resultKind === 'OVERSIZED_TURN' ? 1 : resultKind === 'TURN_INDEX' ? orderedTurnIndexes.length : orderedTurns.length),
    ...(resultKind === 'TURN_INDEX' ? {orderedTurnIndexes} : resultKind === 'OVERSIZED_TURN' ? {oversizedTurn} : {orderedTurns}),
  };
}

export function readEvidence({
  sourceEpoch: sourceEpochValue = epoch(),
  readEvidenceId = 'read-evidence-1',
  providerMethod,
  sortDirection,
  itemsView,
  readGeneration = 1,
  spec = readSpec({sourcePartition: sourceOf(sourceEpochValue)}),
  orderedTurns = [],
  resultKind = 'FULL_TURNS',
  orderedTurnIndexes = [],
  oversizedTurn,
  returnedCursor = null,
  resultCount,
  resultDigest,
  certificationId = 'codex-cert-0.151.0',
  certificationDigest,
  codexExecutableDigest = CODEX_BUILD_SHA256,
} = {}) {
  const effectiveCount = resultCount ?? (resultKind === 'OVERSIZED_TURN' ? 1 : resultKind === 'TURN_INDEX' ? orderedTurnIndexes.length : orderedTurns.length);
  if (resultKind === 'FULL_TURNS' && effectiveCount !== orderedTurns.length || resultKind === 'TURN_INDEX' && effectiveCount !== orderedTurnIndexes.length || resultKind === 'OVERSIZED_TURN' && effectiveCount !== 1) {
    throw new RangeError('resultCount must equal orderedTurns.length');
  }
  const cert = {
    codexCertificationId: certificationId,
    codexCertificationDigest: certificationDigest ?? certification(certificationId).codexCertificationDigest,
  };
  const body = {
    providerMethod: providerMethod ?? spec.providerMethod,
    sortDirection: sortDirection ?? spec.sortDirection,
    readPlanDigest: spec.readPlanDigest,
    itemsView: itemsView ?? spec.itemsView,
    limit: spec.limit,
    cursor: spec.cursor,
    returnedCursor,
    resultCount: effectiveCount,
    resultKind,
    resultDigest: resultDigest ?? jcsDigest(resultPreimage({
      sourcePartition: spec.sourcePartition,
      subjectScope: spec.subjectScope,
      readPlanDigest: spec.readPlanDigest,
      readSpecDigest: spec.readSpecDigest,
      returnedCursor,
      resultKind,
      orderedTurns,
      orderedTurnIndexes,
      oversizedTurn,
      resultCount: effectiveCount,
    })),
    sourceEpoch: sourceEpochValue.sourceEpoch,
    providerInstanceEpoch: sourceEpochValue.providerInstanceEpoch,
    readGeneration,
    codexExecutableDigest,
  };
  const preimage = {
    digestDomain: READ_EVIDENCE_DOMAIN,
    readEvidenceId,
    sourcePartition: spec.sourcePartition,
    subjectScope: spec.subjectScope,
    readPlanDigest: spec.readPlanDigest,
    readSpecDigest: spec.readSpecDigest,
    ...cert,
    readBody: body,
  };
  return {
    digestDomain: READ_EVIDENCE_DOMAIN,
    readEvidenceId,
    sourcePartition: spec.sourcePartition,
    subjectScope: spec.subjectScope,
    readPlanDigest: spec.readPlanDigest,
    readSpecDigest: spec.readSpecDigest,
    ...cert,
    readBody: body,
    readEvidenceDigest: jcsDigest(preimage),
  };
}

export function certificationRef(id = 'codex-cert-0.151.0', digest) {
  return {
    codexCertificationId: id,
    codexCertificationDigest: digest ?? certification(id).codexCertificationDigest,
  };
}

export function boundary(turn = turnRef(), turnOrdinal = 0, itemId, timelineOrdinal = turnOrdinal, itemOrdinal = 0) {
  if (itemId === undefined) return {endpointKind: 'TURN', turnRef: turn, turnOrdinal};
  return {endpointKind: 'ITEM', itemRef: itemRef(itemId, turn), timelineOrdinal};
}

export function textItem({
  thread = threadRef(),
  turn = turnRef('turn-1', thread),
  id = 'item-1',
  turnOrdinal = 0,
  itemOrdinal = 0,
  timelineOrdinal = 0,
  predecessorItemRef,
  text = 'hello',
  itemKind = 'USER_MESSAGE',
  payloads,
} = {}) {
  return {
    itemRef: itemRef(id, turn),
    turnOrdinal,
    itemOrdinal,
    timelineOrdinal,
    predecessorItemRef: itemOrdinal > 0 ? (predecessorItemRef ?? itemRef(`${id}-previous`, turn)) : null,
    itemKind,
    payloads: payloads ?? [{kind: 'text', text}],
    providerTypeName: null,
  };
}

/**
 * The payload union carries resolved bytes directly and carries only a
 * commitment plus the one reachable missing marker for an unavailable value.
 * The index is part of the preimage so moving a payload cannot preserve its
 * digest accidentally.
 */
export function payloadCommitment(payload, payloadIndex) {
  if (!payload || payload.kind === 'unavailable') throw new TypeError('payload commitment requires a resolved payload');
  return jcsDigest({digestDomain: PAYLOAD_COMMITMENT_DOMAIN, payloadIndex, payload});
}

export function unavailablePayload(payloadDigest) {
  if (typeof payloadDigest !== 'string' || !/^[0-9a-f]{64}$/.test(payloadDigest)) throw new TypeError('unavailable payload requires a lowercase SHA-256 digest');
  return {kind: 'unavailable', payloadDigest, missingField: 'resolvedPayload'};
}

function normalizeInlinePayloads(payloads) {
  const capacityUnavailableIndexes = [];
  const normalized = payloads.map((payload, payloadIndex) => {
    if (payload && (payload.kind === 'text' || payload.kind === 'tool_summary')) {
      const serializedBytes = canonicalUtf8(payload).byteLength;
      if (serializedBytes > MAX_INLINE_TEXT_BYTES) {
        capacityUnavailableIndexes.push(payloadIndex);
        return unavailablePayload(payloadCommitment(payload, payloadIndex));
      }
    }
    return payload;
  });
  return {payloads: normalized, capacityUnavailableIndexes};
}

function turnSpine(turn, turnOrdinal, items, predecessorTurnRef = null) {
  const ordered = items ?? [];
  return {
    turnRef: turn,
    turnOrdinal,
    predecessorTurnRef,
    firstTimelineOrdinal: ordered.length === 0 ? null : ordered[0].timelineOrdinal,
    lastTimelineOrdinal: ordered.length === 0 ? null : ordered.at(-1).timelineOrdinal,
    itemCount: ordered.length,
  };
}

function strongBoundaryForTurn(turn, spine) {
  return boundary(turn, spine.turnOrdinal);
}

function strongBoundaryForItem(item) {
  return boundary(item.itemRef.turnRef, item.turnOrdinal, item.itemRef.itemId, item.timelineOrdinal, item.itemOrdinal);
}

function coverageIsland(islandOrdinal, turnEntries) {
  const items = turnEntries.flatMap((entry) => entry.items);
  const first = turnEntries[0];
  const last = turnEntries.at(-1);
  const firstItem = items[0];
  const lastItem = items.at(-1);
  const firstBoundary = strongBoundaryForTurn(first.turn, first.spine);
  const lastBoundary = strongBoundaryForTurn(last.turn, last.spine);
  return {
    islandOrdinal,
    startBoundary: firstBoundary,
    endBoundary: lastBoundary,
    minTurnOrdinal: first.spine.turnOrdinal,
    maxTurnOrdinal: last.spine.turnOrdinal,
    minTimelineOrdinal: firstItem ? firstItem.timelineOrdinal : null,
    maxTimelineOrdinal: lastItem ? lastItem.timelineOrdinal : null,
    turnCount: turnEntries.length,
    indexTurnCount: 0,
    fullTurnCount: turnEntries.length,
    itemCount: items.length,
  };
}

function repairTargetFromBoundaries(targetKind, leftBoundary, rightBoundary, thread, item) {
  switch (targetKind) {
    case 'BEFORE': return {targetKind, rightBoundary};
    case 'AFTER': return {targetKind, leftBoundary};
    case 'BETWEEN': return {targetKind, leftBoundary, rightBoundary};
    case 'PAYLOAD': return {targetKind, itemRef: item?.itemRef ?? itemRef('item-1', turnRef('turn-1', thread)), missingPayloadFields: [{payloadIndex: 0, payloadKind: 'unavailable', fieldName: 'resolvedPayload'}]};
    case 'COVERAGE_UNKNOWN': return {targetKind, subjectScope: subject(thread)};
    case 'TURN_PAYLOAD_NOT_LOADED': {
      const targetTurn = item?.itemRef?.turnRef ?? turnRef('turn-1', thread);
      return {targetKind, turnRef: targetTurn, turnOrdinal: item?.turnOrdinal ?? 0};
    }
    default: throw new RangeError(`unknown gap target ${targetKind}`);
  }
}

export function repairIntent({
  thread = threadRef(),
  spec = readSpec({thread}),
  targetKind = 'BEFORE',
  boundaryKind,
  target,
  reason,
  repairKind,
  codexCertificationId = 'codex-cert-0.151.0',
  codexCertificationDigest,
} = {}) {
  const resolvedTargetKind = targetKind === 'SCOPE' ? 'COVERAGE_UNKNOWN' : targetKind === 'BOUNDARY' ? (boundaryKind ?? 'BEFORE') : targetKind;
  const leftBoundary = boundary(turnRef('turn-1', thread), 0, 'item-1', 0, 0);
  const rightBoundary = boundary(turnRef('turn-2', thread), 1, 'item-2', 1, 0);
  const resolvedTarget = target ?? repairTargetFromBoundaries(resolvedTargetKind, leftBoundary, rightBoundary, thread);
  const structuralTarget = ['BEFORE', 'AFTER', 'BETWEEN', 'COVERAGE_UNKNOWN'].includes(resolvedTargetKind);
  const resolvedReason = reason ?? (resolvedTargetKind === 'PAYLOAD' ? 'PAYLOAD_UNAVAILABLE' : resolvedTargetKind === 'TURN_PAYLOAD_NOT_LOADED' ? 'NOT_LOADED' : structuralTarget ? 'ORDER_UNPROVEN' : 'TURN_PAYLOAD_OVERSIZED');
  const resolvedRepairKind = repairKind ?? (resolvedTargetKind === 'PAYLOAD' ? 'LOAD_PAYLOAD' : resolvedTargetKind === 'TURN_PAYLOAD_NOT_LOADED' ? 'FULL_BOUNDED_REREAD' : resolvedTargetKind === 'TURN_PAYLOAD_OVERSIZED' ? 'NONE' : 'FULL_BOUNDED_REREAD');
  const cert = certificationRef(codexCertificationId, codexCertificationDigest);
  const preimage = {
    digestDomain: REPAIR_DOMAIN,
    sourcePartition: thread.sourcePartition,
    subjectScope: subject(thread),
    readPlanDigest: spec.readPlanDigest,
    readSpecDigest: spec.readSpecDigest,
    ...cert,
    target: resolvedTarget,
    reason: resolvedReason,
    repairKind: resolvedRepairKind,
    repairDisposition: resolvedRepairKind === 'NONE' ? 'UNREPAIRABLE_WITH_CURRENT_PROVIDER_API' : 'REPAIRABLE_WITH_CURRENT_PROVIDER_API',
  };
  return {
    digestDomain: REPAIR_DOMAIN,
    sourcePartition: preimage.sourcePartition,
    subjectScope: preimage.subjectScope,
    readPlanDigest: preimage.readPlanDigest,
    readSpecDigest: preimage.readSpecDigest,
    codexCertificationId: preimage.codexCertificationId,
    codexCertificationDigest: preimage.codexCertificationDigest,
    target: preimage.target,
    reason: preimage.reason,
    repairKind: preimage.repairKind,
    repairDisposition: preimage.repairDisposition,
    repairIntentDigest: jcsDigest(preimage),
  };
}

export function gapBetween({left, right, gapOrdinal = 0, thread = threadRef(), spec} = {}) {
  const leftBoundary = left ?? boundary(turnRef('turn-1', thread), 0, 'item-1', 0, 0);
  const rightBoundary = right ?? boundary(turnRef('turn-2', thread), 1, 'item-2', 1, 0);
  const effectiveSpec = spec ?? readSpec({thread, cursor: 'cursor-1'});
  const target = {targetKind: 'BETWEEN', leftBoundary, rightBoundary};
  return {gapOrdinal, target, reason: 'ORDER_UNPROVEN', repairIntent: repairIntent({thread, spec: effectiveSpec, targetKind: 'BETWEEN', target, reason: 'ORDER_UNPROVEN', repairKind: 'FULL_BOUNDED_REREAD'})};
}

export function pageBody({items = [], gaps = []} = {}) {
  return {items, gaps};
}

export function derivePageDigest({source, sourcePartition, timelineSubject, materializationId, subject: materializedSubject, pageIndex, pageCount, body, pageBody: bodyOverride} = {}) {
  return jcsDigest({
    digestDomain: PAGE_DOMAIN,
    sourcePartition: sourcePartition ?? source ?? SOURCE,
    subject: materializedSubject ?? materializationSubject(timelineSubject ?? subject(threadRef()), materializationId),
    pageIndex,
    pageCount,
    pageBody: bodyOverride ?? body,
  });
}

function proofWitness({fromPosition, toPosition, baseSubject, baseHeadVersion, baseManifestDigest} = {}) {
  if (baseSubject) {
    return {proofKind: 'CANONICAL_PREDECESSOR', baseSubject, baseHeadVersion, baseManifestDigest};
  }
  return {proofKind: 'PROVIDER_PAGE_ORDER', fromPosition, toPosition};
}

export function orderProof({materializationId = 'mat-1', thread = threadRef(), pageIndex = 0, fromBoundary, toBoundary, readEvidence: evidence = readEvidence({spec: readSpec({thread})}), sealedProof, fromPosition = {positionKind: 'TURN', turnIndex: 0}, toPosition = {positionKind: 'TURN', turnIndex: 1}} = {}) {
  const scope = subject(thread);
  const materialized = materializationSubject(scope, materializationId);
  const from = fromBoundary ?? boundary(turnRef('turn-1', thread), -1);
  const to = toBoundary ?? boundary(turnRef('turn-1', thread), 0, 'item-1', 0, 0);
  const preimage = {
    digestDomain: ORDER_PROOF_DOMAIN,
    sourcePartition: thread.sourcePartition,
    subject: materialized,
    from,
    to,
    readEvidenceId: evidence.readEvidenceId,
    readEvidenceDigest: evidence.readEvidenceDigest,
    codexCertificationId: evidence.codexCertificationId,
    codexCertificationDigest: evidence.codexCertificationDigest,
    pageIndex,
    sealedProof: sealedProof ?? proofWitness({fromPosition, toPosition}),
  };
  return {...preimage, proofDigest: jcsDigest(preimage)};
}

function deriveOrderIslands({items, islands}) {
  return islands.map((island, islandIndex) => {
    const lower = island.minTimelineOrdinal ?? Number.MIN_SAFE_INTEGER;
    const upper = island.maxTimelineOrdinal ?? Number.MAX_SAFE_INTEGER;
    const islandItems = items.filter((item) => item.timelineOrdinal >= lower && item.timelineOrdinal <= upper);
    const turns = [];
    for (const item of islandItems) {
      let turn = turns.find((candidate) => candidate.turnRef.turnId === item.itemRef.turnRef.turnId);
      if (!turn) {
        turn = {turnRef: item.itemRef.turnRef, turnOrdinal: item.turnOrdinal, items: []};
        turns.push(turn);
      }
      turn.items.push(item);
    }
    return {islandOrdinal: island.islandOrdinal ?? islandIndex, island, orderedTurns: turns.map((turn, turnIndex) => ({turnSpine: turnSpine(turn.turnRef, turn.turnOrdinal, turn.items, turnIndex === 0 ? null : turns[turnIndex - 1].turnRef), incomingProofDigest: null, orderedItems: turn.items.map((item) => ({item, incomingProofDigest: null}))}))};
  });
}

export function deriveOrderDigest({source, sourcePartition, timelineSubject, materializationId, subject: materializedSubject, orderedIslands, items = [], islands = []} = {}) {
  return jcsDigest({digestDomain: ORDER_DOMAIN, sourcePartition: sourcePartition ?? source ?? SOURCE, subject: materializedSubject ?? materializationSubject(timelineSubject ?? subject(threadRef()), materializationId), domain: 'TIMELINE', orderedIslands: orderedIslands ?? deriveOrderIslands({items, islands})});
}

/**
 * The coverage preimage has one and only one representation for a staged
 * island.  In particular, the ordinal is not inferred from a nested island
 * and an island cannot be supplied without its checked outer ordinal.
 */
export function coverageOrderedIsland(islandOrdinal, island) {
  if (!Number.isSafeInteger(islandOrdinal) || islandOrdinal < 0 ||
      !island || typeof island !== 'object' || Array.isArray(island) ||
      !Object.hasOwn(island, 'islandOrdinal') ||
      !Number.isSafeInteger(island.islandOrdinal) || island.islandOrdinal !== islandOrdinal) {
    throw new TypeError('coverage island ordinal must exactly match the nested island');
  }
  return {islandOrdinal, island};
}

// Descriptive alias used by isolated semantic fixtures.
export const coveragePreimageIsland = coverageOrderedIsland;
export const coverageIslandPreimage = coverageOrderedIsland;
export function coveragePreimage(value = {}) {
  const ownKeys = value && typeof value === 'object' && !Array.isArray(value) ? Reflect.ownKeys(value) : [];
  if (!value || typeof value !== 'object' || Array.isArray(value) ||
      ownKeys.length !== 2 || !ownKeys.every((key) => key === 'islandOrdinal' || key === 'island') || !Object.hasOwn(value, 'islandOrdinal') || !Object.hasOwn(value, 'island')) {
    throw new TypeError('coverage preimage requires exactly {islandOrdinal,island}');
  }
  return coverageOrderedIsland(value.islandOrdinal, value.island);
}

export function deriveCoverageDigest({source, sourcePartition, timelineSubject, materializationId, subject: materializedSubject, structuralCoverage, payloadCoverage, islands = [], gaps = [], orderedIslands, orderedGaps, coverageKind = islands.length === 0 ? 'EMPTY' : 'NON_EMPTY', emptyProof: typedEmptyProof} = {}) {
  const base = {digestDomain: COVERAGE_DOMAIN, sourcePartition: sourcePartition ?? source ?? SOURCE, subject: materializedSubject ?? materializationSubject(timelineSubject ?? subject(threadRef()), materializationId), domain: 'TIMELINE'};
  if (coverageKind === 'EMPTY' || structuralCoverage === 'EMPTY_PROVEN') return jcsDigest({...base, structuralCoverage: 'EMPTY_PROVEN', payloadCoverage: 'COMPLETE', orderedIslands: [], orderedGaps: [], emptyProof: typedEmptyProof});
  const derived = orderedIslands ?? islands.map((island) => coverageOrderedIsland(island.islandOrdinal, island));
  if (orderedIslands !== undefined && islands.length > 0) {
    const expected = islands.map((island) => coverageOrderedIsland(island.islandOrdinal, island));
    const expectedBytes = canonicalUtf8(expected);
    const derivedBytes = Array.isArray(derived) ? canonicalUtf8(derived) : null;
    if (!derivedBytes || expectedBytes.byteLength !== derivedBytes.byteLength ||
        !expectedBytes.every((byte, index) => byte === derivedBytes[index])) {
      throw new TypeError('coverage preimage island pair must be byte-equal to staged islands');
    }
  }
  if (!Array.isArray(derived) || derived.some((entry, index) => !entry || entry.islandOrdinal !== index || !entry.island || entry.island.islandOrdinal !== entry.islandOrdinal)) {
    throw new TypeError('coverage ordered islands must be contiguous exact {islandOrdinal,island} pairs');
  }
  return jcsDigest({...base, structuralCoverage, payloadCoverage, orderedIslands: derived, orderedGaps: orderedGaps ?? gaps});
}

export function deriveManifestDigest({source, sourcePartition, timelineSubject, materializationId, subject: materializedSubject, algorithmVersion = 1, baseHeadVersion, candidateHeadVersion, pageCount, orderedPageDigests = [], totalItemCount, totalTurnCount, totalGapCount, islandCount, turnCount, itemCount, gapCount, orderDigest, coverageDigest} = {}) {
  return jcsDigest({digestDomain: MANIFEST_DOMAIN, algorithmVersion: Number.isInteger(algorithmVersion) ? algorithmVersion : 1, sourcePartition: sourcePartition ?? source ?? SOURCE, subject: materializedSubject ?? materializationSubject(timelineSubject ?? subject(threadRef()), materializationId), baseHeadVersion, candidateHeadVersion, pageCount, orderedPageDigests: orderedPageDigests.map((value, pageIndex) => typeof value === 'string' ? {pageIndex, pageDigest: value} : value), domain: 'TIMELINE', turnCount: turnCount ?? totalTurnCount, itemCount: itemCount ?? totalItemCount, islandCount, gapCount: gapCount ?? totalGapCount, orderDigest, coverageDigest});
}

export function deriveBeginHeaderDigest(preimage) {
  const value = structuredClone(preimage);
  if (value?.block) delete value.block.beginHeaderDigest;
  return jcsDigest(value);
}

export function deriveReceiptDigest({algorithmVersion = 1, receiptId, source, sourcePartition, timelineSubject, materializationId, subject: materializedSubject, beginHeaderDigest, manifestDigest, orderDigest, coverageDigest, baseHeadVersion, candidateHeadVersion, readPlanDigest, readSpec, readEvidence, readSpecDigest, readEvidenceId, readEvidenceDigest, certificationId, certificationDigest, pageCount, totalItemCount, totalTurnCount, totalGapCount, islandCount, turnCount, itemCount, gapCount, stagedRowCount = 0, stagedByteCount = '0'} = {}) {
  return jcsDigest({algorithmVersion: Number.isInteger(algorithmVersion) ? algorithmVersion : 1, receiptId, sourcePartition: sourcePartition ?? source ?? SOURCE, subject: materializedSubject ?? materializationSubject(timelineSubject ?? subject(threadRef()), materializationId), beginHeaderDigest, baseHeadVersion, candidateHeadVersion, readPlanDigest: readPlanDigest ?? readSpec?.readPlanDigest ?? readEvidence?.readPlanDigest, readSpecDigest: readSpecDigest ?? readSpec?.readSpecDigest ?? readSpec, readEvidenceId: readEvidenceId ?? readEvidence?.readEvidenceId, readEvidenceDigest: readEvidenceDigest ?? readEvidence?.readEvidenceDigest, codexCertificationId: certificationId ?? readEvidence?.codexCertificationId, codexCertificationDigest: certificationDigest ?? readEvidence?.codexCertificationDigest, result: 'VERIFIED', pageCount, domain: 'TIMELINE', turnCount: turnCount ?? totalTurnCount, itemCount: itemCount ?? totalItemCount, islandCount, gapCount: gapCount ?? totalGapCount, stagedRowCount, stagedByteCount: String(stagedByteCount), orderDigest, coverageDigest, manifestDigest});
}

export function emptyProof({source = SOURCE, sourcePartition, timelineSubject = subject(), readEvidence: evidence} = {}) {
  return {proofKind: 'FULL_SCOPE_PROVIDER_EMPTY', sourcePartition: sourcePartition ?? source, subjectScope: timelineSubject, readPlanDigest: evidence.readPlanDigest, readSpecDigest: evidence.readSpecDigest, readEvidenceId: evidence.readEvidenceId, readEvidenceDigest: evidence.readEvidenceDigest, codexCertificationId: evidence.codexCertificationId, codexCertificationDigest: evidence.codexCertificationDigest};
}

export function messageIdentity({source = SOURCE, sourcePartition, subscriptionId = 'sub-1', streamId = 'timeline-1', messageId, streamSeq, commitSeq, blockRole} = {}) {
  return {sourcePartition: sourcePartition ?? source, subscriptionId, streamId, messageId, baseSeq: streamSeq - 1, streamSeq, commitSeq, checkpointSequence: blockRole === 'COMMIT' ? commitSeq : 0, blockRole};
}

function stagedCapacity(pages, gaps) {
  // Capacity is the durable logical-row projection.  It deliberately does
  // not serialize the page body as a second row: each publication page is a
  // page row, followed by its staged item/proof rows and gap anchors.
  const pageRows = pages.map((page) => ({
    capacityRowKind: 'PAGE',
    sourcePartition: page.sourcePartition,
    subject: page.block.subject,
    pageIndex: page.pageIndex,
    pageCount: page.pageCount,
    previousPageDigest: page.previousPageDigest ?? null,
    pageDigest: page.pageDigest,
  }));
  const rows = [
    ...pageRows,
    ...pages.flatMap((page) => page.body.items.map((item) => ({capacityRowKind: 'LOGICAL_ROW', pageIndex: page.pageIndex, item}))),
    ...pages.flatMap((page) => page.body.gaps.map((gap) => ({capacityRowKind: 'GAP', pageIndex: page.pageIndex, gap}))),
  ];
  return {stagedRowCount: rows.length, stagedByteCount: rows.reduce((sum, row) => sum + BigInt(canonicalUtf8(row).byteLength), 0n).toString()};
}

function buildTurnEntries({thread, materializationId, itemCount, itemsPerTurn = 1, itemText, timelineOrdinalOverride, turnOrdinalOverride, itemOrdinalOverride, payloadsOverride}) {
  const entries = [];
  for (let index = 0; index < itemCount; index += 1) {
    // Materialization/container identity is intentionally absent from stable
    // timeline facts so last-good dominance can compare two containers for
    // the same scope without mistaking a new container id for new content.
    const turn = turnRef(`turn-${index + 1}`, thread);
    const turnOrdinal = turnOrdinalOverride === undefined ? index : turnOrdinalOverride + index;
    const items = [];
    const capacityUnavailableIndexes = new Set();
    for (let itemIndex = 0; itemIndex < itemsPerTurn; itemIndex += 1) {
      const defaultText = index === 0 && itemIndex === 0 ? itemText : `${itemText}-${index}-${itemIndex}`;
      const requestedPayloads = typeof payloadsOverride === 'function' ? payloadsOverride(index, turn, itemIndex) : payloadsOverride;
      const payloads = requestedPayloads === undefined ? [{kind: 'text', text: defaultText}] : structuredClone(requestedPayloads);
      const normalized = normalizeInlinePayloads(payloads);
      for (const payloadIndex of normalized.capacityUnavailableIndexes) capacityUnavailableIndexes.add(payloadIndex);
      const itemId = itemsPerTurn === 1 ? `item-${index + 1}` : `item-${index + 1}-${itemIndex + 1}`;
      const item = textItem({thread, turn, id: itemId, text: defaultText, turnOrdinal, itemOrdinal: itemOrdinalOverride === undefined ? itemIndex : itemOrdinalOverride + itemIndex, timelineOrdinal: timelineOrdinalOverride === undefined ? index * itemsPerTurn + itemIndex : timelineOrdinalOverride + index * itemsPerTurn + itemIndex, predecessorItemRef: items.at(-1)?.itemRef, payloads: normalized.payloads});
      items.push(item);
    }
    // Each fixture entry is its own coverage island. The first Turn in an
    // island has no predecessor; cross-island relationships are represented
    // by structural gaps/order proofs, never by a hidden Turn edge.
    const spine = turnSpine(turn, turnOrdinal, items, null);
    entries.push({turn, turnOrdinal, item: items[0], items, spine, capacityUnavailableIndexes: [...capacityUnavailableIndexes]});
  }
  return entries;
}

/** Build a complete fixture; evaluators must derive relations from its fields. */
export function materialization({materializationId = 'mat-1', thread = threadRef(), empty = false, withBetweenGap = false, payloadGap = false, indexOnly = false, oversized = false, groupTurns = false, itemsPerTurn = 1, itemText = 'hello', payloadsOverride, pageCountOverride, itemCountOverride, totalItemCountOverride, beginHeaderDigestOverride, manifestDigestOverride, previousPageDigestOverride, sourceEpoch: sourceEpochValue, subscriptionId = 'sub-1', streamId = 'timeline-1', baseHeadVersion = 0, timelineOrdinalOverride, turnOrdinalOverride, itemOrdinalOverride, proofKind = 'PROVIDER_PAGE_ORDER', baseSubject, baseManifestDigest} = {}) {
  const sourcePartition = thread.sourcePartition;
  const effectiveSourceEpoch = sourceEpochValue ?? epoch({sourcePartition});
  const timelineSubject = subject(thread);
  const matSubject = materializationSubject(timelineSubject, materializationId);
  const declaredPageCount = pageCountOverride ?? (empty ? 0 : 1);
  const requestedPageCount = pageCountOverride ?? (empty ? 0 : 1);
  const validRequestedPageCount = Number.isSafeInteger(requestedPageCount) && requestedPageCount >= 1 && requestedPageCount <= 128;
  const pageCount = empty ? 0 : validRequestedPageCount ? requestedPageCount : 1;
  const requestedItemCount = oversized ? 1 : itemCountOverride ?? (pageCount > 1 ? pageCount : withBetweenGap ? 2 : 1);
  const itemCount = empty ? 0 : Number.isSafeInteger(requestedItemCount) && requestedItemCount >= pageCount ? requestedItemCount : Math.max(pageCount, 1);
  const stagedIndexOnly = indexOnly || oversized;
  const entries = buildTurnEntries({thread, materializationId, itemCount, itemsPerTurn, itemText, timelineOrdinalOverride, turnOrdinalOverride, itemOrdinalOverride, payloadsOverride});
  if (groupTurns) {
    entries.forEach((entry, index) => {
      entry.spine.predecessorTurnRef = index === 0 ? null : entries[index - 1].turn;
    });
  }
  const islands = empty ? [] : entries.map((entry, islandOrdinal) => {
    const island = coverageIsland(islandOrdinal, [entry]);
    return stagedIndexOnly ? {...island, minTimelineOrdinal: null, maxTimelineOrdinal: null, indexTurnCount: 1, fullTurnCount: 0, itemCount: 0} : island;
  });
  const effectiveIslands = empty ? [] : groupTurns ? [coverageIsland(0, entries)] : islands;
  const stagedIslands = stagedIndexOnly
    ? effectiveIslands.map((island) => ({...island, minTimelineOrdinal: null, maxTimelineOrdinal: null, indexTurnCount: island.turnCount, fullTurnCount: 0, itemCount: 0}))
    : effectiveIslands;
  const orderedTurns = entries.map((entry) => ({
    turnSpine: entry.spine,
    providerReportedItemCount: entry.items.length,
    observedTurnByteCount: String(canonicalUtf8({turnRef: entry.turn, orderedItems: entry.items}).byteLength),
    maximumTurnByteCount: MAX_PROVIDER_TURN_BYTES,
    orderedItems: entry.items,
  }));
  const indexSpec = readSpec({sourcePartition, subjectScope: timelineSubject, thread, providerMethod: 'thread/turns/list', sortDirection: 'asc', itemsView: 'notLoaded', limit: Math.max(1, entries.length), cursor: 'index-cursor'});
  const spec = readSpec({sourcePartition, subjectScope: timelineSubject, thread, providerMethod: 'thread/turns/list', sortDirection: 'asc', itemsView: stagedIndexOnly && !oversized ? 'notLoaded' : 'full', limit: stagedIndexOnly && !oversized ? Math.max(1, entries.length) : 1, cursor: oversized ? 'full-cursor' : null});
  const orderedTurnIndexes = entries.map((entry, index) => ({turnRef: entry.turn, turnOrdinal: entry.turnOrdinal, predecessorTurnRef: groupTurns && index > 0 ? entries[index - 1].turn : null}));
  const oversizedTurn = oversized ? {
    turnIndex: orderedTurnIndexes[0],
    providerReportedItemCount: 1,
    observedTurnByteCount: String(MAX_PROVIDER_TURN_BYTES + 1),
    maximumTurnByteCount: MAX_PROVIDER_TURN_BYTES,
    indexReadEvidenceId: `read-evidence-${materializationId}-index`,
    indexReadEvidenceDigest: null,
  } : undefined;
  const indexEvidence = oversized ? readEvidence({readEvidenceId: oversizedTurn.indexReadEvidenceId, sourceEpoch: effectiveSourceEpoch, spec: indexSpec, resultKind: 'TURN_INDEX', resultCount: orderedTurnIndexes.length, orderedTurnIndexes}) : null;
  if (oversized) oversizedTurn.indexReadEvidenceDigest = indexEvidence.readEvidenceDigest;
  const evidence = oversized
    ? readEvidence({readEvidenceId: `read-evidence-${materializationId}-oversized`, sourceEpoch: effectiveSourceEpoch, spec, resultKind: 'OVERSIZED_TURN', oversizedTurn, readGeneration: 2, resultCount: 1})
    : readEvidence({sourceEpoch: effectiveSourceEpoch, spec, resultKind: indexOnly ? 'TURN_INDEX' : 'FULL_TURNS', resultCount: indexOnly ? orderedTurnIndexes.length : orderedTurns.length, orderedTurns: indexOnly ? [] : orderedTurns, orderedTurnIndexes: indexOnly ? orderedTurnIndexes : []});
  const gaps = [];
  if (indexOnly) {
    for (const entry of entries) {
      const target = {targetKind: 'TURN_PAYLOAD_NOT_LOADED', turnRef: entry.turn, turnOrdinal: entry.turnOrdinal};
      gaps.push({gapOrdinal: gaps.length, target, reason: 'NOT_LOADED', repairIntent: repairIntent({thread, spec, targetKind: target.targetKind, target, reason: 'NOT_LOADED', repairKind: 'FULL_BOUNDED_REREAD'})});
    }
  }
  if (oversized) {
    const target = {targetKind: 'TURN_PAYLOAD_OVERSIZED', turnRef: oversizedTurn.turnIndex.turnRef, turnOrdinal: oversizedTurn.turnIndex.turnOrdinal, leftTurnBoundary: null, rightTurnBoundary: null, providerReportedItemCount: oversizedTurn.providerReportedItemCount, observedTurnByteCount: oversizedTurn.observedTurnByteCount, maximumTurnByteCount: oversizedTurn.maximumTurnByteCount, problemCode: 'TURN_PAYLOAD_OVERSIZED', repairDisposition: 'UNREPAIRABLE_WITH_CURRENT_PROVIDER_API', oversizedReadEvidenceId: evidence.readEvidenceId, oversizedReadEvidenceDigest: evidence.readEvidenceDigest};
    gaps.push({gapOrdinal: gaps.length, target, reason: 'TURN_PAYLOAD_OVERSIZED', repairIntent: repairIntent({thread, spec, targetKind: target.targetKind, target, reason: 'TURN_PAYLOAD_OVERSIZED', repairKind: 'NONE'})});
  }
  for (const entry of entries) {
    for (const item of entry.items) {
      const missingPayloadFields = item.payloads.flatMap((payload, payloadIndex) => payload.kind === 'unavailable'
        ? [{payloadIndex, payloadKind: 'unavailable', fieldName: 'resolvedPayload'}]
        : []);
      if (missingPayloadFields.length === 0) continue;
      const capacityBoundary = [...missingPayloadFields].some(({payloadIndex}) => entry.capacityUnavailableIndexes.includes(payloadIndex));
      const target = {targetKind: 'PAYLOAD', itemRef: item.itemRef, missingPayloadFields};
      const reason = capacityBoundary ? 'CAPACITY_BOUNDARY' : 'PAYLOAD_UNAVAILABLE';
      const repairKind = capacityBoundary ? 'NONE' : 'LOAD_PAYLOAD';
      gaps.push({gapOrdinal: gaps.length, target, reason, repairIntent: repairIntent({thread, spec, targetKind: target.targetKind, target, reason, repairKind})});
    }
  }
  // Every island transition is an explicit BETWEEN relation.  The fixture
  // option can request a partial read, while multi-island/page fixtures must
  // never silently imply complete coverage without those anchors.
  if (stagedIslands.length > 1) {
    for (let islandIndex = 0; islandIndex + 1 < stagedIslands.length; islandIndex += 1) {
      gaps.push(gapBetween({thread, spec, gapOrdinal: gaps.length, left: stagedIslands[islandIndex].endBoundary, right: stagedIslands[islandIndex + 1].startBoundary}));
    }
  }
  const structuralGapCount = gaps.filter((gap) => ['BEFORE', 'AFTER', 'BETWEEN', 'COVERAGE_UNKNOWN'].includes(gap.target.targetKind)).length;
  const structuralCoverage = empty ? 'EMPTY_PROVEN' : structuralGapCount > 0 ? 'PARTIAL' : 'COMPLETE';
  const payloadCoverage = gaps.some((gap) => ['PAYLOAD', 'TURN_PAYLOAD_NOT_LOADED', 'TURN_PAYLOAD_OVERSIZED'].includes(gap.target.targetKind)) ? 'PARTIAL' : 'COMPLETE';
  const typedEmptyProof = empty ? emptyProof({sourcePartition, timelineSubject, readEvidence: evidence}) : undefined;
  const orderProofs = [];
  if (groupTurns) {
    for (let index = 1; index < entries.length; index += 1) {
      orderProofs.push(orderProof({
        materializationId,
        thread,
        pageIndex: 0,
        fromBoundary: strongBoundaryForTurn(entries[index - 1].turn, entries[index - 1].spine),
        toBoundary: strongBoundaryForTurn(entries[index].turn, entries[index].spine),
        readEvidence: evidence,
        sealedProof: proofKind === 'CANONICAL_PREDECESSOR'
          ? proofWitness({baseSubject, baseHeadVersion, baseManifestDigest})
          : proofWitness({fromPosition: {positionKind: 'TURN', turnIndex: index - 1}, toPosition: {positionKind: 'TURN', turnIndex: index}}),
      }));
    }
  }
  if (!stagedIndexOnly) {
    for (const entry of entries) {
      for (let itemIndex = 1; itemIndex < entry.items.length; itemIndex += 1) {
        const fromItem = entry.items[itemIndex - 1];
        const toItem = entry.items[itemIndex];
        orderProofs.push(orderProof({
          materializationId,
          thread,
          pageIndex: 0,
          fromBoundary: strongBoundaryForItem(fromItem),
          toBoundary: strongBoundaryForItem(toItem),
          readEvidence: evidence,
          sealedProof: proofWitness({
            fromPosition: {positionKind: 'ITEM', turnIndex: entries.indexOf(entry), itemIndex: itemIndex - 1},
            toPosition: {positionKind: 'ITEM', turnIndex: entries.indexOf(entry), itemIndex},
          }),
        }));
      }
    }
  }
  const proofsByTo = new Map(orderProofs.map((proof) => [jcsDigest(proof.to), proof]));
  const rowUnits = groupTurns ? [[
    {rowKind: 'COVERAGE_ISLAND', coverageIsland: stagedIslands[0]},
    ...entries.flatMap((entry, index) => {
      const proof = proofsByTo.get(jcsDigest(strongBoundaryForTurn(entry.turn, entry.spine)));
      const rows = [stagedIndexOnly
        ? {rowKind: 'TURN_INDEX', islandOrdinal: 0, turnIndex: orderedTurnIndexes[index]}
        : {rowKind: 'TURN_SPINE', islandOrdinal: 0, turnSpine: entry.spine}];
      if (proof) rows.push({rowKind: 'BOUND_ORDER_PROOF', islandOrdinal: 0, boundOrderProof: proof});
      if (!stagedIndexOnly) {
        for (const item of entry.items) {
          rows.push({rowKind: 'TIMELINE_ITEM', islandOrdinal: 0, timelineItem: item});
          const itemProof = proofsByTo.get(jcsDigest(strongBoundaryForItem(item)));
          if (itemProof) rows.push({rowKind: 'BOUND_ORDER_PROOF', islandOrdinal: 0, boundOrderProof: itemProof});
        }
      }
      return rows;
    }),
  ]] : entries.map((entry, islandOrdinal) => {
    const proof = proofsByTo.get(jcsDigest(strongBoundaryForTurn(entry.turn, entry.spine)));
    const rows = [{rowKind: 'COVERAGE_ISLAND', coverageIsland: stagedIslands[islandOrdinal]}, stagedIndexOnly
      ? {rowKind: 'TURN_INDEX', islandOrdinal, turnIndex: orderedTurnIndexes[islandOrdinal]}
      : {rowKind: 'TURN_SPINE', islandOrdinal, turnSpine: entry.spine}];
    if (proof) rows.push({rowKind: 'BOUND_ORDER_PROOF', islandOrdinal, boundOrderProof: proof});
    if (!stagedIndexOnly) {
      for (const item of entry.items) {
        rows.push({rowKind: 'TIMELINE_ITEM', islandOrdinal, timelineItem: item});
        const itemProof = proofsByTo.get(jcsDigest(strongBoundaryForItem(item)));
        if (itemProof) rows.push({rowKind: 'BOUND_ORDER_PROOF', islandOrdinal, boundOrderProof: itemProof});
      }
    }
      return rows;
  });
  const pages = [];
  const unitsPerPage = Math.ceil(rowUnits.length / pageCount);
  const key = (value) => jcsDigest(value);
  const pageForTurn = (turnRef) => {
    const unitIndex = rowUnits.findIndex((unit) => unit.some((row) =>
      ['TURN_INDEX', 'TURN_SPINE'].includes(row.rowKind) && key((row.turnIndex ?? row.turnSpine).turnRef) === key(turnRef)));
    return unitIndex < 0 ? 0 : Math.floor(unitIndex / unitsPerPage);
  };
  const pageForBoundary = (boundaryValue) => pageForTurn(boundaryValue?.turnRef ?? boundaryValue?.itemRef?.turnRef);
  const pageForGap = (gap) => {
    const target = gap.target;
    if (target.targetKind === 'COVERAGE_UNKNOWN') return 0;
    if (target.targetKind === 'PAYLOAD') {
      const unitIndex = rowUnits.findIndex((unit) => unit.some((row) => row.rowKind === 'TIMELINE_ITEM' && key(row.timelineItem.itemRef) === key(target.itemRef)));
      return unitIndex < 0 ? 0 : Math.floor(unitIndex / unitsPerPage);
    }
    if (target.targetKind === 'TURN_PAYLOAD_NOT_LOADED' || target.targetKind === 'TURN_PAYLOAD_OVERSIZED') return pageForTurn(target.turnRef);
    if (target.targetKind === 'BEFORE') return pageForBoundary(target.rightBoundary);
    if (target.targetKind === 'AFTER') return pageForBoundary(target.leftBoundary);
    if (target.targetKind === 'BETWEEN') return pageForBoundary(target.rightBoundary);
    return 0;
  };
  const gapsByPage = new Map(gaps.map((gap) => [gap.gapOrdinal, pageForGap(gap)]));
  for (let pageIndex = 0; pageIndex < pageCount; pageIndex += 1) {
    // Pack whole staged units.  A unit is an island + turn + its bound proof
    // (if any) + item; a page never bisects that reducer unit.
    const pageRows = rowUnits.slice(pageIndex * unitsPerPage, (pageIndex + 1) * unitsPerPage).flat();
    const body = pageBody({items: pageRows, gaps: gaps.filter((gap) => gapsByPage.get(gap.gapOrdinal) === pageIndex)});
    pages.push({pageIndex, pageCount, sourcePartition, subject: timelineSubject, body, pageDigest: derivePageDigest({sourcePartition, subject: matSubject, pageIndex, pageCount, pageBody: body})});
  }
  const orderedPageDigests = pages.map((page) => ({pageIndex: page.pageIndex, pageDigest: page.pageDigest}));
  const orderDigest = deriveOrderDigest({
    sourcePartition,
    subject: matSubject,
    orderedIslands: stagedIslands.map((island, islandOrdinal) => ({
      islandOrdinal,
      island,
      orderedTurns: (groupTurns ? entries : [entries[islandOrdinal]]).map((entry, turnIndex) => {
        const proof = proofsByTo.get(jcsDigest(strongBoundaryForTurn(entry.turn, entry.spine)));
        return {
          orderPosition: turnIndex === 0 ? 'FIRST' : 'SUCCESSOR',
          turnNode: stagedIndexOnly ? {turnNodeKind: 'INDEX', turnIndex: orderedTurnIndexes[groupTurns ? turnIndex : islandOrdinal]} : {turnNodeKind: 'FULL', turnSpine: entry.spine},
          ...(proof ? {incomingProofDigest: proof.proofDigest} : {}),
          orderedItems: stagedIndexOnly ? [] : entry.items.map((item, itemIndex) => {
            const itemProof = proofsByTo.get(jcsDigest(strongBoundaryForItem(item)));
            return {
              orderPosition: itemIndex === 0 ? 'FIRST' : 'SUCCESSOR',
              item,
              ...(itemIndex === 0 ? {} : {incomingProofDigest: itemProof?.proofDigest}),
            };
          }),
        };
      }),
    })),
  });
  const coverageDigest = deriveCoverageDigest({sourcePartition, subject: matSubject, structuralCoverage, payloadCoverage, islands: stagedIslands, gaps, coverageKind: empty ? 'EMPTY' : 'NON_EMPTY', emptyProof: typedEmptyProof});
  const turnCount = entries.length;
  const materializedItemCount = stagedIndexOnly ? 0 : entries.reduce((count, entry) => count + entry.items.length, 0);
  const manifestDigest = deriveManifestDigest({sourcePartition, subject: matSubject, algorithmVersion: 1, baseHeadVersion, candidateHeadVersion: baseHeadVersion + 1, pageCount, orderedPageDigests, totalItemCount: materializedItemCount, totalTurnCount: turnCount, totalGapCount: gaps.length, islandCount: stagedIslands.length, orderDigest, coverageDigest});
  const receiptId = `receipt-${materializationId}`;
  const block = {blockId: `block-${materializationId}`, subject: matSubject, receiptId, manifestDigest, beginHeaderDigest: beginHeaderDigestOverride ?? '0'.repeat(64)};
  const eventKey = {sourcePartition, ownerKind: 'CanonicalTimelineWriter', aggregateRef: {kind: 'MATERIALIZATION', subject: matSubject}, eventId: `${materializationId}-begin`};
  const beginPayload = {block, baseHeadVersion, candidateHeadVersion: baseHeadVersion + 1, expectedCoverageDigest: coverageDigest, readPlanDigest: spec.readPlanDigest, readSpecDigest: spec.readSpecDigest, readEvidenceId: evidence.readEvidenceId, readEvidenceDigest: evidence.readEvidenceDigest, codexCertificationId: evidence.codexCertificationId, codexCertificationDigest: evidence.codexCertificationDigest, readBody: evidence.readBody, pageCount, structuralCoverage, payloadCoverage, ...(empty ? {emptyProof: typedEmptyProof} : {})};
  const beginPreimage = {digestDomain: BEGIN_DOMAIN, eventKey, payload: {...beginPayload, block: {...block, beginHeaderDigest: undefined}}};
  delete beginPreimage.payload.block.beginHeaderDigest;
  const beginHeaderDigest = beginHeaderDigestOverride ?? deriveBeginHeaderDigest(beginPreimage);
  block.beginHeaderDigest = beginHeaderDigest;
  const begin = {preimage: beginPreimage, payload: beginPayload, beginHeaderDigest};
  const messageCount = pageCount + 2;
  const message = (role, sequence) => messageIdentity({sourcePartition, subscriptionId, streamId, messageId: role === 'PAGE' ? `${materializationId}-page-${sequence - 2}` : `${materializationId}-${role.toLowerCase()}`, streamSeq: sequence, commitSeq: messageCount, blockRole: role});
  const beginFrame = {message: message('BEGIN', 1), block, sourcePartition, subject: timelineSubject, begin, pageCount: declaredPageCount, totalItemCount: totalItemCountOverride ?? materializedItemCount};
  const materializedPages = pages.map((page, index) => ({message: message('PAGE', index + 2), block, sourcePartition, subject: timelineSubject, pageIndex: page.pageIndex, pageCount: page.pageCount, ...(index > 0 ? {previousPageDigest: previousPageDigestOverride ?? pages[index - 1].pageDigest} : {}), body: page.body, pageDigest: page.pageDigest}));
  const capacity = empty ? {stagedRowCount: 0, stagedByteCount: '0'} : stagedCapacity(materializedPages, gaps);
  const receiptDigest = deriveReceiptDigest({receiptId, sourcePartition, subject: matSubject, beginHeaderDigest, manifestDigest, orderDigest, coverageDigest, baseHeadVersion, candidateHeadVersion: baseHeadVersion + 1, readSpec: spec, readEvidence: evidence, readPlanDigest: spec.readPlanDigest, pageCount, totalItemCount: materializedItemCount, totalTurnCount: turnCount, totalGapCount: gaps.length, islandCount: stagedIslands.length, stagedRowCount: capacity.stagedRowCount, stagedByteCount: capacity.stagedByteCount});
  const commit = {message: message('COMMIT', messageCount), block, sourcePartition, subject: matSubject, baseHeadVersion, candidateHeadVersion: baseHeadVersion + 1, pageCount: declaredPageCount, ...(pageCount === 0 ? {} : {finalPageDigest: pages.at(-1)?.pageDigest}), domain: 'TIMELINE', turnCount, itemCount: totalItemCountOverride ?? materializedItemCount, islandCount: stagedIslands.length, gapCount: gaps.length, structuralCoverage, payloadCoverage, orderDigest, coverageDigest, receiptDigest, stagedRowCount: capacity.stagedRowCount, stagedByteCount: capacity.stagedByteCount, lastGoodDisposition: {disposition: baseHeadVersion === 0 ? 'NO_PREVIOUS_HEAD' : 'PREVIOUS_HEAD_RETAINED', ...(baseHeadVersion === 0 ? {} : {previousSubject: baseSubject ?? materializationSubject(timelineSubject, `${materializationId}-previous`), previousHeadVersion: baseHeadVersion})}};
  const plan = readPlan({sourcePartition, subjectScope: timelineSubject, thread, providerMethod: 'thread/turns/list', sortDirection: 'asc'});
  const normalizedResult = {
    digestDomain: READ_RESULT_DOMAIN,
    resultKind: oversized ? 'OVERSIZED_TURN' : indexOnly ? 'TURN_INDEX' : 'FULL_TURNS',
    sourcePartition,
    subjectScope: timelineSubject,
    readPlanDigest: spec.readPlanDigest,
    readSpecDigest: spec.readSpecDigest,
    returnedCursor: evidence.readBody.returnedCursor,
    resultCount: oversized ? 1 : indexOnly ? orderedTurnIndexes.length : orderedTurns.length,
    ...(oversized ? {oversizedTurn} : indexOnly ? {orderedTurnIndexes} : {orderedTurns}),
  };
  const certificationRecord = codexAdapterCertification({sourcePartition});
  const authority = {
    readPlan: plan,
    readSpec: spec,
    normalizedResult,
    evidence,
    certification: certificationRecord,
    probeEvidence: codexAdapterProbeFacts(),
    ...(oversized ? {priorIndexEvidence: {evidence: indexEvidence, normalizedResult: {digestDomain: READ_RESULT_DOMAIN, resultKind: 'TURN_INDEX', sourcePartition, subjectScope: timelineSubject, readPlanDigest: indexSpec.readPlanDigest, readSpecDigest: indexSpec.readSpecDigest, returnedCursor: null, resultCount: orderedTurnIndexes.length, orderedTurnIndexes}}} : {}),
  };
  return {beginFrame, pages: materializedPages, commit, authority};
}

export function cacheObservation({sameMaterialization = true, sourcePartition = SOURCE, materializationId = 'mat-cache'} = {}) {
  return {query: {readKind: 'CACHE_REUSE', threadRef: threadRef('thread-1', sourcePartition), knownMaterializationId: materializationId}, cacheEntryId: sameMaterialization ? materializationId : 'mat-other'};
}

export function livePromotion({sameIdentity = true} = {}) {
  const thread = threadRef();
  const turn = turnRef('turn-1', thread);
  const item = itemRef('item-1', turn);
  const live = {observationId: 'live-1', sourceEpoch: epoch(), itemRef: item, liveRevision: 1, provisionalItemOrdinal: 0, payloads: [{kind: 'text', text: 'hello'}]};
  const canonical = materialization({thread, itemText: 'hello'});
  if (!sameIdentity) canonical.pages[0].body.items.find((row) => row.rowKind === 'TIMELINE_ITEM').timelineItem.itemRef.itemId = 'item-other';
  return {live, canonical};
}

export function operationRequest({operationCode = 'OP-001', operationId = 'op-1', clientMessageId = 'client-message-1', source = SOURCE, sourcePartition, thread = threadRef(), input = {text: 'hello', imageRefs: [], structuredRefs: []}} = {}) {
  const effectiveSource = sourcePartition ?? source;
  const header = {operationId, sourcePartition: effectiveSource, admissionKey: {sourcePartition: effectiveSource, clientMessageId}, submittedAt: '2026-08-30T00:00:00Z'};
  const queueTarget = {threadRef: thread, queueEntryId: 'queue-1', rootOperationId: 'op-root'};
  const variants = {
    'OP-001': {kind: 'start_turn', operationCode, header, target: thread, input, expectedHeadVersion: 0, deliveryMode: 'START_IF_IDLE_ELSE_QUEUE'},
    'OP-002': {kind: 'edit_queued_input', operationCode, header, target: queueTarget, replacement: input, expectedLaneRevision: 1, expectedEntryRevision: 1},
    'OP-003': {kind: 'cancel_queued_input', operationCode, header, target: queueTarget, expectedLaneRevision: 1, expectedEntryRevision: 1, reason: 'USER_REQUESTED'},
    'OP-004': {kind: 'steer_active_turn', operationCode, header, target: turnRef('turn-1', thread), input},
    'OP-005': {kind: 'steer_queued_input', operationCode, header, target: queueTarget, activeTurn: turnRef('turn-active', thread), expectedLaneRevision: 1, expectedEntryRevision: 1},
    'OP-006': {kind: 'interrupt_turn', operationCode, header, target: turnRef('turn-1', thread), reason: 'USER_REQUESTED'},
  };
  return variants[operationCode];
}

export function operationFingerprint(request) {
  const target = request.target;
  const targetId = target.providerThreadId ?? target.turnId ?? target.queueEntryId;
  const {header: _header, ...serverPayload} = request;
  const payloadDigest = jcsDigest(serverPayload);
  const preconditionDigest = jcsDigest(withoutUndefined({digestDomain: PRECONDITION_DOMAIN, expectedHeadVersion: request.expectedHeadVersion, expectedLaneRevision: request.expectedLaneRevision, expectedEntryRevision: request.expectedEntryRevision}));
  const preimage = {digestDomain: OPERATION_DOMAIN, schemaRevision: 1, operationCode: request.operationCode, sourcePartition: request.header.sourcePartition, targetId, payloadDigest, preconditionDigest};
  return {algorithm: 'SHA256_RFC8785', preimage, value: jcsDigest(preimage)};
}

export function operationRef(request) {
  return {sourcePartition: request.header.sourcePartition, operationId: request.header.operationId, operationCode: request.operationCode, targetId: request.target.providerThreadId ?? request.target.turnId ?? request.target.queueEntryId};
}

export function operationDispatchObservation({reference = operationRef(operationRequest()), operationState = 'ADMITTED', dispatchState = 'PREPARED', attemptId = 'attempt-1', attemptRevision = 1, admissionFactId = 'admission-fact-1'} = {}) {
  return {operationRef: reference, operationState, dispatchState, attemptId, attemptRevision, admissionFactId};
}

export function operationRecoveryObservation({reference = operationRef(operationRequest()), afterRecovery = 'OUTCOME_UNKNOWN', reconcileMode = 'READ_ONLY_RECONCILE', resolutionOutcome = 'STILL_UNKNOWN', reconcileRevision = 1, attemptFactId = 'reconcile-attempt-1', resolutionFactId = 'reconcile-resolution-1', postCommitFactIds = [attemptFactId, resolutionFactId], deliveryEnvelopeIds = []} = {}) {
  return {operationRef: reference, beforeCrash: 'CALL_STARTED', afterRecovery, reconcileMode, operationState: 'OUTCOME_UNKNOWN', reconcileRevision, attemptFactId, resolutionFactId, resolutionOutcome, postCommitFactIds, deliveryEnvelopeIds};
}

export function interactionFixture({kind = 'APPROVAL', source = SOURCE, sourcePartition, actorId = 'actor-1', expired = false} = {}) {
  const effectiveSource = sourcePartition ?? source;
  const thread = threadRef('thread-1', effectiveSource);
  const turn = turnRef('turn-1', thread);
  const interactionRef = {sourcePartition: effectiveSource, threadRef: thread, turnRef: turn, interactionId: 'interaction-1', interactionKind: kind};
  const expiresAt = expired ? '2020-01-01T00:00:00Z' : '2999-01-01T00:00:00Z';
  const descriptorByKind = {
    APPROVAL: {kind: 'approval', interactionRef, revision: 1, prompt: 'Approve?', allowReject: true, expiresAt},
    QUESTION: {kind: 'question', interactionRef, revision: 1, prompt: 'Choose', questions: [{questionId: 'q1', prompt: 'Which?', responseKind: 'SINGLE_CHOICE', options: ['yes', 'no'], required: true}], expiresAt},
    MCP_ELICITATION: {kind: 'mcp_elicitation', interactionRef, revision: 1, prompt: 'Provide text', responseShape: 'TEXT', schemaDigest: 'a'.repeat(64), expiresAt},
    EXIT_PLAN: {kind: 'exit_plan', interactionRef, revision: 1, summary: 'Plan', planDigest: 'b'.repeat(64), expiresAt},
  };
  const descriptor = descriptorByKind[kind];
  const sourceEpoch = epoch({sourcePartition: effectiveSource});
  const snapshot = {sourceEpoch, descriptor, state: expired ? 'EXPIRED' : 'OPEN_CLAIMED', revision: 1, claim: {claimId: 'claim-1', actorRef: {actorId, displayName: 'Actor'}, leaseRevision: 1, expiresAt}};
  const header = {operationId: 'op-interaction-1', sourcePartition: effectiveSource, admissionKey: {sourcePartition: effectiveSource, clientMessageId: 'interaction-client-1'}, submittedAt: '2026-08-30T00:00:00Z'};
  const responseByKind = {
    APPROVAL: {responseKind: 'approval', operationCode: 'OP-019', header, interactionRef, claimProof: {claimId: 'claim-1', claimToken: 'opaque', leaseRevision: 1}, expectedInteractionRevision: 1, response: {disposition: 'approve'}},
    QUESTION: {responseKind: 'question', operationCode: 'OP-020', header, interactionRef, claimProof: {claimId: 'claim-1', claimToken: 'opaque', leaseRevision: 1}, expectedInteractionRevision: 1, response: {answers: [{kind: 'single_choice', questionId: 'q1', choice: 'yes'}]}},
    MCP_ELICITATION: {responseKind: 'mcp_elicitation', operationCode: 'OP-021', header, interactionRef, claimProof: {claimId: 'claim-1', claimToken: 'opaque', leaseRevision: 1}, expectedInteractionRevision: 1, response: {disposition: 'accept_text', text: 'ok'}},
    EXIT_PLAN: {responseKind: 'exit_plan', operationCode: 'OP-022', header, interactionRef, claimProof: {claimId: 'claim-1', claimToken: 'opaque', leaseRevision: 1}, expectedInteractionRevision: 1, response: {disposition: 'accept'}},
  };
  return {snapshot, interactionRef, command: {commandKind: 'respond', command: responseByKind[kind]}};
}

export function capabilitySnapshot({claude = false, itemsList = false, sourcePartition = SOURCE, availability = 'UNKNOWN'} = {}) {
  const available = () => ({support: 'SUPPORTED', availability: 'AVAILABLE'});
  return {profileId: PROFILE_ID, sourceEpoch: epoch({sourcePartition}), snapshotRevision: 1, capabilities: [
    {key: 'timeline_read', ...available()}, {key: 'timeline_live', ...available()}, {key: 'operation_core', ...available()}, {key: 'queue_control', ...available()}, {key: 'manual_interaction', ...available()}, {key: 'codex_thread_turns_list', ...available()},
    {key: 'codex_thread_items_list', support: itemsList ? 'SUPPORTED' : 'UNSUPPORTED', availability: itemsList ? 'AVAILABLE' : availability, ...(itemsList ? {} : {problemCode: 'PROVIDER_METHOD_NOT_SUPPORTED'})},
    {key: 'codex_thread_timeline_list', support: 'UNSUPPORTED', availability: 'UNKNOWN', problemCode: 'PROVIDER_METHOD_NOT_SUPPORTED'}, {key: 'message_image_ingress', ...available()},
    {key: 'claude_provider', support: claude ? 'SUPPORTED' : 'UNSUPPORTED', availability: claude ? 'AVAILABLE' : 'UNKNOWN', ...(claude ? {} : {problemCode: 'CLAUDE_NOT_IMPLEMENTED'})},
  ]};
}

export function imageIngress({source = SOURCE, sourcePartition, sizeBytes = 4096, mediaType = 'image/png', sha256 = 'a'.repeat(64), replaySha256 = sha256, turnImageCount = 1, stateStatus = 'COMMITTED'} = {}) {
  const effectiveSource = sourcePartition ?? source;
  const sourceEpoch = epoch({sourcePartition: effectiveSource});
  const header = (requestId) => ({requestId, clientInstanceId: 'client-1', sourceEpoch});
  const prepare = {header: header('image-prepare'), uploadId: 'upload-1', mediaType, sizeBytes, sha256};
  const replayPrepare = {...prepare, header: header('image-prepare-replay'), sha256: replaySha256};
  const commit = {header: header('image-commit'), uploadId: 'upload-1'};
  const contentRef = {contentRefId: 'content-image-1', sourcePartition: effectiveSource, mediaType, sizeBytes, sha256, objectGeneration: 1};
  const state = stateStatus === 'PREPARED' ? {status: 'PREPARED', uploadId: 'upload-1', uploadTicket: {ticketId: 'ticket-1', sourcePartition: effectiveSource, uploadId: 'upload-1', sizeBytes, sha256, expiresAt: '2999-01-01T00:00:00Z'}, expiresAt: '2999-01-01T00:00:00Z'} : {status: 'COMMITTED', uploadId: 'upload-1', contentRef};
  const turnImageRefs = Array.from({length: turnImageCount}, (_, index) => ({imageId: `image-${index}`, contentRef}));
  return {prepare, replayPrepare, commit, state, turnImageRefs};
}

export function canonicalPageBodyBytes(body) {
  return canonicalUtf8(body).byteLength;
}
