import { jsonEqual } from './canonical.mjs';
import { validateGeneratedNames } from './names.mjs';

const ID_PATTERN = /^[A-Za-z][A-Za-z0-9_.-]*$/;
const REASON_PATTERN = /^[A-Z][A-Z0-9_]*$/;
const NODE_KINDS = new Set([
  'array',
  'boolean',
  'enum',
  'integer',
  'map',
  'object',
  'ref',
  'string',
  'union',
]);

function fail(path, message) {
  throw new Error(`${path}: ${message}`);
}

function isObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function requireObject(value, path) {
  if (!isObject(value)) fail(path, 'expected an object');
  return value;
}

function requireArray(value, path) {
  if (!Array.isArray(value)) fail(path, 'expected an array');
  return value;
}

function requireString(value, path) {
  if (typeof value !== 'string' || value.length === 0) {
    fail(path, 'expected a non-empty string');
  }
  return value;
}

function requireId(value, path) {
  const id = requireString(value, path);
  if (!ID_PATTERN.test(id)) fail(path, `invalid identifier ${JSON.stringify(id)}`);
  return id;
}

function requireKeys(value, allowed, required, path) {
  const object = requireObject(value, path);
  const allowedSet = new Set(allowed);
  for (const key of Object.keys(object)) {
    if (!allowedSet.has(key)) fail(`${path}.${key}`, 'unknown field');
  }
  for (const key of required) {
    if (!Object.hasOwn(object, key)) fail(`${path}.${key}`, 'required field is missing');
  }
  return object;
}

function uniqueStrings(values, path, { identifiers = false } = {}) {
  const seen = new Set();
  return requireArray(values, path).map((value, index) => {
    const itemPath = `${path}[${index}]`;
    const text = identifiers ? requireId(value, itemPath) : requireString(value, itemPath);
    if (seen.has(text)) fail(itemPath, `duplicate value ${JSON.stringify(text)}`);
    seen.add(text);
    return text;
  });
}

function validateFields(fields, path, visitNode, forbiddenNames = new Set()) {
  const seen = new Set();
  for (const [index, rawField] of requireArray(fields, path).entries()) {
    const fieldPath = `${path}[${index}]`;
    const field = requireKeys(rawField, ['name', 'required', 'type'], ['name', 'required', 'type'], fieldPath);
    const name = requireString(field.name, `${fieldPath}.name`);
    if (seen.has(name)) fail(`${fieldPath}.name`, `duplicate field ${JSON.stringify(name)}`);
    if (forbiddenNames.has(name)) fail(`${fieldPath}.name`, `reserved field ${JSON.stringify(name)}`);
    seen.add(name);
    if (typeof field.required !== 'boolean') fail(`${fieldPath}.required`, 'expected a boolean');
    visitNode(field.type, `${fieldPath}.type`);
  }
}

function visitDslNode(node, path, references) {
  const object = requireObject(node, path);
  const kind = requireString(object.kind, `${path}.kind`);
  if (!NODE_KINDS.has(kind)) fail(`${path}.kind`, `unsupported node kind ${JSON.stringify(kind)}`);

  switch (kind) {
    case 'string':
    case 'integer':
    case 'boolean':
      requireKeys(object, ['kind'], ['kind'], path);
      break;
    case 'ref': {
      requireKeys(object, ['kind', 'target'], ['kind', 'target'], path);
      const target = requireId(object.target, `${path}.target`);
      references.push({ path: `${path}.target`, target });
      break;
    }
    case 'array':
      requireKeys(object, ['kind', 'items'], ['kind', 'items'], path);
      visitDslNode(object.items, `${path}.items`, references);
      break;
    case 'map':
      requireKeys(object, ['kind', 'values'], ['kind', 'values'], path);
      visitDslNode(object.values, `${path}.values`, references);
      break;
    case 'enum':
      requireKeys(object, ['kind', 'values'], ['kind', 'values'], path);
      if (uniqueStrings(object.values, `${path}.values`).length === 0) {
        fail(`${path}.values`, 'an enum must have at least one value');
      }
      break;
    case 'object':
      requireKeys(object, ['kind', 'fields'], ['kind', 'fields'], path);
      validateFields(object.fields, `${path}.fields`, (child, childPath) =>
        visitDslNode(child, childPath, references));
      break;
    case 'union': {
      requireKeys(object, ['kind', 'discriminator', 'variants'], ['kind', 'discriminator', 'variants'], path);
      const discriminator = requireString(object.discriminator, `${path}.discriminator`);
      const tags = new Set();
      const variants = requireArray(object.variants, `${path}.variants`);
      if (variants.length === 0) fail(`${path}.variants`, 'a union must have at least one variant');
      for (const [index, rawVariant] of variants.entries()) {
        const variantPath = `${path}.variants[${index}]`;
        const variant = requireKeys(rawVariant, ['tag', 'fields'], ['tag', 'fields'], variantPath);
        const tag = requireString(variant.tag, `${variantPath}.tag`);
        if (tags.has(tag)) fail(`${variantPath}.tag`, `duplicate union tag ${JSON.stringify(tag)}`);
        tags.add(tag);
        validateFields(
          variant.fields,
          `${variantPath}.fields`,
          (child, childPath) => visitDslNode(child, childPath, references),
          new Set([discriminator]),
        );
      }
      break;
    }
    default:
      fail(`${path}.kind`, `unhandled node kind ${kind}`);
  }
}

