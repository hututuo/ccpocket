import {
  disabledLocalFeatureProtocolContribution,
  type LocalFeatureProtocolContribution,
} from "../protocol-slot.js";

export type SideChatPermissionDecision = never;
export type SideChatClientMessage = never;
export type SideChatMessagePayload = never;
export type SideChatEventMessage = never;

/** Disabled foundation slot; the side-chat commit activates it. */
export const sideChatProtocolContribution: LocalFeatureProtocolContribution =
  disabledLocalFeatureProtocolContribution("side_chat");
