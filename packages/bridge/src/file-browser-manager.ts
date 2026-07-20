import { createHash, randomBytes } from "node:crypto";
import { realpath } from "node:fs/promises";
import { homedir } from "node:os";
import {
  basename,
  isAbsolute,
  join,
  parse,
  relative,
  resolve,
  sep,
} from "node:path";
import {
  mimeTypeForFilename,
  previewKindForFile,
} from "./artifact-preview.js";
import type { ArtifactStore, IssuedArtifact } from "./artifact-store.js";
import type { ArtifactFileIdentity } from "./artifact-types.js";
import { FILE_TRANSFER_MAX_FILE_SIZE_BYTES } from "./file-transfer-constants.js";
import type { FileTransferManager } from "./file-transfer-manager.js";
import type { TransferFileIdentity } from "./file-transfer-state-store.js";
import {
  FileBrowserBackendError,
  FileBrowserPosixBackend,
  type FileBrowserNativeListResult,
  type FileBrowserNativeStatResult,
  type FileBrowserNativeStatSpec,
  type FileBrowserNativeStats,
  type FileBrowserRootIdentity,
} from "./file-browser-posix-backend.js";
import {
  FILE_BROWSER_DEFAULT_PAGE_SIZE,
  FILE_BROWSER_MAX_PAGE_SIZE,
  FILE_BROWSER_MAX_ROOTS,
  FILE_BROWSER_MAX_STAT_ITEMS,
  validFileBrowserRelativePath,
  type FileBrowserClientMessage,
  type FileBrowserEntry,
  type FileBrowserNodeKind,
  type FileBrowserRoot,
  type FileBrowserServerMessage,
  type FileBrowserStatResultItem,
} from "./local-features/slots/file-browser-protocol.js";

const ROOTS_REQUEST = "file_browser_roots_v1";
const LIST_REQUEST = "file_browser_list_v1";
const STAT_REQUEST = "file_browser_stat_v1";
const PREVIEW_REQUEST = "file_browser_preview_v1";
const DOWNLOAD_REQUEST = "file_browser_download_v1";

const MAX_CONCURRENT_OPERATIONS = 2;
const MAX_GLOBAL_CONCURRENT_OPERATIONS = 4;
const DEFAULT_CURSOR_TTL_MS = 2 * 60 * 1000;
const MAX_CURSORS_PER_CLIENT = 8;
const PREVIEW_TTL_SECONDS = 10 * 60;
export const FILE_BROWSER_PREVIEW_MAX_BYTES = 2 * 1024 * 1024 * 1024;
export const FILE_BROWSER_DOWNLOAD_MAX_BYTES =
  FILE_TRANSFER_MAX_FILE_SIZE_BYTES;

export interface FileBrowserClientBinding {
  isOpen(): boolean;
  send(message: FileBrowserServerMessage): boolean;
}

interface ArtifactIssuer {
  issue: ArtifactStore["issue"];
}

export type TargetedFileOfferer = Pick<FileTransferManager, "offerFileToClient">;

export interface FileBrowserManagerOptions {
  bridgeInstanceId: string;
  allowedDirs?: string[];
  artifactStore?: ArtifactIssuer;
  fileTransferManager?: TargetedFileOfferer;
  homeDir?: string;
  now?: () => number;
  cursorTtlMs?: number;
  rootIdFactory?: (canonicalPath: string) => string;
  cursorTokenFactory?: () => string;
  backend?: FileBrowserPosixBackend;
  helperPath?: string;
  maxDirectoryEntries?: number;
  maxDirectoryNameBytes?: number;
}

interface BrowserRoot extends FileBrowserRoot {
  canonicalPath: string;
  identity: FileBrowserRootIdentity;
}

interface RootSnapshot {
  roots: BrowserRoot[];
  byId: Map<string, BrowserRoot>;
  revision: string;
}

interface ResolvedNode {
  root: BrowserRoot;
  relativePath: string;
  lexicalPath: string;
  canonicalPath?: string;
  canonicalRelativePath?: string;
  sourceStats: FileBrowserNativeStats;
  targetStats?: FileBrowserNativeStats;
  blockedSymlink: boolean;
}

interface PreparedNode {
  relativePath: string;
  lexicalPath: string;
  canonicalPath?: string;
  canonicalRelativePath?: string;
  spec: FileBrowserNativeStatSpec;
}

interface CursorState {
  client: object;
  clientGeneration: number;
  rootId: string;
  relativePath: string;
  pageSize: number;
  showHidden: boolean;
  nextIndex: number;
  directoryRevision: string;
  createdAt: number;
  expiresAt: number;
}

class FileBrowserError extends Error {
  constructor(
    readonly code: string,
    message: string,
  ) {
    super(message);
  }
}

/**
 * Read-only, root-scoped file browsing authority.
 *
 * The manager never serializes an absolute path. Every operation resolves the
 * opaque root again, validates the root-relative path, and canonicalizes the
 * target before issuing a preview or transfer capability.
 */
