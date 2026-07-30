import { describe, expect, it } from "vitest";
import {
  DURABLE_SESSION_INSIGHTS_CAPABILITY,
  isLocalFeatureServerMessageType,
  parseLocalFeatureClientMessage,
} from "./protocol.js";

describe("session insights protocol slot", () => {
  it("strictly parses context and account usage requests", () => {
    expect(
      parseLocalFeatureClientMessage({
        type: "get_context_usage",
        sessionId: "session-1",
        requestId: "context-1",
      }),
    ).toEqual({
      type: "get_context_usage",
      sessionId: "session-1",
      requestId: "context-1",
    });
    expect(
      parseLocalFeatureClientMessage({
        type: "get_context_usage",
        sessionId: "session-1",
        requestId: "",
      }),
    ).toBeNull();
    expect(
      parseLocalFeatureClientMessage({
        type: "get_session_usage",
        sessionId: "session-1",
        requestId: "usage-1",
      }),
    ).toEqual({
      type: "get_session_usage",
      sessionId: "session-1",
      requestId: "usage-1",
    });
    expect(
      parseLocalFeatureClientMessage({
        type: "get_context_usage",
        sessionId: "session-1",
        extra: true,
      }),
    ).toBeNull();
    expect(
      parseLocalFeatureClientMessage({
        type: "get_session_usage",
        sessionId: "session-1",
        requestId: "",
      }),
    ).toBeNull();
  });

  it("registers only its own response capabilities", () => {
    expect(DURABLE_SESSION_INSIGHTS_CAPABILITY).toBe(
      "durable_session_insights_v1",
    );
    expect(isLocalFeatureServerMessageType("context_usage")).toBe(true);
    expect(isLocalFeatureServerMessageType("context_usage_result")).toBe(true);
    expect(isLocalFeatureServerMessageType("context_usage_error")).toBe(true);
    expect(isLocalFeatureServerMessageType("session_usage_result")).toBe(true);
  });
});
