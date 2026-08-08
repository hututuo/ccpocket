import { createHash } from "node:crypto";

import {
  selectTurnAwareHistoryWindow,
  TURN_AWARE_HISTORY_ROOT_TURNS,
} from "../history-window.js";
import type { ServerMessage } from "../parser.js";
import {
  getAllRecentSessions,
  getCodexSessionHistory,
  getSessionHistory,
  type SessionIndexEntry,
} from "../sessions-index.js";
import type { SessionCatalogChange } from "../session-catalog-monitor.js";
import { sessionHistoryToServerMessages } from "./codex-thread-history.js";
import {
  CONVERSATION_CONTENT_EVENT_CAPABILITY,
  type ConversationContentClientMessage,
  type ConversationContentEntry,
  type ConversationContentProvider,
  type ConversationContentServerMessage,
  type ConversationContentTarget,
} from "./slots/conversation-content-protocol.js";
import type {
  LocalFeatureClientDeliveryMode,
  LocalFeatureHandleContext,
  LocalFeatureHandler,
  LocalFeatureRuntime,
  LocalFeatureSession,
} from "./runtime.js";

const DEFAULT_HOT_CONVERSATION_LIMIT = 10;
const DEFAULT_MAX_CATALOG_ENTRIES = 10_000;
const DEFAULT_MAX_CACHED_CONVERSATIONS = 32;
const DEFAULT_COLD_SCAN_MIN_MS = 45_000;
const DEFAULT_COLD_SCAN_MAX_MS = 5 * 60_000;
const DEFAULT_MAX_PAGE_ENTRIES = 32;
const DEFAULT_MAX_PAGE_BYTES = 256 * 1024;
const DEFAULT_MAX_PATCH_BYTES = 256 * 1024;
const DEFAULT_MAX_MESSAGE_TEXT_BYTES = 256 * 1024;
const DEFAULT_MAX_SNAPSHOT_BYTES = 4 * 1024 * 1024;
const DEFAULT_MAX_CACHED_TARGET_BYTES = 8 * 1024 * 1024;
const DEFAULT_MAX_CACHED_BYTES = 32 * 1024 * 1024;
const MIN_MAX_MESSAGE_TEXT_BYTES = 64;
const MIN_MAX_SNAPSHOT_BYTES = 1024;
const DEFAULT_EVENT_BATCH_MS = 75;
const DEFAULT_LIVE_RUNTIME_BATCH_MS = 250;
const QUEUE_PRIORITY_AGING_INTERVAL = 3;
const MAX_TOOL_RESULT_TEXT = 64 * 1024;
const MAX_ASSISTANT_TEXT = 128 * 1024;
const MAX_TOOL_INPUT_JSON = 32 * 1024;
const MAX_ASSISTANT_CONTENT_BLOCKS = 1024;
const MAX_SAFE_JSON_DEPTH = 64;
const MAX_SAFE_JSON_NODES = 10_000;
const TRUNCATED_TEXT_SUFFIX = "\n…[truncated; load details on demand]";

type ConversationKey = string;

interface ClientSubscription {
  subscriptionId: string;
  cursors: Map<ConversationKey, string>;
  pendingRevisions: Map<ConversationKey, string>;
  focusedKey?: ConversationKey;
  interactive: boolean;
}

interface CatalogRecord {
  target: ConversationContentTarget;
  modified: string;
}

interface QueueTask extends ConversationContentTarget {
  key: ConversationKey;
  priority: number;
  sequence: number;
  enqueuedAfterTask: number;
  reason: string;
}

interface PendingQueueTask extends ConversationContentTarget {
  key: ConversationKey;
  priority: number;
  reason: string;
}

export interface ConversationContentSnapshotEntry extends ConversationContentEntry {
  sourceIndex: number;
}

export interface ConversationContentLatestTurnGap {
  /** Stable provider turn identity when the provider exposes one. */
  turnId?: string;
  /** Raw provider entries whose full payload is not present in this snapshot. */
  missingEntryCount: number;
  /** At least one retained entry was reduced to a bounded text/tool shell. */
  payloadOmitted: boolean;
  /** The first raw entry that an on-demand repair must cover. */
  firstMissingSourceIndex?: number;
  /** The read-only request that can repair this gap without resuming the thread. */
  repair: "items_page" | "turns_page";
}

export interface ConversationContentSnapshot extends ConversationContentTarget {
  revision: string;
  entries: ConversationContentSnapshotEntry[];
  hasEarlier: boolean;
  /// Opaque app-server/provider cursor for the next older turn page.
  turnsNextCursor?: string | null;
  /**
   * Whether the newest provider turn is represented without detail loss.
   *
   * A false value never means the existing entries are unsafe to render. It
   * means Mobile should use `latestTurnGap.repair` if the user asks to reveal
   * the omitted current-turn payload instead of advancing the older-turn
   * cursor and silently skipping it.
   */
  latestTurnComplete: boolean;
  latestTurnGap?: ConversationContentLatestTurnGap;
  sourceEntryCount: number;
  /** Exact UTF-8 JSON size used for deterministic cache accounting. */
  cacheBytes: number;
}

interface ConversationContentSyncOptions {
  catalogReader?: () => Promise<SessionIndexEntry[]>;
  historyReader?: (
    target: ConversationContentTarget,
  ) => Promise<ServerMessage[]>;
  hotConversationLimit?: number;
  maxCatalogEntries?: number;
  maxCachedConversations?: number;
  coldScanMinMs?: number;
  coldScanMaxMs?: number;
  maxPageEntries?: number;
  maxPageBytes?: number;
  maxPatchBytes?: number;
  maxMessageTextBytes?: number;
  maxSnapshotBytes?: number;
  maxCachedTargetBytes?: number;
  maxCachedBytes?: number;
}

/**
 * One Bridge-owned scheduler for every durable conversation.
 *
 * Mobile sends one foreground subscription and ACKs committed revisions. The
 * scheduler owns provider change detection, bounded catalog compensation,
 * de-duplication, history reads, patch calculation and multi-client reuse.
 * It never creates one runtime, watcher or timer per conversation.
 */
export class ConversationContentSyncFeatureHandler implements LocalFeatureHandler {
  readonly messageTypes = [
    "conversation_content_subscribe",
    "conversation_content_focus",
    "conversation_content_ack",
    "conversation_content_unsubscribe",
  ] as const;

  private readonly catalogReader: () => Promise<SessionIndexEntry[]>;
  private readonly historyReader: (
    target: ConversationContentTarget,
  ) => Promise<ServerMessage[]>;
  private readonly hotConversationLimit: number;
  private readonly maxCatalogEntries: number;
  private readonly maxCachedConversations: number;
  private readonly coldScanMinMs: number;
  private readonly coldScanMaxMs: number;
  private readonly maxPageEntries: number;
  private readonly maxPageBytes: number;
  private readonly maxPatchBytes: number;
  private readonly maxMessageTextBytes: number;
  private readonly maxSnapshotBytes: number;
  private readonly maxCachedTargetBytes: number;
  private readonly maxCachedBytes: number;

  private readonly clients = new Map<object, ClientSubscription>();
  private readonly catalog = new Map<ConversationKey, CatalogRecord>();
  private readonly queue = new Map<ConversationKey, QueueTask>();
  private readonly inFlightKeys = new Set<ConversationKey>();
  private readonly inFlightDirty = new Map<ConversationKey, PendingQueueTask>();
  private readonly pendingLiveRuntime = new Map<
    ConversationKey,
    PendingQueueTask
  >();
  private readonly snapshots = new Map<
    ConversationKey,
    ConversationContentSnapshot[]
  >();
  private queueSequence = 0;
  private completedTaskCount = 0;
  private cachedSnapshotBytes = 0;
  private draining = false;
  private drainTimer?: ReturnType<typeof setTimeout>;
  private liveRuntimeTimer?: ReturnType<typeof setTimeout>;
  private catalogFlight?: Promise<void>;
  private catalogDirty = false;
  private catalogInitialized = false;
  private coldScanTimer?: ReturnType<typeof setTimeout>;
  private closed = false;

