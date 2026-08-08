import type { GalleryImageInfo } from "./gallery-store.js";
import type { ImageRef } from "./image-store.js";
import type { ArtifactCandidate, ArtifactRef } from "./artifact-types.js";
import type {
  PromptHistoryEntry,
  PromptHistoryImportEntry,
} from "./prompt-history-store.js";
import type { WindowInfo } from "./screenshot.js";
import type { WorktreeInfo } from "./worktree.js";
import {
  parseLocalFeatureClientMessage,
  type LocalFeatureClientMessage,
  type LocalFeatureServerMessage,
} from "./local-features/protocol.js";
import {
  parseFileTransferClientMessage,
  type FileTransferClientMessage,
  type FileTransferServerMessage,
} from "./file-transfer-protocol.js";
import {
  parseBackgroundDeliveryClientMessage,
  type BackgroundDeliveryClientMessage,
  type BackgroundDeliveryServerMessage,
} from "./background-delivery-protocol.js";
import type { PushRegistrationStateMessage } from "./push-registration-protocol.js";

export type {
  CodexSubagentInfo,
  CodexTokenUsageBreakdown,
  ContextUsageMessage,
  SessionUsageInfoPayload,
  SessionUsageLimitCardPayload,
  SessionUsageResetCreditPayload,
  SessionUsageWindowPayload,
} from "./local-features/protocol.js";

// Re-export for convenience
export type { ImageRef } from "./image-store.js";

// ---- Assistant message content types (used by ServerMessage and session.ts) ----

export interface AssistantTextContent {
  type: "text";
  text: string;
}

export interface AssistantToolUseContent {
  type: "tool_use";
  id: string;
  name: string;
  input: Record<string, unknown>;
}

export interface AssistantThinkingContent {
  type: "thinking";
  thinking: string;
}

export interface HistoryToolDetailGap {
  gapId: string;
  toolUseIds: string[];
  toolNames: string[];
  toolCallCount: number;
  /**
   * Additive provider turn identity for detached, read-only detail paging.
   * Older clients ignore it; the Bridge never needs to resume the thread.
   */
  turnId?: string;
}

export interface HistoryToolDetailPayload {
  toolUseId: string;
  toolName: string;
  input: Record<string, unknown>;
  result?: {
    content: string;
    toolName?: string;
    images?: ImageRef[];
    artifacts?: ArtifactRef[];
  };
}

export type AssistantContent =
  AssistantTextContent | AssistantToolUseContent | AssistantThinkingContent;

/** Shape of the assistant message object within ServerMessage. */
export interface AssistantMessage {
  id: string;
  role: "assistant";
  content: AssistantContent[];
  model: string;
}

// ---- Client <-> Server message types ----

export type PermissionMode =
  "default" | "auto" | "acceptEdits" | "bypassPermissions" | "plan";

export type ExecutionMode = "default" | "acceptEdits" | "fullAccess";
export type CodexApprovalPolicy =
  "untrusted" | "on-request" | "on-failure" | "never";
export type CodexApprovalsReviewer =
  "user" | "auto_review" | "guardian_subagent";
export type CodexPermissionsMode =
  "default" | "autoReview" | "fullAccess" | "custom";

/**
 * Target for a detached Codex settings write.
 *
 * Every field is optional at the union level so old clients remain wire
 * compatible. The parser accepts one of three complete shapes: no envelope
 * (private/legacy), all five exact attachment fields with
 * `sessionId === runtimeSessionId`, or a durable thread target carrying source,
 * thread and idempotency identities but no transient runtime fields.
 */
export interface CodexSettingsMutationEnvelope {
  settingsTarget?: "durable_thread";
  codexSourceId?: string;
  threadId?: string;
  runtimeSessionId?: string;
  authorityGeneration?: string;
  operationId?: string;
}

export type Provider = "claude" | "codex";

export type SessionLinkProgressOperation = "resolve" | "resume";

export type SessionLinkProgressStage =
  | "request_accepted"
  | "runtime_checked"
  | "catalog_scanning"
  | "catalog_scanned"
  | "resolution_ready"
  | "resume_lock_waiting"
  | "resume_lock_acquired"
  | "history_reading"
  | "history_read"
  | "runtime_starting"
  | "metadata_loading"
  | "ready";

export type GuardianReviewRisk =
  "unknown" | "low" | "medium" | "high" | "critical";

export type GuardianReviewStatus =
  "approved" | "denied" | "timedOut" | "aborted";

export interface GuardianReviewDetails {
  status: GuardianReviewStatus;
  risk: GuardianReviewRisk;
  reason: string;
  authorization?: string;
  reviewId?: string;
  targetItemId?: string;
  action?: Record<string, unknown>;
}

export type CodexGoalWritableStatus =
  | "active"
  | "paused"
  | "blocked"
  | "usageLimited"
  | "budgetLimited"
  | "complete";

/** App-server may add read-only Goal states before this Bridge is updated. */
export type CodexGoalStatus = string;

export interface CodexGoal {
  threadId: string;
  objective: string;
  status: CodexGoalStatus;
  tokenBudget: number | null;
  tokensUsed: number;
  timeUsedSeconds: number;
  createdAt: number;
  updatedAt: number;
}

export interface QueuedInputItem {
  itemId: string;
  text: string;
  createdAt: string;
  updatedAt?: string;
  /** Additive id used to correlate the queue with staged input receipts. */
  clientMessageId?: string;
  /** Monotonic delivery fact; absent on legacy Bridges. */
  deliveryStage?: "bridge_accepted" | "provider_accepted" | "provider_rejected";
  deliveryError?: string;
  imageCount?: number;
  skills?: Array<{ name: string; path: string }>;
  mentions?: Array<{ name: string; path: string }>;
}

/** Diagnostic-only metadata for the native host installed under Dart OTA code. */
export interface MobileRuntimeCapabilities {
  baseVersion?: string;
  buildNumber?: string;
  patchNumber?: number;
  hostSchemaVersion: number;
  nativeCapabilities: Record<string, number>;
}

/**
 * Hunk reference sent by git hunk operations. `fingerprint` (additive,
 * newer clients only) content-addresses the hunk as displayed; when present
 * the Bridge locates the hunk by content instead of the legacy positional
 * `hunkIndex`, whose numbering differs between context levels.
 */
export interface ClientHunkRef {
  file: string;
  hunkIndex: number;
  fingerprint?: {
    oldStart: number;
    oldLines: number;
    newStart: number;
    newLines: number;
    changesHash: string;
  };
}

