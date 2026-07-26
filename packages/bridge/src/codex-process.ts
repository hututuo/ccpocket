import { EventEmitter } from "node:events";
import { randomUUID } from "node:crypto";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { rm, writeFile } from "node:fs/promises";
import type {
  CodexGoal,
  CodexGoalWritableStatus,
  GuardianReviewDetails,
  ServerMessage,
  ProcessStatus,
} from "./parser.js";
import type { ArtifactCandidate } from "./artifact-types.js";
import {
  createCodexTransport,
  buildCodexSpawnSpec,
  type CodexTransport,
} from "./codex-transport.js";
import { codexCliJoinTarget } from "./codex-app-server-config.js";
import { resolvePlatformPath } from "./path-utils.js";
import { parseSessionInsightsNotification } from "./local-features/slots/session-insights.js";
import { CodexAgentTurnTracker } from "./local-features/codex-agent-turn-tracker.js";
import {
  normalizeCodexServiceTier as normalizeServiceTier,
  normalizeCodexServiceTierForClient as normalizeServiceTierForClient,
} from "./codex-service-tier.js";

export { buildCodexSpawnSpec };

const DEFAULT_CODEX_MODEL = "gpt-5.5";
const COMPLETION_FETCH_COOLDOWN_MS = 1000;
const NATIVE_PLAN_MODE_PROBE_TIMEOUT_MS = 1500;
const NATIVE_PLAN_MODE_EXPLICIT_PROBE_TIMEOUT_MS = 5000;
const GUARDIAN_REVIEW_ENRICHMENT_DELAY_MS = 75;
const CODEX_CLI_NOT_FOUND_MESSAGE =
  "Codex CLI is not installed or not available on PATH on the Bridge machine. Install it with `curl -fsSL https://chatgpt.com/codex/install.sh | sh`, then restart Bridge.";

export interface CodexStartOptions {
  threadId?: string;
  /** Start this process by forking a persisted thread into another persisted thread. */
  forkFromThreadId?: string;
  /** Start this process by forking a persisted thread into memory only. */
  ephemeralForkFromThreadId?: string;
  /** Avoid returning the full inherited transcript in start/resume/fork responses. */
  excludeTurnsOnOpen?: boolean;
  /** Optional app-server analytics source for a newly started or forked thread. */
  threadSource?: string;
  profile?: string;
  additionalWritableRoots?: string[];
  approvalPolicy?: "never" | "on-request" | "on-failure" | "untrusted";
  approvalsReviewer?: "user" | "auto_review" | "guardian_subagent";
  codexPermissionsMode?: "default" | "autoReview" | "fullAccess" | "custom";
  sandboxMode?: "read-only" | "workspace-write" | "danger-full-access";
  model?: string;
  modelReasoningEffort?: string;
  serviceTier?: string;
  networkAccessEnabled?: boolean;
  webSearchMode?: "disabled" | "cached" | "live";
  collaborationMode?: "plan" | "default";
  /** Resume a goal that Bridge paused only to perform an immediate restart. */
  resumeGoalAfterStart?: boolean;
  /**
   * Identifies the exact paused Goal that may be resumed after a restart.
   * Legacy callers may continue to use resumeGoalAfterStart without a lease.
   */
  resumeGoalLease?: CodexGoalResumeLease;
  /** Continue one ordinary turn that Bridge interrupted only for a restart. */
  continueInterruptedTurnAfterStart?: boolean;
  /** Compatibility fallback when this app-server rejects an empty turn. */
  continuationFallbackText?: string;
  /**
   * Managed Browser Use policy cached by Bridge metadata loading.
   * `null` means app-server must read the policy before starting the thread.
   */
  autoReviewDisabledByPolicy?: boolean | null;
}

/** Stable identity and pause watermark for a restart-owned Goal pause. */
export interface CodexGoalResumeLease {
  threadId: string;
  objective: string;
  tokenBudget: number | null;
  tokensUsed: number;
  timeUsedSeconds: number;
  createdAt: number;
  pausedUpdatedAt: number;
}

export interface CodexGoalSnapshot {
  goal: CodexGoal | null;
  /** False when a Goal notification overtook this read on the same runtime. */
  stable: boolean;
}

export interface CodexGoalMutationOptions {
  /** Runs synchronously after the settings barrier and a stable authoritative read. */
  validateCurrentGoal?: (goal: CodexGoal | null) => void;
}

export class CodexGoalSnapshotConflictError extends Error {
  constructor() {
    super("Goal state changed while its mutation preflight was in progress");
    this.name = "CodexGoalSnapshotConflictError";
  }
}

class CodexGoalResumeLeaseMismatchError extends Error {
  constructor(readonly goal: CodexGoal | null) {
    super("The paused Goal no longer matches the restart lease");
    this.name = "CodexGoalResumeLeaseMismatchError";
  }
}

export function createCodexGoalResumeLease(
  goal: CodexGoal,
): CodexGoalResumeLease {
  return {
    threadId: goal.threadId,
    objective: goal.objective,
    tokenBudget: goal.tokenBudget,
    tokensUsed: goal.tokensUsed,
    timeUsedSeconds: goal.timeUsedSeconds,
    createdAt: goal.createdAt,
    pausedUpdatedAt: goal.updatedAt,
  };
}

/** A lease can only resume the same still-paused Goal, never a replacement. */
export function matchesCodexGoalResumeLease(
  goal: CodexGoal | null,
  lease: CodexGoalResumeLease,
): goal is CodexGoal {
  return (
    goal !== null &&
    goal.status === "paused" &&
    goal.threadId === lease.threadId &&
    goal.objective === lease.objective &&
    goal.tokenBudget === lease.tokenBudget &&
    goal.tokensUsed >= lease.tokensUsed &&
    goal.timeUsedSeconds >= lease.timeUsedSeconds &&
    goal.createdAt === lease.createdAt &&
    goal.updatedAt >= lease.pausedUpdatedAt
  );
}

export interface CodexNextTurnPermissionSettings {
  approvalPolicy?: CodexStartOptions["approvalPolicy"] | null;
  approvalsReviewer?: CodexStartOptions["approvalsReviewer"] | null;
  codexPermissionsMode?: CodexStartOptions["codexPermissionsMode"];
  sandboxMode?: CodexStartOptions["sandboxMode"] | null;
}

type CodexSandboxPolicy =
  | { type: "dangerFullAccess" }
  | { type: "readOnly"; networkAccess: boolean }
  | {
      type: "workspaceWrite";
      writableRoots: string[];
      networkAccess: boolean;
      excludeTmpdirEnvVar: boolean;
      excludeSlashTmp: boolean;
    };

export interface CodexProcessEvents {
  message: [ServerMessage];
  status: [ProcessStatus];
  exit: [number | null];
  input_ready: [];
}

interface PendingInput {
  text: string;
  /** Persisted by app-server as UserMessageThreadItem.clientId. */
  clientMessageId?: string;
  images?: Array<{
    base64: string;
    mimeType: string;
  }>;
  skills?: Array<{
    name: string;
    path: string;
  }>;
  mentions?: Array<{
    name: string;
    path: string;
  }>;
}

export interface CodexRpcRequestOptions {
  timeoutMs?: number;
  signal?: AbortSignal;
}

export class CodexRpcError extends Error {
  constructor(
    public readonly method: string,
    message: string,
    public readonly code?: number,
    public readonly data?: unknown,
  ) {
    super(message);
    this.name = "CodexRpcError";
  }
}

export class CodexNativePlanModeUnsupportedError extends Error {
  constructor() {
    super(
      "Native Codex Plan mode is unavailable on this app-server. The conversation was not started in Plan mode.",
    );
    this.name = "CodexNativePlanModeUnsupportedError";
  }
}

export class CodexNativePlanModeProbeRetryError extends Error {
  constructor() {
    super(
      "Native Codex Plan mode support could not be confirmed. Retry after the app-server becomes responsive.",
    );
    this.name = "CodexNativePlanModeProbeRetryError";
  }
}

export type CodexCoreActionPreconditionCode =
  "thread_unavailable" | "session_busy";

export class CodexCoreActionPreconditionError extends Error {
  constructor(
    public readonly code: CodexCoreActionPreconditionCode,
    message: string,
  ) {
    super(message);
    this.name = "CodexCoreActionPreconditionError";
  }
}

export type CodexReviewTarget =
  | { type: "uncommittedChanges" }
  | { type: "baseBranch"; branch: string }
  | { type: "commit"; sha: string; title: string | null }
  | { type: "custom"; instructions: string };

export interface CodexInlineReviewStartResult {
  turnId: string;
  reviewThreadId: string;
}

export interface CodexMcpServerStatusPage {
  data: unknown[];
  nextCursor: string | null;
}

const CODEX_MCP_STATUS_PAGE_SIZE = 64;
const CODEX_CORE_ACTION_START_TIMEOUT_MS = 15_000;
function isUnsupportedClientUserMessageIdError(error: unknown): boolean {
  if (!(error instanceof CodexRpcError)) return false;
  let detail = error.message;
  try {
    detail += ` ${JSON.stringify(error.data)}`;
  } catch {}
  return (
    /clientUserMessageId|client_user_message_id/i.test(detail) &&
    /unknown|unexpected|unsupported|unrecognized|invalid|additional field/i.test(
      detail,
    )
  );
}

interface PendingRpc {
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
  method: string;
  goalOrderingGeneration?: number;
  timeout?: ReturnType<typeof setTimeout>;
  signal?: AbortSignal;
  abortListener?: () => void;
}

type CodexCoreActionMethod = "thread/compact/start" | "review/start";

interface PendingCoreAction {
  method: CodexCoreActionMethod;
  phase: "requesting" | "awaiting_start";
  expectedTurnId: string | null;
  observedTurnId: string | null;
  observedTurnCompleted: boolean;
  startTimeout?: ReturnType<typeof setTimeout>;
}

/** Skill metadata returned by the Codex `skills/list` RPC. */
export interface CodexSkillMetadata {
  name: string;
  path: string;
  description: string;
  shortDescription?: string;
  enabled: boolean;
  scope: string;
  displayName?: string;
  defaultPrompt?: string;
  brandColor?: string;
}

/** App / connector metadata returned by the Codex `app/list` RPC. */
export interface CodexAppMetadata {
  id: string;
  name: string;
  description: string;
  installUrl?: string;
  isAccessible: boolean;
  isEnabled: boolean;
}

/** Plugin metadata returned by the Codex `plugin/list` RPC. */
export interface CodexPluginMetadata {
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
}

export interface CodexThreadSummary {
  id: string;
  forkedFromThreadId?: string | null;
  preview: string;
  createdAt: number;
  updatedAt: number;
  cwd: string;
  agentNickname: string | null;
  agentRole: string | null;
  gitBranch: string | null;
  name: string | null;
}

export type CodexThreadSourceKind =
  | "cli"
  | "vscode"
  | "exec"
  | "appServer"
  | "subAgent"
  | "subAgentReview"
  | "subAgentCompact"
  | "subAgentThreadSpawn"
  | "subAgentOther"
  | "unknown";

interface PendingApproval {
  requestId: string | number;
  toolUseId: string;
  toolName: string;
  input: Record<string, unknown>;
  kind: "command" | "file" | "permissions";
  requestedPermissions?: Record<string, unknown>;
}

interface PendingUserInputQuestion {
  id: string;
  question: string;
}

interface PendingUserInputRequest {
  requestId: string | number;
  toolUseId: string;
  toolName: string;
  questions: PendingUserInputQuestion[];
  input: Record<string, unknown>;
  kind:
    | "questions"
    | "elicitation_form"
    | "elicitation_url"
    | "elicitation_approval"
    | "tool_suggestion";
}

interface PendingGuardianReviewWarning {
  review: GuardianReviewDetails;
  message: string;
  timeout: ReturnType<typeof setTimeout>;
}

interface ToolSuggestionApp {
  id: string;
  name: string;
  description?: string;
  installUrl?: string;
  category?: string;
}

interface PendingTurnCompletion {
  resolve: () => void;
  reject: (error: Error) => void;
}

interface RpcSuccess {
  id: number | string;
  result: unknown;
}

interface RpcError {
  id: number | string;
  error: {
    code?: number;
    message?: string;
    data?: unknown;
  };
}

export function isCodexThreadWriterConflict(error: unknown): boolean {
  return (
    error instanceof CodexRpcError &&
    error.code === -32600 &&
    /\b(active|live local)\s+writer\b/i.test(error.message)
  );
}

export function codexErrorMessage(error: unknown): string {
  if (isCodexThreadWriterConflict(error)) {
    return "This Codex thread is already open in another client. Close it there and try again.";
  }
  return error instanceof Error ? error.message : String(error);
}

interface JsonRpcEnvelope {
  id?: number | string;
  method?: string;
  params?: Record<string, unknown>;
  result?: unknown;
  error?: {
    code?: number;
    message?: string;
    data?: unknown;
  };
}

interface CodexResolvedSettings {
  model?: string;
  approvalPolicy?: string;
  approvalsReviewer?: string;
  codexPermissionsMode?: string;
  sandboxMode?: string;
  modelReasoningEffort?: string;
  serviceTier?: string;
  networkAccessEnabled?: boolean;
  webSearchMode?: string;
}

export interface CodexProfileConfig {
  profiles: string[];
  defaultProfile?: string;
}

export interface CodexConfigRequirements {
  autoReviewDisabled: boolean;
}

export interface CodexModelMetadata {
  model: string;
  supportedReasoningEfforts: string[];
  defaultReasoningEffort?: string;
  supportedServiceTiers: string[];
  defaultServiceTier?: string;
}

interface CodexModelListResponse {
  data?: unknown[];
  nextCursor?: unknown;
}

function isCodexCliNotFoundError(err: Error): boolean {
  const code = (err as NodeJS.ErrnoException).code;
  return (
    code === "ENOENT" ||
    /\bspawn codex ENOENT\b/i.test(err.message) ||
    /codex: command not found/i.test(err.message)
  );
}

function codexAppServerStartError(
  err: Error,
): Extract<ServerMessage, { type: "error" }> {
  if (isCodexCliNotFoundError(err)) {
    return {
      type: "error",
      message: CODEX_CLI_NOT_FOUND_MESSAGE,
      errorCode: "codex_cli_not_found",
    };
  }

  return {
    type: "error",
    message: `Failed to start codex app-server: ${err.message}`,
  };
}

export class CodexProcess extends EventEmitter<CodexProcessEvents> {
  private transport: CodexTransport | null = null;
  private _status: ProcessStatus = "starting";
  private _threadId: string | null = null;
  private _agentNickname: string | null = null;
  private _agentRole: string | null = null;
  private stopped = false;
  private startModel: string | undefined;

  private inputResolve: ((input: PendingInput) => void) | null = null;
  private pendingTurnId: string | null = null;
  private lastCompletedTurn: { turnId: string; status: string } | null = null;
  private pendingTurnCompletion: PendingTurnCompletion | null = null;
  private pendingCoreAction: PendingCoreAction | null = null;
  private activeCoreActionTurnId: string | null = null;
  private pendingApprovals = new Map<string, PendingApproval>();
  private pendingUserInputs = new Map<string, PendingUserInputRequest>();
  private pendingGuardianReviewWarnings = new Map<
    string,
    PendingGuardianReviewWarning[]
  >();
  private emittedGuardianReviewIds = new Set<string>();
  private emittedGuardianReviewIdOrder: string[] = [];
  private goalOperationSequence = 0;
  private goalOrderingGeneration = 0;
  private _lastGoalRpcSequence: number | undefined;
  private expectedGoalNotifications: Array<{
    sequence: number;
    kind: "updated" | "cleared";
    goal?: CodexGoal;
    /** A later Goal event/RPC makes a bare clear notification ambiguous. */
    interveningGoalEvent?: boolean;
    expiresAt: number;
  }> = [];
  private lastTokenUsage: {
    input?: number;
    cachedInput?: number;
    output?: number;
  } | null = null;

  /** Full skill metadata from the last `skills/list` response. */
  private _skills: CodexSkillMetadata[] = [];
  /** Full app metadata from the last `app/list` response. */
  private _apps: CodexAppMetadata[] = [];
  /** Full plugin metadata from the last `plugin/list` response. */
  private _plugins: CodexPluginMetadata[] = [];
  /** Project path stored for re-fetching skills on `skills/changed`. */
  private _projectPath: string | null = null;
  /** Prevent redundant completion fetch storms from repeated change notifications. */
  private _completionFetchInFlight: Promise<void> | null = null;
  private _lastCompletionEntitiesSignature: string | null = null;
  private _completionFetchCooldownUntil = 0;
  private _launchStartedAt = 0;

  /** Expose skill metadata so session/websocket can access it. */
  get skills(): CodexSkillMetadata[] {
    return this._skills;
  }

  get apps(): CodexAppMetadata[] {
    return this._apps;
  }

  private rpcSeq = 1;
  private pendingRpc = new Map<number, PendingRpc>();
  /** Sticky per-method downgrade for builds predating clientUserMessageId. */
  private readonly clientUserMessageIdSupport = new Map<
    "turn/start" | "turn/steer",
    boolean
  >();

  private stdoutBuffer = "";

  // Collaboration mode & plan completion state
  private _approvalPolicy: string | null | undefined = undefined;
  private _approvalsReviewer: string | null | undefined = undefined;
  private _codexPermissionsMode:
    CodexStartOptions["codexPermissionsMode"] | undefined;
  private _runtimeSandboxMode: CodexStartOptions["sandboxMode"] | undefined;
  private _runtimeSandboxPolicy: CodexSandboxPolicy | null | undefined;
  private _workspaceWriteSandboxPolicy: CodexSandboxPolicy | undefined;
  private _networkAccessEnabled = false;
  private _additionalWritableRoots: string[] = [];
  private _pendingThreadSettingsUpdate: Promise<void> | null = null;
  private _pendingRuntimeThreadSettingsUpdate: Promise<void> | null = null;
  private _threadSettingsUpdateTail: Promise<void> = Promise.resolve();
  private _supportsNextTurnPermissionUpdates = false;
  private _threadSettingsUpdateMethodSupport:
    "unknown" | "supported" | "unsupported" = "unknown";
  private _autoReviewDisabledByPolicy = false;
  private _collaborationMode: "plan" | "default" = "default";
  private _nativePlanModeSupport: "unknown" | "supported" | "unsupported" =
    "unknown";
  private _nativePlanModeProbe: Promise<boolean> | null = null;
  private _runtimeGeneration = 0;
  private _runtimeModel: string | undefined;
  private _runtimeModelReasoningEffort:
    CodexStartOptions["modelReasoningEffort"] | undefined;
  private _runtimeServiceTier: string | null | undefined;
  private lastPlanItemText: string | null = null;
  /** Last assistant text message — used as `result` in completion notification. */
  private lastResultText: string | null = null;
  private readonly agentTurnTracker = new CodexAgentTurnTracker();
  /** Tool descriptors already emitted at item/started, keyed by stable item id. */
  private readonly startedToolItems = new Map<
    string,
    CodexItemToolDescriptor
  >();
  private pendingPlanCompletion: {
    toolUseId: string;
    planText: string;
  } | null = null;
  /** Queued plan execution text when inputResolve wasn't ready at approval time. */
  private _pendingPlanInput: string | null = null;
  private _idleWhenInteractionsClear = false;
  private steerTempPaths: string[] = [];
  private readonly platform: NodeJS.Platform;

  constructor(platform: NodeJS.Platform = process.platform) {
    super();
    this.platform = platform;
  }

  get status(): ProcessStatus {
    return this._status;
  }

  get isWaitingForInput(): boolean {
    return (
      this.inputResolve !== null &&
      this._status !== "running" &&
      this.pendingCoreAction === null &&
      this.activeCoreActionTurnId === null
    );
  }

  /**
   * Exact app-server turn currently owned by this runtime. Continuity readers
   * must compare this id with rollout lifecycle events; a generic `running`
   * status is not strong enough to distinguish a phone turn from a competing
   * Desktop turn on the same durable thread.
   */
  get activeTurnId(): string | undefined {
    return this.pendingTurnId ?? this.activeCoreActionTurnId ?? undefined;
  }

  /** True only while compact/review is admitted but not yet a normal Turn. */
  get hasPendingCoreAction(): boolean {
    return this.pendingCoreAction !== null;
  }

  private getMessageModel(): string {
    return sanitizeCodexModel(this.startModel) ?? "";
  }

  get sessionId(): string | null {
    return this._threadId;
  }

  /** Sequence of the latest completed Goal RPC on this process. */
  get lastGoalRpcSequence(): number | undefined {
    return this._lastGoalRpcSequence;
  }

  /** Allocate a Bridge-local ordering token for an authoritative changed read. */
  recordAuthoritativeGoalStateChange(): number {
    const sequence = this.nextGoalOperationSequence();
    this._lastGoalRpcSequence = sequence;
    return sequence;
  }

  get agentNickname(): string | null {
    return this._agentNickname;
  }

  get agentRole(): string | null {
    return this._agentRole;
  }

  get isRunning(): boolean {
    return this.transport?.isRunning ?? false;
  }

  /**
   * The resolved approval policy, or undefined while it is unknown (start
   * options omitted it and the app-server did not report a resolved value).
   * Never fabricate a default here: an invented "on-request" ends up on the
   * wire during permission restarts and overrides the user's config policy.
   */
  get approvalPolicy(): string | undefined {
    return this._approvalPolicy ?? undefined;
  }

  get approvalsReviewer(): string {
    return normalizeApprovalsReviewerForClient(
      this._approvalsReviewer as CodexStartOptions["approvalsReviewer"],
    );
  }

  get codexPermissionsMode():
    CodexStartOptions["codexPermissionsMode"] | undefined {
    return this._codexPermissionsMode;
  }

  get supportsNextTurnPermissionUpdates(): boolean {
    return this._supportsNextTurnPermissionUpdates;
  }

  /** True only after this exact app-server process advertises a Plan preset. */
  get supportsNativePlanMode(): boolean {
    return this._nativePlanModeSupport === "supported";
  }

  /** False means the runtime probe is still pending or has not started. */
  get nativePlanModeCapabilityKnown(): boolean {
    return this._nativePlanModeSupport !== "unknown";
  }

  get model(): string {
    return (
      sanitizeCodexModel(this._runtimeModel) ??
      sanitizeCodexModel(this.startModel) ??
      DEFAULT_CODEX_MODEL
    );
  }

  /**
   * Model confirmed by an explicit start option or the app-server response.
   *
   * Unlike [model], this never returns the new-session fallback while a
   * resumed thread is still bootstrapping. Session snapshots must use this
   * getter so opening an existing thread cannot publish a fallback model as
   * authoritative configuration.
   */
  get knownModel(): string | undefined {
    return (
      sanitizeCodexModel(this._runtimeModel) ??
      sanitizeCodexModel(this.startModel)
    );
  }

  get modelReasoningEffort():
    CodexStartOptions["modelReasoningEffort"] | undefined {
    return this._runtimeModelReasoningEffort;
  }

  get serviceTier(): string {
    return this._runtimeServiceTier ?? "standard";
  }

  /** Confirmed service tier, excluding the standard new-session fallback. */
  get knownServiceTier(): string | undefined {
    if (this._runtimeServiceTier == null) return undefined;
    return normalizeServiceTier(this._runtimeServiceTier) ?? undefined;
  }

  /**
   * Update Codex model at runtime.
   * Takes effect on the next `turn/start` RPC call.
   */
  setModel(
    model: string,
    modelReasoningEffort?: CodexStartOptions["modelReasoningEffort"],
  ): void {
    const sanitizedModel = sanitizeCodexModel(model);
    if (sanitizedModel) {
      this._runtimeModel = sanitizedModel;
      this.startModel = sanitizedModel;
    }
    if (modelReasoningEffort !== undefined) {
      this._runtimeModelReasoningEffort =
        normalizeReasoningEffort(modelReasoningEffort);
    }
    console.log(
      `[codex-process] Model changed to: ${this.model}` +
        (this._runtimeModelReasoningEffort
          ? ` (${this._runtimeModelReasoningEffort})`
          : ""),
    );
  }

  /** Update Codex speed for the next turn without restarting the thread. */
  setServiceTier(serviceTier: string): void {
    this._runtimeServiceTier = normalizeServiceTier(serviceTier);
    console.log(`[codex-process] Speed changed to: ${this.serviceTier}`);
  }

  /**
   * Persist the selected model and effort for app-server-owned turns.
   *
   * Normal user turns still receive the same values on `turn/start`. This
   * best-effort experimental update closes the separate Goal continuation
   * path, where app-server starts the next turn without a Bridge RPC.
   */
  persistRuntimeModelForNextTurn(): Promise<boolean> {
    return this.persistRuntimeThreadSettings(this.runtimeModelSettingsParams());
  }

  /** Persist Fast/Standard for app-server-owned Goal continuations. */
  persistRuntimeServiceTierForNextTurn(): Promise<boolean> {
    return this.persistRuntimeThreadSettings({
      serviceTier: this._runtimeServiceTier ?? null,
    });
  }

  /**
   * Update approval policy at runtime.
   * Takes effect on the next `turn/start` RPC call.
   */
  setApprovalPolicy(policy: string): void {
    this._approvalPolicy = policy;
    console.log(`[codex-process] Approval policy changed to: ${policy}`);
  }

  /**
   * Update where approval requests are reviewed at runtime.
   * Takes effect on the next `turn/start` RPC call.
   */
  setApprovalsReviewer(reviewer: string): void {
    this._approvalsReviewer = this._autoReviewDisabledByPolicy
      ? "user"
      : normalizeApprovalsReviewerForAppServer(
          reviewer as CodexStartOptions["approvalsReviewer"],
        );
    console.log(
      `[codex-process] Approvals reviewer changed to: ${this.approvalsReviewer}`,
    );
  }

