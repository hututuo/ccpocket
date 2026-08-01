import { randomUUID } from "node:crypto";
import { constants as fsConstants } from "node:fs";
import { chmod, lstat, mkdir, open, rename, rm } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

const STORE_VERSION = 1;
const DEFAULT_BRIDGE_PORT = 8765;
const DEFAULT_MAX_ENTRIES = 4_096;
const MAX_STORE_BYTES = 4 * 1024 * 1024;
const MAX_ID_LENGTH = 256;

export type TerminalResultProvider = "claude" | "codex";
export type TerminalResultValue = "completed" | "failed";

export interface TerminalResultScope {
  bridgeInstanceId: string;
  codexSourceId: string;
}

export interface TerminalResultLedgerHealth {
  initialized: boolean;
  ready: boolean;
  degraded: boolean;
  lastFailureAt?: string;
  lastError?: string;
}

export interface TerminalResultRecord extends TerminalResultScope {
  provider: TerminalResultProvider;
  threadId: string;
  /** Exact provider turn that produced this result when the source exposes it. */
  turnId?: string;
  result: TerminalResultValue;
  observedAt: string;
  revision: number;
}

interface TerminalResultStoreData {
  version: 1;
  revision: number;
  records: TerminalResultRecord[];
}

const DEFAULT_STORE_FILE = join(
  homedir(),
  ".ccpocket",
  "terminal-results-v1.json",
);

export function terminalResultLedgerFileForPort(
  port: number | string | undefined,
  explicitFile?: string,
): string {
  if (explicitFile?.trim()) return explicitFile.trim();
  const parsedPort =
    typeof port === "number" ? port : Number.parseInt(port ?? "", 10);
  if (!Number.isInteger(parsedPort) || parsedPort === DEFAULT_BRIDGE_PORT) {
    return DEFAULT_STORE_FILE;
  }
  return join(homedir(), ".ccpocket", `terminal-results-v1-${parsedPort}.json`);
}

export class TerminalResultLedger {
  private data: TerminalResultStoreData = emptyStore();
  private mutationTail: Promise<void> = Promise.resolve();
  private healthState: TerminalResultLedgerHealth = {
    initialized: false,
    ready: false,
    degraded: false,
  };

  constructor(
    readonly filePath = DEFAULT_STORE_FILE,
    private readonly maxEntries = DEFAULT_MAX_ENTRIES,
  ) {
    if (!Number.isSafeInteger(maxEntries) || maxEntries < 1) {
      throw new Error("Terminal result ledger capacity is invalid");
    }
  }

  get health(): TerminalResultLedgerHealth {
    return { ...this.healthState };
  }

  async init(): Promise<void> {
    try {
      await this.load();
      this.healthState = {
        initialized: true,
        ready: true,
        degraded: false,
      };
    } catch (error) {
      this.markDegraded(error, false);
      throw error;
    }
  }

  private async load(): Promise<void> {
    const directory = dirname(this.filePath);
    await mkdir(directory, { recursive: true, mode: 0o700 });
    if (process.platform !== "win32") await chmod(directory, 0o700);
    let handle: Awaited<ReturnType<typeof open>> | undefined;
    try {
      handle = await open(
        this.filePath,
        fsConstants.O_RDONLY |
          (process.platform === "win32" ? 0 : fsConstants.O_NOFOLLOW),
      );
    } catch (error) {
      const code = (error as NodeJS.ErrnoException)?.code;
      if (code === "ENOENT" || code === "ELOOP") {
        this.data = emptyStore();
        return;
      }
      throw error;
    }
    try {
      const metadata = await handle.stat();
      if (!metadata.isFile() || metadata.size > MAX_STORE_BYTES) {
        this.data = emptyStore();
        return;
      }
      if (process.platform !== "win32" && (metadata.mode & 0o077) !== 0) {
        await handle.chmod(0o600);
      }
      const raw = await handle.readFile("utf8");
      if (Buffer.byteLength(raw, "utf8") > MAX_STORE_BYTES) {
        this.data = emptyStore();
        return;
      }
      try {
        this.data =
          parseStore(JSON.parse(raw), this.maxEntries) ?? emptyStore();
      } catch (error) {
        if (!(error instanceof SyntaxError)) throw error;
        this.data = emptyStore();
      }
    } finally {
      await handle.close().catch(() => undefined);
    }
  }

  list(scope: TerminalResultScope): TerminalResultRecord[] {
    const normalized = normalizeScope(scope);
    return this.data.records
      .filter(
        (record) =>
          record.bridgeInstanceId === normalized.bridgeInstanceId &&
          record.codexSourceId === normalized.codexSourceId,
      )
      .map((record) => ({ ...record }));
  }

