import { describe, expect, it } from "vitest";
import {
  isLocalFeatureServerMessageType,
  parseLocalFeatureClientMessage,
} from "./protocol.js";

describe("subagents protocol slot", () => {
  it("strictly parses correlated list and history requests", () => {
    expect(
      parseLocalFeatureClientMessage({
        type: "get_subagents",
        sessionId: "session-1",
        requestId: "list-1",
      }),
    ).toEqual({
      type: "get_subagents",
      sessionId: "session-1",
      requestId: "list-1",
    });
    expect(
      parseLocalFeatureClientMessage({
        type: "get_subagent_history",
        sessionId: "session-1",
        threadId: "child-1",
        requestId: "history-1",
      }),
    ).toEqual({
      type: "get_subagent_history",
      sessionId: "session-1",
      threadId: "child-1",
      requestId: "history-1",
    });
    expect(
      parseLocalFeatureClientMessage({
        type: "get_subagents",
        sessionId: "session-1",
        requestId: "",
      }),
    ).toBeNull();
    expect(
      parseLocalFeatureClientMessage({
        type: "get_subagent_history",
        sessionId: "session-1",
        threadId: "child-1",
        requestId: "history-1",
        parentThreadId: "forged",
      }),
    ).toBeNull();
  });

  it("registers only its own response capabilities", () => {
    expect(isLocalFeatureServerMessageType("subagent_list")).toBe(true);
    expect(isLocalFeatureServerMessageType("subagent_history")).toBe(true);
  });
});
