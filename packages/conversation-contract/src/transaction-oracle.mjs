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
  const machine = machineAuthority.machineRecords.find((candidate) =>
    candidate.machineId === applicability.coordinate.machineId);
  if (!machine) fail('transactionOracle.bridge', 'unknown owner machine');
  const ownerStorage = binding(machineAuthority, machine.storageBindingRef.registryId);
  const ownerCoordinates = new Set(ownerStorage.physicalCoordinates.map((row) => row.coordinateId));
  const rows = coordinateIdsForOwner(machineAuthority, applicability.coordinate).map((coordinateId) => {
    if (!ownerCoordinates.has(coordinateId)) {
      fail('transactionOracle.bridge', `${ownerStorage.registryId} lacks ${coordinateId}`);
    }
    return {
      writeRole: 'OWNER_STATE',
      bindingKey: bindingKey('AUTHORITATIVE_MACHINE', machine.machineId),
      physicalStorageCoordinateRef: storageCoordinateRef(ownerStorage.registryId, coordinateId),
      rowCardinality: exactRows(),
    };
  });
  const deliveryStorage = binding(
    machineAuthority,
    'storage.authoritative.sm-durable-delivery',
  );
  const deliveryCoordinates = new Set(deliveryStorage.physicalCoordinates.map((row) =>
    row.coordinateId));
  const deliveryWrite = (writeRole, coordinateId, rowCardinality) => {
    if (!deliveryCoordinates.has(coordinateId)) {
      fail('transactionOracle.bridge', `${deliveryStorage.registryId} lacks ${coordinateId}`);
    }
    return {
      writeRole,
      bindingKey: bindingKey('AUTHORITATIVE_MACHINE', 'SM-DURABLE-DELIVERY'),
      physicalStorageCoordinateRef: storageCoordinateRef(
        deliveryStorage.registryId,
        coordinateId,
      ),
      rowCardinality,
    };
  };
  if (shape === 'connected') {
    rows.push(deliveryWrite(
      'OWNER_STATE',
      'BRIDGE.durable_delivery_head.state',
      exactRows(),
    ));
  }
  if (shape !== 'quiet') {
    rows.push(deliveryWrite('EVENT_FACT', 'BRIDGE.event_fact.immutable', exactRows()));
  }
  if (shape === 'connected') {
    rows.push(deliveryWrite(
      'OUTBOX_ENVELOPE',
      'BRIDGE.outbox_envelope.immutable',
      contextRows('ELIGIBLE_ENVELOPE_COUNT'),
    ));
  }
  return rows;
}

function slug(value) {
  return value.replaceAll(/[^A-Za-z0-9]+/g, '-').replaceAll(/^-|-$/g, '').toLowerCase();
}

function independentBridgeRouteCases(machineAuthority) {
  const routes = new Map(machineAuthority.projectionRoutes.map((route) => [
    route.registryId,
    route,
  ]));
  const cases = [];
  for (const machine of machineAuthority.machineRecords) {
    if (machine.machineId === 'SM-DURABLE-DELIVERY') continue;
    for (const routeRef of machine.authoritativeRouteRefs) {
      const route = routes.get(routeRef.registryId);
      if (!route) fail('transactionOracle.bridge', `unknown route ${routeRef.registryId}`);
      for (const [edgeOrdinal, edge] of machine.allowedEdges.entries()) {
        cases.push({
          route,
          machine,
          edgeOrdinal,
          coordinate: {machineId: machine.machineId, ...edge},
        });
      }
    }
  }
  return cases.sort((left, right) =>
    left.route.normativeOrdinal - right.route.normativeOrdinal ||
    left.machine.machineOrdinal - right.machine.machineOrdinal ||
    left.edgeOrdinal - right.edgeOrdinal);
}

function independentBridgeGuardId(entry, routeVariant) {
  return `guard.transaction.bridge.${pad(entry.route.normativeOrdinal, 2)}.${pad(
    entry.machine.machineOrdinal,
    2,
  )}.${pad(entry.edgeOrdinal, 3)}.${slug(routeVariant)}`;
}

function independentBridgeManifestId(entry, shape) {
  return `tx.bridge.${pad(entry.route.normativeOrdinal, 2)}.${pad(
    entry.machine.machineOrdinal,
    2,
  )}.${pad(entry.edgeOrdinal, 3)}.${shape}`;
}

