import { createServer } from "node:http";
import { createInterface } from "node:readline";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";

const scenarios = JSON.parse(
  await readFile(
    fileURLToPath(
      new URL(
        "../../../test-fixtures/conversation-chain/scenarios.json",
        import.meta.url,
      ),
    ),
    "utf8",
  ),
);
const providerScenario = scenarios.headlessProvider;
const providerWindowSequence = scenarios.windowSequence;
if (
  !providerScenario?.thread?.id ||
  !Array.isArray(providerWindowSequence) ||
  !providerScenario?.canonical
) {
  throw new Error("headless provider scenario is missing or invalid");
}

const runId = `${new Date().toISOString().replaceAll(":", "-")}-${randomUUID().slice(0, 8)}`;
const traceRoot = resolve(
  process.env.CCPOCKET_CHAIN_TRACE_ROOT ??
    join("/private/tmp/ccpocket-chain", runId),
);
const isolatedHome = await mkdtemp(join(tmpdir(), "ccpocket-chain-provider-"));
await mkdir(traceRoot, { recursive: true });
process.env.HOME = isolatedHome;
process.env.CODEX_HOME = join(isolatedHome, "codex");
process.env.BRIDGE_CODEX_APP_SERVER_MODE = "private";
process.env.NODE_ENV = "test";

const [{ BridgeWebSocketServer }, { PromptHistoryStore }] = await Promise.all([
  import("../dist/websocket.js"),
  import("../dist/prompt-history-store.js"),
]);

const threadId = providerScenario.thread.id;
const providerState = {
  step: 0,
  generation: 1,
};
let catalogRevision = 0;
let notifyCatalogChanged = () => {};
const bridgeFrames = [];
const ackFrames = [];
const clientFrames = [];
const providerReads = [];

class FakeAppServerProcess {
  isRunning = true;

  async initializeOnly() {
    this.isRunning = true;
  }

  stop() {
    this.isRunning = false;
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
    const data = [providerThread()];
    return {
      data: options.archived === true ? [] : data,
      nextCursor: null,
    };
  }

  async listThreadTurns(options) {
    if (options.threadId !== threadId) return { data: [], nextCursor: null };
    const chronological = providerTurns();
    const ordered =
      options.sortDirection === "asc"
        ? chronological
        : [...chronological].reverse();
    return {
      data: ordered.slice(0, options.limit ?? ordered.length),
      nextCursor: null,
    };
  }

  async listThreadItems(options) {
    if (options.threadId !== threadId) return { data: [], nextCursor: null };
    const turn = providerTurns().find((candidate) => candidate.id === options.turnId);
    const items = (turn?.items ?? []).map((item) => ({
      turnId: turn?.id ?? options.turnId ?? "unknown-turn",
      item,
    }));
    return {
      data: items.slice(0, options.limit ?? items.length),
      nextCursor: null,
    };
  }
}

function providerThread() {
  const definition = providerScenario.thread;
  const updatedAt = definition.createdAt + providerState.step * 60;
  const latestStatus =
    providerState.step >= providerWindowSequence.length - 1
      ? "active"
      : "idle";
  return {
    ...definition,
    ephemeral: false,
    updatedAt,
    recencyAt: updatedAt,
    status: {
      type: latestStatus ?? "idle",
      ...(latestStatus === "active" ? { activeFlags: [] } : {}),
    },
    canAcceptDirectInput: true,
    agentNickname: null,
    agentRole: null,
  };
}

function providerTurns() {
  return structuredClone(providerScenario.previewTurns ?? []);
}

function canonicalTimeline() {
  const definition = providerScenario.canonical;
  const total = Number(definition.entryCount);
  if (!Number.isInteger(total) || total < 8) {
    throw new Error("canonical entry count is invalid");
  }
  const timestamp = (index) =>
    new Date(Date.parse(definition.startedAt) + index * 1_000).toISOString();
  const messages = [
    {
      type: "user_input",
      text: definition.userText,
      clientMessageId: "client-user-one",
      providerItemId: "provider-user-one",
      historyTurnId: "provider-turn-one",
      timestamp: timestamp(0),
    },
    {
      type: "assistant",
      messageUuid: "provider-assistant-one",
      historyTurnId: "provider-turn-one",
      timestamp: timestamp(1),
      message: {
        id: "provider-assistant-one",
        role: "assistant",
        model: "gpt-5.6-sol",
        content: [{ type: "text", text: definition.assistantText }],
      },
    },
    {
      type: "user_input",
      text: definition.userText,
      clientMessageId: "client-user-two",
      providerItemId: "provider-user-two",
      historyTurnId: "provider-turn-two",
      timestamp: timestamp(2),
    },
    {
      type: "assistant",
      messageUuid: "provider-assistant-two",
      historyTurnId: "provider-turn-two",
      timestamp: timestamp(3),
      message: {
        id: "provider-assistant-two",
        role: "assistant",
        model: "gpt-5.6-sol",
        content: [{ type: "text", text: definition.assistantText }],
      },
    },
    {
      type: "tool_result",
      toolUseId: "provider-tool-two",
      historyTurnId: "provider-turn-two",
      timestamp: timestamp(4),
      content: "chain",
      isError: false,
    },
  ];
  for (let index = messages.length; index < total; index += 1) {
    messages.push({
      type: "assistant",
      messageUuid: `provider-progress-${String(index).padStart(3, "0")}`,
      historyTurnId: "provider-turn-two",
      timestamp: timestamp(index),
      message: {
        id: `provider-progress-${String(index).padStart(3, "0")}`,
        role: "assistant",
        model: "gpt-5.6-sol",
        content: [
          { type: "text", text: `真实链路进度 ${String(index).padStart(3, "0")}` },
        ],
      },
    });
  }
  return messages;
}

