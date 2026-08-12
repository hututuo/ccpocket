import { randomBytes } from "node:crypto";
import { constants as fsConstants, type Stats } from "node:fs";
import * as fsPromises from "node:fs/promises";
import {
  link,
  lstat,
  mkdir,
  open,
  realpath,
  stat,
  unlink,
} from "node:fs/promises";
import { homedir } from "node:os";
import { extname, join, resolve } from "node:path";
import {
  FILE_TRANSFER_MAX_FILE_SIZE_BYTES,
  FILE_TRANSFER_MAX_UPLOAD_CHUNK_BYTES,
  FILE_TRANSFER_ID_PATTERN,
  FILE_TRANSFER_TOKEN_PATTERN,
} from "./file-transfer-constants.js";
import { hashTransferSecret, identityMatches, identityOf, secretHashMatches } from "./file-transfer-download-store.js";
import { FileTransferError, fileTransferErrorCode } from "./file-transfer-errors.js";
import type {
  PersistedUploadDirectoryIdentity,
  PersistedUploadTransfer,
  TransferFileIdentity,
} from "./file-transfer-state-store.js";
import { FileTransferStateStore } from "./file-transfer-state-store.js";
import {
  DIAGNOSTIC_REPORT_MAX_BYTES,
  validateDiagnosticReportMetadata,
  type DiagnosticReportMetadata,
  type FileTransferPurpose,
} from "./file-transfer-diagnostic.js";

export { FILE_TRANSFER_MAX_FILE_SIZE_BYTES } from "./file-transfer-constants.js";

const DEFAULT_SESSION_TTL_MS = 24 * 60 * 60 * 1000;
const DEFAULT_RETENTION_MS = 7 * 24 * 60 * 60 * 1000;
const DEFAULT_DISK_SAFETY_MARGIN_BYTES = 512 * 1024 * 1024;
const DEFAULT_MAX_ACTIVE_UPLOADS = 2;
const MAX_FILENAME_BYTES = 240;
const MAX_COLLISION_ATTEMPTS = 10_000;
const MAX_TOKEN_ATTEMPTS = 100;
const INTERNAL_PARTIAL_PREFIX = ".ccpocket-upload-v2-";

interface DirectoryIdentity {
  canonicalPath: string;
  lexicalDev: number;
  lexicalIno: number;
  lexicalIsSymlink: boolean;
  dev: number;
  ino: number;
  partialPath: string;
  partialCanonicalPath: string;
  partialLexicalDev: number;
  partialLexicalIno: number;
  partialDev: number;
  partialIno: number;
}

export type PreparedUpload =
  | {
      status: "ready";
      entry: PersistedUploadTransfer;
      uploadToken: string;
      resumeToken: string;
    }
  | { status: "complete"; entry: PersistedUploadTransfer };

export interface UploadAppendResult {
  entry: PersistedUploadTransfer;
  completed: boolean;
}

export interface UploadPreparationOptions {
  purpose?: FileTransferPurpose;
  diagnosticReport?: DiagnosticReportMetadata;
}

export interface FileTransferUploadStoreOptions {
  stateStore: FileTransferStateStore;
  directory?: string;
  partialDirectory?: string;
  maxFileSizeBytes?: number;
  maxChunkSizeBytes?: number;
  sessionTtlMs?: number;
  retentionMs?: number;
  diskSafetyMarginBytes?: number;
  maxActiveUploads?: number;
  now?: () => number;
  tokenFactory?: () => string;
  availableBytes?: (path: string) => Promise<bigint>;
}

export class UploadOffsetConflictError extends FileTransferError {
  constructor(readonly uploadOffset: number) {
    super(409, "upload_offset_mismatch", "Upload-Offset does not match the server offset");
  }
}

export function defaultFileTransferDownloadDirectory(): string {
  return join(homedir(), "Downloads");
}

export function sanitizeFileTransferFilename(input: string): string {
  if (!input || input.includes("\0") || input.includes("/") || input.includes("\\")) {
    throw new FileTransferError(400, "invalid_filename", "filename must be one UTF-8 basename");
  }
  const normalized = input.normalize("NFC").replace(/[\u0000-\u001f\u007f]/g, "_").trim();
  if (!normalized || normalized === "." || normalized === ".." || normalized.startsWith(INTERNAL_PARTIAL_PREFIX)) {
    throw new FileTransferError(400, "invalid_filename", "Invalid filename");
  }
  const bounded = truncateUtf8(normalized, MAX_FILENAME_BYTES);
  if (!bounded || bounded === "." || bounded === "..") {
    throw new FileTransferError(400, "invalid_filename", "Invalid filename");
  }
  return bounded;
}

export function fileTransferStatfsAvailable(
  fsModule: { statfs?: unknown },
): boolean {
  return typeof fsModule.statfs === "function";
}

/** Resumable upload sessions with persisted offsets and completion tombstones. */
export class FileTransferUploadStore {
  readonly directory: string;
  readonly maxFileSizeBytes: number;
  readonly maxChunkSizeBytes: number;
  private readonly stateStore: FileTransferStateStore;
  private readonly requestedPartialDirectory: string;
  private readonly explicitPartialDirectory: boolean;
  private readonly sessionTtlMs: number;
  private readonly retentionMs: number;
  private readonly diskSafetyMarginBytes: number;
  private readonly maxActiveUploads: number;
  private readonly now: () => number;
  private readonly tokenFactory: () => string;
  private readonly availableBytes: (path: string) => Promise<bigint>;
  private readonly statfsSupported: boolean;
  private readyBarrier?: Promise<void>;
  private directoryBarrier?: Promise<DirectoryIdentity>;
  private readonly transferLocks = new Map<string, Promise<void>>();
  private reservationQueue: Promise<void> = Promise.resolve();
  private activeUploads = 0;

