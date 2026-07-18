import { mkdtemp, rename, rm, symlink, truncate, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";

const lstatControl = vi.hoisted(() => ({
  calls: new Map<string, number>(),
  beforeLstat: undefined as
    | ((path: string, call: number) => Promise<void>)
    | undefined,
}));

vi.mock("node:fs/promises", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:fs/promises")>();
  return {
    ...actual,
    lstat: async (path: Parameters<typeof actual.lstat>[0], options?: unknown) => {
      const key = String(path);
      const call = (lstatControl.calls.get(key) ?? 0) + 1;
      lstatControl.calls.set(key, call);
      await lstatControl.beforeLstat?.(key, call);
      return actual.lstat(path, options as never);
    },
  };
});

import { readBoundedNoFollowMetadata } from "./file-transfer-safe-metadata.js";

const roots: string[] = [];

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "ccpocket-safe-metadata-"));
  roots.push(root);
  return { root, path: join(root, "metadata.json") };
}

afterEach(async () => {
  lstatControl.calls.clear();
  lstatControl.beforeLstat = undefined;
  await Promise.all(
    roots.splice(0).map((root) => rm(root, { recursive: true, force: true })),
  );
});

describe("readBoundedNoFollowMetadata", () => {
  it("rejects a symbolic link without reading its target", async () => {
    const f = await fixture();
    const target = join(f.root, "target.json");
    await writeFile(target, "trusted-target");
    await symlink(target, f.path);

    await expect(
      readBoundedNoFollowMetadata(f.path, 1_024, "Test metadata"),
    ).rejects.toThrow("must not be a symbolic link");
  });

  it("rejects an oversized file before allocating its contents", async () => {
    const f = await fixture();
    await writeFile(f.path, "");
    await truncate(f.path, 1_025);

    await expect(
      readBoundedNoFollowMetadata(f.path, 1_024, "Test metadata"),
    ).rejects.toThrow("exceeds 1024 bytes");
  });

  it("rejects a lexical path replaced after its descriptor opens", async () => {
    const f = await fixture();
    const replacement = join(f.root, "replacement.json");
    const original = join(f.root, "original.json");
    await writeFile(f.path, "first");
    await writeFile(replacement, "other");
    lstatControl.beforeLstat = async (path, call) => {
      if (path !== f.path || call !== 1) return;
      await rename(f.path, original);
      await rename(replacement, f.path);
    };

    await expect(
      readBoundedNoFollowMetadata(f.path, 1_024, "Test metadata"),
    ).rejects.toThrow("must be a pinned regular file");
  });

  it("rejects a lexical path replaced after the bounded fd read", async () => {
    const f = await fixture();
    const replacement = join(f.root, "replacement.json");
    const original = join(f.root, "original.json");
    await writeFile(f.path, "alpha");
    await writeFile(replacement, "bravo");
    lstatControl.beforeLstat = async (path, call) => {
      if (path !== f.path || call !== 2) return;
      await rename(f.path, original);
      await rename(replacement, f.path);
    };

    await expect(
      readBoundedNoFollowMetadata(f.path, 1_024, "Test metadata"),
    ).rejects.toThrow("changed while loading");
  });
});
