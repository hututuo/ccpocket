import type { LocalFeatureHandler, LocalFeatureRuntime } from "../runtime.js";
import { SideChatFeatureHandler } from "../side-chat.js";
import { PersistedSideChatFeatureHandler } from "../persisted-side-chat.js";

export function createSideChatHandlers(
  _runtime: LocalFeatureRuntime,
): readonly LocalFeatureHandler[] {
  return [new SideChatFeatureHandler(), new PersistedSideChatFeatureHandler()];
}
