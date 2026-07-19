import { appendFile, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  CodexDesktopContinuityHandler,
  CodexRolloutMonitor,
  type CodexDesktopContinuityMonitorEvent,
} from "./slots/codex-desktop-continuity.js";
import type { LocalFeatureRuntime } from "./runtime.js";

const tempRoots: string[] = [];

afterEach(async () => {
  vi.useRealTimers();
  await Promise.all(
    tempRoots.splice(0).map((path) => rm(path, { recursive: true })),
  );
});

async function rollout(initialEntries: unknown[] = []) {
  const root = await mkdtemp(join(tmpdir(), "ccpocket-continuity-"));
  tempRoots.push(root);
  const path = join(root, "rollout.jsonl");
  await writeFile(
    path,
    initialEntries.map((entry) => JSON.stringify(entry)).join("\n") +
      (initialEntries.length > 0 ? "\n" : ""),
  );
  return path;
}

async function appendEntries(path: string, entries: unknown[]) {
  await appendFile(
    path,
    entries.map((entry) => JSON.stringify(entry)).join("\n") + "\n",
  );
}

function event(
  type: string,
  payload: Record<string, unknown>,
  timestamp = "2026-07-19T12:00:00Z",
) {
  return { timestamp, type, payload };
}

describe("CodexRolloutMonitor", () => {
  it("seeds an in-flight Desktop turn without replaying old content", async () => {
    const path = await rollout([
      event("event_msg", { type: "task_started", turn_id: "turn-1" }),
      event("event_msg", {
        type: "user_message",
        client_id: "desktop-1",
        message: "start",
      }),
      event("response_item", {
        type: "message",
        id: "old-answer",
        role: "assistant",
        content: [{ type: "output_text", text: "already persisted" }],
      }),
    ]);
    const events: CodexDesktopContinuityMonitorEvent[] = [];
    const monitor = new CodexRolloutMonitor({
      threadId: "thread-1",
      path,
      isLocalRuntimeActive: () => false,
      consumeLocalClientMessageId: () => false,
      onEvent: (entry) => events.push(entry),
    });
    await monitor.start();
    expect(monitor.snapshot).toEqual({ state: "running", turnId: "turn-1" });
    expect(monitor.hasExternalTurn).toBe(true);
    expect(events).toEqual([]);
    monitor.close();
  });

  it("keeps an already-running Bridge turn local when a watcher attaches", async () => {
    const path = await rollout([
      event("event_msg", { type: "task_started", turn_id: "turn-local" }),
      event("event_msg", {
        type: "user_message",
        client_id: "identity-lost-after-reconnect",
        message: "from phone",
      }),
    ]);
    const events: CodexDesktopContinuityMonitorEvent[] = [];
    const monitor = new CodexRolloutMonitor({
      threadId: "thread-1",
      path,
      isLocalRuntimeActive: () => true,
      consumeLocalClientMessageId: () => false,
      onEvent: (entry) => events.push(entry),
    });

    await monitor.start();

    expect(monitor.snapshot).toEqual({ state: "idle" });
    expect(monitor.hasExternalTurn).toBe(false);
    expect(events).toEqual([]);
    monitor.close();
  });

  it("streams Desktop user, reasoning, assistant, tool, and terminal items", async () => {
    const path = await rollout();
    const events: CodexDesktopContinuityMonitorEvent[] = [];
    const monitor = new CodexRolloutMonitor({
      threadId: "thread-1",
      path,
      isLocalRuntimeActive: () => false,
      consumeLocalClientMessageId: () => false,
      onEvent: (entry) => events.push(entry),
    });
    await monitor.start();
    await appendEntries(path, [
      event("event_msg", { type: "task_started", turn_id: "turn-1" }),
      event("event_msg", {
        type: "user_message",
        client_id: "desktop-1",
        message: "fix it",
      }),
      event("event_msg", { type: "agent_reasoning", text: "Inspecting" }),
      event("event_msg", { type: "agent_reasoning", text: "Inspecting" }),
      event("event_msg", {
        type: "agent_message",
        message: "Working",
        phase: "commentary",
      }),
      event("response_item", {
        type: "message",
        id: "answer-1",
        role: "assistant",
        phase: "commentary",
        content: [{ type: "output_text", text: "Working" }],
      }),
      event("response_item", {
        type: "function_call",
        call_id: "call-1",
        name: "exec_command",
        arguments: JSON.stringify({ cmd: "git status" }),
      }),
      event("response_item", {
        type: "function_call_output",
        call_id: "call-1",
        output: "clean",
      }),
      event("response_item", {
        type: "custom_tool_call",
        call_id: "call-2",
        name: "exec",
        input: "const value = 1;",
      }),
      event("response_item", {
        type: "custom_tool_call_output",
        call_id: "call-2",
        output: [
          { type: "input_text", text: "Script completed" },
          { type: "input_text", text: "value=1" },
        ],
      }),
      event("response_item", {
        type: "agent_message",
        id: "subagent-private-1",
        author: "/root/reviewer",
        recipient: "/root",
        content: [{ type: "input_text", text: "private review" }],
      }),
      event("event_msg", { type: "task_complete", turn_id: "turn-1" }),
    ]);
    await monitor.refreshNow();

    expect(events[0]).toMatchObject({
      kind: "state",
      state: "running",
      turnId: "turn-1",
    });
    expect(events).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          kind: "message",
          itemKey: "user:desktop-1",
          message: expect.objectContaining({
            type: "user_input",
            text: "fix it",
          }),
        }),
        expect.objectContaining({
          kind: "message",
          message: { type: "thinking_delta", text: "Inspecting\n" },
        }),
        expect.objectContaining({
          kind: "message",
          itemKey: "assistant:answer-1",
        }),
        expect.objectContaining({
          kind: "message",
          itemKey: "tool-start:call-1",
          message: expect.objectContaining({ type: "assistant" }),
        }),
        expect.objectContaining({
          kind: "message",
          itemKey: "tool-result:call-1",
          message: {
            type: "tool_result",
            toolUseId: "call-1",
            content: "clean",
            toolName: "Bash",
          },
        }),
        expect.objectContaining({
          kind: "message",
          itemKey: "tool-start:call-2",
          message: expect.objectContaining({ type: "assistant" }),
        }),
        expect.objectContaining({
          kind: "message",
          itemKey: "tool-result:call-2",
          message: {
            type: "tool_result",
            toolUseId: "call-2",
            content: "Script completed\nvalue=1",
            toolName: "exec",
          },
        }),
        expect.objectContaining({
          kind: "state",
          state: "idle",
          outcome: "completed",
          turnId: "turn-1",
        }),
      ]),
    );
    expect(
      events.filter(
        (entry) =>
          entry.kind === "message" && entry.message.type === "thinking_delta",
      ),
    ).toHaveLength(1);
    expect(
      events.some(
        (entry) =>
          entry.kind === "message" &&
          JSON.stringify(entry.message).includes("private review"),
      ),
    ).toBe(false);
    expect(
      events.filter(
        (entry) =>
          entry.kind === "message" &&
          entry.message.type === "assistant" &&
          entry.message.message.content.some(
            (content) =>
              content.type === "text" && content.text === "Working",
          ),
      ),
    ).toHaveLength(1);
    expect(monitor.hasExternalTurn).toBe(false);
    monitor.close();
  });

  it("keeps an older overlapping turn active when a newer turn completes first", async () => {
    const path = await rollout([
      event("event_msg", { type: "task_started", turn_id: "turn-older" }),
      event("event_msg", {
        type: "user_message",
        turn_id: "turn-older",
        client_id: "desktop-older",
        message: "older work",
      }),
      event("event_msg", { type: "task_started", turn_id: "turn-newer" }),
      event("event_msg", {
        type: "user_message",
        turn_id: "turn-newer",
        client_id: "desktop-newer",
        message: "newer work",
      }),
      event("event_msg", {
        type: "task_complete",
        turn_id: "turn-newer",
      }),
    ]);
    const events: CodexDesktopContinuityMonitorEvent[] = [];
    const monitor = new CodexRolloutMonitor({
      threadId: "thread-1",
      path,
      isLocalRuntimeActive: () => false,
      consumeLocalClientMessageId: () => false,
      onEvent: (entry) => events.push(entry),
    });

    await monitor.start();

    expect(monitor.snapshot).toEqual({
      state: "running",
      turnId: "turn-older",
    });
    expect(monitor.hasExternalTurn).toBe(true);
    expect(events).toEqual([]);
    monitor.close();
  });

  it("tracks overlapping live turns by id through out-of-order terminals", async () => {
    const path = await rollout();
    const events: CodexDesktopContinuityMonitorEvent[] = [];
    const monitor = new CodexRolloutMonitor({
      threadId: "thread-1",
      path,
      isLocalRuntimeActive: () => false,
      consumeLocalClientMessageId: () => false,
      onEvent: (entry) => events.push(entry),
    });
    await monitor.start();
    await appendEntries(path, [
      event("event_msg", { type: "task_started", turn_id: "turn-a" }),
      event("event_msg", {
        type: "user_message",
        turn_id: "turn-a",
        client_id: "desktop-a",
        message: "A",
      }),
      event("event_msg", { type: "task_started", turn_id: "turn-b" }),
      event("event_msg", {
        type: "user_message",
        turn_id: "turn-b",
        client_id: "desktop-b",
        message: "B",
      }),
    ]);

    await monitor.refreshNow();

    expect(monitor.hasExternalTurn).toBe(true);
    expect(monitor.externalTurnIdForSteering).toBeUndefined();

    await appendEntries(path, [
      event("event_msg", { type: "task_complete", turn_id: "turn-a" }),
    ]);
    await monitor.refreshNow();

    expect(monitor.snapshot).toEqual({ state: "running", turnId: "turn-b" });
    expect(monitor.externalTurnIdForSteering).toBe("turn-b");
    expect(
      events.some(
        (entry) => entry.kind === "state" && entry.state === "idle",
      ),
    ).toBe(false);
    expect(events.at(-1)).toMatchObject({
      kind: "state",
      state: "running",
      turnId: "turn-b",
    });

    await appendEntries(path, [
      event("event_msg", { type: "task_complete", turn_id: "turn-b" }),
    ]);
    await monitor.refreshNow();
    expect(events.at(-1)).toMatchObject({
      kind: "state",
      state: "idle",
      turnId: "turn-b",
    });
    monitor.close();
  });

  it("bounds unterminated legacy turns while retaining the newest overlap", async () => {
    const path = await rollout(
      Array.from({ length: 48 }, (_, index) =>
        event("event_msg", {
          type: "task_started",
          turn_id: `legacy-${index + 1}`,
        }),
      ),
    );
    const monitor = new CodexRolloutMonitor({
      threadId: "thread-1",
      path,
      isLocalRuntimeActive: () => false,
      consumeLocalClientMessageId: () => false,
      onEvent: () => {},
    });

    await monitor.start();

    expect((monitor as any).activeTurns.size).toBe(32);
    expect(monitor.snapshot).toEqual({
      state: "running",
      turnId: "legacy-48",
    });
    monitor.close();
  });

  it("pairs event assistant messages with canonical response ids and suppresses late duplicates", async () => {
    vi.useFakeTimers();
    const path = await rollout();
    const events: CodexDesktopContinuityMonitorEvent[] = [];
    const monitor = new CodexRolloutMonitor({
      threadId: "thread-1",
      path,
      isLocalRuntimeActive: () => false,
      consumeLocalClientMessageId: () => false,
      onEvent: (entry) => events.push(entry),
      assistantMessagePairMs: 40,
    });
    await monitor.start();
    await appendEntries(path, [
      event("event_msg", { type: "task_started", turn_id: "turn-pair" }),
      event("event_msg", {
        type: "user_message",
        client_id: "desktop-pair",
        message: "pair it",
      }),
      event("event_msg", {
        type: "agent_message",
        message: "Fallback final",
        phase: "final_answer",
      }),
    ]);
    await monitor.refreshNow();
    expect(
      events.filter(
        (entry) =>
          entry.kind === "message" && entry.message.type === "assistant",
      ),
    ).toHaveLength(0);

    await vi.advanceTimersByTimeAsync(40);
    const syntheticAssistants = events.filter(
      (entry) =>
        entry.kind === "message" && entry.message.type === "assistant",
    );
    expect(syntheticAssistants).toHaveLength(1);
    expect(syntheticAssistants[0]).toMatchObject({
      turnId: "turn-pair",
      message: {
        message: {
          id: expect.stringMatching(/^desktop-event-/),
          content: [{ type: "text", text: "Fallback final" }],
        },
      },
    });

    await appendEntries(path, [
      event("response_item", {
        type: "message",
        id: "canonical-too-late",
        role: "assistant",
        phase: "final_answer",
        content: [{ type: "output_text", text: "Fallback final" }],
      }),
    ]);
    await monitor.refreshNow();
    expect(
      events.filter(
        (entry) =>
          entry.kind === "message" && entry.message.type === "assistant",
      ),
    ).toHaveLength(1);

    await appendEntries(path, [
      event("event_msg", {
        type: "agent_message",
        message: "must not fire after close",
        phase: "commentary",
      }),
    ]);
    await monitor.refreshNow();
    monitor.close();
    expect((monitor as any).activeTurns.size).toBe(0);
    expect((monitor as any).pendingAssistantMessages.size).toBe(0);
    expect((monitor as any).recentResponseAssistants.size).toBe(0);
    expect((monitor as any).emittedKeys.size).toBe(0);
    await vi.advanceTimersByTimeAsync(40);
    expect(
      events.some(
        (entry) => JSON.stringify(entry).includes("must not fire after close"),
      ),
    ).toBe(false);
  });

  it("deduplicates reversed response/event ordering while preserving the real id", async () => {
    const path = await rollout();
    const events: CodexDesktopContinuityMonitorEvent[] = [];
    const monitor = new CodexRolloutMonitor({
      threadId: "thread-1",
      path,
      isLocalRuntimeActive: () => false,
      consumeLocalClientMessageId: () => false,
      onEvent: (entry) => events.push(entry),
    });
    await monitor.start();
    await appendEntries(path, [
      event("event_msg", { type: "task_started", turn_id: "turn-reverse" }),
      event("event_msg", {
        type: "user_message",
        client_id: "desktop-reverse",
        message: "reverse",
      }),
      event("response_item", {
        type: "message",
        id: "canonical-first",
        role: "assistant",
        phase: "commentary",
        content: [{ type: "output_text", text: "One message" }],
      }),
      event("event_msg", {
        type: "agent_message",
        message: "One message",
        phase: "commentary",
      }),
    ]);

    await monitor.refreshNow();

    const assistants = events.filter(
      (entry) =>
        entry.kind === "message" && entry.message.type === "assistant",
    );
    expect(assistants).toHaveLength(1);
    expect(assistants[0]).toMatchObject({
      itemKey: "assistant:canonical-first",
      message: { message: { id: "canonical-first" } },
    });
    monitor.close();
  });

  it("pairs a late canonical response to its completed turn instead of a newer turn", async () => {
    const path = await rollout();
    const events: CodexDesktopContinuityMonitorEvent[] = [];
    const monitor = new CodexRolloutMonitor({
      threadId: "thread-1",
      path,
      isLocalRuntimeActive: () => false,
      consumeLocalClientMessageId: () => false,
      onEvent: (entry) => events.push(entry),
    });
    await monitor.start();
    await appendEntries(path, [
      event("event_msg", { type: "task_started", turn_id: "turn-first" }),
      event("event_msg", {
        type: "user_message",
        client_id: "desktop-first",
        message: "first",
      }),
      event("event_msg", {
        type: "agent_message",
        message: "Belongs to first",
        phase: "commentary",
      }),
      event("event_msg", { type: "task_complete", turn_id: "turn-first" }),
      event("event_msg", { type: "task_started", turn_id: "turn-second" }),
      event("event_msg", {
        type: "user_message",
        client_id: "desktop-second",
        message: "second",
      }),
      event("response_item", {
        type: "message",
        id: "canonical-first-turn",
        role: "assistant",
        phase: "commentary",
        content: [{ type: "output_text", text: "Belongs to first" }],
      }),
    ]);

    await monitor.refreshNow();

    expect(
      events.find(
        (entry) =>
          entry.kind === "message" &&
          entry.itemKey === "assistant:canonical-first-turn",
      ),
    ).toMatchObject({ turnId: "turn-first" });
    expect(monitor.snapshot).toEqual({
      state: "running",
      turnId: "turn-second",
    });
    expect((monitor as any).pendingAssistantMessages.size).toBe(0);
    monitor.close();
  });

  it("emits bounded image generation metadata without forwarding base64 result", async () => {
    const path = await rollout();
    const events: CodexDesktopContinuityMonitorEvent[] = [];
    const monitor = new CodexRolloutMonitor({
      threadId: "thread-1",
      path,
      isLocalRuntimeActive: () => false,
      consumeLocalClientMessageId: () => false,
      onEvent: (entry) => events.push(entry),
    });
    await monitor.start();
    await appendEntries(path, [
      event("event_msg", { type: "task_started", turn_id: "turn-image" }),
      event("event_msg", {
        type: "user_message",
        client_id: "desktop-image",
        message: "draw",
      }),
      event("event_msg", {
        type: "image_generation_end",
        call_id: "ig-real-shape",
        status: "generating",
        revised_prompt: "Draw a compact diagram",
        result: "base64-must-never-cross-the-bridge",
        saved_path: "/Users/test/.codex/generated_images/output.png",
      }),
    ]);

    await monitor.refreshNow();

    const imageEvents = events.filter(
      (entry) => entry.kind === "message" && entry.itemKey.includes("ig-real"),
    );
    expect(imageEvents).toHaveLength(2);
    expect(imageEvents[0]).toMatchObject({
      itemKey: "tool-start:ig-real-shape",
      message: {
        message: {
          content: [
            {
              type: "tool_use",
              name: "ImageGeneration",
              input: {
                prompt: "Draw a compact diagram",
                status: "generating",
                saved_path:
                  "/Users/test/.codex/generated_images/output.png",
              },
            },
          ],
        },
      },
    });
    expect(JSON.stringify(imageEvents)).not.toContain(
      "base64-must-never-cross-the-bridge",
    );
    monitor.close();
  });

  it("clears external turns and requests history calibration on rollback", async () => {
    const path = await rollout();
    const events: CodexDesktopContinuityMonitorEvent[] = [];
    const monitor = new CodexRolloutMonitor({
      threadId: "thread-1",
      path,
      isLocalRuntimeActive: () => false,
      consumeLocalClientMessageId: () => false,
      onEvent: (entry) => events.push(entry),
    });
    await monitor.start();
    await appendEntries(path, [
      event(
        "event_msg",
        { type: "task_started", turn_id: "turn-before-rollback" },
        "2026-07-19T12:00:01Z",
      ),
      event(
        "event_msg",
        {
          type: "user_message",
          client_id: "desktop-before-rollback",
          message: "will roll back",
        },
        "2026-07-19T12:00:02Z",
      ),
      event(
        "event_msg",
        { type: "thread_rolled_back", num_turns: 2 },
        "2026-07-19T12:00:03Z",
      ),
    ]);

    await monitor.refreshNow();

    expect(monitor.hasExternalTurn).toBe(false);
    expect(monitor.snapshot).toEqual({ state: "idle" });
    expect(events.at(-1)).toMatchObject({
      kind: "state",
      state: "idle",
      outcome: "interrupted",
      timestamp: "2026-07-19T12:00:03Z",
    });
    expect(
      monitor.needsRehydrateSince(new Date("2026-07-19T12:00:00Z")),
    ).toBe(true);
    monitor.close();
  });

  it("suppresses a mobile-originated turn by client message identity", async () => {
    const path = await rollout();
    const events: CodexDesktopContinuityMonitorEvent[] = [];
    const monitor = new CodexRolloutMonitor({
      threadId: "thread-1",
      path,
      isLocalRuntimeActive: () => false,
      consumeLocalClientMessageId: (id) => id === "mobile-1",
      onEvent: (entry) => events.push(entry),
    });
    await monitor.start();
    await appendEntries(path, [
      event("event_msg", { type: "task_started", turn_id: "turn-local" }),
      event("event_msg", {
        type: "user_message",
        client_id: "mobile-1",
        message: "from phone",
      }),
      event("response_item", {
        type: "message",
        id: "local-answer",
        role: "assistant",
        content: [{ type: "output_text", text: "done" }],
      }),
      event("event_msg", {
        type: "task_complete",
        turn_id: "turn-local",
      }),
    ]);
    await monitor.refreshNow();
    expect(events).toEqual([]);
    expect(monitor.snapshot).toEqual({ state: "idle", turnId: "turn-local" });
    monitor.close();
  });

  it("detects a Desktop turn that starts while the Bridge owns another turn", async () => {
    const path = await rollout();
    const events: CodexDesktopContinuityMonitorEvent[] = [];
    const monitor = new CodexRolloutMonitor({
      threadId: "thread-1",
      path,
      isLocalRuntimeActive: () => true,
      consumeLocalClientMessageId: () => false,
      onEvent: (entry) => events.push(entry),
    });
    await monitor.start();
    await appendEntries(path, [
      event("event_msg", {
        type: "task_started",
        turn_id: "desktop-during-local",
      }),
      event("event_msg", {
        type: "user_message",
        turn_id: "desktop-during-local",
        client_id: "desktop-explicit-id",
        message: "Desktop started this competing turn",
      }),
    ]);

    await monitor.refreshNow();

    expect(monitor.hasExternalTurn).toBe(true);
    expect(monitor.externalTurnIdForSteering).toBe("desktop-during-local");
    expect(events).toEqual([
      expect.objectContaining({
        kind: "state",
        state: "running",
        turnId: "desktop-during-local",
      }),
      expect.objectContaining({
        kind: "message",
        turnId: "desktop-during-local",
        message: expect.objectContaining({
          type: "user_input",
          text: "Desktop started this competing turn",
        }),
      }),
    ]);
    monitor.close();
  });

  it("skips an oversized line and still observes the following terminal", async () => {
    const path = await rollout([
      event("event_msg", { type: "task_started", turn_id: "turn-1" }),
    ]);
    const events: CodexDesktopContinuityMonitorEvent[] = [];
    const monitor = new CodexRolloutMonitor({
      threadId: "thread-1",
      path,
      isLocalRuntimeActive: () => false,
      consumeLocalClientMessageId: () => false,
      onEvent: (entry) => events.push(entry),
    });
    await monitor.start();
    await appendFile(path, `${"x".repeat(2 * 1024 * 1024 + 32)}\n`);
    await appendEntries(path, [
      event("event_msg", { type: "turn_aborted", turn_id: "turn-1" }),
    ]);
    await monitor.refreshNow();
    expect(events).toEqual([
      expect.objectContaining({
        kind: "state",
        state: "idle",
        outcome: "interrupted",
        turnId: "turn-1",
      }),
    ]);
    monitor.close();
  });

  it("treats a seed window trapped inside one oversized item as active", async () => {
    const path = await rollout();
    await writeFile(path, "x".repeat(8 * 1024 * 1024 + 64));
    const events: CodexDesktopContinuityMonitorEvent[] = [];
    const monitor = new CodexRolloutMonitor({
      threadId: "thread-1",
      path,
      isLocalRuntimeActive: () => false,
      consumeLocalClientMessageId: () => false,
      onEvent: (entry) => events.push(entry),
    });
    await monitor.start();
    expect(monitor.snapshot).toEqual({ state: "running" });
    expect(monitor.hasExternalTurn).toBe(true);

    await appendFile(path, "\n");
    await appendEntries(path, [
      event("event_msg", { type: "task_complete", turn_id: "turn-large" }),
    ]);
    await monitor.refreshNow();
    expect(events).toEqual([
      expect.objectContaining({
        kind: "state",
        state: "idle",
        outcome: "completed",
        turnId: "turn-large",
      }),
    ]);
    monitor.close();
  });
});

