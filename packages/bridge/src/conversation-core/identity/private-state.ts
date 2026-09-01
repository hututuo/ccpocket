import { createHash, randomUUID } from "node:crypto";
import { execFile } from "node:child_process";
import { constants } from "node:fs";
import {
  chmod,
  link,
  lstat,
  mkdir,
  open,
  readFile,
  readlink,
  realpath,
  rename,
  rm,
  unlink,
} from "node:fs/promises";
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { promisify } from "node:util";

const PRIVATE_DIRECTORY_MODE = 0o700;
const PRIVATE_FILE_MODE = 0o600;
const DEFAULT_LOCK_ATTEMPTS = 400;
const DEFAULT_LOCK_RETRY_MS = 5;
const DEFAULT_STALE_LOCK_GRACE_MS = 1_000;
const MAX_LOCK_OWNER_BYTES = 4 * 1024;
const LOCK_OWNER_VERSION = 2 as const;
const LOCK_TOKEN_PATTERN = /^[A-Za-z0-9_-]{16,128}$/;
const PROCESS_IDENTITY_PATTERN = /^[A-Za-z0-9:._+\-/=]{8,1024}$/;
const execFileAsync = promisify(execFile);
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
  processIdentity: string;
  token: string;
  createdAt: string;
}

interface LockSnapshot {
  owner: StateLockOwner;
  device: number;
  inode: number;
}

export type ProcessStatus = "alive" | "dead" | "unknown";

export interface PrivateStateDirectoryBinding {
  readonly path: string;
  readonly device: number;
  readonly inode: number;
}

export type ProcessIdentityResolver = (
  pid: number,
) => Promise<string | undefined>;

export type ProcessStatusResolver = (
  pid: number,
  expectedProcessIdentity: string,
) => ProcessStatus | Promise<ProcessStatus>;

