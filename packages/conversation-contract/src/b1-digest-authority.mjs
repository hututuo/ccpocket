const DERIVATION_MODES = new Set([
  'DOMAIN_SEPARATED_JCS',
  'FROZEN_RFC8785_JCS',
  'STANDARD_EXACT_BYTES',
]);
const ALL_MODES = new Set([...DERIVATION_MODES, 'REFERENCE_EQUALITY']);
const ID_PATTERN = /^[A-Za-z][A-Za-z0-9_.-]*$/;

function fail(path, message) {
  throw new Error(`${path}: ${message}`);
}

function isObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function objectAt(value, path) {
  if (!isObject(value)) fail(path, 'expected an object');
  return value;
}

function arrayAt(value, path) {
  if (!Array.isArray(value)) fail(path, 'expected an array');
  return value;
}

function stringAt(value, path) {
  if (typeof value !== 'string' || value.length === 0) {
    fail(path, 'expected a non-empty string');
  }
  return value;
}

function idAt(value, path) {
  const valueId = stringAt(value, path);
  if (!ID_PATTERN.test(valueId)) fail(path, `invalid identifier ${JSON.stringify(valueId)}`);
  return valueId;
}

function exactKeys(value, allowed, required, path) {
  const object = objectAt(value, path);
  const allowedSet = new Set(allowed);
  for (const key of Object.keys(object)) {
    if (!allowedSet.has(key)) fail(`${path}.${key}`, 'unknown field');
  }
  for (const key of required) {
    if (!Object.hasOwn(object, key)) fail(`${path}.${key}`, 'required field is missing');
  }
  return object;
}

function sortedUniqueStrings(value, path) {
  const result = arrayAt(value, path).map((entry, index) =>
    stringAt(entry, `${path}[${index}]`));
  const expected = [...new Set(result)].sort();
  if (expected.length !== result.length) fail(path, 'contains a duplicate value');
  if (expected.some((entry, index) => entry !== result[index])) {
    fail(path, 'must be sorted in lexical order');
  }
  return result;
}

function mapDefinitions(registry) {
  return new Map(arrayAt(registry.definitions, 'registry.definitions').map((definition, index) => {
    const path = `registry.definitions[${index}]`;
    objectAt(definition, path);
    return [idAt(definition.id, `${path}.id`), definition];
  }));
}

function referencedTypeIds(node, result = []) {
  if (!isObject(node)) return result;
  switch (node.kind) {
    case 'ref':
      result.push(node.target);
      break;
    case 'nullable':
      referencedTypeIds(node.inner, result);
      break;
    case 'array':
      referencedTypeIds(node.items, result);
      break;
    case 'map':
      referencedTypeIds(node.values, result);
      break;
    case 'object':
      for (const field of node.fields ?? []) referencedTypeIds(field.type, result);
      break;
    case 'union':
      for (const variant of node.variants ?? []) {
        for (const field of variant.fields ?? []) referencedTypeIds(field.type, result);
      }
      break;
    case 'oneOf':
      for (const variant of node.variants ?? []) referencedTypeIds(variant, result);
      break;
  }
  return result;
}

function collectActiveDefinitionIds(registry, definitions, activeProfileId) {
  const profile = arrayAt(registry.profiles, 'registry.profiles')
    .find((candidate) => candidate.id === activeProfileId);
  if (!profile) fail('registry.activeProfileId', 'does not reference a profile');
  const active = new Set();
  const pending = [...arrayAt(profile.rootTypeRefs, 'registry.profiles[active].rootTypeRefs')];
  while (pending.length > 0) {
    const typeId = pending.pop();
    if (active.has(typeId)) continue;
    const definition = definitions.get(typeId);
    if (!definition) fail('registry.profiles[active].rootTypeRefs', `unknown type ${typeId}`);
    active.add(typeId);
    pending.push(...referencedTypeIds(definition.node));
  }
  return active;
}

function collectDigestFieldsFromNode(node, path, fields) {
  if (!isObject(node)) return;
  if (node.kind === 'string' && path.includes('.') && (
    node.pattern === '^[0-9a-f]{64}$' ||
    typeof node.const === 'string' && /^[0-9a-f]{64}$/.test(node.const)
  )) {
    fields.add(path);
    return;
  }
  if (node.kind === 'ref') {
    if (node.target === 'Sha256Hex64') fields.add(path);
    return;
  }
  if (node.kind === 'nullable') {
    collectDigestFieldsFromNode(node.inner, path, fields);
    return;
  }
  if (node.kind === 'array') {
    collectDigestFieldsFromNode(node.items, `${path}[]`, fields);
    return;
  }
  if (node.kind === 'map') {
    collectDigestFieldsFromNode(node.values, `${path}{}`, fields);
    return;
  }
  if (node.kind === 'object') {
    for (const field of node.fields ?? []) {
      collectDigestFieldsFromNode(field.type, `${path}.${field.name}`, fields);
    }
    return;
  }
  if (node.kind === 'union') {
    for (const variant of node.variants ?? []) {
      for (const field of variant.fields ?? []) {
        collectDigestFieldsFromNode(
          field.type,
          `${path}<${variant.tag}>.${field.name}`,
          fields,
        );
      }
    }
    return;
  }
  if (node.kind === 'oneOf') {
    for (const [index, variant] of (node.variants ?? []).entries()) {
      collectDigestFieldsFromNode(variant, `${path}<ONE_OF_${index}>`, fields);
    }
  }
}

