import {
  ConversationSyncV2FeatureHandler,
  type ConversationSyncV2Options,
} from "../conversation-sync-v2.js";
import type { LocalFeatureHandler, LocalFeatureRuntime } from "../runtime.js";

/** Additive unified catalog, status and timeline synchronizer. */
export function createConversationSyncV2Handlers(
  runtime: LocalFeatureRuntime,
  options: ConversationSyncV2Options = {},
): readonly LocalFeatureHandler[] {
  return [new ConversationSyncV2FeatureHandler(runtime, options)];
}