  constructor(options: FileTransferUploadStoreOptions) {
    this.stateStore = options.stateStore;
    this.directory = resolve(options.directory ?? defaultFileTransferDownloadDirectory());
    this.requestedPartialDirectory = resolve(
      options.partialDirectory ?? join(homedir(), ".ccpocket", "file-transfer-parts"),
    );
    this.explicitPartialDirectory = options.partialDirectory !== undefined;
    this.maxFileSizeBytes = options.maxFileSizeBytes ?? FILE_TRANSFER_MAX_FILE_SIZE_BYTES;
    this.maxChunkSizeBytes = options.maxChunkSizeBytes ?? FILE_TRANSFER_MAX_UPLOAD_CHUNK_BYTES;
    this.sessionTtlMs = options.sessionTtlMs ?? DEFAULT_SESSION_TTL_MS;
    this.retentionMs = options.retentionMs ?? DEFAULT_RETENTION_MS;
    this.diskSafetyMarginBytes = options.diskSafetyMarginBytes ?? DEFAULT_DISK_SAFETY_MARGIN_BYTES;
    this.maxActiveUploads = options.maxActiveUploads ?? DEFAULT_MAX_ACTIVE_UPLOADS;
    this.now = options.now ?? Date.now;
    this.tokenFactory = options.tokenFactory ?? (() => randomBytes(32).toString("base64url"));
    this.statfsSupported = Boolean(
      options.availableBytes || fileTransferStatfsAvailable(fsPromises),
    );
    this.availableBytes = options.availableBytes ?? (async (path) => {
      const statfs = fsPromises.statfs;
      if (typeof statfs !== "function") {
        throw new FileTransferError(
          503,
          "statfs_unavailable",
          "This Node runtime cannot safely reserve upload disk space",
        );
      }
      const volume = await statfs(path, { bigint: true });
      return volume.bavail * volume.bsize;
    });
  }

  init(): Promise<void> {
    this.readyBarrier ??= (async () => {
      if (!this.statfsSupported) {
        throw new FileTransferError(
          503,
          "statfs_unavailable",
          "This Node runtime cannot safely reserve upload disk space",
        );
      }
      await this.stateStore.init();
      await this.directoryIdentity();
      await this.withReservationLock(() => this.cleanupExpiredLocked());
    })().catch((error) => {
      this.readyBarrier = undefined;
      throw error;
    });
    return this.readyBarrier;
  }

  async close(): Promise<void> {
    await this.stateStore.close();
    this.readyBarrier = undefined;
    this.directoryBarrier = undefined;
  }

  async prepare(
    transferId: string,
    resumeToken: string,
    filename: string,
    sizeBytes: number,
    options: UploadPreparationOptions = {},
  ): Promise<PreparedUpload> {
    await this.init();
    const safeFilename = sanitizeFileTransferFilename(filename);
    this.validateDeclaredSize(sizeBytes);
    this.validatePurpose(options);
    if (!FILE_TRANSFER_ID_PATTERN.test(transferId) || !FILE_TRANSFER_TOKEN_PATTERN.test(resumeToken)) {
      throw new FileTransferError(400, "invalid_transfer_identity", "Invalid transfer id or resume token");
    }
    return this.withReservationLock(async () => {
      // Long-running Bridges must not rely on restart-time cleanup. Delete
      // expired partials/tombstones before lookup and before the bounded state
      // capacity check, under the same reservation serialization.
      await this.cleanupExpiredLocked();
      return this.withTransferLock(transferId, async () => {
        const existing = await this.stateStore.getUpload(transferId);
        if (existing) {
          return this.resumeLocked(existing, resumeToken, safeFilename, sizeBytes, options);
        }
        const resumeHash = hashTransferSecret(resumeToken);
        const uploads = await this.stateStore.listUploads();
        if (uploads.some((entry) => entry.resumeTokenHash === resumeHash)) {
          throw new FileTransferError(409, "resume_token_collision", "Resume token is already in use");
        }
        return this.prepareNewLocked(transferId, resumeToken, safeFilename, sizeBytes, options);
      });
    });
  }

  private async prepareNewLocked(
    transferId: string,
    resumeToken: string,
    safeFilename: string,
    sizeBytes: number,
    options: UploadPreparationOptions,
  ): Promise<PreparedUpload> {
    await this.ensureDiskReservation(sizeBytes);
    const uploadToken = await this.createToken();
    const directory = await this.assertDirectoryIdentity();
    const partialPath = join(directory.partialCanonicalPath, `${INTERNAL_PARTIAL_PREFIX}${transferId}.part`);
    let handle: Awaited<ReturnType<typeof open>> | undefined;
    let entry: PersistedUploadTransfer;
    try {
      handle = await open(partialPath, "wx", 0o600);
      await handle.sync();
      const stats = await handle.stat();
      await handle.close();
      handle = undefined;
      const now = this.now();
      entry = {
        transferId,
        uploadTokenHash: hashTransferSecret(uploadToken),
        resumeTokenHash: hashTransferSecret(resumeToken),
        filename: safeFilename,
        sizeBytes,
        offset: 0,
        status: "pending",
        partialPath,
        partialIdentity: identityOf(stats),
        createdAt: now,
        updatedAt: now,
        expiresAt: now + this.sessionTtlMs,
        retainUntil: now + this.retentionMs,
        ...(options.purpose === "diagnostic_report"
          ? { purpose: options.purpose, diagnosticReport: options.diagnosticReport }
          : {}),
      };
      await this.stateStore.upsertUpload(entry);
    } catch (error) {
      await handle?.close().catch(() => undefined);
      await unlink(partialPath).catch(() => undefined);
      await this.stateStore.removeUpload(transferId).catch(() => undefined);
      throw error;
    }
    // Finalization is intentionally outside the initialization cleanup scope.
    // Once pending metadata exists, a hard-link publication failure must retain
    // pending/committing state so restart recovery cannot publish a duplicate.
    if (sizeBytes === 0) {
      const complete = await this.finalize(entry);
      return { status: "complete", entry: complete };
    }
    return { status: "ready", entry, uploadToken, resumeToken };
  }

  async status(transferId: string, uploadToken: string): Promise<PersistedUploadTransfer> {
    await this.init();
    return this.withTransferLock(transferId, async () => {
      let entry = await this.authorizeUpload(transferId, uploadToken);
      if (entry.status === "committing") entry = await this.recoverCommit(entry);
      if (entry.status === "pending") entry = await this.reconcilePendingEntry(entry);
      return entry;
    });
  }

