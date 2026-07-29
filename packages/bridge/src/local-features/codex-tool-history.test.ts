import { describe, expect, it } from "vitest";
import {
  CodexDesktopToolTimelineBuilder,
  codexDesktopToolImagePaths,
  codexDesktopToolOutputText,
  describeCodexDesktopToolCall,
  normalizeCodexDesktopToolOutput,
} from "./codex-tool-history.js";

describe("Codex Desktop history tool compatibility", () => {
  it.each([
    ["rg -n TODO apps/mobile", "Search"],
    ["ls -la apps/mobile", "ListFiles"],
    ["sed -n '1,80p' apps/mobile/pubspec.yaml", "Read"],
    ["git status --short", "Bash"],
  ])("classifies %s as %s", (command, expectedName) => {
    const descriptor = describeCodexDesktopToolCall(
      "exec",
      `const r = await tools.exec_command({cmd:${JSON.stringify(command)}}); text(r.output);`,
    );
    expect(descriptor.name).toBe(expectedName);
  });

  it("keeps background-terminal wait separate from sub-agent wait", () => {
    expect(describeCodexDesktopToolCall("wait", {}).name).toBe("Wait");
    expect(describeCodexDesktopToolCall("wait_agent", {}).name).toBe(
      "WaitForAgents",
    );
  });

  it("preserves the distinct Desktop sub-agent lifecycle actions", () => {
    expect(describeCodexDesktopToolCall("spawn_agent", {}).name).toBe(
      "SpawnAgent",
    );
    expect(describeCodexDesktopToolCall("send_message", {}).name).toBe(
      "SendAgentInput",
    );
    expect(describeCodexDesktopToolCall("followup_task", {}).name).toBe(
      "ResumeAgent",
    );
    expect(describeCodexDesktopToolCall("interrupt_agent", {}).name).toBe(
      "InterruptAgent",
    );
    expect(describeCodexDesktopToolCall("list_agents", {}).name).toBe(
      "ListAgents",
    );
  });

  it("builds a real-shape, turn-anchored Desktop tool timeline", () => {
    const builder = new CodexDesktopToolTimelineBuilder();
    const meta = { turn_id: "turn-1" };

    builder.ingest({
      type: "response_item",
      payload: {
        type: "message",
        role: "user",
        content: [{ type: "input_text", text: "inspect this" }],
        internal_chat_message_metadata_passthrough: meta,
      },
    });
    builder.ingest({
      type: "response_item",
      payload: {
        type: "custom_tool_call",
        name: "exec",
        call_id: "call-skill",
        input:
          'const r = await tools.exec_command({cmd:"sed -n \'1,80p\' /tmp/skills/pdf/SKILL.md"}); text(r.output);',
        internal_chat_message_metadata_passthrough: meta,
      },
    });
    builder.ingest({
      type: "response_item",
      payload: {
        type: "custom_tool_call_output",
        call_id: "call-skill",
        output: "skill body",
        internal_chat_message_metadata_passthrough: meta,
      },
    });
    builder.ingest({
      type: "response_item",
      payload: {
        type: "message",
        role: "assistant",
        content: [{ type: "output_text", text: "I found the adapter." }],
        internal_chat_message_metadata_passthrough: meta,
      },
    });
    builder.ingest({
      type: "response_item",
      payload: {
        type: "function_call",
        name: "spawn_agent",
        call_id: "call-agent",
        arguments: '{"task_name":"review"}',
        internal_chat_message_metadata_passthrough: meta,
      },
    });
    builder.ingest({
      type: "response_item",
      payload: {
        type: "function_call_output",
        call_id: "call-agent",
        output: "agent started",
        internal_chat_message_metadata_passthrough: meta,
      },
    });

    expect(builder.snapshot().events).toMatchObject([
      {
        turnId: "turn-1",
        callId: "call-skill",
        afterVisibleMessage: 1,
        type: "tool_use",
        name: "ReadSkill",
      },
      {
        callId: "call-skill",
        afterVisibleMessage: 1,
        type: "tool_result",
        name: "ReadSkill",
        content: "skill body",
      },
      {
        callId: "call-agent",
        afterVisibleMessage: 2,
        type: "tool_use",
        name: "SpawnAgent",
      },
      {
        callId: "call-agent",
        afterVisibleMessage: 2,
        type: "tool_result",
        name: "SpawnAgent",
        content: "agent started",
      },
    ]);
  });

  it("indexes exact item, tool-start, and tool-completion timestamps", () => {
    const builder = new CodexDesktopToolTimelineBuilder();
    const meta = { turn_id: "turn-time" };

    builder.ingest({
      timestamp: "2026-07-29T05:20:01.000Z",
      type: "response_item",
      payload: {
        type: "reasoning",
        id: "reasoning-time",
        internal_chat_message_metadata_passthrough: meta,
      },
    });
    builder.ingest({
      timestamp: "2026-07-29T05:20:02.000Z",
      type: "response_item",
      payload: {
        type: "custom_tool_call",
        id: "tool-item-time",
        name: "exec",
        call_id: "call-time",
        input: 'const r = await tools.exec_command({cmd:"pwd"}); text(r.output);',
        internal_chat_message_metadata_passthrough: meta,
      },
    });
    builder.ingest({
      timestamp: "2026-07-29T05:20:04.000Z",
      type: "response_item",
      payload: {
        type: "custom_tool_call_output",
        id: "tool-output-time",
        call_id: "call-time",
        output: "/tmp",
        internal_chat_message_metadata_passthrough: meta,
      },
    });

    const timestamps = builder.snapshot().itemTimestamps;
    expect(timestamps?.get("reasoning-time")).toEqual({
      startedAt: "2026-07-29T05:20:01.000Z",
      completedAt: "2026-07-29T05:20:01.000Z",
    });
    expect(timestamps?.get("call-time")).toEqual({
      startedAt: "2026-07-29T05:20:02.000Z",
      completedAt: "2026-07-29T05:20:04.000Z",
    });
    expect(timestamps?.get("tool-item-time")).toEqual({
      startedAt: "2026-07-29T05:20:02.000Z",
      completedAt: "2026-07-29T05:20:04.000Z",
    });
  });

  it("restores all textual output blocks in order", () => {
    expect(
      codexDesktopToolOutputText([
        { type: "input_text", text: "Script completed" },
        { type: "input_text", text: "result" },
      ]),
    ).toBe("Script completed\nresult");
  });

  it("keeps view_image output structured instead of rendering base64 as text", () => {
    const output = normalizeCodexDesktopToolOutput([
      {
        type: "input_image",
        detail: "high",
        image_url: "data:image/png;base64,aGVsbG8=",
      },
    ]);

    expect(output).toEqual({
      content: "",
      imageBase64: [{ data: "aGVsbG8=", mimeType: "image/png" }],
    });
    expect(codexDesktopToolOutputText([
      {
        type: "input_image",
        image_url: "data:image/png;base64,aGVsbG8=",
      },
    ])).toBe("Returned 1 image");
    expect(
      codexDesktopToolImagePaths("ViewImage", {
        path: "/tmp/screenshot.png",
      }),
    ).toEqual(["/tmp/screenshot.png"]);
  });

  it("carries the lightweight view_image path through the Desktop timeline", () => {
    const builder = new CodexDesktopToolTimelineBuilder();
    const meta = { turn_id: "turn-image" };
    builder.ingest({
      type: "response_item",
      payload: {
        type: "function_call",
        name: "view_image",
        call_id: "call-image",
        arguments: '{"path":"/tmp/screenshot.png","detail":"high"}',
        internal_chat_message_metadata_passthrough: meta,
      },
    });
    builder.ingest({
      type: "response_item",
      payload: {
        type: "function_call_output",
        call_id: "call-image",
        output: [
          {
            type: "input_image",
            image_url: "data:image/png;base64,aGVsbG8=",
          },
        ],
        internal_chat_message_metadata_passthrough: meta,
      },
    });

    expect(builder.snapshot().events).toMatchObject([
      {
        type: "tool_use",
        name: "ViewImage",
        imagePaths: ["/tmp/screenshot.png"],
      },
      {
        type: "tool_result",
        name: "ViewImage",
        imagePaths: ["/tmp/screenshot.png"],
        content: "Viewed image",
      },
    ]);
  });
});
