import { createHash, randomUUID } from "node:crypto";
import { createWriteStream } from "node:fs";
import {
  chmod,
  link,
  lstat,
  mkdir,
  open,
  readFile,
  readdir,
  realpath,
  rmdir,
  rm,
  stat,
  unlink,
  utimes,
  writeFile,
} from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { basename, isAbsolute, join, relative, resolve, sep } from "node:path";
import { pipeline } from "node:stream/promises";

const DEFAULT_MAX_FILE_SIZE_BYTES = 100 * 1024 * 1024;
const DEFAULT_MAX_ENTRIES = 5_000;
const DEFAULT_ENTRY_TTL_MS = 180 * 24 * 60 * 60 * 1_000;
const MANAGED_BUCKET_PATTERN = /^[A-Za-z0-9_-]{43}$/;
const MANAGED_TEMP_PATTERN =
  /^\.tmp-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const MARKER_FILENAME = ".ccpocket-generated-artifact-v1";

interface ManagedBucketMarker {
  version: 1;
  filename: string;
}

interface ManagedBucket {
  path: string;
  marker: ManagedBucketMarker;
  lastAccessAt: number;
}

export interface GeneratedArtifactStoreOptions {
  directory?: string;
  trustedSourceRoots?: string[];
  maxFileSizeBytes?: number;
  maxEntries?: number;
  entryTtlMs?: number;
  now?: () => number;
}

export interface PersistGeneratedArtifactInput {
  sourcePath: string;
  cwd: string;
  ownerId: string;
  messageId: string;
  /** Hash of the original provider candidate, before the path is rewritten. */
  candidateKey: string;
}

export function generatedArtifactDirectory(): string {
  return join(homedir(), ".ccpocket", "artifacts", "generated");
}

/**
 * Codex currently writes ImageGeneration results to either its fixed /tmp
 * directory or a platform temp directory. These narrow roots are the only
 * provider-owned locations from which automatic persistence is allowed.
 */
export function defaultCodexGeneratedImageRoots(): string[] {
  return [
    join("/tmp", "codex", "generated_images"),
    join(tmpdir(), "codex", "generated_images"),
  ];
}

function nodeErrorCode(error: unknown): string | undefined {
  return typeof error === "object" && error !== null && "code" in error
    ? String((error as { code?: unknown }).code)
    : undefined;
}

function isWithinRoot(filePath: string, root: string): boolean {
  const rel = relative(root, filePath);
  return (
    rel === "" ||
    (rel !== ".." && !rel.startsWith(`..${sep}`) && !isAbsolute(rel))
  );
}

function sameIdentity(
  left: { dev: number; ino: number; size: number; mtimeMs: number },
  right: { dev: number; ino: number; size: number; mtimeMs: number },
): boolean {
  return (
    left.dev === right.dev &&
    left.ino === right.ino &&
    left.size === right.size &&
    left.mtimeMs === right.mtimeMs
  );
}

