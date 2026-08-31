import {compareUtf16, jsonEqual} from './canonical.mjs';

const ROUTE_VARIANTS = Object.freeze([
  'PUBLIC_CONNECTED',
  'PUBLIC_DISCONNECTED',
  'COALESCED',
  'REJECTED',
  'INTERNAL',
]);
const BRIDGE_POINT_KINDS = Object.freeze([
  'BEFORE_OWNER_STATE_WRITE',
  'AFTER_OWNER_STATE_BEFORE_EVENT_FACT',
  'AFTER_EVENT_FACT_BEFORE_OUTBOX',
  'AFTER_OUTBOX_BEFORE_COMMIT',
]);
const DOMAIN_MACHINES_BY_ROUTE = Object.freeze({
  'sync.gap.v1': [],
  'materialization.begin.v1:TIMELINE': ['SM-MATERIALIZATION'],
  'materialization.page.v1:TIMELINE': ['SM-MATERIALIZATION'],
  'materialization.commit.v1:TIMELINE': [
    'SM-MATERIALIZATION',
    'SM-TIMELINE-HEAD',
  ],
  'operation.state.v1': [
    'SM-OPERATION',
    'SM-DISPATCH-ATTEMPT',
    'SM-EFFECT-OBSERVATION',
    'SM-RECONCILE',
  ],
  'queue.snapshot.v1': ['SM-QUEUE-ENTRY'],
  'interaction.snapshot.v1': ['SM-INTERACTION', 'SM-CLAIM'],
});
const COORDINATE_EXEMPTIONS = new Set([
  'MOBILE.protected_local_intent.state',
  'BRIDGE.content_offer.state',
]);

function fail(path, message) {
  throw new TypeError(`${path}: ${message}`);
}

function caseKey(value) {
  return [
    value.routeRef?.registryId ?? '',
    value.coordinate?.machineId ?? '',
    value.coordinate?.from ?? '',
    value.coordinate?.to ?? '',
    value.routeVariant ?? '',
  ].join('\u0000');
}

function binding(machineAuthority, registryId) {
  const value = machineAuthority.storageBindings.find((candidate) =>
    candidate.registryId === registryId);
  if (!value) fail('transactionOracle.storageBindings', `missing ${registryId}`);
  return value;
}

function coordinateIdsForOwner(machineAuthority, coordinate) {
  const machine = machineAuthority.machineRecords.find((candidate) =>
    candidate.machineId === coordinate.machineId);
  if (!machine) fail('transactionOracle.coordinate', `unknown ${coordinate.machineId}`);
  const storage = binding(machineAuthority, machine.storageBindingRef.registryId);
  if (coordinate.machineId === 'SM-READ-ATTEMPT' &&
      coordinate.from === 'VERIFYING' && coordinate.to === 'VERIFIED') {
    return [
      'BRIDGE.timeline_read_attempt.state',
      'BRIDGE.timeline_read_evidence.immutable',
    ];
  }
  if (coordinate.machineId === 'SM-RECONCILE') {
    return [coordinate.to === 'REQUESTED'
      ? 'BRIDGE.reconcile_attempt.immutable'
      : 'BRIDGE.reconcile_resolution.immutable'];
  }
  if (storage.physicalCoordinates.length === 0) {
    fail('transactionOracle.coordinate', `${coordinate.machineId} has no physical owner write`);
  }
  return [storage.physicalCoordinates[0].coordinateId];
}

function expectedBridgeWrites(machineAuthority, applicability, shape) {
  const rows = coordinateIdsForOwner(machineAuthority, applicability.coordinate).map((coordinateId) => ({
    writeRole: 'OWNER_STATE',
    coordinateId,
  }));
  if (shape === 'connected') {
    rows.push({writeRole: 'OWNER_STATE', coordinateId: 'BRIDGE.durable_delivery_head.state'});
  }
  if (shape !== 'quiet') {
    rows.push({writeRole: 'EVENT_FACT', coordinateId: 'BRIDGE.event_fact.immutable'});
  }
  if (shape === 'connected') {
    rows.push({writeRole: 'OUTBOX_ENVELOPE', coordinateId: 'BRIDGE.outbox_envelope.immutable'});
  }
  return rows;
}

