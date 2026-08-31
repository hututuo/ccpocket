import {canonicalize, canonicalUtf8, jcsDigest} from './canonical.mjs';
import {evaluateAdmissionLookupCase} from './admission-semantics.mjs';
import {
  evaluateMachineAuthorityCase,
  evaluateMachineSqlCase,
} from './machine-semantics.mjs';
import {evaluateTransactionAuthorityCase} from './transaction-semantics.mjs';
import {
  CODEX_BUILD_SHA256,
  MAX_CONTROL_FRAME_BYTES,
  MAX_CONTROL_PAYLOAD_BYTES,
  MAX_INLINE_TEXT_BYTES,
  MAX_IMAGE_BYTES,
  MAX_PUBLICATION_PAGE_BYTES,
  MAX_PROVIDER_TURN_BYTES,
  MAX_TURN_IMAGE_COUNT,
  deriveBeginHeaderDigest,
  deriveCoverageDigest,
  deriveManifestDigest,
  deriveOrderDigest,
  derivePageDigest,
  deriveReceiptDigest,
  codexAdapterCertification,
  codexAdapterCertificationPreimage,
  codexAdapterProbeFacts,
  coverageOrderedIsland,
  materializationSubject,
  operationFingerprint,
  operationRef,
} from './semantic-primitives.mjs';

const DIGEST = /^[0-9a-f]{64}$/;
const READ_PLAN_DOMAIN = 'ccpocket.timeline-read-plan.v1';
const READ_SPEC_DOMAIN = 'ccpocket.timeline-provider-read-spec.v1';
const READ_RESULT_DOMAIN = 'ccpocket.timeline-provider-read-result.v1';
const READ_EVIDENCE_DOMAIN = 'ccpocket.timeline-provider-read-evidence.v1';
const REPAIR_DOMAIN = 'ccpocket.gap-repair-intent.v1';
const PAGE_DOMAIN = 'ccpocket.materialization-page.v1';
const BEGIN_DOMAIN = 'ccpocket.materialization-begin.v1';
const PAYLOAD_COMMITMENT_DOMAIN = 'ccpocket.timeline-payload-commitment.v1';
const PROVIDER_METHOD = 'thread/turns/list';
const DEFAULT_CERTIFICATION_ID = 'codex-cert-0.151.0';
const ZERO = Object.freeze({
  'wire.closed-normalized-shape': Object.freeze({durableRows: 0, wireWrites: 0}),
  'identity.source-fence': Object.freeze({admissionRows: 0, interactionRows: 0, providerCalls: 0, publicationRows: 0, queueRows: 0, visibleResults: 0}),
  'timeline.typed-empty': Object.freeze({canonicalCommits: 0, lastGoodDeletes: 0}),
  'timeline.read-evidence': Object.freeze({canonicalCommits: 0, providerReads: 0, wireWrites: 0}),
  'timeline.provider-turn-boundary': Object.freeze({mobileCommits: 0, mobileAcks: 0, visibleResults: 0}),
  'timeline.materialization': Object.freeze({mobileCommits: 0, mobileAcks: 0, visibleResults: 0}),
  'timeline.page-size': Object.freeze({mobileCommits: 0, mobileAcks: 0, visibleResults: 0}),
  'image.ingress': Object.freeze({contentRefs: 0, operationAdmissions: 0}),
  'timeline.cache-reuse': Object.freeze({canonicalRewrites: 0, repeatProviderReads: 0}),
  'timeline.order-gap': Object.freeze({canonicalCommits: 0, gapClosures: 0, itemReorders: 0}),
  'timeline.last-good': Object.freeze({canonicalCommits: 0, lastGoodDeletes: 0, lastGoodDowngrades: 0}),
  'timeline.live-promotion': Object.freeze({canonicalDuplicates: 0, livePromotions: 0, liveReorders: 0}),
  'operation.typed-union': Object.freeze({admissionRows: 0, providerCalls: 0}),
  'operation.fingerprint': Object.freeze({newAdmissionRows: 0, providerCalls: 0, queueRows: 0}),
  'operation.admission-barrier': Object.freeze({providerCalls: 0}),
  'operation.outcome-unknown': Object.freeze({reconcileMutationCalls: 0, redispatches: 0, terminalSuccessWrites: 0}),
  'queue.revision': Object.freeze({providerCalls: 0, queueRowsUpdated: 0}),
  'interaction.source': Object.freeze({interactionRows: 0, operationRows: 0, providerCalls: 0, queueRows: 0, visibleResults: 0}),
  'interaction.actor': Object.freeze({interactionRows: 0, operationRows: 0, providerCalls: 0, queueRows: 0, visibleResults: 0}),
  'interaction.expiry': Object.freeze({interactionRows: 0, operationRows: 0, providerCalls: 0, queueRows: 0, visibleResults: 0}),
  'interaction.duplicate': Object.freeze({additionalOperationRows: 0, additionalProviderCalls: 0, additionalVisibleResults: 0}),
  'interaction.variant': Object.freeze({interactionRows: 0, operationRows: 0, providerCalls: 0, queueRows: 0, visibleResults: 0}),
  'capability.claude': Object.freeze({admissionRows: 0, providerCalls: 0}),
  'capability.codex-runtime': Object.freeze({providerReads: 0, publications: 0}),
});

const INTERACTION_CODES = new Map([
  ['approval', 'OP-019'],
  ['question', 'OP-020'],
  ['mcp_elicitation', 'OP-021'],
  ['exit_plan', 'OP-022'],
]);
const IMAGE_TYPES = new Set(['image/png', 'image/jpeg', 'image/gif', 'image/webp']);

function clone(value) {
  try {
    return structuredClone(value);
  } catch {
    return null;
  }
}

function same(left, right) {
  try {
    return canonicalize(left) === canonicalize(right);
  } catch {
    return false;
  }
}

function keysExactly(value, keys) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return false;
  const prototype = Object.getPrototypeOf(value);
  if (prototype !== Object.prototype && prototype !== null) return false;
  const expected = new Set(keys);
  const ownKeys = Reflect.ownKeys(value);
  if (ownKeys.length !== keys.length || ownKeys.some((key) => typeof key !== 'string' || !expected.has(key))) return false;
  return keys.every((key) => {
    const descriptor = Object.getOwnPropertyDescriptor(value, key);
    return descriptor && descriptor.enumerable === true && Object.hasOwn(descriptor, 'value');
  });
}

function keysAtMost(value, required, optional = []) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return false;
  const prototype = Object.getPrototypeOf(value);
  if (prototype !== Object.prototype && prototype !== null) return false;
  const allowed = new Set([...required, ...optional]);
  const ownKeys = Reflect.ownKeys(value);
  return required.every((key) => Object.hasOwn(value, key)) && ownKeys.every((key) => {
    if (typeof key !== 'string' || !allowed.has(key)) return false;
    const descriptor = Object.getOwnPropertyDescriptor(value, key);
    return descriptor && descriptor.enumerable === true && Object.hasOwn(descriptor, 'value');
  });
}

function denseArray(value) {
  if (!Array.isArray(value)) return false;
  const lengthDescriptor = Object.getOwnPropertyDescriptor(value, 'length');
  if (!lengthDescriptor || !Object.hasOwn(lengthDescriptor, 'value') || lengthDescriptor.enumerable !== false) return false;
  const expectedKeys = new Set(['length']);
  for (let index = 0; index < value.length; index += 1) {
    const key = String(index);
    expectedKeys.add(key);
    const descriptor = Object.getOwnPropertyDescriptor(value, key);
    if (!descriptor || !Object.hasOwn(descriptor, 'value') || descriptor.enumerable !== true) return false;
  }
  return Reflect.ownKeys(value).every((key) => typeof key === 'string' && expectedKeys.has(key));
}

function isDigest(value) {
  return typeof value === 'string' && DIGEST.test(value);
}

function validSource(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value) &&
    keysExactly(value, ['bridgeIdentityId', 'bridgeInstanceId', 'codexSourceId']) &&
    Object.values(value).every((id) => typeof id === 'string' && id.length > 0);
}

function sourceMatches(value, expected) {
  return validSource(value) && validSource(expected) && same(value, expected);
}

function accept() {
  return {valid: true, reason: 'NONE', postState: 'APPLIED', sideEffects: {}};
}

function reject(oracleRef, reason) {
  return {valid: false, reason, postState: 'UNCHANGED', sideEffects: clone(ZERO[oracleRef] ?? {})};
}

function canonicalLength(value) {
  try {
    return canonicalUtf8(value).byteLength;
  } catch {
    return null;
  }
}

function digestMatches(value, preimage) {
  try {
    return isDigest(value) && value === jcsDigest(preimage);
  } catch {
    return false;
  }
}

function scope(value, expectedSource) {
  return value && keysExactly(value, ['domain', 'threadRef']) && value.domain === 'TIMELINE' &&
    value.threadRef && keysExactly(value.threadRef, ['sourcePartition', 'providerThreadId']) &&
    sourceMatches(value.threadRef.sourcePartition, expectedSource) &&
    typeof value.threadRef.providerThreadId === 'string' && value.threadRef.providerThreadId.length > 0;
}

function materialized(value, expectedScope, expectedId) {
  return value && keysExactly(value, ['domain', 'threadRef', 'materializationId']) &&
    scope({domain: value.domain, threadRef: value.threadRef}, expectedScope?.threadRef?.sourcePartition) &&
    (!expectedScope || same({domain: value.domain, threadRef: value.threadRef}, expectedScope)) &&
    typeof value.materializationId === 'string' && value.materializationId.length > 0 &&
    (expectedId === undefined || value.materializationId === expectedId);
}

function epochValid(value, expectedSource) {
  return value && keysExactly(value, ['sourcePartition', 'connectionEpoch', 'sourceEpoch', 'providerInstanceEpoch', 'runtimeAuthorityGeneration']) &&
    sourceMatches(value.sourcePartition, expectedSource ?? value.sourcePartition) &&
    ['connectionEpoch', 'sourceEpoch', 'providerInstanceEpoch', 'runtimeAuthorityGeneration']
      .every((key) => Number.isSafeInteger(value[key]) && value[key] >= 1);
}

function endpointValid(value, expectedScope) {
  if (!value || typeof value !== 'object') return false;
  if (value.endpointKind === 'TURN') {
    return keysExactly(value, ['endpointKind', 'turnRef', 'turnOrdinal']) &&
      value.turnRef && scope({domain: 'TIMELINE', threadRef: value.turnRef.threadRef}, expectedScope?.threadRef?.sourcePartition) &&
      same(value.turnRef.threadRef, expectedScope.threadRef) && Number.isSafeInteger(value.turnOrdinal);
  }
  if (value.endpointKind === 'ITEM') {
    return keysExactly(value, ['endpointKind', 'itemRef', 'timelineOrdinal']) && value.itemRef &&
      value.itemRef.turnRef && scope({domain: 'TIMELINE', threadRef: value.itemRef.turnRef.threadRef}, expectedScope?.threadRef?.sourcePartition) &&
      same(value.itemRef.turnRef.threadRef, expectedScope.threadRef) && Number.isSafeInteger(value.timelineOrdinal);
  }
  return false;
}

function endpointForTurn(turnSpine) {
  const node = turnSpine.turnSpine ?? turnSpine.turnIndex ?? turnSpine;
  return {endpointKind: 'TURN', turnRef: node.turnRef, turnOrdinal: node.turnOrdinal};
}

function endpointForItem(item) {
  return {endpointKind: 'ITEM', itemRef: item.itemRef, timelineOrdinal: item.timelineOrdinal};
}

function endpointOrder(left, right) {
  if (!left || !right || left.endpointKind !== right.endpointKind) return null;
  const leftOrdinal = left.endpointKind === 'TURN' ? left.turnOrdinal : left.timelineOrdinal;
  const rightOrdinal = right.endpointKind === 'TURN' ? right.turnOrdinal : right.timelineOrdinal;
  if (leftOrdinal < rightOrdinal) return -1;
  if (leftOrdinal > rightOrdinal) return 1;
  return 0;
}

function verifyReadSpec(value, expectedSource, expectedScope) {
  if (!value || !keysExactly(value, ['digestDomain', 'sourcePartition', 'subjectScope', 'readPlanDigest', 'providerMethod', 'sortDirection', 'itemsView', 'limit', 'cursor', 'readSpecDigest']) ||
      value.digestDomain !== READ_SPEC_DOMAIN ||
      !sourceMatches(value.sourcePartition, expectedSource ?? value.sourcePartition) ||
      !scope(value.subjectScope, expectedScope?.threadRef?.sourcePartition ?? value.sourcePartition) ||
      expectedScope && !same(value.subjectScope, expectedScope) ||
      value.providerMethod !== PROVIDER_METHOD || !['asc', 'desc'].includes(value.sortDirection) ||
      !['notLoaded', 'full'].includes(value.itemsView) || !Number.isSafeInteger(value.limit) || value.limit < 1 ||
      value.limit > 128 || !(value.cursor === null || typeof value.cursor === 'string')) return false;
  const planPreimage = {
    digestDomain: READ_PLAN_DOMAIN,
    sourcePartition: value.sourcePartition,
    subjectScope: value.subjectScope,
    providerMethod: value.providerMethod,
    sortDirection: value.sortDirection,
    orderingContract: 'CODEX_THREAD_TURNS_PROVIDER_ORDER_V1',
  };
  if (!digestMatches(value.readPlanDigest, planPreimage)) return false;
  const preimage = {...value};
  delete preimage.readSpecDigest;
  return digestMatches(value.readSpecDigest, preimage);
}

function verifyReadPlan(value, expectedSource, expectedScope) {
  if (!value || !keysExactly(value, ['digestDomain', 'sourcePartition', 'subjectScope', 'providerMethod', 'sortDirection', 'orderingContract', 'readPlanDigest']) ||
      value.digestDomain !== READ_PLAN_DOMAIN || !sourceMatches(value.sourcePartition, expectedSource) ||
      !scope(value.subjectScope, expectedSource) || !same(value.subjectScope, expectedScope) ||
      value.providerMethod !== PROVIDER_METHOD || !['asc', 'desc'].includes(value.sortDirection) ||
      value.orderingContract !== 'CODEX_THREAD_TURNS_PROVIDER_ORDER_V1') return false;
  return digestMatches(value.readPlanDigest, {
    digestDomain: READ_PLAN_DOMAIN,
    sourcePartition: value.sourcePartition,
    subjectScope: value.subjectScope,
    providerMethod: value.providerMethod,
    sortDirection: value.sortDirection,
    orderingContract: value.orderingContract,
  });
}

function certificationDigest(id) {
  // Certification ids are opaque references into the immutable adapter
  // certification catalog.  Do not derive authority from an arbitrary id and
  // a fixed executable hash.  The catalog digest is independently recomputed
  // from the complete CodexAdapterCertificationPreimageV1.
  if (id !== DEFAULT_CERTIFICATION_ID) return null;
  const record = codexAdapterCertification();
  return record.codexCertificationDigest === jcsDigest(codexAdapterCertificationPreimage())
    ? record.codexCertificationDigest
    : null;
}

function readResultPreimage({sourcePartition, subjectScope, readPlanDigest, readSpecDigest, returnedCursor, resultKind = 'FULL_TURNS', orderedTurns = [], orderedTurnIndexes = [], oversizedTurn, resultCount}) {
  const count = resultCount ?? (resultKind === 'OVERSIZED_TURN' ? 1 : resultKind === 'TURN_INDEX' ? orderedTurnIndexes.length : orderedTurns.length);
  return {
    digestDomain: READ_RESULT_DOMAIN,
    resultKind,
    sourcePartition,
    subjectScope,
    readPlanDigest,
    readSpecDigest,
    returnedCursor,
    resultCount: count,
    ...(resultKind === 'TURN_INDEX' ? {orderedTurnIndexes} : resultKind === 'OVERSIZED_TURN' ? {oversizedTurn} : {orderedTurns}),
  };
}

function verifyReadEvidence(value, expectedSource, expectedScope, orderedTurns = null) {
  if (!value || !keysExactly(value, ['digestDomain', 'readEvidenceId', 'sourcePartition', 'subjectScope', 'readPlanDigest', 'readSpecDigest', 'codexCertificationId', 'codexCertificationDigest', 'readBody', 'readEvidenceDigest']) ||
      value.digestDomain !== READ_EVIDENCE_DOMAIN ||
      !sourceMatches(value.sourcePartition, expectedSource ?? value.sourcePartition) ||
      !scope(value.subjectScope, expectedScope?.threadRef?.sourcePartition ?? value.sourcePartition) ||
      expectedScope && !same(value.subjectScope, expectedScope) ||
      typeof value.readEvidenceId !== 'string' || value.readEvidenceId.length === 0 ||
      typeof value.codexCertificationId !== 'string' || value.codexCertificationId.length === 0 ||
      !isDigest(value.codexCertificationDigest) || value.codexCertificationDigest !== certificationDigest(value.codexCertificationId)) {
    return reject('timeline.read-evidence', 'PROVIDER_METHOD_NOT_SUPPORTED');
  }
  const body = value.readBody;
  if (!body || !keysExactly(body, ['providerMethod', 'sortDirection', 'readPlanDigest', 'itemsView', 'limit', 'cursor', 'returnedCursor', 'resultKind', 'resultCount', 'resultDigest', 'sourceEpoch', 'providerInstanceEpoch', 'readGeneration', 'codexExecutableDigest']) ||
      body.providerMethod !== PROVIDER_METHOD || !['asc', 'desc'].includes(body.sortDirection) ||
      body.readPlanDigest !== value.readPlanDigest || !['notLoaded', 'full'].includes(body.itemsView) || !Number.isSafeInteger(body.limit) || body.limit < 1 || body.limit > 128 || body.itemsView === 'full' && body.limit !== 1 ||
      !(body.cursor === null || typeof body.cursor === 'string') || !(body.returnedCursor === null || typeof body.returnedCursor === 'string') ||
      !['TURN_INDEX', 'FULL_TURNS', 'OVERSIZED_TURN'].includes(body.resultKind) ||
      !Number.isSafeInteger(body.resultCount) || body.resultCount < 0 || !isDigest(body.resultDigest) ||
      !Number.isSafeInteger(body.sourceEpoch) || body.sourceEpoch < 1 || !Number.isSafeInteger(body.providerInstanceEpoch) || body.providerInstanceEpoch < 1 ||
      !Number.isSafeInteger(body.readGeneration) || body.readGeneration < 1 || body.codexExecutableDigest !== CODEX_BUILD_SHA256) {
    return reject('timeline.read-evidence', 'PROVIDER_METHOD_NOT_SUPPORTED');
  }
  const spec = {
    digestDomain: READ_SPEC_DOMAIN,
    sourcePartition: value.sourcePartition,
    subjectScope: value.subjectScope,
    readPlanDigest: value.readPlanDigest,
    providerMethod: body.providerMethod,
    sortDirection: body.sortDirection,
    itemsView: body.itemsView,
    limit: body.limit,
    cursor: body.cursor,
    readSpecDigest: value.readSpecDigest,
  };
  // verifyReadSpec reconstructs the closed preimage from the body rather than
  // trusting a caller-provided digest. This is the sole admission path for
  // the evidence's readSpecDigest.
  if (!verifyReadSpec(spec, expectedSource ?? value.sourcePartition, expectedScope)) {
    return reject('timeline.read-evidence', 'PROVIDER_METHOD_NOT_SUPPORTED');
  }
  if (orderedTurns === null) {
    if (body.resultCount !== 0) return reject('timeline.read-evidence', 'PROVIDER_METHOD_NOT_SUPPORTED');
    orderedTurns = [];
  }
  const normalizedKind = body.resultKind;
  const isIndex = normalizedKind === 'TURN_INDEX';
  const isOversized = normalizedKind === 'OVERSIZED_TURN';
  let normalized;
  if (isIndex) {
    const indexes = [];
    let previous = null;
    const seen = new Set();
    for (const entry of orderedTurns) {
      const index = entry?.turnIndex ?? entry;
      // A null predecessor starts a new structural island; otherwise the
      // provider's signed ordinal/ref pair must continue the prior index.
      if (!verifyTurnIndex(index, expectedScope, index?.predecessorTurnRef === null ? null : previous)) return reject('timeline.read-evidence', 'PROVIDER_METHOD_NOT_SUPPORTED');
      const key = canonicalize(index.turnRef);
      if (seen.has(key)) return reject('timeline.read-evidence', 'PROVIDER_METHOD_NOT_SUPPORTED');
      seen.add(key);
      indexes.push(index);
      previous = index;
    }
    normalized = {orderedTurnIndexes: indexes, orderedTurns: []};
  } else if (isOversized) {
    const observation = orderedTurns.length === 1 ? orderedTurns[0]?.oversizedTurn ?? orderedTurns[0] : null;
    const index = observation?.turnIndex;
    if (!observation || !keysExactly(observation, ['turnIndex', 'providerReportedItemCount', 'observedTurnByteCount', 'maximumTurnByteCount', 'indexReadEvidenceId', 'indexReadEvidenceDigest']) ||
        !validTurnIndexShape(index, expectedScope) || !Number.isSafeInteger(observation.providerReportedItemCount) || observation.providerReportedItemCount < 0 ||
        typeof observation.observedTurnByteCount !== 'string' || !/^[0-9]+$/.test(observation.observedTurnByteCount) || BigInt(observation.observedTurnByteCount) <= BigInt(MAX_PROVIDER_TURN_BYTES) ||
        observation.maximumTurnByteCount !== MAX_PROVIDER_TURN_BYTES || typeof observation.indexReadEvidenceId !== 'string' || observation.indexReadEvidenceId.length === 0 || !isDigest(observation.indexReadEvidenceDigest)) {
      return reject('timeline.read-evidence', 'PROVIDER_METHOD_NOT_SUPPORTED');
    }
    normalized = {orderedTurnIndexes: [], orderedTurns: [], oversizedTurn: observation};
  } else {
    let previous = null;
    const fullTurns = [];
    for (const turn of orderedTurns) {
      if (!turn || !keysExactly(turn, ['turnSpine', 'providerReportedItemCount', 'observedTurnByteCount', 'maximumTurnByteCount', 'orderedItems']) ||
      !verifyTurnSpine(turn.turnSpine, expectedScope, previous) || !denseArray(turn.orderedItems) ||
          !Number.isSafeInteger(turn.providerReportedItemCount) || turn.providerReportedItemCount < 0 || turn.providerReportedItemCount !== turn.orderedItems.length ||
          turn.turnSpine.itemCount !== turn.orderedItems.length || turn.maximumTurnByteCount !== MAX_PROVIDER_TURN_BYTES ||
          typeof turn.observedTurnByteCount !== 'string' || !/^[0-9]+$/.test(turn.observedTurnByteCount) || BigInt(turn.observedTurnByteCount) > BigInt(MAX_PROVIDER_TURN_BYTES) ||
          turn.observedTurnByteCount !== String(canonicalLength({turnRef: turn.turnSpine.turnRef, orderedItems: turn.orderedItems}) ?? -1)) return reject('timeline.read-evidence', 'PROVIDER_METHOD_NOT_SUPPORTED');
      const seenItems = new Set();
      let previousItem = null;
      for (const item of turn.orderedItems) {
        if (!verifyItem(item, expectedScope, previousItem, seenItems)) return reject('timeline.read-evidence', 'PROVIDER_METHOD_NOT_SUPPORTED');
        previousItem = item;
      }
      fullTurns.push(turn);
      previous = turn;
    }
    normalized = {orderedTurns: fullTurns, orderedTurnIndexes: []};
  }
  if (body.itemsView === 'notLoaded' && !isIndex || body.itemsView === 'full' && isIndex ||
      isOversized && (body.resultCount !== 1 || body.limit !== 1) ||
      !isOversized && body.resultCount !== (isIndex ? normalized.orderedTurnIndexes.length : normalized.orderedTurns.length) ||
      body.resultCount > body.limit) {
    return reject('timeline.read-evidence', 'PROVIDER_METHOD_NOT_SUPPORTED');
  }
  const resultPreimage = readResultPreimage({sourcePartition: value.sourcePartition, subjectScope: value.subjectScope, readPlanDigest: value.readPlanDigest, readSpecDigest: value.readSpecDigest, returnedCursor: body.returnedCursor, resultKind: normalizedKind, orderedTurns: normalized.orderedTurns, orderedTurnIndexes: normalized.orderedTurnIndexes, resultCount: body.resultCount, oversizedTurn: normalized.oversizedTurn});
  if (!digestMatches(body.resultDigest, resultPreimage)) return reject('timeline.read-evidence', 'PROVIDER_METHOD_NOT_SUPPORTED');
  const evidencePreimage = {...value};
  delete evidencePreimage.readEvidenceDigest;
  return digestMatches(value.readEvidenceDigest, evidencePreimage) ? accept() : reject('timeline.read-evidence', 'PROVIDER_METHOD_NOT_SUPPORTED');
}

