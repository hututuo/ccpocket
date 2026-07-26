import { createHash } from "node:crypto";
import type { FileHandle } from "node:fs/promises";
import { realpath } from "node:fs/promises";
import { extname, posix, win32 } from "node:path";
import { MAX_ARTIFACTS_PER_MESSAGE } from "./artifact-types.js";
import { ArtifactHttpError, ArtifactStore } from "./artifact-store.js";
import { ArtifactRegistry } from "./artifact-registry.js";
import type { GeneratedArtifactStore } from "./generated-artifact-store.js";
import type {
  ArtifactCandidate,
  ArtifactFileIdentity,
  ArtifactKind,
  ArtifactRef,
  ArtifactRegistryEntry,
  RegisterArtifactInput,
  ResolveArtifactInput,
  ResolvedArtifact,
} from "./artifact-types.js";

export interface ArtifactManagerOptions {
  store: ArtifactStore;
  registry: ArtifactRegistry;
  generatedArtifactStore?: GeneratedArtifactStore;
  platform?: NodeJS.Platform;
  /**
   * Allow opaque, registry-bound preview refs for regular files outside the
   * current session roots. Production enables this only for an explicitly
   * unrestricted Bridge that also requires API-key authentication.
   */
  allowUnscopedRead?: boolean;
}

export interface RegisterArtifactCandidatesInput {
  /** Stable provider thread/session UUID. */
  ownerId: string;
  messageId: string;
  /** Exact turn cwd (worktree path when applicable) for relative hrefs. */
  cwd: string;
  /** Explicit local roots non-image candidates may expose in addition to cwd. */
  candidateRoots?: string[];
  candidates: ArtifactCandidate[];
}

export interface MaterializeGeneratedCandidatesInput {
  ownerId: string;
  messageId: string;
  cwd: string;
  candidates: ArtifactCandidate[];
}

export interface OpenAuthorizedSourceInput {
  artifactId: string;
  ownerId: string;
  messageId: string;
  candidateRoots: string[];
  cwd: string;
  projectRelativePath: string;
}

export interface OpenedArtifactSource {
  /** Caller owns this verified handle and must close it. */
  handle: FileHandle;
  filename: string;
  mimeType: string;
  sizeBytes: number;
  /** Registry-verified identity that reads must match before and after I/O. */
  identity: ArtifactFileIdentity;
  line?: number;
  column?: number;
}

export class ArtifactResolveError extends Error {
  constructor(
    readonly statusCode: number,
    readonly code: string,
    message: string,
  ) {
    super(message);
  }
}

const SOURCE_EXTENSIONS = new Set([
  ".c",
  ".cc",
  ".cs",
  ".csproj",
  ".conf",
  ".cpp",
  ".css",
  ".dart",
  ".env",
  ".ex",
  ".exs",
  ".fish",
  ".fs",
  ".fsx",
  ".go",
  ".gradle",
  ".h",
  ".hpp",
  ".ini",
  ".java",
  ".js",
  ".jsx",
  ".kt",
  ".kts",
  ".log",
  ".lua",
  ".md",
  ".mjs",
  ".php",
  ".plist",
  ".properties",
  ".ps1",
  ".py",
  ".r",
  ".rb",
  ".rs",
  ".scala",
  ".sh",
  ".sln",
  ".sql",
  ".swift",
  ".tex",
  ".toml",
  ".ts",
  ".tsx",
  ".txt",
  ".vue",
  ".xml",
  ".yaml",
  ".yml",
  ".zsh",
]);

const SOURCE_FILENAMES = new Set([
  ".dockerignore",
  ".editorconfig",
  ".gitattributes",
  ".gitignore",
  "cmakelists.txt",
  "dockerfile",
  "gemfile",
  "makefile",
  "rakefile",
]);

function positiveInteger(value: string | undefined): number | undefined {
  if (!value || !/^\d+$/.test(value)) return undefined;
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : undefined;
}

export function splitArtifactLocationSuffix(
  input: string,
): { filePath: string; line: number; column?: number } | undefined {
  const match =
    /^(.*):([0-9]+):([0-9]+)$/.exec(input) ?? /^(.*):([0-9]+)$/.exec(input);
  if (!match || !match[1]) return undefined;
  const line = positiveInteger(match[2]);
  const column = match[3] ? positiveInteger(match[3]) : undefined;
  if (!line || (match[3] && !column)) return undefined;
  return { filePath: match[1], line, column };
}

