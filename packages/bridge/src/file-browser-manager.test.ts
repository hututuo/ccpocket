import { execFileSync } from "node:child_process";
import {
  mkdir,
  mkdtemp,
  rm,
  symlink,
  truncate,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  FILE_BROWSER_DOWNLOAD_MAX_BYTES,
  FILE_BROWSER_PREVIEW_MAX_BYTES,
  FileBrowserManager,
} from "./file-browser-manager.js";
import { FileBrowserPosixBackend } from "./file-browser-posix-backend.js";

interface CapturedMessage {
  type: string;
  requestId: string;
  success: boolean;
  errorCode?: string;
  [key: string]: unknown;
}

const temporaryRoots: string[] = [];
const managers: FileBrowserManager[] = [];
const nativeBrowserSupported =
  process.platform === "darwin" || process.platform === "linux";
const describeNative = describe.skipIf(!nativeBrowserSupported);

afterEach(async () => {
  await Promise.all(managers.splice(0).map((manager) => manager.close()));
  await Promise.all(
    temporaryRoots
      .splice(0)
      .map((directory) => rm(directory, { recursive: true, force: true })),
  );
});

async function temporaryDirectory(prefix: string): Promise<string> {
  const directory = await mkdtemp(join(tmpdir(), prefix));
  temporaryRoots.push(directory);
  return directory;
}

async function fixture(options: {
  allowedDirs?: string[];
  allowFilesystemRoot?: boolean;
  homeDir?: string;
  artifactStore?: ConstructorParameters<
    typeof FileBrowserManager
  >[0]["artifactStore"];
  fileTransferManager?: ConstructorParameters<
    typeof FileBrowserManager
  >[0]["fileTransferManager"];
  now?: () => number;
  cursorTtlMs?: number;
  backend?: FileBrowserPosixBackend;
}) {
  const root =
    options.homeDir ?? (await temporaryDirectory("ccpocket-browser-"));
  const messages: CapturedMessage[] = [];
  const client = {};
  const manager = new FileBrowserManager({
    bridgeInstanceId: "bridge-test",
    homeDir: root,
    allowedDirs: options.allowedDirs ?? [],
    allowFilesystemRoot: options.allowFilesystemRoot,
    artifactStore: options.artifactStore,
    fileTransferManager: options.fileTransferManager,
    now: options.now,
    cursorTtlMs: options.cursorTtlMs,
    backend: options.backend,
  });
  managers.push(manager);
  manager.connect(client, {
    isOpen: () => true,
    send(message) {
      messages.push(message as CapturedMessage);
      return true;
    },
  });
  await manager.init();

  const request = async (
    message: Parameters<typeof manager.handleClientMessage>[1],
  ) => {
    await manager.handleClientMessage(client, message);
    const response = messages.findLast(
      (candidate) => candidate.requestId === message.requestId,
    );
    expect(response).toBeDefined();
    return response!;
  };
  const roots = await request({
    type: "file_browser_roots_v1",
    requestId: "roots",
  });
  const firstRoot = (roots.roots as Array<{ rootId: string }>)[0];
  return {
    root,
    manager,
    client,
    messages,
    request,
    roots,
    rootId: firstRoot?.rootId,
  };
}

