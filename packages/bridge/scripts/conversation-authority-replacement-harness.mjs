import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { createServer } from "node:http";
import { mkdir, writeFile } from "node:fs/promises";
import { once } from "node:events";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import WebSocket from "ws";

import { BridgeWebSocketServer } from "../src/websocket.ts";
import { CodexProcess } from "../src/codex-process.ts";
import { PromptHistoryStore } from "../src/prompt-history-store.ts";
import { codexThreadToServerMessages } from "../src/local-features/codex-thread-history.ts";
import { startConversationAppServerFixture } from "./conversation-app-server-fixture.mjs";

// Run in an owned child via the already installed tsx loader. Neither Bridge
// source nor a generated dist build is swapped to install the test gate.
const fixtureHome = process.env.CCPOCKET_REPLACEMENT_HOME;
assert.ok(fixtureHome, "The caller must provide an isolated child home");
const capacityGate = process.env.CCPOCKET_REPLACEMENT_GATE ?? "catalog";
assert.ok(["catalog", "overlay"].includes(capacityGate));
const projectPath = process.cwd();
const threadId = "019f-authority-replacement-thread";
const turnId = "turn-authority-replacement";
const subscriptionId = `authority-replacement-${randomUUID()}`;
const traceRoot = resolve(
  process.env.CCPOCKET_CHAIN_TRACE_PARENT ?? join(tmpdir(), "ccpocket-chain"),
  `${new Date().toISOString().replaceAll(":", "-")}-${randomUUID().slice(0, 8)}-authority-replacement`,
);
await mkdir(traceRoot, { recursive: true });
const rpcTrace = [];
const providerReads = [];
const frames = [];
const stages = [];
const origins = [];
const clientFrames = [];
const capacityTrace = [];
const capacityObservers = [];
const providerState = { revision: 1, active: false, completed: false, assistantItems: [] };
const userItem = {
  type: "userMessage", id: "provider-user-replacement",
  clientMessageId: "client-user-live-segments",
  content: [{ type: "text", text: "Exercise same runtime replacement" }],
};
const thread = () => ({
  id: threadId, name: "Authority replacement fixture", cwd: projectPath,
  createdAt: 1_786_464_000, updatedAt: 1_786_464_000 + providerState.revision,
  ephemeral: false, canAcceptDirectInput: true,
  status: providerState.active ? { type: "active", activeFlags: [] } : { type: "idle" },
});
const turn = () => ({
  id: turnId, status: providerState.active ? "inProgress" : "completed",
  items: [userItem, ...providerState.assistantItems],
});
const catalogTime = "2026-08-11T16:00:00.000Z";
function seed(provider, providerSessionId, index) {
  return {
    entry: {
      provider, providerSessionId, revision: `fixture-${index}`,
      projectPath, firstPrompt: `Fixture conversation ${index}`,
      summary: `${index}:${"x".repeat(512)}`,
      createdAt: catalogTime, modifiedAt: catalogTime, recencyAt: catalogTime,
      availability: "durable",
    },
    status: {
      provider, providerSessionId, activity: "unknown", attention: "none",
      result: "none", runtimeAttachment: "notLoaded", source: "legacyRollout",
      confidence: "unknown", observedAt: catalogTime,
    },
  };
}
const seeds = [
  seed("codex", threadId, 0),
  ...Array.from({ length: 10_000 }, (_, index) => seed("claude", `capacity-${index}`, index + 1)),
];
let bridge;
let rpcFixture;
let historyRpc;
let httpServer;
let client;
let serverSocket;
let releaseAck = false;
let clientError;
let summary;

async function waitFor(condition, label, milliseconds = 10_000) {
  const deadline = Date.now() + milliseconds;
  while (!condition()) {
    if (clientError) throw clientError;
    assert.ok(Date.now() < deadline, `Timed out: ${label}`);
    await delay(5);
  }
}

