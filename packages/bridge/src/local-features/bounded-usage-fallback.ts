import { open, opendir } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import type { SessionUsageInfoPayload } from "./protocol.js";
import { parseCodexAccountRateLimits } from "./account-usage.js";

const DEFAULT_MAX_DAYS = 7;
const DEFAULT_MAX_DIRECTORY_ENTRIES = 512;
const DEFAULT_MAX_FILES = 24;
const DEFAULT_TAIL_BYTES = 512 * 1024;
const DEFAULT_READ_CHUNK_BYTES = 64 * 1024;
const DEFAULT_DEADLINE_MS = 2_000;

// Defaults are also hard ceilings. Callers may tighten a scan for tests or a
// constrained runtime, but cannot turn this compatibility fallback back into
// the unbounded whole-rollout scan it replaces.
const HARD_MAX_DAYS = DEFAULT_MAX_DAYS;
const HARD_MAX_DIRECTORY_ENTRIES = DEFAULT_MAX_DIRECTORY_ENTRIES;
const HARD_MAX_FILES = DEFAULT_MAX_FILES;
const HARD_MAX_TAIL_BYTES = DEFAULT_TAIL_BYTES;
const HARD_MAX_READ_CHUNK_BYTES = DEFAULT_READ_CHUNK_BYTES;
const HARD_MAX_DEADLINE_MS = DEFAULT_DEADLINE_MS;

export interface BoundedUsageFallbackOptions {
  sessionsDir?: string;
  now?: Date;
  maxDays?: number;
  maxDirectoryEntries?: number;
  maxFiles?: number;
  tailBytes?: number;
  readChunkBytes?: number;
  deadlineMs?: number;
}

/**
 * Read only bounded tails of recent Codex rollouts.
 *
 * This is intentionally feature-local. The regular account RPC remains the
 * preferred source, while older app-servers get a finite compatibility path
 * without changing the upstream usage scanner or loading whole JSONL files.
 */
export async function fetchBoundedCodexUsageFallback(
  options: BoundedUsageFallbackOptions = {},
): Promise<SessionUsageInfoPayload[]> {
  const sessionsDir =
    options.sessionsDir ?? join(homedir(), ".codex", "sessions");
  const maxDays = boundedPositiveInteger(
    options.maxDays,
    DEFAULT_MAX_DAYS,
    HARD_MAX_DAYS,
  );
  const maxDirectoryEntries = boundedPositiveInteger(
    options.maxDirectoryEntries,
    DEFAULT_MAX_DIRECTORY_ENTRIES,
    HARD_MAX_DIRECTORY_ENTRIES,
  );
  const maxFiles = boundedPositiveInteger(
    options.maxFiles,
    DEFAULT_MAX_FILES,
    HARD_MAX_FILES,
  );
  const tailBytes = boundedPositiveInteger(
    options.tailBytes,
    DEFAULT_TAIL_BYTES,
    HARD_MAX_TAIL_BYTES,
  );
  const readChunkBytes = boundedPositiveInteger(
    options.readChunkBytes,
    DEFAULT_READ_CHUNK_BYTES,
    HARD_MAX_READ_CHUNK_BYTES,
  );
  const deadlineMs = boundedPositiveInteger(
    options.deadlineMs,
    DEFAULT_DEADLINE_MS,
    HARD_MAX_DEADLINE_MS,
  );
  const deadlineAt = Date.now() + deadlineMs;
  const controller = new AbortController();

  try {
    return await guardDeadline(
      scanBoundedUsage({
        sessionsDir,
        now: options.now ?? new Date(),
        maxDays,
        maxDirectoryEntries,
        maxFiles,
        tailBytes,
        readChunkBytes,
        deadlineAt,
        signal: controller.signal,
      }),
      deadlineMs,
      controller,
    );
  } catch (error) {
    return [
      emptyUsage(error instanceof Error ? error.message : String(error)),
    ];
  }
}

async function scanBoundedUsage(options: {
  sessionsDir: string;
  now: Date;
  maxDays: number;
  maxDirectoryEntries: number;
  maxFiles: number;
  tailBytes: number;
  readChunkBytes: number;
  deadlineAt: number;
  signal: AbortSignal;
}): Promise<SessionUsageInfoPayload[]> {
  const candidates = await recentRolloutCandidates(options);
  for (const filePath of candidates) {
    ensureWithinDeadline(options.deadlineAt, options.signal);
    const rateLimits = await latestRateLimitsFromTail(
      filePath,
      options.tailBytes,
      options.readChunkBytes,
      options.deadlineAt,
      options.signal,
    );
    if (!rateLimits) continue;
    return [
      {
        ...parseCodexAccountRateLimits({ rateLimits }),
        source: "session_log",
        resetCredits: undefined,
      },
    ];
  }
  return [emptyUsage("No rate limit data found in bounded rollout tails")];
}

