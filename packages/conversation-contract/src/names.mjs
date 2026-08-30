const DART_RESERVED = new Set([
  'abstract', 'as', 'assert', 'async', 'await', 'base', 'break', 'case',
  'catch', 'class', 'const', 'continue', 'covariant', 'default', 'deferred',
  'do', 'dynamic', 'else', 'enum', 'export', 'extends', 'extension',
  'external', 'factory', 'false', 'final', 'finally', 'for', 'get', 'hide',
  'if', 'implements', 'import', 'in', 'interface', 'is', 'late', 'library',
  'mixin', 'new', 'null', 'of', 'on', 'operator', 'part', 'required',
  'rethrow', 'return', 'sealed', 'set', 'show', 'static', 'super', 'switch',
  'sync', 'this', 'throw', 'true', 'try', 'typedef', 'var', 'void', 'when',
  'while', 'with', 'yield',
]);

const DART_CORE_NAMES = new Set([
  'BigInt', 'bool', 'Comparable', 'DateTime', 'Deprecated', 'double',
  'Duration', 'Enum', 'Error', 'Exception', 'FormatException', 'Function',
  'Future', 'FutureOr', 'IndexError', 'int', 'Invocation', 'Iterable',
  'Iterator', 'List', 'Map', 'MapEntry', 'Match', 'Never', 'NoSuchMethodError',
  'Null', 'num', 'Object', 'Pattern', 'pragma', 'RangeError', 'Record',
  'RegExp', 'RuneIterator', 'Runes', 'Set', 'Sink', 'StackTrace', 'Stopwatch',
  'Stream', 'String', 'StringBuffer', 'StringSink', 'Symbol', 'Type',
  'TypeError', 'UnimplementedError', 'UnsupportedError', 'Uri', 'WeakReference',
]);

const DART_FIXED_TOP_LEVEL = [
  '_expectString',
  '_expectInt',
  '_expectBool',
  '_expectList',
  '_expectMap',
  '_expectKeys',
];

const DART_OBJECT_MEMBERS = new Set([
  'fromJson',
  'hashCode',
  'noSuchMethod',
  'runtimeType',
  'toJson',
  'toString',
]);

const DART_ENUM_MEMBERS = new Set([
  ...DART_OBJECT_MEMBERS,
  'fromWire',
  'index',
  'name',
  'values',
  'wire',
]);

const TYPESCRIPT_SUPPORT_TYPES = [
  'ContractNode',
  'ContractField',
  'ContractVariant',
  'ReadonlyArray',
  'Record',
];

const TYPESCRIPT_FIXED_HELPERS = [
  'contractNodes',
  'isRecord',
  'assertNode',
  'assertFields',
  'assertContractType',
];

export function pascalName(value) {
  const words = value
    .replace(/([a-z0-9])([A-Z])/g, '$1 $2')
    .split(/[^A-Za-z0-9]+/)
    .filter(Boolean);
  let result = words.map((word) => `${word[0].toUpperCase()}${word.slice(1)}`).join('');
  if (!result) {
    const codeUnits = [];
    for (let index = 0; index < value.length; index += 1) {
      codeUnits.push(value.charCodeAt(index).toString(16).padStart(4, '0'));
    }
    result = `U${codeUnits.join('') || '0000'}`;
  }
  if (/^[0-9]/.test(result)) result = `N${result}`;
  return result;
}

export function dartMemberName(value) {
  const pascal = pascalName(value);
  let result = `${pascal[0].toLowerCase()}${pascal.slice(1)}`;
  if (DART_RESERVED.has(result)) result = `${result}Value`;
  return result;
}

export function enumMemberName(value) {
  return dartMemberName(value);
}

function registerName(names, name, owner, namespace) {
  const previous = names.get(name);
  if (previous !== undefined) {
    throw new Error(`${namespace} name collision for ${name}: ${previous} and ${owner}`);
  }
  names.set(name, owner);
}

function checkDartMembers(fields, className) {
  const members = new Map(
    [...DART_OBJECT_MEMBERS].map((name) => [name, 'generated/runtime member']),
  );
  for (const field of fields) {
    registerName(
      members,
      dartMemberName(field.name),
      `field ${JSON.stringify(field.name)}`,
      `Dart member in ${className}`,
    );
  }
}

