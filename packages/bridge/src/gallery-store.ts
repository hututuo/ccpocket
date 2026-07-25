import { randomUUID } from "node:crypto";
import {
  copyFile,
  lstat,
  mkdir,
  readFile,
  rename,
  stat,
  unlink,
  writeFile,
} from "node:fs/promises";
import { join, extname, basename, isAbsolute, resolve } from "node:path";
import { homedir } from "node:os";
import type { IncomingMessage, ServerResponse } from "node:http";
import { isDirectLoopbackRequest } from "./bridge-http-auth.js";

export interface GalleryImageMeta {
  id: string;
  filename: string;
  mimeType: string;
  projectPath: string;
  sessionId?: string;
  providerSessionId?: string;
  sourcePath: string;
  addedAt: string;
  sizeBytes: number;
}

export interface GalleryImageInfo {
  id: string;
  url: string;
  mimeType: string;
  projectPath: string;
  projectName: string;
  sessionId?: string;
  addedAt: string;
  sizeBytes: number;
}

const DEFAULT_GALLERY_DIR = join(homedir(), ".ccpocket", "gallery");
const MAX_GALLERY_IMAGE_BYTES = 10 * 1024 * 1024;
const MAX_GALLERY_UPLOAD_BODY_BYTES =
  Math.ceil(MAX_GALLERY_IMAGE_BYTES / 3) * 4 + 64 * 1024;
const MAX_GALLERY_STRING_BYTES = 16 * 1024;
const BASE64_PATTERN =
  /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;

const MIME_TYPES: Record<string, string> = {
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
};

function projectNameFromPath(projectPath: string): string {
  const parts = projectPath.split("/").filter(Boolean);
  return parts.length > 0 ? parts[parts.length - 1] : projectPath;
}

function boundedString(
  value: unknown,
  maxBytes = MAX_GALLERY_STRING_BYTES,
): string | undefined {
  if (typeof value !== "string" || !value.trim()) return undefined;
  return Buffer.byteLength(value, "utf8") <= maxBytes ? value : undefined;
}

function decodeGalleryBase64(base64Data: string): Buffer | null {
  if (
    !base64Data ||
    base64Data.length > Math.ceil(MAX_GALLERY_IMAGE_BYTES / 3) * 4 ||
    !BASE64_PATTERN.test(base64Data)
  ) {
    return null;
  }
  const buffer = Buffer.from(base64Data, "base64");
  if (
    buffer.length === 0 ||
    buffer.length > MAX_GALLERY_IMAGE_BYTES ||
    buffer.toString("base64") !== base64Data
  ) {
    return null;
  }
  return buffer;
}

async function readGalleryUploadBody(req: IncomingMessage): Promise<string> {
  const chunks: Buffer[] = [];
  let totalBytes = 0;
  for await (const chunk of req) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    totalBytes += buffer.length;
    if (totalBytes > MAX_GALLERY_UPLOAD_BODY_BYTES) {
      req.resume();
      throw new GalleryUploadError(413, "Request body is too large");
    }
    chunks.push(buffer);
  }
  return Buffer.concat(chunks).toString("utf8");
}

class GalleryUploadError extends Error {
  constructor(
    readonly statusCode: number,
    message: string,
  ) {
    super(message);
    this.name = "GalleryUploadError";
  }
}

function sendGalleryJson(
  res: ServerResponse,
  statusCode: number,
  value: unknown,
): void {
  const body = Buffer.from(JSON.stringify(value));
  res.writeHead(statusCode, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": body.length,
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
  });
  res.end(body);
}

export class GalleryStore {
  private index: GalleryImageMeta[] = [];
  private readonly imagesDirectory: string;
  private readonly indexFile: string;
  private indexWriteTail: Promise<void> = Promise.resolve();

  constructor(options: { directory?: string } = {}) {
    const directory = options.directory ?? DEFAULT_GALLERY_DIR;
    this.imagesDirectory = join(directory, "images");
    this.indexFile = join(directory, "index.json");
  }

  private async resolveReadablePath(filePath: string, projectPath: string): Promise<string | null> {
    const candidates: string[] = [];
    if (isAbsolute(filePath)) {
      candidates.push(filePath);
      candidates.push(resolve(projectPath, filePath.replace(/^\/+/, "")));
    } else {
      candidates.push(resolve(projectPath, filePath));
      candidates.push(filePath);
    }

    for (const candidate of candidates) {
      try {
        const st = await stat(candidate);
        if (st.isFile()) return candidate;
      } catch {
        // Try next candidate.
      }
    }
    return null;
  }