describe("CodexDesktopContinuityHandler", () => {
  it("rejects a claimed cwd that does not belong to the bound runtime", async () => {
    const client = {};
    const sent: unknown[] = [];
    const resolveRolloutPath = vi.fn(async () => null);
    const session = {
      id: "runtime-path-bound",
      provider: "codex",
      projectPath: "/project/owned",
      process: { isWaitingForInput: true },
    };
    const runtime: LocalFeatureRuntime = {
      getSession: () => session,
      getCodexThreadId: () => "thread-path-bound",
      getActiveCodexProcess: () => null,
      createStandaloneCodexProcess: async () => {
        throw new Error("not used");
      },
      isProjectPathAllowed: () => true,
      isSessionProjectPath: () => false,
      send: (_client, message) => sent.push(message),
      supports: () => true,
    };
    const handler = new CodexDesktopContinuityHandler(runtime, {
      resolveRolloutPath,
    });

    await handler.handle(
      {
        type: "codex_desktop_continuity_watch",
        protocolVersion: 1,
        requestId: "watch-path-bound",
        sessionId: session.id,
        threadId: "thread-path-bound",
        projectPath: "/project/other",
      },
      { client, signal: new AbortController().signal, runtime },
    );

    expect(resolveRolloutPath).not.toHaveBeenCalled();
    expect(sent).toEqual([
      expect.objectContaining({
        type: "codex_desktop_continuity_event_v1",
        event: "error",
        errorCode: "continuity_binding_mismatch",
      }),
    ]);
    handler.close();
  });

  it("separates ambiguous external activity from a steerable turn id", async () => {
    const path = await rollout([
      event("event_msg", { type: "task_started", turn_id: "turn-a" }),
      event("event_msg", {
        type: "user_message",
        turn_id: "turn-a",
        client_id: "desktop-a",
        message: "A",
      }),
      event("event_msg", { type: "task_started", turn_id: "turn-b" }),
      event("event_msg", {
        type: "user_message",
        turn_id: "turn-b",
        client_id: "desktop-b",
        message: "B",
      }),
    ]);
    const client = {};
    const session = {
      id: "runtime-ambiguous",
      provider: "codex",
      projectPath: "/project",
      process: { isWaitingForInput: true },
    };
    const runtime: LocalFeatureRuntime = {
      getSession: () => session,
      getCodexThreadId: () => "thread-ambiguous",
      getActiveCodexProcess: () => null,
      createStandaloneCodexProcess: async () => {
        throw new Error("not used");
      },
      send: () => {},
      supports: (_client, type) => type === "codex_desktop_continuity_event_v1",
    };
    const handler = new CodexDesktopContinuityHandler(runtime, {
      resolveRolloutPath: async () => path,
    });
    await handler.handle(
      {
        type: "codex_desktop_continuity_watch",
        protocolVersion: 1,
        requestId: "watch-ambiguous",
        sessionId: session.id,
        threadId: "thread-ambiguous",
        projectPath: "/project",
      },
      { client, signal: new AbortController().signal, runtime },
    );

    expect(handler.hasExternalCodexActivity(session)).toBe(true);
    expect(handler.externalCodexTurnId(session)).toBeUndefined();
    handler.close();
  });

  it("negotiates a watch, queues during Desktop activity, and rehydrates after completion", async () => {
    const path = await rollout();
    const client = {};
    const sent: any[] = [];
    const rehydrate = vi
      .fn()
      .mockResolvedValueOnce(false)
      .mockResolvedValueOnce(false)
      .mockResolvedValue(true);
    const drainQueuedInput = vi.fn(() => true);
    const session = {
      id: "runtime-1",
      provider: "codex",
      projectPath: "/project",
      process: { isWaitingForInput: true },
    };
    const runtime: LocalFeatureRuntime = {
      bridgeInstanceId: "bridge-1",
      getSession: (id) => (id === session.id ? session : undefined),
      getCodexThreadId: () => "thread-1",
      getActiveCodexProcess: () => null,
      createStandaloneCodexProcess: async () => {
        throw new Error("not used");
      },
      isProjectPathAllowed: () => true,
      rehydrateCodexSessionAfterExternalTurn: rehydrate,
      hasCodexQueuedInput: () => true,
      drainCodexQueuedInputIfReady: drainQueuedInput,
      send: (_client, message) => sent.push(message),
      supports: (_client, type) => type === "codex_desktop_continuity_event_v1",
    };
    const handler = new CodexDesktopContinuityHandler(runtime, {
      resolveRolloutPath: async () => path,
      rehydrateSettleMs: 5,
      rehydrateRetryMs: 2,
    });
    await handler.handle(
      {
        type: "codex_desktop_continuity_watch",
        protocolVersion: 1,
        requestId: "watch-1",
        sessionId: "runtime-1",
        threadId: "thread-1",
        projectPath: "/project",
      },
      { client, signal: new AbortController().signal, runtime },
    );
    expect(sent.at(-1)).toMatchObject({
      type: "codex_desktop_continuity_event_v1",
      event: "watching",
      state: "unknown",
    });

    await appendEntries(path, [
      event("event_msg", { type: "task_started", turn_id: "turn-1" }),
      event("event_msg", {
        type: "user_message",
        client_id: "desktop-1",
        message: "from desktop",
      }),
    ]);
    const admission = await handler.admitInput!(client, session, {
      type: "input",
      sessionId: "runtime-1",
      clientMessageId: "mobile-1",
    });
    expect(admission).toEqual({
      action: "queue",
      reason: "desktop_turn_active",
    });
    expect(sent).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ event: "state", state: "running" }),
        expect.objectContaining({
          event: "message",
          message: expect.objectContaining({ type: "user_input" }),
        }),
      ]),
    );

    await appendEntries(path, [
      event("event_msg", { type: "task_complete", turn_id: "turn-1" }),
    ]);
    expect(
      await handler.admitInput!(client, session, {
        type: "input",
        sessionId: "runtime-1",
      }),
    ).toEqual({
      action: "queue",
      reason: "desktop_history_refreshing",
    });
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(sent).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          event: "state",
          state: "idle",
          outcome: "completed",
          handoffQueued: true,
        }),
      ]),
    );
    expect(rehydrate).toHaveBeenCalledWith("runtime-1", "thread-1");
    expect(drainQueuedInput).toHaveBeenCalledWith("runtime-1");
    expect(
      sent.some(
        (message) =>
          message.event === "error" &&
          message.errorCode === "runtime_rehydrate_failed",
      ),
    ).toBe(false);
    expect(
      await handler.admitInput!(client, session, {
        type: "input",
        sessionId: "runtime-1",
      }),
    ).toEqual({ action: "allow" });
    handler.close();
  });

  it("clears external ownership without hiding an already-running phone turn", async () => {
    const path = await rollout();
    const client = {};
    const sent: any[] = [];
    let localRuntimeActive = false;
    const session = {
      id: "runtime-local-handoff",
      provider: "codex",
      projectPath: "/project",
      process: { isWaitingForInput: true },
    };
    const runtime: LocalFeatureRuntime = {
      getSession: () => session,
      getCodexThreadId: () => "thread-local-handoff",
      getActiveCodexProcess: () => null,
      createStandaloneCodexProcess: async () => {
        throw new Error("not used");
      },
      isCodexThreadLocallyActive: () => localRuntimeActive,
      hasCodexQueuedInput: () => false,
      send: (_client, message) => sent.push(message),
      supports: () => true,
    };
    const handler = new CodexDesktopContinuityHandler(runtime, {
      resolveRolloutPath: async () => path,
    });
    await handler.handle(
      {
        type: "codex_desktop_continuity_watch",
        protocolVersion: 1,
        requestId: "watch-local-handoff",
        sessionId: session.id,
        threadId: "thread-local-handoff",
        projectPath: "/project",
      },
      { client, signal: new AbortController().signal, runtime },
    );
    await appendEntries(path, [
      event("event_msg", {
        type: "task_started",
        turn_id: "desktop-before-local",
      }),
      event("event_msg", {
        type: "user_message",
        turn_id: "desktop-before-local",
        client_id: "desktop-before-local",
        message: "desktop work",
      }),
    ]);
    await handler.admitInput!(client, session, {
      type: "input",
      sessionId: session.id,
    });

    localRuntimeActive = true;
    await appendEntries(path, [
      event("event_msg", {
        type: "task_complete",
        turn_id: "desktop-before-local",
      }),
    ]);
    await handler.admitInput!(client, session, {
      type: "input",
      sessionId: session.id,
    });

    expect(sent).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          event: "state",
          state: "idle",
          handoffQueued: true,
        }),
      ]),
    );
    handler.close();
  });

  it("rehydrates a Desktop terminal missed while the phone was disconnected", async () => {
    const path = await rollout([
      event(
        "event_msg",
        { type: "task_started", turn_id: "turn-offline" },
        "2026-07-19T12:00:01Z",
      ),
      event(
        "event_msg",
        {
          type: "user_message",
          client_id: "desktop-offline",
          message: "desktop work",
        },
        "2026-07-19T12:00:02Z",
      ),
      event(
        "event_msg",
        { type: "task_complete", turn_id: "turn-offline" },
        "2026-07-19T12:00:03Z",
      ),
    ]);
    const client = {};
    const sent: any[] = [];
    const rehydrate = vi.fn().mockResolvedValue(true);
    const session = {
      id: "runtime-1",
      provider: "codex",
      projectPath: "/project",
      createdAt: new Date("2026-07-19T12:00:00Z"),
      process: { isWaitingForInput: true },
    };
    const runtime: LocalFeatureRuntime = {
      getSession: () => session,
      getCodexThreadId: () => "thread-1",
      getActiveCodexProcess: () => null,
      createStandaloneCodexProcess: async () => {
        throw new Error("not used");
      },
      rehydrateCodexSessionAfterExternalTurn: rehydrate,
      hasCodexQueuedInput: () => true,
      send: (_client, message) => sent.push(message),
      supports: (_client, type) => type === "codex_desktop_continuity_event_v1",
    };
    const handler = new CodexDesktopContinuityHandler(runtime, {
      resolveRolloutPath: async () => path,
      rehydrateSettleMs: 5,
    });

    await handler.handle(
      {
        type: "codex_desktop_continuity_watch",
        protocolVersion: 1,
        requestId: "watch-offline",
        sessionId: session.id,
        threadId: "thread-1",
        projectPath: "/project",
      },
      { client, signal: new AbortController().signal, runtime },
    );
    expect(sent.at(-1)).toMatchObject({
      event: "watching",
      state: "idle",
      handoffQueued: true,
    });
    expect(
      await handler.admitInput!(client, session, {
        type: "input",
        sessionId: session.id,
      }),
    ).toEqual({
      action: "queue",
      reason: "desktop_history_refreshing",
    });
    await vi.waitFor(() => expect(rehydrate).toHaveBeenCalledOnce());
    expect(
      sent.some(
        (message) =>
          message.event === "error" &&
          message.errorCode === "runtime_rehydrate_failed",
      ),
    ).toBe(false);
    handler.close();
  });

  it("rehydrates authoritative history after an offline thread rollback", async () => {
    const path = await rollout([
      event(
        "event_msg",
        { type: "task_started", turn_id: "turn-rolled-back" },
        "2026-07-19T12:00:01Z",
      ),
      event(
        "event_msg",
        {
          type: "user_message",
          client_id: "desktop-rolled-back",
          message: "remove this turn",
        },
        "2026-07-19T12:00:02Z",
      ),
      event(
        "event_msg",
        { type: "thread_rolled_back", num_turns: 1 },
        "2026-07-19T12:00:03Z",
      ),
    ]);
    const client = {};
    const rehydrate = vi.fn().mockResolvedValue(true);
    const session = {
      id: "runtime-rollback",
      provider: "codex",
      projectPath: "/project",
      createdAt: new Date("2026-07-19T12:00:00Z"),
      process: { isWaitingForInput: true },
    };
    const runtime: LocalFeatureRuntime = {
      getSession: () => session,
      getCodexThreadId: () => "thread-rollback",
      getActiveCodexProcess: () => null,
      createStandaloneCodexProcess: async () => {
        throw new Error("not used");
      },
      rehydrateCodexSessionAfterExternalTurn: rehydrate,
      send: () => {},
      supports: (_client, type) => type === "codex_desktop_continuity_event_v1",
    };
    const handler = new CodexDesktopContinuityHandler(runtime, {
      resolveRolloutPath: async () => path,
      rehydrateSettleMs: 1,
    });

    await handler.handle(
      {
        type: "codex_desktop_continuity_watch",
        protocolVersion: 1,
        requestId: "watch-rollback",
        sessionId: session.id,
        threadId: "thread-rollback",
        projectPath: "/project",
      },
      { client, signal: new AbortController().signal, runtime },
    );

    await vi.waitFor(() => expect(rehydrate).toHaveBeenCalledOnce());
    expect(rehydrate).toHaveBeenCalledWith(
      "runtime-rollback",
      "thread-rollback",
    );
    handler.close();
  });

  it("does not rehydrate a completed mobile turn discovered during seed", async () => {
    const path = await rollout([
      event(
        "event_msg",
        { type: "task_started", turn_id: "turn-mobile" },
        "2026-07-19T12:00:01Z",
      ),
      event(
        "event_msg",
        {
          type: "user_message",
          client_id: "mobile-1",
          message: "phone work",
        },
        "2026-07-19T12:00:02Z",
      ),
      event(
        "event_msg",
        { type: "task_complete", turn_id: "turn-mobile" },
        "2026-07-19T12:00:03Z",
      ),
    ]);
    const client = {};
    const rehydrate = vi.fn().mockResolvedValue(true);
    const session = {
      id: "runtime-1",
      provider: "codex",
      projectPath: "/project",
      createdAt: new Date("2026-07-19T12:00:00Z"),
      process: { isWaitingForInput: true },
    };
    const runtime: LocalFeatureRuntime = {
      getSession: () => session,
      getCodexThreadId: () => "thread-1",
      getActiveCodexProcess: () => null,
      createStandaloneCodexProcess: async () => {
        throw new Error("not used");
      },
      rehydrateCodexSessionAfterExternalTurn: rehydrate,
      send: () => {},
      supports: (_client, type) => type === "codex_desktop_continuity_event_v1",
    };
    const handler = new CodexDesktopContinuityHandler(runtime, {
      resolveRolloutPath: async () => path,
      rehydrateSettleMs: 5,
    });
    handler.inputAccepted!(
      client,
      session,
      {
        type: "input",
        sessionId: session.id,
        clientMessageId: "mobile-1",
      },
      false,
    );

    await handler.handle(
      {
        type: "codex_desktop_continuity_watch",
        protocolVersion: 1,
        requestId: "watch-mobile",
        sessionId: session.id,
        threadId: "thread-1",
        projectPath: "/project",
      },
      { client, signal: new AbortController().signal, runtime },
    );
    expect(
      await handler.admitInput!(client, session, {
        type: "input",
        sessionId: session.id,
      }),
    ).toEqual({ action: "allow" });
    await new Promise((resolve) => setTimeout(resolve, 15));
    expect(rehydrate).not.toHaveBeenCalled();
    handler.close();
  });
});
