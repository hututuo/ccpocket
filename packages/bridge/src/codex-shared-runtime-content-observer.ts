import type { CodexProcess, CodexStartOptions } from "./codex-process.js";
import {
  isSharedRuntimePilotObserverBlocked,
  subscribeSharedRuntimePilotFormalAttachmentReleased,
} from "./codex-shared-runtime-pilot.js";
import type { ServerMessage } from "./parser.js";

const DEFAULT_MAX_OBSERVERS = 32;
const DEFAULT_UNFOCUS_GRACE_MS = 15_000;
const DEFAULT_ATTACH_TIMEOUT_MS = 15_000;
const DEFAULT_MAX_CONCURRENT_ATTACHES = 4;
const DEFAULT_RETRY_DELAYS_MS = [250, 1_000, 2_500] as const;

export interface SharedCodexContentObserverInterest {
  threadId: string;
  projectPath: string;
  /** One or more interactive clients currently render this thread. */
  focused: boolean;
  /** A canonical unresolved approval/question/form exists. */
  needsAttention: boolean;
  /** The shared app-server reports an active or compacting turn. */
  active: boolean;
  /** Used only as a deterministic tie breaker inside one priority class. */
  observedAt: string;
}

export interface SharedCodexContentObserverMessage {
  threadId: string;
  connectionGeneration: number;
  observerGeneration: number;
  observedAt: string;
  turnId?: string;
  /** Opaque per-turn scope used only when the app-server omits turnId. */
  anonymousTurnScope?: string;
  message: ServerMessage;
}

export interface SharedCodexContentObserverCompletion {
  threadId: string;
  connectionGeneration: number;
  observerGeneration: number;
  observedAt: string;
  turnId?: string;
  anonymousTurnScope?: string;
}

/**
 * Narrow shape used by the coordinator so its lifecycle can be tested without
 * spawning a real Codex transport. Production supplies a dedicated
 * CodexProcess connected to the already-running shared app-server.
 */
export interface SharedCodexContentObserverProcess {
  readonly activeTurnId?: string;
  readonly isRunning?: boolean;
  start(projectPath: string, options: CodexStartOptions): void;
  waitUntilAttached(timeoutMs?: number): Promise<void>;
  stop(): void;
  on(event: "message", listener: (message: ServerMessage) => void): unknown;
  on(event: "exit", listener: (code: number | null) => void): unknown;
  on(event: "shared_runtime_yield", listener: () => void): unknown;
  off(event: "message", listener: (message: ServerMessage) => void): unknown;
  off(event: "exit", listener: (code: number | null) => void): unknown;
  off(event: "shared_runtime_yield", listener: () => void): unknown;
}

export interface SharedCodexContentObserverCoordinatorOptions {
  codexSourceId?: string;
  createProcess: () => SharedCodexContentObserverProcess;
  onMessage: (event: SharedCodexContentObserverMessage) => void;
  onCompletion: (event: SharedCodexContentObserverCompletion) => void;
  maxObservers?: number;
  unfocusGraceMs?: number;
  attachTimeoutMs?: number;
  maxConcurrentAttaches?: number;
  retryDelaysMs?: readonly number[];
  now?: () => number;
}

interface ObserverRecord {
  threadId: string;
  process: SharedCodexContentObserverProcess;
  connectionGeneration: number;
  observerGeneration: number;
  onMessage: (message: ServerMessage) => void;
  onExit: (code: number | null) => void;
  onYield: () => void;
  graceTimer?: ReturnType<typeof setTimeout>;
  attaching: boolean;
  lastUsed: number;
  anonymousTurnSequence: number;
  anonymousTurnScope?: string;
}

function boundedPositiveInteger(value: number | undefined, fallback: number) {
  return value !== undefined && Number.isFinite(value) && value > 0
    ? Math.floor(value)
    : fallback;
}

function boundedNonNegativeInteger(
  value: number | undefined,
  fallback: number,
) {
  return value !== undefined && Number.isFinite(value) && value >= 0
    ? Math.floor(value)
    : fallback;
}

function priority(interest: SharedCodexContentObserverInterest): number {
  if (interest.needsAttention) return 0;
  if (interest.focused) return 1;
  if (interest.active) return 2;
  return 3;
}

