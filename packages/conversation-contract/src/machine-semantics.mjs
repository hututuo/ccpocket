import {readFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';

import {compareUtf16, digestBytes, jsonEqual} from './canonical.mjs';
import {renderMachineTransitionSql} from './generate-machine-ddl.mjs';

const PROFILE_ID = 'pvmc1.phone-core.v1';
const MACHINE_FAILURE_REASON = 'MACHINE_AUTHORITY_INVALID';
const MACHINE_SQL_FAILURE_REASON = 'MACHINE_SQL_INVALID';
const ZERO_MACHINE_SIDE_EFFECTS = Object.freeze({artifacts: 0, durableRows: 0});
const ORACLE_PATH = fileURLToPath(new URL(
  '../test/fixtures/pvmc1-b2-normative-oracle.json',
  import.meta.url,
));
const RULING_PATH = fileURLToPath(new URL(
  '../../../docs/design/codex-kernel-v4/PVMC-1-B2-IMPLEMENTATION-RULING-20260830.md',
  import.meta.url,
));
const AMENDMENT_PATH = fileURLToPath(new URL(
  '../../../docs/design/codex-kernel-v4/PVMC-1-COMPACT-AUTHORITY-AMENDMENT-20260830.md',
  import.meta.url,
));

function fail(path, message) {
  throw new TypeError(`${path}: ${message}`);
}

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function object(value, path) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    fail(path, 'expected an object');
  }
  return value;
}

function array(value, path) {
  if (!Array.isArray(value)) fail(path, 'expected an array');
  return value;
}

function string(value, path) {
  if (typeof value !== 'string' || value.length === 0) {
    fail(path, 'expected a non-empty string');
  }
  return value;
}

function integer(value, path, minimum = 0) {
  if (!Number.isSafeInteger(value) || value < minimum) {
    fail(path, `expected a safe integer >= ${minimum}`);
  }
  return value;
}

function exactKeys(value, keys, path) {
  object(value, path);
  const actual = Object.keys(value).sort(compareUtf16);
  const expected = [...keys].sort(compareUtf16);
  if (!jsonEqual(actual, expected)) {
    fail(path, `expected exact keys ${expected.join(', ')}`);
  }
  return value;
}

function unique(values, path, key = (value) => value) {
  const seen = new Set();
  for (const [index, value] of array(values, path).entries()) {
    const identity = key(value);
    if (seen.has(identity)) fail(`${path}[${index}]`, `duplicate ${identity}`);
    seen.add(identity);
  }
  return seen;
}

function slug(value) {
  return value
    .replaceAll(/([a-z0-9])([A-Z])/g, '$1-$2')
    .replaceAll(/[^A-Za-z0-9_.-]+/g, '-')
    .toLowerCase();
}

export function semanticOwnerRegistryId(ownerId) {
  return `selector.semantic.${slug(ownerId)}`;
}

export function authoritativeWriterRegistryId(writerId) {
  return `writer.authoritative.${slug(writerId)}`;
}

export function authoritativeStorageRegistryId(machineId) {
  return `storage.authoritative.${slug(machineId)}`;
}

export function replicaStorageRegistryId(machineId) {
  return `storage.replica.${slug(machineId)}`;
}

export function wireProjectionRegistryId(machineId) {
  return `wire.${slug(machineId)}`;
}

export function unknownPolicyRegistryId(machineId) {
  return `unknown.${slug(machineId)}`;
}

export function edgeGuardRegistryId(machineOrdinal, edgeOrdinal) {
  return `guard.machine.${String(machineOrdinal).padStart(2, '0')}.${String(edgeOrdinal).padStart(3, '0')}`;
}

export function stateOracleRegistryId(machineOrdinal, stateOrdinal) {
  return `oracle.machine.${String(machineOrdinal).padStart(2, '0')}.${String(stateOrdinal).padStart(3, '0')}`;
}

export function positiveEdgeVectorId(machineOrdinal, edgeOrdinal) {
  return `machine.edge.${String(machineOrdinal).padStart(2, '0')}.${String(edgeOrdinal).padStart(3, '0')}.positive`;
}

