import { describe, expect, it, vi } from "vitest";
import { createLocalFeaturesController } from "./registry.js";
import type { LocalFeatureRuntime } from "./runtime.js";

function createRuntime(): LocalFeatureRuntime {
  return {
    getSession: () => undefined,
    getCodexThreadId: () => undefined,
    getActiveCodexProcess: () => null,
    createStandaloneCodexProcess: vi.fn(async () => {
      throw new Error("not used");
    }),
    send: vi.fn(),
    supports: () => false,
  };
}

describe("createLocalFeaturesController", () => {
  it("keeps desktop continuity registered for private app-server mode", async () => {
    const runtime = createRuntime();
    const controller = createLocalFeaturesController(runtime, {
      BRIDGE_CODEX_APP_SERVER_MODE: "private",
    });

    const result = controller.handle(
      {},
      { type: "codex_desktop_continuity_watch" },
    );
    expect(result).not.toBeNull();
    await result;
    expect(runtime.send).toHaveBeenCalledWith(
      expect.anything(),
      expect.objectContaining({
        type: "error",
        errorCode: "unsupported_capability",
      }),
    );

    await controller.close();
  });

  it("does not register JSONL desktop continuity in daemon mode", async () => {
    const runtime = createRuntime();
    const controller = createLocalFeaturesController(runtime, {
      BRIDGE_CODEX_APP_SERVER_MODE: "daemon",
    });

    expect(
      controller.handle({}, { type: "codex_desktop_continuity_watch" }),
    ).toBeNull();

    await controller.close();
  });

  it("registers daemon auto approval as Action Broker supervision, not private process supervision", async () => {
    const sent: unknown[] = [];
    const runtime: LocalFeatureRuntime = {
      ...createRuntime(),
      codexSourceId: "source-a",
      send: (_client, message) => sent.push(message),
      supports: () => true,
    };
    const controller = createLocalFeaturesController(runtime, {
      BRIDGE_CODEX_APP_SERVER_MODE: "daemon",
    });

    await controller.handle(
      {},
      {
        type: "get_auto_approval_state",
        requestId: "daemon-auto-approval",
        codexSourceId: "source-a",
        providerSessionId: "thread-a",
      },
    );

    expect(sent).toContainEqual(
      expect.objectContaining({
        requestId: "daemon-auto-approval",
        supervisionAvailable: false,
        supervisionMode: "action_broker",
        unavailableReason: "unsupported_session",
        supervisionUnavailableReason: "action_broker_unavailable",
      }),
    );
    await controller.close();
  });
});
