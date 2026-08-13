import type { IncomingMessage, ServerResponse } from "node:http";
import { FILE_TRANSFER_MAX_UPLOAD_CHUNK_BYTES } from "./file-transfer-constants.js";
import { FileTransferError } from "./file-transfer-errors.js";
import type { FileTransferManager } from "./file-transfer-manager.js";
import type { PersistedUploadTransfer } from "./file-transfer-state-store.js";
import { UploadOffsetConflictError } from "./file-transfer-upload-store.js";
import { isDirectLoopbackRequest } from "./bridge-http-auth.js";
import {
  fileTransferContentDisposition,
  sendFileTransferJson,
  sendFileTransferText,
  validateFileTransferBaseUrl,
} from "./file-transfer-utils.js";

const CONTROL_PATH = "/api/file-transfers/send";
const DOWNLOAD_PATH = /^\/api\/file-transfers\/downloads\/([A-Za-z0-9_-]{16,128})$/;
const UPLOAD_PATH = /^\/api\/file-transfers\/uploads\/([A-Za-z0-9_-]{16,128})$/;
const MAX_CONTROL_BODY_BYTES = 16 * 1024;
const MAX_ACTIVE_DOWNLOADS = 4;
const TRANSFER_IDLE_TIMEOUT_MS = 60_000;
const TRANSFER_TOTAL_TIMEOUT_MS = 15 * 60_000;

export interface FileTransferHttpHandlerOptions {
  maxActiveDownloads?: number;
  idleTimeoutMs?: number;
  totalTimeoutMs?: number;
  /** Defaults to true for authenticated/legacy runtimes. */
  allowDiagnosticUploadContinuation?: boolean;
}

export class FileTransferHttpHandler {
  private activeDownloads = 0;
  private readonly activeDownloadIds = new Set<string>();
  private accepting = true;
  private readonly activeRequests = new Map<Promise<void>, () => void>();
  private readonly maxActiveDownloads: number;
  private readonly idleTimeoutMs: number;
  private readonly totalTimeoutMs: number;
  private readonly allowDiagnosticUploadContinuation: boolean;

  constructor(
    private readonly manager: FileTransferManager,
    options: FileTransferHttpHandlerOptions = {},
  ) {
    this.maxActiveDownloads = options.maxActiveDownloads ?? MAX_ACTIVE_DOWNLOADS;
    this.idleTimeoutMs = options.idleTimeoutMs ?? TRANSFER_IDLE_TIMEOUT_MS;
    this.totalTimeoutMs = options.totalTimeoutMs ?? TRANSFER_TOTAL_TIMEOUT_MS;
    this.allowDiagnosticUploadContinuation =
      options.allowDiagnosticUploadContinuation !== false;
  }

  handleRequest(req: IncomingMessage, res: ServerResponse): boolean {
    const rawUrl = req.url ?? "";
    if (rawUrl === CONTROL_PATH) {
      if (!this.accepting) return transferShuttingDown(req, res);
      if (req.method !== "POST") return methodNotAllowed(res, "POST");
      this.startRequest(req, res, () => this.handleSendControl(req, res));
      return true;
    }
    const download = rawUrl.match(DOWNLOAD_PATH);
    if (download) {
      if (!this.accepting) return transferShuttingDown(req, res);
      if (req.method !== "HEAD" && req.method !== "GET") {
        return methodNotAllowed(res, "HEAD, GET");
      }
      this.startRequest(req, res, () => this.handleDownload(req, res, download[1]));
      return true;
    }
    const upload = rawUrl.match(UPLOAD_PATH);
    if (upload) {
      if (!this.accepting) return transferShuttingDown(req, res);
      if (req.method !== "HEAD" && req.method !== "PATCH") {
        return methodNotAllowed(res, "HEAD, PATCH");
      }
      this.startRequest(req, res, () => this.handleUpload(req, res, upload[1]));
      return true;
    }
    return false;
  }

  /** Stop new transfer routes, abort every active body/stream, then drain. */
  async close(): Promise<void> {
    this.accepting = false;
    while (this.activeRequests.size > 0) {
      const snapshot = [...this.activeRequests.entries()];
      for (const [, abort] of snapshot) abort();
      await Promise.allSettled(snapshot.map(([operation]) => operation));
    }
  }