function validateBridgeManifests(machineAuthority, authority) {
  const expectedCases = new Set();
  for (const machine of machineAuthority.machineRecords) {
    if (machine.machineId === 'SM-DURABLE-DELIVERY') continue;
    for (const routeRef of machine.authoritativeRouteRefs) {
      for (const edge of machine.allowedEdges) {
        for (const routeVariant of ROUTE_VARIANTS) {
          expectedCases.add(caseKey({
            routeRef,
            coordinate: {machineId: machine.machineId, ...edge},
            routeVariant,
          }));
        }
      }
    }
  }

  const actualCases = new Set();
  const bridge = authority.transactionManifests.filter((manifest) =>
    manifest.manifestId.startsWith('tx.bridge.'));
  for (const manifest of bridge) {
    const shape = manifest.manifestId.split('.').at(-1);
    const expectedVariants = shape === 'connected'
      ? ['PUBLIC_CONNECTED']
      : shape === 'disconnected'
        ? ['PUBLIC_DISCONNECTED']
        : shape === 'quiet'
          ? ['COALESCED', 'REJECTED', 'INTERNAL']
          : null;
    if (expectedVariants === null || manifest.applicabilityCases.length !== expectedVariants.length) {
      fail(manifest.manifestId, 'invalid authoritative manifest shape');
    }
    const first = manifest.applicabilityCases[0];
    if (!jsonEqual(manifest.applicabilityCases.map((row) => row.routeVariant), expectedVariants) ||
        manifest.applicabilityCases.some((row) =>
          !jsonEqual(row.coordinate, first.coordinate) ||
          !jsonEqual(row.routeRef, first.routeRef))) {
      fail(manifest.manifestId, 'applicability partition is not the exact shape');
    }
    for (const row of manifest.applicabilityCases) {
      const key = caseKey(row);
      if (!expectedCases.has(key) || actualCases.has(key)) {
        fail(manifest.manifestId, `unexpected or duplicate case ${key}`);
      }
      actualCases.add(key);
    }
    if (manifest.segments.length !== 1 ||
        manifest.segments[0].segmentKind !== 'SQL_TRANSACTION' ||
        manifest.segments[0].transactionRole !== 'AUTHORITATIVE_OWNER') {
      fail(manifest.manifestId, 'authoritative manifest needs one owner SQL segment');
    }
    const actualWrites = manifest.segments[0].writes.map((write) => ({
      writeRole: write.writeRole,
      coordinateId: write.physicalStorageCoordinateRef.coordinateId,
    }));
    const expectedWrites = expectedBridgeWrites(machineAuthority, first, shape);
    if (!jsonEqual(actualWrites, expectedWrites)) {
      fail(manifest.manifestId, 'physical writes do not match the independent edge plan');
    }
    for (const write of manifest.segments[0].writes) {
      const expectedCardinality = write.writeRole === 'OUTBOX_ENVELOPE'
        ? {cardinalityKind: 'CONTEXT_COUNT', countKind: 'ELIGIBLE_ENVELOPE_COUNT'}
        : {cardinalityKind: 'EXACT', rows: 1};
      if (!jsonEqual(write.rowCardinality, expectedCardinality)) {
        fail(write.writeId, 'wrong independent row cardinality');
      }
    }
  }
  if (actualCases.size !== expectedCases.size) {
    fail('transactionOracle.applicabilityCases',
      `expected ${expectedCases.size}, got ${actualCases.size}`);
  }
  return {bridgeManifestCount: bridge.length, authoritativeCaseCount: expectedCases.size};
}

function validateMobileManifests(machineAuthority, authority) {
  const mobile = authority.transactionManifests.filter((manifest) =>
    manifest.manifestId.startsWith('tx.mobile.'));
  if (mobile.length !== machineAuthority.projectionRoutes.length) {
    fail('transactionOracle.mobile', 'expected one manifest per route');
  }
  for (const route of machineAuthority.projectionRoutes) {
    const manifest = mobile.find((candidate) =>
      candidate.applicabilityCases[0]?.routeRef?.registryId === route.registryId);
    if (!manifest || manifest.applicabilityCases.length !== 1) {
      fail('transactionOracle.mobile', `missing exact ${route.registryId}`);
    }
    const domainMachines = DOMAIN_MACHINES_BY_ROUTE[route.registryId];
    if (domainMachines === undefined) fail('transactionOracle.mobile', `unknown ${route.registryId}`);
    const expectedRoles = [
      'DURABLE_INBOX_STAGING',
      ...(domainMachines.length > 0 ? ['DURABLE_DOMAIN_STAGING'] : []),
      'FINAL_REPLICA_APPLY',
      'READBACK',
      'READBACK_STATE_CAS',
      'PUBLICATION',
      'PUBLICATION_STATE_CAS',
      'ACK',
      'ACK_STATE_CAS',
    ];
    const actualRoles = manifest.segments.map((segment) =>
      segment.segmentKind === 'SQL_TRANSACTION'
        ? segment.transactionRole
        : segment.segmentKind);
    if (!jsonEqual(actualRoles, expectedRoles)) {
      fail(manifest.manifestId, 'wrong independent Mobile 8/9 segment shape');
    }
    const final = manifest.segments.find((segment) =>
      segment.transactionRole === 'FINAL_REPLICA_APPLY');
    const actualDomain = final.writes.filter((write) =>
      write.writeRole === 'DOMAIN_REPLICA').map((write) => write.bindingKey.machineId);
    if (!jsonEqual(actualDomain, domainMachines)) {
      fail(manifest.manifestId, 'wrong independent Mobile domain binding set');
    }
  }
  return {mobileManifestCount: mobile.length};
}

