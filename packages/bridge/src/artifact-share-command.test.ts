import { createServer, type Server } from "node:http";
import { afterEach, describe, expect, it } from "vitest";
import {
  parseShareTtl,
  publishArtifactViaBridge,
} from "./artifact-share-command.js";

const servers: Server[] = [];

afterEach(async () => {
  await Promise.all(
    servers.splice(0).map(
      (server) =>
        new Promise<void>((resolve) => server.close(() => resolve())),
    ),
  );
});

async function fakeBridge(
  handler: Parameters<typeof createServer>[0],
): Promise<number> {
  const server = createServer(handler);
  servers.push(server);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("missing port");
  return address.port;
}

describe("parseShareTtl", () => {
  it("parses a valid TTL", () => {
    expect(parseShareTtl("3600")).toBe(3600);
  });

  it.each(["", "1.5", "abc", "59", "86401"])(
    "rejects invalid TTL %j",
    (value) => expect(() => parseShareTtl(value)).toThrow("--ttl"),
  );
});

describe("publishArtifactViaBridge", () => {
  it("publishes through the loopback control API", async () => {
    const port = await fakeBridge((req, res) => {
      expect(req.method).toBe("POST");
      expect(req.url).toBe("/api/artifacts");
      expect(req.headers["x-ccpocket-control"]).toBe("1");
      const chunks: Buffer[] = [];
      req.on("data", (chunk: Buffer) => chunks.push(chunk));
      req.on("end", () => {
        const body = JSON.parse(Buffer.concat(chunks).toString()) as {
          filePath: string;
        };
        expect(body.filePath).toBe("/tmp/report.pdf");
        const artifact = {
          previewUrl: "http://192.168.1.20:8765/artifacts/token",
          downloadUrl: "http://192.168.1.20:8765/artifacts/token/download",
          markdown:
            "[预览并下载 report.pdf](http://192.168.1.20:8765/artifacts/token)",
          filename: "report.pdf",
          mimeType: "application/pdf",
          sizeBytes: 10,
          expiresAt: "2026-07-16T02:00:00.000Z",
        };
        res.writeHead(201, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ artifact }));
      });
    });

    const artifact = await publishArtifactViaBridge({
      filePath: "/tmp/report.pdf",
      projectPath: "/tmp",
      port,
      baseUrl: "http://192.168.1.20:8765",
    });

    expect(artifact.filename).toBe("report.pdf");
    expect(artifact.markdown).toContain("预览并下载");
  });

  it("surfaces Bridge errors", async () => {
    const port = await fakeBridge((_req, res) => {
      res.writeHead(403, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "File is outside allowed dirs" }));
    });

    await expect(
      publishArtifactViaBridge({
        filePath: "/tmp/secret.txt",
        projectPath: "/tmp",
        port,
      }),
    ).rejects.toThrow("outside allowed dirs");
  });

  it("rejects an unreachable mobile base URL before connecting", async () => {
    await expect(
      publishArtifactViaBridge({
        filePath: "/tmp/file.txt",
        projectPath: "/tmp",
        port: 8765,
        baseUrl: "http://127.0.0.1:8765",
      }),
    ).rejects.toThrow("mobile-reachable");
  });
});
