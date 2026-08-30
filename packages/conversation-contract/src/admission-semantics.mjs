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

  const privateOrigin = value.storedOriginView.kind === 'AUTO_APPROVAL_POLICY';
  const actorMismatch = value.storedOriginView.kind === 'AUTHENTICATED_ACTOR' &&
    (value.currentActorBinding === null ||
      !same(value.storedOriginView.actorBinding, value.currentActorBinding));
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

  const fingerprintMismatch = value.storedFingerprintVersion !==
      value.lookupKey.fingerprintVersion ||
    value.storedOperationFingerprint !== value.lookupKey.operationFingerprint;
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

  if (value.result.outcome === 'NOT_FOUND') {
    return value.expectedProjection === 'ADMISSION_UNKNOWN' ? accept() : reject();
  }
  if (value.result.outcome !== 'MATCHED') return reject();
  const expected = expectedProjectionForSnapshot(value.result.snapshot);
  return expected !== null && value.expectedProjection === expected ? accept() : reject();
}

export {
  BRIDGE_ACCEPTED_STATES,
  FAILURE_REASON as ADMISSION_LOOKUP_FAILURE_REASON,
  ZERO_EFFECTS as ZERO_ADMISSION_LOOKUP_EFFECTS,
};
