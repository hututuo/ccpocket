import {
  lstat,
  mkdir,
  mkdtemp,
  readFile,
  readdir,
  rename,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";

import {
  acquireStateMutationLock,
  atomicPrivateWrite,
  readBoundedPrivateFile,
  STATE_LOCK_OWNER_FILE,
  STATE_LOCK_RECLAIM_DIRECTORY,
  syncDirectoryForDurability,
  type StateMutationLockOptions,
} from "./private-state.js";

function errorWithCode(code: string): NodeJS.ErrnoException {
  return Object.assign(new Error(code), { code });
}

function lockToken(label: string): string {
  return ["fixture", label].join("_");
}

describe("private conversation identity state", () => {
  const roots: string[] = [];

  afterEach(async () => {
    await Promise.all(
      roots.splice(0).map((root) => rm(root, { recursive: true, force: true })),
    );
  });

  async function stateFile(): Promise<string> {
    const root = await mkdtemp(join(tmpdir(), "ccpocket-v4-state-lock-"));
    roots.push(root);
    return join(root, "state.json");
  }

  async function writeLockOwner(
    file: string,
    owner: { pid: number; token: string; createdAt: string },
  ): Promise<void> {
    await writeOwnerDirectory(`${file}.lock`, owner);
  }

  async function writeOwnerDirectory(
    directory: string,
    owner: { pid: number; token: string; createdAt: string },
  ): Promise<void> {
    await mkdir(directory, { mode: 0o700 });
    await writeFile(
      join(directory, STATE_LOCK_OWNER_FILE),
      `${JSON.stringify({ version: 1, ...owner })}\n`,
      { mode: 0o600 },
    );
  }

  it("binds a bounded read to the file identity observed before open", async () => {
    const file = await stateFile();
    const displaced = `${file}.displaced`;
    await writeFile(file, "original", { mode: 0o600 });

    await expect(
      readBoundedPrivateFile(file, 64, "identity-race fixture", {
        beforeOpen: async () => {
          await rename(file, displaced);
          await writeFile(file, "replacement", { mode: 0o600 });
        },
      }),
    ).rejects.toThrow(/changed while being opened/);

    expect(await readFile(file, "utf8")).toBe("replacement");
    expect(await readFile(displaced, "utf8")).toBe("original");
  });

  it("never replaces an existing destination during create-only install", async () => {
    const file = await stateFile();
    await writeFile(file, "existing", { mode: 0o600 });

    await expect(
      atomicPrivateWrite(file, "replacement", 64, "create-only fixture", {
        createOnly: true,
      }),
    ).rejects.toMatchObject({ code: "EEXIST" });

    expect(await readFile(file, "utf8")).toBe("existing");
  });

  function lockOptions(
    overrides: Partial<StateMutationLockOptions> = {},
  ): StateMutationLockOptions {
    return {
      now: () => Date.UTC(2026, 7, 30, 12),
      processStatus: () => "dead",
      staleGraceMs: 1_000,
      attempts: 4,
      retryMs: 0,
      ...overrides,
    };
  }

  it("recovers an old lock only when its owner process is confirmed dead", async () => {
    const file = await stateFile();
    await writeLockOwner(file, {
      pid: 101,
      token: lockToken("stale-owner-101"),
      createdAt: "2026-08-30T11:59:00.000Z",
    });

    const release = await acquireStateMutationLock(
      file,
      "fixture lock",
      lockOptions({
        pid: 202,
        token: () => lockToken("replacement-202"),
        processStatus: (pid) => (pid === 101 ? "dead" : "alive"),
      }),
    );
    const owner = JSON.parse(
      await readFile(join(`${file}.lock`, STATE_LOCK_OWNER_FILE), "utf8"),
    ) as { pid: number; token: string };
    expect(owner).toMatchObject({
      pid: 202,
      token: lockToken("replacement-202"),
    });
    expect((await lstat(`${file}.lock`)).mode & 0o777).toBe(0o700);
    const ownerStats = await lstat(join(`${file}.lock`, STATE_LOCK_OWNER_FILE));
    expect(ownerStats.mode & 0o777).toBe(0o600);
    expect(ownerStats.size).toBeLessThan(4 * 1024);

    await release();
    expect(await readdir(join(file, ".."))).toEqual([]);
  });

  it("does not steal a live or unknown-owner lock", async () => {
    const liveFile = await stateFile();
    const liveRelease = await acquireStateMutationLock(
      liveFile,
      "live fixture lock",
      lockOptions({ pid: 301, token: () => lockToken("live-owner-301") }),
    );
    await expect(
      acquireStateMutationLock(
        liveFile,
        "live fixture lock",
        lockOptions({
          pid: 302,
          token: () => lockToken("contender-302"),
          processStatus: () => "alive",
          attempts: 2,
        }),
      ),
    ).rejects.toThrow(/busy/);
    expect(
      JSON.parse(
        await readFile(join(`${liveFile}.lock`, STATE_LOCK_OWNER_FILE), "utf8"),
      ),
    ).toMatchObject({ pid: 301, token: lockToken("live-owner-301") });
    await liveRelease();

    const unknownFile = await stateFile();
    await writeLockOwner(unknownFile, {
      pid: 401,
      token: lockToken("unknown-owner-401"),
      createdAt: "2026-08-30T11:59:00.000Z",
    });
    await expect(
      acquireStateMutationLock(
        unknownFile,
        "unknown fixture lock",
        lockOptions({
          pid: 402,
          token: () => lockToken("contender-402"),
          processStatus: () => "unknown",
          attempts: 2,
        }),
      ),
    ).rejects.toThrow(/busy/);
    expect((await lstat(`${unknownFile}.lock`)).isDirectory()).toBe(true);
  });

  it("does not reclaim a newly-created lock even when its PID is dead", async () => {
    const file = await stateFile();
    await writeLockOwner(file, {
      pid: 450,
      token: lockToken("young-dead-owner-450"),
      createdAt: "2026-08-30T12:00:00.000Z",
    });

    await expect(
      acquireStateMutationLock(
        file,
        "young dead fixture lock",
        lockOptions({
          pid: 451,
          token: () => lockToken("contender-451"),
          processStatus: () => "dead",
          attempts: 2,
        }),
      ),
    ).rejects.toThrow(/busy/);
    expect((await lstat(`${file}.lock`)).isDirectory()).toBe(true);
  });

  it("fails closed for malformed lock ownership metadata", async () => {
    const file = await stateFile();
    await mkdir(`${file}.lock`, { mode: 0o700 });
    await writeFile(join(`${file}.lock`, STATE_LOCK_OWNER_FILE), "{broken", {
      mode: 0o600,
    });

    await expect(
      acquireStateMutationLock(
        file,
        "malformed fixture lock",
        lockOptions({
          pid: 475,
          token: () => lockToken("contender-475"),
          attempts: 2,
        }),
      ),
    ).rejects.toThrow(/busy/);
    expect((await lstat(`${file}.lock`)).isDirectory()).toBe(true);
  });

  it("lets only one contender reclaim a dead lock and leaves no artifacts", async () => {
    const file = await stateFile();
    await writeLockOwner(file, {
      pid: 501,
      token: lockToken("stale-owner-501"),
      createdAt: "2026-08-30T11:59:00.000Z",
    });
    const contender = (pid: number, token: string) =>
      acquireStateMutationLock(
        file,
        "contended fixture lock",
        lockOptions({
          pid,
          token: () => token,
          processStatus: (ownerPid) => (ownerPid === 501 ? "dead" : "alive"),
          attempts: 5,
        }),
      );

    const results = await Promise.allSettled([
      contender(502, lockToken("contender-502")),
      contender(503, lockToken("contender-503")),
    ]);
    const acquired = results.filter(
      (result): result is PromiseFulfilledResult<() => Promise<void>> =>
        result.status === "fulfilled",
    );
    expect(acquired).toHaveLength(1);
    expect(
      results.filter((result) => result.status === "rejected"),
    ).toHaveLength(1);

    await acquired[0]!.value();
    expect(await readdir(join(file, ".."))).toEqual([]);
  });

  it("recovers a dead reclaim claim left by a crashed contender", async () => {
    const file = await stateFile();
    await writeLockOwner(file, {
      pid: 550,
      token: lockToken("stale-owner-550"),
      createdAt: "2026-08-30T11:58:00.000Z",
    });
    await writeOwnerDirectory(
      join(`${file}.lock`, STATE_LOCK_RECLAIM_DIRECTORY),
      {
        pid: 551,
        token: lockToken("dead-claimant-551"),
        createdAt: "2026-08-30T11:59:00.000Z",
      },
    );

    const release = await acquireStateMutationLock(
      file,
      "crashed reclaim fixture lock",
      lockOptions({
        pid: 552,
        token: () => lockToken("replacement-552"),
        processStatus: (pid) => (pid === 550 || pid === 551 ? "dead" : "alive"),
        attempts: 5,
      }),
    );
    await release();

    expect(await readdir(join(file, ".."))).toEqual([]);
  });

  it("refuses to delete a lock whose owner token changed before release", async () => {
    const file = await stateFile();
    const release = await acquireStateMutationLock(
      file,
      "ownership fixture lock",
      lockOptions({ pid: 601, token: () => lockToken("original-owner-601") }),
    );
    await writeFile(
      join(`${file}.lock`, STATE_LOCK_OWNER_FILE),
      `${JSON.stringify({
        version: 1,
        pid: 602,
        token: lockToken("replacement-owner-602"),
        createdAt: "2026-08-30T12:00:00.000Z",
      })}\n`,
      { mode: 0o600 },
    );

    await expect(release()).rejects.toThrow(/ownership changed/);
    expect((await lstat(`${file}.lock`)).isDirectory()).toBe(true);
  });

  it("refuses to delete a same-pid same-token replacement before release", async () => {
    const file = await stateFile();
    const pid = 602;
    const token = lockToken("replacement-same-owner");
    const release = await acquireStateMutationLock(
      file,
      "same owner replacement fixture lock",
      lockOptions({ pid, token: () => token }),
    );
    const originalStats = await lstat(`${file}.lock`);
    await rm(`${file}.lock`, { recursive: true, force: true });
    await writeOwnerDirectory(`${file}.lock`, {
      pid,
      token,
      createdAt: "2026-08-30T12:00:00.000Z",
    });
    const replacementStats = await lstat(`${file}.lock`);
    expect(replacementStats.ino).not.toBe(originalStats.ino);

    await expect(release()).rejects.toThrow(/ownership changed before release/);
    expect((await lstat(`${file}.lock`)).isDirectory()).toBe(true);
  });

  it("never restores a tombstone whose bound owner changed", async () => {
    const file = await stateFile();
    const parent = dirname(file);
    let sabotageRelease = false;
    const release = await acquireStateMutationLock(
      file,
      "tombstone replacement fixture lock",
      lockOptions({
        pid: 603,
        token: () => lockToken("tombstone-owner-603"),
        syncDirectory: async () => {
          if (!sabotageRelease) return;
          const releaseEntry = (await readdir(parent)).find((entry) =>
            entry.startsWith("state.json.lock.release-"),
          );
          if (!releaseEntry) return;
          await writeFile(
            join(parent, releaseEntry, STATE_LOCK_OWNER_FILE),
            `${JSON.stringify({
              version: 1,
              pid: 604,
              token: lockToken("replacement-owner-604"),
              createdAt: "2026-08-30T12:00:00.000Z",
            })}\n`,
            { mode: 0o600 },
          );
          throw errorWithCode("EIO");
        },
      }),
    );

    sabotageRelease = true;
    await expect(release()).rejects.toMatchObject({ code: "EIO" });
    await expect(lstat(`${file}.lock`)).rejects.toMatchObject({
      code: "ENOENT",
    });
    expect(
      (await readdir(parent)).filter((entry) =>
        entry.startsWith("state.json.lock.release-"),
      ),
    ).toHaveLength(1);
  });

  it("syncs the namespace after lock install and release mutations", async () => {
    const file = await stateFile();
    const parent = dirname(file);
    const calls: string[] = [];
    const release = await acquireStateMutationLock(
      file,
      "namespace sync fixture lock",
      lockOptions({
        syncDirectory: async (path) => {
          calls.push(path);
        },
      }),
    );
    await release();

    expect(calls.filter((path) => path === parent)).toHaveLength(3);
  });

  it("syncs the namespace around stale lock tombstone reclamation", async () => {
    const file = await stateFile();
    const parent = dirname(file);
    await writeLockOwner(file, {
      pid: 650,
      token: lockToken("stale-sync-owner-650"),
      createdAt: "2026-08-30T11:59:00.000Z",
    });
    const calls: string[] = [];
    const release = await acquireStateMutationLock(
      file,
      "stale namespace sync fixture lock",
      lockOptions({
        syncDirectory: async (path) => {
          calls.push(path);
        },
        processStatus: (pid) => (pid === 650 ? "dead" : "alive"),
      }),
    );
    await release();

    expect(
      calls.filter((path) => path === parent).length,
    ).toBeGreaterThanOrEqual(5);
  });
});

describe("syncDirectoryForDurability", () => {
  it("requires directory fsync on POSIX", async () => {
    let closed = false;
    await expect(
      syncDirectoryForDurability("fixture", {
        platform: "darwin",
        openDirectory: async () => ({
          sync: async () => {
            throw errorWithCode("ENOTSUP");
          },
          close: async () => {
            closed = true;
          },
        }),
      }),
    ).rejects.toMatchObject({ code: "ENOTSUP" });
    expect(closed).toBe(true);
  });

  it("tolerates only known unsupported directory-sync errors on Windows", async () => {
    await expect(
      syncDirectoryForDurability("fixture", {
        platform: "win32",
        openDirectory: async () => {
          throw errorWithCode("EPERM");
        },
      }),
    ).resolves.toBeUndefined();

    let closed = false;
    await expect(
      syncDirectoryForDurability("fixture", {
        platform: "win32",
        openDirectory: async () => ({
          sync: async () => {
            throw errorWithCode("ENOTSUP");
          },
          close: async () => {
            closed = true;
          },
        }),
      }),
    ).resolves.toBeUndefined();
    expect(closed).toBe(true);
  });

  it("does not swallow unknown Windows directory-sync failures", async () => {
    await expect(
      syncDirectoryForDurability("fixture", {
        platform: "win32",
        openDirectory: async () => ({
          sync: async () => {
            throw errorWithCode("EIO");
          },
          close: async () => undefined,
        }),
      }),
    ).rejects.toMatchObject({ code: "EIO" });
  });
});