export class FileBrowserManager {
  private readonly bridgeInstanceId: string;
  private readonly artifactStore?: ArtifactIssuer;
  private readonly fileTransferManager?: TargetedFileOfferer;
  private readonly homeDir: string;
  private readonly now: () => number;
  private readonly cursorTtlMs: number;
  private readonly rootIdFactory: (canonicalPath: string) => string;
  private readonly cursorTokenFactory: () => string;
  private readonly backend: FileBrowserPosixBackend;
  private readonly rootsPromise: Promise<RootSnapshot>;
  private readonly clients = new Map<object, FileBrowserClientBinding>();
  private readonly clientGenerations = new WeakMap<object, number>();
  private nextClientGeneration = 1;
  private readonly activeByClient = new Map<object, number>();
  private activeGlobal = 0;
  private readonly operationControllers = new Map<
    object,
    Set<AbortController>
  >();
  private readonly activeOperations = new Set<Promise<void>>();
  private readonly cursors = new Map<string, CursorState>();
  private accepting = true;
  private closeBarrier?: Promise<void>;

  constructor(options: FileBrowserManagerOptions) {
    this.bridgeInstanceId = options.bridgeInstanceId;
    this.artifactStore = options.artifactStore;
    this.fileTransferManager = options.fileTransferManager;
    this.homeDir = resolve(options.homeDir ?? homedir());
    this.now = options.now ?? Date.now;
    this.cursorTtlMs = options.cursorTtlMs ?? DEFAULT_CURSOR_TTL_MS;
    this.rootIdFactory =
      options.rootIdFactory ??
      ((canonicalPath) => opaqueDigest("root", canonicalPath).slice(0, 24));
    this.cursorTokenFactory =
      options.cursorTokenFactory ??
      (() => randomBytes(24).toString("base64url"));
    this.backend =
      options.backend ??
      new FileBrowserPosixBackend({
        helperPath: options.helperPath,
        maxDirectoryEntries: options.maxDirectoryEntries,
        maxDirectoryNameBytes: options.maxDirectoryNameBytes,
      });

    const configuredRoots = options.allowedDirs ?? [];
    const requestedRoots =
      configuredRoots.length > 0 ? configuredRoots : [this.homeDir];
    this.rootsPromise = this.initializeRoots(requestedRoots);
  }

  async init(): Promise<void> {
    await this.rootsPromise;
  }

  connect(client: object, binding: FileBrowserClientBinding): void {
    if (!this.accepting) return;
    this.disconnect(client);
    this.clientGenerations.set(client, this.nextClientGeneration++);
    this.clients.set(client, binding);
  }

  disconnect(client: object): void {
    this.clients.delete(client);
    this.clientGenerations.delete(client);
    const controllers = this.operationControllers.get(client);
    if (controllers) {
      for (const controller of controllers) {
        controller.abort(new Error("File browser client disconnected"));
      }
      this.operationControllers.delete(client);
    }
    for (const [token, cursor] of this.cursors) {
      if (cursor.client === client) this.cursors.delete(token);
    }
  }

  close(): Promise<void> {
    this.closeBarrier ??= this.closeInternal();
    return this.closeBarrier;
  }

  private async closeInternal(): Promise<void> {
    this.accepting = false;
    for (const controllers of this.operationControllers.values()) {
      for (const controller of controllers) {
        controller.abort(new Error("File browser is shutting down"));
      }
    }
    this.operationControllers.clear();
    this.clients.clear();
    this.cursors.clear();
    while (this.activeOperations.size > 0) {
      await Promise.allSettled([...this.activeOperations]);
    }
  }

  handleClientMessage(
    client: object,
    message: FileBrowserClientMessage,
    externalSignal?: AbortSignal,
  ): Promise<void> {
    if (!this.accepting) return Promise.resolve();
    const binding = this.clients.get(client);
    const generation = this.clientGenerations.get(client);
    if (!binding?.isOpen() || generation === undefined) return Promise.resolve();
    const controller = linkedAbortController(externalSignal);
    const controllers = this.operationControllers.get(client) ?? new Set();
    controllers.add(controller);
    this.operationControllers.set(client, controllers);
    let tracked!: Promise<void>;
    tracked = this.handleClientMessageInternal(
      client,
      binding,
      generation,
      message,
      controller.signal,
    ).finally(() => {
      controllers.delete(controller);
      if (
        controllers.size === 0 &&
        this.operationControllers.get(client) === controllers
      ) {
        this.operationControllers.delete(client);
      }
      this.activeOperations.delete(tracked);
      unlinkAbortController(controller);
    });
    this.activeOperations.add(tracked);
    return tracked;
  }

  private async handleClientMessageInternal(
    client: object,
    binding: FileBrowserClientBinding,
    generation: number,
    message: FileBrowserClientMessage,
    signal: AbortSignal,
  ): Promise<void> {
    let response: FileBrowserServerMessage;
    try {
      response = await this.withClientLimit(client, signal, () =>
        this.handleMessage(client, generation, message, signal),
      );
    } catch (error) {
      const browserError = normalizeError(error);
      response = {
        type: resultTypeFor(message.type),
        requestId: message.requestId,
        success: false,
        errorCode: browserError.code,
        error: browserError.message,
      } as FileBrowserServerMessage;
    }

    if (this.operationIsCurrent(client, binding, generation, signal)) {
      binding.send(response);
    }
  }

  private async handleMessage(
    client: object,
    clientGeneration: number,
    message: FileBrowserClientMessage,
    signal: AbortSignal,
  ): Promise<FileBrowserServerMessage> {
    switch (message.type) {
      case ROOTS_REQUEST:
        return this.rootsResult(message.requestId, signal);
      case LIST_REQUEST:
        return this.listResult(client, clientGeneration, message, signal);
      case STAT_REQUEST:
        return this.statResult(message, signal);
      case PREVIEW_REQUEST:
        return this.previewResult(message, signal);
      case DOWNLOAD_REQUEST:
        return this.downloadResult(client, message, signal);
    }
  }