  async append(
    transferId: string,
    uploadToken: string,
    uploadOffset: number,
    contentLength: number,
    body: AsyncIterable<Buffer | Uint8Array | string>,
    signal: AbortSignal,
  ): Promise<UploadAppendResult> {
    if (!Number.isSafeInteger(contentLength) || contentLength < 1 || contentLength > this.maxChunkSizeBytes) {
      throw new FileTransferError(413, "upload_chunk_too_large", "Upload chunk exceeds the 16 MiB limit");
    }
    await this.init();
    return this.withTransferLock(transferId, async () => {
      let entry = await this.authorizeUpload(transferId, uploadToken);
      if (entry.status === "committing") entry = await this.recoverCommit(entry);
      if (entry.status === "complete") {
        throw new FileTransferError(409, "upload_already_complete", "Upload is already complete");
      }
      entry = await this.reconcilePendingEntry(entry);
      if (uploadOffset !== entry.offset) throw new UploadOffsetConflictError(entry.offset);
      if (entry.offset + contentLength > entry.sizeBytes) {
        throw new FileTransferError(413, "upload_exceeds_declared_size", "Chunk exceeds declared file size");
      }
      if (this.activeUploads >= this.maxActiveUploads) {
        throw new FileTransferError(429, "upload_concurrency_limit", "Too many uploads are active");
      }
      this.activeUploads += 1;
      try {
        const updated = await this.appendChunk(entry, contentLength, body, signal);
        if (updated.offset === updated.sizeBytes) {
          const completed = await this.finalize(updated);
          return { entry: completed, completed: true };
        }
        return { entry: updated, completed: false };
      } finally {
        this.activeUploads -= 1;
      }
    });
  }

  async cancel(transferId: string, resumeToken: string): Promise<void> {
    await this.init();
    await this.withTransferLock(transferId, async () => {
      let entry = await this.stateStore.getUpload(transferId);
      if (!entry || !secretHashMatches(entry.resumeTokenHash, resumeToken)) {
        throw new FileTransferError(404, "upload_not_found", "Upload is invalid or expired");
      }
      if (entry.status === "committing") entry = await this.recoverCommit(entry);
      if (entry.status === "complete") {
        throw new FileTransferError(409, "upload_already_complete", "Completed uploads cannot be cancelled");
      }
      if (entry.partialPath && entry.partialIdentity) {
        entry = await this.reconcilePendingEntry(entry);
        const controlled = await this.controlledPartialPath(entry);
        if (!entry.partialIdentity) {
          throw new FileTransferError(409, "upload_state_invalid", "Upload state is invalid");
        }
        await unlinkIfIdentity(controlled, entry.partialIdentity);
      }
      await this.stateStore.removeUpload(transferId);
    });
  }

  /** Reads one completed upload through the pinned Downloads identity. */
  async readCompletedUpload(
    entry: PersistedUploadTransfer,
    maxBytes = DIAGNOSTIC_REPORT_MAX_BYTES,
  ): Promise<Buffer> {
    await this.init();
    if (entry.status !== "complete" || !entry.finalFilename) {
      throw new FileTransferError(409, "upload_not_complete", "Upload is not complete");
    }
    if (!Number.isSafeInteger(maxBytes) || maxBytes < 0) {
      throw new FileTransferError(500, "upload_read_limit_invalid", "Upload read limit is invalid");
    }
    const directory = await this.assertDirectoryIdentity();
    const safeFilename = sanitizeFileTransferFilename(entry.finalFilename);
    if (safeFilename !== entry.finalFilename) {
      throw new FileTransferError(409, "upload_final_path_invalid", "Upload final path is invalid");
    }
    const destination = join(directory.canonicalPath, safeFilename);
    let handle: Awaited<ReturnType<typeof open>> | undefined;
    try {
      const noFollow = typeof fsConstants.O_NOFOLLOW === "number" ? fsConstants.O_NOFOLLOW : 0;
      handle = await open(destination, fsConstants.O_RDONLY | noFollow);
      const opened = await handle.stat();
      const lexical = await lstat(destination);
      if (
        !opened.isFile() ||
        !lexical.isFile() ||
        lexical.isSymbolicLink() ||
        opened.dev !== lexical.dev ||
        opened.ino !== lexical.ino ||
        (entry.finalIdentity !== undefined &&
          !sameFileObject(entry.finalIdentity, identityOf(opened))) ||
        opened.size !== entry.sizeBytes ||
        opened.size > maxBytes
      ) {
        throw new FileTransferError(409, "upload_final_changed", "Upload final file changed");
      }
      const bytes = await handle.readFile();
      if (bytes.length !== entry.sizeBytes) {
        throw new FileTransferError(409, "upload_final_changed", "Upload final file changed");
      }
      return bytes;
    } catch (error) {
      if (error instanceof FileTransferError) throw error;
      throw new FileTransferError(409, "upload_final_unavailable", "Upload final file is unavailable", { cause: error });
    } finally {
      await handle?.close().catch(() => undefined);
    }
  }

  /** Removes only the exact completed file represented by one upload entry. */
  async removeCompletedUpload(entry: PersistedUploadTransfer): Promise<void> {
    await this.init();
    await this.withTransferLock(entry.transferId, async () => {
      const current = await this.stateStore.getUpload(entry.transferId);
      if (!current) return;
      if (current.status !== "complete" || !current.finalFilename) {
        throw new FileTransferError(409, "upload_not_complete", "Upload is not complete");
      }
      const directory = await this.assertDirectoryIdentity();
      const safeFilename = sanitizeFileTransferFilename(current.finalFilename);
      if (safeFilename !== current.finalFilename) {
        throw new FileTransferError(409, "upload_final_path_invalid", "Upload final path is invalid");
      }
      const destination = join(directory.canonicalPath, safeFilename);
      const lexical = await lstat(destination).catch((error) => {
        if (fileTransferErrorCode(error) === "ENOENT") return undefined;
        throw error;
      });
      if (!lexical) {
        await this.stateStore.removeUpload(current.transferId);
        return;
      }
      if (
        !lexical.isFile() ||
        lexical.isSymbolicLink() ||
        lexical.size !== current.sizeBytes ||
        (current.finalIdentity !== undefined &&
          !sameFileObject(current.finalIdentity, identityOf(lexical)))
      ) {
        throw new FileTransferError(409, "upload_final_changed", "Upload final file changed");
      }
      await unlink(destination);
      await fsyncDirectory(directory.canonicalPath);
      await this.stateStore.removeUpload(current.transferId);
    });
  }