  /**
   * Persist permission settings for turns that have not started yet.
   *
   * This uses the app-server thread setting rather than only caching values in
   * Bridge. Goal continuations are started by app-server itself, so a local
   * `turn/start` override cannot cover them reliably.
   */
  updatePermissionSettingsForNextTurn(
    settings: CodexNextTurnPermissionSettings,
  ): Promise<void> {
    const operation = this._threadSettingsUpdateTail.then(async () => {
      if (!this._threadId) {
        throw new Error("No thread ID available for permission update");
      }

      const sandboxPolicy =
        settings.sandboxMode === undefined
          ? undefined
          : settings.sandboxMode === null
            ? null
            : await this.buildSandboxPolicy(settings.sandboxMode);
      const params: Record<string, unknown> = { threadId: this._threadId };
      if (settings.approvalPolicy !== undefined) {
        params.approvalPolicy =
          settings.approvalPolicy === null
            ? null
            : normalizeApprovalPolicy(settings.approvalPolicy);
      }
      if (settings.approvalsReviewer !== undefined) {
        params.approvalsReviewer =
          settings.approvalsReviewer === null
            ? null
            : normalizeApprovalsReviewerForAppServer(
                settings.approvalsReviewer,
              );
      }
      if (sandboxPolicy !== undefined) {
        params.sandboxPolicy = sandboxPolicy;
      }

      try {
        await this.request("thread/settings/update", params);
      } catch (err) {
        if (isUnsupportedThreadSettingsMethod(err)) {
          this._threadSettingsUpdateMethodSupport = "unsupported";
          this._supportsNextTurnPermissionUpdates = false;
        }
        throw err;
      }
      this._threadSettingsUpdateMethodSupport = "supported";
      this._supportsNextTurnPermissionUpdates = true;

      if (settings.approvalPolicy !== undefined) {
        this._approvalPolicy = settings.approvalPolicy;
      }
      if (settings.approvalsReviewer !== undefined) {
        this._approvalsReviewer =
          settings.approvalsReviewer === null
            ? null
            : normalizeApprovalsReviewerForAppServer(
                settings.approvalsReviewer,
              );
      }
      if (settings.codexPermissionsMode !== undefined) {
        this._codexPermissionsMode = settings.codexPermissionsMode;
      }
      if (settings.sandboxMode !== undefined) {
        this._runtimeSandboxMode = settings.sandboxMode ?? undefined;
        this._runtimeSandboxPolicy = sandboxPolicy;
        if (sandboxPolicy?.type === "workspaceWrite") {
          this._workspaceWriteSandboxPolicy = sandboxPolicy;
        }
      }
    });

    // Keep later updates serial without letting one rejection poison the tail.
    // The public pending promise remains the real operation so a dependent
    // turn cannot silently pass a failed permission update.
    this._threadSettingsUpdateTail = operation.then(
      () => undefined,
      () => undefined,
    );
    this._pendingThreadSettingsUpdate = operation;
    void operation.then(
      () => {
        if (this._pendingThreadSettingsUpdate === operation) {
          this._pendingThreadSettingsUpdate = null;
        }
      },
      () => {
        if (this._pendingThreadSettingsUpdate === operation) {
          this._pendingThreadSettingsUpdate = null;
        }
      },
    );
    return operation;
  }

  private async probeNextTurnPermissionUpdates(): Promise<void> {
    if (!this._threadId) return;
    try {
      // An empty partial update is a no-op. It verifies support on this exact
      // app-server process without changing any effective thread setting.
      await this.request("thread/settings/update", {
        threadId: this._threadId,
      });
      this._threadSettingsUpdateMethodSupport = "supported";
      this._supportsNextTurnPermissionUpdates = true;
    } catch (err) {
      this._threadSettingsUpdateMethodSupport =
        isUnsupportedThreadSettingsMethod(err) ? "unsupported" : "unknown";
      this._supportsNextTurnPermissionUpdates = false;
      console.log(
        `[codex-process] next-turn permission updates unavailable: ${err instanceof Error ? err.message : String(err)}`,
      );
    }
    if (!this.stopped) {
      this.emitMessage({
        type: "system",
        subtype: "runtime_capabilities",
        provider: "codex",
      });
    }
  }

  /**
   * Probe the experimental Plan preset on this exact app-server process.
   *
   * A successful RPC is not enough: the response must advertise a concrete
   * `plan` mode. Until that happens, turn/start stays on the stable schema and
   * omits collaborationMode entirely.
   */
  probeNativePlanModeSupport(
    requestTimeoutMs = NATIVE_PLAN_MODE_PROBE_TIMEOUT_MS,
  ): Promise<boolean> {
    if (this._nativePlanModeSupport !== "unknown") {
      return Promise.resolve(this.supportsNativePlanMode);
    }
    if (this._nativePlanModeProbe) return this._nativePlanModeProbe;

    const generation = this._runtimeGeneration;
    let probe!: Promise<boolean>;
    probe = this.request(
      "collaborationMode/list",
      {},
      { timeoutMs: requestTimeoutMs },
    )
      .then((response) => classifyNativePlanModeResponse(response))
      .catch((error) => {
        const result = isNativePlanModeMethodUnsupported(error)
          ? "unsupported"
          : "unknown";
        console.log(
          `[codex-process] native Plan mode probe ${result}: ${error instanceof Error ? error.message : String(error)}`,
        );
        return result;
      })
      .then((support) => {
        if (this.stopped || generation !== this._runtimeGeneration) {
          return false;
        }
        if (support === "unknown") {
          console.warn(
            "[codex-process] native Plan mode probe was inconclusive; keeping capability unknown for retry",
          );
          return false;
        }
        this._nativePlanModeSupport = support;
        const supported = support === "supported";
        this.emitMessage({
          type: "system",
          subtype: "runtime_capabilities",
          provider: "codex",
          ...(this._threadId ? { sessionId: this._threadId } : {}),
          codexNativePlanModeSupported: supported,
        });
        return supported;
      })
      .finally(() => {
        if (this._nativePlanModeProbe === probe) {
          this._nativePlanModeProbe = null;
        }
      });

    this._nativePlanModeProbe = probe;
    return probe;
  }

  async confirmNativePlanModeSupportForUserAction(): Promise<boolean> {
    const inheritedProbe = this._nativePlanModeProbe;
    const supported = await this.probeNativePlanModeSupport(
      NATIVE_PLAN_MODE_EXPLICIT_PROBE_TIMEOUT_MS,
    );
    if (supported || this.nativePlanModeCapabilityKnown || !inheritedProbe) {
      return supported;
    }
    return this.probeNativePlanModeSupport(
      NATIVE_PLAN_MODE_EXPLICIT_PROBE_TIMEOUT_MS,
    );
  }

  private async waitForPendingThreadSettingsUpdate(): Promise<void> {
    while (true) {
      const pending = this._pendingThreadSettingsUpdate;
      if (!pending) return;
      await pending;
      // An update can be appended while the previous operation is awaited.
      if (this._pendingThreadSettingsUpdate === pending) {
        this._pendingThreadSettingsUpdate = null;
        return;
      }
    }
  }

  private persistRuntimeThreadSettings(
    settings: Record<string, unknown>,
  ): Promise<boolean> {
    if (
      !this._threadId ||
      this._threadSettingsUpdateMethodSupport === "unsupported"
    ) {
      return Promise.resolve(false);
    }

    const threadId = this._threadId;
    const operation = this._threadSettingsUpdateTail.then(async () => {
      try {
        await this.request("thread/settings/update", {
          threadId,
          ...settings,
        });
        this._threadSettingsUpdateMethodSupport = "supported";
        return true;
      } catch (err) {
        if (isUnsupportedThreadSettingsMethod(err)) {
          this._threadSettingsUpdateMethodSupport = "unsupported";
          this._supportsNextTurnPermissionUpdates = false;
        }
        console.warn(
          `[codex-process] Runtime settings will fall back to turn/start: ${err instanceof Error ? err.message : String(err)}`,
        );
        return false;
      }
    });

    // Share ordering with permission updates, but keep this path best-effort:
    // an older app-server must still start the next ordinary turn using the
    // existing turn/start overrides.
    this._threadSettingsUpdateTail = operation.then(() => undefined);
    const pending = operation.then(() => undefined);
    this._pendingRuntimeThreadSettingsUpdate = pending;
    void pending.then(() => {
      if (this._pendingRuntimeThreadSettingsUpdate === pending) {
        this._pendingRuntimeThreadSettingsUpdate = null;
      }
    });
    return operation;
  }

  private runtimeModelSettingsParams(): Record<string, unknown> {
    const model = this.model;
    const effort = this._runtimeModelReasoningEffort;
    const modeSettings: Record<string, unknown> = { model };
    if (effort !== undefined) {
      modeSettings.reasoning_effort = effort;
    }
    return {
      model,
      ...(effort !== undefined ? { effort } : {}),
      ...(this.supportsNativePlanMode
        ? {
            collaborationMode: {
              mode: this._collaborationMode,
              settings: modeSettings,
            },
          }
        : {}),
    };
  }

  private async waitForPendingRuntimeThreadSettingsUpdate(): Promise<void> {
    while (true) {
      const pending = this._pendingRuntimeThreadSettingsUpdate;
      if (!pending) return;
      await pending;
      if (this._pendingRuntimeThreadSettingsUpdate === pending) {
        this._pendingRuntimeThreadSettingsUpdate = null;
        return;
      }
    }
  }

  /**
   * Wait until the shared settings queue is stable across both operation kinds.
   *
   * A permission update can be appended while a model/speed update is being
   * awaited (and vice versa). Rechecking both trackers after every await keeps
   * the following turn or Goal action behind the complete serialized tail.
   */
  private async waitForPendingThreadSettingsUpdates(): Promise<void> {
    while (true) {
      if (this._pendingThreadSettingsUpdate) {
        await this.waitForPendingThreadSettingsUpdate();
      }
      if (this._pendingRuntimeThreadSettingsUpdate) {
        await this.waitForPendingRuntimeThreadSettingsUpdate();
      }
      if (
        !this._pendingThreadSettingsUpdate &&
        !this._pendingRuntimeThreadSettingsUpdate
      ) {
        return;
      }
    }
  }

  private async buildSandboxPolicy(
    mode: NonNullable<CodexStartOptions["sandboxMode"]>,
  ): Promise<CodexSandboxPolicy> {
    if (mode === "danger-full-access") {
      return { type: "dangerFullAccess" };
    }
    if (mode === "read-only") {
      return {
        type: "readOnly",
        networkAccess: this._networkAccessEnabled,
      };
    }
    const cachedWorkspacePolicy =
      this._workspaceWriteSandboxPolicy?.type === "workspaceWrite"
        ? this._workspaceWriteSandboxPolicy
        : undefined;
    let configuredRoots: string[] = [];
    if (this._projectPath) {
      try {
        const response = await this.request("config/read", {
          includeLayers: false,
          cwd: this._projectPath,
        });
        configuredRoots = extractWritableRootsFromConfigRead(response);
      } catch (err) {
        console.warn(
          `[codex-process] Failed to read workspace roots for next-turn permissions: ${err instanceof Error ? err.message : String(err)}`,
        );
      }
    }
    const writableRoots = normalizeWritableRoots(
      [
        ...(this._projectPath ? [this._projectPath] : []),
        ...(cachedWorkspacePolicy?.writableRoots ?? []),
        ...configuredRoots,
        ...this._additionalWritableRoots,
      ],
      this.platform,
    );
    return {
      type: "workspaceWrite",
      writableRoots,
      networkAccess:
        cachedWorkspacePolicy?.networkAccess ?? this._networkAccessEnabled,
      excludeTmpdirEnvVar: cachedWorkspacePolicy?.excludeTmpdirEnvVar ?? false,
      excludeSlashTmp: cachedWorkspacePolicy?.excludeSlashTmp ?? false,
    };
  }

  /**
   * Set collaboration mode ("plan" or "default").
   * Takes effect on the next `turn/start` RPC call.
   */
  setCollaborationMode(mode: "plan" | "default"): void {
    if (mode === "plan") {
      if (!this.nativePlanModeCapabilityKnown) {
        throw new CodexNativePlanModeProbeRetryError();
      }
      if (!this.supportsNativePlanMode) {
        throw new CodexNativePlanModeUnsupportedError();
      }
    }
    this._collaborationMode = mode;
    console.log(`[codex-process] Collaboration mode changed to: ${mode}`);
  }

  get collaborationMode(): "plan" | "default" {
    return this._collaborationMode;
  }

  /**
   * Rename a thread via the app-server RPC.
   * Sends thread/name/set which persists to ~/.codex/session_index.jsonl.
   */
  async renameThread(name: string): Promise<void> {
    if (!this._threadId) {
      throw new Error("No thread ID available for rename");
    }
    await this.request("thread/name/set", {
      threadId: this._threadId,
      name,
    });
  }

  /** Read the persisted goal attached to this Codex thread. */
  async getGoal(): Promise<CodexGoal | null> {
    return (await this.getGoalSnapshot()).goal;
  }

  /** Read Goal state together with same-runtime notification ordering. */
  async getGoalSnapshot(): Promise<CodexGoalSnapshot> {
    if (!this._threadId) {
      throw new Error("No thread ID available for goal lookup");
    }
    this.beginGoalRpc();
    const orderingGeneration = this.goalOrderingGeneration;
    const response = (await this.request("thread/goal/get", {
      threadId: this._threadId,
    })) as Record<string, unknown>;
    return {
      goal: response.goal == null ? null : parseCodexGoal(response.goal),
      stable: this.goalOrderingGeneration === orderingGeneration,
    };
  }

  /** Create or update the persisted goal attached to this Codex thread. */
  async setGoal(
    update: {
      objective?: string;
      status?: CodexGoalWritableStatus;
      tokenBudget?: number | null;
    },
    options: CodexGoalMutationOptions = {},
  ): Promise<CodexGoal> {
    if (!this._threadId) {
      throw new Error("No thread ID available for goal update");
    }
    await this.waitForPendingThreadSettingsUpdates();
    if (options.validateCurrentGoal) {
      const snapshot = await this.getGoalSnapshot();
      if (!snapshot.stable) throw new CodexGoalSnapshotConflictError();
      // Intentionally synchronous: no notification can interleave between the
      // validated app-server snapshot and registering the mutation RPC.
      options.validateCurrentGoal(snapshot.goal);
    }
    this.beginGoalRpc();
    const response = (await this.request("thread/goal/set", {
      threadId: this._threadId,
      ...(update.objective !== undefined
        ? { objective: update.objective.trim() }
        : {}),
      ...(update.status !== undefined ? { status: update.status } : {}),
      ...(update.tokenBudget !== undefined
        ? { tokenBudget: update.tokenBudget }
        : {}),
    })) as Record<string, unknown>;
    return parseCodexGoal(response.goal);
  }

  /** Remove the persisted goal attached to this Codex thread. */
  async clearGoal(options: CodexGoalMutationOptions = {}): Promise<boolean> {
    if (!this._threadId) {
      throw new Error("No thread ID available for goal clear");
    }
    await this.waitForPendingThreadSettingsUpdates();
    if (options.validateCurrentGoal) {
      const snapshot = await this.getGoalSnapshot();
      if (!snapshot.stable) throw new CodexGoalSnapshotConflictError();
      options.validateCurrentGoal(snapshot.goal);
    }
    this.beginGoalRpc();
    const response = (await this.request("thread/goal/clear", {
      threadId: this._threadId,
    })) as Record<string, unknown>;
    if (typeof response.cleared !== "boolean") {
      throw new Error("thread/goal/clear returned an invalid response");
    }
    return response.cleared;
  }

  private nextGoalOperationSequence(): number {
    this.goalOperationSequence += 1;
    return this.goalOperationSequence;
  }

  private consumeExpectedGoalNotification(
    kind: "updated" | "cleared",
    goal?: CodexGoal,
  ):
    | {
        sequence: number;
        interveningGoalEvent: boolean;
      }
    | undefined {
    this.removeExpiredGoalNotifications();
    const index = this.expectedGoalNotifications.findIndex(
      (expected) =>
        expected.kind === kind &&
        (kind === "cleared" ||
          (expected.goal !== undefined &&
            goal !== undefined &&
            sameCodexGoal(expected.goal, goal))),
    );
    const matched =
      index >= 0 ? this.expectedGoalNotifications[index] : undefined;
    this.expectedGoalNotifications = this.expectedGoalNotifications
      .filter((_, expectedIndex) => expectedIndex !== index)
      .map((expected) =>
        expected.kind === "cleared"
          ? { ...expected, interveningGoalEvent: true }
          : expected,
      );
    return matched
      ? {
          sequence: matched.sequence,
          interveningGoalEvent: matched.interveningGoalEvent === true,
        }
      : undefined;
  }

  private markExpectedClearNotificationsIntervened(): void {
    this.removeExpiredGoalNotifications();
    this.expectedGoalNotifications = this.expectedGoalNotifications.map(
      (expected) =>
        expected.kind === "cleared"
          ? { ...expected, interveningGoalEvent: true }
          : expected,
    );
  }

  private beginGoalRpc(): void {
    this.goalOrderingGeneration += 1;
    this.markExpectedClearNotificationsIntervened();
  }

  private async verifyAmbiguousClearNotification(): Promise<void> {
    const generationBeforeRead = this.goalOrderingGeneration;
    try {
      const snapshot = await this.getGoalSnapshot();
      if (
        !snapshot.stable ||
        this.goalOrderingGeneration !== generationBeforeRead + 1
      ) {
        return;
      }
      this.emitMessage({
        type: "goal_state",
        goal: snapshot.goal,
        goalOperationSequence: this.recordAuthoritativeGoalStateChange(),
      });
    } catch (error) {
      console.warn(
        `[codex-process] Failed to verify an ambiguous Goal clear notification: ${error instanceof Error ? error.message : String(error)}`,
      );
    }
  }

  private removeExpiredGoalNotifications(now = Date.now()): void {
    this.expectedGoalNotifications = this.expectedGoalNotifications.filter(
      (expected) => expected.expiresAt > now,
    );
  }

  /**
   * Archive a Codex thread via the app-server `thread/archive` RPC.
   * Accepts an explicit threadId so that historical (non-active) sessions
   * can be archived without requiring a running process.
   */
  async archiveThread(threadId: string): Promise<void> {
    await this.request("thread/archive", { threadId });
  }

  /** Restore a historical Codex thread via the stable app-server RPC. */
  async unarchiveThread(threadId: string): Promise<void> {
    await this.request("thread/unarchive", { threadId });
  }

  /** Permanently delete a historical Codex thread and its spawned descendants. */
  async deleteThread(threadId: string): Promise<void> {
    await this.request("thread/delete", { threadId });
  }

  /** Start a stable app-server compaction for the active, idle thread. */
  async compactThread(options: CodexRpcRequestOptions = {}): Promise<void> {
    const operation = this.beginCoreAction("thread/compact/start");
    try {
      await this.request(
        "thread/compact/start",
        { threadId: operation.threadId },
        options,
      );
      this.markCoreActionAccepted(operation.action, null);
    } catch (error) {
      this.failCoreAction(operation.action);
      throw error;
    }
  }

  /** Start an inline stable app-server review for the active, idle thread. */
  async startInlineReview(
    target: CodexReviewTarget,
    options: CodexRpcRequestOptions = {},
  ): Promise<CodexInlineReviewStartResult> {
    const operation = this.beginCoreAction("review/start");
    try {
      const response = (await this.request(
        "review/start",
        {
          threadId: operation.threadId,
          target,
          delivery: "inline",
        },
        options,
      )) as Record<string, unknown>;
      const turn = asRecord(response?.turn);
      const turnId = stringValue(turn?.id);
      const reviewThreadId = stringValue(response?.reviewThreadId);
      if (!turnId || !reviewThreadId) {
        throw new CodexRpcError(
          "review/start",
          "review/start returned an invalid response",
        );
      }
      this.markCoreActionAccepted(operation.action, turnId);
      return { turnId, reviewThreadId };
    } catch (error) {
      this.failCoreAction(operation.action);
      throw error;
    }
  }

  /** Read one bounded, low-detail page of MCP server inventory/status. */
  async listMcpServerStatus(
    options: CodexRpcRequestOptions = {},
  ): Promise<CodexMcpServerStatusPage> {
    if (!this._threadId) {
      throw new CodexCoreActionPreconditionError(
        "thread_unavailable",
        "No Codex thread is available",
      );
    }
    const response = (await this.requestReadOnlyRpc(
      "mcpServerStatus/list",
      {
        cursor: null,
        limit: CODEX_MCP_STATUS_PAGE_SIZE,
        detail: "toolsAndAuthOnly",
        threadId: this._threadId,
      },
      options,
    )) as Record<string, unknown>;
    if (!Array.isArray(response?.data)) {
      throw new CodexRpcError(
        "mcpServerStatus/list",
        "mcpServerStatus/list returned an invalid response",
      );
    }
    return {
      data: response.data,
      nextCursor:
        typeof response.nextCursor === "string" &&
        response.nextCursor.length > 0
          ? response.nextCursor
          : null,
    };
  }

  private beginCoreAction(method: CodexCoreActionMethod): {
    threadId: string;
    action: PendingCoreAction;
  } {
    const threadId = this.requireIdleCoreAction(method);
    const action: PendingCoreAction = {
      method,
      phase: "requesting",
      expectedTurnId: null,
      observedTurnId: null,
      observedTurnCompleted: false,
    };
    this.pendingCoreAction = action;
    this.setStatus("running");
    return { threadId, action };
  }

  private requireIdleCoreAction(method: CodexCoreActionMethod): string {
    if (!this._threadId) {
      throw new CodexCoreActionPreconditionError(
        "thread_unavailable",
        `No Codex thread is available for ${method}`,
      );
    }
    if (
      this._status !== "idle" ||
      this.pendingTurnId !== null ||
      this.pendingCoreAction !== null ||
      this.activeCoreActionTurnId !== null
    ) {
      throw new CodexCoreActionPreconditionError(
        "session_busy",
        `Cannot call ${method} while Codex is ${this._status}`,
      );
    }
    return this._threadId;
  }

  private markCoreActionAccepted(
    action: PendingCoreAction,
    expectedTurnId: string | null,
  ): void {
    if (this.pendingCoreAction !== action) return;
    action.phase = "awaiting_start";
    action.expectedTurnId = expectedTurnId;
    if (
      action.observedTurnId &&
      (!expectedTurnId || action.observedTurnId === expectedTurnId)
    ) {
      if (action.observedTurnCompleted) {
        this.releaseCoreAction(action);
      } else {
        this.transferCoreActionToStartedTurn(action, action.observedTurnId);
      }
      return;
    }

    action.startTimeout = setTimeout(() => {
      if (this.pendingCoreAction !== action) return;
      console.warn(
        `[codex-process] ${action.method} was accepted but no matching turn/started arrived within ${CODEX_CORE_ACTION_START_TIMEOUT_MS}ms`,
      );
      this.releaseCoreAction(action);
      if (
        this._status === "running" &&
        !this.pendingTurnId &&
        !this.activeCoreActionTurnId
      ) {
        this.setStatus("idle");
      }
    }, CODEX_CORE_ACTION_START_TIMEOUT_MS);
  }

  private observeCoreActionTurnStarted(turnId: string): void {
    const action = this.pendingCoreAction;
    if (!action) return;
    if (action.phase === "requesting") {
      action.observedTurnId = turnId;
      action.observedTurnCompleted = false;
      return;
    }
    if (!action.expectedTurnId || action.expectedTurnId === turnId) {
      this.transferCoreActionToStartedTurn(action, turnId);
    }
  }

  private observeCoreActionTurnCompleted(turnId: string | null): void {
    if (
      this.activeCoreActionTurnId &&
      (!turnId || this.activeCoreActionTurnId === turnId)
    ) {
      this.activeCoreActionTurnId = null;
    }

    const action = this.pendingCoreAction;
    if (!action) return;
    const matchesObserved =
      action.observedTurnId !== null &&
      (!turnId || action.observedTurnId === turnId);
    const matchesExpected =
      action.expectedTurnId !== null &&
      (!turnId || action.expectedTurnId === turnId);
    const matchesCompactWithoutStart =
      action.method === "thread/compact/start" &&
      action.phase === "awaiting_start" &&
      action.observedTurnId === null;

    if (matchesObserved) {
      action.observedTurnCompleted = true;
    }
    if (
      action.phase === "awaiting_start" &&
      (matchesObserved || matchesExpected || matchesCompactWithoutStart)
    ) {
      this.releaseCoreAction(action);
    }
  }

  private transferCoreActionToStartedTurn(
    action: PendingCoreAction,
    turnId: string,
  ): void {
    if (this.pendingCoreAction !== action) return;
    this.activeCoreActionTurnId = turnId;
    this.releaseCoreAction(action);
  }

  private failCoreAction(action: PendingCoreAction): void {
    if (this.pendingCoreAction !== action) return;
    if (action.observedTurnId && !action.observedTurnCompleted) {
      this.activeCoreActionTurnId = action.observedTurnId;
    }
    this.releaseCoreAction(action);
    if (
      this._status === "running" &&
      !this.pendingTurnId &&
      !this.activeCoreActionTurnId
    ) {
      this.setStatus("idle");
    }
  }

  private releaseCoreAction(expected?: PendingCoreAction): void {
    const action = this.pendingCoreAction;
    if (!action || (expected && action !== expected)) return;
    if (action.startTimeout) clearTimeout(action.startTimeout);
    this.pendingCoreAction = null;
  }

