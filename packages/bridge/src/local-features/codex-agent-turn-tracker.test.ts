import { describe, expect, it } from "vitest";
import { CodexAgentTurnTracker } from "./codex-agent-turn-tracker.js";

describe("CodexAgentTurnTracker", () => {
  it("binds an id-less delta to the only open agent item", () => {
    const tracker = new CodexAgentTurnTracker();
    tracker.startTurn("turn-1");
    tracker.startAgentItem({ turnId: "turn-1", itemId: "agent-1" });

    tracker.appendDelta({ turnId: "turn-1", text: "bound response" });

    expect(
      tracker.completeAgentItem({
        turnId: "turn-1",
        itemId: "agent-1",
      }),
    ).toEqual({
      kind: "emit",
      emission: {
        turnId: "turn-1",
        itemId: "agent-1",
        text: "bound response",
        affectsActiveTurn: true,
        source: "completed",
      },
    });
  });

  it("suppresses a late completion by turn and item without touching the next turn", () => {
    const tracker = new CodexAgentTurnTracker();
    tracker.startTurn("turn-1");
    tracker.appendDelta({
      turnId: "turn-1",
      itemId: "agent-1",
      text: "first result",
    });
    expect(tracker.completeTurn("turn-1")).toHaveLength(1);

    tracker.startTurn("turn-2");
    tracker.appendDelta({
      turnId: "turn-2",
      itemId: "agent-2",
      text: "second result",
    });
    expect(
      tracker.completeAgentItem({
        turnId: "turn-1",
        itemId: "agent-1",
        completedText: "first result",
      }),
    ).toEqual({ kind: "suppress" });

    expect(tracker.completeTurn("turn-2")).toEqual([
      {
        turnId: "turn-2",
        itemId: "agent-2",
        text: "second result",
        affectsActiveTurn: true,
        source: "turn_fallback",
      },
    ]);
  });

  it("preserves equal text from distinct item ids in the same turn", () => {
    const tracker = new CodexAgentTurnTracker();
    tracker.startTurn("turn-equal");
    tracker.appendDelta({
      itemId: "agent-a",
      text: "same response",
    });
    tracker.appendDelta({
      itemId: "agent-b",
      text: "same response",
    });

    expect(tracker.completeTurn("turn-equal")).toMatchObject([
      { itemId: "agent-a", text: "same response" },
      { itemId: "agent-b", text: "same response" },
    ]);
  });

  it("fails open when an anonymous delta cannot be uniquely attributed", () => {
    const tracker = new CodexAgentTurnTracker();
    tracker.startTurn("turn-ambiguous");
    tracker.startAgentItem({ itemId: "agent-a" });
    tracker.startAgentItem({ itemId: "agent-b" });
    tracker.appendDelta({ text: "same response" });

    expect(
      tracker.completeAgentItem({
        itemId: "agent-a",
        completedText: "same response",
      }),
    ).toMatchObject({
      kind: "emit",
      emission: { itemId: "agent-a", text: "same response" },
    });
    expect(tracker.completeTurn("turn-ambiguous")).toMatchObject([
      { itemId: null, text: "same response" },
    ]);
  });

  it("retains a tombstone across four subsequent turns and then prunes it", () => {
    const tracker = new CodexAgentTurnTracker({
      retainedTurnCount: 5,
      tombstoneCapacity: 5,
    });

    for (let index = 1; index <= 5; index += 1) {
      tracker.startTurn(`turn-${index}`);
      tracker.appendDelta({
        itemId: `agent-${index}`,
        text: `response-${index}`,
      });
      tracker.completeTurn(`turn-${index}`);
    }

    expect(
      tracker.completeAgentItem({
        turnId: "turn-1",
        itemId: "agent-1",
        completedText: "response-1",
      }),
    ).toEqual({ kind: "suppress" });

    tracker.startTurn("turn-6");
    tracker.appendDelta({ itemId: "agent-6", text: "response-6" });
    tracker.completeTurn("turn-6");

    expect(
      tracker.completeAgentItem({
        turnId: "turn-1",
        itemId: "agent-1",
        completedText: "response-1",
      }),
    ).toMatchObject({
      kind: "emit",
      emission: { affectsActiveTurn: false },
    });
  });

  it("clears pending text and tombstones on reset", () => {
    const tracker = new CodexAgentTurnTracker();
    tracker.startTurn("turn-before-reset");
    tracker.appendDelta({ itemId: "agent-1", text: "response" });
    tracker.completeTurn("turn-before-reset");
    tracker.startTurn("turn-pending-before-reset");
    tracker.appendDelta({ itemId: "agent-pending", text: "pending" });

    tracker.reset();

    expect(tracker.completeTurn("turn-pending-before-reset")).toEqual([]);
    expect(
      tracker.completeAgentItem({
        turnId: "turn-before-reset",
        itemId: "agent-1",
        completedText: "response",
      }),
    ).toMatchObject({
      kind: "emit",
      emission: { affectsActiveTurn: false },
    });
  });
});
