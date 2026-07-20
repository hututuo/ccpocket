import { CodexRpcError, type CodexProcess } from "../codex-process.js";
import type { AssistantContent, ServerMessage } from "../parser.js";
import {
  getCodexSessionIndexMetadata,
  getCodexSessionIndexMetadataForFiles,
  type CodexSessionIndexMetadata,
} from "../sessions-index.js";
import { codexThreadToServerMessages } from "./codex-thread-history.js";
import type {
  CodexSubagentInfo,
  LocalFeatureClientMessage,
} from "./protocol.js";
import type {
  LocalFeatureHandler,
  LocalFeatureHandleContext,
} from "./runtime.js";

const SUBAGENT_SOURCE_KINDS = [
  "subAgent",
  "subAgentReview",
  "subAgentCompact",
  "subAgentThreadSpawn",
  "subAgentOther",
];

const THREAD_PAGE_SIZE = 100;
const MAX_THREAD_PAGES = 20;
const MAX_THREAD_ENTRIES = THREAD_PAGE_SIZE * MAX_THREAD_PAGES;
const HISTORY_PAGE_SIZE = 100;
const MAX_HISTORY_PAGES = 20;
const MAX_HISTORY_ENTRIES = HISTORY_PAGE_SIZE * MAX_HISTORY_PAGES;
const DEFAULT_SUBAGENT_DEADLINE_MS = 12_000;
const MAX_SUBAGENT_DEADLINE_MS = 15_000;
const MAX_FORK_LINEAGE_DEPTH = 16;
const MAX_PREVIEW_CHARS_PER_SIDE = 140;

export const MAX_SUBAGENT_HISTORY_MESSAGES = 400;
export const MAX_SUBAGENT_HISTORY_BYTES = 512 * 1024;

export interface CodexSubagentListResult {
  subagents: CodexSubagentInfo[];
  truncated: boolean;
}

export interface CodexSubagentHistoryResult {
  subagent: CodexSubagentInfo;
  messages: ServerMessage[];
  truncated: boolean;
}

export interface CodexSubagentOperationOptions {
  signal?: AbortSignal;
  timeoutMs?: number;
}

export class SubagentsFeatureHandler implements LocalFeatureHandler {
  readonly messageTypes = [
    "get_subagents",
    "get_subagent_history",
  ] as const;
  private readonly activeClients = new WeakSet<object>();
  private readonly service = new CodexSubagentService();

  async handle(
    message: LocalFeatureClientMessage,
    context: LocalFeatureHandleContext,
  ): Promise<void> {
    if (
      message.type !== "get_subagents" &&
      message.type !== "get_subagent_history"
    ) {
      return;
    }
    const responseType =
      message.type === "get_subagents" ? "subagent_list" : "subagent_history";
    if (!context.runtime.supports(context.client, responseType)) {
      this.sendFailure(
        message,
        context,
        "Subagent capability was not negotiated",
      );
      return;
    }
    if (this.activeClients.has(context.client)) {
      this.sendFailure(
        message,
        context,
        "Another subagent request is already in progress",
      );
      return;
    }

    const session = context.runtime.getSession(message.sessionId);
    const parentThreadId = session
      ? context.runtime.getCodexThreadId(session)
      : undefined;
    if (
      !session ||
      session.provider !== "codex" ||
      !parentThreadId ||
      !isCodexReadOnlyProcess(session.process)
    ) {
      this.sendFailure(message, context, "Codex session not found");
      return;
    }

    this.activeClients.add(context.client);
    try {
      if (message.type === "get_subagents") {
        const result = await this.service.list(session.process, parentThreadId, {
          signal: context.signal,
        });
        context.runtime.send(context.client, {
          type: "subagent_list",
          sessionId: message.sessionId,
          requestId: message.requestId,
          subagents: result.subagents,
          ...(result.truncated ? { truncated: true } : {}),
        });
        return;
      }

      const result = await this.service.readVerified(
        session.process,
        parentThreadId,
        message.threadId,
        { signal: context.signal },
      );
      context.runtime.send(context.client, {
        type: "subagent_history",
        sessionId: message.sessionId,
        requestId: message.requestId,
        threadId: message.threadId,
        subagent: result.subagent,
        messages: result.messages,
        ...(result.truncated ? { truncated: true } : {}),
      });
    } catch (error) {
      if (!context.signal.aborted) {
        this.sendFailure(
          message,
          context,
          error instanceof Error ? error.message : String(error),
        );
      }
    } finally {
      this.activeClients.delete(context.client);
    }
  }

