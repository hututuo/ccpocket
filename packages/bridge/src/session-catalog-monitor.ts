import { watch, type Dirent, type FSWatcher } from "node:fs";
import { readdir } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, join } from "node:path";
import { resolveCodexHome } from "./codex-home.js";

type CatalogRootKind = "claudeProjects" | "codexRoot" | "codexSessions";

interface CatalogRoot {
  path: string;
  kind: CatalogRootKind;
  maxDepth: number;
}

export interface SessionCatalogChange {
  revision: number;
  provider?: "claude" | "codex";
  providerSessionId?: string;
}

export interface SessionCatalogMonitorOptions {
  onChanged: (revision: number, change?: SessionCatalogChange) => void;
  debounceMs?: number;
  minIntervalMs?: number;
  retryMs?: number;
  maxWatchedDirectories?: number;
  roots?: CatalogRoot[];
  /**
   * Test seam for the process-epoch revision seed.
   *
   * Production revisions start from the current epoch time instead of zero so
   * a Bridge restart cannot accidentally reuse a complete mobile cache whose
   * in-memory counter happened to reach the same value in an earlier process.
   */
  initialRevision?: number;
}

interface WatchedDirectory {
  watcher: FSWatcher;
  root: CatalogRoot;
  depth: number;
}

interface RootScanState {
  root: CatalogRoot;
  queue: Array<{ path: string; depth: number }>;
  directories: Array<{ path: string; depth: number }>;
  complete: boolean;
}

const DEFAULT_DEBOUNCE_MS = 750;
const DEFAULT_MIN_INTERVAL_MS = 2_500;
const DEFAULT_RETRY_MS = 15_000;
const DEFAULT_MAX_WATCHED_DIRECTORIES = 1_024;

function defaultRoots(): CatalogRoot[] {
  const home = homedir();
  const codexHome = resolveCodexHome({ homeDir: home });
  return [
    {
      path: join(home, ".claude", "projects"),
      kind: "claudeProjects",
      maxDepth: 1,
    },
    {
      path: codexHome,
      kind: "codexRoot",
      maxDepth: 0,
    },
    {
      path: join(codexHome, "sessions"),
      kind: "codexSessions",
      maxDepth: 4,
    },
  ];
}

