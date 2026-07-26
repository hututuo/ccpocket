import { watch, type FSWatcher } from "node:fs";
import { readdir } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

type CatalogRootKind = "claudeProjects" | "codexRoot" | "codexSessions";

interface CatalogRoot {
  path: string;
  kind: CatalogRootKind;
  maxDepth: number;
}

export interface SessionCatalogMonitorOptions {
  onChanged: (revision: number) => void;
  debounceMs?: number;
  minIntervalMs?: number;
  retryMs?: number;
  maxWatchedDirectories?: number;
  roots?: CatalogRoot[];
}

interface WatchedDirectory {
  watcher: FSWatcher;
  root: CatalogRoot;
  depth: number;
}

const DEFAULT_DEBOUNCE_MS = 750;
const DEFAULT_MIN_INTERVAL_MS = 2_500;
const DEFAULT_RETRY_MS = 15_000;
const DEFAULT_MAX_WATCHED_DIRECTORIES = 1_024;

function defaultRoots(): CatalogRoot[] {
  const home = homedir();
  return [
    {
      path: join(home, ".claude", "projects"),
      kind: "claudeProjects",
      maxDepth: 1,
    },
    {
      path: join(home, ".codex"),
      kind: "codexRoot",
      maxDepth: 0,
    },
    {
      path: join(home, ".codex", "sessions"),
      kind: "codexSessions",
      maxDepth: 4,
    },
  ];
}

function boundedPositiveInteger(
  value: number | undefined,
  fallback: number,
): number {
  return typeof value === "number" &&
    Number.isFinite(value) &&
    value >= 0
    ? Math.floor(value)
    : fallback;
}

/**
 * Watches only the provider-owned metadata/session directories needed by the
 * recent-session catalog. It intentionally emits a compact invalidation
 * revision instead of reading history or constructing session runtimes.
 *
 * Recursive fs.watch is unavailable on some supported Node 18 platforms, so
 * the monitor installs bounded non-recursive watchers for the shallow Claude
 * and Codex directory trees. Directory renames trigger a bounded re-scan.
 */
export class SessionCatalogMonitor {
  private readonly onChanged: (revision: number) => void;
  private readonly debounceMs: number;
  private readonly minIntervalMs: number;
  private readonly retryMs: number;
  private readonly maxWatchedDirectories: number;
  private readonly roots: CatalogRoot[];
  private readonly watchedDirectories = new Map<string, WatchedDirectory>();

  private active = false;
  private generation = 0;
  private revision = 0;
  private lastChangedAt = 0;
  private changeTimer: NodeJS.Timeout | null = null;
  private rescanTimer: NodeJS.Timeout | null = null;
  private scanPromise: Promise<void> | null = null;

  constructor(options: SessionCatalogMonitorOptions) {
    this.onChanged = options.onChanged;
    this.debounceMs = boundedPositiveInteger(
      options.debounceMs,
      DEFAULT_DEBOUNCE_MS,
    );
    this.minIntervalMs = boundedPositiveInteger(
      options.minIntervalMs,
      DEFAULT_MIN_INTERVAL_MS,
    );
    this.retryMs = boundedPositiveInteger(options.retryMs, DEFAULT_RETRY_MS);
    this.maxWatchedDirectories = Math.max(
      1,
      boundedPositiveInteger(
        options.maxWatchedDirectories,
        DEFAULT_MAX_WATCHED_DIRECTORIES,
      ),
    );
    this.roots = options.roots ?? defaultRoots();
  }

  get isActive(): boolean {
    return this.active;
  }

  get currentRevision(): number {
    return this.revision;
  }

  start(): Promise<void> {
    if (this.active) return this.scanPromise ?? Promise.resolve();
    this.active = true;
    this.generation += 1;
    return this.scan();
  }

  close(): void {
    if (!this.active && this.watchedDirectories.size === 0) return;
    this.active = false;
    this.generation += 1;
    if (this.changeTimer) clearTimeout(this.changeTimer);
    if (this.rescanTimer) clearTimeout(this.rescanTimer);
    this.changeTimer = null;
    this.rescanTimer = null;
    for (const entry of this.watchedDirectories.values()) {
      entry.watcher.close();
    }
    this.watchedDirectories.clear();
    this.scanPromise = null;
  }

