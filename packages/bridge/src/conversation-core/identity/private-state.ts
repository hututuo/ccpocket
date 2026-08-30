import { randomUUID } from "node:crypto";
import { constants } from "node:fs";
import {
  chmod,
  lstat,
  mkdir,
  open,
  realpath,
  rename,
  rm,
} from "node:fs/promises";
import { dirname, join, resolve } from "node:path";

const PRIVATE_DIRECTORY_MODE = 0o700;
const PRIVATE_FILE_MODE = 0o600;
const DEFAULT_LOCK_ATTEMPTS = 400;
const DEFAULT_LOCK_RETRY_MS = 5;
const DEFAULT_STALE_LOCK_GRACE_MS = 1_000;
const MAX_LOCK_OWNER_BYTES = 4 * 1024;
const LOCK_OWNER_VERSION = 1 as const;
const LOCK_TOKEN_PATTERN = /^[A-Za-z0-9_-]{16,128}$/;
const WINDOWS_UNSUPPORTED_DIRECTORY_SYNC_ERRORS = new Set([
  "EISDIR",
  "EINVAL",
  "ENOTSUP",
  "EPERM",
]);

export const STATE_LOCK_OWNER_FILE = "owner-v1.json" as const;
export const STATE_LOCK_RECLAIM_DIRECTORY = "reclaim-v1" as const;

interface StateLockOwner {
  version: typeof LOCK_OWNER_VERSION;
  pid: number;
  token: string;
  createdAt: string;
}

interface LockSnapshot {
  owner: StateLockOwner;
  device: number;
  inode: number;
}

export type ProcessStatus = "alive" | "dead" | "unknown";

export interface StateMutationLockOptions {
  now?: () => number;
  pid?: number;
  token?: () => string;
  processStatus?: (pid: number) => ProcessStatus;
  staleGraceMs?: number;
  attempts?: number;
  retryMs?: number;
  syncDirectory?: DirectorySync;
}

export interface DirectorySyncHandle {
  sync(): Promise<void>;
  close(): Promise<void>;
}

export type DirectorySync = (path: string) => Promise<void>;

export interface DirectorySyncOptions {
  platform?: NodeJS.Platform;
  openDirectory?: (path: string) => Promise<DirectorySyncHandle>;
}

function isMissing(error: unknown): boolean {
  return (error as NodeJS.ErrnoException).code === "ENOENT";
}

async function pathExists(path: string): Promise<boolean> {
  try {
    await lstat(path);
    return true;
  } catch (error) {
    if (isMissing(error)) return false;
    throw error;
  }
}

function modeOf(mode: number): number {
  return mode & 0o777;
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function hasExactKeys(
  value: Record<string, unknown>,
  keys: readonly string[],
): boolean {
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  return (
    actual.length === expected.length &&
    actual.every((key, index) => key === expected[index])
  );
}

function isCanonicalTimestamp(value: string): boolean {
  const parsed = new Date(value);
  return !Number.isNaN(parsed.valueOf()) && parsed.toISOString() === value;
}

function defaultProcessStatus(pid: number): ProcessStatus {
  try {
    process.kill(pid, 0);
    return "alive";
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code;
    if (code === "ESRCH") return "dead";
    return "unknown";
  }
}

async function pause(milliseconds: number): Promise<void> {
  await new Promise((resolvePause) => setTimeout(resolvePause, milliseconds));
}

export async function preparePrivateStateDirectory(
  path: string,
): Promise<string> {
  const absolutePath = resolve(path);
  await mkdir(absolutePath, { recursive: true, mode: PRIVATE_DIRECTORY_MODE });
  const before = await lstat(absolutePath);
  if (before.isSymbolicLink() || !before.isDirectory()) {
    throw new Error(
      "Conversation identity state directory must be a real directory",
    );
  }
  await chmod(absolutePath, PRIVATE_DIRECTORY_MODE);
  const after = await lstat(absolutePath);
  if (
    after.isSymbolicLink() ||
    !after.isDirectory() ||
    (process.platform !== "win32" &&
      modeOf(after.mode) !== PRIVATE_DIRECTORY_MODE)
  ) {
    throw new Error("Conversation identity state directory is not private");
  }
  return realpath(absolutePath);
}

export async function readBoundedPrivateFile(
  path: string,
  maximumBytes: number,
  description: string,
): Promise<string | undefined> {
  let handle: Awaited<ReturnType<typeof open>> | undefined;
  try {
    try {
      const stats = await lstat(path);
      if (stats.isSymbolicLink() || !stats.isFile()) {
        throw new Error(`${description} must be a private regular file`);
      }
    } catch (error) {
      if (isMissing(error)) return undefined;
      throw error;
    }

    try {
      handle = await open(
        path,
        constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0),
      );
    } catch (error) {
      if (isMissing(error)) return undefined;
      throw new Error(`${description} cannot be opened safely`, {
        cause: error,
      });
    }

    const before = await handle.stat();
    if (!before.isFile()) {
      throw new Error(`${description} must be a private regular file`);
    }
    if (before.size > maximumBytes) {
      throw new Error(`${description} exceeds its size limit`);
    }

    await handle.chmod(PRIVATE_FILE_MODE);
    const secured = await handle.stat();
    if (
      !secured.isFile() ||
      (process.platform !== "win32" &&
        modeOf(secured.mode) !== PRIVATE_FILE_MODE)
    ) {
      throw new Error(`${description} is not private`);
    }

    const contents = Buffer.alloc(maximumBytes + 1);
    let offset = 0;
    while (offset < contents.length) {
      const result = await handle.read(
        contents,
        offset,
        contents.length - offset,
        offset,
      );
      if (result.bytesRead === 0) break;
      offset += result.bytesRead;
    }
    if (offset > maximumBytes) {
      throw new Error(`${description} exceeds its size limit`);
    }
    return contents.subarray(0, offset).toString("utf8");
  } finally {
    await handle?.close().catch(() => undefined);
  }
}

