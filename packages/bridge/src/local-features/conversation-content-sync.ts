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
const QUEUE_PRIORITY_AGING_INTERVAL = 3;
const MAX_TOOL_RESULT_TEXT = 64 * 1024;
const MAX_ASSISTANT_TEXT = 128 * 1024;
const MAX_TOOL_INPUT_JSON = 32 * 1024;
const MAX_ASSISTANT_CONTENT_BLOCKS = 1024;
const MAX_SAFE_JSON_DEPTH = 64;
const MAX_SAFE_JSON_NODES = 10_000;
const TRUNCATED_TEXT_SUFFIX =
  "\n…[truncated; load details on demand]";

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

interface SnapshotEntry extends ConversationContentEntry {
  sourceIndex: number;
}

interface ConversationSnapshot extends ConversationContentTarget {
  revision: string;
  entries: SnapshotEntry[];
  hasEarlier: boolean;
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
  private readonly snapshots = new Map<
    ConversationKey,
    ConversationSnapshot[]
  >();
  private queueSequence = 0;
  private completedTaskCount = 0;
  private cachedSnapshotBytes = 0;
  private draining = false;
  private drainTimer?: ReturnType<typeof setTimeout>;
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
          })
        ).sessions);
    this.historyReader = options.historyReader ?? readDurableHistory;
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
        this.cancelDrainTimer();
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
    this.enqueue(target, this.focusPriority(target, 1), "live_runtime");
  }

  disconnect(client: object): void {
    this.clients.delete(client);
    if (!this.hasInteractiveClients()) {
      this.queue.clear();
      this.cancelDrainTimer();
      this.cancelColdScan();
    }
  }

  close(): void {
    this.closed = true;
    this.clients.clear();
    this.queue.clear();
    this.snapshots.clear();
    this.cachedSnapshotBytes = 0;
    this.cancelDrainTimer();
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
      this.cancelDrainTimer();
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
          const snapshot = buildSnapshot(task, messages, {
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
        task.priority -
          Math.floor(tasksWaited / QUEUE_PRIORITY_AGING_INTERVAL),
      );
      if (
        !selected ||
        agedPriority < selectedPriority ||
        (agedPriority === selectedPriority &&
          task.sequence < selected.sequence)
      ) {
        selected = task;
        selectedPriority = agedPriority;
      }
    }
    return selected;
  }

  private publishSnapshot(
    key: ConversationKey,
    snapshot: ConversationSnapshot,
  ): void {
    for (const [client, subscription] of [...this.clients]) {
      if (!subscription.interactive || !this.clientReady(client)) continue;
      if (subscription.pendingRevisions.get(key) === snapshot.revision) {
        continue;
      }
      const knownRevision = subscription.cursors.get(key);
      if (knownRevision === snapshot.revision) {
        subscription.pendingRevisions.delete(key);
        continue;
      }
      const base = knownRevision
        ? this.findSnapshot(key, knownRevision)
        : undefined;
      const patched =
        base != null && this.sendPatch(client, subscription, base, snapshot);
      if (!patched) this.sendSnapshot(client, subscription, snapshot);
      subscription.pendingRevisions.set(key, snapshot.revision);
    }
  }

  private sendPatch(
    client: object,
    subscription: ClientSubscription,
    base: ConversationSnapshot,
    snapshot: ConversationSnapshot,
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
      upserts: upserts.map(toWireEntry),
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
    snapshot: ConversationSnapshot,
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
    const pages = paginateEntries(
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
        entries: entries.map(toWireEntry),
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
    snapshot: ConversationSnapshot,
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
    while (
      revisions.length > 1 &&
      targetBytes > this.maxCachedTargetBytes
    ) {
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
      this.removeCachedTarget(oldest);
    }
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
  ): ConversationSnapshot | undefined {
    const values = this.snapshots.get(key);
    const snapshot = values?.find((value) => value.revision === revision);
    if (snapshot && values) this.touchCachedTarget(key, values);
    return snapshot;
  }

  private latestSnapshot(
    key: ConversationKey,
  ): ConversationSnapshot | undefined {
    const values = this.snapshots.get(key);
    const snapshot = values?.at(-1);
    if (snapshot && values) this.touchCachedTarget(key, values);
    return snapshot;
  }

  private touchCachedTarget(
    key: ConversationKey,
    values: ConversationSnapshot[],
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

async function readDurableHistory(
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

function buildSnapshot(
  target: ConversationContentTarget,
  rawMessages: readonly ServerMessage[],
  limits: {
    maxMessageTextBytes: number;
    maxSnapshotBytes: number;
  },
): ConversationSnapshot {
  const firstRelevantIndex = latestRootTurnStart(
    rawMessages,
    TURN_AWARE_HISTORY_ROOT_TURNS,
  );
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
  const selected = selectTurnAwareHistoryWindow(source);
  const retained: Array<{
    sourceIndex: number;
    message: ServerMessage;
    serialized: string;
  }> = [];
  let retainedMessageBytes = 0;
  let omitted = false;
  for (let index = selected.length - 1; index >= 0; index -= 1) {
    const value = selected[index]!;
    const message = boundHistoryMessage(
      value.message,
      limits.maxMessageTextBytes,
    );
    const serialized = safeJsonSerialize(
      message,
      limits.maxSnapshotBytes,
    );
    if (!serialized) {
      throw new Error("Conversation message exceeds safe serialized byte budget");
    }
    if (retainedMessageBytes + serialized.bytes > limits.maxSnapshotBytes) {
      omitted = true;
      break;
    }
    retainedMessageBytes += serialized.bytes;
    retained.unshift({
      sourceIndex: value.sourceIndex,
      message,
      serialized: serialized.value,
    });
  }

  const usedIds = new Map<string, number>();
  const candidateEntries: SnapshotEntry[] = retained.map((value) => {
    const message = value.message;
    const baseId = messageIdentity(
      message,
      value.sourceIndex,
      value.serialized,
    );
    const occurrence = (usedIds.get(baseId) ?? 0) + 1;
    usedIds.set(baseId, occurrence);
    const entryId = occurrence === 1 ? baseId : `${baseId}:${occurrence}`;
    return {
      entryId,
      index: value.sourceIndex,
      sourceIndex: value.sourceIndex,
      contentHash: sha256(value.serialized),
      message,
    };
  });
  const emptySnapshotBytes = materializeSnapshot(
    target,
    [],
    true,
    rawMessages.length,
  ).cacheBytes;
  let entryBytes = emptySnapshotBytes + 32;
  let firstEntry = candidateEntries.length;
  for (let index = candidateEntries.length - 1; index >= 0; index -= 1) {
    const candidateBytes = Buffer.byteLength(
      JSON.stringify(candidateEntries[index]),
      "utf8",
    );
    const separatorBytes = firstEntry === candidateEntries.length ? 0 : 1;
    if (
      entryBytes + separatorBytes + candidateBytes >
      limits.maxSnapshotBytes
    ) {
      omitted = true;
      break;
    }
    entryBytes += separatorBytes + candidateBytes;
    firstEntry = index;
  }
  if (candidateEntries.length > 0 && firstEntry === candidateEntries.length) {
    throw new Error("Conversation snapshot entry exceeds snapshot byte budget");
  }
  const entries = candidateEntries.slice(firstEntry);
  const hasEarlier =
    omitted ||
    retained.length < selected.length ||
    firstEntry > 0 ||
    (entries[0]?.sourceIndex ?? rawMessages.length) > 0;
  const snapshot = materializeSnapshot(
    target,
    entries,
    hasEarlier,
    rawMessages.length,
  );
  if (snapshot.cacheBytes > limits.maxSnapshotBytes) {
    throw new Error("Conversation snapshot exceeds safe serialized byte budget");
  }
  return snapshot;
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
  entries: SnapshotEntry[],
  hasEarlier: boolean,
  sourceEntryCount: number,
): ConversationSnapshot {
  const revision = sha256(
    JSON.stringify({
      sourceEntryCount,
      hasEarlier,
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

function boundHistoryMessage(
  message: ServerMessage,
  maxMessageTextBytes: number,
): ServerMessage {
  const budget = { remaining: maxMessageTextBytes };
  if (message.type === "user_input") {
    return {
      ...message,
      text: takeBoundedText(message.text, budget, maxMessageTextBytes),
    };
  }
  if (message.type === "tool_result") {
    return {
      ...message,
      content: takeBoundedText(message.content, budget, MAX_TOOL_RESULT_TEXT),
    };
  }
  if (message.type === "tool_use_summary") {
    return {
      ...message,
      summary: takeBoundedText(
        message.summary,
        budget,
        maxMessageTextBytes,
      ),
    };
  }
  if (message.type !== "assistant") return message;
  if (message.message.content.length > MAX_ASSISTANT_CONTENT_BLOCKS) {
    throw new Error(
      `Assistant message exceeds ${MAX_ASSISTANT_CONTENT_BLOCKS} content blocks`,
    );
  }
  return {
    ...message,
    message: {
      ...message.message,
      content: message.message.content.map((content) => {
        if (content.type === "text") {
          return {
            ...content,
            text: takeBoundedText(
              content.text,
              budget,
              MAX_ASSISTANT_TEXT,
            ),
          };
        }
        if (content.type === "thinking") {
          return {
            ...content,
            thinking: takeBoundedText(
              content.thinking,
              budget,
              MAX_ASSISTANT_TEXT,
            ),
          };
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
        return {
          ...content,
          input: replacement,
        };
      }),
    },
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
  if (
    first >= 0xd800 &&
    first <= 0xdbff &&
    index + 1 < value.length
  ) {
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
    const encoded = Number.isFinite(value)
      ? JSON.stringify(value)
      : "null";
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
    return `user:${message.userMessageUuid ?? sha256(serialized)}`;
  }
  if (message.type === "assistant") {
    return `assistant:${message.messageUuid ?? message.message.id}`;
  }
  if (message.type === "tool_result") {
    return `tool-result:${message.toolUseId}`;
  }
  return `message:${message.type}:${index}`;
}

function paginateEntries(
  entries: readonly SnapshotEntry[],
  maxEntries: number,
  maxBytes: number,
  pageEnvelopeBytes: number,
): SnapshotEntry[][] {
  if (entries.length === 0) return [];
  if (pageEnvelopeBytes > maxBytes) {
    throw new Error("Conversation snapshot page envelope exceeds byte budget");
  }
  const pages: SnapshotEntry[][] = [];
  let page: SnapshotEntry[] = [];
  let pageBytes = pageEnvelopeBytes;
  for (const entry of entries) {
    const entryBytes = Buffer.byteLength(
      JSON.stringify(toWireEntry(entry)),
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

function toWireEntry(entry: SnapshotEntry): ConversationContentEntry {
  return {
    entryId: entry.entryId,
    index: entry.index,
    contentHash: entry.contentHash,
    message: entry.message,
  };
}

function snapshotTarget(
  snapshot: ConversationSnapshot,
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
