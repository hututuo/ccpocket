import { createServer, type Server } from "node:http";
import { request } from "node:http";
import {
  mkdtemp,
  mkdir,
  realpath,
  rename,
  rm,
  symlink,
  unlink,
  writeFile,
} from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { afterEach, describe, expect, it } from "vitest";
import {
  ArtifactHttpError,
  ArtifactStore,
  type PublishedArtifact,
} from "./artifact-store.js";
import { ArtifactHttpHandler, isLoopbackAddress } from "./artifact-http.js";
import { contentDisposition, parseByteRange } from "./artifact-content.js";

interface HttpResult {
  statusCode: number;
  headers: Record<string, string | string[] | undefined>;
  body: Buffer;
}

const stores: ArtifactStore[] = [];
const servers: Server[] = [];
const tempRoots: string[] = [];

afterEach(async () => {
  for (const store of stores.splice(0)) store.close();
  await Promise.all(
    servers
      .splice(0)
      .map(
        (server) =>
          new Promise<void>((resolve) => server.close(() => resolve())),
      ),
  );
  await Promise.all(
    tempRoots
      .splice(0)
      .map((root) => rm(root, { recursive: true, force: true })),
  );
});

async function tempRoot(): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), "ccpocket-artifact-test-"));
  tempRoots.push(root);
  return root;
}

function trackedStore(options: ConstructorParameters<typeof ArtifactStore>[0]) {
  const store = new ArtifactStore({ cleanupIntervalMs: 0, ...options });
  stores.push(store);
  return store;
}

async function startStore(store: ArtifactStore): Promise<number> {
  const handler = new ArtifactHttpHandler(store);
  const server = createServer((req, res) => {
    if (!handler.handleRequest(req, res)) {
      res.writeHead(404);
      res.end();
    }
  });
  servers.push(server);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("missing port");
  return address.port;
}

function httpRequest(
  port: number,
  path: string,
  options: {
    method?: string;
    headers?: Record<string, string | number>;
    body?: string | Buffer;
  } = {},
): Promise<HttpResult> {
  const body =
    options.body === undefined ? undefined : Buffer.from(options.body);
  return new Promise((resolve, reject) => {
    const req = request(
      {
        hostname: "127.0.0.1",
        port,
        path,
        method: options.method ?? "GET",
        headers: {
          ...(body ? { "Content-Length": body.length } : {}),
          ...options.headers,
        },
      },
      (res) => {
        const chunks: Buffer[] = [];
        res.on("data", (chunk: Buffer) => chunks.push(chunk));
        res.on("end", () => {
          resolve({
            statusCode: res.statusCode ?? 0,
            headers: res.headers,
            body: Buffer.concat(chunks),
          });
        });
      },
    );
    req.on("error", reject);
    req.end(body);
  });
}

async function publishOverHttp(
  port: number,
  filePath: string,
  extra: Record<string, unknown> = {},
): Promise<PublishedArtifact> {
  const result = await httpRequest(port, "/api/artifacts", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-CCPocket-Control": "1",
    },
    body: JSON.stringify({ filePath, ...extra }),
  });
  expect(result.statusCode).toBe(201);
  return (JSON.parse(result.body.toString()) as { artifact: PublishedArtifact })
    .artifact;
}