  async init(): Promise<void> {
    await mkdir(this.imagesDirectory, { recursive: true });
    try {
      const data = await readFile(this.indexFile, "utf-8");
      const parsed: unknown = JSON.parse(data);
      this.index = Array.isArray(parsed)
        ? (parsed as GalleryImageMeta[])
        : [];
    } catch {
      // File doesn't exist or is corrupt — start fresh
      this.index = [];
    }
  }

  private async saveIndex(): Promise<void> {
    const write = this.indexWriteTail.then(async () => {
      const temporaryFile = `${this.indexFile}.${randomUUID()}.tmp`;
      try {
        await writeFile(
          temporaryFile,
          JSON.stringify(this.index, null, 2),
          { encoding: "utf-8", mode: 0o600 },
        );
        await rename(temporaryFile, this.indexFile);
      } catch (error) {
        await unlink(temporaryFile).catch(() => undefined);
        throw error;
      }
    });
    this.indexWriteTail = write.catch(() => undefined);
    await write;
  }

  async addImage(
    filePath: string,
    projectPath: string,
    sessionId?: string,
    providerSessionId?: string,
  ): Promise<GalleryImageMeta | null> {
    try {
      const resolvedPath = await this.resolveReadablePath(filePath, projectPath);
      if (!resolvedPath) return null;
      const st = await stat(resolvedPath);
      if (st.size > MAX_GALLERY_IMAGE_BYTES) return null;

      const ext = extname(resolvedPath).toLowerCase();
      const mimeType = MIME_TYPES[ext];
      if (!mimeType) return null;

      const id = randomUUID();
      const filename = `${id}${ext}`;
      const destPath = join(this.imagesDirectory, filename);

      await copyFile(resolvedPath, destPath);

      const meta: GalleryImageMeta = {
        id,
        filename,
        mimeType,
        projectPath,
        sessionId,
        ...(providerSessionId ? { providerSessionId } : {}),
        sourcePath: resolvedPath,
        addedAt: new Date().toISOString(),
        sizeBytes: st.size,
      };

      this.index.push(meta);
      await this.saveIndex();

      console.log(`[gallery] Added image ${id} from ${basename(resolvedPath)}`);
      return meta;
    } catch (err) {
      const detail = err instanceof Error ? err.name : "unknown_error";
      console.warn(`[gallery] Failed to add image: ${detail}`);
      return null;
    }
  }

  /**
   * Add an image from base64-encoded data.
   * This allows mobile clients to upload images directly without file paths.
   */
  async addImageFromBase64(
    base64Data: string,
    mimeType: string,
    projectPath: string,
    sessionId?: string,
    providerSessionId?: string,
  ): Promise<GalleryImageMeta | null> {
    try {
      // Validate mime type and get extension
      const ext = Object.entries(MIME_TYPES).find(([, mime]) => mime === mimeType)?.[0];
      if (!ext) {
        console.warn(`[gallery] Unsupported mime type: ${mimeType}`);
        return null;
      }

      const id = randomUUID();
      const filename = `${id}${ext}`;
      const destPath = join(this.imagesDirectory, filename);

      // Decode a canonical bounded payload before touching persistent storage.
      const buffer = decodeGalleryBase64(base64Data);
      if (!buffer) return null;
      await writeFile(destPath, buffer);

      const meta: GalleryImageMeta = {
        id,
        filename,
        mimeType,
        projectPath,
        sessionId,
        ...(providerSessionId ? { providerSessionId } : {}),
        sourcePath: "base64_upload",
        addedAt: new Date().toISOString(),
        sizeBytes: buffer.length,
      };

      this.index.push(meta);
      await this.saveIndex();

      console.log(`[gallery] Added image ${id} from base64 (${Math.round(buffer.length / 1024)}KB)`);
      return meta;
    } catch (err) {
      console.warn(`[gallery] Failed to add image from base64:`, err);
      return null;
    }
  }

  list(options?: {
    projectPath?: string;
    sessionId?: string;
    providerSessionId?: string;
  }): GalleryImageInfo[] {
    let items = this.index;
    if (options?.projectPath) {
      items = items.filter((m) => m.projectPath === options.projectPath);
    }
    if (options?.sessionId || options?.providerSessionId) {
      items = items.filter(
        (meta) =>
          (options.sessionId !== undefined &&
            meta.sessionId === options.sessionId) ||
          (options.providerSessionId !== undefined &&
            meta.providerSessionId === options.providerSessionId),
      );
    }
    // Return newest first
    return [...items]
      .sort((a, b) => new Date(b.addedAt).getTime() - new Date(a.addedAt).getTime())
      .map((m) => ({
        id: m.id,
        url: `/api/gallery/${m.id}`,
        mimeType: m.mimeType,
        projectPath: m.projectPath,
        projectName: projectNameFromPath(m.projectPath),
        sessionId: m.sessionId,
        addedAt: m.addedAt,
        sizeBytes: m.sizeBytes,
      }));
  }

