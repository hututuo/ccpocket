import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';

import {buildExpectedMachineAuthority} from '../src/machine-semantics.mjs';
import {
  buildExpectedTransactionAuthority,
  deriveTransactionKillPoints,
  deriveTransactionSteps,
  evaluateTransactionAuthorityCase,
  validateTransactionAuthorityRegistry,
} from '../src/transaction-semantics.mjs';
import {
  validateIndependentTransactionAuthority,
  validateTransactionAuthorityVectors,
} from '../src/transaction-oracle.mjs';

// Deliberately duplicated from the accepted ruling instead of imported from
// transaction-semantics, so implementation drift cannot self-certify.
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

const registryUrl = new URL(
  '../../../docs/design/codex-kernel-v4/contracts/contract-registry.json',
  import.meta.url,
);
const vectorsUrl = new URL(
  '../../../docs/design/codex-kernel-v4/contracts/vectors/phone-core-vectors.json',
  import.meta.url,
);

function expected() {
  const machine = buildExpectedMachineAuthority();
  const transaction = buildExpectedTransactionAuthority(machine);
  return {machine, transaction};
}

function registry() {
  return JSON.parse(readFileSync(registryUrl, 'utf8'));
}

function vectors() {
  return JSON.parse(readFileSync(vectorsUrl, 'utf8')).vectors;
}

function machineWithAuxiliary(machine, transaction) {
  return {
    ...machine,
    storageBindings: [
      ...machine.storageBindings,
      ...transaction.transactionAuxiliaryStorageBindings,
    ],
  };
}

test('normalizes the exact B2 transaction universe and all derived rows', () => {
  const {transaction} = expected();
  assert.equal(transaction.transactionAuxiliaryStorageBindings.length, 3);
  assert.equal(transaction.transactionGuards.length, 387);
  assert.equal(transaction.transactionOracleProjections.length, 27);
  assert.equal(transaction.transactionManifests.length, 235);
  assert.equal(transaction.transactionSteps.length, 1181);
  assert.equal(transaction.transactionKillPoints.length, 946);
  assert.equal(transaction.bridgeRoutePointBindings.length, 28);
  assert.equal(
    transaction.transactionManifests.reduce(
      (count, manifest) => count + manifest.applicabilityCases.length,
      0,
    ),
    387,
  );
});

test('independent transaction oracle re-derives cover, writes, steps, and aliases', () => {
  const {machine, transaction} = expected();
  assert.deepEqual(
    validateIndependentTransactionAuthority(
      machineWithAuxiliary(machine, transaction),
      transaction,
    ),
    {
      manifestCount: 235,
      applicabilityCaseCount: 387,
      stepCount: 1181,
      killPointCount: 946,
      bridgeAliasCount: 28,
    },
  );

  const drift = structuredClone(transaction);
  const reconcile = drift.transactionManifests.find((manifest) =>
    manifest.applicabilityCases[0].coordinate.machineId === 'SM-RECONCILE' &&
    manifest.applicabilityCases[0].coordinate.to === 'EXECUTED_MATCHED');
  reconcile.segments[0].writes[0].physicalStorageCoordinateRef.coordinateId =
    'BRIDGE.reconcile_attempt.immutable';
  assert.throws(
    () => validateIndependentTransactionAuthority(
      machineWithAuxiliary(machine, drift),
      drift,
    ),
    /independent Bridge law/,
  );
});