  disconnect(client: object): void {
    this.activeClients.delete(client);
  }

  private sendFailure(
    message: Extract<
      LocalFeatureClientMessage,
      { type: "get_subagents" | "get_subagent_history" }
    >,
    context: LocalFeatureHandleContext,
    error: string,
  ): void {
    if (message.type === "get_subagents") {
      context.runtime.send(context.client, {
        type: "subagent_list",
        sessionId: message.sessionId,
        requestId: message.requestId,
        subagents: [],
        error,
      });
      return;
    }
    context.runtime.send(context.client, {
      type: "subagent_history",
      sessionId: message.sessionId,
      requestId: message.requestId,
      threadId: message.threadId,
      messages: [],
      error,
    });
  }
}

interface CollectedPageEntries<T> {
  entries: T[];
  truncated: boolean;
}

export class CodexSubagentService {
  async list(
    process: CodexProcess,
    parentThreadId: string,
    options: CodexSubagentOperationOptions = {},
  ): Promise<CodexSubagentListResult> {
    const deadline = new OperationDeadline(options);
    try {
      return await this.listWithinDeadline(process, parentThreadId, deadline);
    } finally {
      deadline.dispose();
    }
  }

  async readVerified(
    process: CodexProcess,
    parentThreadId: string,
    childThreadId: string,
    options: CodexSubagentOperationOptions = {},
  ): Promise<CodexSubagentHistoryResult> {
    const deadline = new OperationDeadline(options);
    try {
      if (childThreadId === parentThreadId) {
        throw new Error("Requested thread is not a subagent descendant");
      }

      const listed = await this.listWithinDeadline(
        process,
        parentThreadId,
        deadline,
      );
      const subagent = listed.subagents.find(
        (entry) => entry.id === childThreadId,
      );
      if (!subagent) {
        throw new Error(
          listed.truncated
            ? "Requested thread was not found in the bounded subagent descendant list"
            : "Requested thread is not a subagent descendant",
        );
      }

      const history = await this.readHistory(
        process,
        childThreadId,
        deadline,
      );
      const converted = childThreadToServerMessages(history.thread);
      const limited = limitSubagentHistoryResponse(converted);
      return {
        subagent,
        messages: limited.messages,
        truncated: history.truncated || limited.truncated,
      };
    } finally {
      deadline.dispose();
    }
  }

  private async listWithinDeadline(
    process: CodexProcess,
    parentThreadId: string,
    deadline: OperationDeadline,
  ): Promise<CodexSubagentListResult> {
    const lineage = await this.readForkLineage(
      process,
      parentThreadId,
      deadline,
    );
    const rolloutPaths = new Map<string, string>();
    try {
      const collected = await this.collectLineageDescendants(
        process,
        lineage,
        deadline,
        rolloutPaths,
      );
      return {
        subagents: await hydrateLatestPreviews(
          collected.entries,
          rolloutPaths,
        ),
        truncated: collected.truncated,
      };
    } catch (error) {
      if (!isUnsupportedAncestorFilterError(error)) throw error;
      console.warn(
        `[subagents] ancestorThreadId unsupported; using bounded local filter: ${errorMessage(error)}`,
      );
      rolloutPaths.clear();
      const collected = await this.collectArchivedStatesWithStateDbFallback(
        process,
        deadline,
        { sourceKinds: SUBAGENT_SOURCE_KINDS },
        rolloutPaths,
      );
      return {
        subagents: await hydrateLatestPreviews(
          descendantsOfAny(collected.entries, lineage),
          rolloutPaths,
        ),
        truncated: collected.truncated,
      };
    }
  }

  private async readForkLineage(
    process: CodexProcess,
    threadId: string,
    deadline: OperationDeadline,
  ): Promise<string[]> {
    const lineage: string[] = [];
    const seen = new Set<string>();
    let current: string | null = threadId;

    while (
      current &&
      lineage.length < MAX_FORK_LINEAGE_DEPTH &&
      !seen.has(current)
    ) {
      lineage.push(current);
      seen.add(current);
      try {
        const response: { thread?: unknown } = await process.requestReadOnlyRpc<{
          thread?: unknown;
        }>(
          "thread/read",
          { threadId: current, includeTurns: false },
          deadline.rpcOptions(),
        );
        const thread: Record<string, unknown> | null = isRecord(response.thread)
          ? response.thread
          : null;
        current = thread ? stringOrNull(thread.forkedFromId) : null;
      } catch (error) {
        if (isUnsupportedThreadReadError(error)) break;
        throw error;
      }
    }

    return lineage;
  }

