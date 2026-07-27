import { describe, expect, it } from "vitest";
import {
  isLocalFeatureServerMessageType,
  parseLocalFeatureClientMessage,
} from "./protocol.js";

describe("conversation mirror protocol slot", () => {
  it("strictly parses correlated probe, sync, watch, and unwatch requests", () => {
    for (const type of [
      "conversation_mirror_probe",
      "conversation_mirror_sync",
      "conversation_mirror_watch",
    ] as const) {
      expect(
        parseLocalFeatureClientMessage({
          type,
          protocolVersion: 1,
          requestId: "request-1",
          provider: "codex",
          providerSessionId: "thread-1",
          projectPath: "/tmp/project",
          knownRevision: "a".repeat(64),
        }),
      ).toEqual({
        type,
        protocolVersion: 1,
        requestId: "request-1",
        provider: "codex",
        providerSessionId: "thread-1",
        projectPath: "/tmp/project",
        knownRevision: "a".repeat(64),
      });
    }

    expect(
      parseLocalFeatureClientMessage({
        type: "conversation_mirror_unwatch",
        protocolVersion: 1,
        requestId: "request-2",
        provider: "claude",
        providerSessionId: "session-2",
      }),
    ).toEqual({
      type: "conversation_mirror_unwatch",
      protocolVersion: 1,
      requestId: "request-2",
      provider: "claude",
      providerSessionId: "session-2",
    });
  });

  it("preserves an optional Codex source while old request shapes stay valid", () => {
    expect(
      parseLocalFeatureClientMessage({
        type: "conversation_mirror_sync",
        protocolVersion: 1,
        requestId: "source-aware",
        provider: "codex",
        providerSessionId: "thread-1",
        codexSourceId: "codex-home-source-a",
        projectPath: "/tmp/project",
      }),
    ).toEqual({
      type: "conversation_mirror_sync",
      protocolVersion: 1,
      requestId: "source-aware",
      provider: "codex",
      providerSessionId: "thread-1",
      codexSourceId: "codex-home-source-a",
      projectPath: "/tmp/project",
    });

    expect(
      parseLocalFeatureClientMessage({
        type: "conversation_mirror_unwatch",
        protocolVersion: 1,
        requestId: "legacy-unwatch",
        provider: "codex",
        providerSessionId: "thread-1",
      }),
    ).toEqual({
      type: "conversation_mirror_unwatch",
      protocolVersion: 1,
      requestId: "legacy-unwatch",
      provider: "codex",
      providerSessionId: "thread-1",
    });
  });

  it("rejects missing, oversized, and forged fields", () => {
    expect(
      parseLocalFeatureClientMessage({
        type: "conversation_mirror_sync",
        requestId: "r",
        provider: "codex",
        providerSessionId: "thread",
      }),
    ).toBeNull();
    expect(
      parseLocalFeatureClientMessage({
        type: "conversation_mirror_sync",
        protocolVersion: 2,
        requestId: "r",
        provider: "codex",
        providerSessionId: "thread",
        projectPath: "/tmp",
      }),
    ).toBeNull();
    expect(
      parseLocalFeatureClientMessage({
        type: "conversation_mirror_watch",
        requestId: "r",
        provider: "other",
        providerSessionId: "thread",
        projectPath: "/tmp",
      }),
    ).toBeNull();
    expect(
      parseLocalFeatureClientMessage({
        type: "conversation_mirror_unwatch",
        requestId: "r",
        provider: "codex",
        providerSessionId: "thread",
        projectPath: "/forged",
      }),
    ).toBeNull();
    expect(
      parseLocalFeatureClientMessage({
        type: "conversation_mirror_probe",
        requestId: "r".repeat(129),
        provider: "codex",
        providerSessionId: "thread",
        projectPath: "/tmp",
      }),
    ).toBeNull();
    expect(
      parseLocalFeatureClientMessage({
        type: "conversation_mirror_sync",
        protocolVersion: 1,
        requestId: "source-blank",
        provider: "codex",
        providerSessionId: "thread",
        codexSourceId: " ",
        projectPath: "/tmp",
      }),
    ).toBeNull();
    expect(
      parseLocalFeatureClientMessage({
        type: "conversation_mirror_sync",
        protocolVersion: 1,
        requestId: "source-oversized",
        provider: "codex",
        providerSessionId: "thread",
        codexSourceId: "s".repeat(129),
        projectPath: "/tmp",
      }),
    ).toBeNull();
    expect(
      parseLocalFeatureClientMessage({
        type: "conversation_mirror_sync",
        protocolVersion: 1,
        requestId: "source-forged",
        provider: "claude",
        providerSessionId: "session",
        codexSourceId: "codex-home-source-a",
        projectPath: "/tmp",
      }),
    ).toBeNull();
  });

  it("registers the base event and additive chunk capabilities", () => {
    expect(isLocalFeatureServerMessageType("conversation_mirror_event_v1")).toBe(
      true,
    );
    expect(
      isLocalFeatureServerMessageType("conversation_mirror_entry_chunk_v1"),
    ).toBe(true);
  });
});