  /**
   * Narrow extension seam for optional local read-only modules. Method names
   * must follow the app-server `.../read` or `.../list` convention so feature
   * code cannot accidentally route a mutating RPC through this API.
   */
  requestReadOnlyRpc<T = unknown>(
    method: string,
    params: Record<string, unknown>,
    options: CodexRpcRequestOptions = {},
  ): Promise<T> {
    if (!method.endsWith("/read") && !method.endsWith("/list")) {
      return Promise.reject(
        new CodexRpcError(
          method,
          `Refusing non-read-only RPC method: ${method}`,
        ),
      );
    }
    return this.request(method, params, options) as Promise<T>;
  }

  async readThread(
    threadId: string,
    includeTurns = true,
  ): Promise<Record<string, unknown>> {
    const response = (await this.request("thread/read", {
      threadId,
      includeTurns,
    })) as Record<string, unknown>;
    const thread = response.thread as Record<string, unknown> | undefined;
    if (!thread) {
      throw new Error("thread/read returned no thread");
    }
    return thread;
  }

  async rollbackThread(numTurns: number): Promise<Record<string, unknown>> {
    if (!this._threadId) {
      throw new Error("No thread ID available for rollback");
    }
    return this.rollbackThreadById(this._threadId, numTurns);
  }

  async rollbackThreadById(
    threadId: string,
    numTurns: number,
  ): Promise<Record<string, unknown>> {
    const response = (await this.request("thread/rollback", {
      threadId,
      numTurns,
    })) as Record<string, unknown>;
    const thread = response.thread as Record<string, unknown> | undefined;
    if (!thread) {
      throw new Error("thread/rollback returned no thread");
    }
    return thread;
  }

  async forkThread(): Promise<{
    threadId: string;
    thread: Record<string, unknown>;
  }> {
    if (!this._threadId) {
      throw new Error("No thread ID available for fork");
    }
    const response = (await this.request("thread/fork", {
      threadId: this._threadId,
      persistExtendedHistory: true,
    })) as Record<string, unknown>;
    const thread = response.thread as Record<string, unknown> | undefined;
    const threadId = typeof thread?.id === "string" ? thread.id : undefined;
    if (!thread || !threadId) {
      throw new Error("thread/fork returned no thread id");
    }
    return { threadId, thread };
  }

  async listThreads(
    params: {
      limit?: number;
      cursor?: string | null;
      cwd?: string;
      searchTerm?: string;
      modelProviders?: string[];
      sourceKinds?: CodexThreadSourceKind[];
    } = {},
  ): Promise<{ data: CodexThreadSummary[]; nextCursor: string | null }> {
    const result = (await this.request("thread/list", {
      sortKey: "updated_at",
      archived: false,
      ...(params.limit != null ? { limit: params.limit } : {}),
      ...(params.cursor !== undefined ? { cursor: params.cursor } : {}),
      ...(params.modelProviders !== undefined
        ? { modelProviders: params.modelProviders }
        : {}),
      ...(params.sourceKinds !== undefined
        ? { sourceKinds: params.sourceKinds }
        : {}),
      ...(params.cwd ? { cwd: params.cwd } : {}),
      ...(params.searchTerm ? { searchTerm: params.searchTerm } : {}),
    })) as { data?: unknown[]; nextCursor?: unknown };

    const data = Array.isArray(result.data)
      ? result.data.map((entry) => toCodexThreadSummary(entry))
      : [];
    return {
      data,
      nextCursor:
        typeof result.nextCursor === "string" ? result.nextCursor : null,
    };
  }

  async listAvailableModels(): Promise<string[]> {
    const models = await this.listAvailableModelMetadata();
    return models.map((model) => model.model);
  }

  async listAvailableModelMetadata(): Promise<CodexModelMetadata[]> {
    const models: CodexModelMetadata[] = [];
    const seenModels = new Set<string>();
    const seenCursors = new Set<string>();
    let cursor: string | null = null;

    do {
      const result = (await this.request("model/list", {
        limit: 100,
        cursor,
        includeHidden: false,
      })) as CodexModelListResponse;

      if (Array.isArray(result.data)) {
        for (const entry of result.data) {
          if (!entry || typeof entry !== "object") continue;
          const raw = entry as Record<string, unknown>;
          if (raw.hidden === true) continue;
          const model =
            typeof raw.model === "string" && raw.model.trim().length > 0
              ? raw.model.trim()
              : typeof raw.id === "string" && raw.id.trim().length > 0
                ? raw.id.trim()
                : undefined;
          if (!model || seenModels.has(model)) continue;
          seenModels.add(model);
          models.push({
            model,
            supportedReasoningEfforts: extractReasoningEfforts(raw),
            defaultReasoningEffort:
              typeof raw.defaultReasoningEffort === "string"
                ? raw.defaultReasoningEffort
                : typeof raw.default_reasoning_effort === "string"
                  ? raw.default_reasoning_effort
                  : undefined,
            supportedServiceTiers: extractServiceTiers(raw),
            defaultServiceTier:
              typeof raw.defaultServiceTier === "string"
                ? raw.defaultServiceTier
                : typeof raw.default_service_tier === "string"
                  ? raw.default_service_tier
                  : undefined,
          });
        }
      }

      const nextCursor =
        typeof result.nextCursor === "string" && result.nextCursor.length > 0
          ? result.nextCursor
          : null;
      if (nextCursor && seenCursors.has(nextCursor)) {
        break;
      }
      if (nextCursor) {
        seenCursors.add(nextCursor);
      }
      cursor = nextCursor;
    } while (cursor);

    return models;
  }

  start(projectPath: string, options?: CodexStartOptions): void {
    if (this.transport) {
      this.stop();
    }

    this.prepareLaunch(projectPath, options);
    this.launchAppServer(projectPath, options);

    void this.bootstrap(projectPath, options);
  }

  async initializeOnly(
    projectPath: string,
    requestTimeoutMs?: number,
  ): Promise<void> {
    if (this.transport) {
      this.stop();
    }
    this.prepareLaunch(projectPath);
    this.launchAppServer(projectPath);
    try {
      await this.initializeRpcConnection(requestTimeoutMs);
      this.setStatus("idle");
    } catch (error) {
      this.stop();
      throw error;
    }
  }

  stop(): void {
    this.stopped = true;

    if (this.inputResolve) {
      this.inputResolve({ text: "" });
      this.inputResolve = null;
    }

    this.pendingApprovals.clear();
    this.pendingUserInputs.clear();
    this.clearPendingGuardianReviewWarnings();
    this.cleanupSteerTempPaths();
    this.rejectAllPending(new Error("stopped"));

    if (this.transport) {
      this.transport.stop();
      this.transport = null;
    }

    this.setStatus("idle");
    console.log("[codex-process] Stopped");
  }

  private prepareLaunch(
    projectPath: string,
    options?: CodexStartOptions,
  ): void {
    this.releaseCoreAction();
    this.activeCoreActionTurnId = null;
    this.stopped = false;
    this._runtimeGeneration += 1;
    this._threadId = null;
    this._agentNickname = null;
    this._agentRole = null;
    this.pendingTurnId = null;
    this.pendingTurnCompletion = null;
    this.pendingApprovals.clear();
    this.pendingUserInputs.clear();
    this.clearPendingGuardianReviewWarnings();
    this.emittedGuardianReviewIds.clear();
    this.emittedGuardianReviewIdOrder = [];
    this.cleanupSteerTempPaths();
    this.lastTokenUsage = null;
    this.startModel = sanitizeCodexModel(options?.model);
    this._runtimeModel = undefined;
    this._runtimeModelReasoningEffort = options?.modelReasoningEffort;
    this._runtimeServiceTier =
      options?.serviceTier === undefined
        ? undefined
        : normalizeServiceTier(options.serviceTier);
    this._approvalPolicy = options?.approvalPolicy;
    this._approvalsReviewer =
      options?.approvalsReviewer === undefined
        ? undefined
        : normalizeApprovalsReviewerForAppServer(options.approvalsReviewer);
    this._codexPermissionsMode = options?.codexPermissionsMode;
    this._runtimeSandboxMode = options?.sandboxMode;
    this._runtimeSandboxPolicy = undefined;
    this._workspaceWriteSandboxPolicy = undefined;
    this._networkAccessEnabled = options?.networkAccessEnabled ?? false;
    this._additionalWritableRoots = normalizeWritableRoots(
      options?.additionalWritableRoots ?? [],
      this.platform,
    );
    this._pendingThreadSettingsUpdate = null;
    this._pendingRuntimeThreadSettingsUpdate = null;
    this._threadSettingsUpdateTail = Promise.resolve();
    this._supportsNextTurnPermissionUpdates = false;
    this._threadSettingsUpdateMethodSupport = "unknown";
    this._autoReviewDisabledByPolicy =
      options?.autoReviewDisabledByPolicy === true;
    this._collaborationMode = options?.collaborationMode ?? "default";
    this._nativePlanModeSupport = "unknown";
    this._nativePlanModeProbe = null;
    this.lastPlanItemText = null;
    this.lastResultText = null;
    this.agentTurnTracker.reset();
    this.startedToolItems.clear();
    this._skills = [];
    this._apps = [];
    this._plugins = [];
    this._lastCompletionEntitiesSignature = null;
    this._launchStartedAt = Date.now();
    this.pendingPlanCompletion = null;
    this._pendingPlanInput = null;
    this._idleWhenInteractionsClear = false;
    this._projectPath = projectPath;
  }

  private launchAppServer(
    projectPath: string,
    options?: CodexStartOptions,
  ): void {
    const sandboxLog = options?.sandboxMode ?? "config";
    const approvalLog = options?.approvalPolicy ?? "config";
    const reviewerLog = options?.approvalsReviewer ?? "config";
    console.log(
      `[codex-process] Starting app-server (cwd: ${projectPath}, sandbox: ${sandboxLog}, approval: ${approvalLog}, reviewer: ${reviewerLog}, model: ${options?.model ?? "default"}, collaboration: ${this._collaborationMode})`,
    );

    const transport = createCodexTransport(projectPath, this.platform);
    this.transport = transport;

    transport.on("data", (chunk: string) => {
      this.handleStdoutChunk(chunk);
    });

    transport.on("log", (chunk: string) => {
      const line = chunk.trim();
      if (line) {
        console.log(`[codex-process] stderr: ${line}`);
      }
    });

    transport.on("error", (err) => {
      if (this.stopped) return;
      // Spawn-level failures (ENOENT) never emit "exit", so this is the only
      // chance to settle in-flight RPCs — otherwise bootstrap awaits
      // initialize forever and the session hangs instead of surfacing the
      // error. rejectAllPending also releases the core-action lock.
      this.rejectAllPending(
        err instanceof Error ? err : new Error(String(err)),
      );
      console.error("[codex-process] app-server process error:", err);
      this.emitMessage(codexAppServerStartError(err));
      this.setStatus("idle");
      this.emit("exit", 1);
    });

    transport.on("exit", (code) => {
      const exitCode = code ?? 0;
      this.transport = null;
      this.rejectAllPending(new Error("codex app-server exited"));
      if (!this.stopped && exitCode !== 0) {
        this.emitMessage({
          type: "error",
          message: `codex app-server exited with code ${exitCode}`,
        });
      }
      this.setStatus("idle");
      this.emit("exit", code);
    });

    transport.start(projectPath);
  }

  interrupt(): void {
    void this.interruptCurrentTurn().catch((err) => {
      if (!this.stopped) {
        console.warn(
          `[codex-process] turn/interrupt failed: ${err instanceof Error ? err.message : String(err)}`,
        );
      }
    });
  }

  /** Interrupt the active turn and wait until app-server accepts the request. */
  async interruptCurrentTurn(): Promise<void> {
    if (!this._threadId || !this.pendingTurnId) return;
    await this.request("turn/interrupt", {
      threadId: this._threadId,
      turnId: this.pendingTurnId,
    });
  }

  /** Interrupt the active turn and wait for its terminal notification. */
  async interruptCurrentTurnAndWait(timeoutMs = 5000): Promise<boolean> {
    const threadId = this._threadId;
    if (!threadId) return false;
    const deadline = Date.now() + timeoutMs;
    while (!this.stopped && !this.pendingTurnId && this._status === "running") {
      if (Date.now() >= deadline) {
        throw new Error("Timed out waiting for the active turn id");
      }
      await new Promise<void>((resolve) => setTimeout(resolve, 20));
    }
    const turnId = this.pendingTurnId;
    if (!turnId) return false;
    try {
      await this.request("turn/interrupt", { threadId, turnId });
    } catch (err) {
      // Completion can win the race with the interrupt response.
      if (this.pendingTurnId !== turnId) return false;
      throw err;
    }

    while (!this.stopped && this.pendingTurnId === turnId) {
      if (Date.now() >= deadline) {
        throw new Error(`Timed out waiting for turn ${turnId} to stop`);
      }
      await new Promise<void>((resolve) => setTimeout(resolve, 20));
    }
    return (
      this.lastCompletedTurn?.turnId === turnId &&
      this.lastCompletedTurn.status === "interrupted"
    );
  }

  sendInput(text: string, clientMessageId?: string): void {
    const resolve = this.inputResolve;
    if (!resolve || !this.isWaitingForInput) {
      console.error("[codex-process] No pending input resolver for sendInput");
      return;
    }
    this.inputResolve = null;
    resolve({ text, clientMessageId });
  }

  sendInputWithImages(
    text: string,
    images: Array<{ base64: string; mimeType: string }>,
    clientMessageId?: string,
  ): void {
    const resolve = this.inputResolve;
    if (!resolve || !this.isWaitingForInput) {
      console.error(
        "[codex-process] No pending input resolver for sendInputWithImages",
      );
      return;
    }
    this.inputResolve = null;
    resolve({ text, images, clientMessageId });
  }

  sendInputWithSkill(
    text: string,
    skill: { name: string; path: string },
  ): void {
    this.sendInputStructured(text, { skills: [skill] });
  }

  sendInputStructured(
    text: string,
    options?: {
      images?: Array<{ base64: string; mimeType: string }>;
      skills?: Array<{ name: string; path: string }>;
      mentions?: Array<{ name: string; path: string }>;
      clientMessageId?: string;
    },
  ): void {
    const resolve = this.inputResolve;
    if (!resolve || !this.isWaitingForInput) {
      console.error(
        "[codex-process] No pending input resolver for sendInputStructured",
      );
      return;
    }
    this.inputResolve = null;
    resolve({
      text,
      images: options?.images,
      skills: options?.skills,
      mentions: options?.mentions,
      clientMessageId: options?.clientMessageId,
    });
  }

  async steerInputStructured(
    text: string,
    options?: {
      images?: Array<{ base64: string; mimeType: string }>;
      skills?: Array<{ name: string; path: string }>;
      mentions?: Array<{ name: string; path: string }>;
      clientMessageId?: string;
    },
  ): Promise<void> {
    if (!this._threadId || !this.pendingTurnId) {
      throw new Error("No active Codex turn to steer");
    }

    await this.steerTurnStructured(this.pendingTurnId, text, options);
  }

  /**
   * Low-level app-server primitive used by optional continuity transports that
   * already have an authoritative expectedTurnId. The app-server still
   * validates ownership and rejects stale/non-steerable turns.
   */
  async steerTurnStructured(
    expectedTurnId: string,
    text: string,
    options?: {
      images?: Array<{ base64: string; mimeType: string }>;
      skills?: Array<{ name: string; path: string }>;
      mentions?: Array<{ name: string; path: string }>;
      clientMessageId?: string;
    },
  ): Promise<void> {
    if (!this._threadId || !expectedTurnId) {
      throw new Error("No Codex thread or expected turn to steer");
    }

    const { input, tempPaths } = await this.toRpcInput({
      text,
      images: options?.images,
      skills: options?.skills,
      mentions: options?.mentions,
      clientMessageId: options?.clientMessageId,
    });
    this.steerTempPaths.push(...tempPaths);
    try {
      if (!input) {
        throw new Error("No Codex input to steer");
      }
      await this.requestWithClientUserMessageIdFallback(
        "turn/steer",
        {
          threadId: this._threadId,
          input,
          expectedTurnId,
        },
        options?.clientMessageId,
      );
    } catch (err) {
      this.steerTempPaths = this.steerTempPaths.filter(
        (path) => !tempPaths.includes(path),
      );
      await Promise.all(
        tempPaths.map((path) => rm(path, { force: true }).catch(() => {})),
      );
      throw err;
    }
  }

  approve(toolUseId?: string): void {
    // Check if this is a plan completion approval
    if (
      this.pendingPlanCompletion &&
      toolUseId === this.pendingPlanCompletion.toolUseId
    ) {
      this.handlePlanApproved();
      return;
    }

    const pending = this.resolvePendingApproval(toolUseId);
    if (!pending) {
      // Fallback: McpElicitation lives in pendingUserInputs
      if (this.approveUserInput(toolUseId, "Accept")) return;
      console.log(
        "[codex-process] approve() called but no pending permission requests",
      );
      return;
    }

    this.pendingApprovals.delete(pending.toolUseId);
    this.respondToServerRequest(
      pending.requestId,
      buildApprovalResponse(pending, "accept"),
    );
    this.emitToolResult(pending.toolUseId, "Approved");

    this.resumeRunningIfNoPendingInteractiveRequest();
  }

  approveAlways(toolUseId?: string): void {
    const pending = this.resolvePendingApproval(toolUseId);
    if (!pending) {
      // Fallback: McpElicitation lives in pendingUserInputs
      if (this.approveUserInput(toolUseId, "Allow for this session")) return;
      console.log(
        "[codex-process] approveAlways() called but no pending permission requests",
      );
      return;
    }

    this.pendingApprovals.delete(pending.toolUseId);
    this.respondToServerRequest(
      pending.requestId,
      buildApprovalResponse(pending, "acceptForSession"),
    );
    this.emitToolResult(pending.toolUseId, "Approved (always)");

    this.resumeRunningIfNoPendingInteractiveRequest();
  }

  reject(toolUseId?: string, _message?: string): void {
    // Check if this is a plan completion rejection
    if (
      this.pendingPlanCompletion &&
      toolUseId === this.pendingPlanCompletion.toolUseId
    ) {
      this.handlePlanRejected(_message);
      return;
    }

    const pending = this.resolvePendingApproval(toolUseId);
    if (!pending) {
      // Fallback: McpElicitation lives in pendingUserInputs
      if (this.rejectUserInput(toolUseId, "Decline")) return;
      console.log(
        "[codex-process] reject() called but no pending permission requests",
      );
      return;
    }

    this.pendingApprovals.delete(pending.toolUseId);
    this.respondToServerRequest(
      pending.requestId,
      buildApprovalResponse(pending, resolveApprovalRejectDecision(pending)),
    );
    this.emitToolResult(pending.toolUseId, "Rejected");

    this.resumeRunningIfNoPendingInteractiveRequest();
  }

  answer(toolUseId: string, result: string): void {
    const pending = this.resolvePendingUserInput(toolUseId);
    if (!pending) {
      console.log(
        "[codex-process] answer() called but no pending AskUserQuestion",
      );
      return;
    }

    this.pendingUserInputs.delete(pending.toolUseId);
    this.respondToServerRequest(
      pending.requestId,
      buildUserInputResponse(pending, result),
    );

    this.emitToolResult(pending.toolUseId, "Answered");

    this.resumeRunningIfNoPendingInteractiveRequest();
  }

  /**
   * Install a plugin or begin connector authentication proposed by Codex.
   * The elicitation remains pending while external app authentication is
   * required, and is accepted only after installation is complete.
   */
  async installToolSuggestion(toolUseId: string): Promise<void> {
    const pending = this.resolvePendingUserInput(toolUseId);
    if (!pending || pending.kind !== "tool_suggestion") {
      throw new Error("No pending tool suggestion found");
    }

    const currentState = pending.input.installState;
    if (currentState === "installing") return;
    if (currentState === "needs_auth") return;

    const meta = asRecord(pending.input._meta) ?? {};
    const toolType = stringValue(meta.tool_type) ?? "";
    const suggestType = stringValue(meta.suggest_type) ?? "";
    if (suggestType !== "install") {
      this.updateToolSuggestion(pending, {
        installState: "failed",
        installError: `Unsupported suggestion action: ${suggestType || "unknown"}`,
      });
      return;
    }

    if (toolType === "connector") {
      const installUrl = stringValue(meta.install_url);
      if (!installUrl) {
        this.updateToolSuggestion(pending, {
          installState: "failed",
          installError: "This connector did not provide an installation URL.",
        });
        return;
      }
      this.updateToolSuggestion(pending, { installState: "needs_auth" });
      return;
    }

    if (toolType !== "plugin") {
      this.updateToolSuggestion(pending, {
        installState: "failed",
        installError: `Unsupported tool type: ${toolType || "unknown"}`,
      });
      return;
    }

    const toolId = stringValue(meta.tool_id) ?? "";
    const remotePluginId = stringValue(meta.remote_plugin_id);
    const separator = toolId.lastIndexOf("@");
    const fallbackPluginName =
      separator > 0 ? toolId.slice(0, separator) : toolId;
    const remoteMarketplaceName =
      separator > 0 ? toolId.slice(separator + 1) : "openai-curated-remote";
    const pluginName = remotePluginId ?? fallbackPluginName;
    if (!pluginName) {
      this.updateToolSuggestion(pending, {
        installState: "failed",
        installError: "This plugin did not provide an installation identifier.",
      });
      return;
    }

    this.updateToolSuggestion(pending, {
      installState: "installing",
      installError: null,
    });

    try {
      const result = (await this.request("plugin/install", {
        remoteMarketplaceName,
        pluginName,
      })) as Record<string, unknown>;

      // The user may reject the suggestion while installation is in flight.
      if (this.pendingUserInputs.get(toolUseId) !== pending) return;

      const appsNeedingAuth = normalizeToolSuggestionApps(
        result.appsNeedingAuth,
      );
      if (appsNeedingAuth.length > 0) {
        this.updateToolSuggestion(pending, {
          installState: "needs_auth",
          appsNeedingAuth,
        });
        return;
      }

      this.resolveToolSuggestion(pending, "Installed");
    } catch (err) {
      if (this.pendingUserInputs.get(toolUseId) !== pending) return;
      this.updateToolSuggestion(pending, {
        installState: "failed",
        installError: err instanceof Error ? err.message : String(err),
      });
    }
  }

  getPendingPermission(
    toolUseId?: string,
  ):
    | { toolUseId: string; toolName: string; input: Record<string, unknown> }
    | undefined {
    // Check plan completion first
    if (this.pendingPlanCompletion) {
      if (!toolUseId || toolUseId === this.pendingPlanCompletion.toolUseId) {
        return {
          toolUseId: this.pendingPlanCompletion.toolUseId,
          toolName: "ExitPlanMode",
          input: { plan: this.pendingPlanCompletion.planText },
        };
      }
    }

    const pending = this.resolvePendingApproval(toolUseId);
    if (pending) {
      return {
        toolUseId: pending.toolUseId,
        toolName: pending.toolName,
        input: { ...pending.input },
      };
    }

    const pendingAsk = this.resolvePendingUserInput(toolUseId);
    if (!pendingAsk) return undefined;
    return {
      toolUseId: pendingAsk.toolUseId,
      toolName: pendingAsk.toolName,
      input: { ...pendingAsk.input },
    };
  }

  /** Emit a synthetic tool_result so history replay can match it to a permission_request. */
  private emitToolResult(toolUseId: string, content: string): void {
    this.emitMessage({
      type: "tool_result",
      toolUseId,
      content,
    });
  }

  private resolvePendingApproval(
    toolUseId?: string,
  ): PendingApproval | undefined {
    if (toolUseId) return this.pendingApprovals.get(toolUseId);
    const first = this.pendingApprovals.values().next();
    return first.done ? undefined : first.value;
  }

  private resolvePendingUserInput(
    toolUseId?: string,
  ): PendingUserInputRequest | undefined {
    if (toolUseId) return this.pendingUserInputs.get(toolUseId);
    const first = this.pendingUserInputs.values().next();
    return first.done ? undefined : first.value;
  }

  private hasPendingInteractiveRequest(): boolean {
    return (
      this.pendingPlanCompletion !== null ||
      this.pendingApprovals.size > 0 ||
      this.pendingUserInputs.size > 0
    );
  }

  private resumeRunningIfNoPendingInteractiveRequest(): void {
    if (this.hasPendingInteractiveRequest()) return;
    if (this._pendingPlanInput) {
      const text = this._pendingPlanInput;
      this._pendingPlanInput = null;
      if (this.inputResolve) {
        const resolve = this.inputResolve;
        this.inputResolve = null;
        resolve({ text });
      } else {
        this._pendingPlanInput = text;
      }
      return;
    }
    if (this._idleWhenInteractionsClear) {
      this._idleWhenInteractionsClear = false;
      this.setStatus("idle");
    } else {
      // turn/completed may have settled the turn while this interaction was
      // still on screen; "running" with no turn in flight would leave the
      // session permanently unable to accept input.
      this.setStatus(this.pendingTurnId ? "running" : "idle");
    }
  }

  /**
   * Approve a pending user-input request (McpElicitation fallback).
   * Called when approve()/approveAlways() cannot find a pendingApproval —
   * McpElicitation lives in pendingUserInputs but the app routes it through
   * the permission (approve/reject) path.
   */
  private approveUserInput(
    toolUseId: string | undefined,
    result: string,
  ): boolean {
    const pending = this.resolvePendingUserInput(toolUseId);
    if (!pending) return false;

    if (pending.kind === "tool_suggestion") {
      if (pending.input.installState === "needs_auth") {
        this.resolveToolSuggestion(pending, "Installed");
      } else {
        void this.installToolSuggestion(pending.toolUseId);
      }
      return true;
    }

    this.pendingUserInputs.delete(pending.toolUseId);
    this.respondToServerRequest(
      pending.requestId,
      buildUserInputResponse(pending, result),
    );
    this.emitToolResult(pending.toolUseId, "Approved");

    this.resumeRunningIfNoPendingInteractiveRequest();
    return true;
  }