  private async cleanupExpiredLocked(): Promise<void> {
    const entries = await this.stateStore.listUploads();
    const now = this.now();
    for (const original of entries) {
      if (original.retainUntil > now) continue;
      await this.withTransferLock(original.transferId, async () => {
        let entry = await this.stateStore.getUpload(original.transferId);
        if (!entry || entry.retainUntil > this.now()) return;
        if (entry.status === "committing") {
          try { entry = await this.recoverCommit(entry); } catch { /* partial cleanup below */ }
        }
        if (entry.status !== "complete" && entry.partialPath && entry.partialIdentity) {
          const controlled = await this.controlledPartialPath(entry);
          await unlinkIfSameInode(controlled, entry.partialIdentity);
        }
        await this.stateStore.removeUpload(entry.transferId);
      });
    }
  }

  private async resumeLocked(
    original: PersistedUploadTransfer,
    resumeToken: string,
    filename: string,
    sizeBytes: number,
    options: UploadPreparationOptions,
  ): Promise<PreparedUpload> {
      let entry = original;
      if (!secretHashMatches(entry.resumeTokenHash, resumeToken)) {
        throw new FileTransferError(404, "upload_not_found", "Upload is invalid or expired");
      }
      if (entry.filename !== filename || entry.sizeBytes !== sizeBytes) {
        throw new FileTransferError(409, "upload_identity_mismatch", "Resume filename or size does not match");
      }
      if (
        (options.purpose ?? "file") !== (entry.purpose ?? "file") ||
        !sameDiagnosticMetadata(options.diagnosticReport, entry.diagnosticReport)
      ) {
        throw new FileTransferError(409, "upload_identity_mismatch", "Resume purpose or diagnostic metadata does not match");
      }
      if (entry.retainUntil <= this.now()) {
        throw new FileTransferError(410, "upload_expired", "Upload retention expired");
      }
      if (entry.status === "committing") entry = await this.recoverCommit(entry);
      if (entry.status === "complete") return { status: "complete", entry };
      entry = await this.reconcilePendingEntry(entry);
      await this.ensureDiskReservation(entry.sizeBytes - entry.offset, entry.transferId);
      const uploadToken = await this.createToken();
      const now = this.now();
      const updated: PersistedUploadTransfer = {
        ...entry,
        uploadTokenHash: hashTransferSecret(uploadToken),
        updatedAt: now,
        expiresAt: now + this.sessionTtlMs,
        retainUntil: now + this.retentionMs,
      };
      await this.stateStore.upsertUpload(updated);
      return { status: "ready", entry: updated, uploadToken, resumeToken };
  }

  private async authorizeUpload(transferId: string, uploadToken: string): Promise<PersistedUploadTransfer> {
    const entry = await this.stateStore.getUpload(transferId);
    if (!entry || entry.expiresAt <= this.now() || !secretHashMatches(entry.uploadTokenHash, uploadToken)) {
      throw new FileTransferError(404, "upload_not_found", "Upload is invalid or expired");
    }
    return entry;
  }

  private async appendChunk(
    entry: PersistedUploadTransfer,
    contentLength: number,
    body: AsyncIterable<Buffer | Uint8Array | string>,
    signal: AbortSignal,
  ): Promise<PersistedUploadTransfer> {
    const controlledPath = await this.controlledPartialPath(entry);
    const noFollow = typeof fsConstants.O_NOFOLLOW === "number" ? fsConstants.O_NOFOLLOW : 0;
    const handle = await open(controlledPath, fsConstants.O_RDWR | noFollow);
    let received = 0;
    let journalPersisted = false;
    try {
      const before = identityOf(await handle.stat());
      if (
        !entry.partialIdentity ||
        !identityMatches(entry.partialIdentity, before) ||
        before.size !== entry.offset
      ) {
        throw new FileTransferError(409, "upload_partial_changed", "Upload partial file changed");
      }
      // Persist the write journal before reading the first request byte. A
      // restart may only reconcile timestamp/tail changes when this marker
      // proves that this Bridge had an admitted PATCH in progress.
      entry = {
        ...entry,
        rollbackPending: true,
        rollbackTruncating: undefined,
        updatedAt: this.now(),
      };
      await this.stateStore.upsertUpload(entry);
      journalPersisted = true;
      for await (const rawChunk of body) {
        if (signal.aborted) throw new FileTransferError(499, "upload_paused", "Upload connection closed");
        const chunk = Buffer.isBuffer(rawChunk) ? rawChunk : Buffer.from(rawChunk);
        received += chunk.length;
        if (received > contentLength) {
          throw new FileTransferError(400, "upload_length_mismatch", "Chunk exceeds Content-Length");
        }
        await writeAll(handle, chunk, entry.offset + received - chunk.length);
      }
      if (signal.aborted) throw new FileTransferError(499, "upload_paused", "Upload connection closed");
      if (received !== contentLength) {
        throw new FileTransferError(400, "upload_length_mismatch", "Chunk is shorter than Content-Length");
      }
      await handle.sync();
      const stats = await handle.stat();
      const now = this.now();
      const updated: PersistedUploadTransfer = {
        ...entry,
        rollbackPending: undefined,
        rollbackTruncating: undefined,
        offset: entry.offset + received,
        partialIdentity: identityOf(stats),
        updatedAt: now,
        expiresAt: now + this.sessionTtlMs,
        retainUntil: now + this.retentionMs,
      };
      await this.stateStore.upsertUpload(updated);
      return updated;
    } catch (error) {
      if (journalPersisted) {
        try {
          const current = identityOf(await handle.stat());
          if (
            entry.partialIdentity &&
            sameInode(entry.partialIdentity, current) &&
            current.size === entry.offset &&
            identityMatches(entry.partialIdentity, current)
          ) {
            // The body failed before writing a byte. Clear only phase one;
            // never manufacture truncate authority without a written tail.
            await this.stateStore.upsertUpload({
              ...entry,
              rollbackPending: undefined,
              rollbackTruncating: undefined,
              updatedAt: this.now(),
            });
          } else if (
            entry.partialIdentity &&
            sameInode(entry.partialIdentity, current) &&
            current.size > entry.offset
          ) {
            // Announce the second phase before truncate. A restart may accept
            // same-size metadata drift only after a real tail proved that this
            // Bridge had begun writing beyond the confirmed offset.
            entry = {
              ...entry,
              rollbackPending: true,
              rollbackTruncating: true,
              updatedAt: this.now(),
            };
            await this.stateStore.upsertUpload(entry);
            await handle.truncate(entry.offset);
            await handle.sync();
            const rolledBack = await handle.stat();
            await this.stateStore.upsertUpload({
              ...entry,
              rollbackPending: undefined,
              rollbackTruncating: undefined,
              partialIdentity: identityOf(rolledBack),
              updatedAt: this.now(),
            });
          }
          // Same-size identity drift, inode replacement, or truncation below
          // the confirmed offset retains phase one and therefore fails closed.
        } catch {
          // Preserve rollbackPending when rollback or its metadata publication
          // cannot be proven durable. Startup reconciliation will retry safely.
        }
      }
      if (signal.aborted && !(error instanceof FileTransferError)) {
        throw new FileTransferError(499, "upload_paused", "Upload connection closed");
      }
      throw error;
    } finally {
      await handle.close().catch(() => undefined);
    }
  }

