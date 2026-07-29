import { createHash } from "node:crypto";

import {
  CodexProcess,
  CodexRpcError,
  type CodexThreadSummary,
} from "../codex-process.js";
import {
  selectTurnAwareHistoryWindow,
  TURN_AWARE_HISTORY_ENVELOPE_ENTRIES,
} from "../history-window.js";
import type { HistoryToolDetailPayload, ServerMessage } from "../parser.js";
import {
  codexThreadToSessionHistory,
  getAllRecentSessions,
  type SessionIndexEntry,
} from "../sessions-index.js";
import {
  buildConversationContentSnapshot,
  paginateConversationContentEntries,
  readDurableConversationHistory,
  toWireConversationContentEntry,
  type ConversationContentSnapshot,
  type ConversationContentSnapshotEntry,
} from "./conversation-content-sync.js";
import { sessionHistoryToServerMessages } from "./codex-thread-history.js";
import {
  CONVERSATION_SYNC_V2_CAPABILITY,
  type ConversationSyncCatalogEntry,
  type ConversationSyncClientMessage,
  type ConversationSyncReadWatermark,
  type ConversationSyncServerMessage,
  type ConversationSyncStatus,
  type ConversationSyncTarget,
} from "./slots/conversation-sync-v2-protocol.js";
import type {
  LocalFeatureClientDeliveryMode,
  LocalFeatureHandleContext,
  LocalFeatureHandler,
  LocalFeatureRuntime,
  LocalFeatureRuntimeConversationState,
  LocalFeatureSession,
} from "./runtime.js";

const MAX_CATALOG_ENTRIES = 10_000;
const CODEX_PAGE_SIZE = 500;
const PRIORITY_RECENT_COUNT = 5;
const MIN_RECENT_COUNT = 10;
const RECENT_WINDOW_MS = 3 * 24 * 60 * 60_000;
const STATUS_WATCHDOG_MS = 5_000;
const COLD_RECONCILE_MS = 10 * 60_000;
const MAX_FRAME_BYTES = 64 * 1024;
const FRAME_CONTENT_BUDGET = 56 * 1024;
const MAX_UNACKED_BYTES = 1024 * 1024;
const MAX_QUEUED_BYTES = 8 * 1024 * 1024;
const SYNC_BACKPRESSURE_BYTES = 2 * 1024 * 1024;
const MAX_TIMELINE_BYTES = 512 * 1024;
const MAX_MESSAGE_TEXT_BYTES = 40 * 1024;
const MAX_TIMELINE_PAGE_ENTRIES = 24;
const MAX_SNAPSHOT_TARGETS = 32;
const MAX_STATE_HISTORY = 4;
const MAX_THREAD_STATES = 512;
const PROVIDER_HISTORY_CONCURRENCY = 2;
const FULL_RECENT_TURNS = 3;
const MAX_TURN_DETAIL_CACHE_BYTES = 16 * 1024 * 1024;
const MAX_TURN_DETAIL_CACHE_ENTRIES = 128;
const MAX_TOOL_DETAIL_COMPONENT_BYTES = 3 * 1024;
const MAX_TOOL_DETAIL_ATTACHMENTS = 4;
const MAX_CODEX_TURN_SCAN_PAGES = 50;
const CODEX_TURN_SCAN_PAGE_SIZE = 20;
const LIVE_CONTENT_BATCH_MS = 32;

type ConversationKey = string;
type ConversationSyncEventPayload =
  ConversationSyncServerMessage extends infer Message
    ? Message extends unknown
      ? Omit<
          Message,
          | "type"
          | "subscriptionId"
          | "bridgeInstanceId"
          | "codexSourceId"
          | "batchId"
          | "sequence"
        >
      : never
    : never;

export interface ConversationSyncCatalogSeed {
  entry: ConversationSyncCatalogEntry;
  status: ConversationSyncStatus;
}

interface CatalogRecord extends ConversationSyncCatalogSeed {}

interface OutboundFrame {
  sequence: number;
  bytes: number;
  message: ConversationSyncServerMessage;
}

interface FrameCommit {
  catalogState?: string;
  statusState?: string;
  thread?: { key: ConversationKey; revision: string };
}

interface SyncSubscription {
  id: string;
  requestId: string;
  batchId: string;
  interactive: boolean;
  focusedKey?: ConversationKey;
  catalogState?: string;
  statusState?: string;
  pendingCatalogState?: string;
  pendingStatusState?: string;
  threadStates: Map<ConversationKey, string>;
  pendingThreadStates: Map<ConversationKey, string>;
  readWatermarks: Map<ConversationKey, string>;
  nextSequence: number;
  outstandingBytes: number;
  outstanding: Map<number, number>;
  queuedBytes: number;
  outbound: OutboundFrame[];
  commits: Map<number, FrameCommit>;
  syncing: boolean;
  dirty: boolean;
}

interface ConversationSyncV2Options {
  catalogReader?: () => Promise<ConversationSyncCatalogSeed[]>;
  statusReader?: (
    current: ReadonlyMap<ConversationKey, CatalogRecord>,
  ) => Promise<Map<ConversationKey, ConversationSyncStatus>>;
  historyReader?: (
    target: ConversationSyncTarget,
  ) => Promise<ServerMessage[] | ConversationHistoryWindow>;
  statusWatchdogMs?: number;
  coldReconcileMs?: number;
}

interface ConversationHistoryWindow {
  messages: ServerMessage[];
  nextTurnCursor: string | null;
  turnDetails?: ConversationTurnDetails[];
}

interface NormalizedConversationTurn {
  turnId: string;
  messages: ServerMessage[];
  itemCount: number;
  itemsView: "summary" | "full";
}

interface ConversationTurnDetails {
  turnId: string;
  details: HistoryToolDetailPayload[];
}

interface ConversationTurnsPage {
  data: unknown[];
  nextCursor: string | null;
  turnDetails?: ConversationTurnDetails[];
}

interface ConversationItemsPage {
  data: unknown[];
  nextCursor: string | null;
  turnDetails?: ConversationTurnDetails;
}

interface CachedTurnDetails {
  details: Map<string, HistoryToolDetailPayload>;
  bytes: number;
}

interface LiveContentRevision {
  target: ConversationSyncTarget;
  observedAt: string;
  revision: string;
}

/**
 * Additive v2 synchronizer. It owns one catalog/status scheduler and one
 * bounded provider-history queue for every v2 Mobile client; v1 remains
 * dormant unless an older client explicitly subscribes to it.
 */
export class ConversationSyncV2FeatureHandler implements LocalFeatureHandler {
  readonly messageTypes = [
    "conversation_sync_subscribe",
    "conversation_sync_ack",
    "conversation_sync_read",
    "conversation_sync_focus",
    "conversation_sync_unsubscribe",
    "conversation_turns_page",
    "conversation_items_page",
  ] as const;

  private readonly catalogReader: () => Promise<ConversationSyncCatalogSeed[]>;
  private readonly statusReader: (
    current: ReadonlyMap<ConversationKey, CatalogRecord>,
  ) => Promise<Map<ConversationKey, ConversationSyncStatus>>;
  private readonly historyReader: (
    target: ConversationSyncTarget,
  ) => Promise<ServerMessage[] | ConversationHistoryWindow>;
  private readonly statusWatchdogMs: number;
  private readonly coldReconcileMs: number;

  private readonly subscriptions = new Map<object, SyncSubscription>();
  private catalog = new Map<ConversationKey, CatalogRecord>();
  private catalogState = hashState([]);
  private statusState = hashState([]);
  private readonly catalogHistory = new Map<
    string,
    Map<ConversationKey, ConversationSyncCatalogEntry>
  >();
  private readonly statusHistory = new Map<
    string,
    Map<ConversationKey, ConversationSyncStatus>
  >();
  private readonly snapshots = new Map<
    ConversationKey,
    ConversationContentSnapshot[]
  >();
  private readonly snapshotFlights = new Map<
    ConversationKey,
    Promise<ConversationContentSnapshot>
  >();
  private readonly resultLedger = new Map<
    ConversationKey,
    { result: "completed" | "failed"; observedAt: string }
  >();
  private readonly turnDetailCache = new Map<string, CachedTurnDetails>();
  private readonly liveContentRevisions = new Map<
    ConversationKey,
    LiveContentRevision
  >();
  private readonly pendingLiveContent = new Map<
    ConversationKey,
    { target: ConversationSyncTarget; observedAt: string }
  >();
  private turnDetailCacheBytes = 0;
  private catalogFlight?: Promise<void>;
  private catalogDirty = true;
  private statusFlight?: Promise<void>;
  private watchdogTimer?: ReturnType<typeof setTimeout>;
  private coldTimer?: ReturnType<typeof setTimeout>;
  private liveContentTimer?: ReturnType<typeof setTimeout>;
  private liveRevision = 0;
  private closed = false;

  constructor(
    private readonly runtime: LocalFeatureRuntime,
    options: ConversationSyncV2Options = {},
  ) {
    this.catalogReader =
      options.catalogReader ?? (() => readUnifiedCatalog(this.runtime));
    this.statusReader =
      options.statusReader ??
      ((current) => readCurrentStatuses(this.runtime, current));
    this.historyReader =
      options.historyReader ??
      ((target) => readRecentConversationHistory(this.runtime, target));
    this.statusWatchdogMs = positiveInterval(
      options.statusWatchdogMs,
      STATUS_WATCHDOG_MS,
    );
    this.coldReconcileMs = positiveInterval(
      options.coldReconcileMs,
      COLD_RECONCILE_MS,
    );
  }

  async handle(
    message: ConversationSyncClientMessage,
    context: LocalFeatureHandleContext,
  ): Promise<void> {
    if (
      this.closed ||
      !this.runtime.supports(context.client, CONVERSATION_SYNC_V2_CAPABILITY)
    ) {
      return;
    }
    switch (message.type) {
      case "conversation_sync_subscribe":
        this.subscribe(context.client, message);
        return;
      case "conversation_sync_ack":
        this.ack(context.client, message);
        return;
      case "conversation_sync_read":
        this.markRead(context.client, message);
        return;
      case "conversation_sync_focus":
        this.focus(context.client, message);
        return;
      case "conversation_sync_unsubscribe":
        this.unsubscribe(context.client, message);
        return;
      case "conversation_turns_page":
        await this.sendTurnsPage(context.client, message, context.signal);
        return;
      case "conversation_items_page":
        await this.sendItemsPage(context.client, message, context.signal);
    }
  }