  private updateToolSuggestion(
    pending: PendingUserInputRequest,
    changes: Record<string, unknown>,
  ): void {
    pending.input = { ...pending.input, ...changes };
    this.emitMessage({
      type: "permission_request",
      toolUseId: pending.toolUseId,
      toolName: "ToolSuggestion",
      input: { ...pending.input },
    });
  }

  private resolveToolSuggestion(
    pending: PendingUserInputRequest,
    toolResult: string,
  ): void {
    this.pendingUserInputs.delete(pending.toolUseId);
    this.respondToServerRequest(pending.requestId, {
      action: "accept",
      content: null,
      _meta: null,
    });
    this.emitMessage({
      type: "permission_resolved",
      toolUseId: pending.toolUseId,
    });
    this.emitToolResult(pending.toolUseId, toolResult);
    this.resumeRunningIfNoPendingInteractiveRequest();
  }

  /**
   * Reject a pending user-input request (McpElicitation fallback).
   */
  private rejectUserInput(
    toolUseId: string | undefined,
    result: string,
  ): boolean {
    const pending = this.resolvePendingUserInput(toolUseId);
    if (!pending) return false;

    this.pendingUserInputs.delete(pending.toolUseId);
    this.respondToServerRequest(
      pending.requestId,
      buildUserInputResponse(
        pending,
        resolveUserInputRejectResult(pending, result),
      ),
    );
    this.emitToolResult(pending.toolUseId, "Rejected");

    this.resumeRunningIfNoPendingInteractiveRequest();
    return true;
  }

  // ---------------------------------------------------------------------------
  // Plan completion handlers (native collaboration_mode)
  // ---------------------------------------------------------------------------

  /**
   * Plan approved → switch to Default mode and auto-start execution.
   */
  private handlePlanApproved(): void {
    const planText = this.pendingPlanCompletion?.planText ?? "";
    const resolvedToolUseId = this.pendingPlanCompletion?.toolUseId;
    this.pendingPlanCompletion = null;
    this._collaborationMode = "default";
    console.log("[codex-process] Plan approved, switching to Default mode");

    // Emit synthetic tool_result so history replay knows this approval is resolved
    if (resolvedToolUseId) {
      this.emitToolResult(resolvedToolUseId, "Plan approved");
    }

    this._pendingPlanInput = `Execute the following plan:\n\n${planText}`;
    this.resumeRunningIfNoPendingInteractiveRequest();
  }

  /**
   * Plan rejected → stay in Plan mode and re-plan with feedback.
   */
  private handlePlanRejected(feedback?: string): void {
    const resolvedToolUseId = this.pendingPlanCompletion?.toolUseId;
    this.pendingPlanCompletion = null;
    console.log("[codex-process] Plan rejected, continuing in Plan mode");
    // Stay in Plan mode

    // Emit synthetic tool_result so history replay knows this approval is resolved
    if (resolvedToolUseId) {
      this.emitToolResult(resolvedToolUseId, "Plan rejected");
    }

    if (feedback) {
      this._pendingPlanInput = feedback;
      this.resumeRunningIfNoPendingInteractiveRequest();
    } else if (this.hasPendingInteractiveRequest()) {
      this._idleWhenInteractionsClear = true;
      this.setStatus("waiting_approval");
    } else {
      this.setStatus("idle");
    }
  }

  private async bootstrap(
    projectPath: string,
    options?: CodexStartOptions,
  ): Promise<void> {
    try {
      await this.initializeRpcConnection();

      const autoReviewDisabled =
        options?.autoReviewDisabledByPolicy === null
          ? (await this.readConfigRequirements()).autoReviewDisabled
          : options?.autoReviewDisabledByPolicy === true;
      this._autoReviewDisabledByPolicy = autoReviewDisabled;
      const effectiveApprovalsReviewer = autoReviewDisabled
        ? "user"
        : options?.approvalsReviewer;
      const effectiveCodexPermissionsMode =
        autoReviewDisabled && options?.codexPermissionsMode === "autoReview"
          ? "default"
          : options?.codexPermissionsMode;
      if (autoReviewDisabled) {
        console.warn(
          "[codex-process] Auto-review disabled by managed Browser Use policy",
        );
      }
      this._approvalsReviewer =
        effectiveApprovalsReviewer === undefined
          ? undefined
          : normalizeApprovalsReviewerForAppServer(effectiveApprovalsReviewer);
      this._codexPermissionsMode = effectiveCodexPermissionsMode;

      // A requested Plan session must never silently run as an ordinary turn.
      // Block only that path on the experimental capability probe; default
      // sessions continue immediately and probe in the background below.
      if (
        this._collaborationMode === "plan" &&
        !(await this.probeNativePlanModeSupport(
          NATIVE_PLAN_MODE_EXPLICIT_PROBE_TIMEOUT_MS,
        ))
      ) {
        this._collaborationMode = "default";
        throw this.nativePlanModeCapabilityKnown
          ? new CodexNativePlanModeUnsupportedError()
          : new CodexNativePlanModeProbeRetryError();
      }

      const requestedApprovalPolicy = options?.approvalPolicy
        ? normalizeApprovalPolicy(options.approvalPolicy)
        : undefined;
      const requestedApprovalsReviewer =
        effectiveApprovalsReviewer === undefined
          ? undefined
          : normalizeApprovalsReviewerForAppServer(effectiveApprovalsReviewer);
      const requestedClientApprovalsReviewer =
        normalizeApprovalsReviewerForClient(effectiveApprovalsReviewer);
      const requestedSandboxMode = options?.sandboxMode
        ? normalizeSandboxMode(options.sandboxMode)
        : undefined;

      const threadParams: Record<string, unknown> = {
        cwd: projectPath,
        experimentalRawEvents: false,
        persistExtendedHistory: true,
      };
      if (requestedApprovalPolicy) {
        threadParams.approvalPolicy = requestedApprovalPolicy;
      }
      if (requestedApprovalsReviewer) {
        threadParams.approvalsReviewer = requestedApprovalsReviewer;
      }
      if (requestedSandboxMode) {
        threadParams.sandbox = requestedSandboxMode;
      }
      const threadConfig: Record<string, unknown> = {};
      const requestedModel = sanitizeCodexModel(options?.model);
      const requestedReasoningEffort = options?.modelReasoningEffort
        ? normalizeReasoningEffort(options.modelReasoningEffort)
        : undefined;
      if (requestedModel) threadParams.model = requestedModel;
      if (options?.serviceTier !== undefined) {
        threadParams.serviceTier = normalizeServiceTier(options.serviceTier);
      }
      if (requestedReasoningEffort) {
        // app-server applies reasoning effort on thread start via config overrides,
        // not the top-level thread/start payload.
        threadConfig.model_reasoning_effort = requestedReasoningEffort;
      }
      if (options?.networkAccessEnabled !== undefined) {
        threadParams.sandboxPolicy = {
          type: normalizeSandboxMode(options?.sandboxMode ?? "workspace-write"),
          networkAccess: options.networkAccessEnabled,
        };
      }
      if (options?.webSearchMode) {
        threadParams.webSearchMode = options.webSearchMode;
      }

      const threadBindings = [
        options?.threadId,
        options?.forkFromThreadId,
        options?.ephemeralForkFromThreadId,
      ].filter((value) => value !== undefined);
      if (threadBindings.length > 1) {
        throw new Error(
          "Codex start must choose exactly one resume or fork binding",
        );
      }
      const forkFromThreadId =
        options?.forkFromThreadId ?? options?.ephemeralForkFromThreadId;
      const method = forkFromThreadId
        ? "thread/fork"
        : options?.threadId
          ? "thread/resume"
          : "thread/start";
      if (forkFromThreadId) {
        threadParams.threadId = forkFromThreadId;
        threadParams.ephemeral = options?.ephemeralForkFromThreadId != null;
      } else if (options?.threadId) {
        threadParams.threadId = options.threadId;
      } else {
        threadParams.experimentalRawEvents = false;
      }
      if (options?.excludeTurnsOnOpen) threadParams.excludeTurns = true;
      if (options?.threadSource && method !== "thread/resume") {
        threadParams.threadSource = options.threadSource;
      }
      threadParams.persistExtendedHistory = true;
      if (options?.profile) {
        threadConfig.profile = options.profile;
      }
      const writableRoots = await this.resolveWritableRootsConfig(
        projectPath,
        options?.additionalWritableRoots,
      );
      if (writableRoots) {
        threadConfig.sandbox_workspace_write = {
          writable_roots: writableRoots,
        };
      }
      if (Object.keys(threadConfig).length > 0) {
        threadParams.config = {
          ...(threadParams.config as Record<string, unknown> | undefined),
          ...threadConfig,
        };
      }

      const response = (await this.request(method, threadParams)) as Record<
        string,
        unknown
      >;
      const thread = response.thread as Record<string, unknown> | undefined;
      const threadId =
        typeof thread?.id === "string" ? thread.id : options?.threadId;
      if (!threadId) {
        throw new Error(`${method} returned no thread id`);
      }
      if (
        options?.ephemeralForkFromThreadId &&
        (threadId === options.ephemeralForkFromThreadId ||
          thread?.ephemeral !== true ||
          thread.path !== null)
      ) {
        // The returned id is untrusted once the response violates the
        // ephemeral contract. Never run an irreversible thread/delete against
        // it: an incompatible server could have echoed any existing thread.
        console.warn(
          `[codex-process] Rejected incompatible ephemeral fork ${threadId}; automatic cleanup skipped for safety`,
        );
        throw new Error(
          "thread/fork did not return an in-memory ephemeral thread; " +
            "automatic cleanup skipped for safety",
        );
      }
      if (
        options?.forkFromThreadId &&
        (threadId === options.forkFromThreadId || thread?.ephemeral === true)
      ) {
        throw new Error(
          "thread/fork did not return a distinct persisted thread",
        );
      }

      // Capture the resolved model name from thread response
      if (typeof thread?.model === "string" && thread.model) {
        this.startModel = thread.model;
      }
      const resolvedSettings =
        extractResolvedSettingsFromThreadResponse(response);
      const resolvedSandboxPolicy = normalizeSandboxPolicyFromRpc(
        response.sandbox,
      );
      const resolvedApprovalsReviewer = autoReviewDisabled
        ? "user"
        : resolvedSettings.approvalsReviewer;
      if (resolvedSettings.model) {
        this.startModel = resolvedSettings.model;
      }
      if (resolvedSettings.approvalPolicy) {
        this._approvalPolicy = resolvedSettings.approvalPolicy;
      }
      if (resolvedApprovalsReviewer) {
        this._approvalsReviewer = normalizeApprovalsReviewerForAppServer(
          resolvedApprovalsReviewer as CodexStartOptions["approvalsReviewer"],
        );
      }
      if (resolvedSettings.sandboxMode) {
        this._runtimeSandboxMode =
          resolvedSettings.sandboxMode as CodexStartOptions["sandboxMode"];
      }
      if (resolvedSandboxPolicy) {
        this._runtimeSandboxPolicy = resolvedSandboxPolicy;
        if (resolvedSandboxPolicy.type === "workspaceWrite") {
          this._workspaceWriteSandboxPolicy = resolvedSandboxPolicy;
        }
      }
      if (resolvedSettings.networkAccessEnabled !== undefined) {
        this._networkAccessEnabled = resolvedSettings.networkAccessEnabled;
      }
      if (resolvedSettings.modelReasoningEffort !== undefined) {
        this._runtimeModelReasoningEffort = normalizeReasoningEffort(
          resolvedSettings.modelReasoningEffort,
        );
      }
      if (resolvedSettings.serviceTier !== undefined) {
        this._runtimeServiceTier = normalizeServiceTier(
          resolvedSettings.serviceTier,
        );
      }

      this._threadId = threadId;
      this._agentNickname = stringOrNull(thread?.agentNickname);
      this._agentRole = stringOrNull(thread?.agentRole);
      const cliJoin = codexCliJoinTarget(threadId);
      this.emitMessage({
        type: "system",
        subtype: "init",
        sessionId: threadId,
        provider: "codex",
        ...(this.nativePlanModeCapabilityKnown
          ? { codexNativePlanModeSupported: this.supportsNativePlanMode }
          : {}),
        ...(sanitizeCodexModel(this.startModel)
          ? { model: sanitizeCodexModel(this.startModel) }
          : {}),
        ...((resolvedSettings.approvalPolicy ?? options?.approvalPolicy)
          ? {
              approvalPolicy:
                resolvedSettings.approvalPolicy ?? requestedApprovalPolicy,
            }
          : {}),
        ...((resolvedApprovalsReviewer ?? effectiveApprovalsReviewer)
          ? {
              approvalsReviewer: resolvedApprovalsReviewer
                ? normalizeApprovalsReviewerForClient(
                    resolvedApprovalsReviewer as CodexStartOptions["approvalsReviewer"],
                  )
                : requestedClientApprovalsReviewer,
            }
          : {}),
        ...((resolvedSettings.sandboxMode ?? options?.sandboxMode)
          ? {
              sandboxMode: resolvedSettings.sandboxMode ?? requestedSandboxMode,
            }
          : {}),
        ...(effectiveCodexPermissionsMode
          ? { codexPermissionsMode: effectiveCodexPermissionsMode }
          : {}),
        ...(resolvedSettings.modelReasoningEffort
          ? { modelReasoningEffort: resolvedSettings.modelReasoningEffort }
          : requestedReasoningEffort
            ? { modelReasoningEffort: requestedReasoningEffort }
            : {}),
        serviceTier: normalizeServiceTierForClient(
          resolvedSettings.serviceTier ?? options?.serviceTier,
        ),
        ...(resolvedSettings.networkAccessEnabled !== undefined
          ? { networkAccessEnabled: resolvedSettings.networkAccessEnabled }
          : {}),
        ...(resolvedSettings.webSearchMode
          ? { webSearchMode: resolvedSettings.webSearchMode }
          : {}),
        ...(options?.additionalWritableRoots?.length
          ? { additionalWritableRoots: options.additionalWritableRoots }
          : {}),
        ...(cliJoin ? { codexCliJoin: cliJoin } : {}),
      });
      this.setStatus("idle");

      await this.resumeGoalAfterBootstrap(options);
      if (
        options?.continueInterruptedTurnAfterStart &&
        !options.resumeGoalAfterStart
      ) {
        await this.continueInterruptedTurnAfterBootstrap(options);
      }

      // Fetch completion entities in background (non-blocking).
      this._projectPath = projectPath;
      setTimeout(() => {
        if (!this.stopped) {
          void this.probeNativePlanModeSupport();
          void this.probeNextTurnPermissionUpdates();
          void this.fetchCompletionEntities(projectPath);
        }
      }, 25);

      await this.runInputLoop(options);
    } catch (err) {
      if (!this.stopped) {
        const message = codexErrorMessage(err);
        console.error("[codex-process] bootstrap error:", err);
        const nativePlanModeError =
          err instanceof CodexNativePlanModeUnsupportedError ||
          err instanceof CodexNativePlanModeProbeRetryError;
        this.emitMessage({
          type: "error",
          message: nativePlanModeError ? message : `Codex error: ${message}`,
          ...(err instanceof CodexNativePlanModeUnsupportedError
            ? { errorCode: "codex_native_plan_mode_unsupported" }
            : err instanceof CodexNativePlanModeProbeRetryError
              ? { errorCode: "codex_native_plan_mode_probe_retry" }
              : {}),
        });
        this.emitMessage({
          type: "result",
          subtype: "error",
          error: message,
          sessionId: this._threadId ?? undefined,
        });
      }
      this.setStatus("idle");
      this.emit("exit", 1);
    }
  }

  private async resumeGoalAfterBootstrap(
    options?: CodexStartOptions,
  ): Promise<void> {
    if (!options?.resumeGoalAfterStart) return;

    // Keep the pre-lease option compatible for internal/older callers.
    if (!options.resumeGoalLease) {
      await this.setGoal({ status: "active" });
      return;
    }

    try {
      await this.setGoal(
        { status: "active" },
        {
          validateCurrentGoal: (currentGoal) => {
            if (
              !matchesCodexGoalResumeLease(
                currentGoal,
                options.resumeGoalLease!,
              )
            ) {
              throw new CodexGoalResumeLeaseMismatchError(currentGoal);
            }
          },
        },
      );
    } catch (error) {
      if (error instanceof CodexGoalResumeLeaseMismatchError) {
        console.warn(
          "[codex-process] Skipping Goal resume because the paused Goal was replaced or changed during restart",
        );
        this.emitMessage({
          type: "goal_state",
          goal: error.goal,
          ...(this._lastGoalRpcSequence !== undefined
            ? { goalOperationSequence: this._lastGoalRpcSequence }
            : {}),
        });
        return;
      }
      console.warn(
        `[codex-process] Skipping Goal resume because the restart lease could not be verified: ${error instanceof Error ? error.message : String(error)}`,
      );
      return;
    }
  }

  private async continueInterruptedTurnAfterBootstrap(
    options: CodexStartOptions,
  ): Promise<void> {
    try {
      // Current app-server schemas allow an empty input list. This resumes the
      // interrupted model-visible thread without fabricating a user message.
      await this.runBootstrapContinuation([]);
      return;
    } catch (error) {
      console.warn(
        `[codex-process] Empty restart continuation was rejected; falling back to text: ${error instanceof Error ? error.message : String(error)}`,
      );
    }

    const fallback = options.continuationFallbackText?.trim() || "继续";
    try {
      await this.runBootstrapContinuation([{ type: "text", text: fallback }]);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      console.warn(`[codex-process] Restart continuation failed: ${message}`);
      this.emitMessage({
        type: "error",
        errorCode: "permission_restart_continuation_failed",
        message:
          "Permissions were restarted, but automatic continuation failed. " +
          `Send ${fallback} to resume: ${message}`,
      });
      this.setStatus("idle");
    }
  }

  private async runBootstrapContinuation(
    input: Array<Record<string, unknown>>,
  ): Promise<void> {
    if (!this._threadId) {
      throw new Error("No thread ID available for restart continuation");
    }
    await this.waitForPendingThreadSettingsUpdates();
    this.lastTokenUsage = null;
    this.setStatus("running");

    await new Promise<void>((resolve, reject) => {
      this.pendingTurnCompletion = { resolve, reject };
      void this.request("turn/start", {
        threadId: this._threadId,
        input,
      })
        .then((result) => {
          const turn = (result as Record<string, unknown>).turn as
            Record<string, unknown> | undefined;
          // app-server may emit turn/completed before replying to turn/start.
          // Never resurrect a turn that the notification path already settled.
          if (this.pendingTurnCompletion && typeof turn?.id === "string") {
            this.pendingTurnId = turn.id;
          }
        })
        .catch((error) => {
          this.pendingTurnCompletion = null;
          this.pendingTurnId = null;
          this.setStatus("idle");
          reject(error instanceof Error ? error : new Error(String(error)));
        });
    });
  }

  private async resolveWritableRootsConfig(
    projectPath: string,
    additionalWritableRoots?: string[],
  ): Promise<string[] | undefined> {
    const normalizedAdditional = normalizeWritableRoots(
      additionalWritableRoots ?? [],
      this.platform,
    );
    if (normalizedAdditional.length === 0) return undefined;

    const response = (await this.request("config/read", {
      includeLayers: false,
      cwd: projectPath,
    })) as unknown;
    const configuredRoots = extractWritableRootsFromConfigRead(response);
    return normalizeWritableRoots(
      [...configuredRoots, ...normalizedAdditional],
      this.platform,
    );
  }

  private async initializeRpcConnection(
    requestTimeoutMs?: number,
  ): Promise<void> {
    const params = {
      clientInfo: {
        name: "ccpocket_bridge",
        version: "1.0.0",
        title: "ccpocket bridge",
      },
      capabilities: {
        experimentalApi: true,
      },
    };
    if (requestTimeoutMs === undefined) {
      await this.request("initialize", params);
    } else {
      await this.request("initialize", params, {
        timeoutMs: requestTimeoutMs,
      });
    }
    this.notify("initialized", {});
  }

  async readProfileConfig(cwd?: string): Promise<CodexProfileConfig> {
    const response = (await this.request("config/read", {
      includeLayers: false,
      ...(cwd ? { cwd } : {}),
    })) as {
      config?: {
        profile?: unknown;
        profiles?: Record<string, unknown>;
      };
    };
    const config = response.config;
    const profiles = config?.profiles;
    return {
      profiles: profiles ? Object.keys(profiles).sort() : [],
      defaultProfile:
        typeof config?.profile === "string" && config.profile.trim().length > 0
          ? config.profile.trim()
          : undefined,
    };
  }

  async readConfigRequirements(): Promise<CodexConfigRequirements> {
    try {
      const response = (await this.request(
        "configRequirements/read",
      )) as Record<string, unknown>;
      const requirements = asRecord(response.requirements);
      const browserUse = asRecord(
        requirements?.browserUse ?? requirements?.browser_use,
      );
      return {
        autoReviewDisabled:
          (browserUse?.disableAutoReview ?? browserUse?.disable_auto_review) ===
          true,
      };
    } catch (err) {
      if (err instanceof CodexRpcError && err.code === -32601) {
        return { autoReviewDisabled: false };
      }
      throw err;
    }
  }

  private async fetchCompletionEntities(projectPath: string): Promise<void> {
    if (this._completionFetchInFlight) {
      return this._completionFetchInFlight;
    }
    this._completionFetchInFlight =
      this._fetchCompletionEntitiesInternal(projectPath);
    try {
      await this._completionFetchInFlight;
    } finally {
      this._completionFetchInFlight = null;
      // Notifications emitted while fetching are usually echoes of our own
      // skills/list or app/list RPCs. Replaying them here can re-arm a tight
      // app/list -> app/list/updated feedback loop.
      this._completionFetchCooldownUntil =
        Date.now() + COMPLETION_FETCH_COOLDOWN_MS;
    }
  }

  private scheduleCompletionFetchFromNotification(): void {
    if (!this._projectPath || this.stopped) return;
    if (Date.now() < this._completionFetchCooldownUntil) return;
    void this.fetchCompletionEntities(this._projectPath);
  }

  private async _fetchCompletionEntitiesInternal(
    projectPath: string,
  ): Promise<void> {
    const TIMEOUT_MS = 10_000;
    try {
      interface SkillRaw {
        name: string;
        path: string;
        description: string;
        shortDescription?: string | null;
        enabled: boolean;
        scope: string;
        interface?: {
          displayName?: string | null;
          shortDescription?: string | null;
          defaultPrompt?: string | null;
          brandColor?: string | null;
        } | null;
      }
      interface AppRaw {
        id: string;
        name: string;
        description: string;
        installUrl?: string | null;
        isAccessible?: boolean | null;
        isEnabled?: boolean | null;
      }
      interface PluginRaw {
        id: string;
        name: string;
        installed: boolean;
        enabled: boolean;
        interface?: {
          displayName?: unknown;
          shortDescription?: unknown;
          longDescription?: unknown;
          defaultPrompt?: unknown;
          brandColor?: unknown;
          composerIcon?: unknown;
          composerIconUrl?: unknown;
        } | null;
      }
      interface PluginMarketplaceRaw {
        name: string;
        path?: string | null;
        plugins: PluginRaw[];
      }
      const requestOrNull = <T>(
        method: string,
        params: Record<string, unknown>,
      ): Promise<T | null> =>
        Promise.race([
          this.request(method, params).catch((err) => {
            console.log(
              `[codex-process] ${method} failed (non-fatal): ${err instanceof Error ? err.message : String(err)}`,
            );
            return null;
          }),
          new Promise<null>((resolve) =>
            setTimeout(() => resolve(null), TIMEOUT_MS),
          ),
        ]) as Promise<T | null>;
      const optionalString = (value: unknown): string | undefined =>
        typeof value === "string" ? value : undefined;
      const optionalFirstString = (value: unknown): string | undefined => {
        if (typeof value === "string") return value;
        if (!Array.isArray(value)) return undefined;
        return value.find(
          (entry): entry is string => typeof entry === "string",
        );
      };

      const skillsRequest = requestOrNull<{
        data?: Array<{ cwd: string; skills: SkillRaw[] }>;
      }>("skills/list", { cwds: [projectPath] });
      const appsRequest = requestOrNull<{ data?: AppRaw[] }>("app/list", {
        cursor: null,
        limit: 100,
        threadId: this._threadId ?? undefined,
        forceRefetch: false,
      });
      const pluginsRequest = requestOrNull<{
        marketplaces?: PluginMarketplaceRaw[];
      }>("plugin/list", { cwds: [projectPath] });
      let skillsReady = false;

      await Promise.all([
        skillsRequest.then((skillsResult) => {
          if (this.stopped || skillsResult === null) return;
          const skillMetadata: CodexSkillMetadata[] = [];
          for (const entry of skillsResult.data ?? []) {
            for (const skill of entry.skills) {
              if (!skill.enabled) continue;
              skillMetadata.push({
                name: skill.name,
                path: skill.path,
                description: skill.description,
                shortDescription:
                  skill.shortDescription ??
                  skill.interface?.shortDescription ??
                  undefined,
                enabled: skill.enabled,
                scope: skill.scope,
                displayName: skill.interface?.displayName ?? undefined,
                defaultPrompt: skill.interface?.defaultPrompt ?? undefined,
                brandColor: skill.interface?.brandColor ?? undefined,
              });
            }
          }
          this._skills = skillMetadata;
          skillsReady = true;
          const elapsedMs =
            this._launchStartedAt > 0
              ? Date.now() - this._launchStartedAt
              : undefined;
          console.log(
            `[codex-process] completion skills ready: ${skillMetadata.length} skills${elapsedMs === undefined ? "" : ` (${elapsedMs}ms since start)`}`,
          );
          this.emitCompletionEntitiesSnapshot("skills");
        }),
        appsRequest.then((appsResult) => {
          if (this.stopped || appsResult === null) return;
          this._apps = (appsResult.data ?? [])
            .filter(
              (app) => (app.isAccessible ?? true) && (app.isEnabled ?? true),
            )
            .map((app) => ({
              id: app.id,
              name: app.name,
              description: app.description,
              installUrl: app.installUrl ?? undefined,
              isAccessible: app.isAccessible ?? true,
              isEnabled: app.isEnabled ?? true,
            }));
          if (skillsReady) this.emitCompletionEntitiesSnapshot("apps");
        }),
        pluginsRequest.then((pluginsResult) => {
          if (this.stopped || pluginsResult === null) return;
          const pluginMetadata: CodexPluginMetadata[] = [];
          for (const marketplace of pluginsResult.marketplaces ?? []) {
            for (const plugin of marketplace.plugins ?? []) {
              if (!plugin.installed || !plugin.enabled) continue;
              pluginMetadata.push({
                id: plugin.id,
                name: plugin.name,
                path: `plugin://${plugin.id}`,
                marketplaceName: marketplace.name,
                marketplacePath: marketplace.path ?? undefined,
                installed: plugin.installed,
                enabled: plugin.enabled,
                displayName: optionalString(plugin.interface?.displayName),
                shortDescription: optionalString(
                  plugin.interface?.shortDescription,
                ),
                longDescription: optionalString(
                  plugin.interface?.longDescription,
                ),
                defaultPrompt: optionalFirstString(
                  plugin.interface?.defaultPrompt,
                ),
                brandColor: optionalString(plugin.interface?.brandColor),
                composerIcon: optionalString(plugin.interface?.composerIcon),
                composerIconUrl: optionalString(
                  plugin.interface?.composerIconUrl,
                ),
              });
            }
          }
          this._plugins = pluginMetadata;
          if (skillsReady) this.emitCompletionEntitiesSnapshot("plugins");
        }),
      ]);
    } catch (err) {
      console.log(
        `[codex-process] completion entity fetch failed (non-fatal): ${err instanceof Error ? err.message : String(err)}`,
      );
    }
  }

