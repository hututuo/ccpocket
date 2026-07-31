import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { EventEmitter } from "node:events";
import { createConnection } from "node:net";
import { resolvePlatformPath } from "./path-utils.js";
import {
  readCodexDaemonConfig,
  readCodexAppServerMode,
  resolveCodexSharedAppServerUrl,
  type CodexAppServerMode,
} from "./codex-app-server-config.js";
import {
  assertCodexDaemonSocketIdentity,
  verifyCodexDaemon,
  type VerifiedCodexDaemon,
} from "./codex-daemon-supervisor.js";
import WebSocket, { type ClientOptions } from "ws";

export interface CodexTransportEvents {
  data: [string];
  log: [string];
  error: [Error];
  exit: [number | null];
}

export abstract class CodexTransport extends EventEmitter<CodexTransportEvents> {
  abstract start(projectPath: string): void;
  abstract write(envelope: Record<string, unknown>): void;
  abstract stop(): void;
  abstract get isRunning(): boolean;
  abstract get connectionGeneration(): number;
}

export function buildCodexSpawnSpec(
  projectPath: string,
  platform: NodeJS.Platform = process.platform,
): {
  command: string;
  args: string[];
  options: {
    cwd: string;
    stdio: "pipe";
    env: NodeJS.ProcessEnv;
    windowsVerbatimArguments?: boolean;
  };
} {
  const cwd = resolvePlatformPath(projectPath, platform);

  if (platform === "win32") {
    return {
      command: "cmd.exe",
      args: ["/d", "/s", "/c", "codex app-server --listen stdio://"],
      options: {
        cwd,
        stdio: "pipe",
        env: process.env,
        windowsVerbatimArguments: true,
      },
    };
  }

  return {
    command: "codex",
    args: ["app-server", "--listen", "stdio://"],
    options: {
      cwd,
      stdio: "pipe",
      env: process.env,
    },
  };
}

class StdioCodexTransport extends CodexTransport {
  private child: ChildProcessWithoutNullStreams | null = null;
  private generation = 0;

  constructor(private readonly platform: NodeJS.Platform) {
    super();
  }

  get isRunning(): boolean {
    return this.child !== null && !this.child.killed;
  }

  get connectionGeneration(): number {
    return this.generation;
  }

  start(projectPath: string): void {
    const generation = ++this.generation;
    const spawnSpec = buildCodexSpawnSpec(projectPath, this.platform);
    const child = spawn(spawnSpec.command, spawnSpec.args, spawnSpec.options);
    this.child = child;

    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => {
      if (generation !== this.generation || this.child !== child) return;
      this.emit("data", chunk);
    });

    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk: string) => {
      if (generation !== this.generation || this.child !== child) return;
      const line = chunk.trim();
      if (line) this.emit("log", line);
    });

    // A write can race the child dying (EPIPE); without a listener the stream
    // "error" event throws and takes down the whole Bridge process.
    child.stdin.on("error", (err) => {
      if (generation === this.generation && this.child === child) {
        this.emit("error", err);
      } else {
        this.emit(
          "log",
          `[codex-transport] stdin error after exit: ${err.message}`,
        );
      }
    });

    child.on("error", (err) => {
      // Spawn-level failures (ENOENT, EACCES) never emit "exit"; drop the
      // reference so isRunning/write stop treating the child as alive.
      if (generation === this.generation && this.child === child) {
        this.child = null;
        this.emit("error", err);
      }
    });

    child.on("exit", (code) => {
      if (generation !== this.generation || this.child !== child) return;
      this.child = null;
      this.emit("exit", code ?? 0);
    });
  }

  write(envelope: Record<string, unknown>): void {
    const child = this.child;
    // "killed" stays false when the child crashes on its own; the writable
    // check catches the window between the crash and the "exit" event.
    // Compare against false explicitly: test doubles may omit the property.
    if (!child || child.killed || child.stdin.writable === false) {
      throw new Error("codex app-server is not running");
    }
    child.stdin.write(`${JSON.stringify(envelope)}\n`, (err) => {
      if (err) {
        this.emit(
          "log",
          `[codex-transport] stdin write failed: ${err.message}`,
        );
      }
    });
  }

  stop(): void {
    this.generation += 1;
    if (this.child) {
      this.child.kill("SIGTERM");
      this.child = null;
    }
  }
}

