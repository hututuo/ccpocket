import { EventEmitter } from "node:events";
import {
  readCodexDaemonConfig,
  readCodexAppServerMode,
} from "./codex-app-server-config.js";
import {
  type CodexTransport,
  createCodexTransport,
} from "./codex-transport.js";
import { verifyCodexDaemon } from "./codex-daemon-supervisor.js";
import {
  readSharedRuntimePilotGates,
  type SharedRuntimePilotGates,
} from "./codex-shared-runtime-pilot.js";

const DEFAULT_EVENT_CAPACITY = 256;
const MAX_EVENT_CAPACITY = 4096;
const MAX_CONTROL_LINE_BYTES = 512 * 1024;
const MAX_OPAQUE_ID_LENGTH = 256;
const DEFAULT_RECONNECT_BASE_DELAY_MS = 250;
const DEFAULT_RECONNECT_MAX_DELAY_MS = 10_000;
const activeControls = new Set<CodexSharedRuntimeControl>();

type ControlTimer = ReturnType<typeof setTimeout>;
type ControlSetTimeout = (
  callback: () => void,
  delayMs: number,
) => ControlTimer;
type ControlClearTimeout = (timer: ControlTimer) => void;

export type CodexSharedRuntimeControlMethod =
  | "thread/started"
  | "thread/status/changed"
  | "thread/name/updated"
  | "turn/started"
  | "turn/completed"
  | "serverRequest/resolved";

export interface CodexSharedRuntimeSafeDaemonIdentity {
  expectedVersion: string;
  cliVersion: string;
  appServerVersion: string;
  socketDevice: number;
  socketInode: number;
}

export interface CodexSharedRuntimeSafeThreadStatus {
  type: "notLoaded" | "idle" | "systemError" | "active" | "unknown";
  activeFlags?: Array<"waitingOnApproval" | "waitingOnUserInput">;
}

/**
 * Deliberately content-free observation. Names, prompts, paths, tool payloads,
 * error text and message bodies never enter the ring.
 */
export interface CodexSharedRuntimeControlEvent {
  sequence: number;
  observedAt: string;
  connectionGeneration: number;
  method: CodexSharedRuntimeControlMethod;
  threadId?: string;
  turnId?: string;
  requestId?: number | string;
  threadStatus?: CodexSharedRuntimeSafeThreadStatus;
  turnStatus?:
    "inProgress" | "completed" | "interrupted" | "failed" | "unknown";
}

/**
 * Connection-affine JSON-RPC request. Full params are never added to the
 * diagnostic ring or durable storage; Action Broker consumers may retain them
 * only for this exact control connection generation.
 */
export interface CodexSharedRuntimeServerRequest {
  requestId: number | string;
  method: string;
  params: Record<string, unknown>;
  observedAt: string;
  connectionGeneration: number;
  threadId?: string;
  turnId?: string;
}

interface CodexSharedRuntimeControlEvents {
  ready: [number];
  not_ready: [number];
  event: [CodexSharedRuntimeControlEvent];
  server_request: [CodexSharedRuntimeServerRequest];
  diagnostic: [
    | "transport_error"
    | "transport_exit"
    | "initialize_rejected"
    | "config_read_rejected"
    | "incompatible_config",
  ];
}

export interface CodexSharedRuntimeControlOptions {
  projectPath: string;
  env?: NodeJS.ProcessEnv;
  platform?: NodeJS.Platform;
  eventCapacity?: number;
  now?: () => Date;
  transportFactory?: (projectPath: string) => CodexTransport;
  daemonIdentityProvider?: () => CodexSharedRuntimeSafeDaemonIdentity;
  reconnectBaseDelayMs?: number;
  reconnectMaxDelayMs?: number;
  random?: () => number;
  setTimeoutFn?: ControlSetTimeout;
  clearTimeoutFn?: ControlClearTimeout;
}

interface JsonRpcEnvelope {
  id?: number | string | null;
  method?: string;
  params?: Record<string, unknown>;
  result?: unknown;
  error?: unknown;
}

interface ReadyWaiter {
  resolve: () => void;
  reject: (error: Error) => void;
  timer?: ControlTimer;
}

/**
 * Stage 1 control-plane observer for the shared Codex daemon.
 *
 * It performs initialize/initialized plus one read-only effective-config
 * preflight, never answers a server request, and never issues a thread RPC.
 * The daemon remains independently owned; stop() closes only this transport.
 */