function activeDigestFieldPaths(definitions, activeDefinitionIds) {
  const fields = new Set();
  for (const typeId of [...activeDefinitionIds].sort()) {
    collectDigestFieldsFromNode(definitions.get(typeId)?.node, typeId, fields);
  }
  return [...fields].sort();
}

function rootTypeId(fieldPath) {
  const match = /^([^.<\[]+)/.exec(fieldPath);
  return match?.[1];
}

function terminalFieldName(fieldPath) {
  return fieldPath.slice(fieldPath.lastIndexOf('.') + 1).replace(/\[\]$/, '');
}

function expectedTargetDigestId(fieldPath) {
  const fieldName = terminalFieldName(fieldPath);
  if (fieldName === 'codexBuildSha256' || fieldName === 'codexExecutableDigest' ||
      fieldName === 'providerBuildDigest') {
    return 'DR-CODEX-EXECUTABLE';
  }
  if (fieldName === 'readPlanDigest') return 'DR-READ-PLAN';
  if (fieldName === 'readSpecDigest') return 'DR-READ-SPEC';
  if (fieldName === 'resultDigest') return 'DR-NORMALIZED-RESULT';
  if (['readEvidenceDigest', 'indexReadEvidenceDigest', 'oversizedReadEvidenceDigest']
      .includes(fieldName)) return 'DR-READ-EVIDENCE';
  if (fieldName === 'codexCertificationDigest') return 'DR-CODEX-CERTIFICATION';
  if (fieldName === 'payloadDigest') {
    return fieldPath.startsWith('OperationFingerprintPreimageV1.')
      ? 'DR-OPERATION-PAYLOAD'
      : 'DR-PAYLOAD-COMMITMENT';
  }
  if (fieldName === 'preconditionDigest') return 'DR-OPERATION-PRECONDITION';
  if (fieldName === 'repairIntentDigest') return 'DR-REPAIR-INTENT';
  if (fieldName === 'proofDigest' || fieldName === 'incomingProofDigest') {
    return 'DR-ORDER-PROOF';
  }
  if (fieldName === 'previousPageDigest' || fieldName === 'pageDigest' ||
      fieldName === 'finalPageDigest') return 'DR-PAGE';
  if (fieldName === 'orderDigest') return 'DR-ORDER';
  if (fieldName === 'coverageDigest' || fieldName === 'expectedCoverageDigest') {
    return 'DR-COVERAGE';
  }
  if (fieldName === 'manifestDigest' || fieldName === 'baseManifestDigest') {
    return 'DR-MANIFEST';
  }
  if (fieldName === 'beginHeaderDigest') return 'DR-BEGIN-HEADER';
  if (fieldName === 'receiptDigest') return 'DR-RECEIPT';
  if (fieldName === 'operationFingerprint') {
    return 'DR-OPERATION-FINGERPRINT';
  }
  if (fieldName === 'sqlSha256') {
    return 'DR-PVMC1-MACHINE-TRANSITION-SQL';
  }
  if (fieldPath === 'OperationFingerprintV1.value') return 'DR-OPERATION-FINGERPRINT';
  fail(`registry.digestEqualityReferences.${fieldPath}`, 'has no unique digest target');
}

function assertDomainPreimage(definition, expectedDomain, path) {
  const branches = definition.node?.kind === 'union'
    ? definition.node.variants.map((variant) => ({
        name: `<${variant.tag}>`,
        fields: variant.fields,
      }))
    : definition.node?.kind === 'oneOf'
      ? definition.node.variants.map((variant, index) => ({
          name: `<ONE_OF_${index}>`,
          fields: variant.fields,
        }))
      : [{name: '', fields: definition.node?.fields}];
  if (!['object', 'union', 'oneOf'].includes(definition.node?.kind)) {
    fail(path, 'domain-separated preimage must be an object, union, or oneOf');
  }
  for (const branch of branches) {
    const domains = (branch.fields ?? []).filter((field) => field.name === 'digestDomain');
    const domainNode = domains[0]?.type;
    const domainValue = domainNode?.kind === 'enum' && domainNode.values?.length === 1
      ? domainNode.values[0]
      : domainNode?.kind === 'string'
        ? domainNode.const
        : undefined;
    if (domains.length !== 1 || domains[0].required !== true || domainValue !== expectedDomain) {
      fail(path, `${branch.name || 'object'} does not own exact digestDomain ${expectedDomain}`);
    }
  }
}

function assertFrozenPreimage(definition, path) {
  const nodes = definition.node?.kind === 'union'
    ? definition.node.variants.map((variant) => variant.fields)
    : definition.node?.kind === 'oneOf'
      ? definition.node.variants.map((variant) => variant.fields)
      : [definition.node?.fields];
  if (!['object', 'union', 'oneOf'].includes(definition.node?.kind)) {
    fail(path, 'frozen JCS preimage must be an object, union, or oneOf');
  }
  if (nodes.some((fields) => (fields ?? []).some((field) => field.name === 'digestDomain'))) {
    fail(path, 'frozen JCS preimage must not declare digestDomain');
  }
}

function sortKeyForDependency(edge) {
  return `${edge.relationKind}|${edge.sourceDigestId}->${edge.targetDigestId}|${
    edge.sourceFieldPath ?? ''}`;
}

function assertSortedRows(rows, key, path) {
  const values = rows.map(key);
  const expected = [...values].sort();
  if (new Set(values).size !== values.length) fail(path, 'contains a duplicate row key');
  if (expected.some((entry, index) => entry !== values[index])) {
    fail(path, 'must be sorted deterministically');
  }
}

function collectDependencyDigestFields(
  node,
  path,
  {definitions, ownedPathsByType, result, visiting},
) {
  if (!isObject(node)) return;
  if (node.kind === 'string' && path.includes('.') && (
    node.pattern === '^[0-9a-f]{64}$' ||
    typeof node.const === 'string' && /^[0-9a-f]{64}$/.test(node.const)
  )) {
    result.add(path);
    return;
  }
  if (node.kind === 'ref') {
    if (node.target === 'Sha256Hex64') {
      result.add(path);
      return;
    }
    const ownedBoundary = ownedPathsByType.get(node.target);
    if (ownedBoundary?.length > 0) {
      for (const ownedPath of ownedBoundary) result.add(ownedPath);
      return;
    }
    if (visiting.has(node.target)) return;
    const target = definitions.get(node.target);
    if (!target) return;
    visiting.add(node.target);
    collectDependencyDigestFields(target.node, node.target, {
      definitions,
      ownedPathsByType,
      result,
      visiting,
    });
    visiting.delete(node.target);
    return;
  }
  if (node.kind === 'nullable') {
    collectDependencyDigestFields(node.inner, path, {
      definitions, ownedPathsByType, result, visiting,
    });
    return;
  }
  if (node.kind === 'array') {
    collectDependencyDigestFields(node.items, `${path}[]`, {
      definitions, ownedPathsByType, result, visiting,
    });
    return;
  }
  if (node.kind === 'map') {
    collectDependencyDigestFields(node.values, `${path}{}`, {
      definitions, ownedPathsByType, result, visiting,
    });
    return;
  }
  if (node.kind === 'object') {
    for (const field of node.fields ?? []) {
      collectDependencyDigestFields(field.type, `${path}.${field.name}`, {
        definitions, ownedPathsByType, result, visiting,
      });
    }
    return;
  }
  if (node.kind === 'union') {
    for (const variant of node.variants ?? []) {
      for (const field of variant.fields ?? []) {
        collectDependencyDigestFields(field.type, `${path}<${variant.tag}>.${field.name}`, {
          definitions, ownedPathsByType, result, visiting,
        });
      }
    }
    return;
  }
  if (node.kind === 'oneOf') {
    for (const [index, variant] of (node.variants ?? []).entries()) {
      collectDependencyDigestFields(variant, `${path}<ONE_OF_${index}>`, {
        definitions, ownedPathsByType, result, visiting,
      });
    }
  }
}

function deriveRequiredDependencyEdges({
  derivationById,
  equalityByPath,
  ownedPaths,
  definitions,
}) {
  const required = new Set();
  let predecessorRequired = false;
  const ownedPathsByType = new Map();
  for (const [fieldPath] of ownedPaths) {
    const typeId = rootTypeId(fieldPath);
    const paths = ownedPathsByType.get(typeId) ?? [];
    paths.push(fieldPath);
    ownedPathsByType.set(typeId, paths);
  }
  for (const [ownerDigestId, derivation] of derivationById) {
    if (!derivation.preimageTypeRef) continue;
    const digestFields = new Set();
    collectDependencyDigestFields(
      definitions.get(derivation.preimageTypeRef)?.node,
      derivation.preimageTypeRef,
      {
        definitions,
        ownedPathsByType,
        result: digestFields,
        visiting: new Set([derivation.preimageTypeRef]),
      },
    );
    for (const fieldPath of digestFields) {
      const dependencyDigestId = ownedPaths.get(fieldPath) ??
        equalityByPath.get(fieldPath)?.equalityTargetDigestId;
      if (!dependencyDigestId) continue;
      if (ownerDigestId === 'DR-ORDER-PROOF' &&
          dependencyDigestId === 'DR-MANIFEST' &&
          terminalFieldName(fieldPath) === 'baseManifestDigest') {
        predecessorRequired = true;
        continue;
      }
      if (dependencyDigestId === ownerDigestId && ownerDigestId !== 'DR-PAGE') {
        fail('registry.digestDependencyEdges',
          `unstratified digest self dependency through ${fieldPath}`);
      }
      required.add(`${dependencyDigestId}->${ownerDigestId}`);
    }
  }
  return {ordinary: required, predecessorRequired};
}

function assertAcyclicOrdinaryGraph(edges, path) {
  const adjacency = new Map();
  for (const edge of edges) {
    if (edge.instanceOrderRule !== undefined) continue;
    const targets = adjacency.get(edge.sourceDigestId) ?? [];
    targets.push(edge.targetDigestId);
    adjacency.set(edge.sourceDigestId, targets);
  }
  const state = new Map();
  const stack = [];
  const visit = (node) => {
    if (state.get(node) === 'done') return;
    if (state.get(node) === 'visiting') {
      const start = stack.indexOf(node);
      fail(path, `ordinary digest cycle: ${[...stack.slice(start), node].join(' -> ')}`);
    }
    state.set(node, 'visiting');
    stack.push(node);
    for (const target of adjacency.get(node) ?? []) visit(target);
    stack.pop();
    state.set(node, 'done');
  };
  for (const node of adjacency.keys()) visit(node);
}

export function validateDigestAuthority(
  registry,
  {activeProfileId, activeDefinitionIds, definitions, owners},
) {
  objectAt(registry, 'registry');
  const ownerIds = owners instanceof Map
    ? new Set(owners.keys())
    : new Set(arrayAt(registry.owners, 'registry.owners').map((owner) => owner.id));

  const derivations = arrayAt(registry.digestDerivations, 'registry.digestDerivations');
  assertSortedRows(derivations, (row) => row.id, 'registry.digestDerivations');
  const derivationById = new Map();
  const ownedPaths = new Map();
  const derivationSources = new Set();
  for (const [index, raw] of derivations.entries()) {
    const path = `registry.digestDerivations[${index}]`;
    const common = [
      'id', 'profileId', 'ownerRef', 'derivationMode', 'ownedFieldPaths',
      'preimageTypeRef', 'digestDomain', 'formulaId', 'byteSubjectRef',
    ];
    const row = exactKeys(raw, common, [
      'id', 'profileId', 'ownerRef', 'derivationMode', 'ownedFieldPaths',
    ], path);
    const id = idAt(row.id, `${path}.id`);
    const profileId = idAt(row.profileId, `${path}.profileId`);
    if (profileId !== activeProfileId) continue;
    if (derivationById.has(id)) fail(`${path}.id`, `duplicate digest derivation ${id}`);
    if (!ownerIds.has(row.ownerRef)) fail(`${path}.ownerRef`, `dangling owner ${row.ownerRef}`);
    if (!DERIVATION_MODES.has(row.derivationMode)) {
      fail(`${path}.derivationMode`, `unsupported owning mode ${row.derivationMode}`);
    }
    const paths = sortedUniqueStrings(row.ownedFieldPaths, `${path}.ownedFieldPaths`);
    for (const fieldPath of paths) {
      if (ownedPaths.has(fieldPath)) {
        fail(`${path}.ownedFieldPaths`, `digest field ${fieldPath} has two owners`);
      }
      const expectedOwner = expectedTargetDigestId(fieldPath);
      if (expectedOwner !== id) {
        fail(`${path}.ownedFieldPaths`,
          `wrong digest owner ${id} for ${fieldPath}; expected ${expectedOwner}`);
      }
      ownedPaths.set(fieldPath, id);
    }
    if (row.derivationMode === 'DOMAIN_SEPARATED_JCS') {
      for (const required of ['preimageTypeRef', 'digestDomain']) {
        if (!Object.hasOwn(row, required)) fail(`${path}.${required}`, 'required for DOMAIN_SEPARATED_JCS');
      }
      if (Object.hasOwn(row, 'formulaId') || Object.hasOwn(row, 'byteSubjectRef')) {
        fail(path, 'DOMAIN_SEPARATED_JCS forbids formulaId and byteSubjectRef');
      }
      const typeId = idAt(row.preimageTypeRef, `${path}.preimageTypeRef`);
      const definition = definitions.get(typeId);
      if (!definition || !activeDefinitionIds.has(typeId)) {
        fail(`${path}.preimageTypeRef`, `dangling or inactive preimage type ${typeId}`);
      }
      assertDomainPreimage(definition, stringAt(row.digestDomain, `${path}.digestDomain`), path);
      const source = `TYPE:${typeId}`;
      if (derivationSources.has(source)) fail(path, `preimage ${typeId} has two digest owners`);
      derivationSources.add(source);
    } else if (row.derivationMode === 'FROZEN_RFC8785_JCS') {
      if (!Object.hasOwn(row, 'formulaId')) fail(`${path}.formulaId`, 'required for FROZEN_RFC8785_JCS');
      if (Object.hasOwn(row, 'digestDomain')) fail(`${path}.digestDomain`, 'forbidden for FROZEN_RFC8785_JCS');
      idAt(row.formulaId, `${path}.formulaId`);
      if (Object.hasOwn(row, 'preimageTypeRef') === Object.hasOwn(row, 'byteSubjectRef')) {
        fail(path, 'FROZEN_RFC8785_JCS requires exactly one preimageTypeRef or byteSubjectRef');
      }
      if (Object.hasOwn(row, 'preimageTypeRef')) {
        const typeId = idAt(row.preimageTypeRef, `${path}.preimageTypeRef`);
        const definition = definitions.get(typeId);
        if (!definition || !activeDefinitionIds.has(typeId)) {
          fail(`${path}.preimageTypeRef`, `dangling or inactive preimage type ${typeId}`);
        }
        assertFrozenPreimage(definition, path);
        const source = `TYPE:${typeId}`;
        if (derivationSources.has(source)) fail(path, `preimage ${typeId} has two digest owners`);
        derivationSources.add(source);
      } else {
        const subject = idAt(row.byteSubjectRef, `${path}.byteSubjectRef`);
        const source = `FROZEN:${subject}`;
        if (derivationSources.has(source)) fail(path, `byte subject ${subject} has two digest owners`);
        derivationSources.add(source);
      }
    } else {
      if (!Object.hasOwn(row, 'byteSubjectRef')) {
        fail(`${path}.byteSubjectRef`, 'required for STANDARD_EXACT_BYTES');
      }
      if (Object.hasOwn(row, 'preimageTypeRef') || Object.hasOwn(row, 'digestDomain') ||
          Object.hasOwn(row, 'formulaId')) {
        fail(path, 'STANDARD_EXACT_BYTES accepts only byteSubjectRef');
      }
      const subject = idAt(row.byteSubjectRef, `${path}.byteSubjectRef`);
      const source = `BYTES:${subject}`;
      if (derivationSources.has(source)) fail(path, `byte subject ${subject} has two digest owners`);
      derivationSources.add(source);
    }
    derivationById.set(id, row);
  }

  const equalityRows = arrayAt(
    registry.digestEqualityReferences,
    'registry.digestEqualityReferences',
  );
  assertSortedRows(equalityRows, (row) => row.fieldPath, 'registry.digestEqualityReferences');
  const equalityByPath = new Map();
  for (const [index, raw] of equalityRows.entries()) {
    const path = `registry.digestEqualityReferences[${index}]`;
    const row = exactKeys(raw, [
      'profileId', 'fieldPath', 'derivationMode', 'equalityTargetDigestId',
    ], [
      'profileId', 'fieldPath', 'derivationMode', 'equalityTargetDigestId',
    ], path);
    if (idAt(row.profileId, `${path}.profileId`) !== activeProfileId) continue;
    const fieldPath = stringAt(row.fieldPath, `${path}.fieldPath`);
    if (equalityByPath.has(fieldPath)) fail(`${path}.fieldPath`, `duplicate digest field ${fieldPath}`);
    if (row.derivationMode !== 'REFERENCE_EQUALITY') {
      fail(`${path}.derivationMode`, 'must be REFERENCE_EQUALITY');
    }
    const targetId = idAt(row.equalityTargetDigestId, `${path}.equalityTargetDigestId`);
    if (!derivationById.has(targetId)) fail(`${path}.equalityTargetDigestId`, `dangling target ${targetId}`);
    const expectedTarget = expectedTargetDigestId(fieldPath);
    if (targetId !== expectedTarget) {
      fail(`${path}.equalityTargetDigestId`, `wrong target ${targetId}; expected ${expectedTarget}`);
    }
    equalityByPath.set(fieldPath, row);
  }

  const reachableFields = activeDigestFieldPaths(definitions, activeDefinitionIds);
  const reachableSet = new Set(reachableFields);
  for (const [fieldPath] of ownedPaths) {
    if (!reachableSet.has(fieldPath)) fail('registry.digestDerivations', `owned field is not reachable: ${fieldPath}`);
    if (equalityByPath.has(fieldPath)) fail('registry.digestEqualityReferences', `owning field is also a reference: ${fieldPath}`);
  }
  for (const [fieldPath] of equalityByPath) {
    if (!reachableSet.has(fieldPath)) fail('registry.digestEqualityReferences', `field is not reachable: ${fieldPath}`);
  }
  for (const fieldPath of reachableFields) {
    const count = Number(ownedPaths.has(fieldPath)) + Number(equalityByPath.has(fieldPath));
    if (count !== 1) {
      fail('registry.digestEqualityReferences',
        `reachable digest field ${fieldPath} must appear exactly once as owner or reference`);
    }
  }

  const dependencyRows = arrayAt(registry.digestDependencyEdges, 'registry.digestDependencyEdges');
  assertSortedRows(dependencyRows, sortKeyForDependency, 'registry.digestDependencyEdges');
  const ordinary = [];
  const predecessors = [];
  for (const [index, raw] of dependencyRows.entries()) {
    const path = `registry.digestDependencyEdges[${index}]`;
    objectAt(raw, path);
    if (raw.relationKind === 'ORDINARY') {
      const row = exactKeys(raw, [
        'profileId', 'sourceDigestId', 'targetDigestId', 'relationKind', 'instanceOrderRule',
      ], ['profileId', 'sourceDigestId', 'targetDigestId', 'relationKind'], path);
      if (row.profileId !== activeProfileId) continue;
      for (const key of ['sourceDigestId', 'targetDigestId']) {
        if (!derivationById.has(row[key])) fail(`${path}.${key}`, `dangling digest ${row[key]}`);
      }
      const stratifiedPair = `${row.sourceDigestId}->${row.targetDigestId}`;
      const requiredStratifier = stratifiedPair === 'DR-PAGE->DR-PAGE'
        ? 'PREVIOUS_PAGE_INDEX'
        : stratifiedPair === 'DR-READ-EVIDENCE->DR-NORMALIZED-RESULT'
          ? 'PRIOR_READ_GENERATION'
          : undefined;
      if (requiredStratifier !== undefined && row.instanceOrderRule !== requiredStratifier) {
        fail(`${path}.instanceOrderRule`, `must be ${requiredStratifier}`);
      }
      if (requiredStratifier === undefined && Object.hasOwn(row, 'instanceOrderRule')) {
        fail(`${path}.instanceOrderRule`, 'unexpected ordinary-edge stratifier');
      }
      ordinary.push(row);
    } else if (raw.relationKind === 'PREDECESSOR_REFERENCE') {
      const row = exactKeys(raw, [
        'profileId', 'sourceDigestId', 'targetDigestId', 'relationKind',
        'edgeTypeRef', 'sourceFieldPath', 'targetFieldPath', 'scopeRule',
        'instanceRule', 'versionRule',
      ], [
        'profileId', 'sourceDigestId', 'targetDigestId', 'relationKind',
        'edgeTypeRef', 'sourceFieldPath', 'targetFieldPath', 'scopeRule',
        'instanceRule', 'versionRule',
      ], path);
      if (row.profileId !== activeProfileId) continue;
      if (row.sourceFieldPath === 'PredecessorReferenceEdgeV1.current.manifestDigest' ||
          row.targetFieldPath === 'PredecessorReferenceEdgeV1.current.manifestDigest') {
        fail(path, 'post-derivation current-manifest equality must not enter the digest DAG');
      }
      const exact = {
        sourceDigestId: 'DR-MANIFEST',
        targetDigestId: 'DR-ORDER-PROOF',
        edgeTypeRef: 'PredecessorReferenceEdgeV1',
        sourceFieldPath: 'PredecessorReferenceEdgeV1.base.manifestDigest',
        targetFieldPath: 'PredecessorReferenceEdgeV1.current.proofDigest',
        scopeRule: 'SAME_SOURCE_AND_STABLE_SCOPE',
        instanceRule: 'DISTINCT_MATERIALIZATION',
        versionRule: 'CURRENT_HEAD_IS_BASE_PLUS_ONE',
      };
      for (const [key, expected] of Object.entries(exact)) {
        if (row[key] !== expected) fail(`${path}.${key}`, `expected ${expected}`);
      }
      if (!definitions.has(row.edgeTypeRef) || !activeDefinitionIds.has(row.edgeTypeRef)) {
        fail(`${path}.edgeTypeRef`, `dangling or inactive edge type ${row.edgeTypeRef}`);
      }
      predecessors.push(row);
    } else {
      fail(`${path}.relationKind`, 'expected ORDINARY or PREDECESSOR_REFERENCE');
    }
  }
  if (predecessors.length !== 1) {
    fail('registry.digestDependencyEdges', 'requires exactly one PREDECESSOR_REFERENCE template');
  }
  const ordinarySet = new Set(ordinary.map((edge) =>
    `${edge.sourceDigestId}->${edge.targetDigestId}`));
  assertAcyclicOrdinaryGraph(ordinary, 'registry.digestDependencyEdges');
  const requiredDependencies = deriveRequiredDependencyEdges({
    derivationById,
    equalityByPath,
    ownedPaths,
    definitions,
  });
  if (!requiredDependencies.predecessorRequired) {
    fail('registry.digestDependencyEdges',
      'PREDECESSOR_REFERENCE has no reachable base-manifest dependency');
  }
  for (const edge of requiredDependencies.ordinary) {
    if (!ordinarySet.has(edge)) fail('registry.digestDependencyEdges', `missing ordinary edge ${edge}`);
  }
  if (ordinarySet.size !== requiredDependencies.ordinary.size) {
    fail('registry.digestDependencyEdges', 'contains an extra ordinary dependency edge');
  }

  const guardRows = arrayAt(
    registry.digestPostDerivationGuards,
    'registry.digestPostDerivationGuards',
  );
  assertSortedRows(guardRows, (row) => row.id, 'registry.digestPostDerivationGuards');
  const activeGuards = [];
  for (const [index, raw] of guardRows.entries()) {
    const path = `registry.digestPostDerivationGuards[${index}]`;
    const row = exactKeys(raw, [
      'id', 'profileId', 'validationMode', 'fieldPath',
      'equalityTargetDigestId', 'excludedFromDigestDependencyGraph',
    ], [
      'id', 'profileId', 'validationMode', 'fieldPath',
      'equalityTargetDigestId', 'excludedFromDigestDependencyGraph',
    ], path);
    if (row.profileId !== activeProfileId) continue;
    idAt(row.id, `${path}.id`);
    if (row.validationMode !== 'POST_DERIVATION_VALIDATION_ONLY') {
      fail(`${path}.validationMode`, 'must be POST_DERIVATION_VALIDATION_ONLY');
    }
    if (row.fieldPath !== 'PredecessorReferenceEdgeV1.current.manifestDigest' ||
        row.equalityTargetDigestId !== 'DR-MANIFEST') {
      fail(path, 'must guard only the current predecessor manifest equality');
    }
    if (row.excludedFromDigestDependencyGraph !== true) {
      fail(`${path}.excludedFromDigestDependencyGraph`, 'must be exactly true');
    }
    const equality = equalityByPath.get(row.fieldPath);
    if (equality?.equalityTargetDigestId !== row.equalityTargetDigestId) {
      fail(`${path}.fieldPath`, 'does not resolve the declared equality target');
    }
    activeGuards.push(row);
  }
  if (activeGuards.length !== 1) {
    fail('registry.digestPostDerivationGuards', 'requires exactly one active current-manifest guard');
  }
  const guardedPath = activeGuards[0].fieldPath;
  if (dependencyRows.some((edge) =>
    edge.sourceFieldPath === guardedPath || edge.targetFieldPath === guardedPath)) {
    fail('registry.digestDependencyEdges',
      'post-derivation current-manifest equality must not enter the digest DAG');
  }

  const observedModes = new Set([
    ...[...derivationById.values()].map((row) => row.derivationMode),
    ...[...equalityByPath.values()].map((row) => row.derivationMode),
  ]);
  if (observedModes.size !== ALL_MODES.size ||
      [...ALL_MODES].some((mode) => !observedModes.has(mode))) {
    fail('registry.digestDerivations', 'active derivation modes are not the closed four-mode set');
  }

  return {
    digestDerivations: [...derivationById.values()],
    digestEqualityReferences: [...equalityByPath.values()],
    digestDependencyEdges: [...ordinary, ...predecessors].sort((left, right) => {
      const leftKey = sortKeyForDependency(left);
      const rightKey = sortKeyForDependency(right);
      return leftKey < rightKey ? -1 : leftKey > rightKey ? 1 : 0;
    }),
    digestPostDerivationGuards: activeGuards,
    digestDerivationsById: derivationById,
  };
}

export function validateDigestAuthorityRegistry(registry) {
  const activeProfileId = idAt(registry.activeProfileId, 'registry.activeProfileId');
  const definitions = mapDefinitions(registry);
  const activeDefinitionIds = collectActiveDefinitionIds(
    registry,
    definitions,
    activeProfileId,
  );
  return validateDigestAuthority(registry, {
    activeProfileId,
    activeDefinitionIds,
    definitions,
    owners: new Map(arrayAt(registry.owners, 'registry.owners').map((owner) => [owner.id, owner])),
  });
}

export function digestAuthoritySource(model) {
  return {
    digestDerivations: model.digestDerivations,
    digestEqualityReferences: model.digestEqualityReferences,
    digestDependencyEdges: model.digestDependencyEdges,
    digestPostDerivationGuards: model.digestPostDerivationGuards,
  };
}

function canonicalValue(value) {
  if (Array.isArray(value)) return value.map(canonicalValue);
  if (!isObject(value)) return value;
  return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonicalValue(value[key])]));
}

