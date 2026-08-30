import {createHash} from 'node:crypto';

const MAX_DEPTH = 512;
const MAX_NODES = 100_000;
const SAFE_INTEGER_MAX = Number.MAX_SAFE_INTEGER;
const RFC8785_SAFE_INTEGER_PROFILE = 'RFC8785-IJSON-SAFE-INTEGER-V1';

function fail(path, message) {
  throw new TypeError(path + ': ' + message);
}

function assertUnicodeScalarString(value, path) {
  for (let index = 0; index < value.length; index += 1) {
    const codeUnit = value.charCodeAt(index);
    if (codeUnit >= 0xd800 && codeUnit <= 0xdbff) {
      const next = value.charCodeAt(index + 1);
      if (!Number.isInteger(next) || next < 0xdc00 || next > 0xdfff) {
        fail(path, 'lone surrogate is not valid I-JSON');
      }
      index += 1;
    } else if (codeUnit >= 0xdc00 && codeUnit <= 0xdfff) {
      fail(path, 'lone surrogate is not valid I-JSON');
    }
  }
}

/** RFC 8785 orders object keys by their UTF-16 code units. */
export function compareUtf16(left, right) {
  const length = Math.min(left.length, right.length);
  for (let index = 0; index < length; index += 1) {
    const difference = left.charCodeAt(index) - right.charCodeAt(index);
    if (difference !== 0) return difference;
  }
  return left.length - right.length;
}

function jsonString(value, path) {
  assertUnicodeScalarString(value, path);
  const encoded = JSON.stringify(value);
  if (encoded === undefined) fail(path, 'string could not be serialized');
  return encoded;
}

function numberString(value, path) {
  if (!Number.isSafeInteger(value)) {
    fail(path, 'JSON numbers must be safe integers');
  }
  // JSON.stringify(-0) is deliberately normalized to the RFC 8785 value 0.
  return Object.is(value, -0) ? '0' : String(value);
}

function assertPlainObject(value, path) {
  const prototype = Object.getPrototypeOf(value);
  if (prototype !== Object.prototype && prototype !== null) {
    fail(path, 'only plain objects or null-prototype objects are valid I-JSON');
  }
  const ownKeys = Reflect.ownKeys(value);
  const entries = [];
  if (ownKeys.some((key) => typeof key !== 'string')) {
    fail(path, 'symbol properties are not valid I-JSON');
  }
  for (const key of ownKeys) {
    const descriptor = Object.getOwnPropertyDescriptor(value, key);
    if (!descriptor || !Object.hasOwn(descriptor, 'value') || descriptor.enumerable !== true) {
      fail(path + '.' + key, 'non-enumerable or accessor properties are not valid I-JSON');
    }
    entries.push([key, descriptor.value]);
  }
  return entries;
}

function canonicalizeValue(value, path, state, depth) {
  if (depth > state.maxDepth) fail(path, 'canonical JSON nesting is too deep');
  state.nodes += 1;
  if (state.nodes > state.maxNodes) fail(path, 'canonical JSON node limit exceeded');

  if (value === null) return 'null';
  switch (typeof value) {
    case 'string': return jsonString(value, path);
    case 'number': return numberString(value, path);
    case 'boolean': return value ? 'true' : 'false';
    case 'undefined':
      fail(path, 'undefined is not valid I-JSON');
      break;
    case 'bigint':
      fail(path, 'BigInt is not valid I-JSON');
      break;
    case 'function':
    case 'symbol':
      fail(path, typeof value + ' is not valid I-JSON');
      break;
    default:
      break;
  }

  if (state.stack.has(value)) fail(path, 'cyclic value is not valid I-JSON');
  state.stack.add(value);
  try {
    if (Array.isArray(value)) {
      const ownKeys = Reflect.ownKeys(value);
      if (ownKeys.some((key) => typeof key === 'symbol')) fail(path, 'symbol properties are not valid I-JSON');
      const lengthDescriptor = Object.getOwnPropertyDescriptor(value, 'length');
      if (!lengthDescriptor || !Object.hasOwn(lengthDescriptor, 'value') || lengthDescriptor.enumerable !== false) {
        fail(path + '.length', 'array length is not a valid data property');
      }
      const length = lengthDescriptor.value;
      const expectedKeys = new Set(['length']);
      const entries = [];
      for (let index = 0; index < length; index += 1) {
        expectedKeys.add(String(index));
        const descriptor = Object.getOwnPropertyDescriptor(value, String(index));
        if (!descriptor || !Object.hasOwn(descriptor, 'value') || descriptor.enumerable !== true) {
          fail(path + '[' + index + ']', 'sparse or accessor array entry is not valid I-JSON');
        }
        entries.push(descriptor.value);
      }
      for (const key of ownKeys) {
        if (typeof key === 'string' && !expectedKeys.has(key)) fail(path + '.' + key, 'array has an unsupported own property');
      }
      return '[' + entries.map((entry, index) => canonicalizeValue(
        entry,
        path + '[' + index + ']',
        state,
        depth + 1,
      )).join(',') + ']';
    }
    if (typeof value !== 'object') fail(path, 'unsupported value');
    const entries = assertPlainObject(value, path);
    entries.sort(([left], [right]) => compareUtf16(left, right));
    const members = entries.map(([key, entry]) => {
      assertUnicodeScalarString(key, path + '.' + key);
      return jsonString(key, path + '.' + key) + ':' + canonicalizeValue(
        entry,
        path + '.' + key,
        state,
        depth + 1,
      );
    });
    return '{' + members.join(',') + '}';
  } finally {
    state.stack.delete(value);
  }
}

