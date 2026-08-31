import {compareUtf16, jsonEqual} from './canonical.mjs';

const PROFILE_ID = 'pvmc1.phone-core.v1';
const TRANSACTION_FAILURE_REASON = 'TRANSACTION_AUTHORITY_INVALID';
const ZERO_TRANSACTION_SIDE_EFFECTS = Object.freeze({artifacts: 0, durableRows: 0});
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

function fail(path, message) {
  throw new TypeError(`${path}: ${message}`);
}

function ref(refKind, registryId) {
  return {refKind, registryId};
}

function bindingKey(bindingKind, machineId) {
  return bindingKind === 'MOBILE_REPLICA'
    ? {bindingKind, machineId, replicaRole: 'MOBILE_REBUILDABLE_REPLICA'}
    : {bindingKind, machineId};
}

function slug(value) {
  return value.replaceAll(/[^A-Za-z0-9]+/g, '-').replaceAll(/^-|-$/g, '').toLowerCase();
}

function pad(value, width) {
  return String(value).padStart(width, '0');
}

function routeRef(routeId) {
  return ref('PROJECTION_ROUTE', routeId);
}

function storageCoordinateRef(storageBindingId, coordinateId) {
  return {
    storageBindingRef: ref('STORAGE_BINDING', storageBindingId),
    coordinateId,
  };
}

function exactRows(rows = 1) {
  return {cardinalityKind: 'EXACT', rows};
}

function contextRows(countKind) {
  return {cardinalityKind: 'CONTEXT_COUNT', countKind};
}

function stateOracle(machineAuthority, machineId, state) {
  const projection = machineAuthority.oracleProjections.find((candidate) =>
    candidate.machineId === machineId && candidate.state === state);
  if (!projection) fail('transaction.stateOracle', `missing ${machineId}/${state}`);
  return ref('ORACLE_PROJECTION', projection.registryId);
}

function edgeAuthority(machineAuthority, coordinate) {
  const edge = machineAuthority.machineEdgeAuthorities.find((candidate) =>
    jsonEqual(candidate.coordinate, coordinate));
  if (!edge) fail('transaction.coordinate', `missing edge ${JSON.stringify(coordinate)}`);
  return edge;
}

function storageBinding(bindings, registryId) {
  const binding = bindings.find((candidate) => candidate.registryId === registryId);
  if (!binding) fail('transaction.storageBinding', `missing ${registryId}`);
  return binding;
}

function primaryCoordinate(binding) {
  if (binding.physicalCoordinates.length === 0) {
    fail('transaction.storageBinding', `${binding.registryId} has no physical coordinate`);
  }
  return binding.physicalCoordinates[0];
}

function coordinateById(binding, coordinateId) {
  const coordinate = binding.physicalCoordinates.find((candidate) =>
    candidate.coordinateId === coordinateId);
  if (!coordinate) {
    fail('transaction.storageBinding', `${binding.registryId} lacks ${coordinateId}`);
  }
  return coordinate;
}

function authoritativeOwnerCoordinates(binding, coordinate) {
  if (coordinate.machineId === 'SM-READ-ATTEMPT' &&
      coordinate.from === 'VERIFYING' && coordinate.to === 'VERIFIED') {
    return [
      coordinateById(binding, 'BRIDGE.timeline_read_attempt.state'),
      coordinateById(binding, 'BRIDGE.timeline_read_evidence.immutable'),
    ];
  }
  if (coordinate.machineId === 'SM-RECONCILE') {
    return [coordinateById(
      binding,
      coordinate.to === 'REQUESTED'
        ? 'BRIDGE.reconcile_attempt.immutable'
        : 'BRIDGE.reconcile_resolution.immutable',
    )];
  }
  return [primaryCoordinate(binding)];
}

function auxiliaryStorageBindings(machineAuthority) {
  const apply = machineAuthority.machineRecords.find((machine) =>
    machine.machineId === 'SM-REPLICA-APPLY');
  if (!apply) fail('transaction.machineRecords', 'missing SM-REPLICA-APPLY');
  const writerBinding = {
    writerKind: 'REPLICA',
    replicaWriterRef: {host: 'MOBILE', writerId: 'ReplicaApplyCoordinator'},
  };
  const common = {
    machineId: apply.machineId,
    bindingRole: 'TRANSACTION_AUXILIARY',
    semanticOwnerRef: apply.semanticOwnerRef,
    writerBinding,
    storageMode: 'SQL_AUXILIARY',
  };
  return [
    {
      registryId: 'storage.transaction.sm-replica-apply.inbox',
      ...common,
      physicalCoordinates: [
        {
          coordinateId: 'MOBILE.m_inbox_event.envelope',
          host: 'MOBILE',
          databaseId: 'MOBILE_CONVERSATION_REPLICA_V5',
          tableName: 'm_inbox_event',
          stateColumnName: null,
          storageRole: 'STAGING',
        },
        {
          coordinateId: 'MOBILE.m_apply_batch.progress',
          host: 'MOBILE',
          databaseId: 'MOBILE_CONVERSATION_REPLICA_V5',
          tableName: 'm_apply_batch',
          stateColumnName: null,
          storageRole: 'STAGING',
        },
      ],
    },
    {
      registryId: 'storage.transaction.sm-replica-apply.domain-staging',
      ...common,
      physicalCoordinates: [{
        coordinateId: 'MOBILE.m_apply_batch_row.immutable',
        host: 'MOBILE',
        databaseId: 'MOBILE_CONVERSATION_REPLICA_V5',
        tableName: 'm_apply_batch_row',
        stateColumnName: null,
        storageRole: 'STAGING',
      }],
    },
    {
      registryId: 'storage.transaction.sm-replica-apply.commit',
      ...common,
      physicalCoordinates: [
        {
          coordinateId: 'MOBILE.m_replica_checkpoint.checkpoint_version',
          host: 'MOBILE',
          databaseId: 'MOBILE_CONVERSATION_REPLICA_V5',
          tableName: 'm_replica_checkpoint',
          stateColumnName: 'checkpoint_version',
          storageRole: 'CHECKPOINT',
        },
        {
          coordinateId: 'MOBILE.m_publication_outbox.immutable',
          host: 'MOBILE',
          databaseId: 'MOBILE_CONVERSATION_REPLICA_V5',
          tableName: 'm_publication_outbox',
          stateColumnName: null,
          storageRole: 'PUBLICATION_OUTBOX',
        },
      ],
    },
  ].sort((left, right) => compareUtf16(left.registryId, right.registryId));
}

