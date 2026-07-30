import {
  hasOnlyLocalFeatureKeys,
  validLocalFeatureId,
  type LocalFeatureProtocolContribution,
} from "../protocol-slot.js";

export const DURABLE_SESSION_INSIGHTS_CAPABILITY =
  "durable_session_insights_v1" as const;

export interface CodexTokenUsageBreakdown {
  totalTokens: number;
  inputTokens: number;
  cachedInputTokens: number;
  cacheWriteInputTokens: number;
  outputTokens: number;
  reasoningOutputTokens: number;
}

export interface ContextUsageMessage {
  type: "context_usage";
  sessionId?: string;
  turnId?: string;
  last: CodexTokenUsageBreakdown;
  total: CodexTokenUsageBreakdown;
  modelContextWindow: number | null;
}

export type ContextUsageResultMessage = Omit<
  ContextUsageMessage,
  "type" | "sessionId"
> & {
  type: "context_usage_result";
  sessionId: string;
  requestId?: string;
};

export interface ContextUsageErrorMessage {
  type: "context_usage_error";
  sessionId: string;
  requestId?: string;
  errorCode: string;
  message: string;
}

export interface SessionUsageWindowPayload {
  utilization: number;
  windowDurationMins?: number;
  resetsAt?: string;
}

export interface SessionUsageLimitCardPayload {
  id: string;
  name?: string;
  limitName?: string;
  planType?: string;
  fiveHour: SessionUsageWindowPayload | null;
  sevenDay: SessionUsageWindowPayload | null;
  rateLimitReachedType?: string;
  spendControlReached?: boolean;
  individualLimit?: {
    limit: string;
    used: string;
    remainingPercent: number;
    resetsAt?: string;
  };
}

export interface SessionUsageResetCreditPayload {
  id: string;
  resetType: string;
  status: string;
  grantedAt?: string;
  expiresAt?: string | null;
  title?: string;
  description?: string;
}

export interface SessionUsageInfoPayload {
  provider: "claude" | "codex";
  fiveHour: SessionUsageWindowPayload | null;
  sevenDay: SessionUsageWindowPayload | null;
  limitCards?: SessionUsageLimitCardPayload[];
  resetCredits?: {
    availableCount: number;
    credits?: SessionUsageResetCreditPayload[];
  };
  source?: "app_server" | "session_log";
  error?: string;
}

export type SessionInsightsClientMessage =
  | { type: "get_context_usage"; sessionId: string; requestId?: string }
  | { type: "get_session_usage"; sessionId: string; requestId: string };

export type SessionInsightsServerMessage =
  | ContextUsageMessage
  | ContextUsageResultMessage
  | ContextUsageErrorMessage
  | {
      type: "session_usage_result";
      providers: SessionUsageInfoPayload[];
      sessionId: string;
      requestId: string;
      error?: string;
    };

const CLIENT_TYPES = ["get_context_usage", "get_session_usage"] as const;

export const sessionInsightsProtocolContribution: LocalFeatureProtocolContribution<
  SessionInsightsClientMessage,
  SessionInsightsServerMessage
> = {
  clientTypes: CLIENT_TYPES,
  serverTypes: [
    "context_usage",
    "context_usage_result",
    "context_usage_error",
    "session_usage_result",
  ],
  parseClient(message) {
    if (
      typeof message.type !== "string" ||
      !CLIENT_TYPES.includes(message.type as (typeof CLIENT_TYPES)[number])
    ) {
      return undefined;
    }

    switch (message.type) {
      case "get_context_usage": {
        const requestId = message.requestId;
        return hasOnlyLocalFeatureKeys(message, [
          "type",
          "sessionId",
          "requestId",
        ]) &&
          validLocalFeatureId(message.sessionId, 256) &&
          (requestId === undefined || validLocalFeatureId(requestId, 128))
          ? {
              type: message.type,
              sessionId: message.sessionId,
              ...(requestId === undefined ? {} : { requestId }),
            }
          : null;
      }
      case "get_session_usage":
        return hasOnlyLocalFeatureKeys(message, [
          "type",
          "sessionId",
          "requestId",
        ]) &&
          validLocalFeatureId(message.sessionId, 256) &&
          validLocalFeatureId(message.requestId, 128)
          ? {
              type: message.type,
              sessionId: message.sessionId,
              requestId: message.requestId,
            }
          : null;
    }
  },
};