async function recentRolloutCandidates(options: {
  sessionsDir: string;
  now: Date;
  maxDays: number;
  maxDirectoryEntries: number;
  maxFiles: number;
  deadlineAt: number;
  signal: AbortSignal;
}): Promise<string[]> {
  const candidates: string[] = [];
  let visitedEntries = 0;

  for (let dayOffset = 0; dayOffset < options.maxDays; dayOffset += 1) {
    ensureWithinDeadline(options.deadlineAt, options.signal);
    const day = new Date(options.now);
    day.setHours(12, 0, 0, 0);
    day.setDate(day.getDate() - dayOffset);
    const dayDir = join(
      options.sessionsDir,
      String(day.getFullYear()),
      String(day.getMonth() + 1).padStart(2, "0"),
      String(day.getDate()).padStart(2, "0"),
    );

    let directory;
    try {
      directory = await opendir(dayDir);
    } catch {
      continue;
    }
    try {
      ensureWithinDeadline(options.deadlineAt, options.signal);
      while (visitedEntries < options.maxDirectoryEntries) {
        const entry = await directory.read();
        ensureWithinDeadline(options.deadlineAt, options.signal);
        if (!entry) break;
        visitedEntries += 1;
        if (
          !entry.isFile() ||
          !entry.name.startsWith("rollout-") ||
          !entry.name.endsWith(".jsonl")
        ) {
          continue;
        }
        insertNewestCandidate(
          candidates,
          join(dayDir, entry.name),
          options.maxFiles,
        );
      }
    } finally {
      await directory.close().catch(() => {});
    }
    if (visitedEntries >= options.maxDirectoryEntries) break;
  }

  return candidates;
}

async function latestRateLimitsFromTail(
  filePath: string,
  tailBytes: number,
  readChunkBytes: number,
  deadlineAt: number,
  signal: AbortSignal,
): Promise<Record<string, unknown> | null> {
  const file = await open(filePath, "r");
  try {
    ensureWithinDeadline(deadlineAt, signal);
    const stats = await file.stat();
    ensureWithinDeadline(deadlineAt, signal);
    if (!stats.isFile()) return null;
    const length = Math.min(stats.size, tailBytes);
    if (length <= 0) return null;
    const start = stats.size - length;
    const buffer = Buffer.alloc(length);
    let bytesRead = 0;
    while (bytesRead < length) {
      ensureWithinDeadline(deadlineAt, signal);
      const requestedBytes = Math.min(length - bytesRead, readChunkBytes);
      const result = await file.read(
        buffer,
        bytesRead,
        requestedBytes,
        start + bytesRead,
      );
      ensureWithinDeadline(deadlineAt, signal);
      if (result.bytesRead === 0) break;
      bytesRead += result.bytesRead;
    }
    if (bytesRead === 0) return null;

    let completeLines = buffer.subarray(0, bytesRead);
    if (start > 0 && completeLines[0] !== 0x7b) {
      // Search for LF in bytes before UTF-8 decoding. The tail can begin in a
      // multibyte code point or halfway through JSON, so decoding first can
      // introduce a replacement character into what looks like a valid line.
      // A leading "{" may be an exact JSONL boundary; keep it and let the
      // strict envelope checks reject it if it was actually nested JSON.
      const firstNewline = completeLines.indexOf(0x0a);
      completeLines =
        firstNewline < 0
          ? Buffer.alloc(0)
          : completeLines.subarray(firstNewline + 1);
    }
    const lines = completeLines.toString("utf8").split("\n");
    for (let index = lines.length - 1; index >= 0; index -= 1) {
      ensureWithinDeadline(deadlineAt, signal);
      const line = lines[index]?.trim();
      if (!line || !line.includes('"token_count"')) continue;
      try {
        const event = JSON.parse(line) as Record<string, unknown>;
        if (event.type !== "event_msg" || !isRecord(event.payload)) continue;
        if (event.payload.type !== "token_count") continue;
        const rateLimits =
          event.payload.rate_limits ?? event.payload.rateLimits;
        if (isRecord(rateLimits)) return rateLimits;
      } catch {
        // Ignore incomplete or unrelated JSONL records inside the bounded tail.
      }
    }
    return null;
  } finally {
    await file.close().catch(() => {});
  }
}

function insertNewestCandidate(
  candidates: string[],
  filePath: string,
  maxFiles: number,
): void {
  candidates.push(filePath);
  candidates.sort((left, right) => right.localeCompare(left));
  if (candidates.length > maxFiles) candidates.pop();
}

function emptyUsage(error: string): SessionUsageInfoPayload {
  return {
    provider: "codex",
    fiveHour: null,
    sevenDay: null,
    source: "session_log",
    error,
  };
}

function boundedPositiveInteger(
  value: number | undefined,
  fallback: number,
  hardMaximum: number,
): number {
  if (typeof value !== "number" || !Number.isFinite(value) || value <= 0) {
    return fallback;
  }
  return Math.max(1, Math.min(Math.floor(value), hardMaximum));
}

function ensureWithinDeadline(
  deadlineAt: number,
  signal: AbortSignal,
): void {
  if (signal.aborted || Date.now() >= deadlineAt) {
    throw new Error("Bounded rollout usage scan deadline exceeded");
  }
}

function guardDeadline<T>(
  operation: Promise<T>,
  deadlineMs: number,
  controller: AbortController,
): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => {
      controller.abort();
      reject(
        new Error(`Bounded rollout usage scan timed out after ${deadlineMs}ms`),
      );
    }, deadlineMs);
    timer.unref?.();
    operation.then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      (error) => {
        clearTimeout(timer);
        reject(error);
      },
    );
  });
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
