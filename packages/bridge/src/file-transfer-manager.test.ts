import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { FileTransferDownloadStore } from "./file-transfer-download-store.js";
import {
  FileTransferManager,
  type FileTransferClientBinding,
} from "./file-transfer-manager.js";
import type { FileTransferServerMessage } from "./file-transfer-protocol.js";
import { FileTransferStateStore } from "./file-transfer-state-store.js";
import { FileTransferUploadStore } from "./file-transfer-upload-store.js";

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
}

async function fixture(options: { now?: () => number; maxChunkSizeBytes?: number } = {}): Promise<Fixture> {
  const root = await mkdtemp(join(tmpdir(), "ccpocket-transfer-manager-"));
  roots.push(root);
  const source = join(root, "report.pdf");
  const downloads = join(root, "downloads");
  const parts = join(root, "parts");
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
  const manager = new FileTransferManager({
    downloadStore,
    uploadStore,
    baseUrl: "http://100.64.0.1:8765",
  });
  await manager.init();
  managers.push(manager);
  return { root, source, state, downloadStore, uploadStore, manager };
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
