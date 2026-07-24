import { appendFile, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { SessionCatalogMonitor } from "./session-catalog-monitor.js";

const temporaryDirectories: string[] = [];

afterEach(async () => {
  await Promise.all(
    temporaryDirectories
      .splice(0)
      .map((directory) => rm(directory, { recursive: true, force: true })),
  );
});

describe("SessionCatalogMonitor", () => {
  it("coalesces provider session writes and stops after close", async () => {
    const root = await mkdtemp(join(tmpdir(), "ccpocket-catalog-monitor-"));
    temporaryDirectories.push(root);
    const project = join(root, "project");
    await mkdir(project);
    const sessionFile = join(project, "session-1.jsonl");
    await writeFile(sessionFile, '{"type":"user"}\n');

    const revisions: number[] = [];
    const monitor = new SessionCatalogMonitor({
      roots: [{ path: root, kind: "claudeProjects", maxDepth: 1 }],
      debounceMs: 20,
      minIntervalMs: 40,
      retryMs: 50,
      onChanged: (revision) => revisions.push(revision),
    });
    await monitor.start();

    await Promise.all([
      appendFile(sessionFile, '{"type":"assistant"}\n'),
      appendFile(sessionFile, '{"type":"result"}\n'),
    ]);
    await vi.waitFor(() => expect(revisions).toEqual([1]), {
      timeout: 2_000,
    });

    monitor.close();
    await appendFile(sessionFile, '{"type":"assistant"}\n');
    await new Promise((resolve) => setTimeout(resolve, 100));
    expect(revisions).toEqual([1]);
  });

  it("adds a watcher when a new provider directory appears", async () => {
    const root = await mkdtemp(join(tmpdir(), "ccpocket-catalog-monitor-"));
    temporaryDirectories.push(root);
    const revisions: number[] = [];
    const monitor = new SessionCatalogMonitor({
      roots: [{ path: root, kind: "claudeProjects", maxDepth: 1 }],
      debounceMs: 10,
      minIntervalMs: 20,
      retryMs: 50,
      onChanged: (revision) => revisions.push(revision),
    });
    await monitor.start();

    const project = join(root, "new-project");
    await mkdir(project);
    await writeFile(join(project, "session-2.jsonl"), '{"type":"user"}\n');
    await vi.waitFor(() => expect(revisions.length).toBeGreaterThan(0), {
      timeout: 2_000,
    });
    const firstRevision = revisions.at(-1)!;

    await new Promise((resolve) => setTimeout(resolve, 350));
    await appendFile(
      join(project, "session-2.jsonl"),
      '{"type":"assistant"}\n',
    );
    await vi.waitFor(
      () => expect(revisions.at(-1)).toBeGreaterThan(firstRevision),
      { timeout: 2_000 },
    );
    monitor.close();
  });
});
