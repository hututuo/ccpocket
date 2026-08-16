import { createHash, randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import { createReadStream } from "node:fs";
import {
  constants as fsConstants,
  copyFile,
  mkdtemp,
  mkdir,
  readFile,
  rm,
  truncate,
  writeFile,
} from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { WebSocket } from "ws";
import { describe, expect, it } from "vitest";

interface RealRolloutManifest {
  version: number;
  threadId: string;
  sourcePathHint: string;
  stateDatabaseHint: string;
  prefixBytes: number;
  prefixSha256: string;
  prefixLines: number;
  rawTaskStartedTurns: number;
  rawUserMessages: number;
  latestTurnId: string;
  latestTurnRawItems: number;
  expectedFocusedWindow: {
    windowComplete: boolean;
    latestTurnComplete: boolean;
    entryCount: number;
    entryTypes: Record<string, number>;
    latestUserText: string;
    latestUserClientMessageId: string;
    entryIdsSha256: string;
  };
}

const repositoryRoot = resolve(
  dirname(fileURLToPath(import.meta.url)),
  "../../../..",
);
const manifestPath = join(
  repositoryRoot,
  "test-fixtures/conversation-chain/real-rollout.manifest.json",
);
const shouldRun = process.env.CCPOCKET_REAL_CHAIN === "1";

describe("real local rollout -> real Bridge -> raw WebSocket frames", () => {
  it.runIf(shouldRun)(
    "replays the immutable unredacted development prefix through production normalization",
    async () => {
      const manifest = JSON.parse(
        await readFile(manifestPath, "utf8"),
      ) as RealRolloutManifest;
      const sourcePath =
        process.env.CCPOCKET_REAL_ROLLOUT ?? manifest.sourcePathHint;
      const stateDatabase =
        process.env.CCPOCKET_REAL_STATE_DB ?? manifest.stateDatabaseHint;
      const verified = await hashPrefix(sourcePath, manifest.prefixBytes);
      expect(verified.sha256).toBe(manifest.prefixSha256);
      expect(verified.lines).toBe(manifest.prefixLines);
      expect(verified.endsWithLf).toBe(true);

      const runId = `${new Date().toISOString().replaceAll(":", "-")}-${randomUUID().slice(0, 8)}`;
      const traceRoot = join("/private/tmp/ccpocket-chain", runId);
      await mkdir(traceRoot, { recursive: true });
      const isolated = await prepareCodexHome(
        sourcePath,
        stateDatabase,
        manifest,
      );
      const priorEnv = {
        HOME: process.env.HOME,
        CODEX_HOME: process.env.CODEX_HOME,
        BRIDGE_CODEX_APP_SERVER_MODE:
          process.env.BRIDGE_CODEX_APP_SERVER_MODE,
      };
      process.env.HOME = isolated;
      process.env.CODEX_HOME = isolated;
      process.env.BRIDGE_CODEX_APP_SERVER_MODE = "private";
      // Import after the isolated environment is active. The production
      // session index intentionally caches Codex paths; importing it earlier
      // would let this test observe the live, still-growing developer rollout
      // instead of the frozen prefix.
      const [
        { BridgeWebSocketServer },
        { PromptHistoryStore },
        { CodexProcess },
      ] = await Promise.all([
        import("../websocket.js"),
        import("../prompt-history-store.js"),
        import("../codex-process.js"),
      ]);
      await prewarmCodexHome(
        manifest.threadId,
        new CodexProcess(globalThis.process.platform),
      );

      const httpServer = createServer();
      const promptHistory = new PromptHistoryStore(
        join(isolated, "ccpocket", "prompt-history.json"),
      );
      await promptHistory.init();
      const bridge = new BridgeWebSocketServer({
        server: httpServer,
        authMode: "open",
        allowedDirs: ["/Users/huyiyang/AI agent/Codex"],
        promptHistoryStore: promptHistory,
        sessionCatalogMonitorFactory: () => ({
          isActive: false,
          currentRevision: 0,
          async start() {},
          close() {},
        }),
        conversationSyncV2Options: {
          daemonMode: false,
          statusWatchdogMs: 60_000,
          coldReconcileMs: 60_000,
          initialExternalCodexMonitors: 0,
          maxExternalCodexMonitors: 0,
        },
      });
      const rawFrames: string[] = [];
      const ackFrames: string[] = [];
      let socket: WebSocket | undefined;
      try {
        await listen(httpServer);
        const address = httpServer.address();
        if (!address || typeof address === "string") {
          throw new Error("Loopback Bridge did not expose a TCP port");
        }
        socket = new WebSocket(`ws://127.0.0.1:${address.port}`);
        await onceOpen(socket);
        const completed = new Promise<Record<string, unknown>>(
          (resolveComplete, rejectComplete) => {
            let sawTargetTimeline = false;
            const timer = setTimeout(
              () => rejectComplete(new Error("real rollout sync timed out")),
              45_000,
            );
            socket!.on("message", (data) => {
              const raw = data.toString();
              rawFrames.push(raw);
              const message = JSON.parse(raw) as Record<string, unknown>;
              if (
                message.type === "conversation_sync_v2" &&
                typeof message.sequence === "number" &&
                typeof message.subscriptionId === "string"
              ) {
                const ack = JSON.stringify({
                  type: "conversation_sync_ack",
                  protocolVersion: 2,
                  subscriptionId: message.subscriptionId,
                  sequence: message.sequence,
                });
                ackFrames.push(ack);
                socket!.send(ack);
              }
              if (
                message.type === "conversation_sync_v2" &&
                message.event === "timeline_page" &&
                message.providerSessionId === manifest.threadId
              ) {
                sawTargetTimeline = true;
              }
              if (
                sawTargetTimeline &&
                message.type === "conversation_sync_v2" &&
                message.event === "sync_complete"
              ) {
                clearTimeout(timer);
                resolveComplete(message);
              }
            });
            socket!.once("error", rejectComplete);
          },
        );

        socket.send(
          JSON.stringify({
            type: "client_capabilities",
            appVersion: "real-chain-harness",
            protocolVersion: 2,
            supportedServerMessages: [
              "bridge_identity_v2",
              "conversation_sync_v2",
              "conversation_sync_window_coverage_v1",
              "conversation_sync_focus_refresh_v1",
              "conversation_user_index_v1",
              "app_server_status_v1",
            ],
          }),
        );
        const requestId = `real-${randomUUID()}`;
        socket.send(
          JSON.stringify({
            type: "conversation_sync_subscribe",
            protocolVersion: 2,
            requestId,
            threadContentStates: [],
            readWatermarks: [],
            focused: {
              provider: "codex",
              providerSessionId: manifest.threadId,
            },
          }),
        );
        await completed;
        const parsedFrames = rawFrames.map(
          (raw) => JSON.parse(raw) as Record<string, unknown>,
        );
        const timelinePages = parsedFrames.filter(
          (message) =>
            message.type === "conversation_sync_v2" &&
            message.event === "timeline_page" &&
            message.providerSessionId === manifest.threadId,
        );
        await writeJsonl(join(traceRoot, "bridge-frame.jsonl"), rawFrames);
        await writeJsonl(join(traceRoot, "ack.jsonl"), ackFrames);
        expect(timelinePages.length).toBeGreaterThan(0);
        expect(
          timelinePages.every(
            (message) => Buffer.byteLength(JSON.stringify(message)) <= 64 * 1024,
          ),
        ).toBe(true);
        const latestRevision = timelinePages.at(-1)?.revision;
        const latestPages = timelinePages.filter(
          (message) => message.revision === latestRevision,
        );
        const entries = latestPages.flatMap((message) =>
          Array.isArray(message.entries) ? message.entries : [],
        ) as Array<Record<string, unknown>>;
        const entryIds = entries.map((entry) => entry.entryId);
        expect(entryIds.length).toBeGreaterThan(0);
        expect(new Set(entryIds).size).toBe(entryIds.length);
        expect(
          latestPages.every((page) => typeof page.windowComplete === "boolean"),
        ).toBe(true);
        expect(
          entries.some((entry) => {
            const message = entry.message as Record<string, unknown> | undefined;
            return message?.historyTurnId === manifest.latestTurnId;
          }),
        ).toBe(true);
        expect(entries).toHaveLength(
          manifest.expectedFocusedWindow.entryCount,
        );
        const entryTypeCounts: Record<string, number> = {};
        const clientMessageIds: string[] = [];
        for (const entry of entries) {
          const message = entry.message as Record<string, unknown> | undefined;
          const type = typeof message?.type === "string" ? message.type : "";
          entryTypeCounts[type] = (entryTypeCounts[type] ?? 0) + 1;
          if (typeof message?.clientMessageId === "string") {
            clientMessageIds.push(message.clientMessageId);
          }
        }
        expect(entryTypeCounts).toEqual(
          manifest.expectedFocusedWindow.entryTypes,
        );
        expect(new Set(clientMessageIds).size).toBe(clientMessageIds.length);
        const latestUser = entries.find((entry) => {
          const message = entry.message as Record<string, unknown> | undefined;
          return (
            message?.type === "user_input" &&
            message.historyTurnId === manifest.latestTurnId
          );
        })?.message as Record<string, unknown> | undefined;
        expect(latestUser?.text).toBe(
          manifest.expectedFocusedWindow.latestUserText,
        );
        expect(latestUser?.clientMessageId).toBe(
          manifest.expectedFocusedWindow.latestUserClientMessageId,
        );
        expect(latestPages.every((page) => page.windowComplete)).toBe(
          manifest.expectedFocusedWindow.windowComplete,
        );
        expect(latestPages.every((page) => page.latestTurnComplete)).toBe(
          manifest.expectedFocusedWindow.latestTurnComplete,
        );
        const v2Sequences = parsedFrames
          .filter(
            (message) =>
              message.type === "conversation_sync_v2" &&
              typeof message.sequence === "number",
          )
          .map((message) => message.sequence as number);
        expect(v2Sequences).toEqual(
          Array.from({ length: v2Sequences.length }, (_, index) => index + 1),
        );
        const acknowledgedSequences = ackFrames.map(
          (raw) =>
            (JSON.parse(raw) as { sequence: number }).sequence,
        );
        expect(acknowledgedSequences).toEqual(v2Sequences);
        expect(
          parsedFrames.find(
            (message) =>
              message.type === "conversation_sync_v2" &&
              message.event === "sync_begin",
          )?.requestId,
        ).toBe(requestId);

        await writeFile(
          join(traceRoot, "summary.json"),
          `${JSON.stringify(
            {
              runId,
              sourcePath,
              prefixBytes: manifest.prefixBytes,
              prefixSha256: verified.sha256,
              threadId: manifest.threadId,
              frameCount: rawFrames.length,
              timelinePageCount: timelinePages.length,
              finalEntryCount: entries.length,
              finalEntryIdsSha256: createHash("sha256")
                .update(JSON.stringify(entryIds))
                .digest("hex"),
            },
            null,
            2,
          )}\n`,
        );
        expect(
          createHash("sha256").update(JSON.stringify(entryIds)).digest("hex"),
        ).toBe(manifest.expectedFocusedWindow.entryIdsSha256);
      } finally {
        socket?.close();
        await bridge.close();
        await closeServer(httpServer);
        restoreEnv("HOME", priorEnv.HOME);
        restoreEnv("CODEX_HOME", priorEnv.CODEX_HOME);
        restoreEnv(
          "BRIDGE_CODEX_APP_SERVER_MODE",
          priorEnv.BRIDGE_CODEX_APP_SERVER_MODE,
        );
        await rm(isolated, {
          recursive: true,
          force: true,
          maxRetries: 8,
          retryDelay: 100,
        });
      }
    },
    90_000,
  );
});

async function prepareCodexHome(
  sourcePath: string,
  stateDatabase: string,
  manifest: RealRolloutManifest,
): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), "ccpocket-real-codex-home-"));
  const rolloutPath = join(
    root,
    "sessions/2026/08/09",
    `rollout-real-${manifest.threadId}.jsonl`,
  );
  await mkdir(dirname(rolloutPath), { recursive: true });
  await copyFile(sourcePath, rolloutPath, fsConstants.COPYFILE_FICLONE);
  await truncate(rolloutPath, manifest.prefixBytes);
  const databasePath = join(root, "state_5.sqlite");
  execFileSync("sqlite3", [stateDatabase, `.backup '${sqlQuote(databasePath)}'`]);
  execFileSync("sqlite3", [
    databasePath,
    [
      `DELETE FROM threads WHERE id <> '${sqlQuote(manifest.threadId)}'`,
      `UPDATE threads SET rollout_path = '${sqlQuote(rolloutPath)}' WHERE id = '${sqlQuote(manifest.threadId)}'`,
    ].join("; "),
  ]);
  return root;
}