/**
 * Verify the relation between a sealed evidence object and the separately
 * sealed normalized result it names.  The wire/evidence object intentionally
 * carries only the result digest; callers must provide the resolved result to
 * this observation API instead of asking the evidence oracle to infer a
 * non-empty result from a count or an arbitrary digest.
 */
export function evaluateReadEvidenceObservation(observation = {}) {
  const invalid = () => reject('timeline.read-evidence', 'PROVIDER_METHOD_NOT_SUPPORTED');
  const {evidence, normalizedResult, priorIndexEvidence} = observation;
  const wrapperKeys = normalizedResult?.resultKind === 'OVERSIZED_TURN'
    ? ['evidence', 'normalizedResult', 'priorIndexEvidence']
    : ['evidence', 'normalizedResult'];
  if (!keysExactly(observation, wrapperKeys) || !evidence || !normalizedResult || typeof normalizedResult !== 'object' || Array.isArray(normalizedResult)) return invalid();
  const common = ['digestDomain', 'resultKind', 'sourcePartition', 'subjectScope', 'readPlanDigest', 'readSpecDigest', 'returnedCursor', 'resultCount'];
  if (!keysExactly(normalizedResult, [...common, normalizedResult.resultKind === 'TURN_INDEX' ? 'orderedTurnIndexes' : normalizedResult.resultKind === 'FULL_TURNS' ? 'orderedTurns' : 'oversizedTurn']) ||
      normalizedResult.digestDomain !== READ_RESULT_DOMAIN || !validSource(normalizedResult.sourcePartition) ||
      !scope(normalizedResult.subjectScope, normalizedResult.sourcePartition) || !isDigest(normalizedResult.readPlanDigest) ||
      !isDigest(normalizedResult.readSpecDigest) || !(normalizedResult.returnedCursor === null || typeof normalizedResult.returnedCursor === 'string') ||
      !Number.isSafeInteger(normalizedResult.resultCount) || normalizedResult.resultCount < 0 ||
      !['TURN_INDEX', 'FULL_TURNS', 'OVERSIZED_TURN'].includes(normalizedResult.resultKind) ||
      !same(normalizedResult.sourcePartition, evidence.sourcePartition) || !same(normalizedResult.subjectScope, evidence.subjectScope) ||
      normalizedResult.readPlanDigest !== evidence.readPlanDigest || normalizedResult.readSpecDigest !== evidence.readSpecDigest ||
      normalizedResult.returnedCursor !== evidence.readBody?.returnedCursor || normalizedResult.resultKind !== evidence.readBody?.resultKind ||
      normalizedResult.resultCount !== evidence.readBody?.resultCount) return invalid();

  let orderedTurns;
  if (normalizedResult.resultKind === 'TURN_INDEX') {
    if (!denseArray(normalizedResult.orderedTurnIndexes)) return invalid();
    orderedTurns = normalizedResult.orderedTurnIndexes.map((turnIndex) => ({turnIndex}));
  } else if (normalizedResult.resultKind === 'FULL_TURNS') {
    if (!denseArray(normalizedResult.orderedTurns)) return invalid();
    orderedTurns = normalizedResult.orderedTurns;
  } else {
    if (!Object.hasOwn(normalizedResult, 'oversizedTurn')) return invalid();
    orderedTurns = [normalizedResult.oversizedTurn];
  }
  if (normalizedResult.resultCount !== orderedTurns.length ||
      normalizedResult.resultKind === 'OVERSIZED_TURN' && normalizedResult.resultCount !== 1 ||
      !digestMatches(evidence.readBody?.resultDigest, normalizedResult)) return invalid();
  if (normalizedResult.resultKind === 'OVERSIZED_TURN') {
    const prior = priorIndexEvidence;
    const priorEvidence = prior?.evidence;
    const priorResult = prior?.normalizedResult;
    if (!keysExactly(prior, ['evidence', 'normalizedResult']) || !priorEvidence || !priorResult || priorResult.resultKind !== 'TURN_INDEX' || evidence.readBody.itemsView !== 'full' || priorEvidence.readBody?.itemsView !== 'notLoaded' ||
        evidence.readBody.limit !== 1 || priorEvidence.readEvidenceId === evidence.readEvidenceId || priorEvidence.readEvidenceDigest === evidence.readEvidenceDigest ||
        priorEvidence.readSpecDigest === evidence.readSpecDigest || priorEvidence.readBody?.resultDigest === evidence.readBody.resultDigest ||
        priorEvidence.readPlanDigest !== evidence.readPlanDigest || !same(priorEvidence.sourcePartition, evidence.sourcePartition) ||
        !same(priorEvidence.subjectScope, evidence.subjectScope) || priorEvidence.codexCertificationId !== evidence.codexCertificationId ||
        priorEvidence.codexCertificationDigest !== evidence.codexCertificationDigest || priorEvidence.readBody?.sourceEpoch !== evidence.readBody.sourceEpoch ||
        priorEvidence.readBody?.providerInstanceEpoch !== evidence.readBody.providerInstanceEpoch || priorEvidence.readBody?.codexExecutableDigest !== evidence.readBody.codexExecutableDigest ||
        !Number.isSafeInteger(priorEvidence.readBody?.readGeneration) || !Number.isSafeInteger(evidence.readBody.readGeneration) ||
        priorEvidence.readBody.readGeneration >= evidence.readBody.readGeneration) return invalid();
    const priorOutcome = evaluateReadEvidenceObservation(prior);
    if (!priorOutcome.valid) return invalid();
    const targetIndex = normalizedResult.oversizedTurn?.turnIndex;
    if (normalizedResult.oversizedTurn?.indexReadEvidenceId !== priorEvidence.readEvidenceId ||
        normalizedResult.oversizedTurn?.indexReadEvidenceDigest !== priorEvidence.readEvidenceDigest) return invalid();
    const matchingIndexes = priorResult.orderedTurnIndexes.filter((candidate) => same(candidate, targetIndex));
    if (matchingIndexes.length !== 1) return invalid();
  }
  return verifyReadEvidence(evidence, evidence.sourcePartition, evidence.subjectScope, orderedTurns);
}

function verifyCodexAdapterCertification(value) {
  const keys = [
    'certificationVersion', 'codexCertificationId', 'codexExecutableDigest',
    'providerBuildDigest', 'methods', 'schema', 'probe', 'semantics', 'status',
    'certificationRevision', 'codexCertificationDigest',
  ];
  if (!value || !keysExactly(value, keys) || value.certificationVersion !== 'CodexAdapterCertificationV1' ||
      value.codexCertificationId !== DEFAULT_CERTIFICATION_ID ||
      !isDigest(value.codexExecutableDigest) || !isDigest(value.providerBuildDigest) ||
      value.codexExecutableDigest !== CODEX_BUILD_SHA256 || value.providerBuildDigest !== CODEX_BUILD_SHA256 ||
      !Number.isSafeInteger(value.certificationRevision) || value.certificationRevision < 1 ||
      !isDigest(value.codexCertificationDigest)) return false;
  const expected = codexAdapterCertification();
  return same(value, expected) && value.codexCertificationDigest === jcsDigest(codexAdapterCertificationPreimage());
}

function verifyCodexAdapterProbeFacts(value) {
  const expected = codexAdapterProbeFacts();
  return value && keysExactly(value, ['providerMethod', 'runtime', 'cursor', 'sortDirection', 'itemsView', 'identity', 'ordering']) &&
    value.providerMethod === expected.providerMethod && same(value.runtime, expected.runtime) &&
    value.cursor === expected.cursor && same(value.sortDirection, expected.sortDirection) && same(value.itemsView, expected.itemsView) &&
    value.identity === expected.identity && value.ordering === expected.ordering;
}

function verifyIndependentMaterializationAuthority(authority, expectedSource, expectedScope) {
  const invalid = () => null;
  if (!authority || typeof authority !== 'object' || Array.isArray(authority) ||
      !authority.normalizedResult || !['TURN_INDEX', 'FULL_TURNS', 'OVERSIZED_TURN'].includes(authority.normalizedResult.resultKind)) return invalid();
  const authorityKeys = authority.normalizedResult.resultKind === 'OVERSIZED_TURN'
    ? ['readPlan', 'readSpec', 'normalizedResult', 'evidence', 'certification', 'probeEvidence', 'priorIndexEvidence']
    : ['readPlan', 'readSpec', 'normalizedResult', 'evidence', 'certification', 'probeEvidence'];
  if (!keysExactly(authority, authorityKeys)) return invalid();
  if (!verifyCodexAdapterCertification(authority.certification) ||
      !verifyCodexAdapterProbeFacts(authority.probeEvidence)) return invalid();
  const plan = authority.readPlan;
  const spec = authority.readSpec;
  if (!verifyReadPlan(plan, expectedSource, expectedScope) || !verifyReadSpec(spec, expectedSource, expectedScope) ||
      spec.readPlanDigest !== plan.readPlanDigest) return invalid();
  const result = authority.normalizedResult;
  if (!result || !['TURN_INDEX', 'FULL_TURNS', 'OVERSIZED_TURN'].includes(result.resultKind)) return invalid();
  const resultArrayKey = result.resultKind === 'TURN_INDEX' ? 'orderedTurnIndexes' : result.resultKind === 'FULL_TURNS' ? 'orderedTurns' : 'oversizedTurn';
  const resultKeys = ['digestDomain', 'resultKind', 'sourcePartition', 'subjectScope', 'readPlanDigest', 'readSpecDigest', 'returnedCursor', 'resultCount', resultArrayKey];
  if (!keysExactly(result, resultKeys) || result.digestDomain !== READ_RESULT_DOMAIN ||
      !sourceMatches(result.sourcePartition, expectedSource) || !scope(result.subjectScope, expectedSource) ||
      !same(result.subjectScope, expectedScope) || result.readPlanDigest !== plan.readPlanDigest ||
      result.readSpecDigest !== spec.readSpecDigest || !(result.returnedCursor === null || typeof result.returnedCursor === 'string') ||
      !Number.isSafeInteger(result.resultCount) || result.resultCount < 0) return invalid();
  if (result.resultKind === 'OVERSIZED_TURN') {
    if (!result.oversizedTurn || result.resultCount !== 1) return invalid();
  } else if (!denseArray(result[resultArrayKey]) || result.resultCount !== result[resultArrayKey].length) return invalid();
  if (result.resultKind === 'TURN_INDEX' && spec.itemsView !== 'notLoaded' ||
      result.resultKind !== 'TURN_INDEX' && spec.itemsView !== 'full' ||
      result.resultCount > spec.limit) return invalid();
  const evidence = authority.evidence;
  const evidenceObservation = result.resultKind === 'OVERSIZED_TURN'
    ? evaluateReadEvidenceObservation({evidence, normalizedResult: result, priorIndexEvidence: authority.priorIndexEvidence})
    : evaluateReadEvidenceObservation({evidence, normalizedResult: result});
  if (!evidenceObservation.valid || !same(evidence.codexCertificationId, authority.certification.codexCertificationId) ||
      evidence.codexCertificationDigest !== authority.certification.codexCertificationDigest ||
      evidence.readPlanDigest !== plan.readPlanDigest || evidence.readSpecDigest !== spec.readSpecDigest ||
      evidence.readBody.providerMethod !== authority.probeEvidence.providerMethod ||
      evidence.readBody.sortDirection !== spec.sortDirection || evidence.readBody.itemsView !== spec.itemsView ||
      evidence.readBody.cursor !== spec.cursor || evidence.readBody.codexExecutableDigest !== authority.certification.codexExecutableDigest) return invalid();
  return {plan, spec, result, evidence, certification: authority.certification, probeEvidence: authority.probeEvidence};
}

function resultTurns(result) {
  if (result.resultKind === 'TURN_INDEX') return result.orderedTurnIndexes.map((turnIndex) => ({turnIndex}));
  if (result.resultKind === 'FULL_TURNS') return result.orderedTurns;
  return [{oversizedTurn: result.oversizedTurn}];
}

function rowsExhaustivelyMatchResult(reduction, result) {
  const expected = resultTurns(result);
  if (expected.length !== reduction.turns.length || result.resultCount !== expected.length) return false;
  for (let index = 0; index < expected.length; index += 1) {
    const actual = reduction.turns[index];
    if (result.resultKind === 'TURN_INDEX') {
      if (actual.nodeKind !== 'INDEX' || !same(actual.turnIndex, expected[index].turnIndex)) return false;
    } else if (result.resultKind === 'FULL_TURNS') {
      if (actual.nodeKind !== 'FULL') return false;
      const expectedTurn = expected[index];
      if (!same(actual.turnSpine, expectedTurn.turnSpine) || !same(actual.orderedItems, expectedTurn.orderedItems) ||
          expectedTurn.providerReportedItemCount !== actual.orderedItems.length ||
          expectedTurn.maximumTurnByteCount !== MAX_PROVIDER_TURN_BYTES ||
          expectedTurn.observedTurnByteCount !== String(canonicalLength({turnRef: actual.turnSpine.turnRef, orderedItems: actual.orderedItems}) ?? -1)) return false;
    } else {
      if (actual.nodeKind !== 'INDEX' || !same(actual.turnIndex, expected[index].oversizedTurn.turnIndex)) return false;
    }
  }
  const expectedItems = result.resultKind === 'FULL_TURNS' ? result.orderedTurns.flatMap((turn) => turn.orderedItems) : [];
  return expectedItems.length === reduction.items.length && expectedItems.every((item, index) => same(item, reduction.items[index]));
}

/**
 * Standalone admission helper for callers that already resolved the sealed
 * plan/spec/result/evidence/certification tuple.  The materialization rule
 * invokes the same helper internally and then performs page provenance.
 */
export function evaluateMaterializationAuthority({authority, sourcePartition, subjectScope} = {}) {
  const resolved = verifyIndependentMaterializationAuthority(authority, sourcePartition, subjectScope);
  return resolved ? accept() : reject('timeline.materialization', 'TIMELINE_ORDER_GAP_INVALID');
}

function verifyRepairTarget(target, expectedScope) {
  if (!target || typeof target.targetKind !== 'string') return false;
  switch (target.targetKind) {
    case 'BEFORE': return keysExactly(target, ['targetKind', 'rightBoundary']) && endpointValid(target.rightBoundary, expectedScope);
    case 'AFTER': return keysExactly(target, ['targetKind', 'leftBoundary']) && endpointValid(target.leftBoundary, expectedScope);
    case 'BETWEEN': return keysExactly(target, ['targetKind', 'leftBoundary', 'rightBoundary']) && endpointValid(target.leftBoundary, expectedScope) && endpointValid(target.rightBoundary, expectedScope) && endpointOrder(target.leftBoundary, target.rightBoundary) === -1;
    case 'COVERAGE_UNKNOWN': return keysExactly(target, ['targetKind', 'subjectScope']) && scope(target.subjectScope, expectedScope.threadRef.sourcePartition) && same(target.subjectScope, expectedScope);
    case 'PAYLOAD': return keysExactly(target, ['targetKind', 'itemRef', 'missingPayloadFields']) && target.itemRef && target.itemRef.turnRef && same(target.itemRef.turnRef.threadRef, expectedScope.threadRef) && denseArray(target.missingPayloadFields) && target.missingPayloadFields.length > 0 && target.missingPayloadFields.every((field, index) => field && keysExactly(field, ['payloadIndex', 'payloadKind', 'fieldName']) && field.payloadKind === 'unavailable' && field.fieldName === 'resolvedPayload' && Number.isSafeInteger(field.payloadIndex) && field.payloadIndex >= 0 && (index === 0 || field.payloadIndex > target.missingPayloadFields[index - 1].payloadIndex));
    case 'TURN_PAYLOAD_NOT_LOADED': return keysExactly(target, ['targetKind', 'turnRef', 'turnOrdinal']) && target.turnRef && same(target.turnRef.threadRef, expectedScope.threadRef) && Number.isSafeInteger(target.turnOrdinal);
    case 'TURN_PAYLOAD_OVERSIZED': return keysExactly(target, ['targetKind', 'turnRef', 'turnOrdinal', 'leftTurnBoundary', 'rightTurnBoundary', 'providerReportedItemCount', 'observedTurnByteCount', 'maximumTurnByteCount', 'problemCode', 'repairDisposition', 'oversizedReadEvidenceId', 'oversizedReadEvidenceDigest']) && target.turnRef && same(target.turnRef.threadRef, expectedScope.threadRef) && Number.isSafeInteger(target.turnOrdinal) && Number.isSafeInteger(target.providerReportedItemCount) && target.providerReportedItemCount >= 0 && typeof target.observedTurnByteCount === 'string' && /^[0-9]+$/.test(target.observedTurnByteCount) && BigInt(target.observedTurnByteCount) > BigInt(MAX_PROVIDER_TURN_BYTES) && target.maximumTurnByteCount === MAX_PROVIDER_TURN_BYTES && target.problemCode === 'TURN_PAYLOAD_OVERSIZED' && target.repairDisposition === 'UNREPAIRABLE_WITH_CURRENT_PROVIDER_API' && (target.leftTurnBoundary === null || endpointValid(target.leftTurnBoundary, expectedScope)) && (target.rightTurnBoundary === null || endpointValid(target.rightTurnBoundary, expectedScope)) && typeof target.oversizedReadEvidenceId === 'string' && isDigest(target.oversizedReadEvidenceDigest);
    default: return false;
  }
}

