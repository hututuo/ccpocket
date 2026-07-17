import {
  hasOnlyLocalFeatureKeys,
  validLocalFeatureId,
  validLocalFeatureText,
  type LocalFeatureProtocolContribution,
} from "../protocol-slot.js";

const SIDE_CHAT_TEXT_MAX_LENGTH = 100_000;

const CLIENT_TYPES = [
  "open_side_chat",
  "side_chat_input",
  "side_chat_permission_response",
  "side_chat_answer",
  "side_chat_interrupt",
  "close_side_chat",
] as const;

export type SideChatPermissionDecision =
  | "allow"
  | "allow_always"
  | "deny";

export type SideChatClientMessage =
  | { type: "open_side_chat"; parentSessionId: string; requestId: string }
  | {
      type: "side_chat_input";
      parentSessionId: string;
      sideChatId: string;
      requestId: string;
      clientMessageId: string;
      text: string;
    }
  | {
      type: "side_chat_permission_response";
      parentSessionId: string;
      sideChatId: string;
      requestId: string;
      permissionRequestId: string;
      decision: SideChatPermissionDecision;
    }
  | {
      type: "side_chat_answer";
      parentSessionId: string;
      sideChatId: string;
      requestId: string;
      questionRequestId: string;
      answer: string;
    }
  | {
      type: "side_chat_interrupt";
      parentSessionId: string;
      sideChatId: string;
      requestId: string;
    }
  | {
      type: "close_side_chat";
      parentSessionId: string;
      sideChatId: string;
      requestId: string;
    };

export interface SideChatMessagePayload {
  id: string;
  role: "user" | "assistant" | "tool" | "system";
  text: string;
}

interface SideChatEventBase {
  type: "side_chat_event";
  parentSessionId: string;
  sideChatId?: string;
  requestId?: string;
  clientMessageId?: string;
}

export type SideChatEventMessage =
  | (SideChatEventBase & {
      event: "opened";
      sideChatId: string;
      requestId: string;
    })
  | (SideChatEventBase & {
      event: "input_accepted";
      sideChatId: string;
      requestId: string;
      clientMessageId: string;
      queued: boolean;
    })
  | (SideChatEventBase & {
      event: "message";
      sideChatId: string;
      message: SideChatMessagePayload;
    })
  | (SideChatEventBase & {
      event: "status";
      sideChatId: string;
      status: string;
    })
  | (SideChatEventBase & {
      event: "permission_request";
      sideChatId: string;
      permission: {
        requestId: string;
        toolName: string;
        input: Record<string, unknown>;
      };
    })
  | (SideChatEventBase & {
      event: "question";
      sideChatId: string;
      question: {
        requestId: string;
        questions: Array<Record<string, unknown>>;
      };
    })
  | (SideChatEventBase & {
      event: "closed";
      sideChatId: string;
    })
  | (SideChatEventBase & {
      event: "error";
      error: {
        code?: string;
        message: string;
      };
    });

const SIDE_CHAT_CLIENT_TYPE_SET = new Set<string>(CLIENT_TYPES);

/**
 * `undefined` means this is not a side-chat message; `null` means it claimed a
 * side-chat type but failed strict validation.
 */
export function parseSideChatClientMessage(
  msg: Record<string, unknown>,
): SideChatClientMessage | null | undefined {
  if (
    typeof msg.type !== "string" ||
    !SIDE_CHAT_CLIENT_TYPE_SET.has(msg.type)
  ) {
    return undefined;
  }

  switch (msg.type) {
    case "open_side_chat":
      return hasOnlyLocalFeatureKeys(msg, [
        "type",
        "parentSessionId",
        "requestId",
      ]) &&
        validLocalFeatureId(msg.parentSessionId, 256) &&
        validLocalFeatureId(msg.requestId, 128)
        ? {
            type: msg.type,
            parentSessionId: msg.parentSessionId,
            requestId: msg.requestId,
          }
        : null;
    case "side_chat_input":
      return hasOnlyLocalFeatureKeys(msg, [
        "type",
        "parentSessionId",
        "sideChatId",
        "requestId",
        "clientMessageId",
        "text",
      ]) &&
        validLocalFeatureId(msg.parentSessionId, 256) &&
        validLocalFeatureId(msg.sideChatId, 128) &&
        validLocalFeatureId(msg.requestId, 128) &&
        validLocalFeatureId(msg.clientMessageId, 256) &&
        validLocalFeatureText(msg.text, SIDE_CHAT_TEXT_MAX_LENGTH, false)
        ? {
            type: msg.type,
            parentSessionId: msg.parentSessionId,
            sideChatId: msg.sideChatId,
            requestId: msg.requestId,
            clientMessageId: msg.clientMessageId,
            text: msg.text,
          }
        : null;
    case "side_chat_permission_response":
      return hasOnlyLocalFeatureKeys(msg, [
        "type",
        "parentSessionId",
        "sideChatId",
        "requestId",
        "permissionRequestId",
        "decision",
      ]) &&
        validLocalFeatureId(msg.parentSessionId, 256) &&
        validLocalFeatureId(msg.sideChatId, 128) &&
        validLocalFeatureId(msg.requestId, 128) &&
        validLocalFeatureId(msg.permissionRequestId, 256) &&
        (msg.decision === "allow" ||
          msg.decision === "allow_always" ||
          msg.decision === "deny")
        ? {
            type: msg.type,
            parentSessionId: msg.parentSessionId,
            sideChatId: msg.sideChatId,
            requestId: msg.requestId,
            permissionRequestId: msg.permissionRequestId,
            decision: msg.decision,
          }
        : null;
    case "side_chat_answer":
      return hasOnlyLocalFeatureKeys(msg, [
        "type",
        "parentSessionId",
        "sideChatId",
        "requestId",
        "questionRequestId",
        "answer",
      ]) &&
        validLocalFeatureId(msg.parentSessionId, 256) &&
        validLocalFeatureId(msg.sideChatId, 128) &&
        validLocalFeatureId(msg.requestId, 128) &&
        validLocalFeatureId(msg.questionRequestId, 256) &&
        validLocalFeatureText(msg.answer, SIDE_CHAT_TEXT_MAX_LENGTH, true)
        ? {
            type: msg.type,
            parentSessionId: msg.parentSessionId,
            sideChatId: msg.sideChatId,
            requestId: msg.requestId,
            questionRequestId: msg.questionRequestId,
            answer: msg.answer,
          }
        : null;
    case "side_chat_interrupt":
    case "close_side_chat":
      return hasOnlyLocalFeatureKeys(msg, [
        "type",
        "parentSessionId",
        "sideChatId",
        "requestId",
      ]) &&
        validLocalFeatureId(msg.parentSessionId, 256) &&
        validLocalFeatureId(msg.sideChatId, 128) &&
        validLocalFeatureId(msg.requestId, 128)
        ? {
            type: msg.type,
            parentSessionId: msg.parentSessionId,
            sideChatId: msg.sideChatId,
            requestId: msg.requestId,
          }
        : null;
  }
}

export const sideChatProtocolContribution: LocalFeatureProtocolContribution<
  SideChatClientMessage,
  SideChatEventMessage
> = {
  clientTypes: CLIENT_TYPES,
  serverTypes: ["side_chat_event"],
  parseClient: parseSideChatClientMessage,
};
