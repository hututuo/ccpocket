import { createHash, randomBytes, randomUUID, timingSafeEqual } from "node:crypto";
import type { FileHandle } from "node:fs/promises";
import { open, realpath, stat } from "node:fs/promises";
import { basename } from "node:path";
import {
  FILE_TRANSFER_ETAG_PATTERN,
  FILE_TRANSFER_ID_PATTERN,
  FILE_TRANSFER_MAX_FILE_SIZE_BYTES,
  FILE_TRANSFER_TOKEN_PATTERN,
} from "./file-transfer-constants.js";
import { FileTransferError, fileTransferErrorCode } from "./file-transfer-errors.js";
import type { PersistedDownloadTransfer, TransferFileIdentity } from "./file-transfer-state-store.js";
import { FileTransferStateStore } from "./file-transfer-state-store.js";
import { fileTransferMimeType } from "./file-transfer-utils.js";
import { isPathWithinAllowedDirectory, resolvePlatformPathFrom } from "./path-utils.js";

const DEFAULT_TTL_SECONDS = 24 * 60 * 60;
const DEFAULT_RETENTION_MS = 7 * 24 * 60 * 60 * 1000;
const MIN_TTL_SECONDS = 60;
const MAX_TTL_SECONDS = 7 * 24 * 60 * 60;
const MAX_TOKEN_ATTEMPTS = 100;

export interface FileTransferDownloadStoreOptions {
  stateStore: FileTransferStateStore;
  allowedDirs?: string[];
  platform?: NodeJS.Platform;
  maxFileSizeBytes?: number;
  now?: () => number;
  transferIdFactory?: () => string;
  tokenFactory?: () => string;
  etagFactory?: () => string;
  retentionMs?: number;
}

export interface IssuedDownloadTransfer {
  entry: PersistedDownloadTransfer;
  downloadToken: string;
}

export interface OpenedDownloadTransfer {
  entry: PersistedDownloadTransfer;
  handle: FileHandle;
}

export interface IssueDownloadTransferOptions {
  projectPath: string;
  ttlSeconds?: number;
  /** Exact source identity authorized by a descriptor-bound browser lookup. */
  expectedIdentity?: TransferFileIdentity;
  /** Fixed canonical root; never re-resolved while validating this transfer. */
  canonicalRoot?: string;
}

/** Persistent transfer-only source capabilities, independent of preview limits. */
export class FileTransferDownloadStore {
  readonly maxFileSizeBytes: number;
  private readonly stateStore: FileTransferStateStore;
  private readonly allowedDirs: string[];
  private readonly platform: NodeJS.Platform;
  private readonly now: () => number;
  private readonly transferIdFactory: () => string;
  private readonly tokenFactory: () => string;
  private readonly etagFactory: () => string;
  private readonly retentionMs: number;

  constructor(options: FileTransferDownloadStoreOptions) {
    this.stateStore = options.stateStore;
    this.allowedDirs = options.allowedDirs ?? [];
    this.platform = options.platform ?? process.platform;
    this.maxFileSizeBytes = options.maxFileSizeBytes ?? FILE_TRANSFER_MAX_FILE_SIZE_BYTES;
    this.now = options.now ?? Date.now;
    this.transferIdFactory = options.transferIdFactory ?? randomUUID;
    this.tokenFactory = options.tokenFactory ?? (() => randomBytes(32).toString("base64url"));
    this.etagFactory = options.etagFactory ?? (() => `"${randomBytes(24).toString("base64url")}"`);
    this.retentionMs = options.retentionMs ?? DEFAULT_RETENTION_MS;
  }

  async issue(
    filePath: string,
    options: IssueDownloadTransferOptions,
  ): Promise<IssuedDownloadTransfer> {
    const inspected = await this.inspect(
      filePath,
      options.projectPath,
      options.expectedIdentity,
      options.canonicalRoot,
    );
    const now = this.now();
    const existing = await this.stateStore.listDownloads();
    const downloadToken = this.createToken(existing);
    const entry: PersistedDownloadTransfer = {
      transferId: this.createTransferId(existing),
      tokenHash: hashTransferSecret(downloadToken),
      etag: this.createEtag(existing),
      canonicalPath: inspected.canonicalPath,
      ...(options.canonicalRoot === undefined
        ? {}
        : { canonicalRoot: options.canonicalRoot }),
      filename: inspected.filename,
      mimeType: inspected.mimeType,
      sizeBytes: inspected.identity.size,
      identity: inspected.identity,
      createdAt: now,
      expiresAt: now + ttlSeconds(options.ttlSeconds) * 1000,
      retainUntil: now + this.retentionMs,
    };
    await this.stateStore.upsertDownload(entry);
    return { entry, downloadToken };
  }