function verifyRepairIntent(value, expectedScope, expectedSource) {
  const forbidden = ['materializationId', 'gapId', 'headVersion', 'actor', 'token', 'nonce', 'expiry', 'sourceEpoch', 'host', 'recipient'];
  const keys = ['digestDomain', 'sourcePartition', 'subjectScope', 'readPlanDigest', 'readSpecDigest', 'codexCertificationId', 'codexCertificationDigest', 'target', 'reason', 'repairKind', 'repairDisposition', 'repairIntentDigest'];
  if (!value || !keysExactly(value, keys) || forbidden.some((key) => Object.hasOwn(value, key)) ||
      value.digestDomain !== REPAIR_DOMAIN ||
      !sourceMatches(value.sourcePartition, expectedSource) || !scope(value.subjectScope, expectedSource) || !same(value.subjectScope, expectedScope) ||
      !isDigest(value.readPlanDigest) || !isDigest(value.readSpecDigest) || typeof value.codexCertificationId !== 'string' || !isDigest(value.codexCertificationDigest) ||
      value.codexCertificationDigest !== certificationDigest(value.codexCertificationId) || !verifyRepairTarget(value.target, expectedScope) ||
      !['NOT_LOADED', 'ORDER_UNPROVEN', 'CAPACITY_BOUNDARY', 'READ_FAILED', 'PROVIDER_UNSUPPORTED', 'COVERAGE_UNPROVEN', 'PAYLOAD_UNAVAILABLE', 'TURN_PAYLOAD_OVERSIZED'].includes(value.reason) ||
      !['NEXT_PROVIDER_PAGE', 'FULL_BOUNDED_REREAD', 'LOAD_PAYLOAD', 'NONE'].includes(value.repairKind) ||
      !['REPAIRABLE_WITH_CURRENT_PROVIDER_API', 'UNREPAIRABLE_WITH_CURRENT_PROVIDER_API'].includes(value.repairDisposition)) return reject('timeline.order-gap', 'TIMELINE_ORDER_GAP_INVALID');
  const targetKind = value.target.targetKind;
  const tuple = (() => {
    if (['BEFORE', 'AFTER', 'BETWEEN', 'COVERAGE_UNKNOWN'].includes(targetKind)) {
      if (['ORDER_UNPROVEN', 'READ_FAILED'].includes(value.reason)) return {repairKind: 'FULL_BOUNDED_REREAD', repairDisposition: 'REPAIRABLE_WITH_CURRENT_PROVIDER_API'};
      if (value.reason === 'COVERAGE_UNPROVEN') return {repairKind: 'NEXT_PROVIDER_PAGE', repairDisposition: 'REPAIRABLE_WITH_CURRENT_PROVIDER_API'};
      if (['CAPACITY_BOUNDARY', 'PROVIDER_UNSUPPORTED'].includes(value.reason)) return {repairKind: 'NONE', repairDisposition: 'UNREPAIRABLE_WITH_CURRENT_PROVIDER_API'};
      return null;
    }
    if (targetKind === 'PAYLOAD') {
      if (value.reason === 'PAYLOAD_UNAVAILABLE') return {repairKind: 'LOAD_PAYLOAD', repairDisposition: 'REPAIRABLE_WITH_CURRENT_PROVIDER_API'};
      if (value.reason === 'CAPACITY_BOUNDARY') return {repairKind: 'NONE', repairDisposition: 'UNREPAIRABLE_WITH_CURRENT_PROVIDER_API'};
      return null;
    }
    if (targetKind === 'TURN_PAYLOAD_NOT_LOADED' && value.reason === 'NOT_LOADED') return {repairKind: 'FULL_BOUNDED_REREAD', repairDisposition: 'REPAIRABLE_WITH_CURRENT_PROVIDER_API'};
    if (targetKind === 'TURN_PAYLOAD_OVERSIZED' && value.reason === 'TURN_PAYLOAD_OVERSIZED') return {repairKind: 'NONE', repairDisposition: 'UNREPAIRABLE_WITH_CURRENT_PROVIDER_API'};
    return null;
  })();
  if (!tuple || value.repairKind !== tuple.repairKind || value.repairDisposition !== tuple.repairDisposition) return reject('timeline.order-gap', 'TIMELINE_ORDER_GAP_INVALID');
  const preimage = {...value};
  delete preimage.repairIntentDigest;
  return digestMatches(value.repairIntentDigest, {...preimage, digestDomain: REPAIR_DOMAIN}) ? accept() : reject('timeline.order-gap', 'TIMELINE_ORDER_GAP_INVALID');
}

function verifyGap(gap, expectedScope, expectedSource, previousOrdinal = -1) {
  if (!gap || !keysExactly(gap, ['gapOrdinal', 'target', 'reason', 'repairIntent']) || !Number.isSafeInteger(gap.gapOrdinal) || gap.gapOrdinal !== previousOrdinal + 1 || !verifyRepairTarget(gap.target, expectedScope) || gap.reason !== gap.repairIntent?.reason || !same(gap.target, gap.repairIntent?.target)) return reject('timeline.order-gap', 'TIMELINE_ORDER_GAP_INVALID');
  return verifyRepairIntent(gap.repairIntent, expectedScope, expectedSource);
}

function payloadCommitment(payload, payloadIndex) {
  return jcsDigest({digestDomain: PAYLOAD_COMMITMENT_DOMAIN, payloadIndex, payload});
}

function verifyPayload(payload, payloadIndex) {
  if (!payload || typeof payload !== 'object' || typeof payload.kind !== 'string') return false;
  if (payload.kind === 'unavailable') {
    return keysExactly(payload, ['kind', 'payloadDigest', 'missingField']) && isDigest(payload.payloadDigest) && payload.missingField === 'resolvedPayload';
  }
  if (payload.kind === 'text') return keysExactly(payload, ['kind', 'text']) && typeof payload.text === 'string' && canonicalLength(payload) !== null && canonicalLength(payload) <= MAX_INLINE_TEXT_BYTES;
  if (payload.kind === 'image') return keysExactly(payload, ['kind', 'imageRef']) && payload.imageRef && typeof payload.imageRef === 'object';
  if (payload.kind === 'structured_ref') return keysExactly(payload, ['kind', 'structuredRef']) && payload.structuredRef && typeof payload.structuredRef === 'object';
  if (payload.kind === 'tool_summary') return keysExactly(payload, ['kind', 'toolName', 'summary']) && typeof payload.toolName === 'string' && typeof payload.summary === 'string' && canonicalLength(payload) !== null && canonicalLength(payload) <= MAX_INLINE_TEXT_BYTES;
  return false;
}

function verifyItem(item, expectedScope, previousInTurn, allKeys) {
  if (!item || !keysExactly(item, ['itemRef', 'turnOrdinal', 'itemOrdinal', 'timelineOrdinal', 'predecessorItemRef', 'itemKind', 'payloads', 'providerTypeName']) ||
      !item.itemRef || !item.itemRef.turnRef || !same(item.itemRef.turnRef.threadRef, expectedScope.threadRef) ||
      !Number.isSafeInteger(item.turnOrdinal) || !Number.isSafeInteger(item.timelineOrdinal) || !Number.isSafeInteger(item.itemOrdinal) || item.itemOrdinal < 0 ||
      previousInTurn && item.itemOrdinal !== previousInTurn.itemOrdinal + 1 || previousInTurn && item.timelineOrdinal <= previousInTurn.timelineOrdinal ||
      item.itemOrdinal === 0 && item.predecessorItemRef !== null || item.itemOrdinal > 0 && !same(item.predecessorItemRef, previousInTurn?.itemRef) ||
      item.itemKind === 'UNKNOWN' && (typeof item.providerTypeName !== 'string' || item.providerTypeName.length === 0) || item.itemKind !== 'UNKNOWN' && item.providerTypeName !== null ||
      !denseArray(item.payloads) || item.payloads.length > 64) return false;
  // Array.prototype.some skips holes.  The payload vector is a dense,
  // position-bound commitment list, so inspect every descriptor explicitly.
  for (let payloadIndex = 0; payloadIndex < item.payloads.length; payloadIndex += 1) {
    if (!Object.hasOwn(item.payloads, payloadIndex) || !verifyPayload(item.payloads[payloadIndex], payloadIndex)) return false;
  }
  const itemKey = canonicalize(item.itemRef);
  if (allKeys.has(itemKey)) return false;
  allKeys.add(itemKey);
  return true;
}

function verifyTurnSpine(spine, expectedScope, previousTurn) {
  if (!spine || !keysExactly(spine, ['turnRef', 'turnOrdinal', 'predecessorTurnRef', 'firstTimelineOrdinal', 'lastTimelineOrdinal', 'itemCount']) ||
      !spine.turnRef || !same(spine.turnRef.threadRef, expectedScope.threadRef) || !Number.isSafeInteger(spine.turnOrdinal) ||
      !Number.isSafeInteger(spine.itemCount) || spine.itemCount < 0 || !Number.isSafeInteger(spine.firstTimelineOrdinal ?? 0) && spine.firstTimelineOrdinal !== null ||
      !Number.isSafeInteger(spine.lastTimelineOrdinal ?? 0) && spine.lastTimelineOrdinal !== null ||
      // A null predecessor starts a new provider result island.  Within an
      // island the predecessor must point at the immediately prior Turn;
      // allowing that explicit boundary here keeps the read-result check
      // relational without inventing an island marker in the provider body.
      previousTurn && spine.predecessorTurnRef !== null && (!same(spine.predecessorTurnRef, previousTurn.turnSpine.turnRef) || spine.turnOrdinal !== previousTurn.turnSpine.turnOrdinal + 1) ||
      !previousTurn && spine.predecessorTurnRef !== null) return false;
  return true;
}

function verifySealedProof(proof, outer, expectedScope, positionContext) {
  if (!proof || !outer || !keysExactly(outer, ['digestDomain', 'sourcePartition', 'subject', 'from', 'to', 'readEvidenceId', 'readEvidenceDigest', 'codexCertificationId', 'codexCertificationDigest', 'pageIndex', 'sealedProof', 'proofDigest']) ||
      outer.digestDomain !== 'ccpocket.order-proof.v1' || !sourceMatches(outer.sourcePartition, expectedScope.threadRef.sourcePartition) ||
      !materialized(outer.subject, expectedScope, positionContext.materializationId) || !endpointValid(outer.from, expectedScope) || !endpointValid(outer.to, expectedScope) ||
      !isDigest(outer.readEvidenceDigest) || typeof outer.readEvidenceId !== 'string' || outer.readEvidenceId.length === 0 ||
      typeof outer.codexCertificationId !== 'string' || !isDigest(outer.codexCertificationDigest) || !Number.isSafeInteger(outer.pageIndex) || outer.pageIndex < 0 || outer.pageIndex > 127 ||
      positionContext.readEvidenceId !== undefined && outer.readEvidenceId !== positionContext.readEvidenceId ||
      positionContext.readEvidenceDigest !== undefined && outer.readEvidenceDigest !== positionContext.readEvidenceDigest ||
      positionContext.codexCertificationId !== undefined && outer.codexCertificationId !== positionContext.codexCertificationId ||
      positionContext.codexCertificationDigest !== undefined && outer.codexCertificationDigest !== positionContext.codexCertificationDigest ||
      !digestMatches(outer.proofDigest, (() => { const x = clone(outer); delete x.proofDigest; return x; })())) return false;
  if (proof.proofKind === 'PROVIDER_PAGE_ORDER') {
    if (!keysExactly(proof, ['proofKind', 'fromPosition', 'toPosition']) || !proof.fromPosition || !proof.toPosition ||
        !['TURN', 'ITEM'].includes(proof.fromPosition.positionKind) || proof.fromPosition.positionKind !== proof.toPosition.positionKind ||
        !Number.isSafeInteger(proof.fromPosition.turnIndex) || !Number.isSafeInteger(proof.toPosition.turnIndex)) return false;
    if (proof.fromPosition.positionKind === 'TURN') {
      if (proof.fromPosition.turnIndex < 0 || proof.toPosition.turnIndex < 0 || proof.toPosition.turnIndex !== proof.fromPosition.turnIndex + 1 || outer.from.endpointKind !== 'TURN' || outer.to.endpointKind !== 'TURN') return false;
    } else if (proof.fromPosition.turnIndex < 0 || proof.toPosition.turnIndex < 0 || !Number.isSafeInteger(proof.fromPosition.itemIndex) || !Number.isSafeInteger(proof.toPosition.itemIndex) || proof.fromPosition.itemIndex < 0 || proof.toPosition.itemIndex < 0 || proof.fromPosition.turnIndex !== proof.toPosition.turnIndex || proof.toPosition.itemIndex !== proof.fromPosition.itemIndex + 1 || outer.from.endpointKind !== 'ITEM' || outer.to.endpointKind !== 'ITEM') return false;
    const turns = positionContext.normalizedTurns ?? [];
    const endpointAt = (position) => {
      const turn = turns[position.turnIndex];
      if (!turn) return null;
      if (position.positionKind === 'TURN') return endpointForTurn(turn);
      const item = turn.orderedItems?.[position.itemIndex];
      return item ? endpointForItem(item) : null;
    };
    const fromEndpoint = endpointAt(proof.fromPosition);
    const toEndpoint = endpointAt(proof.toPosition);
    if (!fromEndpoint || !toEndpoint || !same(outer.from, fromEndpoint) || !same(outer.to, toEndpoint)) return false;
    return true;
  }
  if (proof.proofKind === 'CANONICAL_PREDECESSOR') {
    const edge = positionContext.predecessorEdge;
    return keysExactly(proof, ['proofKind', 'baseSubject', 'baseHeadVersion', 'baseManifestDigest']) &&
      edge && keysExactly(edge, ['edgeKind', 'relationMode', 'current', 'base']) &&
      edge.edgeKind === 'PREDECESSOR_REFERENCE' && edge.relationMode === 'REFERENCE_EQUALITY' &&
      keysExactly(edge.current, ['proofDigest', 'sourcePartition', 'subject', 'headVersion', 'manifestDigest']) &&
      keysExactly(edge.base, ['sourcePartition', 'subject', 'headVersion', 'manifestDigest']) &&
      edge.current.proofDigest === outer.proofDigest && materialized(proof.baseSubject, expectedScope) &&
      proof.baseSubject.materializationId !== positionContext.materializationId && Number.isSafeInteger(proof.baseHeadVersion) &&
      proof.baseHeadVersion >= 1 && proof.baseHeadVersion === positionContext.candidateHeadVersion - 1 && isDigest(proof.baseManifestDigest) &&
      same(edge.base.subject, proof.baseSubject) && edge.base.manifestDigest === proof.baseManifestDigest &&
      edge.base.headVersion === proof.baseHeadVersion;
  }
  return false;
}

function verifyPage(page, expectedScope, expectedMaterializationId, expectedPageCount, expectedSource) {
  const required = ['message', 'block', 'sourcePartition', 'subject', 'pageIndex', 'pageCount', 'body', 'pageDigest'];
  const pageFail = (_label) => false;
  if (!page) return pageFail('missing');
  if (!required.every((key) => Object.hasOwn(page, key))) return pageFail('required');
  if (Object.keys(page).some((key) => !required.includes(key) && key !== 'previousPageDigest')) return pageFail('extra');
  if (!sourceMatches(page.sourcePartition, expectedSource)) return pageFail('source');
  if (!same(page.subject, expectedScope)) return pageFail('scope');
  if (!same(page.block.subject, materializationSubject(expectedScope, expectedMaterializationId))) return pageFail('subject');
  if (!Number.isSafeInteger(page.pageIndex) || page.pageIndex < 0 || page.pageIndex >= expectedPageCount || page.pageCount !== expectedPageCount) return pageFail('index');
  if (page.pageCount < 1 || page.pageCount > 128 || page.pageIndex === 0 && Object.hasOwn(page, 'previousPageDigest') || page.pageIndex > 0 && !isDigest(page.previousPageDigest)) return pageFail('chain');
  if (!page.body || !keysExactly(page.body, ['items', 'gaps']) || !denseArray(page.body.items) || !denseArray(page.body.gaps) || page.body.items.length === 0 && page.body.gaps.length === 0) return pageFail('body-shape');
  const bodyBytes = canonicalLength(page.body);
  const pagePayload = {block: page.block, pageIndex: page.pageIndex, pageCount: page.pageCount, ...(page.pageIndex > 0 ? {previousPageDigest: page.previousPageDigest} : {}), pageBody: page.body, pageDigest: page.pageDigest};
  const payloadBytes = canonicalLength(pagePayload);
  const frameBytes = canonicalLength(page);
  if (bodyBytes === null || bodyBytes > MAX_PUBLICATION_PAGE_BYTES || payloadBytes === null || payloadBytes > MAX_CONTROL_PAYLOAD_BYTES || frameBytes === null || frameBytes > MAX_CONTROL_FRAME_BYTES) return pageFail('size-gate');
  if (!digestMatches(page.pageDigest, {digestDomain: PAGE_DOMAIN, sourcePartition: page.sourcePartition, subject: page.block.subject, pageIndex: page.pageIndex, pageCount: page.pageCount, pageBody: page.body})) return pageFail('digest');
  for (const row of page.body.items) {
    if (!row || typeof row.rowKind !== 'string') return pageFail('row-kind');
    if (row.rowKind === 'COVERAGE_ISLAND') {
      if (!keysExactly(row, ['rowKind', 'coverageIsland'])) return pageFail('island-row');
      continue;
    }
    if (row.rowKind === 'TURN_INDEX') {
      if (!keysExactly(row, ['rowKind', 'islandOrdinal', 'turnIndex'])) return pageFail('turn-index-row');
      continue;
    }
    if (row.rowKind === 'TURN_SPINE') {
      if (!keysExactly(row, ['rowKind', 'islandOrdinal', 'turnSpine'])) return pageFail('turn-row');
      continue;
    }
    if (row.rowKind === 'TIMELINE_ITEM') {
      if (!keysExactly(row, ['rowKind', 'islandOrdinal', 'timelineItem'])) return pageFail('item-row');
      continue;
    }
    if (row.rowKind === 'BOUND_ORDER_PROOF') {
      if (!keysExactly(row, ['rowKind', 'islandOrdinal', 'boundOrderProof'])) return pageFail('proof-row');
      continue;
    }
    return pageFail('row-shape');
  }
  return true;
}

function verifyIsland(island, turns, expectedScope) {
  if (!island || !keysExactly(island, ['islandOrdinal', 'startBoundary', 'endBoundary', 'minTurnOrdinal', 'maxTurnOrdinal', 'minTimelineOrdinal', 'maxTimelineOrdinal', 'turnCount', 'indexTurnCount', 'fullTurnCount', 'itemCount']) ||
      !Number.isSafeInteger(island.islandOrdinal) || island.islandOrdinal < 0 || !endpointValid(island.startBoundary, expectedScope) || !endpointValid(island.endBoundary, expectedScope) ||
      !Number.isSafeInteger(island.minTurnOrdinal) || !Number.isSafeInteger(island.maxTurnOrdinal) || island.maxTurnOrdinal < island.minTurnOrdinal ||
      !Number.isSafeInteger(island.turnCount) || island.turnCount < 1 || !Number.isSafeInteger(island.indexTurnCount) || island.indexTurnCount < 0 ||
      !Number.isSafeInteger(island.fullTurnCount) || island.fullTurnCount < 0 || island.indexTurnCount + island.fullTurnCount !== island.turnCount ||
      !Number.isSafeInteger(island.itemCount) || island.itemCount < 0 || island.turnCount !== turns.length) return false;
  if (island.startBoundary.endpointKind !== 'TURN' || island.endBoundary.endpointKind !== 'TURN') return false;
  const nodes = turns.map((turn) => turn.turnIndex ?? turn.turnSpine);
  if (nodes.some((node) => !node) || !same(island.startBoundary, endpointForTurn(nodes[0])) || !same(island.endBoundary, endpointForTurn(nodes.at(-1))) ||
      island.minTurnOrdinal !== nodes[0].turnOrdinal || island.maxTurnOrdinal !== nodes.at(-1).turnOrdinal) return false;
  if (turns.filter((turn) => turn.nodeKind === 'INDEX').length !== island.indexTurnCount || turns.filter((turn) => turn.nodeKind === 'FULL').length !== island.fullTurnCount) return false;
  const items = turns.flatMap((turn) => turn.orderedItems);
  if (island.itemCount !== items.length) return false;
  if (items.length === 0) return island.minTimelineOrdinal === null && island.maxTimelineOrdinal === null;
  return island.minTimelineOrdinal === items[0].timelineOrdinal && island.maxTimelineOrdinal === items.at(-1).timelineOrdinal;
}