  capabilitiesChanged(client: object): void {
    if (!this.runtime.supports(client, CONVERSATION_SYNC_V2_CAPABILITY)) {
      this.disconnect(client);
    }
  }

  clientDeliveryModeChanged(
    client: object,
    mode: LocalFeatureClientDeliveryMode,
  ): void {
    const subscription = this.subscriptions.get(client);
    if (!subscription) return;
    subscription.interactive = mode === "interactive";
    if (subscription.interactive) {
      this.catalogDirty = true;
      this.scheduleSync(client, subscription);
      this.ensureTimers();
    } else {
      subscription.outbound.length = 0;
      subscription.queuedBytes = 0;
    }
  }

  sessionCatalogChanged(): void {
    this.catalogDirty = true;
    if (!this.hasInteractiveClients()) return;
    void this.refreshCatalog()
      .then(() => this.scheduleInteractiveClients())
      .catch((error) => {
        this.reportBackgroundError("catalog_refresh_failed", error);
      });
  }

  sessionMessage(session: LocalFeatureSession, message: ServerMessage): void {
    if (!this.hasInteractiveClients()) return;
    const target = this.targetForSession(session);
    if (!target) return;
    const key = targetKey(target);
    const observedAt = new Date().toISOString();
    if (message.type === "result") {
      this.resultLedger.set(key, {
        result:
          Boolean(message.error) ||
          /error|fail/i.test(message.subtype) ||
          /error|fail/i.test(message.stopReason ?? "")
            ? "failed"
            : "completed",
        observedAt,
      });
    } else if (
      message.type === "assistant" ||
      message.type === "tool_result" ||
      message.type === "user_input"
    ) {
      this.resultLedger.delete(key);
    }

    if (isStreamingConversationDelta(message)) {
      this.queueLiveContent(target, observedAt);
      return;
    }
    if (isConversationTimelineMessage(message)) {
      this.publishLiveContent(target, observedAt);
      return;
    }

    const previousStatusState = this.statusState;
    this.applyRuntimeOverlay();
    this.recomputeStates();
    if (this.statusState !== previousStatusState) {
      this.scheduleInteractiveClients();
    }
  }

  disconnect(client: object): void {
    this.subscriptions.delete(client);
    if (!this.hasInteractiveClients()) this.cancelTimers();
  }

  close(): void {
    this.closed = true;
    this.subscriptions.clear();
    this.snapshots.clear();
    this.snapshotFlights.clear();
    this.turnDetailCache.clear();
    this.liveContentRevisions.clear();
    this.pendingLiveContent.clear();
    this.turnDetailCacheBytes = 0;
    this.cancelTimers();
  }

  private subscribe(
    client: object,
    message: Extract<
      ConversationSyncClientMessage,
      { type: "conversation_sync_subscribe" }
    >,
  ): void {
    if (!this.runtime.bridgeInstanceId) {
      return;
    }
    const threadStates = new Map<ConversationKey, string>();
    for (const state of message.threadContentStates) {
      threadStates.set(targetKey(state), state.revision);
    }
    const readWatermarks = new Map<ConversationKey, string>();
    for (const watermark of message.readWatermarks) {
      readWatermarks.set(
        targetKey(watermark),
        new Date(watermark.readAt).toISOString(),
      );
    }
    const subscription: SyncSubscription = {
      id: message.requestId,
      requestId: message.requestId,
      batchId: `${message.requestId}:${Date.now().toString(36)}`,
      interactive:
        (this.runtime.getClientDeliveryMode?.(client) ?? "interactive") ===
        "interactive",
      ...(message.focused ? { focusedKey: targetKey(message.focused) } : {}),
      catalogState: message.catalogState,
      statusState: message.statusState,
      threadStates,
      pendingThreadStates: new Map(),
      readWatermarks,
      nextSequence: 0,
      outstandingBytes: 0,
      outstanding: new Map(),
      queuedBytes: 0,
      outbound: [],
      commits: new Map(),
      syncing: false,
      dirty: false,
    };
    this.subscriptions.set(client, subscription);
    if (subscription.interactive) {
      this.catalogDirty = true;
      this.scheduleSync(client, subscription);
      this.ensureTimers();
    }
  }

  private ack(
    client: object,
    message: Extract<
      ConversationSyncClientMessage,
      { type: "conversation_sync_ack" }
    >,
  ): void {
    const subscription = this.subscriptions.get(client);
    if (!subscription || subscription.id !== message.subscriptionId) return;
    for (const [sequence, bytes] of [...subscription.outstanding]) {
      if (sequence > message.sequence) continue;
      subscription.outstanding.delete(sequence);
      subscription.outstandingBytes = Math.max(
        0,
        subscription.outstandingBytes - bytes,
      );
      const commit = subscription.commits.get(sequence);
      if (!commit) continue;
      subscription.commits.delete(sequence);
      if (commit.catalogState) {
        subscription.catalogState = commit.catalogState;
        if (subscription.pendingCatalogState === commit.catalogState) {
          subscription.pendingCatalogState = undefined;
        }
      }
      if (commit.statusState) {
        subscription.statusState = commit.statusState;
        if (subscription.pendingStatusState === commit.statusState) {
          subscription.pendingStatusState = undefined;
        }
      }
      if (commit.thread) {
        subscription.pendingThreadStates.delete(commit.thread.key);
        subscription.threadStates.set(
          commit.thread.key,
          commit.thread.revision,
        );
      }
    }
    this.flush(client, subscription);
    if (subscription.dirty && subscription.outbound.length === 0) {
      this.scheduleSync(client, subscription);
    }
  }

  private markRead(
    client: object,
    message: Extract<
      ConversationSyncClientMessage,
      { type: "conversation_sync_read" }
    >,
  ): void {
    const subscription = this.subscriptions.get(client);
    if (!subscription || subscription.id !== message.subscriptionId) return;
    const key = targetKey(message);
    const nextReadAt = new Date(message.readAt).toISOString();
    const currentReadAt = subscription.readWatermarks.get(key);
    if (currentReadAt && Date.parse(currentReadAt) > Date.parse(nextReadAt)) {
      return;
    }
    subscription.readWatermarks.set(key, nextReadAt);
    this.scheduleSync(client, subscription);
  }

  private focus(
    client: object,
    message: Extract<
      ConversationSyncClientMessage,
      { type: "conversation_sync_focus" }
    >,
  ): void {
    const subscription = this.subscriptions.get(client);
    if (!subscription || subscription.id !== message.subscriptionId) {
      return;
    }
    subscription.focusedKey = message.focused
      ? targetKey(message.focused)
      : undefined;
    this.sendEvent(client, subscription, {
      event: "focus_applied",
      requestId: message.requestId,
      ...(message.focused ? { focused: message.focused } : {}),
    });
    if (message.focused) this.scheduleSync(client, subscription);
  }

  private unsubscribe(
    client: object,
    message: Extract<
      ConversationSyncClientMessage,
      { type: "conversation_sync_unsubscribe" }
    >,
  ): void {
    const subscription = this.subscriptions.get(client);
    if (!subscription || subscription.id !== message.subscriptionId) return;
    this.sendEvent(client, subscription, {
      event: "unsubscribed",
      requestId: message.requestId,
    });
    this.flush(client, subscription);
    this.subscriptions.delete(client);
    if (!this.hasInteractiveClients()) this.cancelTimers();
  }

  private scheduleSync(client: object, subscription: SyncSubscription): void {
    if (this.closed || !subscription.interactive || !this.clientReady(client)) {
      return;
    }
    if (subscription.syncing) {
      subscription.dirty = true;
      return;
    }
    subscription.syncing = true;
    void this.runSync(client, subscription)
      .catch((error) => {
        this.sendError(
          client,
          subscription,
          undefined,
          "sync_failed",
          errorMessage(error),
        );
      })
      .finally(() => {
        subscription.syncing = false;
        if (
          subscription.dirty &&
          subscription.outbound.length === 0 &&
          subscription.outstandingBytes < MAX_UNACKED_BYTES
        ) {
          subscription.dirty = false;
          this.scheduleSync(client, subscription);
        }
      });
  }

  private async runSync(
    client: object,
    subscription: SyncSubscription,
  ): Promise<void> {
    await this.refreshCatalog();
    if (
      this.closed ||
      this.subscriptions.get(client) !== subscription ||
      !subscription.interactive
    ) {
      return;
    }
    const batchId = `${subscription.id}:${Date.now().toString(36)}`;
    subscription.batchId = batchId;
    const beginSequence = this.sendEvent(client, subscription, {
      event: "sync_begin",
      requestId: subscription.requestId,
      catalogState: this.catalogState,
      statusState: this.statusState,
    });
    if (subscription.catalogState === this.catalogState) {
      this.mergeCommit(subscription, beginSequence, {
        catalogState: this.catalogState,
      });
    }
    if (subscription.statusState === this.statusState) {
      this.mergeCommit(subscription, beginSequence, {
        statusState: this.statusState,
      });
    }
    this.sendCatalogChanges(client, subscription);
    this.sendStatusChanges(client, subscription);

    const ordered = this.orderedRecords(subscription);
    const priority = ordered.filter((record, index) =>
      this.isPriorityRecord(record, index, subscription),
    );
    const priorityComplete = await this.sendTimelineRecords(
      client,
      subscription,
      priority,
    );
    this.sendEvent(client, subscription, {
      event: "sync_checkpoint",
      phase: "priority",
      hasMore: !priorityComplete || ordered.length > priority.length,
    });
    if (!priorityComplete) {
      subscription.dirty = true;
      return;
    }

    const priorityKeys = new Set(
      priority.map((record) => targetKey(record.entry)),
    );
    const recent = ordered.filter(
      (record, index) =>
        !priorityKeys.has(targetKey(record.entry)) &&
        this.isRecentRecord(record, index),
    );
    const recentComplete = await this.sendTimelineRecords(
      client,
      subscription,
      recent,
    );
    this.sendEvent(client, subscription, {
      event: "sync_checkpoint",
      phase: "recent",
      hasMore: !recentComplete,
    });
    if (!recentComplete) {
      subscription.dirty = true;
      return;
    }

    const desiredThreadStates = new Map(subscription.threadStates);
    for (const [key, revision] of subscription.pendingThreadStates) {
      desiredThreadStates.set(key, revision);
    }
    this.sendEvent(client, subscription, {
      event: "sync_complete",
      nextState: {
        catalogState: this.catalogState,
        statusState: this.statusState,
        threadContentStates: [...desiredThreadStates]
          .slice(-MAX_THREAD_STATES)
          .map(([key, revision]) => ({
            ...parseTargetKeyRequired(key),
            revision,
          })),
      },
    });
  }