  /** Bind a legacy source-path entry to its stable provider session. */
  async bindProviderSessionIdBySourcePath(
    filePath: string,
    providerSessionId: string,
  ): Promise<GalleryImageMeta | null> {
    let indexChanged = false;
    for (let index = 0; index < this.index.length; ) {
      const meta = this.index[index];
      if (meta.sourcePath !== filePath) {
        index += 1;
        continue;
      }

      let hasStoredFile = false;
      if (
        typeof meta.filename === "string" &&
        basename(meta.filename) === meta.filename
      ) {
        try {
          hasStoredFile = (
            await lstat(join(this.imagesDirectory, meta.filename))
          ).isFile();
        } catch {
          // A stale index row must not suppress history repair.
        }
      }
      if (!hasStoredFile) {
        this.index.splice(index, 1);
        indexChanged = true;
        continue;
      }

      if (meta.providerSessionId !== providerSessionId) {
        meta.providerSessionId = providerSessionId;
        indexChanged = true;
      }
      if (indexChanged) await this.saveIndex();
      return meta;
    }
    if (indexChanged) await this.saveIndex();
    return null;
  }

  getImagePath(id: string): string | null {
    const meta = this.index.find((m) => m.id === id);
    if (!meta) return null;
    return join(this.imagesDirectory, meta.filename);
  }

  /**
   * Get image as Base64 for SDK message embedding.
   * Returns null if image not found.
   */
  async getImageAsBase64(id: string): Promise<{ base64: string; mimeType: string } | null> {
    const meta = this.index.find((m) => m.id === id);
    if (!meta) return null;

    const filePath = join(this.imagesDirectory, meta.filename);
    try {
      const buffer = await readFile(filePath);
      return {
        base64: buffer.toString("base64"),
        mimeType: meta.mimeType,
      };
    } catch {
      return null;
    }
  }

  /**
   * Get mime type for an image by ID.
   */
  getMimeType(id: string): string | null {
    const meta = this.index.find((m) => m.id === id);
    return meta?.mimeType ?? null;
  }

  async delete(id: string): Promise<boolean> {
    const idx = this.index.findIndex((m) => m.id === id);
    if (idx === -1) return false;

    const meta = this.index[idx];
    const filePath = join(this.imagesDirectory, meta.filename);

    try {
      await unlink(filePath);
    } catch {
      // File may already be deleted
    }

    this.index.splice(idx, 1);
    await this.saveIndex();
    console.log(`[gallery] Deleted image ${id}`);
    return true;
  }

