import { describe, expect, it } from "vitest";
import {
  isLocalFeatureServerMessageType,
  parseLocalFeatureClientMessage,
} from "./protocol.js";

describe("Codex core actions protocol slot", () => {
  it("strictly parses correlated compact and MCP status requests", () => {
    expect(
      parseLocalFeatureClientMessage({
        type: "codex_compact_request",
        sessionId: "session-1",
        requestId: "compact-1",
      }),
    ).toEqual({
      type: "codex_compact_request",
      sessionId: "session-1",
      requestId: "compact-1",
    });
    expect(
      parseLocalFeatureClientMessage({
        type: "codex_mcp_status_request",
        sessionId: "session-1",
        requestId: "mcp-1",
      }),
    ).toEqual({
      type: "codex_mcp_status_request",
      sessionId: "session-1",
      requestId: "mcp-1",
    });
    expect(
      parseLocalFeatureClientMessage({
        type: "codex_compact_request",
        sessionId: "session-1",
        requestId: "   ",
      }),
    ).toBeNull();
    expect(
      parseLocalFeatureClientMessage({
        type: "codex_compact_request",
        sessionId: "session-1",
        requestId: "compact-1",
        delivery: "detached",
      }),
    ).toBeNull();
  });

  it("parses only the four stable review target shapes", () => {
    const request = (target: Record<string, unknown>) =>
      parseLocalFeatureClientMessage({
        type: "codex_review_request",
        sessionId: "session-1",
        requestId: "review-1",
        target,
      });

    expect(request({ type: "uncommittedChanges" })).toMatchObject({
      target: { type: "uncommittedChanges" },
    });
    expect(
      request({ type: "baseBranch", branch: "origin/main" }),
    ).toMatchObject({
      target: { type: "baseBranch", branch: "origin/main" },
    });
    expect(request({ type: "commit", sha: "abc123" })).toMatchObject({
      target: { type: "commit", sha: "abc123", title: null },
    });
    expect(
      request({ type: "commit", sha: "abc123", title: "Feature" }),
    ).toMatchObject({
      target: { type: "commit", sha: "abc123", title: "Feature" },
    });
    expect(
      request({ type: "custom", instructions: "Review the API boundary" }),
    ).toMatchObject({
      target: {
        type: "custom",
        instructions: "Review the API boundary",
      },
    });
  });

  it("rejects detached delivery, unknown targets, extras, and unbounded text", () => {
    const request = (target: Record<string, unknown>, extras = {}) =>
      parseLocalFeatureClientMessage({
        type: "codex_review_request",
        sessionId: "session-1",
        requestId: "review-1",
        target,
        ...extras,
      });

    expect(
      request({ type: "uncommittedChanges" }, { delivery: "detached" }),
    ).toBeNull();
    expect(request({ type: "detached" })).toBeNull();
    expect(
      request({ type: "baseBranch", branch: "main", forged: true }),
    ).toBeNull();
    expect(request({ type: "custom", instructions: "" })).toBeNull();
    expect(
      request({ type: "custom", instructions: "x".repeat(32 * 1024 + 1) }),
    ).toBeNull();
  });

  it("registers only the two correlated terminal response types", () => {
    expect(isLocalFeatureServerMessageType("codex_action_result")).toBe(true);
    expect(isLocalFeatureServerMessageType("codex_mcp_status_result")).toBe(
      true,
    );
    expect(isLocalFeatureServerMessageType("codex_review_detached")).toBe(
      false,
    );
  });
});