  private sendCatalogChanges(
    client: object,
    subscription: SyncSubscription,
  ): void {
    if (
      subscription.catalogState === this.catalogState ||
      subscription.pendingCatalogState === this.catalogState
    ) {
      return;
    }
    const previous = subscription.catalogState
      ? this.catalogHistory.get(subscription.catalogState)
      : undefined;
    if (subscription.catalogState && !previous) {
      this.sendEvent(client, subscription, {
        event: "sync_reset",
        scope: "catalog",
        reason: "state_unavailable",
      });
    }
    const current = catalogEntries(this.catalog);
    const changes: Array<
      | { kind: "created"; value: ConversationSyncCatalogEntry }
      | { kind: "updated"; value: ConversationSyncCatalogEntry }
      | { kind: "destroyed"; value: ConversationSyncTarget }
    > = [];
    for (const [key, value] of current) {
      const prior = previous?.get(key);
      if (!prior) {
        changes.push({ kind: "created", value });
      } else if (stableJson(prior) !== stableJson(value)) {
        changes.push({ kind: "updated", value });
      }
    }
    if (previous) {
      for (const [key, value] of previous) {
        if (!current.has(key)) {
          changes.push({
            kind: "destroyed",
            value: {
              provider: value.provider,
              providerSessionId: value.providerSessionId,
            },
          });
        }
      }
    }
    const pages = chunkByJsonBytes(changes, FRAME_CONTENT_BUDGET);
    const effectivePages = pages.length > 0 ? pages : [[]];
    effectivePages.forEach((page, pageIndex) => {
      const sequence = this.sendEvent(client, subscription, {
        event: "catalog_changes",
        catalogState: this.catalogState,
        pageIndex,
        pageCount: effectivePages.length,
        created: page
          .filter((change) => change.kind === "created")
          .map((change) => change.value as ConversationSyncCatalogEntry),
        updated: page
          .filter((change) => change.kind === "updated")
          .map((change) => change.value as ConversationSyncCatalogEntry),
        destroyed: page
          .filter((change) => change.kind === "destroyed")
          .map((change) => change.value as ConversationSyncTarget),
      });
      if (pageIndex === effectivePages.length - 1) {
        subscription.pendingCatalogState = this.catalogState;
        this.mergeCommit(subscription, sequence, {
          catalogState: this.catalogState,
        });
      }
    });
  }

  private sendStatusChanges(
    client: object,
    subscription: SyncSubscription,
  ): void {
    if (
      subscription.statusState === this.statusState ||
      subscription.pendingStatusState === this.statusState
    ) {
      return;
    }
    const previous = subscription.statusState
      ? this.statusHistory.get(subscription.statusState)
      : undefined;
    if (subscription.statusState && !previous) {
      this.sendEvent(client, subscription, {
        event: "sync_reset",
        scope: "status",
        reason: "state_unavailable",
      });
    }
    const current = statusEntries(this.catalog);
    const changes = [...current]
      .filter(([key, value]) => {
        const prior = previous?.get(key);
        return !prior || stableJson(prior) !== stableJson(value);
      })
      .map(([, value]) => value);
    const pages = chunkByJsonBytes(changes, FRAME_CONTENT_BUDGET);
    const effectivePages = pages.length > 0 ? pages : [[]];
    effectivePages.forEach((page, pageIndex) => {
      const sequence = this.sendEvent(client, subscription, {
        event: "status_changes",
        statusState: this.statusState,
        pageIndex,
        pageCount: effectivePages.length,
        changes: page,
      });
      if (pageIndex === effectivePages.length - 1) {
        subscription.pendingStatusState = this.statusState;
        this.mergeCommit(subscription, sequence, {
          statusState: this.statusState,
        });
      }
    });
  }

  private async sendTimelineRecords(
    client: object,
    subscription: SyncSubscription,
    records: CatalogRecord[],
  ): Promise<boolean> {
    for (
      let offset = 0;
      offset < records.length;
      offset += PROVIDER_HISTORY_CONCURRENCY
    ) {
      if (
        subscription.queuedBytes + subscription.outstandingBytes >=
        SYNC_BACKPRESSURE_BYTES
      ) {
        return false;
      }
      const batch = records.slice(
        offset,
        offset + PROVIDER_HISTORY_CONCURRENCY,
      );
      const snapshots = await Promise.all(
        batch.map(async (record) => {
          const key = targetKey(record.entry);
          const known =
            subscription.pendingThreadStates.get(key) ??
            subscription.threadStates.get(key);
          if (known === record.entry.revision) return null;
          return this.snapshotFor(record);
        }),
      );
      for (let index = 0; index < batch.length; index += 1) {
        const snapshot = snapshots[index];
        if (!snapshot) continue;
        this.sendTimeline(client, subscription, batch[index]!, snapshot);
      }
      if (
        subscription.queuedBytes + subscription.outstandingBytes >=
        SYNC_BACKPRESSURE_BYTES
      ) {
        return offset + batch.length >= records.length;
      }
    }
    return true;
  }

  private async snapshotFor(
    record: CatalogRecord,
  ): Promise<ConversationContentSnapshot> {
    const key = targetKey(record.entry);
    // Capture the revision before the provider read begins. Runtime messages
    // can mutate the catalog record while this await is in flight; labelling
    // an older read with that newer revision would make every subscriber treat
    // missing content as committed and suppress the required follow-up read.
    const requestedRevision = record.entry.revision;
    const target: ConversationSyncTarget = {
      provider: record.entry.provider,
      providerSessionId: record.entry.providerSessionId,
    };
    const preserveLatestRootTurnTools =
      record.status.activity === "working" ||
      record.status.activity === "compacting";
    const cached = this.snapshots
      .get(key)
      ?.find((snapshot) => snapshot.revision === requestedRevision);
    if (cached) return cached;
    const existing = this.snapshotFlights.get(key);
    if (existing) return existing;
    const flight = this.historyReader(target)
      .then((history) => {
        const window = normalizeHistoryWindow(history);
        for (const turn of window.turnDetails ?? []) {
          this.rememberTurnDetails(target, turn);
        }
        const built = buildConversationContentSnapshot(
          target,
          window.messages,
          {
            maxMessageTextBytes: MAX_MESSAGE_TEXT_BYTES,
            maxSnapshotBytes: MAX_TIMELINE_BYTES,
            preserveLatestRootTurnTools,
          },
        );
        const snapshot = {
          ...built,
          revision: requestedRevision,
          hasEarlier: built.hasEarlier || window.nextTurnCursor != null,
          turnsNextCursor: window.nextTurnCursor,
        };
        this.rememberSnapshot(key, snapshot);
        return snapshot;
      })
      .finally(() => {
        if (this.snapshotFlights.get(key) === flight) {
          this.snapshotFlights.delete(key);
        }
      });
    this.snapshotFlights.set(key, flight);
    return flight;
  }

  private sendTimeline(
    client: object,
    subscription: SyncSubscription,
    record: CatalogRecord,
    snapshot: ConversationContentSnapshot,
  ): void {
    const key = targetKey(record.entry);
    const known = subscription.threadStates.get(key);
    const base = known
      ? this.snapshots
          .get(key)
          ?.find((candidate) => candidate.revision === known)
      : undefined;
    const sent = base
      ? this.sendTimelinePatch(client, subscription, base, snapshot)
      : false;
    if (!sent) this.sendTimelineSnapshot(client, subscription, snapshot);
    subscription.pendingThreadStates.set(key, snapshot.revision);
  }

  private sendTimelinePatch(
    client: object,
    subscription: SyncSubscription,
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
    const pages = this.timelinePages(snapshot, upserts);
    const deletePages = chunkByJsonBytes(deletes, FRAME_CONTENT_BUDGET);
    const pageCount = Math.max(pages.length, deletePages.length, 1);
    let finalSequence = -1;
    for (let pageIndex = 0; pageIndex < pageCount; pageIndex += 1) {
      finalSequence = this.sendEvent(client, subscription, {
        event: "timeline_page",
        provider: snapshot.provider,
        providerSessionId: snapshot.providerSessionId,
        revision: snapshot.revision,
        baseRevision: base.revision,
        mode: "patch",
        pageIndex,
        pageCount,
        entries: (pages[pageIndex] ?? []).map(toWireConversationContentEntry),
        deletes: deletePages[pageIndex] ?? [],
        hasEarlier: snapshot.hasEarlier,
        turnsNextCursor: snapshot.turnsNextCursor,
        sourceEntryCount: snapshot.sourceEntryCount,
      });
    }
    if (finalSequence < 0) return false;
    this.mergeCommit(subscription, finalSequence, {
      thread: {
        key: targetKey(snapshot),
        revision: snapshot.revision,
      },
    });
    return true;
  }