  private async collectLineageDescendants(
    process: CodexProcess,
    lineage: readonly string[],
    deadline: OperationDeadline,
    rolloutPaths: Map<string, string>,
  ): Promise<CollectedPageEntries<CodexSubagentInfo>> {
    const merged = new Map<string, CodexSubagentInfo>();
    let truncated = false;

    for (const ancestorThreadId of lineage) {
      const collected = await this.collectArchivedStatesWithStateDbFallback(
        process,
        deadline,
        {
          ancestorThreadId,
          // Omitted/empty sourceKinds means interactive threads in the
          // official protocol. Explicitly request spawned descendants.
          sourceKinds: SUBAGENT_SOURCE_KINDS,
        },
        rolloutPaths,
      );
      truncated ||= collected.truncated;
      for (const entry of collected.entries) {
        const previous = merged.get(entry.id);
        if (!previous || entry.updatedAt >= previous.updatedAt) {
          merged.set(entry.id, entry);
        }
      }
      if (merged.size >= MAX_THREAD_ENTRIES) {
        truncated = true;
        break;
      }
    }

    const entries = [...merged.values()]
      .sort((left, right) => right.updatedAt - left.updatedAt)
      .slice(0, MAX_THREAD_ENTRIES);
    return { entries, truncated: truncated || merged.size > entries.length };
  }

  private async collectArchivedStates(
    process: CodexProcess,
    deadline: OperationDeadline,
    filters: {
      ancestorThreadId?: string;
      sourceKinds?: readonly string[];
      useStateDbOnly?: boolean;
    },
    rolloutPaths: Map<string, string>,
  ): Promise<CollectedPageEntries<CodexSubagentInfo>> {
    const active = await this.collectThreads(
      process,
      deadline,
      filters,
      false,
      rolloutPaths,
    );
    if (active.truncated || active.entries.length >= MAX_THREAD_ENTRIES) {
      return active;
    }
    let archived: CollectedPageEntries<CodexSubagentInfo> = {
      entries: [],
      truncated: false,
    };
    try {
      archived = await this.collectThreads(
        process,
        deadline,
        filters,
        true,
        rolloutPaths,
      );
    } catch (error) {
      if (!isUnsupportedArchivedFilterError(error)) throw error;
    }

    const merged = new Map<string, CodexSubagentInfo>();
    for (const entry of [...active.entries, ...archived.entries]) {
      const previous = merged.get(entry.id);
      if (!previous || entry.updatedAt >= previous.updatedAt) {
        merged.set(entry.id, entry);
      }
    }
    const entries = [...merged.values()]
      .sort((left, right) => right.updatedAt - left.updatedAt)
      .slice(0, MAX_THREAD_ENTRIES);
    return {
      entries,
      truncated:
        active.truncated ||
        archived.truncated ||
        merged.size > entries.length,
    };
  }

  private async collectArchivedStatesWithStateDbFallback(
    process: CodexProcess,
    deadline: OperationDeadline,
    filters: {
      ancestorThreadId?: string;
      sourceKinds?: readonly string[];
    },
    rolloutPaths: Map<string, string>,
  ): Promise<CollectedPageEntries<CodexSubagentInfo>> {
    try {
      return await this.collectArchivedStates(
        process,
        deadline,
        { ...filters, useStateDbOnly: true },
        rolloutPaths,
      );
    } catch (error) {
      if (!isUnsupportedStateDbOnlyError(error)) throw error;
      return this.collectArchivedStates(
        process,
        deadline,
        filters,
        rolloutPaths,
      );
    }
  }

  private async collectThreads(
    process: CodexProcess,
    deadline: OperationDeadline,
    filters: {
      ancestorThreadId?: string;
      sourceKinds?: readonly string[];
      useStateDbOnly?: boolean;
    },
    archived: boolean,
    rolloutPaths: Map<string, string>,
  ): Promise<CollectedPageEntries<CodexSubagentInfo>> {
    return collectBoundedPages(
      async (cursor) => {
        const response = await process.requestReadOnlyRpc<{
          data?: unknown;
          nextCursor?: unknown;
        }>(
          "thread/list",
          {
            sortKey: "updated_at",
            archived,
            limit: THREAD_PAGE_SIZE,
            cursor,
            ...(filters.ancestorThreadId
              ? { ancestorThreadId: filters.ancestorThreadId }
              : {}),
            ...(filters.sourceKinds
              ? { sourceKinds: [...filters.sourceKinds] }
              : {}),
            ...(filters.useStateDbOnly ? { useStateDbOnly: true } : {}),
          },
          deadline.rpcOptions(),
        );
        return {
          data: Array.isArray(response.data)
            ? response.data.flatMap((value) => {
                const entry = toCodexSubagentInfo(value);
                if (!entry.id) return [];
                const record = isRecord(value) ? value : null;
                const rolloutPath = record
                  ? stringOrNull(record.path)
                  : null;
                if (rolloutPath) rolloutPaths.set(entry.id, rolloutPath);
                return [entry];
              })
            : [],
          nextCursor:
            typeof response.nextCursor === "string"
              ? response.nextCursor
              : null,
        };
      },
      {
        maxPages: MAX_THREAD_PAGES,
        maxEntries: MAX_THREAD_ENTRIES,
        identity: (entry) => entry.id,
        signal: deadline.signal,
      },
    );
  }

