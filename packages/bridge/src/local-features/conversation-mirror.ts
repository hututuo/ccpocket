import { createHash } from "node:crypto";
import { CodexRpcError, type CodexProcess } from "../codex-process.js";
import type { AssistantContent, ServerMessage } from "../parser.js";
import {
  codexThreadToSessionHistory,
  codexUserTurnUuid,
  type SessionHistoryMessage,
} from "../sessions-index.js";
import type {
  ConversationMirrorClientMessage,
  ConversationMirrorEntry,
  ConversationMirrorEventMessage,
  ConversationMirrorProvider,
  ConversationMirrorThreadStatus,
  LocalFeatureClientMessage,
} from "./protocol.js";
import type {
  LocalFeatureHandler,
  LocalFeatureHandleContext,
  LocalFeatureRuntime,
} from "./runtime.js";

const HISTORY_PAGE_SIZE = 100;
const DEFAULT_RPC_TIMEOUT_MS = 15_000;
const DEFAULT_MARKER_POLL_MS = 5_000;
const DEFAULT_FULL_RECONCILE_MS = 5 * 60_000;
const DEFAULT_STANDALONE_IDLE_MS = 15_000;
const DEFAULT_MAX_CONCURRENT_READS = 2;
const DEFAULT_MAX_POLL_BACKOFF_MS = 5 * 60_000;
const DEFAULT_POLL_JITTER_RATIO = 0.2;

export const MAX_CONVERSATION_MIRROR_ENTRIES = 10_000;
export const MAX_CONVERSATION_MIRROR_TOTAL_BYTES = 32 * 1024 * 1024;
export const MAX_CONVERSATION_MIRROR_EVENT_BYTES = 512 * 1024;
export const MAX_CONVERSATION_MIRROR_PAGE_ENTRIES = 100;
export const MAX_CONVERSATION_MIRROR_WATCHES_PER_CLIENT = 8;
export const MAX_CONVERSATION_MIRROR_WATCHED_THREADS = 32;

type MirrorErrorCode =
  | "capability_not_negotiated"
  | "entry_too_large"
  | "history_too_large"
  | "invalid_state"
  | "path_not_allowed"
  | "read_failed"
  | "unsupported_provider";

export class ConversationMirrorError extends Error {
  constructor(
    readonly code: MirrorErrorCode,
    message: string,
    readonly originalError?: unknown,
  ) {
    super(message);
    this.name = "ConversationMirrorError";
  }
}

export interface ConversationMirrorMarker {
  digest: string;
  threadStatus: ConversationMirrorThreadStatus;
  /** Provider-reported cwd; internal authorization metadata, never on wire. */
  threadCwd?: string;
}

export interface ConversationMirrorSnapshot extends ConversationMirrorMarker {
  revision: string;
  entries: ConversationMirrorEntry[];
  totalBytes: number;
}

export interface ConversationMirrorReaderOptions {
  rpcTimeoutMs?: number;
  maxPages?: number;
  maxEntries?: number;
  maxTotalBytes?: number;
}

type ConversationMirrorHistoryMode =
  | "items"
  | "turns"
  | "turnsLegacy"
  | "whole";

/**
 * Provider reader kept separate from WebSocket lifecycle code so the mirror
 * feature can be removed or replaced without changing canonical sessions.
 */
export class CodexConversationMirrorReader {
  private readonly historyModeByProcess = new WeakMap<
    object,
    Map<string, ConversationMirrorHistoryMode>
  >();
  private readonly rpcTimeoutMs: number;
  private readonly maxPages: number;
  private readonly maxEntries: number;
  private readonly maxTotalBytes: number;

  constructor(options: ConversationMirrorReaderOptions = {}) {
    this.rpcTimeoutMs = positiveInteger(
      options.rpcTimeoutMs,
      DEFAULT_RPC_TIMEOUT_MS,
    );
    this.maxPages = positiveInteger(options.maxPages, 100);
    this.maxEntries = positiveInteger(
      options.maxEntries,
      MAX_CONVERSATION_MIRROR_ENTRIES,
    );
    this.maxTotalBytes = positiveInteger(
      options.maxTotalBytes,
      MAX_CONVERSATION_MIRROR_TOTAL_BYTES,
    );
  }

  async readMarker(
    process: CodexProcess,
    threadId: string,
    signal?: AbortSignal,
  ): Promise<ConversationMirrorMarker> {
    const response = await process.requestReadOnlyRpc<unknown>(
      "thread/read",
      { threadId, includeTurns: false },
      { timeoutMs: this.rpcTimeoutMs, ...(signal ? { signal } : {}) },
    );
    const thread = responseThread(response);
    return markerFromThread(thread);
  }

  async readSnapshot(
    process: CodexProcess,
    threadId: string,
    signal?: AbortSignal,
    authorizeMarker?: (marker: ConversationMirrorMarker) => void,
  ): Promise<ConversationMirrorSnapshot> {
    try {
      const marker = await this.readMarker(process, threadId, signal);
      authorizeMarker?.(marker);
      const history = await this.readPaginatedOrFallback(
        process,
        threadId,
        signal,
      );
      // Re-check a full-thread fallback response to close the cwd race between
      // the lightweight marker read and the history read. Only the paginated
      // adapter is synthetic and therefore legitimately has no cwd.
      if (!history.paginated) {
        authorizeMarker?.(markerFromThread(history.thread));
      }
      return normalizeConversationMirrorSnapshot(history.thread, marker, {
        maxEntries: this.maxEntries,
        maxTotalBytes: this.maxTotalBytes,
      });
    } catch (error) {
      if (error instanceof ConversationMirrorError) throw error;
      if (signal?.aborted) throw abortError(signal);
      throw new ConversationMirrorError(
        "read_failed",
        errorMessage(error),
        error,
      );
    }
  }