function verifyTurnIndex(index, expectedScope, previousTurn) {
  return validTurnIndexShape(index, expectedScope) &&
    (previousTurn ? index.turnOrdinal === previousTurn.turnOrdinal + 1 && same(index.predecessorTurnRef, previousTurn.turnRef) : index.predecessorTurnRef === null);
}

function validTurnIndexShape(index, expectedScope) {
  return index && keysExactly(index, ['turnRef', 'turnOrdinal', 'predecessorTurnRef']) &&
    index.turnRef && same(index.turnRef.threadRef, expectedScope.threadRef) && Number.isSafeInteger(index.turnOrdinal) &&
    (index.predecessorTurnRef === null || index.predecessorTurnRef && same(index.predecessorTurnRef.threadRef, expectedScope.threadRef) && typeof index.predecessorTurnRef.turnId === 'string' && index.predecessorTurnRef.turnId.length > 0);
}

function reduceRows(pages, expectedScope, expectedSource, materializationId, candidateHeadVersion, normalizedTurns = [], proofContext = {}) {
  const rowFail = (_label) => null;
  const rows = pages.flatMap((page) => page.body.items);
  const islands = [];
  const turns = [];
  const items = [];
  const proofs = [];
  const seenIslands = new Set();
  const seenTurns = new Set();
  const seenItems = new Set();
  const seenProofs = new Set();
  const gaps = [];
  const previousTurnsByIsland = new Map();
  const rowPageByObject = new Map();
  for (const page of pages) for (const row of page.body.items) rowPageByObject.set(row, page.pageIndex);
  let currentTurn = null;
  let activeIslandOrdinal = null;
  const previousItemByIsland = new Map();
  for (let index = 0; index < rows.length; index += 1) {
    const row = rows[index];
    if (row.rowKind === 'COVERAGE_ISLAND') {
      const island = row.coverageIsland;
      if (!keysExactly(row, ['rowKind', 'coverageIsland']) || !island || seenIslands.has(island.islandOrdinal) || island.islandOrdinal !== islands.length || activeIslandOrdinal !== null && island.islandOrdinal !== activeIslandOrdinal + 1) return rowFail('island');
      seenIslands.add(island.islandOrdinal);
      islands.push(island);
      // A coverage island is a reducer grouping, not a reset of the global
      // turn spine. The first turn in a later island may (and normally does)
      // name the immediately preceding turn as its predecessor.
      currentTurn = null;
      activeIslandOrdinal = island.islandOrdinal;
      continue;
    }
    if (row.rowKind === 'TURN_INDEX') {
      if (!Number.isSafeInteger(row.islandOrdinal) || row.islandOrdinal !== activeIslandOrdinal || !seenIslands.has(row.islandOrdinal) || !verifyTurnIndex(row.turnIndex, expectedScope, previousTurnsByIsland.get(row.islandOrdinal))) return rowFail('turn-index');
      const key = canonicalize(row.turnIndex.turnRef);
      if (seenTurns.has(key)) return rowFail('duplicate-turn');
      seenTurns.add(key);
      currentTurn = {islandOrdinal: row.islandOrdinal, nodeKind: 'INDEX', turnIndex: row.turnIndex, turnRef: row.turnIndex.turnRef, turnOrdinal: row.turnIndex.turnOrdinal, orderedItems: []};
      turns.push(currentTurn);
      previousTurnsByIsland.set(row.islandOrdinal, currentTurn);
      continue;
    }
    if (row.rowKind === 'TURN_SPINE') {
      if (!Number.isSafeInteger(row.islandOrdinal) || row.islandOrdinal !== activeIslandOrdinal || !seenIslands.has(row.islandOrdinal) || !verifyTurnSpine(row.turnSpine, expectedScope, previousTurnsByIsland.get(row.islandOrdinal))) return rowFail('turn');
      const key = canonicalize(row.turnSpine.turnRef);
      if (seenTurns.has(key)) return rowFail('duplicate-turn');
      seenTurns.add(key);
      currentTurn = {islandOrdinal: row.islandOrdinal, nodeKind: 'FULL', turnSpine: row.turnSpine, turnRef: row.turnSpine.turnRef, turnOrdinal: row.turnSpine.turnOrdinal, orderedItems: []};
      turns.push(currentTurn);
      previousTurnsByIsland.set(row.islandOrdinal, currentTurn);
      continue;
    }
    if (row.rowKind === 'TIMELINE_ITEM') {
      const previousItem = previousItemByIsland.get(row.islandOrdinal);
      if (!currentTurn || currentTurn.nodeKind !== 'FULL' || row.islandOrdinal !== activeIslandOrdinal || row.islandOrdinal !== currentTurn.islandOrdinal || !verifyItem(row.timelineItem, expectedScope, currentTurn.orderedItems.at(-1), seenItems) || row.timelineItem.turnOrdinal !== currentTurn.turnOrdinal || previousItem && row.timelineItem.timelineOrdinal !== previousItem.timelineOrdinal + 1) return rowFail('item');
      currentTurn.orderedItems.push(row.timelineItem);
      items.push(row.timelineItem);
      previousItemByIsland.set(row.islandOrdinal, row.timelineItem);
      continue;
    }
    if (row.rowKind === 'BOUND_ORDER_PROOF') {
      const proof = row.boundOrderProof;
      if (!currentTurn || row.islandOrdinal !== activeIslandOrdinal || row.islandOrdinal !== currentTurn.islandOrdinal || !proof || seenProofs.has(proof.proofDigest)) return rowFail('proof-shape');
      const previousRow = rows[index - 1];
      if (!previousRow || !['TURN_SPINE', 'TURN_INDEX', 'TIMELINE_ITEM'].includes(previousRow.rowKind)) return rowFail('proof-adjacent');
      if (!verifySealedProof(proof.sealedProof, proof, expectedScope, {materializationId, candidateHeadVersion, normalizedTurns, ...proofContext})) return rowFail('proof-sealed');
      // A TURN_SPINE proof is placed immediately after its to-node. Its
      // from-node is therefore the prior global turn, not the immediately
      // preceding row (which is the current turn spine). Item proofs retain
      // the analogous prior-item adjacency.
      const priorTurn = turns.filter((candidate) => candidate.islandOrdinal === currentTurn.islandOrdinal).at(-2) ?? null;
      let expectedFrom;
      let expectedTo;
      if (['TURN_SPINE', 'TURN_INDEX'].includes(previousRow.rowKind)) {
        expectedFrom = priorTurn ? endpointForTurn(priorTurn) : null;
        expectedTo = previousRow.rowKind === 'TURN_SPINE' ? endpointForTurn(currentTurn.turnSpine) : endpointForTurn(currentTurn.turnIndex);
      } else {
        // The proof row follows its `to` Item.  Its source is therefore the
        // immediately preceding Item in the same Turn, not the preceding
        // staged row (which is the `to` Item itself).  Requiring both dense
        // coordinates here prevents a cross-Turn or reverse item edge from
        // passing merely because its refs happen to be well-shaped.
        const toItem = currentTurn.orderedItems.at(-1);
        const fromItem = currentTurn.orderedItems.at(-2);
        if (!fromItem || !toItem || !same(fromItem.itemRef.turnRef, toItem.itemRef.turnRef) ||
            fromItem.turnOrdinal !== toItem.turnOrdinal ||
            toItem.itemOrdinal !== fromItem.itemOrdinal + 1 ||
            toItem.timelineOrdinal !== fromItem.timelineOrdinal + 1) return rowFail('item-proof-coordinate');
        expectedFrom = endpointForItem(fromItem);
        expectedTo = endpointForItem(toItem);
      }
      // A provider-page proof's outer endpoints are the reducer nodes, not a
      // kind-only assertion. The current row must be the proof's to-node.
      if (!same(proof.from, expectedFrom) || !same(proof.to, expectedTo) || proof.pageIndex !== pages.findIndex((page) => page.body.items.includes(row))) return rowFail('proof-binding');
      seenProofs.add(proof.proofDigest);
      proofs.push(proof);
      continue;
    }
    return rowFail('unknown');
  }
  if (islands.some((island, index) => island.islandOrdinal !== index)) return rowFail('island-order');
  for (const page of pages) {
    for (const gap of page.body.gaps) {
      const checked = verifyGap(gap, expectedScope, expectedSource, gaps.length - 1);
      if (!checked.valid) return rowFail('gap');
      const target = gap.target;
      const pageForTurn = (turnRef) => {
        const row = rows.find((candidate) => ['TURN_INDEX', 'TURN_SPINE'].includes(candidate.rowKind) && same((candidate.turnIndex ?? candidate.turnSpine).turnRef, turnRef));
        return row ? rowPageByObject.get(row) : null;
      };
      const pageForBoundary = (boundaryValue) => pageForTurn(boundaryValue?.turnRef ?? boundaryValue?.itemRef?.turnRef);
      const expectedPage = target.targetKind === 'COVERAGE_UNKNOWN' ? 0 : target.targetKind === 'PAYLOAD'
        ? (() => {
          const row = rows.find((candidate) => candidate.rowKind === 'TIMELINE_ITEM' && same(candidate.timelineItem.itemRef, target.itemRef));
          return row ? rowPageByObject.get(row) : null;
        })()
        : target.targetKind === 'TURN_PAYLOAD_NOT_LOADED' || target.targetKind === 'TURN_PAYLOAD_OVERSIZED' ? pageForTurn(target.turnRef)
          : target.targetKind === 'BEFORE' ? pageForBoundary(target.rightBoundary)
            : target.targetKind === 'AFTER' ? pageForBoundary(target.leftBoundary)
              : target.targetKind === 'BETWEEN' ? pageForBoundary(target.rightBoundary) : null;
      if (expectedPage === null || expectedPage !== page.pageIndex || target.targetKind === 'BETWEEN' && pageForBoundary(target.leftBoundary) > page.pageIndex) return rowFail('gap-anchor-page');
      gaps.push(gap);
    }
  }
  for (const island of islands) {
    const islandTurns = turns.filter((turn) => turn.islandOrdinal === island.islandOrdinal);
    if (!verifyIsland(island, islandTurns, expectedScope)) return rowFail(`island-${island.islandOrdinal}`);
    for (const turn of islandTurns) {
      if (turn.nodeKind === 'INDEX') {
        if (turn.orderedItems.length !== 0) return rowFail(`index-items-${turn.turnRef.turnId}`);
      } else if (turn.turnSpine.itemCount !== turn.orderedItems.length || turn.orderedItems.length === 0 && (turn.turnSpine.firstTimelineOrdinal !== null || turn.turnSpine.lastTimelineOrdinal !== null) || turn.orderedItems.length > 0 && (turn.turnSpine.firstTimelineOrdinal !== turn.orderedItems[0].timelineOrdinal || turn.turnSpine.lastTimelineOrdinal !== turn.orderedItems.at(-1).timelineOrdinal)) return rowFail(`turn-items-${turn.turnSpine.turnRef.turnId}`);
    }
  }
  const nonEmptyTurnCount = turns.filter((turn) => turn.nodeKind === 'FULL' && turn.orderedItems.length > 0).length;
  const expectedProofCount = turns.length - islands.length + items.length - nonEmptyTurnCount;
  if (proofs.length !== expectedProofCount) return rowFail('proof-cardinality');
  return {rows, islands, turns, items, proofs, gaps};
}

function stagedCapacity(pages, reduction) {
  const pageRows = pages.map((page) => ({capacityRowKind: 'PAGE', sourcePartition: page.sourcePartition, subject: page.block.subject, pageIndex: page.pageIndex, pageCount: page.pageCount, previousPageDigest: page.previousPageDigest ?? null, pageDigest: page.pageDigest}));
  const logicalRows = pages.flatMap((page) => page.body.items.map((item) => ({capacityRowKind: 'LOGICAL_ROW', pageIndex: page.pageIndex, item})));
  const gapRows = pages.flatMap((page) => page.body.gaps.map((gap) => ({capacityRowKind: 'GAP', pageIndex: page.pageIndex, gap})));
  const all = [...pageRows, ...logicalRows, ...gapRows];
  return {stagedRowCount: all.length, stagedByteCount: all.reduce((sum, row) => sum + BigInt(canonicalUtf8(row).byteLength), 0n).toString()};
}

function verifyIndexGapBijection(reduction) {
  const turnGaps = reduction.gaps.filter((gap) => ['TURN_PAYLOAD_NOT_LOADED', 'TURN_PAYLOAD_OVERSIZED'].includes(gap.target?.targetKind));
  const indexes = reduction.turns.filter((turn) => turn.nodeKind === 'INDEX');
  const fullTurns = reduction.turns.filter((turn) => turn.nodeKind === 'FULL');
  const key = (turnRef) => {
    try { return canonicalize(turnRef); } catch { return null; }
  };
  const indexKeys = new Set(indexes.map((turn) => key(turn.turnRef)));
  if (indexKeys.size !== indexes.length) return false;
  if (fullTurns.some((turn) => turnGaps.some((gap) => key(gap.target.turnRef) === key(turn.turnRef)))) return false;
  if (indexes.some((turn) => turnGaps.filter((gap) => key(gap.target.turnRef) === key(turn.turnRef) && gap.target.turnOrdinal === turn.turnOrdinal).length !== 1)) return false;
  if (turnGaps.some((gap) => !indexKeys.has(key(gap.target.turnRef)) || indexes.filter((turn) => key(turn.turnRef) === key(gap.target.turnRef) && turn.turnOrdinal === gap.target.turnOrdinal).length !== 1)) return false;
  return true;
}

function verifyCoverage(value, reduction, expectedScope, expectedSource, materializationId, expectedCoverageDigest, resolvedAuthority = null) {
  const structural = value.structuralCoverage;
  const payload = value.payloadCoverage;
  const gaps = reduction.gaps;
  if (!['COMPLETE', 'PARTIAL', 'EMPTY_PROVEN'].includes(structural) || !['COMPLETE', 'PARTIAL'].includes(payload) || gaps.some((gap, index) => gap.gapOrdinal !== index)) return false;
  const structuralKinds = new Set(['BEFORE', 'AFTER', 'BETWEEN', 'COVERAGE_UNKNOWN']);
  const structuralGaps = gaps.filter((gap) => structuralKinds.has(gap.target.targetKind));
  const payloadGaps = gaps.filter((gap) => !structuralKinds.has(gap.target.targetKind));
  if (structural === 'EMPTY_PROVEN') {
    if (reduction.items.length !== 0 || reduction.turns.length !== 0 || reduction.islands.length !== 0 || gaps.length !== 0 || payload !== 'COMPLETE' || !value.emptyProof) return false;
  } else if (structural === 'COMPLETE' && (structuralGaps.length !== 0 || reduction.islands.length !== 1) || structural === 'PARTIAL' && structuralGaps.length === 0 || payload === 'COMPLETE' && payloadGaps.length !== 0 || payload === 'PARTIAL' && payloadGaps.length === 0) return false;
  if (structural !== 'EMPTY_PROVEN') {
    if (structuralGaps.filter((gap) => gap.target.targetKind === 'BEFORE').length > 1 || structuralGaps.filter((gap) => gap.target.targetKind === 'AFTER').length > 1 || structuralGaps.filter((gap) => gap.target.targetKind === 'COVERAGE_UNKNOWN').length > 1) return false;
    if (structuralGaps.some((gap) => gap.target.targetKind === 'COVERAGE_UNKNOWN') && reduction.islands.length !== 0) return false;
    for (let index = 0; index + 1 < reduction.islands.length; index += 1) {
      const left = reduction.islands[index];
      const right = reduction.islands[index + 1];
      if (structuralGaps.filter((gap) => gap.target.targetKind === 'BETWEEN' && same(gap.target.leftBoundary, left.endBoundary) && same(gap.target.rightBoundary, right.startBoundary)).length !== 1) return false;
    }
    if (structuralGaps.filter((gap) => gap.target.targetKind === 'BETWEEN').some((gap) => !reduction.islands.some((island, index) => {
      const next = reduction.islands[index + 1];
      return next && same(gap.target.leftBoundary, island.endBoundary) && same(gap.target.rightBoundary, next.startBoundary);
    }))) return false;
    for (const gap of structuralGaps) {
      if (gap.target.targetKind === 'BEFORE' && (!reduction.islands[0] || !same(gap.target.rightBoundary, reduction.islands[0].startBoundary))) return false;
      if (gap.target.targetKind === 'AFTER' && (!reduction.islands.at(-1) || !same(gap.target.leftBoundary, reduction.islands.at(-1).endBoundary))) return false;
      if (gap.target.targetKind === 'BETWEEN') {
        const bridged = reduction.islands.some((island, index) => {
          const next = reduction.islands[index + 1];
          return next && same(gap.target.leftBoundary, island.endBoundary) && same(gap.target.rightBoundary, next.startBoundary);
        });
        if (!bridged) return false;
      }
    }
    for (const gap of payloadGaps) {
      if (gap.target.targetKind === 'TURN_PAYLOAD_NOT_LOADED') continue;
      if (gap.target.targetKind === 'TURN_PAYLOAD_OVERSIZED') {
        const oversized = resolvedAuthority?.result?.oversizedTurn;
        const indexTurn = reduction.turns.find((turn) => turn.nodeKind === 'INDEX' && same(turn.turnRef, gap.target.turnRef) && turn.turnOrdinal === gap.target.turnOrdinal);
        const islandTurns = indexTurn ? reduction.turns.filter((turn) => turn.islandOrdinal === indexTurn.islandOrdinal) : [];
        const turnPosition = indexTurn ? islandTurns.findIndex((turn) => same(turn.turnRef, indexTurn.turnRef)) : -1;
        const expectedLeft = turnPosition > 0 ? endpointForTurn(islandTurns[turnPosition - 1].turnIndex) : null;
        const expectedRight = turnPosition >= 0 && turnPosition + 1 < islandTurns.length ? endpointForTurn(islandTurns[turnPosition + 1].turnIndex) : null;
        if (!oversized || !indexTurn || !same(oversized.turnIndex, {turnRef: indexTurn.turnRef, turnOrdinal: indexTurn.turnOrdinal, predecessorTurnRef: indexTurn.turnIndex.predecessorTurnRef}) ||
            gap.target.oversizedReadEvidenceId !== resolvedAuthority.evidence.readEvidenceId || gap.target.oversizedReadEvidenceDigest !== resolvedAuthority.evidence.readEvidenceDigest ||
            gap.target.providerReportedItemCount !== oversized.providerReportedItemCount || gap.target.observedTurnByteCount !== oversized.observedTurnByteCount ||
            !same(gap.target.leftTurnBoundary, expectedLeft) || !same(gap.target.rightTurnBoundary, expectedRight)) return false;
        continue;
      }
      const item = reduction.items.find((candidate) => same(candidate.itemRef, gap.target.itemRef));
      if (!item || gap.target.missingPayloadFields.length === 0) return false;
      const expectedMissing = item.payloads.flatMap((candidate, payloadIndex) => candidate.kind === 'unavailable' ? [{payloadIndex, payloadKind: 'unavailable', fieldName: 'resolvedPayload'}] : []);
      if (!same(expectedMissing, gap.target.missingPayloadFields)) return false;
    }
    const unavailableCount = reduction.items.reduce((count, item) => count + item.payloads.filter((payload) => payload.kind === 'unavailable').length, 0);
    const itemPayloadGapCount = payloadGaps.filter((gap) => gap.target.targetKind === 'PAYLOAD').reduce((count, gap) => count + gap.target.missingPayloadFields.length, 0);
    if (unavailableCount !== itemPayloadGapCount || !verifyIndexGapBijection(reduction)) return false;
  }
  let digest;
  try {
    digest = deriveCoverageDigest({sourcePartition: expectedSource, subject: materializationSubject(expectedScope, materializationId), structuralCoverage: structural, payloadCoverage: payload, orderedIslands: reduction.islands.map((island, index) => coverageOrderedIsland(index, island)), gaps, coverageKind: structural === 'EMPTY_PROVEN' ? 'EMPTY' : 'NON_EMPTY', emptyProof: value.emptyProof});
  } catch {
    return false;
  }
  return digest === expectedCoverageDigest;
}