  private async finalize(entry: PersistedUploadTransfer): Promise<PersistedUploadTransfer> {
    if (entry.status === "committing") return this.recoverCommit(entry);
    if (entry.status === "complete") return entry;
    if (entry.offset !== entry.sizeBytes || !entry.partialPath || !entry.partialIdentity) {
      throw new FileTransferError(409, "upload_incomplete", "Upload is not complete");
    }
    entry = await this.reconcilePendingEntry(entry);
    const directory = await this.assertDirectoryIdentity();
    for (let attempt = 0; attempt < MAX_COLLISION_ATTEMPTS; attempt += 1) {
      const finalFilename = collisionFilename(entry.filename, attempt);
      const destination = join(directory.canonicalPath, finalFilename);
      const committing: PersistedUploadTransfer = {
        ...entry,
        status: "committing",
        finalFilename,
        updatedAt: this.now(),
      };
      await this.stateStore.upsertUpload(committing);
      try {
        await link(await this.controlledPartialPath(entry), destination);
      } catch (error) {
        if (fileTransferErrorCode(error) === "EEXIST") continue;
        throw error;
      }
      return this.finishCommittedLink(committing, destination);
    }
    throw new FileTransferError(409, "filename_collision_limit", "Unable to reserve a collision-free filename");
  }

  private async recoverCommit(entry: PersistedUploadTransfer): Promise<PersistedUploadTransfer> {
    if (entry.status !== "committing" || !entry.partialPath || !entry.partialIdentity || !entry.finalFilename) return entry;
    const directory = await this.assertDirectoryIdentity();
    const destination = join(directory.canonicalPath, entry.finalFilename);
    const destinationIdentity = await safeIdentity(destination);
    if (destinationIdentity && sameFileObject(entry.partialIdentity, destinationIdentity)) {
      return this.finishCommittedLink(entry, destination);
    }
    const controlledPath = await this.controlledPartialPath(entry);
    const partialIdentity = await safeIdentity(controlledPath);
    if (!partialIdentity || !identityMatches(entry.partialIdentity, partialIdentity)) {
      throw new FileTransferError(409, "upload_commit_state_invalid", "Upload commit state is invalid");
    }
    if (destinationIdentity) {
      const pending: PersistedUploadTransfer = { ...entry, status: "pending", finalFilename: undefined };
      await this.stateStore.upsertUpload(pending);
      return this.finalize(pending);
    }
    try {
      await link(controlledPath, destination);
    } catch (error) {
      if (fileTransferErrorCode(error) === "EEXIST") {
        const pending: PersistedUploadTransfer = { ...entry, status: "pending", finalFilename: undefined };
        await this.stateStore.upsertUpload(pending);
        return this.finalize(pending);
      }
      throw error;
    }
    return this.finishCommittedLink(entry, destination);
  }

  private async finishCommittedLink(
    entry: PersistedUploadTransfer,
    destination: string,
  ): Promise<PersistedUploadTransfer> {
    const destinationIdentity = await safeIdentity(destination);
    if (!entry.partialIdentity || !destinationIdentity || !sameFileObject(entry.partialIdentity, destinationIdentity)) {
      throw new FileTransferError(409, "destination_changed", "Upload destination changed during commit");
    }
    if (entry.partialPath) {
      const controlled = await this.controlledPartialPath(entry);
      await unlinkIfIdentity(controlled, entry.partialIdentity, true);
    }
    const directories = await this.directoryIdentity();
    await fsyncDirectory(directories.partialCanonicalPath);
    await fsyncDirectory(directories.canonicalPath);
    const now = this.now();
    const complete: PersistedUploadTransfer = {
      ...entry,
      status: "complete",
      rollbackPending: undefined,
      rollbackTruncating: undefined,
      offset: entry.sizeBytes,
      partialPath: undefined,
      partialIdentity: undefined,
      ...(entry.purpose === "diagnostic_report"
        ? { finalIdentity: destinationIdentity }
        : {}),
      updatedAt: now,
      retainUntil: now + this.retentionMs,
    };
    await this.stateStore.upsertUpload(complete);
    return complete;
  }

