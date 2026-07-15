import { randomBytes } from "node:crypto";
import type { FileHandle } from "node:fs/promises";
import { open, realpath, stat as fileStat } from "node:fs/promises";
import { basename } from "node:path";
import {
  isPathWithinAllowedDirectory,
  resolvePlatformPathFrom,
} from "./path-utils.js";
import { mimeTypeForFilename } from "./artifact-preview.js";
import {
  buildArtifactMarkdown,
  buildArtifactPreviewUrl,
  validateArtifactBaseUrl,
} from "./artifact-url.js";

const TOKEN_PATTERN = /^[A-Za-z0-9_-]{43}$/;
const DEFAULT_TTL_SECONDS = 60 * 60;
const MIN_TTL_SECONDS = 60;
const MAX_TTL_SECONDS = 24 * 60 * 60;
const DEFAULT_MAX_ENTRIES = 100;
const DEFAULT_MAX_FILE_SIZE_BYTES = 2 * 1024 * 1024 * 1024;
const MAX_TOKEN_ATTEMPTS = 100;

interface FileIdentity {
  dev: number;
  ino: number;
  size: number;
  mtimeMs: number;
}

export interface ArtifactEntry extends FileIdentity {
  token: string;
  filePath: string;
  filename: string;
  mimeType: string;
  createdAt: number;
  expiresAt: number;
}

export interface PublishedArtifact {
  previewUrl: string;
  downloadUrl: string;
  markdown: string;
  filename: string;
  mimeType: string;
  sizeBytes: number;
  expiresAt: string;
}

export interface PublishArtifactOptions {
  projectPath?: string;
  filename?: string;
  ttlSeconds?: number;
  baseUrl?: string;
}

export interface ArtifactStoreOptions {
  baseUrl?: string;
  allowedDirs?: string[];
  platform?: NodeJS.Platform;
  maxEntries?: number;
  maxFileSizeBytes?: number;
  cleanupIntervalMs?: number;
  now?: () => number;
  tokenFactory?: () => string;
}

export class ArtifactHttpError extends Error {
  constructor(
    readonly statusCode: number,
    readonly code: string,
    message: string,
  ) {
    super(message);
  }
}

function fileIdentityMatches(
  expected: FileIdentity,
  actual: FileIdentity,
): boolean {
  return (
    expected.dev === actual.dev &&
    expected.ino === actual.ino &&
    expected.size === actual.size &&
    expected.mtimeMs === actual.mtimeMs
  );
}

function statsIdentity(stats: {
  dev: number;
  ino: number;
  size: number;
  mtimeMs: number;
}): FileIdentity {
  return {
    dev: stats.dev,
    ino: stats.ino,
    size: stats.size,
    mtimeMs: stats.mtimeMs,
  };
}

function ttlSeconds(value: unknown): number {
  if (value === undefined) return DEFAULT_TTL_SECONDS;
  if (typeof value !== "number" || !Number.isInteger(value)) {
    throw new ArtifactHttpError(
      400,
      "invalid_ttl",
      "ttlSeconds must be an integer",
    );
  }
  if (value < MIN_TTL_SECONDS || value > MAX_TTL_SECONDS) {
    throw new ArtifactHttpError(
      400,
      "invalid_ttl",
      `ttlSeconds must be between ${MIN_TTL_SECONDS} and ${MAX_TTL_SECONDS}`,
    );
  }
  return value;
}

