import { createHash, randomUUID } from "node:crypto";
import { constants as fsConstants } from "node:fs";
import { chmod, lstat, mkdir, open, rename, rmdir, unlink } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import lockfile from "proper-lockfile";
import {
  FILE_TRANSFER_ETAG_PATTERN,
  FILE_TRANSFER_ID_PATTERN,
  FILE_TRANSFER_MAX_FILE_SIZE_BYTES,
} from "./file-transfer-constants.js";
import { readBoundedNoFollowMetadata } from "./file-transfer-safe-metadata.js";
import {
  DIAGNOSTIC_REPORT_PAYLOAD_MAX_BYTES,
  validateDiagnosticReportIdentity,
  validateDiagnosticReportMetadata,
  type DiagnosticReportMetadata,
  type FileTransferPurpose,
} from "./file-transfer-diagnostic.js";

export interface TransferFileIdentity {
  dev: number;
  ino: number;
  size: number;
  mtimeMs: number;
  ctimeMs: number;
}

export interface PersistedDownloadTransfer {
  transferId: string;
  tokenHash: string;
  etag: string;
  canonicalPath: string;
  /** Optional immutable browser-root boundary captured when the offer was issued. */
  canonicalRoot?: string;
  filename: string;
  mimeType: string;
  sizeBytes: number;
  identity: TransferFileIdentity;
  createdAt: number;
  expiresAt: number;
  retainUntil: number;
}

export interface PersistedUploadDirectoryIdentity {
  lexicalPath: string;
  canonicalPath: string;
  lexicalDev: number;
  lexicalIno: number;
  lexicalIsSymlink: boolean;
  targetDev: number;
  targetIno: number;
}

export interface PersistedDiagnosticReceipt {
  filename: string;
  savedPath: string;
  sizeBytes: number;
  purpose: "diagnostic_report";
  reportId: string;
  archiveSha256: string;
  mobileReportCanonicalSha256: string;
  committedAt: number;
}

export interface PersistedUploadTransfer {
  transferId: string;
  uploadTokenHash: string;
  resumeTokenHash: string;
  filename: string;
  sizeBytes: number;
  offset: number;
  status: "pending" | "committing" | "complete";
  /** A PATCH was durably announced before any unconfirmed bytes were written. */
  rollbackPending?: true;
  /** The rollback phase was durably announced before truncating a written tail. */
  rollbackTruncating?: true;
  partialPath?: string;
  partialIdentity?: TransferFileIdentity;
  finalFilename?: string;
  finalIdentity?: TransferFileIdentity;
  createdAt: number;
  updatedAt: number;
  expiresAt: number;
  retainUntil: number;
  purpose?: FileTransferPurpose;
  diagnosticReport?: DiagnosticReportMetadata;
  diagnosticReceipt?: PersistedDiagnosticReceipt;
}

interface FileTransferState {
  version: 2;
  uploadDirectoryIdentity?: PersistedUploadDirectoryIdentity;
  partialDirectoryIdentity?: PersistedUploadDirectoryIdentity;
  downloads: PersistedDownloadTransfer[];
  uploads: PersistedUploadTransfer[];
}

export interface FileTransferStateStoreOptions {
  filePath?: string;
  maxDownloads?: number;
  maxUploads?: number;
  now?: () => number;
  lockOwnerId?: string;
  warn?: (message: string) => void;
}

export interface FileTransferLockOwner {
  version: 1;
  nonce: string;
  pid: number;
  processStartedAt: string;
  acquiredAt: string;
  ownerId?: string;
}

export interface FileTransferLockInspection {
  stateFilePath: string;
  lockPath: string;
  ownerPath: string;
  recoveryPath: string;
  recoveryInProgress: boolean;
  locked: boolean;
  owner?: FileTransferLockOwner;
  ownerAlive?: boolean;
  recoverable: boolean;
  reason: string;
}

const DEFAULT_MAX_DOWNLOADS = 256;
const DEFAULT_MAX_UPLOADS = 256;
const HASH_PATTERN = /^[A-Za-z0-9_-]{43}$/;
const SHA256_PATTERN = /^[a-f0-9]{64}$/u;
export const FILE_TRANSFER_STATE_MAX_BYTES = 8 * 1024 * 1024;
const FILE_TRANSFER_MAX_PATH_LENGTH = 4_096;
const FILE_TRANSFER_MAX_FILENAME_LENGTH = 1_024;
const FILE_TRANSFER_MAX_MIME_TYPE_LENGTH = 256;
const FILE_TRANSFER_LOCK_OWNER_MAX_BYTES = 64 * 1024;

export function fileTransferStateFile(
  port: number | string = 8765,
  explicitFile?: string,
  bridgeInstanceId?: string,
): string {
  if (explicitFile?.trim()) return explicitFile.trim();
  const parsedPort = typeof port === "number" ? port : Number.parseInt(port, 10);
  const stableInstance = bridgeInstanceId?.trim();
  // A stable Bridge identity must survive a port change. The port is only a
  // fallback namespace for installations that do not have an identity yet.
  const namespace = stableInstance
    ? `-${createHash("sha256").update(stableInstance).digest("hex").slice(0, 12)}`
    : Number.isInteger(parsedPort) && parsedPort !== 8765
      ? `-${parsedPort}`
      : "";
  return join(homedir(), ".ccpocket", `file-transfers-v2${namespace}.json`);
}

