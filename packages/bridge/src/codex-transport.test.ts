import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
import { afterEach, describe, expect, it, vi } from "vitest";

const { spawnMock } = vi.hoisted(() => ({ spawnMock: vi.fn() }));

vi.mock("node:child_process", async (importOriginal) => {
  const actual =
    await importOriginal<typeof import("node:child_process")>();
  return { ...actual, spawn: spawnMock };
});

import { createCodexTransport } from "./codex-transport.js";

class FakeChild extends EventEmitter {
  stdout = new PassThrough();
  stderr = new PassThrough();
  stdin = new PassThrough();
  killed = false;
  kill = vi.fn((_signal?: string) => {
    this.killed = true;
    return true;
  });
}

function startStdioTransport() {
  const child = new FakeChild();
  spawnMock.mockReturnValueOnce(child);
  const transport = createCodexTransport("/tmp/project");
  transport.start("/tmp/project");
  return { transport, child };
}

afterEach(() => {
  spawnMock.mockReset();
  vi.unstubAllEnvs();
});

describe("StdioCodexTransport crash resilience (P0-5)", () => {
  it("surfaces stdin errors as transport errors instead of crashing", () => {
    const { transport, child } = startStdioTransport();
    const errors: Error[] = [];
    transport.on("error", (err) => errors.push(err));

    const epipe = Object.assign(new Error("write EPIPE"), { code: "EPIPE" });
    expect(() => child.stdin.emit("error", epipe)).not.toThrow();
    expect(errors).toEqual([epipe]);
  });

  it("logs (not crashes) stdin errors that arrive after the child exited", () => {
    const { transport, child } = startStdioTransport();
    const errors: Error[] = [];
    const logs: string[] = [];
    transport.on("error", (err) => errors.push(err));
    transport.on("log", (line) => logs.push(line));

    child.emit("exit", 1);
    const epipe = Object.assign(new Error("write EPIPE"), { code: "EPIPE" });
    expect(() => child.stdin.emit("error", epipe)).not.toThrow();
    expect(errors).toEqual([]);
    expect(logs.some((line) => line.includes("EPIPE"))).toBe(true);
  });

  it("rejects writes synchronously once stdin is no longer writable", () => {
    const { transport, child } = startStdioTransport();
    transport.on("error", () => {});

    // Child crashed on its own: killed stays false, exit not yet delivered.
    child.stdin.destroy();
    expect(child.killed).toBe(false);
    expect(() => transport.write({ hello: "world" })).toThrow(
      "codex app-server is not running",
    );
  });

  it("rejects writes after spawn-level errors (no exit event fires)", () => {
    const { transport, child } = startStdioTransport();
    transport.on("error", () => {});

    const enoent = Object.assign(new Error("spawn codex ENOENT"), {
      code: "ENOENT",
    });
    child.emit("error", enoent);
    expect(transport.isRunning).toBe(false);
    expect(() => transport.write({ hello: "world" })).toThrow(
      "codex app-server is not running",
    );
  });

  it("still delivers writes on a healthy child", async () => {
    const { transport, child } = startStdioTransport();
    const received = new Promise<string>((res) => {
      child.stdin.once("data", (chunk) => res(String(chunk)));
    });

    transport.write({ hello: "world" });
    expect(await received).toBe('{"hello":"world"}\n');
  });
});
