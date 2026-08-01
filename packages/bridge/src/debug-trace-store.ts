import {
  chmod,
  constants,
  mkdir,
  open,
  readdir,
  rm,
  stat,
} from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import type { DebugTraceEvent } from "./parser.js";

const DEFAULT_ROOT_DIR = join(homedir(), ".ccpocket", "debug");
const TRACE_DIRNAME = "traces";
const BUNDLE_DIRNAME = "bundles";
const DEFAULT_MAX_TRACE_BYTES = 4 * 1024 * 1024;
const DEFAULT_TRACE_RETENTION_MS = 7 * 24 * 60 * 60 * 1000;

export interface DebugTraceStoreOptions {
  /** Automatic transcript-adjacent trace persistence is opt-in. */
  persistTraces?: boolean;
  maxTraceBytes?: number;
  traceRetentionMs?: number;
  now?: () => number;
}

export class DebugTraceStore {
  private readonly rootDir: string;
  private readonly traceDir: string;
  private readonly bundleDir: string;
  private readonly persistTraces: boolean;
  private readonly maxTraceBytes: number;
  private readonly traceRetentionMs: number;
  private readonly now: () => number;
  private writeChains = new Map<string, Promise<void>>();

  constructor(
    rootDir: string = DEFAULT_ROOT_DIR,
    options: DebugTraceStoreOptions = {},
  ) {
    this.rootDir = rootDir;
    this.traceDir = join(rootDir, TRACE_DIRNAME);
    this.bundleDir = join(rootDir, BUNDLE_DIRNAME);
    this.persistTraces =
      options.persistTraces ?? process.env.BRIDGE_PERSIST_DEBUG_TRACES === "1";
    this.maxTraceBytes = positiveLimit(
      options.maxTraceBytes,
      DEFAULT_MAX_TRACE_BYTES,
    );
    this.traceRetentionMs = positiveLimit(
      options.traceRetentionMs,
      DEFAULT_TRACE_RETENTION_MS,
    );
    this.now = options.now ?? Date.now;
  }

  async init(): Promise<void> {
    await secureDirectory(this.rootDir);
    await secureDirectory(this.traceDir);
    await secureDirectory(this.bundleDir);
    await Promise.all([
      this.hardenExistingFiles(this.traceDir),
      this.hardenExistingFiles(this.bundleDir),
    ]);
    await this.pruneExpiredTraces();
  }

  getTraceFilePath(sessionId: string): string {
    return join(this.traceDir, `${sanitizeSegment(sessionId)}.jsonl`);
  }

  getBundleFilePath(sessionId: string, generatedAt: string): string {
    return join(
      this.bundleDir,
      `${sanitizeSegment(sessionId)}-${timestampToken(generatedAt)}.json`,
    );
  }

  saveBundleAtPath(path: string, bundle: Record<string, unknown>): void {
    const body = JSON.stringify(bundle, null, 2);
    this.enqueue(path, async () => {
      await writeSecureFile(path, body);
    });
  }

  saveBundle(
    sessionId: string,
    generatedAt: string,
    bundle: Record<string, unknown>,
  ): string {
    const path = this.getBundleFilePath(sessionId, generatedAt);
    this.saveBundleAtPath(path, bundle);
    return path;
  }

  record(event: DebugTraceEvent): void {
    if (!this.persistTraces) return;
    const path = this.getTraceFilePath(event.sessionId);
    const line = `${JSON.stringify(event)}\n`;
    this.enqueue(path, async () => {
      await appendBoundedSecureFile(path, line, this.maxTraceBytes);
    });
  }

  async flush(): Promise<void> {
    const pendingWrites = [...this.writeChains.values()];
    await Promise.all(pendingWrites.map((p) => p.catch(() => {})));
  }

  private enqueue(path: string, task: () => Promise<void>): void {
    const previous = this.writeChains.get(path) ?? Promise.resolve();
    const next = previous
      .catch(() => {})
      .then(async () => {
        await secureDirectory(dirname(path));
        await task();
      })
      .finally(() => {
        // Avoid unbounded growth: clear settled chain if no newer chain replaced it.
        if (this.writeChains.get(path) === next) {
          this.writeChains.delete(path);
        }
      });

    this.writeChains.set(path, next);
    void next.catch((err) => {
      const detail =
        err instanceof Error
          ? `${err.name}${"code" in err ? `:${String((err as NodeJS.ErrnoException).code ?? "")}` : ""}`
          : "unknown_error";
      console.warn(
        `[debug-trace-store] Failed to persist diagnostic trace (${detail})`,
      );
    });
  }

  private async hardenExistingFiles(directory: string): Promise<void> {
    const entries = await readdir(directory, { withFileTypes: true }).catch(
      () => [],
    );
    await Promise.all(
      entries
        .filter((entry) => entry.isFile())
        .map((entry) =>
          chmod(join(directory, entry.name), 0o600).catch(() => {}),
        ),
    );
  }

  private async pruneExpiredTraces(): Promise<void> {
    const cutoff = this.now() - this.traceRetentionMs;
    const entries = await readdir(this.traceDir, { withFileTypes: true }).catch(
      () => [],
    );
    await Promise.all(
      entries
        .filter((entry) => entry.isFile() && entry.name.endsWith(".jsonl"))
        .map(async (entry) => {
          const path = join(this.traceDir, entry.name);
          const metadata = await stat(path).catch(() => null);
          if (metadata && metadata.mtimeMs < cutoff) {
            await rm(path, { force: true });
          }
        }),
    );
  }
}

function positiveLimit(value: number | undefined, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value) && value > 0
    ? Math.floor(value)
    : fallback;
}

async function secureDirectory(path: string): Promise<void> {
  await mkdir(path, { recursive: true, mode: 0o700 });
  await chmod(path, 0o700).catch(() => {});
}

function noFollowFlag(): number {
  return process.platform === "win32" ? 0 : constants.O_NOFOLLOW;
}

async function writeSecureFile(path: string, body: string): Promise<void> {
  const handle = await open(
    path,
    constants.O_WRONLY | constants.O_CREAT | constants.O_TRUNC | noFollowFlag(),
    0o600,
  );
  try {
    await handle.writeFile(body, "utf8");
    await handle.chmod(0o600).catch(() => {});
  } finally {
    await handle.close();
  }
}

async function appendBoundedSecureFile(
  path: string,
  line: string,
  maxBytes: number,
): Promise<void> {
  const handle = await open(
    path,
    constants.O_WRONLY |
      constants.O_CREAT |
      constants.O_APPEND |
      noFollowFlag(),
    0o600,
  );
  try {
    const metadata = await handle.stat();
    if (metadata.size + Buffer.byteLength(line) > maxBytes) {
      await handle.truncate(0);
    }
    await handle.writeFile(line, "utf8");
    await handle.chmod(0o600).catch(() => {});
  } finally {
    await handle.close();
  }
}

function sanitizeSegment(value: string): string {
  return value.replace(/[^a-zA-Z0-9._-]/g, "_");
}

function timestampToken(iso: string): string {
  const token = iso.replace(/[^0-9]/g, "");
  if (token.length >= 17) return token.slice(0, 17);
  if (token.length >= 14) return token.slice(0, 14);
  return Date.now().toString();
}