function boundedPositiveInteger(
  value: number | undefined,
  fallback: number,
): number {
  return typeof value === "number" && Number.isFinite(value) && value >= 0
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
  private readonly onChanged: (
    revision: number,
    change?: SessionCatalogChange,
  ) => void;
  private readonly debounceMs: number;
  private readonly minIntervalMs: number;
  private readonly retryMs: number;
  private readonly maxWatchedDirectories: number;
  private readonly roots: CatalogRoot[];
  private readonly watchedDirectories = new Map<string, WatchedDirectory>();

  private active = false;
  private generation = 0;
  private revision: number;
  private lastChangedAt = 0;
  private changeTimer: NodeJS.Timeout | null = null;
  private rescanTimer: NodeJS.Timeout | null = null;
  private scanPromise: Promise<void> | null = null;
  private scanRequested = false;
  private pendingConversationKeys = new Set<string>();
  private pendingUnscopedChange = false;

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
    this.roots = options.roots ?? defaultRoots();
    this.maxWatchedDirectories = Math.max(
      1,
      this.roots.length,
      boundedPositiveInteger(
        options.maxWatchedDirectories,
        DEFAULT_MAX_WATCHED_DIRECTORIES,
      ),
    );
    this.revision = normalizeRevisionSeed(options.initialRevision);
  }

  get isActive(): boolean {
    return this.active;
  }

  get currentRevision(): number {
    return this.revision;
  }

  get watcherCount(): number {
    return this.watchedDirectories.size;
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
    this.scanRequested = false;
    this.pendingConversationKeys.clear();
    this.pendingUnscopedChange = false;
    const watchedDirectories = [...this.watchedDirectories.values()];
    this.watchedDirectories.clear();
    for (const entry of watchedDirectories) {
      entry.watcher.close();
    }
    this.scanPromise = null;
  }

  private scan(): Promise<void> {
    if (!this.active) return Promise.resolve();
    if (this.scanPromise) {
      this.scanRequested = true;
      return this.scanPromise;
    }
    const generation = this.generation;
    const scan = (async () => {
      do {
        this.scanRequested = false;
        await this.installMissingWatchers(generation);
      } while (
        this.active &&
        generation === this.generation &&
        this.scanRequested
      );
    })().finally(() => {
      if (this.scanPromise === scan) this.scanPromise = null;
    });
    this.scanPromise = scan;
    return scan;
  }

  private async installMissingWatchers(generation: number): Promise<void> {
    let missingRoot = false;
    const discoveredDirectories = new Set<string>();
    const scans: RootScanState[] = this.roots.map((root) => ({
      root,
      queue: [],
      directories: [],
      complete: true,
    }));

    // Install every provider root before spending capacity on descendants.
    // Missing roots retain their slot so a late-created Codex directory cannot
    // be permanently displaced by an already-large Claude project tree.
    for (const scan of scans) {
      if (!this.active || generation !== this.generation) return;
      const installed = this.watchDirectory(scan.root.path, scan.root, 0);
      if (!installed) {
        missingRoot = true;
      }
      if (scan.root.maxDepth === 0) continue;
      try {
        const children = await readdir(scan.root.path, { withFileTypes: true });
        if (!this.active || generation !== this.generation) return;
        this.enqueueChildDirectories(scan, scan.root.path, 0, children);
      } catch {
        scan.complete = false;
        missingRoot = true;
      }
    }

    // Discover the complete reachable tree independently of watcher capacity.
    // Otherwise a stale watcher can keep the map full and prevent the scan
    // from ever reaching the replacement directory that should take its slot.
    while (scans.some((scan) => scan.queue.length > 0)) {
      for (const scan of scans) {
        if (!this.active || generation !== this.generation) return;
        const current = scan.queue.shift();
        if (!current) continue;

        discoveredDirectories.add(current.path);
        scan.directories.push(current);
        if (current.depth >= scan.root.maxDepth) continue;

        try {
          const children = await readdir(current.path, {
            withFileTypes: true,
          });
          if (!this.active || generation !== this.generation) return;
          this.enqueueChildDirectories(
            scan,
            current.path,
            current.depth,
            children,
          );
        } catch {
          scan.complete = false;
          continue;
        }
      }
    }

    if (!this.active || generation !== this.generation) return;
    this.removeUndiscoveredWatchers(
      discoveredDirectories,
      new Set(scans.filter((scan) => scan.complete).map((scan) => scan.root)),
    );

    const reservedRootSlots = scans.reduce(
      (count, scan) =>
        this.watchedDirectories.has(scan.root.path) ? count : count + 1,
      0,
    );
    const descendantLimit = this.maxWatchedDirectories - reservedRootSlots;

    // Consume one descendant from every provider root per round. The previous
    // root-at-a-time walk let one provider exhaust the global watcher budget
    // before later roots were considered; rescanning repeated the starvation.
    while (
      scans.some((scan) => scan.directories.length > 0) &&
      this.watchedDirectories.size < descendantLimit
    ) {
      for (const scan of scans) {
        if (!this.active || generation !== this.generation) return;
        if (this.watchedDirectories.size >= descendantLimit) break;
        const current = scan.directories.shift();
        if (!current) continue;
        this.watchDirectory(current.path, scan.root, current.depth);
      }
    }
    if (missingRoot || scans.some((scan) => !scan.complete)) {
      this.scheduleRescan(this.retryMs);
    }
  }

  private removeUndiscoveredWatchers(
    discoveredDirectories: ReadonlySet<string>,
    completelyScannedRoots: ReadonlySet<CatalogRoot>,
  ): void {
    for (const [directory, entry] of this.watchedDirectories) {
      if (
        entry.depth === 0 ||
        !completelyScannedRoots.has(entry.root) ||
        discoveredDirectories.has(directory)
      ) {
        continue;
      }
      this.watchedDirectories.delete(directory);
      entry.watcher.close();
    }
  }

  private enqueueChildDirectories(
    scan: RootScanState,
    parent: string,
    depth: number,
    children: Dirent[],
  ): void {
    for (const child of children) {
      if (!child.isDirectory() || child.name.startsWith(".")) continue;
      scan.queue.push({
        path: join(parent, child.name),
        depth: depth + 1,
      });
    }
  }

  private watchDirectory(
    directory: string,
    root: CatalogRoot,
    depth: number,
  ): boolean {
    if (this.watchedDirectories.has(directory)) return true;
    try {
      let entry: WatchedDirectory | null = null;
      const watcher = watch(
        directory,
        { persistent: false },
        (eventType, filename) => {
          if (
            !this.active ||
            this.watchedDirectories.get(directory) !== entry
          ) {
            return;
          }
          const name = filename?.toString();
          if (this.isRelevant(root, depth, eventType, name)) {
            const change = this.conversationChange(root, name);
            if (
              change ||
              eventType === "rename" ||
              depth >= root.maxDepth ||
              root.kind === "codexRoot"
            ) {
              this.scheduleChanged(change);
            }
          }
          if (eventType === "rename") this.scheduleRescan();
        },
      );
      entry = { watcher, root, depth };
      this.watchedDirectories.set(directory, entry);
      watcher.on("error", () => {
        const current = this.watchedDirectories.get(directory);
        if (current !== entry) return;
        this.watchedDirectories.delete(directory);
        current.watcher.close();
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
        filename === ".codex-global-state.json" ||
        filename === "ccpocket-session-profiles.json" ||
        filename === "ccpocket-session-additional-writable-roots.json" ||
        (eventType === "rename" && filename === "sessions")
      );
    }
    if (filename.endsWith(".jsonl")) return true;
    if (root.kind === "claudeProjects" && filename === "sessions-index.json") {
      return true;
    }
    return eventType === "rename" && depth < root.maxDepth;
  }

  private conversationChange(
    root: CatalogRoot,
    filename: string | undefined,
  ): Omit<SessionCatalogChange, "revision"> | undefined {
    if (!filename) return undefined;
    const leaf = basename(filename);
    if (!leaf.endsWith(".jsonl")) return undefined;
    const stem = leaf.slice(0, -".jsonl".length);
    if (!stem || stem.length > 512) {
      return undefined;
    }
    if (root.kind === "claudeProjects") {
      return { provider: "claude", providerSessionId: stem };
    }
    if (root.kind !== "codexSessions") return undefined;
    const uuid = stem.match(
      /(?:^|-)([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/i,
    )?.[1];
    return {
      provider: "codex",
      providerSessionId: uuid ?? stem,
    };
  }

  private scheduleChanged(
    change?: Omit<SessionCatalogChange, "revision">,
  ): void {
    if (!this.active) return;
    if (change?.provider && change.providerSessionId) {
      this.pendingConversationKeys.add(
        `${change.provider}\0${change.providerSessionId}`,
      );
    } else {
      this.pendingUnscopedChange = true;
    }
    if (this.changeTimer) return;
    const now = Date.now();
    const earliest = Math.max(
      now + this.debounceMs,
      this.lastChangedAt + this.minIntervalMs,
    );
    this.changeTimer = setTimeout(
      () => {
        this.changeTimer = null;
        if (!this.active) return;
        this.lastChangedAt = Date.now();
        this.revision += 1;
        let change: SessionCatalogChange | undefined;
        if (
          !this.pendingUnscopedChange &&
          this.pendingConversationKeys.size === 1
        ) {
          const [key] = this.pendingConversationKeys;
          const separator = key!.indexOf("\0");
          change = {
            revision: this.revision,
            provider: key!.slice(0, separator) as "claude" | "codex",
            providerSessionId: key!.slice(separator + 1),
          };
        }
        this.pendingConversationKeys.clear();
        this.pendingUnscopedChange = false;
        this.onChanged(this.revision, change ?? { revision: this.revision });
      },
      Math.max(0, earliest - now),
    );
    this.changeTimer.unref?.();
  }

  private scheduleRescan(delayMs = 250): void {
    if (!this.active || this.rescanTimer) return;
    this.rescanTimer = setTimeout(
      () => {
        this.rescanTimer = null;
        void this.scan();
      },
      Math.max(0, delayMs),
    );
    this.rescanTimer.unref?.();
  }
}

function normalizeRevisionSeed(value: number | undefined): number {
  if (typeof value === "number" && Number.isSafeInteger(value) && value >= 0) {
    return value;
  }
  // Equality, not wall-clock meaning, is the cache contract. Date.now() gives
  // every normal Bridge process a fresh, safely representable epoch while
  // remaining monotonic for the existing client-side `revision > previous`
  // invalidation check.
  return Date.now();
}
