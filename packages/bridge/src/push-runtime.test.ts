import { describe, expect, it, vi } from "vitest";
import type { FirebaseAuthClient } from "./firebase-auth.js";
import {
  initializePushRuntime,
  pushInitializationDisabled,
} from "./push-runtime.js";

function mockClient(initialize = vi.fn(async () => {})): FirebaseAuthClient {
  return {
    initialize,
  } as unknown as FirebaseAuthClient;
}

describe("push runtime startup gate", () => {
  it("preserves the historical enabled default", async () => {
    const initialize = vi.fn(async () => {});
    const createClient = vi.fn(() => mockClient(initialize));

    expect(pushInitializationDisabled({})).toBe(false);
    const client = await initializePushRuntime({
      env: {},
      createClient,
      log: vi.fn(),
      warn: vi.fn(),
    });

    expect(client).toBeDefined();
    expect(createClient).toHaveBeenCalledTimes(1);
    expect(initialize).toHaveBeenCalledTimes(1);
  });

  it.each(["", "1", "true", "yes", "on", "mistyped-value"])(
    "disables fail-closed for %s without constructing Firebase",
    async (value) => {
      const createClient = vi.fn(() => mockClient());
      const log = vi.fn();

      expect(pushInitializationDisabled({ BRIDGE_DISABLE_PUSH: value })).toBe(
        true,
      );
      await expect(
        initializePushRuntime({
          env: { BRIDGE_DISABLE_PUSH: value },
          createClient,
          log,
          warn: vi.fn(),
        }),
      ).resolves.toBeUndefined();

      expect(createClient).not.toHaveBeenCalled();
      expect(log).toHaveBeenCalledWith(
        "[bridge] Push relay disabled by configuration",
      );
    },
  );

  it.each(["0", "false", "no", "off"])(
    "allows an explicit false value %j",
    (value) => {
      expect(pushInitializationDisabled({ BRIDGE_DISABLE_PUSH: value })).toBe(
        false,
      );
    },
  );

  it("keeps startup non-fatal when Firebase initialization fails", async () => {
    const error = new Error("offline");
    const warn = vi.fn();
    const createClient = vi.fn(() =>
      mockClient(vi.fn(async () => Promise.reject(error))),
    );

    await expect(
      initializePushRuntime({
        env: {},
        createClient,
        log: vi.fn(),
        warn,
      }),
    ).resolves.toBeUndefined();
    expect(warn).toHaveBeenCalledWith(
      "[bridge] Push relay disabled: Firebase auth failed:",
      error,
    );
  });
});
