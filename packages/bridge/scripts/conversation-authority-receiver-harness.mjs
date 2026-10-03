import assert from "node:assert/strict";
import { createServer } from "node:http";
import { createInterface } from "node:readline";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { randomUUID } from "node:crypto";
import { setTimeout as delay } from "node:timers/promises";
import { startConversationAppServerFixture } from "./conversation-app-server-fixture.mjs";

// An owned child loads actual TS with the installed tsx loader. Only Provider
// facts/catalog inputs are synthetic; authority and all receiver paths are real.
const home = await mkdtemp(join(tmpdir(), "ccpocket-authority-receiver-"));
process.env.HOME = home;
process.env.CODEX_HOME = join(home, "codex");
process.env.BRIDGE_CODEX_APP_SERVER_MODE = "private";
process.env.NODE_ENV = "test";
const projectPath = process.cwd();
const threadId = "019f-authority-receiver-thread";
const turnId = "turn-authority-receiver";
const traceRoot = resolve(
  process.env.CCPOCKET_CHAIN_TRACE_PARENT ?? join(tmpdir(), "ccpocket-chain"),
  `${new Date().toISOString().replaceAll(":", "-")}-${randomUUID().slice(0, 8)}-authority-receiver`,
);
const rpcTrace = [], providerReads = [], frames = [], clientFrames = [], origins = [], controls = [];
const state = { revision: 1, active: false, completed: false, assistantItems: [] };
const userItem = { type: "userMessage", id: "provider-user-authority-receiver",
  clientMessageId: "client-user-live-segments",
  content: [{ type: "text", text: "Exercise received old authority replacement" }] };
const thread = () => ({ id: threadId, name: "Authority receiver fixture", cwd: projectPath,
  createdAt: 1_786_464_000, updatedAt: 1_786_464_000 + state.revision,
  ephemeral: false, canAcceptDirectInput: true,
  status: state.active ? { type: "active", activeFlags: [] } : { type: "idle" } });
const turn = () => ({ id: turnId, status: state.active ? "inProgress" : "completed",
  items: [userItem, ...state.assistantItems] });