export function artifactCandidateKey(candidate: ArtifactCandidate): string {
  return createHash("sha256")
    .update(
      JSON.stringify([
        candidate.source,
        candidate.linkKind,
        candidate.localPath,
        candidate.originalHref ?? null,
        candidate.textContentIndex ?? null,
      ]),
    )
    .digest("base64url");
}

function isInsideProject(
  canonicalPath: string,
  canonicalCwd: string,
  platform: NodeJS.Platform,
): string | undefined {
  const pathApi = platform === "win32" ? win32 : posix;
  const relativePath = pathApi.relative(canonicalCwd, canonicalPath);
  if (
    !relativePath ||
    relativePath === ".." ||
    relativePath.startsWith(`..${pathApi.sep}`) ||
    pathApi.isAbsolute(relativePath)
  ) {
    return undefined;
  }
  return platform === "win32" ? relativePath.replace(/\\/g, "/") : relativePath;
}

function isWithinRoot(
  canonicalPath: string,
  canonicalRoot: string,
  platform: NodeJS.Platform,
): boolean {
  const pathApi = platform === "win32" ? win32 : posix;
  const relativePath = pathApi.relative(canonicalRoot, canonicalPath);
  return (
    relativePath === "" ||
    (relativePath !== ".." &&
      !relativePath.startsWith(`..${pathApi.sep}`) &&
      !pathApi.isAbsolute(relativePath))
  );
}

function normalizedProjectRelativePath(
  input: string,
  platform: NodeJS.Platform,
): string | undefined {
  if (!input || input.includes("\0")) return undefined;
  const pathApi = platform === "win32" ? win32 : posix;
  if (pathApi.isAbsolute(input)) return undefined;
  const normalized = pathApi.normalize(input);
  if (
    !normalized ||
    normalized === "." ||
    normalized === ".." ||
    normalized.startsWith(`..${pathApi.sep}`) ||
    pathApi.isAbsolute(normalized)
  ) {
    return undefined;
  }
  return platform === "win32" ? normalized.replace(/\\/g, "/") : normalized;
}

async function canonicalRoots(roots: Iterable<string>): Promise<string[]> {
  const canonical: string[] = [];
  for (const root of new Set(roots)) {
    if (!root.trim()) continue;
    try {
      canonical.push(await realpath(root));
    } catch {
      // Missing roots grant no automatic publication authority.
    }
  }
  return canonical;
}

function requiresSessionScope(source: ArtifactCandidate["source"]): boolean {
  return source !== "image_generation";
}

function sourceKind(
  candidate: ArtifactCandidate,
  projectRelativePath: string | undefined,
  filename: string,
  mimeType: string,
  line: number | undefined,
): ArtifactKind {
  if (
    !projectRelativePath ||
    candidate.source === "image_generation" ||
    candidate.linkKind === "image"
  ) {
    return "preview";
  }
  const normalizedMime = mimeType.toLowerCase();
  const extension = extname(filename).toLowerCase();
  // HTML renders in the sandboxed iframe and JSON pretty-prints on the
  // preview page; kind:"source" would strand both in the File Peek text
  // sheet with the whole preview route unreachable. A line-anchored ref
  // is the exception: only File Peek can scroll to the cited line (the
  // preview page ignores line info and truncates large text), so it
  // stays on the source path.
  if (
    extension === ".html" ||
    extension === ".htm" ||
    extension === ".json" ||
    normalizedMime.startsWith("text/html") ||
    normalizedMime.startsWith("application/json")
  ) {
    return line === undefined ? "preview" : "source";
  }
  const isSource =
    SOURCE_EXTENSIONS.has(extension) ||
    SOURCE_FILENAMES.has(filename.toLowerCase()) ||
    normalizedMime.startsWith("text/") ||
    normalizedMime.startsWith("application/xml") ||
    normalizedMime.startsWith("application/yaml") ||
    normalizedMime.startsWith("application/toml");
  return isSource ? "source" : "preview";
}