  private async rootsResult(
    requestId: string,
    signal: AbortSignal,
  ): Promise<FileBrowserServerMessage> {
    const snapshot = await this.rootsPromise;
    throwIfAborted(signal);
    const roots: FileBrowserRoot[] = snapshot.roots.map(
      ({ rootId, label, displayPath }) => ({ rootId, label, displayPath }),
    );
    return {
      type: "file_browser_roots_result_v1",
      requestId,
      success: true,
      bridgeInstanceId: this.bridgeInstanceId,
      rootSetRevision: snapshot.revision,
      roots,
      previewMaxBytes: FILE_BROWSER_PREVIEW_MAX_BYTES,
      downloadMaxBytes: FILE_BROWSER_DOWNLOAD_MAX_BYTES,
      downloadAvailable: this.fileTransferManager !== undefined,
    };
  }

  private async listResult(
    client: object,
    clientGeneration: number,
    message: Extract<FileBrowserClientMessage, { type: typeof LIST_REQUEST }>,
    signal: AbortSignal,
  ): Promise<FileBrowserServerMessage> {
    const root = await this.requireRoot(message.rootId);
    const normalizedPath = normalizeRelativePath(message.relativePath);
    let pageSize = normalizePageSize(message.pageSize);
    let showHidden = message.showHidden ?? false;
    let startIndex = 0;
    let expectedDirectoryRevision: string | undefined;

    if (message.cursor !== undefined) {
      const cursor = this.requireCursor(
        message.cursor,
        client,
        clientGeneration,
      );
      if (
        cursor.rootId !== root.rootId ||
        cursor.relativePath !== normalizedPath ||
        (message.showHidden !== undefined && showHidden !== cursor.showHidden)
      ) {
        throw new FileBrowserError(
          "invalid_cursor",
          "The cursor does not match this directory request",
        );
      }
      // The protocol parser normalizes an omitted pageSize to 100. Cursor
      // state remains authoritative so a continuation of an earlier custom
      // page size cannot be accidentally widened by that normalization.
      pageSize = cursor.pageSize;
      showHidden = cursor.showHidden;
      startIndex = cursor.nextIndex;
      expectedDirectoryRevision = cursor.directoryRevision;
      this.cursors.delete(message.cursor);
    }

    const canonicalDirectory = await this.canonicalizeWithinRoot(
      root,
      normalizedPath,
      signal,
    );
    const listed = await this.backend.list(
      root.canonicalPath,
      root.identity,
      canonicalDirectory,
      { pageSize, startIndex, showHidden, signal },
    );
    throwIfAborted(signal);
    const directoryRevision = opaqueDigest(
      "directory",
      root.rootId,
      normalizedPath,
      listed.revision,
    );
    if (
      expectedDirectoryRevision !== undefined &&
      expectedDirectoryRevision !== directoryRevision
    ) {
      throw new FileBrowserError(
        "directory_changed",
        "The directory changed while it was being paged",
      );
    }

    const entries = await this.directoryEntries(
      root,
      normalizedPath,
      canonicalDirectory,
      listed,
      signal,
    );
    this.requireCurrentClient(client, clientGeneration, signal);
    const nextCursor =
      listed.nextIndex !== undefined
        ? this.createCursor({
            client,
            clientGeneration,
            rootId: root.rootId,
            relativePath: normalizedPath,
            pageSize,
            showHidden,
            nextIndex: listed.nextIndex,
            directoryRevision,
          })
        : undefined;

    return {
      type: "file_browser_list_result_v1",
      requestId: message.requestId,
      success: true,
      rootId: root.rootId,
      relativePath: normalizedPath,
      directoryRevision,
      entries,
      ...(nextCursor === undefined ? {} : { nextCursor }),
    };
  }

  private async statResult(
    message: Extract<FileBrowserClientMessage, { type: typeof STAT_REQUEST }>,
    signal: AbortSignal,
  ): Promise<FileBrowserServerMessage> {
    if (message.items.length > FILE_BROWSER_MAX_STAT_ITEMS) {
      throw new FileBrowserError(
        "too_many_items",
        `At most ${FILE_BROWSER_MAX_STAT_ITEMS} file items can be inspected at once`,
      );
    }

    const items: FileBrowserStatResultItem[] = [];
    for (const item of message.items) {
      let normalizedPath = item.relativePath;
      try {
        const root = await this.requireRoot(item.rootId);
        normalizedPath = normalizeRelativePath(item.relativePath);
        const resolved = await this.resolveNode(
          root,
          normalizedPath,
          true,
          signal,
        );
        items.push({
          rootId: root.rootId,
          relativePath: normalizedPath,
          exists: true,
          node: this.nodeData(resolved),
        });
      } catch (error) {
        if (signal.aborted) throw error;
        const browserError = normalizeError(error);
        items.push({
          rootId: item.rootId,
          relativePath: normalizedPath,
          exists: false,
          errorCode: browserError.code,
        });
      }
    }

    return {
      type: "file_browser_stat_result_v1",
      requestId: message.requestId,
      success: true,
      items,
    };
  }