export function fileTransferLockPaths(stateFilePath: string): {
  lockPath: string;
  ownerPath: string;
  recoveryPath: string;
} {
  return {
    lockPath: `${stateFilePath}.lock`,
    ownerPath: `${stateFilePath}.lock-owner.json`,
    recoveryPath: `${stateFilePath}.lock-recovery`,
  };
}

/** Read-only diagnosis. It never removes or refreshes a lock. */
export async function inspectFileTransferLock(
  stateFilePath: string,
): Promise<FileTransferLockInspection> {
  return inspectFileTransferLockInternal(stateFilePath, false);
}

async function inspectFileTransferLockInternal(
  stateFilePath: string,
  ignoreRecoveryClaim: boolean,
): Promise<FileTransferLockInspection> {
  const paths = fileTransferLockPaths(stateFilePath);
  const recoveryReason = ignoreRecoveryClaim
    ? undefined
    : await inspectRecoveryClaim(paths.recoveryPath);
  const recoveryInProgress = recoveryReason !== undefined;
  let lockStats: Awaited<ReturnType<typeof lstat>>;
  try {
    lockStats = await lstat(paths.lockPath);
  } catch (error) {
    if (nodeCode(error) === "ENOENT") {
      return {
        stateFilePath,
        ...paths,
        locked: false,
        recoveryInProgress,
        recoverable: false,
        reason: recoveryReason ?? "No file transfer lock is present",
      };
    }
    throw error;
  }
  if (!lockStats.isDirectory() || lockStats.isSymbolicLink()) {
    return {
      stateFilePath,
      ...paths,
      locked: true,
      recoveryInProgress,
      recoverable: false,
      reason: recoveryReason ?? "Lock path is not a safe lock directory",
    };
  }
  const owner = await readLockOwner(paths.ownerPath);
  if (!owner) {
    return {
      stateFilePath,
      ...paths,
      locked: true,
      recoveryInProgress,
      recoverable: false,
      reason: recoveryReason ?? "Lock owner metadata is missing or invalid; manual review is required",
    };
  }
  const ownerAlive = processIsAlive(owner.pid);
  return {
    stateFilePath,
    ...paths,
    locked: true,
    recoveryInProgress,
    owner,
    ownerAlive,
    recoverable: !recoveryInProgress && !ownerAlive,
    reason: recoveryReason ?? (ownerAlive
      ? `Lock owner PID ${owner.pid} is still alive`
      : `Lock owner PID ${owner.pid} is no longer alive`),
  };
}

/**
 * Explicit recovery for a verified dead owner. A recovery claim is respected
 * by startup before and after lock acquisition, preventing a second unlocker
 * from deleting a newly-created compliant Bridge lock.
 */
export async function unlockFileTransferLock(
  stateFilePath: string,
): Promise<FileTransferLockInspection> {
  const paths = fileTransferLockPaths(stateFilePath);
  await mkdir(dirname(stateFilePath), { recursive: true, mode: 0o700 });
  try {
    await mkdir(paths.recoveryPath, { mode: 0o700 });
  } catch (error) {
    if (nodeCode(error) === "EEXIST") {
      throw new Error("Another file transfer lock recovery is already running");
    }
    throw error;
  }
  try {
    const inspection = await inspectFileTransferLockInternal(stateFilePath, true);
    if (!inspection.locked) return inspection;
    if (!inspection.recoverable || !inspection.owner) {
      throw new Error(inspection.reason);
    }
    const before = await lstat(paths.lockPath);
    const confirmedOwner = await readLockOwner(paths.ownerPath);
    if (
      !confirmedOwner ||
      confirmedOwner.nonce !== inspection.owner.nonce ||
      processIsAlive(confirmedOwner.pid)
    ) {
      throw new Error("File transfer lock ownership changed during recovery");
    }
    const current = await lstat(paths.lockPath);
    if (before.dev !== current.dev || before.ino !== current.ino) {
      throw new Error("File transfer lock changed during recovery");
    }
    await rmdir(paths.lockPath);
    const ownerAfterRemoval = await readLockOwner(paths.ownerPath);
    if (ownerAfterRemoval?.nonce === confirmedOwner.nonce) {
      await unlink(paths.ownerPath);
    }
    await fsyncDirectory(dirname(stateFilePath));
    return {
      stateFilePath,
      ...paths,
      locked: false,
      recoveryInProgress: false,
      owner: confirmedOwner,
      ownerAlive: false,
      recoverable: false,
      reason: "Verified dead-owner lock removed",
    };
  } finally {
    await rmdir(paths.recoveryPath).catch(() => undefined);
  }
}

