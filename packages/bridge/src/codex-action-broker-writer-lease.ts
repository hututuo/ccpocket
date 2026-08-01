import { createHash, randomUUID } from "node:crypto";
import {
  chmod,
  lstat,
  mkdir,
  readFile,
  rename,
  rm,
  writeFile,
} from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import type { CodexSharedRuntimeSafeDaemonIdentity } from "./codex-shared-runtime-control.js";

const LEASE_VERSION = 1;
const MAX_LEASE_FILE_BYTES = 16 * 1024;
const DEFAULT_HEARTBEAT_MS = 2_000;

interface LeaseOwnerRecord {
  version: typeof LEASE_VERSION;
  codexSourceId: string;
  socketDevice: number;
  socketInode: number;
  pid: number;
  processNonce: string;
  leaseEpoch: number;
  acquiredAt: string;
  heartbeatAt: string;
}

export interface CodexActionBrokerWriterLeaseHealth {
  held: boolean;
  leaseEpoch?: number;
  ownerPid?: number;
  lockPath?: string;
  reason?: "owned_elsewhere" | "unsafe_lock" | "identity_unavailable";
}

export interface CodexActionBrokerWriterLeaseOptions {
  rootDir?: string;
  pid?: number;
  now?: () => Date;
  randomToken?: () => string;
  processAlive?: (pid: number) => boolean;
  heartbeatMs?: number;
}

/**
 * Cross-process single-writer fence for one Codex source and one verified
 * daemon socket. A directory is the atomic ownership primitive: takeover first
 * renames the stale directory, so a previous owner can no longer pass the
 * exact nonce check before writing to app-server.
 *
 * A live PID is never stolen merely because a heartbeat is late. This makes an
 * event-loop stall fail closed; clean warm handoff must explicitly release the
 * lease after draining in-flight actions.
 */
export class CodexActionBrokerWriterLease {
  private readonly rootDir: string;
  private readonly pid: number;
  private readonly now: () => Date;
  private readonly processNonce: string;
  private readonly processAlive: (pid: number) => boolean;
  private readonly heartbeatMs: number;
  private heldOwner?: LeaseOwnerRecord;
  private lockPath?: string;
  private heartbeatTimer?: ReturnType<typeof setInterval>;
  private mutationTail: Promise<void> = Promise.resolve();

  constructor(
    private readonly codexSourceId: string,
    options: CodexActionBrokerWriterLeaseOptions = {},
  ) {
    if (!codexSourceId.trim() || codexSourceId.length > 128) {
      throw new Error("Codex Action Broker writer lease source ID is invalid");
    }
    this.rootDir =
      options.rootDir ?? join(homedir(), ".ccpocket", "codex-action-writer-v1");
    this.pid = options.pid ?? process.pid;
    this.now = options.now ?? (() => new Date());
    this.processNonce = options.randomToken?.() ?? randomUUID();
    this.processAlive = options.processAlive ?? defaultProcessAlive;
    this.heartbeatMs = normalizeHeartbeat(options.heartbeatMs);
  }

  get health(): CodexActionBrokerWriterLeaseHealth {
    if (this.heldOwner && this.lockPath) {
      return {
        held: true,
        leaseEpoch: this.heldOwner.leaseEpoch,
        ownerPid: this.pid,
        lockPath: this.lockPath,
      };
    }
    return { held: false, reason: "owned_elsewhere" };
  }

