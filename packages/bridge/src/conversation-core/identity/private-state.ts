import { createHash, createHmac, randomBytes, randomUUID } from "node:crypto";
import { execFile } from "node:child_process";
import { constants, type Stats } from "node:fs";
import {
  chmod,
  link,
  lstat,
  mkdir,
  open,
  readFile,
  readdir,
  readlink,
  realpath,
  rename,
  rm,
  unlink,
} from "node:fs/promises";
import {
  dirname,
  isAbsolute,
  join,
  parse,
  relative,
  resolve,
  sep,
} from "node:path";
import { createConnection, createServer, type Server } from "node:net";
import { promisify } from "node:util";

const PRIVATE_DIRECTORY_MODE = 0o700;
const PRIVATE_FILE_MODE = 0o600;
const DEFAULT_LOCK_ATTEMPTS = 400;
const DEFAULT_LOCK_RETRY_MS = 5;
const DEFAULT_STALE_LOCK_GRACE_MS = 1_000;
const MAX_LOCK_OWNER_BYTES = 4 * 1024;
const LOCK_OWNER_VERSION = 3 as const;
const LOCK_DIRECTORY_OPEN_FLAGS =
  constants.O_RDONLY |
  (constants.O_DIRECTORY ?? 0) |
  (constants.O_NOFOLLOW ?? 0);