  async record(
    input: Omit<TerminalResultRecord, "revision">,
  ): Promise<TerminalResultRecord> {
    const normalized = normalizeRecord(input, 0);
    return this.runMutation(async (next) => {
      const key = terminalResultKey(normalized);
      const index = next.records.findIndex(
        (record) => terminalResultKey(record) === key,
      );
      const previous = index >= 0 ? next.records[index] : undefined;
      if (
        previous &&
        compareIso(previous.observedAt, normalized.observedAt) > 0
      ) {
        return { changed: false, value: { ...previous } };
      }
      if (
        previous &&
        previous.observedAt === normalized.observedAt &&
        previous.result === normalized.result &&
        previous.turnId === normalized.turnId
      ) {
        return { changed: false, value: { ...previous } };
      }
      next.revision += 1;
      const record: TerminalResultRecord = {
        ...normalized,
        revision: next.revision,
      };
      if (index >= 0) next.records[index] = record;
      else next.records.push(record);
      next.records = pruneRecords(next.records, this.maxEntries);
      return { changed: true, value: { ...record } };
    });
  }

  async clear(
    scope: TerminalResultScope,
    provider: TerminalResultProvider,
    threadId: string,
    observedAt: string,
    turnId?: string,
  ): Promise<boolean> {
    const target = {
      ...normalizeScope(scope),
      provider: normalizeProvider(provider),
      threadId: normalizeId(threadId, "thread"),
    };
    const clearAt = normalizeIso(observedAt);
    const exactTurnId = normalizeOptionalTurnId(turnId);
    return this.runMutation(async (next) => {
      const key = terminalResultKey(target);
      const index = next.records.findIndex(
        (record) => terminalResultKey(record) === key,
      );
      if (index < 0) return { changed: false, value: false };
      const previous = next.records[index]!;
      if (exactTurnId !== undefined && previous.turnId !== exactTurnId) {
        return { changed: false, value: false };
      }
      if (compareIso(previous.observedAt, clearAt) > 0) {
        return { changed: false, value: false };
      }
      next.records.splice(index, 1);
      next.revision += 1;
      return { changed: true, value: true };
    });
  }

  async flush(): Promise<void> {
    await this.mutationTail;
  }

  private async runMutation<T>(
    operation: (
      next: TerminalResultStoreData,
    ) => Promise<{ changed: boolean; value: T }>,
  ): Promise<T> {
    const previous = this.mutationTail;
    let release!: () => void;
    this.mutationTail = new Promise<void>((resolve) => {
      release = resolve;
    });
    await previous;
    try {
      const next = cloneStore(this.data);
      const result = await operation(next);
      if (!result.changed) return result.value;
      const publication = await this.save(next);
      // rename(2) is the publication boundary. chmod/fsync hardening happens
      // afterwards and can fail even though readers already see `next` on
      // disk. Keep memory aligned with the published file before surfacing a
      // durability error; otherwise the following mutation could clone stale
      // state and overwrite the successfully published record.
      this.data = next;
      if (publication.postPublishError !== undefined) {
        throw publication.postPublishError;
      }
      this.healthState = {
        initialized: true,
        ready: true,
        degraded: false,
      };
      return result.value;
    } catch (error) {
      this.markDegraded(error, true);
      throw error;
    } finally {
      release();
    }
  }

  private markDegraded(error: unknown, initialized: boolean): void {
    this.healthState = {
      initialized,
      ready: false,
      degraded: true,
      lastFailureAt: new Date().toISOString(),
      // Expose only the error class. Messages may include local paths and are
      // already written to the Bridge log at the call site when appropriate.
      lastError: error instanceof Error ? error.name : "UnknownError",
    };
  }

  private async save(
    data: TerminalResultStoreData,
  ): Promise<{ postPublishError?: unknown }> {
    const directory = dirname(this.filePath);
    await mkdir(directory, { recursive: true, mode: 0o700 });
    if (process.platform !== "win32") await chmod(directory, 0o700);
    const temporary = `${this.filePath}.${process.pid}.${randomUUID()}.tmp`;
    const serialized = `${JSON.stringify(data)}\n`;
    if (Buffer.byteLength(serialized, "utf8") > MAX_STORE_BYTES) {
      throw new Error("Terminal result ledger exceeds its size limit");
    }
    let handle: Awaited<ReturnType<typeof open>> | undefined;
    let postPublishError: unknown;
    try {
      handle = await open(
        temporary,
        fsConstants.O_WRONLY |
          fsConstants.O_CREAT |
          fsConstants.O_EXCL |
          (process.platform === "win32" ? 0 : fsConstants.O_NOFOLLOW),
        0o600,
      );
      await handle.writeFile(serialized, "utf8");
      await handle.sync();
      await handle.close();
      handle = undefined;
      await rename(temporary, this.filePath);
      try {
        await this.hardenPublishedStore(directory);
      } catch (error) {
        postPublishError = error;
      }
    } finally {
      await handle?.close().catch(() => undefined);
      await rm(temporary, { force: true }).catch(() => undefined);
    }
    return postPublishError === undefined ? {} : { postPublishError };
  }

  /** Post-rename hardening seam kept protected for deterministic fault tests. */
  protected async hardenPublishedStore(directory: string): Promise<void> {
    const published = await lstat(this.filePath);
    if (!published.isFile() || published.isSymbolicLink()) {
      throw new Error("Terminal result ledger publication was unsafe");
    }
    await chmod(this.filePath, 0o600);
    await fsyncDirectory(directory);
  }
}