  constructor(
    private readonly runtime: LocalFeatureRuntime,
    options: ConversationContentSyncOptions = {},
  ) {
    this.maxCatalogEntries = positiveInteger(
      options.maxCatalogEntries,
      DEFAULT_MAX_CATALOG_ENTRIES,
    );
    this.catalogReader =
      options.catalogReader ??
      (async () =>
        (
          await getAllRecentSessions({
            limit: this.maxCatalogEntries,
            offset: 0,
            metadataOnly: true,
          })
        ).sessions);
    this.historyReader =
      options.historyReader ?? readDurableConversationHistory;
    this.hotConversationLimit = positiveInteger(
      options.hotConversationLimit,
      DEFAULT_HOT_CONVERSATION_LIMIT,
    );
    this.maxCachedConversations = positiveInteger(
      options.maxCachedConversations,
      DEFAULT_MAX_CACHED_CONVERSATIONS,
    );
    this.coldScanMinMs = positiveInteger(
      options.coldScanMinMs,
      DEFAULT_COLD_SCAN_MIN_MS,
    );
    this.coldScanMaxMs = Math.max(
      this.coldScanMinMs,
      positiveInteger(options.coldScanMaxMs, DEFAULT_COLD_SCAN_MAX_MS),
    );
    this.maxPageEntries = positiveInteger(
      options.maxPageEntries,
      DEFAULT_MAX_PAGE_ENTRIES,
    );
    this.maxPageBytes = positiveInteger(
      options.maxPageBytes,
      DEFAULT_MAX_PAGE_BYTES,
    );
    this.maxPatchBytes = positiveInteger(
      options.maxPatchBytes,
      DEFAULT_MAX_PATCH_BYTES,
    );
    this.maxMessageTextBytes = Math.max(
      MIN_MAX_MESSAGE_TEXT_BYTES,
      positiveInteger(
        options.maxMessageTextBytes,
        DEFAULT_MAX_MESSAGE_TEXT_BYTES,
      ),
    );
    this.maxSnapshotBytes = Math.max(
      MIN_MAX_SNAPSHOT_BYTES,
      positiveInteger(options.maxSnapshotBytes, DEFAULT_MAX_SNAPSHOT_BYTES),
    );
    this.maxCachedBytes = positiveInteger(
      options.maxCachedBytes,
      DEFAULT_MAX_CACHED_BYTES,
    );
    this.maxCachedTargetBytes = Math.min(
      this.maxCachedBytes,
      positiveInteger(
        options.maxCachedTargetBytes,
        DEFAULT_MAX_CACHED_TARGET_BYTES,
      ),
    );
  }

  async handle(
    message: ConversationContentClientMessage,
    context: LocalFeatureHandleContext,
  ): Promise<void> {
    if (
      !this.runtime.supports(
        context.client,
        CONVERSATION_CONTENT_EVENT_CAPABILITY,
      )
    ) {
      return;
    }
    if (this.closed) return;

    if (message.type === "conversation_content_subscribe") {
      this.subscribe(context.client, message);
      return;
    }
    if (message.type === "conversation_content_ack") {
      this.ack(context.client, message);
      return;
    }
    if (message.type === "conversation_content_focus") {
      this.focus(context.client, message);
      return;
    }
    this.unsubscribe(context.client, message);
  }

  capabilitiesChanged(client: object): void {
    if (!this.runtime.supports(client, CONVERSATION_CONTENT_EVENT_CAPABILITY)) {
      this.disconnect(client);
    }
  }

  clientDeliveryModeChanged(
    client: object,
    mode: LocalFeatureClientDeliveryMode,
  ): void {
    const subscription = this.clients.get(client);
    if (!subscription) return;
    subscription.interactive = mode === "interactive";
    subscription.pendingRevisions.clear();
    if (!subscription.interactive) {
      if (!this.hasInteractiveClients()) {
        this.queue.clear();
        this.inFlightDirty.clear();
        this.pendingLiveRuntime.clear();
        this.cancelDrainTimer();
        this.cancelLiveRuntimeTimer();
        this.cancelColdScan();
      }
      return;
    }
    this.warmSubscription(subscription);
  }

  sessionCatalogChanged(change: SessionCatalogChange): void {
    if (!this.hasInteractiveClients()) return;
    if (change.provider && change.providerSessionId) {
      const target = {
        provider: change.provider,
        providerSessionId: change.providerSessionId,
      };
      this.enqueue(target, this.focusPriority(target, 1), "provider_change");
      return;
    }
    void this.refreshCatalog();
  }

  sessionMessage(session: LocalFeatureSession, _message: ServerMessage): void {
    if (!this.hasInteractiveClients()) return;
    const provider = session.provider;
    if (provider !== "claude" && provider !== "codex") return;
    const providerSessionId =
      this.runtime.getProviderSessionId?.(session) ??
      (provider === "codex"
        ? this.runtime.getCodexThreadId(session)
        : undefined);
    if (!providerSessionId) return;
    const target: ConversationContentTarget = { provider, providerSessionId };
    this.enqueueLiveRuntime(
      target,
      this.focusPriority(target, 1),
      "live_runtime",
    );
  }

  disconnect(client: object): void {
    this.clients.delete(client);
    if (!this.hasInteractiveClients()) {
      this.queue.clear();
      this.inFlightDirty.clear();
      this.pendingLiveRuntime.clear();
      this.cancelDrainTimer();
      this.cancelLiveRuntimeTimer();
      this.cancelColdScan();
    }
  }

  close(): void {
    this.closed = true;
    this.clients.clear();
    this.queue.clear();
    this.inFlightDirty.clear();
    this.pendingLiveRuntime.clear();
    this.snapshots.clear();
    this.cachedSnapshotBytes = 0;
    this.cancelDrainTimer();
    this.cancelLiveRuntimeTimer();
    this.cancelColdScan();
  }

  private subscribe(
    client: object,
    message: Extract<
      ConversationContentClientMessage,
      { type: "conversation_content_subscribe" }
    >,
  ): void {
    const bridgeInstanceId = this.runtime.bridgeInstanceId;
    if (!bridgeInstanceId) {
      this.send(client, {
        type: CONVERSATION_CONTENT_EVENT_CAPABILITY,
        event: "error",
        subscriptionId: message.requestId,
        bridgeInstanceId: "unavailable",
        requestId: message.requestId,
        errorCode: "invalid_state",
        error: "Bridge instance identity is unavailable",
      });
      return;
    }

    const cursors = new Map<ConversationKey, string>();
    for (const cursor of message.knownRevisions) {
      cursors.set(targetKey(cursor), cursor.revision);
    }
    const subscription: ClientSubscription = {
      subscriptionId: message.requestId,
      cursors,
      pendingRevisions: new Map(),
      focusedKey: message.focused ? targetKey(message.focused) : undefined,
      interactive:
        (this.runtime.getClientDeliveryMode?.(client) ?? "interactive") ===
        "interactive",
    };
    this.clients.set(client, subscription);
    this.send(client, {
      type: CONVERSATION_CONTENT_EVENT_CAPABILITY,
      event: "subscribed",
      requestId: message.requestId,
      subscriptionId: message.requestId,
      bridgeInstanceId,
      hotConversationLimit: this.hotConversationLimit,
    });
    if (subscription.interactive) this.warmSubscription(subscription);
  }