  private async previewResult(
    message: Extract<FileBrowserClientMessage, { type: typeof PREVIEW_REQUEST }>,
    signal: AbortSignal,
  ): Promise<FileBrowserServerMessage> {
    if (!this.artifactStore) {
      throw new FileBrowserError(
        "preview_unavailable",
        "File preview is not available on this Bridge",
      );
    }
    const root = await this.requireRoot(message.rootId);
    const normalizedPath = normalizeRelativePath(message.relativePath);
    const resolved = await this.requireRegularFile(root, normalizedPath, signal);
    const node = this.nodeData(resolved);
    this.requireExpectedRevision(message.nodeRevision, node.nodeRevision);
    const stats = resolved.targetStats ?? resolved.sourceStats;
    if (stats.size > FILE_BROWSER_PREVIEW_MAX_BYTES) {
      throw new FileBrowserError(
        "preview_too_large",
        "The file exceeds the 2 GiB preview limit",
      );
    }

    const filename = displayNameFor(root, normalizedPath);
    let issued: IssuedArtifact;
    try {
      issued = await this.artifactStore.issue(resolved.canonicalPath!, {
        projectPath: root.canonicalPath,
        expectedIdentity: artifactIdentity(stats),
        filename,
        ttlSeconds: PREVIEW_TTL_SECONDS,
      });
      throwIfAborted(signal);
    } catch (error) {
      throw translateCapabilityError(error, "preview_failed");
    }

    return {
      type: "file_browser_preview_result_v1",
      requestId: message.requestId,
      success: true,
      rootId: root.rootId,
      relativePath: normalizedPath,
      relativeUrl: issued.relativeUrl,
      filename: issued.filename,
      mimeType: issued.mimeType,
      sizeBytes: issued.sizeBytes,
      previewKind: previewKindForFile(issued.filename, issued.mimeType),
      expiresAt: issued.expiresAt,
    };
  }

  private async downloadResult(
    client: object,
    message: Extract<FileBrowserClientMessage, { type: typeof DOWNLOAD_REQUEST }>,
    signal: AbortSignal,
  ): Promise<FileBrowserServerMessage> {
    if (!this.fileTransferManager) {
      throw new FileBrowserError(
        "download_unavailable",
        "File download is not available on this Bridge",
      );
    }
    const root = await this.requireRoot(message.rootId);
    const normalizedPath = normalizeRelativePath(message.relativePath);
    const resolved = await this.requireRegularFile(root, normalizedPath, signal);
    const node = this.nodeData(resolved);
    this.requireExpectedRevision(message.nodeRevision, node.nodeRevision);
    const stats = resolved.targetStats ?? resolved.sourceStats;
    if (stats.size > FILE_BROWSER_DOWNLOAD_MAX_BYTES) {
      throw new FileBrowserError(
        "download_too_large",
        "The file exceeds the 15 GiB download limit",
      );
    }

    let offered: Awaited<
      ReturnType<TargetedFileOfferer["offerFileToClient"]>
    >;
    try {
      offered = await this.fileTransferManager.offerFileToClient(client, {
        filePath: resolved.canonicalPath!,
        projectPath: root.canonicalPath,
        expectedIdentity: transferIdentity(stats),
        canonicalRoot: root.canonicalPath,
        signal,
      });
    } catch (error) {
      throw translateCapabilityError(error, "download_failed");
    }

    return {
      type: "file_browser_download_result_v1",
      requestId: message.requestId,
      success: true,
      rootId: root.rootId,
      relativePath: normalizedPath,
      transferId: offered.transferId,
      status: "queued",
    };
  }

  private async initializeRoots(
    requestedRoots: string[],
  ): Promise<RootSnapshot> {
    await this.backend.init();
    const snapshot = await this.buildRootSnapshot(requestedRoots);
    if (snapshot.roots.length === 0) {
      throw new FileBrowserError(
        "invalid_root",
        "No secure file browser roots are available",
      );
    }
    return snapshot;
  }

  private async buildRootSnapshot(
    requestedRoots: string[],
  ): Promise<RootSnapshot> {
    let canonicalHome = this.homeDir;
    try {
      canonicalHome = await realpath(this.homeDir);
    } catch {
      // A missing configured home produces no implicit broad fallback.
    }

    const candidates: Array<{
      canonicalPath: string;
      identity: FileBrowserRootIdentity;
    }> = [];
    for (const requestedRoot of requestedRoots) {
      try {
        const canonicalPath = await realpath(resolve(requestedRoot));
        if (
          canonicalPath === parse(canonicalPath).root ||
          candidates.some((candidate) => candidate.canonicalPath === canonicalPath)
        ) {
          continue;
        }
        const identity = await this.backend.inspectRoot(canonicalPath);
        candidates.push({ canonicalPath, identity });
        if (candidates.length >= FILE_BROWSER_MAX_ROOTS) break;
      } catch {
        // Invalid configured roots are omitted rather than widening access.
      }
    }

    const usedIds = new Set<string>();
    const labelCounts = new Map<string, number>();
    const roots = candidates.map(({ canonicalPath, identity }) => {
      const baseLabel =
        canonicalPath === canonicalHome
          ? "Home"
          : safeRootLabel(basename(canonicalPath));
      const duplicateIndex = (labelCounts.get(baseLabel) ?? 0) + 1;
      labelCounts.set(baseLabel, duplicateIndex);
      const label =
        duplicateIndex === 1 ? baseLabel : `${baseLabel} (${duplicateIndex})`;
      let rootId = this.rootIdFactory(canonicalPath);
      for (let suffix = 2; usedIds.has(rootId); suffix += 1) {
        rootId = opaqueDigest("root-collision", canonicalPath, String(suffix)).slice(
          0,
          24,
        );
      }
      usedIds.add(rootId);
      return {
        rootId,
        label,
        displayPath: displayPathForRoot(canonicalPath, canonicalHome, label),
        canonicalPath,
        identity,
      };
    });
    const byId = new Map(roots.map((root) => [root.rootId, root]));
    const revision = opaqueDigest(
      "root-set",
      ...roots.map(
        (root) => `${root.rootId}\0${root.label}\0${root.displayPath}`,
      ),
    );
    return { roots, byId, revision };
  }

