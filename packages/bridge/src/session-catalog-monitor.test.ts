import { EventEmitter } from "node:events";
import { watch as nodeWatch, type FSWatcher } from "node:fs";
import { appendFile, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { SessionCatalogMonitor } from "./session-catalog-monitor.js";

const temporaryDirectories: string[] = [];
// The full Bridge suite deliberately stresses filesystem/process resources in
// parallel. macOS can defer an fs.watch callback for more than two seconds
// under that load even though the same contract completes immediately alone.
const WATCH_EVENT_TIMEOUT_MS = 5_000;

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

    const changes: Array<{
      revision: number;
      provider?: string;
      providerSessionId?: string;
    }> = [];
    type WatchCallback = (
      eventType: "rename" | "change",
      filename: string | Buffer | null,
    ) => void;
    const watchCallbacks = new Map<string, WatchCallback>();
    const watchFactory = ((
      directory: string,
      _options: unknown,
      callback: WatchCallback,
    ) => {
      const watcher = new EventEmitter() as FSWatcher;
      watcher.close = vi.fn(() => watcher.emit("close"));
      watcher.ref = () => watcher;
      watcher.unref = () => watcher;
      watchCallbacks.set(directory, callback);
      return watcher;
    }) as unknown as typeof nodeWatch;
    const monitor = new SessionCatalogMonitor({
      roots: [{ path: root, kind: "claudeProjects", maxDepth: 1 }],
      initialRevision: 0,
      debounceMs: 20,
      minIntervalMs: 40,
      retryMs: 50,
      watchFactory,
      onChanged: (revision, change) => changes.push(change ?? { revision }),
    });
    await monitor.start();

    // This test owns the debounce/close contract, not macOS FSEvents delivery.
    // Other cases below retain real fs.watch integration. Drive the installed
    // child watcher deterministically so a lost OS notification cannot make
    // this lifecycle assertion randomly time out.
    const projectWatcher = watchCallbacks.get(project);
    expect(projectWatcher).toBeDefined();
    projectWatcher!("change", "session-1.jsonl");
    projectWatcher!("change", "session-1.jsonl");
    await vi.waitFor(() => expect(changes).toHaveLength(1), {
      timeout: WATCH_EVENT_TIMEOUT_MS,
    });
    expect(changes[0]).toMatchObject({ revision: 1 });

    monitor.close();
    projectWatcher!("change", "session-1.jsonl");
    await new Promise((resolve) => setTimeout(resolve, 100));
    expect(changes).toHaveLength(1);
  });

  it("reports the Codex thread id from a rollout filename", async () => {
    const root = await mkdtemp(join(tmpdir(), "ccpocket-catalog-monitor-"));
    temporaryDirectories.push(root);
    const threadId = "7a87c6d1-1134-4e5f-bc0a-2dd4ad88c329";
    const sessionFile = join(
      root,
      `rollout-2026-07-26T00-00-00-${threadId}.jsonl`,
    );
    await writeFile(sessionFile, '{"type":"session_meta"}\n');

    const changes: Array<{
      revision: number;
      provider?: string;
      providerSessionId?: string;
    }> = [];
    const monitor = new SessionCatalogMonitor({
      roots: [{ path: root, kind: "codexSessions", maxDepth: 0 }],
      initialRevision: 0,
      debounceMs: 10,
      minIntervalMs: 20,
      onChanged: (revision, change) => changes.push(change ?? { revision }),
    });
    await monitor.start();

    await appendFile(sessionFile, '{"type":"event_msg"}\n');
    await vi.waitFor(
      () =>
        expect(changes).toEqual([
          {
            revision: 1,
            provider: "codex",
            providerSessionId: threadId,
          },
        ]),
      { timeout: WATCH_EVENT_TIMEOUT_MS },
    );
    monitor.close();
  });

  it("falls back to an unscoped invalidation for multiple conversations", async () => {
    const root = await mkdtemp(join(tmpdir(), "ccpocket-catalog-monitor-"));
    temporaryDirectories.push(root);
    const project = join(root, "project");
    await mkdir(project);
    const first = join(project, "session-a.jsonl");
    const second = join(project, "session-b.jsonl");
    await writeFile(first, '{"type":"user"}\n');
    await writeFile(second, '{"type":"user"}\n');

    const changes: Array<{
      revision: number;
      provider?: string;
      providerSessionId?: string;
    }> = [];
    const monitor = new SessionCatalogMonitor({
      roots: [{ path: root, kind: "claudeProjects", maxDepth: 1 }],
      initialRevision: 0,
      debounceMs: 20,
      minIntervalMs: 40,
      onChanged: (revision, change) => changes.push(change ?? { revision }),
    });
    await monitor.start();

    await Promise.all([
      appendFile(first, '{"type":"assistant"}\n'),
      appendFile(second, '{"type":"assistant"}\n'),
    ]);
    await vi.waitFor(() => expect(changes).toEqual([{ revision: 1 }]), {
      timeout: WATCH_EVENT_TIMEOUT_MS,
    });
    monitor.close();
  });

  it("adds a watcher when a new provider directory appears", async () => {
    const root = await mkdtemp(join(tmpdir(), "ccpocket-catalog-monitor-"));
    temporaryDirectories.push(root);
    const revisions: number[] = [];
    const monitor = new SessionCatalogMonitor({
      roots: [{ path: root, kind: "claudeProjects", maxDepth: 1 }],
      initialRevision: 0,
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
      timeout: WATCH_EVENT_TIMEOUT_MS,
    });
    const firstRevision = revisions.at(-1)!;

    await new Promise((resolve) => setTimeout(resolve, 350));
    await appendFile(
      join(project, "session-2.jsonl"),
      '{"type":"assistant"}\n',
    );
    await vi.waitFor(
      () => expect(revisions.at(-1)).toBeGreaterThan(firstRevision),
      { timeout: WATCH_EVENT_TIMEOUT_MS },
    );
    monitor.close();
  });

  it("reserves watcher capacity across provider roots before descending", async () => {
    const base = await mkdtemp(join(tmpdir(), "ccpocket-catalog-monitor-"));
    temporaryDirectories.push(base);
    const claudeRoot = join(base, "claude-projects");
    const codexRoot = join(base, "codex-sessions");
    await mkdir(join(claudeRoot, "project-a"), { recursive: true });
    await mkdir(codexRoot, { recursive: true });
    const codexSession = join(codexRoot, "thread-codex.jsonl");
    await writeFile(codexSession, '{"type":"session_meta"}\n');

    const changes: Array<{
      provider?: string;
      providerSessionId?: string;
    }> = [];
    const monitor = new SessionCatalogMonitor({
      roots: [
        { path: claudeRoot, kind: "claudeProjects", maxDepth: 1 },
        { path: codexRoot, kind: "codexSessions", maxDepth: 0 },
      ],
      maxWatchedDirectories: 2,
      initialRevision: 0,
      debounceMs: 10,
      minIntervalMs: 20,
      onChanged: (_revision, change) => changes.push(change ?? {}),
    });
    await monitor.start();
    await new Promise((resolve) => setTimeout(resolve, 50));
    changes.length = 0;

    await appendFile(codexSession, '{"type":"event_msg"}\n');
    await vi.waitFor(
      () =>
        expect(changes).toContainEqual({
          revision: expect.any(Number),
          provider: "codex",
          providerSessionId: "thread-codex",
        }),
      { timeout: WATCH_EVENT_TIMEOUT_MS },
    );
    monitor.close();
  });

  it("keeps capacity for a provider root that appears after startup", async () => {
    const base = await mkdtemp(join(tmpdir(), "ccpocket-catalog-monitor-"));
    temporaryDirectories.push(base);
    const claudeRoot = join(base, "claude-projects");
    const codexRoot = join(base, "codex-sessions");
    await mkdir(join(claudeRoot, "project-a"), { recursive: true });

    const changes: Array<{
      revision?: number;
      provider?: string;
      providerSessionId?: string;
    }> = [];
    const monitor = new SessionCatalogMonitor({
      roots: [
        { path: claudeRoot, kind: "claudeProjects", maxDepth: 1 },
        { path: codexRoot, kind: "codexSessions", maxDepth: 0 },
      ],
      maxWatchedDirectories: 2,
      initialRevision: 0,
      debounceMs: 10,
      minIntervalMs: 20,
      retryMs: 20,
      onChanged: (_revision, change) => changes.push(change ?? {}),
    });
    await monitor.start();

    await mkdir(codexRoot);
    const codexSession = join(codexRoot, "thread-late.jsonl");
    await writeFile(codexSession, '{"type":"session_meta"}\n');
    await new Promise((resolve) => setTimeout(resolve, 200));
    changes.length = 0;
    await appendFile(codexSession, '{"type":"event_msg"}\n');

    await vi.waitFor(
      () =>
        expect(changes).toContainEqual({
          revision: expect.any(Number),
          provider: "codex",
          providerSessionId: "thread-late",
        }),
      { timeout: WATCH_EVENT_TIMEOUT_MS },
    );
    monitor.close();
  });

  it("reclaims a deleted directory watcher for a replacement directory", async () => {
    const root = await mkdtemp(join(tmpdir(), "ccpocket-catalog-monitor-"));
    temporaryDirectories.push(root);
    const retiredProject = join(root, "retired-project");
    const retainedProject = join(root, "retained-project");
    const replacementProject = join(root, "replacement-project");
    await Promise.all([mkdir(retiredProject), mkdir(retainedProject)]);

    const changes: Array<{
      revision?: number;
      provider?: string;
      providerSessionId?: string;
    }> = [];
    const monitor = new SessionCatalogMonitor({
      roots: [{ path: root, kind: "claudeProjects", maxDepth: 1 }],
      maxWatchedDirectories: 3,
      initialRevision: 0,
      debounceMs: 5,
      minIntervalMs: 0,
      onChanged: (_revision, change) => changes.push(change ?? {}),
    });
    await monitor.start();

    try {
      expect(monitor.watcherCount).toBe(3);

      await rm(retiredProject, { recursive: true, force: true });
      await mkdir(replacementProject);
      const replacementSession = join(
        replacementProject,
        "replacement-session.jsonl",
      );
      await writeFile(replacementSession, '{"type":"user"}\n');

      await (monitor as unknown as { scan: () => Promise<void> }).scan();
      expect(monitor.watcherCount).toBe(3);

      await vi.waitFor(
        async () => {
          await appendFile(replacementSession, '{"type":"assistant"}\n');
          expect(changes).toContainEqual({
            revision: expect.any(Number),
            provider: "claude",
            providerSessionId: "replacement-session",
          });
        },
        { timeout: 3_000, interval: 50 },
      );
    } finally {
      monitor.close();
    }
  });

  it("uses a fresh process epoch by default", () => {
    const before = Date.now();
    const monitor = new SessionCatalogMonitor({
      roots: [],
      onChanged: () => {},
    });
    expect(monitor.currentRevision).toBeGreaterThanOrEqual(before);
    expect(monitor.currentRevision).toBeLessThanOrEqual(Date.now());
    monitor.close();
  });

  it("invalidates the catalog when Desktop project assignments change", async () => {
    const root = await mkdtemp(join(tmpdir(), "ccpocket-catalog-monitor-"));
    temporaryDirectories.push(root);
    const globalState = join(root, ".codex-global-state.json");
    await writeFile(globalState, '{"local-projects":{}}');
    const changes: number[] = [];
    const monitor = new SessionCatalogMonitor({
      roots: [{ path: root, kind: "codexRoot", maxDepth: 0 }],
      initialRevision: 0,
      debounceMs: 10,
      minIntervalMs: 20,
      onChanged: (revision) => changes.push(revision),
    });
    await monitor.start();

    await writeFile(
      globalState,
      '{"local-projects":{"project":{"name":"Renamed"}}}',
    );
    await vi.waitFor(() => expect(changes).toEqual([1]), {
      timeout: WATCH_EVENT_TIMEOUT_MS,
    });
    monitor.close();
  });
});