function isUnsupportedWindowsDirectorySyncError(error: unknown): boolean {
  return WINDOWS_UNSUPPORTED_DIRECTORY_SYNC_ERRORS.has(
    (error as NodeJS.ErrnoException).code ?? "",
  );
}

export async function syncDirectoryForDurability(
  path: string,
  options: DirectorySyncOptions = {},
): Promise<void> {
  const platform = options.platform ?? process.platform;
  const openDirectory =
    options.openDirectory ??
    (async (directoryPath: string) => open(directoryPath, constants.O_RDONLY));
  let handle: DirectorySyncHandle;
  try {
    handle = await openDirectory(path);
  } catch (error) {
    if (platform === "win32" && isUnsupportedWindowsDirectorySyncError(error))
      return;
    throw error;
  }
  try {
    try {
      await handle.sync();
    } catch (error) {
      if (!(
        platform === "win32" && isUnsupportedWindowsDirectorySyncError(error)
      )) {
        throw error;
      }
    }
  } finally {
    await handle.close();
  }
}

export async function atomicPrivateWrite(
  path: string,
  contents: string,
  maximumBytes: number,
  description: string,
  options: { syncDirectory?: DirectorySync } = {},
): Promise<void> {
  if (Buffer.byteLength(contents, "utf8") > maximumBytes) {
    throw new Error(`${description} exceeds its size limit`);
  }

  const directory = dirname(path);
  const temporary = `${path}.tmp-${process.pid}-${randomUUID()}`;
  let handle: Awaited<ReturnType<typeof open>> | undefined;
  try {
    handle = await open(temporary, "wx", PRIVATE_FILE_MODE);
    await handle.writeFile(contents, "utf8");
    await handle.chmod(PRIVATE_FILE_MODE);
    await handle.sync();
    await handle.close();
    handle = undefined;
    await rename(temporary, path);
    await (options.syncDirectory ?? syncDirectoryForDurability)(directory);
  } finally {
    await handle?.close().catch(() => undefined);
    await rm(temporary, { force: true }).catch(() => undefined);
  }
}

async function syncParentDirectory(
  path: string,
  syncDirectory: DirectorySync,
): Promise<void> {
  await syncDirectory(dirname(path));
}

function serializeLockOwner(owner: StateLockOwner): string {
  return `${JSON.stringify(owner)}\n`;
}

function parseLockOwner(contents: string): StateLockOwner | undefined {
  let parsed: unknown;
  try {
    parsed = JSON.parse(contents);
  } catch {
    return undefined;
  }
  if (
    !isPlainObject(parsed) ||
    !hasExactKeys(parsed, ["version", "pid", "token", "createdAt"]) ||
    parsed.version !== LOCK_OWNER_VERSION ||
    typeof parsed.pid !== "number" ||
    !Number.isSafeInteger(parsed.pid) ||
    parsed.pid <= 0 ||
    typeof parsed.token !== "string" ||
    !LOCK_TOKEN_PATTERN.test(parsed.token) ||
    typeof parsed.createdAt !== "string" ||
    !isCanonicalTimestamp(parsed.createdAt)
  ) {
    return undefined;
  }
  return {
    version: LOCK_OWNER_VERSION,
    pid: parsed.pid,
    token: parsed.token,
    createdAt: parsed.createdAt,
  };
}