test('independent Bridge law rejects candidate-derived manifest and failure drift', () => {
  const {machine, transaction} = expected();
  const mutations = [
    (manifest) => { manifest.segments[0].segmentId = 'segment.drift'; },
    (manifest) => { manifest.segments[0].writes[0].writeId = 'write.drift'; },
    (manifest) => {
      const success = structuredClone(manifest.segments[0].commitPostStateProjectionRef);
      manifest.initialDurablePostStateProjectionRef = structuredClone(success);
      manifest.segments[0].entryDurablePostStateProjectionRef = success;
    },
    (manifest) => {
      manifest.segments[0].commitPostStateProjectionRef = structuredClone(
        manifest.segments[0].entryDurablePostStateProjectionRef,
      );
    },
    (manifest) => {
      manifest.applicabilityCases[0].bindingKey.machineId = 'SM-DURABLE-DELIVERY';
    },
    (manifest) => {
      manifest.applicabilityCases[0].guardRefs[0].registryId = 'guard.drift';
    },
    (manifest) => {
      manifest.segments[0].coordinatorBindingKey.machineId = 'SM-DURABLE-DELIVERY';
    },
    (manifest) => {
      manifest.segments[0].writes[0].bindingKey.machineId = 'SM-DURABLE-DELIVERY';
    },
    (manifest) => {
      manifest.segments[0].writes[0].physicalStorageCoordinateRef.storageBindingRef.registryId =
        'storage.authoritative.sm-durable-delivery';
    },
  ];
  for (const mutate of mutations) {
    const drift = structuredClone(transaction);
    const bridge = drift.transactionManifests.find((manifest) =>
      manifest.manifestId.endsWith('.disconnected'));
    mutate(bridge);
    drift.transactionSteps = deriveTransactionSteps(drift.transactionManifests);
    drift.transactionKillPoints = deriveTransactionKillPoints(
      drift.transactionManifests,
      drift.transactionSteps,
    );
    assert.throws(
      () => validateIndependentTransactionAuthority(
        machineWithAuxiliary(machine, drift),
        drift,
      ),
      /independent Bridge law/,
    );
  }
});

test('independent manifest universe rejects cross-group order and derived failure drift', () => {
  const {machine, transaction} = expected();
  const drift = structuredClone(transaction);
  const mobileIndex = drift.transactionManifests.findIndex((manifest) =>
    manifest.manifestId === 'tx.mobile.00.apply');
  assert.notEqual(mobileIndex, -1);
  const [mobile] = drift.transactionManifests.splice(mobileIndex, 1);
  drift.transactionManifests.splice(100, 0, mobile);
  drift.transactionSteps = deriveTransactionSteps(drift.transactionManifests);
  drift.transactionKillPoints = deriveTransactionKillPoints(
    drift.transactionManifests,
    drift.transactionSteps,
  );
  assert.throws(
    () => validateIndependentTransactionAuthority(
      machineWithAuxiliary(machine, drift),
      drift,
    ),
    /manifest inventory does not exact-equal independent order/,
  );
});

test('independent Mobile law rejects a self-consistent candidate and derived failure drift', () => {
  const {machine, transaction} = expected();
  const mutations = [
    (manifest) => { manifest.manifestId = 'tx.mobile.00.drift'; },
    (manifest) => { manifest.applicabilityCases[0].guardRefs[0].registryId = 'guard.drift'; },
    (manifest) => { manifest.segments[0].segmentId = 'segment.drift'; },
    (manifest) => { manifest.segments[0].segmentOrdinal = 1; },
    (manifest) => {
      manifest.segments[0].entryDurablePostStateProjectionRef.registryId = 'oracle.drift';
    },
    (manifest) => {
      manifest.segments[0].commitPostStateProjectionRef.registryId = 'oracle.drift';
    },
    (manifest) => { manifest.segments[0].writes[0].writeId = 'write.drift'; },
    (manifest) => { manifest.segments[0].writes[0].writeRole = 'PROGRESS_METADATA'; },
    (manifest) => {
      manifest.segments[0].writes[0].bindingKey.machineId = 'SM-OPERATION';
    },
    (manifest) => {
      manifest.segments[0].writes[0].physicalStorageCoordinateRef.coordinateId =
        'MOBILE.m_apply_batch.progress';
    },
    (manifest) => {
      manifest.segments[0].writes[0].rowCardinality = {
        cardinalityKind: 'EXACT',
        rows: 1,
      };
    },
    (manifest) => {
      manifest.segments.find((segment) => segment.segmentKind === 'READBACK').replayRule =
        'IDEMPOTENT_BY_REPOSITORY_PUBLICATION_ID';
    },
  ];
  for (const mutate of mutations) {
    const drift = structuredClone(transaction);
    const mobile = drift.transactionManifests.find((manifest) =>
      manifest.manifestId === 'tx.mobile.00.apply');
    mutate(mobile);
    drift.transactionSteps = deriveTransactionSteps(drift.transactionManifests);
    drift.transactionKillPoints = deriveTransactionKillPoints(
      drift.transactionManifests,
      drift.transactionSteps,
    );
    assert.throws(
      () => validateIndependentTransactionAuthority(
        machineWithAuxiliary(machine, drift),
        drift,
      ),
      /independent route law/,
    );
  }
});

