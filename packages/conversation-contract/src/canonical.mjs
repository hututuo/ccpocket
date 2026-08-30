import { createHash } from 'node:crypto';

export function sortJson(value) {
  if (Array.isArray(value)) {
    return value.map(sortJson);
  }
  if (value !== null && typeof value === 'object') {
    const sorted = Object.create(null);
    for (const key of Object.keys(value).sort()) {
      sorted[key] = sortJson(value[key]);
    }
    return sorted;
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