function resolveError(error: ArtifactHttpError): ArtifactResolveError {
  const code =
    error.code === "file_not_found" ||
    error.code === "not_regular_file" ||
    error.code === "file_unreadable"
      ? "file_gone"
      : error.code;
  const statusCode = code === "file_gone" ? 410 : error.statusCode;
  return new ArtifactResolveError(
    statusCode,
    code,
    code === "file_changed"
      ? "Artifact file changed"
      : code === "path_not_allowed"
        ? "Artifact is no longer allowed"
        : code === "file_gone" || code === "file_unreadable"
          ? "Artifact is no longer available"
          : "Artifact could not be resolved",
  );
}

export class ArtifactManager {
  private readonly store: ArtifactStore;
  private readonly registry: ArtifactRegistry;
  private readonly generatedArtifactStore?: GeneratedArtifactStore;
  private readonly platform: NodeJS.Platform;
  private readonly allowUnscopedRead: boolean;

  constructor(options: ArtifactManagerOptions) {
    this.store = options.store;
    this.registry = options.registry;
    this.generatedArtifactStore = options.generatedArtifactStore;
    this.platform = options.platform ?? process.platform;
    this.allowUnscopedRead = options.allowUnscopedRead ?? false;
  }

  /**
   * Convert provider-local ImageGeneration paths into trusted managed paths
   * before legacy image/gallery code is allowed to read them.
   */
  async materializeGeneratedCandidates(
    input: MaterializeGeneratedCandidatesInput,
  ): Promise<string[]> {
    if (
      !this.generatedArtifactStore ||
      !input.ownerId.trim() ||
      !input.messageId.trim() ||
      !input.cwd.trim()
    ) {
      return [];
    }

    const paths: string[] = [];
    const seenCandidateKeys = new Set<string>();
    for (const candidate of input.candidates.slice(
      0,
      MAX_ARTIFACTS_PER_MESSAGE,
    )) {
      if (candidate.source !== "image_generation") continue;
      const candidateKey = artifactCandidateKey(candidate);
      if (seenCandidateKeys.has(candidateKey)) continue;
      seenCandidateKeys.add(candidateKey);
      try {
        const persisted = await this.generatedArtifactStore.persist({
          sourcePath: candidate.localPath,
          cwd: input.cwd,
          ownerId: input.ownerId,
          messageId: input.messageId,
          candidateKey,
        });
        if (persisted && !paths.includes(persisted)) paths.push(persisted);
      } catch {
        // One invalid generated path must not drop the provider message.
      }
    }
    return paths;
  }

