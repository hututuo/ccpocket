import {
  mkdir,
  mkdtemp,
  realpath,
  rename,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  FileBrowserBackendError,
  FileBrowserPosixBackend,
} from "./file-browser-posix-backend.js";

const temporaryRoots: string[] = [];
const supported = process.platform === "darwin" || process.platform === "linux";

afterEach(async () => {
  await Promise.all(
    temporaryRoots.splice(0).map((root) =>
      rm(root, { recursive: true, force: true }),
    ),
  );
});

async function temporaryDirectory(prefix: string): Promise<string> {
  const root = await realpath(await mkdtemp(join(tmpdir(), prefix)));
  temporaryRoots.push(root);
  return root;
}

describe.skipIf(!supported)("FileBrowserPosixBackend", () => {
  it("lists a pinned root without returning an absolute path", async () => {
    const root = await temporaryDirectory("ccpocket-browser-native-");
    await writeFile(join(root, "note.txt"), "hello");
    const backend = new FileBrowserPosixBackend();
    await backend.init();
    const identity = await backend.inspectRoot(root);

    const listed = await backend.list(root, identity, "", {
      pageSize: 100,
      startIndex: 0,
      showHidden: false,
    });

    expect(listed.names).toEqual(["note.txt"]);
    expect(JSON.stringify(listed)).not.toContain(root);
  });

  it("refuses to follow symlink components while pinning a root", async () => {
    const container = await temporaryDirectory("ccpocket-browser-root-pin-");
    const root = join(container, "root");
    const alias = join(container, "root-alias");
    await mkdir(root);
    await symlink(root, alias, "dir");
    const backend = new FileBrowserPosixBackend();
    await backend.init();

    await expect(backend.inspectRoot(alias)).rejects.toMatchObject({
      code: expect.stringMatching(
        /^(invalid_symlink|not_found|file_unreadable)$/,
      ),
    });
  });

  it("rejects a directory swapped to an outside symlink after canonicalization", async () => {
    const container = await temporaryDirectory("ccpocket-browser-swap-");
    const root = join(container, "root");
    const outside = join(container, "outside");
    await mkdir(root);
    await mkdir(outside);
    await mkdir(join(root, "folder"));
    await writeFile(join(root, "folder", "inside.txt"), "inside");
    await writeFile(join(outside, "secret.txt"), "secret");

    const backend = new FileBrowserPosixBackend();
    await backend.init();
    const identity = await backend.inspectRoot(root);
    await rename(join(root, "folder"), join(root, "folder-before-swap"));
    await symlink(outside, join(root, "folder"), "dir");

    let failure: unknown;
    try {
      await backend.list(root, identity, "folder", {
        pageSize: 100,
        startIndex: 0,
        showHidden: false,
      });
    } catch (error) {
      failure = error;
    }
    expect(failure).toBeInstanceOf(FileBrowserBackendError);
    expect((failure as FileBrowserBackendError).code).toMatch(
      /^(invalid_symlink|not_found|file_unreadable)$/,
    );
    expect(String(failure)).not.toContain(outside);
    expect(String(failure)).not.toContain("secret.txt");
  });

  it("binds page-entry stats to the exact directory inode that was listed", async () => {
    const root = await temporaryDirectory("ccpocket-browser-list-stat-swap-");
    await mkdir(join(root, "folder"));
    await writeFile(join(root, "folder", "same-name.txt"), "before");
    const backend = new FileBrowserPosixBackend();
    await backend.init();
    const identity = await backend.inspectRoot(root);
    const listed = await backend.list(root, identity, "folder", {
      pageSize: 100,
      startIndex: 0,
      showHidden: false,
    });

    await rename(join(root, "folder"), join(root, "folder-before-swap"));
    await mkdir(join(root, "folder"));
    await writeFile(join(root, "folder", "same-name.txt"), "after");
    const [result] = await backend.stat(root, identity, [
      {
        sourceParent: "folder",
        sourceName: "same-name.txt",
        targetCanonical: "folder/same-name.txt",
        sourceParentIdentity: {
          dev: listed.directory.dev,
          ino: listed.directory.ino,
        },
      },
    ]);

    expect(result).toEqual({
      success: false,
      errorCode: "directory_changed",
    });
  });

  it("rejects a swapped root inode before invoking the helper", async () => {
    const container = await temporaryDirectory("ccpocket-browser-root-swap-");
    const root = join(container, "root");
    const outside = join(container, "outside");
    await mkdir(root);
    await mkdir(outside);
    await writeFile(join(outside, "secret.txt"), "secret");
    const backend = new FileBrowserPosixBackend();
    await backend.init();
    const identity = await backend.inspectRoot(root);
    await rename(root, join(container, "original-root"));
    await symlink(outside, root, "dir");

    await expect(
      backend.list(root, identity, "", {
        pageSize: 100,
        startIndex: 0,
        showHidden: false,
      }),
    ).rejects.toMatchObject({ code: "root_changed" });
  });

  it("enforces hard entry-count and total-name-byte limits", async () => {
    const root = await temporaryDirectory("ccpocket-browser-bounds-");
    await writeFile(join(root, "one"), "1");
    await writeFile(join(root, "two"), "2");
    await writeFile(join(root, "three"), "3");

    const entryBounded = new FileBrowserPosixBackend({
      maxDirectoryEntries: 2,
    });
    await entryBounded.init();
    const identity = await entryBounded.inspectRoot(root);
    await expect(
      entryBounded.list(root, identity, "", {
        pageSize: 100,
        startIndex: 0,
        showHidden: false,
      }),
    ).rejects.toMatchObject({ code: "directory_too_large" });

    const byteBounded = new FileBrowserPosixBackend({
      maxDirectoryNameBytes: 4,
    });
    await byteBounded.init();
    await expect(
      byteBounded.list(root, identity, "", {
        pageSize: 100,
        startIndex: 0,
        showHidden: false,
      }),
    ).rejects.toMatchObject({ code: "directory_too_large" });
  });

  it("fails initialization when the helper is unavailable", async () => {
    const root = await temporaryDirectory("ccpocket-browser-no-helper-");
    const backend = new FileBrowserPosixBackend({
      helperPath: join(root, "missing-helper"),
    });
    await expect(backend.init()).rejects.toMatchObject({
      code: "helper_unavailable",
    });
  });
});

describe("FileBrowserPosixBackend platform gate", () => {
  it("fails closed on Windows before advertising file browsing", async () => {
    const backend = new FileBrowserPosixBackend({ platform: "win32" });
    await expect(backend.init()).rejects.toMatchObject({
      code: "helper_unsupported",
    });
  });
});
