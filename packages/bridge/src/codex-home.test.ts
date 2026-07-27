import { describe, expect, it } from "vitest";
import {
  environmentForCodexHome,
  resolveCodexHome,
  resolveCodexSessionsDir,
} from "./codex-home.js";

describe("Codex home resolution", () => {
  it("uses the platform home when CODEX_HOME is absent", () => {
    expect(
      resolveCodexHome({
        env: {},
        homeDir: "/Users/test",
        cwd: "/work",
      }),
    ).toBe("/Users/test/.codex");
  });

  it("uses an explicit absolute CODEX_HOME for every compatibility path", () => {
    const options = {
      env: { CODEX_HOME: "/isolated/codex-home" },
      homeDir: "/Users/test",
      cwd: "/work",
    };
    expect(resolveCodexHome(options)).toBe("/isolated/codex-home");
    expect(resolveCodexSessionsDir(options)).toBe(
      "/isolated/codex-home/sessions",
    );
  });

  it("resolves a relative CODEX_HOME once against the Bridge cwd", () => {
    expect(
      resolveCodexHome({
        env: { CODEX_HOME: "../codex-home" },
        homeDir: "/Users/test",
        cwd: "/work/bridge",
      }),
    ).toBe("/work/codex-home");
  });

  it("builds an isolated app-server environment without mutating its base", () => {
    const base = { PATH: "/usr/bin", CODEX_HOME: "/old" };
    const result = environmentForCodexHome("/new/codex-home", base);

    expect(result).toEqual({
      PATH: "/usr/bin",
      CODEX_HOME: "/new/codex-home",
    });
    expect(base.CODEX_HOME).toBe("/old");
  });
});
