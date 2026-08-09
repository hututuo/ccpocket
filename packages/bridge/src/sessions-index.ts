import {
  readdir,
  readFile,
  writeFile,
  appendFile,
  stat,
  open,
  type FileHandle,
} from "node:fs/promises";
import { createReadStream, type Dirent } from "node:fs";
import { createInterface } from "node:readline";
import { basename, extname, join } from "node:path";
import { homedir } from "node:os";
import { createHash } from "node:crypto";
import { renameSession as renameClaudeSdkSession } from "@anthropic-ai/claude-agent-sdk";
import { isAutoRenamePromptText } from "./auto-rename.js";
import { resolveCodexHome, resolveCodexSessionsDir } from "./codex-home.js";
import { normalizeCodexServiceTierForClient } from "./codex-service-tier.js";
import {
  readCodexDesktopProjectCatalog,
  type CodexDesktopProjectCatalog,
  type CodexDesktopProjectGroupKind,
} from "./codex-desktop-project-catalog.js";
import {
  CodexDesktopToolTimelineBuilder,
  codexDesktopToolImagePaths,
  codexDesktopToolOutputText,
  describeCodexDesktopToolCall,
  formatCodexFileChanges,
  normalizeCodexDesktopToolOutput,
  type CodexDesktopItemTimestamp,
  type CodexDesktopToolTimeline,
  type CodexDesktopToolTimelineEvent,
} from "./local-features/codex-tool-history.js";

export interface SessionIndexEntry {
  sessionId: string;
  provider: "claude" | "codex";
  /** Durable Codex parent thread for a forked conversation. */
  forkedFromThreadId?: string;
  /** User-assigned session name (customTitle for Claude, thread_name for Codex). */
  name?: string;
  agentNickname?: string;
  agentRole?: string;
  summary?: string;
  firstPrompt: string;
  lastPrompt?: string;
  created: string;
  modified: string;
  gitBranch: string;
  projectPath: string;
  /** Raw cwd used to resume this session (worktree path for codex, if any). */
  resumeCwd?: string;
  /** Desktop-owned presentation grouping. Never replaces projectPath/resumeCwd. */
  projectGroupKind?: CodexDesktopProjectGroupKind;
  projectGroupId?: string;
  projectGroupName?: string;
  projectGroupPath?: string;
  projectGroupingSnapshotComplete?: boolean;
  /** Permission mode from the first user message (Claude sessions only). */
  permissionMode?: string;
  isSidechain: boolean;
  codexSettings?: {
    profile?: string;
    approvalPolicy?: string;
    approvalsReviewer?: string;
    sandboxMode?: string;
    model?: string;
    modelReasoningEffort?: string;
    serviceTier?: string;
    collaborationMode?: "plan" | "default";
    networkAccessEnabled?: boolean;
    webSearchMode?: string;
    additionalWritableRoots?: string[];
  };
}

interface RawSessionIndexFile {
  version: number;
  entries: RawSessionEntry[];
}

interface RawSessionEntry {
  sessionId: string;
  fullPath: string;
  fileMtime: number;
  firstPrompt: string;
  summary?: string;
  customTitle?: string;
  messageCount: number;
  created: string;
  modified: string;
  gitBranch: string;
  projectPath: string;
  isSidechain: boolean;
}

export interface GetRecentSessionsOptions {
  limit?: number; // default 20
  offset?: number; // default 0
  projectPath?: string; // filter by project
  /** Exact provider session ID lookup (used by deep-link resolution). */
  sessionId?: string;
  /** Session IDs to exclude (archived sessions). */
  archivedSessionIds?: ReadonlySet<string>;
  /** Provider-scoped identities (`provider\0sessionId`) to exclude safely. */
  archivedSessionKeys?: ReadonlySet<string>;
  /** Filter by provider (claude or codex). */
  provider?: "claude" | "codex";
  /** Show only sessions with a non-empty name. */
  namedOnly?: boolean;
  /** Free-text search across name, firstPrompt, lastPrompt and summary. */
  searchQuery?: string;
  /**
   * Internal lightweight catalog projection. Indexed Claude entries keep their
   * durable identity and modified timestamp without optional JSONL enrichment.
   */
  metadataOnly?: boolean;
  /**
   * Optional bounded progress signal for interactive callers. A callback is
   * emitted only when another catalog source (Claude project index/JSONL
   * directory or the Codex catalog) has actually completed.
   */
  onProgress?: (progress: {
    completedUnits: number;
    totalUnits?: number;
  }) => void;
}

export interface GetRecentSessionsResult {
  sessions: SessionIndexEntry[];
  hasMore: boolean;
}

function attachDesktopProjectGrouping(
  entries: SessionIndexEntry[],
  desktopProjects: CodexDesktopProjectCatalog,
): SessionIndexEntry[] {
  if (!desktopProjects.available) return entries;
  return entries.map((entry) => ({
    ...entry,
    ...(desktopProjects.groupingFor(
      // Desktop assignments and projectless IDs belong only to Codex
      // threads. Claude rows participate through their filesystem path.
      entry.provider === "codex" ? entry.sessionId : "",
      entry.resumeCwd ?? entry.projectPath,
    ) ?? {}),
  }));
}

interface JsonlScanStats {
  filesTotal: number;
  filesExcluded: number;
  filesRead: number;
  entriesReturned: number;
}

interface RecentSessionsPerfStats {
  claudeProjectDirs: number;
  claudeIndexDirs: number;
  claudeJsonlOnlyDirs: number;
  claudeIndexEntries: number;
  claudeJsonlFilesTotal: number;
  claudeJsonlFilesExcluded: number;
  claudeJsonlFilesRead: number;
  claudeJsonlEntries: number;
  codexFilesTotal: number;
  codexFilesRead: number;
  codexEntries: number;
  claudeNamedOnlyFastPathUsed: boolean;
  counts: {
    beforeArchive: number;
    afterArchive: number;
    afterProvider: number;
    afterNamedOnly: number;
    afterSearch: number;
    returned: number;
  };
}

function createRecentSessionsPerfStats(): RecentSessionsPerfStats {
  return {
    claudeProjectDirs: 0,
    claudeIndexDirs: 0,
    claudeJsonlOnlyDirs: 0,
    claudeIndexEntries: 0,
    claudeJsonlFilesTotal: 0,
    claudeJsonlFilesExcluded: 0,
    claudeJsonlFilesRead: 0,
    claudeJsonlEntries: 0,
    codexFilesTotal: 0,
    codexFilesRead: 0,
    codexEntries: 0,
    claudeNamedOnlyFastPathUsed: false,
    counts: {
      beforeArchive: 0,
      afterArchive: 0,
      afterProvider: 0,
      afterNamedOnly: 0,
      afterSearch: 0,
      returned: 0,
    },
  };
}

function markDuration(
  durations: Record<string, number>,
  key: string,
  startedAt: bigint,
): void {
  const elapsedMs = Number(process.hrtime.bigint() - startedAt) / 1_000_000;
  durations[key] = elapsedMs;
}

function shouldLogRecentSessionsPerf(): boolean {
  const v = process.env.BRIDGE_RECENT_SESSIONS_PROFILE;
  return v === "1" || v === "true";
}

function logRecentSessionsPerf(
  options: GetRecentSessionsOptions,
  durations: Record<string, number>,
  stats: RecentSessionsPerfStats,
): void {
  if (!shouldLogRecentSessionsPerf()) return;

  const projectPath = options.projectPath;
  const projectPathLabel = projectPath
    ? projectPath.length > 72
      ? `${projectPath.slice(0, 69)}...`
      : projectPath
    : "";

  const payload = {
    options: {
      limit: options.limit ?? 20,
      offset: options.offset ?? 0,
      projectPath: projectPathLabel || undefined,
      provider: options.provider ?? "all",
      namedOnly: options.namedOnly ?? false,
      metadataOnly: options.metadataOnly ?? false,
      searchQuery: options.searchQuery ? "<set>" : "<none>",
      archivedSessionIds: options.archivedSessionIds?.size ?? 0,
      archivedSessionKeys: options.archivedSessionKeys?.size ?? 0,
    },
    durationsMs: Object.fromEntries(
      Object.entries(durations).map(([k, v]) => [k, Number(v.toFixed(1))]),
    ),
    stats,
  };

  console.info(`[recent-sessions][perf] ${JSON.stringify(payload)}`);
}

interface ScanJsonlDirOptions {
  excludeSessionIds?: ReadonlySet<string>;
  stats?: JsonlScanStats;
}

/** Convert a filesystem path to Claude's project directory slug (e.g. /foo/bar → -foo-bar). */
export function pathToSlug(p: string): string {
  return p.replace(/[^a-zA-Z0-9]/g, "-");
}

/**
 * Normalize a worktree cwd back to the main project path.
 * e.g. /path/to/project-worktrees/branch → /path/to/project
 */
export function normalizeWorktreePath(p: string): string {
  const match = p.match(/^(.+)-worktrees[\\/][^\\/]+$/);
  return match?.[1] ?? p;
}

/**
 * Check if a directory slug represents a worktree directory for a given project slug.
 * e.g. "-Users-x-proj-worktrees-branch" is a worktree dir for "-Users-x-proj".
 */
export function isWorktreeSlug(dirSlug: string, projectSlug: string): boolean {
  return dirSlug.startsWith(projectSlug + "-worktrees-");
}

/** Concurrency limit for parallel file reads to avoid fd exhaustion. */
const PARALLEL_FILE_READ_LIMIT = 32;

/** Head/Tail byte sizes for partial JSONL reads. */
const HEAD_BYTES = 16384; // 16KB — covers first user entry + metadata
const TAIL_BYTES = 8192; // 8KB — covers last entries for modified/lastPrompt
const CODEX_HEAD_BYTES = 131072; // 128KB — Codex turn_context can be large
const CODEX_TAIL_BYTES = 16384;
const CODEX_SETTINGS_SCAN_BYTES = 65536;
const CODEX_TURN_CONTEXT_MARKER = Buffer.from('"type":"turn_context"');
const CODEX_THREAD_SETTINGS_MARKER = Buffer.from(
  '"type":"thread_settings_applied"',
);
const CODEX_SETTINGS_MARKER_OVERLAP =
  Math.max(
    CODEX_TURN_CONTEXT_MARKER.length,
    CODEX_THREAD_SETTINGS_MARKER.length,
  ) - 1;

/**
 * Run async tasks with a concurrency limit.
 * Returns results in the same order as the input tasks.
 */
async function parallelMap<T, R>(
  items: T[],
  concurrency: number,
  fn: (item: T) => Promise<R>,
): Promise<R[]> {
  const results: R[] = new Array(items.length);
  let nextIndex = 0;

  async function worker(): Promise<void> {
    while (nextIndex < items.length) {
      const i = nextIndex++;
      results[i] = await fn(items[i]);
    }
  }

  const workers = Array.from(
    { length: Math.min(concurrency, items.length) },
    () => worker(),
  );
  await Promise.all(workers);
  return results;
}

// Regexes for fast field extraction without JSON.parse
const RE_TYPE_USER = /"type"\s*:\s*"user"/;
const RE_TYPE_ASSISTANT = /"type"\s*:\s*"assistant"/;
const RE_TIMESTAMP = /"timestamp"\s*:\s*"([^"]+)"/;
const RE_GIT_BRANCH = /"gitBranch"\s*:\s*"([^"]+)"/;
const RE_CWD = /"cwd"\s*:\s*"([^"]+)"/;
const RE_IS_SIDECHAIN = /"isSidechain"\s*:\s*true/;
const RE_PERMISSION_MODE = /"permissionMode"\s*:\s*"([^"]+)"/;
const RE_TYPE_CUSTOM_TITLE = /"type"\s*:\s*"custom-title"/;
const RE_CUSTOM_TITLE = /"customTitle"\s*:\s*"([^"]*)"/;
const RE_CODEX_PARTIAL_TIMESTAMP = /"timestamp"\s*:\s*"([^"]+)"/;
const RE_CODEX_PARTIAL_USER_MESSAGE =
  /"type"\s*:\s*"event_msg"[\s\S]*"payload"\s*:\s*\{[\s\S]*"type"\s*:\s*"user_message"[\s\S]*"message"\s*:\s*"((?:\\.|[^"\\])*)/;
const RE_CODEX_PARTIAL_AGENT_MESSAGE =
  /"type"\s*:\s*"event_msg"[\s\S]*"payload"\s*:\s*\{[\s\S]*"type"\s*:\s*"agent_message"[\s\S]*"message"\s*:\s*"((?:\\.|[^"\\])*)/;
const RE_CODEX_PARTIAL_OUTPUT_TEXT =
  /"type"\s*:\s*"response_item"[\s\S]*"role"\s*:\s*"assistant"[\s\S]*"type"\s*:\s*"output_text"[\s\S]*"text"\s*:\s*"((?:\\.|[^"\\])*)/;

/**
 * Detect system-injected messages that should be skipped when determining
 * the user's first/last prompt text (e.g. local-command-caveat, stderr/stdout
 * captures, team notifications, skill loading).
 */
const RE_SYSTEM_INJECTED =
  /^<(?:local-command-caveat|local-command-std(?:err|out)|task-notification|teammate-message|bash-(?:input|stdout))>/;

function isSystemInjectedText(text: string): boolean {
  return (
    RE_SYSTEM_INJECTED.test(text) ||
    text.startsWith("Base directory for this skill:")
  );
}

function isCodexAutoRenameSession(firstPrompt: string): boolean {
  return isAutoRenamePromptText(firstPrompt);
}

function decodeJsonStringPrefix(fragment: string): string {
  let candidate = fragment;
  while (candidate.length > 0) {
    try {
      return JSON.parse(`"${candidate}"`) as string;
    } catch {
      candidate = candidate.slice(0, -1);
    }
  }
  return "";
}

function parsePartialCodexLine(line: string): {
  timestamp?: string;
  userMessage?: string;
  assistantText?: string;
} {
  const timestamp = line.match(RE_CODEX_PARTIAL_TIMESTAMP)?.[1];
  const userMessage = line.match(RE_CODEX_PARTIAL_USER_MESSAGE)?.[1];
  if (userMessage !== undefined) {
    return {
      timestamp,
      userMessage: decodeJsonStringPrefix(userMessage),
    };
  }
  const agentMessage = line.match(RE_CODEX_PARTIAL_AGENT_MESSAGE)?.[1];
  if (agentMessage !== undefined) {
    return {
      timestamp,
      assistantText: decodeJsonStringPrefix(agentMessage),
    };
  }
  const outputText = line.match(RE_CODEX_PARTIAL_OUTPUT_TEXT)?.[1];
  if (outputText !== undefined) {
    return {
      timestamp,
      assistantText: decodeJsonStringPrefix(outputText),
    };
  }
  return timestamp ? { timestamp } : {};
}

/** Extract user prompt text from a parsed JSONL entry. */
function extractUserPromptText(entry: Record<string, unknown>): string {
  const message = entry.message as { content?: unknown } | undefined;
  if (!message?.content) return "";
  if (typeof message.content === "string") return message.content;
  if (Array.isArray(message.content)) {
    const textBlock = (
      message.content as Array<{ type: string; text?: string }>
    ).find((c) => c.type === "text" && c.text);
    return textBlock?.text ?? "";
  }
  return "";
}

/**
 * Parse head and optional tail text chunks to build a SessionIndexEntry.
 * Uses regex for most fields, JSON.parse only for first/last user lines.
 */
interface ParsedClaudeChunks {
  entry: SessionIndexEntry | null;
  headFoundFirstPrompt: boolean;
  headFoundProjectPath: boolean;
  headFoundGitBranch: boolean;
}

function parseFromChunks(
  sessionId: string,
  head: string,
  tail: string | null,
): ParsedClaudeChunks {
  let firstPrompt = "";
  let lastPrompt = "";
  let created = "";
  let modified = "";
  let gitBranch = "";
  let rawCwd = "";
  let projectPath = "";
  let customTitle = "";
  let permissionMode = "";
  let isSidechain = false;
  let hasAnyMessage = false;
  let headFoundFirstPrompt = false;
  let headFoundProjectPath = false;
  let headFoundGitBranch = false;
  let isInternalAutoRename = false;

  // --- Scan head lines ---
  const headLines = head.split("\n");
  for (const line of headLines) {
    if (!line.trim()) continue;

    // Extract custom-title entries. Claude treats these as last-wins metadata.
    if (RE_TYPE_CUSTOM_TITLE.test(line)) {
      const ctMatch = line.match(RE_CUSTOM_TITLE);
      if (ctMatch) customTitle = ctMatch[1];
      continue;
    }

    const isUser = RE_TYPE_USER.test(line);
    const isAssistant = !isUser && RE_TYPE_ASSISTANT.test(line);
    if (!isUser && !isAssistant) continue;
    hasAnyMessage = true;

    const tsMatch = line.match(RE_TIMESTAMP);
    if (tsMatch) {
      if (!created) created = tsMatch[1];
      modified = tsMatch[1];
    }

    if (!gitBranch) {
      const gbMatch = line.match(RE_GIT_BRANCH);
      if (gbMatch) {
        gitBranch = gbMatch[1];
        headFoundGitBranch = true;
      }
    }

    if (!projectPath) {
      const cwdMatch = line.match(RE_CWD);
      if (cwdMatch) {
        rawCwd = cwdMatch[1];
        projectPath = normalizeWorktreePath(rawCwd);
        headFoundProjectPath = true;
      }
    }

    if (!isSidechain && RE_IS_SIDECHAIN.test(line)) {
      isSidechain = true;
    }

    if (isUser && !permissionMode) {
      const pmMatch = line.match(RE_PERMISSION_MODE);
      if (pmMatch) permissionMode = pmMatch[1];
    }

    if (isUser && !firstPrompt) {
      // JSON.parse only user lines to extract prompt text, skipping
      // system-injected messages (e.g. <local-command-caveat>)
      try {
        const entry = JSON.parse(line) as Record<string, unknown>;
        const text = extractUserPromptText(entry);
        if (text && !isSystemInjectedText(text)) {
          if (isAutoRenamePromptText(text)) {
            isInternalAutoRename = true;
            break;
          }
          firstPrompt = text;
          headFoundFirstPrompt = true;
        }
      } catch {
        /* skip */
      }
    }
  }

  if (isInternalAutoRename) {
    return {
      entry: null,
      headFoundFirstPrompt,
      headFoundProjectPath,
      headFoundGitBranch,
    };
  }

  // --- Scan tail lines (if separate from head) ---
  if (tail) {
    const tailLines = tail.split("\n");

    // Find last timestamp and last user prompt from tail (scan in reverse)
    let lastUserLine: string | null = null;
    let tailCustomTitle = "";
    for (let i = tailLines.length - 1; i >= 0; i--) {
      const line = tailLines[i];
      if (!line.trim()) continue;

      if (RE_TYPE_CUSTOM_TITLE.test(line)) {
        const ctMatch = line.match(RE_CUSTOM_TITLE);
        if (ctMatch && !tailCustomTitle) {
          tailCustomTitle = ctMatch[1];
          customTitle = tailCustomTitle;
        }
        continue;
      }

      const isUser = RE_TYPE_USER.test(line);
      const isAssistant = !isUser && RE_TYPE_ASSISTANT.test(line);
      if (!isUser && !isAssistant) continue;
      hasAnyMessage = true;

      // Get the last modified timestamp
      if (!modified || true) {
        // Always update modified from tail (tail is later in file)
        const tsMatch = line.match(RE_TIMESTAMP);
        if (tsMatch) {
          modified = tsMatch[1];
          // We found the last message — we're done with timestamps
          if (isUser && !lastUserLine) lastUserLine = line;
          break;
        }
      }
    }

    // Also find last user line if not found in reverse timestamp scan
    if (!lastUserLine) {
      for (let i = tailLines.length - 1; i >= 0; i--) {
        const line = tailLines[i];
        if (!line.trim()) continue;
        if (RE_TYPE_USER.test(line)) {
          lastUserLine = line;
          break;
        }
      }
    }

    // JSON.parse only the last user line for lastPrompt
    if (lastUserLine) {
      try {
        const entry = JSON.parse(lastUserLine) as Record<string, unknown>;
        const text = extractUserPromptText(entry);
        if (text && !isSystemInjectedText(text)) lastPrompt = text;
      } catch {
        /* skip */
      }
    }

    // Fill in metadata from tail if head didn't have it
    if (!gitBranch || !projectPath) {
      for (const line of tailLines) {
        if (!line.trim()) continue;
        if (!RE_TYPE_USER.test(line) && !RE_TYPE_ASSISTANT.test(line)) continue;
        if (!gitBranch) {
          const gbMatch = line.match(RE_GIT_BRANCH);
          if (gbMatch) gitBranch = gbMatch[1];
        }
        if (!projectPath) {
          const cwdMatch = line.match(RE_CWD);
          if (cwdMatch) {
            rawCwd = cwdMatch[1];
            projectPath = normalizeWorktreePath(rawCwd);
          }
        }
        if (gitBranch && projectPath) break;
      }
    }
  }

  if (!hasAnyMessage) {
    return {
      entry: null,
      headFoundFirstPrompt,
      headFoundProjectPath,
      headFoundGitBranch,
    };
  }

  if (isAutoRenamePromptText(firstPrompt)) {
    return {
      entry: null,
      headFoundFirstPrompt,
      headFoundProjectPath,
      headFoundGitBranch,
    };
  }

  return {
    entry: {
      sessionId,
      provider: "claude",
      firstPrompt,
      ...(lastPrompt && lastPrompt !== firstPrompt ? { lastPrompt } : {}),
      ...(customTitle ? { name: customTitle } : {}),
      created,
      modified,
      gitBranch,
      projectPath,
      ...(rawCwd && rawCwd !== projectPath ? { resumeCwd: rawCwd } : {}),
      ...(permissionMode ? { permissionMode } : {}),
      isSidechain,
    },
    headFoundFirstPrompt,
    headFoundProjectPath,
    headFoundGitBranch,
  };
}

/**
 * Fast parse a Claude JSONL file using partial (head+tail) reads.
 * Only reads the first 16KB and last 8KB of the file, avoiding full I/O.
 * JSON.parse is called at most twice (first + last user lines).
 */
async function parseClaudeJsonlFileFast(
  sessionId: string,
  filePath: string,
): Promise<SessionIndexEntry | null> {
  let fh;
  try {
    fh = await open(filePath, "r");
  } catch {
    return null;
  }

  let parsedChunks: ParsedClaudeChunks;
  try {
    const fileStat = await fh.stat();
    const fileSize = fileStat.size;
    if (fileSize === 0) return null;

    // Small files: read entirely (no benefit from partial reads)
    if (fileSize <= HEAD_BYTES + TAIL_BYTES) {
      const buf = Buffer.alloc(fileSize);
      await fh.read(buf, 0, fileSize, 0);
      return parseFromChunks(sessionId, buf.toString("utf-8"), null).entry;
    }

    // Head read
    const headBuf = Buffer.alloc(HEAD_BYTES);
    await fh.read(headBuf, 0, HEAD_BYTES, 0);
    const headStr = headBuf.toString("utf-8");

    // Tail read — discard the first partial line
    const tailBuf = Buffer.alloc(TAIL_BYTES);
    await fh.read(tailBuf, 0, TAIL_BYTES, fileSize - TAIL_BYTES);
    const tailRaw = tailBuf.toString("utf-8");
    const firstNewline = tailRaw.indexOf("\n");
    const cleanTail = firstNewline >= 0 ? tailRaw.slice(firstNewline + 1) : "";

    parsedChunks = parseFromChunks(sessionId, headStr, cleanTail);
  } finally {
    await fh.close();
  }

  const result = parsedChunks.entry;

  // If the first large JSONL line pushed early metadata outside HEAD_BYTES,
  // the tail supplement may incorrectly pick a later cwd/gitBranch. Stream
  // from the start whenever head parsing missed these fields so resume uses
  // the original session cwd rather than a later in-session directory.
  if (
    result &&
    (!result.firstPrompt ||
      !parsedChunks.headFoundProjectPath ||
      !parsedChunks.headFoundGitBranch)
  ) {
    const missing = await extractMissingFieldsStreaming(
      filePath,
      !result.firstPrompt,
      !parsedChunks.headFoundProjectPath,
      !parsedChunks.headFoundGitBranch,
    );
    if (!result.firstPrompt && missing.firstPrompt) {
      result.firstPrompt = missing.firstPrompt;
    }
    if (isAutoRenamePromptText(result.firstPrompt)) {
      return null;
    }
    if (missing.projectPath) {
      result.projectPath = missing.projectPath;
      if (missing.rawCwd && missing.rawCwd !== missing.projectPath) {
        result.resumeCwd = missing.rawCwd;
      } else {
        delete result.resumeCwd;
      }
    }
    if (missing.gitBranch) {
      result.gitBranch = missing.gitBranch;
    }
  }

  return result;
}