function sameValue(left, right) {
  return JSON.stringify(canonicalValue(left)) === JSON.stringify(canonicalValue(right));
}

function stableScope(subject) {
  return {
    domain: subject?.domain,
    threadRef: subject?.threadRef,
  };
}

function sourceProjectionMatches(endpoint) {
  const subjectSource = endpoint.subject?.threadRef?.sourcePartition;
  return isObject(endpoint.sourcePartition) && isObject(subjectSource) &&
    sameValue(endpoint.sourcePartition, subjectSource);
}

function predecessorNode(endpoint) {
  return JSON.stringify(canonicalValue({
    sourcePartition: endpoint.sourcePartition,
    subject: endpoint.subject,
    headVersion: endpoint.headVersion,
    manifestDigest: endpoint.manifestDigest,
  }));
}

export function validatePredecessorReferenceInstances(edges) {
  const rows = arrayAt(edges, 'predecessorEdges');
  const graph = new Map();
  const parsed = [];
  for (const [index, raw] of rows.entries()) {
    const path = `predecessorEdges[${index}]`;
    const edge = exactKeys(raw, ['edgeKind', 'relationMode', 'current', 'base'], [
      'edgeKind', 'relationMode', 'current', 'base',
    ], path);
    if (edge.edgeKind !== 'PREDECESSOR_REFERENCE') {
      fail(`${path}.edgeKind`, 'must be PREDECESSOR_REFERENCE');
    }
    if (edge.relationMode !== 'REFERENCE_EQUALITY') {
      fail(`${path}.relationMode`, 'must be REFERENCE_EQUALITY');
    }
    const current = exactKeys(edge.current, [
      'proofDigest', 'sourcePartition', 'subject', 'headVersion', 'manifestDigest',
    ], ['proofDigest', 'sourcePartition', 'subject', 'headVersion', 'manifestDigest'], `${path}.current`);
    const base = exactKeys(edge.base, [
      'sourcePartition', 'subject', 'headVersion', 'manifestDigest',
    ], ['sourcePartition', 'subject', 'headVersion', 'manifestDigest'], `${path}.base`);
    if (!sourceProjectionMatches(current) || !sourceProjectionMatches(base)) {
      fail(path, 'source projection mismatch');
    }
    if (!sameValue(current.sourcePartition, base.sourcePartition) ||
        !sameValue(stableScope(current.subject), stableScope(base.subject))) {
      fail(path, 'cross-scope predecessor reference');
    }
    if (current.subject?.materializationId === base.subject?.materializationId ||
        current.manifestDigest === base.manifestDigest) {
      fail(path, 'self predecessor reference');
    }
    const from = predecessorNode(base);
    const to = predecessorNode(current);
    const targets = graph.get(from) ?? [];
    targets.push(to);
    graph.set(from, targets);
    parsed.push({path, current, base});
  }

  const states = new Map();
  const visit = (node) => {
    if (states.get(node) === 'done') return;
    if (states.get(node) === 'visiting') fail('predecessorEdges', 'cross-instance predecessor cycle');
    states.set(node, 'visiting');
    for (const target of graph.get(node) ?? []) visit(target);
    states.set(node, 'done');
  };
  for (const node of graph.keys()) visit(node);

  for (const {path, current, base} of parsed) {
    if (!Number.isSafeInteger(current.headVersion) || !Number.isSafeInteger(base.headVersion) ||
        current.headVersion <= 0 || base.headVersion <= 0) {
      fail(path, 'head versions must be positive safe integers');
    }
    if (current.headVersion === base.headVersion) fail(path, 'same-version predecessor reference');
    if (current.headVersion < base.headVersion) fail(path, 'reverse predecessor reference');
    if (base.headVersion === Number.MAX_SAFE_INTEGER || current.headVersion !== base.headVersion + 1) {
      fail(path, 'current head version must equal base plus one');
    }
  }
  return true;
}