  private async requireRoot(rootId: string): Promise<BrowserRoot> {
    const root = (await this.rootsPromise).byId.get(rootId);
    if (!root) {
      throw new FileBrowserError("invalid_root", "The file root is unavailable");
    }
    return root;
  }

  private async directoryEntries(
    root: BrowserRoot,
    requestedDirectory: string,
    canonicalDirectory: string,
    listed: FileBrowserNativeListResult,
    signal: AbortSignal,
  ): Promise<FileBrowserEntry[]> {
    if (listed.names.length === 0) return [];
    const prepared = await Promise.all(
      listed.names.map((name) =>
        this.prepareNode(
          root,
          joinRelativePath(requestedDirectory, name),
          true,
          signal,
          canonicalDirectory,
        ),
      ),
    );
    throwIfAborted(signal);
    const results = await this.backend.stat(
      root.canonicalPath,
      root.identity,
      prepared.map((item) => ({
        ...item.spec,
        sourceParentIdentity: {
          dev: listed.directory.dev,
          ino: listed.directory.ino,
        },
      })),
      signal,
    );
    return results.map((result, index) => {
      const item = prepared[index];
      if (!result.success) {
        if (
          result.errorCode === "not_found" ||
          result.errorCode === "directory_changed"
        ) {
          throw new FileBrowserError(
            "directory_changed",
            "A directory entry changed while it was being read",
          );
        }
        return unreadableEntry(root, item.relativePath, result.errorCode);
      }
      try {
        return this.nodeData(this.resolvedFromNative(root, item, result, true));
      } catch (error) {
        const browserError = normalizeError(error);
        if (browserError.code === "not_found" || browserError.code === "node_changed") {
          throw new FileBrowserError(
            "directory_changed",
            "A directory entry changed while it was being read",
          );
        }
        return unreadableEntry(root, item.relativePath, browserError.code);
      }
    });
  }

  private async resolveNode(
    root: BrowserRoot,
    relativePath: string,
    allowBlockedTerminalSymlink: boolean,
    signal: AbortSignal,
  ): Promise<ResolvedNode> {
    const prepared = await this.prepareNode(
      root,
      relativePath,
      allowBlockedTerminalSymlink,
      signal,
    );
    const [result] = await this.backend.stat(
      root.canonicalPath,
      root.identity,
      [prepared.spec],
      signal,
    );
    if (!result.success) throw nativeResultError(result.errorCode);
    return this.resolvedFromNative(
      root,
      prepared,
      result,
      allowBlockedTerminalSymlink,
    );
  }

  private async prepareNode(
    root: BrowserRoot,
    relativePath: string,
    allowBlockedTerminalSymlink: boolean,
    signal: AbortSignal,
    knownCanonicalParent?: string,
  ): Promise<PreparedNode> {
    throwIfAborted(signal);
    const normalizedPath = normalizeRelativePath(relativePath);
    const lexicalPath = absolutePathFor(root.canonicalPath, normalizedPath);
    if (normalizedPath === "") {
      return {
        relativePath: normalizedPath,
        lexicalPath,
        canonicalPath: root.canonicalPath,
        canonicalRelativePath: "",
        spec: {
          sourceParent: "",
          targetCanonical: "",
        },
      };
    }
    const segments = normalizedPath.split("/");
    const sourceName = segments.pop()!;
    const sourceParent =
      knownCanonicalParent ??
      (await this.canonicalizeWithinRoot(root, segments.join("/"), signal));
    let canonicalPath: string | undefined;
    let canonicalRelativePath: string | undefined;
    try {
      canonicalPath = await realpath(lexicalPath);
      canonicalRelativePath = canonicalRelativeWithinRoot(
        root.canonicalPath,
        canonicalPath,
      );
    } catch (error) {
      if (!allowBlockedTerminalSymlink) throw safeCanonicalizationError(error);
    }
    throwIfAborted(signal);
    return {
      relativePath: normalizedPath,
      lexicalPath,
      canonicalPath,
      canonicalRelativePath,
      spec: {
        sourceParent,
        sourceName,
        ...(canonicalRelativePath === undefined
          ? {}
          : { targetCanonical: canonicalRelativePath }),
      },
    };
  }

