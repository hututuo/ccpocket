import fs from 'node:fs';

const registryPath = 'docs/design/codex-kernel-v4/contracts/contract-registry.json';
const registry = JSON.parse(fs.readFileSync(registryPath, 'utf8'));

const ref = (target) => ({kind: 'ref', target});
const nullable = (inner) => ({kind: 'nullable', inner});
const string = (extra = {}) => ({kind: 'string', ...extra});
const integer = (extra = {}) => ({kind: 'integer', ...extra});
const enumeration = (values, extra = {}) => ({kind: 'enum', values, ...extra});
const field = (name, type, required = true) => ({name, required, type});
const object = (fields) => ({kind: 'object', fields});
const array = (items, extra = {}) => ({kind: 'array', items, ...extra});
const oneOf = (variants) => ({kind: 'oneOf', variants});

const PROFILE = 'pvmc1.phone-core.v1';
const SAFE_MIN = Number.MIN_SAFE_INTEGER;
const SAFE_MAX = Number.MAX_SAFE_INTEGER;
const sha = ref('Sha256Hex64');
const sourcePartition = ref('SourcePartitionV1');
const subjectScope = ref('TimelineSubjectScopeV1');
const materializedSubject = ref('TimelineMaterializationSubjectV1');
const turnIndex = ref('TimelineTurnIndexV1');
const fullTurn = ref('TimelineProviderFullTurnV1');
const targetBoundary = ref('TimelineStrongBoundaryV1');

function definition(id, node) {
  return {id, profiles: [PROFILE], node};
}

function upsert(id, node) {
  const existing = registry.definitions.find((candidate) => candidate.id === id);
  if (existing) existing.node = node;
  else registry.definitions.push(definition(id, node));
}

function variantObject(tag, variant) {
  return object([
    field('targetKind', string({const: tag})),
    ...variant.fields,
  ]);
}

const stableTarget = registry.definitions.find((candidate) => candidate.id === 'TimelineGapStableTargetV1')?.node;
if (!stableTarget || stableTarget.kind !== 'union' || stableTarget.discriminator !== 'targetKind') {
  throw new Error('TimelineGapStableTargetV1 must remain the source union for target branches');
}
const targetObjects = new Map(stableTarget.variants.map((variant) => [variant.tag, variantObject(variant.tag, variant)]));

// Keep the broad target union for page rows, but give each closed repair branch
// an unambiguous target class. This makes the seven-way oneOf exclusive without
// introducing a wire-level branch/discriminator field.
upsert('TimelineStructuralGapTargetV1', oneOf([
  targetObjects.get('BEFORE'),
  targetObjects.get('AFTER'),
  targetObjects.get('BETWEEN'),
  targetObjects.get('COVERAGE_UNKNOWN'),
]));
upsert('TimelineItemPayloadGapTargetV1', targetObjects.get('PAYLOAD'));
upsert('TimelineNotLoadedTurnGapTargetV1', targetObjects.get('TURN_PAYLOAD_NOT_LOADED'));
upsert('TimelineOversizedTurnGapSemanticTargetV1', targetObjects.get('TURN_PAYLOAD_OVERSIZED'));

const repairCommon = (targetType, reasonType, repairKind, disposition, includeDigest) => [
  field('digestDomain', string({const: 'ccpocket.gap-repair-intent.v1'})),
  field('sourcePartition', sourcePartition),
  field('subjectScope', subjectScope),
  field('readPlanDigest', sha),
  field('readSpecDigest', sha),
  field('codexCertificationId', string()),
  field('codexCertificationDigest', sha),
  field('target', ref(targetType)),
  field('reason', reasonType),
  field('repairKind', string({const: repairKind})),
  field('repairDisposition', string({const: disposition})),
  ...(includeDigest ? [field('repairIntentDigest', sha)] : []),
];

