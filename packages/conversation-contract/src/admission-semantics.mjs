import {jsonEqual} from './canonical.mjs';

const FAILURE_REASON = 'OPERATION_ADMISSION_LOOKUP_INVALID';
const ZERO_EFFECTS = Object.freeze({
  attemptsCreated: 0,
  eventRows: 0,
  newOperationIds: 0,
  operationsCreated: 0,
  outboxRows: 0,
  providerCalls: 0,
  resends: 0,
});

const BRIDGE_ACCEPTED_STATES = new Set([
  'ADMITTED',
  'QUEUED',
  'BLOCKED_PRECONDITION',
  'READY',
  'DISPATCHING',
  'PROVIDER_ACCEPTED',
  'AWAITING_EFFECT_OBSERVATION',
  'SUCCEEDED',
  'FAILED_DEFINITIVE',
  'OUTCOME_UNKNOWN',
  'CANCELLED_PRE_DISPATCH',
]);

function accept() {
  return {valid: true, reason: 'NONE', postState: 'APPLIED', sideEffects: {}};
}

function reject() {
  return {
    valid: false,
    reason: FAILURE_REASON,
    postState: 'UNCHANGED',
    sideEffects: ZERO_EFFECTS,
  };
}

function same(left, right) {
  try {
    return jsonEqual(left, right);
  } catch {
    return false;
  }
}

function effectsAreZero(effects) {
  return effects !== null && typeof effects === 'object' && !Array.isArray(effects) &&
    Object.keys(ZERO_EFFECTS).every((key) => effects[key] === 0) &&
    Object.keys(effects).length === Object.keys(ZERO_EFFECTS).length;
}

function queryCorrelationMatches(value, requireAuthenticatedSource) {
  const {lookupKey, query} = value;
  return query?.schemaRevision === 1 && query.kind === 'operation.query' &&
    value.outerRequestId === query.requestId &&
    (!requireAuthenticatedSource || same(value.authenticatedSourcePartition, query.sourcePartition)) &&
    same(query.sourcePartition, lookupKey?.sourcePartition) &&
    query.operationId === lookupKey.operationId &&
    query.fingerprintVersion === lookupKey.fingerprintVersion &&
    query.operationFingerprint === lookupKey.operationFingerprint;
}

function resultCorrelationMatches(value) {
  const {lookupKey, query, result} = value;
  return queryCorrelationMatches(value, true) &&
    result?.schemaRevision === 1 && result.kind === 'operation.snapshot' &&
    same(value.authenticatedSourcePartition, query.sourcePartition) &&
    result.requestId === query.requestId &&
    same(result.sourcePartition, query.sourcePartition) &&
    result.operationId === query.operationId && result.operationId === lookupKey.operationId &&
    result.fingerprintVersion === query.fingerprintVersion &&
    result.fingerprintVersion === lookupKey.fingerprintVersion &&
    result.operationFingerprint === query.operationFingerprint &&
    result.operationFingerprint === lookupKey.operationFingerprint;
}

function conflictCode(result) {
  return result?.outcome === 'CONFLICT' ? result.problem?.problemCode : null;
}

function conflictProblemMatches(result, operationId, problemCode) {
  return conflictCode(result) === problemCode &&
    result.problem?.errorClass === 'CONFLICT' &&
    result.problem?.retryDirective === 'NEVER' &&
    result.problem?.subject?.kind === 'operation' &&
    result.problem.subject.operationId === operationId;
}

function expectedProjectionForSnapshot(snapshot) {
  if (snapshot.lifecycleState === 'RECEIVED') return 'ADMISSION_UNKNOWN';
  if (snapshot.lifecycleState === 'REJECTED_BEFORE_ADMISSION') return 'LOCAL_ERROR';
  if (BRIDGE_ACCEPTED_STATES.has(snapshot.lifecycleState)) return 'BRIDGE_ACCEPTED';
  return null;
}

