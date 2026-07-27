import type {
  ContextUsageMessage,
  CodexTokenUsageBreakdown,
} from "./protocol.js";
import { open, readdir } from "node:fs/promises";
import { join } from "node:path";
import { resolveCodexSessionsDir } from "../codex-home.js";
import type {
  LocalFeatureHandler,
  LocalFeatureHandleContext,
} from "./runtime.js";
import type { LocalFeatureClientMessage } from "./protocol.js";

const EMPTY_BREAKDOWN: CodexTokenUsageBreakdown = {
  totalTokens: 0,
  inputTokens: 0,
  cachedInputTokens: 0,
  cacheWriteInputTokens: 0,
  outputTokens: 0,
  reasoningOutputTokens: 0,
};

const EXPLICIT_CONTEXT_DEADLINE_MS = 2_500;

type ContextUsageLoader = (
  threadId: string,
  options: {
    signal: AbortSignal;
    scanDeadlineMs: number;
    maxDirectoryReads: number;
  },
) => Promise<ContextUsageMessage | null>;

export interface ContextFeatureHandlerOptions {
  load?: ContextUsageLoader;
  deadlineMs?: number;
  scanDeadlineMs?: number;
  maxDirectoryReads?: number;
}

export class ContextFeatureHandler implements LocalFeatureHandler {
  readonly messageTypes = ["get_context_usage"] as const;

  private readonly load: ContextUsageLoader;
  private readonly deadlineMs: number;
  private readonly scanDeadlineMs: number;
  private readonly maxDirectoryReads: number;

  constructor(options: ContextFeatureHandlerOptions = {}) {
    this.load = options.load ?? loadCodexContextUsageFromRollout;
    this.deadlineMs = Math.max(
      1,
      Math.min(options.deadlineMs ?? EXPLICIT_CONTEXT_DEADLINE_MS, 5_000),
    );
    this.scanDeadlineMs = Math.max(
      1,
      Math.min(options.scanDeadlineMs ?? 1_500, this.deadlineMs),
    );
    this.maxDirectoryReads = Math.max(
      1,
      Math.min(options.maxDirectoryReads ?? 256, 2_000),
    );
  }

  async handle(
    message: LocalFeatureClientMessage,
    context: LocalFeatureHandleContext,
  ): Promise<void> {
    if (message.type !== "get_context_usage") return;
    if (!context.runtime.supports(context.client, "context_usage")) {
      this.sendFailure(
        message.sessionId,
        context,
        "unsupported_capability",
        "Context usage capability was not negotiated",
      );
      return;
    }

    const session = context.runtime.getSession(message.sessionId);
    const threadId = session
      ? context.runtime.getCodexThreadId(session)
      : undefined;
    if (!session || session.provider !== "codex" || !threadId) {
      this.sendFailure(
        message.sessionId,
        context,
        "context_usage_session_not_found",
        `Session ${message.sessionId} not found`,
      );
      return;
    }

    try {
      const usage = await withTotalDeadline(
        (signal) =>
          this.load(threadId, {
            signal,
            scanDeadlineMs: this.scanDeadlineMs,
            maxDirectoryReads: this.maxDirectoryReads,
          }),
        context.signal,
        this.deadlineMs,
      );
      if (usage) {
        context.runtime.send(
          context.client,
          context.runtime.supports(context.client, "context_usage_result")
            ? {
                ...usage,
                type: "context_usage_result",
                sessionId: message.sessionId,
              }
            : { ...usage, sessionId: message.sessionId },
        );
      }
    } catch (error) {
      if (context.signal.aborted) return;
      this.sendFailure(
        message.sessionId,
        context,
        "context_usage_failed",
        error instanceof Error ? error.message : String(error),
      );
    }
  }

  private sendFailure(
    sessionId: string,
    context: LocalFeatureHandleContext,
    errorCode: string,
    message: string,
  ): void {
    context.runtime.send(
      context.client,
      context.runtime.supports(context.client, "context_usage_error")
        ? { type: "context_usage_error", sessionId, errorCode, message }
        : { type: "error", errorCode, message },
    );
  }
}

/**
 * Normalize both current app-server token notifications and the pre-v2 flat
 * `usage` payload. The result intentionally contains raw counts only; clients
 * decide how to present context occupancy.
 */