/** Bounded, atomic metadata persistence. Raw transfer secrets are never stored. */
export class FileTransferStateStore {
  readonly filePath: string;
  private readonly maxDownloads: number;
  private readonly maxUploads: number;
  private readonly now: () => number;
  private readonly lockOwnerId?: string;
  private readonly warn: (message: string) => void;
  private data: FileTransferState = { version: 2, downloads: [], uploads: [] };
  private initBarrier?: Promise<void>;
  private mutationQueue: Promise<void> = Promise.resolve();
  private releaseProcessLock?: () => Promise<void>;
  private lockCompromised?: Error;
  private lockOwnerNonce?: string;

  constructor(options: FileTransferStateStoreOptions = {}) {
    this.filePath = options.filePath ?? fileTransferStateFile();
    this.maxDownloads = options.maxDownloads ?? DEFAULT_MAX_DOWNLOADS;
    this.maxUploads = options.maxUploads ?? DEFAULT_MAX_UPLOADS;
    this.now = options.now ?? Date.now;
    this.lockOwnerId = options.lockOwnerId?.trim() || undefined;
    this.warn = options.warn ?? ((message) => console.warn(`[file-transfer] ${message}`));
    if (!Number.isSafeInteger(this.maxDownloads) || this.maxDownloads < 1) {
      throw new Error("File transfer maxDownloads must be positive");
    }
    if (!Number.isSafeInteger(this.maxUploads) || this.maxUploads < 1) {
      throw new Error("File transfer maxUploads must be positive");
    }
  }

  init(): Promise<void> {
    this.initBarrier ??= (async () => {
      await this.acquireProcessLock();
      try {
        await this.load();
      } catch (error) {
        await this.releaseLock();
        throw error;
      }
    })().catch((error) => {
      this.initBarrier = undefined;
      throw error;
    });
    return this.initBarrier;
  }

  async close(): Promise<void> {
    await this.mutationQueue.catch(() => undefined);
    await this.releaseLock();
    this.initBarrier = undefined;
  }

  async getUploadDirectoryIdentity(): Promise<PersistedUploadDirectoryIdentity | undefined> {
    await this.init();
    return this.enqueue(async () => {
      return this.data.uploadDirectoryIdentity
        ? { ...this.data.uploadDirectoryIdentity }
        : undefined;
    });
  }

  async getPartialDirectoryIdentity(): Promise<PersistedUploadDirectoryIdentity | undefined> {
    await this.init();
    return this.enqueue(async () => {
      return this.data.partialDirectoryIdentity
        ? { ...this.data.partialDirectoryIdentity }
        : undefined;
    });
  }

  /**
   * Pins destination and partial roots as one unit. A completed-only state may
   * safely adopt replacement directories; pending/committing bytes may not.
   */
  async bindUploadDirectories(
    uploadIdentity: PersistedUploadDirectoryIdentity,
    partialIdentity: PersistedUploadDirectoryIdentity,
  ): Promise<void> {
    if (!isUploadDirectoryIdentity(uploadIdentity) || !isUploadDirectoryIdentity(partialIdentity)) {
      throw new Error("Invalid file transfer directory identity");
    }
    await this.init();
    await this.enqueue(async () => {
      const uploadChanged = !sameDirectoryIdentity(
        this.data.uploadDirectoryIdentity,
        uploadIdentity,
      );
      const partialChanged = !sameDirectoryIdentity(
        this.data.partialDirectoryIdentity,
        partialIdentity,
      );
      if (!uploadChanged && !partialChanged) return;
      const alreadyBound = Boolean(
        this.data.uploadDirectoryIdentity || this.data.partialDirectoryIdentity,
      );
      const hasIncompleteUpload = this.data.uploads.some(
        (entry) => entry.status === "pending" || entry.status === "committing",
      );
      if (alreadyBound && hasIncompleteUpload) {
        throw new Error("Persisted file transfer directory identity changed");
      }
      this.data.uploadDirectoryIdentity = { ...uploadIdentity };
      this.data.partialDirectoryIdentity = { ...partialIdentity };
      await this.save();
    });
  }

  async getDownload(transferId: string): Promise<PersistedDownloadTransfer | undefined> {
    await this.init();
    return this.enqueue(async () => {
      const changed = this.pruneDownloads();
      if (changed) await this.save();
      const entry = this.data.downloads.find((item) => item.transferId === transferId);
      return entry ? cloneDownload(entry) : undefined;
    });
  }

  async upsertDownload(entry: PersistedDownloadTransfer): Promise<void> {
    if (!isDownload(entry)) throw new Error("Invalid download transfer metadata");
    await this.init();
    await this.enqueue(async () => {
      this.pruneDownloads();
      this.data.downloads = this.data.downloads.filter(
        (item) => item.transferId !== entry.transferId,
      );
      if (this.data.downloads.length >= this.maxDownloads) {
        throw new Error("File transfer download metadata capacity reached");
      }
      this.data.downloads.push(cloneDownload(entry));
      await this.save();
    });
  }

  async listDownloads(): Promise<PersistedDownloadTransfer[]> {
    await this.init();
    return this.enqueue(async () => {
      const changed = this.pruneDownloads();
      if (changed) await this.save();
      return this.data.downloads.map(cloneDownload);
    });
  }