function emptyStore(): TerminalResultStoreData {
  return { version: STORE_VERSION, revision: 0, records: [] };
}

function cloneStore(data: TerminalResultStoreData): TerminalResultStoreData {
  return {
    version: STORE_VERSION,
    revision: data.revision,
    records: data.records.map((record) => ({ ...record })),
  };
}

function parseStore(
  value: unknown,
  maxEntries: number,
): TerminalResultStoreData | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const record = value as Record<string, unknown>;
  if (
    record.version !== STORE_VERSION ||
    !Number.isSafeInteger(record.revision) ||
    (record.revision as number) < 0 ||
    !Array.isArray(record.records)
  ) {
    return null;
  }
  const byKey = new Map<string, TerminalResultRecord>();
  for (const raw of record.records) {
    try {
      const parsed = normalizeRecord(
        raw as Omit<TerminalResultRecord, "revision">,
        (raw as { revision?: unknown })?.revision,
      );
      const key = terminalResultKey(parsed);
      const previous = byKey.get(key);
      if (
        !previous ||
        compareIso(previous.observedAt, parsed.observedAt) <= 0
      ) {
        byKey.set(key, parsed);
      }
    } catch {
      // One malformed legacy row must not hide other valid terminal results.
    }
  }
  const records = pruneRecords([...byKey.values()], maxEntries);
  return {
    version: STORE_VERSION,
    revision: Math.max(
      record.revision as number,
      ...records.map((entry) => entry.revision),
    ),
    records,
  };
}

function normalizeRecord(
  value: Omit<TerminalResultRecord, "revision">,
  revision: unknown,
): TerminalResultRecord {
  return {
    ...normalizeScope(value),
    provider: normalizeProvider(value.provider),
    threadId: normalizeId(value.threadId, "thread"),
    ...optionalTurnId(value.turnId),
    result: normalizeResult(value.result),
    observedAt: normalizeIso(value.observedAt),
    revision:
      Number.isSafeInteger(revision) && (revision as number) >= 0
        ? (revision as number)
        : 0,
  };
}

function optionalTurnId(value: unknown): Pick<TerminalResultRecord, "turnId"> {
  const turnId = normalizeOptionalTurnId(value);
  return turnId === undefined ? {} : { turnId };
}

function normalizeOptionalTurnId(value: unknown): string | undefined {
  if (value === undefined) return undefined;
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    value.length > MAX_ID_LENGTH ||
    value.trim() !== value ||
    /[\u0000-\u001f\u007f]/.test(value)
  ) {
    throw new Error("Terminal result turn identity is invalid");
  }
  return value;
}

function normalizeScope(scope: TerminalResultScope): TerminalResultScope {
  return {
    bridgeInstanceId: normalizeId(scope.bridgeInstanceId, "Bridge"),
    codexSourceId: normalizeId(scope.codexSourceId, "source"),
  };
}

function normalizeId(value: unknown, label: string): string {
  const normalized = typeof value === "string" ? value.trim() : "";
  if (!normalized || normalized.length > MAX_ID_LENGTH) {
    throw new Error(`Terminal result ${label} identity is invalid`);
  }
  return normalized;
}

function normalizeProvider(value: unknown): TerminalResultProvider {
  if (value !== "claude" && value !== "codex") {
    throw new Error("Terminal result provider is invalid");
  }
  return value;
}

function normalizeResult(value: unknown): TerminalResultValue {
  if (value !== "completed" && value !== "failed") {
    throw new Error("Terminal result value is invalid");
  }
  return value;
}

function normalizeIso(value: unknown): string {
  if (
    typeof value !== "string" ||
    value.length > 64 ||
    !Number.isFinite(Date.parse(value))
  ) {
    throw new Error("Terminal result timestamp is invalid");
  }
  return new Date(value).toISOString();
}

function terminalResultKey(
  value: Pick<
    TerminalResultRecord,
    "bridgeInstanceId" | "codexSourceId" | "provider" | "threadId"
  >,
): string {
  return [
    value.bridgeInstanceId,
    value.codexSourceId,
    value.provider,
    value.threadId,
  ].join("\0");
}

function compareIso(left: string, right: string): number {
  return Date.parse(left) - Date.parse(right);
}

function pruneRecords(
  records: TerminalResultRecord[],
  maxEntries: number,
): TerminalResultRecord[] {
  return [...records]
    .sort(
      (left, right) =>
        compareIso(right.observedAt, left.observedAt) ||
        right.revision - left.revision,
    )
    .slice(0, maxEntries);
}

async function fsyncDirectory(directory: string): Promise<void> {
  if (process.platform === "win32") return;
  let handle: Awaited<ReturnType<typeof open>> | undefined;
  try {
    handle = await open(directory, fsConstants.O_RDONLY);
    await handle.sync();
  } finally {
    await handle?.close().catch(() => undefined);
  }
}