function independentBridgeApplicability(machineAuthority, entry, routeVariant) {
  const edge = machineEdge(machineAuthority, entry.coordinate);
  if (edge.guardRefs.length !== 1) {
    fail('transactionOracle.bridge', `${edge.edgeId} needs one exact machine guard`);
  }
  return {
    bindingKey: bindingKey('AUTHORITATIVE_MACHINE', entry.machine.machineId),
    coordinate: entry.coordinate,
    routeRef: ref('PROJECTION_ROUTE', entry.route.registryId),
    routeVariant,
    guardRefs: [
      ref('EDGE_GUARD', edge.guardRefs[0].registryId),
      ref('EDGE_GUARD', independentBridgeGuardId(entry, routeVariant)),
    ].sort((left, right) => compareUtf16(left.registryId, right.registryId)),
  };
}

function independentBridgeManifests(machineAuthority) {
  const manifests = [];
  for (const entry of independentBridgeRouteCases(machineAuthority)) {
    const edge = machineEdge(machineAuthority, entry.coordinate);
    const coordinator = bindingKey('AUTHORITATIVE_MACHINE', entry.machine.machineId);
    for (const [shape, variants] of [
      ['connected', ['PUBLIC_CONNECTED']],
      ['disconnected', ['PUBLIC_DISCONNECTED']],
      ['quiet', ['COALESCED', 'REJECTED', 'INTERNAL']],
    ]) {
      const manifestId = independentBridgeManifestId(entry, shape);
      manifests.push({
        manifestId,
        initialDurablePostStateProjectionRef: edge.zeroEffectProjectionRef,
        applicabilityCases: variants.map((routeVariant) =>
          independentBridgeApplicability(machineAuthority, entry, routeVariant)),
        segments: [independentSqlSegment({
          manifestId,
          segmentOrdinal: 0,
          transactionRole: 'AUTHORITATIVE_OWNER',
          coordinatorBindingKey: coordinator,
          entry: edge.zeroEffectProjectionRef,
          writes: expectedBridgeWrites(machineAuthority, entry, shape),
          commit: edge.successPostStateProjectionRef,
        })],
      });
    }
  }
  return manifests;
}

function validateBridgeManifests(machineAuthority, authority) {
  const bridge = authority.transactionManifests.filter((manifest) =>
    manifest.manifestId.startsWith('tx.bridge.'));
  const expected = independentBridgeManifests(machineAuthority);
  if (!jsonEqual(bridge, expected)) {
    fail('transactionOracle.bridge', 'manifests do not exact-equal the independent Bridge law');
  }
  return {
    bridgeManifestCount: expected.length,
    authoritativeCaseCount: independentBridgeRouteCases(machineAuthority).length *
      ROUTE_VARIANTS.length,
    expectedById: new Map(expected.map((manifest) => [manifest.manifestId, manifest])),
  };
}

function ref(refKind, registryId) {
  return {refKind, registryId};
}

function bindingKey(bindingKind, machineId) {
  return bindingKind === 'MOBILE_REPLICA'
    ? {bindingKind, machineId, replicaRole: 'MOBILE_REBUILDABLE_REPLICA'}
    : {bindingKind, machineId};
}

function storageCoordinateRef(storageBindingId, coordinateId) {
  return {
    storageBindingRef: ref('STORAGE_BINDING', storageBindingId),
    coordinateId,
  };
}

function exactRows() {
  return {cardinalityKind: 'EXACT', rows: 1};
}

function contextRows(countKind) {
  return {cardinalityKind: 'CONTEXT_COUNT', countKind};
}

function pad(value, width) {
  return String(value).padStart(width, '0');
}

function machineStateOracle(machineAuthority, machineId, state) {
  const projection = machineAuthority.oracleProjections.find((candidate) =>
    candidate.machineId === machineId && candidate.state === state);
  if (!projection) fail('transactionOracle.state', `missing ${machineId}/${state}`);
  return ref('ORACLE_PROJECTION', projection.registryId);
}

function customMobileOracle(route, suffix) {
  return ref(
    'ORACLE_PROJECTION',
    `oracle.transaction.mobile.${pad(route.normativeOrdinal, 2)}.${suffix}`,
  );
}

function machineEdge(machineAuthority, coordinate) {
  const edge = machineAuthority.machineEdgeAuthorities.find((candidate) =>
    jsonEqual(candidate.coordinate, coordinate));
  if (!edge) fail('transactionOracle.mobile', `missing ${JSON.stringify(coordinate)}`);
  return edge;
}

