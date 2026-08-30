import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';

import {buildExpectedMachineAuthority} from '../src/machine-semantics.mjs';
import {
  buildExpectedTransactionAuthority,
  evaluateTransactionAuthorityCase,
  validateTransactionAuthorityRegistry,
} from '../src/transaction-semantics.mjs';

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

function expected() {
  const machine = buildExpectedMachineAuthority();
  const transaction = buildExpectedTransactionAuthority(machine);
  return {machine, transaction};
}

function registry() {
  return JSON.parse(readFileSync(registryUrl, 'utf8'));
}

test('normalizes the exact B2 transaction universe and all derived rows', () => {
  const {transaction} = expected();
  assert.equal(transaction.transactionAuxiliaryStorageBindings.length, 3);
  assert.equal(transaction.transactionGuards.length, 387);
  assert.equal(transaction.transactionOracleProjections.length, 27);
  assert.equal(transaction.transactionManifests.length, 235);
  assert.equal(transaction.transactionSteps.length, 1102);
  assert.equal(transaction.transactionKillPoints.length, 867);
  assert.equal(transaction.bridgeRoutePointBindings.length, 28);
  assert.equal(
    transaction.transactionManifests.reduce(
      (count, manifest) => count + manifest.applicabilityCases.length,
      0,
    ),
    387,
  );
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
    'EVENT_FACT',
    'OUTBOX_ENVELOPE',
  ]);
  assert.deepEqual(roles(byShape('disconnected')), ['OWNER_STATE', 'EVENT_FACT']);
  assert.deepEqual(roles(byShape('quiet')), ['OWNER_STATE']);
  assert.deepEqual(byShape('connected').segments[0].writes[2].rowCardinality, {
    cardinalityKind: 'CONTEXT_COUNT',
    countKind: 'ELIGIBLE_ENVELOPE_COUNT',
  });
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
