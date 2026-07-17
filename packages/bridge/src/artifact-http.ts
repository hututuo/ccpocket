import type { FileHandle } from "node:fs/promises";
import type { IncomingMessage, ServerResponse } from "node:http";
import {
  ARTIFACT_ASSET_PATTERN,
  serveArtifactAsset,
} from "./artifact-assets.js";
import {
  sendArtifactError,
  sendArtifactJson,
  sendArtifactText,
  serveArtifactFile,
} from "./artifact-content.js";
import {
  previewKindForFile,
  renderArtifactPreviewHtml,
} from "./artifact-preview.js";
import {
  ArtifactHttpError,
  type ArtifactStore,
} from "./artifact-store.js";
import { validateArtifactBaseUrl } from "./artifact-url.js";

const TOKEN_PATTERN = "[A-Za-z0-9_-]{43}";
const MAX_CONTROL_BODY_BYTES = 16 * 1024;
const MAX_TEXT_PREVIEW_BYTES = 512 * 1024;
const MAX_DOCX_BROWSER_PREVIEW_BYTES = 25 * 1024 * 1024;

export function isLoopbackAddress(address?: string): boolean {
  if (!address) return false;
  const normalized = address.toLowerCase();
  if (normalized === "::1") return true;
  const ipv4 = normalized.startsWith("::ffff:")
    ? normalized.slice("::ffff:".length)
    : normalized;
  return ipv4.startsWith("127.");
}

async function readControlBody(req: IncomingMessage): Promise<string> {
  const chunks: Buffer[] = [];
  let totalBytes = 0;
  for await (const chunk of req) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    totalBytes += buffer.length;
    if (totalBytes > MAX_CONTROL_BODY_BYTES) {
      req.resume();
      throw new ArtifactHttpError(
        413,
        "body_too_large",
        "Request body is too large",
      );
    }
    chunks.push(buffer);
  }
  return Buffer.concat(chunks).toString("utf8");
}

function parseControlObject(body: string): Record<string, unknown> {
  let value: unknown;
  try {
    value = JSON.parse(body);
  } catch {
    throw new ArtifactHttpError(400, "invalid_json", "Invalid JSON body");
  }
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new ArtifactHttpError(
      400,
      "invalid_json_object",
      "Request body must be a JSON object",
    );
  }
  return value as Record<string, unknown>;
}

export class ArtifactHttpHandler {
  constructor(private readonly store: ArtifactStore) {}

  handleRequest(req: IncomingMessage, res: ServerResponse): boolean {
    const rawUrl = req.url ?? "";
    const queryStart = rawUrl.indexOf("?");
    const url = queryStart === -1 ? rawUrl : rawUrl.slice(0, queryStart);
    const query = queryStart === -1 ? "" : rawUrl.slice(queryStart + 1);

    if (url === "/api/artifacts") {
      if (req.method !== "POST") {
        sendArtifactText(res, 405, "Method Not Allowed", { Allow: "POST" });
        return true;
      }
      void this.handlePublishRequest(req, res);
      return true;
    }

    const assetMatch = url.match(ARTIFACT_ASSET_PATTERN);
    if (assetMatch) {
      if (req.method !== "GET" && req.method !== "HEAD") {
        sendArtifactText(res, 405, "Method Not Allowed", {
          Allow: "GET, HEAD",
        });
        return true;
      }
      void serveArtifactAsset(assetMatch[1], req.method === "HEAD", res);
      return true;
    }

    const artifactMatch = url.match(
      new RegExp(`^/artifacts/(${TOKEN_PATTERN})(?:/(content|download))?$`),
    );
    if (!artifactMatch) return false;

    const token = artifactMatch[1];
    const action = artifactMatch[2] ?? "preview";
    if (req.method !== "GET" && req.method !== "HEAD") {
      sendArtifactText(res, 405, "Method Not Allowed", {
        Allow: "GET, HEAD",
      });
      return true;
    }

    if (action === "preview") {
      const embedded = new URLSearchParams(query).get("embedded") === "1";
      void this.servePreview(token, req.method === "HEAD", embedded, res);
    } else {
      void serveArtifactFile(
        this.store,
        token,
        action === "download" ? "attachment" : "inline",
        req,
        res,
      );
    }
    return true;
  }