  async removeDownload(transferId: string): Promise<void> {
    await this.init();
    await this.enqueue(async () => {
      const before = this.data.downloads.length;
      this.data.downloads = this.data.downloads.filter(
        (entry) => entry.transferId !== transferId,
      );
      if (before !== this.data.downloads.length) await this.save();
    });
  }

  async getUpload(transferId: string): Promise<PersistedUploadTransfer | undefined> {
    await this.init();
    return this.enqueue(async () => {
      const changed = this.pruneDownloads();
      if (changed) await this.save();
      const entry = this.data.uploads.find((item) => item.transferId === transferId);
      return entry ? cloneUpload(entry) : undefined;
    });
  }

  async listUploads(): Promise<PersistedUploadTransfer[]> {
    await this.init();
    return this.enqueue(async () => {
      const changed = this.pruneDownloads();
      if (changed) await this.save();
      return this.data.uploads.map(cloneUpload);
    });
  }

  async upsertUpload(entry: PersistedUploadTransfer): Promise<void> {
    if (!isUpload(entry)) throw new Error("Invalid upload transfer metadata");
    await this.init();
    await this.enqueue(async () => {
      this.pruneDownloads();
      this.data.uploads = this.data.uploads.filter(
        (item) => item.transferId !== entry.transferId,
      );
      if (this.data.uploads.length >= this.maxUploads) {
        throw new Error("File transfer upload metadata capacity reached");
      }
      this.data.uploads.push(cloneUpload(entry));
      await this.save();
    });
  }

  async removeUpload(transferId: string): Promise<void> {
    await this.init();
    await this.enqueue(async () => {
      const before = this.data.uploads.length;
      this.data.uploads = this.data.uploads.filter(
        (entry) => entry.transferId !== transferId,
      );
      if (before !== this.data.uploads.length) await this.save();
    });
  }

  private async load(): Promise<void> {
    await mkdir(dirname(this.filePath), { recursive: true, mode: 0o700 });
    let raw: string;
    let handle: Awaited<ReturnType<typeof open>> | undefined;
    try {
      const noFollow = typeof fsConstants.O_NOFOLLOW === "number"
        ? fsConstants.O_NOFOLLOW
        : 0;
      handle = await open(this.filePath, fsConstants.O_RDONLY | noFollow);
      const opened = await handle.stat();
      const lexical = await lstat(this.filePath);
      if (
        !opened.isFile() ||
        !lexical.isFile() ||
        lexical.isSymbolicLink() ||
        opened.dev !== lexical.dev ||
        opened.ino !== lexical.ino
      ) {
        throw new Error("File transfer state file must be a regular file");
      }
      if (
        !Number.isSafeInteger(opened.size) ||
        opened.size < 0 ||
        opened.size > FILE_TRANSFER_STATE_MAX_BYTES
      ) {
        throw new Error(
          `File transfer state file exceeds ${FILE_TRANSFER_STATE_MAX_BYTES} bytes`,
        );
      }
      raw = await readBoundedUtf8(handle, opened.size);
      await handle.chmod(0o600);
      const after = await handle.stat();
      const published = await lstat(this.filePath);
      if (
        !published.isFile() ||
        published.isSymbolicLink() ||
        after.dev !== opened.dev ||
        after.ino !== opened.ino ||
        after.size !== opened.size ||
        published.dev !== opened.dev ||
        published.ino !== opened.ino ||
        published.size !== opened.size
      ) {
        throw new Error("File transfer state file changed while loading");
      }
    } catch (error) {
      if (nodeCode(error) === "ELOOP") {
        throw new Error("File transfer state file must be a regular file", {
          cause: error,
        });
      }
      if (nodeCode(error) !== "ENOENT") throw error;
      this.data = { version: 2, downloads: [], uploads: [] };
      return;
    } finally {
      await handle?.close().catch(() => undefined);
    }
    let parsed: unknown;
    try {
      parsed = JSON.parse(raw);
    } catch (error) {
      throw new Error("File transfer state contains invalid JSON", { cause: error });
    }
    if (!parsed || typeof parsed !== "object") {
      throw new Error("File transfer state has an invalid root");
    }
    const candidate = parsed as Partial<FileTransferState>;
    if (
      candidate.version !== 2 ||
      !Array.isArray(candidate.downloads) ||
      !Array.isArray(candidate.uploads)
    ) {
      throw new Error("Unsupported file transfer state version");
    }
    if (
      (candidate.uploadDirectoryIdentity !== undefined &&
        !isUploadDirectoryIdentity(candidate.uploadDirectoryIdentity)) ||
      (candidate.partialDirectoryIdentity !== undefined &&
        !isUploadDirectoryIdentity(candidate.partialDirectoryIdentity))
    ) {
      throw new Error("File transfer directory identity is invalid");
    }
    if (!candidate.downloads.every(isDownload) || !candidate.uploads.every(isUpload)) {
      throw new Error("File transfer state contains invalid transfer metadata");
    }
    this.data = {
      version: 2,
      ...(isUploadDirectoryIdentity(candidate.uploadDirectoryIdentity)
        ? { uploadDirectoryIdentity: { ...candidate.uploadDirectoryIdentity } }
        : {}),
      ...(isUploadDirectoryIdentity(candidate.partialDirectoryIdentity)
        ? { partialDirectoryIdentity: { ...candidate.partialDirectoryIdentity } }
        : {}),
      downloads: candidate.downloads.map((entry) =>
        cloneDownload(entry as PersistedDownloadTransfer),
      ),
      uploads: candidate.uploads.map((entry) =>
        cloneUpload(entry as PersistedUploadTransfer),
      ),
    };
    const changed = this.pruneDownloads();
    if (this.data.uploads.length > this.maxUploads) {
      throw new Error("File transfer upload metadata exceeds capacity");
    }
    if (this.data.downloads.length > this.maxDownloads) {
      throw new Error("File transfer download metadata exceeds capacity");
    }
    if (changed) await this.save();
  }

