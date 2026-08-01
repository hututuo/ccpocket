import {
  chmod,
  mkdir,
  mkdtemp,
  readFile,
  rm,
  stat,
  utimes,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { DebugTraceStore } from "./debug-trace-store.js";

describe("DebugTraceStore", () => {
  let rootDir = "";

  beforeEach(async () => {
    rootDir = await mkdtemp(join(tmpdir(), "ccpocket-debug-trace-store-"));
  });

  afterEach(async () => {
    if (rootDir) {
      await rm(rootDir, { recursive: true, force: true });
    }
  });

  it("persists trace events as jsonl", async () => {
    const store = new DebugTraceStore(rootDir, { persistTraces: true });
    await store.init();

    store.record({
      ts: "2026-02-13T00:00:00.000Z",
      sessionId: "s-1",
      direction: "incoming",
      channel: "ws",
      type: "input",
      detail: 'text="hello" image=false',
    });
    await store.flush();

    const tracePath = store.getTraceFilePath("s-1");
    const raw = await readFile(tracePath, "utf-8");
    const lines = raw.trim().split("\n");
    expect(lines).toHaveLength(1);
    expect(JSON.parse(lines[0])).toMatchObject({
      sessionId: "s-1",
      type: "input",
    });
    expect((await stat(tracePath)).mode & 0o777).toBe(0o600);
    expect((await stat(join(rootDir, "traces"))).mode & 0o777).toBe(0o700);
    expect((store as any).writeChains.size).toBe(0);
  });

  it("keeps automatic trace persistence disabled by default", async () => {
    const store = new DebugTraceStore(rootDir);
    await store.init();
    store.record({
      ts: "2026-02-13T00:00:00.000Z",
      sessionId: "s-private",
      direction: "incoming",
      channel: "ws",
      type: "input",
      detail: "must remain in memory only",
    });
    await store.flush();

    await expect(
      readFile(store.getTraceFilePath("s-private"), "utf8"),
    ).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("bounds opted-in trace files and prunes expired traces", async () => {
    const traceDir = join(rootDir, "traces");
    await mkdir(traceDir, { recursive: true });
    const expiredPath = join(traceDir, "expired.jsonl");
    await writeFile(expiredPath, "old\n", { mode: 0o644 });
    await chmod(expiredPath, 0o644);
    const old = new Date("2026-02-01T00:00:00.000Z");
    await utimes(expiredPath, old, old);

    const now = Date.parse("2026-02-13T00:00:00.000Z");
    const store = new DebugTraceStore(rootDir, {
      persistTraces: true,
      maxTraceBytes: 300,
      traceRetentionMs: 24 * 60 * 60 * 1000,
      now: () => now,
    });
    await store.init();
    await expect(readFile(expiredPath, "utf8")).rejects.toMatchObject({
      code: "ENOENT",
    });

    for (let index = 0; index < 8; index += 1) {
      store.record({
        ts: new Date(now + index).toISOString(),
        sessionId: "s-bounded",
        direction: "outgoing",
        channel: "session",
        type: "assistant",
        detail: `bounded-${index}-${"x".repeat(80)}`,
      });
    }
    await store.flush();
    const tracePath = store.getTraceFilePath("s-bounded");
    expect((await stat(tracePath)).size).toBeLessThanOrEqual(300);
    expect((await stat(tracePath)).mode & 0o777).toBe(0o600);
  });

  it("saves bundle snapshots to disk", async () => {
    const store = new DebugTraceStore(rootDir);
    await store.init();

    const bundlePath = store.saveBundle("s-2", "2026-02-13T01:02:03.456Z", {
      type: "debug_bundle",
      sessionId: "s-2",
    });
    await store.flush();

    const bundleRaw = await readFile(bundlePath, "utf-8");
    const parsed = JSON.parse(bundleRaw) as { type: string; sessionId: string };
    expect(parsed).toEqual({
      type: "debug_bundle",
      sessionId: "s-2",
    });
    expect((store as any).writeChains.size).toBe(0);
  });
});
