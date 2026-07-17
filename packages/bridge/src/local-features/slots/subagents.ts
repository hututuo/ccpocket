import type { LocalFeatureHandler, LocalFeatureRuntime } from "../runtime.js";
import { SubagentsFeatureHandler } from "../subagents.js";

export function createSubagentsHandlers(
  _runtime: LocalFeatureRuntime,
): readonly LocalFeatureHandler[] {
  return [new SubagentsFeatureHandler()];
}