  private resolvedFromNative(
    root: BrowserRoot,
    prepared: PreparedNode,
    result: Extract<FileBrowserNativeStatResult, { success: true }>,
    allowBlockedTerminalSymlink: boolean,
  ): ResolvedNode {
    const target = result.target;
    const blockedSymlink = target === undefined;
    if (blockedSymlink) {
      if (!allowBlockedTerminalSymlink || result.source.kind !== "symlink") {
        throw new FileBrowserError(
          "node_changed",
          "The file changed while it was being inspected",
        );
      }
    } else if (
      result.source.kind !== "symlink" &&
      !sameNativeIdentity(result.source, target)
    ) {
      throw new FileBrowserError(
        "node_changed",
        "The file changed while it was being inspected",
      );
    }
    return {
      root,
      relativePath: prepared.relativePath,
      lexicalPath: prepared.lexicalPath,
      canonicalPath: prepared.canonicalPath,
      canonicalRelativePath: prepared.canonicalRelativePath,
      sourceStats: result.source,
      targetStats: result.target,
      blockedSymlink,
    };
  }

  private async canonicalizeWithinRoot(
    root: BrowserRoot,
    relativePath: string,
    signal: AbortSignal,
  ): Promise<string> {
    const normalizedPath = normalizeRelativePath(relativePath);
    try {
      const canonicalPath = await realpath(
        absolutePathFor(root.canonicalPath, normalizedPath),
      );
      throwIfAborted(signal);
      return canonicalRelativeWithinRoot(root.canonicalPath, canonicalPath);
    } catch (error) {
      if (error instanceof FileBrowserError) throw error;
      throw safeCanonicalizationError(error);
    }
  }

  private async requireRegularFile(
    root: BrowserRoot,
    relativePath: string,
    signal: AbortSignal,
  ): Promise<ResolvedNode> {
    const resolved = await this.resolveNode(root, relativePath, false, signal);
    const targetStats = resolved.targetStats ?? resolved.sourceStats;
    if (targetStats.kind !== "file") {
      throw new FileBrowserError(
        "not_regular_file",
        "Only regular files can be previewed or downloaded",
      );
    }
    return resolved;
  }

  private nodeData(resolved: ResolvedNode): FileBrowserEntry {
    const targetStats = resolved.targetStats;
    const sourceKind = resolved.sourceStats.kind;
    const targetKind = targetStats?.kind;
    const effectiveStats = targetStats ?? resolved.sourceStats;
    const regularFile =
      !resolved.blockedSymlink && targetKind === "file";
    const filename = displayNameFor(resolved.root, resolved.relativePath);
    const mimeType = regularFile ? mimeTypeForFilename(filename) : undefined;
    const previewKind =
      regularFile && mimeType
        ? previewKindForFile(filename, mimeType)
        : undefined;
    const canPreview =
      regularFile &&
      this.artifactStore !== undefined &&
      effectiveStats.size <= FILE_BROWSER_PREVIEW_MAX_BYTES;
    const canDownload =
      regularFile &&
      this.fileTransferManager !== undefined &&
      effectiveStats.size <= FILE_BROWSER_DOWNLOAD_MAX_BYTES;
    const directory =
      !resolved.blockedSymlink && targetKind === "directory";

    return {
      name: filename,
      relativePath: resolved.relativePath,
      kind: sourceKind,
      isSymlink: sourceKind === "symlink",
      ...(sourceKind === "symlink" && targetKind !== undefined
        ? { targetKind }
        : {}),
      ...(regularFile ? { sizeBytes: effectiveStats.size } : {}),
      modifiedAt: new Date(effectiveStats.mtimeMs).toISOString(),
      ...(mimeType === undefined ? {} : { mimeType }),
      ...(previewKind === undefined ? {} : { previewKind }),
      canOpen: directory || canPreview,
      canPreview,
      canDownload,
      nodeRevision: nodeRevision(resolved),
    };
  }

  private requireExpectedRevision(
    expected: string | undefined,
    actual: string,
  ): void {
    if (expected !== undefined && expected !== actual) {
      throw new FileBrowserError(
        "node_changed",
        "The file changed since it was displayed",
      );
    }
  }

  private requireCursor(
    token: string,
    client: object,
    clientGeneration: number,
  ): CursorState {
    this.pruneExpiredCursors();
    const cursor = this.cursors.get(token);
    if (
      !cursor ||
      cursor.client !== client ||
      cursor.clientGeneration !== clientGeneration
    ) {
      throw new FileBrowserError(
        "invalid_cursor",
        "The directory cursor is invalid or expired",
      );
    }
    return cursor;
  }

  private createCursor(
    input: Omit<CursorState, "createdAt" | "expiresAt">,
  ): string {
    if (
      !this.accepting ||
      this.clientGenerations.get(input.client) !== input.clientGeneration
    ) {
      throw new FileBrowserError(
        "control_cancelled",
        "The file browser client disconnected",
      );
    }
    this.pruneExpiredCursors();
    const clientCursors = [...this.cursors.entries()].filter(
      ([, cursor]) => cursor.client === input.client,
    );
    while (clientCursors.length >= MAX_CURSORS_PER_CLIENT) {
      const oldest = clientCursors.shift();
      if (oldest) this.cursors.delete(oldest[0]);
    }

    let token = "";
    for (let attempt = 0; attempt < 100; attempt += 1) {
      const candidate = this.cursorTokenFactory();
      if (candidate && !this.cursors.has(candidate)) {
        token = candidate;
        break;
      }
    }
    if (!token) {
      throw new FileBrowserError(
        "cursor_unavailable",
        "Unable to allocate a directory cursor",
      );
    }
    const now = this.now();
    this.cursors.set(token, {
      ...input,
      createdAt: now,
      expiresAt: now + this.cursorTtlMs,
    });
    return token;
  }

