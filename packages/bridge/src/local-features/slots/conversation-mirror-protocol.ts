import {
  disabledLocalFeatureProtocolContribution,
  type LocalFeatureProtocolContribution,
} from "../protocol-slot.js";

/**
 * Disabled compatibility slot for the optional conversation-mirror module.
 * The feature commit replaces this file with its versioned wire contract.
 */
export type ConversationMirrorProvider = never;
export type ConversationMirrorClientMessage = never;
export type ConversationMirrorEntry = never;
export type ConversationMirrorEventMessage = never;
export type ConversationMirrorThreadStatus = never;

export const conversationMirrorProtocolContribution =
  disabledLocalFeatureProtocolContribution(
    "conversation_mirror",
  ) as LocalFeatureProtocolContribution<
    ConversationMirrorClientMessage,
    ConversationMirrorEventMessage
  >;
