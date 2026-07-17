import type { LocalFeatureHandler, LocalFeatureRuntime } from "../runtime.js";
import type { ContextUsageMessage } from "../protocol.js";
import {
  ContextFeatureHandler,
  parseCodexContextUsageNotification,
} from "../context.js";
import { UsageFeatureHandler } from "../usage-service.js";

export function createSessionInsightsHandlers(
  runtime: LocalFeatureRuntime,
): readonly LocalFeatureHandler[] {
  return [new ContextFeatureHandler(), new UsageFeatureHandler(runtime)];
}

/**
 * Notification hook kept outside CodexProcess so the feature can be reverted
 * without editing the upstream-owned notification switch.
 */
export function parseSessionInsightsNotification(
  params: Record<string, unknown>,
): ContextUsageMessage | null {
  return parseCodexContextUsageNotification(params);
}
