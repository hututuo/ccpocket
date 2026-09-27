import { chmod, mkdir, mkdtemp, realpath, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { createHash } from "node:crypto";
import { tmpdir } from "node:os";
import { join } from "node:path";
import WebSocket, { WebSocketServer } from "ws";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { CodexProcess } from "./codex-process.js";
import { CodexActionBroker } from "./codex-action-broker.js";
import { CodexActionBrokerRuntime } from "./codex-action-broker-runtime.js";
import { CodexActionBrokerWriterLease } from "./codex-action-broker-writer-lease.js";
import { CodexSharedRuntimeControl } from "./codex-shared-runtime-control.js";
import { sharedRuntimePilotAttachmentCount } from "./codex-shared-runtime-pilot.js";
const SOURCE_ID = "codex-source-0123456789abcdef0123456789abcdef";
vi.setConfig({ testTimeout: 15000, hookTimeout: 10000 });
const waitFor = <T>(callback: () => T | Promise<T>, options: {
  timeout?: number;
  interval?: number;
} = {}) => vi.waitFor(callback, { timeout: 5000, interval: 20, ...options });
type Envelope = {
  id?: string | number;
  method?: string;
  params?: Record<string, any>;
  result?: any;
  error?: {
    code: number;
    message: string;
  };
};
// Only the provider is synthetic. Production daemon verification, Unix-socket
// WebSocket transport, JSON-RPC framing, process and attachment registry run
// unchanged. The fixture version executable has no daemon lifecycle commands.
async function createProvider() {
  const home = await realpath(await mkdtemp(join(tmpdir(), "ccp-wire-")));
  const socketPath = join(home, "rpc.sock");
  const cliPath = join(home, "codex");
  const http = createServer();
  const server = new WebSocketServer({ server: http });
  const peers: WebSocket[] = [];
  const trace: Array<{
    peer: number;
    direction: string;
    raw: string;
  }> = [];
  const clientTrace: Array<{
    client: number;
    direction: string;
    raw: string;
  }> = [];
  const checkpoints: string[] = [];
  const active = new Map<string, string>();
  let nextTurn = 0;
  const send = (peer: number, message: Envelope) => {
    const raw = JSON.stringify({ jsonrpc: "2.0", ...message });
    trace.push({ peer, direction: "provider_to_bridge", raw });
    peers[peer].send(raw);
  };
  const thread = (id: string) => ({
    id, cwd: home, model: "fixture-model", turns: [],
    status: active.has(id) ? { type: "active", activeFlags: [] } : { type: "idle" },
  });
  server.on("connection", (ws) => {
    const peer = peers.push(ws) - 1;
    ws.on("message", (data) => {
      const raw = data.toString();
      trace.push({ peer, direction: "bridge_to_provider", raw });
      const request = JSON.parse(raw) as Envelope;
      if (request.id === undefined || !request.method)
        return;
      const params = request.params ?? {};
      let result: unknown;
      switch (request.method) {
        case "initialize":
          result = { userAgent: "synthetic-shared-provider" };
          break;
        case "config/read":
          result = { config: { features: {} } };
          break;
        case "configRequirements/read":
          result = { requirements: {} };
          break;
        case "model/list":
          result = { data: [], nextCursor: null };
          break;
        case "thread/resume":
        case "thread/read":
          result = { thread: thread(params.threadId) };
          break;
        case "thread/turns/list":
          result = { data: active.has(params.threadId) ? [{ id: active.get(params.threadId), status: "inProgress" }] : [], nextCursor: null };
          break;
        case "turn/start": {
          const id = "fixture-turn-" + ++nextTurn;
          active.set(params.threadId, id);
          send(peer, { id: request.id, result: { turn: { id, status: "inProgress" } } });
          send(peer, { method: "turn/started", params: { threadId: params.threadId, turn: { id, status: "inProgress" } } });
          return;
        }
        case "thread/name/set":
        case "thread/archive":
        case "thread/unarchive":
        case "thread/delete":
        case "turn/steer":
        case "turn/interrupt":
          result = {};
          break;
        default:
          send(peer, { id: request.id, error: { code: -32601, message: "Unexpected fixture method: " + request.method } });
          return;
      }
      send(peer, { id: request.id, result });
    });
  });
  await new Promise<void>((resolve, reject) => {
    http.once("error", reject);
    http.listen(socketPath, resolve);
  });
  await chmod(socketPath, 0o600);
  const version = {
    status: "running", backend: "pid", cliVersion: "fixture-1",
    appServerVersion: "fixture-1", managedCodexVersion: "fixture-1",
    managedCodexPath: cliPath, socketPath,
  };
  await writeFile(cliPath, [
    "#!/usr/bin/env node",
    'if (process.argv.slice(2).join(" ") !== "app-server daemon version") process.exit(2);',
    "process.stdout.write(" + JSON.stringify(JSON.stringify(version)) + ");",
  ].join("\n") + "\n", { mode: 0o700 });
  for (const [key, value] of Object.entries({
    CODEX_HOME: home, BRIDGE_CODEX_APP_SERVER_MODE: "daemon",
    BRIDGE_CODEX_DAEMON_CLI: cliPath, BRIDGE_CODEX_DAEMON_SOCKET: socketPath,
    BRIDGE_CODEX_DAEMON_EXPECTED_VERSION: "fixture-1",
    BRIDGE_CODEX_DAEMON_EXPECTED_APP_SERVER_VERSION: "fixture-1",
    BRIDGE_CODEX_SOURCE_ID: SOURCE_ID, BRIDGE_CODEX_SHARED_PILOT: "1",
    BRIDGE_CODEX_SHARED_PILOT_ALLOW_THREAD_START: "1",
    BRIDGE_CODEX_SHARED_PILOT_ALLOW_TURN_START: "1",
  }))
    vi.stubEnv(key, value);
  return {
    home, peers, trace, send, active, clientTrace, checkpoints,
    requests: () => trace.filter((entry) => entry.direction === "bridge_to_provider").map((entry) => ({ peer: entry.peer, message: JSON.parse(entry.raw) as Envelope })),
    async close() {
      for (const peer of peers)
        peer.terminate();
      await new Promise<void>((resolve) => server.close(() => resolve()));
      await new Promise<void>((resolve) => http.close(() => resolve()));
      await rm(home, { recursive: true, force: true });
    },
  };
}
describe.skipIf(process.platform === "win32")("shared runtime ownership over real Unix sockets", () => {
  let fixture: Awaited<ReturnType<typeof createProvider>>;
  const processes: CodexProcess[] = [];
  const cleanup: Array<() => Promise<void>> = [];
  async function startBroker() {
    const control = new CodexSharedRuntimeControl({ projectPath: fixture.home, reconnectBaseDelayMs: 50, reconnectMaxDelayMs: 100 });
    const lease = new CodexActionBrokerWriterLease(SOURCE_ID, { rootDir: join(fixture.home, "leases") });
    const broker = new CodexActionBroker({ filePath: join(fixture.home, "broker.json") });
    const runtime = new CodexActionBrokerRuntime(broker, control, SOURCE_ID, lease);
    cleanup.push(async () => { await runtime.close(); control.stop(); });
    control.start();
    await control.waitUntilReady(3000);
    await runtime.start();
    return { control, lease, runtime, peer: fixture.peers.length - 1 };
  }
  function processWithGuard(guard?: () => boolean) {
    const proc = new CodexProcess(process.platform, guard);
    processes.push(proc);
    return proc;
  }
  async function attach(proc: CodexProcess, mode: "observer" | "adoption", threadId = "thread-a") {
    proc.start(fixture.home, { threadId, sharedRuntimeAttach: mode });
    await proc.waitUntilAttached(3000);
    if (mode === "adoption" && !fixture.active.has(threadId)) {
      await waitFor(() => expect(proc.isWaitingForInput).toBe(true));
    }
    return fixture.peers.length - 1;
  }
  beforeEach(async () => { fixture = await createProvider(); });
  afterEach(async (context) => {
    try {
      const traceDir = process.env.CCPOCKET_SHARED_WIRE_TRACE_DIR;
      if (traceDir && fixture) {
        await mkdir(traceDir, { recursive: true });
        const providerFrames = fixture.trace.map((entry) => ({ ...entry, sha256: createHash("sha256").update(entry.raw).digest("hex") }));
        const clientFrames = fixture.clientTrace.map((entry) => ({ ...entry, sha256: createHash("sha256").update(entry.raw).digest("hex") }));
        await writeFile(join(traceDir, context.task.name.replace(/[^a-zA-Z0-9-]/g, "_") + ".json"), JSON.stringify({ schema: 1, sourceSha: process.env.GITHUB_SHA ?? null, test: context.task.name, providerFrames, clientFrames, checkpoints: fixture.checkpoints }, null, 2));
      }
    } finally {
      const errors: unknown[] = [];
      for (const close of cleanup.splice(0).reverse()) {
        try {
          await close();
        } catch (error) {
          errors.push(error);
        }
      }
      for (const proc of processes.splice(0))
        proc.stop();
      try {
        await fixture?.close();
      } finally {
        vi.unstubAllEnvs();
      }
      if (errors.length)
        throw new AggregateError(errors, "Shared wire fixture cleanup failed");
    }
    expect(sharedRuntimePilotAttachmentCount()).toBe(0);
  });
  it("keeps observers read-only even when the source writer gates are open", async () => {
    const observer = processWithGuard(() => true);
    await attach(observer, "observer");
    const actions = [
      () => observer.renameThreadById("thread-a", "must not persist"),
      () => observer.archiveThread("thread-a"),
      () => observer.unarchiveThread("thread-a"),
      () => observer.deleteThread("thread-a"),
    ];
    for (const action of actions)
      await expect(action()).rejects.toThrow();
    await observer.readThread("thread-a");
    expect(fixture.requests().map(({ message }) => message.method).filter(Boolean)).toEqual([
      "initialize", "initialized", "thread/resume", "thread/read",
    ]);
    fixture.checkpoints.push("observer_mutations_blocked_before_provider_wire");
  });
  it("yields the observer before adopting and rejects a competing writer without a socket", async () => {
    const observer = processWithGuard();
    await attach(observer, "observer");
    const writer = processWithGuard();
    const writerPeer = await attach(writer, "adoption");
    expect(observer.isRunning).toBe(false);
    expect(sharedRuntimePilotAttachmentCount()).toBe(1);
    const competitor = processWithGuard();
    expect(() => competitor.start(fixture.home, { threadId: "thread-a", sharedRuntimeAttach: "adoption" })).toThrow("already exists");
    expect(fixture.peers).toHaveLength(2);
    await expect(attach(processWithGuard(), "observer", "thread-b")).resolves.toBe(2);
    writer.sendInput("synthetic ownership check");
    await waitFor(() => expect(writer.activeTurnIsBridgeOwned).toBe(true));
    expect(fixture.requests().filter(({ message }) => message.method === "turn/start").map(({ peer }) => peer)).toEqual([writerPeer]);
    const resumes = fixture.requests().filter(({ message }) => message.method === "thread/resume");
    for (const { message } of resumes)
      expect(message.params).toEqual({ threadId: message.params?.threadId, excludeTurns: true });
    fixture.checkpoints.push("observer_yield_competing_writer_blocked_independent_thread_readable");
  });
  it("revokes old turn ownership and pending approval after disconnect and reattachment", async () => {
    const writer = processWithGuard();
    const messages: any[] = [];
    writer.on("message", (message) => messages.push(message));
    const peer = await attach(writer, "adoption");
    const generation = writer.authorityGeneration;
    writer.sendInput("synthetic first turn");
    await waitFor(() => expect(writer.activeTurnIsBridgeOwned).toBe(true));
    const turnId = writer.activeTurnId!;
    const approval = { id: "old-approval", method: "item/commandExecution/requestApproval", params: { threadId: "thread-a", turnId, itemId: "old-tool", command: "synthetic-command" } };
    fixture.send(peer, approval);
    await waitFor(() => expect(messages.some((m) => m.type === "permission_request" && m.toolUseId === "old-tool")).toBe(true));
    fixture.peers[peer].terminate();
    await waitFor(() => expect(writer.isRunning).toBe(false));
    expect(writer.activeTurnIsBridgeOwned).toBe(false);
    const replacement = await attach(writer, "adoption");
    expect(writer.authorityGeneration).not.toBe(generation);
    expect(writer.activeTurnId).toBe(turnId);
    expect(writer.activeTurnIsBridgeOwned).toBe(false);
    const messageCount = messages.length;
    // Replay the same provider bytes on the replacement transport. Seeing an
    // old turn again does not prove this attachment ever started that turn.
    fixture.send(replacement, approval);
    await writer.readThread("thread-a");
    writer.approve("old-tool");
    await expect(writer.interruptCurrentTurn()).rejects.toThrow();
    await writer.readThread("thread-a");
    expect(messages.slice(messageCount).filter((m) => m.type === "permission_request")).toEqual([]);
    expect(fixture.requests().filter(({ message }) => message.id === "old-approval" && !message.method)).toEqual([]);
    expect(fixture.requests().filter(({ message }) => message.method === "turn/interrupt")).toEqual([]);
    fixture.checkpoints.push("reattachment_cannot_approve_or_interrupt_old_turn");
  });
  it("holds one real file lease across competing controls and transfers it only after release", async () => {
    const first = await startBroker();
    const standby = await startBroker();
    expect(first.runtime.health.ready).toBe(true);
    expect(standby.runtime.health).toMatchObject({ ready: false, writerLeaseHeld: false, degradedReason: "writer_lease_unavailable" });
    const reader = processWithGuard(() => standby.runtime.health.ready);
    await attach(reader, "observer");
    await expect(reader.readThread("thread-a")).resolves.toMatchObject({ id: "thread-a" });
    await expect(reader.renameThreadById("thread-a", "blocked")).rejects.toThrow();
    const oldGeneration = first.runtime.health.authorityGeneration;
    await first.runtime.close();
    await waitFor(() => expect(standby.runtime.health.ready).toBe(true), { timeout: 3000 });
    expect(first.lease.health.held).toBe(false);
    expect(standby.runtime.health.authorityGeneration).not.toBe(oldGeneration);
    expect(await first.lease.assertHeld(first.control.daemonIdentity)).toBe(false);
    await expect(reader.readThread("thread-a")).resolves.toMatchObject({ id: "thread-a" });
    fixture.checkpoints.push("single_file_lease_handoff_with_read_continuity");
  });
  it("accepts one of two authenticated clients and fences old control generations on the wire", async () => {
    // Import Bridge only after redirecting its default stores into the fixture.
    // No real conversation, user configuration or production service is read.
    vi.stubEnv("HOME", fixture.home);
    const { BridgeWebSocketServer } = await import("./websocket.js");
    const { PromptHistoryStore } = await import("./prompt-history-store.js");
    const { runtime, control, peer } = await startBroker();
    const http = createServer();
    const store = new PromptHistoryStore(join(fixture.home, "prompts.json"));
    await store.init();
    const bridge = new BridgeWebSocketServer({
      server: http, authMode: "key", apiKey: "synthetic-test-key",
      allowedDirs: [fixture.home], promptHistoryStore: store,
      sharedRuntimeControl: control, codexActionBrokerRuntime: runtime,
      sessionCatalogMonitorFactory: () => ({ isActive: false, async start() { }, close() { } }),
    });
    const clients: Array<{
      socket: WebSocket;
      messages: any[];
    }> = [];
    cleanup.push(async () => {
      for (const client of clients)
        client.socket.terminate();
      await bridge.close();
      await new Promise<void>((resolve) => http.close(() => resolve()));
    });
    await new Promise<void>((resolve) => http.listen(0, "127.0.0.1", resolve));
    const port = (http.address() as import("node:net").AddressInfo).port;
    function sendClient(client: {
      socket: WebSocket;
      clientId: number;
    }, message: unknown) {
      const raw = JSON.stringify(message);
      fixture.clientTrace.push({ client: client.clientId, direction: "client_to_bridge", raw });
      client.socket.send(raw);
    }
    async function connect() {
      const socket = new WebSocket("ws://127.0.0.1:" + port + "/?token=synthetic-test-key");
      const messages: any[] = [];
      clients.push({ socket, messages });
      const clientId = clients.length;
      socket.on("message", (data) => {
        const raw = data.toString();
        fixture.clientTrace.push({ client: clientId, direction: "bridge_to_client", raw });
        messages.push(JSON.parse(raw));
      });
      await new Promise<void>((resolve, reject) => { socket.once("open", resolve); socket.once("error", reject); });
      sendClient({ socket, clientId }, { type: "client_capabilities", supportedServerMessages: ["codex_action_broker_v1"] });
      sendClient({ socket, clientId }, { type: "get_codex_actions", requestId: "initial", codexSourceId: SOURCE_ID, threadId: "thread-a" });
      await waitFor(() => expect(messages.some((m) => m.event === "snapshot" && m.requestId === "initial")).toBe(true));
      return { socket, messages, clientId };
    }
    const a = await connect();
    const b = await connect();
    function request(id: string) {
      return { id, method: "item/commandExecution/requestApproval", params: { threadId: "thread-a", turnId: "turn-a", itemId: "tool-" + id, command: "synthetic-only", availableDecisions: ["accept", "decline"] } };
    }
    async function projected(client: typeof a, excludedRequestId: string, generation?: string) {
      let result: any;
      await waitFor(() => {
        result = client.messages.filter((m) => m.event === "request" && m.request.live && m.request.input?.command === "synthetic-only" && m.request.opaqueRequestId !== excludedRequestId && (!generation || m.request.authorityGeneration === generation)).at(-1)?.request;
        expect(result).toBeDefined();
      });
      return result;
    }
    function respond(client: typeof a, target: any, id: string, overrides = {}) {
      const { opaqueRequestId, codexSourceId, threadId, turnId, authorityGeneration } = target;
      sendClient(client, { type: "respond_codex_action", requestId: id, opaqueRequestId, codexSourceId, threadId, turnId, authorityGeneration, claimantId: id, operationId: id, action: "approve", ...overrides });
    }
    async function outcome(client: typeof a, id: string) {
      await waitFor(() => expect(client.messages.some((m) => m.event === "response" && m.requestId === id)).toBe(true));
      return client.messages.find((m) => m.event === "response" && m.requestId === id).outcome;
    }
    fixture.send(peer, request("race"));
    await waitFor(() => expect(runtime.listRequests()).toHaveLength(1));
    const target = await projected(a, "");
    await waitFor(() => expect(b.messages.some((m) => m.event === "request" && m.request.opaqueRequestId === target.opaqueRequestId)).toBe(true));
    for (const [key, value] of Object.entries({ codexSourceId: "other-source", threadId: "other-thread", turnId: "other-turn", authorityGeneration: "cab:0:0" })) {
      respond(a, target, key, { [key]: value });
      expect(["invalid", "staleGeneration"]).toContain(await outcome(a, key));
    }
    expect(fixture.requests().filter(({ message }) => !message.method)).toHaveLength(0);
    fixture.checkpoints.push("source_thread_turn_generation_mismatch_rejected");
    respond(a, target, "client-a");
    respond(b, target, "client-b");
    const outcomes = await Promise.all([outcome(a, "client-a"), outcome(b, "client-b")]);
    expect(outcomes.filter((value) => value === "submitted")).toHaveLength(1);
    expect(outcomes.every((value) => ["submitted", "contended", "alreadyResolved"].includes(value))).toBe(true);
    await waitFor(() => expect(fixture.requests().filter(({ message }) => message.id === "race" && !message.method)).toHaveLength(1));
    fixture.checkpoints.push("two_authenticated_clients_one_provider_response");
    fixture.send(peer, request("reconnect"));
    const old = await projected(a, target.opaqueRequestId);
    const oldGeneration = control.connectionGeneration;
    fixture.peers[peer].terminate();
    await waitFor(() => expect(control.connectionGeneration).toBeGreaterThan(oldGeneration), { timeout: 3000 });
    await waitFor(() => expect(runtime.health.ready).toBe(true));
    const replacement = fixture.peers.length - 1;
    expect(runtime.health.authorityGeneration).not.toBe(old.authorityGeneration);
    expect(control.respondToServerRequest({ requestId: "reconnect", connectionGeneration: oldGeneration }, { decision: "accept" })).toBe(false);
    respond(a, old, "old-client");
    expect(["staleGeneration", "unavailable", "expired"]).toContain(await outcome(a, "old-client"));
    expect(fixture.requests().filter(({ message }) => message.id === "reconnect" && !message.method)).toHaveLength(0);
    fixture.checkpoints.push("old_control_generation_and_client_response_rejected");
    const original = fixture.trace.find((entry) => entry.direction === "provider_to_bridge" && JSON.parse(entry.raw).id === "reconnect")!;
    fixture.trace.push({ peer: replacement, direction: "provider_to_bridge", raw: original.raw });
    fixture.peers[replacement].send(original.raw);
    const fresh = await projected(b, old.opaqueRequestId, runtime.health.authorityGeneration);
    expect(fresh.opaqueRequestId).not.toBe(old.opaqueRequestId);
    respond(b, fresh, "fresh-client");
    expect(await outcome(b, "fresh-client")).toBe("submitted");
    await waitFor(() => expect(fixture.requests().filter(({ message }) => message.id === "reconnect" && !message.method).map(({ peer }) => peer)).toEqual([replacement]));
    fixture.checkpoints.push("reissued_same_provider_bytes_require_new_authority");
  }, 15000);
});
