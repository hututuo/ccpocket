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