  async registerCandidates(
    input: RegisterArtifactCandidatesInput,
  ): Promise<ArtifactRef[]> {
    if (!input.ownerId.trim() || !input.messageId.trim() || !input.cwd.trim()) {
      return [];
    }

    let canonicalCwd: string | undefined;
    try {
      canonicalCwd = await realpath(input.cwd);
    } catch {
      // Relative candidates will fail closed in ArtifactStore. Absolute files
      // may still be safely registered, but never as project source refs.
    }
    const canonicalCandidateRoots = await canonicalRoots([
      input.cwd,
      ...(input.candidateRoots ?? []),
    ]);

    const refs: Array<ArtifactRef | undefined> = [];
    const pending: Array<{
      refIndex: number;
      candidate: ArtifactCandidate;
      registration: RegisterArtifactInput;
    }> = [];
    const seenCandidateKeys = new Set<string>();
    for (const candidate of input.candidates.slice(
      0,
      MAX_ARTIFACTS_PER_MESSAGE,
    )) {
      const candidateKey = artifactCandidateKey(candidate);
      if (seenCandidateKeys.has(candidateKey)) continue;
      seenCandidateKeys.add(candidateKey);
      const refIndex = refs.length;
      refs.push(undefined);
      const existing = await this.registry.getCandidate(
        input.ownerId,
        input.messageId,
        candidateKey,
      );
      if (existing) {
        if (
          !this.allowUnscopedRead &&
          requiresSessionScope(candidate.source) &&
          !canonicalCandidateRoots.some((root) =>
            isWithinRoot(existing.canonicalPath, root, this.platform),
          )
        ) {
          continue;
        }
        if (existing.source === "image_generation") {
          await this.generatedArtifactStore?.touch(existing.canonicalPath);
        }
        refs[refIndex] = this.toRef(existing, candidate, canonicalCwd);
        continue;
      }

      let candidatePath = candidate.localPath;
      if (candidate.source === "image_generation") {
        if (!this.generatedArtifactStore) continue;
        const persisted = await this.generatedArtifactStore.persist({
          sourcePath: candidate.localPath,
          cwd: input.cwd,
          ownerId: input.ownerId,
          messageId: input.messageId,
          candidateKey,
        });
        if (!persisted) continue;
        candidatePath = persisted;
      }

      const inspected = await this.inspectCandidate(
        { ...candidate, localPath: candidatePath },
        input.cwd,
      );
      if (!inspected) continue;
      if (
        !this.allowUnscopedRead &&
        requiresSessionScope(candidate.source) &&
        !canonicalCandidateRoots.some((root) =>
          isWithinRoot(inspected.file.canonicalPath, root, this.platform),
        )
      ) {
        continue;
      }

      const projectRelativePath = canonicalCwd
        ? isInsideProject(
            inspected.file.canonicalPath,
            canonicalCwd,
            this.platform,
          )
        : undefined;
      const kind = sourceKind(
        candidate,
        projectRelativePath,
        inspected.file.filename,
        inspected.file.mimeType,
        inspected.line,
      );
      pending.push({
        refIndex,
        candidate,
        registration: {
          candidateKey,
          ownerId: input.ownerId,
          messageId: input.messageId,
          canonicalPath: inspected.file.canonicalPath,
          filename: inspected.file.filename,
          mimeType: inspected.file.mimeType,
          sizeBytes: inspected.file.sizeBytes,
          identity: inspected.file.identity,
          kind,
          source: candidate.source,
          line: inspected.line,
          column: inspected.column,
        },
      });
    }
    const registered = await this.registry.registerMany(
      pending.map((item) => item.registration),
    );
    for (const [index, entry] of registered.entries()) {
      const item = pending[index];
      refs[item.refIndex] = this.toRef(entry, item.candidate, canonicalCwd);
    }
    return refs.filter((ref): ref is ArtifactRef => ref !== undefined);
  }

  private toRef(
    entry: ArtifactRegistryEntry,
    candidate: ArtifactCandidate,
    canonicalCwd: string | undefined,
  ): ArtifactRef {
    const projectRelativePath = canonicalCwd
      ? isInsideProject(entry.canonicalPath, canonicalCwd, this.platform)
      : undefined;
    const kind =
      entry.kind === "source" && projectRelativePath ? "source" : "preview";
    return {
      id: entry.artifactId,
      filename: entry.filename,
      mimeType: entry.mimeType,
      sizeBytes: entry.sizeBytes,
      kind,
      source: entry.source,
      ...(kind === "source" && projectRelativePath
        ? { projectRelativePath }
        : {}),
      ...(candidate.originalHref !== undefined
        ? { originalHref: candidate.originalHref }
        : {}),
      ...(candidate.textContentIndex !== undefined
        ? { textContentIndex: candidate.textContentIndex }
        : {}),
      ...(entry.line !== undefined ? { line: entry.line } : {}),
      ...(entry.column !== undefined ? { column: entry.column } : {}),
    };
  }

  async resolve(input: ResolveArtifactInput): Promise<ResolvedArtifact> {
    const entry = await this.registry.getAuthorized(
      input.artifactId,
      input.ownerId,
      input.messageId,
    );
    if (!entry) {
      throw new ArtifactResolveError(
        404,
        "artifact_not_found",
        "Artifact not found",
      );
    }

    if (!this.allowUnscopedRead && requiresSessionScope(entry.source)) {
      const roots = await canonicalRoots(input.candidateRoots);
      if (
        !roots.some((root) =>
          isWithinRoot(entry.canonicalPath, root, this.platform),
        )
      ) {
        throw new ArtifactResolveError(
          403,
          "path_not_allowed",
          "Artifact is no longer allowed",
        );
      }
    }

    try {
      if (entry.source === "image_generation") {
        await this.generatedArtifactStore?.touch(entry.canonicalPath);
      }
      const issued = await this.store.issue(entry.canonicalPath, {
        filename: entry.filename,
        ttlSeconds: input.ttlSeconds,
        expectedIdentity: entry.identity,
      });
      const touched = await this.registry.touch(
        entry.artifactId,
        entry.ownerId,
        entry.messageId,
      );
      if (!touched) {
        throw new ArtifactResolveError(
          404,
          "artifact_not_found",
          "Artifact not found",
        );
      }
      return {
        artifactId: entry.artifactId,
        relativeUrl: issued.relativeUrl,
        expiresAt: issued.expiresAt,
      };
    } catch (error) {
      if (error instanceof ArtifactResolveError) throw error;
      if (error instanceof ArtifactHttpError) throw resolveError(error);
      throw error;
    }
  }