  private enqueue<T>(operation: () => Promise<T>): Promise<T> {
    const checked = async (): Promise<T> => {
      this.assertLockHealthy();
      return operation();
    };
    const run = this.mutationQueue.then(checked, checked);
    this.mutationQueue = run.then(() => undefined, () => undefined);
    return run;
  }

  private pruneDownloads(): boolean {
    const now = this.now();
    const beforeDownloads = this.data.downloads.length;
    this.data.downloads = this.data.downloads.filter(
      (entry) => entry.retainUntil > now,
    );
    return beforeDownloads !== this.data.downloads.length;
  }

  private async save(): Promise<void> {
    this.assertLockHealthy();
    const directory = dirname(this.filePath);
    await mkdir(directory, { recursive: true, mode: 0o700 });
    const serialized = JSON.stringify(this.data, null, 2);
    if (Buffer.byteLength(serialized, "utf8") > FILE_TRANSFER_STATE_MAX_BYTES) {
      throw new Error(
        `File transfer state file exceeds ${FILE_TRANSFER_STATE_MAX_BYTES} bytes`,
      );
    }
    const temporary = `${this.filePath}.${randomUUID()}.tmp`;
    let handle: Awaited<ReturnType<typeof open>> | undefined;
    try {
      try {
        const current = await lstat(this.filePath);
        if (!current.isFile() || current.isSymbolicLink()) {
          throw new Error("File transfer state file changed");
        }
      } catch (error) {
        if (nodeCode(error) !== "ENOENT") throw error;
      }
      handle = await open(temporary, "wx", 0o600);
      await handle.writeFile(serialized, "utf8");
      await handle.sync();
      await handle.close();
      handle = undefined;
      await rename(temporary, this.filePath);
      const published = await lstat(this.filePath);
      if (!published.isFile() || published.isSymbolicLink()) {
        throw new Error("File transfer state publication failed");
      }
      await chmod(this.filePath, 0o600);
      await fsyncDirectory(directory);
    } catch (error) {
      await handle?.close().catch(() => undefined);
      await unlink(temporary).catch(() => undefined);
      throw error;
    }
  }

  private async acquireProcessLock(): Promise<void> {
    if (this.releaseProcessLock) return;
    const paths = fileTransferLockPaths(this.filePath);
    await mkdir(dirname(paths.lockPath), { recursive: true, mode: 0o700 });
    this.lockCompromised = undefined;
    try {
      await assertNoRecoveryClaim(paths.recoveryPath);
      this.releaseProcessLock = await lockfile.lock(this.filePath, {
        lockfilePath: paths.lockPath,
        realpath: false,
        retries: 0,
        // Never reclaim a stale lock automatically. Removing a stale path can
        // race a newly-acquired owner. Clean shutdowns release normally; an
        // unclean-exit lock intentionally disables only this optional feature
        // until an operator verifies there is no owner and removes the lock.
        stale: Number.MAX_SAFE_INTEGER,
        update: 30_000,
        onCompromised: (error) => {
          this.lockCompromised = error;
        },
      });
      // A recovery command may have claimed the path after our initial check
      // but before mkdir won. In that case immediately release and fail soft.
      await assertNoRecoveryClaim(paths.recoveryPath);
      const nonce = randomUUID();
      await this.writeLockOwner(paths.ownerPath, nonce);
      this.lockOwnerNonce = nonce;
    } catch (error) {
      if (this.releaseProcessLock) {
        const release = this.releaseProcessLock;
        this.releaseProcessLock = undefined;
        try {
          await release();
        } catch (releaseError) {
          this.reportLockReleaseFailure(releaseError, "initialization cleanup");
        }
      }
      this.lockOwnerNonce = undefined;
      if (nodeCode(error) === "ELOCKED") {
        throw new Error(
          "Another Bridge process owns the file transfer state, or an unclean-exit lock needs manual recovery",
          { cause: error },
        );
      }
      throw error;
    }
  }