function verifyMaterialization(value, {predecessorEdge} = {}) {
  const oracle = 'timeline.materialization';
  const failAt = (_label, reason = 'TIMELINE_ORDER_GAP_INVALID') => reject(oracle, reason);
  if (!value || !value.beginFrame || !value.beginFrame.begin || !value.beginFrame.begin.payload || !value.beginFrame.begin.preimage || !value.beginFrame.block || !value.commit || !denseArray(value.pages)) return failAt('root');
  const beginFrame = value.beginFrame;
  const commit = value.commit;
  const block = beginFrame.block;
  const materializedSubject = block.subject;
  const expectedSource = beginFrame.sourcePartition;
  const expectedScope = beginFrame.subject;
  const materializationId = materializedSubject?.materializationId;
  const pageCount = commit.pageCount;
  const commitSeq = pageCount + 2;
  const messageKeys = ['sourcePartition', 'subscriptionId', 'streamId', 'messageId', 'baseSeq', 'streamSeq', 'commitSeq', 'checkpointSequence', 'blockRole'];
  const blockKeys = ['blockId', 'subject', 'receiptId', 'manifestDigest', 'beginHeaderDigest'];
  const frameKeys = ['message', 'block', 'sourcePartition', 'subject', 'begin', 'pageCount', 'totalItemCount'];
  const commitKeys = ['message', 'block', 'sourcePartition', 'subject', 'baseHeadVersion', 'candidateHeadVersion', 'pageCount', 'domain', 'turnCount', 'itemCount', 'islandCount', 'gapCount', 'structuralCoverage', 'payloadCoverage', 'orderDigest', 'coverageDigest', 'receiptDigest', 'stagedRowCount', 'stagedByteCount', 'lastGoodDisposition'];
  if (!keysExactly(beginFrame, frameKeys) || !keysAtMost(commit, commitKeys, ['finalPageDigest']) || !keysExactly(block, blockKeys) ||
      !keysExactly(beginFrame.begin, ['preimage', 'payload', 'beginHeaderDigest']) || !keysExactly(beginFrame.message, messageKeys) || !keysExactly(commit.message, messageKeys) ||
      !scope(expectedScope, expectedSource) || !materialized(materializedSubject, expectedScope, materializationId) || !Number.isSafeInteger(pageCount) || pageCount < 0 || pageCount > 128 ||
      pageCount === 0 && value.pages.length !== 0 || pageCount > 0 && value.pages.length !== pageCount || !same(block.subject, materializedSubject) || !same(commit.block, block) || !sourceMatches(commit.sourcePartition, expectedSource) || !same(commit.subject, materializedSubject) ||
      beginFrame.pageCount !== pageCount || beginFrame.message?.blockRole !== 'BEGIN' || commit.message?.blockRole !== 'COMMIT' || commit.message?.streamSeq !== commitSeq || beginFrame.message?.streamSeq !== 1 || commit.message?.checkpointSequence !== commitSeq ||
      !Number.isSafeInteger(commit.baseHeadVersion) || commit.baseHeadVersion < 0 || !Number.isSafeInteger(commit.candidateHeadVersion) || commit.candidateHeadVersion !== commit.baseHeadVersion + 1) return failAt('identity');
  const disposition = commit.lastGoodDisposition;
  const validDisposition = commit.baseHeadVersion === 0
    ? disposition && keysExactly(disposition, ['disposition']) && disposition.disposition === 'NO_PREVIOUS_HEAD'
    : disposition && keysExactly(disposition, ['disposition', 'previousSubject', 'previousHeadVersion']) && disposition.disposition === 'PREVIOUS_HEAD_RETAINED' &&
      materialized(disposition.previousSubject, expectedScope) && disposition.previousSubject.materializationId !== materializationId &&
      Number.isSafeInteger(disposition.previousHeadVersion) && disposition.previousHeadVersion === commit.baseHeadVersion;
  if (!validDisposition) return failAt('last-good-disposition');
  const preimage = beginFrame.begin.preimage;
  const payload = beginFrame.begin.payload;
  const expectedPreimageKeys = ['digestDomain', 'eventKey', 'payload'];
  if (!keysExactly(preimage, expectedPreimageKeys) || preimage.digestDomain !== BEGIN_DOMAIN || !keysExactly(payload, ['block', 'baseHeadVersion', 'candidateHeadVersion', 'expectedCoverageDigest', 'readPlanDigest', 'readSpecDigest', 'readEvidenceId', 'readEvidenceDigest', 'codexCertificationId', 'codexCertificationDigest', 'readBody', 'pageCount', 'structuralCoverage', 'payloadCoverage']) && !keysExactly(payload, ['block', 'baseHeadVersion', 'candidateHeadVersion', 'expectedCoverageDigest', 'readPlanDigest', 'readSpecDigest', 'readEvidenceId', 'readEvidenceDigest', 'codexCertificationId', 'codexCertificationDigest', 'readBody', 'pageCount', 'structuralCoverage', 'payloadCoverage', 'emptyProof'])) return failAt('preimage-shape');
  const preimageBlock = {...block}; delete preimageBlock.beginHeaderDigest;
  if (!same(preimage.payload.block, preimageBlock) || !same(beginFrame.begin.payload.block, block) || !same(beginFrame.begin.beginHeaderDigest, block.beginHeaderDigest) ||
      !same(preimage.eventKey, {sourcePartition: expectedSource, ownerKind: 'CanonicalTimelineWriter', aggregateRef: {kind: 'MATERIALIZATION', subject: materializedSubject}, eventId: preimage.eventKey?.eventId}) ||
      !Number.isSafeInteger(payload.baseHeadVersion) || payload.baseHeadVersion !== commit.baseHeadVersion || payload.candidateHeadVersion !== commit.candidateHeadVersion || payload.pageCount !== pageCount ||
      payload.expectedCoverageDigest !== commit.coverageDigest || !isDigest(payload.readSpecDigest) || !isDigest(payload.readEvidenceDigest) ||
      !isDigest(payload.codexCertificationDigest) || payload.codexCertificationId !== undefined && typeof payload.codexCertificationId !== 'string' ||
      deriveBeginHeaderDigest(preimage) !== beginFrame.begin.beginHeaderDigest || deriveBeginHeaderDigest(preimage) !== block.beginHeaderDigest) return failAt('preimage-values');
  const pages = value.pages;
  const messages = [beginFrame.message, ...pages.map((page) => page.message), commit.message];
  const messageIds = new Set();
  if (messages.some((message, index) =>
    !sourceMatches(message.sourcePartition, expectedSource) ||
    message.subscriptionId !== beginFrame.message.subscriptionId ||
    message.streamId !== beginFrame.message.streamId ||
    typeof message.subscriptionId !== 'string' || message.subscriptionId.length === 0 ||
    typeof message.streamId !== 'string' || message.streamId.length === 0 ||
    typeof message.messageId !== 'string' || message.messageId.length === 0 || messageIds.has(message.messageId) ||
    message.blockRole !== (index === 0 ? 'BEGIN' : index === messages.length - 1 ? 'COMMIT' : 'PAGE') ||
    message.streamSeq !== index + 1 || message.baseSeq !== message.streamSeq - 1 ||
    message.commitSeq !== commitSeq || message.checkpointSequence !== (index === messages.length - 1 ? commitSeq : 0))) {
    return failAt('message-identity');
  }
  for (const message of messages) messageIds.add(message.messageId);
  for (let index = 0; index < pages.length; index += 1) {
    const page = pages[index];
    if (!same(page.block, block) || !sourceMatches(page.sourcePartition, expectedSource) || !same(page.subject, expectedScope) || page.pageIndex !== index || page.pageCount !== pageCount || index > 0 && page.previousPageDigest !== pages[index - 1].pageDigest || !verifyPage(page, expectedScope, materializationId, pageCount, expectedSource)) return failAt(`page-${index}`);
  }
  const independentAuthority = verifyIndependentMaterializationAuthority(value.authority, expectedSource, expectedScope);
  // A materialization is admissible only after the complete plan/spec/result/
  // evidence/certification bundle has resolved independently of staged rows.
  // In particular, page rows are provenance to that result, never a source
  // from which the result or authority can be reconstructed.
  if (!independentAuthority) return failAt('independent-authority');
  const independentResult = independentAuthority.result;
  if (independentAuthority && (
      payload.readPlanDigest !== independentAuthority.plan.readPlanDigest ||
      payload.readSpecDigest !== independentAuthority.spec.readSpecDigest ||
      payload.readEvidenceId !== independentAuthority.evidence.readEvidenceId ||
      payload.readEvidenceDigest !== independentAuthority.evidence.readEvidenceDigest ||
      payload.codexCertificationId !== independentAuthority.certification.codexCertificationId ||
      payload.codexCertificationDigest !== independentAuthority.certification.codexCertificationDigest ||
      !same(payload.readBody, independentAuthority.evidence.readBody))) return failAt('authority-binding');
  const normalizedRows = pageCount === 0 ? [] : resultTurns(independentResult);
  const rowReduction = pageCount === 0 ? {rows: [], islands: [], turns: [], items: [], proofs: [], gaps: []} : reduceRows(pages, expectedScope, expectedSource, materializationId, commit.candidateHeadVersion, normalizedRows, {
    readEvidenceId: payload.readEvidenceId,
    readEvidenceDigest: payload.readEvidenceDigest,
    codexCertificationId: payload.codexCertificationId,
    codexCertificationDigest: payload.codexCertificationDigest,
    predecessorEdge,
  });
  if (!rowReduction) return failAt('rows');
  const resultKind = payload.readBody.resultKind;
  if (independentResult && !rowsExhaustivelyMatchResult(rowReduction, independentResult)) return failAt('result-provenance');
  if (independentResult.resultKind !== resultKind || independentResult.resultCount !== payload.readBody.resultCount ||
      independentResult.returnedCursor !== payload.readBody.returnedCursor || independentResult.readPlanDigest !== payload.readPlanDigest ||
      independentResult.readSpecDigest !== payload.readSpecDigest || payload.readBody.resultDigest !== jcsDigest(independentResult)) return failAt('result');
  if (pageCount === 0) {
    if (payload.structuralCoverage !== 'EMPTY_PROVEN' || payload.payloadCoverage !== 'COMPLETE' || !payload.emptyProof || !same(payload.emptyProof, value.commit.emptyProof ?? payload.emptyProof)) return reject(oracle, 'TIMELINE_EMPTY_PROOF_INVALID');
    if (!keysExactly(payload.emptyProof, ['proofKind', 'sourcePartition', 'subjectScope', 'readPlanDigest', 'readSpecDigest', 'readEvidenceId', 'readEvidenceDigest', 'codexCertificationId', 'codexCertificationDigest']) || payload.emptyProof.proofKind !== 'FULL_SCOPE_PROVIDER_EMPTY' || !same(payload.emptyProof.sourcePartition, expectedSource) || !same(payload.emptyProof.subjectScope, expectedScope) || payload.emptyProof.readPlanDigest !== payload.readPlanDigest || payload.emptyProof.readSpecDigest !== payload.readSpecDigest || payload.emptyProof.readEvidenceId !== payload.readEvidenceId || payload.emptyProof.readEvidenceDigest !== payload.readEvidenceDigest || payload.readBody.resultCount !== 0 || payload.readBody.returnedCursor !== null) return reject(oracle, 'TIMELINE_EMPTY_PROOF_INVALID');
  }
  if (!verifyCoverage({structuralCoverage: payload.structuralCoverage, payloadCoverage: payload.payloadCoverage, emptyProof: payload.emptyProof}, rowReduction, expectedScope, expectedSource, materializationId, commit.coverageDigest, independentAuthority)) return failAt('coverage');
  const orderIslands = rowReduction.islands.map((island, index) => {
    const islandTurns = rowReduction.turns.filter((turn) => turn.islandOrdinal === index);
    return {islandOrdinal: index, island, orderedTurns: islandTurns.map((turn, turnIndex) => ({orderPosition: turnIndex === 0 ? 'FIRST' : 'SUCCESSOR', turnNode: turn.nodeKind === 'INDEX' ? {turnNodeKind: 'INDEX', turnIndex: turn.turnIndex} : {turnNodeKind: 'FULL', turnSpine: turn.turnSpine}, ...(turnIndex === 0 ? {} : {incomingProofDigest: rowReduction.proofs.find((proof) => same(proof.to, endpointForTurn(turn)))?.proofDigest}), orderedItems: turn.orderedItems.map((item, itemIndex) => ({orderPosition: itemIndex === 0 ? 'FIRST' : 'SUCCESSOR', item, ...(itemIndex === 0 ? {} : {incomingProofDigest: rowReduction.proofs.find((proof) => same(proof.to, endpointForItem(item)))?.proofDigest})}))}))};
  });
  const orderDigest = deriveOrderDigest({sourcePartition: expectedSource, subject: materializedSubject, orderedIslands: orderIslands});
  const capacity = pageCount === 0 ? {stagedRowCount: 0, stagedByteCount: '0'} : stagedCapacity(pages, rowReduction);
  const manifestDigest = deriveManifestDigest({sourcePartition: expectedSource, subject: materializedSubject, algorithmVersion: 1, baseHeadVersion: commit.baseHeadVersion, candidateHeadVersion: commit.candidateHeadVersion, pageCount, orderedPageDigests: pages.map((page) => ({pageIndex: page.pageIndex, pageDigest: page.pageDigest})), totalItemCount: rowReduction.items.length, totalTurnCount: rowReduction.turns.length, totalGapCount: rowReduction.gaps.length, islandCount: rowReduction.islands.length, orderDigest, coverageDigest: commit.coverageDigest});
  const derivedCommitMatches = commit.orderDigest === orderDigest && block.manifestDigest === manifestDigest && commit.stagedRowCount === capacity.stagedRowCount && commit.stagedByteCount === capacity.stagedByteCount && (pageCount === 0 ? !Object.hasOwn(commit, 'finalPageDigest') : commit.finalPageDigest === pages.at(-1).pageDigest) && commit.itemCount === rowReduction.items.length && commit.turnCount === rowReduction.turns.length && commit.gapCount === rowReduction.gaps.length && commit.islandCount === rowReduction.islands.length && commit.structuralCoverage === payload.structuralCoverage && commit.payloadCoverage === payload.payloadCoverage;
  if (!derivedCommitMatches) return failAt('commit-derived');
  const receiptDigest = deriveReceiptDigest({receiptId: block.receiptId, sourcePartition: expectedSource, subject: materializedSubject, beginHeaderDigest: block.beginHeaderDigest, manifestDigest, orderDigest, coverageDigest: commit.coverageDigest, baseHeadVersion: commit.baseHeadVersion, candidateHeadVersion: commit.candidateHeadVersion, readPlanDigest: payload.readPlanDigest, readSpecDigest: payload.readSpecDigest, readEvidenceId: payload.readEvidenceId, readEvidenceDigest: payload.readEvidenceDigest, certificationId: payload.codexCertificationId, certificationDigest: payload.codexCertificationDigest, pageCount, totalItemCount: rowReduction.items.length, totalTurnCount: rowReduction.turns.length, totalGapCount: rowReduction.gaps.length, islandCount: rowReduction.islands.length, stagedRowCount: capacity.stagedRowCount, stagedByteCount: capacity.stagedByteCount});
  return commit.receiptDigest === receiptDigest ? accept() : failAt('receipt');
}

function comparisonProjection(snapshot) {
  const result = verifyMaterialization(snapshot);
  if (!result.valid) return null;
  const resolvedAuthority = verifyIndependentMaterializationAuthority(snapshot.authority, snapshot.beginFrame.sourcePartition, snapshot.beginFrame.subject);
  if (!resolvedAuthority) return null;
  const frame = snapshot.beginFrame;
  const payload = frame.begin.payload;
  const resolvedResult = resolvedAuthority.result;
  const reduction = snapshot.pages.length === 0 ? {islands: [], turns: [], items: [], proofs: [], gaps: []} : reduceRows(snapshot.pages, frame.subject, frame.sourcePartition, frame.block.subject.materializationId, snapshot.commit.candidateHeadVersion, resultTurns(resolvedResult), {
    readEvidenceId: payload.readEvidenceId,
    readEvidenceDigest: payload.readEvidenceDigest,
    codexCertificationId: payload.codexCertificationId,
    codexCertificationDigest: payload.codexCertificationDigest,
  });
  if (!reduction) return null;
  const stableProjection = (value) => {
    const excluded = new Set(['materializationId', 'blockId', 'receiptId', 'messageId', 'readEvidenceId', 'readEvidenceDigest', 'readSpecDigest', 'codexCertificationId', 'codexCertificationDigest', 'repairIntentDigest', 'proofDigest', 'baseManifestDigest', 'pageIndex', 'gapOrdinal']);
    if (Array.isArray(value)) return value.map(stableProjection);
    if (!value || typeof value !== 'object') return value;
    return Object.fromEntries(Object.entries(value).filter(([key]) => !excluded.has(key)).map(([key, entry]) => [key, stableProjection(entry)]));
  };
  const turnComparisonFact = (turn) => {
    const node = turn.nodeKind === 'INDEX' ? turn.turnIndex : turn.turnSpine;
    if (turn.nodeKind === 'INDEX') {
      return {
        turnFactKind: 'INDEX',
        turnRef: node.turnRef,
        turnOrdinal: node.turnOrdinal,
        semanticFieldPresence: ['turnRef', 'turnOrdinal'],
      };
    }
    return {
      turnFactKind: 'FULL',
      turnRef: node.turnRef,
      turnOrdinal: node.turnOrdinal,
      firstTimelineOrdinal: node.firstTimelineOrdinal,
      lastTimelineOrdinal: node.lastTimelineOrdinal,
      itemCount: node.itemCount,
      semanticFieldPresence: ['turnRef', 'turnOrdinal', 'firstTimelineOrdinal', 'lastTimelineOrdinal', 'itemCount'],
    };
  };
  const stableKey = {sourcePartition: frame.sourcePartition, subjectScope: frame.subject, readPlanDigest: payload.readPlanDigest};
  if (payload.structuralCoverage === 'EMPTY_PROVEN') {
    return {
      projectionKind: 'EMPTY_PROVEN',
      stableKey,
      structuralCoverage: 'EMPTY_PROVEN',
      payloadCoverage: 'COMPLETE',
    };
  }
  const orderedItems = reduction.items.map((item) => {
    const {payloads: _payloads, ...itemCore} = item;
    return {
      ...stableProjection(itemCore),
      semanticFieldPresence: ['itemRef', 'turnOrdinal', 'itemOrdinal', 'timelineOrdinal', 'predecessorItemRef', 'itemKind', 'providerTypeName'],
    };
  });
  const orderedPayloadFacts = reduction.items.map((item) => ({
    itemRef: item.itemRef,
    orderedPayloadCommitments: item.payloads.map((payload, payloadIndex) => ({
      payloadIndex,
      payloadDigest: payload.kind === 'unavailable' ? payload.payloadDigest : payloadCommitment(payload, payloadIndex),
    })),
    orderedObservedFields: item.payloads.flatMap((payload, payloadIndex) => {
      if (payload.kind === 'text') return [{payloadIndex, payloadKind: 'text', fieldName: 'text', value: payload.text}];
      if (payload.kind === 'image') return [{payloadIndex, payloadKind: 'image', fieldName: 'imageRef', value: payload.imageRef}];
      if (payload.kind === 'structured_ref') return [{payloadIndex, payloadKind: 'structured_ref', fieldName: 'structuredRef', value: payload.structuredRef}];
      if (payload.kind === 'tool_summary') return [
        {payloadIndex, payloadKind: 'tool_summary', fieldName: 'toolName', value: payload.toolName},
        {payloadIndex, payloadKind: 'tool_summary', fieldName: 'summary', value: payload.summary},
      ];
      return [];
    }),
    missingPayloadFields: item.payloads.flatMap((payload, payloadIndex) => payload.kind === 'unavailable'
      ? [{payloadIndex, payloadKind: 'unavailable', fieldName: 'resolvedPayload'}]
      : []),
  }));
  return {
    projectionKind: 'NON_EMPTY_OR_PARTIAL',
    stableKey,
    certification: {codexCertificationId: payload.codexCertificationId, codexCertificationDigest: payload.codexCertificationDigest},
    structuralCoverage: payload.structuralCoverage,
    payloadCoverage: payload.payloadCoverage,
    // Payload bytes/availability are compared by the independent commitment
    // projection below; item identity/order facts must remain stable while a
    // missing placeholder is atomically revealed.
    orderedItems,
    // Turn predecessor is a derived adjacency fact, not stable Turn-core data.
    // This lets a first-island null predecessor become populated only when the
    // exact structural gap closes, without rewriting immutable Turn bytes.
    orderedTurnFacts: reduction.turns.map(turnComparisonFact),
    orderedPayloadFacts,
    orderedAdjacencyFacts: reduction.proofs.map((proof) => ({edgeKind: proof.from.endpointKind, from: proof.from, to: proof.to})),
    derivedOrderedIslandFacts: reduction.islands.map((island) => {
      const {islandOrdinal: _islandOrdinal, ...islandCore} = island;
      return stableProjection(islandCore);
    }),
    orderedGapFacts: reduction.gaps.map((gap) => ({semanticTarget: stableProjection(gap.target), reason: gap.reason, repairKind: gap.repairIntent.repairKind, repairDisposition: gap.repairIntent.repairDisposition})),
  };
}

