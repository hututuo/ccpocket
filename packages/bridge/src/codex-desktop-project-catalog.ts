import { open, stat } from "node:fs/promises";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";

import { resolveCodexHome } from "./codex-home.js";

const GLOBAL_STATE_FILENAME = ".codex-global-state.json";
const MAX_GLOBAL_STATE_BYTES = 8 * 1024 * 1024;
const MAX_PROJECTS = 2_048;
const MAX_ASSIGNMENTS = 100_000;
const MAX_PROJECTLESS_THREADS = 100_000;
const MAX_PROJECT_ROOTS = 32;
const MAX_PROJECT_ID_LENGTH = 256;
const MAX_PROJECT_NAME_LENGTH = 512;
const MAX_PROJECT_PATH_LENGTH = 4_096;

export type CodexDesktopProjectGroupKind =
  | "desktopProject"
  | "projectless";

export interface CodexDesktopProjectGrouping {
  projectGroupKind: CodexDesktopProjectGroupKind;
  projectGroupingSnapshotComplete: true;
  projectGroupId?: string;
  projectGroupName?: string;
  projectGroupPath?: string;
}

export interface CodexDesktopProjectCatalog {
  readonly available: boolean;
  matchesProjectName(searchQuery: string): boolean;
  groupingFor(
    threadId: string,
    cwd: string,
  ): CodexDesktopProjectGrouping | undefined;
}

export interface ReadCodexDesktopProjectCatalogOptions {
  codexHome?: string;
}

interface DesktopProject {
  id: string;
  name: string;
  rootPaths: string[];
}

interface ParsedDesktopProjectCatalog {
  projects: Map<string, DesktopProject>;
  assignments: Map<string, string>;
  projectlessThreadIds: Set<string>;
}

interface CachedDesktopProjectCatalog {
  fingerprint: string;
  catalog: CodexDesktopProjectCatalog;
}

const unavailableCatalog: CodexDesktopProjectCatalog = Object.freeze({
  available: false,
  matchesProjectName: () => false,
  groupingFor: () => undefined,
});
const catalogCache = new Map<string, CachedDesktopProjectCatalog>();
const catalogFlights = new Map<string, Promise<CodexDesktopProjectCatalog>>();

class DesktopProjectCatalog implements CodexDesktopProjectCatalog {
  readonly available = true;
  private readonly projectsByRoot = new Map<string, DesktopProject>();

  constructor(private readonly parsed: ParsedDesktopProjectCatalog) {
    for (const project of parsed.projects.values()) {
      for (const rootPath of project.rootPaths) {
        const key = pathKey(rootPath);
        if (!this.projectsByRoot.has(key)) {
          this.projectsByRoot.set(key, project);
        }
      }
    }
  }

  matchesProjectName(searchQuery: string): boolean {
    const query = searchQuery.trim().toLocaleLowerCase();
    return (
      query.length > 0 &&
      [...this.parsed.projects.values()].some((project) =>
        project.name.toLocaleLowerCase().includes(query),
      )
    );
  }

  groupingFor(
    threadId: string,
    cwd: string,
  ): CodexDesktopProjectGrouping {
    const assignedProjectId = this.parsed.assignments.get(threadId);
    const assignedProject = assignedProjectId
      ? this.parsed.projects.get(assignedProjectId)
      : undefined;
    if (assignedProject) {
      return projectGrouping(assignedProject, cwd);
    }
    if (this.parsed.projectlessThreadIds.has(threadId)) {
      return projectlessGrouping();
    }
    const normalizedCwd = absolutePath(cwd);
    if (normalizedCwd) {
      const matchedProject = this.projectForPath(normalizedCwd);
      if (matchedProject) {
        return projectGrouping(matchedProject, normalizedCwd);
      }
    }
    // Desktop keeps unassigned local threads outside its project sections.
    // Mobile still needs one stable bucket so those chats remain reachable
    // without turning every temporary cwd into a fake project.
    return projectlessGrouping();
  }

