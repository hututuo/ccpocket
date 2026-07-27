import { createHash, randomUUID } from "node:crypto";
import { mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

export type PromptCommandKind = "none" | "slash" | "skill";

export interface PromptHistoryClientStat {
  useCount: number;
  lastUsedAt: string;
  clientName?: string;
}

export interface PromptHistorySessionStat {
  useCount: number;
  lastUsedAt: string;
}

export interface PromptHistoryEntry {
  id: string;
  text: string;
  projectPath: string;
  totalUseCount: number;
  isFavorite: boolean;
  createdAt: string;
  lastUsedAt: string;
  updatedAt: string;
  favoriteUpdatedAt?: string;
  deletedAt?: string;
  commandKind: PromptCommandKind;
  clientStats: Record<string, PromptHistoryClientStat>;
  sessionStats: Record<string, PromptHistorySessionStat>;
}

export interface PromptHistoryImportEntry {
  id?: string;
  text: string;
  projectPath?: string;
  useCount?: number;
  totalUseCount?: number;
  isFavorite?: boolean;
  createdAt?: string;
  lastUsedAt?: string;
  updatedAt?: string;
  favoriteUpdatedAt?: string;
  deletedAt?: string;
  commandKind?: PromptCommandKind;
  clientStats?: Record<string, PromptHistoryClientStat>;
  sessionStats?: Record<string, PromptHistorySessionStat>;
}

export interface PromptHistoryRecordInput {
  text: string;
  projectPath?: string;
  clientId: string;
  clientName?: string;
  sessionId?: string;
  usedAt?: string;
}

export interface PromptHistoryMutationInput {
  id?: string;
  text?: string;
  projectPath?: string;
  action: "favorite" | "delete" | "restore";
  isFavorite?: boolean;
  updatedAt?: string;
}

interface PromptHistoryStoreData {
  version: 2;
  bridgeInstanceId: string;
  revision: number;
  entries: PromptHistoryEntry[];
}

const DEFAULT_STORE_FILE = join(
  homedir(),
  ".ccpocket",
  "prompt-history-v2.json",
);
const DEFAULT_BRIDGE_PORT = 8765;

export function promptHistoryStoreFileForPort(
  port: number | string | undefined,
  explicitFile?: string,
): string {
  if (explicitFile?.trim()) return explicitFile.trim();
  const parsedPort =
    typeof port === "number" ? port : Number.parseInt(port ?? "", 10);
  if (!Number.isInteger(parsedPort) || parsedPort === DEFAULT_BRIDGE_PORT) {
    return DEFAULT_STORE_FILE;
  }
  return join(homedir(), ".ccpocket", `prompt-history-v2-${parsedPort}.json`);
}

function isoNow(): string {
  return new Date().toISOString();
}

function compareIso(left: string, right: string): number {
  const leftTime = Date.parse(left);
  const rightTime = Date.parse(right);
  if (Number.isFinite(leftTime) && Number.isFinite(rightTime)) {
    return leftTime - rightTime;
  }
  return left.localeCompare(right);
}

function maxIso(left: string | undefined, right: string | undefined): string {
  if (!left) return right ?? isoNow();
  if (!right) return left;
  return compareIso(left, right) >= 0 ? left : right;
}

function minIso(left: string | undefined, right: string | undefined): string {
  if (!left) return right ?? isoNow();
  if (!right) return left;
  return compareIso(left, right) <= 0 ? left : right;
}

function normalizeText(text: string): string {
  return text.trim().replace(/\r\n/g, "\n");
}

function normalizeProjectPath(projectPath: string | undefined): string {
  return (projectPath ?? "").trim();
}

export function promptHistoryId(text: string, projectPath = ""): string {
  const stableKey = `${normalizeProjectPath(projectPath)}\u0000${normalizeText(text)}`;
  const digest = createHash("sha256").update(stableKey).digest("hex");
  return `ph_${digest.slice(0, 24)}`;
}

export function detectPromptCommandKind(text: string): PromptCommandKind {
  const trimmed = text.trimStart();
  if (trimmed.startsWith("$")) return "skill";
  if (trimmed.startsWith("/")) return "slash";

  const commandMatch = /<command-name>\s*(.*?)\s*<\/command-name>/s.exec(text);
  const commandName = commandMatch?.[1]?.trim();
  if (commandName?.startsWith("$")) return "skill";
  if (commandName?.startsWith("/")) return "slash";
  return "none";
}

function cloneEntry(entry: PromptHistoryEntry): PromptHistoryEntry {
  return {
    ...entry,
    clientStats: Object.fromEntries(
      Object.entries(entry.clientStats).map(([id, stat]) => [id, { ...stat }]),
    ),
    sessionStats: Object.fromEntries(
      Object.entries(entry.sessionStats).map(([id, stat]) => [
        id,
        { ...stat },
      ]),
    ),
  };
}

function cloneStoreData(data: PromptHistoryStoreData): PromptHistoryStoreData {
  return {
    ...data,
    entries: data.entries.map(cloneEntry),
  };
}

function listEntries(
  data: PromptHistoryStoreData,
  includeDeleted = false,
): PromptHistoryEntry[] {
  return data.entries
    .filter((entry) => includeDeleted || !entry.deletedAt)
    .map(cloneEntry);
}

export class PromptHistoryStore {
  private data: PromptHistoryStoreData = {
    version: 2,
    bridgeInstanceId: randomUUID(),
    revision: 0,
    entries: [],
  };
  private readonly filePath: string;
  private mutationTail: Promise<void> = Promise.resolve();

  constructor(filePath?: string) {
    this.filePath = filePath ?? DEFAULT_STORE_FILE;
  }

  async init(): Promise<void> {
    await mkdir(dirname(this.filePath), { recursive: true });
    try {
      const raw = await readFile(this.filePath, "utf-8");
      const parsed = JSON.parse(raw) as PromptHistoryStoreData;
      if (parsed.version === 2 && Array.isArray(parsed.entries)) {
        this.data = {
          version: 2,
          bridgeInstanceId:
            typeof parsed.bridgeInstanceId === "string" &&
            parsed.bridgeInstanceId.length > 0
              ? parsed.bridgeInstanceId
              : randomUUID(),
          revision: Number.isInteger(parsed.revision) ? parsed.revision : 0,
          entries: parsed.entries.map((entry) => ({
            ...entry,
            clientStats: entry.clientStats ?? {},
            sessionStats: entry.sessionStats ?? {},
            commandKind: entry.commandKind ?? detectPromptCommandKind(entry.text),
          })),
        };
        if (!parsed.bridgeInstanceId) await this.save();
      }
    } catch {
      this.data = {
        version: 2,
        bridgeInstanceId: randomUUID(),
        revision: 0,
        entries: [],
      };
      await this.save();
    }
  }

  get revision(): number {
    return this.data.revision;
  }

  get bridgeInstanceId(): string {
    return this.data.bridgeInstanceId;
  }

  list(includeDeleted = false): PromptHistoryEntry[] {
    return listEntries(this.data, includeDeleted);
  }

  async record(input: PromptHistoryRecordInput): Promise<PromptHistoryEntry> {
    const text = normalizeText(input.text);
    if (!text) throw new Error("Prompt text is required");
    const projectPath = normalizeProjectPath(input.projectPath);
    const id = promptHistoryId(text, projectPath);
    const usedAt = input.usedAt ?? isoNow();
    return this.runMutation((data) => {
      const existing = this.findMutable(data, id);

      if (existing) {
        existing.totalUseCount += 1;
        existing.lastUsedAt = maxIso(existing.lastUsedAt, usedAt);
        existing.updatedAt = maxIso(existing.updatedAt, usedAt);
        existing.deletedAt = undefined;
        this.incrementClientStat(
          existing,
          input.clientId,
          input.clientName,
          usedAt,
          1,
        );
        if (input.sessionId) {
          this.incrementSessionStat(existing, input.sessionId, usedAt, 1);
        }
        return { changed: true, value: cloneEntry(existing) };
      }

      const entry: PromptHistoryEntry = {
        id,
        text,
        projectPath,
        totalUseCount: 1,
        isFavorite: false,
        createdAt: usedAt,
        lastUsedAt: usedAt,
        updatedAt: usedAt,
        commandKind: detectPromptCommandKind(text),
        clientStats: {},
        sessionStats: {},
      };
      this.incrementClientStat(
        entry,
        input.clientId,
        input.clientName,
        usedAt,
        1,
      );
      if (input.sessionId) {
        this.incrementSessionStat(entry, input.sessionId, usedAt, 1);
      }
      data.entries.push(entry);
      return { changed: true, value: cloneEntry(entry) };
    });
  }

  async mutate(input: PromptHistoryMutationInput): Promise<PromptHistoryEntry | null> {
    const id = input.id ?? (input.text ? promptHistoryId(input.text, input.projectPath ?? "") : undefined);
    if (!id) return null;
    const updatedAt = input.updatedAt ?? isoNow();
    return this.runMutation((data) => {
      const entry = this.findMutable(data, id);
      if (!entry) return { changed: false, value: null };

      switch (input.action) {
        case "favorite":
          entry.isFavorite = input.isFavorite ?? !entry.isFavorite;
          entry.favoriteUpdatedAt = updatedAt;
          entry.updatedAt = maxIso(entry.updatedAt, updatedAt);
          break;
        case "delete":
          entry.deletedAt = updatedAt;
          entry.updatedAt = maxIso(entry.updatedAt, updatedAt);
          break;
        case "restore":
          entry.deletedAt = undefined;
          entry.updatedAt = maxIso(entry.updatedAt, updatedAt);
          break;
      }

      return { changed: true, value: cloneEntry(entry) };
    });
  }

  async importEntries(
    entries: PromptHistoryImportEntry[],
    clientId: string,
    clientName?: string,
  ): Promise<{ imported: number; entries: PromptHistoryEntry[] }> {
    return this.runMutation((data) => {
      data.entries = [];
      let imported = 0;
      for (const raw of entries) {
        const text = normalizeText(raw.text);
        if (!text) continue;
        const projectPath = normalizeProjectPath(raw.projectPath);
        const id = raw.id ?? promptHistoryId(text, projectPath);
        const now = isoNow();
        const useCount = Math.max(1, raw.totalUseCount ?? raw.useCount ?? 1);
        const createdAt = raw.createdAt ?? now;
        const lastUsedAt = raw.lastUsedAt ?? raw.updatedAt ?? now;
        const updatedAt = raw.updatedAt ?? lastUsedAt;
        const incoming: PromptHistoryEntry = {
          id,
          text,
          projectPath,
          totalUseCount: useCount,
          isFavorite: raw.isFavorite ?? false,
          createdAt,
          lastUsedAt,
          updatedAt,
          favoriteUpdatedAt: raw.favoriteUpdatedAt ?? (raw.isFavorite ? updatedAt : undefined),
          deletedAt: raw.deletedAt,
          commandKind: raw.commandKind ?? detectPromptCommandKind(text),
          clientStats: raw.clientStats ?? {},
          sessionStats: raw.sessionStats ?? {},
        };
        this.incrementClientStat(incoming, clientId, clientName, lastUsedAt, useCount);
        this.mergeEntry(data, incoming);
        imported += 1;
      }

      return {
        changed: true,
        value: { imported, entries: listEntries(data) },
      };
    });
  }

  async mergeClientEntries(entries: PromptHistoryImportEntry[]): Promise<void> {
    if (entries.length === 0) return;
    await this.runMutation((data) => {
      for (const raw of entries) {
        const text = normalizeText(raw.text);
        if (!text) continue;
        const projectPath = normalizeProjectPath(raw.projectPath);
        this.mergeEntry(data, {
          id: raw.id ?? promptHistoryId(text, projectPath),
          text,
          projectPath,
          totalUseCount: Math.max(1, raw.totalUseCount ?? raw.useCount ?? 1),
          isFavorite: raw.isFavorite ?? false,
          createdAt: raw.createdAt ?? isoNow(),
          lastUsedAt: raw.lastUsedAt ?? raw.updatedAt ?? isoNow(),
          updatedAt: raw.updatedAt ?? raw.lastUsedAt ?? isoNow(),
          favoriteUpdatedAt: raw.favoriteUpdatedAt,
          deletedAt: raw.deletedAt,
          commandKind: raw.commandKind ?? detectPromptCommandKind(text),
          clientStats: raw.clientStats ?? {},
          sessionStats: raw.sessionStats ?? {},
        });
      }
      return { changed: true, value: undefined };
    });
  }

  private findMutable(
    data: PromptHistoryStoreData,
    id: string,
  ): PromptHistoryEntry | undefined {
    return data.entries.find((entry) => entry.id === id);
  }

  private incrementClientStat(
    entry: PromptHistoryEntry,
    clientId: string,
    clientName: string | undefined,
    lastUsedAt: string,
    increment: number,
  ): void {
    const current = entry.clientStats[clientId] ?? { useCount: 0, lastUsedAt };
    entry.clientStats[clientId] = {
      useCount: current.useCount + increment,
      lastUsedAt: maxIso(current.lastUsedAt, lastUsedAt),
      clientName: clientName ?? current.clientName,
    };
  }

  private incrementSessionStat(
    entry: PromptHistoryEntry,
    sessionId: string,
    lastUsedAt: string,
    increment: number,
  ): void {
    const current = entry.sessionStats[sessionId] ?? { useCount: 0, lastUsedAt };
    entry.sessionStats[sessionId] = {
      useCount: current.useCount + increment,
      lastUsedAt: maxIso(current.lastUsedAt, lastUsedAt),
    };
  }

  private mergeEntry(
    data: PromptHistoryStoreData,
    incoming: PromptHistoryEntry,
  ): void {
    const existing = this.findMutable(data, incoming.id);
    if (!existing) {
      data.entries.push(cloneEntry(incoming));
      return;
    }

    existing.totalUseCount += incoming.totalUseCount;
    existing.createdAt = minIso(existing.createdAt, incoming.createdAt);
    existing.lastUsedAt = maxIso(existing.lastUsedAt, incoming.lastUsedAt);
    existing.updatedAt = maxIso(existing.updatedAt, incoming.updatedAt);
    existing.commandKind =
      existing.commandKind === "none" ? incoming.commandKind : existing.commandKind;

    if (
      incoming.favoriteUpdatedAt &&
      (!existing.favoriteUpdatedAt ||
        compareIso(incoming.favoriteUpdatedAt, existing.favoriteUpdatedAt) >= 0)
    ) {
      existing.isFavorite = incoming.isFavorite;
      existing.favoriteUpdatedAt = incoming.favoriteUpdatedAt;
    } else if (incoming.isFavorite && !existing.favoriteUpdatedAt) {
      existing.isFavorite = true;
      existing.favoriteUpdatedAt = incoming.updatedAt;
    }

    if (
      incoming.deletedAt &&
      (!existing.deletedAt ||
        compareIso(incoming.deletedAt, existing.deletedAt) >= 0)
    ) {
      existing.deletedAt = incoming.deletedAt;
    }

    for (const [clientId, stat] of Object.entries(incoming.clientStats)) {
      const current = existing.clientStats[clientId];
      existing.clientStats[clientId] = current
        ? {
          useCount: current.useCount + stat.useCount,
          lastUsedAt: maxIso(current.lastUsedAt, stat.lastUsedAt),
          clientName: stat.clientName ?? current.clientName,
        }
        : { ...stat };
    }

    for (const [sessionId, stat] of Object.entries(incoming.sessionStats)) {
      const current = existing.sessionStats[sessionId];
      existing.sessionStats[sessionId] = current
        ? {
          useCount: current.useCount + stat.useCount,
          lastUsedAt: maxIso(current.lastUsedAt, stat.lastUsedAt),
        }
        : { ...stat };
    }
  }

  private async runMutation<T>(
    operation: (data: PromptHistoryStoreData) => {
      changed: boolean;
      value: T;
    },
  ): Promise<T> {
    const previous = this.mutationTail;
    let release!: () => void;
    this.mutationTail = new Promise<void>((resolve) => {
      release = resolve;
    });
    await previous;
    try {
      const next = cloneStoreData(this.data);
      const result = operation(next);
      if (!result.changed) return result.value;
      next.revision += 1;
      await this.save(next);
      this.data = next;
      return result.value;
    } finally {
      release();
    }
  }

  private async save(data: PromptHistoryStoreData = this.data): Promise<void> {
    await mkdir(dirname(this.filePath), { recursive: true });
    const tmp = `${this.filePath}.${randomUUID()}.tmp`;
    try {
      await writeFile(tmp, JSON.stringify(data, null, 2), "utf-8");
      await rename(tmp, this.filePath);
    } catch (error) {
      await rm(tmp, { force: true }).catch(() => undefined);
      throw error;
    }
  }
}
