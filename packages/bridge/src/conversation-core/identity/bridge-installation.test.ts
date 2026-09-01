import { createHash } from "node:crypto";
import { spawn } from "node:child_process";
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
import { pathToFileURL } from "node:url";
import { afterEach, describe, expect, it } from "vitest";

import {
  BRIDGE_INSTALLATION_FILE,
  BRIDGE_INSTALLATION_SCHEMA_VERSION,
  BridgeInstallationStore,
  CODEX_SOURCE_PROVIDER,
} from "./index.js";
import {
  acquireStateMutationLock,
  type StateMutationLockOptions,
} from "./private-state.js";

function locatorDigest(locator: string): string {
  return createHash("sha256").update(locator).digest("hex");
}

describe("BridgeInstallationStore", () => {
  const roots: string[] = [];
  const stores: BridgeInstallationStore[] = [];

  afterEach(async () => {
    await Promise.all(stores.splice(0).map((store) => store.close()));
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
    options: {
      now?: () => number;
      lockOptions?: StateMutationLockOptions;
    } = {},
  ): Promise<BridgeInstallationStore> {
    const store = await BridgeInstallationStore.load({ stateDir, ...options });
    stores.push(store);
    return store;
  }

  async function close(store: BridgeInstallationStore): Promise<void> {
    await store.close();
    const index = stores.indexOf(store);
    if (index >= 0) stores.splice(index, 1);
  }

  async function waitForFixtureEvent(
    child: ReturnType<typeof spawn>,
    event: string,
  ): Promise<Record<string, unknown>> {
    let output = "";
    let errorOutput = "";
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        cleanup();
        reject(
          new Error(
            `identity fixture timeout waiting for ${event}: stdout=${output} stderr=${errorOutput}`,
          ),
        );
      }, 10_000);
      const onData = (chunk: Buffer): void => {
        output += chunk.toString("utf8");
        for (const line of output.split("\n")) {
          if (!line.trim()) continue;
          try {
            const parsed = JSON.parse(line) as Record<string, unknown>;
            if (parsed.event === event) {
              cleanup();
              resolve(parsed);
              return;
            }
          } catch {
            // Wait for a complete JSON line.
          }
        }
        output = output.slice(output.lastIndexOf("\n") + 1);
      };
      const onError = (chunk: Buffer): void => {
        errorOutput += chunk.toString("utf8");
      };
      const onExit = (
        code: number | null,
        signal: NodeJS.Signals | null,
      ): void => {
        cleanup();
        reject(
          new Error(
            `identity fixture exited before ${event}: code=${code} signal=${signal} stderr=${errorOutput}`,
          ),
        );
      };
      const cleanup = (): void => {
        clearTimeout(timer);
        child.stdout?.off("data", onData);
        child.stderr?.off("data", onError);
        child.off("exit", onExit);
      };
      child.stdout?.on("data", onData);
      child.stderr?.on("data", onError);
      child.on("exit", onExit);
    });
  }

  it("creates private bounded installation state only on explicit load", async () => {
    const parent = await root();
    const stateDir = join(parent, "state");
    expect(existsSync(stateDir)).toBe(false);

    const store = await load(stateDir);
    const installationFile = join(stateDir, BRIDGE_INSTALLATION_FILE);
    const document = JSON.parse(
      await readFile(installationFile, "utf8"),
    ) as Record<string, unknown>;

    expect(store.bridgeInstanceId).toMatch(
      /^bridge_instance_[A-Za-z0-9_-]{32}$/,
    );
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

  it("persists stable source IDs while keeping each authenticated epoch in memory", async () => {
    const stateDir = join(await root(), "state");
    const rawLocatorA = "/Users/private/.codex?account=secret&route=10.0.0.8";
    const rawLocatorB = "/Users/other/.codex?account=second&route=tailnet";
    const digestA = locatorDigest(rawLocatorA);
    const digestB = locatorDigest(rawLocatorB);
    let store = await load(stateDir, { now: () => Date.UTC(2026, 7, 30) });

    const first = await store.bindAuthenticatedCodexSource(digestA);
    const duplicate =
      await store.codexSources.bindAuthenticatedCodexSource(digestA);
    const different = await store.bindAuthenticatedCodexSource(digestB);

    expect(duplicate).toEqual(first);
    expect(different.codexSourceId).not.toBe(first.codexSourceId);
    expect(different.sourceEpoch).not.toBe(first.sourceEpoch);
    expect(first.sourceEpoch).toMatch(/^source_epoch_[A-Za-z0-9_-]+$/);
    expect(
      store.codexSources.isSourceEpochCurrent(digestA, first.sourceEpoch),
    ).toBe(true);

    const replaced = await store.replaceAuthenticatedCodexSource(digestA);
    expect(replaced.codexSourceId).toBe(first.codexSourceId);
    expect(replaced.sourceEpoch).not.toBe(first.sourceEpoch);
    expect(
      store.codexSources.isSourceEpochCurrent(digestA, first.sourceEpoch),
    ).toBe(false);
    expect(
      store.codexSources.isSourceEpochCurrent(digestA, replaced.sourceEpoch),
    ).toBe(true);
    expect(() =>
      store.codexSources.assertSourceEpoch(digestA, first.sourceEpoch),
    ).toThrow(/not current/);
    await close(store);

    store = await load(stateDir);
    const reopenedA = await store.bindAuthenticatedCodexSource(digestA);
    const reopenedB = await store.bindAuthenticatedCodexSource(digestB);
    expect(reopenedA.codexSourceId).toBe(first.codexSourceId);
    expect(reopenedB.codexSourceId).toBe(different.codexSourceId);
    expect(reopenedA.sourceEpoch).not.toBe(first.sourceEpoch);
    expect(reopenedA.sourceEpoch).not.toBe(replaced.sourceEpoch);
    expect(reopenedB.sourceEpoch).not.toBe(different.sourceEpoch);
    expect(
      store.codexSources.isSourceEpochCurrent(digestA, first.sourceEpoch),
    ).toBe(false);
    expect(() =>
      store.codexSources.assertSourceEpoch(digestA, first.sourceEpoch),
    ).toThrow(/not current/);
    const serialized = await readFile(
      join(stateDir, BRIDGE_INSTALLATION_FILE),
      "utf8",
    );
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
      },
      {
        provider: CODEX_SOURCE_PROVIDER,
        locatorDigest: digestB,
        codexSourceId: different.codexSourceId,
      },
    ]);
  });

  it("serializes concurrent same-digest resolution into one durable binding", async () => {
    const stateDir = join(await root(), "state");
    const store = await load(stateDir);
    const digest = locatorDigest("same-logical-codex-source");

    const results = await Promise.all(
      Array.from({ length: 32 }, () =>
        store.bindAuthenticatedCodexSource(digest),
      ),
    );

    expect(new Set(results.map((result) => result.codexSourceId))).toHaveLength(
      1,
    );
    expect(new Set(results.map((result) => result.sourceEpoch))).toHaveLength(
      1,
    );
    expect(store.sourceBindings()).toHaveLength(1);
    expect((await readdir(stateDir)).sort()).toEqual([
      BRIDGE_INSTALLATION_FILE,
    ]);
  });

  it("partitions concurrent different digests into different IDs and epochs", async () => {
    const stateDir = join(await root(), "state");
    const store = await load(stateDir);
    const digests = Array.from({ length: 16 }, (_, index) =>
      locatorDigest(`codex-source-${index}`),
    );

    const results = await Promise.all(
      digests.map((digest) => store.bindAuthenticatedCodexSource(digest)),
    );

    expect(new Set(results.map((result) => result.codexSourceId))).toHaveLength(
      16,
    );
    expect(new Set(results.map((result) => result.sourceEpoch))).toHaveLength(
      16,
    );
    expect(store.sourceBindings()).toHaveLength(16);
  });

  it("rejects a second in-process writer and permits a stable reopen after close", async () => {
    const stateDir = join(await root(), "state");
    const first = await load(stateDir, {
      lockOptions: { attempts: 2, retryMs: 0 },
    });
    const bridgeInstanceId = first.bridgeInstanceId;
    await expect(
      BridgeInstallationStore.load({
        stateDir,
        lockOptions: { attempts: 2, retryMs: 0 },
      }),
    ).rejects.toThrow(/writer lease is busy/);

    await close(first);
    const reopened = await load(stateDir, {
      lockOptions: { attempts: 2, retryMs: 0 },
    });
    expect(reopened.bridgeInstanceId).toBe(bridgeInstanceId);
  });

  it("aborts queued work before allowing a clean reopen after close", async () => {
    const stateDir = join(await root(), "state");
    const store = await load(stateDir);
    const pending = store.bindAuthenticatedCodexSource(
      locatorDigest("close-race"),
    );
    const pendingRejection = expect(pending).rejects.toThrow(/store is closed/);

    await close(store);
    await pendingRejection;

    const reopened = await load(stateDir);
    expect(reopened.sourceBindings()).toEqual([]);
  });

  it("shares close completion, drains a started mutation, and rejects queued work", async () => {
    const stateDir = join(await root(), "state");
    const store = await load(stateDir);
    const blockerRelease = await acquireStateMutationLock(
      store.installationFile,
      "close fixture blocker",
    );
    const startedDigest = locatorDigest("started-before-close");
    const queuedDigest = locatorDigest("queued-before-close");
    const started = store.bindAuthenticatedCodexSource(startedDigest);
    const queued = store.bindAuthenticatedCodexSource(queuedDigest);
    const queuedRejection = expect(queued).rejects.toThrow(/store is closed/);
    await new Promise((resolveImmediate) => setImmediate(resolveImmediate));

    const closing = store.close();
    expect(store.close()).toBe(closing);
    expect(
      await Promise.race([
        closing.then(() => "closed"),
        new Promise<string>((resolvePending) =>
          setTimeout(() => resolvePending("pending"), 10),
        ),
      ]),
    ).toBe("pending");
    await expect(
      BridgeInstallationStore.load({
        stateDir,
        lockOptions: { attempts: 2, retryMs: 0 },
      }),
    ).rejects.toThrow(/writer lease is busy/);

    await blockerRelease();
    const resolved = await started;
    await queuedRejection;
    await closing;

    const reopened = await load(stateDir);
    const reopenedResolved =
      await reopened.bindAuthenticatedCodexSource(startedDigest);
    expect(reopenedResolved.codexSourceId).toBe(resolved.codexSourceId);
    expect(reopenedResolved.sourceEpoch).not.toBe(resolved.sourceEpoch);
    expect(
      reopened.sourceBindings().map((binding) => binding.locatorDigest),
    ).toEqual([startedDigest]);
  });

  it("allows only one concurrent first writer without creating two identities or leaking files", async () => {
    const stateDir = join(await root(), "state");
    const attempts = await Promise.allSettled([
      BridgeInstallationStore.load({
        stateDir,
        lockOptions: { attempts: 2, retryMs: 0 },
      }),
      BridgeInstallationStore.load({
        stateDir,
        lockOptions: { attempts: 2, retryMs: 0 },
      }),
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
    expect(document.bridgeInstanceId).toBe(
      fulfilled[0]!.value.bridgeInstanceId,
    );
    expect((await readdir(stateDir)).sort()).toEqual([
      BRIDGE_INSTALLATION_FILE,
    ]);
  });

  it("enforces the writer lease across processes and rereads after handoff", async () => {
    const stateDir = join(await root(), "state");
    const digest = locatorDigest("cross-process-lifecycle");
    const modulePath = existsSync(
      join(
        process.cwd(),
        "packages/bridge/src/conversation-core/identity/bridge-installation.ts",
      ),
    )
      ? join(
          process.cwd(),
          "packages/bridge/src/conversation-core/identity/bridge-installation.ts",
        )
      : join(
          process.cwd(),
          "src/conversation-core/identity/bridge-installation.ts",
        );
    const moduleUrl = pathToFileURL(modulePath).href;
    const fixture = `
      import { BridgeInstallationStore } from ${JSON.stringify(moduleUrl)};
      const store = await BridgeInstallationStore.load({
        stateDir: process.env.CCPOCKET_IDENTITY_FIXTURE_STATE_DIR,
        lockOptions: { attempts: 20, retryMs: 5 },
      });
      const resolved = await store.bindAuthenticatedCodexSource(
        process.env.CCPOCKET_IDENTITY_FIXTURE_DIGEST,
      );
      process.stdout.write(JSON.stringify({ event: "ready", resolved }) + "\\n");
      process.stdin.once("data", async () => {
        await store.close();
        process.stdout.write(
          JSON.stringify({ event: "closed" }) + "\\n",
          () => process.exit(0),
        );
      });
    `;
    const child = spawn(
      process.execPath,
      ["--import", "tsx", "--input-type=module", "-e", fixture],
      {
        cwd: process.cwd(),
        env: {
          ...process.env,
          CCPOCKET_IDENTITY_FIXTURE_STATE_DIR: stateDir,
          CCPOCKET_IDENTITY_FIXTURE_DIGEST: digest,
        },
        stdio: ["pipe", "pipe", "pipe"],
      },
    );
    try {
      const ready = await waitForFixtureEvent(child, "ready");
      const firstResolved = ready.resolved as {
        codexSourceId: string;
        sourceEpoch: string;
      };
      await expect(
        BridgeInstallationStore.load({
          stateDir,
          lockOptions: { attempts: 2, retryMs: 0 },
        }),
      ).rejects.toThrow(/writer lease is busy/);

      const closedEvent = waitForFixtureEvent(child, "closed");
      child.stdin?.write("close\n");
      await closedEvent;
      await new Promise<void>((resolve, reject) => {
        child.once("exit", (code) => {
          if (code === 0) resolve();
          else reject(new Error(`identity fixture close exit code ${code}`));
        });
      });

      const reopened = await load(stateDir, {
        lockOptions: { attempts: 2, retryMs: 0 },
      });
      const secondResolved =
        await reopened.bindAuthenticatedCodexSource(digest);
      expect(secondResolved.codexSourceId).toBe(firstResolved.codexSourceId);
      expect(secondResolved.sourceEpoch).not.toBe(firstResolved.sourceEpoch);
      expect(
        reopened.codexSources.isSourceEpochCurrent(
          digest,
          firstResolved.sourceEpoch,
        ),
      ).toBe(false);
    } finally {
      if (!child.killed && child.exitCode === null) child.kill("SIGKILL");
    }
  }, 30_000);

  it("reclaims a crashed writer lease only after the owner PID is dead", async () => {
    const stateDir = join(await root(), "crashed-state");
    const digest = locatorDigest("crashed-writer");
    const modulePath = existsSync(
      join(
        process.cwd(),
        "packages/bridge/src/conversation-core/identity/bridge-installation.ts",
      ),
    )
      ? join(
          process.cwd(),
          "packages/bridge/src/conversation-core/identity/bridge-installation.ts",
        )
      : join(
          process.cwd(),
          "src/conversation-core/identity/bridge-installation.ts",
        );
    const fixture = `
      import { BridgeInstallationStore } from ${JSON.stringify(pathToFileURL(modulePath).href)};
      const store = await BridgeInstallationStore.load({
        stateDir: process.env.CCPOCKET_IDENTITY_FIXTURE_STATE_DIR,
        lockOptions: { attempts: 20, retryMs: 5 },
      });
      await store.bindAuthenticatedCodexSource(process.env.CCPOCKET_IDENTITY_FIXTURE_DIGEST);
      process.stdout.write(JSON.stringify({ event: "ready" }) + "\\n");
      process.stdin.resume();
    `;
    const child = spawn(
      process.execPath,
      ["--import", "tsx", "--input-type=module", "-e", fixture],
      {
        cwd: process.cwd(),
        env: {
          ...process.env,
          CCPOCKET_IDENTITY_FIXTURE_STATE_DIR: stateDir,
          CCPOCKET_IDENTITY_FIXTURE_DIGEST: digest,
        },
        stdio: ["pipe", "pipe", "pipe"],
      },
    );
    try {
      await waitForFixtureEvent(child, "ready");
      child.kill("SIGKILL");
      await new Promise<void>((resolve, reject) => {
        child.once("exit", (code, signal) => {
          if (signal === "SIGKILL") resolve();
          else
            reject(
              new Error(`identity fixture crash signal=${signal} code=${code}`),
            );
        });
      });

      const recovered = await load(stateDir, {
        lockOptions: { staleGraceMs: 0, attempts: 20, retryMs: 0 },
      });
      const resolved = await recovered.bindAuthenticatedCodexSource(digest);
      expect(resolved.codexSourceId).toMatch(
        /^codex_source_[A-Za-z0-9_-]{32}$/,
      );
      expect(
        recovered.codexSources.isSourceEpochCurrent(
          digest,
          resolved.sourceEpoch,
        ),
      ).toBe(true);
    } finally {
      if (!child.killed && child.exitCode === null) child.kill("SIGKILL");
    }
  }, 30_000);

  it("repairs private modes without changing valid installation state", async () => {
    const stateDir = join(await root(), "state");
    const first = await load(stateDir);
    const bridgeInstanceId = first.bridgeInstanceId;
    const installationFile = join(stateDir, BRIDGE_INSTALLATION_FILE);
    await close(first);
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
    await expect(
      BridgeInstallationStore.load({ stateDir: malformedState }),
    ).rejects.toThrow(/malformed/);

    const realState = join(await root(), "real-state");
    const linkedState = join(await root(), "linked-state");
    await mkdir(realState, { mode: 0o700 });
    await symlink(realState, linkedState);
    await expect(
      BridgeInstallationStore.load({ stateDir: linkedState }),
    ).rejects.toThrow(/real directory/);

    const symlinkState = join(await root(), "symlink");
    await mkdir(symlinkState, { mode: 0o700 });
    const target = join(await root(), "installation-target");
    await writeFile(target, "{}", { mode: 0o600 });
    await symlink(target, join(symlinkState, BRIDGE_INSTALLATION_FILE));
    await expect(
      BridgeInstallationStore.load({ stateDir: symlinkState }),
    ).rejects.toThrow(/private regular file/);

    const directoryState = join(await root(), "directory");
    await mkdir(join(directoryState, BRIDGE_INSTALLATION_FILE), {
      recursive: true,
      mode: 0o700,
    });
    await expect(
      BridgeInstallationStore.load({ stateDir: directoryState }),
    ).rejects.toThrow(/private regular file/);

    const oversizedState = join(await root(), "oversized");
    await mkdir(oversizedState, { mode: 0o700 });
    await writeFile(
      join(oversizedState, BRIDGE_INSTALLATION_FILE),
      Buffer.alloc(1024 * 1024 + 1),
      { mode: 0o600 },
    );
    await expect(
      BridgeInstallationStore.load({ stateDir: oversizedState }),
    ).rejects.toThrow(/size limit/);

    const persistedEpochState = join(await root(), "persisted-epoch");
    await mkdir(persistedEpochState, { mode: 0o700 });
    await writeFile(
      join(persistedEpochState, BRIDGE_INSTALLATION_FILE),
      JSON.stringify({
        schemaVersion: BRIDGE_INSTALLATION_SCHEMA_VERSION,
        bridgeInstanceId: "bridge_instance_12345678901234567890123456789012",
        sourceBindings: [
          {
            provider: CODEX_SOURCE_PROVIDER,
            locatorDigest: locatorDigest("persisted-epoch"),
            codexSourceId: "codex_source_12345678901234567890123456789012",
            sourceEpoch: "source_epoch_stale_should_not_be_read",
          },
        ],
      }),
      { mode: 0o600 },
    );
    await expect(
      BridgeInstallationStore.load({ stateDir: persistedEpochState }),
    ).rejects.toThrow(/source binding is invalid/);
  });

  it("rejects raw or non-canonical locators without mutating the registry", async () => {
    const stateDir = join(await root(), "state");
    const store = await load(stateDir);
    const before = await readFile(
      join(stateDir, BRIDGE_INSTALLATION_FILE),
      "utf8",
    );

    await expect(
      store.bindAuthenticatedCodexSource("/Users/private/.codex"),
    ).rejects.toThrow(/64 lowercase hex/);
    await expect(
      store.bindAuthenticatedCodexSource("A".repeat(64)),
    ).rejects.toThrow(
      /64 lowercase hex/,
    );
    expect(
      await readFile(join(stateDir, BRIDGE_INSTALLATION_FILE), "utf8"),
    ).toBe(before);
  });
});