export function parseCodexContextUsageNotification(
  params: Record<string, unknown>,
): ContextUsageMessage | null {
  const current = asRecord(params.tokenUsage ?? params.token_usage);
  const legacy = asRecord(params.usage);
  const source = current ?? legacy;
  if (!source) return null;

  const last = parseBreakdown(current?.last ?? current?.last_usage ?? legacy);
  const total = parseBreakdown(
    current?.total ?? current?.total_usage ?? legacy,
  );
  if (!last || !total) return null;

  return {
    type: "context_usage",
    ...(typeof params.turnId === "string"
      ? { turnId: params.turnId }
      : typeof params.turn_id === "string"
        ? { turnId: params.turn_id }
        : {}),
    last,
    total,
    modelContextWindow: nonNegativeNumberOrNull(
      current?.modelContextWindow ??
        current?.model_context_window ??
        legacy?.modelContextWindow ??
        legacy?.model_context_window,
    ),
  };
}

export function parseCodexTokenCountEvent(
  event: unknown,
): ContextUsageMessage | null {
  const eventRecord = asRecord(event);
  if (eventRecord?.type !== "event_msg") return null;
  const payload = asRecord(eventRecord.payload);
  if (payload?.type !== "token_count") return null;

  // Current Codex rollout events wrap the token snapshot in `payload.info`.
  // Keep the flat fallback for older rollouts written before that envelope.
  const info = asRecord(payload.info) ?? payload;

  const last = parseBreakdown(info.last_token_usage ?? info.lastTokenUsage);
  const total = parseBreakdown(info.total_token_usage ?? info.totalTokenUsage);
  if (!last || !total) return null;
  return {
    type: "context_usage",
    last,
    total,
    modelContextWindow: nonNegativeNumberOrNull(
      info.model_context_window ?? info.modelContextWindow,
    ),
  };
}

/** Read only a bounded rollout tail so a resumed thread has context data. */
export async function loadCodexContextUsageFromRollout(
  threadId: string,
  options: {
    sessionsDir?: string;
    maxTailBytes?: number;
    scanDeadlineMs?: number;
    maxDirectoryReads?: number;
    signal?: AbortSignal;
  } = {},
): Promise<ContextUsageMessage | null> {
  const sessionsDir =
    options.sessionsDir ?? resolveCodexSessionsDir();
  const scanBudget = {
    deadlineAt:
      Date.now() + Math.max(50, Math.min(options.scanDeadlineMs ?? 1_500, 5_000)),
    remainingDirectories: Math.max(
      1,
      Math.min(options.maxDirectoryReads ?? 256, 2_000),
    ),
    signal: options.signal,
  };
  const rolloutPath = await findRolloutByThreadId(
    sessionsDir,
    threadId,
    scanBudget,
  );
  if (!rolloutPath) return null;

  let handle;
  try {
    handle = await open(rolloutPath, "r");
    const stats = await handle.stat();
    const maxTailBytes = Math.max(4096, options.maxTailBytes ?? 512 * 1024);
    const length = Math.min(stats.size, maxTailBytes);
    if (!stats.isFile()) return null;
    const buffer = Buffer.alloc(length);
    let bytesRead = 0;
    while (bytesRead < length) {
      const result = await handle.read(
        buffer,
        bytesRead,
        length - bytesRead,
        stats.size - length + bytesRead,
      );
      if (result.bytesRead === 0) break;
      bytesRead += result.bytesRead;
    }
    if (bytesRead === 0) return null;
    let text = buffer.subarray(0, bytesRead).toString("utf-8");
    if (length < stats.size) {
      const firstNewline = text.indexOf("\n");
      text = firstNewline >= 0 ? text.slice(firstNewline + 1) : "";
    }
    const lines = text.split("\n");
    for (let index = lines.length - 1; index >= 0; index -= 1) {
      const line = lines[index]?.trim();
      if (!line || !line.includes('"token_count"')) continue;
      try {
        const usage = parseCodexTokenCountEvent(JSON.parse(line));
        if (usage) return usage;
      } catch {
        // Ignore a malformed line and continue farther back in the bounded tail.
      }
    }
  } catch {
    return null;
  } finally {
    await handle?.close().catch(() => {});
  }
  return null;
}

async function findRolloutByThreadId(
  sessionsDir: string,
  threadId: string,
  budget: DirectoryScanBudget,
): Promise<string | null> {
  const suffix = `${threadId}.jsonl`;
  let years;
  try {
    years = await boundedReadDir(sessionsDir, budget);
  } catch {
    return null;
  }
  for (const year of numericDirectoriesDescending(years)) {
    if (scanExpired(budget)) return null;
    const yearPath = join(sessionsDir, year);
    const months = await boundedReadDir(yearPath, budget);
    for (const month of numericDirectoriesDescending(months)) {
      if (scanExpired(budget)) return null;
      const monthPath = join(yearPath, month);
      const days = await boundedReadDir(monthPath, budget);
      for (const day of numericDirectoriesDescending(days)) {
        if (scanExpired(budget)) return null;
        const dayPath = join(monthPath, day);
        const entries = await boundedReadDir(dayPath, budget);
        const match = entries.find(
          (entry) => entry.isFile() && entry.name.endsWith(suffix),
        );
        if (match) return join(dayPath, match.name);
      }
    }
  }
  return null;
}