describe("ArtifactStore.publish", () => {
  it("creates a token-only preview URL without leaking the source path", async () => {
    const root = await tempRoot();
    const filePath = join(root, "报告 final.pdf");
    await writeFile(filePath, "pdf-content");
    const store = trackedStore({
      baseUrl: "http://192.168.1.20:8765",
      allowedDirs: [root],
      tokenFactory: () => "A".repeat(43),
    });

    const artifact = await store.publish(filePath);

    expect(artifact.previewUrl).toBe(
      `http://192.168.1.20:8765/artifacts/${"A".repeat(43)}`,
    );
    expect(JSON.stringify(artifact)).not.toContain(root);
    expect(artifact.markdown).toContain("预览并下载 报告 final.pdf");
  });

  it("rejects a file outside allowed directories", async () => {
    const allowed = await tempRoot();
    const outside = await tempRoot();
    const filePath = join(outside, "secret.txt");
    await writeFile(filePath, "secret");
    const store = trackedStore({
      baseUrl: "http://192.168.1.20:8765",
      allowedDirs: [allowed],
    });

    await expect(store.publish(filePath)).rejects.toMatchObject({
      statusCode: 403,
      code: "path_not_allowed",
    });
  });

  it("rejects a symlink that escapes an allowed directory", async () => {
    const allowed = await tempRoot();
    const outside = await tempRoot();
    const target = join(outside, "secret.txt");
    const link = join(allowed, "link.txt");
    await writeFile(target, "secret");
    await symlink(target, link);
    const store = trackedStore({
      baseUrl: "http://192.168.1.20:8765",
      allowedDirs: [allowed],
    });

    await expect(store.publish(link)).rejects.toMatchObject({
      statusCode: 403,
      code: "path_not_allowed",
    });
  });

  it("rejects directories and oversized files", async () => {
    const root = await tempRoot();
    const filePath = join(root, "large.bin");
    await writeFile(filePath, "1234");
    const store = trackedStore({
      baseUrl: "http://192.168.1.20:8765",
      allowedDirs: [root],
      maxFileSizeBytes: 3,
    });

    await expect(store.publish(root)).rejects.toMatchObject({
      code: "not_regular_file",
    });
    await expect(store.publish(filePath)).rejects.toMatchObject({
      statusCode: 413,
      code: "file_too_large",
    });
  });

  it("requires a valid mobile base URL", async () => {
    const root = await tempRoot();
    const filePath = join(root, "file.txt");
    await writeFile(filePath, "hello");
    const store = trackedStore({ allowedDirs: [root] });

    await expect(store.publish(filePath)).rejects.toMatchObject({
      statusCode: 503,
      code: "artifact_base_url_unavailable",
    });
  });

  it("fails safely when an injected token factory stays invalid", async () => {
    const root = await tempRoot();
    const filePath = join(root, "file.txt");
    await writeFile(filePath, "hello");
    const store = trackedStore({
      baseUrl: "http://192.168.1.20:8765",
      allowedDirs: [root],
      tokenFactory: () => "not-a-valid-token",
    });

    await expect(store.publish(filePath)).rejects.toMatchObject({
      statusCode: 500,
      code: "token_generation_failed",
    });
  });
});

describe("ArtifactStore.inspect and issue", () => {
  it("returns canonical metadata without minting a capability", async () => {
    const root = await tempRoot();
    const filePath = join(root, "报告 final.pdf");
    await writeFile(filePath, "pdf-content");
    const store = trackedStore({ allowedDirs: [root] });

    const inspected = await store.inspect(filePath);

    expect(inspected).toMatchObject({
      canonicalPath: await realpath(filePath),
      filename: "报告 final.pdf",
      mimeType: "application/pdf",
      sizeBytes: 11,
    });
    expect(inspected.identity).toMatchObject({ size: 11 });
    expect(JSON.stringify(inspected)).not.toContain("token");
  });

  it("returns a verified handle that stays bound after the path is replaced", async () => {
    const root = await tempRoot();
    const filePath = join(root, "source.txt");
    const movedPath = join(root, "source-moved.txt");
    await writeFile(filePath, "original inode");
    const store = trackedStore({ allowedDirs: [root] });

    const opened = await store.openVerified(filePath);
    try {
      await rename(filePath, movedPath);
      await writeFile(filePath, "replacement path");
      await expect(opened.handle.readFile("utf8")).resolves.toBe(
        "original inode",
      );
    } finally {
      await opened.handle.close();
    }
  });

  it("issues a relative URL without requiring a mobile base URL", async () => {
    const root = await tempRoot();
    const filePath = join(root, "file.txt");
    await writeFile(filePath, "hello");
    const store = trackedStore({
      allowedDirs: [root],
      tokenFactory: () => "R".repeat(43),
    });

    const issued = await store.issue(filePath);

    expect(issued.relativeUrl).toBe(`/artifacts/${"R".repeat(43)}`);
    expect(issued.relativeDownloadUrl).toBe(
      `/artifacts/${"R".repeat(43)}/download`,
    );
    expect(JSON.stringify(issued)).not.toContain(root);
  });

  it("requires the original identity when reissuing a persistent ref", async () => {
    const root = await tempRoot();
    const filePath = join(root, "file.txt");
    await writeFile(filePath, "before");
    const store = trackedStore({ allowedDirs: [root] });
    const inspected = await store.inspect(filePath);
    await writeFile(filePath, "after with another size");

    await expect(
      store.issue(filePath, { expectedIdentity: inspected.identity }),
    ).rejects.toMatchObject({ statusCode: 409, code: "file_changed" });
  });

  it("applies allowed-root and regular-file checks through inspect", async () => {
    const allowed = await tempRoot();
    const outside = await tempRoot();
    const outsideFile = join(outside, "secret.txt");
    await writeFile(outsideFile, "secret");
    const store = trackedStore({ allowedDirs: [allowed] });

    await expect(store.inspect(allowed)).rejects.toMatchObject({
      code: "not_regular_file",
    });
    await expect(store.inspect(outsideFile)).rejects.toMatchObject({
      statusCode: 403,
      code: "path_not_allowed",
    });
    await expect(
      store.inspect(join(allowed, "missing.txt")),
    ).rejects.toMatchObject({
      statusCode: 404,
      code: "file_not_found",
    });
  });
});