  private async readPaginatedOrFallback(
    process: CodexProcess,
    threadId: string,
    signal?: AbortSignal,
  ): Promise<{ thread: Record<string, unknown>; paginated: boolean }> {
    const modes = this.historyModes(process);
    let mode = modes.get(threadId) ?? "items";
    if (mode === "items") {
      try {
        const thread = await this.readPaginatedHistory(
          process,
          "thread/items/list",
          threadId,
          signal,
        );
        modes.set(threadId, "items");
        return { thread, paginated: true };
      } catch (error) {
        if (error instanceof ConversationMirrorError) throw error;
        if (signal?.aborted) throw abortError(signal);
        if (!isHistoryPaginationUnavailable(error, "thread/items/list")) {
          throw error;
        }
        mode = "turns";
        modes.set(threadId, mode);
        console.warn(
          `[conversation-mirror] thread/items/list unavailable for thread ${threadId}; trying thread/turns/list: ${errorMessage(error)}`,
        );
      }
    }

    if (mode === "turns" || mode === "turnsLegacy") {
      let turnsError: unknown;
      try {
        const thread = await this.readPaginatedHistory(
          process,
          "thread/turns/list",
          threadId,
          signal,
          { omitItemsView: mode === "turnsLegacy" },
        );
        modes.set(threadId, mode);
        return { thread, paginated: true };
      } catch (error) {
        if (error instanceof ConversationMirrorError) throw error;
        if (signal?.aborted) throw abortError(signal);
        turnsError = error;
      }

      if (
        mode === "turns" &&
        isTurnsItemsViewParameterUnavailable(turnsError)
      ) {
        mode = "turnsLegacy";
        modes.set(threadId, mode);
        console.warn(
          `[conversation-mirror] thread/turns/list itemsView is unavailable for thread ${threadId}; retrying the legacy request and validating a full response: ${errorMessage(turnsError)}`,
        );
        try {
          const thread = await this.readPaginatedHistory(
            process,
            "thread/turns/list",
            threadId,
            signal,
            { omitItemsView: true },
          );
          return { thread, paginated: true };
        } catch (error) {
          if (error instanceof ConversationMirrorError) throw error;
          if (signal?.aborted) throw abortError(signal);
          turnsError = error;
        }
      }

      if (
        !isHistoryPaginationUnavailable(
          turnsError,
          "thread/turns/list",
        ) &&
        !isNonFullTurnsResponseError(turnsError)
      ) {
        throw turnsError;
      }
      modes.set(threadId, "whole");
      console.warn(
        `[conversation-mirror] full paginated history unavailable for thread ${threadId}; using thread/read fallback: ${errorMessage(turnsError)}`,
      );
    }

    return {
      thread: await this.readWholeThread(process, threadId, signal),
      paginated: false,
    };
  }

  private historyModes(
    process: CodexProcess,
  ): Map<string, ConversationMirrorHistoryMode> {
    const existing = this.historyModeByProcess.get(process);
    if (existing) return existing;
    const modes = new Map<string, ConversationMirrorHistoryMode>();
    this.historyModeByProcess.set(process, modes);
    return modes;
  }

  private async readPaginatedHistory(
    process: CodexProcess,
    method: "thread/items/list" | "thread/turns/list",
    threadId: string,
    signal?: AbortSignal,
    options: { omitItemsView?: boolean } = {},
  ): Promise<Record<string, unknown>> {
    const newestFirst: Array<{
      record: Record<string, unknown>;
      turnId?: string;
    }> = [];
    const seenCursors = new Set<string>();
    let cursor: string | null = null;

    for (let pageIndex = 0; pageIndex < this.maxPages; pageIndex += 1) {
      throwIfAborted(signal);
      const response: { data?: unknown; nextCursor?: unknown } =
        await process.requestReadOnlyRpc<{
          data?: unknown;
          nextCursor?: unknown;
        }>(
          method,
          {
            threadId,
            ...(method === "thread/turns/list" && !options.omitItemsView
              ? { itemsView: "full" }
              : {}),
            limit: HISTORY_PAGE_SIZE,
            cursor,
            sortDirection: "desc",
          },
          { timeoutMs: this.rpcTimeoutMs, ...(signal ? { signal } : {}) },
        );
      if (!Array.isArray(response.data)) {
        throw new Error(`${method} returned invalid data`);
      }
      for (const value of response.data) {
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
        newestFirst.push({
          record: historyRecord,
          ...(method === "thread/items/list"
            ? {
                turnId:
                  nonEmptyString(record.turnId) ??
                  nonEmptyString(record.turn_id),
              }
            : {}),
        });
        if (newestFirst.length > this.maxEntries) {
          throw new ConversationMirrorError(
            "history_too_large",
            `Conversation exceeds ${this.maxEntries} bounded history records`,
          );
        }
      }

      const nextCursor: string | null =
        typeof response.nextCursor === "string" && response.nextCursor.length > 0
          ? response.nextCursor
          : null;
      if (!nextCursor) {
        const chronological = newestFirst.reverse();
        return method === "thread/items/list"
          ? {
              id: threadId,
              turns: groupPaginatedItemsByTurn(threadId, chronological),
            }
          : { id: threadId, turns: chronological.map((value) => value.record) };
      }
      if (nextCursor === cursor || seenCursors.has(nextCursor)) {
        throw new Error(`${method} returned a repeated cursor`);
      }
      seenCursors.add(nextCursor);
      cursor = nextCursor;
    }

    throw new ConversationMirrorError(
      "history_too_large",
      `Conversation exceeds ${this.maxPages} history pages`,
    );
  }

  private async readWholeThread(
    process: CodexProcess,
    threadId: string,
    signal?: AbortSignal,
  ): Promise<Record<string, unknown>> {
    const response = await process.requestReadOnlyRpc<unknown>(
      "thread/read",
      { threadId, includeTurns: true },
      { timeoutMs: this.rpcTimeoutMs, ...(signal ? { signal } : {}) },
    );
    return responseThread(response);
  }
}