function subsequence(oldItems, candidateItems) {
  let index = 0;
  for (const item of oldItems) {
    const found = candidateItems.findIndex((candidate, candidateIndex) => candidateIndex >= index && same(candidate, item));
    if (found < index) return false;
    index = found + 1;
  }
  return true;
}

function turnFactKey(fact) {
  try { return canonicalize({turnRef: fact.turnRef, turnOrdinal: fact.turnOrdinal}); } catch { return null; }
}

function snapshotResultKind(snapshot) {
  return snapshot?.authority?.normalizedResult?.resultKind ?? snapshot?.beginFrame?.begin?.payload?.readBody?.resultKind;
}

function turnFactsDominate(currentFacts, candidateFacts, currentSnapshot, candidateSnapshot) {
  const candidateByKey = new Map(candidateFacts.map((fact, index) => [turnFactKey(fact), {fact, index}]));
  const currentKeys = new Set();
  for (let index = 0; index < currentFacts.length; index += 1) {
    const old = currentFacts[index];
    const key = turnFactKey(old);
    if (!key || currentKeys.has(key)) return false;
    currentKeys.add(key);
    const next = candidateByKey.get(key);
    // A retained provider-result position cannot move during refinement.
    if (!next || next.index !== index) return false;
    if (old.turnFactKind === 'FULL') {
      if (next.fact.turnFactKind !== 'FULL' || !same(next.fact, old)) return false;
      continue;
    }
    if (next.fact.turnFactKind === 'INDEX') {
      if (!same(next.fact, old)) return false;
      continue;
    }
    // The only widening of a Turn core is the exact INDEX -> FULL branch.
    // The candidate must be backed by the independently resolved FULL result
    // at this same TurnRef+turnOrdinal/result position.  A FULL -> INDEX
    // downgrade never enters this branch.
    if (next.fact.turnFactKind !== 'FULL' || snapshotResultKind(candidateSnapshot) !== 'FULL_TURNS') return false;
    const resolved = candidateSnapshot.authority?.normalizedResult?.orderedTurns?.[index];
    if (!resolved || resolved.turnSpine.turnOrdinal !== next.fact.turnOrdinal ||
        !same(resolved.turnSpine.turnRef, next.fact.turnRef) ||
        resolved.turnSpine.firstTimelineOrdinal !== next.fact.firstTimelineOrdinal ||
        resolved.turnSpine.lastTimelineOrdinal !== next.fact.lastTimelineOrdinal ||
        resolved.turnSpine.itemCount !== next.fact.itemCount) return false;
  }
  // New Turns are allowed only as a bounded provider-page extension of an
  // existing INDEX observation, or inside a previously recorded structural
  // Gap.  This prevents candidate page rows from inventing a new authority
  // outside the old observation.
  const oldGapTargets = currentSnapshot?.pages?.flatMap((page) => page.body.gaps ?? []).map((gap) => gap.target) ?? [];
  const hasTurnExtensionGap = oldGapTargets.some((target) => target?.targetKind === 'TURN_PAYLOAD_NOT_LOADED');
  const hasStructuralGap = oldGapTargets.some((target) => ['BEFORE', 'AFTER', 'BETWEEN', 'COVERAGE_UNKNOWN'].includes(target?.targetKind));
  const candidateNew = candidateFacts.slice(currentFacts.length);
  if (candidateNew.length === 0) return true;
  if (snapshotResultKind(candidateSnapshot) === 'TURN_INDEX' && hasTurnExtensionGap) return true;
  return hasStructuralGap;
}

function dominatesProjection(current, candidate, currentSnapshot, candidateSnapshot) {
  const checks = {
    node: subsequence(current.orderedItems, candidate.orderedItems),
    turn: turnFactsDominate(current.orderedTurnFacts, candidate.orderedTurnFacts, currentSnapshot, candidateSnapshot),
    payload: payloadFactsDominate(current.orderedPayloadFacts ?? [], candidate.orderedPayloadFacts ?? []),
    adjacency: subsequence(current.orderedAdjacencyFacts, candidate.orderedAdjacencyFacts),
    island: islandFactsDominate(current.derivedOrderedIslandFacts, candidate.derivedOrderedIslandFacts),
    gap: gapFactsDoNotRegress(current.orderedGapFacts, candidate.orderedGapFacts, current.orderedTurnFacts, candidate.orderedTurnFacts, currentSnapshot, candidateSnapshot),
  };
  return Object.values(checks).every(Boolean);
}

function islandFactsDominate(currentFacts, candidateFacts) {
  let cursor = 0;
  for (const old of currentFacts) {
    const found = candidateFacts.findIndex((next, index) => index >= cursor &&
      same(next.startBoundary, old.startBoundary) &&
      next.minTurnOrdinal === old.minTurnOrdinal &&
      next.maxTurnOrdinal >= old.maxTurnOrdinal &&
      next.turnCount >= old.turnCount &&
      next.itemCount >= old.itemCount &&
      next.fullTurnCount >= old.fullTurnCount &&
      (old.minTimelineOrdinal === null || next.minTimelineOrdinal === old.minTimelineOrdinal) &&
      (old.maxTimelineOrdinal === null || next.maxTimelineOrdinal === old.maxTimelineOrdinal));
    if (found < cursor) return false;
    cursor = found + 1;
  }
  return true;
}

function payloadFactsDominate(currentFacts, candidateFacts) {
  const candidateByItem = new Map(candidateFacts.map((fact) => [canonicalize(fact.itemRef), fact]));
  const currentByItem = new Map(currentFacts.map((fact) => [canonicalize(fact.itemRef), fact]));
  for (const oldFact of currentFacts) {
    const next = candidateByItem.get(canonicalize(oldFact.itemRef));
    if (!next || !Array.isArray(next.orderedPayloadCommitments) || !Array.isArray(next.orderedObservedFields) || !Array.isArray(next.missingPayloadFields)) return false;
    const oldCommitments = new Map(oldFact.orderedPayloadCommitments.map((fact) => [fact.payloadIndex, fact]));
    const nextCommitments = new Map(next.orderedPayloadCommitments.map((fact) => [fact.payloadIndex, fact]));
    for (const [payloadIndex, oldCommitment] of oldCommitments) {
      if (nextCommitments.get(payloadIndex)?.payloadDigest !== oldCommitment.payloadDigest) return false;
    }
    if (nextCommitments.size < oldCommitments.size || [...nextCommitments.keys()].some((payloadIndex) => !oldCommitments.has(payloadIndex))) return false;
    const oldObserved = new Map(oldFact.orderedObservedFields.map((field) => [`${field.payloadIndex}:${field.fieldName}`, field]));
    const nextObserved = new Map(next.orderedObservedFields.map((field) => [`${field.payloadIndex}:${field.fieldName}`, field]));
    for (const [key, field] of oldObserved) {
      const candidateField = nextObserved.get(key);
      if (!candidateField || !same(candidateField, field)) return false;
    }
    const oldMissing = new Map(oldFact.missingPayloadFields.map((field) => [field.payloadIndex, field]));
    const nextMissing = new Map(next.missingPayloadFields.map((field) => [field.payloadIndex, field]));
    for (const [payloadIndex, field] of nextMissing) {
      if (!oldMissing.has(payloadIndex) || !same(field, oldMissing.get(payloadIndex))) return false;
    }
    for (const [key, field] of nextObserved) {
      if (!oldObserved.has(key) && !oldMissing.has(field.payloadIndex)) return false;
    }
  }
  // A new Item is governed by the node/provenance relation; payload facts for
  // it are accepted here only when they are internally complete and unique.
  for (const fact of candidateFacts) {
    if (currentByItem.has(canonicalize(fact.itemRef))) continue;
    if (!Array.isArray(fact.orderedPayloadCommitments) || !Array.isArray(fact.orderedObservedFields) || !Array.isArray(fact.missingPayloadFields)) return false;
    if (new Set(fact.orderedPayloadCommitments.map((entry) => entry.payloadIndex)).size !== fact.orderedPayloadCommitments.length ||
        new Set(fact.orderedObservedFields.map((entry) => `${entry.payloadIndex}:${entry.fieldName}`)).size !== fact.orderedObservedFields.length ||
        new Set(fact.missingPayloadFields.map((entry) => entry.payloadIndex)).size !== fact.missingPayloadFields.length) return false;
  }
  return true;
}

function gapFactsDoNotRegress(currentFacts, candidateFacts, currentTurnFacts = [], candidateTurnFacts = [], currentSnapshot, candidateSnapshot) {
  // Closing a previously recorded gap is progress. A candidate may retain
  // only exact old gap facts (or a separately reviewed split in a future
  // reducer); an additional Turn-payload gap is allowed only when the same
  // candidate also adds a previously unseen INDEX Turn. This is the one
  // relational expansion produced by a larger notLoaded provider page; it
  // does not permit a caller to invent a gap for an existing Turn.
  const hasCurrentTurn = (turnRef) => currentTurnFacts.some((fact) => same(fact.turnRef, turnRef));
  const hasCandidateTurn = (turnRef) => candidateTurnFacts.some((fact) => same(fact.turnRef, turnRef));
  const keyForTurn = (turnRef, turnOrdinal) => {
    try { return canonicalize({turnRef, turnOrdinal}); } catch { return null; }
  };
  const currentTurnGapByKey = new Map(currentFacts
    .filter((fact) => ['TURN_PAYLOAD_NOT_LOADED', 'TURN_PAYLOAD_OVERSIZED'].includes(fact.semanticTarget?.targetKind))
    .map((fact) => [keyForTurn(fact.semanticTarget.turnRef, fact.semanticTarget.turnOrdinal), fact]));
  const candidateTurnGapByKey = new Map(candidateFacts
    .filter((fact) => ['TURN_PAYLOAD_NOT_LOADED', 'TURN_PAYLOAD_OVERSIZED'].includes(fact.semanticTarget?.targetKind))
    .map((fact) => [keyForTurn(fact.semanticTarget.turnRef, fact.semanticTarget.turnOrdinal), fact]));
  const candidateResult = candidateSnapshot?.authority?.normalizedResult;
  const candidateHasFullTurn = (key) => candidateResult?.resultKind === 'FULL_TURNS' && candidateResult.orderedTurns.some((turn) => keyForTurn(turn.turnSpine.turnRef, turn.turnSpine.turnOrdinal) === key);
  const candidateHasOversizedTurn = (key) => candidateResult?.resultKind === 'OVERSIZED_TURN' && keyForTurn(candidateResult.oversizedTurn?.turnIndex?.turnRef, candidateResult.oversizedTurn?.turnIndex?.turnOrdinal) === key;
  return candidateFacts.every((candidate) => {
    if (currentFacts.some((current) => same(current, candidate))) return true;
    const target = candidate.semanticTarget;
    if (!target) return false;
    if (target.targetKind === 'TURN_PAYLOAD_OVERSIZED') {
      const key = keyForTurn(target.turnRef, target.turnOrdinal);
      const old = currentTurnGapByKey.get(key);
      return old?.semanticTarget?.targetKind === 'TURN_PAYLOAD_NOT_LOADED' &&
        candidateHasOversizedTurn(key) && snapshotResultKind(candidateSnapshot) === 'OVERSIZED_TURN';
    }
    if (target.targetKind === 'PAYLOAD') {
      // Child payload gaps are admitted only for a newly resolved FULL Turn,
      // and their parent Turn must have been an INDEX-to-FULL refinement.
      const parent = candidateTurnFacts.find((fact) => same(fact.turnRef, target.itemRef?.turnRef) && fact.turnFactKind === 'FULL');
      const oldParent = currentTurnFacts.find((fact) => same(fact.turnRef, target.itemRef?.turnRef) && fact.turnFactKind === 'INDEX');
      return Boolean(parent && oldParent && candidateHasFullTurn(keyForTurn(parent.turnRef, parent.turnOrdinal)));
    }
    return ['TURN_PAYLOAD_NOT_LOADED'].includes(target.targetKind) &&
      target.turnRef && hasCandidateTurn(target.turnRef) && !hasCurrentTurn(target.turnRef);
  });
}

function verifyLastGood(value) {
  const current = comparisonProjection(value?.current);
  const candidate = comparisonProjection(value?.candidate);
  if (!current || !candidate || !same(current.stableKey, candidate.stableKey)) return reject('timeline.last-good', 'TIMELINE_LAST_GOOD_REGRESSION');
  const currentSemantic = {...current};
  const candidateSemantic = {...candidate};
  delete currentSemantic.certification;
  delete candidateSemantic.certification;
  // Certification is an evidence envelope. A semantically equal snapshot may
  // be re-certified, while any strict-superset classification must keep the
  // exact certification context so an unproven build cannot dominate a prior
  // verified head.
  if (same(currentSemantic, candidateSemantic)) return accept();
  if (!same(current.certification, candidate.certification) || current.structuralCoverage === 'COMPLETE' && candidate.structuralCoverage !== 'COMPLETE' || current.payloadCoverage === 'COMPLETE' && candidate.payloadCoverage !== 'COMPLETE' || !dominatesProjection(current, candidate, value.current, value.candidate)) return reject('timeline.last-good', 'TIMELINE_LAST_GOOD_REGRESSION');
  return accept();
}

/**
 * Resolve the only cross-materialization dependency admitted by PVMC-1.
 *
 * A CANONICAL_PREDECESSOR proof is not made true by its own three fields or by
 * a caller-supplied manifest digest.  Both materializations must independently
 * verify, the predecessor edge must bind the exact sealed heads, and the
 * candidate proof must name the actual final node of the verified base order.
 * The current manifest is checked only after candidate derivation; it is a
 * guard equality and deliberately does not become a proof digest input here.
 */
export function evaluateCanonicalPredecessorObservation({base, candidate, edge, currentLastGood, materializationPath} = {}) {
  const invalid = () => reject('timeline.last-good', 'TIMELINE_LAST_GOOD_REGRESSION');
  if (!base || !candidate || !edge || !currentLastGood || !same(currentLastGood, base)) return invalid();
  if (!materializationPath || !keysExactly(materializationPath, ['predecessorReferenceEdge'])) return invalid();
  const pathEdge = materializationPath.predecessorReferenceEdge;
  if (!pathEdge || !same(pathEdge, edge)) return invalid();
  const baseResult = verifyMaterialization(base);
  const candidateResult = verifyMaterialization(candidate, {predecessorEdge: edge});
  if (!baseResult.valid || !candidateResult.valid) return invalid();

  const baseFrame = base.beginFrame;
  const candidateFrame = candidate.beginFrame;
  const baseBlock = baseFrame.block;
  const candidateBlock = candidateFrame.block;
  const baseCommit = base.commit;
  const candidateCommit = candidate.commit;
  const baseSubject = baseBlock.subject;
  const candidateSubject = candidateBlock.subject;
  const baseHeadVersion = baseCommit.candidateHeadVersion;
  const candidateHeadVersion = candidateCommit.candidateHeadVersion;
  const baseSource = baseFrame.sourcePartition;
  const candidateSource = candidateFrame.sourcePartition;
  const baseScope = baseFrame.subject;
  const candidateScope = candidateFrame.subject;
  const edgeCurrentKeys = ['proofDigest', 'sourcePartition', 'subject', 'headVersion', 'manifestDigest'];
  const edgeBaseKeys = ['sourcePartition', 'subject', 'headVersion', 'manifestDigest'];
  const edgeKeys = ['edgeKind', 'relationMode', 'current', 'base'];
  if (!keysExactly(edge, edgeKeys) || edge.edgeKind !== 'PREDECESSOR_REFERENCE' || edge.relationMode !== 'REFERENCE_EQUALITY' ||
      !keysExactly(edge.current, edgeCurrentKeys) || !keysExactly(edge.base, edgeBaseKeys) ||
      !sourceMatches(baseSource, candidateSource) || !same(baseScope, candidateScope) ||
      !materialized(baseSubject, baseScope) || !materialized(candidateSubject, candidateScope) ||
      !sourceMatches(edge.current.sourcePartition, candidateSource) || !sourceMatches(edge.base.sourcePartition, baseSource) ||
      !same(edge.current.subject, candidateSubject) || !same(edge.base.subject, baseSubject) ||
      !isDigest(edge.current.proofDigest) || !isDigest(edge.current.manifestDigest) || !isDigest(edge.base.manifestDigest) ||
      !Number.isSafeInteger(edge.current.headVersion) || !Number.isSafeInteger(edge.base.headVersion) ||
      !isDigest(baseBlock.manifestDigest) || !isDigest(candidateBlock.manifestDigest) ||
      baseHeadVersion < 1 || candidateHeadVersion !== baseHeadVersion + 1 ||
      edge.base.headVersion !== baseHeadVersion || edge.current.headVersion !== candidateHeadVersion ||
      edge.base.manifestDigest !== baseBlock.manifestDigest || edge.current.manifestDigest !== candidateBlock.manifestDigest ||
      baseSubject.materializationId === candidateSubject.materializationId) return invalid();

  const baseCertification = {
    codexCertificationId: baseFrame.begin.payload.codexCertificationId,
    codexCertificationDigest: baseFrame.begin.payload.codexCertificationDigest,
  };
  const candidateCertification = {
    codexCertificationId: candidateFrame.begin.payload.codexCertificationId,
    codexCertificationDigest: candidateFrame.begin.payload.codexCertificationDigest,
  };
  if (!same(baseCertification, candidateCertification)) return invalid();

  // The candidate proof must be a real bound row.  A digest-shaped value in
  // the edge is insufficient, and duplicate matches are ambiguous.
  const proofRows = candidate.pages.flatMap((page) => page.body.items)
    .filter((row) => row?.rowKind === 'BOUND_ORDER_PROOF')
    .map((row) => row.boundOrderProof)
    .filter((proof) => proof?.proofDigest === edge.current.proofDigest);
  if (proofRows.length !== 1) return invalid();
  const proof = proofRows[0];
  const sealed = proof.sealedProof;
  if (!sealed || sealed.proofKind !== 'CANONICAL_PREDECESSOR' ||
      !keysExactly(sealed, ['proofKind', 'baseSubject', 'baseHeadVersion', 'baseManifestDigest']) ||
      !same(sealed.baseSubject, baseSubject) || sealed.baseHeadVersion !== baseHeadVersion ||
      sealed.baseManifestDigest !== baseBlock.manifestDigest) return invalid();

  // Reconstruct the final authoritative node from the independently verified
  // base rows.  This is the predecessor relation; it is not a fixture ID or a
  // lexical materialization ordering rule.
  const baseRows = base.pages.flatMap((page) => page.body.items);
  const baseNode = [...baseRows].reverse().find((row) => ['TURN_INDEX', 'TURN_SPINE', 'TIMELINE_ITEM'].includes(row?.rowKind));
  if (!baseNode) return invalid();
  const baseEndpoint = baseNode.rowKind === 'TIMELINE_ITEM'
    ? endpointForItem(baseNode.timelineItem)
    : endpointForTurn(baseNode.turnIndex ?? baseNode.turnSpine);
  if (!same(proof.from, baseEndpoint)) return invalid();

  const predecessor = candidateCommit.lastGoodDisposition;
  if (!predecessor || predecessor.disposition !== 'PREVIOUS_HEAD_RETAINED' ||
      !same(predecessor.previousSubject, baseSubject) || predecessor.previousHeadVersion !== baseHeadVersion) return invalid();
  return accept();
}

/**
 * Validate a collection of cross-instance predecessor references before it is
 * admitted to the digest dependency graph.  The instance verifier above
 * checks the resolved snapshots; this companion gate checks the graph-level
 * invariants (closed edge shape, strict head rank, duplicate/reverse/self
 * references, and cycles) without trusting materialization-id lexical order.
 */