  private emitCompletionEntitiesSnapshot(
    source: "skills" | "apps" | "plugins",
  ): void {
    if (this.stopped) return;
    const skills = this._skills.map((skill) => skill.name);
    const apps = this._apps.map((app) => app.id);
    const plugins = this._plugins.map((plugin) => plugin.name);
    const signature = JSON.stringify({
      skills,
      skillMetadata: this._skills,
      apps,
      appMetadata: this._apps,
      plugins,
      pluginMetadata: this._plugins,
    });
    if (signature === this._lastCompletionEntitiesSignature) return;
    this._lastCompletionEntitiesSignature = signature;
    console.log(
      `[codex-process] completion entities updated (${source}): ${skills.length} skills, ${apps.length} apps, ${plugins.length} plugins`,
    );
    this.emitMessage({
      type: "system",
      subtype: "supported_commands",
      skills,
      skillMetadata: this._skills,
      apps,
      appMetadata: this._apps,
      plugins,
      pluginMetadata: this._plugins,
    });
  }

  private async runInputLoop(options?: CodexStartOptions): Promise<void> {
    while (!this.stopped) {
      const pendingInput = await new Promise<PendingInput>((resolve) => {
        this.inputResolve = resolve;
        // If plan approval arrived before inputResolve was ready, drain it now.
        if (this._pendingPlanInput && !this.hasPendingInteractiveRequest()) {
          const text = this._pendingPlanInput;
          this._pendingPlanInput = null;
          this.inputResolve = null;
          resolve({ text });
          return;
        }
        this.emit("input_ready");
      });
      if (this.stopped || !pendingInput.text) break;
      if (!this._threadId) {
        this.emitMessage({
          type: "error",
          message: "Codex thread is not initialized",
        });
        continue;
      }

      const { input, tempPaths } = await this.toRpcInput(pendingInput);
      if (!input) {
        continue;
      }

      // Settings and the following input can arrive on adjacent WebSocket
      // frames. Do not let the new turn overtake the persisted update.
      try {
        await this.waitForPendingThreadSettingsUpdates();
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        this.emitMessage({
          type: "error",
          errorCode: "set_permission_mode_rejected",
          message:
            "The queued permission update failed, so this input was not started: " +
            message,
        });
        this.emitMessage({
          type: "result",
          subtype: "error",
          error: message,
          sessionId: this._threadId,
        });
        await Promise.all(
          tempPaths.map((path) => rm(path, { force: true }).catch(() => {})),
        );
        this.setStatus("idle");
        continue;
      }

      this.setStatus("running");
      this.lastTokenUsage = null;

      const completion = await new Promise<void>((resolve, reject) => {
        this.pendingTurnCompletion = { resolve, reject };

        const params: Record<string, unknown> = {
          threadId: this._threadId,
          input,
        };
        if (this._approvalPolicy !== undefined) {
          params.approvalPolicy =
            this._approvalPolicy === null
              ? null
              : normalizeApprovalPolicy(
                  this._approvalPolicy as CodexStartOptions["approvalPolicy"],
                );
        }
        if (this._approvalsReviewer !== undefined) {
          params.approvalsReviewer =
            this._approvalsReviewer === null
              ? null
              : normalizeApprovalsReviewerForAppServer(
                  this
                    ._approvalsReviewer as CodexStartOptions["approvalsReviewer"],
                );
        }
        if (this._runtimeSandboxPolicy !== undefined) {
          params.sandboxPolicy = this._runtimeSandboxPolicy;
        }
        const requestedModel =
          sanitizeCodexModel(this._runtimeModel) ??
          sanitizeCodexModel(options?.model);
        const requestedReasoningEffort =
          this._runtimeModelReasoningEffort ??
          (options?.modelReasoningEffort
            ? normalizeReasoningEffort(options.modelReasoningEffort)
            : undefined);
        if (requestedModel) params.model = requestedModel;
        if (requestedReasoningEffort) {
          params.effort = requestedReasoningEffort;
        }
        if (this._runtimeServiceTier !== undefined) {
          params.serviceTier = this._runtimeServiceTier;
        }

        // collaborationMode is experimental. Send it only after this exact
        // app-server process advertises a native Plan preset; stable/older
        // servers receive the ordinary stable turn/start shape.
        if (this.supportsNativePlanMode) {
          const modeSettings: Record<string, unknown> = {
            model:
              requestedModel ||
              sanitizeCodexModel(this.startModel) ||
              DEFAULT_CODEX_MODEL,
          };
          if (requestedReasoningEffort) {
            modeSettings.reasoning_effort = requestedReasoningEffort;
          }
          params.collaborationMode = {
            mode: this._collaborationMode,
            settings: modeSettings,
          };
        }

        console.log(
          `[codex-process] turn/start: approval=${params.approvalPolicy}, sandbox=${this._runtimeSandboxMode ?? "config"}, collaboration=${this.supportsNativePlanMode ? this._collaborationMode : "omitted"}`,
        );
        void this.requestWithClientUserMessageIdFallback(
          "turn/start",
          params,
          pendingInput.clientMessageId,
        )
          .then((result) => {
            const turn = (result as Record<string, unknown>).turn as
              Record<string, unknown> | undefined;
            if (typeof turn?.id === "string") {
              this.pendingTurnId = turn.id;
            }
          })
          .catch((err) => {
            this.pendingTurnCompletion = null;
            reject(err instanceof Error ? err : new Error(String(err)));
          });
      }).catch((err) => {
        if (!this.stopped) {
          const message = err instanceof Error ? err.message : String(err);
          this.emitMessage({ type: "error", message });
          this.emitMessage({
            type: "result",
            subtype: "error",
            error: message,
            sessionId: this._threadId ?? undefined,
          });
          this.setStatus("idle");
        }
      });

      await Promise.all(
        tempPaths.map((path) => rm(path, { force: true }).catch(() => {})),
      );
      void completion;
    }
  }

  private handleStdoutChunk(chunk: string): void {
    this.stdoutBuffer += chunk;
    while (true) {
      const newlineIndex = this.stdoutBuffer.indexOf("\n");
      if (newlineIndex < 0) break;
      const line = this.stdoutBuffer.slice(0, newlineIndex).trim();
      this.stdoutBuffer = this.stdoutBuffer.slice(newlineIndex + 1);
      if (!line) continue;

      try {
        const envelope = JSON.parse(line) as JsonRpcEnvelope;
        this.handleRpcEnvelope(envelope);
      } catch (err) {
        console.warn(
          `[codex-process] failed to parse app-server JSON line: ${line.slice(0, 200)}`,
        );
        if (!this.stopped) {
          this.emitMessage({
            type: "error",
            message: `Failed to parse codex app-server output: ${err instanceof Error ? err.message : String(err)}`,
          });
        }
      }
    }
  }

  private handleRpcEnvelope(envelope: JsonRpcEnvelope): void {
    if (
      envelope.id != null &&
      envelope.method &&
      envelope.result === undefined &&
      envelope.error === undefined
    ) {
      this.handleServerRequest(
        envelope.id,
        envelope.method,
        envelope.params ?? {},
      );
      return;
    }

    if (
      envelope.id != null &&
      (envelope.result !== undefined || envelope.error)
    ) {
      this.handleRpcResponse(envelope as RpcSuccess | RpcError);
      return;
    }

    if (envelope.method) {
      this.handleNotification(envelope.method, envelope.params ?? {});
    }
  }

  private handleRpcResponse(envelope: RpcSuccess | RpcError): void {
    if (typeof envelope.id !== "number") {
      return;
    }
    const pending = this.pendingRpc.get(envelope.id);
    if (!pending) return;
    this.pendingRpc.delete(envelope.id);
    this.clearPendingRpcLifecycle(pending);

    if ("error" in envelope && envelope.error) {
      const message =
        envelope.error.message ?? `RPC error ${envelope.error.code ?? ""}`;
      pending.reject(
        new CodexRpcError(
          pending.method,
          message,
          envelope.error.code,
          envelope.error.data,
        ),
      );
      return;
    }

    const result = (envelope as RpcSuccess).result;
    try {
      this.handleGoalRpcSuccess(pending, result);
    } catch (error) {
      pending.reject(error instanceof Error ? error : new Error(String(error)));
      return;
    }
    pending.resolve(result);
  }

  private handleGoalRpcSuccess(pending: PendingRpc, result: unknown): void {
    if (
      pending.method !== "thread/goal/get" &&
      pending.method !== "thread/goal/set" &&
      pending.method !== "thread/goal/clear"
    ) {
      return;
    }
    // Reads are not writable revisions. In particular, mobile polling must not
    // invalidate a CAS token when the authoritative Goal did not change.
    if (pending.method === "thread/goal/get") return;

    // Alternate/direct request paths still make an older clear echo ambiguous.
    this.markExpectedClearNotificationsIntervened();
    const sequence = this.recordAuthoritativeGoalStateChange();

    if (!result || typeof result !== "object") {
      throw new Error(`${pending.method} returned an invalid response`);
    }
    const response = result as Record<string, unknown>;
    if (pending.method === "thread/goal/set") {
      const goal = parseCodexGoal(response.goal);
      this.expectedGoalNotifications.push({
        sequence,
        kind: "updated",
        goal,
        expiresAt: Date.now() + 10_000,
      });
      this.trimExpectedGoalNotifications();
      this.emitMessage({
        type: "goal_state",
        goal,
        goalOperationSequence: sequence,
      });
      return;
    }
    if (pending.method === "thread/goal/clear") {
      if (typeof response.cleared !== "boolean") {
        throw new Error("thread/goal/clear returned an invalid response");
      }
      if (
        response.cleared &&
        (pending.goalOrderingGeneration === undefined ||
          pending.goalOrderingGeneration === this.goalOrderingGeneration)
      ) {
        this.expectedGoalNotifications.push({
          sequence,
          kind: "cleared",
          interveningGoalEvent: false,
          expiresAt: Date.now() + 10_000,
        });
        this.trimExpectedGoalNotifications();
      }
      this.emitMessage({
        type: "goal_state",
        goal: null,
        goalOperationSequence: sequence,
      });
    }
  }

  private trimExpectedGoalNotifications(): void {
    this.removeExpiredGoalNotifications();
    if (this.expectedGoalNotifications.length > 64) {
      this.expectedGoalNotifications.splice(
        0,
        this.expectedGoalNotifications.length - 64,
      );
    }
  }

  private handleServerRequest(
    id: number | string,
    method: string,
    params: Record<string, unknown>,
  ): void {
    switch (method) {
      case "item/commandExecution/requestApproval": {
        const toolUseId = this.extractToolUseId(params, id);
        const input: Record<string, unknown> = {
          ...(typeof params.command === "string"
            ? { command: params.command }
            : {}),
          ...(typeof params.cwd === "string" ? { cwd: params.cwd } : {}),
          ...(params.commandActions
            ? { commandActions: params.commandActions }
            : {}),
          ...(params.networkApprovalContext
            ? { networkApprovalContext: params.networkApprovalContext }
            : {}),
          ...(params.additionalPermissions
            ? { additionalPermissions: params.additionalPermissions }
            : {}),
          ...(params.skillMetadata
            ? { skillMetadata: params.skillMetadata }
            : {}),
          ...(params.proposedExecpolicyAmendment
            ? {
                proposedExecpolicyAmendment: params.proposedExecpolicyAmendment,
              }
            : {}),
          ...(params.proposedNetworkPolicyAmendments
            ? {
                proposedNetworkPolicyAmendments:
                  params.proposedNetworkPolicyAmendments,
              }
            : {}),
          ...(params.availableDecisions
            ? { availableDecisions: params.availableDecisions }
            : {}),
          ...(typeof params.reason === "string"
            ? { reason: params.reason }
            : {}),
        };

        this.pendingApprovals.set(toolUseId, {
          requestId: id,
          toolUseId,
          toolName: "Bash",
          input,
          kind: "command",
        });
        this.emitMessage({
          type: "permission_request",
          toolUseId,
          toolName: "Bash",
          input,
        });
        this.setStatus("waiting_approval");
        break;
      }

      case "item/fileChange/requestApproval": {
        const toolUseId = this.extractToolUseId(params, id);
        const input: Record<string, unknown> = {
          ...(Array.isArray(params.changes) ? { changes: params.changes } : {}),
          ...(typeof params.grantRoot === "string"
            ? { grantRoot: params.grantRoot }
            : {}),
          ...(typeof params.reason === "string"
            ? { reason: params.reason }
            : {}),
        };

        this.pendingApprovals.set(toolUseId, {
          requestId: id,
          toolUseId,
          toolName: "FileChange",
          input,
          kind: "file",
        });
        this.emitMessage({
          type: "permission_request",
          toolUseId,
          toolName: "FileChange",
          input,
        });
        this.setStatus("waiting_approval");
        break;
      }

      case "item/tool/requestUserInput": {
        const toolUseId = this.extractToolUseId(params, id);
        const questions = normalizeUserInputQuestions(params.questions);
        const input: Record<string, unknown> = {
          questions: questions.map((q) => ({
            id: q.id,
            question: q.question,
            header: q.header,
            options: q.options,
            multiSelect: false,
            isOther: q.isOther,
            isSecret: q.isSecret,
          })),
        };

        this.pendingUserInputs.set(toolUseId, {
          requestId: id,
          toolUseId,
          toolName: "AskUserQuestion",
          questions: questions.map((q) => ({
            id: q.id,
            question: q.question,
          })),
          input,
          kind: "questions",
        });
        this.emitMessage({
          type: "permission_request",
          toolUseId,
          toolName: "AskUserQuestion",
          input,
        });
        this.setStatus("waiting_approval");
        break;
      }

      case "item/permissions/requestApproval": {
        const toolUseId = this.extractToolUseId(params, id);
        const requestedPermissions = asRecord(params.permissions) ?? {};
        const input: Record<string, unknown> = {
          permissions: requestedPermissions,
          ...(typeof params.reason === "string"
            ? { reason: params.reason }
            : {}),
        };

        this.pendingApprovals.set(toolUseId, {
          requestId: id,
          toolUseId,
          toolName: "Permissions",
          input,
          kind: "permissions",
          requestedPermissions,
        });
        this.emitMessage({
          type: "permission_request",
          toolUseId,
          toolName: "Permissions",
          input,
        });
        this.setStatus("waiting_approval");
        break;
      }

      case "mcpServer/elicitation/request": {
        const toolUseId = this.extractToolUseId(params, id);
        const elicitation = createElicitationInput(params);
        const toolName =
          elicitation.kind === "tool_suggestion"
            ? "ToolSuggestion"
            : "McpElicitation";
        this.pendingUserInputs.set(toolUseId, {
          requestId: id,
          toolUseId,
          toolName,
          questions: elicitation.questions,
          input: elicitation.input,
          kind: elicitation.kind,
        });
        this.emitMessage({
          type: "permission_request",
          toolUseId,
          toolName,
          input: elicitation.input,
        });
        this.setStatus("waiting_approval");
        break;
      }

      case "currentTime/read": {
        this.respondToServerRequest(id, {
          currentTimeAt: Math.floor(Date.now() / 1000),
        });
        break;
      }

      default: {
        console.warn(`[codex-process] unsupported server request: ${method}`);
        this.respondToServerRequestError(
          id,
          -32601,
          `Unsupported server request: ${method}`,
        );
        break;
      }
    }
  }

  private queueGuardianReviewWarning(
    review: GuardianReviewDetails,
    message: string,
  ): void {
    const key = guardianReviewSignature(review);
    let pending!: PendingGuardianReviewWarning;
    const timeout = setTimeout(() => {
      const queued = this.pendingGuardianReviewWarnings.get(key);
      if (!queued) return;
      const index = queued.indexOf(pending);
      if (index === -1) return;
      queued.splice(index, 1);
      if (queued.length === 0) {
        this.pendingGuardianReviewWarnings.delete(key);
      }
      this.emitGuardianReview(review, message);
    }, GUARDIAN_REVIEW_ENRICHMENT_DELAY_MS);
    timeout.unref?.();
    pending = { review, message, timeout };
    const queued = this.pendingGuardianReviewWarnings.get(key);
    if (queued) {
      queued.push(pending);
    } else {
      this.pendingGuardianReviewWarnings.set(key, [pending]);
    }
  }

  private takePendingGuardianReviewWarning(
    review: GuardianReviewDetails,
  ): PendingGuardianReviewWarning | null {
    const exactKey = guardianReviewSignature(review);
    const exact = this.takeQueuedGuardianReviewWarning(exactKey, 0);
    if (exact) return exact;

    for (const [key, queued] of this.pendingGuardianReviewWarnings) {
      const index = queued.findIndex((pending) =>
        guardianReviewsCompatible(pending.review, review),
      );
      if (index !== -1) {
        return this.takeQueuedGuardianReviewWarning(key, index);
      }
    }
    return null;
  }

  private takeQueuedGuardianReviewWarning(
    key: string,
    index: number,
  ): PendingGuardianReviewWarning | null {
    const queued = this.pendingGuardianReviewWarnings.get(key);
    if (!queued || index < 0 || index >= queued.length) return null;
    const [pending] = queued.splice(index, 1);
    clearTimeout(pending.timeout);
    if (queued.length === 0) {
      this.pendingGuardianReviewWarnings.delete(key);
    }
    return pending;
  }

  private clearPendingGuardianReviewWarnings(): void {
    for (const queued of this.pendingGuardianReviewWarnings.values()) {
      for (const pending of queued) {
        clearTimeout(pending.timeout);
      }
    }
    this.pendingGuardianReviewWarnings.clear();
  }

  private emitGuardianReview(
    review: GuardianReviewDetails,
    legacyMessage?: string,
  ): void {
    if (review.reviewId && this.emittedGuardianReviewIds.has(review.reviewId)) {
      return;
    }
    if (
      review.status === "approved" &&
      review.risk === "low" &&
      isLowRiskAllowDecision(review.reason)
    ) {
      this.rememberGuardianReviewId(review.reviewId);
      return;
    }

    this.rememberGuardianReviewId(review.reviewId);
    if (
      review.status === "approved" &&
      (review.risk === "medium" || review.risk === "high")
    ) {
      this.emitMessage({
        type: "guardian_approval",
        risk: review.risk,
        reason: review.reason,
        ...(review.authorization
          ? { authorization: review.authorization }
          : {}),
        status: "approved",
        ...(review.reviewId ? { reviewId: review.reviewId } : {}),
        ...(review.targetItemId ? { targetItemId: review.targetItemId } : {}),
        ...(review.action ? { action: review.action } : {}),
      });
      return;
    }

    this.emitMessage({
      type: "error",
      errorCode: "codex_warning",
      message: legacyMessage ?? formatGuardianReviewWarning(review),
      guardianReview: review,
    });
  }

  private rememberGuardianReviewId(reviewId: string | undefined): void {
    if (!reviewId || this.emittedGuardianReviewIds.has(reviewId)) return;
    this.emittedGuardianReviewIds.add(reviewId);
    this.emittedGuardianReviewIdOrder.push(reviewId);
    if (this.emittedGuardianReviewIdOrder.length <= 256) return;
    const expired = this.emittedGuardianReviewIdOrder.shift();
    if (expired) this.emittedGuardianReviewIds.delete(expired);
  }

  private handleNotification(
    method: string,
    params: Record<string, unknown>,
  ): void {
    if (this.isForeignThreadNotification(method, params)) return;

    switch (method) {
      case "thread/started": {
        const thread = params.thread as Record<string, unknown> | undefined;
        if (typeof thread?.id === "string") {
          this._threadId = thread.id;
        }
        this._agentNickname = stringOrNull(thread?.agentNickname);
        this._agentRole = stringOrNull(thread?.agentRole);
        break;
      }

      case "turn/started": {
        const turn = params.turn as Record<string, unknown> | undefined;
        const turnId = stringOrNull(turn?.id);
        if (turnId) {
          this.pendingTurnId = turnId;
          this.lastCompletedTurn = null;
          this.observeCoreActionTurnStarted(turnId);
          this.agentTurnTracker.startTurn(turnId);
        }
        this.lastResultText = null;
        this.setStatus("running");
        break;
      }

      case "turn/completed": {
        this.handleTurnCompleted(
          params.turn as Record<string, unknown> | undefined,
        );
        break;
      }

      case "thread/name/updated": {
        // Name change notification — handled by session manager
        break;
      }

      case "thread/goal/updated": {
        try {
          const goal = parseCodexGoal(params.goal);
          const expected = this.consumeExpectedGoalNotification(
            "updated",
            goal,
          );
          this.goalOrderingGeneration += 1;
          if (expected !== undefined) {
            break;
          }
          this.emitMessage({
            type: "goal_state",
            goal,
            goalOperationSequence: this.nextGoalOperationSequence(),
          });
        } catch (err) {
          this.goalOrderingGeneration += 1;
          this.markExpectedClearNotificationsIntervened();
          console.warn(
            `[codex-process] Ignoring invalid goal notification: ${err instanceof Error ? err.message : String(err)}`,
          );
        }
        break;
      }

      case "thread/goal/cleared": {
        const expected = this.consumeExpectedGoalNotification("cleared");
        this.goalOrderingGeneration += 1;
        if (expected !== undefined) {
          if (expected.interveningGoalEvent) {
            void this.verifyAmbiguousClearNotification();
          }
          break;
        }
        this.emitMessage({
          type: "goal_state",
          goal: null,
          goalOperationSequence: this.nextGoalOperationSequence(),
        });
        break;
      }

      case "thread/tokenUsage/updated": {
        const usage = params.usage as Record<string, unknown> | undefined;
        if (usage) {
          this.lastTokenUsage = {
            input: numberOrUndefined(usage.inputTokens ?? usage.input_tokens),
            cachedInput: numberOrUndefined(
              usage.cachedInputTokens ?? usage.cached_input_tokens,
            ),
            output: numberOrUndefined(
              usage.outputTokens ?? usage.output_tokens,
            ),
          };
        }
        const localMessage = parseSessionInsightsNotification(params);
        if (localMessage) this.emitMessage(localMessage);
        break;
      }

      case "item/started": {
        const item = params.item as Record<string, unknown> | undefined;
        this.processItemStarted(
          item,
          stringOrNull(params.turnId) ?? stringOrNull(item?.turnId),
        );
        break;
      }

      case "item/completed": {
        const item = params.item as Record<string, unknown> | undefined;
        this.processItemCompleted(
          item,
          stringOrNull(params.turnId) ?? stringOrNull(item?.turnId),
        );
        break;
      }

      case "item/agentMessage/delta": {
        const delta =
          typeof params.delta === "string"
            ? params.delta
            : typeof params.textDelta === "string"
              ? params.textDelta
              : "";
        if (delta) {
          this.agentTurnTracker.appendDelta({
            turnId: stringOrNull(params.turnId),
            itemId: stringOrNull(params.itemId),
            text: delta,
          });
          this.emitMessage({ type: "stream_delta", text: delta });
        }
        break;
      }

      case "item/reasoning/summaryTextDelta":
      case "item/reasoning/textDelta": {
        const delta =
          typeof params.delta === "string"
            ? params.delta
            : typeof params.textDelta === "string"
              ? params.textDelta
              : "";
        if (delta) {
          this.emitMessage({ type: "thinking_delta", text: delta });
        }
        break;
      }

      case "item/plan/delta": {
        const delta = typeof params.delta === "string" ? params.delta : "";
        if (delta) {
          this.emitMessage({ type: "thinking_delta", text: delta });
        }
        break;
      }

      case "skills/changed": {
        // Re-fetch skills/apps when Codex notifies us of changes
        this.scheduleCompletionFetchFromNotification();
        break;
      }

      case "app/list/updated": {
        this.scheduleCompletionFetchFromNotification();
        break;
      }

      case "turn/plan/updated": {
        // Default mode's update_plan tool output. Keep it structured so clients
        // can render it with the same checklist UI used for Claude TodoWrite.
        const input = buildPlanUpdateToolUseInput(params);
        if (!input) break;
        this.emitMessage({
          type: "assistant",
          message: {
            id: randomUUID(),
            role: "assistant",
            content: [
              {
                type: "tool_use",
                id: `update_plan_${randomUUID()}`,
                name: "UpdatePlan",
                input,
              },
            ],
            model: this.getMessageModel(),
          },
        });
        break;
      }

      case "item/autoApprovalReview/completed": {
        const completed = parseGuardianReviewCompleted(params);
        if (!completed) break;
        const pending = this.takePendingGuardianReviewWarning(completed);
        const review = pending
          ? mergeGuardianReviewDetails(pending.review, completed)
          : completed;
        this.emitGuardianReview(review, pending?.message);
        break;
      }

      case "serverRequest/resolved": {
        this.handleServerRequestResolved(params);
        break;
      }

      case "warning": {
        const message = stringValue(params.message);
        if (message) {
          this.emitMessage({
            type: "error",
            errorCode: "codex_warning",
            message,
          });
        }
        break;
      }

      case "guardianWarning": {
        const message = stringValue(params.message);
        if (!message) break;
        const review = parseGuardianReviewWarning(message);
        if (review) {
          this.queueGuardianReviewWarning(review, message);
          break;
        }
        this.emitMessage({
          type: "error",
          errorCode: "codex_warning",
          message,
        });
        break;
      }

      case "configWarning":
      case "deprecationNotice": {
        const summary = stringValue(params.summary);
        const details = stringValue(params.details);
        if (summary || details) {
          this.emitMessage({
            type: "error",
            errorCode: "codex_warning",
            message: [summary, details].filter(Boolean).join("\n"),
          });
        }
        break;
      }

      case "error": {
        const error = asRecord(params.error);
        const message = stringValue(error?.message) ?? "Codex runtime error";
        this.emitMessage({
          type: "error",
          errorCode: params.willRetry ? "codex_warning" : "codex_runtime_error",
          message: params.willRetry ? `${message}\nCodex will retry.` : message,
        });
        break;
      }

      default:
        break;
    }
  }

