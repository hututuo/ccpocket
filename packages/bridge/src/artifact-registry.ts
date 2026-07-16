import { randomBytes, randomUUID } from "node:crypto";
import {
  chmod,
  mkdir,
  readFile,
  rename,
  unlink,
  writeFile,
} from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import type {
  ArtifactFileIdentity,
  ArtifactRegistryEntry,
  RegisterArtifactInput,
} from "./artifact-types.js";

interface ArtifactRegistryData {
  version: 1;
  entries: ArtifactRegistryEntry[];
}

export interface ArtifactRegistryOptions {
  filePath?: string;
  port?: number | string;
  maxEntries?: number;
  entryTtlMs?: number;
  now?: () => number;
  idFactory?: () => string;
}

const DEFAULT_BRIDGE_PORT = 8765;
const DEFAULT_MAX_ENTRIES = 5_000;
const DEFAULT_ENTRY_TTL_MS = 180 * 24 * 60 * 60 * 1_000;
const ARTIFACT_ID_PATTERN = /^[A-Za-z0-9_-]{22,128}$/;
const CANDIDATE_KEY_PATTERN = /^[A-Za-z0-9_-]{43}$/;
const MAX_ID_ATTEMPTS = 100;

export function artifactRegistryFileForPort(
  port: number | string | undefined,
  explicitFile?: string,
): string {
  if (explicitFile?.trim()) return explicitFile.trim();
  const parsedPort =
    typeof port === "number" ? port : Number.parseInt(port ?? "", 10);
  const filename =
    Number.isInteger(parsedPort) && parsedPort !== DEFAULT_BRIDGE_PORT
      ? `artifact-registry-v1-${parsedPort}.json`
      : "artifact-registry-v1.json";
  return join(homedir(), ".ccpocket", filename);
}

function cloneEntry(entry: ArtifactRegistryEntry): ArtifactRegistryEntry {
  return { ...entry, identity: { ...entry.identity } };
}

function cloneData(data: ArtifactRegistryData): ArtifactRegistryData {
  return { version: 1, entries: data.entries.map(cloneEntry) };
}

function isFiniteNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value);
}

function nodeErrorCode(error: unknown): string | undefined {
  return typeof error === "object" && error !== null && "code" in error
    ? String((error as { code?: unknown }).code)
    : undefined;
}

function isIdentity(value: unknown): value is ArtifactFileIdentity {
  if (typeof value !== "object" || value === null) return false;
  const candidate = value as Partial<ArtifactFileIdentity>;
  return (
    isFiniteNumber(candidate.dev) &&
    isFiniteNumber(candidate.ino) &&
    isFiniteNumber(candidate.size) &&
    candidate.size >= 0 &&
    isFiniteNumber(candidate.mtimeMs)
  );
}

function isRegistryEntry(value: unknown): value is ArtifactRegistryEntry {
  if (typeof value !== "object" || value === null) return false;
  const entry = value as Partial<ArtifactRegistryEntry>;
  return (
    typeof entry.artifactId === "string" &&
    ARTIFACT_ID_PATTERN.test(entry.artifactId) &&
    typeof entry.candidateKey === "string" &&
    CANDIDATE_KEY_PATTERN.test(entry.candidateKey) &&
    typeof entry.ownerId === "string" &&
    entry.ownerId.length > 0 &&
    typeof entry.messageId === "string" &&
    entry.messageId.length > 0 &&
    typeof entry.canonicalPath === "string" &&
    entry.canonicalPath.length > 0 &&
    typeof entry.filename === "string" &&
    entry.filename.length > 0 &&
    typeof entry.mimeType === "string" &&
    isFiniteNumber(entry.sizeBytes) &&
    entry.sizeBytes >= 0 &&
    isIdentity(entry.identity) &&
    entry.sizeBytes === entry.identity.size &&
    (entry.kind === "source" || entry.kind === "preview") &&
    (entry.source === "assistant_markdown" ||
      entry.source === "image_generation" ||
      entry.source === "structured_tool") &&
    (entry.line === undefined ||
      (Number.isInteger(entry.line) && entry.line > 0)) &&
    (entry.column === undefined ||
      (Number.isInteger(entry.column) && entry.column > 0)) &&
    isFiniteNumber(entry.createdAt) &&
    isFiniteNumber(entry.lastAccessAt) &&
    isFiniteNumber(entry.expiresAt)
  );
}

function dedupeMatches(
  entry: ArtifactRegistryEntry,
  input: RegisterArtifactInput,
): boolean {
  return (
    entry.ownerId === input.ownerId &&
    entry.messageId === input.messageId &&
    entry.candidateKey === input.candidateKey
  );
}

function validateRegistration(input: RegisterArtifactInput): void {
  if (
    !input.ownerId.trim() ||
    !input.messageId.trim() ||
    !CANDIDATE_KEY_PATTERN.test(input.candidateKey) ||
    !input.canonicalPath ||
    !input.filename ||
    !input.mimeType ||
    !isIdentity(input.identity) ||
    !Number.isFinite(input.sizeBytes) ||
    input.sizeBytes < 0 ||
    input.sizeBytes !== input.identity.size
  ) {
    throw new Error("Invalid artifact registration");
  }
}

