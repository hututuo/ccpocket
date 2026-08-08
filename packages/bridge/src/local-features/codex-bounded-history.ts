import {
  CodexRpcError,
  type CodexProcess,
  type CodexRpcRequestOptions,
} from "../codex-process.js";

export type CodexBoundedHistoryPreference = "items" | "turns";

type CodexBoundedHistoryMode = "items" | "turns" | "turnsLegacy";

export interface CodexBoundedHistoryPage {
  thread: Record<string, unknown>;
  nextCursor: string | null;
  mode: CodexBoundedHistoryMode;
  recordCount: number;
}

export interface CodexBoundedHistoryReaderOptions {
  pageSize?: number;
  maxPages?: number;
  maxEntries?: number;
  rpcTimeoutMs?: number;
}

interface ReadPageOptions {
  cursor?: string | null;
  limit?: number;
  sortDirection?: "asc" | "desc";
  preference?: CodexBoundedHistoryPreference;
  signal?: AbortSignal;
}

const DEFAULT_PAGE_SIZE = 100;
const DEFAULT_MAX_ENTRIES = 100_000;
const DEFAULT_RPC_TIMEOUT_MS = 15_000;

/**
 * Shared adapter for Codex history pagination.
 *
 * The adapter negotiates only bounded provider RPCs. It deliberately has no
 * `thread/read(includeTurns: true)` fallback: callers must preserve their last
 * committed projection when both pagination families are unavailable.
 */
export class CodexBoundedHistoryReader {
  private readonly historyModeByProcess = new WeakMap<
    object,
    Map<string, CodexBoundedHistoryMode>
  >();
  private readonly pageSize: number;
  private readonly maxPages: number;
  private readonly maxEntries: number;
  private readonly rpcTimeoutMs: number;

  constructor(options: CodexBoundedHistoryReaderOptions = {}) {
    this.pageSize = positiveInteger(options.pageSize, DEFAULT_PAGE_SIZE);
    this.maxEntries = positiveInteger(
      options.maxEntries,
      DEFAULT_MAX_ENTRIES,
    );
    this.maxPages = positiveInteger(
      options.maxPages,
      Math.ceil(this.maxEntries / this.pageSize),
    );
    this.rpcTimeoutMs = positiveInteger(
      options.rpcTimeoutMs,
      DEFAULT_RPC_TIMEOUT_MS,
    );
  }

  async readPage(
    process: CodexProcess,
    threadId: string,
    options: ReadPageOptions = {},
  ): Promise<CodexBoundedHistoryPage> {
    const cursor = options.cursor ?? null;
    const preference = options.preference ?? "items";
    const modes = this.historyModes(process);
    let mode = modes.get(threadId) ?? preference;

    if (mode === "items") {
      try {
        const page = await this.readProviderPage(
          process,
          "thread/items/list",
          threadId,
          mode,
          options,
        );
        modes.set(threadId, mode);
        return page;
      } catch (error) {
        if (
          cursor !== null ||
          !isHistoryPaginationUnavailable(error, "thread/items/list")
        ) {
          throw error;
        }
        mode = "turns";
        modes.set(threadId, mode);
      }
    }

    if (mode === "turns" || mode === "turnsLegacy") {
      let turnsError: unknown;
      try {
        const page = await this.readProviderPage(
          process,
          "thread/turns/list",
          threadId,
          mode,
          options,
        );
        modes.set(threadId, mode);
        return page;
      } catch (error) {
        turnsError = error;
      }

      if (
        cursor === null &&
        mode === "turns" &&
        isTurnsItemsViewParameterUnavailable(turnsError)
      ) {
        mode = "turnsLegacy";
        modes.set(threadId, mode);
        try {
          return await this.readProviderPage(
            process,
            "thread/turns/list",
            threadId,
            mode,
            options,
          );
        } catch (error) {
          turnsError = error;
        }
      }

      if (
        cursor === null &&
        preference === "turns" &&
        (isHistoryPaginationUnavailable(
          turnsError,
          "thread/turns/list",
        ) ||
          isNonFullTurnsResponseError(turnsError))
      ) {
        mode = "items";
        modes.set(threadId, mode);
        return this.readProviderPage(
          process,
          "thread/items/list",
          threadId,
          mode,
          options,
        );
      }
      throw turnsError;
    }

    throw new Error(`Unsupported Codex bounded history mode: ${mode}`);
  }