function expectedSteps(manifest) {
  const rows = [];
  let stepOrdinal = 0;
  for (const segment of manifest.segments) {
    if (segment.segmentKind === 'SQL_TRANSACTION') {
      rows.push({stepOrdinal, segment, stepKind: 'TX_BEGIN'});
      stepOrdinal += 1;
      for (const write of segment.writes) {
        rows.push({stepOrdinal, segment, stepKind: 'WRITE', write});
        stepOrdinal += 1;
      }
      rows.push({stepOrdinal, segment, stepKind: 'TX_COMMIT'});
      stepOrdinal += 1;
    } else {
      rows.push({stepOrdinal, segment, stepKind: segment.segmentKind});
      stepOrdinal += 1;
    }
  }
  return rows;
}

function expectedFailureOracle(after, before) {
  const segment = after.segment;
  if (after.stepKind === 'TX_BEGIN' || after.stepKind === 'WRITE') {
    return {
      oracleKind: 'ROLLBACK_OPEN_TRANSACTION',
      durablePostStateProjectionRef: segment.entryDurablePostStateProjectionRef,
      resumeSegmentOrdinal: segment.segmentOrdinal,
    };
  }
  if (after.stepKind === 'TX_COMMIT') {
    return {
      oracleKind: 'DURABLE_COMMIT_IDEMPOTENT_REPLAY',
      durablePostStateProjectionRef: segment.commitPostStateProjectionRef,
      resumeSegmentOrdinal: before.segment.segmentOrdinal,
    };
  }
  return {
    oracleKind: 'EXTERNAL_EFFECT_MAY_HAVE_OCCURRED',
    effectKind: after.stepKind,
    replayRule: segment.replayRule,
    durablePostStateProjectionRef: segment.durablePostStateProjectionRef,
    resumeSegmentOrdinal: before.segment.segmentOrdinal,
  };
}

function validateDerivedFailureUniverse(authority) {
  const actualSteps = new Map(authority.transactionSteps.map((row) => [row.stepId, row]));
  const actualKills = new Map(authority.transactionKillPoints.map((row) => [row.killPointId, row]));
  let stepCount = 0;
  let killPointCount = 0;
  for (const manifest of authority.transactionManifests) {
    const steps = expectedSteps(manifest);
    stepCount += steps.length;
    killPointCount += steps.length - 1;
    for (const expected of steps) {
      const stepId = `${manifest.manifestId}:P${expected.stepOrdinal}`;
      const actual = actualSteps.get(stepId);
      if (!actual || actual.stepOrdinal !== expected.stepOrdinal ||
          actual.segmentOrdinal !== expected.segment.segmentOrdinal ||
          actual.stepKind !== expected.stepKind ||
          (expected.write && (actual.writeId !== expected.write.writeId ||
            actual.writeRole !== expected.write.writeRole))) {
        fail(stepId, 'derived step does not match independent flattening');
      }
    }
    for (let index = 0; index + 1 < steps.length; index += 1) {
      const after = steps[index];
      const before = steps[index + 1];
      const killPointId = `${manifest.manifestId}:K${after.stepOrdinal}`;
      const actual = actualKills.get(killPointId);
      if (!actual || actual.afterStepId !== `${manifest.manifestId}:P${after.stepOrdinal}` ||
          actual.beforeStepId !== `${manifest.manifestId}:P${before.stepOrdinal}` ||
          actual.afterStepOrdinal !== after.stepOrdinal ||
          actual.beforeStepOrdinal !== before.stepOrdinal ||
          !jsonEqual(actual.failureOracle, expectedFailureOracle(after, before))) {
        fail(killPointId, 'kill point does not match independent adjacency/oracle');
      }
    }
  }
  if (actualSteps.size !== stepCount || actualKills.size !== killPointCount) {
    fail('transactionOracle.failureUniverse',
      `expected ${stepCount}/${killPointCount}, got ${actualSteps.size}/${actualKills.size}`);
  }
  return {stepCount, killPointCount};
}