  private startRequest(
    req: IncomingMessage,
    res: ServerResponse,
    operation: () => Promise<void>,
  ): void {
    let tracked!: Promise<void>;
    const abort = (): void => {
      const error = new Error("Bridge file transfer is shutting down");
      req.destroy(error);
      if (!res.destroyed) res.destroy(error);
    };
    tracked = operation()
      .catch((error) => {
        if (!res.headersSent && !res.destroyed) sendTransferError(res, error);
        else if (!res.destroyed) res.destroy(error instanceof Error ? error : undefined);
      })
      .finally(() => {
        this.activeRequests.delete(tracked);
      });
    this.activeRequests.set(tracked, abort);
  }

  private async handleSendControl(req: IncomingMessage, res: ServerResponse): Promise<void> {
    if (!isDirectLoopbackRequest(req)) {
      req.resume();
      return sendTransferJson(res, 403, "loopback_required", "Forbidden");
    }
    if (req.headers.origin) {
      req.resume();
      return sendTransferJson(res, 403, "origin_not_allowed", "Forbidden");
    }
    if (req.headers["x-ccpocket-control"] !== "1") {
      req.resume();
      return sendTransferJson(res, 403, "control_header_required", "Forbidden");
    }
    if (mediaType(req) !== "application/json") {
      req.resume();
      return sendTransferJson(res, 415, "unsupported_content_type", "Content-Type must be application/json");
    }
    const earlyLength = optionalUnsignedHeader(req, "content-length");
    if (earlyLength !== undefined && (!Number.isSafeInteger(earlyLength) || earlyLength > MAX_CONTROL_BODY_BYTES)) {
      req.resume();
      return sendTransferJson(res, 413, "body_too_large", "Request body is too large");
    }
    const controller = new AbortController();
    const abort = (): void => controller.abort();
    req.once("aborted", abort);
    res.once("close", abort);
    if (req.aborted || res.destroyed) abort();
    try {
      const body = parseControlObject(await readBoundedBody(req));
      if (typeof body.filePath !== "string" || !body.filePath.trim()) {
        throw new FileTransferError(400, "invalid_path", "filePath is required");
      }
      if (typeof body.projectPath !== "string" || !body.projectPath.trim()) {
        throw new FileTransferError(400, "invalid_project_path", "projectPath is required");
      }
      if (body.ttlSeconds !== undefined && (!Number.isSafeInteger(body.ttlSeconds) || Number(body.ttlSeconds) < 1)) {
        throw new FileTransferError(400, "invalid_ttl", "ttlSeconds must be a positive integer");
      }
      if (body.baseUrl !== undefined && (typeof body.baseUrl !== "string" || !validateFileTransferBaseUrl(body.baseUrl))) {
        throw new FileTransferError(400, "invalid_base_url", "baseUrl must be a mobile-reachable HTTP(S) origin");
      }
      const offered = await this.manager.offerFile({
        filePath: body.filePath,
        projectPath: body.projectPath,
        ttlSeconds: body.ttlSeconds as number | undefined,
        baseUrl: body.baseUrl as string | undefined,
        signal: controller.signal,
      });
      if (!res.destroyed && !res.writableEnded) {
        sendFileTransferJson(res, 202, offered);
      }
    } catch (error) {
      if (!res.destroyed && !res.writableEnded) sendTransferError(res, error);
    } finally {
      req.off("aborted", abort);
      res.off("close", abort);
    }
  }

