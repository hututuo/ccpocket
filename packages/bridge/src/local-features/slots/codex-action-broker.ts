import { CodexActionBrokerFeatureHandler } from "../codex-action-broker.js";
import type { LocalFeatureHandler, LocalFeatureRuntime } from "../runtime.js";

export function createCodexActionBrokerHandlers(
  runtime: LocalFeatureRuntime,
): readonly LocalFeatureHandler[] {
  return [new CodexActionBrokerFeatureHandler(runtime)];
}
