import { once } from "node:events";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it } from "vitest";
import { CodexProcess } from "./codex-process.js";
import type { ServerMessage } from "./parser.js";
import { startConversationAppServerFixture } from "../scripts/conversation-app-server-fixture.mjs";

it.skipIf(process.platform === "win32")("uses real private stdio RPC for provider reads, live segments and completion", async () => {
  const home = await mkdtemp(join(tmpdir(), "ccpocket-rpc-entry-"));
  const keys = ["HOME", "CODEX_HOME", "PATH", "BRIDGE_CODEX_APP_SERVER_MODE", "CCPOCKET_FIXTURE_RPC_PORT"] as const;
  const saved = Object.fromEntries(keys.map((key) => [key, process.env[key]]));
  const threadId = "rpc-entry-thread";
  const turnId = "rpc-entry-turn";
  const trace: Array<{ direction: string; raw: string }> = [];
  const state = { revision: 1, active: false };
  const runtime = new CodexProcess();
  const messages: ServerMessage[] = [];
  runtime.on("message", (message) => messages.push(message));
  let fixture;
  try {
    process.env.HOME = home;
    process.env.CODEX_HOME = join(home, "codex");
    process.env.BRIDGE_CODEX_APP_SERVER_MODE = "private";
    fixture = await startConversationAppServerFixture({
      home, projectPath: home, threadId, turnId, state, trace, reads: [],
      thread: () => ({ id: threadId, cwd: home, preview: "Synthetic stdio provider", status: { type: "idle" } }),
      turn: () => ({ id: turnId, status: "completed", items: [{ type: "userMessage", id: "rpc-user", content: [{ type: "text", text: "Fixture input" }] }] }),
    });
    await runtime.initializeOnly(home, 8000);
    expect((await runtime.listThreads()).data.map((thread) => thread.id)).toEqual([threadId]);
    expect((await runtime.listThreadTurns({ threadId, itemsView: "full" })).data).toHaveLength(1);
    const ready = once(runtime, "input_ready", { signal: AbortSignal.timeout(8000) });
    runtime.start(home, { threadId, model: "gpt-5.6-sol" });
    await ready;
    expect(runtime.usesSharedRuntimeTopology).toBe(false);
    await fixture.beginTurn(runtime);
    const nextInput = once(runtime, "input_ready", { signal: AbortSignal.timeout(8000) });
    fixture.notify("item/started", { threadId, turnId, item: { id: "rpc-assistant", type: "agentMessage" } });
    fixture.notify("item/agentMessage/delta", { threadId, turnId, itemId: "rpc-assistant", delta: "真实 RPC 中文输出" });
    fixture.notify("item/completed", { threadId, turnId, item: { id: "rpc-assistant", type: "agentMessage", text: "真实 RPC 中文输出" } });
    fixture.notify("turn/completed", { threadId, turn: { id: turnId, status: "completed" } });
    await nextInput;
    const assistants = messages.filter((message) => message.type === "assistant");
    expect(assistants).toHaveLength(1);
    expect(assistants[0]).toMatchObject({ message: { id: "rpc-assistant", content: [{ type: "text", text: "真实 RPC 中文输出" }] } });
    expect(runtime.isWaitingForInput).toBe(true);
    const requests = trace.filter((entry) => entry.direction === "bridge_to_provider").map((entry) => JSON.parse(entry.raw));
    for (const method of ["initialize", "initialized", "thread/list", "thread/turns/list", "thread/resume", "turn/start"]) {
      expect(requests.some((request) => request.method === method)).toBe(true);
    }
    const start = requests.find((request) => request.method === "turn/start");
    expect(start.params.threadId).toBe(threadId);
    expect(start.params.input).toEqual([{ type: "text", text: "Exercise live segment boundaries" }]);
  } finally {
    runtime.stop();
    await fixture?.close();
    for (const key of keys) {
      if (saved[key] === undefined) delete process.env[key];
      else process.env[key] = saved[key];
    }
    await rm(home, { recursive: true, force: true });
  }
}, 20000);