  private async readHistory(
    process: CodexProcess,
    childThreadId: string,
    deadline: OperationDeadline,
  ): Promise<{ thread: Record<string, unknown>; truncated: boolean }> {
    try {
      const items = await this.collectHistoryPages(
        process,
        "thread/items/list",
        childThreadId,
        deadline,
      );
      return {
        thread: {
          id: childThreadId,
          turns: [{ items: [...items.entries].reverse() }],
        },
        truncated: items.truncated,
      };
    } catch (error) {
      if (!isUnsupportedHistoryPaginationError(error, "thread/items/list")) {
        throw error;
      }
    }

    try {
      const turns = await this.collectHistoryPages(
        process,
        "thread/turns/list",
        childThreadId,
        deadline,
      );
      return {
        thread: { id: childThreadId, turns: [...turns.entries].reverse() },
        truncated: turns.truncated,
      };
    } catch (error) {
      if (!isUnsupportedHistoryPaginationError(error, "thread/turns/list")) {
        throw error;
      }
    }

    // `thread/read(includeTurns:true)` has no server-side page or byte bound.
    // Refuse that legacy fallback instead of loading and converting an entire
    // child rollout before applying our response limit.
    throw new Error(
      "Subagent history pagination is not supported by this Codex app-server",
    );
  }

  private collectHistoryPages(
    process: CodexProcess,
    method: "thread/items/list" | "thread/turns/list",
    threadId: string,
    deadline: OperationDeadline,
  ): Promise<CollectedPageEntries<Record<string, unknown>>> {
    return collectBoundedPages(
      async (cursor) => {
        const response = await process.requestReadOnlyRpc<{
          data?: unknown;
          nextCursor?: unknown;
        }>(
          method,
          {
            threadId,
            limit: HISTORY_PAGE_SIZE,
            cursor,
            sortDirection: "desc",
          },
          deadline.rpcOptions(),
        );
        if (!Array.isArray(response.data)) {
          throw new Error(`${method} returned invalid data`);
        }
        return {
          data: response.data.flatMap((value) => {
            if (!isRecord(value)) return [];
            if (method === "thread/items/list" && isRecord(value.item)) {
              return [value.item];
            }
            return [value];
          }),
          nextCursor:
            typeof response.nextCursor === "string"
              ? response.nextCursor
              : null,
        };
      },
      {
        maxPages: MAX_HISTORY_PAGES,
        maxEntries: MAX_HISTORY_ENTRIES,
        signal: deadline.signal,
      },
    );
  }
}

async function hydrateLatestPreviews(
  entries: readonly CodexSubagentInfo[],
  rolloutPaths: ReadonlyMap<string, string>,
): Promise<CodexSubagentInfo[]> {
  if (entries.length === 0) return [];
  const metadata = new Map<string, CodexSessionIndexMetadata>();
  try {
    const byPath = await getCodexSessionIndexMetadataForFiles(rolloutPaths);
    for (const [id, value] of byPath) metadata.set(id, value);
  } catch (error) {
    console.warn(
      `[subagents] rollout-path preview hydration skipped: ${errorMessage(error)}`,
    );
  }
  const unresolved = entries
    .map((entry) => entry.id)
    .filter((id) => !metadata.has(id));
  if (unresolved.length > 0) {
    try {
      const indexed = await getCodexSessionIndexMetadata(unresolved);
      for (const [id, value] of indexed) metadata.set(id, value);
    } catch (error) {
      // List visibility must never depend on optional preview enrichment.
      console.warn(
        `[subagents] indexed preview hydration skipped: ${errorMessage(error)}`,
      );
    }
  }
  return entries.map((entry) => {
    const snapshot = metadata.get(entry.id);
    if (!snapshot) return entry;
    // A persisted subagent rollout may begin with the ancestor's replayed
    // transcript. In that shape `firstPrompt` belongs to the parent, not to
    // the child's latest exchange. Only pair an answer with a prompt proven
    // to be later than that inherited head; otherwise render the latest
    // answer alone instead of showing the same root prompt on every card.
    const question = snapshot.lastPrompt;
    const answer = snapshot.summary;
    const preview = latestExchangePreview(question, answer);
    return preview ? { ...entry, preview } : entry;
  });
}