export function negativeEdgeVectorId(machineOrdinal, edgeOrdinal) {
  return `machine.edge.${String(machineOrdinal).padStart(2, '0')}.${String(edgeOrdinal).padStart(3, '0')}.guard-negative`;
}

export function faultEdgeVectorId(machineOrdinal, edgeOrdinal) {
  return `machine.edge.${String(machineOrdinal).padStart(2, '0')}.${String(edgeOrdinal).padStart(3, '0')}.write-fault`;
}

export function forbiddenEdgeMarkerId(machineOrdinal, fromOrdinal, toOrdinal) {
  return `forbidden.edge.${String(machineOrdinal).padStart(2, '0')}.${String(fromOrdinal).padStart(3, '0')}.${String(toOrdinal).padStart(3, '0')}`;
}

export function forbiddenEdgeVectorId(machineOrdinal, fromOrdinal, toOrdinal) {
  return `${forbiddenEdgeMarkerId(machineOrdinal, fromOrdinal, toOrdinal)}.negative`;
}

function ownerHost(ownerId) {
  return ownerId === 'LocalIntentRepository' || ownerId === 'ReplicaApplyCoordinator'
    ? 'MOBILE'
    : 'BRIDGE';
}

function ref(refKind, registryId) {
  return {refKind, registryId};
}

function sourceOracle() {
  const parsed = JSON.parse(readFileSync(ORACLE_PATH, 'utf8'));
  exactKeys(parsed, [
    'formatVersion', 'profileId', 'status', 'authorityAmendmentSha256',
    'implementationRulingSha256', 'counts', 'durableRoutes', 'machines',
  ], 'pvmc1B2Oracle');
  if (parsed.formatVersion !== 1 || parsed.profileId !== PROFILE_ID ||
      parsed.status !== 'INDEPENDENT_TEST_ORACLE_NOT_GENERATION_SOURCE') {
    fail('pvmc1B2Oracle', 'unexpected oracle identity');
  }
  const rulingDigest = digestBytes(readFileSync(RULING_PATH));
  if (parsed.implementationRulingSha256 !== rulingDigest) {
    fail(
      'pvmc1B2Oracle.implementationRulingSha256',
      `expected current ruling digest ${rulingDigest}`,
    );
  }
  const amendmentDigest = digestBytes(readFileSync(AMENDMENT_PATH));
  if (parsed.authorityAmendmentSha256 !== amendmentDigest) {
    fail(
      'pvmc1B2Oracle.authorityAmendmentSha256',
      `expected current amendment digest ${amendmentDigest}`,
    );
  }
  return parsed;
}

export function loadPvmc1B2NormativeOracle() {
  return clone(sourceOracle());
}

function buildSelectorInventories(oracle) {
  const ownerIds = [...new Set(oracle.machines.map((machine) => machine.semanticOwner))];
  const writerIds = [...new Set(oracle.machines.map((machine) => machine.authoritativeWriter))];
  return {
    semanticOwnerSelectors: ownerIds.map((ownerId) => ({
      registryId: semanticOwnerRegistryId(ownerId),
      selectorKind: 'EXACT_COMPONENT',
      host: ownerHost(ownerId),
      ownerId,
    })).sort((left, right) => compareUtf16(left.registryId, right.registryId)),
    authoritativeWriters: writerIds.map((writerId) => ({
      registryId: authoritativeWriterRegistryId(writerId),
      writerKind: 'EXACT_COMPONENT',
      host: ownerHost(writerId),
      writerId,
    })).sort((left, right) => compareUtf16(left.registryId, right.registryId)),
  };
}

function physicalCoordinates(storage) {
  return storage.coordinates.map((coordinate) => ({
    coordinateId: coordinate.coordinateId,
    host: storage.host,
    databaseId: storage.databaseId,
    tableName: coordinate.tableName,
    stateColumnName: coordinate.stateColumnName,
    storageRole: coordinate.storageRole,
  }));
}

