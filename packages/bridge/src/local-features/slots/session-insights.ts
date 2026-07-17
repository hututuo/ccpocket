import type { LocalFeatureHandler, LocalFeatureRuntime } from "../runtime.js";
import type { ContextUsageMessage } from "../protocol.js";

/** Disabled foundation slot; the session-insights commit activates it. */
export function createSessionInsightsHandlers(
  _runtime: LocalFeatureRuntime,
): readonly LocalFeatureHandler[] {
  return [];
}

/**
 * Notification hook kept outside CodexProcess so the feature can be reverted
 * without editing the upstream-owned notification switch.
 */
export function parseSessionInsightsNotification(
  _params: Record<string, unknown>,
): ContextUsageMessage | null {
  return null;
}