async function hydrateClaudeIndexedEntry(
  dirPath: string,
  entry: RawSessionEntry,
  options: { metadataOnly?: boolean } = {},
): Promise<SessionIndexEntry | null> {
  if (isAutoRenamePromptText(entry.firstPrompt ?? "")) return null;

  const rawProjectPath = entry.projectPath ?? "";
  const normalizedPath = normalizeWorktreePath(rawProjectPath);
  const base: SessionIndexEntry = {
    sessionId: entry.sessionId,
    provider: "claude",
    ...(entry.customTitle ? { name: entry.customTitle } : {}),
    ...(entry.summary ? { summary: entry.summary } : {}),
    firstPrompt: entry.firstPrompt ?? "",
    created: entry.created ?? "",
    modified: entry.modified ?? "",
    gitBranch: entry.gitBranch ?? "",
    projectPath: normalizedPath,
    ...(rawProjectPath && rawProjectPath !== normalizedPath
      ? { resumeCwd: rawProjectPath }
      : {}),
    isSidechain: entry.isSidechain ?? false,
  };

  // The conversation-content scheduler only needs durable identity and the
  // modified timestamp to decide what to enqueue. Avoid parsing every indexed
  // JSONL merely to enrich display fields that this internal caller discards.
  // If the timestamp is missing, retain the repair path so change detection
  // never becomes permanently blind for a malformed/old index entry.
  if (options.metadataOnly && base.modified) return base;

  const needsJsonlRepair =
    !base.firstPrompt ||
    !base.projectPath ||
    !base.gitBranch ||
    !base.created ||
    !base.modified ||
    !base.permissionMode;

  if (!needsJsonlRepair) return base;

  const fallbackPath =
    entry.fullPath || join(dirPath, `${entry.sessionId}.jsonl`);
  const parsed = await parseClaudeJsonlFileFast(entry.sessionId, fallbackPath);
  if (!parsed) return base;
  if (isAutoRenamePromptText(parsed.firstPrompt)) return null;

  return {
    ...base,
    firstPrompt: base.firstPrompt || parsed.firstPrompt,
    ...(parsed.name
      ? { name: parsed.name }
      : base.name
        ? { name: base.name }
        : {}),
    created: base.created || parsed.created,
    modified: base.modified || parsed.modified,
    gitBranch: base.gitBranch || parsed.gitBranch,
    projectPath: base.projectPath || parsed.projectPath,
    isSidechain: base.isSidechain || parsed.isSidechain,
    ...(base.lastPrompt || !parsed.lastPrompt
      ? {}
      : { lastPrompt: parsed.lastPrompt }),
    ...(base.permissionMode || !parsed.permissionMode
      ? {}
      : { permissionMode: parsed.permissionMode }),
  };
}

/**
 * Fallback: stream a JSONL file line-by-line to find missing fields.
 * Called when the fast head-read could not extract firstPrompt/projectPath
 * (e.g. the first user message line is very large due to embedded images
 * and got truncated within HEAD_BYTES).
 * Reads only until all needed fields are found, then stops.
 */
async function extractMissingFieldsStreaming(
  filePath: string,
  needFirstPrompt: boolean,
  needProjectPath: boolean,
  needGitBranch: boolean,
): Promise<{
  firstPrompt: string;
  projectPath: string;
  rawCwd: string;
  gitBranch: string;
}> {
  return new Promise((resolve) => {
    const stream = createReadStream(filePath, { encoding: "utf-8" });
    const rl = createInterface({ input: stream, crlfDelay: Infinity });
    let firstPrompt = "";
    let rawCwd = "";
    let projectPath = "";
    let gitBranch = "";
    let done = false;

    function checkDone(): void {
      const promptDone = !needFirstPrompt || firstPrompt !== "";
      const pathDone = !needProjectPath || projectPath !== "";
      const branchDone = !needGitBranch || gitBranch !== "";
      if (promptDone && pathDone && branchDone) {
        done = true;
        rl.close();
        stream.destroy();
        resolve({ firstPrompt, projectPath, rawCwd, gitBranch });
      }
    }

    rl.on("line", (line) => {
      if (done) return;
      const isUser = RE_TYPE_USER.test(line);
      const isAssistant = !isUser && RE_TYPE_ASSISTANT.test(line);
      if (!isUser && !isAssistant) return;

      // Extract projectPath/gitBranch from cwd field (available on any user/assistant line)
      if (needProjectPath && !projectPath) {
        const cwdMatch = line.match(RE_CWD);
        if (cwdMatch) {
          rawCwd = cwdMatch[1];
          projectPath = normalizeWorktreePath(rawCwd);
        }
      }
      if (needGitBranch && !gitBranch) {
        const gbMatch = line.match(RE_GIT_BRANCH);
        if (gbMatch) gitBranch = gbMatch[1];
      }

      // Extract firstPrompt from user lines
      if (needFirstPrompt && isUser && !firstPrompt) {
        try {
          const entry = JSON.parse(line) as Record<string, unknown>;
          const text = extractUserPromptText(entry);
          if (text && !isSystemInjectedText(text)) {
            firstPrompt = text;
          }
        } catch {
          // Line might be malformed — skip
        }
      }

      checkDone();
    });

    rl.on("close", () => {
      if (!done) resolve({ firstPrompt, projectPath, rawCwd, gitBranch });
    });

    stream.on("error", () => {
      if (!done) resolve({ firstPrompt, projectPath, rawCwd, gitBranch });
    });
  });
}

/**
 * Maximum bytes to read from file tail when searching for lastPrompt.
 * Claude sessions often have large tool-result lines (diffs, etc.) near the
 * end, so 8KB is rarely enough.  We grow the read window in steps up to this
 * cap to balance speed and coverage.
 */
const LAST_PROMPT_MAX_TAIL = 131072; // 128KB

/**
 * Fast tail-read to extract the last user prompt from a JSONL file.
 * Starts at TAIL_BYTES and doubles up to LAST_PROMPT_MAX_TAIL until a real
 * user text prompt is found.  No full-file scan is ever performed.
 * Used to supplement sessions-index.json entries that lack lastPrompt.
 */
async function extractLastPromptFromTail(filePath: string): Promise<string> {
  let fh;
  try {
    fh = await open(filePath, "r");
  } catch {
    return "";
  }
  try {
    const fileSize = (await fh.stat()).size;
    if (fileSize === 0) return "";

    // Grow tail window: 8KB → 16KB → 32KB → 64KB → 128KB
    for (
      let tailSize = TAIL_BYTES;
      tailSize <= LAST_PROMPT_MAX_TAIL;
      tailSize *= 2
    ) {
      const readSize = Math.min(fileSize, tailSize);
      const readOffset = fileSize - readSize;
      const buf = Buffer.alloc(readSize);
      await fh.read(buf, 0, readSize, readOffset);
      let raw = buf.toString("utf-8");

      // Discard the first partial line if reading from middle of file
      if (readOffset > 0) {
        const nl = raw.indexOf("\n");
        if (nl >= 0) raw = raw.slice(nl + 1);
      }

      // Scan in reverse to find the last user line with real text
      const lines = raw.split("\n");
      for (let i = lines.length - 1; i >= 0; i--) {
        const line = lines[i];
        if (!line.trim()) continue;
        if (!RE_TYPE_USER.test(line)) continue;
        try {
          const entry = JSON.parse(line) as Record<string, unknown>;
          const text = extractUserPromptText(entry);
          if (text && !isSystemInjectedText(text)) return text;
        } catch {
          // Truncated line — skip
        }
      }

      // If we already read the entire file, stop
      if (readSize >= fileSize) break;
    }
    return "";
  } finally {
    await fh.close();
  }
}

/**
 * Scan a directory for JSONL session files and create SessionIndexEntry objects.
 * Used as a fallback when sessions-index.json is missing (common for worktree sessions).
 * File reads are parallelized and use head+tail partial reads for performance.
 */
export async function scanJsonlDir(
  dirPath: string,
  options: ScanJsonlDirOptions = {},
): Promise<SessionIndexEntry[]> {
  const scanStats = options.stats;

  let files: string[];
  try {
    files = await readdir(dirPath);
  } catch {
    return [];
  }

  // Filter to JSONL files and apply exclusions
  const targets: Array<{ sessionId: string; filePath: string }> = [];
  for (const file of files) {
    if (!file.endsWith(".jsonl")) continue;
    scanStats && (scanStats.filesTotal += 1);

    const sessionId = basename(file, ".jsonl");
    if (options.excludeSessionIds?.has(sessionId)) {
      scanStats && (scanStats.filesExcluded += 1);
      continue;
    }
    targets.push({ sessionId, filePath: join(dirPath, file) });
  }

  // Read and parse files in parallel using fast head+tail reads
  const results = await parallelMap(
    targets,
    PARALLEL_FILE_READ_LIMIT,
    async ({ sessionId, filePath }) => {
      const entry = await parseClaudeJsonlFileFast(sessionId, filePath);
      if (entry) {
        scanStats && (scanStats.filesRead += 1);
        scanStats && (scanStats.entriesReturned += 1);
      } else {
        scanStats && (scanStats.filesRead += 1);
      }
      return entry;
    },
  );

  return results.filter((e): e is SessionIndexEntry => e !== null);
}

export async function getAllRecentSessions(
  options: GetRecentSessionsOptions = {},
): Promise<GetRecentSessionsResult> {
  const totalStartedAt = process.hrtime.bigint();
  const durations: Record<string, number> = {};
  const perfStats = createRecentSessionsPerfStats();

  const limit = options.limit ?? 20;
  const offset = options.offset ?? 0;
  const filterProjectPath = options.projectPath;
  const shouldLoadClaude = options.provider !== "codex";
  const shouldLoadCodex = options.provider !== "claude";
  const includeOnlyNamedClaude = options.namedOnly === true;
  let completedProgressUnits = 0;
  let totalProgressUnits = shouldLoadCodex ? 1 : 0;
  const reportProgress = (): void => {
    completedProgressUnits += 1;
    options.onProgress?.({
      completedUnits: completedProgressUnits,
      ...(totalProgressUnits > 0 ? { totalUnits: totalProgressUnits } : {}),
    });
  };

  const projectsDir = join(homedir(), ".claude", "projects");
  const entries: SessionIndexEntry[] = [];

  let projectDirs: string[];
  const loadProjectDirsStartedAt = process.hrtime.bigint();
  try {
    projectDirs = await readdir(projectsDir);
  } catch {
    // ~/.claude/projects doesn't exist
    projectDirs = [];
  }
  markDuration(durations, "loadClaudeProjectDirs", loadProjectDirsStartedAt);

  // Compute worktree slug prefix for projectPath filtering
  const projectSlug = filterProjectPath ? pathToSlug(filterProjectPath) : null;

  // --- Load Claude and Codex sessions in parallel ---

  const desktopProjectsPromise = readCodexDesktopProjectCatalog();

  const loadClaudeStartedAt = process.hrtime.bigint();
  const claudeEntriesPromise = (async (): Promise<SessionIndexEntry[]> => {
    if (!shouldLoadClaude) return [];

    // Filter directories first (sync), then process in parallel
    const relevantDirs: string[] = [];
    for (const dirName of projectDirs) {
      if (dirName.startsWith(".")) continue;
      const isProjectDir = projectSlug ? dirName === projectSlug : false;
      const isWorktreeDir = projectSlug
        ? isWorktreeSlug(dirName, projectSlug)
        : false;
      if (filterProjectPath && !isProjectDir && !isWorktreeDir) continue;
      relevantDirs.push(dirName);
    }
    perfStats.claudeProjectDirs = relevantDirs.length;
    totalProgressUnits += relevantDirs.length;

    // Process directories in parallel
    const dirResults = await parallelMap(
      relevantDirs,
      PARALLEL_FILE_READ_LIMIT,
      async (dirName) => {
        const dirPath = join(projectsDir, dirName);
        const indexPath = join(dirPath, "sessions-index.json");
        let raw: string | null = null;
        try {
          raw = await readFile(indexPath, "utf-8");
        } catch {
          // No sessions-index.json — will try JSONL scan for worktree dirs
        }

        const result: {
          entries: SessionIndexEntry[];
          indexDirs: number;
          indexEntries: number;
          jsonlOnlyDirs: number;
          jsonlStats: JsonlScanStats;
        } = {
          entries: [],
          indexDirs: 0,
          indexEntries: 0,
          jsonlOnlyDirs: 0,
          jsonlStats: {
            filesTotal: 0,
            filesExcluded: 0,
            filesRead: 0,
            entriesReturned: 0,
          },
        };
        const finish = (): typeof result => {
          reportProgress();
          return result;
        };

        if (raw !== null) {
          result.indexDirs = 1;

          let index: RawSessionIndexFile;
          try {
            index = JSON.parse(raw) as RawSessionIndexFile;
          } catch {
            console.error(`[sessions-index] Failed to parse ${indexPath}`);
            return finish();
          }

          if (!Array.isArray(index.entries)) return finish();

          const indexedIds = new Set<string>();
          for (const entry of index.entries) {
            const name = entry.customTitle || undefined;
            if (includeOnlyNamedClaude && (!name || name === "")) {
              continue;
            }

            indexedIds.add(entry.sessionId);
            const hydrated = await hydrateClaudeIndexedEntry(dirPath, entry, {
              metadataOnly: options.metadataOnly,
            });
            if (hydrated) {
              result.entries.push(hydrated);
              result.indexEntries += 1;
            }
          }

          if (!includeOnlyNamedClaude) {
            const scanned = await scanJsonlDir(dirPath, {
              excludeSessionIds: indexedIds,
              stats: result.jsonlStats,
            });
            result.entries.push(...scanned);
          } else {
            perfStats.claudeNamedOnlyFastPathUsed = true;
          }
        } else {
          if (includeOnlyNamedClaude) {
            perfStats.claudeNamedOnlyFastPathUsed = true;
            return finish();
          }

          result.jsonlOnlyDirs = 1;
          const scanned = await scanJsonlDir(dirPath, {
            stats: result.jsonlStats,
          });
          result.entries.push(...scanned);
        }

        return finish();
      },
    );

    // Aggregate stats and entries
    const allEntries: SessionIndexEntry[] = [];
    for (const r of dirResults) {
      allEntries.push(...r.entries);
      perfStats.claudeIndexDirs += r.indexDirs;
      perfStats.claudeIndexEntries += r.indexEntries;
      perfStats.claudeJsonlOnlyDirs += r.jsonlOnlyDirs;
      perfStats.claudeJsonlFilesTotal += r.jsonlStats.filesTotal;
      perfStats.claudeJsonlFilesExcluded += r.jsonlStats.filesExcluded;
      perfStats.claudeJsonlFilesRead += r.jsonlStats.filesRead;
      perfStats.claudeJsonlEntries += r.jsonlStats.entriesReturned;
    }
    return allEntries;
  })();

  const loadCodexStartedAt = process.hrtime.bigint();
  const codexEntriesPromise = (async (): Promise<SessionIndexEntry[]> => {
    if (!shouldLoadCodex) return [];
    const codexPerf: CodexRecentPerfStats = {
      filesTotal: 0,
      filesRead: 0,
      entriesReturned: 0,
    };
    const codexEntries = await getAllRecentCodexSessions({
      projectPath: filterProjectPath,
      perfStats: codexPerf,
    });
    perfStats.codexFilesTotal = codexPerf.filesTotal;
    perfStats.codexFilesRead = codexPerf.filesRead;
    perfStats.codexEntries = codexPerf.entriesReturned;
    reportProgress();
    return codexEntries;
  })();

  // Wait for both Claude and Codex loading to complete in parallel
  const [rawClaudeEntries, rawCodexEntries, desktopProjects] =
    await Promise.all([
      claudeEntriesPromise,
      codexEntriesPromise,
      desktopProjectsPromise,
    ]);
  const claudeEntries = attachDesktopProjectGrouping(
    rawClaudeEntries,
    desktopProjects,
  );
  const codexEntries = attachDesktopProjectGrouping(
    rawCodexEntries,
    desktopProjects,
  );
  markDuration(durations, "loadClaudeSessions", loadClaudeStartedAt);
  markDuration(durations, "loadCodexSessions", loadCodexStartedAt);

  // Combine results and deduplicate by provider-scoped session identity.
  // The same session can appear in both the main project dir and a worktree dir
  // (Claude CLI writes to both sessions-index.json files). Claude and Codex can
  // legitimately emit the same raw id, so collapsing across providers would
  // silently hide one of the conversations. Keep the entry with richer data
  // only within the same provider identity.
  const combined = [...claudeEntries, ...codexEntries];
  const seen = new Map<string, SessionIndexEntry>();
  for (const entry of combined) {
    const identityKey = `${entry.provider}\u0000${entry.sessionId}`;
    const existing = seen.get(identityKey);
    if (!existing) {
      seen.set(identityKey, entry);
    } else {
      // Pick the entry with more populated fields
      const score = (e: SessionIndexEntry): number =>
        (e.firstPrompt ? 1 : 0) +
        (e.gitBranch ? 1 : 0) +
        (e.created ? 1 : 0) +
        (e.modified ? 1 : 0) +
        (e.name ? 1 : 0) +
        (e.summary ? 1 : 0) +
        (e.lastPrompt ? 1 : 0);
      if (score(entry) > score(existing)) {
        seen.set(identityKey, entry);
      }
    }
  }
  entries.push(...seen.values());

  // Filter out archived sessions
  const archivedIds = options.archivedSessionIds;
  const archivedKeys = options.archivedSessionKeys;
  let filtered =
    archivedIds || archivedKeys
      ? entries.filter(
          (entry) =>
            !archivedIds?.has(entry.sessionId) &&
            !archivedKeys?.has(`${entry.provider}\u0000${entry.sessionId}`),
        )
      : [...entries];
  perfStats.counts.beforeArchive = entries.length;
  perfStats.counts.afterArchive = filtered.length;

  // Filter by provider
  if (options.provider) {
    filtered = filtered.filter((e) => e.provider === options.provider);
  }
  perfStats.counts.afterProvider = filtered.length;

  // Exact provider session lookup. Apply before pagination so old sessions
  // remain resolvable even when they are outside the first recent page.
  if (options.sessionId) {
    filtered = filtered.filter((e) => e.sessionId === options.sessionId);
  }

  // Filter named only
  if (options.namedOnly) {
    filtered = filtered.filter((e) => e.name != null && e.name !== "");
  }
  perfStats.counts.afterNamedOnly = filtered.length;

  // Filter by search query (name, firstPrompt, lastPrompt, summary)
  if (options.searchQuery) {
    const q = options.searchQuery.toLowerCase();
    filtered = filtered.filter(
      (e) =>
        e.name?.toLowerCase().includes(q) ||
        e.firstPrompt?.toLowerCase().includes(q) ||
        e.lastPrompt?.toLowerCase().includes(q) ||
        e.summary?.toLowerCase().includes(q) ||
        e.projectGroupName?.toLowerCase().includes(q),
    );
  }
  perfStats.counts.afterSearch = filtered.length;

  // Sort by modified descending
  const sortStartedAt = process.hrtime.bigint();
  filtered.sort((a, b) => {
    const ta = new Date(a.modified).getTime();
    const tb = new Date(b.modified).getTime();
    return tb - ta;
  });
  markDuration(durations, "sortSessions", sortStartedAt);

  const paginateStartedAt = process.hrtime.bigint();
  const sliced = filtered.slice(offset, offset + limit);
  const hasMore = offset + limit < filtered.length;
  perfStats.counts.returned = sliced.length;
  markDuration(durations, "paginate", paginateStartedAt);

  // Supplement missing lastPrompt for Claude sessions (sessions-index.json
  // doesn't include lastPrompt).  Only the paginated page is processed so at
  // most `limit` tail reads are needed — lightweight enough to keep inline.
  const supplementStartedAt = process.hrtime.bigint();
  const needLastPrompt = sliced.filter(
    (e) => e.provider === "claude" && !e.lastPrompt && e.projectPath,
  );
  if (!options.metadataOnly && needLastPrompt.length > 0) {
    const projectsDir = join(homedir(), ".claude", "projects");
    await parallelMap(
      needLastPrompt,
      PARALLEL_FILE_READ_LIMIT,
      async (entry) => {
        const slug = pathToSlug(entry.projectPath);
        const jsonlPath = join(projectsDir, slug, `${entry.sessionId}.jsonl`);
        const lp = await extractLastPromptFromTail(jsonlPath);
        if (lp && lp !== entry.firstPrompt) {
          entry.lastPrompt = lp;
        }
      },
    );
  }
  markDuration(durations, "supplementLastPrompt", supplementStartedAt);

  markDuration(durations, "total", totalStartedAt);
  logRecentSessionsPerf(options, durations, perfStats);

  return { sessions: sliced, hasMore };
}

interface CodexRecentOptions {
  projectPath?: string;
  perfStats?: CodexRecentPerfStats;
}

interface CodexRecentPerfStats {
  filesTotal: number;
  filesRead: number;
  entriesReturned: number;
}

export interface CodexSessionIndexMetadata {
  forkedFromThreadId?: string;
  codexSettings?: SessionIndexEntry["codexSettings"];
  /** Canonical project path derived from the persisted rollout cwd. */
  projectPath?: string;
  resumeCwd?: string;
  /** First user prompt parsed from the rollout file. The thread/list API
   *  only exposes a preview blob, so these three text fields let recent-
   *  session entries carry the real first/last/summary texts. */
  firstPrompt?: string;
  /** Last user prompt; omitted when identical to firstPrompt. */
  lastPrompt?: string;
  /** Last assistant message text — the closest thing to a session summary. */
  summary?: string;
}

interface CodexSessionParseResult {
  entry: SessionIndexEntry;
  threadId: string;
}