  private ack(
    client: object,
    message: Extract<
      ConversationContentClientMessage,
      { type: "conversation_content_ack" }
    >,
  ): void {
    const subscription = this.clients.get(client);
    if (
      !subscription ||
      subscription.subscriptionId !== message.subscriptionId
    ) {
      return;
    }
    const key = targetKey(message);
    const pending = subscription.pendingRevisions.get(key);
    if (pending !== message.revision) return;
    subscription.pendingRevisions.delete(key);
    subscription.cursors.set(key, message.revision);
    const latest = this.latestSnapshot(key);
    if (latest && latest.revision !== message.revision) {
      this.publishSnapshotToClient(client, subscription, key, latest);
    }
  }

  private focus(
    client: object,
    message: Extract<
      ConversationContentClientMessage,
      { type: "conversation_content_focus" }
    >,
  ): void {
    const subscription = this.clients.get(client);
    if (
      !subscription ||
      subscription.subscriptionId !== message.subscriptionId
    ) {
      this.sendError(
        client,
        message.subscriptionId,
        message.requestId,
        "stale_subscription",
        "Conversation content subscription is no longer active",
      );
      return;
    }
    subscription.focusedKey = message.focused
      ? targetKey(message.focused)
      : undefined;
    this.send(client, {
      type: CONVERSATION_CONTENT_EVENT_CAPABILITY,
      event: "focus_applied",
      requestId: message.requestId,
      subscriptionId: subscription.subscriptionId,
      bridgeInstanceId: this.runtime.bridgeInstanceId!,
      ...(message.focused ? { focused: message.focused } : {}),
    });
    if (message.focused && subscription.interactive) {
      this.enqueue(message.focused, 0, "focused");
    }
  }

  private unsubscribe(
    client: object,
    message: Extract<
      ConversationContentClientMessage,
      { type: "conversation_content_unsubscribe" }
    >,
  ): void {
    const subscription = this.clients.get(client);
    if (
      !subscription ||
      subscription.subscriptionId !== message.subscriptionId
    ) {
      return;
    }
    this.clients.delete(client);
    this.send(client, {
      type: CONVERSATION_CONTENT_EVENT_CAPABILITY,
      event: "unsubscribed",
      requestId: message.requestId,
      subscriptionId: message.subscriptionId,
      bridgeInstanceId: this.runtime.bridgeInstanceId!,
    });
    if (!this.hasInteractiveClients()) {
      this.queue.clear();
      this.inFlightDirty.clear();
      this.pendingLiveRuntime.clear();
      this.cancelDrainTimer();
      this.cancelLiveRuntimeTimer();
      this.cancelColdScan();
    }
  }

  private warmSubscription(subscription: ClientSubscription): void {
    if (!subscription.interactive || this.closed) return;
    if (subscription.focusedKey) {
      const focused = parseTargetKey(subscription.focusedKey);
      if (focused) this.enqueue(focused, 0, "focused");
    }
    if (this.catalogInitialized) this.reuseOrEnqueueHotCatalog();
    void this.refreshCatalog();
  }

  private refreshCatalog(): Promise<void> {
    if (this.closed || !this.hasInteractiveClients()) {
      return Promise.resolve();
    }
    if (this.catalogFlight) {
      this.catalogDirty = true;
      return this.catalogFlight;
    }
    const flight = (async () => {
      do {
        this.catalogDirty = false;
        const sessions = await this.catalogReader();
        if (this.closed || !this.hasInteractiveClients()) return;
        this.applyCatalog(sessions);
      } while (this.catalogDirty);
    })()
      .catch((error) => {
        this.sendFocusedErrors(
          "catalog_read_failed",
          error instanceof Error ? error.message : String(error),
        );
      })
      .finally(() => {
        if (this.catalogFlight === flight) this.catalogFlight = undefined;
        this.scheduleColdScan();
      });
    this.catalogFlight = flight;
    return flight;
  }

  private applyCatalog(sessions: readonly SessionIndexEntry[]): void {
    const wasInitialized = this.catalogInitialized;
    const next = new Map<ConversationKey, CatalogRecord>();
    for (const session of sessions.slice(0, this.maxCatalogEntries)) {
      const target = {
        provider: session.provider,
        providerSessionId: session.sessionId,
      };
      next.set(targetKey(target), {
        target,
        modified: session.modified,
      });
    }

    if (this.catalogInitialized) {
      for (const [key, record] of next) {
        const previous = this.catalog.get(key);
        if (!previous || previous.modified !== record.modified) {
          this.enqueue(
            record.target,
            this.focusPriority(record.target, 3),
            previous ? "cold_revision" : "new_conversation",
          );
        }
      }
    }
    this.catalog.clear();
    for (const [key, record] of next) this.catalog.set(key, record);
    this.catalogInitialized = true;
    if (!wasInitialized) this.reuseOrEnqueueHotCatalog();
  }

  private reuseOrEnqueueHotCatalog(): void {
    let count = 0;
    for (const [key, record] of this.catalog) {
      if (count >= this.hotConversationLimit) break;
      const cached = this.latestSnapshot(key);
      if (cached && !this.inFlightKeys.has(key) && !this.queue.has(key)) {
        this.publishSnapshot(key, cached);
      } else {
        this.enqueue(
          record.target,
          this.focusPriority(record.target, 2),
          "hot_catalog",
        );
      }
      count += 1;
    }
  }

  private enqueue(
    target: ConversationContentTarget,
    priority: number,
    reason: string,
  ): void {
    if (this.closed || !this.hasInteractiveClients()) return;
    const key = targetKey(target);
    if (this.inFlightKeys.has(key)) {
      this.mergePendingTask(this.inFlightDirty, target, priority, reason);
      return;
    }
    const existing = this.queue.get(key);
    if (existing) {
      const previousPriority = existing.priority;
      existing.priority = Math.min(existing.priority, priority);
      existing.reason = priority < previousPriority ? reason : existing.reason;
      return;
    }
    this.queue.set(key, {
      ...target,
      key,
      priority,
      sequence: ++this.queueSequence,
      enqueuedAfterTask: this.completedTaskCount,
      reason,
    });
    this.scheduleDrain();
  }

  private enqueueLiveRuntime(
    target: ConversationContentTarget,
    priority: number,
    reason: string,
  ): void {
    if (this.closed || !this.hasInteractiveClients()) return;
    this.mergePendingTask(this.pendingLiveRuntime, target, priority, reason);
    if (this.liveRuntimeTimer) return;
    this.liveRuntimeTimer = setTimeout(() => {
      this.liveRuntimeTimer = undefined;
      const pending = [...this.pendingLiveRuntime.values()];
      this.pendingLiveRuntime.clear();
      for (const task of pending) {
        this.enqueue(task, task.priority, task.reason);
      }
    }, DEFAULT_LIVE_RUNTIME_BATCH_MS);
    this.liveRuntimeTimer.unref?.();
  }

  private mergePendingTask(
    pending: Map<ConversationKey, PendingQueueTask>,
    target: ConversationContentTarget,
    priority: number,
    reason: string,
  ): void {
    const key = targetKey(target);
    const existing = pending.get(key);
    if (existing) {
      const previousPriority = existing.priority;
      existing.priority = Math.min(existing.priority, priority);
      existing.reason = priority < previousPriority ? reason : existing.reason;
      return;
    }
    pending.set(key, { ...target, key, priority, reason });
  }

  private scheduleDrain(): void {
    if (this.draining || this.closed) return;
    const hasImmediate = [...this.queue.values()].some(
      (task) => task.priority === 0,
    );
    if (hasImmediate) {
      this.cancelDrainTimer();
      this.draining = true;
      queueMicrotask(() => void this.drain());
      return;
    }
    if (this.drainTimer) return;
    this.drainTimer = setTimeout(() => {
      this.drainTimer = undefined;
      if (this.draining || this.closed) return;
      this.draining = true;
      void this.drain();
    }, DEFAULT_EVENT_BATCH_MS);
    this.drainTimer.unref?.();
  }

