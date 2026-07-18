import { EventEmitter } from "node:events";
import { createServer, request } from "node:http";
import type { AddressInfo } from "node:net";
import { mkdtemp, mkdir, readFile, rm, stat, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { FileTransferDownloadStore } from "./file-transfer-download-store.js";
import {
  FileTransferHttpHandler,
  streamFileTransferDownloadRange,
  type FileTransferHttpHandlerOptions,
} from "./file-transfer-http.js";
import {
  FileTransferManager,
  type FileTransferClientBinding,
} from "./file-transfer-manager.js";
import type { FileTransferServerMessage } from "./file-transfer-protocol.js";
import { sendFileViaBridge } from "./file-transfer-send-command.js";
import { FileTransferStateStore } from "./file-transfer-state-store.js";
import { FileTransferUploadStore } from "./file-transfer-upload-store.js";

const cleanups: Array<() => Promise<void>> = [];
const resumeToken = "r".repeat(43);

afterEach(async () => {
  await Promise.all(cleanups.splice(0).map((cleanup) => cleanup()));
});

interface Fixture {
  root: string;
  source: string;
  downloads: string;
  manager: FileTransferManager;
  state: FileTransferStateStore;
  handler: FileTransferHttpHandler;
  port: number;
}

async function fixture(options: {
  sourceContent?: Buffer | string;
  maxChunkSizeBytes?: number;
  http?: FileTransferHttpHandlerOptions;
} = {}): Promise<Fixture> {
  const root = await mkdtemp(join(tmpdir(), "ccpocket-transfer-http-"));
  const source = join(root, "source.bin");
  const downloads = join(root, "downloads");
  const parts = join(root, "parts");
  await writeFile(source, options.sourceContent ?? "source");
  await mkdir(downloads);
  let idSequence = 0;
  let tokenSequence = 0;
  let etagSequence = 0;
  const state = new FileTransferStateStore({ filePath: join(root, "state.json") });
  const downloadStore = new FileTransferDownloadStore({
    stateStore: state,
    allowedDirs: [root],
    transferIdFactory: () => `download_${String(++idSequence).padStart(8, "0")}`,
    tokenFactory: () => `${String(++tokenSequence).padStart(43, "d")}`.slice(-43),
    etagFactory: () => `"${String(++etagSequence).padStart(32, "e")}"`,
  });
  const uploadStore = new FileTransferUploadStore({
    stateStore: state,
    directory: downloads,
    partialDirectory: parts,
    diskSafetyMarginBytes: 0,
    maxChunkSizeBytes: options.maxChunkSizeBytes,
    tokenFactory: () => `${String(++tokenSequence).padStart(43, "u")}`.slice(-43),
  });
  const manager = new FileTransferManager({
    downloadStore,
    uploadStore,
    baseUrl: "http://100.64.0.1:8765",
  });
  await manager.init();
  const handler = new FileTransferHttpHandler(manager, options.http);
  const server = createServer((req, res) => {
    if (!handler.handleRequest(req, res)) res.writeHead(404).end("Not Found");
  });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => resolve());
  });
  const port = (server.address() as AddressInfo).port;
  cleanups.push(async () => {
    await handler.close();
    await new Promise<void>((resolve) => server.close(() => resolve()));
    await manager.close();
    await rm(root, { recursive: true, force: true });
  });
  return { root, source, downloads, manager, state, handler, port };
}

function phone(supported: string[]) {
  const messages: FileTransferServerMessage[] = [];
  const binding: FileTransferClientBinding = {
    supports: (type) => supported.includes(type),
    isOpen: () => true,
    send: (message) => {
      messages.push(message);
      return true;
    },
  };
  return { binding, messages };
}

interface HttpResult {
  status: number;
  headers: Record<string, string | string[] | undefined>;
  body: Buffer;
}

function httpRequest(
  port: number,
  method: string,
  path: string,
  headers: Record<string, string | number> = {},
  body?: Buffer | string,
): Promise<HttpResult> {
  const payload = body === undefined ? undefined : Buffer.from(body);
  return new Promise((resolve, reject) => {
    const req = request({ hostname: "127.0.0.1", port, path, method, headers }, (res) => {
      const chunks: Buffer[] = [];
      res.on("data", (chunk) => chunks.push(Buffer.from(chunk)));
      res.on("end", () => resolve({
        status: res.statusCode ?? 0,
        headers: res.headers,
        body: Buffer.concat(chunks),
      }));
    });
    req.once("error", reject);
    req.end(payload);
  });
}