export class CodexSharedRuntimeControl extends EventEmitter<CodexSharedRuntimeControlEvents> {
  private readonly env: NodeJS.ProcessEnv;
  private readonly platform: NodeJS.Platform;
  private readonly projectPath: string;
  private readonly eventCapacity: number;
  private readonly now: () => Date;
  private readonly transportFactory: (projectPath: string) => CodexTransport;
  private readonly daemonIdentityProvider: () => CodexSharedRuntimeSafeDaemonIdentity;
  private readonly frozenGates: Readonly<SharedRuntimePilotGates>;
  private readonly reconnectBaseDelayMs: number;
  private readonly reconnectMaxDelayMs: number;
  private readonly random: () => number;
  private readonly setTimeoutFn: ControlSetTimeout;
  private readonly clearTimeoutFn: ControlClearTimeout;

  private transport: CodexTransport | null = null;
  private started = false;
  private hasEverBeenReady = false;
  private reconnectAttempt = 0;
  private reconnectTimer: ControlTimer | null = null;
  private _ready = false;
  private startupFailure: Error | null = null;
  private readonly readyWaiters = new Set<ReadyWaiter>();
  private _connectionGeneration = 0;
  private _daemonIdentity: Readonly<CodexSharedRuntimeSafeDaemonIdentity> | null =
    null;
  private initSequence = 0;
  private pendingInitializeId: number | null = null;
  private pendingConfigReadId: number | null = null;
  private lineBuffer = "";
  private lineBufferBytes = 0;
  private discardUntilNewline = false;
  private eventSequence = 0;
  private readonly eventRing: CodexSharedRuntimeControlEvent[] = [];

  constructor(options: CodexSharedRuntimeControlOptions) {
    super();
    this.env = { ...(options.env ?? process.env) };
    this.platform = options.platform ?? process.platform;
    this.projectPath = options.projectPath;
    this.eventCapacity = normalizeEventCapacity(options.eventCapacity);
    this.now = options.now ?? (() => new Date());

    if (readCodexAppServerMode(this.env) !== "daemon") {
      throw new Error("Shared runtime control requires daemon app-server mode");
    }
    this.frozenGates = Object.freeze({
      ...readSharedRuntimePilotGates(this.env),
    });

    this.transportFactory =
      options.transportFactory ??
      ((projectPath) =>
        createCodexTransport(projectPath, this.platform, this.env));
    this.daemonIdentityProvider =
      options.daemonIdentityProvider ??
      (() => {
        const verified = verifyCodexDaemon(
          readCodexDaemonConfig(this.env, this.platform),
        );
        return {
          expectedVersion: verified.config.expectedVersion,
          cliVersion: verified.cliVersion,
          appServerVersion: verified.appServerVersion,
          socketDevice: verified.socketIdentity.device,
          socketInode: verified.socketIdentity.inode,
        };
      });
    this.reconnectBaseDelayMs = normalizeReconnectDelay(
      options.reconnectBaseDelayMs,
      DEFAULT_RECONNECT_BASE_DELAY_MS,
      "base",
    );
    this.reconnectMaxDelayMs = normalizeReconnectDelay(
      options.reconnectMaxDelayMs,
      DEFAULT_RECONNECT_MAX_DELAY_MS,
      "maximum",
    );
    if (this.reconnectMaxDelayMs < this.reconnectBaseDelayMs) {
      throw new Error(
        "Shared runtime control reconnect maximum must be at least the base delay",
      );
    }
    this.random = options.random ?? Math.random;
    this.setTimeoutFn =
      options.setTimeoutFn ??
      ((callback, delayMs) => setTimeout(callback, delayMs));
    this.clearTimeoutFn =
      options.clearTimeoutFn ?? ((timer) => clearTimeout(timer));
  }

  get ready(): boolean {
    return this._ready;
  }

  get connectionGeneration(): number {
    return this._connectionGeneration;
  }

  get pilotGates(): Readonly<SharedRuntimePilotGates> {
    return this.frozenGates;
  }

  get daemonIdentity(): Readonly<CodexSharedRuntimeSafeDaemonIdentity> | null {
    return this._daemonIdentity ? { ...this._daemonIdentity } : null;
  }

  get events(): CodexSharedRuntimeControlEvent[] {
    return this.eventRing.map(cloneControlEvent);
  }

