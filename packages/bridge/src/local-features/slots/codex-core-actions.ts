import type { LocalFeatureHandler, LocalFeatureRuntime } from "../runtime.js";

/** Disabled registration slot; activated only by the Core Bridge commit. */
export function createCodexCoreActionsHandlers(
  _runtime: LocalFeatureRuntime,
): readonly LocalFeatureHandler[] {
  return [];
}