  private sendTimelineSnapshot(
    client: object,
    subscription: SyncSubscription,
    snapshot: ConversationContentSnapshot,
  ): void {
    const pages = this.timelinePages(snapshot, snapshot.entries);
    const effectivePages = pages.length > 0 ? pages : [[]];
    let finalSequence = -1;
    effectivePages.forEach((page, pageIndex) => {
      finalSequence = this.sendEvent(client, subscription, {
        event: "timeline_page",
        provider: snapshot.provider,
        providerSessionId: snapshot.providerSessionId,
        revision: snapshot.revision,
        mode: "snapshot",
        pageIndex,
        pageCount: effectivePages.length,
        entries: page.map(toWireConversationContentEntry),
        deletes: [],
        hasEarlier: snapshot.hasEarlier,
        turnsNextCursor: snapshot.turnsNextCursor,
        sourceEntryCount: snapshot.sourceEntryCount,
      });
    });
    this.mergeCommit(subscription, finalSequence, {
      thread: {
        key: targetKey(snapshot),
        revision: snapshot.revision,
      },
    });
  }

  private timelinePages(
    snapshot: ConversationContentSnapshot,
    entries: readonly ConversationContentSnapshotEntry[],
  ): ConversationContentSnapshotEntry[][] {
    const envelopeBytes = Buffer.byteLength(
      JSON.stringify({
        type: CONVERSATION_SYNC_V2_CAPABILITY,
        subscriptionId: "x".repeat(128),
        bridgeInstanceId: this.runtime.bridgeInstanceId,
        codexSourceId: this.runtime.codexSourceId,
        batchId: "x".repeat(128),
        sequence: Number.MAX_SAFE_INTEGER,
        event: "timeline_page",
        provider: snapshot.provider,
        providerSessionId: snapshot.providerSessionId,
        revision: snapshot.revision,
        mode: "snapshot",
        pageIndex: Number.MAX_SAFE_INTEGER,
        pageCount: Number.MAX_SAFE_INTEGER,
        entries: [],
        deletes: [],
        hasEarlier: snapshot.hasEarlier,
        turnsNextCursor: snapshot.turnsNextCursor,
        sourceEntryCount: snapshot.sourceEntryCount,
      }),
      "utf8",
    );
    return paginateConversationContentEntries(
      entries,
      MAX_TIMELINE_PAGE_ENTRIES,
      MAX_FRAME_BYTES,
      envelopeBytes,
    );
  }

  private orderedRecords(subscription: SyncSubscription): CatalogRecord[] {
    const focused = subscription.focusedKey;
    return [...this.catalog.values()].sort((left, right) => {
      const leftKey = targetKey(left.entry);
      const rightKey = targetKey(right.entry);
      if (leftKey === focused && rightKey !== focused) return -1;
      if (rightKey === focused && leftKey !== focused) return 1;
      const specialDifference =
        Number(this.isSpecial(right, subscription)) -
        Number(this.isSpecial(left, subscription));
      if (specialDifference !== 0) return specialDifference;
      return right.entry.recencyAt.localeCompare(left.entry.recencyAt);
    });
  }

  private isPriorityRecord(
    record: CatalogRecord,
    index: number,
    subscription: SyncSubscription,
  ): boolean {
    return (
      index < PRIORITY_RECENT_COUNT ||
      targetKey(record.entry) === subscription.focusedKey ||
      this.isSpecial(record, subscription)
    );
  }

  private isSpecial(
    record: CatalogRecord,
    subscription: SyncSubscription,
  ): boolean {
    if (
      record.status.activity === "working" ||
      record.status.activity === "compacting" ||
      record.status.activity === "systemError" ||
      record.status.attention !== "none"
    ) {
      return true;
    }
    if (record.status.result === "none") return false;
    const readAt = subscription.readWatermarks.get(targetKey(record.entry));
    if (!readAt) return true;
    const readTime = Date.parse(readAt);
    const observedTime = Date.parse(record.status.observedAt);
    return (
      !Number.isFinite(readTime) ||
      !Number.isFinite(observedTime) ||
      readTime < observedTime
    );
  }

  private isRecentRecord(record: CatalogRecord, index: number): boolean {
    const recency = Date.parse(record.entry.recencyAt);
    return (
      index < MIN_RECENT_COUNT ||
      (Number.isFinite(recency) && Date.now() - recency <= RECENT_WINDOW_MS)
    );
  }

  private refreshCatalog(): Promise<void> {
    if (!this.catalogDirty) return Promise.resolve();
    if (this.catalogFlight) return this.catalogFlight;
    const flight = (async () => {
      do {
        this.catalogDirty = false;
        const seeds = await this.catalogReader();
        if (this.closed) return;
        const previousStatuses = statusEntries(this.catalog);
        const next = new Map<ConversationKey, CatalogRecord>();
        for (const seed of seeds.slice(0, MAX_CATALOG_ENTRIES)) {
          if (seed.entry.availability === "ephemeral") continue;
          const key = targetKey(seed.entry);
          const live = this.liveContentRevisions.get(key);
          if (
            live &&
            Date.parse(seed.entry.recencyAt) >= Date.parse(live.observedAt)
          ) {
            this.liveContentRevisions.delete(key);
          }
          const previous = previousStatuses.get(key);
          next.set(key, {
            entry: seed.entry,
            status: preserveObservedAt(previous, seed.status),
          });
        }
        this.catalog = next;
        this.applyRuntimeOverlay();
        for (const key of this.liveContentRevisions.keys()) {
          if (!this.catalog.has(key)) this.liveContentRevisions.delete(key);
        }
        for (const key of this.resultLedger.keys()) {
          if (!this.catalog.has(key)) this.resultLedger.delete(key);
        }
        this.recomputeStates();
      } while (this.catalogDirty && !this.closed);
    })()
      .catch((error) => {
        this.catalogDirty = true;
        throw error;
      })
      .finally(() => {
        if (this.catalogFlight === flight) this.catalogFlight = undefined;
      });
    this.catalogFlight = flight;
    return flight;
  }

  private refreshStatuses(): Promise<void> {
    if (this.statusFlight) return this.statusFlight;
    const flight = this.statusReader(this.catalog)
      .then((statuses) => {
        if (this.closed) return;
        for (const [key, status] of statuses) {
          const record = this.catalog.get(key);
          if (!record) continue;
          record.status = preserveObservedAt(record.status, status);
        }
        this.applyRuntimeOverlay();
        this.recomputeStates();
        for (const [client, subscription] of this.subscriptions) {
          if (subscription.interactive) this.scheduleSync(client, subscription);
        }
      })
      .finally(() => {
        if (this.statusFlight === flight) this.statusFlight = undefined;
      });
    this.statusFlight = flight;
    return flight;
  }

  private applyRuntimeOverlay(): void {
    const runtimeStates = this.runtime.listRuntimeConversationStates?.() ?? [];
    for (const runtimeState of runtimeStates) {
      const target = targetFromRuntime(runtimeState);
      if (!target) continue;
      const key = targetKey(target);
      let record = this.catalog.get(key);
      if (!record) {
        const timestamp = validIso(runtimeState.observedAt)
          ? runtimeState.observedAt
          : new Date().toISOString();
        record = {
          entry: {
            ...target,
            revision: providerRevision(target, timestamp),
            projectPath: runtimeState.projectPath,
            createdAt: timestamp,
            modifiedAt: timestamp,
            recencyAt: timestamp,
            availability: "durable",
          },
          status: unknownStatus(target, timestamp, "bridgeRuntime"),
        };
        this.catalog.set(key, record);
      }
      record.status = statusFromRuntime(runtimeState, record.status);
    }
    for (const [key, live] of this.liveContentRevisions) {
      const record = this.catalog.get(key);
      if (!record) continue;
      record.entry.modifiedAt = live.observedAt;
      record.entry.recencyAt = live.observedAt;
      record.entry.revision = live.revision;
    }
    for (const [key, result] of this.resultLedger) {
      const record = this.catalog.get(key);
      if (!record) continue;
      record.status = {
        ...record.status,
        result: result.result,
        observedAt:
          result.observedAt > record.status.observedAt
            ? result.observedAt
            : record.status.observedAt,
      };
    }
  }

  private recomputeStates(): void {
    const catalog = catalogEntries(this.catalog);
    const statuses = statusEntries(this.catalog);
    this.catalogState = hashState([...catalog].sort(compareStateEntries));
    this.statusState = hashState([...statuses].sort(compareStateEntries));
    rememberState(this.catalogHistory, this.catalogState, catalog);
    rememberState(this.statusHistory, this.statusState, statuses);
  }

  private rememberSnapshot(
    key: ConversationKey,
    snapshot: ConversationContentSnapshot,
  ): void {
    const existing = this.snapshots.get(key) ?? [];
    this.snapshots.delete(key);
    this.snapshots.set(key, [
      ...existing
        .filter((candidate) => candidate.revision !== snapshot.revision)
        .slice(-1),
      snapshot,
    ]);
    while (this.snapshots.size > MAX_SNAPSHOT_TARGETS) {
      const oldest = this.snapshots.keys().next().value;
      if (oldest === undefined) break;
      this.snapshots.delete(oldest);
    }
  }

  private rememberTurnDetails(
    target: ConversationSyncTarget,
    turn: ConversationTurnDetails,
  ): void {
    if (!turn.turnId || turn.details.length === 0) return;
    const key = turnDetailKey(target, turn.turnId);
    const details = new Map(
      turn.details.map((detail) => [detail.toolUseId, detail]),
    );
    const bytes = Buffer.byteLength(
      JSON.stringify([...details.values()]),
      "utf8",
    );
    if (bytes > MAX_TURN_DETAIL_CACHE_BYTES) return;
    const previous = this.turnDetailCache.get(key);
    if (previous) this.turnDetailCacheBytes -= previous.bytes;
    this.turnDetailCache.delete(key);
    this.turnDetailCache.set(key, { details, bytes });
    this.turnDetailCacheBytes += bytes;
    while (
      this.turnDetailCache.size > MAX_TURN_DETAIL_CACHE_ENTRIES ||
      this.turnDetailCacheBytes > MAX_TURN_DETAIL_CACHE_BYTES
    ) {
      const oldestKey = this.turnDetailCache.keys().next().value;
      if (oldestKey === undefined) break;
      const oldest = this.turnDetailCache.get(oldestKey);
      this.turnDetailCache.delete(oldestKey);
      if (oldest) this.turnDetailCacheBytes -= oldest.bytes;
    }
  }