function addGlobalId(seen, id, path) {
  if (seen.has(id)) fail(path, `identifier ${JSON.stringify(id)} is already used at ${seen.get(id)}`);
  seen.set(id, path);
}

function simpleInventory(values, name, globalIds) {
  const ids = new Map();
  for (const [index, raw] of requireArray(values, name).entries()) {
    const path = `${name}[${index}]`;
    const item = requireKeys(raw, ['id'], ['id'], path);
    const id = requireId(item.id, `${path}.id`);
    addGlobalId(globalIds, id, `${path}.id`);
    ids.set(id, item);
  }
  return ids;
}

function validateZeroSemantics(value, path) {
  const object = requireObject(value, path);
  const keys = Object.keys(object);
  if (keys.length === 0) fail(path, 'zero semantics must name at least one side effect');
  for (const key of keys) {
    requireId(key, `${path}.${key}`);
    if (object[key] !== 0) fail(`${path}.${key}`, 'zero semantics values must be exactly 0');
  }
  return object;
}

export function validateInputs(registryInput, vectorsInput) {
  const registry = requireKeys(
    registryInput,
    [
      'formatVersion', 'activeProfileId', 'profiles', 'definitions', 'owners',
      'consumers', 'executableTests', 'hardRules', 'vectorSets',
    ],
    [
      'formatVersion', 'activeProfileId', 'profiles', 'definitions', 'owners',
      'consumers', 'executableTests', 'hardRules', 'vectorSets',
    ],
    'registry',
  );
  if (registry.formatVersion !== 1) fail('registry.formatVersion', 'only format version 1 is supported');

  const globalIds = new Map();
  const profiles = new Map();
  for (const [index, raw] of requireArray(registry.profiles, 'registry.profiles').entries()) {
    const path = `registry.profiles[${index}]`;
    const profile = requireKeys(raw, ['id', 'status', 'rootTypeRefs'], ['id', 'status', 'rootTypeRefs'], path);
    const id = requireId(profile.id, `${path}.id`);
    addGlobalId(globalIds, id, `${path}.id`);
    if (!['active', 'planned', 'disabled'].includes(profile.status)) {
      fail(`${path}.status`, 'expected active, planned, or disabled');
    }
    const rootTypeRefs = uniqueStrings(
      profile.rootTypeRefs,
      `${path}.rootTypeRefs`,
      {identifiers: true},
    );
    if (profile.status === 'active' && rootTypeRefs.length === 0) {
      fail(`${path}.rootTypeRefs`, 'an active profile must have at least one root type');
    }
    profiles.set(id, profile);
  }
  const activeProfileId = requireId(registry.activeProfileId, 'registry.activeProfileId');
  const activeProfile = profiles.get(activeProfileId);
  if (!activeProfile) fail('registry.activeProfileId', 'does not reference a profile');
  if (activeProfile.status !== 'active') fail('registry.activeProfileId', 'referenced profile is not active');
  const activeStatuses = [...profiles.values()].filter((profile) => profile.status === 'active');
  if (activeStatuses.length !== 1) fail('registry.profiles', 'exactly one profile must have status active');

  const definitions = new Map();
  const definitionRefs = new Map();
  for (const [index, raw] of requireArray(registry.definitions, 'registry.definitions').entries()) {
    const path = `registry.definitions[${index}]`;
    const definition = requireKeys(raw, ['id', 'profiles', 'node'], ['id', 'profiles', 'node'], path);
    const id = requireId(definition.id, `${path}.id`);
    addGlobalId(globalIds, id, `${path}.id`);
    const profileIds = uniqueStrings(definition.profiles, `${path}.profiles`, { identifiers: true });
    if (profileIds.length === 0) fail(`${path}.profiles`, 'a definition must belong to at least one profile');
    for (const profileId of profileIds) {
      if (!profiles.has(profileId)) fail(`${path}.profiles`, `unknown profile ${JSON.stringify(profileId)}`);
    }
    const references = [];
    if (profileIds.includes(activeProfileId)) {
      visitDslNode(definition.node, `${path}.node`, references);
    }
    definitions.set(id, definition);
    definitionRefs.set(id, references);
  }
  if (![...definitions.values()].some((definition) =>
    definition.profiles.includes(activeProfileId))) {
    fail('registry.definitions', 'the active profile must have at least one definition');
  }
  for (const [sourceId, references] of definitionRefs) {
    const source = definitions.get(sourceId);
    for (const reference of references) {
      const target = definitions.get(reference.target);
      if (!target) fail(reference.path, `unknown definition ${JSON.stringify(reference.target)}`);
      for (const profileId of source.profiles) {
        if (!target.profiles.includes(profileId)) {
          fail(reference.path, `target ${reference.target} is unavailable to profile ${profileId}`);
        }
      }
    }
  }

  const definitionStates = new Map();
  const definitionStack = [];
  const assertAcyclicDefinition = (id, path) => {
    const definition = definitions.get(id);
    if (!definition) fail(path, `unknown definition ${JSON.stringify(id)}`);
    if (!definition.profiles.includes(activeProfileId)) {
      fail(path, `definition ${id} is not enabled for ${activeProfileId}`);
    }
    const state = definitionStates.get(id);
    if (state === 'visiting') {
      const cycleStart = definitionStack.indexOf(id);
      const cycle = [...definitionStack.slice(cycleStart), id];
      fail(path, `active definition dependency cycle: ${cycle.join(' -> ')}`);
    }
    if (state === 'visited') return;
    definitionStates.set(id, 'visiting');
    definitionStack.push(id);
    for (const reference of definitionRefs.get(id)) {
      assertAcyclicDefinition(reference.target, reference.path);
    }
    definitionStack.pop();
    definitionStates.set(id, 'visited');
  };
  for (const [id, definition] of definitions) {
    if (definition.profiles.includes(activeProfileId)) {
      assertAcyclicDefinition(id, `registry.definitions[${JSON.stringify(id)}]`);
    }
  }

  const activeDefinitionIds = new Set();
  const collectDefinition = (id, path) => {
    const definition = definitions.get(id);
    if (!definition) fail(path, `unknown definition ${JSON.stringify(id)}`);
    if (!definition.profiles.includes(activeProfileId)) {
      fail(path, `definition ${id} is not enabled for ${activeProfileId}`);
    }
    if (activeDefinitionIds.has(id)) return;
    activeDefinitionIds.add(id);
    for (const reference of definitionRefs.get(id)) {
      collectDefinition(reference.target, reference.path);
    }
  };
  for (const [index, rootRef] of activeProfile.rootTypeRefs.entries()) {
    collectDefinition(rootRef, `registry.profiles[active].rootTypeRefs[${index}]`);
  }
  validateGeneratedNames(activeDefinitionIds, definitions);

  const owners = simpleInventory(registry.owners, 'registry.owners', globalIds);
  const consumers = simpleInventory(registry.consumers, 'registry.consumers', globalIds);
  const executableTests = simpleInventory(registry.executableTests, 'registry.executableTests', globalIds);

  const hardRules = new Map();
  for (const [index, raw] of requireArray(registry.hardRules, 'registry.hardRules').entries()) {
    const path = `registry.hardRules[${index}]`;
    const base = requireKeys(raw, [
      'id', 'profileId', 'ownerRef', 'consumerRef', 'executableTestRef',
      'failureReason', 'zeroSemantics',
    ], ['id', 'profileId'], path);
    const id = requireId(base.id, `${path}.id`);
    addGlobalId(globalIds, id, `${path}.id`);
    const profileId = requireId(base.profileId, `${path}.profileId`);
    if (!profiles.has(profileId)) fail(`${path}.profileId`, `unknown profile ${profileId}`);
    if (profileId !== activeProfileId) continue;
    requireKeys(raw, [
      'id', 'profileId', 'ownerRef', 'consumerRef', 'executableTestRef',
      'failureReason', 'zeroSemantics',
    ], [
      'id', 'profileId', 'ownerRef', 'consumerRef', 'executableTestRef',
      'failureReason', 'zeroSemantics',
    ], path);
    const ownerRef = requireId(raw.ownerRef, `${path}.ownerRef`);
    const consumerRef = requireId(raw.consumerRef, `${path}.consumerRef`);
    const executableTestRef = requireId(raw.executableTestRef, `${path}.executableTestRef`);
    if (!owners.has(ownerRef)) fail(`${path}.ownerRef`, `unknown owner ${ownerRef}`);
    if (!consumers.has(consumerRef)) fail(`${path}.consumerRef`, `unknown consumer ${consumerRef}`);
    if (!executableTests.has(executableTestRef)) fail(`${path}.executableTestRef`, `unknown executable test ${executableTestRef}`);
    const failureReason = requireString(raw.failureReason, `${path}.failureReason`);
    if (!REASON_PATTERN.test(failureReason) || failureReason === 'NONE') {
      fail(`${path}.failureReason`, 'expected a stable uppercase reason other than NONE');
    }
    validateZeroSemantics(raw.zeroSemantics, `${path}.zeroSemantics`);
    hardRules.set(id, raw);
  }
  if (hardRules.size === 0) {
    fail('registry.hardRules', 'the active profile must have at least one hard rule');
  }

  const vectorSets = new Map();
  for (const [index, raw] of requireArray(registry.vectorSets, 'registry.vectorSets').entries()) {
    const path = `registry.vectorSets[${index}]`;
    const vectorSet = requireKeys(raw, ['id', 'profileId'], ['id', 'profileId'], path);
    const id = requireId(vectorSet.id, `${path}.id`);
    addGlobalId(globalIds, id, `${path}.id`);
    const profileId = requireId(vectorSet.profileId, `${path}.profileId`);
    if (!profiles.has(profileId)) fail(`${path}.profileId`, `unknown profile ${profileId}`);
    if (profileId === activeProfileId) vectorSets.set(id, vectorSet);
  }
  if (vectorSets.size === 0) {
    fail('registry.vectorSets', 'the active profile must have at least one vector set');
  }

  const vectorsDocument = requireKeys(vectorsInput, ['formatVersion', 'vectors'], ['formatVersion', 'vectors'], 'vectors');
  if (vectorsDocument.formatVersion !== 1) fail('vectors.formatVersion', 'only format version 1 is supported');
  const activeVectors = [];
  for (const [index, raw] of requireArray(vectorsDocument.vectors, 'vectors.vectors').entries()) {
    const path = `vectors.vectors[${index}]`;
    const base = requireKeys(raw, [
      'id', 'profileId', 'vectorSetRef', 'ruleRef', 'typeRef', 'valid',
      'expectedReason', 'expectedZeroSideEffects', 'value',
    ], ['id', 'profileId'], path);
    const id = requireId(base.id, `${path}.id`);
    addGlobalId(globalIds, id, `${path}.id`);
    const profileId = requireId(base.profileId, `${path}.profileId`);
    if (!profiles.has(profileId)) fail(`${path}.profileId`, `unknown profile ${profileId}`);
    if (profileId !== activeProfileId) continue;
    const vector = requireKeys(raw, [
      'id', 'profileId', 'vectorSetRef', 'ruleRef', 'typeRef', 'valid',
      'expectedReason', 'expectedZeroSideEffects', 'value',
    ], [
      'id', 'profileId', 'vectorSetRef', 'ruleRef', 'typeRef', 'valid',
      'expectedReason', 'value',
    ], path);
    const vectorSetRef = requireId(vector.vectorSetRef, `${path}.vectorSetRef`);
    const ruleRef = requireId(vector.ruleRef, `${path}.ruleRef`);
    const typeRef = requireId(vector.typeRef, `${path}.typeRef`);
    if (!vectorSets.has(vectorSetRef)) fail(`${path}.vectorSetRef`, `unknown active vector set ${vectorSetRef}`);
    const rule = hardRules.get(ruleRef);
    if (!rule) fail(`${path}.ruleRef`, `unknown active hard rule ${ruleRef}`);
    if (!activeDefinitionIds.has(typeRef)) fail(`${path}.typeRef`, `type ${typeRef} is not in the active closure`);
    if (typeof vector.valid !== 'boolean') fail(`${path}.valid`, 'expected a boolean');
    const expectedReason = requireString(vector.expectedReason, `${path}.expectedReason`);
    if (vector.valid) {
      if (expectedReason !== 'NONE') fail(`${path}.expectedReason`, 'valid vectors must expect NONE');
      if (Object.hasOwn(vector, 'expectedZeroSideEffects')) {
        fail(`${path}.expectedZeroSideEffects`, 'valid vectors must not declare failure side effects');
      }
      const valueErrors = validateValue(typeRef, vector.value, { definitions });
      if (valueErrors.length > 0) fail(`${path}.value`, `valid vector fails its type: ${valueErrors[0]}`);
    } else {
      if (expectedReason !== rule.failureReason) {
        fail(`${path}.expectedReason`, `expected ${rule.failureReason} for rule ${ruleRef}`);
      }
      if (!Object.hasOwn(vector, 'expectedZeroSideEffects')) {
        fail(`${path}.expectedZeroSideEffects`, 'negative vectors require zero-side-effect expectations');
      }
      validateZeroSemantics(vector.expectedZeroSideEffects, `${path}.expectedZeroSideEffects`);
      if (!jsonEqual(vector.expectedZeroSideEffects, rule.zeroSemantics)) {
        fail(`${path}.expectedZeroSideEffects`, `must exactly match ${ruleRef}.zeroSemantics`);
      }
    }
    activeVectors.push(vector);
  }
  for (const [id] of hardRules) {
    if (!activeVectors.some((vector) => vector.valid && vector.ruleRef === id)) {
      fail('vectors.vectors', `active hard rule ${id} has no positive vector`);
    }
    if (!activeVectors.some((vector) => !vector.valid && vector.ruleRef === id)) {
      fail('vectors.vectors', `active hard rule ${id} has no negative vector`);
    }
  }
  for (const [id] of vectorSets) {
    if (!activeVectors.some((vector) => vector.vectorSetRef === id)) {
      fail('vectors.vectors', `active vector set ${id} is empty`);
    }
  }

  return {
    registry,
    vectorsDocument,
    activeProfile,
    activeProfileId,
    definitions,
    activeDefinitionIds,
    owners,
    consumers,
    executableTests,
    hardRules,
    vectorSets,
    activeVectors,
  };
}