  /**
   * Respond on the same live connection that observed the request. A false
   * result means the authority generation changed and the caller must leave
   * the durable request unresolved/fail closed.
   */
  respondToServerRequest(
    request: Pick<
      CodexSharedRuntimeServerRequest,
      "requestId" | "connectionGeneration"
    >,
    result: Record<string, unknown>,
  ): boolean {
    if (
      !this._ready ||
      !this.transport?.isRunning ||
      request.connectionGeneration !== this._connectionGeneration
    ) {
      return false;
    }
    this.transport.write({ id: request.requestId, result });
    return true;
  }

  waitUntilReady(timeoutMs = 15_000): Promise<void> {
    if (this._ready) return Promise.resolve();
    if (this.startupFailure) return Promise.reject(this.startupFailure);
    return new Promise<void>((resolve, reject) => {
      const waiter: ReadyWaiter = { resolve, reject };
      if (Number.isFinite(timeoutMs) && timeoutMs > 0) {
        waiter.timer = this.setTimeoutFn(() => {
          this.readyWaiters.delete(waiter);
          reject(
            new Error(
              `Shared runtime control did not become ready within ${Math.floor(timeoutMs)}ms`,
            ),
          );
        }, Math.floor(timeoutMs));
        unrefTimer(waiter.timer);
      }
      this.readyWaiters.add(waiter);
    });
  }

  start(): void {
    if (this.started || this.transport || this.reconnectTimer !== null) {
      throw new Error("Shared runtime control is already started");
    }
    this.started = true;
    this.hasEverBeenReady = false;
    this.reconnectAttempt = 0;
    this._ready = false;
    this.startupFailure = null;
    this._daemonIdentity = null;
    this.resetConnectionBuffers();
    try {
      this.openTransport(true);
      if (this.startupFailure) throw this.startupFailure;
    } catch (error) {
      this.started = false;
      const failure = asError(error);
      this.failStartup(failure);
      throw failure;
    }
  }

  stop(): void {
    this.started = false;
    this.hasEverBeenReady = false;
    this.reconnectAttempt = 0;
    this.cancelReconnect();
    activeControls.delete(this);
    const transport = this.transport;
    this.transport = null;
    this.pendingInitializeId = null;
    this.pendingConfigReadId = null;
    this.resetConnectionBuffers();
    this.markNotReady();
    this.failStartup(new Error("Shared runtime control stopped"));
    if (!transport) return;
    transport.stop();
  }

  private openTransport(initialStartup: boolean): void {
    if (!this.started) return;
    let transport: CodexTransport;
    try {
      this._daemonIdentity = Object.freeze(
        validateSafeDaemonIdentity(this.daemonIdentityProvider()),
      );
      transport = this.transportFactory(this.projectPath);
    } catch (error) {
      if (!initialStartup) this.emit("diagnostic", "transport_error");
      this.handleConnectionAttemptFailure(error, initialStartup);
      return;
    }

    const generation = ++this._connectionGeneration;
    this.transport = transport;
    this.pendingInitializeId = null;
    this.pendingConfigReadId = null;
    this.resetConnectionBuffers();
    const ownsTransport = (): boolean =>
      this.started &&
      this.transport === transport &&
      this._connectionGeneration === generation;

    transport.on("data", (chunk) => {
      if (!ownsTransport()) return;
      this.handleData(chunk);
    });
    transport.on("error", () => {
      if (!ownsTransport()) return;
      this.handleTransportFailure(
        transport,
        generation,
        "transport_error",
        "Shared runtime control transport failed before readiness",
      );
    });
    transport.on("exit", () => {
      if (!ownsTransport()) return;
      this.handleTransportFailure(
        transport,
        generation,
        "transport_exit",
        "Shared runtime control transport exited before readiness",
      );
    });

    try {
      transport.start(this.projectPath);
      if (!ownsTransport()) return;
      const initializeId = ++this.initSequence;
      this.pendingInitializeId = initializeId;
      transport.write({
        id: initializeId,
        method: "initialize",
        params: {
          clientInfo: {
            name: "ccpocket_bridge_control_observer",
            version: "1.0.0",
            title: "CC Pocket Bridge control observer",
          },
          capabilities: { experimentalApi: true },
        },
      });
    } catch (error) {
      const released =
        ownsTransport() && this.releaseTransport(transport, generation);
      if (!released) {
        if (initialStartup && this.startupFailure) throw this.startupFailure;
        return;
      }
      this.emit("diagnostic", "transport_error");
      this.handleConnectionAttemptFailure(error, initialStartup);
    }
  }