  private cachedTurnDetails(
    target: ConversationSyncTarget,
    turnId: string,
    toolUseIds: readonly string[],
  ): HistoryToolDetailPayload[] | null {
    const key = turnDetailKey(target, turnId);
    const cached = this.turnDetailCache.get(key);
    if (!cached) return null;
    const details = toolUseIds
      .map((toolUseId) => cached.details.get(toolUseId))
      .filter(
        (detail): detail is HistoryToolDetailPayload => detail !== undefined,
      );
    if (details.length !== toolUseIds.length) return null;
    this.turnDetailCache.delete(key);
    this.turnDetailCache.set(key, cached);
    return details;
  }

  private ensureTimers(): void {
    if (this.closed || !this.hasInteractiveClients()) return;
    if (!this.watchdogTimer) {
      this.watchdogTimer = setTimeout(() => {
        this.watchdogTimer = undefined;
        void this.refreshStatuses()
          .catch((error) => {
            this.reportBackgroundError("status_refresh_failed", error);
          })
          .finally(() => this.ensureTimers());
      }, this.statusWatchdogMs);
      this.watchdogTimer.unref?.();
    }
    if (!this.coldTimer) {
      const jitter = Math.floor(this.coldReconcileMs * Math.random() * 0.1);
      this.coldTimer = setTimeout(() => {
        this.coldTimer = undefined;
        this.catalogDirty = true;
        void this.refreshCatalog()
          .then(() => this.scheduleInteractiveClients())
          .catch((error) => {
            this.reportBackgroundError("catalog_refresh_failed", error);
          })
          .finally(() => this.ensureTimers());
      }, this.coldReconcileMs + jitter);
      this.coldTimer.unref?.();
    }
  }

  private cancelTimers(): void {
    if (this.watchdogTimer) clearTimeout(this.watchdogTimer);
    if (this.coldTimer) clearTimeout(this.coldTimer);
    if (this.liveContentTimer) clearTimeout(this.liveContentTimer);
    this.watchdogTimer = undefined;
    this.coldTimer = undefined;
    this.liveContentTimer = undefined;
  }

  private queueLiveContent(
    target: ConversationSyncTarget,
    observedAt: string,
  ): void {
    this.pendingLiveContent.set(targetKey(target), { target, observedAt });
    if (this.liveContentTimer || this.closed) return;
    this.liveContentTimer = setTimeout(() => {
      this.liveContentTimer = undefined;
      this.flushPendingLiveContent();
    }, LIVE_CONTENT_BATCH_MS);
    this.liveContentTimer.unref?.();
  }

  private publishLiveContent(
    target: ConversationSyncTarget,
    observedAt: string,
  ): void {
    this.pendingLiveContent.delete(targetKey(target));
    if (this.pendingLiveContent.size === 0 && this.liveContentTimer) {
      clearTimeout(this.liveContentTimer);
      this.liveContentTimer = undefined;
    }
    this.rememberLiveContent(target, observedAt);
    this.applyRuntimeOverlay();
    this.recomputeStates();
    this.scheduleInteractiveClients();
  }

  private flushPendingLiveContent(): void {
    if (this.closed || this.pendingLiveContent.size === 0) return;
    const pending = [...this.pendingLiveContent.values()];
    this.pendingLiveContent.clear();
    for (const { target, observedAt } of pending) {
      this.rememberLiveContent(target, observedAt);
    }
    this.applyRuntimeOverlay();
    this.recomputeStates();
    this.scheduleInteractiveClients();
  }

  private rememberLiveContent(
    target: ConversationSyncTarget,
    observedAt: string,
  ): void {
    this.liveContentRevisions.set(targetKey(target), {
      target,
      observedAt,
      revision: providerRevision(
        target,
        `${observedAt}:${++this.liveRevision}`,
      ),
    });
  }

  private scheduleInteractiveClients(): void {
    for (const [client, subscription] of this.subscriptions) {
      if (subscription.interactive) this.scheduleSync(client, subscription);
    }
  }

  private reportBackgroundError(errorCode: string, error: unknown): void {
    for (const [client, subscription] of this.subscriptions) {
      if (!subscription.interactive) continue;
      try {
        this.sendError(
          client,
          subscription,
          undefined,
          errorCode,
          errorMessage(error),
        );
      } catch {
        subscription.dirty = true;
      }
    }
  }

  private async sendTurnsPage(
    client: object,
    message: Extract<
      ConversationSyncClientMessage,
      { type: "conversation_turns_page" }
    >,
    signal: AbortSignal,
  ): Promise<void> {
    const subscription = this.validSubscription(client, message.subscriptionId);
    if (!subscription) return;
    try {
      const page = await readTurnsPage(
        this.runtime,
        message,
        this.historyReader,
        signal,
      );
      for (const turn of page.turnDetails ?? []) {
        this.rememberTurnDetails(message, turn);
      }
      this.sendEvent(client, subscription, {
        event: "turns_page_response",
        requestId: message.requestId,
        provider: message.provider,
        providerSessionId: message.providerSessionId,
        data: page.data,
        nextCursor: page.nextCursor,
      });
    } catch (error) {
      this.sendError(
        client,
        subscription,
        message.requestId,
        "turns_page_failed",
        errorMessage(error),
        message,
      );
    }
  }

  private async sendItemsPage(
    client: object,
    message: Extract<
      ConversationSyncClientMessage,
      { type: "conversation_items_page" }
    >,
    signal: AbortSignal,
  ): Promise<void> {
    const subscription = this.validSubscription(client, message.subscriptionId);
    if (!subscription) return;
    try {
      const cached =
        message.turnId && message.toolUseIds
          ? this.cachedTurnDetails(message, message.turnId, message.toolUseIds)
          : null;
      const page = cached
        ? historyToolDetailsPage(message, cached)
        : await readItemsPage(
            this.runtime,
            message,
            this.historyReader,
            signal,
          );
      if (page.turnDetails) {
        this.rememberTurnDetails(message, page.turnDetails);
      }
      this.sendEvent(client, subscription, {
        event: "items_page_response",
        requestId: message.requestId,
        provider: message.provider,
        providerSessionId: message.providerSessionId,
        ...(message.turnId ? { turnId: message.turnId } : {}),
        data: page.data,
        nextCursor: page.nextCursor,
      });
    } catch (error) {
      this.sendError(
        client,
        subscription,
        message.requestId,
        "items_page_failed",
        errorMessage(error),
        message,
      );
    }
  }

  private validSubscription(
    client: object,
    subscriptionId: string,
  ): SyncSubscription | null {
    const subscription = this.subscriptions.get(client);
    return subscription?.id === subscriptionId ? subscription : null;
  }

  private targetForSession(
    session: LocalFeatureSession,
  ): ConversationSyncTarget | null {
    if (session.provider !== "claude" && session.provider !== "codex") {
      return null;
    }
    const providerSessionId =
      this.runtime.getProviderSessionId?.(session) ??
      (session.provider === "codex"
        ? this.runtime.getCodexThreadId(session)
        : undefined);
    return providerSessionId
      ? { provider: session.provider, providerSessionId }
      : null;
  }

  private sendError(
    client: object,
    subscription: SyncSubscription,
    requestId: string | undefined,
    errorCode: string,
    error: string,
    target?: ConversationSyncTarget,
  ): void {
    this.sendEvent(client, subscription, {
      event: "error",
      ...(requestId ? { requestId } : {}),
      errorCode,
      error,
      ...(target
        ? {
            target: {
              provider: target.provider,
              providerSessionId: target.providerSessionId,
            },
          }
        : {}),
    });
  }

  private sendEvent(
    client: object,
    subscription: SyncSubscription,
    payload: ConversationSyncEventPayload,
  ): number {
    const sequence = ++subscription.nextSequence;
    const message = {
      type: CONVERSATION_SYNC_V2_CAPABILITY,
      subscriptionId: subscription.id,
      bridgeInstanceId: this.runtime.bridgeInstanceId ?? "unavailable",
      codexSourceId: this.runtime.codexSourceId ?? "legacy",
      batchId: subscription.batchId,
      sequence,
      ...payload,
    } as ConversationSyncServerMessage;
    const bytes = Buffer.byteLength(JSON.stringify(message), "utf8");
    if (bytes > MAX_FRAME_BYTES) {
      throw new Error(
        `conversation_sync_v2 frame exceeds ${MAX_FRAME_BYTES} bytes`,
      );
    }
    if (subscription.queuedBytes + bytes > MAX_QUEUED_BYTES) {
      throw new Error(
        "conversation_sync_v2 outbound queue exceeded byte budget",
      );
    }
    subscription.outbound.push({ sequence, bytes, message });
    subscription.queuedBytes += bytes;
    this.flush(client, subscription);
    return sequence;
  }

  private flush(client: object, subscription: SyncSubscription): void {
    if (!subscription.interactive || !this.clientReady(client)) return;
    while (subscription.outbound.length > 0) {
      const frame = subscription.outbound[0]!;
      if (
        subscription.outstandingBytes > 0 &&
        subscription.outstandingBytes + frame.bytes > MAX_UNACKED_BYTES
      ) {
        break;
      }
      subscription.outbound.shift();
      subscription.queuedBytes = Math.max(
        0,
        subscription.queuedBytes - frame.bytes,
      );
      this.runtime.send(client, frame.message);
      subscription.outstanding.set(frame.sequence, frame.bytes);
      subscription.outstandingBytes += frame.bytes;
    }
  }

  private mergeCommit(
    subscription: SyncSubscription,
    sequence: number,
    commit: FrameCommit,
  ): void {
    subscription.commits.set(sequence, {
      ...(subscription.commits.get(sequence) ?? {}),
      ...commit,
    });
  }