async function listCodexSessionFiles(): Promise<string[]> {
  const root = resolveCodexSessionsDir();
  const files: string[] = [];
  const stack = [root];

  while (stack.length > 0) {
    const dir = stack.pop()!;
    let children: Dirent[];
    try {
      children = await readdir(dir, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const child of children) {
      const p = join(dir, child.name);
      if (child.isDirectory()) {
        stack.push(p);
      } else if (child.isFile() && p.endsWith(".jsonl")) {
        files.push(p);
      }
    }
  }

  return files;
}

function parseCodexSessionJsonl(
  raw: string,
  fallbackSessionId: string,
  includeInternal = false,
): CodexSessionParseResult | null {
  const lines = raw.split("\n");
  let threadId = fallbackSessionId;
  let forkedFromThreadId: string | undefined;
  let projectPath = "";
  let resumeCwd = "";
  let gitBranch = "";
  let created = "";
  let modified = "";
  let firstPrompt = "";
  let lastPrompt = "";
  let summary = "";
  let hasMessages = false;
  let lastAssistantText = "";
  let agentNickname: string | undefined;
  let agentRole: string | undefined;
  // Settings extracted from the first turn_context entry
  let approvalPolicy: string | undefined;
  let approvalsReviewer: string | undefined;
  let sandboxMode: string | undefined;
  let model: string | undefined;
  let modelReasoningEffort: string | undefined;
  let serviceTier: string | undefined;
  let collaborationMode: "plan" | "default" | undefined;
  let networkAccessEnabled: boolean | undefined;
  let webSearchMode: string | undefined;

  for (const line of lines) {
    if (!line.trim()) continue;
    let entry: Record<string, unknown>;
    try {
      entry = JSON.parse(line) as Record<string, unknown>;
    } catch {
      const partial = parsePartialCodexLine(line);
      if (partial.timestamp) {
        if (!created) created = partial.timestamp;
        modified = partial.timestamp;
      }
      if (partial.userMessage !== undefined) {
        hasMessages = true;
        if (!firstPrompt) firstPrompt = partial.userMessage;
        lastPrompt = partial.userMessage;
      }
      if (partial.assistantText) {
        hasMessages = true;
        lastAssistantText = partial.assistantText;
      }
      continue;
    }

    const timestamp = entry.timestamp as string | undefined;
    if (timestamp) {
      if (!created) created = timestamp;
      modified = timestamp;
    }

    if (entry.type === "session_meta") {
      const payload = entry.payload as Record<string, unknown> | undefined;
      if (payload) {
        if (!includeInternal && isCodexInternalSessionSource(payload.source)) {
          return null;
        }
        // Persisted forks can replay inherited session_meta records. When a
        // caller supplied the authoritative child id, ignore metadata owned
        // by an ancestor instead of returning the parent under the child path.
        if (
          includeInternal &&
          typeof payload.id === "string" &&
          payload.id.length > 0 &&
          payload.id !== fallbackSessionId
        ) {
          continue;
        }
        if (typeof payload.id === "string" && payload.id.length > 0) {
          threadId = payload.id;
        }
        if (
          forkedFromThreadId === undefined &&
          typeof payload.forked_from_id === "string" &&
          payload.forked_from_id.length > 0
        ) {
          forkedFromThreadId = payload.forked_from_id;
        }
        if (typeof payload.cwd === "string" && payload.cwd.length > 0) {
          resumeCwd = payload.cwd;
          projectPath = normalizeWorktreePath(payload.cwd);
        }
        const git = payload.git as Record<string, unknown> | undefined;
        if (git && typeof git.branch === "string") {
          gitBranch = git.branch;
        }
        if (
          typeof payload.agent_nickname === "string" &&
          payload.agent_nickname.length > 0
        ) {
          agentNickname = payload.agent_nickname;
        }
        if (
          typeof payload.agent_role === "string" &&
          payload.agent_role.length > 0
        ) {
          agentRole = payload.agent_role;
        }
      }
      continue;
    }

    // Extract codex settings from turn_context.
    // Always update (no guard) so the **last** turn_context wins — this is
    // important when sandbox mode or other settings change mid-session.
    if (entry.type === "turn_context") {
      const payload = entry.payload as Record<string, unknown> | undefined;
      if (payload) {
        if (typeof payload.approval_policy === "string") {
          approvalPolicy = payload.approval_policy;
        }
        if (typeof payload.approvals_reviewer === "string") {
          approvalsReviewer = payload.approvals_reviewer;
        }
        const sp = payload.sandbox_policy as
          Record<string, unknown> | undefined;
        if (sp && typeof sp.type === "string") {
          sandboxMode = sp.type;
        }
        if (typeof payload.model === "string") {
          model = payload.model;
        }
        const collaboration = payload.collaboration_mode as
          Record<string, unknown> | undefined;
        const collaborationSettings = collaboration?.settings as
          Record<string, unknown> | undefined;
        const collaborationModeValue = collaboration?.mode;
        if (
          collaborationModeValue === "plan" ||
          collaborationModeValue === "default"
        ) {
          collaborationMode = collaborationModeValue;
        }
        if (typeof collaborationSettings?.reasoning_effort === "string") {
          modelReasoningEffort = collaborationSettings.reasoning_effort;
        }
        // Codex omits service_tier from standard-speed turn_context records.
        // Treat every new context as authoritative so Fast -> Standard clears
        // a previous persisted "fast" value.
        serviceTier =
          typeof payload.service_tier === "string" &&
          payload.service_tier.trim().length > 0 &&
          payload.service_tier !== "default"
            ? normalizeCodexServiceTierForClient(payload.service_tier)
            : "standard";
        if (typeof sp?.network_access === "boolean") {
          networkAccessEnabled = sp.network_access;
        }
        if (typeof payload.web_search === "string") {
          webSearchMode = payload.web_search;
        }
      }
      continue;
    }

    if (entry.type === "event_msg") {
      const payload = entry.payload as Record<string, unknown> | undefined;
      if (payload?.type === "thread_settings_applied") {
        const settings = payload.thread_settings as
          Record<string, unknown> | undefined;
        if (settings) {
          if (typeof settings.approval_policy === "string") {
            approvalPolicy = settings.approval_policy;
          }
          if (typeof settings.approvals_reviewer === "string") {
            approvalsReviewer = settings.approvals_reviewer;
          }
          if (typeof settings.model === "string") {
            model = settings.model;
          }
          const collaboration = settings.collaboration_mode as
            Record<string, unknown> | undefined;
          const collaborationSettings = collaboration?.settings as
            Record<string, unknown> | undefined;
          const collaborationModeValue = collaboration?.mode;
          if (
            collaborationModeValue === "plan" ||
            collaborationModeValue === "default"
          ) {
            collaborationMode = collaborationModeValue;
          }
          const reasoningEffort =
            typeof settings.reasoning_effort === "string"
              ? settings.reasoning_effort
              : collaborationSettings?.reasoning_effort;
          if (typeof reasoningEffort === "string") {
            modelReasoningEffort = reasoningEffort;
          }
          if ("service_tier" in settings) {
            serviceTier = normalizeCodexServiceTierForClient(
              settings.service_tier,
            );
          }
        }
      } else if (
        payload?.type === "user_message" &&
        typeof payload.message === "string"
      ) {
        hasMessages = true;
        if (!firstPrompt) firstPrompt = payload.message;
        lastPrompt = payload.message;
      } else if (
        payload?.type === "agent_message" &&
        typeof payload.message === "string" &&
        payload.message.trim().length > 0
      ) {
        hasMessages = true;
        lastAssistantText = payload.message;
      }
      continue;
    }

    if (entry.type === "response_item") {
      const payload = entry.payload as Record<string, unknown> | undefined;
      if (
        !payload ||
        payload.type !== "message" ||
        payload.role !== "assistant"
      ) {
        continue;
      }
      const content = payload.content;
      if (!Array.isArray(content)) continue;
      const text = (content as Array<Record<string, unknown>>)
        .filter(
          (item) =>
            item.type === "output_text" && typeof item.text === "string",
        )
        .map((item) => item.text as string)
        .join("\n")
        .trim();
      if (text.length > 0) {
        hasMessages = true;
        lastAssistantText = text;
      }
    }
  }

  if (model === "codex-auto-review") return null;
  if (isCodexAutoRenameSession(firstPrompt)) return null;
  if (!projectPath || !hasMessages) return null;
  summary = lastAssistantText || summary;

  const codexSettings =
    approvalPolicy ||
    approvalsReviewer ||
    sandboxMode ||
    model ||
    modelReasoningEffort ||
    serviceTier ||
    collaborationMode ||
    networkAccessEnabled !== undefined ||
    webSearchMode
      ? {
          approvalPolicy,
          approvalsReviewer,
          sandboxMode,
          model,
          modelReasoningEffort,
          serviceTier,
          collaborationMode,
          networkAccessEnabled,
          webSearchMode,
        }
      : undefined;

  return {
    threadId,
    entry: {
      sessionId: threadId,
      provider: "codex",
      ...(forkedFromThreadId ? { forkedFromThreadId } : {}),
      ...(agentNickname ? { agentNickname } : {}),
      ...(agentRole ? { agentRole } : {}),
      summary: summary || undefined,
      firstPrompt,
      ...(lastPrompt && lastPrompt !== firstPrompt ? { lastPrompt } : {}),
      created,
      modified,
      gitBranch,
      projectPath,
      ...(resumeCwd && resumeCwd !== projectPath ? { resumeCwd } : {}),
      isSidechain: false,
      codexSettings,
    },
  };
}

/**
 * Fast parse a Codex JSONL file for recent-session list metadata.
 * The first chunk contains session_meta / first prompt; the tail chunk contains
 * the latest prompt, latest assistant summary, and modified timestamp.
 */
async function parseCodexSessionJsonlFast(
  filePath: string,
  fallbackSessionId: string,
  includeInternal = false,
): Promise<CodexSessionParseResult | null> {
  let fh;
  try {
    fh = await open(filePath, "r");
  } catch {
    return null;
  }

  try {
    const fileStat = await fh.stat();
    const fileSize = fileStat.size;
    if (fileSize === 0) return null;

    if (fileSize <= CODEX_HEAD_BYTES + CODEX_TAIL_BYTES) {
      const buf = Buffer.alloc(fileSize);
      await fh.read(buf, 0, fileSize, 0);
      return parseCodexSessionJsonl(
        buf.toString("utf-8"),
        fallbackSessionId,
        includeInternal,
      );
    }

    const headBuf = Buffer.alloc(CODEX_HEAD_BYTES);
    await fh.read(headBuf, 0, CODEX_HEAD_BYTES, 0);

    const tailBuf = Buffer.alloc(CODEX_TAIL_BYTES);
    await fh.read(tailBuf, 0, CODEX_TAIL_BYTES, fileSize - CODEX_TAIL_BYTES);
    const tailRaw = tailBuf.toString("utf-8");
    const firstNewline = tailRaw.indexOf("\n");
    const cleanTail = firstNewline >= 0 ? tailRaw.slice(firstNewline + 1) : "";

    const partialRaw = `${headBuf.toString("utf-8")}\n${cleanTail}`;
    return parseCodexSessionJsonl(
      partialRaw,
      fallbackSessionId,
      includeInternal,
    );
  } finally {
    await fh.close();
  }
}

type CodexSettings = NonNullable<SessionIndexEntry["codexSettings"]>;
type CodexSettingsRecordKind = "turn_context" | "thread_settings_applied";

function normalizeCodexCollaborationMode(
  value: unknown,
): "plan" | "default" | undefined {
  return value === "plan" || value === "default" ? value : undefined;
}

interface CodexSettingsMarker {
  kind: CodexSettingsRecordKind;
  offset: number;
}

interface CodexJsonlLine {
  start: number;
  text: string;
}

interface CodexSettingsRecord {
  kind: CodexSettingsRecordKind;
  settings: CodexSettings;
}

async function readFileRange(
  fh: FileHandle,
  position: number,
  length: number,
): Promise<Buffer> {
  if (length <= 0) return Buffer.alloc(0);
  const buffer = Buffer.allocUnsafe(length);
  let totalBytesRead = 0;
  while (totalBytesRead < length) {
    const { bytesRead } = await fh.read(
      buffer,
      totalBytesRead,
      length - totalBytesRead,
      position + totalBytesRead,
    );
    if (bytesRead === 0) break;
    totalBytesRead += bytesRead;
  }
  return totalBytesRead === length
    ? buffer
    : buffer.subarray(0, totalBytesRead);
}

async function findPreviousCodexSettingsMarker(
  fh: FileHandle,
  fileSize: number,
  upperBound: number,
): Promise<CodexSettingsMarker | null> {
  let cursor = Math.min(fileSize, upperBound);
  while (cursor > 0) {
    const start = Math.max(0, cursor - CODEX_SETTINGS_SCAN_BYTES);
    const end = Math.min(fileSize, cursor + CODEX_SETTINGS_MARKER_OVERLAP);
    const buffer = await readFileRange(fh, start, end - start);
    const lastAllowedIndex = cursor - start - 1;
    const turnContextIndex = buffer.lastIndexOf(
      CODEX_TURN_CONTEXT_MARKER,
      lastAllowedIndex,
    );
    const threadSettingsIndex = buffer.lastIndexOf(
      CODEX_THREAD_SETTINGS_MARKER,
      lastAllowedIndex,
    );
    if (turnContextIndex >= 0 || threadSettingsIndex >= 0) {
      if (turnContextIndex > threadSettingsIndex) {
        return {
          kind: "turn_context",
          offset: start + turnContextIndex,
        };
      }
      return {
        kind: "thread_settings_applied",
        offset: start + threadSettingsIndex,
      };
    }
    cursor = start;
  }
  return null;
}

async function readCodexJsonlLineAtOffset(
  fh: FileHandle,
  fileSize: number,
  offset: number,
): Promise<CodexJsonlLine | null> {
  let lineStart = Math.min(fileSize, offset);
  let cursor = lineStart;
  while (cursor > 0) {
    const start = Math.max(0, cursor - CODEX_SETTINGS_SCAN_BYTES);
    const buffer = await readFileRange(fh, start, cursor - start);
    const newline = buffer.lastIndexOf(0x0a);
    if (newline >= 0) {
      lineStart = start + newline + 1;
      break;
    }
    cursor = start;
    lineStart = start;
  }

  let lineEnd = Math.min(fileSize, offset);
  cursor = lineEnd;
  while (cursor < fileSize) {
    const length = Math.min(CODEX_SETTINGS_SCAN_BYTES, fileSize - cursor);
    const buffer = await readFileRange(fh, cursor, length);
    const newline = buffer.indexOf(0x0a);
    if (newline >= 0) {
      lineEnd = cursor + newline;
      break;
    }
    if (buffer.length === 0) break;
    cursor += buffer.length;
    lineEnd = cursor;
    if (buffer.length < length) break;
  }

  const lineBuffer = await readFileRange(fh, lineStart, lineEnd - lineStart);
  if (lineBuffer.length === 0) return null;
  return { start: lineStart, text: lineBuffer.toString("utf-8") };
}

function codexSandboxFromActivePermissionProfile(
  settings: Record<string, unknown>,
): string | undefined {
  const activeProfile = asObject(settings.active_permission_profile);
  const rawId = activeProfile?.id;
  if (typeof rawId !== "string") return undefined;
  const profileId = rawId.startsWith(":") ? rawId.slice(1) : rawId;
  return profileId === "danger-full-access" ||
    profileId === "workspace-write" ||
    profileId === "read-only"
    ? profileId
    : undefined;
}

function codexSettingsFromTurnContext(
  payload: Record<string, unknown>,
): CodexSettings {
  const sandboxPolicy = asObject(payload.sandbox_policy);
  const collaborationMode = asObject(payload.collaboration_mode);
  const collaborationSettings = asObject(collaborationMode?.settings);
  const collaborationModeValue = normalizeCodexCollaborationMode(
    collaborationMode?.mode,
  );
  return {
    ...(typeof payload.approval_policy === "string"
      ? { approvalPolicy: payload.approval_policy }
      : {}),
    ...(typeof payload.approvals_reviewer === "string"
      ? { approvalsReviewer: payload.approvals_reviewer }
      : {}),
    ...(typeof sandboxPolicy?.type === "string"
      ? { sandboxMode: sandboxPolicy.type }
      : {}),
    ...(typeof payload.model === "string" ? { model: payload.model } : {}),
    ...(typeof collaborationSettings?.reasoning_effort === "string"
      ? { modelReasoningEffort: collaborationSettings.reasoning_effort }
      : {}),
    ...(collaborationModeValue
      ? { collaborationMode: collaborationModeValue }
      : {}),
    serviceTier:
      typeof payload.service_tier === "string" &&
      payload.service_tier.trim().length > 0 &&
      payload.service_tier !== "default"
        ? normalizeCodexServiceTierForClient(payload.service_tier)
        : "standard",
    ...(typeof sandboxPolicy?.network_access === "boolean"
      ? { networkAccessEnabled: sandboxPolicy.network_access }
      : {}),
    ...(typeof payload.web_search === "string"
      ? { webSearchMode: payload.web_search }
      : {}),
  };
}

function codexSettingsFromThreadSettings(
  settings: Record<string, unknown>,
): CodexSettings {
  const collaborationMode = asObject(settings.collaboration_mode);
  const collaborationSettings = asObject(collaborationMode?.settings);
  const collaborationModeValue = normalizeCodexCollaborationMode(
    collaborationMode?.mode,
  );
  const reasoningEffort =
    typeof settings.reasoning_effort === "string"
      ? settings.reasoning_effort
      : collaborationSettings?.reasoning_effort;
  const sandboxMode = codexSandboxFromActivePermissionProfile(settings);
  return {
    ...(typeof settings.approval_policy === "string"
      ? { approvalPolicy: settings.approval_policy }
      : {}),
    ...(typeof settings.approvals_reviewer === "string"
      ? { approvalsReviewer: settings.approvals_reviewer }
      : {}),
    ...(sandboxMode ? { sandboxMode } : {}),
    ...(typeof settings.model === "string" ? { model: settings.model } : {}),
    ...(typeof reasoningEffort === "string"
      ? { modelReasoningEffort: reasoningEffort }
      : {}),
    ...(collaborationModeValue
      ? { collaborationMode: collaborationModeValue }
      : {}),
    ...("service_tier" in settings
      ? {
          serviceTier: normalizeCodexServiceTierForClient(
            settings.service_tier,
          ),
        }
      : {}),
  };
}

function parseCodexSettingsRecord(line: string): CodexSettingsRecord | null {
  let entry: Record<string, unknown>;
  try {
    entry = JSON.parse(line) as Record<string, unknown>;
  } catch {
    return null;
  }

  if (entry.type === "turn_context") {
    const payload = asObject(entry.payload);
    return payload
      ? {
          kind: "turn_context",
          settings: codexSettingsFromTurnContext(payload),
        }
      : null;
  }

  if (entry.type === "event_msg") {
    const payload = asObject(entry.payload);
    if (payload?.type !== "thread_settings_applied") return null;
    const settings = asObject(payload.thread_settings);
    return settings
      ? {
          kind: "thread_settings_applied",
          settings: codexSettingsFromThreadSettings(settings),
        }
      : null;
  }

  return null;
}

function fillMissingCodexSettings(
  target: CodexSettings,
  source: CodexSettings,
): void {
  target.approvalPolicy ??= source.approvalPolicy;
  target.approvalsReviewer ??= source.approvalsReviewer;
  target.sandboxMode ??= source.sandboxMode;
  target.model ??= source.model;
  target.modelReasoningEffort ??= source.modelReasoningEffort;
  target.serviceTier ??= source.serviceTier;
  target.collaborationMode ??= source.collaborationMode;
  target.networkAccessEnabled ??= source.networkAccessEnabled;
  target.webSearchMode ??= source.webSearchMode;
}

/**
 * Read the latest complete Codex settings at a stable file-size boundary.
 *
 * Recent-session presentation intentionally reads only a small head/tail
 * window. A resume is different: missing the latest turn_context can silently
 * combine a persisted sandbox with the runtime's default approval policy.
 * Search backwards without a history-size cutoff and stop at the latest
 * complete turn_context, applying any newer thread_settings_applied overlay.
 */
async function readLatestCodexSettingsFromJsonl(
  filePath: string,
): Promise<CodexSettings | undefined> {
  let fh: FileHandle;
  try {
    fh = await open(filePath, "r");
  } catch {
    return undefined;
  }

  try {
    const fileSize = (await fh.stat()).size;
    let upperBound = fileSize;
    const settings: CodexSettings = {};
    let foundSettings = false;

    while (upperBound > 0) {
      const marker = await findPreviousCodexSettingsMarker(
        fh,
        fileSize,
        upperBound,
      );
      if (!marker) break;
      const line = await readCodexJsonlLineAtOffset(
        fh,
        fileSize,
        marker.offset,
      );
      upperBound = line?.start ?? marker.offset;
      if (!line) continue;

      const record = parseCodexSettingsRecord(line.text);
      if (!record || record.kind !== marker.kind) continue;
      fillMissingCodexSettings(settings, record.settings);
      foundSettings = true;
      if (record.kind === "turn_context") break;
    }

    return foundSettings ? settings : undefined;
  } finally {
    await fh.close();
  }
}

function isCodexInternalSessionSource(source: unknown): boolean {
  const sourceObj = asObject(source);
  return sourceObj?.subagent !== undefined;
}

function extractClaudeCustomTitleFromText(text: string): string | undefined {
  let customTitle = "";
  for (const line of text.split("\n")) {
    if (!RE_TYPE_CUSTOM_TITLE.test(line)) continue;
    const match = line.match(RE_CUSTOM_TITLE);
    if (match) customTitle = match[1];
  }
  return customTitle || undefined;
}

async function getClaudeJsonlCustomTitle(
  filePath: string,
): Promise<string | undefined> {
  let fh;
  try {
    fh = await open(filePath, "r");
  } catch {
    return undefined;
  }

  try {
    const fileStat = await fh.stat();
    const fileSize = fileStat.size;
    if (fileSize === 0) return undefined;
    if (fileSize <= HEAD_BYTES + TAIL_BYTES) {
      const buf = Buffer.alloc(fileSize);
      await fh.read(buf, 0, fileSize, 0);
      return extractClaudeCustomTitleFromText(buf.toString("utf-8"));
    }

    const headBuf = Buffer.alloc(HEAD_BYTES);
    await fh.read(headBuf, 0, HEAD_BYTES, 0);
    const headTitle = extractClaudeCustomTitleFromText(
      headBuf.toString("utf-8"),
    );

    const tailBuf = Buffer.alloc(TAIL_BYTES);
    await fh.read(tailBuf, 0, TAIL_BYTES, fileSize - TAIL_BYTES);
    const tailRaw = tailBuf.toString("utf-8");
    const firstNewline = tailRaw.indexOf("\n");
    const cleanTail = firstNewline >= 0 ? tailRaw.slice(firstNewline + 1) : "";
    return extractClaudeCustomTitleFromText(cleanTail) ?? headTitle;
  } finally {
    await fh.close();
  }
}

/**
 * Look up the saved name (customTitle) for a Claude Code session.
 * Returns the name if found, or undefined.
 */
export async function getClaudeSessionName(
  projectPath: string,
  claudeSessionId: string,
): Promise<string | undefined> {
  const slug = pathToSlug(projectPath);
  const dirPath = join(homedir(), ".claude", "projects", slug);
  const indexPath = join(dirPath, "sessions-index.json");

  let raw: string;
  try {
    raw = await readFile(indexPath, "utf-8");
  } catch {
    return getClaudeJsonlCustomTitle(join(dirPath, `${claudeSessionId}.jsonl`));
  }

  let index: RawSessionIndexFile;
  try {
    index = JSON.parse(raw) as RawSessionIndexFile;
  } catch {
    return getClaudeJsonlCustomTitle(join(dirPath, `${claudeSessionId}.jsonl`));
  }

  if (!Array.isArray(index.entries)) {
    return getClaudeJsonlCustomTitle(join(dirPath, `${claudeSessionId}.jsonl`));
  }

  const entry = index.entries.find((e) => e.sessionId === claudeSessionId);
  return (
    (await getClaudeJsonlCustomTitle(
      entry?.fullPath || join(dirPath, `${claudeSessionId}.jsonl`),
    )) ??
    entry?.customTitle ??
    undefined
  );
}

/**
 * Rename a Claude Code session using the Claude Agent SDK's transcript mutation.
 * The SDK appends a custom-title entry to the session JSONL instead of creating
 * sessions-index.json entries, matching Claude CLI storage semantics.
 */
export async function renameClaudeSession(
  projectPath: string,
  claudeSessionId: string,
  name: string | null,
): Promise<boolean> {
  if (name) {
    try {
      await renameClaudeSdkSession(claudeSessionId, name, { dir: projectPath });
      return true;
    } catch {
      return false;
    }
  }

  // The SDK renameSession API intentionally rejects empty titles. For clear,
  // write the same transcript metadata shape with an empty last-wins title,
  // and never create a private sessions-index entry for a metadata-only
  // mutation.
  let changed = false;
  try {
    const jsonlPath = await findSessionJsonlPath(claudeSessionId);
    if (jsonlPath) {
      await appendFile(
        jsonlPath,
        JSON.stringify({
          type: "custom-title",
          customTitle: "",
          sessionId: claudeSessionId,
        }) + "\n",
      );
      changed = true;
    }
  } catch {
    // Fall through to best-effort index cleanup.
  }

  const slug = pathToSlug(projectPath);
  const indexPath = join(
    homedir(),
    ".claude",
    "projects",
    slug,
    "sessions-index.json",
  );

  let index: RawSessionIndexFile | null = null;
  try {
    const raw = await readFile(indexPath, "utf-8");
    index = JSON.parse(raw) as RawSessionIndexFile;
  } catch {
    return changed;
  }

  if (index && Array.isArray(index.entries)) {
    const entry = index.entries.find((e) => e.sessionId === claudeSessionId);
    if (entry) {
      delete entry.customTitle;
      await writeFile(indexPath, JSON.stringify(index, null, 2), "utf-8");
      return true;
    }
  }

  return changed;
}

/**
 * Read the Codex session_index.jsonl and build a threadId → name map.
 */
export async function loadCodexSessionNames(): Promise<Map<string, string>> {
  const indexPath = join(resolveCodexHome(), "session_index.jsonl");
  const names = new Map<string, string>();

  let raw: string;
  try {
    raw = await readFile(indexPath, "utf-8");
  } catch {
    return names;
  }

  // Append-only: later entries override earlier ones for the same id
  for (const line of raw.split("\n")) {
    if (!line.trim()) continue;
    try {
      const entry = JSON.parse(line) as { id?: string; thread_name?: unknown };
      if (entry.id && typeof entry.thread_name === "string") {
        const normalizedName = entry.thread_name.trim();
        if (normalizedName) {
          names.set(entry.id, normalizedName);
        } else {
          // An append-only empty marker is an authoritative title clear. It
          // must remove an earlier value instead of being ignored.
          names.delete(entry.id);
        }
      }
    } catch {
      // skip malformed
    }
  }

  return names;
}

export async function loadCodexSessionProfiles(): Promise<Map<string, string>> {
  const path = join(resolveCodexHome(), "ccpocket-session-profiles.json");
  let raw: string;
  try {
    raw = await readFile(path, "utf-8");
  } catch {
    return new Map();
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw) as unknown;
  } catch {
    return new Map();
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    return new Map();
  }

  const profiles = new Map<string, string>();
  for (const [threadId, profile] of Object.entries(
    parsed as Record<string, unknown>,
  )) {
    if (typeof profile === "string" && profile.trim().length > 0) {
      profiles.set(threadId, profile.trim());
    }
  }
  return profiles;
}

