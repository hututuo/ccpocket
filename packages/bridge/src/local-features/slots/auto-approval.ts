import {
  AutoApprovalFeatureHandler,
  type AutoApprovalFeatureOptions,
} from "../auto-approval.js";
import type { LocalFeatureHandler, LocalFeatureRuntime } from "../runtime.js";

/** One removable registration seam for Bridge-owned automatic approvals. */
export function createAutoApprovalHandlers(
  runtime: LocalFeatureRuntime,
  options: AutoApprovalFeatureOptions = {},
): readonly LocalFeatureHandler[] {
  return [new AutoApprovalFeatureHandler(runtime, options)];
}
