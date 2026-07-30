import { performance } from "node:perf_hooks";

import { CodexProcess } from "../dist/codex-process.js";
import { ConversationSyncV2FeatureHandler } from "../dist/local-features/conversation-sync-v2.js";

const CAPABILITY = "conversation_sync_v2";
const LIVE_CATALOG_LIMIT = 1_500;
const LIVE_CATALOG_ITERATIONS = 20;
const LIVE_DELTA_COUNT = 1_000;
const BENCHMARK_CASES = [
  { catalogEntries: 1_500, iterations: 20 },
  { catalogEntries: 10_000, iterations: 5 },
];

function percentile(samples, quantile) {
  const index = Math.min(
    samples.length - 1,
    Math.ceil(samples.length * quantile) - 1,
  );
  return samples[index];
}

function syntheticSeeds(catalogEntries) {
  return Array.from({ length: catalogEntries }, (_, index) => {
    const timestamp =
      index < 10
        ? Date.now() - index * 60_000
        : Date.now() - (10 + index) * 86_400_000;
    const observedAt = new Date(timestamp).toISOString();
    const working = index === 700 || index === 900 || index === 1_200;
    return {
      entry: {
        provider: "claude",
        providerSessionId: `thread-${index}`,
        revision: `revision-${index}`,
        projectPath: `/benchmark/${index}`,
        firstPrompt: `Conversation ${index}`,
        createdAt: observedAt,
        modifiedAt: observedAt,
        recencyAt: observedAt,
        availability: "durable",
      },
      status: {
        provider: "claude",
        providerSessionId: `thread-${index}`,
        activity: working ? "working" : "unknown",
        attention: index === 1_300 ? "approval" : "none",
        result: "none",
        runtimeAttachment: working ? "loaded" : "notLoaded",
        source: working ? "bridgeRuntime" : "legacyRollout",
        confidence: working ? "authoritative" : "unknown",
        observedAt,
      },
    };
  });
}

function history(providerSessionId) {
  return [
    {
      type: "user_input",
      text: providerSessionId,
      userMessageUuid: `user-${providerSessionId}`,
    },
    {
      type: "assistant",
      messageUuid: `assistant-${providerSessionId}`,
      message: {
        id: `assistant-${providerSessionId}`,
        role: "assistant",
        model: "benchmark",
        content: [{ type: "text", text: "ok" }],
      },
    },
  ];
}

function context(client, runtime) {
  return {
    client,
    signal: new AbortController().signal,
    runtime,
  };
}