  async acquire(
    daemonIdentity: CodexSharedRuntimeSafeDaemonIdentity | null,
  ): Promise<CodexActionBrokerWriterLeaseHealth> {
    return this.serialize(async () => {
      if (!daemonIdentity) {
        await this.releaseInternal();
        return { held: false, reason: "identity_unavailable" };
      }
      validateDaemonIdentity(daemonIdentity);
      const targetPath = leasePathFor(
        this.rootDir,
        this.codexSourceId,
        daemonIdentity,
      );
      if (
        this.heldOwner &&
        this.lockPath === targetPath &&
        this.heldOwner.socketDevice === daemonIdentity.socketDevice &&
        this.heldOwner.socketInode === daemonIdentity.socketInode &&
        (await this.ownerStillMatches(this.heldOwner, targetPath))
      ) {
        return this.health;
      }
      await this.releaseInternal();
      await ensurePrivateDirectory(this.rootDir);

      for (let attempt = 0; attempt < 4; attempt += 1) {
        let createdLock = false;
        try {
          await mkdir(targetPath, { mode: 0o700 });
          createdLock = true;
          await chmod(targetPath, 0o700);
          const now = this.now().toISOString();
          const owner: LeaseOwnerRecord = {
            version: LEASE_VERSION,
            codexSourceId: this.codexSourceId,
            socketDevice: daemonIdentity.socketDevice,
            socketInode: daemonIdentity.socketInode,
            pid: this.pid,
            processNonce: this.processNonce,
            leaseEpoch: await this.advanceLeaseEpoch(),
            acquiredAt: now,
            heartbeatAt: now,
          };
          await writeOwner(targetPath, owner);
          this.heldOwner = owner;
          this.lockPath = targetPath;
          this.armHeartbeat();
          return this.health;
        } catch (error) {
          if ((error as NodeJS.ErrnoException).code !== "EEXIST") {
            // releaseInternal() cannot remove a directory until heldOwner is
            // published. If setup failed after mkdir (for example while
            // advancing the epoch or writing owner.json), remove only the
            // exact directory this attempt just created so it cannot strand
            // an unreadable source-global lock.
            if (createdLock) {
              await rm(targetPath, { recursive: true, force: true }).catch(
                () => undefined,
              );
            }
            await this.releaseInternal();
            return { held: false, reason: "unsafe_lock" };
          }
        }

        const existing = await readOwner(targetPath).catch(() => null);
        if (!existing) return { held: false, reason: "unsafe_lock" };
        if (
          existing.pid === this.pid &&
          existing.processNonce === this.processNonce
        ) {
          this.heldOwner = existing;
          this.lockPath = targetPath;
          this.armHeartbeat();
          return this.health;
        }
        if (this.processAlive(existing.pid)) {
          return {
            held: false,
            ownerPid: existing.pid,
            lockPath: targetPath,
            reason: "owned_elsewhere",
          };
        }

        const stalePath = `${targetPath}.stale-${this.processNonce}-${attempt}`;
        try {
          await rename(targetPath, stalePath);
          await rm(stalePath, { recursive: true, force: true });
        } catch (error) {
          const code = (error as NodeJS.ErrnoException).code;
          if (code !== "ENOENT" && code !== "EEXIST") {
            return { held: false, reason: "unsafe_lock" };
          }
        }
      }
      return { held: false, reason: "owned_elsewhere" };
    });
  }

  async assertHeld(
    daemonIdentity: CodexSharedRuntimeSafeDaemonIdentity | null,
  ): Promise<boolean> {
    await this.mutationTail;
    const owner = this.heldOwner;
    const path = this.lockPath;
    if (!owner || !path || !daemonIdentity) return false;
    if (
      owner.socketDevice !== daemonIdentity.socketDevice ||
      owner.socketInode !== daemonIdentity.socketInode
    ) {
      return false;
    }
    return this.ownerStillMatches(owner, path);
  }

  async release(): Promise<void> {
    await this.serialize(() => this.releaseInternal());
  }