export async function saveCodexSessionProfile(
  threadId: string,
  profile: string | null,
): Promise<void> {
  const path = join(resolveCodexHome(), "ccpocket-session-profiles.json");
  const existing = await loadCodexSessionProfiles();
  if (profile && profile.trim().length > 0) {
    existing.set(threadId, profile.trim());
  } else {
    existing.delete(threadId);
  }
  const next = Object.fromEntries(existing.entries());
  await writeFile(path, JSON.stringify(next, null, 2), "utf-8");
}

export async function loadCodexSessionAdditionalWritableRoots(): Promise<
  Map<string, string[]>
> {
  const path = join(
    homedir(),
    ".codex",
    "ccpocket-session-additional-writable-roots.json",
  );
  let raw: string;
  try {
    raw = await readFile(path, "utf-8");
  } catch {
    return new Map();
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw) as unknown;
  } catch {
    return new Map();
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    return new Map();
  }

  const rootsByThread = new Map<string, string[]>();
  for (const [threadId, roots] of Object.entries(
    parsed as Record<string, unknown>,
  )) {
    const normalized = sanitizeAdditionalWritableRoots(roots);
    if (normalized.length > 0) {
      rootsByThread.set(threadId, normalized);
    }
  }
  return rootsByThread;
}

export async function saveCodexSessionAdditionalWritableRoots(
  threadId: string,
  roots: string[] | null,
): Promise<void> {
  const path = join(
    homedir(),
    ".codex",
    "ccpocket-session-additional-writable-roots.json",
  );
  const existing = await loadCodexSessionAdditionalWritableRoots();
  const normalized = sanitizeAdditionalWritableRoots(roots);
  if (normalized.length > 0) {
    existing.set(threadId, normalized);
  } else {
    existing.delete(threadId);
  }
  const next = Object.fromEntries(existing.entries());
  await writeFile(path, JSON.stringify(next, null, 2), "utf-8");
}

function sanitizeAdditionalWritableRoots(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  const roots = new Map<string, string>();
  for (const root of value) {
    if (typeof root !== "string") continue;
    const trimmed = root.trim();
    if (!trimmed) continue;
    if (!roots.has(trimmed)) {
      roots.set(trimmed, trimmed);
    }
  }
  return [...roots.values()];
}

/**
 * Rename a Codex session by appending to ~/.codex/session_index.jsonl.
 * Passing `null` or empty name writes an empty thread_name to effectively clear it.
 */
export async function renameCodexSession(
  threadId: string,
  name: string | null,
): Promise<boolean> {
  try {
    const indexPath = join(resolveCodexHome(), "session_index.jsonl");
    const entry = JSON.stringify({
      id: threadId,
      thread_name: name ?? "",
      updated_at: new Date().toISOString(),
    });
    await appendFile(indexPath, entry + "\n");
    return true;
  } catch {
    return false;
  }
}

async function getAllRecentCodexSessions(
  options: CodexRecentOptions = {},
): Promise<SessionIndexEntry[]> {
  const files = await listCodexSessionFiles();
  const entries: SessionIndexEntry[] = [];
  options.perfStats && (options.perfStats.filesTotal = files.length);
  const normalizedProjectPath = options.projectPath
    ? normalizeWorktreePath(options.projectPath)
    : null;

  // Load thread names from session_index.jsonl
  const threadNames = await loadCodexSessionNames();
  const threadProfiles = await loadCodexSessionProfiles();
  const threadAdditionalWritableRoots =
    await loadCodexSessionAdditionalWritableRoots();

  const parsedResults = await parallelMap(
    files,
    PARALLEL_FILE_READ_LIMIT,
    async (filePath) => {
      const fallbackSessionId = basename(filePath, ".jsonl");
      return parseCodexSessionJsonlFast(filePath, fallbackSessionId);
    },
  );

  for (const parsed of parsedResults) {
    options.perfStats && (options.perfStats.filesRead += 1);
    if (!parsed) continue;
    if (
      normalizedProjectPath &&
      parsed.entry.projectPath !== normalizedProjectPath
    ) {
      continue;
    }
    // Attach thread name if available
    const threadName = threadNames.get(parsed.threadId);
    if (threadName) {
      parsed.entry.name = threadName;
    }
    const threadProfile = threadProfiles.get(parsed.threadId);
    if (threadProfile) {
      parsed.entry.codexSettings = {
        ...(parsed.entry.codexSettings ?? {}),
        profile: threadProfile,
      };
    }
    const additionalWritableRoots = threadAdditionalWritableRoots.get(
      parsed.threadId,
    );
    if (additionalWritableRoots) {
      parsed.entry.codexSettings = {
        ...(parsed.entry.codexSettings ?? {}),
        additionalWritableRoots,
      };
    }
    entries.push(parsed.entry);
    options.perfStats && (options.perfStats.entriesReturned += 1);
  }

  return entries;
}

export async function getCodexSessionIndexMetadata(
  threadIds: readonly string[],
  options: { authoritativeCodexSettings?: boolean } = {},
): Promise<Map<string, CodexSessionIndexMetadata>> {
  const wantedThreadIds = new Set(threadIds.filter((id) => id.length > 0));
  const result = new Map<string, CodexSessionIndexMetadata>();
  if (wantedThreadIds.size === 0) return result;

  // Resolve all requested ids through the shared source-scoped path index.
  // The first lookup performs one directory walk; concurrent and later ids
  // then become O(1) map lookups instead of files x threadIds suffix scans.
  const resolvedTargets = await parallelMap(
    [...wantedThreadIds],
    PARALLEL_FILE_READ_LIMIT,
    async (expectedThreadId) => ({
      expectedThreadId,
      filePath: await findCodexSessionJsonlPath(expectedThreadId),
    }),
  );
  const targets = resolvedTargets.filter(
    (target): target is { expectedThreadId: string; filePath: string } =>
      target.filePath != null,
  );

  const parsedResults = await parallelMap(
    targets,
    PARALLEL_FILE_READ_LIMIT,
    async ({ filePath, expectedThreadId }) => {
      const fallbackSessionId = basename(filePath, ".jsonl");
      const [parsed, authoritativeSettings] = await Promise.all([
        parseCodexSessionJsonlFast(filePath, fallbackSessionId),
        options.authoritativeCodexSettings
          ? readLatestCodexSettingsFromJsonl(filePath)
          : Promise.resolve(undefined),
      ]);
      if (parsed && authoritativeSettings) {
        parsed.entry.codexSettings = {
          ...parsed.entry.codexSettings,
          ...authoritativeSettings,
        };
      }
      return { expectedThreadId, filePath, parsed, authoritativeSettings };
    },
  );

  for (const {
    expectedThreadId,
    filePath,
    parsed,
    authoritativeSettings,
  } of parsedResults) {
    // A persisted fork can replay an inherited parent session_meta close to
    // the tail. The bounded presentation parser may therefore identify that
    // parent even though the path index resolved this exact child rollout.
    // Discard the mismatched presentation fields, but do not discard settings
    // read authoritatively from the already-resolved child file.
    const matchingParsed =
      parsed?.threadId === expectedThreadId ? parsed : undefined;
    let persistedOwnerMetadata: CodexRolloutOwnerMetadata | null = null;
    if (!matchingParsed) {
      if (!authoritativeSettings) continue;
      // Filename indexes are fast but a copied or damaged rollout can carry
      // another thread's id. Confirm the first persisted owner before using
      // settings without a matching presentation parse.
      persistedOwnerMetadata = await codexJsonlOwnerMetadata(filePath).catch(
        () => null,
      );
      if (persistedOwnerMetadata?.threadId !== expectedThreadId) continue;
    }
    const pathMetadata = matchingParsed?.entry ?? persistedOwnerMetadata;
    result.set(expectedThreadId, {
      ...(matchingParsed?.entry.forkedFromThreadId
        ? { forkedFromThreadId: matchingParsed.entry.forkedFromThreadId }
        : {}),
      ...(matchingParsed?.entry.codexSettings
        ? { codexSettings: matchingParsed.entry.codexSettings }
        : authoritativeSettings
          ? { codexSettings: authoritativeSettings }
          : {}),
      ...(pathMetadata?.projectPath
        ? { projectPath: pathMetadata.projectPath }
        : {}),
      ...(pathMetadata?.resumeCwd ? { resumeCwd: pathMetadata.resumeCwd } : {}),
      ...(matchingParsed?.entry.firstPrompt
        ? { firstPrompt: matchingParsed.entry.firstPrompt }
        : {}),
      ...(matchingParsed?.entry.lastPrompt
        ? { lastPrompt: matchingParsed.entry.lastPrompt }
        : {}),
      ...(matchingParsed?.entry.summary
        ? { summary: matchingParsed.entry.summary }
        : {}),
    });
  }

  return result;
}

/**
 * Read the same bounded Codex metadata from app-server supplied rollout paths.
 *
 * Callers that already received authoritative paths from `thread/list` should
 * use this helper instead of rescanning the whole sessions tree. The parser is
 * still the existing head+tail parser, so a very large rollout is never loaded
 * in full merely to render a list preview.
 */
export async function getCodexSessionIndexMetadataForFiles(
  files: ReadonlyMap<string, string>,
): Promise<Map<string, CodexSessionIndexMetadata>> {
  const targets = [...files.entries()].filter(
    ([threadId, filePath]) => threadId.length > 0 && filePath.length > 0,
  );
  const result = new Map<string, CodexSessionIndexMetadata>();
  if (targets.length === 0) return result;

  const parsedResults = await parallelMap(
    targets,
    PARALLEL_FILE_READ_LIMIT,
    async ([threadId, filePath]) => ({
      expectedThreadId: threadId,
      parsed: await parseCodexSessionJsonlFast(filePath, threadId, true),
    }),
  );

  for (const { expectedThreadId, parsed } of parsedResults) {
    if (!parsed || parsed.threadId !== expectedThreadId) continue;
    result.set(expectedThreadId, {
      ...(parsed.entry.forkedFromThreadId
        ? { forkedFromThreadId: parsed.entry.forkedFromThreadId }
        : {}),
      ...(parsed.entry.codexSettings
        ? { codexSettings: parsed.entry.codexSettings }
        : {}),
      ...(parsed.entry.projectPath
        ? { projectPath: parsed.entry.projectPath }
        : {}),
      ...(parsed.entry.resumeCwd ? { resumeCwd: parsed.entry.resumeCwd } : {}),
      ...(parsed.entry.firstPrompt
        ? { firstPrompt: parsed.entry.firstPrompt }
        : {}),
      ...(parsed.entry.lastPrompt
        ? { lastPrompt: parsed.entry.lastPrompt }
        : {}),
      ...(parsed.entry.summary ? { summary: parsed.entry.summary } : {}),
    });
  }

  return result;
}

// ---- Session history from JSONL files ----

type SessionHistoryContentItem = {
  type: string;
  text?: string;
  thinking?: string;
  id?: string;
  name?: string;
  input?: Record<string, unknown>;
};

export interface SessionHistoryMessage {
  role: "user" | "assistant" | "tool_result";
  uuid?: string;
  /** Raw provider item id, when it differs from the display-safe UUID. */
  rawItemId?: string;
  /** Provider turn identity used to scope legacy UUIDs across pages. */
  historyTurnId?: string;
  /** Client-supplied identity echoed by the provider, when available. */
  clientMessageId?: string;
  timestamp?: string;
  /** True when timestamp came from the provider's individual event record. */
  timestampIsAuthoritative?: boolean;
  /** Skill loading prompt or other meta message (rendered as a chip). */
  isMeta?: boolean;
  /** Number of images attached to this user message (for display indicator). */
  imageCount?: number;
  toolUseId?: string;
  toolName?: string;
  imagePaths?: string[];
  imageBase64?: Array<{ data: string; mimeType: string }>;
  content: string | SessionHistoryContentItem[];
}

export function codexUserTurnUuid(ordinal: number): string {
  return `codex:user-turn:${ordinal}`;
}

export function isCodexUserTurnUuid(uuid: string | undefined): uuid is string {
  return typeof uuid === "string" && /^codex:user-turn:\d+$/.test(uuid);
}