let bridge, fixture, history, server, input, activeRuntime, changed;
let stopping = false;
let cleaning = false;
async function waitFor(ready, label) {
  const end = Date.now() + 8000;
  while (!ready()) { assert.ok(Date.now() < end, `Timed out: ${label}`); await delay(5); }
}
function currentState() {
  const snapshot = bridge.localFeatures.listRuntimeConversationStates()
    .find((row) => row.provider === "codex" && row.providerSessionId === threadId);
  assert.ok(snapshot, "Actual SessionManager runtime must exist");
  assert.equal(bridge.sessionManager.get(snapshot.bridgeSessionId).process, activeRuntime);
  return snapshot;
}
async function shutdown() {
  if (cleaning) return;
  cleaning = true;
  input?.close();
  fixture?.beginShutdown();
  await mkdir(traceRoot, { recursive: true });
  for (const [name, rows] of [
    ["app-server-wire.jsonl", rpcTrace], ["provider-read.jsonl", providerReads],
    ["bridge-frame.jsonl", frames], ["client-frame.jsonl", clientFrames],
    ["runtime-overlay-origin.jsonl", origins], ["replacement-control.jsonl", controls],
  ]) await writeFile(join(traceRoot, name), rows.map((row) => JSON.stringify(row)).join("\n") + "\n");
  if (bridge) await Promise.race([bridge.close(), delay(3000)]);
  history?.stop();
  await fixture?.close();
  if (server?.listening) {
    server.closeAllConnections?.();
    await new Promise((accept) => server.close(accept));
  }
  await rm(home, { recursive: true, force: true });
}
// If the parent has to retire its captured child, close owned Provider sockets
// as well, so their byte-pipe grandchildren exit on socket close.
process.once("SIGTERM", () => { stopping = true; input?.close(); history?.stop(); });
try {
  const [{ BridgeWebSocketServer }, { CodexProcess }, { PromptHistoryStore },
    { codexThreadToServerMessages }] = await Promise.all([
    import("../src/websocket.ts"), import("../src/codex-process.ts"),
    import("../src/prompt-history-store.ts"), import("../src/local-features/codex-thread-history.ts"),
  ]);
  fixture = await startConversationAppServerFixture({
    home, projectPath, threadId, turnId, state, thread, turn, trace: rpcTrace, reads: providerReads,
  });
  assert.ok(!stopping, "Parent retired fixture during startup");
  history = new CodexProcess();
  await history.initializeOnly(projectPath, 8000);
  assert.ok(!stopping, "Parent retired fixture during startup");
  const prompts = new PromptHistoryStore(join(home, "prompt-history.json"));
  await prompts.init();
  assert.ok(!stopping, "Parent retired fixture during startup");
  server = createServer();
  const catalogTime = "2026-08-11T16:00:00.000Z";
  bridge = new BridgeWebSocketServer({ server, authMode: "open", allowedDirs: [projectPath],
    promptHistoryStore: prompts, deltaBatchMs: 0,
    codexProcessFactory: () => {
      const runtime = new CodexProcess();
      runtime.on("message", (message) => {
        if (message.type === "system" && message.subtype === "init") activeRuntime = runtime;
        if (message.type === "assistant") origins.push({
          assistantId: message.message.id, processActiveTurnId: runtime.activeTurnId,
          runtimeStates: bridge.localFeatures.listRuntimeConversationStates(),
        });
      });
      return runtime;
    },
    sessionCatalogMonitorFactory: (onChanged) => {
      let revision = 0;
      changed = () => onChanged(++revision, { revision, provider: "codex", providerSessionId: threadId });
      return { isActive: true, currentRevision: 0, async start() {}, close() {} };
    },
    conversationSyncV2Options: {
      daemonMode: false, statusWatchdogMs: 60_000, coldReconcileMs: 60_000,
      focusedContentReconcileMs: 60_000, initialExternalCodexMonitors: 0, maxExternalCodexMonitors: 0,
      catalogReader: async () => [{ entry: { provider: "codex", providerSessionId: threadId,
        revision: `fixture-${state.revision}`, projectPath, firstPrompt: "Received authority replacement",
        createdAt: catalogTime, modifiedAt: catalogTime, recencyAt: catalogTime, availability: "durable" },
        status: { provider: "codex", providerSessionId: threadId, activity: "unknown", attention: "none",
          result: "none", runtimeAttachment: "notLoaded", source: "legacyRollout", confidence: "unknown",
          observedAt: catalogTime } }],
      statusReader: async () => new Map(), focusedCodexMetadataReader: async () => undefined,
      inspectCodexThread: async () => null,
      desktopToolTimelineReader: async () => ({ events: [], callIds: new Set() }),
      historyReader: async (target) => target.providerSessionId === threadId
        ? codexThreadToServerMessages({ turns: (await history.listThreadTurns({ threadId, itemsView: "full" })).data })
        : [],
    },
  });
  bridge.wss.on("connection", (socket) => {
    const send = socket.send.bind(socket);
    socket.send = (data, ...args) => {
      const result = send(data, ...args);
      frames.push(JSON.parse(data.toString()));
      return result;
    };
    socket.on("message", (data) => clientFrames.push(JSON.parse(data.toString())));
  });
  await new Promise((accept, reject) => { server.once("error", reject); server.listen(0, "127.0.0.1", accept); });
  assert.ok(!stopping, "Parent retired fixture during startup");
  process.stdout.write(`READY ${JSON.stringify({ url: `ws://127.0.0.1:${server.address().port}`,
    threadId, turnId, projectPath, traceRoot, providerMode: "stdio-json-rpc" })}\n`);
  input = createInterface({ input: process.stdin, crlfDelay: Infinity });
  for await (const line of input) {
    const command = JSON.parse(line);
    if (command.command === "shutdown") break;
    try {
      let result;
      if (command.command === "emit_segment") {
        assert.ok(activeRuntime, "Runtime must be initialized through real public start");
        await fixture.beginTurn(activeRuntime);
        if (activeRuntime.activeTurnId !== turnId) {
          state.active = true;
          fixture.notify("turn/started", { threadId, turn: { id: turnId, status: "inProgress" } });
          await waitFor(() => activeRuntime.activeTurnId === turnId, "actual replacement turn/started");
        }
        assert.ok(typeof command.id === "string" && command.id && typeof command.text === "string" && command.text);
        fixture.notify("item/started", { threadId, turnId, item: { id: command.id, type: "agentMessage" } });
        fixture.notify("item/agentMessage/delta", { threadId, turnId, itemId: command.id, delta: command.text });
        fixture.notify("item/completed", { threadId, turnId, item: { id: command.id, type: "agentMessage", text: command.text } });
        state.assistantItems.push({ id: command.id, type: "agentMessage", text: command.text });
        state.revision++;
        changed();
        result = { id: command.id, revision: state.revision };
      } else if (command.command === "replace_runtime") {
        const before = currentState();
        const oldRuntime = activeRuntime;
        const id = await bridge.sessionManager.replaceCodexSession(
          before.bridgeSessionId, projectPath, [], undefined, { threadId }, 8000,
        );
        const after = currentState();
        assert.equal(id, before.bridgeSessionId);
        assert.notEqual(activeRuntime, oldRuntime);
        assert.notEqual(after.authorityGeneration, before.authorityGeneration);
        // No turn/started or new item is sent to B in this command.
        result = { runtimeId: id, oldAuthority: before.authorityGeneration,
          newAuthority: after.authorityGeneration, before, after };
      } else throw new Error("unknown_control");
      const response = { ok: true, requestId: command.requestId, command: command.command, ...result };
      controls.push(response);
      process.stdout.write(`CONTROL ${JSON.stringify(response)}\n`);
    } catch (error) {
      const response = { ok: false, requestId: command.requestId, error: String(error) };
      controls.push(response);
      process.stdout.write(`CONTROL ${JSON.stringify(response)}\n`);
    }
  }
} finally { await shutdown(); }
// Original Bridge watchdogs are long-lived; all owned sockets and evidence have
// been closed/flushed before terminating this successful control child.
process.exit(0);