async function readLockSnapshot(
  lockPath: string,
): Promise<LockSnapshot | undefined> {
  let stats: Awaited<ReturnType<typeof lstat>>;
  try {
    stats = await lstat(lockPath);
  } catch (error) {
    if (isMissing(error)) return undefined;
    throw error;
  }
  if (
    stats.isSymbolicLink() ||
    !stats.isDirectory() ||
    (process.platform !== "win32" &&
      modeOf(stats.mode) !== PRIVATE_DIRECTORY_MODE)
  ) {
    throw new Error(
      "Conversation identity lock is not a private real directory",
    );
  }
  const ownerContents = await readBoundedPrivateFile(
    join(lockPath, STATE_LOCK_OWNER_FILE),
    MAX_LOCK_OWNER_BYTES,
    "Conversation identity lock owner",
  );
  if (ownerContents === undefined) {
    throw new Error("Conversation identity lock owner is missing");
  }
  const owner = parseLockOwner(ownerContents);
  if (!owner) throw new Error("Conversation identity lock owner is invalid");
  return { owner, device: stats.dev, inode: stats.ino };
}

function snapshotsMatch(left: LockSnapshot, right: LockSnapshot): boolean {
  return (
    left.device === right.device &&
    left.inode === right.inode &&
    left.owner.pid === right.owner.pid &&
    left.owner.token === right.owner.token &&
    left.owner.createdAt === right.owner.createdAt
  );
}

async function tryInstallPreparedLock(
  lockPath: string,
  owner: StateLockOwner,
  syncDirectory: DirectorySync,
): Promise<boolean> {
  const candidate = `${lockPath}.candidate-${owner.pid}-${owner.token}-${randomUUID()}`;
  let candidateExists = false;
  try {
    await mkdir(candidate, { mode: PRIVATE_DIRECTORY_MODE });
    candidateExists = true;
    await atomicPrivateWrite(
      join(candidate, STATE_LOCK_OWNER_FILE),
      serializeLockOwner(owner),
      MAX_LOCK_OWNER_BYTES,
      "Conversation identity lock owner",
      { syncDirectory },
    );
    try {
      await rename(candidate, lockPath);
      candidateExists = false;
    } catch (error) {
      try {
        await lstat(lockPath);
        return false;
      } catch (destinationError) {
        if (!isMissing(destinationError)) throw destinationError;
        throw error;
      }
    }
    await syncParentDirectory(lockPath, syncDirectory);
    return true;
  } finally {
    if (candidateExists) {
      await rm(candidate, { recursive: true, force: true })
        .then(() => syncParentDirectory(candidate, syncDirectory))
        .catch(() => undefined);
    }
  }
}

async function restoreTombstone(
  tombstone: string,
  lockPath: string,
  syncDirectory: DirectorySync,
): Promise<boolean> {
  try {
    // Never use rename's POSIX replacement semantics against a lock that may
    // have been re-created while the tombstone was inspected.
    if (await pathExists(lockPath)) return false;
    await rename(tombstone, lockPath);
    await syncParentDirectory(lockPath, syncDirectory);
    return true;
  } catch {
    // Never delete an object whose ownership changed while it was being inspected.
    return false;
  }
}

function isStaleDeadSnapshot(
  snapshot: LockSnapshot,
  options: Required<
    Pick<StateMutationLockOptions, "now" | "processStatus" | "staleGraceMs">
  >,
): boolean {
  const age = options.now() - Date.parse(snapshot.owner.createdAt);
  return (
    age >= options.staleGraceMs &&
    options.processStatus(snapshot.owner.pid) === "dead"
  );
}

async function tryReclaimUnclaimedDeadDirectory(
  lockPath: string,
  claimantToken: string,
  syncDirectory: DirectorySync,
  options: Required<
    Pick<StateMutationLockOptions, "now" | "processStatus" | "staleGraceMs">
  >,
): Promise<boolean> {
  let snapshot: LockSnapshot | undefined;
  try {
    snapshot = await readLockSnapshot(lockPath);
  } catch {
    return false;
  }
  if (!snapshot) return true;
  if (!isStaleDeadSnapshot(snapshot, options)) return false;

  const tombstone = `${lockPath}.stale-${claimantToken}-${randomUUID()}`;
  try {
    await rename(lockPath, tombstone);
  } catch (error) {
    if (isMissing(error)) return true;
    return false;
  }
  await syncParentDirectory(lockPath, syncDirectory);

  let moved: LockSnapshot | undefined;
  try {
    moved = await readLockSnapshot(tombstone);
  } catch {
    await restoreTombstone(tombstone, lockPath, syncDirectory);
    return false;
  }
  if (!moved || !snapshotsMatch(snapshot, moved)) {
    await restoreTombstone(tombstone, lockPath, syncDirectory);
    return false;
  }
  await rm(tombstone, { recursive: true, force: true });
  await syncParentDirectory(tombstone, syncDirectory);
  return true;
}

