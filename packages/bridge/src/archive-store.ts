import { mkdir, readFile, rename, unlink, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { homedir } from "node:os";
import { randomUUID } from "node:crypto";

export interface ArchivedSession {
  sessionId: string;
  provider: "claude" | "codex";
  projectPath: string;
  archivedAt: string;
  /** Best-effort local display metadata captured when the phone archives. */
  name?: string;
  summary?: string;
  firstPrompt?: string;
  modified?: string;
}

export function archiveIdentityKey(
  provider: ArchivedSession["provider"],
  sessionId: string,
): string {
  return `${provider}\u0000${sessionId}`;
}

interface ArchiveStoreData {
  version: 1;
  archivedSessions: ArchivedSession[];
}

export interface ArchiveCapacityReservation {
  readonly sessionId: string;
  readonly provider: ArchivedSession["provider"];
  readonly identityKey: string;
  readonly token: symbol | null;
  readonly alreadyArchived: boolean;
}

interface PendingArchiveReservation {
  readonly token: symbol;
  readonly released: Promise<void>;
  readonly release: () => void;
}

/**
 * Manages a persistent set of archived session IDs.
 * Data is stored in `~/.ccpocket/archived-sessions.json`.
 */
export class ArchiveStore {
  private readonly dirPath: string;
  private readonly filePath: string;
  /** In-memory cache of archived session IDs for O(1) lookup. */
  private cache = new Set<string>();
  private data: ArchiveStoreData = { version: 1, archivedSessions: [] };
  private mutationTail: Promise<void> = Promise.resolve();
  private readonly archiveReservations = new Map<
    string,
    PendingArchiveReservation
  >();

  constructor(dirPath = join(homedir(), ".ccpocket")) {
    this.dirPath = dirPath;
    this.filePath = join(this.dirPath, "archived-sessions.json");
  }

  /** Initialise the store: create directory if needed and load existing data. */
  async init(): Promise<void> {
    await mkdir(this.dirPath, { recursive: true });
    try {
      const raw = await readFile(this.filePath, "utf-8");
      const parsed = JSON.parse(raw) as ArchiveStoreData;
      if (parsed.version === 1 && Array.isArray(parsed.archivedSessions)) {
        const archivedSessions = parseArchivedSessions(
          parsed.archivedSessions,
        );
        this.data = { version: 1, archivedSessions };
        this.cache = new Set(
          archivedSessions.map((session) =>
            archiveIdentityKey(session.provider, session.sessionId),
          ),
        );
      } else {
        throw new Error("Unsupported or invalid archive store schema");
      }
    } catch (error) {
      if ((error as NodeJS.ErrnoException)?.code !== "ENOENT") {
        throw new Error(
          `Failed to load archived sessions without risking data loss: ${
            error instanceof Error ? error.message : String(error)
          }`,
        );
      }
      this.data = { version: 1, archivedSessions: [] };
      this.cache = new Set();
    }
    console.log(
      `[archive-store] Loaded ${this.cache.size} archived session(s)`,
    );
  }

  /** Archive a session. Idempotent – archiving an already-archived session is a no-op. */
  async archive(
    sessionId: string,
    provider: "claude" | "codex",
    projectPath: string,
    metadata: Pick<
      ArchivedSession,
      "name" | "summary" | "firstPrompt" | "modified"
    > = {},
  ): Promise<void> {
    const reservation = await this.reserveArchiveCapacity(sessionId, provider);
    try {
      await this.commitReservedArchive(reservation, projectPath, metadata);
    } finally {
      await this.releaseArchiveCapacity(reservation);
    }
  }

  /**
   * Reserve one persistent archive slot before a provider-side mutation starts.
   *
   * Reservations are serialized with all store mutations. A concurrent request
   * for the same provider/session identity waits for the owner and then observes
   * the committed entry as an idempotent no-op. Different identities cannot
   * reserve beyond the on-disk limit.
   */
  async reserveArchiveCapacity(
    sessionId: string,
    provider: ArchivedSession["provider"],
  ): Promise<ArchiveCapacityReservation> {
    const identityKey = archiveIdentityKey(provider, sessionId);
    for (;;) {
      const result = await this.mutate(async () => {
        if (this.cache.has(identityKey)) {
          return {
            kind: "reservation" as const,
            value: {
              sessionId,
              provider,
              identityKey,
              token: null,
              alreadyArchived: true,
            } satisfies ArchiveCapacityReservation,
          };
        }

        const owner = this.archiveReservations.get(identityKey);
        if (owner) {
          return { kind: "wait" as const, value: owner.released };
        }

        if (
          this.data.archivedSessions.length +
            this.uncommittedReservationCount() >=
          MAX_ARCHIVED_SESSIONS
        ) {
          throw new Error(
            `Archive store has reached the supported ${MAX_ARCHIVED_SESSIONS}-entry limit`,
          );
        }

        const token = Symbol(identityKey);
        let release!: () => void;
        const released = new Promise<void>((resolve) => {
          release = resolve;
        });
        this.archiveReservations.set(identityKey, {
          token,
          released,
          release,
        });
        return {
          kind: "reservation" as const,
          value: {
            sessionId,
            provider,
            identityKey,
            token,
            alreadyArchived: false,
          } satisfies ArchiveCapacityReservation,
        };
      });

      if (result.kind === "reservation") return result.value;
      await result.value;
    }
  }

  /** Persist an entry while its capacity reservation remains owned. */
  async commitReservedArchive(
    reservation: ArchiveCapacityReservation,
    projectPath: string,
    metadata: Pick<
      ArchivedSession,
      "name" | "summary" | "firstPrompt" | "modified"
    > = {},
  ): Promise<void> {
    if (reservation.alreadyArchived) return;
    await this.mutate(async () => {
      const owner = this.archiveReservations.get(reservation.identityKey);
      if (!owner || owner.token !== reservation.token) {
        throw new Error("Archive capacity reservation is no longer owned");
      }
      if (this.cache.has(reservation.identityKey)) return;
      if (this.data.archivedSessions.length >= MAX_ARCHIVED_SESSIONS) {
        throw new Error(
          `Archive store has reached the supported ${MAX_ARCHIVED_SESSIONS}-entry limit`,
        );
      }
      const entry: ArchivedSession = {
        sessionId: reservation.sessionId,
        provider: reservation.provider,
        projectPath,
        archivedAt: new Date().toISOString(),
        ...sanitizeDisplayMetadata(metadata),
      };
      await this.commit([...this.data.archivedSessions, entry]);
      console.log(`[archive-store] Archived session ${reservation.sessionId}`);
    });
  }

  /** Release a reservation after provider compensation has completed. */
  async releaseArchiveCapacity(
    reservation: ArchiveCapacityReservation,
  ): Promise<void> {
    if (reservation.alreadyArchived) return;
    await this.mutate(async () => {
      const owner = this.archiveReservations.get(reservation.identityKey);
      if (!owner || owner.token !== reservation.token) return;
      this.archiveReservations.delete(reservation.identityKey);
      owner.release();
    });
  }

  /** Check whether a session is archived. */
  isArchived(
    sessionId: string,
    provider: ArchivedSession["provider"],
  ): boolean {
    return this.cache.has(archiveIdentityKey(provider, sessionId));
  }

  /** Return the full set of archived session IDs (for bulk filtering). */
  archivedIds(provider: ArchivedSession["provider"]): ReadonlySet<string> {
    return new Set(
      this.data.archivedSessions
        .filter((session) => session.provider === provider)
        .map((session) => session.sessionId),
    );
  }

  archivedKeys(): ReadonlySet<string> {
    return new Set(this.cache);
  }

  /** Return immutable snapshots, newest archive first. */
  list(limit = MAX_ARCHIVED_SESSIONS): ArchivedSession[] {
    return this.data.archivedSessions
      .map((session) => ({ ...session }))
      .sort((left, right) => right.archivedAt.localeCompare(left.archivedAt))
      .slice(0, Math.max(0, limit));
  }

  /** Restore an archived entry to the normal recent-session list. */
  async unarchive(
    sessionId: string,
    provider: ArchivedSession["provider"],
  ): Promise<ArchivedSession | null> {
    return this.removeEntry(sessionId, provider, "Unarchived");
  }

  /** Remove bookkeeping after the provider permanently deletes a thread. */
  async remove(
    sessionId: string,
    provider: ArchivedSession["provider"],
  ): Promise<ArchivedSession | null> {
    return this.removeEntry(sessionId, provider, "Removed");
  }

  // ---- internal ----

  private async removeEntry(
    sessionId: string,
    provider: ArchivedSession["provider"],
    action: "Unarchived" | "Removed",
  ): Promise<ArchivedSession | null> {
    let removed: ArchivedSession | null = null;
    await this.mutate(async () => {
      const index = this.data.archivedSessions.findIndex(
        (session) =>
          session.sessionId === sessionId && session.provider === provider,
      );
      if (index < 0) return;
      removed = { ...this.data.archivedSessions[index] };
      const next = [...this.data.archivedSessions];
      next.splice(index, 1);
      await this.commit(next);
      console.log(`[archive-store] ${action} session ${sessionId}`);
    });
    return removed;
  }

  private async mutate<T>(operation: () => Promise<T>): Promise<T> {
    const previous = this.mutationTail;
    let release!: () => void;
    this.mutationTail = new Promise<void>((resolve) => {
      release = resolve;
    });
    await previous;
    try {
      return await operation();
    } finally {
      release();
    }
  }

  private async commit(archivedSessions: ArchivedSession[]): Promise<void> {
    if (archivedSessions.length > MAX_ARCHIVED_SESSIONS) {
      throw new Error(
        `Archive store has reached the supported ${MAX_ARCHIVED_SESSIONS}-entry limit`,
      );
    }
    const next: ArchiveStoreData = { version: 1, archivedSessions };
    await this.save(next);
    this.data = next;
    this.cache = new Set(
      archivedSessions.map((session) =>
        archiveIdentityKey(session.provider, session.sessionId),
      ),
    );
  }

  private uncommittedReservationCount(): number {
    let count = 0;
    for (const identityKey of this.archiveReservations.keys()) {
      if (!this.cache.has(identityKey)) count += 1;
    }
    return count;
  }

  /** Atomic write: write to temp file, then rename. */
  private async save(data: ArchiveStoreData): Promise<void> {
    const tmp = join(this.dirPath, `archived-sessions.${randomUUID()}.tmp`);
    try {
      await writeFile(tmp, JSON.stringify(data, null, 2), "utf-8");
      await rename(tmp, this.filePath);
    } catch (error) {
      await unlink(tmp).catch(() => undefined);
      throw error;
    }
  }
}

const MAX_ARCHIVED_SESSIONS = 10_000;
const MAX_SESSION_ID_LENGTH = 256;
const MAX_PROJECT_PATH_LENGTH = 16_384;
const MAX_DISPLAY_TEXT_LENGTH = 16_384;

function parseArchivedSessions(value: unknown[]): ArchivedSession[] {
  if (value.length > MAX_ARCHIVED_SESSIONS) {
    throw new Error("Archive store exceeds the supported entry limit");
  }
  const sessions: ArchivedSession[] = [];
  const seen = new Set<string>();
  for (const [index, raw] of value.entries()) {
    if (!raw || typeof raw !== "object") {
      throw new Error(`Invalid archived session at index ${index}`);
    }
    const entry = raw as Record<string, unknown>;
    const sessionId = boundedString(entry.sessionId, MAX_SESSION_ID_LENGTH);
    const projectPath = boundedString(
      entry.projectPath,
      MAX_PROJECT_PATH_LENGTH,
    );
    const archivedAt = boundedString(entry.archivedAt, 64);
    const provider = entry.provider;
    if (
      !sessionId ||
      !projectPath ||
      !archivedAt ||
      (provider !== "claude" && provider !== "codex")
    ) {
      throw new Error(`Invalid archived session at index ${index}`);
    }
    validateOptionalDisplayMetadata(entry, index);
    const identityKey = archiveIdentityKey(provider, sessionId);
    if (seen.has(identityKey)) {
      throw new Error(`Duplicate archived session at index ${index}`);
    }
    seen.add(identityKey);
    sessions.push({
      sessionId,
      provider,
      projectPath,
      archivedAt,
      ...sanitizeDisplayMetadata(entry),
    });
  }
  return sessions;
}

function validateOptionalDisplayMetadata(
  value: Record<string, unknown>,
  index: number,
): void {
  for (const [key, maxLength] of [
    ["name", 1_024],
    ["summary", MAX_DISPLAY_TEXT_LENGTH],
    ["firstPrompt", MAX_DISPLAY_TEXT_LENGTH],
    ["modified", 64],
  ] as const) {
    const field = value[key];
    if (
      field !== undefined &&
      (typeof field !== "string" || field.length > maxLength)
    ) {
      throw new Error(
        `Invalid archived session ${key} at index ${index}`,
      );
    }
  }
}

function sanitizeDisplayMetadata(
  value: Pick<
    ArchivedSession,
    "name" | "summary" | "firstPrompt" | "modified"
  > | Record<string, unknown>,
): Pick<
  ArchivedSession,
  "name" | "summary" | "firstPrompt" | "modified"
> {
  const name = boundedString(value.name, 1_024);
  const summary = boundedString(value.summary, MAX_DISPLAY_TEXT_LENGTH);
  const firstPrompt = boundedString(value.firstPrompt, MAX_DISPLAY_TEXT_LENGTH);
  const modified = boundedString(value.modified, 64);
  return {
    ...(name ? { name } : {}),
    ...(summary ? { summary } : {}),
    ...(firstPrompt ? { firstPrompt } : {}),
    ...(modified ? { modified } : {}),
  };
}

function boundedString(value: unknown, maxLength: number): string | undefined {
  return typeof value === "string" && value.length > 0 && value.length <= maxLength
    ? value
    : undefined;
}