  /**
   * Open a project source ref by registry identity and return the same verified
   * handle that the caller must read. No absolute path is returned or reopened.
   */
  async openAuthorizedSource(
    input: OpenAuthorizedSourceInput,
  ): Promise<OpenedArtifactSource> {
    const entry = await this.registry.getAuthorized(
      input.artifactId,
      input.ownerId,
      input.messageId,
    );
    if (!entry || entry.kind !== "source") {
      throw new ArtifactResolveError(
        404,
        "artifact_not_found",
        "Artifact not found",
      );
    }

    const roots = await canonicalRoots([input.cwd, ...input.candidateRoots]);
    if (
      !roots.some((root) =>
        isWithinRoot(entry.canonicalPath, root, this.platform),
      )
    ) {
      throw new ArtifactResolveError(
        403,
        "path_not_allowed",
        "Artifact is no longer allowed",
      );
    }

    let canonicalCwd: string;
    try {
      canonicalCwd = await realpath(input.cwd);
    } catch {
      throw new ArtifactResolveError(
        403,
        "path_not_allowed",
        "Artifact is no longer allowed",
      );
    }
    const requestedRelativePath = normalizedProjectRelativePath(
      input.projectRelativePath,
      this.platform,
    );
    const registeredRelativePath = isInsideProject(
      entry.canonicalPath,
      canonicalCwd,
      this.platform,
    );
    if (
      !requestedRelativePath ||
      !registeredRelativePath ||
      requestedRelativePath !== registeredRelativePath
    ) {
      throw new ArtifactResolveError(
        409,
        "source_path_mismatch",
        "Artifact source path does not match",
      );
    }

    let opened: Awaited<ReturnType<ArtifactStore["openVerified"]>>;
    try {
      opened = await this.store.openVerified(requestedRelativePath, {
        projectPath: canonicalCwd,
        expectedIdentity: entry.identity,
      });
    } catch (error) {
      if (error instanceof ArtifactHttpError) throw resolveError(error);
      throw error;
    }

    try {
      if (opened.canonicalPath !== entry.canonicalPath) {
        throw new ArtifactResolveError(
          409,
          "source_path_mismatch",
          "Artifact source path does not match",
        );
      }
      const touched = await this.registry.touch(
        entry.artifactId,
        entry.ownerId,
        entry.messageId,
      );
      if (!touched) {
        throw new ArtifactResolveError(
          404,
          "artifact_not_found",
          "Artifact not found",
        );
      }
      return {
        handle: opened.handle,
        filename: opened.filename,
        mimeType: opened.mimeType,
        sizeBytes: opened.sizeBytes,
        identity: opened.identity,
        ...(entry.line !== undefined ? { line: entry.line } : {}),
        ...(entry.column !== undefined ? { column: entry.column } : {}),
      };
    } catch (error) {
      await opened.handle.close().catch(() => undefined);
      throw error;
    }
  }

  private async inspectCandidate(
    candidate: ArtifactCandidate,
    cwd: string,
  ): Promise<
    | {
        file: Awaited<ReturnType<ArtifactStore["inspect"]>>;
        line?: number;
        column?: number;
      }
    | undefined
  > {
    try {
      return {
        file: await this.store.inspect(candidate.localPath, {
          projectPath: cwd,
        }),
      };
    } catch (error) {
      if (!(error instanceof ArtifactHttpError)) throw error;
      if (error.code !== "file_not_found") return undefined;
    }

    const location = splitArtifactLocationSuffix(candidate.localPath);
    if (!location) return undefined;
    try {
      return {
        file: await this.store.inspect(location.filePath, {
          projectPath: cwd,
        }),
        line: location.line,
        column: location.column,
      };
    } catch (error) {
      if (error instanceof ArtifactHttpError) return undefined;
      throw error;
    }
  }
}
