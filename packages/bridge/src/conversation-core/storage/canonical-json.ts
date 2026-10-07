import { createHash } from "node:crypto";

import { ConversationStoreError, type JsonObject } from "./types.js";

export const OPERATION_JSON_MAX_BYTES = 64 * 1024;
export const TIMELINE_PAGE_MAX_BYTES = 256 * 1024;
export const JSON_MAX_DEPTH = 32;
export const JSON_MAX_NODES = 100_000;

const HOSTILE_KEYS = new Set(["__proto__", "prototype", "constructor"]);

export interface CanonicalJsonOptions {
  maxBytes: number;
  maxDepth?: number;
  maxNodes?: number;
  requireObject?: boolean;
}

/** RFC 8785/JCS for the I-JSON subset accepted by this store. */
export function canonicalizeJson(value: unknown, options: CanonicalJsonOptions): string {
  const maxDepth = options.maxDepth ?? JSON_MAX_DEPTH;
  const maxNodes = options.maxNodes ?? JSON_MAX_NODES;
  let nodes = 0;
  const ancestors = new Set<object>();

  const visit = (current: unknown, depth: number): string => {
    nodes += 1;
    if (nodes > maxNodes) invalid("JSON node limit exceeded");
    if (depth > maxDepth) invalid("JSON depth limit exceeded");
    if (current === null) return "null";
    switch (typeof current) {
      case "boolean":
        return current ? "true" : "false";
      case "string":
        assertUnicodeScalarString(current);
        return JSON.stringify(current);
      case "number":
        if (!Number.isFinite(current)) invalid("non-finite JSON number");
        return JSON.stringify(current);
      case "bigint":
        invalid("BigInt is not JSON");
      case "undefined":
      case "function":
      case "symbol":
        invalid(`unsupported JSON value ${typeof current}`);
      case "object":
        break;
      default:
        invalid("unsupported JSON value");
    }

    const object = current as object;
    if (ancestors.has(object)) invalid("cyclic JSON value");
    ancestors.add(object);
    try {
      if (Array.isArray(object)) {
        const descriptors = Object.getOwnPropertyDescriptors(object);
        if (Object.getOwnPropertySymbols(object).length !== 0) invalid("symbol JSON key");
        for (let index = 0; index < object.length; index += 1) {
          const descriptor = descriptors[String(index)];
          if (!descriptor || !("value" in descriptor)) invalid("sparse or accessor JSON array");
        }
        const extraKeys = Object.keys(object).filter((key) => !/^(0|[1-9][0-9]*)$/.test(key));
        if (extraKeys.length !== 0) invalid("array has non-index JSON properties");
        return `[${object.map((entry) => visit(entry, depth + 1)).join(",")}]`;
      }

      const prototype = Object.getPrototypeOf(object);
      if (prototype !== Object.prototype && prototype !== null) invalid("non-plain JSON object");
      if (Object.getOwnPropertySymbols(object).length !== 0) invalid("symbol JSON key");
      const descriptors = Object.getOwnPropertyDescriptors(object);
      const keys = Object.keys(descriptors).sort();
      const pairs: string[] = [];
      for (const key of keys) {
        if (HOSTILE_KEYS.has(key)) invalid(`hostile JSON key ${key}`);
        assertUnicodeScalarString(key);
        const descriptor = descriptors[key];
        if (!descriptor || !("value" in descriptor) || !descriptor.enumerable) {
          invalid("non-enumerable or accessor JSON property");
        }
        pairs.push(`${JSON.stringify(key)}:${visit(descriptor.value, depth + 1)}`);
      }
      return `{${pairs.join(",")}}`;
    } finally {
      ancestors.delete(object);
    }
  };

  if (options.requireObject && !isPlainObject(value)) invalid("top-level JSON must be an object");
  const encoded = visit(value, 0);
  if (Buffer.byteLength(encoded, "utf8") > options.maxBytes) {
    throw new ConversationStoreError("PAYLOAD_TOO_LARGE", "canonical JSON byte limit exceeded");
  }
  return encoded;
}

export function canonicalizeJsonObject(value: JsonObject, maxBytes: number): string {
  return canonicalizeJson(value, { maxBytes, requireObject: true });
}

export function sha256CanonicalJson(value: unknown, maxBytes: number): { canonical: string; digest: string } {
  const canonical = canonicalizeJson(value, { maxBytes });
  return {
    canonical,
    digest: createHash("sha256").update(canonical, "utf8").digest("hex"),
  };
}

export function sha256Text(value: string): string {
  return createHash("sha256").update(value, "utf8").digest("hex");
}

export function parseStoredJsonObject(value: string): JsonObject {
  const decoded: unknown = JSON.parse(value);
  if (!isPlainObject(decoded)) invalid("stored JSON value is not a plain object");
  // Re-validation protects readers if the database was modified outside the API.
  canonicalizeJson(decoded, { maxBytes: Math.max(Buffer.byteLength(value, "utf8"), 1), requireObject: true });
  return decoded;
}

function isPlainObject(value: unknown): value is JsonObject {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return false;
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function assertUnicodeScalarString(value: string): void {
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code >= 0xd800 && code <= 0xdbff) {
      const next = value.charCodeAt(index + 1);
      if (!(next >= 0xdc00 && next <= 0xdfff)) invalid("unpaired high surrogate");
      index += 1;
    } else if (code >= 0xdc00 && code <= 0xdfff) {
      invalid("unpaired low surrogate");
    }
  }
}

function invalid(message: string): never {
  throw new ConversationStoreError("INVALID_JSON", message);
}