  private async reconcilePendingEntry(
    entry: PersistedUploadTransfer,
  ): Promise<PersistedUploadTransfer> {
    await this.assertDirectoryIdentity();
    if (entry.status !== "pending" || !entry.partialPath || !entry.partialIdentity) {
      throw new FileTransferError(409, "upload_state_invalid", "Upload state is invalid");
    }
    const controlled = await this.controlledPartialPath(entry);
    const noFollow = typeof fsConstants.O_NOFOLLOW === "number" ? fsConstants.O_NOFOLLOW : 0;
    let handle: Awaited<ReturnType<typeof open>> | undefined;
    try {
      handle = await open(controlled, fsConstants.O_RDWR | noFollow);
      const current = identityOf(await handle.stat());
      if (!sameInode(entry.partialIdentity, current) || current.size < entry.offset) {
        throw new FileTransferError(409, "upload_partial_changed", "Upload partial file changed");
      }
      if (
        current.size === entry.offset &&
        identityMatches(entry.partialIdentity, current)
      ) {
        if (!entry.rollbackPending) return entry;
        const cleared: PersistedUploadTransfer = {
          ...entry,
          rollbackPending: undefined,
          rollbackTruncating: undefined,
          updatedAt: this.now(),
        };
        await this.stateStore.upsertUpload(cleared);
        return cleared;
      }
      if (!entry.rollbackPending) {
        throw new FileTransferError(409, "upload_partial_changed", "Upload partial file changed");
      }
      if (current.size === entry.offset && !entry.rollbackTruncating) {
        // The first journal phase is persisted before the request body. It
        // cannot prove that same-length prefix changes came from this Bridge.
        throw new FileTransferError(409, "upload_partial_changed", "Upload partial file changed");
      }
      // A written tail is the only evidence that allows the first phase to
      // advance. Persist phase two before truncate so a kill after truncate
      // can safely refresh only the resulting metadata identity.
      if (current.size > entry.offset && !entry.rollbackTruncating) {
        entry = {
          ...entry,
          rollbackTruncating: true,
          updatedAt: this.now(),
        };
        await this.stateStore.upsertUpload(entry);
      }
      if (current.size > entry.offset) await handle.truncate(entry.offset);
      await handle.sync();
      const reconciled: PersistedUploadTransfer = {
        ...entry,
        rollbackPending: undefined,
        rollbackTruncating: undefined,
        partialIdentity: identityOf(await handle.stat()),
        updatedAt: this.now(),
      };
      await this.stateStore.upsertUpload(reconciled);
      return reconciled;
    } catch (error) {
      if (error instanceof FileTransferError) throw error;
      throw new FileTransferError(
        409,
        "upload_partial_changed",
        "Upload partial file changed",
        { cause: error },
      );
    } finally {
      await handle?.close().catch(() => undefined);
    }
  }

  private async controlledPartialPath(entry: PersistedUploadTransfer): Promise<string> {
    const directory = await this.assertDirectoryIdentity();
    const expected = join(
      directory.partialCanonicalPath,
      `${INTERNAL_PARTIAL_PREFIX}${entry.transferId}.part`,
    );
    if (entry.partialPath !== expected) {
      throw new FileTransferError(409, "upload_partial_path_invalid", "Upload partial path is invalid");
    }
    return expected;
  }

  private async ensureDiskReservation(additionalBytes: number, excludeTransferId?: string): Promise<void> {
    const directory = await this.assertDirectoryIdentity();
    const entries = await this.stateStore.listUploads();
    let reserved = BigInt(additionalBytes);
    for (const entry of entries) {
      if (
        entry.transferId !== excludeTransferId &&
        entry.status !== "complete" &&
        entry.retainUntil > this.now()
      ) {
        reserved += BigInt(entry.sizeBytes - entry.offset);
      }
    }
    const available = await this.availableBytes(directory.canonicalPath);
    if (reserved + BigInt(this.diskSafetyMarginBytes) > available) {
      throw new FileTransferError(507, "insufficient_storage", "Not enough reserved disk space for this upload");
    }
  }

  private validateDeclaredSize(sizeBytes: number): void {
    if (!Number.isSafeInteger(sizeBytes) || sizeBytes < 0 || sizeBytes > this.maxFileSizeBytes) {
      throw new FileTransferError(413, "file_too_large", "File exceeds the 15 GiB transfer limit");
    }
  }

  private validatePurpose(options: UploadPreparationOptions): void {
    if (options.purpose !== undefined && options.purpose !== "file" && options.purpose !== "diagnostic_report") {
      throw new FileTransferError(400, "invalid_upload_purpose", "Upload purpose is invalid");
    }
    if (options.purpose === "diagnostic_report" && !validateDiagnosticReportMetadata(options.diagnosticReport)) {
      throw new FileTransferError(400, "invalid_diagnostic_metadata", "Diagnostic metadata is invalid");
    }
    if ((options.purpose === undefined || options.purpose === "file") && options.diagnosticReport !== undefined) {
      throw new FileTransferError(400, "invalid_diagnostic_metadata", "Diagnostic metadata requires diagnostic_report purpose");
    }
  }

  private async createToken(): Promise<string> {
    const uploads = await this.stateStore.listUploads();
    for (let attempt = 0; attempt < MAX_TOKEN_ATTEMPTS; attempt += 1) {
      const candidate = this.tokenFactory();
      const hash = hashTransferSecret(candidate);
      if (
        FILE_TRANSFER_TOKEN_PATTERN.test(candidate) &&
        !uploads.some(
          (entry) =>
            entry.uploadTokenHash === hash || entry.resumeTokenHash === hash,
        )
      ) return candidate;
    }
    throw new FileTransferError(500, "upload_token_failed", "Unable to create an upload token");
  }

  private directoryIdentity(): Promise<DirectoryIdentity> {
    this.directoryBarrier ??= this.loadDirectoryIdentity().catch((error) => {
      this.directoryBarrier = undefined;
      throw error;
    });
    return this.directoryBarrier;
  }

