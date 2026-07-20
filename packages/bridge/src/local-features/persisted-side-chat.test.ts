import { describe, expect, it, vi } from "vitest";
import { PersistedSideChatFeatureHandler } from "./persisted-side-chat.js";
import type { LocalFeatureRuntime } from "./runtime.js";

function runtime(options: {
  supported?: boolean;
  create?: LocalFeatureRuntime["createPersistedCodexChildSession"];
}) {
  const sent: unknown[] = [];
  const value: LocalFeatureRuntime = {
    getSession: () => undefined,
    getCodexThreadId: () => undefined,
    getActiveCodexProcess: () => null,
    createStandaloneCodexProcess: vi.fn(),
    createPersistedCodexChildSession: options.create,
    send: (_client, message) => sent.push(message),
    supports: () => options.supported ?? true,
  };
  return { value, sent };
}

describe("PersistedSideChatFeatureHandler", () => {
  it("creates a durable official child and returns its normal session id", async () => {
    const create = vi.fn(async () => ({
      sessionId: "child-session",
      projectPath: "/tmp/project",
      worktreePath: "/tmp/worktree",
      permissionMode: "acceptEdits",
      sandboxMode: "workspace-write",
    }));
    const state = runtime({ create });

    await new PersistedSideChatFeatureHandler().handle(
      {
        type: "open_persisted_side_chat",
        parentSessionId: "parent-session",
        requestId: "request-1",
      },
      {
        client: {},
        signal: new AbortController().signal,
        runtime: state.value,
      },
    );

    expect(create).toHaveBeenCalledWith("parent-session", {
      threadSource: "ccpocket_side_chat",
      excludeTurnsOnOpen: true,
    });
    expect(state.sent).toEqual([
      {
        type: "persisted_side_chat_opened",
        parentSessionId: "parent-session",
        requestId: "request-1",
        childSessionId: "child-session",
        projectPath: "/tmp/project",
        worktreePath: "/tmp/worktree",
        permissionMode: "acceptEdits",
        sandboxMode: "workspace-write",
      },
    ]);
  });

  it("keeps legacy clients isolated behind capability negotiation", async () => {
    const create = vi.fn();
    const state = runtime({ supported: false, create });

    await new PersistedSideChatFeatureHandler().handle(
      {
        type: "open_persisted_side_chat",
        parentSessionId: "parent-session",
        requestId: "request-1",
      },
      {
        client: {},
        signal: new AbortController().signal,
        runtime: state.value,
      },
    );

    expect(create).not.toHaveBeenCalled();
    expect(state.sent).toEqual([
      expect.objectContaining({
        type: "persisted_side_chat_opened",
        errorCode: "unsupported_capability",
      }),
    ]);
  });
});