function checkDartEnumMembers(node, name) {
  const members = new Map(
    [...DART_ENUM_MEMBERS].map((member) => [member, 'generated/runtime member']),
  );
  for (const value of node.values) {
    registerName(
      members,
      enumMemberName(value),
      `value ${JSON.stringify(value)}`,
      `Dart enum member in ${name}`,
    );
  }
}

function visitDartNode(node, name, globals, owner, {declare = true} = {}) {
  if (declare && ['object', 'enum', 'union'].includes(node.kind)) {
    registerName(globals, name, owner, 'Dart top-level');
  }

  switch (node.kind) {
    case 'object':
      checkDartMembers(node.fields, name);
      for (const field of node.fields) {
        visitDartNode(
          field.type,
          `${name}${pascalName(field.name)}`,
          globals,
          `${owner} nested field ${JSON.stringify(field.name)}`,
        );
      }
      break;
    case 'enum':
      checkDartEnumMembers(node, name);
      break;
    case 'union':
      for (const variant of node.variants) {
        const variantName = `${name}${pascalName(variant.tag)}`;
        registerName(
          globals,
          variantName,
          `${owner} union variant ${JSON.stringify(variant.tag)}`,
          'Dart top-level',
        );
        checkDartMembers(variant.fields, variantName);
        for (const field of variant.fields) {
          visitDartNode(
            field.type,
            `${variantName}${pascalName(field.name)}`,
            globals,
            `${owner} union variant ${JSON.stringify(variant.tag)} field ${JSON.stringify(field.name)}`,
          );
        }
      }
      break;
    case 'array':
      visitDartNode(node.items, `${name}Item`, globals, `${owner} array item`);
      break;
    case 'map':
      visitDartNode(node.values, `${name}Value`, globals, `${owner} map value`);
      break;
    case 'boolean':
    case 'integer':
    case 'ref':
    case 'string':
      break;
    default:
      throw new Error(`Dart naming preflight does not support node kind ${node.kind}`);
  }
}

function reserveNormalizedHelpers(names, helpers, namespace) {
  for (const helper of helpers) {
    registerName(names, pascalName(helper), `generated helper ${helper}`, namespace);
  }
}

export function validateGeneratedNames(activeDefinitionIds, definitions) {
  const ids = [...activeDefinitionIds].sort();
  const dartGlobals = new Map();
  for (const name of DART_CORE_NAMES) {
    registerName(dartGlobals, name, 'dart:core', 'Dart top-level');
  }
  for (const helper of DART_FIXED_TOP_LEVEL) {
    registerName(dartGlobals, helper, 'generated helper', 'Dart top-level');
  }
  reserveNormalizedHelpers(dartGlobals, DART_FIXED_TOP_LEVEL, 'Dart public');

  const typeNames = new Map();
  for (const id of ids) {
    const name = pascalName(id);
    registerName(typeNames, name, `definition ${id}`, 'generated public type');
    registerName(dartGlobals, name, `definition ${id}`, 'Dart top-level');
  }

  for (const id of ids) {
    const name = pascalName(id);
    registerName(dartGlobals, `decode${name}`, `codec for ${id}`, 'Dart top-level');
    registerName(dartGlobals, `encode${name}`, `codec for ${id}`, 'Dart top-level');
    reserveNormalizedHelpers(
      dartGlobals,
      [`decode${name}`, `encode${name}`],
      'Dart public',
    );
  }

  for (const id of ids) {
    visitDartNode(
      definitions.get(id).node,
      pascalName(id),
      dartGlobals,
      `definition ${id}`,
      {declare: false},
    );
  }

  const tsPublic = new Map();
  for (const supportType of TYPESCRIPT_SUPPORT_TYPES) {
    registerName(tsPublic, supportType, 'generated support type', 'TypeScript public');
  }
  reserveNormalizedHelpers(tsPublic, TYPESCRIPT_FIXED_HELPERS, 'TypeScript public');
  for (const id of ids) {
    registerName(tsPublic, pascalName(id), `definition ${id}`, 'TypeScript public');
  }
  for (const id of ids) {
    const name = pascalName(id);
    reserveNormalizedHelpers(
      tsPublic,
      [`decode${name}`, `encode${name}`],
      'TypeScript public',
    );
  }
}