  private projectForPath(candidate: string): DesktopProject | undefined {
    let current = candidate;
    while (true) {
      const project = this.projectsByRoot.get(pathKey(current));
      if (project) return project;
      const parent = dirname(current);
      if (parent === current) return undefined;
      current = parent;
    }
  }
}

export async function readCodexDesktopProjectCatalog(
  options: ReadCodexDesktopProjectCatalogOptions = {},
): Promise<CodexDesktopProjectCatalog> {
  const codexHome = options.codexHome
    ? resolve(options.codexHome)
    : resolveCodexHome();
  const statePath = join(codexHome, GLOBAL_STATE_FILENAME);
  let fileStat: Awaited<ReturnType<typeof stat>>;
  try {
    fileStat = await stat(statePath);
  } catch {
    return unavailableCatalog;
  }
  if (!fileStat.isFile() || fileStat.size > MAX_GLOBAL_STATE_BYTES) {
    return catalogCache.get(statePath)?.catalog ?? unavailableCatalog;
  }
  const fingerprint = stateFingerprint(fileStat);
  const cached = catalogCache.get(statePath);
  if (cached?.fingerprint === fingerprint) return cached.catalog;
  const existingFlight = catalogFlights.get(statePath);
  if (existingFlight) return existingFlight;

  const flight = readBoundedStateFile(statePath, fileStat.size)
    .then(async (raw) => {
      if (raw === null) return cached?.catalog ?? unavailableCatalog;
      const verifiedStat = await stat(statePath);
      if (stateFingerprint(verifiedStat) !== fingerprint) {
        return cached?.catalog ?? unavailableCatalog;
      }
      const parsed = parseDesktopProjectCatalog(raw);
      if (!parsed) return cached?.catalog ?? unavailableCatalog;
      const catalog = new DesktopProjectCatalog(parsed);
      catalogCache.set(statePath, { fingerprint, catalog });
      return catalog;
    })
    .catch(() => cached?.catalog ?? unavailableCatalog)
    .finally(() => {
      if (catalogFlights.get(statePath) === flight) {
        catalogFlights.delete(statePath);
      }
    });
  catalogFlights.set(statePath, flight);
  return flight;
}

async function readBoundedStateFile(
  path: string,
  expectedSize: number,
): Promise<string | null> {
  const handle = await open(path, "r");
  try {
    const buffer = Buffer.allocUnsafe(
      Math.min(MAX_GLOBAL_STATE_BYTES + 1, Math.max(1, expectedSize + 1)),
    );
    let offset = 0;
    while (offset < buffer.length) {
      const { bytesRead } = await handle.read(
        buffer,
        offset,
        buffer.length - offset,
        null,
      );
      if (bytesRead === 0) break;
      offset += bytesRead;
    }
    if (offset > MAX_GLOBAL_STATE_BYTES) return null;
    return buffer.toString("utf8", 0, offset);
  } finally {
    await handle.close();
  }
}

function stateFingerprint(fileStat: {
  size: number;
  mtimeMs: number;
  ctimeMs: number;
}): string {
  return `${fileStat.size}:${fileStat.mtimeMs}:${fileStat.ctimeMs}`;
}

