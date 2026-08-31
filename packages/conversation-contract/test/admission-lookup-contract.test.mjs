import assert from 'node:assert/strict';
import test from 'node:test';

import {
  ADMISSION_LOOKUP_FAILURE_REASON,
  BRIDGE_ACCEPTED_STATES,
  evaluateAdmissionLookupCase,
  ZERO_ADMISSION_LOOKUP_EFFECTS,
} from '../src/admission-semantics.mjs';

const sourcePartition = Object.freeze({
  bridgeIdentityId: 'bi-1',
  bridgeInstanceId: 'bridge-1',
  codexSourceId: 'codex-1',
});
const actor = Object.freeze({
  kind: 'PAIRED_DEVICE',
  principalId: 'actor-1',
  trustRevision: 1,
});
const operationId = 'operation-1';
const requestId = 'request-1';
const fingerprint = 'a'.repeat(64);

function problem(problemCode, subjectOperationId = operationId) {
  return {
    errorClass: 'CONFLICT',
    problemCode,
    retryDirective: 'NEVER',
    safeTitle: 'Operation admission conflict',
    subject: {kind: 'operation', operationId: subjectOperationId},
  };
}

function baseCase() {
  const lookupKey = {
    sourcePartition,
    operationId,
    fingerprintVersion: 1,
    operationFingerprint: fingerprint,
  };
  const query = {
    schemaRevision: 1,
    kind: 'operation.query',
    requestId,
    sourcePartition,
    operationId,
    fingerprintVersion: 1,
    operationFingerprint: fingerprint,
  };
  return {
    transportOutcome: 'RESULT',
    inFlightCount: 1,
    outerRequestId: requestId,
    authenticatedSourcePartition: sourcePartition,
    lookupKey,
    query,
    result: {
      outcome: 'MATCHED',
      schemaRevision: 1,
      kind: 'operation.snapshot',
      requestId,
      sourcePartition,
      operationId,
      fingerprintVersion: 1,
      operationFingerprint: fingerprint,
      snapshot: {operationRevision: 1, lifecycleState: 'ADMITTED'},
    },
    persistedOperation: {
      sourcePartition,
      operationId,
      originView: {kind: 'AUTHENTICATED_ACTOR', actorBinding: actor},
      fingerprintVersion: 1,
      operationFingerprint: fingerprint,
      snapshot: {operationRevision: 1, lifecycleState: 'ADMITTED'},
    },
    currentActorBinding: actor,
    expectedProjection: 'BRIDGE_ACCEPTED',
    effects: structuredClone(ZERO_ADMISSION_LOOKUP_EFFECTS),
  };
}

function accepted() {
  return {valid: true, reason: 'NONE', postState: 'APPLIED', sideEffects: {}};
}

function rejected() {
  return {
    valid: false,
    reason: ADMISSION_LOOKUP_FAILURE_REASON,
    postState: 'UNCHANGED',
    sideEffects: structuredClone(ZERO_ADMISSION_LOOKUP_EFFECTS),
  };
}

test('projects every matched lifecycle without creating durable or provider effects', () => {
  const states = [
    ['RECEIVED', 'ADMISSION_UNKNOWN'],
    ['REJECTED_BEFORE_ADMISSION', 'LOCAL_ERROR'],
    ...[...BRIDGE_ACCEPTED_STATES].map((state) => [state, 'BRIDGE_ACCEPTED']),
  ];
  assert.equal(states.length, 13);
  for (const [state, projection] of states) {
    const value = baseCase();
    value.result.snapshot.lifecycleState = state;
    value.persistedOperation.snapshot.lifecycleState = state;
    value.expectedProjection = projection;
    assert.deepEqual(evaluateAdmissionLookupCase(value), accepted(), state);
  }
});

test('NOT_FOUND preserves ADMISSION_UNKNOWN and forbids resend', () => {
  const value = baseCase();
  value.result = {...value.result, outcome: 'NOT_FOUND'};
  delete value.result.snapshot;
  value.persistedOperation = null;
  value.expectedProjection = 'ADMISSION_UNKNOWN';
  assert.deepEqual(evaluateAdmissionLookupCase(value), accepted());
  value.effects.resends = 1;
  assert.deepEqual(evaluateAdmissionLookupCase(value), rejected());
});

test('actor-origin mismatch is resolved before stored fingerprint mismatch', () => {
  const value = baseCase();
  value.currentActorBinding = {...actor, principalId: 'actor-2'};
  value.persistedOperation.operationFingerprint = 'b'.repeat(64);
  value.result = {
    ...value.result,
    outcome: 'CONFLICT',
    problem: problem('OPERATION_ACTOR_MISMATCH'),
  };
  delete value.result.snapshot;
  value.expectedProjection = 'LOCAL_ERROR';
  assert.deepEqual(evaluateAdmissionLookupCase(value), accepted());
  value.result.problem = problem('OPERATION_FINGERPRINT_CONFLICT');
  assert.deepEqual(evaluateAdmissionLookupCase(value), rejected());
});