const repairBranches = (includeDigest) => [
  object(repairCommon(
    'TimelineStructuralGapTargetV1',
    enumeration(['ORDER_UNPROVEN', 'READ_FAILED']),
    'FULL_BOUNDED_REREAD',
    'REPAIRABLE_WITH_CURRENT_PROVIDER_API',
    includeDigest,
  )),
  object(repairCommon(
    'TimelineStructuralGapTargetV1',
    string({const: 'COVERAGE_UNPROVEN'}),
    'NEXT_PROVIDER_PAGE',
    'REPAIRABLE_WITH_CURRENT_PROVIDER_API',
    includeDigest,
  )),
  object(repairCommon(
    'TimelineStructuralGapTargetV1',
    enumeration(['CAPACITY_BOUNDARY', 'PROVIDER_UNSUPPORTED']),
    'NONE',
    'UNREPAIRABLE_WITH_CURRENT_PROVIDER_API',
    includeDigest,
  )),
  object(repairCommon(
    'TimelineItemPayloadGapTargetV1',
    string({const: 'PAYLOAD_UNAVAILABLE'}),
    'LOAD_PAYLOAD',
    'REPAIRABLE_WITH_CURRENT_PROVIDER_API',
    includeDigest,
  )),
  object(repairCommon(
    'TimelineItemPayloadGapTargetV1',
    string({const: 'CAPACITY_BOUNDARY'}),
    'NONE',
    'UNREPAIRABLE_WITH_CURRENT_PROVIDER_API',
    includeDigest,
  )),
  object(repairCommon(
    'TimelineNotLoadedTurnGapTargetV1',
    string({const: 'NOT_LOADED'}),
    'FULL_BOUNDED_REREAD',
    'REPAIRABLE_WITH_CURRENT_PROVIDER_API',
    includeDigest,
  )),
  object(repairCommon(
    'TimelineOversizedTurnGapSemanticTargetV1',
    string({const: 'TURN_PAYLOAD_OVERSIZED'}),
    'NONE',
    'UNREPAIRABLE_WITH_CURRENT_PROVIDER_API',
    includeDigest,
  )),
];
upsert('TimelineGapRepairIntentPreimageV1', oneOf(repairBranches(false)));
upsert('TimelineGapRepairIntentV1', oneOf(repairBranches(true)));

// The coverage preimage has one checked two-field island reference. The order
// preimage retains its richer ordered-island node (which includes orderedTurns).
upsert('TimelineCoverageIslandReferenceV1', object([
  field('islandOrdinal', ref('Ordinal0V1')),
  field('island', ref('TimelineCoverageIslandV1')),
]));
for (const id of ['TimelineMaterializationCoveragePreimageV1']) {
  const node = registry.definitions.find((candidate) => candidate.id === id)?.node;
  if (node?.kind === 'union') {
    for (const variant of node.variants) {
      const islands = variant.fields.find((candidate) => candidate.name === 'orderedIslands');
      if (islands?.type.kind === 'array') islands.type.items = ref('TimelineCoverageIslandReferenceV1');
    }
  }
}

// Exact bounded scalar authority. The generator maps these directly to JSON
// Schema and runtime checks; no semantic helper or generated output is edited.
upsert('SignedJsonSafeIntegerV1', integer({minimum: SAFE_MIN, maximum: SAFE_MAX}));
upsert('Ordinal0V1', integer({minimum: 0, maximum: SAFE_MAX}));
upsert('PositiveJsonSafeIntegerV1', integer({minimum: 1, maximum: SAFE_MAX}));
upsert('PageIndex0To127V1', integer({minimum: 0, maximum: 127}));
upsert('PageCount0To128V1', integer({minimum: 0, maximum: 128}));
upsert('PageCount1To128V1', integer({minimum: 1, maximum: 128}));
upsert('PageIndex1To127V1', integer({minimum: 1, maximum: 127}));
upsert('HeadVersionV1', integer({minimum: 0, maximum: SAFE_MAX}));
upsert('BoundEpochV1', integer({minimum: 1, maximum: SAFE_MAX}));
upsert('UInt64DecimalV1', string({pattern: '^(0|[1-9][0-9]{0,19})$'}));
upsert('Sha256Hex64', string({pattern: '^[0-9a-f]{64}$'}));

const MAX_TURN_BYTES = 4194304;
const MAX_STAGED_BODY_BYTES = 262144;
const MIN_STAGED_TURN_INDEX_BYTES = 241;
const PAGE_BODY_STRUCTURAL_BYTES = 24;
const MAX_PAGES = 128;
const MAX_CAPACITY_ROWS = MAX_PAGES + MAX_PAGES * Math.floor(
  (MAX_STAGED_BODY_BYTES - PAGE_BODY_STRUCTURAL_BYTES) / MIN_STAGED_TURN_INDEX_BYTES,
);

// Exact fixed fields used by the provider result and oversized seam.
for (const id of ['TimelineProviderFullTurnV1', 'TimelineOversizedTurnObservationV1']) {
  const node = registry.definitions.find((candidate) => candidate.id === id)?.node;
  const maximum = node?.fields.find((candidate) => candidate.name === 'maximumTurnByteCount');
  if (maximum) maximum.type = integer({const: MAX_TURN_BYTES});
}
const oversizedTarget = targetObjects.get('TURN_PAYLOAD_OVERSIZED');
const oversizedMaximum = oversizedTarget?.fields.find((candidate) => candidate.name === 'maximumTurnByteCount');
if (oversizedMaximum) oversizedMaximum.type = integer({const: MAX_TURN_BYTES});
const resultNode = registry.definitions.find((candidate) => candidate.id === 'TimelineProviderReadResultPreimageV1')?.node;
const oversizedVariant = resultNode?.variants?.find((candidate) => candidate.tag === 'OVERSIZED_TURN');
const oversizedCount = oversizedVariant?.fields.find((candidate) => candidate.name === 'resultCount');
if (oversizedCount) oversizedCount.type = integer({const: 1});

