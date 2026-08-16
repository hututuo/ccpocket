import { appendFile, chmod, mkdtemp, mkdir, open, readFile, readdir, rm, stat, symlink, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { FileTransferStateStore } from "./file-transfer-state-store.js";
import {
  DIAGNOSTIC_REPORT_PAYLOAD_MAX_BYTES,
  type DiagnosticReportContentPolicy,
} from "./file-transfer-diagnostic.js";
import {
  FileTransferUploadStore,
  fileTransferStatfsAvailable,
  sanitizeFileTransferFilename,
} from "./file-transfer-upload-store.js";

const roots: string[] = [];
const resumeToken = "r".repeat(43);

async function fixture(options: {
  symlinkTarget?: boolean;
  now?: () => number;
  availableBytes?: () => Promise<bigint>;
  maxUploads?: number;
  diagnosticContentPolicy?: DiagnosticReportContentPolicy;
} = {}) {
  const root = await mkdtemp(join(tmpdir(), "ccpocket-transfer-upload-"));
  roots.push(root);
  const realDownloads = join(root, "real-downloads");
  const downloads = options.symlinkTarget ? join(root, "downloads") : realDownloads;
  const parts = join(root, "private-parts");
  await mkdir(realDownloads);
  if (options.symlinkTarget) await symlink(realDownloads, downloads);
  const statePath = join(root, "state.json");
  const state = new FileTransferStateStore({
    filePath: statePath,
    now: options.now,
    maxUploads: options.maxUploads,
  });
  let tokenSequence = 0;
  const store = new FileTransferUploadStore({
    stateStore: state,
    directory: downloads,
    partialDirectory: parts,
    diskSafetyMarginBytes: 0,
    now: options.now,
    availableBytes: options.availableBytes,
    diagnosticContentPolicy: options.diagnosticContentPolicy,
    tokenFactory: () => `${String(++tokenSequence).padStart(43, "a")}`.slice(-43),
  });
  return { root, downloads, realDownloads, parts, statePath, state, store };
}

async function* buffers(...values: Buffer[]): AsyncGenerator<Buffer> {
  for (const value of values) yield value;
}

afterEach(async () => {
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

describe("FileTransferUploadStore v2", () => {
  it("feature-detects statfs without a Node 18.0 static named import", () => {
    expect(fileTransferStatfsAvailable({ statfs: async () => ({}) })).toBe(true);
    expect(fileTransferStatfsAvailable({ statfs: undefined })).toBe(false);
  });

  it("sanitizes one UTF-8 basename and rejects traversal", () => {
    expect(sanitizeFileTransferFilename(" e\u0301\u0001.txt ")).toBe("é_.txt");
    for (const value of ["../a", "a/b", "a\\b", ".", "..", "\0bad"]) {
      expect(() => sanitizeFileTransferFilename(value)).toThrow();
    }
  });

  it("uses a stable Downloads symlink while keeping partials in private storage", async () => {
    const f = await fixture({ symlinkTarget: true });
    const prepared = await f.store.prepare("upload_123456789", resumeToken, "report.txt", 5);
    expect(prepared.status).toBe("ready");
    expect(await readdir(f.realDownloads)).toEqual([]);
    expect((await readdir(f.parts)).filter((name) => name.endsWith(".part"))).toHaveLength(1);
    if (process.platform !== "win32") {
      expect((await stat(f.parts)).mode & 0o777).toBe(0o700);
    }
    await f.state.close();
  });

  it("rejects a partial-directory symlink before changing its target mode", async () => {
    const f = await fixture();
    const victim = join(f.root, "victim-directory");
    await mkdir(victim);
    await chmod(victim, 0o755);
    await symlink(victim, f.parts);
    expect((await stat(victim)).mode & 0o777).toBe(0o755);
    await expect(f.store.init()).rejects.toMatchObject({
      code: "partial_directory_unsafe",
    });
    expect((await stat(victim)).mode & 0o777).toBe(0o755);
    await f.state.close();
  });

  it("makes repeated prepare idempotent after a lost ready response", async () => {
    const f = await fixture();
    const first = await f.store.prepare("upload_123456789", resumeToken, "report.txt", 5);
    const second = await f.store.prepare("upload_123456789", resumeToken, "report.txt", 5);
    expect(first.status).toBe("ready");
    expect(second).toMatchObject({ status: "ready", entry: { offset: 0 } });
    if (first.status === "ready" && second.status === "ready") {
      expect(second.uploadToken).not.toBe(first.uploadToken);
      expect(second.resumeToken).toBe(resumeToken);
    }
    expect((await readdir(f.parts)).filter((name) => name.endsWith(".part"))).toHaveLength(1);
    await f.state.close();
  });

  it("accepts adaptive 1 MiB, 10 MiB, and non-integral chunks with exact offsets", async () => {
    const f = await fixture();
    const oneMiB = Buffer.alloc(1024 * 1024, 1);
    const tenMiB = Buffer.alloc(10 * 1024 * 1024, 2);
    const tail = Buffer.alloc(12_345, 3);
    const total = oneMiB.length + tenMiB.length + tail.length;
    const prepared = await f.store.prepare("upload_123456789", resumeToken, "adaptive.bin", total);
    if (prepared.status !== "ready") throw new Error("expected ready");
    const signal = new AbortController().signal;
    const first = await f.store.append(prepared.entry.transferId, prepared.uploadToken, 0, oneMiB.length, buffers(oneMiB), signal);
    expect(first.entry.offset).toBe(oneMiB.length);
    const second = await f.store.append(prepared.entry.transferId, prepared.uploadToken, first.entry.offset, tenMiB.length, buffers(tenMiB), signal);
    expect(second.entry.offset).toBe(oneMiB.length + tenMiB.length);
    const completed = await f.store.append(prepared.entry.transferId, prepared.uploadToken, second.entry.offset, tail.length, buffers(tail), signal);
    expect(completed).toMatchObject({ completed: true, entry: { status: "complete", offset: total } });
    expect((await readFile(join(f.realDownloads, "adaptive.bin"))).length).toBe(total);
    await f.state.close();
  });

  it("rolls a short or interrupted chunk back to the persisted offset", async () => {
    const f = await fixture();
    const prepared = await f.store.prepare("upload_123456789", resumeToken, "retry.bin", 5);
    if (prepared.status !== "ready") throw new Error("expected ready");
    await expect(f.store.append(
      prepared.entry.transferId,
      prepared.uploadToken,
      0,
      5,
      buffers(Buffer.from("ab")),
      new AbortController().signal,
    )).rejects.toMatchObject({ code: "upload_length_mismatch" });
    await expect(f.store.status(prepared.entry.transferId, prepared.uploadToken))
      .resolves.toMatchObject({ offset: 0 });
    await expect(f.store.append(
      prepared.entry.transferId,
      prepared.uploadToken,
      0,
      5,
      buffers(Buffer.from("hello")),
      new AbortController().signal,
    )).resolves.toMatchObject({ completed: true });
    await f.state.close();
  });

  it("replays a persisted completion tombstone after response loss and restart", async () => {
    const f = await fixture();
    const prepared = await f.store.prepare("upload_123456789", resumeToken, "done.txt", 4);
    if (prepared.status !== "ready") throw new Error("expected ready");
    await f.store.append(
      prepared.entry.transferId,
      prepared.uploadToken,
      0,
      4,
      buffers(Buffer.from("done")),
      new AbortController().signal,
    );
    await f.state.close();

    const restartedState = new FileTransferStateStore({ filePath: f.statePath });
    const restarted = new FileTransferUploadStore({
      stateStore: restartedState,
      directory: f.downloads,
      partialDirectory: f.parts,
      diskSafetyMarginBytes: 0,
    });
    await expect(restarted.prepare("upload_123456789", resumeToken, "done.txt", 4))
      .resolves.toMatchObject({ status: "complete", entry: { finalFilename: "done.txt" } });
    expect(await readFile(join(f.realDownloads, "done.txt"), "utf8")).toBe("done");
    await restartedState.close();
  });

  it("truncates same-inode bytes written after the confirmed offset across restart", async () => {
    const f = await fixture();
    const prepared = await f.store.prepare("upload_killwrite01", resumeToken, "recover.bin", 5);
    if (prepared.status !== "ready" || !prepared.entry.partialPath) throw new Error("expected ready");
    const progress = await f.store.append(
      prepared.entry.transferId,
      prepared.uploadToken,
      0,
      2,
      buffers(Buffer.from("he")),
      new AbortController().signal,
    );
    await f.state.upsertUpload({ ...progress.entry, rollbackPending: true });
    // Simulate process death after kernel writes but before the new offset and
    // identity can be atomically persisted. The pre-write journal was already
    // durable before the request body began.
    await appendFile(progress.entry.partialPath!, "XX");
    expect((await stat(progress.entry.partialPath!)).size).toBe(4);
    await f.state.close();

    const restartedState = new FileTransferStateStore({ filePath: f.statePath });
    const restarted = new FileTransferUploadStore({
      stateStore: restartedState,
      directory: f.downloads,
      partialDirectory: f.parts,
      diskSafetyMarginBytes: 0,
    });
    const resumed = await restarted.prepare(
      prepared.entry.transferId,
      resumeToken,
      "recover.bin",
      5,
    );
    expect(resumed).toMatchObject({ status: "ready", entry: { offset: 2 } });
    if (resumed.status !== "ready" || !resumed.entry.partialPath) throw new Error("expected ready");
    expect((await stat(resumed.entry.partialPath)).size).toBe(2);
    await expect(restarted.append(
      resumed.entry.transferId,
      resumed.uploadToken,
      2,
      3,
      buffers(Buffer.from("llo")),
      new AbortController().signal,
    )).resolves.toMatchObject({ completed: true });
    expect(await readFile(join(f.realDownloads, "recover.bin"), "utf8")).toBe("hello");
    await restartedState.close();
  });

  it("refreshes same-inode identity when kill occurs after rollback fsync but before metadata upsert", async () => {
    const f = await fixture();
    const prepared = await f.store.prepare("upload_killtime001", resumeToken, "time.bin", 5);
    if (prepared.status !== "ready" || !prepared.entry.partialPath) throw new Error("expected ready");
    const progress = await f.store.append(
      prepared.entry.transferId,
      prepared.uploadToken,
      0,
      2,
      buffers(Buffer.from("he")),
      new AbortController().signal,
    );
    await f.state.upsertUpload({
      ...progress.entry,
      rollbackPending: true,
      rollbackTruncating: true,
    });
    const changed = new Date(Date.now() + 5_000);
    await utimes(progress.entry.partialPath!, changed, changed);
    expect((await stat(progress.entry.partialPath!)).size).toBe(progress.entry.offset);
    await f.state.close();

    const restartedState = new FileTransferStateStore({ filePath: f.statePath });
    const restarted = new FileTransferUploadStore({
      stateStore: restartedState,
      directory: f.downloads,
      partialDirectory: f.parts,
      diskSafetyMarginBytes: 0,
    });
    await expect(restarted.prepare(
      prepared.entry.transferId,
      resumeToken,
      "time.bin",
      5,
    )).resolves.toMatchObject({ status: "ready", entry: { offset: 2 } });
    await restartedState.close();
  });

  it("rejects same-inode same-size prefix tampering without a write journal", async () => {
    const f = await fixture();
    const prepared = await f.store.prepare("upload_tamperprefix", resumeToken, "tamper.bin", 5);
    if (prepared.status !== "ready") throw new Error("expected ready");
    const progress = await f.store.append(
      prepared.entry.transferId,
      prepared.uploadToken,
      0,
      2,
      buffers(Buffer.from("he")),
      new AbortController().signal,
    );
    const handle = await open(progress.entry.partialPath!, "r+");
    await handle.write(Buffer.from("XX"), 0, 2, 0);
    await handle.sync();
    await handle.close();
    await f.state.close();

    const restartedState = new FileTransferStateStore({ filePath: f.statePath });
    const restarted = new FileTransferUploadStore({
      stateStore: restartedState,
      directory: f.downloads,
      partialDirectory: f.parts,
      diskSafetyMarginBytes: 0,
    });
    await expect(restarted.prepare(
      prepared.entry.transferId,
      resumeToken,
      "tamper.bin",
      5,
    )).rejects.toMatchObject({ code: "upload_partial_changed" });
    await restartedState.close();
  });

  it("rejects same-size prefix tampering after a first-phase journal but before the first body byte", async () => {
    const f = await fixture();
    const prepared = await f.store.prepare("upload_tamperjournal", resumeToken, "tamper-journal.bin", 5);
    if (prepared.status !== "ready") throw new Error("expected ready");
    const progress = await f.store.append(
      prepared.entry.transferId,
      prepared.uploadToken,
      0,
      2,
      buffers(Buffer.from("he")),
      new AbortController().signal,
    );
    await f.state.upsertUpload({ ...progress.entry, rollbackPending: true });
    const handle = await open(progress.entry.partialPath!, "r+");
    await handle.write(Buffer.from("XX"), 0, 2, 0);
    await handle.sync();
    await handle.close();
    await f.state.close();

    const restartedState = new FileTransferStateStore({ filePath: f.statePath });
    const restarted = new FileTransferUploadStore({
      stateStore: restartedState,
      directory: f.downloads,
      partialDirectory: f.parts,
      diskSafetyMarginBytes: 0,
    });
    await expect(restarted.prepare(
      prepared.entry.transferId,
      resumeToken,
      "tamper-journal.bin",
      5,
    )).rejects.toMatchObject({ code: "upload_partial_changed" });
    await expect(restartedState.getUpload(prepared.entry.transferId)).resolves.toMatchObject({
      rollbackPending: true,
      offset: 2,
    });
    expect((await restartedState.getUpload(prepared.entry.transferId))?.rollbackTruncating)
      .toBeUndefined();
    await restartedState.close();
  });

  it("persists the write journal before consuming a PATCH body and clears it after commit", async () => {
    const f = await fixture();
    const prepared = await f.store.prepare("upload_journal0001", resumeToken, "journal.bin", 2);
    if (prepared.status !== "ready") throw new Error("expected ready");
    async function* observedBody(): AsyncGenerator<Buffer> {
      await expect(f.state.getUpload(prepared.entry.transferId)).resolves.toMatchObject({
        rollbackPending: true,
        rollbackTruncating: undefined,
        offset: 0,
      });
      yield Buffer.from("ok");
    }
    await expect(f.store.append(
      prepared.entry.transferId,
      prepared.uploadToken,
      0,
      2,
      observedBody(),
      new AbortController().signal,
    )).resolves.toMatchObject({ completed: true });
    await expect(f.state.getUpload(prepared.entry.transferId)).resolves.toMatchObject({
      status: "complete",
    });
    expect((await f.state.getUpload(prepared.entry.transferId))?.rollbackPending).toBeUndefined();
    await f.state.close();
  });

  it("clears phase one when the PATCH body throws before writing its first byte", async () => {
    const f = await fixture();
    const prepared = await f.store.prepare("upload_bodythrow001", resumeToken, "body-throw.bin", 2);
    if (prepared.status !== "ready") throw new Error("expected ready");
    async function* failingBody(): AsyncGenerator<Buffer> {
      throw new Error("iterator failed before first byte");
    }
    await expect(f.store.append(
      prepared.entry.transferId,
      prepared.uploadToken,
      0,
      2,
      failingBody(),
      new AbortController().signal,
    )).rejects.toThrow("iterator failed before first byte");
    const retained = await f.state.getUpload(prepared.entry.transferId);
    expect(retained).toMatchObject({ status: "pending", offset: 0 });
    expect(retained?.rollbackPending).toBeUndefined();
    expect(retained?.rollbackTruncating).toBeUndefined();
    await f.state.close();
  });

  it("does not advance phase one when a pre-byte iterator tampers with the confirmed prefix", async () => {
    const f = await fixture();
    const prepared = await f.store.prepare("upload_bodytamper01", resumeToken, "body-tamper.bin", 5);
    if (prepared.status !== "ready") throw new Error("expected ready");
    const progress = await f.store.append(
      prepared.entry.transferId,
      prepared.uploadToken,
      0,
      2,
      buffers(Buffer.from("he")),
      new AbortController().signal,
    );
    async function* tamperingBody(): AsyncGenerator<Buffer> {
      const handle = await open(progress.entry.partialPath!, "r+");
      await handle.write(Buffer.from("XX"), 0, 2, 0);
      await handle.sync();
      await handle.close();
      throw new Error("iterator tampered before first byte");
    }
    await expect(f.store.append(
      prepared.entry.transferId,
      prepared.uploadToken,
      2,
      3,
      tamperingBody(),
      new AbortController().signal,
    )).rejects.toThrow("iterator tampered before first byte");
    const retained = await f.state.getUpload(prepared.entry.transferId);
    expect(retained).toMatchObject({ rollbackPending: true, offset: 2 });
    expect(retained?.rollbackTruncating).toBeUndefined();
    await f.state.close();

    const restartedState = new FileTransferStateStore({ filePath: f.statePath });
    const restarted = new FileTransferUploadStore({
      stateStore: restartedState,
      directory: f.downloads,
      partialDirectory: f.parts,
      diskSafetyMarginBytes: 0,
    });
    await expect(restarted.prepare(
      prepared.entry.transferId,
      resumeToken,
      "body-tamper.bin",
      5,
    )).rejects.toMatchObject({ code: "upload_partial_changed" });
    await restartedState.close();
  });

  it("clears a durable journal when the process died before any body bytes", async () => {
    const f = await fixture();
    const prepared = await f.store.prepare("upload_journal0002", resumeToken, "journal.bin", 2);
    if (prepared.status !== "ready") throw new Error("expected ready");
    await f.state.upsertUpload({ ...prepared.entry, rollbackPending: true });
    await f.state.close();

    const restartedState = new FileTransferStateStore({ filePath: f.statePath });
    const restarted = new FileTransferUploadStore({
      stateStore: restartedState,
      directory: f.downloads,
      partialDirectory: f.parts,
      diskSafetyMarginBytes: 0,
    });
    await expect(restarted.prepare(
      prepared.entry.transferId,
      resumeToken,
      "journal.bin",
      2,
    )).resolves.toMatchObject({ status: "ready", entry: { offset: 0 } });
    expect((await restartedState.getUpload(prepared.entry.transferId))?.rollbackPending)
      .toBeUndefined();
    await restartedState.close();
  });

  it("recovers a zero-byte committing tombstone after final publication save fails", async () => {
    const f = await fixture();
    const originalUpsert = f.state.upsertUpload.bind(f.state);
    let injectFailure = true;
    vi.spyOn(f.state, "upsertUpload").mockImplementation(async (entry) => {
      if (injectFailure && entry.status === "complete") {
        injectFailure = false;
        throw new Error("injected complete save failure");
      }
      await originalUpsert(entry);
    });
    await expect(f.store.prepare(
      "upload_emptycommit",
      resumeToken,
      "empty.bin",
      0,
    )).rejects.toThrow("injected complete save failure");
    expect((await stat(join(f.realDownloads, "empty.bin"))).size).toBe(0);
    await expect(f.state.getUpload("upload_emptycommit")).resolves.toMatchObject({
      status: "committing",
      finalFilename: "empty.bin",
    });
    vi.restoreAllMocks();
    await f.state.close();

    const restartedState = new FileTransferStateStore({ filePath: f.statePath });
    const restarted = new FileTransferUploadStore({
      stateStore: restartedState,
      directory: f.downloads,
      partialDirectory: f.parts,
      diskSafetyMarginBytes: 0,
    });
    await expect(restarted.prepare(
      "upload_emptycommit",
      resumeToken,
      "empty.bin",
      0,
    )).resolves.toMatchObject({
      status: "complete",
      entry: { finalFilename: "empty.bin" },
    });
    expect(await readdir(f.realDownloads)).toEqual(["empty.bin"]);
    await restartedState.close();
  });

  it("renews an expired HTTP upload lease within partial retention", async () => {
    let now = 1_000;
    const f = await fixture({ now: () => now });
    const first = await f.store.prepare("upload_123456789", resumeToken, "lease.bin", 2);
    if (first.status !== "ready") throw new Error("expected ready");
    now = first.entry.expiresAt + 1;
    const resumed = await f.store.prepare("upload_123456789", resumeToken, "lease.bin", 2);
    expect(resumed).toMatchObject({ status: "ready", entry: { offset: 0 } });
    await f.state.close();
  });

  it("cleans expired pending state before capacity checks on a long-running Bridge", async () => {
    let now = 1_000;
    const f = await fixture({ now: () => now, maxUploads: 1 });
    const first = await f.store.prepare("upload_expired001", resumeToken, "old.bin", 5);
    if (first.status !== "ready") throw new Error("expected ready");
    now = first.entry.retainUntil + 1;
    await expect(f.store.prepare(
      "upload_reclaimed01",
      "s".repeat(43),
      "new.bin",
      5,
    )).resolves.toMatchObject({ status: "ready" });
    await expect(f.state.getUpload(first.entry.transferId)).resolves.toBeUndefined();
    expect((await readdir(f.parts)).filter((name) => name.includes(first.entry.transferId)))
      .toEqual([]);
    await f.state.close();
  });

  it("keeps metadata when expired partial cleanup sees a replacement inode", async () => {
    let now = 1_000;
    const f = await fixture({ now: () => now });
    const first = await f.store.prepare("upload_tampered01", resumeToken, "old.bin", 5);
    if (first.status !== "ready" || !first.entry.partialPath) throw new Error("expected ready");
    await rm(first.entry.partialPath);
    await writeFile(first.entry.partialPath, "replacement");
    now = first.entry.retainUntil + 1;
    await expect(f.store.prepare(
      "upload_aftertamper",
      "s".repeat(43),
      "new.bin",
      1,
    )).rejects.toMatchObject({ code: "upload_partial_changed" });
    await expect(f.state.getUpload(first.entry.transferId)).resolves.toBeDefined();
    await f.state.close();
  });

  it("does not replay an expired completion tombstone on a long-running Bridge", async () => {
    let now = 1_000;
    const f = await fixture({ now: () => now, maxUploads: 1 });
    const first = await f.store.prepare("upload_expired002", resumeToken, "done.bin", 1);
    if (first.status !== "ready") throw new Error("expected ready");
    const complete = await f.store.append(
      first.entry.transferId,
      first.uploadToken,
      0,
      1,
      buffers(Buffer.from("x")),
      new AbortController().signal,
    );
    now = complete.entry.retainUntil + 1;
    await expect(f.store.prepare(
      first.entry.transferId,
      resumeToken,
      "done.bin",
      1,
    )).resolves.toMatchObject({ status: "ready", entry: { offset: 0 } });
    await f.state.close();
  });

  it("removes an expired raw diagnostic payload even when no receipt was committed", async () => {
    let now = 1_000;
    const f = await fixture({ now: () => now, maxUploads: 1 });
    const filename = "expired-diagnostic.json";
    const body = Buffer.from("{}");
    const first = await f.store.prepare(
      "upload_expireddiag",
      resumeToken,
      filename,
      body.length,
      {
        purpose: "diagnostic_report",
        diagnosticReport: {
          schemaVersion: 1,
          reportId: "expired-diagnostic",
          provider: "codex",
          providerSessionId: "thread-123",
          bridgeInstanceId: "bridge-test",
          codexSourceId: "source-bridge",
          capturedAtStart: "2026-08-12T00:00:00.000Z",
          capturedAtEnd: "2026-08-12T00:01:00.000Z",
          sha256: "a".repeat(64),
        },
      },
    );
    if (first.status !== "ready") throw new Error("expected ready");
    const complete = await f.store.append(
      first.entry.transferId,
      first.uploadToken,
      0,
      body.length,
      buffers(body),
      new AbortController().signal,
    );
    expect(await readFile(join(f.realDownloads, filename))).toEqual(body);
    now = complete.entry.retainUntil + 1;

    await f.store.prepare(
      "upload_afterdiag01",
      "s".repeat(43),
      "next.bin",
      1,
    );

    await expect(readFile(join(f.realDownloads, filename))).rejects.toMatchObject({
      code: "ENOENT",
    });
    expect(await f.state.getUpload(first.entry.transferId)).toBeUndefined();
    await f.state.close();
  });

  it("cleans an expired diagnostic during receipt lookup so prepare can restart", async () => {
    let now = 1_000;
    const f = await fixture({ now: () => now, maxUploads: 1 });
    const filename = "expired-receipt-lookup.json";
    const body = Buffer.from("{}");
    const diagnosticReport = {
      schemaVersion: 1 as const,
      reportId: "expired-receipt-lookup",
      provider: "codex",
      providerSessionId: "thread-123",
      bridgeInstanceId: "bridge-test",
      codexSourceId: "source-bridge",
      capturedAtStart: "2026-08-12T00:00:00.000Z",
      capturedAtEnd: "2026-08-12T00:01:00.000Z",
      sha256: "a".repeat(64),
    };
    const first = await f.store.prepare(
      "upload_expiredfind",
      resumeToken,
      filename,
      body.length,
      { purpose: "diagnostic_report", diagnosticReport },
    );
    if (first.status !== "ready") throw new Error("expected ready");
    const complete = await f.store.append(
      first.entry.transferId,
      first.uploadToken,
      0,
      body.length,
      buffers(body),
      new AbortController().signal,
    );
    now = complete.entry.retainUntil + 1;

    await expect(f.store.findDiagnosticReceipt(
      first.entry.transferId,
      resumeToken,
      filename,
      body.length,
      { purpose: "diagnostic_report", diagnosticReport },
    )).resolves.toBeUndefined();
    await expect(readFile(join(f.realDownloads, filename))).rejects.toMatchObject({
      code: "ENOENT",
    });
    expect(await f.state.getUpload(first.entry.transferId)).toBeUndefined();
    await expect(f.store.prepare(
      first.entry.transferId,
      resumeToken,
      filename,
      body.length,
      { purpose: "diagnostic_report", diagnosticReport },
    )).resolves.toMatchObject({ status: "ready", entry: { offset: 0 } });
    await f.state.close();
  });

  it("bounds diagnostic staging independently of the generic upload state capacity", async () => {
    const f = await fixture();
    for (let index = 1; index <= 4; index += 1) {
      await expect(f.store.prepare(
        `upload_diaglimit0${index}`,
        String(index).repeat(43),
        `diagnostic-${index}.json`,
        DIAGNOSTIC_REPORT_PAYLOAD_MAX_BYTES,
        {
          purpose: "diagnostic_report",
          diagnosticReport: {
            schemaVersion: 1,
            reportId: `diagnostic-limit-${index}`,
            provider: "codex",
            providerSessionId: `thread-${index}`,
            bridgeInstanceId: "bridge-test",
            codexSourceId: "source-bridge",
            capturedAtStart: "2026-08-12T00:00:00.000Z",
            capturedAtEnd: "2026-08-12T00:01:00.000Z",
            sha256: String(index).repeat(64),
          },
        },
      )).resolves.toMatchObject({ status: "ready" });
    }
    await expect(f.store.prepare(
      "upload_diaglimit05",
      "5".repeat(43),
      "diagnostic-5.json",
      1,
      {
        purpose: "diagnostic_report",
        diagnosticReport: {
          schemaVersion: 1,
          reportId: "diagnostic-limit-5",
          provider: "codex",
          providerSessionId: "thread-5",
          bridgeInstanceId: "bridge-test",
          codexSourceId: "source-bridge",
          capturedAtStart: "2026-08-12T00:00:00.000Z",
          capturedAtEnd: "2026-08-12T00:01:00.000Z",
          sha256: "5".repeat(64),
        },
      },
    )).rejects.toMatchObject({ code: "diagnostic_staging_limit" });
    await f.state.close();
  });

  it("rejects credential-bearing diagnostic metadata before checkpoint persistence", async () => {
    const f = await fixture();
    await expect(f.store.prepare(
      "upload_diagsecret1",
      "s".repeat(43),
      "diagnostic-secret.json",
      1,
      {
        purpose: "diagnostic_report",
        diagnosticReport: {
          schemaVersion: 1,
          reportId: "diagnostic-secret",
          provider: "codex",
          providerSessionId: "AWS_ACCESS_KEY_ID=ASIAABCDEFGHIJKLMNOP",
          bridgeInstanceId: "bridge-test",
          codexSourceId: "source-bridge",
          capturedAtStart: "2026-08-12T00:00:00.000Z",
          capturedAtEnd: "2026-08-12T00:01:00.000Z",
          sha256: "a".repeat(64),
        },
      },
    )).rejects.toMatchObject({ code: "diagnostic_sensitive_field" });
    expect(await f.state.getUpload("upload_diagsecret1")).toBeUndefined();
    await f.state.close();
  });

  it("accepts full-fidelity diagnostic metadata only in development policy", async () => {
    const f = await fixture({
      diagnosticContentPolicy: "development_full_fidelity",
    });
    const prepared = await f.store.prepare(
      "upload_diagdev001",
      "d".repeat(43),
      "diagnostic-development.json",
      1,
      {
        purpose: "diagnostic_report",
        diagnosticReport: {
          schemaVersion: 1,
          reportId: "diagnostic-development",
          provider: "codex",
          providerSessionId: "AWS_ACCESS_KEY_ID=ASIAABCDEFGHIJKLMNOP",
          bridgeInstanceId: "bridge-test",
          codexSourceId: "source-bridge",
          capturedAtStart: "2026-08-12T00:00:00.000Z",
          capturedAtEnd: "2026-08-12T00:01:00.000Z",
          sha256: "a".repeat(64),
        },
      },
    );
    expect(prepared.status).toBe("ready");
    expect(await f.state.getUpload("upload_diagdev001")).toBeDefined();
    await f.state.close();
  });

  it("serializes reservations so concurrent sessions cannot oversell free space", async () => {
    const f = await fixture({ availableBytes: async () => 100n });
    const results = await Promise.allSettled([
      f.store.prepare("upload_123456789", "x".repeat(43), "a.bin", 60),
      f.store.prepare("upload_876543219", "y".repeat(43), "b.bin", 60),
    ]);
    expect(results.filter((result) => result.status === "fulfilled")).toHaveLength(1);
    const rejected = results.find((result) => result.status === "rejected");
    expect(rejected).toMatchObject({ reason: { code: "insufficient_storage" } });
    await f.state.close();
  });

  it("rejects a Downloads symlink retarget across Bridge restart", async () => {
    const f = await fixture({ symlinkTarget: true });
    await f.store.prepare("upload_retarget01", resumeToken, "pending.bin", 5);
    await f.state.close();
    const replacement = join(f.root, "replacement");
    await mkdir(replacement);
    await rm(f.downloads);
    await symlink(replacement, f.downloads);
    const restartedState = new FileTransferStateStore({ filePath: f.statePath });
    const restarted = new FileTransferUploadStore({
      stateStore: restartedState,
      directory: f.downloads,
      partialDirectory: f.parts,
      diskSafetyMarginBytes: 0,
    });
    await expect(restarted.init()).rejects.toMatchObject({ code: "transfer_directory_changed" });
    await restartedState.close();
  });

  it("safely rebinds directory identity when no upload is pending or committing", async () => {
    const f = await fixture({ symlinkTarget: true });
    await f.store.init();
    await f.state.close();
    const replacement = join(f.root, "replacement-complete-only");
    await mkdir(replacement);
    await rm(f.downloads);
    await symlink(replacement, f.downloads);
    const restartedState = new FileTransferStateStore({ filePath: f.statePath });
    const restarted = new FileTransferUploadStore({
      stateStore: restartedState,
      directory: f.downloads,
      partialDirectory: f.parts,
      diskSafetyMarginBytes: 0,
    });
    await expect(restarted.init()).resolves.toBeUndefined();
    await restartedState.close();
  });

  it("cancels only pending state and never deletes a completed final file", async () => {
    const f = await fixture();
    await f.store.prepare("upload_123456789", resumeToken, "pending.bin", 4);
    await f.store.cancel("upload_123456789", resumeToken);
    expect((await readdir(f.parts)).filter((name) => name.endsWith(".part"))).toEqual([]);

    const prepared = await f.store.prepare("upload_876543219", "s".repeat(43), "final.bin", 1);
    if (prepared.status !== "ready") throw new Error("expected ready");
    await f.store.append(prepared.entry.transferId, prepared.uploadToken, 0, 1, buffers(Buffer.from("x")), new AbortController().signal);
    await expect(f.store.cancel("upload_876543219", "s".repeat(43)))
      .rejects.toMatchObject({ code: "upload_already_complete" });
    expect(await readFile(join(f.realDownloads, "final.bin"), "utf8")).toBe("x");
    await f.state.close();
  });
});