test('durable sync.gap publication is persisted by ReadAttempt, never memory-only GapRepair', () => {
  const {machine} = expected();
  const readAttempt = machine.machineRecords.find((row) => row.machineId === 'SM-READ-ATTEMPT');
  const gapRepair = machine.machineRecords.find((row) => row.machineId === 'SM-GAP-REPAIR');
  assert.deepEqual(readAttempt.authoritativeRouteRefs, [{
    refKind: 'PROJECTION_ROUTE',
    registryId: 'sync.gap.v1',
  }]);
  assert.deepEqual(gapRepair.authoritativeRouteRefs, []);
  assert.equal(gapRepair.storageBindingRef.registryId, 'storage.authoritative.sm-gap-repair');
  assert.equal(
    machine.storageBindings.find((row) =>
      row.registryId === gapRepair.storageBindingRef.registryId).storageMode,
    'MEMORY_ONLY',
  );
});

test('every authoritative edge-route pair has one closed five-way variant partition', () => {
  const {machine, transaction} = expected();
  const authoritativeCases = transaction.transactionManifests
    .filter((manifest) => manifest.manifestId.startsWith('tx.bridge.'))
    .flatMap((manifest) => manifest.applicabilityCases);
  const expectedPairs = machine.machineRecords
    .filter((row) => row.machineId !== 'SM-DURABLE-DELIVERY')
    .reduce((count, machineRow) =>
      count + machineRow.allowedEdges.length * machineRow.authoritativeRouteRefs.length,
    0);
  assert.equal(expectedPairs, 76);
  assert.equal(authoritativeCases.length, expectedPairs * ROUTE_VARIANTS.length);
  const partitions = new Map();
  for (const row of authoritativeCases) {
    const key = `${row.routeRef.registryId}\u0000${row.coordinate.machineId}\u0000${
      row.coordinate.from}\u0000${row.coordinate.to}`;
    const variants = partitions.get(key) ?? [];
    variants.push(row.routeVariant);
    partitions.set(key, variants);
  }
  assert.equal(partitions.size, expectedPairs);
  for (const variants of partitions.values()) {
    assert.deepEqual(variants.sort(), [...ROUTE_VARIANTS].sort());
  }
});

test('R77 physical writes are exact for connected, disconnected, and quiet branches', () => {
  const {transaction} = expected();
  const byShape = (shape) => transaction.transactionManifests.find((manifest) =>
    manifest.manifestId.startsWith('tx.bridge.') && manifest.manifestId.endsWith(`.${shape}`));
  const roles = (manifest) => manifest.segments[0].writes.map((write) => write.writeRole);
  assert.deepEqual(roles(byShape('connected')), [
    'OWNER_STATE',
    'OWNER_STATE',
    'EVENT_FACT',
    'OUTBOX_ENVELOPE',
  ]);
  assert.deepEqual(roles(byShape('disconnected')), ['OWNER_STATE', 'EVENT_FACT']);
  assert.deepEqual(roles(byShape('quiet')), ['OWNER_STATE']);
  assert.deepEqual(byShape('connected').segments[0].writes[3].rowCardinality, {
    cardinalityKind: 'CONTEXT_COUNT',
    countKind: 'ELIGIBLE_ENVELOPE_COUNT',
  });
});

test('edge-specific owner plans consume delivery head, read evidence, and reconcile facts', () => {
  const {transaction} = expected();
  const coordinateRefs = transaction.transactionManifests.flatMap((manifest) =>
    manifest.segments.flatMap((segment) => segment.segmentKind === 'SQL_TRANSACTION'
      ? segment.writes.map((write) => ({
          manifestId: manifest.manifestId,
          applicability: manifest.applicabilityCases[0],
          coordinateId: write.physicalStorageCoordinateRef.coordinateId,
        }))
      : []));
  const count = (coordinateId) => coordinateRefs.filter((row) =>
    row.coordinateId === coordinateId).length;
  assert.equal(count('BRIDGE.durable_delivery_head.state'), 76);
  assert.equal(count('BRIDGE.timeline_read_evidence.immutable'), 3);
  assert.equal(count('BRIDGE.reconcile_attempt.immutable'), 6);
  assert.equal(count('BRIDGE.reconcile_resolution.immutable'), 12);

  for (const row of coordinateRefs.filter((candidate) =>
    candidate.applicability.coordinate.machineId === 'SM-RECONCILE' &&
    candidate.coordinateId.startsWith('BRIDGE.reconcile_'))) {
    assert.equal(
      row.coordinateId,
      row.applicability.coordinate.to === 'REQUESTED'
        ? 'BRIDGE.reconcile_attempt.immutable'
        : 'BRIDGE.reconcile_resolution.immutable',
      row.manifestId,
    );
  }
});