export function validateValue(typeRef, value, model) {
  const errors = [];
  const visit = (node, current, path, stack) => {
    switch (node.kind) {
      case 'string':
        if (typeof current !== 'string') errors.push(`${path} must be a string`);
        break;
      case 'integer':
        if (!Number.isSafeInteger(current)) errors.push(`${path} must be a safe integer`);
        break;
      case 'boolean':
        if (typeof current !== 'boolean') errors.push(`${path} must be a boolean`);
        break;
      case 'enum':
        if (typeof current !== 'string' || !node.values.includes(current)) {
          errors.push(`${path} must be one of ${node.values.join(', ')}`);
        }
        break;
      case 'ref': {
        const definition = model.definitions.get(node.target);
        if (!definition) {
          errors.push(`${path} references unknown type ${node.target}`);
        } else if (stack.length > 512) {
          errors.push(`${path} exceeds the reference depth limit`);
        } else {
          visit(definition.node, current, path, [...stack, node.target]);
        }
        break;
      }
      case 'array':
        if (!Array.isArray(current)) errors.push(`${path} must be an array`);
        else current.forEach((entry, index) => visit(node.items, entry, `${path}[${index}]`, stack));
        break;
      case 'map':
        if (!isObject(current)) errors.push(`${path} must be an object map`);
        else Object.entries(current).forEach(([key, entry]) => visit(node.values, entry, `${path}.${key}`, stack));
        break;
      case 'object': {
        if (!isObject(current)) {
          errors.push(`${path} must be an object`);
          break;
        }
        const fields = new Map(node.fields.map((field) => [field.name, field]));
        for (const field of node.fields) {
          if (!Object.hasOwn(current, field.name)) {
            if (field.required) errors.push(`${path}.${field.name} is required`);
          } else {
            visit(field.type, current[field.name], `${path}.${field.name}`, stack);
          }
        }
        for (const key of Object.keys(current)) {
          if (!fields.has(key)) errors.push(`${path}.${key} is not allowed`);
        }
        break;
      }
      case 'union': {
        if (!isObject(current)) {
          errors.push(`${path} must be an object`);
          break;
        }
        const tag = current[node.discriminator];
        const variant = node.variants.find((candidate) => candidate.tag === tag);
        if (!variant) {
          errors.push(`${path}.${node.discriminator} is not a known discriminator`);
          break;
        }
        visit(
          {kind: 'object', fields: [
            {name: node.discriminator, required: true, type: {kind: 'enum', values: [variant.tag]}},
            ...variant.fields,
          ]},
          current,
          path,
          stack,
        );
        break;
      }
      default:
        errors.push(`${path} has unsupported node kind ${node.kind}`);
    }
  };
  const definition = model.definitions.get(typeRef);
  if (!definition) return [`$ references unknown type ${typeRef}`];
  visit(definition.node, value, '$', [typeRef]);
  return errors;
}
