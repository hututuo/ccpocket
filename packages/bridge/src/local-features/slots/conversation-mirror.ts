import type { LocalFeatureHandler, LocalFeatureRuntime } from "../runtime.js";
import { ConversationMirrorFeatureHandler } from "../conversation-mirror.js";

/** One removable registration seam for the complete conversation mirror. */
export function createConversationMirrorHandlers(
  runtime: LocalFeatureRuntime,
): readonly LocalFeatureHandler[] {
  return [new ConversationMirrorFeatureHandler(runtime)];
}
