import {
  chmod,
  lstat,
  mkdir,
  mkdtemp,
  readFile,
  readdir,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  defaultCodexGeneratedImageRoots,
  GeneratedArtifactStore,
} from "./generated-artifact-store.js";

const roots: string[] = [];

afterEach(async () => {
  await Promise.all(
    roots.splice(0).map((root) => rm(root, { recursive: true, force: true })),
  );
});

async function tempRoot(): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), "ccpocket-generated-test-"));
  roots.push(root);
  return root;
}

function input(sourcePath: string, suffix = "one") {
  return {
    sourcePath,
    cwd: "/unused",
    ownerId: "provider-thread",
    messageId: `message-${suffix}`,
    candidateKey: `${suffix}-candidate-key`,
  };
}

describe("GeneratedArtifactStore", () => {
  it("includes both fixed /tmp and platform temp Codex roots", () => {
    const roots = defaultCodexGeneratedImageRoots();
    expect(roots).toContain("/tmp/codex/generated_images");
    expect(roots).toContain(join(tmpdir(), "codex", "generated_images"));
  });

  it("atomically persists trusted Unicode paths with private permissions", async () => {
    const root = await tempRoot();
    const trusted = join(root, "trusted");
    const controlled = join(root, "controlled");
    await mkdir(trusted);
    const source = join(trusted, "生成 图.png");
    await writeFile(source, "first image");
    const store = new GeneratedArtifactStore({
      directory: controlled,
      trustedSourceRoots: [trusted],
    });

    const first = await store.persist(input(source));
    expect(first).toBeDefined();
    expect(first).not.toBe(source);
    expect(first?.endsWith("/生成 图.png")).toBe(true);
    expect(await readFile(first!, "utf8")).toBe("first image");
    expect((await lstat(first!)).mode & 0o777).toBe(0o600);
    expect((await lstat(controlled)).mode & 0o777).toBe(0o700);
    expect((await lstat(dirname(first!))).mode & 0o777).toBe(0o700);

    await rm(source);
    await expect(store.persist(input(source))).resolves.toBe(first);
    await expect(store.touch(first!)).resolves.toBe(true);
  });

  it("rejects untrusted paths, escaping symlinks, and oversized files", async () => {
    const root = await tempRoot();
    const trusted = join(root, "trusted");
    const outside = join(root, "outside");
    const controlled = join(root, "controlled");
    await mkdir(trusted);
    await mkdir(outside);
    const secret = join(outside, "secret.png");
    await writeFile(secret, "secret");
    await symlink(secret, join(trusted, "escape.png"));
    const large = join(trusted, "large.png");
    await writeFile(large, "too large");
    const store = new GeneratedArtifactStore({
      directory: controlled,
      trustedSourceRoots: [trusted],
      maxFileSizeBytes: 4,
    });

    await expect(
      store.persist(input(secret, "outside")),
    ).resolves.toBeUndefined();
    await expect(
      store.persist(input(join(trusted, "escape.png"), "escape")),
    ).resolves.toBeUndefined();
    await expect(store.persist(input(large, "large"))).resolves.toBeUndefined();
    await expect(readdir(controlled)).resolves.toEqual([]);
  });

  it("rejects a symlinked managed root without chmodding its target", async () => {
    const root = await tempRoot();
    const trusted = join(root, "trusted");
    const target = join(root, "unrelated-target");
    const controlledLink = join(root, "controlled-link");
    await mkdir(trusted);
    await mkdir(target);
    await chmod(target, 0o755);
    await symlink(target, controlledLink);
    const source = join(trusted, "image.png");
    await writeFile(source, "image");
    const store = new GeneratedArtifactStore({
      directory: controlledLink,
      trustedSourceRoots: [trusted],
    });

    await expect(store.persist(input(source))).resolves.toBeUndefined();
    expect((await lstat(target)).mode & 0o777).toBe(0o755);
    await expect(readdir(target)).resolves.toEqual([]);
  });

  it("ignores malicious markers and never traverses outside their bucket", async () => {
    const root = await tempRoot();
    const trusted = join(root, "trusted");
    const controlled = join(root, "controlled");
    await mkdir(trusted);
    await mkdir(controlled);
    const maliciousBucket = join(controlled, "B".repeat(43));
    await mkdir(maliciousBucket);
    const marker = join(
      maliciousBucket,
      ".ccpocket-generated-artifact-v1",
    );
    await writeFile(marker, JSON.stringify({ version: 1, filename: ".." }));
    const parentSentinel = join(controlled, "parent-sentinel.txt");
    await writeFile(parentSentinel, "never delete");
    const source = join(trusted, "valid.png");
    await writeFile(source, "valid");
    const store = new GeneratedArtifactStore({
      directory: controlled,
      trustedSourceRoots: [trusted],
      maxEntries: 1,
      entryTtlMs: 1,
      now: () => 10_000,
    });

    await expect(store.persist(input(source, "valid"))).resolves.toBeDefined();
    await expect(readFile(parentSentinel, "utf8")).resolves.toBe(
      "never delete",
    );
    await expect(readFile(marker, "utf8")).resolves.toContain('".."');
  });

  it("bounds managed buckets while leaving every unmarked file untouched", async () => {
    const root = await tempRoot();
    const trusted = join(root, "trusted");
    const controlled = join(root, "controlled");
    await mkdir(trusted);
    await mkdir(controlled);
    const unmarkedBucket = join(controlled, "A".repeat(43));
    await mkdir(unmarkedBucket);
    const unrelated = join(unmarkedBucket, "user-file.txt");
    await writeFile(unrelated, "keep me");
    const sources = ["one.png", "two.png", "three.png"].map((name) =>
      join(trusted, name),
    );
    await Promise.all(sources.map((source) => writeFile(source, source)));
    let now = 1_000;
    const store = new GeneratedArtifactStore({
      directory: controlled,
      trustedSourceRoots: [trusted],
      maxEntries: 2,
      now: () => now,
    });

    const first = await store.persist(input(sources[0], "first"));
    now += 1;
    const second = await store.persist(input(sources[1], "second"));
    expect(first).toBeDefined();
    expect(second).toBeDefined();
    const foreignInsideManagedBucket = join(first!, "..", "foreign.txt");
    await writeFile(foreignInsideManagedBucket, "also keep me");

    now += 1;
    const third = await store.persist(input(sources[2], "third"));
    expect(third).toBeDefined();
    await expect(readFile(unrelated, "utf8")).resolves.toBe("keep me");
    await expect(readFile(foreignInsideManagedBucket, "utf8")).resolves.toBe(
      "also keep me",
    );
    await expect(lstat(first!)).rejects.toMatchObject({ code: "ENOENT" });
    await expect(readFile(second!, "utf8")).resolves.toContain("two.png");
    await expect(readFile(third!, "utf8")).resolves.toContain("three.png");
  });

  it("opportunistically removes only expired managed files", async () => {
    const root = await tempRoot();
    const trusted = join(root, "trusted");
    const controlled = join(root, "controlled");
    await mkdir(trusted);
    const oldSource = join(trusted, "old.png");
    const freshSource = join(trusted, "fresh.png");
    await writeFile(oldSource, "old");
    await writeFile(freshSource, "fresh");
    let now = 10_000;
    const store = new GeneratedArtifactStore({
      directory: controlled,
      trustedSourceRoots: [trusted],
      entryTtlMs: 1_000,
      now: () => now,
    });

    const oldPath = await store.persist(input(oldSource, "old"));
    now += 1_001;
    const freshPath = await store.persist(input(freshSource, "fresh"));
    expect(freshPath).toBeDefined();
    await expect(lstat(oldPath!)).rejects.toMatchObject({ code: "ENOENT" });
    await expect(readFile(freshPath!, "utf8")).resolves.toBe("fresh");
  });
});
