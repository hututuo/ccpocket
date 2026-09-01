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
  preparePrivateStateDirectory,
  readBoundedPrivateFile,
  STATE_LOCK_OWNER_FILE,
  STATE_LOCK_RECLAIM_DIRECTORY,
  syncDirectoryForDurability,
  type PrivateStateDirectoryBinding,
  type StateMutationLockOptions,
} from "./private-state.js";

function errorWithCode(code: string): NodeJS.ErrnoException {
  return Object.assign(new Error(code), { code });
}

function lockToken(label: string): string {
  return ["fixture", label].join("_");
}

function fixtureProcessIdentity(
  pid: number,
  incarnation = "incarnation",
): string {
  return `fixture_scope:${pid}:${incarnation}`;
}

type FixtureOwner = {
  pid: number;
  processIdentity?: string;
  token: string;
  createdAt: string;
};

describe("private conversation identity state", () => {
  const roots: string[] = [];

  afterEach(async () => {
    await Promise.all(
      roots.splice(0).map((root) => rm(root, { recursive: true, force: true })),
    );
  });

  async function stateFile(): Promise<{
    directory: PrivateStateDirectoryBinding;
    file: string;
  }> {
    const root = await mkdtemp(join(tmpdir(), "ccpocket-v4-state-lock-"));
    roots.push(root);
    const directory = await preparePrivateStateDirectory(root);
    return { directory, file: join(directory.path, "state.json") };
  }

  async function writeLockOwner(
    file: string,
    owner: FixtureOwner,
  ): Promise<void> {
    await writeOwnerDirectory(`${file}.lock`, owner);
  }

  async function writeOwnerDirectory(
    directory: string,
    owner: FixtureOwner,
  ): Promise<void> {
    await mkdir(directory, { mode: 0o700 });
    const processIdentity =
      owner.processIdentity ?? fixtureProcessIdentity(owner.pid);
    await writeFile(
      join(directory, STATE_LOCK_OWNER_FILE),
      `${JSON.stringify({
        version: 2,
        pid: owner.pid,
        processIdentity,
        token: owner.token,
        createdAt: owner.createdAt,
      })}\n`,
      { mode: 0o600 },
    );
  }

  it("binds a bounded read to the file identity observed before open", async () => {
    const { directory, file } = await stateFile();
    const displaced = `${file}.displaced`;
    await writeFile(file, "original", { mode: 0o600 });

    await expect(
      readBoundedPrivateFile(directory, file, 64, "identity-race fixture", {
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
    const { directory, file } = await stateFile();
    await writeFile(file, "existing", { mode: 0o600 });

    await expect(
      atomicPrivateWrite(
        directory,
        file,
        "replacement",
        64,
        "create-only fixture",
        {
          createOnly: true,
        },
      ),
    ).rejects.toMatchObject({ code: "EEXIST" });

    expect(await readFile(file, "utf8")).toBe("existing");
  });

  function lockOptions(
    overrides: Partial<StateMutationLockOptions> = {},
  ): StateMutationLockOptions {
    return {
      now: () => Date.UTC(2026, 7, 30, 12),
      processIdentity: async (pid) => fixtureProcessIdentity(pid),
      processStatus: async (_pid, _expectedIdentity) => "dead",
      staleGraceMs: 1_000,
      attempts: 4,
      retryMs: 0,
      ...overrides,
    };
  }

  it("recovers an old lock only when its owner process is confirmed dead", async () => {
    const { directory, file } = await stateFile();
    await writeLockOwner(file, {
      pid: 101,
      token: lockToken("stale-owner-101"),
      createdAt: "2026-08-30T11:59:00.000Z",
    });

    const release = await acquireStateMutationLock(
      directory,
      file,
      "fixture lock",
      lockOptions({
        pid: 202,
        token: () => lockToken("replacement-202"),
        processStatus: async (pid, _expectedIdentity) =>
          pid === 101 ? "dead" : "alive",
      }),
    );
    const owner = JSON.parse(
      await readFile(join(`${file}.lock`, STATE_LOCK_OWNER_FILE), "utf8"),
    ) as { pid: number; token: string };
    expect(owner).toMatchObject({
      pid: 202,
      processIdentity: fixtureProcessIdentity(202),
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
    const liveState = await stateFile();
    const { directory: liveDirectory, file: liveFile } = liveState;
    const liveRelease = await acquireStateMutationLock(
      liveDirectory,
      liveFile,
      "live fixture lock",
      lockOptions({ pid: 301, token: () => lockToken("live-owner-301") }),
    );
    await expect(
      acquireStateMutationLock(
        liveDirectory,
        liveFile,
        "live fixture lock",
        lockOptions({
          pid: 302,
          token: () => lockToken("contender-302"),
          processStatus: async (_pid, _expectedIdentity) => "alive",
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

    const { directory: unknownDirectory, file: unknownFile } =
      await stateFile();
    await writeLockOwner(unknownFile, {
      pid: 401,
      token: lockToken("unknown-owner-401"),
      createdAt: "2026-08-30T11:59:00.000Z",
    });
    await expect(
      acquireStateMutationLock(
        unknownDirectory,
        unknownFile,
        "unknown fixture lock",
        lockOptions({
          pid: 402,
          token: () => lockToken("contender-402"),
          processStatus: async (_pid, _expectedIdentity) => "unknown",
          attempts: 2,
        }),
      ),
    ).rejects.toThrow(/busy/);
    expect((await lstat(`${unknownFile}.lock`)).isDirectory()).toBe(true);
  });

  it("does not reclaim a newly-created lock even when its PID is dead", async () => {
    const { directory, file } = await stateFile();
    await writeLockOwner(file, {
      pid: 450,
      token: lockToken("young-dead-owner-450"),
      createdAt: "2026-08-30T12:00:00.000Z",
    });

    await expect(
      acquireStateMutationLock(
        directory,
        file,
        "young dead fixture lock",
        lockOptions({
          pid: 451,
          token: () => lockToken("contender-451"),
          processStatus: async (_pid, _expectedIdentity) => "dead",
          attempts: 2,
        }),
      ),
    ).rejects.toThrow(/busy/);
    expect((await lstat(`${file}.lock`)).isDirectory()).toBe(true);
  });

  it("fails closed for malformed lock ownership metadata", async () => {
    const { directory, file } = await stateFile();
    await mkdir(`${file}.lock`, { mode: 0o700 });
    await writeFile(join(`${file}.lock`, STATE_LOCK_OWNER_FILE), "{broken", {
      mode: 0o600,
    });

    await expect(
      acquireStateMutationLock(
        directory,
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
    const { directory, file } = await stateFile();
    await writeLockOwner(file, {
      pid: 501,
      token: lockToken("stale-owner-501"),
      createdAt: "2026-08-30T11:59:00.000Z",
    });
    const contender = (pid: number, token: string) =>
      acquireStateMutationLock(
        directory,
        file,
        "contended fixture lock",
        lockOptions({
          pid,
          token: () => token,
          processStatus: async (ownerPid, _expectedIdentity) =>
            ownerPid === 501 ? "dead" : "alive",
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
    const { directory, file } = await stateFile();
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
      directory,
      file,
      "crashed reclaim fixture lock",
      lockOptions({
        pid: 552,
        token: () => lockToken("replacement-552"),
        processStatus: async (pid, _expectedIdentity) =>
          pid === 550 || pid === 551 ? "dead" : "alive",
        attempts: 5,
      }),
    );
    await release();

    expect(await readdir(join(file, ".."))).toEqual([]);
  });

  it("refuses to delete a lock whose owner token changed before release", async () => {
    const { directory, file } = await stateFile();
    const release = await acquireStateMutationLock(
      directory,
      file,
      "ownership fixture lock",
      lockOptions({ pid: 601, token: () => lockToken("original-owner-601") }),
    );
    await writeFile(
      join(`${file}.lock`, STATE_LOCK_OWNER_FILE),
      `${JSON.stringify({
        version: 2,
        pid: 602,
        processIdentity: fixtureProcessIdentity(602, "replacement"),
        token: lockToken("replacement-owner-602"),
        createdAt: "2026-08-30T12:00:00.000Z",
      })}\n`,
      { mode: 0o600 },
    );

    await expect(release()).rejects.toThrow(/ownership changed/);
    expect((await lstat(`${file}.lock`)).isDirectory()).toBe(true);
  });

  it("refuses to delete a same-pid same-token replacement before release", async () => {
    const { directory, file } = await stateFile();
    const pid = 602;
    const token = lockToken("replacement-same-owner");
    const release = await acquireStateMutationLock(
      directory,
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
    const { directory, file } = await stateFile();
    const parent = dirname(file);
    let sabotageRelease = false;
    const release = await acquireStateMutationLock(
      directory,
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
              version: 2,
              pid: 604,
              processIdentity: fixtureProcessIdentity(604, "replacement"),
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

  it("quarantines a reclaim rollback changed after restore rename", async () => {
    const { directory, file } = await stateFile();
    const parent = dirname(file);
    await writeLockOwner(file, {
      pid: 607,
      token: lockToken("stale-restore-owner-607"),
      createdAt: "2026-08-30T11:59:00.000Z",
    });
    let parentSyncs = 0;

    await expect(
      acquireStateMutationLock(
        directory,
        file,
        "restore final snapshot fixture lock",
        lockOptions({
          pid: 608,
          token: () => lockToken("restore-contender-608"),
          processStatus: async (pid, _expectedIdentity) =>
            pid === 607 ? "dead" : "alive",
          syncDirectory: async (path) => {
            if (path !== parent) return;
            parentSyncs += 1;
            if (parentSyncs === 1) throw errorWithCode("EIO");
            if (parentSyncs === 2) {
              await writeFile(
                join(`${file}.lock`, STATE_LOCK_OWNER_FILE),
                `${JSON.stringify({
                  version: 2,
                  pid: 609,
                  processIdentity: fixtureProcessIdentity(
                    609,
                    "changed-after-restore",
                  ),
                  token: lockToken("changed-after-restore-609"),
                  createdAt: "2026-08-30T12:00:00.000Z",
                })}\n`,
                { mode: 0o600 },
              );
            }
          },
        }),
      ),
    ).rejects.toMatchObject({ code: "EIO" });

    await expect(lstat(`${file}.lock`)).rejects.toMatchObject({ code: "ENOENT" });
    const quarantine = (await readdir(parent)).filter((entry) =>
      entry.startsWith("state.json.lock.changed-restore-"),
    );
    expect(quarantine).toHaveLength(1);
    const changedOwner = JSON.parse(
      await readFile(join(parent, quarantine[0]!, STATE_LOCK_OWNER_FILE), "utf8"),
    ) as { pid: number; processIdentity: string };
    expect(changedOwner).toMatchObject({
      pid: 609,
      processIdentity: fixtureProcessIdentity(609, "changed-after-restore"),
    });
  });

  it("reclaims a stale lock for a reused PID only when its process identity differs", async () => {
    const staleState = await stateFile();
    const pid = 70101;
    const currentIdentity = fixtureProcessIdentity(pid);
    const previousIdentity = fixtureProcessIdentity(pid, "previous-incarnation");
    await writeLockOwner(staleState.file, {
      pid,
      processIdentity: previousIdentity,
      token: lockToken("stale-reused-pid"),
      createdAt: "2026-08-30T11:59:00.000Z",
    });

    const observedStatuses: Array<{
      pid: number;
      expectedIdentity: string;
    }> = [];
    const release = await acquireStateMutationLock(
      staleState.directory,
      staleState.file,
      "reused PID fixture lock",
      lockOptions({
        pid,
        token: () => lockToken("replacement-reused-pid"),
        processStatus: async (ownerPid, expectedIdentity) => {
          observedStatuses.push({ pid: ownerPid, expectedIdentity });
          return expectedIdentity === currentIdentity ? "alive" : "dead";
        },
      }),
    );
    expect(observedStatuses).toContainEqual({
      pid,
      expectedIdentity: previousIdentity,
    });
    await release();

    const sameIncarnationState = await stateFile();
    await writeLockOwner(sameIncarnationState.file, {
      pid,
      processIdentity: currentIdentity,
      token: lockToken("live-reused-pid"),
      createdAt: "2026-08-30T11:59:00.000Z",
    });
    await expect(
      acquireStateMutationLock(
        sameIncarnationState.directory,
        sameIncarnationState.file,
        "same incarnation fixture lock",
        lockOptions({
          pid,
          token: () => lockToken("contender-same-incarnation"),
          processStatus: async (ownerPid, expectedIdentity) => {
            expect(ownerPid).toBe(pid);
            expect(expectedIdentity).toBe(currentIdentity);
            return "alive";
          },
          attempts: 2,
        }),
      ),
    ).rejects.toThrow(/busy/);
  });

  it("leaves no canonical lock after install fsync failure and allows the next acquire", async () => {
    const { directory, file } = await stateFile();
    const parent = dirname(file);
    let failCanonicalSync = true;
    let canonicalPresentAtFailure = false;
    const syncDirectory = async (path: string) => {
      if (path === parent && failCanonicalSync) {
        canonicalPresentAtFailure = await lstat(`${file}.lock`)
          .then((stats) => stats.isDirectory())
          .catch(() => false);
        failCanonicalSync = false;
        throw errorWithCode("EIO");
      }
    };

    await expect(
      acquireStateMutationLock(
        directory,
        file,
        "install fsync failure fixture lock",
        lockOptions({
          pid: 70201,
          token: () => lockToken("failed-install"),
          syncDirectory,
        }),
      ),
    ).rejects.toMatchObject({ code: "EIO" });
    expect(canonicalPresentAtFailure).toBe(true);
    await expect(lstat(`${file}.lock`)).rejects.toMatchObject({
      code: "ENOENT",
    });

    const release = await acquireStateMutationLock(
      directory,
      file,
      "install fsync retry fixture lock",
      lockOptions({
        pid: 70202,
        token: () => lockToken("successful-retry"),
        syncDirectory,
      }),
    );
    expect((await lstat(`${file}.lock`)).isDirectory()).toBe(true);
    await release();
    await expect(lstat(`${file}.lock`)).rejects.toMatchObject({
      code: "ENOENT",
    });
  });

  it("retries release after its first namespace fsync failure and clears the tombstone", async () => {
    const { directory, file } = await stateFile();
    const parent = dirname(file);
    let failReleaseSync = false;
    const syncDirectory = async (path: string) => {
      if (path === parent && failReleaseSync) {
        failReleaseSync = false;
        throw errorWithCode("EIO");
      }
    };
    const release = await acquireStateMutationLock(
      directory,
      file,
      "first release fsync failure fixture lock",
      lockOptions({
        pid: 70301,
        token: () => lockToken("first-release-failure"),
        syncDirectory,
      }),
    );

    failReleaseSync = true;
    await expect(release()).rejects.toMatchObject({ code: "EIO" });
    await expect(lstat(`${file}.lock`)).rejects.toMatchObject({
      code: "ENOENT",
    });
    expect(
      (await readdir(parent)).filter((entry) =>
        entry.startsWith("state.json.lock.release-"),
      ),
    ).toHaveLength(1);

    await release();
    await expect(lstat(`${file}.lock`)).rejects.toMatchObject({
      code: "ENOENT",
    });
    expect(
      (await readdir(parent)).filter((entry) =>
        entry.startsWith("state.json.lock.release-"),
      ),
    ).toHaveLength(0);
  });

  it("retries release after its final namespace fsync failure and clears the tombstone", async () => {
    const { directory, file } = await stateFile();
    const parent = dirname(file);
    let releaseStarted = false;
    let releaseParentSyncs = 0;
    const syncDirectory = async (path: string) => {
      if (path !== parent || !releaseStarted) return;
      releaseParentSyncs += 1;
      if (releaseParentSyncs === 2) throw errorWithCode("EIO");
    };
    const release = await acquireStateMutationLock(
      directory,
      file,
      "final release fsync failure fixture lock",
      lockOptions({
        pid: 70401,
        token: () => lockToken("final-release-failure"),
        syncDirectory,
      }),
    );

    releaseStarted = true;
    await expect(release()).rejects.toMatchObject({ code: "EIO" });
    expect(releaseParentSyncs).toBe(2);
    await expect(lstat(`${file}.lock`)).rejects.toMatchObject({
      code: "ENOENT",
    });
    expect(
      (await readdir(parent)).filter((entry) =>
        entry.startsWith("state.json.lock.release-"),
      ),
    ).toHaveLength(0);

    await release();
    await expect(lstat(`${file}.lock`)).rejects.toMatchObject({
      code: "ENOENT",
    });
    expect(
      (await readdir(parent)).filter((entry) =>
        entry.startsWith("state.json.lock.release-"),
      ),
    ).toHaveLength(0);
  });

  it("fails closed for duplicate-key lock owner metadata", async () => {
    const { directory, file } = await stateFile();
    await mkdir(`${file}.lock`, { mode: 0o700 });
    await writeFile(
      join(`${file}.lock`, STATE_LOCK_OWNER_FILE),
      `{"version":2,"pid":70501,"processIdentity":"${fixtureProcessIdentity(
        70501,
      )}","token":"${lockToken(
        "duplicate-owner",
      )}","createdAt":"2026-08-30T11:59:00.000Z","pid":70502}\n`,
      { mode: 0o600 },
    );

    await expect(
      acquireStateMutationLock(
        directory,
        file,
        "duplicate owner fixture lock",
        lockOptions({
          pid: 70502,
          token: () => lockToken("duplicate-contender"),
          attempts: 2,
        }),
      ),
    ).rejects.toThrow(/busy/);
    expect((await lstat(`${file}.lock`)).isDirectory()).toBe(true);
  });

  it("ignores non-canonical crash residue when acquiring the canonical lock", async () => {
    const { directory, file } = await stateFile();
    const residue = `${file}.lock.candidate-crashed-residue`;
    await writeOwnerDirectory(residue, {
      pid: 70601,
      token: lockToken("crashed-candidate"),
      createdAt: "2026-08-30T11:59:00.000Z",
    });

    const release = await acquireStateMutationLock(
      directory,
      file,
      "non-canonical residue fixture lock",
      lockOptions({
        pid: 70602,
        token: () => lockToken("canonical-owner"),
      }),
    );
    const owner = JSON.parse(
      await readFile(join(`${file}.lock`, STATE_LOCK_OWNER_FILE), "utf8"),
    ) as { pid: number; processIdentity: string };
    expect(owner).toMatchObject({
      pid: 70602,
      processIdentity: fixtureProcessIdentity(70602),
    });
    await release();

    expect((await lstat(residue)).isDirectory()).toBe(true);
    await expect(lstat(`${file}.lock`)).rejects.toMatchObject({
      code: "ENOENT",
    });
  });

  it("syncs the namespace after lock install and release mutations", async () => {
    const { directory, file } = await stateFile();
    const parent = dirname(file);
    const calls: string[] = [];
    const release = await acquireStateMutationLock(
      directory,
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
    const { directory, file } = await stateFile();
    const parent = dirname(file);
    await writeLockOwner(file, {
      pid: 650,
      token: lockToken("stale-sync-owner-650"),
      createdAt: "2026-08-30T11:59:00.000Z",
    });
    const calls: string[] = [];
    const release = await acquireStateMutationLock(
      directory,
      file,
      "stale namespace sync fixture lock",
      lockOptions({
        syncDirectory: async (path) => {
          calls.push(path);
        },
        processStatus: async (pid, _expectedIdentity) =>
          pid === 650 ? "dead" : "alive",
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
