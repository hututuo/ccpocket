import { chmod, mkdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { mkdtemp } from "node:fs/promises";
import { afterEach, describe, expect, it } from "vitest";
import {
  ArtifactRegistry,
  artifactRegistryFileForPort,
} from "./artifact-registry.js";
import type { RegisterArtifactInput } from "./artifact-types.js";

const roots: string[] = [];

afterEach(async () => {
  await Promise.all(
    roots.splice(0).map((root) => rm(root, { recursive: true, force: true })),
  );
});

async function tempRoot(): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), "ccpocket-registry-test-"));
  roots.push(root);
  return root;
}

function registration(
  overrides: Partial<RegisterArtifactInput> = {},
): RegisterArtifactInput {
  return {
    candidateKey: "K".repeat(43),
    ownerId: "provider-thread-1",
    messageId: "message-1",
    canonicalPath: "/allowed/report.pdf",
    filename: "report.pdf",
    mimeType: "application/pdf",
    sizeBytes: 10,
    identity: { dev: 1, ino: 2, size: 10, mtimeMs: 3 },
    kind: "preview",
    source: "assistant_markdown",
    ...overrides,
  };
}

function sequentialIds(): () => string {
  let value = 0;
  return () => `${"A".repeat(22)}${value++}`;
}

describe("artifactRegistryFileForPort", () => {
  it("uses the legacy filename on 8765 and isolates non-default ports", () => {
    expect(artifactRegistryFileForPort(8765)).toContain(
      "artifact-registry-v1.json",
    );
    expect(artifactRegistryFileForPort(8766)).toContain(
      "artifact-registry-v1-8766.json",
    );
    expect(artifactRegistryFileForPort(8766, "/tmp/custom.json")).toBe(
      "/tmp/custom.json",
    );
  });
});