/**
 * Persistent, Bridge-only artifact descriptors. The registry stores no public
 * capability token and never logs local paths or identifiers.
 */
export class ArtifactRegistry {
  readonly filePath: string;
  private readonly maxEntries: number;
  private readonly entryTtlMs: number;
  private readonly now: () => number;
  private readonly idFactory: () => string;
  private readonly managesDirectoryPermissions: boolean;
  private data: ArtifactRegistryData = { version: 1, entries: [] };
  private initBarrier?: Promise<void>;
  private mutationQueue: Promise<void> = Promise.resolve();

  constructor(options: ArtifactRegistryOptions = {}) {
    this.filePath = artifactRegistryFileForPort(options.port, options.filePath);
    this.managesDirectoryPermissions = !options.filePath?.trim();
    this.maxEntries = options.maxEntries ?? DEFAULT_MAX_ENTRIES;
    this.entryTtlMs = options.entryTtlMs ?? DEFAULT_ENTRY_TTL_MS;
    this.now = options.now ?? Date.now;
    this.idFactory =
      options.idFactory ?? (() => randomBytes(24).toString("base64url"));
    if (!Number.isInteger(this.maxEntries) || this.maxEntries < 1) {
      throw new Error("ArtifactRegistry maxEntries must be a positive integer");
    }
    if (!Number.isFinite(this.entryTtlMs) || this.entryTtlMs <= 0) {
      throw new Error("ArtifactRegistry entryTtlMs must be positive");
    }
  }

  /** A shared barrier prevents init/register races from overwriting disk data. */
  init(): Promise<void> {
    this.initBarrier ??= this.load().catch((error: unknown) => {
      this.initBarrier = undefined;
      throw error;
    });
    return this.initBarrier;
  }

  async register(input: RegisterArtifactInput): Promise<ArtifactRegistryEntry> {
    const [entry] = await this.registerMany([input]);
    return entry;
  }

  /** Register one message's candidates with a single atomic disk write. */
  async registerMany(
    inputs: RegisterArtifactInput[],
  ): Promise<ArtifactRegistryEntry[]> {
    for (const input of inputs) validateRegistration(input);
    if (inputs.length === 0) return [];
    await this.init();
    return this.enqueue(async () => {
      const snapshot = cloneData(this.data);
      try {
        const now = this.now();
        let changed = this.prune(now);
        const result: ArtifactRegistryEntry[] = [];
        for (const input of inputs) {
          const existing = this.data.entries.find((entry) =>
            dedupeMatches(entry, input),
          );
          if (existing) {
            const shouldRenew =
              existing.expiresAt - now <= Math.floor(this.entryTtlMs / 2);
            if (shouldRenew) {
              existing.lastAccessAt = now;
              existing.expiresAt = now + this.entryTtlMs;
              changed = true;
            }
            result.push(cloneEntry(existing));
            continue;
          }

          this.evictForInsert();
          const entry: ArtifactRegistryEntry = {
            artifactId: this.createId(),
            candidateKey: input.candidateKey,
            ownerId: input.ownerId,
            messageId: input.messageId,
            canonicalPath: input.canonicalPath,
            filename: input.filename,
            mimeType: input.mimeType,
            sizeBytes: input.sizeBytes,
            identity: { ...input.identity },
            kind: input.kind,
            source: input.source,
            line: input.line,
            column: input.column,
            createdAt: now,
            lastAccessAt: now,
            expiresAt: now + this.entryTtlMs,
          };
          this.data.entries.push(entry);
          result.push(cloneEntry(entry));
          changed = true;
        }
        if (changed) await this.save();
        return result;
      } catch (error) {
        this.data = snapshot;
        throw error;
      }
    });
  }

  async getAuthorized(
    artifactId: string,
    ownerId: string,
    messageId: string,
  ): Promise<ArtifactRegistryEntry | undefined> {
    await this.init();
    return this.enqueue(async () => {
      const snapshot = cloneData(this.data);
      try {
        const changed = this.prune(this.now());
        const entry = this.data.entries.find(
          (candidate) =>
            candidate.artifactId === artifactId &&
            candidate.ownerId === ownerId &&
            candidate.messageId === messageId,
        );
        if (changed) await this.save();
        return entry ? cloneEntry(entry) : undefined;
      } catch (error) {
        this.data = snapshot;
        throw error;
      }
    });
  }

  async getCandidate(
    ownerId: string,
    messageId: string,
    candidateKey: string,
  ): Promise<ArtifactRegistryEntry | undefined> {
    await this.init();
    return this.enqueue(async () => {
      const snapshot = cloneData(this.data);
      try {
        const changed = this.prune(this.now());
        const entry = this.data.entries.find(
          (candidate) =>
            candidate.ownerId === ownerId &&
            candidate.messageId === messageId &&
            candidate.candidateKey === candidateKey,
        );
        if (changed) await this.save();
        return entry ? cloneEntry(entry) : undefined;
      } catch (error) {
        this.data = snapshot;
        throw error;
      }
    });
  }