const itemNode = registry.definitions.find((candidate) => candidate.id === 'TimelineItemV1')?.node;
const payloads = itemNode?.fields.find((candidate) => candidate.name === 'payloads');
if (payloads?.type.kind === 'array') {
  payloads.type.minItems = 0;
  payloads.type.maxItems = 64;
}
const snapshotNode = registry.definitions.find((candidate) => candidate.id === 'TimelineMaterializationSnapshotV1')?.node;
const pages = snapshotNode?.fields.find((candidate) => candidate.name === 'pages');
if (pages?.type.kind === 'array') {
  pages.type.minItems = 0;
  pages.type.maxItems = MAX_PAGES;
  pages.type.uniqueBy = ['pageIndex'];
  pages.type.orderBy = ['pageIndex'];
}
const capacityNode = registry.definitions.find((candidate) => candidate.id === 'TimelineStagedCapacitySetV1');
if (capacityNode?.node.kind === 'array') {
  capacityNode.node.minItems = 0;
  capacityNode.node.maxItems = MAX_CAPACITY_ROWS;
  capacityNode.node.uniqueItems = true;
  capacityNode.node.orderBy = ['pageIndex'];
}

// The immutable adapter certification/probe authority is an active type, not
// a JS-only oracle constant. Its fixed literals mirror semantic-primitives.
const certStatus = enumeration(['CERTIFIED', 'NOT_CERTIFIED', 'UNKNOWN']);
const certificationPreimage = object([
  field('certificationVersion', string({const: 'CodexAdapterCertificationV1'})),
  field('digestDomain', string({const: 'ccpocket.codex-certification.v1'})),
  field('certificationId', string({pattern: '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$'})),
  field('codexExecutableDigest', sha),
  field('providerBuildDigest', sha),
  field('methods', object([
    field('supported', array(enumeration(['thread/turns/list']), {minItems: 1, maxItems: 1, uniqueItems: true})),
    field('unsupported', array(enumeration(['thread/items/list', 'thread/timeline/list']), {minItems: 2, maxItems: 2, uniqueItems: true})),
  ])),
  field('schema', object([
    field('profileId', string({const: PROFILE})),
    field('readPlan', string({const: 'TimelineReadPlanV1'})),
    field('readSpec', string({const: 'TimelineProviderReadSpecV1'})),
    field('normalizedResult', string({const: 'TimelineProviderReadResultV1'})),
    field('readBody', string({const: 'TimelineProviderReadBodyV1'})),
    field('readEvidence', string({const: 'TimelineProviderReadEvidenceV1'})),
  ])),
  field('probe', object([
    field('runtime', object([
      field('thread/turns/list', enumeration(['AVAILABLE', 'RUNTIME_UNAVAILABLE'])),
      field('thread/items/list', enumeration(['AVAILABLE', 'RUNTIME_UNAVAILABLE'])),
      field('thread/timeline/list', enumeration(['AVAILABLE', 'RUNTIME_UNAVAILABLE'])),
    ])),
    field('cursor', string({const: 'OPAQUE_CURSOR_V1'})),
    field('sortDirection', array(enumeration(['asc', 'desc']), {minItems: 2, maxItems: 2, uniqueItems: true})),
    field('itemsView', array(enumeration(['notLoaded', 'full']), {minItems: 2, maxItems: 2, uniqueItems: true})),
  ])),
  field('semantics', object([
    field('identity', string({const: 'TURN_REF_ITEM_REF_V1'})),
    field('ordering', string({const: 'CODEX_THREAD_TURNS_PROVIDER_ORDER_V1'})),
    field('itemOrdering', string({const: 'TURN_ORDINAL_ITEM_ORDINAL_TIMELINE_ORDINAL_CONTIGUITY_V1'})),
    field('predecessorEdge', string({const: 'PREDECESSOR_REFERENCE_EDGE_V1'})),
  ])),
  field('status', object([
    field('historyRead', certStatus),
    field('ordering', certStatus),
    field('cursor', certStatus),
    field('identity', certStatus),
    field('mutation', certStatus),
    field('capacity', certStatus),
  ])),
  field('certificationRevision', integer({minimum: 1, maximum: SAFE_MAX})),
]);
const certificationRecord = object([
  ...certificationPreimage.fields.filter((candidate) => candidate.name !== 'digestDomain' && candidate.name !== 'certificationId'),
  field('codexCertificationId', string({pattern: '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$'})),
  field('codexCertificationDigest', sha),
]);
upsert('CodexAdapterCertificationPreimageV1', certificationPreimage);
upsert('CodexAdapterCertificationV1', certificationRecord);
upsert('CodexAdapterProbeEvidenceV1', object([
  field('providerMethod', string({const: 'thread/turns/list'})),
  field('runtime', object([
    field('thread/turns/list', enumeration(['AVAILABLE', 'RUNTIME_UNAVAILABLE'])),
    field('thread/items/list', enumeration(['AVAILABLE', 'RUNTIME_UNAVAILABLE'])),
    field('thread/timeline/list', enumeration(['AVAILABLE', 'RUNTIME_UNAVAILABLE'])),
  ])),
  field('cursor', string({const: 'OPAQUE_CURSOR_V1'})),
  field('sortDirection', array(enumeration(['asc', 'desc']), {minItems: 2, maxItems: 2, uniqueItems: true})),
  field('itemsView', array(enumeration(['notLoaded', 'full']), {minItems: 2, maxItems: 2, uniqueItems: true})),
  field('identity', string({const: 'TURN_REF_ITEM_REF_V1'})),
  field('ordering', string({const: 'CODEX_THREAD_TURNS_PROVIDER_ORDER_V1'})),
]));

