import { describe, expect, it } from "vitest";
import {
  codexCliJoinTarget,
  readCodexAppServerMode,
  readCodexDaemonConfig,
  resolveCodexSharedAppServerUrl,
} from "./codex-app-server-config.js";

describe("codex app-server config", () => {
  it("builds a session-specific Codex CLI join command in managed mode", () => {
    const env = {
      BRIDGE_CODEX_APP_SERVER_MODE: "managed",
      BRIDGE_CODEX_SHARED_APP_SERVER_URL: "ws://127.0.0.1:8767",
    };

    expect(codexCliJoinTarget("thr_123", env)).toEqual({
      url: "ws://127.0.0.1:8767",
      command: "codex resume thr_123 --remote ws://127.0.0.1:8767",
    });
  });

  it("does not expose a join target for private mode", () => {
    expect(codexCliJoinTarget("thr_123", {})).toBeUndefined();
  });

  it("uses the managed default URL when no explicit URL is set", () => {
    expect(
      resolveCodexSharedAppServerUrl("managed", { BRIDGE_PORT: "8767" }),
    ).toBe("ws://127.0.0.1:8768");
  });

  it("keeps an omitted or blank mode backward-compatible with private", () => {
    expect(readCodexAppServerMode({})).toBe("private");
    expect(readCodexAppServerMode({ BRIDGE_CODEX_APP_SERVER_MODE: "  " })).toBe(
      "private",
    );
  });

  it("accepts daemon mode without exposing the TCP CLI join command", () => {
    const env = { BRIDGE_CODEX_APP_SERVER_MODE: "daemon" };
    expect(readCodexAppServerMode(env)).toBe("daemon");
    expect(codexCliJoinTarget("thr_123", env)).toBeUndefined();
  });

  it("fails closed for an unknown non-empty mode", () => {
    expect(() =>
      readCodexAppServerMode({ BRIDGE_CODEX_APP_SERVER_MODE: "daemno" }),
    ).toThrow("Invalid BRIDGE_CODEX_APP_SERVER_MODE");
  });

  it("resolves strict daemon configuration and its default socket", () => {
    expect(
      readCodexDaemonConfig(
        {
          CODEX_HOME: "/Users/test/.codex-pilot",
          BRIDGE_CODEX_DAEMON_CLI: "/Applications/Codex.app/codex",
          BRIDGE_CODEX_DAEMON_EXPECTED_VERSION: "0.146.0-alpha.9.2",
        },
        "darwin",
      ),
    ).toEqual({
      codexHome: "/Users/test/.codex-pilot",
      cliPath: "/Applications/Codex.app/codex",
      socketPath:
        "/Users/test/.codex-pilot/app-server-control/app-server-control.sock",
      expectedVersion: "0.146.0-alpha.9.2",
    });
  });

  it("allows the official managed app-server label to differ from the CLI", () => {
    expect(
      readCodexDaemonConfig(
        {
          CODEX_HOME: "/Users/test/.codex",
          BRIDGE_CODEX_DAEMON_CLI: "/Users/test/.codex/codex",
          BRIDGE_CODEX_DAEMON_EXPECTED_VERSION: "0.146.0-alpha.9.2",
          BRIDGE_CODEX_DAEMON_EXPECTED_APP_SERVER_VERSION: "0.146.0",
        },
        "darwin",
      ).expectedAppServerVersion,
    ).toBe("0.146.0");
  });

  it("rejects incomplete, relative, empty, and Windows daemon configuration", () => {
    const valid = {
      CODEX_HOME: "/Users/test/.codex-pilot",
      BRIDGE_CODEX_DAEMON_CLI: "/Applications/Codex.app/codex",
      BRIDGE_CODEX_DAEMON_EXPECTED_VERSION: "0.146.0-alpha.9.2",
    };
    expect(() => readCodexDaemonConfig({}, "darwin")).toThrow(
      "CODEX_HOME is required",
    );
    expect(() =>
      readCodexDaemonConfig({ ...valid, CODEX_HOME: ".codex" }, "darwin"),
    ).toThrow("CODEX_HOME must be an absolute path");
    expect(() =>
      readCodexDaemonConfig(
        { ...valid, BRIDGE_CODEX_DAEMON_SOCKET: "" },
        "darwin",
      ),
    ).toThrow("BRIDGE_CODEX_DAEMON_SOCKET must not be empty");
    expect(() => readCodexDaemonConfig(valid, "win32")).toThrow(
      "requires a Unix domain socket",
    );
  });
});