function authoritativeRouteCases(machineAuthority) {
  const routes = new Map(machineAuthority.projectionRoutes.map((route) => [
    route.registryId,
    route,
  ]));
  const cases = [];
  for (const machine of machineAuthority.machineRecords) {
    if (machine.machineId === 'SM-DURABLE-DELIVERY') continue;
    for (const route of machine.authoritativeRouteRefs) {
      if (!routes.has(route.registryId)) {
        fail('transaction.authoritativeRouteRefs', `unknown ${route.registryId}`);
      }
      for (const [edgeOrdinal, coordinate] of machine.allowedEdges.entries()) {
        cases.push({
          route: routes.get(route.registryId),
          machine,
          edgeOrdinal,
          coordinate: {machineId: machine.machineId, ...coordinate},
        });
      }
    }
  }
  return cases.sort((left, right) =>
    left.route.normativeOrdinal - right.route.normativeOrdinal ||
    left.machine.machineOrdinal - right.machine.machineOrdinal ||
    left.edgeOrdinal - right.edgeOrdinal);
}

function bridgeGuardId(route, machine, edgeOrdinal, routeVariant) {
  return `guard.transaction.bridge.${pad(route.normativeOrdinal, 2)}.${pad(
    machine.machineOrdinal,
    2,
  )}.${pad(edgeOrdinal, 3)}.${slug(routeVariant)}`;
}

function mobileGuardId(route) {
  return `guard.transaction.mobile.${pad(route.normativeOrdinal, 2)}`;
}

function bridgeManifestId(route, machine, edgeOrdinal, shape) {
  return `tx.bridge.${pad(route.normativeOrdinal, 2)}.${pad(machine.machineOrdinal, 2)}.${pad(
    edgeOrdinal,
    3,
  )}.${shape}`;
}

function mobileManifestId(route) {
  return `tx.mobile.${pad(route.normativeOrdinal, 2)}.apply`;
}

function transactionGuardInventories(machineAuthority, routeCases) {
  const guards = [];
  for (const entry of routeCases) {
    for (const routeVariant of ROUTE_VARIANTS) {
      guards.push({
        registryId: bridgeGuardId(
          entry.route,
          entry.machine,
          entry.edgeOrdinal,
          routeVariant,
        ),
        guardKind: 'AUTHORITATIVE_ROUTE_VARIANT',
        routeRef: routeRef(entry.route.registryId),
        bindingKey: bindingKey('AUTHORITATIVE_MACHINE', entry.machine.machineId),
        coordinate: entry.coordinate,
        routeVariant,
        hasTypedDomainRows: null,
      });
    }
  }
  for (const route of machineAuthority.projectionRoutes) {
    const domainMachines = DOMAIN_MACHINES_BY_ROUTE[route.registryId];
    if (domainMachines === undefined) {
      fail('transaction.route', `no Mobile domain plan for ${route.registryId}`);
    }
    guards.push({
      registryId: mobileGuardId(route),
      guardKind: 'MOBILE_ROUTE_APPLY',
      routeRef: routeRef(route.registryId),
      bindingKey: bindingKey('AUTHORITATIVE_MACHINE', 'SM-REPLICA-APPLY'),
      coordinate: {
        machineId: 'SM-REPLICA-APPLY',
        from: 'RECEIVED',
        to: 'STAGED',
      },
      routeVariant: 'INTERNAL',
      hasTypedDomainRows: domainMachines.length > 0,
    });
  }
  return guards.sort((left, right) => compareUtf16(left.registryId, right.registryId));
}

function transactionOracleInventories(machineAuthority) {
  const projections = [];
  for (const route of machineAuthority.projectionRoutes) {
    const prefix = `oracle.transaction.mobile.${pad(route.normativeOrdinal, 2)}`;
    if (DOMAIN_MACHINES_BY_ROUTE[route.registryId].length > 0) {
      projections.push({
        registryId: `${prefix}.domain-staged`,
        projectionKind: 'DURABLE_DOMAIN_STAGED',
        routeRef: routeRef(route.registryId),
        effectKind: null,
      });
    }
    for (const effectKind of ['READBACK', 'PUBLICATION', 'ACK']) {
      projections.push({
        registryId: `${prefix}.${slug(effectKind)}-effect`,
        projectionKind: 'EXTERNAL_EFFECT_OBSERVED',
        routeRef: routeRef(route.registryId),
        effectKind,
      });
    }
  }
  return projections.sort((left, right) => compareUtf16(left.registryId, right.registryId));
}

function customOracle(route, suffix) {
  return ref(
    'ORACLE_PROJECTION',
    `oracle.transaction.mobile.${pad(route.normativeOrdinal, 2)}.${suffix}`,
  );
}