  private clientReady(client: object): boolean {
    return (
      (this.runtime.isClientOpen?.(client) ?? true) &&
      this.runtime.supports(client, CONVERSATION_SYNC_V2_CAPABILITY)
    );
  }

  private hasInteractiveClients(): boolean {
    return [...this.subscriptions.values()].some(
      (subscription) => subscription.interactive,
    );
  }
}

async function readUnifiedCatalog(
  runtime: LocalFeatureRuntime,
): Promise<ConversationSyncCatalogSeed[]> {
  const [claude, codex] = await Promise.all([
    getAllRecentSessions({
      provider: "claude",
      limit: MAX_CATALOG_ENTRIES,
      offset: 0,
      metadataOnly: true,
    }).then((result) => result.sessions.map(sessionSeed)),
    readCodexCatalog(runtime),
  ]);
  return [...codex, ...claude]
    .sort((left, right) =>
      right.entry.recencyAt.localeCompare(left.entry.recencyAt),
    )
    .slice(0, MAX_CATALOG_ENTRIES);
}

async function readCodexCatalog(
  runtime: LocalFeatureRuntime,
): Promise<ConversationSyncCatalogSeed[]> {
  try {
    return await withCodexProcess(runtime, undefined, async (process) => {
      const seeds: ConversationSyncCatalogSeed[] = [];
      let cursor: string | null = null;
      do {
        const page = await process.listThreads({
          cursor,
          limit: Math.min(CODEX_PAGE_SIZE, MAX_CATALOG_ENTRIES - seeds.length),
          sortKey: "recency_at",
          sortDirection: "desc",
          archived: false,
          useStateDbOnly: true,
        });
        for (const thread of page.data) {
          if (!thread.id || thread.ephemeral) continue;
          seeds.push(codexThreadSeed(thread));
          if (seeds.length >= MAX_CATALOG_ENTRIES) break;
        }
        cursor = page.nextCursor;
      } while (cursor && seeds.length < MAX_CATALOG_ENTRIES);
      return seeds;
    });
  } catch (error) {
    if (!isUnsupportedAppServerRead(error)) throw error;
    const fallback = await getAllRecentSessions({
      provider: "codex",
      limit: MAX_CATALOG_ENTRIES,
      offset: 0,
      metadataOnly: true,
    });
    return fallback.sessions.map(sessionSeed);
  }
}

async function readCurrentStatuses(
  runtime: LocalFeatureRuntime,
  current: ReadonlyMap<ConversationKey, CatalogRecord>,
): Promise<Map<ConversationKey, ConversationSyncStatus>> {
  const statuses = new Map<ConversationKey, ConversationSyncStatus>();
  try {
    const codex = await readCodexCatalog(runtime);
    for (const seed of codex) statuses.set(targetKey(seed.entry), seed.status);
  } catch {
    for (const [key, record] of current) {
      if (record.entry.provider === "codex") {
        statuses.set(key, {
          ...record.status,
          activity: "unknown",
          confidence: "unknown",
          source: "appServer",
        });
      }
    }
  }
  return statuses;
}

async function readRecentConversationHistory(
  runtime: LocalFeatureRuntime,
  target: ConversationSyncTarget,
): Promise<ConversationHistoryWindow> {
  if (target.provider !== "codex") {
    return readLegacyHistoryWindow(target);
  }
  try {
    return await withCodexProcess(runtime, undefined, async (process) => {
      const page = await process.listThreadTurns({
        threadId: target.providerSessionId,
        limit: 5,
        sortDirection: "desc",
        // The current app-server summary view keeps only the user/final spine
        // and omits tool ids/counts. Read one bounded full page at the Bridge,
        // then compact the older two turns before crossing the wire.
        itemsView: "full",
      });
      const turns = [...page.data].reverse();
      const normalized = normalizeCodexTurns(
        turns,
        "full",
        target.providerSessionId,
      );
      const fullStart = Math.max(
        0,
        normalized.turns.length - FULL_RECENT_TURNS,
      );
      return {
        messages: normalized.turns.flatMap((turn, index) =>
          index < fullStart
            ? compactTurnMessages(turn.messages, turn.turnId)
            : turn.messages,
        ),
        nextTurnCursor: page.nextCursor,
        turnDetails: normalized.turnDetails,
      };
    });
  } catch (error) {
    if (!isUnsupportedAppServerRead(error)) throw error;
    return readLegacyHistoryWindow(target);
  }
}

async function readLegacyHistoryWindow(
  target: ConversationSyncTarget,
): Promise<ConversationHistoryWindow> {
  const messages = await readDurableConversationHistory(target);
  const turns = groupLegacyTurns(messages);
  const recentStart = Math.max(0, turns.length - PRIORITY_RECENT_COUNT);
  const fullStart = Math.max(recentStart, turns.length - FULL_RECENT_TURNS);
  const normalizedMessages = turns.flatMap((turn, index) => {
    const annotated = annotateTurnMessages(turn.items, turn.id);
    if (index >= recentStart && index < fullStart) {
      return compactTurnMessages(annotated, turn.id);
    }
    return annotated;
  });
  const turnDetails = turns
    .slice(recentStart)
    .map((turn) => ({
      turnId: turn.id,
      details: historyToolDetailPayloads(
        annotateTurnMessages(turn.items, turn.id),
      ),
    }))
    .filter((turn) => turn.details.length > 0);
  return {
    messages: normalizedMessages,
    nextTurnCursor:
      turns.length > PRIORITY_RECENT_COUNT
        ? String(PRIORITY_RECENT_COUNT)
        : null,
    turnDetails,
  };
}

async function readTurnsPage(
  runtime: LocalFeatureRuntime,
  message: Extract<
    ConversationSyncClientMessage,
    { type: "conversation_turns_page" }
  >,
  historyReader: (
    target: ConversationSyncTarget,
  ) => Promise<ServerMessage[] | ConversationHistoryWindow>,
  signal: AbortSignal,
): Promise<ConversationTurnsPage> {
  if (message.provider === "codex") {
    return withCodexProcess(runtime, undefined, async (process) => {
      const page = await process.listThreadTurns(
        {
          threadId: message.providerSessionId,
          cursor: message.cursor,
          limit: message.limit ?? 5,
          sortDirection: message.sortDirection ?? "desc",
          // `summary` currently omits all tool ids. A bounded full provider
          // page is compacted at the Bridge so Mobile still receives a useful
          // process shell without the heavy details.
          itemsView: "full",
        },
        { signal },
      );
      const chronologicalTurns =
        (message.sortDirection ?? "desc") === "desc"
          ? [...page.data].reverse()
          : page.data;
      const normalized = normalizeCodexTurns(
        chronologicalTurns,
        message.itemsView ?? "summary",
        message.providerSessionId,
      );
      return {
        data: normalized.turns,
        nextCursor: page.nextCursor,
        turnDetails: normalized.turnDetails,
      };
    });
  }
  const history = normalizeHistoryWindow(await historyReader(message));
  const cachedDetailsByTurn = new Map(
    (history.turnDetails ?? []).map((turn) => [turn.turnId, turn.details]),
  );
  const turns = groupLegacyTurns(history.messages).map((turn) => {
    const annotated = annotateTurnMessages(turn.items, turn.id);
    return {
      turnId: turn.id,
      messages:
        (message.itemsView ?? "summary") === "summary"
          ? compactTurnMessages(annotated, turn.id)
          : annotated,
      itemCount: turn.items.length,
      itemsView: message.itemsView ?? "summary",
      details:
        cachedDetailsByTurn.get(turn.id) ??
        historyToolDetailPayloads(annotated),
    };
  });
  const page = paginateArray(
    turns,
    message.cursor,
    message.limit ?? 5,
    message.sortDirection ?? "desc",
  );
  return {
    data:
      (message.sortDirection ?? "desc") === "desc"
        ? [...page.data].reverse().map(({ details: _, ...turn }) => turn)
        : page.data.map(({ details: _, ...turn }) => turn),
    nextCursor: page.nextCursor,
    turnDetails: page.data
      .filter((turn) => turn.details.length > 0)
      .map((turn) => ({ turnId: turn.turnId, details: turn.details })),
  };
}

async function readItemsPage(
  runtime: LocalFeatureRuntime,
  message: Extract<
    ConversationSyncClientMessage,
    { type: "conversation_items_page" }
  >,
  historyReader: (
    target: ConversationSyncTarget,
  ) => Promise<ServerMessage[] | ConversationHistoryWindow>,
  signal: AbortSignal,
): Promise<ConversationItemsPage> {
  if (message.provider === "codex") {
    return withCodexProcess(runtime, undefined, async (process) => {
      const turnId = message.turnId ?? "paged-items";
      let messages: ServerMessage[];
      let nextCursor: string | null = null;
      try {
        const page = await process.listThreadItems(
          {
            threadId: message.providerSessionId,
            turnId: message.turnId,
            cursor: message.cursor,
            limit: message.limit ?? 200,
            sortDirection: message.sortDirection ?? "asc",
          },
          { signal },
        );
        // The official response is ThreadItemEntry { turnId, item }, not a
        // bare ThreadItem. Accept the bare form as a forward-compatible
        // fallback for older experimental app-server builds.
        const items = page.data.map(unwrapCodexThreadItem);
        messages = codexTurnMessages(
          { id: turnId, items },
          message.providerSessionId,
        );
        nextCursor = page.nextCursor;
      } catch (error) {
        if (!message.turnId || !isUnsupportedAppServerRead(error)) throw error;
        messages = await findCodexTurnMessages(
          process,
          message.providerSessionId,
          message.turnId,
          signal,
        );
      }
      const details = historyToolDetailPayloads(messages, message.toolUseIds);
      const turnDetails = {
        turnId,
        details: historyToolDetailPayloads(messages),
      };
      if (message.toolUseIds) {
        return {
          ...historyToolDetailsPage(message, details),
          turnDetails,
        };
      }
      return {
        data: messages,
        nextCursor,
        turnDetails,
      };
    });
  }
  const history = normalizeHistoryWindow(await historyReader(message));
  const turns = groupLegacyTurns(history.messages);
  const selected = message.turnId
    ? (turns.find((turn) => turn.id === message.turnId)?.items ?? [])
    : turns.flatMap((turn) => turn.items);
  const annotated = message.turnId
    ? annotateTurnMessages(selected, message.turnId)
    : selected;
  if (message.toolUseIds) {
    const cached = message.turnId
      ? history.turnDetails?.find((turn) => turn.turnId === message.turnId)
          ?.details
      : undefined;
    const cachedById = new Map(
      (cached ?? []).map((detail) => [detail.toolUseId, detail]),
    );
    const details =
      cached &&
      message.toolUseIds.every((toolUseId) => cachedById.has(toolUseId))
        ? message.toolUseIds
            .map((toolUseId) => cachedById.get(toolUseId))
            .filter(
              (detail): detail is HistoryToolDetailPayload =>
                detail !== undefined,
            )
        : historyToolDetailPayloads(annotated, message.toolUseIds);
    return {
      ...historyToolDetailsPage(message, details),
      ...(message.turnId
        ? {
            turnDetails: {
              turnId: message.turnId,
              details: cached ?? historyToolDetailPayloads(annotated),
            },
          }
        : {}),
    };
  }
  return paginateArray(
    annotated,
    message.cursor,
    message.limit ?? 50,
    message.sortDirection ?? "asc",
  );
}