export interface StateMutationLockOptions {
  now?: () => number;
  pid?: number;
  token?: () => string;
  processIdentity?: ProcessIdentityResolver;
  processStatus?: ProcessStatusResolver;
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

export interface BoundedPrivateFileReadOptions {
  beforeOpen?: () => Promise<void>;
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

function sameFileIdentity(
  left: { dev: number; ino: number },
  right: { dev: number; ino: number },
): boolean {
  return left.dev === right.dev && left.ino === right.ino;
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

function skipJsonWhitespace(contents: string, offset: number): number {
  while (
    offset < contents.length &&
    /[\u0009\u000a\u000d\u0020]/u.test(contents[offset]!)
  ) {
    offset += 1;
  }
  return offset;
}

function scanJsonString(
  contents: string,
  offset: number,
): { readonly next: number; readonly value: string } {
  if (contents[offset] !== '"') throw new SyntaxError("expected JSON string");
  const start = offset;
  offset += 1;
  while (offset < contents.length) {
    const character = contents[offset]!;
    if (character === '"') {
      const next = offset + 1;
      return { next, value: JSON.parse(contents.slice(start, next)) as string };
    }
    if (character === "\\") {
      offset += 1;
      if (offset >= contents.length) throw new SyntaxError("truncated JSON escape");
      if (contents[offset] === "u") {
        const codePoint = contents.slice(offset + 1, offset + 5);
        if (!/^[0-9a-fA-F]{4}$/u.test(codePoint)) {
          throw new SyntaxError("invalid JSON unicode escape");
        }
        offset += 4;
      }
    } else if (character.charCodeAt(0) < 0x20) {
      throw new SyntaxError("invalid JSON control character");
    }
    offset += 1;
  }
  throw new SyntaxError("unterminated JSON string");
}

function scanJsonValue(
  contents: string,
  initialOffset: number,
  depth: number,
): number {
  if (depth > 64) throw new SyntaxError("JSON state nesting is too deep");
  let offset = skipJsonWhitespace(contents, initialOffset);
  const character = contents[offset];
  if (character === '"') return scanJsonString(contents, offset).next;
  if (character === "{") {
    offset = skipJsonWhitespace(contents, offset + 1);
    const keys = new Set<string>();
    if (contents[offset] === "}") return offset + 1;
    while (offset < contents.length) {
      const key = scanJsonString(contents, offset);
      if (keys.has(key.value)) throw new SyntaxError("duplicate JSON object key");
      keys.add(key.value);
      offset = skipJsonWhitespace(contents, key.next);
      if (contents[offset] !== ":") throw new SyntaxError("expected JSON colon");
      offset = scanJsonValue(contents, offset + 1, depth + 1);
      offset = skipJsonWhitespace(contents, offset);
      if (contents[offset] === "}") return offset + 1;
      if (contents[offset] !== ",") throw new SyntaxError("expected JSON comma");
      offset = skipJsonWhitespace(contents, offset + 1);
    }
    throw new SyntaxError("unterminated JSON object");
  }
  if (character === "[") {
    offset = skipJsonWhitespace(contents, offset + 1);
    if (contents[offset] === "]") return offset + 1;
    while (offset < contents.length) {
      offset = scanJsonValue(contents, offset, depth + 1);
      offset = skipJsonWhitespace(contents, offset);
      if (contents[offset] === "]") return offset + 1;
      if (contents[offset] !== ",") throw new SyntaxError("expected JSON comma");
      offset = skipJsonWhitespace(contents, offset + 1);
    }
    throw new SyntaxError("unterminated JSON array");
  }
  const start = offset;
  while (
    offset < contents.length &&
    !/[\u0009\u000a\u000d\u0020,}\]]/u.test(contents[offset]!)
  ) {
    offset += 1;
  }
  if (offset === start) throw new SyntaxError("expected JSON value");
  JSON.parse(contents.slice(start, offset));
  return offset;
}

export function parseJsonWithoutDuplicateKeys(contents: string): unknown {
  const end = skipJsonWhitespace(contents, scanJsonValue(contents, 0, 0));
  if (end !== contents.length) throw new SyntaxError("trailing JSON data");
  return JSON.parse(contents);
}

function isCanonicalTimestamp(value: string): boolean {
  const parsed = new Date(value);
  return !Number.isNaN(parsed.valueOf()) && parsed.toISOString() === value;
}

interface ProcessIdentityParts {
  readonly machineScope: string;
  readonly bootScope: string;
  readonly processScope: string;
}

function parseProcessIdentity(value: string): ProcessIdentityParts | undefined {
  const parts = value.split(":");
  if (parts.length < 5 || parts[0] !== "proc-v1") return undefined;
  return {
    machineScope: parts.slice(0, 3).join(":"),
    bootScope: parts.slice(0, 4).join(":"),
    processScope: parts.slice(0, -1).join(":"),
  };
}

function encodeProcessIdentity(
  platform: string,
  machine: string,
  boot: string,
  started: string,
  namespace?: string,
): string {
  const digest = (value: string) =>
    createHash("sha256").update(value, "utf8").digest("base64url");
  return [
    "proc-v1",
    platform,
    digest(machine),
    digest(boot),
    ...(namespace === undefined ? [] : [digest(namespace)]),
    digest(started),
  ].join(":");
}

async function linuxProcessIdentity(pid: number): Promise<string | undefined> {
  try {
    const [machineId, bootId, namespace, stat] = await Promise.all([
      readFile("/etc/machine-id", "utf8"),
      readFile("/proc/sys/kernel/random/boot_id", "utf8"),
      readlink(`/proc/${pid}/ns/pid`),
      readFile(`/proc/${pid}/stat`, "utf8"),
    ]);
    const closingParenthesis = stat.lastIndexOf(")");
    if (closingParenthesis < 0) return undefined;
    const fieldsAfterCommand = stat
      .slice(closingParenthesis + 1)
      .trim()
      .split(/\s+/u);
    const startTicks = fieldsAfterCommand[19];
    if (!startTicks || !/^\d+$/u.test(startTicks)) return undefined;
    return encodeProcessIdentity(
      "linux",
      machineId.trim(),
      bootId.trim(),
      startTicks,
      namespace,
    );
  } catch {
    return undefined;
  }
}

async function darwinProcessIdentity(pid: number): Promise<string | undefined> {
  try {
    const [machine, boot, started] = await Promise.all([
      execFileAsync(
        "/usr/sbin/ioreg",
        ["-rd1", "-c", "IOPlatformExpertDevice"],
        { encoding: "utf8", timeout: 2_000, maxBuffer: 64 * 1024 },
      ),
      execFileAsync("/usr/sbin/sysctl", ["-n", "kern.boottime"], {
        encoding: "utf8",
        timeout: 2_000,
        maxBuffer: 4 * 1024,
      }),
      execFileAsync("/bin/ps", ["-o", "lstart=", "-p", String(pid)], {
        encoding: "utf8",
        timeout: 2_000,
        maxBuffer: 4 * 1024,
      }),
    ]);
    const machineMatch = machine.stdout.match(
      /"IOPlatformUUID"\s*=\s*"([^"]+)"/u,
    );
    const machineValue = machineMatch?.[1]?.trim();
    const bootValue = boot.stdout.trim().replace(/\s+/gu, "_");
    const startedValue = started.stdout.trim().replace(/\s+/gu, "_");
    if (!machineValue || !bootValue || !startedValue) return undefined;
    return encodeProcessIdentity(
      "darwin",
      machineValue,
      bootValue,
      startedValue,
    );
  } catch {
    return undefined;
  }
}

