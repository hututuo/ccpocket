import {existsSync, lstatSync, readFileSync} from 'node:fs';
import {Buffer} from 'node:buffer';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

import { canonicalize, compareUtf16, jsonEqual } from './canonical.mjs';
import { validateDigestAuthority } from './b1-digest-authority.mjs';
import { discoverDigestPreimages } from './digest-preimages.mjs';
import { validateGeneratedNames } from './names.mjs';
import { evaluateSemanticRule } from './semantic-oracle.mjs';

const ID_PATTERN = /^[A-Za-z][A-Za-z0-9_.-]*$/;
const REASON_PATTERN = /^[A-Z][A-Z0-9_]*$/;
const SHA256_HEX64 = /^[0-9a-f]{64}$/;
const DIGEST_AUTHORITY_KEYS = [
  'digestDerivations',
  'digestEqualityReferences',
  'digestDependencyEdges',
  'digestPostDerivationGuards',
];
const NODE_KINDS = new Set([
  'array',
  'boolean',
  'enum',
  'integer',
  'map',
  'nullable',
  'object',
  'oneOf',
  'ref',
  'string',
  'union',
]);
const REPOSITORY_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');

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

function requireText(value, path) {
  if (typeof value !== 'string') fail(path, 'expected a string');
  return value;
}

function requireSafeInteger(value, path, {nonNegative = false} = {}) {
  if (!Number.isSafeInteger(value) || nonNegative && value < 0) {
    fail(path, nonNegative ? 'expected a non-negative safe integer' : 'expected a safe integer');
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
    if (!field.required && field.type?.kind === 'nullable') {
      fail(`${fieldPath}.type`, 'nullable fields must be required so absence and null remain distinct');
    }
    visitNode(field.type, `${fieldPath}.type`);
  }
}

