import {
  disabledLocalFeatureProtocolContribution,
  type LocalFeatureProtocolContribution,
} from "../protocol-slot.js";

/**
 * Disabled compatibility slot for the optional native Codex action module.
 * The feature commit replaces this file with the real compact/review/MCP
 * protocol while the composition root remains unchanged.
 */
export type CodexCoreAction = never;
export type CodexCoreActionStatus = never;
export type CodexCoreActionsClientMessage = never;
export type CodexCoreActionsServerMessage = never;
export type CodexMcpServerInfoSummary = never;
export type CodexMcpServerStatusSummary = never;
export type CodexMcpStatusResultStatus = never;
export type CodexMcpToolSummary = never;
export type CodexReviewRequestTarget = never;

export const codexCoreActionsProtocolContribution =
  disabledLocalFeatureProtocolContribution(
    "codex_core_actions",
  ) as LocalFeatureProtocolContribution<
    CodexCoreActionsClientMessage,
    CodexCoreActionsServerMessage
  >;
