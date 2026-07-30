import { createRequire } from "node:module";

const runtimeRoot =
  "/Users/huyiyang/Library/Application Support/ccPocket Bridge/runtime/1.69.4-compat.6-19ee1609";
const require = createRequire(`${runtimeRoot}/package.json`);
const WebSocket = require("ws");

const mode = process.argv[2];
const port = Number(process.argv[3] ?? "18765");
if (mode !== "legacy" && mode !== "capable") {
  throw new Error(
    "usage: candidate-sync-smoke.mjs legacy|capable [port]",
  );
}
if (!Number.isInteger(port) || port < 1 || port > 65_535) {
  throw new Error("port must be an integer from 1 to 65535");
}

const supportedServerMessages = ["conversation_sync_v2"];
if (mode === "capable") {
  supportedServerMessages.push("app_server_status_v1");
}

const socket = new WebSocket(
  `ws://127.0.0.1:${port}${
    port === 18765 ? "?token=smoke-test-key" : ""
  }`,
);
const deadline = setTimeout(() => {
  console.error(JSON.stringify({ mode, error: "timeout" }));
  socket.terminate();
  process.exitCode = 1;
}, 60_000);

let subscribed = false;
let maxFrameBytes = 0;
let statusReset = false;
let syncComplete = false;
let catalogCount = 0;
let statusCount = 0;
const activityCounts = new Map();
const attachmentCounts = new Map();
const confidenceCounts = new Map();

function increment(map, key) {
  map.set(key, (map.get(key) ?? 0) + 1);
}

function sendSubscribe() {
  if (subscribed) return;
  subscribed = true;
  socket.send(
    JSON.stringify({
      type: "client_capabilities",
      protocolVersion: 1,
      appVersion: mode === "legacy" ? "1.110.1+206" : "future-source",
      supportedServerMessages,
    }),
  );
  setTimeout(() => {
    socket.send(
      JSON.stringify({
        type: "conversation_sync_subscribe",
        protocolVersion: 2,
        requestId: `smoke-${mode}`,
        catalogState: "stale-catalog-state",
        statusState: "legacy-status-state",
        threadContentStates: [],
        readWatermarks: [],
      }),
    );
  }, 50);
}

socket.on("open", sendSubscribe);
socket.on("message", (data) => {
  const frameBytes = Buffer.byteLength(data);
  maxFrameBytes = Math.max(maxFrameBytes, frameBytes);
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

  if (message.event === "sync_reset" && message.scope === "status") {
    statusReset = true;
  } else if (message.event === "catalog_changes") {
    catalogCount +=
      message.created.length + message.updated.length + message.destroyed.length;
  } else if (message.event === "status_changes") {
    statusCount += message.changes.length;
    for (const status of message.changes) {
      increment(activityCounts, status.activity);
      increment(attachmentCounts, status.runtimeAttachment);
      increment(confidenceCounts, status.confidence);
    }
  } else if (message.event === "sync_complete") {
    if (syncComplete) return;
    syncComplete = true;
    clearTimeout(deadline);
    console.log(
      JSON.stringify({
        mode,
        statusReset,
        syncComplete,
        catalogCount,
        statusCount,
        activityCounts: Object.fromEntries(activityCounts),
        attachmentCounts: Object.fromEntries(attachmentCounts),
        confidenceCounts: Object.fromEntries(confidenceCounts),
        maxFrameBytes,
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
  if (!syncComplete && process.exitCode === undefined) {
    clearTimeout(deadline);
    console.error(JSON.stringify({ mode, error: "closed-before-complete" }));
    process.exitCode = 1;
  }
});