function groupPaginatedItemsByTurn(
  threadId: string,
  items: Array<{ record: Record<string, unknown>; turnId?: string }>,
): Record<string, unknown>[] {
  const fallbackTurnId = `${threadId}:mirror-items`;
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

interface SnapshotLimits {
  maxEntries: number;
  maxTotalBytes: number;
}

export function normalizeConversationMirrorSnapshot(
  thread: unknown,
  marker?: ConversationMirrorMarker,
  limits: SnapshotLimits = {
    maxEntries: MAX_CONVERSATION_MIRROR_ENTRIES,
    maxTotalBytes: MAX_CONVERSATION_MIRROR_TOTAL_BYTES,
  },
): ConversationMirrorSnapshot {
  const record = recordValue(thread) ?? {};
  const entries: ConversationMirrorEntry[] = [];
  const seenEntryIds = new Set<string>();
  let totalBytes = 0;
  let userTurnOrdinal = 0;

  const turns = Array.isArray(record.turns) ? record.turns : [];
  for (let turnIndex = 0; turnIndex < turns.length; turnIndex += 1) {
    const turn = recordValue(turns[turnIndex]);
    if (!turn) continue;
    const rawTurnId = nonEmptyString(turn.id);
    const turnIdentity =
      rawTurnId ?? `turn-${shortDigest({ ...turn, items: undefined })}`;
    const items = Array.isArray(turn.items) ? turn.items : [];

    for (let itemIndex = 0; itemIndex < items.length; itemIndex += 1) {
      const item = recordValue(items[itemIndex]);
      if (!item) continue;
      const rawItemId = nonEmptyString(item.id);
      const itemIdentity =
        rawItemId ?? `${turnIdentity}:item-${shortDigest(item)}`;
      const converted = conversationMirrorThreadToServerMessages({
        turns: [{ ...turn, items: [item] }],
      });
      const userMessageUuid = converted.some(
        (message) => message.type === "user_input",
      )
        ? codexUserTurnUuid(++userTurnOrdinal)
        : undefined;

      for (let partIndex = 0; partIndex < converted.length; partIndex += 1) {
        const baseEntryId =
          partIndex === 0
            ? itemIdentity
            : `${itemIdentity}:part-${partIndex + 1}`;
        const entryId = uniqueEntryId(baseEntryId, seenEntryIds);

        // Canonicalize nested maps before hashing *and* sending. The mobile
        // store hashes the received JSON envelope, so deterministic insertion
        // order must be present on the wire as well as in this process.
        const message = canonicalJsonValue(
          normalizeRawEnvelope(
            converted[partIndex]!,
            item,
            entryId,
            userMessageUuid,
          ),
        ) as ServerMessage;
        const serialized = jsonString(message);
        const messageBytes = Buffer.byteLength(serialized, "utf8");
        totalBytes += messageBytes;
        entries.push({
          entryId,
          index: entries.length,
          contentHash: sha256(serialized),
          message,
        });

        if (entries.length > limits.maxEntries) {
          throw new ConversationMirrorError(
            "history_too_large",
            `Conversation exceeds ${limits.maxEntries} normalized entries`,
          );
        }
        if (totalBytes > limits.maxTotalBytes) {
          throw new ConversationMirrorError(
            "history_too_large",
            `Conversation exceeds ${limits.maxTotalBytes} normalized bytes`,
          );
        }
      }
    }
  }

  const effectiveMarker = marker ?? markerFromThread(record);
  const revision = sha256(
    jsonString({
      threadStatus: effectiveMarker.threadStatus,
      entries: entries.map((entry) => [
        entry.entryId,
        entry.index,
        entry.contentHash,
      ]),
    }),
  );
  return {
    ...effectiveMarker,
    revision,
    entries,
    totalBytes,
  };
}

function normalizeRawEnvelope(
  source: ServerMessage,
  rawItem: Record<string, unknown>,
  stableId: string,
  userMessageUuid?: string,
): ServerMessage {
  if (source.type === "user_input") {
    const clientMessageId =
      nonEmptyString(rawItem.clientId) ??
      nonEmptyString(rawItem.client_id) ??
      nonEmptyString(rawItem.clientMessageId) ??
      nonEmptyString(rawItem.client_message_id);
    return {
      ...source,
      ...(userMessageUuid ? { userMessageUuid } : {}),
      ...(clientMessageId ? { clientMessageId } : {}),
    };
  }
  if (source.type === "assistant") {
    return {
      ...source,
      message: { ...source.message, id: stableId },
      messageUuid: stableId,
    };
  }
  return source;
}

/**
 * Mirror-local, pure history adapter. It deliberately depends only on the
 * canonical sessions-index foundation, never on another optional feature.
 */
function conversationMirrorThreadToServerMessages(
  thread: unknown,
): ServerMessage[] {
  return codexThreadToSessionHistory(thread).flatMap((message, index) =>
    mirrorHistoryMessageToServerMessages(message, index),
  );
}

function mirrorHistoryMessageToServerMessages(
  history: SessionHistoryMessage,
  index: number,
): ServerMessage[] {
  if (history.role === "user") {
    const text = mirrorHistoryText(history.content);
    if (!text) return [];
    return [
      {
        type: "user_input",
        text,
        ...(history.uuid ? { userMessageUuid: history.uuid } : {}),
        ...(history.isMeta ? { isMeta: true } : {}),
        ...(history.imageCount ? { imageCount: history.imageCount } : {}),
        ...(history.timestamp ? { timestamp: history.timestamp } : {}),
      },
    ];
  }

  if (history.role === "tool_result") {
    const content = mirrorHistoryText(history.content);
    if (!content) return [];
    return [
      {
        type: "tool_result",
        toolUseId:
          history.toolUseId ?? history.uuid ?? `mirror-history-tool-${index}`,
        content,
        ...(history.toolName ? { toolName: history.toolName } : {}),
      },
    ];
  }

  const content = mirrorAssistantContent(history.content);
  if (content.length === 0) return [];
  const id = history.uuid ?? history.rawItemId ?? `mirror-history-${index}`;
  return [
    {
      type: "assistant",
      message: { id, role: "assistant", content, model: "" },
      ...(history.uuid ? { messageUuid: history.uuid } : {}),
    },
  ];
}

function mirrorHistoryText(content: SessionHistoryMessage["content"]): string {
  if (typeof content === "string") return content;
  return content
    .flatMap((item) => {
      if (item.type === "text" && typeof item.text === "string") {
        return [item.text];
      }
      if (item.type === "thinking" && typeof item.thinking === "string") {
        return [item.thinking];
      }
      return [];
    })
    .filter(Boolean)
    .join("\n");
}

function mirrorAssistantContent(
  content: SessionHistoryMessage["content"],
): AssistantContent[] {
  if (typeof content === "string") {
    return content ? [{ type: "text", text: content }] : [];
  }

  const converted: AssistantContent[] = [];
  for (const item of content) {
    if (item.type === "text" && typeof item.text === "string" && item.text) {
      converted.push({ type: "text", text: item.text });
    } else if (
      item.type === "thinking" &&
      typeof item.thinking === "string" &&
      item.thinking
    ) {
      converted.push({ type: "thinking", thinking: item.thinking });
    } else if (
      item.type === "tool_use" &&
      typeof item.id === "string" &&
      typeof item.name === "string"
    ) {
      converted.push({
        type: "tool_use",
        id: item.id,
        name: item.name,
        input: recordValue(item.input) ?? {},
      });
    }
  }
  return converted;
}

export interface ConversationMirrorHandlerOptions {
  markerPollMs?: number;
  fullReconcileMs?: number;
  standaloneIdleMs?: number;
  maxClientWatches?: number;
  maxWatchedThreads?: number;
  maxConcurrentReads?: number;
  maxPollBackoffMs?: number;
  pollJitterRatio?: number;
  reader?: CodexConversationMirrorReader;
}

interface ClientWatch {
  requestId: string;
  lastSnapshot?: ConversationMirrorSnapshot;
}

interface WatchedThread {
  key: string;
  provider: ConversationMirrorProvider;
  providerSessionId: string;
  projectPath: string;
  clients: Map<object, ClientWatch>;
  abortController: AbortController;
  snapshot?: ConversationMirrorSnapshot;
  previousSnapshot?: ConversationMirrorSnapshot;
  reconcilePromise?: Promise<ConversationMirrorSnapshot>;
  timer?: ReturnType<typeof setTimeout>;
  pollInFlight: boolean;
  pollFailureCount: number;
  pollSequence: number;
  lastScheduledDelayMs?: number;
  lastFullAt: number;
}

export class ConversationMirrorFeatureHandler implements LocalFeatureHandler {
  readonly messageTypes = [
    "conversation_mirror_probe",
    "conversation_mirror_sync",
    "conversation_mirror_watch",
    "conversation_mirror_unwatch",
  ] as const;

  private readonly reader: CodexConversationMirrorReader;
  private readonly markerPollMs: number;
  private readonly fullReconcileMs: number;
  private readonly standaloneIdleMs: number;
  private readonly maxClientWatches: number;
  private readonly maxWatchedThreads: number;
  private readonly maxConcurrentReads: number;
  private readonly maxPollBackoffMs: number;
  private readonly pollJitterRatio: number;
  private readonly watches = new Map<string, WatchedThread>();
  /** At most one mirror-owned app-server exists across every watched thread. */
  private ownedProcess?: CodexProcess;
  private ownedProcessPromise?: Promise<CodexProcess>;
  private ownedCleanupTimer?: ReturnType<typeof setTimeout>;
  private readonly failedActiveProcesses = new WeakSet<object>();
  private readonly pendingReadStarts: Array<() => void> = [];
  private activeReadCount = 0;
  private pooledOperationCount = 0;
  private closed = false;

  constructor(
    private readonly runtime: LocalFeatureRuntime,
    options: ConversationMirrorHandlerOptions = {},
  ) {
    this.reader = options.reader ?? new CodexConversationMirrorReader();
    this.markerPollMs = positiveInteger(
      options.markerPollMs,
      DEFAULT_MARKER_POLL_MS,
    );
    this.fullReconcileMs = positiveInteger(
      options.fullReconcileMs,
      DEFAULT_FULL_RECONCILE_MS,
    );
    this.standaloneIdleMs = positiveInteger(
      options.standaloneIdleMs,
      DEFAULT_STANDALONE_IDLE_MS,
    );
    this.maxClientWatches = positiveInteger(
      options.maxClientWatches,
      MAX_CONVERSATION_MIRROR_WATCHES_PER_CLIENT,
    );
    this.maxWatchedThreads = positiveInteger(
      options.maxWatchedThreads,
      MAX_CONVERSATION_MIRROR_WATCHED_THREADS,
    );
    this.maxConcurrentReads = positiveInteger(
      options.maxConcurrentReads,
      DEFAULT_MAX_CONCURRENT_READS,
    );
    this.maxPollBackoffMs = positiveInteger(
      options.maxPollBackoffMs,
      DEFAULT_MAX_POLL_BACKOFF_MS,
    );
    this.pollJitterRatio = boundedNumber(
      options.pollJitterRatio,
      DEFAULT_POLL_JITTER_RATIO,
      0,
      0.5,
    );
  }

  async handle(
    message: LocalFeatureClientMessage,
    context: LocalFeatureHandleContext,
  ): Promise<void> {
    if (!isConversationMirrorRequest(message)) return;
    if (!this.runtime.supports(context.client, "conversation_mirror_event_v1")) {
      // Old clients did not opt in and must not receive an unknown message.
      return;
    }
    if (!this.runtime.bridgeInstanceId) {
      // A host that has not wired persistent identity cannot safely create a
      // durable mobile cache key. Keep the runtime seam optional so unrelated
      // local-feature test doubles remain source-compatible.
      this.runtime.send(context.client, {
        type: "conversation_mirror_event_v1",
        event: "error",
        requestId: message.requestId,
        bridgeInstanceId: "unavailable",
        provider: message.provider,
        providerSessionId: message.providerSessionId,
        errorCode: "invalid_state",
        error: "Bridge instance identity is unavailable",
      });
      return;
    }
    if (this.closed) {
      this.sendError(context.client, message, "invalid_state", "Mirror closed");
      return;
    }

    if (message.type === "conversation_mirror_unwatch") {
      this.unwatch(context.client, message);
      return;
    }
    if (message.provider !== "codex") {
      this.sendError(
        context.client,
        message,
        "unsupported_provider",
        `Conversation mirror does not support ${message.provider} yet`,
      );
      return;
    }
    if (
      this.runtime.isProjectPathAllowed &&
      !this.runtime.isProjectPathAllowed(message.projectPath)
    ) {
      this.sendError(
        context.client,
        message,
        "path_not_allowed",
        "Project path is outside the Bridge allowed directories",
      );
      return;
    }

    try {
      if (message.type === "conversation_mirror_probe") {
        this.sendAccepted(context.client, message);
        const snapshot = await this.getSnapshot(message, context.signal);
        this.runtime.send(context.client, {
          ...this.base(message),
          event: "probe",
          revision: snapshot.revision,
          entryCount: snapshot.entries.length,
          totalBytes: snapshot.totalBytes,
          threadStatus: snapshot.threadStatus,
          notModified: message.knownRevision === snapshot.revision,
        });
        return;
      }

      if (message.type === "conversation_mirror_sync") {
        this.sendAccepted(context.client, message);
        const snapshot = await this.getSnapshot(message, context.signal);
        if (message.knownRevision === snapshot.revision) {
          this.sendNotModified(context.client, message, snapshot);
        } else {
          this.sendSnapshot(context.client, message, snapshot);
        }
        return;
      }

      await this.watch(context.client, message);
    } catch (error) {
      if (!context.signal.aborted) {
        const mirrorError = toMirrorError(error);
        this.sendError(
          context.client,
          message,
          mirrorError.code,
          mirrorError.message,
        );
      }
    }
  }

  capabilitiesChanged(client: object): void {
    if (!this.runtime.supports(client, "conversation_mirror_event_v1")) {
      this.disconnect(client);
    }
  }

  disconnect(client: object): void {
    for (const state of [...this.watches.values()]) {
      state.clients.delete(client);
      if (state.clients.size === 0) this.destroyWatch(state);
    }
  }

  close(): void {
    this.closed = true;
    for (const state of [...this.watches.values()]) this.destroyWatch(state);
    this.watches.clear();
    if (this.ownedCleanupTimer) clearTimeout(this.ownedCleanupTimer);
    this.ownedCleanupTimer = undefined;
    // Reject queued reads without interrupting bounded operations already
    // using the shared reader. Their normal completion owns cleanup.
    this.drainReadQueue();
    this.stopOwnedProcess();
  }

  private async watch(
    client: object,
    message: Extract<
      ConversationMirrorClientMessage,
      { type: "conversation_mirror_watch" }
    >,
  ): Promise<void> {
    const key = this.key(message.provider, message.providerSessionId);
    let state = this.watches.get(key);
    const replacingExistingWatch = state?.clients.has(client) === true;
    if (
      !replacingExistingWatch &&
      this.clientWatchCount(client) >= this.maxClientWatches
    ) {
      throw new ConversationMirrorError(
        "invalid_state",
        `A client may watch at most ${this.maxClientWatches} conversations`,
      );
    }
    if (!state && this.watches.size >= this.maxWatchedThreads) {
      throw new ConversationMirrorError(
        "invalid_state",
        `The Bridge may watch at most ${this.maxWatchedThreads} conversations`,
      );
    }
    if (!state) {
      state = {
        key,
        provider: message.provider,
        providerSessionId: message.providerSessionId,
        projectPath: message.projectPath,
        clients: new Map(),
        abortController: new AbortController(),
        pollInFlight: false,
        pollFailureCount: 0,
        pollSequence: 0,
        lastFullAt: 0,
      };
      this.watches.set(key, state);
    }

    const registration: ClientWatch = { requestId: message.requestId };
    state.clients.set(client, registration);
    try {
      this.sendAccepted(client, message);
      const snapshot = await this.reconcile(state);
      if (state.clients.get(client) !== registration) return;
      this.runtime.send(client, {
        ...this.base(message),
        event: "watching",
        revision: snapshot.revision,
        threadStatus: snapshot.threadStatus,
      });

      if (message.knownRevision === snapshot.revision) {
        this.sendNotModified(client, message, snapshot);
      } else if (
        message.knownRevision &&
        state.previousSnapshot?.revision === message.knownRevision
      ) {
        this.sendPatchOrSnapshot(
          client,
          message,
          state.previousSnapshot,
          snapshot,
        );
      } else {
        this.sendSnapshot(client, message, snapshot);
      }
      registration.lastSnapshot = snapshot;
      this.startPolling(state);
    } catch (error) {
      if (state.clients.get(client) === registration) {
        state.clients.delete(client);
      }
      if (state.clients.size === 0) this.destroyWatch(state);
      throw error;
    }
  }

  private unwatch(
    client: object,
    message: Extract<
      ConversationMirrorClientMessage,
      { type: "conversation_mirror_unwatch" }
    >,
  ): void {
    const state = this.watches.get(
      this.key(message.provider, message.providerSessionId),
    );
    state?.clients.delete(client);
    if (state && state.clients.size === 0) this.destroyWatch(state);
    this.runtime.send(client, { ...this.base(message), event: "unwatched" });
  }

  private async getSnapshot(
    message: Extract<
      ConversationMirrorClientMessage,
      {
        type:
          | "conversation_mirror_probe"
          | "conversation_mirror_sync"
          | "conversation_mirror_watch";
      }
    >,
    signal: AbortSignal,
  ): Promise<ConversationMirrorSnapshot> {
    const key = this.key(message.provider, message.providerSessionId);
    const watched = this.watches.get(key);
    if (watched) {
      return this.reconcile(watched);
    }

    return this.readOneShot(
      message.projectPath,
      message.providerSessionId,
      signal,
    );
  }

  private async readOneShot(
    projectPath: string,
    providerSessionId: string,
    signal: AbortSignal,
  ): Promise<ConversationMirrorSnapshot> {
    const snapshot = await this.withReaderProcess(
      projectPath,
      signal,
      (process) =>
        this.reader.readSnapshot(
          process,
          providerSessionId,
          signal,
          (marker) => this.assertThreadPathAllowed(marker),
        ),
    );
    this.assertThreadPathAllowed(snapshot);
    return snapshot;
  }

  private async reconcile(
    state: WatchedThread,
  ): Promise<ConversationMirrorSnapshot> {
    if (state.reconcilePromise) return state.reconcilePromise;
    const promise = (async () => {
      // A watch request is long-lived. Mark every later full reconciliation as
      // a new transfer boundary so mobile can snapshot its canonical content
      // epoch before the provider read starts. Initial watches already receive
      // `accepted` in watch(), so only established registrations need this.
      for (const [client, registration] of state.clients) {
        if (registration.lastSnapshot == null) continue;
        try {
          this.sendAccepted(
            client,
            this.watchRequest(state, registration),
          );
        } catch {
          if (state.clients.get(client) === registration) {
            state.clients.delete(client);
          }
        }
      }
      if (state.clients.size === 0) this.destroyWatch(state);
      const snapshot = await this.withReaderProcess(
        state.projectPath,
        state.abortController.signal,
        (process) =>
          this.reader.readSnapshot(
            process,
            state.providerSessionId,
            state.abortController.signal,
            (marker) => this.assertThreadPathAllowed(marker),
          ),
      );
      this.assertThreadPathAllowed(snapshot);

      const previous = state.snapshot;
      state.previousSnapshot = previous;
      state.snapshot = snapshot;
      state.lastFullAt = Date.now();
      for (const [client, registration] of state.clients) {
        const clientSnapshot = registration.lastSnapshot;
        if (!clientSnapshot) continue;
        const request = this.watchRequest(state, registration);
        try {
          if (clientSnapshot.revision === snapshot.revision) {
            this.sendNotModified(client, request, snapshot);
          } else {
            this.sendPatchOrSnapshot(
              client,
              request,
              clientSnapshot,
              snapshot,
            );
          }
          registration.lastSnapshot = snapshot;
        } catch (error) {
          // One slow/broken client (or one payload that cannot be represented
          // within the negotiated event limit) must not prevent the shared
          // snapshot from reaching every other watcher. End only this watch;
          // the client can explicitly re-watch after handling the error.
          const mirrorError = toMirrorError(error);
          try {
            this.sendError(
              client,
              request,
              mirrorError.code,
              mirrorError.message,
            );
          } catch {}
          if (state.clients.get(client) === registration) {
            state.clients.delete(client);
          }
        }
      }
      if (state.clients.size === 0) this.destroyWatch(state);
      return snapshot;
    })().finally(() => {
      if (state.reconcilePromise === promise) state.reconcilePromise = undefined;
    });
    state.reconcilePromise = promise;
    return promise;
  }

  private watchRequest(
    state: WatchedThread,
    registration: ClientWatch,
  ): Extract<
    ConversationMirrorClientMessage,
    { type: "conversation_mirror_watch" }
  > {
    return {
      type: "conversation_mirror_watch",
      protocolVersion: 1,
      requestId: registration.requestId,
      provider: state.provider,
      providerSessionId: state.providerSessionId,
      projectPath: state.projectPath,
    };
  }

  private startPolling(state: WatchedThread): void {
    if (state.timer || state.clients.size === 0) return;
    this.schedulePoll(state);
  }

  private schedulePoll(state: WatchedThread): void {
    if (
      state.timer ||
      state.clients.size === 0 ||
      this.watches.get(state.key) !== state
    ) {
      return;
    }
    const delayMs = this.nextPollDelayMs(state);
    state.lastScheduledDelayMs = delayMs;
    state.timer = setTimeout(() => {
      state.timer = undefined;
      void this.poll(state).finally(() => {
        this.schedulePoll(state);
      });
    }, delayMs);
    state.timer.unref?.();
  }

  private nextPollDelayMs(state: WatchedThread): number {
    const exponent = Math.min(state.pollFailureCount, 16);
    const backoffMs = Math.min(
      this.maxPollBackoffMs,
      this.markerPollMs * 2 ** exponent,
    );
    const unit = deterministicJitterUnit(state.key, state.pollSequence);
    state.pollSequence += 1;
    const factor = 1 + (unit * 2 - 1) * this.pollJitterRatio;
    return Math.max(
      1,
      Math.min(this.maxPollBackoffMs, Math.round(backoffMs * factor)),
    );
  }

  private async poll(state: WatchedThread): Promise<void> {
    if (
      state.pollInFlight ||
      state.clients.size === 0 ||
      this.watches.get(state.key) !== state
    ) {
      return;
    }
    state.pollInFlight = true;
    try {
      const marker = await this.withReaderProcess(
        state.projectPath,
        state.abortController.signal,
        (process) =>
          this.reader.readMarker(
            process,
            state.providerSessionId,
            state.abortController.signal,
          ),
      );
      this.assertThreadPathAllowed(marker);
      const markerChanged = marker.digest !== state.snapshot?.digest;
      const fullDue = Date.now() - state.lastFullAt >= this.fullReconcileMs;
      if (markerChanged || fullDue) {
        await this.reconcile(state);
      }
      state.pollFailureCount = 0;
    } catch (error) {
      state.pollFailureCount = Math.min(state.pollFailureCount + 1, 16);
      console.warn(
        `[conversation-mirror] watch poll failed for ${state.providerSessionId}: ${errorMessage(error)}`,
      );
    } finally {
      state.pollInFlight = false;
    }
  }

  private async withReaderProcess<T>(
    projectPath: string,
    signal: AbortSignal,
    operation: (process: CodexProcess) => Promise<T>,
  ): Promise<T> {
    return this.withReadPermit(signal, () => {
      throwIfAborted(signal);
      return this.withReaderProcessUnlocked(projectPath, operation);
    });
  }

  /**
   * The active Codex process and the single mirror-owned process are shared by
   * every watch. Bound all marker and full-history work globally so many
   * watches cannot stampede either process at the same poll boundary.
   */
  private withReadPermit<T>(
    signal: AbortSignal,
    operation: () => Promise<T>,
  ): Promise<T> {
    return new Promise<T>((resolve, reject) => {
      let queued = true;
      const removeAbortListener = (): void => {
        signal.removeEventListener("abort", abortQueuedRead);
      };
      const abortQueuedRead = (): void => {
        if (!queued) return;
        const index = this.pendingReadStarts.indexOf(start);
        if (index < 0) return;
        this.pendingReadStarts.splice(index, 1);
        queued = false;
        removeAbortListener();
        reject(abortError(signal));
      };
      const start = (): void => {
        if (!queued) return;
        queued = false;
        removeAbortListener();
        if (this.closed) {
          reject(
            new ConversationMirrorError(
              "invalid_state",
              "Mirror closed while a reader operation was queued",
            ),
          );
          return;
        }
        if (signal.aborted) {
          reject(abortError(signal));
          return;
        }
        this.activeReadCount += 1;
        void Promise.resolve()
          .then(operation)
          .then(resolve, reject)
          .finally(() => {
            this.activeReadCount -= 1;
            this.drainReadQueue();
          });
      };
      if (signal.aborted) {
        queued = false;
        reject(abortError(signal));
        return;
      }
      signal.addEventListener("abort", abortQueuedRead, { once: true });
      this.pendingReadStarts.push(start);
      this.drainReadQueue();
    });
  }

  private drainReadQueue(): void {
    while (
      this.activeReadCount < this.maxConcurrentReads &&
      this.pendingReadStarts.length > 0
    ) {
      this.pendingReadStarts.shift()?.();
    }
  }

  private async withReaderProcessUnlocked<T>(
    projectPath: string,
    operation: (process: CodexProcess) => Promise<T>,
  ): Promise<T> {
    this.pooledOperationCount += 1;
    this.cancelOwnedCleanup();
    try {
      const active = this.runtime.getActiveCodexProcess();
      if (active && !this.failedActiveProcesses.has(active)) {
        try {
          return await operation(active);
        } catch (error) {
          if (!isReaderTransportFailure(error)) throw error;
          this.failedActiveProcesses.add(active);
          console.warn(
            `[conversation-mirror] active Codex reader failed; using shared standalone: ${errorMessage(error)}`,
          );
        }
      }

      const owned = await this.getOwnedProcess(projectPath);
      try {
        return await operation(owned);
      } catch (error) {
        // RPC domain errors (missing thread, invalid request, size limit) say
        // nothing about process health. Only transport/process-death failures
        // invalidate the shared reader used by other watches.
        if (isReaderTransportFailure(error)) {
          this.invalidateOwnedProcess(owned);
        }
        throw error;
      }
    } finally {
      this.pooledOperationCount -= 1;
      this.scheduleOwnedCleanup();
    }
  }

  private async getOwnedProcess(projectPath: string): Promise<CodexProcess> {
    if (this.ownedProcess) return this.ownedProcess;
    if (this.ownedProcessPromise) return this.ownedProcessPromise;
    const promise = this.runtime
      .createStandaloneCodexProcess(DEFAULT_RPC_TIMEOUT_MS, projectPath)
      .then((process) => {
        if (this.closed) {
          process.stop();
          throw new ConversationMirrorError(
            "invalid_state",
            "Mirror closed while its reader was starting",
          );
        }
        this.ownedProcess = process;
        return process;
      })
      .finally(() => {
        if (this.ownedProcessPromise === promise) {
          this.ownedProcessPromise = undefined;
        }
      });
    this.ownedProcessPromise = promise;
    return promise;
  }

  private invalidateOwnedProcess(process: CodexProcess): void {
    if (this.ownedProcess !== process) return;
    this.ownedProcess = undefined;
    process.stop();
  }

  private stopOwnedProcess(): void {
    const process = this.ownedProcess;
    this.ownedProcess = undefined;
    process?.stop();
  }

  private cancelOwnedCleanup(): void {
    if (this.ownedCleanupTimer) clearTimeout(this.ownedCleanupTimer);
    this.ownedCleanupTimer = undefined;
  }

  private scheduleOwnedCleanup(): void {
    if (
      !this.ownedProcess ||
      this.ownedCleanupTimer ||
      this.pooledOperationCount > 0 ||
      this.watches.size > 0
    ) {
      return;
    }
    this.ownedCleanupTimer = setTimeout(() => {
      this.ownedCleanupTimer = undefined;
      if (
        this.pooledOperationCount === 0 &&
        this.watches.size === 0
      ) {
        this.stopOwnedProcess();
      }
    }, this.standaloneIdleMs);
    this.ownedCleanupTimer.unref?.();
  }

  private destroyWatch(state: WatchedThread): void {
    if (this.watches.get(state.key) === state) this.watches.delete(state.key);
    if (state.timer) clearTimeout(state.timer);
    state.timer = undefined;
    state.clients.clear();
    if (!state.abortController.signal.aborted) {
      const reason = new Error("Conversation mirror watch closed");
      reason.name = "AbortError";
      state.abortController.abort(reason);
    }
    this.scheduleOwnedCleanup();
  }

  private clientWatchCount(client: object): number {
    let count = 0;
    for (const state of this.watches.values()) {
      if (state.clients.has(client)) count += 1;
    }
    return count;
  }

  private assertThreadPathAllowed(marker: ConversationMirrorMarker): void {
    const cwd = marker.threadCwd;
    if (!this.runtime.isProjectPathAllowed) return;
    if (!cwd) {
      throw new ConversationMirrorError(
        "path_not_allowed",
        "Codex did not report the conversation working directory",
      );
    }
    if (!this.runtime.isProjectPathAllowed(cwd)) {
      throw new ConversationMirrorError(
        "path_not_allowed",
        "The conversation belongs to a directory outside the Bridge allowed directories",
      );
    }
  }

  private sendSnapshot(
    client: object,
    request: ConversationMirrorClientMessage,
    snapshot: ConversationMirrorSnapshot,
  ): void {
    const pages = chunkConversationMirrorEntries(request, snapshot, {
      bridgeInstanceId: this.requireBridgeInstanceId(),
    });
    this.runtime.send(client, {
      ...this.base(request),
      event: "snapshot_begin",
      revision: snapshot.revision,
      entryCount: snapshot.entries.length,
      pageCount: pages.length,
      totalBytes: snapshot.totalBytes,
      threadStatus: snapshot.threadStatus,
    });
    for (let pageIndex = 0; pageIndex < pages.length; pageIndex += 1) {
      this.runtime.send(client, {
        ...this.base(request),
        event: "snapshot_page",
        revision: snapshot.revision,
        pageIndex,
        pageCount: pages.length,
        entries: pages[pageIndex]!,
      });
    }
    this.runtime.send(client, {
      ...this.base(request),
      event: "snapshot_complete",
      revision: snapshot.revision,
      entryCount: snapshot.entries.length,
      threadStatus: snapshot.threadStatus,
    });
  }

  private sendAccepted(
    client: object,
    request: ConversationMirrorClientMessage,
  ): void {
    this.runtime.send(client, { ...this.base(request), event: "accepted" });
  }

  private sendNotModified(
    client: object,
    request: ConversationMirrorClientMessage,
    snapshot: ConversationMirrorSnapshot,
  ): void {
    this.runtime.send(client, {
      ...this.base(request),
      event: "not_modified",
      revision: snapshot.revision,
      threadStatus: snapshot.threadStatus,
    });
  }

  private sendPatchOrSnapshot(
    client: object,
    request: ConversationMirrorClientMessage,
    previous: ConversationMirrorSnapshot,
    next: ConversationMirrorSnapshot,
  ): void {
    const patch = diffSnapshots(previous, next);
    const event: ConversationMirrorEventMessage = {
      ...this.base(request),
      event: "patch",
      baseRevision: previous.revision,
      revision: next.revision,
      upserts: patch.upserts,
      deletes: patch.deletes,
      threadStatus: next.threadStatus,
    };
    if (jsonBytes(event) > MAX_CONVERSATION_MIRROR_EVENT_BYTES) {
      this.sendSnapshot(client, request, next);
      return;
    }
    this.runtime.send(client, event);
  }

  private sendError(
    client: object,
    request: ConversationMirrorClientMessage,
    errorCode: MirrorErrorCode,
    error: string,
  ): void {
    this.runtime.send(client, {
      ...this.base(request),
      event: "error",
      errorCode,
      error: error.slice(0, 2_048),
    });
  }

  private base(request: ConversationMirrorClientMessage): {
    type: "conversation_mirror_event_v1";
    requestId: string;
    bridgeInstanceId: string;
    provider: ConversationMirrorProvider;
    providerSessionId: string;
  } {
    return {
      type: "conversation_mirror_event_v1",
      requestId: request.requestId,
      bridgeInstanceId: this.requireBridgeInstanceId(),
      provider: request.provider,
      providerSessionId: request.providerSessionId,
    };
  }

  private key(provider: ConversationMirrorProvider, sessionId: string): string {
    return `${this.requireBridgeInstanceId()}\u0000${provider}\u0000${sessionId}`;
  }

  private requireBridgeInstanceId(): string {
    const bridgeInstanceId = this.runtime.bridgeInstanceId;
    if (!bridgeInstanceId) {
      throw new ConversationMirrorError(
        "invalid_state",
        "Bridge instance identity is unavailable",
      );
    }
    return bridgeInstanceId;
  }
}

export function diffSnapshots(
  previous: ConversationMirrorSnapshot,
  next: ConversationMirrorSnapshot,
): { upserts: ConversationMirrorEntry[]; deletes: string[] } {
  const oldById = new Map(
    previous.entries.map((entry) => [entry.entryId, entry]),
  );
  const newIds = new Set(next.entries.map((entry) => entry.entryId));
  const upserts = next.entries.filter((entry) => {
    const old = oldById.get(entry.entryId);
    return (
      !old || old.contentHash !== entry.contentHash || old.index !== entry.index
    );
  });
  const deletes = previous.entries
    .filter((entry) => !newIds.has(entry.entryId))
    .map((entry) => entry.entryId);
  return { upserts, deletes };
}

export function chunkConversationMirrorEntries(
  request: Pick<
    ConversationMirrorClientMessage,
    "requestId" | "provider" | "providerSessionId"
  >,
  snapshot: ConversationMirrorSnapshot,
  runtime: { bridgeInstanceId: string },
): ConversationMirrorEntry[][] {
  if (snapshot.entries.length === 0) return [];
  const pages: ConversationMirrorEntry[][] = [];
  let page: ConversationMirrorEntry[] = [];

  const eventBytes = (entries: ConversationMirrorEntry[]): number =>
    jsonBytes({
      type: "conversation_mirror_event_v1",
      event: "snapshot_page",
      requestId: request.requestId,
      bridgeInstanceId: runtime.bridgeInstanceId,
      provider: request.provider,
      providerSessionId: request.providerSessionId,
      revision: snapshot.revision,
      pageIndex: 999_999,
      pageCount: 999_999,
      entries,
    });

  for (const entry of snapshot.entries) {
    if (eventBytes([entry]) > MAX_CONVERSATION_MIRROR_EVENT_BYTES) {
      throw new ConversationMirrorError(
        "entry_too_large",
        `Conversation entry ${entry.entryId} exceeds the 512 KiB event limit`,
      );
    }
    const candidate = [...page, entry];
    if (
      page.length >= MAX_CONVERSATION_MIRROR_PAGE_ENTRIES ||
      eventBytes(candidate) > MAX_CONVERSATION_MIRROR_EVENT_BYTES
    ) {
      pages.push(page);
      page = [entry];
    } else {
      page = candidate;
    }
  }
  if (page.length > 0) pages.push(page);
  return pages;
}

function markerFromThread(thread: Record<string, unknown>): ConversationMirrorMarker {
  const threadStatus = normalizeThreadStatus(thread.status);
  const threadCwd = nonEmptyString(thread.cwd);
  return {
    threadStatus,
    ...(threadCwd ? { threadCwd } : {}),
    digest: sha256(
      jsonString({
        id: thread.id ?? null,
        updatedAt: thread.updatedAt ?? thread.updated_at ?? null,
        status: thread.status ?? null,
        preview: thread.preview ?? null,
        name: thread.name ?? null,
      }),
    ),
  };
}

function normalizeThreadStatus(value: unknown): ConversationMirrorThreadStatus {
  if (typeof value === "string") return value;
  const record = recordValue(value);
  return nonEmptyString(record?.type) ?? nonEmptyString(record?.status) ?? null;
}

function responseThread(value: unknown): Record<string, unknown> {
  const response = recordValue(value);
  const thread = recordValue(response?.thread);
  if (!thread) {
    throw new Error("thread/read returned no thread");
  }
  return thread;
}

function isConversationMirrorRequest(
  message: LocalFeatureClientMessage,
): message is ConversationMirrorClientMessage {
  return message.type.startsWith("conversation_mirror_");
}

function toMirrorError(error: unknown): ConversationMirrorError {
  return error instanceof ConversationMirrorError
    ? error
    : new ConversationMirrorError("read_failed", errorMessage(error));
}

function isReaderTransportFailure(error: unknown): boolean {
  if (error instanceof ConversationMirrorError) {
    return error.code === "read_failed"
      ? isReaderTransportFailure(error.originalError)
      : false;
  }
  // A JSON-RPC error is a valid response from a live process. This includes
  // thread-not-found, method-not-found, validation, and other domain failures.
  if (error instanceof CodexRpcError) {
    return /(?:timed?\s*out|timeout|aborted because codex app-server exited)/i.test(
      error.message,
    );
  }
  if (!(error instanceof Error)) return false;
  if (error.name === "AbortError") return false;
  return /(?:app-server|transport|connection|socket|pipe|econn|epipe).*(?:exit|stop|clos|reset|refus|fail|broken|down|not running)|(?:exit|stop|clos|reset|refus|fail|broken|down|not running).*(?:app-server|transport|connection|socket|pipe|econn|epipe)|(?:timed?\s*out|timeout)/i.test(
    error.message,
  );
}

function isHistoryPaginationUnavailable(
  error: unknown,
  method: "thread/items/list" | "thread/turns/list",
): boolean {
  if (error instanceof CodexRpcError) {
    let detail = error.message;
    try {
      detail += ` ${JSON.stringify(error.data)}`;
    } catch {}
    if (error.method === method && error.code === -32601) {
      return true;
    }
    if (error.method === method && unsupportedOrInvalidMessage(detail)) {
      return true;
    }
  }
  const message = errorMessage(error);
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
  return /itemsview|items_view|items view/i.test(message) &&
    unsupportedOrInvalidMessage(message);
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

function abortError(signal: AbortSignal): Error {
  return signal.reason instanceof Error
    ? signal.reason
    : new Error("Conversation mirror request aborted");
}

function throwIfAborted(signal?: AbortSignal): void {
  if (signal?.aborted) throw abortError(signal);
}

function positiveInteger(value: number | undefined, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value) && value > 0
    ? Math.floor(value)
    : fallback;
}

function boundedNumber(
  value: number | undefined,
  fallback: number,
  minimum: number,
  maximum: number,
): number {
  return typeof value === "number" && Number.isFinite(value)
    ? Math.min(maximum, Math.max(minimum, value))
    : fallback;
}

function deterministicJitterUnit(key: string, sequence: number): number {
  const prefix = sha256(`${key}\u0000${sequence}`).slice(0, 8);
  return Number.parseInt(prefix, 16) / 0xffff_ffff;
}

function recordValue(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function nonEmptyString(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function uniqueEntryId(base: string, seen: Set<string>): string {
  let candidate = base;
  let duplicate = 1;
  while (seen.has(candidate)) {
    candidate = `${base}:duplicate-${duplicate}`;
    duplicate += 1;
  }
  seen.add(candidate);
  return candidate;
}

function jsonString(value: unknown): string {
  return JSON.stringify(canonicalJsonValue(value)) ?? "null";
}

function canonicalJsonValue(
  value: unknown,
  ancestors: Set<object> = new Set(),
): unknown {
  if (value === null || typeof value !== "object") return value;
  if (ancestors.has(value)) {
    throw new TypeError("Cannot canonicalize a circular JSON value");
  }
  ancestors.add(value);
  try {
    const toJSON = (value as { toJSON?: unknown }).toJSON;
    if (typeof toJSON === "function") {
      return canonicalJsonValue(toJSON.call(value), ancestors);
    }
    if (Array.isArray(value)) {
      return value.map((entry) => {
        const canonical = canonicalJsonValue(entry, ancestors);
        return canonical === undefined ? null : canonical;
      });
    }
    const result: Record<string, unknown> = Object.create(null);
    for (const key of Object.keys(value).sort()) {
      const canonical = canonicalJsonValue(
        (value as Record<string, unknown>)[key],
        ancestors,
      );
      if (canonical !== undefined) result[key] = canonical;
    }
    return result;
  } finally {
    ancestors.delete(value);
  }
}

function jsonBytes(value: unknown): number {
  return Buffer.byteLength(jsonString(value), "utf8");
}

function sha256(value: string): string {
  return createHash("sha256").update(value, "utf8").digest("hex");
}

function shortDigest(value: unknown): string {
  return sha256(jsonString(value)).slice(0, 24);
}

function errorMessage(error: unknown): string {
  if (error instanceof Error) return error.message;
  if (typeof error === "string") return error;
  const record = recordValue(error);
  return typeof record?.message === "string" ? record.message : String(error);
}
