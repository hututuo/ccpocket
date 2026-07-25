import type { ServerResponse } from "node:http";
import { extname } from "node:path";
import { isLoopbackAddress } from "./bridge-http-auth.js";

const MIME_TYPES: Record<string, string> = {
  ".aac": "audio/aac",
  ".avi": "video/x-msvideo",
  ".bmp": "image/bmp",
  ".csv": "text/csv; charset=utf-8",
  ".doc": "application/msword",
  ".docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  ".gif": "image/gif",
  ".heic": "image/heic",
  ".html": "text/html; charset=utf-8",
  ".jpeg": "image/jpeg",
  ".jpg": "image/jpeg",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".log": "text/plain; charset=utf-8",
  ".m4a": "audio/mp4",
  ".md": "text/markdown; charset=utf-8",
  ".mov": "video/quicktime",
  ".mp3": "audio/mpeg",
  ".mp4": "video/mp4",
  ".pdf": "application/pdf",
  ".png": "image/png",
  ".ppt": "application/vnd.ms-powerpoint",
  ".pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
  ".py": "text/x-python; charset=utf-8",
  ".rtf": "application/rtf",
  ".sh": "text/x-shellscript; charset=utf-8",
  ".svg": "image/svg+xml",
  ".swift": "text/x-swift; charset=utf-8",
  ".ts": "text/typescript; charset=utf-8",
  ".tsv": "text/tab-separated-values; charset=utf-8",
  ".txt": "text/plain; charset=utf-8",
  ".wav": "audio/wav",
  ".webm": "video/webm",
  ".webp": "image/webp",
  ".xls": "application/vnd.ms-excel",
  ".xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  ".xml": "application/xml; charset=utf-8",
  ".yaml": "text/yaml; charset=utf-8",
  ".yml": "text/yaml; charset=utf-8",
  ".zip": "application/zip",
};

export function fileTransferMimeType(filename: string): string {
  return MIME_TYPES[extname(filename).toLowerCase()] ?? "application/octet-stream";
}

export function isFileTransferLoopbackAddress(address?: string): boolean {
  return isLoopbackAddress(address);
}

/** Validate a configured/CLI origin that must be reachable from the phone. */
export function validateFileTransferBaseUrl(rawUrl?: string): string | undefined {
  return validateOrigin(rawUrl, false);
}

/**
 * Validate the HTTP origin observed on an authenticated WebSocket handshake.
 * Exact loopback origins are valid here because an SSH local forward belongs
 * to the phone and is therefore its actual same-origin transfer endpoint.
 */
export function validateFileTransferPeerBaseUrl(rawUrl?: string): string | undefined {
  return validateOrigin(rawUrl, true);
}

function validateOrigin(
  rawUrl: string | undefined,
  allowExactLoopback: boolean,
): string | undefined {
  const trimmed = rawUrl?.trim();
  if (!trimmed) return undefined;
  let parsed: URL;
  try {
    parsed = new URL(trimmed);
  } catch {
    return undefined;
  }
  const hostname = normalizeHostname(parsed.hostname);
  const exactLoopback =
    hostname === "localhost" || hostname === "127.0.0.1" || hostname === "::1";
  const anyLoopback =
    hostname === "localhost" || hostname.startsWith("127.") ||
    hostname === "::1" || hostname.startsWith("::ffff:7f");
  const wildcard = hostname === "0.0.0.0" || hostname === "::";
  if (
    (parsed.protocol !== "http:" && parsed.protocol !== "https:") ||
    !hostname ||
    parsed.username ||
    parsed.password ||
    parsed.search ||
    parsed.hash ||
    (parsed.pathname !== "" && parsed.pathname !== "/") ||
    wildcard ||
    (anyLoopback && (!allowExactLoopback || !exactLoopback))
  ) {
    return undefined;
  }
  return parsed.toString().replace(/\/$/, "");
}

function normalizeHostname(hostname: string): string {
  const lower = hostname.toLowerCase();
  return lower.startsWith("[") && lower.endsWith("]")
    ? lower.slice(1, -1)
    : lower;
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

export function fileTransferContentDisposition(filename: string): string {
  return `attachment; filename="${asciiFilename(filename)}"; filename*=UTF-8''${encodeRfc5987(filename)}`;
}

export function sendFileTransferText(
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

export function sendFileTransferJson(
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