  private async handleDownload(
    req: IncomingMessage,
    res: ServerResponse,
    transferId: string,
  ): Promise<void> {
    if (req.headers.origin) return sendTransferJson(res, 403, "origin_not_allowed", "Forbidden");
    const token = singleHeader(req, "x-ccpocket-transfer-token");
    if (!token) return sendTransferJson(res, 403, "transfer_token_required", "Transfer token is required");
    if (req.method === "HEAD") {
      let opened: Awaited<ReturnType<FileTransferManager["openDownload"]>> | undefined;
      try {
        opened = await this.manager.openDownload(transferId, token);
        await opened.handle.close();
        const entry = opened.entry;
        opened = undefined;
        res.writeHead(200, downloadHeaders(entry));
        res.end();
      } catch (error) {
        await opened?.handle.close().catch(() => undefined);
        sendTransferError(res, error);
      }
      return;
    }
    if (this.activeDownloads >= this.maxActiveDownloads || this.activeDownloadIds.has(transferId)) {
      return sendTransferJson(res, 429, "download_concurrency_limit", "Too many downloads are active");
    }
    // Reserve synchronously before the first await so parallel requests cannot
    // all pass the check against the same slot count.
    this.activeDownloads += 1;
    this.activeDownloadIds.add(transferId);
    let opened: Awaited<ReturnType<FileTransferManager["openDownload"]>> | undefined;
    let downloadSize: number | undefined;
    try {
      opened = await this.manager.openDownload(transferId, token);
      downloadSize = opened.entry.sizeBytes;
      if (opened.entry.sizeBytes === 0) {
        if (req.headers.range) throw new FileTransferError(416, "range_not_satisfiable", "Empty file has no byte range");
        res.writeHead(200, downloadHeaders(opened.entry));
        await opened.handle.close();
        opened = undefined;
        this.releaseDownloadSlot(transferId);
        res.end();
        return;
      }
      const range = parseRequiredDownloadRange(singleHeader(req, "range"), opened.entry.sizeBytes);
      if (singleHeader(req, "if-range") !== opened.entry.etag) {
        throw new FileTransferError(412, "etag_mismatch", "If-Range does not match the transfer ETag");
      }
      const length = range.end - range.start + 1;
      if (length > FILE_TRANSFER_MAX_UPLOAD_CHUNK_BYTES) {
        throw new FileTransferError(413, "download_chunk_too_large", "Download range exceeds 16 MiB");
      }
      const headers = downloadHeaders(opened.entry);
      headers["Content-Length"] = length;
      headers["Content-Range"] = `bytes ${range.start}-${range.end}/${opened.entry.sizeBytes}`;
      res.writeHead(206, headers);
      const finalByte = await streamFileTransferDownloadRange(
        opened,
        range.start,
        range.end,
        req,
        res,
        this.idleTimeoutMs,
        this.totalTimeoutMs,
      );
      await this.manager.downloadStore.verifyAfterRead(opened);
      await opened.handle.close();
      opened = undefined;
      // Hold the final byte until post-read identity verification succeeds.
      // Releasing the slot before publishing that byte also prevents a client
      // that completes by Content-Length from observing a transient 429 on its
      // immediately-following adaptive range request.
      this.releaseDownloadSlot(transferId);
      res.end(finalByte);
    } catch (error) {
      await opened?.handle.close().catch(() => undefined);
      if (!res.headersSent) {
        if (error instanceof FileTransferError && error.code === "range_not_satisfiable") {
          if (downloadSize !== undefined) {
            res.setHeader("Content-Range", `bytes */${downloadSize}`);
          }
        }
        sendTransferError(res, error);
      } else {
        res.destroy(error instanceof Error ? error : undefined);
      }
    } finally {
      this.releaseDownloadSlot(transferId);
    }
  }

  private releaseDownloadSlot(transferId: string): void {
    if (this.activeDownloadIds.delete(transferId)) this.activeDownloads -= 1;
  }

