import { mkdir, mkdtemp, readFile, rm, symlink, truncate, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { hashTransferSecret } from "./file-transfer-download-store.js";
import { FILE_TRANSFER_MAX_FILE_SIZE_BYTES } from "./file-transfer-constants.js";
import { DIAGNOSTIC_REPORT_PAYLOAD_MAX_BYTES } from "./file-transfer-diagnostic.js";
import {
  FILE_TRANSFER_STATE_MAX_BYTES,
  FileTransferStateStore,
  fileTransferLockPaths,
  fileTransferStateFile,
  inspectFileTransferLock,
  unlockFileTransferLock,
  type PersistedDownloadTransfer,
} from "./file-transfer-state-store.js";

const roots: string[] = [];
const token = "a".repeat(43);

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "ccpocket-transfer-state-"));
  roots.push(root);
  return { root, filePath: join(root, "state.json") };
}

function download(id: string, now = 1_000): PersistedDownloadTransfer {
  return {
    transferId: id,
    tokenHash: hashTransferSecret(token),
    etag: `"${"e".repeat(32)}"`,
    canonicalPath: "/private/source",
    filename: "source.bin",
    mimeType: "application/octet-stream",
    sizeBytes: 1,
    identity: { dev: 1, ino: 2, size: 1, mtimeMs: 3, ctimeMs: 4 },
    createdAt: now,
    expiresAt: now + 100,
    retainUntil: now + 1_000,
  };
}