function buildStorageBindings(oracle) {
  const bindings = [];
  for (const machine of oracle.machines) {
    const semanticOwnerRef = ref(
      'SEMANTIC_OWNER_SELECTOR',
      semanticOwnerRegistryId(machine.semanticOwner),
    );
    bindings.push({
      registryId: authoritativeStorageRegistryId(machine.machineId),
      machineId: machine.machineId,
      bindingRole: 'AUTHORITATIVE',
      semanticOwnerRef,
      writerBinding: {
        writerKind: 'AUTHORITATIVE',
        authoritativeWriterRef: ref(
          'AUTHORITATIVE_WRITER',
          authoritativeWriterRegistryId(machine.authoritativeWriter),
        ),
      },
      storageMode: machine.storage.mode,
      physicalCoordinates: physicalCoordinates(machine.storage),
    });
    if (machine.replica !== null) {
      bindings.push({
        registryId: replicaStorageRegistryId(machine.machineId),
        machineId: machine.machineId,
        bindingRole: 'REBUILDABLE_REPLICA',
        semanticOwnerRef,
        writerBinding: {
          writerKind: 'REPLICA',
          replicaWriterRef: {
            host: 'MOBILE',
            writerId: 'ReplicaApplyCoordinator',
          },
        },
        storageMode: 'SQL_STATE_COLUMN',
        physicalCoordinates: [{
          coordinateId: `MOBILE.${machine.replica.tableName}.${machine.replica.stateColumnName}`,
          host: 'MOBILE',
          databaseId: 'MOBILE_CONVERSATION_REPLICA_V5',
          tableName: machine.replica.tableName,
          stateColumnName: machine.replica.stateColumnName,
          storageRole: 'MUTABLE_STATE',
        }],
      });
    }
  }
  return bindings.sort((left, right) => compareUtf16(left.registryId, right.registryId));
}

function buildMachineRecords(oracle) {
  return oracle.machines.map((machine) => {
    const replicaWriterBindings = machine.replica === null ? [] : [{
      replicaRole: 'MOBILE_REBUILDABLE_REPLICA',
      replicaWriterRef: {
        host: 'MOBILE',
        writerId: 'ReplicaApplyCoordinator',
      },
      storageBindings: [ref('STORAGE_BINDING', replicaStorageRegistryId(machine.machineId))],
      routeBindings: machine.replica.routes
        .map((registryId) => ref('PROJECTION_ROUTE', registryId))
        .sort((left, right) => compareUtf16(left.registryId, right.registryId)),
      canWriteSemanticOwnerState: false,
      canWriteEventFacts: false,
      canWriteOutboxEnvelopes: false,
      canAdvanceCanonicalHead: false,
    }];
    return {
      machineOrdinal: machine.machineOrdinal,
      machineId: machine.machineId,
      stateTypeRef: machine.stateTypeRef,
      states: machine.states,
      initialState: machine.initialState,
      terminalStates: machine.terminalStates,
      allowedEdges: machine.edges.map(([from, to]) => ({from, to})),
      semanticOwnerRef: ref(
        'SEMANTIC_OWNER_SELECTOR',
        semanticOwnerRegistryId(machine.semanticOwner),
      ),
      authoritativeWriterRef: ref(
        'AUTHORITATIVE_WRITER',
        authoritativeWriterRegistryId(machine.authoritativeWriter),
      ),
      eventFactOwnerSelectorRef: machine.eventFactOwnerSelector === undefined
        ? null
        : ref('EVENT_FACT_OWNER_SELECTOR', machine.eventFactOwnerSelector),
      replicaWriterBindings,
      storageBindingRef: ref(
        'STORAGE_BINDING',
        authoritativeStorageRegistryId(machine.machineId),
      ),
      authoritativeRouteRefs: machine.authoritativeRoutes.map((registryId) =>
        ref('PROJECTION_ROUTE', registryId)),
      wireProjectionRef: ref(
        'WIRE_PROJECTION',
        wireProjectionRegistryId(machine.machineId),
      ),
      unknownPolicyRef: ref(
        'UNKNOWN_POLICY',
        unknownPolicyRegistryId(machine.machineId),
      ),
      ownerFeature: machine.ownerFeature ?? null,
    };
  });
}