export function evaluatePredecessorReferenceGraph({edges} = {}) {
  const invalid = () => reject('timeline.last-good', 'TIMELINE_LAST_GOOD_REGRESSION');
  if (!denseArray(edges) || edges.length === 0) return invalid();
  const graph = new Map();
  const edgeKeys = new Set();
  const currentKeys = new Set();
  const nodeKey = (part) => {
    try {
      return canonicalize({sourcePartition: part.sourcePartition, subject: part.subject, headVersion: part.headVersion, manifestDigest: part.manifestDigest});
    } catch {
      return null;
    }
  };
  for (const edge of edges) {
    if (!edge || !keysExactly(edge, ['edgeKind', 'relationMode', 'current', 'base']) || edge.edgeKind !== 'PREDECESSOR_REFERENCE' || edge.relationMode !== 'REFERENCE_EQUALITY' ||
        !keysExactly(edge.current, ['proofDigest', 'sourcePartition', 'subject', 'headVersion', 'manifestDigest']) || !keysExactly(edge.base, ['sourcePartition', 'subject', 'headVersion', 'manifestDigest'])) return invalid();
    const current = edge.current;
    const base = edge.base;
    const baseScope = base.subject && {domain: base.subject.domain, threadRef: base.subject.threadRef};
    const currentScope = current.subject && {domain: current.subject.domain, threadRef: current.subject.threadRef};
    if (!validSource(base.sourcePartition) || !validSource(current.sourcePartition) || !sourceMatches(base.sourcePartition, current.sourcePartition) ||
        !materialized(base.subject, baseScope) || !materialized(current.subject, currentScope) || !same(baseScope, currentScope) ||
        !sourceMatches(base.subject.threadRef.sourcePartition, base.sourcePartition) || !sourceMatches(current.subject.threadRef.sourcePartition, current.sourcePartition) ||
        !isDigest(current.proofDigest) || !isDigest(base.manifestDigest) || !isDigest(current.manifestDigest) ||
        !Number.isSafeInteger(base.headVersion) || base.headVersion < 1 || !Number.isSafeInteger(current.headVersion) || current.headVersion !== base.headVersion + 1 ||
        base.subject.materializationId === current.subject.materializationId) return invalid();
    const baseKey = nodeKey(base);
    const currentKey = nodeKey(current);
    if (!baseKey || !currentKey || baseKey === currentKey || currentKeys.has(currentKey)) return invalid();
    const key = `${baseKey}->${currentKey}`;
    if (edgeKeys.has(key)) return invalid();
    edgeKeys.add(key);
    currentKeys.add(currentKey);
    const next = graph.get(baseKey) ?? new Set();
    next.add(currentKey);
    graph.set(baseKey, next);
  }
  const visiting = new Set();
  const visited = new Set();
  const visit = (node) => {
    if (visiting.has(node)) return false;
    if (visited.has(node)) return true;
    visiting.add(node);
    for (const next of graph.get(node) ?? []) if (!visit(next)) return false;
    visiting.delete(node);
    visited.add(node);
    return true;
  };
  for (const node of graph.keys()) if (!visit(node)) return invalid();
  return accept();
}

function verifySourceEpoch(value) {
  const authenticated = value?.authenticated;
  const current = value?.current;
  const source = authenticated?.sourcePartition;
  if (!authenticated || !current || !source || !epochValid(authenticated, source) || !epochValid(current, source) || !sourceMatches(value.attemptedSourcePartition, source) || current.connectionEpoch < authenticated.connectionEpoch || current.sourceEpoch < authenticated.sourceEpoch || current.providerInstanceEpoch < authenticated.providerInstanceEpoch || current.runtimeAuthorityGeneration < authenticated.runtimeAuthorityGeneration) return reject('identity.source-fence', 'SOURCE_FENCE_MISMATCH');
  return accept();
}

function verifyWire(value) {
  if (!value || typeof value.type !== 'string') return reject('wire.closed-normalized-shape', 'WIRE_SHAPE_INVALID');
  if (value.type === 'client_hello') {
    const hello = value.hello;
    return keysExactly(value, ['type', 'hello']) && hello && keysExactly(hello, ['protocolVersion', 'profileId', 'clientInstanceId']) &&
      Number.isSafeInteger(hello.protocolVersion) && hello.protocolVersion >= 1 && hello.profileId === 'pvmc1.phone-core.v1' &&
      typeof hello.clientInstanceId === 'string' && hello.clientInstanceId.length > 0
      ? accept()
      : reject('wire.closed-normalized-shape', 'WIRE_SHAPE_INVALID');
  }
  let source;
  const related = [];
  if (value.type === 'timeline_read' || value.type === 'timeline_ack') source = value.header?.sourceEpoch?.sourcePartition;
  if (value.type === 'operation_submit') source = value.operation?.header?.sourcePartition;
  if (value.type === 'message_image_prepare') source = value.prepare?.header?.sourceEpoch?.sourcePartition;
  if (value.type === 'message_image_commit') source = value.commit?.header?.sourceEpoch?.sourcePartition;
  if (value.type === 'interaction') source = value.command?.command?.interactionRef?.sourcePartition;
  if (value.type === 'timeline_read') related.push(value.query?.threadRef?.sourcePartition);
  if (value.type === 'timeline_ack') related.push(value.ack?.sourcePartition);
  if (value.type === 'operation_submit') related.push(value.operation?.target?.sourcePartition ?? value.operation?.target?.threadRef?.sourcePartition ?? value.operation?.target?.turnRef?.threadRef?.sourcePartition);
  if (value.type === 'message_image_prepare' || value.type === 'message_image_commit') related.push(value[value.type === 'message_image_prepare' ? 'prepare' : 'commit']?.header?.sourceEpoch?.sourcePartition);
  if (value.type === 'interaction') related.push(value.command?.command?.interactionRef?.sourcePartition);
  let closed = true;
  if (value.type === 'timeline_read') {
    const query = value.query;
    const expectedScope = query?.threadRef && {domain: 'TIMELINE', threadRef: query.threadRef};
    closed = query && ['FIRST_READ', 'OLDER_PAGE', 'TIMELINE_REPAIR', 'CACHE_REUSE'].includes(query.readKind) &&
      query.providerReadSpec === undefined || query && query.readKind === 'CACHE_REUSE' && query.providerReadSpec === undefined;
    if (query?.readKind !== 'CACHE_REUSE') {
      closed = Boolean(query && expectedScope && verifyReadSpec(query.providerReadSpec, source, expectedScope) && same(query.providerReadSpec.subjectScope, expectedScope));
    }
  }
  return closed && validSource(source) && related.every((candidate) => sourceMatches(candidate, source)) ? accept() : reject('wire.closed-normalized-shape', 'WIRE_SHAPE_INVALID');
}

export function evaluateRawWireBoundary({payloadBytes, frameBytes, rawBytes} = {}) {
  const rawValid = rawBytes === undefined || rawBytes instanceof Uint8Array;
  const actualFrameBytes = rawBytes === undefined ? frameBytes : rawBytes?.byteLength;
  return rawValid && Number.isSafeInteger(payloadBytes) && payloadBytes >= 0 && Number.isSafeInteger(actualFrameBytes) && actualFrameBytes >= 0 && payloadBytes <= MAX_CONTROL_PAYLOAD_BYTES && actualFrameBytes <= MAX_CONTROL_FRAME_BYTES ? accept() : reject('wire.closed-normalized-shape', 'WIRE_SHAPE_INVALID');
}

function verifyPageBodySize(value) {
  if (!value || !keysExactly(value, ['items', 'gaps']) || !denseArray(value.items) || !denseArray(value.gaps)) {
    return reject('timeline.page-size', 'TIMELINE_PAGE_BODY_TOO_LARGE');
  }
  const bodyBytes = canonicalLength(value);
  return bodyBytes !== null && bodyBytes <= MAX_PUBLICATION_PAGE_BYTES
    ? accept()
    : reject('timeline.page-size', 'TIMELINE_PAGE_BODY_TOO_LARGE');
}

export function evaluateProviderTurnBoundary({byteLength, turnIdentity, oversizedGap} = {}) {
  if (!Number.isSafeInteger(byteLength) || byteLength < 0) return reject('timeline.materialization', 'TURN_PAYLOAD_OVERSIZED');
  if (byteLength > MAX_PROVIDER_TURN_BYTES) {
    const validTurnIdentity = turnIdentity && keysExactly(turnIdentity, ['turnRef', 'turnOrdinal']) &&
      turnIdentity.turnRef && keysExactly(turnIdentity.turnRef, ['threadRef', 'turnId']) &&
      validSource(turnIdentity.turnRef.threadRef?.sourcePartition) && typeof turnIdentity.turnRef.threadRef.providerThreadId === 'string' &&
      typeof turnIdentity.turnRef.turnId === 'string' && Number.isSafeInteger(turnIdentity.turnOrdinal);
    const validOversizedGap = oversizedGap && keysExactly(oversizedGap, ['targetKind', 'turnRef', 'turnOrdinal', 'observedTurnByteCount', 'maximumTurnByteCount']) &&
      oversizedGap.targetKind === 'TURN_PAYLOAD_OVERSIZED' && same(oversizedGap.turnRef, turnIdentity?.turnRef) &&
      oversizedGap.turnOrdinal === turnIdentity?.turnOrdinal && typeof oversizedGap.observedTurnByteCount === 'string' &&
      /^[0-9]+$/.test(oversizedGap.observedTurnByteCount) && BigInt(oversizedGap.observedTurnByteCount) === BigInt(byteLength) &&
      BigInt(oversizedGap.observedTurnByteCount) > BigInt(MAX_PROVIDER_TURN_BYTES) && oversizedGap.maximumTurnByteCount === MAX_PROVIDER_TURN_BYTES;
    if (!validTurnIdentity || !validOversizedGap) return reject('timeline.materialization', 'TURN_PAYLOAD_OVERSIZED');
  }
  return accept();
}

function verifyProviderTurnBoundaryValue(value) {
  if (!value || !keysExactly(value, [
    'turnSpine', 'providerReportedItemCount', 'observedTurnByteCount',
    'maximumTurnByteCount', 'orderedItems',
  ]) || !value.turnSpine || !denseArray(value.orderedItems) ||
      !Number.isSafeInteger(value.providerReportedItemCount) ||
      value.providerReportedItemCount !== value.orderedItems.length ||
      value.turnSpine.itemCount !== value.orderedItems.length ||
      typeof value.observedTurnByteCount !== 'string' ||
      !/^(0|[1-9][0-9]*)$/.test(value.observedTurnByteCount) ||
      BigInt(value.observedTurnByteCount) > BigInt(Number.MAX_SAFE_INTEGER) ||
      value.maximumTurnByteCount !== MAX_PROVIDER_TURN_BYTES) {
    return reject('timeline.provider-turn-boundary', 'TURN_PAYLOAD_OVERSIZED');
  }
  return evaluateProviderTurnBoundary({
    byteLength: Number(value.observedTurnByteCount),
    turnIdentity: {
      turnRef: value.turnSpine.turnRef,
      turnOrdinal: value.turnSpine.turnOrdinal,
    },
  });
}

function verifyCache(value) {
  const query = value?.query;
  return value && keysExactly(value, ['query', 'cacheEntryId']) && query && keysExactly(query, ['readKind', 'threadRef', 'knownMaterializationId']) &&
    query.readKind === 'CACHE_REUSE' && validThreadRef(query.threadRef) && typeof query.knownMaterializationId === 'string' && query.knownMaterializationId.length > 0 &&
    typeof value.cacheEntryId === 'string' && value.cacheEntryId === query.knownMaterializationId ? accept() : reject('timeline.cache-reuse', 'CACHE_REUSE_VIOLATION');
}

function verifyLivePromotion(value) {
  const itemRow = value?.canonical?.pages?.[0]?.body?.items?.find((row) => row.rowKind === 'TIMELINE_ITEM');
  const item = itemRow?.timelineItem;
  const materializedResult = verifyMaterialization(value?.canonical);
  return materializedResult.valid && value.live?.sourceEpoch?.sourcePartition && epochValid(value.live.sourceEpoch, value.canonical.beginFrame.sourcePartition) && same(value.live.itemRef, item?.itemRef) && value.live.provisionalItemOrdinal === item?.itemOrdinal && Number.isSafeInteger(value.live.liveRevision) && value.live.liveRevision > 0 ? accept() : reject('timeline.live-promotion', 'TIMELINE_LIVE_PROMOTION_INVALID');
}

function validThreadRef(value) {
  return value && keysExactly(value, ['sourcePartition', 'providerThreadId']) && validSource(value.sourcePartition) && typeof value.providerThreadId === 'string' && value.providerThreadId.length > 0;
}

function validTurnRef(value) {
  return value && keysExactly(value, ['threadRef', 'turnId']) && validThreadRef(value.threadRef) && typeof value.turnId === 'string' && value.turnId.length > 0;
}

function validQueueTarget(value) {
  return value && keysExactly(value, ['threadRef', 'queueEntryId', 'rootOperationId']) && validThreadRef(value.threadRef) && typeof value.queueEntryId === 'string' && value.queueEntryId.length > 0 && typeof value.rootOperationId === 'string' && value.rootOperationId.length > 0;
}

function validOperationHeader(value) {
  return value && keysExactly(value, ['operationId', 'sourcePartition', 'admissionKey', 'submittedAt']) &&
    typeof value.operationId === 'string' && value.operationId.length > 0 && validSource(value.sourcePartition) &&
    value.admissionKey && keysExactly(value.admissionKey, ['sourcePartition', 'clientMessageId']) &&
    sourceMatches(value.admissionKey.sourcePartition, value.sourcePartition) && typeof value.admissionKey.clientMessageId === 'string' &&
    value.admissionKey.clientMessageId.length > 0 && typeof value.submittedAt === 'string' && value.submittedAt.length > 0 &&
    !Object.hasOwn(value, 'fingerprint');
}

function validOperationRef(value) {
  return value && keysExactly(value, ['sourcePartition', 'operationId', 'operationCode', 'targetId']) && validSource(value.sourcePartition) &&
    typeof value.operationId === 'string' && value.operationId.length > 0 && ['OP-001', 'OP-002', 'OP-003', 'OP-004', 'OP-005', 'OP-006', 'OP-019', 'OP-020', 'OP-021', 'OP-022'].includes(value.operationCode) &&
    typeof value.targetId === 'string' && value.targetId.length > 0;
}

function validTurnInput(value) {
  return value && keysExactly(value, ['text', 'imageRefs', 'structuredRefs']) && typeof value.text === 'string' &&
    denseArray(value.imageRefs) && denseArray(value.structuredRefs) && value.imageRefs.every((ref) => ref && typeof ref === 'object') &&
    value.structuredRefs.every((ref) => ref && typeof ref === 'object');
}

function validOperationCommand(value) {
  if (!value || typeof value.kind !== 'string' || !validOperationHeader(value.header)) return false;
  const source = value.header.sourcePartition;
  if (value.kind === 'start_turn') {
    return keysExactly(value, ['kind', 'operationCode', 'header', 'target', 'input', 'expectedHeadVersion', 'deliveryMode']) &&
      value.operationCode === 'OP-001' && validThreadRef(value.target) && sourceMatches(value.target.sourcePartition, source) && validTurnInput(value.input) &&
      Number.isSafeInteger(value.expectedHeadVersion) && value.expectedHeadVersion >= 0 && value.deliveryMode === 'START_IF_IDLE_ELSE_QUEUE';
  }
  if (value.kind === 'edit_queued_input') {
    return keysExactly(value, ['kind', 'operationCode', 'header', 'target', 'replacement', 'expectedLaneRevision', 'expectedEntryRevision']) &&
      value.operationCode === 'OP-002' && validQueueTarget(value.target) && sourceMatches(value.target.threadRef.sourcePartition, source) && validTurnInput(value.replacement) &&
      Number.isSafeInteger(value.expectedLaneRevision) && value.expectedLaneRevision >= 1 && Number.isSafeInteger(value.expectedEntryRevision) && value.expectedEntryRevision >= 1;
  }
  if (value.kind === 'cancel_queued_input') {
    return keysExactly(value, ['kind', 'operationCode', 'header', 'target', 'expectedLaneRevision', 'expectedEntryRevision', 'reason']) &&
      value.operationCode === 'OP-003' && validQueueTarget(value.target) && sourceMatches(value.target.threadRef.sourcePartition, source) &&
      Number.isSafeInteger(value.expectedLaneRevision) && value.expectedLaneRevision >= 1 && Number.isSafeInteger(value.expectedEntryRevision) && value.expectedEntryRevision >= 1 && value.reason === 'USER_REQUESTED';
  }
  if (value.kind === 'steer_active_turn') {
    return keysExactly(value, ['kind', 'operationCode', 'header', 'target', 'input']) && value.operationCode === 'OP-004' && validTurnRef(value.target) && sourceMatches(value.target.threadRef.sourcePartition, source) && validTurnInput(value.input);
  }
  if (value.kind === 'steer_queued_input') {
    return keysExactly(value, ['kind', 'operationCode', 'header', 'target', 'activeTurn', 'expectedLaneRevision', 'expectedEntryRevision']) &&
      value.operationCode === 'OP-005' && validQueueTarget(value.target) && validTurnRef(value.activeTurn) && sourceMatches(value.target.threadRef.sourcePartition, source) && sourceMatches(value.activeTurn.threadRef.sourcePartition, source) &&
      Number.isSafeInteger(value.expectedLaneRevision) && value.expectedLaneRevision >= 1 && Number.isSafeInteger(value.expectedEntryRevision) && value.expectedEntryRevision >= 1;
  }
  if (value.kind === 'interrupt_turn') {
    return keysExactly(value, ['kind', 'operationCode', 'header', 'target', 'reason']) && value.operationCode === 'OP-006' && validTurnRef(value.target) && sourceMatches(value.target.threadRef.sourcePartition, source) && ['USER_REQUESTED', 'SAFETY_STOP'].includes(value.reason);
  }
  return false;
}

function verifyOperation(value) {
  return validOperationCommand(value) ? accept() : reject('operation.typed-union', 'OPERATION_VARIANT_INVALID');
}

function verifyFingerprint(value) {
  const first = value?.firstRequest;
  const replay = value?.replayRequest;
  if (!first || !replay || !value.firstFingerprint || !value.replayFingerprint || !value.existingOperationRef || !verifyOperation(first).valid || !verifyOperation(replay).valid) return reject('operation.fingerprint', 'OPERATION_FINGERPRINT_CONFLICT');
  const expectedFirst = operationFingerprint(first);
  const expectedReplay = operationFingerprint(replay);
  return same(value.firstFingerprint, expectedFirst) && same(value.replayFingerprint, expectedReplay) && same(value.existingOperationRef, operationRef(first)) && expectedFirst.value === expectedReplay.value ? accept() : reject('operation.fingerprint', 'OPERATION_FINGERPRINT_CONFLICT');
}

function verifyAdmission(value) {
  const ref = value?.operationRef;
  const valid = value && keysExactly(value, ['operationRef', 'operationState', 'dispatchState', 'attemptId', 'attemptRevision', 'admissionFactId']) && validOperationRef(ref) && typeof value.attemptId === 'string' && value.attemptId.length > 0 && Number.isSafeInteger(value.attemptRevision) && value.attemptRevision >= 1 && typeof value.admissionFactId === 'string' && value.admissionFactId.length > 0;
  const prepared = value?.dispatchState === 'PREPARED' && value?.operationState === 'ADMITTED';
  const callStarted = value?.dispatchState === 'CALL_STARTED' && value?.operationState === 'DISPATCHING';
  return valid && (prepared || callStarted) ? accept() : reject('operation.admission-barrier', 'DURABLE_ADMISSION_REQUIRED');
}

function verifyOutcome(value) {
  const ref = value?.operationRef;
  const valid = value && keysExactly(value, ['operationRef', 'beforeCrash', 'afterRecovery', 'reconcileMode', 'operationState', 'reconcileRevision', 'attemptFactId', 'resolutionFactId', 'resolutionOutcome', 'postCommitFactIds', 'deliveryEnvelopeIds']) && validOperationRef(ref) && value.beforeCrash === 'CALL_STARTED' && value.afterRecovery === 'OUTCOME_UNKNOWN' && value.reconcileMode === 'READ_ONLY_RECONCILE' && value.operationState === 'OUTCOME_UNKNOWN' && Number.isSafeInteger(value.reconcileRevision) && value.reconcileRevision >= 1 && typeof value.attemptFactId === 'string' && value.attemptFactId.length > 0 && typeof value.resolutionFactId === 'string' && value.resolutionFactId.length > 0 && value.attemptFactId !== value.resolutionFactId && value.resolutionOutcome === 'STILL_UNKNOWN' && denseArray(value.postCommitFactIds) && value.postCommitFactIds.length === 2 && value.postCommitFactIds[0] === value.attemptFactId && value.postCommitFactIds[1] === value.resolutionFactId && denseArray(value.deliveryEnvelopeIds) && value.deliveryEnvelopeIds.length === 0;
  return valid ? accept() : reject('operation.outcome-unknown', 'OUTCOME_UNKNOWN');
}