function safeFilename(filePath: string): string {
  const value = basename(filePath)
    .replace(/[\u0000-\u001f\u007f"\\]/g, "_")
    .trim();
  const limited = Array.from(value || "generated-image")
    .slice(0, 180)
    .join("");
  return limited === "." ||
    limited === ".." ||
    limited === MARKER_FILENAME ||
    MANAGED_TEMP_PATTERN.test(limited)
    ? `generated-${limited.replace(/^\.+/, "") || "image"}`
    : limited;
}

function isSafeManagedFilename(filename: string): boolean {
  return (
    filename.length > 0 &&
    filename !== "." &&
    filename !== ".." &&
    filename === basename(filename) &&
    !filename.includes("/") &&
    !filename.includes("\\") &&
    filename === safeFilename(filename)
  );
}

/**
 * Copies trusted, ephemeral Codex-generated images into private Bridge-owned
 * storage. The destination is derived from opaque hashes and is never
 * overwritten, so a history replay cannot silently rebind an artifact.
 */
export class GeneratedArtifactStore {
  readonly directory: string;
  private readonly trustedSourceRoots: string[];
  private readonly maxFileSizeBytes: number;
  private readonly maxEntries: number;
  private readonly entryTtlMs: number;
  private readonly now: () => number;
  private mutationQueue: Promise<void> = Promise.resolve();
  private managedRoot?: string;
  private managedBuckets?: Map<string, ManagedBucket>;

  constructor(options: GeneratedArtifactStoreOptions = {}) {
    this.directory = options.directory ?? generatedArtifactDirectory();
    this.trustedSourceRoots =
      options.trustedSourceRoots ?? defaultCodexGeneratedImageRoots();
    this.maxFileSizeBytes =
      options.maxFileSizeBytes ?? DEFAULT_MAX_FILE_SIZE_BYTES;
    this.maxEntries = options.maxEntries ?? DEFAULT_MAX_ENTRIES;
    this.entryTtlMs = options.entryTtlMs ?? DEFAULT_ENTRY_TTL_MS;
    this.now = options.now ?? Date.now;
    if (!Number.isFinite(this.maxFileSizeBytes) || this.maxFileSizeBytes <= 0) {
      throw new Error(
        "GeneratedArtifactStore maxFileSizeBytes must be positive",
      );
    }
    if (!Number.isInteger(this.maxEntries) || this.maxEntries < 1) {
      throw new Error(
        "GeneratedArtifactStore maxEntries must be a positive integer",
      );
    }
    if (!Number.isFinite(this.entryTtlMs) || this.entryTtlMs <= 0) {
      throw new Error("GeneratedArtifactStore entryTtlMs must be positive");
    }
  }

  async persist(
    input: PersistGeneratedArtifactInput,
  ): Promise<string | undefined> {
    if (
      !input.sourcePath.trim() ||
      !input.cwd.trim() ||
      !input.ownerId.trim() ||
      !input.messageId.trim() ||
      !input.candidateKey.trim()
    ) {
      return undefined;
    }

    return this.enqueue(() => this.persistLocked(input));
  }

  /** Refresh the retention clock only for a path owned by this helper. */
  async touch(filePath: string): Promise<boolean> {
    return this.enqueue(async () => {
      try {
        const canonicalDirectory = await this.ensureManagedDirectory(false);
        await this.loadManagedBuckets(canonicalDirectory);
        const canonicalPath = await realpath(filePath);
        if (!isWithinRoot(canonicalPath, canonicalDirectory)) return false;
        const rel = relative(canonicalDirectory, canonicalPath);
        const parts = rel.split(sep);
        if (parts.length !== 2 || !MANAGED_BUCKET_PATTERN.test(parts[0])) {
          return false;
        }
        const bucket = this.managedBuckets?.get(parts[0]);
        if (!bucket || bucket.marker.filename !== parts[1]) return false;
        if (
          !(await this.isPrivateRegularFile(canonicalPath, canonicalDirectory))
        ) {
          return false;
        }
        await this.touchBucket(parts[0], bucket);
        return true;
      } catch {
        return false;
      }
    });
  }

  private async persistLocked(
    input: PersistGeneratedArtifactInput,
  ): Promise<string | undefined> {
    const storageKey = createHash("sha256")
      .update(
        JSON.stringify([input.ownerId, input.messageId, input.candidateKey]),
      )
      .digest("base64url");
    const filename = safeFilename(input.sourcePath);

    try {
      const canonicalDirectory = await this.ensureManagedDirectory(true);
      await this.loadManagedBuckets(canonicalDirectory);
      await this.pruneManagedBuckets();

      let managedBucket = this.managedBuckets?.get(storageKey);
      const bucket = join(canonicalDirectory, storageKey);
      const destination = join(bucket, filename);

      // A completed copy may predate a registry write (for example, after a
      // crash). Reuse it without consulting the now-ephemeral source.
      if (
        managedBucket?.marker.filename === filename &&
        (await this.isPrivateRegularFile(destination, canonicalDirectory))
      ) {
        await this.touchBucket(storageKey, managedBucket);
        return destination;
      }

      const sourcePath = isAbsolute(input.sourcePath)
        ? input.sourcePath
        : resolve(input.cwd, input.sourcePath);
      const sourceHandle = await open(sourcePath, "r");
      try {
        const before = await sourceHandle.stat();
        if (!before.isFile() || before.size > this.maxFileSizeBytes) {
          return undefined;
        }

        const canonicalSource = await realpath(sourcePath);
        const canonicalStats = await stat(canonicalSource);
        if (!sameIdentity(before, canonicalStats)) return undefined;

        const trustedRoots = await this.canonicalTrustedRoots();
        if (!trustedRoots.some((root) => isWithinRoot(canonicalSource, root))) {
          return undefined;
        }

        await this.ensureCapacityForInsert(
          managedBucket ? storageKey : undefined,
        );
        managedBucket = await this.createManagedBucket(
          storageKey,
          bucket,
          filename,
        );
        if (!managedBucket) return undefined;
        const temporary = join(bucket, `.tmp-${randomUUID()}`);
        let published = false;
        try {
          await pipeline(
            sourceHandle.createReadStream({ autoClose: false, start: 0 }),
            createWriteStream(temporary, { flags: "wx", mode: 0o600 }),
          );
          const after = await sourceHandle.stat();
          if (!sameIdentity(before, after)) return undefined;
          await chmod(temporary, 0o600);

          try {
            // Hard-linking is an atomic no-clobber publication within the same
            // directory. A concurrent replay keeps whichever complete copy won.
            await link(temporary, destination);
          } catch (error) {
            if (nodeErrorCode(error) !== "EEXIST") throw error;
          }

          published = await this.isPrivateRegularFile(
            destination,
            canonicalDirectory,
          );
          return published ? destination : undefined;
        } finally {
          await rm(temporary, { force: true }).catch(() => undefined);
          if (!published && managedBucket) {
            await this.deleteManagedBucket(storageKey, managedBucket);
          }
        }
      } finally {
        await sourceHandle.close().catch(() => undefined);
      }
    } catch {
      // Automatic enrichment is best effort. Fail closed without logging a
      // provider path, which may contain private local information.
      return undefined;
    }
  }

  private enqueue<T>(operation: () => Promise<T>): Promise<T> {
    const run = this.mutationQueue.then(operation, operation);
    this.mutationQueue = run.then(
      () => undefined,
      () => undefined,
    );
    return run;
  }

  private async loadManagedBuckets(canonicalDirectory: string): Promise<void> {
    if (this.managedRoot === canonicalDirectory && this.managedBuckets) return;
    const buckets = new Map<string, ManagedBucket>();
    const entries = await readdir(canonicalDirectory, { withFileTypes: true });
    for (const entry of entries) {
      if (!entry.isDirectory() || !MANAGED_BUCKET_PATTERN.test(entry.name)) {
        continue;
      }
      const bucket = await this.readManagedBucket(
        join(canonicalDirectory, entry.name),
      );
      if (bucket) buckets.set(entry.name, bucket);
    }
    this.managedRoot = canonicalDirectory;
    this.managedBuckets = buckets;
  }

  private async readManagedBucket(
    bucketPath: string,
  ): Promise<ManagedBucket | undefined> {
    try {
      const bucketStats = await lstat(bucketPath);
      if (!bucketStats.isDirectory() || bucketStats.isSymbolicLink()) {
        return undefined;
      }
      const markerPath = join(bucketPath, MARKER_FILENAME);
      const markerStats = await lstat(markerPath);
      if (!markerStats.isFile() || markerStats.isSymbolicLink()) {
        return undefined;
      }
      const parsed = JSON.parse(
        await readFile(markerPath, "utf8"),
      ) as Partial<ManagedBucketMarker>;
      if (
        parsed.version !== 1 ||
        typeof parsed.filename !== "string" ||
        !isSafeManagedFilename(parsed.filename)
      ) {
        return undefined;
      }
      return {
        path: bucketPath,
        marker: { version: 1, filename: parsed.filename },
        lastAccessAt: markerStats.mtimeMs,
      };
    } catch {
      return undefined;
    }
  }

  private async createManagedBucket(
    storageKey: string,
    bucketPath: string,
    filename: string,
  ): Promise<ManagedBucket | undefined> {
    if (!this.managedBuckets) return undefined;
    const current = this.managedBuckets.get(storageKey);
    if (current) {
      return current.marker.filename === filename ? current : undefined;
    }

    try {
      await mkdir(bucketPath, { mode: 0o700 });
      await chmod(bucketPath, 0o700);
      const marker: ManagedBucketMarker = { version: 1, filename };
      const markerPath = join(bucketPath, MARKER_FILENAME);
      await writeFile(markerPath, JSON.stringify(marker), {
        flag: "wx",
        mode: 0o600,
      });
      const created: ManagedBucket = {
        path: bucketPath,
        marker,
        lastAccessAt: this.now(),
      };
      this.managedBuckets.set(storageKey, created);
      await this.touchBucket(storageKey, created);
      return created;
    } catch {
      // Never adopt or recursively remove an unmarked pre-existing directory.
      const recovered = await this.readManagedBucket(bucketPath);
      if (recovered?.marker.filename === filename) {
        this.managedBuckets.set(storageKey, recovered);
        return recovered;
      }
      return undefined;
    }
  }

  private async touchBucket(
    storageKey: string,
    bucket: ManagedBucket,
  ): Promise<void> {
    const touchedAt = this.now();
    const date = new Date(touchedAt);
    await utimes(join(bucket.path, MARKER_FILENAME), date, date);
    bucket.lastAccessAt = touchedAt;
    this.managedBuckets?.set(storageKey, bucket);
  }

  private async pruneManagedBuckets(): Promise<void> {
    if (!this.managedBuckets) return;
    const cutoff = this.now() - this.entryTtlMs;
    const expired = [...this.managedBuckets.entries()]
      .filter(([, bucket]) => bucket.lastAccessAt <= cutoff)
      .sort((left, right) => left[1].lastAccessAt - right[1].lastAccessAt);
    for (const [storageKey, bucket] of expired) {
      await this.deleteManagedBucket(storageKey, bucket);
    }
  }

  private async ensureCapacityForInsert(reservedKey?: string): Promise<void> {
    if (!this.managedBuckets) return;
    const oldest = (): [string, ManagedBucket] | undefined =>
      [...this.managedBuckets!.entries()]
        .filter(([key]) => key !== reservedKey)
        .sort((left, right) => left[1].lastAccessAt - right[1].lastAccessAt)[0];
    const targetSize = this.maxEntries - (reservedKey ? 0 : 1);
    while (this.managedBuckets.size > targetSize) {
      const candidate = oldest();
      if (!candidate) return;
      await this.deleteManagedBucket(candidate[0], candidate[1]);
    }
  }

  private async deleteManagedBucket(
    storageKey: string,
    bucket: ManagedBucket,
  ): Promise<void> {
    if (!this.managedBuckets) return;
    const verified = await this.readManagedBucket(bucket.path);
    if (!verified || verified.marker.filename !== bucket.marker.filename) {
      this.managedBuckets.delete(storageKey);
      return;
    }

    try {
      const names = await readdir(bucket.path);
      for (const name of names) {
        if (
          name !== MARKER_FILENAME &&
          name !== verified.marker.filename &&
          !MANAGED_TEMP_PATTERN.test(name)
        ) {
          continue;
        }
        await this.unlinkManagedFile(bucket.path, name);
      }
      // rmdir intentionally fails if a user placed any unrelated file here.
      await rmdir(bucket.path).catch(() => undefined);
    } finally {
      this.managedBuckets.delete(storageKey);
    }
  }

  private async canonicalTrustedRoots(): Promise<string[]> {
    const roots: string[] = [];
    for (const root of new Set(this.trustedSourceRoots)) {
      try {
        const canonical = await realpath(root);
        if (!roots.includes(canonical)) roots.push(canonical);
      } catch {
        // Missing roots grant no persistence authority.
      }
    }
    return roots;
  }

  private async ensureManagedDirectory(chmodDirectory: boolean): Promise<string> {
    await mkdir(this.directory, { recursive: true, mode: 0o700 });
    const lexicalStats = await lstat(this.directory);
    if (!lexicalStats.isDirectory() || lexicalStats.isSymbolicLink()) {
      throw new Error("Managed artifact root must be a real directory");
    }
    const canonicalDirectory = await realpath(this.directory);
    if (chmodDirectory) await chmod(canonicalDirectory, 0o700);
    return canonicalDirectory;
  }

  private async unlinkManagedFile(
    bucketPath: string,
    filename: string,
  ): Promise<void> {
    try {
      if (!isSafeManagedFilename(filename) && filename !== MARKER_FILENAME && !MANAGED_TEMP_PATTERN.test(filename)) {
        return;
      }
      const lexicalPath = join(bucketPath, filename);
      const lexicalRelative = relative(bucketPath, lexicalPath);
      if (
        lexicalRelative !== filename ||
        lexicalRelative === ".." ||
        lexicalRelative.startsWith(`..${sep}`) ||
        isAbsolute(lexicalRelative)
      ) {
        return;
      }
      const lexicalStats = await lstat(lexicalPath);
      if (!lexicalStats.isFile() || lexicalStats.isSymbolicLink()) return;
      const canonicalBucket = await realpath(bucketPath);
      const canonicalPath = await realpath(lexicalPath);
      if (!isWithinRoot(canonicalPath, canonicalBucket)) return;
      await unlink(lexicalPath);
    } catch {
      // A concurrent change simply leaves the file for a later cleanup pass.
    }
  }

  private async isPrivateRegularFile(
    filePath: string,
    canonicalDirectory: string,
  ): Promise<boolean> {
    try {
      const lexicalStats = await lstat(filePath);
      if (!lexicalStats.isFile() || lexicalStats.isSymbolicLink()) return false;
      const canonicalPath = await realpath(filePath);
      return isWithinRoot(canonicalPath, canonicalDirectory);
    } catch {
      return false;
    }
  }
}
