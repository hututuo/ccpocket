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

export type SubagentsClientMessage =
  | { type: "get_subagents"; sessionId: string; requestId: string }
  | {
      type: "get_subagent_history";
      sessionId: string;
      threadId: string;
      requestId: string;
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
    };

const CLIENT_TYPES = ["get_subagents", "get_subagent_history"] as const;

export const subagentsProtocolContribution: LocalFeatureProtocolContribution<
  SubagentsClientMessage,
  SubagentsServerMessage
> = {
  clientTypes: CLIENT_TYPES,
  serverTypes: ["subagent_list", "subagent_history"],
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
    }
  },
};
