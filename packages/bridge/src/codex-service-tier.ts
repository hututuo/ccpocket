/**
 * Normalize Codex's user-facing speed values for app-server RPCs.
 *
 * Some app-server responses and rollout files expose Fast by its lower-level
 * service tier id (`priority`). Bridge keeps the mobile protocol stable on the
 * public `fast` value and sends that same value back to current app-servers.
 */
export function normalizeCodexServiceTier(value: string): string | null {
  const normalized = value.trim();
  if (!normalized || normalized === "standard" || normalized === "default") {
    return null;
  }
  return normalized === "priority" ? "fast" : normalized;
}

/** Normalize an app-server or rollout value before exposing it to clients. */
export function normalizeCodexServiceTierForClient(value: unknown): string {
  if (typeof value !== "string") return "standard";
  return normalizeCodexServiceTier(value) ?? "standard";
}
