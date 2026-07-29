import { ConversationSyncV2FeatureHandler } from "../conversation-sync-v2.js";
import type { LocalFeatureHandler, LocalFeatureRuntime } from "../runtime.js";

/** Additive unified catalog, status and timeline synchronizer. */
export function createConversationSyncV2Handlers(
  runtime: LocalFeatureRuntime,
): readonly LocalFeatureHandler[] {
  return [new ConversationSyncV2FeatureHandler(runtime)];
}