function verifyQueue(value) {
  const command = value?.command;
  const queueOwned = new Set(['edit_queued_input', 'cancel_queued_input', 'steer_queued_input']);
  const dispatchOwned = new Set(['steer_active_turn', 'interrupt_turn']);
  const source = command?.header?.sourcePartition;
  const revisions = Number.isSafeInteger(value?.currentLaneRevision) && value.currentLaneRevision >= 1 && Number.isSafeInteger(value?.currentEntryRevision) && value.currentEntryRevision >= 1;
  const ownership = command && (queueOwned.has(command.kind) ? 'QUEUED' : dispatchOwned.has(command.kind) ? 'DISPATCH_OWNED' : null);
  const exactObservation = value && keysExactly(value, ['command', 'currentLaneRevision', 'currentEntryRevision', 'ownership']);
  const expectedRevisions = command && queueOwned.has(command.kind) && value.currentLaneRevision === command.expectedLaneRevision && value.currentEntryRevision === command.expectedEntryRevision;
  return exactObservation && validOperationCommand(command) && !['start_turn'].includes(command.kind) && validSource(source) && revisions && (queueOwned.has(command.kind) ? expectedRevisions : dispatchOwned.has(command.kind)) && value.ownership === ownership ? accept() : reject('queue.revision', 'QUEUE_REVISION_CONFLICT');
}

function commandResponse(value) {
  return value?.command?.commandKind === 'respond' ? value.command.command : null;
}

function verifyInteractionSource(value) {
  const response = commandResponse(value);
  const source = value?.authenticatedEpoch?.sourcePartition;
  const descriptorRef = value?.snapshot?.descriptor?.interactionRef;
  return epochValid(value?.authenticatedEpoch, source) && epochValid(value?.snapshot?.sourceEpoch, source) && descriptorRef && sourceMatches(descriptorRef.sourcePartition, source) && sourceMatches(response?.header?.sourcePartition, source) && sourceMatches(response?.header?.admissionKey?.sourcePartition, source) && response && same(response.interactionRef, descriptorRef) ? accept() : reject('interaction.source', 'INTERACTION_WRONG_SOURCE');
}

function verifyInteractionActor(value) {
  const response = commandResponse(value);
  const claim = value?.snapshot?.claim;
  return value?.authenticatedActor && claim && same(value.authenticatedActor, claim.actorRef) && response && response.claimProof && response.claimProof.claimId === claim.claimId && response.claimProof.leaseRevision === claim.leaseRevision && response.expectedInteractionRevision === value.snapshot.revision && same(response.interactionRef, value.snapshot.descriptor.interactionRef) ? accept() : reject('interaction.actor', 'INTERACTION_WRONG_ACTOR');
}

function verifyInteractionExpiry(value) {
  const response = commandResponse(value);
  const snapshot = value?.snapshot;
  const now = Date.parse(value?.observedAt);
  const expiry = Date.parse(snapshot?.claim?.expiresAt);
  return response && snapshot?.state === 'OPEN_CLAIMED' && Number.isFinite(now) && Number.isFinite(expiry) && expiry > now && response.expectedInteractionRevision === snapshot.revision && same(response.interactionRef, snapshot.descriptor.interactionRef) ? accept() : reject('interaction.expiry', 'INTERACTION_EXPIRED');
}

function verifyInteractionDuplicate(value) {
  return value?.snapshot?.state === 'OPEN_CLAIMED' && value.firstCommand && value.duplicateCommand && same(value.firstCommand, value.duplicateCommand) && commandResponse({command: value.firstCommand}) && commandResponse({command: value.duplicateCommand}) ? accept() : reject('interaction.duplicate', 'INTERACTION_DUPLICATE_RESPONSE');
}

function validOptionalStringObject(value, requiredKey, optionalKey) {
  return keysAtMost(value, [requiredKey], optionalKey ? [optionalKey] : []) &&
    typeof value[requiredKey] === 'string' && value[requiredKey].length > 0 &&
    (optionalKey === undefined || !Object.hasOwn(value, optionalKey) || typeof value[optionalKey] === 'string');
}

function validInteractionResponseBody(descriptor, response) {
  if (!descriptor || !response) return false;
  if (descriptor.kind === 'approval') {
    if (response.disposition === 'approve') return keysExactly(response, ['disposition']);
    return response.disposition === 'reject' && validOptionalStringObject(response, 'disposition', 'message');
  }
  if (descriptor.kind === 'question') {
    if (!keysExactly(response, ['answers']) || !denseArray(response.answers)) return false;
    const questions = denseArray(descriptor.questions) ? new Map(descriptor.questions.map((question) => [question.questionId, question])) : new Map();
    const seen = new Set();
    const validAnswers = response.answers.every((answer) => {
      const question = answer && questions.get(answer.questionId);
      if (!answer || typeof answer.questionId !== 'string' || answer.questionId.length === 0 || !question || seen.has(answer.questionId)) return false;
      seen.add(answer.questionId);
      const options = denseArray(question.options) ? question.options : [];
      if (answer.kind === 'single_choice') return question.responseKind === 'SINGLE_CHOICE' && keysExactly(answer, ['kind', 'questionId', 'choice']) && typeof answer.choice === 'string' && answer.choice.length > 0 && options.includes(answer.choice);
      if (answer.kind === 'multi_choice') return question.responseKind === 'MULTI_CHOICE' && keysExactly(answer, ['kind', 'questionId', 'choices']) && denseArray(answer.choices) && answer.choices.length > 0 && new Set(answer.choices).size === answer.choices.length && answer.choices.every((choice) => typeof choice === 'string' && choice.length > 0 && options.includes(choice));
      return question.responseKind === 'FREE_TEXT' && answer.kind === 'free_text' && keysExactly(answer, ['kind', 'questionId', 'text']) && typeof answer.text === 'string';
    });
    return validAnswers && [...questions.values()].every((question) => !question.required || seen.has(question.questionId));
  }
  if (descriptor.kind === 'mcp_elicitation') {
    if (descriptor.responseShape === 'TEXT') {
      if (response.disposition === 'accept_text') return keysExactly(response, ['disposition', 'text']) && typeof response.text === 'string';
      return response.disposition === 'reject' && validOptionalStringObject(response, 'disposition', 'message');
    }
    if (descriptor.responseShape === 'CONFIRMATION') {
      if (response.disposition === 'accept_confirmation') return keysExactly(response, ['disposition', 'confirmed']) && typeof response.confirmed === 'boolean';
      return response.disposition === 'reject' && validOptionalStringObject(response, 'disposition', 'message');
    }
    return false;
  }
  if (descriptor.kind === 'exit_plan') {
    if (response.disposition === 'accept') return keysExactly(response, ['disposition']);
    return response.disposition === 'reject' && validOptionalStringObject(response, 'disposition', 'feedback');
  }
  return false;
}

function verifyInteractionVariant(value) {
  const response = commandResponse(value);
  const descriptor = value?.snapshot?.descriptor;
  const descriptorKeys = descriptor?.kind === 'approval'
    ? ['kind', 'interactionRef', 'revision', 'prompt', 'allowReject', 'expiresAt']
    : descriptor?.kind === 'question'
      ? ['kind', 'interactionRef', 'revision', 'prompt', 'questions', 'expiresAt']
      : descriptor?.kind === 'mcp_elicitation'
        ? ['kind', 'interactionRef', 'revision', 'prompt', 'responseShape', 'schemaDigest', 'expiresAt']
        : descriptor?.kind === 'exit_plan'
          ? ['kind', 'interactionRef', 'revision', 'summary', 'planDigest', 'expiresAt']
          : null;
  const validDescriptor = descriptorKeys !== null && keysExactly(descriptor, descriptorKeys) &&
    Number.isSafeInteger(descriptor.revision) && descriptor.revision >= 1 &&
    typeof descriptor.expiresAt === 'string' && descriptor.expiresAt.length > 0 &&
    (descriptor.kind === 'approval'
      ? typeof descriptor.prompt === 'string' && typeof descriptor.allowReject === 'boolean'
      : descriptor.kind === 'question'
        ? typeof descriptor.prompt === 'string' && denseArray(descriptor.questions) &&
          new Set(descriptor.questions.map((question) => question?.questionId)).size === descriptor.questions.length &&
          descriptor.questions.every((question) => question && keysExactly(question, ['questionId', 'prompt', 'responseKind', 'options', 'required']) &&
            typeof question.questionId === 'string' && question.questionId.length > 0 && typeof question.prompt === 'string' &&
            ['SINGLE_CHOICE', 'MULTI_CHOICE', 'FREE_TEXT'].includes(question.responseKind) && denseArray(question.options) &&
            question.options.every((option) => typeof option === 'string' && option.length > 0) && typeof question.required === 'boolean')
        : descriptor.kind === 'mcp_elicitation'
          ? typeof descriptor.prompt === 'string' && ['TEXT', 'CONFIRMATION'].includes(descriptor.responseShape) &&
            typeof descriptor.schemaDigest === 'string' && descriptor.schemaDigest.length > 0
          : descriptor.kind === 'exit_plan' && typeof descriptor.summary === 'string' && descriptor.summary.length > 0 &&
            typeof descriptor.planDigest === 'string' && descriptor.planDigest.length > 0);
  const validHeader = response?.header && keysExactly(response.header, ['operationId', 'sourcePartition', 'admissionKey', 'submittedAt']) &&
    typeof response.header.operationId === 'string' && response.header.operationId.length > 0 &&
    validSource(response.header.sourcePartition) && response.header.admissionKey &&
    keysExactly(response.header.admissionKey, ['sourcePartition', 'clientMessageId']) &&
    sourceMatches(response.header.admissionKey.sourcePartition, response.header.sourcePartition) &&
    typeof response.header.admissionKey.clientMessageId === 'string' && response.header.admissionKey.clientMessageId.length > 0 &&
    typeof response.header.submittedAt === 'string' && response.header.submittedAt.length > 0 && !Object.hasOwn(response.header, 'fingerprint');
  const validClaimProof = response?.claimProof && keysExactly(response.claimProof, ['claimId', 'claimToken', 'leaseRevision']) &&
    typeof response.claimProof.claimId === 'string' && response.claimProof.claimId.length > 0 &&
    typeof response.claimProof.claimToken === 'string' && response.claimProof.claimToken.length > 0 &&
    Number.isSafeInteger(response.claimProof.leaseRevision) && response.claimProof.leaseRevision >= 1;
  const validResponse = response && keysExactly(response, ['responseKind', 'operationCode', 'header', 'interactionRef', 'claimProof', 'expectedInteractionRevision', 'response']) &&
    validDescriptor && descriptor.kind === response.responseKind && INTERACTION_CODES.get(response.responseKind) === response.operationCode &&
    validHeader && validClaimProof && same(response.interactionRef, descriptor.interactionRef) &&
    Number.isSafeInteger(response.expectedInteractionRevision) && response.expectedInteractionRevision >= 1 &&
    validInteractionResponseBody(descriptor, response.response);
  return validResponse && value.snapshot.state === 'OPEN_CLAIMED' && response.expectedInteractionRevision === value.snapshot.revision ? accept() : reject('interaction.variant', 'WRONG_INTERACTION_VARIANT');
}

function verifyCapability(value, key, oracleRef, failureReason) {
  const entries = value?.capabilities;
  const matching = denseArray(entries) ? entries.filter((entry) => entry.key === key) : [];
  const entry = matching.length === 1 ? matching[0] : null;
  const validEntry = (candidate) => {
    if (!candidate || typeof candidate.key !== 'string' || candidate.key.length === 0) return false;
    if (candidate.support === 'SUPPORTED' && candidate.availability === 'AVAILABLE') {
      return keysExactly(candidate, ['key', 'support', 'availability']);
    }
    if (candidate.support === 'UNSUPPORTED' && candidate.availability === 'UNKNOWN') {
      return keysExactly(candidate, ['key', 'support', 'availability', 'problemCode']) && typeof candidate.problemCode === 'string' && candidate.problemCode.length > 0;
    }
    return candidate.support === 'REQUIRES_BASE_APP_UPDATE' && candidate.availability === 'UNKNOWN' && keysExactly(candidate, ['key', 'support', 'availability']);
  };
  const shape = denseArray(entries) && matching.length === 1 && new Set(entries.map((candidate) => candidate.key)).size === entries.length && epochValid(value.sourceEpoch, value.sourceEpoch?.sourcePartition) && Number.isSafeInteger(value.snapshotRevision) && value.snapshotRevision >= 1 && entries.every(validEntry);
  if (!shape || !entry) return reject(oracleRef, failureReason);
  if (key === 'claude_provider') return entry.support === 'UNSUPPORTED' && entry.availability === 'UNKNOWN' && entry.problemCode === 'CLAUDE_NOT_IMPLEMENTED' ? accept() : reject(oracleRef, failureReason);
  return entry.support === 'UNSUPPORTED' && entry.availability === 'UNKNOWN' && entry.problemCode === 'PROVIDER_METHOD_NOT_SUPPORTED' ? accept() : reject(oracleRef, failureReason);
}

function verifyImage(value) {
  const source = value?.prepare?.header?.sourceEpoch?.sourcePartition;
  const prepare = value?.prepare;
  const replay = value?.replayPrepare;
  const commit = value?.commit;
  const validHeader = (header) => header && keysExactly(header, ['requestId', 'clientInstanceId', 'sourceEpoch']) &&
    typeof header.requestId === 'string' && header.requestId.length > 0 && typeof header.clientInstanceId === 'string' &&
    header.clientInstanceId.length > 0 && epochValid(header.sourceEpoch, source);
  const validPrepare = (candidate) => candidate && keysExactly(candidate, ['header', 'uploadId', 'mediaType', 'sizeBytes', 'sha256']) &&
    validHeader(candidate.header) && typeof candidate.uploadId === 'string' && candidate.uploadId.length > 0 &&
    IMAGE_TYPES.has(candidate.mediaType) && Number.isSafeInteger(candidate.sizeBytes) && candidate.sizeBytes >= 0 &&
    candidate.sizeBytes <= MAX_IMAGE_BYTES && isDigest(candidate.sha256);
  if (!value || !keysExactly(value, ['prepare', 'replayPrepare', 'commit', 'state', 'turnImageRefs']) || !validPrepare(prepare) || !validPrepare(replay) ||
      !commit || !keysExactly(commit, ['header', 'uploadId']) || !validHeader(commit.header) || !value.state ||
      !source || replay.uploadId !== prepare.uploadId || replay.mediaType !== prepare.mediaType || replay.sizeBytes !== prepare.sizeBytes ||
      replay.sha256 !== prepare.sha256 || commit.uploadId !== prepare.uploadId || value.state.uploadId !== prepare.uploadId ||
      !denseArray(value.turnImageRefs) || value.turnImageRefs.length > MAX_TURN_IMAGE_COUNT ||
      new Set(value.turnImageRefs.map((candidate) => candidate?.imageId)).size !== value.turnImageRefs.length ||
      value.turnImageRefs.some((candidate) => !candidate || !keysExactly(candidate, ['imageId', 'contentRef']) || typeof candidate.imageId !== 'string' || candidate.imageId.length === 0)) {
    return reject('image.ingress', 'IMAGE_INGRESS_REJECTED');
  }
  if (value.state.status === 'PREPARED') return keysExactly(value.state, ['status', 'uploadId', 'uploadTicket', 'expiresAt']) && value.turnImageRefs.length === 0 &&
    typeof value.state.expiresAt === 'string' && value.state.expiresAt.length > 0 && value.state.uploadTicket &&
    keysExactly(value.state.uploadTicket, ['ticketId', 'sourcePartition', 'uploadId', 'sizeBytes', 'sha256', 'expiresAt']) &&
    typeof value.state.uploadTicket.ticketId === 'string' && value.state.uploadTicket.ticketId.length > 0 &&
    sourceMatches(value.state.uploadTicket.sourcePartition, source) && value.state.uploadTicket.uploadId === prepare.uploadId &&
    value.state.uploadTicket.sizeBytes === prepare.sizeBytes && value.state.uploadTicket.sha256 === prepare.sha256 &&
    typeof value.state.uploadTicket.expiresAt === 'string' && value.state.uploadTicket.expiresAt.length > 0 ? accept() : reject('image.ingress', 'IMAGE_INGRESS_REJECTED');
  const ref = value.state.contentRef;
  return value.state.status === 'COMMITTED' && keysExactly(value.state, ['status', 'uploadId', 'contentRef']) && ref &&
    keysExactly(ref, ['contentRefId', 'sourcePartition', 'mediaType', 'sizeBytes', 'sha256', 'objectGeneration']) &&
    typeof ref.contentRefId === 'string' && ref.contentRefId.length > 0 && sourceMatches(ref.sourcePartition, source) &&
    IMAGE_TYPES.has(ref.mediaType) && ref.mediaType === prepare.mediaType && Number.isSafeInteger(ref.sizeBytes) &&
    ref.sizeBytes === prepare.sizeBytes && isDigest(ref.sha256) && ref.sha256 === prepare.sha256 &&
    Number.isSafeInteger(ref.objectGeneration) && ref.objectGeneration >= 1 && value.turnImageRefs.every((candidate) => same(candidate.contentRef, ref)) ? accept() : reject('image.ingress', 'IMAGE_INGRESS_REJECTED');
}

function verifyTypedEmpty(value) {
  const result = verifyMaterialization(value);
  return result.valid && value.commit.pageCount === 0 && value.beginFrame.begin.payload.structuralCoverage === 'EMPTY_PROVEN' ? accept() : reject('timeline.typed-empty', 'TIMELINE_EMPTY_PROOF_INVALID');
}

export function evaluateSemanticRule(value, oracleRef) {
  switch (oracleRef) {
    case 'machine.authority': return evaluateMachineAuthorityCase(value);
    case 'machine.sql-exact-bytes': return evaluateMachineSqlCase(value);
    case 'operation.admission-lookup': return evaluateAdmissionLookupCase(value);
    case 'transaction.authority': return evaluateTransactionAuthorityCase(value);
    case 'wire.closed-normalized-shape': return verifyWire(value);
    case 'identity.source-fence': return verifySourceEpoch(value);
    case 'timeline.typed-empty': return verifyTypedEmpty(value);
    case 'timeline.read-evidence': return value?.evidence && value?.normalizedResult
      ? evaluateReadEvidenceObservation(value)
      : verifyReadEvidence(value);
    case 'timeline.provider-turn-boundary': return verifyProviderTurnBoundaryValue(value);
    case 'timeline.materialization': return verifyMaterialization(value);
    case 'timeline.page-size': return verifyPageBodySize(value);
    case 'image.ingress': return verifyImage(value);
    case 'timeline.cache-reuse': return verifyCache(value);
    case 'timeline.order-gap': return value?.target?.targetKind ? verifyGap(value, value.repairIntent?.subjectScope, value.repairIntent?.sourcePartition) : reject('timeline.order-gap', 'TIMELINE_ORDER_GAP_INVALID');
    case 'timeline.last-good': return value?.edge ? evaluateCanonicalPredecessorObservation(value) : verifyLastGood(value);
    case 'timeline.live-promotion': return verifyLivePromotion(value);
    case 'operation.typed-union': return verifyOperation(value);
    case 'operation.fingerprint': return verifyFingerprint(value);
    case 'operation.admission-barrier': return verifyAdmission(value);
    case 'operation.outcome-unknown': return verifyOutcome(value);
    case 'queue.revision': return verifyQueue(value);
    case 'interaction.source': return verifyInteractionSource(value);
    case 'interaction.actor': return verifyInteractionActor(value);
    case 'interaction.expiry': return verifyInteractionExpiry(value);
    case 'interaction.duplicate': return verifyInteractionDuplicate(value);
    case 'interaction.variant': return verifyInteractionVariant(value);
    case 'capability.claude': return verifyCapability(value, 'claude_provider', oracleRef, 'CLAUDE_NOT_IMPLEMENTED');
    case 'capability.codex-runtime': return verifyCapability(value, 'codex_thread_items_list', oracleRef, 'PROVIDER_METHOD_NOT_SUPPORTED');
    default: throw new Error(`unknown semantic oracle ${oracleRef}`);
  }
}

export function oracleForRule(rule) {
  if (!rule || typeof rule.oracleRef !== 'string') throw new Error('hard rule has no semantic oracle');
  return (value) => evaluateSemanticRule(value, rule.oracleRef);
}
