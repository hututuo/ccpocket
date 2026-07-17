import type { LocalFeatureHandler, LocalFeatureRuntime } from "../runtime.js";

/** Disabled foundation slot; the side-chat commit activates it. */
export function createSideChatHandlers(
  _runtime: LocalFeatureRuntime,
): readonly LocalFeatureHandler[] {
  return [];
}
