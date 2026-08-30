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

export function generateTypeScript(model, sourceDigest) {
  const ids = [...model.activeDefinitionIds].sort();
  const nodes = Object.fromEntries(ids.map((id) => [id, model.definitions.get(id).node]));
  const declarations = ids.map((id) => declaration(id, nodes[id])).join('\n\n');
  const codecs = ids.map((id) => {
    const name = pascalName(id);
    return `export function decode${name}(value: unknown): ${name} {\n` +
      `  assertContractType(${quoted(id)}, value);\n` +
      `  return value as ${name};\n` +
      `}\n\n` +
      `export function encode${name}(value: ${name}): unknown {\n` +
      `  assertContractType(${quoted(id)}, value);\n` +
      `  return value;\n` +
      `}`;
  }).join('\n\n');

  return `// @generated from conversation contract ${sourceDigest}; DO NOT EDIT.\n` +
`/* eslint-disable */\n\n` +
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
`type ContractVariant = { readonly tag: string; readonly fields: ReadonlyArray<ContractField> };\n\n` +
`const contractNodes = ${JSON.stringify(nodes, null, 2)} as Record<string, ContractNode>;\n\n` +
`function isRecord(value: unknown): value is Record<string, unknown> {\n` +
`  return value !== null && typeof value === 'object' && !Array.isArray(value);\n` +
`}\n\n` +
`function assertNode(node: ContractNode, value: unknown, path: string, depth: number): void {\n` +
`  if (depth > 512) throw new TypeError(path + ': contract nesting is too deep');\n` +
`  switch (node.kind) {\n` +
`    case 'string': if (typeof value !== 'string') throw new TypeError(path + ': expected string'); return;\n` +
`    case 'integer': if (!Number.isSafeInteger(value)) throw new TypeError(path + ': expected safe integer'); return;\n` +
`    case 'boolean': if (typeof value !== 'boolean') throw new TypeError(path + ': expected boolean'); return;\n` +
`    case 'enum': if (typeof value !== 'string' || !node.values.includes(value)) throw new TypeError(path + ': invalid enum'); return;\n` +
`    case 'ref': {\n` +
`      const target = contractNodes[node.target];\n` +
`      if (!target) throw new TypeError(path + ': unknown type ' + node.target);\n` +
`      assertNode(target, value, path, depth + 1); return;\n` +
`    }\n` +
`    case 'array':\n` +
`      if (!Array.isArray(value)) throw new TypeError(path + ': expected array');\n` +
`      value.forEach((entry, index) => assertNode(node.items, entry, path + '[' + index + ']', depth + 1)); return;\n` +
`    case 'map':\n` +
`      if (!isRecord(value)) throw new TypeError(path + ': expected string-key map');\n` +
`      Object.entries(value).forEach(([key, entry]) => assertNode(node.values, entry, path + '.' + key, depth + 1)); return;\n` +
`    case 'object': assertFields(node.fields, value, path, depth, undefined); return;\n` +
`    case 'union': {\n` +
`      if (!isRecord(value)) throw new TypeError(path + ': expected union object');\n` +
`      const tag = value[node.discriminator];\n` +
`      const variant = node.variants.find((candidate) => candidate.tag === tag);\n` +
`      if (!variant) throw new TypeError(path + '.' + node.discriminator + ': invalid discriminator');\n` +
`      assertFields(variant.fields, value, path, depth, { key: node.discriminator, value: variant.tag }); return;\n` +
`    }\n` +
`  }\n` +
`}\n\n` +
`function assertFields(fields: ReadonlyArray<ContractField>, value: unknown, path: string, depth: number, discriminator: { key: string; value: string } | undefined): void {\n` +
`  if (!isRecord(value)) throw new TypeError(path + ': expected object');\n` +
`  const allowed = new Set(fields.map((field) => field.name));\n` +
`  if (discriminator) { allowed.add(discriminator.key); if (value[discriminator.key] !== discriminator.value) throw new TypeError(path + '.' + discriminator.key + ': invalid discriminator'); }\n` +
`  for (const key of Object.keys(value)) if (!allowed.has(key)) throw new TypeError(path + '.' + key + ': unknown field');\n` +
`  for (const field of fields) {\n` +
`    if (!Object.prototype.hasOwnProperty.call(value, field.name)) { if (field.required) throw new TypeError(path + '.' + field.name + ': required'); }\n` +
`    else assertNode(field.type, value[field.name], path + '.' + field.name, depth + 1);\n` +
`  }\n` +
`}\n\n` +
`export function assertContractType(typeId: string, value: unknown): void {\n` +
`  const node = contractNodes[typeId];\n` +
`  if (!node) throw new TypeError('unknown contract type ' + typeId);\n` +
`  assertNode(node, value, '$', 0);\n` +
`}\n\n` +
`${codecs}\n`;
}