function latestExchangePreview(
  question: string | undefined,
  answer: string | undefined,
): string {
  const compact = (value: string | undefined): string =>
    (value ?? "")
      .trim()
      .replace(/\s+/g, " ")
      .slice(0, MAX_PREVIEW_CHARS_PER_SIDE);
  const latestQuestion = compact(question);
  const latestAnswer = compact(answer);
  if (latestQuestion && latestAnswer) {
    return `${latestQuestion}\n${latestAnswer}`;
  }
  return latestAnswer || latestQuestion;
}

function descendantsOfAny(
  entries: readonly CodexSubagentInfo[],
  roots: readonly string[],
): CodexSubagentInfo[] {
  const merged = new Map<string, CodexSubagentInfo>();
  for (const root of roots) {
    for (const entry of descendantsOf([...entries], root)) {
      const previous = merged.get(entry.id);
      if (!previous || entry.updatedAt >= previous.updatedAt) {
        merged.set(entry.id, entry);
      }
    }
  }
  return [...merged.values()].sort(
    (left, right) => right.updatedAt - left.updatedAt,
  );
}

async function collectBoundedPages<T>(
  loader: (
    cursor: string | null,
  ) => Promise<{ data: T[]; nextCursor: string | null }>,
  options: {
    maxPages: number;
    maxEntries: number;
    identity?: (entry: T) => string;
    signal?: AbortSignal;
  },
): Promise<CollectedPageEntries<T>> {
  const entries: T[] = [];
  const seenEntryIds = new Set<string>();
  const seenCursors = new Set<string>();
  let cursor: string | null = null;
  let nextCursor: string | null = null;

  for (let pageIndex = 0; pageIndex < options.maxPages; pageIndex += 1) {
    throwIfAborted(options.signal);
    const page = await loader(cursor);
    if (!Array.isArray(page.data)) {
      throw new Error("Invalid paginated response");
    }

    for (let entryIndex = 0; entryIndex < page.data.length; entryIndex += 1) {
      const entry = page.data[entryIndex]!;
      const id = options.identity?.(entry);
      if (id !== undefined) {
        if (!id || seenEntryIds.has(id)) continue;
        seenEntryIds.add(id);
      }
      entries.push(entry);
      if (entries.length >= options.maxEntries) {
        nextCursor = page.nextCursor;
        const hasUnconsumedPageEntries = entryIndex + 1 < page.data.length;
        const truncated = hasUnconsumedPageEntries || page.nextCursor !== null;
        return {
          entries,
          truncated,
        };
      }
    }

    nextCursor = page.nextCursor;
    if (!nextCursor) return { entries, truncated: false };
    if (nextCursor === cursor || seenCursors.has(nextCursor)) {
      return { entries, truncated: true };
    }
    seenCursors.add(nextCursor);
    cursor = nextCursor;
  }

  return {
    entries,
    truncated: nextCursor !== null,
  };
}

class OperationDeadline {
  private readonly controller = new AbortController();
  private readonly timer: ReturnType<typeof setTimeout>;
  private readonly deadlineAt: number;
  private readonly parentSignal?: AbortSignal;
  private readonly parentAbort = (): void => {
    this.controller.abort(this.parentSignal?.reason);
  };

  constructor(options: CodexSubagentOperationOptions) {
    const timeoutMs = Math.max(
      1,
      Math.min(
        options.timeoutMs ?? DEFAULT_SUBAGENT_DEADLINE_MS,
        MAX_SUBAGENT_DEADLINE_MS,
      ),
    );
    this.deadlineAt = Date.now() + timeoutMs;
    this.parentSignal = options.signal;
    if (options.signal?.aborted) {
      this.controller.abort(options.signal.reason);
    } else {
      options.signal?.addEventListener("abort", this.parentAbort, {
        once: true,
      });
    }
    this.timer = setTimeout(() => {
      this.controller.abort(new Error("Subagent request deadline exceeded"));
    }, timeoutMs);
  }

