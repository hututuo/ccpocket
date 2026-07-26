import { describe, expect, it, vi } from "vitest";
import type { CodexProcess } from "../codex-process.js";
import { LocalFeaturesController } from "./controller.js";
import type { LocalFeatureHandler, LocalFeatureRuntime } from "./runtime.js";

describe("LocalFeaturesController", () => {
  it("stays generic and dispatches only explicitly registered handlers", async () => {
    const handle = vi.fn(async () => {});
    const handler: LocalFeatureHandler = {
      messageTypes: ["get_context_usage"],
      handle,
    };
    const controller = new LocalFeaturesController(runtime(), [handler]);
    const client = {};

    expect(controller.handle(client, { type: "start" })).toBeNull();
    const request = controller.handle(client, {
      type: "get_context_usage",
      sessionId: "session-1",
    });
    expect(request).toBeInstanceOf(Promise);
    await request;

    expect(handle).toHaveBeenCalledOnce();
    expect(handle.mock.calls[0]?.[1]).toMatchObject({
      client,
      signal: expect.any(AbortSignal),
    });
  });

  it("aborts all active operations when the bridge controller closes", async () => {
    let signal: AbortSignal | undefined;
    const close = vi.fn();
    const handler: LocalFeatureHandler = {
      messageTypes: ["get_context_usage"],
      handle: async (_message, context) => {
        signal = context.signal;
        await new Promise<void>((resolve) => {
          context.signal.addEventListener("abort", () => resolve(), {
            once: true,
          });
        });
      },
      close,
    };
    const controller = new LocalFeaturesController(runtime(), [handler]);
    const request = controller.handle(
      {},
      {
        type: "get_context_usage",
        sessionId: "session-1",
      },
    );
    await vi.waitFor(() => expect(signal).toBeDefined());

    await controller.close();
    await request;

    expect(signal?.aborted).toBe(true);
    expect(close).toHaveBeenCalledOnce();
  });

  it("keeps a reconnected client's new operation tracked after the old one settles", async () => {
    const signals: AbortSignal[] = [];
    let releaseFirst!: () => void;
    const firstGate = new Promise<void>((resolve) => {
      releaseFirst = resolve;
    });
    let releaseSecond!: () => void;
    const secondGate = new Promise<void>((resolve) => {
      releaseSecond = resolve;
    });
    const handler: LocalFeatureHandler = {
      messageTypes: ["get_context_usage"],
      handle: async (_message, context) => {
        signals.push(context.signal);
        await (signals.length === 1 ? firstGate : secondGate);
      },
    };
    const controller = new LocalFeaturesController(runtime(), [handler]);
    const client = {};
    const first = controller.handle(client, {
      type: "get_context_usage",
      sessionId: "session-1",
    })!;
    await vi.waitFor(() => expect(signals).toHaveLength(1));
    controller.disconnect(client);
    const second = controller.handle(client, {
      type: "get_context_usage",
      sessionId: "session-1",
    })!;
    await vi.waitFor(() => expect(signals).toHaveLength(2));

    releaseFirst();
    await first;
    controller.disconnect(client);
    expect(signals[1].aborted).toBe(true);
    releaseSecond();
    await second;
    await controller.close();
  });

  it("notifies each registered handler once when capabilities change", () => {
    const capabilitiesChanged = vi.fn();
    const handler: LocalFeatureHandler = {
      messageTypes: ["get_context_usage", "get_session_usage"],
      handle: async () => {},
      capabilitiesChanged,
    };
    const controller = new LocalFeaturesController(runtime(), [handler]);
    const client = {};

    controller.capabilitiesChanged(client);

    expect(capabilitiesChanged).toHaveBeenCalledOnce();
    expect(capabilitiesChanged).toHaveBeenCalledWith(client);
  });

  it("keeps the no-admission path synchronous and composes async gates", async () => {
    const passive: LocalFeatureHandler = {
      messageTypes: ["get_context_usage"],
      handle: async () => {},
    };
    const controller = new LocalFeaturesController(runtime(), [passive]);
    const session = runtime().getSession("session-1")!;
    const message = { type: "input" as const, sessionId: session.id };

    expect(controller.admitInput({}, session, message)).toEqual({
      action: "allow",
    });

    const queueing: LocalFeatureHandler = {
      messageTypes: ["get_session_usage"],
      handle: async () => {},
      admitInput: async () => ({
        action: "queue",
        reason: "external_turn_active",
      }),
    };
    const gated = new LocalFeaturesController(runtime(), [passive, queueing]);
    await expect(gated.admitInput({}, session, message)).resolves.toEqual({
      action: "queue",
      reason: "external_turn_active",
    });
  });

  it("reports external activity separately from a unique steer target", () => {
    const session = runtime().getSession("session-1")!;
    const handler: LocalFeatureHandler = {
      messageTypes: ["get_context_usage"],
      handle: async () => {},
      hasExternalCodexActivity: () => true,
      externalCodexTurnId: () => undefined,
    };
    const controller = new LocalFeaturesController(runtime(), [handler]);

    expect(controller.hasExternalCodexActivity(session)).toBe(true);
    expect(controller.externalCodexTurnId(session)).toBeUndefined();
  });

  it("forwards published session messages once per registered handler", () => {
    const session = runtime().getSession("session-1")!;
    const sessionMessage = vi.fn();
    const handler: LocalFeatureHandler = {
      messageTypes: ["get_context_usage", "get_session_usage"],
      handle: async () => {},
      sessionMessage,
    };
    const controller = new LocalFeaturesController(runtime(), [handler]);
    const message = {
      type: "permission_request" as const,
      toolUseId: "tool-1",
      toolName: "Bash",
      input: { command: "pwd" },
    };

    controller.sessionMessage(session, message);

    expect(sessionMessage).toHaveBeenCalledOnce();
    expect(sessionMessage).toHaveBeenCalledWith(session, message);
  });

  it("forwards one catalog invalidation once per registered handler", () => {
    const sessionCatalogChanged = vi.fn();
    const handler: LocalFeatureHandler = {
      messageTypes: ["get_context_usage", "get_session_usage"],
      handle: async () => {},
      sessionCatalogChanged,
    };
    const controller = new LocalFeaturesController(runtime(), [handler]);
    const change = {
      revision: 7,
      provider: "codex" as const,
      providerSessionId: "thread-1",
    };

    controller.sessionCatalogChanged(change);

    expect(sessionCatalogChanged).toHaveBeenCalledOnce();
    expect(sessionCatalogChanged).toHaveBeenCalledWith(change);
  });

  it("composes generic queued-input drain guards and blocked callbacks", () => {
    const session = runtime().getSession("session-1")!;
    const blocked = vi.fn();
    const allowing: LocalFeatureHandler = {
      messageTypes: ["get_context_usage"],
      handle: async () => {},
      admitCodexQueuedInputDrain: () => true,
      codexQueuedInputDrainBlocked: blocked,
    };
    const rejecting: LocalFeatureHandler = {
      messageTypes: ["get_session_usage"],
      handle: async () => {},
      admitCodexQueuedInputDrain: () => false,
    };
    const controller = new LocalFeaturesController(runtime(), [
      allowing,
      rejecting,
    ]);

    expect(controller.admitCodexQueuedInputDrain(session)).toBe(false);
    controller.codexQueuedInputDrainBlocked(session);
    expect(blocked).toHaveBeenCalledWith(session);
  });
});

function runtime(
  options: {
    process?: CodexProcess;
    sent?: unknown[];
  } = {},
): LocalFeatureRuntime {
  const process = options.process ?? ({} as CodexProcess);
  return {
    getSession: (sessionId) =>
      sessionId === "session-1"
        ? { id: sessionId, provider: "codex", process }
        : undefined,
    getCodexThreadId: () => "thread-1",
    getActiveCodexProcess: () => null,
    createStandaloneCodexProcess: async () => {
      throw new Error("not used");
    },
    send: (_client, message) => options.sent?.push(message),
    supports: () => true,
  };
}