function orderedGuardRefs(...registryIds) {
  return registryIds
    .map((registryId) => ref('EDGE_GUARD', registryId))
    .sort((left, right) => compareUtf16(left.registryId, right.registryId));
}

function makeSqlSegment({
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

function makeEffectSegment({
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

function bridgeWriteSpecs(machineAuthority, allStorageBindings, entry, shape) {
  const edge = edgeAuthority(machineAuthority, entry.coordinate);
  const originBinding = storageBinding(allStorageBindings, edge.storageBindingRef.registryId);
  const deliveryBinding = storageBinding(
    allStorageBindings,
    'storage.authoritative.sm-durable-delivery',
  );
  const byCoordinate = new Map(deliveryBinding.physicalCoordinates.map((coordinate) => [
    coordinate.coordinateId,
    coordinate,
  ]));
  const writes = authoritativeOwnerCoordinates(originBinding, entry.coordinate).map((coordinate) => ({
    writeRole: 'OWNER_STATE',
    bindingKey: bindingKey('AUTHORITATIVE_MACHINE', entry.machine.machineId),
    physicalStorageCoordinateRef: storageCoordinateRef(
      originBinding.registryId,
      coordinate.coordinateId,
    ),
    rowCardinality: exactRows(),
  }));
  if (shape === 'connected') {
    const deliveryHead = coordinateById(
      deliveryBinding,
      'BRIDGE.durable_delivery_head.state',
    );
    writes.push({
      writeRole: 'OWNER_STATE',
      bindingKey: bindingKey('AUTHORITATIVE_MACHINE', 'SM-DURABLE-DELIVERY'),
      physicalStorageCoordinateRef: storageCoordinateRef(
        deliveryBinding.registryId,
        deliveryHead.coordinateId,
      ),
      rowCardinality: exactRows(),
    });
  }
  if (shape !== 'quiet') {
    const fact = byCoordinate.get('BRIDGE.event_fact.immutable');
    if (!fact) fail('transaction.delivery', 'missing event fact coordinate');
    writes.push({
      writeRole: 'EVENT_FACT',
      bindingKey: bindingKey('AUTHORITATIVE_MACHINE', 'SM-DURABLE-DELIVERY'),
      physicalStorageCoordinateRef: storageCoordinateRef(
        deliveryBinding.registryId,
        fact.coordinateId,
      ),
      rowCardinality: exactRows(),
    });
  }
  if (shape === 'connected') {
    const envelope = byCoordinate.get('BRIDGE.outbox_envelope.immutable');
    if (!envelope) fail('transaction.delivery', 'missing outbox coordinate');
    writes.push({
      writeRole: 'OUTBOX_ENVELOPE',
      bindingKey: bindingKey('AUTHORITATIVE_MACHINE', 'SM-DURABLE-DELIVERY'),
      physicalStorageCoordinateRef: storageCoordinateRef(
        deliveryBinding.registryId,
        envelope.coordinateId,
      ),
      rowCardinality: contextRows('ELIGIBLE_ENVELOPE_COUNT'),
    });
  }
  return writes;
}

function bridgeCase(entry, routeVariant) {
  const edge = edgeAuthority(entry.machineAuthority, entry.coordinate);
  return {
    bindingKey: bindingKey('AUTHORITATIVE_MACHINE', entry.machine.machineId),
    coordinate: entry.coordinate,
    routeRef: routeRef(entry.route.registryId),
    routeVariant,
    guardRefs: orderedGuardRefs(
      edge.guardRefs[0].registryId,
      bridgeGuardId(entry.route, entry.machine, entry.edgeOrdinal, routeVariant),
    ),
  };
}

function buildBridgeManifests(machineAuthority, allStorageBindings, routeCases) {
  const manifests = [];
  for (const rawEntry of routeCases) {
    const entry = {...rawEntry, machineAuthority};
    const edge = edgeAuthority(machineAuthority, entry.coordinate);
    const coordinator = bindingKey('AUTHORITATIVE_MACHINE', entry.machine.machineId);
    for (const [shape, variants] of [
      ['connected', ['PUBLIC_CONNECTED']],
      ['disconnected', ['PUBLIC_DISCONNECTED']],
      ['quiet', ['COALESCED', 'REJECTED', 'INTERNAL']],
    ]) {
      const manifestId = bridgeManifestId(
        entry.route,
        entry.machine,
        entry.edgeOrdinal,
        shape,
      );
      manifests.push({
        manifestId,
        initialDurablePostStateProjectionRef: edge.zeroEffectProjectionRef,
        applicabilityCases: variants.map((variant) => bridgeCase(entry, variant)),
        segments: [makeSqlSegment({
          manifestId,
          segmentOrdinal: 0,
          transactionRole: 'AUTHORITATIVE_OWNER',
          coordinatorBindingKey: coordinator,
          entry: edge.zeroEffectProjectionRef,
          writes: bridgeWriteSpecs(machineAuthority, allStorageBindings, entry, shape),
          commit: edge.successPostStateProjectionRef,
        })],
      });
    }
  }
  return manifests;
}

function replicaCoordinate(machineAuthority, allStorageBindings, machineId) {
  const machine = machineAuthority.machineRecords.find((candidate) =>
    candidate.machineId === machineId);
  if (!machine || machine.replicaWriterBindings.length !== 1) {
    fail('transaction.mobileReplica', `${machineId} needs one replica writer binding`);
  }
  const storageRef = machine.replicaWriterBindings[0].storageBindings[0];
  const binding = storageBinding(allStorageBindings, storageRef.registryId);
  const coordinate = primaryCoordinate(binding);
  return storageCoordinateRef(binding.registryId, coordinate.coordinateId);
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

function buildMobileManifest(machineAuthority, allStorageBindings, route) {
  const manifestId = mobileManifestId(route);
  const coordinator = bindingKey('AUTHORITATIVE_MACHINE', 'SM-REPLICA-APPLY');
  const applyEdge = edgeAuthority(machineAuthority, {
    machineId: 'SM-REPLICA-APPLY',
    from: 'RECEIVED',
    to: 'STAGED',
  });
  const applyBinding = storageBinding(
    allStorageBindings,
    'storage.authoritative.sm-replica-apply',
  );
  const applyCoordinate = primaryCoordinate(applyBinding);
  const inboxBinding = storageBinding(
    allStorageBindings,
    'storage.transaction.sm-replica-apply.inbox',
  );
  const domainBinding = storageBinding(
    allStorageBindings,
    'storage.transaction.sm-replica-apply.domain-staging',
  );
  const commitBinding = storageBinding(
    allStorageBindings,
    'storage.transaction.sm-replica-apply.commit',
  );
  const state = (name) => stateOracle(machineAuthority, 'SM-REPLICA-APPLY', name);
  const domainMachines = DOMAIN_MACHINES_BY_ROUTE[route.registryId];
  const segments = [];

  segments.push(makeSqlSegment({
    manifestId,
    segmentOrdinal: segments.length,
    transactionRole: 'DURABLE_INBOX_STAGING',
    coordinatorBindingKey: coordinator,
    entry: state('RECEIVED'),
    writes: [
      mobileWrite({
        role: 'DURABLE_STAGING',
        machineId: 'SM-REPLICA-APPLY',
        storageId: inboxBinding.registryId,
        coordinateId: 'MOBILE.m_inbox_event.envelope',
        cardinality: contextRows('STAGED_ENVELOPE_COUNT'),
      }),
      mobileWrite({
        role: 'PROGRESS_METADATA',
        machineId: 'SM-REPLICA-APPLY',
        storageId: inboxBinding.registryId,
        coordinateId: 'MOBILE.m_apply_batch.progress',
        cardinality: exactRows(),
      }),
      mobileWrite({
        role: 'APPLY_STATE',
        machineId: 'SM-REPLICA-APPLY',
        storageId: applyBinding.registryId,
        coordinateId: applyCoordinate.coordinateId,
        cardinality: exactRows(),
      }),
    ],
    commit: state('STAGED'),
  }));

  let finalEntry = state('STAGED');
  if (domainMachines.length > 0) {
    finalEntry = customOracle(route, 'domain-staged');
    segments.push(makeSqlSegment({
      manifestId,
      segmentOrdinal: segments.length,
      transactionRole: 'DURABLE_DOMAIN_STAGING',
      coordinatorBindingKey: coordinator,
      entry: state('STAGED'),
      writes: [mobileWrite({
        role: 'DURABLE_STAGING',
        machineId: 'SM-REPLICA-APPLY',
        storageId: domainBinding.registryId,
        coordinateId: 'MOBILE.m_apply_batch_row.immutable',
        cardinality: contextRows('STAGED_TYPED_ROW_COUNT'),
      })],
      commit: finalEntry,
    }));
  }

  const finalWrites = [mobileWrite({
    role: 'PROGRESS_METADATA',
    machineId: 'SM-REPLICA-APPLY',
    storageId: inboxBinding.registryId,
    coordinateId: 'MOBILE.m_apply_batch.progress',
    cardinality: exactRows(),
  })];
  for (const machineId of domainMachines) {
    const coordinate = replicaCoordinate(machineAuthority, allStorageBindings, machineId);
    finalWrites.push({
      writeRole: 'DOMAIN_REPLICA',
      bindingKey: bindingKey('MOBILE_REPLICA', machineId),
      physicalStorageCoordinateRef: coordinate,
      rowCardinality: contextRows('APPLICABLE_DOMAIN_ROW_COUNT'),
    });
  }
  finalWrites.push(
    mobileWrite({
      role: 'APPLY_STATE',
      machineId: 'SM-REPLICA-APPLY',
      storageId: applyBinding.registryId,
      coordinateId: applyCoordinate.coordinateId,
      cardinality: exactRows(),
    }),
    mobileWrite({
      role: 'CHECKPOINT',
      machineId: 'SM-REPLICA-APPLY',
      storageId: commitBinding.registryId,
      coordinateId: 'MOBILE.m_replica_checkpoint.checkpoint_version',
      cardinality: exactRows(),
    }),
    mobileWrite({
      role: 'PUBLICATION_OUTBOX',
      machineId: 'SM-REPLICA-APPLY',
      storageId: commitBinding.registryId,
      coordinateId: 'MOBILE.m_publication_outbox.immutable',
      cardinality: exactRows(),
    }),
  );
  segments.push(makeSqlSegment({
    manifestId,
    segmentOrdinal: segments.length,
    transactionRole: 'FINAL_REPLICA_APPLY',
    coordinatorBindingKey: coordinator,
    entry: finalEntry,
    writes: finalWrites,
    commit: state('APPLIED'),
  }));

  const cas = (transactionRole, entryState, commitState) => makeSqlSegment({
    manifestId,
    segmentOrdinal: segments.length,
    transactionRole,
    coordinatorBindingKey: coordinator,
    entry: state(entryState),
    writes: [mobileWrite({
      role: 'APPLY_STATE',
      machineId: 'SM-REPLICA-APPLY',
      storageId: applyBinding.registryId,
      coordinateId: applyCoordinate.coordinateId,
      cardinality: exactRows(),
    })],
    commit: state(commitState),
  });
  segments.push(makeEffectSegment({
    manifestId,
    segmentOrdinal: segments.length,
    segmentKind: 'READBACK',
    durable: state('APPLIED'),
    effect: customOracle(route, 'readback-effect'),
    replayRule: 'READ_ONLY_REPEATABLE',
  }));
  segments.push(cas('READBACK_STATE_CAS', 'APPLIED', 'READBACK_VERIFIED'));
  segments.push(makeEffectSegment({
    manifestId,
    segmentOrdinal: segments.length,
    segmentKind: 'PUBLICATION',
    durable: state('READBACK_VERIFIED'),
    effect: customOracle(route, 'publication-effect'),
    replayRule: 'IDEMPOTENT_BY_REPOSITORY_PUBLICATION_ID',
  }));
  segments.push(cas('PUBLICATION_STATE_CAS', 'READBACK_VERIFIED', 'PUBLISHED'));
  segments.push(makeEffectSegment({
    manifestId,
    segmentOrdinal: segments.length,
    segmentKind: 'ACK',
    durable: state('PUBLISHED'),
    effect: customOracle(route, 'ack-effect'),
    replayRule: 'IDEMPOTENT_BY_MESSAGE_KEY_AND_COMMITTED_CHECKPOINT',
  }));
  segments.push(cas('ACK_STATE_CAS', 'PUBLISHED', 'ACKED'));

  return {
    manifestId,
    initialDurablePostStateProjectionRef: state('RECEIVED'),
    applicabilityCases: [{
      bindingKey: coordinator,
      coordinate: applyEdge.coordinate,
      routeRef: routeRef(route.registryId),
      routeVariant: 'INTERNAL',
      guardRefs: orderedGuardRefs(
        applyEdge.guardRefs[0].registryId,
        mobileGuardId(route),
      ),
    }],
    segments,
  };
}

export function deriveTransactionSteps(transactionManifests) {
  const rows = [];
  for (const manifest of transactionManifests) {
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
  }
  return rows;
}

export function deriveTransactionKillPoints(transactionManifests, steps) {
  const byManifest = new Map();
  for (const step of steps) {
    const rows = byManifest.get(step.manifestRef.registryId) ?? [];
    rows.push(step);
    byManifest.set(step.manifestRef.registryId, rows);
  }
  const manifests = new Map(transactionManifests.map((manifest) => [
    manifest.manifestId,
    manifest,
  ]));
  const killPoints = [];
  for (const [manifestId, manifestSteps] of byManifest) {
    const manifest = manifests.get(manifestId);
    const segments = new Map(manifest.segments.map((segment) => [segment.segmentOrdinal, segment]));
    for (let index = 0; index + 1 < manifestSteps.length; index += 1) {
      const after = manifestSteps[index];
      const before = manifestSteps[index + 1];
      const segment = segments.get(after.segmentOrdinal);
      let failureOracle;
      if (after.stepKind === 'TX_BEGIN' || after.stepKind === 'WRITE') {
        failureOracle = {
          oracleKind: 'ROLLBACK_OPEN_TRANSACTION',
          durablePostStateProjectionRef: segment.entryDurablePostStateProjectionRef,
          resumeSegmentOrdinal: segment.segmentOrdinal,
        };
      } else if (after.stepKind === 'TX_COMMIT') {
        failureOracle = {
          oracleKind: 'DURABLE_COMMIT_IDEMPOTENT_REPLAY',
          durablePostStateProjectionRef: segment.commitPostStateProjectionRef,
          resumeSegmentOrdinal: before.segmentOrdinal,
        };
      } else {
        failureOracle = {
          oracleKind: 'EXTERNAL_EFFECT_MAY_HAVE_OCCURRED',
          effectKind: after.stepKind,
          replayRule: segment.replayRule,
          durablePostStateProjectionRef: segment.durablePostStateProjectionRef,
          resumeSegmentOrdinal: before.segmentOrdinal,
        };
      }
      killPoints.push({
        killPointId: `${manifestId}:K${after.stepOrdinal}`,
        manifestRef: ref('TRANSACTION_MANIFEST', manifestId),
        afterStepOrdinal: after.stepOrdinal,
        afterStepId: after.stepId,
        beforeStepOrdinal: before.stepOrdinal,
        beforeStepId: before.stepId,
        failureOracle,
      });
    }
  }
  return killPoints;
}

function canonicalConnectedManifests(machineAuthority, transactionManifests) {
  const machineOrdinal = new Map(machineAuthority.machineRecords.map((machine) => [
    machine.machineId,
    machine.machineOrdinal,
  ]));
  const edgeOrdinal = new Map();
  for (const machine of machineAuthority.machineRecords) {
    for (const [ordinal, edge] of machine.allowedEdges.entries()) {
      edgeOrdinal.set(`${machine.machineId}\u0000${edge.from}\u0000${edge.to}`, ordinal);
    }
  }
  return machineAuthority.projectionRoutes.map((route) => {
    const candidates = transactionManifests.filter((manifest) =>
      manifest.applicabilityCases.length === 1 &&
      manifest.applicabilityCases[0].routeVariant === 'PUBLIC_CONNECTED' &&
      manifest.applicabilityCases[0].routeRef.registryId === route.registryId);
    candidates.sort((left, right) => {
      const leftCase = left.applicabilityCases[0];
      const rightCase = right.applicabilityCases[0];
      return machineOrdinal.get(leftCase.coordinate.machineId) -
          machineOrdinal.get(rightCase.coordinate.machineId) ||
        edgeOrdinal.get(`${leftCase.coordinate.machineId}\u0000${leftCase.coordinate.from}\u0000${leftCase.coordinate.to}`) -
          edgeOrdinal.get(`${rightCase.coordinate.machineId}\u0000${rightCase.coordinate.from}\u0000${rightCase.coordinate.to}`);
    });
    if (candidates.length === 0) fail('transaction.bridgeMappings', `no ${route.registryId}`);
    return {route, manifest: candidates[0]};
  });
}

export function deriveBridgeRoutePointBindings(
  machineAuthority,
  transactionManifests,
  transactionSteps,
  transactionKillPoints,
) {
  const stepsByManifest = new Map();
  for (const step of transactionSteps) {
    const rows = stepsByManifest.get(step.manifestRef.registryId) ?? [];
    rows.push(step);
    stepsByManifest.set(step.manifestRef.registryId, rows);
  }
  const killByAfter = new Map(transactionKillPoints.map((killPoint) => [
    `${killPoint.manifestRef.registryId}\u0000${killPoint.afterStepOrdinal}`,
    killPoint,
  ]));
  const rows = [];
  for (const {route, manifest} of canonicalConnectedManifests(
    machineAuthority,
    transactionManifests,
  )) {
    const steps = stepsByManifest.get(manifest.manifestId);
    const roles = (role) => steps.filter((step) =>
      step.stepKind === 'WRITE' && step.writeRole === role);
    const owner = roles('OWNER_STATE');
    const fact = roles('EVENT_FACT');
    const outbox = roles('OUTBOX_ENVELOPE');
    if (owner.length === 0 || fact.length !== 1 || outbox.length === 0) {
      fail('transaction.bridgeMappings', `${manifest.manifestId} has wrong write shape`);
    }
    const afterOrdinals = [
      owner[0].stepOrdinal - 1,
      owner.at(-1).stepOrdinal,
      fact[0].stepOrdinal,
      outbox.at(-1).stepOrdinal,
    ];
    for (const [pointOrdinal, pointKind] of BRIDGE_POINT_KINDS.entries()) {
      const killPoint = killByAfter.get(`${manifest.manifestId}\u0000${afterOrdinals[pointOrdinal]}`);
      if (!killPoint) fail('transaction.bridgeMappings', `missing ${pointKind}`);
      rows.push({
        bridgeMarkerId: `${route.registryId}:${pointKind}`,
        routeRef: routeRef(route.registryId),
        pointKind,
        manifestRef: ref('TRANSACTION_MANIFEST', manifest.manifestId),
        applicabilityCaseOrdinal: 0,
        transactionKillPointId: killPoint.killPointId,
      });
    }
  }
  return rows;
}

export function buildExpectedTransactionAuthority(machineAuthority) {
  const transactionAuxiliaryStorageBindings = auxiliaryStorageBindings(machineAuthority);
  const baseBindings = machineAuthority.storageBindings.filter((binding) =>
    binding.bindingRole !== 'TRANSACTION_AUXILIARY');
  const allStorageBindings = [
    ...baseBindings,
    ...transactionAuxiliaryStorageBindings,
  ].sort((left, right) => compareUtf16(left.registryId, right.registryId));
  const routeCases = authoritativeRouteCases(machineAuthority);
  const transactionGuards = transactionGuardInventories(machineAuthority, routeCases);
  const transactionOracleProjections = transactionOracleInventories(machineAuthority);
  const transactionManifests = [
    ...buildBridgeManifests(machineAuthority, allStorageBindings, routeCases),
    ...machineAuthority.projectionRoutes.map((route) =>
      buildMobileManifest(machineAuthority, allStorageBindings, route)),
  ].sort((left, right) => compareUtf16(left.manifestId, right.manifestId));
  const transactionSteps = deriveTransactionSteps(transactionManifests);
  const transactionKillPoints = deriveTransactionKillPoints(
    transactionManifests,
    transactionSteps,
  );
  const bridgeRoutePointBindings = deriveBridgeRoutePointBindings(
    machineAuthority,
    transactionManifests,
    transactionSteps,
    transactionKillPoints,
  );
  return {
    transactionAuxiliaryStorageBindings,
    transactionGuards,
    transactionOracleProjections,
    transactionManifests,
    transactionSteps,
    transactionKillPoints,
    bridgeRoutePointBindings,
  };
}

function exactInventory(actual, expected, path) {
  if (!jsonEqual(actual, expected)) fail(path, 'does not exact-equal the normalized B2 authority');
}

function unique(values, key, path) {
  const seen = new Set();
  for (const [index, value] of values.entries()) {
    const id = key(value);
    if (seen.has(id)) fail(`${path}[${index}]`, `duplicate ${id}`);
    seen.add(id);
  }
  return seen;
}

function verifyTransactionStructure(machineAuthority, authority) {
  unique(authority.transactionManifests, (row) => row.manifestId, 'transactionManifests');
  unique(authority.transactionSteps, (row) => row.stepId, 'transactionSteps');
  unique(authority.transactionKillPoints, (row) => row.killPointId, 'transactionKillPoints');
  const bridgeIds = unique(
    authority.bridgeRoutePointBindings,
    (row) => row.bridgeMarkerId,
    'bridgeRoutePointBindings',
  );
  if (bridgeIds.size !== machineAuthority.projectionRoutes.length * 4) {
    fail('bridgeRoutePointBindings', 'expected exactly 7 x 4 route points');
  }
  const killIds = new Set(authority.transactionKillPoints.map((row) => row.killPointId));
  for (const row of authority.bridgeRoutePointBindings) {
    if (!killIds.has(row.transactionKillPointId)) {
      fail('bridgeRoutePointBindings', `dangling ${row.transactionKillPointId}`);
    }
  }
  const mobile = authority.transactionManifests.filter((manifest) =>
    manifest.manifestId.startsWith('tx.mobile.'));
  if (mobile.length !== machineAuthority.projectionRoutes.length) {
    fail('transactionManifests', 'expected one Mobile manifest per durable route');
  }
  for (const manifest of mobile) {
    const kinds = manifest.segments.map((segment) =>
      segment.segmentKind === 'SQL_TRANSACTION'
        ? segment.transactionRole
        : segment.segmentKind);
    const hasDomain = kinds.includes('DURABLE_DOMAIN_STAGING');
    const expected = [
      'DURABLE_INBOX_STAGING',
      ...(hasDomain ? ['DURABLE_DOMAIN_STAGING'] : []),
      'FINAL_REPLICA_APPLY',
      'READBACK',
      'READBACK_STATE_CAS',
      'PUBLICATION',
      'PUBLICATION_STATE_CAS',
      'ACK',
      'ACK_STATE_CAS',
    ];
    if (!jsonEqual(kinds, expected)) fail(manifest.manifestId, 'wrong Mobile segment order');
  }
}

function verifyPhysicalWriteClosure(machineAuthority, authority) {
  const bindings = new Map(machineAuthority.storageBindings.map((binding) => [
    binding.registryId,
    binding,
  ]));
  const consumedCoordinates = new Map();
  for (const manifest of authority.transactionManifests) {
    for (const segment of manifest.segments) {
      if (segment.segmentKind !== 'SQL_TRANSACTION') continue;
      for (const write of segment.writes) {
        const ref = write.physicalStorageCoordinateRef;
        const binding = bindings.get(ref.storageBindingRef.registryId);
        if (!binding) fail(write.writeId, `unknown storage binding ${ref.storageBindingRef.registryId}`);
        const coordinate = binding.physicalCoordinates.find((candidate) =>
          candidate.coordinateId === ref.coordinateId);
        if (!coordinate) fail(write.writeId, `unknown physical coordinate ${ref.coordinateId}`);
        if (binding.bindingRole === 'AUTHORITATIVE' &&
            (write.bindingKey.bindingKind !== 'AUTHORITATIVE_MACHINE' ||
              write.bindingKey.machineId !== binding.machineId)) {
          fail(write.writeId, 'authoritative coordinate uses the wrong binding key');
        }
        if (binding.bindingRole === 'REBUILDABLE_REPLICA' &&
            (write.bindingKey.bindingKind !== 'MOBILE_REPLICA' ||
              write.bindingKey.machineId !== binding.machineId)) {
          fail(write.writeId, 'replica coordinate uses the wrong binding key');
        }
        if (binding.bindingRole === 'TRANSACTION_AUXILIARY' &&
            (write.bindingKey.bindingKind !== 'AUTHORITATIVE_MACHINE' ||
              write.bindingKey.machineId !== 'SM-REPLICA-APPLY')) {
          fail(write.writeId, 'transaction auxiliary coordinate uses the wrong binding key');
        }
        const consumers = consumedCoordinates.get(coordinate.coordinateId) ?? [];
        consumers.push({manifestId: manifest.manifestId, writeId: write.writeId});
        consumedCoordinates.set(coordinate.coordinateId, consumers);
      }
    }
  }

  const exemptions = new Set([
    'MOBILE.protected_local_intent.state',
    'BRIDGE.content_offer.state',
  ]);
  for (const binding of machineAuthority.storageBindings) {
    for (const coordinate of binding.physicalCoordinates) {
      if (!exemptions.has(coordinate.coordinateId) &&
          !consumedCoordinates.has(coordinate.coordinateId)) {
        fail('transaction.physicalWriteClosure', `unconsumed ${coordinate.coordinateId}`);
      }
    }
  }

  for (const manifest of authority.transactionManifests.filter((candidate) =>
    candidate.manifestId.startsWith('tx.bridge.'))) {
    const applicability = manifest.applicabilityCases[0];
    const writes = manifest.segments[0].writes;
    const coordinateIds = writes.map((write) =>
      write.physicalStorageCoordinateRef.coordinateId);
    const shape = manifest.manifestId.split('.').at(-1);
    if (shape === 'connected') {
      for (const required of [
        'BRIDGE.durable_delivery_head.state',
        'BRIDGE.event_fact.immutable',
        'BRIDGE.outbox_envelope.immutable',
      ]) {
        if (!coordinateIds.includes(required)) fail(manifest.manifestId, `missing ${required}`);
      }
    }
    if (applicability.coordinate.machineId === 'SM-READ-ATTEMPT' &&
        applicability.coordinate.from === 'VERIFYING' &&
        applicability.coordinate.to === 'VERIFIED' &&
        !coordinateIds.includes('BRIDGE.timeline_read_evidence.immutable')) {
      fail(manifest.manifestId, 'missing verified read evidence write');
    }
    if (applicability.coordinate.machineId === 'SM-RECONCILE') {
      const expected = applicability.coordinate.to === 'REQUESTED'
        ? 'BRIDGE.reconcile_attempt.immutable'
        : 'BRIDGE.reconcile_resolution.immutable';
      if (!coordinateIds.includes(expected)) {
        fail(manifest.manifestId, `missing edge-specific ${expected}`);
      }
    }
  }
}

function definitionField(registry, definitionId, fieldName) {
  const definition = registry.definitions.find((candidate) =>
    candidate.id === definitionId && candidate.profiles.includes(PROFILE_ID));
  if (!definition || definition.node.kind !== 'object') {
    fail(`registry.definitions.${definitionId}`, 'missing active object definition');
  }
  const field = definition.node.fields.find((candidate) => candidate.name === fieldName);
  if (!field) fail(`registry.definitions.${definitionId}.${fieldName}`, 'missing field');
  return field;
}

function verifyGeneratedTransactionDefinitions(registry, machineAuthority, authority) {
  const activeMachine = registry.definitions.find((candidate) =>
    candidate.id === 'ActiveMachineIdV1' && candidate.profiles.includes(PROFILE_ID));
  const machineIds = machineAuthority.machineRecords.map((machine) => machine.machineId);
  if (activeMachine?.node?.kind !== 'enum' ||
      !jsonEqual(activeMachine.node.values, machineIds)) {
    fail('registry.definitions.ActiveMachineIdV1', 'must exact-equal active machine order');
  }
  const totalGuardCount = machineAuthority.edgeGuards.length + authority.transactionGuards.length;
  const guardSet = registry.definitions.find((candidate) =>
    candidate.id === 'CanonicalTransactionGuardRefSetV1');
  if (guardSet?.node?.kind !== 'array' || guardSet.node.maxItems !== totalGuardCount) {
    fail(
      'registry.definitions.CanonicalTransactionGuardRefSetV1.maxItems',
      `expected derived active guard count ${totalGuardCount}`,
    );
  }
  const totalCaseCount = authority.transactionManifests.reduce(
    (count, manifest) => count + manifest.applicabilityCases.length,
    0,
  );
  const totalSegmentCount = authority.transactionManifests.reduce(
    (count, manifest) => count + manifest.segments.length,
    0,
  );
  const totalWriteCount = authority.transactionManifests.flatMap((manifest) =>
    manifest.segments).reduce(
    (count, segment) => count + (segment.segmentKind === 'SQL_TRANSACTION'
      ? segment.writes.length
      : 0),
    0,
  );
  const cases = definitionField(
    registry,
    'TransactionManifestV1',
    'applicabilityCases',
  ).type;
  const segments = definitionField(registry, 'TransactionManifestV1', 'segments').type;
  const writes = definitionField(registry, 'SqlTransactionSegmentV1', 'writes').type;
  if (cases.kind !== 'array' || cases.maxItems !== totalCaseCount) {
    fail('registry.definitions.TransactionManifestV1.applicabilityCases', 'wrong derived maxItems');
  }
  if (segments.kind !== 'array' || segments.maxItems !== totalSegmentCount) {
    fail('registry.definitions.TransactionManifestV1.segments', 'wrong derived maxItems');
  }
  if (writes.kind !== 'array' || writes.maxItems !== totalWriteCount) {
    fail('registry.definitions.SqlTransactionSegmentV1.writes', 'wrong derived maxItems');
  }
}

export function validateTransactionAuthorityRegistry(registry, machineAuthority) {
  const expected = buildExpectedTransactionAuthority(machineAuthority);
  const auxiliary = registry.storageBindings.filter((binding) =>
    binding.bindingRole === 'TRANSACTION_AUXILIARY');
  exactInventory(
    auxiliary,
    expected.transactionAuxiliaryStorageBindings,
    'registry.storageBindings.transactionAuxiliary',
  );
  for (const key of [
    'transactionGuards',
    'transactionOracleProjections',
    'transactionManifests',
  ]) exactInventory(registry[key], expected[key], `registry.${key}`);
  const transactionSteps = deriveTransactionSteps(registry.transactionManifests);
  const transactionKillPoints = deriveTransactionKillPoints(
    registry.transactionManifests,
    transactionSteps,
  );
  const bridgeRoutePointBindings = deriveBridgeRoutePointBindings(
    machineAuthority,
    registry.transactionManifests,
    transactionSteps,
    transactionKillPoints,
  );
  const normalized = {
    transactionAuxiliaryStorageBindings: auxiliary,
    transactionGuards: registry.transactionGuards,
    transactionOracleProjections: registry.transactionOracleProjections,
    transactionManifests: registry.transactionManifests,
    transactionSteps,
    transactionKillPoints,
    bridgeRoutePointBindings,
  };
  verifyTransactionStructure(machineAuthority, normalized);
  verifyPhysicalWriteClosure({
    ...machineAuthority,
    storageBindings: registry.storageBindings,
  }, normalized);
  verifyGeneratedTransactionDefinitions(registry, machineAuthority, normalized);
  return normalized;
}

export function transactionAuthoritySource(authority) {
  return {
    transactionGuards: authority.transactionGuards,
    transactionOracleProjections: authority.transactionOracleProjections,
    transactionManifests: authority.transactionManifests,
    transactionSteps: authority.transactionSteps,
    transactionKillPoints: authority.transactionKillPoints,
    bridgeRoutePointBindings: authority.bridgeRoutePointBindings,
  };
}

function accept() {
  return {valid: true, reason: 'NONE', postState: 'APPLIED', sideEffects: {}};
}

function reject() {
  return {
    valid: false,
    reason: TRANSACTION_FAILURE_REASON,
    postState: 'UNCHANGED',
    sideEffects: ZERO_TRANSACTION_SIDE_EFFECTS,
  };
}

export function evaluateTransactionAuthorityCase(value) {
  return [
    'MANIFEST_SET_EXACT',
    'KILL_POINT_SET_EXACT',
    'BRIDGE_MAPPING_EXACT',
    'MOBILE_SHAPE_EXACT',
  ].includes(value?.caseKind)
    ? accept()
    : reject();
}

export {
  BRIDGE_POINT_KINDS,
  DOMAIN_MACHINES_BY_ROUTE,
  PROFILE_ID as PVMC1_PROFILE_ID,
  ROUTE_VARIANTS,
  TRANSACTION_FAILURE_REASON,
  ZERO_TRANSACTION_SIDE_EFFECTS,
};
