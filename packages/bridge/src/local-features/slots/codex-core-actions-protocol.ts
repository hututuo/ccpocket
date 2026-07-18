import {
  hasOnlyLocalFeatureKeys,
  validLocalFeatureId,
  validLocalFeatureText,
  type LocalFeatureProtocolContribution,
} from "../protocol-slot.js";

export const CODEX_CORE_ACTIONS_FEATURE_ID = "codex_core_actions";

export type CodexCoreAction = "compact" | "review";
export type CodexCoreActionStatus =
  | "accepted"
  | "unsupported"
  | "rejected"
  | "failed";
export type CodexMcpStatusResultStatus =
  | "completed"
  | "unsupported"
  | "failed";

export type CodexReviewRequestTarget =
  | { type: "uncommittedChanges" }
  | { type: "baseBranch"; branch: string }
  | { type: "commit"; sha: string; title: string | null }
  | { type: "custom"; instructions: string };

export type CodexCoreActionsClientMessage =
  | {
      type: "codex_compact_request";
      sessionId: string;
      requestId: string;
    }
  | {
      type: "codex_review_request";
      sessionId: string;
      requestId: string;
      target: CodexReviewRequestTarget;
    }
  | {
      type: "codex_mcp_status_request";
      sessionId: string;
      requestId: string;
    };

export interface CodexMcpToolSummary {
  name: string;
  title?: string;
  description?: string;
}

export interface CodexMcpServerInfoSummary {
  name: string;
  title?: string;
  version: string;
  description?: string;
  websiteUrl?: string;
}

export interface CodexMcpServerStatusSummary {
  name: string;
  authStatus: string;
  serverInfo?: CodexMcpServerInfoSummary;
  tools: CodexMcpToolSummary[];
  toolCount: number;
  toolsTruncated?: boolean;
}

export type CodexCoreActionsServerMessage =
  | {
      type: "codex_action_result";
      sessionId: string;
      requestId: string;
      action: CodexCoreAction;
      status: CodexCoreActionStatus;
      turnId?: string;
      reviewThreadId?: string;
      errorCode?: string;
      message?: string;
    }
  | {
      type: "codex_mcp_status_result";
      sessionId: string;
      requestId: string;
      status: CodexMcpStatusResultStatus;
      servers: CodexMcpServerStatusSummary[];
      serversTruncated?: boolean;
      errorCode?: string;
      message?: string;
    };

const CLIENT_TYPES = [
  "codex_compact_request",
  "codex_review_request",
  "codex_mcp_status_request",
] as const;

const MAX_SESSION_ID_LENGTH = 256;
const MAX_REQUEST_ID_LENGTH = 128;
const MAX_REVIEW_BRANCH_LENGTH = 1024;
const MAX_REVIEW_SHA_LENGTH = 128;
const MAX_REVIEW_TITLE_LENGTH = 1024;
const MAX_REVIEW_INSTRUCTIONS_LENGTH = 32 * 1024;

export const codexCoreActionsProtocolContribution: LocalFeatureProtocolContribution<
  CodexCoreActionsClientMessage,
  CodexCoreActionsServerMessage
> = {
  clientTypes: CLIENT_TYPES,
  serverTypes: ["codex_action_result", "codex_mcp_status_result"],
  parseClient(message) {
    if (
      typeof message.type !== "string" ||
      !CLIENT_TYPES.includes(message.type as (typeof CLIENT_TYPES)[number])
    ) {
      return undefined;
    }
    if (
      !validCorrelatedId(message.sessionId, MAX_SESSION_ID_LENGTH) ||
      !validCorrelatedId(message.requestId, MAX_REQUEST_ID_LENGTH)
    ) {
      return null;
    }

    switch (message.type) {
      case "codex_compact_request":
      case "codex_mcp_status_request":
        return hasOnlyLocalFeatureKeys(message, [
          "type",
          "sessionId",
          "requestId",
        ])
          ? {
              type: message.type,
              sessionId: message.sessionId,
              requestId: message.requestId,
            }
          : null;
      case "codex_review_request": {
        if (
          !hasOnlyLocalFeatureKeys(message, [
            "type",
            "sessionId",
            "requestId",
            "target",
          ])
        ) {
          return null;
        }
        const target = parseReviewTarget(message.target);
        return target
          ? {
              type: message.type,
              sessionId: message.sessionId,
              requestId: message.requestId,
              target,
            }
          : null;
      }
    }
  },
};

function validCorrelatedId(value: unknown, maxLength: number): value is string {
  return validLocalFeatureId(value, maxLength) && value.trim().length > 0;
}

function parseReviewTarget(value: unknown): CodexReviewRequestTarget | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const target = value as Record<string, unknown>;
  switch (target.type) {
    case "uncommittedChanges":
      return hasOnlyLocalFeatureKeys(target, ["type"])
        ? { type: target.type }
        : null;
    case "baseBranch":
      return hasOnlyLocalFeatureKeys(target, ["type", "branch"]) &&
        validLocalFeatureText(target.branch, MAX_REVIEW_BRANCH_LENGTH, false)
        ? { type: target.type, branch: target.branch }
        : null;
    case "commit": {
      if (
        !hasOnlyLocalFeatureKeys(target, ["type", "sha", "title"]) ||
        !validLocalFeatureText(target.sha, MAX_REVIEW_SHA_LENGTH, false) ||
        !validOptionalReviewTitle(target.title)
      ) {
        return null;
      }
      return {
        type: target.type,
        sha: target.sha,
        title: typeof target.title === "string" ? target.title : null,
      };
    }
    case "custom":
      return hasOnlyLocalFeatureKeys(target, ["type", "instructions"]) &&
        validLocalFeatureText(
          target.instructions,
          MAX_REVIEW_INSTRUCTIONS_LENGTH,
          false,
        )
        ? { type: target.type, instructions: target.instructions }
        : null;
    default:
      return null;
  }
}

function validOptionalReviewTitle(value: unknown): boolean {
  return (
    value === undefined ||
    value === null ||
    validLocalFeatureText(value, MAX_REVIEW_TITLE_LENGTH, true)
  );
}
