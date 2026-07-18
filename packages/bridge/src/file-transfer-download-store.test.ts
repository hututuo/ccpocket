import { mkdtemp, readFile, rm, truncate, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { FILE_TRANSFER_MAX_FILE_SIZE_BYTES } from "./file-transfer-constants.js";
import { FileTransferDownloadStore } from "./file-transfer-download-store.js";
import { FileTransferStateStore } from "./file-transfer-state-store.js";

const roots: string[] = [];

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "ccpocket-transfer-download-"));
  roots.push(root);
  const statePath = join(root, "state.json");
  return { root, statePath };
}

afterEach(async () => {
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

describe("FileTransferDownloadStore", () => {
  it("issues a 15 GiB transfer-only capability without the preview limit", async () => {
    const f = await fixture();
    const source = join(f.root, "large.bin");
    await writeFile(source, "");
    await truncate(source, FILE_TRANSFER_MAX_FILE_SIZE_BYTES);
    const state = new FileTransferStateStore({ filePath: f.statePath });
    const store = new FileTransferDownloadStore({
      stateStore: state,
      allowedDirs: [f.root],
      transferIdFactory: () => "download_1234567",
      tokenFactory: () => "a".repeat(43),
      etagFactory: () => `"${"e".repeat(32)}"`,
    });
    await expect(store.issue(source, { projectPath: f.root })).resolves.toMatchObject({
      entry: { sizeBytes: FILE_TRANSFER_MAX_FILE_SIZE_BYTES },
      downloadToken: "a".repeat(43),
    });
    await state.close();
  });

  it("rejects one byte above the 15 GiB ceiling", async () => {
    const f = await fixture();
    const source = join(f.root, "too-large.bin");
    await writeFile(source, "");
    await truncate(source, FILE_TRANSFER_MAX_FILE_SIZE_BYTES + 1);
    const state = new FileTransferStateStore({ filePath: f.statePath });
    const store = new FileTransferDownloadStore({ stateStore: state, allowedDirs: [f.root] });
    await expect(store.issue(source, { projectPath: f.root })).rejects.toMatchObject({ code: "file_too_large" });
    await state.close();
  });

  it("resumes the same token and ETag across a Bridge restart", async () => {
    const f = await fixture();
    const source = join(f.root, "source.txt");
    await writeFile(source, "hello world");
    const token = "b".repeat(43);
    const firstState = new FileTransferStateStore({ filePath: f.statePath });
    const first = new FileTransferDownloadStore({
      stateStore: firstState,
      allowedDirs: [f.root],
      transferIdFactory: () => "download_1234567",
      tokenFactory: () => token,
      etagFactory: () => `"${"q".repeat(32)}"`,
    });
    await first.issue(source, { projectPath: f.root });
    await firstState.close();

    const secondState = new FileTransferStateStore({ filePath: f.statePath });
    const second = new FileTransferDownloadStore({ stateStore: secondState, allowedDirs: [f.root] });
    const opened = await second.openAuthorized("download_1234567", token);
    const buffer = Buffer.alloc(5);
    await opened.handle.read(buffer, 0, 5, 6);
    expect(buffer.toString()).toBe("world");
    await second.verifyAfterRead(opened);
    await opened.handle.close();
    await secondState.close();
  });

  it("renews an expired HTTP lease within retention after source verification", async () => {
    const f = await fixture();
    const source = join(f.root, "source.txt");
    await writeFile(source, "hello");
    let now = 1_000;
    const token = "c".repeat(43);
    const state = new FileTransferStateStore({ filePath: f.statePath, now: () => now });
    const store = new FileTransferDownloadStore({
      stateStore: state,
      allowedDirs: [f.root],
      now: () => now,
      transferIdFactory: () => "download_1234567",
      tokenFactory: () => token,
      etagFactory: () => `"${"r".repeat(32)}"`,
    });
    const issued = await store.issue(source, { projectPath: f.root, ttlSeconds: 60 });
    now = issued.entry.expiresAt + 1;
    await expect(store.authorize(issued.entry.transferId, token)).rejects.toMatchObject({ code: "download_not_found" });
    await expect(store.resume(issued.entry.transferId, token)).resolves.toMatchObject({
      etag: issued.entry.etag,
      expiresAt: expect.any(Number),
    });
    await state.close();
  });

  it("fails a resume when the source identity changed", async () => {
    const f = await fixture();
    const source = join(f.root, "source.txt");
    await writeFile(source, "first");
    const state = new FileTransferStateStore({ filePath: f.statePath });
    const store = new FileTransferDownloadStore({
      stateStore: state,
      allowedDirs: [f.root],
      transferIdFactory: () => "download_1234567",
      tokenFactory: () => "d".repeat(43),
      etagFactory: () => `"${"s".repeat(32)}"`,
    });
    await store.issue(source, { projectPath: f.root });
    await writeFile(source, "changed");
    await expect(store.resume("download_1234567", "d".repeat(43)))
      .rejects.toMatchObject({ code: "source_changed" });
    await state.close();
  });

  it("bounds exported filenames by UTF-8 bytes", async () => {
    const f = await fixture();
    const source = join(f.root, `${"文".repeat(100)}.txt`);
    await writeFile(source, "x");
    const state = new FileTransferStateStore({ filePath: f.statePath });
    const store = new FileTransferDownloadStore({
      stateStore: state,
      allowedDirs: [f.root],
      transferIdFactory: () => "download_1234567",
      tokenFactory: () => "e".repeat(43),
      etagFactory: () => `"${"t".repeat(32)}"`,
    });
    const issued = await store.issue(source, { projectPath: f.root });
    expect(Buffer.byteLength(issued.entry.filename, "utf8")).toBeLessThanOrEqual(240);
    expect((await readFile(f.statePath, "utf8"))).not.toContain("e".repeat(43));
    await state.close();
  });
});