  private async loadDirectoryIdentity(): Promise<DirectoryIdentity> {
    await mkdir(this.directory, { recursive: true });
    const lexical = await lstat(this.directory);
    if (!lexical.isDirectory() && !lexical.isSymbolicLink()) {
      throw new FileTransferError(503, "download_directory_unsafe", "Download directory is unavailable");
    }
    const canonicalPath = await realpath(this.directory);
    const target = await stat(canonicalPath);
    if (!target.isDirectory()) {
      throw new FileTransferError(503, "download_directory_unsafe", "Download directory is unavailable");
    }
    const identity: PersistedUploadDirectoryIdentity = {
      lexicalPath: this.directory,
      canonicalPath,
      lexicalDev: lexical.dev,
      lexicalIno: lexical.ino,
      lexicalIsSymlink: lexical.isSymbolicLink(),
      targetDev: target.dev,
      targetIno: target.ino,
    };
    let partialPath = this.requestedPartialDirectory;
    let privateDirectory = await ensurePrivateRealDirectory(partialPath);
    let partialLexical = privateDirectory.lexical;
    let partialCanonicalPath = privateDirectory.canonicalPath;
    let partialTarget = privateDirectory.target;
    if (partialTarget.dev !== target.dev) {
      if (this.explicitPartialDirectory) {
        throw new FileTransferError(503, "partial_directory_cross_device", "Configured partial directory must be on the destination volume");
      }
      partialPath = join(canonicalPath, ".ccpocket-file-transfer-parts");
      privateDirectory = await ensurePrivateRealDirectory(partialPath);
      partialLexical = privateDirectory.lexical;
      partialCanonicalPath = privateDirectory.canonicalPath;
      partialTarget = privateDirectory.target;
      if (
        !partialLexical.isDirectory() ||
        partialLexical.isSymbolicLink() ||
        partialTarget.dev !== target.dev
      ) {
        throw new FileTransferError(503, "partial_directory_cross_device", "Unable to create a same-volume private partial directory");
      }
    }
    const partialIdentity: PersistedUploadDirectoryIdentity = {
      lexicalPath: partialPath,
      canonicalPath: partialCanonicalPath,
      lexicalDev: partialLexical.dev,
      lexicalIno: partialLexical.ino,
      lexicalIsSymlink: false,
      targetDev: partialTarget.dev,
      targetIno: partialTarget.ino,
    };
    try {
      await this.stateStore.bindUploadDirectories(identity, partialIdentity);
    } catch (error) {
      throw new FileTransferError(
        503,
        "transfer_directory_changed",
        "File transfer destination or partial directory changed while an upload is incomplete",
        { cause: error },
      );
    }
    return {
      canonicalPath: identity.canonicalPath,
      lexicalDev: identity.lexicalDev,
      lexicalIno: identity.lexicalIno,
      lexicalIsSymlink: identity.lexicalIsSymlink,
      dev: identity.targetDev,
      ino: identity.targetIno,
      partialPath: partialIdentity.lexicalPath,
      partialCanonicalPath: partialIdentity.canonicalPath,
      partialLexicalDev: partialIdentity.lexicalDev,
      partialLexicalIno: partialIdentity.lexicalIno,
      partialDev: partialIdentity.targetDev,
      partialIno: partialIdentity.targetIno,
    };
  }

  private async assertDirectoryIdentity(): Promise<DirectoryIdentity> {
    const expected = await this.directoryIdentity();
    try {
      const lexical = await lstat(this.directory);
      const canonicalPath = await realpath(this.directory);
      const target = await stat(canonicalPath);
      const partialLexical = await lstat(expected.partialPath);
      const partialCanonicalPath = await realpath(expected.partialPath);
      const partialTarget = await stat(partialCanonicalPath);
      if (
        (!lexical.isDirectory() && !lexical.isSymbolicLink()) ||
        lexical.isSymbolicLink() !== expected.lexicalIsSymlink ||
        lexical.dev !== expected.lexicalDev ||
        lexical.ino !== expected.lexicalIno ||
        !target.isDirectory() ||
        canonicalPath !== expected.canonicalPath ||
        target.dev !== expected.dev ||
        target.ino !== expected.ino
        || !partialLexical.isDirectory()
        || partialLexical.isSymbolicLink()
        || partialLexical.dev !== expected.partialLexicalDev
        || partialLexical.ino !== expected.partialLexicalIno
        || partialCanonicalPath !== expected.partialCanonicalPath
        || partialTarget.dev !== expected.partialDev
        || partialTarget.ino !== expected.partialIno
        || partialTarget.dev !== target.dev
      ) throw new Error("changed");
      return expected;
    } catch {
      throw new FileTransferError(503, "download_directory_changed", "Download directory changed");
    }
  }

  private withTransferLock<T>(transferId: string, operation: () => Promise<T>): Promise<T> {
    const previous = this.transferLocks.get(transferId) ?? Promise.resolve();
    const run = previous.then(operation, operation);
    const settled = run.then(() => undefined, () => undefined);
    this.transferLocks.set(transferId, settled);
    void settled.finally(() => {
      if (this.transferLocks.get(transferId) === settled) this.transferLocks.delete(transferId);
    });
    return run;
  }

  private withReservationLock<T>(operation: () => Promise<T>): Promise<T> {
    const run = this.reservationQueue.then(operation, operation);
    this.reservationQueue = run.then(() => undefined, () => undefined);
    return run;
  }
}

async function ensurePrivateRealDirectory(path: string): Promise<{
  lexical: Stats;
  canonicalPath: string;
  target: Stats;
}> {
  let initial: Stats;
  try {
    initial = await lstat(path);
  } catch (error) {
    if (fileTransferErrorCode(error) !== "ENOENT") throw error;
    await mkdir(path, { recursive: true, mode: 0o700 });
    initial = await lstat(path);
  }
  if (!initial.isDirectory() || initial.isSymbolicLink()) {
    throw new FileTransferError(
      503,
      "partial_directory_unsafe",
      "Partial directory must be a real private directory",
    );
  }
  let pinned: Stats;
  let handle: Awaited<ReturnType<typeof open>> | undefined;
  try {
    if (process.platform === "win32") {
      // Windows mode bits do not provide POSIX directory privacy. Avoid
      // chmod(path) entirely so a replacement symlink can never cause a side
      // effect, then prove the lexical and resolved identities are unchanged.
      pinned = initial;
    } else {
      if (typeof fsConstants.O_NOFOLLOW !== "number") {
        throw new FileTransferError(
          503,
          "partial_directory_unsafe",
          "This platform cannot safely pin the private partial directory",
        );
      }
      const directoryOnly = typeof fsConstants.O_DIRECTORY === "number"
        ? fsConstants.O_DIRECTORY
        : 0;
      handle = await open(
        path,
        fsConstants.O_RDONLY | fsConstants.O_NOFOLLOW | directoryOnly,
      );
      pinned = await handle.stat();
      if (!pinned.isDirectory()) {
        throw new FileTransferError(
          503,
          "partial_directory_unsafe",
          "Partial directory must be a real private directory",
        );
      }
      // fchmod applies to the already pinned inode. A path swap between lstat
      // and this call cannot redirect the permission change to a symlink target.
      await handle.chmod(0o700);
      const secured = await handle.stat();
      if (secured.dev !== pinned.dev || secured.ino !== pinned.ino) {
        throw new FileTransferError(
          503,
          "partial_directory_unsafe",
          "Partial directory changed while it was secured",
        );
      }
      pinned = secured;
    }
    const lexical = await lstat(path);
    const canonicalPath = await realpath(path);
    const target = await stat(canonicalPath);
    if (
      !lexical.isDirectory() ||
      lexical.isSymbolicLink() ||
      lexical.dev !== pinned.dev ||
      lexical.ino !== pinned.ino ||
      !target.isDirectory() ||
      target.dev !== pinned.dev ||
      target.ino !== pinned.ino
    ) {
      throw new FileTransferError(
        503,
        "partial_directory_unsafe",
        "Partial directory identity is unsafe",
      );
    }
    return { lexical, canonicalPath, target };
  } catch (error) {
    if (error instanceof FileTransferError) throw error;
    throw new FileTransferError(
      503,
      "partial_directory_unsafe",
      "Partial directory could not be pinned safely",
      { cause: error },
    );
  } finally {
    await handle?.close().catch(() => undefined);
  }
}