function persistedOperationMatchesLookup(value) {
  const persisted = value.persistedOperation;
  return persisted !== null && typeof persisted === 'object' &&
    same(persisted.sourcePartition, value.lookupKey.sourcePartition) &&
    persisted.operationId === value.lookupKey.operationId;
}

export function evaluateAdmissionLookupCase(value) {
  if (!effectsAreZero(value?.effects) || value.inFlightCount !== 1) return reject();
  if (value.transportOutcome === 'TIMEOUT') {
    return queryCorrelationMatches(value, true) && value.result === null &&
      value.expectedProjection === 'ADMISSION_UNKNOWN'
      ? accept()
      : reject();
  }
  if (value.transportOutcome === 'AUTH_FAILURE') {
    return queryCorrelationMatches(value, false) &&
      value.authenticatedSourcePartition === null && value.result === null &&
      value.expectedProjection === 'ADMISSION_UNKNOWN'
      ? accept()
      : reject();
  }
  if (value.transportOutcome !== 'RESULT' || value.result === null ||
      value.authenticatedSourcePartition === null || !resultCorrelationMatches(value)) {
    return reject();
  }

  if (value.result.outcome === 'NOT_FOUND') {
    return value.persistedOperation === null &&
      value.expectedProjection === 'ADMISSION_UNKNOWN'
      ? accept()
      : reject();
  }
  if (!persistedOperationMatchesLookup(value)) return reject();

  const persisted = value.persistedOperation;
  const privateOrigin = persisted.originView.kind === 'AUTO_APPROVAL_POLICY';
  const actorMismatch = persisted.originView.kind === 'AUTHENTICATED_ACTOR' &&
    (value.currentActorBinding === null ||
      !same(persisted.originView.actorBinding, value.currentActorBinding));
  if (privateOrigin || actorMismatch) {
    return conflictProblemMatches(
      value.result,
      value.lookupKey.operationId,
      'OPERATION_ACTOR_MISMATCH',
    ) &&
      value.expectedProjection === 'LOCAL_ERROR'
      ? accept()
      : reject();
  }

  const fingerprintMismatch = persisted.fingerprintVersion !==
      value.lookupKey.fingerprintVersion ||
    persisted.operationFingerprint !== value.lookupKey.operationFingerprint;
  if (fingerprintMismatch) {
    return conflictProblemMatches(
      value.result,
      value.lookupKey.operationId,
      'OPERATION_FINGERPRINT_CONFLICT',
    ) &&
      value.expectedProjection === 'LOCAL_ERROR'
      ? accept()
      : reject();
  }

  if (value.result.outcome !== 'MATCHED') return reject();
  if (!same(value.result.snapshot, persisted.snapshot)) return reject();
  const expected = expectedProjectionForSnapshot(value.result.snapshot);
  return expected !== null && value.expectedProjection === expected ? accept() : reject();
}

