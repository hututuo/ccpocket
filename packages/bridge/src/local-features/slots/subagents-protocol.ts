import type { ServerMessage } from "../../parser.js";
import {
  hasOnlyLocalFeatureKeys,
  validLocalFeatureId,
  type LocalFeatureProtocolContribution,
} from "../protocol-slot.js";

export interface CodexSubagentInfo {
  id: string;
  sessionId: string | null;
  parentThreadId: string | null;
  forkedFromId: string | null;
  preview: string;
  createdAt: number;
  updatedAt: number;
  cwd: string;
  status: string;
  activeFlags: string[];
  source: string | null;
  threadSource: string | null;
  agentNickname: string | null;
  agentRole: string | null;
  agentPath: string | null;
  gitBranch: string | null;
  name: string | null;
  ephemeral: boolean;
}

export const DETACHED_SUBAGENTS_READ_CAPABILITY = "detached_subagents_read_v1";

export const SUBAGENT_ACTIVITY_SUMMARY_MESSAGE =
  "subagent_activity_summary_v1" as const;

export type SubagentActivityScope = "runtime" | "provider";

export type SubagentsClientMessage =
  | { type: "get_subagents"; sessionId: string; requestId: string }
  | {
      type: "get_subagent_history";
      sessionId: string;
      threadId: string;
      requestId: string;
    }
  | {
      type: "get_detached_subagents";
      ownerSessionId: string;
      providerThreadId: string;
      codexSourceId: string;
      requestId: string;
    }
  | {
      type: "get_detached_subagent_history";
      ownerSessionId: string;
      providerThreadId: string;
      codexSourceId: string;
      threadId: string;
      requestId: string;
    }
  | {
      type: "watch_subagent_activity_v1";
      sessionId: string;
      listRequestId: string;
      subscriptionId: string;
    }
  | {
      type: "watch_detached_subagent_activity_v1";
      ownerSessionId: string;
      providerThreadId: string;
      codexSourceId: string;
      listRequestId: string;
      subscriptionId: string;
    }
  | {
      type: "unwatch_subagent_activity_v1";
      subscriptionId: string;
    };

export type SubagentsServerMessage =
  | {
      type: "subagent_list";
      sessionId: string;
      requestId: string;
      subagents: CodexSubagentInfo[];
      truncated?: boolean;
      error?: string;
    }
  | {
      type: "subagent_history";
      sessionId: string;
      requestId: string;
      threadId: string;
      subagent?: CodexSubagentInfo;
      messages: ServerMessage[];
      truncated?: boolean;
      error?: string;
    }
  | {
      type: "detached_subagent_list";
      ownerSessionId: string;
      providerThreadId: string;
      codexSourceId?: string;
      requestId: string;
      subagents: CodexSubagentInfo[];
      truncated?: boolean;
      error?: string;
      errorCode?: string;
    }
  | {
      type: "detached_subagent_history";
      ownerSessionId: string;
      providerThreadId: string;
      codexSourceId?: string;
      requestId: string;
      threadId: string;
      subagent?: CodexSubagentInfo;
      messages: ServerMessage[];
      truncated?: boolean;
      error?: string;
      errorCode?: string;
    }
  | {
      type: typeof SUBAGENT_ACTIVITY_SUMMARY_MESSAGE;
      scope: SubagentActivityScope;
      ownerSessionId: string;
      providerThreadId: string;
      codexSourceId?: string;
      revision: string;
      activeCount: number;
      totalCount: number;
      truncated?: boolean;
      subscribed: boolean;
      listRequestId?: string;
      subscriptionId?: string;
    };

const CLIENT_TYPES = [
  "get_subagents",
  "get_subagent_history",
  "get_detached_subagents",
  "get_detached_subagent_history",
  "watch_subagent_activity_v1",
  "watch_detached_subagent_activity_v1",
  "unwatch_subagent_activity_v1",
] as const;

export const subagentsProtocolContribution: LocalFeatureProtocolContribution<
  SubagentsClientMessage,
  SubagentsServerMessage
