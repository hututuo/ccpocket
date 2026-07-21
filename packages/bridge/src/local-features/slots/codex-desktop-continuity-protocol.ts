import type { ServerMessage } from "../../parser.js";
import {
  hasOnlyLocalFeatureKeys,
  validLocalFeatureId,
  validLocalFeatureText,
  type LocalFeatureProtocolContribution,
} from "../protocol-slot.js";

interface CodexDesktopContinuityRequestBase {
  /** Breaking wire changes must use version 2 request/event type names. */
  protocolVersion: 1;
  requestId: string;
  sessionId: string;
  threadId: string;
}

export type CodexDesktopContinuityClientMessage =
  | (CodexDesktopContinuityRequestBase & {
      type: "codex_desktop_continuity_watch";
      projectPath: string;
    })
  | (CodexDesktopContinuityRequestBase & {
      type: "codex_desktop_continuity_unwatch";
    });

export type CodexDesktopContinuityState = "idle" | "running" | "unknown";
export type CodexDesktopContinuityOrigin = "desktop_rollout";

interface CodexDesktopContinuityEventBase {
  type: "codex_desktop_continuity_event_v1";
  requestId: string;
  bridgeInstanceId: string;
  sessionId: string;
  threadId: string;
  origin: CodexDesktopContinuityOrigin;
}

export type CodexDesktopContinuityEventMessage =
  | (CodexDesktopContinuityEventBase & {
      event: "watching";
      state: CodexDesktopContinuityState;
      turnId?: string;
      /** Queue state used when reconnecting after an external turn ended. */
      handoffQueued?: boolean;
    })
  | (CodexDesktopContinuityEventBase & {
      event: "state";
      state: "idle" | "running";
      turnId?: string;
      outcome?: "completed" | "interrupted";
      /** Canonical runtime history now includes the completed Desktop turn. */
      historyReady?: boolean;
      /** A queued mobile input is being handed to a freshly resumed runtime. */
      handoffQueued?: boolean;
      timestamp?: string;
    })
  | (CodexDesktopContinuityEventBase & {
      event: "message";
      itemKey: string;
      turnId?: string;
      timestamp?: string;
      /** A normal ccPocket message, rendered through the existing chat path. */
      message: ServerMessage;
    })
  | (CodexDesktopContinuityEventBase & {
      event: "unwatched";
    })
  | (CodexDesktopContinuityEventBase & {
      event: "error";
      errorCode: string;
      error: string;
    });

const CLIENT_TYPES = [
  "codex_desktop_continuity_watch",
  "codex_desktop_continuity_unwatch",
] as const;

export const codexDesktopContinuityProtocolContribution: LocalFeatureProtocolContribution<
  CodexDesktopContinuityClientMessage,
  CodexDesktopContinuityEventMessage
> = {
  clientTypes: CLIENT_TYPES,
  serverTypes: ["codex_desktop_continuity_event_v1"],
  parseClient(message) {
    if (
      typeof message.type !== "string" ||
      !CLIENT_TYPES.includes(message.type as (typeof CLIENT_TYPES)[number])
    ) {
      return undefined;
    }
    if (
      message.protocolVersion !== 1 ||
      !validLocalFeatureId(message.requestId, 128) ||
      !validLocalFeatureId(message.sessionId, 256) ||
      !validLocalFeatureId(message.threadId, 256)
    ) {
      return null;
    }
    const requestId = message.requestId;
    const sessionId = message.sessionId;
    const threadId = message.threadId;

    if (message.type === "codex_desktop_continuity_unwatch") {
      return hasOnlyLocalFeatureKeys(message, [
        "type",
        "protocolVersion",
        "requestId",
        "sessionId",
        "threadId",
      ])
        ? {
            type: message.type,
            protocolVersion: 1,
            requestId,
            sessionId,
            threadId,
          }
        : null;
    }

    if (
      !hasOnlyLocalFeatureKeys(message, [
        "type",
        "protocolVersion",
        "requestId",
        "sessionId",
        "threadId",
        "projectPath",
      ]) ||
      !validLocalFeatureText(message.projectPath, 4096, false)
    ) {
      return null;
    }
    return {
      type: "codex_desktop_continuity_watch",
      protocolVersion: 1,
      requestId,
      sessionId,
      threadId,
      projectPath: message.projectPath,
    } satisfies CodexDesktopContinuityClientMessage;
  },
};