function numberToIsoTimestamp(value: unknown): string | undefined {
  return typeof value === "number" && Number.isFinite(value)
    ? new Date(value * 1000).toISOString()
    : undefined;
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function arrayValue(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function codexToolResultContent(value: unknown): string {
  if (value == null) return "";
  if (typeof value === "string") return value;
  try {
    return JSON.stringify(value, null, 2);
  } catch {
    return String(value);
  }
}

function codexUserInputTextAndImages(content: unknown): {
  text: string;
  imageCount: number;
  imagePaths: string[];
  imageBase64: Array<{ data: string; mimeType: string }>;
} {
  const textParts: string[] = [];
  let imageCount = 0;
  const imagePaths: string[] = [];
  const imageBase64: Array<{ data: string; mimeType: string }> = [];

  for (const entry of arrayValue(content)) {
    const item = asObject(entry);
    if (!item) continue;
    if (item.type === "text" && typeof item.text === "string") {
      textParts.push(item.text);
    } else if (item.type === "image" || item.type === "localImage") {
      imageCount += 1;
      const path = codexContentImagePath(item);
      if (path) imagePaths.push(path);
      const base64 = codexContentImageBase64(item);
      if (base64) imageBase64.push(base64);
    }
  }

  return {
    text: textParts.join("\n"),
    imageCount,
    imagePaths,
    imageBase64,
  };
}

function codexContentImagePath(
  item: Record<string, unknown>,
): string | undefined {
  return (
    stringValue(item.path) ??
    stringValue(item.localPath) ??
    stringValue(item.local_path)
  );
}

function codexContentImageBase64(
  item: Record<string, unknown>,
): { data: string; mimeType: string } | undefined {
  const imageUrl =
    stringValue(item.imageUrl) ??
    stringValue(item.image_url) ??
    stringValue(item.url);
  const dataUri = extractDataUriImage(imageUrl);
  if (dataUri) return { data: dataUri.base64, mimeType: dataUri.mimeType };

  const source = asObject(item.source);
  const data =
    stringValue(item.base64) ??
    stringValue(item.data) ??
    stringValue(source?.data);
  const mimeType =
    stringValue(item.mimeType) ??
    stringValue(item.mime_type) ??
    stringValue(item.media_type) ??
    stringValue(source?.mimeType) ??
    stringValue(source?.mime_type) ??
    stringValue(source?.media_type);

  return data && mimeType ? { data, mimeType } : undefined;
}

function appendCodexThinkingMessage(
  messages: SessionHistoryMessage[],
  text: string,
  timestamp?: string,
  historyTurnId?: string,
): void {
  const normalized = text.trim();
  if (!normalized) return;
  messages.push({
    role: "assistant",
    content: [{ type: "thinking", thinking: normalized }],
    ...(historyTurnId ? { historyTurnId } : {}),
    ...(timestamp ? { timestamp } : {}),
  });
}

function appendCodexOfficialToolResult(
  messages: SessionHistoryMessage[],
  id: string,
  name: string | undefined,
  content: string,
  timestamp?: string,
  historyTurnId?: string,
): void {
  appendToolResultMessage(messages, id, name, content, {
    ...(timestamp ? { timestamp } : {}),
    ...(historyTurnId ? { historyTurnId } : {}),
  });
}

function applyCodexItemTimestamp(
  messages: SessionHistoryMessage[],
  startIndex: number,
  timing: CodexDesktopItemTimestamp | undefined,
): void {
  if (!timing) return;

  for (let index = startIndex; index < messages.length; index += 1) {
    const message = messages[index];
    const isToolResult = message.role === "tool_result";
    const timestamp = isToolResult
      ? (timing.completedAt ?? timing.startedAt)
      : (timing.startedAt ?? timing.completedAt);
    if (!timestamp) continue;
    message.timestamp = timestamp;
    message.timestampIsAuthoritative = true;
  }
}

export function codexThreadToSessionHistory(
  thread: unknown,
  options: { desktopToolTimeline?: CodexDesktopToolTimeline } = {},
): SessionHistoryMessage[] {
  const messages: SessionHistoryMessage[] = [];
  const sourceThread = options.desktopToolTimeline
    ? supplementCodexThreadWithDesktopTools(thread, options.desktopToolTimeline)
    : thread;
  const turns = arrayValue(asObject(sourceThread)?.turns);
  let userTurnOrdinal = 0;

  for (const rawTurn of turns) {
    const turn = asObject(rawTurn);
    if (!turn) continue;
    const historyTurnId = stringValue(turn.id);
    const turnStartedAt = numberToIsoTimestamp(turn.startedAt);
    const turnCompletedAt = numberToIsoTimestamp(turn.completedAt);

    for (const rawItem of arrayValue(turn.items)) {
      const item = asObject(rawItem);
      if (!item || typeof item.type !== "string") continue;
      const rawItemId = stringValue(item.id);
      const itemId = rawItemId ?? `codex-item-${messages.length}`;
      const itemTimestamp = turnCompletedAt ?? turnStartedAt;
      const embeddedItemTiming: CodexDesktopItemTimestamp = {
        startedAt: stringValue(item.__ccPocketEventStartedAt),
        completedAt: stringValue(item.__ccPocketEventCompletedAt),
      };
      const itemTiming =
        (rawItemId
          ? options.desktopToolTimeline?.itemTimestamps?.get(rawItemId)
          : undefined) ??
        (embeddedItemTiming.startedAt || embeddedItemTiming.completedAt
          ? embeddedItemTiming
          : undefined);
      const historyStartIndex = messages.length;

      switch (item.type) {
        case "userMessage": {
          const { text, imageCount, imagePaths, imageBase64 } =
            codexUserInputTextAndImages(item.content);
          const displayText =
            text.trim().length > 0
              ? text
              : imageCount > 0
                ? `[Image attached${imageCount > 1 ? ` x${imageCount}` : ""}]`
                : "";
          if (displayText.trim().length === 0) break;
          userTurnOrdinal += 1;
          const clientMessageId =
            stringValue(item.clientMessageId) ?? stringValue(item.clientId);
          messages.push({
            role: "user",
            uuid: codexUserTurnUuid(userTurnOrdinal),
            ...(rawItemId ? { rawItemId } : {}),
            ...(clientMessageId ? { clientMessageId } : {}),
            content: [{ type: "text", text: displayText }],
            ...(historyTurnId ? { historyTurnId } : {}),
            ...(imageCount > 0 ? { imageCount } : {}),
            ...(imagePaths.length > 0 ? { imagePaths } : {}),
            ...(imageBase64.length > 0 ? { imageBase64 } : {}),
            ...(turnStartedAt ? { timestamp: turnStartedAt } : {}),
          });
          break;
        }

        case "agentMessage": {
          appendTextMessage(
            messages,
            "assistant",
            stringValue(item.text) ?? "",
            itemTimestamp,
            itemId,
            historyTurnId,
          );
          break;
        }

        case "plan": {
          appendTextMessage(
            messages,
            "assistant",
            stringValue(item.text) ?? "",
            itemTimestamp,
            itemId,
            historyTurnId,
          );
          break;
        }

        case "reasoning": {
          const summary = arrayValue(item.summary).filter(
            (value): value is string => typeof value === "string",
          );
          const content = arrayValue(item.content).filter(
            (value): value is string => typeof value === "string",
          );
          appendCodexThinkingMessage(
            messages,
            [...summary, ...content].join("\n"),
            itemTimestamp,
            historyTurnId,
          );
          break;
        }

        case "commandExecution": {
          const descriptor = describeCodexHistoryCommand(item);
          appendToolUseMessage(
            messages,
            itemId,
            descriptor.name,
            descriptor.input,
            historyTurnId,
          );
          const outputParts: string[] = [];
          if (typeof item.status === "string") {
            outputParts.push(`status: ${item.status}`);
          }
          if (typeof item.exitCode === "number") {
            outputParts.push(`exitCode: ${item.exitCode}`);
          }
          if (typeof item.aggregatedOutput === "string") {
            outputParts.push(item.aggregatedOutput);
          }
          appendCodexOfficialToolResult(
            messages,
            itemId,
            descriptor.name,
            outputParts.join("\n").trim(),
            itemTimestamp,
            historyTurnId,
          );
          break;
        }

        case "fileChange": {
          appendToolUseMessage(
            messages,
            itemId,
            "FileChange",
            {
              changes: Array.isArray(item.changes) ? item.changes : [],
              ...(typeof item.status === "string"
                ? { status: item.status }
                : {}),
            },
            historyTurnId,
          );
          appendCodexOfficialToolResult(
            messages,
            itemId,
            "FileChange",
            formatCodexFileChanges(item.changes),
            itemTimestamp,
            historyTurnId,
          );
          break;
        }

        case "mcpToolCall": {
          const server = stringValue(item.server) ?? "mcp";
          const tool = stringValue(item.tool) ?? "tool";
          appendToolUseMessage(
            messages,
            itemId,
            `mcp:${server}/${tool}`,
            {
              arguments: item.arguments ?? {},
              ...(typeof item.status === "string"
                ? { status: item.status }
                : {}),
            },
            historyTurnId,
          );
          if (item.result != null || item.error != null) {
            const normalized = normalizeCodexMcpResult(
              item.result ?? item.error,
            );
            appendToolResultMessage(
              messages,
              itemId,
              `mcp:${server}/${tool}`,
              normalized.content,
              {
                imageBase64: normalized.imageBase64,
                ...(itemTimestamp ? { timestamp: itemTimestamp } : {}),
                ...(historyTurnId ? { historyTurnId } : {}),
              },
            );
          }
          break;
        }

        case "dynamicToolCall": {
          const tool = stringValue(item.tool) ?? "tool";
          const toolInput = parseObjectLike(item.arguments);
          appendToolUseMessage(
            messages,
            itemId,
            tool,
            {
              // App-server dynamic tools carry their semantic arguments in
              // `arguments`. Promote only a bounded summary allowlist to the
              // stable ToolUse input level so Mobile can render Desktop-like
              // Read/Search summaries without duplicating arbitrary payloads.
              ...dynamicToolSummaryInput(toolInput),
              arguments: item.arguments ?? {},
              ...(typeof item.status === "string"
                ? { status: item.status }
                : {}),
            },
            historyTurnId,
          );
          const contentItems = arrayValue(item.contentItems);
          const normalized = normalizeCodexDesktopToolOutput(contentItems);
          const declaredImagePaths = arrayValue(item.imagePaths).filter(
            (value): value is string =>
              typeof value === "string" && value.trim().length > 0,
          );
          const imagePaths = [
            ...new Set([
              ...declaredImagePaths,
              ...codexDesktopToolImagePaths(tool, toolInput),
            ]),
          ];
          const hasImages =
            imagePaths.length > 0 || normalized.imageBase64.length > 0;
          appendToolResultMessage(
            messages,
            itemId,
            tool,
            normalized.content ||
              (hasImages
                ? tool === "ViewImage"
                  ? "Viewed image"
                  : "Tool returned an image"
                : ""),
            {
              imagePaths,
              imageBase64: imagePaths.length > 0 ? [] : normalized.imageBase64,
              ...(itemTimestamp ? { timestamp: itemTimestamp } : {}),
              ...(historyTurnId ? { historyTurnId } : {}),
            },
          );
          break;
        }

        case "webSearch": {
          const query = stringValue(item.query) ?? "";
          appendToolUseMessage(
            messages,
            itemId,
            "WebSearch",
            {
              query,
              ...(item.action != null ? { action: item.action } : {}),
            },
            historyTurnId,
          );
          appendCodexOfficialToolResult(
            messages,
            itemId,
            "WebSearch",
            query ? `Web search: ${query}` : "Web search completed",
            itemTimestamp,
            historyTurnId,
          );
          break;
        }

        case "collabAgentToolCall": {
          const tool = stringValue(item.tool) ?? "subagent";
          const toolName = codexCollabHistoryToolName(tool);
          const status = stringValue(item.status) ?? "completed";
          const receiverThreadIds = arrayValue(item.receiverThreadIds).map(
            (value) => String(value),
          );
          appendToolUseMessage(
            messages,
            itemId,
            toolName,
            {
              tool,
              status,
              ...(typeof item.prompt === "string"
                ? { prompt: item.prompt }
                : {}),
              ...(typeof item.senderThreadId === "string"
                ? { senderThreadId: item.senderThreadId }
                : {}),
              ...(receiverThreadIds.length > 0 ? { receiverThreadIds } : {}),
              ...(typeof item.model === "string" ? { model: item.model } : {}),
              ...(typeof item.reasoningEffort === "string"
                ? { reasoningEffort: item.reasoningEffort }
                : {}),
              ...(item.agentsStates != null
                ? { agentsStates: item.agentsStates }
                : {}),
            },
            historyTurnId,
          );
          if (status !== "inProgress") {
            appendCodexOfficialToolResult(
              messages,
              itemId,
              toolName,
              [
                `status: ${status}`,
                ...(receiverThreadIds.length > 0
                  ? [`agents: ${receiverThreadIds.join(", ")}`]
                  : []),
              ].join("\n"),
              itemTimestamp,
              historyTurnId,
            );
          }
          break;
        }

        case "subAgentActivity": {
          const kind = stringValue(item.kind) ?? "activity";
          const toolName = codexSubAgentActivityHistoryToolName(kind);
          const agentPath = stringValue(item.agentPath);
          appendToolUseMessage(
            messages,
            itemId,
            toolName,
            {
              kind,
              ...(typeof item.agentThreadId === "string"
                ? { agentThreadId: item.agentThreadId }
                : {}),
              ...(agentPath ? { agentPath } : {}),
            },
            historyTurnId,
          );
          appendCodexOfficialToolResult(
            messages,
            itemId,
            toolName,
            codexSubAgentActivitySummary(kind, agentPath),
            itemTimestamp,
            historyTurnId,
          );
          break;
        }

        case "contextCompaction": {
          appendToolUseMessage(
            messages,
            itemId,
            "ContextCompaction",
            {
              description: "Compact the conversation context",
            },
            historyTurnId,
          );
          appendCodexOfficialToolResult(
            messages,
            itemId,
            "ContextCompaction",
            "Conversation context compacted",
            itemTimestamp,
            historyTurnId,
          );
          break;
        }

        case "imageView": {
          const path = stringValue(item.path);
          appendToolUseMessage(
            messages,
            itemId,
            "ViewImage",
            path ? { path } : {},
            historyTurnId,
          );
          appendToolResultMessage(
            messages,
            itemId,
            "ViewImage",
            path ? `Viewed image: ${path}` : "Image viewed",
            {
              ...(path ? { imagePaths: [path] } : {}),
              ...(itemTimestamp ? { timestamp: itemTimestamp } : {}),
              ...(historyTurnId ? { historyTurnId } : {}),
            },
          );
          break;
        }

        case "sleep": {
          const durationMs =
            typeof item.durationMs === "number" ? item.durationMs : undefined;
          appendToolUseMessage(
            messages,
            itemId,
            "Wait",
            durationMs === undefined ? {} : { durationMs },
            historyTurnId,
          );
          appendCodexOfficialToolResult(
            messages,
            itemId,
            "Wait",
            durationMs === undefined
              ? "Wait completed"
              : `Waited ${durationMs} ms`,
            itemTimestamp,
            historyTurnId,
          );
          break;
        }

        case "imageGeneration": {
          appendToolUseMessage(
            messages,
            itemId,
            "ImageGeneration",
            {
              ...(typeof item.status === "string"
                ? { status: item.status }
                : {}),
              ...(typeof item.revisedPrompt === "string"
                ? { revisedPrompt: item.revisedPrompt }
                : {}),
            },
            historyTurnId,
          );
          appendImageGenerationResult(
            messages,
            {
              id: itemId,
              status: item.status,
              revisedPrompt: item.revisedPrompt,
              savedPath: item.savedPath,
              result: item.result,
            },
            itemId,
            itemTimestamp,
            historyTurnId,
          );
          break;
        }

        case "enteredReviewMode":
        case "exitedReviewMode": {
          appendTextMessage(
            messages,
            "assistant",
            stringValue(item.review) ?? "",
            itemTimestamp,
            itemId,
            historyTurnId,
          );
          break;
        }

        default:
          break;
      }
      if (historyTurnId) {
        for (
          let index = historyStartIndex;
          index < messages.length;
          index += 1
        ) {
          messages[index]!.historyTurnId = historyTurnId;
        }
      }
      applyCodexItemTimestamp(messages, historyStartIndex, itemTiming);
    }
  }

  return messages;
}

/**
 * Restore host-side Desktop tools as ordinary dynamic ThreadItems.
 *
 * app-server intentionally leaves these Responses API records out of
 * `thread/read`. Keeping the compatibility layer at the ThreadItem boundary
 * lets active history and the optional on-device mirror share exactly the
 * same ordering, de-duplication, and future removal point.
 */
export function supplementCodexThreadWithDesktopTools(
  thread: unknown,
  timeline: CodexDesktopToolTimeline,
): unknown {
  const root = asObject(thread);
  if (
    !root ||
    (timeline.events.length === 0 && !timeline.itemTimestamps?.size)
  ) {
    return thread;
  }

  const eventsByTurn = new Map<string, CodexDesktopToolTimelineEvent[]>();
  for (const event of timeline.events) {
    const events = eventsByTurn.get(event.turnId) ?? [];
    events.push(event);
    eventsByTurn.set(event.turnId, events);
  }

  let changed = false;
  const turns = arrayValue(root.turns).map((rawTurn) => {
    const turn = asObject(rawTurn);
    const turnId = stringValue(turn?.id);
    const turnEvents = turnId ? eventsByTurn.get(turnId) : undefined;
    if (!turn) return rawTurn;
    const items = arrayValue(turn.items);
    const supplemented =
      turnEvents && turnEvents.length > 0
        ? supplementCodexTurnItems(items, turnEvents)
        : items;
    const timestamped = supplementCodexItemTimestamps(
      supplemented,
      timeline.itemTimestamps,
    );
    if (timestamped === items) return rawTurn;
    changed = true;
    return { ...turn, items: timestamped };
  });

  return changed ? { ...root, turns } : thread;
}

function supplementCodexItemTimestamps(
  original: unknown[],
  itemTimestamps: ReadonlyMap<string, CodexDesktopItemTimestamp> | undefined,
): unknown[] {
  if (!itemTimestamps?.size) return original;

  let changed = false;
  const timestamped = original.map((rawItem) => {
    const item = asObject(rawItem);
    const itemId = stringValue(item?.id);
    const timing = itemId ? itemTimestamps.get(itemId) : undefined;
    if (!item || !timing || (!timing.startedAt && !timing.completedAt)) {
      return rawItem;
    }
    changed = true;
    return {
      ...item,
      ...(timing.startedAt
        ? { __ccPocketEventStartedAt: timing.startedAt }
        : {}),
      ...(timing.completedAt
        ? { __ccPocketEventCompletedAt: timing.completedAt }
        : {}),
    };
  });
  return changed ? timestamped : original;
}

function supplementCodexTurnItems(
  original: unknown[],
  turnEvents: CodexDesktopToolTimelineEvent[],
): unknown[] {
  const supplementalCallIds = new Set(turnEvents.map((event) => event.callId));
  const officialToolCounts = new Map<string, number>();

  for (const rawItem of original) {
    const item = asObject(rawItem);
    const itemId = stringValue(item?.id);
    const toolName = item ? codexOfficialItemToolName(item) : undefined;
    if (!toolName || (itemId && supplementalCallIds.has(itemId))) continue;
    officialToolCounts.set(
      toolName,
      (officialToolCounts.get(toolName) ?? 0) + 1,
    );
  }

  const eventsByCall = new Map<string, CodexDesktopToolTimelineEvent[]>();
  const callOrder: string[] = [];
  for (const event of turnEvents) {
    let events = eventsByCall.get(event.callId);
    if (!events) {
      events = [];
      eventsByCall.set(event.callId, events);
      callOrder.push(event.callId);
    }
    events.push(event);
  }

  const keptCalls: Array<{
    use: CodexDesktopToolTimelineEvent;
    result?: CodexDesktopToolTimelineEvent;
  }> = [];
  for (const callId of callOrder) {
    const callEvents = eventsByCall.get(callId)!;
    const use = callEvents.find((event) => event.type === "tool_use");
    if (!use) continue;

    const officialCount = officialToolCounts.get(use.name) ?? 0;
    const exactOfficialMatch = original.some(
      (rawItem) => stringValue(asObject(rawItem)?.id) === callId,
    );
    if (!exactOfficialMatch && officialCount > 0) {
      officialToolCounts.set(use.name, officialCount - 1);
      continue;
    }
    keptCalls.push({
      use,
      result: callEvents.find((event) => event.type === "tool_result"),
    });
  }

  if (keptCalls.length === 0) return original;

  const keptCallIds = new Set(keptCalls.map(({ use }) => use.callId));
  const filteredOfficial = original.filter((rawItem) => {
    const itemId = stringValue(asObject(rawItem)?.id);
    return !itemId || !keptCallIds.has(itemId);
  });

  const byVisibleMessage = new Map<number, Record<string, unknown>[]>();
  for (const { use, result } of keptCalls.sort(
    (a, b) => a.use.sequence - b.use.sequence,
  )) {
    const bucket = byVisibleMessage.get(use.afterVisibleMessage) ?? [];
    bucket.push({
      type: "dynamicToolCall",
      id: use.callId,
      tool: use.name,
      arguments: use.input ?? {},
      status: result ? "completed" : "inProgress",
      contentItems:
        result?.content && result.content.length > 0
          ? [{ type: "inputText", text: result.content }]
          : [],
      ...(result?.imagePaths && result.imagePaths.length > 0
        ? { imagePaths: result.imagePaths }
        : use.imagePaths && use.imagePaths.length > 0
          ? { imagePaths: use.imagePaths }
          : {}),
      ...(use.timestamp ? { __ccPocketEventStartedAt: use.timestamp } : {}),
      ...(result?.timestamp
        ? { __ccPocketEventCompletedAt: result.timestamp }
        : {}),
      desktopHostTool: true,
    });
    byVisibleMessage.set(use.afterVisibleMessage, bucket);
  }

  const merged: unknown[] = [];
  const flushed = new Set<number>();
  let visibleMessages = 0;
  const flush = (anchor: number): void => {
    if (flushed.has(anchor)) return;
    flushed.add(anchor);
    merged.push(...(byVisibleMessage.get(anchor) ?? []));
  };

  for (const rawItem of filteredOfficial) {
    if (isVisibleCodexThreadItem(rawItem)) {
      flush(visibleMessages);
      merged.push(rawItem);
      visibleMessages += 1;
    } else {
      merged.push(rawItem);
    }
  }
  flush(visibleMessages);

  for (const anchor of [...byVisibleMessage.keys()].sort((a, b) => a - b)) {
    flush(anchor);
  }

  return merged;
}

function isVisibleCodexThreadItem(rawItem: unknown): boolean {
  const item = asObject(rawItem);
  if (!item) return false;
  if (item.type === "userMessage") return true;
  return (
    (item.type === "agentMessage" || item.type === "plan") &&
    typeof item.text === "string" &&
    item.text.trim().length > 0
  );
}

function codexOfficialItemToolName(
  item: Record<string, unknown>,
): string | undefined {
  switch (item.type) {
    case "commandExecution":
      return describeCodexHistoryCommand(item).name;
    case "fileChange":
      return "FileChange";
    case "mcpToolCall":
      return `mcp:${stringValue(item.server) ?? "mcp"}/${
        stringValue(item.tool) ?? "tool"
      }`;
    case "dynamicToolCall":
      return stringValue(item.tool) ?? "tool";
    case "webSearch":
      return "WebSearch";
    case "collabAgentToolCall":
      return codexCollabHistoryToolName(stringValue(item.tool) ?? "subagent");
    case "subAgentActivity":
      return codexSubAgentActivityHistoryToolName(
        stringValue(item.kind) ?? "activity",
      );
    case "contextCompaction":
      return "ContextCompaction";
    case "imageView":
      return "ViewImage";
    case "sleep":
      return "Wait";
    case "imageGeneration":
      return "ImageGeneration";
    default:
      return undefined;
  }
}

function codexSubAgentActivityHistoryToolName(kind: string): string {
  switch (kind.replace(/[_\s-]/g, "").toLowerCase()) {
    case "started":
      return "SpawnAgent";
    case "interacted":
      return "SubAgentInteraction";
    case "interrupted":
      return "InterruptAgent";
    default:
      return "SubAgentActivity";
  }
}

function codexSubAgentActivitySummary(
  kind: string,
  agentPath: string | undefined,
): string {
  const target = agentPath ? ` ${agentPath}` : "";
  switch (kind.replace(/[_\s-]/g, "").toLowerCase()) {
    case "started":
      return `Started sub-agent${target}`;
    case "interacted":
      return `Interacted with sub-agent${target}`;
    case "interrupted":
      return `Interrupted sub-agent${target}`;
    default:
      return `Sub-agent activity: ${kind}${target}`;
  }
}

function asObject(value: unknown): Record<string, unknown> | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return null;
  }
  return value as Record<string, unknown>;
}

function parseObjectLike(value: unknown): Record<string, unknown> {
  if (typeof value === "string") {
    try {
      const parsed = JSON.parse(value) as unknown;
      return asObject(parsed) ?? { value: parsed };
    } catch {
      return { value };
    }
  }
  return asObject(value) ?? {};
}

const DYNAMIC_TOOL_SUMMARY_LIMITS = Object.freeze({
  file_path: 4_096,
  notebook_path: 4_096,
  path: 4_096,
  cwd: 4_096,
  glob: 512,
  pattern: 512,
  query: 512,
  url: 2_048,
});

function dynamicToolSummaryInput(
  input: Record<string, unknown>,
): Record<string, string> {
  const summary: Record<string, string> = {};
  for (const [key, maximumLength] of Object.entries(
    DYNAMIC_TOOL_SUMMARY_LIMITS,
  )) {
    const value = input[key];
    if (typeof value !== "string") continue;
    const normalized = value.trim();
    if (!normalized) continue;
    summary[key] = normalized.slice(0, maximumLength);
  }
  return summary;
}

function appendTextMessage(
  messages: SessionHistoryMessage[],
  role: "user" | "assistant",
  text: string,
  timestamp?: string,
  uuid?: string,
  historyTurnId?: string,
): boolean {
  const normalized = text.trim();
  if (!normalized) return false;

  const last = messages.at(-1);
  if (
    last &&
    last.role === role &&
    Array.isArray(last.content) &&
    last.content.length === 1 &&
    last.content[0].type === "text" &&
    typeof last.content[0].text === "string" &&
    last.content[0].text.trim() === normalized &&
    (!uuid || last.uuid === uuid) &&
    last.historyTurnId === historyTurnId
  ) {
    return false;
  }

  messages.push({
    role,
    ...(uuid ? { uuid } : {}),
    content: [{ type: "text", text }],
    ...(historyTurnId ? { historyTurnId } : {}),
    ...(timestamp ? { timestamp } : {}),
  });
  return true;
}

function assignStableCodexAssistantUuids(
  messages: SessionHistoryMessage[],
  threadId: string,
): void {
  let assistantOrdinal = 0;
  for (const message of messages) {
    if (message.role !== "assistant") continue;
    assistantOrdinal += 1;
    if (message.uuid || !Array.isArray(message.content)) continue;
    const hasText = message.content.some(
      (item) => item.type === "text" && typeof item.text === "string",
    );
    if (!hasText) continue;
    const digest = createHash("sha256")
      .update(
        JSON.stringify([
          threadId,
          assistantOrdinal,
          message.timestamp ?? null,
          message.content,
        ]),
      )
      .digest("base64url")
      .slice(0, 32);
    message.uuid = `codex:assistant:${digest}`;
  }
}

function countCodexUserTurns(messages: SessionHistoryMessage[]): number {
  return messages.filter(
    (message) => message.role === "user" && !message.isMeta,
  ).length;
}

function applyCodexThreadRollback(
  messages: SessionHistoryMessage[],
  numTurns: number,
): void {
  if (!Number.isFinite(numTurns) || numTurns <= 0) return;

  const userIndices = messages
    .map((message, index) =>
      message.role === "user" && !message.isMeta ? index : -1,
    )
    .filter((index) => index >= 0);
  if (userIndices.length === 0) return;
  if (numTurns >= userIndices.length) {
    messages.length = 0;
    return;
  }

  const keepUserTurns = userIndices.length - numTurns;
  const cutIndex = userIndices[keepUserTurns];
  messages.splice(cutIndex);
}

function appendImageGenerationResult(
  messages: SessionHistoryMessage[],
  payload: Record<string, unknown>,
  fallbackId: string,
  timestamp?: string,
  historyTurnId?: string,
): void {
  const id =
    typeof payload.call_id === "string"
      ? payload.call_id
      : typeof payload.id === "string"
        ? payload.id
        : fallbackId;
  if (
    messages.some(
      (m) =>
        m.role === "tool_result" &&
        m.toolUseId === id &&
        m.historyTurnId === historyTurnId,
    )
  ) {
    return;
  }

  const status =
    typeof payload.status === "string" ? payload.status : undefined;
  const revisedPrompt =
    typeof payload.revised_prompt === "string"
      ? payload.revised_prompt
      : typeof payload.revisedPrompt === "string"
        ? payload.revisedPrompt
        : undefined;
  const savedPath =
    typeof payload.saved_path === "string"
      ? payload.saved_path
      : typeof payload.savedPath === "string"
        ? payload.savedPath
        : undefined;
  const result =
    typeof payload.result === "string" ? payload.result : undefined;
  const base64Image =
    !savedPath && result
      ? { data: stripImageDataUrlPrefix(result), mimeType: "image/png" }
      : undefined;

  const contentLines: string[] = [];
  if (status) contentLines.push(`status: ${status}`);
  if (revisedPrompt) contentLines.push(`revisedPrompt: ${revisedPrompt}`);
  if (savedPath) contentLines.push(`savedPath: ${savedPath}`);

  messages.push({
    role: "tool_result",
    toolUseId: id,
    toolName: "ImageGeneration",
    content: contentLines.join("\n"),
    ...(historyTurnId ? { historyTurnId } : {}),
    ...(savedPath ? { imagePaths: [savedPath] } : {}),
    ...(base64Image ? { imageBase64: [base64Image] } : {}),
    ...(timestamp ? { timestamp } : {}),
  });
}

function stripImageDataUrlPrefix(value: string): string {
  const match = value.match(/^data:image\/[a-z0-9.+-]+;base64,(.*)$/i);
  return match?.[1] ?? value;
}

function appendToolResultMessage(
  messages: SessionHistoryMessage[],
  id: string,
  name: string | undefined,
  content: string,
  options?: {
    imagePaths?: string[];
    imageBase64?: Array<{ data: string; mimeType: string }>;
    timestamp?: string;
    historyTurnId?: string;
  },
): void {
  if (
    messages.some(
      (m) =>
        m.role === "tool_result" &&
        m.toolUseId === id &&
        m.historyTurnId === options?.historyTurnId,
    )
  ) {
    return;
  }

  const imagePaths = options?.imagePaths ?? [];
  const imageBase64 = options?.imageBase64 ?? [];
  if (!content.trim() && imagePaths.length === 0 && imageBase64.length === 0) {
    return;
  }

  messages.push({
    role: "tool_result",
    toolUseId: id,
    ...(name ? { toolName: name } : {}),
    content,
    ...(options?.historyTurnId ? { historyTurnId: options.historyTurnId } : {}),
    ...(imagePaths.length > 0 ? { imagePaths } : {}),
    ...(imageBase64.length > 0 ? { imageBase64 } : {}),
    ...(options?.timestamp ? { timestamp: options.timestamp } : {}),
  });
}

