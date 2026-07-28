import { createHash } from "node:crypto";
import { watch, type FSWatcher } from "node:fs";
import { open, stat, type FileHandle } from "node:fs/promises";
import { StringDecoder } from "node:string_decoder";
import type { ServerMessage } from "../../parser.js";
import { resolveCodexSessionJsonlPath } from "../../sessions-index.js";
import {
  describeCodexDesktopToolCall,
  normalizeCodexDesktopToolOutput,
  type CodexDesktopInlineImage,
} from "../codex-tool-history.js";
import type {
  CodexDesktopContinuityClientMessage,
  CodexDesktopContinuityEventMessage,
  CodexDesktopContinuityState,
} from "./codex-desktop-continuity-protocol.js";
import type {
  LocalFeatureHandleContext,
  LocalFeatureHandler,
  LocalFeatureInputAdmission,
  LocalFeatureInputMessage,
  LocalFeatureRuntime,
  LocalFeatureSession,
} from "../runtime.js";

const SERVER_MESSAGE_TYPE = "codex_desktop_continuity_event_v1";
const MAX_MONITORS = 64;
const MAX_WATCHERS = 256;
const MAX_SEED_BYTES = 8 * 1024 * 1024;
const READ_CHUNK_BYTES = 64 * 1024;
const MAX_READ_BYTES_PER_PASS = 4 * 1024 * 1024;
const MAX_LINE_BYTES = 2 * 1024 * 1024;
const MAX_TEXT_BYTES = 256 * 1024;
const MAX_TOOL_INPUT_BYTES = 256 * 1024;
const MAX_DEDUPE_KEYS = 4096;
const MAX_ACTIVE_TURNS = 32;
const MAX_RETIRED_STALE_TURN_IDS = 128;
const MAX_PENDING_ASSISTANT_MESSAGES = 128;
const MAX_RECENT_RESPONSE_ASSISTANTS = 128;
const ASSISTANT_PAIR_TOMBSTONE_MS = 5000;
const ACTIVE_POLL_MS = 750;
const IDLE_POLL_MS = 10_000;
const START_CLASSIFICATION_MS = 100;
const STALE_DESKTOP_PREDECESSOR_MS = 5 * 60 * 1000;
const ASSISTANT_MESSAGE_PAIR_MS = 40;
const REHYDRATE_SETTLE_MS = 350;
const REHYDRATE_RETRY_MS = 750;
const MAX_REHYDRATE_ATTEMPTS = 3;

type TurnOrigin = "desktop" | "local" | null;

interface WatchRegistration {
  client: object;
  requestId: string;
  sessionId: string;
  threadId: string;
}

interface WatchIntent {
  generation: number;
  requestId: string;
  sessionId: string;
  threadId: string;
}

interface MonitorMessageEvent {
  kind: "message";
  itemKey: string;
  turnId?: string;
  timestamp?: string;
  message: ServerMessage;
  /** Bridge-internal only; converted to opaque ImageRefs before sending. */
  imageBase64?: CodexDesktopInlineImage[];
}

interface MonitorStateEvent {
  kind: "state";
  state: "idle" | "running";
  turnId?: string;
  outcome?: "completed" | "interrupted";
  timestamp?: string;
}

export type CodexDesktopContinuityMonitorEvent =
  MonitorMessageEvent | MonitorStateEvent;

interface MonitorSnapshot {
  state: CodexDesktopContinuityState;
  turnId?: string;
}

interface ActiveTurn {
  key: string;
  turnId?: string;
  origin: TurnOrigin;
  timestamp?: string;
  sequence: number;
  pendingStartTimer: ReturnType<typeof setTimeout> | null;
}

type CompletedEventToolType =
  | "mcp_tool_call_end"
  | "patch_apply_end"
  | "web_search_end"
  | "image_generation_end";

interface PendingCompletedTool {
  type: CompletedEventToolType;
  payload: Record<string, unknown>;
  timestamp?: string;
  turnId?: string;
}

interface PendingAssistantMessage {
  key: string;
  turnKey?: string;
  turnId?: string;
  phase: AssistantMessagePhase;
  text: string;
  timestamp?: string;
  timestampMs?: number;
  syntheticId: string;
  timer: ReturnType<typeof setTimeout> | null;
  syntheticEmitted: boolean;
}

interface RecentResponseAssistant {
  key: string;
  turnId?: string;
  phase: AssistantMessagePhase;
  text: string;
  timestampMs?: number;
}

type AssistantMessagePhase = "commentary" | "final" | "unknown";

interface RolloutEntry {
  timestamp?: unknown;
  type?: unknown;
  payload?: unknown;
}

export function createCodexDesktopContinuityHandlers(
  runtime: LocalFeatureRuntime,
): readonly LocalFeatureHandler[] {
  return [new CodexDesktopContinuityHandler(runtime)];
}

export interface CodexDesktopContinuityHandlerOptions {
  resolveRolloutPath?: (threadId: string) => Promise<string | null>;
  rehydrateSettleMs?: number;
  rehydrateRetryMs?: number;
}

export class CodexDesktopContinuityHandler implements LocalFeatureHandler {
  readonly messageTypes = [
    "codex_desktop_continuity_watch",
    "codex_desktop_continuity_unwatch",
  ] as const;

  private readonly monitors = new Map<string, CodexRolloutMonitor>();
  private readonly watchersByClient = new Map<
    object,
    Map<string, WatchRegistration>
  >();
  private readonly watchIntentsByClient = new Map<
    object,
    Map<string, WatchIntent>
  >();
  private watchGeneration = 0;
  private readonly localClientMessageIds = new Map<string, Set<string>>();
  private readonly rehydrateTimers = new Map<
    string,
    ReturnType<typeof setTimeout>
  >();
  private readonly rehydrateInFlight = new Set<string>();
  private readonly rehydrateFailureCounts = new Map<string, number>();
  /** Runtime sessions whose model-visible history trails the durable rollout. */
  private readonly staleRuntimeSessionIds = new Set<string>();
  private readonly blockedDrainSessionIds = new Set<string>();
  private closed = false;

  constructor(
    private readonly runtime: LocalFeatureRuntime,
    private readonly options: CodexDesktopContinuityHandlerOptions = {},
  ) {}