  get signal(): AbortSignal {
    return this.controller.signal;
  }

  rpcOptions(): { timeoutMs: number; signal: AbortSignal } {
    throwIfAborted(this.signal);
    return {
      timeoutMs: Math.max(1, this.deadlineAt - Date.now()),
      signal: this.signal,
    };
  }

  dispose(): void {
    clearTimeout(this.timer);
    this.parentSignal?.removeEventListener("abort", this.parentAbort);
  }
}

function throwIfAborted(signal: AbortSignal | undefined): void {
  if (!signal?.aborted) return;
  throw signal.reason instanceof Error
    ? signal.reason
    : new Error("Subagent request aborted");
}

/**
 * Pure conversion for child-thread history. It intentionally emits text-only
 * protocol messages and never resolves paths, registers images, materializes
 * artifacts, or writes Gallery state.
 */
export function childThreadToServerMessages(
  threadOrTurns: unknown,
): ServerMessage[] {
  return codexThreadToServerMessages(threadOrTurns, {
    idPrefix: "child-history",
  });
}

export function toCodexSubagentInfo(value: unknown): CodexSubagentInfo {
  const record = isRecord(value) ? value : {};
  const gitInfo = isRecord(record.gitInfo) ? record.gitInfo : {};
  const status = isRecord(record.status) ? record.status : {};
  const source = normalizeCodexThreadSource(record.source);
  const metadata = extractCodexSubagentMetadata(record.source);
  return {
    id: stringOrNull(record.id) ?? "",
    sessionId: stringOrNull(record.sessionId),
    parentThreadId: stringOrNull(record.parentThreadId),
    forkedFromId: stringOrNull(record.forkedFromId),
    preview: stringOrNull(record.preview) ?? "",
    createdAt: finiteNumber(record.createdAt) ?? 0,
    updatedAt: finiteNumber(record.updatedAt) ?? 0,
    cwd: stringOrNull(record.cwd) ?? "",
    status:
      stringOrNull(record.status) ?? stringOrNull(status.type) ?? "unknown",
    activeFlags: Array.isArray(status.activeFlags)
      ? status.activeFlags.filter(
          (flag): flag is string => typeof flag === "string",
        )
      : [],
    source,
    threadSource: stringOrNull(record.threadSource),
    agentNickname: stringOrNull(record.agentNickname) ?? metadata.agentNickname,
    agentRole: stringOrNull(record.agentRole) ?? metadata.agentRole,
    agentPath: metadata.agentPath,
    gitBranch: stringOrNull(gitInfo.branch),
    name: stringOrNull(record.name),
    ephemeral: record.ephemeral === true,
  };
}

function normalizeCodexThreadSource(source: unknown): string | null {
  if (typeof source === "string") return source;
  if (!isRecord(source)) return null;
  if (typeof source.custom === "string") return source.custom;
  const subagent = source.subAgent;
  if (typeof subagent === "string") {
    if (subagent === "review") return "subAgentReview";
    if (subagent === "compact") return "subAgentCompact";
    return "subAgentOther";
  }
  if (!isRecord(subagent)) return null;
  if (subagent.thread_spawn || subagent.threadSpawn) {
    return "subAgentThreadSpawn";
  }
  return "subAgentOther";
}

function extractCodexSubagentMetadata(source: unknown): {
  agentNickname: string | null;
  agentRole: string | null;
  agentPath: string | null;
} {
  const empty = {
    agentNickname: null,
    agentRole: null,
    agentPath: null,
  };
  if (!isRecord(source) || !isRecord(source.subAgent)) return empty;
  const spawn = source.subAgent.thread_spawn ?? source.subAgent.threadSpawn;
  if (!isRecord(spawn)) return empty;
  return {
    agentNickname: stringOrNull(spawn.agent_nickname ?? spawn.agentNickname),
    agentRole: stringOrNull(spawn.agent_role ?? spawn.agentRole),
    agentPath: stringOrNull(spawn.agent_path ?? spawn.agentPath),
  };
}