function normalizeHistoryWindow(
  history: ServerMessage[] | ConversationHistoryWindow,
): ConversationHistoryWindow {
  return Array.isArray(history)
    ? { messages: history, nextTurnCursor: null }
    : history;
}

function normalizeCodexTurns(
  rawTurns: readonly unknown[],
  itemsView: "summary" | "full",
  threadId: string,
): {
  turns: NormalizedConversationTurn[];
  turnDetails: ConversationTurnDetails[];
} {
  const turns: NormalizedConversationTurn[] = [];
  const turnDetails: ConversationTurnDetails[] = [];
  rawTurns.forEach((rawTurn, index) => {
    if (!rawTurn || typeof rawTurn !== "object") return;
    const turn = rawTurn as Record<string, unknown>;
    const rawId = turn.id;
    const turnId =
      typeof rawId === "string" && rawId.trim()
        ? rawId.trim()
        : `turn:${hashState([threadId, index, turn]).slice(0, 24)}`;
    const items = Array.isArray(turn.items) ? turn.items : [];
    const fullMessages = annotateTurnMessages(
      codexTurnMessages({ ...turn, id: turnId }, threadId),
      turnId,
    );
    const details = historyToolDetailPayloads(fullMessages);
    if (details.length > 0) turnDetails.push({ turnId, details });
    turns.push({
      turnId,
      messages:
        itemsView === "summary"
          ? compactTurnMessages(fullMessages, turnId)
          : fullMessages,
      itemCount: items.length,
      itemsView,
    });
  });
  return { turns, turnDetails };
}

function codexTurnMessages(
  turn: Record<string, unknown>,
  threadId: string,
): ServerMessage[] {
  const history = codexThreadToSessionHistory({
    id: threadId,
    turns: [turn],
  });
  return sessionHistoryToServerMessages(history, {
    idPrefix: `conversation-sync-v2-page-${threadId}`,
  });
}

function annotateTurnMessages(
  messages: readonly ServerMessage[],
  turnId: string,
): ServerMessage[] {
  return messages.map((message) => {
    if (message.type === "assistant" || message.type === "tool_result") {
      return { ...message, historyTurnId: turnId };
    }
    return message;
  });
}

function compactTurnMessages(
  messages: readonly ServerMessage[],
  turnId: string,
): ServerMessage[] {
  const annotated = annotateTurnMessages(messages, turnId);
  return selectTurnAwareHistoryWindow(
    annotated.map((message, sourceIndex) => ({ message, sourceIndex })),
    {
      rootTurns: 1,
      toolCalls: 0,
      envelopeEntries: TURN_AWARE_HISTORY_ENVELOPE_ENTRIES,
    },
  ).map((entry) => entry.message);
}

function historyToolDetailPayloads(
  messages: readonly ServerMessage[],
  requestedIds?: readonly string[],
): HistoryToolDetailPayload[] {
  const requested = requestedIds ? new Set(requestedIds) : null;
  const details = new Map<string, HistoryToolDetailPayload>();
  for (const message of messages) {
    if (message.type === "assistant") {
      for (const content of message.message.content) {
        if (
          content.type !== "tool_use" ||
          (requested && !requested.has(content.id))
        ) {
          continue;
        }
        const existing = details.get(content.id);
        details.set(content.id, {
          toolUseId: content.id,
          toolName: content.name,
          input: boundedToolDetailInput(content.input),
          ...(existing?.result ? { result: existing.result } : {}),
        });
      }
      continue;
    }
    if (
      message.type !== "tool_result" ||
      (requested && !requested.has(message.toolUseId))
    ) {
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
        content: boundedUtf8Text(
          message.content,
          MAX_TOOL_DETAIL_COMPONENT_BYTES,
        ),
        ...(message.toolName ? { toolName: message.toolName } : {}),
        ...(message.images?.length
          ? {
              images: message.images.slice(0, MAX_TOOL_DETAIL_ATTACHMENTS),
            }
          : {}),
        ...(message.artifacts?.length
          ? {
              artifacts: message.artifacts.slice(
                0,
                MAX_TOOL_DETAIL_ATTACHMENTS,
              ),
            }
          : {}),
      },
    });
  }
  const order = requestedIds ?? [...details.keys()];
  return order
    .map((toolUseId) => details.get(toolUseId))
    .filter(
      (detail): detail is HistoryToolDetailPayload => detail !== undefined,
    );
}

function boundedToolDetailInput(
  input: Record<string, unknown>,
): Record<string, unknown> {
  try {
    if (
      Buffer.byteLength(JSON.stringify(input), "utf8") <=
      MAX_TOOL_DETAIL_COMPONENT_BYTES
    ) {
      return input;
    }
  } catch {
    // Fall through to the bounded marker.
  }
  return {
    ccpocketTruncated: true,
    preview: "[tool input omitted: exceeds detail page budget]",
  };
}

function boundedUtf8Text(value: string, maxBytes: number): string {
  if (Buffer.byteLength(value, "utf8") <= maxBytes) return value;
  const suffix = "\n… [truncated]";
  const suffixBytes = Buffer.byteLength(suffix, "utf8");
  const contentLimit = Math.max(0, maxBytes - suffixBytes);
  let bytes = 0;
  let result = "";
  for (const codePoint of value) {
    const width = Buffer.byteLength(codePoint, "utf8");
    if (bytes + width > contentLimit) break;
    result += codePoint;
    bytes += width;
  }
  return `${result}${suffix}`;
}

function historyToolDetailsPage(
  message: Extract<
    ConversationSyncClientMessage,
    { type: "conversation_items_page" }
  >,
  details: readonly HistoryToolDetailPayload[],
): ConversationItemsPage {
  return {
    data: [
      {
        type: "history_tool_details",
        requestId: message.requestId,
        sessionId: message.providerSessionId,
        details: [...details],
      } satisfies ServerMessage,
    ],
    nextCursor: null,
  };
}

function unwrapCodexThreadItem(value: unknown): unknown {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return value;
  }
  const item = (value as Record<string, unknown>).item;
  return item && typeof item === "object" && !Array.isArray(item)
    ? item
    : value;
}

async function findCodexTurnMessages(
  process: CodexProcess,
  threadId: string,
  turnId: string,
  signal: AbortSignal,
): Promise<ServerMessage[]> {
  let cursor: string | null = null;
  for (
    let pageIndex = 0;
    pageIndex < MAX_CODEX_TURN_SCAN_PAGES;
    pageIndex += 1
  ) {
    signal.throwIfAborted();
    const page = await process.listThreadTurns(
      {
        threadId,
        cursor,
        limit: CODEX_TURN_SCAN_PAGE_SIZE,
        sortDirection: "desc",
        itemsView: "full",
      },
      { signal },
    );
    const found = page.data.find((rawTurn) => {
      if (!rawTurn || typeof rawTurn !== "object" || Array.isArray(rawTurn)) {
        return false;
      }
      return (rawTurn as Record<string, unknown>).id === turnId;
    });
    if (found && typeof found === "object" && !Array.isArray(found)) {
      return annotateTurnMessages(
        codexTurnMessages(found as Record<string, unknown>, threadId),
        turnId,
      );
    }
    if (!page.nextCursor) break;
    cursor = page.nextCursor;
  }
  throw new Error("Requested Codex turn is outside the bounded read window");
}

function turnDetailKey(target: ConversationSyncTarget, turnId: string): string {
  return `${targetKey(target)}\0${turnId}`;
}

async function withCodexProcess<T>(
  runtime: LocalFeatureRuntime,
  projectPath: string | undefined,
  operation: (process: CodexProcess) => Promise<T>,
): Promise<T> {
  const active = runtime.getActiveCodexProcess();
  const process =
    active ?? (await runtime.createStandaloneCodexProcess(15_000, projectPath));
  try {
    return await operation(process);
  } finally {
    if (!active) process.stop();
  }
}

function sessionSeed(session: SessionIndexEntry): ConversationSyncCatalogSeed {
  const target = {
    provider: session.provider,
    providerSessionId: session.sessionId,
  } as const;
  const modifiedAt = normalizedIso(session.modified);
  return {
    entry: {
      ...target,
      revision: providerRevision(target, session.modified),
      projectPath: session.projectPath,
      ...(session.name ? { name: session.name } : {}),
      ...(session.summary ? { summary: session.summary } : {}),
      ...(session.firstPrompt ? { firstPrompt: session.firstPrompt } : {}),
      createdAt: normalizedIso(session.created),
      modifiedAt,
      recencyAt: modifiedAt,
      availability: "durable",
      ...(session.forkedFromThreadId
        ? { forkedFromThreadId: session.forkedFromThreadId }
        : {}),
    },
    status: unknownStatus(target, modifiedAt, "legacyRollout"),
  };
}

