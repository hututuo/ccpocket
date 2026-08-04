import { createHash } from "node:crypto";

import {
  CodexProcess,
  CodexRpcError,
  type CodexThreadSourceKind,
  type CodexThreadSummary,
} from "../codex-process.js";
import { readCodexAppServerMode } from "../codex-app-server-config.js";
import {
  SharedCodexContentObserverCoordinator,
  asSharedCodexContentObserverProcess,
  type SharedCodexContentObserverCompletion,
  type SharedCodexContentObserverMessage,
  type SharedCodexContentObserverProcess,
} from "../codex-shared-runtime-content-observer.js";
import type {
  CodexActionBrokerRuntimeRequest,
  CodexActionBrokerRuntimeUpdate,
} from "../codex-action-broker-runtime.js";
import {
  selectTurnAwareHistoryWindow,
  TURN_AWARE_HISTORY_ENVELOPE_ENTRIES,
} from "../history-window.js";
import type { HistoryToolDetailPayload, ServerMessage } from "../parser.js";
import {
  codexThreadToSessionHistory,
  getAllRecentSessions,
  getCodexSessionIndexMetadata,
  getCodexDesktopToolTimeline,
  readClaudeSessionHistoryWindow,
  resolveCodexSessionJsonlPath,
  type CodexSessionIndexMetadata,
  type SessionIndexEntry,
} from "../sessions-index.js";
import type { SessionCatalogChange } from "../session-catalog-monitor.js";
import {
  buildConversationContentSnapshot,
  paginateConversationContentEntries,
  toWireConversationContentEntry,
  type ConversationContentLatestTurnGap,
  type ConversationContentSnapshot,
  type ConversationContentSnapshotEntry,
} from "./conversation-content-sync.js";
import type { CodexDesktopToolTimeline } from "./codex-tool-history.js";
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
import type { ContextUsageMessage } from "./slots/session-insights-protocol.js";
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
  LocalFeatureSharedRuntimeControlUpdate,
  LocalFeatureSession,
} from "./runtime.js";
import type {
  TerminalResultScope,
  TerminalResultValue,
} from "./terminal-result-ledger.js";

const MAX_CATALOG_ENTRIES = 10_000;
const MAX_TERMINAL_RESULT_ENTRIES = 4_096;
const MAX_CATALOG_NAME_LENGTH = 512;
const MAX_CATALOG_TEXT_LENGTH = 4_096;
const MAX_CATALOG_PATH_LENGTH = 4_096;
const MAX_CATALOG_LINEAGE_ID_LENGTH = 256;
const MAX_CATALOG_MODEL_LENGTH = 256;
const MAX_CATALOG_SETTING_LENGTH = 64;
const CODEX_PAGE_SIZE = 500;
// Subagents are attached to their owning conversation and surface through the
// per-session process UI. Including their internal threads in the main catalog
// both leaks implementation detail and crowds out real user conversations.
export const CONVERSATION_SYNC_PRIMARY_CODEX_SOURCE_KINDS = [
  "cli",
  "vscode",
  "exec",
  "appServer",
] as const satisfies readonly CodexThreadSourceKind[];
const PRIORITY_RECENT_COUNT = 5;
const PRIORITY_CODEX_SETTINGS_CONCURRENCY = 3;
const MAX_PENDING_PRIORITY_CODEX_SETTINGS = 32;
const CODEX_SETTINGS_HYDRATION_TIMEOUT_MS = 5_000;
const MIN_RECENT_COUNT = 10;
const RECENT_WINDOW_MS = 3 * 24 * 60 * 60_000;
const STATUS_WATCHDOG_MS = 5_000;
const SHARED_CONTROL_RECONCILE_MS = 50;
const MAX_SHARED_CONTROL_RECOVERY_THREADS = 64;
const SHARED_CONTROL_RECOVERY_TIMEOUT_MS = 5_000;
const SHARED_CONTROL_RECOVERY_CONCURRENCY = 4;
const LEGACY_STATUS_STATE_PREFIX = "legacy-status-v1:";
const APP_SERVER_STATUS_STATE_PREFIX = "app-server-status-v1:";
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
const LEGACY_WINDOW_CURSOR_PREFIX = "ccp-legacy-window-v1:";
const MAX_CODEX_RAW_TURN_ITEMS = 256;
const MAX_CODEX_RAW_TURN_BYTES = 192 * 1024;
const MAX_CODEX_RAW_ITEM_BYTES = 32 * 1024;
const MAX_CODEX_RAW_STRING_BYTES = 24 * 1024;
const MAX_CODEX_RAW_ARRAY_ITEMS = 64;
const MAX_CODEX_RAW_OBJECT_KEYS = 64;
const MAX_CODEX_RAW_DEPTH = 5;
const PAGE_PROJECTION_TEXT_BUDGETS = [
  32 * 1024,
  16 * 1024,
  8 * 1024,
  4 * 1024,
  2 * 1024,
  1024,
  512,
  256,
  128,
] as const;
const LIVE_CONTENT_SETTLE_MS = 100;
const LIVE_CONTENT_MAX_WAIT_MS = 1_000;
const MAX_SHARED_OBSERVER_LIVE_MESSAGES = 256;
const MAX_SHARED_OBSERVER_LIVE_BYTES_PER_THREAD = 512 * 1024;
const MAX_SHARED_OBSERVER_INLINE_IMAGES = 4;
const MAX_SHARED_OBSERVER_INLINE_IMAGE_BASE64_BYTES = 8 * 1024 * 1024;
const CATALOG_CONNECTION_REUSE_MS = 5_000;
const FOCUSED_CODEX_SETTINGS_RETRY_MS = 5_000;
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
const STATUS_STATE_SCHEMA_VERSION = 5;
// Build 208 could persist a content revision without observing Desktop-owned
// rollout changes, and the first v2 snapshot could cut into an oversized latest
// turn without declaring that gap. Advance the semantic generation so upgraded
// clients refresh the bounded hot window once and receive the completeness
// metadata instead of trusting those stale revisions.
const CONTENT_STATE_SCHEMA_VERSION = 4;

type ConversationKey = string;
type WithCodexReadProcess = <T>(
  operation: (process: CodexProcess) => Promise<T>,
) => Promise<T>;
type SharedRuntimeControlEvent = Extract<
  LocalFeatureSharedRuntimeControlUpdate,
  { kind: "event" }
>["event"];
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
  notificationOnly: boolean;
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
  fullSyncRequested: boolean;
  dirtyThreadKeys: Set<ConversationKey>;
  capacityWaiters: Set<() => void>;
}

interface ConversationSyncV2Options {
  catalogReader?: () => Promise<ConversationSyncCatalogSeed[]>;
  /** Test seam for authoritative Codex thread settings scans. */
  focusedCodexMetadataReader?: (
    threadId: string,
  ) => Promise<CodexSessionIndexMetadata | undefined>;
  codexSettingsHydrationTimeoutMs?: number;
  statusReader?: (
    current: ReadonlyMap<ConversationKey, CatalogRecord>,
  ) => Promise<Map<ConversationKey, ConversationSyncStatus>>;
  historyReader?: ConversationHistoryReader;
  latestTurnHistoryReader?: ConversationHistoryReader;
  statusWatchdogMs?: number;
  coldReconcileMs?: number;
  observeCodexThread?: ObserveCodexThread;
  inspectCodexThread?: InspectCodexThread;
  desktopToolTimelineReader?: DesktopToolTimelineReader;
  initialExternalCodexMonitors?: number;
  maxExternalCodexMonitors?: number;
  sharedControlReconcileMs?: number;
  sharedControlRecoveryReader?: SharedControlRecoveryReader;
  sharedControlRecoveryTimeoutMs?: number;
  maxConcurrentSharedControlRecoveries?: number;
  /** Deterministic test override; production derives this from Bridge mode. */
  daemonMode?: boolean;
  createSharedContentObserverProcess?: () => SharedCodexContentObserverProcess;
  maxSharedContentObservers?: number;
  sharedContentObserverUnfocusGraceMs?: number;
  sharedContentObserverAttachTimeoutMs?: number;
  maxConcurrentSharedContentObserverAttaches?: number;
  sharedContentObserverRetryDelaysMs?: readonly number[];
  /** Test seam for the focused-thread usage side channel. */
  publishSharedContextUsage?: (
    client: object,
    message: ContextUsageMessage,
  ) => void;
}

interface SharedControlRecoverySnapshot {
  turnId?: string;
  status?: "inProgress" | "completed" | "failed" | "interrupted" | "unknown";
  observedAt?: string;
}

type SharedControlRecoveryReader = (
  target: ConversationSyncTarget,
  signal: AbortSignal,
) => Promise<SharedControlRecoverySnapshot | null>;

interface SharedControlRecoveryTarget {
  target: ConversationSyncTarget;
  lastKnown: ConversationSyncStatus;
}

interface ConversationHistoryReadRequest {
  kind: "turns" | "items";
  cursor: string | null;
  limit: number;
  sortDirection: "asc" | "desc";
  itemsView?: "summary" | "full";
  turnId?: string;
}

interface ConversationHistoryWindow {
  messages: ServerMessage[];
  nextTurnCursor: string | null;
  turnDetails?: ConversationTurnDetails[];
  latestTurnComplete?: boolean;
  latestTurnGap?: ConversationContentLatestTurnGap;
  /**
   * Cursor this bounded window actually consumed. A reader must echo an
   * opaque non-null request cursor here; otherwise the fallback cannot prove
   * it advanced and must fail instead of replaying the first window.
   */
  sourceCursor?: string | null;
}

type ConversationHistoryReader = (
  target: ConversationSyncTarget,
  request?: ConversationHistoryReadRequest,
) => Promise<ServerMessage[] | ConversationHistoryWindow>;

interface NormalizedConversationTurn {
  turnId: string;
  messages: ServerMessage[];
  itemCount: number;
  itemsView: "summary" | "full";
  latestTurnComplete?: boolean;
  latestTurnGap?: ConversationContentLatestTurnGap;
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

interface TimelinePatchPage {
  entries: ConversationContentSnapshotEntry[];
  deletes: string[];
}

type CodexReadRunner = <T>(
  operation: (process: CodexProcess) => Promise<T>,
) => Promise<T>;

interface CachedTurnDetails {
  details: Map<string, HistoryToolDetailPayload>;
  bytes: number;
}

interface LiveContentRevision {
  target: ConversationSyncTarget;
  /** Latest timeline event, including streaming, thinking, and tool traffic. */
  observedAt: string;
  /** Latest discrete assistant text allowed to advance catalog ordering. */
  catalogObservedAt?: string;
  revision: string;
  /** Narrowest provider read still required before publishing this revision. */
  readScope: "direct" | "latestTurn" | "recent";
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

type DesktopToolTimelineReader = (
  threadId: string,
) => Promise<CodexDesktopToolTimeline>;

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
  private readonly focusedCodexMetadataReader: (
    threadId: string,
  ) => Promise<CodexSessionIndexMetadata | undefined>;
  private readonly codexSettingsHydrationTimeoutMs: number;
  private readonly statusReader: (
    current: ReadonlyMap<ConversationKey, CatalogRecord>,
  ) => Promise<Map<ConversationKey, ConversationSyncStatus>>;
  private readonly historyReader: ConversationHistoryReader;
  private readonly latestTurnHistoryReader: ConversationHistoryReader;
  private readonly statusWatchdogMs: number;
  private readonly coldReconcileMs: number;
  private readonly observeCodexThread: ObserveCodexThread;
  private readonly inspectCodexThread: InspectCodexThread;
  private readonly desktopToolTimelineReader: DesktopToolTimelineReader;
  private readonly initialExternalCodexMonitors: number;
  private readonly maxExternalCodexMonitors: number;
  private readonly sharedControlReconcileMs: number;
  private readonly sharedControlRecoveryReader: SharedControlRecoveryReader;
  private readonly sharedControlRecoveryTimeoutMs: number;
  private readonly maxConcurrentSharedControlRecoveries: number;
  private readonly daemonMode: boolean;
  private readonly legacyCodexMonitoringEnabled: boolean;

  private readonly subscriptions = new Map<object, SyncSubscription>();
  private catalog = new Map<ConversationKey, CatalogRecord>();
  private catalogState = hashState([]);
  private statusState = hashState([STATUS_STATE_SCHEMA_VERSION]);
  private catalogProjection = new Map<
    ConversationKey,
    ConversationSyncCatalogEntry
  >();
  private statusProjection = new Map<ConversationKey, ConversationSyncStatus>();
  private backgroundActiveKeys = new Set<ConversationKey>();
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
    {
      turnId?: string;
      result: TerminalResultValue;
      observedAt: string;
      revision: number;
    }
  >();
  private readonly terminalResultScope?: TerminalResultScope;
  private terminalResultWrites: Promise<void> = Promise.resolve();
  private readonly turnDetailCache = new Map<string, CachedTurnDetails>();
  private readonly liveContentRevisions = new Map<
    ConversationKey,
    LiveContentRevision
  >();
  private readonly pendingLiveContent = new Map<
    ConversationKey,
    {
      target: ConversationSyncTarget;
      observedAt: string;
      readScope: LiveContentRevision["readScope"];
    }
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
  private readonly sharedRuntimeStatuses = new Map<
    ConversationKey,
    ConversationSyncStatus
  >();
  private readonly externalCodexLiveMessages = new Map<
    ConversationKey,
    Map<string, ExternalCodexLiveMessage>
  >();
  private readonly externalCodexLiveBytes = new Map<ConversationKey, number>();
  private readonly sharedObserverLiveMessages = new Map<
    ConversationKey,
    Map<string, ExternalCodexLiveMessage>
  >();
  private readonly sharedObserverLiveBytes = new Map<ConversationKey, number>();
  private readonly externalCodexDiscoveredRunning = new Map<
    string,
    ExternalCodexSnapshot
  >();
  private readonly pendingExternalCodexThreads = new Set<string>();
  private externalCodexMonitorGeneration = 0;
  private externalCodexDiscoveryGeneration = 0;
  private externalCodexDiscoveryCompletedAt = 0;
  private sharedRuntimeControlUnsubscribe?: () => void;
  private codexActionBrokerUnsubscribe?: () => void;
  private readonly sharedContentObservers?: SharedCodexContentObserverCoordinator;
  private readonly publishSharedContextUsage: (
    client: object,
    message: ContextUsageMessage,
  ) => void;
  private sharedControlGeneration = 0;
  private sharedControlReady = false;
  private sharedControlLastSequence = 0;
  private sharedControlCatalogReconcilePending = false;
  private sharedControlStatusReconcilePending = false;
  private sharedControlReconcileTimer?: ReturnType<typeof setTimeout>;
  private readonly sharedControlRecoveryTargets = new Map<
    ConversationKey,
    SharedControlRecoveryTarget
  >();
  private sharedControlRecoveryAbort?: AbortController;
  private sharedControlRecoveryFlight?: {
    connectionGeneration: number;
    promise: Promise<void>;
  };
  private sharedCodexReadProcess?: CodexProcess;
  private sharedCodexReadProcessFlight?: Promise<CodexProcess>;
  private sharedCodexReadProcessUsers = 0;
  private sharedCodexReadProcessCloseRequested = false;
  private turnDetailCacheBytes = 0;
  private catalogFlight?: Promise<void>;
  private catalogDirty = true;
  private catalogRefreshedAt = 0;
  private readonly focusedCodexSettingsFlights = new Map<
    ConversationKey,
    Promise<boolean>
  >();
  private readonly focusedCodexSettingsAttempts = new Map<
    ConversationKey,
    { signature: string; attemptedAt: number; complete: boolean }
  >();
  private codexSettingsHydrationGeneration = 0;
  private readonly codexSettingsHydrationEpochs = new Map<
    ConversationKey,
    number
  >();
  private readonly codexSettingsFlightObservations = new Map<
    ConversationKey,
    { generation: number; epoch: number }
  >();
  private readonly codexSettingsRerunKeys = new Set<ConversationKey>();
  private readonly priorityCodexSettingsQueue = new Set<ConversationKey>();
  private activePriorityCodexSettings = 0;
  private statusFlight?: Promise<void>;
  private watchdogTimer?: ReturnType<typeof setTimeout>;
  private coldTimer?: ReturnType<typeof setTimeout>;
  private liveContentTimer?: ReturnType<typeof setTimeout>;
  private liveContentBatchStartedAt?: number;
  private liveRevision = 0;
  private closed = false;

