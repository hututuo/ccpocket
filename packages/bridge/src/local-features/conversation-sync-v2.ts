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
  resolveCodexSessionJsonlPath,
  type SessionIndexEntry,
} from "../sessions-index.js";
import type { SessionCatalogChange } from "../session-catalog-monitor.js";
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
  APP_SERVER_STATUS_CAPABILITY,
  CONVERSATION_SYNC_V2_CAPABILITY,
  type ConversationSyncCatalogEntry,
  type ConversationSyncClientMessage,
  type ConversationSyncReadWatermark,
  type ConversationSyncServerMessage,
  type ConversationSyncStatus,
  type ConversationSyncTarget,
} from "./slots/conversation-sync-v2-protocol.js";
import {
  CodexRolloutMonitor,
  inspectCodexRolloutSnapshot,
  type CodexDesktopContinuityMonitorEvent,
} from "./slots/codex-desktop-continuity.js";
import type {
  LocalFeatureClientDeliveryMode,
  LocalFeatureHandleContext,
  LocalFeatureHandler,
  LocalFeatureRuntime,
  LocalFeatureRuntimeConversationState,
  LocalFeatureSession,
} from "./runtime.js";

const MAX_CATALOG_ENTRIES = 10_000;
const MAX_CATALOG_NAME_LENGTH = 512;
const MAX_CATALOG_TEXT_LENGTH = 4_096;
const MAX_CATALOG_PATH_LENGTH = 4_096;
const MAX_CATALOG_LINEAGE_ID_LENGTH = 256;
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
// The one-shot discovery already finds every currently running rollout.
// Idle recent threads are attached lazily on an exact catalog change or focus,
// avoiding ten redundant 8 MiB seed parses on every cold phone connection.
const INITIAL_EXTERNAL_CODEX_MONITORS = 0;
const MAX_EXTERNAL_CODEX_MONITORS = 32;
const EXTERNAL_CODEX_DISCOVERY_CONCURRENCY = 8;
const EXTERNAL_CODEX_DISCOVERY_SEED_BYTES = 64 * 1024;
const EXTERNAL_CODEX_DISCOVERY_TTL_MS = 2 * 60_000;
const EXTERNAL_CODEX_INFERRED_RUNNING_FRESHNESS_MS = 2 * 60 * 60_000;
const MAX_EXTERNAL_LIVE_MESSAGES = 256;
const MAX_EXTERNAL_LIVE_BYTES_PER_THREAD = 512 * 1024;
// Bump whenever the meaning of a status snapshot changes without changing the
// wire shape. This invalidates old persisted state tokens so Mobile clears
// stale rows before applying the replacement snapshot.
const STATUS_STATE_SCHEMA_VERSION = 2;
// Build 208 could persist a content revision without observing Desktop-owned
// rollout changes. Advance the semantic generation so upgraded clients refresh
// the bounded hot window once instead of trusting those stale revisions.
const CONTENT_STATE_SCHEMA_VERSION = 2;

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
  observeCodexThread?: ObserveCodexThread;
  inspectCodexThread?: InspectCodexThread;
  initialExternalCodexMonitors?: number;
  maxExternalCodexMonitors?: number;
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

interface ExternalCodexSnapshot {
  state: "idle" | "running" | "unknown";
  turnId?: string;
  observedAt?: string;
  runningEvidence?: "lifecycle" | "activity";
}

interface ExternalCodexObservation {
  readonly snapshot: ExternalCodexSnapshot;
  refreshNow(): Promise<void>;
  close(): void;
}

type ObserveCodexThread = (
  threadId: string,
  onEvent: (event: CodexDesktopContinuityMonitorEvent) => void,
) => Promise<ExternalCodexObservation>;

type InspectCodexThread = (
  threadId: string,
) => Promise<ExternalCodexSnapshot | null>;

interface ExternalCodexMonitorRecord {
  observation: ExternalCodexObservation;
  generation: number;
}

interface ExternalCodexLiveMessage {
  message: ServerMessage;
  observedAt: string;
  bytes: number;
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
  private readonly observeCodexThread: ObserveCodexThread;
  private readonly inspectCodexThread: InspectCodexThread;
  private readonly initialExternalCodexMonitors: number;
  private readonly maxExternalCodexMonitors: number;