  private async releaseInternal(): Promise<void> {
    this.clearHeartbeat();
    const owner = this.heldOwner;
    const path = this.lockPath;
    this.heldOwner = undefined;
    this.lockPath = undefined;
    if (!owner || !path || !(await this.ownerStillMatches(owner, path))) return;
    const releasePath = `${path}.release-${this.processNonce}`;
    try {
      await rename(path, releasePath);
      await rm(releasePath, { recursive: true, force: true });
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
  }

  private async ownerStillMatches(
    expected: LeaseOwnerRecord,
    path: string,
  ): Promise<boolean> {
    const current = await readOwner(path).catch(() => null);
    return (
      current !== null &&
      current.pid === expected.pid &&
      current.processNonce === expected.processNonce &&
      current.codexSourceId === expected.codexSourceId &&
      current.socketDevice === expected.socketDevice &&
      current.socketInode === expected.socketInode &&
      current.leaseEpoch === expected.leaseEpoch
    );
  }

  private armHeartbeat(): void {
    this.clearHeartbeat();
    this.heartbeatTimer = setInterval(() => {
      void this.serialize(async () => {
        const owner = this.heldOwner;
        const path = this.lockPath;
        if (!owner || !path || !(await this.ownerStillMatches(owner, path))) {
          this.clearHeartbeat();
          this.heldOwner = undefined;
          this.lockPath = undefined;
          return;
        }
        owner.heartbeatAt = this.now().toISOString();
        await writeOwner(path, owner);
      }).catch(() => {
        this.clearHeartbeat();
        this.heldOwner = undefined;
        this.lockPath = undefined;
      });
    }, this.heartbeatMs);
    this.heartbeatTimer.unref?.();
  }

  private clearHeartbeat(): void {
    if (!this.heartbeatTimer) return;
    clearInterval(this.heartbeatTimer);
    this.heartbeatTimer = undefined;
  }

  private async advanceLeaseEpoch(): Promise<number> {
    const sourceHash = sourceKey(this.codexSourceId);
    const epochPath = join(this.rootDir, `${sourceHash}.epoch`);
    let previous = 0;
    try {
      const raw = await readFile(epochPath, "utf8");
      const parsed = Number.parseInt(raw.trim(), 10);
      if (!Number.isSafeInteger(parsed) || parsed < 0) {
        throw new Error("unsafe lease epoch");
      }
      previous = parsed;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
    const next = previous + 1;
    await writePrivateFile(epochPath, `${next}\n`);
    return next;
  }

  private async serialize<T>(operation: () => Promise<T>): Promise<T> {
    const current = this.mutationTail.then(operation);
    this.mutationTail = current.then(
      () => undefined,
      () => undefined,
    );
    return current;
  }
}

function leasePathFor(
  rootDir: string,
  codexSourceId: string,
  _daemonIdentity: CodexSharedRuntimeSafeDaemonIdentity,
): string {
  const key = createHash("sha256")
    .update(codexSourceId)
    .digest("hex")
    .slice(0, 32);
  return join(rootDir, `${key}.lock`);
}

function sourceKey(codexSourceId: string): string {
  return createHash("sha256").update(codexSourceId).digest("hex").slice(0, 32);
}

function validateDaemonIdentity(
  identity: CodexSharedRuntimeSafeDaemonIdentity,
): void {
  if (
    !Number.isSafeInteger(identity.socketDevice) ||
    identity.socketDevice < 0 ||
    !Number.isSafeInteger(identity.socketInode) ||
    identity.socketInode < 0
  ) {
    throw new Error("Codex Action Broker daemon identity is invalid");
  }
}

async function ensurePrivateDirectory(path: string): Promise<void> {
  await mkdir(path, { recursive: true, mode: 0o700 });
  const stats = await lstat(path);
  if (!stats.isDirectory() || stats.isSymbolicLink()) {
    throw new Error("Codex Action Broker writer lease directory is unsafe");
  }
  if (!process.platform.startsWith("win") && (stats.mode & 0o077) !== 0) {
    await chmod(path, 0o700);
  }
}

async function writeOwner(
  path: string,
  owner: LeaseOwnerRecord,
): Promise<void> {
  await writePrivateFile(
    join(path, "owner.json"),
    `${JSON.stringify(owner)}\n`,
  );
}

async function writePrivateFile(path: string, value: string): Promise<void> {
  const temporary = join(
    dirname(path),
    `.${process.pid}-${randomUUID()}-${path.split("/").at(-1)}.tmp`,
  );
  await writeFile(temporary, value, { mode: 0o600, flag: "wx" });
  await chmod(temporary, 0o600);
  await rename(temporary, path);
}

async function readOwner(path: string): Promise<LeaseOwnerRecord> {
  const ownerPath = join(path, "owner.json");
  const stats = await lstat(ownerPath);
  if (
    !stats.isFile() ||
    stats.isSymbolicLink() ||
    stats.size > MAX_LEASE_FILE_BYTES ||
    (!process.platform.startsWith("win") && (stats.mode & 0o077) !== 0)
  ) {
    throw new Error("Codex Action Broker writer lease owner is unsafe");
  }
  const parsed = JSON.parse(await readFile(ownerPath, "utf8")) as unknown;
  if (!validOwner(parsed)) {
    throw new Error("Codex Action Broker writer lease owner is invalid");
  }
  return parsed;
}

function validOwner(value: unknown): value is LeaseOwnerRecord {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const owner = value as Partial<LeaseOwnerRecord>;
  return (
    owner.version === LEASE_VERSION &&
    typeof owner.codexSourceId === "string" &&
    owner.codexSourceId.length > 0 &&
    owner.codexSourceId.length <= 128 &&
    Number.isSafeInteger(owner.socketDevice) &&
    Number.isSafeInteger(owner.socketInode) &&
    Number.isSafeInteger(owner.pid) &&
    (owner.pid ?? 0) > 0 &&
    typeof owner.processNonce === "string" &&
    owner.processNonce.length > 0 &&
    Number.isSafeInteger(owner.leaseEpoch) &&
    (owner.leaseEpoch ?? 0) > 0 &&
    typeof owner.acquiredAt === "string" &&
    Number.isFinite(Date.parse(owner.acquiredAt)) &&
    typeof owner.heartbeatAt === "string" &&
    Number.isFinite(Date.parse(owner.heartbeatAt))
  );
}

function defaultProcessAlive(pid: number): boolean {
  if (!Number.isSafeInteger(pid) || pid <= 0) return true;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return (error as NodeJS.ErrnoException).code !== "ESRCH";
  }
}

function normalizeHeartbeat(value: number | undefined): number {
  if (value === undefined) return DEFAULT_HEARTBEAT_MS;
  if (!Number.isFinite(value) || value < 100 || value > 60_000) {
    throw new Error("Codex Action Broker writer heartbeat is invalid");
  }
  return Math.floor(value);
}
