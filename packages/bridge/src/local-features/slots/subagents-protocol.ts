import {
  disabledLocalFeatureProtocolContribution,
  type LocalFeatureProtocolContribution,
} from "../protocol-slot.js";

export type CodexSubagentInfo = never;
export type SubagentsClientMessage = never;
export type SubagentsServerMessage = never;

/** Disabled foundation slot; the subagents commit activates it. */
export const subagentsProtocolContribution: LocalFeatureProtocolContribution =
  disabledLocalFeatureProtocolContribution("subagents");
