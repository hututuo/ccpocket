import { createHash, timingSafeEqual } from "node:crypto";
import type { IncomingMessage, ServerResponse } from "node:http";

const MAX_API_KEY_BYTES = 4 * 1024;
const GALLERY_IMAGE_PATH = /^\/api\/gallery\/[A-Za-z0-9_-]+$/;

function digestCredential(value: string): Buffer {
  return createHash("sha256").update(value, "utf8").digest();
}

function singleHeader(req: IncomingMessage, name: string): string | undefined {
  const value = req.headers[name];
  return Array.isArray(value) ? undefined : value;
}

function bearerCredential(req: IncomingMessage): string | undefined {
  const authorization = singleHeader(req, "authorization");
  if (!authorization) return undefined;
  const match = authorization.match(/^Bearer ([^\s]+)$/i);
  return match?.[1];
}

function hasForwardingHeaders(req: IncomingMessage): boolean {
  return Boolean(
    req.headers.forwarded ||
    req.headers["x-forwarded-for"] ||
    req.headers["x-forwarded-host"] ||
    req.headers["x-forwarded-proto"],
  );
}

function directPeerAddress(req: IncomingMessage): string | undefined {
  if (hasForwardingHeaders(req)) return undefined;
  return req.socket.remoteAddress?.toLowerCase();
}

export function isLoopbackAddress(address?: string): boolean {
  if (!address) return false;
  const normalized = address.toLowerCase();
  if (normalized === "::1") return true;
  const ipv4 = normalized.startsWith("::ffff:")
    ? normalized.slice("::ffff:".length)
    : normalized;
  return ipv4.startsWith("127.");
}

export function isDirectLoopbackRequest(req: IncomingMessage): boolean {
  return (
    !hasForwardingHeaders(req) && isLoopbackAddress(req.socket.remoteAddress)
  );
}

export function requiresPrivateHttpAuthorization(
  method: string | undefined,
  rawUrl: string | undefined,
  options: { allowOpenModeReadiness?: boolean } = {},
): boolean {
  const path = (rawUrl ?? "").split("?", 1)[0];
  if (
    options.allowOpenModeReadiness === true &&
    method === "GET" &&
    path === "/readyz"
  ) {
    return false;
  }
  if (
    path === "/usage" ||
    path === "/doctor" ||
    path === "/readyz" ||
    path === "/pilot/diagnostics"
  ) {
    return true;
  }
  if (path === "/api/gallery" || path === "/api/gallery/upload") return true;
  return method === "DELETE" && GALLERY_IMAGE_PATH.test(path);
}

export class BridgeApiKeyAuthenticator {
  private readonly expectedDigest?: Buffer;
  private readonly authenticatedPeers = new Map<string, number>();
  private readonly deviceSessions = new Map<
    string,
    { digest: Buffer; remoteAddress?: string; expiresAt?: number }
  >();

  constructor(apiKey?: string) {
    if (apiKey && apiKey.trim()) {
      this.expectedDigest = digestCredential(apiKey);
    }
  }

  get isConfigured(): boolean {
    return this.expectedDigest !== undefined;
  }

  matches(candidate: string | undefined): boolean {
    if (!this.expectedDigest || candidate === undefined) return false;
    if (Buffer.byteLength(candidate, "utf8") > MAX_API_KEY_BYTES) return false;
    return timingSafeEqual(digestCredential(candidate), this.expectedDigest);
  }

  acceptsWebSocketRequest(req: IncomingMessage): boolean {
    if (!this.expectedDigest) return true;
    try {
      const url = new URL(req.url ?? "/", "http://bridge.invalid");
      return this.matches(url.searchParams.get("token") ?? undefined);
    } catch {
      return false;
    }
  }

  acceptsPrivateHttpRequest(req: IncomingMessage): boolean {
    if (isDirectLoopbackRequest(req)) return true;
    const bearer = bearerCredential(req);
    if (bearer !== undefined) {
      if (this.matches(bearer)) return true;
      const session = this.deviceSessions.get(
        digestCredential(bearer).toString("hex"),
      );
      if (
        !session ||
        (session.expiresAt !== undefined && session.expiresAt <= Date.now())
      ) {
        if (session)
          this.deviceSessions.delete(digestCredential(bearer).toString("hex"));
        return false;
      }
      if (
        session.remoteAddress &&
        session.remoteAddress !== directPeerAddress(req)
      )
        return false;
      return true;
    }
    if (!this.expectedDigest || req.headers.origin) return false;
    const address = directPeerAddress(req);
    return (
      address !== undefined && (this.authenticatedPeers.get(address) ?? 0) > 0
    );
  }

  /** Register a short-lived bearer issued after Ed25519 device authentication. */
  registerDeviceSession(
    token: string,
    options: { remoteAddress?: string; ttlMs?: number | null } = {},
  ): () => void {
    if (!token || token.length > MAX_API_KEY_BYTES) return () => undefined;
    const digest = digestCredential(token);
    const key = digest.toString("hex");
    this.deviceSessions.set(key, {
      digest,
      remoteAddress: options.remoteAddress,
      ...(options.ttlMs === null
        ? {}
        : {
            expiresAt:
              Date.now() + Math.max(1_000, options.ttlMs ?? 10 * 60_000),
          }),
    });
    let released = false;
    return () => {
      if (released) return;
      released = true;
      const current = this.deviceSessions.get(key);
      if (current?.digest.equals(digest)) this.deviceSessions.delete(key);
    };
  }

  trackAuthenticatedWebSocketPeer(req: IncomingMessage): () => void {
    if (!this.expectedDigest) return () => undefined;
    const address = directPeerAddress(req);
    if (!address) return () => undefined;
    this.authenticatedPeers.set(
      address,
      (this.authenticatedPeers.get(address) ?? 0) + 1,
    );
    let released = false;
    return () => {
      if (released) return;
      released = true;
      const remaining = (this.authenticatedPeers.get(address) ?? 1) - 1;
      if (remaining > 0) this.authenticatedPeers.set(address, remaining);
      else this.authenticatedPeers.delete(address);
    };
  }

  rejectPrivateHttpRequest(req: IncomingMessage, res: ServerResponse): void {
    req.resume();
    const statusCode = this.isConfigured ? 401 : 403;
    const body = Buffer.from(
      JSON.stringify({
        error: statusCode === 401 ? "Unauthorized" : "Forbidden",
        errorCode: this.isConfigured
          ? "api_key_required"
          : "remote_private_routes_disabled",
      }),
    );
    res.writeHead(statusCode, {
      "Content-Type": "application/json; charset=utf-8",
      "Content-Length": body.length,
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
      ...(statusCode === 401
        ? { "WWW-Authenticate": 'Bearer realm="CC Pocket Bridge"' }
        : {}),
    });
    res.end(body);
  }
}