async function windowsProcessIdentity(pid: number): Promise<string | undefined> {
  const powershell = join(
    process.env.SystemRoot ?? "C:\\Windows",
    "System32",
    "WindowsPowerShell",
    "v1.0",
    "powershell.exe",
  );
  const command = [
    `$p = Get-Process -Id ${pid} -ErrorAction Stop`,
    "$os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop",
    "$machine = (Get-ItemProperty " +
      "'HKLM:\\SOFTWARE\\Microsoft\\Cryptography' " +
      "-Name MachineGuid -ErrorAction Stop).MachineGuid",
    "Write-Output ($machine + ':' + " +
      "$os.LastBootUpTime.ToUniversalTime().Ticks.ToString() + ':' + " +
      "$p.StartTime.ToUniversalTime().Ticks.ToString())",
  ].join("; ");
  try {
    const result = await execFileAsync(
      powershell,
      ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", command],
      { encoding: "utf8", timeout: 5_000, maxBuffer: 4 * 1024 },
    );
    const value = result.stdout.trim();
    const [machine, boot, started] = value.split(":");
    if (
      !machine ||
      !/^\d+$/u.test(boot ?? "") ||
      !/^\d+$/u.test(started ?? "")
    ) {
      return undefined;
    }
    return encodeProcessIdentity("win32", machine, boot!, started!);
  } catch {
    return undefined;
  }
}

async function defaultProcessIdentity(pid: number): Promise<string | undefined> {
  if (!Number.isSafeInteger(pid) || pid <= 0) return undefined;
  if (process.platform === "linux") return linuxProcessIdentity(pid);
  if (process.platform === "darwin") return darwinProcessIdentity(pid);
  if (process.platform === "win32") return windowsProcessIdentity(pid);
  return undefined;
}

let currentProcessIdentityPromise: Promise<string | undefined> | undefined;

function currentProcessIdentity(
  resolver: ProcessIdentityResolver,
): Promise<string | undefined> {
  if (resolver !== defaultProcessIdentity) return resolver(process.pid);
  currentProcessIdentityPromise ??= resolver(process.pid);
  return currentProcessIdentityPromise;
}

async function defaultProcessStatus(
  pid: number,
  expectedProcessIdentity: string,
): Promise<ProcessStatus> {
  const expected = parseProcessIdentity(expectedProcessIdentity);
  const currentIdentity = await currentProcessIdentity(defaultProcessIdentity);
  const current =
    currentIdentity === undefined
      ? undefined
      : parseProcessIdentity(currentIdentity);
  if (!expected || !current) return "unknown";
  if (expected.machineScope !== current.machineScope) return "unknown";
  if (expected.bootScope !== current.bootScope) return "dead";
  if (expected.processScope !== current.processScope) return "unknown";
  if (pid === process.pid) {
    return currentIdentity === expectedProcessIdentity ? "alive" : "dead";
  }
  const observed = await defaultProcessIdentity(pid);
  if (observed === undefined) {
    try {
      process.kill(pid, 0);
      return "unknown";
    } catch (error) {
      return (error as NodeJS.ErrnoException).code === "ESRCH"
        ? "dead"
        : "unknown";
    }
  }
  const observedParts = parseProcessIdentity(observed);
  if (!observedParts || observedParts.processScope !== expected.processScope) {
    return "unknown";
  }
  return observed === expectedProcessIdentity ? "alive" : "dead";
}

async function pause(milliseconds: number): Promise<void> {
  await new Promise((resolvePause) => setTimeout(resolvePause, milliseconds));
}

export async function preparePrivateStateDirectory(
  path: string,
): Promise<PrivateStateDirectoryBinding> {
  const absolutePath = resolve(path);
  await mkdir(absolutePath, { recursive: true, mode: PRIVATE_DIRECTORY_MODE });
  const before = await lstat(absolutePath);
  if (before.isSymbolicLink() || !before.isDirectory()) {
    throw new Error(
      "Conversation identity state directory must be a real directory",
    );
  }
  const canonicalPath = await realpath(absolutePath);
  const rebound = await lstat(absolutePath);
  const canonicalBefore = await lstat(canonicalPath);
  if (
    rebound.isSymbolicLink() ||
    !rebound.isDirectory() ||
    !canonicalBefore.isDirectory() ||
    !sameFileIdentity(before, rebound) ||
    !sameFileIdentity(before, canonicalBefore)
  ) {
    throw new Error(
      "Conversation identity state directory changed while binding",
    );
  }
  await chmod(canonicalPath, PRIVATE_DIRECTORY_MODE);
  const after = await lstat(canonicalPath);
  const finalPath = await lstat(absolutePath);
  if (
    after.isSymbolicLink() ||
    !after.isDirectory() ||
    finalPath.isSymbolicLink() ||
    !finalPath.isDirectory() ||
    !sameFileIdentity(before, after) ||
    !sameFileIdentity(before, finalPath) ||
    (process.platform !== "win32" &&
      modeOf(after.mode) !== PRIVATE_DIRECTORY_MODE)
  ) {
    throw new Error("Conversation identity state directory is not private");
  }
  return Object.freeze({
    path: canonicalPath,
    device: after.dev,
    inode: after.ino,
  });
}