function isInitializeEnvelope(envelope: Record<string, unknown>): boolean {
  return envelope.method === "initialize";
}

export class WebSocketCodexTransport extends CodexTransport {
  private ws: WebSocket | null = null;
  private stopped = true;
  private connected = false;
  private initialPayload: string | null = null;
  private retryTimer: NodeJS.Timeout | null = null;
  private firstAttemptAt = 0;
  private everConnected = false;
  private generation = 0;

  constructor(
    private readonly url: string,
    private readonly retryDurationMs = 0,
    private readonly clientOptions?: ClientOptions,
    private readonly beforeConnect?: () => void,
  ) {
    super();
  }

  get isRunning(): boolean {
    return (
      !this.stopped &&
      (this.connected || this.ws !== null || this.retryTimer !== null)
    );
  }

  get connectionGeneration(): number {
    return this.generation;
  }

  start(_projectPath: string): void {
    if (!this.stopped || this.ws || this.retryTimer) {
      throw new Error("codex app-server transport is already started");
    }
    this.stopped = false;
    this.connected = false;
    this.everConnected = false;
    this.initialPayload = null;
    this.firstAttemptAt = Date.now();
    this.connect();
  }

  write(envelope: Record<string, unknown>): void {
    if (this.stopped) {
      throw new Error("codex app-server is not running");
    }
    const payload = JSON.stringify(envelope);
    if (this.connected && this.ws?.readyState === WebSocket.OPEN) {
      const ws = this.ws;
      const generation = this.generation;
      ws.send(payload, (error) => {
        if (
          error &&
          !this.stopped &&
          generation === this.generation &&
          this.ws === ws
        ) {
          this.emit("error", error);
        }
      });
      return;
    }

    // CodexProcess starts bootstrap immediately after transport.start(). Keep
    // exactly one initialize request until the first socket opens. Business
    // RPCs, writes after a disconnect, and duplicate initialize calls are
    // never queued or replayed across a connection generation.
    if (
      !this.everConnected &&
      this.ws !== null &&
      this.initialPayload === null &&
      isInitializeEnvelope(envelope)
    ) {
      this.initialPayload = payload;
      return;
    }
    throw new Error(
      "codex app-server is not connected; request was not queued",
    );
  }

  stop(): void {
    this.stopped = true;
    this.connected = false;
    this.everConnected = false;
    this.initialPayload = null;
    this.generation += 1;
    if (this.retryTimer) {
      clearTimeout(this.retryTimer);
      this.retryTimer = null;
    }
    if (this.ws) {
      this.ws.close();
      this.ws = null;
    }
  }

  private connect(): void {
    if (this.stopped) return;

    const generation = ++this.generation;
    let ws: WebSocket;
    try {
      this.beforeConnect?.();
      ws = new WebSocket(this.url, this.clientOptions);
    } catch (error) {
      if (this.shouldRetry()) {
        this.scheduleRetry(generation);
        return;
      }
      this.emit(
        "error",
        error instanceof Error ? error : new Error(String(error)),
      );
      return;
    }
    this.ws = ws;
    const isCurrent = (): boolean =>
      !this.stopped && generation === this.generation && this.ws === ws;

    ws.on("open", () => {
      if (!isCurrent()) return;
      this.connected = true;
      this.everConnected = true;
      const payload = this.initialPayload;
      this.initialPayload = null;
      if (payload !== null) {
        ws.send(payload, (error) => {
          if (error && isCurrent()) {
            this.emit("error", error);
          }
        });
      }
    });

    ws.on("message", (data) => {
      if (!isCurrent()) return;
      const text = data.toString();
      this.emit("data", text.endsWith("\n") ? text : `${text}\n`);
    });

    ws.on("error", (err) => {
      if (!isCurrent()) return;
      if (this.shouldRetry()) return;
      this.emit("error", err instanceof Error ? err : new Error(String(err)));
    });

    ws.on("close", () => {
      if (!isCurrent()) return;
      this.connected = false;
      this.ws = null;
      if (this.stopped) return;
      if (this.shouldRetry()) {
        this.scheduleRetry(generation);
        return;
      }
      this.emit("exit", 1);
    });
  }

