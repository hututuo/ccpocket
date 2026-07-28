import { describe, expect, it } from "vitest";
import {
  codexHomeIdentity,
  codexSourceIdentity,
  environmentForCodexHome,
  normalizeCodexSourceId,
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

  it("uses a stable opaque identity that changes with the selected Home", () => {
    const first = codexHomeIdentity({
      env: { CODEX_HOME: "/private/first" },
    });
    const repeated = codexHomeIdentity({
      env: { CODEX_HOME: "/private/first" },
    });
    const second = codexHomeIdentity({
      env: { CODEX_HOME: "/private/second" },
    });

    expect(first).toBe(repeated);
    expect(first).not.toBe(second);
    expect(first).toMatch(/^codex-home-[0-9a-f]{24}$/);
    expect(first).not.toContain("/private/first");
  });

  it("keeps the historical Home identity when no shared source is configured", () => {
    const options = {
      env: { CODEX_HOME: "/private/first" },
    };

    expect(codexSourceIdentity(options)).toBe(codexHomeIdentity(options));
  });

  it("uses one explicit authority identity across sequential Codex Homes", () => {
    const sourceId = "codex-source-0123456789abcdef0123456789abcdef";

    expect(
      codexSourceIdentity({
        env: { CODEX_HOME: "/private/first" },
        sourceId,
      }),
    ).toBe(sourceId);
    expect(
      codexSourceIdentity({
        env: {
          CODEX_HOME: "/private/second",
          BRIDGE_CODEX_SOURCE_ID: sourceId,
        },
      }),
    ).toBe(sourceId);
  });

  it("keeps different explicit authorities isolated", () => {
    const first = codexSourceIdentity({
      env: { CODEX_HOME: "/private/shared" },
      sourceId: "codex-source-0123456789abcdef0123456789abcdef",
    });
    const second = codexSourceIdentity({
      env: { CODEX_HOME: "/private/shared" },
      sourceId: "codex-source-fedcba9876543210fedcba9876543210",
    });

    expect(first).not.toBe(second);
  });

  it("accepts one exact historical identity for migration-free adoption", () => {
    const existing = "codex-home-0123456789abcdef01234567";
    expect(normalizeCodexSourceId(existing)).toBe(existing);
    expect(
      codexSourceIdentity({
        env: { CODEX_HOME: "/private/other" },
        sourceId: existing,
      }),
    ).toBe(existing);
  });

  it.each([
    "",
    " codex-source-0123456789abcdef0123456789abcdef",
    "codex-source-0123456789ABCDEF0123456789ABCDEF",
    "shared-main",
    "codex-home-/private/user",
  ])("rejects unsafe or ambiguous explicit source identity %j", (sourceId) => {
    expect(() => normalizeCodexSourceId(sourceId)).toThrow(
      "BRIDGE_CODEX_SOURCE_ID must be",
    );
  });
});