  private isForeignThreadNotification(
    method: string,
    params: Record<string, unknown>,
  ): boolean {
    if (!isThreadScopedNotification(method)) return false;
    const threadId = notificationThreadId(params);
    if (!threadId) return false;

    // Thread binding comes from the thread/start or thread/resume response.
    // In shared app-server modes, early notifications can belong to another
    // client, so explicit-thread notifications are ignored until this process
    // has its own authoritative thread id.
    if (!this._threadId) return true;
    return threadId !== this._threadId;
  }

  private handleTurnCompleted(turn: Record<string, unknown> | undefined): void {
    const turnId = stringValue(turn?.id) ?? this.pendingTurnId;
    this.observeCoreActionTurnCompleted(turnId);
    const status = String(turn?.status ?? "completed");
    if (status === "completed") {
      this.prepareTurnCompletionAgentSummary(turn, turnId);
    }
    if (turnId) this.lastCompletedTurn = { turnId, status };
    this.finalizePendingAgentText(turnId);

    const usage = this.lastTokenUsage;
    this.lastTokenUsage = null;

    if (status === "failed") {
      const errorObj = turn?.error as Record<string, unknown> | undefined;
      const message =
        typeof errorObj?.message === "string"
          ? errorObj.message
          : "Turn failed";
      this.emitMessage({
        type: "result",
        subtype: "error",
        error: message,
        sessionId: this._threadId ?? undefined,
      });
    } else if (status === "interrupted") {
      this.emitMessage({
        type: "result",
        subtype: "interrupted",
        sessionId: this._threadId ?? undefined,
      });
    } else {
      this.emitMessage({
        type: "result",
        subtype: "success",
        sessionId: this._threadId ?? undefined,
        ...(this.lastResultText ? { result: this.lastResultText } : {}),
        ...(usage?.input != null ? { inputTokens: usage.input } : {}),
        ...(usage?.cachedInput != null
          ? { cachedInputTokens: usage.cachedInput }
          : {}),
        ...(usage?.output != null ? { outputTokens: usage.output } : {}),
      });
    }

    if (!turnId || this.pendingTurnId === turnId) {
      this.pendingTurnId = null;
    }

    // Plan mode: emit synthetic plan approval and wait for user decision
    if (this._collaborationMode === "plan" && this.lastPlanItemText) {
      const toolUseId = `plan_${randomUUID()}`;
      this.pendingPlanCompletion = {
        toolUseId,
        planText: this.lastPlanItemText,
      };
      this.lastPlanItemText = null;

      this.emitMessage({
        type: "permission_request",
        toolUseId,
        toolName: "ExitPlanMode",
        input: { plan: this.pendingPlanCompletion.planText },
      });
      this.setStatus("waiting_approval");
      // Do NOT set idle — waiting for plan approval
    } else {
      this.lastPlanItemText = null;
      if (
        this.pendingApprovals.size === 0 &&
        this.pendingUserInputs.size === 0
      ) {
        this.setStatus("idle");
      }
    }

    if (this.pendingTurnCompletion) {
      this.pendingTurnCompletion.resolve();
      this.pendingTurnCompletion = null;
    }
    this.cleanupSteerTempPaths();
  }

  private prepareTurnCompletionAgentSummary(
    turn: Record<string, unknown> | undefined,
    turnId: string | null,
  ): void {
    if (turn?.itemsView !== "summary" || !Array.isArray(turn.items)) return;

    const summaryItem = [...turn.items]
      .reverse()
      .find(
        (item): item is Record<string, unknown> =>
          typeof item === "object" &&
          item !== null &&
          normalizeItemType((item as Record<string, unknown>).type) ===
            "agentmessage" &&
          Boolean(extractAgentText(item as Record<string, unknown>)?.trim()),
      );
    if (!summaryItem) return;

    const summaryText = extractAgentText(summaryItem);
    if (!summaryText?.trim()) return;
    this.agentTurnTracker.seedTurnFallback({
      turnId,
      itemId: stringOrNull(summaryItem.id),
      text: summaryText,
    });
  }

  private finalizePendingAgentText(turnId: string | null): void {
    const pendingItems = this.agentTurnTracker.completeTurn(turnId);
    for (const pendingItem of pendingItems) {
      const itemId = pendingItem.itemId ?? randomUUID();
      if (pendingItem.affectsActiveTurn) {
        this.lastResultText = pendingItem.text;
      }
      this.emitMessage({
        type: "assistant",
        message: {
          id: itemId,
          role: "assistant",
          content: [{ type: "text", text: pendingItem.text }],
          model: this.getMessageModel(),
        },
      });
    }
  }

  private cleanupSteerTempPaths(): void {
    const tempPaths = this.steerTempPaths.splice(0);
    void Promise.all(
      tempPaths.map((path) => rm(path, { force: true }).catch(() => {})),
    );
  }

  private processItemStarted(
    item: Record<string, unknown> | undefined,
    turnId: string | null = null,
  ): void {
    if (!item || typeof item !== "object") return;
    const itemId = typeof item.id === "string" ? item.id : randomUUID();
    const itemType = normalizeItemType(item.type);
    if (itemType === "agentmessage") {
      this.agentTurnTracker.startAgentItem({ turnId, itemId });
    }

    const descriptor = describeCodexItemTool(item, itemType);
    if (descriptor) {
      this.emitStartedToolUse(itemId, descriptor);
    }
  }

  private emitStartedToolUse(
    itemId: string,
    descriptor: CodexItemToolDescriptor,
  ): void {
    if (this.startedToolItems.has(itemId)) return;
    this.startedToolItems.set(itemId, descriptor);
    this.emitToolUse(itemId, descriptor);
  }

  private emitToolUse(
    itemId: string,
    descriptor: CodexItemToolDescriptor,
  ): void {
    this.emitMessage({
      type: "assistant",
      message: {
        id: itemId,
        role: "assistant",
        content: [
          {
            type: "tool_use",
            id: itemId,
            name: descriptor.name,
            input: descriptor.input,
          },
        ],
        model: this.getMessageModel(),
      },
    });
  }

  private ensureStartedToolUse(
    itemId: string,
    descriptor: CodexItemToolDescriptor,
  ): void {
    const started = this.startedToolItems.get(itemId);
    this.startedToolItems.delete(itemId);
    if (!started) {
      this.emitToolUse(itemId, descriptor);
      return;
    }

    // A completed app-server item can carry a more precise parsed command
    // than its started counterpart. Re-emit the same stable assistant id so
    // capable clients replace the generic row instead of losing Read/List/Search.
    if (started.name !== descriptor.name) {
      this.emitToolUse(itemId, descriptor);
    }
  }

  private processItemCompleted(
    item: Record<string, unknown> | undefined,
    turnId: string | null = null,
  ): void {
    if (!item || typeof item !== "object") return;
    const itemId = typeof item.id === "string" ? item.id : randomUUID();
    const itemType = normalizeItemType(item.type);

    switch (itemType) {
      case "agentmessage": {
        const completedText = extractAgentText(item);
        const completion = this.agentTurnTracker.completeAgentItem({
          turnId,
          itemId,
          completedText,
        });
        if (completion.kind !== "emit") return;
        const { emission } = completion;
        if (emission.affectsActiveTurn) {
          this.lastResultText = emission.text;
        }
        this.emitMessage({
          type: "assistant",
          message: {
            id: itemId,
            role: "assistant",
            content: [{ type: "text", text: emission.text }],
            model: this.getMessageModel(),
          },
        });
        break;
      }

      case "user":
      case "usermessage":
      case "userinput": {
        const text = extractUserText(item);
        if (!text) return;
        this.emitMessage({
          type: "user_input",
          text,
          userMessageUuid: itemId,
          ...(typeof item.timestamp === "string"
            ? { timestamp: item.timestamp }
            : {}),
        } as ServerMessage);
        break;
      }

      case "reasoning": {
        const text = extractReasoningText(item);
        if (text) {
          this.emitMessage({ type: "thinking_delta", text });
        }
        break;
      }

      case "commandexecution": {
        const descriptor = describeCodexItemTool(item, itemType)!;
        this.ensureStartedToolUse(itemId, descriptor);
        const output =
          typeof item.aggregatedOutput === "string"
            ? item.aggregatedOutput
            : typeof item.output === "string"
              ? item.output
              : "";
        const exitCode = numberOrUndefined(item.exitCode ?? item.exit_code);
        this.emitMessage({
          type: "tool_result",
          toolUseId: itemId,
          content: output || `exit code: ${exitCode ?? "unknown"}`,
          toolName: descriptor.name,
        });
        break;
      }

      case "filechange": {
        const descriptor = describeCodexItemTool(item, itemType)!;
        this.ensureStartedToolUse(itemId, descriptor);
        const content = formatFileChangesWithDiff(item.changes);
        this.emitMessage({
          type: "tool_result",
          toolUseId: itemId,
          content,
          toolName: "FileChange",
        });
        break;
      }

      case "mcptoolcall": {
        const server = typeof item.server === "string" ? item.server : "mcp";
        const tool = typeof item.tool === "string" ? item.tool : "unknown";
        const toolName = `mcp:${server}/${tool}`;
        const result = item.result ?? item.error ?? "MCP call completed";
        const normalized = normalizeMcpToolResult(result);
        this.ensureStartedToolUse(itemId, {
          name: toolName,
          input: toToolUseInput(item.arguments),
        });
        this.emitMessage({
          type: "tool_result",
          toolUseId: itemId,
          content: normalized.content,
          toolName,
          ...(normalized.rawContentBlocks.length > 0
            ? { rawContentBlocks: normalized.rawContentBlocks }
            : {}),
        });
        break;
      }

      case "dynamictoolcall": {
        const tool = typeof item.tool === "string" ? item.tool : "DynamicTool";
        this.ensureStartedToolUse(itemId, {
          name: tool,
          input: toToolUseInput(item.arguments),
        });
        const content = formatDynamicToolResult(item);
        this.emitMessage({
          type: "tool_result",
          toolUseId: itemId,
          content,
          toolName: tool,
        });
        break;
      }

      case "imagegeneration": {
        this.ensureStartedToolUse(
          itemId,
          describeCodexItemTool(item, itemType)!,
        );
        const normalized = formatImageGenerationResult(item);
        this.emitMessage({
          type: "tool_result",
          toolUseId: itemId,
          content: normalized.content,
          toolName: "ImageGeneration",
          ...(normalized.rawContentBlocks.length > 0
            ? { rawContentBlocks: normalized.rawContentBlocks }
            : {}),
          ...(normalized.artifactCandidates.length > 0
            ? { artifactCandidates: normalized.artifactCandidates }
            : {}),
        });
        break;
      }

      case "websearch": {
        const query = typeof item.query === "string" ? item.query : "";
        this.ensureStartedToolUse(itemId, {
          name: "WebSearch",
          input: query ? { query } : {},
        });
        this.emitMessage({
          type: "tool_result",
          toolUseId: itemId,
          content: query ? `Web search: ${query}` : "Web search completed",
          toolName: "WebSearch",
        });
        break;
      }

      case "collabagenttoolcall": {
        const descriptor = describeCodexItemTool(item, itemType)!;
        this.ensureStartedToolUse(itemId, descriptor);
        const tool = typeof item.tool === "string" ? item.tool : "subagent";
        const status =
          typeof item.status === "string" ? item.status : "completed";
        const receiverThreadIds = Array.isArray(item.receiverThreadIds)
          ? item.receiverThreadIds.map((entry) => String(entry))
          : [];
        const content = [
          `tool: ${tool}`,
          `status: ${status}`,
          ...(receiverThreadIds.length > 0
            ? [`agents: ${receiverThreadIds.join(", ")}`]
            : []),
        ].join("\n");
        this.emitMessage({
          type: "tool_result",
          toolUseId: itemId,
          content,
          toolName: descriptor.name,
        });
        break;
      }

      case "imageview":
      case "sleep":
      case "contextcompaction":
      case "subagentactivity": {
        const descriptor = describeCodexItemTool(item, itemType)!;
        this.ensureStartedToolUse(itemId, descriptor);
        this.emitMessage({
          type: "tool_result",
          toolUseId: itemId,
          content: completedCodexItemSummary(item, itemType),
          toolName: descriptor.name,
        });
        break;
      }

      case "plan": {
        // Plan item completed — save text for plan approval emission in handleTurnCompleted()
        const planText = typeof item.text === "string" ? item.text : "";
        this.lastPlanItemText = planText;
        break;
      }

      case "exitedreviewmode": {
        const text = typeof item.review === "string" ? item.review : "";
        if (!text) break;
        this.lastResultText = text;
        this.emitMessage({
          type: "assistant",
          message: {
            id: itemId,
            role: "assistant",
            content: [{ type: "text", text }],
            model: this.getMessageModel(),
          },
        });
        break;
      }

      case "error": {
        const message =
          typeof item.message === "string" ? item.message : "Codex item error";
        this.emitMessage({ type: "error", message });
        break;
      }

      default:
        break;
    }
  }

  private async toRpcInput(pendingInput: PendingInput): Promise<{
    input: Array<Record<string, unknown>> | null;
    tempPaths: string[];
  }> {
    const input: Array<Record<string, unknown>> = [];
    const tempPaths: string[] = [];

    // Prepend structured input items before the free-form text body.
    for (const skill of pendingInput.skills ?? []) {
      input.push({
        type: "skill",
        name: skill.name,
        path: skill.path,
      });
    }
    for (const mention of pendingInput.mentions ?? []) {
      input.push({
        type: "mention",
        name: mention.name,
        path: mention.path,
      });
    }
    input.push({ type: "text", text: pendingInput.text });

    if (!pendingInput.images || pendingInput.images.length === 0) {
      return { input, tempPaths };
    }

    for (const image of pendingInput.images) {
      const ext = extensionFromMime(image.mimeType);
      if (!ext) {
        this.emitMessage({
          type: "error",
          message: `Unsupported image mime type for Codex: ${image.mimeType}`,
        });
        continue;
      }

      let buffer: Buffer;
      try {
        buffer = Buffer.from(image.base64, "base64");
      } catch {
        this.emitMessage({
          type: "error",
          message: "Invalid base64 image data for Codex input",
        });
        continue;
      }

      const tempPath = join(
        tmpdir(),
        `ccpocket-codex-image-${randomUUID()}.${ext}`,
      );
      await writeFile(tempPath, buffer);
      tempPaths.push(tempPath);
      input.push({ type: "localImage", path: tempPath });
    }

    return { input, tempPaths };
  }

  private async requestWithClientUserMessageIdFallback(
    method: "turn/start" | "turn/steer",
    params: Record<string, unknown>,
    clientMessageId?: string,
  ): Promise<unknown> {
    if (
      !clientMessageId ||
      this.clientUserMessageIdSupport.get(method) === false
    ) {
      return this.request(method, params);
    }
    try {
      const result = await this.request(method, {
        ...params,
        clientUserMessageId: clientMessageId,
      });
      this.clientUserMessageIdSupport.set(method, true);
      return result;
    } catch (error) {
      if (!isUnsupportedClientUserMessageIdError(error)) throw error;
      this.clientUserMessageIdSupport.set(method, false);
      console.warn(
        "[codex-process] app-server does not support clientUserMessageId; retrying without durable client acknowledgement",
      );
      return this.request(method, params);
    }
  }

  private request(
    method: string,
    params?: Record<string, unknown>,
    options: CodexRpcRequestOptions = {},
  ): Promise<unknown> {
    const id = this.rpcSeq++;
    const envelope =
      params === undefined ? { id, method } : { id, method, params };
    const timeoutMs =
      typeof options.timeoutMs === "number" &&
      Number.isFinite(options.timeoutMs) &&
      options.timeoutMs > 0
        ? Math.floor(options.timeoutMs)
        : undefined;

    return new Promise<unknown>((resolve, reject) => {
      if (options.signal?.aborted) {
        reject(
          new CodexRpcError(
            method,
            abortMessage(method, options.signal.reason),
          ),
        );
        return;
      }

      const pending: PendingRpc = {
        resolve,
        reject,
        method,
        ...(method === "thread/goal/get" ||
        method === "thread/goal/set" ||
        method === "thread/goal/clear"
          ? { goalOrderingGeneration: this.goalOrderingGeneration }
          : {}),
      };
      this.pendingRpc.set(id, pending);
      if (timeoutMs !== undefined) {
        pending.timeout = setTimeout(() => {
          if (this.pendingRpc.get(id) !== pending) return;
          this.pendingRpc.delete(id);
          this.clearPendingRpcLifecycle(pending);
          reject(
            new CodexRpcError(
              method,
              `${method} timed out after ${timeoutMs}ms`,
            ),
          );
        }, timeoutMs);
      }
      if (options.signal) {
        pending.signal = options.signal;
        pending.abortListener = () => {
          if (this.pendingRpc.get(id) !== pending) return;
          this.pendingRpc.delete(id);
          this.clearPendingRpcLifecycle(pending);
          reject(
            new CodexRpcError(
              method,
              abortMessage(method, options.signal?.reason),
            ),
          );
        };
        options.signal.addEventListener("abort", pending.abortListener, {
          once: true,
        });
      }
      try {
        this.writeEnvelope(envelope);
      } catch (err) {
        this.pendingRpc.delete(id);
        this.clearPendingRpcLifecycle(pending);
        reject(err instanceof Error ? err : new Error(String(err)));
      }
    });
  }

  private notify(method: string, params: Record<string, unknown>): void {
    this.writeEnvelope({ method, params });
  }

  private respondToServerRequest(
    id: number | string,
    result: Record<string, unknown>,
  ): void {
    try {
      this.writeEnvelope({ id, result });
    } catch (err) {
      if (!this.stopped) {
        console.warn(
          `[codex-process] failed to respond to server request: ${err instanceof Error ? err.message : String(err)}`,
        );
      }
    }
  }

  private respondToServerRequestError(
    id: number | string,
    code: number,
    message: string,
  ): void {
    try {
      this.writeEnvelope({ id, error: { code, message } });
    } catch (err) {
      if (!this.stopped) {
        console.warn(
          `[codex-process] failed to reject server request: ${err instanceof Error ? err.message : String(err)}`,
        );
      }
    }
  }

  private writeEnvelope(envelope: Record<string, unknown>): void {
    if (!this.transport || !this.transport.isRunning) {
      throw new Error("codex app-server is not running");
    }
    this.transport.write(envelope);
  }

  private rejectAllPending(error: Error): void {
    this.releaseCoreAction();
    this.activeCoreActionTurnId = null;
    for (const pending of this.pendingRpc.values()) {
      this.clearPendingRpcLifecycle(pending);
      pending.reject(error);
    }
    this.pendingRpc.clear();

    if (this.pendingTurnCompletion) {
      this.pendingTurnCompletion.reject(error);
      this.pendingTurnCompletion = null;
    }
  }

  private clearPendingRpcLifecycle(pending: PendingRpc): void {
    if (pending.timeout) clearTimeout(pending.timeout);
    if (pending.signal && pending.abortListener) {
      pending.signal.removeEventListener("abort", pending.abortListener);
    }
  }

  private setStatus(status: ProcessStatus): void {
    if (this._status !== status) {
      this._status = status;
      this.emit("status", status);
      this.emitMessage({ type: "status", status });
    }
  }

  private emitMessage(msg: ServerMessage): void {
    this.emit("message", msg);
  }

  private extractToolUseId(
    params: Record<string, unknown>,
    requestId: number | string,
  ): string {
    if (typeof params.approvalId === "string") return params.approvalId;
    if (typeof params.elicitationId === "string") return params.elicitationId;
    if (typeof params.itemId === "string") return params.itemId;
    if (typeof requestId === "string") return requestId;
    return `approval-${requestId}`;
  }

  private handleServerRequestResolved(params: Record<string, unknown>): void {
    const requestId = params.requestId;
    if (requestId === undefined || requestId === null) return;

    const approval = [...this.pendingApprovals.values()].find(
      (entry) => entry.requestId === requestId,
    );
    if (approval) {
      this.pendingApprovals.delete(approval.toolUseId);
      this.emitMessage({
        type: "permission_resolved",
        toolUseId: approval.toolUseId,
      });
    }

    const inputRequest = [...this.pendingUserInputs.values()].find(
      (entry) => entry.requestId === requestId,
    );
    if (inputRequest) {
      this.pendingUserInputs.delete(inputRequest.toolUseId);
      this.emitMessage({
        type: "permission_resolved",
        toolUseId: inputRequest.toolUseId,
      });
    }

    if (
      !this.pendingPlanCompletion &&
      this.pendingApprovals.size === 0 &&
      this.pendingUserInputs.size === 0
    ) {
      if (this._pendingPlanInput || this._idleWhenInteractionsClear) {
        this.resumeRunningIfNoPendingInteractiveRequest();
      } else {
        this.setStatus(this.pendingTurnId ? "running" : "idle");
      }
    }
  }
}

function buildApprovalResponse(
  pending: PendingApproval,
  decision: "accept" | "acceptForSession" | "decline" | "cancel",
): Record<string, unknown> {
  if (pending.kind === "permissions") {
    return {
      scope: decision === "acceptForSession" ? "session" : "turn",
      permissions:
        decision === "decline" ? {} : (pending.requestedPermissions ?? {}),
    };
  }

  return {
    decision,
  };
}

function resolveApprovalRejectDecision(
  pending: PendingApproval,
): "decline" | "cancel" {
  const availableDecisions = pending.input.availableDecisions;
  if (!Array.isArray(availableDecisions)) return "decline";
  const decisions = new Set(
    availableDecisions.filter(
      (entry): entry is string => typeof entry === "string",
    ),
  );
  if (decisions.has("cancel") && !decisions.has("decline")) {
    return "cancel";
  }
  return "decline";
}

function buildUserInputResponse(
  pending: PendingUserInputRequest,
  rawResult: string,
): Record<string, unknown> {
  if (pending.kind === "questions") {
    return {
      answers: buildUserInputAnswers(pending.questions, rawResult),
    };
  }

  return buildElicitationResponse(pending, rawResult);
}

function resolveUserInputRejectResult(
  pending: PendingUserInputRequest,
  fallback: string,
): string {
  if (pending.kind !== "elicitation_approval") return fallback;
  const availableDecisions = pending.input.availableDecisions;
  if (!Array.isArray(availableDecisions)) return fallback;
  const decisions = new Set(
    availableDecisions.filter(
      (entry): entry is string => typeof entry === "string",
    ),
  );
  if (decisions.has("cancel") && !decisions.has("decline")) {
    return "Cancel";
  }
  return fallback;
}

function extractWritableRootsFromConfigRead(response: unknown): string[] {
  if (!response || typeof response !== "object") return [];
  const config = (response as Record<string, unknown>).config;
  if (!config || typeof config !== "object") return [];
  const workspaceWrite = (config as Record<string, unknown>)
    .sandbox_workspace_write;
  if (!workspaceWrite || typeof workspaceWrite !== "object") return [];
  const writableRoots = (workspaceWrite as Record<string, unknown>)
    .writable_roots;
  if (!Array.isArray(writableRoots)) return [];
  return writableRoots.filter(
    (root): root is string => typeof root === "string",
  );
}