function json(result: HttpResult): Record<string, unknown> {
  return JSON.parse(result.body.toString("utf8")) as Record<string, unknown>;
}

async function offer(f: Fixture): Promise<Extract<FileTransferServerMessage, { type: "file_transfer_offer_v2" }>> {
  const peer = phone(["file_transfer_offer_v2"]);
  f.manager.connect({}, peer.binding);
  await f.manager.offerFile({ filePath: f.source, projectPath: f.root, ttlSeconds: 600 });
  const message = peer.messages[0];
  if (message.type !== "file_transfer_offer_v2") throw new Error("expected offer");
  return message;
}

async function prepareUpload(
  f: Fixture,
  sizeBytes: number,
): Promise<{
  client: object;
  peer: ReturnType<typeof phone>;
  ready: Extract<FileTransferServerMessage, { type: "file_transfer_upload_ready_v2" }>;
}> {
  const client = {};
  const peer = phone(["file_transfer_upload_ready_v2", "file_transfer_upload_result_v2"]);
  f.manager.connect(client, peer.binding);
  await f.manager.handleClientMessage(client, {
    type: "file_transfer_upload_prepare_v2",
    requestId: "prepare-request",
    transferId: "upload_http00001",
    resumeToken,
    filename: "phone.bin",
    sizeBytes,
  });
  const ready = peer.messages[0];
  if (ready.type !== "file_transfer_upload_ready_v2") throw new Error("expected ready");
  return { client, peer, ready };
}

function transferHeaders(token: string): Record<string, string> {
  return { "X-CCPocket-Transfer-Token": token };
}