const canonicalMessages = canonicalTimeline();

function providerHistoryWindow() {
  const definition = providerWindowSequence[providerState.step];
  if (!definition) throw new Error(`missing provider step ${providerState.step}`);
  const completeCount = definition.complete
    ? definition.count
    : providerWindowSequence
        .slice(0, providerState.step + 1)
        .reverse()
        .find((candidate) => candidate.complete)?.count;
  if (!Number.isInteger(completeCount) || !Number.isInteger(definition.count)) {
    throw new Error("provider window count is invalid");
  }
  const completeWindow = canonicalMessages.slice(0, completeCount);
  const messages = definition.complete
    ? completeWindow
    : completeWindow.slice(-definition.count);
  providerReads.push({
    step: providerState.step,
    requestedCount: definition.count,
    rawMessageCount: messages.length,
    windowComplete: definition.complete,
    stableIds: messages.map((message) =>
      message.providerItemId ?? message.messageUuid ?? message.toolUseId,
    ),
  });
  return {
    messages: structuredClone(messages),
    nextTurnCursor: null,
    windowComplete: definition.complete,
    latestTurnComplete: true,
  };
}

const httpServer = createServer();
const promptHistoryStore = new PromptHistoryStore(
  join(isolatedHome, "ccpocket", "prompt-history.json"),
);
await promptHistoryStore.init();
const bridge = new BridgeWebSocketServer({
  server: httpServer,
  authMode: "open",
  allowedDirs: [providerScenario.thread.cwd],
  promptHistoryStore,
  codexProcessFactory: () => new FakeAppServerProcess(),
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
    desktopToolTimelineReader: async () => ({
      events: [],
      callIds: new Set(),
    }),
    historyReader: async (target) => {
      if (target.providerSessionId !== threadId) {
        return {
          messages: [],
          nextTurnCursor: null,
          windowComplete: true,
          latestTurnComplete: true,
        };
      }
      return providerHistoryWindow();
    },
  },
});

const originalSend = bridge.send.bind(bridge);
bridge.send = (client, message) => {
  const raw = JSON.stringify(message);
  bridgeFrames.push(raw);
  originalSend(client, message);
};
bridge.wss.on("connection", (socket) => {
  socket.on("message", (data) => {
    const raw = data.toString();
    clientFrames.push(raw);
    try {
      const parsed = JSON.parse(raw);
      if (parsed.type === "conversation_sync_ack") ackFrames.push(raw);
    } catch {}
  });
});

await new Promise((resolveListen, rejectListen) => {
  httpServer.once("error", rejectListen);
  httpServer.listen(0, "127.0.0.1", resolveListen);
});
const address = httpServer.address();
if (!address || typeof address === "string") {
  throw new Error("headless Bridge harness did not bind a TCP port");
}
process.stdout.write(
  `READY ${JSON.stringify({
    url: `ws://127.0.0.1:${address.port}`,
    threadId,
    traceRoot,
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
  if (command.command === "advance") {
    const next = Number(command.step);
    if (
      !Number.isInteger(next) ||
      next < providerState.step ||
      next >= providerWindowSequence.length
    ) {
      process.stdout.write(
        `CONTROL ${JSON.stringify({ ok: false, error: "invalid_step" })}\n`,
      );
      continue;
    }
    providerState.step = next;
    notifyCatalogChanged();
    process.stdout.write(
      `CONTROL ${JSON.stringify({
        ok: true,
        step: providerState.step,
        generation: providerState.generation,
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
  join(traceRoot, "ack.jsonl"),
  ackFrames.length === 0 ? "" : `${ackFrames.join("\n")}\n`,
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
await writeFile(
  join(traceRoot, "summary.json"),
  `${JSON.stringify(
    {
      runId,
      threadId,
      finalStep: providerState.step,
      providerGeneration: providerState.generation,
      bridgeFrameCount: bridgeFrames.length,
      ackCount: ackFrames.length,
      clientFrameCount: clientFrames.length,
      providerReadCount: providerReads.length,
    },
    null,
    2,
  )}\n`,
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
await rm(isolatedHome, {
  recursive: true,
  force: true,
  maxRetries: 5,
  retryDelay: 100,
});
// Bridge feature timers are intentionally long-lived in production. This
// isolated child has already flushed every trace and closed its listeners, so
// terminate it explicitly instead of making the Dart receiver wait for those
// production timers to expire.
process.exit(0);