function compareInterest(
  left: SharedCodexContentObserverInterest,
  right: SharedCodexContentObserverInterest,
): number {
  const priorityDifference = priority(left) - priority(right);
  if (priorityDifference !== 0) return priorityDifference;
  const recencyDifference =
    Date.parse(right.observedAt) - Date.parse(left.observedAt);
  if (Number.isFinite(recencyDifference) && recencyDifference !== 0) {
    return recencyDifference;
  }
  return left.threadId.localeCompare(right.threadId);
}

function isObservedMessage(message: ServerMessage): boolean {
  return (
    message.type === "context_usage" ||
    message.type === "assistant" ||
    message.type === "tool_result" ||
    message.type === "result" ||
    message.type === "guardian_approval" ||
    message.type === "error" ||
    message.type === "history_delta" ||
    message.type === "history_snapshot" ||
    message.type === "tool_use_summary" ||
    message.type === "user_input" ||
    message.type === "stream_delta" ||
    message.type === "thinking_delta"
  );
}

/**
 * Keeps a bounded set of settings-neutral, read-only attachments to threads
 * whose live content is useful to an interactive Mobile client.
 *
 * The coordinator never exposes an input loop and never listens for or answers
 * app-server requests. CodexProcess's `observer` attachment mode enforces the
 * same boundary again at the RPC layer.
 */
export class SharedCodexContentObserverCoordinator {
  private readonly createProcess: () => SharedCodexContentObserverProcess;
  private readonly codexSourceId?: string;
  private readonly onMessage: (
    event: SharedCodexContentObserverMessage,
  ) => void;
  private readonly onCompletion: (
    event: SharedCodexContentObserverCompletion,
  ) => void;
  private readonly maxObservers: number;
  private readonly unfocusGraceMs: number;
  private readonly attachTimeoutMs: number;
  private readonly maxConcurrentAttaches: number;
  private readonly retryDelaysMs: readonly number[];
  private readonly now: () => number;
  private readonly unsubscribeFormalAttachmentReleased: () => void;
  private readonly interests = new Map<
    string,
    SharedCodexContentObserverInterest
  >();
  private readonly observers = new Map<string, ObserverRecord>();
  private readonly retryAttempts = new Map<string, number>();
  private readonly retryTimers = new Map<
    string,
    ReturnType<typeof setTimeout>
  >();
  private connectionGeneration = 0;
  private observerGeneration = 0;
  private usageSequence = 0;
  private ready = false;
  private active = false;
  private closed = false;

  constructor(options: SharedCodexContentObserverCoordinatorOptions) {
    this.createProcess = options.createProcess;
    this.codexSourceId = options.codexSourceId;
    this.onMessage = options.onMessage;
    this.onCompletion = options.onCompletion;
    this.maxObservers = boundedPositiveInteger(
      options.maxObservers,
      DEFAULT_MAX_OBSERVERS,
    );
    this.unfocusGraceMs = boundedNonNegativeInteger(
      options.unfocusGraceMs,
      DEFAULT_UNFOCUS_GRACE_MS,
    );
    this.attachTimeoutMs = boundedPositiveInteger(
      options.attachTimeoutMs,
      DEFAULT_ATTACH_TIMEOUT_MS,
    );
    this.maxConcurrentAttaches = Math.min(
      this.maxObservers,
      boundedPositiveInteger(
        options.maxConcurrentAttaches,
        DEFAULT_MAX_CONCURRENT_ATTACHES,
      ),
    );
    this.retryDelaysMs =
      options.retryDelaysMs?.map((delay) =>
        boundedNonNegativeInteger(delay, 0),
      ) ?? DEFAULT_RETRY_DELAYS_MS;
    this.now = options.now ?? Date.now;
    this.unsubscribeFormalAttachmentReleased =
      subscribeSharedRuntimePilotFormalAttachmentReleased(
        (sourceId, threadId) => {
          if (this.codexSourceId && sourceId !== this.codexSourceId) return;
          if (this.closed || !this.interests.has(threadId)) return;
          const retryTimer = this.retryTimers.get(threadId);
          if (retryTimer) clearTimeout(retryTimer);
          this.retryTimers.delete(threadId);
          this.retryAttempts.delete(threadId);
          this.reconcile();
        },
      );
  }

  setAuthority(connectionGeneration: number, ready: boolean): void {
    if (this.closed || connectionGeneration < this.connectionGeneration) return;
    const generationChanged =
      connectionGeneration !== this.connectionGeneration;
    if (generationChanged || !ready) {
      this.connectionGeneration = connectionGeneration;
      this.observerGeneration += 1;
      this.closeAllObservers();
      this.cancelAllRetries();
      if (generationChanged) this.retryAttempts.clear();
    }
    this.ready = ready;
    if (ready) this.reconcile();
  }