  private readonly subscriptions = new Map<object, SyncSubscription>();
  private catalog = new Map<ConversationKey, CatalogRecord>();
  private catalogState = hashState([]);
  private statusState = hashState([STATUS_STATE_SCHEMA_VERSION]);
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
  private readonly externalCodexMonitors = new Map<
    string,
    ExternalCodexMonitorRecord
  >();
  private readonly externalCodexMonitorFlights = new Map<
    string,
    Promise<ExternalCodexObservation | null>
  >();
  private readonly externalCodexMonitorGenerations = new Map<string, number>();
  private readonly externalCodexStatuses = new Map<
    ConversationKey,
    ConversationSyncStatus
  >();
  private readonly externalCodexLiveMessages = new Map<
    ConversationKey,
    Map<string, ExternalCodexLiveMessage>
  >();
  private readonly externalCodexLiveBytes = new Map<ConversationKey, number>();
  private readonly externalCodexDiscoveredRunning = new Map<
    string,
    ExternalCodexSnapshot
  >();
  private readonly pendingExternalCodexThreads = new Set<string>();
  private externalCodexMonitorGeneration = 0;
  private externalCodexDiscoveryGeneration = 0;
  private externalCodexDiscoveryCompletedAt = 0;
  private sharedCodexReadProcess?: CodexProcess;
  private sharedCodexReadProcessFlight?: Promise<CodexProcess>;
  private sharedCodexReadProcessUsers = 0;
  private sharedCodexReadProcessCloseRequested = false;
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
      ((target) => this.readRecentConversationHistory(target));
    this.statusWatchdogMs = positiveInterval(
      options.statusWatchdogMs,
      STATUS_WATCHDOG_MS,
    );
    this.coldReconcileMs = positiveInterval(
      options.coldReconcileMs,
      COLD_RECONCILE_MS,
    );
    this.observeCodexThread =
      options.observeCodexThread ??
      ((threadId, onEvent) =>
        observeDurableCodexThread(this.runtime, threadId, onEvent));
    this.inspectCodexThread =
      options.inspectCodexThread ??
      (options.observeCodexThread
        ? async () => null
        : inspectDurableCodexThread);
    this.initialExternalCodexMonitors = nonNegativeInteger(
      options.initialExternalCodexMonitors,
      INITIAL_EXTERNAL_CODEX_MONITORS,
    );
    this.maxExternalCodexMonitors = Math.max(
      this.initialExternalCodexMonitors,
      positiveInterval(
        options.maxExternalCodexMonitors,
        MAX_EXTERNAL_CODEX_MONITORS,
      ),
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
      if (!this.hasInteractiveClients()) {
        this.clearExternalCodexMonitoring();
        this.requestSharedCodexReadProcessClose();
      }
    }
  }

  sessionCatalogChanged(change?: SessionCatalogChange): void {
    this.catalogDirty = true;
    const exactCodexThreadId =
      change?.provider === "codex" ? change.providerSessionId : undefined;
    if (exactCodexThreadId) {
      this.pendingExternalCodexThreads.add(exactCodexThreadId);
    } else if (!this.hasInteractiveClients()) {
      this.externalCodexDiscoveryCompletedAt = 0;
    }
    if (!this.hasInteractiveClients()) return;
    if (exactCodexThreadId) {
      const target: ConversationSyncTarget = {
        provider: "codex",
        providerSessionId: exactCodexThreadId,
      };
      this.rememberLiveContent(target, new Date().toISOString());
    }
    void (
      exactCodexThreadId
        ? this.ensureExternalCodexMonitor(exactCodexThreadId, true)
            .catch((error) => {
              this.reportExternalObservationFailure(error);
              return null;
            })
            .then(() => this.refreshCatalog())
        : this.refreshCatalog()
    )
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
    if (!this.hasInteractiveClients()) {
      this.cancelTimers();
      this.clearExternalCodexMonitoring();
      this.requestSharedCodexReadProcessClose();
    }
  }

  close(): void {
    this.closed = true;
    this.subscriptions.clear();
    this.snapshots.clear();
    this.snapshotFlights.clear();
    this.turnDetailCache.clear();
    this.liveContentRevisions.clear();
    this.pendingLiveContent.clear();
    this.clearExternalCodexMonitoring();
    this.externalCodexDiscoveredRunning.clear();
    this.pendingExternalCodexThreads.clear();
    this.externalCodexDiscoveryCompletedAt = 0;
    this.requestSharedCodexReadProcessClose();
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
    if (!message.focused) return;
    if (message.focused.provider === "codex") {
      void this.ensureExternalCodexMonitor(
        message.focused.providerSessionId,
        true,
      )
        .catch((error) => {
          this.reportExternalObservationFailure(error);
        })
        .finally(() => this.scheduleSync(client, subscription));
      return;
    }
    this.scheduleSync(client, subscription);
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
    if (!this.hasInteractiveClients()) {
      this.cancelTimers();
      this.clearExternalCodexMonitoring();
      this.requestSharedCodexReadProcessClose();
    }
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
      // A client whose global catalog cursor can no longer be continued may
      // also hold per-thread revisions from a cache generation the Bridge can
      // no longer relate to the current catalog. Preserve user read
      // watermarks, but force one bounded hot-window bootstrap.
      subscription.threadStates.clear();
      subscription.pendingThreadStates.clear();
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
      subscription.threadStates.clear();
      subscription.pendingThreadStates.clear();
    }
    const current = statusEntries(this.catalog);
    const supportsAppServerStatusSemantics = this.runtime.supports(
      client,
      APP_SERVER_STATUS_CAPABILITY,
    );
    const changes = [...current]
      .filter(([key, value]) => {
        const prior = previous?.get(key);
        return !prior || stableJson(prior) !== stableJson(value);
      })
      .map(([, value]) =>
        statusForClient(value, supportsAppServerStatusSemantics),
      );
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
        const messages = mergeExternalCodexMessages(
          window.messages,
          this.externalCodexLiveMessages.get(key)?.values() ?? [],
        );
        for (const turn of window.turnDetails ?? []) {
          this.rememberTurnDetails(target, turn);
        }
        const built = buildConversationContentSnapshot(target, messages, {
          maxMessageTextBytes: MAX_MESSAGE_TEXT_BYTES,
          maxSnapshotBytes: MAX_TIMELINE_BYTES,
          preserveLatestRootTurnTools,
        });
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
        const previousCatalog = this.catalog;
        const previousStatuses = statusEntries(this.catalog);
        const next = new Map<ConversationKey, CatalogRecord>();
        const changedCodexThreads: string[] = [];
        for (const seed of seeds.slice(0, MAX_CATALOG_ENTRIES)) {
          if (seed.entry.availability === "ephemeral") continue;
          const entry = normalizeCatalogEntry(seed.entry);
          const key = targetKey(entry);
          const previousRecord = previousCatalog.get(key);
          if (
            entry.provider === "codex" &&
            previousRecord &&
            previousRecord.entry.revision !== entry.revision
          ) {
            changedCodexThreads.push(entry.providerSessionId);
          }
          const live = this.liveContentRevisions.get(key);
          if (
            live &&
            Date.parse(entry.recencyAt) >= Date.parse(live.observedAt)
          ) {
            this.liveContentRevisions.delete(key);
            this.deleteExternalCodexLiveMessages(key);
          }
          const previous = previousStatuses.get(key);
          next.set(key, {
            entry,
            status: preserveObservedAt(previous, seed.status),
          });
        }
        this.catalog = next;
        const shouldWarmExternalCodex =
          previousCatalog.size === 0 ||
          (this.externalCodexMonitors.size === 0 &&
            this.externalCodexMonitorFlights.size === 0);
        const codexThreadIds = [...next.values()]
          .filter((record) => record.entry.provider === "codex")
          .map((record) => record.entry.providerSessionId);
        for (const [threadId, snapshot] of this
          .externalCodexDiscoveredRunning) {
          if (!codexThreadIds.includes(threadId)) continue;
          this.applyExternalCodexSnapshot(
            threadId,
            snapshot,
            externalSnapshotObservedAt(snapshot),
            false,
          );
        }
        const discoveryExpired =
          this.externalCodexDiscoveryCompletedAt === 0 ||
          Date.now() - this.externalCodexDiscoveryCompletedAt >=
            EXTERNAL_CODEX_DISCOVERY_TTL_MS;
        const discovery =
          discoveryExpired && this.hasInteractiveClients()
            ? await this.discoverExternalCodexActivity(
                codexThreadIds,
                this.externalCodexDiscoveryGeneration,
              )
            : {
                completed: true,
                running: [...this.externalCodexDiscoveredRunning.keys()],
              };
        const pendingCodexThreads = [...this.pendingExternalCodexThreads];
        const initialCodexThreads = shouldWarmExternalCodex
          ? [...next.values()]
              .filter((record) => record.entry.provider === "codex")
              .slice(0, this.initialExternalCodexMonitors)
              .map((record) => record.entry.providerSessionId)
          : [];
        await this.ensureExternalCodexMonitors([
          ...pendingCodexThreads,
          ...discovery.running,
          ...initialCodexThreads,
          ...changedCodexThreads.slice(0, this.maxExternalCodexMonitors),
        ]);
        if (discovery.completed) {
          for (const threadId of pendingCodexThreads) {
            this.pendingExternalCodexThreads.delete(threadId);
          }
        }
        this.applyRuntimeOverlay();
        for (const key of this.liveContentRevisions.keys()) {
          if (!this.catalog.has(key)) {
            this.liveContentRevisions.delete(key);
            this.deleteExternalCodexLiveMessages(key);
          }
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
    const flight = (async () => {
      const monitoredThreads = [...this.externalCodexMonitors.keys()];
      for (
        let offset = 0;
        offset < monitoredThreads.length;
        offset += PROVIDER_HISTORY_CONCURRENCY
      ) {
        await Promise.allSettled(
          monitoredThreads
            .slice(offset, offset + PROVIDER_HISTORY_CONCURRENCY)
            .map((threadId) =>
              this.ensureExternalCodexMonitor(threadId, true, false),
            ),
        );
      }
      if (this.closed) return;
      this.applyRuntimeOverlay();
      this.recomputeStates();
      for (const [client, subscription] of this.subscriptions) {
        if (subscription.interactive) this.scheduleSync(client, subscription);
      }
    })().finally(() => {
      if (this.statusFlight === flight) this.statusFlight = undefined;
    });
    this.statusFlight = flight;
    return flight;
  }

  private async readRecentConversationHistory(
    target: ConversationSyncTarget,
  ): Promise<ConversationHistoryWindow> {
    if (target.provider !== "codex") {
      return readLegacyHistoryWindow(target);
    }
    try {
      return await this.withSharedCodexReadProcess((process) =>
        readRecentCodexConversationHistory(process, target),
      );
    } catch (error) {
      if (!isUnsupportedAppServerRead(error)) throw error;
      return readLegacyHistoryWindow(target);
    }
  }

  private async withSharedCodexReadProcess<T>(
    operation: (process: CodexProcess) => Promise<T>,
  ): Promise<T> {
    const active = this.runtime.getActiveCodexProcess();
    if (active && active.isRunning !== false) return operation(active);

    this.sharedCodexReadProcessCloseRequested = false;
    const process = await this.ensureSharedCodexReadProcess();
    if (
      this.closed ||
      (this.sharedCodexReadProcessCloseRequested &&
        !this.hasInteractiveClients())
    ) {
      if (this.sharedCodexReadProcess === process) {
        this.sharedCodexReadProcess.stop();
        this.sharedCodexReadProcess = undefined;
      }
      throw new Error("Conversation sync reader is no longer active");
    }
    this.sharedCodexReadProcessUsers += 1;
    try {
      return await operation(process);
    } catch (error) {
      if (
        this.sharedCodexReadProcess === process &&
        process.isRunning === false
      ) {
        this.sharedCodexReadProcess = undefined;
        process.stop();
      }
      throw error;
    } finally {
      this.sharedCodexReadProcessUsers = Math.max(
        0,
        this.sharedCodexReadProcessUsers - 1,
      );
      if (
        this.sharedCodexReadProcessCloseRequested &&
        this.sharedCodexReadProcessUsers === 0
      ) {
        this.stopSharedCodexReadProcess();
      }
    }
  }

  private ensureSharedCodexReadProcess(): Promise<CodexProcess> {
    if (this.sharedCodexReadProcess?.isRunning === false) {
      const stopped = this.sharedCodexReadProcess;
      this.sharedCodexReadProcess = undefined;
      stopped.stop();
    }
    if (this.sharedCodexReadProcess) {
      return Promise.resolve(this.sharedCodexReadProcess);
    }
    if (this.sharedCodexReadProcessFlight) {
      return this.sharedCodexReadProcessFlight;
    }
    const flight = this.runtime
      .createStandaloneCodexProcess(15_000)
      .then((process) => {
        if (this.closed) {
          process.stop();
          throw new Error("Conversation sync handler is closed");
        }
        this.sharedCodexReadProcess = process;
        return process;
      })
      .finally(() => {
        if (this.sharedCodexReadProcessFlight === flight) {
          this.sharedCodexReadProcessFlight = undefined;
        }
      });
    this.sharedCodexReadProcessFlight = flight;
    return flight;
  }

  private requestSharedCodexReadProcessClose(): void {
    this.sharedCodexReadProcessCloseRequested = true;
    if (this.sharedCodexReadProcessUsers === 0) {
      this.stopSharedCodexReadProcess();
    }
  }

  private stopSharedCodexReadProcess(): void {
    const process = this.sharedCodexReadProcess;
    this.sharedCodexReadProcess = undefined;
    process?.stop();
  }

  private async discoverExternalCodexActivity(
    threadIds: readonly string[],
    generation: number,
  ): Promise<{ completed: boolean; running: string[] }> {
    let failures = 0;
    for (
      let offset = 0;
      offset < threadIds.length;
      offset += EXTERNAL_CODEX_DISCOVERY_CONCURRENCY
    ) {
      if (this.closed || !this.hasInteractiveClients()) break;
      const batch = threadIds.slice(
        offset,
        offset + EXTERNAL_CODEX_DISCOVERY_CONCURRENCY,
      );
      const inspected = await Promise.allSettled(
        batch.map((threadId) => this.inspectCodexThread(threadId)),
      );
      if (
        this.closed ||
        !this.hasInteractiveClients() ||
        this.externalCodexDiscoveryGeneration !== generation
      ) {
        return { completed: false, running: [] };
      }
      inspected.forEach((result, index) => {
        const threadId = batch[index];
        if (!threadId) return;
        if (result.status === "rejected") {
          failures += 1;
          if (!this.externalCodexMonitors.has(threadId)) {
            this.clearUnverifiedExternalCodexSnapshot(threadId);
          }
          return;
        }
        const snapshot = result.value;
        if (!snapshot) {
          if (!this.externalCodexMonitors.has(threadId)) {
            this.clearUnverifiedExternalCodexSnapshot(threadId);
          }
          return;
        }
        this.applyExternalCodexSnapshot(
          threadId,
          snapshot,
          externalSnapshotObservedAt(snapshot),
          false,
        );
      });
    }
    if (failures > 0) {
      console.warn(
        `[conversation-sync-v2] Optional rollout discovery skipped ${failures} thread(s)`,
      );
    }
    if (
      this.closed ||
      !this.hasInteractiveClients() ||
      this.externalCodexDiscoveryGeneration !== generation
    ) {
      return { completed: false, running: [] };
    }
    this.externalCodexDiscoveryCompletedAt = Date.now();
    const inspectedThreads = new Set(threadIds);
    return {
      completed: true,
      running: [...this.externalCodexDiscoveredRunning.keys()].filter(
        (threadId) => inspectedThreads.has(threadId),
      ),
    };
  }

  private async ensureExternalCodexMonitors(
    threadIds: readonly string[],
  ): Promise<void> {
    const unique = [...new Set(threadIds.filter(Boolean))];
    for (
      let offset = 0;
      offset < unique.length;
      offset += PROVIDER_HISTORY_CONCURRENCY
    ) {
      await Promise.allSettled(
        unique
          .slice(offset, offset + PROVIDER_HISTORY_CONCURRENCY)
          .map((threadId) =>
            this.ensureExternalCodexMonitor(threadId, false, false),
          ),
      );
    }
  }

  private ensureExternalCodexMonitor(
    threadId: string,
    refresh: boolean,
    publish = true,
  ): Promise<ExternalCodexObservation | null> {
    if (
      this.closed ||
      !this.hasInteractiveClients() ||
      this.hasActiveLocalCodexRuntime(threadId)
    ) {
      this.dropExternalCodexMonitor(threadId);
      return Promise.resolve(null);
    }
    const existing = this.externalCodexMonitors.get(threadId);
    if (existing) {
      this.externalCodexMonitors.delete(threadId);
      this.externalCodexMonitors.set(threadId, existing);
      if (!refresh) return Promise.resolve(existing.observation);
      return existing.observation
        .refreshNow()
        .then(() => {
          if (
            this.externalCodexMonitors.get(threadId) !== existing ||
            this.externalCodexMonitorGenerations.get(threadId) !==
              existing.generation
          ) {
            return (
              this.externalCodexMonitors.get(threadId)?.observation ?? null
            );
          }
          this.applyExternalCodexSnapshot(
            threadId,
            existing.observation.snapshot,
            externalSnapshotObservedAt(existing.observation.snapshot),
            publish,
          );
          return existing.observation;
        })
        .catch((error) => {
          if (this.externalCodexMonitors.get(threadId) === existing) {
            this.dropExternalCodexMonitor(threadId);
          }
          throw error;
        });
    }
    const inFlight = this.externalCodexMonitorFlights.get(threadId);
    if (inFlight) {
      return refresh
        ? inFlight.then(async (observation) => {
            if (!observation) return null;
            const record = this.externalCodexMonitors.get(threadId);
            if (!record || record.observation !== observation) {
              return record?.observation ?? null;
            }
            await observation.refreshNow();
            if (
              this.externalCodexMonitors.get(threadId) !== record ||
              this.externalCodexMonitorGenerations.get(threadId) !==
                record.generation
            ) {
              return (
                this.externalCodexMonitors.get(threadId)?.observation ?? null
              );
            }
            this.applyExternalCodexSnapshot(
              threadId,
              observation.snapshot,
              externalSnapshotObservedAt(observation.snapshot),
              publish,
            );
            return observation;
          })
        : inFlight;
    }

    if (!this.ensureExternalCodexMonitorCapacity()) {
      return Promise.resolve(null);
    }
    const generation = ++this.externalCodexMonitorGeneration;
    this.externalCodexMonitorGenerations.set(threadId, generation);
    const flight = (async (): Promise<ExternalCodexObservation | null> => {
      const observation = await this.observeCodexThread(threadId, (event) =>
        this.onExternalCodexEvent(threadId, generation, event),
      );
      if (
        this.closed ||
        !this.hasInteractiveClients() ||
        this.hasActiveLocalCodexRuntime(threadId) ||
        this.externalCodexMonitorGenerations.get(threadId) !== generation
      ) {
        observation.close();
        return null;
      }
      const raced = this.externalCodexMonitors.get(threadId);
      if (raced) {
        observation.close();
        return raced.observation;
      }
      this.externalCodexMonitors.set(threadId, {
        observation,
        generation,
      });
      this.applyExternalCodexSnapshot(
        threadId,
        observation.snapshot,
        externalSnapshotObservedAt(observation.snapshot),
        publish,
      );
      return observation;
    })().finally(() => {
      if (this.externalCodexMonitorFlights.get(threadId) === flight) {
        this.externalCodexMonitorFlights.delete(threadId);
      }
      if (
        !this.externalCodexMonitors.has(threadId) &&
        this.externalCodexMonitorGenerations.get(threadId) === generation
      ) {
        this.externalCodexMonitorGenerations.delete(threadId);
      }
    });
    this.externalCodexMonitorFlights.set(threadId, flight);
    return flight;
  }

  private onExternalCodexEvent(
    threadId: string,
    generation: number,
    event: CodexDesktopContinuityMonitorEvent,
  ): void {
    if (
      this.closed ||
      !this.hasInteractiveClients() ||
      this.externalCodexMonitorGenerations.get(threadId) !== generation
    ) {
      return;
    }
    const target: ConversationSyncTarget = {
      provider: "codex",
      providerSessionId: threadId,
    };
    const observedAt =
      event.timestamp && validIso(event.timestamp)
        ? event.timestamp
        : new Date().toISOString();
    const monitor = this.externalCodexMonitors.get(threadId);
    if (monitor) {
      this.externalCodexMonitors.delete(threadId);
      this.externalCodexMonitors.set(threadId, monitor);
    }

    if (event.kind === "state") {
      this.applyExternalCodexSnapshot(
        threadId,
        {
          state: event.state,
          ...(event.turnId ? { turnId: event.turnId } : {}),
        },
        observedAt,
        false,
      );
      const key = targetKey(target);
      if (event.state === "running") {
        this.resultLedger.delete(key);
      } else if (event.outcome) {
        this.resultLedger.set(key, {
          result: event.outcome === "completed" ? "completed" : "failed",
          observedAt,
        });
        this.rememberLiveContent(target, observedAt);
      }
      this.applyRuntimeOverlay();
      this.recomputeStates();
      this.scheduleInteractiveClients();
      return;
    }

    this.rememberExternalCodexMessage(target, event, observedAt);
    if (event.message.type === "result") {
      this.resultLedger.set(targetKey(target), {
        result:
          Boolean(event.message.error) ||
          /error|fail/i.test(event.message.subtype) ||
          /error|fail/i.test(event.message.stopReason ?? "")
            ? "failed"
            : "completed",
        observedAt,
      });
    } else if (
      event.message.type === "assistant" ||
      event.message.type === "tool_result" ||
      event.message.type === "user_input"
    ) {
      this.resultLedger.delete(targetKey(target));
    }
    if (isStreamingConversationDelta(event.message)) {
      this.queueLiveContent(target, observedAt);
    } else if (isConversationTimelineMessage(event.message)) {
      this.publishLiveContent(target, observedAt);
    }
  }

  private clearUnverifiedExternalCodexSnapshot(threadId: string): void {
    this.externalCodexDiscoveredRunning.delete(threadId);
    const target: ConversationSyncTarget = {
      provider: "codex",
      providerSessionId: threadId,
    };
    const previous = this.externalCodexStatuses.get(targetKey(target));
    if (!previous) return;
    this.applyExternalCodexSnapshot(
      threadId,
      { state: "unknown" },
      previous.observedAt,
      false,
    );
  }

  private applyExternalCodexSnapshot(
    threadId: string,
    snapshot: ExternalCodexSnapshot,
    observedAt: string,
    publish: boolean,
  ): void {
    const target: ConversationSyncTarget = {
      provider: "codex",
      providerSessionId: threadId,
    };
    const effectiveState =
      snapshot.state === "running" && !credibleExternalRunning(snapshot)
        ? "unknown"
        : snapshot.state;
    const status: ConversationSyncStatus =
      effectiveState === "running"
        ? {
            ...target,
            activity: "working",
            attention: "none",
            result: "none",
            runtimeAttachment: "ownedElsewhere",
            source: "legacyRollout",
            confidence: "observed",
            observedAt,
          }
        : effectiveState === "idle"
          ? {
              ...target,
              activity: "idle",
              attention: "none",
              result: "none",
              runtimeAttachment: "notLoaded",
              source: "legacyRollout",
              confidence: "observed",
              observedAt,
            }
          : unknownStatus(target, observedAt, "legacyRollout");
    const key = targetKey(target);
    const previous = this.externalCodexStatuses.get(key);
    if (previous && Date.parse(observedAt) < Date.parse(previous.observedAt)) {
      return;
    }
    if (effectiveState === "running") {
      this.externalCodexDiscoveredRunning.set(threadId, {
        ...snapshot,
        observedAt,
      });
    } else {
      this.externalCodexDiscoveredRunning.delete(threadId);
    }
    this.externalCodexStatuses.set(key, status);
    if (!publish || !this.catalog.has(key)) return;
    this.applyRuntimeOverlay();
    this.recomputeStates();
    this.scheduleInteractiveClients();
  }

  private rememberExternalCodexMessage(
    target: ConversationSyncTarget,
    event: Extract<CodexDesktopContinuityMonitorEvent, { kind: "message" }>,
    observedAt: string,
  ): void {
    const key = targetKey(target);
    const bytes = Buffer.byteLength(stableJson(event.message), "utf8");
    if (bytes > MAX_EXTERNAL_LIVE_BYTES_PER_THREAD) return;
    const messages =
      this.externalCodexLiveMessages.get(key) ??
      new Map<string, ExternalCodexLiveMessage>();
    let totalBytes = this.externalCodexLiveBytes.get(key) ?? 0;
    const previous = messages.get(event.itemKey);
    if (previous) totalBytes = Math.max(0, totalBytes - previous.bytes);
    messages.delete(event.itemKey);
    messages.set(event.itemKey, {
      message: event.message,
      observedAt,
      bytes,
    });
    totalBytes += bytes;
    while (
      messages.size > MAX_EXTERNAL_LIVE_MESSAGES ||
      totalBytes > MAX_EXTERNAL_LIVE_BYTES_PER_THREAD
    ) {
      const oldest = messages.keys().next().value;
      if (oldest === undefined) break;
      const removed = messages.get(oldest);
      messages.delete(oldest);
      if (removed) totalBytes = Math.max(0, totalBytes - removed.bytes);
    }
    if (messages.size === 0) {
      this.deleteExternalCodexLiveMessages(key);
      return;
    }
    this.externalCodexLiveMessages.set(key, messages);
    this.externalCodexLiveBytes.set(key, totalBytes);
  }

  private hasActiveLocalCodexRuntime(threadId: string): boolean {
    return (this.runtime.listRuntimeConversationStates?.() ?? []).some(
      (state) =>
        state.provider === "codex" &&
        state.providerSessionId === threadId &&
        (state.processStatus !== "idle" ||
          state.pendingAttention !== undefined),
    );
  }

  private ensureExternalCodexMonitorCapacity(): boolean {
    const occupiedCount = () =>
      new Set([
        ...this.externalCodexMonitors.keys(),
        ...this.externalCodexMonitorFlights.keys(),
      ]).size;
    while (occupiedCount() >= this.maxExternalCodexMonitors) {
      const idle = [...this.externalCodexMonitors.entries()].find(
        ([threadId]) =>
          !this.externalCodexMonitorFlights.has(threadId) &&
          this.externalCodexStatuses.get(
            targetKey({ provider: "codex", providerSessionId: threadId }),
          )?.activity !== "working",
      );
      const oldest =
        idle ??
        [...this.externalCodexMonitors.entries()].find(
          ([threadId]) => !this.externalCodexMonitorFlights.has(threadId),
        );
      if (!oldest) return false;
      this.dropExternalCodexMonitor(oldest[0], true);
    }
    return true;
  }

  private dropExternalCodexMonitor(
    threadId: string,
    preserveStatus = false,
  ): void {
    const record = this.externalCodexMonitors.get(threadId);
    if (record) record.observation.close();
    this.externalCodexMonitors.delete(threadId);
    this.externalCodexMonitorFlights.delete(threadId);
    this.externalCodexMonitorGenerations.delete(threadId);
    const key = targetKey({ provider: "codex", providerSessionId: threadId });
    if (!preserveStatus) this.externalCodexStatuses.delete(key);
    this.deleteExternalCodexLiveMessages(key);
  }

  private clearExternalCodexMonitoring(): void {
    this.externalCodexDiscoveryGeneration += 1;
    for (const record of this.externalCodexMonitors.values()) {
      record.observation.close();
    }
    this.externalCodexMonitors.clear();
    this.externalCodexMonitorFlights.clear();
    this.externalCodexMonitorGenerations.clear();
    this.externalCodexStatuses.clear();
    this.externalCodexLiveMessages.clear();
    this.externalCodexLiveBytes.clear();
  }

  private deleteExternalCodexLiveMessages(key: ConversationKey): void {
    this.externalCodexLiveMessages.delete(key);
    this.externalCodexLiveBytes.delete(key);
  }

  private applyRuntimeOverlay(): void {
    for (const [key, status] of this.externalCodexStatuses) {
      const record = this.catalog.get(key);
      if (!record) continue;
      if (!externalStatusMayOverride(record.status, status)) continue;
      record.status = preserveObservedAt(record.status, status);
    }
    const runtimeStates = this.runtime.listRuntimeConversationStates?.() ?? [];
    for (const runtimeState of runtimeStates) {
      const target = targetFromRuntime(runtimeState);
      if (!target) continue;
      const key = targetKey(target);
      const activeLocalCodexRuntime =
        target.provider === "codex" &&
        (runtimeState.processStatus !== "idle" ||
          runtimeState.pendingAttention !== undefined);
      if (activeLocalCodexRuntime) {
        this.dropExternalCodexMonitor(target.providerSessionId);
      }
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
      const runtimeStatus = statusFromRuntime(runtimeState, record.status);
      const externalStatus =
        target.provider === "codex"
          ? this.externalCodexStatuses.get(key)
          : undefined;
      if (
        !activeLocalCodexRuntime &&
        externalStatus?.activity === "working" &&
        statusObservedAfter(externalStatus, runtimeStatus)
      ) {
        record.status = externalStatus;
      } else {
        record.status = runtimeStatus;
      }
    }
    for (const [key, live] of this.liveContentRevisions) {
      const record = this.catalog.get(key);
      if (!record) continue;
      record.entry.modifiedAt = laterIso(
        record.entry.modifiedAt,
        live.observedAt,
      );
      record.entry.recencyAt = laterIso(
        record.entry.recencyAt,
        live.observedAt,
      );
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
    this.statusState = hashState([
      STATUS_STATE_SCHEMA_VERSION,
      ...[...statuses].sort(compareStateEntries),
    ]);
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

  private reportExternalObservationFailure(error: unknown): void {
    // This compatibility overlay is optional. Do not turn a missing legacy
    // rollout into a v2 protocol failure while app-server catalog/history is
    // still usable, and do not print filesystem error messages that may carry
    // private host paths.
    const kind = error instanceof Error ? error.name : typeof error;
    console.warn(
      `[conversation-sync-v2] Optional rollout observation unavailable (${kind})`,
    );
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

async function observeDurableCodexThread(
  runtime: LocalFeatureRuntime,
  threadId: string,
  onEvent: (event: CodexDesktopContinuityMonitorEvent) => void,
): Promise<ExternalCodexObservation> {
  const path = await resolveCodexSessionJsonlPath(threadId);
  if (!path) {
    throw new Error(`No durable rollout found for ${threadId}`);
  }
  const monitor = new CodexRolloutMonitor({
    threadId,
    path,
    getLocalActiveTurnId: () => runtime.getLocallyActiveCodexTurnId?.(threadId),
    consumeLocalClientMessageId: () => false,
    onEvent,
    replayActiveTurnMessages: true,
  });
  try {
    await monitor.start();
    return {
      get snapshot() {
        return {
          ...monitor.snapshot,
          ...(monitor.snapshotObservedAt
            ? { observedAt: monitor.snapshotObservedAt }
            : {}),
          ...(monitor.snapshotRunningEvidence
            ? { runningEvidence: monitor.snapshotRunningEvidence }
            : {}),
        };
      },
      refreshNow: () => monitor.refreshNow(),
      close: () => monitor.close(),
    };
  } catch (error) {
    monitor.close();
    throw error;
  }
}

async function inspectDurableCodexThread(
  threadId: string,
): Promise<ExternalCodexSnapshot | null> {
  const path = await resolveCodexSessionJsonlPath(threadId);
  if (!path) return null;
  return inspectCodexRolloutSnapshot({
    threadId,
    path,
    seedBytes: EXTERNAL_CODEX_DISCOVERY_SEED_BYTES,
  });
}

function mergeExternalCodexMessages(
  history: readonly ServerMessage[],
  observed: Iterable<ExternalCodexLiveMessage>,
): ServerMessage[] {
  const merged = [...history];
  const canonicalUsers = history
    .map((message, index) => ({ message, index }))
    .filter((entry) => entry.message.type === "user_input");
  const matchedCanonicalUsers = new Set<number>();
  const identities = new Set(
    history.map(observedMessageIdentity).filter((value) => value !== null),
  );
  for (const entry of observed) {
    if (entry.message.type === "user_input") {
      const matchingCanonical = canonicalUsers.find(
        (candidate) =>
          !matchedCanonicalUsers.has(candidate.index) &&
          equivalentObservedUserMessage(candidate.message, entry.message),
      );
      if (matchingCanonical) {
        matchedCanonicalUsers.add(matchingCanonical.index);
        continue;
      }
    }
    const identity = observedMessageIdentity(entry.message);
    if (identity && identities.has(identity)) continue;
    merged.push(entry.message);
    if (identity) identities.add(identity);
  }
  return merged;
}

function observedMessageIdentity(message: ServerMessage): string | null {
  if (message.type === "user_input") {
    const clientMessageId =
      "clientMessageId" in message &&
      typeof message.clientMessageId === "string"
        ? message.clientMessageId
        : undefined;
    return `user:${
      message.userMessageUuid ??
      clientMessageId ??
      createHash("sha256").update(stableJson(message)).digest("hex")
    }`;
  }
  if (message.type === "assistant") {
    return `assistant:${message.messageUuid ?? message.message.id}`;
  }
  if (message.type === "tool_result") {
    return `tool-result:${message.toolUseId}`;
  }
  // Deltas are ordered chunks. Equal text in two distinct chunks is valid;
  // the rollout item key already provides the only safe live dedupe identity.
  if (message.type === "thinking_delta" || message.type === "stream_delta") {
    return null;
  }
  return null;
}

function equivalentObservedUserMessage(
  canonical: ServerMessage,
  live: ServerMessage,
): boolean {
  if (canonical.type !== "user_input" || live.type !== "user_input") {
    return false;
  }
  if (
    canonical.text !== live.text ||
    (canonical.imageCount ?? 0) !== (live.imageCount ?? 0)
  ) {
    return false;
  }
  const canonicalTimestamp = canonical.sourceTimestamp ?? canonical.timestamp;
  const liveTimestamp = live.sourceTimestamp ?? live.timestamp;
  if (!canonicalTimestamp || !liveTimestamp) return false;
  const canonicalTime = Date.parse(canonicalTimestamp);
  const liveTime = Date.parse(liveTimestamp);
  return (
    Number.isFinite(canonicalTime) &&
    Number.isFinite(liveTime) &&
    Math.abs(canonicalTime - liveTime) <= 1_000
  );
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

async function readRecentCodexConversationHistory(
  process: CodexProcess,
  target: ConversationSyncTarget,
): Promise<ConversationHistoryWindow> {
  const page = await process.listThreadTurns({
    threadId: target.providerSessionId,
    limit: 5,
    sortDirection: "desc",
    // The current app-server summary view keeps only the user/final spine and
    // omits tool ids/counts. Read one bounded full page at the Bridge, then
    // compact the older two turns before crossing the wire.
    itemsView: "full",
  });
  const turns = [...page.data].reverse();
  const normalized = normalizeCodexTurns(
    turns,
    "full",
    target.providerSessionId,
  );
  const fullStart = Math.max(0, normalized.turns.length - FULL_RECENT_TURNS);
  return {
    messages: normalized.turns.flatMap((turn, index) =>
      index < fullStart
        ? compactTurnMessages(turn.messages, turn.turnId)
        : turn.messages,
    ),
    nextTurnCursor: page.nextCursor,
    turnDetails: normalized.turnDetails,
  };
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

function normalizeCatalogEntry(
  entry: ConversationSyncCatalogEntry,
): ConversationSyncCatalogEntry {
  const name = truncateCatalogText(entry.name, MAX_CATALOG_NAME_LENGTH);
  const summary = truncateCatalogText(entry.summary, MAX_CATALOG_TEXT_LENGTH);
  const firstPrompt = truncateCatalogText(
    entry.firstPrompt,
    MAX_CATALOG_TEXT_LENGTH,
  );
  const forkedFromThreadId = validCatalogLineageId(entry.forkedFromThreadId);
  const parentThreadId = validCatalogLineageId(entry.parentThreadId);
  return {
    provider: entry.provider,
    providerSessionId: entry.providerSessionId,
    revision: entry.revision,
    projectPath:
      truncateCatalogText(entry.projectPath, MAX_CATALOG_PATH_LENGTH) ?? "",
    ...(name ? { name } : {}),
    ...(summary ? { summary } : {}),
    ...(firstPrompt ? { firstPrompt } : {}),
    createdAt: entry.createdAt,
    modifiedAt: entry.modifiedAt,
    recencyAt: entry.recencyAt,
    availability: entry.availability,
    ...(forkedFromThreadId ? { forkedFromThreadId } : {}),
    ...(parentThreadId ? { parentThreadId } : {}),
  };
}

function truncateCatalogText(
  value: string | undefined,
  maximumLength: number,
): string | undefined {
  if (!value) return undefined;
  if (value.length <= maximumLength) return value;
  let end = maximumLength - 1;
  if (
    end > 0 &&
    isHighSurrogate(value.charCodeAt(end - 1)) &&
    isLowSurrogate(value.charCodeAt(end))
  ) {
    end -= 1;
  }
  return `${value.slice(0, end)}…`;
}

function validCatalogLineageId(value: string | undefined): string | undefined {
  return value && value.length <= MAX_CATALOG_LINEAGE_ID_LENGTH
    ? value
    : undefined;
}

function isHighSurrogate(value: number): boolean {
  return value >= 0xd800 && value <= 0xdbff;
}

function isLowSurrogate(value: number): boolean {
  return value >= 0xdc00 && value <= 0xdfff;
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
      return {
        ...unknownStatus(target, observedAt, "appServer"),
        // The app-server returned a status object, but its type is newer than
        // this Bridge understands. Keep that distinct from the ordinary
        // notLoaded case so capable clients can surface a real degraded state.
        runtimeAttachment: "loaded",
      };
  }
}

function statusForClient(
  status: ConversationSyncStatus,
  supportsAppServerStatusSemantics: boolean,
): ConversationSyncStatus {
  if (
    supportsAppServerStatusSemantics ||
    status.activity !== "unknown" ||
    status.runtimeAttachment !== "notLoaded" ||
    status.confidence !== "unknown" ||
    status.attention !== "none"
  ) {
    return status;
  }
  // Build 206 and older mapped every `activity: unknown` row to a visible
  // error, even when `runtimeAttachment: notLoaded` only meant that no live
  // runtime observation existed. Preserve the honest confidence/attachment
  // fields while projecting the neutral legacy activity that those clients
  // already render without inventing a Ready badge.
  return { ...status, activity: "idle" };
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

function externalSnapshotObservedAt(snapshot: ExternalCodexSnapshot): string {
  return snapshot.observedAt && validIso(snapshot.observedAt)
    ? snapshot.observedAt
    : new Date().toISOString();
}

function credibleExternalRunning(snapshot: ExternalCodexSnapshot): boolean {
  if (snapshot.state !== "running") return false;
  if (snapshot.runningEvidence !== "activity") return true;
  if (!snapshot.observedAt || !validIso(snapshot.observedAt)) return false;
  const observedAt = Date.parse(snapshot.observedAt);
  return (
    Number.isFinite(observedAt) &&
    Date.now() - observedAt <= EXTERNAL_CODEX_INFERRED_RUNNING_FRESHNESS_MS
  );
}

function statusObservedAfter(
  candidate: ConversationSyncStatus,
  current: ConversationSyncStatus,
): boolean {
  const candidateTime = Date.parse(candidate.observedAt);
  const currentTime = Date.parse(current.observedAt);
  return (
    Number.isFinite(candidateTime) &&
    Number.isFinite(currentTime) &&
    candidateTime > currentTime
  );
}

function externalStatusMayOverride(
  current: ConversationSyncStatus,
  external: ConversationSyncStatus,
): boolean {
  if (current.confidence !== "authoritative") return true;
  if (
    current.activity === "working" ||
    current.activity === "compacting" ||
    current.activity === "systemError" ||
    current.attention !== "none"
  ) {
    return false;
  }
  if (current.activity === "unknown") return true;
  return (
    external.activity === "working" && statusObservedAfter(external, current)
  );
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
      `${CONTENT_STATE_SCHEMA_VERSION}\0${target.provider}\0${target.providerSessionId}\0${sourceRevision}`,
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

function laterIso(current: string, candidate: string): string {
  const currentTime = Date.parse(current);
  const candidateTime = Date.parse(candidate);
  if (!Number.isFinite(candidateTime)) return current;
  if (!Number.isFinite(currentTime) || candidateTime > currentTime) {
    return candidate;
  }
  return current;
}

function positiveInterval(value: number | undefined, fallback: number): number {
  return Number.isFinite(value) && (value ?? 0) > 0
    ? Math.floor(value!)
    : fallback;
}

function nonNegativeInteger(
  value: number | undefined,
  fallback: number,
): number {
  return Number.isFinite(value) && (value ?? -1) >= 0
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
