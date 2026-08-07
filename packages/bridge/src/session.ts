import { randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import {
  pathToSlug,
  codexUserTurnUuid,
  isCodexUserTurnUuid,
  renameClaudeSession,
  renameCodexSession,
  saveCodexSessionAdditionalWritableRoots,
  saveCodexSessionProfile,
} from "./sessions-index.js";
import {
  SdkProcess,
  type StartOptions,
  type RewindFilesResult,
} from "./sdk-process.js";
import {
  CodexProcess,
  type CodexInputDeliveryEvent,
  type CodexSharedRuntimeMutationGuard,
  type CodexStartOptions,
} from "./codex-process.js";
import { mergeCodexGoalState } from "./codex-goal-controller.js";
import type {
  ServerMessage,
  ProcessStatus,
  AssistantToolUseContent,
  Provider,
  QueuedInputItem,
  CodexGoal,
} from "./parser.js";
import { isLocalFeatureServerMessage } from "./local-features/protocol.js";
import type { ImageRef, ImageStore } from "./image-store.js";
import type { GalleryStore, GalleryImageMeta } from "./gallery-store.js";
import { withDerivedCodexPermissionsMode } from "./codex-permissions.js";
import { createWorktree, worktreeExists } from "./worktree.js";
import type { WorktreeStore } from "./worktree-store.js";
import {
  buildAutoRenameTranscript,
  generateAutoRenameName,
} from "./auto-rename.js";
import type { ArtifactManager } from "./artifact-manager.js";
import { extractArtifactCandidates } from "./artifact-candidates.js";
import {
  MAX_ARTIFACTS_PER_MESSAGE,
  type ArtifactCandidate,
} from "./artifact-types.js";
import {
  InputDeliveryLedger,
  InputDeliveryLedgerError,
  MAX_DURABLE_QUEUED_INPUTS_PER_THREAD,
  type DurableInputDeliveryRecord,
  type DurableInputPayload,
  type InputDeliveryIdentity,
  type InputDeliveryScope,
} from "./input-delivery-ledger.js";

export interface WorktreeOptions {
  useWorktree?: boolean;
  worktreeBranch?: string;
  /** Reuse an existing worktree path (skip creation). */
  existingWorktreePath?: string;
}

export interface SessionInfo {
  id: string;
  process: SdkProcess | CodexProcess;
  provider: Provider;
  history: ServerMessage[];
  historyEntries: HistoryEntry[];
  historyRevision: number;
  historyLowWatermark: number;
  /**
   * Latest non-append history mutation. Clients behind this revision need a
   * snapshot because a delta cannot express an in-place message replacement.
   */
  historyMutationResetRevision?: number;
  /** Past conversation loaded from disk on resume (SessionHistoryMessage[]). */
  pastMessages?: unknown[];
  /**
   * True until the first Codex history response consumes the history already
   * loaded during resume. This also distinguishes a loaded empty history from
   * a session that has not loaded canonical history yet.
   */
  codexInitialHistoryPending?: boolean;
  projectPath: string;
  claudeSessionId?: string;
  /** Bridge runtime that was forked, when it is still known locally. */
  forkedFromSessionId?: string;
  /** Durable Codex thread that this session was forked from. */
  forkedFromThreadId?: string;
  /** Live-only auxiliary runtime omitted from the durable session catalog. */
  auxiliary?: {
    kind: "ephemeral_side_chat";
    parentSessionId: string;
    /** Stable provider thread identity; unlike parentSessionId it survives runtime detach. */
    parentProviderSessionId?: string;
  };
  /** User-assigned session name (via /rename or mobile rename). */
  name?: string;
  status: ProcessStatus;
  createdAt: Date;
  lastActivityAt: Date;
  gitBranch: string;
  /** If this session uses a worktree, the path to it. */
  worktreePath?: string;
  /** Branch name of the worktree. */
  worktreeBranch?: string;
  /** Codex-specific settings used to start this session (for resume). */
  codexSettings?: {
    profile?: string;
    approvalPolicy?: string;
    approvalsReviewer?: string;
    codexPermissionsMode?: string;
    sandboxMode?: string;
    model?: string;
    modelReasoningEffort?: string;
    serviceTier?: string;
    networkAccessEnabled?: boolean;
    webSearchMode?: string;
    additionalWritableRoots?: string[];
    autoReviewDisabledByPolicy?: boolean | null;
  };
  /** Claude sandbox enabled state (for resume). */
  sandboxEnabled?: boolean;
  /** Canonical bounded FIFO of Codex inputs waiting for future turns. */
  codexQueuedInputs?: QueuedCodexInput[];
  /**
   * Legacy alias for the FIFO head. Kept during the additive protocol
   * transition so older integrations and test doubles remain compatible.
   */
  codexQueuedInput?: QueuedCodexInput;
  /**
   * Bounded in-memory delivery receipts keyed by Mobile clientMessageId.
   * They survive an in-process runtime replacement, but are not a disk queue.
   */
  inputDeliveryReceipts?: Map<string, InputDeliveryReceipt>;
  /** Latest Codex goal state. Kept out of chat history. */
  codexGoal?: CodexGoal | null;
  /** Highest non-empty Goal updatedAt observed, retained across a clear. */
  codexGoalUpdatedAt?: number;
  /** Latest Bridge-local Goal RPC/notification ordering token. */
  codexGoalOperationSequence?: number;
  /** Runtime-probed support for the app-server Goal RPC family. */
  codexGoalControlSupported?: boolean;
  /** Blocks input and approval actions during an explicit permission restart. */
  permissionRestartInProgress?: boolean;
  /** Shared app-server attachment lifecycle; absent for private/legacy runs. */
  codexAttachmentState?: "connected" | "reconciling" | "unavailable";
  /** Synthetic Codex user UUIDs waiting for their app-server echo. */
  pendingCodexUserEchoUuids?: Set<string>;
  /** Raw Codex app-server user item ids mapped to valid ccpocket turn UUIDs. */
  codexUserTurnUuidByRawId?: Map<string, string>;
  /** Last Bridge history seq covered by the canonical Codex thread snapshot. */
  codexCanonicalHistoryRevision?: number;
  /** Latest canonical/live Codex user turn used to scope residual assistants. */
  codexLiveHistoryUserKey?: string;
  /** Stable live assistant identity to its Codex user turn across baselines. */
  codexLiveAssistantUserKeyByIdentity?: Map<string, string>;
  /** Monotonic revision that invalidates deltas from an older Codex baseline. */
  codexHistoryResetRevision?: number;
  /** Latest Codex user input, retained even when the history tail is trimmed. */
  codexLatestUserInput?: Extract<ServerMessage, { type: "user_input" }>;
  /** Last merged Codex snapshot, retained to preserve live event ordering. */
  codexOrderedHistoryEntries?: HistoryEntry[];
  /** Bridge history revision covered by codexOrderedHistoryEntries. */
  codexOrderedHistoryRevision?: number;
  /** Whether to generate a session name after the first completed turn. */
  autoRename?: boolean;
  /** Prevents automatic rename from running more than once. */
  autoRenameAttempted?: boolean;
}

/** Roots explicitly in scope for automatic non-image artifact references. */
export function artifactCandidateRootsForSession(
  session: SessionInfo,
): string[] {
  return [
    ...new Set(
      [
        session.worktreePath ?? session.projectPath,
        session.projectPath,
        ...(session.codexSettings?.additionalWritableRoots ?? []),
      ]
        .map((root) => root.trim())
        .filter((root) => root.length > 0),
    ),
  ];
}

export interface HistoryEntry {
  seq: number;
  message: ServerMessage;
}

export type HistoryDeltaResult =
  | {
      kind: "delta";
      fromSeq: number;
      toSeq: number;
      entries: HistoryEntry[];
    }
  | {
      kind: "snapshot";
      fromSeq: number;
      toSeq: number;
      entries: HistoryEntry[];
      reason: "compacted" | "reset";
    };

export interface QueuedCodexInput extends QueuedInputItem {
  userMessageUuid?: string;
  clientMessageId?: string;
  images?: Array<{
    base64: string;
    mimeType: string;
  }>;
  imageRefs?: ImageRef[];
  /** Internal fence for a crash recovery replay; never projected to Mobile. */
  recoveryRequiresClientUserMessageId?: boolean;
}

export type InputDeliveryStage =
  "bridge_accepted" | "provider_accepted" | "provider_rejected";

export interface InputDeliveryReceipt {
  clientMessageId: string;
  stage: InputDeliveryStage;
  acceptedSeq: number;
  queued: boolean;
  provider?: "codex";
  method?: "turn/start" | "turn/steer";
  occurredAt: string;
  clientUserMessageIdAccepted?: boolean;
  error?: string;
}

export interface SessionSummary {
  id: string;
  provider: Provider;
  projectPath: string;
  claudeSessionId?: string;
  forkedFromSessionId?: string;
  forkedFromThreadId?: string;
  /** User-assigned session name. */
  name?: string;
  status: ProcessStatus;
  createdAt: string;
  lastActivityAt: string;
  gitBranch: string;
  lastMessage: string;
  worktreePath?: string;
  worktreeBranch?: string;
  permissionMode?: string;
  executionMode?: string;
  planMode?: boolean;
  model?: string;
  codexSettings?: {
    profile?: string;
    approvalPolicy?: string;
    approvalsReviewer?: string;
    codexPermissionsMode?: string;
    sandboxMode?: string;
    model?: string;
    modelReasoningEffort?: string;
    serviceTier?: string;
    networkAccessEnabled?: boolean;
    webSearchMode?: string;
    additionalWritableRoots?: string[];
    autoReviewDisabledByPolicy?: boolean | null;
  };
  agentNickname?: string;
  agentRole?: string;
  /** Claude sandbox enabled state. */
  sandboxEnabled?: boolean;
  pendingPermission?: {
    toolUseId: string;
    toolName: string;
    input: Record<string, unknown>;
  };
  queuedInput?: QueuedInputItem;
  queuedInputs?: QueuedInputItem[];
  queuedInputLimit?: number;
  /** Runtime-probed support for app-server next-turn permission settings. */
  codexPermissionApplyStrategySupported?: boolean;
  /** Runtime-probed support for the experimental native Codex Plan preset. */
  codexNativePlanModeSupported?: boolean;
  /** Runtime-probed support for app-server Goal management. */
  codexGoalControlSupported?: boolean | null;
}

interface SessionCreateInternalOptions {
  replaceSessionId?: string;
  replacementReadyTimeoutMs?: number;
  replacementStillValid?: () => boolean;
  replacementSignal?: AbortSignal;
  onReplacementCommitted?: (session: SessionInfo) => void;
  onReplacementReady?: () => void;
  onReplacementFailed?: (error: Error) => void;
  auxiliary?: SessionInfo["auxiliary"];
}

export const MAX_HISTORY_PER_SESSION = 100;
export const MAX_CODEX_QUEUED_INPUTS =
  MAX_DURABLE_QUEUED_INPUTS_PER_THREAD;
const MAX_IDLE_SESSIONS = 30;
const MAX_INPUT_DELIVERY_RECEIPTS_PER_SESSION = 512;
const SHARED_ATTACHMENT_RETRY_INITIAL_MS = 250;
const SHARED_ATTACHMENT_RETRY_MAX_MS = 10_000;
const SHARED_ATTACHMENT_READY_TIMEOUT_MS = 30_000;

interface SharedCodexAttachmentRecovery {
  generation: number;
  attempt: number;
  session: SessionInfo;
  timer?: ReturnType<typeof setTimeout>;
  replacementAbort?: AbortController;
}

export type GalleryImageCallback = (meta: GalleryImageMeta) => void;
export type SessionUpdatedCallback = (sessionId: string) => void;

/** Optional module-neutral hooks around queued Codex input promotion. */
export interface CodexQueueDrainHooks {
  canDrain?(session: SessionInfo): boolean;
  onBlocked?(session: SessionInfo): void;
}

function mergeCodexSettings(
  current: SessionInfo["codexSettings"],
  msg: Extract<ServerMessage, { type: "system" }>,
): SessionInfo["codexSettings"] {
  const model = sanitizeCodexModel(msg.model);
  const hasRuntimePermissionUpdate =
    msg.approvalPolicy !== undefined ||
    msg.approvalsReviewer !== undefined ||
    msg.sandboxMode !== undefined;
  const currentSettings = { ...(current ?? {}) };
  if (hasRuntimePermissionUpdate && msg.codexPermissionsMode === undefined) {
    delete currentSettings.codexPermissionsMode;
  }
  const next = {
    ...currentSettings,
    ...(msg.approvalPolicy !== undefined
      ? { approvalPolicy: msg.approvalPolicy }
      : {}),
    ...(msg.approvalsReviewer !== undefined
      ? { approvalsReviewer: msg.approvalsReviewer }
      : {}),
    ...(msg.codexPermissionsMode !== undefined
      ? { codexPermissionsMode: msg.codexPermissionsMode }
      : {}),
    ...(msg.sandboxMode !== undefined ? { sandboxMode: msg.sandboxMode } : {}),
    ...(model !== undefined ? { model } : {}),
    ...(msg.modelReasoningEffort !== undefined
      ? { modelReasoningEffort: msg.modelReasoningEffort }
      : {}),
    ...(msg.serviceTier !== undefined ? { serviceTier: msg.serviceTier } : {}),
    ...(msg.networkAccessEnabled !== undefined
      ? { networkAccessEnabled: msg.networkAccessEnabled }
      : {}),
    ...(msg.webSearchMode !== undefined
      ? { webSearchMode: msg.webSearchMode }
      : {}),
    ...(msg.additionalWritableRoots !== undefined
      ? { additionalWritableRoots: msg.additionalWritableRoots }
      : {}),
  };

  return Object.values(next).some((value) => value !== undefined)
    ? next
    : current;
}

function equalCodexSettings(
  left: SessionInfo["codexSettings"],
  right: SessionInfo["codexSettings"],
): boolean {
  if (left === right) return true;
  if (!left || !right) return false;
  const leftRoots = left.additionalWritableRoots;
  const rightRoots = right.additionalWritableRoots;
  return (
    left.profile === right.profile &&
    left.approvalPolicy === right.approvalPolicy &&
    left.approvalsReviewer === right.approvalsReviewer &&
    left.codexPermissionsMode === right.codexPermissionsMode &&
    left.sandboxMode === right.sandboxMode &&
    left.model === right.model &&
    left.modelReasoningEffort === right.modelReasoningEffort &&
    left.serviceTier === right.serviceTier &&
    left.networkAccessEnabled === right.networkAccessEnabled &&
    left.webSearchMode === right.webSearchMode &&
    left.autoReviewDisabledByPolicy === right.autoReviewDisabledByPolicy &&
    (leftRoots === rightRoots ||
      (leftRoots !== undefined &&
        rightRoots !== undefined &&
        leftRoots.length === rightRoots.length &&
        leftRoots.every((root, index) => root === rightRoots[index])))
  );
}

function sanitizeCodexModel(model: unknown): string | undefined {
  if (typeof model !== "string") return undefined;
  const normalized = model.trim();
  if (!normalized || normalized === "codex") return undefined;
  return normalized;
}

export function publicQueuedInput(
  item?: QueuedCodexInput,
  receipt?: InputDeliveryReceipt,
): QueuedInputItem | undefined {
  if (!item) return undefined;
  const matchingReceipt =
    item.clientMessageId && receipt?.clientMessageId === item.clientMessageId
      ? receipt
      : undefined;
  return {
    itemId: item.itemId,
    text: item.text,
    createdAt: item.createdAt,
    ...(item.updatedAt ? { updatedAt: item.updatedAt } : {}),
    ...(item.clientMessageId ? { clientMessageId: item.clientMessageId } : {}),
    ...(matchingReceipt ? { deliveryStage: matchingReceipt.stage } : {}),
    ...(matchingReceipt?.error ? { deliveryError: matchingReceipt.error } : {}),
    ...(item.imageCount ? { imageCount: item.imageCount } : {}),
    ...(item.skills?.length ? { skills: item.skills } : {}),
    ...(item.mentions?.length ? { mentions: item.mentions } : {}),
  };
}

export function codexQueuedInputsForSession(
  session: Pick<SessionInfo, "codexQueuedInputs" | "codexQueuedInput">,
): QueuedCodexInput[] {
  if (session.codexQueuedInputs) return session.codexQueuedInputs;
  return session.codexQueuedInput ? [session.codexQueuedInput] : [];
}

function structuredImagePaths(candidates: ArtifactCandidate[]): string[] {
  return [
    ...new Set(
      candidates
        .filter((candidate) => candidate.source === "image_generation")
        .map((candidate) => candidate.localPath),
    ),
  ].slice(0, MAX_ARTIFACTS_PER_MESSAGE);
}

export class SessionManager {
  private sessions = new Map<string, SessionInfo>();
  private retiredSessions = new WeakSet<SessionInfo>();
  private onMessage: (sessionId: string, msg: ServerMessage) => void;
  private imageStore: ImageStore | null;
  private galleryStore: GalleryStore | null;
  private onGalleryImage: GalleryImageCallback | null;
  private worktreeStore: WorktreeStore | null;
  private onSessionUpdated: SessionUpdatedCallback | null;
  private artifactManager: ArtifactManager | null;
  private codexQueueDrainHooks: CodexQueueDrainHooks;
  private codexSharedRuntimeMutationAllowed?: CodexSharedRuntimeMutationGuard;
  private readonly inputDeliveryLedger?: InputDeliveryLedger;
  private readonly inputDeliveryScope?: InputDeliveryScope;
  private readonly inputDeliveryRestoredThreads = new WeakMap<
    SessionInfo,
    string
  >();
  private readonly recoveredReceiptEmission = new WeakSet<SessionInfo>();
  private readonly recoveredReceiptsToEmit = new WeakMap<
    SessionInfo,
    InputDeliveryReceipt[]
  >();
  private readonly codexQueueDrainInFlight = new Map<
    string,
    QueuedCodexInput
  >();
  private sharedAttachmentGeneration = 0;
  private sharedAttachmentRecoveries = new Map<
    string,
    SharedCodexAttachmentRecovery
  >();

  /** Cache completion entities per provider and effective cwd. */
  private commandCache = new Map<
    string,
    {
      slashCommands: string[];
      skills: string[];
      skillMetadata?: Array<Record<string, unknown>>;
      apps: string[];
      appMetadata?: Array<Record<string, unknown>>;
      plugins: string[];
      pluginMetadata?: Array<Record<string, unknown>>;
    }
  >();

  constructor(
    onMessage: (sessionId: string, msg: ServerMessage) => void,
    imageStore?: ImageStore,
    galleryStore?: GalleryStore,
    onGalleryImage?: GalleryImageCallback,
    worktreeStore?: WorktreeStore,
    onSessionUpdated?: SessionUpdatedCallback,
    artifactManager?: ArtifactManager,
    codexQueueDrainHooks: CodexQueueDrainHooks = {},
    codexSharedRuntimeMutationAllowed?: CodexSharedRuntimeMutationGuard,
    inputDelivery?: {
      ledger: InputDeliveryLedger;
      scope: InputDeliveryScope;
    },
  ) {
    this.onMessage = onMessage;
    this.imageStore = imageStore ?? null;
    this.galleryStore = galleryStore ?? null;
    this.onGalleryImage = onGalleryImage ?? null;
    this.worktreeStore = worktreeStore ?? null;
    this.onSessionUpdated = onSessionUpdated ?? null;
    this.artifactManager = artifactManager ?? null;
    this.codexQueueDrainHooks = codexQueueDrainHooks;
    this.codexSharedRuntimeMutationAllowed = codexSharedRuntimeMutationAllowed;
    this.inputDeliveryLedger = inputDelivery?.ledger;
    this.inputDeliveryScope = inputDelivery?.scope;
  }

  /**
   * Attach safe, opaque artifact refs while preserving provider text exactly.
   * This method is shared by live messages and canonical history replay.
   */
  enrichArtifactsForSession(
    session: SessionInfo,
    message: ServerMessage,
    detachedCandidates?: ArtifactCandidate[],
  ): ServerMessage | Promise<ServerMessage> {
    const embeddedCandidates =
      message.type === "tool_result" ? (message.artifactCandidates ?? []) : [];
    let cleanMessage = message;
    if (message.type === "tool_result" && "artifactCandidates" in message) {
      const { artifactCandidates: _, ...clean } = message;
      cleanMessage = clean as ServerMessage;
    }

    if (session.provider !== "codex" || !this.artifactManager) {
      return cleanMessage;
    }

    const ownerId =
      session.claudeSessionId ??
      (session.process instanceof CodexProcess
        ? (session.process.sessionId ?? undefined)
        : undefined);
    if (!ownerId) return cleanMessage;

    const candidates = [...(detachedCandidates ?? []), ...embeddedCandidates];
    let messageId: string | undefined;
    if (cleanMessage.type === "assistant") {
      messageId = cleanMessage.message.id;
      if (detachedCandidates === undefined) {
        try {
          for (const [
            index,
            content,
          ] of cleanMessage.message.content.entries()) {
            if (content.type !== "text") continue;
            candidates.push(
              ...extractArtifactCandidates(content.text, {
                source: "assistant_markdown",
                textContentIndex: index,
                platform: process.platform,
              }),
            );
          }
        } catch {
          return cleanMessage;
        }
      }
    } else if (cleanMessage.type === "tool_result") {
      messageId = cleanMessage.toolUseId;
    } else {
      return cleanMessage;
    }

    if (!messageId || candidates.length === 0) return cleanMessage;
    return this.artifactManager
      .registerCandidates({
        ownerId,
        messageId,
        cwd: session.worktreePath ?? session.projectPath,
        candidateRoots: artifactCandidateRootsForSession(session),
        candidates,
      })
      .then((artifacts) =>
        artifacts.length > 0
          ? ({ ...cleanMessage, artifacts } as ServerMessage)
          : cleanMessage,
      )
      .catch((error: unknown) => {
        const detail = error instanceof Error ? error.name : "unknown_error";
        console.warn(
          `[artifact] Enrichment failed for ${cleanMessage.type} in session ${session.id}: ${detail}`,
        );
        return cleanMessage;
      });
  }

  /**
   * Stage a fresh app-server for the same durable Codex thread and keep the
   * public Bridge session id stable. The old runtime remains authoritative
   * until the replacement reaches input_ready; bootstrap failure is therefore
   * non-destructive and callers can retry safely.
   */
  async replaceCodexSession(
    sessionId: string,
    projectPath: string,
    pastMessages: unknown[],
    worktreeOpts: WorktreeOptions | undefined,
    codexOptions: CodexStartOptions,
    replacementReadyTimeoutMs?: number,
    replacementStillValid?: () => boolean,
    replacementSignal?: AbortSignal,
    onReplacementCommitted?: (session: SessionInfo) => void,
  ): Promise<string> {
    return new Promise<string>((resolve, reject) => {
      try {
        this.create(
          projectPath,
          undefined,
          pastMessages,
          worktreeOpts,
          "codex",
          codexOptions,
          {
            replaceSessionId: sessionId,
            replacementReadyTimeoutMs,
            replacementStillValid,
            replacementSignal,
            onReplacementCommitted,
            onReplacementReady: () => resolve(sessionId),
            onReplacementFailed: reject,
          },
        );
      } catch (error) {
        reject(error instanceof Error ? error : new Error(String(error)));
      }
    });
  }

  create(
    projectPath: string,
    options?: StartOptions,
    pastMessages?: unknown[],
    worktreeOpts?: WorktreeOptions,
    provider?: Provider,
    codexOptions?: CodexStartOptions,
    internal?: SessionCreateInternalOptions,
  ): string {
    const replacementSession = internal?.replaceSessionId
      ? this.sessions.get(internal.replaceSessionId)
      : undefined;
    if (
      internal?.replaceSessionId &&
      (!replacementSession ||
        replacementSession.provider !== "codex" ||
        provider !== "codex")
    ) {
      throw new Error("Cannot replace a missing or non-Codex session");
    }
    const id = internal?.replaceSessionId ?? randomUUID().slice(0, 8);
    const effectiveProvider = provider ?? "claude";
    const proc =
      effectiveProvider === "codex"
        ? new CodexProcess(
            process.platform,
            this.codexSharedRuntimeMutationAllowed,
          )
        : new SdkProcess();

    // Handle worktree: reuse existing or create new
    let wtPath: string | undefined;
    let wtBranch: string | undefined;
    if (worktreeOpts?.existingWorktreePath) {
      // Reuse an existing worktree (resume case)
      wtPath = worktreeOpts.existingWorktreePath;
      wtBranch = worktreeOpts.worktreeBranch;
      console.log(`[session] Reusing existing worktree at ${wtPath}`);
    } else if (worktreeOpts?.useWorktree) {
      // Create a new worktree
      try {
        const wt = createWorktree(projectPath, id, worktreeOpts.worktreeBranch);
        wtPath = wt.worktreePath;
        wtBranch = wt.branch;
        console.log(
          `[session] Created worktree at ${wtPath} (branch: ${wtBranch})`,
        );
      } catch (err) {
        console.error(`[session] Failed to create worktree:`, err);
        // Fall through to use original projectPath
      }
    }

    // Use worktree path as cwd if available
    const effectiveCwd = wtPath ?? projectPath;

    let gitBranch = "";
    try {
      gitBranch = execFileSync("git", ["rev-parse", "--abbrev-ref", "HEAD"], {
        cwd: effectiveCwd,
        encoding: "utf-8",
      }).trim();
    } catch {
      /* not a git repo */
    }

    const session: SessionInfo = {
      id,
      process: proc,
      provider: effectiveProvider,
      history: [],
      historyEntries: [],
      historyRevision: 0,
      historyLowWatermark: 1,
      pastMessages:
        pastMessages && pastMessages.length > 0 ? pastMessages : undefined,
      projectPath,
      status: "starting",
      createdAt: new Date(),
      lastActivityAt: new Date(),
      gitBranch,
      worktreePath: wtPath,
      worktreeBranch: wtBranch,
      autoRename:
        options?.autoRename === true &&
        !options.sessionId &&
        !options.continueMode &&
        !codexOptions?.threadId,
      // Pre-populate claudeSessionId for resumed sessions so that get_history
      // can return it immediately (before the SDK sends a system/result event).
      claudeSessionId: options?.sessionId,
      forkedFromSessionId: replacementSession?.forkedFromSessionId,
      forkedFromThreadId: replacementSession?.forkedFromThreadId,
      auxiliary: internal?.auxiliary,
      ...(effectiveProvider === "codex" && codexOptions?.sharedRuntimeAttach
        ? { codexAttachmentState: "reconciling" as const }
        : {}),
    };
    const ownsRuntimeSlot = (): boolean =>
      !this.retiredSessions.has(session) &&
      (replacementSession === undefined || this.sessions.get(id) === session);
    let sharedAttachmentEstablished = false;
    let replacementSettled = false;
    let replacementReadyTimer: ReturnType<typeof setTimeout> | undefined;
    let replacementAbortListener: (() => void) | undefined;
    const cleanupReplacementAbort = (): void => {
      if (!replacementAbortListener) return;
      internal?.replacementSignal?.removeEventListener(
        "abort",
        replacementAbortListener,
      );
      replacementAbortListener = undefined;
    };
    const failReplacement = (error: Error): void => {
      if (!replacementSession || replacementSettled) return;
      replacementSettled = true;
      if (replacementReadyTimer) clearTimeout(replacementReadyTimer);
      cleanupReplacementAbort();
      proc.removeAllListeners();
      proc.stop();
      internal?.onReplacementFailed?.(error);
    };
    const commitReplacement = (): void => {
      if (!replacementSession || replacementSettled) return;
      if (internal?.replacementStillValid?.() === false) {
        failReplacement(
          new Error("Codex replacement invalidated before it became ready"),
        );
        return;
      }
      if (this.sessions.get(id) !== replacementSession) {
        failReplacement(
          new Error("Codex session changed before its replacement was ready"),
        );
        return;
      }
      replacementSettled = true;
      if (replacementReadyTimer) clearTimeout(replacementReadyTimer);
      cleanupReplacementAbort();

      // Recapture mutable phone-owned state at the atomic swap boundary. Queue
      // edits/cancels made while app-server bootstrapped must land on the fresh
      // runtime before its input_ready drain listener runs.
      session.name = replacementSession.name;
      session.autoRename = replacementSession.autoRename;
      session.autoRenameAttempted = replacementSession.autoRenameAttempted;
      // Preserve the queue object's identity across the atomic swap. The steer
      // path uses that identity as its compare-and-clear revision, so an edit
      // or cancel racing an in-flight RPC cannot be mistaken for the snapshot
      // that was actually sent.
      this.setCodexQueuedInputs(session, [
        ...codexQueuedInputsForSession(replacementSession),
      ]);
      session.inputDeliveryReceipts =
        replacementSession.inputDeliveryReceipts ??
        session.inputDeliveryReceipts;
      // Keep the old public session's incremental history authoritative until
      // the fresh canonical history is consumed. The replacement preflight
      // already loaded the new durable history into `pastMessages`; marking it
      // pending lets the next history request reconcile both sides without a
      // second provider read or a revision rollback.
      session.history = [...replacementSession.history];
      session.historyEntries = replacementSession.historyEntries.map(
        (entry) => ({ ...entry }),
      );
      session.historyRevision = replacementSession.historyRevision;
      session.historyLowWatermark = replacementSession.historyLowWatermark;
      session.historyMutationResetRevision =
        replacementSession.historyMutationResetRevision;
      session.codexInitialHistoryPending =
        codexOptions?.sharedRuntimeAttach == null;
      // Carry the user-echo dedup state across the swap. Losing it made the
      // app-server echo of an already-published user turn look brand new on
      // the fresh runtime, re-inserting the same input into history.
      session.codexLatestUserInput = replacementSession.codexLatestUserInput;
      session.pendingCodexUserEchoUuids =
        replacementSession.pendingCodexUserEchoUuids;
      if (replacementSession.codexUserTurnUuidByRawId) {
        // The staged seed may know turns the rollout persisted after the old
        // runtime seeded, while the old runtime holds live-echo mappings the
        // rollout has not flushed yet. Merge, letting the live mapping win:
        // its uuids are the ones clients have already rendered.
        const merged = new Map(session.codexUserTurnUuidByRawId ?? []);
        for (const [
          rawId,
          uuid,
        ] of replacementSession.codexUserTurnUuidByRawId) {
          merged.set(rawId, uuid);
        }
        session.codexUserTurnUuidByRawId = merged;
      }
      session.codexGoal = replacementSession.codexGoal;
      session.codexGoalUpdatedAt = replacementSession.codexGoalUpdatedAt;
      session.codexGoalOperationSequence =
        replacementSession.codexGoalOperationSequence;
      session.codexGoalControlSupported =
        replacementSession.codexGoalControlSupported;
      if (codexOptions?.sharedRuntimeAttach != null) {
        // A shared-runtime replacement is deliberately settings-neutral: its
        // thread/resume request must not replay Mobile's cached settings into
        // the daemon. The staged system/init frame is also ignored until the
        // atomic public-session swap. Preserve the last authoritative display
        // facts from the stable SessionInfo so recovery does not erase model,
        // effort, speed, or permission metadata while leaving app-server state
        // untouched.
        session.codexSettings = replacementSession.codexSettings
          ? {
              ...replacementSession.codexSettings,
              ...(replacementSession.codexSettings.additionalWritableRoots
                ? {
                    additionalWritableRoots: [
                      ...replacementSession.codexSettings
                        .additionalWritableRoots,
                    ],
                  }
                : {}),
            }
          : undefined;
      }
      session.codexCanonicalHistoryRevision =
        replacementSession.codexCanonicalHistoryRevision;
      session.codexLiveHistoryUserKey =
        replacementSession.codexLiveHistoryUserKey;
      session.codexLiveAssistantUserKeyByIdentity =
        replacementSession.codexLiveAssistantUserKeyByIdentity === undefined
          ? undefined
          : new Map(replacementSession.codexLiveAssistantUserKeyByIdentity);
      session.codexHistoryResetRevision =
        replacementSession.codexHistoryResetRevision;
      session.codexOrderedHistoryEntries =
        replacementSession.codexOrderedHistoryEntries?.map((entry) => ({
          ...entry,
        }));
      session.codexOrderedHistoryRevision =
        replacementSession.codexOrderedHistoryRevision;
      // The staged runtime's initial idle status event was intentionally
      // ignored while the old runtime owned the public session slot.
      // `input_ready` is the authoritative idle boundary; publish that state
      // as part of the same atomic swap before a queued handoff is drained.
      session.status =
        (proc as CodexProcess & { status?: ProcessStatus }).status ?? "idle";
      session.lastActivityAt = replacementSession.lastActivityAt;
      if ((proc as CodexProcess).usesSharedRuntimeTopology) {
        // This listener itself is running for input_ready, so attachment is
        // already established. Record that fact before publishing the fresh
        // session: a synchronous follow-up exit must be eligible for another
        // recovery generation rather than looking like a bootstrap failure.
        sharedAttachmentEstablished = true;
        session.codexAttachmentState = "connected";
      }

      this.retiredSessions.add(replacementSession);
      this.sessions.set(id, session);
      // Recovery coordination must hand off its generation synchronously at
      // the atomic swap boundary. Waiting for the replacement Promise allows
      // input_ready followed immediately by exit to be lost behind the old
      // recovery record.
      internal?.onReplacementCommitted?.(session);
      replacementSession.process.removeAllListeners();
      replacementSession.process.stop();
      internal?.onReplacementReady?.();
      this.onSessionUpdated?.(id);
      this.evictStaleIdleSessions();
    };
    if (replacementSession && internal?.replacementSignal) {
      if (internal.replacementSignal.aborted) {
        proc.stop();
        throw new Error("Codex replacement was cancelled");
      }
      replacementAbortListener = () =>
        failReplacement(new Error("Codex replacement was cancelled"));
      internal.replacementSignal.addEventListener(
        "abort",
        replacementAbortListener,
        { once: true },
      );
    }
    if (effectiveProvider === "codex") {
      this.seedCodexPastUserTurnUuidMap(session);
    }

    // Cache tool_use id → name for enriching tool_result messages
    const toolUseNames = new Map<string, string>();

    // Provider EventEmitters do not await async listeners. Keep all message
    // enrichment/history mutations on one chain so an awaited file inspection
    // cannot let a later result/status overtake the assistant message.
    let messageProcessing: Promise<void> | null = null;
    const trackMessageWork = (work: Promise<void>): void => {
      // Swallow (and log) failures so the stored promise always resolves:
      // a rejected chain would skip every later .then(processMessage) and
      // permanently stall this session's pipeline — and, once nothing else
      // chains onto it, crash the process as an unhandled rejection.
      const tracked = work
        .catch((err) => {
          console.error(
            `[session] Message pipeline step failed for session ${id}:`,
            err,
          );
        })
        .finally(() => {
          if (messageProcessing === tracked) messageProcessing = null;
        });
      messageProcessing = tracked;
    };
    proc.on("message", (msg) => {
      if (!ownsRuntimeSlot()) return;
      // Detach provider-local paths before any asynchronous operation. For
      // assistant text, AST extraction is synchronous and lets us retain the
      // legacy synchronous fast path when no artifact exists.
      let artifactCandidates: ArtifactCandidate[] = [];
      if (msg.type === "tool_result" && msg.artifactCandidates) {
        artifactCandidates = [...msg.artifactCandidates];
        const { artifactCandidates: _, ...clean } = msg;
        msg = clean as ServerMessage;
      } else if (
        effectiveProvider === "codex" &&
        this.artifactManager !== null &&
        msg.type === "assistant"
      ) {
        try {
          for (const [index, content] of msg.message.content.entries()) {
            if (content.type !== "text") continue;
            artifactCandidates.push(
              ...extractArtifactCandidates(content.text, {
                source: "assistant_markdown",
                textContentIndex: index,
                platform: process.platform,
              }),
            );
          }
        } catch {
          artifactCandidates = [];
        }
      }

      const artifactWorkMayAwait =
        effectiveProvider === "codex" &&
        this.artifactManager !== null &&
        artifactCandidates.length > 0 &&
        Boolean(
          session.claudeSessionId ||
          (proc instanceof CodexProcess && proc.sessionId),
        );
      let imageWorkMayAwait = false;
      if (msg.type === "tool_result" && this.imageStore) {
        try {
          const generatedPaths = structuredImagePaths(artifactCandidates);
          imageWorkMayAwait =
            (this.artifactManager !== null && generatedPaths.length > 0) ||
            this.imageStore.extractImagePaths(msg.content).length > 0 ||
            Boolean(
              this.galleryStore &&
              Array.isArray(msg.rawContentBlocks) &&
              msg.rawContentBlocks.some((block) => {
                if (!block || typeof block !== "object") return false;
                const record = block as Record<string, unknown>;
                const source = record.source as
                  Record<string, unknown> | undefined;
                return (
                  record.type === "image" &&
                  source?.type === "base64" &&
                  typeof source.data === "string" &&
                  typeof source.media_type === "string"
                );
              }),
            );
        } catch {
          // The normal handler below owns error reporting and fail-open logic.
          imageWorkMayAwait = false;
        }
      }

      const processMessage = async (): Promise<void> => {
        try {
          session.lastActivityAt = new Date();
          const previousProviderSessionId = session.claudeSessionId;
          let codexSettingsChanged = false;

          if (msg.type === "goal_state") {
            const advancesGoalSequence =
              msg.goalOperationSequence !== undefined &&
              (session.codexGoalOperationSequence === undefined ||
                msg.goalOperationSequence > session.codexGoalOperationSequence);
            if (
              msg.goalOperationSequence !== undefined &&
              session.codexGoalOperationSequence !== undefined &&
              msg.goalOperationSequence < session.codexGoalOperationSequence
            ) {
              return;
            }
            if (msg.goalOperationSequence !== undefined) {
              session.codexGoalOperationSequence = msg.goalOperationSequence;
            }
            const merged = mergeCodexGoalState(
              session.codexGoal,
              msg.goal,
              session.codexGoalUpdatedAt,
              advancesGoalSequence,
            );
            session.codexGoalUpdatedAt = merged.updatedAt;
            if (!merged.accepted) return;
            session.codexGoal = merged.goal;
            this.onMessage(id, { ...msg, goal: merged.goal });
            return;
          }

          if (isLocalFeatureServerMessage(msg)) {
            this.onMessage(id, msg);
            return;
          }

          if (
            msg.type === "system" &&
            (msg.subtype === "init" || msg.subtype === "supported_commands") &&
            (msg.slashCommands ||
              msg.skills ||
              msg.skillMetadata ||
              msg.apps ||
              msg.appMetadata ||
              msg.plugins ||
              msg.pluginMetadata)
          ) {
            const commandCacheKey = this.commandCacheKey(
              effectiveProvider,
              effectiveCwd,
            );
            const previousCommands = this.commandCache.get(commandCacheKey);
            this.commandCache.set(commandCacheKey, {
              slashCommands:
                msg.slashCommands ?? previousCommands?.slashCommands ?? [],
              skills: msg.skills ?? previousCommands?.skills ?? [],
              skillMetadata:
                (msg.skillMetadata as
                  Array<Record<string, unknown>> | undefined) ??
                previousCommands?.skillMetadata,
              apps: msg.apps ?? previousCommands?.apps ?? [],
              appMetadata:
                (msg.appMetadata as
                  Array<Record<string, unknown>> | undefined) ??
                previousCommands?.appMetadata,
              plugins: msg.plugins ?? previousCommands?.plugins ?? [],
              pluginMetadata:
                (msg.pluginMetadata as
                  Array<Record<string, unknown>> | undefined) ??
                previousCommands?.pluginMetadata,
            });
          }

          if (effectiveProvider === "claude") {
            // Capture Claude session_id from result events
            if (msg.type === "result" && "sessionId" in msg && msg.sessionId) {
              session.claudeSessionId = msg.sessionId;
              this.saveWorktreeMapping(session);
            }
            if (msg.type === "system" && "sessionId" in msg && msg.sessionId) {
              session.claudeSessionId = msg.sessionId;
              this.saveWorktreeMapping(session);
            }

            // Cache tool_use names from assistant messages
            if (
              msg.type === "assistant" &&
              Array.isArray(msg.message.content)
            ) {
              for (const content of msg.message.content) {
                if (content.type === "tool_use") {
                  const toolUse = content as AssistantToolUseContent;
                  toolUseNames.set(toolUse.id, toolUse.name);
                }
              }
            }

            // Enrich tool_result with toolName
            if (msg.type === "tool_result") {
              const cachedName = toolUseNames.get(msg.toolUseId);
              if (cachedName) {
                msg = { ...msg, toolName: cachedName };
              }
            }
          } else {
            // Codex: capture thread_id for session tracking and worktree restore.
            if (msg.type === "system" && "sessionId" in msg && msg.sessionId) {
              session.claudeSessionId = msg.sessionId;
              this.restoreInputDeliveryState(session, msg.sessionId);
              if (!session.auxiliary) this.saveWorktreeMapping(session);
              if (!session.auxiliary && session.codexSettings?.profile) {
                saveCodexSessionProfile(
                  msg.sessionId,
                  session.codexSettings.profile,
                ).catch((err) => {
                  console.error(
                    "[session] Failed to save codex session profile:",
                    err,
                  );
                });
              }
              if (
                !session.auxiliary &&
                session.codexSettings?.additionalWritableRoots
              ) {
                saveCodexSessionAdditionalWritableRoots(
                  msg.sessionId,
                  session.codexSettings.additionalWritableRoots,
                ).catch((err) => {
                  console.error(
                    "[session] Failed to save codex writable roots:",
                    err,
                  );
                });
              }
            }
            if (msg.type === "system") {
              const nextCodexSettings = mergeCodexSettings(
                session.codexSettings,
                msg,
              );
              codexSettingsChanged = !equalCodexSettings(
                session.codexSettings,
                nextCodexSettings,
              );
              session.codexSettings = nextCodexSettings;
            }
            const messageModel = sanitizeCodexModel(
              msg.type === "assistant" ? msg.message.model : undefined,
            );
            if (msg.type === "assistant" && messageModel) {
              const nextCodexSettings = {
                ...(session.codexSettings ?? {}),
                model: messageModel,
              };
              codexSettingsChanged ||= !equalCodexSettings(
                session.codexSettings,
                nextCodexSettings,
              );
              session.codexSettings = nextCodexSettings;
            }
          }

          if (
            (session.claudeSessionId &&
              session.claudeSessionId !== previousProviderSessionId) ||
            codexSettingsChanged
          ) {
            this.onSessionUpdated?.(session.id);
          }
          if (msg.type === "system" && msg.subtype === "runtime_capabilities") {
            // Capability probes finish after the initial session_created frame.
            // Re-broadcast the session list so clients learn the capability for
            // this exact Codex runtime instead of relying on a global guess.
            this.onSessionUpdated?.(session.id);
          }

          const providerSessionId =
            session.claudeSessionId ?? proc.sessionId ?? undefined;
          let materializedGeneratedPaths: string[] = [];
          if (
            msg.type === "tool_result" &&
            effectiveProvider === "codex" &&
            this.imageStore &&
            this.artifactManager &&
            artifactCandidates.some(
              (candidate) => candidate.source === "image_generation",
            )
          ) {
            const ownerId =
              session.claudeSessionId ??
              (proc instanceof CodexProcess
                ? (proc.sessionId ?? undefined)
                : undefined);
            if (ownerId) {
              materializedGeneratedPaths =
                await this.artifactManager.materializeGeneratedCandidates({
                  ownerId,
                  messageId: msg.toolUseId,
                  cwd: session.worktreePath ?? session.projectPath,
                  candidates: artifactCandidates,
                });
            }
          }

          // Extract images from tool_result content for both Claude and Codex.
          if (msg.type === "tool_result" && this.imageStore) {
            const rawGeneratedPaths = new Set(
              structuredImagePaths(artifactCandidates),
            );
            const extractedPaths = this.imageStore.extractImagePaths(
              msg.content,
            );
            const paths = [
              ...new Set([
                ...(this.artifactManager && rawGeneratedPaths.size > 0
                  ? []
                  : extractedPaths),
                ...materializedGeneratedPaths,
              ]),
            ];
            if (paths.length > 0) {
              const images = await this.imageStore.registerImages(
                paths,
                session.worktreePath ?? session.projectPath,
              );
              if (images.length > 0) {
                msg = { ...msg, images };
              }

              // Also register in GalleryStore (disk-persistent)
              if (this.galleryStore) {
                for (const p of paths) {
                  const meta = await this.galleryStore.addImage(
                    p,
                    session.worktreePath ?? session.projectPath,
                    session.id,
                    providerSessionId,
                  );
                  if (meta && this.onGalleryImage) {
                    this.onGalleryImage(meta);
                  }
                }
              }
            }

            // Extract base64 images from content blocks (e.g., MCP screenshots)
            if (msg.rawContentBlocks) {
              const imageBlocks = (
                msg.rawContentBlocks as Array<Record<string, unknown>>
              ).filter(
                (c) =>
                  c.type === "image" &&
                  (c.source as Record<string, unknown>)?.type === "base64",
              );

              if (imageBlocks.length > 0) {
                const existingImages = msg.images ?? [];
                const newImages: ImageRef[] = [];

                for (const block of imageBlocks) {
                  const source = block.source as Record<string, unknown>;
                  if (
                    typeof source?.data !== "string" ||
                    typeof source?.media_type !== "string"
                  )
                    continue;
                  const b64Data = source.data as string;
                  const mimeType = source.media_type as string;
                  const ref = this.imageStore.registerFromBase64(
                    b64Data,
                    mimeType,
                  );
                  if (ref) {
                    newImages.push(ref);

                    // Also persist to GalleryStore
                    if (this.galleryStore) {
                      const meta = await this.galleryStore.addImageFromBase64(
                        b64Data,
                        mimeType,
                        session.projectPath,
                        session.id,
                        providerSessionId,
                      );
                      if (meta && this.onGalleryImage) {
                        this.onGalleryImage(meta);
                      }
                    }
                  }
                }

                if (newImages.length > 0) {
                  msg = { ...msg, images: [...existingImages, ...newImages] };
                }
              }

              // Strip transient rawContentBlocks before sending to client
              const { rawContentBlocks: _, ...cleanMsg } = msg;
              msg = cleanMsg as typeof msg;
            }
          }

          const enrichedMessage = this.enrichArtifactsForSession(
            session,
            msg,
            artifactCandidates,
          );
          msg =
            enrichedMessage instanceof Promise
              ? await enrichedMessage
              : enrichedMessage;

          // Don't add streaming deltas to history
          let mergedUserInput = false;
          let historyMsg: ServerMessage = msg;
          if (msg.type !== "stream_delta" && msg.type !== "thinking_delta") {
            if (this.shouldSuppressCodexCanonicalUserEcho(session, msg)) {
              return;
            }
            const mergedMsg = this.mergeUserInputIntoHistory(session, msg);
            if (mergedMsg) {
              mergedUserInput = true;
              historyMsg = mergedMsg;
            } else {
              historyMsg = this.buildHistoryProcessMessage(session, msg);
              this.appendHistoryToSession(session, historyMsg);
            }
          }

          this.onMessage(
            id,
            this.buildLiveProcessMessage(session, historyMsg, mergedUserInput),
          );

          // After a result (turn complete), backfill UUIDs from disk.
          // The SDK does not echo user messages via the stream, so
          // in-memory user_input entries lack UUIDs.  The disk
          // conversation file always has them.
          if (msg.type === "result") {
            this.backfillUserUuidsFromDisk(session);
            this.scheduleAutoRename(session);
          }
        } catch (err) {
          console.error(
            `[session] Error processing message for session ${id}:`,
            err,
          );
        }
      };

      // Preserve the existing synchronous fast path until an operation really
      // awaits; only messages arriving behind pending work enter the chain.
      if (messageProcessing) {
        trackMessageWork(messageProcessing.then(processMessage));
      } else {
        const current = processMessage();
        if (artifactWorkMayAwait || imageWorkMayAwait) {
          trackMessageWork(current);
        }
      }
    });

    proc.on("status", (status) => {
      if (!ownsRuntimeSlot()) return;
      session.status = status;
      if (session.auxiliary) this.onSessionUpdated?.(id);
      if (status === "idle") {
        this.evictStaleIdleSessions();
      }
    });

    if (proc instanceof CodexProcess) {
      if (replacementSession) {
        proc.prependOnceListener("input_ready", commitReplacement);
      }
      proc.on("input_ready", () => {
        if (!ownsRuntimeSlot()) return;
        if (proc.usesSharedRuntimeTopology) {
          sharedAttachmentEstablished = true;
          const attachmentChanged =
            session.codexAttachmentState !== "connected";
          session.codexAttachmentState = "connected";
          if (attachmentChanged) this.onSessionUpdated?.(id);
        }
        const drain = (): void => {
          this.emitRecoveredInputDeliveryReceipts(session);
          this.drainCodexQueue(session);
        };
        if (messageProcessing) {
          trackMessageWork(messageProcessing.then(drain));
        } else {
          drain();
        }
      });
      proc.on("input_delivery", (event) => {
        if (!ownsRuntimeSlot()) return;
        const publish = (receipt: InputDeliveryReceipt | undefined): void => {
          if (
            !receipt ||
            receipt.stage === "bridge_accepted" ||
            !receipt.method ||
            !ownsRuntimeSlot()
          ) {
            return;
          }
          this.onMessage(session.id, {
            type: "input_delivery_status_v1",
            sessionId: session.id,
            clientMessageId: receipt.clientMessageId,
            stage: receipt.stage,
            provider: "codex",
            method: receipt.method,
            occurredAt: receipt.occurredAt,
            acceptedSeq: receipt.acceptedSeq,
            queued: receipt.queued,
            ...(receipt.clientUserMessageIdAccepted === undefined
              ? {}
              : {
                  clientUserMessageIdAccepted:
                    receipt.clientUserMessageIdAccepted,
                }),
            ...(receipt.error ? { error: receipt.error } : {}),
          });
        };
        const receipt = this.recordProviderInputDelivery(session, event);
        if (receipt instanceof Promise) {
          void receipt.then(publish).catch((error) => {
            console.error(
              "[session] Failed to persist Codex input delivery receipt:",
              error instanceof Error ? error.name : "UnknownError",
            );
          });
        } else {
          publish(receipt);
        }
      });
    }

    proc.on("exit", () => {
      if (!ownsRuntimeSlot()) {
        failReplacement(
          new Error("Replacement Codex runtime exited before it became ready"),
        );
        return;
      }
      const finish = (): void => {
        if (session.auxiliary?.kind === "ephemeral_side_chat") {
          this.destroy(id);
          this.onSessionUpdated?.(id);
          return;
        }
        const sharedRuntimeDisconnected =
          proc instanceof CodexProcess && proc.lastStopWasSharedRuntime;
        const previousStatus = session.status;
        session.status = sharedRuntimeDisconnected ? "starting" : "idle";
        if (sharedRuntimeDisconnected) {
          session.codexAttachmentState = "unavailable";
        }
        if (!sharedRuntimeDisconnected) {
          this.setCodexQueuedInputs(
            session,
            this.inputDeliveryLedger
              ? codexQueuedInputsForSession(session).filter(
                  (item) => item.clientMessageId != null,
                )
              : [],
          );
        }
        // Add the disconnect boundary after every already-emitted provider
        // message, but only once. Retry phases change attachment authority,
        // not the public process status, and must not duplicate `starting`.
        if (!sharedRuntimeDisconnected || previousStatus !== session.status) {
          this.appendHistoryToSession(session, {
            type: "status",
            status: session.status,
          } as ServerMessage);
        }
        if (sharedRuntimeDisconnected && previousStatus !== session.status) {
          this.onMessage(id, {
            type: "status",
            status: session.status,
          } as ServerMessage);
        }
        if (session.provider === "codex") {
          this.broadcastCodexQueue(session);
        }
        if (sharedRuntimeDisconnected || session.auxiliary) {
          this.onSessionUpdated?.(id);
        }
        if (sharedRuntimeDisconnected && sharedAttachmentEstablished) {
          this.beginSharedCodexAttachmentRecovery(session);
        }
        this.evictStaleIdleSessions();
      };
      if (messageProcessing) {
        trackMessageWork(messageProcessing.then(finish));
      } else {
        finish();
      }
    });

    // Retry name persistence after the SDK/CLI has flushed transcript files.
    // This covers early renames that happened before the provider session id
    // or JSONL file was available.
    if (proc instanceof SdkProcess) {
      proc.on("session_end", async () => {
        if (!session.name) return;
        try {
          if (session.provider === "claude" && session.claudeSessionId) {
            await renameClaudeSession(
              session.worktreePath ?? session.projectPath,
              session.claudeSessionId,
              session.name,
            );
          } else if (session.provider === "codex" && session.claudeSessionId) {
            await renameCodexSession(session.claudeSessionId, session.name);
          }
        } catch (err) {
          console.warn(
            `[session] Failed to re-persist session name on session end:`,
            err,
          );
        }
      });
    }

    // Store Claude sandbox state for resume
    if (effectiveProvider === "claude" && options?.sandboxEnabled != null) {
      session.sandboxEnabled = options.sandboxEnabled;
    }

    if (effectiveProvider === "codex" && codexOptions) {
      session.codexSettings = {
        profile: codexOptions.profile,
        approvalPolicy: codexOptions.approvalPolicy,
        approvalsReviewer: codexOptions.approvalsReviewer,
        codexPermissionsMode: codexOptions.codexPermissionsMode,
        sandboxMode: codexOptions.sandboxMode,
        model: codexOptions.model,
        modelReasoningEffort: codexOptions.modelReasoningEffort,
        serviceTier: codexOptions.serviceTier,
        networkAccessEnabled: codexOptions.networkAccessEnabled,
        webSearchMode: codexOptions.webSearchMode,
        additionalWritableRoots: codexOptions.additionalWritableRoots,
        autoReviewDisabledByPolicy: codexOptions.autoReviewDisabledByPolicy,
      };
      // Resume starts know the thread id up front.
      if (codexOptions.threadId) {
        session.claudeSessionId = codexOptions.threadId;
        this.restoreInputDeliveryState(session, codexOptions.threadId);
        this.saveWorktreeMapping(session);
        if (codexOptions.profile) {
          saveCodexSessionProfile(
            codexOptions.threadId,
            codexOptions.profile,
          ).catch((err) => {
            console.error(
              "[session] Failed to save codex session profile:",
              err,
            );
          });
        }
        if (codexOptions.additionalWritableRoots) {
          saveCodexSessionAdditionalWritableRoots(
            codexOptions.threadId,
            codexOptions.additionalWritableRoots,
          ).catch((err) => {
            console.error(
              "[session] Failed to save codex writable roots:",
              err,
            );
          });
        }
      }
    }

    try {
      if (effectiveProvider === "codex") {
        (proc as CodexProcess).start(effectiveCwd, codexOptions);
      } else {
        (proc as SdkProcess).start(effectiveCwd, options);
      }
    } catch (error) {
      // A replacement must fail atomically: the old session remains mapped
      // and usable if the new provider cannot even start.
      cleanupReplacementAbort();
      proc.removeAllListeners();
      proc.stop();
      throw error;
    }

    // Add session to Map only after proc.start() succeeds.
    // If start() throws, no zombie session is left behind.
    if (replacementSession) {
      const timeoutMs = Math.max(
        1,
        internal?.replacementReadyTimeoutMs ?? 30_000,
      );
      replacementReadyTimer = setTimeout(
        () =>
          failReplacement(
            new Error("Replacement Codex runtime did not become ready in time"),
          ),
        timeoutMs,
      );
      replacementReadyTimer.unref?.();
    } else {
      this.sessions.set(id, session);
      this.evictStaleIdleSessions();
    }

    console.log(
      `[session] Created ${effectiveProvider} session ${id} for ${effectiveCwd}${wtPath ? ` (worktree of ${projectPath})` : ""}`,
    );
    return id;
  }

  get(id: string): SessionInfo | undefined {
    return this.sessions.get(id);
  }

  appendHistory(
    sessionId: string,
    msg: ServerMessage,
  ): HistoryEntry | undefined {
    const session = this.sessions.get(sessionId);
    if (!session) return undefined;
    const entry = this.appendHistoryToSession(session, msg);
    this.markPendingCodexUserEcho(session, msg);
    return entry;
  }

  getHistorySince(
    sessionId: string,
    sinceSeq: number,
  ): HistoryDeltaResult | undefined {
    const session = this.sessions.get(sessionId);
    if (!session) return undefined;

    const toSeq = session.historyRevision;
    const entries = session.historyEntries;
    if (sinceSeq > toSeq) {
      return {
        kind: "snapshot",
        fromSeq: entries[0]?.seq ?? toSeq + 1,
        toSeq,
        entries: [...entries],
        reason: "reset",
      };
    }
    if (entries.length === 0) {
      return {
        kind: "delta",
        fromSeq: toSeq + 1,
        toSeq,
        entries: [],
      };
    }

    const firstSeq = entries[0].seq;
    if (
      session.historyMutationResetRevision !== undefined &&
      sinceSeq < session.historyMutationResetRevision
    ) {
      return {
        kind: "snapshot",
        fromSeq: firstSeq,
        toSeq,
        entries: [...entries],
        reason: "reset",
      };
    }
    if (sinceSeq < firstSeq - 1) {
      return {
        kind: "snapshot",
        fromSeq: firstSeq,
        toSeq,
        entries: [...entries],
        reason: "compacted",
      };
    }

    const deltaEntries = entries.filter((entry) => entry.seq > sinceSeq);
    return {
      kind: "delta",
      fromSeq: deltaEntries[0]?.seq ?? toSeq + 1,
      toSeq,
      entries: deltaEntries,
    };
  }

  list(): SessionSummary[] {
    const sessions = Array.from(this.sessions.values()).filter(
      (session) => session.auxiliary == null,
    );
    return sessions.map((s) => {
      const codexSettings =
        s.process instanceof CodexProcess
          ? withDerivedCodexPermissionsMode(
              s.codexSettings ??
                (s.process.codexPermissionsMode
                  ? { codexPermissionsMode: s.process.codexPermissionsMode }
                  : undefined),
            )
          : s.codexSettings;
      const processWithPending = s.process as {
        getPendingPermission?: () =>
          | {
              toolUseId: string;
              toolName: string;
              input: Record<string, unknown>;
            }
          | undefined;
      };
      // The process-owned ledger is the authority for transient interactions.
      // Status and the ledger are emitted on separate event paths, so gating
      // this read on a status snapshot can briefly hide a still-actionable
      // Plan approval or question from a reconnecting Mobile client.
      const pendingPermission = processWithPending.getPendingPermission?.();
      const executionMode =
        s.process instanceof SdkProcess
          ? s.process.permissionMode === "bypassPermissions"
            ? "fullAccess"
            : s.process.permissionMode === "acceptEdits"
              ? "acceptEdits"
              : "default"
          : s.process instanceof CodexProcess
            ? codexSettings?.approvalPolicy === undefined
              ? undefined
              : codexSettings.approvalPolicy === "never"
                ? "fullAccess"
                : "default"
            : undefined;
      const planMode =
        s.process instanceof SdkProcess
          ? s.process.permissionMode === "plan"
          : s.process instanceof CodexProcess
            ? s.process.collaborationMode === "plan"
            : undefined;
      return {
        id: s.id,
        provider: s.provider,
        projectPath: s.projectPath,
        claudeSessionId: s.claudeSessionId,
        forkedFromSessionId: s.forkedFromSessionId,
        forkedFromThreadId: s.forkedFromThreadId,
        name: s.name,
        status: s.status,
        createdAt: s.createdAt.toISOString(),
        lastActivityAt: s.lastActivityAt.toISOString(),
        gitBranch: s.gitBranch,
        lastMessage: this.extractLastMessage(s),
        worktreePath: s.worktreePath,
        worktreeBranch: s.worktreeBranch,
        permissionMode:
          s.process instanceof SdkProcess
            ? s.process.permissionMode
            : s.process instanceof CodexProcess
              ? s.process.collaborationMode === "plan"
                ? "plan"
                : codexSettings?.approvalPolicy === undefined
                  ? undefined
                  : codexSettings.approvalPolicy === "never"
                    ? "bypassPermissions"
                    : "acceptEdits"
              : undefined,
        executionMode,
        planMode,
        model: s.process instanceof SdkProcess ? s.process.model : undefined,
        codexSettings,
        agentNickname:
          s.process instanceof CodexProcess
            ? (s.process.agentNickname ?? undefined)
            : undefined,
        agentRole:
          s.process instanceof CodexProcess
            ? (s.process.agentRole ?? undefined)
            : undefined,
        codexPermissionApplyStrategySupported:
          s.process instanceof CodexProcess
            ? s.process.supportsNextTurnPermissionUpdates
            : undefined,
        ...(s.process instanceof CodexProcess &&
        s.process.nativePlanModeCapabilityKnown
          ? { codexNativePlanModeSupported: s.process.supportsNativePlanMode }
          : {}),
        ...(s.process instanceof CodexProcess &&
        s.codexGoalControlSupported !== undefined
          ? { codexGoalControlSupported: s.codexGoalControlSupported }
          : {}),
        sandboxEnabled: s.sandboxEnabled,
        pendingPermission,
        ...(s.provider === "codex"
          ? {
              queuedInput: (() => {
                const item = codexQueuedInputsForSession(s)[0];
                return publicQueuedInput(
                  item,
                  item?.clientMessageId
                    ? s.inputDeliveryReceipts?.get(item.clientMessageId)
                    : undefined,
                );
              })(),
              queuedInputs: codexQueuedInputsForSession(s)
                .map((item) =>
                  publicQueuedInput(
                    item,
                    item.clientMessageId
                      ? s.inputDeliveryReceipts?.get(item.clientMessageId)
                      : undefined,
                  ),
                )
                .filter(
                  (item): item is QueuedInputItem => item !== undefined,
                ),
              queuedInputLimit: MAX_CODEX_QUEUED_INPUTS,
            }
          : {}),
      };
    });
  }

  listEphemeralSideChats(): SessionInfo[] {
    return Array.from(this.sessions.values())
      .filter((session) => session.auxiliary?.kind === "ephemeral_side_chat")
      .sort(
        (left, right) =>
          right.lastActivityAt.getTime() - left.lastActivityAt.getTime(),
      );
  }

  private appendHistoryToSession(
    session: SessionInfo,
    msg: ServerMessage,
  ): HistoryEntry {
    msg.receivedAt = new Date().toISOString();
    const entry = {
      seq: session.historyRevision + 1,
      message: msg,
    };
    (msg as Record<string, unknown>).historySeq = entry.seq;
    session.historyRevision = entry.seq;
    session.history.push(msg);
    session.historyEntries.push(entry);
    if (session.provider === "codex" && msg.type === "user_input") {
      session.codexLatestUserInput = msg;
    }
    this.trimHistory(session);
    return entry;
  }

  private mergeUserInputIntoHistory(
    session: SessionInfo,
    msg: ServerMessage,
  ): ServerMessage | null {
    if (msg.type !== "user_input") return null;

    for (let i = session.history.length - 1; i >= 0; i--) {
      const current = session.history[i];
      if (current.type !== "user_input") continue;
      if (!this.isSameUserInput(session, current, msg)) continue;

      const mergedUuid = this.mergeUserMessageUuid(current, msg);
      const mergedReceivedAt = current.receivedAt ?? msg.receivedAt;
      const currentTimestamp =
        "timestamp" in current ? current.timestamp : undefined;
      const mergedTimestamp =
        currentTimestamp || ("timestamp" in msg ? msg.timestamp : undefined);
      const currentUuid =
        "userMessageUuid" in current ? current.userMessageUuid : undefined;
      const mergedMsg = {
        ...current,
        userMessageUuid: mergedUuid,
        receivedAt: mergedReceivedAt,
        timestamp: mergedTimestamp,
      } as ServerMessage;
      const historyChanged =
        mergedUuid !== currentUuid ||
        mergedReceivedAt !== current.receivedAt ||
        mergedTimestamp !== currentTimestamp;

      const entry = session.historyEntries[i];
      if (entry) {
        (mergedMsg as Record<string, unknown>).historySeq = entry.seq;
        entry.message = mergedMsg;
      }
      session.history[i] = mergedMsg;
      // This is an in-place replacement, not an append. Advance the session
      // revision and force lagging clients through the existing snapshot lane
      // so they receive the UUID backfill without duplicating or reordering the
      // original user turn.
      if (historyChanged) {
        session.historyRevision += 1;
        session.historyMutationResetRevision = session.historyRevision;
      }
      this.clearPendingCodexUserEcho(session, current);
      this.clearPendingCodexUserEcho(session, msg);
      return mergedMsg;
    }

    return null;
  }

  private buildLiveProcessMessage(
    session: SessionInfo,
    msg: ServerMessage,
    mergedUserInput: boolean,
  ): ServerMessage {
    if (
      session.provider === "codex" &&
      msg.type === "user_input" &&
      !mergedUserInput &&
      "userMessageUuid" in msg &&
      msg.userMessageUuid
    ) {
      // Current mobile builds treat a user_input with userMessageUuid as a UUID
      // backfill for an optimistic local message.  New remote turns need to be
      // added as chat entries, while history still keeps the Codex item id.
      const { userMessageUuid: _, ...liveMsg } = msg;
      return liveMsg as ServerMessage;
    }
    return msg;
  }

  private shouldSuppressCodexCanonicalUserEcho(
    session: SessionInfo,
    msg: ServerMessage,
  ): boolean {
    if (session.provider !== "codex" || msg.type !== "user_input") {
      return false;
    }
    const rawId = "userMessageUuid" in msg ? msg.userMessageUuid : undefined;
    if (!rawId || isCodexUserTurnUuid(rawId)) return false;
    const canonicalUuid = session.codexUserTurnUuidByRawId?.get(rawId);
    if (!canonicalUuid) return false;
    return this.hasPastCodexUserMessage(session, canonicalUuid);
  }

  private seedCodexPastUserTurnUuidMap(session: SessionInfo): void {
    for (const message of session.pastMessages ?? []) {
      if (!message || typeof message !== "object") continue;
      const item = message as {
        role?: unknown;
        uuid?: unknown;
        rawItemId?: unknown;
        isMeta?: unknown;
      };
      if (
        item.role !== "user" ||
        item.isMeta === true ||
        typeof item.rawItemId !== "string" ||
        typeof item.uuid !== "string"
      ) {
        continue;
      }
      session.codexUserTurnUuidByRawId ??= new Map<string, string>();
      session.codexUserTurnUuidByRawId.set(item.rawItemId, item.uuid);
    }
  }

  private hasPastCodexUserMessage(session: SessionInfo, uuid: string): boolean {
    return (session.pastMessages ?? []).some((message) => {
      if (!message || typeof message !== "object") return false;
      const item = message as {
        role?: unknown;
        uuid?: unknown;
        isMeta?: unknown;
      };
      return item.role === "user" && item.uuid === uuid && item.isMeta !== true;
    });
  }

  private buildHistoryProcessMessage(
    session: SessionInfo,
    msg: ServerMessage,
  ): ServerMessage {
    if (session.provider !== "codex" || msg.type !== "user_input") return msg;
    const uuid = "userMessageUuid" in msg ? msg.userMessageUuid : undefined;
    if (!uuid || isCodexUserTurnUuid(uuid)) return msg;
    return {
      ...msg,
      userMessageUuid: this.codexUserTurnUuidForRawItem(session, uuid),
    } as ServerMessage;
  }

  private isSameUserInput(
    session: SessionInfo,
    existing: ServerMessage,
    incoming: ServerMessage,
  ): boolean {
    if (existing.type !== "user_input" || incoming.type !== "user_input") {
      return false;
    }

    const existingClientId =
      "clientMessageId" in existing ? existing.clientMessageId : undefined;
    const incomingClientId =
      "clientMessageId" in incoming ? incoming.clientMessageId : undefined;
    if (existingClientId && incomingClientId) {
      return existingClientId === incomingClientId;
    }

    const existingUuid =
      "userMessageUuid" in existing ? existing.userMessageUuid : undefined;
    const incomingUuid =
      "userMessageUuid" in incoming ? incoming.userMessageUuid : undefined;
    if (existingUuid && incomingUuid && existingUuid === incomingUuid) {
      return true;
    }

    if (session.provider !== "codex" && !existingUuid && incomingUuid) {
      return true;
    }

    if (existing.text !== incoming.text) return false;
    const existingHasImageCount = "imageCount" in existing;
    const incomingHasImageCount = "imageCount" in incoming;
    if (existingHasImageCount && incomingHasImageCount) {
      const existingImages = existing.imageCount ?? 0;
      const incomingImages = incoming.imageCount ?? 0;
      if (existingImages !== incomingImages) return false;
    }
    if (
      isCodexUserTurnUuid(existingUuid) ||
      isCodexUserTurnUuid(incomingUuid)
    ) {
      return (
        this.isPendingCodexUserEcho(session, existingUuid) ||
        this.isPendingCodexUserEcho(session, incomingUuid)
      );
    }
    return !existingUuid || !incomingUuid;
  }

  private mergeUserMessageUuid(
    existing: ServerMessage,
    incoming: ServerMessage,
  ): string | undefined {
    const existingUuid =
      existing.type === "user_input" && "userMessageUuid" in existing
        ? existing.userMessageUuid
        : undefined;
    const incomingUuid =
      incoming.type === "user_input" && "userMessageUuid" in incoming
        ? incoming.userMessageUuid
        : undefined;
    if (isCodexUserTurnUuid(existingUuid)) {
      return existingUuid;
    }
    if (isCodexUserTurnUuid(incomingUuid)) {
      return incomingUuid;
    }
    return existingUuid || incomingUuid;
  }

  private markPendingCodexUserEcho(
    session: SessionInfo,
    msg: ServerMessage,
  ): void {
    if (session.provider !== "codex" || msg.type !== "user_input") return;
    const uuid = "userMessageUuid" in msg ? msg.userMessageUuid : undefined;
    if (!isCodexUserTurnUuid(uuid)) return;
    session.pendingCodexUserEchoUuids ??= new Set<string>();
    session.pendingCodexUserEchoUuids.add(uuid);
  }

  private clearPendingCodexUserEcho(
    session: SessionInfo,
    msg: ServerMessage,
  ): void {
    if (session.provider !== "codex" || msg.type !== "user_input") return;
    const uuid = "userMessageUuid" in msg ? msg.userMessageUuid : undefined;
    if (!isCodexUserTurnUuid(uuid)) return;
    session.pendingCodexUserEchoUuids?.delete(uuid);
  }

  private isPendingCodexUserEcho(
    session: SessionInfo,
    uuid: string | undefined,
  ): boolean {
    return (
      isCodexUserTurnUuid(uuid) &&
      (session.pendingCodexUserEchoUuids?.has(uuid) ?? false)
    );
  }

  private codexUserTurnUuidForRawItem(
    session: SessionInfo,
    rawId: string,
  ): string {
    session.codexUserTurnUuidByRawId ??= new Map<string, string>();
    const existing = session.codexUserTurnUuidByRawId.get(rawId);
    if (existing) return existing;
    const uuid = this.nextCodexUserTurnUuid(session);
    session.codexUserTurnUuidByRawId.set(rawId, uuid);
    return uuid;
  }

  private nextCodexUserTurnUuid(session: SessionInfo): string {
    let maxOrdinal = 0;
    let userTurnCount = 0;

    const observe = (uuid?: string): void => {
      userTurnCount += 1;
      if (!isCodexUserTurnUuid(uuid)) return;
      const ordinal = Number(uuid.slice("codex:user-turn:".length));
      if (Number.isInteger(ordinal)) {
        maxOrdinal = Math.max(maxOrdinal, ordinal);
      }
    };

    for (const message of session.pastMessages ?? []) {
      if (!message || typeof message !== "object") continue;
      const item = message as {
        role?: unknown;
        uuid?: unknown;
        isMeta?: unknown;
      };
      if (item.role !== "user" || item.isMeta === true) continue;
      observe(typeof item.uuid === "string" ? item.uuid : undefined);
    }

    for (const message of session.history) {
      if (message.type !== "user_input") continue;
      observe(
        "userMessageUuid" in message ? message.userMessageUuid : undefined,
      );
    }
    for (const queued of codexQueuedInputsForSession(session)) {
      observe(queued.userMessageUuid);
    }
    return codexUserTurnUuid(Math.max(maxOrdinal, userTurnCount) + 1);
  }

  private trimHistory(session: SessionInfo): void {
    while (session.history.length > MAX_HISTORY_PER_SESSION) {
      // Keep the retained in-memory history as a chronological tail.  The
      // mobile client renders history snapshots directly; preferentially
      // preserving user_input/system entries makes long sessions degrade into
      // a run of user bubbles after compaction.
      session.history.shift();
      session.historyEntries.shift();
    }

    session.historyLowWatermark =
      session.historyEntries[0]?.seq ?? session.historyRevision + 1;
  }

  private scheduleAutoRename(session: SessionInfo): void {
    if (!this.shouldAutoRename(session)) return;
    session.autoRenameAttempted = true;
    setTimeout(() => {
      void this.autoRenameSession(session).catch((err) => {
        console.warn(
          `[session] Failed to auto-rename session ${session.id}:`,
          err,
        );
      });
    }, 0);
  }

  private shouldAutoRename(session: SessionInfo): boolean {
    if (!session.autoRename || session.autoRenameAttempted || session.name) {
      return false;
    }
    if (this.isInternalAutoRenameSession(session)) return false;
    return buildAutoRenameTranscript(session.history) !== null;
  }

  private isInternalAutoRenameSession(session: SessionInfo): boolean {
    if (session.codexSettings?.model === "codex-auto-review") return true;
    const firstUser = session.history.find((msg) => msg.type === "user_input");
    return (
      firstUser?.type === "user_input" &&
      firstUser.text.startsWith(
        "The following is the Codex agent history whose request action",
      )
    );
  }

  private async autoRenameSession(session: SessionInfo): Promise<void> {
    if (session.name) return;
    const transcript = buildAutoRenameTranscript(session.history);
    if (!transcript) return;

    const name = generateAutoRenameName({
      provider: session.provider,
      projectPath: session.worktreePath ?? session.projectPath,
      model:
        session.provider === "claude"
          ? session.process instanceof SdkProcess
            ? session.process.model
            : undefined
          : session.codexSettings?.model,
      transcript,
    });
    if (!name || session.name) return;

    const persisted = await this.persistSessionName(session, name);
    if (!persisted || session.name) return;
    session.name = name;
    this.onSessionUpdated?.(session.id);
  }

  private async persistSessionName(
    session: SessionInfo,
    name: string,
  ): Promise<boolean> {
    if (session.provider === "claude" && session.claudeSessionId) {
      await renameClaudeSession(
        session.worktreePath ?? session.projectPath,
        session.claudeSessionId,
        name,
      );
      return true;
    }

    if (session.provider !== "codex") return false;
    if (session.process instanceof CodexProcess) {
      try {
        await session.process.renameThread(name);
        return true;
      } catch (err) {
        console.warn(`[session] Failed to auto-rename Codex thread:`, err);
      }
    }
    if (session.claudeSessionId) {
      await renameCodexSession(session.claudeSessionId, name);
      return true;
    }
    return false;
  }

  private extractLastMessage(s: SessionInfo): string {
    // Search in-memory history (newest first) for assistant text
    for (let i = s.history.length - 1; i >= 0; i--) {
      const msg = s.history[i];
      if (msg.type === "assistant") {
        const textBlock = msg.message.content.find((c) => c.type === "text");
        if (textBlock && "text" in textBlock && textBlock.text) {
          return textBlock.text.replace(/\s+/g, " ").trim().slice(0, 100);
        }
      }
    }
    // Fallback to pastMessages (raw Claude CLI format)
    if (s.pastMessages) {
      for (let i = s.pastMessages.length - 1; i >= 0; i--) {
        const msg = s.pastMessages[i] as Record<string, unknown>;
        if (msg.role === "assistant") {
          // Handle string content (defensive — normally array)
          if (typeof msg.content === "string") {
            return msg.content.replace(/\s+/g, " ").trim().slice(0, 100);
          }
          const content = msg.content as
            Array<Record<string, unknown>> | undefined;
          const textBlock = content?.find((c) => c.type === "text");
          if (textBlock?.text)
            return (textBlock.text as string)
              .replace(/\s+/g, " ")
              .trim()
              .slice(0, 100);
        }
      }
    }
    return "";
  }

  private inputDeliveryIdentity(
    session: SessionInfo,
    clientMessageId: string,
  ): InputDeliveryIdentity | undefined {
    if (
      !this.inputDeliveryLedger ||
      !this.inputDeliveryScope ||
      session.provider !== "codex"
    ) {
      return undefined;
    }
    const providerThreadId =
      session.claudeSessionId ?? session.process.sessionId ?? undefined;
    if (!providerThreadId) return undefined;
    return {
      ...this.inputDeliveryScope,
      providerThreadId,
      clientMessageId,
    };
  }

  private setCodexQueuedInputs(
    session: SessionInfo,
    inputs: QueuedCodexInput[],
  ): void {
    const bounded = inputs.slice(0, MAX_CODEX_QUEUED_INPUTS);
    session.codexQueuedInputs = bounded;
    session.codexQueuedInput = bounded[0];
  }

  private replaceCodexQueuedInput(
    session: SessionInfo,
    current: QueuedCodexInput,
    next: QueuedCodexInput,
  ): boolean {
    const queue = codexQueuedInputsForSession(session);
    const index = queue.indexOf(current);
    if (index === -1) return false;
    this.setCodexQueuedInputs(session, [
      ...queue.slice(0, index),
      next,
      ...queue.slice(index + 1),
    ]);
    return true;
  }

  private removeCodexQueuedInput(
    session: SessionInfo,
    current: QueuedCodexInput,
  ): boolean {
    const queue = codexQueuedInputsForSession(session);
    const index = queue.indexOf(current);
    if (index === -1) return false;
    this.setCodexQueuedInputs(session, [
      ...queue.slice(0, index),
      ...queue.slice(index + 1),
    ]);
    return true;
  }

  private restoreInputDeliveryState(
    session: SessionInfo,
    providerThreadId: string,
  ): void {
    if (!this.inputDeliveryLedger || !this.inputDeliveryScope) return;
    if (this.inputDeliveryRestoredThreads.get(session) === providerThreadId) {
      return;
    }
    this.inputDeliveryRestoredThreads.set(session, providerThreadId);
    const plan = this.inputDeliveryLedger.recoveryPlan(
      this.inputDeliveryScope,
      providerThreadId,
    );
    if (plan.records.length === 0) return;

    const receipts = new Map<string, InputDeliveryReceipt>();
    for (const record of plan.records) {
      receipts.set(
        record.clientMessageId,
        this.receiptFromDurableInput(record),
      );
    }
    session.inputDeliveryReceipts = receipts;

    const replay = [...plan.replay].sort((left, right) =>
      left.record.occurredAt.localeCompare(right.record.occurredAt),
    );
    const selected = replay.splice(0, MAX_CODEX_QUEUED_INPUTS);
    this.setCodexQueuedInputs(
      session,
      selected.map(({ record, payload, requireClientUserMessageId }) => ({
        ...payload,
        clientMessageId: record.clientMessageId,
        recoveryRequiresClientUserMessageId: requireClientUserMessageId,
      })),
    );

    const forcedUnknown = [
      ...plan.outcomeUnknown,
      ...replay.map(({ record }) => record),
    ];
    for (const record of forcedUnknown) {
      const error = record.containsImages
        ? "Bridge restarted during image delivery; the image input was not replayed."
        : record.method === "turn/steer"
          ? "Bridge restarted during turn guidance; the stale guidance was not replayed."
          : "Bridge restarted after provider delivery may have begun; the input was not replayed.";
      receipts.set(record.clientMessageId, {
        clientMessageId: record.clientMessageId,
        stage: "provider_rejected",
        acceptedSeq: record.acceptedSeq,
        queued: record.queued,
        provider: "codex",
        method: record.method ?? "turn/start",
        occurredAt: new Date().toISOString(),
        clientUserMessageIdAccepted: false,
        error,
      });
      void this.inputDeliveryLedger
        .markOutcomeUnknown(record, error)
        .catch((failure) => {
          console.error(
            "[session] Failed to persist an unknown input delivery outcome:",
            failure instanceof Error ? failure.name : "UnknownError",
          );
        });
    }

    const terminalReceipts = [...receipts.values()]
      .filter((receipt) => receipt.stage !== "bridge_accepted")
      .sort((left, right) => right.occurredAt.localeCompare(left.occurredAt))
      .slice(0, 16);
    if (terminalReceipts.length > 0) {
      this.recoveredReceiptsToEmit.set(session, terminalReceipts);
    }
  }

  private receiptFromDurableInput(
    record: DurableInputDeliveryRecord,
  ): InputDeliveryReceipt {
    const stage: InputDeliveryStage =
      record.state === "provider_accepted"
        ? "provider_accepted"
        : record.state === "provider_rejected" ||
            record.state === "outcome_unknown" ||
            record.state === "cancelled"
          ? "provider_rejected"
          : "bridge_accepted";
    return {
      clientMessageId: record.clientMessageId,
      stage,
      acceptedSeq: record.acceptedSeq,
      queued: record.queued,
      ...(stage === "bridge_accepted"
        ? {}
        : {
            provider: "codex" as const,
            method: record.method ?? ("turn/start" as const),
          }),
      occurredAt: record.occurredAt,
      ...(record.clientUserMessageIdAccepted === undefined
        ? {}
        : {
            clientUserMessageIdAccepted: record.clientUserMessageIdAccepted,
          }),
      ...(record.error ? { error: record.error } : {}),
    };
  }

  private emitRecoveredInputDeliveryReceipts(session: SessionInfo): void {
    if (this.recoveredReceiptEmission.has(session)) return;
    this.recoveredReceiptEmission.add(session);
    for (const receipt of this.recoveredReceiptsToEmit.get(session) ?? []) {
      if (!receipt.method || receipt.stage === "bridge_accepted") continue;
      this.onMessage(session.id, {
        type: "input_delivery_status_v1",
        sessionId: session.id,
        clientMessageId: receipt.clientMessageId,
        stage: receipt.stage,
        provider: "codex",
        method: receipt.method,
        occurredAt: receipt.occurredAt,
        acceptedSeq: receipt.acceptedSeq,
        queued: receipt.queued,
        ...(receipt.clientUserMessageIdAccepted === undefined
          ? {}
          : {
              clientUserMessageIdAccepted: receipt.clientUserMessageIdAccepted,
            }),
        ...(receipt.error ? { error: receipt.error } : {}),
      });
    }
    this.recoveredReceiptsToEmit.delete(session);
  }

  async queueCodexInputDurably(
    id: string,
    input: QueuedCodexInput,
    acceptedSeq: number,
  ): Promise<boolean> {
    const session = this.sessions.get(id);
    if (!session || session.provider !== "codex") return false;
    if (!input.clientMessageId || !this.inputDeliveryLedger) {
      return this.queueCodexInput(id, input);
    }
    const identity = this.inputDeliveryIdentity(session, input.clientMessageId);
    if (!identity) {
      throw new InputDeliveryLedgerError(
        "unavailable",
        "The Codex thread identity is not ready for durable delivery.",
      );
    }
    await this.inputDeliveryLedger.admit({
      identity,
      acceptedSeq,
      queued: true,
      payload: this.durablePayloadFromQueue(input),
      containsImages: Boolean(
        input.imageCount || input.images?.length || input.imageRefs?.length,
      ),
    });
    const current = this.sessions.get(id);
    if (
      current !== session ||
      codexQueuedInputsForSession(current).length >= MAX_CODEX_QUEUED_INPUTS
    ) {
      await this.inputDeliveryLedger.markOutcomeUnknown(
        identity,
        "The runtime queue changed while durable admission was being committed; the input was not enqueued.",
      );
      return false;
    }
    return this.queueCodexInput(id, input);
  }

  async prepareImmediateCodexInputDelivery(
    id: string,
    input: QueuedCodexInput,
    acceptedSeq: number,
  ): Promise<InputDeliveryReceipt | undefined> {
    const session = this.sessions.get(id);
    if (!session || session.provider !== "codex" || !input.clientMessageId) {
      return undefined;
    }
    if (!this.inputDeliveryLedger) {
      return this.recordInputBridgeAcceptance(
        id,
        input.clientMessageId,
        acceptedSeq,
        false,
      );
    }
    const identity = this.inputDeliveryIdentity(session, input.clientMessageId);
    if (!identity) {
      throw new InputDeliveryLedgerError(
        "unavailable",
        "The Codex thread identity is not ready for durable delivery.",
      );
    }
    const admitted = await this.inputDeliveryLedger.admit({
      identity,
      acceptedSeq,
      queued: false,
      payload: this.durablePayloadFromQueue(input),
      containsImages: Boolean(
        input.imageCount || input.images?.length || input.imageRefs?.length,
      ),
    });
    const receipt = this.receiptFromDurableInput(admitted.record);
    this.storeInputDeliveryReceipt(session, receipt);
    return receipt;
  }

  async updateCodexQueuedInputDurably(
    id: string,
    itemId: string,
    text: string,
    options?: {
      skills?: Array<{ name: string; path: string }>;
      mentions?: Array<{ name: string; path: string }>;
    },
  ): Promise<boolean> {
    const session = this.sessions.get(id);
    const current = session
      ? codexQueuedInputsForSession(session).find(
          (candidate) => candidate.itemId === itemId,
        )
      : undefined;
    if (!session || session.provider !== "codex" || !current) return false;
    if (!current.clientMessageId || !this.inputDeliveryLedger) {
      return this.updateCodexQueuedInput(id, itemId, text, options);
    }
    const identity = this.inputDeliveryIdentity(
      session,
      current.clientMessageId,
    );
    if (!identity) {
      throw new InputDeliveryLedgerError(
        "unavailable",
        "The Codex thread identity is not ready for durable delivery.",
      );
    }
    const next: QueuedCodexInput = {
      ...current,
      text,
      updatedAt: new Date().toISOString(),
      skills: options?.skills,
      mentions: options?.mentions,
    };
    await this.inputDeliveryLedger.updateQueued(
      identity,
      this.durablePayloadFromQueue(next),
    );
    const latest = this.sessions.get(id);
    const latestCurrent =
      latest?.provider === "codex"
        ? codexQueuedInputsForSession(latest).find(
            (candidate) =>
              candidate.itemId === itemId &&
              candidate.clientMessageId === current.clientMessageId,
          )
        : undefined;
    if (!latest || !latestCurrent) {
      return false;
    }
    // A runtime replacement can atomically swap SessionInfo while the durable
    // write is awaiting fsync. Re-resolve by the stable delivery identity so
    // the in-memory queue cannot keep stale text after the ledger committed.
    this.replaceCodexQueuedInput(latest, latestCurrent, {
      ...latestCurrent,
      text,
      updatedAt: next.updatedAt,
      skills: options?.skills,
      mentions: options?.mentions,
    });
    latest.lastActivityAt = new Date();
    this.broadcastCodexQueue(latest);
    return true;
  }

  async cancelCodexQueuedInputDurably(
    id: string,
    itemId: string,
  ): Promise<boolean> {
    const session = this.sessions.get(id);
    const current = session
      ? codexQueuedInputsForSession(session).find(
          (candidate) => candidate.itemId === itemId,
        )
      : undefined;
    if (!session || session.provider !== "codex" || !current) return false;
    if (!current.clientMessageId || !this.inputDeliveryLedger) {
      return this.cancelCodexQueuedInput(id, itemId);
    }
    const identity = this.inputDeliveryIdentity(
      session,
      current.clientMessageId,
    );
    if (!identity) {
      throw new InputDeliveryLedgerError(
        "unavailable",
        "The Codex thread identity is not ready for durable delivery.",
      );
    }
    await this.inputDeliveryLedger.cancel(identity);
    const latest = this.sessions.get(id);
    const latestCurrent =
      latest?.provider === "codex"
        ? codexQueuedInputsForSession(latest).find(
            (candidate) =>
              candidate.itemId === itemId &&
              candidate.clientMessageId === current.clientMessageId,
          )
        : undefined;
    if (!latest || !latestCurrent) {
      return false;
    }
    // Cancellation is already durable at this point. Apply it to whichever
    // replacement currently owns the stable public session id; otherwise a
    // cancelled ledger record could leave an undrainable ghost queue item.
    this.removeCodexQueuedInput(latest, latestCurrent);
    latest.lastActivityAt = new Date();
    this.broadcastCodexQueue(latest);
    return true;
  }

  private durablePayloadFromQueue(
    input: QueuedCodexInput,
  ): DurableInputPayload {
    return {
      itemId: input.itemId,
      text: input.text,
      createdAt: input.createdAt,
      ...(input.updatedAt ? { updatedAt: input.updatedAt } : {}),
      ...(input.userMessageUuid
        ? { userMessageUuid: input.userMessageUuid }
        : {}),
      ...(input.skills ? { skills: input.skills } : {}),
      ...(input.mentions ? { mentions: input.mentions } : {}),
    };
  }

  queueCodexInput(id: string, input: QueuedCodexInput): boolean {
    const session = this.sessions.get(id);
    if (!session || session.provider !== "codex") return false;
    const queue = codexQueuedInputsForSession(session);
    if (queue.length >= MAX_CODEX_QUEUED_INPUTS) return false;
    this.setCodexQueuedInputs(session, [...queue, input]);
    session.lastActivityAt = new Date();
    this.broadcastCodexQueue(session);
    return true;
  }

  recordInputBridgeAcceptance(
    id: string,
    clientMessageId: string,
    acceptedSeq: number,
    queued: boolean,
  ): InputDeliveryReceipt | undefined {
    const session = this.sessions.get(id);
    if (!session) return undefined;
    const existing = session.inputDeliveryReceipts?.get(clientMessageId);
    if (existing && existing.stage !== "bridge_accepted") return existing;
    const receipt: InputDeliveryReceipt = {
      clientMessageId,
      stage: "bridge_accepted",
      acceptedSeq,
      queued,
      occurredAt: existing?.occurredAt ?? new Date().toISOString(),
    };
    this.storeInputDeliveryReceipt(session, receipt);
    if (
      queued &&
      codexQueuedInputsForSession(session).some(
        (item) => item.clientMessageId === clientMessageId,
      )
    ) {
      this.broadcastCodexQueue(session);
    }
    return receipt;
  }

  getInputDeliveryReceipt(
    id: string,
    clientMessageId: string,
  ): InputDeliveryReceipt | undefined {
    return this.sessions.get(id)?.inputDeliveryReceipts?.get(clientMessageId);
  }

  recordCodexInputDispatchFailure(
    id: string,
    clientMessageId: string,
    error: unknown,
  ):
    | InputDeliveryReceipt
    | undefined
    | Promise<InputDeliveryReceipt | undefined> {
    const session = this.sessions.get(id);
    if (!session || session.provider !== "codex") return undefined;
    return this.recordProviderInputDelivery(session, {
      clientMessageId,
      stage: "provider_rejected",
      method: "turn/start",
      occurredAt: new Date().toISOString(),
      error: error instanceof Error ? error.message : String(error),
    });
  }

  updateCodexQueuedInput(
    id: string,
    itemId: string,
    text: string,
    options?: {
      skills?: Array<{ name: string; path: string }>;
      mentions?: Array<{ name: string; path: string }>;
    },
  ): boolean {
    const session = this.sessions.get(id);
    if (!session || session.provider !== "codex") return false;
    const current = codexQueuedInputsForSession(session).find(
      (candidate) => candidate.itemId === itemId,
    );
    if (!current) return false;
    this.replaceCodexQueuedInput(session, current, {
      ...current,
      text,
      updatedAt: new Date().toISOString(),
      skills: options?.skills,
      mentions: options?.mentions,
    });
    session.lastActivityAt = new Date();
    this.broadcastCodexQueue(session);
    return true;
  }

  cancelCodexQueuedInput(id: string, itemId: string): boolean {
    const session = this.sessions.get(id);
    if (!session || session.provider !== "codex") return false;
    const current = codexQueuedInputsForSession(session).find(
      (candidate) => candidate.itemId === itemId,
    );
    if (!current) return false;
    this.removeCodexQueuedInput(session, current);
    session.lastActivityAt = new Date();
    this.broadcastCodexQueue(session);
    return true;
  }

  async steerCodexQueuedInput(
    id: string,
    itemId: string,
    expectedTurnId: string,
    isExpectedTurnCurrent?: () => boolean,
    allowExternalSharedRuntimeTurn = false,
  ): Promise<{ ok: true } | { ok: false; error: string }> {
    const session = this.sessions.get(id);
    if (!session || session.provider !== "codex") {
      return { ok: false, error: "No active Codex session." };
    }
    const queued = codexQueuedInputsForSession(session).find(
      (candidate) => candidate.itemId === itemId,
    );
    if (!queued) {
      return { ok: false, error: "Queued message not found." };
    }
    if (!(session.process instanceof CodexProcess)) {
      return { ok: false, error: "No active Codex process." };
    }
    if (!expectedTurnId || isExpectedTurnCurrent?.() === false) {
      return {
        ok: false,
        error: "The target turn changed before guidance was applied.",
      };
    }

    try {
      const options = {
        images: queued.images,
        skills: queued.skills,
        mentions: queued.mentions,
        ...(queued.clientMessageId
          ? { clientMessageId: queued.clientMessageId }
          : {}),
      };
      if (isExpectedTurnCurrent?.() === false) {
        return {
          ok: false,
          error: "The target turn changed before guidance was applied.",
        };
      }
      if (queued.clientMessageId && this.inputDeliveryLedger) {
        const identity = this.inputDeliveryIdentity(
          session,
          queued.clientMessageId,
        );
        if (!identity) {
          return {
            ok: false,
            error:
              "The Codex thread identity is not ready for durable delivery.",
          };
        }
        await this.inputDeliveryLedger.markDispatching(identity, "turn/steer");
      }
      if (allowExternalSharedRuntimeTurn) {
        await session.process.steerExternalTurnStructured(
          expectedTurnId,
          queued.text,
          options,
        );
      } else {
        await session.process.steerTurnStructured(
          expectedTurnId,
          queued.text,
          options,
        );
      }
    } catch (err) {
      return {
        ok: false,
        error: err instanceof Error ? err.message : String(err),
      };
    }

    // Re-resolve the stable session after the asynchronous RPC. A Desktop
    // history refresh may have atomically swapped the underlying process while
    // guidance was in flight. Clear only the exact queue object that was sent;
    // edits/cancels replace that object and therefore remain queued.
    const currentSession = this.sessions.get(id);
    if (!currentSession || currentSession.provider !== "codex") {
      return { ok: true };
    }
    if (codexQueuedInputsForSession(currentSession).includes(queued)) {
      this.removeCodexQueuedInput(currentSession, queued);
      currentSession.lastActivityAt = new Date();
      this.broadcastCodexQueue(currentSession);
    }

    const userMsg = this.buildQueuedUserInputMessage(queued);
    this.appendHistoryToSession(currentSession, userMsg);
    this.markPendingCodexUserEcho(currentSession, userMsg);
    this.onMessage(currentSession.id, userMsg);
    return { ok: true };
  }

  private broadcastCodexQueue(session: SessionInfo): void {
    const items = codexQueuedInputsForSession(session)
      .map((item) =>
        publicQueuedInput(
          item,
          item.clientMessageId
            ? session.inputDeliveryReceipts?.get(item.clientMessageId)
            : undefined,
        ),
      )
      .filter((item): item is QueuedInputItem => item !== undefined);
    this.onMessage(session.id, {
      type: "conversation_queue",
      sessionId: session.id,
      limit: MAX_CODEX_QUEUED_INPUTS,
      items,
    });
  }

  /**
   * Close the narrow race where a queued handoff arrives immediately after a
   * refreshed Codex runtime already emitted input_ready.
   */
  drainCodexQueuedInputIfReady(
    id: string,
    isStillSafe?: () => boolean,
  ): boolean {
    const session = this.sessions.get(id);
    if (
      isStillSafe?.() === false ||
      !session ||
      session.provider !== "codex" ||
      codexQueuedInputsForSession(session).length === 0 ||
      !(session.process instanceof CodexProcess) ||
      !session.process.isWaitingForInput
    ) {
      return false;
    }
    return this.drainCodexQueue(session);
  }

  private sharedCodexQueueDrainIsSafe(session: SessionInfo): boolean {
    if (!(session.process instanceof CodexProcess)) return false;
    const process = session.process;
    if (!process.usesSharedRuntimeTopology) return true;
    if (
      session.codexAttachmentState !== "connected" ||
      !process.isAttachmentReady
    ) {
      return false;
    }
    return !process.activeTurnId || process.activeTurnIsBridgeOwned;
  }

  private drainCodexQueue(session: SessionInfo): boolean {
    if (session.provider !== "codex") return false;
    const queued = codexQueuedInputsForSession(session)[0];
    if (!queued || !(session.process instanceof CodexProcess)) return false;
    if (!session.process.isWaitingForInput) return false;
    if (!this.sharedCodexQueueDrainIsSafe(session)) {
      this.codexQueueDrainHooks.onBlocked?.(session);
      return false;
    }
    if (this.codexQueueDrainHooks.canDrain?.(session) === false) {
      this.codexQueueDrainHooks.onBlocked?.(session);
      return false;
    }

    if (queued.clientMessageId && this.inputDeliveryLedger) {
      const identity = this.inputDeliveryIdentity(
        session,
        queued.clientMessageId,
      );
      if (!identity) {
        this.codexQueueDrainHooks.onBlocked?.(session);
        return false;
      }
      if (this.codexQueueDrainInFlight.has(session.id)) return true;
      this.codexQueueDrainInFlight.set(session.id, queued);
      void this.inputDeliveryLedger
        .markDispatching(identity, "turn/start")
        .then(() => {
          const current = this.sessions.get(session.id);
          if (
            current !== session ||
            codexQueuedInputsForSession(current)[0] !== queued ||
            !(current.process instanceof CodexProcess) ||
            !current.process.isWaitingForInput ||
            !this.sharedCodexQueueDrainIsSafe(current) ||
            this.codexQueueDrainHooks.canDrain?.(current) === false
          ) {
            return;
          }
          this.dispatchCodexQueueNow(current, queued);
        })
        .catch((error) => {
          console.error(
            "[session] Failed to persist Codex queue dispatch:",
            error instanceof Error ? error.name : "UnknownError",
          );
          this.codexQueueDrainHooks.onBlocked?.(session);
        })
        .finally(() => {
          if (this.codexQueueDrainInFlight.get(session.id) === queued) {
            this.codexQueueDrainInFlight.delete(session.id);
          }
        });
      return true;
    }

    this.dispatchCodexQueueNow(session, queued);
    return true;
  }

  private dispatchCodexQueueNow(
    session: SessionInfo,
    queued: QueuedCodexInput,
  ): void {
    if (
      this.sessions.get(session.id) !== session ||
      codexQueuedInputsForSession(session)[0] !== queued ||
      !(session.process instanceof CodexProcess)
    ) {
      return;
    }

    this.removeCodexQueuedInput(session, queued);
    this.broadcastCodexQueue(session);

    const userMsg = this.buildQueuedUserInputMessage(queued);
    this.appendHistoryToSession(session, userMsg);
    this.markPendingCodexUserEcho(session, userMsg);
    this.onMessage(session.id, userMsg);

    try {
      session.process.sendInputStructured(queued.text, {
        images: queued.images,
        skills: queued.skills,
        mentions: queued.mentions,
        ...(queued.clientMessageId
          ? { clientMessageId: queued.clientMessageId }
          : {}),
        ...(queued.recoveryRequiresClientUserMessageId
          ? { requireClientUserMessageId: true }
          : {}),
      });
    } catch (error) {
      if (!queued.clientMessageId) throw error;
      const pendingReceipt = this.recordCodexInputDispatchFailure(
        session.id,
        queued.clientMessageId,
        error,
      );
      const publish = (receipt: InputDeliveryReceipt | undefined): void => {
        if (
          !receipt ||
          receipt.stage === "bridge_accepted" ||
          !receipt.method ||
          this.sessions.get(session.id) !== session
        ) {
          return;
        }
        this.onMessage(session.id, {
          type: "input_delivery_status_v1",
          sessionId: session.id,
          clientMessageId: receipt.clientMessageId,
          stage: receipt.stage,
          provider: "codex",
          method: receipt.method,
          occurredAt: receipt.occurredAt,
          acceptedSeq: receipt.acceptedSeq,
          queued: receipt.queued,
          ...(receipt.error ? { error: receipt.error } : {}),
        });
      };
      if (pendingReceipt instanceof Promise) {
        void pendingReceipt.then(publish).catch((failure) => {
          console.error(
            "[session] Failed to persist Codex queue dispatch rejection:",
            failure instanceof Error ? failure.name : "UnknownError",
          );
        });
      } else {
        publish(pendingReceipt);
      }
    }
  }

  private notifySharedAttachmentState(
    session: SessionInfo,
    state: "connected" | "reconciling" | "unavailable",
  ): void {
    if (this.sessions.get(session.id) !== session) return;
    const previousState = session.codexAttachmentState;
    const previousStatus = session.status;
    session.codexAttachmentState = state;
    if (state !== "connected") session.status = "starting";
    if (
      previousState === session.codexAttachmentState &&
      previousStatus === session.status
    ) {
      return;
    }
    // Attachment-state changes are projected through the runtime state engine
    // and session-list update. Do not rebroadcast the same public `starting`
    // status on every retry phase; that created duplicate status/history/UI
    // churn without adding information.
    if (previousStatus !== session.status) {
      this.onMessage(session.id, {
        type: "status",
        status: session.status,
      } as ServerMessage);
    }
    this.onSessionUpdated?.(session.id);
  }

  private beginSharedCodexAttachmentRecovery(session: SessionInfo): void {
    if (
      this.sessions.get(session.id) !== session ||
      session.provider !== "codex" ||
      !(session.process instanceof CodexProcess) ||
      !session.claudeSessionId ||
      this.sharedAttachmentRecoveries.has(session.id)
    ) {
      return;
    }
    const recovery: SharedCodexAttachmentRecovery = {
      generation: ++this.sharedAttachmentGeneration,
      attempt: 0,
      session,
    };
    this.sharedAttachmentRecoveries.set(session.id, recovery);
    this.scheduleSharedCodexAttachmentRecovery(recovery);
  }

  private scheduleSharedCodexAttachmentRecovery(
    recovery: SharedCodexAttachmentRecovery,
  ): void {
    if (this.sharedAttachmentRecoveries.get(recovery.session.id) !== recovery) {
      return;
    }
    const delayMs = Math.min(
      SHARED_ATTACHMENT_RETRY_MAX_MS,
      SHARED_ATTACHMENT_RETRY_INITIAL_MS * 2 ** Math.min(recovery.attempt, 8),
    );
    recovery.timer = setTimeout(() => {
      recovery.timer = undefined;
      void this.attemptSharedCodexAttachmentRecovery(recovery);
    }, delayMs);
    recovery.timer.unref?.();
  }

  private async attemptSharedCodexAttachmentRecovery(
    recovery: SharedCodexAttachmentRecovery,
  ): Promise<void> {
    const sessionId = recovery.session.id;
    if (
      this.sharedAttachmentRecoveries.get(sessionId) !== recovery ||
      this.sessions.get(sessionId) !== recovery.session
    ) {
      return;
    }
    const threadId = recovery.session.claudeSessionId;
    if (!threadId) {
      this.cancelSharedCodexAttachmentRecovery(sessionId);
      return;
    }

    this.notifySharedAttachmentState(recovery.session, "reconciling");
    const abortController = new AbortController();
    recovery.replacementAbort = abortController;
    const recoveryGeneration = recovery.generation;
    let committed = false;
    const recoveryStillCurrent = (): boolean =>
      this.sharedAttachmentRecoveries.get(sessionId) === recovery &&
      recovery.generation === recoveryGeneration;
    const stillValid = (): boolean =>
      recoveryStillCurrent() &&
      this.sessions.get(sessionId) === recovery.session;
    try {
      await this.replaceCodexSession(
        sessionId,
        recovery.session.projectPath,
        [],
        recovery.session.worktreePath
          ? {
              existingWorktreePath: recovery.session.worktreePath,
              worktreeBranch: recovery.session.worktreeBranch,
            }
          : undefined,
        {
          threadId,
          sharedRuntimeAttach: "adoption",
        },
        SHARED_ATTACHMENT_READY_TIMEOUT_MS,
        stillValid,
        abortController.signal,
        (attachedSession) => {
          // `commitReplacement` has already atomically installed the fresh
          // session, so the pre-commit identity predicate is expected to be
          // false here. The recovery record/generation is the handoff fence.
          if (!recoveryStillCurrent()) return;
          committed = true;
          recovery.replacementAbort = undefined;
          // Delete the old recovery record before any callback or subsequent
          // process event can run. A replacement that exits immediately after
          // input_ready will then create a fresh recovery generation.
          this.sharedAttachmentRecoveries.delete(sessionId);
          attachedSession.codexAttachmentState = "connected";
          if (attachedSession.status !== recovery.session.status) {
            const statusMessage = {
              type: "status",
              status: attachedSession.status,
            } as ServerMessage;
            this.appendHistoryToSession(attachedSession, statusMessage);
            this.onMessage(sessionId, statusMessage);
          }
        },
      );
    } catch {
      if (this.sharedAttachmentRecoveries.get(sessionId) !== recovery) return;
      recovery.replacementAbort = undefined;
      recovery.attempt += 1;
      this.notifySharedAttachmentState(recovery.session, "unavailable");
      this.scheduleSharedCodexAttachmentRecovery(recovery);
      return;
    }

    // A successful commit synchronously removed this recovery generation at
    // the swap boundary. If it did not, treat the result as non-authoritative
    // and retry against the still-current public session.
    if (committed) return;
    if (this.sharedAttachmentRecoveries.get(sessionId) !== recovery) return;
    recovery.replacementAbort = undefined;
    if (this.sessions.get(sessionId) !== recovery.session) {
      this.sharedAttachmentRecoveries.delete(sessionId);
      return;
    }
    recovery.attempt += 1;
    this.notifySharedAttachmentState(recovery.session, "unavailable");
    this.scheduleSharedCodexAttachmentRecovery(recovery);
  }

  private cancelSharedCodexAttachmentRecovery(sessionId: string): void {
    const recovery = this.sharedAttachmentRecoveries.get(sessionId);
    if (!recovery) return;
    this.sharedAttachmentRecoveries.delete(sessionId);
    if (recovery.timer) clearTimeout(recovery.timer);
    recovery.replacementAbort?.abort();
  }

  private buildQueuedUserInputMessage(queued: QueuedCodexInput): ServerMessage {
    return {
      type: "user_input",
      text: queued.text,
      ...(queued.userMessageUuid
        ? { userMessageUuid: queued.userMessageUuid }
        : {}),
      ...(queued.clientMessageId
        ? { clientMessageId: queued.clientMessageId }
        : {}),
      timestamp: new Date().toISOString(),
      ...(queued.imageCount ? { imageCount: queued.imageCount } : {}),
      ...(queued.imageRefs ? { images: queued.imageRefs } : {}),
    } as ServerMessage;
  }

  private recordProviderInputDelivery(
    session: SessionInfo,
    event: CodexInputDeliveryEvent,
  ):
    | InputDeliveryReceipt
    | undefined
    | Promise<InputDeliveryReceipt | undefined> {
    const existing = session.inputDeliveryReceipts?.get(event.clientMessageId);
    if (
      existing?.stage === "provider_accepted" ||
      existing?.stage === "provider_rejected"
    ) {
      return undefined;
    }
    const publish = (
      durable?: DurableInputDeliveryRecord,
    ): InputDeliveryReceipt => {
      const receipt: InputDeliveryReceipt = durable
        ? this.receiptFromDurableInput(durable)
        : {
            clientMessageId: event.clientMessageId,
            stage: event.stage,
            acceptedSeq: existing?.acceptedSeq ?? session.historyRevision,
            queued: existing?.queued ?? false,
            provider: "codex",
            method: event.method,
            occurredAt: event.occurredAt,
            ...(event.clientUserMessageIdAccepted === undefined
              ? {}
              : {
                  clientUserMessageIdAccepted:
                    event.clientUserMessageIdAccepted,
                }),
            ...(event.error ? { error: event.error } : {}),
          };
      this.storeInputDeliveryReceipt(session, receipt);
      if (
        codexQueuedInputsForSession(session).some(
          (item) => item.clientMessageId === event.clientMessageId,
        )
      ) {
        this.broadcastCodexQueue(session);
      }
      return receipt;
    };
    const identity = this.inputDeliveryIdentity(session, event.clientMessageId);
    if (this.inputDeliveryLedger && identity) {
      return this.inputDeliveryLedger
        .recordProviderOutcome({
          identity,
          stage: event.stage,
          method: event.method,
          occurredAt: event.occurredAt,
          ...(event.clientUserMessageIdAccepted === undefined
            ? {}
            : {
                clientUserMessageIdAccepted: event.clientUserMessageIdAccepted,
              }),
          ...(event.error ? { error: event.error } : {}),
        })
        .then(publish);
    }
    return publish();
  }

  private storeInputDeliveryReceipt(
    session: SessionInfo,
    receipt: InputDeliveryReceipt,
  ): void {
    const receipts =
      session.inputDeliveryReceipts ?? new Map<string, InputDeliveryReceipt>();
    session.inputDeliveryReceipts = receipts;
    receipts.delete(receipt.clientMessageId);
    receipts.set(receipt.clientMessageId, receipt);
    while (receipts.size > MAX_INPUT_DELIVERY_RECEIPTS_PER_SESSION) {
      const oldest = receipts.keys().next().value;
      if (oldest === undefined) break;
      receipts.delete(oldest);
    }
  }

  getCachedCommands(
    provider: Provider,
    effectiveCwd: string,
  ):
    | {
        slashCommands: string[];
        skills: string[];
        skillMetadata?: Array<Record<string, unknown>>;
        apps: string[];
        appMetadata?: Array<Record<string, unknown>>;
        plugins: string[];
        pluginMetadata?: Array<Record<string, unknown>>;
      }
    | undefined {
    return this.commandCache.get(this.commandCacheKey(provider, effectiveCwd));
  }

  private commandCacheKey(provider: Provider, effectiveCwd: string): string {
    return `${provider}\u0000${effectiveCwd}`;
  }

  /** Get worktree store for external use (e.g., resume_session in websocket.ts). */
  getWorktreeStore(): WorktreeStore | null {
    return this.worktreeStore;
  }

  /** Save worktree mapping when a provider session ID is available. */
  private saveWorktreeMapping(session: SessionInfo): void {
    if (
      !session.auxiliary &&
      this.worktreeStore &&
      session.claudeSessionId &&
      session.worktreePath &&
      session.worktreeBranch
    ) {
      this.worktreeStore.set(session.claudeSessionId, {
        worktreePath: session.worktreePath,
        worktreeBranch: session.worktreeBranch,
        projectPath: session.projectPath,
      });
    }
  }

  /**
   * Rewind files to their state at the specified user message.
   * Delegates to the session's SdkProcess.rewindFiles().
   */
  async rewindFiles(
    id: string,
    targetUuid: string,
    dryRun?: boolean,
  ): Promise<RewindFilesResult> {
    const session = this.sessions.get(id);
    if (!session) {
      return { canRewind: false, error: "Session not found" };
    }
    if (session.provider === "codex") {
      return {
        canRewind: false,
        error: "Rewind is not supported for Codex sessions",
      };
    }
    return (session.process as SdkProcess).rewindFiles(targetUuid, dryRun);
  }

  /**
   * Rewind the conversation to just before a specific user message.
   * Stops the current process and restarts with resumeSessionAt pointing at
   * the assistant message before the selected user message. If the selected
   * message is the first turn, there is no previous assistant boundary, so a
   * fresh empty Claude session is created.
   */
  rewindConversation(
    id: string,
    targetUuid: string,
    onReady: (newSessionId: string) => void,
  ): void {
    const session = this.sessions.get(id);
    if (!session) {
      throw new Error(`Session ${id} not found`);
    }
    if (session.provider === "codex") {
      throw new Error("Rewind is not supported for Codex sessions");
    }

    const claudeSessionId = session.claudeSessionId;
    if (!claudeSessionId) {
      throw new Error("Session has no Claude session ID");
    }

    const assistantUuid = this.findAssistantUuidBeforeUser(session, targetUuid);

    const projectPath = session.projectPath;
    const permissionMode = (session.process as SdkProcess).permissionMode;
    const worktreePath = session.worktreePath;
    const worktreeBranch = session.worktreeBranch;

    // Stop and destroy the current session
    this.destroy(id);

    // Create a new session with resumeSessionAt (assistant UUID). When there
    // is no previous assistant, start empty rather than keeping the selected
    // user turn in history.
    const newId = this.create(
      projectPath,
      assistantUuid
        ? {
            sessionId: claudeSessionId,
            permissionMode,
            resumeSessionAt: assistantUuid,
          }
        : { permissionMode },
      undefined,
      worktreePath
        ? { existingWorktreePath: worktreePath, worktreeBranch }
        : undefined,
    );

    onReady(newId);
  }

  /**
   * Find the assistant message UUID immediately before a given user message UUID.
   *
   * Searches in-memory history first, then pastMessages (disk history).
   */
  private findAssistantUuidBeforeUser(
    session: SessionInfo,
    userUuid: string,
  ): string | null {
    // 1. Search in-memory history
    let previousAssistantUuid: string | null = null;
    for (const msg of session.history) {
      if (msg.type === "assistant" && "messageUuid" in msg && msg.messageUuid) {
        previousAssistantUuid = msg.messageUuid as string;
        continue;
      }
      if (
        (msg.type === "user_input" || msg.type === "tool_result") &&
        "userMessageUuid" in msg &&
        msg.userMessageUuid === userUuid
      ) {
        return previousAssistantUuid;
      }
    }

    // 2. Search pastMessages (disk history with uuid field)
    if (session.pastMessages) {
      previousAssistantUuid = null;
      for (const raw of session.pastMessages) {
        const pm = raw as { role?: string; uuid?: string };
        if (pm.role === "assistant" && pm.uuid) {
          previousAssistantUuid = pm.uuid;
          continue;
        }
        if (pm.role === "user" && pm.uuid === userUuid) {
          return previousAssistantUuid;
        }
      }
    }

    return null;
  }

  /**
   * Read the Claude CLI conversation history file from disk and backfill
   * `userMessageUuid` into in-memory history entries that are missing it.
   *
   * The SDK does not echo user messages via the stream, so in-memory
   * `user_input` entries (pushed by websocket.ts) lack UUIDs.  The disk
   * file, however, always contains UUIDs.  We match by text content.
   *
   * Also re-broadcasts the updated `user_input` message so the Flutter
   * client can update its UserChatEntry.messageUuid values.
   */
  private backfillUserUuidsFromDisk(session: SessionInfo): void {
    if (!session.claudeSessionId || !session.projectPath) return;

    const historyPath = this.findHistoryJsonlPath(session);
    if (!historyPath) return;

    let lines: string[];
    try {
      const raw = readFileSync(historyPath, "utf-8").trim();
      if (!raw) return;
      lines = raw.split("\n");
    } catch {
      // File may not exist yet (e.g., very new session)
      return;
    }

    // Collect user message text→uuid queue from disk.
    // Use an array per text key so duplicate messages ("yes", "ok", etc.)
    // are matched in order rather than collapsed to one UUID.
    const diskUuids = new Map<string, string[]>();
    for (const line of lines) {
      try {
        const entry = JSON.parse(line) as {
          type?: string;
          role?: string;
          uuid?: string;
          message?: { content?: unknown[] };
        };
        if (entry.type !== "user" && entry.role !== "user") continue;
        if (!entry.uuid) continue;

        // Extract text from content array
        const content = entry.message?.content;
        if (!Array.isArray(content)) continue;
        const texts = content
          .filter(
            (c: unknown) => (c as Record<string, unknown>).type === "text",
          )
          .map((c: unknown) => (c as Record<string, unknown>).text as string);
        if (texts.length > 0) {
          const key = texts.join("\n");
          const arr = diskUuids.get(key) ?? [];
          arr.push(entry.uuid);
          diskUuids.set(key, arr);
        }
      } catch {
        // skip malformed lines
      }
    }

    // Backfill UUIDs into in-memory history
    for (const msg of session.history) {
      if (
        msg.type === "user_input" &&
        !(
          "userMessageUuid" in msg &&
          (msg as Record<string, unknown>).userMessageUuid
        )
      ) {
        const text = (msg as { text?: string }).text;
        const queue = text ? diskUuids.get(text) : undefined;
        if (queue && queue.length > 0) {
          (msg as Record<string, unknown>).userMessageUuid = queue.shift();
          // Re-broadcast so Flutter can update UserChatEntry.messageUuid
          this.onMessage(session.id, msg);
        }
      }
    }
  }

  private findHistoryJsonlPath(session: SessionInfo): string | null {
    if (!session.claudeSessionId) return null;

    const projectsDir = join(homedir(), ".claude", "projects");
    const fileName = `${session.claudeSessionId}.jsonl`;
    const slugCandidates = new Set<string>([pathToSlug(session.projectPath)]);

    // Worktree sessions are persisted under the worktree slug, not projectPath.
    if (session.worktreePath) {
      slugCandidates.add(pathToSlug(session.worktreePath));
    }

    for (const slug of slugCandidates) {
      const candidate = join(projectsDir, slug, fileName);
      if (existsSync(candidate)) return candidate;
    }

    // Fallback: scan all project dirs in case metadata paths drift.
    try {
      const entries = readdirSync(projectsDir, { withFileTypes: true });
      for (const entry of entries) {
        if (!entry.isDirectory() || entry.name.startsWith(".")) continue;
        const candidate = join(projectsDir, entry.name, fileName);
        if (existsSync(candidate)) return candidate;
      }
    } catch {
      return null;
    }

    return null;
  }

  /**
   * Rename a running session (in-memory only).
   * Persistent storage is handled by the caller (websocket.ts).
   */
  renameSession(id: string, name: string | null): boolean {
    const session = this.sessions.get(id);
    if (!session) return false;
    session.name = name ?? undefined;
    session.autoRenameAttempted = true;
    return true;
  }

  destroy(id: string): boolean {
    const session = this.sessions.get(id);
    if (!session) return false;
    this.cancelSharedCodexAttachmentRecovery(id);
    const childIds = Array.from(this.sessions.values())
      .filter(
        (candidate) =>
          candidate.auxiliary?.kind === "ephemeral_side_chat" &&
          candidate.auxiliary.parentSessionId === id,
      )
      .map((candidate) => candidate.id);
    for (const childId of childIds) this.destroy(childId);
    // Remove first so synchronous status/exit events from stop() cannot try to
    // evict the same session recursively.
    this.retiredSessions.add(session);
    this.sessions.delete(id);
    session.process.stop();
    session.process.removeAllListeners();
    console.log(`[session] Destroyed session ${id}`);
    return true;
  }

  private evictStaleIdleSessions(): void {
    const staleIdleSessions = Array.from(this.sessions.values())
      .filter((session) => session.status === "idle" && !session.auxiliary)
      .sort(
        (left, right) =>
          left.lastActivityAt.getTime() - right.lastActivityAt.getTime(),
      )
      .slice(0, Math.max(0, this.idleSessionCount() - MAX_IDLE_SESSIONS));

    for (const session of staleIdleSessions) {
      console.log(
        `[session] Evicting idle session ${session.id} (last active ${session.lastActivityAt.toISOString()})`,
      );
      this.destroy(session.id);
    }
    if (staleIdleSessions.length > 0) {
      this.onSessionUpdated?.(staleIdleSessions.at(-1)!.id);
    }
  }

  private idleSessionCount(): number {
    let count = 0;
    for (const session of this.sessions.values()) {
      if (session.status === "idle" && !session.auxiliary) count += 1;
    }
    return count;
  }

  destroyAll(): void {
    for (const [id] of this.sessions) {
      this.destroy(id);
    }
  }
}
