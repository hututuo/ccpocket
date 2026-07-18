import { mkdtemp, mkdir, rm, truncate, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  FILE_TRANSFER_STATE_MAX_BYTES,
  fileTransferLockPaths,
} from "./file-transfer-state-store.js";
import { initializeFileTransferRuntime } from "./file-transfer-runtime.js";

const roots: string[] = [];

afterEach(async () => {
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

describe("initializeFileTransferRuntime", () => {
  it("fails soft on lock contention and keeps the first runtime healthy", async () => {
    const root = await mkdtemp(join(tmpdir(), "ccpocket-transfer-runtime-"));
    roots.push(root);
    const downloads = join(root, "downloads");
    const parts = join(root, "parts");
    const stateFilePath = join(root, "state.json");
    await mkdir(downloads);
    const first = await initializeFileTransferRuntime({
      port: 8765,
      bridgeInstanceId: "bridge-test",
      allowedDirs: [root],
      baseUrl: "http://100.64.0.1:8765",
      stateFilePath,
      downloadDirectory: downloads,
      partialDirectory: parts,
    });
    expect(first).toBeDefined();

    const warn = vi.fn();
    const second = await initializeFileTransferRuntime({
      port: 8765,
      bridgeInstanceId: "bridge-test",
      allowedDirs: [root],
      baseUrl: "http://100.64.0.1:8765",
      stateFilePath,
      downloadDirectory: downloads,
      partialDirectory: parts,
      warn,
    });
    expect(second).toBeUndefined();
    expect(warn).toHaveBeenCalledWith(expect.stringContaining("chat remains available"));
    expect(warn).toHaveBeenCalledWith(expect.stringContaining(`${stateFilePath}.lock`));
    expect(warn).toHaveBeenCalledWith(expect.stringContaining("file-transfer status"));
    expect(warn).toHaveBeenCalledWith(expect.stringContaining("file-transfer unlock"));

    const source = join(root, "still-healthy.txt");
    await writeFile(source, "ok");
    await expect(first!.manager.downloadStore.issue(source, { projectPath: root }))
      .resolves.toMatchObject({ entry: { filename: "still-healthy.txt" } });
    await first!.manager.close();
  });

  it("reuses the exact Bridge allowedDirs policy", async () => {
    const root = await mkdtemp(join(tmpdir(), "ccpocket-transfer-runtime-"));
    const outside = await mkdtemp(join(tmpdir(), "ccpocket-transfer-outside-"));
    roots.push(root, outside);
    const downloads = join(root, "downloads");
    await mkdir(downloads);
    const runtime = await initializeFileTransferRuntime({
      port: 8765,
      bridgeInstanceId: "bridge-policy",
      allowedDirs: [root],
      stateFilePath: join(root, "state.json"),
      downloadDirectory: downloads,
      partialDirectory: join(root, "parts"),
    });
    expect(runtime).toBeDefined();
    const source = join(outside, "outside.txt");
    await writeFile(source, "no");
    await expect(runtime!.manager.downloadStore.issue(source, { projectPath: outside }))
      .rejects.toMatchObject({ code: "path_not_allowed" });
    await runtime!.manager.close();
  });

  it("disables only file transfer when its persisted state is oversized", async () => {
    const root = await mkdtemp(join(tmpdir(), "ccpocket-transfer-runtime-"));
    roots.push(root);
    const downloads = join(root, "downloads");
    const stateFilePath = join(root, "state.json");
    await mkdir(downloads);
    await writeFile(stateFilePath, "");
    await truncate(stateFilePath, FILE_TRANSFER_STATE_MAX_BYTES + 1);
    const warn = vi.fn();

    const runtime = await initializeFileTransferRuntime({
      port: 8765,
      bridgeInstanceId: "bridge-oversized-state",
      allowedDirs: [root],
      stateFilePath,
      downloadDirectory: downloads,
      partialDirectory: join(root, "parts"),
      warn,
    });

    expect(runtime).toBeUndefined();
    expect(warn).toHaveBeenCalledWith(expect.stringContaining("chat remains available"));
    expect(warn).toHaveBeenCalledWith(expect.stringContaining("state file exceeds"));
  });

  it("reports a shutdown lock-release failure without blocking Bridge exit", async () => {
    const root = await mkdtemp(join(tmpdir(), "ccpocket-transfer-runtime-"));
    roots.push(root);
    const downloads = join(root, "downloads");
    const stateFilePath = join(root, "state.json");
    await mkdir(downloads);
    const warn = vi.fn();
    const runtime = await initializeFileTransferRuntime({
      port: 8765,
      bridgeInstanceId: "bridge-release-warning",
      allowedDirs: [root],
      stateFilePath,
      downloadDirectory: downloads,
      partialDirectory: join(root, "parts"),
      warn,
    });
    expect(runtime).toBeDefined();

    const lockPath = fileTransferLockPaths(stateFilePath).lockPath;
    await writeFile(join(lockPath, "force-rmdir-failure"), "occupied");
    await expect(runtime!.manager.close()).resolves.toBeUndefined();
    expect(warn).toHaveBeenCalledWith(
      expect.stringContaining("State lock release failed during shutdown"),
    );
    expect(warn).toHaveBeenCalledWith(
      expect.stringContaining("Bridge exit will continue"),
    );
    expect(warn).toHaveBeenCalledWith(expect.stringContaining(lockPath));
  });
});