function primaryCoordinate(machineAuthority, storageBindingId) {
  const storage = binding(machineAuthority, storageBindingId);
  if (storage.physicalCoordinates.length === 0) {
    fail('transactionOracle.mobile', `${storageBindingId} has no physical coordinate`);
  }
  return storage.physicalCoordinates[0];
}

function replicaCoordinate(machineAuthority, machineId) {
  const machine = machineAuthority.machineRecords.find((candidate) =>
    candidate.machineId === machineId);
  if (!machine || machine.replicaWriterBindings.length !== 1 ||
      machine.replicaWriterBindings[0].storageBindings.length !== 1) {
    fail('transactionOracle.mobile', `${machineId} lacks one closed replica binding`);
  }
  const storageId = machine.replicaWriterBindings[0].storageBindings[0].registryId;
  const coordinate = primaryCoordinate(machineAuthority, storageId);
  return storageCoordinateRef(storageId, coordinate.coordinateId);
}

function independentSqlSegment({
  manifestId,
  segmentOrdinal,
  transactionRole,
  coordinatorBindingKey,
  entry,
  writes,
  commit,
}) {
  const segmentId = `${manifestId}:S${segmentOrdinal}`;
  return {
    segmentOrdinal,
    segmentId,
    segmentKind: 'SQL_TRANSACTION',
    transactionRole,
    coordinatorBindingKey,
    entryDurablePostStateProjectionRef: entry,
    writes: writes.map((write, writeOrdinal) => ({
      writeOrdinal,
      writeId: `${segmentId}:W${writeOrdinal}`,
      ...write,
    })),
    commitPostStateProjectionRef: commit,
  };
}

function independentEffectSegment({
  manifestId,
  segmentOrdinal,
  segmentKind,
  durable,
  effect,
  replayRule,
}) {
  return {
    segmentOrdinal,
    segmentId: `${manifestId}:S${segmentOrdinal}`,
    segmentKind,
    durablePostStateProjectionRef: durable,
    effectPostStateProjectionRef: effect,
    replayRule,
  };
}

function mobileWrite({role, machineId, storageId, coordinateId, cardinality}) {
  return {
    writeRole: role,
    bindingKey: bindingKey(
      machineId === 'SM-REPLICA-APPLY' ? 'AUTHORITATIVE_MACHINE' : 'MOBILE_REPLICA',
      machineId,
    ),
    physicalStorageCoordinateRef: storageCoordinateRef(storageId, coordinateId),
    rowCardinality: cardinality,
  };
}