async function tryAcquireReclaimClaim(
  lockPath: string,
  claimant: StateLockOwner,
  syncDirectory: DirectorySync,
  options: Required<
    Pick<StateMutationLockOptions, "now" | "processStatus" | "staleGraceMs">
  >,
): Promise<boolean> {
  const claimPath = join(lockPath, STATE_LOCK_RECLAIM_DIRECTORY);
  try {
    if (!(await pathExists(claimPath))) {
      return tryInstallPreparedLock(claimPath, claimant, syncDirectory);
    }
    const reclaimed = await tryReclaimUnclaimedDeadDirectory(
      claimPath,
      claimant.token,
      syncDirectory,
      options,
    );
    return (
      reclaimed &&
      (await pathExists(lockPath)) &&
      !(await pathExists(claimPath)) &&
      (await tryInstallPreparedLock(claimPath, claimant, syncDirectory))
    );
  } catch (error) {
    if (isMissing(error)) return false;
    throw error;
  }
}

async function tryReclaimDeadLock(
  lockPath: string,
  claimant: StateLockOwner,
  syncDirectory: DirectorySync,
  options: Required<
    Pick<StateMutationLockOptions, "now" | "processStatus" | "staleGraceMs">
  >,
): Promise<boolean> {
  let snapshot: LockSnapshot | undefined;
  try {
    snapshot = await readLockSnapshot(lockPath);
  } catch {
    return false;
  }
  if (!snapshot) return true;
  if (!isStaleDeadSnapshot(snapshot, options)) return false;
  if (
    !(await tryAcquireReclaimClaim(lockPath, claimant, syncDirectory, options))
  ) {
    return false;
  }

  const claimPath = join(lockPath, STATE_LOCK_RECLAIM_DIRECTORY);
  let claimMovedWithLock = false;
  let claimSnapshot: LockSnapshot | undefined;
  try {
    const current = await readLockSnapshot(lockPath);
    const claim = await readLockSnapshot(claimPath);
    claimSnapshot = claim;
    if (
      !current ||
      !claim ||
      !snapshotsMatch(snapshot, current) ||
      claim.owner.pid !== claimant.pid ||
      claim.owner.token !== claimant.token ||
      !isStaleDeadSnapshot(current, options)
    ) {
      await releaseOwnedLock(claimPath, claimant, claim, syncDirectory).catch(
        () => undefined,
      );
      return false;
    }

    const tombstone = `${lockPath}.stale-${claimant.token}-${randomUUID()}`;
    try {
      await rename(lockPath, tombstone);
      claimMovedWithLock = true;
    } catch (error) {
      if (isMissing(error)) return true;
      return false;
    }
    await syncParentDirectory(lockPath, syncDirectory);

    let moved: LockSnapshot | undefined;
    let movedClaim: LockSnapshot | undefined;
    try {
      moved = await readLockSnapshot(tombstone);
      movedClaim = await readLockSnapshot(
        join(tombstone, STATE_LOCK_RECLAIM_DIRECTORY),
      );
    } catch {
      if (await restoreTombstone(tombstone, lockPath, syncDirectory)) {
        claimMovedWithLock = false;
      }
      return false;
    }
    if (
      !moved ||
      !movedClaim ||
      !snapshotsMatch(snapshot, moved) ||
      !snapshotsMatch(claim, movedClaim)
    ) {
      if (await restoreTombstone(tombstone, lockPath, syncDirectory)) {
        claimMovedWithLock = false;
      }
      return false;
    }
    await rm(tombstone, { recursive: true, force: true });
    await syncParentDirectory(tombstone, syncDirectory);
    return true;
  } finally {
    if (
      !claimMovedWithLock &&
      (await pathExists(claimPath).catch(() => false))
    ) {
      await releaseOwnedLock(
        claimPath,
        claimant,
        claimSnapshot,
        syncDirectory,
      ).catch(() => undefined);
    }
  }
}