  private async releaseLock(): Promise<void> {
    const release = this.releaseProcessLock;
    const ownerNonce = this.lockOwnerNonce;
    const ownerPath = fileTransferLockPaths(this.filePath).ownerPath;
    this.releaseProcessLock = undefined;
    this.lockOwnerNonce = undefined;
    this.lockCompromised = undefined;
    let released = !release;
    if (release) {
      try {
        await release();
        released = true;
      } catch (error) {
        released = false;
        this.reportLockReleaseFailure(error, "shutdown");
      }
    }
    if (released && ownerNonce) {
      const owner = await readLockOwner(ownerPath);
      if (owner?.nonce === ownerNonce) {
        await unlink(ownerPath).catch(() => undefined);
        await fsyncDirectory(dirname(ownerPath)).catch(() => undefined);
      }
    }
  }

  private reportLockReleaseFailure(
    error: unknown,
    phase: "initialization cleanup" | "shutdown",
  ): void {
    const lockPath = fileTransferLockPaths(this.filePath).lockPath;
    const detail = error instanceof Error ? error.message : String(error);
    const continuation = phase === "shutdown"
      ? "Bridge exit will continue"
      : "file transfer initialization will fail closed";
    try {
      this.warn(
        `State lock release failed during ${phase}; ${continuation} and ${lockPath} is left for safe diagnosis: ${detail}`,
      );
    } catch {
      // A logging sink must never turn the optional transfer teardown into a
      // Bridge-wide shutdown failure.
    }
  }

  private async writeLockOwner(path: string, nonce: string): Promise<void> {
    try {
      const stale = await lstat(path);
      if (!stale.isFile() || stale.isSymbolicLink()) {
        throw new Error("File transfer lock owner metadata path is unsafe");
      }
      await unlink(path);
    } catch (error) {
      if (nodeCode(error) !== "ENOENT") throw error;
    }
    const owner: FileTransferLockOwner = {
      version: 1,
      nonce,
      pid: process.pid,
      processStartedAt: new Date(
        Date.now() - process.uptime() * 1000,
      ).toISOString(),
      acquiredAt: new Date().toISOString(),
      ...(this.lockOwnerId ? { ownerId: this.lockOwnerId } : {}),
    };
    const handle = await open(path, "wx", 0o600);
    try {
      await handle.writeFile(JSON.stringify(owner, null, 2), "utf8");
      await handle.sync();
    } finally {
      await handle.close().catch(() => undefined);
    }
    await fsyncDirectory(dirname(path));
  }

  private assertLockHealthy(): void {
    if (!this.releaseProcessLock || this.lockCompromised) {
      throw new Error("File transfer state lock is not healthy", {
        cause: this.lockCompromised,
      });
    }
  }
}

async function readBoundedUtf8(
  handle: Awaited<ReturnType<typeof open>>,
  expectedSize: number,
): Promise<string> {
  const buffer = Buffer.allocUnsafe(expectedSize + 1);
  let offset = 0;
  while (offset < buffer.length) {
    const { bytesRead } = await handle.read(
      buffer,
      offset,
      buffer.length - offset,
      null,
    );
    if (bytesRead === 0) break;
    offset += bytesRead;
    if (offset > expectedSize) {
      throw new Error("File transfer state file changed while loading");
    }
  }
  if (offset !== expectedSize) {
    throw new Error("File transfer state file changed while loading");
  }
  return buffer.subarray(0, offset).toString("utf8");
}

async function fsyncDirectory(path: string): Promise<void> {
  let handle: Awaited<ReturnType<typeof open>> | undefined;
  try {
    handle = await open(path, "r");
    await handle.sync();
  } finally {
    await handle?.close().catch(() => undefined);
  }
}

function cloneIdentity(identity: TransferFileIdentity): TransferFileIdentity {
  return { ...identity };
}

function cloneDownload(entry: PersistedDownloadTransfer): PersistedDownloadTransfer {
  return { ...entry, identity: cloneIdentity(entry.identity) };
}

function cloneUpload(entry: PersistedUploadTransfer): PersistedUploadTransfer {
  return {
    ...entry,
    ...(entry.partialIdentity
      ? { partialIdentity: cloneIdentity(entry.partialIdentity) }
      : {}),
    ...(entry.finalIdentity
      ? { finalIdentity: cloneIdentity(entry.finalIdentity) }
      : {}),
    ...(entry.diagnosticReport
      ? { diagnosticReport: { ...entry.diagnosticReport } }
      : {}),
    ...(entry.diagnosticReceipt
      ? { diagnosticReceipt: { ...entry.diagnosticReceipt } }
      : {}),
  };
}

function isFiniteNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value);
}

function isSafeByteCount(value: unknown): value is number {
  return (
    typeof value === "number" &&
    Number.isSafeInteger(value) &&
    value >= 0 &&
    value <= FILE_TRANSFER_MAX_FILE_SIZE_BYTES
  );
}

