import { LocalFeaturesController } from "./controller.js";
import type { LocalFeatureRuntime } from "./runtime.js";
import { createSessionInsightsHandlers } from "./slots/session-insights.js";
import { createSideChatHandlers } from "./slots/side-chat.js";
import { createSubagentsHandlers } from "./slots/subagents.js";

/**
 * The only concrete feature registry. Every slot exists in the foundation as
 * a disabled stub. A feature commit activates only its own slot, so reverting
 * that commit restores the stub without touching this composition root.
 */
export function createLocalFeaturesController(
  runtime: LocalFeatureRuntime,
): LocalFeaturesController {
  return new LocalFeaturesController(runtime, [
    ...createSessionInsightsHandlers(runtime),
    ...createSubagentsHandlers(runtime),
    ...createSideChatHandlers(runtime),
  ]);
}
