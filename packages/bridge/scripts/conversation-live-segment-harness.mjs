import { createServer } from "node:http";
import { createInterface } from "node:readline";
import { mkdir, mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { randomUUID } from "node:crypto";

const runId = `${new Date().toISOString().replaceAll(":", "-")}-${randomUUID().slice(0, 8)}`;
const traceRoot = resolve(
  process.env.CCPOCKET_CHAIN_TRACE_ROOT ??
    join("/private/tmp/ccpocket-chain", `${runId}-live-segments`),
);
const isolatedHome = await mkdtemp(join(tmpdir(), "ccpocket-segment-provider-"));
// Exercise the real project-scoped Bridge paths against an actual Git worktree.
// A synthetic empty directory makes unrelated git metadata probes noisy and can
// hide the receiver assertions behind fixture-only stderr.
const projectPath = process.cwd();
await mkdir(traceRoot, { recursive: true });
process.env.HOME = isolatedHome;
process.env.CODEX_HOME = join(isolatedHome, "codex");
process.env.BRIDGE_CODEX_APP_SERVER_MODE = "private";
process.env.NODE_ENV = "test";

const [
  { BridgeWebSocketServer },
  { PromptHistoryStore },
  { CodexProcess },
  { codexThreadToServerMessages },
] = await Promise.all([
  import("../dist/websocket.js"),
  import("../dist/prompt-history-store.js"),
  import("../dist/codex-process.js"),
  import("../dist/local-features/codex-thread-history.js"),
]);

const threadId = "019f-live-segment-authority-thread";
const turnId = "turn-live-segments";
const latestTurnGapScenario =
  process.env.CCPOCKET_CHAIN_SCENARIO === "latest-turn-gap";
const userItem = {
  type: "userMessage",
  id: "provider-user-live-segments",
  clientMessageId: "client-user-live-segments",
  content: [{ type: "text", text: "Exercise live segment boundaries" }],
};
const providerState = {
  revision: latestTurnGapScenario ? 4 : 1,
  active: false,
  completed: latestTurnGapScenario,
  assistantItems: latestTurnGapScenario
    ? [
        {
          type: "agentMessage",
          id: "provider-commentary-before-oversized-tool",
          text: "Commentary before oversized tool",
        },
        {
          type: "commandExecution",
          id: "provider-oversized-tool",
          command: "generate-large-output",
          status: "completed",
          aggregatedOutput: "x".repeat(100 * 1024),
        },
        {
          type: "reasoning",
          id: "provider-reasoning-after-oversized-tool",
          summary: ["Reasoning after oversized tool"],
        },
        {
          type: "agentMessage",
          id: "provider-commentary-after-oversized-tool",
          text: "Commentary after oversized tool",
        },
        {
          type: "agentMessage",
          id: "provider-final-after-oversized-tool",
          text: "Final answer after oversized tool",
        },
      ]
    : [],
};
const providerReads = [];
const bridgeFrames = [];
const clientFrames = [];
let activeRuntime = null;
let notifyCatalogChanged = () => {};
let catalogRevision = 0;

function providerTurn() {
  return {
    id: turnId,
    status: providerState.completed
      ? "completed"
      : providerState.active
        ? "inProgress"
        : "completed",
    startedAt: 1_786_464_000,
    ...(providerState.completed ? { completedAt: 1_786_464_060 } : {}),
    items: [userItem, ...providerState.assistantItems],
  };
}

function providerThread() {
  const updatedAt = 1_786_464_000 + providerState.revision;
  return {
    id: threadId,
    name: "Live segment authority fixture",
    cwd: projectPath,
    createdAt: 1_786_464_000,
    updatedAt,
    recencyAt: updatedAt,
    ephemeral: false,
    status: providerState.active
      ? { type: "active", activeFlags: [] }
      : { type: "idle" },
    canAcceptDirectInput: true,
    agentNickname: null,
    agentRole: null,
  };
}

class FakeCodexAppServer extends CodexProcess {
  _fixtureRunning = true;

  get isRunning() {
    return this._fixtureRunning;
  }

  get isAttachmentReady() {
    return true;
  }

  get isWaitingForInput() {
    return !providerState.active;
  }

  async initializeOnly() {
    this._fixtureRunning = true;
  }

  start(cwd, options = {}) {
    this._fixtureRunning = true;
    this._threadId = options.threadId ?? threadId;
    activeRuntime = this;
    queueMicrotask(() => {
      this.emit("message", {
        type: "system",
        subtype: "init",
        sessionId: this._threadId,
        provider: "codex",
        projectPath: cwd,
        model: "gpt-5.6-sol",
        modelReasoningEffort: "max",
        serviceTier: "standard",
      });
      this.setStatus("idle");
      this.emit("input_ready");
    });
  }

  stop() {
    this._fixtureRunning = false;
  }

  sendInput(text, clientMessageId) {
    // Bridge acceptance is intentionally emitted before this call. Keep the
    // provider transcript one revision behind so the receiver must preserve
    // the accepted user envelope while SQLite catches up.
    providerReads.push({
      method: "turn/start-deferred",
      text,
      clientMessageId,
      revision: providerState.revision,
    });
  }

  async readProfileConfig() {
    return { profiles: [], defaultProfile: undefined };
  }

  async listAvailableModelMetadata() {
    return [
      {
        model: "gpt-5.6-sol",
        supportedReasoningEfforts: ["high", "max", "ultra"],
        supportedServiceTiers: ["standard"],
      },
    ];
  }

  async readConfigRequirements() {
    return { autoReviewDisabled: false };
  }

  async listThreads(options = {}) {
    return {
      data: options.archived === true ? [] : [providerThread()],
      nextCursor: null,
    };
  }

  async listThreadTurns(options) {
    if (options.threadId !== threadId) return { data: [], nextCursor: null };
    providerReads.push({
      method: "thread/turns/list",
      revision: providerState.revision,
      itemIds: providerTurn().items.map((item) => item.id),
    });
    return { data: [structuredClone(providerTurn())], nextCursor: null };
  }

  async listThreadItems(options) {
    throw new Error("thread/items/list is not supported yet");
  }

  injectAssistantItem(id, text, { completeTurn = false } = {}) {
    if (!providerState.active) {
      providerState.active = true;
      this.handleNotification("turn/started", {
        threadId,
        turn: { id: turnId, status: "inProgress" },
      });
    }
    const startedAt = 1_786_464_000 + providerState.revision * 2;
    this.handleNotification("item/started", {
      threadId,
      turnId,
      item: { id, type: "agentMessage", createdAt: startedAt },
    });
    this.handleNotification("item/agentMessage/delta", {
      threadId,
      turnId,
      itemId: id,
      delta: text,
    });
    this.handleNotification("item/completed", {
      threadId,
      turnId,
      item: {
        id,
        type: "agentMessage",
        text,
        createdAt: startedAt,
        completedAt: startedAt + 1,
      },
    });
    providerState.assistantItems.push({
      type: "agentMessage",
      id,
      text,
      __ccPocketEventStartedAt: new Date(startedAt * 1_000).toISOString(),
      __ccPocketEventCompletedAt: new Date((startedAt + 1) * 1_000).toISOString(),
    });
    providerState.revision += 1;
    if (completeTurn) {
      providerState.active = false;
      providerState.completed = true;
      this.handleNotification("turn/completed", {
        threadId,
        turn: { id: turnId, status: "completed" },
      });
      // The real CodexProcess run loop publishes input_ready after consuming
      // turn/completed. This fake provider bypasses that loop, so mirror the
      // same public lifecycle boundary explicitly.
      this.setStatus("idle");
      this.emit("input_ready");
    }
    notifyCatalogChanged();
  }
}

const httpServer = createServer();
const promptHistoryStore = new PromptHistoryStore(
  join(isolatedHome, "ccpocket", "prompt-history.json"),
);
await promptHistoryStore.init();
const bridge = new BridgeWebSocketServer({
  server: httpServer,
  authMode: "open",
  allowedDirs: [projectPath],
  promptHistoryStore,
  deltaBatchMs: 0,
  codexProcessFactory: () => new FakeCodexAppServer(),
  sessionCatalogMonitorFactory: (onChanged) => {
    notifyCatalogChanged = () => {
      catalogRevision += 1;
      onChanged(catalogRevision);
    };
    return {
      isActive: true,
      currentRevision: catalogRevision,
      async start() {},
      close() {},
    };
  },
  conversationSyncV2Options: {
    daemonMode: false,
    statusWatchdogMs: 60_000,
    coldReconcileMs: 60_000,
    initialExternalCodexMonitors: 0,
    maxExternalCodexMonitors: 0,
    focusedCodexMetadataReader: async () => undefined,
    inspectCodexThread: async () => null,
    desktopToolTimelineReader: async () => ({ events: [], callIds: new Set() }),
    historyReader: async (target) => {
      if (target.providerSessionId !== threadId) {
        return {
          messages: [],
          nextTurnCursor: null,
          windowComplete: true,
          latestTurnComplete: true,
        };
      }
      const messages = codexThreadToServerMessages({ turns: [providerTurn()] });
      providerReads.push({
        method: "conversation-history",
        revision: providerState.revision,
        itemIds: providerTurn().items.map((item) => item.id),
        messageIds: messages.map((message) =>
          message.type === "assistant"
            ? message.message.id
            : message.type === "user_input"
              ? message.providerItemId
              : undefined,
        ),
      });
      return {
        messages,
        nextTurnCursor: null,
        windowComplete: true,
        latestTurnComplete: !providerState.active,
      };
    },
  },
});

const originalSend = bridge.send.bind(bridge);
bridge.send = (client, message) => {
  bridgeFrames.push(JSON.stringify(message));
  originalSend(client, message);
};
bridge.wss.on("connection", (socket) => {
  socket.on("message", (data) => clientFrames.push(data.toString()));
});

await new Promise((resolveListen, rejectListen) => {
  httpServer.once("error", rejectListen);
  httpServer.listen(0, "127.0.0.1", resolveListen);
});
const address = httpServer.address();
if (!address || typeof address === "string") {
  throw new Error("live segment harness did not bind a TCP port");
}
process.stdout.write(
  `READY ${JSON.stringify({
    url: `ws://127.0.0.1:${address.port}`,
    threadId,
    turnId,
    projectPath,
    traceRoot,
    scenario: latestTurnGapScenario ? "latest-turn-gap" : "live-segments",
  })}\n`,
);

const input = createInterface({ input: process.stdin, crlfDelay: Infinity });
for await (const line of input) {
  let command;
  try {
    command = JSON.parse(line);
  } catch {
    continue;
  }
  if (command.command === "emit_segment") {
    if (!activeRuntime) {
      process.stdout.write(
        `CONTROL ${JSON.stringify({ ok: false, error: "runtime_not_started" })}\n`,
      );
      continue;
    }
    const id = String(command.id ?? "").trim();
    const text = String(command.text ?? "");
    if (!id || !text) {
      process.stdout.write(
        `CONTROL ${JSON.stringify({ ok: false, error: "invalid_segment" })}\n`,
      );
      continue;
    }
    activeRuntime.injectAssistantItem(id, text, {
      completeTurn: command.completeTurn === true,
    });
    process.stdout.write(
      `CONTROL ${JSON.stringify({
        ok: true,
        id,
        revision: providerState.revision,
        completeTurn: command.completeTurn === true,
      })}\n`,
    );
    continue;
  }
  if (command.command === "shutdown") break;
}

await writeFile(
  join(traceRoot, "bridge-frame.jsonl"),
  bridgeFrames.length === 0 ? "" : `${bridgeFrames.join("\n")}\n`,
);
await writeFile(
  join(traceRoot, "client-frame.jsonl"),
  clientFrames.length === 0 ? "" : `${clientFrames.join("\n")}\n`,
);
await writeFile(
  join(traceRoot, "provider-read.jsonl"),
  providerReads.length === 0
    ? ""
    : `${providerReads.map((entry) => JSON.stringify(entry)).join("\n")}\n`,
);
await Promise.race([
  bridge.close(),
  new Promise((resolveClose) => setTimeout(resolveClose, 3_000)),
]);
httpServer.closeAllConnections?.();
await Promise.race([
  new Promise((resolveClose) => httpServer.close(() => resolveClose())),
  new Promise((resolveClose) => setTimeout(resolveClose, 3_000)),
]);
// Bridge owns long-lived watchdog timers by design. The harness has flushed all
// trace files and closed its sockets at this point, so terminate explicitly
// instead of making the Flutter test kill an otherwise successful fixture.
process.exit(0);