function visitDslNode(node, path, references) {
  const object = requireObject(node, path);
  const kind = requireString(object.kind, `${path}.kind`);
  if (!NODE_KINDS.has(kind)) fail(`${path}.kind`, `unsupported node kind ${JSON.stringify(kind)}`);

  switch (kind) {
    case 'string': {
      requireKeys(object, ['kind', 'const', 'pattern'], ['kind'], path);
      if (Object.hasOwn(object, 'const')) requireText(object.const, `${path}.const`);
      if (Object.hasOwn(object, 'pattern')) {
        const pattern = requireText(object.pattern, `${path}.pattern`);
        try {
          new RegExp(pattern, 'u');
        } catch {
          fail(`${path}.pattern`, 'expected a valid ECMAScript Unicode regular expression');
        }
        if (Object.hasOwn(object, 'const') && !new RegExp(pattern, 'u').test(object.const)) {
          fail(`${path}.const`, 'does not match pattern');
        }
      }
      break;
    }
    case 'integer': {
      requireKeys(object, ['kind', 'const', 'minimum', 'maximum'], ['kind'], path);
      const minimum = Object.hasOwn(object, 'minimum')
        ? requireSafeInteger(object.minimum, `${path}.minimum`)
        : Number.MIN_SAFE_INTEGER;
      const maximum = Object.hasOwn(object, 'maximum')
        ? requireSafeInteger(object.maximum, `${path}.maximum`)
        : Number.MAX_SAFE_INTEGER;
      if (minimum > maximum) fail(path, 'minimum must not exceed maximum');
      if (Object.hasOwn(object, 'const')) {
        const value = requireSafeInteger(object.const, `${path}.const`);
        if (value < minimum || value > maximum) fail(`${path}.const`, 'must be within minimum and maximum');
      }
      break;
    }
    case 'boolean':
      requireKeys(object, ['kind', 'const'], ['kind'], path);
      if (Object.hasOwn(object, 'const') && typeof object.const !== 'boolean') {
        fail(`${path}.const`, 'expected a boolean');
      }
      break;
    case 'nullable':
      requireKeys(object, ['kind', 'inner'], ['kind', 'inner'], path);
      if (object.inner?.kind === 'nullable') fail(`${path}.inner`, 'nested nullable nodes are redundant');
      visitDslNode(object.inner, `${path}.inner`, references);
      break;
    case 'ref': {
      requireKeys(object, ['kind', 'target'], ['kind', 'target'], path);
      const target = requireId(object.target, `${path}.target`);
      references.push({ path: `${path}.target`, target });
      break;
    }
    case 'array': {
      requireKeys(
        object,
        ['kind', 'items', 'minItems', 'maxItems', 'uniqueItems', 'uniqueBy', 'orderBy'],
        ['kind', 'items'],
        path,
      );
      const minimum = Object.hasOwn(object, 'minItems')
        ? requireSafeInteger(object.minItems, `${path}.minItems`, {nonNegative: true})
        : 0;
      const maximum = Object.hasOwn(object, 'maxItems')
        ? requireSafeInteger(object.maxItems, `${path}.maxItems`, {nonNegative: true})
        : Number.MAX_SAFE_INTEGER;
      if (minimum > maximum) fail(path, 'minItems must not exceed maxItems');
      if (Object.hasOwn(object, 'uniqueItems') && typeof object.uniqueItems !== 'boolean') {
        fail(`${path}.uniqueItems`, 'expected a boolean');
      }
      for (const selectorKey of ['uniqueBy', 'orderBy']) {
        if (!Object.hasOwn(object, selectorKey)) continue;
        const selectors = uniqueStrings(object[selectorKey], `${path}.${selectorKey}`);
        if (selectors.length === 0) fail(`${path}.${selectorKey}`, 'must contain at least one field selector');
        for (const [index, selector] of selectors.entries()) {
          if (selector.split('.').some((segment) => segment.length === 0)) {
            fail(`${path}.${selectorKey}[${index}]`, 'field paths must contain non-empty dot-separated segments');
          }
        }
      }
      visitDslNode(object.items, `${path}.items`, references);
      break;
    }
    case 'map':
      requireKeys(object, ['kind', 'values'], ['kind', 'values'], path);
      visitDslNode(object.values, `${path}.values`, references);
      break;
    case 'enum':
      requireKeys(object, ['kind', 'values', 'const'], ['kind', 'values'], path);
      if (uniqueStrings(object.values, `${path}.values`).length === 0) {
        fail(`${path}.values`, 'an enum must have at least one value');
      }
      if (Object.hasOwn(object, 'const')) {
        const value = requireText(object.const, `${path}.const`);
        if (!object.values.includes(value)) fail(`${path}.const`, 'must be one of the enum values');
      }
      break;
    case 'object':
      requireKeys(object, ['kind', 'fields'], ['kind', 'fields'], path);
      validateFields(object.fields, `${path}.fields`, (child, childPath) =>
        visitDslNode(child, childPath, references));
      break;
    case 'oneOf': {
      requireKeys(object, ['kind', 'variants'], ['kind', 'variants'], path);
      const variants = requireArray(object.variants, `${path}.variants`);
      if (variants.length < 2) fail(`${path}.variants`, 'oneOf must have at least two variants');
      for (const [index, variant] of variants.entries()) {
        visitDslNode(variant, `${path}.variants[${index}]`, references);
      }
      break;
    }
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

function dereferenceNode(node, definitions, path) {
  let current = node;
  const seen = new Set();
  while (current.kind === 'ref') {
    if (seen.has(current.target)) fail(path, `selector reference cycle through ${current.target}`);
    seen.add(current.target);
    const definition = definitions.get(current.target);
    if (!definition) fail(path, `selector references unknown definition ${current.target}`);
    current = definition.node;
  }
  return current;
}

function selectedFieldNodes(itemNode, selector, definitions, path) {
  if (selector === '$') {
    const node = dereferenceNode(itemNode, definitions, path);
    if (!['object', 'union', 'oneOf'].includes(node.kind)) {
      fail(path, 'the $ orderBy selector requires object, union, or oneOf array items');
    }
    return [node];
  }
  let nodes = [itemNode];
  for (const segment of selector.split('.')) {
    const next = [];
    for (const rawNode of nodes) {
      const node = dereferenceNode(rawNode, definitions, path);
      if (node.kind === 'object') {
        const field = node.fields.find((candidate) => candidate.name === segment);
        if (!field) fail(path, `unknown item field selector ${JSON.stringify(selector)}`);
        if (!field.required) fail(path, `item field selector ${JSON.stringify(selector)} must be required`);
        next.push(field.type);
        continue;
      }
      if (node.kind === 'union') {
        if (segment === node.discriminator) {
          next.push({kind: 'enum', values: node.variants.map((variant) => variant.tag)});
          continue;
        }
        for (const variant of node.variants) {
          const field = variant.fields.find((candidate) => candidate.name === segment);
          if (!field) {
            fail(path, `item field selector ${JSON.stringify(selector)} is absent from variant ${JSON.stringify(variant.tag)}`);
          }
          if (!field.required) {
            fail(path, `item field selector ${JSON.stringify(selector)} must be required in variant ${JSON.stringify(variant.tag)}`);
          }
          next.push(field.type);
        }
        continue;
      }
      if (node.kind === 'oneOf') {
        for (const variant of node.variants) next.push(...selectedFieldNodes(variant, segment, definitions, path));
        continue;
      }
      fail(path, 'field selectors require object, union, or oneOf array items');
    }
    nodes = next;
  }
  return nodes;
}

function isOrderableSelectorNode(rawNode, definitions, path) {
  const node = dereferenceNode(rawNode, definitions, path);
  if (node.kind === 'nullable') return isOrderableSelectorNode(node.inner, definitions, path);
  return ['string', 'integer', 'boolean', 'enum'].includes(node.kind);
}

function validateArrayConstraintSelectors(node, path, definitions) {
  switch (node.kind) {
    case 'array':
      for (const selectorKey of ['uniqueBy', 'orderBy']) {
        for (const [index, selector] of (node[selectorKey] ?? []).entries()) {
          const selectorPath = `${path}.${selectorKey}[${index}]`;
          if (selector === '$' && selectorKey !== 'orderBy') {
            fail(selectorPath, 'the $ selector is supported only by orderBy');
          }
          const selected = selectedFieldNodes(node.items, selector, definitions, selectorPath);
          if (selectorKey === 'orderBy' && selector !== '$') {
            for (const selectedNode of selected) {
              if (!isOrderableSelectorNode(selectedNode, definitions, selectorPath)) {
                fail(selectorPath, 'orderBy selectors must resolve to string, integer, boolean, enum, or nullable forms of those scalars');
              }
            }
          }
        }
      }
      validateArrayConstraintSelectors(node.items, `${path}.items`, definitions);
      break;
    case 'nullable':
      validateArrayConstraintSelectors(node.inner, `${path}.inner`, definitions);
      break;
    case 'map':
      validateArrayConstraintSelectors(node.values, `${path}.values`, definitions);
      break;
    case 'object':
      for (const [index, field] of node.fields.entries()) {
        if (!field.required && dereferenceNode(field.type, definitions, `${path}.fields[${index}].type`).kind === 'nullable') {
          fail(`${path}.fields[${index}].type`, 'nullable fields must be required so absence and null remain distinct');
        }
        validateArrayConstraintSelectors(field.type, `${path}.fields[${index}].type`, definitions);
      }
      break;
    case 'union':
      for (const [variantIndex, variant] of node.variants.entries()) {
        for (const [fieldIndex, field] of variant.fields.entries()) {
          if (!field.required && dereferenceNode(
            field.type,
            definitions,
            `${path}.variants[${variantIndex}].fields[${fieldIndex}].type`,
          ).kind === 'nullable') {
            fail(
              `${path}.variants[${variantIndex}].fields[${fieldIndex}].type`,
              'nullable fields must be required so absence and null remain distinct',
            );
          }
          validateArrayConstraintSelectors(
            field.type,
            `${path}.variants[${variantIndex}].fields[${fieldIndex}].type`,
            definitions,
          );
        }
      }
      break;
    case 'oneOf':
      for (const [index, variant] of node.variants.entries()) {
        validateArrayConstraintSelectors(variant, `${path}.variants[${index}]`, definitions);
      }
      break;
    case 'ref':
    case 'string':
    case 'integer':
    case 'boolean':
    case 'enum':
      break;
    default:
      fail(path, `unhandled node kind ${node.kind}`);
  }
}

function addGlobalId(seen, id, path) {
  if (seen.has(id)) fail(path, `identifier ${JSON.stringify(id)} is already used at ${seen.get(id)}`);
  seen.set(id, path);
}

function simpleInventory(values, name, globalIds, {executableBinding = false, metadata = [], owners} = {}) {
  const ids = new Map();
  for (const [index, raw] of requireArray(values, name).entries()) {
    const path = `${name}[${index}]`;
    const allowed = executableBinding
      ? ['id', 'ownerRef', 'path', 'command', 'evidence']
      : ['id', ...metadata];
    const item = requireKeys(raw, allowed, executableBinding
      ? ['id', 'ownerRef', 'path', 'command', 'evidence']
      : ['id'], path);
    const id = requireId(item.id, `${path}.id`);
    if (executableBinding) {
      requireId(item.ownerRef, `${path}.ownerRef`);
      if (!owners?.has(item.ownerRef)) fail(`${path}.ownerRef`, `unknown owner ${item.ownerRef}`);
      requireString(item.path, `${path}.path`);
      requireString(item.command, `${path}.command`);
      requireString(item.evidence, `${path}.evidence`);
      validateExecutableBinding(item, path, {test: name.endsWith('executableTests')});
    }
    addGlobalId(globalIds, id, `${path}.id`);
    ids.set(id, item);
  }
  return ids;
}

function validateRepoRelativePath(value, pathName, {file = false, mustExist = true} = {}) {
  if (value.startsWith('/') || value.includes('\\') || value.split('/').includes('..')) {
    fail(pathName, 'must be a repository-relative path');
  }
  const resolved = path.resolve(REPOSITORY_ROOT, value);
  if (!resolved.startsWith(`${REPOSITORY_ROOT}${path.sep}`) || mustExist && !existsSync(resolved)) {
    fail(pathName, `path does not exist: ${value}`);
  }
  if (file) {
    if (!path.extname(resolved)) fail(pathName, 'must name a file');
    let stat;
    try {
      stat = lstatSync(resolved);
    } catch {
      stat = null;
    }
    if (!stat || !stat.isFile() || stat.isSymbolicLink()) {
      fail(pathName, 'must name an existing regular non-symlink file');
    }
  }
  return resolved;
}

function validateEvidenceReference(value, pathName) {
  const evidenceParts = value.split('#');
  if (evidenceParts.length > 2 || evidenceParts[0].length === 0) {
    fail(pathName, 'expected path or path#anchor');
  }
  const evidencePath = evidenceParts[0];
  const resolvedEvidence = validateRepoRelativePath(evidencePath, pathName, {file: true});
  const anchor = evidenceParts.length === 2 ? evidenceParts[1] : null;
  if (anchor !== null && (anchor.length === 0 || !readFileSync(resolvedEvidence, 'utf8').includes(anchor))) {
    fail(pathName, `anchor is not present in ${evidencePath}`);
  }
  return {evidencePath, resolvedEvidence};
}

function validateExecutableBinding(item, pathName, {test = false} = {}) {
  const {evidencePath} = validateEvidenceReference(item.evidence, `${pathName}.evidence`);
  if (!item.command.includes(evidencePath)) {
    fail(`${pathName}.command`, `must invoke evidence path ${evidencePath}`);
  }
  if (test && item.path !== evidencePath) {
    fail(`${pathName}.path`, `must equal evidence path ${evidencePath}`);
  } else {
    validateRepoRelativePath(item.path, `${pathName}.path`, {mustExist: false});
  }
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
  const activeProfileIdHint = registryInput?.activeProfileId;
  const pvmcRegistry = activeProfileIdHint === 'pvmc1.phone-core.v1';
  const registry = requireKeys(
    registryInput,
    [
      'formatVersion', 'activeProfileId', 'profiles', 'definitions', 'owners',
      'consumers', 'executableTests', 'hardRules', 'vectorSets',
      ...DIGEST_AUTHORITY_KEYS,
    ],
    [
      'formatVersion', 'activeProfileId', 'profiles', 'definitions', 'owners',
      'consumers', 'executableTests', 'hardRules', 'vectorSets',
      'digestDerivations',
      ...(pvmcRegistry ? DIGEST_AUTHORITY_KEYS.slice(1) : []),
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
  for (const id of activeDefinitionIds) {
    validateArrayConstraintSelectors(
      definitions.get(id).node,
      `registry.definitions[${JSON.stringify(id)}].node`,
      definitions,
    );
  }
  validateGeneratedNames(activeDefinitionIds, definitions);

  const owners = simpleInventory(registry.owners, 'registry.owners', globalIds, {metadata: ['role', 'path']});
  if (pvmcRegistry) {
    for (const [id, owner] of owners) {
      validateRepoRelativePath(owner.path, `registry.owners.${id}.path`);
    }
  }
  const consumers = simpleInventory(registry.consumers, 'registry.consumers', globalIds, {
    executableBinding: pvmcRegistry,
    owners,
  });
  const executableTests = simpleInventory(registry.executableTests, 'registry.executableTests', globalIds, {
    executableBinding: pvmcRegistry,
    owners,
  });
  const digestAuthority = pvmcRegistry
    ? validateDigestAuthority(registry, {
        activeProfileId,
        activeDefinitionIds,
        definitions,
        owners,
      })
    : {
        digestDerivations: requireArray(registry.digestDerivations, 'registry.digestDerivations'),
        digestEqualityReferences: [],
        digestDependencyEdges: [],
        digestPostDerivationGuards: [],
        digestDerivationsById: new Map(),
      };

  const hardRules = new Map();
  for (const [index, raw] of requireArray(registry.hardRules, 'registry.hardRules').entries()) {
    const path = `registry.hardRules[${index}]`;
    const commonFields = [
      'id', 'profileId', 'ownerRef', 'consumerRef', 'executableTestRef',
      'failureReason', 'zeroSemantics',
    ];
    const base = requireKeys(raw, [...commonFields, 'oracleRef', 'evidenceRef'], ['id', 'profileId'], path);
    const id = requireId(base.id, `${path}.id`);
    addGlobalId(globalIds, id, `${path}.id`);
    const profileId = requireId(base.profileId, `${path}.profileId`);
    if (!profiles.has(profileId)) fail(`${path}.profileId`, `unknown profile ${profileId}`);
    if (profileId !== activeProfileId) continue;
    const activeFields = pvmcRegistry
      ? [...commonFields, 'oracleRef', 'evidenceRef']
      : commonFields;
    requireKeys(raw, activeFields, activeFields, path);
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
    if (pvmcRegistry) {
      requireId(raw.oracleRef, `${path}.oracleRef`);
      requireString(raw.evidenceRef, `${path}.evidenceRef`);
      validateEvidenceReference(raw.evidenceRef, `${path}.evidenceRef`);
    }
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
      'expectedReason', 'expectedTypeError', 'expectedZeroSideEffects', 'expectedPostState', 'value',
    ], ['id', 'profileId'], path);
    const id = requireId(base.id, `${path}.id`);
    addGlobalId(globalIds, id, `${path}.id`);
    const profileId = requireId(base.profileId, `${path}.profileId`);
    if (!profiles.has(profileId)) fail(`${path}.profileId`, `unknown profile ${profileId}`);
    if (profileId !== activeProfileId) continue;
    const vector = requireKeys(raw, [
      'id', 'profileId', 'vectorSetRef', 'ruleRef', 'typeRef', 'valid',
      'expectedReason', 'expectedTypeError', 'expectedZeroSideEffects', 'expectedPostState', 'value',
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
    const valueErrors = validateValue(typeRef, vector.value, { definitions });
    const expectedTypeError = Object.hasOwn(vector, 'expectedTypeError')
      ? requireString(vector.expectedTypeError, `${path}.expectedTypeError`)
      : null;
    if (expectedTypeError !== null) {
      if (!pvmcRegistry) fail(`${path}.expectedTypeError`, 'is reserved for the active PVMC Registry');
      if (vector.valid) fail(`${path}.expectedTypeError`, 'valid vectors cannot expect a type error');
      if (expectedTypeError !== 'NO_ONE_OF_VARIANT') {
        fail(`${path}.expectedTypeError`, 'only NO_ONE_OF_VARIANT is supported');
      }
      if (valueErrors.length !== 1 || !valueErrors[0].includes('NO_ONE_OF_VARIANT')) {
        fail(`${path}.value`, `expected exact NO_ONE_OF_VARIANT, got ${valueErrors[0] ?? 'no type error'}`);
      }
    } else if (pvmcRegistry && valueErrors.length > 0) {
      fail(`${path}.value`, `vector is not executable: ${valueErrors[0]}`);
    }
    if (vector.valid) {
      if (expectedReason !== 'NONE') fail(`${path}.expectedReason`, 'valid vectors must expect NONE');
      if (Object.hasOwn(vector, 'expectedZeroSideEffects')) {
        fail(`${path}.expectedZeroSideEffects`, 'valid vectors must not declare failure side effects');
      }
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
      if (pvmcRegistry) {
        if (vector.expectedPostState !== 'UNCHANGED') {
          fail(`${path}.expectedPostState`, 'negative vectors must expect UNCHANGED post-state');
        }
        let outcome;
        try {
          outcome = evaluateSemanticRule(vector.value, rule.oracleRef);
        } catch (error) {
          fail(`${path}.value`, `semantic oracle failed: ${error.message}`);
        }
        if (outcome.valid !== false || outcome.reason !== expectedReason || outcome.postState !== 'UNCHANGED' ||
            !jsonEqual(outcome.sideEffects ?? {}, vector.expectedZeroSideEffects)) {
          fail(`${path}.value`, `semantic oracle mismatch: expected ${expectedReason}/UNCHANGED/zero, got ${outcome.reason}/${outcome.postState}`);
        }
      }
    }
    if (pvmcRegistry && vector.valid) {
      let outcome;
      try {
        outcome = evaluateSemanticRule(vector.value, rule.oracleRef);
      } catch (error) {
        fail(`${path}.value`, `semantic oracle failed: ${error.message}`);
      }
      if (!outcome.valid || outcome.reason !== 'NONE' || outcome.postState !== 'APPLIED') {
        fail(`${path}.value`, `semantic oracle mismatch: expected NONE/APPLIED, got ${outcome.reason}/${outcome.postState}`);
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

  const model = {
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
    ...digestAuthority,
  };
  discoverDigestPreimages(model);
  return model;
}

function runtimeSelectorValue(value, selector, path) {
  let current = value;
  for (const segment of selector.split('.')) {
    if (!isObject(current) || !Object.hasOwn(current, segment)) {
      throw new TypeError(`${path}.${selector} is required by the array selector`);
    }
    current = current[segment];
  }
  return current;
}

function selectorEnumOrder(itemNode, selector, definitions, path) {
  const values = [];
  const seen = new Set();
  for (const rawNode of selectedFieldNodes(itemNode, selector, definitions, path)) {
    let node = dereferenceNode(rawNode, definitions, path);
    if (node.kind === 'nullable') node = dereferenceNode(node.inner, definitions, path);
    if (node.kind !== 'enum') continue;
    for (const value of node.values) {
      if (seen.has(value)) continue;
      seen.add(value);
      values.push(value);
    }
  }
  return values.length > 0 ? values : null;
}

function compareConstraintScalar(left, right, enumOrder) {
  if (left === right) return 0;
  if (left === null) return -1;
  if (right === null) return 1;
  if (enumOrder && typeof left === 'string' && typeof right === 'string') {
    const leftRank = enumOrder.indexOf(left);
    const rightRank = enumOrder.indexOf(right);
    if (leftRank !== -1 && rightRank !== -1) return leftRank - rightRank;
  }
  if (typeof left === 'number' && typeof right === 'number') return left - right;
  if (typeof left === 'boolean' && typeof right === 'boolean') return left ? 1 : -1;
  if (typeof left === 'string' && typeof right === 'string') return compareUtf16(left, right);
  throw new TypeError('orderBy values have incompatible scalar types');
}

function compareCanonicalBytes(left, right) {
  return Buffer.compare(
    Buffer.from(canonicalize(left), 'utf8'),
    Buffer.from(canonicalize(right), 'utf8'),
  );
}

function compareArrayEntries(left, right, selectors, itemNode, definitions, path) {
  for (const selector of selectors) {
    const comparison = selector === '$'
      ? compareCanonicalBytes(left, right)
      : compareConstraintScalar(
        runtimeSelectorValue(left, selector, path),
        runtimeSelectorValue(right, selector, path),
        selectorEnumOrder(itemNode, selector, definitions, `${path}.${selector}`),
      );
    if (comparison !== 0) return comparison;
  }
  return 0;
}

export function validateValue(typeRef, value, model) {
  const errors = [];
  try {
    canonicalize(value);
  } catch (error) {
    return [`$ failed strict I-JSON admission: ${error.message}`];
  }
  const visit = (node, current, path, stack) => {
    switch (node.kind) {
      case 'string':
        if (typeof current !== 'string') {
          errors.push(`${path} must be a string`);
        } else {
          if (Object.hasOwn(node, 'const') && current !== node.const) {
            errors.push(`${path} must equal ${JSON.stringify(node.const)}`);
          }
          if (node.pattern !== undefined && !new RegExp(node.pattern, 'u').test(current)) {
            errors.push(`${path} must match ${JSON.stringify(node.pattern)}`);
          }
        }
        break;
      case 'nullable':
        if (current !== null) visit(node.inner, current, path, stack);
        break;
      case 'integer':
        if (!Number.isSafeInteger(current)) {
          errors.push(`${path} must be a safe integer`);
        } else {
          const minimum = node.minimum ?? Number.MIN_SAFE_INTEGER;
          const maximum = node.maximum ?? Number.MAX_SAFE_INTEGER;
          if (current < minimum || current > maximum) {
            errors.push(`${path} must be between ${minimum} and ${maximum}`);
          }
          if (Object.hasOwn(node, 'const') && current !== node.const) {
            errors.push(`${path} must equal ${node.const}`);
          }
        }
        break;
      case 'boolean':
        if (typeof current !== 'boolean') {
          errors.push(`${path} must be a boolean`);
        } else if (Object.hasOwn(node, 'const') && current !== node.const) {
          errors.push(`${path} must equal ${node.const}`);
        }
        break;
      case 'enum':
        if (typeof current !== 'string' || !node.values.includes(current)) {
          errors.push(`${path} must be one of ${node.values.join(', ')}`);
        } else if (Object.hasOwn(node, 'const') && current !== node.const) {
          errors.push(`${path} must equal ${JSON.stringify(node.const)}`);
        }
        break;
      case 'ref': {
        const definition = model.definitions.get(node.target);
        if (!definition) {
          errors.push(`${path} references unknown type ${node.target}`);
        } else if (node.target === 'Sha256Hex64' &&
            (typeof current !== 'string' || !SHA256_HEX64.test(current))) {
          errors.push(`${path} must be a lowercase SHA-256 hex digest`);
        } else if (stack.length > 512) {
          errors.push(`${path} exceeds the reference depth limit`);
        } else {
          visit(definition.node, current, path, [...stack, node.target]);
        }
        break;
      }
      case 'array':
        if (!Array.isArray(current)) {
          errors.push(`${path} must be an array`);
        } else {
          const minimum = node.minItems ?? 0;
          const maximum = node.maxItems ?? Number.MAX_SAFE_INTEGER;
          if (current.length < minimum || current.length > maximum) {
            errors.push(`${path} must contain between ${minimum} and ${maximum} items`);
          }
          for (let index = 0; index < current.length; index += 1) {
            visit(node.items, current[index], `${path}[${index}]`, stack);
          }
          try {
            if (node.uniqueItems) {
              const seen = new Set();
              for (const [index, entry] of current.entries()) {
                const key = canonicalize(entry);
                if (seen.has(key)) errors.push(`${path}[${index}] duplicates an earlier item`);
                seen.add(key);
              }
            }
            if (node.uniqueBy) {
              const seen = new Set();
              for (const [index, entry] of current.entries()) {
                const key = canonicalize(node.uniqueBy.map((selector) =>
                  runtimeSelectorValue(entry, selector, `${path}[${index}]`)));
                if (seen.has(key)) errors.push(`${path}[${index}] duplicates uniqueBy fields ${node.uniqueBy.join(', ')}`);
                seen.add(key);
              }
            }
            if (node.orderBy) {
              for (let index = 1; index < current.length; index += 1) {
                if (compareArrayEntries(
                  current[index - 1],
                  current[index],
                  node.orderBy,
                  node.items,
                  model.definitions,
                  `${path}[${index}]`,
                ) > 0) {
                  errors.push(`${path}[${index}] is out of order by ${node.orderBy.join(', ')}`);
                }
              }
            }
          } catch (error) {
            errors.push(`${path} has invalid collection metadata: ${error.message}`);
          }
        }
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
      case 'oneOf': {
        let syntheticTypeRef = '__GeneratedOneOfBranch';
        while (model.definitions.has(syntheticTypeRef)) syntheticTypeRef += '_';
        let matches = 0;
        for (const variant of node.variants) {
          const definitions = new Map(model.definitions);
          definitions.set(syntheticTypeRef, {node: variant, profiles: [model.activeProfileId]});
          if (validateValue(syntheticTypeRef, current, {...model, definitions}).length === 0) {
            matches += 1;
          }
        }
        if (matches === 0) errors.push(`${path} NO_ONE_OF_VARIANT: must match one oneOf variant`);
        if (matches > 1) errors.push(`${path} AMBIGUOUS_ONE_OF_VARIANT: matches ${matches} oneOf variants`);
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
  if (typeRef === 'Sha256Hex64' &&
      (typeof value !== 'string' || !SHA256_HEX64.test(value))) {
    errors.push('$ must be a lowercase SHA-256 hex digest');
  }
  visit(definition.node, value, '$', [typeRef]);
  return errors;
}