function buildEdgeInventories(oracle, machineRecords) {
  const edgeGuards = [];
  const oracleProjections = [];
  const machineEdgeAuthorities = [];
  for (const machine of machineRecords) {
    for (const [stateOrdinal, state] of machine.states.entries()) {
      oracleProjections.push({
        registryId: stateOracleRegistryId(machine.machineOrdinal, stateOrdinal),
        machineId: machine.machineId,
        state,
        projectionKind: 'EXACT_MACHINE_STATE',
      });
    }
    for (const [edgeOrdinal, coordinate] of machine.allowedEdges.entries()) {
      const guardRef = ref(
        'EDGE_GUARD',
        edgeGuardRegistryId(machine.machineOrdinal, edgeOrdinal),
      );
      edgeGuards.push({
        registryId: guardRef.registryId,
        machineId: machine.machineId,
        from: coordinate.from,
        to: coordinate.to,
        guardKind: 'EXACT_MACHINE_EDGE_PRECONDITIONS',
      });
      const fromOrdinal = machine.states.indexOf(coordinate.from);
      const toOrdinal = machine.states.indexOf(coordinate.to);
      machineEdgeAuthorities.push({
        edgeId: `${machine.machineId}:${coordinate.from}->${coordinate.to}`,
        coordinate: {machineId: machine.machineId, ...coordinate},
        semanticOwnerRef: machine.semanticOwnerRef,
        authoritativeWriterRef: machine.authoritativeWriterRef,
        eventFactOwnerSelectorRef: machine.eventFactOwnerSelectorRef,
        replicaWriterBindings: machine.replicaWriterBindings,
        storageBindingRef: machine.storageBindingRef,
        wireProjectionRef: machine.wireProjectionRef,
        unknownPolicyRef: machine.unknownPolicyRef,
        guardRefs: [guardRef],
        failureProblem: 'MACHINE_TRANSITION_INVALID',
        zeroEffectProjectionRef: ref(
          'ORACLE_PROJECTION',
          stateOracleRegistryId(machine.machineOrdinal, fromOrdinal),
        ),
        successPostStateProjectionRef: ref(
          'ORACLE_PROJECTION',
          stateOracleRegistryId(machine.machineOrdinal, toOrdinal),
        ),
        positiveVectorId: positiveEdgeVectorId(machine.machineOrdinal, edgeOrdinal),
        negativeVectorIds: [negativeEdgeVectorId(machine.machineOrdinal, edgeOrdinal)],
        faultVectorIds: [faultEdgeVectorId(machine.machineOrdinal, edgeOrdinal)],
      });
    }
  }
  return {edgeGuards, oracleProjections, machineEdgeAuthorities};
}

export function buildExpectedMachineAuthority() {
  const oracle = sourceOracle();
  const machineRecords = buildMachineRecords(oracle);
  const selectorInventories = buildSelectorInventories(oracle);
  const edgeInventories = buildEdgeInventories(oracle, machineRecords);
  return {
    machineAuthority: {
      formatVersion: 1,
      profileId: PROFILE_ID,
      authorityAmendmentSha256: oracle.authorityAmendmentSha256,
      implementationRulingSha256: oracle.implementationRulingSha256,
      machineCount: oracle.counts.machines,
      stateOccurrenceCount: oracle.counts.stateOccurrences,
      edgeCount: oracle.counts.allowedEdges,
      terminalCount: oracle.counts.terminals,
      cartesianPairCount: oracle.counts.cartesianPairs,
      forbiddenEdgeCount: oracle.counts.forbiddenEdges,
      durableRouteCount: oracle.durableRoutes.length,
    },
    machineRecords,
    ...selectorInventories,
    storageBindings: buildStorageBindings(oracle),
    projectionRoutes: oracle.durableRoutes.map((route) => ({
      registryId: route.registryId,
      normativeOrdinal: route.normativeOrdinal,
    })),
    wireProjections: oracle.machines.map((machine) => ({
      registryId: wireProjectionRegistryId(machine.machineId),
      machineId: machine.machineId,
      projectionKind: machine.wireProjection,
    })).sort((left, right) => compareUtf16(left.registryId, right.registryId)),
    unknownPolicies: oracle.machines.map((machine) => ({
      registryId: unknownPolicyRegistryId(machine.machineId),
      machineId: machine.machineId,
      policyKind: machine.unknownPolicy,
    })).sort((left, right) => compareUtf16(left.registryId, right.registryId)),
    eventFactOwnerSelectors: [{
      registryId: 'EVENT_KEY_OWNER_V1',
      selectorKind: 'ORIGINATING_EVENT_FACT_OWNER',
    }],
    ...edgeInventories,
  };
}

