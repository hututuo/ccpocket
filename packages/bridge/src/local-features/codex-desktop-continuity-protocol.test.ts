import { describe, expect, it } from "vitest";
import {
  isLocalFeatureServerMessageType,
  parseLocalFeatureClientMessage,
} from "./protocol.js";

describe("Codex Desktop continuity protocol", () => {
  it("parses bounded watch and unwatch requests", () => {
    expect(
      parseLocalFeatureClientMessage({
        type: "codex_desktop_continuity_watch",
        protocolVersion: 1,
        requestId: "watch-1",
        sessionId: "runtime-1",
        threadId: "thread-1",
        projectPath: "/project",
      }),
    ).toEqual({
      type: "codex_desktop_continuity_watch",
      protocolVersion: 1,
      requestId: "watch-1",
      sessionId: "runtime-1",
      threadId: "thread-1",
      projectPath: "/project",
    });
    expect(
      parseLocalFeatureClientMessage({
        type: "codex_desktop_continuity_unwatch",
        protocolVersion: 1,
        requestId: "watch-1",
        sessionId: "runtime-1",
        threadId: "thread-1",
      }),
    ).toEqual({
      type: "codex_desktop_continuity_unwatch",
      protocolVersion: 1,
      requestId: "watch-1",
      sessionId: "runtime-1",
      threadId: "thread-1",
    });
  });

  it("rejects unknown fields, missing paths, and protocol drift", () => {
    const base = {
      type: "codex_desktop_continuity_watch",
      protocolVersion: 1,
      requestId: "watch-1",
      sessionId: "runtime-1",
      threadId: "thread-1",
      projectPath: "/project",
    };
    expect(
      parseLocalFeatureClientMessage({ ...base, unexpected: true }),
    ).toBeNull();
    expect(
      parseLocalFeatureClientMessage({ ...base, projectPath: "" }),
    ).toBeNull();
    expect(
      parseLocalFeatureClientMessage({ ...base, protocolVersion: 2 }),
    ).toBeNull();
  });

  it("advertises only the opt-in v1 server event", () => {
    expect(
      isLocalFeatureServerMessageType("codex_desktop_continuity_event_v1"),
    ).toBe(true);
    expect(
      isLocalFeatureServerMessageType("codex_desktop_continuity_event_v2"),
    ).toBe(false);
  });
});
