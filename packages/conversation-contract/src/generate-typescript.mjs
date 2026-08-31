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
    case 'string': return Object.hasOwn(node, 'const') ? quoted(node.const) : 'string';
    case 'integer': return Object.hasOwn(node, 'const') ? String(node.const) : 'number';
    case 'boolean': return Object.hasOwn(node, 'const') ? String(node.const) : 'boolean';
    case 'enum': return Object.hasOwn(node, 'const')
      ? quoted(node.const)
      : node.values.map(quoted).join(' | ');
    case 'ref': return pascalName(node.target);
    case 'nullable': return `${tsType(node.inner)} | null`;
    case 'array': return `ReadonlyArray<${tsType(node.items)}>`;
    case 'map': return `Readonly<Record<string, ${tsType(node.values)}>>`;
    case 'object': return `{ ${node.fields.map((field) =>
      `readonly ${quoted(field.name)}${field.required ? '' : '?'}: ${tsType(field.type)}`).join('; ')} }`;
    case 'oneOf': return node.variants.map(tsType).join(' | ');
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

function pvmc1AuthorityExports(model) {
  if (model.machineAuthority === null) return '';
  const machineRecords = model.machineAuthority.machineRecords;
  const machineEdges = model.machineAuthority.machineEdgeAuthorities;
  const routes = model.machineAuthority.projectionRoutes.map((row) => row.registryId);
  const sql = model.machineAuthority.machineTransitionSql.manifest;
  const transactionManifestIds = model.transactionAuthority?.transactionManifests.map((row) =>
    row.manifestId) ?? [];
  const transactionKillPointIds = model.transactionAuthority?.transactionKillPoints.map((row) =>
    row.killPointId).sort() ?? [];
  const bridgeRoutePointIds = model.transactionAuthority?.bridgeRoutePointBindings.map((row) =>
    row.bridgeMarkerId) ?? [];
  return `function pvmc1DeepFreezeAuthority<T>(value: T): T {\n` +
    `  if (value !== null && typeof value === 'object' && !Object.isFrozen(value)) {\n` +
    `    for (const child of Object.values(value as Record<string, unknown>)) {\n` +
    `      pvmc1DeepFreezeAuthority(child);\n` +
    `    }\n` +
    `    Object.freeze(value);\n` +
    `  }\n` +
    `  return value;\n` +
    `}\n\n` +
    `export interface Pvmc1MachineRecord {\n` +
    `  readonly machineOrdinal: number;\n` +
    `  readonly machineId: ActiveMachineIdV1;\n` +
    `  readonly stateTypeRef: string;\n` +
    `  readonly states: ReadonlyArray<string>;\n` +
    `  readonly initialState: string;\n` +
    `  readonly terminalStates: ReadonlyArray<string>;\n` +
    `  readonly allowedEdges: ReadonlyArray<{ readonly from: string; readonly to: string }>;\n` +
    `  readonly semanticOwnerRef: SemanticOwnerSelectorRefV1;\n` +
    `  readonly authoritativeWriterRef: AuthoritativeWriterRefV1;\n` +
    `  readonly eventFactOwnerSelectorRef: EventFactOwnerSelectorRefV1 | null;\n` +
    `  readonly replicaWriterBindings: ReadonlyArray<ReplicaWriterBindingV1>;\n` +
    `  readonly storageBindingRef: StorageBindingRefV1;\n` +
    `  readonly authoritativeRouteRefs: ReadonlyArray<ProjectionRouteRefV1>;\n` +
    `  readonly wireProjectionRef: WireProjectionRefV1;\n` +
    `  readonly unknownPolicyRef: UnknownPolicyRefV1;\n` +
    `  readonly ownerFeature: string | null;\n` +
    `}\n\n` +
    `export const pvmc1MachineRecords = ${JSON.stringify(machineRecords, null, 2)} as const satisfies readonly Pvmc1MachineRecord[];\n` +
    `pvmc1DeepFreezeAuthority(pvmc1MachineRecords);\n\n` +
    `export const pvmc1MachineEdgeAuthorities = ${JSON.stringify(machineEdges, null, 2)} as const satisfies readonly MachineEdgeAuthorityV1[];\n` +
    `pvmc1DeepFreezeAuthority(pvmc1MachineEdgeAuthorities);\n\n` +
    `export const pvmc1DurableRouteIds = ${JSON.stringify(routes, null, 2)} as const;\n` +
    `pvmc1DeepFreezeAuthority(pvmc1DurableRouteIds);\n\n` +
    `const pvmc1AllowedMachineEdgeKeys = new Set<string>(pvmc1MachineEdgeAuthorities.map((row) =>\n` +
    `  row.coordinate.machineId + "\\u0000" + row.coordinate.from + "\\u0000" + row.coordinate.to));\n\n` +
    `export function isAllowedPvmc1MachineEdge(machineId: string, from: string, to: string): boolean {\n` +
    `  return pvmc1AllowedMachineEdgeKeys.has(machineId + "\\u0000" + from + "\\u0000" + to);\n` +
    `}\n\n` +
    `export const pvmc1MachineTransitionSqlRowCount = ${sql.rowCount} as const;\n` +
    `export const pvmc1MachineTransitionSqlSha256 = ${quoted(sql.sqlSha256)} as const;\n` +
    `export const pvmc1MachineTransitionSqlUtf8Base64 = ${quoted(sql.sqlUtf8Base64)} as const;\n\n` +
    `export function pvmc1MachineTransitionSqlBytes(): Uint8Array {\n` +
    `  const bytes = Uint8Array.from(Buffer.from(pvmc1MachineTransitionSqlUtf8Base64, 'base64'));\n` +
    `  const digest = createHash('sha256').update(bytes).digest('hex');\n` +
    `  if (digest !== pvmc1MachineTransitionSqlSha256) throw new TypeError('PVMC1 machine SQL digest mismatch');\n` +
    `  return bytes;\n` +
    `}\n\n` +
    `export const pvmc1TransactionManifestIds = ${JSON.stringify(transactionManifestIds, null, 2)} as const;\n` +
    `pvmc1DeepFreezeAuthority(pvmc1TransactionManifestIds);\n\n` +
    `export const pvmc1TransactionKillPointIds = ${JSON.stringify(transactionKillPointIds, null, 2)} as const;\n` +
    `pvmc1DeepFreezeAuthority(pvmc1TransactionKillPointIds);\n\n` +
    `export const pvmc1BridgeRoutePointIds = ${JSON.stringify(bridgeRoutePointIds, null, 2)} as const;\n` +
    `pvmc1DeepFreezeAuthority(pvmc1BridgeRoutePointIds);`;
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
  const authorityExports = pvmc1AuthorityExports(model);

  return `// @generated from conversation contract ${sourceDigest}; DO NOT EDIT.\n` +
`/* eslint-disable */\n\n` +
`import { createHash } from 'node:crypto';\n` +
`import { isProxy } from 'node:util/types';\n\n` +
`${declarations}\n\n` +
`type ContractNode =\n` +
`  | { readonly kind: 'string'; readonly const?: string; readonly pattern?: string }\n` +
`  | { readonly kind: 'integer'; readonly const?: number; readonly minimum?: number; readonly maximum?: number }\n` +
`  | { readonly kind: 'boolean'; readonly const?: boolean }\n` +
`  | { readonly kind: 'enum'; readonly values: ReadonlyArray<string>; readonly const?: string }\n` +
`  | { readonly kind: 'ref'; readonly target: string }\n` +
`  | { readonly kind: 'nullable'; readonly inner: ContractNode }\n` +
`  | { readonly kind: 'array'; readonly items: ContractNode; readonly minItems?: number; readonly maxItems?: number; readonly uniqueItems?: boolean; readonly uniqueBy?: ReadonlyArray<string>; readonly orderBy?: ReadonlyArray<string> }\n` +
`  | { readonly kind: 'map'; readonly values: ContractNode }\n` +
`  | { readonly kind: 'object'; readonly fields: ReadonlyArray<ContractField> }\n` +
`  | { readonly kind: 'oneOf'; readonly variants: ReadonlyArray<ContractNode> }\n` +
`  | { readonly kind: 'union'; readonly discriminator: string; readonly variants: ReadonlyArray<ContractVariant> };\n` +
`type ContractField = { readonly name: string; readonly required: boolean; readonly type: ContractNode };\n` +
`type ContractVariant = { readonly tag: string; readonly fields: ReadonlyArray<ContractField> };\n` +
`type JsonSnapshot = null | string | number | boolean | JsonSnapshot[] | JsonSnapshotObject;\n` +
`type JsonSnapshotObject = { readonly [key: string]: JsonSnapshot };\n` +
`type SnapshotState = { readonly active: Set<object>; nodes: number };\n` +
`type DigestDomainRule =\n` +
`  | null\n` +
`  | { readonly kind: 'object'; readonly value: string }\n` +
`  | { readonly kind: 'oneOf'; readonly values: ReadonlyArray<string> }\n` +
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
`function dereferenceContractNode(node: ContractNode, path: string): ContractNode {\n` +
`  const seen = new Set<string>();\n` +
`  let current = node;\n` +
`  while (current.kind === 'ref') {\n` +
`    if (seen.has(current.target) || !Object.hasOwn(contractNodes, current.target)) throw new TypeError(path + ': invalid selector type reference');\n` +
`    seen.add(current.target);\n` +
`    current = contractNodes[current.target];\n` +
`  }\n` +
`  return current;\n` +
`}\n\n` +
`function selectedContractNodes(itemNode: ContractNode, selector: string, path: string): ReadonlyArray<ContractNode> {\n` +
`  if (selector === '$') return [dereferenceContractNode(itemNode, path)];\n` +
`  let nodes: ReadonlyArray<ContractNode> = [itemNode];\n` +
`  for (const segment of selector.split('.')) {\n` +
`    const next: ContractNode[] = [];\n` +
`    for (const rawNode of nodes) {\n` +
`      const node = dereferenceContractNode(rawNode, path);\n` +
`      if (node.kind === 'object') {\n` +
`        const field = node.fields.find((candidate) => candidate.name === segment);\n` +
`        if (!field) throw new TypeError(path + ': unknown collection selector ' + selector);\n` +
`        next.push(field.type);\n` +
`      } else if (node.kind === 'union') {\n` +
`        if (segment === node.discriminator) {\n` +
`          next.push({ kind: 'enum', values: node.variants.map((variant) => variant.tag) });\n` +
`        } else {\n` +
`          for (const variant of node.variants) {\n` +
`            const field = variant.fields.find((candidate) => candidate.name === segment);\n` +
`            if (!field) throw new TypeError(path + ': selector ' + selector + ' is absent from ' + variant.tag);\n` +
`            next.push(field.type);\n` +
`          }\n` +
`        }\n` +
`      } else if (node.kind === 'oneOf') {\n` +
`        for (const variant of node.variants) next.push(...selectedContractNodes(variant, segment, path));\n` +
`      } else {\n` +
`        throw new TypeError(path + ': collection selectors require object, union, or oneOf items');\n` +
`      }\n` +
`    }\n` +
`    nodes = next;\n` +
`  }\n` +
`  return nodes;\n` +
`}\n\n` +
`function selectorEnumOrder(itemNode: ContractNode, selector: string, path: string): ReadonlyArray<string> | undefined {\n` +
`  const result: string[] = [];\n` +
`  const seen = new Set<string>();\n` +
`  for (const selected of selectedContractNodes(itemNode, selector, path)) {\n` +
`    let node = dereferenceContractNode(selected, path);\n` +
`    if (node.kind === 'nullable') node = dereferenceContractNode(node.inner, path);\n` +
`    if (node.kind !== 'enum') continue;\n` +
`    for (const value of node.values) if (!seen.has(value)) { seen.add(value); result.push(value); }\n` +
`  }\n` +
`  return result.length === 0 ? undefined : result;\n` +
`}\n\n` +
`function snapshotSelectorValue(value: JsonSnapshot, selector: string, path: string): JsonSnapshot {\n` +
`  let current = value;\n` +
`  for (const segment of selector.split('.')) {\n` +
`    if (current === null || typeof current !== 'object' || Array.isArray(current) || !Object.hasOwn(current, segment)) {\n` +
`      throw new TypeError(path + '.' + selector + ': required collection selector');\n` +
`    }\n` +
`    current = current[segment];\n` +
`  }\n` +
`  return current;\n` +
`}\n\n` +
`function compareUtf16(left: string, right: string): number {\n` +
`  const length = Math.min(left.length, right.length);\n` +
`  for (let index = 0; index < length; index += 1) {\n` +
`    const difference = left.charCodeAt(index) - right.charCodeAt(index);\n` +
`    if (difference !== 0) return difference;\n` +
`  }\n` +
`  return left.length - right.length;\n` +
`}\n\n` +
`function compareConstraintScalar(left: JsonSnapshot, right: JsonSnapshot, enumOrder: ReadonlyArray<string> | undefined): number {\n` +
`  if (left === right) return 0;\n` +
`  if (left === null) return -1;\n` +
`  if (right === null) return 1;\n` +
`  if (enumOrder && typeof left === 'string' && typeof right === 'string') {\n` +
`    const leftRank = enumOrder.indexOf(left);\n` +
`    const rightRank = enumOrder.indexOf(right);\n` +
`    if (leftRank !== -1 && rightRank !== -1) return leftRank - rightRank;\n` +
`  }\n` +
`  if (typeof left === 'number' && typeof right === 'number') return left - right;\n` +
`  if (typeof left === 'boolean' && typeof right === 'boolean') return left ? 1 : -1;\n` +
`  if (typeof left === 'string' && typeof right === 'string') return compareUtf16(left, right);\n` +
`  throw new TypeError('orderBy values have incompatible scalar types');\n` +
`}\n\n` +
`function compareCanonicalBytes(left: JsonSnapshot, right: JsonSnapshot): number {\n` +
`  const leftBytes = utf8Encoder.encode(canonicalJson(left));\n` +
`  const rightBytes = utf8Encoder.encode(canonicalJson(right));\n` +
`  const length = Math.min(leftBytes.length, rightBytes.length);\n` +
`  for (let index = 0; index < length; index += 1) {\n` +
`    const difference = leftBytes[index] - rightBytes[index];\n` +
`    if (difference !== 0) return difference;\n` +
`  }\n` +
`  return leftBytes.length - rightBytes.length;\n` +
`}\n\n` +
`function compareArrayEntries(left: JsonSnapshot, right: JsonSnapshot, selectors: ReadonlyArray<string>, itemNode: ContractNode, path: string): number {\n` +
`  for (const selector of selectors) {\n` +
`    const comparison = selector === '$'\n` +
`      ? compareCanonicalBytes(left, right)\n` +
`      : compareConstraintScalar(\n` +
`          snapshotSelectorValue(left, selector, path),\n` +
`          snapshotSelectorValue(right, selector, path),\n` +
`          selectorEnumOrder(itemNode, selector, path + '.' + selector),\n` +
`        );\n` +
`    if (comparison !== 0) return comparison;\n` +
`  }\n` +
`  return 0;\n` +
`}\n\n` +
`function assertArrayConstraints(node: ContractNode & { readonly kind: 'array' }, values: ReadonlyArray<JsonSnapshot>, path: string): void {\n` +
`  const minimum = node.minItems ?? 0;\n` +
`  const maximum = node.maxItems ?? Number.MAX_SAFE_INTEGER;\n` +
`  if (values.length < minimum || values.length > maximum) throw new TypeError(path + ': expected between ' + minimum + ' and ' + maximum + ' items');\n` +
`  if (node.uniqueItems) {\n` +
`    const seen = new Set<string>();\n` +
`    for (let index = 0; index < values.length; index += 1) {\n` +
`      const key = canonicalJson(values[index]);\n` +
`      if (seen.has(key)) throw new TypeError(path + '[' + index + ']: duplicate array item');\n` +
`      seen.add(key);\n` +
`    }\n` +
`  }\n` +
`  if (node.uniqueBy) {\n` +
`    const seen = new Set<string>();\n` +
`    for (let index = 0; index < values.length; index += 1) {\n` +
`      const key = canonicalJson(node.uniqueBy.map((selector) => snapshotSelectorValue(values[index], selector, path + '[' + index + ']')));\n` +
`      if (seen.has(key)) throw new TypeError(path + '[' + index + ']: duplicate uniqueBy fields ' + node.uniqueBy.join(', '));\n` +
`      seen.add(key);\n` +
`    }\n` +
`  }\n` +
`  if (node.orderBy) {\n` +
`    for (let index = 1; index < values.length; index += 1) {\n` +
`      if (compareArrayEntries(values[index - 1], values[index], node.orderBy, node.items, path + '[' + index + ']') > 0) {\n` +
`        throw new TypeError(path + '[' + index + ']: out of order by ' + node.orderBy.join(', '));\n` +
`      }\n` +
`    }\n` +
`  }\n` +
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
`      assertUnicodeScalarString(value, path);\n` +
`      if (Object.hasOwn(node, 'const') && value !== node.const) throw new TypeError(path + ': invalid const');\n` +
`      if (node.pattern !== undefined && !new RegExp(node.pattern, 'u').test(value)) throw new TypeError(path + ': pattern mismatch');\n` +
`      return value;\n` +
`    case 'integer': {\n` +
`      if (!Number.isSafeInteger(value)) throw new TypeError(path + ': expected safe integer');\n` +
`      const integer = value as number;\n` +
`      if (integer < (node.minimum ?? Number.MIN_SAFE_INTEGER) || integer > (node.maximum ?? Number.MAX_SAFE_INTEGER)) throw new TypeError(path + ': integer outside bounds');\n` +
`      if (Object.hasOwn(node, 'const') && integer !== node.const) throw new TypeError(path + ': invalid const');\n` +
`      return integer;\n` +
`    }\n` +
`    case 'boolean':\n` +
`      if (typeof value !== 'boolean') throw new TypeError(path + ': expected boolean');\n` +
`      if (Object.hasOwn(node, 'const') && value !== node.const) throw new TypeError(path + ': invalid const');\n` +
`      return value;\n` +
`    case 'enum':\n` +
`      if (typeof value !== 'string' || !node.values.includes(value)) throw new TypeError(path + ': invalid enum');\n` +
`      if (Object.hasOwn(node, 'const') && value !== node.const) throw new TypeError(path + ': invalid const');\n` +
`      assertUnicodeScalarString(value, path); return value;\n` +
`    case 'nullable':\n` +
`      return value === null ? null : snapshotNode(node.inner, value, path, depth + 1, state);\n` +
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
`        const result = Array.from({ length: value.length }, (_, index) =>\n` +
`          snapshotNode(node.items, descriptors.get(index)?.value, path + '[' + index + ']', depth + 1, state));\n` +
`        assertArrayConstraints(node, result, path);\n` +
`        return result;\n` +
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
`    case 'oneOf': {\n` +
`      const matches: Array<{ readonly snapshot: JsonSnapshot; readonly nodes: number }> = [];\n` +
`      for (const variant of node.variants) {\n` +
`        const branchState: SnapshotState = { active: new Set(state.active), nodes: state.nodes };\n` +
`        try {\n` +
`          matches.push({ snapshot: snapshotNode(variant, value, path, depth + 1, branchState), nodes: branchState.nodes });\n` +
`        } catch (error) {\n` +
`          if (!(error instanceof TypeError)) throw error;\n` +
`        }\n` +
`      }\n` +
`      if (matches.length === 0) throw new TypeError(path + ': NO_ONE_OF_VARIANT');\n` +
`      if (matches.length > 1) throw new TypeError(path + ': AMBIGUOUS_ONE_OF_VARIANT');\n` +
`      state.nodes = matches[0].nodes;\n` +
`      return matches[0].snapshot;\n` +
`    }\n` +
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
`  const snapshot = snapshotNode(node, value, '$', 0, { active: new Set<object>(), nodes: 0 });\n` +
`  assertSemanticType(typeId, snapshot, '$');\n` +
`  return snapshot;\n` +
`}\n\n` +
`function assertDigestDomain(typeId: string, value: JsonSnapshot): void {\n` +
`  const rule = digestDomainRules[typeId];\n` +
`  if (!Object.hasOwn(digestDomainRules, typeId) || typeof value !== 'object' || value === null || Array.isArray(value)) throw new TypeError(typeId + ': invalid digest preimage authority');\n` +
`  if (rule === null) return;\n` +
`  if (rule.kind === 'object') {\n` +
`    if (value.digestDomain !== rule.value) throw new TypeError(typeId + '.digestDomain: invalid digest domain');\n` +
`    return;\n` +
`  }\n` +
`  if (rule.kind === 'oneOf') {\n` +
`    if (typeof value.digestDomain !== 'string' || !rule.values.includes(value.digestDomain)) throw new TypeError(typeId + '.digestDomain: invalid digest domain');\n` +
`    return;\n` +
`  }\n` +
`  const tag = value[rule.discriminator];\n` +
`  const variant = rule.variants.find((candidate) => candidate.tag === tag);\n` +
`  if (!variant || value.digestDomain !== variant.value) throw new TypeError(typeId + '.digestDomain: invalid digest domain');\n` +
`}\n\n` +
`function canonicalJson(value: JsonSnapshot): string {\n` +
`  if (value === null) return 'null';\n` +
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
(digests ? `\n${digests}\n` : '') +
(authorityExports ? `\n${authorityExports}\n` : '');
}