export function deriveForbiddenEdgeMarkers(machineRecords) {
  const markers = [];
  for (const machine of machineRecords) {
    const allowed = new Set(machine.allowedEdges.map((edge) => `${edge.from}\u0000${edge.to}`));
    for (const [fromOrdinal, from] of machine.states.entries()) {
      for (const [toOrdinal, to] of machine.states.entries()) {
        if (allowed.has(`${from}\u0000${to}`)) continue;
        markers.push({
          markerId: forbiddenEdgeMarkerId(
            machine.machineOrdinal,
            fromOrdinal,
            toOrdinal,
          ),
          coordinate: {machineId: machine.machineId, from, to},
        });
      }
    }
  }
  return markers;
}

function verifyGraph(machineRecords, header) {
  const machineIds = unique(machineRecords, 'registry.machineRecords', (machine) => machine.machineId);
  let stateOccurrences = 0;
  let edgeCount = 0;
  let terminalCount = 0;
  let cartesianPairCount = 0;
  let selfLoops = 0;
  for (const [machineOrdinal, machine] of machineRecords.entries()) {
    const path = `registry.machineRecords[${machineOrdinal}]`;
    if (machine.machineOrdinal !== machineOrdinal) {
      fail(`${path}.machineOrdinal`, `expected ${machineOrdinal}`);
    }
    string(machine.machineId, `${path}.machineId`);
    string(machine.stateTypeRef, `${path}.stateTypeRef`);
    const states = array(machine.states, `${path}.states`);
    unique(states, `${path}.states`);
    if (states[0] !== machine.initialState) {
      fail(`${path}.initialState`, 'must equal the first state');
    }
    const stateSet = new Set(states);
    const terminalSet = unique(machine.terminalStates, `${path}.terminalStates`);
    for (const terminal of terminalSet) {
      if (!stateSet.has(terminal)) fail(`${path}.terminalStates`, `unknown state ${terminal}`);
    }
    const edges = array(machine.allowedEdges, `${path}.allowedEdges`);
    unique(edges, `${path}.allowedEdges`, (edge) => `${edge.from}\u0000${edge.to}`);
    const outgoing = new Map(states.map((state) => [state, []]));
    const namedStates = new Set(machine.terminalStates);
    for (const [edgeOrdinal, edge] of edges.entries()) {
      exactKeys(edge, ['from', 'to'], `${path}.allowedEdges[${edgeOrdinal}]`);
      if (!stateSet.has(edge.from) || !stateSet.has(edge.to)) {
        fail(`${path}.allowedEdges[${edgeOrdinal}]`, 'edge state is outside machine');
      }
      namedStates.add(edge.from);
      namedStates.add(edge.to);
      outgoing.get(edge.from).push(edge.to);
      if (edge.from === edge.to) selfLoops += 1;
    }
    if (!jsonEqual([...namedStates].sort(compareUtf16), [...stateSet].sort(compareUtf16))) {
      fail(path, 'state set must equal edge endpoints union terminal states');
    }
    for (const terminal of terminalSet) {
      if (outgoing.get(terminal).length !== 0) fail(path, `terminal ${terminal} has an outgoing edge`);
    }
    for (const state of states) {
      if (!terminalSet.has(state) && outgoing.get(state).length === 0) {
        fail(path, `nonterminal ${state} has no outgoing edge`);
      }
      const seen = new Set([state]);
      const queue = [state];
      let reachesTerminal = terminalSet.has(state);
      while (queue.length > 0 && !reachesTerminal) {
        const current = queue.shift();
        for (const next of outgoing.get(current)) {
          if (terminalSet.has(next)) {
            reachesTerminal = true;
            break;
          }
          if (!seen.has(next)) {
            seen.add(next);
            queue.push(next);
          }
        }
      }
      if (!reachesTerminal) fail(path, `state ${state} has no path to a terminal`);
    }
    stateOccurrences += states.length;
    edgeCount += edges.length;
    terminalCount += terminalSet.size;
    cartesianPairCount += states.length * states.length;
  }
  const derived = {
    machineCount: machineIds.size,
    stateOccurrenceCount: stateOccurrences,
    edgeCount,
    terminalCount,
    cartesianPairCount,
    forbiddenEdgeCount: cartesianPairCount - edgeCount,
  };
  for (const [key, value] of Object.entries(derived)) {
    if (header[key] !== value) fail(`registry.machineAuthority.${key}`, `expected ${value}`);
  }
  if (selfLoops !== 2) fail('registry.machineRecords', `expected two self-loops, got ${selfLoops}`);
}

