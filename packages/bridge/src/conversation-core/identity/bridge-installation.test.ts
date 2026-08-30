import { createHash } from "node:crypto";
import { existsSync } from "node:fs";
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
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";

import {
  BRIDGE_INSTALLATION_FILE,
  BRIDGE_INSTALLATION_SCHEMA_VERSION,
  BridgeInstallationStore,
  CODEX_SOURCE_PROVIDER,
} from "./index.js";

function locatorDigest(locator: string): string {
  return createHash("sha256").update(locator).digest("hex");
}

describe("BridgeInstallationStore", () => {
  const roots: string[] = [];
  const stores: BridgeInstallationStore[] = [];

  afterEach(async () => {
    for (const store of stores.splice(0)) store.close();
    await Promise.all(
      roots.splice(0).map((root) => rm(root, { recursive: true, force: true })),
    );
  });

  async function root(): Promise<string> {
    const value = await mkdtemp(join(tmpdir(), "ccpocket-v4-installation-"));
    roots.push(value);
    return value;
  }

  async function load(
    stateDir: string,
    options: { now?: () => number } = {},
  ): Promise<BridgeInstallationStore> {
    const store = await BridgeInstallationStore.load({ stateDir, ...options });
    stores.push(store);
    return store;
  }

  function close(store: BridgeInstallationStore): void {
    store.close();
    const index = stores.indexOf(store);
    if (index >= 0) stores.splice(index, 1);
  }

  it("creates private bounded installation state only on explicit load", async () => {
    const parent = await root();
    const stateDir = join(parent, "state");
    expect(existsSync(stateDir)).toBe(false);

    const store = await load(stateDir);
    const installationFile = join(stateDir, BRIDGE_INSTALLATION_FILE);
    const document = JSON.parse(await readFile(installationFile, "utf8")) as Record<
      string,
      unknown
    >;

    expect(store.bridgeInstanceId).toMatch(/^bridge_instance_[A-Za-z0-9_-]{32}$/);
    expect(document).toEqual({
      schemaVersion: BRIDGE_INSTALLATION_SCHEMA_VERSION,
      bridgeInstanceId: store.bridgeInstanceId,
      sourceBindings: [],
    });
    expect((await lstat(stateDir)).mode & 0o777).toBe(0o700);
    expect((await lstat(installationFile)).mode & 0o777).toBe(0o600);
    expect(JSON.stringify(document)).not.toMatch(
      /providerInstanceEpoch|connectionEpoch|runtimeAuthorityGeneration/,
    );
  });

  it("resolves stable source IDs and source epochs by digest without persisting raw locators", async () => {
    const stateDir = join(await root(), "state");
    const rawLocatorA = "/Users/private/.codex?account=secret&route=10.0.0.8";
    const rawLocatorB = "/Users/other/.codex?account=second&route=tailnet";
    const digestA = locatorDigest(rawLocatorA);
    const digestB = locatorDigest(rawLocatorB);
    let store = await load(stateDir, { now: () => Date.UTC(2026, 7, 30) });

    const first = await store.resolveCodexSource(digestA);
    const duplicate = await store.codexSources.resolveCodexSource(digestA);
    const different = await store.resolveCodexSource(digestB);

    expect(duplicate).toEqual(first);
    expect(different.codexSourceId).not.toBe(first.codexSourceId);
    expect(different.sourceEpoch).not.toBe(first.sourceEpoch);
    expect(first.sourceEpoch).toMatch(/^source_epoch_[A-Za-z0-9_-]{32}$/);
    close(store);

    store = await load(stateDir);
    expect(await store.resolveCodexSource(digestA)).toEqual(first);
    expect(await store.resolveCodexSource(digestB)).toEqual(different);
    const serialized = await readFile(join(stateDir, BRIDGE_INSTALLATION_FILE), "utf8");
    expect(serialized).not.toContain(rawLocatorA);
    expect(serialized).not.toContain(rawLocatorB);
    const document = JSON.parse(serialized) as {
      sourceBindings: Array<Record<string, unknown>>;
    };
    expect(document.sourceBindings).toEqual([
      {
        provider: CODEX_SOURCE_PROVIDER,
        locatorDigest: digestA,
        codexSourceId: first.codexSourceId,
        sourceEpoch: first.sourceEpoch,
        createdAt: "2026-08-30T00:00:00.000Z",
      },
      {
        provider: CODEX_SOURCE_PROVIDER,
        locatorDigest: digestB,
        codexSourceId: different.codexSourceId,
        sourceEpoch: different.sourceEpoch,
        createdAt: "2026-08-30T00:00:00.000Z",
      },
    ]);
  });

  it("serializes concurrent same-digest resolution into one durable binding", async () => {
    const stateDir = join(await root(), "state");
    const store = await load(stateDir);
    const digest = locatorDigest("same-logical-codex-source");

    const results = await Promise.all(
      Array.from({ length: 32 }, () => store.resolveCodexSource(digest)),
    );

    expect(new Set(results.map((result) => result.codexSourceId))).toHaveLength(1);
    expect(new Set(results.map((result) => result.sourceEpoch))).toHaveLength(1);
    expect(store.sourceBindings()).toHaveLength(1);
    expect((await readdir(stateDir)).sort()).toEqual([BRIDGE_INSTALLATION_FILE]);
  });

  it("partitions concurrent different digests into different IDs and epochs", async () => {
    const stateDir = join(await root(), "state");
    const store = await load(stateDir);
    const digests = Array.from({ length: 16 }, (_, index) =>
      locatorDigest(`codex-source-${index}`),
    );

    const results = await Promise.all(
      digests.map((digest) => store.resolveCodexSource(digest)),
    );

    expect(new Set(results.map((result) => result.codexSourceId))).toHaveLength(16);
    expect(new Set(results.map((result) => result.sourceEpoch))).toHaveLength(16);
    expect(store.sourceBindings()).toHaveLength(16);
  });

  it("rejects a second in-process writer and permits a stable reopen after close", async () => {
    const stateDir = join(await root(), "state");
    const first = await load(stateDir);
    const bridgeInstanceId = first.bridgeInstanceId;
    await expect(BridgeInstallationStore.load({ stateDir })).rejects.toThrow(
      /writer is already open/,
    );

    close(first);
    const reopened = await load(stateDir);
    expect(reopened.bridgeInstanceId).toBe(bridgeInstanceId);
  });

  it("aborts queued work before allowing a clean reopen after close", async () => {
    const stateDir = join(await root(), "state");
    const store = await load(stateDir);
    const pending = store.resolveCodexSource(locatorDigest("close-race"));
    const pendingRejection = expect(pending).rejects.toThrow(/store is closed/);

    close(store);
    await pendingRejection;

    const reopened = await load(stateDir);
    expect(reopened.sourceBindings()).toEqual([]);
  });

  it("allows only one concurrent first writer without creating two identities or leaking files", async () => {
    const stateDir = join(await root(), "state");
    const attempts = await Promise.allSettled([
      BridgeInstallationStore.load({ stateDir }),
      BridgeInstallationStore.load({ stateDir }),
    ]);
    const fulfilled = attempts.filter(
      (result): result is PromiseFulfilledResult<BridgeInstallationStore> =>
        result.status === "fulfilled",
    );
    const rejected = attempts.filter((result) => result.status === "rejected");
    expect(fulfilled).toHaveLength(1);
    expect(rejected).toHaveLength(1);
    stores.push(fulfilled[0]!.value);

    const document = JSON.parse(
      await readFile(join(stateDir, BRIDGE_INSTALLATION_FILE), "utf8"),
    ) as { bridgeInstanceId: string };
    expect(document.bridgeInstanceId).toBe(fulfilled[0]!.value.bridgeInstanceId);
    expect((await readdir(stateDir)).sort()).toEqual([BRIDGE_INSTALLATION_FILE]);
  });

  it("repairs private modes without changing valid installation state", async () => {
    const stateDir = join(await root(), "state");
    const first = await load(stateDir);
    const bridgeInstanceId = first.bridgeInstanceId;
    const installationFile = join(stateDir, BRIDGE_INSTALLATION_FILE);
    close(first);
    await chmod(stateDir, 0o755);
    await chmod(installationFile, 0o644);

    const reopened = await load(stateDir);
    expect(reopened.bridgeInstanceId).toBe(bridgeInstanceId);
    expect((await lstat(stateDir)).mode & 0o777).toBe(0o700);
    expect((await lstat(installationFile)).mode & 0o777).toBe(0o600);
  });

  it("fails closed for corrupt, symlinked, non-file, and oversized state", async () => {
    const malformedState = join(await root(), "malformed");
    await mkdir(malformedState, { mode: 0o700 });
    await writeFile(join(malformedState, BRIDGE_INSTALLATION_FILE), "{broken", {
      mode: 0o600,
    });
    await expect(BridgeInstallationStore.load({ stateDir: malformedState })).rejects.toThrow(
      /malformed/,
    );

    const realState = join(await root(), "real-state");
    const linkedState = join(await root(), "linked-state");
    await mkdir(realState, { mode: 0o700 });
    await symlink(realState, linkedState);
    await expect(BridgeInstallationStore.load({ stateDir: linkedState })).rejects.toThrow(
      /real directory/,
    );

    const symlinkState = join(await root(), "symlink");
    await mkdir(symlinkState, { mode: 0o700 });
    const target = join(await root(), "installation-target");
    await writeFile(target, "{}", { mode: 0o600 });
    await symlink(target, join(symlinkState, BRIDGE_INSTALLATION_FILE));
    await expect(BridgeInstallationStore.load({ stateDir: symlinkState })).rejects.toThrow(
      /private regular file/,
    );

    const directoryState = join(await root(), "directory");
    await mkdir(join(directoryState, BRIDGE_INSTALLATION_FILE), {
      recursive: true,
      mode: 0o700,
    });
    await expect(BridgeInstallationStore.load({ stateDir: directoryState })).rejects.toThrow(
      /private regular file/,
    );

    const oversizedState = join(await root(), "oversized");
    await mkdir(oversizedState, { mode: 0o700 });
    await writeFile(
      join(oversizedState, BRIDGE_INSTALLATION_FILE),
      Buffer.alloc(1024 * 1024 + 1),
      { mode: 0o600 },
    );
    await expect(BridgeInstallationStore.load({ stateDir: oversizedState })).rejects.toThrow(
      /size limit/,
    );
  });

  it("rejects raw or non-canonical locators without mutating the registry", async () => {
    const stateDir = join(await root(), "state");
    const store = await load(stateDir);
    const before = await readFile(join(stateDir, BRIDGE_INSTALLATION_FILE), "utf8");

    await expect(store.resolveCodexSource("/Users/private/.codex")).rejects.toThrow(
      /64 lowercase hex/,
    );
    await expect(store.resolveCodexSource("A".repeat(64))).rejects.toThrow(
      /64 lowercase hex/,
    );
    expect(await readFile(join(stateDir, BRIDGE_INSTALLATION_FILE), "utf8")).toBe(before);
  });
});