  async readAll(
    process: CodexProcess,
    threadId: string,
    options: Omit<ReadPageOptions, "cursor" | "limit"> = {},
  ): Promise<Record<string, unknown>> {
    const pages: Record<string, unknown>[][] = [];
    const seenCursors = new Set<string>();
    let cursor: string | null = null;
    let entryCount = 0;

    for (let pageIndex = 0; pageIndex < this.maxPages; pageIndex += 1) {
      throwIfAborted(options.signal);
      const page = await this.readPage(process, threadId, {
        ...options,
        cursor,
        limit: this.pageSize,
        sortDirection: "desc",
      });
      const turns = threadTurns(page.thread);
      pages.push(turns);
      entryCount += page.recordCount;
      if (entryCount > this.maxEntries) {
        throw new Error(
          `Conversation exceeds ${this.maxEntries} bounded history records`,
        );
      }
      if (!page.nextCursor) {
        return {
          id: threadId,
          turns: mergeChronologicalTurns(pages.reverse().flat()),
        };
      }
      if (
        page.nextCursor === cursor ||
        seenCursors.has(page.nextCursor)
      ) {
        throw new Error(`${page.mode} history returned a repeated cursor`);
      }
      seenCursors.add(page.nextCursor);
      cursor = page.nextCursor;
    }

    throw new Error(`Conversation exceeds ${this.maxPages} history pages`);
  }

  private historyModes(
    process: CodexProcess,
  ): Map<string, CodexBoundedHistoryMode> {
    const existing = this.historyModeByProcess.get(process);
    if (existing) return existing;
    const modes = new Map<string, CodexBoundedHistoryMode>();
    this.historyModeByProcess.set(process, modes);
    return modes;
  }

  private async readProviderPage(
    process: CodexProcess,
    method: "thread/items/list" | "thread/turns/list",
    threadId: string,
    mode: CodexBoundedHistoryMode,
    options: ReadPageOptions,
  ): Promise<CodexBoundedHistoryPage> {
    throwIfAborted(options.signal);
    const limit = Math.min(
      this.pageSize,
      positiveInteger(options.limit, this.pageSize),
    );
    const sortDirection = options.sortDirection ?? "desc";
    const requestOptions: CodexRpcRequestOptions = {
      timeoutMs: this.rpcTimeoutMs,
      ...(options.signal ? { signal: options.signal } : {}),
    };
    const response = await process.requestReadOnlyRpc<{
      data?: unknown;
      nextCursor?: unknown;
    }>(
      method,
      {
        threadId,
        ...(method === "thread/turns/list" && mode !== "turnsLegacy"
          ? { itemsView: "full" }
          : {}),
        limit,
        cursor: options.cursor ?? null,
        sortDirection,
      },
      requestOptions,
    );
    if (!Array.isArray(response.data)) {
      throw new Error(`${method} returned invalid data`);
    }
    if (response.data.length > limit) {
      throw new Error(`${method} exceeded the requested page limit`);
    }

    const values = response.data.map((value) => {
      const record = recordValue(value);
      if (!record) throw new Error(`${method} returned invalid data`);
      const historyRecord =
        method === "thread/items/list"
          ? (recordValue(record.item) ?? record)
          : (recordValue(record.turn) ?? record);
      if (method === "thread/turns/list") {
        if (!Array.isArray(historyRecord.items)) {
          throw new Error(`${method} returned a turn without items`);
        }
        const itemsView = historyRecord.itemsView;
        if (itemsView !== undefined && itemsView !== "full") {
          throw new Error(
            `${method} returned non-full itemsView: ${String(itemsView)}`,
          );
        }
      }
      return {
        record: historyRecord,
        ...(method === "thread/items/list"
          ? {
              turnId:
                nonEmptyString(record.turnId) ??
                nonEmptyString(record.turn_id),
            }
          : {}),
      };
    });
    const chronological =
      sortDirection === "desc" ? values.reverse() : values;
    const turns =
      method === "thread/items/list"
        ? groupPaginatedItemsByTurn(threadId, chronological)
        : chronological.map((value) => value.record);
    const nextCursor =
      typeof response.nextCursor === "string" && response.nextCursor.length
        ? response.nextCursor
        : null;
    if (nextCursor !== null && nextCursor === (options.cursor ?? null)) {
      throw new Error(`${method} returned a repeated cursor`);
    }
    return {
      thread: { id: threadId, turns },
      nextCursor,
      mode,
      recordCount: values.length,
    };
  }
}

