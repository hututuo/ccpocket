import {
  hasOnlyLocalFeatureKeys,
  validLocalFeatureId,
  validLocalFeatureText,
  type LocalFeatureProtocolContribution,
} from "../protocol-slot.js";

export const CODEX_ACTION_BROKER_CAPABILITY = "codex_action_broker_v1" as const;

export type CodexActionWireDecision =
  "approve" | "approve_always" | "reject" | "answer";

export interface CodexActionWireHealth {
  ready: boolean;
  controlReady: boolean;
  degraded: boolean;
  writerLeaseHeld: boolean;
  degradedReason?:
    | "unreadable_state"
    | "unsafe_state"
    | "generation_unavailable"
    | "writer_lease_unavailable"
    | "runtime_draining"
    | "unsupported_server_request"
    | "unsupported_topology";
  authorityGeneration?: string;
}

export interface CodexActionWireRequest {
  opaqueRequestId: string;
  codexSourceId: string;
  threadId: string;
  turnId: string;
  kind:
    | "command_approval"
    | "file_approval"
    | "permissions_approval"
    | "user_input"
    | "mcp_elicitation"
    | "tool_suggestion"
    | "current_time"
    | "unknown";
  state: "pending" | "claimed" | "resolved" | "expired";
  observedAt: string;
  expiresAt: string;
  updatedAt: string;
  authorityGeneration: string;
  live: boolean;
  payloadUnavailableReason?: "payload_too_large";
  toolName?: string;
  input?: Record<string, unknown>;
  allowedActions?: CodexActionWireDecision[];
}

export interface CodexActionBrokerSnapshotScope {
  codexSourceId: string;
  threadId: string;
}

export type CodexActionBrokerClientMessage =
  | ({
      type: "get_codex_actions";
      requestId: string;
    } & (
      | CodexActionBrokerSnapshotScope
      | { codexSourceId?: never; threadId?: never }
    ))
  | {
      type: "respond_codex_action";
      requestId: string;
      opaqueRequestId: string;
      codexSourceId: string;
      threadId: string;
      turnId: string;
      authorityGeneration: string;
      claimantId: string;
      operationId: string;
      action: CodexActionWireDecision;
      answer?: string;
    };

export type CodexActionBrokerServerMessage =
  | {
      type: typeof CODEX_ACTION_BROKER_CAPABILITY;
      event: "snapshot";
      requestId?: string;
      health: CodexActionWireHealth;
      requests: CodexActionWireRequest[];
      scope?: CodexActionBrokerSnapshotScope;
      truncated?: boolean;
    }
  | {
      type: typeof CODEX_ACTION_BROKER_CAPABILITY;
      event: "request";
      request: CodexActionWireRequest;
    }
  | {
      type: typeof CODEX_ACTION_BROKER_CAPABILITY;
      event: "health";
      health: CodexActionWireHealth;
    }
  | {
      type: typeof CODEX_ACTION_BROKER_CAPABILITY;
      event: "response";
      requestId: string;
      opaqueRequestId: string;
      outcome:
        | "submitted"
        | "outcomeUnknown"
        | "alreadyResolved"
        | "contended"
        | "expired"
        | "staleGeneration"
        | "unavailable"
        | "invalid";
      request?: CodexActionWireRequest;
      error?: string;
    };

const CLIENT_TYPES = ["get_codex_actions", "respond_codex_action"] as const;
const DECISIONS = new Set<CodexActionWireDecision>([
  "approve",
  "approve_always",
  "reject",
  "answer",
]);

export const codexActionBrokerProtocolContribution: LocalFeatureProtocolContribution<
  CodexActionBrokerClientMessage,
  CodexActionBrokerServerMessage
> = {
  clientTypes: CLIENT_TYPES,
  serverTypes: [CODEX_ACTION_BROKER_CAPABILITY],
  parseClient(message) {
    if (
      typeof message.type !== "string" ||
      !CLIENT_TYPES.includes(message.type as (typeof CLIENT_TYPES)[number])
    ) {
      return undefined;
    }
    if (!validLocalFeatureId(message.requestId, 128)) return null;
    if (message.type === "get_codex_actions") {
      if (
        !hasOnlyLocalFeatureKeys(message, [
          "type",
          "requestId",
          "codexSourceId",
          "threadId",
        ])
      ) {
        return null;
      }
      const hasSource = message.codexSourceId !== undefined;
      const hasThread = message.threadId !== undefined;
      if (hasSource !== hasThread) return null;
      if (!hasSource) {
        return { type: message.type, requestId: message.requestId };
      }
      if (
        !validLocalFeatureId(message.codexSourceId, 128) ||
        !validLocalFeatureId(message.threadId, 256)
      ) {
        return null;
      }
      return {
        type: message.type,
        requestId: message.requestId,
        codexSourceId: message.codexSourceId,
        threadId: message.threadId,
      };
    }
    if (
      !hasOnlyLocalFeatureKeys(message, [
        "type",
        "requestId",
        "opaqueRequestId",
        "codexSourceId",
        "threadId",
        "turnId",
        "authorityGeneration",
        "claimantId",
        "operationId",
        "action",
        "answer",
      ]) ||
      !validLocalFeatureId(message.opaqueRequestId, 256) ||
      !validLocalFeatureId(message.codexSourceId, 128) ||
      !validLocalFeatureId(message.threadId, 256) ||
      !validLocalFeatureId(message.turnId, 256) ||
      !validLocalFeatureId(message.authorityGeneration, 64) ||
      !validLocalFeatureId(message.claimantId, 256) ||
      !validLocalFeatureId(message.operationId, 256) ||
      !DECISIONS.has(message.action as CodexActionWireDecision)
    ) {
      return null;
    }
    const action = message.action as CodexActionWireDecision;
    if (
      (action === "answer" &&
        !validLocalFeatureText(message.answer, 64 * 1024, true)) ||
      (action !== "answer" && message.answer !== undefined)
    ) {
      return null;
    }
    return {
      type: "respond_codex_action",
      requestId: message.requestId,
      opaqueRequestId: message.opaqueRequestId,
      codexSourceId: message.codexSourceId,
      threadId: message.threadId,
      turnId: message.turnId,
      authorityGeneration: message.authorityGeneration,
      claimantId: message.claimantId,
      operationId: message.operationId,
      action,
      ...(action === "answer" ? { answer: message.answer as string } : {}),
    };
  },
};