describeNative("FileBrowserManager roots and path authority", () => {
  it("fails initialization when the secure native helper is unavailable", async () => {
    const root = await temporaryDirectory("ccpocket-browser-no-helper-");
    const manager = new FileBrowserManager({
      bridgeInstanceId: "bridge-test",
      homeDir: root,
      helperPath: join(root, "missing-helper"),
    });
    managers.push(manager);

    await expect(manager.init()).rejects.toMatchObject({
      code: "helper_unavailable",
    });
  });

  it("uses only Home when allowedDirs is empty and never exposes an absolute path", async () => {
    const f = await fixture({});

    expect(f.roots).toMatchObject({
      success: true,
      bridgeInstanceId: "bridge-test",
      previewMaxBytes: FILE_BROWSER_PREVIEW_MAX_BYTES,
      downloadMaxBytes: FILE_BROWSER_DOWNLOAD_MAX_BYTES,
      downloadAvailable: false,
      roots: [{ label: "Home", displayPath: "~" }],
    });
    expect(JSON.stringify(f.roots)).not.toContain(f.root);
    expect(f.rootId).toMatch(/^[A-Za-z0-9_-]{24}$/);
  });

  it("uses configured roots, deduplicates them, and refuses a filesystem root", async () => {
    const container = await temporaryDirectory("ccpocket-browser-roots-");
    const first = join(container, "one");
    const second = join(container, "two");
    await mkdir(first);
    await mkdir(second);
    const f = await fixture({
      homeDir: container,
      allowedDirs: [first, first, second, "/"],
    });

    expect(f.roots.roots).toEqual([
      expect.objectContaining({ label: "one", displayPath: "~/one" }),
      expect.objectContaining({ label: "two", displayPath: "~/two" }),
    ]);
    expect(JSON.stringify(f.roots)).not.toContain(container);
  });

  it("exposes an opaque Mac root only when explicitly enabled", async () => {
    const home = await temporaryDirectory("ccpocket-browser-owner-home-");
    const f = await fixture({
      homeDir: home,
      allowFilesystemRoot: true,
    });

    expect(f.roots.roots).toEqual([
      expect.objectContaining({ label: "Home", displayPath: "~" }),
      expect.objectContaining({ label: "Mac", displayPath: "Mac" }),
    ]);
    expect(JSON.stringify(f.roots)).not.toContain(home);
    const macRoot = (
      f.roots.roots as Array<{
        rootId: string;
        label: string;
      }>
    ).find((root) => root.label === "Mac");
    expect(macRoot?.rootId).toMatch(/^[A-Za-z0-9_-]{24}$/);
  });

  it("rejects absolute, traversal, backslash, and drive-prefixed paths on every platform", async () => {
    const f = await fixture({});
    await writeFile(join(f.root, "inside.txt"), "inside");

    for (const [requestId, relativePath] of [
      ["traversal", "../outside"],
      ["absolute", join(f.root, "inside.txt")],
      ["backslash", "folder\\secret"],
      ["drive", "C:/Windows"],
    ] as const) {
      const response = await f.request({
        type: "file_browser_list_v1",
        requestId,
        rootId: f.rootId,
        relativePath,
      });
      expect(response).toMatchObject({
        success: false,
        errorCode: "invalid_relative_path",
      });
    }
  });

  it("filters hidden files by default and includes them only when requested", async () => {
    const f = await fixture({});
    await writeFile(join(f.root, ".secret"), "secret");
    await writeFile(join(f.root, "visible.txt"), "visible");

    const normal = await f.request({
      type: "file_browser_list_v1",
      requestId: "normal",
      rootId: f.rootId,
      relativePath: "",
    });
    const shown = await f.request({
      type: "file_browser_list_v1",
      requestId: "shown",
      rootId: f.rootId,
      relativePath: "",
      showHidden: true,
    });

    expect(
      (normal.entries as Array<{ name: string }>).map((entry) => entry.name),
    ).toEqual(["visible.txt"]);
    expect(
      (shown.entries as Array<{ name: string }>).map((entry) => entry.name),
    ).toEqual([".secret", "visible.txt"]);
    expect(normal.entries).toEqual([
      expect.objectContaining({ name: "visible.txt", isSymlink: false }),
    ]);
  });

  it("lists an empty directory without issuing an empty native stat batch", async () => {
    const f = await fixture({});
    await mkdir(join(f.root, "empty"));

    const listed = await f.request({
      type: "file_browser_list_v1",
      requestId: "empty-directory",
      rootId: f.rootId,
      relativePath: "empty",
    });
    expect(listed).toMatchObject({ success: true, entries: [] });
  });

  it("uses stable name ordering instead of eagerly statting the whole directory for folders-first", async () => {
    const f = await fixture({});
    await writeFile(join(f.root, "a-file.txt"), "a");
    await mkdir(join(f.root, "z-directory"));

    const listed = await f.request({
      type: "file_browser_list_v1",
      requestId: "name-order",
      rootId: f.rootId,
      relativePath: "",
    });
    expect(
      (listed.entries as Array<{ name: string }>).map((entry) => entry.name),
    ).toEqual(["a-file.txt", "z-directory"]);
  });
});

