import type { LocalFeatureHandler, LocalFeatureRuntime } from "../runtime.js";

/** Disabled registration slot; activated only by the Mirror Bridge commit. */
export function createConversationMirrorHandlers(
  _runtime: LocalFeatureRuntime,
): readonly LocalFeatureHandler[] {
  return [];
}