  private async handleUpload(
    req: IncomingMessage,
    res: ServerResponse,
    transferId: string,
  ): Promise<void> {
    if (req.headers.origin) {
      req.resume();
      return sendTransferJson(res, 403, "origin_not_allowed", "Forbidden");
    }
    const token = singleHeader(req, "x-ccpocket-transfer-token");
    if (!token) {
      req.resume();
      return sendTransferJson(res, 403, "transfer_token_required", "Transfer token is required");
    }
    let authorizedEntry: PersistedUploadTransfer;
    try {
      authorizedEntry = await this.manager.statusUpload(transferId, token);
      if (
        authorizedEntry.purpose === "diagnostic_report" &&
        !this.allowDiagnosticUploadContinuation
      ) {
        throw new FileTransferError(
          403,
          "diagnostic_upload_disabled",
          "Development diagnostic uploads are disabled for this Bridge runtime",
        );
      }
    } catch (error) {
      req.resume();
      sendTransferError(res, error);
      return;
    }
    if (req.method === "HEAD") {
      try {
        const entry = authorizedEntry;
        res.writeHead(200, uploadStatusHeaders(entry, this.manager.uploadStore.maxChunkSizeBytes));
        res.end();
      } catch (error) {
        sendTransferError(res, error);
      }
      return;
    }
    if (mediaType(req) !== "application/offset+octet-stream") {
      req.resume();
      return sendTransferJson(res, 415, "unsupported_content_type", "Content-Type must be application/offset+octet-stream");
    }
    const contentLength = requiredUnsignedHeader(req, "content-length");
    const uploadOffset = requiredUnsignedHeader(req, "upload-offset");
    if (contentLength === undefined) {
      req.resume();
      return sendTransferJson(res, 411, "content_length_required", "A valid Content-Length is required");
    }
    if (uploadOffset === undefined) {
      req.resume();
      return sendTransferJson(res, 400, "upload_offset_required", "A valid Upload-Offset is required");
    }
    if (contentLength < 1 || contentLength > this.manager.uploadStore.maxChunkSizeBytes) {
      req.resume();
      return sendTransferJson(res, 413, "upload_chunk_too_large", "Upload chunk is outside the advertised limit");
    }
    const controller = new AbortController();
    const abort = (): void => controller.abort();
    req.once("aborted", abort);
    try {
      const result = await this.manager.appendUpload(
        transferId,
        token,
        uploadOffset,
        contentLength,
        timedUploadBody(
          req,
          controller,
          this.idleTimeoutMs,
          this.totalTimeoutMs,
        ),
        controller.signal,
      );
      res.writeHead(204, uploadStatusHeaders(result.entry, this.manager.uploadStore.maxChunkSizeBytes));
      res.end();
    } catch (error) {
      req.resume();
      if (!res.headersSent) {
        if (error instanceof UploadOffsetConflictError) {
          res.setHeader("Upload-Offset", error.uploadOffset);
        }
        sendTransferError(res, error);
      } else {
        res.destroy(error instanceof Error ? error : undefined);
      }
    } finally {
      req.off("aborted", abort);
    }
  }
}

function downloadHeaders(entry: Awaited<ReturnType<FileTransferManager["authorizeDownload"]>>): Record<string, string | number> {
  return {
    "Content-Type": entry.mimeType,
    "Content-Disposition": fileTransferContentDisposition(entry.filename),
    "Content-Length": entry.sizeBytes,
    "Accept-Ranges": "bytes",
    ETag: entry.etag,
    "X-CCPocket-Max-Chunk-Bytes": FILE_TRANSFER_MAX_UPLOAD_CHUNK_BYTES,
    "X-CCPocket-Transfer-Expires": new Date(entry.expiresAt).toISOString(),
    "Cache-Control": "private, no-store, max-age=0",
    "X-Content-Type-Options": "nosniff",
  };
}

function uploadStatusHeaders(
  entry: PersistedUploadLike,
  maxChunkSizeBytes: number,
): Record<string, string | number> {
  return {
    "Upload-Offset": entry.offset,
    "Upload-Length": entry.sizeBytes,
    "Upload-Expires": new Date(entry.expiresAt).toISOString(),
    "Upload-Complete": entry.status === "complete" ? "1" : "0",
    "X-CCPocket-Max-Chunk-Bytes": maxChunkSizeBytes,
    ...(entry.status === "complete" && entry.finalFilename
      ? { "Upload-Filename": encodeURIComponent(entry.finalFilename) }
      : {}),
    "Cache-Control": "no-store",
  };
}

interface PersistedUploadLike {
  offset: number;
  sizeBytes: number;
  expiresAt: number;
  status: string;
  finalFilename?: string;
}