function verifyExactInventory(registry, key, expected) {
  if (!jsonEqual(registry[key], expected)) {
    fail(`registry.${key}`, 'does not exact-equal the independent B2 oracle');
  }
}

function activeDefinition(registry, id) {
  const definition = registry.definitions.find((candidate) => candidate.id === id);
  if (!definition || !definition.profiles.includes(PROFILE_ID)) {
    fail(`registry.definitions.${id}`, 'missing active definition');
  }
  return definition;
}

function verifyGeneratedMachineDefinitions(registry) {
  for (const machine of registry.machineRecords) {
    const stateDefinition = activeDefinition(registry, machine.stateTypeRef);
    if (stateDefinition.node.kind !== 'enum' ||
        !jsonEqual(stateDefinition.node.values, machine.states)) {
      fail(
        `registry.definitions.${machine.stateTypeRef}`,
        `must exact-equal ${machine.machineId} state order`,
      );
    }
  }
  const coordinate = activeDefinition(registry, 'MachineEdgeCoordinateV1').node;
  const expectedVariants = registry.machineRecords.map((machine) => ({
    tag: machine.machineId,
    fields: ['from', 'to'].map((name) => ({
      name,
      required: true,
      type: {kind: 'ref', target: machine.stateTypeRef},
    })),
  }));
  if (coordinate.kind !== 'union' || coordinate.discriminator !== 'machineId' ||
      !jsonEqual(coordinate.variants, expectedVariants)) {
    fail('registry.definitions.MachineEdgeCoordinateV1', 'must exact-equal all 17 machine enums');
  }
  const sql = activeDefinition(registry, 'MachineTransitionSqlV1').node;
  const rowCount = sql.kind === 'object'
    ? sql.fields.find((field) => field.name === 'rowCount')?.type
    : null;
  if (rowCount?.kind !== 'integer' ||
      rowCount.const !== registry.machineAuthority.edgeCount ||
      rowCount.minimum !== registry.machineAuthority.edgeCount ||
      rowCount.maximum !== registry.machineAuthority.edgeCount) {
    fail('registry.definitions.MachineTransitionSqlV1.rowCount', 'must bind the exact edge count');
  }
}

export function validateMachineAuthorityRegistry(registry) {
  const expected = buildExpectedMachineAuthority();
  verifyExactInventory(registry, 'machineAuthority', expected.machineAuthority);
  verifyExactInventory(registry, 'machineRecords', expected.machineRecords);
  verifyGraph(registry.machineRecords, registry.machineAuthority);
  verifyGeneratedMachineDefinitions(registry);
  for (const key of [
    'semanticOwnerSelectors',
    'authoritativeWriters',
    'projectionRoutes',
    'wireProjections',
    'unknownPolicies',
    'eventFactOwnerSelectors',
    'edgeGuards',
    'oracleProjections',
    'machineEdgeAuthorities',
  ]) {
    verifyExactInventory(registry, key, expected[key]);
  }
  const machineStorageBindings = registry.storageBindings.filter((binding) =>
    binding.bindingRole !== 'TRANSACTION_AUXILIARY');
  if (!jsonEqual(machineStorageBindings, expected.storageBindings)) {
    fail('registry.storageBindings', 'machine bindings do not exact-equal the independent B2 oracle');
  }
  const forbiddenEdgeMarkers = deriveForbiddenEdgeMarkers(registry.machineRecords);
  if (forbiddenEdgeMarkers.length !== registry.machineAuthority.forbiddenEdgeCount) {
    fail('registry.machineAuthority.forbiddenEdgeCount', 'forbidden complement mismatch');
  }
  const sql = renderMachineTransitionSql(
    registry.machineRecords,
    registry.machineEdgeAuthorities,
  );
  if (sql.rows.length !== registry.machineAuthority.edgeCount) {
    fail('registry.machineEdgeAuthorities', 'DDL row count differs from edge count');
  }
  return {
    machineAuthority: registry.machineAuthority,
    machineRecords: registry.machineRecords,
    semanticOwnerSelectors: registry.semanticOwnerSelectors,
    authoritativeWriters: registry.authoritativeWriters,
    storageBindings: registry.storageBindings,
    projectionRoutes: registry.projectionRoutes,
    wireProjections: registry.wireProjections,
    unknownPolicies: registry.unknownPolicies,
    eventFactOwnerSelectors: registry.eventFactOwnerSelectors,
    edgeGuards: registry.edgeGuards,
    oracleProjections: registry.oracleProjections,
    machineEdgeAuthorities: registry.machineEdgeAuthorities,
    forbiddenEdgeMarkers,
    machineTransitionSql: sql,
  };
}