export type ClientMessage =
  | BackgroundDeliveryClientMessage
  | {
      type: "client_capabilities";
      appVersion?: string;
      protocolVersion?: number;
      supportedServerMessages?: string[];
      mobileRuntime?: MobileRuntimeCapabilities;
    }
  | {
      type: "start";
      projectPath: string;
      provider?: Provider;
      sessionId?: string;
      continue?: boolean;
      permissionMode?: PermissionMode;
      executionMode?: ExecutionMode;
      approvalPolicy?: CodexApprovalPolicy;
      approvalsReviewer?: CodexApprovalsReviewer;
      codexPermissionsMode?: CodexPermissionsMode;
      planMode?: boolean;
      sandboxMode?: string;
      model?: string;
      effort?: "low" | "medium" | "high" | "xhigh" | "max";
      maxTurns?: number;
      maxBudgetUsd?: number;
      fallbackModel?: string;
      forkSession?: boolean;
      persistSession?: boolean;
      profile?: string;
      modelReasoningEffort?: string;
      serviceTier?: string;
      networkAccessEnabled?: boolean;
      webSearchMode?: string;
      additionalWritableRoots?: string[];
      useWorktree?: boolean;
      worktreeBranch?: string;
      existingWorktreePath?: string;
      autoRename?: boolean;
      startRequestId?: string;
    }
  | {
      type: "input";
      text: string;
      sessionId?: string;
      clientMessageId?: string;
      baseSeq?: number;
      images?: Array<{ base64: string; mimeType: string }>;
      imageId?: string;
      imageBase64?: string;
      mimeType?: string;
      skill?: { name: string; path: string };
      skills?: Array<{ name: string; path: string }>;
      mentions?: Array<{ name: string; path: string }>;
    }
  | {
      type: "update_queued_input";
      sessionId: string;
      itemId: string;
      text: string;
      skills?: Array<{ name: string; path: string }>;
      mentions?: Array<{ name: string; path: string }>;
    }
  | {
      type: "steer_queued_input";
      sessionId: string;
      itemId: string;
      expectedTurnId?: string;
      codexSourceId?: string;
      threadId?: string;
      authorityGeneration?: string;
    }
  | { type: "cancel_queued_input"; sessionId: string; itemId: string }
  | {
      type: "push_register";
      token: string;
      platform: "ios" | "android" | "web";
      requestId?: string;
      locale?: string;
      privacyMode?: boolean;
      enabledEventTypes?: string[];
      approvalActionsSupported?: boolean;
      approvalActionsVersion?: 1 | 2;
    }
  | { type: "push_unregister"; token: string; requestId?: string }
  | ({
      type: "set_permission_mode";
      mode: PermissionMode;
      applyStrategy?: "next_turn" | "restart_now";
      permissionChangeId?: string;
      executionMode?: ExecutionMode;
      approvalPolicy?: CodexApprovalPolicy;
      approvalsReviewer?: CodexApprovalsReviewer;
      codexPermissionsMode?: CodexPermissionsMode;
      planMode?: boolean;
      sessionId?: string;
    } & CodexSettingsMutationEnvelope)
  | ({
      type: "set_codex_model";
      model: string;
      modelReasoningEffort?: string;
      sessionId?: string;
    } & CodexSettingsMutationEnvelope)
  | ({
      type: "set_codex_speed";
      serviceTier: string;
      sessionId?: string;
    } & CodexSettingsMutationEnvelope)
  | { type: "get_goal"; sessionId: string }
  | {
      type: "set_goal";
      sessionId: string;
      objective?: string;
      status?: CodexGoalWritableStatus;
      tokenBudget?: number | null;
      goalChangeId?: string;
      expectedGoalOperationSequence?: number;
    }
  | {
      type: "clear_goal";
      sessionId: string;
      goalChangeId?: string;
      expectedGoalOperationSequence?: number;
    }
  | ({
      type: "set_sandbox_mode";
      sandboxMode: string;
      sessionId?: string;
    } & CodexSettingsMutationEnvelope)
  | {
      type: "approve";
      id: string;
      clearContext?: boolean;
      sessionId?: string;
    }
  | { type: "approve_always"; id: string; sessionId?: string }
  | { type: "reject"; id: string; message?: string; sessionId?: string }
  | { type: "answer"; toolUseId: string; result: string; sessionId?: string }
  | { type: "install_tool_suggestion"; toolUseId: string; sessionId?: string }
  | { type: "list_sessions" }
  | { type: "stop_session"; sessionId: string }
  | {
      type: "detach_session";
      sessionId: string;
      codexSourceId: string;
      threadId: string;
      authorityGeneration: string;
    }
  | {
      type: "rename_session";
      sessionId: string;
      name?: string;
      provider?: string;
      providerSessionId?: string;
      projectPath?: string;
      codexSourceId?: string;
    }
  | { type: "get_history"; sessionId: string }
  | { type: "get_history_delta"; sessionId: string; sinceSeq: number }
  | {
      type: "get_history_page";
      requestId: string;
      sessionId: string;
      beforeSeq: number;
      beforeCursor?: string;
    }
  | {
      type: "get_history_tool_details";
      requestId: string;
      sessionId: string;
      toolUseIds: string[];
      historyTurnId?: string;
    }
  | {
      type: "resolve_artifact";
      requestId: string;
      sessionId: string;
      messageId: string;
      artifactId: string;
    }
  | {
      type: "resolve_session_link";
      requestId: string;
      sessionId: string;
      provider?: Provider;
      /** Additive request generation echoed by progress-aware Bridges. */
      sessionLinkGeneration?: number;
    }
  | {
      type: "list_recent_sessions";
      limit?: number;
      offset?: number;
      projectPath?: string;
      requestScope?: "list" | "append" | "project" | "catalog";
      requestId?: string;
      queryGeneration?: number;
      provider?: "claude" | "codex";
      namedOnly?: boolean;
      searchQuery?: string;
    }
  | {
      type: "resume_session";
      sessionId: string;
      projectPath: string;
      permissionMode?: PermissionMode;
      executionMode?: ExecutionMode;
      approvalPolicy?: CodexApprovalPolicy;
      approvalsReviewer?: CodexApprovalsReviewer;
      codexPermissionsMode?: CodexPermissionsMode;
      planMode?: boolean;
      provider?: Provider;
      sandboxMode?: string;
      model?: string;
      effort?: "low" | "medium" | "high" | "xhigh" | "max";
      maxTurns?: number;
      maxBudgetUsd?: number;
      fallbackModel?: string;
      forkSession?: boolean;
      persistSession?: boolean;
      profile?: string;
      modelReasoningEffort?: string;
      serviceTier?: string;
      networkAccessEnabled?: boolean;
      webSearchMode?: string;
      additionalWritableRoots?: string[];
      resumeRequestId?: string;
      codexSourceId?: string;
      /** Additive request generation echoed by progress-aware Bridges. */
      sessionLinkGeneration?: number;
    }
  | { type: "list_gallery"; project?: string; sessionId?: string }
  | {
      type: "read_file";
      requestId?: string;
      projectPath: string;
      filePath: string;
      maxLines?: number;
    }
  | {
      type: "read_artifact_source";
      requestId: string;
      sessionId: string;
      messageId: string;
      artifactId: string;
      /** Safe project-relative path from ArtifactRef, never an absolute path. */
      filePath: string;
      maxLines?: number;
    }
  | { type: "list_files"; projectPath: string; requestId?: string }
  | {
      type: "get_diff";
      projectPath: string;
      staged?: boolean;
      /** Echoed back in diff_result so clients can match responses. */
      requestId?: string;
    }
  | {
      type: "get_diff_image";
      projectPath: string;
      filePath: string;
      version: "old" | "new" | "both";
      /** Echoed back in diff_image_result so clients can match responses. */
      requestId?: string;
    }
  | { type: "interrupt"; sessionId?: string }
  | { type: "list_project_history" }
  | { type: "remove_project_history"; projectPath: string }
  | { type: "list_worktrees"; projectPath: string }
  | { type: "remove_worktree"; projectPath: string; worktreePath: string }
  | {
      type: "rewind";
      sessionId: string;
      targetUuid: string;
      mode: "conversation" | "code" | "both";
    }
  | { type: "rewind_dry_run"; sessionId: string; targetUuid: string }
  | {
      type: "fork";
      /** Bridge runtime id, or a durable Codex thread id with projectPath. */
      sessionId: string;
      targetUuid: string;
      /** Present only when forking a persisted conversation from the list. */
      projectPath?: string;
      codexSourceId?: string;
    }
  | { type: "list_windows" }
  | {
      type: "take_screenshot";
      mode: "fullscreen" | "window";
      windowId?: number;
      projectPath: string;
      sessionId?: string;
    }
  | {
      type: "get_debug_bundle";
      sessionId: string;
      traceLimit?: number;
      includeDiff?: boolean;
    }
  | { type: "get_usage" }
  | { type: "list_recordings" }
  | { type: "get_recording"; sessionId: string }
  | { type: "get_message_images"; claudeSessionId: string; messageUuid: string }
  | {
      type: "backup_prompt_history";
      data: string;
      appVersion: string;
      dbVersion: number;
    }
  | { type: "restore_prompt_history" }
  | { type: "get_prompt_history_backup_info" }
  | {
      type: "record_prompt_history";
      text: string;
      projectPath?: string;
      clientId: string;
      clientName?: string;
      sessionId?: string;
      usedAt?: string;
    }
  | {
      type: "sync_prompt_history";
      requestId?: string;
      clientId: string;
      clientName?: string;
      sinceRevision?: number;
      entries?: PromptHistoryImportEntry[];
      includeDeleted?: boolean;
    }
  | {
      type: "mutate_prompt_history";
      id?: string;
      text?: string;
      projectPath?: string;
      action: "favorite" | "delete" | "restore";
      isFavorite?: boolean;
      updatedAt?: string;
    }
  | {
      type: "import_prompt_history_v1";
      requestId?: string;
      clientId: string;
      clientName?: string;
      entries: PromptHistoryImportEntry[];
    }
  | {
      type: "archive_session";
      sessionId: string;
      provider: Provider;
      projectPath: string;
      requestId?: string;
      name?: string;
      summary?: string;
      firstPrompt?: string;
      modified?: string;
      codexSourceId?: string;
    }
  | { type: "list_archived_sessions"; requestId: string }
  | {
      type: "unarchive_session";
      requestId: string;
      sessionId: string;
      provider: Provider;
      projectPath: string;
      codexSourceId?: string;
    }
  | {
      type: "delete_session";
      requestId: string;
      sessionId: string;
      provider: "codex";
      projectPath: string;
      confirmDescendantDeletion: true;
      codexSourceId?: string;
    }
  | { type: "refresh_branch"; sessionId: string }
  // ---- Git Operations (Phase 1-3) ----
  | {
      type: "git_stage";
      projectPath: string;
      files?: string[];
      hunks?: ClientHunkRef[];
    }
  | { type: "git_unstage"; projectPath: string; files?: string[] }
  | {
      type: "git_unstage_hunks";
      projectPath: string;
      hunks: ClientHunkRef[];
    }
  | {
      type: "git_commit";
      projectPath: string;
      sessionId?: string;
      message?: string;
      autoGenerate?: boolean;
    }
  | { type: "git_push"; projectPath: string }
  | { type: "git_branches"; projectPath: string }
  | {
      type: "git_create_branch";
      projectPath: string;
      name: string;
      checkout?: boolean;
    }
  | { type: "git_checkout_branch"; projectPath: string; branch: string }
  | { type: "git_revert_file"; projectPath: string; files: string[] }
  | {
      type: "git_revert_hunks";
      projectPath: string;
      hunks: ClientHunkRef[];
    }
  | { type: "git_fetch"; projectPath: string }
  | { type: "git_pull"; projectPath: string }
  | {
      type: "git_status";
      projectPath: string;
      sessionId?: string;
      includeRemote?: boolean;
    }
  | { type: "git_remote_status"; projectPath: string }
  | LocalFeatureClientMessage
  | FileTransferClientMessage;

/** Image change detected in a git diff (binary image file). */
export interface ImageChange {
  filePath: string;
  isNew: boolean;
  isDeleted: boolean;
  isSvg: boolean;
  oldSize?: number;
  newSize?: number;
  /** Base64-encoded old image (included only for on-demand loads). */
  oldBase64?: string;
  /** Base64-encoded new image (included only for on-demand loads). */
  newBase64?: string;
  mimeType: string;
  /** Whether the image can be loaded on demand (auto-display or loadable range). */
  loadable: boolean;
  /** Whether the image qualifies for auto-display (≤ auto threshold). */
  autoDisplay?: boolean;
}

export interface DebugTraceEvent {
  ts: string;
  sessionId: string;
  direction: "incoming" | "outgoing" | "internal";
  channel: "ws" | "session" | "bridge";
  type: string;
  detail?: string;
}

export interface CodexCliJoinTarget {
  url: string;
  command: string;
}

