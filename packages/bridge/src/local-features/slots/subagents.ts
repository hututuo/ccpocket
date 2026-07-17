import type { LocalFeatureHandler, LocalFeatureRuntime } from "../runtime.js";

/** Disabled foundation slot; the subagents commit activates it. */
export function createSubagentsHandlers(
  _runtime: LocalFeatureRuntime,
): readonly LocalFeatureHandler[] {
  return [];
}