  async authorize(
    transferId: string,
    rawToken: string,
  ): Promise<PersistedDownloadTransfer> {
    const entry = await this.stateStore.getDownload(transferId);
    if (
      !entry ||
      entry.expiresAt <= this.now() ||
      !secretHashMatches(entry.tokenHash, rawToken)
    ) {
      throw new FileTransferError(404, "download_not_found", "Transfer is invalid or expired");
    }
    return entry;
  }

  async resume(
    transferId: string,
    rawToken: string,
  ): Promise<PersistedDownloadTransfer> {
    const entry = await this.stateStore.getDownload(transferId);
    if (
      !entry ||
      entry.retainUntil <= this.now() ||
      !secretHashMatches(entry.tokenHash, rawToken)
    ) {
      throw new FileTransferError(404, "download_not_found", "Transfer is invalid or expired");
    }
    // Re-open and verify the persisted source identity before extending lease.
    let handle: FileHandle | undefined;
    try {
      handle = (await this.openPersistedEntry(entry)).handle;
    } finally {
      await handle?.close().catch(() => undefined);
    }
    const renewed: PersistedDownloadTransfer = {
      ...entry,
      expiresAt: Math.min(
        this.now() + DEFAULT_TTL_SECONDS * 1000,
        entry.retainUntil,
      ),
    };
    await this.stateStore.upsertDownload(renewed);
    return renewed;
  }

  async openAuthorized(
    transferId: string,
    rawToken: string,
  ): Promise<OpenedDownloadTransfer> {
    const entry = await this.authorize(transferId, rawToken);
    return this.openPersistedEntry(entry);
  }

  private async openPersistedEntry(
    entry: PersistedDownloadTransfer,
  ): Promise<OpenedDownloadTransfer> {
    let handle: FileHandle;
    try {
      handle = await open(entry.canonicalPath, "r");
    } catch {
      throw new FileTransferError(410, "source_unavailable", "Source file is no longer available");
    }
    try {
      const stats = await handle.stat();
      if (!stats.isFile() || !identityMatches(entry.identity, identityOf(stats))) {
        throw new FileTransferError(409, "source_changed", "Source file changed after transfer creation");
      }
      const canonicalPath = await realpath(entry.canonicalPath);
      const canonicalStats = await stat(canonicalPath);
      if (
        canonicalPath !== entry.canonicalPath ||
        !identityMatches(entry.identity, identityOf(canonicalStats)) ||
        (entry.canonicalRoot !== undefined &&
          !isPathWithinAllowedDirectory(
            canonicalPath,
            entry.canonicalRoot,
            this.platform,
          )) ||
        !(await this.isAllowedCanonicalPath(canonicalPath))
      ) {
        throw new FileTransferError(409, "source_changed", "Source file changed after transfer creation");
      }
      return { entry, handle };
    } catch (error) {
      await handle.close().catch(() => undefined);
      throw error;
    }
  }

  async verifyAfterRead(opened: OpenedDownloadTransfer): Promise<void> {
    const after = await opened.handle.stat();
    if (!identityMatches(opened.entry.identity, identityOf(after))) {
      throw new FileTransferError(409, "source_changed", "Source file changed during transfer");
    }
  }

  remove(transferId: string): Promise<void> {
    return this.stateStore.removeDownload(transferId);
  }

  async cancel(transferId: string, rawToken: string): Promise<void> {
    const entry = await this.stateStore.getDownload(transferId);
    if (!entry || !secretHashMatches(entry.tokenHash, rawToken)) {
      throw new FileTransferError(404, "download_not_found", "Transfer is invalid or expired");
    }
    await this.stateStore.removeDownload(transferId);
  }

  private async inspect(
    filePath: string,
    projectPath: string,
    expectedIdentity?: TransferFileIdentity,
    canonicalRoot?: string,
  ): Promise<{ canonicalPath: string; filename: string; mimeType: string; identity: TransferFileIdentity }> {
    if (!filePath.trim() || !projectPath.trim()) {
      throw new FileTransferError(400, "invalid_path", "filePath and projectPath are required");
    }
    const resolved = resolvePlatformPathFrom(projectPath, filePath, this.platform);
    let handle: FileHandle;
    try {
      handle = await open(resolved, "r");
    } catch (error) {
      throw new FileTransferError(
        fileTransferErrorCode(error) === "ENOENT" ? 404 : 400,
        fileTransferErrorCode(error) === "ENOENT" ? "file_not_found" : "file_unreadable",
        "Source file is not readable",
      );
    }
    try {
      const openedStats = await handle.stat();
      if (!openedStats.isFile()) {
        throw new FileTransferError(400, "not_regular_file", "Only regular files can be transferred");
      }
      const identity = identityOf(openedStats);
      if (expectedIdentity && !identityMatches(expectedIdentity, identity)) {
        throw new FileTransferError(409, "source_changed", "Source file changed during inspection");
      }
      if (openedStats.size > this.maxFileSizeBytes) {
        throw new FileTransferError(413, "file_too_large", "File exceeds the 15 GiB transfer limit");
      }
      const canonicalPath = await realpath(resolved);
      const canonicalStats = await stat(canonicalPath);
      if (!identityMatches(identity, identityOf(canonicalStats))) {
        throw new FileTransferError(409, "source_changed", "Source file changed during inspection");
      }
      if (
        canonicalRoot !== undefined &&
        !isPathWithinAllowedDirectory(canonicalPath, canonicalRoot, this.platform)
      ) {
        throw new FileTransferError(409, "source_changed", "Source file changed during inspection");
      }
      if (!(await this.isAllowedCanonicalPath(canonicalPath))) {
        throw new FileTransferError(403, "path_not_allowed", "File is outside BRIDGE_ALLOWED_DIRS");
      }
      const filename = safeTransferFilename(canonicalPath);
      return { canonicalPath, filename, mimeType: fileTransferMimeType(filename), identity };
    } finally {
      await handle.close().catch(() => undefined);
    }
  }