function validateBridgeAliases(machineAuthority, authority) {
  const expectedIds = [];
  for (const route of machineAuthority.projectionRoutes) {
    for (const pointKind of BRIDGE_POINT_KINDS) {
      expectedIds.push(`${route.registryId}:${pointKind}`);
    }
  }
  if (!jsonEqual(authority.bridgeRoutePointBindings.map((row) => row.bridgeMarkerId), expectedIds)) {
    fail('transactionOracle.bridgeAliases', 'wrong route/point exact order');
  }
  const killPoints = new Map(authority.transactionKillPoints.map((row) => [
    row.killPointId,
    row,
  ]));
  for (const row of authority.bridgeRoutePointBindings) {
    const killPoint = killPoints.get(row.transactionKillPointId);
    if (!killPoint || !jsonEqual(killPoint.manifestRef, row.manifestRef) ||
        killPoint.beforeStepOrdinal !== killPoint.afterStepOrdinal + 1) {
      fail(row.bridgeMarkerId, 'does not resolve one adjacent kill point');
    }
  }
  return {bridgeAliasCount: expectedIds.length};
}

function validateCoordinateClosure(machineAuthority, authority) {
  const consumed = new Set();
  for (const manifest of authority.transactionManifests) {
    for (const segment of manifest.segments) {
      if (segment.segmentKind !== 'SQL_TRANSACTION') continue;
      for (const write of segment.writes) {
        consumed.add(write.physicalStorageCoordinateRef.coordinateId);
      }
    }
  }
  for (const storage of machineAuthority.storageBindings) {
    for (const coordinate of storage.physicalCoordinates) {
      if (!COORDINATE_EXEMPTIONS.has(coordinate.coordinateId) &&
          !consumed.has(coordinate.coordinateId)) {
        fail('transactionOracle.coordinateClosure', `unconsumed ${coordinate.coordinateId}`);
      }
    }
  }
}

export function validateIndependentTransactionAuthority(machineAuthority, authority) {
  const bridge = validateBridgeManifests(machineAuthority, authority);
  const mobile = validateMobileManifests(machineAuthority, authority);
  const failure = validateDerivedFailureUniverse(authority);
  const aliases = validateBridgeAliases(machineAuthority, authority);
  validateCoordinateClosure(machineAuthority, authority);
  const expectedManifestCount = bridge.authoritativeCaseCount / ROUTE_VARIANTS.length * 3 +
    mobile.mobileManifestCount;
  const expectedCaseCount = bridge.authoritativeCaseCount + mobile.mobileManifestCount;
  if (authority.transactionManifests.length !== expectedManifestCount) {
    fail('transactionOracle.manifests', `expected ${expectedManifestCount}`);
  }
  return {
    manifestCount: expectedManifestCount,
    applicabilityCaseCount: expectedCaseCount,
    ...failure,
    ...aliases,
  };
}

export function transactionVectorSubjects(authority) {
  const mobile = authority.transactionManifests.filter((manifest) =>
    manifest.manifestId.startsWith('tx.mobile.'));
  const values = new Map([
    ['MANIFEST_SET_EXACT', authority.transactionManifests.map((row) => row.manifestId)],
    ['KILL_POINT_SET_EXACT', authority.transactionKillPoints.map((row) => row.killPointId)],
    ['BRIDGE_MAPPING_EXACT', authority.bridgeRoutePointBindings.map((row) => row.bridgeMarkerId)],
    ['MOBILE_SHAPE_EXACT', mobile.map((row) => row.manifestId)],
  ]);
  return new Map([...values].map(([caseKind, subjectIds]) => [caseKind, {
    caseKind,
    subjectCount: subjectIds.length,
    subjectIds: [...subjectIds].sort(compareUtf16),
  }]));
}

export function validateTransactionAuthorityVectors(authority, activeVectors) {
  const subjects = transactionVectorSubjects(authority);
  const expected = new Map();
  for (const [caseKind, value] of subjects) {
    const stem = caseKind.toLowerCase().replaceAll('_', '-');
    expected.set(`transaction.authority.${stem}.positive`, value);
    expected.set(`transaction.authority.${stem.replace('-exact', '-drift')}.negative`, {
      caseKind: caseKind.replace('_EXACT', '_DRIFT'),
      subjectCount: value.subjectCount,
      subjectIds: [],
    });
  }
  const actual = activeVectors.filter((vector) =>
    vector.vectorSetRef === 'vectors.transaction-authority');
  if (actual.length !== expected.size || actual.some((vector) => !expected.has(vector.id))) {
    fail('vectors.transactionAuthority', `expected ${expected.size} exact vectors`);
  }
  for (const vector of actual) {
    if (vector.ruleRef !== 'rule.transaction.authority' ||
        vector.typeRef !== 'TransactionAuthorityCaseV1' ||
        !jsonEqual(vector.value, expected.get(vector.id))) {
      fail(`vectors.${vector.id}`, 'transaction vector ID does not bind its exact subject');
    }
  }
}

export {DOMAIN_MACHINES_BY_ROUTE as INDEPENDENT_DOMAIN_MACHINES_BY_ROUTE};