const LOCK_TOKEN_PATTERN = /^[A-Za-z0-9_-]{16,128}$/;
const PROCESS_IDENTITY_PATTERN = /^[A-Za-z0-9:._+\-/=]{8,1024}$/;
const PRIVATE_STATE_RELEASE_RESIDUE_PATTERN =
  /^.+\.lock\.release-[A-Za-z0-9_-]{16,128}-[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const PRIVATE_STATE_RESIDUE_PATTERNS = [
  /^.+\.tmp-[1-9][0-9]*-[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
  /^.+\.lock\.candidate-[1-9][0-9]*-[A-Za-z0-9_-]{16,128}-[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
  /^.+\.lock\.(?:stale|legacy-stale)-[A-Za-z0-9_-]{16,128}-[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
  PRIVATE_STATE_RELEASE_RESIDUE_PATTERN,
  /^.+\.lock\.(?:failed-install|changed-restore)-[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
  /^.+\.gc-[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
] as const;
const execFileAsync = promisify(execFile);
const DARWIN_COMMAND_ENV = Object.freeze({
  LANG: "C",
  LC_ALL: "C",
  PATH: "/usr/bin:/bin:/usr/sbin:/sbin",
});
export const STATE_LOCK_OWNER_FILE = "owner-v3.json" as const;
const PREVIOUS_STATE_LOCK_OWNER_FILE = "owner-v2.json" as const;
export const LEGACY_STATE_LOCK_OWNER_FILE = "owner-v1.json" as const;
export const STATE_LOCK_RECLAIM_DIRECTORY = "reclaim-v1" as const;

interface StateLockOwner {
  version: typeof LOCK_OWNER_VERSION;
  pid: number;
  processIdentity: string;
  token: string;
  createdAt: string;
  directoryDevice?: string;
  directoryInode?: string;
}

interface LockSnapshot {
  owner: StateLockOwner;
  device: number;
  inode: number;
}

interface LockDirectoryIdentity {
  readonly device: number;
  readonly inode: number;
}

interface LegacyStateLockOwner {
  readonly version: 1;
  readonly pid: number;
  readonly token: string;
  readonly createdAt: string;
}

class LegacyStateLockOwnerError extends Error {
  readonly owner: LegacyStateLockOwner;
  readonly directoryIdentity: LockDirectoryIdentity;

  constructor(
    owner: LegacyStateLockOwner,
    directoryIdentity: LockDirectoryIdentity,
  ) {
    super("Conversation identity lock uses legacy owner metadata");
    this.owner = owner;
    this.directoryIdentity = directoryIdentity;
  }
}

export type ProcessStatus = "alive" | "dead" | "dead-old-boot" | "unknown";

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
  beforeInstalledSnapshotRead?: (lockPath: string) => Promise<void>;
  beforeLockOwnerRead?: (lockPath: string) => Promise<void>;
  afterLockOwnerRead?: (lockPath: string) => Promise<void>;
  beforeReleaseSnapshotRead?: (lockPath: string) => Promise<void>;
}

export type PrivateStateGenerationHolder =
  "bridge-identity" | "bridge-installation";

export interface PrivateStateGenerationLease {
  readonly writerLeaseFile: string;
  readonly assertCurrent: () => Promise<void>;
  readonly release: () => Promise<void>;
  readonly abandon: () => Promise<void>;
}

export interface StateMutationLockLease {
  (): Promise<void>;
  readonly assertCurrent: () => Promise<void>;
  readonly abandon: () => Promise<void>;
}

export async function releaseOrAbandonStateMutationLock(
  lease: StateMutationLockLease,
): Promise<void> {
  try {
    await lease();
  } catch (releaseError) {
    try {
      await lease.abandon();
    } catch (recoveryError) {
      throw new AggregateError(
        [releaseError, recoveryError],
        "Conversation identity lock release and recovery registration both failed",
      );
    }
    throw releaseError;
  }
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

function isPrivateStateResidueName(name: string): boolean {
  return PRIVATE_STATE_RESIDUE_PATTERNS.some((pattern) => pattern.test(name));
}

async function cleanPrivateStateResidueEntry(
  directory: PrivateStateDirectoryBinding,
  name: string,
  syncDirectory: DirectorySync,
  processStatus: ProcessStatusResolver,
): Promise<void> {
  if (!isPrivateStateResidueName(name)) return;
  const residue = join(directory.path, name);
  assertPathWithinBinding(directory, residue);
  await assertPrivateStateDirectory(directory);
  let releaseSnapshot: LockSnapshot | undefined;
  if (PRIVATE_STATE_RELEASE_RESIDUE_PATTERN.test(name)) {
    releaseSnapshot = await readLockSnapshot(directory, residue).catch(
      () => undefined,
    );
    if (releaseSnapshot !== undefined) {
      const status = await processStatus(
        releaseSnapshot.owner.pid,
        releaseSnapshot.owner.processIdentity,
      );
      if (status === "alive" || status === "unknown") return;
    }
  }
  let before: Awaited<ReturnType<typeof lstat>>;
  try {
    before = await lstat(residue);
  } catch (error) {
    if (isMissing(error)) return;
    throw error;
  }
  if (
    releaseSnapshot !== undefined &&
    !sameLockDirectoryIdentity(releaseSnapshot, {
      device: before.dev,
      inode: before.ino,
    })
  ) {
    return;
  }
  const quarantine = `${residue}.gc-${randomUUID()}`;
  await rename(residue, quarantine);
  await syncDirectory(directory.path);
  const moved = await lstat(quarantine);
  if (!sameFileIdentity(before, moved)) {
    throw new Error("Conversation identity residue changed during cleanup");
  }
  await rm(quarantine, { recursive: true, force: false });
  await syncDirectory(directory.path);
  await assertPrivateStateDirectory(directory);
}

async function cleanPrivateStateResidue(
  directory: PrivateStateDirectoryBinding,
  syncDirectory: DirectorySync,
  processStatus: ProcessStatusResolver,
): Promise<void> {
  let names: string[];
  try {
    await assertPrivateStateDirectory(directory);
    names = await readdir(directory.path);
  } catch {
    return;
  }
  for (const name of names) {
    await cleanPrivateStateResidueEntry(
      directory,
      name,
      syncDirectory,
      processStatus,
    ).catch(() => undefined);
  }
}

function modeOf(mode: number): number {
  return mode & 0o777;
}

function securityCacheKey(status: {
  dev: number;
  ino: number;
  ctimeMs: number;
}): string {
  return `${status.dev}:${status.ino}:${status.ctimeMs}`;
}

const securedPrivatePaths = new Set<string>();
const inspectedPrivateStateAncestors = new Set<string>();
const MAX_SECURITY_CACHE_ENTRIES = 4_096;

function rememberSecurityCacheEntry(cache: Set<string>, key: string): void {
  if (cache.has(key)) return;
  while (cache.size >= MAX_SECURITY_CACHE_ENTRIES) {
    const oldest = cache.values().next().value as string | undefined;
    if (oldest === undefined) break;
    cache.delete(oldest);
  }
  cache.add(key);
}

async function darwinAclEntries(path: string): Promise<readonly string[]> {
  const result = await execFileAsync("/bin/ls", ["-lde", path], {
    encoding: "utf8",
    timeout: 2_000,
    maxBuffer: 64 * 1024,
    env: DARWIN_COMMAND_ENV,
  });
  return result.stdout
    .split("\n")
    .slice(1)
    .filter((line) => /^\s*\d+:\s/u.test(line));
}

async function assertNoDarwinAllowAcl(
  path: string,
  description: string,
): Promise<void> {
  if (process.platform !== "darwin") return;
  const entries = await darwinAclEntries(path);
  if (entries.some((entry) => /\ballow\b/u.test(entry))) {
    throw new Error(`${description} grants access through a macOS ACL`);
  }
}

async function hardenPrivatePath(
  path: string,
  expectedMode: number,
  description: string,
  expectedKind: "directory" | "file",
): Promise<Stats> {
  const before = await lstat(path);
  const isExpectedKind =
    expectedKind === "directory" ? before.isDirectory() : before.isFile();
  if (before.isSymbolicLink() || !isExpectedKind) {
    throw new Error(`${description} must be a private real ${expectedKind}`);
  }
  const effectiveUser = process.geteuid?.();
  if (effectiveUser !== undefined && before.uid !== effectiveUser) {
    throw new Error(`${description} is not owned by the current user`);
  }
  const cached = securedPrivatePaths.has(securityCacheKey(before));
  if (!cached) {
    await chmod(path, expectedMode);
    if (process.platform === "darwin") {
      await execFileAsync("/bin/chmod", ["-N", path], {
        encoding: "utf8",
        timeout: 2_000,
        maxBuffer: 4 * 1024,
        env: DARWIN_COMMAND_ENV,
      });
      await assertNoDarwinAllowAcl(path, description);
    }
  }
  const after = await lstat(path);
  const remainsExpectedKind =
    expectedKind === "directory" ? after.isDirectory() : after.isFile();
  if (
    after.isSymbolicLink() ||
    !remainsExpectedKind ||
    !sameFileIdentity(before, after) ||
    (effectiveUser !== undefined && after.uid !== effectiveUser) ||
    modeOf(after.mode) !== expectedMode
  ) {
    throw new Error(`${description} is not private`);
  }
  rememberSecurityCacheEntry(securedPrivatePaths, securityCacheKey(after));
  return after;
}

async function assertPrivateStateAncestorSecurity(path: string): Promise<void> {
  const effectiveUser = process.geteuid?.();
  let cursor = dirname(path);
  while (true) {
    const status = await lstat(cursor);
    if (status.isSymbolicLink() || !status.isDirectory()) {
      throw new Error(
        "Conversation identity state ancestor is not a real directory",
      );
    }
    const cacheKey = securityCacheKey(status);
    if (!inspectedPrivateStateAncestors.has(cacheKey)) {
      if (process.platform === "darwin") {
        const aclEntries = await darwinAclEntries(cursor);
        const grantsNamespaceMutation = aclEntries.some(
          (entry) =>
            /\ballow\b/u.test(entry) &&
            /\b(?:add_file|add_subdirectory|delete|delete_child|writeattr|writeextattr|writesecurity|chown)\b/u.test(
              entry,
            ),
        );
        if (grantsNamespaceMutation) {
          throw new Error(
            "Conversation identity state ancestor ACL grants namespace mutation",
          );
        }
      }
      const writableByAnotherPrincipal = (status.mode & 0o022) !== 0;
      const protectedStickyRoot =
        (status.mode & 0o1000) !== 0 && status.uid === 0;
      const foreignOwnerCanMutateNamespace =
        effectiveUser !== undefined &&
        status.uid !== effectiveUser &&
        status.uid !== 0 &&
        (status.mode & 0o300) === 0o300;
      if (
        (writableByAnotherPrincipal || foreignOwnerCanMutateNamespace) &&
        !protectedStickyRoot
      ) {
        throw new Error(
          "Conversation identity state ancestor is writable by another principal",
        );
      }
      rememberSecurityCacheEntry(inspectedPrivateStateAncestors, cacheKey);
    }
    const parent = dirname(cursor);
    if (parent === cursor) return;
    cursor = parent;
  }
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
      if (offset >= contents.length)
        throw new SyntaxError("truncated JSON escape");
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
      if (keys.has(key.value))
        throw new SyntaxError("duplicate JSON object key");
      keys.add(key.value);
      offset = skipJsonWhitespace(contents, key.next);
      if (contents[offset] !== ":")
        throw new SyntaxError("expected JSON colon");
      offset = scanJsonValue(contents, offset + 1, depth + 1);
      offset = skipJsonWhitespace(contents, offset);
      if (contents[offset] === "}") return offset + 1;
      if (contents[offset] !== ",")
        throw new SyntaxError("expected JSON comma");
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
      if (contents[offset] !== ",")
        throw new SyntaxError("expected JSON comma");
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
  readonly version: "proc-v1" | "proc-v2" | "proc-v3";
  readonly platform: string;
  readonly machineScope: string;
  readonly bootScope: string;
  readonly processScope: string;
  readonly witness?: {
    readonly pid: number;
    readonly port: number;
    readonly token: string;
  };
}

function parseProcessIdentity(value: string): ProcessIdentityParts | undefined {
  const parts = value.split(":");
  if (parts[0] === "proc-v2" || parts[0] === "proc-v3") {
    if (
      parts.length !== 7 ||
      parts[2]?.length !== 43 ||
      parts[3]?.length !== 43 ||
      !/^\d+$/u.test(parts[4] ?? "") ||
      !/^\d+$/u.test(parts[5] ?? "") ||
      !/^[A-Za-z0-9_-]{43}$/u.test(parts[6] ?? "")
    ) {
      return undefined;
    }
    const pid = Number(parts[4]);
    const port = Number(parts[5]);
    if (
      !Number.isSafeInteger(pid) ||
      pid <= 0 ||
      !Number.isSafeInteger(port) ||
      port <= 0 ||
      port > 65_535
    ) {
      return undefined;
    }
    return {
      version: parts[0],
      platform: parts[1]!,
      machineScope: parts.slice(1, 3).join(":"),
      bootScope: parts.slice(1, 4).join(":"),
      processScope: parts.slice(1, 6).join(":"),
      witness: { pid, port, token: parts[6]! },
    };
  }
  if (parts.length < 5 || parts[0] !== "proc-v1") return undefined;
  return {
    version: "proc-v1",
    platform: parts[1]!,
    machineScope: parts.slice(1, 3).join(":"),
    bootScope: parts.slice(1, 4).join(":"),
    processScope: parts.slice(1, -1).join(":"),
  };
}

interface DarwinProcessWitness {
  readonly port: number;
  readonly token: string;
  readonly server: Server;
  active: boolean;
}

let darwinProcessWitnessPromise: Promise<DarwinProcessWitness> | undefined;

function darwinProcessWitness(): Promise<DarwinProcessWitness> {
  if (darwinProcessWitnessPromise !== undefined) {
    return darwinProcessWitnessPromise;
  }
  const pending = new Promise<DarwinProcessWitness>(
    (resolveWitness, reject) => {
      const token = randomBytes(32).toString("base64url");
      const witness: DarwinProcessWitness = {
        port: 0,
        token,
        server: createServer(),
        active: true,
      };
      witness.server.on("connection", (socket) => {
        let input = "";
        socket.setEncoding("utf8");
        socket.setTimeout(1_000, () => socket.destroy());
        socket.on("data", (chunk: string) => {
          input += chunk;
          if (input.length > 256) {
            socket.destroy();
            return;
          }
          const newline = input.indexOf("\n");
          if (newline < 0) return;
          const challenge = input.slice(0, newline);
          if (!/^[A-Za-z0-9_-]{43}$/u.test(challenge)) {
            socket.destroy();
            return;
          }
          const response = createHmac("sha256", token)
            .update(challenge, "utf8")
            .digest("base64url");
          socket.end(`${response}\n`);
        });
      });
      witness.server.once("error", (error) => {
        witness.active = false;
        reject(error);
      });
      witness.server.once("listening", () => {
        const address = witness.server.address();
        if (address === null || typeof address === "string") {
          witness.active = false;
          witness.server.close();
          reject(new Error("Darwin process witness did not bind TCP"));
          return;
        }
        Object.defineProperty(witness, "port", { value: address.port });
        witness.server.on("close", () => {
          witness.active = false;
        });
        witness.server.unref();
        resolveWitness(witness);
      });
      witness.server.listen({ host: "127.0.0.1", port: 0, exclusive: true });
    },
  );
  const tracked = pending.catch((error: unknown) => {
    if (darwinProcessWitnessPromise === tracked) {
      darwinProcessWitnessPromise = undefined;
    }
    throw error;
  });
  darwinProcessWitnessPromise = tracked;
  return darwinProcessWitnessPromise;
}

async function probeDarwinProcessWitness(
  witness: NonNullable<ProcessIdentityParts["witness"]>,
): Promise<ProcessStatus> {
  const challenge = randomBytes(32).toString("base64url");
  const expected = createHmac("sha256", witness.token)
    .update(challenge, "utf8")
    .digest("base64url");
  return new Promise<ProcessStatus>((resolveStatus) => {
    let settled = false;
    let output = "";
    const finish = (status: ProcessStatus): void => {
      if (settled) return;
      settled = true;
      socket.destroy();
      resolveStatus(status);
    };
    const socket = createConnection({
      host: "127.0.0.1",
      port: witness.port,
    });
    socket.setEncoding("utf8");
    socket.setTimeout(1_000, () => finish("unknown"));
    socket.on("connect", () => socket.write(`${challenge}\n`));
    socket.on("data", (chunk: string) => {
      output += chunk;
      if (output.length > 256) return finish("dead");
      const newline = output.indexOf("\n");
      if (newline >= 0) {
        finish(output.slice(0, newline) === expected ? "alive" : "dead");
      }
    });
    socket.on("error", (error: NodeJS.ErrnoException) => {
      finish(error.code === "ECONNREFUSED" ? "dead" : "unknown");
    });
    socket.on("end", () => {
      if (!settled) finish("dead");
    });
  });
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

export function parseDarwinBootTime(value: string): string | undefined {
  const match = value.match(
    /^\{\s*sec\s*=\s*([1-9][0-9]*),\s*usec\s*=\s*([0-9]+)\s*\}/u,
  );
  if (!match) return undefined;
  const seconds = match[1]!;
  const microseconds = match[2]!;
  if (microseconds.length > 6 || Number(microseconds) > 999_999) {
    return undefined;
  }
  return `${seconds}:${microseconds.padStart(6, "0")}`;
}

async function darwinProcessIdentity(pid: number): Promise<string | undefined> {
  if (pid !== process.pid) return undefined;
  try {
    const [machine, boot, witness] = await Promise.all([
      execFileAsync(
        "/usr/sbin/ioreg",
        ["-rd1", "-c", "IOPlatformExpertDevice"],
        {
          encoding: "utf8",
          timeout: 2_000,
          maxBuffer: 64 * 1024,
          env: DARWIN_COMMAND_ENV,
        },
      ),
      execFileAsync("/usr/sbin/sysctl", ["-n", "kern.boottime"], {
        encoding: "utf8",
        timeout: 2_000,
        maxBuffer: 4 * 1024,
        env: DARWIN_COMMAND_ENV,
      }),
      darwinProcessWitness(),
    ]);
    const machineMatch = machine.stdout.match(
      /"IOPlatformUUID"\s*=\s*"([^"]+)"/u,
    );
    const machineValue = machineMatch?.[1]?.trim();
    const bootValue = parseDarwinBootTime(boot.stdout);
    if (!machineValue || !bootValue || !witness.active) return undefined;
    const digest = (value: string) =>
      createHash("sha256").update(value, "utf8").digest("base64url");
    return [
      "proc-v3",
      "darwin",
      digest(machineValue),
      digest(bootValue),
      String(pid),
      String(witness.port),
      witness.token,
    ].join(":");
  } catch {
    return undefined;
  }
}

async function windowsProcessIdentity(
  pid: number,
): Promise<string | undefined> {
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

async function defaultProcessIdentity(
  pid: number,
): Promise<string | undefined> {
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
  if (currentProcessIdentityPromise === undefined) {
    const attempt = resolver(process.pid);
    const tracked = attempt.then(
      (identity) => {
        if (
          identity === undefined &&
          currentProcessIdentityPromise === tracked
        ) {
          currentProcessIdentityPromise = undefined;
        }
        return identity;
      },
      (error: unknown) => {
        if (currentProcessIdentityPromise === tracked) {
          currentProcessIdentityPromise = undefined;
        }
        throw error;
      },
    );
    currentProcessIdentityPromise = tracked;
  }
  return currentProcessIdentityPromise;
}

export async function defaultProcessStatus(
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
  // Darwin proc-v1 hashed locale-sensitive boot text and proc-v2 hashed the
  // full TZ-sensitive kern.boottime rendering. Neither version can prove an
  // old boot against proc-v3 numeric timeval evidence. Preserve live v2
  // owners through their persisted witness and keep v1 fail closed unless its
  // PID is definitely absent.
  if (
    expected.version === "proc-v2" &&
    expected.platform === "darwin" &&
    expected.witness !== undefined
  ) {
    try {
      process.kill(pid, 0);
    } catch (error) {
      return (error as NodeJS.ErrnoException).code === "ESRCH"
        ? "dead"
        : "unknown";
    }
    return probeDarwinProcessWitness(expected.witness);
  }
  if (expected.version === "proc-v1" && expected.platform === "darwin") {
    try {
      process.kill(pid, 0);
      return "unknown";
    } catch (error) {
      return (error as NodeJS.ErrnoException).code === "ESRCH"
        ? "dead"
        : "unknown";
    }
  }
  if (expected.bootScope !== current.bootScope) return "dead-old-boot";
  if (
    expected.version === "proc-v1" &&
    expected.processScope !== current.processScope
  ) {
    return "unknown";
  }
  if (
    expected.version === "proc-v3" &&
    expected.platform === "darwin" &&
    expected.witness !== undefined
  ) {
    try {
      process.kill(pid, 0);
    } catch (error) {
      return (error as NodeJS.ErrnoException).code === "ESRCH"
        ? "dead"
        : "unknown";
    }
    return probeDarwinProcessWitness(expected.witness);
  }
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

async function ensureDirectoryNamespaceDurable(
  absolutePath: string,
  syncDirectory: DirectorySync,
): Promise<string> {
  const namespacePath =
    await canonicalizeTrustedPrivateStateAlias(absolutePath);
  await assertLexicalDirectoryComponents(namespacePath);
  let cursor = namespacePath;
  while (true) {
    try {
      const status = await lstat(cursor);
      if (status.isSymbolicLink() || !status.isDirectory()) {
        throw new Error(
          "Conversation identity state path component is not a real directory",
        );
      }
      break;
    } catch (error) {
      if (!isMissing(error)) throw error;
      const parent = dirname(cursor);
      if (parent === cursor) throw error;
      cursor = parent;
    }
  }

  await mkdir(namespacePath, { recursive: true, mode: PRIVATE_DIRECTORY_MODE });
  await assertLexicalDirectoryComponents(namespacePath);
  const leafIdentity = await lstat(namespacePath);
  if (leafIdentity.isSymbolicLink() || !leafIdentity.isDirectory()) {
    throw new Error(
      "Conversation identity state directory changed while being created",
    );
  }
  // Durability follows the actual namespace. macOS exposes stable system
  // aliases such as /var -> /private/var, so reconcile the canonical chain
  // while the leaf itself is still rejected if it is a symbolic link.
  cursor = await realpath(namespacePath);
  while (true) {
    const status = await lstat(cursor);
    if (status.isSymbolicLink() || !status.isDirectory()) {
      throw new Error(
        "Conversation identity state directory changed while being created",
      );
    }
    const parent = dirname(cursor);
    if (parent === cursor) return namespacePath;
    await syncDirectory(parent);
    const currentLeaf = await lstat(namespacePath);
    if (
      currentLeaf.isSymbolicLink() ||
      !currentLeaf.isDirectory() ||
      !sameFileIdentity(leafIdentity, currentLeaf)
    ) {
      throw new Error(
        "Conversation identity state directory changed while being created",
      );
    }
    cursor = parent;
  }
}

async function canonicalizeTrustedPrivateStateAlias(
  absolutePath: string,
): Promise<string> {
  const parsed = parse(absolutePath);
  const segments = relative(parsed.root, absolutePath)
    .split(sep)
    .filter(Boolean);
  if (segments.length === 0) return absolutePath;
  const alias = join(parsed.root, segments[0]!);
  let status: Awaited<ReturnType<typeof lstat>>;
  try {
    status = await lstat(alias);
  } catch (error) {
    if (isMissing(error)) return absolutePath;
    throw error;
  }
  if (!status.isSymbolicLink()) return absolutePath;
  const canonical = await realpath(alias);
  const trustedDarwinAliases = new Map([
    [join(parsed.root, "etc"), join(parsed.root, "private", "etc")],
    [join(parsed.root, "tmp"), join(parsed.root, "private", "tmp")],
    [join(parsed.root, "var"), join(parsed.root, "private", "var")],
  ]);
  if (
    process.platform !== "darwin" ||
    status.uid !== 0 ||
    trustedDarwinAliases.get(alias) !== canonical
  ) {
    throw new Error(
      "Conversation identity state path component is a symbolic link",
    );
  }
  return join(canonical, ...segments.slice(1));
}

async function assertLexicalDirectoryComponents(path: string): Promise<void> {
  const parsed = parse(path);
  const segments = relative(parsed.root, path).split(sep).filter(Boolean);
  let cursor = parsed.root;
  for (const segment of segments) {
    cursor = join(cursor, segment);
    let status: Awaited<ReturnType<typeof lstat>>;
    try {
      status = await lstat(cursor);
    } catch (error) {
      if (isMissing(error)) return;
      throw error;
    }
    if (status.isSymbolicLink()) {
      throw new Error(
        "Conversation identity state path component is a symbolic link",
      );
    }
    if (!status.isDirectory()) {
      throw new Error(
        "Conversation identity state path component is not a real directory",
      );
    }
  }
}

export async function preparePrivateStateDirectory(
  path: string,
  syncDirectory: DirectorySync = syncDirectoryForDurability,
): Promise<PrivateStateDirectoryBinding> {
  assertPrivateStatePlatformSupported(process.platform);
  const absolutePath = resolve(path);
  if (/[\u0000-\u001f\u007f]/u.test(absolutePath)) {
    throw new Error("Conversation identity state path contains control data");
  }
  const namespacePath = await ensureDirectoryNamespaceDurable(
    absolutePath,
    syncDirectory,
  );
  const before = await lstat(namespacePath);
  if (before.isSymbolicLink() || !before.isDirectory()) {
    throw new Error(
      "Conversation identity state directory must be a real directory",
    );
  }
  const canonicalPath = await realpath(namespacePath);
  const rebound = await lstat(namespacePath);
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
  const after = await hardenPrivatePath(
    canonicalPath,
    PRIVATE_DIRECTORY_MODE,
    "Conversation identity state directory",
    "directory",
  );
  await assertPrivateStateAncestorSecurity(canonicalPath);
  const finalPath = await lstat(namespacePath);
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
  await syncDirectory(canonicalPath);
  const durable = await lstat(canonicalPath);
  if (
    durable.isSymbolicLink() ||
    !durable.isDirectory() ||
    !sameFileIdentity(after, durable) ||
    (process.geteuid?.() !== undefined &&
      durable.uid !== process.geteuid?.()) ||
    modeOf(durable.mode) !== PRIVATE_DIRECTORY_MODE
  ) {
    throw new Error(
      "Conversation identity state directory changed while securing metadata",
    );
  }
  return Object.freeze({
    path: canonicalPath,
    device: durable.dev,
    inode: durable.ino,
  });
}

export function assertPrivateStatePlatformSupported(
  platform: NodeJS.Platform,
): void {
  if (platform === "win32") {
    throw new Error(
      "Conversation identity private state is unavailable on Windows until " +
        "an owner-only ACL and durable namespace backend is installed",
    );
  }
}

export async function assertPrivateStateDirectory(
  binding: PrivateStateDirectoryBinding,
): Promise<void> {
  if (process.platform === "darwin") {
    const witness = await darwinProcessWitness();
    if (!witness.active) {
      throw new Error("Darwin private-state process witness is unavailable");
    }
  }
  const current = await lstat(binding.path);
  const effectiveUser = process.geteuid?.();
  if (
    current.isSymbolicLink() ||
    !current.isDirectory() ||
    current.dev !== binding.device ||
    current.ino !== binding.inode ||
    (effectiveUser !== undefined && current.uid !== effectiveUser) ||
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

    pathStats = await hardenPrivatePath(
      path,
      PRIVATE_FILE_MODE,
      description,
      "file",
    );

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
    await handle.sync();
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
    if (platform === "win32") {
      throw new Error(
        "Windows directory durability requires a supported native backend",
        { cause: error },
      );
    }
    throw error;
  }
  try {
    try {
      await handle.sync();
    } catch (error) {
      if (platform === "win32") {
        throw new Error(
          "Windows directory durability requires a supported native backend",
          { cause: error },
        );
      }
      throw error;
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
    const preparedBeforeAcl = await handle.stat();
    await hardenPrivatePath(temporary, PRIVATE_FILE_MODE, description, "file");
    await handle.sync();
    const prepared = await handle.stat();
    if (!sameFileIdentity(preparedBeforeAcl, prepared)) {
      throw new Error(`${description} changed while being secured`);
    }
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

function serializeLockOwner(
  owner: StateLockOwner,
  directoryIdentity: LockDirectoryIdentity,
): string {
  return `${JSON.stringify({
    version: LOCK_OWNER_VERSION,
    pid: owner.pid,
    processIdentity: owner.processIdentity,
    token: owner.token,
    createdAt: owner.createdAt,
    directoryDevice: String(directoryIdentity.device),
    directoryInode: String(directoryIdentity.inode),
  })}\n`;
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
      "directoryDevice",
      "directoryInode",
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
    !isCanonicalTimestamp(parsed.createdAt) ||
    typeof parsed.directoryDevice !== "string" ||
    !/^(?:0|[1-9][0-9]*)$/.test(parsed.directoryDevice) ||
    typeof parsed.directoryInode !== "string" ||
    !/^(?:0|[1-9][0-9]*)$/.test(parsed.directoryInode)
  ) {
    return undefined;
  }
  return {
    version: LOCK_OWNER_VERSION,
    pid: parsed.pid,
    processIdentity: parsed.processIdentity,
    token: parsed.token,
    createdAt: parsed.createdAt,
    directoryDevice: parsed.directoryDevice,
    directoryInode: parsed.directoryInode,
  };
}

function parseLegacyLockOwner(
  contents: string,
): LegacyStateLockOwner | undefined {
  let parsed: unknown;
  try {
    parsed = parseJsonWithoutDuplicateKeys(contents);
  } catch {
    return undefined;
  }
  if (
    !isPlainObject(parsed) ||
    !hasExactKeys(parsed, ["version", "pid", "token", "createdAt"]) ||
    parsed.version !== 1 ||
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
    version: 1,
    pid: parsed.pid,
    token: parsed.token,
    createdAt: parsed.createdAt,
  };
}

async function readLockSnapshot(
  directory: PrivateStateDirectoryBinding,
  lockPath: string,
  beforeOwnerRead?: (lockPath: string) => Promise<void>,
  afterOwnerRead?: (lockPath: string) => Promise<void>,
): Promise<LockSnapshot | undefined> {
  assertPathWithinBinding(directory, lockPath);
  await assertPrivateStateDirectory(directory);
  let stats: Awaited<ReturnType<typeof lstat>>;
  try {
    stats = await hardenPrivatePath(
      lockPath,
      PRIVATE_DIRECTORY_MODE,
      "Conversation identity lock",
      "directory",
    );
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
  const handle = await open(lockPath, LOCK_DIRECTORY_OPEN_FLAGS);
  const expectedIdentity = { device: stats.dev, inode: stats.ino };
  let result: LockSnapshot | undefined;
  let operationFailure: unknown;
  try {
    const handleBefore = await handle.stat();
    const lexicalBefore = await lstat(lockPath);
    if (
      !handleBefore.isDirectory() ||
      lexicalBefore.isSymbolicLink() ||
      !lexicalBefore.isDirectory() ||
      !sameLockDirectoryIdentity(expectedIdentity, {
        device: handleBefore.dev,
        inode: handleBefore.ino,
      }) ||
      !sameLockDirectoryIdentity(expectedIdentity, {
        device: lexicalBefore.dev,
        inode: lexicalBefore.ino,
      })
    ) {
      throw new Error(
        "Conversation identity lock directory changed before owner read",
      );
    }
    await beforeOwnerRead?.(lockPath);
    let ownerContents = await readBoundedPrivateFile(
      directory,
      join(lockPath, STATE_LOCK_OWNER_FILE),
      MAX_LOCK_OWNER_BYTES,
      "Conversation identity lock owner",
    );
    if (ownerContents === undefined) {
      const previousOwnerContents = await readBoundedPrivateFile(
        directory,
        join(lockPath, PREVIOUS_STATE_LOCK_OWNER_FILE),
        MAX_LOCK_OWNER_BYTES,
        "Conversation identity previous lock owner",
      );
      if (previousOwnerContents !== undefined) {
        throw new Error(
          "Conversation identity previous lock owner requires explicit recovery",
        );
      }
      ownerContents = await readBoundedPrivateFile(
        directory,
        join(lockPath, LEGACY_STATE_LOCK_OWNER_FILE),
        MAX_LOCK_OWNER_BYTES,
        "Conversation identity legacy lock owner",
      );
      if (ownerContents === undefined) {
        throw new Error("Conversation identity lock owner is missing");
      }
      const compatibleOwner = parseLockOwner(ownerContents);
      if (compatibleOwner) {
        result = { owner: compatibleOwner, ...expectedIdentity };
      } else {
        const legacyOwner = parseLegacyLockOwner(ownerContents);
        if (legacyOwner) {
          throw new LegacyStateLockOwnerError(legacyOwner, expectedIdentity);
        }
      }
    }
    if (result === undefined) {
      const owner = parseLockOwner(ownerContents);
      if (!owner)
        throw new Error("Conversation identity lock owner is invalid");
      result = { owner, ...expectedIdentity };
    }
    await afterOwnerRead?.(lockPath);
    // Node has no portable openat-style child open. Bind the persisted owner
    // to the directory generation instead: the held directory handle keeps
    // the original inode alive, so an independently created B in an A-B-A
    // pathname swap cannot acquire the same dev+ino while this read runs.
    if (
      result.owner.directoryDevice !== String(expectedIdentity.device) ||
      result.owner.directoryInode !== String(expectedIdentity.inode)
    ) {
      throw new Error(
        "Conversation identity lock owner belongs to another directory generation",
      );
    }
  } catch (error) {
    operationFailure = error;
  }
  try {
    const handleAfter = await handle.stat();
    const lexicalAfter = await lstat(lockPath);
    if (
      !handleAfter.isDirectory() ||
      lexicalAfter.isSymbolicLink() ||
      !lexicalAfter.isDirectory() ||
      !sameLockDirectoryIdentity(expectedIdentity, {
        device: handleAfter.dev,
        inode: handleAfter.ino,
      }) ||
      !sameLockDirectoryIdentity(expectedIdentity, {
        device: lexicalAfter.dev,
        inode: lexicalAfter.ino,
      })
    ) {
      throw new Error(
        "Conversation identity lock directory changed during owner read",
      );
    }
  } catch (bindingFailure) {
    throw new Error(
      "Conversation identity lock directory changed during owner read",
      { cause: operationFailure ?? bindingFailure },
    );
  } finally {
    await handle.close();
  }
  if (operationFailure !== undefined) throw operationFailure;
  return result;
}

async function tryReclaimLegacyDeadLock(
  _directory: PrivateStateDirectoryBinding,
  _lockPath: string,
  _legacy: LegacyStateLockOwnerError,
  _claimant: StateLockOwner,
  _syncDirectory: DirectorySync,
  _options: Required<
    Pick<StateMutationLockOptions, "now" | "processStatus" | "staleGraceMs">
  > &
    Pick<
      StateMutationLockOptions,
      | "beforeInstalledSnapshotRead"
      | "beforeLockOwnerRead"
      | "afterLockOwnerRead"
    >,
): Promise<boolean> {
  // Version-one owners have no machine, boot, namespace, or incarnation
  // evidence. Local ESRCH is therefore insufficient proof of death when the
  // state directory may be reused across hosts or PID namespaces.
  return false;
}

async function readLockDirectoryIdentity(
  directory: PrivateStateDirectoryBinding,
  lockPath: string,
): Promise<LockDirectoryIdentity | undefined> {
  assertPathWithinBinding(directory, lockPath);
  await assertPrivateStateDirectory(directory);
  let stats: Awaited<ReturnType<typeof lstat>>;
  try {
    stats = await hardenPrivatePath(
      lockPath,
      PRIVATE_DIRECTORY_MODE,
      "Conversation identity lock",
      "directory",
    );
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
  return { device: stats.dev, inode: stats.ino };
}

function sameLockDirectoryIdentity(
  expected: LockDirectoryIdentity,
  actual: LockDirectoryIdentity,
): boolean {
  return expected.device === actual.device && expected.inode === actual.inode;
}

function snapshotsMatch(left: LockSnapshot, right: LockSnapshot): boolean {
  return (
    left.device === right.device &&
    left.inode === right.inode &&
    left.owner.pid === right.owner.pid &&
    left.owner.processIdentity === right.owner.processIdentity &&
    left.owner.token === right.owner.token &&
    left.owner.createdAt === right.owner.createdAt &&
    left.owner.directoryDevice === right.owner.directoryDevice &&
    left.owner.directoryInode === right.owner.directoryInode
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
  return quarantineLockDirectory(
    directory,
    lockPath,
    expectedSnapshot,
    reason,
    syncDirectory,
  );
}

async function quarantineLockDirectory(
  directory: PrivateStateDirectoryBinding,
  lockPath: string,
  expectedIdentity: LockDirectoryIdentity,
  reason: "failed-install" | "changed-restore",
  syncDirectory: DirectorySync,
): Promise<boolean> {
  const currentIdentity = await readLockDirectoryIdentity(
    directory,
    lockPath,
  ).catch(() => undefined);
  if (
    !currentIdentity ||
    !sameLockDirectoryIdentity(expectedIdentity, currentIdentity)
  ) {
    return false;
  }
  const quarantine = `${lockPath}.${reason}-${randomUUID()}`;
  try {
    await rename(lockPath, quarantine);
  } catch {
    return false;
  }
  await syncParentDirectory(lockPath, syncDirectory);
  const movedIdentity = await readLockDirectoryIdentity(
    directory,
    quarantine,
  ).catch(() => undefined);
  if (
    movedIdentity &&
    sameLockDirectoryIdentity(expectedIdentity, movedIdentity) &&
    !(await pathExists(lockPath).catch(() => true))
  ) {
    return true;
  }
  if (
    movedIdentity &&
    !sameLockDirectoryIdentity(expectedIdentity, movedIdentity) &&
    !(await pathExists(lockPath).catch(() => true))
  ) {
    await rename(quarantine, lockPath).catch(() => undefined);
    await syncParentDirectory(lockPath, syncDirectory);
  }
  return false;
}

async function tryInstallPreparedLock(
  directory: PrivateStateDirectoryBinding,
  lockPath: string,
  owner: StateLockOwner,
  syncDirectory: DirectorySync,
  beforeInstalledSnapshotRead?: (lockPath: string) => Promise<void>,
): Promise<LockSnapshot | undefined> {
  await assertPrivateStateDirectory(directory);
  const candidate = `${lockPath}.candidate-${owner.pid}-${owner.token}-${randomUUID()}`;
  let candidateExists = false;
  try {
    await mkdir(candidate, { mode: PRIVATE_DIRECTORY_MODE });
    candidateExists = true;
    const candidateStatus = await lstat(candidate);
    if (candidateStatus.isSymbolicLink() || !candidateStatus.isDirectory()) {
      throw new Error("Conversation identity lock candidate is invalid");
    }
    const candidateIdentity = {
      device: candidateStatus.dev,
      inode: candidateStatus.ino,
    };
    await atomicPrivateWrite(
      directory,
      join(candidate, STATE_LOCK_OWNER_FILE),
      serializeLockOwner(owner, candidateIdentity),
      MAX_LOCK_OWNER_BYTES,
      "Conversation identity lock owner",
      { syncDirectory, createOnly: true },
    );
    const prepared = await readLockSnapshot(directory, candidate);
    if (!prepared || !snapshotsMatchOwner(prepared, owner)) {
      throw new Error("Conversation identity lock candidate is invalid");
    }
    try {
      await assertPrivateStateDirectory(directory);
      await rename(candidate, lockPath);
      candidateExists = false;
    } catch (error) {
      try {
        await lstat(lockPath);
        return undefined;
      } catch (destinationError) {
        if (!isMissing(destinationError)) throw destinationError;
        throw error;
      }
    }
    try {
      await beforeInstalledSnapshotRead?.(lockPath);
      const observed = await readLockSnapshot(directory, lockPath);
      if (!observed || !snapshotsMatch(prepared, observed)) {
        throw new Error("Conversation identity lock changed during install");
      }
      await syncParentDirectory(lockPath, syncDirectory);
      await assertPrivateStateDirectory(directory);
      return observed;
    } catch (error) {
      const quarantined = await quarantineLockDirectory(
        directory,
        lockPath,
        prepared,
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
  let restoredToCanonical = false;
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
    restoredToCanonical = true;
    await syncParentDirectory(lockPath, syncDirectory);
    const restored = await readLockSnapshot(directory, lockPath);
    if (restored !== undefined && snapshotsMatch(expectedSnapshot, restored)) {
      return true;
    }
    if (restoredToCanonical) {
      await quarantineLockDirectory(
        directory,
        lockPath,
        expectedSnapshot,
        "changed-restore",
        syncDirectory,
      );
    }
    return false;
  } catch {
    if (restoredToCanonical) {
      await quarantineLockDirectory(
        directory,
        lockPath,
        expectedSnapshot,
        "changed-restore",
        syncDirectory,
      ).catch(() => false);
    }
    return false;
  }
}

async function isStaleDeadSnapshot(
  snapshot: LockSnapshot,
  options: Required<
    Pick<StateMutationLockOptions, "now" | "processStatus" | "staleGraceMs">
  > &
    Pick<
      StateMutationLockOptions,
      | "beforeInstalledSnapshotRead"
      | "beforeLockOwnerRead"
      | "afterLockOwnerRead"
    >,
): Promise<boolean> {
  const age = options.now() - Date.parse(snapshot.owner.createdAt);
  const status = await options.processStatus(
    snapshot.owner.pid,
    snapshot.owner.processIdentity,
  );
  return (
    status === "dead-old-boot" ||
    (age >= options.staleGraceMs && status === "dead")
  );
}

async function tryReclaimUnclaimedDeadDirectory(
  directory: PrivateStateDirectoryBinding,
  lockPath: string,
  claimant: StateLockOwner,
  syncDirectory: DirectorySync,
  options: Required<
    Pick<StateMutationLockOptions, "now" | "processStatus" | "staleGraceMs">
  > &
    Pick<
      StateMutationLockOptions,
      | "beforeInstalledSnapshotRead"
      | "beforeLockOwnerRead"
      | "afterLockOwnerRead"
    >,
): Promise<boolean> {
  let snapshot: LockSnapshot | undefined;
  try {
    snapshot = await readLockSnapshot(
      directory,
      lockPath,
      options.beforeLockOwnerRead,
      options.afterLockOwnerRead,
    );
  } catch (error) {
    if (error instanceof LegacyStateLockOwnerError) {
      return tryReclaimLegacyDeadLock(
        directory,
        lockPath,
        error,
        claimant,
        syncDirectory,
        options,
      );
    }
    return false;
  }
  if (!snapshot) return true;
  if (!(await isStaleDeadSnapshot(snapshot, options))) return false;

  const tombstone = `${lockPath}.stale-${claimant.token}-${randomUUID()}`;
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
  > &
    Pick<
      StateMutationLockOptions,
      | "beforeInstalledSnapshotRead"
      | "beforeLockOwnerRead"
      | "afterLockOwnerRead"
    >,
): Promise<LockSnapshot | undefined> {
  const claimPath = join(lockPath, STATE_LOCK_RECLAIM_DIRECTORY);
  try {
    if (!(await pathExists(claimPath))) {
      return tryInstallPreparedLock(
        directory,
        claimPath,
        claimant,
        syncDirectory,
        options.beforeInstalledSnapshotRead,
      );
    }
    const reclaimed = await tryReclaimUnclaimedDeadDirectory(
      directory,
      claimPath,
      claimant,
      syncDirectory,
      options,
    );
    if (
      !reclaimed ||
      !(await pathExists(lockPath)) ||
      (await pathExists(claimPath))
    ) {
      return undefined;
    }
    return tryInstallPreparedLock(
      directory,
      claimPath,
      claimant,
      syncDirectory,
      options.beforeInstalledSnapshotRead,
    );
  } catch (error) {
    if (isMissing(error)) return undefined;
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
  > &
    Pick<
      StateMutationLockOptions,
      | "beforeInstalledSnapshotRead"
      | "beforeLockOwnerRead"
      | "afterLockOwnerRead"
    >,
): Promise<boolean> {
  let snapshot: LockSnapshot | undefined;
  try {
    snapshot = await readLockSnapshot(
      directory,
      lockPath,
      options.beforeLockOwnerRead,
      options.afterLockOwnerRead,
    );
  } catch (error) {
    if (error instanceof LegacyStateLockOwnerError) {
      return tryReclaimLegacyDeadLock(
        directory,
        lockPath,
        error,
        claimant,
        syncDirectory,
        options,
      );
    }
    return false;
  }
  if (!snapshot) return true;
  if (!(await isStaleDeadSnapshot(snapshot, options))) return false;
  const acquiredClaim = await tryAcquireReclaimClaim(
    directory,
    lockPath,
    claimant,
    syncDirectory,
    options,
  );
  if (acquiredClaim === undefined) return false;

  const claimPath = join(lockPath, STATE_LOCK_RECLAIM_DIRECTORY);
  const releaseClaim = createLockRelease(
    directory,
    claimPath,
    claimant,
    acquiredClaim,
    syncDirectory,
  );
  let claimMovedWithLock = false;
  let operationError: unknown;
  try {
    const current = await readLockSnapshot(
      directory,
      lockPath,
      options.beforeLockOwnerRead,
      options.afterLockOwnerRead,
    );
    const claim = await readLockSnapshot(directory, claimPath);
    if (
      !current ||
      !claim ||
      !snapshotsMatch(snapshot, current) ||
      claim.owner.pid !== claimant.pid ||
      claim.owner.token !== claimant.token ||
      !(await isStaleDeadSnapshot(current, options))
    ) {
      await releaseOrAbandonStateMutationLock(releaseClaim);
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
      if (
        await restoreTombstone(
          directory,
          tombstone,
          lockPath,
          snapshot,
          syncDirectory,
        ).catch(() => false)
      ) {
        claimMovedWithLock = false;
      }
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
  } catch (error) {
    operationError = error;
    throw error;
  } finally {
    if (
      !claimMovedWithLock &&
      (await pathExists(claimPath).catch(() => false))
    ) {
      try {
        await releaseOrAbandonStateMutationLock(releaseClaim);
      } catch (cleanupError) {
        if (operationError !== undefined && cleanupError !== operationError) {
          throw new AggregateError(
            [operationError, cleanupError],
            "Conversation identity reclaim and claim cleanup both failed",
          );
        }
        throw cleanupError;
      }
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
  beforeReleaseSnapshotRead?: (lockPath: string) => Promise<void>,
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
    if (!moved) {
      const canonical = await readLockSnapshot(directory, lockPath);
      if (canonical !== undefined) {
        throw new Error(
          "Conversation identity lock ownership changed during release",
        );
      }
      progress.phase = "removed-awaiting-sync";
      progress.tombstone = undefined;
      progress.snapshot = undefined;
      await syncParentDirectory(lockPath, syncDirectory);
      await assertPrivateStateDirectory(directory);
      return;
    }
    if (!snapshotsMatch(snapshot, moved)) {
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

  await beforeReleaseSnapshotRead?.(lockPath);
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

const orphanedMutationLockReleases = new Map<string, StateMutationLockLease>();

function mutationRecoveryKey(
  directory: PrivateStateDirectoryBinding,
  lockPath: string,
): string {
  return `${directory.device}:${directory.inode}:${lockPath}`;
}

async function recoverOrphanedMutationLockReleases(
  directory: PrivateStateDirectoryBinding,
): Promise<void> {
  const prefix = `${directory.device}:${directory.inode}:`;
  const pending = [...orphanedMutationLockReleases.entries()].filter(([key]) =>
    key.startsWith(prefix),
  );
  for (const [key, release] of pending) {
    await release();
    if (orphanedMutationLockReleases.get(key) === release) {
      orphanedMutationLockReleases.delete(key);
    }
  }
}

function createLockRelease(
  directory: PrivateStateDirectoryBinding,
  lockPath: string,
  owner: StateLockOwner,
  expectedSnapshot: LockSnapshot,
  syncDirectory: DirectorySync,
  beforeReleaseSnapshotRead?: (lockPath: string) => Promise<void>,
): StateMutationLockLease {
  const recoveryKey = mutationRecoveryKey(directory, lockPath);
  let released = false;
  let releaseAttempt: Promise<void> | undefined;
  const progress: LockReleaseProgress = { phase: "owned" };
  const release = (() => {
    if (released) return Promise.resolve();
    if (releaseAttempt) return releaseAttempt;
    const currentAttempt = releaseOwnedLock(
      directory,
      lockPath,
      owner,
      expectedSnapshot,
      syncDirectory,
      progress,
      beforeReleaseSnapshotRead,
    ).then(() => {
      released = true;
      if (orphanedMutationLockReleases.get(recoveryKey) === release) {
        orphanedMutationLockReleases.delete(recoveryKey);
      }
    });
    const trackedAttempt = currentAttempt.catch((error: unknown) => {
      if (releaseAttempt === trackedAttempt) releaseAttempt = undefined;
      throw error;
    });
    releaseAttempt = trackedAttempt;
    return trackedAttempt;
  }) as StateMutationLockLease;
  Object.defineProperties(release, {
    assertCurrent: {
      value: async (): Promise<void> => {
        if (released || progress.phase !== "owned") {
          throw new Error("Conversation identity lock is no longer current");
        }
        await assertPrivateStateDirectory(directory);
        const snapshot = await readLockSnapshot(directory, lockPath);
        if (
          !snapshot ||
          !snapshotsMatchOwner(snapshot, owner) ||
          !snapshotsMatch(expectedSnapshot, snapshot)
        ) {
          throw new Error(
            "Conversation identity lock ownership changed after acquisition",
          );
        }
      },
    },
    abandon: {
      value: async (): Promise<void> => {
        if (released) return;
        const existing = orphanedMutationLockReleases.get(recoveryKey);
        if (existing !== undefined && existing !== release) {
          throw new Error(
            "Conversation identity orphan lock recovery ownership changed",
          );
        }
        orphanedMutationLockReleases.set(recoveryKey, release);
      },
    },
  });
  return release;
}

export async function acquireStateMutationLock(
  directory: PrivateStateDirectoryBinding,
  stateFile: string,
  description: string,
  options: StateMutationLockOptions = {},
): Promise<StateMutationLockLease> {
  assertPathWithinBinding(directory, stateFile);
  await assertPrivateStateDirectory(directory);
  await recoverOrphanedMutationLockReleases(directory);
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
  const terminalProcessStatuses = new Map<string, Promise<ProcessStatus>>();
  const cachedProcessStatus: ProcessStatusResolver = (
    pid,
    expectedIdentity,
  ) => {
    const key = `${pid}:${expectedIdentity}`;
    const cached = terminalProcessStatuses.get(key);
    if (cached) return cached;
    return Promise.resolve(processStatusResolver(pid, expectedIdentity)).then(
      (status) => {
        if (status === "dead" || status === "dead-old-boot") {
          terminalProcessStatuses.set(key, Promise.resolve(status));
        }
        return status;
      },
    );
  };
  const reclaimOptions = {
    now: options.now ?? Date.now,
    processStatus: cachedProcessStatus,
    staleGraceMs: options.staleGraceMs ?? DEFAULT_STALE_LOCK_GRACE_MS,
    beforeInstalledSnapshotRead: options.beforeInstalledSnapshotRead,
    beforeLockOwnerRead: options.beforeLockOwnerRead,
    afterLockOwnerRead: options.afterLockOwnerRead,
  };

  for (let attempt = 0; attempt < attempts; attempt += 1) {
    await assertPrivateStateDirectory(directory);
    if (!(await pathExists(lockPath))) {
      const installed = await tryInstallPreparedLock(
        directory,
        lockPath,
        owner,
        syncDirectory,
        options.beforeInstalledSnapshotRead,
      );
      if (installed !== undefined) {
        return createLockRelease(
          directory,
          lockPath,
          owner,
          installed,
          syncDirectory,
          options.beforeReleaseSnapshotRead,
        );
      }
    }
    const reclaimed = await tryReclaimDeadLock(
      directory,
      lockPath,
      owner,
      syncDirectory,
      reclaimOptions,
    );
    if (reclaimed && !(await pathExists(lockPath))) {
      const installed = await tryInstallPreparedLock(
        directory,
        lockPath,
        owner,
        syncDirectory,
        options.beforeInstalledSnapshotRead,
      );
      if (installed !== undefined) {
        return createLockRelease(
          directory,
          lockPath,
          owner,
          installed,
          syncDirectory,
          options.beforeReleaseSnapshotRead,
        );
      }
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
): Promise<StateMutationLockLease> {
  return acquireStateMutationLock(
    directory,
    `${stateFile}${STATE_WRITER_LEASE_SUFFIX}`,
    description,
    options,
  );
}

interface SharedGenerationLease {
  state: "active" | "release-pending-retry" | "closed";
  readonly directoryDevice: number;
  readonly directoryInode: number;
  readonly lifecycle: PrivateStateDirectoryBinding;
  readonly writerLeaseFile: string;
  readonly releaseWriterLease: StateMutationLockLease;
  readonly holders: Map<
    string,
    { kind: PrivateStateGenerationHolder; state: "active" | "orphaned" }
  >;
}

const sharedGenerationLeases = new Map<string, SharedGenerationLease>();
const sharedGenerationOperationGates = new Map<string, Promise<void>>();

async function finishSharedGenerationRelease(
  lifecyclePath: string,
  shared: SharedGenerationLease,
): Promise<void> {
  if (shared.state === "closed") return;
  shared.state = "release-pending-retry";
  await shared.releaseWriterLease();
  shared.state = "closed";
  if (sharedGenerationLeases.get(lifecyclePath) === shared) {
    sharedGenerationLeases.delete(lifecyclePath);
  }
}

async function withSharedGenerationOperation<T>(
  lifecyclePath: string,
  operation: () => Promise<T>,
): Promise<T> {
  const previous = sharedGenerationOperationGates.get(lifecyclePath);
  let releaseGate!: () => void;
  const gate = new Promise<void>((resolveGate) => {
    releaseGate = resolveGate;
  });
  sharedGenerationOperationGates.set(lifecyclePath, gate);
  await previous;
  try {
    return await operation();
  } finally {
    releaseGate();
    if (sharedGenerationOperationGates.get(lifecyclePath) === gate) {
      sharedGenerationOperationGates.delete(lifecyclePath);
    }
  }
}

/**
 * Holds one parent-stable lease for the complete private-state generation.
 * Identity and installation may share it in one process, but duplicate owners
 * of either authority are rejected. A replacement directory cannot start a
 * parallel generation while the old generation remains open.
 */
export async function acquirePrivateStateGenerationLease(
  directory: PrivateStateDirectoryBinding,
  holder: PrivateStateGenerationHolder,
  options: StateMutationLockOptions = {},
): Promise<PrivateStateGenerationLease> {
  await assertPrivateStateDirectory(directory);
  const lifecyclePath = `${directory.path}.lifecycle-v1`;
  return withSharedGenerationOperation(lifecyclePath, async () => {
    let shared = sharedGenerationLeases.get(lifecyclePath);
    if (
      shared !== undefined &&
      (shared.state === "release-pending-retry" ||
        (shared.holders.size > 0 &&
          [...shared.holders.values()].every(
            (record) => record.state === "orphaned",
          )))
    ) {
      await finishSharedGenerationRelease(lifecyclePath, shared);
      shared = undefined;
    }
    if (shared?.state === "closed") {
      if (sharedGenerationLeases.get(lifecyclePath) === shared) {
        sharedGenerationLeases.delete(lifecyclePath);
      }
      shared = undefined;
    }
    if (shared === undefined) {
      const syncDirectory = options.syncDirectory ?? syncDirectoryForDurability;
      const lifecycle = await preparePrivateStateDirectory(
        lifecyclePath,
        syncDirectory,
      );
      const leaseStateFile = join(lifecycle.path, ".private-state-generation");
      const writerLeaseFile = `${leaseStateFile}${STATE_WRITER_LEASE_SUFFIX}.lock`;
      const releaseWriterLease = await acquireStateWriterLease(
        lifecycle,
        leaseStateFile,
        "Bridge private-state generation writer lease",
        options,
      );
      // The parent-stable writer lease proves that no conforming generation is
      // active. Only now is it safe to remove exact, non-authoritative crash
      // residue left by previous generations.
      try {
        await recoverOrphanedMutationLockReleases(lifecycle);
        await recoverOrphanedMutationLockReleases(directory);
        const residueProcessStatus =
          options.processStatus ?? defaultProcessStatus;
        await cleanPrivateStateResidue(
          lifecycle,
          syncDirectory,
          residueProcessStatus,
        );
        await cleanPrivateStateResidue(
          directory,
          syncDirectory,
          residueProcessStatus,
        );
      } catch (error) {
        let cleanupError: unknown;
        try {
          await releaseOrAbandonStateMutationLock(releaseWriterLease);
        } catch (releaseError) {
          cleanupError = releaseError;
        }
        if (cleanupError !== undefined) {
          throw new AggregateError(
            [error, cleanupError],
            "Bridge private-state residue cleanup and generation release both failed",
          );
        }
        throw error;
      }
      shared = {
        state: "active",
        directoryDevice: directory.device,
        directoryInode: directory.inode,
        lifecycle,
        writerLeaseFile,
        releaseWriterLease,
        holders: new Map(),
      };
      sharedGenerationLeases.set(lifecyclePath, shared);
    }

    if (
      shared.state !== "active" ||
      shared.directoryDevice !== directory.device ||
      shared.directoryInode !== directory.inode
    ) {
      throw new Error(
        "Conversation identity state directory generation is already bound",
      );
    }
    await assertPrivateStateDirectory(shared.lifecycle);
    await shared.releaseWriterLease.assertCurrent();
    if ([...shared.holders.values()].some((record) => record.kind === holder)) {
      throw new Error(`${holder} private-state generation is already open`);
    }

    const holderToken = randomUUID();
    shared.holders.set(holderToken, { kind: holder, state: "active" });
    let released = false;
    let releaseAttempt: Promise<void> | undefined;
    const assertCurrent = (): Promise<void> =>
      withSharedGenerationOperation(lifecyclePath, async () => {
        const current = sharedGenerationLeases.get(lifecyclePath);
        const record = shared.holders.get(holderToken);
        if (
          released ||
          current !== shared ||
          shared.state !== "active" ||
          record?.state !== "active"
        ) {
          throw new Error(`${holder} private-state generation is not current`);
        }
        await assertPrivateStateDirectory(directory);
        await assertPrivateStateDirectory(shared.lifecycle);
        await shared.releaseWriterLease.assertCurrent();
      });
    const release = (): Promise<void> => {
      if (released) return Promise.resolve();
      if (releaseAttempt) return releaseAttempt;
      const attempt = withSharedGenerationOperation(lifecyclePath, async () => {
        if (shared.state === "closed") {
          released = true;
          return;
        }
        const current = sharedGenerationLeases.get(lifecyclePath);
        const record = shared.holders.get(holderToken);
        if (current !== shared || record === undefined) {
          throw new Error(
            `${holder} private-state generation ownership changed`,
          );
        }
        if (shared.holders.size === 1) {
          await finishSharedGenerationRelease(lifecyclePath, shared);
          shared.holders.delete(holderToken);
        } else {
          if (shared.state !== "active") {
            throw new Error(
              `${holder} private-state generation release is pending`,
            );
          }
          shared.holders.delete(holderToken);
        }
        released = true;
      });
      const tracked = attempt.catch((error: unknown) => {
        if (releaseAttempt === tracked) releaseAttempt = undefined;
        throw error;
      });
      releaseAttempt = tracked;
      return tracked;
    };
    const abandon = (): Promise<void> =>
      withSharedGenerationOperation(lifecyclePath, async () => {
        if (released) return;
        const current = sharedGenerationLeases.get(lifecyclePath);
        const record = shared.holders.get(holderToken);
        if (current === shared && record !== undefined) {
          record.state = "orphaned";
        }
      });

    return {
      writerLeaseFile: shared.writerLeaseFile,
      assertCurrent,
      release,
      abandon,
    };
  });
}