/**
 * Serialize the I-JSON safe-integer subset used by the active contract.
 * This is intentionally independent from key-ordering JSON.stringify helpers.
 */
export function canonicalize(value, {
  maxDepth = MAX_DEPTH,
  maxNodes = MAX_NODES,
} = {}) {
  if (!Number.isInteger(maxDepth) || maxDepth < 0) throw new RangeError('maxDepth must be a non-negative integer');
  if (!Number.isInteger(maxNodes) || maxNodes < 1) throw new RangeError('maxNodes must be a positive integer');
  return canonicalizeValue(value, '$', {
    maxDepth,
    maxNodes,
    nodes: 0,
    stack: new Set(),
  }, 0);
}

export function canonicalUtf8(value, options) {
  return Buffer.from(canonicalize(value, options), 'utf8');
}

export function jcsDigest(value, options) {
  return createHash('sha256').update(canonicalUtf8(value, options)).digest('hex');
}

// Kept private on purpose. Authority code must use a generated, closed typed
// preimage helper instead of allowing callers to choose a required-key list.
function digestDomainSeparatedJcs(value, {digestDomain, requiredKeys = []} = {}) {
  if (typeof digestDomain !== 'string' || digestDomain.length === 0) {
    throw new TypeError('digestDomain is required for a domain-separated preimage');
  }
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new TypeError('domain-separated preimage must be a plain object');
  }
  assertPlainObject(value, '$');
  if (value.digestDomain !== digestDomain) {
    throw new TypeError('digestDomain literal mismatch');
  }
  for (const key of requiredKeys) {
    if (!Object.hasOwn(value, key)) throw new TypeError('preimage field is missing: ' + key);
  }
  return jcsDigest(value);
}

function prettyValue(value, indent, level) {
  if (value === null || typeof value !== 'object') {
    return canonicalize(value);
  }
  const keys = Array.isArray(value) ? null : Object.keys(value).sort(compareUtf16);
  if (Array.isArray(value)) {
    if (value.length === 0) return '[]';
    const padding = ' '.repeat(indent * (level + 1));
    const closing = ' '.repeat(indent * level);
    return '[\n' + padding +
      value.map((entry) => prettyValue(entry, indent, level + 1)).join(',\n' + padding) +
      '\n' + closing + ']';
  }
  if (keys.length === 0) return '{}';
  const padding = ' '.repeat(indent * (level + 1));
  const closing = ' '.repeat(indent * level);
  return '{\n' + padding +
    keys.map((key) => jsonString(key, '$') + ': ' + prettyValue(value[key], indent, level + 1))
      .join(',\n' + padding) +
    '\n' + closing + '}';
}

/** Human-readable deterministic projection; digests always use canonicalize(). */
export function canonicalJson(value, space = 2, options) {
  if (!Number.isInteger(space) || space < 0 || space > 10) throw new RangeError('space must be between 0 and 10');
  // Canonicalize once, then pretty-print an immutable parsed snapshot. This
  // keeps a dynamic Proxy from being observed a second time by the pretty
  // printer with values different from the bytes that were validated.
  const snapshot = JSON.parse(canonicalize(value, options));
  return prettyValue(snapshot, space, 0) + '\n';
}

function sortJson(value) {
  if (Array.isArray(value)) return value.map(sortJson);
  if (value !== null && typeof value === 'object') {
    return Object.fromEntries(Object.keys(value).sort(compareUtf16).map((key) => [key, sortJson(value[key])]));
  }
  return value;
}

export function digestJson(value, options) {
  return jcsDigest(value, options);
}

export function digestBytes(value) {
  return createHash('sha256').update(value).digest('hex');
}

export function jsonEqual(left, right) {
  return canonicalize(left) === canonicalize(right);
}

export {MAX_DEPTH, MAX_NODES, SAFE_INTEGER_MAX, RFC8785_SAFE_INTEGER_PROFILE};
