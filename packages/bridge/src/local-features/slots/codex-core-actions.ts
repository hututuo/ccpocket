import { CodexCoreActionsFeatureHandler } from "../codex-core-actions.js";
import type { LocalFeatureHandler, LocalFeatureRuntime } from "../runtime.js";

export function createCodexCoreActionsHandlers(
  _runtime: LocalFeatureRuntime,
): readonly LocalFeatureHandler[] {
  return [new CodexCoreActionsFeatureHandler()];
}
