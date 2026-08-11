import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { readFile, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const [inputArgument, outputArgument, provenanceArgument] = process.argv.slice(2);
if (!inputArgument || !outputArgument || !provenanceArgument) {
  throw new Error(
    "usage: node freeze-conversation-protocol-trace.mjs " +
      "<real-bridge-frame.jsonl> <protocol-wire.jsonl> <provenance.json>",
  );
}

const inputPath = resolve(inputArgument);
const outputPath = resolve(outputArgument);
const provenancePath = resolve(provenanceArgument);
const captureDirectory = dirname(inputPath);
const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const scenarioPath = resolve(
  scriptDirectory,
  "../../../test-fixtures/conversation-chain/scenarios.json",
);
const scenario = JSON.parse(await readFile(scenarioPath, "utf8"));
const expectedWindows = scenario.windowSequence;
if (!Array.isArray(expectedWindows) || expectedWindows.length === 0) {
  throw new Error("headless Provider window sequence is missing");
}

const inputBytes = await readFile(inputPath);
const inputSha256 = sha256(inputBytes);
const rawFrames = inputBytes
  .toString("utf8")
  .split("\n")
  .filter((line) => line.trim().length > 0)
  .map((line, index) => {
    const parsed = JSON.parse(line);
    const raw = parsed?.raw ?? parsed;
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
      throw new Error(`trace line ${index + 1} does not contain a raw frame`);
    }
    return structuredClone(raw);
  });

const firstV2Index = rawFrames.findIndex(
  (frame) => frame.type === "conversation_sync_v2",
);
if (firstV2Index < 0) throw new Error("capture contains no v2 frames");
const sessionList = rawFrames
  .slice(0, firstV2Index)
  .filter((frame) => frame.type === "session_list")
  .at(-1);
if (!sessionList) throw new Error("capture contains no authoritative session list");
const clientFramePath = resolve(captureDirectory, "client-frame.jsonl");
const clientFrameBytes = await readFile(clientFramePath);
const clientFrames = clientFrameBytes
  .toString("utf8")
  .split("\n")
  .filter((line) => line.trim())
  .map((line) => JSON.parse(line));
const coverageAdvertised = clientFrames.some(
  (frame) =>
    frame.type === "client_capabilities" &&
    Array.isArray(frame.supportedServerMessages) &&
    frame.supportedServerMessages.includes(
      "conversation_sync_window_coverage_v1",
    ),
);
if (!coverageAdvertised) {
  throw new Error("captured Mobile did not advertise window coverage");
}

const coreEvents = new Set([
  "sync_begin",
  "catalog_changes",
  "status_changes",
  "timeline_page",
  "sync_checkpoint",
  "sync_complete",
  "sync_reset",
]);
const capturedV2 = rawFrames.filter(
  (frame) =>
    frame.type === "conversation_sync_v2" && coreEvents.has(frame.event),
);
const subscriptions = new Set(
  capturedV2
    .map((frame) => frame.subscriptionId)
    .filter((value) => typeof value === "string" && value.length > 0),
);
if (subscriptions.size !== 1) {
  throw new Error(
    `expected one captured subscription, found ${subscriptions.size}`,
  );
}
const [subscriptionId] = subscriptions;

const formalBatches = [];
let currentBatch = null;
for (const frame of capturedV2) {
  if (frame.event !== "timeline_page") continue;
  if (!currentBatch) {
    currentBatch = {
      mode: frame.mode,
      baseRevision: frame.baseRevision ?? null,
      revision: frame.revision,
      windowComplete: frame.windowComplete === true,
      sourceEntryCount: frame.sourceEntryCount,
      payloadEntryCount: 0,
      deleteCount: 0,
    };
  }
  currentBatch.payloadEntryCount += frame.entries?.length ?? 0;
  currentBatch.deleteCount += frame.deletes?.length ?? 0;
  if (frame.pageIndex !== frame.pageCount - 1) continue;
  formalBatches.push(currentBatch);
  currentBatch = null;
}
if (currentBatch) throw new Error("capture ends inside a timeline batch");
if (formalBatches.length !== expectedWindows.length) {
  throw new Error(
    `expected ${expectedWindows.length} timeline batches, found ${formalBatches.length}`,
  );
}
for (let index = 0; index < expectedWindows.length; index += 1) {
  const expected = expectedWindows[index];
  const actual = formalBatches[index];
  if (
    actual.payloadEntryCount !== expected.count ||
    actual.sourceEntryCount !== expected.count ||
    actual.windowComplete !== expected.complete
  ) {
    throw new Error(
      `timeline batch ${index} mismatch: ` +
        `payload=${actual.payloadEntryCount} source=${actual.sourceEntryCount} ` +
        `complete=${actual.windowComplete}`,
    );
  }
  if (
    !expected.complete &&
    (actual.mode !== "patch" ||
      !actual.baseRevision ||
      actual.revision !== actual.baseRevision ||
      actual.deleteCount !== 0)
  ) {
    throw new Error(`timeline batch ${index} is not a safe additive patch`);
  }
}