export async function streamFileTransferDownloadRange(
  opened: Awaited<ReturnType<FileTransferManager["openDownload"]>>,
  start: number,
  end: number,
  req: IncomingMessage,
  res: ServerResponse,
  idleTimeoutMs: number,
  totalTimeoutMs: number,
): Promise<Buffer> {
  let idleTimer: NodeJS.Timeout | undefined;
  const controller = new AbortController();
  const abortWith = (error: Error): void => {
    if (!controller.signal.aborted) controller.abort(error);
  };
  const totalTimer = setTimeout(
    () => abortWith(new Error("Download timed out")),
    totalTimeoutMs,
  );
  totalTimer.unref();
  const resetIdle = (): void => {
    if (idleTimer) clearTimeout(idleTimer);
    idleTimer = setTimeout(
      () => abortWith(new Error("Download stalled")),
      idleTimeoutMs,
    );
    idleTimer.unref();
  };
  const abort = (): void => {
    abortWith(new Error("Download connection closed"));
  };
  req.once("aborted", abort);
  res.once("close", abort);
  resetIdle();
  try {
    let position = start;
    const buffer = Buffer.allocUnsafe(Math.min(256 * 1024, end - start + 1));
    while (position <= end) {
      const requested = Math.min(buffer.length, end - position + 1);
      const { bytesRead } = await abortable(
        opened.handle.read(buffer, 0, requested, position),
        controller.signal,
      );
      if (bytesRead <= 0) throw new Error("Source file ended before the requested range");
      position += bytesRead;
      resetIdle();
      const isFinalRead = position > end;
      const bodyBytes = isFinalRead ? bytesRead - 1 : bytesRead;
      if (bodyBytes > 0) {
        await abortable(
          writeResponseChunk(res, buffer.subarray(0, bodyBytes)),
          controller.signal,
        );
        resetIdle();
      }
      if (isFinalRead) return Buffer.from(buffer.subarray(bytesRead - 1, bytesRead));
    }
    throw new Error("Source file ended before the requested range");
  } finally {
    req.off("aborted", abort);
    res.off("close", abort);
    clearTimeout(totalTimer);
    if (idleTimer) clearTimeout(idleTimer);
  }
}

async function abortable<T>(operation: Promise<T>, signal: AbortSignal): Promise<T> {
  if (signal.aborted) throw abortReason(signal);
  return new Promise<T>((resolve, reject) => {
    const cleanup = (): void => signal.removeEventListener("abort", onAbort);
    const onAbort = (): void => {
      cleanup();
      reject(abortReason(signal));
    };
    signal.addEventListener("abort", onAbort, { once: true });
    operation.then(
      (value) => {
        cleanup();
        resolve(value);
      },
      (error) => {
        cleanup();
        reject(error);
      },
    );
  });
}

function abortReason(signal: AbortSignal): Error {
  return signal.reason instanceof Error
    ? signal.reason
    : new Error("Transfer aborted");
}

async function writeResponseChunk(
  res: ServerResponse,
  chunk: Uint8Array,
): Promise<void> {
  if (res.destroyed || res.closed) throw new Error("Download connection closed");
  await new Promise<void>((resolve, reject) => {
    const cleanup = (): void => {
      res.off("close", onClose);
      res.off("error", onError);
    };
    const settle = (operation: () => void): void => {
      cleanup();
      operation();
    };
    const onClose = (): void => settle(() => reject(new Error("Download connection closed")));
    const onError = (error: Error): void => settle(() => reject(error));
    res.once("close", onClose);
    res.once("error", onError);
    res.write(chunk, (error) => {
      if (error) {
        settle(() => reject(error));
      } else {
        settle(resolve);
      }
    });
  });
}