describe("ArtifactStore HTTP", () => {
  it("publishes only through the protected loopback control route", async () => {
    const root = await tempRoot();
    const filePath = join(root, "file.txt");
    await writeFile(filePath, "hello");
    const store = trackedStore({
      baseUrl: "http://192.168.1.20:8765",
      allowedDirs: [root],
    });
    const port = await startStore(store);

    const missingHeader = await httpRequest(port, "/api/artifacts", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ filePath }),
    });
    expect(missingHeader.statusCode).toBe(403);
    expect(
      missingHeader.headers["access-control-allow-origin"],
    ).toBeUndefined();

    const withOrigin = await httpRequest(port, "/api/artifacts", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-CCPocket-Control": "1",
        Origin: "https://evil.example",
      },
      body: JSON.stringify({ filePath }),
    });
    expect(withOrigin.statusCode).toBe(403);

    const wrongType = await httpRequest(port, "/api/artifacts", {
      method: "POST",
      headers: {
        "Content-Type": "text/plain",
        "X-CCPocket-Control": "1",
      },
      body: JSON.stringify({ filePath }),
    });
    expect(wrongType.statusCode).toBe(415);
  });

  it("rejects invalid and oversized control bodies", async () => {
    const root = await tempRoot();
    const store = trackedStore({
      baseUrl: "http://192.168.1.20:8765",
      allowedDirs: [root],
    });
    const port = await startStore(store);
    const headers = {
      "Content-Type": "application/json",
      "X-CCPocket-Control": "1",
    };

    const invalid = await httpRequest(port, "/api/artifacts", {
      method: "POST",
      headers,
      body: "{",
    });
    expect(invalid.statusCode).toBe(400);

    const nullBody = await httpRequest(port, "/api/artifacts", {
      method: "POST",
      headers,
      body: "null",
    });
    expect(nullBody.statusCode).toBe(400);

    const jsonp = await httpRequest(port, "/api/artifacts", {
      method: "POST",
      headers: {
        "Content-Type": "application/jsonp",
        "X-CCPocket-Control": "1",
      },
      body: "{}",
    });
    expect(jsonp.statusCode).toBe(415);

    const oversized = await httpRequest(port, "/api/artifacts", {
      method: "POST",
      headers,
      body: "x".repeat(17 * 1024),
    });
    expect(oversized.statusCode).toBe(413);
  });

  it("serves a responsive preview page without CORS", async () => {
    const root = await tempRoot();
    const filePath = join(root, "payload.txt");
    await writeFile(filePath, '<script>alert("x")</script>');
    const store = trackedStore({
      baseUrl: "http://192.168.1.20:8765",
      allowedDirs: [root],
    });
    const port = await startStore(store);
    const artifact = await publishOverHttp(port, filePath);
    const previewPath = new URL(artifact.previewUrl).pathname;

    const result = await httpRequest(port, previewPath);
    const embedded = await httpRequest(port, `${previewPath}?embedded=1`);

    expect(result.statusCode).toBe(200);
    expect(result.headers["content-type"]).toContain("text/html");
    expect(result.headers["access-control-allow-origin"]).toBeUndefined();
    expect(result.headers["content-security-policy"]).toContain(
      "default-src 'none'",
    );
    expect(result.body.toString()).toContain("&lt;script&gt;");
    expect(result.body.toString()).not.toContain('<script>alert("x")</script>');
    expect(embedded.statusCode).toBe(200);
    expect(embedded.body.toString()).toContain('class="shell embedded"');
    expect(embedded.body.toString()).not.toContain('id="artifact-toolbar"');
    expect(embedded.body.toString()).not.toContain(
      "preview-controls.v1.js",
    );
  });

  it("renders local HTML only through a same-origin opaque sandbox", async () => {
    const root = await tempRoot();
    const filePath = join(root, "page.html");
    await writeFile(
      filePath,
      '<!doctype html><script>document.body.textContent="ok"</script>',
    );
    const store = trackedStore({
      baseUrl: "http://192.168.1.20:8765",
      allowedDirs: [root],
    });
    const port = await startStore(store);
    const artifact = await publishOverHttp(port, filePath);
    const previewPath = new URL(artifact.previewUrl).pathname;

    const preview = await httpRequest(port, `${previewPath}?embedded=1`);
    const sandbox = await httpRequest(port, `${previewPath}/sandbox`);
    const rawContent = await httpRequest(port, `${previewPath}/content`);

    expect(preview.statusCode).toBe(200);
    expect(preview.body.toString()).toContain(`${previewPath}/sandbox`);
    expect(preview.body.toString()).toContain('sandbox="allow-scripts"');
    expect(sandbox.statusCode).toBe(200);
    expect(sandbox.headers["content-type"]).toContain("text/html");
    expect(sandbox.headers["content-security-policy"]).toContain(
      "sandbox allow-scripts",
    );
    expect(sandbox.headers["content-security-policy"]).toContain(
      "connect-src 'none'",
    );
    expect(sandbox.headers["cross-origin-resource-policy"]).toBe("same-origin");
    expect(sandbox.headers["access-control-allow-origin"]).toBeUndefined();
    expect(sandbox.body.toString()).toContain("document.body.textContent");
    expect(rawContent.headers["content-security-policy"]).toBe(
      "sandbox; default-src 'none'",
    );
  });

  it("pretty-prints valid JSON and keeps invalid JSON as bounded text", async () => {
    const root = await tempRoot();
    const validPath = join(root, "valid.json");
    const invalidPath = join(root, "invalid.json");
    await writeFile(validPath, '{"warning":"x","nested":{"ok":true}}');
    await writeFile(invalidPath, '{"warning":');
    const store = trackedStore({
      baseUrl: "http://192.168.1.20:8765",
      allowedDirs: [root],
    });
    const port = await startStore(store);
    const valid = await publishOverHttp(port, validPath);
    const invalid = await publishOverHttp(port, invalidPath);

    const validPreview = await httpRequest(
      port,
      new URL(valid.previewUrl).pathname,
    );
    const invalidPreview = await httpRequest(
      port,
      new URL(invalid.previewUrl).pathname,
    );

    expect(validPreview.body.toString()).toContain(
      "&quot;warning&quot;: &quot;x&quot;",
    );
    expect(validPreview.body.toString()).toContain(
      "&quot;ok&quot;: true",
    );
    expect(invalidPreview.statusCode).toBe(200);
    expect(invalidPreview.body.toString()).toContain(
      "{&quot;warning&quot;:",
    );
  });

  it("streams full, HEAD, and byte-range content with safe headers", async () => {
    const root = await tempRoot();
    const filePath = join(root, "报告 2026.txt");
    await writeFile(filePath, "0123456789");
    const store = trackedStore({
      baseUrl: "http://192.168.1.20:8765",
      allowedDirs: [root],
    });
    const port = await startStore(store);
    const artifact = await publishOverHttp(port, filePath);
    const previewPath = new URL(artifact.previewUrl).pathname;

    const full = await httpRequest(port, `${previewPath}/download`);
    expect(full.statusCode).toBe(200);
    expect(full.body.toString()).toBe("0123456789");
    expect(full.headers["content-disposition"]).toContain("attachment");
    expect(full.headers["content-disposition"]).toContain("filename*=UTF-8''");
    expect(full.headers["cache-control"]).toContain("no-store");
    expect(full.headers["x-content-type-options"]).toBe("nosniff");

    const head = await httpRequest(port, `${previewPath}/content`, {
      method: "HEAD",
      headers: { Range: "bytes=2-4" },
    });
    expect(head.statusCode).toBe(200);
    expect(head.body).toHaveLength(0);
    expect(head.headers["content-length"]).toBe("10");

    const range = await httpRequest(port, `${previewPath}/content`, {
      headers: { Range: "bytes=2-5" },
    });
    expect(range.statusCode).toBe(206);
    expect(range.body.toString()).toBe("2345");
    expect(range.headers["content-range"]).toBe("bytes 2-5/10");

    const suffix = await httpRequest(port, `${previewPath}/content`, {
      headers: { Range: "bytes=-3" },
    });
    expect(suffix.statusCode).toBe(206);
    expect(suffix.body.toString()).toBe("789");
  });

  it("returns 416 for invalid or multiple ranges", async () => {
    const root = await tempRoot();
    const filePath = join(root, "file.bin");
    await writeFile(filePath, "12345");
    const store = trackedStore({
      baseUrl: "http://192.168.1.20:8765",
      allowedDirs: [root],
    });
    const port = await startStore(store);
    const artifact = await publishOverHttp(port, filePath);
    const previewPath = new URL(artifact.previewUrl).pathname;

    for (const range of ["bytes=9-10", "bytes=4-2", "bytes=0-1,3-4"]) {
      const result = await httpRequest(port, `${previewPath}/content`, {
        headers: { Range: range },
      });
      expect(result.statusCode).toBe(416);
      expect(result.headers["content-range"]).toBe("bytes */5");
    }
  });

  it("returns 409 when a shared file changes", async () => {
    const root = await tempRoot();
    const filePath = join(root, "file.txt");
    await writeFile(filePath, "before");
    const store = trackedStore({
      baseUrl: "http://192.168.1.20:8765",
      allowedDirs: [root],
    });
    const port = await startStore(store);
    const artifact = await publishOverHttp(port, filePath);
    await writeFile(filePath, "after-with-new-size");

    const result = await httpRequest(
      port,
      `${new URL(artifact.previewUrl).pathname}/content`,
    );
    expect(result.statusCode).toBe(409);
  });

  it("returns 410 when a shared file is deleted", async () => {
    const root = await tempRoot();
    const filePath = join(root, "file.txt");
    await writeFile(filePath, "before");
    const store = trackedStore({
      baseUrl: "http://192.168.1.20:8765",
      allowedDirs: [root],
    });
    const port = await startStore(store);
    const artifact = await publishOverHttp(port, filePath);
    await unlink(filePath);

    const result = await httpRequest(
      port,
      `${new URL(artifact.previewUrl).pathname}/content`,
    );
    expect(result.statusCode).toBe(410);
  });

  it("expires links in memory", async () => {
    let now = Date.parse("2026-07-16T01:00:00.000Z");
    const root = await tempRoot();
    const filePath = join(root, "file.txt");
    await writeFile(filePath, "hello");
    const store = trackedStore({
      baseUrl: "http://192.168.1.20:8765",
      allowedDirs: [root],
      now: () => now,
    });
    const port = await startStore(store);
    const artifact = await publishOverHttp(port, filePath, { ttlSeconds: 60 });
    now += 61_000;

    const result = await httpRequest(
      port,
      new URL(artifact.previewUrl).pathname,
    );
    expect(result.statusCode).toBe(404);
  });

  it("serves local DOCX viewer assets", async () => {
    const store = trackedStore({
      baseUrl: "http://192.168.1.20:8765",
      allowedDirs: [],
    });
    const port = await startStore(store);

    const loader = await httpRequest(port, "/artifacts/assets/docx-viewer.js");
    const controls = await httpRequest(
      port,
      "/artifacts/assets/preview-controls.v1.js",
    );
    const renderer = await httpRequest(
      port,
      "/artifacts/assets/docx-preview.min.js",
    );
    const jszip = await httpRequest(port, "/artifacts/assets/jszip.min.js");

    expect(loader.statusCode).toBe(200);
    expect(loader.body.toString()).toContain("renderAsync");
    expect(controls.statusCode).toBe(200);
    expect(controls.body.toString()).toContain("navigator.share");
    expect(renderer.statusCode).toBe(200);
    expect(renderer.body.length).toBeGreaterThan(10_000);
    expect(jszip.statusCode).toBe(200);
    expect(jszip.body.length).toBeGreaterThan(10_000);
  });
});

