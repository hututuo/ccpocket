import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { fetchBoundedCodexUsageFallback } from "./bounded-usage-fallback.js";

const roots: string[] = [];

afterEach(async () => {
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

describe("fetchBoundedCodexUsageFallback", () => {
  it("parses both windows from a 4 KiB tail after a 1 MiB prefix and repeated reads", async () => {
    const root = await mkdtemp(join(tmpdir(), "ccpocket-usage-tail-"));
    roots.push(root);
    const now = new Date(2026, 6, 18, 12);
    const dayDir = join(root, "2026", "07", "18");
    await mkdir(dayDir, { recursive: true });
    const event = tokenCountEvent(now, {
      primary: {
        used_percent: 42,
        window_minutes: 7 * 24 * 60,
        resets_at: 1_800_000_000,
      },
      secondary: {
        used_percent: 17,
        window_minutes: 5 * 60,
        resets_at: 1_799_000_000,
      },
    });
    const eventBytes = Buffer.from(`${event}\n`);
    const prefix = Buffer.alloc(1024 * 1024, 0x78);
    const tailStart = prefix.length + 1 + eventBytes.length - 4096;
    Buffer.from("🙂").copy(prefix, tailStart - 1);
    await writeFile(
      join(dayDir, "rollout-2026-07-18T12-00-00.jsonl"),
      Buffer.concat([prefix, Buffer.from("\n"), eventBytes]),
    );

    await expect(
      fetchBoundedCodexUsageFallback({
        sessionsDir: root,
        now,
        tailBytes: 4096,
        readChunkBytes: 31,
      }),
    ).resolves.toMatchObject([
      {
        provider: "codex",
        source: "session_log",
        fiveHour: {
          utilization: 17,
          windowDurationMins: 300,
        },
        sevenDay: {
          utilization: 42,
          windowDurationMins: 10_080,
        },
      },
    ]);
  });

  it("keeps a complete JSONL record that starts exactly at the tail boundary", async () => {
    const root = await mkdtemp(join(tmpdir(), "ccpocket-usage-boundary-"));
    roots.push(root);
    const now = new Date(2026, 6, 18, 12);
    const dayDir = join(root, "2026", "07", "18");
    await mkdir(dayDir, { recursive: true });
    const event = Buffer.from(
      `${tokenCountEvent(now, {
        primary: {
          used_percent: 36,
          window_minutes: 300,
          resets_at: 1_800_000_000,
        },
      })}\n`,
    );
    const tail = Buffer.alloc(4096, 0x78);
    event.copy(tail, 0);
    tail[tail.length - 1] = 0x0a;
    await writeFile(
      join(dayDir, "rollout-2026-07-18T12-01-00.jsonl"),
      Buffer.concat([
        Buffer.alloc(1024 * 1024, 0x78),
        Buffer.from("\n"),
        tail,
      ]),
    );

    await expect(
      fetchBoundedCodexUsageFallback({
        sessionsDir: root,
        now,
        tailBytes: 4096,
      }),
    ).resolves.toMatchObject([
      {
        provider: "codex",
        source: "session_log",
        fiveHour: { utilization: 36, windowDurationMins: 300 },
      },
    ]);
  });

  it("returns an explicit empty result when its entry budget excludes rollouts", async () => {
    const root = await mkdtemp(join(tmpdir(), "ccpocket-usage-budget-"));
    roots.push(root);
    const now = new Date(2026, 6, 18, 12);
    const dayDir = join(root, "2026", "07", "18");
    await mkdir(dayDir, { recursive: true });
    await writeFile(join(dayDir, "not-a-rollout.txt"), "ignored");
    await writeFile(
      join(dayDir, "rollout-2026-07-18T12-00-00.jsonl"),
      "{}\n",
    );

    await expect(
      fetchBoundedCodexUsageFallback({
        sessionsDir: root,
        now,
        maxDirectoryEntries: 1,
      }),
    ).resolves.toMatchObject([
      {
        provider: "codex",
        source: "session_log",
        fiveHour: null,
        sevenDay: null,
        error: expect.stringContaining("No rate limit data"),
      },
    ]);
  });

  it("never scans more than the hard maximum number of candidate files", async () => {
    const root = await mkdtemp(join(tmpdir(), "ccpocket-usage-files-"));
    roots.push(root);
    const now = new Date(2026, 6, 18, 12);
    const dayDir = join(root, "2026", "07", "18");
    await mkdir(dayDir, { recursive: true });
    const writes: Promise<void>[] = [];
    for (let index = 0; index < 25; index += 1) {
      const name = `rollout-2026-07-18T12-${String(index).padStart(2, "0")}-00.jsonl`;
      const content =
        index === 0
          ? `${tokenCountEvent(now, {
              primary: {
                used_percent: 99,
                window_minutes: 300,
                resets_at: 1_800_000_000,
              },
            })}\n`
          : "{}\n";
      writes.push(writeFile(join(dayDir, name), content));
    }
    await Promise.all(writes);

    const result = await fetchBoundedCodexUsageFallback({
      sessionsDir: root,
      now,
      maxFiles: Number.MAX_SAFE_INTEGER,
    });

    expect(result).toMatchObject([
      {
        source: "session_log",
        fiveHour: null,
        sevenDay: null,
        error: expect.stringContaining("No rate limit data"),
      },
    ]);
  });

  it("clamps caller-supplied day and tail limits to finite ceilings", async () => {
    const now = new Date(2026, 6, 18, 12);

    const oldRoot = await mkdtemp(join(tmpdir(), "ccpocket-usage-days-"));
    roots.push(oldRoot);
    const oldDay = new Date(now);
    oldDay.setDate(oldDay.getDate() - 8);
    const oldDayDir = dayDirectory(oldRoot, oldDay);
    await mkdir(oldDayDir, { recursive: true });
    await writeFile(
      join(oldDayDir, "rollout-2026-07-10T12-00-00.jsonl"),
      `${tokenCountEvent(oldDay, {
        primary: {
          used_percent: 88,
          window_minutes: 300,
          resets_at: 1_800_000_000,
        },
      })}\n`,
    );
    const oldResult = await fetchBoundedCodexUsageFallback({
      sessionsDir: oldRoot,
      now,
      maxDays: Number.MAX_SAFE_INTEGER,
    });
    expect(oldResult[0]?.fiveHour).toBeNull();

    const tailRoot = await mkdtemp(join(tmpdir(), "ccpocket-usage-clamp-tail-"));
    roots.push(tailRoot);
    const currentDayDir = dayDirectory(tailRoot, now);
    await mkdir(currentDayDir, { recursive: true });
    await writeFile(
      join(currentDayDir, "rollout-2026-07-18T12-00-00.jsonl"),
      `${tokenCountEvent(now, {
        primary: {
          used_percent: 77,
          window_minutes: 300,
          resets_at: 1_800_000_000,
        },
      })}\n${"x".repeat(600 * 1024)}\n`,
    );
    const tailResult = await fetchBoundedCodexUsageFallback({
      sessionsDir: tailRoot,
      now,
      tailBytes: Number.MAX_SAFE_INTEGER,
    });
    expect(tailResult[0]?.fiveHour).toBeNull();
  });

  it("returns on its total deadline even while directory entries remain", async () => {
    vi.useFakeTimers();
    const root = await mkdtemp(join(tmpdir(), "ccpocket-usage-deadline-"));
    roots.push(root);
    const now = new Date(2026, 6, 18, 12);
    const dayDir = dayDirectory(root, now);
    await mkdir(dayDir, { recursive: true });
    await Promise.all(
      Array.from({ length: 256 }, (_, index) =>
        writeFile(join(dayDir, `ignored-${index}.txt`), "ignored"),
      ),
    );

    try {
      const pending = fetchBoundedCodexUsageFallback({
        sessionsDir: root,
        now,
        deadlineMs: 1,
      });
      await vi.advanceTimersByTimeAsync(1);
      const result = await pending;

      expect(result).toMatchObject([
        {
          source: "session_log",
          fiveHour: null,
          sevenDay: null,
          error: expect.stringMatching(/deadline|timed out/i),
        },
      ]);
    } finally {
      vi.useRealTimers();
    }
  });
});

function tokenCountEvent(
  timestamp: Date,
  rateLimits: Record<string, unknown>,
): string {
  return JSON.stringify({
    timestamp: timestamp.toISOString(),
    type: "event_msg",
    payload: {
      type: "token_count",
      rate_limits: rateLimits,
    },
  });
}

function dayDirectory(root: string, day: Date): string {
  return join(
    root,
    String(day.getFullYear()),
    String(day.getMonth() + 1).padStart(2, "0"),
    String(day.getDate()).padStart(2, "0"),
  );
}
