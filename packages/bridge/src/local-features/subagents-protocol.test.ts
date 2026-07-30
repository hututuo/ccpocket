import { describe, expect, it } from "vitest";
import {
  DETACHED_SUBAGENTS_READ_CAPABILITY,
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

  it("strictly separates detached provider reads from runtime sessions", () => {
    expect(
      parseLocalFeatureClientMessage({
        type: "get_detached_subagents",
        ownerSessionId: "pane-1",
        providerThreadId: "provider-parent-1",
        codexSourceId: "source-1",
        requestId: "list-1",
      }),
    ).toEqual({
      type: "get_detached_subagents",
      ownerSessionId: "pane-1",
      providerThreadId: "provider-parent-1",
      codexSourceId: "source-1",
      requestId: "list-1",
    });
    expect(
      parseLocalFeatureClientMessage({
        type: "get_detached_subagent_history",
        ownerSessionId: "pane-1",
        providerThreadId: "provider-parent-1",
        codexSourceId: "source-1",
        threadId: "child-1",
        requestId: "history-1",
      }),
    ).toEqual({
      type: "get_detached_subagent_history",
      ownerSessionId: "pane-1",
      providerThreadId: "provider-parent-1",
      codexSourceId: "source-1",
      threadId: "child-1",
      requestId: "history-1",
    });
    expect(
      parseLocalFeatureClientMessage({
        type: "get_detached_subagents",
        ownerSessionId: "pane-1",
        providerThreadId: "provider-parent-1",
        codexSourceId: "source-1",
        requestId: "list-1",
        sessionId: "provider-parent-1",
      }),
    ).toBeNull();
  });

  it("registers only its own response capabilities", () => {
    expect(isLocalFeatureServerMessageType("subagent_list")).toBe(true);
    expect(isLocalFeatureServerMessageType("subagent_history")).toBe(true);
    expect(isLocalFeatureServerMessageType("detached_subagent_list")).toBe(
      true,
    );
    expect(isLocalFeatureServerMessageType("detached_subagent_history")).toBe(
      true,
    );
    expect(DETACHED_SUBAGENTS_READ_CAPABILITY).toBe(
      "detached_subagents_read_v1",
    );
  });
});