export type ServerMessage = (
  | BackgroundDeliveryServerMessage
  | PushRegistrationStateMessage
  | {
      type: "system";
      subtype: string;
      sessionId?: string;
      claudeSessionId?: string;
      model?: string;
      provider?: Provider;
      projectPath?: string;
      approvalPolicy?: string;
      approvalsReviewer?: string;
      codexPermissionsMode?: CodexPermissionsMode;
      executionMode?: ExecutionMode;
      planMode?: boolean;
      slashCommands?: string[];
      skills?: string[];
      skillMetadata?: Array<{
        name: string;
        path: string;
        description: string;
        shortDescription?: string;
        enabled: boolean;
        scope: string;
        displayName?: string;
        defaultPrompt?: string;
        brandColor?: string;
      }>;
      apps?: string[];
      appMetadata?: Array<{
        id: string;
        name: string;
        description: string;
        installUrl?: string;
        isAccessible: boolean;
        isEnabled: boolean;
      }>;
      plugins?: string[];
      pluginMetadata?: Array<{
        id: string;
        name: string;
        path: string;
        marketplaceName: string;
        marketplacePath?: string;
        installed: boolean;
        enabled: boolean;
        displayName?: string;
        shortDescription?: string;
        longDescription?: string;
        defaultPrompt?: string;
        brandColor?: string;
        composerIcon?: string;
        composerIconUrl?: string;
      }>;
      worktreePath?: string;
      worktreeBranch?: string;
      permissionMode?: PermissionMode;
      sandboxMode?: string;
      modelReasoningEffort?: string;
      serviceTier?: string;
      /** Whether a settings ACK reached app-server persistence or runtime only. */
      settingsPersistence?: "durable" | "runtime_only";
      networkAccessEnabled?: boolean;
      webSearchMode?: string;
      additionalWritableRoots?: string[];
      /** Exact per-runtime probe of the experimental Codex Plan preset. */
      codexNativePlanModeSupported?: boolean;
      clearContext?: boolean;
      sourceSessionId?: string;
      forkedFromSessionId?: string;
      forkedFromThreadId?: string;
      startRequestId?: string;
      resumeRequestId?: string;
      sessionLinkGeneration?: number;
      errorMessage?: string;
      tipCode?: string;
      /** Provider turn identity for timeline-bound system markers. */
      historyTurnId?: string;
      permissionChangeId?: string;
      codexCliJoin?: CodexCliJoinTarget;
    }
  | {
      type: "assistant";
      message: AssistantMessage;
      messageUuid?: string;
      artifacts?: ArtifactRef[];
      historyToolDetailGaps?: HistoryToolDetailGap[];
      /** Bridge-internal provenance used to attach a gap to its provider turn. */
      historyTurnId?: string;
    }
  | {
      type: "tool_result";
      toolUseId: string;
      content: string;
      toolName?: string;
      images?: ImageRef[];
      userMessageUuid?: string;
      rawContentBlocks?: unknown[];
      /** Bridge-internal only; SessionManager strips it before history/broadcast. */
      artifactCandidates?: ArtifactCandidate[];
      artifacts?: ArtifactRef[];
      /** Bridge-internal provenance used to attach a gap to its provider turn. */
      historyTurnId?: string;
    }
  | {
      type: "artifact_resolved";
      requestId: string;
      artifactId: string;
      relativeUrl?: string;
      expiresAt?: string;
      error?: string;
      errorCode?: string;
    }
  | {
      type: "result";
      subtype: string;
      result?: string;
      error?: string;
      cost?: number;
      duration?: number;
      sessionId?: string;
      stopReason?: string;
      inputTokens?: number;
      cachedInputTokens?: number;
      outputTokens?: number;
      toolCalls?: number;
      fileEdits?: number;
    }
  | {
      type: "guardian_approval";
      risk: "medium" | "high";
      reason: string;
      authorization?: string;
      status?: "approved";
      reviewId?: string;
      targetItemId?: string;
      action?: Record<string, unknown>;
    }
  | {
      type: "error";
      message: string;
      errorCode?: string;
      sessionId?: string;
      permissionChangeId?: string;
      goalChangeId?: string;
      /**
       * Additive metadata for new clients. Legacy clients keep rendering the
       * original Codex warning text, so low/critical and non-approved reviews
       * remain backward compatible.
       */
      guardianReview?: GuardianReviewDetails;
    }
  | {
      type: "session_link_resolution";
      requestId: string;
      sourceSessionId: string;
      status: "live" | "recent" | "unavailable";
      bridgeSessionId?: string;
      provider?: Provider;
      recentSession?: Record<string, unknown>;
      sessionLinkGeneration?: number;
    }
  | {
      type: "session_link_progress_v1";
      requestId: string;
      sourceSessionId: string;
      generation: number;
      operation: SessionLinkProgressOperation;
      stage: SessionLinkProgressStage;
      sequence: number;
      observedAt: string;
      completedUnits?: number;
      totalUnits?: number;
    }
  | { type: "status"; status: ProcessStatus }
  | {
      type: "history";
      messages: ServerMessage[];
      historyWindow?: {
        capability: "turn_aware_history_window_v1";
        fromSeq: number;
        hasMore: boolean;
        cursor?: string;
      };
    }
  | {
      type: "history_page";
      requestId: string;
      sessionId: string;
      beforeSeq: number;
      nextBeforeSeq: number;
      nextBeforeCursor?: string;
      hasMore: boolean;
      messages: Array<{ seq: number; message: ServerMessage }>;
      error?: string;
    }
  | {
      type: "history_tool_details";
      requestId: string;
      sessionId: string;
      details: HistoryToolDetailPayload[];
      error?: string;
    }
  | {
      type: "history_delta";
      sessionId?: string;
      fromSeq: number;
      toSeq: number;
      messages: Array<{ seq: number; message: ServerMessage }>;
      status?: ProcessStatus;
    }
  | {
      type: "history_snapshot";
      sessionId?: string;
      fromSeq: number;
      toSeq: number;
      messages: Array<{ seq: number; message: ServerMessage }>;
      status?: ProcessStatus;
      reason: "compacted" | "reset";
      historyWindow?: {
        capability: "turn_aware_history_window_v1";
        fromSeq: number;
        hasMore: boolean;
        cursor?: string;
      };
    }
  | {
      type: "conversation_queue";
      sessionId?: string;
      limit: number;
      items: QueuedInputItem[];
    }
  | {
      type: "input_delivery_status_v1";
      sessionId: string;
      clientMessageId: string;
      stage: "provider_accepted" | "provider_rejected";
      provider: "codex";
      method: "turn/start" | "turn/steer";
      occurredAt: string;
      acceptedSeq?: number;
      queued?: boolean;
      clientUserMessageIdAccepted?: boolean;
      error?: string;
    }
  | {
      type: "goal_state";
      sessionId?: string;
      goal: CodexGoal | null;
      goalChangeId?: string;
      /** Bridge-local ordering token; clients may ignore this field. */
      goalOperationSequence?: number;
    }
  | {
      type: "permission_request";
      toolUseId: string;
      toolName: string;
      input: Record<string, unknown>;
    }
  | { type: "permission_resolved"; toolUseId: string }
  | { type: "stream_delta"; text: string }
  | { type: "thinking_delta"; text: string }
  | {
      type: "file_content";
      requestId?: string;
      filePath: string;
      kind?: "text" | "image";
      content: string;
      language?: string;
      error?: string;
      errorCode?: string;
      totalLines?: number;
      truncated?: boolean;
      base64?: string;
      mimeType?: string;
      sizeBytes?: number;
    }
  | {
      type: "file_list";
      files: string[];
      /** Echoed when list_files supplied one, so concurrent explorers do not cross-talk. */
      requestId?: string;
      /** Echoed project identity for clients that need to reject foreign broadcasts. */
      projectPath?: string;
      totalFiles?: number;
      truncated?: boolean;
      error?: string;
      errorCode?: string;
    }
  | { type: "project_history"; projects: string[] }
  | {
      type: "session_catalog_changed_v1";
      revision: number;
      occurredAt: string;
    }
  | {
      type: "diff_result";
      diff: string;
      error?: string;
      errorCode?: string;
      imageChanges?: ImageChange[];
      /** Echo of the get_diff requestId, present when the client sent one. */
      requestId?: string;
    }
  | {
      type: "diff_image_result";
      projectPath: string;
      filePath: string;
      version: "old" | "new" | "both";
      base64?: string;
      mimeType?: string;
      error?: string;
      oldBase64?: string;
      newBase64?: string;
      /** Echo of the get_diff_image requestId when the client sent one. */
      requestId?: string;
    }
  | { type: "worktree_list"; worktrees: WorktreeInfo[]; mainBranch?: string }
  | { type: "worktree_removed"; worktreePath: string }
  | { type: "tool_use_summary"; summary: string; precedingToolUseIds: string[] }
  | {
      type: "rewind_preview";
      canRewind: boolean;
      filesChanged?: string[];
      insertions?: number;
      deletions?: number;
      error?: string;
    }
  | {
      type: "rewind_result";
      success: boolean;
      mode: "conversation" | "code" | "both";
      error?: string;
    }
  | {
      type: "user_input";
      text: string;
      clientMessageId?: string;
      /** Stable provider item identity. Never derive this from page position. */
      providerItemId?: string;
      /** Provider turn provenance used to keep paged/live items together. */
      historyTurnId?: string;
      userMessageUuid?: string;
      isSynthetic?: boolean;
      isMeta?: boolean;
      imageCount?: number;
      timestamp?: string;
      images?: ImageRef[];
    }
  | { type: "window_list"; windows: WindowInfo[] }
  | {
      type: "screenshot_result";
      success: boolean;
      image?: GalleryImageInfo;
      error?: string;
    }
  | {
      type: "debug_bundle";
      sessionId: string;
      generatedAt: string;
      session: {
        id: string;
        provider: Provider;
        status: ProcessStatus;
        projectPath: string;
        worktreePath?: string;
        worktreeBranch?: string;
        claudeSessionId?: string;
        createdAt: string;
        lastActivityAt: string;
      };
      pastMessageCount: number;
      historySummary: string[];
      debugTrace: DebugTraceEvent[];
      traceFilePath: string;
      reproRecipe: {
        wsUrlHint: string;
        startBridgeCommand: string;
        resumeSessionMessage: Record<string, unknown>;
        getHistoryMessage: Record<string, unknown>;
        getDebugBundleMessage: Record<string, unknown>;
        notes: string[];
      };
      agentPrompt: string;
      diff: string;
      diffError?: string;
      savedBundlePath?: string;
    }
  | { type: "usage_result"; providers: UsageInfoPayload[] }
  | { type: "message_images_result"; messageUuid: string; images: ImageRef[] }
  | {
      type: "prompt_history_backup_result";
      success: boolean;
      backedUpAt?: string;
      error?: string;
    }
  | {
      type: "prompt_history_restore_result";
      success: boolean;
      data?: string;
      appVersion?: string;
      dbVersion?: number;
      backedUpAt?: string;
      error?: string;
    }
  | {
      type: "prompt_history_backup_info";
      exists: boolean;
      appVersion?: string;
      dbVersion?: number;
      backedUpAt?: string;
      sizeBytes?: number;
    }
  | {
      type: "prompt_history_sync_result";
      success: boolean;
      requestId?: string;
      bridgeInstanceId?: string;
      revision?: number;
      syncedAt?: string;
      fullSnapshot?: boolean;
      entries?: PromptHistoryEntry[];
      error?: string;
    }
  | {
      type: "prompt_history_mutation_result";
      success: boolean;
      bridgeInstanceId?: string;
      revision?: number;
      entry?: PromptHistoryEntry;
      error?: string;
    }
  | {
      type: "prompt_history_status";
      bridgeInstanceId: string;
      revision: number;
      entryCount: number;
      updatedAt?: string;
    }
  | {
      type: "rename_result";
      sessionId: string;
      name: string | null;
      success: boolean;
      error?: string;
    }
  | {
      type: "archive_result";
      requestId?: string;
      sessionId: string;
      provider?: Provider;
      success: boolean;
      error?: string;
      errorCode?: string;
    }
  | {
      type: "archived_sessions_result";
      requestId: string;
      sessions: ArchivedSessionPayload[];
      success: boolean;
      truncated?: boolean;
      error?: string;
      errorCode?: string;
    }
  | {
      type: "unarchive_result" | "delete_session_result";
      requestId: string;
      sessionId: string;
      success: boolean;
      error?: string;
      errorCode?: string;
    }
  // ---- Git Operations (Phase 1-3) ----
  // Every git result echoes the request's projectPath so app-side views bound
  // to different projects can discard each other's broadcast results.
  | {
      type: "git_stage_result";
      success: boolean;
      projectPath?: string;
      error?: string;
    }
  | {
      type: "git_unstage_result";
      success: boolean;
      projectPath?: string;
      error?: string;
    }
  | {
      type: "git_unstage_hunks_result";
      success: boolean;
      projectPath?: string;
      error?: string;
    }
  | {
      type: "git_commit_result";
      success: boolean;
      projectPath?: string;
      commitHash?: string;
      message?: string;
      error?: string;
    }
  | {
      type: "git_push_result";
      success: boolean;
      projectPath?: string;
      error?: string;
    }
  | {
      type: "git_branches_result";
      current: string;
      branches: string[];
      projectPath?: string;
      checkedOutBranches?: string[];
      remoteStatusByBranch?: Record<
        string,
        { ahead: number; behind: number; hasUpstream: boolean }
      >;
      error?: string;
    }
  | {
      type: "git_create_branch_result";
      success: boolean;
      projectPath?: string;
      error?: string;
    }
  | {
      type: "git_checkout_branch_result";
      success: boolean;
      projectPath?: string;
      error?: string;
    }
  | {
      type: "git_revert_file_result";
      success: boolean;
      projectPath?: string;
      error?: string;
    }
  | {
      type: "git_revert_hunks_result";
      success: boolean;
      projectPath?: string;
      error?: string;
    }
  | {
      type: "git_fetch_result";
      success: boolean;
      projectPath?: string;
      error?: string;
    }
  | {
      type: "git_pull_result";
      success: boolean;
      projectPath?: string;
      message?: string;
      error?: string;
    }
  | {
      type: "git_status_result";
      sessionId?: string;
      projectPath: string;
      hasUncommittedChanges: boolean;
      stagedCount: number;
      unstagedCount: number;
      untrackedCount: number;
      remoteStatusIncluded?: boolean;
      hasRemoteChanges?: boolean;
      commitsAhead?: number;
      commitsBehind?: number;
      hasUpstream?: boolean;
      branch?: string;
      remoteError?: string;
      error?: string;
    }
  | {
      type: "git_remote_status_result";
      ahead: number;
      behind: number;
      branch: string;
      hasUpstream: boolean;
      projectPath?: string;
      error?: string;
      errorCode?: string;
    }
  | LocalFeatureServerMessage
  | FileTransferServerMessage
) & {
  /** Bridge-owned wall time when this live transcript event was first seen. */
  receivedAt?: string;
  /** Provider event time, approximate unless explicitly marked authoritative. */
  sourceTimestamp?: string;
  /** The source timestamp came from an individual provider event record. */
  sourceTimestampIsAuthoritative?: boolean;
  /** Bridge-local sequence metadata retained on in-memory transcript entries. */
  historySeq?: number;
};

