import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';

import {canonicalize, digestBytes} from '../src/canonical.mjs';
import {
  decodeMachineTransitionSqlManifest,
  MACHINE_TRANSITION_SQL_TEMPLATE,
  MACHINE_TRANSITION_SQL_TEMPLATE_SHA256,
  renderMachineTransitionSql,
} from '../src/generate-machine-ddl.mjs';
import {
  buildExpectedMachineAuthority,
  deriveForbiddenEdgeMarkers,
  evaluateMachineAuthorityCase,
  loadPvmc1B2NormativeOracle,
  validateMachineAuthorityRegistry,
  validateMachineAuthorityVectors,
} from '../src/machine-semantics.mjs';

const registryUrl = new URL(
  '../../../docs/design/codex-kernel-v4/contracts/contract-registry.json',
  import.meta.url,
);
const vectorsUrl = new URL(
  '../../../docs/design/codex-kernel-v4/contracts/vectors/phone-core-vectors.json',
  import.meta.url,
);

function registry() {
  return JSON.parse(readFileSync(registryUrl, 'utf8'));
}

function vectors() {
  return JSON.parse(readFileSync(vectorsUrl, 'utf8')).vectors;
}

test('B2 independent oracle fixes the exact machine arithmetic', () => {
  const oracle = loadPvmc1B2NormativeOracle();
  assert.deepEqual(oracle.counts, {
    machines: 17,
    stateOccurrences: 123,
    allowedEdges: 151,
    terminals: 64,
    cartesianPairs: 1023,
    forbiddenEdges: 872,
  });
  assert.equal(oracle.durableRoutes.length, 7);
});

test('normalized machine authority derives every edge and forbidden coordinate', () => {
  const authority = buildExpectedMachineAuthority();
  assert.equal(authority.machineRecords.length, 17);
  assert.equal(authority.machineEdgeAuthorities.length, 151);
  assert.equal(authority.edgeGuards.length, 151);
  assert.equal(authority.oracleProjections.length, 123);
  assert.equal(authority.storageBindings.length, 26);
  assert.equal(deriveForbiddenEdgeMarkers(authority.machineRecords).length, 872);
});

test('replica route bindings are canonical JCS UTF-16 sets', () => {
  const authority = buildExpectedMachineAuthority();
  const materialization = authority.machineRecords.find((machine) =>
    machine.machineId === 'SM-MATERIALIZATION');
  assert.deepEqual(materialization.replicaWriterBindings[0].routeBindings.map((route) =>
    route.registryId), [
    'materialization.begin.v1:TIMELINE',
    'materialization.commit.v1:TIMELINE',
    'materialization.page.v1:TIMELINE',
  ]);
  const drift = registry();
  const row = drift.machineRecords.find((machine) => machine.machineId === 'SM-MATERIALIZATION');
  [row.replicaWriterBindings[0].routeBindings[1], row.replicaWriterBindings[0].routeBindings[2]] =
    [row.replicaWriterBindings[0].routeBindings[2], row.replicaWriterBindings[0].routeBindings[1]];
  assert.throws(() => validateMachineAuthorityRegistry(drift), /independent B2 oracle/);
});

test('only the two frozen state self-loops are allowed', () => {
  const authority = buildExpectedMachineAuthority();
  const loops = authority.machineRecords.flatMap((machine) =>
    machine.allowedEdges
      .filter((edge) => edge.from === edge.to)
      .map((edge) => `${machine.machineId}:${edge.from}->${edge.to}`));
  assert.deepEqual(loops, [
    'SM-TIMELINE-HEAD:PRESENT->PRESENT',
    'SM-QUEUE-ENTRY:QUEUED->QUEUED',
  ]);
});

test('machine semantic oracle distinguishes allowed, forbidden, and fault cases', () => {
  assert.deepEqual(evaluateMachineAuthorityCase({
    caseKind: 'EDGE',
    coordinate: {
      machineId: 'SM-TIMELINE-HEAD',
      from: 'PRESENT',
      to: 'PRESENT',
    },
  }), {valid: true, reason: 'NONE', postState: 'APPLIED', sideEffects: {}});
  for (const value of [
    {
      caseKind: 'FORBIDDEN_EDGE',
      coordinate: {machineId: 'SM-TIMELINE-HEAD', from: 'ABSENT', to: 'ABSENT'},
    },
    {
      caseKind: 'EDGE_GUARD_FAILURE',
      coordinate: {machineId: 'SM-TIMELINE-HEAD', from: 'ABSENT', to: 'PRESENT'},
    },
    {
      caseKind: 'EDGE_WRITE_FAILURE',
      coordinate: {machineId: 'SM-TIMELINE-HEAD', from: 'ABSENT', to: 'PRESENT'},
    },
  ]) {
    assert.deepEqual(evaluateMachineAuthorityCase(value), {
      valid: false,
      reason: 'MACHINE_AUTHORITY_INVALID',
      postState: 'UNCHANGED',
      sideEffects: {artifacts: 0, durableRows: 0},
    });
  }
});

