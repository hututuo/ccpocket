import { spawnSync } from "node:child_process";
import { createRequire } from "node:module";
import { describe, expect, it } from "vitest";

const require = createRequire(import.meta.url);
const tsxCli = require.resolve("tsx/cli");

function runCli(args: string[], bridgePort?: string) {
  const env = { ...process.env };
  if (bridgePort === undefined) {
    delete env.BRIDGE_PORT;
  } else {
    env.BRIDGE_PORT = bridgePort;
  }
  return spawnSync(process.execPath, [tsxCli, "src/cli.ts", ...args], {
    cwd: process.cwd(),
    encoding: "utf8",
    env,
  });
}

describe("ccpocket-bridge CLI", { timeout: 15_000 }, () => {
  it("documents automatic artifact service settings", () => {
    const result = runCli(["--help"]);

    expect(result.status).toBe(0);
    expect(result.stdout).toContain("BRIDGE_AUTO_ARTIFACTS");
    expect(result.stdout).toContain("BRIDGE_ARTIFACT_REGISTRY_FILE");
    expect(result.stdout).toContain("send <path>");
    expect(result.stdout).toContain("file-transfer unlock");
    expect(result.stdout).toContain("BRIDGE_FILE_TRANSFER_PARTIAL_DIR");
    expect(result.stdout).toContain("--codex-source-id");
    expect(result.stdout).toContain("BRIDGE_CODEX_SOURCE_ID");
  });

  it("reports a missing share path without starting the server", () => {
    const result = runCli(["share"]);

    expect(result.status).toBe(1);
    expect(result.stderr).toContain("Share failed: file path is required");
    expect(result.stdout).not.toContain("Starting ccpocket bridge server");
  });

  it("reports a missing send path without starting the server", () => {
    const result = runCli(["send"]);
    expect(result.status).toBe(1);
    expect(result.stderr).toContain("Send failed: file path is required");
    expect(result.stdout).not.toContain("Starting ccpocket bridge server");
  });

  it("requires an explicit file-transfer status or unlock action", () => {
    const result = runCli(["file-transfer"]);
    expect(result.status).toBe(1);
    expect(result.stderr).toContain("requires status or unlock");
  });

  it("rejects an invalid --port value before server startup", () => {
    const result = runCli(["--port", "abc"]);

    expect(result.status).toBe(1);
    expect(result.stderr).toContain(
      '[bridge] Failed to start: Invalid BRIDGE_PORT "abc"',
    );
    expect(result.stdout).not.toContain("Starting ccpocket bridge server");
  });

  it("does not ignore an empty inline --port value", () => {
    const result = runCli(["--port="]);

    expect(result.status).toBe(1);
    expect(result.stderr).toContain(
      '[bridge] Failed to start: Invalid BRIDGE_PORT ""',
    );
  });

  it("rejects --port when its value is missing", () => {
    const result = runCli(["--port"]);

    expect(result.status).toBe(1);
    expect(result.stderr).toContain(
      '[bridge] Failed to start: Invalid BRIDGE_PORT ""',
    );
  });

  it("rejects an invalid BRIDGE_PORT before server startup", () => {
    const result = runCli([], "8.5");

    expect(result.status).toBe(1);
    expect(result.stderr).toContain(
      '[bridge] Failed to start: Invalid BRIDGE_PORT "8.5"',
    );
    expect(result.stdout).not.toContain("Starting ccpocket bridge server");
  });
});