export function limitSubagentHistoryResponse(
  messages: readonly ServerMessage[],
  options: { maxMessages?: number; maxBytes?: number } = {},
): { messages: ServerMessage[]; truncated: boolean } {
  const maxMessages = Math.max(
    0,
    Math.floor(options.maxMessages ?? MAX_SUBAGENT_HISTORY_MESSAGES),
  );
  const maxBytes = Math.max(
    2,
    Math.floor(options.maxBytes ?? MAX_SUBAGENT_HISTORY_BYTES),
  );
  if (messages.length === 0 || maxMessages === 0) {
    return { messages: [], truncated: messages.length > 0 };
  }

  const newestFirst: ServerMessage[] = [];
  let usedBytes = 2; // JSON array brackets.
  let truncated = false;

  for (let index = messages.length - 1; index >= 0; index -= 1) {
    if (newestFirst.length >= maxMessages) {
      truncated = true;
      break;
    }
    const message = messages[index]!;
    const separatorBytes = newestFirst.length === 0 ? 0 : 1;
    const messageBytes = jsonBytes(message);
    if (usedBytes + separatorBytes + messageBytes <= maxBytes) {
      newestFirst.push(message);
      usedBytes += separatorBytes + messageBytes;
      continue;
    }

    truncated = true;
    if (newestFirst.length === 0) {
      const compacted = compactMessageToBytes(message, maxBytes - 2);
      if (compacted) newestFirst.push(compacted);
    }
    break;
  }

  if (newestFirst.length < messages.length) truncated = true;
  return { messages: newestFirst.reverse(), truncated };
}

function compactMessageToBytes(
  message: ServerMessage,
  maxBytes: number,
): ServerMessage | null {
  if (maxBytes <= 0) return null;
  if (message.type === "user_input") {
    return compactTextMessage(message, maxBytes);
  }
  if (message.type === "tool_result") {
    return compactTextMessage(message, maxBytes);
  }
  if (message.type !== "assistant") return null;

  const content = message.message.content;
  for (let start = content.length - 1; start >= 0; start -= 1) {
    const suffix = content.slice(start);
    const candidate: ServerMessage = {
      ...message,
      message: { ...message.message, content: suffix },
    };
    if (jsonBytes(candidate) <= maxBytes) return candidate;

    if (suffix.length !== 1) continue;
    const block = suffix[0]!;
    if (block.type === "text") {
      return compactAssistantBlock(message, block, maxBytes);
    }
    if (block.type === "thinking") {
      return compactAssistantBlock(message, block, maxBytes);
    }
    if (block.type === "tool_use") {
      const serialized = safeJsonStringify(block.input);
      return binarySearchCompaction(serialized.length, (tailLength) => ({
        ...message,
        message: {
          ...message.message,
          content: [
            {
              ...block,
              input: {
                truncated: true,
                tail: truncateTextTail(serialized, tailLength),
              },
            },
          ],
        },
      }), maxBytes);
    }
  }
  return null;
}

function compactTextMessage(
  message: Extract<ServerMessage, { type: "user_input" | "tool_result" }>,
  maxBytes: number,
): ServerMessage | null {
  const text = message.type === "user_input" ? message.text : message.content;
  return binarySearchCompaction(
    text.length,
    (tailLength) =>
      message.type === "user_input"
        ? { ...message, text: truncateTextTail(text, tailLength) }
        : { ...message, content: truncateTextTail(text, tailLength) },
    maxBytes,
  );
}

function compactAssistantBlock(
  message: Extract<ServerMessage, { type: "assistant" }>,
  block: Extract<AssistantContent, { type: "text" | "thinking" }>,
  maxBytes: number,
): ServerMessage | null {
  const text = block.type === "text" ? block.text : block.thinking;
  return binarySearchCompaction(
    text.length,
    (tailLength) => ({
      ...message,
      message: {
        ...message.message,
        content: [
          block.type === "text"
            ? { ...block, text: truncateTextTail(text, tailLength) }
            : { ...block, thinking: truncateTextTail(text, tailLength) },
        ] as AssistantContent[],
      },
    }),
    maxBytes,
  );
}

function binarySearchCompaction(
  originalLength: number,
  candidate: (tailLength: number) => ServerMessage,
  maxBytes: number,
): ServerMessage | null {
  let low = 0;
  let high = originalLength;
  let best: ServerMessage | null = null;
  while (low <= high) {
    const middle = Math.floor((low + high) / 2);
    const next = candidate(middle);
    if (jsonBytes(next) <= maxBytes) {
      best = next;
      low = middle + 1;
    } else {
      high = middle - 1;
    }
  }
  return best;
}

function truncateTextTail(value: string, tailLength: number): string {
  if (tailLength >= value.length) return value;
  let start = Math.max(0, value.length - Math.max(0, tailLength));
  const code = value.charCodeAt(start);
  if (code >= 0xdc00 && code <= 0xdfff) start += 1;
  return `[earlier content truncated]\n${value.slice(start)}`;
}

