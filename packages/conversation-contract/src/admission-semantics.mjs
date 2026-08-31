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

function admissionVectorBaseline() {
  const sourcePartition = {
    bridgeIdentityId: 'bi-1',
    bridgeInstanceId: 'bridge-1',
    codexSourceId: 'codex-1',
  };
  const actorBinding = {
    kind: 'PAIRED_DEVICE',
    principalId: 'actor-1',
    trustRevision: 1,
  };
  const operationFingerprint = 'a'.repeat(64);
  return {
    transportOutcome: 'RESULT',
    inFlightCount: 1,
    outerRequestId: 'request-1',
    authenticatedSourcePartition: structuredClone(sourcePartition),
    lookupKey: {
      sourcePartition: structuredClone(sourcePartition),
      operationId: 'operation-1',
      fingerprintVersion: 1,
      operationFingerprint,
    },
    query: {
      schemaRevision: 1,
      kind: 'operation.query',
      requestId: 'request-1',
      sourcePartition: structuredClone(sourcePartition),
      operationId: 'operation-1',
      fingerprintVersion: 1,
      operationFingerprint,
    },
    result: {
      outcome: 'MATCHED',
      schemaRevision: 1,
      kind: 'operation.snapshot',
      requestId: 'request-1',
      sourcePartition: structuredClone(sourcePartition),
      operationId: 'operation-1',
      fingerprintVersion: 1,
      operationFingerprint,
      snapshot: {operationRevision: 1, lifecycleState: 'RECEIVED'},
    },
    persistedOperation: {
      sourcePartition: structuredClone(sourcePartition),
      operationId: 'operation-1',
      originView: {
        kind: 'AUTHENTICATED_ACTOR',
        actorBinding: structuredClone(actorBinding),
      },
      fingerprintVersion: 1,
      operationFingerprint,
      snapshot: {operationRevision: 1, lifecycleState: 'RECEIVED'},
    },
    currentActorBinding: structuredClone(actorBinding),
    expectedProjection: 'ADMISSION_UNKNOWN',
    effects: structuredClone(ZERO_EFFECTS),
  };
}

function admissionConflict(problemCode) {
  return {
    errorClass: 'CONFLICT',
    problemCode,
    retryDirective: 'NEVER',
    safeTitle: 'Operation admission conflict',
    subject: {kind: 'operation', operationId: 'operation-1'},
  };
}

function matchedAdmissionVector(lifecycleState, expectedProjection) {
  const value = admissionVectorBaseline();
  value.result.snapshot.lifecycleState = lifecycleState;
  value.persistedOperation.snapshot.lifecycleState = lifecycleState;
  value.expectedProjection = expectedProjection;
  return value;
}

function conflictAdmissionVector(problemCode) {
  const value = matchedAdmissionVector('ADMITTED', 'LOCAL_ERROR');
  value.result.outcome = 'CONFLICT';
  value.result.problem = admissionConflict(problemCode);
  delete value.result.snapshot;
  return value;
}