function isIdentity(value: unknown): value is TransferFileIdentity {
  if (!value || typeof value !== "object") return false;
  const identity = value as Partial<TransferFileIdentity>;
  return (
    isFiniteNumber(identity.dev) &&
    isFiniteNumber(identity.ino) &&
    isSafeByteCount(identity.size) &&
    isFiniteNumber(identity.mtimeMs) &&
    isFiniteNumber(identity.ctimeMs)
  );
}

function isDiagnosticReceipt(value: unknown): value is PersistedDiagnosticReceipt {
  if (!value || typeof value !== "object") return false;
  const receipt = value as Partial<PersistedDiagnosticReceipt>;
  return (
    validLeafName(receipt.filename) &&
    validText(receipt.savedPath, FILE_TRANSFER_MAX_PATH_LENGTH) &&
    isSafeByteCount(receipt.sizeBytes) &&
    receipt.purpose === "diagnostic_report" &&
    typeof receipt.reportId === "string" &&
    validateDiagnosticReportIdentity(receipt.reportId) &&
    typeof receipt.archiveSha256 === "string" &&
    SHA256_PATTERN.test(receipt.archiveSha256) &&
    typeof receipt.mobileReportCanonicalSha256 === "string" &&
    SHA256_PATTERN.test(receipt.mobileReportCanonicalSha256) &&
    isFiniteNumber(receipt.committedAt)
  );
}

function sameDirectoryIdentity(
  left: PersistedUploadDirectoryIdentity | undefined,
  right: PersistedUploadDirectoryIdentity,
): boolean {
  return Boolean(
    left &&
    left.lexicalPath === right.lexicalPath &&
    left.canonicalPath === right.canonicalPath &&
    left.lexicalDev === right.lexicalDev &&
    left.lexicalIno === right.lexicalIno &&
    left.lexicalIsSymlink === right.lexicalIsSymlink &&
    left.targetDev === right.targetDev &&
    left.targetIno === right.targetIno
  );
}

function isDownload(value: unknown): value is PersistedDownloadTransfer {
  if (!value || typeof value !== "object") return false;
  const entry = value as Partial<PersistedDownloadTransfer>;
  return (
    validId(entry.transferId) &&
    typeof entry.tokenHash === "string" && HASH_PATTERN.test(entry.tokenHash) &&
    typeof entry.etag === "string" && FILE_TRANSFER_ETAG_PATTERN.test(entry.etag) &&
    validText(entry.canonicalPath, FILE_TRANSFER_MAX_PATH_LENGTH) &&
    (entry.canonicalRoot === undefined ||
      validText(entry.canonicalRoot, FILE_TRANSFER_MAX_PATH_LENGTH)) &&
    validLeafName(entry.filename) &&
    validText(entry.mimeType, FILE_TRANSFER_MAX_MIME_TYPE_LENGTH) &&
    isSafeByteCount(entry.sizeBytes) &&
    isIdentity(entry.identity) && entry.identity.size === entry.sizeBytes &&
    isFiniteNumber(entry.createdAt) &&
    isFiniteNumber(entry.expiresAt) &&
    isFiniteNumber(entry.retainUntil) &&
    entry.retainUntil >= entry.expiresAt
  );
}

function isUpload(value: unknown): value is PersistedUploadTransfer {
  if (!value || typeof value !== "object") return false;
  const entry = value as Partial<PersistedUploadTransfer>;
  const pendingValid =
    entry.status === "pending" &&
    (entry.rollbackPending === undefined || entry.rollbackPending === true) &&
    (entry.rollbackTruncating === undefined ||
      (entry.rollbackTruncating === true && entry.rollbackPending === true)) &&
    validText(entry.partialPath, FILE_TRANSFER_MAX_PATH_LENGTH) &&
    isIdentity(entry.partialIdentity) &&
    entry.partialIdentity.size === entry.offset &&
    entry.finalFilename === undefined &&
    entry.finalIdentity === undefined;
  const committingValid =
    entry.status === "committing" &&
    entry.rollbackPending === undefined &&
    entry.rollbackTruncating === undefined &&
    validText(entry.partialPath, FILE_TRANSFER_MAX_PATH_LENGTH) &&
    isIdentity(entry.partialIdentity) &&
    entry.partialIdentity.size === entry.offset &&
    entry.offset === entry.sizeBytes &&
    validLeafName(entry.finalFilename) &&
    entry.finalIdentity === undefined;
  const completeValid =
    entry.status === "complete" &&
    entry.rollbackPending === undefined &&
    entry.rollbackTruncating === undefined &&
    validLeafName(entry.finalFilename) &&
    entry.offset === entry.sizeBytes &&
    entry.partialPath === undefined &&
    entry.partialIdentity === undefined &&
    (entry.finalIdentity === undefined ||
      (isIdentity(entry.finalIdentity) && entry.finalIdentity.size === entry.sizeBytes));
  const diagnosticReceiptValid = entry.diagnosticReceipt === undefined ||
    (entry.purpose === "diagnostic_report" &&
      isDiagnosticReceipt(entry.diagnosticReceipt) &&
      entry.diagnosticReceipt.sizeBytes === entry.sizeBytes &&
      entry.diagnosticReceipt.reportId === entry.diagnosticReport?.reportId);
  return (
    validId(entry.transferId) &&
    typeof entry.uploadTokenHash === "string" && HASH_PATTERN.test(entry.uploadTokenHash) &&
    typeof entry.resumeTokenHash === "string" && HASH_PATTERN.test(entry.resumeTokenHash) &&
    validLeafName(entry.filename) &&
    (entry.purpose === undefined || entry.purpose === "file" || entry.purpose === "diagnostic_report") &&
    (entry.purpose !== "diagnostic_report"
      ? entry.diagnosticReport === undefined
      : validateDiagnosticReportMetadata(entry.diagnosticReport)) &&
    (entry.purpose === "diagnostic_report" || entry.finalIdentity === undefined) &&
    diagnosticReceiptValid &&
    isSafeByteCount(entry.sizeBytes) &&
    (entry.purpose !== "diagnostic_report" ||
      entry.sizeBytes <= DIAGNOSTIC_REPORT_PAYLOAD_MAX_BYTES) &&
    isSafeByteCount(entry.offset) && entry.offset <= entry.sizeBytes &&
    (pendingValid || committingValid || completeValid) &&
    isFiniteNumber(entry.createdAt) &&
    isFiniteNumber(entry.updatedAt) &&
    isFiniteNumber(entry.expiresAt) &&
    isFiniteNumber(entry.retainUntil)
  );
}