  private async isAllowedCanonicalPath(filePath: string): Promise<boolean> {
    if (this.allowedDirs.length === 0) return true;
    for (const root of this.allowedDirs) {
      try {
        const canonicalRoot = await realpath(root);
        if (isPathWithinAllowedDirectory(filePath, canonicalRoot, this.platform)) return true;
      } catch {
        // Missing roots authorize nothing.
      }
    }
    return false;
  }

  private createTransferId(existing: readonly PersistedDownloadTransfer[]): string {
    for (let attempt = 0; attempt < MAX_TOKEN_ATTEMPTS; attempt += 1) {
      const candidate = this.transferIdFactory();
      if (
        FILE_TRANSFER_ID_PATTERN.test(candidate) &&
        !existing.some((entry) => entry.transferId === candidate)
      ) return candidate;
    }
    throw new FileTransferError(500, "transfer_id_failed", "Unable to create a transfer id");
  }

  private createToken(existing: readonly PersistedDownloadTransfer[]): string {
    for (let attempt = 0; attempt < MAX_TOKEN_ATTEMPTS; attempt += 1) {
      const candidate = this.tokenFactory();
      if (
        FILE_TRANSFER_TOKEN_PATTERN.test(candidate) &&
        !existing.some((entry) => entry.tokenHash === hashTransferSecret(candidate))
      ) return candidate;
    }
    throw new FileTransferError(500, "download_token_failed", "Unable to create a transfer token");
  }

  private createEtag(existing: readonly PersistedDownloadTransfer[]): string {
    for (let attempt = 0; attempt < MAX_TOKEN_ATTEMPTS; attempt += 1) {
      const candidate = this.etagFactory();
      if (
        FILE_TRANSFER_ETAG_PATTERN.test(candidate) &&
        !existing.some((entry) => entry.etag === candidate)
      ) return candidate;
    }
    throw new FileTransferError(500, "etag_failed", "Unable to create a transfer ETag");
  }
}

export function hashTransferSecret(secret: string): string {
  return createHash("sha256").update(secret).digest("base64url");
}

export function secretHashMatches(expectedHash: string, secret: string): boolean {
  const actual = hashTransferSecret(secret);
  const expectedBuffer = Buffer.from(expectedHash);
  const actualBuffer = Buffer.from(actual);
  return expectedBuffer.length === actualBuffer.length && timingSafeEqual(expectedBuffer, actualBuffer);
}

export function identityOf(stats: {
  dev: number;
  ino: number;
  size: number;
  mtimeMs: number;
  ctimeMs: number;
}): TransferFileIdentity {
  return {
    dev: stats.dev,
    ino: stats.ino,
    size: stats.size,
    mtimeMs: stats.mtimeMs,
    ctimeMs: stats.ctimeMs,
  };
}

export function identityMatches(expected: TransferFileIdentity, actual: TransferFileIdentity): boolean {
  return expected.dev === actual.dev &&
    expected.ino === actual.ino &&
    expected.size === actual.size &&
    expected.mtimeMs === actual.mtimeMs &&
    expected.ctimeMs === actual.ctimeMs;
}

function ttlSeconds(value: number | undefined): number {
  if (value === undefined) return DEFAULT_TTL_SECONDS;
  if (!Number.isSafeInteger(value) || value < MIN_TTL_SECONDS || value > MAX_TTL_SECONDS) {
    throw new FileTransferError(400, "invalid_ttl", `ttlSeconds must be between ${MIN_TTL_SECONDS} and ${MAX_TTL_SECONDS}`);
  }
  return value;
}

function safeTransferFilename(path: string): string {
  const value = basename(path).replace(/[\u0000-\u001f\u007f"\\]/g, "_").trim();
  let result = "";
  let bytes = 0;
  for (const character of value || "download") {
    const length = Buffer.byteLength(character, "utf8");
    if (bytes + length > 240) break;
    result += character;
    bytes += length;
  }
  return result || "download";
}