describeNative("FileBrowserManager pagination", () => {
  it("defaults to 100 entries, caps pages at 200, and pages with an opaque cursor", async () => {
    const f = await fixture({});
    await Promise.all(
      Array.from({ length: 205 }, (_, index) =>
        writeFile(
          join(f.root, `file-${String(index).padStart(3, "0")}.txt`),
          "x",
        ),
      ),
    );

    const first = await f.request({
      type: "file_browser_list_v1",
      requestId: "first",
      rootId: f.rootId,
      relativePath: "",
    });
    expect(first.success).toBe(true);
    expect(first.entries).toHaveLength(100);
    expect(first.nextCursor).toEqual(expect.any(String));

    const capped = await f.request({
      type: "file_browser_list_v1",
      requestId: "capped",
      rootId: f.rootId,
      relativePath: "",
      pageSize: 999,
    });
    expect(capped.entries).toHaveLength(200);

    const tail = await f.request({
      type: "file_browser_list_v1",
      requestId: "tail",
      rootId: f.rootId,
      relativePath: "",
      pageSize: 999,
      cursor: capped.nextCursor as string,
    });
    expect(tail.entries).toHaveLength(5);
    expect(tail.nextCursor).toBeUndefined();
  });

  it("binds cursors to one client without letting a wrong client consume them", async () => {
    const f = await fixture({});
    await writeFile(join(f.root, "a"), "a");
    await writeFile(join(f.root, "b"), "b");
    await writeFile(join(f.root, "c"), "c");
    const first = await f.request({
      type: "file_browser_list_v1",
      requestId: "first",
      rootId: f.rootId,
      relativePath: "",
      pageSize: 1,
    });
    const cursor = first.nextCursor as string;

    const otherClient = {};
    const otherMessages: CapturedMessage[] = [];
    f.manager.connect(otherClient, {
      isOpen: () => true,
      send(message) {
        otherMessages.push(message as CapturedMessage);
        return true;
      },
    });
    await f.manager.handleClientMessage(otherClient, {
      type: "file_browser_list_v1",
      requestId: "wrong-client",
      rootId: f.rootId,
      relativePath: "",
      pageSize: 1,
      cursor,
    });
    expect(otherMessages[0]).toMatchObject({
      success: false,
      errorCode: "invalid_cursor",
    });

    const rightful = await f.request({
      type: "file_browser_list_v1",
      requestId: "rightful",
      rootId: f.rootId,
      relativePath: "",
      // parseClient normalizes an omitted continuation size to 100; the
      // opaque cursor must retain the original one-entry page contract.
      pageSize: 100,
      cursor,
    });
    expect(rightful.success).toBe(true);
    expect(rightful.entries).toHaveLength(1);
    expect(rightful.nextCursor).toEqual(expect.any(String));
  });

  it("expires cursors and detects directory changes between pages", async () => {
    let now = 1_000;
    const f = await fixture({ now: () => now, cursorTtlMs: 50 });
    await writeFile(join(f.root, "a"), "a");
    await writeFile(join(f.root, "b"), "b");
    const expiring = await f.request({
      type: "file_browser_list_v1",
      requestId: "expiring",
      rootId: f.rootId,
      relativePath: "",
      pageSize: 1,
    });
    now += 51;
    const expired = await f.request({
      type: "file_browser_list_v1",
      requestId: "expired",
      rootId: f.rootId,
      relativePath: "",
      pageSize: 1,
      cursor: expiring.nextCursor as string,
    });
    expect(expired).toMatchObject({
      success: false,
      errorCode: "invalid_cursor",
    });

    const changing = await f.request({
      type: "file_browser_list_v1",
      requestId: "changing",
      rootId: f.rootId,
      relativePath: "",
      pageSize: 1,
    });
    await writeFile(join(f.root, "c"), "c");
    const changed = await f.request({
      type: "file_browser_list_v1",
      requestId: "changed",
      rootId: f.rootId,
      relativePath: "",
      pageSize: 1,
      cursor: changing.nextCursor as string,
    });
    expect(changed).toMatchObject({
      success: false,
      errorCode: "directory_changed",
    });
  });

  it("keeps at most eight live cursors per client", async () => {
    const f = await fixture({});
    await writeFile(join(f.root, "a"), "a");
    await writeFile(join(f.root, "b"), "b");
    const cursors: string[] = [];
    for (let index = 0; index < 9; index += 1) {
      const page = await f.request({
        type: "file_browser_list_v1",
        requestId: `cursor-${index}`,
        rootId: f.rootId,
        relativePath: "",
        pageSize: 1,
      });
      cursors.push(page.nextCursor as string);
    }

    const evicted = await f.request({
      type: "file_browser_list_v1",
      requestId: "evicted",
      rootId: f.rootId,
      relativePath: "",
      pageSize: 1,
      cursor: cursors[0],
    });
    expect(evicted).toMatchObject({
      success: false,
      errorCode: "invalid_cursor",
    });
  });

  it("invalidates every cursor when the same client reconnects", async () => {
    const f = await fixture({});
    await writeFile(join(f.root, "a"), "a");
    await writeFile(join(f.root, "b"), "b");
    const first = await f.request({
      type: "file_browser_list_v1",
      requestId: "before-reconnect",
      rootId: f.rootId,
      relativePath: "",
      pageSize: 1,
    });

    f.manager.disconnect(f.client);
    f.manager.connect(f.client, {
      isOpen: () => true,
      send(message) {
        f.messages.push(message as CapturedMessage);
        return true;
      },
    });
    const response = await f.request({
      type: "file_browser_list_v1",
      requestId: "after-reconnect",
      rootId: f.rootId,
      relativePath: "",
      pageSize: 1,
      cursor: first.nextCursor as string,
    });
    expect(response).toMatchObject({
      success: false,
      errorCode: "invalid_cursor",
    });
  });
});