interface DirectoryScanBudget {
  deadlineAt: number;
  remainingDirectories: number;
  signal?: AbortSignal;
}

async function boundedReadDir(path: string, budget: DirectoryScanBudget) {
  if (scanExpired(budget)) return [];
  budget.remainingDirectories -= 1;
  try {
    return await readdir(path, { withFileTypes: true });
  } catch {
    return [];
  }
}

function scanExpired(budget: DirectoryScanBudget): boolean {
  return (
    budget.signal?.aborted === true ||
    budget.remainingDirectories <= 0 ||
    Date.now() >= budget.deadlineAt
  );
}

function numericDirectoriesDescending(
  entries: Awaited<ReturnType<typeof boundedReadDir>>,
): string[] {
  return entries
    .filter(
      (entry) => entry.isDirectory() && /^\d+$/.test(entry.name),
    )
    .map((entry) => entry.name)
    .sort((left, right) => right.localeCompare(left));
}

function parseBreakdown(value: unknown): CodexTokenUsageBreakdown | null {
  const record = asRecord(value);
  if (!record) return null;
  const inputTokens = nonNegativeNumber(
    record.inputTokens ?? record.input_tokens,
  );
  const cachedInputTokens = nonNegativeNumber(
    record.cachedInputTokens ?? record.cached_input_tokens,
  );
  const cacheWriteInputTokens = nonNegativeNumber(
    record.cacheWriteInputTokens ?? record.cache_write_input_tokens,
  );
  const outputTokens = nonNegativeNumber(
    record.outputTokens ?? record.output_tokens,
  );
  const reasoningOutputTokens = nonNegativeNumber(
    record.reasoningOutputTokens ?? record.reasoning_output_tokens,
  );
  const explicitTotal = nonNegativeNumberOrUndefined(
    record.totalTokens ?? record.total_tokens,
  );

  const hasAnyKnownField =
    explicitTotal !== undefined ||
    [
      "inputTokens",
      "input_tokens",
      "cachedInputTokens",
      "cached_input_tokens",
      "cacheWriteInputTokens",
      "cache_write_input_tokens",
      "outputTokens",
      "output_tokens",
      "reasoningOutputTokens",
      "reasoning_output_tokens",
    ].some((key) => key in record);
  if (!hasAnyKnownField) return null;

  return {
    ...EMPTY_BREAKDOWN,
    totalTokens: explicitTotal ?? inputTokens + outputTokens,
    inputTokens,
    cachedInputTokens,
    cacheWriteInputTokens,
    outputTokens,
    reasoningOutputTokens,
  };
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object"
    ? (value as Record<string, unknown>)
    : null;
}

function nonNegativeNumber(value: unknown): number {
  return nonNegativeNumberOrUndefined(value) ?? 0;
}

function nonNegativeNumberOrUndefined(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) && value >= 0
    ? value
    : undefined;
}

function nonNegativeNumberOrNull(value: unknown): number | null {
  return nonNegativeNumberOrUndefined(value) ?? null;
}

function withTotalDeadline<T>(
  operation: (signal: AbortSignal) => Promise<T>,
  parentSignal: AbortSignal,
  timeoutMs: number,
): Promise<T> {
  const controller = new AbortController();
  const abortFromParent = (): void => controller.abort(parentSignal.reason);

  return new Promise<T>((resolve, reject) => {
    let settled = false;
    const timer = setTimeout(() => {
      const error = new Error(`Context usage timed out after ${timeoutMs}ms`);
      controller.abort(error);
    }, timeoutMs);
    const cleanup = (): void => {
      clearTimeout(timer);
      parentSignal.removeEventListener("abort", abortFromParent);
      controller.signal.removeEventListener("abort", rejectIfAborted);
    };
    const rejectIfAborted = (): void => {
      if (settled) return;
      settled = true;
      cleanup();
      const reason = controller.signal.reason;
      reject(reason instanceof Error ? reason : new Error("Request aborted"));
    };
    controller.signal.addEventListener("abort", rejectIfAborted, {
      once: true,
    });
    parentSignal.addEventListener("abort", abortFromParent, { once: true });
    if (parentSignal.aborted) abortFromParent();
    if (controller.signal.aborted) {
      rejectIfAborted();
      return;
    }

    operation(controller.signal).then(
      (value) => {
        if (settled) return;
        settled = true;
        cleanup();
        resolve(value);
      },
      (error) => {
        if (settled) return;
        settled = true;
        cleanup();
        reject(error);
      },
    );
  });
}