async function runSyntheticIteration(iteration, catalogEntries) {
  const seeds = syntheticSeeds(catalogEntries);
  const firstClient = {};
  let handler;
  let catalogReads = 0;
  let historyReads = 0;
  let activeReads = 0;
  let maxActiveReads = 0;
  let maxFrameBytes = 0;
  let totalSentBytes = 0;
  let firstCompletion;
  let priorityReached;
  const completed = new Promise((resolve) => {
    firstCompletion = resolve;
  });
  const priority = new Promise((resolve) => {
    priorityReached = resolve;
  });
  const runtime = {
    bridgeInstanceId: "benchmark-bridge",
    codexSourceId: "benchmark-source",
    getSession: () => undefined,
    getCodexThreadId: () => undefined,
    getActiveCodexProcess: () => null,
    createStandaloneCodexProcess: async () => {
      throw new Error("The synthetic benchmark does not start app-server.");
    },
    isClientOpen: () => true,
    supports: (_client, capability) => capability === CAPABILITY,
    send(client, message) {
      const bytes = Buffer.byteLength(JSON.stringify(message), "utf8");
      maxFrameBytes = Math.max(maxFrameBytes, bytes);
      totalSentBytes += bytes;
      if (client === firstClient && message.event === "sync_checkpoint") {
        if (message.phase === "priority") priorityReached(message);
      }
      if (client === firstClient && message.event === "sync_complete") {
        firstCompletion(message);
      }
      queueMicrotask(() => {
        void handler.handle(
          {
            type: "conversation_sync_ack",
            protocolVersion: 2,
            subscriptionId: message.subscriptionId,
            sequence: message.sequence,
          },
          context(client, runtime),
        );
      });
    },
  };
  handler = new ConversationSyncV2FeatureHandler(runtime, {
    catalogReader: async () => {
      catalogReads += 1;
      return seeds;
    },
    statusReader: async () => new Map(),
    historyReader: async (target) => {
      historyReads += 1;
      activeReads += 1;
      maxActiveReads = Math.max(maxActiveReads, activeReads);
      await new Promise((resolve) => setTimeout(resolve, 2));
      activeReads -= 1;
      return history(target.providerSessionId);
    },
    statusWatchdogMs: 600_000,
    coldReconcileMs: 600_000,
  });

  const requestId = `benchmark-${iteration}`;
  const startedAt = performance.now();
  await handler.handle(
    {
      type: "conversation_sync_subscribe",
      protocolVersion: 2,
      requestId,
      threadContentStates: [],
      readWatermarks: [],
    },
    context(firstClient, runtime),
  );
  await Promise.race([
    priority,
    new Promise((_, reject) =>
      setTimeout(() => reject(new Error("Priority sync timed out.")), 5_000),
    ),
  ]);
  const priorityMs = performance.now() - startedAt;
  const firstResult = await Promise.race([
    completed,
    new Promise((_, reject) =>
      setTimeout(() => reject(new Error("Initial sync timed out.")), 5_000),
    ),
  ]);
  const completeMs = performance.now() - startedAt;
  const readsAfterFirstSync = historyReads;

  const secondClient = {};
  let secondCompletion;
  const repeated = new Promise((resolve) => {
    secondCompletion = resolve;
  });
  const originalSend = runtime.send;
  runtime.send = (client, message) => {
    originalSend(client, message);
    if (client === secondClient && message.event === "sync_complete") {
      secondCompletion(message);
    }
  };
  await handler.handle(
    {
      type: "conversation_sync_subscribe",
      protocolVersion: 2,
      requestId: `repeat-${iteration}`,
      catalogState: firstResult.nextState.catalogState,
      statusState: firstResult.nextState.statusState,
      threadContentStates: firstResult.nextState.threadContentStates,
      readWatermarks: [],
    },
    context(secondClient, runtime),
  );
  await Promise.race([
    repeated,
    new Promise((_, reject) =>
      setTimeout(() => reject(new Error("Repeat sync timed out.")), 5_000),
    ),
  ]);

  const historyReadsBeforeLive = historyReads;
  let firstLiveCompletion;
  let secondLiveCompletion;
  const firstLive = new Promise((resolve) => {
    firstLiveCompletion = resolve;
  });
  const secondLive = new Promise((resolve) => {
    secondLiveCompletion = resolve;
  });
  const sendBeforeLive = runtime.send;
  runtime.send = (client, message) => {
    sendBeforeLive(client, message);
    if (message.event !== "sync_complete") return;
    if (client === firstClient) firstLiveCompletion(message);
    if (client === secondClient) secondLiveCompletion(message);
  };
  runtime.getProviderSessionId = () => "thread-700";
  const liveSession = {
    id: "runtime-thread-700",
    provider: "claude",
    process: {},
    projectPath: "/benchmark/700",
  };
  const liveDispatchStartedAt = performance.now();
  for (let index = 0; index < LIVE_DELTA_COUNT; index += 1) {
    handler.sessionMessage(liveSession, {
      type: index % 2 === 0 ? "stream_delta" : "thinking_delta",
      text: `delta-${index}`,
    });
  }
  const liveDispatchMs = performance.now() - liveDispatchStartedAt;
  await Promise.race([
    Promise.all([firstLive, secondLive]),
    new Promise((_, reject) =>
      setTimeout(() => reject(new Error("Live sync timed out.")), 5_000),
    ),
  ]);
  await new Promise((resolve) => setTimeout(resolve, 150));

  const result = {
    priorityMs,
    completeMs,
    historyReadsFirst: readsAfterFirstSync,
    historyReadsRepeat: historyReadsBeforeLive - readsAfterFirstSync,
    historyReadsLive: historyReads - historyReadsBeforeLive,
    catalogReads,
    liveDispatchMs,
    maxActiveReads,
    maxFrameBytes,
    totalSentBytes,
  };
  handler.close();
  return result;
}