async function writeAll(handle: Awaited<ReturnType<typeof open>>, buffer: Buffer, position: number): Promise<void> {
  let offset = 0;
  while (offset < buffer.length) {
    const result = await handle.write(buffer, offset, buffer.length - offset, position + offset);
    if (result.bytesWritten <= 0) throw new Error("Unable to make progress writing upload");
    offset += result.bytesWritten;
  }
}

function truncateUtf8(value: string, maxBytes: number): string {
  let result = "";
  let bytes = 0;
  for (const character of value) {
    const length = Buffer.byteLength(character, "utf8");
    if (bytes + length > maxBytes) break;
    result += character;
    bytes += length;
  }
  return result;
}

function collisionFilename(filename: string, attempt: number): string {
  if (attempt === 0) return filename;
  const rawExtension = extname(filename);
  const suffixWithoutExtension = ` (${attempt})`;
  const extension = Buffer.byteLength(rawExtension) + Buffer.byteLength(suffixWithoutExtension) <= MAX_FILENAME_BYTES
    ? rawExtension
    : "";
  const stem = filename.slice(0, filename.length - rawExtension.length) || "file";
  const suffix = `${suffixWithoutExtension}${extension}`;
  return `${truncateUtf8(stem, MAX_FILENAME_BYTES - Buffer.byteLength(suffix))}${suffix}`;
}

async function safeIdentity(path: string): Promise<TransferFileIdentity | undefined> {
  try {
    const stats = await lstat(path);
    return stats.isFile() && !stats.isSymbolicLink() ? identityOf(stats) : undefined;
  } catch {
    return undefined;
  }
}

async function unlinkIfIdentity(
  path: string,
  identity: TransferFileIdentity,
  allowLinkCtimeChange = false,
): Promise<void> {
  const current = await cleanupIdentity(path);
  if (!current) return;
  const matches = allowLinkCtimeChange
    ? sameFileObject(identity, current)
    : identityMatches(identity, current);
  if (!matches) {
    throw new FileTransferError(
      409,
      "upload_partial_changed",
      "Upload partial identity changed before cleanup",
    );
  }
  await unlinkForCleanup(path);
}

async function unlinkIfSameInode(
  path: string,
  identity: TransferFileIdentity,
): Promise<void> {
  const current = await cleanupIdentity(path);
  if (!current) return;
  if (!sameInode(identity, current)) {
    throw new FileTransferError(
      409,
      "upload_partial_changed",
      "Upload partial inode changed before cleanup",
    );
  }
  await unlinkForCleanup(path);
}

async function cleanupIdentity(path: string): Promise<TransferFileIdentity | undefined> {
  try {
    const stats = await lstat(path);
    if (!stats.isFile() || stats.isSymbolicLink()) {
      throw new FileTransferError(
        409,
        "upload_partial_changed",
        "Upload partial path is no longer a regular file",
      );
    }
    return identityOf(stats);
  } catch (error) {
    if (fileTransferErrorCode(error) === "ENOENT") return undefined;
    throw error;
  }
}

async function unlinkForCleanup(path: string): Promise<void> {
  try {
    await unlink(path);
  } catch (error) {
    if (fileTransferErrorCode(error) !== "ENOENT") throw error;
  }
}

function sameInode(
  expected: TransferFileIdentity,
  actual: TransferFileIdentity,
): boolean {
  return expected.dev === actual.dev && expected.ino === actual.ino;
}

// Creating a hard link necessarily changes ctime for the inode. Commit
// recovery therefore pins the same inode, device, size, and mtime, while all
// pre-link partial checks continue to require full identity including ctime.
function sameFileObject(
  expected: TransferFileIdentity,
  actual: TransferFileIdentity,
): boolean {
  return expected.dev === actual.dev &&
    expected.ino === actual.ino &&
    expected.size === actual.size &&
    expected.mtimeMs === actual.mtimeMs;
}

function sameDiagnosticMetadata(
  left: DiagnosticReportMetadata | undefined,
  right: DiagnosticReportMetadata | undefined,
): boolean {
  if (!left || !right) return left === right;
  return left.schemaVersion === right.schemaVersion &&
    left.reportId === right.reportId &&
    left.provider === right.provider &&
    left.providerSessionId === right.providerSessionId &&
    left.codexSourceId === right.codexSourceId &&
    left.capturedAtStart === right.capturedAtStart &&
    left.capturedAtEnd === right.capturedAtEnd &&
    left.sha256 === right.sha256;
}

async function fsyncDirectory(path: string): Promise<void> {
  let handle: Awaited<ReturnType<typeof open>> | undefined;
  try {
    handle = await open(path, "r");
    await handle.sync();
  } catch {
    // Some platforms reject directory fsync; the file itself was already synced.
  } finally {
    await handle?.close().catch(() => undefined);
  }
}