test('the 28 Bridge aliases select real, distinct adjacent transaction kill points', () => {
  const {transaction} = expected();
  const killPoints = new Map(transaction.transactionKillPoints.map((row) => [
    row.killPointId,
    row,
  ]));
  assert.equal(new Set(transaction.bridgeRoutePointBindings.map((row) =>
    row.transactionKillPointId)).size, 28);
  for (let routeOrdinal = 0; routeOrdinal < 7; routeOrdinal += 1) {
    const rows = transaction.bridgeRoutePointBindings.slice(
      routeOrdinal * 4,
      routeOrdinal * 4 + 4,
    );
    assert.deepEqual(rows.map((row) => row.pointKind), [...BRIDGE_POINT_KINDS]);
    for (const row of rows) {
      const killPoint = killPoints.get(row.transactionKillPointId);
      assert.ok(killPoint, row.bridgeMarkerId);
      assert.deepEqual(killPoint.manifestRef, row.manifestRef);
      assert.equal(killPoint.beforeStepOrdinal, killPoint.afterStepOrdinal + 1);
    }
  }
});

test('Bridge aliases reject adjacent redirects, swaps, and cross-route bindings', () => {
  const {machine, transaction} = expected();
  const mutations = [
    (drift) => {
      drift.bridgeRoutePointBindings[0].transactionKillPointId =
        'tx.bridge.00.01.000.connected:K1';
    },
    (drift) => {
      const first = drift.bridgeRoutePointBindings[0].transactionKillPointId;
      drift.bridgeRoutePointBindings[0].transactionKillPointId =
        drift.bridgeRoutePointBindings[1].transactionKillPointId;
      drift.bridgeRoutePointBindings[1].transactionKillPointId = first;
    },
    (drift) => {
      const foreign = drift.bridgeRoutePointBindings[4];
      drift.bridgeRoutePointBindings[0].manifestRef = structuredClone(foreign.manifestRef);
      drift.bridgeRoutePointBindings[0].transactionKillPointId = foreign.transactionKillPointId;
    },
    (drift) => {
      drift.bridgeRoutePointBindings[0].applicabilityCaseOrdinal = 1;
    },
  ];
  for (const mutate of mutations) {
    const drift = structuredClone(transaction);
    mutate(drift);
    assert.throws(
      () => validateIndependentTransactionAuthority(
        machineWithAuxiliary(machine, drift),
        drift,
      ),
      /aliases do not exact-equal canonical boundaries/,
    );
  }
});

test('Mobile manifests have exact 8/9 segments and route-specific domain bindings', () => {
  const {machine, transaction} = expected();
  for (const route of machine.projectionRoutes) {
    const manifest = transaction.transactionManifests.find((row) =>
      row.manifestId === `tx.mobile.${String(route.normativeOrdinal).padStart(2, '0')}.apply`);
    const expectedDomainMachines = DOMAIN_MACHINES_BY_ROUTE[route.registryId];
    assert.equal(manifest.segments.length, expectedDomainMachines.length === 0 ? 8 : 9);
    assert.equal(
      manifest.segments.filter((segment) =>
        segment.transactionRole === 'DURABLE_DOMAIN_STAGING').length,
      expectedDomainMachines.length === 0 ? 0 : 1,
    );
    const final = manifest.segments.find((segment) =>
      segment.transactionRole === 'FINAL_REPLICA_APPLY');
    assert.deepEqual(
      final.writes.filter((write) => write.writeRole === 'DOMAIN_REPLICA')
        .map((write) => write.bindingKey.machineId),
      expectedDomainMachines,
    );
  }
});

