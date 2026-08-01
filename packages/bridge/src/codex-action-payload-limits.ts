const MAX_ACTION_PAYLOAD_DEPTH = 12;
const MAX_ACTION_PAYLOAD_NODES = 2_048;
const MAX_ACTION_PAYLOAD_STRING_BYTES = 16 * 1024;
const MAX_ACTION_PAYLOAD_SERIALIZED_BYTES = 48 * 1024;

/**
 * Approval payloads use the ordinary local-feature WebSocket path rather than
 * conversation-sync-v2 framing. Reject the complete payload when any bound is
 * exceeded: truncating approval context while leaving an action enabled would
 * let a user approve information they could not inspect.
 */
export function isCodexActionPayloadWithinLimits(value: unknown): boolean {
  const seen = new WeakSet<object>();
  let nodes = 0;

  const visit = (candidate: unknown, depth: number): boolean => {
    nodes += 1;
    if (nodes > MAX_ACTION_PAYLOAD_NODES || depth > MAX_ACTION_PAYLOAD_DEPTH) {
      return false;
    }
    if (candidate === null || typeof candidate === "boolean") return true;
    if (typeof candidate === "number") return Number.isFinite(candidate);
    if (typeof candidate === "string") {
      return (
        Buffer.byteLength(candidate, "utf8") <= MAX_ACTION_PAYLOAD_STRING_BYTES
      );
    }
    if (typeof candidate !== "object") return false;
    if (seen.has(candidate)) return false;
    seen.add(candidate);

    if (Array.isArray(candidate)) {
      for (const entry of candidate) {
        if (!visit(entry, depth + 1)) return false;
      }
      return true;
    }
    const prototype = Object.getPrototypeOf(candidate);
    if (prototype !== Object.prototype && prototype !== null) return false;
    for (const [key, entry] of Object.entries(candidate)) {
      nodes += 1;
      if (
        nodes > MAX_ACTION_PAYLOAD_NODES ||
        Buffer.byteLength(key, "utf8") > MAX_ACTION_PAYLOAD_STRING_BYTES ||
        !visit(entry, depth + 1)
      ) {
        return false;
      }
    }
    return true;
  };

  if (!visit(value, 0)) return false;
  try {
    const serialized = JSON.stringify(value);
    return (
      serialized !== undefined &&
      Buffer.byteLength(serialized, "utf8") <=
        MAX_ACTION_PAYLOAD_SERIALIZED_BYTES
    );
  } catch {
    return false;
  }
}