function independentMobileManifest(machineAuthority, route) {
  const routeOrdinal = pad(route.normativeOrdinal, 2);
  const manifestId = `tx.mobile.${routeOrdinal}.apply`;
  const coordinator = bindingKey('AUTHORITATIVE_MACHINE', 'SM-REPLICA-APPLY');
  const applyEdge = machineEdge(machineAuthority, {
    machineId: 'SM-REPLICA-APPLY',
    from: 'RECEIVED',
    to: 'STAGED',
  });
  if (applyEdge.guardRefs.length !== 1) {
    fail('transactionOracle.mobile', 'replica apply edge needs one exact machine guard');
  }
  const applyStorageId = 'storage.authoritative.sm-replica-apply';
  const applyCoordinate = primaryCoordinate(machineAuthority, applyStorageId);
  const inboxStorageId = 'storage.transaction.sm-replica-apply.inbox';
  const domainStorageId = 'storage.transaction.sm-replica-apply.domain-staging';
  const commitStorageId = 'storage.transaction.sm-replica-apply.commit';
  for (const storageId of [inboxStorageId, domainStorageId, commitStorageId]) {
    binding(machineAuthority, storageId);
  }
  const state = (name) => machineStateOracle(machineAuthority, 'SM-REPLICA-APPLY', name);
  const domainMachines = DOMAIN_MACHINES_BY_ROUTE[route.registryId];
  if (domainMachines === undefined) fail('transactionOracle.mobile', `unknown ${route.registryId}`);
  const segments = [];

  segments.push(independentSqlSegment({
    manifestId,
    segmentOrdinal: segments.length,
    transactionRole: 'DURABLE_INBOX_STAGING',
    coordinatorBindingKey: coordinator,
    entry: state('RECEIVED'),
    writes: [
      mobileWrite({
        role: 'DURABLE_STAGING',
        machineId: 'SM-REPLICA-APPLY',
        storageId: inboxStorageId,
        coordinateId: 'MOBILE.m_inbox_event.envelope',
        cardinality: contextRows('STAGED_ENVELOPE_COUNT'),
      }),
      mobileWrite({
        role: 'PROGRESS_METADATA',
        machineId: 'SM-REPLICA-APPLY',
        storageId: inboxStorageId,
        coordinateId: 'MOBILE.m_apply_batch.progress',
        cardinality: exactRows(),
      }),
      mobileWrite({
        role: 'APPLY_STATE',
        machineId: 'SM-REPLICA-APPLY',
        storageId: applyStorageId,
        coordinateId: applyCoordinate.coordinateId,
        cardinality: exactRows(),
      }),
    ],
    commit: state('STAGED'),
  }));

  let finalEntry = state('STAGED');
  if (domainMachines.length > 0) {
    finalEntry = customMobileOracle(route, 'domain-staged');
    segments.push(independentSqlSegment({
      manifestId,
      segmentOrdinal: segments.length,
      transactionRole: 'DURABLE_DOMAIN_STAGING',
      coordinatorBindingKey: coordinator,
      entry: state('STAGED'),
      writes: [mobileWrite({
        role: 'DURABLE_STAGING',
        machineId: 'SM-REPLICA-APPLY',
        storageId: domainStorageId,
        coordinateId: 'MOBILE.m_apply_batch_row.immutable',
        cardinality: contextRows('STAGED_TYPED_ROW_COUNT'),
      })],
      commit: finalEntry,
    }));
  }

  const finalWrites = [mobileWrite({
    role: 'PROGRESS_METADATA',
    machineId: 'SM-REPLICA-APPLY',
    storageId: inboxStorageId,
    coordinateId: 'MOBILE.m_apply_batch.progress',
    cardinality: exactRows(),
  })];
  for (const machineId of domainMachines) {
    finalWrites.push({
      writeRole: 'DOMAIN_REPLICA',
      bindingKey: bindingKey('MOBILE_REPLICA', machineId),
      physicalStorageCoordinateRef: replicaCoordinate(machineAuthority, machineId),
      rowCardinality: contextRows('APPLICABLE_DOMAIN_ROW_COUNT'),
    });
  }
  finalWrites.push(
    mobileWrite({
      role: 'APPLY_STATE',
      machineId: 'SM-REPLICA-APPLY',
      storageId: applyStorageId,
      coordinateId: applyCoordinate.coordinateId,
      cardinality: exactRows(),
    }),
    mobileWrite({
      role: 'CHECKPOINT',
      machineId: 'SM-REPLICA-APPLY',
      storageId: commitStorageId,
      coordinateId: 'MOBILE.m_replica_checkpoint.checkpoint_version',
      cardinality: exactRows(),
    }),
    mobileWrite({
      role: 'PUBLICATION_OUTBOX',
      machineId: 'SM-REPLICA-APPLY',
      storageId: commitStorageId,
      coordinateId: 'MOBILE.m_publication_outbox.immutable',
      cardinality: exactRows(),
    }),
  );
  segments.push(independentSqlSegment({
    manifestId,
    segmentOrdinal: segments.length,
    transactionRole: 'FINAL_REPLICA_APPLY',
    coordinatorBindingKey: coordinator,
    entry: finalEntry,
    writes: finalWrites,
    commit: state('APPLIED'),
  }));

  const cas = (transactionRole, entryState, commitState) => independentSqlSegment({
    manifestId,
    segmentOrdinal: segments.length,
    transactionRole,
    coordinatorBindingKey: coordinator,
    entry: state(entryState),
    writes: [mobileWrite({
      role: 'APPLY_STATE',
      machineId: 'SM-REPLICA-APPLY',
      storageId: applyStorageId,
      coordinateId: applyCoordinate.coordinateId,
      cardinality: exactRows(),
    })],
    commit: state(commitState),
  });
  segments.push(independentEffectSegment({
    manifestId,
    segmentOrdinal: segments.length,
    segmentKind: 'READBACK',
    durable: state('APPLIED'),
    effect: customMobileOracle(route, 'readback-effect'),
    replayRule: 'READ_ONLY_REPEATABLE',
  }));
  segments.push(cas('READBACK_STATE_CAS', 'APPLIED', 'READBACK_VERIFIED'));
  segments.push(independentEffectSegment({
    manifestId,
    segmentOrdinal: segments.length,
    segmentKind: 'PUBLICATION',
    durable: state('READBACK_VERIFIED'),
    effect: customMobileOracle(route, 'publication-effect'),
    replayRule: 'IDEMPOTENT_BY_REPOSITORY_PUBLICATION_ID',
  }));
  segments.push(cas('PUBLICATION_STATE_CAS', 'READBACK_VERIFIED', 'PUBLISHED'));
  segments.push(independentEffectSegment({
    manifestId,
    segmentOrdinal: segments.length,
    segmentKind: 'ACK',
    durable: state('PUBLISHED'),
    effect: customMobileOracle(route, 'ack-effect'),
    replayRule: 'IDEMPOTENT_BY_MESSAGE_KEY_AND_COMMITTED_CHECKPOINT',
  }));
  segments.push(cas('ACK_STATE_CAS', 'PUBLISHED', 'ACKED'));

  return {
    manifestId,
    initialDurablePostStateProjectionRef: state('RECEIVED'),
    applicabilityCases: [{
      bindingKey: coordinator,
      coordinate: applyEdge.coordinate,
      routeRef: ref('PROJECTION_ROUTE', route.registryId),
      routeVariant: 'INTERNAL',
      guardRefs: [
        ref('EDGE_GUARD', applyEdge.guardRefs[0].registryId),
        ref('EDGE_GUARD', `guard.transaction.mobile.${routeOrdinal}`),
      ].sort((left, right) => compareUtf16(left.registryId, right.registryId)),
    }],
    segments,
  };
}