  private pruneExpiredCursors(): void {
    const now = this.now();
    for (const [token, cursor] of this.cursors) {
      if (cursor.expiresAt <= now) this.cursors.delete(token);
    }
  }

  private async withClientLimit<T>(
    client: object,
    signal: AbortSignal,
    operation: () => Promise<T>,
  ): Promise<T> {
    throwIfAborted(signal);
    const active = this.activeByClient.get(client) ?? 0;
    if (active >= MAX_CONCURRENT_OPERATIONS) {
      throw new FileBrowserError(
        "too_many_requests",
        "At most two file browser requests may run at once",
      );
    }
    if (this.activeGlobal >= MAX_GLOBAL_CONCURRENT_OPERATIONS) {
      throw new FileBrowserError(
        "too_many_requests",
        "The secure file browser is busy",
      );
    }
    this.activeByClient.set(client, active + 1);
    this.activeGlobal += 1;
    try {
      return await operation();
    } finally {
      this.activeGlobal = Math.max(0, this.activeGlobal - 1);
      const remaining = (this.activeByClient.get(client) ?? 1) - 1;
      if (remaining <= 0) this.activeByClient.delete(client);
      else this.activeByClient.set(client, remaining);
    }
  }

  private operationIsCurrent(
    client: object,
    binding: FileBrowserClientBinding,
    generation: number,
    signal: AbortSignal,
  ): boolean {
    return (
      this.accepting &&
      !signal.aborted &&
      this.clients.get(client) === binding &&
      this.clientGenerations.get(client) === generation &&
      binding.isOpen()
    );
  }

  private requireCurrentClient(
    client: object,
    generation: number,
    signal: AbortSignal,
  ): void {
    throwIfAborted(signal);
    if (
      !this.accepting ||
      this.clientGenerations.get(client) !== generation ||
      !this.clients.get(client)?.isOpen()
    ) {
      throw new FileBrowserError(
        "control_cancelled",
        "The file browser client disconnected",
      );
    }
  }
}

function normalizeRelativePath(input: string): string {
  if (!validFileBrowserRelativePath(input)) {
    throw new FileBrowserError(
      "invalid_relative_path",
      "File paths cannot contain traversal segments",
    );
  }
  return input;
}

function normalizePageSize(input: number | undefined): number {
  if (input === undefined) return FILE_BROWSER_DEFAULT_PAGE_SIZE;
  if (!Number.isInteger(input) || input <= 0) {
    throw new FileBrowserError(
      "invalid_page_size",
      "pageSize must be a positive integer",
    );
  }
  return Math.min(input, FILE_BROWSER_MAX_PAGE_SIZE);
}

function joinRelativePath(parent: string, name: string): string {
  return parent === "" ? name : `${parent}/${name}`;
}

function isWithinRoot(root: string, target: string): boolean {
  if (root === target) return true;
  const relativePath = relative(root, target);
  return (
    relativePath !== "" &&
    relativePath !== ".." &&
    !relativePath.startsWith(`..${sep}`) &&
    !isAbsolute(relativePath)
  );
}

function displayNameFor(root: BrowserRoot, relativePath: string): string {
  if (relativePath === "") return root.label;
  const segments = relativePath.split("/");
  return segments[segments.length - 1] || root.label;
}

function displayPathForRoot(
  canonicalPath: string,
  canonicalHome: string,
  label: string,
): string {
  if (canonicalPath === canonicalHome) return "~";
  if (isWithinRoot(canonicalHome, canonicalPath)) {
    return `~/${relative(canonicalHome, canonicalPath).split(sep).join("/")}`;
  }
  return label;
}

function safeRootLabel(input: string): string {
  const cleaned = input.replace(/[\u0000-\u001f\u007f]/g, " ").trim();
  return Array.from(cleaned || "Folder").slice(0, 80).join("");
}

function statsRevisionParts(stats: FileBrowserNativeStats): string {
  return [
    stats.dev,
    stats.ino,
    stats.mode,
    stats.size,
    stats.mtimeMs,
    stats.ctimeMs,
  ].join(":");
}

function sameNativeIdentity(
  left: FileBrowserNativeStats,
  right: FileBrowserNativeStats,
): boolean {
  return (
    left.dev === right.dev &&
    left.ino === right.ino &&
    left.mode === right.mode &&
    left.size === right.size &&
    left.mtimeMs === right.mtimeMs &&
    left.ctimeMs === right.ctimeMs
  );
}

function artifactIdentity(stats: FileBrowserNativeStats): ArtifactFileIdentity {
  return {
    dev: numericIdentityPart(stats.dev),
    ino: numericIdentityPart(stats.ino),
    size: stats.size,
    mtimeMs: stats.mtimeMs,
  };
}

function transferIdentity(stats: FileBrowserNativeStats): TransferFileIdentity {
  return {
    ...artifactIdentity(stats),
    ctimeMs: stats.ctimeMs,
  };
}

function nodeRevision(resolved: ResolvedNode): string {
  const canonicalRelative = resolved.canonicalRelativePath ?? "blocked";
  return opaqueDigest(
    "node",
    resolved.root.rootId,
    resolved.relativePath,
    statsRevisionParts(resolved.sourceStats),
    resolved.targetStats ? statsRevisionParts(resolved.targetStats) : "none",
    canonicalRelative,
  );
}