export interface UsageWindowPayload {
  utilization: number;
  resetsAt: string;
}

export interface ArchivedSessionPayload {
  sessionId: string;
  provider: Provider;
  projectPath: string;
  archivedAt: string;
  name?: string;
  summary?: string;
  firstPrompt?: string;
  modified?: string;
}

export interface UsageInfoPayload {
  provider: "claude" | "codex";
  fiveHour: UsageWindowPayload | null;
  sevenDay: UsageWindowPayload | null;
  error?: string;
}

export type ProcessStatus =
  "starting" | "idle" | "running" | "waiting_approval" | "compacting";

// ---- Helpers ----

/** Normalize tool_result content: may be string or array of content blocks. */
export function normalizeToolResultContent(
  content: string | unknown[],
): string {
  if (Array.isArray(content)) {
    return (content as Array<Record<string, unknown>>)
      .filter((c) => c.type === "text")
      .map((c) => c.text as string)
      .join("\n");
  }
  return typeof content === "string" ? content : String(content ?? "");
}

// ---- Parser ----

function isValidClientHunkRef(value: unknown): boolean {
  const hunk = value as Record<string, unknown> | null | undefined;
  if (typeof hunk?.file !== "string" || typeof hunk?.hunkIndex !== "number") {
    return false;
  }
  if (hunk.fingerprint === undefined) return true;
  const fp = hunk.fingerprint as Record<string, unknown> | null;
  return (
    typeof fp?.oldStart === "number" &&
    typeof fp?.oldLines === "number" &&
    typeof fp?.newStart === "number" &&
    typeof fp?.newLines === "number" &&
    typeof fp?.changesHash === "string"
  );
}

function isValidWireIdentifier(
  value: unknown,
  maxLength = 256,
): value is string {
  return (
    typeof value === "string" &&
    value.length > 0 &&
    value.length <= maxLength &&
    value.trim() === value
  );
}

function hasValidCodexSettingsMutationEnvelope(
  msg: Record<string, unknown>,
): boolean {
  if (msg.settingsTarget !== undefined) {
    return (
      msg.settingsTarget === "durable_thread" &&
      isValidWireIdentifier(msg.codexSourceId, 128) &&
      isValidWireIdentifier(msg.threadId) &&
      isValidWireIdentifier(msg.operationId, 128) &&
      msg.runtimeSessionId === undefined &&
      msg.authorityGeneration === undefined &&
      msg.sessionId === undefined
    );
  }
  const fields = [
    msg.codexSourceId,
    msg.threadId,
    msg.runtimeSessionId,
    msg.authorityGeneration,
    msg.operationId,
  ];
  const present = fields.filter((value) => value !== undefined).length;
  if (present === 0) return true;
  if (present !== fields.length) return false;
  return (
    isValidWireIdentifier(msg.codexSourceId, 128) &&
    isValidWireIdentifier(msg.threadId) &&
    isValidWireIdentifier(msg.runtimeSessionId) &&
    isValidWireIdentifier(msg.authorityGeneration) &&
    isValidWireIdentifier(msg.operationId, 128) &&
    msg.sessionId === msg.runtimeSessionId
  );
}