> = {
  clientTypes: CLIENT_TYPES,
  serverTypes: [
    "subagent_list",
    "subagent_history",
    "detached_subagent_list",
    "detached_subagent_history",
    SUBAGENT_ACTIVITY_SUMMARY_MESSAGE,
  ],
  parseClient(message) {
    if (
      typeof message.type !== "string" ||
      !CLIENT_TYPES.includes(message.type as (typeof CLIENT_TYPES)[number])
    ) {
      return undefined;
    }

    switch (message.type) {
      case "get_subagents":
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
      case "get_subagent_history":
        return hasOnlyLocalFeatureKeys(message, [
          "type",
          "sessionId",
          "threadId",
          "requestId",
        ]) &&
          validLocalFeatureId(message.sessionId, 256) &&
          validLocalFeatureId(message.threadId, 256) &&
          validLocalFeatureId(message.requestId, 128)
          ? {
              type: message.type,
              sessionId: message.sessionId,
              threadId: message.threadId,
              requestId: message.requestId,
            }
          : null;
      case "get_detached_subagents":
        return hasOnlyLocalFeatureKeys(message, [
          "type",
          "ownerSessionId",
          "providerThreadId",
          "codexSourceId",
          "requestId",
        ]) &&
          validLocalFeatureId(message.ownerSessionId, 256) &&
          validLocalFeatureId(message.providerThreadId, 256) &&
          validLocalFeatureId(message.codexSourceId, 256) &&
          validLocalFeatureId(message.requestId, 128)
          ? {
              type: message.type,
              ownerSessionId: message.ownerSessionId,
              providerThreadId: message.providerThreadId,
              codexSourceId: message.codexSourceId,
              requestId: message.requestId,
            }
          : null;
      case "get_detached_subagent_history":
        return hasOnlyLocalFeatureKeys(message, [
          "type",
          "ownerSessionId",
          "providerThreadId",
          "codexSourceId",
          "threadId",
          "requestId",
        ]) &&
          validLocalFeatureId(message.ownerSessionId, 256) &&
          validLocalFeatureId(message.providerThreadId, 256) &&
          validLocalFeatureId(message.codexSourceId, 256) &&
          validLocalFeatureId(message.threadId, 256) &&
          validLocalFeatureId(message.requestId, 128)
          ? {
              type: message.type,
              ownerSessionId: message.ownerSessionId,
              providerThreadId: message.providerThreadId,
              codexSourceId: message.codexSourceId,
              threadId: message.threadId,
              requestId: message.requestId,
            }
          : null;
      case "watch_subagent_activity_v1":
        return hasOnlyLocalFeatureKeys(message, [
          "type",
          "sessionId",
          "listRequestId",
          "subscriptionId",
        ]) &&
          validLocalFeatureId(message.sessionId, 256) &&
          validLocalFeatureId(message.listRequestId, 128) &&
          validLocalFeatureId(message.subscriptionId, 128)
          ? {
              type: message.type,
              sessionId: message.sessionId,
              listRequestId: message.listRequestId,
              subscriptionId: message.subscriptionId,
            }
          : null;
      case "watch_detached_subagent_activity_v1":
        return hasOnlyLocalFeatureKeys(message, [
          "type",
          "ownerSessionId",
          "providerThreadId",
          "codexSourceId",
          "listRequestId",
          "subscriptionId",
        ]) &&
          validLocalFeatureId(message.ownerSessionId, 256) &&
          validLocalFeatureId(message.providerThreadId, 256) &&
          validLocalFeatureId(message.codexSourceId, 256) &&
          validLocalFeatureId(message.listRequestId, 128) &&
          validLocalFeatureId(message.subscriptionId, 128)
          ? {
              type: message.type,
              ownerSessionId: message.ownerSessionId,
              providerThreadId: message.providerThreadId,
              codexSourceId: message.codexSourceId,
              listRequestId: message.listRequestId,
              subscriptionId: message.subscriptionId,
            }
          : null;
      case "unwatch_subagent_activity_v1":
        return hasOnlyLocalFeatureKeys(message, ["type", "subscriptionId"]) &&
          validLocalFeatureId(message.subscriptionId, 128)
          ? {
              type: message.type,
              subscriptionId: message.subscriptionId,
            }
          : null;
    }
  },
};
