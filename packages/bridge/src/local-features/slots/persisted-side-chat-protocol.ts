import {
  hasOnlyLocalFeatureKeys,
  validLocalFeatureId,
  type LocalFeatureProtocolContribution,
} from "../protocol-slot.js";

export interface OpenPersistedSideChatMessage {
  type: "open_persisted_side_chat";
  parentSessionId: string;
  requestId: string;
}

export interface PersistedSideChatOpenedMessage {
  type: "persisted_side_chat_opened";
  parentSessionId: string;
  requestId: string;
  childSessionId?: string;
  projectPath?: string;
  worktreePath?: string;
  worktreeBranch?: string;
  permissionMode?: string;
  sandboxMode?: string;
  approvalPolicy?: string;
  approvalsReviewer?: string;
  error?: string;
  errorCode?: string;
}

export const persistedSideChatProtocolContribution: LocalFeatureProtocolContribution<
  OpenPersistedSideChatMessage,
  PersistedSideChatOpenedMessage
> = {
  clientTypes: ["open_persisted_side_chat"],
  serverTypes: ["persisted_side_chat_opened"],
  parseClient(message) {
    if (message.type !== "open_persisted_side_chat") return undefined;
    return hasOnlyLocalFeatureKeys(message, [
      "type",
      "parentSessionId",
      "requestId",
    ]) &&
      validLocalFeatureId(message.parentSessionId, 256) &&
      validLocalFeatureId(message.requestId, 128)
      ? {
          type: "open_persisted_side_chat",
          parentSessionId: message.parentSessionId,
          requestId: message.requestId,
        }
      : null;
  },
};