function validateMobileManifests(machineAuthority, authority) {
  const mobile = authority.transactionManifests.filter((manifest) =>
    manifest.manifestId.startsWith('tx.mobile.'));
  const expected = machineAuthority.projectionRoutes.map((route) =>
    independentMobileManifest(machineAuthority, route));
  if (!jsonEqual(mobile, expected)) {
    fail('transactionOracle.mobile', 'manifests do not exact-equal the independent route law');
  }
  return {
    mobileManifestCount: expected.length,
    expectedById: new Map(expected.map((manifest) => [manifest.manifestId, manifest])),
  };
}

function expectedSteps(manifest) {
  const rows = [];
  let stepOrdinal = 0;
  for (const segment of manifest.segments) {
    if (segment.segmentKind === 'SQL_TRANSACTION') {
      rows.push({
        stepOrdinal,
        stepId: `${manifest.manifestId}:P${stepOrdinal}`,
        manifestRef: ref('TRANSACTION_MANIFEST', manifest.manifestId),
        segmentOrdinal: segment.segmentOrdinal,
        segmentId: segment.segmentId,
        stepKind: 'TX_BEGIN',
      });
      stepOrdinal += 1;
      for (const write of segment.writes) {
        rows.push({
          stepOrdinal,
          stepId: `${manifest.manifestId}:P${stepOrdinal}`,
          manifestRef: ref('TRANSACTION_MANIFEST', manifest.manifestId),
          segmentOrdinal: segment.segmentOrdinal,
          segmentId: segment.segmentId,
          stepKind: 'WRITE',
          writeId: write.writeId,
          writeRole: write.writeRole,
        });
        stepOrdinal += 1;
      }
      rows.push({
        stepOrdinal,
        stepId: `${manifest.manifestId}:P${stepOrdinal}`,
        manifestRef: ref('TRANSACTION_MANIFEST', manifest.manifestId),
        segmentOrdinal: segment.segmentOrdinal,
        segmentId: segment.segmentId,
        stepKind: 'TX_COMMIT',
      });
      stepOrdinal += 1;
    } else {
      rows.push({
        stepOrdinal,
        stepId: `${manifest.manifestId}:P${stepOrdinal}`,
        manifestRef: ref('TRANSACTION_MANIFEST', manifest.manifestId),
        segmentOrdinal: segment.segmentOrdinal,
        segmentId: segment.segmentId,
        stepKind: segment.segmentKind,
        replayRule: segment.replayRule,
      });
      stepOrdinal += 1;
    }
  }
  return rows;
}

function expectedFailureOracle(manifest, after, before) {
  const segment = manifest.segments[after.segmentOrdinal];
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
      resumeSegmentOrdinal: before.segmentOrdinal,
    };
  }
  return {
    oracleKind: 'EXTERNAL_EFFECT_MAY_HAVE_OCCURRED',
    effectKind: after.stepKind,
    replayRule: segment.replayRule,
    durablePostStateProjectionRef: segment.durablePostStateProjectionRef,
    resumeSegmentOrdinal: before.segmentOrdinal,
  };
}