function groupPaginatedItemsByTurn(
  threadId: string,
  items: Array<{ record: Record<string, unknown>; turnId?: string }>,
): Record<string, unknown>[] {
  const fallbackTurnId = `${threadId}:bounded-items`;
  const turns: Array<{ id: string; items: Record<string, unknown>[] }> = [];
  const turnById = new Map<
    string,
    { id: string; items: Record<string, unknown>[] }
  >();
  for (const value of items) {
    const turnId = value.turnId ?? fallbackTurnId;
    let turn = turnById.get(turnId);
    if (!turn) {
      turn = { id: turnId, items: [] };
      turnById.set(turnId, turn);
      turns.push(turn);
    }
    turn.items.push(value.record);
  }
  return turns;
}

function mergeChronologicalTurns(
  values: Record<string, unknown>[],
): Record<string, unknown>[] {
  const merged: Record<string, unknown>[] = [];
  for (const value of values) {
    const id = nonEmptyString(value.id);
    const previous = merged.at(-1);
    if (
      id &&
      previous &&
      previous.id === id &&
      Array.isArray(previous.items) &&
      Array.isArray(value.items)
    ) {
      previous.items = [...previous.items, ...value.items];
      continue;
    }
    merged.push({ ...value });
  }
  return merged;
}

function threadTurns(thread: Record<string, unknown>): Record<string, unknown>[] {
  return Array.isArray(thread.turns)
    ? thread.turns
        .map(recordValue)
        .filter((turn): turn is Record<string, unknown> => turn !== null)
    : [];
}

function isHistoryPaginationUnavailable(
  error: unknown,
  method: "thread/items/list" | "thread/turns/list",
): boolean {
  if (error instanceof CodexRpcError && error.method !== method) return false;
  let message = errorMessage(error);
  if (error instanceof CodexRpcError) {
    try {
      message += ` ${JSON.stringify(error.data)}`;
    } catch {}
    if (error.code === -32601 || unsupportedOrInvalidMessage(message)) {
      return true;
    }
  }
  const namesPagination =
    method === "thread/items/list"
      ? /thread\/items\/list|item\/list|items\/list|listthreaditems|item pagination/i.test(
          message,
        )
      : /thread\/turns\/list|turn\/list|turns\/list|listthreadturns|turn pagination|itemsview|sortdirection/i.test(
          message,
        );
  return namesPagination && unsupportedOrInvalidMessage(message);
}

function isTurnsItemsViewParameterUnavailable(error: unknown): boolean {
  if (error instanceof CodexRpcError && error.method !== "thread/turns/list") {
    return false;
  }
  let message = errorMessage(error);
  if (error instanceof CodexRpcError) {
    try {
      message += ` ${JSON.stringify(error.data)}`;
    } catch {}
  }
  return (
    /itemsview|items_view|items view/i.test(message) &&
    unsupportedOrInvalidMessage(message)
  );
}

function isNonFullTurnsResponseError(error: unknown): boolean {
  return /thread\/turns\/list returned (?:a turn without items|non-full itemsView:)/i.test(
    errorMessage(error),
  );
}

function unsupportedOrInvalidMessage(message: string): boolean {
  const normalized = message.toLowerCase();
  return (
    /\b(unknown|unsupported|unrecognized|unexpected)\b/.test(normalized) ||
    /\bnot supported\b/.test(normalized) ||
    /\bmethod not found\b/.test(normalized) ||
    /\binvalid (?:param(?:eter)?s?|argument|field)\b/.test(normalized)
  );
}

function recordValue(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function nonEmptyString(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function positiveInteger(value: number | undefined, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value) && value > 0
    ? Math.floor(value)
    : fallback;
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function throwIfAborted(signal?: AbortSignal): void {
  if (!signal?.aborted) return;
  throw signal.reason instanceof Error
    ? signal.reason
    : new Error("Codex bounded history request aborted");
}