const MATCHED_VECTOR_STATES = Object.freeze([
  ['received', 'RECEIVED', 'ADMISSION_UNKNOWN'],
  ['rejected_before_admission', 'REJECTED_BEFORE_ADMISSION', 'LOCAL_ERROR'],
  ['admitted', 'ADMITTED', 'BRIDGE_ACCEPTED'],
  ['queued', 'QUEUED', 'BRIDGE_ACCEPTED'],
  ['blocked_precondition', 'BLOCKED_PRECONDITION', 'BRIDGE_ACCEPTED'],
  ['ready', 'READY', 'BRIDGE_ACCEPTED'],
  ['dispatching', 'DISPATCHING', 'BRIDGE_ACCEPTED'],
  ['provider_accepted', 'PROVIDER_ACCEPTED', 'BRIDGE_ACCEPTED'],
  ['awaiting_effect_observation', 'AWAITING_EFFECT_OBSERVATION', 'BRIDGE_ACCEPTED'],
  ['succeeded', 'SUCCEEDED', 'BRIDGE_ACCEPTED'],
  ['failed_definitive', 'FAILED_DEFINITIVE', 'BRIDGE_ACCEPTED'],
  ['outcome_unknown', 'OUTCOME_UNKNOWN', 'BRIDGE_ACCEPTED'],
  ['cancelled_pre_dispatch', 'CANCELLED_PRE_DISPATCH', 'BRIDGE_ACCEPTED'],
]);
const OTHER_VECTOR_IDS = Object.freeze([
  'operation.admission-lookup.not-found',
  'operation.admission-lookup.private-origin-conflict',
  'operation.admission-lookup.actor-mismatch-conflict',
  'operation.admission-lookup.fingerprint-conflict',
  'operation.admission-lookup.auth-failure',
  'operation.admission-lookup.timeout',
  'operation.admission-lookup.outer-request.negative',
  'operation.admission-lookup.authenticated-source.negative',
  'operation.admission-lookup.result-request.negative',
  'operation.admission-lookup.result-operation.negative',
  'operation.admission-lookup.result-fingerprint.negative',
  'operation.admission-lookup.wrong-projection.negative',
  'operation.admission-lookup.double-in-flight.negative',
  'operation.admission-lookup.provider-call.negative',
  'operation.admission-lookup.actor-before-fingerprint.negative',
  'operation.admission-lookup.not-found-resend.negative',
]);

export function validateAdmissionLookupVectors(activeVectors) {
  const expectedIds = new Set([
    ...MATCHED_VECTOR_STATES.map(([suffix]) =>
      `operation.admission-lookup.matched.${suffix}`),
    ...OTHER_VECTOR_IDS,
  ]);
  const vectors = activeVectors.filter((vector) =>
    vector.vectorSetRef === 'vectors.operation-admission-lookup');
  if (vectors.length !== expectedIds.size || vectors.some((vector) =>
    !expectedIds.has(vector.id))) {
    throw new TypeError(
      `vectors.operationAdmissionLookup: expected ${expectedIds.size} exact vectors`,
    );
  }
  const byId = new Map(vectors.map((vector) => [vector.id, vector]));
  for (const [suffix, lifecycleState, projection] of MATCHED_VECTOR_STATES) {
    const id = `operation.admission-lookup.matched.${suffix}`;
    const vector = byId.get(id);
    if (vector.ruleRef !== 'rule.operation.admission-lookup' ||
        vector.typeRef !== 'OperationAdmissionRecoveryCaseV1' ||
        vector.value.result?.outcome !== 'MATCHED' ||
        vector.value.result.snapshot?.lifecycleState !== lifecycleState ||
        vector.value.persistedOperation?.snapshot?.lifecycleState !== lifecycleState ||
        !same(vector.value.result.snapshot, vector.value.persistedOperation.snapshot) ||
        vector.value.expectedProjection !== projection) {
      throw new TypeError(`${id}: does not bind its exact persisted lifecycle subject`);
    }
  }
  const notFound = byId.get('operation.admission-lookup.not-found').value;
  if (notFound.result?.outcome !== 'NOT_FOUND' || notFound.persistedOperation !== null ||
      notFound.expectedProjection !== 'ADMISSION_UNKNOWN') {
    throw new TypeError(
      'operation.admission-lookup.not-found: requires a genuinely absent persisted row',
    );
  }
  const notFoundResend = byId.get('operation.admission-lookup.not-found-resend.negative').value;
  if (notFoundResend.result?.outcome !== 'NOT_FOUND' ||
      notFoundResend.persistedOperation !== null || notFoundResend.effects?.resends !== 1) {
    throw new TypeError(
      'operation.admission-lookup.not-found-resend.negative: wrong exact mutation',
    );
  }
}

export {
  BRIDGE_ACCEPTED_STATES,
  FAILURE_REASON as ADMISSION_LOOKUP_FAILURE_REASON,
  ZERO_EFFECTS as ZERO_ADMISSION_LOOKUP_EFFECTS,
};
