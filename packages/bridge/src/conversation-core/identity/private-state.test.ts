import {
  lstat,
  mkdir,
  mkdtemp,
  readFile,
  readdir,
  realpath,
  rename,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { createServer } from "node:net";
import { promisify } from "node:util";
import { afterEach, describe, expect, it } from "vitest";

import {
  acquirePrivateStateGenerationLease,
  acquireStateMutationLock,
  assertPrivateStatePlatformSupported,
  atomicPrivateWrite,
  defaultProcessStatus,
  LEGACY_STATE_LOCK_OWNER_FILE,
  parseDarwinBootTime,
  preparePrivateStateDirectory,
  readBoundedPrivateFile,
  releaseOrAbandonStateMutationLock,
  STATE_LOCK_OWNER_FILE,
  STATE_LOCK_RECLAIM_DIRECTORY,
  syncDirectoryForDurability,
  type PrivateStateDirectoryBinding,
  type StateMutationLockOptions,
} from "./private-state.js";

const execFileAsync = promisify(execFile);

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
    const directoryStatus = await lstat(directory);
    const processIdentity =
      owner.processIdentity ?? fixtureProcessIdentity(owner.pid);
    await writeFile(
      join(directory, STATE_LOCK_OWNER_FILE),
      `${JSON.stringify({
        version: 3,
        pid: owner.pid,
        processIdentity,
        token: owner.token,
        createdAt: owner.createdAt,
        directoryDevice: String(directoryStatus.dev),
        directoryInode: String(directoryStatus.ino),
      })}\n`,
      { mode: 0o600 },
    );
  }

  it("syncs every newly created state-directory namespace before returning", async () => {
    const root = await mkdtemp(
      join(tmpdir(), "ccpocket-v4-state-parent-sync-"),
    );
    roots.push(root);
    const target = join(root, "nested", "state");
    const synced: string[] = [];

    const binding = await preparePrivateStateDirectory(target, async (path) => {
      synced.push(path);
    });

    const canonicalRoot = await realpath(root);
    expect(binding.path).toBe(await realpath(target));
    expect(synced.slice(0, 2)).toEqual([
      join(canonicalRoot, "nested"),
      canonicalRoot,
    ]);
    expect(synced).toContain("/");
    expect(synced.at(-1)).toBe(binding.path);
  });

  it("reconciles the complete namespace chain after an earlier parent fsync failure", async () => {
    const root = await mkdtemp(
      join(tmpdir(), "ccpocket-v4-state-parent-retry-"),
    );
    roots.push(root);
    const target = join(root, "nested", "state");
    const canonicalRoot = await realpath(root);
    const failedParent = dirname(canonicalRoot);
    let shouldFail = true;
    const calls: string[] = [];
    const syncDirectory = async (path: string): Promise<void> => {
      calls.push(path);
      if (shouldFail && path === failedParent) {
        shouldFail = false;
        throw errorWithCode("EIO");
      }
    };

    await expect(
      preparePrivateStateDirectory(target, syncDirectory),
    ).rejects.toMatchObject({ code: "EIO" });
    expect(calls.filter((path) => path === failedParent)).toHaveLength(1);

    await preparePrivateStateDirectory(target, syncDirectory);
    expect(calls.filter((path) => path === failedParent)).toHaveLength(2);
  });

  it("removes a target ACL and rejects an inherited allow ACL in its ancestor", async () => {
    if (process.platform !== "darwin") return;
    const root = await mkdtemp(join(tmpdir(), "ccpocket-v4-state-acl-"));
    roots.push(root);
    const existingTarget = join(root, "existing");
    await mkdir(existingTarget, { mode: 0o700 });
    await execFileAsync("/bin/chmod", [
      "+a",
      "everyone allow read",
      existingTarget,
    ]);

    const binding = await preparePrivateStateDirectory(existingTarget);
    const secured = await execFileAsync("/bin/ls", ["-lde", existingTarget], {
      encoding: "utf8",
    });
    expect(secured.stdout).not.toMatch(/^\s*\d+:.*\ballow\b/mu);

    const privateFile = join(binding.path, "private.json");
    await writeFile(privateFile, "private", { mode: 0o600 });
    await execFileAsync("/bin/chmod", [
      "+a",
      "everyone allow read",
      privateFile,
    ]);
    await expect(
      readBoundedPrivateFile(binding, privateFile, 64, "ACL fixture"),
    ).resolves.toBe("private");
    const securedFile = await execFileAsync("/bin/ls", ["-lde", privateFile], {
      encoding: "utf8",
    });
    expect(securedFile.stdout).not.toMatch(/^\s*\d+:.*\ballow\b/mu);

    await execFileAsync("/bin/chmod", [
      "+a",
      "everyone allow list,search,add_file,add_subdirectory,delete_child,file_inherit,directory_inherit",
      root,
    ]);
    await expect(
      preparePrivateStateDirectory(join(root, "inherited")),
    ).rejects.toThrow(/ancestor.*ACL/iu);
  });

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

  it("rejects a lock snapshot assembled across two directory inodes", async () => {
    const { directory, file } = await stateFile();
    const lockPath = `${file}.lock`;
    const displaced = `${lockPath}.displaced`;
    await writeOwnerDirectory(lockPath, {
      pid: 81_001,
      token: lockToken("snapshot-owner-a"),
      createdAt: "2026-08-30T11:59:00.000Z",
    });
    let swapped = false;

    await expect(
      acquireStateMutationLock(
        directory,
        file,
        "mixed snapshot fixture lock",
        lockOptions({
          pid: 81_003,
          token: () => lockToken("snapshot-contender"),
          attempts: 1,
          beforeLockOwnerRead: async (observedLockPath) => {
            if (swapped || observedLockPath !== lockPath) return;
            swapped = true;
            await rename(lockPath, displaced);
            await writeOwnerDirectory(lockPath, {
              pid: 81_002,
              token: lockToken("snapshot-owner-b"),
              createdAt: "2026-08-30T11:59:30.000Z",
            });
          },
        }),
      ),
    ).rejects.toThrow(/busy/);

    expect(swapped).toBe(true);
    const replacement = JSON.parse(
      await readFile(join(lockPath, STATE_LOCK_OWNER_FILE), "utf8"),
    ) as { pid: number; token: string };
    const original = JSON.parse(
      await readFile(join(displaced, STATE_LOCK_OWNER_FILE), "utf8"),
    ) as { pid: number; token: string };
    expect(replacement).toMatchObject({
      pid: 81_002,
      token: lockToken("snapshot-owner-b"),
    });
    expect(original).toMatchObject({
      pid: 81_001,
      token: lockToken("snapshot-owner-a"),
    });
  });

  it("rejects an owner read from a transient A-to-B-to-A directory swap", async () => {
    const { directory, file } = await stateFile();
    const lockPath = `${file}.lock`;
    const displaced = `${lockPath}.displaced`;
    await writeOwnerDirectory(lockPath, {
      pid: 82_001,
      token: lockToken("aba-owner-a"),
      createdAt: "2026-08-30T11:59:00.000Z",
    });
    let swapped = false;
    let restored = false;

    await expect(
      acquireStateMutationLock(
        directory,
        file,
        "ABA snapshot fixture lock",
        lockOptions({
          pid: 82_003,
          token: () => lockToken("aba-contender"),
          attempts: 1,
          beforeLockOwnerRead: async (observedLockPath) => {
            if (swapped || observedLockPath !== lockPath) return;
            swapped = true;
            await rename(lockPath, displaced);
            await writeOwnerDirectory(lockPath, {
              pid: 82_002,
              token: lockToken("aba-owner-b"),
              createdAt: "2026-08-30T11:59:30.000Z",
            });
          },
          afterLockOwnerRead: async (observedLockPath) => {
            if (restored || observedLockPath !== lockPath) return;
            restored = true;
            await rm(lockPath, { recursive: true, force: true });
            await rename(displaced, lockPath);
          },
        }),
      ),
    ).rejects.toThrow(/busy/);

    expect(swapped).toBe(true);
    expect(restored).toBe(true);
    const owner = JSON.parse(
      await readFile(join(lockPath, STATE_LOCK_OWNER_FILE), "utf8"),
    ) as { pid: number; token: string };
    expect(owner).toMatchObject({
      pid: 82_001,
      token: lockToken("aba-owner-a"),
    });
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

  it("fails closed for a legacy owner without incarnation evidence", async () => {
    const { directory, file } = await stateFile();
    const legacyLock = `${file}.lock`;
    await mkdir(legacyLock, { mode: 0o700 });
    await writeFile(
      join(legacyLock, LEGACY_STATE_LOCK_OWNER_FILE),
      `${JSON.stringify({
        version: 1,
        pid: 2_000_000_001,
        token: lockToken("legacy-dead-owner"),
        createdAt: "2026-08-30T11:59:00.000Z",
      })}\n`,
      { mode: 0o600 },
    );

    await expect(
      acquireStateMutationLock(
        directory,
        file,
        "legacy owner fixture lock",
        lockOptions({
          pid: 2_000_000_002,
          token: () => lockToken("legacy-successor"),
          attempts: 1,
        }),
      ),
    ).rejects.toThrow(/busy/);
    expect((await lstat(legacyLock)).isDirectory()).toBe(true);
    expect(
      await readFile(join(legacyLock, LEGACY_STATE_LOCK_OWNER_FILE), "utf8"),
    ).toContain('"version":1');
  });

  it("does not reinterpret a previous owner schema as the bound current schema", async () => {
    const { directory, file } = await stateFile();
    const lockPath = `${file}.lock`;
    await mkdir(lockPath, { mode: 0o700 });
    await writeFile(
      join(lockPath, "owner-v2.json"),
      `${JSON.stringify({
        version: 2,
        pid: 2_000_000_101,
        processIdentity: fixtureProcessIdentity(2_000_000_101),
        token: lockToken("previous-owner"),
        createdAt: "2026-08-30T11:59:00.000Z",
      })}\n`,
      { mode: 0o600 },
    );

    await expect(
      acquireStateMutationLock(
        directory,
        file,
        "previous owner fixture lock",
        lockOptions({ attempts: 1 }),
      ),
    ).rejects.toThrow(/busy/);
    expect(await readFile(join(lockPath, "owner-v2.json"), "utf8")).toContain(
      lockToken("previous-owner"),
    );
  });

  it("does not let concurrent contenders reclaim a legacy lock", async () => {
    const { directory, file } = await stateFile();
    const legacyLock = `${file}.lock`;
    await mkdir(legacyLock, { mode: 0o700 });
    await writeFile(
      join(legacyLock, LEGACY_STATE_LOCK_OWNER_FILE),
      `${JSON.stringify({
        version: 1,
        pid: 2_000_000_201,
        token: lockToken("legacy-race-dead-owner"),
        createdAt: "2026-08-30T11:59:00.000Z",
      })}\n`,
      { mode: 0o600 },
    );
    let initialReaders = 0;
    let releaseReaders!: () => void;
    const readersReady = new Promise<void>((resolveReady) => {
      releaseReaders = resolveReady;
    });
    const beforeLockOwnerRead = async (lockPath: string): Promise<void> => {
      if (lockPath !== legacyLock || initialReaders >= 2) return;
      initialReaders += 1;
      if (initialReaders === 2) releaseReaders();
      await readersReady;
    };

    const attempts = await Promise.allSettled([
      acquireStateMutationLock(
        directory,
        file,
        "legacy race fixture lock",
        lockOptions({
          pid: 2_000_000_202,
          token: () => lockToken("legacy-race-a"),
          attempts: 1,
          beforeLockOwnerRead,
        }),
      ),
      acquireStateMutationLock(
        directory,
        file,
        "legacy race fixture lock",
        lockOptions({
          pid: 2_000_000_203,
          token: () => lockToken("legacy-race-b"),
          attempts: 1,
          beforeLockOwnerRead,
        }),
      ),
    ]);
    expect(attempts.every((result) => result.status === "rejected")).toBe(true);
    expect((await lstat(legacyLock)).isDirectory()).toBe(true);
    expect(
      await readFile(join(legacyLock, LEGACY_STATE_LOCK_OWNER_FILE), "utf8"),
    ).toContain(lockToken("legacy-race-dead-owner"));
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

  it("reprobes a live owner on a later retry and recovers after death", async () => {
    const { directory, file } = await stateFile();
    await writeLockOwner(file, {
      pid: 425,
      token: lockToken("dies-during-acquire"),
      createdAt: "2026-08-30T11:59:00.000Z",
    });
    let probes = 0;
    const release = await acquireStateMutationLock(
      directory,
      file,
      "owner death during acquire fixture lock",
      lockOptions({
        pid: 426,
        token: () => lockToken("post-death-contender"),
        attempts: 2,
        processStatus: async () => {
          probes += 1;
          return probes === 1 ? "alive" : "dead";
        },
      }),
    );
    expect(probes).toBeGreaterThanOrEqual(2);
    await release();
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
    const replacementDirectory = await lstat(`${file}.lock`);
    await writeFile(
      join(`${file}.lock`, STATE_LOCK_OWNER_FILE),
      `${JSON.stringify({
        version: 3,
        pid: 602,
        processIdentity: fixtureProcessIdentity(602, "replacement"),
        token: lockToken("replacement-owner-602"),
        createdAt: "2026-08-30T12:00:00.000Z",
        directoryDevice: String(replacementDirectory.dev),
        directoryInode: String(replacementDirectory.ino),
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
          const releaseDirectory = await lstat(join(parent, releaseEntry));
          await writeFile(
            join(parent, releaseEntry, STATE_LOCK_OWNER_FILE),
            `${JSON.stringify({
              version: 3,
              pid: 604,
              processIdentity: fixtureProcessIdentity(604, "replacement"),
              token: lockToken("replacement-owner-604"),
              createdAt: "2026-08-30T12:00:00.000Z",
              directoryDevice: String(releaseDirectory.dev),
              directoryInode: String(releaseDirectory.ino),
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

  it("quarantines a reclaim rollback unreadable after restore rename", async () => {
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
                "{malformed\n",
                { mode: 0o600 },
              );
            }
          },
        }),
      ),
    ).rejects.toMatchObject({ code: "EIO" });

    await expect(lstat(`${file}.lock`)).rejects.toMatchObject({
      code: "ENOENT",
    });
    const quarantine = (await readdir(parent)).filter((entry) =>
      entry.startsWith("state.json.lock.changed-restore-"),
    );
    expect(quarantine).toHaveLength(1);
    expect(
      await readFile(
        join(parent, quarantine[0]!, STATE_LOCK_OWNER_FILE),
        "utf8",
      ),
    ).toBe("{malformed\n");
  });

  it("reclaims a stale lock for a reused PID only when its process identity differs", async () => {
    const staleState = await stateFile();
    const pid = 70101;
    const currentIdentity = fixtureProcessIdentity(pid);
    const previousIdentity = fixtureProcessIdentity(
      pid,
      "previous-incarnation",
    );
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

  it("quarantines a canonical lock when its first installed snapshot cannot be read", async () => {
    const { directory, file } = await stateFile();
    const parent = dirname(file);
    let failed = false;
    await expect(
      acquireStateMutationLock(
        directory,
        file,
        "installed snapshot failure fixture lock",
        lockOptions({
          pid: 70203,
          token: () => lockToken("snapshot-read-failure"),
          beforeInstalledSnapshotRead: async (lockPath) => {
            if (lockPath !== `${file}.lock` || failed) return;
            failed = true;
            throw errorWithCode("EIO");
          },
        }),
      ),
    ).rejects.toMatchObject({ code: "EIO" });
    await expect(lstat(`${file}.lock`)).rejects.toMatchObject({
      code: "ENOENT",
    });
    expect(
      (await readdir(parent)).filter((entry) =>
        entry.startsWith("state.json.lock.failed-install-"),
      ),
    ).toHaveLength(1);
  });

  it("releases a restored nested reclaim claim after outer namespace sync failure", async () => {
    const { directory, file } = await stateFile();
    const parent = dirname(file);
    await writeLockOwner(file, {
      pid: 70204,
      token: lockToken("outer-stale-owner"),
      createdAt: "2026-08-30T11:59:00.000Z",
    });
    let failed = false;
    await expect(
      acquireStateMutationLock(
        directory,
        file,
        "outer reclaim sync failure fixture lock",
        lockOptions({
          pid: 70205,
          token: () => lockToken("outer-reclaim-contender"),
          processStatus: async (pid) => (pid === 70204 ? "dead" : "alive"),
          syncDirectory: async (path) => {
            if (path !== parent || failed) return;
            const entries = await readdir(parent);
            if (
              entries.some((entry) =>
                entry.startsWith("state.json.lock.stale-"),
              )
            ) {
              failed = true;
              throw errorWithCode("EIO");
            }
          },
        }),
      ),
    ).rejects.toMatchObject({ code: "EIO" });
    expect(failed).toBe(true);
    expect((await lstat(`${file}.lock`)).isDirectory()).toBe(true);
    await expect(
      lstat(join(`${file}.lock`, STATE_LOCK_RECLAIM_DIRECTORY)),
    ).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("recovers an orphaned internal reclaim claim before the next admission", async () => {
    const { directory, file } = await stateFile();
    const lockPath = `${file}.lock`;
    await writeLockOwner(file, {
      pid: 70208,
      token: lockToken("internal-claim-stale-owner"),
      createdAt: "2026-08-30T11:59:00.000Z",
    });
    let outerOwnerReads = 0;
    let ownerChanged = false;
    let injectCleanupFailure = true;
    let cleanupFailed = false;
    const syncDirectory = async (path: string): Promise<void> => {
      if (
        injectCleanupFailure &&
        !cleanupFailed &&
        ownerChanged &&
        path === lockPath
      ) {
        cleanupFailed = true;
        throw errorWithCode("CLAIM-CLEANUP-EIO");
      }
    };
    await expect(
      acquireStateMutationLock(
        directory,
        file,
        "internal reclaim claim cleanup fixture lock",
        lockOptions({
          pid: 70209,
          token: () => lockToken("internal-claim-contender"),
          attempts: 1,
          syncDirectory,
          processStatus: async () => "dead",
          beforeLockOwnerRead: async (observedLockPath) => {
            if (observedLockPath !== lockPath) return;
            outerOwnerReads += 1;
            if (outerOwnerReads !== 2) return;
            const status = await lstat(lockPath);
            await writeFile(
              join(lockPath, STATE_LOCK_OWNER_FILE),
              `${JSON.stringify({
                version: 3,
                pid: 70208,
                processIdentity: fixtureProcessIdentity(70208),
                token: lockToken("internal-claim-changed-owner"),
                createdAt: "2026-08-30T11:59:00.000Z",
                directoryDevice: String(status.dev),
                directoryInode: String(status.ino),
              })}\n`,
              { mode: 0o600 },
            );
            ownerChanged = true;
          },
        }),
      ),
    ).rejects.toMatchObject({ code: "CLAIM-CLEANUP-EIO" });
    expect(cleanupFailed).toBe(true);

    injectCleanupFailure = false;
    const release = await acquireStateMutationLock(
      directory,
      file,
      "internal reclaim claim cleanup fixture lock",
      lockOptions({
        pid: 70210,
        token: () => lockToken("internal-claim-successor"),
        syncDirectory,
        processStatus: async () => "dead",
      }),
    );
    expect((await lstat(lockPath)).isDirectory()).toBe(true);
    await release();
  });

  it("reclaims an old-boot owner even when wall clock moved backwards", async () => {
    const { directory, file } = await stateFile();
    await writeLockOwner(file, {
      pid: 70206,
      token: lockToken("future-old-boot-owner"),
      createdAt: "2026-09-01T12:00:00.000Z",
    });
    const release = await acquireStateMutationLock(
      directory,
      file,
      "old boot rollback fixture lock",
      lockOptions({
        now: () => Date.UTC(2026, 7, 30, 12),
        pid: 70207,
        token: () => lockToken("old-boot-successor"),
        processStatus: async (pid) =>
          pid === 70206 ? "dead-old-boot" : "alive",
      }),
    );
    await release();
  });

  it("keeps legacy Darwin process identities safe across the proc-v3 upgrade", async () => {
    if (process.platform !== "darwin") return;
    const probeState = await stateFile();
    const probeRelease = await acquireStateMutationLock(
      probeState.directory,
      probeState.file,
      "Darwin process identity probe",
      {
        attempts: 2,
        retryMs: 0,
        token: () => lockToken("darwin-proc-v3-probe"),
      },
    );
    const currentOwner = JSON.parse(
      await readFile(
        join(`${probeState.file}.lock`, STATE_LOCK_OWNER_FILE),
        "utf8",
      ),
    ) as { processIdentity: string };
    await probeRelease();
    const parts = currentOwner.processIdentity.split(":");
    expect(parts.slice(0, 2)).toEqual(["proc-v3", "darwin"]);
    const machine = parts[2]!;
    const boot = parts[3]!;
    const oldHeadIdentity = `proc-v1:darwin:${machine}:${boot}:legacy-start`;

    const deadState = await stateFile();
    await writeLockOwner(deadState.file, {
      pid: 2_000_000_101,
      processIdentity: oldHeadIdentity,
      token: lockToken("old-head-dead"),
      createdAt: "2026-08-30T11:59:00.000Z",
    });
    const deadRelease = await acquireStateMutationLock(
      deadState.directory,
      deadState.file,
      "Old HEAD dead Darwin owner",
      {
        attempts: 2,
        retryMs: 0,
        staleGraceMs: 0,
        token: () => lockToken("old-head-dead-successor"),
      },
    );
    await deadRelease();

    const oldBootState = await stateFile();
    const otherBoot = boot === "A".repeat(43) ? "B".repeat(43) : "A".repeat(43);
    await writeLockOwner(oldBootState.file, {
      pid: process.pid,
      processIdentity: `proc-v1:darwin:${machine}:${otherBoot}:legacy-start`,
      token: lockToken("old-head-old-boot"),
      createdAt: "2027-08-30T11:59:00.000Z",
    });
    await expect(
      acquireStateMutationLock(
        oldBootState.directory,
        oldBootState.file,
        "Old HEAD ambiguous-boot Darwin owner",
        {
          attempts: 1,
          retryMs: 0,
          token: () => lockToken("old-head-old-boot-successor"),
        },
      ),
    ).rejects.toThrow(/busy/);

    const liveState = await stateFile();
    await writeLockOwner(liveState.file, {
      pid: process.pid,
      processIdentity: oldHeadIdentity,
      token: lockToken("old-head-live"),
      createdAt: "2026-08-30T11:59:00.000Z",
    });
    await expect(
      acquireStateMutationLock(
        liveState.directory,
        liveState.file,
        "Old HEAD live Darwin owner",
        {
          attempts: 1,
          retryMs: 0,
          staleGraceMs: 0,
          token: () => lockToken("old-head-live-contender"),
        },
      ),
    ).rejects.toThrow(/busy/);

    const procV2State = await stateFile();
    await writeLockOwner(procV2State.file, {
      pid: process.pid,
      processIdentity: [
        "proc-v2",
        "darwin",
        machine,
        otherBoot,
        parts[4],
        parts[5],
        parts[6],
      ].join(":"),
      token: lockToken("proc-v2-live-witness"),
      createdAt: "2026-08-30T11:59:00.000Z",
    });
    await expect(
      acquireStateMutationLock(
        procV2State.directory,
        procV2State.file,
        "proc-v2 live Darwin witness",
        {
          attempts: 1,
          retryMs: 0,
          staleGraceMs: 0,
          token: () => lockToken("proc-v2-live-contender"),
        },
      ),
    ).rejects.toThrow(/busy/);
  });

  it("derives the Darwin boot scope only from numeric timeval fields", () => {
    expect(
      parseDarwinBootTime(
        "{ sec = 1788312825, usec = 494293 } Wed Sep  2 09:33:45 2026",
      ),
    ).toBe("1788312825:494293");
    expect(
      parseDarwinBootTime(
        "{ sec = 1788312825, usec = 494293 } Wed Sep  2 01:33:45 2026",
      ),
    ).toBe("1788312825:494293");
    expect(
      parseDarwinBootTime("{ sec = 1788312825, usec = 1 } localized suffix"),
    ).toBe("1788312825:000001");
    expect(parseDarwinBootTime("unstructured boot time")).toBeUndefined();
  });

  it("probes a foreign Darwin witness even when it shares the current PID", async () => {
    if (process.platform !== "darwin") return;
    const probeState = await stateFile();
    const probeRelease = await acquireStateMutationLock(
      probeState.directory,
      probeState.file,
      "Darwin worker witness identity probe",
      { attempts: 1, retryMs: 0 },
    );
    const currentOwner = JSON.parse(
      await readFile(
        join(`${probeState.file}.lock`, STATE_LOCK_OWNER_FILE),
        "utf8",
      ),
    ) as { processIdentity: string };
    await probeRelease();
    const parts = currentOwner.processIdentity.split(":");
    const token = randomBytes(32).toString("base64url");
    const server = createServer((socket) => {
      let input = "";
      socket.setEncoding("utf8");
      socket.on("data", (chunk: string) => {
        input += chunk;
        const newline = input.indexOf("\n");
        if (newline < 0) return;
        const challenge = input.slice(0, newline);
        const response = createHmac("sha256", token)
          .update(challenge, "utf8")
          .digest("base64url");
        socket.end(`${response}\n`);
      });
    });
    await new Promise<void>((resolveListening, rejectListening) => {
      server.once("error", rejectListening);
      server.listen({ host: "127.0.0.1", port: 0 }, resolveListening);
    });
    try {
      const address = server.address();
      if (address === null || typeof address === "string") {
        throw new Error("fixture witness did not bind TCP");
      }
      const foreignWorkerIdentity = [
        "proc-v3",
        "darwin",
        parts[2],
        parts[3],
        String(process.pid),
        String(address.port),
        token,
      ].join(":");
      await expect(
        defaultProcessStatus(process.pid, foreignWorkerIdentity),
      ).resolves.toBe("alive");
    } finally {
      await new Promise<void>((resolveClose) => server.close(resolveClose));
    }
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

  it("recovers an explicitly orphaned mutation release before reacquiring", async () => {
    const { directory, file } = await stateFile();
    let failReleaseRead = true;
    const options = lockOptions({
      beforeReleaseSnapshotRead: async (lockPath) => {
        if (failReleaseRead && lockPath === `${file}.lock`) {
          failReleaseRead = false;
          throw errorWithCode("EIO");
        }
      },
    });
    const first = await acquireStateMutationLock(
      directory,
      file,
      "orphan mutation fixture lock",
      options,
    );

    await expect(first()).rejects.toMatchObject({ code: "EIO" });
    expect((await lstat(`${file}.lock`)).isDirectory()).toBe(true);
    await first.abandon();

    const second = await acquireStateMutationLock(
      directory,
      file,
      "orphan mutation fixture lock",
      options,
    );
    expect((await lstat(`${file}.lock`)).isDirectory()).toBe(true);
    await second();
  });

  it("recovers a tombstoned mutation orphan before generation residue collection", async () => {
    const { directory, file } = await stateFile();
    roots.push(`${directory.path}.lifecycle-v1`);
    const parent = dirname(file);
    let releaseStarted = false;
    let failed = false;
    const syncDirectory = async (path: string): Promise<void> => {
      if (releaseStarted && !failed && path === parent) {
        failed = true;
        throw errorWithCode("EIO");
      }
    };
    const options = lockOptions({ syncDirectory });
    const release = await acquireStateMutationLock(
      directory,
      file,
      "generation orphan ordering fixture lock",
      options,
    );

    releaseStarted = true;
    await expect(
      releaseOrAbandonStateMutationLock(release),
    ).rejects.toMatchObject({ code: "EIO" });
    const tombstones = (await readdir(parent)).filter((entry) =>
      entry.startsWith("state.json.lock.release-"),
    );
    expect(tombstones).toHaveLength(1);

    const generation = await acquirePrivateStateGenerationLease(
      directory,
      "bridge-identity",
      options,
    );
    expect(
      (await readdir(parent)).filter((entry) =>
        entry.startsWith("state.json.lock.release-"),
      ),
    ).toHaveLength(0);
    const next = await acquireStateMutationLock(
      directory,
      file,
      "generation orphan ordering fixture lock",
      options,
    );
    await next();
    await generation.release();
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

  it("collects only exact non-authoritative residue at generation start", async () => {
    const { directory, file } = await stateFile();
    const lifecyclePath = `${directory.path}.lifecycle-v1`;
    roots.push(lifecyclePath);
    await mkdir(lifecyclePath, { mode: 0o700 });
    await writeFile(file, "authority", { mode: 0o600 });
    const uuid = "11111111-1111-4111-8111-111111111111";
    const token = lockToken("residue-owner-token");
    const residue = [
      `${file}.tmp-123-${uuid}`,
      `${file}.lock.candidate-123-${token}-${uuid}`,
      `${file}.lock.stale-${token}-${uuid}`,
      `${file}.lock.legacy-stale-${token}-${uuid}`,
      `${file}.lock.release-${token}-${uuid}`,
      `${file}.lock.failed-install-${uuid}`,
      `${file}.lock.changed-restore-${uuid}`,
      `${file}.lock.release-${token}-${uuid}.gc-${uuid}`,
    ];
    await writeFile(residue[0]!, "temporary", { mode: 0o600 });
    for (const path of residue.slice(1)) {
      await mkdir(path, { mode: 0o700 });
    }
    const lifecycleResidue = join(
      lifecyclePath,
      `.private-state-generation.writer-lease.lock.release-${token}-${uuid}`,
    );
    await mkdir(lifecycleResidue, { mode: 0o700 });
    const preserved = `${file}.lock.candidate-crashed-residue`;
    await mkdir(preserved, { mode: 0o700 });

    const lease = await acquirePrivateStateGenerationLease(
      directory,
      "bridge-identity",
    );

    expect(await readFile(file, "utf8")).toBe("authority");
    expect((await lstat(preserved)).isDirectory()).toBe(true);
    for (const path of [...residue, lifecycleResidue]) {
      await expect(lstat(path)).rejects.toMatchObject({ code: "ENOENT" });
    }
    await lease.release();
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

  it("serializes the last generation holder release with a new acquire", async () => {
    const { directory } = await stateFile();
    roots.push(`${directory.path}.lifecycle-v1`);
    let shouldBlock = false;
    let unblockRelease!: () => void;
    const releaseGate = new Promise<void>((resolveGate) => {
      unblockRelease = resolveGate;
    });
    let releaseBlocked!: () => void;
    const blocked = new Promise<void>((resolveBlocked) => {
      releaseBlocked = resolveBlocked;
    });
    let didBlock = false;
    const syncDirectory = async (path: string): Promise<void> => {
      if (shouldBlock && !didBlock && path.endsWith(".lifecycle-v1")) {
        didBlock = true;
        releaseBlocked();
        await releaseGate;
      }
    };
    const first = await acquirePrivateStateGenerationLease(
      directory,
      "bridge-identity",
      lockOptions({ syncDirectory }),
    );
    shouldBlock = true;
    const closing = first.release();
    await blocked;

    let reopened = false;
    const pending = acquirePrivateStateGenerationLease(
      directory,
      "bridge-identity",
      lockOptions({ syncDirectory }),
    ).then((lease) => {
      reopened = true;
      return lease;
    });
    await new Promise((resolveImmediate) => setImmediate(resolveImmediate));
    expect(reopened).toBe(false);

    unblockRelease();
    await closing;
    const second = await pending;
    expect((await lstat(second.writerLeaseFile)).isDirectory()).toBe(true);
    await expect(
      acquirePrivateStateGenerationLease(
        directory,
        "bridge-identity",
        lockOptions({ syncDirectory }),
      ),
    ).rejects.toThrow(/generation is already open/);
    await second.release();
  });

  it("finishes a failed physical release before admitting another holder kind", async () => {
    const { directory } = await stateFile();
    const lifecyclePath = `${directory.path}.lifecycle-v1`;
    roots.push(lifecyclePath);
    let failRelease = false;
    let releaseFailures = 0;
    const syncDirectory = async (path: string): Promise<void> => {
      if (failRelease && releaseFailures < 2 && path === lifecyclePath) {
        releaseFailures += 1;
        throw errorWithCode("EIO");
      }
    };
    const first = await acquirePrivateStateGenerationLease(
      directory,
      "bridge-identity",
      lockOptions({ syncDirectory }),
    );

    failRelease = true;
    await expect(first.release()).rejects.toMatchObject({ code: "EIO" });
    await expect(
      acquirePrivateStateGenerationLease(
        directory,
        "bridge-installation",
        lockOptions({ syncDirectory }),
      ),
    ).rejects.toMatchObject({ code: "EIO" });
    expect(releaseFailures).toBe(2);
    failRelease = false;
    const second = await acquirePrivateStateGenerationLease(
      directory,
      "bridge-installation",
      lockOptions({ syncDirectory }),
    );

    expect((await lstat(second.writerLeaseFile)).isDirectory()).toBe(true);
    await first.release();
    await second.release();
  });

  it("invalidates a generation when its lifecycle directory is replaced", async () => {
    const { directory } = await stateFile();
    const lifecyclePath = `${directory.path}.lifecycle-v1`;
    const displaced = `${lifecyclePath}.displaced`;
    roots.push(lifecyclePath, displaced);
    const lease = await acquirePrivateStateGenerationLease(
      directory,
      "bridge-identity",
      lockOptions(),
    );

    await rename(lifecyclePath, displaced);
    await mkdir(lifecyclePath, { mode: 0o700 });

    await expect(lease.assertCurrent()).rejects.toThrow(
      /state directory changed after binding/,
    );
    await expect(
      acquirePrivateStateGenerationLease(
        directory,
        "bridge-installation",
        lockOptions(),
      ),
    ).rejects.toThrow(/state directory changed after binding/);
  });

  it("lets a later acquire finish an orphaned failed-load generation cleanup", async () => {
    const { directory } = await stateFile();
    roots.push(`${directory.path}.lifecycle-v1`);
    let failRelease = false;
    let failed = false;
    const syncDirectory = async (path: string): Promise<void> => {
      if (failRelease && !failed && path.endsWith(".lifecycle-v1")) {
        failed = true;
        throw errorWithCode("EIO");
      }
    };
    const first = await acquirePrivateStateGenerationLease(
      directory,
      "bridge-installation",
      lockOptions({ syncDirectory }),
    );
    failRelease = true;
    await expect(first.release()).rejects.toMatchObject({ code: "EIO" });
    await first.abandon();

    failRelease = false;
    const second = await acquirePrivateStateGenerationLease(
      directory,
      "bridge-installation",
      lockOptions({ syncDirectory }),
    );
    expect((await lstat(second.writerLeaseFile)).isDirectory()).toBe(true);
    await second.release();
  });
});

describe("syncDirectoryForDurability", () => {
  it("rejects Windows private state until a secure durable backend exists", () => {
    expect(() => assertPrivateStatePlatformSupported("win32")).toThrow(
      /unavailable on Windows/,
    );
    expect(() => assertPrivateStatePlatformSupported("darwin")).not.toThrow();
  });
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

  it("fails closed when Windows has no native directory durability backend", async () => {
    await expect(
      syncDirectoryForDurability("fixture", {
        platform: "win32",
        openDirectory: async () => {
          throw errorWithCode("EPERM");
        },
      }),
    ).rejects.toThrow(/requires a supported native backend/);

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
    ).rejects.toThrow(/requires a supported native backend/);
    expect(closed).toBe(true);
  });

  it("reports unknown Windows directory-sync failures as unsupported durability", async () => {
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
    ).rejects.toThrow(/requires a supported native backend/);
  });
});
import { execFile } from "node:child_process";
import { createHmac, randomBytes } from "node:crypto";