function safeFilename(input: string): string {
  const cleaned = basename(input)
    .replace(/[\u0000-\u001f\u007f"\\]/g, "_")
    .trim();
  const limited = Array.from(cleaned || "download").slice(0, 180).join("");
  return limited || "download";
}

function errorCode(error: unknown): string | undefined {
  return typeof error === "object" && error !== null && "code" in error
    ? String((error as { code?: unknown }).code)
    : undefined;
}

export class ArtifactStore {
  private readonly entries = new Map<string, ArtifactEntry>();
  private readonly allowedDirs: string[];
  private readonly platform: NodeJS.Platform;
  private readonly maxEntries: number;
  private readonly maxFileSizeBytes: number;
  private readonly now: () => number;
  private readonly tokenFactory: () => string;
  private readonly cleanupTimer?: NodeJS.Timeout;
  private readonly baseUrl?: string;

  constructor(options: ArtifactStoreOptions = {}) {
    this.baseUrl = options.baseUrl;
    this.allowedDirs = options.allowedDirs ?? [];
    this.platform = options.platform ?? process.platform;
    this.maxEntries = options.maxEntries ?? DEFAULT_MAX_ENTRIES;
    this.maxFileSizeBytes =
      options.maxFileSizeBytes ?? DEFAULT_MAX_FILE_SIZE_BYTES;
    this.now = options.now ?? Date.now;
    this.tokenFactory =
      options.tokenFactory ?? (() => randomBytes(32).toString("base64url"));

    const cleanupIntervalMs = options.cleanupIntervalMs ?? 60_000;
    if (cleanupIntervalMs > 0) {
      this.cleanupTimer = setInterval(
        () => this.pruneExpired(),
        cleanupIntervalMs,
      );
      this.cleanupTimer.unref();
    }
  }

  close(): void {
    if (this.cleanupTimer) clearInterval(this.cleanupTimer);
    this.entries.clear();
  }

  async publish(
    filePath: string,
    options: PublishArtifactOptions = {},
  ): Promise<PublishedArtifact> {
    if (!filePath.trim()) {
      throw new ArtifactHttpError(400, "invalid_path", "filePath is required");
    }

    const lifetimeSeconds = ttlSeconds(options.ttlSeconds);
    const resolvedPath = resolvePlatformPathFrom(
      options.projectPath ?? process.cwd(),
      filePath,
      this.platform,
    );

    let handle: FileHandle;
    try {
      handle = await open(resolvedPath, "r");
    } catch (error) {
      const code = errorCode(error);
      throw new ArtifactHttpError(
        code === "ENOENT" ? 404 : 400,
        code === "ENOENT" ? "file_not_found" : "file_unreadable",
        code === "ENOENT" ? "File not found" : "File is not readable",
      );
    }

    try {
      const openedStats = await handle.stat();
      if (!openedStats.isFile()) {
        throw new ArtifactHttpError(
          400,
          "not_regular_file",
          "Only regular files can be shared",
        );
      }
      if (openedStats.size > this.maxFileSizeBytes) {
        throw new ArtifactHttpError(413, "file_too_large", "File is too large");
      }

      const canonicalPath = await realpath(resolvedPath);
      const canonicalStats = await fileStat(canonicalPath);
      const openedIdentity = statsIdentity(openedStats);
      if (!fileIdentityMatches(openedIdentity, statsIdentity(canonicalStats))) {
        throw new ArtifactHttpError(
          409,
          "file_changed",
          "File changed while it was being shared",
        );
      }
      if (!(await this.isAllowedCanonicalPath(canonicalPath))) {
        throw new ArtifactHttpError(
          403,
          "path_not_allowed",
          "File is outside BRIDGE_ALLOWED_DIRS",
        );
      }

      const baseUrl = options.baseUrl
        ? validateArtifactBaseUrl(options.baseUrl)
        : this.baseUrl;
      if (!baseUrl) {
        throw new ArtifactHttpError(
          503,
          "artifact_base_url_unavailable",
          "No mobile-reachable artifact base URL is available; use --base-url",
        );
      }

      this.pruneExpired();
      this.evictOldestIfNeeded();
      const token = this.createToken();
      const now = this.now();
      const filename = safeFilename(options.filename ?? canonicalPath);
      const entry: ArtifactEntry = {
        token,
        filePath: canonicalPath,
        filename,
        mimeType: mimeTypeForFilename(filename),
        createdAt: now,
        expiresAt: now + lifetimeSeconds * 1000,
        ...openedIdentity,
      };
      this.entries.set(token, entry);

      const previewUrl = buildArtifactPreviewUrl(baseUrl, token);
      return {
        previewUrl,
        downloadUrl: `${previewUrl}/download`,
        markdown: buildArtifactMarkdown(filename, previewUrl),
        filename,
        mimeType: entry.mimeType,
        sizeBytes: entry.size,
        expiresAt: new Date(entry.expiresAt).toISOString(),
      };
    } finally {
      await handle.close();
    }
  }

  getEntry(token: string): ArtifactEntry | undefined {
    const entry = this.entries.get(token);
    if (!entry) return undefined;
    if (entry.expiresAt <= this.now()) {
      this.entries.delete(token);
      return undefined;
    }
    return entry;
  }

  async openCurrentEntry(entry: ArtifactEntry): Promise<FileHandle> {
    let handle: FileHandle;
    try {
      handle = await open(entry.filePath, "r");
    } catch (error) {
      if (errorCode(error) === "ENOENT") {
        throw new ArtifactHttpError(
          410,
          "file_gone",
          "File is no longer available",
        );
      }
      throw new ArtifactHttpError(
        500,
        "file_open_failed",
        "Unable to open file",
      );
    }

    try {
      const stats = await handle.stat();
      if (!fileIdentityMatches(entry, statsIdentity(stats))) {
        throw new ArtifactHttpError(
          409,
          "file_changed",
          "File changed after the link was created",
        );
      }
      return handle;
    } catch (error) {
      await handle.close();
      throw error;
    }
  }

  private createToken(): string {
    for (let attempt = 0; attempt < MAX_TOKEN_ATTEMPTS; attempt += 1) {
      const candidate = this.tokenFactory();
      if (TOKEN_PATTERN.test(candidate) && !this.entries.has(candidate)) {
        return candidate;
      }
    }
    throw new ArtifactHttpError(
      500,
      "token_generation_failed",
      "Unable to create a secure artifact token",
    );
  }

  private async isAllowedCanonicalPath(filePath: string): Promise<boolean> {
    if (this.allowedDirs.length === 0) return true;
    for (const root of this.allowedDirs) {
      try {
        const canonicalRoot = await realpath(root);
        if (
          isPathWithinAllowedDirectory(filePath, canonicalRoot, this.platform)
        ) {
          return true;
        }
      } catch {
        // A missing allowed root cannot authorize a file.
      }
    }
    return false;
  }

  private pruneExpired(): void {
    const now = this.now();
    for (const [token, entry] of this.entries) {
      if (entry.expiresAt <= now) this.entries.delete(token);
    }
  }

  private evictOldestIfNeeded(): void {
    while (this.entries.size >= this.maxEntries) {
      let oldest: ArtifactEntry | undefined;
      for (const entry of this.entries.values()) {
        if (!oldest || entry.createdAt < oldest.createdAt) oldest = entry;
      }
      if (!oldest) return;
      this.entries.delete(oldest.token);
    }
  }
}