export function validateMachineAuthorityVectors(machineAuthority, activeVectors) {
  const vectors = new Map(activeVectors.map((vector) => [vector.id, vector]));
  const expected = new Map();
  for (const [machineOrdinal, machine] of machineAuthority.machineRecords.entries()) {
    for (const [edgeOrdinal, edge] of machine.allowedEdges.entries()) {
      const coordinate = {machineId: machine.machineId, ...edge};
      expected.set(positiveEdgeVectorId(machineOrdinal, edgeOrdinal), {
        caseKind: 'EDGE',
        coordinate,
      });
      expected.set(negativeEdgeVectorId(machineOrdinal, edgeOrdinal), {
        caseKind: 'EDGE_GUARD_FAILURE',
        coordinate,
      });
      expected.set(faultEdgeVectorId(machineOrdinal, edgeOrdinal), {
        caseKind: 'EDGE_WRITE_FAILURE',
        coordinate,
      });
    }
  }
  for (const marker of machineAuthority.forbiddenEdgeMarkers) {
    const {machineId, from, to} = marker.coordinate;
    const machine = machineAuthority.machineRecords.find((row) => row.machineId === machineId);
    expected.set(forbiddenEdgeVectorId(
      machine.machineOrdinal,
      machine.states.indexOf(from),
      machine.states.indexOf(to),
    ), {caseKind: 'FORBIDDEN_EDGE', coordinate: marker.coordinate});
  }
  for (const [id, value] of expected) {
    const vector = vectors.get(id);
    if (!vector) fail('vectors.vectors', `missing B2 machine vector ${id}`);
    if (vector.vectorSetRef !== 'vectors.machine-authority' ||
        vector.ruleRef !== 'rule.machine.authority-closure' ||
        vector.typeRef !== 'MachineAuthorityCaseV1' ||
        !jsonEqual(vector.value, value)) {
      fail(`vectors.vectors.${id}`, 'machine vector ID does not bind its exact case and coordinate');
    }
  }
  const machineVectors = activeVectors.filter((vector) =>
    vector.vectorSetRef === 'vectors.machine-authority');
  if (machineVectors.length !== expected.size ||
      machineVectors.some((vector) => !expected.has(vector.id))) {
    fail(
      'vectors.vectors',
      `expected ${expected.size} exact B2 machine vectors, got ${machineVectors.length}`,
    );
  }
  const sqlDigest = machineAuthority.machineTransitionSql.manifest.sqlSha256;
  const expectedSql = new Map([
    ['V-PVMC1-MACHINE-TRANSITION-SQL-EXACT', {
      caseKind: 'SQL_EXACT',
      sqlSha256: sqlDigest,
    }],
    ['V-PVMC1-MACHINE-TRANSITION-SQL-BYTE-DRIFT', {
      caseKind: 'SQL_BYTE_DRIFT',
      sqlSha256: '0'.repeat(64),
    }],
    ['V-PVMC1-MACHINE-TRANSITION-SQL-DIGEST-DRIFT', {
      caseKind: 'SQL_DIGEST_DRIFT',
      sqlSha256: 'f'.repeat(64),
    }],
  ]);
  const sqlVectors = activeVectors.filter((vector) =>
    vector.vectorSetRef === 'vectors.machine-sql');
  if (sqlVectors.length !== expectedSql.size ||
      sqlVectors.some((vector) => !expectedSql.has(vector.id))) {
    fail('vectors.vectors', `expected ${expectedSql.size} exact B2 machine SQL vectors`);
  }
  for (const [id, value] of expectedSql) {
    const vector = vectors.get(id);
    if (!vector || vector.ruleRef !== 'rule.machine.sql-exact-bytes' ||
        vector.typeRef !== 'MachineTransitionSqlCaseV1' ||
        !jsonEqual(vector.value, value)) {
      fail(`vectors.vectors.${id}`, 'machine SQL vector ID does not bind its exact byte subject');
    }
  }
  return {expectedVectorIds: [...expected.keys()].sort(compareUtf16)};
}