  private cancelDrainTimer(): void {
    if (this.drainTimer) clearTimeout(this.drainTimer);
    this.drainTimer = undefined;
  }

  private cancelLiveRuntimeTimer(): void {
    if (this.liveRuntimeTimer) clearTimeout(this.liveRuntimeTimer);
    this.liveRuntimeTimer = undefined;
  }

  private async drain(): Promise<void> {
    try {
      while (!this.closed && this.hasInteractiveClients()) {
        const task = this.nextTask();
        if (!task) break;
        this.queue.delete(task.key);
        this.inFlightKeys.add(task.key);
        try {
          const messages = await this.historyReader(task);
          if (this.closed || !this.hasInteractiveClients()) break;
          const snapshot = buildConversationContentSnapshot(task, messages, {
            maxMessageTextBytes: this.maxMessageTextBytes,
            maxSnapshotBytes: this.maxSnapshotBytes,
          });
          this.publishSnapshot(task.key, snapshot);
          this.rememberSnapshot(task.key, snapshot);
        } catch (error) {
          this.sendTargetErrors(
            task,
            "history_read_failed",
            error instanceof Error ? error.message : String(error),
          );
        } finally {
          this.inFlightKeys.delete(task.key);
          this.completedTaskCount += 1;
          const dirty = this.inFlightDirty.get(task.key);
          if (dirty) {
            this.inFlightDirty.delete(task.key);
            this.enqueue(dirty, dirty.priority, dirty.reason);
          }
        }
      }
    } finally {
      this.draining = false;
      if (!this.closed && this.hasInteractiveClients() && this.queue.size > 0) {
        this.scheduleDrain();
      }
    }
  }

  private nextTask(): QueueTask | undefined {
    let selected: QueueTask | undefined;
    let selectedPriority = Number.POSITIVE_INFINITY;
    for (const task of this.queue.values()) {
      const tasksWaited = Math.max(
        0,
        this.completedTaskCount - task.enqueuedAfterTask,
      );
      const agedPriority = Math.max(
        0,
        task.priority - Math.floor(tasksWaited / QUEUE_PRIORITY_AGING_INTERVAL),
      );
      if (
        !selected ||
        agedPriority < selectedPriority ||
        (agedPriority === selectedPriority && task.sequence < selected.sequence)
      ) {
        selected = task;
        selectedPriority = agedPriority;
      }
    }
    return selected;
  }

  private publishSnapshot(
    key: ConversationKey,
    snapshot: ConversationContentSnapshot,
  ): void {
    for (const [client, subscription] of [...this.clients]) {
      this.publishSnapshotToClient(client, subscription, key, snapshot);
    }
  }

  private publishSnapshotToClient(
    client: object,
    subscription: ClientSubscription,
    key: ConversationKey,
    snapshot: ConversationContentSnapshot,
    allowDeferral = true,
  ): void {
    if (!subscription.interactive || !this.clientReady(client)) return;
    const pendingRevision = subscription.pendingRevisions.get(key);
    if (pendingRevision === snapshot.revision) return;
    const canReplayAfterAck =
      snapshot.cacheBytes <= this.maxCachedTargetBytes &&
      snapshot.cacheBytes <= this.maxCachedBytes;
    if (pendingRevision && allowDeferral && canReplayAfterAck) return;
    const knownRevision = subscription.cursors.get(key);
    if (knownRevision === snapshot.revision) return;
    const base = knownRevision
      ? this.findSnapshot(key, knownRevision)
      : undefined;
    const patched =
      base != null && this.sendPatch(client, subscription, base, snapshot);
    if (!patched) this.sendSnapshot(client, subscription, snapshot);
    subscription.pendingRevisions.set(key, snapshot.revision);
  }

  private sendPatch(
    client: object,
    subscription: ClientSubscription,
    base: ConversationContentSnapshot,
    snapshot: ConversationContentSnapshot,
  ): boolean {
    const baseById = new Map(
      base.entries.map((entry) => [entry.entryId, entry]),
    );
    const nextIds = new Set(snapshot.entries.map((entry) => entry.entryId));
    const upserts = snapshot.entries.filter((entry) => {
      const previous = baseById.get(entry.entryId);
      return (
        !previous ||
        previous.contentHash !== entry.contentHash ||
        previous.index !== entry.index
      );
    });
    const deletes = base.entries
      .filter((entry) => !nextIds.has(entry.entryId))
      .map((entry) => entry.entryId);
    const message: ConversationContentServerMessage = {
      ...this.eventBase(subscription),
      ...snapshotTarget(snapshot),
      event: "patch",
      baseRevision: base.revision,
      revision: snapshot.revision,
      upserts: upserts.map(toWireConversationContentEntry),
      deletes,
      hasEarlier: snapshot.hasEarlier,
      sourceEntryCount: snapshot.sourceEntryCount,
    };
    if (
      Buffer.byteLength(JSON.stringify(message), "utf8") > this.maxPatchBytes
    ) {
      return false;
    }
    this.send(client, message);
    return true;
  }

  private sendSnapshot(
    client: object,
    subscription: ClientSubscription,
    snapshot: ConversationContentSnapshot,
  ): void {
    const pageEnvelopeBytes = Buffer.byteLength(
      JSON.stringify({
        ...this.eventBase(subscription),
        ...snapshotTarget(snapshot),
        event: "snapshot_page",
        revision: snapshot.revision,
        pageIndex: Number.MAX_SAFE_INTEGER,
        pageCount: Number.MAX_SAFE_INTEGER,
        entries: [],
      }),
      "utf8",
    );
    const pages = paginateConversationContentEntries(
      snapshot.entries,
      this.maxPageEntries,
      this.maxPageBytes,
      pageEnvelopeBytes,
    );
    this.send(client, {
      ...this.eventBase(subscription),
      ...snapshotTarget(snapshot),
      event: "snapshot_begin",
      revision: snapshot.revision,
      entryCount: snapshot.entries.length,
      pageCount: pages.length,
      hasEarlier: snapshot.hasEarlier,
      sourceEntryCount: snapshot.sourceEntryCount,
    });
    for (const [pageIndex, entries] of pages.entries()) {
      this.send(client, {
        ...this.eventBase(subscription),
        ...snapshotTarget(snapshot),
        event: "snapshot_page",
        revision: snapshot.revision,
        pageIndex,
        pageCount: pages.length,
        entries: entries.map(toWireConversationContentEntry),
      });
    }
    this.send(client, {
      ...this.eventBase(subscription),
      ...snapshotTarget(snapshot),
      event: "snapshot_complete",
      revision: snapshot.revision,
      entryCount: snapshot.entries.length,
      hasEarlier: snapshot.hasEarlier,
      sourceEntryCount: snapshot.sourceEntryCount,
    });
  }

  private eventBase(subscription: ClientSubscription) {
    return {
      type: CONVERSATION_CONTENT_EVENT_CAPABILITY,
      subscriptionId: subscription.subscriptionId,
      bridgeInstanceId: this.runtime.bridgeInstanceId!,
    } as const;
  }

  private rememberSnapshot(
    key: ConversationKey,
    snapshot: ConversationContentSnapshot,
  ): void {
    const previous = this.snapshots.get(key) ?? [];
    const revisions = [
      ...previous
        .filter((value) => value.revision !== snapshot.revision)
        .slice(-1),
      snapshot,
    ];
    this.removeCachedTarget(key);

    let targetBytes = revisions.reduce(
      (total, value) => total + value.cacheBytes,
      0,
    );
    while (revisions.length > 1 && targetBytes > this.maxCachedTargetBytes) {
      targetBytes -= revisions.shift()!.cacheBytes;
    }
    if (
      revisions.length === 0 ||
      targetBytes > this.maxCachedTargetBytes ||
      targetBytes > this.maxCachedBytes
    ) {
      return;
    }

    this.snapshots.set(key, revisions);
    this.cachedSnapshotBytes += targetBytes;
    while (
      this.snapshots.size > this.maxCachedConversations ||
      this.cachedSnapshotBytes > this.maxCachedBytes
    ) {
      const oldest = this.snapshots.keys().next().value;
      if (!oldest) break;
      this.evictCachedTarget(oldest);
    }
  }