  setActive(active: boolean): void {
    if (this.closed || this.active === active) return;
    this.active = active;
    if (!active) {
      this.observerGeneration += 1;
      this.closeAllObservers();
      this.cancelAllRetries();
      this.retryAttempts.clear();
      return;
    }
    this.reconcile();
  }

  setInterests(interests: readonly SharedCodexContentObserverInterest[]): void {
    if (this.closed) return;
    this.interests.clear();
    const retainedThreadIds = new Set<string>();
    for (const interest of interests) {
      if (!interest.threadId.trim()) continue;
      const previous = this.interests.get(interest.threadId);
      if (!previous || compareInterest(interest, previous) < 0) {
        this.interests.set(interest.threadId, { ...interest });
      }
      retainedThreadIds.add(interest.threadId);
    }
    for (const threadId of this.retryAttempts.keys()) {
      if (!retainedThreadIds.has(threadId)) this.retryAttempts.delete(threadId);
    }
    this.reconcile();
  }

  close(): void {
    if (this.closed) return;
    this.closed = true;
    this.active = false;
    this.ready = false;
    this.observerGeneration += 1;
    this.closeAllObservers();
    this.cancelAllRetries();
    this.interests.clear();
    this.retryAttempts.clear();
    this.unsubscribeFormalAttachmentReleased();
  }

  /** Test-only bounded visibility; it contains thread ids but no content. */
  get observedThreadIds(): readonly string[] {
    return [...this.observers.keys()];
  }

  private reconcile(): void {
    if (this.closed || !this.active || !this.ready) return;
    const selected = [...this.interests.values()]
      .filter(
        (interest) =>
          interest.needsAttention || interest.focused || interest.active,
      )
      .sort(compareInterest)
      .slice(0, this.maxObservers);
    const selectedIds = new Set(selected.map((interest) => interest.threadId));

    for (const [threadId, record] of [...this.observers]) {
      if (selectedIds.has(threadId)) {
        record.lastUsed = ++this.usageSequence;
        this.clearGraceTimer(record);
        continue;
      }
      // A higher-priority candidate must never be blocked by an old grace
      // observer. Otherwise preserve an unfocused observer briefly so a quick
      // page switch does not churn thread/resume attachments.
      if (selected.length >= this.maxObservers || this.unfocusGraceMs === 0) {
        this.closeObserver(threadId, record);
      } else if (!record.graceTimer) {
        record.graceTimer = setTimeout(() => {
          if (this.observers.get(threadId) !== record) return;
          this.closeObserver(threadId, record);
        }, this.unfocusGraceMs);
        record.graceTimer.unref?.();
      }
    }

    // Grace observers are bounded by the same cap. Evict the oldest
    // deterministic low-priority records before attaching replacements.
    while (this.observers.size >= this.maxObservers) {
      const evictable = [...this.observers.values()]
        .filter((record) => !selectedIds.has(record.threadId))
        .sort(
          (left, right) =>
            left.lastUsed - right.lastUsed ||
            left.threadId.localeCompare(right.threadId),
        )[0];
      if (!evictable) break;
      this.closeObserver(evictable.threadId, evictable);
    }

    let attaching = [...this.observers.values()].filter(
      (record) => record.attaching,
    ).length;
    for (const interest of selected) {
      if (this.observers.has(interest.threadId)) continue;
      if (this.retryTimers.has(interest.threadId)) continue;
      if (
        isSharedRuntimePilotObserverBlocked(
          interest.threadId,
          this.codexSourceId,
        )
      ) {
        continue;
      }
      if (this.observers.size >= this.maxObservers) break;
      if (attaching >= this.maxConcurrentAttaches) break;
      this.attach(interest);
      attaching += 1;
    }
  }

