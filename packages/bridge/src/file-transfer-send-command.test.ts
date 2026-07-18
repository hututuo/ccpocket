import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { afterEach, describe, expect, it } from "vitest";
import {
  parseFileTransferTtl,
  sendFileViaBridge,
} from "./file-transfer-send-command.js";

const servers: Array<ReturnType<typeof createServer>> = [];

afterEach(async () => {
  await Promise.all(
    servers.splice(0).map(
      (server) => new Promise<void>((resolve) => server.close(() => resolve())),
    ),
  );
});

describe("file transfer send command", () => {
  it("validates TTL and a mobile-reachable base URL", async () => {
    expect(parseFileTransferTtl("60")).toBe(60);
    expect(parseFileTransferTtl("86400")).toBe(86400);
    expect(() => parseFileTransferTtl("59")).toThrow("between 60 and 86400");
    expect(() => parseFileTransferTtl("1.5")).toThrow("integer");
    await expect(
      sendFileViaBridge({
        filePath: "x",
        projectPath: "/",
        port: 1,
        baseUrl: "http://127.0.0.1:8765",
      }),
    ).rejects.toThrow("mobile-reachable");
  });

  it("uses only the loopback control endpoint and parses a 202 result", async () => {
    let observed: { url?: string; host?: string; control?: string; body?: unknown } = {};
    const server = createServer((req, res) => {
      const chunks: Buffer[] = [];
      req.on("data", (chunk) => chunks.push(Buffer.from(chunk)));
      req.on("end", () => {
        observed = {
          url: req.url,
          host: req.socket.localAddress,
          control: req.headers["x-ccpocket-control"] as string,
          body: JSON.parse(Buffer.concat(chunks).toString("utf8")),
        };
        res.writeHead(202, { "Content-Type": "application/json" });
        res.end(JSON.stringify({
          status: "offered",
          transferId: "download_1234567",
          recipientCount: 1,
          filename: "report.pdf",
          mimeType: "application/pdf",
          sizeBytes: 42,
          expiresAt: new Date(Date.now() + 60_000).toISOString(),
        }));
      });
    });
    servers.push(server);
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    const port = (server.address() as AddressInfo).port;

    await expect(sendFileViaBridge({
      filePath: "/tmp/report.pdf",
      projectPath: "/tmp",
      port,
      ttlSeconds: 600,
      baseUrl: "http://100.64.0.1:8765",
    })).resolves.toMatchObject({
      status: "offered",
      transferId: "download_1234567",
      recipientCount: 1,
    });
    expect(observed).toMatchObject({
      url: "/api/file-transfers/send",
      host: "127.0.0.1",
      control: "1",
      body: {
        filePath: "/tmp/report.pdf",
        projectPath: "/tmp",
        ttlSeconds: 600,
        baseUrl: "http://100.64.0.1:8765",
      },
    });
  });

  it("surfaces a bounded Bridge error", async () => {
    const server = createServer((_req, res) => {
      res.writeHead(409, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "No compatible live phone is connected" }));
    });
    servers.push(server);
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    const port = (server.address() as AddressInfo).port;

    await expect(sendFileViaBridge({ filePath: "x", projectPath: "/", port }))
      .rejects.toThrow("No compatible live phone");
  });

  it("fails boundedly when the Bridge closes a partial control response", async () => {
    const server = createServer((_req, res) => {
      res.writeHead(202, {
        "Content-Type": "application/json",
        "Content-Length": "256",
      });
      res.write('{"status":"offered"');
      setImmediate(() => res.destroy());
    });
    servers.push(server);
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    const port = (server.address() as AddressInfo).port;

    await expect(
      sendFileViaBridge({
        filePath: "x",
        projectPath: "/",
        port,
        responseTimeoutMs: 250,
      }),
    ).rejects.toThrow("response ended before completion");
  });

  it("rejects malformed 202 metadata instead of treating it as delivered", async () => {
    const invalidResponses = [
      {
        status: "saved",
        transferId: "download_1234567",
        recipientCount: 1,
        filename: "report.pdf",
        mimeType: "application/pdf",
        sizeBytes: 42,
        expiresAt: "2030-01-01T00:00:00.000Z",
      },
      {
        status: "offered",
        transferId: "short",
        recipientCount: 1,
        filename: "report.pdf",
        mimeType: "application/pdf",
        sizeBytes: 42,
        expiresAt: "not-a-date",
      },
      {
        status: "offered",
        transferId: "download_1234567",
        recipientCount: 1,
        filename: "report.pdf",
        mimeType: "application/pdf",
        sizeBytes: 42,
        expiresAt: "2020-01-01T00:00:00.000Z",
      },
      {
        status: "offered",
        transferId: "download_1234567",
        recipientCount: 1,
        filename: "report.pdf",
        mimeType: "application/pdf",
        sizeBytes: 15 * 1024 * 1024 * 1024 + 1,
        expiresAt: "2030-01-01T00:00:00.000Z",
      },
    ];
    for (const response of invalidResponses) {
      const server = createServer((_req, res) => {
        res.writeHead(202, { "Content-Type": "application/json" });
        res.end(JSON.stringify(response));
      });
      servers.push(server);
      await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
      const port = (server.address() as AddressInfo).port;
      await expect(sendFileViaBridge({ filePath: "x", projectPath: "/", port }))
        .rejects.toThrow("HTTP 202");
      await new Promise<void>((resolve) => server.close(() => resolve()));
      servers.splice(servers.indexOf(server), 1);
    }
  });
});