  private evictCachedTarget(key: ConversationKey): void {
    const latest = this.snapshots.get(key)?.at(-1);
    if (latest) {
      for (const [client, subscription] of [...this.clients]) {
        if (
          subscription.pendingRevisions.has(key) &&
          subscription.pendingRevisions.get(key) !== latest.revision
        ) {
          this.publishSnapshotToClient(
            client,
            subscription,
            key,
            latest,
            false,
          );
        }
      }
    }
    this.removeCachedTarget(key);
  }

  private removeCachedTarget(key: ConversationKey): void {
    const existing = this.snapshots.get(key);
    if (!existing) return;
    for (const snapshot of existing) {
      this.cachedSnapshotBytes -= snapshot.cacheBytes;
    }
    this.cachedSnapshotBytes = Math.max(0, this.cachedSnapshotBytes);
    this.snapshots.delete(key);
  }

  private findSnapshot(
    key: ConversationKey,
    revision: string,
  ): ConversationContentSnapshot | undefined {
    const values = this.snapshots.get(key);
    const snapshot = values?.find((value) => value.revision === revision);
    if (snapshot && values) this.touchCachedTarget(key, values);
    return snapshot;
  }

  private latestSnapshot(
    key: ConversationKey,
  ): ConversationContentSnapshot | undefined {
    const values = this.snapshots.get(key);
    const snapshot = values?.at(-1);
    if (snapshot && values) this.touchCachedTarget(key, values);
    return snapshot;
  }

  private touchCachedTarget(
    key: ConversationKey,
    values: ConversationContentSnapshot[],
  ): void {
    this.snapshots.delete(key);
    this.snapshots.set(key, values);
  }

  private focusPriority(
    target: ConversationContentTarget,
    fallback: number,
  ): number {
    const key = targetKey(target);
    for (const subscription of this.clients.values()) {
      if (subscription.interactive && subscription.focusedKey === key) return 0;
    }
    return fallback;
  }

  private scheduleColdScan(): void {
    this.cancelColdScan();
    if (this.closed || !this.hasInteractiveClients()) return;
    const scaled = this.coldScanMinMs + this.catalog.size * 20;
    const delay = Math.min(this.coldScanMaxMs, scaled);
    this.coldScanTimer = setTimeout(() => {
      this.coldScanTimer = undefined;
      void this.refreshCatalog();
    }, delay);
    this.coldScanTimer.unref?.();
  }

  private cancelColdScan(): void {
    if (this.coldScanTimer) clearTimeout(this.coldScanTimer);
    this.coldScanTimer = undefined;
  }

  private hasInteractiveClients(): boolean {
    for (const subscription of this.clients.values()) {
      if (subscription.interactive) return true;
    }
    return false;
  }

  private clientReady(client: object): boolean {
    return (
      (this.runtime.isClientOpen?.(client) ?? true) &&
      this.runtime.supports(client, CONVERSATION_CONTENT_EVENT_CAPABILITY)
    );
  }

  private sendFocusedErrors(errorCode: string, error: string): void {
    for (const [client, subscription] of this.clients) {
      if (!subscription.interactive || !subscription.focusedKey) continue;
      const target = parseTargetKey(subscription.focusedKey);
      if (!target) continue;
      this.sendError(
        client,
        subscription.subscriptionId,
        undefined,
        errorCode,
        error,
        target,
      );
    }
  }

  private sendTargetErrors(
    target: ConversationContentTarget,
    errorCode: string,
    error: string,
  ): void {
    const key = targetKey(target);
    for (const [client, subscription] of this.clients) {
      if (!subscription.interactive || subscription.focusedKey !== key)
        continue;
      this.sendError(
        client,
        subscription.subscriptionId,
        undefined,
        errorCode,
        error,
        target,
      );
    }
  }

  private sendError(
    client: object,
    subscriptionId: string,
    requestId: string | undefined,
    errorCode: string,
    error: string,
    target?: ConversationContentTarget,
  ): void {
    this.send(client, {
      type: CONVERSATION_CONTENT_EVENT_CAPABILITY,
      event: "error",
      subscriptionId,
      bridgeInstanceId: this.runtime.bridgeInstanceId ?? "unavailable",
      ...(requestId ? { requestId } : {}),
      ...(target ?? {}),
      errorCode,
      error,
    });
  }

  private send(
    client: object,
    message: ConversationContentServerMessage,
  ): void {
    if (!this.clientReady(client)) return;
    this.runtime.send(client, message);
  }
}

export async function readDurableConversationHistory(
  target: ConversationContentTarget,
): Promise<ServerMessage[]> {
  const history =
    target.provider === "codex"
      ? await getCodexSessionHistory(target.providerSessionId)
      : await getSessionHistory(target.providerSessionId);
  return sessionHistoryToServerMessages(history, {
    idPrefix: `conversation-content-${target.provider}`,
  });
}

