import {
  mkdir,
  mkdtemp,
  rm,
  symlink,
  unlink,
  writeFile,
} from "node:fs/promises";
import { createServer, request as sendHttpRequest } from "node:http";
import type { AddressInfo } from "node:net";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const { TEST_HOME } = vi.hoisted(() => ({
  TEST_HOME: `/tmp/ccpocket-gallery-test-home-${process.pid}`,
}));

vi.mock("node:os", async (importOriginal) => {
  const mod = await importOriginal<typeof import("node:os")>();
  return {
    ...mod,
    homedir: () => TEST_HOME,
  };
});

import { GalleryStore } from "./gallery-store.js";

async function galleryHttpRequest(
  store: GalleryStore,
  body: string,
  headers: Record<string, string | number> = {},
): Promise<{ statusCode: number; body: string }> {
  const server = createServer((req, res) => {
    if (store.handleUploadRequest(req, res)) return;
    res.writeHead(404);
    res.end();
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = (server.address() as AddressInfo).port;
  try {
    return await new Promise((resolve, reject) => {
      const req = sendHttpRequest(
        {
          host: "127.0.0.1",
          port,
          path: "/api/gallery/upload",
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "Content-Length": Buffer.byteLength(body),
            ...headers,
          },
        },
        (res) => {
          const chunks: Buffer[] = [];
          res.on("data", (chunk) => chunks.push(Buffer.from(chunk)));
          res.on("end", () => {
            resolve({
              statusCode: res.statusCode ?? 0,
              body: Buffer.concat(chunks).toString("utf8"),
            });
          });
        },
      );
      req.on("error", reject);
      req.end(body);
    });
  } finally {
    server.closeAllConnections();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
}

describe("GalleryStore.addImage", () => {
  beforeEach(async () => {
    await rm(TEST_HOME, { recursive: true, force: true });
    await mkdir(TEST_HOME, { recursive: true });
  });

  afterEach(async () => {
    await rm(TEST_HOME, { recursive: true, force: true });
  });

  it("resolves leading-slash project-relative paths", async () => {
    const root = await mkdtemp(join(tmpdir(), "ccpocket-gallery-project-"));
    try {
      const imageDir = join(root, "images");
      const imagePath = join(imageDir, "screenshots.png");
      await mkdir(imageDir, { recursive: true });
      await writeFile(imagePath, Buffer.from("89504e470d0a1a0a", "hex"));

      const store = new GalleryStore();
      await store.init();

      const meta = await store.addImage("/images/screenshots.png", root, "session-1");
      expect(meta).not.toBeNull();
      expect(meta?.sourcePath).toBe(imagePath);
      expect(meta?.mimeType).toBe("image/png");
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("persists a legacy provider-session binding and matches runtime OR provider session", async () => {
    const root = await mkdtemp(join(tmpdir(), "ccpocket-gallery-project-"));
    const galleryDirectory = await mkdtemp(
      join(tmpdir(), "ccpocket-gallery-store-"),
    );
    try {
      const imagePath = join(root, "legacy.png");
      await writeFile(imagePath, Buffer.from("89504e470d0a1a0a", "hex"));

      const initialStore = new GalleryStore({ directory: galleryDirectory });
      await initialStore.init();
      const legacyMeta = await initialStore.addImage(
        imagePath,
        root,
        "runtime-old",
      );
      expect(legacyMeta?.providerSessionId).toBeUndefined();

      const restartedStore = new GalleryStore({ directory: galleryDirectory });
      await restartedStore.init();
      const rebound = await restartedStore.bindProviderSessionIdBySourcePath(
        imagePath,
        "thread-stable",
      );
      expect(rebound?.id).toBe(legacyMeta?.id);
      expect(rebound?.providerSessionId).toBe("thread-stable");
      expect(
        restartedStore.list({
          sessionId: "runtime-new",
          providerSessionId: "thread-stable",
        }),
      ).toHaveLength(1);

      const secondRestart = new GalleryStore({ directory: galleryDirectory });
      await secondRestart.init();
      expect(
        secondRestart.list({
          sessionId: "runtime-newer",
          providerSessionId: "thread-stable",
        }),
      ).toHaveLength(1);

      // The repair lookup must not change normal addImage duplicate semantics.
      await secondRestart.addImage(
        imagePath,
        root,
        "runtime-newer",
        "thread-stable",
      );
      expect(
        secondRestart.list({ providerSessionId: "thread-stable" }),
      ).toHaveLength(2);
    } finally {
      await rm(root, { recursive: true, force: true });
      await rm(galleryDirectory, { recursive: true, force: true });
    }
  });

  it("drops a stale source-path row so history repair can copy the image again", async () => {
    const root = await mkdtemp(join(tmpdir(), "ccpocket-gallery-project-"));
    const galleryDirectory = await mkdtemp(
      join(tmpdir(), "ccpocket-gallery-store-"),
    );
    try {
      const imagePath = join(root, "repair.png");
      await writeFile(imagePath, Buffer.from("89504e470d0a1a0a", "hex"));

      const initialStore = new GalleryStore({ directory: galleryDirectory });
      await initialStore.init();
      const staleMeta = await initialStore.addImage(
        imagePath,
        root,
        "runtime-old",
      );
      expect(staleMeta).not.toBeNull();
      await unlink(initialStore.getImagePath(staleMeta!.id)!);

      const restartedStore = new GalleryStore({ directory: galleryDirectory });
      await restartedStore.init();
      expect(
        await restartedStore.bindProviderSessionIdBySourcePath(
          imagePath,
          "thread-stable",
        ),
      ).toBeNull();
      expect(restartedStore.list()).toHaveLength(0);

      const repaired = await restartedStore.addImage(
        imagePath,
        root,
        "runtime-new",
        "thread-stable",
      );
      expect(repaired).not.toBeNull();

      const secondRestart = new GalleryStore({ directory: galleryDirectory });
      await secondRestart.init();
      expect(
        secondRestart.list({ providerSessionId: "thread-stable" }),
      ).toHaveLength(1);
    } finally {
      await rm(root, { recursive: true, force: true });
      await rm(galleryDirectory, { recursive: true, force: true });
    }
  });

  it("does not expose a failed source path in warnings", async () => {
    const root = await mkdtemp(join(tmpdir(), "ccpocket-gallery-project-"));
    try {
      const privatePath = join(root, "private generated name.png");
      await writeFile(privatePath, Buffer.from("89504e470d0a1a0a", "hex"));
      const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
      try {
        // Without init(), the destination directory is absent and copyFile
        // reaches the failure logger.
        const store = new GalleryStore({ directory: join(root, "not-ready") });
        await expect(store.addImage(privatePath, root)).resolves.toBeNull();
        expect(JSON.stringify(warn.mock.calls)).not.toContain(privatePath);
        expect(JSON.stringify(warn.mock.calls)).not.toContain(
          "private generated name.png",
        );
      } finally {
        warn.mockRestore();
      }
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("does not trust a symlink in place of an indexed Gallery image", async () => {
    const root = await mkdtemp(join(tmpdir(), "ccpocket-gallery-project-"));
    const galleryDirectory = await mkdtemp(
      join(tmpdir(), "ccpocket-gallery-store-"),
    );
    try {
      const imagePath = join(root, "source.png");
      await writeFile(imagePath, Buffer.from("89504e470d0a1a0a", "hex"));
      const initialStore = new GalleryStore({ directory: galleryDirectory });
      await initialStore.init();
      const meta = await initialStore.addImage(
        imagePath,
        root,
        "runtime-old",
      );
      const storedPath = initialStore.getImagePath(meta!.id)!;
      await unlink(storedPath);
      await symlink(imagePath, storedPath);

      const restartedStore = new GalleryStore({ directory: galleryDirectory });
      await restartedStore.init();
      expect(
        await restartedStore.bindProviderSessionIdBySourcePath(
          imagePath,
          "thread-stable",
        ),
      ).toBeNull();
      expect(restartedStore.list()).toHaveLength(0);
    } finally {
      await rm(root, { recursive: true, force: true });
      await rm(galleryDirectory, { recursive: true, force: true });
    }
  });

  it("drops malformed persisted rows before they can escape the Gallery directory", async () => {
    const galleryDirectory = await mkdtemp(
      join(tmpdir(), "ccpocket-gallery-store-"),
    );
    try {
      await writeFile(
        join(galleryDirectory, "index.json"),
        JSON.stringify([
          {
            id: "poisoned",
            filename: "../../outside.png",
            mimeType: "image/png",
            projectPath: "/tmp/project",
            sourcePath: "/tmp/source.png",
            addedAt: new Date().toISOString(),
            sizeBytes: 16,
          },
        ]),
      );

      const store = new GalleryStore({ directory: galleryDirectory });
      await store.init();

      expect(store.list()).toEqual([]);
      expect(store.getImagePath("poisoned")).toBeNull();
      await expect(store.getImageAsBase64("poisoned")).resolves.toBeNull();
    } finally {
      await rm(galleryDirectory, { recursive: true, force: true });
    }
  });
});

describe("GalleryStore HTTP upload", () => {
  let galleryDirectory: string;
  let store: GalleryStore;

  beforeEach(async () => {
    galleryDirectory = await mkdtemp(
      join(tmpdir(), "ccpocket-gallery-http-"),
    );
    store = new GalleryStore({ directory: galleryDirectory });
    await store.init();
  });

  afterEach(async () => {
    await rm(galleryDirectory, { recursive: true, force: true });
  });

  it("accepts a bounded canonical base64 image", async () => {
    const response = await galleryHttpRequest(
      store,
      JSON.stringify({
        base64: Buffer.from("small image").toString("base64"),
        mimeType: "image/png",
        projectPath: "/tmp/project",
      }),
    );

    expect(response.statusCode).toBe(201);
    expect(JSON.parse(response.body).image).toMatchObject({
      mimeType: "image/png",
      projectPath: "/tmp/project",
    });
  });

  it("rejects malformed base64 instead of decoding it permissively", async () => {
    const response = await galleryHttpRequest(
      store,
      JSON.stringify({
        base64: "not-valid-base64!",
        mimeType: "image/png",
        projectPath: "/tmp/project",
      }),
    );

    expect(response.statusCode).toBe(400);
    expect(store.list()).toEqual([]);
  });

  it("does not expose file-path copy mode without local control", async () => {
    const response = await galleryHttpRequest(
      store,
      JSON.stringify({
        filePath: "/tmp/private-image.png",
        projectPath: "/tmp",
      }),
    );

    expect(response.statusCode).toBe(403);
    expect(store.list()).toEqual([]);
  });

  it("rejects an oversized declared request before buffering it", async () => {
    const response = await galleryHttpRequest(store, "{}", {
      "Content-Length": 20 * 1024 * 1024,
    });

    expect(response.statusCode).toBe(413);
    expect(store.list()).toEqual([]);
  });
});