  private handleTransportFailure(
    transport: CodexTransport,
    generation: number,
    diagnostic: "transport_error" | "transport_exit" | "initialize_rejected",
    startupMessage: string,
  ): void {
    if (!this.releaseTransport(transport, generation)) return;
    this.emit("diagnostic", diagnostic);
    if (!this.hasEverBeenReady) {
      this.started = false;
      this.failStartup(new Error(startupMessage));
      return;
    }
    this.scheduleReconnect();
  }

  private handleConnectionAttemptFailure(
    error: unknown,
    initialStartup: boolean,
  ): void {
    const failure = asError(error);
    if (initialStartup && !this.hasEverBeenReady) {
      this.started = false;
      this.failStartup(failure);
      throw failure;
    }
    this.scheduleReconnect();
  }

  private releaseTransport(
    transport: CodexTransport,
    generation: number,
  ): boolean {
    if (
      this.transport !== transport ||
      this._connectionGeneration !== generation
    ) {
      return false;
    }
    this.transport = null;
    this.pendingInitializeId = null;
    this.pendingConfigReadId = null;
    activeControls.delete(this);
    this.resetConnectionBuffers();
    this.markNotReady();
    transport.stop();
    return true;
  }

  private scheduleReconnect(): void {
    if (!this.started || this.reconnectTimer !== null) return;
    const exponent = Math.min(this.reconnectAttempt, 30);
    const exponentialDelay = Math.min(
      this.reconnectMaxDelayMs,
      this.reconnectBaseDelayMs * 2 ** exponent,
    );
    this.reconnectAttempt += 1;
    const jitter = 0.5 + clampUnitInterval(this.random()) * 0.5;
    const delayMs = Math.max(
      1,
      Math.min(this.reconnectMaxDelayMs, Math.floor(exponentialDelay * jitter)),
    );
    this.reconnectTimer = this.setTimeoutFn(() => {
      this.reconnectTimer = null;
      if (!this.started) return;
      this.openTransport(false);
    }, delayMs);
    unrefTimer(this.reconnectTimer);
  }

  private cancelReconnect(): void {
    const timer = this.reconnectTimer;
    this.reconnectTimer = null;
    if (timer !== null) this.clearTimeoutFn(timer);
  }

  private resetConnectionBuffers(): void {
    this.lineBuffer = "";
    this.lineBufferBytes = 0;
    this.discardUntilNewline = false;
  }

  private markNotReady(): void {
    if (!this._ready) return;
    this._ready = false;
    this.emit("not_ready", this._connectionGeneration);
  }

  private failStartup(error: Error): void {
    if (this.startupFailure) return;
    this.startupFailure = error;
    for (const waiter of this.readyWaiters) {
      if (waiter.timer !== undefined) this.clearTimeoutFn(waiter.timer);
      waiter.reject(error);
    }
    this.readyWaiters.clear();
  }

  private markReady(): void {
    this.startupFailure = null;
    this.hasEverBeenReady = true;
    this.reconnectAttempt = 0;
    this._ready = true;
    for (const waiter of this.readyWaiters) {
      if (waiter.timer !== undefined) this.clearTimeoutFn(waiter.timer);
      waiter.resolve();
    }
    this.readyWaiters.clear();
    activeControls.add(this);
    this.emit("ready", this._connectionGeneration);
  }

  /**
   * Records lifecycle that the global control connection cannot receive
   * without subscribing to a thread.  The authoritative Bridge attachment
   * remains the sole subscriber/writer; only the already-sanitized identity
   * and state fields enter this diagnostic ring.
   */
  recordAttachmentLifecycle(
    method: "turn/started" | "turn/completed",
    params: Record<string, unknown>,
  ): void {
    if (!this._ready || !activeControls.has(this)) return;
    const event = sanitizeControlEvent(
      method,
      params,
      ++this.eventSequence,
      this.now().toISOString(),
      this._connectionGeneration,
    );
    if (event) this.appendEvent(event);
  }

