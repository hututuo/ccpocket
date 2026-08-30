import { createHash } from 'node:crypto';

export function sortJson(value) {
  if (Array.isArray(value)) {
    return value.map(sortJson);
  }
  if (value !== null && typeof value === 'object') {
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [key, sortJson(value[key])]),
    );
  }
  return value;
}

export function canonicalJson(value, space = 2) {
  return `${JSON.stringify(sortJson(value), null, space)}\n`;
}

export function digestJson(value) {
  return createHash('sha256')
    .update(JSON.stringify(sortJson(value)))
    .digest('hex');
}

export function digestBytes(value) {
  return createHash('sha256').update(value).digest('hex');
}

export function jsonEqual(left, right) {
  return JSON.stringify(sortJson(left)) === JSON.stringify(sortJson(right));
}