describeNative("FileBrowserManager node safety", () => {
  it("rejects a page when its pinned directory changes before entry stat", async () => {
    const nativeDirectory = {
      kind: "directory" as const,
      dev: "1",
      ino: "10",
      mode: 0o40755,
      size: 0,
      mtimeMs: 1,
      ctimeMs: 1,
    };
    const backend = {
      init: vi.fn(async () => {}),
      inspectRoot: vi.fn(async () => ({ dev: "1", ino: "1" })),
      list: vi.fn(async () => ({
        directory: nativeDirectory,
        revision: "listed-revision",
        totalEntries: 1,
        names: ["same-name.txt"],
      })),
      stat: vi.fn(async () => [
        { success: false as const, errorCode: "directory_changed" },
      ]),
    } as unknown as FileBrowserPosixBackend;
    const f = await fixture({ backend });
    await writeFile(join(f.root, "same-name.txt"), "current");

    const listed = await f.request({
      type: "file_browser_list_v1",
      requestId: "list-stat-swap",
      rootId: f.rootId,
      relativePath: "",
    });
    expect(listed).toMatchObject({
      success: false,
      errorCode: "directory_changed",
    });
    expect(backend.stat).toHaveBeenCalledWith(
      expect.any(String),
      expect.any(Object),
      [
        expect.objectContaining({
          sourceParentIdentity: { dev: "1", ino: "10" },
        }),
      ],
      expect.any(AbortSignal),
    );
  });

  it.skipIf(process.platform === "win32")(
    "opens only symlinks whose canonical targets remain in the same root",
    async () => {
      const artifactStore = {
        issue: vi.fn(async () => ({
          relativeUrl: "/artifacts/inside",
          relativeDownloadUrl: "/artifacts/inside/download",
          filename: "inside-link.txt",
          mimeType: "text/plain; charset=utf-8",
          sizeBytes: 6,
          expiresAt: new Date(Date.now() + 600_000).toISOString(),
        })),
      };
      const fileTransferManager = {
        offerFileToClient: vi.fn(async () => ({
          transferId: "transfer-inside",
        })),
      };
      const f = await fixture({ artifactStore, fileTransferManager });
      const outside = await temporaryDirectory("ccpocket-browser-outside-");
      await writeFile(join(f.root, "inside.txt"), "inside");
      await writeFile(join(outside, "outside.txt"), "outside");
      await symlink("inside.txt", join(f.root, "inside-link.txt"));
      await symlink(
        join(outside, "outside.txt"),
        join(f.root, "outside-link.txt"),
      );

      const listed = await f.request({
        type: "file_browser_list_v1",
        requestId: "links",
        rootId: f.rootId,
        relativePath: "",
      });
      const entries = listed.entries as Array<Record<string, unknown>>;
      expect(
        entries.find((entry) => entry.name === "inside-link.txt"),
      ).toMatchObject({
        kind: "symlink",
        isSymlink: true,
        targetKind: "file",
        canOpen: true,
        canPreview: true,
        canDownload: true,
      });
      expect(
        entries.find((entry) => entry.name === "outside-link.txt"),
      ).toMatchObject({
        kind: "symlink",
        isSymlink: true,
        canOpen: false,
        canPreview: false,
        canDownload: false,
      });

      const blocked = await f.request({
        type: "file_browser_preview_v1",
        requestId: "blocked-link",
        rootId: f.rootId,
        relativePath: "outside-link.txt",
      });
      expect(blocked).toMatchObject({
        success: false,
        errorCode: "path_not_allowed",
      });

      const allowed = await f.request({
        type: "file_browser_preview_v1",
        requestId: "allowed-link",
        rootId: f.rootId,
        relativePath: "inside-link.txt",
      });
      expect(allowed.success).toBe(true);
      expect(artifactStore.issue).toHaveBeenCalledOnce();
    },
  );

  it.skipIf(process.platform === "win32")(
    "shows special files but never previews or downloads them",
    async () => {
      const artifactStore = {
        issue: vi.fn(async () => {
          throw new Error("must not issue");
        }),
      };
      const fileTransferManager = {
        offerFileToClient: vi.fn(async () => {
          throw new Error("must not offer");
        }),
      };
      const f = await fixture({ artifactStore, fileTransferManager });
      const fifo = join(f.root, "events.pipe");
      execFileSync("mkfifo", [fifo]);

      const listed = await f.request({
        type: "file_browser_list_v1",
        requestId: "special-list",
        rootId: f.rootId,
        relativePath: "",
      });
      expect(listed.entries).toEqual([
        expect.objectContaining({
          name: "events.pipe",
          kind: "other",
          isSymlink: false,
          canOpen: false,
          canPreview: false,
          canDownload: false,
        }),
      ]);

      const preview = await f.request({
        type: "file_browser_preview_v1",
        requestId: "special-preview",
        rootId: f.rootId,
        relativePath: "events.pipe",
      });
      const download = await f.request({
        type: "file_browser_download_v1",
        requestId: "special-download",
        rootId: f.rootId,
        relativePath: "events.pipe",
      });
      expect(preview).toMatchObject({
        success: false,
        errorCode: "not_regular_file",
      });
      expect(download).toMatchObject({
        success: false,
        errorCode: "not_regular_file",
      });
      expect(artifactStore.issue).not.toHaveBeenCalled();
      expect(fileTransferManager.offerFileToClient).not.toHaveBeenCalled();
    },
  );
});