function normalizeWritableRoots(
  roots: string[],
  platform: NodeJS.Platform,
): string[] {
  const normalized = new Map<string, string>();
  for (const root of roots) {
    const trimmed = root.trim();
    if (!trimmed) continue;
    const resolved = resolvePlatformPath(trimmed, platform);
    const key = platform === "win32" ? resolved.toLowerCase() : resolved;
    if (!normalized.has(key)) {
      normalized.set(key, resolved);
    }
  }
  return [...normalized.values()];
}

function normalizeApprovalPolicy(
  value: CodexStartOptions["approvalPolicy"],
): string {
  switch (value) {
    case "on-request":
      return "on-request";
    case "on-failure":
      return "on-failure";
    case "untrusted":
      return "untrusted";
    case "never":
    default:
      return "never";
  }
}

function normalizeApprovalsReviewerForAppServer(
  value: CodexStartOptions["approvalsReviewer"],
): string {
  switch (value) {
    case "auto_review":
    case "guardian_subagent":
      return "guardian_subagent";
    case "user":
    default:
      return "user";
  }
}

function normalizeApprovalsReviewerForClient(
  value: CodexStartOptions["approvalsReviewer"],
): string {
  switch (value) {
    case "auto_review":
    case "guardian_subagent":
      return "auto_review";
    case "user":
    default:
      return "user";
  }
}

function normalizeSandboxMode(value: CodexStartOptions["sandboxMode"]): string {
  switch (value) {
    case "read-only":
      return "read-only";
    case "danger-full-access":
      return "danger-full-access";
    case "workspace-write":
    default:
      return "workspace-write";
  }
}

function normalizeReasoningEffort(
  value: NonNullable<CodexStartOptions["modelReasoningEffort"]>,
): NonNullable<CodexStartOptions["modelReasoningEffort"]> {
  return value;
}

function extractReasoningEfforts(raw: Record<string, unknown>): string[] {
  const values = Array.isArray(raw.supportedReasoningEfforts)
    ? raw.supportedReasoningEfforts
    : Array.isArray(raw.supported_reasoning_levels)
      ? raw.supported_reasoning_levels
      : [];
  const seen = new Set<string>();
  const efforts: string[] = [];
  for (const value of values) {
    const effort =
      typeof value === "string"
        ? value
        : value && typeof value === "object"
          ? ((value as Record<string, unknown>).reasoningEffort ??
            (value as Record<string, unknown>).effort)
          : undefined;
    if (typeof effort !== "string") continue;
    const normalized = effort.trim();
    if (!normalized || seen.has(normalized)) continue;
    seen.add(normalized);
    efforts.push(normalized);
  }
  return efforts;
}

function extractServiceTiers(raw: Record<string, unknown>): string[] {
  // Recent app-server versions expose the user-facing Fast option as
  // `additionalSpeedTiers: ["fast"]`, while the lower-level service tier is
  // advertised as `{ id: "priority", name: "Fast" }`. Merge both shapes and
  // normalize them to the value accepted by `service_tier` in config/RPCs.
  const values = [
    ...(Array.isArray(raw.additionalSpeedTiers)
      ? raw.additionalSpeedTiers
      : []),
    ...(Array.isArray(raw.serviceTiers) ? raw.serviceTiers : []),
  ];
  const seen = new Set<string>();
  const tiers: string[] = [];
  for (const value of values) {
    const metadata =
      value && typeof value === "object"
        ? (value as Record<string, unknown>)
        : undefined;
    const rawTier = typeof value === "string" ? value : metadata?.id;
    const rawName = metadata?.name;
    const tier =
      rawTier === "priority" ||
      (typeof rawName === "string" && rawName.toLowerCase() === "fast")
        ? "fast"
        : rawTier;
    if (typeof tier !== "string") continue;
    const normalized = tier.trim();
    if (!normalized || seen.has(normalized)) continue;
    seen.add(normalized);
    tiers.push(normalized);
  }
  return tiers;
}

function isUnsupportedThreadSettingsMethod(error: unknown): boolean {
  return (
    error instanceof CodexRpcError &&
    error.method === "thread/settings/update" &&
    error.code === -32601
  );
}

type NativePlanModeProbeResult = "supported" | "unsupported" | "unknown";

function isNativePlanModeMethodUnsupported(error: unknown): boolean {
  return (
    error instanceof CodexRpcError &&
    error.method === "collaborationMode/list" &&
    error.code === -32601
  );
}

function classifyNativePlanModeResponse(
  response: unknown,
): NativePlanModeProbeResult {
  const data = asRecord(response)?.data;
  if (!Array.isArray(data)) return "unknown";
  const modes: string[] = [];
  for (const entry of data) {
    const mode = asRecord(entry)?.mode;
    if (typeof mode !== "string" || !mode.trim()) return "unknown";
    modes.push(mode);
  }
  return modes.includes("plan") ? "supported" : "unsupported";
}

function sanitizeCodexModel(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const normalized = value.trim();
  if (!normalized || normalized === "codex") return undefined;
  return normalized;
}

function extractResolvedSettingsFromThreadResponse(
  response: Record<string, unknown>,
): CodexResolvedSettings {
  const thread = response.thread as Record<string, unknown> | undefined;
  const sandbox = response.sandbox as Record<string, unknown> | undefined;
  const collaborationMode = response.collaborationMode as
    Record<string, unknown> | undefined;
  const collaborationSettings = collaborationMode?.settings as
    Record<string, unknown> | undefined;

  return {
    model:
      sanitizeCodexModel(response.model) ?? sanitizeCodexModel(thread?.model),
    approvalPolicy:
      typeof response.approvalPolicy === "string"
        ? response.approvalPolicy
        : undefined,
    approvalsReviewer:
      typeof response.approvalsReviewer === "string"
        ? response.approvalsReviewer
        : undefined,
    sandboxMode: normalizeSandboxModeFromRpc(sandbox?.type),
    modelReasoningEffort:
      typeof response.reasoningEffort === "string"
        ? response.reasoningEffort
        : typeof collaborationSettings?.reasoning_effort === "string"
          ? collaborationSettings.reasoning_effort
          : undefined,
    serviceTier:
      typeof response.serviceTier === "string"
        ? response.serviceTier
        : undefined,
    networkAccessEnabled:
      typeof sandbox?.networkAccess === "boolean"
        ? sandbox.networkAccess
        : undefined,
    webSearchMode:
      typeof response.webSearchMode === "string"
        ? response.webSearchMode
        : undefined,
  };
}

function normalizeSandboxModeFromRpc(value: unknown): string | undefined {
  switch (value) {
    case "dangerFullAccess":
      return "danger-full-access";
    case "workspaceWrite":
      return "workspace-write";
    case "readOnly":
      return "read-only";
    default:
      return typeof value === "string" && value.length > 0 ? value : undefined;
  }
}

function normalizeSandboxPolicyFromRpc(
  value: unknown,
): CodexSandboxPolicy | undefined {
  if (!value || typeof value !== "object") return undefined;
  const policy = value as Record<string, unknown>;
  const networkAccess = policy.networkAccess ?? policy.network_access;
  const writableRoots = policy.writableRoots ?? policy.writable_roots;
  const excludeTmpdirEnvVar =
    policy.excludeTmpdirEnvVar ?? policy.exclude_tmpdir_env_var;
  const excludeSlashTmp = policy.excludeSlashTmp ?? policy.exclude_slash_tmp;
  switch (policy.type) {
    case "dangerFullAccess":
      return { type: "dangerFullAccess" };
    case "readOnly":
      return {
        type: "readOnly",
        networkAccess: networkAccess === true,
      };
    case "workspaceWrite":
      return {
        type: "workspaceWrite",
        writableRoots: Array.isArray(writableRoots)
          ? writableRoots.filter(
              (root): root is string => typeof root === "string",
            )
          : [],
        networkAccess: networkAccess === true,
        excludeTmpdirEnvVar: excludeTmpdirEnvVar === true,
        excludeSlashTmp: excludeSlashTmp === true,
      };
    default:
      return undefined;
  }
}

function normalizeItemType(raw: unknown): string {
  if (typeof raw !== "string") return "";
  return raw.replace(/[_\s-]/g, "").toLowerCase();
}

interface CodexItemToolDescriptor {
  name: string;
  input: Record<string, unknown>;
}

function describeCodexItemTool(
  item: Record<string, unknown>,
  itemType = normalizeItemType(item.type),
): CodexItemToolDescriptor | null {
  switch (itemType) {
    case "commandexecution":
      return describeCommandExecution(item);
    case "filechange":
      return {
        name: "FileChange",
        input: {
          changes: Array.isArray(item.changes) ? item.changes : [],
          ...(typeof item.status === "string" ? { status: item.status } : {}),
        },
      };
    case "mcptoolcall": {
      const server = stringOrNull(item.server) ?? "mcp";
      const tool = stringOrNull(item.tool) ?? "unknown";
      return {
        name: `mcp:${server}/${tool}`,
        input: {
          ...toToolUseInput(item.arguments),
          ...(typeof item.status === "string" ? { status: item.status } : {}),
          ...(typeof item.durationMs === "number"
            ? { durationMs: item.durationMs }
            : {}),
        },
      };
    }
    case "dynamictoolcall":
      return {
        name: stringOrNull(item.tool) ?? "DynamicTool",
        input: toToolUseInput(item.arguments),
      };
    case "imagegeneration":
      return {
        name: "ImageGeneration",
        input: toImageGenerationToolInput(item),
      };
    case "collabagenttoolcall": {
      const tool = stringOrNull(item.tool) ?? "subagent";
      return {
        name: collabToolDisplayName(tool),
        input: {
          tool,
          ...(typeof item.status === "string" ? { status: item.status } : {}),
          ...(typeof item.prompt === "string" ? { prompt: item.prompt } : {}),
          ...(typeof item.senderThreadId === "string"
            ? { senderThreadId: item.senderThreadId }
            : {}),
          ...(Array.isArray(item.receiverThreadIds)
            ? { receiverThreadIds: item.receiverThreadIds }
            : {}),
          ...(typeof item.model === "string" ? { model: item.model } : {}),
          ...(typeof item.reasoningEffort === "string"
            ? { reasoningEffort: item.reasoningEffort }
            : {}),
          ...(item.agentsStates ? { agentsStates: item.agentsStates } : {}),
        },
      };
    }
    case "subagentactivity":
      return {
        name: "SubAgentActivity",
        input: {
          ...(typeof item.kind === "string" ? { kind: item.kind } : {}),
          ...(typeof item.agentThreadId === "string"
            ? { agentThreadId: item.agentThreadId }
            : {}),
          ...(typeof item.agentPath === "string"
            ? { agentPath: item.agentPath }
            : {}),
        },
      };
    case "websearch": {
      const query = stringOrNull(item.query);
      return { name: "WebSearch", input: query ? { query } : {} };
    }
    case "imageview":
      return {
        name: "ViewImage",
        input: typeof item.path === "string" ? { path: item.path } : {},
      };
    case "sleep": {
      const durationMs = numberOrUndefined(item.durationMs ?? item.duration_ms);
      return {
        name: "Wait",
        input: durationMs === undefined ? {} : { durationMs },
      };
    }
    case "contextcompaction":
      return {
        name: "ContextCompaction",
        input: { description: "Compact the conversation context" },
      };
    default:
      return null;
  }
}

function describeCommandExecution(
  item: Record<string, unknown>,
): CodexItemToolDescriptor {
  const command =
    typeof item.command === "string"
      ? item.command
      : Array.isArray(item.command)
        ? item.command.map((part) => String(part)).join(" ")
        : "";
  const rawActions = item.commandActions ?? item.command_actions;
  const actions = Array.isArray(rawActions)
    ? rawActions
        .map((entry) => asRecord(entry))
        .filter(
          (entry): entry is Record<string, unknown> => entry !== undefined,
        )
    : [];
  const cwd = stringOrNull(item.cwd);
  const baseInput: Record<string, unknown> = {
    command,
    ...(cwd ? { cwd } : {}),
    ...(actions.length > 0 ? { commandActions: actions } : {}),
    ...(typeof item.status === "string" ? { status: item.status } : {}),
    ...(typeof item.exitCode === "number" ? { exitCode: item.exitCode } : {}),
    ...(typeof item.durationMs === "number"
      ? { durationMs: item.durationMs }
      : {}),
  };
  if (actions.length > 1) {
    return {
      name: "MultiCommand",
      input: {
        ...baseInput,
        commands: actions
          .map((action) => stringOrNull(action.command))
          .filter((value): value is string => value !== null),
      },
    };
  }
  const action = actions[0];
  if (!action) return { name: "Bash", input: baseInput };
  switch (normalizeItemType(action.type)) {
    case "read": {
      const path = stringOrNull(action.path);
      const actionName = stringOrNull(action.name);
      const readsSkill =
        path?.toLowerCase().endsWith("/skill.md") === true ||
        actionName?.toLowerCase().includes("skill") === true;
      return {
        name: readsSkill ? "ReadSkill" : "Read",
        input: {
          ...baseInput,
          ...(path ? { file_path: path } : {}),
          ...(readsSkill && path ? { skill: skillNameFromPath(path) } : {}),
        },
      };
    }
    case "listfiles":
      return {
        name: "ListFiles",
        input: {
          ...baseInput,
          ...(typeof action.path === "string" ? { path: action.path } : {}),
        },
      };
    case "search":
      return {
        name: "Search",
        input: {
          ...baseInput,
          ...(typeof action.query === "string" ? { query: action.query } : {}),
          ...(typeof action.path === "string" ? { path: action.path } : {}),
        },
      };
    default:
      return { name: "Bash", input: baseInput };
  }
}

function collabToolDisplayName(tool: string): string {
  switch (normalizeItemType(tool)) {
    case "spawnagent":
      return "SpawnAgent";
    case "sendinput":
      return "SendAgentInput";
    case "resumeagent":
      return "ResumeAgent";
    case "wait":
      return "WaitForAgents";
    case "closeagent":
      return "CloseAgent";
    default:
      return "SubAgent";
  }
}

function skillNameFromPath(path: string): string {
  const parts = path.split(/[\\/]/).filter(Boolean);
  return parts.length >= 2 ? parts[parts.length - 2] : "Skill";
}

function completedCodexItemSummary(
  item: Record<string, unknown>,
  itemType: string,
): string {
  switch (itemType) {
    case "contextcompaction":
      return "Conversation context compacted";
    case "imageview":
      return typeof item.path === "string"
        ? `Viewed image: ${item.path}`
        : "Image viewed";
    case "sleep": {
      const durationMs = numberOrUndefined(item.durationMs ?? item.duration_ms);
      return durationMs === undefined
        ? "Wait completed"
        : `Waited ${durationMs} ms`;
    }
    case "subagentactivity":
      return typeof item.kind === "string"
        ? `Sub-agent activity: ${item.kind}`
        : "Sub-agent activity updated";
    default:
      return "Tool completed";
  }
}

function isThreadScopedNotification(method: string): boolean {
  return (
    method.startsWith("thread/") ||
    method.startsWith("turn/") ||
    method.startsWith("item/") ||
    method === "guardianWarning" ||
    method === "serverRequest/resolved"
  );
}

function notificationThreadId(params: Record<string, unknown>): string | null {
  if (typeof params.threadId === "string") return params.threadId;

  const thread = params.thread;
  if (thread && typeof thread === "object") {
    const id = (thread as Record<string, unknown>).id;
    if (typeof id === "string") return id;
  }

  const turn = params.turn;
  if (turn && typeof turn === "object") {
    const id = (turn as Record<string, unknown>).threadId;
    if (typeof id === "string") return id;
  }

  return null;
}

/** Validate the app-server ThreadGoal payload at the process boundary. */
export function parseCodexGoal(value: unknown): CodexGoal {
  if (!value || typeof value !== "object") {
    throw new Error("Goal payload is missing");
  }
  const goal = value as Record<string, unknown>;
  const requiredNumbers = [
    "tokensUsed",
    "timeUsedSeconds",
    "createdAt",
    "updatedAt",
  ] as const;
  if (
    typeof goal.threadId !== "string" ||
    typeof goal.objective !== "string" ||
    typeof goal.status !== "string" ||
    goal.status.trim().length === 0 ||
    requiredNumbers.some(
      (field) =>
        typeof goal[field] !== "number" ||
        !Number.isFinite(goal[field] as number),
    ) ||
    (goal.tokenBudget !== undefined &&
      goal.tokenBudget !== null &&
      (typeof goal.tokenBudget !== "number" ||
        !Number.isFinite(goal.tokenBudget)))
  ) {
    throw new Error("Goal payload has an invalid shape");
  }
  return {
    threadId: goal.threadId,
    objective: goal.objective,
    status: goal.status,
    tokenBudget: typeof goal.tokenBudget === "number" ? goal.tokenBudget : null,
    tokensUsed: goal.tokensUsed as number,
    timeUsedSeconds: goal.timeUsedSeconds as number,
    createdAt: goal.createdAt as number,
    updatedAt: goal.updatedAt as number,
  };
}

function sameCodexGoal(left: CodexGoal, right: CodexGoal): boolean {
  return (
    left.threadId === right.threadId &&
    left.objective === right.objective &&
    left.status === right.status &&
    left.tokenBudget === right.tokenBudget &&
    left.tokensUsed === right.tokensUsed &&
    left.timeUsedSeconds === right.timeUsedSeconds &&
    left.createdAt === right.createdAt &&
    left.updatedAt === right.updatedAt
  );
}

function numberOrUndefined(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value)
    ? value
    : undefined;
}

function stringOrNull(value: unknown): string | null {
  return typeof value === "string" && value.trim().length > 0 ? value : null;
}

function summarizeFileChanges(changes: unknown): string {
  if (!Array.isArray(changes) || changes.length === 0) {
    return "No file changes";
  }

  return changes
    .map((entry) => {
      if (!entry || typeof entry !== "object") return "changed";
      const record = entry as Record<string, unknown>;
      const kind = typeof record.kind === "string" ? record.kind : "changed";
      const path = typeof record.path === "string" ? record.path : "(unknown)";
      return `${kind}: ${path}`;
    })
    .join("\n");
}

function toToolUseInput(value: unknown): Record<string, unknown> {
  if (value && typeof value === "object" && !Array.isArray(value)) {
    return value as Record<string, unknown>;
  }
  if (Array.isArray(value)) {
    return { items: value };
  }
  if (value === undefined || value === null) {
    return {};
  }
  return { value };
}

function commandExecutionToolUseInput(
  item: Record<string, unknown>,
): Record<string, unknown> {
  const command =
    typeof item.command === "string"
      ? item.command
      : Array.isArray(item.command)
        ? item.command.map((part) => String(part)).join(" ")
        : "";
  const pluginId = stringOrNull(item.pluginId ?? item.plugin_id);
  const scriptPath = stringOrNull(item.scriptPath ?? item.script_path);
  return {
    command,
    ...(pluginId ? { pluginId } : {}),
    ...(scriptPath ? { scriptPath } : {}),
  };
}

function toImageGenerationToolInput(
  item: Record<string, unknown>,
): Record<string, unknown> {
  const input: Record<string, unknown> = {};
  const status = typeof item.status === "string" ? item.status : undefined;
  const revisedPrompt = readStringField(
    item,
    "revisedPrompt",
    "revised_prompt",
  );
  if (status) input.status = status;
  if (revisedPrompt) input.revisedPrompt = revisedPrompt;
  return input;
}

function abortMessage(method: string, reason: unknown): string {
  const detail =
    reason instanceof Error
      ? reason.message
      : typeof reason === "string"
        ? reason
        : "request aborted";
  return `${method} aborted: ${detail}`;
}

function formatDynamicToolResult(item: Record<string, unknown>): string {
  const status = typeof item.status === "string" ? item.status : "completed";
  const success = typeof item.success === "boolean" ? item.success : null;
  const contentItems = Array.isArray(item.contentItems)
    ? item.contentItems
    : null;
  const parts = [
    `status: ${status}`,
    ...(success != null ? [`success: ${success}`] : []),
  ];

  if (contentItems && contentItems.length > 0) {
    for (const entry of contentItems) {
      if (!entry || typeof entry !== "object") continue;
      const record = entry as Record<string, unknown>;
      const type = typeof record.type === "string" ? record.type : "item";
      if (type === "inputText" && typeof record.text === "string") {
        parts.push(record.text);
        continue;
      }
      if (type === "inputImage" && typeof record.imageUrl === "string") {
        parts.push(`image: ${record.imageUrl}`);
        continue;
      }
      parts.push(JSON.stringify(record));
    }
  }

  return parts.join("\n");
}

function formatImageGenerationResult(item: Record<string, unknown>): {
  content: string;
  rawContentBlocks: Array<Record<string, unknown>>;
  artifactCandidates: ArtifactCandidate[];
} {
  const status = typeof item.status === "string" ? item.status : "completed";
  const revisedPrompt = readStringField(
    item,
    "revisedPrompt",
    "revised_prompt",
  );
  const savedPath = readStringField(item, "savedPath", "saved_path");
  const result = typeof item.result === "string" ? item.result.trim() : "";
  const parts = [`status: ${status}`];

  if (revisedPrompt) parts.push(`revisedPrompt: ${revisedPrompt}`);
  if (savedPath) {
    parts.push(`savedPath: ${savedPath}`);
    return {
      content: parts.join("\n"),
      rawContentBlocks: [],
      artifactCandidates: [
        {
          source: "image_generation",
          linkKind: "generated",
          localPath: savedPath,
        },
      ],
    };
  }

  const rawContentBlocks: Array<Record<string, unknown>> = [];
  if (result) {
    const base64 = stripImageDataUrlPrefix(result);
    rawContentBlocks.push({
      type: "image",
      source: {
        type: "base64",
        data: base64,
        media_type: "image/png",
      },
    });
    parts.push("Generated 1 image");
  }

  return {
    content: parts.join("\n"),
    rawContentBlocks,
    artifactCandidates: [],
  };
}

function readStringField(
  record: Record<string, unknown>,
  camelName: string,
  snakeName: string,
): string | undefined {
  const camelValue = record[camelName];
  if (typeof camelValue === "string" && camelValue.trim().length > 0) {
    return camelValue;
  }
  const snakeValue = record[snakeName];
  if (typeof snakeValue === "string" && snakeValue.trim().length > 0) {
    return snakeValue;
  }
  return undefined;
}

function stripImageDataUrlPrefix(value: string): string {
  const match = value.match(/^data:image\/[a-z0-9.+-]+;base64,(.*)$/i);
  return match ? match[1] : value;
}

function normalizeMcpToolResult(result: unknown): {
  content: string;
  rawContentBlocks: Array<Record<string, unknown>>;
} {
  if (typeof result === "string") {
    return { content: result, rawContentBlocks: [] };
  }

  const record =
    result && typeof result === "object" && !Array.isArray(result)
      ? (result as Record<string, unknown>)
      : null;
  const contentItems = Array.isArray(record?.content) ? record.content : null;
  if (!contentItems) {
    return {
      content: result == null ? "MCP call completed" : JSON.stringify(result),
      rawContentBlocks: [],
    };
  }

  const textParts: string[] = [];
  const rawContentBlocks: Array<Record<string, unknown>> = [];

  for (const entry of contentItems) {
    if (!entry || typeof entry !== "object") continue;
    const item = entry as Record<string, unknown>;
    const type = typeof item.type === "string" ? item.type : "";

    if (type === "text" && typeof item.text === "string") {
      textParts.push(item.text);
      rawContentBlocks.push({ type: "text", text: item.text });
      continue;
    }

    if (type === "image" && typeof item.data === "string") {
      const mimeType =
        typeof item.mimeType === "string"
          ? item.mimeType
          : typeof item.mediaType === "string"
            ? item.mediaType
            : typeof item.media_type === "string"
              ? item.media_type
              : "image/png";
      rawContentBlocks.push({
        type: "image",
        source: {
          type: "base64",
          data: item.data,
          media_type: mimeType,
        },
      });
      continue;
    }

    rawContentBlocks.push(item);
    textParts.push(JSON.stringify(item));
  }

  const content = textParts.join("\n").trim();
  if (content.length > 0) {
    return { content, rawContentBlocks };
  }

  const imageCount = rawContentBlocks.filter(
    (entry) => entry.type === "image",
  ).length;
  if (imageCount > 0) {
    return {
      content:
        imageCount === 1
          ? "Generated 1 image"
          : `Generated ${imageCount} images`,
      rawContentBlocks,
    };
  }

  return {
    content: result == null ? "MCP call completed" : JSON.stringify(result),
    rawContentBlocks,
  };
}

function toCodexThreadSummary(entry: unknown): CodexThreadSummary {
  const record =
    entry && typeof entry === "object"
      ? (entry as Record<string, unknown>)
      : {};
  const gitInfo =
    record.gitInfo && typeof record.gitInfo === "object"
      ? (record.gitInfo as Record<string, unknown>)
      : {};
  return {
    id: typeof record.id === "string" ? record.id : "",
    forkedFromThreadId: stringOrNull(record.forkedFromId),
    preview: typeof record.preview === "string" ? record.preview : "",
    createdAt: numberOrUndefined(record.createdAt) ?? 0,
    updatedAt: numberOrUndefined(record.updatedAt) ?? 0,
    cwd: typeof record.cwd === "string" ? record.cwd : "",
    agentNickname: stringOrNull(record.agentNickname),
    agentRole: stringOrNull(record.agentRole),
    gitBranch: stringOrNull(gitInfo.branch),
    name: stringOrNull(record.name),
  };
}

/**
 * Format file changes including unified diff content for display in chat.
 * Falls back to `kind: path` summary when no diff is available.
 */