  private handleData(chunk: string): void {
    let offset = 0;
    if (this.discardUntilNewline) {
      const newline = chunk.indexOf("\n");
      if (newline < 0) return;
      this.discardUntilNewline = false;
      offset = newline + 1;
    }

    while (offset < chunk.length) {
      const newline = chunk.indexOf("\n", offset);
      const fragment =
        newline < 0 ? chunk.slice(offset) : chunk.slice(offset, newline);
      if (!this.appendLineFragment(fragment)) {
        this.resetLineBuffer();
        if (newline < 0) {
          this.discardUntilNewline = true;
          return;
        }
      } else if (newline >= 0) {
        const line = this.lineBuffer.trim();
        this.resetLineBuffer();
        if (line) this.handleLine(line);
      }
      if (newline < 0) return;
      offset = newline + 1;
    }
  }

  private appendLineFragment(fragment: string): boolean {
    const bytes = this.lineBufferBytes + Buffer.byteLength(fragment, "utf8");
    if (bytes > MAX_CONTROL_LINE_BYTES) return false;
    this.lineBuffer += fragment;
    this.lineBufferBytes = bytes;
    return true;
  }

  private resetLineBuffer(): void {
    this.lineBuffer = "";
    this.lineBufferBytes = 0;
  }

  private handleLine(line: string): void {
    let envelope: JsonRpcEnvelope;
    try {
      envelope = JSON.parse(line) as JsonRpcEnvelope;
    } catch {
      return;
    }

    if (
      this.pendingInitializeId !== null &&
      envelope.id === this.pendingInitializeId &&
      envelope.method === undefined
    ) {
      this.handleInitializeResponse(envelope);
      return;
    }

    if (
      this.pendingConfigReadId !== null &&
      envelope.id === this.pendingConfigReadId &&
      envelope.method === undefined
    ) {
      this.handleConfigReadResponse(envelope);
      return;
    }

    // A JSON-RPC request has both id and method. Keep its payload strictly in
    // memory and hand it to the Action Broker; this control transport never
    // answers it automatically. Shared mode must not create a second
    // currentTime/read first responder. The effective-config preflight below
    // rejects external-clock topology before readiness.
    if (envelope.id != null && typeof envelope.method === "string") {
      const observedAt = this.now().toISOString();
      const request = sanitizeServerRequest(
        envelope.id,
        envelope.method,
        envelope.params,
        observedAt,
        this._connectionGeneration,
      );
      if (!request) return;
      this.emit("server_request", request);
      return;
    }
    if (typeof envelope.method !== "string") return;

    const event = sanitizeControlEvent(
      envelope.method,
      envelope.params,
      ++this.eventSequence,
      this.now().toISOString(),
      this._connectionGeneration,
    );
    if (!event) return;
    this.appendEvent(event);
  }

  private appendEvent(event: CodexSharedRuntimeControlEvent): void {
    this.eventRing.push(event);
    if (this.eventRing.length > this.eventCapacity) this.eventRing.shift();
    this.emit("event", cloneControlEvent(event));
  }

  private handleInitializeResponse(envelope: JsonRpcEnvelope): void {
    this.pendingInitializeId = null;
    const transport = this.transport;
    const generation = this._connectionGeneration;
    if (!transport) return;
    if (envelope.error !== undefined || envelope.result === undefined) {
      this.handleTransportFailure(
        transport,
        generation,
        "initialize_rejected",
        "Shared runtime control initialize was rejected",
      );
      return;
    }
    if (!transport.isRunning) {
      this.handleTransportFailure(
        transport,
        generation,
        "transport_exit",
        "Shared runtime control transport exited before readiness",
      );
      return;
    }
    try {
      transport.write({ method: "initialized", params: {} });
      const configReadId = ++this.initSequence;
      this.pendingConfigReadId = configReadId;
      transport.write({
        id: configReadId,
        method: "config/read",
        params: { includeLayers: false },
      });
    } catch {
      this.handleTransportFailure(
        transport,
        generation,
        "transport_error",
        "Shared runtime control transport failed before readiness",
      );
      return;
    }
  }