  private attach(interest: SharedCodexContentObserverInterest): void {
    const process = this.createProcess();
    const connectionGeneration = this.connectionGeneration;
    const observerGeneration = ++this.observerGeneration;
    const record: ObserverRecord = {
      threadId: interest.threadId,
      process,
      connectionGeneration,
      observerGeneration,
      onMessage: () => {},
      onExit: () => {},
      onYield: () => {},
      attaching: true,
      lastUsed: ++this.usageSequence,
      anonymousTurnSequence: 0,
    };
    record.onMessage = (message) => {
      if (!isObservedMessage(message) || !this.isCurrent(record)) return;
      const observedAt = new Date(this.now()).toISOString();
      const turnId = process.activeTurnId;
      if (turnId) {
        // A real turn id supersedes any temporary no-id scope from attachment
        // startup. Never carry that fallback into a later anonymous turn.
        record.anonymousTurnScope = undefined;
      } else if (!record.anonymousTurnScope) {
        record.anonymousTurnScope =
          `observer:${observerGeneration}:turn:${++record.anonymousTurnSequence}`;
      }
      const event = {
        threadId: interest.threadId,
        connectionGeneration,
        observerGeneration,
        observedAt,
        ...(turnId ? { turnId } : {}),
        ...(!turnId && record.anonymousTurnScope
          ? { anonymousTurnScope: record.anonymousTurnScope }
          : {}),
      };
      this.onMessage({ ...event, message });
      if (message.type === "result") {
        this.onCompletion(event);
        record.anonymousTurnScope = undefined;
      }
    };
    record.onExit = () => {
      if (!this.isCurrent(record)) return;
      this.observers.delete(interest.threadId);
      this.detachListeners(record);
      this.scheduleRetry(interest.threadId);
    };
    record.onYield = () => {
      if (!this.isCurrent(record)) return;
      this.closeObserver(interest.threadId, record);
    };
    process.on("message", record.onMessage);
    process.on("exit", record.onExit);
    process.on("shared_runtime_yield", record.onYield);
    this.observers.set(interest.threadId, record);

    try {
      process.start(interest.projectPath || ".", {
        threadId: interest.threadId,
        sharedRuntimeAttach: "observer",
      });
    } catch {
      this.failAttach(record);
      return;
    }

    void process
      .waitUntilAttached(this.attachTimeoutMs)
      .then(() => {
        if (!this.isCurrent(record)) return;
        record.attaching = false;
        // A healthy attachment starts a fresh failure episode. Without this,
        // one transient failure before a successful attach permanently
        // consumes retry budget for a later, unrelated process exit.
        this.retryAttempts.delete(record.threadId);
        this.reconcile();
      })
      .catch(() => this.failAttach(record));
  }

  private failAttach(record: ObserverRecord): void {
    if (!this.isCurrent(record)) return;
    this.closeObserver(record.threadId, record);
    this.scheduleRetry(record.threadId);
  }

  private scheduleRetry(threadId: string): void {
    if (
      this.closed ||
      !this.active ||
      !this.ready ||
      this.retryTimers.has(threadId) ||
      !this.interests.has(threadId)
    ) {
      return;
    }
    const attempt = this.retryAttempts.get(threadId) ?? 0;
    const delay = this.retryDelaysMs[attempt];
    if (delay === undefined) return;
    this.retryAttempts.set(threadId, attempt + 1);
    const generation = this.connectionGeneration;
    const timer = setTimeout(() => {
      if (this.retryTimers.get(threadId) !== timer) return;
      this.retryTimers.delete(threadId);
      if (
        this.connectionGeneration !== generation ||
        !this.active ||
        !this.ready ||
        !this.interests.has(threadId)
      ) {
        return;
      }
      this.reconcile();
    }, delay);
    timer.unref?.();
    this.retryTimers.set(threadId, timer);
  }

  private isCurrent(record: ObserverRecord): boolean {
    return (
      !this.closed &&
      this.active &&
      this.ready &&
      this.connectionGeneration === record.connectionGeneration &&
      this.observers.get(record.threadId) === record
    );
  }

  private closeObserver(threadId: string, record: ObserverRecord): void {
    if (this.observers.get(threadId) !== record) return;
    this.observers.delete(threadId);
    this.clearGraceTimer(record);
    this.detachListeners(record);
    record.process.stop();
  }

  private closeAllObservers(): void {
    for (const [threadId, record] of [...this.observers]) {
      this.closeObserver(threadId, record);
    }
  }

  private detachListeners(record: ObserverRecord): void {
    record.process.off("message", record.onMessage);
    record.process.off("exit", record.onExit);
    record.process.off("shared_runtime_yield", record.onYield);
  }

  private clearGraceTimer(record: ObserverRecord): void {
    if (!record.graceTimer) return;
    clearTimeout(record.graceTimer);
    record.graceTimer = undefined;
  }

  private cancelAllRetries(): void {
    for (const timer of this.retryTimers.values()) clearTimeout(timer);
    this.retryTimers.clear();
  }
}

export function asSharedCodexContentObserverProcess(
  process: CodexProcess,
): SharedCodexContentObserverProcess {
  return process;
}