describe("artifact HTTP helpers", () => {
  it.each(["127.0.0.1", "127.1.2.3", "::1", "::ffff:127.0.0.1"])(
    "accepts loopback address %s",
    (address) => expect(isLoopbackAddress(address)).toBe(true),
  );

  it.each(["192.168.1.20", "100.64.0.2", "::ffff:192.168.1.20"])(
    "rejects remote address %s",
    (address) => expect(isLoopbackAddress(address)).toBe(false),
  );

  it("parses open, closed, and suffix byte ranges", () => {
    expect(parseByteRange("bytes=2-4", 10)).toEqual({ start: 2, end: 4 });
    expect(parseByteRange("bytes=7-", 10)).toEqual({ start: 7, end: 9 });
    expect(parseByteRange("bytes=-4", 10)).toEqual({ start: 6, end: 9 });
    expect(parseByteRange("bytes=20-30", 10)).toBeNull();
  });

  it("sanitizes content disposition filenames", () => {
    const header = contentDisposition("attachment", '报告"\r\n\\final.docx');
    expect(header).not.toContain("\r");
    expect(header).not.toContain("\n");
    expect(header).toContain("filename*=UTF-8''");
  });

  it("exposes structured publish errors", () => {
    const error = new ArtifactHttpError(403, "denied", "Denied");
    expect(error).toMatchObject({ statusCode: 403, code: "denied" });
  });
});
