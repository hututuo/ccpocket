import type { IncomingMessage, ServerResponse } from "node:http";
import type { FileHandle } from "node:fs/promises";
import {
  ArtifactHttpError,
  type ArtifactEntry,
  type ArtifactStore,
} from "./artifact-store.js";

export interface ByteRange {
  start: number;
  end: number;
}

export interface ArtifactServeOptions {
  contentType?: string;
  contentSecurityPolicy?: string;
  extraHeaders?: Record<string, string | number>;
}

function asciiFilename(input: string): string {
  const ascii = input
    .normalize("NFKD")
    .replace(/[^\x20-\x7e]/g, "_")
    .replace(/["\\]/g, "_")
    .trim();
  return Array.from(ascii || "download").slice(0, 180).join("");
}

function encodeRfc5987(input: string): string {
  return encodeURIComponent(input).replace(/[!'()*]/g, (char) =>
    `%${char.charCodeAt(0).toString(16).toUpperCase()}`,
  );
}

export function contentDisposition(
  disposition: "inline" | "attachment",
  filename: string,
): string {
  return `${disposition}; filename="${asciiFilename(filename)}"; filename*=UTF-8''${encodeRfc5987(filename)}`;
}

export function parseByteRange(
  header: string | undefined,
  size: number,
): ByteRange | null | undefined {
  if (!header) return undefined;
  if (size <= 0 || !header.startsWith("bytes=") || header.includes(",")) {
    return null;
  }

  const value = header.slice("bytes=".length).trim();
  const match = value.match(/^(\d*)-(\d*)$/);
  if (!match || (!match[1] && !match[2])) return null;

  if (!match[1]) {
    const suffixLength = Number(match[2]);
    if (!Number.isSafeInteger(suffixLength) || suffixLength <= 0) return null;
    return {
      start: Math.max(0, size - suffixLength),
      end: size - 1,
    };
  }

  const start = Number(match[1]);
  const requestedEnd = match[2] ? Number(match[2]) : size - 1;
  if (
    !Number.isSafeInteger(start) ||
    !Number.isSafeInteger(requestedEnd) ||
    start < 0 ||
    start >= size ||
    requestedEnd < start
  ) {
    return null;
  }

  return { start, end: Math.min(requestedEnd, size - 1) };
}

export function sendArtifactText(
  res: ServerResponse,
  statusCode: number,
  body: string,
  headers?: Record<string, string | number>,
): void {
  const buffer = Buffer.from(body);
  res.writeHead(statusCode, {
    "Content-Type": "text/plain; charset=utf-8",
    "Content-Length": buffer.length,
    ...headers,
  });
  res.end(buffer);
}

export function sendArtifactJson(
  res: ServerResponse,
  statusCode: number,
  value: unknown,
): void {
  const buffer = Buffer.from(JSON.stringify(value));
  res.writeHead(statusCode, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": buffer.length,
    "Cache-Control": "no-store",
  });
  res.end(buffer);
}

export function sendArtifactError(
  res: ServerResponse,
  error: unknown,
): void {
  if (error instanceof ArtifactHttpError) {
    sendArtifactJson(res, error.statusCode, {
      error: error.message,
      errorCode: error.code,
    });
    return;
  }
  sendArtifactJson(res, 500, {
    error: "Internal Server Error",
    errorCode: "artifact_internal_error",
  });
}

function contentHeaders(
  entry: ArtifactEntry,
  disposition: "inline" | "attachment",
  contentLength: number,
  options: ArtifactServeOptions,
): Record<string, string | number> {
  return {
    "Content-Type": options.contentType ?? entry.mimeType,
    "Content-Disposition": contentDisposition(disposition, entry.filename),
    "Content-Length": contentLength,
    "Accept-Ranges": "bytes",
    "Cache-Control": "private, no-store, max-age=0",
    Pragma: "no-cache",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
    "Content-Security-Policy":
      options.contentSecurityPolicy ?? "sandbox; default-src 'none'",
    ...options.extraHeaders,
  };
}

export async function serveArtifactFile(
  store: ArtifactStore,
  token: string,
  disposition: "inline" | "attachment",
  req: IncomingMessage,
  res: ServerResponse,
  options: ArtifactServeOptions = {},
): Promise<void> {
  const entry = store.getEntry(token);
  if (!entry) {
    sendArtifactText(res, 404, "Not Found");
    return;
  }

  const headOnly = req.method === "HEAD";
  const range = headOnly
    ? undefined
    : parseByteRange(
        typeof req.headers.range === "string" ? req.headers.range : undefined,
        entry.size,
      );
  if (range === null) {
    sendArtifactText(res, 416, "Range Not Satisfiable", {
      "Content-Range": `bytes */${entry.size}`,
      "Accept-Ranges": "bytes",
    });
    return;
  }

  let handle: FileHandle | undefined;
  try {
    handle = await store.openCurrentEntry(entry);
    const contentLength = range ? range.end - range.start + 1 : entry.size;
    const headers = contentHeaders(entry, disposition, contentLength, options);
    if (range) {
      headers["Content-Range"] =
        `bytes ${range.start}-${range.end}/${entry.size}`;
    }
    res.writeHead(range ? 206 : 200, headers);

    if (headOnly || contentLength === 0) {
      await handle.close();
      handle = undefined;
      res.end();
      return;
    }

    const stream = handle.createReadStream({
      start: range?.start,
      end: range?.end,
      autoClose: true,
    });
    handle = undefined;
    req.once("aborted", () => stream.destroy());
    res.once("close", () => {
      if (!res.writableEnded) stream.destroy();
    });
    stream.once("error", (error) => res.destroy(error));
    stream.pipe(res);
  } catch (error) {
    if (handle) await handle.close().catch(() => undefined);
    if (!res.headersSent) sendArtifactError(res, error);
    else res.destroy(error instanceof Error ? error : undefined);
  }
}
