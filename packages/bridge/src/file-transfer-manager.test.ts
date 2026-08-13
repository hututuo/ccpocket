import { mkdtemp, mkdir, readFile, rm, unlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { FileTransferDownloadStore } from "./file-transfer-download-store.js";
import {
  FileMutationAuthorizer,
  FileMutationAuthStore,
} from "./file-mutation-auth.js";
import {
  FileTransferManager,
  type FileTransferClientBinding,
} from "./file-transfer-manager.js";
import type { FileTransferServerMessage } from "./file-transfer-protocol.js";
import { FileTransferStateStore } from "./file-transfer-state-store.js";
import { FileTransferUploadStore } from "./file-transfer-upload-store.js";
import { DiagnosticReportArchiver } from "./file-transfer-diagnostic.js";
import { createHash } from "node:crypto";
import { FileTransferError } from "./file-transfer-errors.js";

const roots: string[] = [];
const managers: FileTransferManager[] = [];
const resumeToken = "r".repeat(43);

interface Fixture {
  root: string;
  source: string;
  state: FileTransferStateStore;
  downloadStore: FileTransferDownloadStore;
  uploadStore: FileTransferUploadStore;
  manager: FileTransferManager;
  reports: string;
}

async function fixture(options: {
  now?: () => number;
  maxChunkSizeBytes?: number;
  mutationPassword?: string;
  withoutMutationAuthorizer?: boolean;
  allowDiagnosticWithoutMutationAuthorization?: boolean;
} = {}): Promise<Fixture> {
  const root = await mkdtemp(join(tmpdir(), "ccpocket-transfer-manager-"));
  roots.push(root);
  const source = join(root, "report.pdf");
  const downloads = join(root, "downloads");
  const parts = join(root, "parts");
  const reports = join(root, "reports");
  await writeFile(source, "source");
  await mkdir(downloads);
  let idSequence = 0;
  let tokenSequence = 0;
  let etagSequence = 0;
  const state = new FileTransferStateStore({
    filePath: join(root, "state.json"),
    now: options.now,
  });
  const downloadStore = new FileTransferDownloadStore({
    stateStore: state,
    allowedDirs: [root],
    now: options.now,
    transferIdFactory: () => `download_${String(++idSequence).padStart(8, "0")}`,
    tokenFactory: () => `${String(++tokenSequence).padStart(43, "d")}`.slice(-43),
    etagFactory: () => `"${String(++etagSequence).padStart(32, "e")}"`,
  });
  const uploadStore = new FileTransferUploadStore({
    stateStore: state,
    directory: downloads,
    partialDirectory: parts,
    diskSafetyMarginBytes: 0,
    now: options.now,
    maxChunkSizeBytes: options.maxChunkSizeBytes,
    tokenFactory: () => `${String(++tokenSequence).padStart(43, "u")}`.slice(-43),
  });
  let fileMutationAuthorizer: FileMutationAuthorizer | undefined;
  if (!options.withoutMutationAuthorizer) {
    const authStore = new FileMutationAuthStore({
      filePath: join(root, "file-mutation-auth.json"),
    });
    if (options.mutationPassword !== undefined) {
      await authStore.setPassword(options.mutationPassword);
    }
    fileMutationAuthorizer = new FileMutationAuthorizer({
      store: authStore,
      bridgeInstanceId: "bridge-test",
    });
    if (options.mutationPassword === undefined) {
      vi.spyOn(fileMutationAuthorizer, "authorize").mockResolvedValue();
    }
  }
  const manager = new FileTransferManager({
    downloadStore,
    uploadStore,
    baseUrl: "http://100.64.0.1:8765",
    fileMutationAuthorizer,
    diagnosticReportArchiver: new DiagnosticReportArchiver({
      reportsDirectory: reports,
      bridgeInstanceId: "bridge-test",
      codexSourceId: "source-bridge",
      bridgeVersion: "1.69.6-test",
      getRuntimeStates: () => [{
        bridgeSessionId: "bridge-session",
        provider: "codex",
        providerSessionId: "thread-diagnostic",
        projectPath: root,
        processStatus: "running",
        executionHost: "bridge",
        controlState: "writable",
        authorityGeneration: "generation-1",
        activeTurnId: "turn-1",
        observedAt: "2026-08-12T00:02:00.000Z",
      }],
    }),
    allowDiagnosticWithoutMutationAuthorization:
      options.allowDiagnosticWithoutMutationAuthorization,
  });
  await manager.init();
  managers.push(manager);
  return { root, source, state, downloadStore, uploadStore, manager, reports };
}

function binding(
  supported: string[],
  httpBaseUrl = "http://100.64.0.1:8765",
) {
  const messages: FileTransferServerMessage[] = [];
  let open = true;
  const value: FileTransferClientBinding = {
    supports: (type) => supported.includes(type),
    isOpen: () => open,
    send: (message) => {
      if (!open) return false;
      messages.push(message);
      return true;
    },
    httpBaseUrl,
  };
  return { binding: value, messages, close: () => { open = false; } };
}

async function* chunks(...values: string[]): AsyncGenerator<Buffer> {
  for (const value of values) yield Buffer.from(value);
}

afterEach(async () => {
  await Promise.all(managers.splice(0).map((manager) => manager.close()));
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

describe("FileTransferManager v2", () => {
  it("fails closed with zero or multiple compatible recipients without issuing a file", async () => {
    const f = await fixture();
    await expect(f.manager.offerFile({ filePath: f.source, projectPath: f.root }))
      .rejects.toMatchObject({ code: "no_compatible_phone" });
    expect(await f.state.listDownloads()).toEqual([]);

    f.manager.connect({}, binding(["file_transfer_offer_v2"]).binding);
    f.manager.connect({}, binding(["file_transfer_offer_v2"]).binding);
    await expect(f.manager.offerFile({ filePath: f.source, projectPath: f.root }))
      .rejects.toMatchObject({ code: "multiple_compatible_phones" });
    expect(await f.state.listDownloads()).toEqual([]);
  });

  it("offers one persistent capability only to the v2-compatible phone", async () => {
    const f = await fixture();
    const oldPhone = binding([]);
    const phone = binding(["file_transfer_offer_v2"]);
    f.manager.connect({}, oldPhone.binding);
    f.manager.connect({}, phone.binding);

    await expect(f.manager.offerFile({
      filePath: f.source,
      projectPath: f.root,
      ttlSeconds: 600,
    })).resolves.toMatchObject({
      status: "offered",
      transferId: "download_00000001",
      recipientCount: 1,
      filename: "report.pdf",
      sizeBytes: 6,
    });
    expect(oldPhone.messages).toEqual([]);
    expect(phone.messages).toEqual([expect.objectContaining({
      type: "file_transfer_offer_v2",
      transferId: "download_00000001",
      filename: "report.pdf",
      sizeBytes: 6,
      downloadUrl: "http://100.64.0.1:8765/api/file-transfers/downloads/download_00000001",
      downloadToken: expect.stringMatching(/^[A-Za-z0-9_-]{43}$/),
      etag: expect.stringMatching(/^"[A-Za-z0-9_-]{32}"$/),
    })]);
  });

  it("offers a browser download only to the phone that requested it", async () => {
    const f = await fixture();
    const firstClient = {};
    const secondClient = {};
    const firstPhone = binding(["file_transfer_offer_v2"]);
    const secondPhone = binding(["file_transfer_offer_v2"]);
    f.manager.connect(firstClient, firstPhone.binding);
    f.manager.connect(secondClient, secondPhone.binding);

    await expect(f.manager.offerFileToClient(secondClient, {
      filePath: f.source,
      projectPath: f.root,
      ttlSeconds: 600,
    })).resolves.toMatchObject({
      status: "offered",
      transferId: "download_00000001",
      recipientCount: 1,
    });
    expect(firstPhone.messages).toEqual([]);
    expect(secondPhone.messages).toEqual([
      expect.objectContaining({
        type: "file_transfer_offer_v2",
        transferId: "download_00000001",
      }),
    ]);
  });

  it("rejects a targeted offer when that phone is incompatible", async () => {
    const f = await fixture();
    const client = {};
    f.manager.connect(client, binding([]).binding);

    await expect(f.manager.offerFileToClient(client, {
      filePath: f.source,
      projectPath: f.root,
    })).rejects.toMatchObject({ code: "recipient_incompatible" });
    expect(await f.state.listDownloads()).toEqual([]);
  });

  it("rejects a CLI base-url override that differs from the current WS HTTP origin", async () => {
    const f = await fixture();
    f.manager.connect({}, binding(["file_transfer_offer_v2"]).binding);
    await expect(f.manager.offerFile({
      filePath: f.source,
      projectPath: f.root,
      baseUrl: "http://100.64.0.2:8765",
    })).rejects.toMatchObject({ code: "transfer_base_url_mismatch" });
    expect(await f.state.listDownloads()).toEqual([]);
    await expect(f.manager.offerFile({
      filePath: f.source,
      projectPath: f.root,
      baseUrl: "http://100.64.0.1:8765/",
    })).resolves.toMatchObject({ status: "offered" });
  });

  it("prefers the authenticated peer origin over a different auto-detected global address", async () => {
    const f = await fixture();
    const peer = binding(["file_transfer_offer_v2"], "http://100.104.72.123:8765");
    f.manager.connect({}, peer.binding);
    await expect(f.manager.offerFile({
      filePath: f.source,
      projectPath: f.root,
    })).resolves.toMatchObject({ status: "offered" });
    expect(peer.messages[0]).toMatchObject({
      type: "file_transfer_offer_v2",
      downloadUrl: "http://100.104.72.123:8765/api/file-transfers/downloads/download_00000001",
    });
  });

  it("uses the authenticated phone-side loopback origin for an SSH local tunnel", async () => {
    const f = await fixture();
    const peer = binding(["file_transfer_offer_v2"], "http://127.0.0.1:18765");
    f.manager.connect({}, peer.binding);
    await expect(f.manager.offerFile({
      filePath: f.source,
      projectPath: f.root,
    })).resolves.toMatchObject({ status: "offered" });
    expect(peer.messages[0]).toMatchObject({
      type: "file_transfer_offer_v2",
      downloadUrl: "http://127.0.0.1:18765/api/file-transfers/downloads/download_00000001",
    });
  });

  it("rechecks the unique recipient after asynchronous source inspection", async () => {
    const f = await fixture();
    const issued = await f.downloadStore.issue(f.source, { projectPath: f.root });
    await f.downloadStore.remove(issued.entry.transferId);
    let release!: () => void;
    const gate = new Promise<void>((resolve) => { release = resolve; });
    vi.spyOn(f.downloadStore, "issue").mockImplementation(async () => {
      await gate;
      await f.state.upsertDownload(issued.entry);
      return issued;
    });
    const first = binding(["file_transfer_offer_v2"]);
    f.manager.connect({}, first.binding);
    const pending = f.manager.offerFile({ filePath: f.source, projectPath: f.root });
    await vi.waitFor(() => expect(f.downloadStore.issue).toHaveBeenCalledOnce());
    const second = binding(["file_transfer_offer_v2"]);
    f.manager.connect({}, second.binding);
    release();
    await expect(pending).rejects.toMatchObject({ code: "multiple_compatible_phones" });
    expect(first.messages).toEqual([]);
    expect(second.messages).toEqual([]);
    expect(await f.state.getDownload(issued.entry.transferId)).toBeUndefined();
  });

  it("drains a targeted offer before close releases persistent transfer state", async () => {
    const f = await fixture();
    const client = {};
    f.manager.connect(client, binding(["file_transfer_offer_v2"]).binding);
    const originalIssue = f.downloadStore.issue.bind(f.downloadStore);
    let entered!: () => void;
    const started = new Promise<void>((resolve) => {
      entered = resolve;
    });
    let release!: () => void;
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    vi.spyOn(f.downloadStore, "issue").mockImplementation(
      async (filePath, options) => {
        entered();
        await gate;
        return originalIssue(filePath, options);
      },
    );

    const pending = f.manager.offerFileToClient(client, {
      filePath: f.source,
      projectPath: f.root,
    });
    const outcome = pending.catch((error: unknown) => error);
    await started;
    let closeResolved = false;
    const closing = f.manager.close().then(() => {
      closeResolved = true;
    });
    await Promise.resolve();
    expect(closeResolved).toBe(false);

    release();
    await expect(outcome).resolves.toMatchObject({
      code: "transfer_shutting_down",
    });
    await closing;
    expect(
      (JSON.parse(await readFile(join(f.root, "state.json"), "utf8")) as {
        downloads: unknown[];
      }).downloads,
    ).toEqual([]);
    await expect(
      f.manager.offerFileToClient(client, {
        filePath: f.source,
        projectPath: f.root,
      }),
    ).rejects.toMatchObject({ code: "transfer_shutting_down" });
  });

  it("prepares a mobile-owned upload identity and advertises the actual store chunk limit", async () => {
    const f = await fixture({ maxChunkSizeBytes: 10 * 1024 * 1024 });
    const client = {};
    const phone = binding([
      "file_transfer_upload_ready_v2",
      "file_transfer_upload_result_v2",
    ]);
    f.manager.connect(client, phone.binding);
    await f.manager.handleClientMessage(client, {
      type: "file_transfer_upload_prepare_v2",
      requestId: "request-1",
      transferId: "upload_123456789",
      resumeToken,
      filename: "from phone.txt",
      sizeBytes: 5,
    });
    const ready = phone.messages[0];
    expect(ready).toMatchObject({
      type: "file_transfer_upload_ready_v2",
      requestId: "request-1",
      transferId: "upload_123456789",
      uploadOffset: 0,
      sizeBytes: 5,
      maxChunkSizeBytes: 10 * 1024 * 1024,
      uploadUrl: "http://100.64.0.1:8765/api/file-transfers/uploads/upload_123456789",
    });
    if (ready.type !== "file_transfer_upload_ready_v2") throw new Error("expected ready");
    await f.manager.appendUpload(
      ready.transferId,
      ready.uploadToken,
      0,
      5,
      chunks("he", "llo"),
      new AbortController().signal,
    );
    expect(phone.messages[1]).toEqual({
      type: "file_transfer_upload_result_v2",
      requestId: "request-1",
      transferId: "upload_123456789",
      success: true,
      filename: "from phone.txt",
      sizeBytes: 5,
    });
  });

  it("keeps downloads available but rejects every upload without an authorizer", async () => {
    const f = await fixture({ withoutMutationAuthorizer: true });
    const client = {};
    const phone = binding([
      "file_transfer_offer_v2",
      "file_transfer_upload_ready_v2",
      "file_transfer_upload_result_v2",
    ]);
    f.manager.connect(client, phone.binding);

    await f.manager.handleClientMessage(client, {
      type: "file_transfer_upload_prepare_v2",
      requestId: "locked-upload",
      transferId: "upload_locked001",
      resumeToken,
      filename: "blocked.txt",
      sizeBytes: 1,
    });

    expect(phone.messages).toEqual([
      expect.objectContaining({
        type: "file_transfer_upload_result_v2",
        requestId: "locked-upload",
        transferId: "upload_locked001",
        success: false,
        errorCode: "unsupported_capability",
      }),
    ]);
    expect(await f.state.listUploads()).toEqual([]);

    await expect(
      f.manager.offerFile({ filePath: f.source, projectPath: f.root }),
    ).resolves.toMatchObject({ status: "offered" });
    expect(phone.messages.at(-1)).toMatchObject({
      type: "file_transfer_offer_v2",
      filename: "report.pdf",
    });
  });

  it("requires an operation-bound step-up proof and revokes it on reconnect", async () => {
    const credential = ["correct", "horse", "battery", "staple"].join("-");
    const f = await fixture({ mutationPassword: credential });
    const client = {};
    const phone = binding([
      "file_transfer_upload_ready_v2",
      "file_transfer_upload_result_v2",
    ]);
    f.manager.connect(client, phone.binding);
    const prepare = {
      type: "file_transfer_upload_prepare_v2" as const,
      requestId: "auth-request-1",
      transferId: "upload_auth00001",
      resumeToken,
      filename: "approved.txt",
      sizeBytes: 5,
    };

    await f.manager.handleClientMessage(client, prepare);
    expect(phone.messages.pop()).toMatchObject({
      type: "file_transfer_upload_result_v2",
      success: false,
      errorCode: "step_up_required",
    });
    expect(await f.state.listUploads()).toEqual([]);

    await f.manager.handleClientMessage(client, {
      ...prepare,
      requestId: "auth-request-2",
      mutationAuthorization: {
        method: "password",
        password: ["wrong", "credential"].join("-"),
      },
    });
    expect(phone.messages.pop()).toMatchObject({
      type: "file_transfer_upload_result_v2",
      success: false,
      errorCode: "invalid_password",
    });

    await f.manager.handleClientMessage(client, {
      ...prepare,
      requestId: "auth-request-3",
      mutationAuthorization: { method: "password", password: credential },
    });
    expect(phone.messages.pop()).toMatchObject({
      type: "file_transfer_upload_ready_v2",
      requestId: "auth-request-3",
      transferId: prepare.transferId,
    });

    await f.manager.handleClientMessage(client, {
      ...prepare,
      requestId: "auth-request-4",
      filename: "different.txt",
    });
    expect(phone.messages.pop()).toMatchObject({
      type: "file_transfer_upload_result_v2",
      success: false,
      errorCode: "step_up_required",
    });

    f.manager.disconnect(client);
    const nextClient = {};
    const nextPhone = binding([
      "file_transfer_upload_ready_v2",
      "file_transfer_upload_result_v2",
    ]);
    f.manager.connect(nextClient, nextPhone.binding);
    await f.manager.handleClientMessage(nextClient, {
      ...prepare,
      requestId: "auth-request-5",
    });
    expect(nextPhone.messages).toEqual([
      expect.objectContaining({
        type: "file_transfer_upload_result_v2",
        success: false,
        errorCode: "step_up_required",
      }),
    ]);
  });

  it("negotiates the saved computer path only with a v3-capable phone", async () => {
    const f = await fixture();
    const client = {};
    const phone = binding([
      "file_transfer_upload_ready_v2",
      "file_transfer_upload_result_v2",
      "file_transfer_upload_result_v3",
    ]);
    f.manager.connect(client, phone.binding);
    await f.manager.handleClientMessage(client, {
      type: "file_transfer_upload_prepare_v2",
      requestId: "request-v3",
      transferId: "upload_path00001",
      resumeToken,
      filename: "from phone.txt",
      sizeBytes: 5,
    });
    const ready = phone.messages[0];
    if (ready.type !== "file_transfer_upload_ready_v2") {
      throw new Error("expected ready");
    }

    await f.manager.appendUpload(
      ready.transferId,
      ready.uploadToken,
      0,
      5,
      chunks("hello"),
      new AbortController().signal,
    );

    expect(phone.messages[1]).toEqual({
      type: "file_transfer_upload_result_v3",
      requestId: "request-v3",
      transferId: "upload_path00001",
      success: true,
      filename: "from phone.txt",
      sizeBytes: 5,
      savedPath: join(f.root, "downloads", "from phone.txt"),
    });
  });

  it("archives a diagnostic upload with Bridge runtime authority and removes the Downloads artifact", async () => {
    const f = await fixture();
    const client = {};
    const phone = binding([
      "file_transfer_upload_ready_v2",
      "file_transfer_upload_result_v2",
      "file_transfer_upload_result_v3",
    ]);
    f.manager.connect(client, phone.binding);
    const body = Buffer.from(JSON.stringify({
      schemaVersion: 1,
      reportId: "report_manager_1",
      target: { provider: "codex", providerSessionId: "thread-diagnostic" },
      mobile: {
        infrastructure: {
          bridgeInstanceId: "bridge-test",
          codexSourceId: "source-bridge",
        },
      },
      event: "diagnostic",
      details: { ok: true },
    }));
    const diagnosticReport = {
      schemaVersion: 1 as const,
      reportId: "report_manager_1",
      provider: "codex",
      providerSessionId: "thread-diagnostic",
      bridgeInstanceId: "bridge-test",
      codexSourceId: "source-bridge",
      capturedAtStart: "2026-08-12T00:00:00.000Z",
      capturedAtEnd: "2026-08-12T00:01:00.000Z",
      sha256: createHash("sha256").update(body).digest("hex"),
    };
    await f.manager.handleClientMessage(client, {
      type: "file_transfer_upload_prepare_v2",
      requestId: "diagnostic-prepare",
      transferId: "upload_diagnostic1",
      resumeToken,
      filename: "phone-diagnostic.json",
      sizeBytes: body.length,
      purpose: "diagnostic_report",
      diagnosticReport,
    });
    const ready = phone.messages[0];
    if (ready.type !== "file_transfer_upload_ready_v2") throw new Error("expected ready");
    await f.manager.appendUpload(
      ready.transferId,
      ready.uploadToken,
      0,
      body.length,
      chunks(body.toString()),
      new AbortController().signal,
    );
    const result = phone.messages.at(-1);
    expect(result).toMatchObject({
      type: "file_transfer_upload_result_v3",
      success: true,
      purpose: "diagnostic_report",
      reportId: "report_manager_1",
      sizeBytes: body.length,
    });
    if (result?.type !== "file_transfer_upload_result_v3" || !result.savedPath) {
      throw new Error("expected diagnostic result path");
    }
    expect(result.filename).toBe("report_manager_1.json");
    expect(await readFile(result.savedPath, "utf8")).toContain("\"executionHost\": \"bridge\"");
    expect(await f.state.getUpload("upload_diagnostic1")).toMatchObject({
      status: "complete",
      diagnosticReceipt: {
        reportId: "report_manager_1",
        savedPath: result.savedPath,
      },
    });
    await expect(readFile(join(f.root, "downloads", "phone-diagnostic.json"))).rejects.toMatchObject({ code: "ENOENT" });

    // Losing the first receipt must not force Mobile to upload/archive again.
    // A repeated prepare for the stable transfer identity receives the exact
    // committed receipt even if runtime authority has changed since capture.
    const retryClient = {};
    const retryPhone = binding([
      "file_transfer_upload_ready_v2",
      "file_transfer_upload_result_v3",
    ]);
    f.manager.connect(retryClient, retryPhone.binding);
    await f.manager.handleClientMessage(retryClient, {
      type: "file_transfer_upload_prepare_v2",
      requestId: "diagnostic-prepare-retry",
      transferId: "upload_diagnostic1",
      resumeToken,
      filename: "phone-diagnostic.json",
      sizeBytes: body.length,
      purpose: "diagnostic_report",
      diagnosticReport,
    });
    expect(retryPhone.messages).toEqual([
      expect.objectContaining({
        type: "file_transfer_upload_result_v3",
        requestId: "diagnostic-prepare-retry",
        transferId: "upload_diagnostic1",
        success: true,
        purpose: "diagnostic_report",
        reportId: "report_manager_1",
        sizeBytes: body.length,
        savedPath: result.savedPath,
      }),
    ]);

    await f.manager.close();
    const restartedState = new FileTransferStateStore({
      filePath: f.state.filePath,
    });
    const restartedUploadStore = new FileTransferUploadStore({
      stateStore: restartedState,
      directory: join(f.root, "downloads"),
      partialDirectory: join(f.root, "parts"),
      diskSafetyMarginBytes: 0,
    });
    const restartedAuthStore = new FileMutationAuthStore({
      filePath: join(f.root, "restart-file-mutation-auth.json"),
    });
    const restartedAuthorizer = new FileMutationAuthorizer({
      store: restartedAuthStore,
      bridgeInstanceId: "bridge-test",
    });
    const authorize = vi
      .spyOn(restartedAuthorizer, "authorize")
      .mockRejectedValue(new Error("receipt replay must not reauthorize"));
    const restartedManager = new FileTransferManager({
      downloadStore: new FileTransferDownloadStore({
        stateStore: restartedState,
        allowedDirs: [f.root],
      }),
      uploadStore: restartedUploadStore,
      baseUrl: "http://100.64.0.1:8765",
      fileMutationAuthorizer: restartedAuthorizer,
      diagnosticReportArchiver: new DiagnosticReportArchiver({
        reportsDirectory: f.reports,
        bridgeInstanceId: "bridge-test",
        codexSourceId: "source-bridge",
      }),
    });
    await restartedManager.init();
    managers.push(restartedManager);
    const restartedClient = {};
    const restartedPhone = binding([
      "file_transfer_upload_ready_v2",
      "file_transfer_upload_result_v3",
    ]);
    restartedManager.connect(restartedClient, restartedPhone.binding);
    await restartedManager.handleClientMessage(restartedClient, {
      type: "file_transfer_upload_prepare_v2",
      requestId: "diagnostic-prepare-after-restart",
      transferId: "upload_diagnostic1",
      resumeToken,
      filename: "phone-diagnostic.json",
      sizeBytes: body.length,
      purpose: "diagnostic_report",
      diagnosticReport,
    });
    expect(restartedPhone.messages).toEqual([
      expect.objectContaining({
        type: "file_transfer_upload_result_v3",
        requestId: "diagnostic-prepare-after-restart",
        success: true,
        reportId: "report_manager_1",
        savedPath: result.savedPath,
      }),
    ]);
    expect(authorize).not.toHaveBeenCalled();
  });

  it("bypasses mutation step-up only for explicit development diagnostics", async () => {
    const f = await fixture({
      withoutMutationAuthorizer: true,
      allowDiagnosticWithoutMutationAuthorization: true,
    });
    const client = {};
    const phone = binding([
      "file_transfer_upload_ready_v2",
      "file_transfer_upload_result_v3",
    ]);
    f.manager.connect(client, phone.binding);
    const body = Buffer.from(JSON.stringify({
      schemaVersion: 1,
      reportId: "report_development_bypass",
      target: { provider: "codex", providerSessionId: "thread-diagnostic" },
      mobile: {
        infrastructure: {
          bridgeInstanceId: "bridge-test",
          codexSourceId: "source-bridge",
        },
      },
    }));
    await f.manager.handleClientMessage(client, {
      type: "file_transfer_upload_prepare_v2",
      requestId: "diagnostic-dev-bypass",
      transferId: "upload_diag_dev_bypass",
      resumeToken,
      filename: "diagnostic.json",
      sizeBytes: body.length,
      purpose: "diagnostic_report",
      diagnosticReport: {
        schemaVersion: 1,
        reportId: "report_development_bypass",
        provider: "codex",
        providerSessionId: "thread-diagnostic",
        bridgeInstanceId: "bridge-test",
        codexSourceId: "source-bridge",
        capturedAtStart: "2026-08-13T00:00:00.000Z",
        capturedAtEnd: "2026-08-13T00:00:03.000Z",
        sha256: createHash("sha256").update(body).digest("hex"),
      },
    });
    expect(phone.messages[0]).toMatchObject({
      type: "file_transfer_upload_ready_v2",
      transferId: "upload_diag_dev_bypass",
    });

    const ordinaryClient = {};
    const ordinaryPhone = binding([
      "file_transfer_upload_ready_v2",
      "file_transfer_upload_result_v3",
    ]);
    f.manager.connect(ordinaryClient, ordinaryPhone.binding);
    await f.manager.handleClientMessage(ordinaryClient, {
      type: "file_transfer_upload_prepare_v2",
      requestId: "ordinary-dev-denied",
      transferId: "upload_ordinary_dev",
      resumeToken: "s".repeat(43),
      filename: "ordinary.txt",
      sizeBytes: 1,
    });
    expect(ordinaryPhone.messages).toContainEqual(
      expect.objectContaining({
        type: "file_transfer_upload_result_v3",
        success: false,
        errorCode: "unsupported_capability",
      }),
    );
  });

  it("fails a diagnostic prepare closed when the phone lacks the v3 result path", async () => {
    const f = await fixture();
    const client = {};
    const phone = binding(["file_transfer_upload_ready_v2", "file_transfer_upload_result_v2"]);
    f.manager.connect(client, phone.binding);
    const body = Buffer.from("{}");
    await f.manager.handleClientMessage(client, {
      type: "file_transfer_upload_prepare_v2",
      requestId: "diagnostic-no-v3",
      transferId: "upload_diagnostic3",
      resumeToken: "t".repeat(43),
      filename: "diagnostic.json",
      sizeBytes: body.length,
      purpose: "diagnostic_report",
      diagnosticReport: {
        schemaVersion: 1,
        reportId: "report_no_v3",
        provider: "codex",
        providerSessionId: "thread-diagnostic",
        bridgeInstanceId: "bridge-test",
        codexSourceId: "source-bridge",
        capturedAtStart: "2026-08-12T00:00:00.000Z",
        capturedAtEnd: "2026-08-12T00:01:00.000Z",
        sha256: createHash("sha256").update(body).digest("hex"),
      },
    });
    expect(phone.messages).toMatchObject([
      expect.objectContaining({
        type: "file_transfer_upload_result_v2",
        success: false,
        errorCode: "diagnostic_result_unsupported",
      }),
    ]);
    expect(await f.state.getUpload("upload_diagnostic3")).toBeUndefined();
  });

  it("removes a terminally rejected diagnostic payload instead of retaining raw bytes", async () => {
    const f = await fixture();
    const client = {};
    const phone = binding([
      "file_transfer_upload_ready_v2",
      "file_transfer_upload_result_v2",
      "file_transfer_upload_result_v3",
    ]);
    f.manager.connect(client, phone.binding);
    const body = Buffer.from(JSON.stringify({
      schemaVersion: 1,
      reportId: "report_manager_2",
      target: { provider: "codex", providerSessionId: "thread-diagnostic" },
      mobile: {
        infrastructure: {
          bridgeInstanceId: "bridge-test",
          codexSourceId: "source-bridge",
        },
      },
      event: "diagnostic",
    }));
    const prepare = {
      type: "file_transfer_upload_prepare_v2" as const,
      requestId: "diagnostic-invalid",
      transferId: "upload_diagnostic2",
      resumeToken: "s".repeat(43),
      filename: "invalid-diagnostic.json",
      sizeBytes: body.length,
      purpose: "diagnostic_report" as const,
      diagnosticReport: {
        schemaVersion: 1 as const,
        reportId: "report_manager_2",
        provider: "codex",
        providerSessionId: "thread-diagnostic",
        bridgeInstanceId: "bridge-test",
        codexSourceId: "source-bridge",
        capturedAtStart: "2026-08-12T00:00:00.000Z",
        capturedAtEnd: "2026-08-12T00:01:00.000Z",
        sha256: "0".repeat(64),
      },
    };
    await f.manager.handleClientMessage(client, prepare);
    const ready = phone.messages[0];
    if (ready.type !== "file_transfer_upload_ready_v2") throw new Error("expected ready");
    await f.manager.appendUpload(ready.transferId, ready.uploadToken, 0, body.length, chunks(body.toString()), new AbortController().signal);
    expect(phone.messages.at(-1)).toMatchObject({ success: false, errorCode: "diagnostic_sha256_mismatch" });
    expect(await f.state.getUpload(prepare.transferId)).toBeUndefined();
    await expect(readFile(join(f.root, "downloads", "invalid-diagnostic.json"))).rejects.toMatchObject({ code: "ENOENT" });
    await f.manager.handleClientMessage(client, { ...prepare, requestId: "diagnostic-invalid-retry" });
    expect(phone.messages.at(-1)).toMatchObject({
      type: "file_transfer_upload_ready_v2",
      requestId: "diagnostic-invalid-retry",
    });
  });

  it("deletes a credential-bearing diagnostic immediately after fail-closed rejection", async () => {
    const f = await fixture();
    const client = {};
    const phone = binding([
      "file_transfer_upload_ready_v2",
      "file_transfer_upload_result_v3",
    ]);
    f.manager.connect(client, phone.binding);
    const body = Buffer.from(JSON.stringify({
      schemaVersion: 1,
      reportId: "sensitive_report",
      target: { provider: "codex", providerSessionId: "thread-diagnostic" },
      mobile: {
        infrastructure: {
          bridgeInstanceId: "bridge-test",
          codexSourceId: "source-bridge",
        },
      },
      transcript: {
        authorizationHeader: "Bearer must-never-remain-on-disk",
      },
    }));
    const transferId = "upload_sensitive01";
    await f.manager.handleClientMessage(client, {
      type: "file_transfer_upload_prepare_v2",
      requestId: "sensitive-prepare",
      transferId,
      resumeToken: "v".repeat(43),
      filename: "sensitive-report.json",
      sizeBytes: body.length,
      purpose: "diagnostic_report",
      diagnosticReport: {
        schemaVersion: 1,
        reportId: "sensitive_report",
        provider: "codex",
        providerSessionId: "thread-diagnostic",
        bridgeInstanceId: "bridge-test",
        codexSourceId: "source-bridge",
        capturedAtStart: "2026-08-12T00:00:00.000Z",
        capturedAtEnd: "2026-08-12T00:01:00.000Z",
        sha256: createHash("sha256").update(body).digest("hex"),
      },
    });
    const ready = phone.messages.at(-1);
    if (!ready || ready.type !== "file_transfer_upload_ready_v2") {
      throw new Error("expected ready");
    }
    await f.manager.appendUpload(
      ready.transferId,
      ready.uploadToken,
      0,
      body.length,
      chunks(body.toString()),
      new AbortController().signal,
    );

    expect(phone.messages.at(-1)).toMatchObject({
      success: false,
      errorCode: "diagnostic_sensitive_field",
    });
    expect(await f.state.getUpload(transferId)).toBeUndefined();
    await expect(
      readFile(join(f.root, "downloads", "sensitive-report.json")),
    ).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("scrubs an exact completed diagnostic when its final payload becomes unreadable", async () => {
    const f = await fixture();
    const client = {};
    const phone = binding([
      "file_transfer_upload_ready_v2",
      "file_transfer_upload_result_v3",
    ]);
    f.manager.connect(client, phone.binding);
    const body = Buffer.from(JSON.stringify({
      schemaVersion: 1,
      reportId: "unreadable-final",
      target: { provider: "codex", providerSessionId: "thread-diagnostic" },
      mobile: {
        infrastructure: {
          bridgeInstanceId: "bridge-test",
          codexSourceId: "source-bridge",
        },
      },
    }));
    const prepare = {
      type: "file_transfer_upload_prepare_v2" as const,
      requestId: "unreadable-prepare",
      transferId: "upload_unreadable1",
      resumeToken: "v".repeat(43),
      filename: "unreadable-final.json",
      sizeBytes: body.length,
      purpose: "diagnostic_report" as const,
      diagnosticReport: {
        schemaVersion: 1 as const,
        reportId: "unreadable-final",
        provider: "codex",
        providerSessionId: "thread-diagnostic",
        bridgeInstanceId: "bridge-test",
        codexSourceId: "source-bridge",
        capturedAtStart: "2026-08-12T00:00:00.000Z",
        capturedAtEnd: "2026-08-12T00:01:00.000Z",
        sha256: createHash("sha256").update(body).digest("hex"),
      },
    };
    await f.manager.handleClientMessage(client, prepare);
    const ready = phone.messages.at(-1);
    if (!ready || ready.type !== "file_transfer_upload_ready_v2") {
      throw new Error("expected ready");
    }
    vi.spyOn(f.uploadStore, "readCompletedUpload").mockRejectedValueOnce(
      new FileTransferError(409, "upload_final_changed", "forced unreadable payload"),
    );

    await f.manager.appendUpload(
      ready.transferId,
      ready.uploadToken,
      0,
      body.length,
      chunks(body.toString()),
      new AbortController().signal,
    );

    expect(phone.messages.at(-1)).toMatchObject({
      success: false,
      errorCode: "upload_final_changed",
    });
    expect(await f.state.getUpload(prepare.transferId)).toBeUndefined();
    await expect(readFile(join(f.root, "downloads", prepare.filename)))
      .rejects.toMatchObject({ code: "ENOENT" });
  });

  it("does not replay a success receipt after its immutable archive is missing", async () => {
    const f = await fixture();
    const client = {};
    const phone = binding([
      "file_transfer_upload_ready_v2",
      "file_transfer_upload_result_v3",
    ]);
    f.manager.connect(client, phone.binding);
    const body = Buffer.from(JSON.stringify({
      schemaVersion: 1,
      reportId: "missing_archive",
      target: { provider: "codex", providerSessionId: "thread-diagnostic" },
      mobile: {
        infrastructure: {
          bridgeInstanceId: "bridge-test",
          codexSourceId: "source-bridge",
        },
      },
    }));
    const diagnosticReport = {
      schemaVersion: 1 as const,
      reportId: "missing_archive",
      provider: "codex",
      providerSessionId: "thread-diagnostic",
      bridgeInstanceId: "bridge-test",
      codexSourceId: "source-bridge",
      capturedAtStart: "2026-08-12T00:00:00.000Z",
      capturedAtEnd: "2026-08-12T00:01:00.000Z",
      sha256: createHash("sha256").update(body).digest("hex"),
    };
    const prepare = {
      type: "file_transfer_upload_prepare_v2" as const,
      requestId: "missing-archive-first",
      transferId: "upload_missingarc1",
      resumeToken: "m".repeat(43),
      filename: "missing-archive.json",
      sizeBytes: body.length,
      purpose: "diagnostic_report" as const,
      diagnosticReport,
    };
    await f.manager.handleClientMessage(client, prepare);
    const ready = phone.messages.at(-1);
    if (!ready || ready.type !== "file_transfer_upload_ready_v2") {
      throw new Error("expected ready");
    }
    await f.manager.appendUpload(
      ready.transferId,
      ready.uploadToken,
      0,
      body.length,
      chunks(body.toString()),
      new AbortController().signal,
    );
    const success = phone.messages.at(-1);
    if (!success || success.type !== "file_transfer_upload_result_v3" || !success.savedPath) {
      throw new Error("expected archived result");
    }
    await unlink(success.savedPath);
    phone.messages.splice(0);

    await f.manager.handleClientMessage(client, {
      ...prepare,
      requestId: "missing-archive-retry",
    });

    expect(phone.messages).toEqual([
      expect.objectContaining({
        type: "file_transfer_upload_ready_v2",
        requestId: "missing-archive-retry",
      }),
    ]);
  });

  it("archives and scrubs a completed diagnostic after the WebSocket owner disconnects", async () => {
    const f = await fixture();
    const client = {};
    const phone = binding([
      "file_transfer_upload_ready_v2",
      "file_transfer_upload_result_v3",
    ]);
    f.manager.connect(client, phone.binding);
    const body = Buffer.from(JSON.stringify({
      schemaVersion: 1,
      reportId: "disconnect_archive",
      target: { provider: "codex", providerSessionId: "thread-diagnostic" },
      mobile: {
        infrastructure: {
          bridgeInstanceId: "bridge-test",
          codexSourceId: "source-bridge",
        },
      },
    }));
    await f.manager.handleClientMessage(client, {
      type: "file_transfer_upload_prepare_v2",
      requestId: "disconnect-prepare",
      transferId: "upload_disconnect1",
      resumeToken: "d".repeat(43),
      filename: "disconnect-report.json",
      sizeBytes: body.length,
      purpose: "diagnostic_report",
      diagnosticReport: {
        schemaVersion: 1,
        reportId: "disconnect_archive",
        provider: "codex",
        providerSessionId: "thread-diagnostic",
        bridgeInstanceId: "bridge-test",
        codexSourceId: "source-bridge",
        capturedAtStart: "2026-08-12T00:00:00.000Z",
        capturedAtEnd: "2026-08-12T00:01:00.000Z",
        sha256: createHash("sha256").update(body).digest("hex"),
      },
    });
    const ready = phone.messages.at(-1);
    if (!ready || ready.type !== "file_transfer_upload_ready_v2") {
      throw new Error("expected ready");
    }
    phone.close();
    f.manager.disconnect(client);

    await f.manager.appendUpload(
      ready.transferId,
      ready.uploadToken,
      0,
      body.length,
      chunks(body.toString()),
      new AbortController().signal,
    );

    await expect(
      readFile(join(f.reports, "disconnect_archive.json"), "utf8"),
    ).resolves.toContain('"reportId": "disconnect_archive"');
    await expect(
      readFile(join(f.root, "downloads", "disconnect-report.json")),
    ).rejects.toMatchObject({ code: "ENOENT" });
    expect(await f.state.getUpload("upload_disconnect1")).toMatchObject({
      diagnosticReceipt: {
        archiveSha256: expect.stringMatching(/^[a-f0-9]{64}$/u),
        mobileReportCanonicalSha256: expect.stringMatching(/^[a-f0-9]{64}$/u),
      },
    });
  });

  it("rejects a tampered archived report instead of replaying its receipt", async () => {
    const f = await fixture();
    const client = {};
    const phone = binding([
      "file_transfer_upload_ready_v2",
      "file_transfer_upload_result_v3",
    ]);
    f.manager.connect(client, phone.binding);
    const body = Buffer.from(JSON.stringify({
      schemaVersion: 1,
      reportId: "tampered_archive",
      target: { provider: "codex", providerSessionId: "thread-diagnostic" },
      mobile: {
        infrastructure: {
          bridgeInstanceId: "bridge-test",
          codexSourceId: "source-bridge",
        },
      },
      event: "original",
    }));
    const diagnosticReport = {
      schemaVersion: 1 as const,
      reportId: "tampered_archive",
      provider: "codex",
      providerSessionId: "thread-diagnostic",
      bridgeInstanceId: "bridge-test",
      codexSourceId: "source-bridge",
      capturedAtStart: "2026-08-12T00:00:00.000Z",
      capturedAtEnd: "2026-08-12T00:01:00.000Z",
      sha256: createHash("sha256").update(body).digest("hex"),
    };
    const prepare = {
      type: "file_transfer_upload_prepare_v2" as const,
      requestId: "tamper-first",
      transferId: "upload_tampered01",
      resumeToken: "z".repeat(43),
      filename: "tampered-report.json",
      sizeBytes: body.length,
      purpose: "diagnostic_report" as const,
      diagnosticReport,
    };
    await f.manager.handleClientMessage(client, prepare);
    const ready = phone.messages.at(-1);
    if (!ready || ready.type !== "file_transfer_upload_ready_v2") {
      throw new Error("expected ready");
    }
    await f.manager.appendUpload(
      ready.transferId,
      ready.uploadToken,
      0,
      body.length,
      chunks(body.toString()),
      new AbortController().signal,
    );
    const success = phone.messages.at(-1);
    if (!success || success.type !== "file_transfer_upload_result_v3" || !success.savedPath) {
      throw new Error("expected archived result");
    }
    const altered = JSON.parse(await readFile(success.savedPath, "utf8")) as Record<string, any>;
    altered.mobileReport.event = "forged";
    altered.mobileReportCanonicalSha256 = createHash("sha256")
      .update(JSON.stringify(altered.mobileReport))
      .digest("hex");
    await writeFile(success.savedPath, `${JSON.stringify(altered, null, 2)}\n`);
    phone.messages.splice(0);

    await f.manager.handleClientMessage(client, {
      ...prepare,
      requestId: "tamper-retry",
    });

    expect(phone.messages.at(-1)).toMatchObject({
      success: false,
      errorCode: "diagnostic_report_collision",
    });
    expect(await f.state.getUpload(prepare.transferId)).toBeUndefined();
  });

  it("serializes distinct diagnostic archives to bound parse memory", async () => {
    const originalArchive = DiagnosticReportArchiver.prototype.archive;
    let activeArchives = 0;
    let maximumActiveArchives = 0;
    const archiveSpy = vi
      .spyOn(DiagnosticReportArchiver.prototype, "archive")
      .mockImplementation(async function (
        this: DiagnosticReportArchiver,
        ...args: Parameters<DiagnosticReportArchiver["archive"]>
      ) {
        activeArchives += 1;
        maximumActiveArchives = Math.max(
          maximumActiveArchives,
          activeArchives,
        );
        await new Promise((resolve) => setTimeout(resolve, 20));
        try {
          return await originalArchive.apply(this, args);
        } finally {
          activeArchives -= 1;
        }
      });
    try {
      const f = await fixture();
      const client = {};
      const phone = binding([
        "file_transfer_upload_ready_v2",
        "file_transfer_upload_result_v3",
      ]);
      f.manager.connect(client, phone.binding);
      const uploads = [] as Array<{
        body: Buffer;
        transferId: string;
        uploadToken: string;
      }>;
      for (const index of [1, 2]) {
        const reportId = `serialized_report_${index}`;
        const body = Buffer.from(JSON.stringify({
          schemaVersion: 1,
          reportId,
          target: {
            provider: "codex",
            providerSessionId: "thread-diagnostic",
          },
          mobile: {
            infrastructure: {
              bridgeInstanceId: "bridge-test",
              codexSourceId: "source-bridge",
            },
          },
        }));
        const transferId = `upload_serialized0${index}`;
        await f.manager.handleClientMessage(client, {
          type: "file_transfer_upload_prepare_v2",
          requestId: `serialized-prepare-${index}`,
          transferId,
          resumeToken: String(index).repeat(43),
          filename: `serialized-${index}.json`,
          sizeBytes: body.length,
          purpose: "diagnostic_report",
          diagnosticReport: {
            schemaVersion: 1,
            reportId,
            provider: "codex",
            providerSessionId: "thread-diagnostic",
            bridgeInstanceId: "bridge-test",
            codexSourceId: "source-bridge",
            capturedAtStart: "2026-08-12T00:00:00.000Z",
            capturedAtEnd: "2026-08-12T00:01:00.000Z",
            sha256: createHash("sha256").update(body).digest("hex"),
          },
        });
        const ready = phone.messages.findLast(
          (message) =>
            message.type === "file_transfer_upload_ready_v2" &&
            message.transferId === transferId,
        );
        if (!ready || ready.type !== "file_transfer_upload_ready_v2") {
          throw new Error("expected ready");
        }
        uploads.push({ body, transferId, uploadToken: ready.uploadToken });
      }

      await Promise.all(
        uploads.map((upload) =>
          f.manager.appendUpload(
            upload.transferId,
            upload.uploadToken,
            0,
            upload.body.length,
            chunks(upload.body.toString()),
            new AbortController().signal,
          ),
        ),
      );

      expect(maximumActiveArchives).toBe(1);
    } finally {
      archiveSpy.mockRestore();
    }
  });

  it("replays a completed upload result after ready or result response loss", async () => {
    const f = await fixture();
    const client = {};
    const phone = binding(["file_transfer_upload_ready_v2", "file_transfer_upload_result_v2"]);
    f.manager.connect(client, phone.binding);
    const prepare = {
      type: "file_transfer_upload_prepare_v2" as const,
      requestId: "first-request",
      transferId: "upload_response01",
      resumeToken,
      filename: "done.txt",
      sizeBytes: 4,
    };
    await f.manager.handleClientMessage(client, prepare);
    const ready = phone.messages[0];
    if (ready.type !== "file_transfer_upload_ready_v2") throw new Error("expected ready");
    await f.manager.appendUpload(
      ready.transferId,
      ready.uploadToken,
      0,
      4,
      chunks("done"),
      new AbortController().signal,
    );
    phone.messages.splice(0);
    await f.manager.handleClientMessage(client, { ...prepare, requestId: "retry-request" });
    expect(phone.messages).toEqual([{
      type: "file_transfer_upload_result_v2",
      requestId: "retry-request",
      transferId: "upload_response01",
      success: true,
      filename: "done.txt",
      sizeBytes: 4,
    }]);
  });

  it("makes repeated authenticated cancel idempotent and never cancels a completed upload", async () => {
    const f = await fixture();
    const client = {};
    const phone = binding([
      "file_transfer_upload_ready_v2",
      "file_transfer_upload_result_v2",
      "file_transfer_cancel_result_v2",
    ]);
    f.manager.connect(client, phone.binding);
    await f.manager.handleClientMessage(client, {
      type: "file_transfer_upload_prepare_v2",
      requestId: "prepare",
      transferId: "upload_cancel0001",
      resumeToken,
      filename: "pending.bin",
      sizeBytes: 4,
    });
    for (const requestId of ["cancel-1", "cancel-2"]) {
      await f.manager.handleClientMessage(client, {
        type: "file_transfer_cancel_v2",
        requestId,
        transferId: "upload_cancel0001",
        direction: "upload",
        resumeToken,
      });
    }
    expect(phone.messages.slice(-2)).toEqual([
      expect.objectContaining({ type: "file_transfer_cancel_result_v2", requestId: "cancel-1", success: true }),
      expect.objectContaining({ type: "file_transfer_cancel_result_v2", requestId: "cancel-2", success: true }),
    ]);

    await f.manager.handleClientMessage(client, {
      type: "file_transfer_upload_prepare_v2",
      requestId: "prepare-complete",
      transferId: "upload_complete01",
      resumeToken: "s".repeat(43),
      filename: "complete.bin",
      sizeBytes: 1,
    });
    const ready = phone.messages.findLast((message) =>
      message.type === "file_transfer_upload_ready_v2" && message.transferId === "upload_complete01"
    );
    if (!ready || ready.type !== "file_transfer_upload_ready_v2") throw new Error("expected ready");
    await f.manager.appendUpload(ready.transferId, ready.uploadToken, 0, 1, chunks("x"), new AbortController().signal);
    await f.manager.handleClientMessage(client, {
      type: "file_transfer_cancel_v2",
      requestId: "cancel-complete",
      transferId: ready.transferId,
      direction: "upload",
      resumeToken: "s".repeat(43),
    });
    expect(phone.messages.at(-1)).toMatchObject({
      type: "file_transfer_cancel_result_v2",
      requestId: "cancel-complete",
      success: false,
      errorCode: "upload_already_complete",
    });
  });

  it("renews a retained download idempotently and deletes only on exact receive acknowledgement", async () => {
    let now = 1_000;
    const f = await fixture({ now: () => now });
    const client = {};
    const phone = binding(["file_transfer_offer_v2", "file_transfer_download_resumed_v2"]);
    f.manager.connect(client, phone.binding);
    await f.manager.offerFile({ filePath: f.source, projectPath: f.root, ttlSeconds: 60 });
    const offer = phone.messages[0];
    if (offer.type !== "file_transfer_offer_v2") throw new Error("expected offer");
    await f.manager.handleClientMessage(client, {
      type: "file_transfer_receive_result_v2",
      transferId: offer.transferId,
      success: true,
      receivedBytes: 5,
    });
    expect(await f.state.getDownload(offer.transferId)).toBeDefined();
    now = Date.parse(offer.expiresAt) + 1;
    for (const requestId of ["resume-1", "resume-2"]) {
      await f.manager.handleClientMessage(client, {
        type: "file_transfer_download_resume_v2",
        requestId,
        transferId: offer.transferId,
        downloadToken: offer.downloadToken,
      });
      expect(phone.messages.at(-1)).toMatchObject({
        type: "file_transfer_download_resumed_v2",
        requestId,
        success: true,
        sizeBytes: 6,
      });
    }
    await f.manager.handleClientMessage(client, {
      type: "file_transfer_receive_result_v2",
      transferId: offer.transferId,
      success: true,
      receivedBytes: 6,
    });
    expect(await f.state.getDownload(offer.transferId)).toBeUndefined();
  });

  it("does not let a disconnected late resume replace the new live owner", async () => {
    const f = await fixture();
    const oldClient = {};
    const oldPeer = binding([
      "file_transfer_offer_v2",
      "file_transfer_download_resumed_v2",
    ]);
    f.manager.connect(oldClient, oldPeer.binding);
    await f.manager.offerFile({ filePath: f.source, projectPath: f.root });
    const offer = oldPeer.messages[0];
    if (offer.type !== "file_transfer_offer_v2") {
      throw new Error("expected offer");
    }

    const originalResume = f.downloadStore.resume.bind(f.downloadStore);
    let resumeCalls = 0;
    let releaseOld!: () => void;
    const oldGate = new Promise<void>((resolve) => {
      releaseOld = resolve;
    });
    vi.spyOn(f.downloadStore, "resume").mockImplementation(async (...args) => {
      resumeCalls++;
      if (resumeCalls === 1) await oldGate;
      return originalResume(...args);
    });
    const oldResume = f.manager.handleClientMessage(oldClient, {
      type: "file_transfer_download_resume_v2",
      requestId: "old-resume",
      transferId: offer.transferId,
      downloadToken: offer.downloadToken,
    });
    await vi.waitFor(() => expect(resumeCalls).toBe(1));
    oldPeer.close();
    f.manager.disconnect(oldClient);

    const newClient = {};
    const newPeer = binding(["file_transfer_download_resumed_v2"]);
    f.manager.connect(newClient, newPeer.binding);
    await f.manager.handleClientMessage(newClient, {
      type: "file_transfer_download_resume_v2",
      requestId: "new-resume",
      transferId: offer.transferId,
      downloadToken: offer.downloadToken,
    });
    expect(newPeer.messages.at(-1)).toMatchObject({
      type: "file_transfer_download_resumed_v2",
      requestId: "new-resume",
      success: true,
    });

    releaseOld();
    await oldResume;
    expect(
      oldPeer.messages.some(
        (message) =>
          message.type === "file_transfer_download_resumed_v2" &&
          message.requestId === "old-resume",
      ),
    ).toBe(false);
    await f.manager.handleClientMessage(newClient, {
      type: "file_transfer_receive_result_v2",
      transferId: offer.transferId,
      success: true,
      receivedBytes: offer.sizeBytes,
    });
    expect(await f.state.getDownload(offer.transferId)).toBeUndefined();
  });

  it("contains acknowledged-download cleanup failure and retries it idempotently", async () => {
    const f = await fixture();
    const client = {};
    const peer = binding(["file_transfer_offer_v2"]);
    f.manager.connect(client, peer.binding);
    await f.manager.offerFile({ filePath: f.source, projectPath: f.root });
    const offer = peer.messages[0];
    if (offer.type !== "file_transfer_offer_v2") {
      throw new Error("expected offer");
    }
    vi.spyOn(f.downloadStore, "remove").mockRejectedValueOnce(
      new Error("state cleanup failed"),
    );
    const warning = vi.spyOn(console, "warn").mockImplementation(() => {});
    const acknowledgement = {
      type: "file_transfer_receive_result_v2" as const,
      transferId: offer.transferId,
      success: true,
      receivedBytes: offer.sizeBytes,
    };

    await expect(
      f.manager.handleClientMessage(client, acknowledgement),
    ).resolves.toBeUndefined();
    expect(await f.state.getDownload(offer.transferId)).toBeDefined();
    expect(warning).toHaveBeenCalledWith(
      expect.stringContaining("state cleanup failed"),
    );

    await expect(
      f.manager.handleClientMessage(client, acknowledgement),
    ).resolves.toBeUndefined();
    expect(await f.state.getDownload(offer.transferId)).toBeUndefined();
    warning.mockRestore();
  });

  it("authenticates download cancel across reconnect even after the short HTTP lease expires", async () => {
    let now = 1_000;
    const f = await fixture({ now: () => now });
    const firstClient = {};
    const firstPeer = binding(["file_transfer_offer_v2"]);
    f.manager.connect(firstClient, firstPeer.binding);
    await f.manager.offerFile({ filePath: f.source, projectPath: f.root, ttlSeconds: 60 });
    const offer = firstPeer.messages[0];
    if (offer.type !== "file_transfer_offer_v2") throw new Error("expected offer");
    f.manager.disconnect(firstClient);
    now = Date.parse(offer.expiresAt) + 1;

    const nextClient = {};
    const nextPeer = binding(["file_transfer_cancel_result_v2"]);
    f.manager.connect(nextClient, nextPeer.binding);
    await f.manager.handleClientMessage(nextClient, {
      type: "file_transfer_cancel_v2",
      requestId: "cancel-expired-lease",
      transferId: offer.transferId,
      direction: "download",
      downloadToken: offer.downloadToken,
    });
    expect(nextPeer.messages).toEqual([expect.objectContaining({
      type: "file_transfer_cancel_result_v2",
      requestId: "cancel-expired-lease",
      success: true,
    })]);
    expect(await f.state.getDownload(offer.transferId)).toBeUndefined();
  });

  it("keeps live owner routes after indistinguishable unauthorized cancels", async () => {
    const f = await fixture();
    const ownerClient = {};
    const owner = binding([
      "file_transfer_offer_v2",
      "file_transfer_upload_ready_v2",
      "file_transfer_upload_result_v2",
      "file_transfer_cancel_result_v2",
    ]);
    const otherClient = {};
    const other = binding(["file_transfer_cancel_result_v2"]);
    f.manager.connect(ownerClient, owner.binding);
    f.manager.connect(otherClient, other.binding);

    await f.manager.handleClientMessage(ownerClient, {
      type: "file_transfer_upload_prepare_v2",
      requestId: "prepare-owned-upload",
      transferId: "upload_ownedroute1",
      resumeToken,
      filename: "owned.bin",
      sizeBytes: 1,
    });
    const ready = owner.messages.findLast(
      (message) => message.type === "file_transfer_upload_ready_v2",
    );
    if (!ready || ready.type !== "file_transfer_upload_ready_v2") {
      throw new Error("expected ready");
    }
    await f.manager.handleClientMessage(otherClient, {
      type: "file_transfer_cancel_v2",
      requestId: "wrong-upload-cancel",
      transferId: ready.transferId,
      direction: "upload",
      resumeToken: "w".repeat(43),
    });
    expect(other.messages.at(-1)).toMatchObject({
      type: "file_transfer_cancel_result_v2",
      requestId: "wrong-upload-cancel",
      success: true,
    });
    await f.manager.appendUpload(
      ready.transferId,
      ready.uploadToken,
      0,
      1,
      chunks("x"),
      new AbortController().signal,
    );
    expect(owner.messages.at(-1)).toMatchObject({
      type: "file_transfer_upload_result_v2",
      transferId: ready.transferId,
      success: true,
    });

    await f.manager.offerFile({ filePath: f.source, projectPath: f.root });
    const offer = owner.messages.findLast(
      (message) => message.type === "file_transfer_offer_v2",
    );
    if (!offer || offer.type !== "file_transfer_offer_v2") {
      throw new Error("expected offer");
    }
    await f.manager.handleClientMessage(otherClient, {
      type: "file_transfer_cancel_v2",
      requestId: "wrong-download-cancel",
      transferId: offer.transferId,
      direction: "download",
      downloadToken: "w".repeat(43),
    });
    expect(other.messages.at(-1)).toMatchObject({
      type: "file_transfer_cancel_result_v2",
      requestId: "wrong-download-cancel",
      success: true,
    });
    await f.manager.handleClientMessage(ownerClient, {
      type: "file_transfer_receive_result_v2",
      transferId: offer.transferId,
      success: true,
      receivedBytes: offer.sizeBytes,
    });
    expect(await f.state.getDownload(offer.transferId)).toBeUndefined();
  });

  it("stops new WS control work and drains an admitted prepare before releasing the state lock", async () => {
    const f = await fixture();
    const client = {};
    const peer = binding(["file_transfer_upload_ready_v2", "file_transfer_upload_result_v2"]);
    f.manager.connect(client, peer.binding);
    const originalPrepare = f.uploadStore.prepare.bind(f.uploadStore);
    let release!: () => void;
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const prepareSpy = vi.spyOn(f.uploadStore, "prepare").mockImplementation(async (...args) => {
      await gate;
      return originalPrepare(...args);
    });
    const first = f.manager.handleClientMessage(client, {
      type: "file_transfer_upload_prepare_v2",
      requestId: "admitted",
      transferId: "upload_shutdown01",
      resumeToken,
      filename: "shutdown.bin",
      sizeBytes: 1,
    });
    await vi.waitFor(() => expect(prepareSpy).toHaveBeenCalledOnce());
    const closing = f.manager.close();
    await f.manager.handleClientMessage(client, {
      type: "file_transfer_upload_prepare_v2",
      requestId: "rejected-after-close",
      transferId: "upload_shutdown02",
      resumeToken: "s".repeat(43),
      filename: "later.bin",
      sizeBytes: 1,
    });
    expect(prepareSpy).toHaveBeenCalledOnce();

    const successor = new FileTransferStateStore({ filePath: f.state.filePath });
    await expect(successor.init()).rejects.toThrow("Another Bridge process");
    release();
    await first;
    await closing;
    await expect(successor.init()).resolves.toBeUndefined();
    await successor.close();
  });
});