  async handle(
    rawMessage: CodexDesktopContinuityClientMessage,
    context: LocalFeatureHandleContext,
  ): Promise<void> {
    const message = rawMessage as CodexDesktopContinuityClientMessage;
    if (!this.runtime.supports(context.client, SERVER_MESSAGE_TYPE)) {
      this.runtime.send(context.client, {
        type: "error",
        errorCode: "unsupported_capability",
        message: "Codex Desktop continuity capability was not negotiated",
      });
      return;
    }
    if (message.type === "codex_desktop_continuity_unwatch") {
      this.invalidateWatchIntent(
        context.client,
        message.sessionId,
        message.threadId,
        message.requestId,
      );
      this.removeWatch(
        context.client,
        message.sessionId,
        message.threadId,
        message.requestId,
      );
      this.send(context.client, message, { event: "unwatched" });
      return;
    }

    const session = this.validateBinding(message);
    if (!session) {
      this.send(context.client, message, {
        event: "error",
        errorCode: "continuity_binding_mismatch",
        error: "The runtime session no longer owns this Codex thread.",
      });
      return;
    }
    if (
      this.runtime.isProjectPathAllowed &&
      !this.runtime.isProjectPathAllowed(message.projectPath)
    ) {
      this.send(context.client, message, {
        event: "error",
        errorCode: "path_not_allowed",
        error: "The project path is outside the Bridge allowlist.",
      });
      return;
    }
    if (
      this.runtime.isSessionProjectPath &&
      !this.runtime.isSessionProjectPath(session, message.projectPath)
    ) {
      this.send(context.client, message, {
        event: "error",
        errorCode: "continuity_binding_mismatch",
        error: "The claimed project path does not match this runtime session.",
      });
      return;
    }

    const intent = this.beginWatchIntent(context.client, message);

    try {
      const monitor = await this.monitorFor(message.threadId);
      // Resolving and seeding a rollout can await filesystem work. A socket
      // may disappear in that window, so never register a watcher after its
      // controller has already been aborted.
      if (
        this.closed ||
        context.signal.aborted ||
        !this.isCurrentWatchIntent(context.client, intent)
      ) {
        if (context.signal.aborted) {
          this.invalidateWatchIntentIfCurrent(context.client, intent);
        }
        this.disposeMonitorIfUnused(message.threadId, monitor);
        return;
      }
      if (!this.registerWatch(context.client, message, monitor, intent)) {
        this.disposeMonitorIfUnused(message.threadId, monitor);
        return;
      }
      if (this.closed || context.signal.aborted) {
        this.invalidateWatchIntentIfCurrent(context.client, intent);
        this.removeWatch(
          context.client,
          message.sessionId,
          message.threadId,
          message.requestId,
        );
        this.disposeMonitorIfUnused(message.threadId, monitor);
        return;
      }
      const snapshot = monitor.snapshot;
      const handoffQueued =
        snapshot.state === "idle" &&
        ((this.runtime.hasCodexQueuedInput?.(session.id) ?? false) ||
          this.isLocalRuntimeActive(message.threadId));
      if (
        monitor.hasExternalTurn ||
        monitor.needsRehydrateSince(session.createdAt)
      ) {
        remember(this.staleRuntimeSessionIds, session.id, MAX_WATCHERS);
      }
      this.send(context.client, message, {
        event: "watching",
        state: snapshot.state,
        ...(snapshot.turnId ? { turnId: snapshot.turnId } : {}),
        ...(handoffQueued ? { handoffQueued: true } : {}),
      });
      if (
        !monitor.hasBlockingExternalActivity &&
        this.staleRuntimeSessionIds.has(session.id)
      ) {
        this.rehydrateFailureCounts.delete(session.id);
        this.scheduleRehydrate(session.id, message.threadId, snapshot.turnId);
      }
    } catch (error) {
      if (
        this.closed ||
        context.signal.aborted ||
        !this.isCurrentWatchIntent(context.client, intent)
      ) {
        return;
      }
      this.invalidateWatchIntentIfCurrent(context.client, intent);
      this.send(context.client, message, {
        event: "error",
        errorCode: "rollout_unavailable",
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }

  admitInput(
    client: object,
    session: LocalFeatureSession,
    _message: LocalFeatureInputMessage,
  ): LocalFeatureInputAdmission | null | Promise<LocalFeatureInputAdmission> {
    if (
      session.provider !== "codex" ||
      !this.runtime.supports(client, SERVER_MESSAGE_TYPE)
    ) {
      return null;
    }
    return this.admitSupportedInput(session);
  }

  private async admitSupportedInput(
    session: LocalFeatureSession,
  ): Promise<LocalFeatureInputAdmission> {
    const threadId = this.runtime.getCodexThreadId(session);
    if (!threadId) return { action: "allow" };
    let monitor: CodexRolloutMonitor;
    try {
      monitor = await this.monitorFor(threadId);
      await monitor.refreshNow();
    } catch {
      // Fail open for old/non-durable Codex sessions. The normal Bridge input
      // path remains authoritative when no rollout can be resolved.
      return { action: "allow" };
    }
    if (monitor.hasBlockingExternalActivity) {
      remember(this.staleRuntimeSessionIds, session.id, MAX_WATCHERS);
      return { action: "queue", reason: "desktop_turn_active" };
    }
    if (
      this.staleRuntimeSessionIds.has(session.id) ||
      monitor.needsRehydrateSince(session.createdAt)
    ) {
      remember(this.staleRuntimeSessionIds, session.id, MAX_WATCHERS);
      if (
        (this.rehydrateFailureCounts.get(session.id) ?? 0) >=
        MAX_REHYDRATE_ATTEMPTS
      ) {
        this.rehydrateFailureCounts.delete(session.id);
      }
      this.scheduleRehydrate(session.id, threadId, monitor.snapshot.turnId);
      return { action: "queue", reason: "desktop_history_refreshing" };
    }
    return { action: "allow" };
  }

  inputAccepted(
    _client: object,
    session: LocalFeatureSession,
    message: LocalFeatureInputMessage,
    queued: boolean,
  ): void {
    if (session.provider !== "codex" || !message.clientMessageId) return;
    const threadId = this.runtime.getCodexThreadId(session);
    if (!threadId) return;
    const ids = this.localClientMessageIds.get(threadId) ?? new Set<string>();
    ids.add(message.clientMessageId);
    while (ids.size > 32) ids.delete(ids.values().next().value!);
    setBoundedMap(this.localClientMessageIds, threadId, ids, MAX_MONITORS);
    if (
      queued &&
      this.monitors.get(threadId)?.hasBlockingExternalActivity === false &&
      !this.staleRuntimeSessionIds.has(session.id) &&
      !this.rehydrateInFlight.has(session.id)
    ) {
      this.runtime.drainCodexQueuedInputIfReady?.(session.id);
    }
  }

  admitCodexQueuedInputDrain(session: LocalFeatureSession): boolean {
    if (session.provider !== "codex") return true;
    const threadId = this.runtime.getCodexThreadId(session);
    if (!threadId) return true;
    // Session-level stale/in-flight fences outlive a watcher and its monitor.
    // Check them first so disconnect/unwatch cannot reopen the ordinary
    // input_ready drain path before a reconnect performs canonical rehydrate.
    if (
      this.staleRuntimeSessionIds.has(session.id) ||
      this.rehydrateInFlight.has(session.id)
    ) {
      return false;
    }
    const monitor = this.monitors.get(threadId);
    if (!monitor) return true;
    if (monitor.hasBlockingExternalActivity) return false;
    if (monitor.needsRehydrateSince(session.createdAt)) {
      remember(this.staleRuntimeSessionIds, session.id, MAX_WATCHERS);
    }
    return (
      !this.staleRuntimeSessionIds.has(session.id) &&
      !this.rehydrateInFlight.has(session.id)
    );
  }

  codexQueuedInputDrainBlocked(session: LocalFeatureSession): void {
    if (session.provider !== "codex") return;
    const threadId = this.runtime.getCodexThreadId(session);
    if (!threadId) return;
    remember(this.blockedDrainSessionIds, session.id, MAX_WATCHERS);
    if (this.rehydrateInFlight.has(session.id)) {
      remember(this.staleRuntimeSessionIds, session.id, MAX_WATCHERS);
    }
    const monitor = this.monitors.get(threadId);
    if (!monitor) return;
    if (monitor.hasExternalTurn) {
      remember(this.staleRuntimeSessionIds, session.id, MAX_WATCHERS);
    }
    if (
      monitor.hasBlockingExternalActivity ||
      this.rehydrateInFlight.has(session.id)
    ) {
      return;
    }
    if (monitor.needsRehydrateSince(session.createdAt)) {
      remember(this.staleRuntimeSessionIds, session.id, MAX_WATCHERS);
    }
    if (this.staleRuntimeSessionIds.has(session.id)) {
      this.scheduleRehydrate(session.id, threadId, monitor.snapshot.turnId, 0);
    }
  }

  externalCodexTurnId(session: LocalFeatureSession): string | undefined {
    if (session.provider !== "codex") return undefined;
    const threadId = this.runtime.getCodexThreadId(session);
    if (!threadId) return undefined;
    const monitor = this.monitors.get(threadId);
    return monitor?.externalTurnIdForSteering;
  }

  /** Distinguishes ambiguous Desktop activity from an ordinary local turn. */
  hasExternalCodexActivity(session: LocalFeatureSession): boolean {
    if (session.provider !== "codex") return false;
    const threadId = this.runtime.getCodexThreadId(session);
    if (!threadId) return false;
    return this.monitors.get(threadId)?.hasBlockingExternalActivity ?? false;
  }

  disconnect(client: object): void {
    this.watchIntentsByClient.delete(client);
    const registrations = this.watchersByClient.get(client);
    if (registrations) {
      for (const registration of registrations.values()) {
        const monitor = this.monitors.get(registration.threadId);
        monitor?.removeWatcher(registration);
        if (monitor) {
          this.disposeMonitorIfUnused(registration.threadId, monitor);
        }
      }
      this.watchersByClient.delete(client);
    }
  }

  close(): void {
    this.closed = true;
    for (const timer of this.rehydrateTimers.values()) clearTimeout(timer);
    this.rehydrateTimers.clear();
    for (const monitor of this.monitors.values()) monitor.close();
    this.monitors.clear();
    this.watchersByClient.clear();
    this.watchIntentsByClient.clear();
    this.localClientMessageIds.clear();
    this.staleRuntimeSessionIds.clear();
    this.blockedDrainSessionIds.clear();
    this.rehydrateFailureCounts.clear();
    this.rehydrateInFlight.clear();
  }

  private validateBinding(
    message: Extract<
      CodexDesktopContinuityClientMessage,
      { type: "codex_desktop_continuity_watch" }
    >,
  ): LocalFeatureSession | null {
    const session = this.runtime.getSession(message.sessionId);
    if (!session || session.provider !== "codex") return null;
    return this.runtime.getCodexThreadId(session) === message.threadId
      ? session
      : null;
  }

  private async monitorFor(threadId: string): Promise<CodexRolloutMonitor> {
    const existing = this.monitors.get(threadId);
    if (existing) return existing;
    if (this.monitors.size >= MAX_MONITORS) {
      const idle = [...this.monitors.entries()].find(
        ([, monitor]) => monitor.watcherCount === 0,
      );
      if (!idle) throw new Error("Too many Codex Desktop continuity monitors");
      idle[1].close();
      this.monitors.delete(idle[0]);
    }
    const path = await (
      this.options.resolveRolloutPath ?? resolveCodexSessionJsonlPath
    )(threadId);
    if (this.closed) throw new Error("Continuity handler is closed");
    if (!path) throw new Error(`No durable rollout found for ${threadId}`);
    const racedBeforeStart = this.monitors.get(threadId);
    if (racedBeforeStart) return racedBeforeStart;
    const monitor = new CodexRolloutMonitor({
      threadId,
      path,
      getLocalActiveTurnId: () =>
        this.runtime.getLocallyActiveCodexTurnId?.(threadId),
      consumeLocalClientMessageId: (clientMessageId) =>
        this.consumeLocalClientMessageId(threadId, clientMessageId),
      onEvent: (event) => this.onMonitorEvent(threadId, event),
      onLocalOwnershipSettled: () =>
        this.onMonitorLocalOwnershipSettled(threadId),
    });
    try {
      await monitor.start();
    } catch (error) {
      monitor.close();
      throw error;
    }
    const racedAfterStart = this.monitors.get(threadId);
    if (racedAfterStart) {
      monitor.close();
      return racedAfterStart;
    }
    if (this.closed) {
      monitor.close();
      throw new Error("Continuity handler is closed");
    }
    this.monitors.set(threadId, monitor);
    return monitor;
  }

  private isLocalRuntimeActive(threadId: string): boolean {
    if (this.runtime.isCodexThreadLocallyActive?.(threadId)) return true;
    for (const registrations of this.watchersByClient.values()) {
      for (const registration of registrations.values()) {
        if (registration.threadId !== threadId) continue;
        const process = this.runtime.getSession(registration.sessionId)
          ?.process as { isWaitingForInput?: boolean } | undefined;
        if (process?.isWaitingForInput === false) return true;
      }
    }
    return false;
  }

  private consumeLocalClientMessageId(
    threadId: string,
    clientMessageId: string,
  ): boolean {
    const ids = this.localClientMessageIds.get(threadId);
    if (!ids?.delete(clientMessageId)) return false;
    if (ids.size === 0) this.localClientMessageIds.delete(threadId);
    return true;
  }

  private registerWatch(
    client: object,
    message: Extract<
      CodexDesktopContinuityClientMessage,
      { type: "codex_desktop_continuity_watch" }
    >,
    monitor: CodexRolloutMonitor,
    intent: WatchIntent,
  ): boolean {
    if (!this.isCurrentWatchIntent(client, intent)) return false;
    let registrations = this.watchersByClient.get(client);
    const previous = registrations?.get(message.sessionId);
    if (!previous && this.totalWatcherCount >= MAX_WATCHERS) {
      throw new Error("Too many Codex Desktop continuity watchers");
    }
    if (!registrations) {
      registrations = new Map();
      this.watchersByClient.set(client, registrations);
    }
    if (previous) {
      const previousMonitor = this.monitors.get(previous.threadId);
      previousMonitor?.removeWatcher(previous);
      if (previousMonitor && previousMonitor !== monitor) {
        this.disposeMonitorIfUnused(previous.threadId, previousMonitor);
      }
    }
    const registration: WatchRegistration = {
      client,
      requestId: message.requestId,
      sessionId: message.sessionId,
      threadId: message.threadId,
    };
    registrations.set(message.sessionId, registration);
    monitor.addWatcher(registration);
    return true;
  }

  private removeWatch(
    client: object,
    sessionId: string,
    threadId: string,
    requestId: string,
  ): void {
    const registrations = this.watchersByClient.get(client);
    const registration = registrations?.get(sessionId);
    if (
      !registration ||
      registration.threadId !== threadId ||
      registration.requestId !== requestId
    ) {
      return;
    }
    registrations!.delete(sessionId);
    if (registrations!.size === 0) this.watchersByClient.delete(client);
    const monitor = this.monitors.get(threadId);
    monitor?.removeWatcher(registration);
    if (monitor) this.disposeMonitorIfUnused(threadId, monitor);
  }

  private beginWatchIntent(
    client: object,
    message: Extract<
      CodexDesktopContinuityClientMessage,
      { type: "codex_desktop_continuity_watch" }
    >,
  ): WatchIntent {
    const intent: WatchIntent = {
      generation: ++this.watchGeneration,
      requestId: message.requestId,
      sessionId: message.sessionId,
      threadId: message.threadId,
    };
    const intents =
      this.watchIntentsByClient.get(client) ?? new Map<string, WatchIntent>();
    intents.set(message.sessionId, intent);
    this.watchIntentsByClient.set(client, intents);
    return intent;
  }

  private isCurrentWatchIntent(client: object, intent: WatchIntent): boolean {
    return (
      this.watchIntentsByClient.get(client)?.get(intent.sessionId) === intent
    );
  }

  private invalidateWatchIntent(
    client: object,
    sessionId: string,
    threadId: string,
    requestId: string,
  ): void {
    const intents = this.watchIntentsByClient.get(client);
    const intent = intents?.get(sessionId);
    if (
      !intent ||
      intent.threadId !== threadId ||
      intent.requestId !== requestId
    ) {
      return;
    }
    intents!.delete(sessionId);
    if (intents!.size === 0) this.watchIntentsByClient.delete(client);
  }

  private invalidateWatchIntentIfCurrent(
    client: object,
    intent: WatchIntent,
  ): void {
    if (!this.isCurrentWatchIntent(client, intent)) return;
    this.invalidateWatchIntent(
      client,
      intent.sessionId,
      intent.threadId,
      intent.requestId,
    );
  }

  private disposeMonitorIfUnused(
    threadId: string,
    monitor: CodexRolloutMonitor,
  ): void {
    if (
      monitor.watcherCount !== 0 ||
      this.monitors.get(threadId) !== monitor ||
      this.hasCurrentWatchIntentForThread(threadId)
    ) {
      return;
    }
    monitor.close();
    this.monitors.delete(threadId);
  }

  private hasCurrentWatchIntentForThread(threadId: string): boolean {
    for (const intents of this.watchIntentsByClient.values()) {
      for (const intent of intents.values()) {
        if (intent.threadId === threadId) return true;
      }
    }
    return false;
  }

  private get totalWatcherCount(): number {
    let count = 0;
    for (const registrations of this.watchersByClient.values()) {
      count += registrations.size;
    }
    return count;
  }

  private onMonitorEvent(
    threadId: string,
    event: CodexDesktopContinuityMonitorEvent,
  ): void {
    const monitor = this.monitors.get(threadId);
    if (!monitor) return;
    const registrations = monitor.watchers;
    if (event.kind === "state") {
      for (const registration of registrations) {
        remember(
          this.staleRuntimeSessionIds,
          registration.sessionId,
          MAX_WATCHERS,
        );
        if (event.state === "running") {
          this.rehydrateFailureCounts.delete(registration.sessionId);
        }
      }
    }
    let message =
      event.kind === "message" ? event.message : undefined;
    if (
      event.kind === "message" &&
      message?.type === "tool_result" &&
      event.imageBase64 &&
      event.imageBase64.length > 0
    ) {
      const images = this.runtime.registerInlineImages?.(event.imageBase64) ?? [];
      if (images.length > 0) {
        const existing = message.images ?? [];
        const merged = new Map(existing.map((image) => [image.id, image]));
        for (const image of images) merged.set(image.id, image);
        message = { ...message, images: [...merged.values()] };
      }
    }
    for (const registration of registrations) {
      if (!this.runtime.supports(registration.client, SERVER_MESSAGE_TYPE)) {
        continue;
      }
      if (event.kind === "message") {
        this.runtime.send(registration.client, {
          ...this.eventBase(registration),
          event: "message",
          itemKey: event.itemKey,
          ...(event.turnId ? { turnId: event.turnId } : {}),
          ...(event.timestamp ? { timestamp: event.timestamp } : {}),
          message: message ?? event.message,
        });
      } else {
        const handoffQueued =
          event.state === "idle" &&
          ((this.runtime.hasCodexQueuedInput?.(registration.sessionId) ??
            false) ||
            this.isLocalRuntimeActive(threadId));
        this.runtime.send(registration.client, {
          ...this.eventBase(registration),
          event: "state",
          state: event.state,
          ...(event.turnId ? { turnId: event.turnId } : {}),
          ...(event.outcome ? { outcome: event.outcome } : {}),
          ...(event.timestamp ? { timestamp: event.timestamp } : {}),
          ...(handoffQueued ? { handoffQueued: true } : {}),
        });
      }
    }
    if (event.kind === "state" && event.state === "idle") {
      const sessionIds = new Set(
        registrations.map((registration) => registration.sessionId),
      );
      for (const sessionId of sessionIds) {
        this.scheduleRehydrate(sessionId, threadId, event.turnId);
      }
    }
  }

  private onMonitorLocalOwnershipSettled(threadId: string): void {
    const sessionIds = new Set(this.blockedDrainSessionIds);
    const monitor = this.monitors.get(threadId);
    for (const registration of monitor?.watchers ?? []) {
      sessionIds.add(registration.sessionId);
    }
    for (const sessionId of sessionIds) {
      const session = this.runtime.getSession(sessionId);
      if (!session) {
        this.blockedDrainSessionIds.delete(sessionId);
        continue;
      }
      if (this.runtime.getCodexThreadId(session) !== threadId) continue;
      if (!this.admitCodexQueuedInputDrain(session)) continue;
      const drained = this.runtime.drainCodexQueuedInputIfReady?.(sessionId);
      if (drained || !(this.runtime.hasCodexQueuedInput?.(sessionId) ?? false)) {
        this.blockedDrainSessionIds.delete(sessionId);
      }
    }
  }

  private scheduleRehydrate(
    sessionId: string,
    threadId: string,
    completedTurnId?: string,
    delayMs = this.options.rehydrateSettleMs ?? REHYDRATE_SETTLE_MS,
  ): void {
    if (this.closed) return;
    const prior = this.rehydrateTimers.get(sessionId);
    if (prior) clearTimeout(prior);
    if (!prior && this.rehydrateTimers.size >= MAX_WATCHERS) {
      const oldestSessionId = this.rehydrateTimers.keys().next().value;
      if (oldestSessionId) {
        clearTimeout(this.rehydrateTimers.get(oldestSessionId)!);
        this.rehydrateTimers.delete(oldestSessionId);
      }
    }
    const timer = setTimeout(() => {
      this.rehydrateTimers.delete(sessionId);
      void this.rehydrate(sessionId, threadId, completedTurnId);
    }, delayMs);
    timer.unref?.();
    this.rehydrateTimers.set(sessionId, timer);
  }

  private async rehydrate(
    sessionId: string,
    threadId: string,
    completedTurnId?: string,
  ): Promise<void> {
    if (this.closed || this.rehydrateInFlight.has(sessionId)) return;
    const monitor = this.monitors.get(threadId);
    if (!monitor) return;
    try {
      // input_ready can beat fs.watch delivery. Establish the epoch only after
      // consuming every durable lifecycle event already on disk.
      await monitor.refreshNow();
    } catch {
      this.retryOrReportRehydrateFailure(
        monitor,
        sessionId,
        threadId,
        completedTurnId,
      );
      return;
    }
    if (
      this.closed ||
      this.rehydrateInFlight.has(sessionId) ||
      monitor.hasBlockingExternalActivity
    ) {
      return;
    }
    if (
      completedTurnId &&
      monitor.snapshot.turnId &&
      monitor.snapshot.turnId !== completedTurnId
    ) {
      return;
    }
    const session = this.runtime.getSession(sessionId);
    if (!session || this.runtime.getCodexThreadId(session) !== threadId) {
      this.staleRuntimeSessionIds.delete(sessionId);
      this.rehydrateFailureCounts.delete(sessionId);
      return;
    }
    const process = session.process as { isWaitingForInput?: boolean };
    if (process.isWaitingForInput === false) {
      // The local turn still owns this runtime. Keep the stale fence and let
      // the generic input_ready drain guard wake a fresh rehydrate attempt;
      // otherwise a queued handoff could bypass Desktop history calibration.
      remember(this.blockedDrainSessionIds, sessionId, MAX_WATCHERS);
      return;
    }
    const rehydrate = this.runtime.rehydrateCodexSessionAfterExternalTurn;
    if (!rehydrate) return;
    const activityEpoch = monitor.activityEpoch;
    const isStillSafe = (): boolean =>
      !this.closed &&
      this.monitors.get(threadId) === monitor &&
      monitor.activityEpoch === activityEpoch &&
      !monitor.hasBlockingExternalActivity;
    this.rehydrateInFlight.add(sessionId);
    try {
      const ok = await rehydrate(sessionId, threadId, isStillSafe);
      if (ok) await monitor.refreshNow();
      if (!isStillSafe()) return;
      if (ok) {
        this.staleRuntimeSessionIds.delete(sessionId);
        this.rehydrateFailureCounts.delete(sessionId);
        // The atomic replacement and post-refresh fence are complete. Release
        // the in-flight drain gate synchronously before promoting the queue;
        // finally still performs idempotent cleanup on every exit path.
        this.rehydrateInFlight.delete(sessionId);
        this.sendHistoryReady(
          monitor,
          sessionId,
          completedTurnId ?? monitor.snapshot.turnId,
        );
        // The queue may have been accepted just after the replacement emitted
        // input_ready. Recheck once after the atomic refresh so that race does
        // not leave the phone handoff stuck until another turn completes.
        const drained = this.runtime.drainCodexQueuedInputIfReady?.(
          sessionId,
          isStillSafe,
        );
        if (
          drained ||
          !(this.runtime.hasCodexQueuedInput?.(sessionId) ?? false)
        ) {
          this.blockedDrainSessionIds.delete(sessionId);
        }
      } else {
        this.retryOrReportRehydrateFailure(
          monitor,
          sessionId,
          threadId,
          completedTurnId,
        );
      }
    } catch {
      this.retryOrReportRehydrateFailure(
        monitor,
        sessionId,
        threadId,
        completedTurnId,
      );
    } finally {
      this.rehydrateInFlight.delete(sessionId);
    }
  }

  private sendHistoryReady(
    monitor: CodexRolloutMonitor,
    sessionId: string,
    turnId?: string,
  ): void {
    for (const registration of monitor.watchers) {
      if (registration.sessionId !== sessionId) continue;
      const handoffQueued =
        (this.runtime.hasCodexQueuedInput?.(sessionId) ?? false) ||
        this.isLocalRuntimeActive(registration.threadId);
      this.runtime.send(registration.client, {
        ...this.eventBase(registration),
        event: "state",
        state: "idle",
        historyReady: true,
        ...(turnId ? { turnId } : {}),
        ...(handoffQueued ? { handoffQueued: true } : {}),
      });
    }
  }

  private retryOrReportRehydrateFailure(
    monitor: CodexRolloutMonitor,
    sessionId: string,
    threadId: string,
    completedTurnId?: string,
  ): void {
    if (this.closed) return;
    const failures = (this.rehydrateFailureCounts.get(sessionId) ?? 0) + 1;
    setBoundedMap(
      this.rehydrateFailureCounts,
      sessionId,
      failures,
      MAX_WATCHERS,
    );
    if (failures < MAX_REHYDRATE_ATTEMPTS && !this.closed) {
      this.scheduleRehydrate(
        sessionId,
        threadId,
        completedTurnId,
        (this.options.rehydrateRetryMs ?? REHYDRATE_RETRY_MS) * failures,
      );
      return;
    }
    this.sendRehydrateError(monitor, sessionId, threadId);
  }

  private sendRehydrateError(
    monitor: CodexRolloutMonitor,
    sessionId: string,
    threadId: string,
  ): void {
    for (const registration of monitor.watchers) {
      if (registration.sessionId !== sessionId) continue;
      this.runtime.send(registration.client, {
        ...this.eventBase(registration),
        event: "error",
        errorCode: "runtime_rehydrate_failed",
        error:
          "Desktop output was synchronized, but the Bridge runtime could not be refreshed safely.",
      });
    }
  }

  private send(
    client: object,
    request: CodexDesktopContinuityClientMessage,
    event:
      | {
          event: "watching";
          state: CodexDesktopContinuityState;
          turnId?: string;
          handoffQueued?: boolean;
        }
      | { event: "unwatched" }
      | { event: "error"; errorCode: string; error: string },
  ): void {
    this.runtime.send(client, {
      type: SERVER_MESSAGE_TYPE,
      requestId: request.requestId,
      bridgeInstanceId: this.runtime.bridgeInstanceId ?? "bridge-local",
      sessionId: request.sessionId,
      threadId: request.threadId,
      origin: "desktop_rollout",
      ...event,
    } as CodexDesktopContinuityEventMessage);
  }

  private eventBase(registration: WatchRegistration) {
    return {
      type: "codex_desktop_continuity_event_v1" as const,
      requestId: registration.requestId,
      bridgeInstanceId: this.runtime.bridgeInstanceId ?? "bridge-local",
      sessionId: registration.sessionId,
      threadId: registration.threadId,
      origin: "desktop_rollout" as const,
    };
  }
}

export interface CodexRolloutMonitorOptions {
  threadId: string;
  path: string;
  /** Exact locally owned turn; generic runtime activity is not attribution. */
  getLocalActiveTurnId: () => string | undefined;
  consumeLocalClientMessageId: (clientMessageId: string) => boolean;
  onEvent: (event: CodexDesktopContinuityMonitorEvent) => void;
  /** Internal wake-up when an unpublished provisional turn proves local. */
  onLocalOwnershipSettled?: () => void;
  assistantMessagePairMs?: number;
}

export class CodexRolloutMonitor {
  readonly watchers: WatchRegistration[] = [];
  private file: FileHandle | null = null;
  private fsWatcher: FSWatcher | null = null;
  private pollTimer: ReturnType<typeof setTimeout> | null = null;
  private refreshPromise: Promise<void> | null = null;
  private refreshAgain = false;
  private offset = 0;
  private decoder = new StringDecoder("utf8");
  private lineBuffer = "";
  private discardingLongLine = false;
  private state: CodexDesktopContinuityState = "unknown";
  private readonly activeTurns = new Map<string, ActiveTurn>();
  private readonly retiredStaleDesktopTurnIds = new Set<string>();
  private turnSequence = 0;
  private lastObservedTurnId: string | undefined;
  private readonly pendingAssistantMessages = new Map<
    string,
    PendingAssistantMessage
  >();
  private readonly recentResponseAssistants = new Map<
    string,
    RecentResponseAssistant
  >();
  private assistantMessageSequence = 0;
  private readonly emittedKeys = new Set<string>();
  private readonly reasoningKeys = new Set<string>();
  private readonly toolNames = new Map<string, string>();
  /** Maps transport call ids to the canonical item ids used by history. */
  private readonly toolIdAliases = new Map<string, string>();
  /** Lets an adjacent response item establish the canonical id first. */
  private readonly pendingCompletedTools = new Map<
    string,
    PendingCompletedTool
  >();
  private lastExternalTerminalTimestampMs: number | undefined;
  private activityEpochValue = 0;
  private closed = false;

  constructor(private readonly options: CodexRolloutMonitorOptions) {}

  get watcherCount(): number {
    return this.watchers.length;
  }

  /** Changes whenever live lifecycle/ownership evidence changes. */
  get activityEpoch(): number {
    return this.activityEpochValue;
  }

  get snapshot(): MonitorSnapshot {
    const externalTurn = this.latestExternalTurn();
    if (externalTurn) {
      return {
        state: "running",
        ...(externalTurn.turnId ? { turnId: externalTurn.turnId } : {}),
      };
    }
    if (this.hasUnclassifiedTurn) {
      return { state: "unknown" };
    }
    if (this.activeTurns.size > 0) {
      return { state: "idle" };
    }
    return {
      state: this.state,
      ...(this.lastObservedTurnId ? { turnId: this.lastObservedTurnId } : {}),
    };
  }

  get hasExternalTurn(): boolean {
    return this.latestExternalTurn() !== undefined;
  }

  /** Admission/drain fails closed while ownership is not yet proven. */
  get hasBlockingExternalActivity(): boolean {
    return this.hasExternalTurn || this.hasUnclassifiedTurn;
  }

  private get hasUnclassifiedTurn(): boolean {
    return [...this.activeTurns.values()].some((turn) => turn.origin === null);
  }

  get externalTurnIdForSteering(): string | undefined {
    const externalTurns = [...this.activeTurns.values()].filter(
      (turn) => turn.origin === "desktop",
    );
    return externalTurns.length === 1 ? externalTurns[0].turnId : undefined;
  }

  needsRehydrateSince(createdAt?: Date): boolean {
    return (
      createdAt instanceof Date &&
      Number.isFinite(createdAt.getTime()) &&
      this.lastExternalTerminalTimestampMs !== undefined &&
      this.lastExternalTerminalTimestampMs > createdAt.getTime()
    );
  }

  async start(): Promise<void> {
    this.file = await open(this.options.path, "r");
    await this.seed();
    try {
      this.fsWatcher = watch(this.options.path, () => this.scheduleRefresh());
      this.fsWatcher.on("error", () => {
        this.fsWatcher?.close();
        this.fsWatcher = null;
      });
    } catch {
      this.fsWatcher = null;
    }
    this.resetFallbackPoll();
  }

  addWatcher(registration: WatchRegistration): void {
    if (!this.watchers.includes(registration)) this.watchers.push(registration);
  }

  removeWatcher(registration: WatchRegistration): void {
    const index = this.watchers.indexOf(registration);
    if (index >= 0) this.watchers.splice(index, 1);
  }

  async refreshNow(): Promise<void> {
    if (this.closed) return;
    if (this.refreshPromise) {
      this.refreshAgain = true;
      await this.refreshPromise;
      return;
    }
    const refresh = this.refreshLoop();
    this.refreshPromise = refresh;
    try {
      await refresh;
    } finally {
      if (this.refreshPromise === refresh) {
        this.refreshPromise = null;
        this.resetFallbackPoll();
      }
    }
  }

  close(): void {
    this.closed = true;
    this.clearActiveTurns();
    this.clearAssistantPairing();
    this.emittedKeys.clear();
    this.reasoningKeys.clear();
    this.toolNames.clear();
    this.toolIdAliases.clear();
    this.pendingCompletedTools.clear();
    this.refreshAgain = false;
    if (this.pollTimer) clearTimeout(this.pollTimer);
    this.pollTimer = null;
    this.fsWatcher?.close();
    this.fsWatcher = null;
    this.watchers.splice(0);
    void this.file?.close().catch(() => {});
    this.file = null;
  }

  private scheduleRefresh(): void {
    if (this.closed) return;
    void this.refreshNow().catch(() => {});
  }

  private resetFallbackPoll(): void {
    if (this.pollTimer) clearTimeout(this.pollTimer);
    this.pollTimer = null;
    if (this.closed) return;
    // fs.watch is the primary low-latency path. Polling only recovers missed
    // filesystem notifications, so idle rollouts can use a much slower cadence
    // while running or ownership-unknown turns retain the existing 750 ms bound.
    const delayMs =
      this.snapshot.state === "idle" ? IDLE_POLL_MS : ACTIVE_POLL_MS;
    const timer = setTimeout(() => {
      if (this.pollTimer !== timer) return;
      this.pollTimer = null;
      this.scheduleRefresh();
    }, delayMs);
    this.pollTimer = timer;
    timer.unref?.();
  }

  private async refreshLoop(): Promise<void> {
    do {
      this.refreshAgain = false;
      await this.readPass();
    } while (this.refreshAgain && !this.closed);
  }

  private async seed(): Promise<void> {
    const info = await stat(this.options.path);
    const start = Math.max(0, info.size - MAX_SEED_BYTES);
    const length = info.size - start;
    const buffer = Buffer.alloc(length);
    const { bytesRead } = await this.file!.read(buffer, 0, length, start);
    let text = buffer.subarray(0, bytesRead).toString("utf8");
    let truncatedActiveLine = false;
    if (start > 0) {
      const firstNewline = text.indexOf("\n");
      if (firstNewline >= 0) {
        text = text.slice(firstNewline + 1);
      } else {
        // The seed window is wholly inside one oversized/incomplete item.
        // Treat the thread as active until a future newline lets us observe a
        // terminal event; never accept a competing mobile turn on uncertainty.
        text = "";
        truncatedActiveLine = true;
        this.discardingLongLine = true;
      }
    }
    this.seedLifecycle(text.split("\n"), info.mtimeMs, truncatedActiveLine);
    this.offset = info.size;
  }

  private seedLifecycle(
    lines: string[],
    fileModifiedAtMs: number,
    truncatedActiveLine: boolean,
  ): void {
    this.resetObservedState();
    let sawActivity = truncatedActiveLine;
    let sawLifecycle = truncatedActiveLine;
    let sawExternalTerminalWithoutTimestamp = false;
    if (truncatedActiveLine) {
      this.addActiveTurn(undefined, "desktop", undefined, false);
    }
    for (const line of lines) {
      if (!line || line.length > MAX_LINE_BYTES) continue;
      let entry: RolloutEntry;
      try {
        entry = JSON.parse(line) as RolloutEntry;
      } catch {
        continue;
      }
      if (entry.type !== "event_msg" && entry.type !== "response_item") {
        continue;
      }
      sawActivity = true;
      const payload = asRecord(entry.payload);
      if (!payload) continue;
      const timestampMs = parseTimestampMs(entry.timestamp);
      if (entry.type === "response_item") {
        this.reconcileSeedResponseTurn(payload, timestampMs);
        continue;
      }
      const type = payload.type;
      if (type === "task_started") {
        sawLifecycle = true;
        const turnId = rolloutTurnId(payload);
        this.addActiveTurn(
          turnId,
          this.isExactlyLocalTurn(turnId) ? "local" : null,
          optionalString(entry.timestamp),
          false,
        );
      } else if (type === "user_message") {
        const clientMessageId = optionalString(payload.client_id);
        const hasLocalClientIdentity =
          clientMessageId !== undefined &&
          this.options.consumeLocalClientMessageId(clientMessageId);
        const turn = this.turnForUserMessage(payload);
        if (turn) {
          if (hasLocalClientIdentity) {
            // A guide echo may arrive after a Desktop turn was already
            // classified. Suppress that echo, but never rewrite proven
            // Desktop ownership to local.
            const exactLocalTurn = this.exactLocalActiveTurn();
            if (!exactLocalTurn || exactLocalTurn === turn) {
              if (turn.origin === null) turn.origin = "local";
            }
          } else if (turn.origin === null) {
            if (this.isExactlyLocalTurn(turn.turnId)) {
              turn.origin = "local";
            } else if (clientMessageId !== undefined) {
              turn.origin = "desktop";
            }
          }
          if (turn.origin === "desktop") {
            this.retireStaleDesktopPredecessors(turn, timestampMs);
          }
        }
      } else if (type === "task_complete" || type === "turn_aborted") {
        sawLifecycle = true;
        const turnId = rolloutTurnId(payload);
        if (turnId && this.retiredStaleDesktopTurnIds.delete(turnId)) {
          continue;
        }
        const candidate = this.turnForCompletion(turnId);
        const completed = candidate ? this.takeActiveTurn(candidate) : undefined;
        const origin = completed?.origin ?? "desktop";
        this.lastObservedTurnId = turnId ?? completed?.turnId;
        if (origin === "desktop" && timestampMs !== undefined) {
          this.lastExternalTerminalTimestampMs = timestampMs;
        } else if (origin === "desktop") {
          sawExternalTerminalWithoutTimestamp = true;
        }
      } else if (type === "thread_rolled_back") {
        sawLifecycle = true;
        this.clearExternalTurns();
        this.lastObservedTurnId = undefined;
        if (timestampMs !== undefined) {
          this.lastExternalTerminalTimestampMs = timestampMs;
        } else {
          sawExternalTerminalWithoutTimestamp = true;
        }
      }
    }
    if (sawActivity && !sawLifecycle && this.activeTurns.size === 0) {
      this.addActiveTurn(undefined, "desktop", undefined, false);
    }
    for (const turn of this.activeTurns.values()) {
      if (turn.origin === null) {
        turn.origin = this.isExactlyLocalTurn(turn.turnId)
          ? "local"
          : "desktop";
      }
    }
    if (this.activeTurns.size > 0) {
      this.state = "running";
    } else {
      this.state = sawLifecycle || sawActivity ? "idle" : "unknown";
    }
    if (
      sawExternalTerminalWithoutTimestamp &&
      Number.isFinite(fileModifiedAtMs)
    ) {
      this.lastExternalTerminalTimestampMs = fileModifiedAtMs;
    }
  }

  private reconcileSeedResponseTurn(
    payload: Record<string, unknown>,
    timestampMs?: number,
  ): void {
    const turnId = rolloutTurnId(payload);
    if (!turnId) return;
    const current = this.activeTurns.get(`turn:${turnId}`);
    if (!current) return;
    if (current.origin === null) {
      current.origin = this.isExactlyLocalTurn(turnId) ? "local" : "desktop";
    }
    if (current.origin !== "desktop") return;

    const currentTimestampMs =
      parseTimestampMs(current.timestamp) ?? timestampMs;
    if (currentTimestampMs === undefined) return;
    // A response item carrying an exact turn id is the same ownership
    // evidence used by the live reader. Seed has no classification timers, so
    // classify only stale predecessors before applying the bounded repair.
    for (const candidate of this.activeTurns.values()) {
      if (
        candidate === current ||
        candidate.origin !== null ||
        candidate.sequence >= current.sequence ||
        this.isExactlyLocalTurn(candidate.turnId)
      ) {
        continue;
      }
      const candidateTimestampMs = parseTimestampMs(candidate.timestamp);
      if (
        candidateTimestampMs !== undefined &&
        currentTimestampMs - candidateTimestampMs >=
          STALE_DESKTOP_PREDECESSOR_MS
      ) {
        candidate.origin = "desktop";
      }
    }
    this.retireStaleDesktopPredecessors(current, currentTimestampMs);
  }

  private async readPass(): Promise<void> {
    if (!this.file || this.closed) return;
    let info = await stat(this.options.path);
    if (info.size < this.offset) {
      this.offset = 0;
      this.decoder = new StringDecoder("utf8");
      this.lineBuffer = "";
      this.discardingLongLine = false;
      this.resetObservedState();
    }
    let remainingBudget = MAX_READ_BYTES_PER_PASS;
    while (this.offset < info.size && remainingBudget > 0 && !this.closed) {
      const length = Math.min(
        READ_CHUNK_BYTES,
        info.size - this.offset,
        remainingBudget,
      );
      const buffer = Buffer.allocUnsafe(length);
      const { bytesRead } = await this.file.read(
        buffer,
        0,
        length,
        this.offset,
      );
      if (bytesRead <= 0) break;
      this.offset += bytesRead;
      remainingBudget -= bytesRead;
      this.consumeText(this.decoder.write(buffer.subarray(0, bytesRead)));
      if (this.offset >= info.size) info = await stat(this.options.path);
    }
    if (this.offset < info.size) this.refreshAgain = true;
  }

  private consumeText(text: string): void {
    let cursor = 0;
    while (cursor < text.length) {
      const newline = text.indexOf("\n", cursor);
      const part = text.slice(cursor, newline < 0 ? text.length : newline);
      cursor = newline < 0 ? text.length : newline + 1;
      if (!this.discardingLongLine) {
        this.lineBuffer += part;
        if (Buffer.byteLength(this.lineBuffer, "utf8") > MAX_LINE_BYTES) {
          this.lineBuffer = "";
          this.discardingLongLine = true;
        }
      }
      if (newline < 0) break;
      if (!this.discardingLongLine && this.lineBuffer) {
        this.consumeLine(this.lineBuffer);
      }
      this.lineBuffer = "";
      this.discardingLongLine = false;
    }
  }

  private consumeLine(line: string): void {
    if (this.closed) return;
    let entry: RolloutEntry;
    try {
      entry = JSON.parse(line) as RolloutEntry;
    } catch {
      return;
    }
    const payload = asRecord(entry.payload);
    if (!payload) return;
    const timestamp = optionalString(entry.timestamp);
    if (entry.type === "event_msg") {
      this.consumeEventMessage(payload, timestamp);
    } else if (entry.type === "response_item") {
      this.consumeResponseItem(payload, timestamp);
    }
  }

  private consumeEventMessage(
    payload: Record<string, unknown>,
    timestamp?: string,
  ): void {
    const type = optionalString(payload.type);
    if (type === "task_started") {
      this.beginTurn(rolloutTurnId(payload), timestamp);
      return;
    }
    if (type === "task_complete" || type === "turn_aborted") {
      this.flushPendingCompletedTools();
      this.completeTurn(
        rolloutTurnId(payload),
        type === "turn_aborted" ? "interrupted" : "completed",
        timestamp,
      );
      return;
    }
    if (type === "thread_rolled_back") {
      this.consumeThreadRolledBack(timestamp);
      return;
    }
    if (type === "user_message") {
      this.consumeUserMessage(payload, timestamp);
      return;
    }
    if (type === "agent_message") {
      this.consumeAgentEventMessage(payload, timestamp);
      return;
    }
    if (type === "agent_reasoning") {
      const turn = this.scopedTurnForPayload(payload, timestamp);
      if (turn?.origin !== "desktop") return;
      const text = boundedText(optionalString(payload.text) ?? "", 16 * 1024);
      if (!text) return;
      const key = `reasoning:${turn.key}:${hashText(text)}`;
      if (!remember(this.reasoningKeys, key, 512)) return;
      this.emitMessage(
        key,
        { type: "thinking_delta", text: `${text}\n` },
        timestamp,
        turn.turnId,
      );
      return;
    }
    if (
      type === "mcp_tool_call_end" ||
      type === "patch_apply_end" ||
      type === "web_search_end" ||
      type === "image_generation_end"
    ) {
      const turn = this.scopedTurnForPayload(payload, timestamp);
      if (turn?.origin === "desktop") {
        this.queueCompletedEventTool(type, payload, timestamp, turn.turnId);
      }
    }
  }

  private beginTurn(turnId?: string, timestamp?: string): void {
    this.bumpActivityEpoch();
    this.clearTurnDedupe();
    this.state = "running";
    // A local Bridge turn and a Desktop turn can overlap on the same durable
    // thread. Keep a live start unclassified until the following user_message
    // provides client identity; the short timer remains the fallback for
    // older rollouts that omit that event or its client id.
    const origin: TurnOrigin = this.isExactlyLocalTurn(turnId)
      ? "local"
      : null;
    this.addActiveTurn(turnId, origin, timestamp, origin === null);
  }

  private consumeUserMessage(
    payload: Record<string, unknown>,
    timestamp?: string,
  ): void {
    const clientMessageId = optionalString(payload.client_id);
    const isLocal = clientMessageId
      ? this.options.consumeLocalClientMessageId(clientMessageId)
      : false;
    const turn = this.turnForUserMessage(payload);
    if (!turn) return;
    if (isLocal) {
      const exactLocalTurn = this.exactLocalActiveTurn();
      if (exactLocalTurn && exactLocalTurn !== turn) return;
      this.clearPendingStart(turn);
      if (turn.origin === null) {
        turn.origin = "local";
        this.bumpActivityEpoch();
        this.options.onLocalOwnershipSettled?.();
      }
      return;
    }
    if (turn.origin === "local") return;
    if (turn.origin === null && this.isExactlyLocalTurn(turn.turnId)) {
      this.clearPendingStart(turn);
      turn.origin = "local";
      this.bumpActivityEpoch();
      this.options.onLocalOwnershipSettled?.();
      return;
    }
    // No client identity is not proof of Desktop ownership. Give the exact
    // local active-turn callback and short classification timer time to catch
    // up instead of stealing a just-started phone turn.
    if (turn.origin === null && clientMessageId === undefined) return;
    const wasDesktop = turn.origin === "desktop";
    this.clearPendingStart(turn);
    turn.origin = "desktop";
    const retiredPredecessor = this.retireStaleDesktopPredecessors(
      turn,
      parseTimestampMs(timestamp),
    );
    if (!wasDesktop || retiredPredecessor) {
      this.bumpActivityEpoch();
    }
    if (!wasDesktop) {
      this.options.onEvent({
        kind: "state",
        state: "running",
        ...(turn.turnId ? { turnId: turn.turnId } : {}),
        ...(turn.timestamp ? { timestamp: turn.timestamp } : {}),
      });
    }
    const text = boundedText(
      optionalString(payload.message) ?? "",
      MAX_TEXT_BYTES,
    );
    const imageCount =
      arrayLength(payload.images) + arrayLength(payload.local_images);
    if (!text && imageCount === 0) return;
    const itemKey = `user:${clientMessageId ?? hashText(`${timestamp ?? ""}:${text}`)}`;
    this.emitMessage(
      itemKey,
      {
        type: "user_input",
        text:
          text || `[Image attached${imageCount > 1 ? ` x${imageCount}` : ""}]`,
        ...(clientMessageId ? { clientMessageId } : {}),
        ...(imageCount > 0 ? { imageCount } : {}),
        ...(timestamp ? { timestamp } : {}),
      },
      timestamp,
      turn.turnId,
    );
  }

  private flushPendingStart(turn: ActiveTurn | undefined): void {
    if (!turn || turn.origin !== null) return;
    this.clearPendingStart(turn);
    if (this.isExactlyLocalTurn(turn.turnId)) {
      turn.origin = "local";
      this.bumpActivityEpoch();
      this.options.onLocalOwnershipSettled?.();
      return;
    }
    turn.origin = "desktop";
    this.bumpActivityEpoch();
    this.options.onEvent({
      kind: "state",
      state: "running",
      ...(turn.turnId ? { turnId: turn.turnId } : {}),
      ...(turn.timestamp ? { timestamp: turn.timestamp } : {}),
    });
  }

  private clearPendingStart(turn: ActiveTurn): void {
    if (turn.pendingStartTimer) clearTimeout(turn.pendingStartTimer);
    turn.pendingStartTimer = null;
  }

  private completeTurn(
    turnId: string | undefined,
    outcome: "completed" | "interrupted",
    timestamp?: string,
  ): void {
    if (turnId && this.retiredStaleDesktopTurnIds.delete(turnId)) return;
    const candidate = this.turnForCompletion(turnId);
    // A terminal without a matching id cannot select one of several active
    // turns safely. Keep them active until their exact terminal arrives.
    if (!candidate && this.activeTurns.size > 0) return;
    this.flushPendingStart(candidate);
    const completed = candidate ? this.takeActiveTurn(candidate) : undefined;
    this.bumpActivityEpoch();
    const wasDesktop = (completed?.origin ?? "desktop") === "desktop";
    const effectiveTurnId = turnId ?? completed?.turnId;
    this.lastObservedTurnId = effectiveTurnId;
    this.state = this.activeTurns.size > 0 ? "running" : "idle";
    if (wasDesktop) {
      this.lastExternalTerminalTimestampMs =
        parseTimestampMs(timestamp) ?? Date.now();
      const remainingExternal = this.latestExternalTurn();
      if (remainingExternal) {
        this.options.onEvent({
          kind: "state",
          state: "running",
          ...(remainingExternal.turnId
            ? { turnId: remainingExternal.turnId }
            : {}),
          ...(timestamp ? { timestamp } : {}),
        });
      } else {
        this.options.onEvent({
          kind: "state",
          state: "idle",
          outcome,
          ...(effectiveTurnId ? { turnId: effectiveTurnId } : {}),
          ...(timestamp ? { timestamp } : {}),
        });
      }
    }
  }

  private consumeThreadRolledBack(timestamp?: string): void {
    this.bumpActivityEpoch();
    this.clearExternalTurns();
    this.clearAssistantPairing();
    this.lastObservedTurnId = undefined;
    this.lastExternalTerminalTimestampMs =
      parseTimestampMs(timestamp) ?? Date.now();
    this.state = this.activeTurns.size > 0 ? "running" : "idle";
    this.options.onEvent({
      kind: "state",
      state: "idle",
      outcome: "interrupted",
      ...(timestamp ? { timestamp } : {}),
    });
  }

  private consumeAgentEventMessage(
    payload: Record<string, unknown>,
    timestamp?: string,
  ): void {
    if (!isMainAssistantEventPhase(payload.phase)) return;
    const text = boundedText(
      optionalString(payload.message) ?? "",
      MAX_TEXT_BYTES,
    );
    if (!text) return;
    const turn = this.scopedTurnForPayload(payload, timestamp);
    if (turn?.origin !== "desktop") return;
    const phase = normalizeAssistantPhase(payload.phase);
    const timestampMs = parseTimestampMs(timestamp);
    const recent = this.findRecentResponseAssistant(
      text,
      phase,
      rolloutTurnId(payload),
      timestampMs,
    );
    if (recent) {
      this.recentResponseAssistants.delete(recent.key);
      return;
    }

    const sequence = ++this.assistantMessageSequence;
    const key = `event-assistant:${sequence}`;
    const syntheticId = `desktop-event-${hashText(
      `${timestamp ?? ""}:${turn.key}:${phase}:${text}:${sequence}`,
    )}`;
    const pending: PendingAssistantMessage = {
      key,
      turnKey: turn.key,
      ...(turn.turnId ? { turnId: turn.turnId } : {}),
      phase,
      text,
      ...(timestamp ? { timestamp } : {}),
      ...(timestampMs !== undefined ? { timestampMs } : {}),
      syntheticId,
      timer: null,
      syntheticEmitted: false,
    };
    const delayMs = boundedInteger(
      this.options.assistantMessagePairMs,
      ASSISTANT_MESSAGE_PAIR_MS,
      0,
      1000,
    );
    pending.timer = setTimeout(
      () => this.flushPendingAssistantMessage(key),
      delayMs,
    );
    pending.timer.unref?.();
    this.pendingAssistantMessages.set(key, pending);
    while (
      this.pendingAssistantMessages.size > MAX_PENDING_ASSISTANT_MESSAGES
    ) {
      const oldestKey = this.pendingAssistantMessages.keys().next().value;
      if (!oldestKey) break;
      this.flushPendingAssistantMessage(oldestKey);
      this.pendingAssistantMessages.delete(oldestKey);
    }
  }

  private consumeAssistantResponseItem(
    payload: Record<string, unknown>,
    timestamp?: string,
  ): void {
    const text = boundedText(
      extractContentText(payload.content),
      MAX_TEXT_BYTES,
    );
    if (!text) return;
    const phase = normalizeAssistantPhase(payload.phase);
    const timestampMs = parseTimestampMs(timestamp);
    const currentTurn = this.scopedTurnForPayload(payload, timestamp);
    // Pairing by text is only a dedupe aid, not turn ownership evidence. If
    // multiple active turns make this payload ambiguous, suppress it and let
    // the terminal canonical rehydrate repair history.
    if (!currentTurn) return;
    const pending = this.findPendingAssistantMessage(
      text,
      phase,
      rolloutTurnId(payload),
      timestampMs,
    );
    if (pending) {
      if (pending.timer) clearTimeout(pending.timer);
      this.pendingAssistantMessages.delete(pending.key);
      if (pending.syntheticEmitted) return;
      const id = optionalString(payload.id) ?? pending.syntheticId;
      this.emitAssistantMessage(
        id,
        text,
        timestamp ?? pending.timestamp,
        pending.turnId,
      );
      return;
    }

    if (currentTurn?.origin !== "desktop") return;
    const id =
      optionalString(payload.id) ??
      `desktop-${hashText(`${timestamp ?? ""}:${text}`)}`;
    this.emitAssistantMessage(id, text, timestamp, currentTurn.turnId);
    const key = `response-assistant:${++this.assistantMessageSequence}`;
    setBoundedMap(
      this.recentResponseAssistants,
      key,
      {
        key,
        ...(currentTurn.turnId ? { turnId: currentTurn.turnId } : {}),
        phase,
        text,
        ...(timestampMs !== undefined ? { timestampMs } : {}),
      },
      MAX_RECENT_RESPONSE_ASSISTANTS,
    );
  }

  private flushPendingAssistantMessage(key: string): void {
    const pending = this.pendingAssistantMessages.get(key);
    if (!pending || pending.syntheticEmitted || this.closed) return;
    if (pending.timer) clearTimeout(pending.timer);
    pending.timer = null;
    pending.syntheticEmitted = true;
    this.emitAssistantMessage(
      pending.syntheticId,
      pending.text,
      pending.timestamp,
      pending.turnId,
    );
  }

  private emitAssistantMessage(
    id: string,
    text: string,
    timestamp?: string,
    turnId?: string,
  ): void {
    this.emitMessage(
      `assistant:${id}`,
      {
        type: "assistant",
        message: {
          id,
          role: "assistant",
          content: [{ type: "text", text }],
          model: "codex",
        },
      },
      timestamp,
      turnId,
    );
  }

  private findPendingAssistantMessage(
    text: string,
    phase: AssistantMessagePhase,
    turnId?: string,
    timestampMs?: number,
  ): PendingAssistantMessage | undefined {
    for (const pending of this.pendingAssistantMessages.values()) {
      if (
        pending.text === text &&
        assistantPhasesMatch(pending.phase, phase) &&
        turnIdsMatch(pending.turnId, turnId) &&
        assistantTimestampsMatch(pending.timestampMs, timestampMs)
      ) {
        return pending;
      }
    }
    return undefined;
  }

  private findRecentResponseAssistant(
    text: string,
    phase: AssistantMessagePhase,
    turnId?: string,
    timestampMs?: number,
  ): RecentResponseAssistant | undefined {
    for (const recent of this.recentResponseAssistants.values()) {
      if (
        recent.text === text &&
        assistantPhasesMatch(recent.phase, phase) &&
        turnIdsMatch(recent.turnId, turnId) &&
        assistantTimestampsMatch(recent.timestampMs, timestampMs)
      ) {
        return recent;
      }
    }
    return undefined;
  }

  private consumeResponseItem(
    payload: Record<string, unknown>,
    timestamp?: string,
  ): void {
    const type = optionalString(payload.type);
    if (type === "message" && payload.role === "assistant") {
      this.consumeAssistantResponseItem(payload, timestamp);
      return;
    }
    const turn = this.scopedTurnForPayload(payload, timestamp);
    if (turn?.origin !== "desktop") return;
    if (type === "function_call" || type === "custom_tool_call") {
      const callId =
        optionalString(payload.call_id) ??
        optionalString(payload.id) ??
        `desktop-tool-${hashText(`${timestamp ?? ""}:${JSON.stringify(payload).slice(0, 4096)}`)}`;
      const rawInput =
        type === "function_call" ? payload.arguments : payload.input;
      const descriptor = describeCodexDesktopToolCall(
        optionalString(payload.name) ?? "tool",
        rawInput,
      );
      const name = descriptor.name;
      this.toolNames.set(callId, name);
      while (this.toolNames.size > 512) {
        this.toolNames.delete(this.toolNames.keys().next().value!);
      }
      const input = boundedToolInput(descriptor.input);
      this.emitMessage(
        `tool-start:${callId}`,
        {
          type: "assistant",
          message: {
            id: callId,
            role: "assistant",
            content: [{ type: "tool_use", id: callId, name, input }],
            model: "codex",
          },
          messageUuid: callId,
        },
        timestamp,
        turn.turnId,
      );
      return;
    }
    if (this.consumeCompatibleResponseTool(type, payload, timestamp, turn)) {
      return;
    }
    if (type === "function_call_output" || type === "custom_tool_call_output") {
      const callId = optionalString(payload.call_id);
      if (!callId) return;
      const toolName = this.toolNames.get(callId);
      const normalized = normalizeCodexDesktopToolOutput(payload.output);
      this.emitMessage(
        `tool-result:${callId}`,
        {
          type: "tool_result",
          toolUseId: callId,
          content: boundedText(
            normalized.content ||
              (normalized.imageBase64.length > 0
                ? toolName === "ViewImage"
                  ? "Viewed image"
                  : "Tool returned an image"
                : formatToolOutput(payload.output)),
            MAX_TEXT_BYTES,
          ),
          ...(toolName ? { toolName } : {}),
        },
        timestamp,
        turn.turnId,
        normalized.imageBase64,
      );
    }
  }

  private consumeCompatibleResponseTool(
    type: string | undefined,
    payload: Record<string, unknown>,
    timestamp: string | undefined,
    turn: ActiveTurn,
  ): boolean {
    let idPrefix: string;
    let name: string;
    let input: Record<string, unknown>;
    let preferItemId = false;
    let immediateResult: NormalizedToolResult | undefined;

    switch (type) {
      case "web_search_call":
      case "web_search": {
        idPrefix = "desktop-web-search";
        name = "WebSearch";
        preferItemId = type === "web_search";
        const action = asRecord(payload.action);
        const query =
          optionalString(action?.query) ?? optionalString(payload.query);
        input = query ? { query } : boundedToolInput(action ?? payload.action);
        break;
      }
      case "image_generation_call":
        idPrefix = "desktop-image";
        name = "ImageGeneration";
        input = boundedToolInput({
          prompt: payload.prompt ?? payload.revised_prompt,
          status: payload.status,
        });
        if (
          Object.prototype.hasOwnProperty.call(payload, "output") ||
          Object.prototype.hasOwnProperty.call(payload, "result")
        ) {
          immediateResult = normalizeImageGenerationResult(payload);
        }
        break;
      case "command_execution":
        idPrefix = "desktop-command";
        preferItemId = true;
        {
          const descriptor = describeCodexDesktopToolCall("exec_command", {
            command: payload.command,
          });
          name = descriptor.name;
          input = boundedToolInput(descriptor.input);
        }
        if (hasCommandExecutionResult(payload)) {
          immediateResult = normalizeCommandExecutionResult(payload);
        }
        break;
      case "mcp_tool_call": {
        idPrefix = "desktop-mcp";
        preferItemId = true;
        const server = optionalString(payload.server) ?? "mcp";
        const tool = optionalString(payload.tool) ?? "tool";
        name = `mcp:${server}/${tool}`;
        input = boundedToolInput(payload.arguments);
        break;
      }
      case "file_change":
        idPrefix = "desktop-file-change";
        name = "FileChange";
        preferItemId = true;
        input = boundedToolInput({ changes: payload.changes });
        break;
      default:
        return false;
    }

    // Match sessions-index canonical ids. Older compatibility schemas use
    // `id` as the item identity while their terminal events still refer to
    // `call_id`, so retain an alias for the completion path.
    const itemId = optionalString(payload.id);
    const transportCallId = optionalString(payload.call_id);
    const previouslyEmittedTransportId =
      transportCallId && this.emittedKeys.has(`tool-start:${transportCallId}`)
        ? transportCallId
        : undefined;
    const callId =
      previouslyEmittedTransportId ??
      (preferItemId ? itemId ?? transportCallId : transportCallId ?? itemId) ??
      `${idPrefix}-${hashText(
        `${timestamp ?? ""}:${JSON.stringify(payload).slice(0, 4096)}`,
      )}`;
    for (const alias of [itemId, transportCallId]) {
      if (alias) setBoundedMap(this.toolIdAliases, alias, callId, 512);
    }
    if (transportCallId) {
      this.flushPendingCompletedTool(`call:${transportCallId}`);
    }
    setBoundedMap(this.toolNames, callId, name, 512);
    this.emitMessage(
      `tool-start:${callId}`,
      {
        type: "assistant",
        message: {
          id: callId,
          role: "assistant",
          content: [{ type: "tool_use", id: callId, name, input }],
          model: "codex",
        },
        messageUuid: callId,
      },
      timestamp,
      turn.turnId,
    );
    if (immediateResult) {
      this.emitMessage(
        `tool-result:${callId}`,
        {
          type: "tool_result",
          toolUseId: callId,
          toolName: name,
          content: boundedText(immediateResult.content, MAX_TEXT_BYTES),
        },
        timestamp,
        turn.turnId,
      );
    }
    return true;
  }

  private queueCompletedEventTool(
    type: CompletedEventToolType,
    payload: Record<string, unknown>,
    timestamp?: string,
    turnId?: string,
  ): void {
    const rawCallId = optionalString(payload.call_id);
    if (rawCallId && this.toolIdAliases.has(rawCallId)) {
      this.consumeCompletedEventTool(type, payload, timestamp, turnId);
      return;
    }
    const key = rawCallId
      ? `call:${rawCallId}`
      : `anonymous:${type}:${hashText(
          `${timestamp ?? ""}:${JSON.stringify(payload).slice(0, 4096)}`,
        )}`;
    const previous = this.pendingCompletedTools.get(key);
    if (previous) {
      this.pendingCompletedTools.delete(key);
      this.consumeCompletedEventTool(
        previous.type,
        previous.payload,
        previous.timestamp,
        previous.turnId,
      );
    }
    this.pendingCompletedTools.set(key, {
      type,
      payload,
      ...(timestamp ? { timestamp } : {}),
      ...(turnId ? { turnId } : {}),
    });
    queueMicrotask(() => this.flushPendingCompletedTool(key));
  }

  private flushPendingCompletedTool(key: string): void {
    const pending = this.pendingCompletedTools.get(key);
    if (!pending || this.closed) return;
    this.pendingCompletedTools.delete(key);
    this.consumeCompletedEventTool(
      pending.type,
      pending.payload,
      pending.timestamp,
      pending.turnId,
    );
  }

  private flushPendingCompletedTools(): void {
    for (const key of [...this.pendingCompletedTools.keys()]) {
      this.flushPendingCompletedTool(key);
    }
  }

  private consumeCompletedEventTool(
    type: CompletedEventToolType,
    payload: Record<string, unknown>,
    timestamp?: string,
    turnId?: string,
  ): void {
    const imagePrompt = boundedText(
      optionalString(payload.revised_prompt) ??
        optionalString(payload.prompt) ??
        "",
      64 * 1024,
    );
    const imageStatus = boundedText(
      optionalString(payload.status) ?? "completed",
      1024,
    );
    const imageSavedPath = boundedText(
      optionalString(payload.saved_path) ?? "",
      16 * 1024,
    );
    const rawCallId = optionalString(payload.call_id);
    const callId =
      (rawCallId ? this.toolIdAliases.get(rawCallId) ?? rawCallId : undefined) ??
      (type === "image_generation_end"
        ? `desktop-image-${hashText(
            `${timestamp ?? ""}:${imageStatus}:${imageSavedPath}:${imagePrompt}`,
          )}`
        : undefined);
    if (!callId) return;
    let name: string;
    let input: Record<string, unknown>;
    let output: string;
    if (type === "image_generation_end") {
      name = "ImageGeneration";
      input = boundedToolInput({
        prompt: imagePrompt,
        status: imageStatus,
        saved_path: imageSavedPath,
      });
      const normalized = normalizeImageGenerationResult(payload);
      output = normalized.content;
    } else if (type === "patch_apply_end") {
      name = "FileChange";
      input = boundedToolInput(payload.changes);
      output = formatToolOutput({
        success: payload.success,
        stdout: payload.stdout,
        stderr: payload.stderr,
      });
    } else if (type === "web_search_end") {
      name = "WebSearch";
      input = boundedToolInput(payload.action ?? { query: payload.query });
      output = formatToolOutput(
        payload.results ?? payload.query ?? "Web search completed",
      );
    } else {
      const invocation = asRecord(payload.invocation) ?? {};
      const server = optionalString(invocation.server) ?? "mcp";
      const tool = optionalString(invocation.tool) ?? "tool";
      name = `mcp:${server}/${tool}`;
      input = boundedToolInput(invocation.arguments);
      const normalized = normalizeMcpToolResult(payload.result);
      output = normalized.content;
    }
    setBoundedMap(this.toolNames, callId, name, 512);
    this.emitMessage(
      `tool-start:${callId}`,
      {
        type: "assistant",
        message: {
          id: callId,
          role: "assistant",
          content: [{ type: "tool_use", id: callId, name, input }],
          model: "codex",
        },
        messageUuid: callId,
      },
      timestamp,
      turnId,
    );
    this.emitMessage(
      `tool-result:${callId}`,
      {
        type: "tool_result",
        toolUseId: callId,
        toolName: name,
        content: boundedText(output, MAX_TEXT_BYTES),
      },
      timestamp,
      turnId,
    );
  }

  private addActiveTurn(
    turnId: string | undefined,
    origin: TurnOrigin,
    timestamp: string | undefined,
    scheduleClassification: boolean,
  ): ActiveTurn {
    const sequence = ++this.turnSequence;
    const key = turnId ? `turn:${turnId}` : `turn:anonymous:${sequence}`;
    const existing = this.activeTurns.get(key);
    if (existing) {
      this.clearPendingStart(existing);
      this.activeTurns.delete(key);
    }
    const turn: ActiveTurn = {
      key,
      ...(turnId ? { turnId } : {}),
      origin,
      ...(timestamp ? { timestamp } : {}),
      sequence,
      pendingStartTimer: null,
    };
    this.activeTurns.set(key, turn);
    if (scheduleClassification && origin === null) {
      turn.pendingStartTimer = setTimeout(() => {
        this.flushPendingStart(this.activeTurns.get(key));
      }, START_CLASSIFICATION_MS);
      turn.pendingStartTimer.unref?.();
    }
    while (this.activeTurns.size > MAX_ACTIVE_TURNS) {
      const oldestKey = this.activeTurns.keys().next().value;
      if (!oldestKey) break;
      const oldest = this.activeTurns.get(oldestKey);
      if (oldest) this.clearPendingStart(oldest);
      this.activeTurns.delete(oldestKey);
    }
    return turn;
  }

  private turnForPayload(
    payload: Record<string, unknown>,
  ): ActiveTurn | undefined {
    const explicitTurnId = rolloutTurnId(payload);
    if (explicitTurnId) {
      return this.activeTurns.get(`turn:${explicitTurnId}`);
    }
    const turns = [...this.activeTurns.values()];
    // Real rollouts commonly omit turn_id from reasoning, assistant and tool
    // entries. They are attributable only while exactly one turn is active.
    return turns.length === 1 ? turns[0] : undefined;
  }

  private scopedTurnForPayload(
    payload: Record<string, unknown>,
    timestamp?: string,
  ): ActiveTurn | undefined {
    const explicitTurnId = rolloutTurnId(payload);
    const turn = this.turnForPayload(payload);
    this.flushPendingStart(turn);
    if (
      turn?.origin === "desktop" &&
      explicitTurnId !== undefined &&
      this.retireStaleDesktopPredecessors(turn, parseTimestampMs(timestamp))
    ) {
      this.bumpActivityEpoch();
    }
    return turn;
  }

  private turnForUserMessage(
    payload: Record<string, unknown>,
  ): ActiveTurn | undefined {
    const explicitTurnId = rolloutTurnId(payload);
    if (explicitTurnId) {
      return this.activeTurns.get(`turn:${explicitTurnId}`);
    }
    const turns = [...this.activeTurns.values()];
    const pending = turns.filter((turn) => turn.origin === null);
    if (pending.length === 1) return pending[0];
    return turns.length === 1 ? turns[0] : undefined;
  }

  private turnForCompletion(turnId?: string): ActiveTurn | undefined {
    const turns = [...this.activeTurns.values()];
    if (!turnId) return turns.length === 1 ? turns[0] : undefined;
    const exact = this.activeTurns.get(`turn:${turnId}`);
    if (exact) return exact;
    const anonymous = turns.filter((turn) => turn.turnId === undefined);
    return turns.length === 1 && anonymous.length === 1
      ? anonymous[0]
      : undefined;
  }

  /**
   * A real Desktop turn can briefly overlap another attributed turn, so
   * unscoped payloads must continue to fail closed during that interval.
   * However, Codex rollouts can also retain an orphan task_started forever
   * after an interrupted Desktop host. Once a much newer user_message proves
   * Desktop ownership, an older proven-Desktop predecessor is no longer a
   * credible peer turn on the same serial thread. Retire only that bounded
   * case; local, unclassified, timestamp-less and recent overlaps stay active.
   */
  private retireStaleDesktopPredecessors(
    current: ActiveTurn,
    evidenceTimestampMs?: number,
  ): boolean {
    const currentTimestampMs =
      parseTimestampMs(current.timestamp) ?? evidenceTimestampMs;
    if (currentTimestampMs === undefined) return false;
    let retired = false;
    for (const [key, candidate] of this.activeTurns) {
      if (
        candidate === current ||
        candidate.origin !== "desktop" ||
        candidate.turnId === undefined ||
        candidate.sequence >= current.sequence
      ) {
        continue;
      }
      const candidateTimestampMs = parseTimestampMs(candidate.timestamp);
      if (
        candidateTimestampMs === undefined ||
        currentTimestampMs - candidateTimestampMs <
          STALE_DESKTOP_PREDECESSOR_MS
      ) {
        continue;
      }
      this.clearPendingStart(candidate);
      this.clearPendingOutput(candidate);
      this.activeTurns.delete(key);
      remember(
        this.retiredStaleDesktopTurnIds,
        candidate.turnId,
        MAX_RETIRED_STALE_TURN_IDS,
      );
      retired = true;
    }
    return retired;
  }

  private clearPendingOutput(turn: ActiveTurn): void {
    for (const [key, pending] of this.pendingAssistantMessages) {
      if (pending.turnKey !== turn.key) continue;
      if (pending.timer) clearTimeout(pending.timer);
      this.pendingAssistantMessages.delete(key);
    }
    if (!turn.turnId) return;
    for (const [key, pending] of this.pendingCompletedTools) {
      if (pending.turnId === turn.turnId) {
        this.pendingCompletedTools.delete(key);
      }
    }
  }

  private takeActiveTurn(turn: ActiveTurn): ActiveTurn {
    this.clearPendingStart(turn);
    this.activeTurns.delete(turn.key);
    return turn;
  }

  private isExactlyLocalTurn(turnId?: string): boolean {
    return (
      turnId !== undefined &&
      this.options.getLocalActiveTurnId() === turnId
    );
  }

  private exactLocalActiveTurn(): ActiveTurn | undefined {
    const turnId = this.options.getLocalActiveTurnId();
    return turnId ? this.activeTurns.get(`turn:${turnId}`) : undefined;
  }

  private bumpActivityEpoch(): void {
    this.activityEpochValue =
      this.activityEpochValue >= Number.MAX_SAFE_INTEGER
        ? 1
        : this.activityEpochValue + 1;
  }

  private latestExternalTurn(): ActiveTurn | undefined {
    return lastMatching(
      this.activeTurns.values(),
      (turn) => turn.origin === "desktop",
    );
  }

  private clearExternalTurns(): void {
    for (const [key, turn] of this.activeTurns) {
      if (turn.origin === "local") continue;
      this.clearPendingStart(turn);
      this.activeTurns.delete(key);
    }
  }

  private clearActiveTurns(): void {
    for (const turn of this.activeTurns.values()) {
      this.clearPendingStart(turn);
    }
    this.activeTurns.clear();
  }

  private clearAssistantPairing(): void {
    for (const pending of this.pendingAssistantMessages.values()) {
      if (pending.timer) clearTimeout(pending.timer);
    }
    this.pendingAssistantMessages.clear();
    this.recentResponseAssistants.clear();
  }

  private resetObservedState(): void {
    this.bumpActivityEpoch();
    this.clearActiveTurns();
    this.clearAssistantPairing();
    this.state = "unknown";
    this.lastObservedTurnId = undefined;
    this.lastExternalTerminalTimestampMs = undefined;
    this.retiredStaleDesktopTurnIds.clear();
    this.emittedKeys.clear();
    this.reasoningKeys.clear();
    this.toolNames.clear();
    this.toolIdAliases.clear();
    this.pendingCompletedTools.clear();
  }

  private emitMessage(
    itemKey: string,
    message: ServerMessage,
    timestamp?: string,
    turnId?: string,
    imageBase64?: CodexDesktopInlineImage[],
  ): void {
    if (!remember(this.emittedKeys, itemKey, MAX_DEDUPE_KEYS)) return;
    this.options.onEvent({
      kind: "message",
      itemKey,
      message,
      ...(imageBase64 && imageBase64.length > 0 ? { imageBase64 } : {}),
      ...(turnId ? { turnId } : {}),
      ...(timestamp ? { timestamp } : {}),
    });
  }

  private clearTurnDedupe(): void {
    // Keep cross-turn item ids for a bounded window: late rollout echoes must
    // not duplicate the just-completed tool or assistant item.
    while (this.emittedKeys.size > MAX_DEDUPE_KEYS / 2) {
      this.emittedKeys.delete(this.emittedKeys.values().next().value!);
    }
  }
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value != null && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function optionalString(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function rolloutTurnId(
  payload: Record<string, unknown>,
): string | undefined {
  return (
    optionalString(payload.turn_id) ??
    optionalString(
      asRecord(payload.internal_chat_message_metadata_passthrough)?.turn_id,
    )
  );
}

function parseTimestampMs(value: unknown): number | undefined {
  if (typeof value !== "string") return undefined;
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : undefined;
}

function arrayLength(value: unknown): number {
  return Array.isArray(value) ? value.length : 0;
}

function extractContentText(value: unknown): string {
  if (!Array.isArray(value)) return "";
  return value
    .map((entry) => asRecord(entry))
    .filter((entry): entry is Record<string, unknown> => entry !== null)
    .filter(
      (entry) =>
        (entry.type === "output_text" || entry.type === "text") &&
        typeof entry.text === "string",
    )
    .map((entry) => entry.text as string)
    .join("\n");
}

function boundedToolInput(value: unknown): Record<string, unknown> {
  let parsed: unknown = value;
  if (typeof value === "string") {
    try {
      parsed = JSON.parse(value) as unknown;
    } catch {
      parsed = { value };
    }
  }
  const record = asRecord(parsed) ?? { value: parsed };
  let encoded: string;
  try {
    encoded = JSON.stringify(record);
  } catch {
    return { value: String(value) };
  }
  if (Buffer.byteLength(encoded, "utf8") <= MAX_TOOL_INPUT_BYTES) return record;
  return {
    truncated: true,
    preview: boundedText(encoded, MAX_TOOL_INPUT_BYTES),
  };
}

interface NormalizedToolResult {
  content: string;
}

function hasCommandExecutionResult(
  payload: Record<string, unknown>,
): boolean {
  if (
    ["output", "aggregated_output", "aggregatedOutput", "result"].some(
      (key) => Object.prototype.hasOwnProperty.call(payload, key),
    )
  ) {
    return true;
  }
  if (
    typeof payload.exit_code === "number" ||
    typeof payload.exitCode === "number"
  ) {
    return true;
  }
  return ["completed", "failed", "cancelled", "canceled"].includes(
    optionalString(payload.status)?.toLowerCase() ?? "",
  );
}

function normalizeCommandExecutionResult(
  payload: Record<string, unknown>,
): NormalizedToolResult {
  const output =
    optionalString(payload.aggregated_output) ??
    optionalString(payload.aggregatedOutput) ??
    optionalString(payload.output) ??
    optionalString(payload.result) ??
    "";
  const exitCode =
    typeof payload.exit_code === "number"
      ? payload.exit_code
      : typeof payload.exitCode === "number"
        ? payload.exitCode
        : undefined;
  return {
    content: output || `exit code: ${exitCode ?? "unknown"}`,
  };
}

function normalizeImageGenerationResult(
  payload: Record<string, unknown>,
): NormalizedToolResult {
  const status = optionalString(payload.status) ?? "completed";
  const prompt =
    optionalString(payload.revised_prompt) ??
    optionalString(payload.revisedPrompt) ??
    optionalString(payload.prompt);
  const savedPath =
    optionalString(payload.saved_path) ?? optionalString(payload.savedPath);
  const result =
    optionalString(payload.result)?.trim() ??
    optionalString(payload.output)?.trim() ??
    "";
  const parts = [`status: ${status}`];
  if (prompt) parts.push(`revisedPrompt: ${prompt}`);
  if (savedPath) {
    parts.push(`savedPath: ${savedPath}`);
    return { content: parts.join("\n") };
  }
  if (!result) return { content: parts.join("\n") };
  parts.push("Generated 1 image");
  return { content: parts.join("\n") };
}

function normalizeMcpToolResult(value: unknown): NormalizedToolResult {
  const wrapper = asRecord(value);
  let result = value;
  if (wrapper && Object.prototype.hasOwnProperty.call(wrapper, "Ok")) {
    result = wrapper.Ok;
  } else if (wrapper && Object.prototype.hasOwnProperty.call(wrapper, "Err")) {
    result = wrapper.Err;
  }
  if (typeof result === "string") {
    return { content: result };
  }
  const record = asRecord(result);
  const contentItems = Array.isArray(record?.content) ? record.content : null;
  if (!contentItems) {
    return {
      content: result == null ? "MCP call completed" : formatJson(result),
    };
  }

  const textParts: string[] = [];
  let imageCount = 0;
  for (const entry of contentItems) {
    const item = asRecord(entry);
    if (!item) continue;
    const type = optionalString(item.type) ?? "";
    if (type === "text" && typeof item.text === "string") {
      textParts.push(item.text);
      continue;
    }
    if (type === "image") {
      const source = asRecord(item.source);
      const data =
        optionalString(item.data) ??
        (source?.type === "base64" ? optionalString(source.data) : undefined);
      if (data) {
        imageCount += 1;
        continue;
      }
    }
    textParts.push(formatJson(item));
  }
  const content = textParts.join("\n").trim();
  if (content) return { content };
  return {
    content:
      imageCount > 0
        ? imageCount === 1
          ? "Generated 1 image"
          : `Generated ${imageCount} images`
        : result == null
          ? "MCP call completed"
          : formatJson(result),
  };
}

function formatToolOutput(value: unknown): string {
  if (typeof value === "string") return value;
  if (Array.isArray(value)) {
    const text = value
      .map((entry) => {
        const item = asRecord(entry);
        return typeof item?.text === "string" ? item.text : formatJson(entry);
      })
      .filter(Boolean)
      .join("\n");
    if (text) return text;
  }
  const wrapper = asRecord(value);
  if (wrapper && Object.prototype.hasOwnProperty.call(wrapper, "Ok")) {
    return formatToolOutput(wrapper.Ok);
  }
  if (wrapper && Object.prototype.hasOwnProperty.call(wrapper, "Err")) {
    return formatToolOutput(wrapper.Err);
  }
  return formatJson(value);
}

function formatJson(value: unknown): string {
  try {
    return JSON.stringify(value, null, 2);
  } catch {
    return String(value ?? "");
  }
}

function boundedText(value: string, maxBytes: number): string {
  if (Buffer.byteLength(value, "utf8") <= maxBytes) return value;
  const buffer = Buffer.from(value, "utf8");
  return `${buffer.subarray(0, maxBytes).toString("utf8")}\n…[truncated by Bridge]`;
}

function hashText(value: string): string {
  return createHash("sha256").update(value).digest("base64url").slice(0, 22);
}

function isMainAssistantEventPhase(value: unknown): boolean {
  return value === "commentary" || value === "final" || value === "final_answer";
}

function normalizeAssistantPhase(value: unknown): AssistantMessagePhase {
  if (value === "commentary") return "commentary";
  if (value === "final" || value === "final_answer") return "final";
  return "unknown";
}

function assistantPhasesMatch(
  left: AssistantMessagePhase,
  right: AssistantMessagePhase,
): boolean {
  return left === right || left === "unknown" || right === "unknown";
}

function turnIdsMatch(left?: string, right?: string): boolean {
  return left === undefined || right === undefined || left === right;
}

function assistantTimestampsMatch(left?: number, right?: number): boolean {
  return (
    left === undefined ||
    right === undefined ||
    Math.abs(left - right) <= ASSISTANT_PAIR_TOMBSTONE_MS
  );
}

function boundedInteger(
  value: number | undefined,
  fallback: number,
  minimum: number,
  maximum: number,
): number {
  const candidate =
    typeof value === "number" && Number.isFinite(value)
      ? Math.floor(value)
      : fallback;
  return Math.min(maximum, Math.max(minimum, candidate));
}

function remember(set: Set<string>, value: string, limit: number): boolean {
  if (set.has(value)) return false;
  set.add(value);
  while (set.size > limit) set.delete(set.values().next().value!);
  return true;
}

function setBoundedMap<K, V>(
  map: Map<K, V>,
  key: K,
  value: V,
  limit: number,
): void {
  if (map.has(key)) map.delete(key);
  map.set(key, value);
  while (map.size > limit) map.delete(map.keys().next().value!);
}

function lastMatching<T>(
  values: Iterable<T>,
  predicate: (value: T) => boolean,
): T | undefined {
  let match: T | undefined;
  for (const value of values) {
    if (predicate(value)) match = value;
  }
  return match;
}