  private async handlePublishRequest(
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    if (!isLoopbackAddress(req.socket.remoteAddress)) {
      req.resume();
      sendArtifactJson(res, 403, {
        error: "Forbidden",
        errorCode: "loopback_required",
      });
      return;
    }
    if (req.headers.origin) {
      req.resume();
      sendArtifactJson(res, 403, {
        error: "Forbidden",
        errorCode: "origin_not_allowed",
      });
      return;
    }
    if (req.headers["x-ccpocket-control"] !== "1") {
      req.resume();
      sendArtifactJson(res, 403, {
        error: "Forbidden",
        errorCode: "control_header_required",
      });
      return;
    }

    const contentType = req.headers["content-type"] ?? "";
    const mediaType = contentType.split(";", 1)[0].trim().toLowerCase();
    if (mediaType !== "application/json") {
      req.resume();
      sendArtifactJson(res, 415, {
        error: "Content-Type must be application/json",
        errorCode: "unsupported_content_type",
      });
      return;
    }

    const declaredLength = Number(req.headers["content-length"] ?? 0);
    if (
      Number.isFinite(declaredLength) &&
      declaredLength > MAX_CONTROL_BODY_BYTES
    ) {
      req.resume();
      sendArtifactJson(res, 413, {
        error: "Request body is too large",
        errorCode: "body_too_large",
      });
      return;
    }

    try {
      const parsed = parseControlObject(await readControlBody(req));
      if (typeof parsed.filePath !== "string") {
        throw new ArtifactHttpError(
          400,
          "invalid_path",
          "filePath is required",
        );
      }
      if (
        parsed.projectPath !== undefined &&
        typeof parsed.projectPath !== "string"
      ) {
        throw new ArtifactHttpError(
          400,
          "invalid_project_path",
          "projectPath must be a string",
        );
      }
      if (
        parsed.filename !== undefined &&
        typeof parsed.filename !== "string"
      ) {
        throw new ArtifactHttpError(
          400,
          "invalid_filename",
          "filename must be a string",
        );
      }
      if (
        parsed.baseUrl !== undefined &&
        typeof parsed.baseUrl !== "string"
      ) {
        throw new ArtifactHttpError(
          400,
          "invalid_base_url",
          "baseUrl must be a string",
        );
      }
      if (
        typeof parsed.baseUrl === "string" &&
        !validateArtifactBaseUrl(parsed.baseUrl)
      ) {
        throw new ArtifactHttpError(
          400,
          "invalid_base_url",
          "baseUrl must be a mobile-reachable HTTP(S) origin",
        );
      }

      const artifact = await this.store.publish(parsed.filePath, {
        projectPath: parsed.projectPath as string | undefined,
        filename: parsed.filename as string | undefined,
        ttlSeconds: parsed.ttlSeconds as number | undefined,
        baseUrl: parsed.baseUrl as string | undefined,
      });
      sendArtifactJson(res, 201, { artifact });
    } catch (error) {
      sendArtifactError(res, error);
    }
  }

  private async servePreview(
    token: string,
    headOnly: boolean,
    embedded: boolean,
    res: ServerResponse,
  ): Promise<void> {
    const entry = this.store.getEntry(token);
    if (!entry) {
      sendArtifactText(res, 404, "Not Found");
      return;
    }

    let handle: FileHandle | undefined;
    try {
      handle = await this.store.openCurrentEntry(entry);
      let textPreview: string | undefined;
      let textPreviewTruncated = false;
      const detectedPreviewKind = previewKindForFile(
        entry.filename,
        entry.mimeType,
      );
      const previewKind =
        detectedPreviewKind === "docx" &&
        entry.size > MAX_DOCX_BROWSER_PREVIEW_BYTES
          ? "office"
          : detectedPreviewKind;
      if (previewKind === "text") {
        const bytesToRead = Math.min(entry.size, MAX_TEXT_PREVIEW_BYTES);
        const buffer = Buffer.alloc(bytesToRead);
        const { bytesRead } = await handle.read(buffer, 0, bytesToRead, 0);
        textPreview = buffer.subarray(0, bytesRead).toString("utf8");
        textPreviewTruncated = entry.size > bytesRead;
      }
      await handle.close();
      handle = undefined;

      const html = renderArtifactPreviewHtml({
        token,
        filename: entry.filename,
        mimeType: entry.mimeType,
        sizeBytes: entry.size,
        expiresAt: new Date(entry.expiresAt).toISOString(),
        embedded,
        textPreview,
        textPreviewTruncated,
        previewKind,
      });
      const buffer = Buffer.from(html);
      res.writeHead(200, {
        "Content-Type": "text/html; charset=utf-8",
        "Content-Length": buffer.length,
        "Cache-Control": "private, no-store, max-age=0",
        Pragma: "no-cache",
        "X-Content-Type-Options": "nosniff",
        "Referrer-Policy": "no-referrer",
        "X-Frame-Options": "DENY",
        "Content-Security-Policy": "default-src 'none'; img-src 'self' data: blob:; media-src 'self'; frame-src 'self'; connect-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; font-src 'self' data: blob:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
      });
      res.end(headOnly ? undefined : buffer);
    } catch (error) {
      if (handle) await handle.close().catch(() => undefined);
      sendArtifactError(res, error);
    }
  }
}
