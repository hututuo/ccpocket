import { describe, expect, it, vi } from "vitest";
import { EphemeralSideChatFeatureHandler } from "./ephemeral-side-chat.js";
import type { LocalFeatureRuntime } from "./runtime.js";

const entry = {
  childSessionId: "child-session",
  parentSessionId: "parent-session",
  projectPath: "/tmp/project",
  status: "idle",
  createdAt: "2026-07-25T00:00:00.000Z",
  lastActivityAt: "2026-07-25T00:00:01.000Z",
};

function runtime(options: {
  supported?: boolean;
  create?: LocalFeatureRuntime["createEphemeralCodexChildSession"];
  list?: LocalFeatureRuntime["listEphemeralCodexChildSessions"];
  close?: LocalFeatureRuntime["closeEphemeralCodexChildSession"];
}) {
  const sent: unknown[] = [];
  const value: LocalFeatureRuntime = {
    getSession: () => undefined,
    getCodexThreadId: () => undefined,
    getActiveCodexProcess: () => null,
    createStandaloneCodexProcess: vi.fn(),
    createEphemeralCodexChildSession: options.create,
    listEphemeralCodexChildSessions: options.list,
    closeEphemeralCodexChildSession: options.close,
    send: (_client, message) => sent.push(message),
    supports: () => options.supported ?? true,
  };
  return { value, sent };
}

describe("EphemeralSideChatFeatureHandler", () => {
  it("creates an official live-only child with the required fork options", async () => {
    const create = vi.fn(async () => entry);
    const state = runtime({ create });

    await new EphemeralSideChatFeatureHandler().handle(
      {
        type: "open_ephemeral_side_chat",
        parentSessionId: "parent-session",
        requestId: "request-open",
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
        type: "ephemeral_side_chat_opened",
        parentSessionId: "parent-session",
        requestId: "request-open",
        entry,
      },
    ]);
  });

  it("returns an authoritative registry after listing and closing", async () => {
    const list = vi.fn(() => [entry]);
    const close = vi.fn(() => true);
    const state = runtime({ list, close });
    const handler = new EphemeralSideChatFeatureHandler();
    const context = {
      client: {},
      signal: new AbortController().signal,
      runtime: state.value,
    };

    await handler.handle(
      {
        type: "list_ephemeral_side_chats",
        requestId: "request-list",
      },
      context,
    );
    await handler.handle(
      {
        type: "close_ephemeral_side_chat",
        childSessionId: "child-session",
        requestId: "request-close",
      },
      context,
    );

    expect(close).toHaveBeenCalledWith("child-session");
    expect(list).toHaveBeenCalledTimes(2);
    expect(state.sent).toEqual([
      {
        type: "ephemeral_side_chat_registry",
        requestId: "request-list",
        entries: [entry],
      },
      {
        type: "ephemeral_side_chat_registry",
        requestId: "request-close",
        entries: [entry],
      },
    ]);
  });

  it("fails closed when the capability is absent or a child is gone", async () => {
    const unsupported = runtime({
      supported: false,
      create: vi.fn(async () => entry),
    });
    await new EphemeralSideChatFeatureHandler().handle(
      {
        type: "open_ephemeral_side_chat",
        parentSessionId: "parent-session",
        requestId: "request-unsupported",
      },
      {
        client: {},
        signal: new AbortController().signal,
        runtime: unsupported.value,
      },
    );
    expect(unsupported.sent).toEqual([
      expect.objectContaining({
        type: "ephemeral_side_chat_opened",
        errorCode: "unsupported_capability",
      }),
    ]);

    const missing = runtime({
      list: vi.fn(() => [entry]),
      close: vi.fn(() => false),
    });
    await new EphemeralSideChatFeatureHandler().handle(
      {
        type: "close_ephemeral_side_chat",
        childSessionId: "missing-child",
        requestId: "request-missing",
      },
      {
        client: {},
        signal: new AbortController().signal,
        runtime: missing.value,
      },
    );
    expect(missing.sent).toEqual([
      expect.objectContaining({
        type: "ephemeral_side_chat_registry",
        errorCode: "side_chat_not_found",
      }),
    ]);
  });
});