function parseDesktopProjectCatalog(
  raw: string,
): ParsedDesktopProjectCatalog | null {
  const decoded = JSON.parse(raw) as unknown;
  const state = objectRecord(decoded);
  if (!state) return null;
  const hasProjects = hasOwn(state, "local-projects");
  const hasAssignments = hasOwn(state, "thread-project-assignments");
  const hasProjectless = hasOwn(state, "projectless-thread-ids");
  if (!hasProjects && !hasAssignments && !hasProjectless) {
    return null;
  }
  const rawProjects = hasProjects
    ? objectRecord(state["local-projects"])
    : {};
  const rawAssignments = hasAssignments
    ? objectRecord(state["thread-project-assignments"])
    : {};
  const rawProjectless = hasProjectless
    ? state["projectless-thread-ids"]
    : [];
  if (
    !rawProjects ||
    !rawAssignments ||
    !Array.isArray(rawProjectless)
  ) {
    return null;
  }

  const projectEntries = Object.entries(rawProjects);
  const assignmentEntries = Object.entries(rawAssignments);
  if (
    projectEntries.length > MAX_PROJECTS ||
    assignmentEntries.length > MAX_ASSIGNMENTS ||
    rawProjectless.length > MAX_PROJECTLESS_THREADS
  ) {
    return null;
  }

  const projects = new Map<string, DesktopProject>();
  for (const [fallbackId, rawProject] of projectEntries) {
    const project = objectRecord(rawProject);
    if (!project) return null;
    const id = boundedString(
      hasOwn(project, "id") ? project.id : fallbackId,
      MAX_PROJECT_ID_LENGTH,
    );
    const name = boundedString(project.name, MAX_PROJECT_NAME_LENGTH);
    if (
      !id ||
      !name ||
      !Array.isArray(project.rootPaths) ||
      project.rootPaths.length === 0 ||
      project.rootPaths.length > MAX_PROJECT_ROOTS ||
      projects.has(id)
    ) {
      return null;
    }
    const rootPaths: string[] = [];
    for (const value of project.rootPaths) {
      const rootPath = absolutePath(value);
      if (!rootPath) return null;
      rootPaths.push(rootPath);
    }
    projects.set(id, { id, name, rootPaths });
  }

  const assignments = new Map<string, string>();
  for (const [threadId, rawAssignment] of assignmentEntries) {
    const assignment = objectRecord(rawAssignment);
    const boundedThreadId = boundedString(threadId, MAX_PROJECT_ID_LENGTH);
    const projectId = boundedString(
      assignment?.projectId,
      MAX_PROJECT_ID_LENGTH,
    );
    const projectKind = assignment?.projectKind;
    if (
      !assignment ||
      !boundedThreadId ||
      !projectId ||
      !projects.has(projectId) ||
      (projectKind !== undefined && projectKind !== "local")
    ) {
      return null;
    }
    assignments.set(boundedThreadId, projectId);
  }

  const projectlessThreadIds = new Set<string>();
  for (const rawThreadId of rawProjectless) {
    const threadId = boundedString(rawThreadId, MAX_PROJECT_ID_LENGTH);
    if (!threadId || assignments.has(threadId)) return null;
    projectlessThreadIds.add(threadId);
  }
  return { projects, assignments, projectlessThreadIds };
}

function projectGrouping(
  project: DesktopProject,
  cwd: string,
): CodexDesktopProjectGrouping {
  const normalizedCwd = absolutePath(cwd);
  const matchingRoot = normalizedCwd
    ? project.rootPaths
        .filter((rootPath) => pathContains(rootPath, normalizedCwd))
        .sort((left, right) => right.length - left.length)[0]
    : undefined;
  return {
    projectGroupKind: "desktopProject",
    projectGroupingSnapshotComplete: true,
    projectGroupId: project.id,
    projectGroupName: project.name,
    projectGroupPath: matchingRoot ?? project.rootPaths[0],
  };
}

function projectlessGrouping(): CodexDesktopProjectGrouping {
  return {
    projectGroupKind: "projectless",
    projectGroupingSnapshotComplete: true,
  };
}

function objectRecord(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function hasOwn(record: Record<string, unknown>, key: string): boolean {
  return Object.prototype.hasOwnProperty.call(record, key);
}

function boundedString(value: unknown, maximumLength: number): string | undefined {
  if (typeof value !== "string") return undefined;
  const normalized = value.trim();
  return normalized && normalized.length <= maximumLength
    ? normalized
    : undefined;
}

function absolutePath(value: unknown): string | undefined {
  const bounded = boundedString(value, MAX_PROJECT_PATH_LENGTH);
  return bounded && isAbsolute(bounded) ? resolve(bounded) : undefined;
}

function pathContains(rootPath: string, candidate: string): boolean {
  const child = relative(rootPath, candidate);
  return child === "" || (!child.startsWith("..") && !isAbsolute(child));
}

function pathKey(path: string): string {
  return process.platform === "win32" ? path.toLocaleLowerCase() : path;
}