const batchIds = new Map();
function frozenBatchId(value) {
  if (typeof value !== "string") return value;
  if (!batchIds.has(value)) {
    batchIds.set(value, `__BATCH_${String(batchIds.size + 1).padStart(3, "0")}__`);
  }
  return batchIds.get(value);
}

const normalizedSessionList = structuredClone(sessionList);
normalizedSessionList.bridgeInstanceId = "__BRIDGE_INSTANCE_ID__";
normalizedSessionList.codexSourceId = "__CODEX_SOURCE_ID__";
const normalizedV2 = capturedV2.map((frame, index) => {
  const normalized = structuredClone(frame);
  normalized.subscriptionId = "__SUBSCRIPTION_ID__";
  normalized.bridgeInstanceId = "__BRIDGE_INSTANCE_ID__";
  normalized.codexSourceId = "__CODEX_SOURCE_ID__";
  normalized.sequence = index + 1;
  if (typeof normalized.requestId === "string") {
    normalized.requestId = "__REQUEST_ID__";
  }
  if (normalized.batchId !== undefined) {
    normalized.batchId = frozenBatchId(normalized.batchId);
  }
  return normalized;
});

const frames = [normalizedSessionList, ...normalizedV2];
const output = `${frames.map((frame) => JSON.stringify(frame)).join("\n")}\n`;
await writeFile(outputPath, output);
const normalizedSha256 = sha256(output);
if (
  !scenario.protocolWireFixture ||
  scenario.protocolWireFixture.path !==
    "test-fixtures/conversation-chain/protocol-wire.jsonl"
) {
  throw new Error("scenario protocol wire metadata is missing or unexpected");
}
scenario.protocolWireFixture.sha256 = normalizedSha256;
scenario.protocolWireFixture.frameCount = frames.length;
scenario.protocolWireFixture.v2FrameCount = normalizedV2.length;
await writeFile(scenarioPath, `${JSON.stringify(scenario, null, 2)}\n`);

const providerReadPath = resolve(captureDirectory, "provider-read.jsonl");
const summaryPath = resolve(captureDirectory, "summary.json");
const providerReadBytes = await readFile(providerReadPath);
const summary = JSON.parse(await readFile(summaryPath, "utf8"));
const bridgeHead = execFileSync("git", ["rev-parse", "HEAD"], {
  cwd: resolve(scriptDirectory, "../../.."),
  encoding: "utf8",
}).trim();
const repositoryRoot = resolve(scriptDirectory, "../../..");
const bridgeDiff = execFileSync(
  "git",
  ["diff", "--binary", "--", "packages/bridge/src", "packages/bridge/scripts"],
  { cwd: repositoryRoot },
);
const sourceFiles = [
  "packages/bridge/dist/websocket.js",
  "packages/bridge/dist/local-features/conversation-sync-v2.js",
  "packages/bridge/dist/local-features/conversation-content-sync.js",
  "packages/bridge/scripts/conversation-chain-bridge-harness.mjs",
  "packages/bridge/scripts/freeze-conversation-protocol-trace.mjs",
  "test-fixtures/conversation-chain/scenarios.json",
];
const sourceFileSha256 = Object.fromEntries(
  await Promise.all(
    sourceFiles.map(async (relativePath) => [
      relativePath,
      sha256(await readFile(resolve(repositoryRoot, relativePath))),
    ]),
  ),
);
const provenance = {
  schemaVersion: 1,
  source: "fake Provider boundary -> production BridgeWebSocketServer capture",
  proves: [
    "formal conversation_sync_v2 framing",
    "window coverage capability",
    "W0 snapshot/patch payload sequence",
    "partial patches carry baseRevision and no deletes",
    "Mobile transport replay input",
  ],
  doesNotProve: [
    "Codex app-server raw turn normalization",
    "physical iPhone rendering",
  ],
  bridgeHead,
  bridgeTrackedDiffSha256: sha256(bridgeDiff),
  sourceFileSha256,
  captureSummary: summary,
  captureInputSha256: inputSha256,
  providerReadSha256: sha256(providerReadBytes),
  clientFrameSha256: sha256(clientFrameBytes),
  normalizedFrameCount: frames.length,
  normalizedV2FrameCount: normalizedV2.length,
  normalizedSha256,
  formalBatches,
};
await writeFile(provenancePath, `${JSON.stringify(provenance, null, 2)}\n`);
process.stdout.write(`${JSON.stringify(provenance)}\n`);

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}