  private handleConfigReadResponse(envelope: JsonRpcEnvelope): void {
    this.pendingConfigReadId = null;
    const transport = this.transport;
    const generation = this._connectionGeneration;
    if (!transport) return;
    if (envelope.error !== undefined || envelope.result === undefined) {
      this.failIncompatibleRuntime(
        transport,
        generation,
        "config_read_rejected",
        "Shared runtime config/read preflight was rejected",
      );
      return;
    }
    const result = asRecord(envelope.result);
    const config = asRecord(result?.config);
    if (!config) {
      this.failIncompatibleRuntime(
        transport,
        generation,
        "config_read_rejected",
        "Shared runtime config/read preflight returned an invalid config",
      );
      return;
    }
    if (usesExternalCurrentTime(config)) {
      this.failIncompatibleRuntime(
        transport,
        generation,
        "incompatible_config",
        "Shared runtime is incompatible with external current-time reminders",
      );
      return;
    }
    if (!transport.isRunning) {
      this.handleTransportFailure(
        transport,
        generation,
        "transport_exit",
        "Shared runtime control transport exited before readiness",
      );
      return;
    }
    if (!this._ready) this.markReady();
  }

  private failIncompatibleRuntime(
    transport: CodexTransport,
    generation: number,
    diagnostic: "config_read_rejected" | "incompatible_config",
    message: string,
  ): void {
    if (!this.releaseTransport(transport, generation)) return;
    this.started = false;
    this.cancelReconnect();
    this.emit("diagnostic", diagnostic);
    this.failStartup(new Error(message));
  }
}

/**
 * Called only after a CodexProcess has proved current-generation ownership of
 * the exact thread.  It never sends an RPC and therefore cannot acquire or
 * transfer app-server write ownership.
 */
export function recordSharedRuntimeAttachmentLifecycle(
  method: "turn/started" | "turn/completed",
  params: Record<string, unknown>,
): void {
  for (const control of activeControls) {
    control.recordAttachmentLifecycle(method, params);
  }
}

function normalizeReconnectDelay(
  value: number | undefined,
  fallback: number,
  label: string,
): number {
  if (value === undefined) return fallback;
  if (!Number.isFinite(value) || value < 1 || value > 2_147_483_647) {
    throw new Error(
      `Shared runtime control reconnect ${label} delay is invalid`,
    );
  }
  return Math.floor(value);
}

function clampUnitInterval(value: number): number {
  if (!Number.isFinite(value)) return 0.5;
  return Math.max(0, Math.min(1, value));
}

function unrefTimer(timer: ControlTimer): void {
  timer.unref?.();
}

function asError(error: unknown): Error {
  return error instanceof Error ? error : new Error(String(error));
}

function normalizeEventCapacity(value: number | undefined): number {
  if (value === undefined) return DEFAULT_EVENT_CAPACITY;
  if (!Number.isInteger(value) || value < 1 || value > MAX_EVENT_CAPACITY) {
    throw new Error(
      `Shared runtime control event capacity must be between 1 and ${MAX_EVENT_CAPACITY}`,
    );
  }
  return value;
}

function validateSafeDaemonIdentity(
  identity: CodexSharedRuntimeSafeDaemonIdentity,
): CodexSharedRuntimeSafeDaemonIdentity {
  const expectedVersion = safeVersion(identity.expectedVersion);
  const cliVersion = safeVersion(identity.cliVersion);
  const appServerVersion = safeVersion(identity.appServerVersion);
  if (cliVersion !== expectedVersion || appServerVersion !== expectedVersion) {
    throw new Error("Shared runtime control daemon version mismatch");
  }
  if (
    !Number.isSafeInteger(identity.socketDevice) ||
    identity.socketDevice < 0 ||
    !Number.isSafeInteger(identity.socketInode) ||
    identity.socketInode < 0
  ) {
    throw new Error("Shared runtime control daemon socket identity is invalid");
  }
  return {
    expectedVersion,
    cliVersion,
    appServerVersion,
    socketDevice: identity.socketDevice,
    socketInode: identity.socketInode,
  };
}

function safeVersion(value: string): string {
  const normalized = typeof value === "string" ? value.trim() : "";
  if (!normalized || normalized.length > 128) {
    throw new Error("Shared runtime control daemon version is invalid");
  }
  return normalized;
}