export function buildConversationContentSnapshot(
  target: ConversationContentTarget,
  rawMessages: readonly ServerMessage[],
  limits: {
    maxMessageTextBytes: number;
    maxSnapshotBytes: number;
    preserveLatestRootTurnTools?: boolean;
  },
): ConversationContentSnapshot {
  const firstRelevantIndex = latestRootTurnStart(
    rawMessages,
    TURN_AWARE_HISTORY_ROOT_TURNS,
  );
  const latestTurnStart = latestRootTurnStart(rawMessages, 1);
  const latestTurnId = providerTurnId(rawMessages.slice(latestTurnStart));
  const source: Array<{ sourceIndex: number; message: ServerMessage }> = [];
  for (
    let sourceIndex = firstRelevantIndex;
    sourceIndex < rawMessages.length;
    sourceIndex += 1
  ) {
    source.push({
      sourceIndex,
      message: rawMessages[sourceIndex]!,
    });
  }
  const selected = selectTurnAwareHistoryWindow(source, {
    preserveLatestRootTurnTools: limits.preserveLatestRootTurnTools,
  });
  let candidates = prepareSnapshotEntries(
    selected,
    limits.maxMessageTextBytes,
    limits.maxSnapshotBytes,
  );

  // The ordinary fast path retains the existing exact window. Only if the
  // serialized 512 KiB budget is exceeded do we project heavy tool payloads
  // into stable historyToolDetailGaps. This keeps the current user/final/
  // thinking/process spine together rather than cutting into the newest turn
  // from the front.
  const initialSnapshotTooLarge =
    candidates === undefined ||
    materializeCandidateSnapshot(
      target,
      candidates,
      rawMessages,
      latestTurnStart,
      latestTurnId,
    ).cacheBytes > limits.maxSnapshotBytes;
  if (initialSnapshotTooLarge) {
    const latestSelected = selected.filter(
      (entry) => entry.sourceIndex >= latestTurnStart,
    );
    const preparedLatest = prepareSnapshotEntries(
      latestSelected,
      limits.maxMessageTextBytes,
      limits.maxSnapshotBytes,
    );
    if (
      preparedLatest &&
      materializeCandidateSnapshot(
        target,
        preparedLatest,
        rawMessages,
        latestTurnStart,
        latestTurnId,
      ).cacheBytes <= limits.maxSnapshotBytes
    ) {
      candidates = preparedLatest;
    } else {
      const compactionStages = [
        { envelopeEntries: 300, messageBytes: limits.maxMessageTextBytes },
        { envelopeEntries: 128, messageBytes: 8 * 1024 },
        { envelopeEntries: 64, messageBytes: 4 * 1024 },
        { envelopeEntries: 32, messageBytes: 2 * 1024 },
        { envelopeEntries: 16, messageBytes: 1024 },
        { envelopeEntries: 8, messageBytes: 512 },
        { envelopeEntries: 4, messageBytes: 256 },
        { envelopeEntries: 2, messageBytes: 128 },
        { envelopeEntries: 0, messageBytes: MIN_MAX_MESSAGE_TEXT_BYTES },
      ] as const;
      let compacted: PreparedSnapshotEntry[] | undefined;
      for (const stage of compactionStages) {
        const projected = selectTurnAwareHistoryWindow(source, {
          preserveLatestRootTurnTools: false,
          toolCalls: 0,
          envelopeEntries: stage.envelopeEntries,
        });
        const projectedLatest = projected.filter(
          (entry) => entry.sourceIndex >= latestTurnStart,
        );
        const prepared = prepareSnapshotEntries(
          projectedLatest,
          Math.min(limits.maxMessageTextBytes, stage.messageBytes),
          limits.maxSnapshotBytes,
        );
        if (!prepared) continue;
        if (
          materializeCandidateSnapshot(
            target,
            prepared,
            rawMessages,
            latestTurnStart,
            latestTurnId,
          ).cacheBytes <= limits.maxSnapshotBytes
        ) {
          compacted = prepared;
          break;
        }
      }
      if (!compacted) {
        throw new Error(
          "Latest conversation turn structure exceeds safe snapshot byte budget",
        );
      }
      candidates = compacted;
    }
  }
  if (!candidates) {
    throw new Error("Conversation snapshot projection did not produce entries");
  }

  const latestCandidates = candidates.filter(
    (entry) => entry.sourceIndex >= latestTurnStart,
  );
  const olderCandidates = candidates.filter(
    (entry) => entry.sourceIndex < latestTurnStart,
  );
  const entries = [...latestCandidates];
  let estimatedBytes =
    materializeCandidateSnapshot(
      target,
      latestCandidates,
      rawMessages,
      latestTurnStart,
      latestTurnId,
    ).cacheBytes + 64;
  for (let index = olderCandidates.length - 1; index >= 0; index -= 1) {
    const candidate = olderCandidates[index]!;
    const separatorBytes = entries.length === 0 ? 0 : 1;
    if (
      estimatedBytes + separatorBytes + candidate.serializedEntryBytes >
      limits.maxSnapshotBytes
    ) {
      break;
    }
    entries.unshift(candidate);
    estimatedBytes += separatorBytes + candidate.serializedEntryBytes;
  }
  let snapshot = materializeCandidateSnapshot(
    target,
    entries,
    rawMessages,
    latestTurnStart,
    latestTurnId,
  );
  while (
    snapshot.cacheBytes > limits.maxSnapshotBytes &&
    entries.length > latestCandidates.length
  ) {
    entries.shift();
    snapshot = materializeCandidateSnapshot(
      target,
      entries,
      rawMessages,
      latestTurnStart,
      latestTurnId,
    );
  }
  if (snapshot.cacheBytes > limits.maxSnapshotBytes) {
    throw new Error(
      "Conversation snapshot exceeds safe serialized byte budget",
    );
  }
  return snapshot;
}

interface PreparedSnapshotEntry extends ConversationContentSnapshotEntry {
  payloadOmitted: boolean;
  serializedEntryBytes: number;
}

function prepareSnapshotEntries(
  values: readonly { sourceIndex: number; message: ServerMessage }[],
  maxMessageTextBytes: number,
  maxSnapshotBytes: number,
): PreparedSnapshotEntry[] | undefined {
  const usedIds = new Map<string, number>();
  const entries: PreparedSnapshotEntry[] = [];
  let serializedEntriesBytes = 2;
  for (const value of values) {
    const bounded = boundHistoryMessage(value.message, maxMessageTextBytes);
    const message = bounded.message;
    const serialized = safeJsonSerialize(message, maxSnapshotBytes);
    if (!serialized) {
      throw new Error(
        "Conversation message exceeds safe serialized byte budget",
      );
    }
    const baseId = messageIdentity(
      message,
      value.sourceIndex,
      serialized.value,
    );
    const occurrence = (usedIds.get(baseId) ?? 0) + 1;
    usedIds.set(baseId, occurrence);
    const entryId = occurrence === 1 ? baseId : `${baseId}:${occurrence}`;
    const entry: ConversationContentSnapshotEntry = {
      entryId,
      index: value.sourceIndex,
      sourceIndex: value.sourceIndex,
      contentHash: sha256(serialized.value),
      message,
    };
    const prepared = {
      ...entry,
      payloadOmitted:
        bounded.payloadOmitted || messageContainsHistoryGap(message),
      serializedEntryBytes: Buffer.byteLength(JSON.stringify(entry), "utf8"),
    };
    const addition =
      (entries.length === 0 ? 0 : 1) + prepared.serializedEntryBytes;
    if (serializedEntriesBytes + addition > maxSnapshotBytes) {
      return undefined;
    }
    entries.push(prepared);
    serializedEntriesBytes += addition;
  }
  return entries;
}

function materializeCandidateSnapshot(
  target: ConversationContentTarget,
  preparedEntries: readonly PreparedSnapshotEntry[],
  rawMessages: readonly ServerMessage[],
  latestTurnStart: number,
  latestTurnId?: string,
): ConversationContentSnapshot {
  const entries = preparedEntries.map(
    ({ payloadOmitted: _, serializedEntryBytes: __, ...entry }) => entry,
  );
  const presentLatestIndexes = new Set(
    preparedEntries
      .filter((entry) => entry.sourceIndex >= latestTurnStart)
      .map((entry) => entry.sourceIndex),
  );
  const missingLatestIndexes: number[] = [];
  for (
    let sourceIndex = latestTurnStart;
    sourceIndex < rawMessages.length;
    sourceIndex += 1
  ) {
    if (!presentLatestIndexes.has(sourceIndex)) {
      missingLatestIndexes.push(sourceIndex);
    }
  }
  const payloadOmitted = preparedEntries.some(
    (entry) => entry.sourceIndex >= latestTurnStart && entry.payloadOmitted,
  );
  const latestTurnComplete =
    missingLatestIndexes.length === 0 && !payloadOmitted;
  const latestTurnGap = latestTurnComplete
    ? undefined
    : {
        ...(latestTurnId ? { turnId: latestTurnId } : {}),
        missingEntryCount: missingLatestIndexes.length,
        payloadOmitted,
        ...(missingLatestIndexes[0] !== undefined
          ? { firstMissingSourceIndex: missingLatestIndexes[0] }
          : {}),
        repair:
          target.provider === "codex" && latestTurnId
            ? ("items_page" as const)
            : ("turns_page" as const),
      };
  const hasEarlier =
    entries.length < rawMessages.length ||
    (entries[0]?.sourceIndex ?? rawMessages.length) > 0 ||
    !latestTurnComplete;
  return materializeSnapshot(
    target,
    entries,
    hasEarlier,
    rawMessages.length,
    latestTurnComplete,
    latestTurnGap,
  );
}

function providerTurnId(
  messages: readonly ServerMessage[],
): string | undefined {
  for (const message of messages) {
    if (
      (message.type === "user_input" ||
        message.type === "assistant" ||
        message.type === "tool_result") &&
      message.historyTurnId?.trim()
    ) {
      return message.historyTurnId.trim();
    }
  }
  // A user UUID (or source index) is only a Bridge-local grouping key. Never
  // advertise it as an app-server turn id: thread/items/list would reject that
  // synthetic identity. Without authoritative historyTurnId provenance the
  // safe repair is a fresh latest-turn page.
  return undefined;
}

function messageContainsHistoryGap(message: ServerMessage): boolean {
  return (
    message.type === "assistant" &&
    (message.historyToolDetailGaps?.length ?? 0) > 0
  );
}