function numericIdentityPart(value: string): number {
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 0) {
    throw new FileBrowserError(
      "identity_unsupported",
      "The filesystem identity cannot be represented safely",
    );
  }
  return parsed;
}

function absolutePathFor(root: string, relativePath: string): string {
  return relativePath === ""
    ? root
    : join(root, ...relativePath.split("/"));
}

function canonicalRelativeWithinRoot(root: string, target: string): string {
  if (!isWithinRoot(root, target)) {
    throw new FileBrowserError(
      "path_not_allowed",
      "The requested path resolves outside its file root",
    );
  }
  if (root === target) return "";
  const result = relative(root, target).split(sep).join("/");
  return normalizeRelativePath(result);
}

function safeCanonicalizationError(error: unknown): FileBrowserError {
  if (error instanceof FileBrowserError) return error;
  return translateFsError(error);
}

function nativeResultError(code: string): FileBrowserError {
  switch (code) {
    case "not_found":
      return new FileBrowserError(code, "The file no longer exists");
    case "permission_denied":
      return new FileBrowserError(code, "The file cannot be read by the Bridge");
    case "invalid_symlink":
      return new FileBrowserError(
        code,
        "The symbolic link changed or cannot be followed safely",
      );
    case "root_changed":
      return new FileBrowserError(code, "The configured file root changed");
    default:
      return new FileBrowserError(
        boundedErrorCode(code),
        "The file cannot be inspected safely",
      );
  }
}

function unreadableEntry(
  root: BrowserRoot,
  relativePath: string,
  rawErrorCode: string,
): FileBrowserEntry {
  const code = boundedErrorCode(rawErrorCode);
  return {
    name: displayNameFor(root, relativePath),
    relativePath,
    kind: "other",
    isSymlink: false,
    canOpen: false,
    canPreview: false,
    canDownload: false,
    nodeRevision: opaqueDigest(
      "unreadable-node",
      root.rootId,
      relativePath,
      code,
    ),
  };
}

function boundedErrorCode(value: string): string {
  return /^[A-Za-z0-9_-]{1,128}$/u.test(value)
    ? value
    : "file_browser_failed";
}

const abortControllerCleanup = new WeakMap<AbortController, () => void>();

function linkedAbortController(external?: AbortSignal): AbortController {
  const controller = new AbortController();
  if (!external) return controller;
  const abort = (): void => controller.abort(external.reason);
  if (external.aborted) abort();
  else {
    external.addEventListener("abort", abort, { once: true });
    abortControllerCleanup.set(controller, () =>
      external.removeEventListener("abort", abort),
    );
  }
  return controller;
}

function unlinkAbortController(controller: AbortController): void {
  abortControllerCleanup.get(controller)?.();
  abortControllerCleanup.delete(controller);
}

function throwIfAborted(signal: AbortSignal): void {
  if (signal.aborted) {
    throw new FileBrowserError(
      "control_cancelled",
      "The file browser request was cancelled",
    );
  }
}

function opaqueDigest(...parts: string[]): string {
  const hash = createHash("sha256");
  for (const part of parts) {
    hash.update(part);
    hash.update("\0");
  }
  return hash.digest("base64url");
}

function translateFsError(error: unknown): FileBrowserError {
  const code = errorCode(error);
  if (code === "ENOENT" || code === "ENOTDIR") {
    return new FileBrowserError("not_found", "The file no longer exists");
  }
  if (code === "EACCES" || code === "EPERM") {
    return new FileBrowserError(
      "permission_denied",
      "The file cannot be read by the Bridge",
    );
  }
  if (code === "ELOOP") {
    return new FileBrowserError(
      "invalid_symlink",
      "The symbolic link cannot be resolved",
    );
  }
  return new FileBrowserError("file_unreadable", "The file cannot be read");
}

function translateCapabilityError(
  error: unknown,
  fallbackCode: string,
): FileBrowserError {
  if (error instanceof FileBrowserError) return error;
  if (typeof error === "object" && error !== null && "code" in error) {
    const code = boundedErrorCode(String((error as { code: unknown }).code));
    if (
      code === "file_changed" ||
      code === "file_gone" ||
      code === "source_changed"
    ) {
      return new FileBrowserError(
        "node_changed",
        "The file changed while the capability was being created",
      );
    }
    return new FileBrowserError(code, "The file capability could not be created");
  }
  return new FileBrowserError(
    fallbackCode,
    "The file capability could not be created",
  );
}

function normalizeError(error: unknown): FileBrowserError {
  if (error instanceof FileBrowserError) return error;
  if (error instanceof FileBrowserBackendError) {
    return new FileBrowserError(boundedErrorCode(error.code), error.message);
  }
  return new FileBrowserError(
    "file_browser_failed",
    "The file browser request failed",
  );
}

function errorCode(error: unknown): string | undefined {
  return typeof error === "object" && error !== null && "code" in error
    ? String((error as { code?: unknown }).code)
    : undefined;
}

function resultTypeFor(
  type: FileBrowserClientMessage["type"],
): FileBrowserServerMessage["type"] {
  switch (type) {
    case ROOTS_REQUEST:
      return "file_browser_roots_result_v1";
    case LIST_REQUEST:
      return "file_browser_list_result_v1";
    case STAT_REQUEST:
      return "file_browser_stat_result_v1";
    case PREVIEW_REQUEST:
      return "file_browser_preview_result_v1";
    case DOWNLOAD_REQUEST:
      return "file_browser_download_result_v1";
  }
}
