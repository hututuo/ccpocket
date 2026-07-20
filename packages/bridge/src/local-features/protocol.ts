import {
  codexCoreActionsProtocolContribution,
  type CodexCoreActionsClientMessage,
  type CodexCoreActionsServerMessage,
} from "./slots/codex-core-actions-protocol.js";
import {
  codexDesktopContinuityProtocolContribution,
  type CodexDesktopContinuityClientMessage,
  type CodexDesktopContinuityEventMessage,
} from "./slots/codex-desktop-continuity-protocol.js";
import {
  conversationMirrorProtocolContribution,
  type ConversationMirrorClientMessage,
  type ConversationMirrorEventMessage,
} from "./slots/conversation-mirror-protocol.js";
import {
  fileBrowserProtocolContribution,
  type FileBrowserClientMessage,
  type FileBrowserServerMessage,
} from "./slots/file-browser-protocol.js";
import {
  sessionInsightsProtocolContribution,
  type SessionInsightsClientMessage,
  type SessionInsightsServerMessage,
} from "./slots/session-insights-protocol.js";
import {
  sideChatProtocolContribution,
  type SideChatClientMessage,
  type SideChatEventMessage,
} from "./slots/side-chat-protocol.js";
import {
  subagentsProtocolContribution,
  type SubagentsClientMessage,
  type SubagentsServerMessage,
} from "./slots/subagents-protocol.js";
import type {
  LocalFeatureClientMessageShape,
  LocalFeatureProtocolContribution,
} from "./protocol-slot.js";

export type {
  CodexCoreAction,
  CodexCoreActionStatus,
  CodexCoreActionsClientMessage,
  CodexCoreActionsServerMessage,
  CodexMcpServerInfoSummary,
  CodexMcpServerStatusSummary,
  CodexMcpStatusResultStatus,
  CodexMcpToolSummary,
  CodexReviewRequestTarget,
} from "./slots/codex-core-actions-protocol.js";
export type {
  CodexDesktopContinuityClientMessage,
  CodexDesktopContinuityEventMessage,
  CodexDesktopContinuityOrigin,
  CodexDesktopContinuityState,
} from "./slots/codex-desktop-continuity-protocol.js";
export type {
  CodexTokenUsageBreakdown,
  ContextUsageMessage,
  SessionUsageInfoPayload,
  SessionUsageLimitCardPayload,
  SessionUsageResetCreditPayload,
  SessionUsageWindowPayload,
} from "./slots/session-insights-protocol.js";
export type {
  SideChatEventMessage,
  SideChatMessagePayload,
  SideChatPermissionDecision,
} from "./slots/side-chat-protocol.js";
export type { CodexSubagentInfo } from "./slots/subagents-protocol.js";
export type {
  ConversationMirrorClientMessage,
  ConversationMirrorEntry,
  ConversationMirrorEventMessage,
  ConversationMirrorProvider,
  ConversationMirrorThreadStatus,
} from "./slots/conversation-mirror-protocol.js";
export {
  FILE_BROWSER_CAPABILITY,
  FILE_BROWSER_DEFAULT_PAGE_SIZE,
  FILE_BROWSER_MAX_PAGE_SIZE,
  FILE_BROWSER_MAX_RELATIVE_PATH_LENGTH,
  FILE_BROWSER_MAX_ROOTS,
  FILE_BROWSER_MAX_STAT_ITEMS,
  validFileBrowserRelativePath,
} from "./slots/file-browser-protocol.js";
export type {
  FileBrowserClientMessage,
  FileBrowserDownloadRequest,
  FileBrowserDownloadResult,
  FileBrowserDownloadSuccessResult,
  FileBrowserEntry,
  FileBrowserFailureResult,
  FileBrowserListRequest,
  FileBrowserListResult,
  FileBrowserListSuccessResult,
  FileBrowserNode,
  FileBrowserNodeKind,
  FileBrowserPreviewRequest,
  FileBrowserPreviewResult,
  FileBrowserPreviewSuccessResult,
  FileBrowserRoot,
  FileBrowserRootsRequest,
  FileBrowserRootsResult,
  FileBrowserRootsSuccessResult,
  FileBrowserServerMessage,
  FileBrowserStatRequest,
  FileBrowserStatRequestItem,
  FileBrowserStatResult,
  FileBrowserStatResultItem,
  FileBrowserStatSuccessResult,
} from "./slots/file-browser-protocol.js";

export type LocalFeatureClientMessage =
  | CodexCoreActionsClientMessage
  | CodexDesktopContinuityClientMessage
  | ConversationMirrorClientMessage
  | FileBrowserClientMessage
  | SessionInsightsClientMessage
  | SubagentsClientMessage
  | SideChatClientMessage;

export type LocalFeatureServerMessage =
  | CodexCoreActionsServerMessage
  | CodexDesktopContinuityEventMessage
  | ConversationMirrorEventMessage
  | FileBrowserServerMessage
  | SessionInsightsServerMessage
  | SubagentsServerMessage
  | SideChatEventMessage;

const CONTRIBUTIONS: readonly LocalFeatureProtocolContribution[] = [
  codexCoreActionsProtocolContribution,
  codexDesktopContinuityProtocolContribution,
  conversationMirrorProtocolContribution,
  fileBrowserProtocolContribution,
  sessionInsightsProtocolContribution,
  subagentsProtocolContribution,
  sideChatProtocolContribution,
];

const LOCAL_CLIENT_TYPES = new Set<string>(
  CONTRIBUTIONS.flatMap((contribution) => contribution.clientTypes),
);
const LOCAL_SERVER_TYPES = new Set<string>(
  CONTRIBUTIONS.flatMap((contribution) => contribution.serverTypes),
);

export function isLocalFeatureServerMessage(
  message: { type: string },
): message is LocalFeatureServerMessage {
  return isLocalFeatureServerMessageType(message.type);
}

export function isLocalFeatureServerMessageType(type: string): boolean {
  return LOCAL_SERVER_TYPES.has(type);
}

/**
 * `undefined` means this is not a local-feature message; `null` means a slot
 * recognized its type but rejected the payload.
 */
export function parseLocalFeatureClientMessage(
  message: Record<string, unknown>,
): LocalFeatureClientMessage | null | undefined {
  for (const contribution of CONTRIBUTIONS) {
    const parsed = contribution.parseClient(message);
    if (parsed !== undefined) {
      return parsed as LocalFeatureClientMessage | null;
    }
  }
  return undefined;
}

export function isLocalFeatureClientMessage(
  message: LocalFeatureClientMessageShape,
): message is LocalFeatureClientMessage {
  return LOCAL_CLIENT_TYPES.has(message.type);
}
