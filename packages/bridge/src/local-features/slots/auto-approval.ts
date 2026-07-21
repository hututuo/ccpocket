import { AutoApprovalFeatureHandler } from "../auto-approval.js";
import type { LocalFeatureHandler, LocalFeatureRuntime } from "../runtime.js";

/** One removable registration seam for Bridge-owned automatic approvals. */
export function createAutoApprovalHandlers(
  runtime: LocalFeatureRuntime,
): readonly LocalFeatureHandler[] {
  return [new AutoApprovalFeatureHandler(runtime)];
}