export async function assertPrivateStateDirectory(
  binding: PrivateStateDirectoryBinding,
): Promise<void> {
  const current = await lstat(binding.path);
  if (
    current.isSymbolicLink() ||
    !current.isDirectory() ||
    current.dev !== binding.device ||
    current.ino !== binding.inode ||
    (process.platform !== "win32" &&
      modeOf(current.mode) !== PRIVATE_DIRECTORY_MODE)
  ) {
    throw new Error(
      "Conversation identity state directory changed after binding",
    );
  }
}

function assertPathWithinBinding(
  binding: PrivateStateDirectoryBinding,
  path: string,
): void {
  const pathFromBinding = relative(binding.path, resolve(path));
  if (
    pathFromBinding.length === 0 ||
    isAbsolute(pathFromBinding) ||
    pathFromBinding === ".." ||
    pathFromBinding.startsWith(`..${sep}`)
  ) {
    throw new Error(
      "Conversation identity state path escapes its bound directory",
    );
  }
}

export async function readBoundedPrivateFile(
  directory: PrivateStateDirectoryBinding,
  path: string,
  maximumBytes: number,
  description: string,
  options: BoundedPrivateFileReadOptions = {},
): Promise<string | undefined> {
  assertPathWithinBinding(directory, path);
  await assertPrivateStateDirectory(directory);
  let handle: Awaited<ReturnType<typeof open>> | undefined;
  let pathStats: Awaited<ReturnType<typeof lstat>>;
  try {
    try {
      pathStats = await lstat(path);
      if (pathStats.isSymbolicLink() || !pathStats.isFile()) {
        throw new Error(`${description} must be a private regular file`);
      }
    } catch (error) {
      if (isMissing(error)) {
        await assertPrivateStateDirectory(directory);
        return undefined;
      }
      throw error;
    }

    await options.beforeOpen?.();
    await assertPrivateStateDirectory(directory);

    try {
      handle = await open(
        path,
        constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0),
      );
    } catch (error) {
      throw new Error(`${description} cannot be opened safely`, {
        cause: error,
      });
    }

    const before = await handle.stat();
    if (!before.isFile() || !sameFileIdentity(pathStats, before)) {
      throw new Error(`${description} changed while being opened`);
    }
    if (before.size > maximumBytes) {
      throw new Error(`${description} exceeds its size limit`);
    }

    await handle.chmod(PRIVATE_FILE_MODE);
    const secured = await handle.stat();
    if (
      !secured.isFile() ||
      !sameFileIdentity(before, secured) ||
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
    const value = contents.subarray(0, offset).toString("utf8");
    await assertPrivateStateDirectory(directory);
    return value;
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

export async function confirmPrivateStateDirectoryDurability(
  directory: PrivateStateDirectoryBinding,
  syncDirectory: DirectorySync = syncDirectoryForDurability,
): Promise<void> {
  await assertPrivateStateDirectory(directory);
  await syncDirectory(directory.path);
  await assertPrivateStateDirectory(directory);
}

export async function atomicPrivateWrite(
  directoryBinding: PrivateStateDirectoryBinding,
  path: string,
  contents: string,
  maximumBytes: number,
  description: string,
  options: { syncDirectory?: DirectorySync; createOnly?: boolean } = {},
): Promise<void> {
  assertPathWithinBinding(directoryBinding, path);
  await assertPrivateStateDirectory(directoryBinding);
  if (Buffer.byteLength(contents, "utf8") > maximumBytes) {
    throw new Error(`${description} exceeds its size limit`);
  }

  const directory = dirname(path);
  const temporary = `${path}.tmp-${process.pid}-${randomUUID()}`;
  let handle: Awaited<ReturnType<typeof open>> | undefined;
  let temporaryExists = false;
  try {
    handle = await open(temporary, "wx", PRIVATE_FILE_MODE);
    temporaryExists = true;
    await handle.writeFile(contents, "utf8");
    await handle.chmod(PRIVATE_FILE_MODE);
    await handle.sync();
    const prepared = await handle.stat();
    await handle.close();
    handle = undefined;
    await assertPrivateStateDirectory(directoryBinding);
    if (options.createOnly) {
      await link(temporary, path);
      const installed = await lstat(path);
      if (
        installed.isSymbolicLink() ||
        !installed.isFile() ||
        !sameFileIdentity(prepared, installed)
      ) {
        throw new Error(`${description} changed during create-only install`);
      }
      await unlink(temporary);
      temporaryExists = false;
    } else {
      await rename(temporary, path);
      temporaryExists = false;
    }
    await (options.syncDirectory ?? syncDirectoryForDurability)(directory);
    await assertPrivateStateDirectory(directoryBinding);
  } finally {
    await handle?.close().catch(() => undefined);
    if (temporaryExists) {
      await rm(temporary, { force: true }).catch(() => undefined);
    }
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
    parsed = parseJsonWithoutDuplicateKeys(contents);
  } catch {
    return undefined;
  }
  if (
    !isPlainObject(parsed) ||
    !hasExactKeys(parsed, [
      "version",
      "pid",
      "processIdentity",
      "token",
      "createdAt",
    ]) ||
    parsed.version !== LOCK_OWNER_VERSION ||
    typeof parsed.pid !== "number" ||
    !Number.isSafeInteger(parsed.pid) ||
    parsed.pid <= 0 ||
    typeof parsed.processIdentity !== "string" ||
    !PROCESS_IDENTITY_PATTERN.test(parsed.processIdentity) ||
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
    processIdentity: parsed.processIdentity,
    token: parsed.token,
    createdAt: parsed.createdAt,
  };
}

async function readLockSnapshot(
  directory: PrivateStateDirectoryBinding,
  lockPath: string,
): Promise<LockSnapshot | undefined> {
  assertPathWithinBinding(directory, lockPath);
  await assertPrivateStateDirectory(directory);
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
    directory,
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
    left.owner.processIdentity === right.owner.processIdentity &&
    left.owner.token === right.owner.token &&
    left.owner.createdAt === right.owner.createdAt
  );
}

async function quarantineExactLock(
  directory: PrivateStateDirectoryBinding,
  lockPath: string,
  expectedSnapshot: LockSnapshot,
  reason: "failed-install" | "changed-restore",
  syncDirectory: DirectorySync,
): Promise<boolean> {
  const current = await readLockSnapshot(directory, lockPath).catch(
    () => undefined,
  );
  if (!current || !snapshotsMatch(expectedSnapshot, current)) return false;
  const quarantine = `${lockPath}.${reason}-${randomUUID()}`;
  try {
    await rename(lockPath, quarantine);
  } catch {
    return false;
  }
  await syncParentDirectory(lockPath, syncDirectory).catch(() => undefined);
  const moved = await readLockSnapshot(directory, quarantine).catch(
    () => undefined,
  );
  return (
    moved !== undefined &&
    snapshotsMatch(expectedSnapshot, moved) &&
    !(await pathExists(lockPath).catch(() => true))
  );
}

async function tryInstallPreparedLock(
  directory: PrivateStateDirectoryBinding,
  lockPath: string,
  owner: StateLockOwner,
  syncDirectory: DirectorySync,
): Promise<boolean> {
  await assertPrivateStateDirectory(directory);
  const candidate = `${lockPath}.candidate-${owner.pid}-${owner.token}-${randomUUID()}`;
  let candidateExists = false;
  try {
    await mkdir(candidate, { mode: PRIVATE_DIRECTORY_MODE });
    candidateExists = true;
    await atomicPrivateWrite(
      directory,
      join(candidate, STATE_LOCK_OWNER_FILE),
      serializeLockOwner(owner),
      MAX_LOCK_OWNER_BYTES,
      "Conversation identity lock owner",
      { syncDirectory, createOnly: true },
    );
    try {
      await assertPrivateStateDirectory(directory);
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
    const installed = await readLockSnapshot(directory, lockPath);
    if (!installed || !snapshotsMatchOwner(installed, owner)) {
      throw new Error("Conversation identity lock changed during install");
    }
    try {
      await syncParentDirectory(lockPath, syncDirectory);
      await assertPrivateStateDirectory(directory);
    } catch (error) {
      const quarantined = await quarantineExactLock(
        directory,
        lockPath,
        installed,
        "failed-install",
        syncDirectory,
      );
      if (!quarantined) {
        throw new Error(
          "Conversation identity lock install failed and could not be quarantined",
          { cause: error },
        );
      }
      throw error;
    }
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
  directory: PrivateStateDirectoryBinding,
  tombstone: string,
  lockPath: string,
  expectedSnapshot: LockSnapshot,
  syncDirectory: DirectorySync,
): Promise<boolean> {
  try {
    await assertPrivateStateDirectory(directory);
    const tombstoneSnapshot = await readLockSnapshot(directory, tombstone);
    if (
      !tombstoneSnapshot ||
      !snapshotsMatch(expectedSnapshot, tombstoneSnapshot)
    ) {
      return false;
    }
    // Never use rename's POSIX replacement semantics against a lock that may
    // have been re-created while the tombstone was inspected.
    if (await pathExists(lockPath)) return false;
    await rename(tombstone, lockPath);
    await syncParentDirectory(lockPath, syncDirectory);
    const restored = await readLockSnapshot(directory, lockPath);
    if (restored !== undefined && snapshotsMatch(expectedSnapshot, restored)) {
      return true;
    }
    if (
      restored !== undefined &&
      restored.device === expectedSnapshot.device &&
      restored.inode === expectedSnapshot.inode
    ) {
      await quarantineExactLock(
        directory,
        lockPath,
        restored,
        "changed-restore",
        syncDirectory,
      );
    }
    return false;
  } catch {
    // Never delete an object whose ownership changed while it was being inspected.
    return false;
  }
}

async function isStaleDeadSnapshot(
  snapshot: LockSnapshot,
  options: Required<
    Pick<StateMutationLockOptions, "now" | "processStatus" | "staleGraceMs">
  >,
): Promise<boolean> {
  const age = options.now() - Date.parse(snapshot.owner.createdAt);
  return (
    age >= options.staleGraceMs &&
    (await options.processStatus(
      snapshot.owner.pid,
      snapshot.owner.processIdentity,
    )) === "dead"
  );
}

async function tryReclaimUnclaimedDeadDirectory(
  directory: PrivateStateDirectoryBinding,
  lockPath: string,
  claimantToken: string,
  syncDirectory: DirectorySync,
  options: Required<
    Pick<StateMutationLockOptions, "now" | "processStatus" | "staleGraceMs">
  >,
): Promise<boolean> {
  let snapshot: LockSnapshot | undefined;
  try {
    snapshot = await readLockSnapshot(directory, lockPath);
  } catch {
    return false;
  }
  if (!snapshot) return true;
  if (!(await isStaleDeadSnapshot(snapshot, options))) return false;

  const tombstone = `${lockPath}.stale-${claimantToken}-${randomUUID()}`;
  try {
    await rename(lockPath, tombstone);
  } catch (error) {
    if (isMissing(error)) return true;
    return false;
  }
  try {
    await syncParentDirectory(lockPath, syncDirectory);
  } catch (error) {
    await restoreTombstone(
      directory,
      tombstone,
      lockPath,
      snapshot,
      syncDirectory,
    ).catch(() => false);
    throw error;
  }

  let moved: LockSnapshot | undefined;
  try {
    moved = await readLockSnapshot(directory, tombstone);
  } catch {
    await restoreTombstone(
      directory,
      tombstone,
      lockPath,
      snapshot,
      syncDirectory,
    );
    return false;
  }
  if (!moved || !snapshotsMatch(snapshot, moved)) {
    await restoreTombstone(
      directory,
      tombstone,
      lockPath,
      snapshot,
      syncDirectory,
    );
    return false;
  }
  await rm(tombstone, { recursive: true, force: true });
  await syncParentDirectory(tombstone, syncDirectory);
  return true;
}

async function tryAcquireReclaimClaim(
  directory: PrivateStateDirectoryBinding,
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
      return tryInstallPreparedLock(
        directory,
        claimPath,
        claimant,
        syncDirectory,
      );
    }
    const reclaimed = await tryReclaimUnclaimedDeadDirectory(
      directory,
      claimPath,
      claimant.token,
      syncDirectory,
      options,
    );
    return (
      reclaimed &&
      (await pathExists(lockPath)) &&
      !(await pathExists(claimPath)) &&
      (await tryInstallPreparedLock(
        directory,
        claimPath,
        claimant,
        syncDirectory,
      ))
    );
  } catch (error) {
    if (isMissing(error)) return false;
    throw error;
  }
}

async function tryReclaimDeadLock(
  directory: PrivateStateDirectoryBinding,
  lockPath: string,
  claimant: StateLockOwner,
  syncDirectory: DirectorySync,
  options: Required<
    Pick<StateMutationLockOptions, "now" | "processStatus" | "staleGraceMs">
  >,
): Promise<boolean> {
  let snapshot: LockSnapshot | undefined;
  try {
    snapshot = await readLockSnapshot(directory, lockPath);
  } catch {
    return false;
  }
  if (!snapshot) return true;
  if (!(await isStaleDeadSnapshot(snapshot, options))) return false;
  if (
    !(await tryAcquireReclaimClaim(
      directory,
      lockPath,
      claimant,
      syncDirectory,
      options,
    ))
  ) {
    return false;
  }

  const claimPath = join(lockPath, STATE_LOCK_RECLAIM_DIRECTORY);
  let claimMovedWithLock = false;
  let claimSnapshot: LockSnapshot | undefined;
  try {
    const current = await readLockSnapshot(directory, lockPath);
    const claim = await readLockSnapshot(directory, claimPath);
    claimSnapshot = claim;
    if (
      !current ||
      !claim ||
      !snapshotsMatch(snapshot, current) ||
      claim.owner.pid !== claimant.pid ||
      claim.owner.token !== claimant.token ||
      !(await isStaleDeadSnapshot(current, options))
    ) {
      await releaseOwnedLock(
        directory,
        claimPath,
        claimant,
        claim,
        syncDirectory,
      ).catch(() => undefined);
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
    try {
      await syncParentDirectory(lockPath, syncDirectory);
    } catch (error) {
      await restoreTombstone(
        directory,
        tombstone,
        lockPath,
        snapshot,
        syncDirectory,
      ).catch(() => false);
      throw error;
    }

    let moved: LockSnapshot | undefined;
    let movedClaim: LockSnapshot | undefined;
    try {
      moved = await readLockSnapshot(directory, tombstone);
      movedClaim = await readLockSnapshot(
        directory,
        join(tombstone, STATE_LOCK_RECLAIM_DIRECTORY),
      );
    } catch {
      if (
        await restoreTombstone(
          directory,
          tombstone,
          lockPath,
          snapshot,
          syncDirectory,
        )
      ) {
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
      if (
        await restoreTombstone(
          directory,
          tombstone,
          lockPath,
          snapshot,
          syncDirectory,
        )
      ) {
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
        directory,
        claimPath,
        claimant,
        claimSnapshot,
        syncDirectory,
      ).catch(() => undefined);
    }
  }
}

interface LockReleaseProgress {
  phase: "owned" | "tombstoned" | "removed-awaiting-sync";
  tombstone?: string;
  snapshot?: LockSnapshot;
}

async function releaseOwnedLock(
  directory: PrivateStateDirectoryBinding,
  lockPath: string,
  owner: StateLockOwner,
  expectedSnapshot: LockSnapshot | undefined,
  syncDirectory: DirectorySync,
  progress: LockReleaseProgress = { phase: "owned" },
): Promise<void> {
  await assertPrivateStateDirectory(directory);
  if (progress.phase === "removed-awaiting-sync") {
    await syncParentDirectory(lockPath, syncDirectory);
    await assertPrivateStateDirectory(directory);
    return;
  }

  if (progress.phase === "tombstoned") {
    const tombstone = progress.tombstone;
    const snapshot = progress.snapshot;
    if (!tombstone || !snapshot) {
      throw new Error("Conversation identity lock release state is invalid");
    }
    const moved = await readLockSnapshot(directory, tombstone);
    if (!moved || !snapshotsMatch(snapshot, moved)) {
      throw new Error(
        "Conversation identity lock ownership changed during release",
      );
    }
    await syncParentDirectory(lockPath, syncDirectory);
    await rm(tombstone, { recursive: true, force: true });
    progress.phase = "removed-awaiting-sync";
    progress.tombstone = undefined;
    progress.snapshot = undefined;
    await syncParentDirectory(lockPath, syncDirectory);
    await assertPrivateStateDirectory(directory);
    return;
  }

  const snapshot = await readLockSnapshot(directory, lockPath);
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
  progress.phase = "tombstoned";
  progress.tombstone = tombstone;
  progress.snapshot = snapshot;
  await syncParentDirectory(lockPath, syncDirectory);
  const moved = await readLockSnapshot(directory, tombstone);
  if (!moved || !snapshotsMatch(snapshot, moved)) {
    throw new Error(
      "Conversation identity lock ownership changed during release",
    );
  }
  await rm(tombstone, { recursive: true, force: true });
  progress.phase = "removed-awaiting-sync";
  progress.tombstone = undefined;
  progress.snapshot = undefined;
  await syncParentDirectory(lockPath, syncDirectory);
  await assertPrivateStateDirectory(directory);
}

function snapshotsMatchOwner(
  snapshot: LockSnapshot,
  owner: StateLockOwner,
): boolean {
  return (
    snapshot.owner.pid === owner.pid &&
    snapshot.owner.processIdentity === owner.processIdentity &&
    snapshot.owner.token === owner.token
  );
}

function createLockRelease(
  directory: PrivateStateDirectoryBinding,
  lockPath: string,
  owner: StateLockOwner,
  expectedSnapshot: LockSnapshot,
  syncDirectory: DirectorySync,
): () => Promise<void> {
  let released = false;
  let releaseAttempt: Promise<void> | undefined;
  const progress: LockReleaseProgress = { phase: "owned" };
  return () => {
    if (released) return Promise.resolve();
    if (releaseAttempt) return releaseAttempt;
    const currentAttempt = releaseOwnedLock(
      directory,
      lockPath,
      owner,
      expectedSnapshot,
      syncDirectory,
      progress,
    ).then(() => {
      released = true;
    });
    const trackedAttempt = currentAttempt.catch((error: unknown) => {
      if (releaseAttempt === trackedAttempt) releaseAttempt = undefined;
      throw error;
    });
    releaseAttempt = trackedAttempt;
    return trackedAttempt;
  };
}

export async function acquireStateMutationLock(
  directory: PrivateStateDirectoryBinding,
  stateFile: string,
  description: string,
  options: StateMutationLockOptions = {},
): Promise<() => Promise<void>> {
  assertPathWithinBinding(directory, stateFile);
  await assertPrivateStateDirectory(directory);
  const lockPath = `${stateFile}.lock`;
  const syncDirectory = options.syncDirectory ?? syncDirectoryForDurability;
  const processIdentityResolver =
    options.processIdentity ?? defaultProcessIdentity;
  const ownerPid = options.pid ?? process.pid;
  const ownerProcessIdentity =
    ownerPid === process.pid
      ? await currentProcessIdentity(processIdentityResolver)
      : await processIdentityResolver(ownerPid);
  const owner: StateLockOwner = {
    version: LOCK_OWNER_VERSION,
    pid: ownerPid,
    processIdentity: ownerProcessIdentity ?? "",
    token: (options.token ?? randomUUID)(),
    createdAt: new Date((options.now ?? Date.now)()).toISOString(),
  };
  if (
    !Number.isSafeInteger(owner.pid) ||
    owner.pid <= 0 ||
    !PROCESS_IDENTITY_PATTERN.test(owner.processIdentity) ||
    !LOCK_TOKEN_PATTERN.test(owner.token)
  ) {
    throw new Error("Conversation identity lock owner options are invalid");
  }
  const attempts = options.attempts ?? DEFAULT_LOCK_ATTEMPTS;
  const retryMs = options.retryMs ?? DEFAULT_LOCK_RETRY_MS;
  const processStatusResolver = options.processStatus ?? defaultProcessStatus;
  const processStatuses = new Map<string, Promise<ProcessStatus>>();
  const cachedProcessStatus: ProcessStatusResolver = (pid, expectedIdentity) => {
    const key = `${pid}:${expectedIdentity}`;
    const cached = processStatuses.get(key);
    if (cached) return cached;
    const pending = Promise.resolve(processStatusResolver(pid, expectedIdentity));
    processStatuses.set(key, pending);
    return pending;
  };
  const reclaimOptions = {
    now: options.now ?? Date.now,
    processStatus: cachedProcessStatus,
    staleGraceMs: options.staleGraceMs ?? DEFAULT_STALE_LOCK_GRACE_MS,
  };

  for (let attempt = 0; attempt < attempts; attempt += 1) {
    await assertPrivateStateDirectory(directory);
    if (
      !(await pathExists(lockPath)) &&
      (await tryInstallPreparedLock(directory, lockPath, owner, syncDirectory))
    ) {
      const snapshot = await readLockSnapshot(directory, lockPath);
      if (!snapshot || !snapshotsMatchOwner(snapshot, owner)) {
        throw new Error(
          "Conversation identity lock could not be bound after acquire",
        );
      }
      return createLockRelease(
        directory,
        lockPath,
        owner,
        snapshot,
        syncDirectory,
      );
    }
    const reclaimed = await tryReclaimDeadLock(
      directory,
      lockPath,
      owner,
      syncDirectory,
      reclaimOptions,
    );
    if (
      reclaimed &&
      !(await pathExists(lockPath)) &&
      (await tryInstallPreparedLock(directory, lockPath, owner, syncDirectory))
    ) {
      const snapshot = await readLockSnapshot(directory, lockPath);
      if (!snapshot || !snapshotsMatchOwner(snapshot, owner)) {
        throw new Error(
          "Conversation identity lock could not be bound after reclaim",
        );
      }
      return createLockRelease(
        directory,
        lockPath,
        owner,
        snapshot,
        syncDirectory,
      );
    }
    if (attempt + 1 < attempts) await pause(retryMs);
  }
  throw new Error(`${description} is busy`);
}

export const STATE_WRITER_LEASE_SUFFIX = ".writer-lease" as const;

export function acquireStateWriterLease(
  directory: PrivateStateDirectoryBinding,
  stateFile: string,
  description: string,
  options: StateMutationLockOptions = {},
): Promise<() => Promise<void>> {
  return acquireStateMutationLock(
    directory,
    `${stateFile}${STATE_WRITER_LEASE_SUFFIX}`,
    description,
    options,
  );
}