function sanitizeControlEvent(
  method: string,
  rawParams: Record<string, unknown> | undefined,
  sequence: number,
  observedAt: string,
  connectionGeneration: number,
): CodexSharedRuntimeControlEvent | null {
  if (!isAllowedControlMethod(method)) return null;
  const params = asRecord(rawParams) ?? {};
  const thread = asRecord(params.thread);
  const turn = asRecord(params.turn);
  const threadId = opaqueId(params.threadId ?? thread?.id ?? turn?.threadId);
  const turnId = opaqueId(params.turnId ?? turn?.id);
  const event: CodexSharedRuntimeControlEvent = {
    sequence,
    observedAt,
    connectionGeneration,
    method,
    ...(threadId ? { threadId } : {}),
    ...(turnId ? { turnId } : {}),
  };

  if (method === "thread/started" || method === "thread/status/changed") {
    const status = safeThreadStatus(
      method === "thread/started" ? thread?.status : params.status,
    );
    if (status) event.threadStatus = status;
  }
  if (method === "turn/started" || method === "turn/completed") {
    event.turnStatus = safeTurnStatus(turn?.status);
  }
  if (method === "serverRequest/resolved") {
    const requestId = requestIdValue(params.requestId);
    if (requestId !== null) event.requestId = requestId;
  }
  return event;
}

function sanitizeServerRequest(
  requestId: number | string,
  method: string,
  rawParams: Record<string, unknown> | undefined,
  observedAt: string,
  connectionGeneration: number,
): CodexSharedRuntimeServerRequest | null {
  const normalizedRequestId = requestIdValue(requestId);
  if (normalizedRequestId === null || !method || method.length > 192) {
    return null;
  }
  const params = asRecord(rawParams) ?? {};
  const threadId = opaqueId(params.threadId);
  const turnId = opaqueId(params.turnId);
  return {
    requestId: normalizedRequestId,
    method,
    params: { ...params },
    observedAt,
    connectionGeneration,
    ...(threadId ? { threadId } : {}),
    ...(turnId ? { turnId } : {}),
  };
}

function requestIdValue(value: unknown): number | string | null {
  if (typeof value === "number") {
    return Number.isSafeInteger(value) ? value : null;
  }
  if (typeof value !== "string") return null;
  const normalized = value.trim();
  return normalized ? normalized.slice(0, MAX_OPAQUE_ID_LENGTH) : null;
}

function isAllowedControlMethod(
  method: string,
): method is CodexSharedRuntimeControlMethod {
  return (
    method === "thread/started" ||
    method === "thread/status/changed" ||
    method === "thread/name/updated" ||
    method === "turn/started" ||
    method === "turn/completed" ||
    method === "serverRequest/resolved"
  );
}

function safeThreadStatus(
  value: unknown,
): CodexSharedRuntimeSafeThreadStatus | null {
  const status = asRecord(value);
  if (!status) return null;
  switch (status.type) {
    case "notLoaded":
    case "idle":
    case "systemError":
      return { type: status.type };
    case "active":
      return {
        type: "active",
        activeFlags: Array.isArray(status.activeFlags)
          ? status.activeFlags.filter(
              (flag): flag is "waitingOnApproval" | "waitingOnUserInput" =>
                flag === "waitingOnApproval" || flag === "waitingOnUserInput",
            )
          : [],
      };
    default:
      return { type: "unknown" };
  }
}

function safeTurnStatus(
  value: unknown,
): CodexSharedRuntimeControlEvent["turnStatus"] {
  switch (value) {
    case "inProgress":
    case "completed":
    case "interrupted":
    case "failed":
      return value;
    default:
      return "unknown";
  }
}

function opaqueId(value: unknown): string | null {
  const normalized =
    typeof value === "string"
      ? value.trim()
      : typeof value === "number" && Number.isSafeInteger(value)
        ? String(value)
        : "";
  if (!normalized) return null;
  return normalized.slice(0, MAX_OPAQUE_ID_LENGTH);
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object"
    ? (value as Record<string, unknown>)
    : null;
}

function usesExternalCurrentTime(config: Record<string, unknown>): boolean {
  const features = asRecord(config.features);
  const currentTime = asRecord(
    features?.current_time_reminder ?? features?.currentTimeReminder,
  );
  return (
    currentTime?.clock_source === "external" ||
    currentTime?.clockSource === "external"
  );
}

function cloneControlEvent(
  event: CodexSharedRuntimeControlEvent,
): CodexSharedRuntimeControlEvent {
  return {
    ...event,
    ...(event.threadStatus
      ? {
          threadStatus: {
            ...event.threadStatus,
            ...(event.threadStatus.activeFlags
              ? { activeFlags: [...event.threadStatus.activeFlags] }
              : {}),
          },
        }
      : {}),
  };
}