async function* timedUploadBody(
  req: IncomingMessage,
  controller: AbortController,
  idleTimeoutMs: number,
  totalTimeoutMs: number,
): AsyncGenerator<Buffer> {
  let idleTimer: NodeJS.Timeout | undefined;
  const abortForTimeout = (message: string): void => {
    const error = new FileTransferError(408, "upload_timeout", message);
    controller.abort(error);
    // Aborting only the signal does not wake a generator blocked in
    // IncomingMessage.next(). Destroying the request guarantees the pending
    // read rejects and the upload store can roll back and release its lock.
    req.destroy(error);
  };
  const totalTimer = setTimeout(
    () => abortForTimeout("Upload exceeded the total transfer timeout"),
    totalTimeoutMs,
  );
  totalTimer.unref();
  const resetIdle = (): void => {
    if (idleTimer) clearTimeout(idleTimer);
    idleTimer = setTimeout(
      () => abortForTimeout("Upload stalled before the declared chunk completed"),
      idleTimeoutMs,
    );
    idleTimer.unref();
  };
  resetIdle();
  try {
    for await (const chunk of req) {
      resetIdle();
      yield Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    }
  } finally {
    clearTimeout(totalTimer);
    if (idleTimer) clearTimeout(idleTimer);
  }
}

function parseRequiredDownloadRange(header: string | undefined, size: number): { start: number; end: number } {
  if (!header) throw new FileTransferError(428, "range_required", "A single explicit Range is required");
  if (header.includes(",")) throw new FileTransferError(416, "range_not_satisfiable", "Multiple ranges are not supported");
  const match = /^bytes=(\d+)-(\d+)$/.exec(header.trim());
  if (!match) throw new FileTransferError(416, "range_not_satisfiable", "Range must be bytes=N-M");
  const start = Number(match[1]);
  const end = Number(match[2]);
  if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < 0 || end < start || end >= size) {
    throw new FileTransferError(416, "range_not_satisfiable", "Range is outside the file");
  }
  return { start, end };
}

async function readBoundedBody(req: IncomingMessage): Promise<string> {
  const chunks: Buffer[] = [];
  let total = 0;
  for await (const chunk of req) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    total += buffer.length;
    if (total > MAX_CONTROL_BODY_BYTES) throw new FileTransferError(413, "body_too_large", "Request body is too large");
    chunks.push(buffer);
  }
  return Buffer.concat(chunks).toString("utf8");
}

function parseControlObject(body: string): Record<string, unknown> {
  let parsed: unknown;
  try { parsed = JSON.parse(body); } catch { throw new FileTransferError(400, "invalid_json", "Invalid JSON body"); }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new FileTransferError(400, "invalid_json_object", "Request body must be a JSON object");
  }
  const value = parsed as Record<string, unknown>;
  const allowed = new Set(["filePath", "projectPath", "ttlSeconds", "baseUrl"]);
  if (Object.keys(value).some((key) => !allowed.has(key))) {
    throw new FileTransferError(400, "unknown_control_field", "Request body contains an unknown field");
  }
  return value;
}

function mediaType(req: IncomingMessage): string {
  return (singleHeader(req, "content-type") ?? "").split(";", 1)[0].trim().toLowerCase();
}

function singleHeader(req: IncomingMessage, name: string): string | undefined {
  const value = req.headers[name];
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function optionalUnsignedHeader(req: IncomingMessage, name: string): number | undefined {
  const raw = singleHeader(req, name);
  if (raw === undefined) return undefined;
  if (!/^\d+$/.test(raw)) return Number.NaN;
  const value = Number(raw);
  return Number.isSafeInteger(value) && value >= 0 ? value : Number.NaN;
}

function requiredUnsignedHeader(req: IncomingMessage, name: string): number | undefined {
  const value = optionalUnsignedHeader(req, name);
  return value !== undefined && Number.isSafeInteger(value) ? value : undefined;
}

function methodNotAllowed(res: ServerResponse, allow: string): true {
  sendFileTransferText(res, 405, "Method Not Allowed", { Allow: allow });
  return true;
}

function transferShuttingDown(req: IncomingMessage, res: ServerResponse): true {
  req.resume();
  sendTransferJson(
    res,
    503,
    "file_transfer_shutting_down",
    "File transfer is shutting down",
  );
  return true;
}

function sendTransferJson(res: ServerResponse, status: number, errorCode: string, error: string): void {
  sendFileTransferJson(res, status, { success: false, errorCode, error });
}

function sendTransferError(res: ServerResponse, error: unknown): void {
  if (error instanceof FileTransferError) {
    sendTransferJson(res, error.statusCode, error.code, error.message);
    return;
  }
  sendTransferJson(res, 500, "file_transfer_internal_error", "Internal Server Error");
}
