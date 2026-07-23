import { describe, expect, it } from "vitest";
import {
  CodexDesktopToolTimelineBuilder,
  codexDesktopToolOutputText,
  describeCodexDesktopToolCall,
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

  it("restores all textual output blocks in order", () => {
    expect(
      codexDesktopToolOutputText([
        { type: "input_text", text: "Script completed" },
        { type: "input_text", text: "result" },
      ]),
    ).toBe("Script completed\nresult");
  });
});