// The normalized result alias is reachable from the independent authority
// bundle while keeping the digest-owning preimage definition unchanged.
upsert('TimelineProviderReadResultV1', ref('TimelineProviderReadResultPreimageV1'));
upsert('TimelinePriorIndexEvidenceV1', object([
  field('evidence', ref('TimelineProviderReadEvidenceV1')),
  field('normalizedResult', ref('TimelineProviderReadResultV1')),
]));
upsert('TimelineMaterializationAuthorityV1', object([
  field('readPlan', ref('TimelineReadPlanV1')),
  field('readSpec', ref('TimelineProviderReadSpecV1')),
  field('normalizedResult', ref('TimelineProviderReadResultV1')),
  field('evidence', ref('TimelineProviderReadEvidenceV1')),
  field('certification', ref('CodexAdapterCertificationV1')),
  field('probeEvidence', ref('CodexAdapterProbeEvidenceV1')),
  field('priorIndexEvidence', ref('TimelinePriorIndexEvidenceV1'), false),
]));

// Make the new certification preimage the active root in place of the weak
// three-field historical placeholder. Keep no parallel weak authority root.
const profile = registry.profiles.find((candidate) => candidate.id === PROFILE);
if (!profile) throw new Error(`missing active profile ${PROFILE}`);
profile.rootTypeRefs = profile.rootTypeRefs.map((id) => id === 'CodexCertificationPreimageV1' ? 'CodexAdapterCertificationPreimageV1' : id);
const oldWeakIndex = registry.definitions.findIndex((candidate) => candidate.id === 'CodexCertificationPreimageV1');
if (oldWeakIndex >= 0) registry.definitions.splice(oldWeakIndex, 1);
for (const id of [
  'TimelineMaterializationAuthorityV1',
  'CodexAdapterCertificationV1',
  'CodexAdapterProbeEvidenceV1',
  'TimelineProviderReadResultV1',
  'TimelineCoverageIslandReferenceV1',
  'TimelineStructuralGapTargetV1',
  'TimelineItemPayloadGapTargetV1',
  'TimelineNotLoadedTurnGapTargetV1',
  'TimelineOversizedTurnGapSemanticTargetV1',
  'PageIndex1To127V1',
]) {
  if (!profile.rootTypeRefs.includes(id)) profile.rootTypeRefs.push(id);
}
const snapshotAuthority = snapshotNode?.fields.find((candidate) => candidate.name === 'authority');
if (!snapshotAuthority) snapshotNode?.fields.push(field('authority', ref('TimelineMaterializationAuthorityV1')));
else snapshotAuthority.required = true;

// Existing single-valued metadata arrays are kept in their original order;
// only new collection authorities use deterministic selector annotations.
fs.writeFileSync(registryPath, `${JSON.stringify(registry, null, 2)}\n`);

console.log(JSON.stringify({
  definitions: registry.definitions.length,
  roots: profile.rootTypeRefs.length,
  maxCapacityRows: MAX_CAPACITY_ROWS,
  changed: [
    'repairIntent.oneOf7',
    'coverageIslandReference.twoFields',
    'boundedScalars',
    'adapterCertification',
    'materializationAuthority',
    'capacitySetConstraints',
  ],
}, null, 2));
