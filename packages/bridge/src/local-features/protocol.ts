import {
  autoApprovalProtocolContribution,
  type AutoApprovalClientMessage,
  type AutoApprovalStateMessage,
} from "./slots/auto-approval-protocol.js";
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
  type ConversationMirrorServerMessage,
} from "./slots/conversation-mirror-protocol.js";
import {
  conversationContentProtocolContribution,
  type ConversationContentClientMessage,
  type ConversationContentServerMessage,
} from "./slots/conversation-content-protocol.js";
import {
  conversationSyncV2ProtocolContribution,
  type ConversationSyncClientMessage,
  type ConversationSyncServerMessage,
} from "./slots/conversation-sync-v2-protocol.js";
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
  PERSISTED_SIDE_CHAT_CAPABILITY,
  persistedSideChatProtocolContribution,
  type OpenPersistedSideChatMessage,
  type PersistedSideChatOpenedMessage,
} from "./slots/persisted-side-chat-protocol.js";
import {
  EPHEMERAL_SIDE_CHAT_CAPABILITY,
  ephemeralSideChatProtocolContribution,
  type EphemeralSideChatClientMessage,
  type EphemeralSideChatServerMessage,
} from "./slots/ephemeral-side-chat-protocol.js";
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
  AutoApprovalClientMessage,
  AutoApprovalStateMessage,
} from "./slots/auto-approval-protocol.js";
export { AUTO_APPROVAL_STATE_CAPABILITY } from "./slots/auto-approval-protocol.js";
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
export { DURABLE_SESSION_INSIGHTS_CAPABILITY } from "./slots/session-insights-protocol.js";
export type {
  SideChatEventMessage,
  SideChatMessagePayload,
  SideChatPermissionDecision,
} from "./slots/side-chat-protocol.js";
export type {
  OpenPersistedSideChatMessage,
  PersistedSideChatOpenedMessage,
} from "./slots/persisted-side-chat-protocol.js";
export { PERSISTED_SIDE_CHAT_CAPABILITY } from "./slots/persisted-side-chat-protocol.js";
export type {
  EphemeralSideChatClientMessage,
  EphemeralSideChatEntry,
  EphemeralSideChatServerMessage,
} from "./slots/ephemeral-side-chat-protocol.js";
export { EPHEMERAL_SIDE_CHAT_CAPABILITY } from "./slots/ephemeral-side-chat-protocol.js";
export type { CodexSubagentInfo } from "./slots/subagents-protocol.js";
export type {
  ConversationMirrorClientMessage,
  ConversationMirrorEntryChunkMessage,
  ConversationMirrorEntry,
  ConversationMirrorEventMessage,
  ConversationMirrorProvider,
  ConversationMirrorServerMessage,
  ConversationMirrorThreadStatus,
} from "./slots/conversation-mirror-protocol.js";
export type {
  ConversationContentClientMessage,
  ConversationContentCursor,
  ConversationContentEntry,
  ConversationContentProvider,
  ConversationContentServerMessage,
  ConversationContentTarget,
} from "./slots/conversation-content-protocol.js";
export { CONVERSATION_CONTENT_EVENT_CAPABILITY } from "./slots/conversation-content-protocol.js";
export type {
  ConversationSyncCatalogEntry,
  ConversationSyncClientMessage,
  ConversationSyncNextState,
  ConversationSyncProvider,
  ConversationSyncReadWatermark,
  ConversationSyncServerMessage,
  ConversationSyncStatus,
  ConversationSyncTarget,
  ConversationSyncThreadState,
} from "./slots/conversation-sync-v2-protocol.js";
export {
  APP_SERVER_STATUS_CAPABILITY,
  BRIDGE_IDENTITY_V2_CAPABILITY,
  CONVERSATION_ITEMS_BY_ID_CAPABILITY,
  CONVERSATION_SYNC_V2_CAPABILITY,
} from "./slots/conversation-sync-v2-protocol.js";
export {
  CONVERSATION_MIRROR_ENTRY_CHUNK_CAPABILITY,
  CONVERSATION_MIRROR_SOURCE_IDENTITY_CAPABILITY,
} from "./slots/conversation-mirror-protocol.js";
export {
  FILE_BROWSER_CAPABILITY,
  FILE_BROWSER_DEFAULT_PAGE_SIZE,
  FILE_BROWSER_MAX_PAGE_SIZE,
  FILE_BROWSER_MAX_RELATIVE_PATH_LENGTH,
  FILE_BROWSER_MAX_ROOTS,
  FILE_BROWSER_MAX_STAT_ITEMS,
  FILE_BROWSER_PROJECT_PREVIEW_CAPABILITY,
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
  FileBrowserProjectPreviewRequest,
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
  FileMutationAuthChallengeRequest,
  FileMutationAuthEnrollRequest,
  FileMutationAuthResult,
  FileMutationAuthStateRequest,
} from "./slots/file-browser-protocol.js";

export type LocalFeatureClientMessage =
  | AutoApprovalClientMessage
  | CodexCoreActionsClientMessage
  | CodexDesktopContinuityClientMessage
  | ConversationMirrorClientMessage
  | ConversationContentClientMessage
  | ConversationSyncClientMessage
  | FileBrowserClientMessage
  | SessionInsightsClientMessage
  | SubagentsClientMessage
  | SideChatClientMessage
  | OpenPersistedSideChatMessage
  | EphemeralSideChatClientMessage;

export type LocalFeatureServerMessage =
  | AutoApprovalStateMessage
  | CodexCoreActionsServerMessage
  | CodexDesktopContinuityEventMessage
  | ConversationMirrorServerMessage
  | ConversationContentServerMessage
  | ConversationSyncServerMessage
  | FileBrowserServerMessage
  | SessionInsightsServerMessage
  | SubagentsServerMessage
  | SideChatEventMessage
  | PersistedSideChatOpenedMessage
  | EphemeralSideChatServerMessage;

const CONTRIBUTIONS: readonly LocalFeatureProtocolContribution[] = [
  autoApprovalProtocolContribution,
  codexCoreActionsProtocolContribution,
  codexDesktopContinuityProtocolContribution,
  conversationMirrorProtocolContribution,
  conversationContentProtocolContribution,
  conversationSyncV2ProtocolContribution,
  fileBrowserProtocolContribution,
  sessionInsightsProtocolContribution,
  subagentsProtocolContribution,
  sideChatProtocolContribution,
  persistedSideChatProtocolContribution,
  ephemeralSideChatProtocolContribution,
];

const LOCAL_CLIENT_TYPES = new Set<string>(
  CONTRIBUTIONS.flatMap((contribution) => contribution.clientTypes),
);
const LOCAL_SERVER_TYPES = new Set<string>(
  CONTRIBUTIONS.flatMap((contribution) => contribution.serverTypes),
);

export function isLocalFeatureServerMessage(message: {
  type: string;
}): message is LocalFeatureServerMessage {
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