  private scan(): Promise<void> {
    if (!this.active) return Promise.resolve();
    if (this.scanPromise) return this.scanPromise;
    const generation = this.generation;
    const scan = this.installMissingWatchers(generation).finally(() => {
      if (this.scanPromise === scan) this.scanPromise = null;
    });
    this.scanPromise = scan;
    return scan;
  }

  private async installMissingWatchers(generation: number): Promise<void> {
    let missingRoot = false;
    for (const root of this.roots) {
      if (!this.active || generation !== this.generation) return;
      const installed = await this.installRoot(root, generation);
      missingRoot = missingRoot || !installed;
    }
    if (missingRoot) this.scheduleRescan(this.retryMs);
  }

  private async installRoot(
    root: CatalogRoot,
    generation: number,
  ): Promise<boolean> {
    const queue: Array<{ path: string; depth: number }> = [
      { path: root.path, depth: 0 },
    ];
    let rootInstalled = false;

    while (queue.length > 0) {
      if (!this.active || generation !== this.generation) return rootInstalled;
      if (this.watchedDirectories.size >= this.maxWatchedDirectories) {
        return rootInstalled;
      }

      const current = queue.shift()!;
      const installed = this.watchDirectory(current.path, root, current.depth);
      if (current.depth === 0) rootInstalled = installed;
      if (!installed || current.depth >= root.maxDepth) continue;

      let children;
      try {
        children = await readdir(current.path, { withFileTypes: true });
      } catch {
        if (current.depth === 0) rootInstalled = false;
        continue;
      }
      for (const child of children) {
        if (!child.isDirectory() || child.name.startsWith(".")) continue;
        queue.push({
          path: join(current.path, child.name),
          depth: current.depth + 1,
        });
      }
    }
    return rootInstalled;
  }

  private watchDirectory(
    directory: string,
    root: CatalogRoot,
    depth: number,
  ): boolean {
    if (this.watchedDirectories.has(directory)) return true;
    try {
      const watcher = watch(
        directory,
        { persistent: false },
        (eventType, filename) => {
          if (!this.active) return;
          const name = filename?.toString();
          if (this.isRelevant(root, depth, eventType, name)) {
            this.scheduleChanged();
          }
          if (eventType === "rename") this.scheduleRescan();
        },
      );
      const entry: WatchedDirectory = { watcher, root, depth };
      this.watchedDirectories.set(directory, entry);
      watcher.on("error", () => {
        const current = this.watchedDirectories.get(directory);
        if (current !== entry) return;
        current.watcher.close();
        this.watchedDirectories.delete(directory);
        this.scheduleRescan(this.retryMs);
      });
      return true;
    } catch {
      return false;
    }
  }

  private isRelevant(
    root: CatalogRoot,
    depth: number,
    eventType: string,
    filename: string | undefined,
  ): boolean {
    if (!filename) return true;
    if (root.kind === "codexRoot") {
      return (
        filename === "session_index.jsonl" ||
        filename === "ccpocket-session-profiles.json" ||
        filename === "ccpocket-session-additional-writable-roots.json" ||
        (eventType === "rename" && filename === "sessions")
      );
    }
    if (filename.endsWith(".jsonl")) return true;
    if (
      root.kind === "claudeProjects" &&
      filename === "sessions-index.json"
    ) {
      return true;
    }
    return eventType === "rename" && depth < root.maxDepth;
  }

  private scheduleChanged(): void {
    if (!this.active || this.changeTimer) return;
    const now = Date.now();
    const earliest = Math.max(
      now + this.debounceMs,
      this.lastChangedAt + this.minIntervalMs,
    );
    this.changeTimer = setTimeout(() => {
      this.changeTimer = null;
      if (!this.active) return;
      this.lastChangedAt = Date.now();
      this.revision += 1;
      this.onChanged(this.revision);
    }, Math.max(0, earliest - now));
    this.changeTimer.unref?.();
  }

  private scheduleRescan(delayMs = 250): void {
    if (!this.active || this.rescanTimer) return;
    this.rescanTimer = setTimeout(() => {
      this.rescanTimer = null;
      void this.scan();
    }, Math.max(0, delayMs));
    this.rescanTimer.unref?.();
  }
}