try {
  rpcFixture = await startConversationAppServerFixture({
    home: fixtureHome, projectPath, threadId, turnId, state: providerState,
    thread, turn, trace: rpcTrace, reads: providerReads,
  });
  historyRpc = new CodexProcess();
  await historyRpc.initializeOnly(projectPath, 8_000);
  const promptHistory = new PromptHistoryStore(join(fixtureHome, "prompt-history.json"));
  await promptHistory.init();
  httpServer = createServer();
  bridge = new BridgeWebSocketServer({
    server: httpServer, authMode: "open", allowedDirs: [projectPath],
    promptHistoryStore: promptHistory, deltaBatchMs: 0,
    codexProcessFactory: () => {
      const runtime = new CodexProcess();
      runtime.on("message", (message) => {
        if (message.type !== "assistant") return;
        origins.push({
          assistantId: message.message.id,
          processActiveTurnId: runtime.activeTurnId,
          runtimeStates: bridge.localFeatures.listRuntimeConversationStates(),
        });
      });
      return runtime;
    },
    sessionCatalogMonitorFactory: () => ({
      isActive: true, currentRevision: 0, async start() {}, close() {},
    }),
    conversationSyncV2Options: {
      daemonMode: false, statusWatchdogMs: 60_000,
      coldReconcileMs: 60_000, focusedContentReconcileMs: 60_000,
      initialExternalCodexMonitors: 0, maxExternalCodexMonitors: 0,
      catalogReader: async () => seeds, statusReader: async () => new Map(),
      focusedCodexMetadataReader: async () => undefined,
      inspectCodexThread: async () => null,
      desktopToolTimelineReader: async () => ({ events: [], callIds: new Set() }),
      historyReader: async (target) => target.providerSessionId === threadId
        ? codexThreadToServerMessages({
            turns: (await historyRpc.listThreadTurns({ threadId, itemsView: "full" })).data,
          })
        : [],
    },
  });
  bridge.wss.on("connection", (socket) => { serverSocket = socket; });
  await new Promise((accept, reject) => {
    httpServer.once("error", reject);
    httpServer.listen(0, "127.0.0.1", accept);
  });
  const runtimeId = bridge.sessionManager.create(
    projectPath, undefined, [], undefined, "codex", { threadId },
  );
  const oldRuntime = bridge.sessionManager.get(runtimeId).process;
  await waitFor(() => oldRuntime.isWaitingForInput, "original actual process input_ready");
  await rpcFixture.beginTurn(oldRuntime);
  await waitFor(() => oldRuntime.activeTurnId === turnId, "actual Provider turn/started");
  const oldAuthority = oldRuntime.authorityGeneration;

  client = new WebSocket(`ws://127.0.0.1:${httpServer.address().port}`);
  function acknowledge(sequence) {
    const ack = {
      type: "conversation_sync_ack", protocolVersion: 2,
      subscriptionId, sequence,
    };
    clientFrames.push(ack);
    client.send(JSON.stringify(ack));
  }
  client.on("error", (error) => { clientError = error; });
  client.on("message", (raw) => {
    const frame = JSON.parse(raw.toString());
    frames.push(frame);
    if (releaseAck && frame.type === "conversation_sync_v2") acknowledge(frame.sequence);
  });
  await once(client, "open", { signal: AbortSignal.timeout(8_000) });
  client.send(JSON.stringify({
    type: "client_capabilities", supportedServerMessages: [
      "conversation_sync_v2", "conversation_runtime_overlay_v1",
      "conversation_sync_window_coverage_v1", "conversation_user_index_v1",
      "app_server_status_v1",
    ],
  }));
  client.send(JSON.stringify({
    type: "conversation_sync_subscribe", protocolVersion: 2,
    requestId: subscriptionId, threadContentStates: [], readWatermarks: [],
    focused: { provider: "codex", providerSessionId: threadId },
  }));
  // Read-only test diagnostics. All mutations use original SessionManager,
  // JSON-RPC notifications, public WebSocket subscribe and cumulative ACK.
  const handler = bridge.localFeatures.handlers.get("conversation_sync_subscribe");
  const subscription = () => handler.subscriptions.get(serverSocket);
  await waitFor(() => subscription()?.capacityWaiters.size > 0, "original outbound capacity waiter");
  const state = subscription();
  assert.ok(state.outstandingBytes <= 1024 * 1024);
  assert.ok(state.outstandingBytes + state.queuedBytes > 1024 * 1024);
  assert.ok(state.outstandingBytes + state.queuedBytes <= 2 * 1024 * 1024);

  const pending = (id) => [...state.pendingRuntimeOverlays.values()].find(
    (row) => row.payload.message.type === "assistant" && row.payload.message.message.id === id,
  );
  function emitItem(id, text) {
    rpcFixture.notify("item/started", { threadId, turnId, item: { id, type: "agentMessage" } });
    rpcFixture.notify("item/agentMessage/delta", { threadId, turnId, itemId: id, delta: text });
    rpcFixture.notify("item/completed", {
      threadId, turnId, item: { id, type: "agentMessage", text },
    });
    providerState.assistantItems.push({ id, type: "agentMessage", text });
    providerState.revision += 1;
  }
  const oldItemId = "assistant-old-authority-pending";
  const newItemId = "assistant-new-authority-pending";
  let oldOverlayWait;
  let oldOverlayResolver;
  let oldOverlayWaitSettled = false;
  if (capacityGate === "overlay") {
    const originalWait = handler.waitForOutboundCapacity;
    // Observe the original call and return its exact Promise. This wrapper
    // neither owns the capacity gate nor changes its result or scheduling.
    handler.waitForOutboundCapacity = function (socket, current, payload) {
      const before = new Set(current.capacityWaiters);
      const result = originalWait.call(this, socket, current, payload);
      const addedWaiters = [...current.capacityWaiters].filter((waiter) => !before.has(waiter));
      if (payload.event === "runtime_overlay" &&
          payload.message.message.id === oldItemId &&
          addedWaiters.length > 0) {
        assert.equal(addedWaiters.length, 1);
        assert.equal(oldOverlayWait, undefined);
        oldOverlayResolver = addedWaiters[0];
        const entry = {
          stage: "original-overlay-capacity-entered", overlayId: payload.overlayId,
          runtimeId: payload.runtimeSessionId, authority: payload.authorityGeneration,
          observedAt: payload.observedAt, turnId: payload.turnId,
          estimatedFrameBytes: pending(oldItemId).bytes,
          outstandingBytes: current.outstandingBytes, queuedBytes: current.queuedBytes,
          capacityWaiters: current.capacityWaiters.size,
          addedOriginalWaiters: addedWaiters.length,
          pendingStatusState: current.pendingStatusState,
          nextSequence: current.nextSequence,
          caller: new Error().stack,
          runtimeStates: bridge.localFeatures.listRuntimeConversationStates(),
        };
        capacityTrace.push(entry);
        oldOverlayWait = entry;
        capacityObservers.push(result.then((accepted) => {
          oldOverlayWaitSettled = true;
          capacityTrace.push({
            stage: "original-overlay-capacity-returned", overlayId: payload.overlayId,
            accepted, runtimeStates: bridge.localFeatures.listRuntimeConversationStates(),
            outstandingBytes: current.outstandingBytes, queuedBytes: current.queuedBytes,
            capacityWaiters: current.capacityWaiters.size,
          });
        }));
      }
      return result;
    };
  }
  emitItem(oldItemId, capacityGate === "overlay"
    ? "A".repeat(60_000)
    : "Old process commentary awaiting original capacity");
  await waitFor(() => pending(oldItemId), "actual old process overlay pending");
  assert.equal(pending(oldItemId).payload.runtimeSessionId, runtimeId);
  assert.equal(pending(oldItemId).payload.authorityGeneration, oldAuthority);
  stages.push({ stage: "old-pending-at-capacity", runtimeId, oldAuthority,
    outstandingBytes: state.outstandingBytes, queuedBytes: state.queuedBytes,
    capacityWaiters: state.capacityWaiters.size,
    oldOverlayId: pending(oldItemId).payload.overlayId });

  if (capacityGate === "overlay") {
    const deadline = Date.now() + 10_000;
    while (!oldOverlayWait) {
      assert.ok(Date.now() < deadline, "A must enter its own original capacity wait");
      assert.equal(frames.filter((f) => f.event === "runtime_overlay").length, 0);
      const sequence = state.outstanding.keys().next().value;
      assert.ok(sequence, "Only an actual outstanding public frame can be ACKed");
      acknowledge(sequence);
      await waitFor(() => !state.outstanding.has(sequence) &&
        (oldOverlayWait || state.capacityWaiters.size > 0), "single-frame ACK advances original capacity", 2_000);
    }
    assert.equal(oldOverlayWaitSettled, false);
    assert.ok(state.capacityWaiters.has(oldOverlayResolver));
    assert.ok(oldOverlayWait.caller.includes("sendPendingRuntimeOverlays"));
    assert.ok(oldOverlayWait.estimatedFrameBytes <= 64 * 1024);
    assert.ok(oldOverlayWait.outstandingBytes + oldOverlayWait.queuedBytes +
      oldOverlayWait.estimatedFrameBytes > 2 * 1024 * 1024);
    assert.equal(oldOverlayWait.authority, oldAuthority);
    stages.push({ stage: "old-awaiting-own-capacity-before-replacement", runtimeId, oldAuthority,
      oldOverlayId: oldOverlayWait.overlayId, oldWaitUnsettled: !oldOverlayWaitSettled });
  }

  const replacementId = await bridge.sessionManager.replaceCodexSession(
    runtimeId, projectPath, [], undefined, { threadId }, 8_000,
  );
  const newRuntime = bridge.sessionManager.get(runtimeId).process;
  const newAuthority = newRuntime.authorityGeneration;
  assert.equal(replacementId, runtimeId);
  assert.notEqual(newRuntime, oldRuntime);
  assert.notEqual(newAuthority, oldAuthority);
  if (capacityGate === "overlay") {
    assert.equal(oldOverlayWaitSettled, false);
    assert.ok(state.capacityWaiters.has(oldOverlayResolver));
  }
  assert.ok(pending(oldItemId), "Old event must still be pending before ACK releases the gate");
  rpcFixture.notify("turn/started", { threadId, turn: { id: turnId, status: "inProgress" } });
  await waitFor(() => newRuntime.activeTurnId === turnId, "replacement actual Provider turn/started");
  emitItem(newItemId, "New process commentary awaiting the same capacity gate");
  await waitFor(() => pending(newItemId), "actual new process overlay pending");
  if (capacityGate === "overlay") {
    assert.equal(oldOverlayWaitSettled, false);
    assert.ok(state.capacityWaiters.has(oldOverlayResolver));
    const projected = handler.statusProjection.get(pending(oldItemId).key);
    assert.equal(projected.authorityGeneration, newAuthority);
    assert.equal(state.pendingStatusState, oldOverlayWait.pendingStatusState);
    capacityTrace.push({
      stage: "replacement-with-original-overlay-wait-unsettled", runtimeId,
      oldAuthority, newAuthority, currentProjectedStatus: projected,
      pendingStatusState: state.pendingStatusState,
      originalWaiterStillPresent: state.capacityWaiters.has(oldOverlayResolver),
      originalWaitStillUnsettled: !oldOverlayWaitSettled,
    });
  }
  assert.equal(pending(newItemId).payload.runtimeSessionId, runtimeId);
  assert.equal(pending(newItemId).payload.authorityGeneration, newAuthority);
  assert.ok(state.capacityWaiters.size > 0);
  assert.equal(frames.filter((f) => f.event === "runtime_overlay").length, 0);
  stages.push({ stage: "same-id-replacement-before-ack", runtimeId, oldAuthority, newAuthority,
    oldStillPending: Boolean(pending(oldItemId)), newOverlayId: pending(newItemId).payload.overlayId });

  releaseAck = true;
  const lastSent = frames.filter((f) => f.type === "conversation_sync_v2").at(-1);
  assert.ok(lastSent, "Capacity gate must have actual sent frames to ACK");
  acknowledge(lastSent.sequence);
  await waitFor(() => frames.some((f) => f.event === "runtime_overlay" &&
    f.message.message.id === newItemId), "new authority overlay on original wire after ACK");
  if (capacityGate === "overlay") {
    assert.equal(oldOverlayWaitSettled, true);
    const returned = capacityTrace.find((row) => row.stage === "original-overlay-capacity-returned");
    assert.equal(returned.accepted, true);
    assert.equal(returned.runtimeStates[0].bridgeSessionId, runtimeId);
    assert.equal(returned.runtimeStates[0].authorityGeneration, newAuthority);
  }
  stages.push({ stage: "replacement-overlay-wire", runtimeId, oldAuthority, newAuthority,
    pendingRuntimeOverlayCount: state.pendingRuntimeOverlays.size,
    pendingRuntimeOverlayBytes: state.pendingRuntimeOverlayBytes });
  // A leftover old authority must fail directly, rather than being hidden by
  // closing the subscription or only appearing as an eventual drain timeout.
  assert.equal(state.pendingRuntimeOverlays.size, 0, "Retired authority overlay remains pending");
  assert.equal(state.pendingRuntimeOverlayBytes, 0);
  await waitFor(() => frames.some((f) => f.event === "sync_complete") &&
    !state.syncing && state.capacityWaiters.size === 0 && state.outbound.length === 0 &&
    state.outstandingBytes === 0 && state.queuedBytes === 0 &&
    state.pendingRuntimeOverlays.size === 0 && state.pendingRuntimeOverlayBytes === 0,
  "ACK drain of original subscription");
  const overlays = frames.filter((f) => f.event === "runtime_overlay");
  assert.deepEqual(overlays.map((f) => f.message.message.id), [newItemId]);
  assert.equal(overlays[0].runtimeSessionId, runtimeId);
  assert.equal(overlays[0].authorityGeneration, newAuthority);
  const matchingStatus = frames.filter((f) => f.event === "status_changes").find((f) =>
    f.sequence < overlays[0].sequence && f.changes.some((s) =>
      s.runtimeSessionId === runtimeId && s.authorityGeneration === newAuthority && s.activeTurnId === turnId));
  assert.ok(matchingStatus, "Actual replacement status must be sequenced before its overlay");
  assert.equal(frames.filter((f) => f.event === "sync_failed").length, 0);
  assert.equal(frames.filter((f) => f.errorCode === "unsupported_message").length, 0);
  stages.push({ stage: "ack-drained", runtimeId, oldAuthority, newAuthority,
    statusSequence: matchingStatus.sequence, overlaySequence: overlays[0].sequence,
    outstandingBytes: state.outstandingBytes, queuedBytes: state.queuedBytes,
    pendingRuntimeOverlayBytes: state.pendingRuntimeOverlayBytes, capacityWaiters: state.capacityWaiters.size });
  summary = { runtimeId, oldAuthority, newAuthority, oldItemId, newItemId, capacityGate,
    statusSequence: matchingStatus.sequence, overlaySequence: overlays[0].sequence,
    traceRoot, originalAckDrainVerified: true, oldOverlayRetired: true, newOverlaySentOnce: true,
    oldOverlayOwnWaitEntered: Boolean(oldOverlayWait), oldOverlayOwnWaitReturnedAfterReplacement: oldOverlayWaitSettled };
} finally {
  rpcFixture?.beginShutdown();
  client?.terminate();
  await bridge?.close();
  await Promise.allSettled(capacityObservers);
  historyRpc?.stop();
  await rpcFixture?.close();
  if (httpServer?.listening) await new Promise((accept) => httpServer.close(accept));
  for (const [name, rows] of [
    ["authority-replacement.jsonl", stages], ["bridge-frame.jsonl", frames],
    ["app-server-wire.jsonl", rpcTrace], ["provider-read.jsonl", providerReads],
    ["runtime-overlay-origin.jsonl", origins],
    ["client-frame.jsonl", clientFrames], ["authority-capacity-wait.jsonl", capacityTrace],
  ]) {
    await writeFile(join(traceRoot, name), rows.map((row) => JSON.stringify(row)).join("\n") + "\n");
  }
}
console.log(`${capacityGate === "overlay" ? "C1I" : "C1G"}_ACCEPTANCE ${JSON.stringify(summary)}`);
