import {
  sessionInsightsProtocolContribution,
  type SessionInsightsClientMessage,
  type SessionInsightsServerMessage,
} from "./slots/session-insights-protocol.js";
import {
  sideChatProtocolContribution,
  type SideChatClientMessage,
  type SideChatEventMessage,
} from "./slots/side-chat-protocol.js";
import {
  subagentsProtocolContribution,
  type SubagentsClientMessage,
  type SubagentsServerMessage,
} from "./slots/subagents-protocol.js";
import type {
  LocalFeatureClientMessageShape,
  LocalFeatureProtocolContribution,
} from "./protocol-slot.js";

export type {
  CodexTokenUsageBreakdown,
  ContextUsageMessage,
  SessionUsageInfoPayload,
  SessionUsageLimitCardPayload,
  SessionUsageResetCreditPayload,
  SessionUsageWindowPayload,
} from "./slots/session-insights-protocol.js";
export type {
  SideChatEventMessage,
  SideChatMessagePayload,
  SideChatPermissionDecision,
} from "./slots/side-chat-protocol.js";
export type { CodexSubagentInfo } from "./slots/subagents-protocol.js";

export type LocalFeatureClientMessage =
  | SessionInsightsClientMessage
  | SubagentsClientMessage
  | SideChatClientMessage;

export type LocalFeatureServerMessage =
  | SessionInsightsServerMessage
  | SubagentsServerMessage
  | SideChatEventMessage;

const CONTRIBUTIONS: readonly LocalFeatureProtocolContribution[] = [
  sessionInsightsProtocolContribution,
  subagentsProtocolContribution,
  sideChatProtocolContribution,
];

const LOCAL_CLIENT_TYPES = new Set<string>(
  CONTRIBUTIONS.flatMap((contribution) => contribution.clientTypes),
);
const LOCAL_SERVER_TYPES = new Set<string>(
  CONTRIBUTIONS.flatMap((contribution) => contribution.serverTypes),
);

export function isLocalFeatureServerMessage(
  message: { type: string },
): message is LocalFeatureServerMessage {
  return isLocalFeatureServerMessageType(message.type);
}

export function isLocalFeatureServerMessageType(type: string): boolean {
  return LOCAL_SERVER_TYPES.has(type);
}

/**
 * `undefined` means this is not a local-feature message; `null` means a slot
 * recognized its type but rejected the payload.
 */
export function parseLocalFeatureClientMessage(
  message: Record<string, unknown>,
): LocalFeatureClientMessage | null | undefined {
  for (const contribution of CONTRIBUTIONS) {
    const parsed = contribution.parseClient(message);
    if (parsed !== undefined) {
      return parsed as LocalFeatureClientMessage | null;
    }
  }
  return undefined;
}

export function isLocalFeatureClientMessage(
  message: LocalFeatureClientMessageShape,
): message is LocalFeatureClientMessage {
  return LOCAL_CLIENT_TYPES.has(message.type);
}