test('private auto-approval origin always selects actor mismatch conflict', () => {
  const value = baseCase();
  value.persistedOperation.originView = {kind: 'AUTO_APPROVAL_POLICY'};
  value.currentActorBinding = null;
  value.result = {
    ...value.result,
    outcome: 'CONFLICT',
    problem: problem('OPERATION_ACTOR_MISMATCH'),
  };
  delete value.result.snapshot;
  value.expectedProjection = 'LOCAL_ERROR';
  assert.deepEqual(evaluateAdmissionLookupCase(value), accepted());
});

test('matching actor permits exact stored fingerprint conflict', () => {
  const value = baseCase();
  value.persistedOperation.fingerprintVersion = 2;
  value.result = {
    ...value.result,
    outcome: 'CONFLICT',
    problem: problem('OPERATION_FINGERPRINT_CONFLICT'),
  };
  delete value.result.snapshot;
  value.expectedProjection = 'LOCAL_ERROR';
  assert.deepEqual(evaluateAdmissionLookupCase(value), accepted());
});

test('outer, authenticated-source, result, and lookup-key correlation precede outcome', () => {
  const mutations = [
    (value) => { value.outerRequestId = 'request-2'; },
    (value) => { value.authenticatedSourcePartition = {...sourcePartition, codexSourceId: 'codex-2'}; },
    (value) => { value.lookupKey.operationId = 'operation-2'; },
    (value) => { value.query.schemaRevision = 2; },
    (value) => { value.query.kind = 'operation.other'; },
    (value) => { value.result.requestId = 'request-2'; },
    (value) => { value.result.sourcePartition = {...sourcePartition, bridgeInstanceId: 'bridge-2'}; },
    (value) => { value.result.operationFingerprint = 'c'.repeat(64); },
  ];
  for (const mutate of mutations) {
    const value = baseCase();
    mutate(value);
    assert.deepEqual(evaluateAdmissionLookupCase(value), rejected());
  }
});

test('MATCHED snapshot must exact-equal the persisted revision and lifecycle state', () => {
  const revisionDrift = baseCase();
  revisionDrift.result.snapshot.operationRevision = 2;
  assert.deepEqual(evaluateAdmissionLookupCase(revisionDrift), rejected());

  const stateDrift = baseCase();
  stateDrift.result.snapshot.lifecycleState = 'QUEUED';
  assert.deepEqual(evaluateAdmissionLookupCase(stateDrift), rejected());
});

test('NOT_FOUND is accepted only for a genuinely absent persisted operation row', () => {
  const present = baseCase();
  present.result = {...present.result, outcome: 'NOT_FOUND'};
  delete present.result.snapshot;
  present.expectedProjection = 'ADMISSION_UNKNOWN';
  assert.deepEqual(evaluateAdmissionLookupCase(present), rejected());

  const absent = structuredClone(present);
  absent.persistedOperation = null;
  assert.deepEqual(evaluateAdmissionLookupCase(absent), accepted());
});

test('conflict problem is fenced to the correlated operation and closed retry class', () => {
  const value = baseCase();
  value.currentActorBinding = {...actor, principalId: 'actor-2'};
  value.result = {...value.result, outcome: 'CONFLICT', problem: problem(
    'OPERATION_ACTOR_MISMATCH',
    'operation-2',
  )};
  delete value.result.snapshot;
  value.expectedProjection = 'LOCAL_ERROR';
  assert.deepEqual(evaluateAdmissionLookupCase(value), rejected());
  value.result.problem = problem('OPERATION_ACTOR_MISMATCH');
  value.result.problem.retryDirective = 'NEW_OPERATION';
  assert.deepEqual(evaluateAdmissionLookupCase(value), rejected());
});

test('timeout and authentication failure release exactly one keyed query slot', () => {
  const timeout = baseCase();
  timeout.transportOutcome = 'TIMEOUT';
  timeout.result = null;
  timeout.expectedProjection = 'ADMISSION_UNKNOWN';
  assert.deepEqual(evaluateAdmissionLookupCase(timeout), accepted());
  timeout.outerRequestId = 'request-2';
  assert.deepEqual(evaluateAdmissionLookupCase(timeout), rejected());

  const authFailure = baseCase();
  authFailure.transportOutcome = 'AUTH_FAILURE';
  authFailure.authenticatedSourcePartition = null;
  authFailure.result = null;
  authFailure.expectedProjection = 'ADMISSION_UNKNOWN';
  assert.deepEqual(evaluateAdmissionLookupCase(authFailure), accepted());
  authFailure.inFlightCount = 2;
  assert.deepEqual(evaluateAdmissionLookupCase(authFailure), rejected());
});