describe("FileTransferHttpHandler v2", () => {
  it("requires loopback control authentication, rejects browser origins, and returns only offered semantics", async () => {
    const f = await fixture();
    const body = JSON.stringify({
      filePath: f.source,
      projectPath: f.root,
      ttlSeconds: 600,
      baseUrl: "http://100.64.0.1:8765",
    });
    const missing = await httpRequest(f.port, "POST", "/api/file-transfers/send", {
      "Content-Type": "application/json",
      "Content-Length": Buffer.byteLength(body),
    }, body);
    expect(missing.status).toBe(403);
    expect(json(missing)).toMatchObject({ errorCode: "control_header_required" });

    const browser = await httpRequest(f.port, "POST", "/api/file-transfers/send", {
      "Content-Type": "application/json",
      "Content-Length": Buffer.byteLength(body),
      "X-CCPocket-Control": "1",
      Origin: "https://example.com",
    }, body);
    expect(browser.status).toBe(403);
    expect(json(browser)).toMatchObject({ errorCode: "origin_not_allowed" });

    const peer = phone(["file_transfer_offer_v2"]);
    f.manager.connect({}, peer.binding);
    const offered = await httpRequest(f.port, "POST", "/api/file-transfers/send", {
      "Content-Type": "application/json",
      "Content-Length": Buffer.byteLength(body),
      "X-CCPocket-Control": "1",
    }, body);
    expect(offered.status).toBe(202);
    expect(json(offered)).toMatchObject({
      status: "offered",
      transferId: "download_00000001",
      recipientCount: 1,
    });
  });

  it("cancels a slow CLI control request before any late phone offer", async () => {
    const f = await fixture();
    const peer = phone(["file_transfer_offer_v2"]);
    f.manager.connect({}, peer.binding);
    const originalIssue = f.manager.downloadStore.issue.bind(
      f.manager.downloadStore,
    );
    let releaseIssue!: () => void;
    const issueGate = new Promise<void>((resolve) => {
      releaseIssue = resolve;
    });
    let issued = false;
    vi.spyOn(f.manager.downloadStore, "issue").mockImplementation(
      async (...args) => {
        const value = await originalIssue(...args);
        issued = true;
        await issueGate;
        return value;
      },
    );
    const originalOffer = f.manager.offerFile.bind(f.manager);
    let controlSignal: AbortSignal | undefined;
    vi.spyOn(f.manager, "offerFile").mockImplementation(async (input) => {
      controlSignal = input.signal;
      return originalOffer(input);
    });

    try {
      const outcome = sendFileViaBridge({
        filePath: f.source,
        projectPath: f.root,
        port: f.port,
        responseTimeoutMs: 25,
      }).then<Error | null>(
        () => null,
        (error: unknown) =>
          error instanceof Error ? error : new Error(String(error)),
      );
      await vi.waitFor(() => expect(issued).toBe(true));
      expect((await outcome)?.message).toContain(
        "Timed out waiting for the local Bridge response",
      );
      await vi.waitFor(() => expect(controlSignal?.aborted).toBe(true));
      releaseIssue();
      await vi.waitFor(async () => {
        expect(await f.state.listDownloads()).toEqual([]);
      });
      expect(peer.messages).toEqual([]);
    } finally {
      releaseIssue();
    }
  });

  it("supports HEAD plus exact adaptive 1 MiB, 10 MiB, and non-integral ranges", async () => {
    const oneMiB = 1024 * 1024;
    const tenMiB = 10 * oneMiB;
    const tail = 12_345;
    const content = Buffer.alloc(oneMiB + tenMiB + tail, 0x5a);
    const f = await fixture({ sourceContent: content });
    const offered = await offer(f);
    const headers = transferHeaders(offered.downloadToken);
    const head = await httpRequest(f.port, "HEAD", new URL(offered.downloadUrl).pathname, headers);
    expect(head.status).toBe(200);
    expect(head.headers).toMatchObject({
      "content-length": String(content.length),
      "accept-ranges": "bytes",
      etag: offered.etag,
      "x-ccpocket-max-chunk-bytes": String(16 * oneMiB),
    });

    let offset = 0;
    for (const length of [oneMiB, tenMiB, tail]) {
      const result = await httpRequest(
        f.port,
        "GET",
        new URL(offered.downloadUrl).pathname,
        {
          ...headers,
          Range: `bytes=${offset}-${offset + length - 1}`,
          "If-Range": offered.etag,
        },
      );
      expect(result.status, `range starting at ${offset}`).toBe(206);
      expect(result.body.length).toBe(length);
      expect(result.headers["content-range"]).toBe(
        `bytes ${offset}-${offset + length - 1}/${content.length}`,
      );
      offset += length;
    }
    expect(offset).toBe(content.length);
  });

  it("does not reuse a short-read buffer before a slow response write completes", async () => {
    const source = Buffer.from(Array.from({ length: 13 }, (_, index) => index + 1));
    const written: Buffer[] = [];
    const read = vi.fn(
      async (buffer: Buffer, _offset: number, length: number, position: number) => {
        const bytesRead = Math.min(3, length, source.length - position);
        source.copy(buffer, 0, position, position + bytesRead);
        return { bytesRead, buffer };
      },
    );
    const opened = {
      handle: { read },
    } as unknown as Parameters<typeof streamFileTransferDownloadRange>[0];
    const req = new EventEmitter() as unknown as Parameters<
      typeof streamFileTransferDownloadRange
    >[3];
    const responseEvents = new EventEmitter();
    const res = Object.assign(responseEvents, {
      destroyed: false,
      closed: false,
      write: (
        chunk: Uint8Array,
        callback: (error?: Error | null) => void,
      ): boolean => {
        setTimeout(() => {
          written.push(Buffer.from(chunk));
          callback();
        }, 2);
        return true;
      },
    }) as unknown as Parameters<typeof streamFileTransferDownloadRange>[4];

    const finalByte = await streamFileTransferDownloadRange(
      opened,
      0,
      source.length - 1,
      req,
      res,
      1_000,
      5_000,
    );

    expect(read.mock.calls.length).toBeGreaterThan(1);
    expect(Buffer.concat([...written, finalByte])).toEqual(source);
  });

  it("enforces one explicit range, strong If-Range, actual 416 size, and the max range", async () => {
    const f = await fixture({ sourceContent: Buffer.alloc(17 * 1024 * 1024) });
    const offered = await offer(f);
    const path = new URL(offered.downloadUrl).pathname;
    const token = transferHeaders(offered.downloadToken);
    const missing = await httpRequest(f.port, "GET", path, {
      ...token,
      "If-Range": offered.etag,
    });
    expect(missing.status).toBe(428);
    const invalid = await httpRequest(f.port, "GET", path, {
      ...token,
      Range: `bytes=${17 * 1024 * 1024}-${17 * 1024 * 1024 + 1}`,
      "If-Range": offered.etag,
    });
    expect(invalid.status).toBe(416);
    expect(invalid.headers["content-range"]).toBe(`bytes */${17 * 1024 * 1024}`);
    const stale = await httpRequest(f.port, "GET", path, {
      ...token,
      Range: "bytes=0-0",
      "If-Range": `"${"x".repeat(32)}"`,
    });
    expect(stale.status).toBe(412);
    const tooLarge = await httpRequest(f.port, "GET", path, {
      ...token,
      Range: `bytes=0-${16 * 1024 * 1024}`,
      "If-Range": offered.etag,
    });
    expect(tooLarge.status).toBe(413);
  });

  it("detects same-size in-place source modification even when mtime is restored", async () => {
    const f = await fixture({ sourceContent: "source" });
    const offered = await offer(f);
    const before = await stat(f.source);
    await new Promise((resolve) => setTimeout(resolve, 20));
    await writeFile(f.source, "mutate");
    await utimes(f.source, before.atime, before.mtime);
    const result = await httpRequest(f.port, "HEAD", new URL(offered.downloadUrl).pathname, {
      ...transferHeaders(offered.downloadToken),
    });
    expect(result.status).toBe(409);
  });

  it("reserves a download concurrency slot synchronously before awaiting file open", async () => {
    const f = await fixture({ sourceContent: Buffer.alloc(2) , http: { maxActiveDownloads: 1 } });
    const first = await offer(f);
    // Keep exactly one compatible peer but issue a second independent offer.
    const second = await f.manager.offerFile({ filePath: f.source, projectPath: f.root, ttlSeconds: 600 });
    const persisted = await f.state.getDownload(second.transferId);
    if (!persisted) throw new Error("missing second transfer");
    const peerOffer = (f.manager as unknown as { downloadStore: FileTransferDownloadStore }).downloadStore;
    const original = peerOffer.openAuthorized.bind(peerOffer);
    let release!: () => void;
    const gate = new Promise<void>((resolve) => { release = resolve; });
    let calls = 0;
    vi.spyOn(peerOffer, "openAuthorized").mockImplementation(async (...args) => {
      calls += 1;
      if (calls === 1) await gate;
      return original(...args);
    });
    const firstRequest = httpRequest(f.port, "GET", new URL(first.downloadUrl).pathname, {
      ...transferHeaders(first.downloadToken),
      Range: "bytes=0-0",
      "If-Range": first.etag,
    });
    await vi.waitFor(() => expect(calls).toBe(1));
    const latestOffer = (await f.state.listDownloads()).find((entry) => entry.transferId === second.transferId);
    if (!latestOffer) throw new Error("missing transfer");
    // The second token is present only in the actual WebSocket offer; obtain it
    // by issuing a fresh store session would disturb the assertion, so test the
    // global slot before authorization with any syntactically valid token.
    const rejected = await httpRequest(f.port, "GET", `/api/file-transfers/downloads/${second.transferId}`, {
      ...transferHeaders("z".repeat(43)),
      Range: "bytes=0-0",
      "If-Range": latestOffer.etag,
    });
    expect(rejected.status).toBe(429);
    expect(calls).toBe(1);
    release();
    expect((await firstRequest).status).toBe(206);
  });

  it("accepts adaptive upload PATCH offsets and advertises the actual configured max", async () => {
    const oneMiB = 1024 * 1024;
    const tenMiB = 10 * oneMiB;
    const tail = 12_345;
    const total = oneMiB + tenMiB + tail;
    const f = await fixture({ maxChunkSizeBytes: tenMiB });
    const { peer, ready } = await prepareUpload(f, total);
    const path = new URL(ready.uploadUrl).pathname;
    const common = {
      ...transferHeaders(ready.uploadToken),
      "Content-Type": "application/offset+octet-stream",
    };
    const head = await httpRequest(f.port, "HEAD", path, transferHeaders(ready.uploadToken));
    expect(head.status).toBe(200);
    expect(head.headers["upload-offset"]).toBe("0");
    expect(head.headers["x-ccpocket-max-chunk-bytes"]).toBe(String(tenMiB));

    let offset = 0;
    for (const [length, fill] of [[oneMiB, 1], [tenMiB, 2], [tail, 3]] as const) {
      const payload = Buffer.alloc(length, fill);
      const result = await httpRequest(f.port, "PATCH", path, {
        ...common,
        "Content-Length": payload.length,
        "Upload-Offset": offset,
      }, payload);
      expect(result.status).toBe(204);
      offset += length;
      expect(result.headers["upload-offset"]).toBe(String(offset));
    }
    expect(await readFile(join(f.downloads, "phone.bin"))).toHaveLength(total);
    expect(peer.messages.at(-1)).toMatchObject({
      type: "file_transfer_upload_result_v2",
      success: true,
      sizeBytes: total,
    });
  });

  it("returns the authoritative offset and rejects zero or over-limit upload chunks", async () => {
    const f = await fixture({ maxChunkSizeBytes: 1024 });
    const { ready } = await prepareUpload(f, 2_000);
    const path = new URL(ready.uploadUrl).pathname;
    const common = {
      ...transferHeaders(ready.uploadToken),
      "Content-Type": "application/offset+octet-stream",
    };
    const wrongOffset = await httpRequest(f.port, "PATCH", path, {
      ...common,
      "Content-Length": 1,
      "Upload-Offset": 1,
    }, "x");
    expect(wrongOffset.status).toBe(409);
    expect(wrongOffset.headers["upload-offset"]).toBe("0");
    const zero = await httpRequest(f.port, "PATCH", path, {
      ...common,
      "Content-Length": 0,
      "Upload-Offset": 0,
    });
    expect(zero.status).toBe(413);
    const tooLarge = await httpRequest(f.port, "PATCH", path, {
      ...common,
      "Content-Length": 1025,
      "Upload-Offset": 0,
    }, Buffer.alloc(1025));
    expect(tooLarge.status).toBe(413);
  });

  it("destroys a slowloris upload request so the blocked iterator wakes and offset rolls back", async () => {
    const f = await fixture({ http: { idleTimeoutMs: 40, totalTimeoutMs: 500 } });
    const { ready } = await prepareUpload(f, 5);
    const path = new URL(ready.uploadUrl).pathname;
    await expect(new Promise<void>((resolve, reject) => {
      const req = request({
        hostname: "127.0.0.1",
        port: f.port,
        path,
        method: "PATCH",
        headers: {
          ...transferHeaders(ready.uploadToken),
          "Content-Type": "application/offset+octet-stream",
          "Content-Length": 5,
          "Upload-Offset": 0,
        },
      });
      req.once("response", (res) => {
        res.resume();
        res.once("end", resolve);
      });
      req.once("error", reject);
      req.write("x");
      req.flushHeaders();
    })).rejects.toThrow();
    const head = await httpRequest(f.port, "HEAD", path, transferHeaders(ready.uploadToken));
    expect(head.status).toBe(200);
    expect(head.headers["upload-offset"]).toBe("0");
  });

  it("stops new routes, aborts and drains in-flight HTTP before the state lock is released", async () => {
    const f = await fixture({ http: { idleTimeoutMs: 10_000, totalTimeoutMs: 20_000 } });
    const { ready } = await prepareUpload(f, 5);
    const path = new URL(ready.uploadUrl).pathname;
    const inFlight = new Promise<void>((resolve, reject) => {
      const req = request({
        hostname: "127.0.0.1",
        port: f.port,
        path,
        method: "PATCH",
        headers: {
          ...transferHeaders(ready.uploadToken),
          "Content-Type": "application/offset+octet-stream",
          "Content-Length": 5,
          "Upload-Offset": 0,
        },
      });
      req.once("response", (res) => {
        res.resume();
        res.once("end", resolve);
      });
      req.once("error", reject);
      req.write("x");
      req.flushHeaders();
    });
    const inFlightRejected = expect(inFlight).rejects.toThrow();
    await new Promise((resolve) => setTimeout(resolve, 20));
    await f.handler.close();
    await inFlightRejected;
    const rejected = await httpRequest(f.port, "HEAD", path, transferHeaders(ready.uploadToken));
    expect(rejected.status).toBe(503);

    await f.manager.close();
    const successor = new FileTransferStateStore({ filePath: f.state.filePath });
    await expect(successor.init()).resolves.toBeUndefined();
    await successor.close();
  });
});