interface CodexCatalogProcess {
  initializeOnly(cwd: string, timeoutMs: number): Promise<void>;
  listThreads(options: {
    limit: number;
    archived: boolean;
    sortKey: "recency_at";
    sortDirection: "desc";
    useStateDbOnly: boolean;
    sourceKinds: string[];
  }): Promise<{ data: Array<{ id?: string }> }>;
  stop(): void;
}

async function prewarmCodexHome(
  threadId: string,
  process: CodexCatalogProcess,
): Promise<void> {
  try {
    await process.initializeOnly("/Users/huyiyang/AI agent/Codex", 15_000);
    const page = await process.listThreads({
      limit: 1,
      archived: false,
      sortKey: "recency_at",
      sortDirection: "desc",
      useStateDbOnly: true,
      sourceKinds: ["vscode"],
    });
    if (page.data[0]?.id !== threadId) {
      throw new Error("isolated Codex catalog did not expose the frozen thread");
    }
  } finally {
    process.stop();
  }
}

async function hashPrefix(
  path: string,
  bytes: number,
): Promise<{ sha256: string; lines: number; endsWithLf: boolean }> {
  const hash = createHash("sha256");
  let lines = 0;
  let last = -1;
  for await (const rawChunk of createReadStream(path, {
    start: 0,
    end: bytes - 1,
  })) {
    const chunk = rawChunk as Buffer;
    hash.update(chunk);
    for (const byte of chunk) if (byte === 0x0a) lines += 1;
    if (chunk.length > 0) last = chunk[chunk.length - 1]!;
  }
  return {
    sha256: hash.digest("hex"),
    lines,
    endsWithLf: last === 0x0a,
  };
}

function listen(server: ReturnType<typeof createServer>): Promise<void> {
  return new Promise((resolveListen, rejectListen) => {
    server.once("error", rejectListen);
    server.listen(0, "127.0.0.1", () => resolveListen());
  });
}

function closeServer(server: ReturnType<typeof createServer>): Promise<void> {
  if (!server.listening) return Promise.resolve();
  return new Promise((resolveClose, rejectClose) =>
    server.close((error) => (error ? rejectClose(error) : resolveClose())),
  );
}

function onceOpen(socket: WebSocket): Promise<void> {
  return new Promise((resolveOpen, rejectOpen) => {
    socket.once("open", resolveOpen);
    socket.once("error", rejectOpen);
  });
}

async function writeJsonl(path: string, values: readonly string[]): Promise<void> {
  await writeFile(path, values.length === 0 ? "" : `${values.join("\n")}\n`);
}

function sqlQuote(value: string): string {
  return value.replaceAll("'", "''");
}

function restoreEnv(key: string, value: string | undefined): void {
  if (value === undefined) delete process.env[key];
  else process.env[key] = value;
}