function latestRootTurnStart(
  messages: readonly ServerMessage[],
  rootTurns: number,
): number {
  let seen = 0;
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    if (messages[index]?.type !== "user_input") continue;
    seen += 1;
    if (seen === rootTurns) return index;
  }
  return 0;
}

function materializeSnapshot(
  target: ConversationContentTarget,
  entries: ConversationContentSnapshotEntry[],
  hasEarlier: boolean,
  sourceEntryCount: number,
  latestTurnComplete = true,
  latestTurnGap?: ConversationContentLatestTurnGap,
): ConversationContentSnapshot {
  const revision = sha256(
    JSON.stringify({
      sourceEntryCount,
      hasEarlier,
      latestTurnComplete,
      latestTurnGap,
      entries: entries.map((entry) => [
        entry.entryId,
        entry.index,
        entry.contentHash,
      ]),
    }),
  );
  const value = {
    ...target,
    revision,
    entries,
    hasEarlier,
    latestTurnComplete,
    ...(latestTurnGap ? { latestTurnGap } : {}),
    sourceEntryCount,
  };
  let cacheBytes = Buffer.byteLength(JSON.stringify(value), "utf8");
  for (;;) {
    const measured = Buffer.byteLength(
      JSON.stringify({ ...value, cacheBytes }),
      "utf8",
    );
    if (measured === cacheBytes) return { ...value, cacheBytes };
    cacheBytes = measured;
  }
}

interface BoundedHistoryMessage {
  message: ServerMessage;
  payloadOmitted: boolean;
}

function boundHistoryMessage(
  message: ServerMessage,
  maxMessageTextBytes: number,
): BoundedHistoryMessage {
  const budget = { remaining: maxMessageTextBytes };
  if (message.type === "user_input") {
    const text = takeBoundedText(message.text, budget, maxMessageTextBytes);
    return {
      message: { ...message, text },
      payloadOmitted: text !== message.text,
    };
  }
  if (message.type === "tool_result") {
    const content = takeBoundedText(
      message.content,
      budget,
      MAX_TOOL_RESULT_TEXT,
    );
    return {
      message: { ...message, content },
      payloadOmitted: content !== message.content,
    };
  }
  if (message.type === "tool_use_summary") {
    const summary = takeBoundedText(
      message.summary,
      budget,
      maxMessageTextBytes,
    );
    return {
      message: { ...message, summary },
      payloadOmitted: summary !== message.summary,
    };
  }
  if (message.type !== "assistant") {
    return { message, payloadOmitted: false };
  }
  if (message.message.content.length > MAX_ASSISTANT_CONTENT_BLOCKS) {
    throw new Error(
      `Assistant message exceeds ${MAX_ASSISTANT_CONTENT_BLOCKS} content blocks`,
    );
  }
  let payloadOmitted = false;
  return {
    message: {
      ...message,
      message: {
        ...message.message,
        content: message.message.content.map((content) => {
          if (content.type === "text") {
            const text = takeBoundedText(
              content.text,
              budget,
              MAX_ASSISTANT_TEXT,
            );
            payloadOmitted ||= text !== content.text;
            return { ...content, text };
          }
          if (content.type === "thinking") {
            const thinking = takeBoundedText(
              content.thinking,
              budget,
              MAX_ASSISTANT_TEXT,
            );
            payloadOmitted ||= thinking !== content.thinking;
            return { ...content, thinking };
          }
          if (content.type !== "tool_use") return content;
          const encoded = safeJsonSerialize(
            content.input,
            Math.min(MAX_TOOL_INPUT_JSON, budget.remaining),
          );
          if (encoded) {
            budget.remaining -= encoded.bytes;
            return content;
          }
          const replacement = {
            ccpocketTruncated: true,
            preview: "[tool input omitted: exceeds safe byte budget]",
          };
          const replacementBytes = Buffer.byteLength(
            JSON.stringify(replacement),
            "utf8",
          );
          if (replacementBytes > budget.remaining) {
            throw new Error(
              "Assistant message exceeds aggregate text/input byte budget",
            );
          }
          budget.remaining -= replacementBytes;
          payloadOmitted = true;
          return {
            ...content,
            input: replacement,
          };
        }),
      },
    },
    payloadOmitted,
  };
}

function takeBoundedText(
  value: string,
  budget: { remaining: number },
  blockLimit: number,
): string {
  const bounded = boundedText(
    value,
    Math.max(0, Math.min(blockLimit, budget.remaining)),
  );
  if (value.length > 0 && bounded.length === 0) {
    throw new Error("Message exceeds aggregate text byte budget");
  }
  budget.remaining = Math.max(
    0,
    budget.remaining - Buffer.byteLength(bounded, "utf8"),
  );
  return bounded;
}

function boundedText(value: string, maxBytes: number): string {
  if (maxBytes <= 0 || value.length === 0) return "";
  const suffixBytes = Buffer.byteLength(TRUNCATED_TEXT_SUFFIX, "utf8");
  const contentLimit = Math.max(0, maxBytes - suffixBytes);
  let bytes = 0;
  let contentEnd = 0;
  let index = 0;
  while (index < value.length) {
    const width = utf8CodePointWidth(value, index);
    if (bytes + width.bytes > maxBytes) break;
    bytes += width.bytes;
    index += width.codeUnits;
    if (bytes <= contentLimit) contentEnd = index;
  }
  if (index === value.length) return value;
  if (maxBytes < suffixBytes) {
    return maxBytes >= 3 ? "…" : "";
  }
  return `${value.slice(0, contentEnd)}${TRUNCATED_TEXT_SUFFIX}`;
}

function utf8CodePointWidth(
  value: string,
  index: number,
): { bytes: number; codeUnits: number } {
  const first = value.charCodeAt(index);
  if (first >= 0xd800 && first <= 0xdbff && index + 1 < value.length) {
    const second = value.charCodeAt(index + 1);
    if (second >= 0xdc00 && second <= 0xdfff) {
      return { bytes: 4, codeUnits: 2 };
    }
  }
  if (first <= 0x7f) return { bytes: 1, codeUnits: 1 };
  if (first <= 0x7ff) return { bytes: 2, codeUnits: 1 };
  return { bytes: 3, codeUnits: 1 };
}

function safeJsonSerialize(
  value: unknown,
  maxBytes: number,
): { value: string; bytes: number } | undefined {
  if (maxBytes <= 0) return undefined;
  try {
    const estimated = measureJsonValue(
      value,
      maxBytes,
      { stack: new Set(), nodes: 0 },
      0,
      false,
    );
    if (estimated === undefined || estimated > maxBytes) return undefined;
    const serialized = JSON.stringify(value);
    if (typeof serialized !== "string") return undefined;
    const bytes = Buffer.byteLength(serialized, "utf8");
    if (bytes > maxBytes) return undefined;
    return { value: serialized, bytes };
  } catch {
    return undefined;
  }
}