afterEach(async () => {
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

describe("FileTransferStateStore", () => {
  it("uses stable Bridge identity instead of port when one is available", () => {
    expect(fileTransferStateFile(8765, undefined, "stable-bridge"))
      .toBe(fileTransferStateFile(9876, undefined, "stable-bridge"));
    expect(fileTransferStateFile(9876)).not.toBe(fileTransferStateFile(9877));
  });

  it("persists only secret hashes and recovers metadata after a clean restart", async () => {
    const f = await fixture();
    const first = new FileTransferStateStore({ filePath: f.filePath, now: () => 1_000 });
    await first.upsertDownload(download("download_1234567"));
    await first.close();

    const raw = await readFile(f.filePath, "utf8");
    expect(raw).not.toContain(token);
    expect(raw).toContain(hashTransferSecret(token));

    const second = new FileTransferStateStore({ filePath: f.filePath, now: () => 1_000 });
    await expect(second.getDownload("download_1234567")).resolves.toMatchObject({
      filename: "source.bin",
    });
    await second.close();
  });

  it("uses an exclusive lifetime process lock", async () => {
    const f = await fixture();
    const first = new FileTransferStateStore({ filePath: f.filePath });
    const second = new FileTransferStateStore({ filePath: f.filePath });
    await first.init();
    await expect(inspectFileTransferLock(f.filePath)).resolves.toMatchObject({
      locked: true,
      owner: { pid: process.pid },
      ownerAlive: true,
      recoverable: false,
    });
    await expect(unlockFileTransferLock(f.filePath)).rejects.toThrow("still alive");
    await expect(second.init()).rejects.toThrow("Another Bridge process");
    await first.close();
    await expect(second.init()).resolves.toBeUndefined();
    await second.close();
  });

  it("fails closed on an unclean-exit lock instead of racing stale reclamation", async () => {
    const f = await fixture();
    await mkdir(`${f.filePath}.lock`);
    const store = new FileTransferStateStore({ filePath: f.filePath });
    await expect(store.init()).rejects.toThrow("manual recovery");
    await expect(unlockFileTransferLock(f.filePath)).rejects.toThrow("metadata is missing");
    await store.close();
    await rm(`${f.filePath}.lock`, { recursive: true });
    await expect(store.init()).resolves.toBeUndefined();
    await store.close();
  });

  it("explicitly unlocks only a lock with verified dead-owner metadata", async () => {
    const f = await fixture();
    const paths = fileTransferLockPaths(f.filePath);
    await mkdir(paths.lockPath);
    await writeFile(paths.ownerPath, JSON.stringify({
      version: 1,
      nonce: "00000000-0000-4000-8000-000000000001",
      pid: 2_147_483_647,
      processStartedAt: "2020-01-01T00:00:00.000Z",
      acquiredAt: "2020-01-01T00:00:01.000Z",
      ownerId: "dead-bridge",
    }));
    await expect(inspectFileTransferLock(f.filePath)).resolves.toMatchObject({
      locked: true,
      ownerAlive: false,
      recoverable: true,
      owner: { ownerId: "dead-bridge" },
    });
    await expect(unlockFileTransferLock(f.filePath)).resolves.toMatchObject({
      locked: false,
      reason: "Verified dead-owner lock removed",
    });
    await expect(inspectFileTransferLock(f.filePath)).resolves.toMatchObject({
      locked: false,
    });
  });

  it("rejects symbolic-link lock owner metadata", async () => {
    const f = await fixture();
    const paths = fileTransferLockPaths(f.filePath);
    const target = join(f.root, "owner-target.json");
    await mkdir(paths.lockPath);
    await writeFile(target, JSON.stringify({
      version: 1,
      nonce: "00000000-0000-4000-8000-000000000001",
      pid: 2_147_483_647,
      processStartedAt: "2020-01-01T00:00:00.000Z",
      acquiredAt: "2020-01-01T00:00:01.000Z",
    }));
    await symlink(target, paths.ownerPath);

    const inspection = await inspectFileTransferLock(f.filePath);
    expect(inspection).toMatchObject({
      locked: true,
      recoverable: false,
      reason: expect.stringContaining("metadata is missing or invalid"),
    });
    expect(inspection).not.toHaveProperty("owner");
    await expect(unlockFileTransferLock(f.filePath)).rejects.toThrow(
      "metadata is missing or invalid",
    );
  });

  it("rejects lock owner metadata larger than 64 KiB", async () => {
    const f = await fixture();
    const paths = fileTransferLockPaths(f.filePath);
    await mkdir(paths.lockPath);
    await writeFile(paths.ownerPath, "");
    await truncate(paths.ownerPath, 64 * 1024 + 1);

    const inspection = await inspectFileTransferLock(f.filePath);
    expect(inspection).toMatchObject({
      locked: true,
      recoverable: false,
      reason: expect.stringContaining("metadata is missing or invalid"),
    });
    expect(inspection).not.toHaveProperty("owner");
  });

  it("surfaces an orphaned recovery claim instead of reporting an ordinary unlocked state", async () => {
    const f = await fixture();
    const paths = fileTransferLockPaths(f.filePath);
    await mkdir(paths.recoveryPath);
    await expect(inspectFileTransferLock(f.filePath)).resolves.toMatchObject({
      locked: false,
      recoveryInProgress: true,
      recoverable: false,
      reason: expect.stringContaining("recovery claim exists"),
    });
    const store = new FileTransferStateStore({ filePath: f.filePath });
    await expect(store.init()).rejects.toThrow("recovery is in progress");
    await store.close();
  });

  it("rejects a symlink state file", async () => {
    const f = await fixture();
    const target = join(f.root, "target.json");
    await writeFile(target, JSON.stringify({ version: 2, downloads: [], uploads: [] }));
    await symlink(target, f.filePath);
    const store = new FileTransferStateStore({ filePath: f.filePath });
    await expect(store.init()).rejects.toThrow("regular file");
    await store.close();
  });

  it("rejects an oversized state file before reading its contents", async () => {
    const f = await fixture();
    await writeFile(f.filePath, "");
    await truncate(f.filePath, FILE_TRANSFER_STATE_MAX_BYTES + 1);
    const store = new FileTransferStateStore({ filePath: f.filePath });
    await expect(store.init()).rejects.toThrow("state file exceeds");
    await store.close();
  });

  it("rejects persisted transfer sizes above the 15 GiB product limit", async () => {
    const f = await fixture();
    const entry = download("download_1234567");
    entry.sizeBytes = FILE_TRANSFER_MAX_FILE_SIZE_BYTES + 1;
    entry.identity.size = entry.sizeBytes;
    await writeFile(f.filePath, JSON.stringify({
      version: 2,
      downloads: [entry],
      uploads: [],
    }));
    const store = new FileTransferStateStore({ filePath: f.filePath });
    await expect(store.init()).rejects.toThrow("invalid transfer metadata");
    await store.close();
  });

  it("rejects a persisted diagnostic upload above its 16 MiB purpose limit", async () => {
    const f = await fixture();
    const sizeBytes = DIAGNOSTIC_REPORT_PAYLOAD_MAX_BYTES + 1;
    await writeFile(f.filePath, JSON.stringify({
      version: 2,
      downloads: [],
      uploads: [{
        transferId: "upload_oversizeddiag",
        uploadTokenHash: hashTransferSecret(token),
        resumeTokenHash: hashTransferSecret("r".repeat(43)),
        filename: "oversized-diagnostic.json",
        sizeBytes,
        offset: 0,
        status: "pending",
        partialPath: "/private/tmp/oversized-diagnostic.part",
        partialIdentity: {
          dev: 1,
          ino: 2,
          size: 0,
          mtimeMs: 3,
          ctimeMs: 4,
        },
        createdAt: 1_000,
        updatedAt: 1_000,
        expiresAt: 2_000,
        retainUntil: 3_000,
        purpose: "diagnostic_report",
        diagnosticReport: {
          schemaVersion: 1,
          reportId: "oversized-diagnostic",
          provider: "codex",
          providerSessionId: "thread-123",
          bridgeInstanceId: "bridge-test",
          codexSourceId: "source-bridge",
          capturedAtStart: "2026-08-12T00:00:00.000Z",
          capturedAtEnd: "2026-08-12T00:01:00.000Z",
          sha256: "a".repeat(64),
        },
      }],
    }));
    const store = new FileTransferStateStore({ filePath: f.filePath });
    await expect(store.init()).rejects.toThrow("invalid transfer metadata");
    await store.close();
  });

  it.each([
    ["embedded NUL", "bad\0name.bin"],
    ["an overlong name", "x".repeat(1_025)],
  ])("rejects persisted filenames containing %s", async (_label, filename) => {
    const f = await fixture();
    const entry = { ...download("download_1234567"), filename };
    await writeFile(f.filePath, JSON.stringify({
      version: 2,
      downloads: [entry],
      uploads: [],
    }));
    const store = new FileTransferStateStore({ filePath: f.filePath });
    await expect(store.init()).rejects.toThrow("invalid transfer metadata");
    await store.close();
  });

  it("fails closed at capacity instead of evicting an unexpired download", async () => {
    const f = await fixture();
    const store = new FileTransferStateStore({
      filePath: f.filePath,
      maxDownloads: 1,
      now: () => 1_000,
    });
    await store.upsertDownload(download("download_1234567"));
    await expect(store.upsertDownload(download("download_7654321")))
      .rejects.toThrow("capacity");
    await expect(store.getDownload("download_1234567")).resolves.toBeDefined();
    await store.close();
  });
});