function formatFileChangesWithDiff(changes: unknown): string {
  if (!Array.isArray(changes) || changes.length === 0) {
    return "No file changes";
  }

  return changes
    .map((entry) => {
      if (!entry || typeof entry !== "object") return "changed";
      const record = entry as Record<string, unknown>;
      const kind = typeof record.kind === "string" ? record.kind : "changed";
      const path = typeof record.path === "string" ? record.path : "(unknown)";
      const diff = typeof record.diff === "string" ? record.diff.trim() : "";

      if (diff) {
        // If diff already has unified headers, use as-is; otherwise add them
        if (diff.startsWith("---") || diff.startsWith("@@")) {
          return `--- a/${path}\n+++ b/${path}\n${diff}`;
        }
        return diff;
      }
      return `${kind}: ${path}`;
    })
    .join("\n\n");
}

function extractAgentText(item: Record<string, unknown>): string {
  if (typeof item.text === "string") return item.text;

  const parts = item.content;
  if (Array.isArray(parts)) {
    const text = parts
      .filter((part) => part && typeof part === "object")
      .map((part) => {
        const record = part as Record<string, unknown>;
        if (record.type === "text" && typeof record.text === "string") {
          return record.text;
        }
        return "";
      })
      .filter((part) => part.length > 0)
      .join("\n");
    if (text) return text;
  }

  return "";
}

function extractUserText(item: Record<string, unknown>): string {
  if (typeof item.text === "string") return item.text;
  if (typeof item.message === "string") return item.message;
  return extractAgentText(item);
}

function extractReasoningText(item: Record<string, unknown>): string {
  if (typeof item.text === "string") return item.text;

  const summary = item.summary;
  if (Array.isArray(summary)) {
    const text = summary
      .map((entry) => {
        if (!entry || typeof entry !== "object") return "";
        const record = entry as Record<string, unknown>;
        return typeof record.text === "string" ? record.text : "";
      })
      .filter((part) => part.length > 0)
      .join("\n");
    if (text) return text;
  }

  return "";
}

function normalizeUserInputQuestions(raw: unknown): Array<{
  id: string;
  question: string;
  header: string;
  options: Array<{ label: string; description: string }>;
  isOther: boolean;
  isSecret: boolean;
}> {
  if (!Array.isArray(raw)) return [];
  return raw
    .filter(
      (entry): entry is Record<string, unknown> =>
        !!entry && typeof entry === "object",
    )
    .map((entry, index) => {
      const id =
        typeof entry.id === "string" ? entry.id : `question_${index + 1}`;
      const question = typeof entry.question === "string" ? entry.question : "";
      const header =
        typeof entry.header === "string"
          ? entry.header
          : `Question ${index + 1}`;
      const optionsRaw = Array.isArray(entry.options) ? entry.options : [];
      const options = optionsRaw
        .filter(
          (option): option is Record<string, unknown> =>
            !!option && typeof option === "object",
        )
        .map((option) => ({
          label: typeof option.label === "string" ? option.label : "",
          description:
            typeof option.description === "string" ? option.description : "",
        }))
        .filter((option) => option.label.length > 0);
      return {
        id,
        question,
        header,
        options,
        isOther: Boolean(entry.isOther),
        isSecret: Boolean(entry.isSecret),
      };
    })
    .filter((question) => question.question.length > 0);
}

function buildUserInputAnswers(
  questions: PendingUserInputQuestion[],
  rawResult: string,
): Record<string, { answers: string[] }> {
  const parsed = parseResultObject(rawResult);
  const answerMap: Record<string, { answers: string[] }> = {};

  for (const question of questions) {
    const candidate =
      parsed.byId[question.id] ?? parsed.byQuestion[question.question];
    const answers = normalizeAnswerValues(candidate);
    if (answers.length > 0) {
      answerMap[question.id] = { answers };
    }
  }

  if (Object.keys(answerMap).length === 0 && questions.length > 0) {
    answerMap[questions[0].id] = { answers: normalizeAnswerValues(rawResult) };
  }

  return answerMap;
}

function parseResultObject(rawResult: string): {
  byId: Record<string, unknown>;
  byQuestion: Record<string, unknown>;
} {
  try {
    const parsed = JSON.parse(rawResult) as Record<string, unknown>;
    const byId: Record<string, unknown> = {};
    const byQuestion: Record<string, unknown> = {};

    if (parsed && typeof parsed === "object") {
      const answers = parsed.answers;
      if (answers && typeof answers === "object" && !Array.isArray(answers)) {
        for (const [key, value] of Object.entries(
          answers as Record<string, unknown>,
        )) {
          byId[key] = value;
          byQuestion[key] = value;
        }
      }
    }

    return { byId, byQuestion };
  } catch {
    return { byId: {}, byQuestion: {} };
  }
}

function parseGuardianReviewWarning(
  message: string,
): GuardianReviewDetails | null {
  const normalizedMessage = message.trim();
  const match = normalizedMessage.match(
    /^automatic approval review (approved|denied)\s*\(([^)]*)\)\s*:\s*([\s\S]+)$/i,
  );
  if (!match) {
    if (
      /^automatic approval review timed out while evaluating the requested approval\.?$/i.test(
        normalizedMessage,
      )
    ) {
      return {
        status: "timedOut",
        risk: "unknown",
        reason: normalizedMessage,
      };
    }
    return null;
  }

  const metadata = new Map<string, string>();
  for (const field of match[2].split(",")) {
    const separator = field.indexOf(":");
    if (separator === -1) continue;
    metadata.set(
      field.slice(0, separator).trim().toLowerCase(),
      field.slice(separator + 1).trim(),
    );
  }

  const risk = parseGuardianReviewRisk(metadata.get("risk"));
  const reason = match[3].trim();
  if (!reason || !risk) return null;
  const authorization = metadata.get("authorization");
  return {
    status: match[1].toLowerCase() === "denied" ? "denied" : "approved",
    risk,
    reason,
    ...(authorization ? { authorization } : {}),
  };
}

function parseGuardianReviewCompleted(
  params: Record<string, unknown>,
): GuardianReviewDetails | null {
  const review = asRecord(params.review);
  const status = parseGuardianReviewStatus(stringOrNull(review?.status));
  if (!review || !status) return null;

  const risk =
    parseGuardianReviewRisk(stringOrNull(review.riskLevel)) ?? "unknown";
  const reason = stringOrNull(review.rationale)?.trim() ?? "";
  const authorization = stringOrNull(review.userAuthorization)?.trim();
  const reviewId = stringOrNull(params.reviewId)?.trim();
  const targetItemId = stringOrNull(params.targetItemId)?.trim();
  const action = asRecord(params.action);
  return {
    status,
    risk,
    reason,
    ...(authorization ? { authorization } : {}),
    ...(reviewId ? { reviewId } : {}),
    ...(targetItemId ? { targetItemId } : {}),
    ...(action ? { action: { ...action } } : {}),
  };
}

function parseGuardianReviewRisk(
  value: string | null | undefined,
): GuardianReviewDetails["risk"] | null {
  switch (value?.trim().toLowerCase()) {
    case "low":
      return "low";
    case "medium":
      return "medium";
    case "high":
      return "high";
    case "critical":
      return "critical";
    case "unknown":
      return "unknown";
    default:
      return null;
  }
}

function parseGuardianReviewStatus(
  value: string | null,
): GuardianReviewDetails["status"] | null {
  switch (value) {
    case "approved":
      return "approved";
    case "denied":
      return "denied";
    case "timedOut":
      return "timedOut";
    case "aborted":
      return "aborted";
    default:
      return null;
  }
}

function guardianReviewSignature(review: GuardianReviewDetails): string {
  return [
    review.status,
    review.risk,
    review.authorization?.trim().toLowerCase() ?? "",
    review.reason.trim().replace(/\s+/g, " ").toLowerCase(),
  ].join("\u0000");
}

function guardianReviewsCompatible(
  pending: GuardianReviewDetails,
  completed: GuardianReviewDetails,
): boolean {
  if (pending.status !== completed.status) return false;
  if (completed.risk !== "unknown" && pending.risk !== completed.risk) {
    return false;
  }
  const pendingAuthorization = pending.authorization?.trim().toLowerCase();
  const completedAuthorization = completed.authorization?.trim().toLowerCase();
  if (
    completedAuthorization &&
    pendingAuthorization !== completedAuthorization
  ) {
    return false;
  }
  const completedReason = normalizeGuardianReviewText(completed.reason);
  return (
    completedReason.length === 0 ||
    normalizeGuardianReviewText(pending.reason) === completedReason
  );
}

function mergeGuardianReviewDetails(
  pending: GuardianReviewDetails,
  completed: GuardianReviewDetails,
): GuardianReviewDetails {
  return {
    ...completed,
    risk: completed.risk === "unknown" ? pending.risk : completed.risk,
    reason: completed.reason.trim() || pending.reason,
    authorization: completed.authorization ?? pending.authorization,
  };
}

function normalizeGuardianReviewText(value: string): string {
  return value.trim().replace(/\s+/g, " ").toLowerCase();
}

function formatGuardianReviewWarning(review: GuardianReviewDetails): string {
  if (review.status === "timedOut" && review.reason) return review.reason;
  if (review.status === "aborted") {
    return review.reason || "Automatic approval review was aborted.";
  }
  const verdict = review.status === "denied" ? "denied" : "approved";
  const authorization = review.authorization ?? "unknown";
  const reason = review.reason || "No review rationale was provided.";
  return (
    `Automatic approval review ${verdict} ` +
    `(risk: ${review.risk}, authorization: ${authorization}): ${reason}`
  );
}

function isLowRiskAllowDecision(reason: string): boolean {
  const normalized = reason.trim().replace(/\s+/g, " ");
  return /^auto-review returned a low[- ]risk allow decision\.?$/i.test(
    normalized,
  );
}

function normalizeAnswerValues(value: unknown): string[] {
  if (typeof value === "string") {
    const normalized = value.trim();
    return normalized ? [normalized] : [];
  }

  if (Array.isArray(value)) {
    return value
      .map((entry) => String(entry).trim())
      .filter((entry) => entry.length > 0);
  }

  if (value && typeof value === "object") {
    const record = value as Record<string, unknown>;
    if (Array.isArray(record.answers)) {
      return record.answers
        .map((entry) => String(entry).trim())
        .filter((entry) => entry.length > 0);
    }
  }

  if (value == null) return [];
  const normalized = String(value).trim();
  return normalized ? [normalized] : [];
}

function buildElicitationResponse(
  pending: PendingUserInputRequest,
  rawResult: string,
): Record<string, unknown> {
  if (pending.kind === "tool_suggestion") {
    return {
      action: parseElicitationAction(rawResult),
      content: null,
      _meta: null,
    };
  }

  if (pending.kind === "elicitation_url") {
    const action = parseElicitationAction(rawResult);
    return {
      action,
      content: null,
      _meta: null,
    };
  }

  if (pending.kind === "elicitation_approval") {
    return buildApprovalElicitationResponse(pending, rawResult);
  }

  const parsed = parseResultObject(rawResult);
  const content: Record<string, unknown> = {};
  const schema = asRecord(pending.input.requestedSchema);
  const properties = asRecord(schema?.properties) ?? {};

  for (const question of pending.questions) {
    const candidate =
      parsed.byId[question.id] ?? parsed.byQuestion[question.question];
    const value = coerceElicitationValue(
      candidate,
      asRecord(properties[question.id]),
    );
    if (value !== undefined) {
      content[question.id] = value;
    }
  }

  if (Object.keys(content).length === 0 && pending.questions.length === 1) {
    const questionId = pending.questions[0].id;
    const value = coerceElicitationValue(
      rawResult,
      asRecord(properties[questionId]),
    );
    if (value !== undefined) {
      content[questionId] = value;
    }
  }

  return {
    action: "accept",
    content: Object.keys(content).length > 0 ? content : null,
    _meta: null,
  };
}

function coerceElicitationValue(
  value: unknown,
  field: Record<string, unknown> | undefined,
): unknown {
  if (value == null) return undefined;
  const type = stringValue(field?.type) ?? "string";

  if (type === "array") {
    if (Array.isArray(value)) {
      const entries = value.map((entry) => String(entry));
      return entries.length > 0 ? entries : undefined;
    }
    if (typeof value === "string") {
      return value
        .split(",")
        .map((entry) => entry.trim())
        .filter(Boolean);
    }
    return [String(value)];
  }

  const scalar = Array.isArray(value) ? value[0] : value;
  if (scalar == null) return undefined;
  if (typeof scalar === "string" && scalar.trim().length === 0) {
    return undefined;
  }
  if (type === "boolean") {
    if (typeof scalar === "boolean") return scalar;
    if (String(scalar).toLowerCase() === "true") return true;
    if (String(scalar).toLowerCase() === "false") return false;
    return undefined;
  }
  if (type === "number" || type === "integer") {
    const number = typeof scalar === "number" ? scalar : Number(scalar);
    if (!Number.isFinite(number)) return undefined;
    if (type === "integer" && !Number.isInteger(number)) return undefined;
    return number;
  }
  return String(scalar);
}

function buildApprovalElicitationResponse(
  pending: PendingUserInputRequest,
  rawResult: string,
): Record<string, unknown> {
  const selection = resolveApprovalElicitationSelection(pending, rawResult);
  const normalized = selection.trim().toLowerCase();

  if (normalized === "cancel" || normalized.includes("cancel")) {
    return {
      action: "cancel",
      content: null,
      _meta: null,
    };
  }

  if (
    normalized === "deny" ||
    normalized === "decline" ||
    normalized.includes("decline") ||
    normalized.includes("deny")
  ) {
    return {
      action: "decline",
      content: null,
      _meta: null,
    };
  }

  let meta: Record<string, unknown> | null = null;
  if (
    normalized === "approve this session" ||
    normalized === "allow for this session"
  ) {
    meta = { persist: "session" };
  } else if (
    normalized === "always allow" ||
    normalized === "allow and don't ask me again"
  ) {
    meta = { persist: "always" };
  }

  return {
    action: "accept",
    content: null,
    _meta: meta,
  };
}

function parseElicitationAction(
  rawResult: string,
): "accept" | "decline" | "cancel" {
  const normalized = rawResult.trim().toLowerCase();
  if (normalized.includes("cancel")) return "cancel";
  if (normalized.includes("decline") || normalized.includes("deny"))
    return "decline";

  try {
    const parsed = JSON.parse(rawResult) as Record<string, unknown>;
    const answers = parsed.answers;
    if (answers && typeof answers === "object" && !Array.isArray(answers)) {
      const first = Object.values(answers as Record<string, unknown>)[0];
      const answer = normalizeAnswerValues(first).join(" ").toLowerCase();
      if (answer.includes("cancel")) return "cancel";
      if (answer.includes("decline") || answer.includes("deny"))
        return "decline";
    }
  } catch {
    // Fall through to accept.
  }

  return "accept";
}

function createElicitationInput(params: Record<string, unknown>): {
  input: Record<string, unknown>;
  questions: PendingUserInputQuestion[];
  kind: PendingUserInputRequest["kind"];
} {
  const serverName =
    typeof params.serverName === "string" ? params.serverName : "MCP";
  const message =
    typeof params.message === "string" ? params.message : "Provide input";

  if (params.mode === "url") {
    const url = typeof params.url === "string" ? params.url : "";
    const question = url ? `${message}\n${url}` : message;
    return {
      kind: "elicitation_url",
      questions: [{ id: "elicitation_action", question }],
      input: {
        mode: "url",
        serverName,
        url,
        message,
        questions: [
          {
            id: "elicitation_action",
            header: serverName,
            question,
            options: [
              { label: "Accept", description: "Continue with this request" },
              { label: "Decline", description: "Reject this request" },
              { label: "Cancel", description: "Cancel without accepting" },
            ],
            multiSelect: false,
            isOther: false,
            isSecret: false,
          },
        ],
      },
    };
  }

  const schema = asRecord(params.requestedSchema);
  const elicitationMeta = asRecord(params._meta);
  if (isToolSuggestionElicitation(serverName, elicitationMeta)) {
    const toolName = stringValue(elicitationMeta?.tool_name) ?? "Tool";
    return {
      kind: "tool_suggestion",
      questions: [],
      input: {
        mode: "form",
        serverName,
        message,
        _meta: elicitationMeta ?? null,
        toolType: stringValue(elicitationMeta?.tool_type),
        suggestType: stringValue(elicitationMeta?.suggest_type),
        suggestReason: stringValue(elicitationMeta?.suggest_reason) ?? message,
        toolId: stringValue(elicitationMeta?.tool_id),
        toolName,
        installUrl: stringValue(elicitationMeta?.install_url),
        remotePluginId: stringValue(elicitationMeta?.remote_plugin_id),
        appConnectorIds: Array.isArray(elicitationMeta?.app_connector_ids)
          ? elicitationMeta.app_connector_ids.filter(
              (entry): entry is string => typeof entry === "string",
            )
          : [],
        installState: "idle",
        appsNeedingAuth: [],
      },
    };
  }
  if (isApprovalActionElicitation(schema, serverName, elicitationMeta)) {
    const questionId = "approval";
    const isToolApproval = isToolApprovalElicitation(elicitationMeta);
    return {
      kind: "elicitation_approval",
      questions: [{ id: questionId, question: message }],
      input: {
        mode: "form",
        serverName,
        message,
        _meta: elicitationMeta ?? null,
        availableDecisions: buildApprovalActionElicitationAvailableDecisions(
          elicitationMeta,
          isToolApproval,
        ),
        questions: [
          {
            id: questionId,
            header: "Approve app tool call?",
            question: message,
            options: buildApprovalActionElicitationOptions(
              elicitationMeta,
              isToolApproval,
            ),
            multiSelect: false,
            isOther: false,
            isSecret: false,
          },
        ],
      },
    };
  }
  const properties = asRecord(schema?.properties) ?? {};
  const requiredFields = new Set(
    Array.isArray(schema?.required)
      ? schema!.required!.map((entry) => String(entry))
      : [],
  );

  const questions = Object.entries(properties)
    .filter(([, value]) => value && typeof value === "object")
    .map(([key, value]) => {
      const field = value as Record<string, unknown>;
      const title = typeof field.title === "string" ? field.title : key;
      const description =
        typeof field.description === "string" ? field.description : message;
      const type = typeof field.type === "string" ? field.type : "";
      const options = buildElicitationFieldOptions(field, description);

      return {
        id: key,
        question: requiredFields.has(key) ? `${title} (required)` : title,
        header: serverName,
        options,
        required: requiredFields.has(key),
        multiSelect: type === "array",
        isOther: options.length === 0,
        isSecret: false,
      };
    });

  const normalizedQuestions =
    questions.length > 0
      ? questions
      : [
          {
            id: "value",
            question: message,
            header: serverName,
            options: [] as Array<{
              label: string;
              value: string;
              description: string;
            }>,
            required: true,
            multiSelect: false,
            isOther: true,
            isSecret: false,
          },
        ];

  return {
    kind: "elicitation_form",
    questions: normalizedQuestions.map((question) => ({
      id: question.id,
      question: question.question,
      required: question.required,
    })),
    input: {
      mode: "form",
      serverName,
      message,
      _meta: elicitationMeta ?? null,
      requestedSchema: schema,
      questions: normalizedQuestions.map((question) => ({
        id: question.id,
        header: question.header,
        question: question.question,
        options: question.options,
        required: question.required,
        multiSelect: question.multiSelect,
        isOther: question.isOther,
        isSecret: question.isSecret,
      })),
    },
  };
}

function buildElicitationFieldOptions(
  field: Record<string, unknown>,
  description: string,
): Array<{ label: string; value: string; description: string }> {
  const type = stringValue(field.type);
  const source = type === "array" ? (asRecord(field.items) ?? {}) : field;
  const rawOptions = Array.isArray(source.oneOf)
    ? source.oneOf
    : Array.isArray(source.anyOf)
      ? source.anyOf
      : null;
  if (rawOptions) {
    return rawOptions.flatMap((entry, index) => {
      const option = asRecord(entry);
      const value = stringValue(option?.const);
      if (!value) return [];
      return [
        {
          label: stringValue(option?.title) ?? value,
          value,
          description: index === 0 ? description : "",
        },
      ];
    });
  }

  if (Array.isArray(source.enum)) {
    return source.enum.map((entry, index) => {
      const value = String(entry);
      return {
        label: value,
        value,
        description: index === 0 ? description : "",
      };
    });
  }

  if (type === "boolean") {
    return [
      { label: "true", value: "true", description },
      { label: "false", value: "false", description: "" },
    ];
  }
  return [];
}

function isApprovalActionElicitation(
  schema: Record<string, unknown> | undefined,
  serverName: string,
  meta: Record<string, unknown> | undefined,
): boolean {
  return (
    isEmptyObjectSchema(schema) &&
    !isToolSuggestionElicitation(serverName, meta)
  );
}

function isEmptyObjectSchema(
  schema: Record<string, unknown> | undefined,
): boolean {
  if (!schema) return false;
  if (schema.type !== "object") return false;
  const properties = asRecord(schema.properties);
  return properties != null && Object.keys(properties).length === 0;
}

function isToolApprovalElicitation(
  meta: Record<string, unknown> | undefined,
): boolean {
  return meta?.codex_approval_kind === "mcp_tool_call";
}

function isToolSuggestionElicitation(
  serverName: string,
  meta: Record<string, unknown> | undefined,
): boolean {
  return (
    serverName === "codex_apps" &&
    meta?.codex_approval_kind === "tool_suggestion"
  );
}

function buildApprovalActionElicitationOptions(
  meta: Record<string, unknown> | undefined,
  isToolApproval: boolean,
): Array<{ label: string; description: string }> {
  const persistModes = extractPersistModes(meta);
  const options = [
    {
      label: "Allow",
      description: isToolApproval
        ? "Run the tool and continue."
        : "Allow this request and continue.",
    },
  ];
  if (persistModes.has("session")) {
    options.push({
      label: "Allow for this session",
      description: isToolApproval
        ? "Run the tool and remember this choice for this session."
        : "Allow this request and remember this choice for this session.",
    });
  }
  if (persistModes.has("always")) {
    options.push({
      label: "Always allow",
      description: isToolApproval
        ? "Run the tool and remember this choice for future tool calls."
        : "Allow this request and remember this choice for future requests.",
    });
  }
  if (!isToolApproval) {
    options.push({
      label: "Deny",
      description: "Decline this request and continue.",
    });
  }
  options.push(
    isToolApproval
      ? {
          label: "Cancel",
          description: "Cancel this tool call.",
        }
      : {
          label: "Cancel",
          description: "Cancel this request.",
        },
  );
  return options;
}

function buildApprovalActionElicitationAvailableDecisions(
  meta: Record<string, unknown> | undefined,
  isToolApproval: boolean,
): string[] {
  const persistModes = extractPersistModes(meta);
  return [
    "accept",
    ...(persistModes.has("session") ? ["acceptForSession"] : []),
    isToolApproval ? "cancel" : "decline",
  ];
}

function extractPersistModes(
  meta: Record<string, unknown> | undefined,
): Set<"session" | "always"> {
  const persist = meta?.persist;
  const modes = new Set<"session" | "always">();

  if (typeof persist === "string") {
    if (persist === "session" || persist === "always") {
      modes.add(persist);
    }
    return modes;
  }

  if (Array.isArray(persist)) {
    for (const entry of persist) {
      if (entry === "session" || entry === "always") {
        modes.add(entry);
      }
    }
  }

  return modes;
}

function resolveApprovalElicitationSelection(
  pending: PendingUserInputRequest,
  rawResult: string,
): string {
  const parsed = parseResultObject(rawResult);

  for (const question of pending.questions) {
    const candidate =
      parsed.byId[question.id] ?? parsed.byQuestion[question.question];
    const answers = normalizeAnswerValues(candidate);
    if (answers.length > 0) return answers[0];
  }

  const directAnswers = normalizeAnswerValues(rawResult);
  if (directAnswers.length > 0) return directAnswers[0];

  return rawResult;
}

function asRecord(value: unknown): Record<string, unknown> | undefined {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : undefined;
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function normalizeToolSuggestionApps(value: unknown): ToolSuggestionApp[] {
  if (!Array.isArray(value)) return [];
  return value.flatMap((entry) => {
    const app = asRecord(entry);
    const id = stringValue(app?.id);
    const name = stringValue(app?.name);
    if (!id || !name) return [];
    const description = stringValue(app?.description);
    const installUrl = stringValue(app?.installUrl);
    const category = stringValue(app?.category);
    return [
      {
        id,
        name,
        ...(description ? { description } : {}),
        ...(installUrl ? { installUrl } : {}),
        ...(category ? { category } : {}),
      },
    ];
  });
}

function buildPlanUpdateToolUseInput(
  params: Record<string, unknown>,
): Record<string, unknown> | null {
  const stepsRaw = params.plan;
  if (!Array.isArray(stepsRaw) || stepsRaw.length === 0) return null;

  const explanation =
    typeof params.explanation === "string" ? params.explanation.trim() : "";
  const todos = stepsRaw
    .filter(
      (entry): entry is Record<string, unknown> =>
        !!entry && typeof entry === "object",
    )
    .map((entry, index) => {
      const content =
        typeof entry.step === "string" ? entry.step : `Step ${index + 1}`;
      const status = normalizePlanStatus(entry.status);
      return { content, status, activeForm: "" };
    });

  if (todos.length === 0) return null;
  return {
    title: "Plan update",
    ...(explanation ? { explanation } : {}),
    todos,
  };
}

function normalizePlanStatus(raw: unknown): string {
  switch (raw) {
    case "inProgress":
      return "in_progress";
    case "completed":
      return "completed";
    case "pending":
    default:
      return "pending";
  }
}

function extensionFromMime(mimeType: string): string | null {
  switch (mimeType) {
    case "image/png":
      return "png";
    case "image/jpeg":
      return "jpg";
    case "image/webp":
      return "webp";
    case "image/gif":
      return "gif";
    default:
      return null;
  }
}