async function benchmarkSyntheticSync(catalogEntries, iterations) {
  const results = [];
  for (let iteration = 0; iteration <= iterations; iteration += 1) {
    const result = await runSyntheticIteration(iteration, catalogEntries);
    if (iteration > 0) results.push(result);
  }
  const priority = results
    .map((result) => result.priorityMs)
    .sort((a, b) => a - b);
  const complete = results
    .map((result) => result.completeMs)
    .sort((a, b) => a - b);
  const liveDispatch = results
    .map((result) => result.liveDispatchMs)
    .sort((a, b) => a - b);
  const last = results.at(-1);
  const summary = {
    catalogEntries,
    iterations: results.length,
    priorityP50Ms: percentile(priority, 0.5),
    priorityP95Ms: percentile(priority, 0.95),
    completeP50Ms: percentile(complete, 0.5),
    completeP95Ms: percentile(complete, 0.95),
    historyReadsFirst: last.historyReadsFirst,
    historyReadsRepeat: last.historyReadsRepeat,
    historyReadsLive: last.historyReadsLive,
    catalogReads: last.catalogReads,
    liveDeltaCount: LIVE_DELTA_COUNT,
    liveDispatchP50Ms: percentile(liveDispatch, 0.5),
    liveDispatchP95Ms: percentile(liveDispatch, 0.95),
    maxActiveReads: Math.max(
      ...results.map((result) => result.maxActiveReads),
    ),
    maxFrameBytes: Math.max(...results.map((result) => result.maxFrameBytes)),
    maxSentBytesPerIteration: Math.max(
      ...results.map((result) => result.totalSentBytes),
    ),
  };
  if (summary.historyReadsRepeat !== 0) {
    throw new Error("Unchanged repeat sync reread provider history.");
  }
  if (summary.historyReadsLive > 1) {
    throw new Error("One dirty timeline caused more than one provider read.");
  }
  if (summary.catalogReads !== 1) {
    throw new Error("A second client or live delta rescanned the catalog.");
  }
  if (summary.maxActiveReads > 2) {
    throw new Error("Provider history concurrency exceeded the bound of 2.");
  }
  if (summary.maxFrameBytes > 64 * 1024) {
    throw new Error("A conversation_sync_v2 frame exceeded 64 KiB.");
  }
  return summary;
}

async function benchmarkLiveCatalog() {
  const processClient = new CodexProcess();
  await processClient.initializeOnly(process.cwd(), 30_000);
  const samples = [];
  let observedEntries = 0;
  try {
    for (
      let iteration = 0;
      iteration < LIVE_CATALOG_ITERATIONS;
      iteration += 1
    ) {
      const startedAt = performance.now();
      let cursor = null;
      let count = 0;
      do {
        const page = await processClient.listThreads({
          cursor,
          limit: 500,
          sortKey: "recency_at",
          sortDirection: "desc",
          archived: false,
          useStateDbOnly: true,
        });
        count += page.data.length;
        cursor = page.nextCursor;
      } while (cursor && count < LIVE_CATALOG_LIMIT);
      samples.push(performance.now() - startedAt);
      observedEntries = count;
    }
  } finally {
    processClient.stop();
  }
  samples.sort((left, right) => left - right);
  return {
    observedEntries,
    requestedLimit: LIVE_CATALOG_LIMIT,
    iterations: samples.length,
    medianMs: percentile(samples, 0.5),
    p95Ms: percentile(samples, 0.95),
    maxMs: samples.at(-1),
  };
}

const syntheticSync = {};
for (const benchmarkCase of BENCHMARK_CASES) {
  syntheticSync[`catalog${benchmarkCase.catalogEntries}`] =
    await benchmarkSyntheticSync(
      benchmarkCase.catalogEntries,
      benchmarkCase.iterations,
    );
}

const result = {
  generatedAt: new Date().toISOString(),
  liveCatalog: await benchmarkLiveCatalog(),
  syntheticSync,
};
console.log(JSON.stringify(result, null, 2));
