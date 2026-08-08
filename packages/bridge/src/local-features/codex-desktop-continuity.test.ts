import { appendFile, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { ServerMessage } from "../parser.js";
import {
  CodexDesktopContinuityHandler,
  CodexRolloutMonitor,
  inspectCodexRolloutSnapshot,
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
      getLocalActiveTurnId: () => undefined,
      consumeLocalClientMessageId: () => false,
      onEvent: (entry) => events.push(entry),
    });
    await monitor.start();
    expect(monitor.snapshot).toEqual({ state: "running", turnId: "turn-1" });
    expect(monitor.hasExternalTurn).toBe(true);
    expect(events).toEqual([]);
    monitor.close();
  });

  it("optionally replays only the active seed turn for v2 catch-up", async () => {
    const path = await rollout([
      event("event_msg", {
        type: "task_started",
        turn_id: "turn-complete",
      }),
      event("event_msg", {
        type: "user_message",
        client_id: "desktop-complete",
        message: "old completed request",
      }),
      event("response_item", {
        type: "message",
        id: "old-completed-answer",
        role: "assistant",
        content: [{ type: "output_text", text: "old completed answer" }],
      }),
      event("event_msg", {
        type: "task_complete",
        turn_id: "turn-complete",
      }),
      event(
        "event_msg",
        { type: "task_started", turn_id: "turn-active" },
        "2026-07-19T12:01:00Z",
      ),
      event(
        "event_msg",
        {
          type: "user_message",
          client_id: "desktop-active",
          message: "current request",
        },
        "2026-07-19T12:01:01Z",
      ),
      event(
        "event_msg",
        { type: "agent_reasoning", text: "current reasoning" },
        "2026-07-19T12:01:02Z",
      ),
      event(
        "response_item",
        {
          type: "function_call",
          call_id: "active-call",
          name: "exec_command",
          arguments: JSON.stringify({ cmd: "git status" }),
        },
        "2026-07-19T12:01:03Z",
      ),
      event(
        "response_item",
        {
          type: "function_call_output",
          call_id: "active-call",
          output: "clean",
        },
        "2026-07-19T12:01:04Z",
      ),
      event(
        "response_item",
        {
          type: "message",
          id: "active-answer",
          role: "assistant",
          content: [{ type: "output_text", text: "current answer" }],
        },
        "2026-07-19T12:01:05Z",
      ),
    ]);
    const events: CodexDesktopContinuityMonitorEvent[] = [];
    const monitor = new CodexRolloutMonitor({
      threadId: "thread-1",
      path,
      getLocalActiveTurnId: () => undefined,
      consumeLocalClientMessageId: () => false,
      onEvent: (entry) => events.push(entry),
      replayActiveTurnMessages: true,
      assistantMessagePairMs: 0,
    });

    await monitor.start();
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(monitor.snapshot).toEqual({
      state: "running",
      turnId: "turn-active",
    });
    expect(JSON.stringify(events)).not.toContain("old completed");
    expect(
      events
        .filter((entry) => entry.kind === "message")
        .map((entry) => entry.message.type),
    ).toEqual([
      "user_input",
      "thinking_delta",
      "assistant",
      "tool_result",
      "assistant",
    ]);
    expect(JSON.stringify(events)).toContain("current request");
    expect(JSON.stringify(events)).toContain("current reasoning");
    expect(JSON.stringify(events)).toContain("git status");
    expect(JSON.stringify(events)).toContain("clean");
    expect(JSON.stringify(events)).toContain("current answer");
    monitor.close();
  });

  it("marks response-only tail activity as inferred rather than lifecycle running", async () => {
    const path = await rollout([
      event(
        "response_item",
        {
          type: "message",
          id: "orphan-answer",
          role: "assistant",
          content: [{ type: "output_text", text: "tail activity" }],
        },
        "2020-01-01T00:00:00.000Z",
      ),
    ]);

    await expect(
      inspectCodexRolloutSnapshot({
        threadId: "thread-response-only",
        path,
        seedBytes: 64 * 1024,
      }),
    ).resolves.toEqual({
      state: "running",
      observedAt: "2020-01-01T00:00:00.000Z",
      runningEvidence: "activity",
    });
  });

  it("backs off idle fallback polling without slowing active turns", async () => {
    vi.useFakeTimers();
    const activePath = await rollout([
      event("event_msg", { type: "task_started", turn_id: "turn-active" }),
      event("event_msg", {
        type: "user_message",
        client_id: "desktop-active",
        message: "keep watching",
      }),
    ]);
    const idlePath = await rollout([
      event("event_msg", { type: "task_started", turn_id: "turn-idle" }),
      event("event_msg", {
        type: "user_message",
        client_id: "desktop-idle",
        message: "already finished",
      }),
      event("event_msg", { type: "task_complete", turn_id: "turn-idle" }),
    ]);
    const active = new CodexRolloutMonitor({
      threadId: "thread-active",
      path: activePath,
      getLocalActiveTurnId: () => undefined,
      consumeLocalClientMessageId: () => false,
      onEvent: () => {},
    });
    const idle = new CodexRolloutMonitor({
      threadId: "thread-idle",
      path: idlePath,
      getLocalActiveTurnId: () => undefined,
      consumeLocalClientMessageId: () => false,
      onEvent: () => {},
    });
    await active.start();
    await idle.start();
    expect(active.snapshot.state).toBe("running");
    expect(idle.snapshot.state).toBe("idle");
    const activeRefresh = vi.spyOn(active, "refreshNow");
    const idleRefresh = vi.spyOn(idle, "refreshNow");

    await vi.advanceTimersByTimeAsync(749);
    expect(activeRefresh).not.toHaveBeenCalled();
    expect(idleRefresh).not.toHaveBeenCalled();

    await vi.advanceTimersByTimeAsync(1);
    expect(activeRefresh).toHaveBeenCalledTimes(1);
    expect(idleRefresh).not.toHaveBeenCalled();
    active.close();

    await vi.advanceTimersByTimeAsync(9_250);
    expect(idleRefresh).toHaveBeenCalledTimes(1);
    idle.close();
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
      getLocalActiveTurnId: () => "turn-local",
      consumeLocalClientMessageId: () => false,
      onEvent: (entry) => events.push(entry),
    });

    await monitor.start();

    expect(monitor.snapshot).toEqual({ state: "idle" });
    expect(monitor.hasExternalTurn).toBe(false);
    expect(events).toEqual([]);
    monitor.close();
  });

  it("keeps a delayed local turn unpublished and unsteerable while unknown", async () => {
    vi.useFakeTimers();
    const path = await rollout();
    const events: CodexDesktopContinuityMonitorEvent[] = [];
    let localTurnId: string | undefined;
    const monitor = new CodexRolloutMonitor({
      threadId: "thread-delayed-local",
      path,
      getLocalActiveTurnId: () => localTurnId,
      consumeLocalClientMessageId: () => false,
      onEvent: (entry) => events.push(entry),
    });
    await monitor.start();
    await appendEntries(path, [
      event("event_msg", {
        type: "task_started",
        turn_id: "turn-delayed-local",
      }),
    ]);
    await monitor.refreshNow();

    expect(monitor.snapshot).toEqual({ state: "unknown" });
    expect(monitor.hasExternalTurn).toBe(false);
    expect(monitor.hasBlockingExternalActivity).toBe(true);
    expect(monitor.externalTurnIdForSteering).toBeUndefined();
    expect(events).toEqual([]);

    localTurnId = "turn-delayed-local";
    await vi.advanceTimersByTimeAsync(100);
    expect(monitor.snapshot).toEqual({ state: "idle" });
    expect(monitor.hasBlockingExternalActivity).toBe(false);
    expect(events).toEqual([]);
    monitor.close();
  });

  it("streams Desktop user, reasoning, assistant, tool, and terminal items", async () => {
    const path = await rollout();
    const events: CodexDesktopContinuityMonitorEvent[] = [];
    const monitor = new CodexRolloutMonitor({
      threadId: "thread-1",
      path,
      getLocalActiveTurnId: () => undefined,
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
        type: "function_call",
        call_id: "call-skill",
        name: "exec_command",
        arguments: JSON.stringify({
          cmd: "sed -n '1,200p' /Users/test/.codex/skills/chronicle/SKILL.md",
        }),
      }),
      event("response_item", {
        type: "function_call_output",
        call_id: "call-skill",
        output: "# Chronicle",
      }),
      event("response_item", {
        type: "function_call",
        call_id: "call-spawn",
        name: "spawn_agent",
        arguments: JSON.stringify({
          task_name: "reviewer",
          message: "Review the change",
        }),
      }),
      event("response_item", {
        type: "function_call_output",
        call_id: "call-spawn",
        output: '{"agent_id":"agent-1"}',
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
            toolName: "Bash",
          },
        }),
        expect.objectContaining({
          kind: "message",
          itemKey: "tool-result:call-skill",
          message: {
            type: "tool_result",
            toolUseId: "call-skill",
            content: "# Chronicle",
            toolName: "ReadSkill",
          },
        }),
        expect.objectContaining({
          kind: "message",
          itemKey: "tool-result:call-spawn",
          message: {
            type: "tool_result",
            toolUseId: "call-spawn",
            content: '{"agent_id":"agent-1"}',
            toolName: "SpawnAgent",
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
            (content) => content.type === "text" && content.text === "Working",
          ),
      ),
    ).toHaveLength(1);
    expect(monitor.hasExternalTurn).toBe(false);
    monitor.close();
  });

  it("keeps a live view_image result structured for Bridge registration", async () => {
    const path = await rollout();
    const events: CodexDesktopContinuityMonitorEvent[] = [];
    const monitor = new CodexRolloutMonitor({
      threadId: "thread-image",
      path,
      getLocalActiveTurnId: () => undefined,
      consumeLocalClientMessageId: () => false,
      onEvent: (entry) => events.push(entry),
    });
    await monitor.start();
    await appendEntries(path, [
      event("event_msg", { type: "task_started", turn_id: "turn-image" }),
      event("event_msg", {
        type: "user_message",
        client_id: "desktop-image",
        message: "show the screenshot",
      }),
      event("response_item", {
        type: "function_call",
        call_id: "call-image",
        name: "view_image",
        arguments: JSON.stringify({
          path: "/tmp/referenced screenshot.png",
          detail: "high",
        }),
      }),
      event("response_item", {
        type: "function_call_output",
        call_id: "call-image",
        output: [
          {
            type: "input_image",
            detail: "high",
            image_url: "data:image/png;base64,aGVsbG8=",
          },
        ],
      }),
    ]);
    await monitor.refreshNow();

    expect(events).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          kind: "message",
          itemKey: "tool-result:call-image",
          message: expect.objectContaining({
            type: "tool_result",
            toolUseId: "call-image",
            toolName: "ViewImage",
            content: "Viewed image",
          }),
          imageBase64: [{ data: "aGVsbG8=", mimeType: "image/png" }],
        }),
      ]),
    );
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
      getLocalActiveTurnId: () => undefined,
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

  it("streams every tool schema supported by canonical Codex history", async () => {
    const path = await rollout();
    const events: CodexDesktopContinuityMonitorEvent[] = [];
    const monitor = new CodexRolloutMonitor({
      threadId: "thread-tool-parity",
      path,
      getLocalActiveTurnId: () => undefined,
      consumeLocalClientMessageId: () => false,
      onEvent: (entry) => events.push(entry),
    });
    await monitor.start();
    await appendEntries(path, [
      event("event_msg", { type: "task_started", turn_id: "turn-tools" }),
      event("event_msg", {
        type: "user_message",
        turn_id: "turn-tools",
        client_id: "desktop-tools",
        message: "exercise every tool schema",
      }),
      event("response_item", {
        type: "web_search_call",
        call_id: "web-1",
        action: { type: "search", query: "CC Pocket" },
      }),
      event("response_item", {
        type: "web_search",
        query: "legacy search without id",
      }),
      event("response_item", {
        type: "image_generation_call",
        id: "image-1",
        prompt: "orange bridge",
      }),
      event("response_item", {
        type: "image_generation_call",
        id: "image-inline",
        status: "completed",
        revised_prompt: "inline orange bridge",
        result: "data:image/png;base64,aW1hZ2U=",
      }),
      event("response_item", {
        type: "command_execution",
        id: "command-item-1",
        call_id: "command-call-1",
        command: "git status",
        output: "",
        exit_code: 17,
      }),
      event("response_item", {
        type: "command_execution",
        id: "command-start-only",
        command: "long-running-task",
      }),
      event("response_item", {
        type: "mcp_tool_call",
        id: "mcp-item-1",
        call_id: "mcp-call-1",
        server: "computer-use",
        tool: "get_app_state",
        arguments: { app: "Simulator" },
      }),
      event("response_item", {
        type: "mcp_tool_call",
        id: "mcp-error-item",
        call_id: "mcp-error-call",
        server: "computer-use",
        tool: "get_app_state",
        arguments: { app: "Missing" },
      }),
      event("response_item", {
        type: "file_change",
        id: "file-item-1",
        call_id: "file-call-1",
        changes: [{ path: "lib/main.dart", kind: "update" }],
      }),
      event("event_msg", {
        type: "mcp_tool_call_end",
        call_id: "mcp-late-call",
        invocation: {
          server: "computer-use",
          tool: "get_app_state",
          arguments: { app: "Late" },
        },
        result: { Ok: { content: [{ type: "text", text: "late ready" }] } },
      }),
      event("response_item", {
        type: "mcp_tool_call",
        id: "mcp-late-item",
        call_id: "mcp-late-call",
        server: "computer-use",
        tool: "get_app_state",
        arguments: { app: "Late" },
      }),
      event("event_msg", {
        type: "mcp_tool_call_end",
        call_id: "mcp-call-1",
        invocation: {
          server: "computer-use",
          tool: "get_app_state",
          arguments: { app: "Simulator" },
        },
        result: {
          Ok: {
            content: [
              { type: "text", text: "ready" },
              {
                type: "image",
                data: "data:image/png;base64,c2NyZWVuc2hvdA==",
                mimeType: "image/png",
              },
            ],
          },
        },
      }),
      event("event_msg", {
        type: "mcp_tool_call_end",
        call_id: "mcp-error-call",
        invocation: {
          server: "computer-use",
          tool: "get_app_state",
          arguments: { app: "Missing" },
        },
        result: { Err: "simulator unavailable" },
      }),
      event("event_msg", {
        type: "patch_apply_end",
        call_id: "file-call-1",
        success: true,
        stdout: "updated",
      }),
      event("event_msg", {
        type: "web_search_end",
        call_id: "web-1",
        query: "CC Pocket",
        results: [{ title: "CC Pocket" }],
      }),
      event("event_msg", {
        type: "image_generation_end",
        call_id: "image-late-call",
        prompt: "late orange bridge",
        saved_path: "/tmp/late-bridge.png",
        status: "completed",
      }),
      event("response_item", {
        type: "image_generation_call",
        id: "image-late-item",
        call_id: "image-late-call",
        prompt: "late orange bridge",
        result: "data:image/png;base64,bGF0ZQ==",
      }),
      event("event_msg", { type: "task_complete", turn_id: "turn-tools" }),
    ]);

    await monitor.refreshNow();

    const toolStarts = events
      .filter(
        (
          entry,
        ): entry is Extract<
          CodexDesktopContinuityMonitorEvent,
          { kind: "message" }
        > =>
          entry.kind === "message" && entry.itemKey.startsWith("tool-start:"),
      )
      .map((entry) => {
        const message = entry.message;
        if (message.type !== "assistant") return null;
        const tool = message.message.content.find(
          (content) => content.type === "tool_use",
        );
        return tool?.type === "tool_use" ? [tool.id, tool.name] : null;
      })
      .filter((entry): entry is string[] => entry !== null);
    expect(toolStarts).toEqual(
      expect.arrayContaining([
        ["web-1", "WebSearch"],
        ["image-1", "ImageGeneration"],
        ["command-item-1", "Bash"],
        ["command-start-only", "Bash"],
        ["mcp-item-1", "mcp:computer-use/get_app_state"],
        ["mcp-error-item", "mcp:computer-use/get_app_state"],
        ["mcp-late-item", "mcp:computer-use/get_app_state"],
        ["file-item-1", "FileChange"],
        ["image-late-call", "ImageGeneration"],
      ]),
    );
    expect(toolStarts.filter(([id]) => id === "mcp-item-1")).toHaveLength(1);
    expect(toolStarts.filter(([id]) => id === "file-item-1")).toHaveLength(1);
    expect(toolStarts.filter(([id]) => id === "image-late-call")).toHaveLength(
      1,
    );
    expect(toolStarts.filter(([id]) => id === "image-late-item")).toHaveLength(
      0,
    );
    expect(toolStarts.filter(([id]) => id === "mcp-late-item")).toHaveLength(1);
    expect(toolStarts.filter(([id]) => id === "mcp-late-call")).toHaveLength(0);
    const legacySearchStarts = events.filter((entry) => {
      if (entry.kind !== "message" || entry.message.type !== "assistant") {
        return false;
      }
      return entry.message.message.content.some(
        (content) =>
          content.type === "tool_use" &&
          content.name === "WebSearch" &&
          content.input.query === "legacy search without id",
      );
    });
    expect(legacySearchStarts).toHaveLength(1);

    const toolResults = events
      .filter(
        (
          entry,
        ): entry is Extract<
          CodexDesktopContinuityMonitorEvent,
          { kind: "message" }
        > & { message: Extract<ServerMessage, { type: "tool_result" }> } =>
          entry.kind === "message" && entry.message.type === "tool_result",
      )
      .map((entry) => entry.message);
    const resultIds = toolResults.map((message) => message.toolUseId);
    expect(resultIds).toEqual(
      expect.arrayContaining([
        "command-item-1",
        "mcp-item-1",
        "mcp-error-item",
        "mcp-late-item",
        "file-item-1",
        "web-1",
        "image-inline",
        "image-late-call",
      ]),
    );
    expect(resultIds).not.toContain("command-start-only");
    expect(
      toolResults.find((message) => message.toolUseId === "command-item-1")
        ?.content,
    ).toBe("exit code: 17");
    const inlineImage = toolResults.find(
      (message) => message.toolUseId === "image-inline",
    );
    expect(inlineImage?.content).toContain("Generated 1 image");
    expect(inlineImage?.content).not.toContain("aW1hZ2U=");
    expect(JSON.stringify(inlineImage)).not.toContain("aW1hZ2U=");
    const mcpResult = toolResults.find(
      (message) => message.toolUseId === "mcp-item-1",
    );
    expect(mcpResult?.content).toBe("ready");
    expect(mcpResult?.content).not.toContain("c2NyZWVuc2hvdA==");
    expect(JSON.stringify(mcpResult)).not.toContain("c2NyZWVuc2hvdA==");
    expect(
      toolResults.find((message) => message.toolUseId === "mcp-error-item")
        ?.content,
    ).toBe("simulator unavailable");
    expect(
      toolResults.find((message) => message.toolUseId === "image-late-call")
        ?.content,
    ).toContain("savedPath: /tmp/late-bridge.png");
    expect(
      toolResults.find((message) => message.toolUseId === "mcp-late-item")
        ?.content,
    ).toBe("late ready");
    monitor.close();
  });

  it("tracks overlapping live turns by id through out-of-order terminals", async () => {
    const path = await rollout();
    const events: CodexDesktopContinuityMonitorEvent[] = [];
    const monitor = new CodexRolloutMonitor({
      threadId: "thread-1",
      path,
      getLocalActiveTurnId: () => undefined,
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
      events.some((entry) => entry.kind === "state" && entry.state === "idle"),
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

  it("suppresses unscoped deltas while multiple turns are active", async () => {
    const path = await rollout();
    const events: CodexDesktopContinuityMonitorEvent[] = [];
    const monitor = new CodexRolloutMonitor({
      threadId: "thread-1",
      path,
      getLocalActiveTurnId: () => undefined,
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
      event("event_msg", { type: "agent_reasoning", text: "ambiguous" }),
      event("event_msg", {
        type: "agent_message",
        phase: "commentary",
        message: "ambiguous assistant",
      }),
      event("response_item", {
        type: "function_call",
        call_id: "ambiguous-tool",
        name: "exec",
        arguments: "{}",
      }),
      event("event_msg", {
        type: "agent_reasoning",
        turn_id: "turn-a",
        text: "scoped A",
      }),
      event("response_item", {
        type: "function_call",
        call_id: "metadata-tool-b",
        name: "exec",
        arguments: '{"command":"pwd"}',
        internal_chat_message_metadata_passthrough: { turn_id: "turn-b" },
      }),
      event("response_item", {
        type: "function_call_output",
        call_id: "metadata-tool-b",
        output: "/project",
        internal_chat_message_metadata_passthrough: { turn_id: "turn-b" },
      }),
      event("response_item", {
        type: "message",
        role: "assistant",
        id: "metadata-assistant-b",
        phase: "commentary",
        content: [{ type: "output_text", text: "scoped B" }],
        internal_chat_message_metadata_passthrough: { turn_id: "turn-b" },
      }),
    ]);

    await monitor.refreshNow();

    expect(JSON.stringify(events)).not.toContain("ambiguous assistant");
    expect(JSON.stringify(events)).not.toContain("ambiguous-tool");
    expect(JSON.stringify(events)).not.toContain('"text":"ambiguous\\n"');
    expect(events).toContainEqual(
      expect.objectContaining({
        kind: "message",
        turnId: "turn-a",
        message: { type: "thinking_delta", text: "scoped A\n" },
      }),
    );
    expect(events).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          kind: "message",
          turnId: "turn-b",
          message: expect.objectContaining({ type: "assistant" }),
        }),
        expect.objectContaining({
          kind: "message",
          turnId: "turn-b",
          message: expect.objectContaining({
            type: "tool_result",
            toolUseId: "metadata-tool-b",
          }),
        }),
      ]),
    );
    expect(JSON.stringify(events)).toContain("scoped B");
    monitor.close();
  });

  it("retires a stale Desktop predecessor before streaming a newer turn", async () => {
    const path = await rollout();
    const events: CodexDesktopContinuityMonitorEvent[] = [];
    const monitor = new CodexRolloutMonitor({
      threadId: "thread-stale-desktop",
      path,
      getLocalActiveTurnId: () => undefined,
      consumeLocalClientMessageId: () => false,
      onEvent: (entry) => events.push(entry),
      assistantMessagePairMs: 1,
    });
    await monitor.start();
    await appendEntries(path, [
      event(
        "event_msg",
        { type: "task_started", turn_id: "desktop-orphan" },
        "2026-07-19T12:00:00Z",
      ),
      event(
        "event_msg",
        {
          type: "user_message",
          client_id: "desktop-orphan-user",
          message: "orphaned work",
        },
        "2026-07-19T12:00:01Z",
      ),
      event(
        "event_msg",
        {
          type: "agent_message",
          turn_id: "desktop-orphan",
          phase: "commentary",
          message: "late orphan assistant",
        },
        "2026-07-19T12:09:58Z",
      ),
      event(
        "event_msg",
        {
          type: "web_search_end",
          turn_id: "desktop-orphan",
          call_id: "late-orphan-tool",
          query: "late orphan search",
        },
        "2026-07-19T12:09:59Z",
      ),
      event(
        "event_msg",
        { type: "task_started", turn_id: "desktop-current" },
        "2026-07-19T12:10:00Z",
      ),
      event(
        "event_msg",
        {
          type: "user_message",
          client_id: "desktop-current-user",
          message: "current work",
        },
        "2026-07-19T12:10:01Z",
      ),
      event(
        "event_msg",
        { type: "agent_reasoning", text: "current reasoning" },
        "2026-07-19T12:10:02Z",
      ),
      event(
        "response_item",
        {
          type: "message",
          id: "current-answer",
          role: "assistant",
          content: [{ type: "output_text", text: "current answer" }],
        },
        "2026-07-19T12:10:03Z",
      ),
      event(
        "response_item",
        {
          type: "function_call",
          call_id: "current-tool",
          name: "exec_command",
          arguments: "{}",
        },
        "2026-07-19T12:10:04Z",
      ),
    ]);

    await monitor.refreshNow();
    await new Promise((resolve) => setTimeout(resolve, 5));

    expect(monitor.snapshot).toEqual({
      state: "running",
      turnId: "desktop-current",
    });
    expect(monitor.externalTurnIdForSteering).toBe("desktop-current");
    expect(JSON.stringify(events)).toContain("current reasoning");
    expect(JSON.stringify(events)).toContain("current answer");
    expect(JSON.stringify(events)).toContain("current-tool");
    expect(JSON.stringify(events)).not.toContain("late orphan assistant");
    expect(JSON.stringify(events)).not.toContain("late-orphan-tool");

    await appendEntries(path, [
      event("event_msg", {
        type: "task_complete",
        turn_id: "desktop-orphan",
      }),
    ]);
    await monitor.refreshNow();
    expect(monitor.snapshot).toEqual({
      state: "running",
      turnId: "desktop-current",
    });
    monitor.close();
  });

  it("uses response metadata to retire an orphan when user_message is absent", async () => {
    const path = await rollout();
    const events: CodexDesktopContinuityMonitorEvent[] = [];
    const monitor = new CodexRolloutMonitor({
      threadId: "thread-metadata-repair",
      path,
      getLocalActiveTurnId: () => undefined,
      consumeLocalClientMessageId: () => false,
      onEvent: (entry) => events.push(entry),
    });
    await monitor.start();
    await appendEntries(path, [
      event(
        "event_msg",
        { type: "task_started", turn_id: "desktop-orphan" },
        "2026-07-19T12:00:00Z",
      ),
      event(
        "event_msg",
        { type: "task_started", turn_id: "desktop-current" },
        "2026-07-19T12:10:00Z",
      ),
    ]);
    await monitor.refreshNow();
    await new Promise((resolve) => setTimeout(resolve, 120));

    expect(monitor.externalTurnIdForSteering).toBeUndefined();
    await appendEntries(path, [
      event(
        "response_item",
        {
          type: "function_call",
          call_id: "metadata-current-tool",
          name: "exec_command",
          arguments: "{}",
          internal_chat_message_metadata_passthrough: {
            turn_id: "desktop-current",
          },
        },
        "2026-07-19T12:10:01Z",
      ),
    ]);
    await monitor.refreshNow();

    expect(monitor.snapshot).toEqual({
      state: "running",
      turnId: "desktop-current",
    });
    expect(monitor.externalTurnIdForSteering).toBe("desktop-current");
    expect(JSON.stringify(events)).toContain("metadata-current-tool");

    await appendEntries(path, [
      event("event_msg", {
        type: "task_complete",
        turn_id: "desktop-current",
      }),
    ]);
    await monitor.refreshNow();
    expect(monitor.snapshot.state).toBe("idle");
    expect(events.at(-1)).toMatchObject({
      kind: "state",
      state: "idle",
      turnId: "desktop-current",
    });
    monitor.close();
  });

  it("repairs metadata-scoped orphaned turns while seeding", async () => {
    const path = await rollout([
      event(
        "event_msg",
        { type: "task_started", turn_id: "desktop-seed-orphan-metadata" },
        "2026-07-19T12:00:00Z",
      ),
      event(
        "event_msg",
        { type: "task_started", turn_id: "desktop-seed-current-metadata" },
        "2026-07-19T12:10:00Z",
      ),
      event(
        "response_item",
        {
          type: "function_call",
          call_id: "metadata-seed-tool",
          name: "exec_command",
          arguments: "{}",
          internal_chat_message_metadata_passthrough: {
            turn_id: "desktop-seed-current-metadata",
          },
        },
        "2026-07-19T12:10:01Z",
      ),
      event(
        "event_msg",
        {
          type: "task_complete",
          turn_id: "desktop-seed-current-metadata",
        },
        "2026-07-19T12:10:02Z",
      ),
    ]);
    const events: CodexDesktopContinuityMonitorEvent[] = [];
    const monitor = new CodexRolloutMonitor({
      threadId: "thread-seed-metadata-repair",
      path,
      getLocalActiveTurnId: () => undefined,
      consumeLocalClientMessageId: () => false,
      onEvent: (entry) => events.push(entry),
    });

    await monitor.start();

    expect(monitor.snapshot).toEqual({
      state: "idle",
      turnId: "desktop-seed-current-metadata",
    });
    expect(monitor.externalTurnIdForSteering).toBeUndefined();
    expect(events).toEqual([]);
    monitor.close();
  });

  it("repairs a stale Desktop predecessor while seeding history", async () => {
    const path = await rollout([
      event(
        "event_msg",
        { type: "task_started", turn_id: "desktop-seed-orphan" },
        "2026-07-19T12:00:00Z",
      ),
      event(
        "event_msg",
        {
          type: "user_message",
          client_id: "desktop-seed-orphan-user",
          message: "old work",
        },
        "2026-07-19T12:00:01Z",
      ),
      event(
        "event_msg",
        { type: "task_started", turn_id: "desktop-seed-current" },
        "2026-07-19T12:10:00Z",
      ),
      event(
        "event_msg",
        {
          type: "user_message",
          client_id: "desktop-seed-current-user",
          message: "new work",
        },
        "2026-07-19T12:10:01Z",
      ),
    ]);
    const events: CodexDesktopContinuityMonitorEvent[] = [];
    const monitor = new CodexRolloutMonitor({
      threadId: "thread-seed-stale-desktop",
      path,
      getLocalActiveTurnId: () => undefined,
      consumeLocalClientMessageId: () => false,
      onEvent: (entry) => events.push(entry),
    });

    await monitor.start();

    expect(monitor.snapshot).toEqual({
      state: "running",
      turnId: "desktop-seed-current",
    });
    expect(monitor.externalTurnIdForSteering).toBe("desktop-seed-current");
    expect(events).toEqual([]);

    await appendEntries(path, [
      event("event_msg", {
        type: "agent_reasoning",
        text: "seed repaired",
      }),
    ]);
    await monitor.refreshNow();
    expect(JSON.stringify(events)).toContain("seed repaired");
    monitor.close();
  });

  it("ignores a late stale terminal instead of completing an anonymous current turn", async () => {
    const path = await rollout();
    const monitor = new CodexRolloutMonitor({
      threadId: "thread-stale-late-terminal",
      path,
      getLocalActiveTurnId: () => undefined,
      consumeLocalClientMessageId: () => false,
      onEvent: () => {},
    });
    await monitor.start();
    await appendEntries(path, [
      event(
        "event_msg",
        { type: "task_started", turn_id: "desktop-stale-id" },
        "2026-07-19T12:00:00Z",
      ),
      event(
        "event_msg",
        {
          type: "user_message",
          client_id: "desktop-stale-user",
          message: "old work",
        },
        "2026-07-19T12:00:01Z",
      ),
      event("event_msg", { type: "task_started" }, "2026-07-19T12:10:00Z"),
      event(
        "event_msg",
        {
          type: "user_message",
          client_id: "desktop-anonymous-current-user",
          message: "new anonymous work",
        },
        "2026-07-19T12:10:01Z",
      ),
    ]);
    await monitor.refreshNow();
    expect(monitor.snapshot).toEqual({ state: "running" });
    expect((monitor as any).activeTurns.size).toBe(1);

    await appendEntries(path, [
      event("event_msg", {
        type: "task_complete",
        turn_id: "desktop-stale-id",
      }),
    ]);
    await monitor.refreshNow();

    expect(monitor.snapshot).toEqual({ state: "running" });
    expect((monitor as any).activeTurns.size).toBe(1);
    monitor.close();
  });

  it("keeps an exact local overlap while retiring only the stale Desktop turn", async () => {
    const path = await rollout();
    const events: CodexDesktopContinuityMonitorEvent[] = [];
    const monitor = new CodexRolloutMonitor({
      threadId: "thread-stale-plus-local",
      path,
      getLocalActiveTurnId: () => "local-active",
      consumeLocalClientMessageId: (id) => id === "local-user",
      onEvent: (entry) => events.push(entry),
    });
    await monitor.start();
    await appendEntries(path, [
      event(
        "event_msg",
        { type: "task_started", turn_id: "desktop-old" },
        "2026-07-19T12:00:00Z",
      ),
      event(
        "event_msg",
        {
          type: "user_message",
          client_id: "desktop-old-user",
          message: "old Desktop work",
        },
        "2026-07-19T12:00:01Z",
      ),
      event(
        "event_msg",
        { type: "task_started", turn_id: "local-active" },
        "2026-07-19T12:09:00Z",
      ),
      event(
        "event_msg",
        {
          type: "user_message",
          client_id: "local-user",
          message: "phone work",
        },
        "2026-07-19T12:09:01Z",
      ),
      event(
        "event_msg",
        { type: "task_started", turn_id: "desktop-new" },
        "2026-07-19T12:10:00Z",
      ),
      event(
        "event_msg",
        {
          type: "user_message",
          client_id: "desktop-new-user",
          message: "new Desktop work",
        },
        "2026-07-19T12:10:01Z",
      ),
      event("event_msg", {
        type: "agent_reasoning",
        text: "still ambiguous with phone",
      }),
    ]);

    await monitor.refreshNow();

    expect(monitor.externalTurnIdForSteering).toBe("desktop-new");
    expect((monitor as any).activeTurns.has("turn:desktop-old")).toBe(false);
    expect((monitor as any).activeTurns.has("turn:local-active")).toBe(true);
    expect((monitor as any).activeTurns.has("turn:desktop-new")).toBe(true);
    expect(JSON.stringify(events)).not.toContain("still ambiguous with phone");
    monitor.close();
  });

  it("does not let a local guide id rewrite a Desktop-owned turn", async () => {
    const path = await rollout();
    const events: CodexDesktopContinuityMonitorEvent[] = [];
    const monitor = new CodexRolloutMonitor({
      threadId: "thread-1",
      path,
      getLocalActiveTurnId: () => undefined,
      consumeLocalClientMessageId: (id) => id === "mobile-guide",
      onEvent: (entry) => events.push(entry),
    });
    await monitor.start();
    await appendEntries(path, [
      event("event_msg", { type: "task_started", turn_id: "desktop-turn" }),
      event("event_msg", {
        type: "user_message",
        client_id: "desktop-user",
        message: "Desktop owns this",
      }),
      event("event_msg", {
        type: "user_message",
        client_id: "mobile-guide",
        message: "guide echo",
      }),
      event("event_msg", { type: "agent_reasoning", text: "still desktop" }),
    ]);

    await monitor.refreshNow();

    expect(monitor.hasExternalTurn).toBe(true);
    expect(JSON.stringify(events)).not.toContain("guide echo");
    expect(events).toContainEqual(
      expect.objectContaining({
        kind: "message",
        turnId: "desktop-turn",
        message: { type: "thinking_delta", text: "still desktop\n" },
      }),
    );
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
      getLocalActiveTurnId: () => undefined,
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

  it("does not deduplicate repeated user assistant and tool ids across provider turns", async () => {
    const path = await rollout();
    const events: CodexDesktopContinuityMonitorEvent[] = [];
    const monitor = new CodexRolloutMonitor({
      threadId: "thread-repeated-provider-ids",
      path,
      getLocalActiveTurnId: () => undefined,
      consumeLocalClientMessageId: () => false,
      onEvent: (entry) => events.push(entry),
    });
    await monitor.start();

    for (const [index, turnId] of [
      "provider-turn-one",
      "provider-turn-two",
    ].entries()) {
      const timestamp = `2026-07-19T12:0${index}:00Z`;
      await appendEntries(path, [
        event(
          "event_msg",
          { type: "task_started", turn_id: turnId },
          timestamp,
        ),
        event(
          "event_msg",
          {
            type: "user_message",
            client_id: "reused-client-message",
            message: `request ${turnId}`,
          },
          timestamp,
        ),
        event(
          "response_item",
          {
            type: "function_call",
            call_id: "reused-tool",
            name: "Read",
            arguments: JSON.stringify({ file_path: `${turnId}.txt` }),
          },
          timestamp,
        ),
        event(
          "response_item",
          {
            type: "function_call_output",
            call_id: "reused-tool",
            output: `result ${turnId}`,
          },
          timestamp,
        ),
        event(
          "event_msg",
          { type: "task_complete", turn_id: turnId },
          timestamp,
        ),
      ]);
      await monitor.refreshNow();
    }

    const messages = events.filter(
      (
        entry,
      ): entry is Extract<
        CodexDesktopContinuityMonitorEvent,
        { kind: "message" }
      > => entry.kind === "message",
    );
    expect(
      messages.filter((entry) => entry.message.type === "user_input"),
    ).toHaveLength(2);
    expect(
      messages.filter(
        (entry) =>
          entry.message.type === "assistant" &&
          entry.message.message.content.some(
            (content) => content.type === "tool_use",
          ),
      ),
    ).toHaveLength(2);
    expect(
      messages.filter((entry) => entry.message.type === "tool_result"),
    ).toHaveLength(2);
    expect(new Set(messages.map((entry) => entry.turnId))).toEqual(
      new Set(["provider-turn-one", "provider-turn-two"]),
    );
    monitor.close();
  });

  it("pairs event assistant messages with canonical response ids and suppresses late duplicates", async () => {
    vi.useFakeTimers();
    const path = await rollout();
    const events: CodexDesktopContinuityMonitorEvent[] = [];
    const monitor = new CodexRolloutMonitor({
      threadId: "thread-1",
      path,
      getLocalActiveTurnId: () => undefined,
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
      (entry) => entry.kind === "message" && entry.message.type === "assistant",
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
      events.some((entry) =>
        JSON.stringify(entry).includes("must not fire after close"),
      ),
    ).toBe(false);
  });

  it("deduplicates reversed response/event ordering while preserving the real id", async () => {
    const path = await rollout();
    const events: CodexDesktopContinuityMonitorEvent[] = [];
    const monitor = new CodexRolloutMonitor({
      threadId: "thread-1",
      path,
      getLocalActiveTurnId: () => undefined,
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
      (entry) => entry.kind === "message" && entry.message.type === "assistant",
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
      getLocalActiveTurnId: () => undefined,
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
      getLocalActiveTurnId: () => undefined,
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
                saved_path: "/Users/test/.codex/generated_images/output.png",
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
      getLocalActiveTurnId: () => undefined,
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
    expect(monitor.needsRehydrateSince(new Date("2026-07-19T12:00:00Z"))).toBe(
      true,
    );
    monitor.close();
  });

  it("suppresses a mobile-originated turn by client message identity", async () => {
    const path = await rollout();
    const events: CodexDesktopContinuityMonitorEvent[] = [];
    const monitor = new CodexRolloutMonitor({
      threadId: "thread-1",
      path,
      getLocalActiveTurnId: () => undefined,
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
      getLocalActiveTurnId: () => "some-other-local-turn",
      consumeLocalClientMessageId: () => false,
      onEvent: (entry) => events.push(entry),
    });
    await monitor.start();
    await appendEntries(path, [
      event("event_msg", {
        type: "task_started",
        turn_id: "some-other-local-turn",
      }),
      event("event_msg", {
        type: "task_started",
        turn_id: "desktop-during-local",
      }),
      event("event_msg", {
        type: "user_message",
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
      getLocalActiveTurnId: () => undefined,
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
      getLocalActiveTurnId: () => undefined,
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
  it("replaces live view_image base64 with an opaque ImageRef", async () => {
    const path = await rollout();
    const client = {};
    const sent: any[] = [];
    const registerInlineImages = vi.fn(() => [
      {
        id: "image-ref-1",
        url: "/images/image-ref-1",
        mimeType: "image/png",
      },
    ]);
    const session = {
      id: "runtime-image",
      provider: "codex",
      projectPath: "/project",
      process: { isWaitingForInput: true },
    };
    const runtime: LocalFeatureRuntime = {
      getSession: () => session,
      getCodexThreadId: () => "thread-image",
      getActiveCodexProcess: () => null,
      createStandaloneCodexProcess: async () => {
        throw new Error("not used");
      },
      registerInlineImages,
      send: (_client, message) => sent.push(message),
      supports: (_client, type) => type === "codex_desktop_continuity_event_v1",
    };
    const handler = new CodexDesktopContinuityHandler(runtime, {
      resolveRolloutPath: async () => path,
    });
    await handler.handle(
      {
        type: "codex_desktop_continuity_watch",
        protocolVersion: 1,
        requestId: "watch-image",
        sessionId: session.id,
        threadId: "thread-image",
        projectPath: "/project",
      },
      { client, signal: new AbortController().signal, runtime },
    );
    await appendEntries(path, [
      event("event_msg", { type: "task_started", turn_id: "turn-image" }),
      event("event_msg", {
        type: "user_message",
        client_id: "desktop-image",
        message: "show it",
      }),
      event("response_item", {
        type: "function_call",
        call_id: "call-image",
        name: "view_image",
        arguments: '{"path":"/project/screenshot.png"}',
      }),
      event("response_item", {
        type: "function_call_output",
        call_id: "call-image",
        output: [
          {
            type: "input_image",
            image_url: "data:image/png;base64,aGVsbG8=",
          },
        ],
      }),
    ]);
    await (handler as any).monitors.get("thread-image").refreshNow();

    expect(registerInlineImages).toHaveBeenCalledWith([
      { data: "aGVsbG8=", mimeType: "image/png" },
    ]);
    expect(sent).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          event: "message",
          itemKey: "tool-result:call-image",
          message: expect.objectContaining({
            type: "tool_result",
            toolName: "ViewImage",
            images: [
              {
                id: "image-ref-1",
                url: "/images/image-ref-1",
                mimeType: "image/png",
              },
            ],
          }),
        }),
      ]),
    );
    expect(JSON.stringify(sent)).not.toContain("aGVsbG8=");
    handler.close();
  });

  it("isolates same-Bridge watchers per client while sharing one rollout monitor", async () => {
    const path = await rollout();
    const sentByClient = new Map<object, any[]>();
    const session = {
      id: "runtime-multi-client",
      provider: "codex",
      projectPath: "/project",
      process: { isWaitingForInput: true },
    };
    const runtime: LocalFeatureRuntime = {
      bridgeInstanceId: "bridge-multi-client",
      getSession: (id) => (id === session.id ? session : undefined),
      getCodexThreadId: () => "thread-multi-client",
      getActiveCodexProcess: () => null,
      createStandaloneCodexProcess: async () => {
        throw new Error("not used");
      },
      send: (client, message) => {
        const sent = sentByClient.get(client) ?? [];
        sent.push(message);
        sentByClient.set(client, sent);
      },
      supports: (_client, type) => type === "codex_desktop_continuity_event_v1",
    };
    const handler = new CodexDesktopContinuityHandler(runtime, {
      resolveRolloutPath: async () => path,
    });
    const client1 = {};
    const client2 = {};
    const watch = (client: object, requestId: string) =>
      handler.handle(
        {
          type: "codex_desktop_continuity_watch",
          protocolVersion: 1,
          requestId,
          sessionId: session.id,
          threadId: "thread-multi-client",
          projectPath: "/project",
        },
        { client, signal: new AbortController().signal, runtime },
      );

    await watch(client1, "watch-client-1");
    await watch(client2, "watch-client-2");
    expect((handler as any).monitors.size).toBe(1);
    expect(
      (handler as any).monitors.get("thread-multi-client")?.watcherCount,
    ).toBe(2);

    await appendEntries(path, [
      event("event_msg", {
        type: "task_started",
        turn_id: "turn-multi-client",
      }),
      event("event_msg", {
        type: "user_message",
        turn_id: "turn-multi-client",
        client_id: "desktop-multi-client",
        message: "stream to both phones",
      }),
      event("event_msg", {
        type: "agent_reasoning",
        turn_id: "turn-multi-client",
        text: "shared reasoning",
      }),
    ]);
    await (handler as any).monitors.get("thread-multi-client").refreshNow();

    for (const [client, requestId] of [
      [client1, "watch-client-1"],
      [client2, "watch-client-2"],
    ] as const) {
      expect(sentByClient.get(client)).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            requestId,
            event: "message",
            itemKey: "user:desktop-multi-client",
          }),
          expect.objectContaining({
            requestId,
            event: "message",
            message: { type: "thinking_delta", text: "shared reasoning\n" },
          }),
        ]),
      );
    }

    const disconnectedCount = sentByClient.get(client1)?.length ?? 0;
    handler.disconnect(client1);
    await appendEntries(path, [
      event("response_item", {
        type: "function_call",
        call_id: "call-after-disconnect",
        name: "exec_command",
        arguments: JSON.stringify({ cmd: "pwd" }),
        turn_id: "turn-multi-client",
      }),
    ]);
    await (handler as any).monitors.get("thread-multi-client").refreshNow();

    expect(sentByClient.get(client1)).toHaveLength(disconnectedCount);
    expect(sentByClient.get(client2)).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          requestId: "watch-client-2",
          event: "message",
          itemKey: "tool-start:call-after-disconnect",
        }),
      ]),
    );
    expect(
      (handler as any).monitors.get("thread-multi-client")?.watcherCount,
    ).toBe(1);

    handler.disconnect(client2);
    expect((handler as any).monitors.size).toBe(0);
    handler.close();
  });

  it("reports unknown to a watcher that joins during ownership delay", async () => {
    vi.useFakeTimers();
    const path = await rollout();
    const sentByClient = new Map<object, any[]>();
    let localTurnId: string | undefined;
    const session = {
      id: "runtime-unknown-watch",
      provider: "codex",
      projectPath: "/project",
      process: { isWaitingForInput: false },
    };
    const runtime: LocalFeatureRuntime = {
      getSession: () => session,
      getCodexThreadId: () => "thread-unknown-watch",
      getActiveCodexProcess: () => null,
      createStandaloneCodexProcess: async () => {
        throw new Error("not used");
      },
      getLocallyActiveCodexTurnId: () => localTurnId,
      send: (client, message) => {
        const sent = sentByClient.get(client) ?? [];
        sent.push(message);
        sentByClient.set(client, sent);
      },
      supports: () => true,
    };
    const handler = new CodexDesktopContinuityHandler(runtime, {
      resolveRolloutPath: async () => path,
    });
    const client1 = {};
    const client2 = {};
    const watch = (client: object, requestId: string) =>
      handler.handle(
        {
          type: "codex_desktop_continuity_watch",
          protocolVersion: 1,
          requestId,
          sessionId: session.id,
          threadId: "thread-unknown-watch",
          projectPath: "/project",
        },
        { client, signal: new AbortController().signal, runtime },
      );
    await watch(client1, "watch-before-start");
    await appendEntries(path, [
      event("event_msg", {
        type: "task_started",
        turn_id: "turn-delayed-watch",
      }),
    ]);
    await (handler as any).monitors.get("thread-unknown-watch").refreshNow();
    await watch(client2, "watch-during-delay");

    expect(sentByClient.get(client2)?.at(-1)).toMatchObject({
      event: "watching",
      requestId: "watch-during-delay",
      state: "unknown",
    });
    expect(sentByClient.get(client2)?.at(-1)).not.toHaveProperty("turnId");
    expect(handler.externalCodexTurnId(session)).toBeUndefined();
    expect(handler.hasExternalCodexActivity(session)).toBe(true);

    localTurnId = "turn-delayed-watch";
    await vi.advanceTimersByTimeAsync(100);
    expect(
      sentByClient.get(client2)?.some((message) => message.event === "state"),
    ).toBe(false);
    handler.close();
  });

  it("drops an aborted watch and closes its unused monitor", async () => {
    const path = await rollout();
    const client = {};
    const sent: unknown[] = [];
    let releasePath!: (path: string) => void;
    const pathGate = new Promise<string>((resolve) => {
      releasePath = resolve;
    });
    const resolveRolloutPath = vi.fn(() => pathGate);
    const session = {
      id: "runtime-aborted-watch",
      provider: "codex",
      projectPath: "/project",
      process: { isWaitingForInput: true },
    };
    const runtime: LocalFeatureRuntime = {
      getSession: () => session,
      getCodexThreadId: () => "thread-aborted-watch",
      getActiveCodexProcess: () => null,
      createStandaloneCodexProcess: async () => {
        throw new Error("not used");
      },
      send: (_client, message) => sent.push(message),
      supports: () => true,
    };
    const handler = new CodexDesktopContinuityHandler(runtime, {
      resolveRolloutPath,
    });
    const controller = new AbortController();
    const handling = handler.handle(
      {
        type: "codex_desktop_continuity_watch",
        protocolVersion: 1,
        requestId: "watch-aborted",
        sessionId: session.id,
        threadId: "thread-aborted-watch",
        projectPath: "/project",
      },
      { client, signal: controller.signal, runtime },
    );
    await vi.waitFor(() => expect(resolveRolloutPath).toHaveBeenCalledOnce());
    controller.abort();
    releasePath(path);
    await handling;

    expect(sent).toEqual([]);
    expect((handler as any).watchersByClient.size).toBe(0);
    expect((handler as any).monitors.size).toBe(0);
    handler.close();
  });

  it("uses watch intent CAS across delayed watch, unwatch, and supersede", async () => {
    const path = await rollout();
    const client = {};
    const sent: any[] = [];
    let releaseFirst!: (path: string) => void;
    const firstPath = new Promise<string>((resolve) => {
      releaseFirst = resolve;
    });
    let resolveCalls = 0;
    const resolveRolloutPath = vi.fn(() => {
      resolveCalls += 1;
      return resolveCalls === 1 ? firstPath : Promise.resolve(path);
    });
    const session = {
      id: "runtime-watch-cas",
      provider: "codex",
      projectPath: "/project",
      process: { isWaitingForInput: true },
    };
    const runtime: LocalFeatureRuntime = {
      getSession: () => session,
      getCodexThreadId: () => "thread-watch-cas",
      getActiveCodexProcess: () => null,
      createStandaloneCodexProcess: async () => {
        throw new Error("not used");
      },
      send: (_client, message) => sent.push(message),
      supports: () => true,
    };
    const handler = new CodexDesktopContinuityHandler(runtime, {
      resolveRolloutPath,
    });
    const context = {
      client,
      signal: new AbortController().signal,
      runtime,
    };
    const request = (type: "watch" | "unwatch", requestId: string) =>
      handler.handle(
        type === "watch"
          ? {
              type: "codex_desktop_continuity_watch",
              protocolVersion: 1,
              requestId,
              sessionId: session.id,
              threadId: "thread-watch-cas",
              projectPath: "/project",
            }
          : {
              type: "codex_desktop_continuity_unwatch",
              protocolVersion: 1,
              requestId,
              sessionId: session.id,
              threadId: "thread-watch-cas",
            },
        context,
      );

    const watch1 = request("watch", "watch-1");
    await vi.waitFor(() => expect(resolveRolloutPath).toHaveBeenCalledOnce());
    await request("unwatch", "watch-1");
    await request("watch", "watch-2");
    releaseFirst(path);
    await watch1;

    const registration = (handler as any).watchersByClient
      .get(client)
      ?.get(session.id);
    expect(registration?.requestId).toBe("watch-2");
    expect(
      sent
        .filter((message) => message.event === "watching")
        .map((message) => message.requestId),
    ).toEqual(["watch-2"]);

    await request("unwatch", "watch-1");
    expect(
      (handler as any).watchersByClient.get(client)?.get(session.id)?.requestId,
    ).toBe("watch-2");
    expect(
      (handler as any).monitors.get("thread-watch-cas")?.watcherCount,
    ).toBe(1);
    handler.close();
  });

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

  it("verifies external ownership before any Mobile watcher exists", async () => {
    const path = await rollout([
      event("event_msg", {
        type: "task_started",
        turn_id: "turn-before-watch",
      }),
      event("event_msg", {
        type: "user_message",
        turn_id: "turn-before-watch",
        client_id: "desktop-owner",
        message: "Desktop-owned request",
      }),
    ]);
    const session = {
      id: "runtime-before-watch",
      provider: "codex",
      projectPath: "/project",
      process: { isWaitingForInput: true },
    };
    const runtime: LocalFeatureRuntime = {
      getSession: () => session,
      getCodexThreadId: () => "thread-before-watch",
      getActiveCodexProcess: () => null,
      createStandaloneCodexProcess: async () => {
        throw new Error("not used");
      },
      send: () => {},
      supports: () => true,
    };
    const handler = new CodexDesktopContinuityHandler(runtime, {
      resolveRolloutPath: async () => path,
    });

    expect(handler.hasExternalCodexActivity(session)).toBe(false);
    await expect(
      handler.hasExternalCodexActivityVerified(session),
    ).resolves.toBe(true);
    expect((handler as any).monitors.size).toBe(0);
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
      getSessionCodexActiveTurnId: (sessionId) =>
        sessionId === session.id ? "turn-1" : undefined,
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
      turnSteerable: false,
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
        expect.objectContaining({
          event: "state",
          state: "running",
          turnSteerable: true,
        }),
        expect.objectContaining({
          event: "message",
          turnSteerable: true,
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
    await vi.waitFor(() =>
      expect(drainQueuedInput).toHaveBeenCalledWith(
        "runtime-1",
        expect.any(Function),
      ),
    );
    expect(sent).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          event: "state",
          state: "idle",
          outcome: "completed",
          turnSteerable: false,
          handoffQueued: true,
        }),
        expect.objectContaining({
          event: "state",
          state: "idle",
          historyReady: true,
          handoffQueued: true,
        }),
      ]),
    );
    expect(rehydrate).toHaveBeenCalledWith(
      "runtime-1",
      "thread-1",
      expect.any(Function),
    );
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

  it("refreshes the rollout before draining after rehydrate", async () => {
    const path = await rollout([
      event(
        "event_msg",
        { type: "task_started", turn_id: "desktop-finished" },
        "2026-07-20T00:00:01Z",
      ),
      event(
        "event_msg",
        {
          type: "user_message",
          client_id: "desktop-finished-user",
          message: "first Desktop turn",
        },
        "2026-07-20T00:00:02Z",
      ),
      event(
        "event_msg",
        { type: "task_complete", turn_id: "desktop-finished" },
        "2026-07-20T00:00:03Z",
      ),
    ]);
    const client = {};
    const session = {
      id: "runtime-rehydrate-race",
      provider: "codex",
      projectPath: "/project",
      createdAt: new Date("2026-07-20T00:00:00Z"),
      process: { isWaitingForInput: true },
    };
    const drainQueuedInput = vi.fn(() => true);
    const rehydrate = vi.fn(
      async (
        _sessionId: string,
        _threadId: string,
        isStillSafe?: () => boolean,
      ) => {
        expect(isStillSafe?.()).toBe(true);
        // Simulate Desktop B becoming durable while the replacement runtime
        // reaches input_ready, before fs.watch has refreshed the monitor.
        await appendEntries(path, [
          event("event_msg", {
            type: "task_started",
            turn_id: "desktop-b",
          }),
          event("event_msg", {
            type: "user_message",
            client_id: "desktop-b-user",
            message: "competing Desktop turn",
          }),
        ]);
        return true;
      },
    );
    const runtime: LocalFeatureRuntime = {
      getSession: () => session,
      getCodexThreadId: () => "thread-rehydrate-race",
      getActiveCodexProcess: () => null,
      createStandaloneCodexProcess: async () => {
        throw new Error("not used");
      },
      rehydrateCodexSessionAfterExternalTurn: rehydrate,
      hasCodexQueuedInput: () => true,
      drainCodexQueuedInputIfReady: drainQueuedInput,
      send: () => {},
      supports: () => true,
    };
    const handler = new CodexDesktopContinuityHandler(runtime, {
      resolveRolloutPath: async () => path,
      rehydrateSettleMs: 1,
    });
    await handler.handle(
      {
        type: "codex_desktop_continuity_watch",
        protocolVersion: 1,
        requestId: "watch-rehydrate-race",
        sessionId: session.id,
        threadId: "thread-rehydrate-race",
        projectPath: "/project",
      },
      { client, signal: new AbortController().signal, runtime },
    );

    await vi.waitFor(() =>
      expect(handler.hasExternalCodexActivity(session)).toBe(true),
    );
    expect(rehydrate).toHaveBeenCalledOnce();
    expect(drainQueuedInput).not.toHaveBeenCalled();
    handler.close();
  });

  it("rehydrates once before draining C after external B ends before local A", async () => {
    const path = await rollout();
    const client = {};
    let localTurnId: string | undefined = "local-a";
    let queued = false;
    let drainCount = 0;
    const process = { isWaitingForInput: false };
    const session = {
      id: "runtime-a-b-c",
      provider: "codex",
      projectPath: "/project",
      createdAt: new Date("2026-07-20T00:00:00Z"),
      process,
    };
    const rehydrate = vi.fn(async () => true);
    let handler!: CodexDesktopContinuityHandler;
    const runtime: LocalFeatureRuntime = {
      getSession: () => session,
      getCodexThreadId: () => "thread-a-b-c",
      getActiveCodexProcess: () => null,
      createStandaloneCodexProcess: async () => {
        throw new Error("not used");
      },
      getLocallyActiveCodexTurnId: () => localTurnId,
      rehydrateCodexSessionAfterExternalTurn: rehydrate,
      hasCodexQueuedInput: () => queued,
      drainCodexQueuedInputIfReady: (_sessionId, isStillSafe) => {
        if (
          isStillSafe?.() === false ||
          !process.isWaitingForInput ||
          !queued
        ) {
          return false;
        }
        if (!handler.admitCodexQueuedInputDrain(session)) {
          handler.codexQueuedInputDrainBlocked(session);
          return false;
        }
        queued = false;
        drainCount += 1;
        return true;
      },
      send: () => {},
      supports: () => true,
    };
    handler = new CodexDesktopContinuityHandler(runtime, {
      resolveRolloutPath: async () => path,
      rehydrateSettleMs: 1,
    });
    await handler.handle(
      {
        type: "codex_desktop_continuity_watch",
        protocolVersion: 1,
        requestId: "watch-a-b-c",
        sessionId: session.id,
        threadId: "thread-a-b-c",
        projectPath: "/project",
      },
      { client, signal: new AbortController().signal, runtime },
    );
    await appendEntries(path, [
      event("event_msg", { type: "task_started", turn_id: "local-a" }),
      event("event_msg", { type: "task_started", turn_id: "desktop-b" }),
      event("event_msg", {
        type: "user_message",
        client_id: "desktop-b-user",
        message: "Desktop B",
      }),
    ]);
    const monitor = (handler as any).monitors.get("thread-a-b-c");
    await monitor.refreshNow();
    queued = true;
    expect(
      await handler.admitInput!(client, session, {
        type: "input",
        sessionId: session.id,
        clientMessageId: "mobile-c",
      }),
    ).toEqual({ action: "queue", reason: "desktop_turn_active" });
    handler.inputAccepted!(
      client,
      session,
      {
        type: "input",
        sessionId: session.id,
        clientMessageId: "mobile-c",
      },
      true,
    );

    await appendEntries(path, [
      event("event_msg", { type: "task_complete", turn_id: "desktop-b" }),
    ]);
    await monitor.refreshNow();
    await vi.waitFor(() =>
      expect((handler as any).blockedDrainSessionIds.has(session.id)).toBe(
        true,
      ),
    );
    expect(rehydrate).not.toHaveBeenCalled();
    expect(drainCount).toBe(0);

    await appendEntries(path, [
      event("event_msg", { type: "task_complete", turn_id: "local-a" }),
    ]);
    localTurnId = undefined;
    process.isWaitingForInput = true;
    // Ordinary input_ready happens before fs.watch consumes local A's terminal.
    expect(runtime.drainCodexQueuedInputIfReady!(session.id)).toBe(false);

    await vi.waitFor(() => expect(drainCount).toBe(1));
    expect(rehydrate).toHaveBeenCalledOnce();
    expect(queued).toBe(false);
    expect((handler as any).staleRuntimeSessionIds.has(session.id)).toBe(false);
    expect((handler as any).blockedDrainSessionIds.has(session.id)).toBe(false);
    handler.close();
  });

  it.each(["unwatch", "disconnect"] as const)(
    "keeps C fenced across %s monitor disposal until reconnect rehydrates",
    async (disposal) => {
      const path = await rollout();
      const client = {};
      const reconnectClient = disposal === "disconnect" ? {} : client;
      const threadId = `thread-disposed-${disposal}`;
      let localTurnId: string | undefined = "local-a";
      let queued = false;
      let drainCount = 0;
      const process = { isWaitingForInput: false };
      const session = {
        id: `runtime-disposed-${disposal}`,
        provider: "codex",
        projectPath: "/project",
        createdAt: new Date("2026-07-20T00:00:00Z"),
        process,
      };
      const rehydrate = vi.fn(async () => true);
      let handler!: CodexDesktopContinuityHandler;
      const runtime: LocalFeatureRuntime = {
        getSession: () => session,
        getCodexThreadId: () => threadId,
        getActiveCodexProcess: () => null,
        createStandaloneCodexProcess: async () => {
          throw new Error("not used");
        },
        getLocallyActiveCodexTurnId: () => localTurnId,
        rehydrateCodexSessionAfterExternalTurn: rehydrate,
        hasCodexQueuedInput: () => queued,
        drainCodexQueuedInputIfReady: (_sessionId, isStillSafe) => {
          if (
            isStillSafe?.() === false ||
            !process.isWaitingForInput ||
            !queued
          ) {
            return false;
          }
          if (!handler.admitCodexQueuedInputDrain(session)) {
            handler.codexQueuedInputDrainBlocked(session);
            return false;
          }
          queued = false;
          drainCount += 1;
          return true;
        },
        send: () => {},
        supports: () => true,
      };
      handler = new CodexDesktopContinuityHandler(runtime, {
        resolveRolloutPath: async () => path,
        rehydrateSettleMs: 1,
      });
      const watch = (targetClient: object, requestId: string) =>
        handler.handle(
          {
            type: "codex_desktop_continuity_watch",
            protocolVersion: 1,
            requestId,
            sessionId: session.id,
            threadId,
            projectPath: "/project",
          },
          {
            client: targetClient,
            signal: new AbortController().signal,
            runtime,
          },
        );
      await watch(client, "watch-before-dispose");
      await appendEntries(path, [
        event("event_msg", { type: "task_started", turn_id: "local-a" }),
        event("event_msg", { type: "task_started", turn_id: "desktop-b" }),
        event("event_msg", {
          type: "user_message",
          client_id: "desktop-b-user",
          message: "Desktop B",
        }),
      ]);
      const monitor = (handler as any).monitors.get(threadId);
      await monitor.refreshNow();
      queued = true;
      expect(
        await handler.admitInput!(client, session, {
          type: "input",
          sessionId: session.id,
          clientMessageId: "mobile-c",
        }),
      ).toEqual({ action: "queue", reason: "desktop_turn_active" });
      handler.inputAccepted!(
        client,
        session,
        {
          type: "input",
          sessionId: session.id,
          clientMessageId: "mobile-c",
        },
        true,
      );
      expect((handler as any).staleRuntimeSessionIds.has(session.id)).toBe(
        true,
      );

      if (disposal === "unwatch") {
        await handler.handle(
          {
            type: "codex_desktop_continuity_unwatch",
            protocolVersion: 1,
            requestId: "watch-before-dispose",
            sessionId: session.id,
            threadId,
          },
          {
            client,
            signal: new AbortController().signal,
            runtime,
          },
        );
      } else {
        handler.disconnect(client);
      }
      expect((handler as any).monitors.size).toBe(0);

      await appendEntries(path, [
        event("event_msg", { type: "task_complete", turn_id: "desktop-b" }),
        event("event_msg", { type: "task_complete", turn_id: "local-a" }),
      ]);
      localTurnId = undefined;
      process.isWaitingForInput = true;
      // There is no monitor in this disconnect window, but the session fence
      // must still reject the ordinary input_ready drain.
      expect(runtime.drainCodexQueuedInputIfReady!(session.id)).toBe(false);
      expect(queued).toBe(true);
      expect(drainCount).toBe(0);
      expect(rehydrate).not.toHaveBeenCalled();

      await watch(reconnectClient, "watch-after-dispose");
      await vi.waitFor(() => expect(drainCount).toBe(1));
      expect(rehydrate).toHaveBeenCalledOnce();
      expect(queued).toBe(false);
      expect((handler as any).staleRuntimeSessionIds.has(session.id)).toBe(
        false,
      );
      expect((handler as any).blockedDrainSessionIds.has(session.id)).toBe(
        false,
      );
      handler.close();
    },
  );

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
      expect.any(Function),
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