describeNative("FileBrowserManager preview and download boundaries", () => {
  it("aborts and drains an in-flight request before close resolves", async () => {
    let entered!: () => void;
    const started = new Promise<void>((resolve) => {
      entered = resolve;
    });
    let release!: () => void;
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    const nativeDirectory = {
      kind: "directory" as const,
      dev: "1",
      ino: "1",
      mode: 0o40755,
      size: 0,
      mtimeMs: 1,
      ctimeMs: 1,
    };
    const backend = {
      init: vi.fn(async () => {}),
      inspectRoot: vi.fn(async () => ({ dev: "1", ino: "1" })),
      list: vi.fn(async () => {
        entered();
        await gate;
        return {
          directory: nativeDirectory,
          revision: "revision",
          totalEntries: 0,
          names: [],
        };
      }),
      stat: vi.fn(async () => []),
    } as unknown as FileBrowserPosixBackend;
    const f = await fixture({ backend });
    const pending = f.manager.handleClientMessage(f.client, {
      type: "file_browser_list_v1",
      requestId: "closing-list",
      rootId: f.rootId,
      relativePath: "",
      pageSize: 100,
    });
    await started;
    let closeResolved = false;
    const closing = f.manager.close().then(() => {
      closeResolved = true;
    });
    await Promise.resolve();
    expect(closeResolved).toBe(false);

    release();
    await pending;
    await closing;
    expect(
      f.messages.some((message) => message.requestId === "closing-list"),
    ).toBe(false);
  });

  it("keeps a reconnected client's new request abortable after the old request settles", async () => {
    const signals: AbortSignal[] = [];
    let releaseFirst!: () => void;
    const firstGate = new Promise<void>((resolve) => {
      releaseFirst = resolve;
    });
    let releaseSecond!: () => void;
    const secondGate = new Promise<void>((resolve) => {
      releaseSecond = resolve;
    });
    const nativeDirectory = {
      kind: "directory" as const,
      dev: "1",
      ino: "1",
      mode: 0o40755,
      size: 0,
      mtimeMs: 1,
      ctimeMs: 1,
    };
    const backend = {
      init: vi.fn(async () => {}),
      inspectRoot: vi.fn(async () => ({ dev: "1", ino: "1" })),
      list: vi.fn(async (...args: unknown[]) => {
        const options = args[3] as { signal?: AbortSignal };
        signals.push(options.signal!);
        await (signals.length === 1 ? firstGate : secondGate);
        return {
          directory: nativeDirectory,
          revision: "revision",
          totalEntries: 0,
          names: [],
        };
      }),
      stat: vi.fn(async () => []),
    } as unknown as FileBrowserPosixBackend;
    const f = await fixture({ backend });
    const first = f.manager.handleClientMessage(f.client, {
      type: "file_browser_list_v1",
      requestId: "old-generation",
      rootId: f.rootId,
      relativePath: "",
      pageSize: 100,
    });
    await vi.waitFor(() => expect(signals).toHaveLength(1));
    f.manager.disconnect(f.client);
    f.manager.connect(f.client, {
      isOpen: () => true,
      send(message) {
        f.messages.push(message as CapturedMessage);
        return true;
      },
    });
    const second = f.manager.handleClientMessage(f.client, {
      type: "file_browser_list_v1",
      requestId: "new-generation",
      rootId: f.rootId,
      relativePath: "",
      pageSize: 100,
    });
    await vi.waitFor(() => expect(signals).toHaveLength(2));

    releaseFirst();
    await first;
    f.manager.disconnect(f.client);
    expect(signals[1].aborted).toBe(true);
    releaseSecond();
    await second;
  });

  it("limits one client to two concurrent file operations", async () => {
    let release!: () => void;
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    const artifactStore = {
      issue: vi.fn(async () => {
        await gate;
        return {
          relativeUrl: "/artifacts/concurrent",
          relativeDownloadUrl: "/artifacts/concurrent/download",
          filename: "note.txt",
          mimeType: "text/plain; charset=utf-8",
          sizeBytes: 5,
          expiresAt: new Date(Date.now() + 600_000).toISOString(),
        };
      }),
    };
    const f = await fixture({ artifactStore });
    await writeFile(join(f.root, "note.txt"), "hello");
    const preview = (requestId: string) =>
      f.manager.handleClientMessage(f.client, {
        type: "file_browser_preview_v1",
        requestId,
        rootId: f.rootId,
        relativePath: "note.txt",
      });

    const first = preview("concurrent-1");
    const second = preview("concurrent-2");
    await preview("concurrent-3");
    expect(
      f.messages.find((message) => message.requestId === "concurrent-3"),
    ).toMatchObject({ success: false, errorCode: "too_many_requests" });

    release();
    await Promise.all([first, second]);
    expect(artifactStore.issue).toHaveBeenCalledTimes(2);
  });

  it("limits file browsing to four concurrent operations across clients", async () => {
    let release!: () => void;
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    const artifactStore = {
      issue: vi.fn(async () => {
        await gate;
        return {
          relativeUrl: "/artifacts/global-limit",
          relativeDownloadUrl: "/artifacts/global-limit/download",
          filename: "note.txt",
          mimeType: "text/plain; charset=utf-8",
          sizeBytes: 5,
          expiresAt: new Date(Date.now() + 600_000).toISOString(),
        };
      }),
    };
    const f = await fixture({ artifactStore });
    await writeFile(join(f.root, "note.txt"), "hello");
    const secondClient = {};
    const thirdClient = {};
    const secondMessages: CapturedMessage[] = [];
    const thirdMessages: CapturedMessage[] = [];
    f.manager.connect(secondClient, {
      isOpen: () => true,
      send(message) {
        secondMessages.push(message as CapturedMessage);
        return true;
      },
    });
    f.manager.connect(thirdClient, {
      isOpen: () => true,
      send(message) {
        thirdMessages.push(message as CapturedMessage);
        return true;
      },
    });
    const preview = (client: object, requestId: string) =>
      f.manager.handleClientMessage(client, {
        type: "file_browser_preview_v1",
        requestId,
        rootId: f.rootId,
        relativePath: "note.txt",
      });

    const active = [
      preview(f.client, "global-1"),
      preview(f.client, "global-2"),
      preview(secondClient, "global-3"),
      preview(secondClient, "global-4"),
    ];
    await preview(thirdClient, "global-5");
    expect(thirdMessages).toContainEqual(
      expect.objectContaining({
        requestId: "global-5",
        success: false,
        errorCode: "too_many_requests",
      }),
    );

    release();
    await Promise.all(active);
    expect(artifactStore.issue).toHaveBeenCalledTimes(4);
  });

  it("issues a ten-minute artifact only after matching the current node revision", async () => {
    const artifactStore = {
      issue: vi.fn(
        async (_filePath: string, options: { filename?: string }) => ({
          relativeUrl: "/artifacts/token",
          relativeDownloadUrl: "/artifacts/token/download",
          filename: options.filename ?? "file.txt",
          mimeType: "text/plain; charset=utf-8",
          sizeBytes: 5,
          expiresAt: new Date(Date.now() + 600_000).toISOString(),
        }),
      ),
    };
    const f = await fixture({ artifactStore });
    await writeFile(join(f.root, "note.txt"), "hello");
    const statResult = await f.request({
      type: "file_browser_stat_v1",
      requestId: "stat-note",
      items: [{ rootId: f.rootId, relativePath: "note.txt" }],
    });
    const node = (
      statResult.items as Array<{ node: { nodeRevision: string } }>
    )[0].node;

    const stale = await f.request({
      type: "file_browser_preview_v1",
      requestId: "stale-preview",
      rootId: f.rootId,
      relativePath: "note.txt",
      nodeRevision: "stale",
    });
    expect(stale).toMatchObject({ success: false, errorCode: "node_changed" });
    expect(artifactStore.issue).not.toHaveBeenCalled();

    const preview = await f.request({
      type: "file_browser_preview_v1",
      requestId: "preview-note",
      rootId: f.rootId,
      relativePath: "note.txt",
      nodeRevision: node.nodeRevision,
    });
    expect(preview).toMatchObject({
      success: true,
      relativeUrl: "/artifacts/token",
      filename: "note.txt",
      previewKind: "text",
    });
    expect(artifactStore.issue).toHaveBeenCalledWith(
      expect.stringContaining("note.txt"),
      expect.objectContaining({
        projectPath: expect.any(String),
        expectedIdentity: expect.objectContaining({ size: 5 }),
        filename: "note.txt",
        ttlSeconds: 600,
      }),
    );
  });

  it.skipIf(process.platform === "win32")(
    "resolves project previews through a configured root and blocks symlink escape from the project",
    async () => {
      const artifactStore = {
        issue: vi.fn(async () => ({
          relativeUrl: "/artifacts/project-preview",
          relativeDownloadUrl: "/artifacts/project-preview/download",
          filename: "report.html",
          mimeType: "text/html; charset=utf-8",
          sizeBytes: 15,
          expiresAt: new Date(Date.now() + 600_000).toISOString(),
        })),
      };
      const f = await fixture({ artifactStore });
      const project = join(f.root, "project");
      const outsideProject = join(f.root, "outside-project");
      await mkdir(project);
      await mkdir(outsideProject);
      await writeFile(join(project, "report.html"), "<h1>report</h1>");
      await writeFile(join(outsideProject, "secret.txt"), "secret");
      await symlink(
        join(outsideProject, "secret.txt"),
        join(project, "escape.txt"),
      );

      const preview = await f.request({
        type: "file_browser_project_preview_v1",
        requestId: "project-preview",
        projectPath: project,
        filePath: "report.html",
      });
      expect(preview).toMatchObject({
        type: "file_browser_preview_result_v1",
        success: true,
        rootId: f.rootId,
        relativePath: "project/report.html",
        relativeUrl: "/artifacts/project-preview",
        filename: "report.html",
        previewKind: "html",
      });
      expect(artifactStore.issue).toHaveBeenCalledWith(
        expect.stringContaining("report.html"),
        expect.objectContaining({
          projectPath: expect.stringContaining("ccpocket-browser-"),
          expectedIdentity: expect.objectContaining({ size: 15 }),
          filename: "report.html",
          ttlSeconds: 600,
        }),
      );

      const escaped = await f.request({
        type: "file_browser_project_preview_v1",
        requestId: "project-preview-escape",
        projectPath: project,
        filePath: "escape.txt",
      });
      expect(escaped).toMatchObject({
        type: "file_browser_preview_result_v1",
        success: false,
        errorCode: "path_not_allowed",
      });
      expect(artifactStore.issue).toHaveBeenCalledOnce();
    },
  );

  it("allows exactly 2 GiB for preview and rejects one byte more", async () => {
    const artifactStore = {
      issue: vi.fn(async () => ({
        relativeUrl: "/artifacts/large",
        relativeDownloadUrl: "/artifacts/large/download",
        filename: "large.bin",
        mimeType: "application/octet-stream",
        sizeBytes: FILE_BROWSER_PREVIEW_MAX_BYTES,
        expiresAt: new Date(Date.now() + 600_000).toISOString(),
      })),
    };
    const f = await fixture({ artifactStore });
    const exact = join(f.root, "exact.bin");
    const tooLarge = join(f.root, "too-large.bin");
    await writeFile(exact, "");
    await writeFile(tooLarge, "");
    await truncate(exact, FILE_BROWSER_PREVIEW_MAX_BYTES);
    await truncate(tooLarge, FILE_BROWSER_PREVIEW_MAX_BYTES + 1);

    const accepted = await f.request({
      type: "file_browser_preview_v1",
      requestId: "preview-exact",
      rootId: f.rootId,
      relativePath: "exact.bin",
    });
    const rejected = await f.request({
      type: "file_browser_preview_v1",
      requestId: "preview-too-large",
      rootId: f.rootId,
      relativePath: "too-large.bin",
    });
    expect(accepted.success).toBe(true);
    expect(rejected).toMatchObject({
      success: false,
      errorCode: "preview_too_large",
    });
    expect(artifactStore.issue).toHaveBeenCalledOnce();
  });

  it("targets the requesting client up to 15 GiB and rejects one byte more", async () => {
    const fileTransferManager = {
      offerFileToClient: vi.fn(async () => ({
        transferId: "download-transfer",
      })),
    };
    const f = await fixture({ fileTransferManager });
    const exact = join(f.root, "exact-download.bin");
    const tooLarge = join(f.root, "too-large-download.bin");
    await writeFile(exact, "");
    await writeFile(tooLarge, "");
    await truncate(exact, FILE_BROWSER_DOWNLOAD_MAX_BYTES);
    await truncate(tooLarge, FILE_BROWSER_DOWNLOAD_MAX_BYTES + 1);

    const accepted = await f.request({
      type: "file_browser_download_v1",
      requestId: "download-exact",
      rootId: f.rootId,
      relativePath: "exact-download.bin",
    });
    const rejected = await f.request({
      type: "file_browser_download_v1",
      requestId: "download-too-large",
      rootId: f.rootId,
      relativePath: "too-large-download.bin",
    });
    expect(accepted).toMatchObject({
      success: true,
      transferId: "download-transfer",
      status: "queued",
    });
    expect(rejected).toMatchObject({
      success: false,
      errorCode: "download_too_large",
    });
    expect(fileTransferManager.offerFileToClient).toHaveBeenCalledWith(
      f.client,
      expect.objectContaining({
        filePath: expect.stringContaining("exact-download.bin"),
        projectPath: expect.any(String),
        canonicalRoot: expect.any(String),
        expectedIdentity: expect.objectContaining({
          size: FILE_BROWSER_DOWNLOAD_MAX_BYTES,
        }),
        signal: expect.any(AbortSignal),
      }),
    );
    expect(fileTransferManager.offerFileToClient).toHaveBeenCalledOnce();
  });
});