export function parseClientMessage(data: string): ClientMessage | null {
  try {
    const msg = JSON.parse(data) as Record<string, unknown>;
    if (!msg.type || typeof msg.type !== "string") return null;
    const backgroundDeliveryMessage = parseBackgroundDeliveryClientMessage(msg);
    if (backgroundDeliveryMessage !== undefined) {
      return backgroundDeliveryMessage;
    }
    const fileTransferMessage = parseFileTransferClientMessage(msg);
    if (fileTransferMessage !== undefined) return fileTransferMessage;
    const localFeatureMessage = parseLocalFeatureClientMessage(msg);
    if (localFeatureMessage !== undefined) return localFeatureMessage;
    if (
      Object.prototype.hasOwnProperty.call(msg, "sessionId") &&
      !isValidWireIdentifier(msg.sessionId)
    ) {
      return null;
    }
    const hasOnlyKeys = (allowedKeys: readonly string[]): boolean => {
      const allowed = new Set(allowedKeys);
      return Object.keys(msg).every((key) => allowed.has(key));
    };
    const isPromptHistoryStatRecord = (
      value: unknown,
      allowClientName: boolean,
    ): boolean => {
      if (!value || typeof value !== "object" || Array.isArray(value)) {
        return false;
      }
      return Object.values(value as Record<string, unknown>).every((stat) => {
        if (!stat || typeof stat !== "object" || Array.isArray(stat)) {
          return false;
        }
        const record = stat as Record<string, unknown>;
        if (!Number.isInteger(record.useCount) || Number(record.useCount) < 0)
          return false;
        if (typeof record.lastUsedAt !== "string") return false;
        if (
          allowClientName &&
          record.clientName !== undefined &&
          typeof record.clientName !== "string"
        )
          return false;
        return true;
      });
    };
    const isPromptHistoryEntry = (value: unknown): boolean => {
      if (!value || typeof value !== "object") return false;
      const entry = value as Record<string, unknown>;
      if (typeof entry.text !== "string") return false;
      if (
        entry.projectPath !== undefined &&
        typeof entry.projectPath !== "string"
      )
        return false;
      if (entry.id !== undefined && typeof entry.id !== "string") return false;
      if (
        entry.useCount !== undefined &&
        (!Number.isInteger(entry.useCount) || Number(entry.useCount) < 0)
      )
        return false;
      if (
        entry.totalUseCount !== undefined &&
        (!Number.isInteger(entry.totalUseCount) ||
          Number(entry.totalUseCount) < 0)
      )
        return false;
      if (
        entry.isFavorite !== undefined &&
        typeof entry.isFavorite !== "boolean"
      )
        return false;
      for (const key of [
        "createdAt",
        "lastUsedAt",
        "updatedAt",
        "favoriteUpdatedAt",
        "deletedAt",
      ] as const) {
        if (entry[key] !== undefined && typeof entry[key] !== "string")
          return false;
      }
      if (
        entry.commandKind !== undefined &&
        (typeof entry.commandKind !== "string" ||
          !["none", "slash", "skill"].includes(entry.commandKind))
      )
        return false;
      if (
        entry.clientStats !== undefined &&
        !isPromptHistoryStatRecord(entry.clientStats, true)
      )
        return false;
      if (
        entry.sessionStats !== undefined &&
        !isPromptHistoryStatRecord(entry.sessionStats, false)
      )
        return false;
      return true;
    };

    switch (msg.type) {
      case "client_capabilities":
        if (
          msg.appVersion !== undefined &&
          (typeof msg.appVersion !== "string" || msg.appVersion.length > 128)
        )
          return null;
        if (
          msg.protocolVersion !== undefined &&
          (!Number.isInteger(msg.protocolVersion) ||
            Number(msg.protocolVersion) < 1)
        )
          return null;
        if (msg.supportedServerMessages !== undefined) {
          if (
            !Array.isArray(msg.supportedServerMessages) ||
            msg.supportedServerMessages.length > 512
          )
            return null;
          if (
            msg.supportedServerMessages.some(
              (type) =>
                typeof type !== "string" ||
                type.length === 0 ||
                type.length > 128,
            )
          )
            return null;
        }
        if (msg.mobileRuntime !== undefined) {
          if (
            typeof msg.mobileRuntime !== "object" ||
            msg.mobileRuntime === null ||
            Array.isArray(msg.mobileRuntime)
          )
            return null;
          const runtime = msg.mobileRuntime as Record<string, unknown>;
          if (
            !Object.keys(runtime).every((key) =>
              [
                "baseVersion",
                "buildNumber",
                "patchNumber",
                "hostSchemaVersion",
                "nativeCapabilities",
              ].includes(key),
            )
          )
            return null;
          for (const key of ["baseVersion", "buildNumber"] as const) {
            const value = runtime[key];
            if (
              value !== undefined &&
              (typeof value !== "string" ||
                value.length < 1 ||
                value.length > 64)
            )
              return null;
          }
          if (
            runtime.patchNumber !== undefined &&
            (!Number.isInteger(runtime.patchNumber) ||
              Number(runtime.patchNumber) < 0 ||
              Number(runtime.patchNumber) > 1_000_000)
          )
            return null;
          if (
            !Number.isInteger(runtime.hostSchemaVersion) ||
            Number(runtime.hostSchemaVersion) < 0 ||
            Number(runtime.hostSchemaVersion) > 1_000
          )
            return null;
          if (
            typeof runtime.nativeCapabilities !== "object" ||
            runtime.nativeCapabilities === null ||
            Array.isArray(runtime.nativeCapabilities)
          )
            return null;
          const capabilities = Object.entries(
            runtime.nativeCapabilities as Record<string, unknown>,
          );
          if (capabilities.length > 64) return null;
          if (
            capabilities.some(
              ([key, value]) =>
                !/^[A-Za-z][A-Za-z0-9]{0,63}$/.test(key) ||
                !Number.isInteger(value) ||
                Number(value) < 1 ||
                Number(value) > 1_000,
            )
          )
            return null;
        }
        break;
      case "start":
        if (typeof msg.projectPath !== "string") return null;
        if (
          msg.startRequestId !== undefined &&
          (typeof msg.startRequestId !== "string" ||
            msg.startRequestId.length === 0 ||
            msg.startRequestId.length > 128)
        )
          return null;
        if (msg.model !== undefined && typeof msg.model !== "string")
          return null;
        if (
          msg.effort !== undefined &&
          !["low", "medium", "high", "xhigh", "max"].includes(
            String(msg.effort),
          )
        )
          return null;
        if (
          msg.maxTurns !== undefined &&
          (!Number.isInteger(msg.maxTurns) || Number(msg.maxTurns) < 1)
        )
          return null;
        if (
          msg.maxBudgetUsd !== undefined &&
          (typeof msg.maxBudgetUsd !== "number" ||
            !Number.isFinite(msg.maxBudgetUsd) ||
            msg.maxBudgetUsd < 0)
        )
          return null;
        if (
          msg.fallbackModel !== undefined &&
          typeof msg.fallbackModel !== "string"
        )
          return null;
        if (
          msg.forkSession !== undefined &&
          typeof msg.forkSession !== "boolean"
        )
          return null;
        if (
          msg.persistSession !== undefined &&
          typeof msg.persistSession !== "boolean"
        )
          return null;
        if (msg.profile !== undefined && typeof msg.profile !== "string")
          return null;
        if (
          msg.networkAccessEnabled !== undefined &&
          typeof msg.networkAccessEnabled !== "boolean"
        )
          return null;
        if (
          msg.modelReasoningEffort !== undefined &&
          (typeof msg.modelReasoningEffort !== "string" ||
            msg.modelReasoningEffort.trim().length === 0)
        )
          return null;
        if (
          msg.serviceTier !== undefined &&
          (typeof msg.serviceTier !== "string" ||
            msg.serviceTier.trim().length === 0)
        )
          return null;
        if (
          msg.permissionMode !== undefined &&
          ![
            "default",
            "auto",
            "acceptEdits",
            "bypassPermissions",
            "plan",
          ].includes(String(msg.permissionMode))
        )
          return null;
        if (
          msg.executionMode !== undefined &&
          !["default", "acceptEdits", "fullAccess"].includes(
            String(msg.executionMode),
          )
        )
          return null;
        if (
          msg.approvalPolicy !== undefined &&
          !["untrusted", "on-request", "on-failure", "never"].includes(
            String(msg.approvalPolicy),
          )
        )
          return null;
        if (
          msg.approvalsReviewer !== undefined &&
          !["user", "auto_review", "guardian_subagent"].includes(
            String(msg.approvalsReviewer),
          )
        )
          return null;
        if (
          msg.codexPermissionsMode !== undefined &&
          !["default", "autoReview", "fullAccess", "custom"].includes(
            String(msg.codexPermissionsMode),
          )
        )
          return null;
        if (msg.planMode !== undefined && typeof msg.planMode !== "boolean")
          return null;
        if (msg.autoRename !== undefined && typeof msg.autoRename !== "boolean")
          return null;
        if (
          msg.webSearchMode !== undefined &&
          !["disabled", "cached", "live"].includes(String(msg.webSearchMode))
        )
          return null;
        if (msg.additionalWritableRoots !== undefined) {
          if (!Array.isArray(msg.additionalWritableRoots)) return null;
          if (
            msg.additionalWritableRoots.some((root) => typeof root !== "string")
          )
            return null;
        }
        break;
      case "input":
        if (typeof msg.text !== "string") return null;
        if (
          msg.clientMessageId !== undefined &&
          typeof msg.clientMessageId !== "string"
        )
          return null;
        if (
          msg.baseSeq !== undefined &&
          (typeof msg.baseSeq !== "number" ||
            !Number.isInteger(msg.baseSeq) ||
            msg.baseSeq < 0)
        )
          return null;
        // Validate images array if provided
        if (msg.images !== undefined) {
          if (!Array.isArray(msg.images)) return null;
          for (const img of msg.images) {
            if (
              typeof img?.base64 !== "string" ||
              typeof img?.mimeType !== "string"
            )
              return null;
          }
        }
        if (msg.skills !== undefined) {
          if (!Array.isArray(msg.skills)) return null;
          for (const skill of msg.skills) {
            if (
              typeof skill?.name !== "string" ||
              typeof skill?.path !== "string"
            )
              return null;
          }
        }
        if (msg.mentions !== undefined) {
          if (!Array.isArray(msg.mentions)) return null;
          for (const mention of msg.mentions) {
            if (
              typeof mention?.name !== "string" ||
              typeof mention?.path !== "string"
            )
              return null;
          }
        }
        // Legacy: imageBase64 requires mimeType
        if (msg.imageBase64 && typeof msg.mimeType !== "string") return null;
        break;
      case "update_queued_input":
        if (
          typeof msg.sessionId !== "string" ||
          !isValidWireIdentifier(msg.itemId) ||
          typeof msg.text !== "string"
        )
          return null;
        if (msg.skills !== undefined) {
          if (!Array.isArray(msg.skills)) return null;
          for (const skill of msg.skills) {
            if (
              typeof skill?.name !== "string" ||
              typeof skill?.path !== "string"
            )
              return null;
          }
        }
        if (msg.mentions !== undefined) {
          if (!Array.isArray(msg.mentions)) return null;
          for (const mention of msg.mentions) {
            if (
              typeof mention?.name !== "string" ||
              typeof mention?.path !== "string"
            )
              return null;
          }
        }
        break;
      case "steer_queued_input":
        if (
          typeof msg.sessionId !== "string" ||
          !isValidWireIdentifier(msg.itemId)
        )
          return null;
        if (
          msg.expectedTurnId !== undefined &&
          (typeof msg.expectedTurnId !== "string" ||
            msg.expectedTurnId.length === 0 ||
            msg.expectedTurnId.length > 256)
        )
          return null;
        {
          const authorityFields = [
            msg.codexSourceId,
            msg.threadId,
            msg.authorityGeneration,
          ];
          const authorityFieldCount = authorityFields.filter(
            (value) => value !== undefined,
          ).length;
          if (authorityFieldCount !== 0 && authorityFieldCount !== 3) {
            return null;
          }
          if (
            authorityFieldCount === 3 &&
            (!isValidWireIdentifier(msg.codexSourceId, 128) ||
              !isValidWireIdentifier(msg.threadId) ||
              !isValidWireIdentifier(msg.authorityGeneration) ||
              !isValidWireIdentifier(msg.expectedTurnId))
          ) {
            return null;
          }
        }
        break;
      case "cancel_queued_input":
        if (
          typeof msg.sessionId !== "string" ||
          !isValidWireIdentifier(msg.itemId)
        )
          return null;
        break;
      case "push_register":
        if (
          typeof msg.token !== "string" ||
          msg.token.length === 0 ||
          msg.token.length > 4_096
        )
          return null;
        if (
          msg.platform !== "ios" &&
          msg.platform !== "android" &&
          msg.platform !== "web"
        )
          return null;
        if (msg.enabledEventTypes !== undefined) {
          if (
            !Array.isArray(msg.enabledEventTypes) ||
            msg.enabledEventTypes.length > 16 ||
            msg.enabledEventTypes.some(
              (eventType) =>
                typeof eventType !== "string" ||
                eventType.length === 0 ||
                eventType.length > 64,
            )
          )
            return null;
        }
        if (
          msg.requestId !== undefined &&
          (typeof msg.requestId !== "string" ||
            msg.requestId.length === 0 ||
            msg.requestId.length > 96)
        )
          return null;
        if (
          msg.approvalActionsSupported !== undefined &&
          typeof msg.approvalActionsSupported !== "boolean"
        )
          return null;
        if (
          msg.approvalActionsVersion !== undefined &&
          msg.approvalActionsVersion !== 1 &&
          msg.approvalActionsVersion !== 2
        )
          return null;
        break;
      case "push_unregister":
        if (
          typeof msg.token !== "string" ||
          msg.token.length === 0 ||
          msg.token.length > 4_096
        )
          return null;
        if (
          msg.requestId !== undefined &&
          (typeof msg.requestId !== "string" ||
            msg.requestId.length === 0 ||
            msg.requestId.length > 96)
        )
          return null;
        break;
      case "set_permission_mode":
        if (!hasValidCodexSettingsMutationEnvelope(msg)) return null;
        if (
          typeof msg.mode !== "string" ||
          ![
            "default",
            "auto",
            "acceptEdits",
            "bypassPermissions",
            "plan",
          ].includes(msg.mode)
        )
          return null;
        if (
          msg.executionMode !== undefined &&
          !["default", "acceptEdits", "fullAccess"].includes(
            String(msg.executionMode),
          )
        )
          return null;
        if (
          msg.approvalPolicy !== undefined &&
          !["untrusted", "on-request", "on-failure", "never"].includes(
            String(msg.approvalPolicy),
          )
        )
          return null;
        if (
          msg.approvalsReviewer !== undefined &&
          !["user", "auto_review", "guardian_subagent"].includes(
            String(msg.approvalsReviewer),
          )
        )
          return null;
        if (
          msg.codexPermissionsMode !== undefined &&
          !["default", "autoReview", "fullAccess", "custom"].includes(
            String(msg.codexPermissionsMode),
          )
        )
          return null;
        if (msg.planMode !== undefined && typeof msg.planMode !== "boolean")
          return null;
        if (
          msg.applyStrategy !== undefined &&
          msg.applyStrategy !== "next_turn" &&
          msg.applyStrategy !== "restart_now"
        )
          return null;
        if (
          msg.permissionChangeId !== undefined &&
          (typeof msg.permissionChangeId !== "string" ||
            msg.permissionChangeId.trim() === "")
        )
          return null;
        break;
      case "set_codex_model":
        if (!hasValidCodexSettingsMutationEnvelope(msg)) return null;
        if (typeof msg.model !== "string" || msg.model.trim() === "")
          return null;
        if (
          msg.modelReasoningEffort !== undefined &&
          (typeof msg.modelReasoningEffort !== "string" ||
            msg.modelReasoningEffort.trim().length === 0)
        )
          return null;
        if (msg.sessionId !== undefined && typeof msg.sessionId !== "string")
          return null;
        break;
      case "set_codex_speed":
        if (!hasValidCodexSettingsMutationEnvelope(msg)) return null;
        if (
          typeof msg.serviceTier !== "string" ||
          msg.serviceTier.trim().length === 0
        )
          return null;
        if (msg.sessionId !== undefined && typeof msg.sessionId !== "string")
          return null;
        break;
      case "get_goal":
        if (typeof msg.sessionId !== "string") return null;
        break;
      case "clear_goal":
        if (typeof msg.sessionId !== "string") return null;
        if (
          msg.goalChangeId !== undefined &&
          (typeof msg.goalChangeId !== "string" ||
            msg.goalChangeId.trim().length === 0)
        )
          return null;
        if (
          msg.expectedGoalOperationSequence !== undefined &&
          (typeof msg.expectedGoalOperationSequence !== "number" ||
            !Number.isSafeInteger(msg.expectedGoalOperationSequence) ||
            msg.expectedGoalOperationSequence < 0)
        )
          return null;
        break;
      case "set_goal": {
        if (typeof msg.sessionId !== "string") return null;
        const hasObjective = msg.objective !== undefined;
        const hasStatus = msg.status !== undefined;
        const hasTokenBudget = msg.tokenBudget !== undefined;
        if (!hasObjective && !hasStatus && !hasTokenBudget) return null;
        if (
          hasObjective &&
          (typeof msg.objective !== "string" ||
            msg.objective.trim().length === 0 ||
            msg.objective.length > 4000)
        ) {
          return null;
        }
        if (
          hasStatus &&
          ![
            "active",
            "paused",
            "blocked",
            "usageLimited",
            "budgetLimited",
            "complete",
          ].includes(String(msg.status))
        ) {
          return null;
        }
        if (
          hasTokenBudget &&
          msg.tokenBudget !== null &&
          (typeof msg.tokenBudget !== "number" ||
            !Number.isInteger(msg.tokenBudget) ||
            msg.tokenBudget <= 0)
        ) {
          return null;
        }
        if (
          msg.goalChangeId !== undefined &&
          (typeof msg.goalChangeId !== "string" ||
            msg.goalChangeId.trim().length === 0)
        ) {
          return null;
        }
        if (
          msg.expectedGoalOperationSequence !== undefined &&
          (typeof msg.expectedGoalOperationSequence !== "number" ||
            !Number.isSafeInteger(msg.expectedGoalOperationSequence) ||
            msg.expectedGoalOperationSequence < 0)
        ) {
          return null;
        }
        break;
      }
      case "set_sandbox_mode":
        if (!hasValidCodexSettingsMutationEnvelope(msg)) return null;
        if (typeof msg.sandboxMode !== "string") return null;
        break;
      case "approve":
        if (!isValidWireIdentifier(msg.id)) return null;
        break;
      case "approve_always":
        if (!isValidWireIdentifier(msg.id)) return null;
        break;
      case "reject":
        if (!isValidWireIdentifier(msg.id)) return null;
        break;
      case "answer":
        if (
          !isValidWireIdentifier(msg.toolUseId) ||
          typeof msg.result !== "string"
        )
          return null;
        break;
      case "install_tool_suggestion":
        if (!isValidWireIdentifier(msg.toolUseId)) return null;
        break;
      case "list_sessions":
        break;
      case "stop_session":
        if (typeof msg.sessionId !== "string") return null;
        break;
      case "detach_session":
        if (
          !isValidWireIdentifier(msg.sessionId) ||
          !isValidWireIdentifier(msg.codexSourceId, 128) ||
          !isValidWireIdentifier(msg.threadId) ||
          !isValidWireIdentifier(msg.authorityGeneration)
        ) {
          return null;
        }
        break;
      case "rename_session":
        if (typeof msg.sessionId !== "string") return null;
        if (
          msg.codexSourceId !== undefined &&
          !isValidWireIdentifier(msg.codexSourceId, 128)
        )
          return null;
        break;
      case "get_history":
        if (typeof msg.sessionId !== "string") return null;
        break;
      case "get_history_delta":
        if (typeof msg.sessionId !== "string") return null;
        if (
          typeof msg.sinceSeq !== "number" ||
          !Number.isInteger(msg.sinceSeq) ||
          msg.sinceSeq < 0
        )
          return null;
        break;
      case "get_history_page":
        if (
          typeof msg.requestId !== "string" ||
          msg.requestId.length === 0 ||
          msg.requestId.length > 128 ||
          typeof msg.sessionId !== "string" ||
          msg.sessionId.length === 0 ||
          msg.sessionId.length > 256 ||
          typeof msg.beforeSeq !== "number" ||
          !Number.isSafeInteger(msg.beforeSeq) ||
          msg.beforeSeq <= 0
        )
          return null;
        if (
          msg.beforeCursor !== undefined &&
          (typeof msg.beforeCursor !== "string" ||
            msg.beforeCursor.length === 0 ||
            msg.beforeCursor.length > 512)
        )
          return null;
        break;
      case "get_history_tool_details":
        if (
          typeof msg.requestId !== "string" ||
          msg.requestId.length === 0 ||
          msg.requestId.length > 128 ||
          typeof msg.sessionId !== "string" ||
          msg.sessionId.length === 0 ||
          msg.sessionId.length > 256 ||
          !Array.isArray(msg.toolUseIds) ||
          msg.toolUseIds.length === 0 ||
          msg.toolUseIds.length > 8 ||
          msg.toolUseIds.some(
            (value: unknown) =>
              typeof value !== "string" ||
              value.length === 0 ||
              value.length > 256 ||
              value.trim() !== value,
          ) ||
          new Set(msg.toolUseIds).size !== msg.toolUseIds.length
        )
          return null;
        if (
          msg.historyTurnId !== undefined &&
          (typeof msg.historyTurnId !== "string" ||
            msg.historyTurnId.length === 0 ||
            msg.historyTurnId.length > 256 ||
            msg.historyTurnId.trim() !== msg.historyTurnId)
        )
          return null;
        break;
      case "resolve_artifact":
        if (
          !hasOnlyKeys([
            "type",
            "requestId",
            "sessionId",
            "messageId",
            "artifactId",
          ])
        )
          return null;
        if (
          typeof msg.requestId !== "string" ||
          msg.requestId.length === 0 ||
          msg.requestId.length > 128 ||
          typeof msg.sessionId !== "string" ||
          msg.sessionId.length === 0 ||
          msg.sessionId.length > 256 ||
          typeof msg.messageId !== "string" ||
          msg.messageId.length === 0 ||
          msg.messageId.length > 512 ||
          typeof msg.artifactId !== "string" ||
          msg.artifactId.length === 0 ||
          msg.artifactId.length > 128
        )
          return null;
        break;
      case "resolve_session_link":
        if (
          !hasOnlyKeys([
            "type",
            "requestId",
            "sessionId",
            "provider",
            "sessionLinkGeneration",
          ])
        )
          return null;
        if (
          typeof msg.requestId !== "string" ||
          msg.requestId.length === 0 ||
          msg.requestId.length > 128 ||
          typeof msg.sessionId !== "string" ||
          msg.sessionId.length === 0 ||
          msg.sessionId.length > 256
        )
          return null;
        if (
          msg.provider !== undefined &&
          msg.provider !== "claude" &&
          msg.provider !== "codex"
        )
          return null;
        if (
          msg.sessionLinkGeneration !== undefined &&
          (!Number.isSafeInteger(msg.sessionLinkGeneration) ||
            Number(msg.sessionLinkGeneration) < 1)
        )
          return null;
        break;
      case "list_recent_sessions":
        if (
          msg.limit !== undefined &&
          (typeof msg.limit !== "number" ||
            !Number.isSafeInteger(msg.limit) ||
            msg.limit <= 0)
        )
          return null;
        if (
          msg.offset !== undefined &&
          (typeof msg.offset !== "number" ||
            !Number.isSafeInteger(msg.offset) ||
            msg.offset < 0)
        )
          return null;
        if (
          msg.projectPath !== undefined &&
          (typeof msg.projectPath !== "string" ||
            msg.projectPath.length > 4_096)
        )
          return null;
        if (
          msg.requestScope !== undefined &&
          msg.requestScope !== "list" &&
          msg.requestScope !== "append" &&
          msg.requestScope !== "project" &&
          msg.requestScope !== "catalog"
        )
          return null;
        if (
          msg.requestId !== undefined &&
          (typeof msg.requestId !== "string" ||
            msg.requestId.length === 0 ||
            msg.requestId.length > 128)
        )
          return null;
        if (
          msg.queryGeneration !== undefined &&
          (typeof msg.queryGeneration !== "number" ||
            !Number.isSafeInteger(msg.queryGeneration) ||
            msg.queryGeneration < 0)
        )
          return null;
        if (
          msg.provider !== undefined &&
          msg.provider !== "claude" &&
          msg.provider !== "codex"
        )
          return null;
        if (msg.namedOnly !== undefined && typeof msg.namedOnly !== "boolean")
          return null;
        if (
          msg.searchQuery !== undefined &&
          (typeof msg.searchQuery !== "string" || msg.searchQuery.length > 512)
        )
          return null;
        break;
      case "resume_session":
        if (
          typeof msg.sessionId !== "string" ||
          typeof msg.projectPath !== "string"
        )
          return null;
        if (
          msg.codexSourceId !== undefined &&
          !isValidWireIdentifier(msg.codexSourceId, 128)
        )
          return null;
        if (
          msg.resumeRequestId !== undefined &&
          (typeof msg.resumeRequestId !== "string" ||
            msg.resumeRequestId.length === 0 ||
            msg.resumeRequestId.length > 128)
        )
          return null;
        if (
          msg.sessionLinkGeneration !== undefined &&
          (!Number.isSafeInteger(msg.sessionLinkGeneration) ||
            Number(msg.sessionLinkGeneration) < 1)
        )
          return null;
        if (
          msg.provider &&
          msg.provider !== "claude" &&
          msg.provider !== "codex"
        )
          return null;
        if (msg.model !== undefined && typeof msg.model !== "string")
          return null;
        if (
          msg.effort !== undefined &&
          !["low", "medium", "high", "xhigh", "max"].includes(
            String(msg.effort),
          )
        )
          return null;
        if (
          msg.maxTurns !== undefined &&
          (!Number.isInteger(msg.maxTurns) || Number(msg.maxTurns) < 1)
        )
          return null;
        if (
          msg.maxBudgetUsd !== undefined &&
          (typeof msg.maxBudgetUsd !== "number" ||
            !Number.isFinite(msg.maxBudgetUsd) ||
            msg.maxBudgetUsd < 0)
        )
          return null;
        if (
          msg.fallbackModel !== undefined &&
          typeof msg.fallbackModel !== "string"
        )
          return null;
        if (
          msg.forkSession !== undefined &&
          typeof msg.forkSession !== "boolean"
        )
          return null;
        if (
          msg.persistSession !== undefined &&
          typeof msg.persistSession !== "boolean"
        )
          return null;
        if (msg.profile !== undefined && typeof msg.profile !== "string")
          return null;
        if (
          msg.networkAccessEnabled !== undefined &&
          typeof msg.networkAccessEnabled !== "boolean"
        )
          return null;
        if (
          msg.modelReasoningEffort !== undefined &&
          (typeof msg.modelReasoningEffort !== "string" ||
            msg.modelReasoningEffort.trim().length === 0)
        )
          return null;
        if (
          msg.serviceTier !== undefined &&
          (typeof msg.serviceTier !== "string" ||
            msg.serviceTier.trim().length === 0)
        )
          return null;
        if (
          msg.permissionMode !== undefined &&
          ![
            "default",
            "auto",
            "acceptEdits",
            "bypassPermissions",
            "plan",
          ].includes(String(msg.permissionMode))
        )
          return null;
        if (
          msg.executionMode !== undefined &&
          !["default", "acceptEdits", "fullAccess"].includes(
            String(msg.executionMode),
          )
        )
          return null;
        if (
          msg.approvalPolicy !== undefined &&
          !["untrusted", "on-request", "on-failure", "never"].includes(
            String(msg.approvalPolicy),
          )
        )
          return null;
        if (
          msg.approvalsReviewer !== undefined &&
          !["user", "auto_review", "guardian_subagent"].includes(
            String(msg.approvalsReviewer),
          )
        )
          return null;
        if (
          msg.codexPermissionsMode !== undefined &&
          !["default", "autoReview", "fullAccess", "custom"].includes(
            String(msg.codexPermissionsMode),
          )
        )
          return null;
        if (msg.planMode !== undefined && typeof msg.planMode !== "boolean")
          return null;
        if (
          msg.webSearchMode !== undefined &&
          !["disabled", "cached", "live"].includes(String(msg.webSearchMode))
        )
          return null;
        if (msg.additionalWritableRoots !== undefined) {
          if (!Array.isArray(msg.additionalWritableRoots)) return null;
          if (
            msg.additionalWritableRoots.some((root) => typeof root !== "string")
          )
            return null;
        }
        break;
      case "list_gallery":
        break;
      case "read_file": {
        if (
          !hasOnlyKeys([
            "type",
            "requestId",
            "projectPath",
            "filePath",
            "maxLines",
          ]) ||
          typeof msg.projectPath !== "string" ||
          msg.projectPath.trim().length === 0 ||
          msg.projectPath.length > 8192 ||
          typeof msg.filePath !== "string" ||
          msg.filePath.trim().length === 0 ||
          msg.filePath.length > 8192 ||
          (msg.requestId !== undefined &&
            (typeof msg.requestId !== "string" ||
              msg.requestId.length === 0 ||
              msg.requestId.length > 128)) ||
          (msg.maxLines !== undefined &&
            (!Number.isInteger(msg.maxLines) ||
              Number(msg.maxLines) < 1 ||
              Number(msg.maxLines) > 100_000))
        )
          return null;
        break;
      }
      case "read_artifact_source": {
        if (
          !hasOnlyKeys([
            "type",
            "requestId",
            "sessionId",
            "messageId",
            "artifactId",
            "filePath",
            "maxLines",
          ]) ||
          typeof msg.requestId !== "string" ||
          msg.requestId.length === 0 ||
          msg.requestId.length > 128 ||
          typeof msg.sessionId !== "string" ||
          msg.sessionId.length === 0 ||
          msg.sessionId.length > 256 ||
          typeof msg.messageId !== "string" ||
          msg.messageId.length === 0 ||
          msg.messageId.length > 512 ||
          typeof msg.artifactId !== "string" ||
          msg.artifactId.length === 0 ||
          msg.artifactId.length > 128 ||
          typeof msg.filePath !== "string" ||
          msg.filePath.trim().length === 0 ||
          msg.filePath.length > 8192 ||
          (msg.maxLines !== undefined &&
            (!Number.isInteger(msg.maxLines) ||
              Number(msg.maxLines) < 1 ||
              Number(msg.maxLines) > 100_000))
        )
          return null;
        break;
      }
      case "list_files":
        if (typeof msg.projectPath !== "string") return null;
        if (
          msg.requestId !== undefined &&
          (typeof msg.requestId !== "string" ||
            msg.requestId.length === 0 ||
            msg.requestId.length > 128)
        )
          return null;
        break;
      case "get_diff":
        if (typeof msg.projectPath !== "string") return null;
        if (msg.requestId !== undefined && typeof msg.requestId !== "string")
          return null;
        break;
      case "get_diff_image":
        if (typeof msg.projectPath !== "string") return null;
        if (typeof msg.filePath !== "string") return null;
        if (msg.requestId !== undefined && typeof msg.requestId !== "string")
          return null;
        if (
          msg.version !== "old" &&
          msg.version !== "new" &&
          msg.version !== "both"
        )
          return null;
        break;
      case "interrupt":
        break;
      case "list_project_history":
        break;
      case "remove_project_history":
        if (typeof msg.projectPath !== "string") return null;
        break;
      case "list_worktrees":
        if (typeof msg.projectPath !== "string") return null;
        break;
      case "remove_worktree":
        if (
          typeof msg.projectPath !== "string" ||
          typeof msg.worktreePath !== "string"
        )
          return null;
        break;
      case "rewind":
        if (
          typeof msg.sessionId !== "string" ||
          typeof msg.targetUuid !== "string"
        )
          return null;
        if (
          msg.mode !== "conversation" &&
          msg.mode !== "code" &&
          msg.mode !== "both"
        )
          return null;
        break;
      case "rewind_dry_run":
        if (
          typeof msg.sessionId !== "string" ||
          typeof msg.targetUuid !== "string"
        )
          return null;
        break;
      case "fork":
        if (
          typeof msg.sessionId !== "string" ||
          typeof msg.targetUuid !== "string" ||
          (msg.projectPath !== undefined && typeof msg.projectPath !== "string")
        )
          return null;
        if (
          msg.codexSourceId !== undefined &&
          !isValidWireIdentifier(msg.codexSourceId, 128)
        )
          return null;
        break;
      case "list_windows":
        break;
      case "take_screenshot":
        if (msg.mode !== "fullscreen" && msg.mode !== "window") return null;
        if (msg.mode === "window" && typeof msg.windowId !== "number")
          return null;
        if (typeof msg.projectPath !== "string") return null;
        break;
      case "get_debug_bundle":
        if (typeof msg.sessionId !== "string") return null;
        if (msg.traceLimit !== undefined && typeof msg.traceLimit !== "number")
          return null;
        if (
          msg.includeDiff !== undefined &&
          typeof msg.includeDiff !== "boolean"
        )
          return null;
        break;
      case "get_usage":
        break;
      case "list_recordings":
        break;
      case "get_recording":
        if (typeof msg.sessionId !== "string") return null;
        break;
      case "get_message_images":
        if (
          typeof msg.claudeSessionId !== "string" ||
          typeof msg.messageUuid !== "string"
        )
          return null;
        break;
      case "backup_prompt_history":
        if (typeof msg.data !== "string") return null;
        if (typeof msg.appVersion !== "string") return null;
        if (
          typeof msg.dbVersion !== "number" ||
          !Number.isInteger(msg.dbVersion)
        )
          return null;
        break;
      case "restore_prompt_history":
        break;
      case "get_prompt_history_backup_info":
        break;
      case "record_prompt_history":
        if (typeof msg.text !== "string") return null;
        if (typeof msg.clientId !== "string") return null;
        if (
          msg.projectPath !== undefined &&
          typeof msg.projectPath !== "string"
        )
          return null;
        if (msg.clientName !== undefined && typeof msg.clientName !== "string")
          return null;
        if (msg.sessionId !== undefined && typeof msg.sessionId !== "string")
          return null;
        if (msg.usedAt !== undefined && typeof msg.usedAt !== "string")
          return null;
        break;
      case "sync_prompt_history":
        if (
          msg.requestId !== undefined &&
          (typeof msg.requestId !== "string" ||
            msg.requestId.length === 0 ||
            msg.requestId.length > 128)
        )
          return null;
        if (typeof msg.clientId !== "string") return null;
        if (msg.clientName !== undefined && typeof msg.clientName !== "string")
          return null;
        if (
          msg.sinceRevision !== undefined &&
          (!Number.isInteger(msg.sinceRevision) ||
            Number(msg.sinceRevision) < 0)
        )
          return null;
        if (
          msg.entries !== undefined &&
          (!Array.isArray(msg.entries) ||
            !msg.entries.every(isPromptHistoryEntry))
        )
          return null;
        if (
          msg.includeDeleted !== undefined &&
          typeof msg.includeDeleted !== "boolean"
        )
          return null;
        break;
      case "mutate_prompt_history":
        if (!["favorite", "delete", "restore"].includes(String(msg.action)))
          return null;
        if (msg.id !== undefined && typeof msg.id !== "string") return null;
        if (msg.text !== undefined && typeof msg.text !== "string") return null;
        if (
          msg.projectPath !== undefined &&
          typeof msg.projectPath !== "string"
        )
          return null;
        if (msg.isFavorite !== undefined && typeof msg.isFavorite !== "boolean")
          return null;
        if (msg.updatedAt !== undefined && typeof msg.updatedAt !== "string")
          return null;
        break;
      case "import_prompt_history_v1":
        if (
          msg.requestId !== undefined &&
          (typeof msg.requestId !== "string" ||
            msg.requestId.length === 0 ||
            msg.requestId.length > 128)
        )
          return null;
        if (typeof msg.clientId !== "string") return null;
        if (msg.clientName !== undefined && typeof msg.clientName !== "string")
          return null;
        if (msg.mode !== undefined) return null;
        if (
          !Array.isArray(msg.entries) ||
          !msg.entries.every(isPromptHistoryEntry)
        )
          return null;
        break;
      case "refresh_branch":
        if (typeof msg.sessionId !== "string") return null;
        break;
      // ---- Git Operations (Phase 1-3) ----
      case "git_stage":
        if (typeof msg.projectPath !== "string") return null;
        if (!Array.isArray(msg.files) && !Array.isArray(msg.hunks)) return null;
        if (msg.hunks !== undefined) {
          if (!Array.isArray(msg.hunks)) return null;
          for (const h of msg.hunks as unknown[]) {
            if (!isValidClientHunkRef(h)) return null;
          }
        }
        break;
      case "git_unstage":
        if (typeof msg.projectPath !== "string") return null;
        break;
      case "git_unstage_hunks":
        if (typeof msg.projectPath !== "string") return null;
        if (!Array.isArray(msg.hunks) || msg.hunks.length === 0) return null;
        for (const h of msg.hunks as unknown[]) {
          if (!isValidClientHunkRef(h)) return null;
        }
        break;
      case "git_commit":
        if (
          !hasOnlyKeys([
            "type",
            "projectPath",
            "sessionId",
            "message",
            "autoGenerate",
          ])
        )
          return null;
        if (typeof msg.projectPath !== "string") return null;
        if (msg.sessionId !== undefined && typeof msg.sessionId !== "string")
          return null;
        if (msg.message !== undefined && typeof msg.message !== "string")
          return null;
        if (
          msg.autoGenerate !== undefined &&
          typeof msg.autoGenerate !== "boolean"
        )
          return null;
        break;
      case "git_push":
        if (!hasOnlyKeys(["type", "projectPath"])) return null;
        if (typeof msg.projectPath !== "string") return null;
        break;
      case "git_branches":
        if (!hasOnlyKeys(["type", "projectPath"])) return null;
        if (typeof msg.projectPath !== "string") return null;
        break;
      case "git_create_branch":
        if (typeof msg.projectPath !== "string") return null;
        if (typeof msg.name !== "string") return null;
        if (msg.checkout !== undefined && typeof msg.checkout !== "boolean")
          return null;
        break;
      case "git_checkout_branch":
        if (typeof msg.projectPath !== "string") return null;
        if (typeof msg.branch !== "string") return null;
        break;
      case "git_revert_file":
        if (typeof msg.projectPath !== "string") return null;
        if (!Array.isArray(msg.files)) return null;
        break;
      case "git_revert_hunks":
        if (typeof msg.projectPath !== "string") return null;
        if (!Array.isArray(msg.hunks) || msg.hunks.length === 0) return null;
        for (const h of msg.hunks as unknown[]) {
          if (!isValidClientHunkRef(h)) return null;
        }
        break;
      case "git_fetch":
        if (typeof msg.projectPath !== "string") return null;
        break;
      case "git_pull":
        if (typeof msg.projectPath !== "string") return null;
        break;
      case "git_status":
        if (typeof msg.projectPath !== "string") return null;
        if (msg.sessionId !== undefined && typeof msg.sessionId !== "string")
          return null;
        if (
          msg.includeRemote !== undefined &&
          typeof msg.includeRemote !== "boolean"
        )
          return null;
        break;
      case "git_remote_status":
        if (typeof msg.projectPath !== "string") return null;
        break;
      case "archive_session":
        if (
          typeof msg.sessionId !== "string" ||
          msg.sessionId.length === 0 ||
          msg.sessionId.length > 256
        )
          return null;
        if (msg.provider !== "claude" && msg.provider !== "codex") return null;
        if (
          msg.codexSourceId !== undefined &&
          !isValidWireIdentifier(msg.codexSourceId, 128)
        )
          return null;
        if (
          typeof msg.projectPath !== "string" ||
          msg.projectPath.length === 0 ||
          msg.projectPath.length > 16_384
        )
          return null;
        if (
          msg.requestId !== undefined &&
          (typeof msg.requestId !== "string" ||
            msg.requestId.length === 0 ||
            msg.requestId.length > 128)
        )
          return null;
        for (const [key, maxLength] of [
          ["name", 1_024],
          ["summary", 16_384],
          ["firstPrompt", 16_384],
          ["modified", 64],
        ] as const) {
          const value = msg[key];
          if (
            value !== undefined &&
            (typeof value !== "string" || value.length > maxLength)
          )
            return null;
        }
        break;
      case "list_archived_sessions":
        if (
          typeof msg.requestId !== "string" ||
          msg.requestId.length === 0 ||
          msg.requestId.length > 128
        )
          return null;
        break;
      case "unarchive_session":
        if (
          typeof msg.requestId !== "string" ||
          msg.requestId.length === 0 ||
          msg.requestId.length > 128 ||
          typeof msg.sessionId !== "string" ||
          msg.sessionId.length === 0 ||
          msg.sessionId.length > 256 ||
          (msg.provider !== "claude" && msg.provider !== "codex") ||
          typeof msg.projectPath !== "string" ||
          msg.projectPath.length === 0 ||
          msg.projectPath.length > 16_384
        )
          return null;
        if (
          msg.codexSourceId !== undefined &&
          !isValidWireIdentifier(msg.codexSourceId, 128)
        )
          return null;
        break;
      case "delete_session":
        if (
          typeof msg.requestId !== "string" ||
          msg.requestId.length === 0 ||
          msg.requestId.length > 128 ||
          typeof msg.sessionId !== "string" ||
          msg.sessionId.length === 0 ||
          msg.sessionId.length > 256 ||
          msg.provider !== "codex" ||
          typeof msg.projectPath !== "string" ||
          msg.projectPath.length === 0 ||
          msg.projectPath.length > 16_384 ||
          msg.confirmDescendantDeletion !== true
        )
          return null;
        if (
          msg.codexSourceId !== undefined &&
          !isValidWireIdentifier(msg.codexSourceId, 128)
        )
          return null;
        break;
      default:
        return null;
    }

    return msg as unknown as ClientMessage;
  } catch {
    return null;
  }
}
