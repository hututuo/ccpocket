import { ConversationContentSyncFeatureHandler } from "../conversation-content-sync.js";
import type { LocalFeatureHandler, LocalFeatureRuntime } from "../runtime.js";

/** One removable Bridge-owned durable conversation update scheduler. */
export function createConversationContentHandlers(
  runtime: LocalFeatureRuntime,
): readonly LocalFeatureHandler[] {
  return [new ConversationContentSyncFeatureHandler(runtime)];
}