test('machine SQL template bytes and digest are frozen', () => {
  const bytes = Buffer.from(MACHINE_TRANSITION_SQL_TEMPLATE, 'utf8');
  assert.equal(bytes.length, 657);
  assert.equal(digestBytes(bytes), MACHINE_TRANSITION_SQL_TEMPLATE_SHA256);
});

test('machine SQL is a single canonical 151-row byte buffer', () => {
  const authority = buildExpectedMachineAuthority();
  const rendered = renderMachineTransitionSql(
    authority.machineRecords,
    authority.machineEdgeAuthorities,
  );
  assert.equal(rendered.rows.length, 151);
  assert.equal(rendered.manifest.rowCount, 151);
  assert.equal(rendered.manifest.sqlUtf8Base64, rendered.bytes.toString('base64'));
  assert.equal(rendered.manifest.sqlSha256, digestBytes(rendered.bytes));
  assert.equal(decodeMachineTransitionSqlManifest(rendered.manifest).sql, rendered.sql);
  assert.ok(rendered.sql.endsWith('\n'));
  assert.ok(!rendered.sql.endsWith('\n\n'));
  assert.ok(!rendered.sql.includes('\r'));
});

test('every SQL authority_json cell is canonical Registry authority', () => {
  const authority = buildExpectedMachineAuthority();
  const rendered = renderMachineTransitionSql(
    authority.machineRecords,
    authority.machineEdgeAuthorities,
  );
  for (const row of rendered.rows) {
    assert.equal(canonicalize(row.authority), canonicalize(
      authority.machineEdgeAuthorities.find((candidate) =>
        candidate.edgeId === row.edgeId),
    ));
  }
});

test('SQL manifest rejects byte and digest drift', () => {
  const authority = buildExpectedMachineAuthority();
  const rendered = renderMachineTransitionSql(
    authority.machineRecords,
    authority.machineEdgeAuthorities,
  );
  assert.throws(() => decodeMachineTransitionSqlManifest({
    ...rendered.manifest,
    sqlUtf8Base64: `${rendered.manifest.sqlUtf8Base64.slice(0, -4)}AAAA`,
  }), /digest mismatch|non-canonical/);
  assert.throws(() => decodeMachineTransitionSqlManifest({
    ...rendered.manifest,
    sqlSha256: '0'.repeat(64),
  }), /digest mismatch/);
});

test('generated state enums, coordinate union, and SQL count cannot drift from Registry', () => {
  const stateDrift = registry();
  stateDrift.definitions.find((row) => row.id === 'SmSourceStateV1').node.values.pop();
  assert.throws(() => validateMachineAuthorityRegistry(stateDrift), /state order/);

  const coordinateDrift = registry();
  coordinateDrift.definitions.find((row) => row.id === 'MachineEdgeCoordinateV1')
    .node.variants[0].fields[0].type.target = 'SmLiveStateV1';
  assert.throws(() => validateMachineAuthorityRegistry(coordinateDrift), /all 17 machine enums/);

  const sqlCountDrift = registry();
  const rowCount = sqlCountDrift.definitions.find((row) =>
    row.id === 'MachineTransitionSqlV1').node.fields.find((field) =>
    field.name === 'rowCount').type;
  rowCount.const -= 1;
  assert.throws(() => validateMachineAuthorityRegistry(sqlCountDrift), /exact edge count/);
});

test('machine vector IDs bind their exact case kind and coordinate', () => {
  const authority = validateMachineAuthorityRegistry(registry());
  const pristine = vectors();
  validateMachineAuthorityVectors(authority, pristine);

  for (const id of [
    'machine.edge.00.000.positive',
    'machine.edge.00.000.guard-negative',
    'machine.edge.00.000.write-fault',
    'forbidden.edge.00.000.000.negative',
  ]) {
    const drift = structuredClone(pristine);
    const vector = drift.find((candidate) => candidate.id === id);
    const donor = drift.find((candidate) =>
      candidate.vectorSetRef === vector.vectorSetRef && candidate.id !== id &&
      candidate.value.caseKind === vector.value.caseKind);
    vector.value.coordinate = structuredClone(donor.value.coordinate);
    assert.throws(
      () => validateMachineAuthorityVectors(authority, drift),
      /does not bind its exact case and coordinate/,
      id,
    );
  }
});