function appendToolUseMessage(
  messages: SessionHistoryMessage[],
  id: string,
  name: string,
  input: Record<string, unknown>,
  historyTurnId?: string,
): void {
  const normalizedName = name.trim();
  if (!normalizedName) return;

  const last = messages.at(-1);
  if (
    last &&
    last.role === "assistant" &&
    Array.isArray(last.content) &&
    last.content.length === 1 &&
    last.content[0].type === "tool_use" &&
    last.content[0].id === id &&
    last.content[0].name === normalizedName &&
    last.historyTurnId === historyTurnId
  ) {
    return;
  }

  messages.push({
    role: "assistant",
    uuid: id,
    ...(historyTurnId ? { historyTurnId } : {}),
    content: [
      {
        type: "tool_use",
        id,
        name: normalizedName,
        input,
      },
    ],
  });
}

function describeCodexHistoryCommand(payload: Record<string, unknown>): {
  name: string;
  input: Record<string, unknown>;
} {
  const command = typeof payload.command === "string" ? payload.command : "";
  const rawActions = payload.commandActions ?? payload.command_actions;
  const actions = Array.isArray(rawActions)
    ? rawActions
        .map(asObject)
        .filter((value): value is Record<string, unknown> => value !== null)
    : [];
  const baseInput: Record<string, unknown> = {
    command,
    ...(typeof payload.cwd === "string" ? { cwd: payload.cwd } : {}),
    ...(typeof payload.pluginId === "string"
      ? { pluginId: payload.pluginId }
      : typeof payload.plugin_id === "string"
        ? { pluginId: payload.plugin_id }
        : {}),
    ...(typeof payload.scriptPath === "string"
      ? { scriptPath: payload.scriptPath }
      : typeof payload.script_path === "string"
        ? { scriptPath: payload.script_path }
        : {}),
    ...(actions.length > 0 ? { commandActions: actions } : {}),
    ...(typeof payload.status === "string" ? { status: payload.status } : {}),
    ...(typeof payload.exitCode === "number"
      ? { exitCode: payload.exitCode }
      : {}),
    ...(typeof payload.durationMs === "number"
      ? { durationMs: payload.durationMs }
      : {}),
  };
  if (actions.length > 1) {
    return {
      name: "MultiCommand",
      input: {
        ...baseInput,
        commands: actions
          .map((action) => action.command)
          .filter((value): value is string => typeof value === "string"),
      },
    };
  }
  const action = actions[0];
  if (!action) return { name: "Bash", input: baseInput };
  const actionType =
    typeof action.type === "string"
      ? action.type.replace(/[_\s-]/g, "").toLowerCase()
      : "";
  if (actionType === "read") {
    const path = typeof action.path === "string" ? action.path : undefined;
    const readsSkill = path?.toLowerCase().endsWith("/skill.md") === true;
    return {
      name: readsSkill ? "ReadSkill" : "Read",
      input: {
        ...baseInput,
        ...(path ? { file_path: path } : {}),
        ...(readsSkill && path
          ? { skill: path.split(/[\\/]/).filter(Boolean).at(-2) ?? "Skill" }
          : {}),
      },
    };
  }
  if (actionType === "listfiles") {
    return {
      name: "ListFiles",
      input: {
        ...baseInput,
        ...(typeof action.path === "string" ? { path: action.path } : {}),
      },
    };
  }
  if (actionType === "search") {
    return {
      name: "Search",
      input: {
        ...baseInput,
        ...(typeof action.query === "string" ? { query: action.query } : {}),
        ...(typeof action.path === "string" ? { path: action.path } : {}),
      },
    };
  }
  return { name: "Bash", input: baseInput };
}