  constructor(
    private readonly runtime: LocalFeatureRuntime,
    options: ConversationSyncV2Options = {},
  ) {
    this.daemonMode =
      options.daemonMode ?? readCodexAppServerMode() === "daemon";
    this.publishSharedContextUsage =
      options.publishSharedContextUsage ??
      ((client, message) => this.runtime.send(client, message));
    this.legacyCodexMonitoringEnabled = !this.daemonMode;
    this.catalogReader =
      options.catalogReader ??
      (() =>
        readUnifiedCatalog(this.runtime, (operation) =>
          this.withSharedCodexReadProcess(operation),
        ));
    this.focusedCodexMetadataReader =
      options.focusedCodexMetadataReader ??
      (async (threadId) =>
        (
          await getCodexSessionIndexMetadata([threadId], {
            authoritativeCodexSettings: true,
          })
        ).get(threadId));
    this.codexSettingsHydrationTimeoutMs =
      options.codexSettingsHydrationTimeoutMs ??
      CODEX_SETTINGS_HYDRATION_TIMEOUT_MS;
    this.statusReader =
      options.statusReader ??
      ((current) =>
        readCurrentStatuses(this.runtime, current, (operation) =>
          this.withSharedCodexReadProcess(operation),
        ));
    this.historyReader =
      options.historyReader ??
      ((target, request) =>
        this.readRecentConversationHistory(target, request));
    this.latestTurnHistoryReader =
      options.latestTurnHistoryReader ??
      ((target) => this.readLatestCodexConversationHistory(target));
    this.statusWatchdogMs = positiveInterval(
      options.statusWatchdogMs,
      STATUS_WATCHDOG_MS,
    );
    this.coldReconcileMs = positiveInterval(
      options.coldReconcileMs,
      COLD_RECONCILE_MS,
    );
    this.sharedControlReconcileMs = positiveInterval(
      options.sharedControlReconcileMs,
      SHARED_CONTROL_RECONCILE_MS,
    );
    this.sharedControlRecoveryReader =
      options.sharedControlRecoveryReader ??
      ((target, signal) =>
        this.readSharedControlRecoverySnapshot(target, signal));
    this.sharedControlRecoveryTimeoutMs = positiveInterval(
      options.sharedControlRecoveryTimeoutMs,
      SHARED_CONTROL_RECOVERY_TIMEOUT_MS,
    );
    this.maxConcurrentSharedControlRecoveries = Math.min(
      4,
      Math.max(
        2,
        positiveInterval(
          options.maxConcurrentSharedControlRecoveries,
          SHARED_CONTROL_RECOVERY_CONCURRENCY,
        ),
      ),
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
    this.desktopToolTimelineReader =
      options.desktopToolTimelineReader ?? getCodexDesktopToolTimeline;
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
    if (
      this.runtime.terminalResultLedger &&
      this.runtime.bridgeInstanceId &&
      this.runtime.codexSourceId
    ) {
      this.terminalResultScope = {
        bridgeInstanceId: this.runtime.bridgeInstanceId,
        codexSourceId: this.runtime.codexSourceId,
      };
      try {
        for (const record of this.runtime.terminalResultLedger.list(
          this.terminalResultScope,
        )) {
          this.resultLedger.set(
            targetKey({
              provider: record.provider,
              providerSessionId: record.threadId,
            }),
            {
              ...(record.turnId ? { turnId: record.turnId } : {}),
              result: record.result,
              observedAt: record.observedAt,
              revision: record.revision,
            },
          );
        }
      } catch {
        // Persistence is optional. An invalid identity or damaged legacy file
        // must not make conversation sync unavailable.
      }
    }
    const createSharedContentObserverProcess =
      options.createSharedContentObserverProcess ??
      (this.runtime.createDedicatedCodexProcess
        ? () =>
            asSharedCodexContentObserverProcess(
              this.runtime.createDedicatedCodexProcess!(),
            )
        : undefined);
    if (this.daemonMode && createSharedContentObserverProcess) {
      this.sharedContentObservers = new SharedCodexContentObserverCoordinator({
        codexSourceId: this.runtime.codexSourceId,
        createProcess: createSharedContentObserverProcess,
        onMessage: (event) => this.handleSharedObserverMessage(event),
        onCompletion: (event) => this.handleSharedObserverCompletion(event),
        maxObservers: options.maxSharedContentObservers,
        unfocusGraceMs: options.sharedContentObserverUnfocusGraceMs,
        attachTimeoutMs: options.sharedContentObserverAttachTimeoutMs,
        maxConcurrentAttaches:
          options.maxConcurrentSharedContentObserverAttaches,
        retryDelaysMs: options.sharedContentObserverRetryDelaysMs,
      });
    }
    this.sharedRuntimeControlUnsubscribe =
      this.runtime.subscribeSharedRuntimeControl?.((update) =>
        this.handleSharedRuntimeControlUpdate(update),
      );
    this.codexActionBrokerUnsubscribe =
      this.runtime.codexActionBroker?.subscribe((update) =>
        this.handleCodexActionBrokerUpdate(update),
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
    subscription.notificationOnly = mode === "notifications_only";
    if (subscription.interactive) {
      this.sharedContentObservers?.setActive(true);
      this.markCatalogDirtyIfStale();
      this.scheduleSync(client, subscription, { full: true });
      this.ensureTimers();
      this.armSharedControlReconcile();
    } else {
      subscription.outbound.length = 0;
      subscription.queuedBytes = 0;
      this.wakeCapacityWaiters(subscription);
      if (!this.hasInteractiveClients()) {
        this.priorityCodexSettingsQueue.clear();
        this.clearExternalCodexMonitoring();
        this.requestSharedCodexReadProcessClose();
      }
    }
    this.reconcileSharedContentObservers();
    if (subscription.notificationOnly) {
      this.requestSharedControlReconcile({ catalog: true, status: true });
    }
  }

  backgroundNotificationDemandChanged(): void {
    this.reconcileSharedContentObservers();
    if (this.hasSharedObserverDemand()) {
      this.requestSharedControlReconcile({ catalog: true, status: true });
    }
  }

  backgroundActiveConversationKeys(): Iterable<string> {
    return this.backgroundActiveKeys;
  }

  conversationActivity(
    provider: string,
    providerSessionId: string,
  ): "active" | "inactive" | "unknown" {
    const status = this.statusProjection.get(
      targetKey({ provider, providerSessionId } as ConversationSyncTarget),
    );
    if (!status) return "unknown";
    if (statusNeedsBackgroundDelivery(status)) return "active";
    if (
      status.activity === "unknown" ||
      status.controlState === "reconciling" ||
      status.controlState === "unavailable"
    ) {
      return "unknown";
    }
    return "inactive";
  }

  sessionCatalogChanged(change?: SessionCatalogChange): void {
    this.catalogDirty = true;
    const exactCodexThreadId =
      change?.provider === "codex" ? change.providerSessionId : undefined;
    if (exactCodexThreadId && this.legacyCodexMonitoringEnabled) {
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
      exactCodexThreadId && this.legacyCodexMonitoringEnabled
        ? this.ensureExternalCodexMonitor(exactCodexThreadId, true)
            .catch((error) => {
              this.reportExternalObservationFailure(error);
              return null;
            })
            .then(() => this.refreshCatalog())
        : this.refreshCatalog()
    )
      .then(() => this.scheduleInteractiveClients({ full: true }))
      .catch((error) => {
        this.reportBackgroundError("catalog_refresh_failed", error);
      });
  }

  runtimeSessionChanged(session: LocalFeatureSession): void {
    const target = this.targetForSession(session);
    if (!target) return;

    const changedKeys = new Set([targetKey(target)]);
    const previousCatalogState = this.catalogState;
    const previousStatusState = this.statusState;
    this.applyRuntimeOverlay(changedKeys);
    this.recomputeStates(changedKeys);
    this.reconcileSharedContentObservers();
    if (
      this.catalogState !== previousCatalogState ||
      this.statusState !== previousStatusState
    ) {
      this.scheduleInteractiveClients({ dirtyKeys: changedKeys });
    }
  }

  sessionMessage(session: LocalFeatureSession, message: ServerMessage): void {
    const target = this.targetForSession(session);
    if (!target) return;
    const key = targetKey(target);
    const observedAt = new Date().toISOString();
    if (message.type === "result") {
      const terminal = terminalResultFromServerMessage(message);
      if (terminal) this.setTerminalResult(target, terminal, observedAt);
    } else if (message.type === "user_input") {
      this.clearTerminalResult(target, observedAt);
    }
    if (!this.hasInteractiveClients()) return;

    if (isStreamingConversationDelta(message)) {
      this.queueLiveContent(target, observedAt);
      return;
    }
    if (isConversationTimelineMessage(message)) {
      this.publishLiveContent(
        target,
        observedAt,
        assistantTextCatalogActivity(message, observedAt),
      );
      return;
    }

    const previousStatusState = this.statusState;
    const changedKeys = new Set([key]);
    this.applyRuntimeOverlay(changedKeys);
    this.recomputeStates(changedKeys);
    if (this.statusState !== previousStatusState) {
      this.scheduleInteractiveClients();
    }
  }

  private setTerminalResult(
    target: ConversationSyncTarget,
    result: TerminalResultValue,
    observedAt: string,
    turnId?: string,
  ): void {
    const key = targetKey(target);
    const previous = this.resultLedger.get(key);
    if (previous && previous.observedAt > observedAt) return;
    this.resultLedger.set(key, {
      ...(turnId ? { turnId } : {}),
      result,
      observedAt,
      revision: previous?.revision ?? 0,
    });
    this.pruneTerminalResults();
    const ledger = this.runtime.terminalResultLedger;
    const scope = this.terminalResultScope;
    if (!ledger || !scope) return;
    this.enqueueTerminalResultWrite(async () => {
      const persisted = await ledger.record({
        ...scope,
        provider: target.provider,
        threadId: target.providerSessionId,
        ...(turnId ? { turnId } : {}),
        result,
        observedAt,
      });
      const current = this.resultLedger.get(key);
      if (
        current?.observedAt === observedAt &&
        current.result === result &&
        current.turnId === turnId
      ) {
        current.revision = persisted.revision;
      }
    });
  }

  private clearTerminalResult(
    target: ConversationSyncTarget,
    observedAt: string,
    _activeTurnId?: string,
  ): void {
    const key = targetKey(target);
    const previous = this.resultLedger.get(key);
    if (previous && previous.observedAt > observedAt) return;
    if (!previous) return;
    this.resultLedger.delete(key);
    const ledger = this.runtime.terminalResultLedger;
    const scope = this.terminalResultScope;
    if (!ledger || !scope) return;
    this.enqueueTerminalResultWrite(async () => {
      await ledger.clear(
        scope,
        target.provider,
        target.providerSessionId,
        observedAt,
        previous.turnId,
      );
    });
  }

  private pruneTerminalResults(): void {
    while (this.resultLedger.size > MAX_TERMINAL_RESULT_ENTRIES) {
      let oldestKey: ConversationKey | undefined;
      let oldestObservedAt: string | undefined;
      for (const [key, result] of this.resultLedger) {
        if (
          oldestObservedAt === undefined ||
          result.observedAt < oldestObservedAt
        ) {
          oldestKey = key;
          oldestObservedAt = result.observedAt;
        }
      }
      if (oldestKey === undefined) break;
      this.resultLedger.delete(oldestKey);
    }
  }

  private enqueueTerminalResultWrite(operation: () => Promise<void>): void {
    this.terminalResultWrites = this.terminalResultWrites
      .then(operation)
      .catch(() => {
        console.warn(
          "[conversation-sync-v2] Terminal result persistence unavailable",
        );
      });
  }

  private handleSharedRuntimeControlUpdate(
    update: LocalFeatureSharedRuntimeControlUpdate,
  ): void {
    if (this.closed) return;
    if (update.kind === "ready") {
      this.handleSharedControlReady(update.connectionGeneration);
      return;
    }
    if (update.kind === "not_ready") {
      this.handleSharedControlNotReady(update.connectionGeneration);
      return;
    }
    if (update.kind === "event") {
      this.handleSharedControlEvent(update.event);
      return;
    }
    const exhaustive: never = update;
    void exhaustive;
  }

  private handleSharedControlReady(connectionGeneration: number): void {
    if (connectionGeneration < this.sharedControlGeneration) return;
    if (
      connectionGeneration === this.sharedControlGeneration &&
      this.sharedControlReady
    ) {
      return;
    }
    const generationChanged =
      connectionGeneration !== this.sharedControlGeneration;
    if (generationChanged) this.cancelSharedControlRecovery();
    this.sharedControlGeneration = connectionGeneration;
    this.sharedControlReady = true;
    this.invalidateAllCodexSettingsHydration();
    this.sharedContentObservers?.setAuthority(connectionGeneration, true);
    if (generationChanged) this.sharedControlLastSequence = 0;
    this.clearSharedControlReconcileTimer();
    // A ready generation is a reset boundary. Mark the existing catalog dirty
    // here rather than inside the delayed worker so an initial Mobile sync and
    // the ready reconciliation can share the same in-flight full read.
    this.catalogDirty = true;
    const changedKeys = this.transitionSharedDaemonAuthority("reconciling");
    this.publishSharedControlChanges(changedKeys);
    this.requestSharedControlReconcile({ catalog: true, status: true });
    this.reconcileSharedContentObservers();
  }

  private handleSharedControlNotReady(connectionGeneration: number): void {
    if (connectionGeneration < this.sharedControlGeneration) return;
    this.cancelSharedControlRecovery();
    this.sharedControlGeneration = connectionGeneration;
    this.sharedControlReady = false;
    this.invalidateAllCodexSettingsHydration();
    this.sharedContentObservers?.setAuthority(connectionGeneration, false);
    this.sharedControlLastSequence = 0;
    this.clearSharedControlReconcileTimer();
    this.sharedControlCatalogReconcilePending = false;
    this.sharedControlStatusReconcilePending = false;
    this.captureSharedControlRecoveryTargets();
    const changedKeys = this.transitionSharedDaemonAuthority("unavailable");
    this.publishSharedControlChanges(changedKeys);
  }

  private handleSharedControlEvent(event: SharedRuntimeControlEvent): void {
    if (
      !this.sharedControlReady ||
      event.connectionGeneration !== this.sharedControlGeneration ||
      event.sequence <= this.sharedControlLastSequence
    ) {
      return;
    }
    this.sharedControlLastSequence = event.sequence;
    const threadId = event.threadId;
    if (!threadId) return;
    const target: ConversationSyncTarget = {
      provider: "codex",
      providerSessionId: threadId,
    };
    const key = targetKey(target);
    if (event.method === "thread/settings/updated") {
      const knownThread = this.catalog.has(key);
      this.invalidateCodexSettingsHydration(key);
      if (!knownThread) {
        this.catalogDirty = true;
        this.requestSharedControlReconcile({ catalog: true, status: false });
        return;
      }
      if (!this.focusedCodexSettingsFlights.has(key)) {
        this.prioritizeCodexSettingsHydration(key);
      }
      return;
    }
    const previous =
      this.sharedRuntimeStatuses.get(key) ??
      this.catalog.get(key)?.status ??
      unknownStatus(target, event.observedAt, "appServer");
    const next = sharedControlStatusFromEvent(
      event,
      previous,
      sharedControlAuthorityGeneration(this.sharedControlGeneration),
      this.runtime.codexActionBroker === undefined,
    );
    if (next) {
      if (next.activity === "working" || next.activity === "compacting") {
        next.executionHost = this.hasActiveBridgeOwnedCodexRuntime(
          threadId,
          event.turnId,
        )
          ? "bridge"
          : "desktopAppServer";
      }
      if (
        event.method === "turn/started" ||
        ((event.method === "thread/started" ||
          event.method === "thread/status/changed") &&
          next.activity === "working")
      ) {
        this.clearTerminalResult(target, event.observedAt, event.turnId);
      } else if (
        event.method === "turn/completed" &&
        (next.result === "completed" || next.result === "failed")
      ) {
        this.setTerminalResult(
          target,
          next.result,
          event.observedAt,
          event.turnId,
        );
        this.publishExternalCodexNotificationCandidate({
          threadId,
          turnId: event.turnId,
          observedAt: event.observedAt,
          message: {
            type: "result",
            subtype: next.result === "completed" ? "success" : "error",
            sessionId: threadId,
          },
        });
      }
      this.rememberSharedRuntimeStatus(key, next);
      if (
        event.method === "turn/started" ||
        event.method === "turn/completed"
      ) {
        this.sharedControlRecoveryTargets.delete(key);
      }
    }
    const knownThread = this.catalog.has(key);
    if (
      knownThread &&
      event.method === "turn/completed" &&
      this.hasInteractiveClients()
    ) {
      // Status and content use separate observer transports. A completion can
      // race observer eviction or reconnect, so the authoritative control
      // event itself schedules one final latest-turn reconciliation.
      this.queueLiveContent(target, event.observedAt, "latestTurn");
    }
    if (next && knownThread) {
      this.publishSharedControlChanges(new Set([key]));
    }
    this.reconcileSharedContentObservers();
    if (!knownThread) {
      // The event is already the authoritative status for its one thread. A
      // catalog read is only needed to materialize an unknown identity; known
      // thread events must not fan out into a 10k-thread status scan.
      this.catalogDirty = true;
      this.requestSharedControlReconcile({ catalog: true, status: false });
    }
  }

  private reconcileSharedContentObservers(): void {
    const observers = this.sharedContentObservers;
    if (!observers) return;
    const observerDemand = this.hasSharedObserverDemand();
    observers.setActive(observerDemand);
    if (!observerDemand) return;
    const focusedKeys = new Set(
      [...this.subscriptions.values()]
        .filter(
          (subscription) => subscription.interactive && subscription.focusedKey,
        )
        .map((subscription) => subscription.focusedKey!),
    );
    const alreadyObservedRuntimeThreads = new Set(
      (this.runtime.listRuntimeConversationStates?.() ?? [])
        .filter(
          (state) =>
            state.provider === "codex" &&
            state.providerSessionId &&
            state.controlState !== "unavailable" &&
            state.controlState !== "reconciling",
        )
        .map((state) => state.providerSessionId!),
    );
    observers.setInterests(
      [...this.catalog.entries()]
        .filter(
          ([, record]) =>
            record.entry.provider === "codex" &&
            !alreadyObservedRuntimeThreads.has(record.entry.providerSessionId),
        )
        .map(([key, record]) => {
          const status = this.sharedRuntimeStatuses.get(key) ?? record.status;
          return {
            threadId: record.entry.providerSessionId,
            projectPath: record.entry.projectPath,
            focused: focusedKeys.has(key),
            needsAttention: status.attention !== "none",
            active:
              status.activity === "working" || status.activity === "compacting",
            observedAt: status.observedAt,
          };
        })
        .filter(
          (interest) =>
            interest.focused || interest.needsAttention || interest.active,
        ),
    );
  }

  private handleSharedObserverMessage(
    event: SharedCodexContentObserverMessage,
  ): void {
    if (
      this.closed ||
      !this.sharedControlReady ||
      event.connectionGeneration !== this.sharedControlGeneration
    ) {
      return;
    }
    if (event.message.type === "context_usage") {
      this.forwardSharedObserverContextUsage(event);
      return;
    }
    const target: ConversationSyncTarget = {
      provider: "codex",
      providerSessionId: event.threadId,
    };
    const message = withSourceTimestamp(
      annotateObservedTurn(
        sanitizeSharedObserverMessage(this.runtime, event.message),
        event.turnId,
      ),
      event.observedAt,
      false,
    );
    if (message.type === "result") {
      const terminal = terminalResultFromServerMessage(message);
      if (terminal) {
        this.setTerminalResult(
          target,
          terminal,
          event.observedAt,
          event.turnId,
        );
      }
      return;
    }
    if (message.type === "user_input") {
      this.clearTerminalResult(target, event.observedAt, event.turnId);
    }
    if (isStreamingConversationDelta(message)) {
      this.queueLiveContent(target, event.observedAt, "latestTurn");
      return;
    }
    if (!isConversationTimelineMessage(message)) return;
    const identity = observedMessageIdentity(message);
    if (!identity) {
      this.queueLiveContent(target, event.observedAt, "latestTurn");
      return;
    }
    const remembered = this.rememberSharedObserverMessage(
      target,
      `${event.turnId ?? "turn-unknown"}:${identity}`,
      message,
      event.observedAt,
    );
    if (!remembered) {
      this.queueLiveContent(target, event.observedAt, "latestTurn");
      return;
    }
    const progressMessage = backgroundProgressCandidate(message);
    if (progressMessage) {
      this.publishExternalCodexNotificationCandidate({
        threadId: event.threadId,
        turnId: event.turnId,
        observedAt: event.observedAt,
        message: progressMessage,
      });
    }
    this.publishLiveContent(
      target,
      event.observedAt,
      assistantTextCatalogActivity(message, event.observedAt),
      "direct",
    );
  }

  private forwardSharedObserverContextUsage(
    event: SharedCodexContentObserverMessage,
  ): void {
    if (event.message.type !== "context_usage") return;
    const focusedKey = targetKey({
      provider: "codex",
      providerSessionId: event.threadId,
    });
    const bridgeInstanceId = this.runtime.bridgeInstanceId;
    const codexSourceId = this.runtime.codexSourceId;
    if (!bridgeInstanceId || !codexSourceId) return;
    const message: ContextUsageMessage = {
      ...event.message,
      sessionId: event.threadId,
      threadId: event.threadId,
      ...(event.turnId ? { turnId: event.turnId } : {}),
      bridgeInstanceId,
      codexSourceId,
      authorityGeneration: `daemon:${event.connectionGeneration}:${event.observerGeneration}`,
    };
    for (const [client, subscription] of this.subscriptions) {
      if (
        !subscription.interactive ||
        subscription.focusedKey !== focusedKey ||
        !this.runtime.supports(client, "context_usage")
      ) {
        continue;
      }
      this.publishSharedContextUsage(client, message);
    }
  }

  private handleSharedObserverCompletion(
    event: SharedCodexContentObserverCompletion,
  ): void {
    if (
      this.closed ||
      !this.sharedControlReady ||
      event.connectionGeneration !== this.sharedControlGeneration
    ) {
      return;
    }
    // A completion is the canonicalization boundary. Direct observer messages
    // make the UI live immediately, then one coalesced latest-turn read repairs
    // any delta or tool notification that arrived without a stable identity.
    this.queueLiveContent(
      {
        provider: "codex",
        providerSessionId: event.threadId,
      },
      event.observedAt,
      "latestTurn",
    );
  }

  private publishExternalCodexNotificationCandidate(input: {
    threadId: string;
    turnId?: string;
    observedAt: string;
    message: Extract<ServerMessage, { type: "assistant" | "result" }>;
  }): void {
    const codexSourceId = this.runtime.codexSourceId;
    if (
      !codexSourceId ||
      !this.runtime.publishExternalCodexNotificationCandidate
    ) {
      return;
    }
    const entry = this.catalog.get(
      targetKey({
        provider: "codex",
        providerSessionId: input.threadId,
      }),
    )?.entry;
    const projectLabel = entry?.projectPath
      ?.replace(/[\\/]+$/, "")
      .split(/[\\/]/)
      .filter(Boolean)
      .at(-1);
    const name = entry?.name?.trim();
    const label = name
      ? projectLabel
        ? `${name} (${projectLabel})`
        : name
      : projectLabel;
    this.runtime.publishExternalCodexNotificationCandidate({
      codexSourceId,
      threadId: input.threadId,
      ...(input.turnId ? { turnId: input.turnId } : {}),
      observedAt: input.observedAt,
      ...(label ? { label } : {}),
      message: input.message,
    });
  }

  private rememberSharedObserverMessage(
    target: ConversationSyncTarget,
    itemKey: string,
    message: ServerMessage,
    observedAt: string,
  ): boolean {
    const key = targetKey(target);
    const bytes = Buffer.byteLength(stableJson(message), "utf8");
    if (bytes > MAX_SHARED_OBSERVER_LIVE_BYTES_PER_THREAD) return false;
    const messages =
      this.sharedObserverLiveMessages.get(key) ??
      new Map<string, ExternalCodexLiveMessage>();
    let totalBytes = this.sharedObserverLiveBytes.get(key) ?? 0;
    const previous = messages.get(itemKey);
    if (previous) totalBytes = Math.max(0, totalBytes - previous.bytes);
    messages.set(itemKey, { message, observedAt, bytes });
    totalBytes += bytes;
    while (
      messages.size > MAX_SHARED_OBSERVER_LIVE_MESSAGES ||
      totalBytes > MAX_SHARED_OBSERVER_LIVE_BYTES_PER_THREAD
    ) {
      const oldest = messages.keys().next().value;
      if (oldest === undefined) break;
      const removed = messages.get(oldest);
      messages.delete(oldest);
      if (removed) totalBytes = Math.max(0, totalBytes - removed.bytes);
    }
    if (messages.size === 0) {
      this.deleteSharedObserverLiveMessages(key);
      return false;
    }
    const retained = messages.has(itemKey);
    this.sharedObserverLiveMessages.set(key, messages);
    this.sharedObserverLiveBytes.set(key, totalBytes);
    return retained;
  }

  private deleteSharedObserverLiveMessages(key: ConversationKey): void {
    this.sharedObserverLiveMessages.delete(key);
    this.sharedObserverLiveBytes.delete(key);
  }

  private transitionSharedDaemonAuthority(
    controlState: "reconciling" | "unavailable",
  ): Set<ConversationKey> {
    const changedKeys = new Set<ConversationKey>();
    for (const key of this.sharedRuntimeStatuses.keys()) {
      const previous =
        this.sharedRuntimeStatuses.get(key) ?? this.catalog.get(key)?.status;
      if (!previous || !isSharedSpecialStatus(previous)) continue;
      const next = sharedControlTransitionStatus(
        previous,
        controlState,
        this.sharedControlGeneration,
      );
      this.rememberSharedRuntimeStatus(key, next);
      if (this.catalog.has(key)) changedKeys.add(key);
    }
    return changedKeys;
  }

  private captureSharedControlRecoveryTargets(): void {
    for (const [key, status] of this.sharedRuntimeStatuses) {
      if (!isSharedSpecialStatus(status)) continue;
      const record = this.catalog.get(key);
      if (!record || record.entry.provider !== "codex") continue;
      if (!this.sharedControlRecoveryTargets.has(key)) {
        this.sharedControlRecoveryTargets.set(key, {
          target: {
            provider: "codex",
            providerSessionId: record.entry.providerSessionId,
          },
          lastKnown: { ...status },
        });
      }
      if (
        this.sharedControlRecoveryTargets.size >=
        MAX_SHARED_CONTROL_RECOVERY_THREADS
      ) {
        break;
      }
    }
  }

  private handleCodexActionBrokerUpdate(
    update: CodexActionBrokerRuntimeUpdate,
  ): void {
    if (this.closed) return;
    const changedKeys = new Set<ConversationKey>();
    if (update.kind === "request") {
      this.applyCodexActionRequest(update.request, changedKeys);
    } else {
      for (const request of this.runtime.codexActionBroker?.listRequests() ??
        []) {
        this.applyCodexActionRequest(request, changedKeys);
      }
    }
    this.publishSharedControlChanges(changedKeys);
    this.reconcileSharedContentObservers();
  }

  private applyCodexActionRequest(
    request: CodexActionBrokerRuntimeRequest,
    changedKeys: Set<ConversationKey>,
  ): void {
    if (
      this.runtime.codexSourceId &&
      request.codexSourceId !== this.runtime.codexSourceId
    ) {
      return;
    }
    const target: ConversationSyncTarget = {
      provider: "codex",
      providerSessionId: request.threadId,
    };
    const key = targetKey(target);
    const previous =
      this.sharedRuntimeStatuses.get(key) ?? this.catalog.get(key)?.status;
    if (!previous) return;
    if (request.state === "resolved" || request.state === "expired") {
      if (previous.attentionRequestId !== request.opaqueRequestId) return;
      const replacement = this.runtime.codexActionBroker
        ?.listRequests({ threadId: request.threadId })
        .filter(
          (candidate) =>
            candidate.opaqueRequestId !== request.opaqueRequestId &&
            (candidate.state === "pending" || candidate.state === "claimed"),
        )
        .at(-1);
      if (replacement) {
        this.applyCodexActionRequest(replacement, changedKeys);
        return;
      }
      const next: ConversationSyncStatus = {
        ...previous,
        attention: "none",
        observedAt: request.updatedAt,
      };
      delete next.attentionRequestId;
      this.rememberSharedRuntimeStatus(key, next);
      if (this.catalog.has(key)) changedKeys.add(key);
      return;
    }
    const brokerReady = this.runtime.codexActionBroker?.health.ready === true;
    const next: ConversationSyncStatus = {
      ...previous,
      activity: previous.activity === "compacting" ? "compacting" : "working",
      attention: attentionFromCodexAction(request),
      result: "none",
      runtimeAttachment: "loaded",
      source: "appServer",
      confidence: brokerReady && request.live ? "authoritative" : "unknown",
      observedAt: request.updatedAt,
      attentionRequestId: request.opaqueRequestId,
      activeTurnId: request.turnId,
      controlState: brokerReady && request.live ? "readOnly" : "unavailable",
    };
    this.rememberSharedRuntimeStatus(key, next);
    if (this.catalog.has(key)) changedKeys.add(key);
  }

  private applyCodexActionBrokerOverlay(
    onlyKeys?: ReadonlySet<ConversationKey>,
  ): void {
    for (const request of this.runtime.codexActionBroker?.listRequests() ??
      []) {
      const key = targetKey({
        provider: "codex",
        providerSessionId: request.threadId,
      });
      if (onlyKeys && !onlyKeys.has(key)) continue;
      this.applyCodexActionRequest(request, new Set());
    }
  }

  private rememberSharedRuntimeStatus(
    key: ConversationKey,
    status: ConversationSyncStatus,
  ): void {
    this.sharedRuntimeStatuses.set(key, status);
    while (this.sharedRuntimeStatuses.size > MAX_CATALOG_ENTRIES) {
      const oldest = this.sharedRuntimeStatuses.keys().next().value;
      if (oldest === undefined) break;
      this.sharedRuntimeStatuses.delete(oldest);
    }
  }

  private publishSharedControlChanges(
    changedKeys: ReadonlySet<ConversationKey>,
  ): void {
    if (changedKeys.size === 0) return;
    this.applyRuntimeOverlay(changedKeys);
    this.recomputeStates(changedKeys);
    this.scheduleInteractiveClients({ dirtyKeys: changedKeys });
  }

  private requestSharedControlReconcile(options: {
    catalog: boolean;
    status: boolean;
  }): void {
    this.sharedControlCatalogReconcilePending ||= options.catalog;
    this.sharedControlStatusReconcilePending ||= options.status;
    this.armSharedControlReconcile();
  }

  private armSharedControlReconcile(): void {
    if (
      this.closed ||
      !this.sharedControlReady ||
      !this.hasSharedObserverDemand() ||
      this.sharedControlReconcileTimer ||
      (!this.sharedControlCatalogReconcilePending &&
        !this.sharedControlStatusReconcilePending)
    ) {
      return;
    }
    this.sharedControlReconcileTimer = setTimeout(() => {
      this.sharedControlReconcileTimer = undefined;
      const catalog = this.sharedControlCatalogReconcilePending;
      const status = this.sharedControlStatusReconcilePending;
      this.sharedControlCatalogReconcilePending = false;
      this.sharedControlStatusReconcilePending = false;
      void this.runSharedControlReconcile(catalog, status);
    }, this.sharedControlReconcileMs);
    this.sharedControlReconcileTimer.unref?.();
  }

  private async runSharedControlReconcile(
    catalogRequested: boolean,
    statusRequested: boolean,
  ): Promise<void> {
    if (this.closed || !this.sharedControlReady) return;
    if (catalogRequested) {
      try {
        await this.refreshCatalog();
        this.enqueuePriorityCodexSettingsForInteractiveClients();
      } catch (error) {
        this.reportBackgroundError("control_catalog_refresh_failed", error);
      }
    }
    if (statusRequested && this.sharedControlReady) {
      try {
        await this.refreshStatuses();
      } catch (error) {
        this.reportBackgroundError("control_status_refresh_failed", error);
      }
    }
    if (this.sharedControlReady && this.sharedControlRecoveryTargets.size > 0) {
      await this.reconcileSharedControlRecoveryTargets(
        this.sharedControlGeneration,
      );
    }
    this.reconcileSharedContentObservers();
    this.scheduleInteractiveClients();
    this.armSharedControlReconcile();
  }

  private clearSharedControlReconcileTimer(): void {
    if (!this.sharedControlReconcileTimer) return;
    clearTimeout(this.sharedControlReconcileTimer);
    this.sharedControlReconcileTimer = undefined;
  }

  disconnect(client: object): void {
    const subscription = this.subscriptions.get(client);
    if (subscription) this.wakeCapacityWaiters(subscription);
    this.subscriptions.delete(client);
    if (!this.hasInteractiveClients()) {
      this.priorityCodexSettingsQueue.clear();
      this.cancelTimers();
      this.clearExternalCodexMonitoring();
      this.requestSharedCodexReadProcessClose();
    }
    this.reconcileSharedContentObservers();
  }

  async close(): Promise<void> {
    this.closed = true;
    this.sharedRuntimeControlUnsubscribe?.();
    this.sharedRuntimeControlUnsubscribe = undefined;
    this.codexActionBrokerUnsubscribe?.();
    this.codexActionBrokerUnsubscribe = undefined;
    this.sharedContentObservers?.close();
    this.cancelSharedControlRecovery();
    for (const subscription of this.subscriptions.values()) {
      this.wakeCapacityWaiters(subscription);
    }
    this.subscriptions.clear();
    this.snapshots.clear();
    this.snapshotFlights.clear();
    this.turnDetailCache.clear();
    this.liveContentRevisions.clear();
    this.pendingLiveContent.clear();
    this.catalogProjection.clear();
    this.statusProjection.clear();
    this.clearExternalCodexMonitoring();
    this.externalCodexDiscoveredRunning.clear();
    this.pendingExternalCodexThreads.clear();
    this.sharedRuntimeStatuses.clear();
    this.sharedObserverLiveMessages.clear();
    this.sharedObserverLiveBytes.clear();
    this.sharedControlRecoveryTargets.clear();
    this.focusedCodexSettingsFlights.clear();
    this.focusedCodexSettingsAttempts.clear();
    this.codexSettingsHydrationGeneration += 1;
    this.codexSettingsHydrationEpochs.clear();
    this.codexSettingsFlightObservations.clear();
    this.codexSettingsRerunKeys.clear();
    this.priorityCodexSettingsQueue.clear();
    this.activePriorityCodexSettings = 0;
    this.sharedControlCatalogReconcilePending = false;
    this.sharedControlStatusReconcilePending = false;
    this.externalCodexDiscoveryCompletedAt = 0;
    this.requestSharedCodexReadProcessClose();
    this.turnDetailCacheBytes = 0;
    this.cancelTimers();
    await this.terminalResultWrites;
    await this.runtime.terminalResultLedger?.flush();
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
    const deliveryMode =
      this.runtime.getClientDeliveryMode?.(client) ?? "interactive";
    const previous = this.subscriptions.get(client);
    if (previous) this.wakeCapacityWaiters(previous);
    const subscription: SyncSubscription = {
      id: message.requestId,
      requestId: message.requestId,
      batchId: `${message.requestId}:${Date.now().toString(36)}`,
      interactive: deliveryMode === "interactive",
      notificationOnly: deliveryMode === "notifications_only",
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
      fullSyncRequested: true,
      dirtyThreadKeys: new Set(),
      capacityWaiters: new Set(),
    };
    this.subscriptions.set(client, subscription);
    if (subscription.interactive || subscription.notificationOnly) {
      this.reconcileSharedContentObservers();
    }
    if (subscription.interactive) {
      this.markCatalogDirtyIfStale();
      this.scheduleSync(client, subscription, { full: true });
      this.ensureTimers();
      this.armSharedControlReconcile();
    } else if (subscription.notificationOnly) {
      this.requestSharedControlReconcile({ catalog: true, status: true });
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
    this.wakeCapacityWaiters(subscription);
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
    // WebSocket frames are ordered and Mobile serializes its SQLite writes.
    // Accept a lower value so a status-clock-bound watermark can repair a
    // previously persisted fast-phone timestamp without reconnecting.
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
    this.reconcileSharedContentObservers();
    this.sendEvent(client, subscription, {
      event: "focus_applied",
      requestId: message.requestId,
      ...(message.focused ? { focused: message.focused } : {}),
    });
    if (!message.focused) return;
    if (
      message.focused.provider === "codex" &&
      this.legacyCodexMonitoringEnabled
    ) {
      void this.ensureExternalCodexMonitor(
        message.focused.providerSessionId,
        true,
      )
        .catch((error) => {
          this.reportExternalObservationFailure(error);
        })
        .finally(() =>
          this.scheduleSync(client, subscription, {
            dirtyKeys: [targetKey(message.focused!)],
          }),
        );
      return;
    }
    this.scheduleSync(client, subscription, {
      dirtyKeys: [targetKey(message.focused)],
    });
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
    this.wakeCapacityWaiters(subscription);
    this.subscriptions.delete(client);
    if (!this.hasInteractiveClients()) {
      this.priorityCodexSettingsQueue.clear();
      this.cancelTimers();
      this.clearExternalCodexMonitoring();
      this.requestSharedCodexReadProcessClose();
    }
    this.reconcileSharedContentObservers();
  }

  private scheduleSync(
    client: object,
    subscription: SyncSubscription,
    options: {
      full?: boolean;
      dirtyKeys?: Iterable<ConversationKey>;
    } = {},
  ): void {
    if (options.full) subscription.fullSyncRequested = true;
    for (const key of options.dirtyKeys ?? []) {
      subscription.dirtyThreadKeys.add(key);
    }
    if (this.closed || !subscription.interactive || !this.clientReady(client)) {
      return;
    }
    if (subscription.syncing) {
      subscription.dirty = true;
      return;
    }
    subscription.syncing = true;
    subscription.dirty = false;
    void this.runSync(client, subscription)
      .catch((error) => {
        try {
          this.sendError(
            client,
            subscription,
            undefined,
            "sync_failed",
            errorMessage(error),
          );
        } catch {
          // A saturated or disconnected client may be unable to accept even
          // the terminal error frame. Retain recovery intent without allowing
          // this detached task to reject a second time.
          subscription.dirty = true;
        }
      })
      .finally(() => {
        subscription.syncing = false;
        if (
          subscription.dirty &&
          subscription.outbound.length === 0 &&
          subscription.outstandingBytes < MAX_UNACKED_BYTES
        ) {
          this.scheduleSync(client, subscription);
        }
      });
  }

  private async runSync(
    client: object,
    subscription: SyncSubscription,
  ): Promise<void> {
    const fullSyncRequested = subscription.fullSyncRequested;
    subscription.fullSyncRequested = false;
    const dirtyThreadKeys = new Set(subscription.dirtyThreadKeys);
    subscription.dirtyThreadKeys.clear();
    await this.refreshCatalog();
    const fullSyncOrdered = fullSyncRequested
      ? this.orderedRecords(subscription)
      : undefined;
    if (fullSyncOrdered) {
      this.enqueuePriorityCodexSettingsHydration(
        this.priorityCodexSettingsRecords(fullSyncOrdered, subscription),
      );
    }
    if (subscription.focusedKey) {
      this.prioritizeCodexSettingsHydration(subscription.focusedKey);
    }
    await this.rewarmExternalCodexMonitoringIfNeeded();
    if (
      this.closed ||
      this.subscriptions.get(client) !== subscription ||
      !subscription.interactive
    ) {
      return;
    }
    const batchId = `${subscription.id}:${Date.now().toString(36)}`;
    subscription.batchId = batchId;
    const statusState = this.statusStateForClient(client);
    const beginSequence = this.sendEvent(client, subscription, {
      event: "sync_begin",
      requestId: subscription.requestId,
      catalogState: this.catalogState,
      statusState,
    });
    if (subscription.catalogState === this.catalogState) {
      this.mergeCommit(subscription, beginSequence, {
        catalogState: this.catalogState,
      });
    }
    if (subscription.statusState === statusState) {
      this.mergeCommit(subscription, beginSequence, {
        statusState,
      });
    }
    if (!(await this.sendCatalogChanges(client, subscription))) {
      subscription.fullSyncRequested ||= fullSyncRequested;
      subscription.dirty = true;
      return;
    }
    if (!(await this.sendStatusChanges(client, subscription))) {
      subscription.fullSyncRequested ||= fullSyncRequested;
      subscription.dirty = true;
      return;
    }

    if (fullSyncRequested) {
      const ordered = fullSyncOrdered ?? this.orderedRecords(subscription);
      const priority = ordered.filter((record, index) =>
        this.isPriorityRecord(record, index, subscription),
      );
      const priorityComplete = await this.sendTimelineRecords(
        client,
        subscription,
        priority,
        "priority",
      );
      this.sendEvent(client, subscription, {
        event: "sync_checkpoint",
        phase: "priority",
        hasMore: !priorityComplete || ordered.length > priority.length,
      });
      if (!priorityComplete) {
        subscription.fullSyncRequested = true;
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
        "recent",
      );
      this.sendEvent(client, subscription, {
        event: "sync_checkpoint",
        phase: "recent",
        hasMore: !recentComplete,
      });
      if (!recentComplete) {
        subscription.fullSyncRequested = true;
        subscription.dirty = true;
        return;
      }
    } else {
      const dirtyRecords = [...dirtyThreadKeys]
        .map((key) => this.catalog.get(key))
        .filter((record): record is CatalogRecord => record !== undefined);
      const dirtyComplete = await this.sendTimelineRecords(
        client,
        subscription,
        dirtyRecords,
        "priority",
      );
      this.sendEvent(client, subscription, {
        event: "sync_checkpoint",
        phase: "priority",
        hasMore: !dirtyComplete,
      });
      this.sendEvent(client, subscription, {
        event: "sync_checkpoint",
        phase: "recent",
        hasMore: false,
      });
      if (!dirtyComplete) {
        for (const key of dirtyThreadKeys) {
          subscription.dirtyThreadKeys.add(key);
        }
        subscription.dirty = true;
        return;
      }
    }

    const desiredThreadStates = new Map(subscription.threadStates);
    for (const [key, revision] of subscription.pendingThreadStates) {
      desiredThreadStates.set(key, revision);
    }
    this.sendEvent(client, subscription, {
      event: "sync_complete",
      nextState: {
        catalogState: this.catalogState,
        statusState,
        threadContentStates: [...desiredThreadStates]
          .slice(-MAX_THREAD_STATES)
          .map(([key, revision]) => ({
            ...parseTargetKeyRequired(key),
            revision,
          })),
      },
    });
  }

  private async sendCatalogChanges(
    client: object,
    subscription: SyncSubscription,
  ): Promise<boolean> {
    if (
      subscription.catalogState === this.catalogState ||
      subscription.pendingCatalogState === this.catalogState
    ) {
      return true;
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
    const current = this.catalogProjection;
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
    for (const [pageIndex, page] of effectivePages.entries()) {
      const payload: ConversationSyncEventPayload = {
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
      };
      if (
        !(await this.waitForOutboundCapacity(client, subscription, payload))
      ) {
        return false;
      }
      const sequence = this.sendEvent(client, subscription, payload);
      if (pageIndex === effectivePages.length - 1) {
        subscription.pendingCatalogState = this.catalogState;
        this.mergeCommit(subscription, sequence, {
          catalogState: this.catalogState,
        });
      }
    }
    return true;
  }

  private async sendStatusChanges(
    client: object,
    subscription: SyncSubscription,
  ): Promise<boolean> {
    const supportsAppServerStatusSemantics = this.runtime.supports(
      client,
      APP_SERVER_STATUS_CAPABILITY,
    );
    const statusState = clientStatusState(
      this.statusState,
      supportsAppServerStatusSemantics,
    );
    if (
      subscription.statusState === statusState ||
      subscription.pendingStatusState === statusState
    ) {
      return true;
    }
    const previousState = subscription.statusState
      ? parseClientStatusState(
          subscription.statusState,
          supportsAppServerStatusSemantics,
        )
      : undefined;
    const previous = previousState?.compatible
      ? this.statusHistory.get(previousState.rawState)
      : undefined;
    if (subscription.statusState && (!previousState?.compatible || !previous)) {
      this.sendEvent(client, subscription, {
        event: "sync_reset",
        scope: "status",
        reason: "state_unavailable",
      });
    }
    const current = this.statusProjection;
    const changes = [...current]
      .filter(([key, value]) => {
        const prior = previous?.get(key);
        return (
          !prior ||
          stableJson(
            statusForClient(prior, supportsAppServerStatusSemantics),
          ) !==
            stableJson(statusForClient(value, supportsAppServerStatusSemantics))
        );
      })
      .map(([, value]) =>
        statusForClient(value, supportsAppServerStatusSemantics),
      );
    const pages = chunkByJsonBytes(changes, FRAME_CONTENT_BUDGET);
    const effectivePages = pages.length > 0 ? pages : [[]];
    for (const [pageIndex, page] of effectivePages.entries()) {
      const payload: ConversationSyncEventPayload = {
        event: "status_changes",
        statusState,
        pageIndex,
        pageCount: effectivePages.length,
        changes: page,
      };
      if (
        !(await this.waitForOutboundCapacity(client, subscription, payload))
      ) {
        return false;
      }
      const sequence = this.sendEvent(client, subscription, payload);
      if (pageIndex === effectivePages.length - 1) {
        subscription.pendingStatusState = statusState;
        this.mergeCommit(subscription, sequence, {
          statusState,
        });
      }
    }
    return true;
  }

  private statusStateForClient(client: object): string {
    return clientStatusState(
      this.statusState,
      this.runtime.supports(client, APP_SERVER_STATUS_CAPABILITY),
    );
  }

  private async sendTimelineRecords(
    client: object,
    subscription: SyncSubscription,
    records: CatalogRecord[],
    phase: "priority" | "recent" | "cold",
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
          if (known === this.timelineRevisionFor(record)) return null;
          try {
            return await this.snapshotFor(record);
          } catch (error) {
            try {
              this.sendError(
                client,
                subscription,
                undefined,
                "timeline_failed",
                errorMessage(error),
                record.entry,
              );
            } catch {
              subscription.dirty = true;
            }
            return null;
          }
        }),
      );
      for (let index = 0; index < batch.length; index += 1) {
        const snapshot = snapshots[index];
        if (!snapshot) continue;
        this.sendTimeline(
          client,
          subscription,
          batch[index]!,
          snapshot,
          phase,
          offset + index,
          records.length,
        );
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
    const requestedRevision = this.timelineRevisionFor(record);
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
    const liveAtReadStart = this.liveContentRevisions.get(key);
    const previousSnapshot = this.snapshots.get(key)?.at(-1);
    const sharedMessagesAtReadStart = this.sharedObserverLiveMessages.get(key);
    const historySource =
      target.provider === "codex" &&
      sharedMessagesAtReadStart &&
      previousSnapshot &&
      liveAtReadStart?.readScope === "direct"
        ? Promise.resolve({
            window: historyWindowFromSnapshot(previousSnapshot),
            canonicalMessages: undefined,
          })
        : target.provider === "codex" &&
            previousSnapshot &&
            liveAtReadStart?.readScope === "latestTurn"
          ? this.latestTurnHistoryReader(target).then((history) => {
              const latest = normalizeHistoryWindow(history);
              return {
                window: mergeSnapshotWithLatestTurn(previousSnapshot, latest),
                canonicalMessages: latest.messages,
              };
            })
          : this.historyReader(target).then((history) => {
              const window = normalizeHistoryWindow(history);
              return { window, canonicalMessages: window.messages };
            });
    const flight = historySource
      .then(({ window, canonicalMessages }) => {
        const externalMessages = this.externalCodexLiveMessages.get(key);
        const sharedMessages = this.sharedObserverLiveMessages.get(key);
        const externalMergedMessages = mergeExternalCodexMessages(
          window.messages,
          externalMessages?.values() ?? [],
        );
        const mergedMessages = mergeObservedMessagesReplacingStable(
          externalMergedMessages,
          sharedMessages?.values() ?? [],
        );
        const canonicalHistoryCoversExternalMessages =
          externalMessages === undefined ||
          (canonicalMessages !== undefined &&
            !this.liveContentRevisions.has(key) &&
            canonicalHistoryCoversDurableExternalMessages(
              canonicalMessages,
              externalMessages.values(),
            ));
        const canonicalHistoryCoversSharedMessages =
          sharedMessages === undefined ||
          (canonicalMessages !== undefined &&
            canonicalHistoryCoversDurableExternalMessages(
              canonicalMessages,
              sharedMessages.values(),
            ));
        const messages =
          canonicalHistoryCoversExternalMessages &&
          canonicalHistoryCoversSharedMessages
            ? window.messages
            : mergedMessages;
        for (const turn of window.turnDetails ?? []) {
          this.rememberTurnDetails(target, turn);
        }
        const built = buildConversationContentSnapshot(target, messages, {
          maxMessageTextBytes: MAX_MESSAGE_TEXT_BYTES,
          maxSnapshotBytes: MAX_TIMELINE_BYTES,
          preserveLatestRootTurnTools,
        });
        const catalogHasVisibleContent = Boolean(
          record.entry.firstPrompt?.trim() || record.entry.summary?.trim(),
        );
        const providerHistoryIndicatesContent =
          window.nextTurnCursor != null ||
          (window.turnDetails?.length ?? 0) > 0 ||
          (externalMessages?.size ?? 0) > 0 ||
          (sharedMessages?.size ?? 0) > 0;
        const catalogIndicatesPriorActivity =
          record.status.activity === "working" ||
          record.status.activity === "compacting" ||
          record.status.activity === "systemError" ||
          record.status.attention !== "none" ||
          record.status.result !== "none";
        const catalogContentMissing =
          built.entries.length === 0 &&
          (catalogHasVisibleContent ||
            providerHistoryIndicatesContent ||
            catalogIndicatesPriorActivity);
        const latestTurnGap = mergeLatestTurnGaps(
          mergeLatestTurnGaps(window.latestTurnGap, built.latestTurnGap),
          catalogContentMissing
            ? {
                missingEntryCount: 1,
                payloadOmitted: false,
                repair: "turns_page",
              }
            : undefined,
        );
        const snapshot = {
          ...built,
          revision: requestedRevision,
          hasEarlier:
            built.hasEarlier ||
            window.nextTurnCursor != null ||
            catalogContentMissing,
          turnsNextCursor: window.nextTurnCursor,
          latestTurnComplete:
            window.latestTurnComplete !== false &&
            built.latestTurnComplete &&
            latestTurnGap === undefined,
          ...(latestTurnGap ? { latestTurnGap } : {}),
        };
        // Both cases are provisional under the catalog revision: canonical
        // history can materialize later without advancing app-server recency.
        // A reconnect must reread the provider instead of pinning a blank or
        // live-only projection under that same revision.
        if (
          !catalogContentMissing &&
          canonicalHistoryCoversExternalMessages &&
          (canonicalHistoryCoversSharedMessages || sharedMessages !== undefined)
        ) {
          this.rememberSnapshot(key, snapshot);
        }
        if (
          externalMessages &&
          canonicalHistoryCoversExternalMessages &&
          this.externalCodexLiveMessages.get(key) === externalMessages &&
          !this.liveContentRevisions.has(key)
        ) {
          // Catalog recency can advance before turns/list catches up. Only
          // canonical provider history covering every buffered item proves it
          // is safe to drop the Desktop continuity buffer.
          this.deleteExternalCodexLiveMessages(key);
        }
        if (
          sharedMessages &&
          canonicalHistoryCoversSharedMessages &&
          this.sharedObserverLiveMessages.get(key) === sharedMessages
        ) {
          this.deleteSharedObserverLiveMessages(key);
        }
        const currentLive = this.liveContentRevisions.get(key);
        if (currentLive?.revision === requestedRevision) {
          // The scoped provider read (or direct stable merge) has satisfied
          // this exact revision. A later delta will promote the scope again.
          currentLive.readScope = "direct";
        }
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

  private timelineRevisionFor(record: CatalogRecord): string {
    return (
      this.liveContentRevisions.get(targetKey(record.entry))?.revision ??
      record.entry.revision
    );
  }

  private sendTimeline(
    client: object,
    subscription: SyncSubscription,
    record: CatalogRecord,
    snapshot: ConversationContentSnapshot,
    phase: "priority" | "recent" | "cold",
    timelineIndex: number,
    timelineCount: number,
  ): void {
    const key = targetKey(record.entry);
    const known = subscription.threadStates.get(key);
    const base = known
      ? this.snapshots
          .get(key)
          ?.find((candidate) => candidate.revision === known)
      : undefined;
    const sent = base
      ? this.sendTimelinePatch(
          client,
          subscription,
          base,
          snapshot,
          phase,
          timelineIndex,
          timelineCount,
        )
      : false;
    if (!sent) {
      this.sendTimelineSnapshot(
        client,
        subscription,
        snapshot,
        phase,
        timelineIndex,
        timelineCount,
      );
    }
    subscription.pendingThreadStates.set(key, snapshot.revision);
  }

  private sendTimelinePatch(
    client: object,
    subscription: SyncSubscription,
    base: ConversationContentSnapshot,
    snapshot: ConversationContentSnapshot,
    phase: "priority" | "recent" | "cold",
    timelineIndex: number,
    timelineCount: number,
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
    const pages = this.timelinePatchPages(
      subscription,
      base.revision,
      snapshot,
      upserts,
      deletes,
      phase,
      timelineIndex,
      timelineCount,
    );
    const pageCount = pages.length;
    let finalSequence = -1;
    for (let pageIndex = 0; pageIndex < pageCount; pageIndex += 1) {
      const page = pages[pageIndex]!;
      finalSequence = this.sendEvent(client, subscription, {
        event: "timeline_page",
        provider: snapshot.provider,
        providerSessionId: snapshot.providerSessionId,
        revision: snapshot.revision,
        baseRevision: base.revision,
        mode: "patch",
        phase,
        timelineIndex,
        timelineCount,
        pageIndex,
        pageCount,
        entries: page.entries.map(toWireConversationContentEntry),
        deletes: page.deletes,
        hasEarlier: snapshot.hasEarlier,
        turnsNextCursor: snapshot.turnsNextCursor,
        latestTurnComplete: snapshot.latestTurnComplete,
        latestTurnGap: snapshot.latestTurnGap,
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

  private timelinePatchPages(
    subscription: SyncSubscription,
    baseRevision: string,
    snapshot: ConversationContentSnapshot,
    entries: readonly ConversationContentSnapshotEntry[],
    deletes: readonly string[],
    phase: "priority" | "recent" | "cold",
    timelineIndex: number,
    timelineCount: number,
  ): TimelinePatchPage[] {
    const envelopeBytes = this.eventPayloadBytes(subscription, {
      event: "timeline_page",
      provider: snapshot.provider,
      providerSessionId: snapshot.providerSessionId,
      revision: snapshot.revision,
      baseRevision,
      mode: "patch",
      phase,
      timelineIndex,
      timelineCount,
      pageIndex: Number.MAX_SAFE_INTEGER,
      pageCount: Number.MAX_SAFE_INTEGER,
      entries: [],
      deletes: [],
      hasEarlier: snapshot.hasEarlier,
      turnsNextCursor: snapshot.turnsNextCursor,
      latestTurnComplete: snapshot.latestTurnComplete,
      latestTurnGap: snapshot.latestTurnGap,
      sourceEntryCount: snapshot.sourceEntryCount,
    });
    const entryBytes = entries.map((entry) =>
      Buffer.byteLength(
        JSON.stringify(toWireConversationContentEntry(entry)),
        "utf8",
      ),
    );
    const deleteBytes = deletes.map((entryId) =>
      Buffer.byteLength(JSON.stringify(entryId), "utf8"),
    );
    const pages: TimelinePatchPage[] = [];
    let entryIndex = 0;
    let deleteIndex = 0;
    while (entryIndex < entries.length || deleteIndex < deletes.length) {
      const page: TimelinePatchPage = { entries: [], deletes: [] };
      let bytes = envelopeBytes;
      while (
        entryIndex < entries.length &&
        page.entries.length < MAX_TIMELINE_PAGE_ENTRIES
      ) {
        const addition =
          (page.entries.length === 0 ? 0 : 1) + entryBytes[entryIndex]!;
        if (bytes + addition > MAX_FRAME_BYTES) break;
        page.entries.push(entries[entryIndex]!);
        bytes += addition;
        entryIndex += 1;
      }
      while (deleteIndex < deletes.length) {
        const addition =
          (page.deletes.length === 0 ? 0 : 1) + deleteBytes[deleteIndex]!;
        if (bytes + addition > MAX_FRAME_BYTES) break;
        page.deletes.push(deletes[deleteIndex]!);
        bytes += addition;
        deleteIndex += 1;
      }
      if (page.entries.length === 0 && page.deletes.length === 0) {
        throw new Error(
          "conversation_sync_v2 timeline patch item exceeds frame budget",
        );
      }
      pages.push(page);
    }
    return pages.length > 0 ? pages : [{ entries: [], deletes: [] }];
  }

  private sendTimelineSnapshot(
    client: object,
    subscription: SyncSubscription,
    snapshot: ConversationContentSnapshot,
    phase: "priority" | "recent" | "cold",
    timelineIndex: number,
    timelineCount: number,
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
        phase,
        timelineIndex,
        timelineCount,
        pageIndex,
        pageCount: effectivePages.length,
        entries: page.map(toWireConversationContentEntry),
        deletes: [],
        hasEarlier: snapshot.hasEarlier,
        turnsNextCursor: snapshot.turnsNextCursor,
        latestTurnComplete: snapshot.latestTurnComplete,
        latestTurnGap: snapshot.latestTurnGap,
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
        phase: "priority",
        timelineIndex: Number.MAX_SAFE_INTEGER,
        timelineCount: Number.MAX_SAFE_INTEGER,
        pageIndex: Number.MAX_SAFE_INTEGER,
        pageCount: Number.MAX_SAFE_INTEGER,
        entries: [],
        deletes: [],
        hasEarlier: snapshot.hasEarlier,
        turnsNextCursor: snapshot.turnsNextCursor,
        latestTurnComplete: snapshot.latestTurnComplete,
        latestTurnGap: snapshot.latestTurnGap,
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
          let entry = normalizeCatalogEntry(seed.entry);
          const key = targetKey(entry);
          const previousRecord = previousCatalog.get(key);
          if (previousRecord) {
            entry = mergeIncompleteCodexCatalogSettings(
              entry,
              previousRecord.entry,
            );
          }
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
          } else if (live?.catalogObservedAt) {
            entry = withLiveCatalogMetadata(entry, live.catalogObservedAt);
          }
          const previous = previousStatuses.get(key);
          next.set(key, {
            entry,
            status: preserveObservedAt(previous, seed.status),
          });
        }
        this.catalog = next;
        for (const key of this.focusedCodexSettingsAttempts.keys()) {
          if (!next.has(key)) this.focusedCodexSettingsAttempts.delete(key);
        }
        for (const key of this.codexSettingsHydrationEpochs.keys()) {
          if (!next.has(key)) this.codexSettingsHydrationEpochs.delete(key);
        }
        for (const key of this.codexSettingsRerunKeys) {
          if (!next.has(key)) this.codexSettingsRerunKeys.delete(key);
        }
        for (const key of this.priorityCodexSettingsQueue) {
          if (!next.has(key)) this.priorityCodexSettingsQueue.delete(key);
        }
        if (this.legacyCodexMonitoringEnabled) {
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
        } else {
          // The daemon app-server is the live authority. JSONL discovery and
          // tail monitors would duplicate that stream, spend O(rollout) I/O,
          // and can resurrect stale Desktop evidence after a newer daemon
          // status. Keep the legacy path completely dormant in this mode.
          this.clearExternalCodexMonitoring();
          this.externalCodexDiscoveredRunning.clear();
          this.pendingExternalCodexThreads.clear();
          this.externalCodexDiscoveryCompletedAt = 0;
        }
        this.applyRuntimeOverlay();
        for (const key of this.liveContentRevisions.keys()) {
          if (!this.catalog.has(key)) {
            this.liveContentRevisions.delete(key);
            this.deleteExternalCodexLiveMessages(key);
            this.deleteSharedObserverLiveMessages(key);
          }
        }
        this.recomputeStates();
        this.reconcileSharedContentObservers();
        this.catalogRefreshedAt = Date.now();
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

  private invalidateAllCodexSettingsHydration(): void {
    this.codexSettingsHydrationGeneration += 1;
    this.focusedCodexSettingsAttempts.clear();
    this.codexSettingsRerunKeys.clear();
    this.priorityCodexSettingsQueue.clear();
  }

  private invalidateCodexSettingsHydration(key: ConversationKey): void {
    this.codexSettingsHydrationEpochs.set(
      key,
      (this.codexSettingsHydrationEpochs.get(key) ?? 0) + 1,
    );
    this.focusedCodexSettingsAttempts.delete(key);
    if (this.focusedCodexSettingsFlights.has(key)) {
      this.codexSettingsRerunKeys.add(key);
    }
  }

  private hydrateFocusedCodexSettings(
    key: ConversationKey,
  ): Promise<boolean> {
    const target = parseTargetKeyRequired(key);
    if (target.provider !== "codex") return Promise.resolve(false);
    const record = this.catalog.get(key);
    if (!record) return Promise.resolve(false);
    const signature = codexCatalogSettingsObservationSignature(record.entry);
    const previousAttempt = this.focusedCodexSettingsAttempts.get(key);
    if (
      previousAttempt?.signature === signature &&
      (previousAttempt.complete ||
        Date.now() - previousAttempt.attemptedAt <
          FOCUSED_CODEX_SETTINGS_RETRY_MS)
    ) {
      return Promise.resolve(false);
    }
    const existing = this.focusedCodexSettingsFlights.get(key);
    if (existing) return existing;

    this.focusedCodexSettingsAttempts.set(key, {
      signature,
      attemptedAt: Date.now(),
      complete: false,
    });
    const hydrationGeneration = this.codexSettingsHydrationGeneration;
    const hydrationEpoch = this.codexSettingsHydrationEpochs.get(key) ?? 0;
    this.codexSettingsFlightObservations.set(key, {
      generation: hydrationGeneration,
      epoch: hydrationEpoch,
    });
    const flight = this.readCodexSettingsMetadataWithTimeout(
      target.providerSessionId,
    )
      .then((metadata) => {
        if (this.closed || !metadata?.codexSettings) return false;
        if (
          hydrationGeneration !== this.codexSettingsHydrationGeneration ||
          hydrationEpoch !== (this.codexSettingsHydrationEpochs.get(key) ?? 0)
        ) {
          return false;
        }
        const current = this.catalog.get(key);
        if (!current) return false;
        if (codexCatalogSettingsObservationSignature(current.entry) !== signature) {
          // The authoritative read started against an older catalog
          // observation. Never let its result overwrite a newer revision;
          // schedule one focused retry after this flight releases its slot.
          this.focusedCodexSettingsAttempts.delete(key);
          this.codexSettingsRerunKeys.add(key);
          this.scheduleInteractiveClients({ dirtyKeys: [key] });
          return false;
        }
        const nextEntry = replaceCodexCatalogSettings(
          current.entry,
          metadata.codexSettings,
        );
        const changed = stableJson(nextEntry) !== stableJson(current.entry);
        if (changed) {
          current.entry = nextEntry;
          this.recomputeStates([key]);
        }
        this.focusedCodexSettingsAttempts.set(key, {
          signature: codexCatalogSettingsObservationSignature(current.entry),
          attemptedAt: Date.now(),
          complete: true,
        });
        return changed;
      })
      .catch((error) => {
        const kind = error instanceof Error ? error.name : typeof error;
        console.warn(
          `[conversation-sync-v2] Codex settings unavailable (${kind})`,
        );
        return false;
      })
      .finally(() => {
        if (this.focusedCodexSettingsFlights.get(key) === flight) {
          this.focusedCodexSettingsFlights.delete(key);
          this.codexSettingsFlightObservations.delete(key);
        }
        if (this.codexSettingsRerunKeys.delete(key)) {
          this.prioritizeCodexSettingsHydration(key);
        }
      });
    this.focusedCodexSettingsFlights.set(key, flight);
    return flight;
  }

  private readCodexSettingsMetadataWithTimeout(
    threadId: string,
  ): Promise<CodexSessionIndexMetadata | undefined> {
    let timeout: ReturnType<typeof setTimeout> | undefined;
    const timedOut = new Promise<never>((_, reject) => {
      timeout = setTimeout(() => {
        reject(
          new Error(
            `Codex settings hydration timed out after ${this.codexSettingsHydrationTimeoutMs}ms`,
          ),
        );
      }, this.codexSettingsHydrationTimeoutMs);
      timeout.unref?.();
    });
    return Promise.race([
      this.focusedCodexMetadataReader(threadId),
      timedOut,
    ]).finally(() => {
      if (timeout) clearTimeout(timeout);
    });
  }

  private priorityCodexSettingsRecords(
    ordered: readonly CatalogRecord[],
    subscription: SyncSubscription,
  ): CatalogRecord[] {
    const selected = new Map<ConversationKey, CatalogRecord>();
    const add = (record: CatalogRecord | undefined): void => {
      if (!record || record.entry.provider !== "codex") return;
      if (record.entry.codexSettingsSnapshotComplete === true) return;
      selected.set(targetKey(record.entry), record);
    };
    if (subscription.focusedKey) {
      add(this.catalog.get(subscription.focusedKey));
    }
    const recent = [...ordered]
      .filter((record) => record.entry.provider === "codex")
      .sort((left, right) =>
        right.entry.recencyAt.localeCompare(left.entry.recencyAt),
      )
      .slice(0, PRIORITY_RECENT_COUNT);
    for (const record of recent) add(record);
    for (const record of ordered) {
      if (selected.size >= MAX_PENDING_PRIORITY_CODEX_SETTINGS) break;
      if (this.isSpecial(record, subscription)) add(record);
    }
    return [...selected.values()];
  }

  private enqueuePriorityCodexSettingsForInteractiveClients(): void {
    for (const subscription of this.subscriptions.values()) {
      if (!subscription.interactive) continue;
      const ordered = this.orderedRecords(subscription);
      this.enqueuePriorityCodexSettingsHydration(
        this.priorityCodexSettingsRecords(ordered, subscription),
      );
      if (subscription.focusedKey) {
        this.prioritizeCodexSettingsHydration(subscription.focusedKey);
      }
    }
  }

  private enqueuePriorityCodexSettingsHydration(
    records: readonly CatalogRecord[],
  ): void {
    for (const record of records) {
      if (record.entry.provider !== "codex") continue;
      const key = targetKey(record.entry);
      if (
        this.priorityCodexSettingsQueue.has(key)
      ) {
        continue;
      }
      if (this.focusedCodexSettingsFlights.has(key)) {
        if (this.isCodexSettingsFlightInvalidated(key)) {
          this.codexSettingsRerunKeys.add(key);
        }
        continue;
      }
      if (
        this.priorityCodexSettingsQueue.size >=
        MAX_PENDING_PRIORITY_CODEX_SETTINGS
      ) {
        break;
      }
      this.priorityCodexSettingsQueue.add(key);
    }
    this.drainPriorityCodexSettingsHydration();
  }

  private prioritizeCodexSettingsHydration(key: ConversationKey): void {
    if (!this.hasInteractiveClients()) return;
    if (this.focusedCodexSettingsFlights.has(key)) {
      if (this.isCodexSettingsFlightInvalidated(key)) {
        this.codexSettingsRerunKeys.add(key);
      }
      return;
    }
    const pending = [...this.priorityCodexSettingsQueue].filter(
      (candidate) => candidate !== key,
    );
    this.priorityCodexSettingsQueue.clear();
    this.priorityCodexSettingsQueue.add(key);
    for (const candidate of pending) {
      if (
        this.priorityCodexSettingsQueue.size >=
        MAX_PENDING_PRIORITY_CODEX_SETTINGS
      ) {
        break;
      }
      this.priorityCodexSettingsQueue.add(candidate);
    }
    this.drainPriorityCodexSettingsHydration();
  }

  private isCodexSettingsFlightInvalidated(key: ConversationKey): boolean {
    const observation = this.codexSettingsFlightObservations.get(key);
    return (
      observation == null ||
      observation.generation !== this.codexSettingsHydrationGeneration ||
      observation.epoch !== (this.codexSettingsHydrationEpochs.get(key) ?? 0)
    );
  }

  private drainPriorityCodexSettingsHydration(): void {
    while (
      !this.closed &&
      this.hasInteractiveClients() &&
      this.activePriorityCodexSettings <
        PRIORITY_CODEX_SETTINGS_CONCURRENCY &&
      this.priorityCodexSettingsQueue.size > 0
    ) {
      const key = this.priorityCodexSettingsQueue.values().next().value as
        | ConversationKey
        | undefined;
      if (!key) return;
      this.priorityCodexSettingsQueue.delete(key);
      if (!this.catalog.has(key)) continue;
      this.activePriorityCodexSettings += 1;
      void this.hydrateFocusedCodexSettings(key)
        .then((changed) => {
          if (changed && !this.closed) {
            this.scheduleInteractiveClients({ dirtyKeys: [key] });
          }
        })
        .finally(() => {
          this.activePriorityCodexSettings = Math.max(
            0,
            this.activePriorityCodexSettings - 1,
          );
          this.drainPriorityCodexSettingsHydration();
        });
    }
  }

  private markCatalogDirtyIfStale(): void {
    if (
      this.catalogRefreshedAt === 0 ||
      Date.now() - this.catalogRefreshedAt >= CATALOG_CONNECTION_REUSE_MS
    ) {
      this.catalogDirty = true;
    }
  }

  private async rewarmExternalCodexMonitoringIfNeeded(): Promise<void> {
    if (
      this.closed ||
      !this.legacyCodexMonitoringEnabled ||
      !this.hasInteractiveClients() ||
      this.externalCodexMonitors.size > 0 ||
      this.externalCodexMonitorFlights.size > 0
    ) {
      return;
    }
    const codexRecords = [...this.catalog.values()].filter(
      (record) => record.entry.provider === "codex",
    );
    const catalogThreadIds = new Set(
      codexRecords.map((record) => record.entry.providerSessionId),
    );
    const threadIds = [
      ...[...this.externalCodexDiscoveredRunning.keys()].filter((threadId) =>
        catalogThreadIds.has(threadId),
      ),
      ...codexRecords
        .slice(0, this.initialExternalCodexMonitors)
        .map((record) => record.entry.providerSessionId),
    ];
    if (threadIds.length === 0) return;
    await this.ensureExternalCodexMonitors(threadIds);
    const changedKeys = new Set(
      threadIds.map((threadId) =>
        targetKey({ provider: "codex", providerSessionId: threadId }),
      ),
    );
    this.applyRuntimeOverlay(changedKeys);
    this.recomputeStates(changedKeys);
  }

  private refreshStatuses(): Promise<void> {
    if (this.statusFlight) return this.statusFlight;
    const flight = (async () => {
      // Freeze the authority inputs before awaiting app-server I/O. A shallow
      // Map copy would still share CatalogRecord objects, so a live runtime
      // event arriving during the read could mutate the supposed baseline and
      // defeat the late-generation fence below.
      const catalogAtReadStart = new Map(
        [...this.catalog].map(([key, record]) => [
          key,
          {
            entry: { ...record.entry },
            status: { ...record.status },
          },
        ]),
      );
      const sharedControlGenerationAtReadStart = this.sharedControlGeneration;
      const sharedControlSequenceAtReadStart = this.sharedControlLastSequence;
      let statusReadFailed = false;
      let statusReadError: unknown;
      try {
        const providerStatuses = await this.statusReader(catalogAtReadStart);
        if (this.closed) return;
        this.mergeProviderStatusSnapshot(
          catalogAtReadStart,
          providerStatuses,
          sharedControlGenerationAtReadStart,
          sharedControlSequenceAtReadStart,
        );
      } catch (error) {
        statusReadFailed = true;
        statusReadError = error;
        if (this.closed) return;
        this.markProviderStatusReadUnavailable(
          catalogAtReadStart,
          sharedControlGenerationAtReadStart,
          sharedControlSequenceAtReadStart,
        );
      }

      if (this.legacyCodexMonitoringEnabled) {
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
      }
      if (this.closed) return;
      // Runtime evidence is intentionally applied after the provider read.
      // This keeps a Bridge-owned live turn authoritative without allowing a
      // late watchdog result to overwrite it.
      this.applyRuntimeOverlay();
      this.recomputeStates();
      this.reconcileSharedContentObservers();
      for (const [client, subscription] of this.subscriptions) {
        if (subscription.interactive) this.scheduleSync(client, subscription);
      }
      if (statusReadFailed) throw statusReadError;
    })().finally(() => {
      if (this.statusFlight === flight) this.statusFlight = undefined;
    });
    this.statusFlight = flight;
    return flight;
  }

  private mergeProviderStatusSnapshot(
    catalogAtReadStart: ReadonlyMap<ConversationKey, CatalogRecord>,
    providerStatuses: ReadonlyMap<ConversationKey, ConversationSyncStatus>,
    sharedControlGenerationAtReadStart: number,
    sharedControlSequenceAtReadStart: number,
  ): void {
    const completedAt = new Date().toISOString();
    const sharedAuthorityStillCurrent = this.sharedControlReadStillCurrent(
      sharedControlGenerationAtReadStart,
      sharedControlSequenceAtReadStart,
    );
    for (const [key, startedRecord] of catalogAtReadStart) {
      if (startedRecord.entry.provider !== "codex") continue;
      const record = this.catalog.get(key);
      if (!record) continue;
      const candidate = providerStatuses.get(key);
      if (!candidate) {
        if (
          statusChangedSinceReadStarted(startedRecord.status, record.status)
        ) {
          continue;
        }
        const unavailable = unavailableProviderStatus(
          record.status,
          completedAt,
        );
        record.status = unavailable;
        if (sharedAuthorityStillCurrent) {
          this.rememberSharedRuntimeStatus(key, unavailable);
        }
        continue;
      }
      if (targetKey(candidate) !== key) continue;
      let normalized = validIso(candidate.observedAt)
        ? candidate
        : { ...candidate, observedAt: completedAt };
      if (sharedAuthorityStillCurrent) {
        normalized = sharedControlProviderSnapshotStatus(
          normalized,
          sharedControlAuthorityGeneration(this.sharedControlGeneration),
        );
        if (
          normalized.activity === "working" ||
          normalized.activity === "compacting"
        ) {
          normalized = {
            ...normalized,
            executionHost: this.hasActiveBridgeOwnedCodexRuntime(
              normalized.providerSessionId,
              normalized.activeTurnId,
            )
              ? "bridge"
              : "desktopAppServer",
          };
        }
      }
      if (
        !providerStatusReadMayReplace(
          startedRecord.status,
          record.status,
          normalized,
        )
      ) {
        continue;
      }
      record.status = preserveObservedAt(record.status, normalized);
      if (sharedAuthorityStillCurrent) {
        this.rememberSharedRuntimeStatus(key, normalized);
      }
    }
  }

  private markProviderStatusReadUnavailable(
    catalogAtReadStart: ReadonlyMap<ConversationKey, CatalogRecord>,
    sharedControlGenerationAtReadStart: number,
    sharedControlSequenceAtReadStart: number,
  ): void {
    const observedAt = new Date().toISOString();
    const sharedAuthorityStillCurrent = this.sharedControlReadStillCurrent(
      sharedControlGenerationAtReadStart,
      sharedControlSequenceAtReadStart,
    );
    for (const [key, startedRecord] of catalogAtReadStart) {
      if (startedRecord.entry.provider !== "codex") continue;
      const record = this.catalog.get(key);
      if (
        !record ||
        statusChangedSinceReadStarted(startedRecord.status, record.status)
      ) {
        continue;
      }
      const unavailable = unavailableProviderStatus(record.status, observedAt);
      record.status = unavailable;
      if (sharedAuthorityStillCurrent) {
        this.rememberSharedRuntimeStatus(key, unavailable);
      }
    }
  }

  private sharedControlReadStillCurrent(
    generation: number,
    sequence: number,
  ): boolean {
    return (
      this.runtime.subscribeSharedRuntimeControl !== undefined &&
      this.sharedControlReady &&
      this.sharedControlGeneration === generation &&
      this.sharedControlLastSequence === sequence
    );
  }

  private async readRecentConversationHistory(
    target: ConversationSyncTarget,
    request?: ConversationHistoryReadRequest,
  ): Promise<ConversationHistoryWindow> {
    if (target.provider === "claude") {
      return readRecentClaudeConversationHistory(target, request);
    }
    if (target.provider !== "codex") {
      throw boundedLegacyPageUnavailable(target.provider);
    }
    if (request) throw boundedLegacyPageUnavailable(target.provider);
    try {
      return await this.withSharedCodexReadProcess((process) =>
        readRecentCodexConversationHistory(
          process,
          target,
          this.desktopToolTimelineReader,
        ),
      );
    } catch (error) {
      if (!isUnsupportedAppServerRead(error)) throw error;
      throw boundedLegacyPageUnavailable(target.provider);
    }
  }

  private async readLatestCodexConversationHistory(
    target: ConversationSyncTarget,
  ): Promise<ConversationHistoryWindow> {
    if (target.provider !== "codex") {
      throw boundedLegacyPageUnavailable(target.provider);
    }
    return this.withSharedCodexReadProcess((process) =>
      readLatestCodexTurnHistory(process, target),
    );
  }

  private async readSharedControlRecoverySnapshot(
    target: ConversationSyncTarget,
    signal: AbortSignal,
  ): Promise<SharedControlRecoverySnapshot | null> {
    if (target.provider !== "codex") return null;
    return this.withSharedCodexReadProcess(async (process) => {
      const page = await process.listThreadTurns(
        {
          threadId: target.providerSessionId,
          limit: 1,
          sortDirection: "desc",
          itemsView: "summary",
        },
        {
          signal,
          timeoutMs: this.sharedControlRecoveryTimeoutMs,
        },
      );
      const raw = page.data[0];
      if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
      const turn = raw as Record<string, unknown>;
      return {
        ...(typeof turn.id === "string" && turn.id.trim()
          ? { turnId: turn.id.trim() }
          : {}),
        status: sharedRecoveryTurnStatus(turn.status),
        ...(providerTimestampToIso(turn.completedAt ?? turn.updatedAt)
          ? {
              observedAt: providerTimestampToIso(
                turn.completedAt ?? turn.updatedAt,
              ),
            }
          : {}),
      };
    });
  }

  private async reconcileSharedControlRecoveryTargets(
    connectionGeneration: number,
  ): Promise<void> {
    const current = this.sharedControlRecoveryFlight;
    if (current?.connectionGeneration === connectionGeneration) {
      return current.promise;
    }
    if (current) this.cancelSharedControlRecovery();

    const abortController = new AbortController();
    this.sharedControlRecoveryAbort = abortController;
    const entries = [...this.sharedControlRecoveryTargets.entries()].slice(
      0,
      MAX_SHARED_CONTROL_RECOVERY_THREADS,
    );
    let nextEntry = 0;
    const runWorker = async (): Promise<void> => {
      while (nextEntry < entries.length) {
        if (!this.isSharedControlRecoveryCurrent(connectionGeneration)) return;
        const entry = entries[nextEntry++];
        if (!entry) return;
        await this.reconcileSharedControlRecoveryTarget(
          entry,
          connectionGeneration,
          abortController.signal,
        );
      }
    };
    const promise = Promise.all(
      Array.from(
        {
          length: Math.min(
            this.maxConcurrentSharedControlRecoveries,
            entries.length,
          ),
        },
        () => runWorker(),
      ),
    )
      .then(() => undefined)
      .finally(() => {
        if (this.sharedControlRecoveryFlight?.promise === promise) {
          this.sharedControlRecoveryFlight = undefined;
        }
        if (this.sharedControlRecoveryAbort === abortController) {
          this.sharedControlRecoveryAbort = undefined;
        }
        if (!this.hasInteractiveClients()) {
          this.requestSharedCodexReadProcessClose();
        }
      });
    this.sharedControlRecoveryFlight = {
      connectionGeneration,
      promise,
    };
    return promise;
  }

  private async reconcileSharedControlRecoveryTarget(
    [key, recovery]: readonly [ConversationKey, SharedControlRecoveryTarget],
    connectionGeneration: number,
    generationSignal: AbortSignal,
  ): Promise<void> {
    try {
      const snapshot = await this.readSharedControlRecoveryWithTimeout(
        recovery.target,
        generationSignal,
      );
      if (
        !snapshot ||
        !this.isSharedControlRecoveryTargetCurrent(
          key,
          recovery,
          connectionGeneration,
        )
      ) {
        return;
      }
      const observedAt =
        snapshot.observedAt && validIso(snapshot.observedAt)
          ? snapshot.observedAt
          : new Date().toISOString();
      const current =
        this.sharedRuntimeStatuses.get(key) ??
        this.catalog.get(key)?.status ??
        recovery.lastKnown;
      const status = snapshot.status ?? "unknown";
      const terminalResult =
        status === "completed"
          ? "completed"
          : status === "failed"
            ? "failed"
            : undefined;
      const next: ConversationSyncStatus = {
        ...current,
        activity:
          status === "inProgress"
            ? "working"
            : status === "failed"
              ? "systemError"
              : status === "completed" || status === "interrupted"
                ? "idle"
                : recovery.lastKnown.activity,
        attention: status === "inProgress" ? current.attention : "none",
        result:
          status === "inProgress" ? "none" : (terminalResult ?? current.result),
        runtimeAttachment: "loaded",
        source: "appServer",
        confidence: status === "unknown" ? "unknown" : "authoritative",
        observedAt,
        executionHost: current.executionHost ?? "unknown",
        controlState: "readOnly",
        authorityGeneration:
          sharedControlAuthorityGeneration(connectionGeneration),
        ...(status === "inProgress" && snapshot.turnId
          ? { activeTurnId: snapshot.turnId }
          : {}),
      };
      if (status !== "inProgress") {
        delete next.activeTurnId;
        delete next.attentionRequestId;
      }
      if (status === "inProgress") {
        // A newly authoritative active turn supersedes any terminal result
        // restored for an older turn. Clear the durable slot before publishing
        // so a reconnect cannot briefly resurrect a false completion/unread.
        this.clearTerminalResult(recovery.target, observedAt, snapshot.turnId);
      }
      this.rememberSharedRuntimeStatus(key, next);
      if (terminalResult) {
        this.setTerminalResult(
          recovery.target,
          terminalResult,
          observedAt,
          snapshot.turnId,
        );
      }
      if (
        terminalResult ||
        (snapshot.turnId && snapshot.turnId !== recovery.lastKnown.activeTurnId)
      ) {
        this.rememberLiveContent(recovery.target, observedAt);
      }
      this.sharedControlRecoveryTargets.delete(key);
      this.publishSharedControlChanges(new Set([key]));
      this.reconcileSharedContentObservers();
    } catch (error) {
      if (
        generationSignal.aborted ||
        !this.isSharedControlRecoveryTargetCurrent(
          key,
          recovery,
          connectionGeneration,
        )
      ) {
        return;
      }
      // One bounded thread read may fail independently. Keep its last-known
      // business state stale and fail mutations closed instead of clearing it
      // or expanding the repair into a full catalog/history scan.
      const stale = sharedControlTransitionStatus(
        recovery.lastKnown,
        "unavailable",
        connectionGeneration,
      );
      this.rememberSharedRuntimeStatus(key, stale);
      this.publishSharedControlChanges(new Set([key]));
      this.reconcileSharedContentObservers();
      this.reportBackgroundError("control_scoped_recovery_failed", error);
    }
  }

  private readSharedControlRecoveryWithTimeout(
    target: ConversationSyncTarget,
    generationSignal: AbortSignal,
  ): Promise<SharedControlRecoverySnapshot | null> {
    const controller = new AbortController();
    const abortFromGeneration = () =>
      controller.abort(
        generationSignal.reason ??
          new Error("Shared control recovery generation changed"),
      );
    if (generationSignal.aborted) abortFromGeneration();
    else {
      generationSignal.addEventListener("abort", abortFromGeneration, {
        once: true,
      });
    }
    const timeout = setTimeout(() => {
      controller.abort(
        new Error(
          `Shared control recovery timed out after ${this.sharedControlRecoveryTimeoutMs}ms`,
        ),
      );
    }, this.sharedControlRecoveryTimeoutMs);
    timeout.unref?.();
    const aborted = new Promise<never>((_, reject) => {
      const rejectAbort = () =>
        reject(
          controller.signal.reason instanceof Error
            ? controller.signal.reason
            : new Error("Shared control recovery aborted"),
        );
      if (controller.signal.aborted) rejectAbort();
      else {
        controller.signal.addEventListener("abort", rejectAbort, {
          once: true,
        });
      }
    });
    return Promise.race([
      this.sharedControlRecoveryReader(target, controller.signal),
      aborted,
    ]).finally(() => {
      clearTimeout(timeout);
      generationSignal.removeEventListener("abort", abortFromGeneration);
    });
  }

  private isSharedControlRecoveryCurrent(
    connectionGeneration: number,
  ): boolean {
    return (
      !this.closed &&
      this.sharedControlReady &&
      this.sharedControlGeneration === connectionGeneration &&
      this.sharedControlRecoveryAbort?.signal.aborted !== true
    );
  }

  private isSharedControlRecoveryTargetCurrent(
    key: ConversationKey,
    recovery: SharedControlRecoveryTarget,
    connectionGeneration: number,
  ): boolean {
    return (
      this.isSharedControlRecoveryCurrent(connectionGeneration) &&
      this.sharedControlRecoveryTargets.get(key) === recovery
    );
  }

  private cancelSharedControlRecovery(): void {
    this.sharedControlRecoveryAbort?.abort(
      new Error("Shared control recovery generation changed"),
    );
    this.sharedControlRecoveryAbort = undefined;
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
    if (!this.legacyCodexMonitoringEnabled) {
      return { completed: true, running: [] };
    }
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
    if (!this.legacyCodexMonitoringEnabled) return;
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
      !this.legacyCodexMonitoringEnabled ||
      this.closed ||
      !this.hasInteractiveClients() ||
      this.hasActiveBridgeOwnedCodexRuntime(threadId)
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
        this.hasActiveBridgeOwnedCodexRuntime(threadId) ||
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
      let contentChanged = false;
      if (event.state === "running") {
        this.clearTerminalResult(target, observedAt, event.turnId);
      } else if (event.outcome) {
        this.setTerminalResult(
          target,
          event.outcome === "completed" ? "completed" : "failed",
          observedAt,
          event.turnId,
        );
        this.rememberLiveContent(target, observedAt);
        contentChanged = true;
      }
      const changedKeys = new Set([key]);
      this.applyRuntimeOverlay(changedKeys);
      this.recomputeStates(changedKeys);
      this.scheduleInteractiveClients(
        contentChanged ? { dirtyKeys: changedKeys } : undefined,
      );
      return;
    }

    this.rememberExternalCodexMessage(target, event, observedAt);
    if (event.message.type === "result") {
      const terminal = terminalResultFromServerMessage(event.message);
      if (terminal) {
        this.setTerminalResult(target, terminal, observedAt, event.turnId);
      }
    } else if (event.message.type === "user_input") {
      this.clearTerminalResult(target, observedAt, event.turnId);
    }
    if (isStreamingConversationDelta(event.message)) {
      this.queueLiveContent(target, observedAt);
    } else if (isConversationTimelineMessage(event.message)) {
      this.publishLiveContent(
        target,
        observedAt,
        assistantTextCatalogActivity(event.message, observedAt),
      );
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
    const changedKeys = new Set([key]);
    this.applyRuntimeOverlay(changedKeys);
    this.recomputeStates(changedKeys);
    this.scheduleInteractiveClients();
  }

  private rememberExternalCodexMessage(
    target: ConversationSyncTarget,
    event: Extract<CodexDesktopContinuityMonitorEvent, { kind: "message" }>,
    observedAt: string,
  ): void {
    const key = targetKey(target);
    const providerTimestamp =
      event.timestamp && validIso(event.timestamp)
        ? event.timestamp
        : undefined;
    const message = withSourceTimestamp(
      event.message,
      providerTimestamp ?? observedAt,
      providerTimestamp !== undefined,
    );
    const bytes = Buffer.byteLength(stableJson(message), "utf8");
    if (bytes > MAX_EXTERNAL_LIVE_BYTES_PER_THREAD) return;
    const messages =
      this.externalCodexLiveMessages.get(key) ??
      new Map<string, ExternalCodexLiveMessage>();
    let totalBytes = this.externalCodexLiveBytes.get(key) ?? 0;
    const previous = messages.get(event.itemKey);
    if (previous) totalBytes = Math.max(0, totalBytes - previous.bytes);
    // Map#set replaces an existing value without changing insertion order.
    // Deleting first moved a streamed item to the end on every delta and made
    // the Mobile timeline jump even though the provider item identity did not
    // change.
    messages.set(event.itemKey, {
      message,
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

  private hasActiveBridgeOwnedCodexRuntime(
    threadId: string,
    expectedTurnId?: string,
  ): boolean {
    return (this.runtime.listRuntimeConversationStates?.() ?? []).some(
      (state) =>
        state.provider === "codex" &&
        state.providerSessionId === threadId &&
        (!expectedTurnId || state.activeTurnId === expectedTurnId) &&
        this.runtimeStateClaimsBridgeOwnership(state) &&
        (state.processStatus !== "idle" ||
          state.pendingAttention !== undefined),
    );
  }

  private runtimeStateClaimsBridgeOwnership(
    state: LocalFeatureRuntimeConversationState,
  ): boolean {
    if (state.executionHost !== undefined) {
      return state.executionHost === "bridge";
    }
    // Private mode predates the explicit authority fields and its runtime
    // states are still local by construction. The daemon shares app-server
    // state with Desktop, so absence there must remain unknown rather than be
    // silently promoted to Bridge ownership.
    return this.legacyCodexMonitoringEnabled;
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

  private applyRuntimeOverlay(onlyKeys?: ReadonlySet<ConversationKey>): void {
    this.applyCodexActionBrokerOverlay(onlyKeys);
    for (const [key, status] of this.externalCodexStatuses) {
      if (onlyKeys && !onlyKeys.has(key)) continue;
      const record = this.catalog.get(key);
      if (!record) continue;
      if (!externalStatusMayOverride(record.status, status)) continue;
      record.status = preserveObservedAt(record.status, status);
    }
    for (const [key, status] of this.sharedRuntimeStatuses) {
      if (onlyKeys && !onlyKeys.has(key)) continue;
      const record = this.catalog.get(key);
      if (!record) continue;
      record.status = preserveObservedAt(record.status, status);
    }
    const runtimeStates = this.runtime.listRuntimeConversationStates?.() ?? [];
    for (const runtimeState of runtimeStates) {
      const target = targetFromRuntime(runtimeState);
      if (!target) continue;
      const key = targetKey(target);
      if (onlyKeys && !onlyKeys.has(key)) continue;
      if (
        target.provider === "codex" &&
        this.daemonMode &&
        !hasExplicitRuntimeAuthority(runtimeState)
      ) {
        // A daemon-backed adoption can describe a Desktop turn. Without an
        // explicit execution host/control generation this is not evidence
        // that Bridge owns or can steer the turn, so retain the app-server
        // status instead of manufacturing Bridge authority.
        continue;
      }
      const activeBridgeOwnedCodexRuntime =
        target.provider === "codex" &&
        this.runtimeStateClaimsBridgeOwnership(runtimeState) &&
        (runtimeState.processStatus !== "idle" ||
          runtimeState.pendingAttention !== undefined);
      if (activeBridgeOwnedCodexRuntime) {
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
      if (
        activeBridgeOwnedCodexRuntime &&
        runtimeStatus.activity === "working"
      ) {
        this.clearTerminalResult(
          target,
          runtimeStatus.observedAt,
          runtimeStatus.activeTurnId,
        );
      }
      if (
        !activeBridgeOwnedCodexRuntime &&
        trustedProviderActivitySurvivesPassiveRuntime(
          record.status,
          runtimeStatus,
        )
      ) {
        // A passive Bridge attachment is not evidence that a different
        // app-server or Desktop-owned turn stopped. Preserve the stronger
        // provider observation until that provider emits its own terminal
        // state. Structurally active Bridge runtimes still take precedence
        // through activeBridgeOwnedCodexRuntime above.
        continue;
      }
      record.status = runtimeStatus;
    }
    for (const [key, result] of this.resultLedger) {
      if (onlyKeys && !onlyKeys.has(key)) continue;
      const record = this.catalog.get(key);
      if (!record) continue;
      if (
        record.status.activity === "working" ||
        record.status.activity === "compacting" ||
        (record.status.activeTurnId !== undefined &&
          result.turnId !== undefined &&
          record.status.activeTurnId !== result.turnId)
      ) {
        // A terminal result belongs to a particular completed turn. It must
        // never overlay a newer authoritative active turn, even when the
        // result was restored from disk before runtime recovery completed.
        continue;
      }
      record.status = {
        ...record.status,
        result: result.result,
        // Result time is the provider terminal event time, not the later
        // catalog/restart observation time. Turn identity above prevents an
        // older terminal result from overlaying a newer active turn.
        observedAt: result.observedAt,
      };
    }
  }

  private recomputeStates(keys?: Iterable<ConversationKey>): void {
    if (!keys) {
      const catalog = catalogEntries(this.catalog);
      const statuses = statusEntries(this.catalog);
      const catalogState = hashState([...catalog].sort(compareStateEntries));
      const statusState = hashState([
        STATUS_STATE_SCHEMA_VERSION,
        ...[...statuses].sort(compareStateEntries),
      ]);
      this.catalogProjection = catalog;
      this.statusProjection = statuses;
      const nextBackgroundActiveKeys = new Set(
        [...statuses]
          .filter(([, status]) => statusNeedsBackgroundDelivery(status))
          .map(([key]) => key),
      );
      const backgroundActivityChanged = !sameStringSet(
        this.backgroundActiveKeys,
        nextBackgroundActiveKeys,
      );
      this.backgroundActiveKeys = nextBackgroundActiveKeys;
      if (
        catalogState !== this.catalogState ||
        !this.catalogHistory.has(catalogState)
      ) {
        this.catalogState = catalogState;
        rememberState(this.catalogHistory, this.catalogState, catalog);
      }
      if (
        statusState !== this.statusState ||
        !this.statusHistory.has(statusState)
      ) {
        this.statusState = statusState;
        rememberState(this.statusHistory, this.statusState, statuses);
      }
      if (backgroundActivityChanged) {
        this.runtime.notifyBackgroundActivityChanged?.();
      }
      return;
    }

    const catalogChanges: Array<
      readonly [ConversationKey, ConversationSyncCatalogEntry | null]
    > = [];
    const statusChanges: Array<
      readonly [ConversationKey, ConversationSyncStatus | null]
    > = [];
    let backgroundActivityChanged = false;
    for (const key of new Set(keys)) {
      const record = this.catalog.get(key);
      const nextCatalog = record?.entry;
      const previousCatalog = this.catalogProjection.get(key);
      if (
        (nextCatalog === undefined) !== (previousCatalog === undefined) ||
        (nextCatalog !== undefined &&
          stableJson(nextCatalog) !== stableJson(previousCatalog))
      ) {
        if (nextCatalog) {
          this.catalogProjection.set(key, nextCatalog);
        } else {
          this.catalogProjection.delete(key);
        }
        catalogChanges.push([key, nextCatalog ?? null]);
      }

      const nextStatus = record?.status;
      const previousStatus = this.statusProjection.get(key);
      const wasBackgroundActive = this.backgroundActiveKeys.has(key);
      const isBackgroundActive =
        nextStatus !== undefined && statusNeedsBackgroundDelivery(nextStatus);
      if (wasBackgroundActive !== isBackgroundActive) {
        backgroundActivityChanged = true;
        if (isBackgroundActive) {
          this.backgroundActiveKeys.add(key);
        } else {
          this.backgroundActiveKeys.delete(key);
        }
      }
      if (
        (nextStatus === undefined) !== (previousStatus === undefined) ||
        (nextStatus !== undefined &&
          stableJson(nextStatus) !== stableJson(previousStatus))
      ) {
        if (nextStatus) {
          this.statusProjection.set(key, nextStatus);
        } else {
          this.statusProjection.delete(key);
        }
        statusChanges.push([key, nextStatus ?? null]);
      }
    }
    if (catalogChanges.length > 0) {
      this.catalogState = hashState([
        "catalog-delta-v1",
        this.catalogState,
        ...catalogChanges.sort(compareStateEntries),
      ]);
      rememberState(
        this.catalogHistory,
        this.catalogState,
        this.catalogProjection,
      );
    }
    if (statusChanges.length > 0) {
      this.statusState = hashState([
        STATUS_STATE_SCHEMA_VERSION,
        "status-delta-v1",
        this.statusState,
        ...statusChanges.sort(compareStateEntries),
      ]);
      rememberState(
        this.statusHistory,
        this.statusState,
        this.statusProjection,
      );
    }
    if (backgroundActivityChanged) {
      this.runtime.notifyBackgroundActivityChanged?.();
    }
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
    if (!this.usesSharedControlStatusStream() && !this.watchdogTimer) {
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
        void this.runColdReconcile()
          .catch((error) => {
            this.reportBackgroundError("cold_reconcile_failed", error);
          })
          .finally(() => this.ensureTimers());
      }, this.coldReconcileMs + jitter);
      this.coldTimer.unref?.();
    }
  }

  private usesSharedControlStatusStream(): boolean {
    return (
      this.daemonMode &&
      this.runtime.subscribeSharedRuntimeControl !== undefined
    );
  }

  private async runColdReconcile(): Promise<void> {
    this.catalogDirty = true;
    await this.refreshCatalog();
    // A cold pass is the bounded repair path for a control event lost before
    // Bridge observed it. Unlike the five-second private watchdog, this full
    // status snapshot runs only on the long cold cadence (and only while the
    // shared control generation is ready).
    if (this.usesSharedControlStatusStream() && this.sharedControlReady) {
      await this.refreshStatuses();
    }
    this.scheduleInteractiveClients({ full: true });
  }

  private cancelTimers(): void {
    if (this.watchdogTimer) clearTimeout(this.watchdogTimer);
    if (this.coldTimer) clearTimeout(this.coldTimer);
    if (this.liveContentTimer) clearTimeout(this.liveContentTimer);
    this.clearSharedControlReconcileTimer();
    this.watchdogTimer = undefined;
    this.coldTimer = undefined;
    this.liveContentTimer = undefined;
    this.liveContentBatchStartedAt = undefined;
  }

  private queueLiveContent(
    target: ConversationSyncTarget,
    observedAt: string,
    readScope: LiveContentRevision["readScope"] = "recent",
  ): void {
    const key = targetKey(target);
    const pending = this.pendingLiveContent.get(key);
    this.pendingLiveContent.set(key, {
      target,
      observedAt: pending
        ? laterIso(pending.observedAt, observedAt)
        : observedAt,
      readScope: mergeLiveReadScope(pending?.readScope, readScope),
    });
    if (this.closed) return;
    const now = Date.now();
    this.liveContentBatchStartedAt ??= now;
    if (this.liveContentTimer) clearTimeout(this.liveContentTimer);
    const elapsed = now - this.liveContentBatchStartedAt;
    const delay = Math.max(
      0,
      Math.min(LIVE_CONTENT_SETTLE_MS, LIVE_CONTENT_MAX_WAIT_MS - elapsed),
    );
    this.liveContentTimer = setTimeout(() => {
      this.liveContentTimer = undefined;
      this.flushPendingLiveContent();
    }, delay);
    this.liveContentTimer.unref?.();
  }

  private publishLiveContent(
    target: ConversationSyncTarget,
    observedAt: string,
    catalogObservedAt?: string,
    readScope: LiveContentRevision["readScope"] = "recent",
  ): void {
    const key = targetKey(target);
    const pending = this.pendingLiveContent.get(key);
    this.pendingLiveContent.delete(key);
    if (this.pendingLiveContent.size === 0) {
      if (this.liveContentTimer) clearTimeout(this.liveContentTimer);
      this.liveContentTimer = undefined;
      this.liveContentBatchStartedAt = undefined;
    }
    this.rememberLiveContent(
      target,
      pending ? laterIso(pending.observedAt, observedAt) : observedAt,
      catalogObservedAt,
      mergeLiveReadScope(pending?.readScope, readScope),
    );
    const changedKeys = new Set([key]);
    this.applyRuntimeOverlay(changedKeys);
    this.recomputeStates(changedKeys);
    this.scheduleInteractiveClients({ dirtyKeys: changedKeys });
  }

  private flushPendingLiveContent(): void {
    if (this.closed || this.pendingLiveContent.size === 0) return;
    const pending = [...this.pendingLiveContent.values()];
    this.pendingLiveContent.clear();
    this.liveContentBatchStartedAt = undefined;
    const changedKeys = new Set<ConversationKey>();
    for (const { target, observedAt, readScope } of pending) {
      this.rememberLiveContent(target, observedAt, undefined, readScope);
      changedKeys.add(targetKey(target));
    }
    this.applyRuntimeOverlay(changedKeys);
    this.recomputeStates(changedKeys);
    this.scheduleInteractiveClients({ dirtyKeys: changedKeys });
  }

  private rememberLiveContent(
    target: ConversationSyncTarget,
    observedAt: string,
    catalogObservedAt?: string,
    readScope: LiveContentRevision["readScope"] = "recent",
  ): void {
    const key = targetKey(target);
    const previous = this.liveContentRevisions.get(key);
    const latestCatalogObservedAt = catalogObservedAt
      ? previous?.catalogObservedAt
        ? laterIso(previous.catalogObservedAt, catalogObservedAt)
        : catalogObservedAt
      : previous?.catalogObservedAt;
    const record = this.catalog.get(key);
    if (record && latestCatalogObservedAt) {
      record.entry = withLiveCatalogMetadata(
        record.entry,
        latestCatalogObservedAt,
      );
    }
    this.liveContentRevisions.set(key, {
      target,
      observedAt,
      ...(latestCatalogObservedAt
        ? { catalogObservedAt: latestCatalogObservedAt }
        : {}),
      revision: providerRevision(
        target,
        `${observedAt}:${++this.liveRevision}`,
      ),
      readScope: mergeLiveReadScope(previous?.readScope, readScope),
    });
  }

  private scheduleInteractiveClients(
    options: {
      full?: boolean;
      dirtyKeys?: Iterable<ConversationKey>;
    } = {},
  ): void {
    const dirtyKeys = options.dirtyKeys ? [...options.dirtyKeys] : undefined;
    for (const [client, subscription] of this.subscriptions) {
      if (!subscription.interactive) continue;
      this.scheduleSync(client, subscription, {
        full: options.full,
        dirtyKeys,
      });
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
    const responsePayload = (
      page: ConversationTurnsPage,
    ): ConversationSyncEventPayload => ({
      event: "turns_page_response",
      requestId: message.requestId,
      provider: message.provider,
      providerSessionId: message.providerSessionId,
      data: page.data,
      nextCursor: page.nextCursor,
    });
    let page: ConversationTurnsPage;
    try {
      page = await readTurnsPage(
        message,
        this.historyReader,
        signal,
        (operation) => this.withSharedCodexReadProcess(operation),
        this.desktopToolTimelineReader,
        (candidate) =>
          this.eventPayloadFits(subscription, responsePayload(candidate)),
      );
      for (const turn of page.turnDetails ?? []) {
        this.rememberTurnDetails(message, turn);
      }
    } catch (error) {
      try {
        this.sendError(
          client,
          subscription,
          message.requestId,
          "turns_page_failed",
          errorMessage(error),
          message,
        );
      } catch {
        subscription.dirty = true;
      }
      return;
    }
    try {
      this.sendEvent(client, subscription, responsePayload(page));
    } catch {
      // The response is already queued when a synchronous socket write fails.
      // Do not append a false provider/read failure for the same request.
      subscription.dirty = true;
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
    const responsePayload = (
      page: ConversationItemsPage,
    ): ConversationSyncEventPayload => ({
      event: "items_page_response",
      requestId: message.requestId,
      provider: message.provider,
      providerSessionId: message.providerSessionId,
      ...(message.turnId ? { turnId: message.turnId } : {}),
      data: page.data,
      nextCursor: page.nextCursor,
    });
    let page: ConversationItemsPage;
    try {
      const pageFits = (candidate: ConversationItemsPage) =>
        this.eventPayloadFits(subscription, responsePayload(candidate));
      const cached =
        message.turnId && message.toolUseIds
          ? this.cachedTurnDetails(message, message.turnId, message.toolUseIds)
          : null;
      page = cached
        ? historyToolDetailsPage(message, cached)
        : await readItemsPage(
            message,
            this.historyReader,
            signal,
            (operation) => this.withSharedCodexReadProcess(operation),
            this.desktopToolTimelineReader,
            pageFits,
          );
      if (!pageFits(page)) {
        throw oversizedItemsPageError();
      }
      if (page.turnDetails) {
        this.rememberTurnDetails(message, page.turnDetails);
      }
    } catch (error) {
      try {
        this.sendError(
          client,
          subscription,
          message.requestId,
          "items_page_failed",
          errorMessage(error),
          message,
        );
      } catch {
        subscription.dirty = true;
      }
      return;
    }
    try {
      this.sendEvent(client, subscription, responsePayload(page));
    } catch {
      // Preserve the valid queued response; transport recovery will flush it.
      subscription.dirty = true;
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
    const sequence = subscription.nextSequence + 1;
    const message = this.eventMessage(subscription, sequence, payload);
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
    subscription.nextSequence = sequence;
    subscription.outbound.push({ sequence, bytes, message });
    subscription.queuedBytes += bytes;
    this.flush(client, subscription);
    return sequence;
  }

  private async waitForOutboundCapacity(
    client: object,
    subscription: SyncSubscription,
    payload: ConversationSyncEventPayload,
  ): Promise<boolean> {
    const bytes = this.eventPayloadBytes(subscription, payload);
    if (bytes > MAX_FRAME_BYTES) {
      throw new Error(
        `conversation_sync_v2 frame exceeds ${MAX_FRAME_BYTES} bytes`,
      );
    }
    while (
      subscription.queuedBytes + subscription.outstandingBytes + bytes >
      SYNC_BACKPRESSURE_BYTES
    ) {
      if (
        this.closed ||
        this.subscriptions.get(client) !== subscription ||
        !subscription.interactive ||
        !this.clientReady(client)
      ) {
        return false;
      }
      await new Promise<void>((resolve) => {
        subscription.capacityWaiters.add(resolve);
      });
    }
    return true;
  }

  private wakeCapacityWaiters(subscription: SyncSubscription): void {
    const waiters = [...subscription.capacityWaiters];
    subscription.capacityWaiters.clear();
    for (const resolve of waiters) resolve();
  }

  private eventPayloadFits(
    subscription: SyncSubscription,
    payload: ConversationSyncEventPayload,
  ): boolean {
    return this.eventPayloadBytes(subscription, payload) <= MAX_FRAME_BYTES;
  }

  private eventPayloadBytes(
    subscription: SyncSubscription,
    payload: ConversationSyncEventPayload,
  ): number {
    return Buffer.byteLength(
      JSON.stringify(
        this.eventMessage(subscription, Number.MAX_SAFE_INTEGER, payload),
      ),
      "utf8",
    );
  }

  private eventMessage(
    subscription: SyncSubscription,
    sequence: number,
    payload: ConversationSyncEventPayload,
  ): ConversationSyncServerMessage {
    return {
      type: CONVERSATION_SYNC_V2_CAPABILITY,
      subscriptionId: subscription.id,
      bridgeInstanceId: this.runtime.bridgeInstanceId ?? "unavailable",
      codexSourceId: this.runtime.codexSourceId ?? "legacy",
      batchId: subscription.batchId,
      sequence,
      ...payload,
    } as ConversationSyncServerMessage;
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
      // The queue is the retry source of truth. Keep the frame and its byte
      // accounting intact until the runtime confirms the socket write.
      this.runtime.send(client, frame.message);
      subscription.outbound.shift();
      subscription.queuedBytes = Math.max(
        0,
        subscription.queuedBytes - frame.bytes,
      );
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

  private hasSharedObserverDemand(): boolean {
    return (
      [...this.subscriptions.values()].some(
        (subscription) =>
          subscription.interactive || subscription.notificationOnly,
      ) || this.runtime.hasExternalCodexNotificationDemand?.() === true
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

function mergeObservedMessagesReplacingStable(
  history: readonly ServerMessage[],
  observed: Iterable<ExternalCodexLiveMessage>,
): ServerMessage[] {
  const merged = [...history];
  const canonicalUsers = merged
    .map((message, index) => ({ message, index }))
    .filter((entry) => entry.message.type === "user_input");
  const matchedCanonicalUsers = new Set<number>();
  const identities = new Map<string, number>();
  merged.forEach((message, index) => {
    const identity = observedMessageIdentity(message);
    if (identity) identities.set(identity, index);
  });
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
    if (!identity) {
      merged.push(entry.message);
      continue;
    }
    const existing = identities.get(identity);
    if (existing === undefined) {
      identities.set(identity, merged.length);
      merged.push(entry.message);
    } else {
      // Stable app-server item ids are update identities. Preserve their
      // timeline position while replacing a tool-start shell or partial final
      // message with its newer observer projection.
      merged[existing] = entry.message;
    }
  }
  return merged;
}

function historyWindowFromSnapshot(
  snapshot: ConversationContentSnapshot,
): ConversationHistoryWindow {
  return {
    messages: snapshot.entries.map((entry) => entry.message),
    nextTurnCursor: snapshot.turnsNextCursor ?? null,
    latestTurnComplete: snapshot.latestTurnComplete,
    ...(snapshot.latestTurnGap
      ? { latestTurnGap: snapshot.latestTurnGap }
      : {}),
  };
}

function mergeSnapshotWithLatestTurn(
  snapshot: ConversationContentSnapshot,
  latest: ConversationHistoryWindow,
): ConversationHistoryWindow {
  const base = snapshot.entries.map((entry) => entry.message);
  const messages = mergeObservedMessagesReplacingStable(
    base,
    latest.messages.map((message) => ({
      message,
      observedAt: "",
      bytes: 0,
    })),
  );
  return {
    messages,
    nextTurnCursor: snapshot.turnsNextCursor ?? latest.nextTurnCursor,
    turnDetails: latest.turnDetails,
    latestTurnComplete: latest.latestTurnComplete,
    ...(latest.latestTurnGap ? { latestTurnGap: latest.latestTurnGap } : {}),
  };
}

function annotateObservedTurn(
  message: ServerMessage,
  turnId: string | undefined,
): ServerMessage {
  if (!turnId) return message;
  if (message.type === "assistant" || message.type === "tool_result") {
    return { ...message, historyTurnId: turnId };
  }
  return message;
}

function sanitizeSharedObserverMessage(
  runtime: LocalFeatureRuntime,
  message: ServerMessage,
): ServerMessage {
  if (message.type !== "tool_result") return message;
  const inlineImages: Array<{ data: string; mimeType: string }> = [];
  for (const value of message.rawContentBlocks ?? []) {
    if (
      inlineImages.length >= MAX_SHARED_OBSERVER_INLINE_IMAGES ||
      !value ||
      typeof value !== "object" ||
      Array.isArray(value)
    ) {
      continue;
    }
    const block = value as Record<string, unknown>;
    const source =
      block.source && typeof block.source === "object"
        ? (block.source as Record<string, unknown>)
        : undefined;
    if (
      block.type !== "image" ||
      source?.type !== "base64" ||
      typeof source.data !== "string" ||
      typeof source.media_type !== "string" ||
      !source.media_type.startsWith("image/") ||
      Buffer.byteLength(source.data, "utf8") >
        MAX_SHARED_OBSERVER_INLINE_IMAGE_BASE64_BYTES
    ) {
      continue;
    }
    inlineImages.push({ data: source.data, mimeType: source.media_type });
  }
  const registered = runtime.registerInlineImages?.(inlineImages) ?? [];
  const { rawContentBlocks: _, artifactCandidates: __, ...safe } = message;
  return {
    ...safe,
    ...((message.images?.length ?? 0) + registered.length > 0
      ? {
          images: [...(message.images ?? []), ...registered].slice(
            0,
            MAX_SHARED_OBSERVER_INLINE_IMAGES,
          ),
        }
      : {}),
  };
}

function mergeLiveReadScope(
  first: LiveContentRevision["readScope"] | undefined,
  second: LiveContentRevision["readScope"],
): LiveContentRevision["readScope"] {
  const rank = { direct: 0, latestTurn: 1, recent: 2 } as const;
  if (!first) return second;
  return rank[first] >= rank[second] ? first : second;
}

function canonicalHistoryCoversDurableExternalMessages(
  history: readonly ServerMessage[],
  observed: Iterable<ExternalCodexLiveMessage>,
): boolean {
  const entries = [...observed];
  const durable = entries.filter(
    (entry) =>
      entry.message.type !== "thinking_delta" &&
      entry.message.type !== "stream_delta",
  );
  const hasTransient = durable.length !== entries.length;
  // Reasoning/stream chunks are transient projections rather than durable
  // provider items. Keep them while canonical history is wholly empty, then
  // require only stable user/assistant/tool identities to be represented.
  if (hasTransient && history.length === 0) return false;
  return mergeExternalCodexMessages(history, durable).length === history.length;
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
  withCodexReadProcess?: WithCodexReadProcess,
): Promise<ConversationSyncCatalogSeed[]> {
  const [claude, codex] = await Promise.all([
    getAllRecentSessions({
      provider: "claude",
      limit: MAX_CATALOG_ENTRIES,
      offset: 0,
      metadataOnly: true,
    }).then((result) => result.sessions.map(sessionSeed)),
    readCodexCatalog(runtime, {}, withCodexReadProcess),
  ]);
  return [...codex, ...claude]
    .sort((left, right) =>
      right.entry.recencyAt.localeCompare(left.entry.recencyAt),
    )
    .slice(0, MAX_CATALOG_ENTRIES);
}

async function readCodexCatalog(
  runtime: LocalFeatureRuntime,
  options: { includeDurableMetadata?: boolean } = {},
  withCodexReadProcess?: WithCodexReadProcess,
): Promise<ConversationSyncCatalogSeed[]> {
  try {
    const read =
      withCodexReadProcess ??
      ((operation) => withCodexProcess(runtime, undefined, operation));
    return await read(async (process) => {
      const threads: CodexThreadSummary[] = [];
      let cursor: string | null = null;
      do {
        const page = await process.listThreads({
          cursor,
          limit: Math.min(
            CODEX_PAGE_SIZE,
            MAX_CATALOG_ENTRIES - threads.length,
          ),
          sortKey: "recency_at",
          sortDirection: "desc",
          archived: false,
          useStateDbOnly: true,
          sourceKinds: [...CONVERSATION_SYNC_PRIMARY_CODEX_SOURCE_KINDS],
        });
        for (const thread of page.data) {
          if (!thread.id || thread.ephemeral) continue;
          threads.push(thread);
          if (threads.length >= MAX_CATALOG_ENTRIES) break;
        }
        cursor = page.nextCursor;
      } while (cursor && threads.length < MAX_CATALOG_ENTRIES);

      if (options.includeDurableMetadata === false) {
        return threads.map((thread) =>
          buildConversationSyncCodexCatalogSeed(thread),
        );
      }

      // thread/list is the fast authority for identity, recency and runtime
      // status, but it does not currently expose the selected model, effort
      // or service tier. Resolve those three facts in one bounded rollout
      // metadata pass; a failure only leaves the optional settings unknown.
      const metadata = await getCodexSessionIndexMetadata(
        threads.map((thread) => thread.id),
      ).catch(() => new Map<string, CodexSessionIndexMetadata>());
      return threads.map((thread) =>
        buildConversationSyncCodexCatalogSeed(thread, metadata.get(thread.id)),
      );
    });
  } catch (error) {
    if (
      !isUnsupportedAppServerRead(error) &&
      !isUnsupportedCodexSourceKindFilter(error)
    ) {
      throw error;
    }
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
  _current: ReadonlyMap<ConversationKey, CatalogRecord>,
  withCodexReadProcess?: WithCodexReadProcess,
): Promise<Map<ConversationKey, ConversationSyncStatus>> {
  const statuses = new Map<ConversationKey, ConversationSyncStatus>();
  const codex = await readCodexCatalog(
    runtime,
    { includeDurableMetadata: false },
    withCodexReadProcess,
  );
  for (const seed of codex) statuses.set(targetKey(seed.entry), seed.status);
  return statuses;
}

async function readOptionalDesktopToolTimeline(
  reader: DesktopToolTimelineReader,
  threadId: string,
): Promise<CodexDesktopToolTimeline | undefined> {
  try {
    const timeline = await reader(threadId);
    return timeline.events.length > 0 || timeline.itemTimestamps?.size
      ? timeline
      : undefined;
  } catch (error) {
    // Timeline enrichment is optional and must not make canonical app-server
    // history unavailable. Keep diagnostics bounded and path-free because
    // reader failures may include the local rollout path.
    const kind = error instanceof Error ? error.name : typeof error;
    console.warn(
      `[conversation-sync-v2] Optional Desktop item timeline unavailable (${kind})`,
    );
    return undefined;
  }
}

async function readRecentCodexConversationHistory(
  process: CodexProcess,
  target: ConversationSyncTarget,
  desktopToolTimelineReader: DesktopToolTimelineReader,
): Promise<ConversationHistoryWindow> {
  const timeline = readOptionalDesktopToolTimeline(
    desktopToolTimelineReader,
    target.providerSessionId,
  );
  const [page, desktopToolTimeline] = await Promise.all([
    process.listThreadTurns({
      threadId: target.providerSessionId,
      limit: 5,
      sortDirection: "desc",
      // The current app-server summary view keeps only the user/final spine and
      // omits tool ids/counts. Read one bounded full page at the Bridge, then
      // compact the older two turns before crossing the wire.
      itemsView: "full",
    }),
    timeline,
  ]);
  const turns = [...page.data].reverse();
  const normalized = normalizeCodexTurns(
    turns,
    "full",
    target.providerSessionId,
    desktopToolTimeline,
  );
  const fullStart = Math.max(0, normalized.turns.length - FULL_RECENT_TURNS);
  const latestTurn = normalized.turns.at(-1);
  return {
    messages: normalized.turns.flatMap((turn, index) =>
      index < fullStart
        ? compactTurnMessages(turn.messages, turn.turnId)
        : turn.messages,
    ),
    nextTurnCursor: page.nextCursor,
    turnDetails: normalized.turnDetails,
    latestTurnComplete: latestTurn?.latestTurnComplete ?? true,
    ...(latestTurn?.latestTurnGap
      ? { latestTurnGap: latestTurn.latestTurnGap }
      : {}),
  };
}

async function readLatestCodexTurnHistory(
  process: CodexProcess,
  target: ConversationSyncTarget,
): Promise<ConversationHistoryWindow> {
  const page = await process.listThreadTurns({
    threadId: target.providerSessionId,
    limit: 1,
    sortDirection: "desc",
    itemsView: "full",
  });
  const normalized = normalizeCodexTurns(
    [...page.data].reverse(),
    "full",
    target.providerSessionId,
  );
  const latestTurn = normalized.turns.at(-1);
  return {
    messages: latestTurn?.messages ?? [],
    nextTurnCursor: page.nextCursor,
    turnDetails: normalized.turnDetails,
    latestTurnComplete: latestTurn?.latestTurnComplete ?? true,
    ...(latestTurn?.latestTurnGap
      ? { latestTurnGap: latestTurn.latestTurnGap }
      : {}),
  };
}

async function readRecentClaudeConversationHistory(
  target: ConversationSyncTarget,
  request?: ConversationHistoryReadRequest,
): Promise<ConversationHistoryWindow> {
  const page = await readClaudeSessionHistoryWindow(target.providerSessionId, {
    ...(request?.cursor ? { cursor: request.cursor } : {}),
    maxUserTurns: request?.limit ?? PRIORITY_RECENT_COUNT,
  });
  const messages = sessionHistoryToServerMessages(page.messages, {
    idPrefix: `claude-history-${target.providerSessionId}`,
  });
  const turns = groupLegacyTurns(messages);
  const fullStart = Math.max(0, turns.length - FULL_RECENT_TURNS);
  const normalizedMessages = turns.flatMap((turn, index) => {
    const annotated = annotateTurnMessages(turn.items, turn.id);
    return !request && index < fullStart
      ? compactTurnMessages(annotated, turn.id)
      : annotated;
  });
  const turnDetails = turns
    .map((turn) => ({
      turnId: turn.id,
      details: historyToolDetailPayloads(
        annotateTurnMessages(turn.items, turn.id),
      ),
    }))
    .filter((turn) => turn.details.length > 0);
  return {
    messages: normalizedMessages,
    nextTurnCursor: page.nextCursor,
    turnDetails,
    sourceCursor: request?.cursor ?? null,
  };
}

function boundedLegacyPageUnavailable(provider: string): Error {
  return new Error(
    `Bounded legacy history paging is unavailable for ${provider}; refusing an unbounded durable-history scan`,
  );
}

async function readTurnsPage(
  message: Extract<
    ConversationSyncClientMessage,
    { type: "conversation_turns_page" }
  >,
  historyReader: ConversationHistoryReader,
  signal: AbortSignal,
  runCodexRead: CodexReadRunner,
  desktopToolTimelineReader: DesktopToolTimelineReader,
  pageFits: (page: ConversationTurnsPage) => boolean,
): Promise<ConversationTurnsPage> {
  if (message.provider === "codex") {
    try {
      return await runCodexRead(async (process) => {
        const timeline = readOptionalDesktopToolTimeline(
          desktopToolTimelineReader,
          message.providerSessionId,
        );
        let lastPage: ConversationTurnsPage | undefined;
        for (const limit of decreasingPageLimits(message.limit ?? 5)) {
          signal.throwIfAborted();
          const page = await process.listThreadTurns(
            {
              threadId: message.providerSessionId,
              cursor: message.cursor,
              limit,
              sortDirection: message.sortDirection ?? "desc",
              // Summary pages stay summary at the provider boundary. Full
              // item details are fetched by the explicit items endpoint.
              itemsView: message.itemsView ?? "summary",
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
            await timeline,
          );
          const candidate: ConversationTurnsPage = {
            data: normalized.turns,
            nextCursor: page.nextCursor,
            turnDetails: normalized.turnDetails,
          };
          if (pageFits(candidate)) return candidate;
          lastPage = candidate;
        }
        if (!lastPage) {
          throw new Error("Codex turns page did not return a bounded result");
        }
        return projectOversizedTurnsPage(message, lastPage, pageFits);
      });
    } catch (error) {
      if (!isUnsupportedAppServerRead(error)) throw error;
    }
  }
  return readLegacyTurnsPage(message, historyReader, pageFits);
}

async function readLegacyTurnsPage(
  message: Extract<
    ConversationSyncClientMessage,
    { type: "conversation_turns_page" }
  >,
  historyReader: ConversationHistoryReader,
  pageFits: (page: ConversationTurnsPage) => boolean,
): Promise<ConversationTurnsPage> {
  const cursor = decodeLegacyWindowCursor(message.cursor);
  const history = normalizeHistoryWindow(
    await historyReader(message, {
      kind: "turns",
      cursor: cursor.sourceCursor,
      limit: message.limit ?? 5,
      sortDirection: message.sortDirection ?? "desc",
      itemsView: message.itemsView ?? "summary",
    }),
  );
  assertLegacySourceCursorConsumed(history, cursor.sourceCursor);
  const cachedDetailsByTurn = new Map(
    (history.turnDetails ?? []).map((turn) => [turn.turnId, turn.details]),
  );
  const turns = groupLegacyTurns(history.messages);
  let lastPage: ConversationTurnsPage | undefined;
  for (const limit of decreasingPageLimits(message.limit ?? 5)) {
    const rawPage = paginateArray(
      turns,
      String(cursor.offset),
      limit,
      message.sortDirection ?? "desc",
    );
    const pageTurns = rawPage.data.map((turn) => {
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
    const wireTurns =
      (message.sortDirection ?? "desc") === "desc"
        ? [...pageTurns].reverse()
        : pageTurns;
    const candidate: ConversationTurnsPage = {
      data: wireTurns.map(({ details: _, ...turn }) => turn),
      nextCursor: nextLegacyWindowCursor(
        cursor,
        rawPage.nextCursor,
        history.nextTurnCursor,
      ),
      turnDetails: pageTurns
        .filter((turn) => turn.details.length > 0)
        .map((turn) => ({ turnId: turn.turnId, details: turn.details })),
    };
    if (pageFits(candidate)) return candidate;
    lastPage = candidate;
  }
  if (!lastPage) {
    throw new Error("Legacy turns page did not return a bounded result");
  }
  return projectOversizedTurnsPage(message, lastPage, pageFits);
}

async function readItemsPage(
  message: Extract<
    ConversationSyncClientMessage,
    { type: "conversation_items_page" }
  >,
  historyReader: ConversationHistoryReader,
  signal: AbortSignal,
  runCodexRead: CodexReadRunner,
  desktopToolTimelineReader: DesktopToolTimelineReader,
  pageFits: (page: ConversationItemsPage) => boolean,
): Promise<ConversationItemsPage> {
  if (message.provider === "codex") {
    try {
      return await runCodexRead(async (process) => {
        const timeline = readOptionalDesktopToolTimeline(
          desktopToolTimelineReader,
          message.providerSessionId,
        );
        const turnId = message.turnId ?? "paged-items";
        let lastPage: ConversationItemsPage | undefined;
        for (const limit of decreasingPageLimits(message.limit ?? 200)) {
          signal.throwIfAborted();
          let messages: ServerMessage[];
          let nextCursor: string | null = null;
          let usedTurnsFallback = false;
          try {
            const page = await process.listThreadItems(
              {
                threadId: message.providerSessionId,
                turnId: message.turnId,
                cursor: message.cursor,
                limit,
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
              await timeline,
            );
            nextCursor = page.nextCursor;
          } catch (error) {
            if (!message.turnId || !isUnsupportedAppServerRead(error)) {
              throw error;
            }
            messages = await findCodexTurnMessages(
              process,
              message.providerSessionId,
              message.turnId,
              signal,
              await timeline,
            );
            usedTurnsFallback = true;
          }
          const details = historyToolDetailPayloads(
            messages,
            message.toolUseIds,
          );
          const turnDetails = {
            turnId,
            details: historyToolDetailPayloads(messages),
          };
          const candidate: ConversationItemsPage = message.toolUseIds
            ? {
                ...historyToolDetailsPage(message, details),
                turnDetails,
              }
            : {
                data: messages,
                nextCursor,
                turnDetails,
              };
          if (pageFits(candidate)) return candidate;
          if (usedTurnsFallback || message.toolUseIds) {
            throw oversizedItemsPageError();
          }
          lastPage = candidate;
        }
        if (!lastPage) {
          throw new Error("Codex items page did not return a bounded result");
        }
        throw oversizedItemsPageError();
      });
    } catch (error) {
      if (!isUnsupportedAppServerRead(error)) throw error;
    }
  }
  return readLegacyItemsPage(message, historyReader, pageFits);
}

async function readLegacyItemsPage(
  message: Extract<
    ConversationSyncClientMessage,
    { type: "conversation_items_page" }
  >,
  historyReader: ConversationHistoryReader,
  pageFits: (page: ConversationItemsPage) => boolean,
): Promise<ConversationItemsPage> {
  let localCursor = message.cursor;
  if (message.cursor?.startsWith(LEGACY_WINDOW_CURSOR_PREFIX)) {
    const decoded = decodeLegacyWindowCursor(message.cursor);
    if (decoded.sourceCursor !== null) {
      throw new Error(
        "Legacy item history cannot consume the opaque item cursor",
      );
    }
    localCursor = String(decoded.offset);
  } else if (message.cursor && !/^\d+$/.test(message.cursor)) {
    throw new Error(
      "Legacy item history cannot consume the opaque item cursor",
    );
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
    const candidate = {
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
    if (!pageFits(candidate)) throw oversizedItemsPageError();
    return candidate;
  }
  let lastPage: ConversationItemsPage | undefined;
  for (const limit of decreasingPageLimits(message.limit ?? 50)) {
    const candidate = paginateArray(
      annotated,
      localCursor,
      limit,
      message.sortDirection ?? "asc",
    );
    if (pageFits(candidate)) return candidate;
    lastPage = candidate;
  }
  if (!lastPage) {
    throw new Error("Legacy items page did not return a bounded result");
  }
  throw oversizedItemsPageError();
}

function decreasingPageLimits(requestedLimit: number): number[] {
  const limits: number[] = [];
  let current = Math.min(200, Math.max(1, Math.floor(requestedLimit)));
  for (;;) {
    limits.push(current);
    if (current === 1) return limits;
    current = Math.max(1, Math.floor(current / 2));
  }
}

interface LegacyWindowCursor {
  sourceCursor: string | null;
  offset: number;
}

function decodeLegacyWindowCursor(
  cursor: string | undefined,
): LegacyWindowCursor {
  if (!cursor) return { sourceCursor: null, offset: 0 };
  if (!cursor.startsWith(LEGACY_WINDOW_CURSOR_PREFIX)) {
    return { sourceCursor: cursor, offset: 0 };
  }
  try {
    const decoded = JSON.parse(
      Buffer.from(
        cursor.slice(LEGACY_WINDOW_CURSOR_PREFIX.length),
        "base64url",
      ).toString("utf8"),
    ) as { sourceCursor?: unknown; offset?: unknown };
    if (
      (decoded.sourceCursor === null ||
        typeof decoded.sourceCursor === "string") &&
      typeof decoded.offset === "number" &&
      Number.isSafeInteger(decoded.offset) &&
      decoded.offset >= 0
    ) {
      return {
        sourceCursor: decoded.sourceCursor,
        offset: decoded.offset,
      };
    }
  } catch {
    // Invalid bridge cursor is rejected below rather than replayed as offset 0.
  }
  throw new Error("Invalid legacy history cursor");
}

function encodeLegacyWindowCursor(cursor: LegacyWindowCursor): string {
  return `${LEGACY_WINDOW_CURSOR_PREFIX}${Buffer.from(
    JSON.stringify(cursor),
    "utf8",
  ).toString("base64url")}`;
}

function assertLegacySourceCursorConsumed(
  history: ConversationHistoryWindow,
  sourceCursor: string | null,
): void {
  if (sourceCursor === null) return;
  if (history.sourceCursor !== sourceCursor) {
    throw new Error(
      "Legacy history reader did not consume the requested opaque cursor",
    );
  }
}

function nextLegacyWindowCursor(
  current: LegacyWindowCursor,
  localNextCursor: string | null,
  sourceNextCursor: string | null,
): string | null {
  if (localNextCursor != null) {
    return encodeLegacyWindowCursor({
      sourceCursor: current.sourceCursor,
      offset: Number.parseInt(localNextCursor, 10),
    });
  }
  if (sourceNextCursor == null) return null;
  if (sourceNextCursor === current.sourceCursor) {
    throw new Error("Legacy history reader returned a non-advancing cursor");
  }
  return encodeLegacyWindowCursor({
    sourceCursor: sourceNextCursor,
    offset: 0,
  });
}

function mergeLatestTurnGaps(
  first: ConversationContentLatestTurnGap | undefined,
  second: ConversationContentLatestTurnGap | undefined,
): ConversationContentLatestTurnGap | undefined {
  if (!first) return second;
  if (!second) return first;
  const missingIndices = [
    first.firstMissingSourceIndex,
    second.firstMissingSourceIndex,
  ].filter((value): value is number => value !== undefined);
  return {
    ...((first.turnId ?? second.turnId)
      ? { turnId: first.turnId ?? second.turnId }
      : {}),
    missingEntryCount: first.missingEntryCount + second.missingEntryCount,
    payloadOmitted: first.payloadOmitted || second.payloadOmitted,
    ...(missingIndices.length > 0
      ? { firstMissingSourceIndex: Math.min(...missingIndices) }
      : {}),
    repair:
      first.repair === "items_page" || second.repair === "items_page"
        ? "items_page"
        : "turns_page",
  };
}

function projectOversizedTurnsPage(
  message: Extract<
    ConversationSyncClientMessage,
    { type: "conversation_turns_page" }
  >,
  page: ConversationTurnsPage,
  pageFits: (candidate: ConversationTurnsPage) => boolean,
): ConversationTurnsPage {
  if (page.data.length !== 1) {
    throw new Error("Conversation turns page exceeds the frame byte budget");
  }
  const rawTurn = page.data[0];
  if (!rawTurn || typeof rawTurn !== "object" || Array.isArray(rawTurn)) {
    throw new Error(
      "Conversation turn cannot be projected into a bounded page",
    );
  }
  const turn = rawTurn as Record<string, unknown>;
  if (!Array.isArray(turn.messages)) {
    throw new Error("Conversation turn does not contain projectable messages");
  }
  for (const textBudget of PAGE_PROJECTION_TEXT_BUDGETS) {
    let snapshot: ReturnType<typeof buildConversationContentSnapshot>;
    try {
      snapshot = buildConversationContentSnapshot(
        {
          provider: message.provider,
          providerSessionId: message.providerSessionId,
        },
        turn.messages as ServerMessage[],
        {
          maxMessageTextBytes: textBudget,
          maxSnapshotBytes: projectedSnapshotBudget(textBudget),
          preserveLatestRootTurnTools: false,
        },
      );
    } catch {
      // Retry with the next smaller deterministic projection budget.
      continue;
    }
    const existingGap =
      turn.latestTurnGap &&
      typeof turn.latestTurnGap === "object" &&
      !Array.isArray(turn.latestTurnGap)
        ? (turn.latestTurnGap as ConversationContentLatestTurnGap)
        : undefined;
    const latestTurnGap = mergeLatestTurnGaps(
      existingGap,
      snapshot.latestTurnGap,
    );
    const candidate: ConversationTurnsPage = {
      ...page,
      data: [
        {
          ...turn,
          messages: snapshot.entries.map((entry) => entry.message),
          itemsView: "summary",
          latestTurnComplete:
            turn.latestTurnComplete !== false &&
            snapshot.latestTurnComplete &&
            latestTurnGap === undefined,
          ...(latestTurnGap ? { latestTurnGap } : {}),
        },
      ],
    };
    if (pageFits(candidate)) return candidate;
  }
  throw new Error("Conversation turn exceeds the frame byte budget");
}

function oversizedItemsPageError(): Error {
  return new Error(
    "Conversation item exceeds the frame byte budget; retry with the same cursor",
  );
}

function projectedSnapshotBudget(textBudget: number): number {
  return Math.max(8 * 1024, Math.min(48 * 1024, textBudget + 16 * 1024));
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
  desktopToolTimeline?: CodexDesktopToolTimeline,
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
    const rawItems = Array.isArray(turn.items) ? turn.items : [];
    const firstItem =
      rawItems[0] && typeof rawItems[0] === "object"
        ? (rawItems[0] as Record<string, unknown>)
        : undefined;
    const firstItemId =
      typeof firstItem?.id === "string" ? firstItem.id : "anonymous";
    const turnId =
      typeof rawId === "string" && rawId.trim()
        ? rawId.trim()
        : `turn:${hashState([threadId, index, firstItemId]).slice(0, 24)}`;
    const items = rawItems;
    const bounded = boundCodexRawTurnForConversion(turn, turnId);
    const fullMessages = annotateTurnMessages(
      codexTurnMessages(bounded.turn, threadId, desktopToolTimeline),
      turnId,
    );
    if (itemsView === "full") {
      const details = historyToolDetailPayloads(fullMessages);
      if (details.length > 0) turnDetails.push({ turnId, details });
    }
    turns.push({
      turnId,
      messages:
        itemsView === "summary"
          ? compactTurnMessages(fullMessages, turnId)
          : fullMessages,
      itemCount: items.length,
      itemsView: bounded.payloadOmitted ? "summary" : itemsView,
      ...(bounded.payloadOmitted
        ? {
            latestTurnComplete: false,
            latestTurnGap: {
              turnId,
              missingEntryCount: Math.max(1, bounded.missingItemCount),
              payloadOmitted: true,
              repair: "items_page" as const,
            },
          }
        : {}),
    });
  });
  return { turns, turnDetails };
}

interface BoundedCodexRawTurn {
  turn: Record<string, unknown>;
  missingItemCount: number;
  payloadOmitted: boolean;
}

interface CodexRawProjectionBudget {
  remaining: number;
  omitted: boolean;
}

const CODEX_RAW_PRIORITY_KEYS = [
  "type",
  "id",
  "status",
  "role",
  "text",
  "summary",
  "content",
  "command",
  "cwd",
  "exitCode",
  "aggregatedOutput",
  "tool",
  "server",
  "arguments",
  "contentItems",
  "changes",
  "result",
  "error",
] as const;

function boundCodexRawTurnForConversion(
  turn: Record<string, unknown>,
  turnId: string,
): BoundedCodexRawTurn {
  const items = Array.isArray(turn.items) ? turn.items : [];
  const projectedItems: unknown[] = [];
  let remaining = MAX_CODEX_RAW_TURN_BYTES;
  let payloadOmitted = false;
  let projectedPayloadOmissions = 0;

  for (let index = 0; index < items.length; index += 1) {
    if (projectedItems.length >= MAX_CODEX_RAW_TURN_ITEMS || remaining < 128) {
      payloadOmitted = true;
      break;
    }
    const budget: CodexRawProjectionBudget = {
      remaining: Math.min(remaining, MAX_CODEX_RAW_ITEM_BYTES),
      omitted: false,
    };
    const projected = projectCodexRawValue(items[index], budget, 0);
    if (
      !projected ||
      typeof projected !== "object" ||
      Array.isArray(projected)
    ) {
      payloadOmitted = true;
      projectedPayloadOmissions += 1;
      continue;
    }
    const itemBytes = Buffer.byteLength(JSON.stringify(projected), "utf8");
    if (itemBytes > remaining) {
      payloadOmitted = true;
      break;
    }
    projectedItems.push(projected);
    remaining -= itemBytes;
    if (budget.omitted) {
      payloadOmitted = true;
      projectedPayloadOmissions += 1;
    }
  }

  const missingWholeItems = Math.max(0, items.length - projectedItems.length);
  return {
    turn: {
      id: turnId,
      ...(typeof turn.startedAt === "number"
        ? { startedAt: turn.startedAt }
        : {}),
      ...(typeof turn.completedAt === "number"
        ? { completedAt: turn.completedAt }
        : {}),
      items: projectedItems,
    },
    missingItemCount: missingWholeItems + projectedPayloadOmissions,
    payloadOmitted: payloadOmitted || missingWholeItems > 0,
  };
}

function projectCodexRawValue(
  value: unknown,
  budget: CodexRawProjectionBudget,
  depth: number,
  key?: string,
): unknown {
  if (budget.remaining <= 0) {
    budget.omitted = true;
    return undefined;
  }
  if (
    value == null ||
    typeof value === "boolean" ||
    typeof value === "number"
  ) {
    budget.remaining -= 8;
    return value;
  }
  if (typeof value === "string") {
    if (isBinaryCodexRawKey(key)) {
      budget.omitted = true;
      return undefined;
    }
    const projected = boundedCodexRawString(
      value,
      Math.min(MAX_CODEX_RAW_STRING_BYTES, budget.remaining),
    );
    budget.remaining -= Buffer.byteLength(projected.value, "utf8") + 2;
    budget.omitted ||= projected.truncated;
    return projected.value;
  }
  if (depth >= MAX_CODEX_RAW_DEPTH) {
    budget.omitted = true;
    return undefined;
  }
  if (Array.isArray(value)) {
    const projected: unknown[] = [];
    const limit = Math.min(value.length, MAX_CODEX_RAW_ARRAY_ITEMS);
    let visited = 0;
    for (let index = 0; index < limit && budget.remaining > 0; index += 1) {
      visited += 1;
      const item = projectCodexRawValue(value[index], budget, depth + 1, key);
      if (item !== undefined) projected.push(item);
    }
    if (visited < value.length) budget.omitted = true;
    return projected;
  }
  if (typeof value !== "object") {
    budget.omitted = true;
    return undefined;
  }

  const source = value as Record<string, unknown>;
  const availableKeys = Object.keys(source);
  const orderedKeys = [
    ...CODEX_RAW_PRIORITY_KEYS.filter((candidate) =>
      Object.prototype.hasOwnProperty.call(source, candidate),
    ),
    ...availableKeys.filter(
      (candidate) =>
        !(CODEX_RAW_PRIORITY_KEYS as readonly string[]).includes(candidate),
    ),
  ];
  const projected: Record<string, unknown> = {};
  let visited = 0;
  for (const candidate of orderedKeys) {
    if (visited >= MAX_CODEX_RAW_OBJECT_KEYS || budget.remaining <= 0) {
      budget.omitted = true;
      break;
    }
    visited += 1;
    if (isBinaryCodexRawKey(candidate)) {
      budget.omitted = true;
      continue;
    }
    const keyBytes = Buffer.byteLength(candidate, "utf8") + 4;
    if (keyBytes >= budget.remaining) {
      budget.omitted = true;
      break;
    }
    budget.remaining -= keyBytes;
    const child = projectCodexRawValue(
      source[candidate],
      budget,
      depth + 1,
      candidate,
    );
    if (child !== undefined) projected[candidate] = child;
  }
  if (visited < availableKeys.length) budget.omitted = true;
  return projected;
}

function isBinaryCodexRawKey(key: string | undefined): boolean {
  if (!key) return false;
  const normalized = key.toLowerCase();
  return (
    normalized.includes("base64") ||
    normalized === "image" ||
    normalized === "images" ||
    normalized === "imagedata"
  );
}

function boundedCodexRawString(
  value: string,
  maxBytes: number,
): { value: string; truncated: boolean } {
  if (maxBytes <= 0) return { value: "", truncated: value.length > 0 };
  const suffix = "\n… [truncated]";
  const suffixBytes = Buffer.byteLength(suffix, "utf8");
  const contentLimit = Math.max(0, maxBytes - suffixBytes);
  let result = "";
  let bytes = 0;
  let codeUnits = 0;
  for (const codePoint of value) {
    const width = Buffer.byteLength(codePoint, "utf8");
    if (bytes + width > contentLimit) {
      return { value: `${result}${suffix}`, truncated: true };
    }
    result += codePoint;
    bytes += width;
    codeUnits += codePoint.length;
  }
  return { value: result, truncated: codeUnits < value.length };
}

function codexTurnMessages(
  turn: Record<string, unknown>,
  threadId: string,
  desktopToolTimeline?: CodexDesktopToolTimeline,
): ServerMessage[] {
  const history = codexThreadToSessionHistory(
    {
      id: threadId,
      turns: [turn],
    },
    desktopToolTimeline ? { desktopToolTimeline } : undefined,
  );
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
  desktopToolTimeline?: CodexDesktopToolTimeline,
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
        codexTurnMessages(
          found as Record<string, unknown>,
          threadId,
          desktopToolTimeline,
        ),
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
      ...catalogSettings(session.codexSettings),
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
  const model = validCatalogSetting(entry.model, MAX_CATALOG_MODEL_LENGTH);
  const modelReasoningEffort = validCatalogSetting(
    entry.modelReasoningEffort,
    MAX_CATALOG_SETTING_LENGTH,
  );
  const serviceTier = validCatalogSetting(
    entry.serviceTier,
    MAX_CATALOG_SETTING_LENGTH,
  );
  const approvalPolicy = validCatalogSetting(
    entry.approvalPolicy,
    MAX_CATALOG_SETTING_LENGTH,
  );
  const approvalsReviewer = validCatalogSetting(
    entry.approvalsReviewer,
    MAX_CATALOG_SETTING_LENGTH,
  );
  const sandboxMode = validCatalogSetting(
    entry.sandboxMode,
    MAX_CATALOG_SETTING_LENGTH,
  );
  const collaborationMode =
    entry.collaborationMode === "plan" || entry.collaborationMode === "default"
      ? entry.collaborationMode
      : undefined;
  const webSearchMode = validCatalogSetting(
    entry.webSearchMode,
    MAX_CATALOG_SETTING_LENGTH,
  );
  return {
    provider: entry.provider,
    providerSessionId: entry.providerSessionId,
    revision: entry.revision,
    projectPath:
      truncateCatalogText(entry.projectPath, MAX_CATALOG_PATH_LENGTH) ?? "",
    ...(name ? { name } : {}),
    ...(summary ? { summary } : {}),
    ...(firstPrompt ? { firstPrompt } : {}),
    ...(model ? { model } : {}),
    ...(modelReasoningEffort ? { modelReasoningEffort } : {}),
    ...(serviceTier ? { serviceTier } : {}),
    ...(approvalPolicy ? { approvalPolicy } : {}),
    ...(approvalsReviewer ? { approvalsReviewer } : {}),
    ...(sandboxMode ? { sandboxMode } : {}),
    ...(collaborationMode ? { collaborationMode } : {}),
    ...(entry.networkAccessEnabled !== undefined
      ? { networkAccessEnabled: entry.networkAccessEnabled }
      : {}),
    ...(webSearchMode ? { webSearchMode } : {}),
    ...(entry.codexSettingsSnapshotComplete !== undefined
      ? {
          codexSettingsSnapshotComplete: entry.codexSettingsSnapshotComplete,
        }
      : {}),
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

function validCatalogSetting(
  value: string | undefined,
  maximumLength: number,
): string | undefined {
  const normalized = value?.trim();
  return normalized && normalized.length <= maximumLength
    ? normalized
    : undefined;
}

function catalogSettings(
  settings: SessionIndexEntry["codexSettings"] | undefined,
): Pick<
  ConversationSyncCatalogEntry,
  | "model"
  | "modelReasoningEffort"
  | "serviceTier"
  | "approvalPolicy"
  | "approvalsReviewer"
  | "sandboxMode"
  | "collaborationMode"
  | "networkAccessEnabled"
  | "webSearchMode"
> {
  const model = validCatalogSetting(settings?.model, MAX_CATALOG_MODEL_LENGTH);
  const modelReasoningEffort = validCatalogSetting(
    settings?.modelReasoningEffort,
    MAX_CATALOG_SETTING_LENGTH,
  );
  const serviceTier = validCatalogSetting(
    settings?.serviceTier,
    MAX_CATALOG_SETTING_LENGTH,
  );
  const approvalPolicy = validCatalogSetting(
    settings?.approvalPolicy,
    MAX_CATALOG_SETTING_LENGTH,
  );
  const approvalsReviewer = validCatalogSetting(
    settings?.approvalsReviewer,
    MAX_CATALOG_SETTING_LENGTH,
  );
  const sandboxMode = validCatalogSetting(
    settings?.sandboxMode,
    MAX_CATALOG_SETTING_LENGTH,
  );
  const collaborationMode =
    settings?.collaborationMode === "plan" ||
    settings?.collaborationMode === "default"
      ? settings.collaborationMode
      : undefined;
  const webSearchMode = validCatalogSetting(
    settings?.webSearchMode,
    MAX_CATALOG_SETTING_LENGTH,
  );
  return {
    ...(model ? { model } : {}),
    ...(modelReasoningEffort ? { modelReasoningEffort } : {}),
    ...(serviceTier ? { serviceTier } : {}),
    ...(approvalPolicy ? { approvalPolicy } : {}),
    ...(approvalsReviewer ? { approvalsReviewer } : {}),
    ...(sandboxMode ? { sandboxMode } : {}),
    ...(collaborationMode ? { collaborationMode } : {}),
    ...(settings?.networkAccessEnabled !== undefined
      ? { networkAccessEnabled: settings.networkAccessEnabled }
      : {}),
    ...(webSearchMode ? { webSearchMode } : {}),
  };
}

function codexCatalogSettingsObservationSignature(
  entry: ConversationSyncCatalogEntry,
): string {
  return `${entry.revision}\0${entry.modifiedAt}`;
}

function replaceCodexCatalogSettings(
  entry: ConversationSyncCatalogEntry,
  settings: SessionIndexEntry["codexSettings"],
): ConversationSyncCatalogEntry {
  const {
    model: _model,
    modelReasoningEffort: _modelReasoningEffort,
    serviceTier: _serviceTier,
    approvalPolicy: _approvalPolicy,
    approvalsReviewer: _approvalsReviewer,
    sandboxMode: _sandboxMode,
    collaborationMode: _collaborationMode,
    networkAccessEnabled: _networkAccessEnabled,
    webSearchMode: _webSearchMode,
    codexSettingsSnapshotComplete: _codexSettingsSnapshotComplete,
    ...identityAndPresentation
  } = entry;
  return normalizeCatalogEntry({
    ...identityAndPresentation,
    ...catalogSettings(settings),
    codexSettingsSnapshotComplete: true,
  });
}

function mergeIncompleteCodexCatalogSettings(
  incoming: ConversationSyncCatalogEntry,
  previous: ConversationSyncCatalogEntry,
): ConversationSyncCatalogEntry {
  if (
    incoming.provider !== "codex" ||
    previous.provider !== "codex" ||
    incoming.codexSettingsSnapshotComplete === true
  ) {
    return incoming;
  }
  return {
    ...incoming,
    ...(incoming.model === undefined && previous.model !== undefined
      ? { model: previous.model }
      : {}),
    ...(incoming.modelReasoningEffort === undefined &&
    previous.modelReasoningEffort !== undefined
      ? { modelReasoningEffort: previous.modelReasoningEffort }
      : {}),
    ...(incoming.serviceTier === undefined &&
    previous.serviceTier !== undefined
      ? { serviceTier: previous.serviceTier }
      : {}),
    ...(incoming.approvalPolicy === undefined &&
    previous.approvalPolicy !== undefined
      ? { approvalPolicy: previous.approvalPolicy }
      : {}),
    ...(incoming.approvalsReviewer === undefined &&
    previous.approvalsReviewer !== undefined
      ? { approvalsReviewer: previous.approvalsReviewer }
      : {}),
    ...(incoming.sandboxMode === undefined &&
    previous.sandboxMode !== undefined
      ? { sandboxMode: previous.sandboxMode }
      : {}),
    ...(incoming.collaborationMode === undefined &&
    previous.collaborationMode !== undefined
      ? { collaborationMode: previous.collaborationMode }
      : {}),
    ...(incoming.networkAccessEnabled === undefined &&
    previous.networkAccessEnabled !== undefined
      ? { networkAccessEnabled: previous.networkAccessEnabled }
      : {}),
    ...(incoming.webSearchMode === undefined &&
    previous.webSearchMode !== undefined
      ? { webSearchMode: previous.webSearchMode }
      : {}),
    ...(previous.codexSettingsSnapshotComplete === true
      ? { codexSettingsSnapshotComplete: true }
      : {}),
  };
}

function isHighSurrogate(value: number): boolean {
  return value >= 0xd800 && value <= 0xdbff;
}

function isLowSurrogate(value: number): boolean {
  return value >= 0xdc00 && value <= 0xdfff;
}

export function buildConversationSyncCodexCatalogSeed(
  thread: CodexThreadSummary,
  metadata?: CodexSessionIndexMetadata,
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
      ...(metadata?.summary ? { summary: metadata.summary } : {}),
      ...(metadata?.firstPrompt ? { firstPrompt: metadata.firstPrompt } : {}),
      ...catalogSettings(metadata?.codexSettings),
      createdAt,
      modifiedAt,
      recencyAt,
      availability: thread.ephemeral ? "ephemeral" : "durable",
      ...((metadata?.forkedFromThreadId ?? thread.forkedFromThreadId)
        ? {
            forkedFromThreadId:
              metadata?.forkedFromThreadId ?? thread.forkedFromThreadId!,
          }
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

function clientStatusState(
  rawState: string,
  supportsAppServerStatusSemantics: boolean,
): string {
  return `${supportsAppServerStatusSemantics ? APP_SERVER_STATUS_STATE_PREFIX : LEGACY_STATUS_STATE_PREFIX}${rawState}`;
}

function parseClientStatusState(
  state: string,
  supportsAppServerStatusSemantics: boolean,
): { compatible: boolean; rawState: string } {
  const expectedPrefix = supportsAppServerStatusSemantics
    ? APP_SERVER_STATUS_STATE_PREFIX
    : LEGACY_STATUS_STATE_PREFIX;
  if (!state.startsWith(expectedPrefix)) {
    return { compatible: false, rawState: "" };
  }
  const rawState = state.slice(expectedPrefix.length);
  return { compatible: rawState.length > 0, rawState };
}

function sharedControlAuthorityGeneration(
  connectionGeneration: number,
): string {
  return `daemon:${connectionGeneration}`;
}

function sharedControlProviderSnapshotStatus(
  status: ConversationSyncStatus,
  authorityGeneration: string,
): ConversationSyncStatus {
  const {
    executionHost: _executionHost,
    controlState: _controlState,
    authorityGeneration: _authorityGeneration,
    ...rest
  } = status;
  return {
    ...rest,
    executionHost: "unknown",
    controlState: "readOnly",
    authorityGeneration,
  };
}

function sharedControlTransitionStatus(
  previous: ConversationSyncStatus,
  controlState: "reconciling" | "unavailable",
  connectionGeneration: number,
): ConversationSyncStatus {
  const {
    controlState: _controlState,
    authorityGeneration: _authorityGeneration,
    ...rest
  } = previous;
  return {
    ...rest,
    source: "appServer",
    confidence: "unknown",
    controlState,
    ...(controlState === "reconciling"
      ? {
          authorityGeneration:
            sharedControlAuthorityGeneration(connectionGeneration),
        }
      : {}),
  };
}

function sharedControlStatusFromEvent(
  event: SharedRuntimeControlEvent,
  previous: ConversationSyncStatus,
  authorityGeneration: string,
  allowUncorrelatedResolution = false,
): ConversationSyncStatus | null {
  const target: ConversationSyncTarget = {
    provider: "codex",
    providerSessionId: event.threadId!,
  };
  const base = {
    ...target,
    runtimeAttachment: "loaded" as const,
    source: "appServer" as const,
    confidence: "authoritative" as const,
    observedAt: event.observedAt,
    executionHost: "unknown" as const,
    controlState: "readOnly" as const,
    authorityGeneration,
  };
  if (
    event.method === "thread/started" ||
    event.method === "thread/status/changed"
  ) {
    const status = event.threadStatus;
    if (status?.type === "active") {
      const approval =
        status.activeFlags?.includes("waitingOnApproval") ?? false;
      const question =
        status.activeFlags?.includes("waitingOnUserInput") ?? false;
      return {
        ...base,
        activity: "working",
        attention: question ? "question" : approval ? "approval" : "none",
        result: "none",
        ...(previous.activeTurnId
          ? { activeTurnId: previous.activeTurnId }
          : {}),
      };
    }
    if (status?.type === "idle") {
      return {
        ...base,
        activity: "idle",
        attention: "none",
        result: previous.result,
      };
    }
    if (status?.type === "systemError") {
      return {
        ...base,
        activity: "systemError",
        attention: "none",
        result: previous.result,
      };
    }
    if (status?.type === "notLoaded") {
      return {
        ...base,
        activity: "unknown",
        attention: "none",
        result: previous.result,
        runtimeAttachment: "notLoaded",
        confidence: "unknown",
      };
    }
    return {
      ...base,
      activity: "unknown",
      attention: "none",
      result: previous.result,
      confidence: "unknown",
    };
  }
  if (event.method === "turn/started") {
    return {
      ...base,
      activity: "working",
      attention: "none",
      result: "none",
      ...(event.turnId ? { activeTurnId: event.turnId } : {}),
    };
  }
  if (event.method === "turn/completed") {
    const failed = event.turnStatus === "failed";
    const terminal =
      event.turnStatus === "completed" ||
      event.turnStatus === "interrupted" ||
      failed;
    return {
      ...base,
      activity: failed ? "systemError" : terminal ? "idle" : "unknown",
      attention: "none",
      result: failed
        ? "failed"
        : event.turnStatus === "completed"
          ? "completed"
          : previous.result,
      ...(terminal ? {} : event.turnId ? { activeTurnId: event.turnId } : {}),
      ...(terminal ? {} : { confidence: "unknown" as const }),
    };
  }
  if (event.method === "serverRequest/resolved") {
    const resolvedCurrentRequest =
      event.requestId !== undefined &&
      (previous.attentionRequestId !== undefined
        ? previous.attentionRequestId === String(event.requestId)
        : allowUncorrelatedResolution);
    return {
      ...base,
      activity: previous.activity,
      attention: resolvedCurrentRequest ? "none" : previous.attention,
      result: previous.result,
      runtimeAttachment: previous.runtimeAttachment,
      confidence: previous.confidence,
      ...(previous.activeTurnId ? { activeTurnId: previous.activeTurnId } : {}),
      ...(!resolvedCurrentRequest && previous.attentionRequestId
        ? { attentionRequestId: previous.attentionRequestId }
        : {}),
    };
  }
  return null;
}

function statusFromRuntime(
  state: LocalFeatureRuntimeConversationState,
  previous: ConversationSyncStatus,
): ConversationSyncStatus {
  const target = targetFromRuntime(state)!;
  const controlCannotProveRunning =
    state.controlState === "reconciling" ||
    state.controlState === "blocked" ||
    state.controlState === "unavailable";
  const reportedActivity =
    state.processStatus === "starting" ||
    state.processStatus === "running" ||
    state.processStatus === "waiting_approval"
      ? "working"
      : state.processStatus === "compacting"
        ? "compacting"
        : state.processStatus === "idle"
          ? "idle"
          : "unknown";
  const activity = controlCannotProveRunning
    ? previous.activity
    : reportedActivity;
  return {
    ...target,
    activity,
    attention:
      state.pendingAttention?.kind ??
      (controlCannotProveRunning ? previous.attention : "none"),
    result:
      activity === "working" || activity === "compacting"
        ? "none"
        : previous.result,
    runtimeAttachment: "loaded",
    source: "bridgeRuntime",
    confidence: controlCannotProveRunning ? "unknown" : "authoritative",
    observedAt: validIso(state.observedAt)
      ? state.observedAt
      : previous.observedAt,
    ...(state.pendingAttention
      ? { attentionRequestId: state.pendingAttention.requestId }
      : {}),
    ...(state.executionHost ? { executionHost: state.executionHost } : {}),
    ...(state.activeTurnId ? { activeTurnId: state.activeTurnId } : {}),
    ...(state.controlState ? { controlState: state.controlState } : {}),
    ...(state.authorityGeneration
      ? { authorityGeneration: state.authorityGeneration }
      : {}),
  };
}

function hasExplicitRuntimeAuthority(
  state: LocalFeatureRuntimeConversationState,
): boolean {
  return (
    state.executionHost !== undefined ||
    state.activeTurnId !== undefined ||
    state.controlState !== undefined ||
    state.authorityGeneration !== undefined
  );
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

function semanticStatusEqual(
  left: ConversationSyncStatus,
  right: ConversationSyncStatus,
): boolean {
  return (
    stableJson({ ...left, observedAt: "" }) ===
    stableJson({ ...right, observedAt: "" })
  );
}

function statusChangedSinceReadStarted(
  started: ConversationSyncStatus,
  current: ConversationSyncStatus,
): boolean {
  return !semanticStatusEqual(started, current);
}

function providerStatusReadMayReplace(
  started: ConversationSyncStatus,
  current: ConversationSyncStatus,
  candidate: ConversationSyncStatus,
): boolean {
  if (!statusChangedSinceReadStarted(started, current)) return true;
  if (semanticStatusEqual(current, candidate)) return true;
  if (
    current.authorityGeneration !== undefined &&
    candidate.authorityGeneration !== current.authorityGeneration
  ) {
    return false;
  }
  return statusObservedAfter(candidate, current);
}

function unavailableProviderStatus(
  previous: ConversationSyncStatus,
  observedAt: string,
): ConversationSyncStatus {
  const {
    controlState: _controlState,
    authorityGeneration: _authorityGeneration,
    ...rest
  } = previous;
  return {
    ...rest,
    runtimeAttachment: previous.runtimeAttachment,
    source: "appServer",
    confidence: "unknown",
    observedAt: previous.observedAt || observedAt,
    controlState: "unavailable",
  };
}

function isSharedSpecialStatus(status: ConversationSyncStatus): boolean {
  return (
    status.activity === "working" ||
    status.activity === "compacting" ||
    status.activity === "systemError" ||
    status.attention !== "none" ||
    status.result !== "none"
  );
}

function statusNeedsBackgroundDelivery(
  status: ConversationSyncStatus,
): boolean {
  return (
    status.activity === "working" ||
    status.activity === "compacting" ||
    status.attention !== "none"
  );
}

function sameStringSet(
  left: ReadonlySet<string>,
  right: ReadonlySet<string>,
): boolean {
  if (left.size !== right.size) return false;
  for (const value of left) {
    if (!right.has(value)) return false;
  }
  return true;
}

function attentionFromCodexAction(
  request: CodexActionBrokerRuntimeRequest,
): ConversationSyncStatus["attention"] {
  switch (request.kind) {
    case "command_approval":
    case "file_approval":
      return "approval";
    case "permissions_approval":
      return "permission";
    case "user_input":
      return "question";
    case "mcp_elicitation":
    case "tool_suggestion":
      return "form";
    case "current_time":
    case "unknown":
      return "permission";
  }
}

function sharedRecoveryTurnStatus(
  value: unknown,
): SharedControlRecoverySnapshot["status"] {
  return value === "inProgress" ||
    value === "completed" ||
    value === "failed" ||
    value === "interrupted"
    ? value
    : "unknown";
}

function providerTimestampToIso(value: unknown): string | undefined {
  if (typeof value === "string" && validIso(value)) return value;
  if (typeof value !== "number" || !Number.isFinite(value) || value <= 0) {
    return undefined;
  }
  const milliseconds = value < 10_000_000_000 ? value * 1_000 : value;
  const timestamp = new Date(milliseconds).toISOString();
  return validIso(timestamp) ? timestamp : undefined;
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

function trustedProviderActivitySurvivesPassiveRuntime(
  providerStatus: ConversationSyncStatus,
  runtimeStatus: ConversationSyncStatus,
): boolean {
  if (
    runtimeStatus.source !== "bridgeRuntime" ||
    runtimeStatus.activity !== "idle" ||
    runtimeStatus.attention !== "none"
  ) {
    return false;
  }
  const providerIsTrusted =
    (providerStatus.source === "appServer" &&
      providerStatus.confidence === "authoritative") ||
    (providerStatus.source === "legacyRollout" &&
      providerStatus.confidence === "observed");
  return (
    providerIsTrusted &&
    (providerStatus.activity === "working" ||
      providerStatus.activity === "compacting" ||
      providerStatus.attention !== "none")
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

function terminalResultFromServerMessage(
  message: Extract<ServerMessage, { type: "result" }>,
): TerminalResultValue | null {
  const subtype = message.subtype.trim().toLowerCase();
  const explicitFailure =
    Boolean(message.error) || /error|fail/i.test(message.stopReason ?? "");
  if (explicitFailure || subtype === "error" || subtype === "failed") {
    return "failed";
  }
  if (subtype === "success" || subtype === "completed") return "completed";
  // stopped/interrupted/cancelled and future unknown subtypes describe an
  // incomplete or unclassified turn. They must not manufacture completion
  // unread state merely because they are not errors.
  return null;
}

function backgroundProgressCandidate(
  message: ServerMessage,
): Extract<ServerMessage, { type: "assistant" }> | null {
  if (message.type !== "assistant") return null;
  const toolUse = [...message.message.content]
    .reverse()
    .find(
      (content) =>
        content.type === "tool_use" &&
        typeof content.id === "string" &&
        content.id.length > 0 &&
        typeof content.name === "string" &&
        content.name.length > 0,
    );
  if (!toolUse || toolUse.type !== "tool_use") return null;
  return {
    type: "assistant",
    message: {
      id: message.message.id,
      role: "assistant",
      model: "",
      // The background seam deliberately carries no command input, result,
      // transcript text, path, artifact, or raw content block.
      content: [
        {
          type: "tool_use",
          id: toolUse.id,
          name: toolUse.name,
          input: {},
        },
      ],
    },
  };
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

function assistantTextCatalogActivity(
  message: ServerMessage,
  observedAt: string,
): string | undefined {
  if (message.type !== "assistant") return undefined;
  return message.message.content.some(
    (content) => content.type === "text" && content.text.trim().length > 0,
  )
    ? observedAt
    : undefined;
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
  left: readonly [string, unknown],
  right: readonly [string, unknown],
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

function withSourceTimestamp(
  message: ServerMessage,
  sourceTimestamp: string,
  authoritative: boolean,
): ServerMessage {
  if (message.sourceTimestamp && validIso(message.sourceTimestamp)) {
    return message;
  }
  return {
    ...message,
    sourceTimestamp,
    ...(authoritative ? { sourceTimestampIsAuthoritative: true } : {}),
  };
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

function withLiveCatalogMetadata(
  entry: ConversationSyncCatalogEntry,
  observedAt: string,
): ConversationSyncCatalogEntry {
  const modifiedAt = laterIso(entry.modifiedAt, observedAt);
  const recencyAt = laterIso(entry.recencyAt, observedAt);
  if (modifiedAt === entry.modifiedAt && recencyAt === entry.recencyAt) {
    return entry;
  }
  return {
    ...entry,
    modifiedAt,
    recencyAt,
  };
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

function isUnsupportedCodexSourceKindFilter(error: unknown): boolean {
  if (!(error instanceof CodexRpcError) || error.method !== "thread/list") {
    return false;
  }
  if (error.code !== -32602) return false;
  const details = `${error.message} ${JSON.stringify(error.data ?? "")}`;
  return /sourceKinds/i.test(details);
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