function codexThreadSeed(
  thread: CodexThreadSummary,
): ConversationSyncCatalogSeed {
  const target = {
    provider: "codex" as const,
    providerSessionId: thread.id,
  };
  const createdAt = secondsIso(thread.createdAt);
  const modifiedAt = secondsIso(thread.updatedAt);
  const recencyAt = secondsIso(thread.recencyAt ?? thread.updatedAt);
  return {
    entry: {
      ...target,
      revision: providerRevision(
        target,
        String(thread.recencyAt ?? thread.updatedAt),
      ),
      projectPath: thread.cwd,
      ...(thread.name ? { name: thread.name } : {}),
      ...(thread.preview ? { firstPrompt: thread.preview } : {}),
      createdAt,
      modifiedAt,
      recencyAt,
      availability: thread.ephemeral ? "ephemeral" : "durable",
      ...(thread.forkedFromThreadId
        ? { forkedFromThreadId: thread.forkedFromThreadId }
        : {}),
      ...(thread.parentThreadId
        ? { parentThreadId: thread.parentThreadId }
        : {}),
    },
    status: statusFromCodexThread(thread, modifiedAt),
  };
}

function statusFromCodexThread(
  thread: CodexThreadSummary,
  observedAt: string,
): ConversationSyncStatus {
  const target = {
    provider: "codex" as const,
    providerSessionId: thread.id,
  };
  switch (thread.status.type) {
    case "active": {
      const approval = thread.status.activeFlags.includes("waitingOnApproval");
      const question = thread.status.activeFlags.includes("waitingOnUserInput");
      return {
        ...target,
        activity: "working",
        attention: question ? "question" : approval ? "approval" : "none",
        result: "none",
        runtimeAttachment: "loaded",
        source: "appServer",
        confidence: "authoritative",
        observedAt,
      };
    }
    case "idle":
      return {
        ...target,
        activity: "idle",
        attention: "none",
        result: "none",
        runtimeAttachment: "loaded",
        source: "appServer",
        confidence: "authoritative",
        observedAt,
      };
    case "systemError":
      return {
        ...target,
        activity: "systemError",
        attention: "none",
        result: "none",
        runtimeAttachment: "loaded",
        source: "appServer",
        confidence: "authoritative",
        observedAt,
      };
    case "notLoaded":
      return {
        ...target,
        activity: "unknown",
        attention: "none",
        result: "none",
        runtimeAttachment: "notLoaded",
        source: "appServer",
        confidence: "unknown",
        observedAt,
      };
    case "unknown":
      return unknownStatus(target, observedAt, "appServer");
  }
}

function statusFromRuntime(
  state: LocalFeatureRuntimeConversationState,
  previous: ConversationSyncStatus,
): ConversationSyncStatus {
  const target = targetFromRuntime(state)!;
  const activity =
    state.processStatus === "running" ||
    state.processStatus === "waiting_approval"
      ? "working"
      : state.processStatus === "compacting"
        ? "compacting"
        : state.processStatus === "idle"
          ? "idle"
          : "unknown";
  return {
    ...target,
    activity,
    attention: state.pendingAttention?.kind ?? "none",
    result:
      activity === "working" || activity === "compacting"
        ? "none"
        : previous.result,
    runtimeAttachment: "loaded",
    source: "bridgeRuntime",
    confidence: "authoritative",
    observedAt: validIso(state.observedAt)
      ? state.observedAt
      : previous.observedAt,
    ...(state.pendingAttention
      ? { attentionRequestId: state.pendingAttention.requestId }
      : {}),
  };
}

function targetFromRuntime(
  state: LocalFeatureRuntimeConversationState,
): ConversationSyncTarget | null {
  if (
    (state.provider !== "claude" && state.provider !== "codex") ||
    !state.providerSessionId
  ) {
    return null;
  }
  return {
    provider: state.provider,
    providerSessionId: state.providerSessionId,
  };
}

function unknownStatus(
  target: ConversationSyncTarget,
  observedAt: string,
  source: ConversationSyncStatus["source"],
): ConversationSyncStatus {
  return {
    ...target,
    activity: "unknown",
    attention: "none",
    result: "none",
    runtimeAttachment: "notLoaded",
    source,
    confidence: "unknown",
    observedAt,
  };
}

function preserveObservedAt(
  previous: ConversationSyncStatus | undefined,
  next: ConversationSyncStatus,
): ConversationSyncStatus {
  if (!previous) return next;
  const semanticPrevious = { ...previous, observedAt: "" };
  const semanticNext = { ...next, observedAt: "" };
  return stableJson(semanticPrevious) === stableJson(semanticNext)
    ? { ...next, observedAt: previous.observedAt }
    : next;
}

function catalogEntries(
  catalog: ReadonlyMap<ConversationKey, CatalogRecord>,
): Map<ConversationKey, ConversationSyncCatalogEntry> {
  return new Map([...catalog].map(([key, record]) => [key, record.entry]));
}

function statusEntries(
  catalog: ReadonlyMap<ConversationKey, CatalogRecord>,
): Map<ConversationKey, ConversationSyncStatus> {
  return new Map([...catalog].map(([key, record]) => [key, record.status]));
}

function rememberState<T>(
  history: Map<string, Map<ConversationKey, T>>,
  token: string,
  value: Map<ConversationKey, T>,
): void {
  history.delete(token);
  history.set(token, new Map(value));
  while (history.size > MAX_STATE_HISTORY) {
    const oldest = history.keys().next().value;
    if (oldest === undefined) break;
    history.delete(oldest);
  }
}

function hashState(value: unknown): string {
  return createHash("sha256").update(stableJson(value)).digest("hex");
}

function providerRevision(
  target: ConversationSyncTarget,
  sourceRevision: string,
): string {
  return createHash("sha256")
    .update(
      `${target.provider}\0${target.providerSessionId}\0${sourceRevision}`,
    )
    .digest("hex");
}

function isStreamingConversationDelta(message: ServerMessage): boolean {
  return message.type === "stream_delta" || message.type === "thinking_delta";
}

function isConversationTimelineMessage(message: ServerMessage): boolean {
  return (
    message.type === "assistant" ||
    message.type === "tool_result" ||
    message.type === "result" ||
    message.type === "guardian_approval" ||
    message.type === "error" ||
    message.type === "history_delta" ||
    message.type === "history_snapshot" ||
    message.type === "tool_use_summary" ||
    message.type === "user_input"
  );
}

function targetKey(target: ConversationSyncTarget): ConversationKey {
  return `${target.provider}\0${target.providerSessionId}`;
}

function parseTargetKeyRequired(key: ConversationKey): ConversationSyncTarget {
  const separator = key.indexOf("\0");
  const provider = key.slice(0, separator);
  if (
    separator <= 0 ||
    (provider !== "claude" && provider !== "codex") ||
    separator >= key.length - 1
  ) {
    throw new Error("Invalid conversation identity key");
  }
  return {
    provider,
    providerSessionId: key.slice(separator + 1),
  };
}

function compareStateEntries(
  left: [string, unknown],
  right: [string, unknown],
): number {
  return left[0].localeCompare(right[0]);
}

function stableJson(value: unknown): string {
  return JSON.stringify(value);
}

function chunkByJsonBytes<T>(values: readonly T[], maxBytes: number): T[][] {
  if (values.length === 0) return [];
  const pages: T[][] = [];
  let page: T[] = [];
  let bytes = 2;
  for (const value of values) {
    const itemBytes = Buffer.byteLength(JSON.stringify(value), "utf8");
    if (itemBytes + 2 > maxBytes) {
      throw new Error("conversation_sync_v2 item exceeds frame content budget");
    }
    const separator = page.length === 0 ? 0 : 1;
    if (page.length > 0 && bytes + separator + itemBytes > maxBytes) {
      pages.push(page);
      page = [];
      bytes = 2;
    }
    page.push(value);
    bytes += (page.length === 1 ? 0 : 1) + itemBytes;
  }
  if (page.length > 0) pages.push(page);
  return pages;
}

function groupLegacyTurns(messages: readonly ServerMessage[]): Array<{
  id: string;
  items: ServerMessage[];
}> {
  const turns: Array<{ id: string; items: ServerMessage[] }> = [];
  for (const message of messages) {
    if (message.type === "user_input" || turns.length === 0) {
      const id =
        message.type === "user_input"
          ? `legacy-turn:${message.userMessageUuid ?? turns.length}`
          : `legacy-turn:prefix`;
      turns.push({ id, items: [] });
    }
    turns.at(-1)!.items.push(message);
  }
  return turns;
}

function paginateArray<T>(
  values: readonly T[],
  cursor: string | undefined,
  limit: number,
  direction: "asc" | "desc",
): { data: T[]; nextCursor: string | null } {
  const ordered = direction === "desc" ? [...values].reverse() : [...values];
  const offset =
    cursor && /^\d+$/.test(cursor) ? Number.parseInt(cursor, 10) : 0;
  const boundedOffset = Number.isSafeInteger(offset)
    ? Math.min(Math.max(offset, 0), ordered.length)
    : 0;
  const data = ordered.slice(boundedOffset, boundedOffset + limit);
  const next = boundedOffset + data.length;
  return {
    data,
    nextCursor: next < ordered.length ? String(next) : null,
  };
}

function normalizedIso(value: string): string {
  return validIso(value)
    ? new Date(value).toISOString()
    : new Date(0).toISOString();
}

function secondsIso(value: number): string {
  return Number.isFinite(value) && value >= 0
    ? new Date(value * 1000).toISOString()
    : new Date(0).toISOString();
}

function validIso(value: string): boolean {
  return Number.isFinite(Date.parse(value));
}

function positiveInterval(value: number | undefined, fallback: number): number {
  return Number.isFinite(value) && (value ?? 0) > 0
    ? Math.floor(value!)
    : fallback;
}

function isUnsupportedAppServerRead(error: unknown): boolean {
  return (
    (error instanceof CodexRpcError && error.code === -32601) ||
    /method not found|unknown method|not supported/i.test(errorMessage(error))
  );
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