function measureJsonValue(
  value: unknown,
  maxBytes: number,
  state: { stack: Set<object>; nodes: number },
  depth: number,
  inArray: boolean,
): number | undefined {
  state.nodes += 1;
  if (state.nodes > MAX_SAFE_JSON_NODES || depth > MAX_SAFE_JSON_DEPTH) {
    return undefined;
  }
  if (value === null) return maxBytes >= 4 ? 4 : undefined;
  if (typeof value === "string") {
    return jsonStringByteLength(value, maxBytes);
  }
  if (typeof value === "boolean") {
    const bytes = value ? 4 : 5;
    return bytes <= maxBytes ? bytes : undefined;
  }
  if (typeof value === "number") {
    const encoded = Number.isFinite(value) ? JSON.stringify(value) : "null";
    const bytes = Buffer.byteLength(encoded, "utf8");
    return bytes <= maxBytes ? bytes : undefined;
  }
  if (
    typeof value === "undefined" ||
    typeof value === "function" ||
    typeof value === "symbol"
  ) {
    return inArray && maxBytes >= 4 ? 4 : undefined;
  }
  if (typeof value === "bigint" || typeof value !== "object") {
    return undefined;
  }
  if (!Array.isArray(value)) {
    const prototype = Object.getPrototypeOf(value);
    if (prototype !== Object.prototype && prototype !== null) {
      return undefined;
    }
  }
  if (hasCustomJsonSerialization(value) || state.stack.has(value)) {
    return undefined;
  }

  state.stack.add(value);
  try {
    if (Array.isArray(value)) {
      if (value.length > MAX_SAFE_JSON_NODES) return undefined;
      let bytes = 2;
      for (let index = 0; index < value.length; index += 1) {
        if (index > 0) bytes += 1;
        if (bytes > maxBytes) return undefined;
        const descriptor = Object.getOwnPropertyDescriptor(
          value,
          String(index),
        );
        if (!descriptor) {
          bytes += 4;
          continue;
        }
        if (descriptor.get || descriptor.set) return undefined;
        const remaining = maxBytes - bytes;
        const child = measureJsonValue(
          descriptor.value,
          remaining,
          state,
          depth + 1,
          true,
        );
        if (child === undefined) return undefined;
        bytes += child;
      }
      return bytes <= maxBytes ? bytes : undefined;
    }

    let bytes = 2;
    let count = 0;
    const record = value as Record<string, unknown>;
    for (const key in record) {
      if (!Object.prototype.hasOwnProperty.call(record, key)) continue;
      state.nodes += 1;
      if (state.nodes > MAX_SAFE_JSON_NODES) return undefined;
      const descriptor = Object.getOwnPropertyDescriptor(record, key);
      if (!descriptor?.enumerable) continue;
      if (descriptor.get || descriptor.set) return undefined;
      const childValue = descriptor.value;
      if (
        typeof childValue === "undefined" ||
        typeof childValue === "function" ||
        typeof childValue === "symbol"
      ) {
        continue;
      }
      if (count > 0) bytes += 1;
      const keyBytes = jsonStringByteLength(key, maxBytes - bytes);
      if (keyBytes === undefined) return undefined;
      bytes += keyBytes + 1;
      if (bytes > maxBytes) return undefined;
      const child = measureJsonValue(
        childValue,
        maxBytes - bytes,
        state,
        depth + 1,
        false,
      );
      if (child === undefined) return undefined;
      bytes += child;
      count += 1;
    }
    return bytes <= maxBytes ? bytes : undefined;
  } finally {
    state.stack.delete(value);
  }
}

function hasCustomJsonSerialization(value: object): boolean {
  let current: object | null = value;
  while (current) {
    const descriptor = Object.getOwnPropertyDescriptor(current, "toJSON");
    if (descriptor) {
      return (
        descriptor.get != null ||
        descriptor.set != null ||
        typeof descriptor.value === "function"
      );
    }
    current = Object.getPrototypeOf(current);
  }
  return false;
}

function jsonStringByteLength(
  value: string,
  maxBytes: number,
): number | undefined {
  let bytes = 2;
  for (let index = 0; index < value.length; index += 1) {
    const codeUnit = value.charCodeAt(index);
    if (codeUnit === 0x22 || codeUnit === 0x5c) {
      bytes += 2;
    } else if (
      codeUnit === 0x08 ||
      codeUnit === 0x09 ||
      codeUnit === 0x0a ||
      codeUnit === 0x0c ||
      codeUnit === 0x0d
    ) {
      bytes += 2;
    } else if (codeUnit <= 0x1f) {
      bytes += 6;
    } else if (
      codeUnit >= 0xd800 &&
      codeUnit <= 0xdbff &&
      index + 1 < value.length
    ) {
      const second = value.charCodeAt(index + 1);
      if (second >= 0xdc00 && second <= 0xdfff) {
        bytes += 4;
        index += 1;
      } else {
        bytes += 6;
      }
    } else if (codeUnit >= 0xd800 && codeUnit <= 0xdfff) {
      bytes += 6;
    } else if (codeUnit <= 0x7f) {
      bytes += 1;
    } else if (codeUnit <= 0x7ff) {
      bytes += 2;
    } else {
      bytes += 3;
    }
    if (bytes > maxBytes) return undefined;
  }
  return bytes <= maxBytes ? bytes : undefined;
}

function messageIdentity(
  message: ServerMessage,
  index: number,
  serialized: string,
): string {
  if (message.type === "user_input") {
    if (message.providerItemId) return `user:${message.providerItemId}`;
    const fallback = message.userMessageUuid ?? sha256(serialized);
    return message.historyTurnId
      ? `turn:${message.historyTurnId}:user:${fallback}`
      : `user:${fallback}`;
  }
  if (message.type === "assistant") {
    const fallback = message.messageUuid ?? message.message.id;
    return message.historyTurnId
      ? `turn:${message.historyTurnId}:assistant:${fallback}`
      : `assistant:${fallback}`;
  }
  if (message.type === "tool_result") {
    return message.historyTurnId
      ? `turn:${message.historyTurnId}:tool-result:${message.toolUseId}`
      : `tool-result:${message.toolUseId}`;
  }
  return `message:${message.type}:${index}`;
}

export function paginateConversationContentEntries(
  entries: readonly ConversationContentSnapshotEntry[],
  maxEntries: number,
  maxBytes: number,
  pageEnvelopeBytes: number,
): ConversationContentSnapshotEntry[][] {
  if (entries.length === 0) return [];
  if (pageEnvelopeBytes > maxBytes) {
    throw new Error("Conversation snapshot page envelope exceeds byte budget");
  }
  const pages: ConversationContentSnapshotEntry[][] = [];
  let page: ConversationContentSnapshotEntry[] = [];
  let pageBytes = pageEnvelopeBytes;
  for (const entry of entries) {
    const entryBytes = Buffer.byteLength(
      JSON.stringify(toWireConversationContentEntry(entry)),
      "utf8",
    );
    if (pageEnvelopeBytes + entryBytes > maxBytes) {
      throw new Error("Conversation snapshot entry exceeds page byte budget");
    }
    const separatorBytes = page.length === 0 ? 0 : 1;
    if (
      page.length > 0 &&
      (page.length >= maxEntries ||
        pageBytes + separatorBytes + entryBytes > maxBytes)
    ) {
      pages.push(page);
      page = [];
      pageBytes = pageEnvelopeBytes;
    }
    page.push(entry);
    pageBytes += (page.length === 1 ? 0 : 1) + entryBytes;
  }
  if (page.length > 0) pages.push(page);
  return pages;
}

export function toWireConversationContentEntry(
  entry: ConversationContentSnapshotEntry,
): ConversationContentEntry {
  return {
    entryId: entry.entryId,
    index: entry.index,
    contentHash: entry.contentHash,
    message: entry.message,
  };
}

function snapshotTarget(
  snapshot: ConversationContentSnapshot,
): ConversationContentTarget {
  return {
    provider: snapshot.provider,
    providerSessionId: snapshot.providerSessionId,
  };
}

function targetKey(target: ConversationContentTarget): ConversationKey {
  return `${target.provider}\0${target.providerSessionId}`;
}

function parseTargetKey(
  key: ConversationKey,
): ConversationContentTarget | null {
  const separator = key.indexOf("\0");
  if (separator <= 0 || separator >= key.length - 1) return null;
  const provider = key.slice(0, separator);
  if (provider !== "claude" && provider !== "codex") return null;
  return {
    provider,
    providerSessionId: key.slice(separator + 1),
  };
}

function sha256(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}

function positiveInteger(value: number | undefined, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value) && value > 0
    ? Math.floor(value)
    : fallback;
}