function validateDerivedFailureUniverse(authority, expectedManifestsById) {
  const expectedStepRows = [];
  const expectedKillRows = [];
  for (const candidate of authority.transactionManifests) {
    const manifest = expectedManifestsById.get(candidate.manifestId);
    if (!manifest) {
      fail('transactionOracle.failureUniverse', `unexpected manifest ${candidate.manifestId}`);
    }
    const steps = expectedSteps(manifest);
    expectedStepRows.push(...steps);
    for (let index = 0; index + 1 < steps.length; index += 1) {
      const after = steps[index];
      const before = steps[index + 1];
      expectedKillRows.push({
        killPointId: `${manifest.manifestId}:K${after.stepOrdinal}`,
        manifestRef: ref('TRANSACTION_MANIFEST', manifest.manifestId),
        afterStepOrdinal: after.stepOrdinal,
        afterStepId: after.stepId,
        beforeStepOrdinal: before.stepOrdinal,
        beforeStepId: before.stepId,
        failureOracle: expectedFailureOracle(manifest, after, before),
      });
    }
  }
  if (!jsonEqual(authority.transactionSteps, expectedStepRows) ||
      !jsonEqual(authority.transactionKillPoints, expectedKillRows)) {
    fail('transactionOracle.failureUniverse', 'steps or kill points differ from independent law');
  }
  return {
    stepCount: expectedStepRows.length,
    killPointCount: expectedKillRows.length,
  };
}

function validateBridgeAliases(machineAuthority, authority) {
  const expected = [];
  for (const route of machineAuthority.projectionRoutes) {
    const candidates = [];
    for (const machine of machineAuthority.machineRecords) {
      if (!machine.authoritativeRouteRefs.some((candidate) =>
        candidate.registryId === route.registryId)) continue;
      for (const [edgeOrdinal, edge] of machine.allowedEdges.entries()) {
        candidates.push({machine, edgeOrdinal, edge});
      }
    }
    candidates.sort((left, right) =>
      left.machine.machineOrdinal - right.machine.machineOrdinal ||
      left.edgeOrdinal - right.edgeOrdinal);
    if (candidates.length === 0) fail('transactionOracle.bridgeAliases', `no ${route.registryId}`);
    const selected = candidates[0];
    const manifestId = `tx.bridge.${pad(route.normativeOrdinal, 2)}.${pad(
      selected.machine.machineOrdinal,
      2,
    )}.${pad(selected.edgeOrdinal, 3)}.connected`;
    const applicability = {
      routeRef: ref('PROJECTION_ROUTE', route.registryId),
      coordinate: {machineId: selected.machine.machineId, ...selected.edge},
    };
    const writes = expectedBridgeWrites(machineAuthority, applicability, 'connected');
    const ownerIndexes = writes.map((write, index) =>
      write.writeRole === 'OWNER_STATE' ? index : -1).filter((index) => index >= 0);
    const eventIndex = writes.findIndex((write) => write.writeRole === 'EVENT_FACT');
    const outboxIndex = writes.findIndex((write) => write.writeRole === 'OUTBOX_ENVELOPE');
    if (ownerIndexes.length === 0 || eventIndex < 0 || outboxIndex < 0) {
      fail('transactionOracle.bridgeAliases', `${manifestId} lacks canonical boundaries`);
    }
    const killOrdinals = [
      0,
      ownerIndexes.at(-1) + 1,
      eventIndex + 1,
      outboxIndex + 1,
    ];
    for (const [pointOrdinal, pointKind] of BRIDGE_POINT_KINDS.entries()) {
      expected.push({
        bridgeMarkerId: `${route.registryId}:${pointKind}`,
        routeRef: ref('PROJECTION_ROUTE', route.registryId),
        pointKind,
        manifestRef: ref('TRANSACTION_MANIFEST', manifestId),
        applicabilityCaseOrdinal: 0,
        transactionKillPointId: `${manifestId}:K${killOrdinals[pointOrdinal]}`,
      });
    }
  }
  if (!jsonEqual(authority.bridgeRoutePointBindings, expected)) {
    fail('transactionOracle.bridgeAliases', 'aliases do not exact-equal canonical boundaries');
  }
  return {bridgeAliasCount: expected.length};
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
  const expectedManifestsById = new Map([
    ...bridge.expectedById,
    ...mobile.expectedById,
  ]);
  if (expectedManifestsById.size !== authority.transactionManifests.length) {
    fail('transactionOracle.manifests', 'independent manifest universe is not exact');
  }
  const failure = validateDerivedFailureUniverse(authority, expectedManifestsById);
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
