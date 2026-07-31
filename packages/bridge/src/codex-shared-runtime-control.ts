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
const activeControls = new Set<CodexSharedRuntimeControl>();

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
  requestId?: string;
  threadStatus?: CodexSharedRuntimeSafeThreadStatus;
  turnStatus?:
    "inProgress" | "completed" | "interrupted" | "failed" | "unknown";
}

interface CodexSharedRuntimeControlEvents {
  ready: [number];
  not_ready: [number];
  event: [CodexSharedRuntimeControlEvent];
  diagnostic: ["transport_error" | "transport_exit" | "initialize_rejected"];
}

export interface CodexSharedRuntimeControlOptions {
  projectPath: string;
  env?: NodeJS.ProcessEnv;
  platform?: NodeJS.Platform;
  eventCapacity?: number;
  now?: () => Date;
  transportFactory?: (projectPath: string) => CodexTransport;
  daemonIdentityProvider?: () => CodexSharedRuntimeSafeDaemonIdentity;
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
  timer?: NodeJS.Timeout;
}

/**
 * Stage 1 control-plane observer for the shared Codex daemon.
 *
 * It performs only initialize/initialized, never answers a server request and
 * never issues a thread RPC. The daemon remains independently owned; stop()
 * closes only this transport.
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

  private transport: CodexTransport | null = null;
  private _ready = false;
  private startupFailure: Error | null = null;
  private readonly readyWaiters = new Set<ReadyWaiter>();
  private _connectionGeneration = 0;
  private _daemonIdentity: Readonly<CodexSharedRuntimeSafeDaemonIdentity> | null =
    null;
  private initSequence = 0;
  private pendingInitializeId: number | null = null;
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

  waitUntilReady(timeoutMs = 15_000): Promise<void> {
    if (this._ready) return Promise.resolve();
    if (this.startupFailure) return Promise.reject(this.startupFailure);
    return new Promise<void>((resolve, reject) => {
      const waiter: ReadyWaiter = { resolve, reject };
      if (Number.isFinite(timeoutMs) && timeoutMs > 0) {
        waiter.timer = setTimeout(() => {
          this.readyWaiters.delete(waiter);
          reject(
            new Error(
              `Shared runtime control did not become ready within ${Math.floor(timeoutMs)}ms`,
            ),
          );
        }, Math.floor(timeoutMs));
        waiter.timer.unref?.();
      }
      this.readyWaiters.add(waiter);
    });
  }

  start(): void {
    if (this.transport) {
      throw new Error("Shared runtime control is already started");
    }

    this._daemonIdentity = Object.freeze(
      validateSafeDaemonIdentity(this.daemonIdentityProvider()),
    );
    const transport = this.transportFactory(this.projectPath);
    this.transport = transport;
    this._ready = false;
    this.startupFailure = null;
    this.lineBuffer = "";
    this.lineBufferBytes = 0;
    this.discardUntilNewline = false;

    const ownsTransport = (): boolean => this.transport === transport;
    transport.on("data", (chunk) => {
      if (!ownsTransport()) return;
      this._connectionGeneration = transport.connectionGeneration;
      this.handleData(chunk);
    });
    transport.on("error", () => {
      if (!ownsTransport()) return;
      activeControls.delete(this);
      this._connectionGeneration = transport.connectionGeneration;
      this.markNotReady();
      this.failStartup(
        new Error("Shared runtime control transport failed before readiness"),
      );
      this.emit("diagnostic", "transport_error");
    });
    transport.on("exit", () => {
      if (!ownsTransport()) return;
      activeControls.delete(this);
      this._connectionGeneration = transport.connectionGeneration;
      this.markNotReady();
      this.failStartup(
        new Error("Shared runtime control transport exited before readiness"),
      );
      this.emit("diagnostic", "transport_exit");
    });

    try {
      transport.start(this.projectPath);
      this._connectionGeneration = transport.connectionGeneration;
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
      this.transport = null;
      this.pendingInitializeId = null;
      transport.stop();
      this._connectionGeneration = transport.connectionGeneration;
      throw error;
    }
  }

  stop(): void {
    activeControls.delete(this);
    const transport = this.transport;
    this.transport = null;
    this.pendingInitializeId = null;
    this.lineBuffer = "";
    this.lineBufferBytes = 0;
    this.discardUntilNewline = false;
    this.markNotReady();
    this.failStartup(new Error("Shared runtime control stopped"));
    if (!transport) return;
    transport.stop();
    this._connectionGeneration = transport.connectionGeneration;
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
      if (waiter.timer) clearTimeout(waiter.timer);
      waiter.reject(error);
    }
    this.readyWaiters.clear();
  }

  private markReady(): void {
    this.startupFailure = null;
    this._ready = true;
    for (const waiter of this.readyWaiters) {
      if (waiter.timer) clearTimeout(waiter.timer);
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

    // A JSON-RPC request has both id and method. The observer deliberately
    // sends no success and no error response; another authoritative client may
    // own it on the shared daemon.
    if (envelope.id != null && typeof envelope.method === "string") return;
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
    if (envelope.error !== undefined || envelope.result === undefined) {
      this.failStartup(
        new Error("Shared runtime control initialize was rejected"),
      );
      this.markNotReady();
      this.emit("diagnostic", "initialize_rejected");
      return;
    }
    const transport = this.transport;
    if (!transport || !transport.isRunning) return;
    transport.write({ method: "initialized", params: {} });
    this._connectionGeneration = transport.connectionGeneration;
    if (!this._ready) {
      this.markReady();
    }
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
    const requestId = opaqueId(params.requestId);
    if (requestId) event.requestId = requestId;
  }
  return event;
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