  private shouldRetry(): boolean {
    return (
      !this.stopped &&
      !this.everConnected &&
      this.retryDurationMs > 0 &&
      Date.now() - this.firstAttemptAt < this.retryDurationMs
    );
  }

  private scheduleRetry(generation: number): void {
    if (
      this.stopped ||
      generation !== this.generation ||
      this.retryTimer !== null
    ) {
      return;
    }
    this.retryTimer = setTimeout(() => {
      if (this.stopped || generation !== this.generation) return;
      this.retryTimer = null;
      this.connect();
    }, 100);
  }
}

export class UnixSocketCodexTransport extends WebSocketCodexTransport {
  constructor(daemon: VerifiedCodexDaemon) {
    super(
      "ws://codex-app-server/rpc",
      0,
      {
        createConnection: () => createConnection(daemon.socketPath),
        perMessageDeflate: false,
      },
      () =>
        assertCodexDaemonSocketIdentity(
          daemon.socketPath,
          daemon.socketIdentity,
        ),
    );
  }
}

class ManagedCodexAppServer {
  private child: ChildProcessWithoutNullStreams | null = null;

  constructor(
    private readonly url: string,
    private readonly platform: NodeJS.Platform,
  ) {}

  ensureStarted(projectPath: string): void {
    if (this.child && !this.child.killed) return;

    const cwd = resolvePlatformPath(projectPath, this.platform);
    const child =
      this.platform === "win32"
        ? spawn(
            "cmd.exe",
            ["/d", "/s", "/c", `codex app-server --listen ${this.url}`],
            {
              cwd,
              stdio: "pipe",
              env: process.env,
              windowsVerbatimArguments: true,
            },
          )
        : spawn("codex", ["app-server", "--listen", this.url], {
            cwd,
            stdio: "pipe",
            env: process.env,
          });

    this.child = child;
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => {
      const line = chunk.trim();
      if (line) console.log(`[codex-app-server] ${line}`);
    });
    child.stderr.on("data", (chunk: string) => {
      const line = chunk.trim();
      if (line) console.log(`[codex-app-server] ${line}`);
    });
    child.on("error", (err) => {
      if (this.child === child) {
        this.child = null;
      }
      const message = err instanceof Error ? err.message : String(err);
      console.error(`[codex-app-server] Failed to start: ${message}`);
    });
    child.on("exit", () => {
      this.child = null;
    });
  }

  createTransport(projectPath: string): CodexTransport {
    this.ensureStarted(projectPath);
    return new WebSocketCodexTransport(this.url, 5000);
  }

  stop(): void {
    if (!this.child) return;
    this.child.kill("SIGTERM");
    this.child = null;
  }
}

const managedServers = new Map<string, ManagedCodexAppServer>();

export function createCodexTransport(
  projectPath: string,
  platform: NodeJS.Platform = process.platform,
  env: NodeJS.ProcessEnv = process.env,
  daemonVerifier: typeof verifyCodexDaemon = verifyCodexDaemon,
): CodexTransport {
  const mode = readCodexAppServerMode(env);
  if (mode === "daemon") {
    const config = readCodexDaemonConfig(env, platform);
    return new UnixSocketCodexTransport(daemonVerifier(config));
  }
  if (mode === "external") {
    return new WebSocketCodexTransport(readCodexAppServerUrl(mode, env));
  }
  if (mode === "managed") {
    const url = readCodexAppServerUrl(mode, env);
    let manager = managedServers.get(url);
    if (!manager) {
      manager = new ManagedCodexAppServer(url, platform);
      managedServers.set(url, manager);
    }
    return manager.createTransport(projectPath);
  }
  return new StdioCodexTransport(platform);
}

export function stopManagedCodexAppServers(): void {
  for (const manager of managedServers.values()) {
    manager.stop();
  }
  managedServers.clear();
}

function readCodexAppServerUrl(
  mode: CodexAppServerMode,
  env: NodeJS.ProcessEnv,
): string {
  const url = resolveCodexSharedAppServerUrl(mode, env);
  if (url) return url;

  if (mode === "external") {
    throw new Error(
      "BRIDGE_CODEX_SHARED_APP_SERVER_URL is required when BRIDGE_CODEX_APP_SERVER_MODE=external",
    );
  }
  throw new Error("codex app-server URL could not be resolved");
}