function coordinateStatus(coordinate) {
  const oracle = sourceOracle();
  const machine = oracle.machines.find((candidate) =>
    candidate.machineId === coordinate?.machineId);
  if (!machine || !machine.states.includes(coordinate?.from) ||
      !machine.states.includes(coordinate?.to)) return 'WRONG_COORDINATE';
  return machine.edges.some(([from, to]) =>
    from === coordinate.from && to === coordinate.to)
    ? 'ALLOWED'
    : 'FORBIDDEN';
}

function accept() {
  return {valid: true, reason: 'NONE', postState: 'APPLIED', sideEffects: {}};
}

function reject() {
  return {
    valid: false,
    reason: MACHINE_FAILURE_REASON,
    postState: 'UNCHANGED',
    sideEffects: ZERO_MACHINE_SIDE_EFFECTS,
  };
}

export function evaluateMachineAuthorityCase(value) {
  if (value?.caseKind === 'EDGE' && coordinateStatus(value.coordinate) === 'ALLOWED') {
    return accept();
  }
  if (value?.caseKind === 'FORBIDDEN_EDGE' &&
      coordinateStatus(value.coordinate) === 'FORBIDDEN') return reject();
  if (value?.caseKind === 'EDGE_GUARD_FAILURE' &&
      coordinateStatus(value.coordinate) === 'ALLOWED') return reject();
  if (value?.caseKind === 'EDGE_WRITE_FAILURE' &&
      coordinateStatus(value.coordinate) === 'ALLOWED') return reject();
  return reject();
}

export function evaluateMachineSqlCase(value) {
  const expected = buildExpectedMachineAuthority();
  const rendered = renderMachineTransitionSql(
    expected.machineRecords,
    expected.machineEdgeAuthorities,
  );
  if (value?.caseKind === 'SQL_EXACT' &&
      value.sqlSha256 === rendered.manifest.sqlSha256) return accept();
  return {
    valid: false,
    reason: MACHINE_SQL_FAILURE_REASON,
    postState: 'UNCHANGED',
    sideEffects: ZERO_MACHINE_SIDE_EFFECTS,
  };
}

export function machineAuthoritySource(machineAuthority) {
  return {
    machineAuthority: machineAuthority.machineAuthority,
    machineRecords: machineAuthority.machineRecords,
    semanticOwnerSelectors: machineAuthority.semanticOwnerSelectors,
    authoritativeWriters: machineAuthority.authoritativeWriters,
    storageBindings: machineAuthority.storageBindings,
    projectionRoutes: machineAuthority.projectionRoutes,
    wireProjections: machineAuthority.wireProjections,
    unknownPolicies: machineAuthority.unknownPolicies,
    eventFactOwnerSelectors: machineAuthority.eventFactOwnerSelectors,
    edgeGuards: machineAuthority.edgeGuards,
    oracleProjections: machineAuthority.oracleProjections,
    machineEdgeAuthorities: machineAuthority.machineEdgeAuthorities,
    forbiddenEdgeMarkers: machineAuthority.forbiddenEdgeMarkers,
  };
}

export {
  MACHINE_FAILURE_REASON,
  MACHINE_SQL_FAILURE_REASON,
  PROFILE_ID as PVMC1_PROFILE_ID,
  ZERO_MACHINE_SIDE_EFFECTS,
};