async function releaseOwnedLock(
  lockPath: string,
  owner: StateLockOwner,
  expectedSnapshot: LockSnapshot | undefined,
  syncDirectory: DirectorySync,
): Promise<void> {
  const snapshot = await readLockSnapshot(lockPath);
  if (
    !snapshot ||
    !snapshotsMatchOwner(snapshot, owner) ||
    (expectedSnapshot !== undefined &&
      !snapshotsMatch(expectedSnapshot, snapshot))
  ) {
    throw new Error(
      "Conversation identity lock ownership changed before release",
    );
  }
  const tombstone = `${lockPath}.release-${owner.token}-${randomUUID()}`;
  await rename(lockPath, tombstone);
  try {
    await syncParentDirectory(lockPath, syncDirectory);
  } catch (error) {
    await restoreTombstone(tombstone, lockPath, syncDirectory).catch(
      () => false,
    );
    throw error;
  }
  let moved: LockSnapshot | undefined;
  try {
    moved = await readLockSnapshot(tombstone);
  } catch {
    await restoreTombstone(tombstone, lockPath, syncDirectory);
    throw new Error(
      "Conversation identity lock ownership changed during release",
    );
  }
  if (!moved || !snapshotsMatch(snapshot, moved)) {
    await restoreTombstone(tombstone, lockPath, syncDirectory);
    throw new Error(
      "Conversation identity lock ownership changed during release",
    );
  }
  await rm(tombstone, { recursive: true, force: true });
  await syncParentDirectory(tombstone, syncDirectory);
}

function snapshotsMatchOwner(
  snapshot: LockSnapshot,
  owner: StateLockOwner,
): boolean {
  return (
    snapshot.owner.pid === owner.pid && snapshot.owner.token === owner.token
  );
}

function createLockRelease(
  lockPath: string,
  owner: StateLockOwner,
  expectedSnapshot: LockSnapshot,
  syncDirectory: DirectorySync,
): () => Promise<void> {
  let released = false;
  return async () => {
    if (released) return;
    await releaseOwnedLock(lockPath, owner, expectedSnapshot, syncDirectory);
    released = true;
  };
}

export async function acquireStateMutationLock(
  stateFile: string,
  description: string,
  options: StateMutationLockOptions = {},
): Promise<() => Promise<void>> {
  const lockPath = `${stateFile}.lock`;
  const syncDirectory = options.syncDirectory ?? syncDirectoryForDurability;
  const owner: StateLockOwner = {
    version: LOCK_OWNER_VERSION,
    pid: options.pid ?? process.pid,
    token: (options.token ?? randomUUID)(),
    createdAt: new Date((options.now ?? Date.now)()).toISOString(),
  };
  if (
    !Number.isSafeInteger(owner.pid) ||
    owner.pid <= 0 ||
    !LOCK_TOKEN_PATTERN.test(owner.token)
  ) {
    throw new Error("Conversation identity lock owner options are invalid");
  }
  const attempts = options.attempts ?? DEFAULT_LOCK_ATTEMPTS;
  const retryMs = options.retryMs ?? DEFAULT_LOCK_RETRY_MS;
  const reclaimOptions = {
    now: options.now ?? Date.now,
    processStatus: options.processStatus ?? defaultProcessStatus,
    staleGraceMs: options.staleGraceMs ?? DEFAULT_STALE_LOCK_GRACE_MS,
  };

  for (let attempt = 0; attempt < attempts; attempt += 1) {
    if (
      !(await pathExists(lockPath)) &&
      (await tryInstallPreparedLock(lockPath, owner, syncDirectory))
    ) {
      const snapshot = await readLockSnapshot(lockPath);
      if (!snapshot || !snapshotsMatchOwner(snapshot, owner)) {
        throw new Error(
          "Conversation identity lock could not be bound after acquire",
        );
      }
      return createLockRelease(lockPath, owner, snapshot, syncDirectory);
    }
    const reclaimed = await tryReclaimDeadLock(
      lockPath,
      owner,
      syncDirectory,
      reclaimOptions,
    );
    if (
      reclaimed &&
      !(await pathExists(lockPath)) &&
      (await tryInstallPreparedLock(lockPath, owner, syncDirectory))
    ) {
      const snapshot = await readLockSnapshot(lockPath);
      if (!snapshot || !snapshotsMatchOwner(snapshot, owner)) {
        throw new Error(
          "Conversation identity lock could not be bound after reclaim",
        );
      }
      return createLockRelease(lockPath, owner, snapshot, syncDirectory);
    }
    if (attempt + 1 < attempts) await pause(retryMs);
  }
  throw new Error(`${description} is busy`);
}

export const STATE_WRITER_LEASE_SUFFIX = ".writer-lease" as const;

export function acquireStateWriterLease(
  stateFile: string,
  description: string,
  options: StateMutationLockOptions = {},
): Promise<() => Promise<void>> {
  return acquireStateMutationLock(
    `${stateFile}${STATE_WRITER_LEASE_SUFFIX}`,
    description,
    options,
  );
}
