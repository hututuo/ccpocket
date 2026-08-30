import {
  SHA256_HEX_TYPE_ID,
  discoverDigestPreimages,
} from './digest-preimages.mjs';
import { pascalName } from './names.mjs';

function quoted(value) {
  return JSON.stringify(value);
}

function tsType(node) {
  switch (node.kind) {
    case 'string': return 'string';
    case 'integer': return 'number';
    case 'boolean': return 'boolean';
    case 'enum': return node.values.map(quoted).join(' | ');
    case 'ref': return pascalName(node.target);
    case 'array': return `ReadonlyArray<${tsType(node.items)}>`;
    case 'map': return `Readonly<Record<string, ${tsType(node.values)}>>`;
    case 'object': return `{ ${node.fields.map((field) =>
      `readonly ${quoted(field.name)}${field.required ? '' : '?'}: ${tsType(field.type)}`).join('; ')} }`;
    case 'union': return node.variants.map((variant) =>
      `{ readonly ${quoted(node.discriminator)}: ${quoted(variant.tag)}; ${variant.fields.map((field) =>
        `readonly ${quoted(field.name)}${field.required ? '' : '?'}: ${tsType(field.type)}`).join('; ')} }`).join(' | ');
    default: throw new Error(`unsupported TypeScript node kind ${node.kind}`);
  }
}

function declaration(id, node) {
  const name = pascalName(id);
  if (node.kind === 'object') {
    const fields = node.fields.map((field) =>
      `  readonly ${quoted(field.name)}${field.required ? '' : '?'}: ${tsType(field.type)};`).join('\n');
    return `export interface ${name} {\n${fields}\n}`;
  }
  return `export type ${name} = ${tsType(node)};`;
}

function codec(id) {
  const name = pascalName(id);
  return `export function decode${name}(value: unknown): ${name} {\n` +
    `  return snapshotContractType(${quoted(id)}, value) as unknown as ${name};\n` +
    `}\n\n` +
    `export function encode${name}(value: ${name}): unknown {\n` +
    `  return snapshotContractType(${quoted(id)}, value);\n` +
    `}`;
}

function digestHelpers(preimage) {
  const name = pascalName(preimage.typeId);
  return `export function canonicalBytes${name}(value: ${name}): Uint8Array {\n` +
    `  return canonicalBytesForPreimage(${quoted(preimage.typeId)}, value);\n` +
    `}\n\n` +
    `export function digest${name}(value: ${name}): string {\n` +
    `  return createHash('sha256').update(canonicalBytes${name}(value)).digest('hex');\n` +
    `}`;
}