function expectedAdmissionVectorValues() {
  const values = new Map();
  for (const [suffix, lifecycleState, projection] of MATCHED_VECTOR_STATES) {
    values.set(
      `operation.admission-lookup.matched.${suffix}`,
      matchedAdmissionVector(lifecycleState, projection),
    );
  }

  const notFound = admissionVectorBaseline();
  notFound.result.outcome = 'NOT_FOUND';
  delete notFound.result.snapshot;
  notFound.persistedOperation = null;
  values.set('operation.admission-lookup.not-found', notFound);

  const privateOrigin = conflictAdmissionVector('OPERATION_ACTOR_MISMATCH');
  privateOrigin.persistedOperation.originView = {kind: 'AUTO_APPROVAL_POLICY'};
  privateOrigin.currentActorBinding = null;
  values.set('operation.admission-lookup.private-origin-conflict', privateOrigin);

  const actorMismatch = conflictAdmissionVector('OPERATION_ACTOR_MISMATCH');
  actorMismatch.currentActorBinding.principalId = 'actor-2';
  values.set('operation.admission-lookup.actor-mismatch-conflict', actorMismatch);

  const fingerprintConflict = conflictAdmissionVector('OPERATION_FINGERPRINT_CONFLICT');
  fingerprintConflict.persistedOperation.operationFingerprint = 'b'.repeat(64);
  values.set('operation.admission-lookup.fingerprint-conflict', fingerprintConflict);

  const authFailure = matchedAdmissionVector('ADMITTED', 'ADMISSION_UNKNOWN');
  authFailure.transportOutcome = 'AUTH_FAILURE';
  authFailure.authenticatedSourcePartition = null;
  authFailure.result = null;
  values.set('operation.admission-lookup.auth-failure', authFailure);

  const timeout = matchedAdmissionVector('ADMITTED', 'ADMISSION_UNKNOWN');
  timeout.transportOutcome = 'TIMEOUT';
  timeout.result = null;
  values.set('operation.admission-lookup.timeout', timeout);

  const negative = () => matchedAdmissionVector('ADMITTED', 'BRIDGE_ACCEPTED');
  const outerRequest = negative();
  outerRequest.outerRequestId = 'request-2';
  values.set('operation.admission-lookup.outer-request.negative', outerRequest);

  const authenticatedSource = negative();
  for (const source of [
    authenticatedSource.authenticatedSourcePartition,
    authenticatedSource.lookupKey.sourcePartition,
    authenticatedSource.query.sourcePartition,
    authenticatedSource.persistedOperation.sourcePartition,
  ]) {
    source.codexSourceId = 'codex-2';
  }
  values.set('operation.admission-lookup.authenticated-source.negative', authenticatedSource);

  const resultRequest = negative();
  resultRequest.result.requestId = 'request-2';
  values.set('operation.admission-lookup.result-request.negative', resultRequest);

  const resultOperation = negative();
  resultOperation.result.operationId = 'operation-2';
  values.set('operation.admission-lookup.result-operation.negative', resultOperation);

  const resultFingerprint = negative();
  resultFingerprint.result.operationFingerprint = 'c'.repeat(64);
  values.set('operation.admission-lookup.result-fingerprint.negative', resultFingerprint);

  const wrongProjection = negative();
  wrongProjection.expectedProjection = 'LOCAL_ERROR';
  values.set('operation.admission-lookup.wrong-projection.negative', wrongProjection);

  const doubleInFlight = negative();
  doubleInFlight.inFlightCount = 2;
  values.set('operation.admission-lookup.double-in-flight.negative', doubleInFlight);

  const providerCall = negative();
  providerCall.effects.providerCalls = 1;
  values.set('operation.admission-lookup.provider-call.negative', providerCall);

  const actorBeforeFingerprint = conflictAdmissionVector('OPERATION_FINGERPRINT_CONFLICT');
  actorBeforeFingerprint.currentActorBinding.principalId = 'actor-2';
  actorBeforeFingerprint.persistedOperation.operationFingerprint = 'b'.repeat(64);
  values.set(
    'operation.admission-lookup.actor-before-fingerprint.negative',
    actorBeforeFingerprint,
  );

  const notFoundResend = structuredClone(notFound);
  notFoundResend.effects.resends = 1;
  values.set('operation.admission-lookup.not-found-resend.negative', notFoundResend);
  return values;
}

export function validateAdmissionLookupVectors(activeVectors) {
  const expectedValues = expectedAdmissionVectorValues();
  const expectedIds = new Set([
    ...MATCHED_VECTOR_STATES.map(([suffix]) =>
      `operation.admission-lookup.matched.${suffix}`),
    ...OTHER_VECTOR_IDS,
  ]);
  if (expectedValues.size !== expectedIds.size ||
      [...expectedIds].some((id) => !expectedValues.has(id))) {
    throw new TypeError('vectors.operationAdmissionLookup: incomplete independent subject oracle');
  }
  const vectors = activeVectors.filter((vector) =>
    vector.vectorSetRef === 'vectors.operation-admission-lookup');
  if (vectors.length !== expectedIds.size || vectors.some((vector) =>
    !expectedIds.has(vector.id))) {
    throw new TypeError(
      `vectors.operationAdmissionLookup: expected ${expectedIds.size} exact vectors`,
    );
  }
  for (const vector of vectors) {
    if (vector.ruleRef !== 'rule.operation.admission-lookup' ||
        vector.typeRef !== 'OperationAdmissionRecoveryCaseV1' ||
        !same(vector.value, expectedValues.get(vector.id))) {
      throw new TypeError(`${vector.id}: does not bind its exact admission subject`);
    }
  }
}

export {
  BRIDGE_ACCEPTED_STATES,
  FAILURE_REASON as ADMISSION_LOOKUP_FAILURE_REASON,
  ZERO_EFFECTS as ZERO_ADMISSION_LOOKUP_EFFECTS,
};
