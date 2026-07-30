import type { IncomingMessage, Server as HttpServer } from "node:http";
import { createHash, randomUUID } from "node:crypto";
import { execFile, execFileSync } from "node:child_process";
import { readFileSync, existsSync, realpathSync } from "node:fs";
import {
  lstat,
  open,
  readFile,
  readlink,
  realpath,
  stat,
  unlink,
} from "node:fs/promises";
import type { FileHandle } from "node:fs/promises";
import { resolve, extname, basename, relative } from "node:path";
import { StringDecoder } from "node:string_decoder";
import { promisify } from "node:util";
import { WebSocketServer, WebSocket } from "ws";
import {
  SessionCatalogMonitor,
  type SessionCatalogChange,
} from "./session-catalog-monitor.js";
import {
  artifactCandidateRootsForSession,
  publicQueuedInput,
  SessionManager,
  MAX_HISTORY_PER_SESSION,
  type HistoryEntry,
  type InputDeliveryReceipt,
  type SessionInfo,
  type WorktreeOptions,
} from "./session.js";
import {
  SdkProcess,
  listAvailableClaudeModels,
  type ClaudeEffortLevel,
  type ClaudeModelMetadata,
} from "./sdk-process.js";
import type { StartOptions } from "./sdk-process.js";
import {
  codexErrorMessage,
  CodexProcess,
  CodexRpcError,
  createCodexGoalResumeLease,
  matchesCodexGoalResumeLease,
  type CodexGoalResumeLease,
  type CodexModelMetadata,
  type CodexNextTurnPermissionSettings,
  type CodexStartOptions,
  type CodexThreadSourceKind,
  type CodexThreadSummary,
} from "./codex-process.js";
import { codexSourceIdentity } from "./codex-home.js";
import { stopManagedCodexAppServers } from "./codex-transport.js";
import {
  parseClientMessage,
  type AssistantContent,
  type ClientMessage,
  type DebugTraceEvent,
  type CodexGoal,
  type ImageChange,
  type HistoryToolDetailPayload,
  type Provider,
  type SessionLinkProgressOperation,
  type SessionLinkProgressStage,
  type ServerMessage,
} from "./parser.js";
import {
  getAllRecentSessions,
  getCodexDesktopToolTimeline,
  getCodexSessionHistory,
  getSessionHistory,
  codexUserTurnUuid,
  codexThreadToSessionHistory,
  type SessionHistoryMessage,
  findSessionsByClaudeIds,
  extractMessageImages,
  getClaudeSessionName,
  getCodexSessionIndexMetadata,
  type CodexSessionIndexMetadata,
  loadCodexSessionNames,
  normalizeWorktreePath,
  renameClaudeSession,
  renameCodexSession,
  saveCodexSessionProfile,
} from "./sessions-index.js";
import type { ImageRef, ImageStore } from "./image-store.js";
import {
  formatResumePerformanceLog,
  summarizeResumeHistory,
} from "./resume-metrics.js";
import type { GalleryStore } from "./gallery-store.js";
import type { ProjectHistory } from "./project-history.js";
import {
  ArchiveStore,
  type ArchiveCapacityReservation,
} from "./archive-store.js";
import { WorktreeStore } from "./worktree-store.js";
import {
  listWorktrees,
  removeWorktree,
  createWorktree,
  worktreeExists,
  getMainBranch,
} from "./worktree.js";
import {
  stageFiles,
  stageHunks,
  unstageFiles,
  unstageHunks,
  gitCommit,
  gitPush,
  listProjectFilesAndDirectoriesForClient,
  listBranches,
  createBranch,
  checkoutBranch,
  revertFiles,
  revertHunks,
  gitFetch,
  gitPull,
  gitRemoteStatus,
  gitStatus,
} from "./git-operations.js";
import { generateCommitMessage } from "./git-assist.js";
import { listWindows, takeScreenshot } from "./screenshot.js";
import { DebugTraceStore } from "./debug-trace-store.js";
import { RecordingStore } from "./recording-store.js";
import { PushRelayClient, type PushNotifyPayload } from "./push-relay.js";
import type { FirebaseAuthClient } from "./firebase-auth.js";
import { type PushLocale, normalizePushLocale, t } from "./push-i18n.js";
import {
  BACKGROUND_ACTIVITY_STATE_MESSAGE,
  BACKGROUND_NOTIFICATION_ACK_CAPABILITY,
  BACKGROUND_NOTIFICATION_ACK_MESSAGE,
  BACKGROUND_NOTIFICATION_DELIVERY_CAPABILITY,
  BACKGROUND_NOTIFICATION_MESSAGE,
  CLIENT_DELIVERY_MODE_STATE_MESSAGE,
  type BackgroundActivityStateMessage,
  type ClientDeliveryMode,
} from "./background-delivery-protocol.js";
import {
  createBackgroundNotificationPolicy,
  createBackgroundNotificationProjectionState,
  projectBackgroundNotification,
  type BackgroundNotificationPolicy,
  type BackgroundNotificationProjectionState,
} from "./background-notification-projector.js";
import {
  PUSH_REGISTRATION_STATE_MESSAGE,
  PUSH_REGISTRATION_STATUS_CAPABILITY,
  type PushRegistrationStateMessage,
} from "./push-registration-protocol.js";
import { fetchAllUsage } from "./usage.js";
import type { PromptHistoryBackupStore } from "./prompt-history-backup.js";
import type { PromptHistoryStore } from "./prompt-history-store.js";
import { getPackageVersion } from "./version.js";
import {
  isPathWithinAllowedDirectory,
  resolvePlatformPath,
  resolvePlatformPathFrom,
} from "./path-utils.js";
import {
  deriveCodexPermissionsMode,
  normalizeCodexPermissionsMode,
  withDerivedCodexPermissionsMode,
} from "./codex-permissions.js";
import { ArtifactManager, ArtifactResolveError } from "./artifact-manager.js";
import { validateFileTransferPeerBaseUrl } from "./file-transfer-utils.js";
import { createPathArtifactCandidate } from "./artifact-candidates.js";
import { createLocalFeaturesController } from "./local-features/registry.js";
import type { LocalFeaturesController } from "./local-features/controller.js";
import {
  APP_SERVER_STATUS_CAPABILITY,
  BRIDGE_IDENTITY_V2_CAPABILITY,
  CONVERSATION_CONTENT_EVENT_CAPABILITY,
  CONVERSATION_ITEMS_BY_ID_CAPABILITY,
  CONVERSATION_MIRROR_SOURCE_IDENTITY_CAPABILITY,
  CONVERSATION_SYNC_V2_CAPABILITY,
  DURABLE_SESSION_INSIGHTS_CAPABILITY,
  EPHEMERAL_SIDE_CHAT_CAPABILITY,
  EPHEMERAL_SIDE_CHAT_PARENT_IDENTITY_CAPABILITY,
  FILE_BROWSER_CAPABILITY,
  FILE_BROWSER_PROJECT_PREVIEW_CAPABILITY,
  isLocalFeatureServerMessageType,
} from "./local-features/protocol.js";
import type { FileTransferManager } from "./file-transfer-manager.js";
import type { FileBrowserManager } from "./file-browser-manager.js";
import {
  FILE_MUTATION_AUTH_CAPABILITY,
  FILE_TRANSFER_UPLOAD_AUTH_CAPABILITY,
  type FileMutationAuthorizer,
} from "./file-mutation-auth.js";
import { BridgeApiKeyAuthenticator } from "./bridge-http-auth.js";
import {
  FILE_TRANSFER_CAPABILITY,
  isFileTransferClientMessage,
  isFileTransferServerMessageType,
} from "./file-transfer-protocol.js";
import {
  CodexGoalConflictError,
  CodexGoalController,
  isUnsupportedCodexGoalRpc,
} from "./codex-goal-controller.js";
import {
  HISTORY_PAGE_CAPABILITY,
  HISTORY_TOOL_DETAIL_CAPABILITY,
  selectTurnAwareHistoryWindow,
  TURN_AWARE_HISTORY_WINDOW_CAPABILITY,
} from "./history-window.js";

type SystemServerMessage = Extract<ServerMessage, { type: "system" }>;
type InputClientMessage = Extract<ClientMessage, { type: "input" }>;
type FileContentServerMessage = Extract<
  ServerMessage,
  { type: "file_content" }
>;
type ResumeClientMessage = Extract<ClientMessage, { type: "resume_session" }>;
type ResumeOperationWaiter = {
  ws: WebSocket;
  resumeRequestId?: string;
  sessionLinkGeneration?: number;
  progressSequence: number;
};
type ResumeOperationProgress = {
  stage: SessionLinkProgressStage;
  completedUnits?: number;
  totalUnits?: number;
};
type ResumeOperation = {
  id: string;
  provider: Provider;
  sourceSessionId: string;
  projectPath: string;
  fingerprint: string;
  waiters: ResumeOperationWaiter[];
  latestProgress?: ResumeOperationProgress;
  timeout?: ReturnType<typeof setTimeout>;
  completed?: {
    sessionId: string;
    message: SystemServerMessage;
    completedAt: number;
  };
};
const RESUME_OPERATION_TIMEOUT_MS = 5 * 60 * 1000;
const RESUME_COMPLETED_TTL_MS = 30 * 1000;
type ClaudePermissionMode =
  "default" | "auto" | "acceptEdits" | "bypassPermissions" | "plan";
type BackgroundDeliveryClientState = {
  mode: Extract<ClientDeliveryMode, "notifications_only">;
  policy: BackgroundNotificationPolicy;
  projectionState: BackgroundNotificationProjectionState;
};

type PendingBackgroundPushDelivery = {
  payloads: PushNotifyPayload[];
  candidateTokens: Set<string>;
  acknowledgedTokens: Set<string>;
  timer: NodeJS.Timeout;
};

const FILE_PEEK_TEXT_MAX_BYTES = 8 * 1024 * 1024;
const FILE_PEEK_READ_CHUNK_BYTES = 64 * 1024;
const FILE_PEEK_PREVIEW_MAX_BYTES = 512 * 1024;
const FILE_PEEK_PREVIEW_MAX_LINE_CHARS = 64 * 1024;
const HISTORY_TOOL_DETAIL_FIELD_MAX_BYTES = 64 * 1024;
const HISTORY_TOOL_DETAIL_MAX_ATTACHMENTS = 32;

function boundedHistoryToolDetailInput(
  value: Record<string, unknown>,
): Record<string, unknown> {
  let encoded: string;
  try {
    encoded = JSON.stringify(value);
  } catch {
    return {
      truncated: true,
      preview: "[Tool input could not be serialized by Bridge]",
    };
  }
  if (
    Buffer.byteLength(encoded, "utf8") <= HISTORY_TOOL_DETAIL_FIELD_MAX_BYTES
  ) {
    return value;
  }
  return {
    truncated: true,
    preview: boundedHistoryToolDetailText(encoded),
  };
}

function boundedHistoryToolDetailText(value: string): string {
  if (Buffer.byteLength(value, "utf8") <= HISTORY_TOOL_DETAIL_FIELD_MAX_BYTES) {
    return value;
  }
  const bytes = Buffer.from(value, "utf8");
  const decoder = new StringDecoder("utf8");
  return `${decoder.write(
    bytes.subarray(0, HISTORY_TOOL_DETAIL_FIELD_MAX_BYTES),
  )}\n…[truncated by Bridge]`;
}

const CODEX_PERMISSION_APPLY_STRATEGY_CAPABILITY =
  "codex_permission_apply_strategy_v1";
const CODEX_SESSION_LIFECYCLE_CAPABILITY = "codex_session_lifecycle_v1";
const CODEX_DESKTOP_CONTINUITY_CAPABILITY = "codex_desktop_continuity_v1";
const CODEX_RESUME_PRESERVES_SETTINGS_CAPABILITY =
  "codex_resume_preserves_settings_v1";
const CODEX_HOME_IDENTITY_CAPABILITY = "codex_home_identity_v1";
const PUSH_NOTIFICATION_PREFERENCES_CAPABILITY =
  "push_notification_preferences_v1";
const PUSH_PROGRESS_EVENT = "session_progress";
const PUSH_PROGRESS_MIN_INTERVAL_MS = 45_000;
const BACKGROUND_PUSH_ACK_WAIT_MS = 750;
const MAX_PENDING_BACKGROUND_PUSH_DELIVERIES = 128;
const BOUNDED_HISTORY_WINDOW_CAPABILITY = "bounded_history_window_v1";
const SESSION_ACTIVITY_AT_CAPABILITY = "session_activity_at_v1";
const SESSION_REQUEST_CORRELATION_CAPABILITY = "session_request_correlation_v1";
const PROMPT_HISTORY_REQUEST_CORRELATION_CAPABILITY =
  "prompt_history_request_correlation_v1";
const SESSION_CATALOG_WATCH_CAPABILITY = "session_catalog_watch_v1";
const SESSION_CATALOG_REQUEST_CORRELATION_CAPABILITY =
  "session_catalog_request_correlation_v1";
const SESSION_CATALOG_CHANGED_MESSAGE = "session_catalog_changed_v1";
const SESSION_LINK_PROGRESS_CAPABILITY = "session_link_progress_v1";
const FILE_LIST_REQUEST_CORRELATION_CAPABILITY =
  "file_list_request_correlation_v1";
const GIT_DIFF_REQUEST_CORRELATION_CAPABILITY =
  "git_diff_request_correlation_v1";
const GIT_PROJECT_RESULT_CORRELATION_CAPABILITY =
  "git_project_result_correlation_v1";
const INPUT_DELIVERY_ACK_CAPABILITY = "input_delivery_ack_v1";
const INPUT_DELIVERY_STATUS_MESSAGE = "input_delivery_status_v1";
const BOUNDED_HISTORY_WINDOW_ENTRIES = 200;
const ARCHIVED_SESSION_LIST_LIMIT = 1_000;
const CODEX_GOAL_RAW_STATUS_CAPABILITY = "goal_state_raw_status";
const KNOWN_CODEX_GOAL_STATUSES = new Set([
  "active",
  "paused",
  "blocked",
  "usageLimited",
  "budgetLimited",
  "complete",
]);

/**
 * True when a WebSocket Origin header points at a private/LAN host:
 * localhost, loopback, RFC1918, Tailscale CGNAT (100.64/10), IPv6
 * loopback/ULA/link-local, or an mDNS .local name. Public origins —
 * the drive-by vector — stay rejected. Deliberately string-based (no
 * DNS resolution), so a public hostname that *resolves* to a private
 * address (DNS rebinding) is still rejected.
 */
export function isPrivateOrigin(origin: string): boolean {
  let hostname: string;
  try {
    hostname = new URL(origin).hostname;
  } catch {
    return false;
  }
  const bare =
    hostname.startsWith("[") && hostname.endsWith("]")
      ? hostname.slice(1, -1)
      : hostname;
  if (bare === "localhost" || bare.endsWith(".localhost")) return true;
  if (bare.endsWith(".local")) return true;
  if (bare.includes(":")) {
    return bare === "::1" || /^f[cd]/i.test(bare) || /^fe[89ab]/i.test(bare);
  }
  const ipv4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(bare);
  if (!ipv4) return false;
  const a = Number(ipv4[1]);
  const b = Number(ipv4[2]);
  if (a === 127 || a === 10) return true;
  if (a === 192 && b === 168) return true;
  if (a === 172 && b >= 16 && b <= 31) return true;
  if (a === 100 && b >= 64 && b <= 127) return true;
  return false;
}

function normalizeBrowserOrigin(origin: string): string | null {
  try {
    const url = new URL(origin);
    if (url.protocol !== "http:" && url.protocol !== "https:") return null;
    if (url.username || url.password) return null;
    return url.origin;
  } catch {
    return null;
  }
}

function websocketHostName(host: string | undefined): string | null {
  if (!host) return null;
  try {
    return new URL(`ws://${host}`).hostname.toLowerCase();
  } catch {
    return null;
  }
}

export function isAllowedBrowserOrigin(
  origin: string,
  websocketHost: string | undefined,
  explicitlyAllowedOrigins: ReadonlySet<string> = new Set(),
): boolean {
  const normalized = normalizeBrowserOrigin(origin);
  if (!normalized) return false;
  if (explicitlyAllowedOrigins.has(normalized)) return true;
  if (!isPrivateOrigin(normalized)) return false;

  const originHost = new URL(normalized).hostname.toLowerCase();
  return originHost === websocketHostName(websocketHost);
}

function configuredWebSocketOrigins(values: string[] | undefined): Set<string> {
  const configured =
    values ??
    process.env.BRIDGE_ALLOWED_ORIGINS?.split(",").map((value) =>
      value.trim(),
    ) ??
    [];
  return new Set(
    configured
      .map(normalizeBrowserOrigin)
      .filter((value): value is string => value !== null),
  );
}

function httpBaseUrlForWebSocketRequest(
  request?: IncomingMessage,
): string | undefined {
  if (!request) return undefined;
  const forwardedHost = firstForwardedHeader(
    request.headers["x-forwarded-host"],
  );
  const host = forwardedHost ?? request.headers.host;
  if (!host) return undefined;
  const forwardedProtocol = firstForwardedHeader(
    request.headers["x-forwarded-proto"],
  )?.toLowerCase();
  const secureSocket = Boolean(
    (request.socket as typeof request.socket & { encrypted?: boolean })
      .encrypted,
  );
  const protocol =
    forwardedProtocol === "https" || forwardedProtocol === "wss"
      ? "https"
      : forwardedProtocol === "http" || forwardedProtocol === "ws"
        ? "http"
        : secureSocket
          ? "https"
          : "http";
  return validateFileTransferPeerBaseUrl(`${protocol}://${host}`);
}

function firstForwardedHeader(
  value: string | string[] | undefined,
): string | undefined {
  const raw = Array.isArray(value) ? value[0] : value;
  const first = raw?.split(",", 1)[0]?.trim();
  return first || undefined;
}
const PERMISSION_RESTART_BLOCKED_MESSAGE_TYPES = new Set([
  "update_queued_input",
  "cancel_queued_input",
  "steer_queued_input",
  "set_codex_model",
  "set_codex_speed",
  "set_goal",
  "clear_goal",
  "set_sandbox_mode",
  "install_tool_suggestion",
  "stop_session",
  "interrupt",
  "archive_session",
  "unarchive_session",
  "delete_session",
  "rewind",
  "fork",
  "rename_session",
]);

class FilePeekReadError extends Error {
  constructor(
    readonly code: "file_too_large" | "file_changed" | "not_regular_file",
    message: string,
  ) {
    super(message);
  }
}

function sameOpenFileStats(
  before: { dev: number; ino: number; size: number; mtimeMs: number },
  after: { dev: number; ino: number; size: number; mtimeMs: number },
): boolean {
  return (
    before.dev === after.dev &&
    before.ino === after.ino &&
    before.size === after.size &&
    before.mtimeMs === after.mtimeMs
  );
}

async function stableFileStats(
  handle: FileHandle,
  maxBytes: number,
  tooLargeMessage: string,
  expectedIdentity?: {
    dev: number;
    ino: number;
    size: number;
    mtimeMs: number;
  },
) {
  const stats = await handle.stat();
  if (!stats.isFile()) {
    throw new FilePeekReadError(
      "not_regular_file",
      "This path is not a regular file.",
    );
  }
  if (stats.size > maxBytes) {
    throw new FilePeekReadError("file_too_large", tooLargeMessage);
  }
  if (expectedIdentity && !sameOpenFileStats(expectedIdentity, stats)) {
    throw new FilePeekReadError(
      "file_changed",
      "File changed before it could be read.",
    );
  }
  return stats;
}

async function readStableTextFromHandle(
  handle: FileHandle,
  maxLines: number,
  expectedIdentity?: {
    dev: number;
    ino: number;
    size: number;
    mtimeMs: number;
  },
): Promise<{ content: string; totalLines: number; truncated: boolean }> {
  const before = await stableFileStats(
    handle,
    FILE_PEEK_TEXT_MAX_BYTES,
    "File is too large to preview. Maximum size is 8 MiB.",
    expectedIdentity,
  );
  const buffer = Buffer.allocUnsafe(FILE_PEEK_READ_CHUNK_BYTES);
  const previewChunks: Buffer[] = [];
  let previewBytes = 0;
  let newlineCount = 0;
  let position = 0;

  while (true) {
    const { bytesRead } = await handle.read(buffer, 0, buffer.length, position);
    if (bytesRead === 0) break;
    position += bytesRead;
    if (position > FILE_PEEK_TEXT_MAX_BYTES) {
      throw new FilePeekReadError(
        "file_too_large",
        "File is too large to preview. Maximum size is 8 MiB.",
      );
    }
    const chunk = buffer.subarray(0, bytesRead);
    let searchOffset = 0;
    while (searchOffset < chunk.length) {
      const newline = chunk.indexOf(0x0a, searchOffset);
      if (newline < 0) break;
      newlineCount += 1;
      searchOffset = newline + 1;
    }
    if (previewBytes < FILE_PEEK_PREVIEW_MAX_BYTES) {
      const selectedBytes = Math.min(
        bytesRead,
        FILE_PEEK_PREVIEW_MAX_BYTES - previewBytes,
      );
      // The read buffer is reused, so retain an owned copy of the bounded
      // preview prefix rather than a subarray view.
      previewChunks.push(Buffer.from(chunk.subarray(0, selectedBytes)));
      previewBytes += selectedBytes;
    }
  }

  const after = await handle.stat();
  if (
    !sameOpenFileStats(before, after) ||
    (expectedIdentity && !sameOpenFileStats(expectedIdentity, after))
  ) {
    throw new FilePeekReadError(
      "file_changed",
      "File changed while it was being read.",
    );
  }
  const previewText = Buffer.concat(previewChunks, previewBytes).toString(
    "utf8",
  );
  const lineLimit = Math.max(1, Math.floor(maxLines));
  const selectedLines: string[] = [];
  let lineStart = 0;
  let clippedLongLine = false;
  while (selectedLines.length < lineLimit) {
    const newline = previewText.indexOf("\n", lineStart);
    const lineEnd = newline < 0 ? previewText.length : newline;
    const line = previewText.slice(lineStart, lineEnd);
    if (line.length > FILE_PEEK_PREVIEW_MAX_LINE_CHARS) {
      clippedLongLine = true;
      selectedLines.push(line.slice(0, FILE_PEEK_PREVIEW_MAX_LINE_CHARS));
    } else {
      selectedLines.push(line);
    }
    if (newline < 0) break;
    lineStart = newline + 1;
    if (lineStart === previewText.length) {
      if (selectedLines.length < lineLimit) selectedLines.push("");
      break;
    }
  }
  const totalLines = newlineCount + 1;
  return {
    content: selectedLines.join("\n"),
    totalLines,
    truncated:
      position > previewBytes ||
      totalLines > selectedLines.length ||
      clippedLongLine,
  };
}

async function readStableBufferFromHandle(
  handle: FileHandle,
  maxBytes: number,
  tooLargeMessage: string,
  expectedIdentity?: {
    dev: number;
    ino: number;
    size: number;
    mtimeMs: number;
  },
): Promise<Buffer> {
  const before = await stableFileStats(
    handle,
    maxBytes,
    tooLargeMessage,
    expectedIdentity,
  );
  const chunks: Buffer[] = [];
  let position = 0;
  while (true) {
    const buffer = Buffer.allocUnsafe(
      Math.min(FILE_PEEK_READ_CHUNK_BYTES, maxBytes + 1 - position),
    );
    const { bytesRead } = await handle.read(buffer, 0, buffer.length, position);
    if (bytesRead === 0) break;
    position += bytesRead;
    if (position > maxBytes) {
      throw new FilePeekReadError("file_too_large", tooLargeMessage);
    }
    chunks.push(buffer.subarray(0, bytesRead));
  }
  const after = await handle.stat();
  if (
    !sameOpenFileStats(before, after) ||
    (expectedIdentity && !sameOpenFileStats(expectedIdentity, after))
  ) {
    throw new FilePeekReadError(
      "file_changed",
      "File changed while it was being read.",
    );
  }
  return Buffer.concat(chunks, position);
}

function filePeekLanguage(filename: string): string | undefined {
  const ext = extname(filename).replace(/^\./, "").toLowerCase();
  const languageMap: Record<string, string> = {
    ts: "typescript",
    tsx: "typescript",
    js: "javascript",
    jsx: "javascript",
    py: "python",
    rb: "ruby",
    rs: "rust",
    go: "go",
    java: "java",
    kt: "kotlin",
    swift: "swift",
    dart: "dart",
    c: "c",
    cpp: "cpp",
    h: "c",
    hpp: "cpp",
    cs: "csharp",
    sh: "bash",
    zsh: "bash",
    yml: "yaml",
    yaml: "yaml",
    json: "json",
    toml: "toml",
    md: "markdown",
    html: "html",
    css: "css",
    scss: "css",
    sql: "sql",
    xml: "xml",
    dockerfile: "dockerfile",
    makefile: "makefile",
    gradle: "groovy",
  };
  return languageMap[ext] ?? (ext || undefined);
}

// ---- Available model lists (delivered to clients via session_list) ----

const FALLBACK_CLAUDE_MODELS: string[] = [
  "claude-opus-4-7",
  "claude-opus-4-7[1m]",
  "claude-opus-4-6",
  "claude-opus-4-6[1m]",
  "claude-opus-4-5-20251101",
  "claude-sonnet-4-6",
  "claude-haiku-4-6",
];

const FALLBACK_CLAUDE_MODEL_EFFORTS: Record<string, ClaudeEffortLevel[]> = {
  "claude-opus-4-7": ["low", "medium", "high", "xhigh", "max"],
  "claude-opus-4-7[1m]": ["low", "medium", "high", "xhigh", "max"],
  "claude-opus-4-6": ["low", "medium", "high", "max"],
  "claude-opus-4-6[1m]": ["low", "medium", "high", "max"],
  "claude-opus-4-5-20251101": ["low", "medium", "high"],
  "claude-sonnet-4-6": ["low", "medium", "high", "max"],
  "claude-haiku-4-6": [],
};

const FALLBACK_CODEX_MODELS: string[] = [
  "gpt-5.6-sol",
  "gpt-5.6-terra",
  "gpt-5.6-luna",
  "gpt-5.5",
  "gpt-5.4",
  "gpt-5.4-mini",
  "gpt-5.3-codex",
  "gpt-5.3-codex-spark",
];

const FALLBACK_CODEX_REASONING_EFFORTS = ["low", "medium", "high", "xhigh"];
const FALLBACK_GPT_5_6_REASONING_EFFORTS = [
  ...FALLBACK_CODEX_REASONING_EFFORTS,
  "max",
];
const FALLBACK_GPT_5_6_ULTRA_REASONING_EFFORTS = [
  ...FALLBACK_GPT_5_6_REASONING_EFFORTS,
  "ultra",
];

function fallbackCodexReasoningEfforts(model: string): string[] {
  if (model === "gpt-5.6-sol" || model === "gpt-5.6-terra") {
    return FALLBACK_GPT_5_6_ULTRA_REASONING_EFFORTS;
  }
  if (model === "gpt-5.6-luna") return FALLBACK_GPT_5_6_REASONING_EFFORTS;
  return FALLBACK_CODEX_REASONING_EFFORTS;
}

function fallbackCodexServiceTiers(model: string): string[] {
  return [
    "gpt-5.6-sol",
    "gpt-5.6-terra",
    "gpt-5.6-luna",
    "gpt-5.5",
    "gpt-5.4",
  ].includes(model)
    ? ["fast"]
    : [];
}

const CODEX_RECENT_THREAD_SOURCE_KINDS: CodexThreadSourceKind[] = [
  "cli",
  "vscode",
  "exec",
  "appServer",
];
const CODEX_RECENT_THREAD_MIN_PAGE_SIZE = 20;
const CODEX_RECENT_THREAD_MAX_PAGE_SIZE = 100;
const CODEX_RECENT_THREAD_MAX_SCAN_PAGES = 25;
const CODEX_RECENT_THREAD_MAX_SCANNED_THREADS = 1_000;

const CODEX_USER_TURN_UUID_RE = /^codex:user-turn:(\d+)$/;

const OPT_IN_SERVER_MESSAGES = new Set<string>([
  "conversation_queue",
  "goal_state",
  "guardian_approval",
  INPUT_DELIVERY_STATUS_MESSAGE,
  "prompt_history_status",
  "artifact_resolved",
  PUSH_REGISTRATION_STATE_MESSAGE,
  CLIENT_DELIVERY_MODE_STATE_MESSAGE,
  BACKGROUND_NOTIFICATION_MESSAGE,
  BACKGROUND_ACTIVITY_STATE_MESSAGE,
  SESSION_CATALOG_CHANGED_MESSAGE,
  SESSION_LINK_PROGRESS_CAPABILITY,
]);

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function parseCodexUserTurnOrdinal(uuid: string | undefined): number | null {
  if (!uuid) return null;
  const match = uuid.match(CODEX_USER_TURN_UUID_RE);
  if (!match) return null;
  const ordinal = Number(match[1]);
  return Number.isInteger(ordinal) && ordinal > 0 ? ordinal : null;
}

function hasUnknownCodexGoalStatus(
  msg: ServerMessage | Record<string, unknown>,
): boolean {
  if (msg.type !== "goal_state") return false;
  const goal = msg.goal;
  if (goal == null || typeof goal !== "object") return false;
  const status = (goal as unknown as { status?: unknown }).status;
  return typeof status !== "string" || !KNOWN_CODEX_GOAL_STATUSES.has(status);
}

function countCodexUserTurnsInSession(session: SessionInfo): number {
  let count = 0;
  let maxOrdinal = 0;

  const observe = (uuid?: string): void => {
    count += 1;
    const ordinal = parseCodexUserTurnOrdinal(uuid);
    if (ordinal !== null) {
      maxOrdinal = Math.max(maxOrdinal, ordinal);
    }
  };

  if (Array.isArray(session.pastMessages)) {
    for (const message of session.pastMessages) {
      if (!message || typeof message !== "object") continue;
      const item = message as {
        role?: unknown;
        uuid?: unknown;
        isMeta?: unknown;
      };
      if (item.role === "user" && item.isMeta !== true) {
        observe(typeof item.uuid === "string" ? item.uuid : undefined);
      }
    }
  }

  for (const message of session.history) {
    if (message.type === "user_input") {
      observe(message.userMessageUuid);
    }
  }

  return Math.max(count, maxOrdinal);
}

function nextCodexUserTurnUuid(session: SessionInfo): string {
  return codexUserTurnUuid(countCodexUserTurnsInSession(session) + 1);
}

function normalizeHistoryContent(
  content: unknown,
): SessionHistoryMessage["content"] {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return [];

  const normalized: Array<{
    type: string;
    text?: string;
    id?: string;
    name?: string;
    input?: Record<string, unknown>;
  }> = [];

  for (const item of content) {
    if (!item || typeof item !== "object") continue;
    const value = item as Record<string, unknown>;
    if (typeof value.type !== "string") continue;
    if (value.type === "text") {
      normalized.push({
        type: "text",
        text: typeof value.text === "string" ? value.text : "",
      });
    } else if (value.type === "tool_use") {
      normalized.push({
        type: "tool_use",
        id: typeof value.id === "string" ? value.id : undefined,
        name: typeof value.name === "string" ? value.name : undefined,
        input:
          value.input &&
          typeof value.input === "object" &&
          !Array.isArray(value.input)
            ? (value.input as Record<string, unknown>)
            : undefined,
      });
    }
  }

  return normalized;
}

function buildCodexHistoryPrefix(
  session: SessionInfo,
  targetOrdinal: number,
): SessionHistoryMessage[] {
  const messages: SessionHistoryMessage[] = [];
  let userOrdinal = 0;
  let reachedEnd = false;

  const appendPastMessage = (message: unknown): void => {
    if (reachedEnd || !message || typeof message !== "object") return;
    const item = message as SessionHistoryMessage;
    if (item.role === "user" && item.isMeta !== true) {
      userOrdinal += 1;
      if (userOrdinal > targetOrdinal) {
        reachedEnd = true;
        return;
      }
      messages.push({ ...item });
      return;
    }
    if (
      item.role === "assistant" &&
      userOrdinal > 0 &&
      userOrdinal <= targetOrdinal
    ) {
      messages.push({ ...item });
    }
  };

  for (const message of session.pastMessages ?? []) {
    appendPastMessage(message);
    if (reachedEnd) return messages;
  }

  for (const message of session.history) {
    if (message.type === "user_input") {
      if (message.isMeta === true) continue;
      const userInput = message as typeof message & { timestamp?: string };
      userOrdinal += 1;
      if (userOrdinal > targetOrdinal) break;
      messages.push({
        role: "user",
        uuid: userInput.userMessageUuid,
        timestamp: userInput.timestamp,
        imageCount: userInput.imageCount,
        content: [{ type: "text", text: userInput.text }],
      });
    } else if (
      message.type === "assistant" &&
      userOrdinal > 0 &&
      userOrdinal <= targetOrdinal
    ) {
      messages.push({
        role: "assistant",
        uuid: message.messageUuid,
        content: normalizeHistoryContent(message.message.content),
      });
    }
  }

  return messages;
}

function countCodexHistoryUserTurns(messages: SessionHistoryMessage[]): number {
  return messages.filter(
    (message) => message.role === "user" && !message.isMeta,
  ).length;
}

// ---- Codex mode mapping helpers ----

/** Map unified PermissionMode to Codex approval_policy.
 *  Only "bypassPermissions" maps to "never"; all others use "on-request". */
function permissionModeToApprovalPolicy(mode?: string): "never" | "on-request" {
  return mode === "bypassPermissions" ? "never" : "on-request";
}

function normalizeCodexApprovalPolicy(
  value?: string,
): "never" | "on-request" | "on-failure" | "untrusted" {
  switch (value) {
    case "untrusted":
      return "untrusted";
    case "on-failure":
      return "on-failure";
    case "never":
      return "never";
    case "on-request":
    default:
      return "on-request";
  }
}

/** Normalizes a known policy but preserves "unknown" instead of fabricating
 * "on-request" — a fabricated value would be persisted and, on a permission
 * restart, sent as an explicit policy that overrides the user's config. */
function normalizeCodexApprovalPolicyIfKnown(
  value?: string,
): "never" | "on-request" | "on-failure" | "untrusted" | undefined {
  return value === undefined ? undefined : normalizeCodexApprovalPolicy(value);
}

type CodexPermissionsMode = NonNullable<
  CodexStartOptions["codexPermissionsMode"]
>;

interface CodexPermissionSettings {
  codexPermissionsMode?: CodexPermissionsMode;
  approvalPolicy?: CodexStartOptions["approvalPolicy"];
  approvalsReviewer?: CodexStartOptions["approvalsReviewer"];
  sandboxMode?: CodexStartOptions["sandboxMode"];
}

function isCodexAutoReviewApprovalsReviewer(value: unknown): boolean {
  return value === "auto_review" || value === "guardian_subagent";
}

function sanitizeCodexModel(model: unknown): string | undefined {
  if (typeof model !== "string") return undefined;
  const normalized = model.trim();
  if (!normalized || normalized === "codex") return undefined;
  return normalized;
}

function codexSettingsFromPermissionsMode(
  mode: CodexPermissionsMode,
): CodexPermissionSettings {
  switch (mode) {
    case "default":
      return {
        codexPermissionsMode: mode,
        approvalPolicy: "on-request",
        approvalsReviewer: "user",
        sandboxMode: "workspace-write",
      };
    case "autoReview":
      return {
        codexPermissionsMode: mode,
        approvalPolicy: "on-request",
        approvalsReviewer: "auto_review",
        sandboxMode: "workspace-write",
      };
    case "fullAccess":
      return {
        codexPermissionsMode: mode,
        approvalPolicy: "never",
        approvalsReviewer: "user",
        sandboxMode: "danger-full-access",
      };
    case "custom":
      return { codexPermissionsMode: mode };
  }
}

function errorMessageOf(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

function isUnsupportedCodexRpc(err: unknown): boolean {
  return (
    (err instanceof CodexRpcError && err.code === -32601) ||
    /method not found|unsupported method/i.test(errorMessageOf(err))
  );
}

type SessionLifecycleErrorCode =
  | "session_active"
  | "session_not_archived"
  | "archive_identity_mismatch"
  | "codex_source_mismatch"
  | "unsupported_capability"
  | "provider_rpc_failed"
  | "local_store_failed"
  | "partial_failure"
  | "path_not_allowed";

class SessionLifecycleError extends Error {
  constructor(
    readonly code: SessionLifecycleErrorCode,
    message: string,
  ) {
    super(message);
    this.name = "SessionLifecycleError";
  }
}

function isClaudeAutoModeUnavailableError(err: unknown): boolean {
  const message = errorMessageOf(err).toLowerCase();
  const autoMentionsMode =
    message.includes("auto mode") ||
    message.includes('permission mode "auto"') ||
    message.includes("permission mode auto") ||
    message.includes("mode auto");
  if (!autoMentionsMode) return false;
  return (
    message.includes("unavailable") ||
    message.includes("not available") ||
    message.includes("unsupported") ||
    message.includes("not supported") ||
    message.includes("disabled") ||
    message.includes("requires") ||
    message.includes("only available") ||
    message.includes("not enabled")
  );
}

function deriveExecutionMode(params: {
  permissionMode?: string;
  executionMode?: string;
  approvalPolicy?: string;
  provider?: Provider;
}): "default" | "acceptEdits" | "fullAccess" {
  if (
    params.executionMode === "default" ||
    params.executionMode === "acceptEdits" ||
    params.executionMode === "fullAccess"
  ) {
    return params.executionMode;
  }
  if (
    params.permissionMode === "bypassPermissions" ||
    params.approvalPolicy === "never"
  ) {
    return "fullAccess";
  }
  if (params.permissionMode === "acceptEdits") {
    return params.provider === "codex" ? "default" : "acceptEdits";
  }
  return "default";
}

function derivePlanMode(params: {
  permissionMode?: string;
  planMode?: boolean;
  collaborationMode?: "plan" | "default";
}): boolean {
  return (
    params.planMode ??
    (params.permissionMode === "plan" || params.collaborationMode === "plan")
  );
}

function modesToLegacyPermissionMode(
  provider: Provider,
  executionMode: "default" | "acceptEdits" | "fullAccess",
  planMode: boolean,
): "default" | "acceptEdits" | "bypassPermissions" | "plan" {
  if (planMode) return "plan";
  switch (executionMode) {
    case "fullAccess":
      return "bypassPermissions";
    case "acceptEdits":
      return "acceptEdits";
    case "default":
    default:
      return provider === "codex" ? "acceptEdits" : "default";
  }
}

/** Map simplified SandboxMode (on/off) to Codex internal sandbox mode. */
function sandboxModeToInternal(
  mode?: string,
): "read-only" | "workspace-write" | "danger-full-access" {
  switch (mode) {
    case "danger-full-access":
    case "workspace-write":
    case "read-only":
      return mode;
    case "off":
      return "danger-full-access";
    default:
      return "workspace-write";
  }
}

/** Map Codex internal sandbox mode back to simplified on/off for clients. */
function sandboxModeToExternal(mode?: string): "on" | "off" {
  return mode === "danger-full-access" ? "off" : "on";
}

function threadTimestampToIso(value: number): string {
  return value > 0 ? new Date(value * 1000).toISOString() : "";
}

function envFlagEnabled(name: string): boolean {
  const value = process.env[name]?.trim().toLowerCase();
  return value === "1" || value === "true" || value === "yes" || value === "on";
}

const MAX_TIMER_DELAY_MS = 2_147_483_647;

function positiveEnvInt(name: string, fallback: number): number {
  const raw = process.env[name]?.trim();
  if (!raw) return fallback;
  const value = Number(raw);
  return Number.isSafeInteger(value) && value > 0 ? value : fallback;
}

function nonNegativeEnvInt(name: string, fallback: number): number {
  const raw = process.env[name]?.trim();
  if (!raw) return fallback;
  const value = Number(raw);
  return Number.isSafeInteger(value) &&
    value >= 0 &&
    value <= MAX_TIMER_DELAY_MS
    ? value
    : fallback;
}

function normalizePositiveLimit(
  value: number | undefined,
  fallback: number,
): number {
  return value !== undefined && Number.isSafeInteger(value) && value > 0
    ? value
    : fallback;
}

function normalizeNonNegativeLimit(
  value: number | undefined,
  fallback: number,
): number {
  return value !== undefined &&
    Number.isSafeInteger(value) &&
    value >= 0 &&
    value <= MAX_TIMER_DELAY_MS
    ? value
    : fallback;
}

function codexThreadToRecentSession(
  thread: CodexThreadSummary,
  indexed?: CodexSessionIndexMetadata,
): Record<string, unknown> {
  const projectPath = normalizeWorktreePath(thread.cwd);
  const resumeCwd =
    indexed?.resumeCwd ?? (thread.cwd !== projectPath ? thread.cwd : undefined);
  // thread/list only exposes a single preview blob; prefer the real
  // first/last/summary texts parsed from the rollout file so display-mode
  // switches (first prompt / last prompt / summary) show distinct content.
  return {
    sessionId: thread.id,
    provider: "codex",
    ...((thread.forkedFromThreadId ?? indexed?.forkedFromThreadId)
      ? {
          forkedFromThreadId:
            thread.forkedFromThreadId ?? indexed?.forkedFromThreadId,
        }
      : {}),
    ...(thread.name ? { name: thread.name } : {}),
    ...(thread.agentNickname ? { agentNickname: thread.agentNickname } : {}),
    ...(thread.agentRole ? { agentRole: thread.agentRole } : {}),
    summary: indexed?.summary || thread.preview || undefined,
    firstPrompt: indexed?.firstPrompt || thread.preview || "",
    ...(indexed?.lastPrompt ? { lastPrompt: indexed.lastPrompt } : {}),
    created: threadTimestampToIso(thread.createdAt),
    modified: threadTimestampToIso(thread.updatedAt),
    gitBranch: thread.gitBranch ?? "",
    projectPath,
    ...(resumeCwd ? { resumeCwd } : {}),
    isSidechain: false,
    ...(indexed?.codexSettings ? { codexSettings: indexed.codexSettings } : {}),
  };
}

function canonicalRecentProjectPath(
  input: string,
  platform: NodeJS.Platform,
): string {
  const normalized = normalizeWorktreePath(
    resolvePlatformPath(input, platform),
  );
  return platform === "win32" ? normalized.toLowerCase() : normalized;
}

function recentSessionModifiedTime(session: unknown): number {
  const modified = (session as { modified?: unknown })?.modified;
  return typeof modified === "string" ? new Date(modified).getTime() || 0 : 0;
}

function recentSessionDedupeKey(
  session: unknown,
  fallbackIndex: number,
): string {
  const value = session as { provider?: unknown; sessionId?: unknown };
  return typeof value.provider === "string" &&
    typeof value.sessionId === "string"
    ? `${value.provider}:${value.sessionId}`
    : `unknown:${fallbackIndex}`;
}

function mergeRecentSessionPages(sessions: unknown[]): unknown[] {
  const seen = new Set<string>();
  const merged: unknown[] = [];
  for (const session of sessions) {
    const key = recentSessionDedupeKey(session, merged.length);
    if (seen.has(key)) continue;
    seen.add(key);
    merged.push(session);
  }
  return merged.sort(
    (a, b) => recentSessionModifiedTime(b) - recentSessionModifiedTime(a),
  );
}

export interface BridgeServerOptions {
  server: HttpServer;
  apiKey?: string;
  apiKeyAuthenticator?: BridgeApiKeyAuthenticator;
  allowedWebSocketOrigins?: string[];
  allowedDirs?: string[];
  imageStore?: ImageStore;
  galleryStore?: GalleryStore;
  projectHistory?: ProjectHistory;
  debugTraceStore?: DebugTraceStore;
  recordingStore?: RecordingStore;
  firebaseAuth?: FirebaseAuthClient;
  promptHistoryBackup?: PromptHistoryBackupStore;
  promptHistoryStore?: PromptHistoryStore;
  platform?: NodeJS.Platform;
  fileListMaxEntries?: number;
  fileListMaxBytes?: number;
  deltaBatchMs?: number;
  deltaBatchMaxChars?: number;
  artifactManager?: ArtifactManager;
  fileTransfer?: FileTransferManager;
  fileBrowser?: FileBrowserManager;
  fileMutationAuthorizer?: FileMutationAuthorizer;
  sessionCatalogMonitorFactory?: (
    onChanged: (revision: number, change?: SessionCatalogChange) => void,
  ) => SessionCatalogMonitorControl;
}

export interface SessionCatalogMonitorControl {
  readonly isActive: boolean;
  readonly currentRevision?: number;
  start(): Promise<void>;
  close(): void;
}

type DeltaServerMessage = Extract<
  ServerMessage,
  { type: "stream_delta" | "thinking_delta" }
>;

interface DeltaBatch {
  messages: DeltaServerMessage[];
  timer: NodeJS.Timeout;
  charCount: number;
}

interface DeltaTextChunk {
  text: string;
  charCount: number;
}

export class BridgeWebSocketServer {
  private static readonly MAX_DEBUG_EVENTS = 800;
  private static readonly MAX_HISTORY_SUMMARY_ITEMS = 300;
  private static readonly CONNECT_METADATA_REFRESH_COOLDOWN_MS = 5 * 60 * 1000;
  private static readonly DEFAULT_FILE_LIST_MAX_ENTRIES = 5000;
  private static readonly DEFAULT_FILE_LIST_MAX_BYTES = 512 * 1024;
  private static readonly DEFAULT_DELTA_BATCH_MS = 100;
  private static readonly DEFAULT_DELTA_BATCH_MAX_CHARS = 4096;

  private wss: WebSocketServer;
  private sessionManager: SessionManager;
  private readonly apiKeyAuthenticator: BridgeApiKeyAuthenticator;
  private allowedDirs: string[];
  private imageStore: ImageStore | null;
  private galleryStore: GalleryStore | null;
  private projectHistory: ProjectHistory | null;
  private debugTraceStore: DebugTraceStore;
  private recordingStore: RecordingStore | null;
  private worktreeStore: WorktreeStore;
  private pushRelay: PushRelayClient;
  private promptHistoryBackup: PromptHistoryBackupStore | null;
  private promptHistoryStore: PromptHistoryStore | null;
  private readonly bridgeInstanceId?: string;
  private readonly codexSourceId: string;
  private artifactManager: ArtifactManager | null;

  private recentSessionsRequestIds = new WeakMap<WebSocket, number>();
  private debugEvents = new Map<string, DebugTraceEvent[]>();
  private notifiedPermissionToolUses = new Map<string, Set<string>>();
  private progressNotificationState = new Map<
    string,
    { lastSentAt: number; lastToolKey: string }
  >();
  private archiveStore: ArchiveStore;
  private archiveStoreReady: Promise<void>;
  private archiveStoreInitializationError: Error | null = null;
  private codexLifecycleMutations = new Map<string, Promise<void>>();
  private codexProfiles: string[] = [];
  private defaultCodexProfile: string | undefined;
  private codexAutoReviewDisabled = false;
  private codexAutoReviewPolicyLoaded = false;
  private codexMetadataRequest: Promise<void> | null = null;
  private lastConnectMetadataRefreshAt: number | null = null;
  private claudeModels: string[] = FALLBACK_CLAUDE_MODELS;
  private claudeModelEfforts: Record<string, ClaudeEffortLevel[]> = {
    ...FALLBACK_CLAUDE_MODEL_EFFORTS,
  };
  private claudeModelsRequest: Promise<void> | null = null;
  private codexModels: string[] = FALLBACK_CODEX_MODELS;
  private codexModelReasoningEfforts: Record<string, string[]> =
    Object.fromEntries(
      FALLBACK_CODEX_MODELS.map((model) => [
        model,
        fallbackCodexReasoningEfforts(model),
      ]),
    );
  private codexModelServiceTiers: Record<string, string[]> = Object.fromEntries(
    FALLBACK_CODEX_MODELS.map((model) => [
      model,
      fallbackCodexServiceTiers(model),
    ]),
  );
  /** FCM token → push notification locale */
  private tokenLocales = new Map<string, PushLocale>();
  private tokenPrivacyMode = new Map<string, boolean>();
  private tokenEnabledEventTypes = new Map<string, Set<string>>();
  private pushTokenOperations = new Map<string, Promise<void>>();
  private failSetPermissionMode = envFlagEnabled(
    "BRIDGE_FAIL_SET_PERMISSION_MODE",
  );
  private failSetSandboxMode = envFlagEnabled("BRIDGE_FAIL_SET_SANDBOX_MODE");
  private readonly fileListMaxEntries: number;
  private readonly fileListMaxBytes: number;
  private readonly deltaBatchMs: number;
  private readonly deltaBatchMaxChars: number;
  private deltaBatches = new Map<WebSocket, Map<string, DeltaBatch>>();
  private platform: NodeJS.Platform;
  private clientSupportedServerMessages = new WeakMap<WebSocket, Set<string>>();
  private backgroundDeliveryClients = new WeakMap<
    WebSocket,
    BackgroundDeliveryClientState
  >();
  private clientPushTokens = new WeakMap<WebSocket, Set<string>>();
  private pendingBackgroundPushDeliveries = new Map<
    string,
    PendingBackgroundPushDelivery
  >();
  // Diagnostic-only: feature behavior remains gated by advertised capabilities.
  private clientMobileRuntime = new WeakMap<
    WebSocket,
    Extract<ClientMessage, { type: "client_capabilities" }>["mobileRuntime"]
  >();
  private activeArtifactSourceReads = new WeakSet<WebSocket>();
  private pendingClaudeResumeInputs = new WeakMap<
    WebSocket,
    Map<string, InputClientMessage[]>
  >();
  private restoringManagedGalleryPaths = new Set<string>();
  private readonly localFeatures: LocalFeaturesController;
  private readonly codexGoals: CodexGoalController;
  private readonly fileTransfer: FileTransferManager | null;
  private readonly fileBrowser: FileBrowserManager | null;
  private readonly fileMutationAuthorizer: FileMutationAuthorizer | null;
  private readonly sessionCatalogMonitor: SessionCatalogMonitorControl;
  private resumeOperations = new Map<string, ResumeOperation>();

  constructor(options: BridgeServerOptions) {
    const {
      server,
      apiKey,
      apiKeyAuthenticator,
      allowedWebSocketOrigins,
      allowedDirs,
      imageStore,
      galleryStore,
      projectHistory,
      debugTraceStore,
      recordingStore,
      firebaseAuth,
      promptHistoryBackup,
      promptHistoryStore,
      platform,
      fileListMaxEntries,
      fileListMaxBytes,
      deltaBatchMs,
      deltaBatchMaxChars,
      artifactManager,
      fileTransfer,
      fileBrowser,
      fileMutationAuthorizer,
      sessionCatalogMonitorFactory,
    } = options;
    this.apiKeyAuthenticator =
      apiKeyAuthenticator ?? new BridgeApiKeyAuthenticator(apiKey);
    const browserOrigins = configuredWebSocketOrigins(allowedWebSocketOrigins);
    this.allowedDirs = allowedDirs ?? [];
    this.imageStore = imageStore ?? null;
    this.galleryStore = galleryStore ?? null;
    this.projectHistory = projectHistory ?? null;
    this.debugTraceStore = debugTraceStore ?? new DebugTraceStore();
    this.recordingStore = recordingStore ?? null;
    this.worktreeStore = new WorktreeStore();
    this.pushRelay = new PushRelayClient({ firebaseAuth });
    this.promptHistoryBackup = promptHistoryBackup ?? null;
    this.promptHistoryStore = promptHistoryStore ?? null;
    // Durable mobile cache identity must never silently become process-local.
    // Production wires PromptHistoryStore; test/custom hosts without it keep
    // the optional mirror feature unavailable rather than orphaning copies on
    // every restart.
    this.bridgeInstanceId = promptHistoryStore?.bridgeInstanceId;
    this.codexSourceId = codexSourceIdentity();
    this.artifactManager = artifactManager ?? null;
    this.fileTransfer = fileTransfer ?? null;
    this.fileBrowser = fileBrowser ?? null;
    this.fileMutationAuthorizer = fileMutationAuthorizer ?? null;
    this.sessionCatalogMonitor = sessionCatalogMonitorFactory
      ? sessionCatalogMonitorFactory((revision, change) =>
          this.broadcastSessionCatalogChanged(revision, change),
        )
      : new SessionCatalogMonitor({
          onChanged: (revision, change) =>
            this.broadcastSessionCatalogChanged(revision, change),
        });
    this.platform = platform ?? process.platform;
    this.fileListMaxEntries = normalizePositiveLimit(
      fileListMaxEntries,
      positiveEnvInt(
        "BRIDGE_FILE_LIST_MAX_ENTRIES",
        BridgeWebSocketServer.DEFAULT_FILE_LIST_MAX_ENTRIES,
      ),
    );
    this.fileListMaxBytes = normalizePositiveLimit(
      fileListMaxBytes,
      positiveEnvInt(
        "BRIDGE_FILE_LIST_MAX_BYTES",
        BridgeWebSocketServer.DEFAULT_FILE_LIST_MAX_BYTES,
      ),
    );
    this.deltaBatchMs = normalizeNonNegativeLimit(
      deltaBatchMs,
      nonNegativeEnvInt(
        "BRIDGE_DELTA_BATCH_MS",
        BridgeWebSocketServer.DEFAULT_DELTA_BATCH_MS,
      ),
    );
    this.deltaBatchMaxChars = normalizePositiveLimit(
      deltaBatchMaxChars,
      positiveEnvInt(
        "BRIDGE_DELTA_BATCH_MAX_CHARS",
        BridgeWebSocketServer.DEFAULT_DELTA_BATCH_MAX_CHARS,
      ),
    );

    this.archiveStore = new ArchiveStore();
    this.archiveStoreReady = this.archiveStore.init().catch((err) => {
      console.error("[ws] Failed to initialize archive store:", err);
      this.archiveStoreInitializationError =
        err instanceof Error ? err : new Error(String(err));
    });
    void this.debugTraceStore.init().catch((err) => {
      console.error("[ws] Failed to initialize debug trace store:", err);
    });
    if (this.recordingStore) {
      void this.recordingStore.init().catch((err) => {
        console.error("[ws] Failed to initialize recording store:", err);
      });
    }
    if (!this.pushRelay.isConfigured) {
      console.log("[ws] Push relay disabled (Firebase auth not available)");
    } else {
      console.log("[ws] Push relay enabled (Firebase Anonymous Auth)");
    }

    // Browsers always attach an Origin header to WebSocket handshakes; native
    // app clients do not. A private address is a network location, not an
    // identity, so bind browser Origins to the actual WebSocket Host. Operators
    // can explicitly allow a different first-party web origin, and a valid API
    // key remains an independent authentication path.
    this.wss = new WebSocketServer({
      server,
      verifyClient: (
        info: { req: IncomingMessage },
        done: (res: boolean, code?: number, message?: string) => void,
      ) => {
        const origin = info.req.headers.origin;
        const authenticatedByToken =
          this.apiKeyAuthenticator.isConfigured &&
          this.apiKeyAuthenticator.acceptsWebSocketRequest(info.req);
        if (
          origin !== undefined &&
          !authenticatedByToken &&
          !isAllowedBrowserOrigin(origin, info.req.headers.host, browserOrigins)
        ) {
          console.log("[ws] Client rejected: untrusted browser Origin");
          done(false, 403, "Forbidden");
          return;
        }
        done(true);
      },
    });

    this.sessionManager = new SessionManager(
      (sessionId, msg) => {
        this.broadcastSessionMessage(sessionId, msg);
      },
      imageStore,
      galleryStore,
      // Broadcast gallery_new_image when a new image is added
      (meta) => {
        if (this.galleryStore) {
          const info = this.galleryStore.metaToInfo(meta);
          this.broadcast({ type: "gallery_new_image", image: info });
        }
      },
      this.worktreeStore,
      () => {
        this.broadcastSessionList();
        this.broadcastEphemeralSideChatRegistry();
      },
      artifactManager,
      {
        canDrain: (session) =>
          this.localFeatures.admitCodexQueuedInputDrain(session),
        onBlocked: (session) =>
          this.localFeatures.codexQueuedInputDrainBlocked(session),
      },
    );
    this.codexGoals = new CodexGoalController({
      getSession: (sessionId) => this.sessionManager.get(sessionId),
      onCapabilityChanged: () => this.broadcastSessionList(),
    });
    this.localFeatures = createLocalFeaturesController({
      bridgeInstanceId: this.bridgeInstanceId,
      codexSourceId: this.codexSourceId,
      fileBrowser: this.fileBrowser ?? undefined,
      getSession: (sessionId) => this.sessionManager.get(sessionId),
      getCodexThreadId: (session) =>
        this.codexThreadIdForSession(session as SessionInfo),
      getProviderSessionId: (rawSession) =>
        this.providerSessionIdForSession(rawSession as SessionInfo),
      listRuntimeConversationStates: () =>
        this.sessionManager.list().map((summary) => {
          const session = this.sessionManager.get(summary.id);
          const toolName = summary.pendingPermission?.toolName.toLowerCase();
          const attentionKind =
            toolName == null
              ? undefined
              : toolName.includes("askuser") ||
                  toolName.includes("question") ||
                  toolName.includes("request_user_input")
                ? "question"
                : toolName.includes("form") || toolName.includes("elicitation")
                  ? "form"
                  : toolName.includes("approval") ||
                      toolName.includes("exitplan")
                    ? "approval"
                    : "permission";
          return {
            bridgeSessionId: summary.id,
            provider: summary.provider,
            ...(session
              ? {
                  providerSessionId: this.providerSessionIdForSession(session),
                }
              : {}),
            projectPath: summary.projectPath,
            processStatus: summary.status,
            ...(summary.pendingPermission && attentionKind
              ? {
                  pendingAttention: {
                    requestId: summary.pendingPermission.toolUseId,
                    kind: attentionKind,
                  },
                }
              : {}),
            observedAt: summary.lastActivityAt,
          };
        }),
      getClientDeliveryMode: (client) =>
        this.backgroundDeliveryClients.get(client as WebSocket)?.mode ===
        "notifications_only"
          ? "notifications_only"
          : "interactive",
      getActiveCodexProcess: () => this.getActiveCodexProcess(),
      createStandaloneCodexProcess: (requestTimeoutMs, projectPath) =>
        this.createStandaloneCodexProcess(
          projectPath
            ? resolvePlatformPath(projectPath, this.platform)
            : undefined,
          requestTimeoutMs,
        ),
      createDedicatedCodexProcess: () => new CodexProcess(this.platform),
      createPersistedCodexChildSession: (parentSessionId, childOptions) =>
        this.createPersistedCodexChildSession(parentSessionId, childOptions),
      createEphemeralCodexChildSession: (parentSessionId, childOptions) =>
        this.createEphemeralCodexChildSession(parentSessionId, childOptions),
      listEphemeralCodexChildSessions: () =>
        this.listEphemeralCodexChildSessions(),
      closeEphemeralCodexChildSession: (childSessionId) =>
        this.closeEphemeralCodexChildSession(childSessionId),
      isProjectPathAllowed: (projectPath) =>
        this.isExistingProjectPathAllowed(
          resolvePlatformPath(projectPath, this.platform),
        ),
      isSessionProjectPath: (rawSession, projectPath) => {
        const session = rawSession as SessionInfo;
        const claimed = canonicalRecentProjectPath(projectPath, this.platform);
        return [session.projectPath, session.worktreePath]
          .filter((path): path is string => Boolean(path))
          .some(
            (path) =>
              canonicalRecentProjectPath(path, this.platform) === claimed,
          );
      },
      isCodexThreadLocallyActive: (threadId) =>
        this.sessionManager.list().some(({ id }) => {
          const session = this.sessionManager.get(id);
          if (
            !session ||
            session.provider !== "codex" ||
            this.codexThreadIdForSession(session) !== threadId ||
            !(session.process instanceof CodexProcess)
          ) {
            return false;
          }
          return (
            session.process.status === "running" ||
            session.process.status === "waiting_approval" ||
            session.process.status === "compacting"
          );
        }),
      getLocallyActiveCodexTurnId: (threadId) => {
        const turnIds = new Set<string>();
        for (const { id } of this.sessionManager.list()) {
          const session = this.sessionManager.get(id);
          if (
            !session ||
            session.provider !== "codex" ||
            this.codexThreadIdForSession(session) !== threadId ||
            !(session.process instanceof CodexProcess)
          ) {
            continue;
          }
          const turnId = session.process.activeTurnId;
          if (turnId) turnIds.add(turnId);
        }
        return turnIds.size === 1 ? turnIds.values().next().value : undefined;
      },
      rehydrateCodexSessionAfterExternalTurn: (
        sessionId,
        threadId,
        isStillSafe,
      ) =>
        this.rehydrateCodexSessionAfterExternalTurn(
          sessionId,
          threadId,
          isStillSafe,
        ),
      hasCodexQueuedInput: (sessionId) =>
        this.sessionManager.get(sessionId)?.codexQueuedInput != null,
      registerInlineImages: (images) => {
        if (!this.imageStore) return [];
        const refs: ImageRef[] = [];
        for (const image of images) {
          if (
            typeof image.data !== "string" ||
            typeof image.mimeType !== "string" ||
            !image.mimeType.startsWith("image/")
          ) {
            continue;
          }
          const ref = this.imageStore.registerFromBase64(
            image.data,
            image.mimeType,
          );
          if (ref) refs.push(ref);
        }
        return refs;
      },
      drainCodexQueuedInputIfReady: (sessionId, isStillSafe) =>
        this.sessionManager.drainCodexQueuedInputIfReady(
          sessionId,
          isStillSafe,
        ),
      send: (client, message) =>
        this.send(client as WebSocket, message as ServerMessage),
      isClientOpen: (client) =>
        (client as WebSocket).readyState === WebSocket.OPEN,
      supports: (client, messageType) =>
        this.clientSupportedServerMessages
          .get(client as WebSocket)
          ?.has(messageType) ?? false,
    });

    this.wss.on("connection", (ws, req) => {
      // API key authentication
      if (!this.apiKeyAuthenticator.acceptsWebSocketRequest(req)) {
        console.log("[ws] Client rejected: invalid token");
        ws.close(4001, "Unauthorized");
        return;
      }
      const releaseAuthenticatedPeer =
        this.apiKeyAuthenticator.trackAuthenticatedWebSocketPeer(req);
      ws.once("close", releaseAuthenticatedPeer);

      console.log("[ws] Client connected");
      this.handleConnection(ws, req);
    });

    this.wss.on("error", (err) => {
      console.error("[ws] Server error:", err.message);
    });

    console.log(`[ws] WebSocket server attached to HTTP server`);
  }

  /**
   * Validate that a project path is within the allowed directories.
   * Returns true if the path is allowed, false otherwise.
   */
  private isPathAllowed(path: string): boolean {
    if (this.allowedDirs.length === 0) return true;
    return this.allowedDirs.some((dir) =>
      isPathWithinAllowedDirectory(path, dir, this.platform),
    );
  }

  /**
   * Authorize an existing project by its real location, not merely the path
   * spelling supplied by a client. File-create/upload paths intentionally keep
   * using the lexical check because their final target may not exist yet.
   */
  private isExistingProjectPathAllowed(path: string): boolean {
    if (!this.isPathAllowed(path)) return false;
    if (this.allowedDirs.length === 0) return true;
    // Tests can emulate another host's path rules. Only the native host can
    // resolve that platform's filesystem identity; the real Bridge always
    // uses its own process platform.
    if (this.platform !== process.platform) return true;
    try {
      const canonicalPath = realpathSync(path);
      return this.allowedDirs.some((directory) => {
        try {
          return isPathWithinAllowedDirectory(
            canonicalPath,
            realpathSync(directory),
            this.platform,
          );
        } catch {
          return false;
        }
      });
    } catch {
      return false;
    }
  }

  /** Resolve configured roots before authorizing a file reached by symlink. */
  private async isCanonicalPathAllowed(
    canonicalPath: string,
  ): Promise<boolean> {
    if (this.allowedDirs.length === 0) return true;
    for (const directory of this.allowedDirs) {
      try {
        const canonicalDirectory = await realpath(directory);
        if (
          isPathWithinAllowedDirectory(
            canonicalPath,
            canonicalDirectory,
            this.platform,
          )
        ) {
          return true;
        }
      } catch {
        // A missing configured root grants no file-read authority.
      }
    }
    return false;
  }

  /** Build a user-friendly error for disallowed project paths. */
  private buildPathNotAllowedError(
    projectPath: string,
  ): Extract<ServerMessage, { type: "error" }> {
    return {
      type: "error",
      message: `⚠ Project path not allowed\n\n"${projectPath}" is not in the allowed directories.\n\nFix: Update BRIDGE_ALLOWED_DIRS on the Bridge server to include this path.`,
      errorCode: "path_not_allowed",
    };
  }

  /**
   * Git operations have dedicated terminal result frames. Returning a generic
   * error for a denied path leaves old Mobile clients waiting forever because
   * their busy state is cleared only by the matching result stream.
   */
  private sendGitPathNotAllowed(
    ws: WebSocket,
    requestType:
      | "get_diff"
      | "git_stage"
      | "git_unstage"
      | "git_unstage_hunks"
      | "git_commit"
      | "git_push"
      | "git_branches"
      | "git_create_branch"
      | "git_checkout_branch"
      | "git_revert_file"
      | "git_revert_hunks"
      | "git_fetch"
      | "git_pull"
      | "git_remote_status",
    projectPath: string,
    requestId?: string,
  ): void {
    const error = this.buildPathNotAllowedError(projectPath).message;
    const result = (() => {
      switch (requestType) {
        case "get_diff":
          return {
            type: "diff_result",
            diff: "",
            error,
            errorCode: "path_not_allowed",
            ...(requestId ? { requestId } : {}),
          };
        case "git_stage":
          return {
            type: "git_stage_result",
            success: false,
            projectPath,
            error,
          };
        case "git_unstage":
          return {
            type: "git_unstage_result",
            success: false,
            projectPath,
            error,
          };
        case "git_unstage_hunks":
          return {
            type: "git_unstage_hunks_result",
            success: false,
            projectPath,
            error,
          };
        case "git_commit":
          return {
            type: "git_commit_result",
            success: false,
            projectPath,
            error,
          };
        case "git_push":
          return {
            type: "git_push_result",
            success: false,
            projectPath,
            error,
          };
        case "git_branches":
          return {
            type: "git_branches_result",
            current: "",
            branches: [],
            projectPath,
            error,
          };
        case "git_create_branch":
          return {
            type: "git_create_branch_result",
            success: false,
            projectPath,
            error,
          };
        case "git_checkout_branch":
          return {
            type: "git_checkout_branch_result",
            success: false,
            projectPath,
            error,
          };
        case "git_revert_file":
          return {
            type: "git_revert_file_result",
            success: false,
            projectPath,
            error,
          };
        case "git_revert_hunks":
          return {
            type: "git_revert_hunks_result",
            success: false,
            projectPath,
            error,
          };
        case "git_fetch":
          return {
            type: "git_fetch_result",
            success: false,
            projectPath,
            error,
          };
        case "git_pull":
          return {
            type: "git_pull_result",
            success: false,
            projectPath,
            error,
          };
        case "git_remote_status":
          return {
            type: "git_remote_status_result",
            ahead: 0,
            behind: 0,
            branch: "",
            hasUpstream: false,
            projectPath,
            error,
            errorCode: "path_not_allowed",
          };
      }
    })();
    this.send(ws, result);
  }

  private normalizeAdditionalWritableRoots(
    roots: string[] | undefined,
    projectPath: string,
  ): { roots?: string[]; deniedRoot?: string } {
    if (!roots || roots.length === 0) return {};
    const normalized = new Map<string, string>();
    for (const root of roots) {
      const trimmed = root.trim();
      if (!trimmed) continue;
      const resolved = resolvePlatformPathFrom(
        projectPath,
        trimmed,
        this.platform,
      );
      if (!this.isExistingProjectPathAllowed(resolved)) {
        return { deniedRoot: root };
      }
      const key = this.platform === "win32" ? resolved.toLowerCase() : resolved;
      if (!normalized.has(key)) {
        normalized.set(key, resolved);
      }
    }
    return { roots: [...normalized.values()] };
  }

  private buildSessionCreatedMessage(params: {
    sessionId: string;
    provider: Provider;
    projectPath: string;
    session?: SessionInfo;
    permissionMode?: string;
    executionMode?: string;
    planMode?: boolean;
    approvalsReviewer?: string;
    codexPermissionsMode?: string;
    sandboxMode?: string;
    slashCommands?: string[];
    skills?: string[];
    skillMetadata?: Array<Record<string, unknown>>;
    apps?: string[];
    appMetadata?: Array<Record<string, unknown>>;
    plugins?: string[];
    pluginMetadata?: Array<Record<string, unknown>>;
    /** Durable provider id already known by an explicit resume request. */
    providerSessionId?: string;
    sourceSessionId?: string;
    startRequestId?: string;
    resumeRequestId?: string;
  }): SystemServerMessage {
    const {
      sessionId,
      provider,
      projectPath,
      session,
      permissionMode,
      executionMode,
      planMode,
      approvalsReviewer,
      codexPermissionsMode,
      sandboxMode,
      slashCommands,
      skills,
      skillMetadata,
      apps,
      appMetadata,
      plugins,
      pluginMetadata,
      providerSessionId,
      sourceSessionId,
      startRequestId,
      resumeRequestId,
    } = params;
    const derivedCodexSettings =
      provider === "codex"
        ? withDerivedCodexPermissionsMode(session?.codexSettings)
        : session?.codexSettings;
    const inferredExecutionMode =
      provider === "codex" && derivedCodexSettings?.approvalPolicy !== undefined
        ? derivedCodexSettings.approvalPolicy === "never"
          ? "fullAccess"
          : "default"
        : session?.process instanceof SdkProcess
          ? session.process.permissionMode === "bypassPermissions"
            ? "fullAccess"
            : session.process.permissionMode === "acceptEdits"
              ? "acceptEdits"
              : "default"
          : undefined;
    const resolvedExecutionMode = executionMode ?? inferredExecutionMode;

    const msg: SystemServerMessage = {
      type: "system",
      subtype: "session_created",
      sessionId,
      provider,
      projectPath,
      ...(permissionMode
        ? {
            permissionMode: permissionMode as
              "default" | "auto" | "acceptEdits" | "bypassPermissions" | "plan",
          }
        : {}),
      ...((approvalsReviewer ?? derivedCodexSettings?.approvalsReviewer)
        ? {
            approvalsReviewer:
              approvalsReviewer ?? derivedCodexSettings?.approvalsReviewer,
          }
        : {}),
      ...((codexPermissionsMode ?? derivedCodexSettings?.codexPermissionsMode)
        ? {
            codexPermissionsMode: (codexPermissionsMode ??
              derivedCodexSettings?.codexPermissionsMode) as
              "default" | "autoReview" | "fullAccess" | "custom",
          }
        : {}),
      ...(resolvedExecutionMode
        ? {
            executionMode: resolvedExecutionMode as
              "default" | "acceptEdits" | "fullAccess",
          }
        : {}),
      ...((planMode ??
        (session?.process instanceof SdkProcess
          ? session.process.permissionMode === "plan"
          : session?.process instanceof CodexProcess
            ? session.process.collaborationMode === "plan"
            : undefined)) != null
        ? {
            planMode:
              planMode ??
              (session?.process instanceof SdkProcess
                ? session.process.permissionMode === "plan"
                : session?.process instanceof CodexProcess
                  ? session.process.collaborationMode === "plan"
                  : false),
          }
        : {}),
      ...(sandboxMode ? { sandboxMode } : {}),
      ...(slashCommands ? { slashCommands } : {}),
      ...(skills ? { skills } : {}),
      ...(skillMetadata
        ? {
            skillMetadata:
              skillMetadata as SystemServerMessage["skillMetadata"],
          }
        : {}),
      ...(apps ? { apps } : {}),
      ...(appMetadata
        ? {
            appMetadata: appMetadata as SystemServerMessage["appMetadata"],
          }
        : {}),
      ...(plugins ? { plugins } : {}),
      ...(pluginMetadata
        ? {
            pluginMetadata:
              pluginMetadata as SystemServerMessage["pluginMetadata"],
          }
        : {}),
      ...(session?.worktreePath
        ? {
            worktreePath: session.worktreePath,
            worktreeBranch: session.worktreeBranch,
          }
        : {}),
      // This legacy field is already understood by every client. On a resume
      // it carries the provider's durable identity (Codex thread id or Claude
      // session id), avoiding a new top-level protocol field. Fresh sessions
      // keep the previous shape because the provider id is not known yet.
      ...((providerSessionId ?? session?.claudeSessionId)
        ? { claudeSessionId: providerSessionId ?? session?.claudeSessionId }
        : {}),
      ...(sourceSessionId ? { sourceSessionId } : {}),
      ...(session?.forkedFromSessionId
        ? { forkedFromSessionId: session.forkedFromSessionId }
        : {}),
      ...(session?.forkedFromThreadId
        ? { forkedFromThreadId: session.forkedFromThreadId }
        : {}),
      ...(startRequestId ? { startRequestId } : {}),
      ...(resumeRequestId ? { resumeRequestId } : {}),
    };

    if (provider === "codex" && derivedCodexSettings) {
      if (derivedCodexSettings.model !== undefined) {
        msg.model = derivedCodexSettings.model;
      }
      if (derivedCodexSettings.approvalPolicy !== undefined) {
        msg.approvalPolicy = derivedCodexSettings.approvalPolicy;
      }
      if (derivedCodexSettings.codexPermissionsMode !== undefined) {
        msg.codexPermissionsMode = derivedCodexSettings.codexPermissionsMode as
          "default" | "autoReview" | "fullAccess" | "custom";
      }
      if (derivedCodexSettings.modelReasoningEffort !== undefined) {
        msg.modelReasoningEffort = derivedCodexSettings.modelReasoningEffort;
      }
      if (derivedCodexSettings.serviceTier !== undefined) {
        msg.serviceTier = derivedCodexSettings.serviceTier;
      }
      if (derivedCodexSettings.networkAccessEnabled !== undefined) {
        msg.networkAccessEnabled = derivedCodexSettings.networkAccessEnabled;
      }
      if (derivedCodexSettings.webSearchMode !== undefined) {
        msg.webSearchMode = derivedCodexSettings.webSearchMode;
      }
      if (derivedCodexSettings.additionalWritableRoots !== undefined) {
        msg.additionalWritableRoots =
          derivedCodexSettings.additionalWritableRoots;
      }
    }

    return msg;
  }

  private async rewindCodexConversation(
    ws: WebSocket,
    sessionId: string,
    targetUuid: string,
    mode: "conversation" | "code" | "both",
  ): Promise<void> {
    if (mode !== "conversation") {
      this.send(ws, {
        type: "rewind_result",
        success: false,
        mode,
        error: "Codex only supports conversation rewind",
      });
      return;
    }

    const session = this.sessionManager.get(sessionId);
    if (!session) {
      this.send(ws, {
        type: "rewind_result",
        success: false,
        mode,
        error: `Session ${sessionId} not found`,
      });
      return;
    }
    const codexProcess = session.process as CodexProcess;
    if (
      session.provider !== "codex" ||
      typeof codexProcess.rollbackThread !== "function"
    ) {
      this.send(ws, {
        type: "rewind_result",
        success: false,
        mode,
        error: "Session is not a Codex session",
      });
      return;
    }
    if (
      session.status !== "idle" ||
      (codexProcess.status ?? session.status) !== "idle"
    ) {
      this.send(ws, {
        type: "rewind_result",
        success: false,
        mode,
        error: "Cannot rewind while Codex is running",
      });
      return;
    }
    if (session.codexQueuedInput) {
      this.send(ws, {
        type: "rewind_result",
        success: false,
        mode,
        error: "Cannot rewind while Codex has queued input",
      });
      return;
    }

    const targetOrdinal = parseCodexUserTurnOrdinal(targetUuid);
    const totalUserTurns = countCodexUserTurnsInSession(session);
    if (targetOrdinal === null || targetOrdinal > totalUserTurns) {
      this.send(ws, {
        type: "rewind_result",
        success: false,
        mode,
        error: "Invalid Codex rewind target",
      });
      return;
    }

    const numTurns = totalUserTurns - targetOrdinal + 1;
    if (numTurns <= 0) {
      this.send(ws, {
        type: "rewind_result",
        success: false,
        mode,
        error: "Invalid Codex rewind target",
      });
      return;
    }

    const threadId = codexProcess.sessionId ?? session.claudeSessionId;
    if (!threadId) {
      this.send(ws, {
        type: "rewind_result",
        success: false,
        mode,
        error: "No Codex thread ID available for rewind",
      });
      return;
    }

    const projectPath = session.projectPath;
    const codexSettings = session.codexSettings;
    const worktreeOpts: WorktreeOptions | undefined = session.worktreePath
      ? {
          existingWorktreePath: session.worktreePath,
          worktreeBranch: session.worktreeBranch,
        }
      : undefined;

    const rolledBackThread = await codexProcess.rollbackThread(numTurns);

    const pastMessages = this.codexHistoryFromThreadOrFallback({
      thread: rolledBackThread,
      expectedUserTurns: targetOrdinal - 1,
      fallback: buildCodexHistoryPrefix(session, targetOrdinal - 1),
    });
    this.destroySession(sessionId);
    const newSessionId = this.sessionManager.create(
      projectPath,
      undefined,
      pastMessages,
      worktreeOpts,
      "codex",
      this.withCodexAutoReviewPolicy({
        ...(codexSettings ?? {}),
        threadId,
      } as CodexStartOptions),
    );
    const newSession = this.sessionManager.get(newSessionId);

    this.send(ws, {
      type: "rewind_result",
      success: true,
      mode,
    });
    this.send(
      ws,
      this.buildSessionCreatedMessage({
        sessionId: newSessionId,
        provider: "codex",
        projectPath,
        session: newSession,
        approvalsReviewer: newSession?.codexSettings?.approvalsReviewer,
        sandboxMode: newSession?.codexSettings?.sandboxMode,
        sourceSessionId: sessionId,
      }),
    );
    this.sendSessionList(ws);
  }

  private async forkCodexSession(
    ws: WebSocket,
    sessionId: string,
    targetUuid: string,
    persistedProjectPath?: string,
    codexSourceId?: string,
  ): Promise<void> {
    this.assertCodexSourceMatches("codex", codexSourceId);
    const requestedPersistedFork = persistedProjectPath !== undefined;
    const session =
      this.sessionManager.get(sessionId) ??
      (requestedPersistedFork
        ? this.findRunningCodexSession(sessionId)
        : undefined);
    if (!session && requestedPersistedFork) {
      await this.forkPersistedCodexSession(ws, sessionId, persistedProjectPath);
      return;
    }
    if (!session) {
      this.send(ws, {
        type: "error",
        message: `Session ${sessionId} not found`,
        errorCode: "fork_failed",
      });
      return;
    }
    const codexProcess = session.process as CodexProcess;
    if (
      session.provider !== "codex" ||
      typeof codexProcess.forkThread !== "function"
    ) {
      this.send(ws, {
        type: "error",
        message: "Fork is only supported for Codex sessions",
        errorCode: "fork_failed",
      });
      return;
    }
    if (
      session.status !== "idle" ||
      (codexProcess.status ?? session.status) !== "idle"
    ) {
      this.send(ws, {
        type: "error",
        message: "Cannot fork while Codex is running",
        errorCode: "fork_failed",
      });
      return;
    }
    if (session.codexQueuedInput) {
      this.send(ws, {
        type: "error",
        message: "Cannot fork while Codex has queued input",
        errorCode: "fork_failed",
      });
      return;
    }

    const totalUserTurns = countCodexUserTurnsInSession(session);
    const targetOrdinal =
      targetUuid === "codex:user-turn:latest"
        ? totalUserTurns
        : parseCodexUserTurnOrdinal(targetUuid);
    if (targetOrdinal === null || targetOrdinal > totalUserTurns) {
      this.send(ws, {
        type: "error",
        message: "Invalid Codex fork target",
        errorCode: "fork_failed",
      });
      return;
    }

    const projectPath = session.projectPath;
    const codexSettings = session.codexSettings;
    const worktreeOpts: WorktreeOptions | undefined = session.worktreePath
      ? {
          existingWorktreePath: session.worktreePath,
          worktreeBranch: session.worktreeBranch,
        }
      : undefined;

    const forked = await codexProcess.forkThread();
    const forkedThreadId = forked.threadId;
    const turnsToDrop = totalUserTurns - targetOrdinal;
    let forkedThread: unknown = forked.thread;
    if (turnsToDrop > 0) {
      forkedThread = await codexProcess.rollbackThreadById(
        forkedThreadId,
        turnsToDrop,
      );
    }

    const pastMessages = this.codexHistoryFromThreadOrFallback({
      thread: forkedThread,
      expectedUserTurns: targetOrdinal,
      fallback: buildCodexHistoryPrefix(session, targetOrdinal),
    });
    const newSessionId = this.sessionManager.create(
      projectPath,
      undefined,
      pastMessages,
      worktreeOpts,
      "codex",
      this.withCodexAutoReviewPolicy({
        ...(codexSettings ?? {}),
        threadId: forkedThreadId,
      } as CodexStartOptions),
    );
    const newSession = this.sessionManager.get(newSessionId);
    if (newSession) {
      newSession.forkedFromSessionId = session.id;
      newSession.forkedFromThreadId =
        session.claudeSessionId ?? codexProcess.sessionId ?? undefined;
    }

    this.send(
      ws,
      this.buildSessionCreatedMessage({
        sessionId: newSessionId,
        provider: "codex",
        projectPath,
        session: newSession,
        approvalsReviewer: newSession?.codexSettings?.approvalsReviewer,
        sandboxMode: newSession?.codexSettings?.sandboxMode,
        sourceSessionId: requestedPersistedFork ? undefined : session.id,
      }),
    );
    this.sendSessionList(ws);
  }

  /**
   * Fork a durable Codex thread that is not currently owned by SessionManager.
   * The child is registered as an ordinary Bridge session and uses the normal
   * CodexSessionScreen/history pipeline; no side-chat runtime is introduced.
   */
  private async forkPersistedCodexSession(
    ws: WebSocket,
    threadId: string,
    rawProjectPath: string,
  ): Promise<void> {
    let releaseThreadOperation: (() => void) | undefined;
    try {
      releaseThreadOperation = await this.acquireCodexThreadOperation(threadId);
      const runningSession = this.findRunningCodexSession(threadId);
      if (runningSession) {
        await this.forkCodexSession(
          ws,
          runningSession.id,
          "codex:user-turn:latest",
          rawProjectPath,
        );
        return;
      }

      await this.requireArchiveStoreReady();
      if (this.archiveStore.isArchived(threadId, "codex", this.codexSourceId)) {
        throw new Error(
          "The Codex thread is archived. Restore it before forking.",
        );
      }

      const requestedProjectPath = resolvePlatformPath(
        rawProjectPath,
        this.platform,
      );
      const worktreeMapping = this.worktreeStore.get(threadId);
      const projectPath = resolvePlatformPath(
        worktreeMapping?.projectPath ?? requestedProjectPath,
        this.platform,
      );
      if (!this.isExistingProjectPathAllowed(projectPath)) {
        this.send(ws, this.buildPathNotAllowedError(rawProjectPath));
        return;
      }

      let worktreeOpts: WorktreeOptions | undefined;
      if (worktreeMapping) {
        worktreeOpts = worktreeExists(worktreeMapping.worktreePath)
          ? {
              existingWorktreePath: worktreeMapping.worktreePath,
              worktreeBranch: worktreeMapping.worktreeBranch,
            }
          : {
              useWorktree: true,
              worktreeBranch: worktreeMapping.worktreeBranch,
            };
      }

      const pastMessages = await this.getCodexThreadHistory(
        threadId,
        projectPath,
      );
      const newSessionId = this.sessionManager.create(
        projectPath,
        undefined,
        pastMessages,
        worktreeOpts,
        "codex",
        { forkFromThreadId: threadId },
      );
      const newSession = this.sessionManager.get(newSessionId);
      if (newSession) {
        newSession.forkedFromThreadId = threadId;
      }
      this.send(
        ws,
        this.buildSessionCreatedMessage({
          sessionId: newSessionId,
          provider: "codex",
          projectPath,
          session: newSession,
        }),
      );
      this.sendSessionList(ws);
      this.projectHistory?.addProject(projectPath);
    } finally {
      releaseThreadOperation?.();
    }
  }

  private async createPersistedCodexChildSession(
    parentSessionId: string,
    childOptions: { threadSource: string; excludeTurnsOnOpen: boolean },
  ): Promise<{
    sessionId: string;
    projectPath: string;
    worktreePath?: string;
    worktreeBranch?: string;
    permissionMode?: string;
    sandboxMode?: string;
    approvalPolicy?: string;
    approvalsReviewer?: string;
  }> {
    const parent = this.sessionManager.get(parentSessionId);
    if (
      !parent ||
      parent.provider !== "codex" ||
      !(parent.process instanceof CodexProcess)
    ) {
      throw new Error("The parent Codex session is no longer active");
    }
    const parentThreadId = this.codexThreadIdForSession(parent);
    if (!parentThreadId) {
      throw new Error("The parent Codex thread is not ready yet");
    }

    const settings = parent.codexSettings ?? {};
    const process = parent.process;
    const worktreeOptions: WorktreeOptions | undefined = parent.worktreePath
      ? {
          existingWorktreePath: parent.worktreePath,
          worktreeBranch: parent.worktreeBranch,
        }
      : undefined;
    const sessionId = this.sessionManager.create(
      parent.projectPath,
      undefined,
      [],
      worktreeOptions,
      "codex",
      {
        forkFromThreadId: parentThreadId,
        excludeTurnsOnOpen: childOptions.excludeTurnsOnOpen,
        threadSource: childOptions.threadSource,
        profile: settings.profile,
        approvalPolicy:
          settings.approvalPolicy as CodexStartOptions["approvalPolicy"],
        approvalsReviewer:
          settings.approvalsReviewer as CodexStartOptions["approvalsReviewer"],
        codexPermissionsMode:
          settings.codexPermissionsMode as CodexStartOptions["codexPermissionsMode"],
        sandboxMode: settings.sandboxMode as CodexStartOptions["sandboxMode"],
        model: settings.model ?? process.knownModel,
        modelReasoningEffort:
          settings.modelReasoningEffort ?? process.modelReasoningEffort,
        serviceTier: settings.serviceTier ?? process.knownServiceTier,
        networkAccessEnabled: settings.networkAccessEnabled,
        webSearchMode:
          settings.webSearchMode as CodexStartOptions["webSearchMode"],
        additionalWritableRoots: settings.additionalWritableRoots,
        collaborationMode: process.collaborationMode,
      },
    );
    const child = this.sessionManager.get(sessionId);
    if (!child) throw new Error("The durable side chat was not registered");
    this.broadcastSessionList();
    return {
      sessionId,
      projectPath: child.projectPath,
      ...(child.worktreePath ? { worktreePath: child.worktreePath } : {}),
      ...(child.worktreeBranch ? { worktreeBranch: child.worktreeBranch } : {}),
      permissionMode:
        settings.approvalPolicy === "never"
          ? "bypassPermissions"
          : "acceptEdits",
      ...(settings.sandboxMode ? { sandboxMode: settings.sandboxMode } : {}),
      ...(settings.approvalPolicy
        ? { approvalPolicy: settings.approvalPolicy }
        : {}),
      ...(settings.approvalsReviewer
        ? { approvalsReviewer: settings.approvalsReviewer }
        : {}),
    };
  }

  private async createEphemeralCodexChildSession(
    parentSessionId: string,
    childOptions: {
      threadSource: string;
      excludeTurnsOnOpen: boolean;
      parentProviderSessionId?: string;
    },
  ): Promise<{
    childSessionId: string;
    parentSessionId: string;
    parentProviderSessionId?: string;
    projectPath: string;
    worktreePath?: string;
    worktreeBranch?: string;
    permissionMode?: string;
    sandboxMode?: string;
    approvalPolicy?: string;
    approvalsReviewer?: string;
    status: string;
    createdAt: string;
    lastActivityAt: string;
  }> {
    const parent = this.sessionManager.get(parentSessionId);
    if (
      parent &&
      (parent.provider !== "codex" ||
        parent.auxiliary ||
        !(parent.process instanceof CodexProcess))
    ) {
      throw new Error("The parent session is not a durable Codex thread");
    }
    const runtimeParentThreadId = parent
      ? this.codexThreadIdForSession(parent)
      : undefined;
    if (
      runtimeParentThreadId &&
      childOptions.parentProviderSessionId &&
      runtimeParentThreadId !== childOptions.parentProviderSessionId
    ) {
      throw new Error(
        "The parent runtime does not match the requested Codex thread",
      );
    }
    const parentThreadId =
      runtimeParentThreadId ?? childOptions.parentProviderSessionId;
    if (!parentThreadId) {
      throw new Error(
        "The parent Codex runtime is detached and no provider thread was supplied",
      );
    }

    const indexedMetadata = parent
      ? undefined
      : (
          await getCodexSessionIndexMetadata([parentThreadId], {
            authoritativeCodexSettings: true,
          })
        ).get(parentThreadId);
    if (!parent && !indexedMetadata) {
      throw new Error("The durable Codex parent thread was not found");
    }
    const rawProjectPath = parent?.projectPath ?? indexedMetadata?.resumeCwd;
    if (!rawProjectPath) {
      throw new Error("The durable Codex parent has no project directory");
    }
    const projectPath = resolvePlatformPath(rawProjectPath, this.platform);
    if (!this.isExistingProjectPathAllowed(projectPath)) {
      throw new Error(
        "The durable Codex parent project is outside Bridge access",
      );
    }
    const allChildren = this.sessionManager.listEphemeralSideChats();
    if (allChildren.length >= 8) {
      throw new Error("Bridge has reached the ephemeral side chat limit");
    }
    if (
      allChildren.filter(
        (child) =>
          child.auxiliary?.parentProviderSessionId === parentThreadId ||
          child.auxiliary?.parentSessionId === parentSessionId,
      ).length >= 4
    ) {
      throw new Error("This conversation has reached the side chat limit");
    }

    const settings =
      parent?.codexSettings ?? indexedMetadata?.codexSettings ?? {};
    const codexPermissionsMode = parent?.codexSettings?.codexPermissionsMode;
    const additionalWritableRoots = this.normalizeAdditionalWritableRoots(
      settings.additionalWritableRoots,
      projectPath,
    );
    if (additionalWritableRoots.deniedRoot) {
      throw new Error(
        "The durable Codex parent has a writable root outside Bridge access",
      );
    }
    const process = parent?.process;
    const worktreeOptions: WorktreeOptions | undefined = parent?.worktreePath
      ? {
          existingWorktreePath: parent.worktreePath,
          worktreeBranch: parent.worktreeBranch,
        }
      : undefined;
    const childSessionId = this.sessionManager.create(
      projectPath,
      undefined,
      [],
      worktreeOptions,
      "codex",
      {
        ephemeralForkFromThreadId: parentThreadId,
        excludeTurnsOnOpen: childOptions.excludeTurnsOnOpen,
        threadSource: childOptions.threadSource,
        profile: settings.profile,
        approvalPolicy:
          settings.approvalPolicy as CodexStartOptions["approvalPolicy"],
        approvalsReviewer:
          settings.approvalsReviewer as CodexStartOptions["approvalsReviewer"],
        codexPermissionsMode:
          codexPermissionsMode as CodexStartOptions["codexPermissionsMode"],
        sandboxMode: settings.sandboxMode as CodexStartOptions["sandboxMode"],
        model:
          settings.model ??
          (process instanceof CodexProcess ? process.knownModel : undefined),
        modelReasoningEffort:
          settings.modelReasoningEffort ??
          (process instanceof CodexProcess
            ? process.modelReasoningEffort
            : undefined),
        serviceTier:
          settings.serviceTier ??
          (process instanceof CodexProcess
            ? process.knownServiceTier
            : undefined),
        networkAccessEnabled: settings.networkAccessEnabled,
        webSearchMode:
          settings.webSearchMode as CodexStartOptions["webSearchMode"],
        additionalWritableRoots: additionalWritableRoots.roots,
        collaborationMode: "default",
      },
      {
        auxiliary: {
          kind: "ephemeral_side_chat",
          parentSessionId,
          parentProviderSessionId: parentThreadId,
        },
      },
    );
    const child = this.sessionManager.get(childSessionId);
    if (!child) {
      throw new Error("The ephemeral side chat was not registered");
    }
    this.broadcastEphemeralSideChatRegistry();
    return this.ephemeralSideChatDescriptor(child);
  }

  private listEphemeralCodexChildSessions() {
    return this.sessionManager
      .listEphemeralSideChats()
      .map((session) => this.ephemeralSideChatDescriptor(session));
  }

  private closeEphemeralCodexChildSession(childSessionId: string): boolean {
    const child = this.sessionManager.get(childSessionId);
    if (child?.auxiliary?.kind !== "ephemeral_side_chat") return false;
    this.flushSessionDeltaBatches(childSessionId);
    const closed = this.sessionManager.destroy(childSessionId);
    if (closed) this.broadcastEphemeralSideChatRegistry();
    return closed;
  }

  private ephemeralSideChatDescriptor(session: SessionInfo) {
    const parentSessionId = session.auxiliary?.parentSessionId;
    if (!parentSessionId) {
      throw new Error("Session is not an ephemeral side chat");
    }
    const settings = session.codexSettings ?? {};
    return {
      childSessionId: session.id,
      parentSessionId,
      ...(session.auxiliary?.parentProviderSessionId
        ? {
            parentProviderSessionId: session.auxiliary.parentProviderSessionId,
          }
        : {}),
      projectPath: session.projectPath,
      ...(session.worktreePath ? { worktreePath: session.worktreePath } : {}),
      ...(session.worktreeBranch
        ? { worktreeBranch: session.worktreeBranch }
        : {}),
      permissionMode:
        settings.approvalPolicy === "never"
          ? "bypassPermissions"
          : "acceptEdits",
      ...(settings.sandboxMode ? { sandboxMode: settings.sandboxMode } : {}),
      ...(settings.approvalPolicy
        ? { approvalPolicy: settings.approvalPolicy }
        : {}),
      ...(settings.approvalsReviewer
        ? { approvalsReviewer: settings.approvalsReviewer }
        : {}),
      status: session.status,
      createdAt: session.createdAt.toISOString(),
      lastActivityAt: session.lastActivityAt.toISOString(),
    };
  }

  private broadcastEphemeralSideChatRegistry(): void {
    this.broadcast({
      type: "ephemeral_side_chat_registry",
      entries: this.listEphemeralCodexChildSessions(),
    });
  }

  private sendTip(
    ws: WebSocket,
    sessionId: string,
    tipCode: string,
    session?: SessionInfo,
  ): void {
    const tipMsg = {
      type: "system",
      subtype: "tip",
      tipCode,
      sessionId,
    } as ServerMessage;
    if (session) {
      this.sessionManager.appendHistory(session.id, tipMsg);
    }
    this.send(ws, tipMsg);
  }

  private async splitPastHistoryMessages(
    session: SessionInfo,
  ): Promise<{ pastMessages: unknown[]; historyMessages: ServerMessage[] }> {
    const messages = session.pastMessages ?? [];
    const pastMessages: unknown[] = [];
    const historyMessages: ServerMessage[] = [];

    for (const raw of messages) {
      const msg = raw as Record<string, unknown>;
      if (msg.role === "user") {
        const images = await this.registerPastUserMessageImages(session, msg);
        pastMessages.push(
          images.length > 0
            ? {
                ...msg,
                images,
                imageCount:
                  typeof msg.imageCount === "number"
                    ? Math.max(msg.imageCount, images.length)
                    : images.length,
              }
            : raw,
        );
        continue;
      }

      if (msg.role !== "tool_result") {
        pastMessages.push(raw);
        continue;
      }

      const content = typeof msg.content === "string" ? msg.content : "";
      const images = await this.registerPastToolResultImages(session, msg);

      pastMessages.push({
        role: "tool_result",
        toolUseId:
          typeof msg.toolUseId === "string"
            ? msg.toolUseId
            : `past-tool-result-${pastMessages.length}`,
        content,
        ...(typeof msg.toolName === "string" ? { toolName: msg.toolName } : {}),
        ...(images.length > 0 ? { images } : {}),
      });
    }

    return { pastMessages, historyMessages };
  }

  private providerSessionIdForSession(
    session: SessionInfo,
  ): string | undefined {
    return session.claudeSessionId ?? session.process.sessionId ?? undefined;
  }

  private findRunningCodexSession(threadId: string): SessionInfo | undefined {
    for (const summary of this.sessionManager.list()) {
      if (summary.provider !== "codex") continue;
      const session = this.sessionManager.get(summary.id);
      if ((session?.process as { isRunning?: boolean })?.isRunning !== true) {
        continue;
      }
      if (session && this.providerSessionIdForSession(session) === threadId) {
        return session;
      }
    }
    return undefined;
  }

  private buildCodexResumeResult(
    session: SessionInfo,
    threadId: string,
    resumeRequestId?: string,
  ): SystemServerMessage {
    const process = session.process as CodexProcess;
    const approvalPolicy = session.codexSettings?.approvalPolicy;
    const executionMode =
      approvalPolicy === undefined
        ? undefined
        : deriveExecutionMode({
            provider: "codex",
            approvalPolicy,
          });
    const planMode = process.collaborationMode === "plan";
    const cached = this.sessionManager.getCachedCommands(
      "codex",
      session.worktreePath ?? session.projectPath,
    );
    return this.buildSessionCreatedMessage({
      sessionId: session.id,
      provider: "codex",
      projectPath: session.projectPath,
      session,
      sandboxMode: session.codexSettings?.sandboxMode
        ? sandboxModeToExternal(session.codexSettings.sandboxMode)
        : undefined,
      permissionMode: planMode
        ? "plan"
        : executionMode === undefined
          ? undefined
          : modesToLegacyPermissionMode("codex", executionMode, false),
      executionMode,
      planMode,
      approvalsReviewer: session.codexSettings?.approvalsReviewer,
      codexPermissionsMode: session.codexSettings?.codexPermissionsMode,
      providerSessionId: threadId,
      resumeRequestId,
      ...(cached
        ? {
            slashCommands: cached.slashCommands,
            skills: cached.skills,
            ...(cached.skillMetadata
              ? { skillMetadata: cached.skillMetadata }
              : {}),
            apps: cached.apps,
            ...(cached.appMetadata ? { appMetadata: cached.appMetadata } : {}),
            plugins: cached.plugins,
            ...(cached.pluginMetadata
              ? { pluginMetadata: cached.pluginMetadata }
              : {}),
          }
        : {}),
    });
  }

  private codexThreadIdForSession(session: SessionInfo): string | undefined {
    return session.provider === "codex"
      ? (session.process.sessionId ?? session.claudeSessionId ?? undefined)
      : undefined;
  }

  private async codexCanonicalHistoryEntries(
    session: SessionInfo,
  ): Promise<HistoryEntry[] | null> {
    if (session.auxiliary?.kind === "ephemeral_side_chat") {
      // Official ephemeral threads are live-only and reject thread/read when
      // the includeTurns parameter is present. Their complete available
      // history is already captured from the live app-server stream.
      session.codexInitialHistoryPending = false;
      session.codexCanonicalHistoryRevision ??= 0;
      session.codexHistoryResetRevision ??= 0;
      return session.historyEntries.map((entry) => ({
        seq: entry.seq,
        message: entry.message,
      }));
    }

    const threadId = this.codexThreadIdForSession(session);
    if (!threadId) return null;

    const history = session.codexInitialHistoryPending
      ? ((session.pastMessages ?? []) as SessionHistoryMessage[])
      : await this.getCodexThreadHistoryFromRpc(
          threadId,
          session.projectPath,
          session.process as CodexProcess,
        );
    session.claudeSessionId = threadId;

    const messages = await this.codexHistoryToServerMessages(session, history);
    const entries = messages.map((message, index) => ({
      seq: index + 1,
      message,
    }));
    this.applyCodexCanonicalHistoryBaseline(session, history, entries);
    session.codexInitialHistoryPending = false;
    return entries;
  }

  private applyCodexCanonicalHistoryBaseline(
    session: SessionInfo,
    history: SessionHistoryMessage[],
    canonicalEntries: HistoryEntry[],
  ): void {
    const orderedRevision = session.codexOrderedHistoryRevision ?? 0;
    const liveEntries: HistoryEntry[] = [
      ...(session.codexOrderedHistoryEntries ?? []),
      ...session.historyEntries.filter((entry) => entry.seq > orderedRevision),
    ].map((entry) => ({
      seq: entry.seq,
      message: entry.message,
    }));
    const latestUserInput = session.codexLatestUserInput;
    const latestUserKeys = latestUserInput
      ? this.codexHistoryMessageIdentityKeys(latestUserInput)
      : [];
    if (
      latestUserInput &&
      !liveEntries.some(
        (entry) =>
          entry.message === latestUserInput ||
          (entry.message.type === "user_input" &&
            this.codexHistoryMessageIdentityKeys(entry.message).some((key) =>
              latestUserKeys.includes(key),
            )),
      )
    ) {
      const historySeq = (latestUserInput as Record<string, unknown>)
        .historySeq;
      liveEntries.unshift({
        seq: typeof historySeq === "number" ? historySeq : 0,
        message: latestUserInput,
      });
    }
    const canonicalUserUuids = new Set<string>();
    for (const entry of canonicalEntries) {
      const message = entry.message;
      if (message.type === "user_input" && message.userMessageUuid) {
        canonicalUserUuids.add(message.userMessageUuid);
      }
    }

    this.seedCodexCanonicalUserTurnUuidMap(session, history);

    const merged: Array<{ message: ServerMessage; retained: boolean }> = [];
    let canonicalCursor = 0;
    let hasCanonicalAnchor = false;
    let canMatchAssistantContent = false;
    const appendCanonicalUntil = (endExclusive: number): void => {
      while (canonicalCursor < endExclusive) {
        const message = canonicalEntries[canonicalCursor].message;
        merged.push({ message, retained: false });
        canonicalCursor += 1;
        hasCanonicalAnchor = true;
        if (message.type === "user_input") {
          canMatchAssistantContent = true;
        }
      }
    };

    for (let liveIndex = 0; liveIndex < liveEntries.length; liveIndex++) {
      const liveEntry = liveEntries[liveIndex];
      const matchIndex = this.findCodexCanonicalMatchIndex(
        canonicalEntries,
        liveEntry.message,
        canonicalCursor,
        canMatchAssistantContent,
      );
      if (matchIndex === -1) {
        let nextMatchIndex = -1;
        for (
          let nextLiveIndex = liveIndex + 1;
          nextLiveIndex < liveEntries.length;
          nextLiveIndex++
        ) {
          nextMatchIndex = this.findCodexCanonicalMatchIndex(
            canonicalEntries,
            liveEntries[nextLiveIndex].message,
            canonicalCursor,
            canMatchAssistantContent,
          );
          if (nextMatchIndex !== -1) break;
        }
        if (nextMatchIndex !== -1) {
          appendCanonicalUntil(nextMatchIndex);
        } else if (!hasCanonicalAnchor) {
          appendCanonicalUntil(canonicalEntries.length);
        }
        if (this.shouldRetainCodexLiveHistoryMessage(liveEntry.message)) {
          merged.push({ message: liveEntry.message, retained: true });
        }
        continue;
      }

      const receivedAt = liveEntry.message.receivedAt;
      if (receivedAt) {
        canonicalEntries[matchIndex].message.receivedAt ??= receivedAt;
      }
      appendCanonicalUntil(matchIndex + 1);
    }
    appendCanonicalUntil(canonicalEntries.length);

    const retainedMessages: ServerMessage[] = [];
    const retainedEntries: HistoryEntry[] = [];
    let canonicalRevision = 0;
    const previousRevision = session.historyRevision;
    const requiresNewBaselineRevision = previousRevision > 0;
    const targetRevision = requiresNewBaselineRevision
      ? Math.max(merged.length, previousRevision + 1)
      : merged.length;
    const sequenceOffset = targetRevision - merged.length;
    const mergedEntries = merged.map(({ message, retained }, index) => {
      const seq = sequenceOffset + index + 1;
      if (retained) {
        (message as Record<string, unknown>).historySeq = seq;
        retainedMessages.push(message);
        retainedEntries.push({ seq, message });
      } else {
        canonicalRevision = seq;
      }
      return { seq, message };
    });
    canonicalEntries.splice(0, canonicalEntries.length, ...mergedEntries);

    session.codexOrderedHistoryEntries =
      this.buildCodexOrderedHistoryWindow(mergedEntries);
    session.codexOrderedHistoryRevision = targetRevision;

    session.pastMessages = history;
    session.history = retainedMessages;
    session.historyEntries = retainedEntries;
    session.historyRevision = targetRevision;
    session.codexCanonicalHistoryRevision = canonicalRevision;
    session.codexHistoryResetRevision = targetRevision;
    session.historyLowWatermark =
      retainedEntries[0]?.seq ?? session.historyRevision + 1;

    if (session.pendingCodexUserEchoUuids) {
      for (const uuid of canonicalUserUuids) {
        session.pendingCodexUserEchoUuids.delete(uuid);
      }
      for (const uuid of [...session.pendingCodexUserEchoUuids]) {
        const stillLive = retainedMessages.some(
          (message) =>
            message.type === "user_input" && message.userMessageUuid === uuid,
        );
        if (!stillLive) session.pendingCodexUserEchoUuids.delete(uuid);
      }
    }
  }

  private buildCodexOrderedHistoryWindow(
    entries: HistoryEntry[],
  ): HistoryEntry[] {
    if (entries.length <= MAX_HISTORY_PER_SESSION) {
      return entries.map((entry) => ({
        seq: entry.seq,
        message: entry.message,
      }));
    }

    const tail = entries.slice(-MAX_HISTORY_PER_SESSION);
    if (tail.some((entry) => entry.message.type === "user_input")) {
      return tail;
    }

    let latestUser: HistoryEntry | undefined;
    for (let index = entries.length - 1; index >= 0; index--) {
      if (entries[index].message.type === "user_input") {
        latestUser = entries[index];
        break;
      }
    }
    return latestUser
      ? [latestUser, ...entries.slice(-(MAX_HISTORY_PER_SESSION - 1))]
      : tail;
  }

  private findCodexCanonicalMatchIndex(
    canonicalEntries: HistoryEntry[],
    liveMessage: ServerMessage,
    start: number,
    allowAssistantContentMatch: boolean,
  ): number {
    const liveKeys = this.codexHistoryMessageIdentityKeys(liveMessage);
    if (liveKeys.length > 0) {
      for (let index = start; index < canonicalEntries.length; index++) {
        const canonicalKeys = this.codexHistoryMessageIdentityKeys(
          canonicalEntries[index].message,
        );
        if (liveKeys.some((key) => canonicalKeys.includes(key))) return index;
      }
    }

    if (!allowAssistantContentMatch || liveMessage.type !== "assistant") {
      return -1;
    }
    const liveContent = this.historyValueKey(liveMessage.message.content);
    for (let index = start; index < canonicalEntries.length; index++) {
      const canonicalMessage = canonicalEntries[index].message;
      if (canonicalMessage.type === "user_input") break;
      if (
        canonicalMessage.type === "assistant" &&
        this.historyValueKey(canonicalMessage.message.content) === liveContent
      ) {
        return index;
      }
    }
    return -1;
  }

  private seedCodexCanonicalUserTurnUuidMap(
    session: SessionInfo,
    history: SessionHistoryMessage[],
  ): void {
    if (session.provider !== "codex") return;
    for (const message of history) {
      if (message.role !== "user" || !message.rawItemId || !message.uuid) {
        continue;
      }
      session.codexUserTurnUuidByRawId ??= new Map<string, string>();
      session.codexUserTurnUuidByRawId.set(message.rawItemId, message.uuid);
    }
  }

  private shouldRetainCodexLiveHistoryMessage(message: ServerMessage): boolean {
    return !(
      message.type === "system" &&
      (message as Record<string, unknown>).subtype === "tip"
    );
  }

  private codexHistoryMessageIdentityKeys(message: ServerMessage): string[] {
    if (message.type === "user_input") {
      return message.userMessageUuid ? [`user:${message.userMessageUuid}`] : [];
    }
    if (message.type === "assistant") {
      const assistantId = message.messageUuid ?? message.message.id;
      if (assistantId) return [`assistant:${assistantId}`];
      return [
        `assistant-content:${this.historyValueKey(message.message.content)}`,
      ];
    }
    if (message.type === "tool_result") {
      if (message.toolUseId) {
        return [`tool-result:${message.toolUseId}:${message.toolName ?? ""}`];
      }
      return [
        `tool-result-content:${message.toolName ?? ""}:${message.content}`,
      ];
    }
    return [];
  }

  private historyValueKey(value: unknown): string {
    try {
      return JSON.stringify(value);
    } catch {
      return String(value);
    }
  }

  private sendCodexCurrentSettings(
    ws: WebSocket,
    sessionId: string,
    session: SessionInfo,
  ): void {
    const process =
      session.process instanceof CodexProcess ? session.process : undefined;
    const settings = session.codexSettings;
    const model = settings?.model ?? process?.knownModel;
    const effort =
      settings?.modelReasoningEffort ?? process?.modelReasoningEffort;
    const serviceTier = settings?.serviceTier ?? process?.knownServiceTier;
    this.send(ws, {
      type: "system",
      subtype: "codex_settings",
      sessionId,
      provider: "codex",
      ...(model ? { model } : {}),
      ...(effort ? { modelReasoningEffort: effort } : {}),
      ...(serviceTier ? { serviceTier } : {}),
    });
  }

  private async sendCodexCanonicalHistorySnapshot(
    ws: WebSocket,
    sessionId: string,
    session: SessionInfo,
    options: { includeCachedCommands?: boolean } = {},
  ): Promise<boolean> {
    try {
      const entries = await this.codexCanonicalHistoryEntries(session);
      if (!entries) return false;
      const visibleEntries = this.historyWindowForClient(ws, entries);
      const historyWindow = this.historyWindowMetadataForClient(
        ws,
        entries,
        visibleEntries,
      );
      this.send(ws, {
        type: "history_snapshot",
        sessionId,
        fromSeq: visibleEntries[0]?.seq ?? session.historyRevision + 1,
        toSeq: session.historyRevision,
        messages: visibleEntries,
        status: session.status,
        reason: "reset",
        ...(historyWindow ? { historyWindow } : {}),
      } satisfies Extract<ServerMessage, { type: "history_snapshot" }>);
      this.sendCodexCurrentSettings(ws, sessionId, session);
      this.sendCodexQueueState(ws, sessionId, session);
      this.sendCodexGoalState(ws, sessionId, session);
      if (options.includeCachedCommands) {
        this.sendCachedCommands(ws, sessionId, session);
      }
      return true;
    } catch (err) {
      this.send(ws, {
        type: "error",
        message: `Failed to read Codex thread history: ${
          err instanceof Error ? err.message : String(err)
        }`,
      });
      return true;
    }
  }

  private async sendCodexCanonicalLegacyHistory(
    ws: WebSocket,
    sessionId: string,
    session: SessionInfo,
  ): Promise<boolean> {
    try {
      const entries = await this.codexCanonicalHistoryEntries(session);
      if (!entries) return false;
      const visibleEntries = this.historyWindowForClient(ws, entries);
      const historyWindow = this.historyWindowMetadataForClient(
        ws,
        entries,
        visibleEntries,
      );
      this.send(ws, {
        type: "history",
        messages: visibleEntries.map((entry) => entry.message),
        sessionId,
        ...(historyWindow ? { historyWindow } : {}),
      } as Record<string, unknown>);
      this.sendCodexCurrentSettings(ws, sessionId, session);
      const activityAt = this.sessionActivityAtForClient(ws, sessionId);
      this.send(ws, {
        type: "status",
        status: session.status,
        sessionId,
        ...(activityAt ? { activityAt } : {}),
      } as Record<string, unknown>);
      this.sendCodexQueueState(ws, sessionId, session);
      this.sendCodexGoalState(ws, sessionId, session);
      this.sendCachedCommands(ws, sessionId, session);
      return true;
    } catch (err) {
      this.send(ws, {
        type: "error",
        message: `Failed to read Codex thread history: ${
          err instanceof Error ? err.message : String(err)
        }`,
      });
      return true;
    }
  }

  private historyWindowForClient(
    ws: WebSocket,
    values: HistoryEntry[],
  ): HistoryEntry[] {
    const capabilities = this.clientSupportedServerMessages.get(ws);
    if (capabilities?.has(TURN_AWARE_HISTORY_WINDOW_CAPABILITY)) {
      return selectTurnAwareHistoryWindow(values);
    }
    if (
      values.length <= BOUNDED_HISTORY_WINDOW_ENTRIES ||
      !capabilities?.has(BOUNDED_HISTORY_WINDOW_CAPABILITY)
    ) {
      return values;
    }
    return values.slice(-BOUNDED_HISTORY_WINDOW_ENTRIES);
  }

  private historyWindowMetadataForClient(
    ws: WebSocket,
    values: HistoryEntry[],
    visibleValues: HistoryEntry[],
  ):
    | {
        capability: typeof TURN_AWARE_HISTORY_WINDOW_CAPABILITY;
        fromSeq: number;
        hasMore: boolean;
        cursor?: string;
      }
    | undefined {
    if (
      !this.clientSupportedServerMessages
        .get(ws)
        ?.has(TURN_AWARE_HISTORY_WINDOW_CAPABILITY)
    ) {
      return undefined;
    }
    const fromSeq =
      visibleValues[0]?.seq ?? values.at(-1)?.seq ?? Number.MAX_SAFE_INTEGER;
    const firstVisibleIndex =
      visibleValues[0] === undefined ? -1 : values.indexOf(visibleValues[0]);
    return {
      capability: TURN_AWARE_HISTORY_WINDOW_CAPABILITY,
      fromSeq,
      hasMore: firstVisibleIndex > 0,
      ...(visibleValues[0]
        ? { cursor: this.historyPageCursor(visibleValues[0]) }
        : {}),
    };
  }

  private historyPageCursor(entry: HistoryEntry): string {
    return `v1:${entry.seq}:${this.historyPageIdentityDigest(entry)}`;
  }

  private historyPageIdentityDigest(entry: HistoryEntry): string {
    const identity =
      this.codexHistoryMessageIdentityKeys(entry.message)[0] ??
      `seq:${entry.seq}`;
    return createHash("sha256").update(identity).digest("hex").slice(0, 24);
  }

  private historyPageCursorIndex(
    entries: HistoryEntry[],
    cursor: string,
  ): number {
    const parsed = /^v1:(\d+):([a-f0-9]{24})$/.exec(cursor);
    if (parsed) {
      const seq = Number(parsed[1]);
      const digest = parsed[2];
      const likelyIndex = entries.findIndex((entry) => entry.seq === seq);
      if (
        likelyIndex >= 0 &&
        this.historyPageIdentityDigest(entries[likelyIndex]) === digest
      ) {
        return likelyIndex;
      }
      let nearestIndex = -1;
      let nearestDistance = Number.MAX_SAFE_INTEGER;
      for (let index = 0; index < entries.length; index++) {
        const entry = entries[index];
        if (this.historyPageIdentityDigest(entry) !== digest) continue;
        const distance = Math.abs(entry.seq - seq);
        if (distance < nearestDistance) {
          nearestIndex = index;
          nearestDistance = distance;
        }
      }
      if (nearestIndex >= 0) return nearestIndex;
    }
    return entries.findIndex(
      (entry) =>
        this.codexHistoryMessageIdentityKeys(entry.message)[0] === cursor,
    );
  }

  private historyToolDetails(
    entries: HistoryEntry[],
    toolUseIds: string[],
  ): HistoryToolDetailPayload[] {
    const requested = new Set(toolUseIds);
    const details = new Map<string, HistoryToolDetailPayload>();
    for (const entry of entries) {
      const message = entry.message;
      if (message.type === "assistant") {
        for (const content of message.message.content) {
          if (content.type !== "tool_use" || !requested.has(content.id)) {
            continue;
          }
          const existing = details.get(content.id);
          details.set(content.id, {
            toolUseId: content.id,
            toolName: content.name,
            input: boundedHistoryToolDetailInput(content.input),
            ...(existing?.result ? { result: existing.result } : {}),
          });
        }
        continue;
      }
      if (message.type !== "tool_result" || !requested.has(message.toolUseId)) {
        continue;
      }
      const existing = details.get(message.toolUseId);
      details.set(message.toolUseId, {
        toolUseId: message.toolUseId,
        toolName:
          existing?.toolName ??
          (message.toolName?.trim().length ? message.toolName : "Tool"),
        input: existing?.input ?? {},
        result: {
          content: boundedHistoryToolDetailText(message.content),
          ...(message.toolName ? { toolName: message.toolName } : {}),
          ...(message.images?.length
            ? {
                images: message.images.slice(
                  0,
                  HISTORY_TOOL_DETAIL_MAX_ATTACHMENTS,
                ),
              }
            : {}),
          ...(message.artifacts?.length
            ? {
                artifacts: message.artifacts.slice(
                  0,
                  HISTORY_TOOL_DETAIL_MAX_ATTACHMENTS,
                ),
              }
            : {}),
        },
      });
    }
    return toolUseIds
      .map((toolUseId) => details.get(toolUseId))
      .filter((detail): detail is HistoryToolDetailPayload => detail != null);
  }

  private async codexHistoryToolDetails(
    session: SessionInfo,
    toolUseIds: string[],
  ): Promise<HistoryToolDetailPayload[]> {
    const cachedEntries = [
      ...(session.codexOrderedHistoryEntries ?? []),
      ...session.historyEntries,
    ];
    const cachedDetails = this.historyToolDetails(cachedEntries, toolUseIds);
    const rawHistory = (session.pastMessages ?? []) as SessionHistoryMessage[];
    if (rawHistory.length === 0) return cachedDetails;

    // A preceding get_history already populated pastMessages from thread/read.
    // Reuse that canonical snapshot and convert only the requested envelopes:
    // expanding each 8-row page must not issue another full provider read or
    // enrich every item in a long thread again.
    const requested = new Set(toolUseIds);
    const foundUses = new Set<string>();
    const foundResults = new Set<string>();
    const selected: Array<{
      index: number;
      item: SessionHistoryMessage;
    }> = [];
    for (let index = rawHistory.length - 1; index >= 0; index -= 1) {
      const item = rawHistory[index];
      if (item.role === "assistant" && Array.isArray(item.content)) {
        const matchingIds = item.content
          .filter(
            (content) =>
              content.type === "tool_use" &&
              typeof content.id === "string" &&
              requested.has(content.id) &&
              !foundUses.has(content.id),
          )
          .map((content) => content.id as string);
        if (matchingIds.length > 0) {
          selected.push({ index, item });
          for (const id of matchingIds) foundUses.add(id);
        }
      } else if (item.role === "tool_result") {
        const id = item.toolUseId ?? item.uuid ?? `codex-history-tool-${index}`;
        if (requested.has(id) && !foundResults.has(id)) {
          selected.push({ index, item });
          foundResults.add(id);
        }
      }
      if (
        foundUses.size === requested.size &&
        foundResults.size === requested.size
      ) {
        break;
      }
    }

    const selectedEntries: HistoryEntry[] = [];
    for (const { index, item } of selected.reverse()) {
      const converted = await this.codexHistoryMessageToServerMessage(
        session,
        item,
        index,
      );
      if (converted) {
        selectedEntries.push({ seq: index + 1, message: converted });
      }
    }
    const rawDetails = this.historyToolDetails(selectedEntries, toolUseIds);
    const rawById = new Map(
      rawDetails.map((detail) => [detail.toolUseId, detail]),
    );
    for (const cached of cachedDetails) {
      const raw = rawById.get(cached.toolUseId);
      rawById.set(cached.toolUseId, {
        ...raw,
        ...cached,
        input:
          Object.keys(cached.input).length > 0
            ? cached.input
            : (raw?.input ?? {}),
        ...((cached.result ?? raw?.result)
          ? { result: cached.result ?? raw?.result }
          : {}),
      });
    }
    return toolUseIds
      .map((toolUseId) => rawById.get(toolUseId))
      .filter((detail): detail is HistoryToolDetailPayload => detail != null);
  }

  private shouldResetCodexHistoryDelta(
    session: SessionInfo,
    sinceSeq: number,
    resultKind: "delta" | "snapshot",
  ): boolean {
    if (!this.codexThreadIdForSession(session)) return false;
    const resetRevision =
      session.codexHistoryResetRevision ??
      session.codexCanonicalHistoryRevision;
    if (typeof resetRevision !== "number") return true;
    if (sinceSeq < resetRevision) return true;
    return resultKind === "snapshot";
  }

  private async codexHistoryToServerMessages(
    session: SessionInfo,
    history: SessionHistoryMessage[],
  ): Promise<ServerMessage[]> {
    const messages: ServerMessage[] = [];
    for (const [historyIndex, item] of history.entries()) {
      const converted = await this.codexHistoryMessageToServerMessage(
        session,
        item,
        historyIndex,
      );
      if (converted) messages.push(converted);
    }
    return messages;
  }

  private async codexHistoryMessageToServerMessage(
    session: SessionInfo,
    item: SessionHistoryMessage,
    historyIndex: number,
  ): Promise<ServerMessage | null> {
    if (item.role === "user") {
      const images = await this.registerPastUserMessageImages(
        session,
        item as unknown as Record<string, unknown>,
      );
      const text = this.sessionHistoryText(item.content);
      if (!text && item.imageCount == null && images.length === 0) return null;
      return {
        type: "user_input",
        text,
        ...(item.uuid ? { userMessageUuid: item.uuid } : {}),
        ...(item.isMeta ? { isMeta: true } : {}),
        ...(item.imageCount != null || images.length > 0
          ? { imageCount: Math.max(item.imageCount ?? 0, images.length) }
          : {}),
        ...(item.timestamp ? { timestamp: item.timestamp } : {}),
        ...(item.timestamp ? { sourceTimestamp: item.timestamp } : {}),
        ...(item.timestamp && item.timestampIsAuthoritative
          ? { sourceTimestampIsAuthoritative: true }
          : {}),
        ...(images.length > 0 ? { images } : {}),
      };
    }

    if (item.role === "assistant") {
      const content = this.sessionHistoryAssistantContent(item.content);
      if (content.length === 0) return null;
      const messageId =
        item.uuid ??
        this.sessionHistorySingleToolUseId(item.content) ??
        `codex-history-assistant-${historyIndex}`;
      const message: ServerMessage = {
        type: "assistant",
        message: {
          id: messageId,
          role: "assistant",
          content,
          model: session.codexSettings?.model ?? "",
        },
        ...(item.uuid ? { messageUuid: item.uuid } : {}),
        ...(item.timestamp ? { sourceTimestamp: item.timestamp } : {}),
        ...(item.timestamp && item.timestampIsAuthoritative
          ? { sourceTimestampIsAuthoritative: true }
          : {}),
      };
      return await this.sessionManager.enrichArtifactsForSession(
        session,
        message,
      );
    }

    const content = this.sessionHistoryText(item.content);
    const toolUseId =
      item.toolUseId ?? item.uuid ?? `codex-history-tool-${historyIndex}`;
    const artifactCandidates =
      item.toolName === "ImageGeneration" && Array.isArray(item.imagePaths)
        ? item.imagePaths.map((path) =>
            createPathArtifactCandidate(path, {
              source: "image_generation",
              linkKind: "generated",
            }),
          )
        : [];
    const providerSessionId = this.codexThreadIdForSession(session);
    let managedImagePaths: string[] | undefined;
    if (
      item.toolName === "ImageGeneration" &&
      this.imageStore &&
      this.artifactManager
    ) {
      managedImagePaths =
        providerSessionId && artifactCandidates.length > 0
          ? await this.artifactManager.materializeGeneratedCandidates({
              ownerId: providerSessionId,
              messageId: toolUseId,
              cwd: session.worktreePath ?? session.projectPath,
              candidates: artifactCandidates,
            })
          : [];
    }
    const images = await this.registerPastToolResultImages(
      session,
      item as unknown as Record<string, unknown>,
      managedImagePaths !== undefined
        ? {
            paths: managedImagePaths,
            suppressLegacyPaths: true,
            persistManagedGallery: true,
            providerSessionId,
          }
        : undefined,
    );
    if (!content && images.length === 0 && artifactCandidates.length === 0) {
      return null;
    }
    const message: ServerMessage = {
      type: "tool_result",
      toolUseId,
      content,
      ...(item.toolName ? { toolName: item.toolName } : {}),
      ...(item.timestamp ? { sourceTimestamp: item.timestamp } : {}),
      ...(item.timestamp && item.timestampIsAuthoritative
        ? { sourceTimestampIsAuthoritative: true }
        : {}),
      ...(images.length > 0 ? { images } : {}),
      ...(artifactCandidates.length > 0 ? { artifactCandidates } : {}),
    };
    return await this.sessionManager.enrichArtifactsForSession(
      session,
      message,
    );
  }

  private sessionHistoryText(
    content: SessionHistoryMessage["content"],
  ): string {
    if (typeof content === "string") return content;
    if (!Array.isArray(content)) return "";
    return content
      .map((item) => {
        if (item.type === "text" && typeof item.text === "string") {
          return item.text;
        }
        if (item.type === "thinking" && typeof item.thinking === "string") {
          return item.thinking;
        }
        return "";
      })
      .filter((text) => text.length > 0)
      .join("\n");
  }

  private sessionHistoryAssistantContent(
    content: SessionHistoryMessage["content"],
  ): AssistantContent[] {
    if (typeof content === "string") {
      return content.trim().length > 0 ? [{ type: "text", text: content }] : [];
    }
    if (!Array.isArray(content)) return [];
    const items: AssistantContent[] = [];
    for (const item of content) {
      if (item.type === "text" && typeof item.text === "string") {
        items.push({ type: "text", text: item.text });
      } else if (
        item.type === "thinking" &&
        typeof item.thinking === "string"
      ) {
        items.push({ type: "thinking", thinking: item.thinking });
      } else if (
        item.type === "tool_use" &&
        typeof item.id === "string" &&
        typeof item.name === "string"
      ) {
        items.push({
          type: "tool_use",
          id: item.id,
          name: item.name,
          input: item.input ?? {},
        });
      }
    }
    return items;
  }

  private sessionHistorySingleToolUseId(
    content: SessionHistoryMessage["content"],
  ): string | undefined {
    if (!Array.isArray(content) || content.length !== 1) return undefined;
    const item = content[0];
    return item.type === "tool_use" && typeof item.id === "string"
      ? item.id
      : undefined;
  }

  private async registerPastUserMessageImages(
    session: SessionInfo,
    msg: Record<string, unknown>,
  ): Promise<ImageRef[]> {
    if (!this.imageStore) return [];

    const existingImages = Array.isArray(msg.images)
      ? (msg.images as ImageRef[])
      : [];
    const refs: ImageRef[] = [...existingImages];

    if (Array.isArray(msg.imagePaths)) {
      const paths = msg.imagePaths.filter(
        (path): path is string => typeof path === "string" && path.length > 0,
      );
      if (paths.length > 0) {
        refs.push(
          ...(await this.imageStore.registerImages(paths, session.projectPath)),
        );
      }
    }

    if (Array.isArray(msg.imageBase64)) {
      for (const image of msg.imageBase64) {
        const rawImage = image as Record<string, unknown>;
        if (
          typeof rawImage.data !== "string" ||
          typeof rawImage.mimeType !== "string"
        ) {
          continue;
        }
        const ref = this.imageStore.registerFromBase64(
          rawImage.data,
          rawImage.mimeType,
        );
        if (ref) refs.push(ref);
      }
    }

    const messageUuid = typeof msg.uuid === "string" ? msg.uuid : undefined;
    const providerSessionId = session.claudeSessionId;
    if (
      refs.length === existingImages.length &&
      messageUuid &&
      providerSessionId
    ) {
      try {
        const extracted = await extractMessageImages(
          providerSessionId,
          messageUuid,
        );
        for (const image of extracted) {
          const ref = this.imageStore.registerFromBase64(
            image.base64,
            image.mimeType,
          );
          if (ref) refs.push(ref);
        }
      } catch (err) {
        console.warn(
          `[ws] Failed to restore user message images for ${messageUuid}: ${
            err instanceof Error ? err.message : String(err)
          }`,
        );
      }
    }

    return refs;
  }

  private async registerPastToolResultImages(
    session: SessionInfo,
    msg: Record<string, unknown>,
    options: {
      paths?: string[];
      suppressLegacyPaths?: boolean;
      persistManagedGallery?: boolean;
      providerSessionId?: string;
    } = {},
  ): Promise<ImageRef[]> {
    const existingImages = Array.isArray(msg.images)
      ? (msg.images as ImageRef[])
      : [];
    if (!this.imageStore) return [...existingImages];

    const paths = new Set<string>(options.paths ?? []);
    if (!options.suppressLegacyPaths && Array.isArray(msg.imagePaths)) {
      for (const path of msg.imagePaths) {
        if (typeof path === "string" && path.length > 0) paths.add(path);
      }
    }

    const content = typeof msg.content === "string" ? msg.content : "";
    if (!options.suppressLegacyPaths && content) {
      for (const path of this.imageStore.extractImagePaths(content)) {
        paths.add(path);
      }
    }

    const refs: ImageRef[] = [...existingImages];
    if (paths.size > 0) {
      const sessionRoot = session.worktreePath ?? session.projectPath;
      refs.push(
        ...(await this.imageStore.registerImages([...paths], sessionRoot)),
      );
      if (options.persistManagedGallery && this.galleryStore) {
        for (const path of paths) {
          if (options.providerSessionId) {
            try {
              const existing =
                await this.galleryStore.bindProviderSessionIdBySourcePath(
                  path,
                  options.providerSessionId,
                );
              if (existing) continue;
            } catch (error) {
              const detail =
                error instanceof Error ? error.name : "unknown_error";
              console.warn(
                `[gallery] Failed to repair managed history binding: ${detail}`,
              );
              continue;
            }
          }

          const galleryKey = `${options.providerSessionId ?? session.id}\0${path}`;
          if (this.restoringManagedGalleryPaths.has(galleryKey)) continue;
          this.restoringManagedGalleryPaths.add(galleryKey);
          try {
            const meta = await this.galleryStore.addImage(
              path,
              sessionRoot,
              session.id,
              options.providerSessionId,
            );
            if (!meta) continue;
            this.broadcast({
              type: "gallery_new_image",
              image: this.galleryStore.metaToInfo(meta),
            });
          } finally {
            this.restoringManagedGalleryPaths.delete(galleryKey);
          }
        }
      }
    }

    if (Array.isArray(msg.imageBase64)) {
      for (const image of msg.imageBase64) {
        const rawImage = image as Record<string, unknown>;
        if (
          typeof rawImage.data !== "string" ||
          typeof rawImage.mimeType !== "string"
        ) {
          continue;
        }
        const ref = this.imageStore.registerFromBase64(
          rawImage.data,
          rawImage.mimeType,
        );
        if (ref) refs.push(ref);
      }
    }

    return refs;
  }

  private async getCodexThreadHistoryFromRpc(
    threadId: string,
    projectPath?: string,
    preferredProcess?: CodexProcess,
  ): Promise<SessionHistoryMessage[]> {
    const activeProcess = preferredProcess ?? this.getActiveCodexProcess();
    const process =
      activeProcess ?? (await this.createStandaloneCodexProcess(projectPath));
    const isStandalone = process !== activeProcess;
    try {
      const [thread, desktopToolTimeline] = await Promise.all([
        process.readThread(threadId, true),
        getCodexDesktopToolTimeline(threadId),
      ]);
      return codexThreadToSessionHistory(thread, { desktopToolTimeline });
    } catch (err) {
      if (this.isCodexThreadNotMaterializedError(err)) return [];
      throw err;
    } finally {
      if (isStandalone) {
        process.stop();
      }
    }
  }

  private isCodexThreadNotMaterializedError(err: unknown): boolean {
    const message = err instanceof Error ? err.message : String(err);
    return (
      message.includes("is not materialized yet") &&
      message.includes("includeTurns is unavailable before first user message")
    );
  }

  private async getCodexThreadHistory(
    threadId: string,
    projectPath?: string,
  ): Promise<SessionHistoryMessage[]> {
    if (!this.getActiveCodexProcess() && process.env.NODE_ENV === "test") {
      return getCodexSessionHistory(threadId);
    }
    return this.getCodexThreadHistoryFromRpc(threadId, projectPath);
  }

  private codexHistoryFromThreadOrFallback(params: {
    thread: unknown;
    expectedUserTurns: number;
    fallback: SessionHistoryMessage[];
  }): SessionHistoryMessage[] {
    const messages = codexThreadToSessionHistory(params.thread);
    if (countCodexHistoryUserTurns(messages) >= params.expectedUserTurns) {
      return messages;
    }
    return params.fallback;
  }

  private createClaudeSessionWithFallback(params: {
    projectPath: string;
    options?: StartOptions & { permissionMode?: ClaudePermissionMode };
    pastMessages?: unknown[];
    worktreeOptions?: WorktreeOptions;
  }): {
    sessionId: string;
    permissionMode: ClaudePermissionMode;
    executionMode: "default" | "acceptEdits" | "fullAccess";
    planMode: boolean;
    usedFallback: boolean;
  } {
    const initialMode = params.options?.permissionMode ?? "default";
    try {
      const sessionId = this.sessionManager.create(
        params.projectPath,
        params.options,
        params.pastMessages,
        params.worktreeOptions,
      );
      return {
        sessionId,
        permissionMode: initialMode,
        executionMode: deriveExecutionMode({
          provider: "claude",
          permissionMode: initialMode,
        }),
        planMode: derivePlanMode({ permissionMode: initialMode }),
        usedFallback: false,
      };
    } catch (err) {
      if (initialMode !== "auto" || !isClaudeAutoModeUnavailableError(err)) {
        throw err;
      }
      const fallbackOptions = {
        ...params.options,
        permissionMode: "default" as const,
      };
      const sessionId = this.sessionManager.create(
        params.projectPath,
        fallbackOptions,
        params.pastMessages,
        params.worktreeOptions,
      );
      return {
        sessionId,
        permissionMode: "default",
        executionMode: "default",
        planMode: false,
        usedFallback: true,
      };
    }
  }

  async close(): Promise<void> {
    console.log("[ws] Shutting down...");
    this.sessionCatalogMonitor.close();
    // Abort local operations synchronously so the existing shutdown flush
    // contract remains observable before callers await this method. Drain the
    // async handlers before releasing shared file-transfer state below.
    const localFeaturesClosing = this.localFeatures.close();
    for (const operation of this.resumeOperations.values()) {
      if (operation.timeout) clearTimeout(operation.timeout);
    }
    this.resumeOperations.clear();
    this.flushAllPendingBackgroundPushDeliveries();
    this.flushAllDeltaBatches();
    this.sessionManager.destroyAll();
    this.flushAllDeltaBatches();
    stopManagedCodexAppServers();
    this.debugEvents.clear();
    this.restoringManagedGalleryPaths.clear();
    this.wss.close();
    await localFeaturesClosing;
    await this.fileTransfer?.close();
  }

  /** Return session count for /health endpoint. */
  get sessionCount(): number {
    return this.sessionManager.list().length;
  }

  /** Return connected WebSocket client count. */
  get clientCount(): number {
    return this.wss.clients.size;
  }

  private handleConnection(ws: WebSocket, request?: IncomingMessage): void {
    this.fileTransfer?.connect(ws, {
      supports: (messageType) =>
        this.clientSupportedServerMessages.get(ws)?.has(messageType) ?? false,
      isOpen: () => ws.readyState === WebSocket.OPEN,
      send: (message) => {
        if (
          ws.readyState !== WebSocket.OPEN ||
          !(
            this.clientSupportedServerMessages.get(ws)?.has(message.type) ??
            false
          )
        )
          return false;
        this.send(ws, message);
        return true;
      },
      httpBaseUrl: httpBaseUrlForWebSocketRequest(request),
    });
    // Send session list and project history on connect
    this.refreshConnectionMetadata();
    this.sendSessionList(ws);
    const projects = this.projectHistory?.getProjects() ?? [];
    this.send(ws, { type: "project_history", projects });

    ws.on("message", (data) => {
      const raw = data.toString();
      const msg = parseClientMessage(raw);

      if (!msg) {
        // Try to extract the message type so the client can decide how to
        // handle the unsupported message (suppress vs show update hint).
        let rawType: string | undefined;
        try {
          rawType = (JSON.parse(raw) as Record<string, unknown>)
            ?.type as string;
        } catch {
          /* ignore */
        }
        console.error(
          "[ws] Unsupported message:",
          rawType ?? raw.slice(0, 200),
        );
        this.send(ws, {
          type: "error",
          errorCode: "unsupported_message",
          message: rawType ?? "unknown",
        });
        return;
      }

      console.log(`[ws] Received: ${msg.type}`);
      void this.handleClientMessage(msg, ws).catch((error) => {
        console.error(
          `[ws] Failed to handle ${msg.type}:`,
          error instanceof Error ? error.message : String(error),
        );
      });
    });

    ws.on("close", () => {
      console.log("[ws] Client disconnected");
      this.localFeatures.disconnect(ws);
      this.fileTransfer?.disconnect(ws);
      this.discardClientDeltaBatches(ws);
      this.clearPendingClaudeResumeInputs(ws);
      this.refreshSessionCatalogMonitorState();
    });

    ws.on("error", (err) => {
      console.error("[ws] Client error:", err.message);
    });
  }

  private refreshConnectionMetadata(now = Date.now()): void {
    const lastRefreshAt = this.lastConnectMetadataRefreshAt;
    if (
      lastRefreshAt !== null &&
      now >= lastRefreshAt &&
      now - lastRefreshAt <
        BridgeWebSocketServer.CONNECT_METADATA_REFRESH_COOLDOWN_MS
    ) {
      return;
    }
    this.lastConnectMetadataRefreshAt = now;
    void this.refreshCodexMetadata();
    void this.refreshClaudeModels();
  }

  private async handleClientMessage(
    msg: ClientMessage,
    ws: WebSocket,
  ): Promise<void> {
    if (msg.type === "client_capabilities") {
      this.clientSupportedServerMessages.set(
        ws,
        new Set(msg.supportedServerMessages ?? []),
      );
      if (msg.mobileRuntime) {
        this.clientMobileRuntime.set(ws, msg.mobileRuntime);
      } else {
        this.clientMobileRuntime.delete(ws);
      }
      this.localFeatures.capabilitiesChanged(ws);
      this.sendPromptHistoryStatus(ws);
      this.refreshSessionCatalogMonitorState();
      return;
    }

    if (msg.type === BACKGROUND_NOTIFICATION_ACK_MESSAGE) {
      this.acknowledgeBackgroundNotification(ws, msg.deliveryId);
      return;
    }

    if (msg.type === "set_client_delivery_mode") {
      const supportedMessages = this.clientSupportedServerMessages.get(ws);
      const supportsBackgroundDelivery =
        supportedMessages?.has(CLIENT_DELIVERY_MODE_STATE_MESSAGE) === true &&
        supportedMessages.has(BACKGROUND_NOTIFICATION_MESSAGE) &&
        supportedMessages.has(BACKGROUND_ACTIVITY_STATE_MESSAGE);
      if (msg.mode === "notifications_only" && !supportsBackgroundDelivery) {
        this.send(ws, {
          type: "error",
          errorCode: "background_delivery_client_unsupported",
          message: msg.type,
        });
        return;
      }

      if (msg.mode === "notifications_only") {
        this.discardClientDeltaBatches(ws);
        this.backgroundDeliveryClients.set(ws, {
          mode: "notifications_only",
          policy: createBackgroundNotificationPolicy({
            locale: msg.locale,
            privacyMode: msg.privacyMode,
            enabledEventTypes: msg.enabledEventTypes,
          }),
          projectionState: createBackgroundNotificationProjectionState(),
        });
      } else {
        this.backgroundDeliveryClients.delete(ws);
      }
      this.localFeatures.clientDeliveryModeChanged(ws, msg.mode);
      this.refreshSessionCatalogMonitorState();
      this.send(ws, {
        type: CLIENT_DELIVERY_MODE_STATE_MESSAGE,
        mode: msg.mode,
        requestId: msg.requestId,
        activeWorkCount: this.backgroundActiveWorkCount(),
      });
      if (msg.mode === "notifications_only") {
        this.send(ws, this.backgroundActivityState());
      }
      return;
    }

    if (this.fileTransfer && isFileTransferClientMessage(msg)) {
      await this.fileTransfer.handleClientMessage(ws, msg);
      return;
    }

    const incomingSessionId = this.extractSessionIdFromClientMessage(msg);
    const isActiveRuntimeSession =
      incomingSessionId != null &&
      this.sessionManager.get(incomingSessionId) != null;
    if (incomingSessionId && isActiveRuntimeSession) {
      this.recordDebugEvent(incomingSessionId, {
        direction: "incoming",
        channel: "ws",
        type: msg.type,
        detail: this.summarizeClientMessage(msg),
      });
      this.recordingStore?.record(incomingSessionId, "incoming", msg);
    }

    const incomingSession = incomingSessionId
      ? this.sessionManager.get(incomingSessionId)
      : undefined;
    if (
      incomingSession?.permissionRestartInProgress &&
      PERMISSION_RESTART_BLOCKED_MESSAGE_TYPES.has(msg.type)
    ) {
      this.send(ws, {
        type: "error",
        message: `Cannot process ${msg.type} while the permission restart is in progress.`,
        errorCode: "permission_restart_in_progress",
        sessionId: incomingSession.id,
        ...((msg.type === "set_goal" || msg.type === "clear_goal") &&
        msg.goalChangeId
          ? { goalChangeId: msg.goalChangeId }
          : {}),
      });
      return;
    }

    const localFeatureRequest = this.localFeatures.handle(ws, msg);
    if (localFeatureRequest) {
      await localFeatureRequest;
      return;
    }

    switch (msg.type) {
      case "start": {
        const projectPath = resolvePlatformPath(msg.projectPath, this.platform);
        const provider = msg.provider ?? "claude";
        if (!this.isExistingProjectPathAllowed(projectPath)) {
          const pathError = this.buildPathNotAllowedError(msg.projectPath);
          this.sendStartFailed(ws, {
            provider,
            projectPath,
            startRequestId: msg.startRequestId,
            errorMessage: pathError.message,
          });
          this.send(ws, pathError);
          break;
        }
        const existingWorktreePath = msg.existingWorktreePath
          ? resolvePlatformPathFrom(
              projectPath,
              msg.existingWorktreePath,
              this.platform,
            )
          : undefined;
        if (
          existingWorktreePath &&
          !this.isExistingProjectPathAllowed(existingWorktreePath)
        ) {
          const pathError = this.buildPathNotAllowedError(
            msg.existingWorktreePath!,
          );
          this.sendStartFailed(ws, {
            provider,
            projectPath,
            startRequestId: msg.startRequestId,
            errorMessage: pathError.message,
          });
          this.send(ws, pathError);
          break;
        }
        if (provider === "codex" && msg.sessionId) {
          // Older clients resume Codex threads through start(sessionId). Keep
          // that wire shape compatible, but admit it through the same
          // provider-thread lock, archive guard, history load, and runtime
          // deduplication as the authoritative resume_session path.
          await this.handleClientMessage(
            {
              type: "resume_session",
              sessionId: msg.sessionId,
              projectPath: msg.projectPath,
              permissionMode: msg.permissionMode,
              executionMode: msg.executionMode,
              approvalPolicy: msg.approvalPolicy,
              approvalsReviewer: msg.approvalsReviewer,
              codexPermissionsMode: msg.codexPermissionsMode,
              planMode: msg.planMode,
              provider,
              sandboxMode: msg.sandboxMode,
              model: msg.model,
              effort: msg.effort,
              maxTurns: msg.maxTurns,
              maxBudgetUsd: msg.maxBudgetUsd,
              fallbackModel: msg.fallbackModel,
              forkSession: msg.forkSession,
              persistSession: msg.persistSession,
              profile: msg.profile,
              modelReasoningEffort: msg.modelReasoningEffort,
              serviceTier: msg.serviceTier,
              networkAccessEnabled: msg.networkAccessEnabled,
              webSearchMode: msg.webSearchMode,
              additionalWritableRoots: msg.additionalWritableRoots,
              resumeRequestId: msg.startRequestId,
            },
            ws,
          );
          break;
        }
        try {
          const normalizedCodexPermissionsMode =
            provider === "codex"
              ? normalizeCodexPermissionsMode(msg.codexPermissionsMode)
              : undefined;
          const requestedCodexPermissionsMode =
            this.codexAutoReviewDisabled &&
            normalizedCodexPermissionsMode === "autoReview"
              ? "default"
              : normalizedCodexPermissionsMode;
          const codexPermissionSettings = requestedCodexPermissionsMode
            ? codexSettingsFromPermissionsMode(requestedCodexPermissionsMode)
            : undefined;
          const codexApprovalPolicy =
            provider === "codex"
              ? requestedCodexPermissionsMode
                ? codexPermissionSettings?.approvalPolicy
                : normalizeCodexApprovalPolicy(
                    msg.approvalPolicy ??
                      (msg.executionMode == null
                        ? undefined
                        : msg.executionMode === "fullAccess"
                          ? "never"
                          : "on-request"),
                  )
              : undefined;
          const executionMode = deriveExecutionMode({
            provider,
            permissionMode: msg.permissionMode,
            executionMode: msg.executionMode,
            approvalPolicy: codexApprovalPolicy,
          });
          const planMode = derivePlanMode({
            permissionMode: msg.permissionMode,
            planMode: msg.planMode,
          });
          const legacyPermissionMode = modesToLegacyPermissionMode(
            provider,
            executionMode,
            planMode,
          );
          const claudePermissionMode =
            provider === "claude"
              ? ((msg.permissionMode as
                  | "default"
                  | "auto"
                  | "acceptEdits"
                  | "bypassPermissions"
                  | "plan"
                  | undefined) ?? legacyPermissionMode)
              : legacyPermissionMode;
          if (provider === "codex") {
            console.log(
              `[ws] start(codex): execution=${executionMode} plan=${planMode}`,
            );
            if (
              msg.profile &&
              !(await this.validateCodexProfile(msg.profile, projectPath))
            ) {
              const message = `Codex profile not found: ${msg.profile}`;
              this.sendStartFailed(ws, {
                provider,
                projectPath,
                startRequestId: msg.startRequestId,
                errorMessage: message,
              });
              this.send(ws, {
                type: "error",
                message,
              });
              break;
            }
          }
          const additionalWritableRoots =
            provider === "codex"
              ? this.normalizeAdditionalWritableRoots(
                  msg.additionalWritableRoots,
                  projectPath,
                )
              : {};
          if (additionalWritableRoots.deniedRoot) {
            const pathError = this.buildPathNotAllowedError(
              additionalWritableRoots.deniedRoot,
            );
            this.sendStartFailed(ws, {
              provider,
              projectPath,
              startRequestId: msg.startRequestId,
              errorMessage: pathError.message,
            });
            this.send(ws, pathError);
            break;
          }
          const {
            sessionId,
            permissionMode: effectivePermissionMode,
            executionMode: effectiveExecutionMode,
            planMode: effectivePlanMode,
            usedFallback: autoFallbackUsed,
          } = provider === "claude"
            ? this.createClaudeSessionWithFallback({
                projectPath,
                options: {
                  sessionId: msg.sessionId,
                  continueMode: msg.continue,
                  permissionMode: claudePermissionMode,
                  model: msg.model,
                  effort: msg.effort,
                  maxTurns: msg.maxTurns,
                  maxBudgetUsd: msg.maxBudgetUsd,
                  fallbackModel: msg.fallbackModel,
                  forkSession: msg.forkSession,
                  persistSession: msg.persistSession,
                  autoRename: msg.autoRename,
                  ...(msg.sandboxMode
                    ? { sandboxEnabled: msg.sandboxMode === "on" }
                    : {}),
                },
                worktreeOptions: {
                  useWorktree: msg.useWorktree,
                  worktreeBranch: msg.worktreeBranch,
                  existingWorktreePath,
                },
              })
            : {
                sessionId: this.sessionManager.create(
                  projectPath,
                  { autoRename: msg.autoRename },
                  undefined,
                  {
                    useWorktree: msg.useWorktree,
                    worktreeBranch: msg.worktreeBranch,
                    existingWorktreePath,
                  },
                  provider,
                  this.withCodexAutoReviewPolicy({
                    profile: msg.profile,
                    approvalPolicy: codexPermissionSettings
                      ? codexPermissionSettings.approvalPolicy
                      : (codexApprovalPolicy ??
                        normalizeCodexApprovalPolicy(
                          executionMode === "fullAccess"
                            ? "never"
                            : "on-request",
                        )),
                    approvalsReviewer:
                      codexPermissionSettings?.approvalsReviewer ??
                      msg.approvalsReviewer,
                    codexPermissionsMode:
                      codexPermissionSettings?.codexPermissionsMode,
                    sandboxMode: codexPermissionSettings
                      ? codexPermissionSettings.sandboxMode
                      : sandboxModeToInternal(msg.sandboxMode),
                    model: msg.model,
                    modelReasoningEffort:
                      (msg.modelReasoningEffort as CodexStartOptions["modelReasoningEffort"]) ??
                      undefined,
                    serviceTier: msg.serviceTier,
                    networkAccessEnabled: msg.networkAccessEnabled,
                    webSearchMode:
                      (msg.webSearchMode as "disabled" | "cached" | "live") ??
                      undefined,
                    additionalWritableRoots: additionalWritableRoots.roots,
                    threadId: msg.sessionId,
                    collaborationMode: planMode
                      ? ("plan" as const)
                      : ("default" as const),
                  }),
                ),
                permissionMode: claudePermissionMode,
                executionMode,
                planMode,
                usedFallback: false,
              };
          const createdSession = this.sessionManager.get(sessionId);
          const cached = this.sessionManager.getCachedCommands(
            provider,
            createdSession?.worktreePath ?? projectPath,
          );

          // Load saved session name from CLI storage (for resumed sessions)
          void this.loadAndSetSessionName(
            createdSession,
            provider,
            projectPath,
            msg.sessionId,
          ).then(() => {
            this.send(
              ws,
              this.buildSessionCreatedMessage({
                sessionId,
                provider,
                projectPath,
                session: createdSession,
                permissionMode:
                  provider === "claude"
                    ? effectivePermissionMode
                    : claudePermissionMode,
                executionMode:
                  provider === "claude"
                    ? effectiveExecutionMode
                    : executionMode,
                planMode: provider === "claude" ? effectivePlanMode : planMode,
                sandboxMode: createdSession?.codexSettings?.sandboxMode
                  ? sandboxModeToExternal(
                      createdSession.codexSettings.sandboxMode,
                    )
                  : msg.sandboxMode,
                codexPermissionsMode:
                  createdSession?.codexSettings?.codexPermissionsMode,
                approvalsReviewer:
                  createdSession?.codexSettings?.approvalsReviewer,
                startRequestId: msg.startRequestId,
                ...(cached
                  ? {
                      slashCommands: cached.slashCommands,
                      skills: cached.skills,
                      ...(cached.skillMetadata
                        ? { skillMetadata: cached.skillMetadata }
                        : {}),
                      apps: cached.apps,
                      ...(cached.appMetadata
                        ? { appMetadata: cached.appMetadata }
                        : {}),
                      plugins: cached.plugins,
                      ...(cached.pluginMetadata
                        ? { pluginMetadata: cached.pluginMetadata }
                        : {}),
                    }
                  : {}),
              }),
            );
            this.broadcastSessionList();
            if (provider === "codex") {
              void this.refreshCodexMetadata(projectPath);
            } else {
              void this.refreshClaudeModels(projectPath);
            }
            if (autoFallbackUsed) {
              this.sendTip(
                ws,
                sessionId,
                "auto_mode_fallback_default",
                createdSession,
              );
            }
            // Send a gentle tip when the project is not a git repository
            if (createdSession && !createdSession.gitBranch) {
              this.sendTip(ws, sessionId, "git_not_available", createdSession);
            }
          });
          this.debugEvents.set(sessionId, []);
          this.recordDebugEvent(sessionId, {
            direction: "internal",
            channel: "bridge",
            type: "session_created",
            detail: `provider=${provider} projectPath=${projectPath}`,
          });
          this.recordingStore?.saveMeta(sessionId, {
            bridgeSessionId: sessionId,
            projectPath,
            createdAt: new Date().toISOString(),
          });
          this.projectHistory?.addProject(projectPath);
        } catch (err) {
          console.error(`[ws] Failed to start session:`, err);
          this.sendStartFailed(ws, {
            provider,
            projectPath,
            startRequestId: msg.startRequestId,
            errorMessage: (err as Error).message,
          });
          this.send(ws, {
            type: "error",
            message: `Failed to start session: ${(err as Error).message}`,
          });
        }
        break;
      }

      case "input": {
        let session = this.resolveSession(msg.sessionId);
        if (!session) {
          const pendingInputs = msg.sessionId
            ? this.pendingClaudeResumeInputs.get(ws)?.get(msg.sessionId)
            : undefined;
          if (pendingInputs) {
            pendingInputs.push(msg);
            return;
          }
          this.send(ws, {
            type: "error",
            message: "No active session. Send 'start' first.",
          });
          return;
        }
        if (session.permissionRestartInProgress) {
          this.send(ws, {
            type: "input_rejected",
            sessionId: session.id,
            ...(msg.clientMessageId
              ? { clientMessageId: msg.clientMessageId }
              : {}),
            reason: "Permission restart in progress",
          });
          break;
        }
        const text = msg.text;
        const clientMessageId = msg.clientMessageId;
        const baseSeq = msg.baseSeq;
        const codexSkills = msg.skills ?? (msg.skill ? [msg.skill] : []);
        const codexMentions = msg.mentions ?? [];

        if (clientMessageId) {
          const priorAdmission = this.findAcceptedClientInput(
            session,
            clientMessageId,
          );
          if (priorAdmission) {
            this.sendInputBridgeAcceptance(
              ws,
              session,
              clientMessageId,
              priorAdmission.acceptedSeq,
              priorAdmission.queued,
            );
            this.sendProviderInputReceipt(ws, session, priorAdmission);
            break;
          }
        }

        // A compact/review RPC can be accepted before app-server publishes the
        // corresponding turn/started notification. The Codex process reports
        // itself as not ready throughout that window, so the ordinary busy
        // path below admits the input into the Bridge-owned queue instead of
        // either consuming it early or rejecting a valid next turn.

        // Snapshot busy state before dispatch. We prefer the actual enqueue
        // result returned by SdkProcess sendInput* below, but keep this as a
        // fallback for test doubles and async paths.
        const isAgentBusySnapshot =
          session.provider === "claude" && !session.process.isWaitingForInput;

        // Normalize images: support new `images` array and legacy single-image fields
        let images: Array<{ base64: string; mimeType: string }> = [];
        if (msg.images && msg.images.length > 0) {
          images = msg.images;
        } else if (msg.imageBase64 && msg.mimeType) {
          // Legacy single-image fallback
          images = [{ base64: msg.imageBase64, mimeType: msg.mimeType }];
        }

        // Add user_input to in-memory history.
        // The SDK stream does NOT emit user messages, so session.history would
        // otherwise lack them.  This ensures get_history responses include user
        // messages and replaceEntries on the client side preserves them.
        // Flutter already shows the user bubble optimistically. For Codex we
        // echo the accepted user_input back with its synthetic UUID so the live
        // bubble becomes rewindable/forkable without requiring a stop+resume.
        //
        // Register images in the image store so they can be served via HTTP
        // when the client re-enters the session and loads history.
        let imageRefs:
          Array<{ id: string; url: string; mimeType: string }> | undefined;
        if (images.length > 0 && this.imageStore) {
          imageRefs = [];
          for (const img of images) {
            const ref = this.imageStore.registerFromBase64(
              img.base64,
              img.mimeType,
            );
            if (ref) imageRefs.push(ref);
          }
          if (imageRefs.length === 0) imageRefs = undefined;
        }

        if (
          clientMessageId &&
          baseSeq !== undefined &&
          this.hasInputConflictSince(session, baseSeq)
        ) {
          this.send(ws, {
            type: "input_rejected",
            sessionId: session.id,
            clientMessageId,
            reason: "conflict",
          });
          break;
        }

        const localFeatureAdmissionResult =
          session.provider === "codex"
            ? this.localFeatures.admitInput(ws, session, msg)
            : { action: "allow" as const };
        const localFeatureAdmission =
          localFeatureAdmissionResult instanceof Promise
            ? await localFeatureAdmissionResult
            : localFeatureAdmissionResult;
        const currentSession = this.sessionManager.get(session.id);
        if (currentSession !== session) {
          const priorThreadId = this.codexThreadIdForSession(session);
          if (
            !currentSession ||
            currentSession.provider !== "codex" ||
            this.codexThreadIdForSession(currentSession) !== priorThreadId
          ) {
            this.send(ws, {
              type: "input_rejected",
              sessionId: session.id,
              ...(clientMessageId ? { clientMessageId } : {}),
              reason: "Session changed while input was being admitted",
            });
            break;
          }
          session = currentSession;
        }
        if (localFeatureAdmission.action === "reject") {
          this.send(ws, {
            type: "input_rejected",
            sessionId: session.id,
            ...(clientMessageId ? { clientMessageId } : {}),
            reason: localFeatureAdmission.reason,
          });
          break;
        }
        const queueForExternalCodexTurn =
          localFeatureAdmission.action === "queue";

        if (
          session.provider === "codex" &&
          (queueForExternalCodexTurn || !session.process.isWaitingForInput)
        ) {
          if (session.codexQueuedInput) {
            this.send(ws, {
              type: "input_rejected",
              sessionId: session.id,
              ...(clientMessageId ? { clientMessageId } : {}),
              reason: "Queue is full",
            });
            break;
          }

          const queued = this.sessionManager.queueCodexInput(session.id, {
            itemId: randomUUID(),
            text,
            createdAt: new Date().toISOString(),
            userMessageUuid: nextCodexUserTurnUuid(session),
            ...(images.length > 0 ? { imageCount: images.length, images } : {}),
            ...(imageRefs ? { imageRefs } : {}),
            ...(clientMessageId ? { clientMessageId } : {}),
            ...(codexSkills.length > 0 ? { skills: codexSkills } : {}),
            ...(codexMentions.length > 0 ? { mentions: codexMentions } : {}),
          });
          if (!queued) {
            this.send(ws, {
              type: "input_rejected",
              sessionId: session.id,
              ...(clientMessageId ? { clientMessageId } : {}),
              reason: "Queue is full",
            });
            break;
          }
          if (images.length > 0 && this.galleryStore && session.projectPath) {
            for (const img of images) {
              this.galleryStore
                .addImageFromBase64(
                  img.base64,
                  img.mimeType,
                  session.projectPath,
                  msg.sessionId,
                  this.providerSessionIdForSession(session),
                )
                .catch((err) => {
                  console.warn(
                    `[ws] Failed to persist queued image to gallery: ${err}`,
                  );
                });
            }
          }
          this.sendInputBridgeAcceptance(
            ws,
            session,
            clientMessageId,
            session.historyRevision,
            true,
          );
          this.localFeatures.inputAccepted(ws, session, msg, true);
          this.broadcastSessionList();
          break;
        }

        const userEntry = this.sessionManager.appendHistory(session.id, {
          type: "user_input",
          text,
          ...(session.provider === "codex"
            ? { userMessageUuid: nextCodexUserTurnUuid(session) }
            : {}),
          ...(clientMessageId ? { clientMessageId } : {}),
          timestamp: new Date().toISOString(),
          ...(images.length > 0 ? { imageCount: images.length } : {}),
          ...(imageRefs ? { images: imageRefs } : {}),
        } as ServerMessage);
        const acceptedSeq = userEntry?.seq ?? session.historyRevision;

        if (session.provider === "codex" && userEntry) {
          this.send(ws, {
            ...userEntry.message,
            sessionId: session.id,
            historySeq: acceptedSeq,
          } as ServerMessage & { sessionId: string; historySeq: number });
        }
        if (userEntry) {
          this.broadcastSessionMessage(
            session.id,
            {
              ...userEntry.message,
              historySeq: acceptedSeq,
            } as ServerMessage & { historySeq: number },
            ws,
          );
        }

        // Persist images to Gallery Store asynchronously (fire-and-forget)
        if (images.length > 0 && this.galleryStore && session.projectPath) {
          for (const img of images) {
            this.galleryStore
              .addImageFromBase64(
                img.base64,
                img.mimeType,
                session.projectPath,
                msg.sessionId,
                this.providerSessionIdForSession(session),
              )
              .catch((err) => {
                console.warn(`[ws] Failed to persist image to gallery: ${err}`);
              });
          }
        }

        // Codex input path
        if (session.provider === "codex") {
          this.sendInputBridgeAcceptance(
            ws,
            session,
            clientMessageId,
            acceptedSeq,
            false,
          );
          this.localFeatures.inputAccepted(ws, session, msg, false);
          const codexProc = session.process as CodexProcess;
          if (images.length > 0) {
            codexProc.sendInputStructured(text, {
              images,
              skills: codexSkills,
              mentions: codexMentions,
              ...(clientMessageId ? { clientMessageId } : {}),
            });
          } else if (msg.imageId && this.galleryStore) {
            this.galleryStore
              .getImageAsBase64(msg.imageId)
              .then((imageData) => {
                if (imageData) {
                  codexProc.sendInputStructured(text, {
                    images: [imageData],
                    skills: codexSkills,
                    mentions: codexMentions,
                    ...(clientMessageId ? { clientMessageId } : {}),
                  });
                } else {
                  console.warn(`[ws] Image not found: ${msg.imageId}`);
                  codexProc.sendInputStructured(text, {
                    skills: codexSkills,
                    mentions: codexMentions,
                    ...(clientMessageId ? { clientMessageId } : {}),
                  });
                }
              })
              .catch((err) => {
                console.error(`[ws] Failed to load image: ${err}`);
                codexProc.sendInputStructured(text, {
                  skills: codexSkills,
                  mentions: codexMentions,
                  ...(clientMessageId ? { clientMessageId } : {}),
                });
              });
          } else if (codexSkills.length > 0 || codexMentions.length > 0) {
            codexProc.sendInputStructured(text, {
              skills: codexSkills,
              mentions: codexMentions,
              ...(clientMessageId ? { clientMessageId } : {}),
            });
          } else {
            if (clientMessageId) {
              codexProc.sendInput(text, clientMessageId);
            } else {
              codexProc.sendInput(text);
            }
          }
          break;
        }

        // Claude Code input path — enqueue first, then interrupt if busy
        const claudeProc = session.process as SdkProcess;
        let wasQueued = false;
        let shouldInterrupt = false;
        if (images.length > 0) {
          console.log(
            `[ws] Sending message with ${images.length} inline Base64 image(s)`,
          );
          if (typeof claudeProc.dispatchInputWithImages === "function") {
            const result = claudeProc.dispatchInputWithImages(text, images);
            wasQueued = result.queued;
            shouldInterrupt = result.shouldInterrupt;
          } else {
            const result = claudeProc.sendInputWithImages(text, images);
            wasQueued =
              typeof result === "boolean" ? result : isAgentBusySnapshot;
            shouldInterrupt = wasQueued;
          }
        }
        // Legacy imageId mode (backward compatibility)
        else if (msg.imageId && this.galleryStore) {
          this.sendInputBridgeAcceptance(
            ws,
            session,
            clientMessageId,
            acceptedSeq,
            isAgentBusySnapshot,
          );
          this.galleryStore
            .getImageAsBase64(msg.imageId)
            .then((imageData) => {
              let queuedAfterResolve = false;
              if (imageData) {
                if (typeof claudeProc.dispatchInputWithImages === "function") {
                  const result = claudeProc.dispatchInputWithImages(text, [
                    imageData,
                  ]);
                  queuedAfterResolve = result.queued;
                  if (result.shouldInterrupt) claudeProc.interrupt();
                } else {
                  const result = claudeProc.sendInputWithImages(text, [
                    imageData,
                  ]);
                  queuedAfterResolve =
                    typeof result === "boolean" ? result : isAgentBusySnapshot;
                  if (queuedAfterResolve) claudeProc.interrupt();
                }
              } else {
                console.warn(`[ws] Image not found: ${msg.imageId}`);
                if (typeof claudeProc.dispatchInput === "function") {
                  const result = claudeProc.dispatchInput(text);
                  queuedAfterResolve = result.queued;
                  if (result.shouldInterrupt) claudeProc.interrupt();
                } else {
                  const result = session.process.sendInput(text);
                  queuedAfterResolve =
                    typeof result === "boolean" ? result : isAgentBusySnapshot;
                  if (queuedAfterResolve) claudeProc.interrupt();
                }
              }
            })
            .catch((err) => {
              console.error(`[ws] Failed to load image: ${err}`);
              if (typeof claudeProc.dispatchInput === "function") {
                const result = claudeProc.dispatchInput(text);
                if (result.shouldInterrupt) claudeProc.interrupt();
              } else {
                const result = session.process.sendInput(text);
                const queuedAfterResolve =
                  typeof result === "boolean" ? result : isAgentBusySnapshot;
                if (queuedAfterResolve) claudeProc.interrupt();
              }
            });
          break;
        }
        // Text-only message
        else {
          if (typeof claudeProc.dispatchInput === "function") {
            const result = claudeProc.dispatchInput(text);
            wasQueued = result.queued;
            shouldInterrupt = result.shouldInterrupt;
          } else {
            const result = session.process.sendInput(text);
            wasQueued =
              typeof result === "boolean" ? result : isAgentBusySnapshot;
            shouldInterrupt = wasQueued;
          }
        }

        // Acknowledge receipt so the client can mark the message state.
        // queued=true means the input was enqueued instead of being consumed
        // immediately by the SDK stream.
        this.sendInputBridgeAcceptance(
          ws,
          session,
          clientMessageId,
          acceptedSeq,
          wasQueued,
        );

        if (shouldInterrupt) {
          console.log(
            `[ws] Agent is busy — will queue input and interrupt current turn`,
          );
          claudeProc.interrupt();
        }
        break;
      }

      case "update_queued_input": {
        const session = this.resolveSession(msg.sessionId);
        if (!session || session.provider !== "codex") {
          this.send(ws, { type: "error", message: "No active Codex session." });
          return;
        }
        if (!msg.text.trim()) {
          this.send(ws, {
            type: "error",
            message: "Queued message cannot be empty.",
          });
          return;
        }
        const success = this.sessionManager.updateCodexQueuedInput(
          session.id,
          msg.itemId,
          msg.text,
          { skills: msg.skills ?? [], mentions: msg.mentions ?? [] },
        );
        if (!success) {
          this.send(ws, {
            type: "error",
            message: "Queued message not found.",
            errorCode: "queued_input_not_found",
          });
          return;
        }
        this.broadcastSessionList();
        break;
      }

      case "cancel_queued_input": {
        const session = this.resolveSession(msg.sessionId);
        if (!session || session.provider !== "codex") {
          this.send(ws, { type: "error", message: "No active Codex session." });
          return;
        }
        const success = this.sessionManager.cancelCodexQueuedInput(
          session.id,
          msg.itemId,
        );
        if (!success) {
          this.send(ws, {
            type: "error",
            message: "Queued message not found.",
            errorCode: "queued_input_not_found",
          });
          return;
        }
        this.broadcastSessionList();
        break;
      }

      case "steer_queued_input": {
        const session = this.resolveSession(msg.sessionId);
        if (!session || session.provider !== "codex") {
          this.send(ws, { type: "error", message: "No active Codex session." });
          return;
        }
        const externalTurnId = this.localFeatures.externalCodexTurnId(session);
        const hasExternalActivity =
          this.localFeatures.hasExternalCodexActivity(session);
        let targetTurnId: string;
        let isExpectedTurnCurrent: () => boolean;
        if (msg.expectedTurnId) {
          if (!hasExternalActivity || msg.expectedTurnId !== externalTurnId) {
            this.send(ws, {
              type: "error",
              message: "The Desktop turn changed before guidance was applied.",
              errorCode: "queued_input_steer_stale_turn",
              sessionId: session.id,
            });
            return;
          }
          const owningProcess = session.process;
          if (
            !(owningProcess instanceof CodexProcess) ||
            owningProcess.activeTurnId !== msg.expectedTurnId
          ) {
            this.send(ws, {
              type: "error",
              message:
                "This Desktop turn is visible to Bridge but is owned by another app-server connection. The queued message was kept.",
              errorCode: "external_turn_not_steerable",
              sessionId: session.id,
            });
            return;
          }
          targetTurnId = msg.expectedTurnId;
          isExpectedTurnCurrent = () =>
            this.sessionManager.get(session.id)?.process === owningProcess &&
            owningProcess.activeTurnId === targetTurnId &&
            this.localFeatures.hasExternalCodexActivity(session) &&
            this.localFeatures.externalCodexTurnId(session) === targetTurnId;
        } else {
          // Older/current Mobile clients omit expectedTurnId for a guide to
          // their own running turn. Never reinterpret that omission as
          // permission to steer a newly arrived Desktop turn.
          if (hasExternalActivity) {
            this.send(ws, {
              type: "error",
              message:
                "A Desktop turn is active; local guidance was not rerouted.",
              errorCode:
                externalTurnId === undefined
                  ? "queued_input_steer_ambiguous_turn"
                  : "queued_input_steer_stale_turn",
              sessionId: session.id,
            });
            return;
          }
          const localProcess = session.process as CodexProcess;
          const localTurnId = localProcess.activeTurnId;
          if (!localTurnId) {
            this.send(ws, {
              type: "error",
              message: "No exact local Codex turn is available to guide.",
              errorCode: "queued_input_steer_stale_turn",
              sessionId: session.id,
            });
            return;
          }
          targetTurnId = localTurnId;
          isExpectedTurnCurrent = () =>
            this.sessionManager.get(session.id)?.process === localProcess &&
            localProcess.activeTurnId === targetTurnId &&
            !this.localFeatures.hasExternalCodexActivity(session);
        }
        const result = await this.sessionManager.steerCodexQueuedInput(
          session.id,
          msg.itemId,
          targetTurnId,
          isExpectedTurnCurrent,
        );
        if (!result.ok) {
          this.send(ws, {
            type: "error",
            message: result.error,
            errorCode:
              result.error === "Queued message not found."
                ? "queued_input_not_found"
                : result.error ===
                    "The target turn changed before guidance was applied."
                  ? "queued_input_steer_stale_turn"
                  : "queued_input_steer_failed",
            sessionId: session.id,
          });
          return;
        }
        this.broadcastSessionList();
        break;
      }

      case "push_register": {
        const locale = normalizePushLocale(msg.locale);
        const privacyMode = msg.privacyMode === true;
        console.log(
          `[ws] push_register received (platform: ${msg.platform}, locale: ${locale}, privacy: ${privacyMode}, configured: ${this.pushRelay.isConfigured})`,
        );
        if (!this.pushRelay.isConfigured) {
          this.sendPushRegistrationResult(ws, msg, {
            operation: "register",
            success: false,
            errorCode: "relay_unavailable",
            legacyError: "Push relay is not configured on bridge",
          });
          return;
        }
        try {
          await this.runPushTokenOperation(msg.token, async () => {
            const previousLocale = this.tokenLocales.get(msg.token);
            const hadPreviousLocale = this.tokenLocales.has(msg.token);
            const previousPrivacy = this.tokenPrivacyMode.get(msg.token);
            const hadPreviousPrivacy = this.tokenPrivacyMode.has(msg.token);
            const previousEventTypes = this.tokenEnabledEventTypes.get(
              msg.token,
            );
            const hadPreviousEventTypes = this.tokenEnabledEventTypes.has(
              msg.token,
            );
            this.tokenLocales.set(msg.token, locale);
            this.tokenPrivacyMode.set(msg.token, privacyMode);
            if (msg.enabledEventTypes == null) {
              this.tokenEnabledEventTypes.delete(msg.token);
            } else {
              this.tokenEnabledEventTypes.set(
                msg.token,
                new Set(msg.enabledEventTypes),
              );
            }
            try {
              await this.pushRelay.registerToken(
                msg.token,
                msg.platform,
                locale,
                msg.enabledEventTypes,
                msg.approvalActionsSupported,
              );
            } catch (error) {
              this.restorePushTokenPreferences(
                msg.token,
                {
                  present: hadPreviousLocale,
                  value: previousLocale,
                },
                {
                  present: hadPreviousPrivacy,
                  value: previousPrivacy,
                },
                {
                  present: hadPreviousEventTypes,
                  value: previousEventTypes,
                },
              );
              throw error;
            }
          });
          const clientTokens = this.clientPushTokens.get(ws) ?? new Set();
          clientTokens.add(msg.token);
          this.clientPushTokens.set(ws, clientTokens);
          console.log("[ws] push_register: token registered successfully");
          this.sendPushRegistrationResult(ws, msg, {
            operation: "register",
            success: true,
          });
        } catch (err) {
          const detail = err instanceof Error ? err.message : String(err);
          console.error(`[ws] push_register failed: ${detail}`);
          this.sendPushRegistrationResult(ws, msg, {
            operation: "register",
            success: false,
            errorCode: "registration_failed",
            legacyError: `Failed to register push token: ${detail}`,
          });
        }
        break;
      }

      case "push_unregister": {
        console.log("[ws] push_unregister received");
        if (!this.pushRelay.isConfigured) {
          this.sendPushRegistrationResult(ws, msg, {
            operation: "unregister",
            success: false,
            errorCode: "relay_unavailable",
            legacyError: "Push relay is not configured on bridge",
          });
          return;
        }
        try {
          await this.runPushTokenOperation(msg.token, async () => {
            const previousLocale = this.tokenLocales.get(msg.token);
            const hadPreviousLocale = this.tokenLocales.has(msg.token);
            const previousPrivacy = this.tokenPrivacyMode.get(msg.token);
            const hadPreviousPrivacy = this.tokenPrivacyMode.has(msg.token);
            const previousEventTypes = this.tokenEnabledEventTypes.get(
              msg.token,
            );
            const hadPreviousEventTypes = this.tokenEnabledEventTypes.has(
              msg.token,
            );
            this.tokenLocales.delete(msg.token);
            this.tokenPrivacyMode.delete(msg.token);
            this.tokenEnabledEventTypes.delete(msg.token);
            try {
              await this.pushRelay.unregisterToken(msg.token);
            } catch (error) {
              this.restorePushTokenPreferences(
                msg.token,
                {
                  present: hadPreviousLocale,
                  value: previousLocale,
                },
                {
                  present: hadPreviousPrivacy,
                  value: previousPrivacy,
                },
                {
                  present: hadPreviousEventTypes,
                  value: previousEventTypes,
                },
              );
              throw error;
            }
          });
          this.clientPushTokens.get(ws)?.delete(msg.token);
          console.log("[ws] push_unregister: token unregistered successfully");
          this.sendPushRegistrationResult(ws, msg, {
            operation: "unregister",
            success: true,
          });
        } catch (err) {
          const detail = err instanceof Error ? err.message : String(err);
          console.error(`[ws] push_unregister failed: ${detail}`);
          this.sendPushRegistrationResult(ws, msg, {
            operation: "unregister",
            success: false,
            errorCode: "registration_failed",
            legacyError: `Failed to unregister push token: ${detail}`,
          });
        }
        break;
      }

      case "set_permission_mode": {
        if (this.failSetPermissionMode) {
          this.send(ws, {
            type: "error",
            message: "Failed to set permission mode: forced test failure",
            errorCode: "set_permission_mode_rejected",
            ...(msg.sessionId ? { sessionId: msg.sessionId } : {}),
            ...(msg.permissionChangeId
              ? { permissionChangeId: msg.permissionChangeId }
              : {}),
          });
          break;
        }
        const session = this.resolveSession(msg.sessionId);
        if (!session) {
          this.send(ws, {
            type: "error",
            message: "No active session.",
            errorCode: "set_permission_mode_rejected",
            ...(msg.sessionId ? { sessionId: msg.sessionId } : {}),
            ...(msg.permissionChangeId
              ? { permissionChangeId: msg.permissionChangeId }
              : {}),
          });
          return;
        }
        if (session.permissionRestartInProgress) {
          this.send(ws, {
            type: "error",
            message: "A permission restart is already in progress.",
            errorCode: "set_permission_mode_rejected",
            sessionId: session.id,
            ...(msg.permissionChangeId
              ? { permissionChangeId: msg.permissionChangeId }
              : {}),
          });
          break;
        }
        if (session.provider === "codex") {
          // Permission mode for Codex requires a session restart (like sandbox mode).
          // approvalPolicy and collaborationMode are thread-level settings that
          // only take effect reliably at thread/start or thread/resume time.
          const normalizedCodexPermissionsMode = normalizeCodexPermissionsMode(
            msg.codexPermissionsMode,
          );
          const requestedCodexPermissionsMode =
            this.codexAutoReviewDisabled &&
            normalizedCodexPermissionsMode === "autoReview"
              ? "default"
              : normalizedCodexPermissionsMode;
          const requestedApprovalsReviewer =
            this.codexAutoReviewDisabled &&
            isCodexAutoReviewApprovalsReviewer(msg.approvalsReviewer)
              ? "user"
              : msg.approvalsReviewer;
          const codexPermissionSettings = requestedCodexPermissionsMode
            ? codexSettingsFromPermissionsMode(requestedCodexPermissionsMode)
            : undefined;
          const process = session.process as CodexProcess;
          const currentApproval = normalizeCodexApprovalPolicyIfKnown(
            process.approvalPolicy,
          );
          const currentReviewer = process.approvalsReviewer;
          const currentSandboxMode = session.codexSettings?.sandboxMode;
          const currentPermissionsMode = normalizeCodexPermissionsMode(
            session.codexSettings?.codexPermissionsMode,
          );
          const collaborationOnlyChange =
            requestedCodexPermissionsMode === undefined &&
            msg.approvalPolicy === undefined &&
            msg.approvalsReviewer === undefined &&
            (msg.planMode !== undefined || msg.mode === "plan");
          const explicitApproval = requestedCodexPermissionsMode
            ? codexPermissionSettings?.approvalPolicy
            : collaborationOnlyChange
              ? currentApproval
              : normalizeCodexApprovalPolicy(
                  msg.approvalPolicy ??
                    (msg.executionMode == null
                      ? undefined
                      : msg.executionMode === "fullAccess"
                        ? "never"
                        : "on-request"),
                );
          const executionMode = deriveExecutionMode({
            provider: "codex",
            permissionMode: msg.mode,
            executionMode: msg.executionMode,
            approvalPolicy: explicitApproval,
          });
          const planMode = derivePlanMode({
            permissionMode: msg.mode,
            planMode: msg.planMode,
          });
          const legacyPermissionMode = modesToLegacyPermissionMode(
            "codex",
            executionMode,
            planMode,
          );
          const newApproval = explicitApproval;
          const newSandboxMode = codexPermissionSettings
            ? codexPermissionSettings.sandboxMode
            : currentSandboxMode;
          const configuredReviewer =
            requestedCodexPermissionsMode === "custom"
              ? undefined
              : (codexPermissionSettings?.approvalsReviewer ??
                requestedApprovalsReviewer ??
                currentReviewer);
          const newReviewer = this.codexAutoReviewDisabled
            ? "user"
            : configuredReviewer;
          const derivedPermissionsMode =
            codexPermissionSettings?.codexPermissionsMode ??
            (collaborationOnlyChange ? currentPermissionsMode : undefined) ??
            deriveCodexPermissionsMode({
              approvalPolicy: newApproval,
              approvalsReviewer: newReviewer,
              sandboxMode: newSandboxMode,
            });
          const newPermissionsMode =
            this.codexAutoReviewDisabled &&
            derivedPermissionsMode === "autoReview"
              ? "default"
              : derivedPermissionsMode;
          const newCollaboration: "plan" | "default" = planMode
            ? "plan"
            : "default";
          if (newCollaboration === "plan" && !process.supportsNativePlanMode) {
            if (!process.nativePlanModeCapabilityKnown) {
              await process.confirmNativePlanModeSupportForUserAction();
            }
            if (!process.supportsNativePlanMode) {
              const capabilityStillUnknown =
                !process.nativePlanModeCapabilityKnown;
              this.send(ws, {
                type: "error",
                message: capabilityStillUnknown
                  ? "Failed to set permission mode: native Codex Plan mode support could not be confirmed. Retry after Codex becomes responsive."
                  : "Native Codex Plan mode is unavailable on this app-server. Update Codex before enabling Plan mode.",
                errorCode: capabilityStillUnknown
                  ? "codex_native_plan_mode_probe_retry"
                  : "codex_native_plan_mode_unsupported",
                sessionId: session.id,
                ...(msg.permissionChangeId
                  ? { permissionChangeId: msg.permissionChangeId }
                  : {}),
              });
              break;
            }
          }
          const currentCollaboration = process.collaborationMode;
          if (
            msg.applyStrategy !== "restart_now" &&
            newApproval === currentApproval &&
            newReviewer === currentReviewer &&
            newSandboxMode === currentSandboxMode &&
            newPermissionsMode === currentPermissionsMode &&
            newCollaboration === currentCollaboration
          ) {
            if (msg.permissionChangeId) {
              this.send(ws, {
                type: "system",
                subtype: "set_permission_mode",
                sessionId: session.id,
                permissionMode: legacyPermissionMode,
                executionMode,
                approvalPolicy: newApproval,
                approvalsReviewer: newReviewer,
                codexPermissionsMode: newPermissionsMode,
                planMode,
                sandboxMode: newSandboxMode,
                permissionChangeId: msg.permissionChangeId,
              });
            }
            break; // No change needed
          }
          const nextTurnSettings: CodexNextTurnPermissionSettings = {
            approvalPolicy:
              requestedCodexPermissionsMode === "custom" ? null : newApproval,
            approvalsReviewer:
              requestedCodexPermissionsMode === "custom"
                ? null
                : (newReviewer as CodexStartOptions["approvalsReviewer"]),
            codexPermissionsMode: newPermissionsMode,
            sandboxMode:
              requestedCodexPermissionsMode === "custom"
                ? null
                : (newSandboxMode as CodexStartOptions["sandboxMode"]),
          };

          if (msg.applyStrategy === "next_turn") {
            // A collaboration-only toggle is already a next-turn local
            // setting. Do not make native Plan depend on the separate
            // experimental thread/settings/update permission capability.
            if (!collaborationOnlyChange) {
              try {
                await process.updatePermissionSettingsForNextTurn(
                  nextTurnSettings,
                );
              } catch (err) {
                const unsupported = isUnsupportedCodexRpc(err);
                this.send(ws, {
                  type: "error",
                  message: unsupported
                    ? "This Codex backend does not support next-turn permission updates. Choose Restart now instead."
                    : `Failed to save permissions for the next turn: ${errorMessageOf(err)}`,
                  errorCode: "set_permission_mode_rejected",
                  sessionId: session.id,
                  ...(msg.permissionChangeId
                    ? { permissionChangeId: msg.permissionChangeId }
                    : {}),
                });
                break;
              }
            }

            session.codexSettings = {
              ...(session.codexSettings ?? {}),
              ...(newApproval !== undefined
                ? { approvalPolicy: newApproval }
                : {}),
              approvalsReviewer: newReviewer,
              codexPermissionsMode: newPermissionsMode,
              sandboxMode: newSandboxMode,
            };
            if (newCollaboration !== currentCollaboration) {
              process.setCollaborationMode(newCollaboration);
            }
            session.lastActivityAt = new Date();
            this.broadcast({
              type: "system",
              subtype: "set_permission_mode",
              sessionId: session.id,
              permissionMode: legacyPermissionMode,
              executionMode,
              approvalPolicy: newApproval,
              approvalsReviewer: newReviewer,
              codexPermissionsMode: newPermissionsMode,
              planMode,
              sandboxMode: newSandboxMode,
              ...(msg.permissionChangeId
                ? { permissionChangeId: msg.permissionChangeId }
                : {}),
            });
            this.broadcast({
              type: "system",
              subtype: "tip",
              sessionId: session.id,
              tipCode: "permission_mode_next_turn_applied",
            });
            this.broadcastSessionList();
            this.recordDebugEvent(session.id, {
              direction: "internal" as const,
              channel: "bridge" as const,
              type: "permission_mode_changed",
              detail: `mode=${msg.mode} approval=${newApproval} reviewer=${newReviewer} sandbox=${newSandboxMode} applied=next-turn`,
            });
            console.log(
              `[ws] set_permission_mode(codex): execution=${executionMode} plan=${planMode} → approval=${newApproval}, reviewer=${newReviewer}, sandbox=${newSandboxMode} (next turn)`,
            );
            break;
          }

          const canApplyModeInPlace =
            msg.applyStrategy !== "restart_now" &&
            session.status === "idle" &&
            requestedCodexPermissionsMode !== "custom" &&
            newSandboxMode === currentSandboxMode &&
            (this.codexAutoReviewPolicyLoaded ||
              !isCodexAutoReviewApprovalsReviewer(newReviewer));

          if (canApplyModeInPlace) {
            const process = session.process as CodexProcess;
            if (newApproval && newApproval !== currentApproval) {
              process.setApprovalPolicy(newApproval);
            }
            if (newReviewer && newReviewer !== currentReviewer) {
              process.setApprovalsReviewer(newReviewer);
            }
            if (newCollaboration !== currentCollaboration) {
              process.setCollaborationMode(newCollaboration);
            }
            session.codexSettings = {
              ...(session.codexSettings ?? {}),
              ...(newApproval !== undefined
                ? { approvalPolicy: newApproval }
                : {}),
              approvalsReviewer: newReviewer,
              codexPermissionsMode: newPermissionsMode,
              sandboxMode: newSandboxMode,
            };
            session.lastActivityAt = new Date();
            this.broadcast({
              type: "system",
              subtype: "set_permission_mode",
              sessionId: session.id,
              permissionMode: legacyPermissionMode,
              executionMode,
              approvalPolicy: newApproval,
              approvalsReviewer: newReviewer,
              codexPermissionsMode: newPermissionsMode,
              planMode,
            });
            this.broadcastSessionList();
            this.recordDebugEvent(session.id, {
              direction: "internal" as const,
              channel: "bridge" as const,
              type: "permission_mode_changed",
              detail: `mode=${msg.mode} approval=${newApproval} reviewer=${newReviewer} collaboration=${newCollaboration} applied=in-place`,
            });
            console.log(
              `[ws] set_permission_mode(codex): execution=${executionMode} plan=${planMode} → approval=${newApproval}, reviewer=${newReviewer}, collaboration=${newCollaboration} (in-place)`,
            );
            break;
          }
          console.log(
            `[ws] set_permission_mode(codex): execution=${executionMode} plan=${planMode} → approval=${newApproval}, reviewer=${newReviewer}, collaboration=${newCollaboration} (restart)`,
          );

          const oldSessionId = session.id;
          let threadId = this.codexThreadIdForSession(session);
          const projectPath = session.projectPath;
          const oldSettings = session.codexSettings ?? {};
          const worktreePath = session.worktreePath;
          const worktreeBranch = session.worktreeBranch;
          const sessionName = session.name;
          let goalResumeLease: CodexGoalResumeLease | undefined;
          let restartGoal: CodexGoal | null | undefined = session.codexGoal;
          let restartOwnedActiveGoal = false;
          let continueInterruptedTurnAfterStart = false;

          {
            // Every path that actually recreates a session uses the same gate,
            // including legacy iOS clients and runtime-capability fallback.
            // Set it before the first await so no session mutation can overtake
            // the restart.
            session.permissionRestartInProgress = true;
            try {
              if (threadId) {
                try {
                  restartGoal = await this.codexGoals.refresh(session.id);
                } catch (goalErr) {
                  if (!isUnsupportedCodexGoalRpc(goalErr)) throw goalErr;
                  restartGoal = null;
                }
              }
              if (restartGoal) threadId = restartGoal.threadId;
              if (threadId && restartGoal?.status === "active") {
                restartOwnedActiveGoal = true;
                const pausedGoal = await this.codexGoals.set(
                  session.id,
                  { status: "paused" },
                  session.codexGoalOperationSequence,
                );
                if (!pausedGoal || pausedGoal.status !== "paused") {
                  throw new Error(
                    "Codex did not return the paused Goal required for a safe permission restart",
                  );
                }
                restartGoal = pausedGoal;
                goalResumeLease = createCodexGoalResumeLease(pausedGoal);
              }
              if (session.status !== "idle" && session.status !== "starting") {
                const interrupted = await process.interruptCurrentTurnAndWait();
                continueInterruptedTurnAfterStart =
                  interrupted === true && !restartOwnedActiveGoal;
              }
            } catch (err) {
              if (goalResumeLease) {
                await this.tryResumePermissionRestartGoal(
                  session.id,
                  goalResumeLease,
                  "restart abort",
                );
              }
              session.permissionRestartInProgress = false;
              this.send(ws, {
                type: "error",
                message: `Failed to settle the current turn before restart: ${errorMessageOf(err)}`,
                errorCode: "set_permission_mode_rejected",
                sessionId: session.id,
                ...(msg.permissionChangeId
                  ? { permissionChangeId: msg.permissionChangeId }
                  : {}),
              });
              break;
            }
          }

          const hasUserMessages =
            session.history?.some(
              (m) => m.type === "user_input" || m.type === "assistant",
            ) ||
            (session.pastMessages && session.pastMessages.length > 0);
          const hasGoalLineage = Boolean(threadId && restartGoal);
          const restartWorktreeMapping = threadId
            ? this.worktreeStore.get(threadId)
            : undefined;
          const restartEffectiveProjectPath =
            restartWorktreeMapping?.projectPath ?? projectPath;
          let restartPastMessages: SessionHistoryMessage[] | undefined;
          if (threadId && hasUserMessages) {
            try {
              // Read the canonical history before destroying the only healthy
              // runtime. A read failure must leave the old session usable and,
              // for goal mode, restore the goal we paused above.
              restartPastMessages = await this.getCodexThreadHistory(
                threadId,
                restartEffectiveProjectPath,
              );
            } catch (err) {
              if (goalResumeLease) {
                await this.tryResumePermissionRestartGoal(
                  session.id,
                  goalResumeLease,
                  "history preflight abort",
                );
              }
              session.permissionRestartInProgress = false;
              this.send(ws, {
                type: "error",
                message: `Failed to prepare session history for permission restart: ${errorMessageOf(err)}`,
                errorCode: "set_permission_mode_rejected",
                sessionId: oldSessionId,
                ...(msg.permissionChangeId
                  ? { permissionChangeId: msg.permissionChangeId }
                  : {}),
              });
              break;
            }
          }

          if (goalResumeLease) {
            const leaseBeingVerified = goalResumeLease;
            try {
              const latestGoal = await this.codexGoals.refresh(session.id);
              if (latestGoal == null) {
                // Another Codex client cleared the goal while the restart was
                // settling. Respect that change and do not reactivate it.
                goalResumeLease = undefined;
              } else if (
                !matchesCodexGoalResumeLease(latestGoal, leaseBeingVerified)
              ) {
                session.permissionRestartInProgress = false;
                this.send(ws, {
                  type: "error",
                  message:
                    "The goal changed while the permission restart was settling. Try again from the current goal state.",
                  errorCode: "set_permission_mode_rejected",
                  sessionId: oldSessionId,
                  ...(msg.permissionChangeId
                    ? { permissionChangeId: msg.permissionChangeId }
                    : {}),
                });
                break;
              }
            } catch (err) {
              await this.tryResumePermissionRestartGoal(
                session.id,
                leaseBeingVerified,
                "final restart check abort",
              );
              session.permissionRestartInProgress = false;
              this.send(ws, {
                type: "error",
                message: `Failed to verify the paused goal before permission restart: ${errorMessageOf(err)}`,
                errorCode: "set_permission_mode_rejected",
                sessionId: oldSessionId,
                ...(msg.permissionChangeId
                  ? { permissionChangeId: msg.permissionChangeId }
                  : {}),
              });
              break;
            }
          }
          if (
            this.sessionManager.get(oldSessionId) !== session ||
            !session.permissionRestartInProgress
          ) {
            if (
              this.sessionManager.get(oldSessionId) === session &&
              goalResumeLease
            ) {
              await this.tryResumePermissionRestartGoal(
                session.id,
                goalResumeLease,
                "session identity abort",
              );
              session.permissionRestartInProgress = false;
            }
            this.send(ws, {
              type: "error",
              message:
                "The session changed while the permission restart was settling. Try again on the current session.",
              errorCode: "set_permission_mode_rejected",
              sessionId: oldSessionId,
              ...(msg.permissionChangeId
                ? { permissionChangeId: msg.permissionChangeId }
                : {}),
            });
            break;
          }

          // A plan approval that is still on screen must survive the restart;
          // only carry it while the replacement stays in Plan mode (leaving
          // Plan mode abandons the plan).
          const carriedPlanCompletion =
            newCollaboration === "plan"
              ? ((process as CodexProcess).pendingPlanCompletionSnapshot ??
                undefined)
              : undefined;

          this.destroySession(oldSessionId);
          console.log(
            `[ws] Permission mode change: destroyed session ${oldSessionId}`,
          );

          if (!threadId || (!hasUserMessages && !hasGoalLineage)) {
            const newId = this.sessionManager.create(
              projectPath,
              undefined,
              undefined,
              worktreePath
                ? { existingWorktreePath: worktreePath, worktreeBranch }
                : undefined,
              "codex",
              this.withCodexAutoReviewPolicy({
                approvalPolicy: newApproval,
                approvalsReviewer: newReviewer as
                  "user" | "auto_review" | "guardian_subagent",
                codexPermissionsMode: newPermissionsMode,
                sandboxMode: newSandboxMode as
                  | "read-only"
                  | "workspace-write"
                  | "danger-full-access"
                  | undefined,
                model: oldSettings.model,
                modelReasoningEffort:
                  oldSettings.modelReasoningEffort as CodexStartOptions["modelReasoningEffort"],
                serviceTier: oldSettings.serviceTier,
                networkAccessEnabled: oldSettings.networkAccessEnabled as
                  boolean | undefined,
                webSearchMode: oldSettings.webSearchMode as
                  "disabled" | "cached" | "live" | undefined,
                autoReviewDisabledByPolicy:
                  oldSettings.autoReviewDisabledByPolicy,
                collaborationMode: newCollaboration,
                ...(carriedPlanCompletion
                  ? { restorePlanCompletion: carriedPlanCompletion }
                  : {}),
                ...(goalResumeLease
                  ? {
                      resumeGoalAfterStart: true,
                      resumeGoalLease: goalResumeLease,
                    }
                  : {}),
                ...(threadId && continueInterruptedTurnAfterStart
                  ? {
                      continueInterruptedTurnAfterStart: true,
                      continuationFallbackText: "继续",
                    }
                  : {}),
              }),
            );
            const newSession = this.sessionManager.get(newId);
            if (newSession && sessionName) newSession.name = sessionName;
            if (msg.permissionChangeId) {
              this.broadcast({
                type: "system",
                subtype: "set_permission_mode",
                sessionId: oldSessionId,
                permissionMode: legacyPermissionMode,
                executionMode,
                approvalPolicy: newApproval,
                approvalsReviewer: newReviewer,
                codexPermissionsMode: newPermissionsMode,
                planMode,
                sandboxMode: newSandboxMode,
                permissionChangeId: msg.permissionChangeId,
              });
            }
            this.broadcast(
              this.buildSessionCreatedMessage({
                sessionId: newId,
                provider: "codex",
                projectPath,
                session: newSession,
                permissionMode: legacyPermissionMode,
                executionMode,
                planMode,
                sandboxMode: newSandboxMode
                  ? sandboxModeToExternal(newSandboxMode)
                  : undefined,
                approvalsReviewer: newReviewer,
                codexPermissionsMode: newPermissionsMode,
                sourceSessionId: oldSessionId,
              }),
            );
            this.broadcastSessionList();
            console.log(
              `[ws] Permission mode change (no thread): created new session ${newId} (mode=${msg.mode})`,
            );
            break;
          }

          // Worktree resolution
          const wtMapping = restartWorktreeMapping;
          const effectiveProjectPath = restartEffectiveProjectPath;
          let worktreeOpts:
            | {
                useWorktree?: boolean;
                worktreeBranch?: string;
                existingWorktreePath?: string;
              }
            | undefined;
          if (wtMapping) {
            if (worktreeExists(wtMapping.worktreePath)) {
              worktreeOpts = {
                existingWorktreePath: wtMapping.worktreePath,
                worktreeBranch: wtMapping.worktreeBranch,
              };
            } else {
              worktreeOpts = {
                useWorktree: true,
                worktreeBranch: wtMapping.worktreeBranch,
              };
            }
          } else if (worktreePath) {
            worktreeOpts = {
              existingWorktreePath: worktreePath,
              worktreeBranch,
            };
          }

          const newId = this.sessionManager.create(
            effectiveProjectPath,
            undefined,
            restartPastMessages ?? [],
            worktreeOpts,
            "codex",
            this.withCodexAutoReviewPolicy({
              threadId,
              approvalPolicy: newApproval,
              approvalsReviewer: newReviewer as
                "user" | "auto_review" | "guardian_subagent",
              codexPermissionsMode: newPermissionsMode,
              sandboxMode: newSandboxMode as
                | "read-only"
                | "workspace-write"
                | "danger-full-access"
                | undefined,
              model: oldSettings.model,
              modelReasoningEffort:
                oldSettings.modelReasoningEffort as CodexStartOptions["modelReasoningEffort"],
              serviceTier: oldSettings.serviceTier,
              networkAccessEnabled: oldSettings.networkAccessEnabled as
                boolean | undefined,
              webSearchMode: oldSettings.webSearchMode as
                "disabled" | "cached" | "live" | undefined,
              autoReviewDisabledByPolicy:
                oldSettings.autoReviewDisabledByPolicy,
              collaborationMode: newCollaboration,
              ...(carriedPlanCompletion
                ? { restorePlanCompletion: carriedPlanCompletion }
                : {}),
              ...(goalResumeLease
                ? {
                    resumeGoalAfterStart: true,
                    resumeGoalLease: goalResumeLease,
                  }
                : {}),
              ...(continueInterruptedTurnAfterStart
                ? {
                    continueInterruptedTurnAfterStart: true,
                    continuationFallbackText: "继续",
                  }
                : {}),
            }),
          );

          const newSession = this.sessionManager.get(newId);
          if (newSession && sessionName) {
            newSession.name = sessionName;
          }
          await this.loadAndSetSessionName(
            newSession,
            "codex",
            effectiveProjectPath,
            threadId,
          );
          if (msg.permissionChangeId) {
            this.broadcast({
              type: "system",
              subtype: "set_permission_mode",
              sessionId: oldSessionId,
              permissionMode: legacyPermissionMode,
              executionMode,
              approvalPolicy: newApproval,
              approvalsReviewer: newReviewer,
              codexPermissionsMode: newPermissionsMode,
              planMode,
              sandboxMode: newSandboxMode,
              permissionChangeId: msg.permissionChangeId,
            });
          }
          this.broadcast(
            this.buildSessionCreatedMessage({
              sessionId: newId,
              provider: "codex",
              projectPath: effectiveProjectPath,
              session: newSession,
              permissionMode: legacyPermissionMode,
              executionMode,
              planMode,
              sandboxMode: newSandboxMode
                ? sandboxModeToExternal(newSandboxMode)
                : undefined,
              approvalsReviewer: newReviewer,
              codexPermissionsMode: newPermissionsMode,
              sourceSessionId: oldSessionId,
            }),
          );
          this.broadcastSessionList();

          this.debugEvents.set(newId, []);
          this.recordDebugEvent(newId, {
            direction: "internal" as const,
            channel: "bridge" as const,
            type: "permission_mode_changed",
            detail: `mode=${msg.mode} approval=${newApproval} reviewer=${newReviewer} collaboration=${newCollaboration} thread=${threadId} oldSession=${oldSessionId} continued=${continueInterruptedTurnAfterStart}`,
          });
          console.log(
            `[ws] Permission mode change: created new session ${newId} (thread=${threadId}, mode=${msg.mode})`,
          );
          break;
        }
        (session.process as SdkProcess)
          .setPermissionMode(msg.mode)
          .catch((err) => {
            if (msg.mode === "auto" && isClaudeAutoModeUnavailableError(err)) {
              this.send(ws, {
                type: "error",
                message:
                  "Auto mode is unavailable in this environment. Keeping the current permission mode.",
                errorCode: "auto_mode_unavailable",
              });
              return;
            }
            this.send(ws, {
              type: "error",
              message: `Failed to set permission mode: ${errorMessageOf(err)}`,
            });
          });
        break;
      }

      case "set_codex_model": {
        const session = this.resolveSession(msg.sessionId);
        if (!session) {
          this.send(ws, { type: "error", message: "No active session." });
          return;
        }
        if (session.provider !== "codex") {
          this.send(ws, {
            type: "error",
            message: "Model switching is only supported for Codex sessions.",
            errorCode: "set_codex_model_unsupported",
          });
          break;
        }

        const model = sanitizeCodexModel(msg.model);
        if (!model) {
          this.send(ws, {
            type: "error",
            message: `Invalid Codex model: ${msg.model}`,
            errorCode: "set_codex_model_rejected",
          });
          break;
        }

        const modelReasoningEffort =
          msg.modelReasoningEffort as CodexStartOptions["modelReasoningEffort"];
        const currentModel = sanitizeCodexModel(session.codexSettings?.model);
        const currentEffort = session.codexSettings?.modelReasoningEffort;
        if (model === currentModel && modelReasoningEffort === currentEffort) {
          break;
        }

        const process = session.process as CodexProcess;
        process.setModel(model, modelReasoningEffort);
        void process.persistRuntimeModelForNextTurn();
        session.codexSettings = {
          ...(session.codexSettings ?? {}),
          model,
          ...(modelReasoningEffort !== undefined
            ? { modelReasoningEffort }
            : {}),
        };
        session.lastActivityAt = new Date();
        this.broadcast({
          type: "system",
          subtype: "set_codex_model",
          sessionId: session.id,
          provider: "codex",
          model,
          ...(modelReasoningEffort !== undefined
            ? { modelReasoningEffort }
            : {}),
        });
        this.broadcastSessionList();
        this.recordDebugEvent(session.id, {
          direction: "internal" as const,
          channel: "bridge",
          type: "codex_model_changed",
          detail: `model=${model} effort=${modelReasoningEffort ?? ""}`,
        });
        console.log(
          `[ws] set_codex_model(codex): model=${model} effort=${modelReasoningEffort ?? ""}`,
        );
        break;
      }

      case "set_codex_speed": {
        const session = this.resolveSession(msg.sessionId);
        if (!session || session.provider !== "codex") {
          this.send(ws, {
            type: "error",
            message: "No active Codex session.",
            errorCode: "set_codex_speed_unsupported",
          });
          return;
        }

        const serviceTier = msg.serviceTier === "fast" ? "fast" : "standard";
        if (session.codexSettings?.serviceTier === serviceTier) break;

        const process = session.process as CodexProcess;
        process.setServiceTier(serviceTier);
        void process.persistRuntimeServiceTierForNextTurn();
        session.codexSettings = {
          ...(session.codexSettings ?? {}),
          serviceTier,
        };
        session.lastActivityAt = new Date();
        this.broadcastSessionMessage(session.id, {
          type: "system",
          subtype: "set_codex_speed",
          sessionId: session.id,
          provider: "codex",
          serviceTier,
        });
        this.broadcastSessionList();
        console.log(`[ws] set_codex_speed(codex): serviceTier=${serviceTier}`);
        break;
      }

      case "get_goal": {
        const session = this.resolveSession(msg.sessionId);
        if (!session || session.provider !== "codex") {
          this.send(ws, {
            type: "error",
            message: "Goal lookup is only supported for active Codex sessions.",
            errorCode: "goal_get_unsupported",
            sessionId: msg.sessionId,
          });
          break;
        }
        try {
          const goal = await this.codexGoals.refresh(session.id);
          if (!this.clientSupportsRawCodexGoalStatus(ws, goal)) {
            this.sendGoalStatusUnsupported(ws, session.id);
            break;
          }
          this.send(ws, {
            type: "goal_state",
            sessionId: session.id,
            goal,
            ...(session.codexGoalOperationSequence !== undefined
              ? {
                  goalOperationSequence: session.codexGoalOperationSequence,
                }
              : {}),
          });
        } catch (err) {
          this.send(ws, {
            type: "error",
            message: `Failed to get goal: ${errorMessageOf(err)}`,
            errorCode: isUnsupportedCodexGoalRpc(err)
              ? "goal_get_unsupported"
              : "goal_get_failed",
            sessionId: session.id,
          });
        }
        break;
      }

      case "set_goal": {
        const session = this.resolveSession(msg.sessionId);
        if (!session || session.provider !== "codex") {
          this.send(ws, {
            type: "error",
            message:
              "Goal updates are only supported for active Codex sessions.",
            errorCode: "goal_set_unsupported",
            sessionId: msg.sessionId,
            ...(msg.goalChangeId ? { goalChangeId: msg.goalChangeId } : {}),
          });
          break;
        }
        try {
          const goal = await this.codexGoals.set(
            session.id,
            {
              ...(msg.objective !== undefined
                ? { objective: msg.objective }
                : {}),
              ...(msg.status !== undefined ? { status: msg.status } : {}),
              ...(msg.tokenBudget !== undefined
                ? { tokenBudget: msg.tokenBudget }
                : {}),
            },
            msg.expectedGoalOperationSequence,
          );
          const response: ServerMessage = {
            type: "goal_state",
            goal,
            ...(session.codexGoalOperationSequence !== undefined
              ? {
                  goalOperationSequence: session.codexGoalOperationSequence,
                }
              : {}),
            ...(msg.goalChangeId ? { goalChangeId: msg.goalChangeId } : {}),
          };
          this.broadcastSessionMessage(session.id, response);
          if (!this.clientSupportsRawCodexGoalStatus(ws, goal)) {
            this.sendGoalStatusUnsupported(ws, session.id, msg.goalChangeId);
          }
        } catch (err) {
          if (err instanceof CodexGoalConflictError) {
            this.send(ws, {
              type: "error",
              message:
                "The Goal changed before this update could be applied. Refresh and try again.",
              errorCode: "goal_conflict",
              sessionId: session.id,
              ...(msg.goalChangeId ? { goalChangeId: msg.goalChangeId } : {}),
            });
            break;
          }
          this.send(ws, {
            type: "error",
            message: `Failed to set goal: ${errorMessageOf(err)}`,
            errorCode: isUnsupportedCodexGoalRpc(err)
              ? "goal_set_unsupported"
              : "goal_set_failed",
            sessionId: session.id,
            ...(msg.goalChangeId ? { goalChangeId: msg.goalChangeId } : {}),
          });
        }
        break;
      }

      case "clear_goal": {
        const session = this.resolveSession(msg.sessionId);
        if (!session || session.provider !== "codex") {
          this.send(ws, {
            type: "error",
            message:
              "Goal clearing is only supported for active Codex sessions.",
            errorCode: "goal_clear_unsupported",
            sessionId: msg.sessionId,
            ...(msg.goalChangeId ? { goalChangeId: msg.goalChangeId } : {}),
          });
          break;
        }
        try {
          const goal = await this.codexGoals.clear(
            session.id,
            msg.expectedGoalOperationSequence,
          );
          this.broadcastSessionMessage(session.id, {
            type: "goal_state",
            goal,
            ...(session.codexGoalOperationSequence !== undefined
              ? {
                  goalOperationSequence: session.codexGoalOperationSequence,
                }
              : {}),
            ...(msg.goalChangeId ? { goalChangeId: msg.goalChangeId } : {}),
          });
        } catch (err) {
          if (err instanceof CodexGoalConflictError) {
            this.send(ws, {
              type: "error",
              message:
                "The Goal changed before it could be cleared. Refresh and try again.",
              errorCode: "goal_conflict",
              sessionId: session.id,
              ...(msg.goalChangeId ? { goalChangeId: msg.goalChangeId } : {}),
            });
            break;
          }
          this.send(ws, {
            type: "error",
            message: `Failed to clear goal: ${errorMessageOf(err)}`,
            errorCode: isUnsupportedCodexGoalRpc(err)
              ? "goal_clear_unsupported"
              : "goal_clear_failed",
            sessionId: session.id,
            ...(msg.goalChangeId ? { goalChangeId: msg.goalChangeId } : {}),
          });
        }
        break;
      }

      case "set_sandbox_mode": {
        if (this.failSetSandboxMode) {
          this.send(ws, {
            type: "error",
            message: "Failed to set sandbox mode: forced test failure",
            errorCode: "set_sandbox_mode_rejected",
          });
          break;
        }
        const session = this.resolveSession(msg.sessionId);
        if (!session) {
          this.send(ws, { type: "error", message: "No active session." });
          return;
        }
        if (msg.sandboxMode !== "on" && msg.sandboxMode !== "off") {
          this.send(ws, {
            type: "error",
            message: `Invalid sandbox mode: ${msg.sandboxMode}`,
          });
          return;
        }

        // ---- Claude sandbox toggle ----
        if (session.provider === "claude") {
          const newEnabled = msg.sandboxMode === "on";
          if (session.sandboxEnabled === newEnabled) {
            break; // No change needed
          }

          // Sandbox is a query-level setting — requires session restart.
          const oldSessionId = session.id;
          const claudeSessionId = session.claudeSessionId;
          const projectPath = session.projectPath;
          const worktreePath = session.worktreePath;
          const worktreeBranch = session.worktreeBranch;
          const sessionName = session.name;
          const permissionMode = (session.process as SdkProcess).permissionMode;
          const model = (session.process as SdkProcess).model;

          this.destroySession(oldSessionId);
          console.log(
            `[ws] Claude sandbox change: destroyed session ${oldSessionId}`,
          );

          const newId = this.sessionManager.create(
            projectPath,
            {
              sessionId: claudeSessionId,
              permissionMode,
              model,
              sandboxEnabled: newEnabled,
            },
            undefined,
            worktreePath
              ? { existingWorktreePath: worktreePath, worktreeBranch }
              : undefined,
            "claude",
          );

          const newSession = this.sessionManager.get(newId);
          if (newSession && sessionName) newSession.name = sessionName;

          void this.loadAndSetSessionName(
            newSession,
            "claude",
            projectPath,
            claudeSessionId,
          ).then(() => {
            this.broadcast(
              this.buildSessionCreatedMessage({
                sessionId: newId,
                provider: "claude",
                projectPath,
                session: newSession,
                sandboxMode: msg.sandboxMode,
                sourceSessionId: oldSessionId,
              }),
            );
            this.broadcastSessionList();
          });

          this.debugEvents.set(newId, []);
          this.recordDebugEvent(newId, {
            direction: "internal" as const,
            channel: "bridge" as const,
            type: "sandbox_mode_changed",
            detail: `sandbox=${newEnabled} claude=${claudeSessionId} oldSession=${oldSessionId}`,
          });
          console.log(
            `[ws] Claude sandbox change: created new session ${newId} (sandbox=${newEnabled})`,
          );
          break;
        }

        // ---- Codex sandbox toggle ----
        const newSandboxMode = sandboxModeToInternal(msg.sandboxMode);
        const currentSandboxMode =
          session.codexSettings?.sandboxMode ?? "workspace-write";
        if (newSandboxMode === currentSandboxMode) {
          break; // No change needed
        }

        // Sandbox mode is a thread-level setting — it can only be applied at
        // thread/start or thread/resume time, not per-turn. To apply the new
        // mode we destroy the current session and resume the same Codex thread
        // with the updated sandbox parameter (same pattern as clearContext).
        const oldSessionId = session.id;
        let threadId = this.codexThreadIdForSession(session);
        const projectPath = session.projectPath;
        const oldSettings = session.codexSettings ?? {};
        const worktreePath = session.worktreePath;
        const worktreeBranch = session.worktreeBranch;
        const sessionName = session.name;
        const collaborationMode = (session.process as CodexProcess)
          .collaborationMode;
        const executionMode =
          oldSettings.approvalPolicy === "never" ? "fullAccess" : "default";
        const planMode = collaborationMode === "plan";
        const legacyPermissionMode = modesToLegacyPermissionMode(
          "codex",
          executionMode,
          planMode,
        );

        let goalResumeLease: CodexGoalResumeLease | undefined;
        let restartGoal: CodexGoal | null | undefined = session.codexGoal;
        session.permissionRestartInProgress = true;
        try {
          if (threadId) {
            try {
              restartGoal = await this.codexGoals.refresh(session.id);
            } catch (goalError) {
              if (!isUnsupportedCodexGoalRpc(goalError)) throw goalError;
              restartGoal = null;
            }
          }
          if (restartGoal) threadId = restartGoal.threadId;
          if (threadId && restartGoal?.status === "active") {
            const pausedGoal = await this.codexGoals.set(
              session.id,
              { status: "paused" },
              session.codexGoalOperationSequence,
            );
            if (!pausedGoal || pausedGoal.status !== "paused") {
              throw new Error(
                "Codex did not return the paused Goal required for a safe sandbox restart",
              );
            }
            restartGoal = pausedGoal;
            goalResumeLease = createCodexGoalResumeLease(pausedGoal);
          }
          if (session.status !== "idle" && session.status !== "starting") {
            await (
              session.process as CodexProcess
            ).interruptCurrentTurnAndWait();
          }
        } catch (error) {
          if (goalResumeLease) {
            await this.tryResumePermissionRestartGoal(
              session.id,
              goalResumeLease,
              "sandbox restart abort",
            );
          }
          session.permissionRestartInProgress = false;
          this.send(ws, {
            type: "error",
            message: `Failed to settle the current session before sandbox restart: ${errorMessageOf(error)}`,
            errorCode: "set_sandbox_mode_rejected",
            sessionId: oldSessionId,
          });
          break;
        }

        // Check if the user actually exchanged messages in this session.
        // session.history always contains system events (init, status, etc.)
        // even before the first user turn, so we check for user_input/assistant
        // messages specifically.
        const hasUserMessages =
          session.history?.some(
            (m) => m.type === "user_input" || m.type === "assistant",
          ) ||
          (session.pastMessages && session.pastMessages.length > 0);
        const hasGoalLineage = Boolean(threadId && restartGoal);

        const wtMapping = threadId
          ? this.worktreeStore.get(threadId)
          : undefined;
        const effectiveProjectPath = wtMapping?.projectPath ?? projectPath;
        let restartPastMessages: SessionHistoryMessage[] | undefined;
        if (threadId && hasUserMessages) {
          try {
            restartPastMessages = await this.getCodexThreadHistory(
              threadId,
              effectiveProjectPath,
            );
          } catch (error) {
            if (goalResumeLease) {
              await this.tryResumePermissionRestartGoal(
                session.id,
                goalResumeLease,
                "sandbox history preflight abort",
              );
            }
            session.permissionRestartInProgress = false;
            this.send(ws, {
              type: "error",
              message: `Failed to prepare session history for sandbox restart: ${errorMessageOf(error)}`,
              errorCode: "set_sandbox_mode_rejected",
              sessionId: oldSessionId,
            });
            break;
          }
        }

        if (goalResumeLease) {
          const leaseBeingVerified = goalResumeLease;
          try {
            const latestGoal = await this.codexGoals.refresh(session.id);
            if (latestGoal == null) {
              goalResumeLease = undefined;
            } else if (
              !matchesCodexGoalResumeLease(latestGoal, leaseBeingVerified)
            ) {
              session.permissionRestartInProgress = false;
              this.send(ws, {
                type: "error",
                message:
                  "The Goal changed while the sandbox restart was settling. Try again from the current Goal state.",
                errorCode: "set_sandbox_mode_rejected",
                sessionId: oldSessionId,
              });
              break;
            }
          } catch (error) {
            await this.tryResumePermissionRestartGoal(
              session.id,
              leaseBeingVerified,
              "sandbox final check abort",
            );
            session.permissionRestartInProgress = false;
            this.send(ws, {
              type: "error",
              message: `Failed to verify the paused Goal before sandbox restart: ${errorMessageOf(error)}`,
              errorCode: "set_sandbox_mode_rejected",
              sessionId: oldSessionId,
            });
            break;
          }
        }

        if (
          this.sessionManager.get(oldSessionId) !== session ||
          !session.permissionRestartInProgress
        ) {
          if (
            this.sessionManager.get(oldSessionId) === session &&
            goalResumeLease
          ) {
            await this.tryResumePermissionRestartGoal(
              session.id,
              goalResumeLease,
              "sandbox session identity abort",
            );
            session.permissionRestartInProgress = false;
          }
          this.send(ws, {
            type: "error",
            message:
              "The session changed while the sandbox restart was settling. Try again on the current session.",
            errorCode: "set_sandbox_mode_rejected",
            sessionId: oldSessionId,
          });
          break;
        }

        this.destroySession(oldSessionId);
        console.log(
          `[ws] Sandbox mode change: destroyed session ${oldSessionId}`,
        );

        if (!threadId || (!hasUserMessages && !hasGoalLineage)) {
          // Session has no thread yet, or has a thread but no messages exchanged.
          // Create a fresh session with the new sandbox — no resume needed.
          // (A thread with no messages cannot be resumed — Codex returns
          // "no rollout found for thread id".)
          const newId = this.sessionManager.create(
            projectPath,
            undefined,
            undefined,
            worktreePath
              ? { existingWorktreePath: worktreePath, worktreeBranch }
              : undefined,
            "codex",
            this.withCodexAutoReviewPolicy({
              approvalPolicy: oldSettings.approvalPolicy as
                "never" | "on-request" | undefined,
              approvalsReviewer: oldSettings.approvalsReviewer as
                "user" | "auto_review" | "guardian_subagent" | undefined,
              codexPermissionsMode: oldSettings.codexPermissionsMode as
                "default" | "autoReview" | "fullAccess" | "custom" | undefined,
              sandboxMode: newSandboxMode,
              model: oldSettings.model,
              modelReasoningEffort:
                oldSettings.modelReasoningEffort as CodexStartOptions["modelReasoningEffort"],
              serviceTier: oldSettings.serviceTier,
              networkAccessEnabled: oldSettings.networkAccessEnabled as
                boolean | undefined,
              webSearchMode: oldSettings.webSearchMode as
                "disabled" | "cached" | "live" | undefined,
              autoReviewDisabledByPolicy:
                oldSettings.autoReviewDisabledByPolicy,
              collaborationMode,
            }),
          );
          const newSession = this.sessionManager.get(newId);
          if (newSession && sessionName) newSession.name = sessionName;
          this.broadcast(
            this.buildSessionCreatedMessage({
              sessionId: newId,
              provider: "codex",
              projectPath,
              session: newSession,
              permissionMode: legacyPermissionMode,
              executionMode,
              planMode,
              sandboxMode: sandboxModeToExternal(newSandboxMode),
              sourceSessionId: oldSessionId,
            }),
          );
          this.broadcastSessionList();
          console.log(
            `[ws] Sandbox mode change (no thread): created new session ${newId} (sandbox=${newSandboxMode})`,
          );
          break;
        }

        // Worktree resolution (same as resume_session)
        let worktreeOpts:
          | {
              useWorktree?: boolean;
              worktreeBranch?: string;
              existingWorktreePath?: string;
            }
          | undefined;
        if (wtMapping) {
          if (worktreeExists(wtMapping.worktreePath)) {
            worktreeOpts = {
              existingWorktreePath: wtMapping.worktreePath,
              worktreeBranch: wtMapping.worktreeBranch,
            };
          } else {
            worktreeOpts = {
              useWorktree: true,
              worktreeBranch: wtMapping.worktreeBranch,
            };
          }
        } else if (worktreePath) {
          worktreeOpts = { existingWorktreePath: worktreePath, worktreeBranch };
        }

        const newId = this.sessionManager.create(
          effectiveProjectPath,
          undefined,
          restartPastMessages ?? [],
          worktreeOpts,
          "codex",
          this.withCodexAutoReviewPolicy({
            threadId,
            approvalPolicy: oldSettings.approvalPolicy as
              "never" | "on-request" | undefined,
            approvalsReviewer: oldSettings.approvalsReviewer as
              "user" | "auto_review" | "guardian_subagent" | undefined,
            codexPermissionsMode: oldSettings.codexPermissionsMode as
              "default" | "autoReview" | "fullAccess" | "custom" | undefined,
            sandboxMode: newSandboxMode,
            model: oldSettings.model,
            modelReasoningEffort:
              oldSettings.modelReasoningEffort as CodexStartOptions["modelReasoningEffort"],
            serviceTier: oldSettings.serviceTier,
            networkAccessEnabled: oldSettings.networkAccessEnabled as
              boolean | undefined,
            webSearchMode: oldSettings.webSearchMode as
              "disabled" | "cached" | "live" | undefined,
            autoReviewDisabledByPolicy: oldSettings.autoReviewDisabledByPolicy,
            collaborationMode,
            ...(goalResumeLease
              ? {
                  resumeGoalAfterStart: true,
                  resumeGoalLease: goalResumeLease,
                }
              : {}),
          }),
        );

        const newSession = this.sessionManager.get(newId);
        if (newSession && sessionName) newSession.name = sessionName;
        await this.loadAndSetSessionName(
          newSession,
          "codex",
          effectiveProjectPath,
          threadId,
        );
        this.broadcast(
          this.buildSessionCreatedMessage({
            sessionId: newId,
            provider: "codex",
            projectPath: effectiveProjectPath,
            session: newSession,
            permissionMode: legacyPermissionMode,
            executionMode,
            planMode,
            sandboxMode: sandboxModeToExternal(newSandboxMode),
            sourceSessionId: oldSessionId,
          }),
        );
        this.broadcastSessionList();

        this.debugEvents.set(newId, []);
        this.recordDebugEvent(newId, {
          direction: "internal" as const,
          channel: "bridge" as const,
          type: "sandbox_mode_changed",
          detail: `sandbox=${newSandboxMode} thread=${threadId} oldSession=${oldSessionId}`,
        });
        console.log(
          `[ws] Sandbox mode change: created new session ${newId} (thread=${threadId}, sandbox=${newSandboxMode})`,
        );
        break;
      }

      case "approve": {
        const session = this.resolveSession(msg.sessionId);
        if (!session) {
          this.send(ws, { type: "error", message: "No active session." });
          return;
        }
        if (this.rejectDuringPermissionRestart(ws, session, "approve")) break;
        if (session.provider === "codex") {
          (session.process as CodexProcess).approve(msg.id);
          break;
        }
        const sdkProc = session.process as SdkProcess;
        if (msg.clearContext) {
          // Clear & Accept: immediately destroy this runtime session and
          // create a fresh one that continues the same Claude conversation.
          // This guarantees chat history is cleared in the mobile UI without
          // waiting for additional in-turn tool approvals.
          const pending = sdkProc.getPendingPermission(msg.id);
          if (
            !pending ||
            pending.toolUseId !== msg.id ||
            pending.toolName !== "ExitPlanMode"
          ) {
            this.send(ws, {
              type: "error",
              errorCode: "invalid_clear_context_approval",
              message:
                "Clear context requires the matching pending plan approval.",
            });
            break;
          }
          const planText =
            typeof pending?.input.plan === "string" ? pending.input.plan : "";

          // Use session.id (always present) instead of msg.sessionId.
          const sessionId = session.id;

          // Capture session properties before destroy.
          const claudeSessionId = session.claudeSessionId;
          const projectPath = session.projectPath;
          const permissionMode = sdkProc.permissionMode;
          const worktreePath = session.worktreePath;
          const worktreeBranch = session.worktreeBranch;

          this.destroySession(sessionId);
          console.log(`[ws] Clear context: destroyed session ${sessionId}`);

          const newId = this.sessionManager.create(
            projectPath,
            {
              ...(claudeSessionId
                ? {
                    sessionId: claudeSessionId,
                    continueMode: true,
                  }
                : {}),
              permissionMode,
              initialInput: planText || undefined,
            },
            undefined,
            worktreePath
              ? { existingWorktreePath: worktreePath, worktreeBranch }
              : undefined,
          );
          console.log(
            `[ws] Clear context: created new session ${newId} (CLI session: ${claudeSessionId ?? "new"})`,
          );

          // Notify all clients. Broadcast is used so reconnecting clients also receive it.
          const newSession = this.sessionManager.get(newId);
          const createdMsg = this.buildSessionCreatedMessage({
            sessionId: newId,
            provider: newSession?.provider ?? "claude",
            projectPath,
            session: newSession,
            permissionMode,
            sourceSessionId: sessionId,
          });
          this.broadcast({ ...createdMsg, clearContext: true });
          this.broadcastSessionList();
        } else {
          sdkProc.approve(msg.id);
        }
        break;
      }

      case "approve_always": {
        const session = this.resolveSession(msg.sessionId);
        if (!session) {
          this.send(ws, { type: "error", message: "No active session." });
          return;
        }
        if (this.rejectDuringPermissionRestart(ws, session, "approve")) break;
        if (session.provider === "codex") {
          (session.process as CodexProcess).approveAlways(msg.id);
          break;
        }
        (session.process as SdkProcess).approveAlways(msg.id);
        break;
      }

      case "reject": {
        const session = this.resolveSession(msg.sessionId);
        if (!session) {
          this.send(ws, { type: "error", message: "No active session." });
          return;
        }
        if (this.rejectDuringPermissionRestart(ws, session, "reject")) break;
        if (session.provider === "codex") {
          (session.process as CodexProcess).reject(msg.id, msg.message);
          break;
        }
        (session.process as SdkProcess).reject(msg.id, msg.message);
        break;
      }

      case "answer": {
        const session = this.resolveSession(msg.sessionId);
        if (!session) {
          this.send(ws, { type: "error", message: "No active session." });
          return;
        }
        if (this.rejectDuringPermissionRestart(ws, session, "answer")) break;
        if (session.provider === "codex") {
          (session.process as CodexProcess).answer(msg.toolUseId, msg.result);
          break;
        }
        (session.process as SdkProcess).answer(msg.toolUseId, msg.result);
        break;
      }

      case "install_tool_suggestion": {
        const session = this.resolveSession(msg.sessionId);
        if (!session) {
          this.send(ws, { type: "error", message: "No active session." });
          return;
        }
        if (session.provider !== "codex") {
          this.send(ws, {
            type: "error",
            message: "Tool suggestions are only supported for Codex sessions.",
          });
          return;
        }
        try {
          await (session.process as CodexProcess).installToolSuggestion(
            msg.toolUseId,
          );
        } catch (err) {
          this.send(ws, {
            type: "error",
            message: err instanceof Error ? err.message : String(err),
          });
        }
        break;
      }

      case "list_sessions": {
        this.sendSessionList(ws);
        break;
      }

      case "stop_session": {
        const session = this.sessionManager.get(msg.sessionId);
        if (session) {
          // Notify clients before destroying (destroy removes listeners)
          this.broadcastSessionMessage(msg.sessionId, {
            type: "result",
            subtype: "stopped",
            sessionId: session.claudeSessionId,
          });
          this.destroySession(msg.sessionId);
          this.recordDebugEvent(msg.sessionId, {
            direction: "internal",
            channel: "bridge",
            type: "session_stopped",
          });
          this.debugEvents.delete(msg.sessionId);
          this.notifiedPermissionToolUses.delete(msg.sessionId);
          this.progressNotificationState.delete(msg.sessionId);
          this.broadcastSessionList();
        } else {
          this.send(ws, {
            type: "error",
            message: `Session ${msg.sessionId} not found`,
          });
        }
        break;
      }

      case "resolve_artifact": {
        if (
          !this.clientSupportedServerMessages.get(ws)?.has("artifact_resolved")
        ) {
          this.send(ws, {
            type: "error",
            message: "Artifact resolution capability was not negotiated",
            errorCode: "unsupported_capability",
          });
          break;
        }

        const fail = (errorCode: string, error: string): void => {
          this.send(ws, {
            type: "artifact_resolved",
            requestId: msg.requestId,
            artifactId: msg.artifactId,
            error,
            errorCode,
          });
        };
        const session = this.sessionManager.get(msg.sessionId);
        if (!session) {
          fail("session_not_found", "Session not found");
          break;
        }
        const ownerId = this.codexThreadIdForSession(session);
        if (!ownerId || !this.artifactManager) {
          fail("artifact_unavailable", "Artifact links are unavailable");
          break;
        }

        try {
          const resolvedArtifact = await this.artifactManager.resolve({
            artifactId: msg.artifactId,
            ownerId,
            messageId: msg.messageId,
            candidateRoots: artifactCandidateRootsForSession(session),
          });
          this.send(ws, {
            type: "artifact_resolved",
            requestId: msg.requestId,
            artifactId: msg.artifactId,
            relativeUrl: resolvedArtifact.relativeUrl,
            expiresAt: resolvedArtifact.expiresAt,
          });
        } catch (error) {
          if (error instanceof ArtifactResolveError) {
            fail(error.code, error.message);
          } else {
            fail("artifact_resolve_failed", "Artifact could not be resolved");
          }
        }
        break;
      }

      case "get_history": {
        const session = this.sessionManager.get(msg.sessionId);
        if (session) {
          if (session.provider === "codex") {
            const handled = await this.sendCodexCanonicalLegacyHistory(
              ws,
              msg.sessionId,
              session,
            );
            if (handled) {
              break;
            }
          }

          const splitPastHistory =
            session.pastMessages && session.pastMessages.length > 0
              ? await this.splitPastHistoryMessages(session)
              : { pastMessages: [], historyMessages: [] };
          // Send past conversation from disk (resume) before in-memory history
          if (splitPastHistory.pastMessages.length > 0) {
            this.send(ws, {
              type: "past_history",
              claudeSessionId: session.claudeSessionId ?? msg.sessionId,
              sessionId: msg.sessionId,
              messages: splitPastHistory.pastMessages,
            } as Record<string, unknown>);
          }
          this.send(ws, {
            type: "history",
            messages: [...splitPastHistory.historyMessages, ...session.history],
            sessionId: msg.sessionId,
          } as Record<string, unknown>);
          if (session.provider === "codex") {
            this.sendCodexCurrentSettings(ws, msg.sessionId, session);
          }
          const activityAt = this.sessionActivityAtForClient(ws, msg.sessionId);
          this.send(ws, {
            type: "status",
            status: session.status,
            sessionId: msg.sessionId,
            ...(activityAt ? { activityAt } : {}),
          } as Record<string, unknown>);
          if (session.provider === "codex") {
            this.sendCodexQueueState(ws, msg.sessionId, session);
            this.sendCodexGoalState(ws, msg.sessionId, session);
          }

          this.sendCachedCommands(ws, msg.sessionId, session);
        } else {
          this.send(ws, {
            type: "error",
            message: `Session ${msg.sessionId} not found`,
            errorCode: "session_not_found",
            sessionId: msg.sessionId,
          });
        }
        break;
      }

      case "resolve_session_link": {
        const provider = msg.provider ?? "claude";
        let progressSequence = 0;
        const sendProgress = (
          stage: SessionLinkProgressStage,
          counts: { completedUnits?: number; totalUnits?: number } = {},
        ): void => {
          this.sendSessionLinkProgress(ws, {
            requestId: msg.requestId,
            sourceSessionId: msg.sessionId,
            generation: msg.sessionLinkGeneration,
            operation: "resolve",
            stage,
            sequence: ++progressSequence,
            ...counts,
          });
        };
        sendProgress("request_accepted");
        const activeSession = this.sessionManager
          .list()
          .find(
            (session) =>
              session.provider === provider &&
              (session.id === msg.sessionId ||
                session.claudeSessionId === msg.sessionId),
          );
        sendProgress("runtime_checked", {
          completedUnits: activeSession ? 1 : 0,
          totalUnits: 1,
        });
        if (activeSession) {
          sendProgress("resolution_ready");
          this.send(ws, {
            type: "session_link_resolution",
            requestId: msg.requestId,
            sourceSessionId: msg.sessionId,
            status: "live",
            bridgeSessionId: activeSession.id,
            provider,
            ...(msg.sessionLinkGeneration !== undefined
              ? { sessionLinkGeneration: msg.sessionLinkGeneration }
              : {}),
          });
          break;
        }

        try {
          sendProgress("catalog_scanning");
          let lastCatalogProgressAt = 0;
          const { sessions } = await getAllRecentSessions({
            limit: 1,
            provider,
            sessionId: msg.sessionId,
            archivedSessionIds: this.archiveStore.archivedIds(
              provider,
              provider === "codex" ? this.codexSourceId : undefined,
            ),
            onProgress: ({ completedUnits, totalUnits }) => {
              const now = Date.now();
              if (
                now - lastCatalogProgressAt < 500 &&
                completedUnits !== totalUnits
              ) {
                return;
              }
              lastCatalogProgressAt = now;
              sendProgress("catalog_scanning", {
                completedUnits,
                ...(totalUnits !== undefined ? { totalUnits } : {}),
              });
            },
          });
          const recentSession = sessions[0];
          const scopedRecentSession =
            recentSession && provider === "codex"
              ? { ...recentSession, codexSourceId: this.codexSourceId }
              : recentSession;
          sendProgress("catalog_scanned", {
            completedUnits: scopedRecentSession ? 1 : 0,
            totalUnits: 1,
          });
          sendProgress("resolution_ready");
          this.send(ws, {
            type: "session_link_resolution",
            requestId: msg.requestId,
            sourceSessionId: msg.sessionId,
            status: scopedRecentSession ? "recent" : "unavailable",
            provider,
            ...(scopedRecentSession
              ? { recentSession: scopedRecentSession }
              : {}),
            ...(msg.sessionLinkGeneration !== undefined
              ? { sessionLinkGeneration: msg.sessionLinkGeneration }
              : {}),
          } as Record<string, unknown>);
        } catch (err) {
          console.error("[ws] Failed to resolve session link:", err);
          this.send(ws, {
            type: "session_link_resolution",
            requestId: msg.requestId,
            sourceSessionId: msg.sessionId,
            status: "unavailable",
            provider,
            ...(msg.sessionLinkGeneration !== undefined
              ? { sessionLinkGeneration: msg.sessionLinkGeneration }
              : {}),
          });
        }
        break;
      }

      case "get_history_delta": {
        const session = this.sessionManager.get(msg.sessionId);
        if (session?.provider === "codex") {
          const result = this.sessionManager.getHistorySince(
            msg.sessionId,
            msg.sinceSeq,
          );
          if (!result) {
            this.send(ws, {
              type: "error",
              message: `Session ${msg.sessionId} not found`,
            });
            break;
          }

          if (
            this.shouldResetCodexHistoryDelta(
              session,
              msg.sinceSeq,
              result.kind,
            )
          ) {
            await this.sendCodexCanonicalHistorySnapshot(
              ws,
              msg.sessionId,
              session,
            );
            break;
          }

          this.send(ws, {
            type:
              result.kind === "snapshot" ? "history_snapshot" : "history_delta",
            sessionId: msg.sessionId,
            fromSeq: result.fromSeq,
            toSeq: result.toSeq,
            messages: result.entries,
            status: session.status,
            ...(result.kind === "snapshot" ? { reason: result.reason } : {}),
          } as ServerMessage);
          this.sendCodexCurrentSettings(ws, msg.sessionId, session);
          this.sendCodexQueueState(ws, msg.sessionId, session);
          this.sendCodexGoalState(ws, msg.sessionId, session);
          break;
        }

        if (session) {
          const result = this.sessionManager.getHistorySince(
            msg.sessionId,
            msg.sinceSeq,
          );
          if (!result) {
            this.send(ws, {
              type: "error",
              message: `Session ${msg.sessionId} not found`,
            });
            break;
          }
          if (session.pastMessages && session.pastMessages.length > 0) {
            const splitPastHistory =
              await this.splitPastHistoryMessages(session);
            if (splitPastHistory.pastMessages.length > 0) {
              this.send(ws, {
                type: "past_history",
                claudeSessionId: session.claudeSessionId ?? msg.sessionId,
                sessionId: msg.sessionId,
                messages: splitPastHistory.pastMessages,
              } as Record<string, unknown>);
            }
          }
          this.send(ws, {
            type:
              result.kind === "snapshot" ? "history_snapshot" : "history_delta",
            sessionId: msg.sessionId,
            fromSeq: result.fromSeq,
            toSeq: result.toSeq,
            messages: result.entries,
            status: session.status,
            ...(result.kind === "snapshot" ? { reason: result.reason } : {}),
          } as ServerMessage);
        } else {
          this.send(ws, {
            type: "error",
            message: `Session ${msg.sessionId} not found`,
          });
        }
        break;
      }

      case "get_history_page": {
        const session = this.sessionManager.get(msg.sessionId);
        if (!session) {
          this.send(ws, {
            type: "history_page",
            requestId: msg.requestId,
            sessionId: msg.sessionId,
            beforeSeq: msg.beforeSeq,
            nextBeforeSeq: msg.beforeSeq,
            hasMore: false,
            messages: [],
            error: `Session ${msg.sessionId} not found`,
          });
          break;
        }
        try {
          const entries =
            session.provider === "codex"
              ? await this.codexCanonicalHistoryEntries(session)
              : session.historyEntries;
          if (!entries) {
            this.send(ws, {
              type: "history_page",
              requestId: msg.requestId,
              sessionId: msg.sessionId,
              beforeSeq: msg.beforeSeq,
              nextBeforeSeq: msg.beforeSeq,
              hasMore: false,
              messages: [],
            });
            break;
          }
          const cursorIndex = msg.beforeCursor
            ? this.historyPageCursorIndex(entries, msg.beforeCursor)
            : -1;
          const eligible =
            cursorIndex >= 0
              ? entries.slice(0, cursorIndex)
              : entries.filter((entry) => entry.seq < msg.beforeSeq);
          const visibleEntries = selectTurnAwareHistoryWindow(eligible);
          const nextBeforeSeq =
            visibleEntries[0]?.seq ?? eligible[0]?.seq ?? msg.beforeSeq;
          const firstVisibleIndex =
            visibleEntries[0] === undefined
              ? -1
              : eligible.indexOf(visibleEntries[0]);
          this.send(ws, {
            type: "history_page",
            requestId: msg.requestId,
            sessionId: msg.sessionId,
            beforeSeq: msg.beforeSeq,
            nextBeforeSeq,
            ...(visibleEntries[0]
              ? { nextBeforeCursor: this.historyPageCursor(visibleEntries[0]) }
              : {}),
            hasMore: firstVisibleIndex > 0,
            messages: visibleEntries,
          });
        } catch (error) {
          this.send(ws, {
            type: "history_page",
            requestId: msg.requestId,
            sessionId: msg.sessionId,
            beforeSeq: msg.beforeSeq,
            nextBeforeSeq: msg.beforeSeq,
            hasMore: false,
            messages: [],
            error: `Failed to read history page: ${
              error instanceof Error ? error.message : String(error)
            }`,
          });
        }
        break;
      }

      case "get_history_tool_details": {
        const session = this.sessionManager.get(msg.sessionId);
        if (!session) {
          this.send(ws, {
            type: "history_tool_details",
            requestId: msg.requestId,
            sessionId: msg.sessionId,
            details: [],
            error: `Session ${msg.sessionId} not found`,
          });
          break;
        }
        try {
          const details =
            session.provider === "codex"
              ? await this.codexHistoryToolDetails(session, msg.toolUseIds)
              : this.historyToolDetails(session.historyEntries, msg.toolUseIds);
          this.send(ws, {
            type: "history_tool_details",
            requestId: msg.requestId,
            sessionId: msg.sessionId,
            details,
          });
        } catch (error) {
          this.send(ws, {
            type: "history_tool_details",
            requestId: msg.requestId,
            sessionId: msg.sessionId,
            details: [],
            error: `Failed to read history tool details: ${
              error instanceof Error ? error.message : String(error)
            }`,
          });
        }
        break;
      }

      case "refresh_branch": {
        const session = this.sessionManager.get(msg.sessionId);
        if (session) {
          const cwd = session.worktreePath ?? session.projectPath;
          let branch = "";
          try {
            branch = execFileSync(
              "git",
              ["rev-parse", "--abbrev-ref", "HEAD"],
              {
                cwd,
                encoding: "utf-8",
              },
            ).trim();
          } catch {
            /* not a git repo */
          }
          // Update stored branch so future session_list responses are also current
          session.gitBranch = branch;
          this.send(ws, {
            type: "branch_update",
            sessionId: msg.sessionId,
            branch,
          });
        } else {
          this.send(ws, {
            type: "error",
            message: `Session ${msg.sessionId} not found`,
          });
        }
        break;
      }

      case "get_debug_bundle": {
        const session = this.sessionManager.get(msg.sessionId);
        if (!session) {
          this.send(ws, {
            type: "error",
            message: `Session ${msg.sessionId} not found`,
          });
          return;
        }

        const emitBundle = (diff: string, diffError?: string): void => {
          const traceLimit =
            msg.traceLimit ?? BridgeWebSocketServer.MAX_DEBUG_EVENTS;
          const trace = this.getDebugEvents(msg.sessionId, traceLimit);
          const generatedAt = new Date().toISOString();
          const includeDiff = msg.includeDiff !== false;
          const bundlePayload: Record<string, unknown> = {
            type: "debug_bundle",
            sessionId: msg.sessionId,
            generatedAt,
            session: {
              id: session.id,
              provider: session.provider,
              status: session.status,
              projectPath: session.projectPath,
              worktreePath: session.worktreePath,
              worktreeBranch: session.worktreeBranch,
              claudeSessionId: session.claudeSessionId,
              createdAt: session.createdAt.toISOString(),
              lastActivityAt: session.lastActivityAt.toISOString(),
            },
            pastMessageCount: session.pastMessages?.length ?? 0,
            historySummary: this.buildHistorySummary(session.history),
            debugTrace: trace,
            traceFilePath: this.debugTraceStore.getTraceFilePath(msg.sessionId),
            reproRecipe: this.buildReproRecipe(
              session,
              traceLimit,
              includeDiff,
            ),
            agentPrompt: this.buildAgentPrompt(session),
            diff,
            diffError,
          };
          const savedBundlePath = this.debugTraceStore.getBundleFilePath(
            msg.sessionId,
            generatedAt,
          );
          bundlePayload.savedBundlePath = savedBundlePath;
          this.debugTraceStore.saveBundleAtPath(savedBundlePath, bundlePayload);
          this.send(ws, bundlePayload);
        };

        if (msg.includeDiff === false) {
          emitBundle("");
          break;
        }

        const cwd = session.worktreePath ?? session.projectPath;
        this.collectGitDiff(cwd, ({ diff, error }) => {
          emitBundle(diff, error);
        });
        break;
      }

      case "get_usage": {
        fetchAllUsage()
          .then((providers) => {
            this.send(ws, { type: "usage_result", providers } as Record<
              string,
              unknown
            >);
          })
          .catch((err) => {
            this.send(ws, {
              type: "error",
              message: `Failed to fetch usage: ${err}`,
            });
          });
        break;
      }

      case "list_recent_sessions": {
        const startsNewQuery =
          msg.requestScope == null || msg.requestScope === "list";
        const currentRequestId = this.recentSessionsRequestIds.get(ws) ?? 0;
        const requestId = startsNewQuery
          ? currentRequestId + 1
          : currentRequestId;
        if (startsNewQuery) {
          this.recentSessionsRequestIds.set(ws, requestId);
        }
        this.listRecentSessions(msg)
          .then(({ sessions, hasMore }) => {
            // Drop stale responses when rapid filter switches cause out-of-order completion
            if (requestId !== (this.recentSessionsRequestIds.get(ws) ?? 0)) {
              return;
            }
            this.send(ws, {
              type: "recent_sessions",
              sessions: this.attachCodexSourceToRecentSessions(sessions),
              hasMore,
              limit: msg.limit,
              offset: msg.offset,
              projectPath: msg.projectPath,
              requestScope: msg.requestScope,
              requestId: msg.requestId,
              queryGeneration: msg.queryGeneration,
              catalogRevision: this.sessionCatalogMonitor.currentRevision ?? 0,
              provider: msg.provider,
              namedOnly: msg.namedOnly,
              searchQuery: msg.searchQuery,
            } as Record<string, unknown>);
          })
          .catch((err) => {
            if (requestId !== (this.recentSessionsRequestIds.get(ws) ?? 0)) {
              return;
            }
            this.send(ws, {
              type: "error",
              message: `Failed to list recent sessions: ${err}`,
            });
          });
        break;
      }

      case "archive_session": {
        void this.handleArchiveSession(msg, ws);
        break;
      }

      case "list_archived_sessions": {
        void this.handleListArchivedSessions(msg.requestId, ws);
        break;
      }

      case "unarchive_session": {
        void this.handleUnarchiveSession(msg, ws);
        break;
      }

      case "delete_session": {
        void this.handleDeleteSession(msg, ws);
        break;
      }

      case "resume_session": {
        const resumeStartedAt = Date.now();
        console.log(
          `[ws] resume_session: sessionId=${msg.sessionId} projectPath=${msg.projectPath} provider=${msg.provider ?? "claude"}`,
        );
        const resumeProjectPath = resolvePlatformPath(
          msg.projectPath,
          this.platform,
        );
        const provider = msg.provider ?? "claude";
        let resumeProgressSequence = 0;
        let sharedResumeOperation:
          | { key: string; operationId: string }
          | undefined;
        const sendResumeProgress = (
          stage: SessionLinkProgressStage,
          counts: { completedUnits?: number; totalUnits?: number } = {},
        ): void => {
          if (sharedResumeOperation) {
            this.sendResumeOperationProgress(
              sharedResumeOperation.key,
              sharedResumeOperation.operationId,
              stage,
              counts,
            );
            return;
          }
          this.sendSessionLinkProgress(ws, {
            requestId: msg.resumeRequestId,
            sourceSessionId: msg.sessionId,
            generation: msg.sessionLinkGeneration,
            operation: "resume",
            stage,
            sequence: ++resumeProgressSequence,
            ...counts,
          });
        };
        sendResumeProgress("request_accepted");
        if (
          provider === "codex" &&
          msg.codexSourceId !== undefined &&
          msg.codexSourceId !== this.codexSourceId
        ) {
          this.sendResumeFailed(ws, {
            provider,
            sourceSessionId: msg.sessionId,
            projectPath: resumeProjectPath,
            resumeRequestId: msg.resumeRequestId,
          });
          this.send(ws, {
            type: "error",
            message:
              "This Codex thread belongs to a different configured source.",
            errorCode: "codex_source_mismatch",
            sessionId: msg.sessionId,
          });
          break;
        }
        if (!this.isExistingProjectPathAllowed(resumeProjectPath)) {
          this.sendResumeFailed(ws, {
            provider,
            sourceSessionId: msg.sessionId,
            projectPath: resumeProjectPath,
            resumeRequestId: msg.resumeRequestId,
          });
          this.send(ws, this.buildPathNotAllowedError(msg.projectPath));
          break;
        }
        const normalizedCodexPermissionsMode =
          provider === "codex"
            ? normalizeCodexPermissionsMode(msg.codexPermissionsMode)
            : undefined;
        const requestedCodexPermissionsMode =
          this.codexAutoReviewDisabled &&
          normalizedCodexPermissionsMode === "autoReview"
            ? "default"
            : normalizedCodexPermissionsMode;
        const codexPermissionSettings = requestedCodexPermissionsMode
          ? codexSettingsFromPermissionsMode(requestedCodexPermissionsMode)
          : undefined;
        const requestedApprovalPolicy =
          msg.approvalPolicy ??
          (msg.executionMode == null
            ? undefined
            : msg.executionMode === "fullAccess"
              ? "never"
              : "on-request");
        const codexApprovalPolicy =
          provider === "codex"
            ? requestedCodexPermissionsMode
              ? codexPermissionSettings?.approvalPolicy
              : requestedApprovalPolicy === undefined
                ? undefined
                : normalizeCodexApprovalPolicy(requestedApprovalPolicy)
            : undefined;
        const executionMode = deriveExecutionMode({
          provider,
          permissionMode: msg.permissionMode,
          executionMode: msg.executionMode,
          approvalPolicy: codexApprovalPolicy,
        });
        const planMode = derivePlanMode({
          permissionMode: msg.permissionMode,
          planMode: msg.planMode,
        });
        const legacyPermissionMode = modesToLegacyPermissionMode(
          provider,
          executionMode,
          planMode,
        );
        const claudePermissionMode =
          provider === "claude"
            ? ((msg.permissionMode as
                | "default"
                | "auto"
                | "acceptEdits"
                | "bypassPermissions"
                | "plan"
                | undefined) ?? legacyPermissionMode)
            : legacyPermissionMode;
        const sessionRefId = msg.sessionId;
        // Resume flow: keep past history in SessionInfo and deliver it only
        // via get_history(sessionId) to avoid duplicate/missed replay races.
        if (provider === "codex") {
          const wtMapping = this.worktreeStore.get(sessionRefId);
          const effectiveProjectPath = resolvePlatformPath(
            wtMapping?.projectPath ?? resumeProjectPath,
            this.platform,
          );

          let worktreeOpts:
            | {
                useWorktree?: boolean;
                worktreeBranch?: string;
                existingWorktreePath?: string;
              }
            | undefined;
          if (wtMapping) {
            if (worktreeExists(wtMapping.worktreePath)) {
              worktreeOpts = {
                existingWorktreePath: wtMapping.worktreePath,
                worktreeBranch: wtMapping.worktreeBranch,
              };
            } else {
              worktreeOpts = {
                useWorktree: true,
                worktreeBranch: wtMapping.worktreeBranch,
              };
            }
          }

          const resumeOperation = this.beginResumeOperation({
            ws,
            provider: "codex",
            sourceSessionId: sessionRefId,
            projectPath: effectiveProjectPath,
            request: msg,
            initialProgressSequence: resumeProgressSequence,
          });
          if (!resumeOperation.isOwner) break;
          sharedResumeOperation = resumeOperation;

          let releaseThreadOperation: (() => void) | undefined;
          let historyMetrics = summarizeResumeHistory([]);
          let historyLoadMs = 0;
          let historyLoaded = false;
          let historyStartedAt = 0;
          let sessionCreateMs = 0;
          let nameLoadMs = 0;
          try {
            sendResumeProgress("resume_lock_waiting");
            releaseThreadOperation =
              await this.acquireCodexThreadOperation(sessionRefId);
            sendResumeProgress("resume_lock_acquired");

            const runningSession = this.findRunningCodexSession(sessionRefId);
            if (runningSession) {
              const createdMessage = this.buildCodexResumeResult(
                runningSession,
                sessionRefId,
                msg.resumeRequestId,
              );
              sendResumeProgress("ready");
              this.completeResumeOperation(
                resumeOperation.key,
                resumeOperation.operationId,
                runningSession.id,
                createdMessage,
              );
              this.broadcastSessionList();
              console.info(
                formatResumePerformanceLog({
                  provider: "codex",
                  sourceSessionId: sessionRefId,
                  outcome: "success",
                  ...historyMetrics,
                  historyLoadMs,
                  sessionCreateMs,
                  nameLoadMs,
                  totalMs: Date.now() - resumeStartedAt,
                }),
              );
              break;
            }

            await this.requireArchiveStoreReady();
            if (
              this.archiveStore.isArchived(
                sessionRefId,
                "codex",
                this.codexSourceId,
              )
            ) {
              throw new Error(
                "The Codex thread is archived. Restore it before resuming.",
              );
            }

            const indexedMetadata = (
              await getCodexSessionIndexMetadata([sessionRefId], {
                authoritativeCodexSettings: true,
              })
            ).get(sessionRefId);
            const indexedSettings = indexedMetadata?.codexSettings;
            const requestedProfile = msg.profile ?? indexedSettings?.profile;
            const additionalWritableRoots =
              this.normalizeAdditionalWritableRoots(
                msg.additionalWritableRoots ??
                  indexedSettings?.additionalWritableRoots,
                effectiveProjectPath,
              );
            if (additionalWritableRoots.deniedRoot) {
              const pathError = this.buildPathNotAllowedError(
                additionalWritableRoots.deniedRoot,
              );
              this.failResumeOperation(
                resumeOperation.key,
                resumeOperation.operationId,
                pathError.message,
              );
              break;
            }

            const effectiveProfile = requestedProfile
              ? await this.resolveCodexResumeProfile(
                  requestedProfile,
                  sessionRefId,
                  effectiveProjectPath,
                )
              : undefined;
            historyStartedAt = Date.now();
            sendResumeProgress("history_reading");
            const pastMessages = await this.getCodexThreadHistory(
              sessionRefId,
              effectiveProjectPath,
            );
            historyLoadMs = Date.now() - historyStartedAt;
            historyLoaded = true;
            historyMetrics = summarizeResumeHistory(pastMessages);
            sendResumeProgress("history_read", {
              completedUnits: pastMessages.length,
            });

            const savedApprovalPolicy = indexedSettings?.approvalPolicy
              ? normalizeCodexApprovalPolicy(indexedSettings.approvalPolicy)
              : undefined;
            const savedApprovalsReviewer =
              indexedSettings?.approvalsReviewer === "auto_review" ||
              indexedSettings?.approvalsReviewer === "guardian_subagent" ||
              indexedSettings?.approvalsReviewer === "user"
                ? indexedSettings.approvalsReviewer
                : undefined;
            const savedSandboxMode = indexedSettings?.sandboxMode
              ? sandboxModeToInternal(indexedSettings.sandboxMode)
              : undefined;
            const createStartedAt = Date.now();
            sendResumeProgress("runtime_starting");
            const sessionId = this.sessionManager.create(
              effectiveProjectPath,
              undefined,
              pastMessages,
              worktreeOpts,
              "codex",
              this.withCodexAutoReviewPolicy({
                threadId: sessionRefId,
                profile: effectiveProfile,
                approvalPolicy: codexPermissionSettings
                  ? codexPermissionSettings.approvalPolicy
                  : (codexApprovalPolicy ?? savedApprovalPolicy),
                approvalsReviewer: codexPermissionSettings
                  ? codexPermissionSettings.approvalsReviewer
                  : ((msg.approvalsReviewer ??
                      savedApprovalsReviewer) as CodexStartOptions["approvalsReviewer"]),
                codexPermissionsMode:
                  codexPermissionSettings?.codexPermissionsMode,
                sandboxMode: codexPermissionSettings
                  ? codexPermissionSettings.sandboxMode
                  : msg.sandboxMode !== undefined
                    ? sandboxModeToInternal(msg.sandboxMode)
                    : savedSandboxMode,
                model: msg.model ?? indexedSettings?.model,
                modelReasoningEffort:
                  (msg.modelReasoningEffort as CodexStartOptions["modelReasoningEffort"]) ??
                  (indexedSettings?.modelReasoningEffort as CodexStartOptions["modelReasoningEffort"]),
                serviceTier: msg.serviceTier ?? indexedSettings?.serviceTier,
                networkAccessEnabled:
                  msg.networkAccessEnabled ??
                  indexedSettings?.networkAccessEnabled,
                webSearchMode:
                  (msg.webSearchMode as "disabled" | "cached" | "live") ??
                  (indexedSettings?.webSearchMode as
                    "disabled" | "cached" | "live" | undefined),
                additionalWritableRoots: additionalWritableRoots.roots,
                collaborationMode: planMode
                  ? ("plan" as const)
                  : ("default" as const),
              }),
            );
            sessionCreateMs = Date.now() - createStartedAt;
            const createdSession = this.sessionManager.get(sessionId);
            if (!createdSession) {
              throw new Error(
                `Bridge session was not registered: ${sessionId}`,
              );
            }
            createdSession.codexInitialHistoryPending = true;
            createdSession.forkedFromThreadId =
              indexedMetadata?.forkedFromThreadId;

            const nameStartedAt = Date.now();
            sendResumeProgress("metadata_loading");
            await this.loadAndSetSessionName(
              createdSession,
              "codex",
              effectiveProjectPath,
              sessionRefId,
            );
            nameLoadMs = Date.now() - nameStartedAt;

            const createdMessage = this.buildCodexResumeResult(
              createdSession,
              sessionRefId,
              msg.resumeRequestId,
            );
            sendResumeProgress("ready");
            if (
              !this.completeResumeOperation(
                resumeOperation.key,
                resumeOperation.operationId,
                sessionId,
                createdMessage,
              )
            ) {
              this.sessionManager.destroy(sessionId);
              break;
            }

            this.broadcastSessionList();
            this.debugEvents.set(sessionId, []);
            this.recordDebugEvent(sessionId, {
              direction: "internal",
              channel: "bridge",
              type: "session_resumed",
              detail: `provider=codex thread=${sessionRefId}`,
            });
            this.projectHistory?.addProject(effectiveProjectPath);
            console.info(
              formatResumePerformanceLog({
                provider: "codex",
                sourceSessionId: sessionRefId,
                outcome: "success",
                ...historyMetrics,
                historyLoadMs,
                sessionCreateMs,
                nameLoadMs,
                totalMs: Date.now() - resumeStartedAt,
              }),
            );
          } catch (err) {
            if (!historyLoaded && historyStartedAt > 0) {
              historyLoadMs = Date.now() - historyStartedAt;
            }
            console.info(
              formatResumePerformanceLog({
                provider: "codex",
                sourceSessionId: sessionRefId,
                outcome: "failed",
                ...historyMetrics,
                historyLoadMs,
                sessionCreateMs,
                nameLoadMs,
                totalMs: Date.now() - resumeStartedAt,
              }),
            );
            this.failResumeOperation(
              resumeOperation.key,
              resumeOperation.operationId,
              `Failed to load Codex session history: ${codexErrorMessage(err)}`,
            );
          } finally {
            releaseThreadOperation?.();
          }
          break;
        }

        const claudeSessionId = sessionRefId;
        // Look up worktree mapping for this Claude session
        const wtMapping = this.worktreeStore.get(claudeSessionId);
        let worktreeOpts:
          | {
              useWorktree?: boolean;
              worktreeBranch?: string;
              existingWorktreePath?: string;
            }
          | undefined;
        if (wtMapping) {
          if (worktreeExists(wtMapping.worktreePath)) {
            // Worktree exists — reuse it directly
            worktreeOpts = {
              existingWorktreePath: wtMapping.worktreePath,
              worktreeBranch: wtMapping.worktreeBranch,
            };
          } else {
            // Worktree was deleted — recreate on the same branch
            worktreeOpts = {
              useWorktree: true,
              worktreeBranch: wtMapping.worktreeBranch,
            };
          }
        }

        const resumeOperation = this.beginResumeOperation({
          ws,
          provider: "claude",
          sourceSessionId: claudeSessionId,
          projectPath: resumeProjectPath,
          request: msg,
          initialProgressSequence: resumeProgressSequence,
        });
        if (!resumeOperation.isOwner) break;
        sharedResumeOperation = resumeOperation;

        sendResumeProgress("resume_lock_acquired");
        const historyStartedAt = Date.now();
        let historyMetrics = summarizeResumeHistory([]);
        let historyLoadMs = 0;
        let historyLoaded = false;
        let sessionCreateMs = 0;
        sendResumeProgress("history_reading");
        let lastHistoryProgressAt = 0;
        getSessionHistory(claudeSessionId, {
          onProgress: ({ completedUnits }) => {
            const now = Date.now();
            if (now - lastHistoryProgressAt < 500) return;
            lastHistoryProgressAt = now;
            sendResumeProgress("history_reading", { completedUnits });
          },
        })
          .then((pastMessages) => {
            historyLoadMs = Date.now() - historyStartedAt;
            historyLoaded = true;
            historyMetrics = summarizeResumeHistory(pastMessages);
            sendResumeProgress("history_read", {
              completedUnits: pastMessages.length,
            });
            const createStartedAt = Date.now();
            sendResumeProgress("runtime_starting");
            const {
              sessionId,
              permissionMode: effectivePermissionMode,
              executionMode: effectiveExecutionMode,
              planMode: effectivePlanMode,
              usedFallback: autoFallbackUsed,
            } = this.createClaudeSessionWithFallback({
              projectPath: resumeProjectPath,
              options: {
                sessionId: claudeSessionId,
                permissionMode: claudePermissionMode,
                model: msg.model,
                effort: msg.effort,
                maxTurns: msg.maxTurns,
                maxBudgetUsd: msg.maxBudgetUsd,
                fallbackModel: msg.fallbackModel,
                forkSession: msg.forkSession,
                persistSession: msg.persistSession,
                ...(msg.sandboxMode
                  ? { sandboxEnabled: msg.sandboxMode === "on" }
                  : {}),
              },
              pastMessages,
              worktreeOptions: worktreeOpts,
            });
            sessionCreateMs = Date.now() - createStartedAt;
            const createdSession = this.sessionManager.get(sessionId);
            const cached = this.sessionManager.getCachedCommands(
              "claude",
              createdSession?.worktreePath ?? resumeProjectPath,
            );
            const nameStartedAt = Date.now();
            sendResumeProgress("metadata_loading");
            const finishResume = () => {
              const createdMessage = {
                ...this.buildSessionCreatedMessage({
                  sessionId,
                  provider: "claude",
                  projectPath: resumeProjectPath,
                  session: createdSession,
                  permissionMode: effectivePermissionMode,
                  executionMode: effectiveExecutionMode,
                  planMode: effectivePlanMode,
                  sandboxMode: msg.sandboxMode,
                  resumeRequestId: msg.resumeRequestId,
                  ...(cached
                    ? {
                        slashCommands: cached.slashCommands,
                        skills: cached.skills,
                        ...(cached.skillMetadata
                          ? { skillMetadata: cached.skillMetadata }
                          : {}),
                        apps: cached.apps,
                        ...(cached.appMetadata
                          ? { appMetadata: cached.appMetadata }
                          : {}),
                        plugins: cached.plugins,
                        ...(cached.pluginMetadata
                          ? { pluginMetadata: cached.pluginMetadata }
                          : {}),
                      }
                    : {}),
                }),
                claudeSessionId,
              } as SystemServerMessage;
              sendResumeProgress("ready");
              if (
                !this.completeResumeOperation(
                  resumeOperation.key,
                  resumeOperation.operationId,
                  sessionId,
                  createdMessage,
                )
              ) {
                this.sessionManager.destroy(sessionId);
                return;
              }
              this.broadcastSessionList();
              if (autoFallbackUsed) {
                this.sendTip(
                  ws,
                  sessionId,
                  "auto_mode_fallback_default",
                  createdSession,
                );
              }
              console.info(
                formatResumePerformanceLog({
                  provider: "claude",
                  sourceSessionId: claudeSessionId,
                  outcome: "success",
                  ...historyMetrics,
                  historyLoadMs,
                  sessionCreateMs,
                  nameLoadMs: Date.now() - nameStartedAt,
                  totalMs: Date.now() - resumeStartedAt,
                }),
              );
            };
            void this.loadAndSetSessionName(
              createdSession,
              "claude",
              resumeProjectPath,
              claudeSessionId,
            ).then(finishResume, (err) => {
              console.error("[ws] Failed to load resumed session name:", err);
              finishResume();
            });
            this.debugEvents.set(sessionId, []);
            this.recordDebugEvent(sessionId, {
              direction: "internal",
              channel: "bridge",
              type: "session_resumed",
              detail: `provider=claude session=${claudeSessionId}`,
            });
            this.projectHistory?.addProject(resumeProjectPath);
          })
          .catch((err) => {
            if (!historyLoaded) {
              historyLoadMs = Date.now() - historyStartedAt;
            }
            console.info(
              formatResumePerformanceLog({
                provider: "claude",
                sourceSessionId: claudeSessionId,
                outcome: "failed",
                ...historyMetrics,
                historyLoadMs,
                sessionCreateMs,
                nameLoadMs: 0,
                totalMs: Date.now() - resumeStartedAt,
              }),
            );
            this.failResumeOperation(
              resumeOperation.key,
              resumeOperation.operationId,
              `Failed to load session history: ${err}`,
            );
          });
        break;
      }

      case "list_gallery": {
        if (this.galleryStore) {
          const runtimeSession = msg.sessionId
            ? this.sessionManager.get(msg.sessionId)
            : undefined;
          const images = this.galleryStore.list({
            projectPath: msg.project,
            sessionId: msg.sessionId,
            providerSessionId: runtimeSession
              ? this.providerSessionIdForSession(runtimeSession)
              : undefined,
          });
          this.send(ws, { type: "gallery_list", images } as Record<
            string,
            unknown
          >);
        } else {
          this.send(ws, { type: "gallery_list", images: [] } as Record<
            string,
            unknown
          >);
        }
        break;
      }

      case "get_message_images": {
        void extractMessageImages(msg.claudeSessionId, msg.messageUuid)
          .then((images) => {
            const refs: Array<{ id: string; url: string; mimeType: string }> =
              [];
            if (this.imageStore) {
              for (const img of images) {
                const ref = this.imageStore.registerFromBase64(
                  img.base64,
                  img.mimeType,
                );
                if (ref) refs.push(ref);
              }
            }
            this.send(ws, {
              type: "message_images_result",
              messageUuid: msg.messageUuid,
              images: refs,
            });
          })
          .catch((err) => {
            console.error("[ws] Failed to extract message images:", err);
            this.send(ws, {
              type: "message_images_result",
              messageUuid: msg.messageUuid,
              images: [],
            });
          });
        break;
      }

      case "interrupt": {
        const session = this.resolveSession(msg.sessionId);
        if (!session) {
          this.send(ws, { type: "error", message: "No active session." });
          return;
        }
        session.process.interrupt();
        break;
      }

      case "list_project_history": {
        const projects = this.projectHistory?.getProjects() ?? [];
        this.send(ws, { type: "project_history", projects });
        break;
      }

      case "remove_project_history": {
        this.projectHistory?.removeProject(msg.projectPath);
        const projects = this.projectHistory?.getProjects() ?? [];
        this.send(ws, { type: "project_history", projects });
        break;
      }

      case "read_artifact_source": {
        const sendFileContent = (
          response: Omit<
            FileContentServerMessage,
            "type" | "requestId" | "filePath"
          >,
        ): void => {
          this.send(ws, {
            type: "file_content",
            requestId: msg.requestId,
            filePath: msg.filePath,
            ...response,
          });
        };
        const session = this.sessionManager.get(msg.sessionId);
        if (!session) {
          sendFileContent({
            content: "",
            error: "Session not found",
            errorCode: "session_not_found",
          });
          break;
        }
        const ownerId = this.codexThreadIdForSession(session);
        if (!ownerId || !this.artifactManager) {
          sendFileContent({
            content: "",
            error: "Artifact source reading is unavailable",
            errorCode: "artifact_unavailable",
          });
          break;
        }
        if (this.activeArtifactSourceReads.has(ws)) {
          sendFileContent({
            content: "",
            error: "Another artifact source read is already in progress.",
            errorCode: "artifact_source_busy",
          });
          break;
        }
        this.activeArtifactSourceReads.add(ws);

        void (async () => {
          let opened: Awaited<
            ReturnType<ArtifactManager["openAuthorizedSource"]>
          > | null = null;
          try {
            opened = await this.artifactManager!.openAuthorizedSource({
              artifactId: msg.artifactId,
              ownerId,
              messageId: msg.messageId,
              candidateRoots: artifactCandidateRootsForSession(session),
              cwd: session.worktreePath ?? session.projectPath,
              projectRelativePath: msg.filePath,
            });

            const ext = extname(opened.filename).toLowerCase();
            if (BridgeWebSocketServer.FILE_PEEK_IMAGE_EXTENSIONS.has(ext)) {
              const mimeType = BridgeWebSocketServer.mimeTypeForExt(ext);
              if (opened.sizeBytes > BridgeWebSocketServer.MAX_IMAGE_SIZE) {
                sendFileContent({
                  kind: "image",
                  content: "",
                  mimeType,
                  sizeBytes: opened.sizeBytes,
                  error: "Image too large to preview. Maximum size is 5 MB.",
                  errorCode: "file_too_large",
                });
                return;
              }
              const buffer = await readStableBufferFromHandle(
                opened.handle,
                BridgeWebSocketServer.MAX_IMAGE_SIZE,
                "Image too large to preview. Maximum size is 5 MB.",
                opened.identity,
              );
              sendFileContent({
                kind: "image",
                content: "",
                base64: buffer.toString("base64"),
                mimeType,
                sizeBytes: buffer.length,
              });
              return;
            }

            const language = filePeekLanguage(opened.filename);
            if (opened.sizeBytes > FILE_PEEK_TEXT_MAX_BYTES) {
              sendFileContent({
                kind: "text",
                content: "",
                language,
                sizeBytes: opened.sizeBytes,
                error: "File is too large to preview. Maximum size is 8 MiB.",
                errorCode: "file_too_large",
              });
              return;
            }
            const maxLines = msg.maxLines ?? 5000;
            const text = await readStableTextFromHandle(
              opened.handle,
              maxLines,
              opened.identity,
            );
            sendFileContent({
              kind: "text",
              content: text.content,
              language,
              totalLines: text.totalLines,
              truncated: text.truncated,
              sizeBytes: opened.sizeBytes,
            });
          } catch (error) {
            if (error instanceof ArtifactResolveError) {
              sendFileContent({
                content: "",
                error: error.message,
                errorCode: error.code,
              });
            } else if (error instanceof FilePeekReadError) {
              sendFileContent({
                content: "",
                error: error.message,
                errorCode: error.code,
              });
            } else {
              sendFileContent({
                content: "",
                error: "Failed to read artifact source.",
                errorCode: "artifact_source_read_failed",
              });
            }
          } finally {
            await opened?.handle.close().catch(() => undefined);
            this.activeArtifactSourceReads.delete(ws);
          }
        })();
        break;
      }

      case "read_file": {
        const projectPath = resolvePlatformPath(msg.projectPath, this.platform);
        const absPath = resolvePlatformPathFrom(
          projectPath,
          msg.filePath,
          this.platform,
        );
        const sendFileContent = (
          response: Omit<
            FileContentServerMessage,
            "type" | "requestId" | "filePath"
          >,
        ): void => {
          this.send(ws, {
            type: "file_content",
            ...(msg.requestId ? { requestId: msg.requestId } : {}),
            filePath: msg.filePath,
            ...response,
          });
        };
        if (
          !this.isExistingProjectPathAllowed(projectPath) ||
          !this.isPathAllowed(absPath) ||
          !isPathWithinAllowedDirectory(absPath, projectPath, this.platform)
        ) {
          sendFileContent({ content: "", error: "Path not allowed" });
          break;
        }
        void (async () => {
          let handle: FileHandle | null = null;
          try {
            let fileStat;
            try {
              fileStat = await lstat(absPath);
            } catch {
              sendFileContent({ content: "", error: "File not found" });
              return;
            }
            let targetPath = "";
            if (fileStat.isSymbolicLink()) {
              try {
                targetPath = await readlink(absPath);
              } catch {
                // Best effort only; the user-facing error still works without it.
              }
            }
            if (fileStat.isDirectory()) {
              sendFileContent({
                content: "",
                error: "This path is a directory. Open a file instead.",
              });
              return;
            }

            let canonicalProjectPath: string;
            try {
              canonicalProjectPath = await realpath(projectPath);
            } catch {
              sendFileContent({ content: "", error: "Path not allowed" });
              return;
            }
            try {
              handle = await open(absPath, "r");
            } catch {
              sendFileContent({
                content: "",
                error:
                  fileStat.isSymbolicLink() && targetPath.length > 0
                    ? `This symbolic link points to a missing target: ${targetPath}`
                    : fileStat.isSymbolicLink()
                      ? "This symbolic link points to a missing target."
                      : "File not found",
              });
              return;
            }
            const openedStats = await handle.stat();
            if (openedStats.isDirectory()) {
              sendFileContent({
                content: "",
                error:
                  fileStat.isSymbolicLink() && targetPath.length > 0
                    ? `This symbolic link points to a directory (${targetPath}). Open the target directory instead.`
                    : fileStat.isSymbolicLink()
                      ? "This symbolic link points to a directory. Open the target directory instead."
                      : "This path is a directory. Open a file instead.",
              });
              return;
            }
            if (!openedStats.isFile()) {
              throw new FilePeekReadError(
                "not_regular_file",
                "This path is not a regular file.",
              );
            }

            let canonicalFilePath: string;
            let canonicalFileStats;
            try {
              canonicalFilePath = await realpath(absPath);
              canonicalFileStats = await stat(canonicalFilePath);
            } catch {
              throw new FilePeekReadError(
                "file_changed",
                "File changed while it was being opened.",
              );
            }
            if (!sameOpenFileStats(openedStats, canonicalFileStats)) {
              throw new FilePeekReadError(
                "file_changed",
                "File changed while it was being opened.",
              );
            }
            if (
              !isPathWithinAllowedDirectory(
                canonicalFilePath,
                canonicalProjectPath,
                this.platform,
              ) ||
              !(await this.isCanonicalPathAllowed(canonicalProjectPath)) ||
              !(await this.isCanonicalPathAllowed(canonicalFilePath))
            ) {
              sendFileContent({ content: "", error: "Path not allowed" });
              return;
            }
            const ext = extname(absPath).toLowerCase();
            if (BridgeWebSocketServer.FILE_PEEK_IMAGE_EXTENSIONS.has(ext)) {
              const mimeType = BridgeWebSocketServer.mimeTypeForExt(ext);
              if (openedStats.size > BridgeWebSocketServer.MAX_IMAGE_SIZE) {
                sendFileContent({
                  kind: "image",
                  content: "",
                  mimeType,
                  sizeBytes: openedStats.size,
                  error: "Image too large to preview. Maximum size is 5 MB.",
                });
                return;
              }
              const buf = await readStableBufferFromHandle(
                handle,
                BridgeWebSocketServer.MAX_IMAGE_SIZE,
                "Image too large to preview. Maximum size is 5 MB.",
                openedStats,
              );
              sendFileContent({
                kind: "image",
                content: "",
                base64: buf.toString("base64"),
                mimeType,
                sizeBytes: buf.length,
              });
              return;
            }
            const maxLines =
              typeof msg.maxLines === "number" && msg.maxLines > 0
                ? msg.maxLines
                : 5000;
            if (openedStats.size > FILE_PEEK_TEXT_MAX_BYTES) {
              sendFileContent({
                kind: "text",
                content: "",
                language: filePeekLanguage(absPath),
                error: "File is too large to preview. Maximum size is 8 MiB.",
                errorCode: "file_too_large",
              });
              return;
            }
            const text = await readStableTextFromHandle(
              handle,
              maxLines,
              openedStats,
            );
            sendFileContent({
              kind: "text",
              content: text.content,
              language: filePeekLanguage(absPath),
              totalLines: text.totalLines,
              truncated: text.truncated,
            });
          } catch (error) {
            if (error instanceof FilePeekReadError) {
              sendFileContent({
                content: "",
                error: error.message,
                errorCode: error.code,
              });
            } else {
              sendFileContent({
                content: "",
                error: "Failed to read file.",
              });
            }
          } finally {
            await handle?.close().catch(() => undefined);
          }
        })();
        break;
      }

      case "list_files": {
        if (!this.isExistingProjectPathAllowed(msg.projectPath)) {
          this.send(ws, {
            type: "file_list",
            files: [],
            projectPath: msg.projectPath,
            ...(msg.requestId ? { requestId: msg.requestId } : {}),
            error: this.buildPathNotAllowedError(msg.projectPath).message,
            errorCode: "path_not_allowed",
          });
          break;
        }
        void (async () => {
          try {
            const result = await listProjectFilesAndDirectoriesForClient(
              msg.projectPath,
              {
                maxEntries: this.fileListMaxEntries,
                maxBytes: this.fileListMaxBytes,
              },
            );
            this.send(ws, {
              type: "file_list",
              files: result.files,
              projectPath: msg.projectPath,
              ...(msg.requestId ? { requestId: msg.requestId } : {}),
              totalFiles: result.totalFiles,
              truncated: result.truncated,
            } as Record<string, unknown>);
          } catch (err) {
            const message = err instanceof Error ? err.message : String(err);
            this.send(ws, {
              type: "file_list",
              files: [],
              projectPath: msg.projectPath,
              ...(msg.requestId ? { requestId: msg.requestId } : {}),
              error: `Failed to list files: ${message}`,
              errorCode: "file_list_failed",
            });
          }
        })();
        break;
      }

      case "list_recordings": {
        if (!this.recordingStore) {
          this.send(ws, { type: "recording_list", recordings: [] } as Record<
            string,
            unknown
          >);
          break;
        }
        const store = this.recordingStore;
        void store.listRecordings().then(async (recordings) => {
          // First pass: extract info from JSONL for recordings missing firstPrompt
          // This covers both meta-less legacy recordings and new ones where sessions-index hasn't indexed yet
          await Promise.all(
            recordings.map(async (rec) => {
              const info = await store.extractInfoFromJsonl(rec.name);
              if (info.firstPrompt && !rec.firstPrompt)
                rec.firstPrompt = info.firstPrompt;
              if (info.lastPrompt && !rec.lastPrompt)
                rec.lastPrompt = info.lastPrompt;
              // Backfill meta for legacy recordings
              if (!rec.meta && (info.claudeSessionId || info.projectPath)) {
                rec.meta = {
                  bridgeSessionId: rec.name,
                  claudeSessionId: info.claudeSessionId,
                  projectPath: info.projectPath ?? "",
                  createdAt: rec.modified,
                };
              }
            }),
          );

          // Second pass: look up sessions-index for summaries (if claudeSessionIds available)
          const claudeIds = new Set<string>();
          const idToIdx = new Map<string, number[]>();
          for (let i = 0; i < recordings.length; i++) {
            const cid = recordings[i].meta?.claudeSessionId;
            if (cid) {
              claudeIds.add(cid);
              const arr = idToIdx.get(cid) ?? [];
              arr.push(i);
              idToIdx.set(cid, arr);
            }
          }

          if (claudeIds.size > 0) {
            const sessionInfo = await findSessionsByClaudeIds(claudeIds);
            for (const [cid, info] of sessionInfo) {
              const indices = idToIdx.get(cid) ?? [];
              for (const idx of indices) {
                if (info.summary) recordings[idx].summary = info.summary;
                if (info.firstPrompt)
                  recordings[idx].firstPrompt = info.firstPrompt;
                if (info.lastPrompt)
                  recordings[idx].lastPrompt = info.lastPrompt;
              }
            }
          }

          this.send(ws, { type: "recording_list", recordings } as Record<
            string,
            unknown
          >);
        });
        break;
      }

      case "get_recording": {
        if (!this.recordingStore) {
          this.send(ws, {
            type: "error",
            message: "Recording is not enabled on this server",
          });
          break;
        }
        void this.recordingStore
          .getRecordingContent(msg.sessionId)
          .then((content) => {
            if (content !== null) {
              this.send(ws, {
                type: "recording_content",
                sessionId: msg.sessionId,
                content,
              } as Record<string, unknown>);
            } else {
              this.send(ws, {
                type: "error",
                message: `Recording ${msg.sessionId} not found`,
              });
            }
          });
        break;
      }

      case "get_diff": {
        if (!this.isExistingProjectPathAllowed(msg.projectPath)) {
          this.sendGitPathNotAllowed(
            ws,
            msg.type,
            msg.projectPath,
            msg.requestId,
          );
          break;
        }
        // Echo the client's requestId (when given) so it can match this
        // response to its own request instead of consuming another
        // session's diff.
        const diffRequestId = msg.requestId;
        const sendDiffResult = (payload: Record<string, unknown>) => {
          this.send(
            ws,
            diffRequestId === undefined
              ? payload
              : { ...payload, requestId: diffRequestId },
          );
        };
        this.collectGitDiff(
          msg.projectPath,
          ({ diff, error }) => {
            if (error) {
              if (/not a git repository/i.test(error)) {
                sendDiffResult({
                  type: "diff_result",
                  diff: "",
                  error: "This project is not a git repository",
                  errorCode: "git_not_available",
                });
              } else {
                sendDiffResult({
                  type: "diff_result",
                  diff: "",
                  error: `Failed to get diff: ${error}`,
                });
              }
              return;
            }
            void this.collectImageChanges(msg.projectPath, diff)
              .then((imageChanges) => {
                if (imageChanges.length > 0) {
                  sendDiffResult({ type: "diff_result", diff, imageChanges });
                } else {
                  sendDiffResult({ type: "diff_result", diff });
                }
              })
              .catch((err) => {
                console.error("[ws] Failed to collect image changes:", err);
                sendDiffResult({ type: "diff_result", diff });
              });
          },
          msg.staged === true
            ? { staged: true }
            : msg.staged === false
              ? { unstaged: true }
              : undefined,
        );
        break;
      }

      case "get_diff_image": {
        if (
          !this.isExistingProjectPathAllowed(msg.projectPath) ||
          !this.isPathAllowed(resolve(msg.projectPath, msg.filePath))
        ) {
          this.send(ws, { type: "error", message: `Path not allowed` });
          break;
        }
        if (msg.version === "both") {
          void (async () => {
            try {
              const [oldResult, newResult] = await Promise.all([
                this.loadDiffImageAsync(msg.projectPath, msg.filePath, "old"),
                this.loadDiffImageAsync(msg.projectPath, msg.filePath, "new"),
              ]);
              const errors = [oldResult.error, newResult.error].filter(Boolean);
              this.send(ws, {
                type: "diff_image_result",
                projectPath: msg.projectPath,
                filePath: msg.filePath,
                version: "both" as const,
                oldBase64: oldResult.base64,
                newBase64: newResult.base64,
                mimeType: oldResult.mimeType ?? newResult.mimeType,
                ...(errors.length > 0 ? { error: errors.join("; ") } : {}),
                ...(msg.requestId ? { requestId: msg.requestId } : {}),
              });
            } catch {
              // WebSocket may have closed; ignore send errors.
            }
          })();
        } else {
          const version = msg.version as "old" | "new";
          void (async () => {
            try {
              const result = await this.loadDiffImageAsync(
                msg.projectPath,
                msg.filePath,
                version,
              );
              this.send(ws, {
                type: "diff_image_result",
                projectPath: msg.projectPath,
                filePath: msg.filePath,
                version,
                ...result,
                ...(msg.requestId ? { requestId: msg.requestId } : {}),
              });
            } catch {
              // WebSocket may have closed; ignore send errors.
            }
          })();
        }
        break;
      }

      case "list_worktrees": {
        if (!this.isExistingProjectPathAllowed(msg.projectPath)) {
          this.send(ws, this.buildPathNotAllowedError(msg.projectPath));
          break;
        }
        try {
          const worktrees = listWorktrees(msg.projectPath);
          const mainBranch = getMainBranch(msg.projectPath);
          this.send(ws, { type: "worktree_list", worktrees, mainBranch });
        } catch (err) {
          this.send(ws, {
            type: "error",
            message: `Failed to list worktrees: ${err}`,
          });
        }
        break;
      }

      case "remove_worktree": {
        if (!this.isExistingProjectPathAllowed(msg.projectPath)) {
          this.send(ws, this.buildPathNotAllowedError(msg.projectPath));
          break;
        }
        try {
          removeWorktree(msg.projectPath, msg.worktreePath);
          this.worktreeStore.deleteByWorktreePath(msg.worktreePath);
          this.send(ws, {
            type: "worktree_removed",
            worktreePath: msg.worktreePath,
          });
        } catch (err) {
          this.send(ws, {
            type: "error",
            message: `Failed to remove worktree: ${err}`,
          });
        }
        break;
      }

      // ---- Git Operations (Phase 1-3) ----

      case "git_stage": {
        if (!this.isExistingProjectPathAllowed(msg.projectPath)) {
          this.sendGitPathNotAllowed(ws, msg.type, msg.projectPath);
          break;
        }
        try {
          if (msg.files?.length) stageFiles(msg.projectPath, msg.files);
          if (msg.hunks?.length) stageHunks(msg.projectPath, msg.hunks);
          this.send(ws, {
            type: "git_stage_result",
            success: true,
            projectPath: msg.projectPath,
          });
        } catch (err) {
          this.send(ws, {
            type: "git_stage_result",
            success: false,
            projectPath: msg.projectPath,
            error: String(err),
          });
        }
        break;
      }

      case "git_unstage": {
        if (!this.isExistingProjectPathAllowed(msg.projectPath)) {
          this.sendGitPathNotAllowed(ws, msg.type, msg.projectPath);
          break;
        }
        try {
          unstageFiles(msg.projectPath, msg.files ?? []);
          this.send(ws, {
            type: "git_unstage_result",
            success: true,
            projectPath: msg.projectPath,
          });
        } catch (err) {
          this.send(ws, {
            type: "git_unstage_result",
            success: false,
            projectPath: msg.projectPath,
            error: String(err),
          });
        }
        break;
      }

      case "git_unstage_hunks": {
        if (!this.isExistingProjectPathAllowed(msg.projectPath)) {
          this.sendGitPathNotAllowed(ws, msg.type, msg.projectPath);
          break;
        }
        try {
          unstageHunks(msg.projectPath, msg.hunks);
          this.send(ws, {
            type: "git_unstage_hunks_result",
            success: true,
            projectPath: msg.projectPath,
          });
        } catch (err) {
          this.send(ws, {
            type: "git_unstage_hunks_result",
            success: false,
            projectPath: msg.projectPath,
            error: String(err),
          });
        }
        break;
      }

      case "git_commit": {
        if (!this.isExistingProjectPathAllowed(msg.projectPath)) {
          this.sendGitPathNotAllowed(ws, msg.type, msg.projectPath);
          break;
        }
        const session = msg.sessionId
          ? this.sessionManager.get(msg.sessionId)
          : undefined;
        try {
          const message =
            msg.autoGenerate === true
              ? (() => {
                  if (!msg.sessionId) {
                    throw new Error(
                      "git_commit with autoGenerate=true requires sessionId",
                    );
                  }
                  if (!session) {
                    throw new Error(`Session ${msg.sessionId} not found`);
                  }
                  const expectedPath = resolve(
                    session.worktreePath ?? session.projectPath,
                  );
                  const requestedPath = resolve(msg.projectPath);
                  if (requestedPath !== expectedPath) {
                    throw new Error(
                      "git_commit projectPath must match the active session cwd",
                    );
                  }
                  return generateCommitMessage({
                    provider: session.provider,
                    projectPath: msg.projectPath,
                    model:
                      session.provider === "claude"
                        ? session.process instanceof SdkProcess
                          ? session.process.model
                          : undefined
                        : session.codexSettings?.model,
                  });
                })()
              : (msg.message ?? "");
          const result = gitCommit(msg.projectPath, message);
          this.send(ws, {
            type: "git_commit_result",
            success: true,
            projectPath: msg.projectPath,
            commitHash: result.hash,
            message: result.message,
          });
        } catch (err) {
          this.send(ws, {
            type: "git_commit_result",
            success: false,
            projectPath: msg.projectPath,
            error: err instanceof Error ? err.message : String(err),
          });
        }
        break;
      }

      case "git_push": {
        if (!this.isExistingProjectPathAllowed(msg.projectPath)) {
          this.sendGitPathNotAllowed(ws, msg.type, msg.projectPath);
          break;
        }
        try {
          gitPush(msg.projectPath);
          this.send(ws, {
            type: "git_push_result",
            success: true,
            projectPath: msg.projectPath,
          });
        } catch (err) {
          this.send(ws, {
            type: "git_push_result",
            success: false,
            projectPath: msg.projectPath,
            error: String(err),
          });
        }
        break;
      }

      case "git_branches": {
        if (!this.isExistingProjectPathAllowed(msg.projectPath)) {
          this.sendGitPathNotAllowed(ws, msg.type, msg.projectPath);
          break;
        }
        try {
          const result = listBranches(msg.projectPath);
          this.send(ws, {
            type: "git_branches_result",
            current: result.current,
            branches: result.branches,
            projectPath: msg.projectPath,
            checkedOutBranches: result.checkedOutBranches,
            remoteStatusByBranch: result.remoteStatusByBranch,
          });
        } catch (err) {
          this.send(ws, {
            type: "git_branches_result",
            current: "",
            branches: [],
            projectPath: msg.projectPath,
            remoteStatusByBranch: {},
            error: String(err),
          });
        }
        break;
      }

      case "git_create_branch": {
        if (!this.isExistingProjectPathAllowed(msg.projectPath)) {
          this.sendGitPathNotAllowed(ws, msg.type, msg.projectPath);
          break;
        }
        try {
          createBranch(msg.projectPath, msg.name, msg.checkout);
          this.send(ws, {
            type: "git_create_branch_result",
            success: true,
            projectPath: msg.projectPath,
          });
        } catch (err) {
          this.send(ws, {
            type: "git_create_branch_result",
            success: false,
            projectPath: msg.projectPath,
            error: String(err),
          });
        }
        break;
      }

      case "git_checkout_branch": {
        if (!this.isExistingProjectPathAllowed(msg.projectPath)) {
          this.sendGitPathNotAllowed(ws, msg.type, msg.projectPath);
          break;
        }
        try {
          checkoutBranch(msg.projectPath, msg.branch);
          this.send(ws, {
            type: "git_checkout_branch_result",
            success: true,
            projectPath: msg.projectPath,
          });
        } catch (err) {
          this.send(ws, {
            type: "git_checkout_branch_result",
            success: false,
            projectPath: msg.projectPath,
            error: String(err),
          });
        }
        break;
      }

      case "git_revert_file": {
        if (!this.isExistingProjectPathAllowed(msg.projectPath)) {
          this.sendGitPathNotAllowed(ws, msg.type, msg.projectPath);
          break;
        }
        try {
          revertFiles(msg.projectPath, msg.files);
          this.send(ws, {
            type: "git_revert_file_result",
            success: true,
            projectPath: msg.projectPath,
          });
        } catch (err) {
          this.send(ws, {
            type: "git_revert_file_result",
            success: false,
            projectPath: msg.projectPath,
            error: String(err),
          });
        }
        break;
      }

      case "git_revert_hunks": {
        if (!this.isExistingProjectPathAllowed(msg.projectPath)) {
          this.sendGitPathNotAllowed(ws, msg.type, msg.projectPath);
          break;
        }
        try {
          revertHunks(msg.projectPath, msg.hunks);
          this.send(ws, {
            type: "git_revert_hunks_result",
            success: true,
            projectPath: msg.projectPath,
          });
        } catch (err) {
          this.send(ws, {
            type: "git_revert_hunks_result",
            success: false,
            projectPath: msg.projectPath,
            error: String(err),
          });
        }
        break;
      }

      case "git_fetch": {
        if (!this.isExistingProjectPathAllowed(msg.projectPath)) {
          this.sendGitPathNotAllowed(ws, msg.type, msg.projectPath);
          break;
        }
        try {
          gitFetch(msg.projectPath);
          this.send(ws, {
            type: "git_fetch_result",
            success: true,
            projectPath: msg.projectPath,
          });
        } catch (err) {
          this.send(ws, {
            type: "git_fetch_result",
            success: false,
            projectPath: msg.projectPath,
            error: String(err),
          });
        }
        break;
      }

      case "git_pull": {
        if (!this.isExistingProjectPathAllowed(msg.projectPath)) {
          this.sendGitPathNotAllowed(ws, msg.type, msg.projectPath);
          break;
        }
        try {
          const result = gitPull(msg.projectPath);
          if (result.success) {
            this.send(ws, {
              type: "git_pull_result",
              success: true,
              projectPath: msg.projectPath,
              message: result.message,
            });
          } else {
            this.send(ws, {
              type: "git_pull_result",
              success: false,
              projectPath: msg.projectPath,
              error: result.message,
            });
          }
        } catch (err) {
          this.send(ws, {
            type: "git_pull_result",
            success: false,
            projectPath: msg.projectPath,
            error: String(err),
          });
        }
        break;
      }

      case "git_status": {
        if (!this.isExistingProjectPathAllowed(msg.projectPath)) {
          this.send(ws, {
            type: "git_status_result",
            sessionId: msg.sessionId,
            projectPath: msg.projectPath,
            hasUncommittedChanges: false,
            stagedCount: 0,
            unstagedCount: 0,
            untrackedCount: 0,
            remoteStatusIncluded: false,
            hasRemoteChanges: false,
            commitsAhead: 0,
            commitsBehind: 0,
            hasUpstream: false,
            error: `Path not allowed: ${msg.projectPath}`,
          });
          break;
        }
        try {
          const result = gitStatus(msg.projectPath, {
            includeRemote: msg.includeRemote,
          });
          this.send(ws, {
            type: "git_status_result",
            sessionId: msg.sessionId,
            projectPath: msg.projectPath,
            hasUncommittedChanges: result.hasUncommittedChanges,
            stagedCount: result.stagedCount,
            unstagedCount: result.unstagedCount,
            untrackedCount: result.untrackedCount,
            remoteStatusIncluded: result.remoteStatusIncluded,
            hasRemoteChanges: result.hasRemoteChanges,
            commitsAhead: result.commitsAhead,
            commitsBehind: result.commitsBehind,
            hasUpstream: result.hasUpstream,
            branch: result.branch,
            remoteError: result.remoteError,
          });
        } catch (err) {
          this.send(ws, {
            type: "git_status_result",
            sessionId: msg.sessionId,
            projectPath: msg.projectPath,
            hasUncommittedChanges: false,
            stagedCount: 0,
            unstagedCount: 0,
            untrackedCount: 0,
            remoteStatusIncluded: false,
            hasRemoteChanges: false,
            commitsAhead: 0,
            commitsBehind: 0,
            hasUpstream: false,
            error: String(err),
          });
        }
        break;
      }

      case "git_remote_status": {
        if (!this.isExistingProjectPathAllowed(msg.projectPath)) {
          this.sendGitPathNotAllowed(ws, msg.type, msg.projectPath);
          break;
        }
        try {
          const result = gitRemoteStatus(msg.projectPath);
          this.send(ws, {
            type: "git_remote_status_result",
            ahead: result.ahead,
            behind: result.behind,
            branch: result.branch,
            hasUpstream: result.hasUpstream,
            projectPath: msg.projectPath,
          });
        } catch (err) {
          this.send(ws, {
            type: "git_remote_status_result",
            ahead: 0,
            behind: 0,
            branch: "",
            hasUpstream: false,
            projectPath: msg.projectPath,
            error: String(err),
            errorCode: "git_remote_status_failed",
          });
        }
        break;
      }

      case "rewind_dry_run": {
        const session = this.sessionManager.get(msg.sessionId);
        if (!session) {
          this.send(ws, {
            type: "rewind_preview",
            canRewind: false,
            error: `Session ${msg.sessionId} not found`,
          });
          return;
        }
        if (session.provider === "codex") {
          this.send(ws, {
            type: "rewind_preview",
            canRewind: false,
            error: "Codex rewind does not restore files",
          });
          return;
        }
        this.sessionManager
          .rewindFiles(msg.sessionId, msg.targetUuid, true)
          .then((result) => {
            this.send(ws, {
              type: "rewind_preview",
              canRewind: result.canRewind,
              filesChanged: result.filesChanged,
              insertions: result.insertions,
              deletions: result.deletions,
              error: result.error,
            });
          })
          .catch((err) => {
            this.send(ws, {
              type: "rewind_preview",
              canRewind: false,
              error: `Dry run failed: ${err}`,
            });
          });
        break;
      }

      case "rewind": {
        const session = this.sessionManager.get(msg.sessionId);
        if (!session) {
          this.send(ws, {
            type: "rewind_result",
            success: false,
            mode: msg.mode,
            error: `Session ${msg.sessionId} not found`,
          });
          return;
        }

        const handleError = (err: unknown) => {
          const errMsg = err instanceof Error ? err.message : String(err);
          this.send(ws, {
            type: "rewind_result",
            success: false,
            mode: msg.mode,
            error: errMsg,
          });
        };

        if (session.provider === "codex") {
          this.rewindCodexConversation(
            ws,
            msg.sessionId,
            msg.targetUuid,
            msg.mode,
          ).catch(handleError);
          break;
        }

        if (msg.mode === "code") {
          // Code-only rewind: rewind files without restarting the conversation
          this.sessionManager
            .rewindFiles(msg.sessionId, msg.targetUuid)
            .then((result) => {
              if (result.canRewind) {
                this.send(ws, {
                  type: "rewind_result",
                  success: true,
                  mode: "code",
                });
              } else {
                this.send(ws, {
                  type: "rewind_result",
                  success: false,
                  mode: "code",
                  error: result.error ?? "Cannot rewind files",
                });
              }
            })
            .catch(handleError);
        } else if (msg.mode === "conversation") {
          // Conversation-only rewind: restart session at the target UUID
          try {
            this.flushSessionDeltaBatches(msg.sessionId);
            this.sessionManager.rewindConversation(
              msg.sessionId,
              msg.targetUuid,
              (newSessionId) => {
                this.send(ws, {
                  type: "rewind_result",
                  success: true,
                  mode: "conversation",
                });
                // Notify the new session ID
                const newSession = this.sessionManager.get(newSessionId);
                const rewindPermMode =
                  newSession?.process instanceof SdkProcess
                    ? newSession.process.permissionMode
                    : undefined;
                this.send(
                  ws,
                  this.buildSessionCreatedMessage({
                    sessionId: newSessionId,
                    provider: newSession?.provider ?? "claude",
                    projectPath: newSession?.projectPath ?? "",
                    session: newSession,
                    permissionMode: rewindPermMode,
                    sourceSessionId: msg.sessionId,
                  }),
                );
                this.sendSessionList(ws);
              },
            );
          } catch (err) {
            handleError(err);
          }
        } else {
          // Both: rewind files first, then rewind conversation
          this.sessionManager
            .rewindFiles(msg.sessionId, msg.targetUuid)
            .then((result) => {
              if (!result.canRewind) {
                this.send(ws, {
                  type: "rewind_result",
                  success: false,
                  mode: "both",
                  error: result.error ?? "Cannot rewind files",
                });
                return;
              }
              try {
                this.flushSessionDeltaBatches(msg.sessionId);
                this.sessionManager.rewindConversation(
                  msg.sessionId,
                  msg.targetUuid,
                  (newSessionId) => {
                    this.send(ws, {
                      type: "rewind_result",
                      success: true,
                      mode: "both",
                    });
                    const newSession = this.sessionManager.get(newSessionId);
                    const rewindPermMode2 =
                      newSession?.process instanceof SdkProcess
                        ? newSession.process.permissionMode
                        : undefined;
                    this.send(
                      ws,
                      this.buildSessionCreatedMessage({
                        sessionId: newSessionId,
                        provider: newSession?.provider ?? "claude",
                        projectPath: newSession?.projectPath ?? "",
                        session: newSession,
                        permissionMode: rewindPermMode2,
                        sourceSessionId: msg.sessionId,
                      }),
                    );
                    this.sendSessionList(ws);
                  },
                );
              } catch (err) {
                handleError(err);
              }
            })
            .catch(handleError);
        }
        break;
      }

      case "fork": {
        this.forkCodexSession(
          ws,
          msg.sessionId,
          msg.targetUuid,
          msg.projectPath,
          msg.codexSourceId,
        ).catch((err) => {
          const lifecycleFailure =
            err instanceof SessionLifecycleError
              ? this.classifySessionLifecycleError(err)
              : null;
          this.send(ws, {
            type: "error",
            message:
              lifecycleFailure?.message ??
              (err instanceof Error ? err.message : String(err)),
            errorCode: lifecycleFailure?.code ?? "fork_failed",
            sessionId: msg.sessionId,
          });
        });
        break;
      }

      case "list_windows": {
        listWindows()
          .then((windows) => {
            this.send(ws, { type: "window_list", windows });
          })
          .catch((err) => {
            this.send(ws, {
              type: "error",
              message: `Failed to list windows: ${err instanceof Error ? err.message : String(err)}`,
            });
          });
        break;
      }

      case "take_screenshot": {
        // For window mode, verify the window ID is still valid.
        // The user may have fetched the window list minutes ago and the
        // window could have been closed since then.
        const doCapture = async (): Promise<{
          mode: "fullscreen" | "window";
          windowId?: number;
        }> => {
          if (msg.mode !== "window" || msg.windowId == null) {
            return { mode: msg.mode };
          }
          const current = await listWindows();
          if (current.some((w) => w.windowId === msg.windowId)) {
            return { mode: "window", windowId: msg.windowId };
          }
          // Window ID is stale — fall back to fullscreen and notify
          console.warn(
            `[screenshot] Window ID ${msg.windowId} no longer exists, falling back to fullscreen`,
          );
          return { mode: "fullscreen" };
        };
        doCapture()
          .then((opts) => takeScreenshot(opts))
          .then(async (result) => {
            try {
              if (this.galleryStore) {
                const runtimeSession = msg.sessionId
                  ? this.sessionManager.get(msg.sessionId)
                  : undefined;
                const meta = await this.galleryStore.addImage(
                  result.filePath,
                  msg.projectPath,
                  msg.sessionId,
                  runtimeSession
                    ? this.providerSessionIdForSession(runtimeSession)
                    : undefined,
                );
                if (meta) {
                  const info = this.galleryStore.metaToInfo(meta);
                  this.send(ws, {
                    type: "screenshot_result",
                    success: true,
                    image: info,
                  });
                  this.broadcast({ type: "gallery_new_image", image: info });
                  return;
                }
              }
              this.send(ws, {
                type: "screenshot_result",
                success: false,
                error: "Failed to save screenshot to gallery",
              });
            } finally {
              // Always clean up temp file
              unlink(result.filePath).catch(() => {});
            }
          })
          .catch((err) => {
            this.send(ws, {
              type: "screenshot_result",
              success: false,
              error: err instanceof Error ? err.message : String(err),
            });
          });
        break;
      }

      case "backup_prompt_history": {
        if (!this.promptHistoryBackup) {
          this.send(ws, {
            type: "prompt_history_backup_result",
            success: false,
            error: "Backup store not available",
          });
          break;
        }
        const buf = Buffer.from(msg.data, "base64");
        this.promptHistoryBackup
          .save(buf, msg.appVersion, msg.dbVersion)
          .then((meta) => {
            this.send(ws, {
              type: "prompt_history_backup_result",
              success: true,
              backedUpAt: meta.backedUpAt,
            });
          })
          .catch((err) => {
            this.send(ws, {
              type: "prompt_history_backup_result",
              success: false,
              error: err instanceof Error ? err.message : String(err),
            });
          });
        break;
      }

      case "restore_prompt_history": {
        if (!this.promptHistoryBackup) {
          this.send(ws, {
            type: "prompt_history_restore_result",
            success: false,
            error: "Backup store not available",
          });
          break;
        }
        this.promptHistoryBackup
          .load()
          .then((result) => {
            if (result) {
              this.send(ws, {
                type: "prompt_history_restore_result",
                success: true,
                data: result.data.toString("base64"),
                appVersion: result.meta.appVersion,
                dbVersion: result.meta.dbVersion,
                backedUpAt: result.meta.backedUpAt,
              });
            } else {
              this.send(ws, {
                type: "prompt_history_restore_result",
                success: false,
                error: "No backup found",
              });
            }
          })
          .catch((err) => {
            this.send(ws, {
              type: "prompt_history_restore_result",
              success: false,
              error: err instanceof Error ? err.message : String(err),
            });
          });
        break;
      }

      case "get_prompt_history_backup_info": {
        if (!this.promptHistoryBackup) {
          this.send(ws, { type: "prompt_history_backup_info", exists: false });
          break;
        }
        this.promptHistoryBackup
          .getMeta()
          .then((meta) => {
            if (meta) {
              this.send(ws, {
                type: "prompt_history_backup_info",
                exists: true,
                ...meta,
              });
            } else {
              this.send(ws, {
                type: "prompt_history_backup_info",
                exists: false,
              });
            }
          })
          .catch(() => {
            this.send(ws, {
              type: "prompt_history_backup_info",
              exists: false,
            });
          });
        break;
      }

      case "record_prompt_history": {
        if (!this.promptHistoryStore) {
          this.send(ws, {
            type: "prompt_history_mutation_result",
            success: false,
            error: "Prompt history store not available",
          });
          break;
        }
        try {
          const entry = await this.promptHistoryStore.record({
            text: msg.text,
            projectPath: msg.projectPath,
            clientId: msg.clientId,
            clientName: msg.clientName,
            sessionId: msg.sessionId,
            usedAt: msg.usedAt,
          });
          this.send(ws, {
            type: "prompt_history_mutation_result",
            success: true,
            bridgeInstanceId: this.promptHistoryStore.bridgeInstanceId,
            revision: this.promptHistoryStore.revision,
            entry,
          });
          this.broadcastPromptHistoryStatus();
        } catch (err) {
          this.send(ws, {
            type: "prompt_history_mutation_result",
            success: false,
            error: err instanceof Error ? err.message : String(err),
          });
        }
        break;
      }

      case "sync_prompt_history": {
        if (!this.promptHistoryStore) {
          this.send(ws, {
            type: "prompt_history_sync_result",
            success: false,
            requestId: msg.requestId,
            error: "Prompt history store not available",
          });
          break;
        }
        try {
          if (msg.entries?.length) {
            await this.promptHistoryStore.mergeClientEntries(msg.entries);
          }
          this.send(ws, {
            type: "prompt_history_sync_result",
            success: true,
            requestId: msg.requestId,
            bridgeInstanceId: this.promptHistoryStore.bridgeInstanceId,
            revision: this.promptHistoryStore.revision,
            syncedAt: new Date().toISOString(),
            fullSnapshot: true,
            entries: this.promptHistoryStore.list(msg.includeDeleted ?? true),
          });
          this.broadcastPromptHistoryStatus();
        } catch (err) {
          this.send(ws, {
            type: "prompt_history_sync_result",
            success: false,
            requestId: msg.requestId,
            error: err instanceof Error ? err.message : String(err),
          });
        }
        break;
      }

      case "mutate_prompt_history": {
        if (!this.promptHistoryStore) {
          this.send(ws, {
            type: "prompt_history_mutation_result",
            success: false,
            error: "Prompt history store not available",
          });
          break;
        }
        try {
          const entry = await this.promptHistoryStore.mutate({
            id: msg.id,
            text: msg.text,
            projectPath: msg.projectPath,
            action: msg.action,
            isFavorite: msg.isFavorite,
            updatedAt: msg.updatedAt,
          });
          this.send(ws, {
            type: "prompt_history_mutation_result",
            success: entry != null,
            bridgeInstanceId: this.promptHistoryStore.bridgeInstanceId,
            revision: this.promptHistoryStore.revision,
            entry: entry ?? undefined,
            error: entry == null ? "Prompt not found" : undefined,
          });
          if (entry) this.broadcastPromptHistoryStatus();
        } catch (err) {
          this.send(ws, {
            type: "prompt_history_mutation_result",
            success: false,
            error: err instanceof Error ? err.message : String(err),
          });
        }
        break;
      }

      case "import_prompt_history_v1": {
        if (!this.promptHistoryStore) {
          this.send(ws, {
            type: "prompt_history_sync_result",
            success: false,
            requestId: msg.requestId,
            error: "Prompt history store not available",
          });
          break;
        }
        try {
          const result = await this.promptHistoryStore.importEntries(
            msg.entries,
            msg.clientId,
            msg.clientName,
          );
          this.send(ws, {
            type: "prompt_history_sync_result",
            success: true,
            requestId: msg.requestId,
            bridgeInstanceId: this.promptHistoryStore.bridgeInstanceId,
            revision: this.promptHistoryStore.revision,
            syncedAt: new Date().toISOString(),
            fullSnapshot: true,
            entries: result.entries,
          });
          this.broadcastPromptHistoryStatus();
        } catch (err) {
          this.send(ws, {
            type: "prompt_history_sync_result",
            success: false,
            requestId: msg.requestId,
            error: err instanceof Error ? err.message : String(err),
          });
        }
        break;
      }

      case "rename_session": {
        const name = (msg.name as string | null) || null;
        await this.handleRenameSession(ws, msg.sessionId, name, msg);
        break;
      }
    }
  }

  private clearPendingClaudeResumeInputs(ws: WebSocket): void {
    this.pendingClaudeResumeInputs.get(ws)?.clear();
    this.pendingClaudeResumeInputs.delete(ws);
    for (const operation of this.resumeOperations.values()) {
      operation.waiters = operation.waiters.filter(
        (waiter) => waiter.ws !== ws,
      );
    }
  }

  private resumeOperationKey(
    provider: Provider,
    sourceSessionId: string,
  ): string {
    return `${provider}:${sourceSessionId}`;
  }

  private resumeRequestFingerprint(msg: ResumeClientMessage): string {
    return JSON.stringify({
      provider: msg.provider ?? "claude",
      sessionId: msg.sessionId,
      projectPath: msg.projectPath,
      permissionMode: msg.permissionMode,
      executionMode: msg.executionMode,
      approvalPolicy: msg.approvalPolicy,
      approvalsReviewer: msg.approvalsReviewer,
      codexPermissionsMode: msg.codexPermissionsMode,
      planMode: msg.planMode,
      sandboxMode: msg.sandboxMode,
      model: msg.model,
      effort: msg.effort,
      maxTurns: msg.maxTurns,
      maxBudgetUsd: msg.maxBudgetUsd,
      fallbackModel: msg.fallbackModel,
      forkSession: msg.forkSession ?? false,
      persistSession: msg.persistSession,
      profile: msg.profile,
      modelReasoningEffort: msg.modelReasoningEffort,
      serviceTier: msg.serviceTier,
      networkAccessEnabled: msg.networkAccessEnabled,
      webSearchMode: msg.webSearchMode,
      additionalWritableRoots: [...(msg.additionalWritableRoots ?? [])].sort(),
    });
  }

  private clearResumeOperation(key: string, operation: ResumeOperation): void {
    if (operation.timeout) clearTimeout(operation.timeout);
    if (this.resumeOperations.get(key) === operation) {
      this.resumeOperations.delete(key);
    }
  }

  private ensurePendingClaudeResume(
    ws: WebSocket,
    sourceSessionId: string,
  ): void {
    let pendingResumes = this.pendingClaudeResumeInputs.get(ws);
    if (!pendingResumes) {
      pendingResumes = new Map();
      this.pendingClaudeResumeInputs.set(ws, pendingResumes);
    }
    if (!pendingResumes.has(sourceSessionId)) {
      pendingResumes.set(sourceSessionId, []);
    }
  }

  private beginResumeOperation(params: {
    ws: WebSocket;
    provider: Provider;
    sourceSessionId: string;
    projectPath: string;
    request: ResumeClientMessage;
    initialProgressSequence: number;
  }): { key: string; operationId: string; isOwner: boolean } {
    const {
      ws,
      provider,
      sourceSessionId,
      projectPath,
      request,
      initialProgressSequence,
    } = params;
    const key = this.resumeOperationKey(provider, sourceSessionId);
    const fingerprint = this.resumeRequestFingerprint(request);
    let operation = this.resumeOperations.get(key);
    const completedSession = operation?.completed
      ? this.sessionManager.get(operation.completed.sessionId)
      : undefined;
    const completedCodexSessionStopped =
      operation?.provider === "codex" &&
      completedSession !== undefined &&
      (completedSession.process as { isRunning?: boolean }).isRunning !== true;
    if (
      operation?.completed &&
      (!completedSession ||
        completedCodexSessionStopped ||
        Date.now() - operation.completed.completedAt >
          RESUME_COMPLETED_TTL_MS ||
        operation.fingerprint !== fingerprint ||
        request.forkSession === true)
    ) {
      this.clearResumeOperation(key, operation);
      operation = undefined;
    }

    if (
      operation &&
      !operation.completed &&
      operation.fingerprint !== fingerprint
    ) {
      this.sendResumeFailed(ws, {
        provider,
        sourceSessionId,
        projectPath,
        resumeRequestId: request.resumeRequestId,
      });
      this.send(ws, {
        type: "error",
        message:
          "This session is already being restored with different settings. Wait for it to finish, then try again.",
      });
      return { key, operationId: operation.id, isOwner: false };
    }

    this.send(ws, {
      type: "system",
      subtype: "session_resume_started",
      sourceSessionId,
      provider,
      projectPath,
      ...(request.resumeRequestId
        ? { resumeRequestId: request.resumeRequestId }
        : {}),
    });

    if (provider === "claude") {
      this.ensurePendingClaudeResume(ws, sourceSessionId);
    }

    if (operation) {
      if (operation.completed) {
        this.sendResumeCompletion(
          {
            ws,
            resumeRequestId: request.resumeRequestId,
            sessionLinkGeneration: request.sessionLinkGeneration,
            progressSequence: initialProgressSequence,
          },
          operation.completed.message,
        );
        this.flushPendingClaudeResumeInputs(
          ws,
          sourceSessionId,
          operation.completed.sessionId,
        );
      } else {
        const waiter = this.addResumeOperationWaiter(
          operation,
          ws,
          request,
          initialProgressSequence,
        );
        if (operation.latestProgress) {
          this.sendResumeProgressToWaiter(waiter, operation, {
            ...operation.latestProgress,
          });
        }
      }
      return { key, operationId: operation.id, isOwner: false };
    }

    const operationId = randomUUID();
    const newOperation: ResumeOperation = {
      id: operationId,
      provider,
      sourceSessionId,
      projectPath,
      fingerprint,
      waiters: [
        {
          ws,
          resumeRequestId: request.resumeRequestId,
          sessionLinkGeneration: request.sessionLinkGeneration,
          progressSequence: initialProgressSequence,
        },
      ],
    };
    const timeout = setTimeout(() => {
      this.failResumeOperation(
        key,
        operationId,
        "Session restore is taking longer than expected. Please reconnect and try again.",
      );
    }, RESUME_OPERATION_TIMEOUT_MS);
    timeout.unref?.();
    newOperation.timeout = timeout;
    this.resumeOperations.set(key, newOperation);
    return { key, operationId, isOwner: true };
  }

  private completeResumeOperation(
    key: string,
    operationId: string,
    sessionId: string,
    message: SystemServerMessage,
  ): boolean {
    const operation = this.resumeOperations.get(key);
    if (!operation || operation.id !== operationId) return false;
    if (operation.timeout) clearTimeout(operation.timeout);
    operation.completed = {
      sessionId,
      message,
      completedAt: Date.now(),
    };
    for (const waiter of operation.waiters) {
      this.sendResumeCompletion(waiter, message);
      this.flushPendingClaudeResumeInputs(
        waiter.ws,
        operation.sourceSessionId,
        sessionId,
      );
    }
    operation.waiters = [];
    const timeout = setTimeout(() => {
      this.clearResumeOperation(key, operation);
    }, RESUME_COMPLETED_TTL_MS);
    timeout.unref?.();
    operation.timeout = timeout;
    this.pruneCompletedResumeOperations();
    return true;
  }

  private failResumeOperation(
    key: string,
    operationId: string,
    message: string,
  ): void {
    const operation = this.resumeOperations.get(key);
    if (!operation || operation.id !== operationId) return;
    this.clearResumeOperation(key, operation);
    for (const waiter of operation.waiters) {
      this.rejectPendingClaudeResumeInputs(
        waiter.ws,
        operation.sourceSessionId,
      );
      this.sendResumeFailed(waiter.ws, {
        ...operation,
        resumeRequestId: waiter.resumeRequestId,
        sessionLinkGeneration: waiter.sessionLinkGeneration,
      });
      this.send(waiter.ws, { type: "error", message });
    }
  }

  private addResumeOperationWaiter(
    operation: ResumeOperation,
    ws: WebSocket,
    request: ResumeClientMessage,
    initialProgressSequence: number,
  ): ResumeOperationWaiter {
    const existing = operation.waiters.find(
      (waiter) =>
        waiter.ws === ws &&
        waiter.resumeRequestId === request.resumeRequestId &&
        waiter.sessionLinkGeneration === request.sessionLinkGeneration,
    );
    if (existing) return existing;
    const waiter: ResumeOperationWaiter = {
      ws,
      resumeRequestId: request.resumeRequestId,
      sessionLinkGeneration: request.sessionLinkGeneration,
      progressSequence: initialProgressSequence,
    };
    operation.waiters.push(waiter);
    return waiter;
  }

  private sendResumeOperationProgress(
    key: string,
    operationId: string,
    stage: SessionLinkProgressStage,
    counts: { completedUnits?: number; totalUnits?: number } = {},
  ): void {
    const operation = this.resumeOperations.get(key);
    if (!operation || operation.id !== operationId || operation.completed) {
      return;
    }
    operation.latestProgress = { stage, ...counts };
    for (const waiter of operation.waiters) {
      this.sendResumeProgressToWaiter(waiter, operation, {
        stage,
        ...counts,
      });
    }
  }

  private sendResumeProgressToWaiter(
    waiter: ResumeOperationWaiter,
    operation: ResumeOperation,
    progress: ResumeOperationProgress,
  ): void {
    this.sendSessionLinkProgress(waiter.ws, {
      requestId: waiter.resumeRequestId,
      sourceSessionId: operation.sourceSessionId,
      generation: waiter.sessionLinkGeneration,
      operation: "resume",
      stage: progress.stage,
      sequence: ++waiter.progressSequence,
      ...(progress.completedUnits !== undefined
        ? { completedUnits: progress.completedUnits }
        : {}),
      ...(progress.totalUnits !== undefined
        ? { totalUnits: progress.totalUnits }
        : {}),
    });
  }

  private sendResumeCompletion(
    waiter: ResumeOperationWaiter,
    message: SystemServerMessage,
  ): void {
    const response = {
      ...message,
    } as SystemServerMessage & {
      resumeRequestId?: string;
      sessionLinkGeneration?: number;
    };
    if (waiter.resumeRequestId) {
      response.resumeRequestId = waiter.resumeRequestId;
    } else {
      delete response.resumeRequestId;
    }
    if (waiter.sessionLinkGeneration !== undefined) {
      response.sessionLinkGeneration = waiter.sessionLinkGeneration;
    } else {
      delete response.sessionLinkGeneration;
    }
    this.send(waiter.ws, response);
  }

  private sendResumeFailed(
    ws: WebSocket,
    resume: {
      provider: Provider;
      sourceSessionId: string;
      projectPath: string;
      resumeRequestId?: string;
      sessionLinkGeneration?: number;
    },
  ): void {
    this.send(ws, {
      type: "system",
      subtype: "session_resume_failed",
      provider: resume.provider,
      sourceSessionId: resume.sourceSessionId,
      projectPath: resume.projectPath,
      ...(resume.resumeRequestId
        ? { resumeRequestId: resume.resumeRequestId }
        : {}),
      ...(resume.sessionLinkGeneration !== undefined
        ? { sessionLinkGeneration: resume.sessionLinkGeneration }
        : {}),
    });
  }

  private sendStartFailed(
    ws: WebSocket,
    start: {
      provider: Provider;
      projectPath: string;
      startRequestId?: string;
      errorMessage: string;
    },
  ): void {
    if (!start.startRequestId) return;
    this.send(ws, {
      type: "system",
      subtype: "session_start_failed",
      provider: start.provider,
      projectPath: start.projectPath,
      startRequestId: start.startRequestId,
      errorMessage: start.errorMessage,
    });
  }

  private flushPendingClaudeResumeInputs(
    ws: WebSocket,
    sourceSessionId: string,
    sessionId: string,
  ): void {
    const pendingResumes = this.pendingClaudeResumeInputs.get(ws);
    const queuedInputs = pendingResumes?.get(sourceSessionId) ?? [];
    pendingResumes?.delete(sourceSessionId);
    for (const input of queuedInputs) {
      void this.handleClientMessage({ ...input, sessionId }, ws);
    }
  }

  private rejectPendingClaudeResumeInputs(
    ws: WebSocket,
    sourceSessionId: string,
  ): void {
    const pendingResumes = this.pendingClaudeResumeInputs.get(ws);
    const queuedInputs = pendingResumes?.get(sourceSessionId) ?? [];
    pendingResumes?.delete(sourceSessionId);
    for (const input of queuedInputs) {
      if (!input.clientMessageId) continue;
      this.send(ws, {
        type: "input_rejected",
        sessionId: sourceSessionId,
        clientMessageId: input.clientMessageId,
        reason: "Session resume failed",
      });
    }
  }

  private pruneCompletedResumeOperations(): void {
    const completed = [...this.resumeOperations.entries()]
      .filter((entry) => entry[1].completed)
      .sort(
        (a, b) =>
          (a[1].completed?.completedAt ?? 0) -
          (b[1].completed?.completedAt ?? 0),
      );
    while (completed.length > 100) {
      const oldest = completed.shift();
      if (oldest) this.clearResumeOperation(oldest[0], oldest[1]);
    }
  }

  /**
   * Load the saved session name from CLI storage and set it on the SessionInfo.
   * Called after SessionManager.create() so that session_created carries the name.
   */
  private async loadAndSetSessionName(
    session: SessionInfo | undefined,
    provider: string,
    projectPath: string,
    cliSessionId?: string,
  ): Promise<void> {
    if (!session || !cliSessionId) return;
    try {
      if (provider === "claude") {
        const name = await getClaudeSessionName(projectPath, cliSessionId);
        if (name) session.name = name;
      } else if (provider === "codex") {
        const names = await loadCodexSessionNames();
        const name = names.get(cliSessionId);
        if (name) session.name = name;
      }
    } catch {
      // Non-critical: session works without name
    }
  }

  /**
   * Handle rename_session: update in-memory name and persist to CLI storage.
   *
   * Supports both running sessions (by bridge session id) and recent sessions
   * (by provider session id, i.e. claudeSessionId or codex threadId).
   */
  private async handleRenameSession(
    ws: WebSocket,
    sessionId: string,
    name: string | null,
    msg: ClientMessage,
  ): Promise<void> {
    const renameMsg = msg as Extract<ClientMessage, { type: "rename_session" }>;
    try {
      if (renameMsg.provider === "codex") {
        this.assertCodexSourceMatches("codex", renameMsg.codexSourceId);
      }
    } catch (error) {
      const failure = this.classifySessionLifecycleError(error);
      this.send(ws, {
        type: "rename_result",
        sessionId,
        name,
        success: false,
        error: failure.message,
        errorCode: failure.code,
      });
      return;
    }

    // 1. Try running session first
    const runningSession = this.sessionManager.get(sessionId);
    if (runningSession) {
      this.sessionManager.renameSession(sessionId, name);

      // Persist to provider storage
      if (
        runningSession.provider === "claude" &&
        runningSession.claudeSessionId
      ) {
        await renameClaudeSession(
          runningSession.worktreePath ?? runningSession.projectPath,
          runningSession.claudeSessionId,
          name,
        );
      } else if (
        runningSession.provider === "codex" &&
        runningSession.process
      ) {
        try {
          await (
            runningSession.process as import("./codex-process.js").CodexProcess
          ).renameThread(name ?? "");
        } catch (err) {
          console.warn(`[websocket] Failed to rename Codex thread:`, err);
        }
      }

      this.broadcastSessionList();
      this.send(ws, { type: "rename_result", sessionId, name, success: true });
      return;
    }

    // 2. Recent session (not running) — use provider + providerSessionId + projectPath from message
    const provider = renameMsg.provider;
    const providerSessionId = renameMsg.providerSessionId;
    const projectPath = renameMsg.projectPath;

    if (provider === "claude" && providerSessionId && projectPath) {
      const success = await renameClaudeSession(
        projectPath,
        providerSessionId,
        name,
      );
      this.send(ws, { type: "rename_result", sessionId, name, success });
      return;
    }

    // For Codex recent sessions, write directly to session_index.jsonl.
    if (provider === "codex" && providerSessionId) {
      const success = await renameCodexSession(providerSessionId, name);
      this.send(ws, { type: "rename_result", sessionId, name, success });
      return;
    }

    this.send(ws, { type: "rename_result", sessionId, name, success: false });
  }

  private resolveSession(
    sessionId: string | undefined,
  ): SessionInfo | undefined {
    if (sessionId) return this.sessionManager.get(sessionId);
    return this.getFirstSession();
  }

  private getFirstSession() {
    const sessions = this.sessionManager.list();
    if (sessions.length === 0) return undefined;
    return this.sessionManager.get(sessions[sessions.length - 1].id);
  }

  private sendSessionLinkProgress(
    ws: WebSocket,
    progress: {
      requestId?: string;
      sourceSessionId: string;
      generation?: number;
      operation: SessionLinkProgressOperation;
      stage: SessionLinkProgressStage;
      sequence: number;
      completedUnits?: number;
      totalUnits?: number;
    },
  ): void {
    if (
      !progress.requestId ||
      progress.generation === undefined ||
      this.clientSupportedServerMessages
        .get(ws)
        ?.has(SESSION_LINK_PROGRESS_CAPABILITY) !== true
    ) {
      return;
    }
    this.send(ws, {
      type: SESSION_LINK_PROGRESS_CAPABILITY,
      requestId: progress.requestId,
      sourceSessionId: progress.sourceSessionId,
      generation: progress.generation,
      operation: progress.operation,
      stage: progress.stage,
      sequence: progress.sequence,
      observedAt: new Date().toISOString(),
      ...(progress.completedUnits !== undefined
        ? { completedUnits: progress.completedUnits }
        : {}),
      ...(progress.totalUnits !== undefined
        ? { totalUnits: progress.totalUnits }
        : {}),
    });
  }

  private sendSessionList(ws: WebSocket): void {
    this.pruneDebugEvents();
    const sessions = this.sessionManager.list();
    this.send(ws, {
      type: "session_list",
      sessions,
      bridgeInstanceId: this.bridgeInstanceId,
      codexSourceId: this.codexSourceId,
      allowedDirs: this.allowedDirs,
      claudeModels: this.claudeModels,
      claudeModelEfforts: this.claudeModelEfforts,
      codexModels: this.codexModels,
      codexModelReasoningEfforts: this.codexModelReasoningEfforts,
      codexModelServiceTiers: this.codexModelServiceTiers,
      codexProfiles: this.codexProfiles,
      defaultCodexProfile: this.defaultCodexProfile,
      codexAutoReviewDisabled: this.codexAutoReviewDisabled,
      bridgeVersion: getPackageVersion(),
      bridgeCapabilities: [
        CODEX_PERMISSION_APPLY_STRATEGY_CAPABILITY,
        CODEX_SESSION_LIFECYCLE_CAPABILITY,
        CODEX_DESKTOP_CONTINUITY_CAPABILITY,
        CODEX_RESUME_PRESERVES_SETTINGS_CAPABILITY,
        CODEX_HOME_IDENTITY_CAPABILITY,
        PUSH_NOTIFICATION_PREFERENCES_CAPABILITY,
        PUSH_REGISTRATION_STATUS_CAPABILITY,
        BACKGROUND_NOTIFICATION_DELIVERY_CAPABILITY,
        BACKGROUND_NOTIFICATION_ACK_CAPABILITY,
        EPHEMERAL_SIDE_CHAT_CAPABILITY,
        EPHEMERAL_SIDE_CHAT_PARENT_IDENTITY_CAPABILITY,
        TURN_AWARE_HISTORY_WINDOW_CAPABILITY,
        HISTORY_PAGE_CAPABILITY,
        HISTORY_TOOL_DETAIL_CAPABILITY,
        SESSION_ACTIVITY_AT_CAPABILITY,
        SESSION_REQUEST_CORRELATION_CAPABILITY,
        PROMPT_HISTORY_REQUEST_CORRELATION_CAPABILITY,
        SESSION_CATALOG_WATCH_CAPABILITY,
        SESSION_CATALOG_REQUEST_CORRELATION_CAPABILITY,
        SESSION_LINK_PROGRESS_CAPABILITY,
        FILE_LIST_REQUEST_CORRELATION_CAPABILITY,
        CONVERSATION_CONTENT_EVENT_CAPABILITY,
        BRIDGE_IDENTITY_V2_CAPABILITY,
        CONVERSATION_SYNC_V2_CAPABILITY,
        CONVERSATION_ITEMS_BY_ID_CAPABILITY,
        APP_SERVER_STATUS_CAPABILITY,
        DURABLE_SESSION_INSIGHTS_CAPABILITY,
        CONVERSATION_MIRROR_SOURCE_IDENTITY_CAPABILITY,
        GIT_DIFF_REQUEST_CORRELATION_CAPABILITY,
        GIT_PROJECT_RESULT_CORRELATION_CAPABILITY,
        INPUT_DELIVERY_ACK_CAPABILITY,
        ...(this.fileBrowser ? [FILE_BROWSER_CAPABILITY] : []),
        ...(this.fileBrowser ? [FILE_BROWSER_PROJECT_PREVIEW_CAPABILITY] : []),
        ...(this.fileTransfer ? [FILE_TRANSFER_CAPABILITY] : []),
        ...(this.fileBrowser && this.fileMutationAuthorizer
          ? [FILE_MUTATION_AUTH_CAPABILITY]
          : []),
        ...(this.fileTransfer && this.fileBrowser && this.fileMutationAuthorizer
          ? [FILE_TRANSFER_UPLOAD_AUTH_CAPABILITY]
          : []),
      ],
    });
  }

  private sendPromptHistoryStatus(ws: WebSocket): void {
    if (!this.promptHistoryStore) return;
    const entries = this.promptHistoryStore.list(true);
    const updatedAt = entries.reduce<string | undefined>(
      (latest, entry) =>
        !latest || entry.updatedAt > latest ? entry.updatedAt : latest,
      undefined,
    );
    this.send(ws, {
      type: "prompt_history_status",
      bridgeInstanceId: this.promptHistoryStore.bridgeInstanceId,
      revision: this.promptHistoryStore.revision,
      entryCount: entries.filter((entry) => !entry.deletedAt).length,
      updatedAt,
    });
  }

  /** Broadcast session list to all connected clients. */
  private broadcastSessionList(): void {
    this.pruneDebugEvents();
    const sessions = this.sessionManager.list();
    this.broadcast({
      type: "session_list",
      sessions,
      bridgeInstanceId: this.bridgeInstanceId,
      codexSourceId: this.codexSourceId,
      allowedDirs: this.allowedDirs,
      claudeModels: this.claudeModels,
      claudeModelEfforts: this.claudeModelEfforts,
      codexModels: this.codexModels,
      codexModelReasoningEfforts: this.codexModelReasoningEfforts,
      codexModelServiceTiers: this.codexModelServiceTiers,
      codexProfiles: this.codexProfiles,
      defaultCodexProfile: this.defaultCodexProfile,
      codexAutoReviewDisabled: this.codexAutoReviewDisabled,
      bridgeVersion: getPackageVersion(),
      bridgeCapabilities: [
        CODEX_PERMISSION_APPLY_STRATEGY_CAPABILITY,
        CODEX_SESSION_LIFECYCLE_CAPABILITY,
        CODEX_DESKTOP_CONTINUITY_CAPABILITY,
        CODEX_RESUME_PRESERVES_SETTINGS_CAPABILITY,
        CODEX_HOME_IDENTITY_CAPABILITY,
        PUSH_NOTIFICATION_PREFERENCES_CAPABILITY,
        PUSH_REGISTRATION_STATUS_CAPABILITY,
        BACKGROUND_NOTIFICATION_DELIVERY_CAPABILITY,
        BACKGROUND_NOTIFICATION_ACK_CAPABILITY,
        EPHEMERAL_SIDE_CHAT_CAPABILITY,
        EPHEMERAL_SIDE_CHAT_PARENT_IDENTITY_CAPABILITY,
        TURN_AWARE_HISTORY_WINDOW_CAPABILITY,
        HISTORY_PAGE_CAPABILITY,
        HISTORY_TOOL_DETAIL_CAPABILITY,
        SESSION_ACTIVITY_AT_CAPABILITY,
        SESSION_REQUEST_CORRELATION_CAPABILITY,
        PROMPT_HISTORY_REQUEST_CORRELATION_CAPABILITY,
        SESSION_CATALOG_WATCH_CAPABILITY,
        SESSION_CATALOG_REQUEST_CORRELATION_CAPABILITY,
        SESSION_LINK_PROGRESS_CAPABILITY,
        FILE_LIST_REQUEST_CORRELATION_CAPABILITY,
        CONVERSATION_CONTENT_EVENT_CAPABILITY,
        BRIDGE_IDENTITY_V2_CAPABILITY,
        CONVERSATION_SYNC_V2_CAPABILITY,
        CONVERSATION_ITEMS_BY_ID_CAPABILITY,
        APP_SERVER_STATUS_CAPABILITY,
        DURABLE_SESSION_INSIGHTS_CAPABILITY,
        CONVERSATION_MIRROR_SOURCE_IDENTITY_CAPABILITY,
        GIT_DIFF_REQUEST_CORRELATION_CAPABILITY,
        GIT_PROJECT_RESULT_CORRELATION_CAPABILITY,
        INPUT_DELIVERY_ACK_CAPABILITY,
        ...(this.fileBrowser ? [FILE_BROWSER_CAPABILITY] : []),
        ...(this.fileBrowser ? [FILE_BROWSER_PROJECT_PREVIEW_CAPABILITY] : []),
        ...(this.fileTransfer ? [FILE_TRANSFER_CAPABILITY] : []),
        ...(this.fileBrowser && this.fileMutationAuthorizer
          ? [FILE_MUTATION_AUTH_CAPABILITY]
          : []),
        ...(this.fileTransfer && this.fileBrowser && this.fileMutationAuthorizer
          ? [FILE_TRANSFER_UPLOAD_AUTH_CAPABILITY]
          : []),
      ],
    });
  }

  private broadcastPromptHistoryStatus(): void {
    if (!this.promptHistoryStore) return;
    const entries = this.promptHistoryStore.list(true);
    const updatedAt = entries.reduce<string | undefined>(
      (latest, entry) =>
        !latest || entry.updatedAt > latest ? entry.updatedAt : latest,
      undefined,
    );
    this.broadcast({
      type: "prompt_history_status",
      bridgeInstanceId: this.promptHistoryStore.bridgeInstanceId,
      revision: this.promptHistoryStore.revision,
      entryCount: entries.filter((entry) => !entry.deletedAt).length,
      updatedAt,
    });
  }

  private sessionActivityAtForClient(
    client: WebSocket,
    sessionId: string,
  ): string | undefined {
    if (
      this.clientSupportedServerMessages
        .get(client)
        ?.has(SESSION_ACTIVITY_AT_CAPABILITY) !== true
    ) {
      return undefined;
    }
    const value = this.sessionManager.get(sessionId)?.lastActivityAt;
    if (!value) return undefined;
    const date = value instanceof Date ? value : new Date(value);
    return Number.isNaN(date.getTime()) ? undefined : date.toISOString();
  }

  private broadcastSessionMessage(
    sessionId: string,
    msg: ServerMessage,
    exclude?: WebSocket,
  ): void {
    if (this.shouldBatchDelta(msg, exclude)) {
      this.trackSessionMessage(sessionId, msg);
      const chunks = this.splitDeltaText(msg.text);
      for (const client of this.wss.clients) {
        if (client.readyState !== WebSocket.OPEN) continue;
        if (
          this.backgroundDeliveryClients.get(client)?.mode ===
          "notifications_only"
        ) {
          continue;
        }
        if (!this.shouldSendToClient(client, msg)) continue;
        this.queueDeltaForClient(client, sessionId, msg.type, chunks);
      }
      return;
    }

    this.flushSessionDeltaBatches(sessionId);
    const deliveryId = this.isBackgroundNotificationCandidate(msg)
      ? randomUUID()
      : undefined;
    this.trackSessionMessage(sessionId, msg, deliveryId);
    this.broadcastSessionMessageNow(sessionId, msg, exclude, deliveryId);
    const session = this.sessionManager.get(sessionId);
    if (session) this.localFeatures.sessionMessage(session, msg);
  }

  private shouldBatchDelta(
    msg: ServerMessage,
    exclude?: WebSocket,
  ): msg is DeltaServerMessage {
    if (this.deltaBatchMs === 0 || exclude) return false;
    return msg.type === "stream_delta" || msg.type === "thinking_delta";
  }

  private queueDeltaForClient(
    client: WebSocket,
    sessionId: string,
    type: DeltaServerMessage["type"],
    chunks: DeltaTextChunk[],
  ): void {
    for (const chunk of chunks) {
      let batch = this.deltaBatches.get(client)?.get(sessionId);
      if (
        batch &&
        batch.charCount > 0 &&
        batch.charCount + chunk.charCount > this.deltaBatchMaxChars
      ) {
        this.flushClientDeltaBatch(client, sessionId);
        batch = undefined;
      }

      if (!batch) {
        const clientBatches = this.deltaBatches.get(client) ?? new Map();
        batch = {
          messages: [],
          charCount: 0,
          timer: setTimeout(() => {
            this.flushClientDeltaBatch(client, sessionId);
          }, this.deltaBatchMs),
        };
        clientBatches.set(sessionId, batch);
        this.deltaBatches.set(client, clientBatches);
      }

      const last = batch.messages.at(-1);
      if (last?.type === type) {
        last.text += chunk.text;
      } else {
        batch.messages.push({ type, text: chunk.text });
      }
      batch.charCount += chunk.charCount;

      if (batch.charCount >= this.deltaBatchMaxChars) {
        this.flushClientDeltaBatch(client, sessionId);
      }
    }
  }

  private splitDeltaText(text: string): DeltaTextChunk[] {
    if (text.length === 0) return [{ text, charCount: 0 }];

    const chunks: DeltaTextChunk[] = [];
    let chars: string[] = [];
    let charCount = 0;
    for (const char of text) {
      chars.push(char);
      charCount += 1;
      if (charCount >= this.deltaBatchMaxChars) {
        chunks.push({ text: chars.join(""), charCount });
        chars = [];
        charCount = 0;
      }
    }
    if (chars.length > 0) {
      chunks.push({ text: chars.join(""), charCount });
    }
    return chunks;
  }

  private flushSessionDeltaBatches(sessionId: string): void {
    for (const client of Array.from(this.deltaBatches.keys())) {
      this.flushClientDeltaBatch(client, sessionId);
    }
  }

  private flushAllDeltaBatches(): void {
    for (const [client, batches] of Array.from(this.deltaBatches.entries())) {
      for (const sessionId of Array.from(batches.keys())) {
        this.flushClientDeltaBatch(client, sessionId);
      }
    }
  }

  private flushClientDeltaBatch(client: WebSocket, sessionId: string): void {
    const clientBatches = this.deltaBatches.get(client);
    const batch = clientBatches?.get(sessionId);
    if (!batch) return;

    clearTimeout(batch.timer);
    clientBatches?.delete(sessionId);
    if (clientBatches?.size === 0) this.deltaBatches.delete(client);
    if (client.readyState !== WebSocket.OPEN) return;

    for (const msg of batch.messages) {
      const activityAt = this.sessionActivityAtForClient(client, sessionId);
      client.send(
        JSON.stringify({
          ...msg,
          sessionId,
          ...(activityAt ? { activityAt } : {}),
        }),
      );
    }
  }

  private discardClientDeltaBatches(client: WebSocket): void {
    const batches = this.deltaBatches.get(client);
    if (!batches) return;
    for (const batch of batches.values()) clearTimeout(batch.timer);
    this.deltaBatches.delete(client);
  }

  private destroySession(sessionId: string): void {
    this.flushSessionDeltaBatches(sessionId);
    this.sessionManager.destroy(sessionId);
    this.broadcastEphemeralSideChatRegistry();
  }

  /**
   * A CodexProcess resumed before a Desktop-owned turn does not learn that
   * turn's new model-visible history. Recreate the idle runtime from the
   * durable thread before accepting the next mobile turn, preserving the
   * existing runtime-switch contract used by permission/sandbox restarts.
   */
  private async rehydrateCodexSessionAfterExternalTurn(
    sessionId: string,
    threadId: string,
    isStillSafe: () => boolean = () => true,
  ): Promise<boolean> {
    const session = this.sessionManager.get(sessionId);
    if (
      !isStillSafe() ||
      !session ||
      session.provider !== "codex" ||
      this.codexThreadIdForSession(session) !== threadId ||
      !(session.process instanceof CodexProcess) ||
      !session.process.isWaitingForInput ||
      session.permissionRestartInProgress
    ) {
      return false;
    }

    const process = session.process;
    const initialMapping = this.worktreeStore.get(threadId);
    const historyProjectPath =
      initialMapping?.projectPath ?? session.projectPath;
    let canonicalHistory: SessionHistoryMessage[];
    try {
      canonicalHistory = await this.getCodexThreadHistory(
        threadId,
        historyProjectPath,
      );
    } catch (error) {
      console.warn(
        `[ws] Desktop continuity rehydrate preflight failed for ${threadId}: ${errorMessageOf(error)}`,
      );
      return false;
    }
    if (
      !isStillSafe() ||
      this.sessionManager.get(sessionId) !== session ||
      this.codexThreadIdForSession(session) !== threadId ||
      session.process !== process ||
      !process.isWaitingForInput ||
      session.permissionRestartInProgress
    ) {
      return false;
    }

    // Everything below is recaptured after the async history preflight. Mobile
    // input remains admitted into the normal one-item queue while this runtime
    // is marked stale, so edits/cancels made during the read are preserved.
    const settings = { ...(session.codexSettings ?? {}) };
    const collaborationMode = process.collaborationMode;

    const mapping = this.worktreeStore.get(threadId);
    const effectiveProjectPath = mapping?.projectPath ?? session.projectPath;
    const mappedWorktreePath = mapping?.worktreePath ?? session.worktreePath;
    const mappedWorktreeBranch =
      mapping?.worktreeBranch ?? session.worktreeBranch;
    let worktreeOptions: WorktreeOptions | undefined;
    if (mappedWorktreePath && worktreeExists(mappedWorktreePath)) {
      worktreeOptions = {
        existingWorktreePath: mappedWorktreePath,
        worktreeBranch: mappedWorktreeBranch,
      };
    } else if (mappedWorktreeBranch) {
      worktreeOptions = {
        useWorktree: true,
        worktreeBranch: mappedWorktreeBranch,
      };
    }

    const newId = await this.sessionManager.replaceCodexSession(
      sessionId,
      effectiveProjectPath,
      canonicalHistory,
      worktreeOptions,
      {
        threadId,
        profile: settings.profile,
        approvalPolicy:
          settings.approvalPolicy as CodexStartOptions["approvalPolicy"],
        approvalsReviewer:
          settings.approvalsReviewer as CodexStartOptions["approvalsReviewer"],
        codexPermissionsMode:
          settings.codexPermissionsMode as CodexStartOptions["codexPermissionsMode"],
        sandboxMode: settings.sandboxMode as CodexStartOptions["sandboxMode"],
        model: settings.model,
        modelReasoningEffort: settings.modelReasoningEffort,
        serviceTier: settings.serviceTier,
        networkAccessEnabled: settings.networkAccessEnabled,
        webSearchMode:
          settings.webSearchMode as CodexStartOptions["webSearchMode"],
        additionalWritableRoots: settings.additionalWritableRoots,
        collaborationMode,
      },
      undefined,
      isStillSafe,
    );
    const newSession = this.sessionManager.get(newId);
    if (!newSession) return false;

    this.broadcastSessionList();
    void this.loadAndSetSessionName(
      newSession,
      "codex",
      effectiveProjectPath,
      threadId,
    ).then(() => this.broadcastSessionList());
    this.recordDebugEvent(newId, {
      direction: "internal",
      channel: "bridge",
      type: "desktop_continuity_rehydrated",
      detail: `thread=${threadId} stableSession=${sessionId}`,
    });
    console.log(
      `[ws] Desktop continuity: refreshed ${sessionId} in place for thread ${threadId}`,
    );
    return true;
  }

  private trackSessionMessage(
    sessionId: string,
    msg: ServerMessage,
    deliveryId?: string,
  ): void {
    this.maybeSendPushNotification(sessionId, msg, deliveryId);
    this.recordDebugEvent(sessionId, {
      direction: "outgoing",
      channel: "session",
      type: msg.type,
      detail: this.summarizeServerMessage(msg),
    });
    this.recordingStore?.record(sessionId, "outgoing", msg);

    // Update recording meta with claudeSessionId when it becomes available
    if (
      (msg.type === "system" || msg.type === "result") &&
      "sessionId" in msg &&
      msg.sessionId
    ) {
      const session = this.sessionManager.get(sessionId);
      if (session) {
        this.recordingStore?.saveMeta(sessionId, {
          bridgeSessionId: sessionId,
          claudeSessionId: msg.sessionId as string,
          projectPath: session.projectPath,
          createdAt: session.createdAt.toISOString(),
        });
      }
    }
  }

  private broadcastSessionMessageNow(
    sessionId: string,
    msg: ServerMessage,
    exclude?: WebSocket,
    deliveryId?: string,
  ): void {
    for (const client of this.wss.clients) {
      if (client === exclude) continue;
      if (client.readyState === WebSocket.OPEN) {
        const backgroundDelivery = this.backgroundDeliveryClients.get(client);
        if (backgroundDelivery?.mode === "notifications_only") {
          const projectionSession = this.sessionManager.get(sessionId);
          const notification = deliveryId
            ? projectBackgroundNotification(
                msg,
                {
                  deliveryId,
                  sessionId,
                  provider: projectionSession?.provider ?? "claude",
                  providerSessionId: projectionSession?.claudeSessionId,
                  bridgeInstanceId: this.bridgeInstanceId,
                  codexSourceId:
                    projectionSession?.provider === "codex" &&
                    this.bridgeInstanceId
                      ? this.codexSourceId
                      : undefined,
                  label: this.sessionLabel(sessionId),
                },
                backgroundDelivery.policy,
                backgroundDelivery.projectionState,
              )
            : null;
          if (notification) {
            const compatibleNotification = this.prepareServerMessageForClient(
              client,
              notification,
            );
            if (compatibleNotification) {
              client.send(JSON.stringify(compatibleNotification));
            }
          }
          if (msg.type === "status" || msg.type === "result") {
            const activity = this.prepareServerMessageForClient(
              client,
              this.backgroundActivityState(),
            );
            if (activity) client.send(JSON.stringify(activity));
          }
          continue;
        }
        const activityAt = this.sessionActivityAtForClient(client, sessionId);
        const outboundMsg = {
          ...(msg as unknown as Record<string, unknown>),
          sessionId,
          ...(activityAt ? { activityAt } : {}),
        };
        const compatibleMsg = this.prepareServerMessageForClient(
          client,
          outboundMsg,
        );
        if (!compatibleMsg) continue;
        client.send(JSON.stringify(compatibleMsg));
      }
    }
  }

  private async listRecentSessions(
    msg: Extract<ClientMessage, { type: "list_recent_sessions" }>,
  ): Promise<{ sessions: unknown[]; hasMore: boolean }> {
    await this.requireArchiveStoreReady();
    if (msg.provider === "codex") {
      return this.listRecentCodexSessions(msg);
    }

    if (!msg.provider) {
      return this.listRecentAllProviderSessions(msg);
    }

    return getAllRecentSessions({
      limit: msg.limit,
      offset: msg.offset,
      projectPath: msg.projectPath,
      provider: msg.provider,
      namedOnly: msg.namedOnly,
      searchQuery: msg.searchQuery,
      archivedSessionKeys: this.archiveStore.archivedKeys(this.codexSourceId),
    });
  }

  private async listRecentAllProviderSessions(
    msg: Extract<ClientMessage, { type: "list_recent_sessions" }>,
  ): Promise<{ sessions: unknown[]; hasMore: boolean }> {
    const limit = msg.limit ?? 20;
    const offset = msg.offset ?? 0;
    const sourceLimit = offset + limit;

    const [scanResult, codexResult] = await Promise.all([
      getAllRecentSessions({
        limit: sourceLimit,
        offset: 0,
        projectPath: msg.projectPath,
        provider: "claude",
        namedOnly: msg.namedOnly,
        searchQuery: msg.searchQuery,
        archivedSessionKeys: this.archiveStore.archivedKeys(this.codexSourceId),
      }),
      this.listRecentCodexSessions({
        ...msg,
        provider: "codex",
        limit: sourceLimit,
        offset: 0,
      }),
    ]);

    const merged = mergeRecentSessionPages([
      ...codexResult.sessions,
      ...scanResult.sessions,
    ]);

    return {
      sessions: merged.slice(offset, offset + limit),
      hasMore:
        merged.length > offset + limit ||
        scanResult.hasMore ||
        codexResult.hasMore,
    };
  }

  private async listRecentCodexSessions(
    msg: Extract<ClientMessage, { type: "list_recent_sessions" }>,
  ): Promise<{ sessions: unknown[]; hasMore: boolean }> {
    try {
      return await this.listRecentCodexThreads(msg);
    } catch (err) {
      console.warn(
        `[ws] Codex thread/list failed, falling back to rollout scan: ${err}`,
      );
      return getAllRecentSessions({
        limit: msg.limit,
        offset: msg.offset,
        projectPath: msg.projectPath,
        provider: "codex",
        namedOnly: msg.namedOnly,
        searchQuery: msg.searchQuery,
        archivedSessionKeys: this.archiveStore.archivedKeys(this.codexSourceId),
      });
    }
  }

  private attachCodexSourceToRecentSessions(sessions: unknown[]): unknown[] {
    return sessions.map((session) => {
      if (
        session === null ||
        typeof session !== "object" ||
        Array.isArray(session)
      ) {
        return session;
      }
      const record = session as Record<string, unknown>;
      return record.provider === "codex"
        ? { ...record, codexSourceId: this.codexSourceId }
        : session;
    });
  }

  private async handleArchiveSession(
    msg: Extract<ClientMessage, { type: "archive_session" }>,
    ws: WebSocket,
  ): Promise<void> {
    const { sessionId, provider, requestId } = msg;
    try {
      await this.requireArchiveStoreReady();
      this.assertCodexSourceMatches(provider, msg.codexSourceId);
      const projectPath = this.resolveLifecycleProjectPath(msg.projectPath);
      this.assertProviderSessionInactive(provider, sessionId);
      if (provider === "codex") {
        await this.runCodexLifecycleMutation(sessionId, () =>
          this.withCodexLifecycleProcess(projectPath, async (codexProcess) => {
            this.assertProviderSessionInactive(provider, sessionId);
            let reservation: ArchiveCapacityReservation;
            try {
              reservation = await this.archiveStore.reserveArchiveCapacity(
                sessionId,
                provider,
                this.codexSourceId,
              );
            } catch (error) {
              throw new SessionLifecycleError(
                "local_store_failed",
                `Failed to reserve the local archive: ${errorMessageOf(error)}`,
              );
            }
            try {
              if (reservation.alreadyArchived) return;
              await codexProcess.archiveThread(sessionId);
              try {
                await this.archiveStore.commitReservedArchive(
                  reservation,
                  projectPath,
                  {
                    name: msg.name,
                    summary: msg.summary,
                    firstPrompt: msg.firstPrompt,
                    modified: msg.modified,
                  },
                );
              } catch (storeError) {
                try {
                  await codexProcess.unarchiveThread(sessionId);
                } catch (compensationError) {
                  throw new SessionLifecycleError(
                    "partial_failure",
                    `Codex archived the thread, local bookkeeping failed, and automatic restoration also failed: ${errorMessageOf(compensationError)}`,
                  );
                }
                throw new SessionLifecycleError(
                  "local_store_failed",
                  `Local archive bookkeeping failed; the Codex thread was restored: ${errorMessageOf(storeError)}`,
                );
              }
            } finally {
              await this.archiveStore.releaseArchiveCapacity(reservation);
            }
          }),
        );
      } else {
        try {
          await this.archiveStore.archive(sessionId, provider, projectPath, {
            name: msg.name,
            summary: msg.summary,
            firstPrompt: msg.firstPrompt,
            modified: msg.modified,
          });
        } catch (error) {
          throw new SessionLifecycleError(
            "local_store_failed",
            `Failed to save the local archive: ${errorMessageOf(error)}`,
          );
        }
      }
      this.send(ws, {
        type: "archive_result",
        ...(requestId ? { requestId } : {}),
        sessionId,
        provider,
        success: true,
      });
    } catch (error) {
      const failure = this.classifySessionLifecycleError(error);
      this.send(ws, {
        type: "archive_result",
        ...(requestId ? { requestId } : {}),
        sessionId,
        provider,
        success: false,
        error: failure.message,
        errorCode: failure.code,
      });
    }
  }

  private async requireArchiveStoreReady(): Promise<void> {
    await this.archiveStoreReady;
    if (this.archiveStoreInitializationError) {
      throw new SessionLifecycleError(
        "local_store_failed",
        `Archive store initialization failed: ${this.archiveStoreInitializationError.message}`,
      );
    }
  }

  private async handleListArchivedSessions(
    requestId: string,
    ws: WebSocket,
  ): Promise<void> {
    try {
      await this.requireArchiveStoreReady();
      const sessions = this.archiveStore.list(
        ARCHIVED_SESSION_LIST_LIMIT + 1,
        this.codexSourceId,
      );
      this.send(ws, {
        type: "archived_sessions_result",
        requestId,
        success: true,
        sessions: sessions.slice(0, ARCHIVED_SESSION_LIST_LIMIT),
        ...(sessions.length > ARCHIVED_SESSION_LIST_LIMIT
          ? { truncated: true }
          : {}),
      });
    } catch (error) {
      this.send(ws, {
        type: "archived_sessions_result",
        requestId,
        success: false,
        sessions: [],
        error: errorMessageOf(error),
        errorCode: "local_store_failed",
      });
    }
  }

  private async handleUnarchiveSession(
    msg: Extract<ClientMessage, { type: "unarchive_session" }>,
    ws: WebSocket,
  ): Promise<void> {
    const { requestId, sessionId } = msg;
    try {
      await this.requireArchiveStoreReady();
      const entry = this.requireArchivedSession(msg);
      this.assertProviderSessionInactive(entry.provider, sessionId);
      if (entry.provider === "codex") {
        await this.runCodexLifecycleMutation(sessionId, () =>
          this.withCodexLifecycleProcess(
            entry.projectPath,
            async (codexProcess) => {
              this.assertProviderSessionInactive(entry.provider, sessionId);
              await codexProcess.unarchiveThread(sessionId);
              try {
                await this.archiveStore.unarchive(
                  sessionId,
                  entry.provider,
                  entry.codexSourceId,
                );
              } catch (storeError) {
                try {
                  await codexProcess.archiveThread(sessionId);
                } catch (compensationError) {
                  throw new SessionLifecycleError(
                    "partial_failure",
                    `Codex restored the thread, local bookkeeping failed, and automatic re-archive also failed: ${errorMessageOf(compensationError)}`,
                  );
                }
                throw new SessionLifecycleError(
                  "local_store_failed",
                  `Local restore bookkeeping failed; the Codex thread was re-archived: ${errorMessageOf(storeError)}`,
                );
              }
            },
          ),
        );
      } else {
        try {
          await this.archiveStore.unarchive(
            sessionId,
            entry.provider,
            entry.codexSourceId,
          );
        } catch (error) {
          throw new SessionLifecycleError(
            "local_store_failed",
            `Failed to restore the local archive: ${errorMessageOf(error)}`,
          );
        }
      }
      this.send(ws, {
        type: "unarchive_result",
        requestId,
        sessionId,
        success: true,
      });
    } catch (error) {
      const failure = this.classifySessionLifecycleError(error);
      this.send(ws, {
        type: "unarchive_result",
        requestId,
        sessionId,
        success: false,
        error: failure.message,
        errorCode: failure.code,
      });
    }
  }

  private async handleDeleteSession(
    msg: Extract<ClientMessage, { type: "delete_session" }>,
    ws: WebSocket,
  ): Promise<void> {
    const { requestId, sessionId } = msg;
    try {
      await this.requireArchiveStoreReady();
      const entry = this.requireArchivedSession(msg);
      if (entry.provider !== "codex") {
        throw new SessionLifecycleError(
          "archive_identity_mismatch",
          "Permanent deletion is available only for Codex threads.",
        );
      }
      this.assertProviderSessionInactive("codex", sessionId);
      await this.runCodexLifecycleMutation(sessionId, () =>
        this.withCodexLifecycleProcess(
          entry.projectPath,
          async (codexProcess) => {
            this.assertProviderSessionInactive("codex", sessionId);
            await codexProcess.deleteThread(sessionId);
            try {
              await this.archiveStore.remove(
                sessionId,
                entry.provider,
                entry.codexSourceId,
              );
            } catch (error) {
              throw new SessionLifecycleError(
                "partial_failure",
                `Codex deleted the thread, but local archive cleanup failed: ${errorMessageOf(error)}`,
              );
            }
          },
        ),
      );
      this.send(ws, {
        type: "delete_session_result",
        requestId,
        sessionId,
        success: true,
      });
    } catch (error) {
      const failure = this.classifySessionLifecycleError(error);
      this.send(ws, {
        type: "delete_session_result",
        requestId,
        sessionId,
        success: false,
        error: failure.message,
        errorCode: failure.code,
      });
    }
  }

  private requireArchivedSession(
    msg: Extract<
      ClientMessage,
      { type: "unarchive_session" | "delete_session" }
    >,
  ) {
    this.assertCodexSourceMatches(msg.provider, msg.codexSourceId);
    const candidates = this.archiveStore
      .list()
      .filter(
        (session) =>
          session.sessionId === msg.sessionId &&
          session.provider === msg.provider,
      );
    let entry;
    if (msg.provider === "codex" && msg.codexSourceId !== undefined) {
      entry =
        candidates.find(
          (session) => session.codexSourceId === msg.codexSourceId,
        ) ?? candidates.find((session) => session.codexSourceId === undefined);
    } else if (candidates.length === 1) {
      [entry] = candidates;
    } else {
      entry = candidates.find((session) => session.codexSourceId === undefined);
    }
    if (!entry) {
      throw new SessionLifecycleError(
        "session_not_archived",
        "The session is not present in this Bridge's archive.",
      );
    }
    const requestedPath = this.resolveLifecycleProjectPath(msg.projectPath);
    const storedPath = this.resolveLifecycleProjectPath(entry.projectPath);
    if (entry.provider !== msg.provider || storedPath !== requestedPath) {
      throw new SessionLifecycleError(
        "archive_identity_mismatch",
        "The archived session identity no longer matches this request.",
      );
    }
    return { ...entry, projectPath: storedPath };
  }

  private assertCodexSourceMatches(
    provider: Provider,
    requestedSourceId?: string,
  ): void {
    if (
      provider !== "codex" ||
      requestedSourceId === undefined ||
      requestedSourceId === this.codexSourceId
    ) {
      return;
    }
    throw new SessionLifecycleError(
      "codex_source_mismatch",
      "This Codex thread belongs to a different configured source.",
    );
  }

  private resolveLifecycleProjectPath(projectPath: string): string {
    const resolved = resolvePlatformPath(projectPath, this.platform);
    if (!this.isPathAllowed(resolved)) {
      throw new SessionLifecycleError(
        "path_not_allowed",
        `Project path is outside the Bridge allowlist: ${projectPath}`,
      );
    }
    return resolved;
  }

  private assertProviderSessionInactive(
    provider: Provider,
    providerSessionId: string,
  ): void {
    for (const summary of this.sessionManager.list()) {
      if (summary.provider !== provider) continue;
      const session = this.sessionManager.get(summary.id);
      const liveProviderSessionId =
        session?.claudeSessionId ??
        (session?.provider === "codex"
          ? (session.process as CodexProcess).sessionId
          : undefined);
      if (liveProviderSessionId === providerSessionId) {
        throw new SessionLifecycleError(
          "session_active",
          "Stop or close the active session before changing its archive state.",
        );
      }
    }
  }

  private async withCodexLifecycleProcess<T>(
    projectPath: string,
    operation: (process: CodexProcess) => Promise<T>,
  ): Promise<T> {
    const activeProcess = this.getActiveCodexProcess();
    const codexProcess =
      activeProcess ?? (await this.createStandaloneCodexProcess(projectPath));
    try {
      return await operation(codexProcess);
    } finally {
      if (!activeProcess) codexProcess.stop();
    }
  }

  private async runCodexLifecycleMutation<T>(
    threadId: string,
    operation: () => Promise<T>,
  ): Promise<T> {
    const release = await this.acquireCodexThreadOperation(threadId);
    try {
      return await operation();
    } finally {
      release();
    }
  }

  private async acquireCodexThreadOperation(
    threadId: string,
  ): Promise<() => void> {
    const previous = this.codexLifecycleMutations.get(threadId);
    let openGate!: () => void;
    const gate = new Promise<void>((resolve) => {
      openGate = resolve;
    });
    this.codexLifecycleMutations.set(threadId, gate);
    if (previous) await previous;
    let released = false;
    return () => {
      if (released) return;
      released = true;
      openGate();
      if (this.codexLifecycleMutations.get(threadId) === gate) {
        this.codexLifecycleMutations.delete(threadId);
      }
    };
  }

  private classifySessionLifecycleError(error: unknown): {
    code: SessionLifecycleErrorCode;
    message: string;
  } {
    if (error instanceof SessionLifecycleError) {
      return { code: error.code, message: error.message };
    }
    if (isUnsupportedCodexRpc(error)) {
      return {
        code: "unsupported_capability",
        message:
          "This Codex app-server does not support the requested lifecycle operation.",
      };
    }
    return { code: "provider_rpc_failed", message: codexErrorMessage(error) };
  }

  private async refreshCodexMetadata(projectPath?: string): Promise<void> {
    if (this.codexMetadataRequest) {
      if (projectPath) {
        return this.codexMetadataRequest.then(() =>
          this.refreshCodexMetadata(projectPath),
        );
      }
      return this.codexMetadataRequest;
    }
    this.codexMetadataRequest = this.loadAndApplyCodexMetadata(projectPath)
      .catch((err) => {
        console.warn(`[ws] Failed to load Codex metadata: ${err}`);
        this.codexProfiles = [];
        this.defaultCodexProfile = undefined;
        this.codexAutoReviewPolicyLoaded = false;
        this.applyFallbackCodexModels();
        this.broadcastSessionList();
      })
      .finally(() => {
        this.codexMetadataRequest = null;
      });
    return this.codexMetadataRequest;
  }

  private async loadAndApplyCodexMetadata(projectPath?: string): Promise<void> {
    const activeProcess = this.getActiveCodexProcess();
    const codexProcess =
      activeProcess ?? (await this.createStandaloneCodexProcess(projectPath));
    try {
      const [profileResult, modelResult, requirementsResult] =
        await Promise.allSettled([
          codexProcess.readProfileConfig(projectPath),
          this.readCodexModels(codexProcess),
          this.readCodexAutoReviewDisabled(codexProcess),
        ]);

      if (profileResult.status === "fulfilled") {
        this.codexProfiles = profileResult.value.profiles;
        this.defaultCodexProfile = profileResult.value.defaultProfile;
      } else {
        console.warn(
          `[ws] Failed to load Codex profiles: ${profileResult.reason}`,
        );
        this.codexProfiles = [];
        this.defaultCodexProfile = undefined;
      }

      if (modelResult.status === "fulfilled" && modelResult.value.length > 0) {
        this.applyCodexModels(modelResult.value);
      } else {
        if (modelResult.status === "rejected") {
          console.warn(
            `[ws] Failed to load Codex models: ${modelResult.reason}`,
          );
        }
        this.applyFallbackCodexModels();
      }

      if (requirementsResult.status === "fulfilled") {
        this.codexAutoReviewDisabled = requirementsResult.value;
        this.codexAutoReviewPolicyLoaded = true;
      } else {
        console.warn(
          `[ws] Failed to load Codex config requirements: ${requirementsResult.reason}`,
        );
        this.codexAutoReviewPolicyLoaded = false;
      }
      this.broadcastSessionList();
    } finally {
      if (!activeProcess) codexProcess.stop();
    }
  }

  private async refreshClaudeModels(projectPath?: string): Promise<void> {
    if (this.claudeModelsRequest) return this.claudeModelsRequest;
    this.claudeModelsRequest = this.loadClaudeModels(projectPath)
      .then((models) => {
        if (models.length > 0) {
          this.applyClaudeModels(models);
        } else {
          this.applyFallbackClaudeModels();
        }
        this.broadcastSessionList();
      })
      .catch((err) => {
        console.warn(`[ws] Failed to load Claude models: ${err}`);
        this.applyFallbackClaudeModels();
        this.broadcastSessionList();
      })
      .finally(() => {
        this.claudeModelsRequest = null;
      });
    return this.claudeModelsRequest;
  }

  private async loadClaudeModels(
    projectPath?: string,
  ): Promise<ClaudeModelMetadata[]> {
    const activeProcess = this.getActiveClaudeProcess();
    if (activeProcess) {
      const models = await activeProcess.listAvailableModels();
      if (models.length > 0) return models;
    }
    if (process.env.NODE_ENV === "test") return [];
    return listAvailableClaudeModels(projectPath);
  }

  private applyClaudeModels(models: ClaudeModelMetadata[]): void {
    this.claudeModels = models.map((model) => model.model);
    this.claudeModelEfforts = Object.fromEntries(
      models.map((model) => [model.model, model.effortLevels]),
    );
  }

  private applyFallbackClaudeModels(): void {
    this.claudeModels = FALLBACK_CLAUDE_MODELS;
    this.claudeModelEfforts = { ...FALLBACK_CLAUDE_MODEL_EFFORTS };
  }

  private async readCodexModels(
    codexProcess: CodexProcess,
  ): Promise<CodexModelMetadata[]> {
    const modelSource = codexProcess as CodexProcess & {
      listAvailableModelMetadata?: () => Promise<CodexModelMetadata[]>;
      listAvailableModels?: () => Promise<string[]>;
    };
    if (typeof modelSource.listAvailableModelMetadata === "function") {
      return modelSource.listAvailableModelMetadata();
    }
    const models =
      typeof modelSource.listAvailableModels === "function"
        ? await modelSource.listAvailableModels()
        : [];
    return models.map((model) => ({
      model,
      supportedReasoningEfforts: fallbackCodexReasoningEfforts(model),
      supportedServiceTiers: fallbackCodexServiceTiers(model),
    }));
  }

  private async readCodexAutoReviewDisabled(
    codexProcess: CodexProcess,
  ): Promise<boolean> {
    const requirementsSource = codexProcess as CodexProcess & {
      readConfigRequirements?: () => Promise<{
        autoReviewDisabled: boolean;
      }>;
    };
    if (typeof requirementsSource.readConfigRequirements !== "function") {
      return false;
    }
    return (await requirementsSource.readConfigRequirements())
      .autoReviewDisabled;
  }

  private applyCodexModels(models: CodexModelMetadata[]): void {
    this.codexModels = models.map((model) => model.model);
    this.codexModelReasoningEfforts = Object.fromEntries(
      models.map((model) => [
        model.model,
        model.supportedReasoningEfforts.length > 0
          ? model.supportedReasoningEfforts
          : fallbackCodexReasoningEfforts(model.model),
      ]),
    );
    this.codexModelServiceTiers = Object.fromEntries(
      models.map((model) => [
        model.model,
        (model.supportedServiceTiers?.length ?? 0) > 0
          ? model.supportedServiceTiers
          : fallbackCodexServiceTiers(model.model),
      ]),
    );
  }

  private applyFallbackCodexModels(): void {
    this.codexModels = FALLBACK_CODEX_MODELS;
    this.codexModelReasoningEfforts = Object.fromEntries(
      FALLBACK_CODEX_MODELS.map((model) => [
        model,
        fallbackCodexReasoningEfforts(model),
      ]),
    );
    this.codexModelServiceTiers = Object.fromEntries(
      FALLBACK_CODEX_MODELS.map((model) => [
        model,
        fallbackCodexServiceTiers(model),
      ]),
    );
  }

  private async loadCodexProfiles(
    projectPath?: string,
  ): Promise<{ profiles: string[]; defaultProfile?: string }> {
    const process =
      this.getActiveCodexProcess() ??
      (await this.createStandaloneCodexProcess(projectPath));
    const isStandalone = process !== this.getActiveCodexProcess();
    try {
      return await process.readProfileConfig(projectPath);
    } finally {
      if (isStandalone) {
        process.stop();
      }
    }
  }

  private async validateCodexProfile(
    profile: string | undefined,
    projectPath?: string,
  ): Promise<boolean> {
    if (!profile) return true;
    const snapshot = await this.loadCodexProfiles(projectPath);
    this.codexProfiles = snapshot.profiles;
    this.defaultCodexProfile = snapshot.defaultProfile;
    return snapshot.profiles.includes(profile);
  }

  private async resolveCodexResumeProfile(
    requestedProfile: string,
    threadId: string,
    projectPath?: string,
  ): Promise<string | undefined> {
    const snapshot = await this.loadCodexProfiles(projectPath);
    this.codexProfiles = snapshot.profiles;
    this.defaultCodexProfile = snapshot.defaultProfile;
    if (snapshot.profiles.includes(requestedProfile)) {
      return requestedProfile;
    }

    const fallbackProfile =
      snapshot.defaultProfile &&
      snapshot.profiles.includes(snapshot.defaultProfile)
        ? snapshot.defaultProfile
        : undefined;
    console.warn(
      `[ws] Codex profile not found on resume: ${requestedProfile}; ` +
        (fallbackProfile
          ? `falling back to default profile: ${fallbackProfile}`
          : "falling back to Codex config default"),
    );
    saveCodexSessionProfile(threadId, fallbackProfile ?? null).catch((err) => {
      console.warn(`[ws] Failed to update Codex session profile cache: ${err}`);
    });
    return fallbackProfile;
  }

  private getActiveCodexProcess(): CodexProcess | null {
    for (const summary of this.sessionManager.list()) {
      if (summary.provider !== "codex") continue;
      const session = this.sessionManager.get(summary.id);
      if (session?.provider !== "codex") continue;
      const process = session.process as CodexProcess;
      if (process.isRunning) return process;
    }
    return null;
  }

  private withCodexAutoReviewPolicy(
    options: CodexStartOptions,
  ): CodexStartOptions {
    // A managed-policy denial is security-monotonic across automatic runtime
    // restarts. A fresh session may observe an updated policy, but a
    // sandbox/permission restart must not silently weaken an existing session.
    const disableAutoReview =
      this.codexAutoReviewDisabled ||
      options.autoReviewDisabledByPolicy === true;
    const policyKnown =
      this.codexAutoReviewPolicyLoaded ||
      typeof options.autoReviewDisabledByPolicy === "boolean";
    return {
      ...options,
      ...(disableAutoReview ? { approvalsReviewer: "user" as const } : {}),
      ...(disableAutoReview && options.codexPermissionsMode === "autoReview"
        ? { codexPermissionsMode: "default" as const }
        : {}),
      autoReviewDisabledByPolicy: policyKnown ? disableAutoReview : null,
    };
  }

  private getActiveClaudeProcess(): SdkProcess | null {
    const summary = this.sessionManager
      .list()
      .find((session) => session.provider === "claude");
    if (!summary) return null;
    const session = this.sessionManager.get(summary.id);
    return session?.provider === "claude"
      ? (session.process as SdkProcess)
      : null;
  }

  private async listRecentCodexThreads(
    msg: Extract<ClientMessage, { type: "list_recent_sessions" }>,
  ): Promise<{ sessions: unknown[]; hasMore: boolean }> {
    const limit = msg.limit ?? 20;
    const offset = msg.offset ?? 0;
    const process =
      this.getActiveCodexProcess() ??
      (await this.createStandaloneCodexProcess(msg.projectPath));
    const isStandalone = process !== this.getActiveCodexProcess();

    try {
      const archivedIds = this.archiveStore.archivedIds(
        "codex",
        this.codexSourceId,
      );
      const visibleThreads: CodexThreadSummary[] = [];
      let cursor: string | null | undefined;
      let hasServerMore = false;
      let scanBoundReached = false;
      let scannedPages = 0;
      let scannedThreads = 0;
      const targetCount = offset + limit;
      const serverPageSize = Math.min(
        Math.max(targetCount, CODEX_RECENT_THREAD_MIN_PAGE_SIZE),
        CODEX_RECENT_THREAD_MAX_PAGE_SIZE,
      );
      const requestedProjectPath = msg.projectPath
        ? canonicalRecentProjectPath(msg.projectPath, this.platform)
        : null;

      do {
        const remainingScanBudget =
          CODEX_RECENT_THREAD_MAX_SCANNED_THREADS - scannedThreads;
        const request: Parameters<CodexProcess["listThreads"]>[0] = {
          limit: Math.min(serverPageSize, remainingScanBudget),
          searchTerm: msg.searchQuery,
          sourceKinds: CODEX_RECENT_THREAD_SOURCE_KINDS,
        };
        if (cursor != null) request.cursor = cursor;

        const result = await process.listThreads(request);
        scannedPages += 1;
        const scannedPage = result.data.slice(0, remainingScanBudget);
        scannedThreads += scannedPage.length;
        for (const thread of scannedPage) {
          if (
            requestedProjectPath &&
            (!thread.cwd.trim() ||
              canonicalRecentProjectPath(thread.cwd, this.platform) !==
                requestedProjectPath)
          ) {
            continue;
          }
          if (archivedIds.has(thread.id)) continue;
          if (msg.namedOnly && !thread.name) continue;
          visibleThreads.push(thread);
        }
        cursor = result.nextCursor;
        hasServerMore = cursor != null;
        scanBoundReached =
          result.data.length > scannedPage.length ||
          (hasServerMore &&
            (scannedPages >= CODEX_RECENT_THREAD_MAX_SCAN_PAGES ||
              scannedThreads >= CODEX_RECENT_THREAD_MAX_SCANNED_THREADS));
        if (scanBoundReached) break;
      } while (visibleThreads.length < targetCount && cursor != null);

      const pageThreads = visibleThreads.slice(offset, offset + limit);
      const indexedById = await getCodexSessionIndexMetadata(
        pageThreads.map((thread) => thread.id),
      );
      const sessions = pageThreads.map((thread) =>
        codexThreadToRecentSession(thread, indexedById.get(thread.id)),
      );
      return {
        sessions,
        hasMore:
          scanBoundReached ||
          hasServerMore ||
          visibleThreads.length > offset + limit,
      };
    } finally {
      if (isStandalone) {
        process.stop();
      }
    }
  }

  private async createStandaloneCodexProcess(
    projectPath?: string,
    requestTimeoutMs?: number,
  ): Promise<CodexProcess> {
    const proc = new CodexProcess();
    try {
      const cwd = projectPath ?? process.cwd();
      if (requestTimeoutMs === undefined) {
        await proc.initializeOnly(cwd);
      } else {
        await proc.initializeOnly(cwd, requestTimeoutMs);
      }
      return proc;
    } catch (err) {
      proc.stop();
      throw err;
    }
  }

  /** Extract a short project label from the full projectPath (last directory name). */
  private projectLabel(sessionId: string): string {
    const session = this.sessionManager.get(sessionId);
    if (!session?.projectPath) return "";
    const parts = session.projectPath.replace(/\/+$/, "").split("/");
    return parts[parts.length - 1] || "";
  }

  /** Get unique locales from registered tokens. Falls back to ["en"] if none registered. */
  private getRegisteredLocales(): PushLocale[] {
    const locales = new Set(this.tokenLocales.values());
    return locales.size > 0 ? [...locales] : ["en"];
  }

  /** Whether any registered token has privacy mode enabled (conservative: privacy wins). */
  private isPrivacyMode(): boolean {
    for (const privacy of this.tokenPrivacyMode.values()) {
      if (privacy) return true;
    }
    return false;
  }

  /** New noisy events require an explicit opt-in from at least one token. */
  private hasExplicitPushSubscriber(eventType: string): boolean {
    for (const enabledEventTypes of this.tokenEnabledEventTypes.values()) {
      if (enabledEventTypes.has(eventType)) return true;
    }
    return false;
  }

  /** Get a display label for push notification title: "name (project)" or just project. */
  private sessionLabel(sessionId: string): string {
    const session = this.sessionManager.get(sessionId);
    const project = this.projectLabel(sessionId);
    if (session?.name) {
      return project ? `${session.name} (${project})` : session.name;
    }
    return project;
  }

  private notificationDataSourceFields(
    provider: "claude" | "codex",
  ): Record<string, string> {
    if (!this.bridgeInstanceId) return {};
    return {
      bridgeInstanceId: this.bridgeInstanceId,
      ...(provider === "codex" ? { codexSourceId: this.codexSourceId } : {}),
    };
  }

  private isBackgroundNotificationCandidate(msg: ServerMessage): boolean {
    if (msg.type === "permission_request") return true;
    // The projector also clears per-turn deduplication on stopped results, so
    // keep routing every terminal result through it even when no notification
    // will be emitted.
    if (msg.type === "result") return true;
    return (
      msg.type === "assistant" &&
      Array.isArray(msg.message.content) &&
      msg.message.content.some(
        (content) =>
          content.type === "tool_use" &&
          typeof content.id === "string" &&
          content.id.length > 0 &&
          typeof content.name === "string" &&
          content.name.length > 0,
      )
    );
  }

  private queuePushNotifications(
    deliveryId: string | undefined,
    payloads: PushNotifyPayload[],
  ): void {
    if (
      !deliveryId ||
      payloads.length === 0 ||
      this.pendingBackgroundPushDeliveries.size >=
        MAX_PENDING_BACKGROUND_PUSH_DELIVERIES
    ) {
      this.dispatchPushNotifications(payloads);
      return;
    }

    const candidateTokens = new Set<string>();
    for (const client of this.wss.clients) {
      if (
        client.readyState !== WebSocket.OPEN ||
        this.backgroundDeliveryClients.get(client)?.mode !==
          "notifications_only"
      ) {
        continue;
      }
      for (const token of this.clientPushTokens.get(client) ?? []) {
        candidateTokens.add(token);
      }
    }
    if (candidateTokens.size === 0) {
      this.dispatchPushNotifications(payloads);
      return;
    }

    const timer = setTimeout(() => {
      this.flushPendingBackgroundPushDelivery(deliveryId);
    }, BACKGROUND_PUSH_ACK_WAIT_MS);
    timer.unref?.();
    this.pendingBackgroundPushDeliveries.set(deliveryId, {
      payloads,
      candidateTokens,
      acknowledgedTokens: new Set(),
      timer,
    });
  }

  private acknowledgeBackgroundNotification(
    client: WebSocket,
    deliveryId: string,
  ): void {
    const pending = this.pendingBackgroundPushDeliveries.get(deliveryId);
    const clientTokens = this.clientPushTokens.get(client);
    if (!pending || !clientTokens) return;
    for (const token of clientTokens) {
      if (pending.candidateTokens.has(token)) {
        pending.acknowledgedTokens.add(token);
      }
    }
  }

  private flushPendingBackgroundPushDelivery(deliveryId: string): void {
    const pending = this.pendingBackgroundPushDeliveries.get(deliveryId);
    if (!pending) return;
    clearTimeout(pending.timer);
    this.pendingBackgroundPushDeliveries.delete(deliveryId);
    this.dispatchPushNotifications(
      pending.payloads,
      Array.from(pending.acknowledgedTokens),
    );
  }

  private flushAllPendingBackgroundPushDeliveries(): void {
    for (const deliveryId of Array.from(
      this.pendingBackgroundPushDeliveries.keys(),
    )) {
      this.flushPendingBackgroundPushDelivery(deliveryId);
    }
  }

  private dispatchPushNotifications(
    payloads: PushNotifyPayload[],
    excludedTokens: string[] = [],
  ): void {
    for (const payload of payloads) {
      void this.pushRelay
        .notify({
          ...payload,
          ...(excludedTokens.length > 0 ? { excludedTokens } : {}),
        })
        .catch((err) => {
          const detail = err instanceof Error ? err.message : String(err);
          console.warn(
            `[ws] Failed to send push notification (${payload.eventType}, ${payload.locale ?? "default"}): ${detail}`,
          );
        });
    }
  }

  private maybeSendPushNotification(
    sessionId: string,
    msg: ServerMessage,
    deliveryId?: string,
  ): void {
    if (!this.pushRelay.isConfigured) return;

    const privacy = this.isPrivacyMode();
    const label = privacy ? "" : this.sessionLabel(sessionId);

    if (msg.type === "assistant" && Array.isArray(msg.message.content)) {
      if (!this.hasExplicitPushSubscriber(PUSH_PROGRESS_EVENT)) return;
      const toolUse = [...msg.message.content]
        .reverse()
        .find((content) => content.type === "tool_use");
      if (!toolUse || !toolUse.id || !toolUse.name) return;

      const now = Date.now();
      const last = this.progressNotificationState.get(sessionId);
      const toolKey = `${toolUse.id}:${toolUse.name}`;
      if (
        last?.lastToolKey === toolKey ||
        (last != null && now - last.lastSentAt < PUSH_PROGRESS_MIN_INTERVAL_MS)
      ) {
        return;
      }
      this.progressNotificationState.set(sessionId, {
        lastSentAt: now,
        lastToolKey: toolKey,
      });

      const session = this.sessionManager.get(sessionId);
      const provider = session?.provider ?? "claude";
      const data: Record<string, string> = {
        sessionId,
        provider,
        occurredAt: new Date(now).toISOString(),
        ...this.notificationDataSourceFields(provider),
      };
      if (deliveryId) data.deliveryId = deliveryId;
      if (session?.claudeSessionId) {
        data.providerSessionId = session.claudeSessionId;
      }
      if (!privacy) {
        data.toolUseId = toolUse.id;
        data.toolName = toolUse.name;
      }
      const payloads = this.getRegisteredLocales().map((locale) => {
        const baseTitle = t(locale, "progress_title");
        const title = label ? `${baseTitle} - ${label}` : baseTitle;
        const body = privacy
          ? t(locale, "progress_body_private")
          : t(locale, "progress_body", { toolName: toolUse.name });
        return {
          eventType: PUSH_PROGRESS_EVENT,
          title,
          body,
          locale,
          data,
        };
      });
      this.queuePushNotifications(deliveryId, payloads);
      return;
    }

    if (msg.type === "permission_request") {
      const seen =
        this.notifiedPermissionToolUses.get(sessionId) ?? new Set<string>();
      if (seen.has(msg.toolUseId)) return;
      seen.add(msg.toolUseId);
      this.notifiedPermissionToolUses.set(sessionId, seen);

      const isAskUserQuestion = msg.toolName === "AskUserQuestion";
      const isExitPlanMode = msg.toolName === "ExitPlanMode";
      const eventType = isAskUserQuestion
        ? "ask_user_question"
        : "approval_required";

      // Extract question text for AskUserQuestion (standard mode only)
      let questionText: string | undefined;
      if (!privacy && isAskUserQuestion) {
        const questions = msg.input?.questions;
        const firstQuestion =
          Array.isArray(questions) && questions.length > 0
            ? (questions[0] as Record<string, unknown>)?.question
            : undefined;
        if (typeof firstQuestion === "string" && firstQuestion.length > 0) {
          questionText = firstQuestion.slice(0, 120);
        }
      }

      const session = this.sessionManager.get(sessionId);
      const provider = session?.provider ?? "claude";
      const data: Record<string, string> = {
        sessionId,
        provider,
        permissionId: msg.toolUseId,
        occurredAt: new Date().toISOString(),
        ...this.notificationDataSourceFields(provider),
      };
      if (deliveryId) data.deliveryId = deliveryId;
      if (session?.claudeSessionId) {
        data.providerSessionId = session.claudeSessionId;
      }
      if (!privacy) {
        data.toolUseId = msg.toolUseId;
        data.toolName = msg.toolName;
      }

      const payloads = this.getRegisteredLocales().map((locale) => {
        let title: string;
        let body: string;

        if (isExitPlanMode) {
          const titleKey = "plan_ready_title";
          title = label
            ? `${t(locale, titleKey)} - ${label}`
            : t(locale, titleKey);
          body = t(locale, "plan_ready_body");
        } else if (isAskUserQuestion) {
          const titleKey = "ask_title";
          title = label
            ? `${t(locale, titleKey)} - ${label}`
            : t(locale, titleKey);
          body = privacy
            ? t(locale, "ask_body_private")
            : (questionText ?? t(locale, "ask_default_body"));
        } else {
          const titleKey = "approval_title";
          title = label
            ? `${t(locale, titleKey)} - ${label}`
            : t(locale, titleKey);
          body = privacy
            ? t(locale, "approval_body_private")
            : t(locale, "approval_body", { toolName: msg.toolName });
        }

        return { eventType, title, body, locale, data };
      });
      this.queuePushNotifications(deliveryId, payloads);
      return;
    }

    if (msg.type !== "result") return;
    if (msg.subtype === "stopped") return;
    if (msg.subtype !== "success" && msg.subtype !== "error") return;

    const isSuccess = msg.subtype === "success";
    this.progressNotificationState.delete(sessionId);
    const eventType = isSuccess ? "session_completed" : "session_failed";

    const pieces: string[] = [];
    if (isSuccess) {
      if (msg.duration != null) pieces.push(`${msg.duration.toFixed(1)}s`);
      if (msg.cost != null) pieces.push(`$${msg.cost.toFixed(4)}`);
    }
    const stats = pieces.length > 0 ? ` (${pieces.join(", ")})` : "";

    const session = this.sessionManager.get(sessionId);
    const provider = session?.provider ?? "claude";
    const data: Record<string, string> = {
      sessionId,
      provider,
      subtype: msg.subtype,
      occurredAt: new Date().toISOString(),
      ...this.notificationDataSourceFields(provider),
    };
    if (deliveryId) data.deliveryId = deliveryId;
    if (session?.claudeSessionId) {
      data.providerSessionId = session.claudeSessionId;
    }
    if (msg.stopReason) data.stopReason = msg.stopReason;
    if (msg.sessionId) data.providerSessionId = msg.sessionId;

    const payloads = this.getRegisteredLocales().map((locale) => {
      let title: string;
      if (privacy) {
        title = isSuccess
          ? t(locale, "task_completed")
          : t(locale, "error_occurred");
      } else {
        title = label
          ? isSuccess
            ? `✅ ${label}`
            : `❌ ${label}`
          : isSuccess
            ? t(locale, "task_completed")
            : t(locale, "error_occurred");
      }

      let body: string;
      if (privacy) {
        const privateBody = isSuccess
          ? t(locale, "result_success_body_private")
          : t(locale, "result_error_body_private");
        body = isSuccess ? `${privateBody}${stats}` : privateBody;
      } else if (isSuccess) {
        body = msg.result
          ? `${msg.result.slice(0, 120)}${stats}`
          : `${t(locale, "session_completed")}${stats}`;
      } else {
        body = msg.error
          ? msg.error.slice(0, 120)
          : t(locale, "session_failed");
      }

      return { eventType, title, body, locale, data };
    });
    this.queuePushNotifications(deliveryId, payloads);
  }

  private broadcast(msg: Record<string, unknown>): void {
    for (const client of this.wss.clients) {
      if (client.readyState === WebSocket.OPEN) {
        const compatibleMsg = this.prepareServerMessageForClient(client, msg);
        if (!compatibleMsg) continue;
        client.send(JSON.stringify(compatibleMsg));
      }
    }
  }

  private clientWantsSessionCatalogWatch(client: WebSocket): boolean {
    return (
      client.readyState === WebSocket.OPEN &&
      this.clientSupportedServerMessages
        .get(client)
        ?.has(SESSION_CATALOG_CHANGED_MESSAGE) === true &&
      this.backgroundDeliveryClients.get(client)?.mode !== "notifications_only"
    );
  }

  private refreshSessionCatalogMonitorState(): void {
    const shouldRun = Array.from(this.wss.clients).some((client) =>
      this.clientWantsSessionCatalogWatch(client),
    );
    if (!shouldRun) {
      this.sessionCatalogMonitor.close();
      return;
    }
    void this.sessionCatalogMonitor.start().catch((error) => {
      console.warn(
        "[sessions-index] Failed to start catalog monitor:",
        error instanceof Error ? error.message : String(error),
      );
    });
  }

  private broadcastSessionCatalogChanged(
    revision: number,
    change?: SessionCatalogChange,
  ): void {
    if (!this.sessionCatalogMonitor.isActive) return;
    this.localFeatures.sessionCatalogChanged(change ?? { revision });
    this.broadcast({
      type: SESSION_CATALOG_CHANGED_MESSAGE,
      revision,
      occurredAt: new Date().toISOString(),
    });
  }

  private prepareServerMessageForClient(
    ws: WebSocket,
    msg: ServerMessage | Record<string, unknown>,
  ): ServerMessage | Record<string, unknown> | null {
    if (this.backgroundDeliveryClients.get(ws)?.mode === "notifications_only") {
      if (msg.type === "session_list") {
        return this.shouldSendToClient(ws, this.backgroundActivityState())
          ? this.backgroundActivityState()
          : null;
      }
      if (
        msg.type !== CLIENT_DELIVERY_MODE_STATE_MESSAGE &&
        msg.type !== BACKGROUND_NOTIFICATION_MESSAGE &&
        msg.type !== BACKGROUND_ACTIVITY_STATE_MESSAGE &&
        msg.type !== PUSH_REGISTRATION_STATE_MESSAGE
      ) {
        return null;
      }
    }
    if (!this.shouldSendToClient(ws, msg)) return null;
    if (!("messages" in msg) || !Array.isArray(msg.messages)) return msg;
    const messages = msg.messages as unknown[];

    if (msg.type === "history") {
      return {
        ...(msg as unknown as Record<string, unknown>),
        messages: messages.filter(
          (message) =>
            isRecord(message) && this.shouldSendToClient(ws, message),
        ),
      };
    }
    if (msg.type === "history_delta" || msg.type === "history_snapshot") {
      return {
        ...(msg as unknown as Record<string, unknown>),
        messages: messages.filter((entry) => {
          if (!isRecord(entry) || !isRecord(entry.message)) return true;
          return this.shouldSendToClient(ws, entry.message);
        }),
      };
    }
    return msg;
  }

  private backgroundActiveWorkCount(): number {
    return this.sessionManager.list().filter((session) => {
      return (
        session.queuedInput != null ||
        session.status === "starting" ||
        session.status === "running" ||
        session.status === "compacting"
      );
    }).length;
  }

  private backgroundActivityState(): BackgroundActivityStateMessage {
    return {
      type: BACKGROUND_ACTIVITY_STATE_MESSAGE,
      activeWorkCount: this.backgroundActiveWorkCount(),
      occurredAt: new Date().toISOString(),
    };
  }

  private shouldSendToClient(
    ws: WebSocket,
    msg: ServerMessage | Record<string, unknown>,
  ): boolean {
    const type = typeof msg.type === "string" ? msg.type : "";
    if (
      type === "goal_state" &&
      hasUnknownCodexGoalStatus(msg) &&
      !this.clientSupportedServerMessages
        .get(ws)
        ?.has(CODEX_GOAL_RAW_STATUS_CAPABILITY)
    ) {
      return false;
    }
    if (
      !OPT_IN_SERVER_MESSAGES.has(type) &&
      !isLocalFeatureServerMessageType(type) &&
      !isFileTransferServerMessageType(type)
    ) {
      return true;
    }
    return this.clientSupportedServerMessages.get(ws)?.has(type) ?? false;
  }

  private clientSupportsRawCodexGoalStatus(
    ws: WebSocket,
    goal: CodexGoal | null,
  ): boolean {
    return (
      goal == null ||
      KNOWN_CODEX_GOAL_STATUSES.has(goal.status) ||
      (this.clientSupportedServerMessages
        .get(ws)
        ?.has(CODEX_GOAL_RAW_STATUS_CAPABILITY) ??
        false)
    );
  }

  private sendGoalStatusUnsupported(
    ws: WebSocket,
    sessionId: string,
    goalChangeId?: string,
  ): void {
    this.send(ws, {
      type: "error",
      message:
        "This Codex backend returned a newer Goal status. Update the mobile client before managing this Goal.",
      errorCode: "goal_status_unsupported",
      sessionId,
      ...(goalChangeId ? { goalChangeId } : {}),
    });
  }

  private hasInputConflictSince(
    session: SessionInfo,
    baseSeq: number,
  ): boolean {
    const codexResetRevision =
      session.codexHistoryResetRevision ??
      session.codexCanonicalHistoryRevision;
    if (
      session.provider === "codex" &&
      typeof codexResetRevision === "number" &&
      baseSeq < codexResetRevision
    ) {
      return true;
    }

    const delta = this.sessionManager.getHistorySince(session.id, baseSeq);
    if (!delta) return true;
    if (delta.kind === "snapshot") return true;

    return delta.entries.some((entry) => {
      const msg = entry.message;
      if (msg.type === "user_input" || msg.type === "result") return true;
      if (msg.type === "system") {
        const subtype = (msg as Record<string, unknown>).subtype;
        return (
          subtype === "session_switched" ||
          subtype === "session_rewound" ||
          subtype === "sandbox_restarted" ||
          subtype === "session_stopped"
        );
      }
      return false;
    });
  }

  private findAcceptedClientInput(
    session: SessionInfo,
    clientMessageId: string,
  ): InputDeliveryReceipt | null {
    // A few legacy adapters and lightweight test doubles implement only the
    // pre-receipt SessionManager surface. Treat the receipt ledger as an
    // additive enhancement so those paths keep their existing ACK behavior.
    const getInputDeliveryReceipt = (
      this.sessionManager as unknown as {
        getInputDeliveryReceipt?: (
          sessionId: string,
          messageId: string,
        ) => InputDeliveryReceipt | undefined;
      }
    ).getInputDeliveryReceipt;
    const receipt =
      typeof getInputDeliveryReceipt === "function"
        ? getInputDeliveryReceipt.call(
            this.sessionManager,
            session.id,
            clientMessageId,
          )
        : undefined;
    if (receipt) return receipt;
    if (session.codexQueuedInput?.clientMessageId === clientMessageId) {
      return {
        clientMessageId,
        stage: "bridge_accepted",
        acceptedSeq: session.historyRevision,
        queued: true,
        occurredAt: new Date().toISOString(),
      };
    }

    for (let index = session.historyEntries.length - 1; index >= 0; index--) {
      const entry = session.historyEntries[index];
      const message = entry.message;
      if (
        message.type === "user_input" &&
        message.clientMessageId === clientMessageId
      ) {
        return {
          clientMessageId,
          stage: "bridge_accepted",
          acceptedSeq: entry.seq,
          queued: false,
          occurredAt: new Date().toISOString(),
        };
      }
    }
    return null;
  }

  private sendInputBridgeAcceptance(
    ws: WebSocket,
    session: SessionInfo,
    clientMessageId: string | undefined,
    acceptedSeq: number,
    queued: boolean,
  ): void {
    if (clientMessageId) {
      const recordInputBridgeAcceptance = (
        this.sessionManager as unknown as {
          recordInputBridgeAcceptance?: (
            sessionId: string,
            messageId: string,
            seq: number,
            isQueued: boolean,
          ) => InputDeliveryReceipt | undefined;
        }
      ).recordInputBridgeAcceptance;
      if (typeof recordInputBridgeAcceptance === "function") {
        recordInputBridgeAcceptance.call(
          this.sessionManager,
          session.id,
          clientMessageId,
          acceptedSeq,
          queued,
        );
      }
    }
    this.send(ws, {
      type: "input_ack",
      sessionId: session.id,
      ...(clientMessageId
        ? {
            clientMessageId,
            stage: "bridge_accepted",
          }
        : {}),
      acceptedSeq,
      queued,
    });
  }

  private sendProviderInputReceipt(
    ws: WebSocket,
    session: SessionInfo,
    receipt: InputDeliveryReceipt,
  ): void {
    if (
      receipt.stage === "bridge_accepted" ||
      receipt.provider !== "codex" ||
      !receipt.method
    ) {
      return;
    }
    this.send(ws, {
      type: INPUT_DELIVERY_STATUS_MESSAGE,
      sessionId: session.id,
      clientMessageId: receipt.clientMessageId,
      stage: receipt.stage,
      provider: receipt.provider,
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
  }

  private sendCodexQueueState(
    ws: WebSocket,
    sessionId: string,
    session: SessionInfo,
  ): void {
    const item = publicQueuedInput(
      session.codexQueuedInput,
      session.codexQueuedInput?.clientMessageId
        ? session.inputDeliveryReceipts?.get(
            session.codexQueuedInput.clientMessageId,
          )
        : undefined,
    );
    this.sendConversationQueue(ws, {
      type: "conversation_queue",
      sessionId,
      limit: 1,
      items: item
        ? [
            item,
          ]
        : [],
    } as Record<string, unknown>);
  }

  private sendCodexGoalState(
    ws: WebSocket,
    sessionId: string,
    session: SessionInfo,
  ): void {
    if (session.codexGoal === undefined) return;
    this.send(ws, {
      type: "goal_state",
      sessionId,
      goal: session.codexGoal,
      ...(session.codexGoalOperationSequence !== undefined
        ? {
            goalOperationSequence: session.codexGoalOperationSequence,
          }
        : {}),
    });
  }

  private sendCachedCommands(
    ws: WebSocket,
    sessionId: string,
    session: SessionInfo,
  ): void {
    // Restore command metadata when the original init/supported_commands event
    // has fallen out of the bounded in-memory history.
    const cached = this.sessionManager.getCachedCommands(
      session.provider,
      session.worktreePath ?? session.projectPath,
    );
    if (
      !cached ||
      (cached.slashCommands.length === 0 &&
        cached.skills.length === 0 &&
        cached.apps.length === 0 &&
        cached.plugins.length === 0)
    ) {
      return;
    }

    this.send(ws, {
      type: "system",
      subtype: "supported_commands",
      sessionId,
      slashCommands: cached.slashCommands,
      skills: cached.skills,
      ...(cached.skillMetadata ? { skillMetadata: cached.skillMetadata } : {}),
      apps: cached.apps,
      ...(cached.appMetadata ? { appMetadata: cached.appMetadata } : {}),
      plugins: cached.plugins,
      ...(cached.pluginMetadata
        ? { pluginMetadata: cached.pluginMetadata }
        : {}),
    });
  }

  private sendConversationQueue(
    ws: WebSocket,
    msg:
      | Extract<ServerMessage, { type: "conversation_queue" }>
      | Record<string, unknown>,
  ): void {
    if (!this.shouldSendToClient(ws, msg)) return;
    this.send(ws, msg);
  }

  private sendPushRegistrationResult(
    ws: WebSocket,
    request: Extract<
      ClientMessage,
      { type: "push_register" | "push_unregister" }
    >,
    result: Omit<PushRegistrationStateMessage, "type" | "requestId"> & {
      legacyError?: string;
    },
  ): void {
    const requestId = request.requestId;
    if (
      requestId &&
      this.clientSupportedServerMessages
        .get(ws)
        ?.has(PUSH_REGISTRATION_STATE_MESSAGE)
    ) {
      this.send(ws, {
        type: PUSH_REGISTRATION_STATE_MESSAGE,
        requestId,
        operation: result.operation,
        success: result.success,
        ...(result.errorCode ? { errorCode: result.errorCode } : {}),
      });
      return;
    }
    if (!result.success && result.legacyError) {
      this.send(ws, { type: "error", message: result.legacyError });
    }
  }

  private async runPushTokenOperation(
    token: string,
    operation: () => Promise<void>,
  ): Promise<void> {
    const previous = this.pushTokenOperations.get(token);
    const current = (previous ?? Promise.resolve())
      .catch(() => undefined)
      .then(operation);
    this.pushTokenOperations.set(token, current);
    try {
      await current;
    } finally {
      if (this.pushTokenOperations.get(token) === current) {
        this.pushTokenOperations.delete(token);
      }
    }
  }

  private restorePushTokenPreferences(
    token: string,
    locale: { present: boolean; value?: PushLocale },
    privacy: { present: boolean; value?: boolean },
    eventTypes: { present: boolean; value?: Set<string> },
  ): void {
    if (locale.present && locale.value != null) {
      this.tokenLocales.set(token, locale.value);
    } else {
      this.tokenLocales.delete(token);
    }
    if (privacy.present && privacy.value != null) {
      this.tokenPrivacyMode.set(token, privacy.value);
    } else {
      this.tokenPrivacyMode.delete(token);
    }
    if (eventTypes.present && eventTypes.value != null) {
      this.tokenEnabledEventTypes.set(token, new Set(eventTypes.value));
    } else {
      this.tokenEnabledEventTypes.delete(token);
    }
  }

  private send(
    ws: WebSocket,
    msg: ServerMessage | Record<string, unknown>,
  ): void {
    const compatibleMsg = this.prepareServerMessageForClient(ws, msg);
    if (!compatibleMsg) return;
    const sessionId = this.extractSessionIdFromServerMessage(compatibleMsg);
    if (sessionId && this.sessionManager.get(sessionId)) {
      this.recordDebugEvent(sessionId, {
        direction: "outgoing",
        channel: "ws",
        type: String(compatibleMsg.type ?? "unknown"),
        detail: this.summarizeOutboundMessage(compatibleMsg),
      });
    }
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify(compatibleMsg));
    }
  }

  /** Broadcast a gallery_new_image message to all connected clients. */
  broadcastGalleryNewImage(
    image: import("./gallery-store.js").GalleryImageInfo,
  ): void {
    this.broadcast({ type: "gallery_new_image", image });
  }

  private collectGitDiff(
    cwd: string,
    callback: (result: { diff: string; error?: string }) => void,
    options?: { staged?: boolean; unstaged?: boolean },
  ): void {
    const execOpts = { cwd, maxBuffer: 10 * 1024 * 1024 };
    const gitArgs = (...args: string[]) => [
      "-c",
      "core.quotePath=false",
      ...args,
    ];
    const listUntrackedFiles = () => {
      const out = execFileSync(
        "git",
        gitArgs("ls-files", "-z", "--others", "--exclude-standard"),
        { cwd, encoding: "utf-8" },
      );
      return out.split("\0").filter(Boolean);
    };

    // Staged only: git diff --cached
    if (options?.staged) {
      execFile(
        "git",
        gitArgs("diff", "--cached", "--no-color"),
        execOpts,
        (err, stdout) => {
          if (err) {
            callback({ diff: "", error: err.message });
            return;
          }
          callback({ diff: stdout });
        },
      );
      return;
    }

    // Unstaged only: git diff (working tree vs index) — original behavior
    if (options?.unstaged) {
      // Collect untracked files so they appear in the diff.
      let untrackedFiles: string[] = [];
      try {
        untrackedFiles = listUntrackedFiles();
      } catch {
        // Ignore errors: non-git directories are handled by git diff callback.
      }

      // Temporarily stage untracked files with --intent-to-add.
      if (untrackedFiles.length > 0) {
        try {
          execFileSync(
            "git",
            ["add", "--intent-to-add", "--", ...untrackedFiles],
            {
              cwd,
            },
          );
        } catch {
          // Ignore staging errors.
        }
      }

      execFile(
        "git",
        gitArgs("diff", "--no-color"),
        execOpts,
        (err, stdout) => {
          // Revert intent-to-add for untracked files.
          if (untrackedFiles.length > 0) {
            try {
              execFileSync("git", ["reset", "--", ...untrackedFiles], { cwd });
            } catch {
              // Ignore reset errors.
            }
          }

          if (err) {
            callback({ diff: "", error: err.message });
            return;
          }
          callback({ diff: stdout });
        },
      );
      return;
    }

    // All mode (no options): git diff HEAD — shows both staged and unstaged vs HEAD
    let untrackedFilesAll: string[] = [];
    try {
      untrackedFilesAll = listUntrackedFiles();
    } catch {
      // Ignore
    }

    if (untrackedFilesAll.length > 0) {
      try {
        execFileSync(
          "git",
          ["add", "--intent-to-add", "--", ...untrackedFilesAll],
          {
            cwd,
          },
        );
      } catch {
        // Ignore
      }
    }

    execFile(
      "git",
      gitArgs("diff", "HEAD", "--no-color"),
      execOpts,
      (err, stdout) => {
        if (untrackedFilesAll.length > 0) {
          try {
            execFileSync("git", ["reset", "--", ...untrackedFilesAll], { cwd });
          } catch {
            // Ignore
          }
        }

        if (err) {
          callback({ diff: "", error: err.message });
          return;
        }
        callback({ diff: stdout });
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Image diff helpers
  // ---------------------------------------------------------------------------

  private static readonly IMAGE_EXTENSIONS = new Set([
    ".png",
    ".jpg",
    ".jpeg",
    ".gif",
    ".webp",
    ".ico",
    ".bmp",
    ".svg",
  ]);

  private static readonly FILE_PEEK_IMAGE_EXTENSIONS = new Set([
    ".png",
    ".jpg",
    ".jpeg",
    ".gif",
    ".webp",
    ".svg",
  ]);

  // Image diff thresholds (configurable via environment variables)
  // - Auto-display: images ≤ threshold are sent inline as base64
  // - Max size: images ≤ max are available for on-demand loading
  // - Images > max size show text info only
  private static readonly AUTO_DISPLAY_THRESHOLD = (() => {
    const kb = parseInt(process.env.DIFF_IMAGE_AUTO_DISPLAY_KB ?? "", 10);
    return Number.isFinite(kb) && kb > 0 ? kb * 1024 : 1024 * 1024; // default 1 MB
  })();
  private static readonly MAX_IMAGE_SIZE = (() => {
    const mb = parseInt(process.env.DIFF_IMAGE_MAX_SIZE_MB ?? "", 10);
    return Number.isFinite(mb) && mb > 0 ? mb * 1024 * 1024 : 5 * 1024 * 1024; // default 5 MB
  })();

  private static mimeTypeForExt(ext: string): string {
    const map: Record<string, string> = {
      ".png": "image/png",
      ".jpg": "image/jpeg",
      ".jpeg": "image/jpeg",
      ".gif": "image/gif",
      ".webp": "image/webp",
      ".ico": "image/x-icon",
      ".bmp": "image/bmp",
      ".svg": "image/svg+xml",
    };
    return map[ext.toLowerCase()] ?? "application/octet-stream";
  }

  /**
   * Scan diff text for image file changes and extract base64 data where appropriate.
   *
   * Detection strategy:
   * 1. Binary markers: "Binary files a/<path> and b/<path> differ"
   * 2. diff --git headers where the file extension is an image type
   *
   * For each detected image file:
   * - Old version: `git show HEAD:<path>` (committed version)
   * - New version: read from working tree
   * - Apply size thresholds for auto-display / on-demand / text-only
   */
  private async collectImageChanges(
    cwd: string,
    diffText: string,
  ): Promise<ImageChange[]> {
    // Phase 1: Extract image file entries from diff text (synchronous, CPU only)
    interface ImageEntry {
      filePath: string;
      isNew: boolean;
      isDeleted: boolean;
      isSvg: boolean;
      mimeType: string;
      ext: string;
    }
    const entries: ImageEntry[] = [];
    const processedPaths = new Set<string>();

    const lines = diffText.split("\n");
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];

      const gitMatch = line.match(/^diff --git a\/(.+?) b\/(.+)$/);
      if (!gitMatch) continue;

      const filePath = gitMatch[2];
      const ext = extname(filePath).toLowerCase();
      if (!BridgeWebSocketServer.IMAGE_EXTENSIONS.has(ext)) continue;
      if (processedPaths.has(filePath)) continue;
      processedPaths.add(filePath);

      let isNew = false;
      let isDeleted = false;
      for (let j = i + 1; j < Math.min(i + 6, lines.length); j++) {
        if (lines[j].startsWith("diff --git ")) break;
        if (lines[j].startsWith("new file mode")) isNew = true;
        if (lines[j].startsWith("deleted file mode")) isDeleted = true;
      }

      entries.push({
        filePath,
        isNew,
        isDeleted,
        isSvg: ext === ".svg",
        mimeType: BridgeWebSocketServer.mimeTypeForExt(ext),
        ext,
      });
    }

    if (entries.length === 0) return [];

    // Phase 2: Read image data asynchronously
    const execFileAsync = promisify(execFile);

    const changes: ImageChange[] = [];
    for (const entry of entries) {
      let oldBuf: Buffer | undefined;
      let newBuf: Buffer | undefined;

      // Read old image (committed version)
      if (!entry.isNew) {
        try {
          const result = await execFileAsync(
            "git",
            ["show", `HEAD:${entry.filePath}`],
            {
              cwd,
              maxBuffer: BridgeWebSocketServer.MAX_IMAGE_SIZE + 1024,
              encoding: "buffer",
            },
          );
          oldBuf = result.stdout as unknown as Buffer;
        } catch {
          // File may not exist in HEAD (e.g. untracked)
        }
      }

      // Read new image (working tree)
      if (!entry.isDeleted) {
        try {
          const absPath = resolve(cwd, entry.filePath);
          if (existsSync(absPath)) {
            newBuf = await readFile(absPath);
          }
        } catch {
          // Ignore read errors
        }
      }

      const oldSize = oldBuf?.length;
      const newSize = newBuf?.length;
      const maxSize = Math.max(oldSize ?? 0, newSize ?? 0);

      const autoDisplay =
        maxSize <= BridgeWebSocketServer.AUTO_DISPLAY_THRESHOLD;
      const loadable =
        autoDisplay || maxSize <= BridgeWebSocketServer.MAX_IMAGE_SIZE;

      const change: ImageChange = {
        filePath: entry.filePath,
        isNew: entry.isNew,
        isDeleted: entry.isDeleted,
        isSvg: entry.isSvg,
        mimeType: entry.mimeType,
        loadable,
        autoDisplay: autoDisplay || undefined,
      };

      if (oldSize !== undefined) change.oldSize = oldSize;
      if (newSize !== undefined) change.newSize = newSize;

      // Auto-display images are no longer embedded in the initial response.
      // They are loaded on-demand when the Flutter widget becomes visible.

      changes.push(change);
    }

    return changes;
  }

  /**
   * Load a single diff image on demand (async I/O for better throughput).
   */
  private async loadDiffImageAsync(
    cwd: string,
    filePath: string,
    version: "old" | "new",
  ): Promise<{ base64?: string; mimeType?: string; error?: string }> {
    // Path traversal guard: reject paths containing '..' or absolute paths
    if (filePath.includes("..") || filePath.startsWith("/")) {
      return { error: "Invalid file path" };
    }

    const ext = extname(filePath).toLowerCase();
    if (!BridgeWebSocketServer.IMAGE_EXTENSIONS.has(ext)) {
      return { error: "Not an image file" };
    }
    const mimeType = BridgeWebSocketServer.mimeTypeForExt(ext);

    try {
      const execFileAsync = promisify(execFile);

      let buf: Buffer;
      if (version === "old") {
        const result = await execFileAsync(
          "git",
          ["show", `HEAD:${filePath}`],
          {
            cwd,
            maxBuffer: BridgeWebSocketServer.MAX_IMAGE_SIZE + 1024,
            encoding: "buffer",
          },
        );
        buf = result.stdout as unknown as Buffer;
      } else {
        const absPath = resolve(cwd, filePath);
        // Verify resolved path stays within cwd
        if (!isPathWithinAllowedDirectory(absPath, cwd, this.platform)) {
          return { error: "Invalid file path" };
        }
        buf = await readFile(absPath);
      }

      if (buf.length > BridgeWebSocketServer.MAX_IMAGE_SIZE) {
        return { error: "Image too large" };
      }

      return { base64: buf.toString("base64"), mimeType };
    } catch (err) {
      return { error: err instanceof Error ? err.message : String(err) };
    }
  }

  private extractSessionIdFromClientMessage(
    msg: ClientMessage,
  ): string | undefined {
    return "sessionId" in msg && typeof msg.sessionId === "string"
      ? msg.sessionId
      : undefined;
  }

  private extractSessionIdFromServerMessage(
    msg: ServerMessage | Record<string, unknown>,
  ): string | undefined {
    if ("sessionId" in msg && typeof msg.sessionId === "string")
      return msg.sessionId;
    return undefined;
  }

  private recordDebugEvent(
    sessionId: string,
    event: Omit<DebugTraceEvent, "ts" | "sessionId">,
  ): void {
    const events = this.debugEvents.get(sessionId) ?? [];
    const fullEvent: DebugTraceEvent = {
      ts: new Date().toISOString(),
      sessionId,
      ...event,
    };
    events.push(fullEvent);
    if (events.length > BridgeWebSocketServer.MAX_DEBUG_EVENTS) {
      events.splice(0, events.length - BridgeWebSocketServer.MAX_DEBUG_EVENTS);
    }
    this.debugEvents.set(sessionId, events);
    this.debugTraceStore.record(fullEvent);
  }

  private async tryResumePermissionRestartGoal(
    sessionId: string,
    lease: CodexGoalResumeLease,
    reason: string,
  ): Promise<boolean> {
    try {
      const latestGoal = await this.codexGoals.refresh(sessionId);
      if (!matchesCodexGoalResumeLease(latestGoal, lease)) {
        console.warn(
          `[ws] Skipping Goal resume after ${reason}: the paused Goal was cleared, replaced, or changed`,
        );
        return false;
      }
      await this.codexGoals.resumeWithLease(sessionId, lease);
      return true;
    } catch (error) {
      console.warn(
        `[ws] Failed to verify and resume Goal after ${reason}: ${errorMessageOf(error)}`,
      );
      return false;
    }
  }

  private rejectDuringPermissionRestart(
    ws: WebSocket,
    session: SessionInfo,
    action: string,
  ): boolean {
    if (!session.permissionRestartInProgress) return false;
    this.send(ws, {
      type: "error",
      message: `Cannot ${action} while the permission restart is in progress.`,
      errorCode: "permission_restart_in_progress",
      sessionId: session.id,
    });
    return true;
  }

  private getDebugEvents(sessionId: string, limit: number): DebugTraceEvent[] {
    const events = this.debugEvents.get(sessionId) ?? [];
    const capped = Math.max(
      0,
      Math.min(limit, BridgeWebSocketServer.MAX_DEBUG_EVENTS),
    );
    if (capped === 0) return [];
    return events.slice(-capped);
  }

  private buildHistorySummary(history: ServerMessage[]): string[] {
    const lines = history.map((msg, index) => {
      const num = String(index + 1).padStart(3, "0");
      return `${num}. ${this.summarizeServerMessage(msg)}`;
    });
    if (lines.length <= BridgeWebSocketServer.MAX_HISTORY_SUMMARY_ITEMS) {
      return lines;
    }
    return lines.slice(-BridgeWebSocketServer.MAX_HISTORY_SUMMARY_ITEMS);
  }

  private summarizeClientMessage(msg: ClientMessage): string {
    switch (msg.type) {
      case "input": {
        const textPreview = msg.text.replace(/\s+/g, " ").trim().slice(0, 80);
        const hasImage = msg.imageBase64 != null || msg.imageId != null;
        return `text=\"${textPreview}\" image=${hasImage} skills=${msg.skills?.length ?? (msg.skill ? 1 : 0)} mentions=${msg.mentions?.length ?? 0}`;
      }
      case "push_register":
        return `platform=${msg.platform} token=${msg.token.slice(0, 8)}...`;
      case "push_unregister":
        return `token=${msg.token.slice(0, 8)}...`;
      case "approve":
      case "approve_always":
      case "reject":
        return `id=${msg.id}`;
      case "answer":
        return `toolUseId=${msg.toolUseId}`;
      case "install_tool_suggestion":
        return `toolUseId=${msg.toolUseId}`;
      case "start":
        return `projectPath=${msg.projectPath} provider=${msg.provider ?? "claude"}`;
      case "resume_session":
        return `sessionId=${msg.sessionId} provider=${msg.provider ?? "claude"}`;
      case "get_debug_bundle":
        return `traceLimit=${msg.traceLimit ?? BridgeWebSocketServer.MAX_DEBUG_EVENTS} includeDiff=${msg.includeDiff ?? true}`;
      case "get_usage":
        return "get_usage";
      default:
        return msg.type;
    }
  }

  private summarizeServerMessage(msg: ServerMessage): string {
    switch (msg.type) {
      case "assistant": {
        const textChunks: string[] = [];
        for (const content of msg.message.content) {
          if (content.type === "text") {
            textChunks.push(content.text);
          }
        }
        const text = textChunks
          .join(" ")
          .replace(/\s+/g, " ")
          .trim()
          .slice(0, 100);
        return text ? `assistant: ${text}` : "assistant";
      }
      case "tool_result": {
        const contentPreview = msg.content
          .replace(/\s+/g, " ")
          .trim()
          .slice(0, 100);
        return `${msg.toolName ?? "tool_result"}(${msg.toolUseId}) ${contentPreview}`;
      }
      case "permission_request":
        return `${msg.toolName}(${msg.toolUseId})`;
      case "result":
        return `${msg.subtype}${msg.error ? ` error=${msg.error}` : ""}`;
      case "status":
        return msg.status;
      case "error":
        return msg.message;
      case "stream_delta":
      case "thinking_delta":
        return `${msg.type}(${msg.text.length})`;
      default:
        return msg.type;
    }
  }

  private summarizeOutboundMessage(
    msg: ServerMessage | Record<string, unknown>,
  ): string {
    if ("type" in msg && typeof msg.type === "string") {
      return msg.type;
    }
    return "message";
  }

  private pruneDebugEvents(): void {
    const active = new Set(this.sessionManager.list().map((s) => s.id));
    for (const sessionId of this.debugEvents.keys()) {
      if (!active.has(sessionId)) {
        this.debugEvents.delete(sessionId);
      }
    }
    for (const sessionId of this.notifiedPermissionToolUses.keys()) {
      if (!active.has(sessionId)) {
        this.notifiedPermissionToolUses.delete(sessionId);
      }
    }
    for (const sessionId of this.progressNotificationState.keys()) {
      if (!active.has(sessionId)) {
        this.progressNotificationState.delete(sessionId);
      }
    }
  }

  private buildReproRecipe(
    session: SessionInfo,
    traceLimit: number,
    includeDiff: boolean,
  ): Record<string, unknown> {
    const bridgePort = process.env.BRIDGE_PORT ?? "8765";
    const wsUrlHint = `ws://localhost:${bridgePort}`;
    const notes = [
      "1) Connect with wsUrlHint and send resumeSessionMessage.",
      "2) Read session_created.sessionId from server response.",
      "3) Replace <runtime_session_id> in getHistoryMessage/getDebugBundleMessage and send them.",
      "4) Compare history/debugTrace/diff with the saved bundle snapshot.",
    ];
    if (!session.claudeSessionId) {
      notes.push(
        "claudeSessionId is not available yet. Use list_recent_sessions to pick the right session id.",
      );
    }

    return {
      wsUrlHint,
      startBridgeCommand: `BRIDGE_PORT=${bridgePort} npm run bridge`,
      resumeSessionMessage: this.buildResumeSessionMessage(session),
      getHistoryMessage: {
        type: "get_history",
        sessionId: "<runtime_session_id>",
      },
      getDebugBundleMessage: {
        type: "get_debug_bundle",
        sessionId: "<runtime_session_id>",
        traceLimit,
        includeDiff,
      },
      notes,
    };
  }

  private buildResumeSessionMessage(
    session: SessionInfo,
  ): Record<string, unknown> {
    const msg: Record<string, unknown> = {
      type: "resume_session",
      sessionId: session.claudeSessionId ?? "<session_id_from_recent_sessions>",
      projectPath: session.projectPath,
      provider: session.provider,
    };

    if (session.provider === "codex" && session.codexSettings) {
      if (session.codexSettings.approvalPolicy !== undefined) {
        msg.approvalPolicy = session.codexSettings.approvalPolicy;
      }
      if (session.codexSettings.approvalsReviewer !== undefined) {
        msg.approvalsReviewer = session.codexSettings.approvalsReviewer;
      }
      if (session.codexSettings.sandboxMode !== undefined) {
        msg.sandboxMode = session.codexSettings.sandboxMode;
      }
      if (session.codexSettings.model !== undefined) {
        msg.model = session.codexSettings.model;
      }
      if (session.codexSettings.modelReasoningEffort !== undefined) {
        msg.modelReasoningEffort = session.codexSettings.modelReasoningEffort;
      }
      if (session.codexSettings.serviceTier !== undefined) {
        msg.serviceTier = session.codexSettings.serviceTier;
      }
      if (session.codexSettings.networkAccessEnabled !== undefined) {
        msg.networkAccessEnabled = session.codexSettings.networkAccessEnabled;
      }
      if (session.codexSettings.webSearchMode !== undefined) {
        msg.webSearchMode = session.codexSettings.webSearchMode;
      }
      if (session.codexSettings.additionalWritableRoots !== undefined) {
        msg.additionalWritableRoots =
          session.codexSettings.additionalWritableRoots;
      }
    }

    return msg;
  }

  private buildAgentPrompt(session: SessionInfo): string {
    return [
      "Use this ccpocket debug bundle to investigate a chat-screen bug.",
      `Target provider: ${session.provider}`,
      `Project path: ${session.projectPath}`,
      "Required output:",
      "1) Timeline analysis from historySummary + debugTrace.",
      "2) Top 1-3 root-cause hypotheses with confidence.",
      "3) Concrete validation steps and the minimum extra logs needed.",
    ].join("\n");
  }
}