export function generateTypeScript(model, sourceDigest) {
  const ids = [...model.activeDefinitionIds].sort();
  const nodes = Object.create(null);
  for (const id of ids) nodes[id] = model.definitions.get(id).node;
  const preimages = discoverDigestPreimages(model);
  const domainRules = Object.create(null);
  for (const preimage of preimages) domainRules[preimage.typeId] = preimage.domainRule;
  const declarations = ids.map((id) => declaration(id, nodes[id])).join('\n\n');
  const codecs = ids.map(codec).join('\n\n');
  const digests = preimages.map(digestHelpers).join('\n\n');

  return `// @generated from conversation contract ${sourceDigest}; DO NOT EDIT.\n` +
`/* eslint-disable */\n\n` +
`import { createHash } from 'node:crypto';\n` +
`import { isProxy } from 'node:util/types';\n\n` +
`${declarations}\n\n` +
`type ContractNode =\n` +
`  | { readonly kind: 'string' | 'integer' | 'boolean' }\n` +
`  | { readonly kind: 'enum'; readonly values: ReadonlyArray<string> }\n` +
`  | { readonly kind: 'ref'; readonly target: string }\n` +
`  | { readonly kind: 'array'; readonly items: ContractNode }\n` +
`  | { readonly kind: 'map'; readonly values: ContractNode }\n` +
`  | { readonly kind: 'object'; readonly fields: ReadonlyArray<ContractField> }\n` +
`  | { readonly kind: 'union'; readonly discriminator: string; readonly variants: ReadonlyArray<ContractVariant> };\n` +
`type ContractField = { readonly name: string; readonly required: boolean; readonly type: ContractNode };\n` +
`type ContractVariant = { readonly tag: string; readonly fields: ReadonlyArray<ContractField> };\n` +
`type JsonSnapshot = string | number | boolean | JsonSnapshot[] | JsonSnapshotObject;\n` +
`type JsonSnapshotObject = { readonly [key: string]: JsonSnapshot };\n` +
`type SnapshotState = { readonly active: WeakSet<object>; nodes: number };\n` +
`type DigestDomainRule =\n` +
`  | { readonly kind: 'object'; readonly value: string }\n` +
`  | { readonly kind: 'union'; readonly discriminator: string; readonly variants: ReadonlyArray<{ readonly tag: string; readonly value: string }> };\n\n` +
`const contractNodes = ${JSON.stringify(nodes, null, 2)} as Record<string, ContractNode>;\n` +
`const digestDomainRules = ${JSON.stringify(domainRules, null, 2)} as Record<string, DigestDomainRule>;\n` +
`const sha256Hex64 = /^[0-9a-f]{64}$/;\n` +
`const utf8Encoder = new TextEncoder();\n\n` +
`function assertUnicodeScalarString(value: string, path: string): void {\n` +
`  for (let index = 0; index < value.length; index += 1) {\n` +
`    const code = value.charCodeAt(index);\n` +
`    if (code >= 0xd800 && code <= 0xdbff) {\n` +
`      if (index + 1 >= value.length) throw new TypeError(path + ': lone high surrogate');\n` +
`      const low = value.charCodeAt(index + 1);\n` +
`      if (low < 0xdc00 || low > 0xdfff) throw new TypeError(path + ': lone high surrogate');\n` +
`      index += 1;\n` +
`    } else if (code >= 0xdc00 && code <= 0xdfff) {\n` +
`      throw new TypeError(path + ': lone low surrogate');\n` +
`    }\n` +
`  }\n` +
`}\n\n` +
`function assertSemanticType(typeId: string, value: JsonSnapshot, path: string): void {\n` +
`  if (typeId === ${quoted(SHA256_HEX_TYPE_ID)} && (typeof value !== 'string' || !sha256Hex64.test(value))) {\n` +
`    throw new TypeError(path + ': expected lowercase SHA-256 hex64');\n` +
`  }\n` +
`}\n\n` +
`function recordDescriptors(value: unknown, path: string): Map<string, PropertyDescriptor> {\n` +
`  if (value === null || typeof value !== 'object' || Array.isArray(value)) throw new TypeError(path + ': expected object');\n` +
`  if (isProxy(value)) throw new TypeError(path + ': proxy objects are not contract data');\n` +
`  const prototype = Object.getPrototypeOf(value);\n` +
`  if (prototype !== Object.prototype && prototype !== null) throw new TypeError(path + ': expected plain data object');\n` +
`  const descriptors = Object.getOwnPropertyDescriptors(value);\n` +
`  const result = new Map<string, PropertyDescriptor>();\n` +
`  for (const key of Reflect.ownKeys(value)) {\n` +
`    if (typeof key !== 'string') throw new TypeError(path + ': symbol fields are not allowed');\n` +
`    assertUnicodeScalarString(key, path + '.<key>');\n` +
`    const descriptor = descriptors[key];\n` +
`    if (!descriptor || !descriptor.enumerable || !Object.prototype.hasOwnProperty.call(descriptor, 'value')) {\n` +
`      throw new TypeError(path + '.' + key + ': expected enumerable own data field');\n` +
`    }\n` +
`    result.set(key, descriptor);\n` +
`  }\n` +
`  return result;\n` +
`}\n\n` +
`function arrayDescriptors(value: ReadonlyArray<unknown>, path: string): Map<number, PropertyDescriptor> {\n` +
`  if (isProxy(value)) throw new TypeError(path + ': proxy arrays are not contract data');\n` +
`  if (Object.getPrototypeOf(value) !== Array.prototype) throw new TypeError(path + ': expected plain array');\n` +
`  const descriptors = Object.getOwnPropertyDescriptors(value);\n` +
`  const result = new Map<number, PropertyDescriptor>();\n` +
`  for (const key of Reflect.ownKeys(value)) {\n` +
`    if (key === 'length') continue;\n` +
`    if (typeof key !== 'string') throw new TypeError(path + ': symbol array fields are not allowed');\n` +
`    const index = Number(key);\n` +
`    if (!Number.isInteger(index) || index < 0 || index >= value.length || String(index) !== key) {\n` +
`      throw new TypeError(path + '.' + key + ': unexpected array field');\n` +
`    }\n` +
`    const descriptor = descriptors[key];\n` +
`    if (!descriptor || !descriptor.enumerable || !Object.prototype.hasOwnProperty.call(descriptor, 'value')) {\n` +
`      throw new TypeError(path + '[' + index + ']: expected enumerable own data entry');\n` +
`    }\n` +
`    result.set(index, descriptor);\n` +
`  }\n` +
`  if (result.size !== value.length) throw new TypeError(path + ': sparse arrays are not allowed');\n` +
`  return result;\n` +
`}\n\n` +
`function snapshotFields(\n` +
`  fields: ReadonlyArray<ContractField>,\n` +
`  value: unknown,\n` +
`  path: string,\n` +
`  depth: number,\n` +
`  state: SnapshotState,\n` +
`  discriminator: { readonly key: string; readonly value: string } | undefined,\n` +
`  capturedDescriptors?: Map<string, PropertyDescriptor>,\n` +
`): JsonSnapshotObject {\n` +
`  const descriptors = capturedDescriptors ?? recordDescriptors(value, path);\n` +
`  const allowed = new Set(fields.map((field) => field.name));\n` +
`  if (discriminator) allowed.add(discriminator.key);\n` +
`  for (const key of descriptors.keys()) if (!allowed.has(key)) throw new TypeError(path + '.' + key + ': unknown field');\n` +
`  if (discriminator) {\n` +
`    const descriptor = descriptors.get(discriminator.key);\n` +
`    if (!descriptor || descriptor.value !== discriminator.value) throw new TypeError(path + '.' + discriminator.key + ': invalid discriminator');\n` +
`    assertUnicodeScalarString(discriminator.value, path + '.' + discriminator.key);\n` +
`    if (++state.nodes > 100000) throw new TypeError(path + '.' + discriminator.key + ': contract node limit exceeded');\n` +
`  }\n` +
`  const result: Record<string, JsonSnapshot> = Object.create(null);\n` +
`  if (discriminator) result[discriminator.key] = discriminator.value;\n` +
`  for (const field of fields) {\n` +
`    const descriptor = descriptors.get(field.name);\n` +
`    if (!descriptor) {\n` +
`      if (field.required) throw new TypeError(path + '.' + field.name + ': required');\n` +
`      continue;\n` +
`    }\n` +
`    result[field.name] = snapshotNode(field.type, descriptor.value, path + '.' + field.name, depth + 1, state);\n` +
`  }\n` +
`  return result;\n` +
`}\n\n` +
`function snapshotNode(node: ContractNode, value: unknown, path: string, depth: number, state: SnapshotState): JsonSnapshot {\n` +
`  if (depth > 512) throw new TypeError(path + ': contract nesting is too deep');\n` +
`  if (node.kind !== 'ref' && ++state.nodes > 100000) throw new TypeError(path + ': contract node limit exceeded');\n` +
`  switch (node.kind) {\n` +
`    case 'string':\n` +
`      if (typeof value !== 'string') throw new TypeError(path + ': expected string');\n` +
`      assertUnicodeScalarString(value, path); return value;\n` +
`    case 'integer': if (!Number.isSafeInteger(value)) throw new TypeError(path + ': expected safe integer'); return value as number;\n` +
`    case 'boolean': if (typeof value !== 'boolean') throw new TypeError(path + ': expected boolean'); return value;\n` +
`    case 'enum':\n` +
`      if (typeof value !== 'string' || !node.values.includes(value)) throw new TypeError(path + ': invalid enum');\n` +
`      assertUnicodeScalarString(value, path); return value;\n` +
`    case 'ref': {\n` +
`      if (!Object.hasOwn(contractNodes, node.target)) throw new TypeError(path + ': unknown type ' + node.target);\n` +
`      const target = contractNodes[node.target];\n` +
`      const snapshot = snapshotNode(target, value, path, depth, state);\n` +
`      assertSemanticType(node.target, snapshot, path); return snapshot;\n` +
`    }\n` +
`    case 'array': {\n` +
`      if (!Array.isArray(value)) throw new TypeError(path + ': expected array');\n` +
`      if (state.active.has(value)) throw new TypeError(path + ': cyclic value');\n` +
`      state.active.add(value);\n` +
`      try {\n` +
`        const descriptors = arrayDescriptors(value, path);\n` +
`        return Array.from({ length: value.length }, (_, index) =>\n` +
`          snapshotNode(node.items, descriptors.get(index)?.value, path + '[' + index + ']', depth + 1, state));\n` +
`      } finally { state.active.delete(value); }\n` +
`    }\n` +
`    case 'map': {\n` +
`      if (value === null || typeof value !== 'object') throw new TypeError(path + ': expected string-key map');\n` +
`      if (state.active.has(value)) throw new TypeError(path + ': cyclic value');\n` +
`      state.active.add(value);\n` +
`      try {\n` +
`        const descriptors = recordDescriptors(value, path);\n` +
`        const result: Record<string, JsonSnapshot> = Object.create(null);\n` +
`        for (const [key, descriptor] of descriptors) {\n` +
`          assertUnicodeScalarString(key, path + '.<key>');\n` +
`          result[key] = snapshotNode(node.values, descriptor.value, path + '.' + key, depth + 1, state);\n` +
`        }\n` +
`        return result;\n` +
`      } finally { state.active.delete(value); }\n` +
`    }\n` +
`    case 'object':\n` +
`      if (value === null || typeof value !== 'object') throw new TypeError(path + ': expected object');\n` +
`      if (state.active.has(value)) throw new TypeError(path + ': cyclic value');\n` +
`      state.active.add(value);\n` +
`      try { return snapshotFields(node.fields, value, path, depth, state, undefined); } finally { state.active.delete(value); }\n` +
`    case 'union': {\n` +
`      if (value === null || typeof value !== 'object') throw new TypeError(path + ': expected union object');\n` +
`      if (state.active.has(value)) throw new TypeError(path + ': cyclic value');\n` +
`      state.active.add(value);\n` +
`      try {\n` +
`        const descriptors = recordDescriptors(value, path);\n` +
`        const tag = descriptors.get(node.discriminator)?.value;\n` +
`        const variant = node.variants.find((candidate) => candidate.tag === tag);\n` +
`        if (!variant) throw new TypeError(path + '.' + node.discriminator + ': invalid discriminator');\n` +
`        return snapshotFields(variant.fields, value, path, depth, state, { key: node.discriminator, value: variant.tag }, descriptors);\n` +
`      } finally { state.active.delete(value); }\n` +
`    }\n` +
`  }\n` +
`}\n\n` +
`function snapshotContractType(typeId: string, value: unknown): JsonSnapshot {\n` +
`  if (!Object.hasOwn(contractNodes, typeId)) throw new TypeError('unknown contract type ' + typeId);\n` +
`  const node = contractNodes[typeId];\n` +
`  const snapshot = snapshotNode(node, value, '$', 0, { active: new WeakSet<object>(), nodes: 0 });\n` +
`  assertSemanticType(typeId, snapshot, '$');\n` +
`  return snapshot;\n` +
`}\n\n` +
`function assertDigestDomain(typeId: string, value: JsonSnapshot): void {\n` +
`  const rule = digestDomainRules[typeId];\n` +
`  if (!rule || typeof value !== 'object' || value === null || Array.isArray(value)) throw new TypeError(typeId + ': invalid digest preimage authority');\n` +
`  if (rule.kind === 'object') {\n` +
`    if (value.digestDomain !== rule.value) throw new TypeError(typeId + '.digestDomain: invalid digest domain');\n` +
`    return;\n` +
`  }\n` +
`  const tag = value[rule.discriminator];\n` +
`  const variant = rule.variants.find((candidate) => candidate.tag === tag);\n` +
`  if (!variant || value.digestDomain !== variant.value) throw new TypeError(typeId + '.digestDomain: invalid digest domain');\n` +
`}\n\n` +
`function canonicalJson(value: JsonSnapshot): string {\n` +
`  if (typeof value === 'string') return JSON.stringify(value);\n` +
`  if (typeof value === 'number') return Object.is(value, -0) ? '0' : String(value);\n` +
`  if (typeof value === 'boolean') return value ? 'true' : 'false';\n` +
`  if (Array.isArray(value)) return '[' + value.map(canonicalJson).join(',') + ']';\n` +
`  return '{' + Object.keys(value).sort().map((key) => JSON.stringify(key) + ':' + canonicalJson(value[key])).join(',') + '}';\n` +
`}\n\n` +
`function canonicalBytesForPreimage(typeId: string, value: unknown): Uint8Array {\n` +
`  const snapshot = snapshotContractType(typeId, value);\n` +
`  assertDigestDomain(typeId, snapshot);\n` +
`  return utf8Encoder.encode(canonicalJson(snapshot));\n` +
`}\n\n` +
`export function assertContractType(typeId: string, value: unknown): void {\n` +
`  snapshotContractType(typeId, value);\n` +
`}\n\n` +
`${codecs}\n` +
(digests ? `\n${digests}\n` : '');
}