  /**
   * Handle HTTP requests for gallery image serving.
   * Returns true if the request was handled.
   */
  handleRequest(req: IncomingMessage, res: ServerResponse): boolean {
    const url = req.url ?? "";

    // Match /api/gallery/:id (alphanumeric, hyphens, underscores)
    const imageMatch = url.match(/^\/api\/gallery\/([a-zA-Z0-9_-]+)$/);

    // GET /api/gallery/:id — serve image file
    if (imageMatch && req.method === "GET") {
      const id = imageMatch[1];
      return this.serveImage(id, res);
    }

    // DELETE /api/gallery/:id
    if (imageMatch && req.method === "DELETE") {
      const id = imageMatch[1];
      this.delete(id).then((ok) => {
        if (ok) {
          res.writeHead(200, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ deleted: true }));
        } else {
          res.writeHead(404, { "Content-Type": "text/plain" });
          res.end("Not Found");
        }
      }).catch(() => {
        res.writeHead(500, { "Content-Type": "text/plain" });
        res.end("Internal Server Error");
      });
      return true;
    }

    // GET /api/gallery — list images (exact path or with query string)
    if ((url === "/api/gallery" || url.startsWith("/api/gallery?")) && req.method === "GET") {
      const parsedUrl = new URL(url, `http://${req.headers.host ?? "localhost"}`);
      const project = parsedUrl.searchParams.get("project") ?? undefined;
      const images = this.list({ projectPath: project });
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ images }));
      return true;
    }

    return false;
  }

  private serveImage(id: string, res: ServerResponse): boolean {
    const meta = this.index.find((m) => m.id === id);
    if (!meta) {
      res.writeHead(404, { "Content-Type": "text/plain" });
      res.end("Not Found");
      return true;
    }

    const filePath = join(this.imagesDirectory, meta.filename);
    readFile(filePath)
      .then((buffer) => {
        res.writeHead(200, {
          "Content-Type": meta.mimeType,
          "Content-Length": buffer.length,
          "Cache-Control": "private, max-age=3600",
          "X-Content-Type-Options": "nosniff",
          "Referrer-Policy": "no-referrer",
          "Cross-Origin-Resource-Policy": "cross-origin",
        });
        res.end(buffer);
      })
      .catch(() => {
        res.writeHead(404, { "Content-Type": "text/plain" });
        res.end("Not Found");
      });

    return true;
  }

  /**
   * Handle POST /api/gallery/upload.
   * Accepts a bounded JSON base64 upload from authenticated Mobile clients.
   * Legacy local file-path copies remain loopback-only and require the explicit
   * local-control header used by Bridge command surfaces.
   * Returns true if the request was handled.
   */
  handleUploadRequest(
    req: IncomingMessage,
    res: ServerResponse,
    onNewImage?: (meta: GalleryImageMeta) => void,
  ): boolean {
    const url = req.url ?? "";
    if (url !== "/api/gallery/upload" || req.method !== "POST") return false;

    void this.handleUpload(req, res, onNewImage);
    return true;
  }

  private async handleUpload(
    req: IncomingMessage,
    res: ServerResponse,
    onNewImage?: (meta: GalleryImageMeta) => void,
  ): Promise<void> {
    const contentType = req.headers["content-type"] ?? "";
    if (
      contentType.split(";", 1)[0].trim().toLowerCase() !==
      "application/json"
    ) {
      req.resume();
      sendGalleryJson(res, 415, {
        error: "Content-Type must be application/json",
      });
      return;
    }
    const declaredLength = Number(req.headers["content-length"] ?? 0);
    if (
      Number.isFinite(declaredLength) &&
      declaredLength > MAX_GALLERY_UPLOAD_BODY_BYTES
    ) {
      req.resume();
      sendGalleryJson(res, 413, { error: "Request body is too large" });
      return;
    }

    try {
      const value: unknown = JSON.parse(await readGalleryUploadBody(req));
      if (typeof value !== "object" || value === null || Array.isArray(value)) {
        throw new GalleryUploadError(400, "Request body must be a JSON object");
      }
      const parsed = value as Record<string, unknown>;
      const projectPath = boundedString(parsed.projectPath);
      const sessionId =
        parsed.sessionId === undefined
          ? undefined
          : boundedString(parsed.sessionId);
      if (!projectPath) {
        throw new GalleryUploadError(400, "projectPath is required");
      }
      if (parsed.sessionId !== undefined && !sessionId) {
        throw new GalleryUploadError(400, "sessionId is invalid");
      }

      let meta: GalleryImageMeta | null = null;
      if (
        typeof parsed.base64 === "string" &&
        typeof parsed.mimeType === "string"
      ) {
        meta = await this.addImageFromBase64(
          parsed.base64,
          parsed.mimeType,
          projectPath,
          sessionId,
        );
      } else if (typeof parsed.filePath === "string") {
        const localControlRequest =
          isDirectLoopbackRequest(req) &&
          !req.headers.origin &&
          req.headers["x-ccpocket-control"] === "1";
        if (!localControlRequest) {
          throw new GalleryUploadError(
            403,
            "File-path gallery uploads require local Bridge control",
          );
        }
        const filePath = boundedString(parsed.filePath);
        if (!filePath) {
          throw new GalleryUploadError(400, "filePath is invalid");
        }
        meta = await this.addImage(filePath, projectPath, sessionId);
      } else {
        throw new GalleryUploadError(
          400,
          "Either filePath or (base64 + mimeType) is required",
        );
      }

      if (!meta) {
        throw new GalleryUploadError(
          400,
          "Failed to add image (unsupported format or invalid data)",
        );
      }
      onNewImage?.(meta);
      sendGalleryJson(res, 201, { image: this.metaToInfo(meta) });
    } catch (error) {
      const statusCode =
        error instanceof GalleryUploadError ? error.statusCode : 400;
      const message =
        error instanceof GalleryUploadError
          ? error.message
          : "Invalid JSON body";
      sendGalleryJson(res, statusCode, { error: message });
    }
  }

  /** Convert GalleryImageMeta to GalleryImageInfo for WS broadcast. */
  metaToInfo(meta: GalleryImageMeta): GalleryImageInfo {
    return {
      id: meta.id,
      url: `/api/gallery/${meta.id}`,
      mimeType: meta.mimeType,
      projectPath: meta.projectPath,
      projectName: projectNameFromPath(meta.projectPath),
      sessionId: meta.sessionId,
      addedAt: meta.addedAt,
      sizeBytes: meta.sizeBytes,
    };
  }
}
