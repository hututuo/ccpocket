import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { ArchiveStore } from "./archive-store.js";

describe("ArchiveStore", () => {
  const tempDirs: string[] = [];

  afterEach(async () => {
    vi.useRealTimers();
    await Promise.all(
      tempDirs.splice(0).map((path) => rm(path, { recursive: true, force: true })),
    );
  });

  async function createStore(): Promise<{ store: ArchiveStore; dir: string }> {
    const dir = await mkdtemp(join(tmpdir(), "ccpocket-archive-store-"));
    tempDirs.push(dir);
    const store = new ArchiveStore(dir);
    await store.init();
    return { store, dir };
  }

  async function createSeededStore(count: number): Promise<{
    store: ArchiveStore;
    dir: string;
    filePath: string;
  }> {
    const dir = await mkdtemp(join(tmpdir(), "ccpocket-archive-store-"));
    tempDirs.push(dir);
    const filePath = join(dir, "archived-sessions.json");
    await writeFile(
      filePath,
      JSON.stringify({
        version: 1,
        archivedSessions: Array.from({ length: count }, (_, index) => ({
          sessionId: `thread-${index}`,
          provider: "codex",
          projectPath: "/project",
          archivedAt: `2026-01-01T00:00:${String(index % 60).padStart(2, "0")}.000Z`,
        })),
      }),
      "utf8",
    );
    const store = new ArchiveStore(dir);
    await store.init();
    return { store, dir, filePath };
  }

  it("serializes concurrent archives without losing an entry", async () => {
    const { store, dir } = await createStore();

    await Promise.all([
      store.archive("thread-a", "codex", "/project/a", {
        name: "Alpha",
        firstPrompt: "first a",
      }),
      store.archive("thread-b", "claude", "/project/b", {
        summary: "summary b",
      }),
    ]);

    expect(store.archivedIds("codex")).toEqual(new Set(["thread-a"]));
    expect(store.archivedIds("claude")).toEqual(new Set(["thread-b"]));
    const disk = JSON.parse(
      await readFile(join(dir, "archived-sessions.json"), "utf8"),
    ) as { archivedSessions: Array<{ sessionId: string }> };
    expect(disk.archivedSessions.map((entry) => entry.sessionId).sort()).toEqual([
      "thread-a",
      "thread-b",
    ]);
  });

  it("keeps concurrent archives for one identity idempotent", async () => {
    const { store } = await createStore();

    await Promise.all([
      store.archive("same-thread", "codex", "/project"),
      store.archive("same-thread", "codex", "/project"),
    ]);

    expect(store.list()).toHaveLength(1);
    expect(store.isArchived("same-thread", "codex")).toBe(true);
  });

  it("rejects entry 10001 without changing disk and remains restart-readable", async () => {
    const { store, dir, filePath } = await createSeededStore(10_000);
    const before = await readFile(filePath, "utf8");

    await expect(
      store.archive("thread-overflow", "codex", "/project"),
    ).rejects.toThrow("10000-entry limit");
    await expect(
      store.archive("thread-0", "codex", "/project"),
    ).resolves.toBeUndefined();

    expect(store.list()).toHaveLength(10_000);
    await expect(readFile(filePath, "utf8")).resolves.toBe(before);
    const reloaded = new ArchiveStore(dir);
    await expect(reloaded.init()).resolves.toBeUndefined();
    expect(reloaded.list()).toHaveLength(10_000);
  });

  it("reserves the final slot atomically across concurrent identities", async () => {
    const { store, dir } = await createSeededStore(9_999);

    const results = await Promise.allSettled([
      store.reserveArchiveCapacity("boundary-a", "codex"),
      store.reserveArchiveCapacity("boundary-b", "codex"),
    ]);
    const fulfilled = results.filter(
      (result): result is PromiseFulfilledResult<
        Awaited<ReturnType<ArchiveStore["reserveArchiveCapacity"]>>
      > => result.status === "fulfilled",
    );
    const rejected = results.filter(
      (result): result is PromiseRejectedResult => result.status === "rejected",
    );
    expect(fulfilled).toHaveLength(1);
    expect(rejected).toHaveLength(1);
    expect(String(rejected[0].reason)).toContain("10000-entry limit");

    const reservation = fulfilled[0].value;
    try {
      await store.commitReservedArchive(reservation, "/project");
    } finally {
      await store.releaseArchiveCapacity(reservation);
    }

    expect(store.list()).toHaveLength(10_000);
    const reloaded = new ArchiveStore(dir);
    await expect(reloaded.init()).resolves.toBeUndefined();
    expect(reloaded.list()).toHaveLength(10_000);
  });

  it("returns defensive list and id snapshots", async () => {
    const { store } = await createStore();
    await store.archive("thread-a", "codex", "/project/a", { name: "Alpha" });

    const listed = store.list();
    listed[0].name = "Changed";
    (store.archivedIds("codex") as Set<string>).clear();

    expect(store.list()[0].name).toBe("Alpha");
    expect(store.isArchived("thread-a", "codex")).toBe(true);
  });

  it("keeps provider plus session id as the archive identity", async () => {
    const { store } = await createStore();
    await store.archive("same-id", "codex", "/project/codex");
    await store.archive("same-id", "claude", "/project/claude");

    expect(store.list()).toHaveLength(2);
    expect(store.isArchived("same-id", "codex")).toBe(true);
    expect(store.isArchived("same-id", "claude")).toBe(true);

    await store.unarchive("same-id", "claude");
    expect(store.isArchived("same-id", "codex")).toBe(true);
    expect(store.isArchived("same-id", "claude")).toBe(false);
  });

  it("keeps identical Codex thread ids separate across source Homes", async () => {
    const { store, dir } = await createStore();
    await store.archive(
      "same-id",
      "codex",
      "/project/a",
      {},
      "codex-home-source-a",
    );
    await store.archive(
      "same-id",
      "codex",
      "/project/b",
      {},
      "codex-home-source-b",
    );

    expect(store.list()).toHaveLength(2);
    expect(store.isArchived("same-id", "codex", "codex-home-source-a")).toBe(
      true,
    );
    expect(store.isArchived("same-id", "codex", "codex-home-source-b")).toBe(
      true,
    );
    expect(store.list(10, "codex-home-source-a")).toMatchObject([
      {
        sessionId: "same-id",
        codexSourceId: "codex-home-source-a",
      },
    ]);
    expect(store.archivedIds("codex", "codex-home-source-a")).toEqual(
      new Set(["same-id"]),
    );

    await store.unarchive("same-id", "codex", "codex-home-source-a");
    expect(store.isArchived("same-id", "codex", "codex-home-source-a")).toBe(
      false,
    );
    expect(store.isArchived("same-id", "codex", "codex-home-source-b")).toBe(
      true,
    );

    const reloaded = new ArchiveStore(dir);
    await reloaded.init();
    expect(reloaded.list()).toMatchObject([
      {
        sessionId: "same-id",
        codexSourceId: "codex-home-source-b",
      },
    ]);
  });

  it("keeps legacy Codex archives globally compatible after source binding", async () => {
    const { store } = await createStore();
    await store.archive("legacy-id", "codex", "/project/legacy");

    await store.archive(
      "legacy-id",
      "codex",
      "/project/source",
      {},
      "codex-home-source-a",
    );

    expect(store.list()).toHaveLength(1);
    expect(store.isArchived("legacy-id", "codex", "codex-home-source-a")).toBe(
      true,
    );
  });

  it("persists unarchive and permanent-delete removal independently", async () => {
    const { store, dir } = await createStore();
    await store.archive("restore-me", "codex", "/project/a");
    await store.archive("delete-me", "codex", "/project/a");

    await expect(store.unarchive("restore-me", "codex")).resolves.toMatchObject({
      sessionId: "restore-me",
    });
    await expect(store.remove("delete-me", "codex")).resolves.toMatchObject({
      sessionId: "delete-me",
    });
    await expect(store.remove("missing", "codex")).resolves.toBeNull();

    const reloaded = new ArchiveStore(dir);
    await reloaded.init();
    expect(reloaded.list()).toEqual([]);
  });

  it("reconciles a complete Codex provider archive without crossing sources", async () => {
    const { store, dir } = await createStore();
    await store.archive(
      "stale-source-a",
      "codex",
      "/project/stale",
      {},
      "source-a",
    );
    await store.archive("confirmed-legacy", "codex", "/project/legacy", {
      name: "Old local title",
    });
    await store.archive(
      "unrelated-legacy",
      "codex",
      "/project/unknown-home",
    );
    await store.archive(
      "other-source",
      "codex",
      "/project/other",
      {},
      "source-b",
    );
    await store.archive("claude-archive", "claude", "/project/claude");
    const legacyArchivedAt = store
      .list()
      .find((entry) => entry.sessionId === "confirmed-legacy")!.archivedAt;

    await store.reconcileCodexSourceSnapshot(
      {
        complete: true,
        entries: [
          {
            sessionId: "confirmed-legacy",
            provider: "codex",
            codexSourceId: "source-a",
            projectPath: "/project/current",
            archivedAt: "2030-01-02T00:00:00.000Z",
            name: "Desktop title",
          },
          {
            sessionId: "desktop-only",
            provider: "codex",
            codexSourceId: "source-a",
            projectPath: "/project/new",
            archivedAt: "2030-01-03T00:00:00.000Z",
          },
        ],
      },
      "source-a",
    );

    expect(store.isArchived("stale-source-a", "codex", "source-a")).toBe(
      false,
    );
    expect(store.isArchived("other-source", "codex", "source-b")).toBe(true);
    expect(store.isArchived("unrelated-legacy", "codex")).toBe(true);
    expect(store.isArchived("claude-archive", "claude")).toBe(true);
    expect(
      store.list().find((entry) => entry.sessionId === "confirmed-legacy"),
    ).toMatchObject({
      codexSourceId: "source-a",
      projectPath: "/project/current",
      name: "Desktop title",
      archivedAt: legacyArchivedAt,
    });
    expect(store.isArchived("desktop-only", "codex", "source-a")).toBe(true);

    const reloaded = new ArchiveStore(dir);
    await reloaded.init();
    expect(reloaded.isArchived("desktop-only", "codex", "source-a")).toBe(
      true,
    );
  });

  it("keeps unseen source rows when the Codex archive scan is partial", async () => {
    const { store } = await createStore();
    await store.archive(
      "unseen",
      "codex",
      "/project/unseen",
      {},
      "source-a",
    );

    await store.reconcileCodexSourceSnapshot(
      {
        complete: false,
        entries: [
          {
            sessionId: "visible",
            provider: "codex",
            codexSourceId: "source-a",
            projectPath: "/project/visible",
            archivedAt: "2030-01-03T00:00:00.000Z",
          },
        ],
      },
      "source-a",
    );

    expect(store.isArchived("unseen", "codex", "source-a")).toBe(true);
    expect(store.isArchived("visible", "codex", "source-a")).toBe(true);
  });

  it("rejects a provider snapshot after a newer local mutation", async () => {
    const { store } = await createStore();
    const revision = store.revision;
    await store.archive("newer-local", "codex", "/project/local", {}, "source-a");

    await expect(
      store.reconcileCodexSourceSnapshot(
        { complete: true, entries: [] },
        "source-a",
        revision,
      ),
    ).resolves.toBe(false);
    expect(store.isArchived("newer-local", "codex", "source-a")).toBe(true);
  });

  it("does not publish an in-memory mutation when atomic save fails", async () => {
    const { store } = await createStore();
    vi.spyOn(store as any, "save").mockRejectedValueOnce(new Error("disk full"));

    await expect(
      store.archive("thread-a", "codex", "/project/a"),
    ).rejects.toThrow("disk full");
    expect(store.isArchived("thread-a", "codex")).toBe(false);
    expect(store.list()).toEqual([]);
  });

  it("fails closed on malformed or duplicate persisted entries", async () => {
    const dir = await mkdtemp(join(tmpdir(), "ccpocket-archive-store-"));
    tempDirs.push(dir);
    await writeFile(
      join(dir, "archived-sessions.json"),
      JSON.stringify({
        version: 1,
        archivedSessions: [
          {
            sessionId: "duplicate",
            provider: "codex",
            projectPath: "/old",
            archivedAt: "2026-01-01T00:00:00.000Z",
          },
          { sessionId: 42, provider: "codex" },
          {
            sessionId: "duplicate",
            provider: "codex",
            projectPath: "/new",
            archivedAt: "2026-02-01T00:00:00.000Z",
            name: "Newest",
          },
          {
            sessionId: "unknown-provider",
            provider: "other",
            projectPath: "/bad",
            archivedAt: "2026-03-01T00:00:00.000Z",
          },
        ],
      }),
      "utf8",
    );

    const store = new ArchiveStore(dir);
    await expect(store.init()).rejects.toThrow("without risking data loss");
    expect(store.list()).toEqual([]);
  });

  it("fails closed on duplicate provider session identities", async () => {
    const dir = await mkdtemp(join(tmpdir(), "ccpocket-archive-store-"));
    tempDirs.push(dir);
    await writeFile(
      join(dir, "archived-sessions.json"),
      JSON.stringify({
        version: 1,
        archivedSessions: [
          {
            sessionId: "duplicate",
            provider: "codex",
            projectPath: "/old",
            archivedAt: "2026-01-01T00:00:00.000Z",
          },
          {
            sessionId: "duplicate",
            provider: "codex",
            projectPath: "/new",
            archivedAt: "2026-02-01T00:00:00.000Z",
          },
        ],
      }),
      "utf8",
    );

    const store = new ArchiveStore(dir);
    await expect(store.init()).rejects.toThrow("Duplicate archived session");
  });

  it("fails closed instead of overwriting an unreadable archive document", async () => {
    const dir = await mkdtemp(join(tmpdir(), "ccpocket-archive-store-"));
    tempDirs.push(dir);
    const filePath = join(dir, "archived-sessions.json");
    await writeFile(filePath, "{not-json", "utf8");

    const store = new ArchiveStore(dir);
    await expect(store.init()).rejects.toThrow(
      "without risking data loss",
    );
    await expect(readFile(filePath, "utf8")).resolves.toBe("{not-json");
  });
});
