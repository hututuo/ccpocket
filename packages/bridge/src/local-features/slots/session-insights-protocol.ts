import {
  disabledLocalFeatureProtocolContribution,
  type LocalFeatureProtocolContribution,
} from "../protocol-slot.js";

export type CodexTokenUsageBreakdown = never;
export type ContextUsageMessage = never;
export type SessionUsageWindowPayload = never;
export type SessionUsageLimitCardPayload = never;
export type SessionUsageResetCreditPayload = never;
export type SessionUsageInfoPayload = never;
export type SessionInsightsClientMessage = never;
export type SessionInsightsServerMessage = never;

/** Disabled foundation slot; the session-insights commit activates it. */
export const sessionInsightsProtocolContribution: LocalFeatureProtocolContribution =
  disabledLocalFeatureProtocolContribution("session_insights");
