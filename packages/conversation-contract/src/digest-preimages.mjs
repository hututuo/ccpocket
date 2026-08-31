export const CANONICALIZATION_PROFILE = 'RFC8785-IJSON-SAFE-INTEGER-V1';
export const SHA256_HEX_TYPE_ID = 'Sha256Hex64';

function fail(typeId, message) {
  throw new Error(`digest preimage ${typeId}: ${message}`);
}

function requiredDigestDomain(fields, typeId, branch) {
  const matches = fields.filter((field) => field.name === 'digestDomain');
  if (matches.length !== 1) {
    fail(typeId, `${branch} must declare exactly one digestDomain field`);
  }
  const field = matches[0];
  if (!field.required) {
    fail(typeId, `${branch}.digestDomain must be required`);
  }
  if (field.type.kind === 'string' && Object.hasOwn(field.type, 'const')) {
    return field.type.const;
  }
  if (field.type.kind === 'enum') {
    if (Object.hasOwn(field.type, 'const')) return field.type.const;
    if (field.type.values.length === 1) return field.type.values[0];
  }
  fail(typeId, `${branch}.digestDomain must be a string const or single-valued enum const`);
}

function assertClosedNode(node, model, typeId, path, visitedDefinitions) {
  switch (node.kind) {
    case 'string':
    case 'integer':
    case 'boolean':
    case 'enum':
      return;
    case 'array':
      assertClosedNode(node.items, model, typeId, `${path}[]`, visitedDefinitions);
      return;
    case 'nullable':
      assertClosedNode(node.inner, model, typeId, `${path}|null`, visitedDefinitions);
      return;
    case 'map':
      fail(typeId, `${path} reaches an open map`);
      return;
    case 'object':
      for (const field of node.fields) {
        assertClosedNode(
          field.type,
          model,
          typeId,
          `${path}.${field.name}`,
          visitedDefinitions,
        );
      }
      return;
    case 'oneOf':
      for (const [index, variant] of node.variants.entries()) {
        assertClosedNode(
          variant,
          model,
          typeId,
          `${path}<oneOf:${index + 1}>`,
          visitedDefinitions,
        );
      }
      return;
    case 'union':
      for (const variant of node.variants) {
        for (const field of variant.fields) {
          assertClosedNode(
            field.type,
            model,
            typeId,
            `${path}<${variant.tag}>.${field.name}`,
            visitedDefinitions,
          );
        }
      }
      return;
    case 'ref': {
      if (visitedDefinitions.has(node.target)) return;
      const target = model.definitions.get(node.target);
      if (!target || !model.activeDefinitionIds.has(node.target)) {
        fail(typeId, `${path} references inactive definition ${node.target}`);
      }
      visitedDefinitions.add(node.target);
      assertClosedNode(
        target.node,
        model,
        typeId,
        `${path}->${node.target}`,
        visitedDefinitions,
      );
      return;
    }
    default:
      fail(typeId, `${path} has unsupported node kind ${node.kind}`);
  }
}

function domainFields(node, model, typeId, path, seen = new Set()) {
  if (node.kind === 'object') return node.fields;
  if (node.kind === 'ref') {
    if (seen.has(node.target)) fail(typeId, `${path} contains a domain-field reference cycle`);
    const target = model.definitions.get(node.target);
    if (!target || !model.activeDefinitionIds.has(node.target)) {
      fail(typeId, `${path} references inactive definition ${node.target}`);
    }
    return domainFields(target.node, model, typeId, `${path}->${node.target}`, new Set([...seen, node.target]));
  }
  fail(typeId, `${path} must resolve to an object branch`);
}

function domainRule(node, model, typeId, expectedDomain) {
  if (node.kind === 'object') {
    const value = requiredDigestDomain(node.fields, typeId, '$');
    if (value !== expectedDomain) fail(typeId, `digestDomain must equal inventory value ${expectedDomain}`);
    return {kind: 'object', value};
  }
  if (node.kind === 'oneOf') {
    const values = node.variants.map((variant, index) => requiredDigestDomain(
      domainFields(variant, model, typeId, `$<oneOf:${index + 1}>`),
      typeId,
      `$<oneOf:${index + 1}>`,
    ));
    if (values.some((value) => value !== expectedDomain)) {
      fail(typeId, `every oneOf branch digestDomain must equal inventory value ${expectedDomain}`);
    }
    const uniqueValues = [...new Set(values)];
    return uniqueValues.length === 1
      ? {kind: 'object', value: uniqueValues[0]}
      : {kind: 'oneOf', values: uniqueValues};
  }
  const variants = node.variants.map((variant) => ({
    tag: variant.tag,
    value: requiredDigestDomain(
      variant.fields,
      typeId,
      `$<${variant.tag}>`,
    ),
  }));
  if (variants.some((variant) => variant.value !== expectedDomain)) {
    fail(typeId, `every union branch digestDomain must equal inventory value ${expectedDomain}`);
  }
  return {kind: 'union', discriminator: node.discriminator, variants};
}

function assertFrozenPreimage(node, model, typeId) {
  const branches = node.kind === 'object'
    ? [node.fields]
    : node.kind === 'oneOf'
      ? node.variants.map((variant, index) =>
          domainFields(variant, model, typeId, `$<oneOf:${index + 1}>`))
      : node.variants.map((variant) => variant.fields);
  if (branches.some((fields) => fields.some((field) => field.name === 'digestDomain'))) {
    fail(typeId, 'frozen RFC8785 preimage must not declare digestDomain');
  }
}