  async touch(
    artifactId: string,
    ownerId: string,
    messageId: string,
  ): Promise<boolean> {
    await this.init();
    return this.enqueue(async () => {
      const snapshot = cloneData(this.data);
      try {
        const now = this.now();
        const changed = this.prune(now);
        const entry = this.data.entries.find(
          (candidate) =>
            candidate.artifactId === artifactId &&
            candidate.ownerId === ownerId &&
            candidate.messageId === messageId,
        );
        if (!entry) {
          if (changed) await this.save();
          return false;
        }
        entry.lastAccessAt = now;
        entry.expiresAt = now + this.entryTtlMs;
        await this.save();
        return true;
      } catch (error) {
        this.data = snapshot;
        throw error;
      }
    });
  }

  async removeOwner(ownerId: string): Promise<number> {
    await this.init();
    return this.enqueue(async () => {
      const snapshot = cloneData(this.data);
      try {
        const before = this.data.entries.length;
        this.data.entries = this.data.entries.filter(
          (entry) => entry.ownerId !== ownerId,
        );
        const removed = before - this.data.entries.length;
        if (removed > 0) await this.save();
        return removed;
      } catch (error) {
        this.data = snapshot;
        throw error;
      }
    });
  }

  private async load(): Promise<void> {
    const directory = dirname(this.filePath);
    await mkdir(directory, {
      recursive: true,
      ...(this.managesDirectoryPermissions ? { mode: 0o700 } : {}),
    });
    let raw: string;
    try {
      raw = await readFile(this.filePath, "utf8");
    } catch (error) {
      if (nodeErrorCode(error) !== "ENOENT") throw error;
      this.data = { version: 1, entries: [] };
      return;
    }
    await chmod(this.filePath, 0o600);

    let parsed: unknown;
    try {
      parsed = JSON.parse(raw);
    } catch (error) {
      throw new Error("Artifact registry contains invalid JSON", {
        cause: error,
      });
    }
    if (typeof parsed !== "object" || parsed === null) {
      throw new Error("Artifact registry has an invalid root value");
    }
    const candidate = parsed as Partial<ArtifactRegistryData>;
    if (candidate.version !== 1) {
      throw new Error("Unsupported artifact registry version");
    }
    if (!Array.isArray(candidate.entries)) {
      throw new Error("Artifact registry entries are invalid");
    }
    this.data = {
      version: 1,
      entries: candidate.entries.filter(isRegistryEntry).map(cloneEntry),
    };

    const before = this.data.entries.length;
    this.prune(this.now());
    this.evictToCapacity();
    if (this.data.entries.length !== before) await this.save();
  }

  private enqueue<T>(operation: () => Promise<T>): Promise<T> {
    const result = this.mutationQueue.then(operation, operation);
    this.mutationQueue = result.then(
      () => undefined,
      () => undefined,
    );
    return result;
  }

  private createId(): string {
    for (let attempt = 0; attempt < MAX_ID_ATTEMPTS; attempt += 1) {
      const candidate = this.idFactory();
      if (
        ARTIFACT_ID_PATTERN.test(candidate) &&
        !this.data.entries.some((entry) => entry.artifactId === candidate)
      ) {
        return candidate;
      }
    }
    throw new Error("Unable to create a secure artifact id");
  }

  private prune(now: number): boolean {
    const before = this.data.entries.length;
    this.data.entries = this.data.entries.filter(
      (entry) => entry.expiresAt > now,
    );
    return this.data.entries.length !== before;
  }

  private evictForInsert(): void {
    while (this.data.entries.length >= this.maxEntries) {
      this.evictOldest();
    }
  }

  private evictToCapacity(): void {
    while (this.data.entries.length > this.maxEntries) {
      this.evictOldest();
    }
  }

  private evictOldest(): void {
    if (this.data.entries.length === 0) return;
    let oldestIndex = 0;
    for (let index = 1; index < this.data.entries.length; index += 1) {
      const candidate = this.data.entries[index];
      const oldest = this.data.entries[oldestIndex];
      if (
        candidate.lastAccessAt < oldest.lastAccessAt ||
        (candidate.lastAccessAt === oldest.lastAccessAt &&
          candidate.createdAt < oldest.createdAt)
      ) {
        oldestIndex = index;
      }
    }
    this.data.entries.splice(oldestIndex, 1);
  }

  private async save(): Promise<void> {
    const directory = dirname(this.filePath);
    await mkdir(directory, {
      recursive: true,
      ...(this.managesDirectoryPermissions ? { mode: 0o700 } : {}),
    });
    const temporaryPath = `${this.filePath}.${randomUUID()}.tmp`;
    try {
      await writeFile(temporaryPath, JSON.stringify(this.data, null, 2), {
        encoding: "utf8",
        mode: 0o600,
        flag: "wx",
      });
      await rename(temporaryPath, this.filePath);
    } catch (error) {
      await unlink(temporaryPath).catch(() => undefined);
      throw error;
    }
  }
}
