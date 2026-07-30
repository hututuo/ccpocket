import {
  hasOnlyLocalFeatureKeys,
  validLocalFeatureId,
  type LocalFeatureProtocolContribution,
} from "../protocol-slot.js";

export const EPHEMERAL_SIDE_CHAT_CAPABILITY = "ephemeral_side_chat_v1";
export const EPHEMERAL_SIDE_CHAT_PARENT_IDENTITY_CAPABILITY =
  "ephemeral_side_chat_parent_identity_v1";

export interface OpenEphemeralSideChatMessage {
  type: "open_ephemeral_side_chat";
  parentSessionId: string;
  parentProviderSessionId?: string;
  requestId: string;
}

export interface ListEphemeralSideChatsMessage {
  type: "list_ephemeral_side_chats";
  requestId: string;
}

export interface CloseEphemeralSideChatMessage {
  type: "close_ephemeral_side_chat";
  childSessionId: string;
  requestId: string;
}

export type EphemeralSideChatClientMessage =
  | OpenEphemeralSideChatMessage
  | ListEphemeralSideChatsMessage
  | CloseEphemeralSideChatMessage;

export interface EphemeralSideChatEntry {
  childSessionId: string;
  parentSessionId: string;
  parentProviderSessionId?: string;
  projectPath: string;
  worktreePath?: string;
  worktreeBranch?: string;
  permissionMode?: string;
  sandboxMode?: string;
  approvalPolicy?: string;
  approvalsReviewer?: string;
  status: string;
  createdAt: string;
  lastActivityAt: string;
}

export interface EphemeralSideChatOpenedMessage {
  type: "ephemeral_side_chat_opened";
  parentSessionId: string;
  requestId: string;
  entry?: EphemeralSideChatEntry;
  error?: string;
  errorCode?: string;
}

export interface EphemeralSideChatRegistryMessage {
  type: "ephemeral_side_chat_registry";
  requestId?: string;
  entries?: EphemeralSideChatEntry[];
  error?: string;
  errorCode?: string;
}

export type EphemeralSideChatServerMessage =
  | EphemeralSideChatOpenedMessage
  | EphemeralSideChatRegistryMessage;

export const ephemeralSideChatProtocolContribution: LocalFeatureProtocolContribution<
  EphemeralSideChatClientMessage,
  EphemeralSideChatServerMessage
> = {
  clientTypes: [
    "open_ephemeral_side_chat",
    "list_ephemeral_side_chats",
    "close_ephemeral_side_chat",
  ],
  serverTypes: [
    "ephemeral_side_chat_opened",
    "ephemeral_side_chat_registry",
  ],
  parseClient(message) {
    if (message.type === "open_ephemeral_side_chat") {
      return hasOnlyLocalFeatureKeys(message, [
        "type",
        "parentSessionId",
        "parentProviderSessionId",
        "requestId",
      ]) &&
        validLocalFeatureId(message.parentSessionId, 256) &&
        (message.parentProviderSessionId === undefined ||
          validLocalFeatureId(message.parentProviderSessionId, 256)) &&
        validLocalFeatureId(message.requestId, 128)
        ? {
            type: "open_ephemeral_side_chat",
            parentSessionId: message.parentSessionId,
            ...(message.parentProviderSessionId
              ? { parentProviderSessionId: message.parentProviderSessionId }
              : {}),
            requestId: message.requestId,
          }
        : null;
    }
    if (message.type === "list_ephemeral_side_chats") {
      return hasOnlyLocalFeatureKeys(message, ["type", "requestId"]) &&
        validLocalFeatureId(message.requestId, 128)
        ? {
            type: "list_ephemeral_side_chats",
            requestId: message.requestId,
          }
        : null;
    }
    if (message.type === "close_ephemeral_side_chat") {
      return hasOnlyLocalFeatureKeys(message, [
        "type",
        "childSessionId",
        "requestId",
      ]) &&
        validLocalFeatureId(message.childSessionId, 256) &&
        validLocalFeatureId(message.requestId, 128)
        ? {
            type: "close_ephemeral_side_chat",
            childSessionId: message.childSessionId,
            requestId: message.requestId,
          }
        : null;
    }
    return undefined;
  },
};
