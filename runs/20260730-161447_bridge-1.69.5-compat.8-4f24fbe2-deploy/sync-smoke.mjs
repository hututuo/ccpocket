import { createRequire } from "node:module";
import { performance } from "node:perf_hooks";

const runtimeRoot =
  "/Users/huyiyang/Library/Application Support/ccPocket Bridge/runtime/1.69.5-compat.8-4f24fbe2";
const require = createRequire(`${runtimeRoot}/package.json`);
const WebSocket = require("ws");

const mode = process.env.SMOKE_MODE;
const port = Number(process.env.SMOKE_PORT ?? "18765");
if (mode !== "legacy" && mode !== "capable") {
  throw new Error("SMOKE_MODE must be legacy or capable");
}

const supportedServerMessages = ["conversation_sync_v2"];
if (mode === "capable") {
  supportedServerMessages.push("app_server_status_v1");
}

const startedAt = performance.now();
const socket = new WebSocket(`ws://127.0.0.1:${port}`);
const deadline = setTimeout(() => {
  console.error(JSON.stringify({ mode, error: "timeout" }));
  socket.terminate();
  process.exitCode = 1;
}, 90_000);

let beginMs;
let priorityMs;
let maxFrameBytes = 0;
let totalBytes = 0;
let catalogCount = 0;
let statusCount = 0;
let timelinePageCount = 0;
let workingCount = 0;
let observedCount = 0;
let completed = false;
const resetScopes = new Set();

socket.on("open", () => {
  socket.send(
    JSON.stringify({
      type: "client_capabilities",
      protocolVersion: 1,
      appVersion: mode === "legacy" ? "1.111.1+208" : "1.111.1+209",
      supportedServerMessages,
    }),
  );
  setTimeout(() => {
    socket.send(
      JSON.stringify({
        type: "conversation_sync_subscribe",
        protocolVersion: 2,
        requestId: `compat8-smoke-${mode}`,
        catalogState: "stale-catalog-state",
        statusState: "stale-status-state",
        threadContentStates: [],
        readWatermarks: [],
      }),
    );
  }, 50);
});

socket.on("message", (data) => {
  const bytes = Buffer.byteLength(data);
  maxFrameBytes = Math.max(maxFrameBytes, bytes);
  totalBytes += bytes;
  const message = JSON.parse(data.toString());
  if (
    message.type !== "conversation_sync_v2" ||
    typeof message.sequence !== "number"
  ) {
    return;
  }

  socket.send(
    JSON.stringify({
      type: "conversation_sync_ack",
      protocolVersion: 2,
      subscriptionId: message.subscriptionId,
      sequence: message.sequence,
    }),
  );

  if (message.event === "sync_begin") {
    beginMs ??= performance.now() - startedAt;
  } else if (message.event === "sync_reset") {
    resetScopes.add(message.scope);
  } else if (message.event === "catalog_changes") {
    catalogCount +=
      message.created.length + message.updated.length + message.destroyed.length;
  } else if (message.event === "status_changes") {
    statusCount += message.changes.length;
    workingCount += message.changes.filter(
      (status) => status.activity === "working",
    ).length;
    observedCount += message.changes.filter(
      (status) => status.confidence === "observed",
    ).length;
  } else if (message.event === "timeline_page") {
    timelinePageCount += 1;
  } else if (
    message.event === "sync_checkpoint" &&
    message.phase === "priority"
  ) {
    priorityMs ??= performance.now() - startedAt;
  } else if (message.event === "sync_complete") {
    if (completed) return;
    completed = true;
    clearTimeout(deadline);
    console.log(
      JSON.stringify({
        mode,
        beginMs,
        priorityMs,
        completeMs: performance.now() - startedAt,
        resetScopes: [...resetScopes].sort(),
        catalogCount,
        statusCount,
        workingCount,
        observedCount,
        timelinePageCount,
        maxFrameBytes,
        totalBytes,
      }),
    );
    socket.close();
  }
});

socket.on("error", (error) => {
  clearTimeout(deadline);
  console.error(JSON.stringify({ mode, error: error.message }));
  process.exitCode = 1;
});

socket.on("close", () => {
  clearTimeout(deadline);
});