function requireExactKeys(value, allowed, required, typeId) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    fail(typeId, 'digest derivation must be an object');
  }
  const allowedSet = new Set(allowed);
  for (const key of Object.keys(value)) {
    if (!allowedSet.has(key)) fail(typeId, `digest derivation has unknown field ${key}`);
  }
  for (const key of required) {
    if (!Object.hasOwn(value, key)) fail(typeId, `digest derivation is missing ${key}`);
  }
  return value;
}

/**
 * Resolves generated JCS helpers only from the validated digest-derivation
 * inventory. A type name is never sufficient authority to generate hashing
 * code.
 */
export function discoverDigestPreimages(model) {
  if (!Array.isArray(model.digestDerivations)) {
    fail('authority', 'digestDerivations inventory is required');
  }
  const preimages = [];
  const seenIds = new Set();
  const seenTypes = new Set();
  let previousId = null;
  for (const raw of model.digestDerivations) {
    const typeIdHint = typeof raw?.preimageTypeRef === 'string' ? raw.preimageTypeRef : 'authority';
    const row = requireExactKeys(raw, [
      'id', 'profileId', 'ownerRef', 'derivationMode', 'ownedFieldPaths',
      'preimageTypeRef', 'digestDomain', 'formulaId', 'byteSubjectRef',
    ], [
      'id', 'profileId', 'ownerRef', 'derivationMode', 'ownedFieldPaths',
    ], typeIdHint);
    if (typeof row.id !== 'string' || row.id.length === 0 || seenIds.has(row.id)) {
      fail(typeIdHint, 'digest derivation ids must be non-empty and unique');
    }
    if (previousId !== null && row.id < previousId) {
      fail(typeIdHint, 'digestDerivations must be sorted by id');
    }
    previousId = row.id;
    seenIds.add(row.id);
    if (row.profileId !== model.activeProfileId) continue;
    if (!model.owners.has(row.ownerRef)) fail(typeIdHint, `unknown digest owner ${row.ownerRef}`);
    if (!Array.isArray(row.ownedFieldPaths) ||
        row.ownedFieldPaths.some((path) => typeof path !== 'string')) {
      fail(typeIdHint, 'ownedFieldPaths must be a string array');
    }
    const expectedPaths = [...new Set(row.ownedFieldPaths)].sort();
    if (expectedPaths.length !== row.ownedFieldPaths.length ||
        expectedPaths.some((path, index) => path !== row.ownedFieldPaths[index])) {
      fail(typeIdHint, 'ownedFieldPaths must be sorted and unique');
    }
    if (row.derivationMode === 'STANDARD_EXACT_BYTES') {
      if (typeof row.byteSubjectRef !== 'string' || Object.hasOwn(row, 'preimageTypeRef') ||
          Object.hasOwn(row, 'digestDomain') || Object.hasOwn(row, 'formulaId')) {
        fail(typeIdHint, 'STANDARD_EXACT_BYTES requires only byteSubjectRef');
      }
      continue;
    }
    if (!['DOMAIN_SEPARATED_JCS', 'FROZEN_RFC8785_JCS'].includes(row.derivationMode)) {
      fail(typeIdHint, `unsupported generated derivation mode ${row.derivationMode}`);
    }
    if (typeof row.preimageTypeRef !== 'string') {
      if (row.derivationMode === 'FROZEN_RFC8785_JCS' &&
          typeof row.byteSubjectRef === 'string' && typeof row.formulaId === 'string') continue;
      fail(typeIdHint, `${row.derivationMode} helper requires preimageTypeRef`);
    }
    const typeId = row.preimageTypeRef;
    if (seenTypes.has(typeId)) fail(typeId, 'preimage has more than one digest derivation');
    seenTypes.add(typeId);
    const definition = model.definitions.get(typeId);
    const node = definition?.node;
    if (!model.activeDefinitionIds.has(typeId) || !node ||
        !['object', 'union', 'oneOf'].includes(node.kind)) {
      fail(typeId, 'inventory preimage must be an active closed object, tagged union, or oneOf');
    }
    assertClosedNode(node, model, typeId, '$', new Set([typeId]));
    if (row.derivationMode === 'FROZEN_RFC8785_JCS') {
      if (typeof row.formulaId !== 'string' || Object.hasOwn(row, 'digestDomain') ||
          Object.hasOwn(row, 'byteSubjectRef')) {
        fail(typeId, 'FROZEN_RFC8785_JCS preimage helper requires formulaId and forbids digestDomain/byteSubjectRef');
      }
      assertFrozenPreimage(node, model, typeId);
      preimages.push({typeId, derivationMode: row.derivationMode, domainRule: null});
      continue;
    }
    if (typeof row.digestDomain !== 'string' || Object.hasOwn(row, 'formulaId') ||
        Object.hasOwn(row, 'byteSubjectRef')) {
      fail(typeId, 'DOMAIN_SEPARATED_JCS helper requires digestDomain and forbids formulaId/byteSubjectRef');
    }
    preimages.push({
      typeId,
      derivationMode: row.derivationMode,
      domainRule: domainRule(node, model, typeId, row.digestDomain),
    });
  }
  return preimages.sort((left, right) =>
    left.typeId < right.typeId ? -1 : left.typeId > right.typeId ? 1 : 0);
}