function validId(value: unknown): value is string {
  return typeof value === "string" && FILE_TRANSFER_ID_PATTERN.test(value);
}

function validText(value: unknown, maxLength: number): value is string {
  return (
    typeof value === "string" &&
    value.length > 0 &&
    value.length <= maxLength &&
    !value.includes("\0")
  );
}

function validLeafName(value: unknown): value is string {
  return (
    validText(value, FILE_TRANSFER_MAX_FILENAME_LENGTH) &&
    value !== "." &&
    value !== ".." &&
    !value.includes("/") &&
    !value.includes("\\")
  );
}

function isUploadDirectoryIdentity(
  value: unknown,
): value is PersistedUploadDirectoryIdentity {
  if (!value || typeof value !== "object") return false;
  const identity = value as Partial<PersistedUploadDirectoryIdentity>;
  return (
    validText(identity.lexicalPath, FILE_TRANSFER_MAX_PATH_LENGTH) &&
    validText(identity.canonicalPath, FILE_TRANSFER_MAX_PATH_LENGTH) &&
    isFiniteNumber(identity.lexicalDev) &&
    isFiniteNumber(identity.lexicalIno) &&
    typeof identity.lexicalIsSymlink === "boolean" &&
    isFiniteNumber(identity.targetDev) &&
    isFiniteNumber(identity.targetIno)
  );
}

async function readLockOwner(path: string): Promise<FileTransferLockOwner | undefined> {
  try {
    const raw = await readBoundedNoFollowMetadata(
      path,
      FILE_TRANSFER_LOCK_OWNER_MAX_BYTES,
      "File transfer lock owner metadata",
    );
    const parsed = JSON.parse(raw) as Partial<FileTransferLockOwner>;
    if (
      parsed.version !== 1 ||
      typeof parsed.nonce !== "string" ||
      !/^[0-9a-f-]{36}$/i.test(parsed.nonce) ||
      !Number.isSafeInteger(parsed.pid) ||
      Number(parsed.pid) <= 0 ||
      typeof parsed.processStartedAt !== "string" ||
      !Number.isFinite(Date.parse(parsed.processStartedAt)) ||
      typeof parsed.acquiredAt !== "string" ||
      !Number.isFinite(Date.parse(parsed.acquiredAt)) ||
      (parsed.ownerId !== undefined && typeof parsed.ownerId !== "string")
    ) return undefined;
    return {
      version: 1,
      nonce: parsed.nonce,
      pid: Number(parsed.pid),
      processStartedAt: parsed.processStartedAt,
      acquiredAt: parsed.acquiredAt,
      ...(parsed.ownerId ? { ownerId: parsed.ownerId } : {}),
    };
  } catch {
    return undefined;
  }
}

async function inspectRecoveryClaim(path: string): Promise<string | undefined> {
  try {
    const stats = await lstat(path);
    if (!stats.isDirectory() || stats.isSymbolicLink()) {
      return "Lock recovery claim path is unsafe; manual review is required";
    }
    return "File transfer lock recovery claim exists; another recovery may be active or interrupted";
  } catch (error) {
    if (nodeCode(error) === "ENOENT") return undefined;
    throw error;
  }
}

async function assertNoRecoveryClaim(path: string): Promise<void> {
  try {
    await lstat(path);
    throw new Error("File transfer lock recovery is in progress");
  } catch (error) {
    if (nodeCode(error) !== "ENOENT") throw error;
  }
}

function processIsAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return nodeCode(error) === "EPERM";
  }
}

function nodeCode(error: unknown): string | undefined {
  return typeof error === "object" && error !== null && "code" in error
    ? String((error as { code?: unknown }).code)
    : undefined;
}
