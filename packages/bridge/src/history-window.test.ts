import { describe, expect, it } from "vitest";
import type { ServerMessage } from "./parser.js";
import {
  selectTurnAwareHistoryWindow,
  TURN_AWARE_HISTORY_MAX_RETAINED_ENTRIES,
} from "./history-window.js";

describe("selectTurnAwareHistoryWindow", () => {
  it("keeps the latest five root turns instead of a flat entry tail", () => {
    const entries = Array.from({ length: 10 }, (_, index) => [
      entry(index * 3 + 1, {
        type: "user_input",
        text: `question ${index}`,
      }),
      entry(index * 3 + 2, assistant(`update ${index}`)),
      entry(index * 3 + 3, { type: "result", subtype: "success" }),
    ]).flat();

    const selected = selectTurnAwareHistoryWindow(entries);

    expect(selected).toHaveLength(15);
    expect(selected[0].message).toMatchObject({
      type: "user_input",
      text: "question 5",
    });
    expect(selected.at(-1)?.message).toMatchObject({
      type: "result",
      subtype: "success",
    });
  });

  it("counts a tool use and its result once and favors recent calls", () => {
    const entries = [
      entry(1, { type: "user_input", text: "inspect" }),
      ...Array.from({ length: 205 }, (_, index) => [
        entry(index * 2 + 2, toolUse(`tool-${index}`)),
        entry(index * 2 + 3, {
          type: "tool_result" as const,
          toolUseId: `tool-${index}`,
          content: `result ${index}`,
        }),
      ]).flat(),
      entry(412, assistant("final answer")),
    ];

    const selected = selectTurnAwareHistoryWindow(entries);

    expect(selected).toHaveLength(403);
    expect(selected[1].message).toMatchObject({
      type: "assistant",
      message: { content: [] },
      historyToolDetailGaps: [
        {
          toolUseIds: ["tool-0", "tool-1", "tool-2", "tool-3", "tool-4"],
          toolCallCount: 5,
        },
      ],
    });
    expect(
      selected.some(
        (item) =>
          item.message.type === "tool_result" &&
          item.message.toolUseId === "tool-0",
      ),
    ).toBe(false);
    expect(
      selected.some(
        (item) =>
          item.message.type === "tool_result" &&
          item.message.toolUseId === "tool-204",
      ),
    ).toBe(true);
    expect(selected.at(-1)?.message).toMatchObject({
      type: "assistant",
      message: {
        content: [{ type: "text", text: "final answer" }],
      },
    });
  });

  it("retains visible text while replacing over-budget tools with a gap", () => {
    const selected = selectTurnAwareHistoryWindow(
      [
        entry(1, { type: "user_input", text: "inspect" }),
        entry(2, {
          type: "assistant",
          message: {
            id: "visible-tool",
            role: "assistant",
            model: "codex",
            content: [
              { type: "text", text: "I am checking the file." },
              {
                type: "tool_use",
                id: "only-tool",
                name: "Read",
                input: { file_path: "a.txt" },
              },
            ],
          },
        }),
      ],
      { toolCalls: 0 },
    );

    expect(selected).toHaveLength(2);
    expect(selected[1].message).toMatchObject({
      type: "assistant",
      message: {
        content: [{ type: "text", text: "I am checking the file." }],
      },
      historyToolDetailGaps: [
        {
          toolUseIds: ["only-tool"],
          toolNames: ["Read"],
          toolCallCount: 1,
        },
      ],
    });
  });

  it("drops anonymous tool payloads that cannot be loaded by stable id", () => {
    const selected = selectTurnAwareHistoryWindow([
      entry(1, { type: "user_input", text: "inspect" }),
      entry(2, {
        type: "assistant",
        message: {
          id: "anonymous-tools",
          role: "assistant",
          model: "codex",
          content: [
            { type: "text", text: "checking" },
            ...Array.from({ length: 1_000 }, () => ({
              type: "tool_use" as const,
              id: "",
              name: "Read",
              input: { content: "x".repeat(1_000) },
            })),
          ],
        },
      }),
    ]);

    expect(selected).toHaveLength(2);
    expect(selected[1].message).toMatchObject({
      type: "assistant",
      message: {
        content: [{ type: "text", text: "checking" }],
      },
    });
  });

  it("has a hard retained-entry ceiling for pathological output", () => {
    const entries = [
      entry(1, { type: "user_input", text: "start" }),
      ...Array.from({ length: 2_000 }, (_, index) =>
        entry(index + 2, assistant(`update ${index}`)),
      ),
    ];

    const selected = selectTurnAwareHistoryWindow(entries);

    expect(selected.length).toBeLessThanOrEqual(
      TURN_AWARE_HISTORY_MAX_RETAINED_ENTRIES,
    );
    expect(selected[0].message.type).toBe("user_input");
    expect(selected.at(-1)?.message).toMatchObject({
      type: "assistant",
      message: {
        content: [{ type: "text", text: "update 1999" }],
      },
    });
  });
});

function entry(seq: number, message: ServerMessage) {
  return { seq, message };
}

function assistant(text: string): ServerMessage {
  return {
    type: "assistant",
    message: {
      id: `assistant-${text}`,
      role: "assistant",
      model: "codex",
      content: [{ type: "text", text }],
    },
  };
}

function toolUse(id: string): ServerMessage {
  return {
    type: "assistant",
    message: {
      id: `assistant-${id}`,
      role: "assistant",
      model: "codex",
      content: [
        {
          type: "tool_use",
          id,
          name: "Read",
          input: { file_path: `${id}.txt` },
        },
      ],
    },
  };
}