function codexCollabHistoryToolName(tool: string): string {
  switch (tool.replace(/[_\s-]/g, "").toLowerCase()) {
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

function normalizeCodexMcpResult(result: unknown): {
  content: string;
  imageBase64: Array<{ data: string; mimeType: string }>;
} {
  const wrapper = asObject(result);
  let value = result;
  if (wrapper && Object.prototype.hasOwnProperty.call(wrapper, "Ok")) {
    value = wrapper.Ok;
  } else if (wrapper && Object.prototype.hasOwnProperty.call(wrapper, "Err")) {
    value = wrapper.Err;
  }

  if (typeof value === "string") {
    return { content: value, imageBase64: [] };
  }

  const record = asObject(value);
  const contentItems = Array.isArray(record?.content) ? record.content : null;
  if (!contentItems) {
    return {
      content: value == null ? "MCP call completed" : JSON.stringify(value),
      imageBase64: [],
    };
  }

  const textParts: string[] = [];
  const imageBase64: Array<{ data: string; mimeType: string }> = [];

  for (const entry of contentItems) {
    const item = asObject(entry);
    if (!item) continue;
    const type = typeof item.type === "string" ? item.type : "";

    if (type === "text" && typeof item.text === "string") {
      textParts.push(item.text);
      continue;
    }

    if (type === "image") {
      const source = asObject(item.source);
      const rawData =
        typeof item.data === "string"
          ? item.data
          : source?.type === "base64" && typeof source.data === "string"
            ? source.data
            : undefined;
      if (rawData) {
        const mimeType =
          typeof item.mimeType === "string"
            ? item.mimeType
            : typeof item.mediaType === "string"
              ? item.mediaType
              : typeof item.media_type === "string"
                ? item.media_type
                : typeof source?.media_type === "string"
                  ? source.media_type
                  : "image/png";
        imageBase64.push({
          data: stripImageDataUrlPrefix(rawData),
          mimeType,
        });
      }
      continue;
    }

    textParts.push(JSON.stringify(item));
  }

  const content = textParts.join("\n").trim();
  if (content) return { content, imageBase64 };

  if (imageBase64.length > 0) {
    return {
      content:
        imageBase64.length === 1
          ? "Generated 1 image"
          : `Generated ${imageBase64.length} images`,
      imageBase64,
    };
  }

  return {
    content: value == null ? "MCP call completed" : JSON.stringify(value),
    imageBase64,
  };
}

function isCodexInjectedUserContext(text: string): boolean {
  const normalized = text.trimStart();
  return (
    normalized.startsWith("# AGENTS.md instructions for ") ||
    normalized.startsWith("<environment_context>") ||
    normalized.startsWith("<permissions instructions>") ||
    normalized.startsWith("<collaboration_mode>") ||
    normalized.startsWith("<personality_spec>") ||
    normalized.startsWith("<skills_instructions>") ||
    normalized.startsWith("<plugins_instructions>") ||
    normalized.startsWith("<skill>")
  );
}

function getCodexSearchInput(
  payload: Record<string, unknown>,
): Record<string, unknown> {
  const action = asObject(payload.action);
  const input: Record<string, unknown> = {};
  if (typeof action?.query === "string") {
    input.query = action.query;
  }
  if (Array.isArray(action?.queries)) {
    const queries = (action.queries as unknown[]).filter(
      (q): q is string => typeof q === "string" && q.length > 0,
    );
    if (queries.length > 0) {
      input.queries = queries;
    }
  }
  return input;
}

/**
 * Find the JSONL file path for a given sessionId by searching sessions-index.json files,
 * then falling back to scanning directories for the JSONL file directly.
 */
async function findSessionJsonlPath(sessionId: string): Promise<string | null> {
  const projectsDir = join(homedir(), ".claude", "projects");

  let projectDirs: string[];
  try {
    projectDirs = await readdir(projectsDir);
  } catch {
    return null;
  }

  // First pass: check sessions-index.json files
  for (const dirName of projectDirs) {
    if (dirName.startsWith(".")) continue;

    const indexPath = join(projectsDir, dirName, "sessions-index.json");
    let raw: string;
    try {
      raw = await readFile(indexPath, "utf-8");
    } catch {
      continue;
    }

    let index: RawSessionIndexFile;
    try {
      index = JSON.parse(raw) as RawSessionIndexFile;
    } catch {
      continue;
    }

    if (!Array.isArray(index.entries)) continue;

    const entry = index.entries.find((e) => e.sessionId === sessionId);
    if (entry?.fullPath) {
      return entry.fullPath;
    }
  }

  // Fallback: scan directories for the JSONL file directly
  // This handles worktree sessions without sessions-index.json
  const jsonlFileName = `${sessionId}.jsonl`;
  for (const dirName of projectDirs) {
    if (dirName.startsWith(".")) continue;

    const candidatePath = join(projectsDir, dirName, jsonlFileName);
    try {
      await stat(candidatePath);
      return candidatePath;
    } catch {
      continue;
    }
  }

  return null;
}

async function findCodexSessionJsonlPath(
  threadId: string,
): Promise<string | null> {
  ensureCodexSessionPathIndexRoot();
  const cached = codexSessionJsonlPathCache.get(threadId);
  if (cached) {
    try {
      const info = await stat(cached);
      const expectedIdentity = codexSessionJsonlPathIdentityCache.get(threadId);
      if (
        expectedIdentity === undefined ||
        expectedIdentity === codexSessionFileIdentity(info)
      ) {
        return cached;
      }
      codexSessionJsonlPathCache.delete(threadId);
      codexSessionJsonlPathIdentityCache.delete(threadId);
    } catch {
      codexSessionJsonlPathCache.delete(threadId);
      codexSessionJsonlPathIdentityCache.delete(threadId);
    }
  }
  await refreshCodexSessionJsonlPathIndex(false);
  let indexed = codexSessionJsonlPathCache.get(threadId);
  if (indexed) return indexed;

  // A newly-created rollout can appear after the shared index was published.
  // Throttle the compensating directory walk globally: discovery asks for
  // many thread ids in small batches, and a per-id refresh turns one missing
  // rollout into O(missing × files) filesystem work.
  const currentFingerprint = await codexSessionPathIndexFingerprint(
    codexSessionPathIndexRoot,
  );
  if (
    currentFingerprint !== codexSessionPathIndexFingerprintValue ||
    Date.now() - codexSessionPathIndexRefreshedAt >=
      CODEX_SESSION_PATH_INDEX_RECHECK_MS
  ) {
    await refreshCodexSessionJsonlPathIndex(true);
    indexed = codexSessionJsonlPathCache.get(threadId);
    if (indexed) return indexed;
  }

  // Legacy/custom rollouts may not carry the thread id in their filename.
  // Build their content-derived index once per directory generation, shared by
  // every concurrent or later miss, and cache successful lookups alongside
  // ordinary UUID filenames.
  await refreshLegacyCodexSessionJsonlPathIndex();
  if (
    codexSessionLegacyPathIndexGeneration !== codexSessionPathIndexGeneration
  ) {
    // A directory refresh raced the legacy scan. Index the current generation
    // before returning rather than exposing a transient false miss.
    await refreshLegacyCodexSessionJsonlPathIndex();
  }
  return codexSessionJsonlPathCache.get(threadId) ?? null;
}

// Root/current-day fingerprints detect ordinary new rollouts immediately.
// This slower fallback only covers unusual writes into older date buckets and
// must remain long enough that one all-thread discovery cannot repeatedly walk
// the same tree as it advances through batches.
const CODEX_SESSION_PATH_INDEX_RECHECK_MS = 60_000;
const codexSessionJsonlPathCache = new Map<string, string>();
const codexSessionJsonlPathIdentityCache = new Map<string, string>();
let codexSessionPathIndexReady = false;
let codexSessionPathIndexFlight: Promise<void> | null = null;
let codexSessionPathIndexRoot: string | null = null;
let codexSessionPathIndexFiles: string[] = [];
let codexSessionPathIndexGeneration = 0;
let codexSessionPathIndexRefreshedAt = 0;
let codexSessionPathIndexFingerprintValue = "";
let codexSessionLegacyPathIndexGeneration = -1;
let codexSessionLegacyPathIndexFlight: Promise<void> | null = null;

function ensureCodexSessionPathIndexRoot(): void {
  const root = resolveCodexSessionsDir();
  if (codexSessionPathIndexRoot === root) return;
  codexSessionPathIndexRoot = root;
  codexSessionJsonlPathCache.clear();
  codexSessionJsonlPathIdentityCache.clear();
  codexSessionPathIndexReady = false;
  codexSessionPathIndexFlight = null;
  codexSessionPathIndexFiles = [];
  codexSessionPathIndexGeneration += 1;
  codexSessionPathIndexRefreshedAt = 0;
  codexSessionPathIndexFingerprintValue = "";
  codexSessionLegacyPathIndexGeneration = -1;
  codexSessionLegacyPathIndexFlight = null;
}

function rolloutThreadIdFromPath(filePath: string): string | null {
  const stem = basename(filePath, ".jsonl");
  return (
    stem.match(
      /(?:^|-)([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/i,
    )?.[1] ?? null
  );
}

function refreshCodexSessionJsonlPathIndex(force: boolean): Promise<void> {
  ensureCodexSessionPathIndexRoot();
  if (codexSessionPathIndexFlight) return codexSessionPathIndexFlight;
  if (codexSessionPathIndexReady && !force) return Promise.resolve();
  const root = codexSessionPathIndexRoot;
  const flight = listCodexSessionFiles()
    .then(async (files) => {
      // Tests and multi-source hosts can switch CODEX_HOME while an earlier
      // directory walk is still in flight. Never let that stale result poison
      // the cache belonging to the new source identity.
      if (codexSessionPathIndexRoot !== root) return;
      const fingerprint = await codexSessionPathIndexFingerprint(root);
      if (codexSessionPathIndexRoot !== root) return;
      const next = new Map<string, string>();
      for (const filePath of files) {
        const threadId = rolloutThreadIdFromPath(filePath);
        // Preserve the existing resolver's first-match behavior if a damaged
        // or manually copied session tree contains duplicate thread ids.
        if (threadId && !next.has(threadId)) next.set(threadId, filePath);
      }
      codexSessionJsonlPathCache.clear();
      codexSessionJsonlPathIdentityCache.clear();
      for (const [threadId, filePath] of next) {
        codexSessionJsonlPathCache.set(threadId, filePath);
      }
      codexSessionPathIndexFiles = files;
      codexSessionPathIndexGeneration += 1;
      codexSessionPathIndexRefreshedAt = Date.now();
      codexSessionPathIndexFingerprintValue = fingerprint;
      codexSessionLegacyPathIndexGeneration = -1;
      codexSessionPathIndexReady = true;
    })
    .finally(() => {
      if (codexSessionPathIndexFlight === flight) {
        codexSessionPathIndexFlight = null;
      }
    });
  codexSessionPathIndexFlight = flight;
  return flight;
}

async function codexSessionPathIndexFingerprint(
  root: string | null,
): Promise<string> {
  if (!root) return "";
  const now = new Date();
  const dateDirectories = new Set<string>([
    join(
      root,
      String(now.getFullYear()).padStart(4, "0"),
      String(now.getMonth() + 1).padStart(2, "0"),
      String(now.getDate()).padStart(2, "0"),
    ),
    join(
      root,
      String(now.getUTCFullYear()).padStart(4, "0"),
      String(now.getUTCMonth() + 1).padStart(2, "0"),
      String(now.getUTCDate()).padStart(2, "0"),
    ),
  ]);
  const paths = [root, ...dateDirectories];
  const fingerprints = await Promise.all(
    paths.map(async (path) => {
      try {
        const info = await stat(path);
        return `${path}:${info.dev}:${info.ino}:${info.mtimeMs}`;
      } catch {
        return `${path}:missing`;
      }
    }),
  );
  return fingerprints.join("|");
}

function refreshLegacyCodexSessionJsonlPathIndex(): Promise<void> {
  ensureCodexSessionPathIndexRoot();
  if (
    codexSessionLegacyPathIndexGeneration === codexSessionPathIndexGeneration
  ) {
    return Promise.resolve();
  }
  if (codexSessionLegacyPathIndexFlight) {
    return codexSessionLegacyPathIndexFlight;
  }
  const root = codexSessionPathIndexRoot;
  const generation = codexSessionPathIndexGeneration;
  const files = codexSessionPathIndexFiles.filter(
    (filePath) => rolloutThreadIdFromPath(filePath) === null,
  );
  const flight = parallelMap(
    files,
    PARALLEL_FILE_READ_LIMIT,
    async (filePath) => {
      const [threadId, info] = await Promise.all([
        codexJsonlThreadId(filePath).catch(() => null),
        stat(filePath).catch(() => null),
      ]);
      return {
        filePath,
        fallbackSessionId: basename(filePath, ".jsonl"),
        threadId,
        identity: info ? codexSessionFileIdentity(info) : null,
      };
    },
  )
    .then((entries) => {
      if (
        codexSessionPathIndexRoot !== root ||
        codexSessionPathIndexGeneration !== generation
      ) {
        return;
      }
      for (const {
        filePath,
        fallbackSessionId,
        threadId,
        identity,
      } of entries) {
        if (
          fallbackSessionId &&
          !codexSessionJsonlPathCache.has(fallbackSessionId)
        ) {
          codexSessionJsonlPathCache.set(fallbackSessionId, filePath);
          if (identity) {
            codexSessionJsonlPathIdentityCache.set(fallbackSessionId, identity);
          }
        }
        if (threadId && !codexSessionJsonlPathCache.has(threadId)) {
          codexSessionJsonlPathCache.set(threadId, filePath);
          if (identity) {
            codexSessionJsonlPathIdentityCache.set(threadId, identity);
          }
        }
      }
      codexSessionLegacyPathIndexGeneration = generation;
    })
    .finally(() => {
      if (codexSessionLegacyPathIndexFlight === flight) {
        codexSessionLegacyPathIndexFlight = null;
      }
    });
  codexSessionLegacyPathIndexFlight = flight;
  return flight;
}

function codexSessionFileIdentity(info: {
  dev: number | bigint;
  ino: number | bigint;
  birthtimeMs: number;
}): string {
  return `${info.dev}:${info.ino}:${info.birthtimeMs}`;
}

/**
 * Resolve the durable rollout owned by one Codex thread without exposing the
 * broader recent-session scanner to optional local features.
 */
export async function resolveCodexSessionJsonlPath(
  threadId: string,
): Promise<string | null> {
  return findCodexSessionJsonlPath(threadId);
}

interface CodexDesktopToolTimelineCacheEntry {
  jsonlPath: string;
  builder: CodexDesktopToolTimelineBuilder;
  readOffset: number;
  pendingLine: Buffer;
  mtimeMs: number;
}

const CODEX_DESKTOP_TOOL_TIMELINE_CACHE_LIMIT = 8;
// A newly focused durable thread must not block its first visible history on a
// complete scan of a potentially hundreds-of-megabytes rollout. Recent turns
// and their tool timestamps live at the tail; subsequent refreshes continue
// incrementally from the remembered offset.
const CODEX_DESKTOP_TOOL_TIMELINE_INITIAL_TAIL_BYTES = 16 * 1024 * 1024;
const codexDesktopToolTimelineCache = new Map<
  string,
  CodexDesktopToolTimelineCacheEntry
>();
const codexDesktopToolTimelineRefreshes = new Map<
  string,
  Promise<CodexDesktopToolTimeline>
>();

/**
 * Read the host-side Responses API tool records omitted by app-server's
 * canonical ThreadItems. The first read consumes a bounded recent tail; later
 * reads consume appended bytes only, which keeps initial conversation loading
 * and Desktop continuity polling bounded even for very large conversations.
 */
export async function getCodexDesktopToolTimeline(
  threadId: string,
): Promise<CodexDesktopToolTimeline> {
  const inFlight = codexDesktopToolTimelineRefreshes.get(threadId);
  if (inFlight) return inFlight;

  const refresh = refreshCodexDesktopToolTimeline(threadId).finally(() => {
    codexDesktopToolTimelineRefreshes.delete(threadId);
  });
  codexDesktopToolTimelineRefreshes.set(threadId, refresh);
  return refresh;
}

async function refreshCodexDesktopToolTimeline(
  threadId: string,
): Promise<CodexDesktopToolTimeline> {
  const cachedPath = codexDesktopToolTimelineCache.get(threadId)?.jsonlPath;
  const jsonlPath = cachedPath ?? (await findCodexSessionJsonlPath(threadId));
  if (!jsonlPath) return emptyCodexDesktopToolTimeline();

  let fileStat;
  try {
    fileStat = await stat(jsonlPath);
  } catch {
    if (cachedPath) codexDesktopToolTimelineCache.delete(threadId);
    return emptyCodexDesktopToolTimeline();
  }

  let cache = codexDesktopToolTimelineCache.get(threadId);
  if (
    !cache ||
    cache.jsonlPath !== jsonlPath ||
    fileStat.size < cache.readOffset ||
    (fileStat.size === cache.readOffset &&
      cache.mtimeMs !== 0 &&
      fileStat.mtimeMs !== cache.mtimeMs)
  ) {
    const initialReadOffset = Math.max(
      0,
      fileStat.size - CODEX_DESKTOP_TOOL_TIMELINE_INITIAL_TAIL_BYTES,
    );
    cache = {
      jsonlPath,
      builder: new CodexDesktopToolTimelineBuilder(),
      readOffset: initialReadOffset,
      pendingLine: Buffer.alloc(0),
      mtimeMs: 0,
    };
    codexDesktopToolTimelineCache.set(threadId, cache);
    trimCodexDesktopToolTimelineCache();
  } else {
    // Refresh insertion order for the small LRU cache.
    codexDesktopToolTimelineCache.delete(threadId);
    codexDesktopToolTimelineCache.set(threadId, cache);
  }

  if (
    fileStat.size === cache.readOffset &&
    fileStat.mtimeMs === cache.mtimeMs
  ) {
    return cache.builder.snapshot();
  }

  if (fileStat.size > cache.readOffset) {
    const stream = createReadStream(jsonlPath, {
      start: cache.readOffset,
      end: fileStat.size - 1,
    });
    let pending = cache.pendingLine;
    try {
      for await (const chunk of stream) {
        const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
        const combined =
          pending.length === 0 ? bytes : Buffer.concat([pending, bytes]);
        let lineStart = 0;
        let lineEnd = combined.indexOf(0x0a, lineStart);
        while (lineEnd !== -1) {
          const rawLine = combined.subarray(lineStart, lineEnd);
          if (rawLine.length > 0) {
            try {
              cache.builder.ingest(JSON.parse(rawLine.toString("utf8")));
            } catch {
              // A malformed rollout entry must not poison later append reads.
            }
          }
          lineStart = lineEnd + 1;
          lineEnd = combined.indexOf(0x0a, lineStart);
        }
        pending = combined.subarray(lineStart);
      }
    } finally {
      stream.destroy();
    }
    cache.pendingLine = Buffer.from(pending);
    cache.readOffset = fileStat.size;
  }

  cache.mtimeMs = fileStat.mtimeMs;
  return cache.builder.snapshot();
}

function emptyCodexDesktopToolTimeline(): CodexDesktopToolTimeline {
  return { events: [], callIds: new Set<string>() };
}

function trimCodexDesktopToolTimelineCache(): void {
  while (
    codexDesktopToolTimelineCache.size > CODEX_DESKTOP_TOOL_TIMELINE_CACHE_LIMIT
  ) {
    const oldest = codexDesktopToolTimelineCache.keys().next().value;
    if (!oldest) return;
    codexDesktopToolTimelineCache.delete(oldest);
  }
}

interface CodexRolloutOwnerMetadata {
  threadId: string;
  projectPath?: string;
  resumeCwd?: string;
}

async function codexJsonlOwnerMetadata(
  filePath: string,
): Promise<CodexRolloutOwnerMetadata | null> {
  for await (const { line } of streamJsonlLines(filePath)) {
    if (!line.trim()) continue;
    let entry: Record<string, unknown>;
    try {
      entry = JSON.parse(line) as Record<string, unknown>;
    } catch {
      continue;
    }
    if (entry.type !== "session_meta") continue;
    const payload = asObject(entry.payload);
    if (typeof payload?.id !== "string" || payload.id.length === 0) {
      return null;
    }
    const rawCwd =
      typeof payload.cwd === "string" && payload.cwd.trim().length > 0
        ? payload.cwd
        : undefined;
    const projectPath = rawCwd ? normalizeWorktreePath(rawCwd) : undefined;
    return {
      threadId: payload.id,
      ...(projectPath ? { projectPath } : {}),
      ...(rawCwd && rawCwd !== projectPath ? { resumeCwd: rawCwd } : {}),
    };
  }
  return null;
}

async function codexJsonlThreadId(filePath: string): Promise<string | null> {
  return (await codexJsonlOwnerMetadata(filePath))?.threadId ?? null;
}

/**
 * Read past conversation messages from a session's JSONL file.
 * Returns user and assistant messages suitable for display.
 */
interface ParsedClaudeHistoryLine {
  message: SessionHistoryMessage;
  isRealUserTurn: boolean;
}

function parseClaudeHistoryLine(line: string): ParsedClaudeHistoryLine | null {
  if (!line.trim()) return null;

  let entry: Record<string, unknown>;
  try {
    const parsed = JSON.parse(line) as unknown;
    const parsedEntry = asObject(parsed);
    if (!parsedEntry) return null;
    entry = parsedEntry;
  } catch {
    return null;
  }

  const type = entry.type;
  if (type !== "user" && type !== "assistant") return null;

  // Context compaction and transcript-only records are not real user input.
  if (
    type === "user" &&
    (entry.isCompactSummary === true ||
      entry.isVisibleInTranscriptOnly === true)
  ) {
    return null;
  }

  const sourceMessage = asObject(entry.message);
  if (!sourceMessage) return null;
  const sourceRole = sourceMessage.role;
  if (sourceRole !== "user" && sourceRole !== "assistant") return null;
  const sourceContent = sourceMessage.content;
  if (!sourceContent) return null;

  const isMeta =
    sourceRole === "user" && entry.isMeta === true ? true : undefined;
  const uuid = typeof entry.uuid === "string" ? entry.uuid : undefined;
  const timestamp =
    typeof entry.timestamp === "string" ? entry.timestamp : undefined;

  if (typeof sourceContent === "string") {
    if (!sourceContent) return null;
    return {
      message: {
        role: sourceRole,
        content: [{ type: "text", text: sourceContent }],
        ...(uuid ? { uuid } : {}),
        ...(timestamp ? { timestamp } : {}),
        ...(isMeta ? { isMeta } : {}),
      },
      isRealUserTurn: type === "user" && sourceRole === "user" && !isMeta,
    };
  }

  if (!Array.isArray(sourceContent)) return null;

  // Preserve the existing display projection: text and tool_use are retained,
  // while tool_result-only user records do not become visible user turns.
  const content: SessionHistoryContentItem[] = [];
  let imageCount = 0;
  for (const rawContent of sourceContent) {
    const item = asObject(rawContent);
    if (!item) continue;
    const contentType = item.type;

    if (contentType === "text" && item.text) {
      content.push({ type: "text", text: item.text as string });
    } else if (contentType === "tool_use") {
      content.push({
        type: "tool_use",
        id: item.id as string,
        name: item.name as string,
        input: (item.input as Record<string, unknown>) ?? {},
      });
    } else if (contentType === "image") {
      imageCount += 1;
    }
  }

  if (content.length === 0 && imageCount === 0) return null;
  if (content.length === 0) {
    content.push({
      type: "text",
      text: `[Image attached${imageCount > 1 ? ` x${imageCount}` : ""}]`,
    });
  }

  return {
    message: {
      role: sourceRole,
      content,
      ...(uuid ? { uuid } : {}),
      ...(timestamp ? { timestamp } : {}),
      ...(isMeta ? { isMeta } : {}),
      ...(imageCount > 0 ? { imageCount } : {}),
    },
    isRealUserTurn: type === "user" && sourceRole === "user" && !isMeta,
  };
}

export async function getSessionHistory(
  sessionId: string,
  options: {
    onProgress?: (progress: { completedUnits: number }) => void;
  } = {},
): Promise<SessionHistoryMessage[]> {
  const jsonlPath = await findSessionJsonlPath(sessionId);
  if (!jsonlPath) return [];

  const messages: SessionHistoryMessage[] = [];
  let processedLines = 0;
  try {
    for await (const { line } of streamJsonlLines(jsonlPath)) {
      processedLines += 1;
      if (processedLines % 512 === 0) {
        options.onProgress?.({ completedUnits: processedLines });
      }
      const parsed = parseClaudeHistoryLine(line);
      if (parsed) messages.push(parsed.message);
    }
  } catch {
    return [];
  }

  return messages;
}

const CLAUDE_HISTORY_WINDOW_DEFAULT_USER_TURNS = 5;
const CLAUDE_HISTORY_WINDOW_DEFAULT_MAX_BYTES = 512 * 1024;
const CLAUDE_HISTORY_WINDOW_READ_CHUNK_BYTES = 64 * 1024;
const CLAUDE_HISTORY_CURSOR_VERSION = 1;
const CLAUDE_HISTORY_CURSOR_MAX_LENGTH = 1024;

interface ClaudeHistoryCursorPayload {
  v: typeof CLAUDE_HISTORY_CURSOR_VERSION;
  dev: string;
  ino: string;
  snapshotSize: number;
  endOffset: number;
  skipTrailingPartial: boolean;
}

export interface ClaudeJsonlHistoryWindowOptions {
  /** Opaque cursor returned by the preceding page; omit for the newest page. */
  cursor?: string;
  /** Maximum number of non-meta user turns to include. */
  maxUserTurns?: number;
  /** Hard upper bound on bytes read from the JSONL file during this call. */
  maxBytes?: number;
}

export interface ClaudeJsonlHistoryWindow {
  messages: SessionHistoryMessage[];
  /** Cursor for the next, older page. Null means the snapshot is exhausted. */
  nextCursor: string | null;
  hasMore: boolean;
  /** Actual file bytes read, always less than or equal to maxBytes. */
  bytesRead: number;
  /** Number of real, non-meta user turns in this page. */
  userTurnCount: number;
}

function invalidClaudeHistoryCursor(): Error {
  return new Error("Invalid Claude history cursor");
}

function encodeClaudeHistoryCursor(
  payload: ClaudeHistoryCursorPayload,
): string {
  return Buffer.from(JSON.stringify(payload), "utf8").toString("base64url");
}

function decodeClaudeHistoryCursor(cursor: string): ClaudeHistoryCursorPayload {
  if (
    cursor.length === 0 ||
    cursor.length > CLAUDE_HISTORY_CURSOR_MAX_LENGTH ||
    !/^[A-Za-z0-9_-]+$/.test(cursor)
  ) {
    throw invalidClaudeHistoryCursor();
  }

  let parsed: unknown;
  try {
    const decoded = Buffer.from(cursor, "base64url");
    if (decoded.toString("base64url") !== cursor) {
      throw invalidClaudeHistoryCursor();
    }
    parsed = JSON.parse(decoded.toString("utf8")) as unknown;
  } catch {
    throw invalidClaudeHistoryCursor();
  }

  const payload = asObject(parsed);
  if (!payload) throw invalidClaudeHistoryCursor();
  const keys = Object.keys(payload).sort().join(",");
  if (keys !== "dev,endOffset,ino,skipTrailingPartial,snapshotSize,v") {
    throw invalidClaudeHistoryCursor();
  }

  const snapshotSize = payload.snapshotSize;
  const endOffset = payload.endOffset;
  if (
    payload.v !== CLAUDE_HISTORY_CURSOR_VERSION ||
    typeof payload.dev !== "string" ||
    !/^\d+$/.test(payload.dev) ||
    typeof payload.ino !== "string" ||
    !/^\d+$/.test(payload.ino) ||
    typeof snapshotSize !== "number" ||
    !Number.isSafeInteger(snapshotSize) ||
    snapshotSize < 0 ||
    typeof endOffset !== "number" ||
    !Number.isSafeInteger(endOffset) ||
    endOffset < 0 ||
    endOffset > snapshotSize ||
    typeof payload.skipTrailingPartial !== "boolean"
  ) {
    throw invalidClaudeHistoryCursor();
  }

  return {
    v: CLAUDE_HISTORY_CURSOR_VERSION,
    dev: payload.dev,
    ino: payload.ino,
    snapshotSize,
    endOffset,
    skipTrailingPartial: payload.skipTrailingPartial,
  };
}

function positiveSafeInteger(
  value: number | undefined,
  fallback: number,
  label: string,
): number {
  const resolved = value ?? fallback;
  if (!Number.isSafeInteger(resolved) || resolved <= 0) {
    throw new Error(`${label} must be a positive safe integer`);
  }
  return resolved;
}

/**
 * Read a display-ready Claude history window from the tail of one JSONL file.
 *
 * The cursor is an exclusive byte position moving toward older records. It is
 * bound to an append-only file snapshot: later appends are allowed, while a
 * different file or a truncation invalidates the cursor. A line larger than a
 * page's byte budget is deliberately skipped across advancing cursors instead
 * of being accumulated without bound.
 */
export async function readClaudeJsonlHistoryWindow(
  jsonlPath: string,
  options: ClaudeJsonlHistoryWindowOptions = {},
): Promise<ClaudeJsonlHistoryWindow> {
  const maxUserTurns = positiveSafeInteger(
    options.maxUserTurns,
    CLAUDE_HISTORY_WINDOW_DEFAULT_USER_TURNS,
    "maxUserTurns",
  );
  const maxBytes = positiveSafeInteger(
    options.maxBytes,
    CLAUDE_HISTORY_WINDOW_DEFAULT_MAX_BYTES,
    "maxBytes",
  );

  const handle = await open(jsonlPath, "r");
  try {
    const initialStat = await handle.stat();
    if (!initialStat.isFile() || !Number.isSafeInteger(initialStat.size)) {
      throw new Error("Claude history source must be a regular sized file");
    }

    const dev = String(initialStat.dev);
    const ino = String(initialStat.ino);
    const suppliedCursor =
      options.cursor === undefined
        ? null
        : decodeClaudeHistoryCursor(options.cursor);
    if (
      suppliedCursor &&
      (suppliedCursor.dev !== dev ||
        suppliedCursor.ino !== ino ||
        initialStat.size < suppliedCursor.snapshotSize)
    ) {
      throw invalidClaudeHistoryCursor();
    }

    const snapshotSize = suppliedCursor?.snapshotSize ?? initialStat.size;
    let position = suppliedCursor?.endOffset ?? snapshotSize;
    const pageEndOffset = position;
    let skipTrailingPartial = suppliedCursor?.skipTrailingPartial ?? false;
    let bytesRead = 0;
    let userTurnCount = 0;
    let stoppedAtOffset: number | null = null;
    const newestFirst: SessionHistoryMessage[] = [];
    let pendingParts: Buffer[] = [];
    let pendingBytes = 0;
    let pendingLineEndOffset = position;

    const clearPending = (): void => {
      pendingParts = [];
      pendingBytes = 0;
    };
    const prependPending = (part: Buffer): void => {
      if (part.length === 0) return;
      pendingParts.unshift(part);
      pendingBytes += part.length;
    };
    const consumeLine = (prefix: Buffer, lineStart: number): boolean => {
      const byteLength = prefix.length + pendingBytes;
      const line =
        pendingParts.length === 0
          ? prefix.toString("utf8")
          : Buffer.concat([prefix, ...pendingParts], byteLength).toString(
              "utf8",
            );
      clearPending();
      const parsed = parseClaudeHistoryLine(line);
      if (!parsed) return false;
      newestFirst.push(parsed.message);
      if (!parsed.isRealUserTurn) return false;
      userTurnCount += 1;
      if (userTurnCount < maxUserTurns) return false;
      stoppedAtOffset = lineStart;
      return true;
    };

    while (position > 0 && bytesRead < maxBytes && stoppedAtOffset === null) {
      const readLength = Math.min(
        CLAUDE_HISTORY_WINDOW_READ_CHUNK_BYTES,
        maxBytes - bytesRead,
        position,
      );
      const readStart = position - readLength;
      const chunk = Buffer.allocUnsafe(readLength);
      let filled = 0;
      while (filled < readLength) {
        const result = await handle.read(
          chunk,
          filled,
          readLength - filled,
          readStart + filled,
        );
        if (result.bytesRead === 0) {
          throw new Error("Claude history file changed while reading");
        }
        filled += result.bytesRead;
        bytesRead += result.bytesRead;
      }
      position = readStart;

      let right = chunk.length;
      if (skipTrailingPartial) {
        const delimiter = chunk.lastIndexOf(0x0a, right - 1);
        if (delimiter < 0) {
          continue;
        }
        skipTrailingPartial = false;
        clearPending();
        pendingLineEndOffset = readStart + delimiter;
        right = delimiter;
      }

      while (right > 0) {
        const delimiter = chunk.lastIndexOf(0x0a, right - 1);
        if (delimiter < 0) {
          prependPending(chunk.subarray(0, right));
          break;
        }
        const lineStart = readStart + delimiter + 1;
        if (consumeLine(chunk.subarray(delimiter + 1, right), lineStart)) {
          break;
        }
        pendingLineEndOffset = lineStart - 1;
        right = delimiter;
      }
    }

    if (
      position === 0 &&
      stoppedAtOffset === null &&
      !skipTrailingPartial &&
      pendingBytes > 0
    ) {
      consumeLine(Buffer.alloc(0), 0);
    }

    const finalStat = await handle.stat();
    if (
      String(finalStat.dev) !== dev ||
      String(finalStat.ino) !== ino ||
      finalStat.size < snapshotSize
    ) {
      throw new Error("Claude history file changed while reading");
    }

    const retryCompleteLine =
      stoppedAtOffset === null &&
      position > 0 &&
      pendingBytes > 0 &&
      pendingLineEndOffset < pageEndOffset;
    const nextEndOffset =
      stoppedAtOffset ?? (retryCompleteLine ? pendingLineEndOffset : position);
    const hasMore = nextEndOffset > 0;
    const nextCursor = hasMore
      ? encodeClaudeHistoryCursor({
          v: CLAUDE_HISTORY_CURSOR_VERSION,
          dev,
          ino,
          snapshotSize,
          endOffset: nextEndOffset,
          skipTrailingPartial:
            stoppedAtOffset === null &&
            !retryCompleteLine &&
            (skipTrailingPartial || pendingBytes > 0),
        })
      : null;

    return {
      messages: newestFirst.reverse(),
      nextCursor,
      hasMore,
      bytesRead,
      userTurnCount,
    };
  } finally {
    await handle.close();
  }
}

/** Resolve one durable Claude session and read only its bounded history page. */
export async function readClaudeSessionHistoryWindow(
  sessionId: string,
  options: ClaudeJsonlHistoryWindowOptions = {},
): Promise<ClaudeJsonlHistoryWindow> {
  const jsonlPath = await findSessionJsonlPath(sessionId);
  if (!jsonlPath) {
    return {
      messages: [],
      nextCursor: null,
      hasMore: false,
      bytesRead: 0,
      userTurnCount: 0,
    };
  }
  return readClaudeJsonlHistoryWindow(jsonlPath, options);
}

// ---- Extract full image data from JSONL for a specific message ----

export interface ExtractedImage {
  base64: string;
  mimeType: string;
}

interface CodexMessageImageIndex {
  jsonlPath: string;
  size: number;
  mtimeMs: number;
  imagesByUuid: Map<string, ExtractedImage[]>;
  imageBytes: number;
}

async function* streamJsonlLines(
  filePath: string,
  endExclusive?: number,
): AsyncGenerator<{ line: string; index: number }> {
  if (endExclusive !== undefined && endExclusive <= 0) return;
  const stream = createReadStream(filePath, {
    encoding: "utf-8",
    ...(endExclusive !== undefined ? { end: endExclusive - 1 } : {}),
  });
  const lines = createInterface({ input: stream, crlfDelay: Infinity });
  let index = 0;
  try {
    for await (const line of lines) {
      yield { line, index };
      index += 1;
    }
  } finally {
    lines.close();
    stream.destroy();
  }
}

const CODEX_IMAGE_INDEX_CACHE_LIMIT = 8;
const CODEX_IMAGE_INDEX_CACHE_MAX_BYTES = 32 * 1024 * 1024;
const codexMessageImageIndexCache = new Map<
  string,
  Promise<CodexMessageImageIndex | null>
>();
const codexMessageImageIndexCacheBytes = new Map<string, number>();

interface ClaudeMessageImageIndex {
  jsonlPath: string;
  size: number;
  mtimeMs: number;
  imagesByUuid: Map<string, ExtractedImage[]>;
  imageBytes: number;
}

const CLAUDE_IMAGE_INDEX_CACHE_LIMIT = 8;
const CLAUDE_IMAGE_INDEX_CACHE_MAX_BYTES = 32 * 1024 * 1024;
const claudeMessageImageIndexCache = new Map<
  string,
  Promise<ClaudeMessageImageIndex | null>
>();
const claudeMessageImageIndexCacheBytes = new Map<string, number>();

/**
 * Extract image base64 data from a Claude Code session JSONL for a specific message UUID.
 */
export async function extractMessageImages(
  sessionId: string,
  messageUuid: string,
): Promise<ExtractedImage[]> {
  if (isCodexMessageImageUuid(messageUuid)) {
    return extractCodexMessageImages(sessionId, messageUuid);
  }

  // A Claude session file is authoritative even when this message has no image.
  // Falling through would scan all Codex rollouts once per Claude user message.
  const claudeIndex = await getClaudeMessageImageIndex(sessionId);
  if (claudeIndex) {
    return claudeIndex.imagesByUuid.get(messageUuid) ?? [];
  }

  return extractCodexMessageImages(sessionId, messageUuid);
}

async function getClaudeMessageImageIndex(
  sessionId: string,
): Promise<ClaudeMessageImageIndex | null> {
  const cached = claudeMessageImageIndexCache.get(sessionId);
  if (cached) {
    const index = await cached;
    if (index && (await isFreshClaudeMessageImageIndex(index))) {
      claudeMessageImageIndexCache.delete(sessionId);
      claudeMessageImageIndexCache.set(sessionId, cached);
      return index;
    }
    deleteClaudeMessageImageIndexCacheEntry(sessionId);
  }

  const promise = buildClaudeMessageImageIndex(sessionId);
  claudeMessageImageIndexCache.set(sessionId, promise);
  trimClaudeMessageImageIndexCache();
  void promise.then(
    (index) => {
      if (claudeMessageImageIndexCache.get(sessionId) !== promise || !index) {
        return;
      }
      if (index.imageBytes > CLAUDE_IMAGE_INDEX_CACHE_MAX_BYTES) {
        deleteClaudeMessageImageIndexCacheEntry(sessionId);
        return;
      }
      claudeMessageImageIndexCacheBytes.set(sessionId, index.imageBytes);
      trimClaudeMessageImageIndexCache();
    },
    () => {
      if (claudeMessageImageIndexCache.get(sessionId) === promise) {
        deleteClaudeMessageImageIndexCacheEntry(sessionId);
      }
    },
  );
  return promise;
}

async function isFreshClaudeMessageImageIndex(
  index: ClaudeMessageImageIndex,
): Promise<boolean> {
  try {
    const current = await stat(index.jsonlPath);
    return current.size === index.size && current.mtimeMs === index.mtimeMs;
  } catch {
    return false;
  }
}

function deleteClaudeMessageImageIndexCacheEntry(sessionId: string): void {
  claudeMessageImageIndexCache.delete(sessionId);
  claudeMessageImageIndexCacheBytes.delete(sessionId);
}

function trimClaudeMessageImageIndexCache(): void {
  while (claudeMessageImageIndexCache.size > CLAUDE_IMAGE_INDEX_CACHE_LIMIT) {
    const oldest = claudeMessageImageIndexCache.keys().next().value;
    if (!oldest) return;
    deleteClaudeMessageImageIndexCacheEntry(oldest);
  }
  let totalBytes = 0;
  for (const bytes of claudeMessageImageIndexCacheBytes.values()) {
    totalBytes += bytes;
  }
  while (totalBytes > CLAUDE_IMAGE_INDEX_CACHE_MAX_BYTES) {
    const oldest = claudeMessageImageIndexCache.keys().next().value;
    if (!oldest) return;
    totalBytes -= claudeMessageImageIndexCacheBytes.get(oldest) ?? 0;
    deleteClaudeMessageImageIndexCacheEntry(oldest);
  }
}

async function buildClaudeMessageImageIndex(
  sessionId: string,
): Promise<ClaudeMessageImageIndex | null> {
  const jsonlPath = await findSessionJsonlPath(sessionId);
  if (!jsonlPath) return null;

  let fileStat;
  try {
    fileStat = await stat(jsonlPath);
  } catch {
    return null;
  }

  const imagesByUuid = new Map<string, ExtractedImage[]>();
  let imageBytes = 0;
  try {
    for await (const { line } of streamJsonlLines(jsonlPath, fileStat.size)) {
      if (!line.trim()) continue;

      let entry: Record<string, unknown>;
      try {
        entry = JSON.parse(line) as Record<string, unknown>;
      } catch {
        continue;
      }

      if (entry.type !== "user") continue;
      if (typeof entry.uuid !== "string") continue;

      const message = entry.message as
        { content: unknown[] | string } | undefined;
      if (!message?.content || !Array.isArray(message.content)) continue;

      const images: ExtractedImage[] = [];
      for (const c of message.content) {
        if (typeof c !== "object" || c === null) continue;
        const item = c as Record<string, unknown>;
        if (item.type !== "image") continue;

        const source = item.source as Record<string, unknown> | undefined;
        if (!source || source.type !== "base64") continue;

        const data = source.data;
        const mediaType = source.media_type;
        if (
          typeof data === "string" &&
          data.length > 0 &&
          typeof mediaType === "string" &&
          mediaType.length > 0
        ) {
          images.push({ base64: data, mimeType: mediaType });
          imageBytes += Buffer.byteLength(data, "utf8");
        }
      }
      if (images.length > 0) {
        imagesByUuid.set(entry.uuid, images);
      }
    }
  } catch {
    return null;
  }

  return {
    jsonlPath,
    size: fileStat.size,
    mtimeMs: fileStat.mtimeMs,
    imagesByUuid,
    imageBytes,
  };
}

async function extractCodexMessageImages(
  sessionId: string,
  messageUuid: string,
): Promise<ExtractedImage[]> {
  const index = await getCodexMessageImageIndex(sessionId);
  return index?.imagesByUuid.get(messageUuid) ?? [];
}

function isCodexMessageImageUuid(messageUuid: string): boolean {
  return (
    messageUuid.startsWith("codex:user-turn:") ||
    messageUuid.startsWith("codex-line-")
  );
}

async function getCodexMessageImageIndex(
  threadId: string,
): Promise<CodexMessageImageIndex | null> {
  const cached = codexMessageImageIndexCache.get(threadId);
  if (cached) {
    const index = await cached;
    if (index && (await isFreshCodexMessageImageIndex(index))) {
      codexMessageImageIndexCache.delete(threadId);
      codexMessageImageIndexCache.set(threadId, cached);
      return index;
    }
    deleteCodexMessageImageIndexCacheEntry(threadId);
  }

  const promise = buildCodexMessageImageIndex(threadId);
  codexMessageImageIndexCache.set(threadId, promise);
  trimCodexMessageImageIndexCache();
  void promise.then(
    (index) => {
      if (codexMessageImageIndexCache.get(threadId) !== promise || !index) {
        return;
      }
      if (index.imageBytes > CODEX_IMAGE_INDEX_CACHE_MAX_BYTES) {
        deleteCodexMessageImageIndexCacheEntry(threadId);
        return;
      }
      codexMessageImageIndexCacheBytes.set(threadId, index.imageBytes);
      trimCodexMessageImageIndexCache();
    },
    () => {
      if (codexMessageImageIndexCache.get(threadId) === promise) {
        deleteCodexMessageImageIndexCacheEntry(threadId);
      }
    },
  );
  return promise;
}

async function isFreshCodexMessageImageIndex(
  index: CodexMessageImageIndex,
): Promise<boolean> {
  try {
    const current = await stat(index.jsonlPath);
    return current.size === index.size && current.mtimeMs === index.mtimeMs;
  } catch {
    return false;
  }
}

function deleteCodexMessageImageIndexCacheEntry(threadId: string): void {
  codexMessageImageIndexCache.delete(threadId);
  codexMessageImageIndexCacheBytes.delete(threadId);
}

function trimCodexMessageImageIndexCache(): void {
  while (codexMessageImageIndexCache.size > CODEX_IMAGE_INDEX_CACHE_LIMIT) {
    const oldest = codexMessageImageIndexCache.keys().next().value;
    if (!oldest) return;
    deleteCodexMessageImageIndexCacheEntry(oldest);
  }
  let totalBytes = 0;
  for (const bytes of codexMessageImageIndexCacheBytes.values()) {
    totalBytes += bytes;
  }
  while (totalBytes > CODEX_IMAGE_INDEX_CACHE_MAX_BYTES) {
    const oldest = codexMessageImageIndexCache.keys().next().value;
    if (!oldest) return;
    totalBytes -= codexMessageImageIndexCacheBytes.get(oldest) ?? 0;
    deleteCodexMessageImageIndexCacheEntry(oldest);
  }
}

async function buildCodexMessageImageIndex(
  threadId: string,
): Promise<CodexMessageImageIndex | null> {
  const jsonlPath = await findCodexSessionJsonlPath(threadId);
  if (!jsonlPath) return null;

  let fileStat;
  try {
    fileStat = await stat(jsonlPath);
  } catch {
    return null;
  }

  let imageIndex: {
    imagesByUuid: Map<string, ExtractedImage[]>;
    imageBytes: number;
  };
  try {
    imageIndex = await collectCodexMessageImages(jsonlPath, fileStat.size);
  } catch {
    return null;
  }
  return {
    jsonlPath,
    size: fileStat.size,
    mtimeMs: fileStat.mtimeMs,
    imagesByUuid: imageIndex.imagesByUuid,
    imageBytes: imageIndex.imageBytes,
  };
}

async function collectCodexMessageImages(
  jsonlPath: string,
  snapshotSize: number,
): Promise<{
  imagesByUuid: Map<string, ExtractedImage[]>;
  imageBytes: number;
}> {
  const imagesByUuid = new Map<string, ExtractedImage[]>();
  const responseItemImagesByOrdinal = new Map<number, ExtractedImage[]>();
  const eventMessageImagesByOrdinal = new Map<number, ExtractedImage[]>();
  let responseOrdinal = 0;
  let eventOrdinal = 0;

  for await (const { line, index: lineIndex } of streamJsonlLines(
    jsonlPath,
    snapshotSize,
  )) {
    if (!line.trim()) continue;

    let entry: Record<string, unknown>;
    try {
      entry = JSON.parse(line) as Record<string, unknown>;
    } catch {
      continue;
    }

    const payload = asObject(entry.payload);
    if (!payload) continue;

    if (
      entry.type === "response_item" &&
      payload.type === "message" &&
      payload.role === "user" &&
      codexUserResponseItemHasDisplayContent(payload)
    ) {
      responseOrdinal += 1;
      const images = extractCodexUserResponseItemImages(payload);
      if (images.length > 0) {
        responseItemImagesByOrdinal.set(responseOrdinal, images);
      }
      continue;
    }

    if (entry.type !== "event_msg" || payload.type !== "user_message") {
      continue;
    }

    const lineImages = await extractCodexUserMessagePayloadImages(payload);
    imagesByUuid.set(`codex-line-${lineIndex}`, lineImages);

    if (!codexUserMessagePayloadHasDisplayContent(payload)) continue;
    eventOrdinal += 1;
    eventMessageImagesByOrdinal.set(eventOrdinal, lineImages);
  }

  for (const [ordinal, lineImages] of eventMessageImagesByOrdinal) {
    imagesByUuid.set(
      `codex:user-turn:${ordinal}`,
      lineImages.length > 0
        ? lineImages
        : (responseItemImagesByOrdinal.get(ordinal) ?? []),
    );
  }

  let imageBytes = 0;
  const counted = new Set<ExtractedImage[]>();
  for (const images of imagesByUuid.values()) {
    if (counted.has(images)) continue;
    counted.add(images);
    for (const image of images) {
      imageBytes += Buffer.byteLength(image.base64, "utf8");
    }
  }
  return { imagesByUuid, imageBytes };
}

async function extractCodexUserMessagePayloadImages(
  payload: Record<string, unknown>,
): Promise<ExtractedImage[]> {
  const images: ExtractedImage[] = [];
  if (Array.isArray(payload.images)) {
    for (const img of payload.images) {
      if (typeof img === "string") {
        const match = img.match(/^data:(image\/[^;]+);base64,(.+)$/);
        if (match) {
          images.push({ base64: match[2], mimeType: match[1] });
        }
        continue;
      }
      const item = asObject(img);
      if (!item) continue;
      const base64 =
        typeof item.base64 === "string"
          ? item.base64
          : typeof item.data === "string"
            ? item.data
            : undefined;
      const mimeType =
        typeof item.mimeType === "string"
          ? item.mimeType
          : typeof item.mime_type === "string"
            ? item.mime_type
            : typeof item.media_type === "string"
              ? item.media_type
              : undefined;
      if (base64 && mimeType) {
        images.push({ base64, mimeType });
      }
    }
  }
  if (Array.isArray(payload.local_images)) {
    for (const imagePath of payload.local_images) {
      if (typeof imagePath !== "string" || imagePath.length === 0) continue;
      const image = await readLocalImageAsBase64(imagePath);
      if (image) images.push(image);
    }
  }
  return images;
}

function codexUserResponseItemHasDisplayContent(
  payload: Record<string, unknown>,
): boolean {
  const texts: string[] = [];
  let hasImage = false;
  for (const item of arrayValue(payload.content)) {
    const content = asObject(item);
    if (!content) continue;
    if (content.type === "input_image") {
      hasImage = true;
      continue;
    }
    if (content.type !== "input_text" || typeof content.text !== "string") {
      continue;
    }
    texts.push(content.text);
  }
  const userText = texts
    .filter((text) => !isCodexImageWrapperText(text.trim()))
    .join("\n")
    .trim();
  if (userText && isCodexInjectedUserContext(userText)) return false;
  return userText.length > 0 || hasImage;
}

function extractCodexUserResponseItemImages(
  payload: Record<string, unknown>,
): ExtractedImage[] {
  const images: ExtractedImage[] = [];
  for (const item of arrayValue(payload.content)) {
    const content = asObject(item);
    if (!content || content.type !== "input_image") continue;
    const imageUrl =
      typeof content.image_url === "string"
        ? content.image_url
        : typeof content.url === "string"
          ? content.url
          : undefined;
    const image = extractDataUriImage(imageUrl);
    if (image) images.push(image);
  }
  return images;
}

function extractDataUriImage(value: string | undefined): ExtractedImage | null {
  const match = value?.match(/^data:(image\/[^;]+);base64,(.+)$/);
  return match ? { base64: match[2], mimeType: match[1] } : null;
}

function isCodexImageWrapperText(text: string): boolean {
  return /^<image(?:\s[^>]*)?>$/.test(text) || text === "</image>";
}

async function readLocalImageAsBase64(
  imagePath: string,
): Promise<ExtractedImage | null> {
  const mimeType = mimeTypeForLocalImagePath(imagePath);
  if (!mimeType) return null;
  try {
    const buffer = await readFile(imagePath);
    return { base64: buffer.toString("base64"), mimeType };
  } catch {
    return null;
  }
}

function mimeTypeForLocalImagePath(imagePath: string): string | null {
  switch (extname(imagePath).toLowerCase()) {
    case ".png":
      return "image/png";
    case ".jpg":
    case ".jpeg":
      return "image/jpeg";
    case ".gif":
      return "image/gif";
    case ".webp":
      return "image/webp";
    default:
      return null;
  }
}

function codexUserMessagePayloadHasDisplayContent(
  payload: Record<string, unknown>,
): boolean {
  const message = typeof payload.message === "string" ? payload.message : "";
  const images = Array.isArray(payload.images) ? payload.images.length : 0;
  const localImages = Array.isArray(payload.local_images)
    ? payload.local_images.length
    : 0;
  return message.trim().length > 0 || images + localImages > 0;
}

export async function getCodexSessionHistory(
  threadId: string,
): Promise<SessionHistoryMessage[]> {
  const jsonlPath = await findCodexSessionJsonlPath(threadId);
  if (!jsonlPath) return [];

  const messages: SessionHistoryMessage[] = [];
  const responseToolNames = new Map<string, string>();
  const responseToolImagePaths = new Map<string, string[]>();
  let userTurnOrdinal = 0;
  let activeHistoryTurnId: string | undefined;

  try {
    for await (const { line, index } of streamJsonlLines(jsonlPath)) {
      if (!line.trim()) continue;
      let entry: Record<string, unknown>;
      try {
        entry = JSON.parse(line) as Record<string, unknown>;
      } catch {
        continue;
      }

      const entryTimestamp = entry.timestamp as string | undefined;

      if (entry.type === "event_msg") {
        const payload = asObject(entry.payload);
        if (!payload) continue;

        if (payload.type === "task_started") {
          activeHistoryTurnId =
            stringValue(payload.turn_id) ?? stringValue(payload.turnId);
          continue;
        }
        if (payload.type === "task_complete") {
          const completedTurnId =
            stringValue(payload.turn_id) ?? stringValue(payload.turnId);
          if (!completedTurnId || completedTurnId === activeHistoryTurnId) {
            activeHistoryTurnId = undefined;
          }
          continue;
        }

        if (payload.type === "thread_rolled_back") {
          const rawNumTurns = payload.num_turns ?? payload.numTurns;
          const numTurns =
            typeof rawNumTurns === "number" ? rawNumTurns : Number(rawNumTurns);
          applyCodexThreadRollback(messages, numTurns);
          userTurnOrdinal = countCodexUserTurns(messages);
          continue;
        }

        if (payload.type === "user_message") {
          const rawMessage =
            typeof payload.message === "string" ? payload.message : "";
          const images = Array.isArray(payload.images)
            ? payload.images.length
            : 0;
          const localImages = Array.isArray(payload.local_images)
            ? payload.local_images.length
            : 0;
          const imageCount = images + localImages;

          const text =
            rawMessage.trim().length > 0
              ? rawMessage
              : imageCount > 0
                ? `[Image attached${imageCount > 1 ? ` x${imageCount}` : ""}]`
                : "";
          if (imageCount > 0) {
            // Push directly to include imageCount metadata
            const normalized = text.trim();
            if (normalized) {
              messages.push({
                role: "user",
                uuid: codexUserTurnUuid(++userTurnOrdinal),
                content: [{ type: "text", text }],
                ...(activeHistoryTurnId
                  ? { historyTurnId: activeHistoryTurnId }
                  : {}),
                imageCount,
                ...(entryTimestamp ? { timestamp: entryTimestamp } : {}),
              });
            }
          } else {
            if (
              appendTextMessage(
                messages,
                "user",
                text,
                entryTimestamp,
                codexUserTurnUuid(userTurnOrdinal + 1),
                activeHistoryTurnId,
              )
            ) {
              userTurnOrdinal += 1;
            }
          }
          continue;
        }

        if (
          payload.type === "agent_message" &&
          typeof payload.message === "string"
        ) {
          appendTextMessage(
            messages,
            "assistant",
            payload.message,
            entryTimestamp,
            undefined,
            activeHistoryTurnId,
          );
        }

        if (payload.type === "image_generation_end") {
          appendImageGenerationResult(
            messages,
            payload,
            `image-generation-${index}`,
            entryTimestamp,
            activeHistoryTurnId,
          );
        }

        if (payload.type === "mcp_tool_call_end") {
          const invocation = asObject(payload.invocation);
          const id =
            typeof payload.call_id === "string"
              ? payload.call_id
              : `mcp-result-${index}`;
          const server =
            typeof invocation?.server === "string" ? invocation.server : "mcp";
          const tool =
            typeof invocation?.tool === "string" ? invocation.tool : "tool";
          const normalized = normalizeCodexMcpResult(payload.result);
          appendToolResultMessage(
            messages,
            id,
            `mcp:${server}/${tool}`,
            normalized.content,
            {
              imageBase64: normalized.imageBase64,
              ...(entryTimestamp ? { timestamp: entryTimestamp } : {}),
              ...(activeHistoryTurnId
                ? { historyTurnId: activeHistoryTurnId }
                : {}),
            },
          );
        }
        continue;
      }

      if (entry.type === "response_item") {
        const payload = asObject(entry.payload);
        if (!payload) continue;
        const responseTurnId =
          stringValue(
            asObject(payload.internal_chat_message_metadata_passthrough)
              ?.turn_id,
          ) ?? activeHistoryTurnId;
        const scopedToolKey = (id: string) =>
          `${responseTurnId ?? "legacy"}\u0000${id}`;

        if (payload.type === "message") {
          const content = Array.isArray(payload.content)
            ? (payload.content as Array<Record<string, unknown>>)
            : [];

          if (payload.role === "assistant") {
            const text = content
              .filter(
                (item) =>
                  item.type === "output_text" && typeof item.text === "string",
              )
              .map((item) => item.text as string)
              .join("\n");
            appendTextMessage(
              messages,
              "assistant",
              text,
              entryTimestamp,
              undefined,
              responseTurnId,
            );
            continue;
          }

          if (payload.role === "user") {
            if (content.some((item) => item.type === "input_image")) {
              continue;
            }
            const text = content
              .filter(
                (item) =>
                  item.type === "input_text" && typeof item.text === "string",
              )
              .map((item) => item.text as string)
              .join("\n");
            if (!isCodexInjectedUserContext(text)) {
              if (
                appendTextMessage(
                  messages,
                  "user",
                  text,
                  entryTimestamp,
                  codexUserTurnUuid(userTurnOrdinal + 1),
                  responseTurnId,
                )
              ) {
                userTurnOrdinal += 1;
              }
            }
            continue;
          }
        }

        if (payload.type === "function_call") {
          const id =
            typeof payload.call_id === "string"
              ? payload.call_id
              : `tool-${index}`;
          const rawName =
            typeof payload.name === "string" ? payload.name : "tool";
          const descriptor = describeCodexDesktopToolCall(
            rawName,
            payload.arguments,
          );
          appendToolUseMessage(
            messages,
            id,
            descriptor.name,
            descriptor.input,
            responseTurnId,
          );
          responseToolNames.set(scopedToolKey(id), descriptor.name);
          const imagePaths = codexDesktopToolImagePaths(
            descriptor.name,
            descriptor.input,
          );
          if (imagePaths.length > 0) {
            responseToolImagePaths.set(scopedToolKey(id), imagePaths);
          }
          continue;
        }

        if (payload.type === "custom_tool_call") {
          const id =
            typeof payload.call_id === "string"
              ? payload.call_id
              : `tool-${index}`;
          const rawName =
            typeof payload.name === "string" ? payload.name : "custom_tool";
          const descriptor = describeCodexDesktopToolCall(
            rawName,
            payload.input,
          );
          appendToolUseMessage(
            messages,
            id,
            descriptor.name,
            descriptor.input,
            responseTurnId,
          );
          responseToolNames.set(scopedToolKey(id), descriptor.name);
          const imagePaths = codexDesktopToolImagePaths(
            descriptor.name,
            descriptor.input,
          );
          if (imagePaths.length > 0) {
            responseToolImagePaths.set(scopedToolKey(id), imagePaths);
          }
          continue;
        }

        if (
          payload.type === "function_call_output" ||
          payload.type === "custom_tool_call_output"
        ) {
          const id =
            typeof payload.call_id === "string"
              ? payload.call_id
              : `tool-result-${index}`;
          const toolName = responseToolNames.get(scopedToolKey(id));
          const imagePaths =
            responseToolImagePaths.get(scopedToolKey(id)) ?? [];
          const normalized = normalizeCodexDesktopToolOutput(payload.output);
          const imageBase64 =
            imagePaths.length > 0 ? [] : normalized.imageBase64;
          appendToolResultMessage(
            messages,
            id,
            toolName,
            normalized.content ||
              (imagePaths.length > 0 || imageBase64.length > 0
                ? toolName === "ViewImage"
                  ? "Viewed image"
                  : "Tool returned an image"
                : codexDesktopToolOutputText(payload.output)),
            {
              imagePaths,
              imageBase64,
              ...(entryTimestamp ? { timestamp: entryTimestamp } : {}),
              ...(responseTurnId ? { historyTurnId: responseTurnId } : {}),
            },
          );
          responseToolNames.delete(scopedToolKey(id));
          responseToolImagePaths.delete(scopedToolKey(id));
          continue;
        }

        if (payload.type === "web_search_call") {
          const id =
            typeof payload.call_id === "string"
              ? payload.call_id
              : `web-search-${index}`;
          appendToolUseMessage(
            messages,
            id,
            "WebSearch",
            getCodexSearchInput(payload),
            responseTurnId,
          );
          responseToolNames.set(scopedToolKey(id), "WebSearch");
          continue;
        }

        if (payload.type === "image_generation_call") {
          appendImageGenerationResult(
            messages,
            payload,
            `image-generation-${index}`,
            entryTimestamp,
            responseTurnId,
          );
          continue;
        }

        // Backward/forward compatibility with older/newer Codex JSONL schemas.
        if (payload.type === "command_execution") {
          const id =
            typeof payload.id === "string"
              ? payload.id
              : typeof payload.call_id === "string"
                ? payload.call_id
                : `cmd-${index}`;
          const descriptor = describeCodexHistoryCommand(payload);
          appendToolUseMessage(
            messages,
            id,
            descriptor.name,
            descriptor.input,
            responseTurnId,
          );
          continue;
        }

        if (payload.type === "mcp_tool_call") {
          const id =
            typeof payload.id === "string"
              ? payload.id
              : typeof payload.call_id === "string"
                ? payload.call_id
                : `mcp-${index}`;
          const server =
            typeof payload.server === "string" ? payload.server : "unknown";
          const tool = typeof payload.tool === "string" ? payload.tool : "tool";
          appendToolUseMessage(
            messages,
            id,
            `mcp:${server}/${tool}`,
            parseObjectLike(payload.arguments),
            responseTurnId,
          );
          continue;
        }

        if (payload.type === "file_change") {
          const id =
            typeof payload.id === "string"
              ? payload.id
              : typeof payload.call_id === "string"
                ? payload.call_id
                : `file-change-${index}`;
          const input = Array.isArray(payload.changes)
            ? { changes: payload.changes as unknown[] }
            : parseObjectLike(payload.changes);
          appendToolUseMessage(
            messages,
            id,
            "FileChange",
            input,
            responseTurnId,
          );
          continue;
        }

        if (payload.type === "web_search") {
          const id =
            typeof payload.id === "string"
              ? payload.id
              : typeof payload.call_id === "string"
                ? payload.call_id
                : `web-search-${index}`;
          const input =
            typeof payload.query === "string"
              ? { query: payload.query }
              : getCodexSearchInput(payload);
          appendToolUseMessage(
            messages,
            id,
            "WebSearch",
            input,
            responseTurnId,
          );
          continue;
        }

        if (
          payload.type === "collab_agent_tool_call" ||
          payload.type === "collab_tool_call"
        ) {
          const id =
            typeof payload.id === "string" ? payload.id : `collab-${index}`;
          const tool =
            typeof payload.tool === "string" ? payload.tool : "subagent";
          appendToolUseMessage(
            messages,
            id,
            codexCollabHistoryToolName(tool),
            parseObjectLike(payload),
            responseTurnId,
          );
          continue;
        }

        if (payload.type === "context_compaction") {
          appendToolUseMessage(
            messages,
            typeof payload.id === "string" ? payload.id : `compact-${index}`,
            "ContextCompaction",
            { description: "Compact the conversation context" },
            responseTurnId,
          );
          continue;
        }

        if (payload.type === "image_view") {
          const id =
            typeof payload.id === "string" ? payload.id : `image-view-${index}`;
          const path =
            typeof payload.path === "string" ? payload.path : undefined;
          appendToolUseMessage(
            messages,
            id,
            "ViewImage",
            path ? { path } : {},
            responseTurnId,
          );
          appendToolResultMessage(
            messages,
            id,
            "ViewImage",
            path ? `Viewed image: ${path}` : "Image viewed",
            {
              ...(path ? { imagePaths: [path] } : {}),
              ...(entryTimestamp ? { timestamp: entryTimestamp } : {}),
              ...(responseTurnId ? { historyTurnId: responseTurnId } : {}),
            },
          );
          continue;
        }

        if (payload.type === "sleep") {
          appendToolUseMessage(
            messages,
            typeof payload.id === "string" ? payload.id : `wait-${index}`,
            "Wait",
            parseObjectLike(payload),
            responseTurnId,
          );
        }
      }
    }
  } catch {
    return [];
  }

  assignStableCodexAssistantUuids(messages, threadId);
  for (const message of messages) {
    if (message.timestamp) message.timestampIsAuthoritative = true;
  }
  return messages;
}

/**
 * Look up session metadata for a set of Claude CLI sessionIds.
 * Returns a map from sessionId to a subset of session metadata.
 * More efficient than getAllRecentSessions when you only need a few entries.
 */
export async function findSessionsByClaudeIds(
  ids: Set<string>,
): Promise<
  Map<
    string,
    Pick<
      SessionIndexEntry,
      "summary" | "firstPrompt" | "lastPrompt" | "projectPath"
    >
  >
> {
  if (ids.size === 0) return new Map();

  const result = new Map<
    string,
    Pick<
      SessionIndexEntry,
      "summary" | "firstPrompt" | "lastPrompt" | "projectPath"
    >
  >();
  const remaining = new Set(ids);

  const projectsDir = join(homedir(), ".claude", "projects");
  let projectDirs: string[];
  try {
    projectDirs = await readdir(projectsDir);
  } catch {
    return result;
  }

  for (const dirName of projectDirs) {
    if (remaining.size === 0) break;
    if (dirName.startsWith(".")) continue;

    const indexPath = join(projectsDir, dirName, "sessions-index.json");
    let raw: string;
    try {
      raw = await readFile(indexPath, "utf-8");
    } catch {
      continue;
    }

    let index: { entries?: Array<Record<string, unknown>> };
    try {
      index = JSON.parse(raw) as { entries?: Array<Record<string, unknown>> };
    } catch {
      continue;
    }

    if (!Array.isArray(index.entries)) continue;

    for (const entry of index.entries) {
      const sid = entry.sessionId as string | undefined;
      if (!sid || !remaining.has(sid)) continue;

      result.set(sid, {
        summary: entry.summary as string | undefined,
        firstPrompt: (entry.firstPrompt as string) ?? "",
        lastPrompt: entry.lastPrompt as string | undefined,
        projectPath: normalizeWorktreePath((entry.projectPath as string) ?? ""),
      });
      remaining.delete(sid);
    }
  }

  return result;
}