function jsonBytes(value: unknown): number {
  return Buffer.byteLength(safeJsonStringify(value), "utf8");
}

function safeJsonStringify(value: unknown): string {
  try {
    return JSON.stringify(value) ?? "null";
  } catch {
    return JSON.stringify(String(value));
  }
}

function isUnsupportedAncestorFilterError(error: unknown): boolean {
  if (
    error instanceof CodexRpcError &&
    error.method === "thread/list" &&
    error.code === -32601
  ) {
    return true;
  }
  const message = errorMessage(error).toLowerCase();
  const namesAncestorParameter =
    message.includes("ancestorthreadid") ||
    message.includes("ancestor_thread_id") ||
    message.includes("ancestor thread");
  return namesAncestorParameter && unsupportedOrInvalidMessage(message);
}

function isUnsupportedArchivedFilterError(error: unknown): boolean {
  if (
    error instanceof CodexRpcError &&
    error.method === "thread/list" &&
    error.code === -32601
  ) {
    return true;
  }
  const message = errorMessage(error).toLowerCase();
  return message.includes("archived") && unsupportedOrInvalidMessage(message);
}

function isUnsupportedStateDbOnlyError(error: unknown): boolean {
  const message = errorMessage(error).toLowerCase();
  return (
    (message.includes("usestatedbonly") ||
      message.includes("use_state_db_only") ||
      message.includes("state db only")) &&
    unsupportedOrInvalidMessage(message)
  );
}

function isUnsupportedThreadReadError(error: unknown): boolean {
  if (
    error instanceof CodexRpcError &&
    error.method === "thread/read" &&
    error.code === -32601
  ) {
    return true;
  }
  const message = errorMessage(error).toLowerCase();
  const namesMethod =
    message.includes("thread/read") ||
    message.includes("readthread") ||
    message.includes("thread read");
  return namesMethod && unsupportedOrInvalidMessage(message);
}

function isUnsupportedHistoryPaginationError(
  error: unknown,
  method: "thread/turns/list" | "thread/items/list",
): boolean {
  if (
    error instanceof CodexRpcError &&
    error.method === method &&
    error.code === -32601
  ) {
    return true;
  }
  const message = errorMessage(error).toLowerCase();
  const namesMethod =
    method === "thread/turns/list"
      ? message.includes("thread/turns/list") ||
        message.includes("turn/list") ||
        message.includes("listthreadturns") ||
        message.includes("turn pagination")
      : message.includes("thread/items/list") ||
        message.includes("item/list") ||
        message.includes("items/list") ||
        message.includes("listthreaditems") ||
        message.includes("item pagination");
  return namesMethod && unsupportedOrInvalidMessage(message);
}

function unsupportedOrInvalidMessage(message: string): boolean {
  return /\b(unknown|unsupported|unrecognized|unexpected)\b/.test(message) ||
    /\bnot supported\b/.test(message) ||
    /\bmethod not found\b/.test(message) ||
    /\binvalid (?:param(?:eter)?s?|argument|field)\b/.test(message);
}

function errorMessage(error: unknown): string {
  if (error instanceof Error) return error.message;
  if (typeof error === "string") return error;
  if (isRecord(error) && typeof error.message === "string") {
    return error.message;
  }
  return String(error);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

export function descendantsOf(
  candidates: CodexSubagentInfo[],
  ancestorThreadId: string,
): CodexSubagentInfo[] {
  const byId = new Map(candidates.map((entry) => [entry.id, entry]));
  const memo = new Map<string, boolean>();

  const isDescendant = (entry: CodexSubagentInfo): boolean => {
    const cached = memo.get(entry.id);
    if (cached !== undefined) return cached;
    const seen = new Set<string>([entry.id]);
    let parentId = entry.parentThreadId;
    while (parentId) {
      if (parentId === ancestorThreadId) {
        memo.set(entry.id, true);
        return true;
      }
      if (seen.has(parentId)) break;
      seen.add(parentId);
      parentId = byId.get(parentId)?.parentThreadId ?? null;
    }
    memo.set(entry.id, false);
    return false;
  };

  return candidates.filter(isDescendant);
}

function stringOrNull(value: unknown): string | null {
  return typeof value === "string" ? value : null;
}

function finiteNumber(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value)
    ? value
    : undefined;
}

function isCodexReadOnlyProcess(value: unknown): value is CodexProcess {
  return (
    value !== null &&
    typeof value === "object" &&
    typeof (value as { requestReadOnlyRpc?: unknown }).requestReadOnlyRpc ===
      "function"
  );
}