describe("ArtifactRegistry", () => {
  it("persists a stable opaque id and deduplicates concurrent replay", async () => {
    const root = await tempRoot();
    const filePath = join(root, "registry.json");
    const registry = new ArtifactRegistry({ filePath });
    const input = registration({ canonicalPath: join(root, "report.pdf") });

    const entries = await Promise.all(
      Array.from({ length: 8 }, () => registry.register(input)),
    );
    expect(new Set(entries.map((entry) => entry.artifactId))).toHaveLength(1);
    expect(entries[0].artifactId).toMatch(/^[A-Za-z0-9_-]{32}$/);

    const reopened = new ArtifactRegistry({ filePath });
    const replayed = await reopened.register(input);
    expect(replayed.artifactId).toBe(entries[0].artifactId);

    const raw = await readFile(filePath, "utf8");
    expect(raw).not.toContain('"token"');
  });

  it("uses an init barrier instead of overwriting an existing descriptor", async () => {
    const root = await tempRoot();
    const filePath = join(root, "nested", "registry.json");
    await mkdir(join(root, "nested"));
    const input = registration({ canonicalPath: join(root, "report.pdf") });
    const persistedId = "P".repeat(24);
    await writeFile(
      filePath,
      JSON.stringify({
        version: 1,
        entries: [
          {
            artifactId: persistedId,
            ...input,
            createdAt: 100,
            lastAccessAt: 100,
            expiresAt: Date.now() + 60_000,
          },
        ],
      }),
    );

    const registry = new ArtifactRegistry({ filePath });
    const [, replayed] = await Promise.all([
      registry.init(),
      registry.register(input),
    ]);
    expect(replayed.artifactId).toBe(persistedId);
  });

  it("keeps different logical candidate keys distinct", async () => {
    const root = await tempRoot();
    const registry = new ArtifactRegistry({
      filePath: join(root, "registry.json"),
      idFactory: sequentialIds(),
    });
    const base = registration();

    const first = await registry.register({ ...base, line: 12 });
    const second = await registry.register({
      ...base,
      candidateKey: "L".repeat(43),
      line: 13,
    });
    const third = await registry.register({
      ...base,
      candidateKey: "M".repeat(43),
      line: 12,
      source: "structured_tool",
    });

    expect(
      new Set([first.artifactId, second.artifactId, third.artifactId]),
    ).toHaveLength(3);
  });

  it("does not silently repoint an existing candidate after identity changes", async () => {
    const root = await tempRoot();
    const registry = new ArtifactRegistry({
      filePath: join(root, "registry.json"),
      idFactory: sequentialIds(),
    });
    const first = await registry.register(registration());
    const replayed = await registry.register(
      registration({
        sizeBytes: 99,
        identity: { dev: 1, ino: 9, size: 99, mtimeMs: 10 },
      }),
    );

    expect(replayed.artifactId).toBe(first.artifactId);
    expect(replayed.identity).toEqual(first.identity);
    expect(replayed.sizeBytes).toBe(first.sizeBytes);
  });

  it("authorizes the full owner/message tuple without revealing mismatches", async () => {
    const root = await tempRoot();
    const registry = new ArtifactRegistry({
      filePath: join(root, "registry.json"),
    });
    const entry = await registry.register(registration());

    expect(
      await registry.getAuthorized(
        entry.artifactId,
        "provider-thread-1",
        "message-1",
      ),
    ).toMatchObject({ artifactId: entry.artifactId });
    expect(
      await registry.getAuthorized(entry.artifactId, "wrong", "message-1"),
    ).toBeUndefined();
    expect(
      await registry.getAuthorized(
        entry.artifactId,
        "provider-thread-1",
        "wrong",
      ),
    ).toBeUndefined();
    expect(
      await registry.getAuthorized(
        "Z".repeat(24),
        "provider-thread-1",
        "message-1",
      ),
    ).toBeUndefined();
  });

  it("enforces expiry, renews active replay, and evicts by last access", async () => {
    const root = await tempRoot();
    let now = 1_000;
    const registry = new ArtifactRegistry({
      filePath: join(root, "registry.json"),
      maxEntries: 2,
      entryTtlMs: 100,
      now: () => now,
      idFactory: sequentialIds(),
    });
    const oneInput = registration({ messageId: "one" });
    const one = await registry.register(oneInput);
    now = 1_060;
    expect((await registry.register(oneInput)).artifactId).toBe(one.artifactId);

    now = 1_070;
    const two = await registry.register(
      registration({
        messageId: "two",
        identity: { dev: 1, ino: 3, size: 10, mtimeMs: 3 },
      }),
    );
    now = 1_080;
    expect(
      await registry.touch(one.artifactId, one.ownerId, one.messageId),
    ).toBe(true);
    now = 1_090;
    await registry.register(
      registration({
        messageId: "three",
        identity: { dev: 1, ino: 4, size: 10, mtimeMs: 3 },
      }),
    );
    expect(
      await registry.getAuthorized(two.artifactId, two.ownerId, two.messageId),
    ).toBeUndefined();
    expect(
      await registry.getAuthorized(one.artifactId, one.ownerId, one.messageId),
    ).toBeDefined();

    now = 1_181;
    expect(
      await registry.getAuthorized(one.artifactId, one.ownerId, one.messageId),
    ).toBeUndefined();
  });

  it("keeps an explicit parent directory mode unchanged and secures the file", async () => {
    const root = await tempRoot();
    const directory = join(root, "shared-project-directory");
    await mkdir(directory, { mode: 0o755 });
    await chmod(directory, 0o755);
    const filePath = join(directory, "registry.json");
    const registry = new ArtifactRegistry({ filePath });
    await registry.register(registration());

    expect((await stat(directory)).mode & 0o777).toBe(0o755);
    expect((await stat(filePath)).mode & 0o777).toBe(0o600);
  });

  it("rolls back memory after an atomic save failure and persists a retry", async () => {
    const root = await tempRoot();
    const filePath = join(root, "registry.json");
    const registry = new ArtifactRegistry({
      filePath,
      idFactory: sequentialIds(),
    });
    await registry.init();
    const internals = registry as unknown as {
      save: () => Promise<void>;
    };
    const realSave = internals.save.bind(registry);
    let failOnce = true;
    internals.save = async () => {
      if (failOnce) {
        failOnce = false;
        throw new Error("injected save failure");
      }
      await realSave();
    };

    await expect(registry.register(registration())).rejects.toThrow(
      "injected save failure",
    );
    const retried = await registry.register(registration());

    const reopened = new ArtifactRegistry({ filePath });
    const persisted = await reopened.register(registration());
    expect(persisted.artifactId).toBe(retried.artifactId);
  });

  it("registers a message batch with one atomic save", async () => {
    const root = await tempRoot();
    const registry = new ArtifactRegistry({
      filePath: join(root, "registry.json"),
      idFactory: sequentialIds(),
    });
    await registry.init();
    const internals = registry as unknown as { save: () => Promise<void> };
    const realSave = internals.save.bind(registry);
    let saves = 0;
    internals.save = async () => {
      saves += 1;
      await realSave();
    };

    const entries = await registry.registerMany(
      [0, 1, 2].map((index) =>
        registration({
          candidateKey: String.fromCharCode(75 + index).repeat(43),
          canonicalPath: `/allowed/report-${index}.pdf`,
          identity: { dev: 1, ino: 10 + index, size: 10, mtimeMs: 3 },
        }),
      ),
    );
    expect(entries).toHaveLength(3);
    expect(saves).toBe(1);
  });

  it("refuses an unknown future version without overwriting it", async () => {
    const root = await tempRoot();
    const filePath = join(root, "registry.json");
    const future = JSON.stringify({ version: 2, entries: [], future: true });
    await writeFile(filePath, future);
    const registry = new ArtifactRegistry({ filePath });

    await expect(registry.init()).rejects.toThrow(
      "Unsupported artifact registry version",
    );
    await expect(registry.register(registration())).rejects.toThrow(
      "Unsupported artifact registry version",
    );
    expect(await readFile(filePath, "utf8")).toBe(future);
  });
});