test('kill-point oracles preserve earlier commits and fence external effects', () => {
  const {transaction} = expected();
  const mobile = transaction.transactionManifests.find((row) =>
    row.manifestId === 'tx.mobile.04.apply');
  const killPoints = transaction.transactionKillPoints.filter((row) =>
    row.manifestRef.registryId === mobile.manifestId);
  assert.ok(killPoints.some((row) =>
    row.failureOracle.oracleKind === 'ROLLBACK_OPEN_TRANSACTION' &&
    row.failureOracle.resumeSegmentOrdinal === 1));
  assert.ok(killPoints.some((row) =>
    row.failureOracle.oracleKind === 'DURABLE_COMMIT_IDEMPOTENT_REPLAY' &&
    row.failureOracle.resumeSegmentOrdinal === 1));
  assert.deepEqual(
    killPoints.filter((row) =>
      row.failureOracle.oracleKind === 'EXTERNAL_EFFECT_MAY_HAVE_OCCURRED')
      .map((row) => row.failureOracle.effectKind),
    ['READBACK', 'PUBLICATION', 'ACK'],
  );
});

test('Registry transaction inventories reject independent manifest and storage drift', () => {
  const value = registry();
  const machine = buildExpectedMachineAuthority();
  machine.storageBindings = value.storageBindings;
  assert.doesNotThrow(() => validateTransactionAuthorityRegistry(value, machine));

  const missingManifest = structuredClone(value);
  missingManifest.transactionManifests.pop();
  const machineForMissing = buildExpectedMachineAuthority();
  machineForMissing.storageBindings = missingManifest.storageBindings;
  assert.throws(
    () => validateTransactionAuthorityRegistry(missingManifest, machineForMissing),
    /transactionManifests/,
  );

  const wrongStorage = structuredClone(value);
  wrongStorage.storageBindings.find((row) =>
    row.registryId === 'storage.transaction.sm-replica-apply.commit')
    .physicalCoordinates[0].tableName = 'wrong_checkpoint';
  const machineForStorage = buildExpectedMachineAuthority();
  machineForStorage.storageBindings = wrongStorage.storageBindings;
  assert.throws(
    () => validateTransactionAuthorityRegistry(wrongStorage, machineForStorage),
    /transactionAuxiliary/,
  );

  const machineEnumDrift = structuredClone(value);
  machineEnumDrift.definitions.find((row) => row.id === 'ActiveMachineIdV1').node.values.pop();
  const machineForEnum = buildExpectedMachineAuthority();
  machineForEnum.storageBindings = machineEnumDrift.storageBindings;
  assert.throws(
    () => validateTransactionAuthorityRegistry(machineEnumDrift, machineForEnum),
    /ActiveMachineIdV1/,
  );

  const boundDrift = structuredClone(value);
  boundDrift.definitions.find((row) =>
    row.id === 'CanonicalTransactionGuardRefSetV1').node.maxItems -= 1;
  const machineForBound = buildExpectedMachineAuthority();
  machineForBound.storageBindings = boundDrift.storageBindings;
  assert.throws(
    () => validateTransactionAuthorityRegistry(boundDrift, machineForBound),
    /derived active guard count/,
  );
});

test('semantic transaction vectors distinguish exact authority from drift markers', () => {
  assert.deepEqual(evaluateTransactionAuthorityCase({caseKind: 'MANIFEST_SET_EXACT'}), {
    valid: true,
    reason: 'NONE',
    postState: 'APPLIED',
    sideEffects: {},
  });
  assert.deepEqual(evaluateTransactionAuthorityCase({caseKind: 'MANIFEST_SET_DRIFT'}), {
    valid: false,
    reason: 'TRANSACTION_AUTHORITY_INVALID',
    postState: 'UNCHANGED',
    sideEffects: {artifacts: 0, durableRows: 0},
  });
});

test('transaction vector IDs bind exact derived subject ID sets', () => {
  const {transaction} = expected();
  const pristine = vectors();
  validateTransactionAuthorityVectors(transaction, pristine);
  const drift = structuredClone(pristine);
  const target = drift.find((vector) =>
    vector.id === 'transaction.authority.kill-point-set-exact.positive');
  target.value = structuredClone(drift.find((vector) =>
    vector.id === 'transaction.authority.manifest-set-exact.positive').value);
  assert.throws(
    () => validateTransactionAuthorityVectors(transaction, drift),
    /does not bind its exact subject/,
  );
});
