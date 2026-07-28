import { describe, expect, it } from "vitest";
import { hasFlag, parseCliArgs, parseFlag } from "./cli-args.js";

describe("parseCliArgs", () => {
  it("detects long help flag", () => {
    const parsed = parseCliArgs(["--help"]);
    expect(parsed.helpRequested).toBe(true);
  });

  it("detects short help flag", () => {
    const parsed = parseCliArgs(["-h"]);
    expect(parsed.helpRequested).toBe(true);
  });

  it("detects help command", () => {
    const parsed = parseCliArgs(["help"]);
    expect(parsed.command).toBe("help");
    expect(parsed.helpRequested).toBe(true);
  });

  it("detects long version flag", () => {
    const parsed = parseCliArgs(["--version"]);
    expect(parsed.versionRequested).toBe(true);
  });

  it("detects short version flag", () => {
    const parsed = parseCliArgs(["-v"]);
    expect(parsed.versionRequested).toBe(true);
  });

  it("detects version command", () => {
    const parsed = parseCliArgs(["version"]);
    expect(parsed.command).toBe("version");
    expect(parsed.versionRequested).toBe(true);
  });

  it("does not treat flag values as commands", () => {
    const parsed = parseCliArgs([
      "--public-ws-url",
      "wss://example.ngrok-free.app",
      "--no-mdns",
    ]);

    expect(parsed.command).toBeUndefined();
    expect(parseFlag(parsed, "public-ws-url")).toBe(
      "wss://example.ngrok-free.app",
    );
    expect(hasFlag(parsed, "no-mdns")).toBe(true);
  });

  it("parses inline flag values", () => {
    const parsed = parseCliArgs([
      "--port=9000",
      "--host=127.0.0.1",
      "--artifact-base-url=http://192.168.1.20:8765",
      "--codex-source-id=codex-source-0123456789abcdef0123456789abcdef",
    ]);

    expect(parseFlag(parsed, "port")).toBe("9000");
    expect(parseFlag(parsed, "host")).toBe("127.0.0.1");
    expect(parseFlag(parsed, "artifact-base-url")).toBe(
      "http://192.168.1.20:8765",
    );
    expect(parseFlag(parsed, "codex-source-id")).toBe(
      "codex-source-0123456789abcdef0123456789abcdef",
    );
  });

  it("preserves a value flag with a missing value", () => {
    const parsed = parseCliArgs(["--port"]);

    expect(parseFlag(parsed, "port")).toBe("");
  });

  it("detects setup command after valued flags", () => {
    const parsed = parseCliArgs(["--port", "9000", "setup", "--uninstall"]);

    expect(parsed.command).toBe("setup");
    expect(parseFlag(parsed, "port")).toBe("9000");
    expect(hasFlag(parsed, "uninstall")).toBe(true);
  });

  it("keeps the share path and parses share flags", () => {
    const parsed = parseCliArgs([
      "share",
      "/Users/test/My Report.pdf",
      "--ttl",
      "7200",
      "--base-url=http://192.168.1.20:8765",
      "--json",
    ]);

    expect(parsed.command).toBe("share");
    expect(parsed.positionals[1]).toBe("/Users/test/My Report.pdf");
    expect(parseFlag(parsed, "ttl")).toBe("7200");
    expect(parseFlag(parsed, "base-url")).toBe(
      "http://192.168.1.20:8765",
    );
    expect(hasFlag(parsed, "json")).toBe(true);
  });

  it("parses file-access password input as a command-scoped boolean flag", () => {
    const parsed = parseCliArgs([
      "file-access",
      "set-password",
      "--password-stdin",
    ]);

    expect(parsed.command).toBe("file-access");
    expect(parsed.positionals).toEqual(["file-access", "set-password"]);
    expect(hasFlag(parsed, "password-stdin")).toBe(true);
  });
});
