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
  rename,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";
import { afterEach, describe, expect, it } from "vitest";

import {
  BRIDGE_INSTALLATION_FILE,
  BRIDGE_INSTALLATION_SCHEMA_VERSION,
  BridgeIdentityStore,
  BridgeInstallationStore,
  CODEX_SOURCE_PROVIDER,
} from "./index.js";
import {
  acquireStateMutationLock,
  preparePrivateStateDirectory,
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

  it("binds identity and installation authority to one shared directory generation", async () => {
    const stateDir = join(await root(), "state");
    const identity = await BridgeIdentityStore.load({
      stateDir,
      lockOptions: { attempts: 2, retryMs: 0 },
    });
    try {
      const installation = await load(stateDir, {
        lockOptions: { attempts: 2, retryMs: 0 },
      });
      expect(installation.writerLeaseFile).toBe(identity.writerLeaseFile);
      expect((await lstat(identity.writerLeaseFile)).isDirectory()).toBe(true);
      await close(installation);
    } finally {
      await identity.close();
    }
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
      await store.codexSources.isSourceEpochCurrent(digestA, first.sourceEpoch),
    ).toBe(true);

    const replaced = await store.replaceAuthenticatedCodexSource(digestA);
    expect(replaced.codexSourceId).toBe(first.codexSourceId);
    expect(replaced.sourceEpoch).not.toBe(first.sourceEpoch);
    expect(
      await store.codexSources.isSourceEpochCurrent(digestA, first.sourceEpoch),
    ).toBe(false);
    expect(
      await store.codexSources.isSourceEpochCurrent(
        digestA,
        replaced.sourceEpoch,
      ),
    ).toBe(true);
    await expect(
      store.codexSources.assertSourceEpoch(digestA, first.sourceEpoch),
    ).rejects.toThrow(/not current/);
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
      await store.codexSources.isSourceEpochCurrent(digestA, first.sourceEpoch),
    ).toBe(false);
    await expect(
      store.codexSources.assertSourceEpoch(digestA, first.sourceEpoch),
    ).rejects.toThrow(/not current/);
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

  it("does not publish a replacement source epoch when lock release rejects", async () => {
    const stateDir = join(await root(), "state");
    let injectReleaseFailure = false;
    let failed = false;
    let mutationParentSyncs = 0;
    let boundStateDir = "";
    const store = await load(stateDir, {
      lockOptions: {
        syncDirectory: async (path) => {
          if (path !== boundStateDir || !injectReleaseFailure || failed) return;
          mutationParentSyncs += 1;
          if (mutationParentSyncs === 2) {
            failed = true;
            throw Object.assign(new Error("EIO"), { code: "EIO" });
          }
        },
      },
    });
    boundStateDir = dirname(store.installationFile);
    const digest = locatorDigest("release-failure-atomicity");
    const original = await store.bindAuthenticatedCodexSource(digest);

    injectReleaseFailure = true;
    mutationParentSyncs = 0;
    await expect(
      store.replaceAuthenticatedCodexSource(digest),
    ).rejects.toMatchObject({ code: "EIO" });
    expect(failed).toBe(true);
    expect(
      await store.codexSources.isSourceEpochCurrent(
        digest,
        original.sourceEpoch,
      ),
    ).toBe(true);
  });

  it("reconciles installed state after the data rename final fsync rejects", async () => {
    const stateDir = join(await root(), "state");
    let boundStateDir = "";
    let injectMutationFailure = false;
    let relevantSyncs = 0;
    let failed = false;
    const store = await load(stateDir, {
      lockOptions: {
        syncDirectory: async (path) => {
          if (path !== boundStateDir || !injectMutationFailure || failed) {
            return;
          }
          relevantSyncs += 1;
          if (relevantSyncs === 2) {
            failed = true;
            throw Object.assign(new Error("EIO"), { code: "EIO" });
          }
        },
      },
    });
    boundStateDir = dirname(store.installationFile);
    const digest = locatorDigest("installed-before-final-fsync-failure");
    injectMutationFailure = true;

    await expect(
      store.bindAuthenticatedCodexSource(digest),
    ).rejects.toMatchObject({ code: "EIO" });
    expect(failed).toBe(true);

    const bindings = await store.sourceBindings();
    expect(bindings).toHaveLength(1);
    expect(bindings[0]).toMatchObject({
      provider: CODEX_SOURCE_PROVIDER,
      locatorDigest: digest,
    });
    const resolved = await store.bindAuthenticatedCodexSource(digest);
    expect(resolved.codexSourceId).toBe(bindings[0]!.codexSourceId);
    expect(
      await store.codexSources.isSourceEpochCurrent(
        digest,
        resolved.sourceEpoch,
      ),
    ).toBe(true);
  });

  it("keeps reconciliation pending when its mutation-lock release fails", async () => {
    const stateDir = join(await root(), "state");
    let boundStateDir = "";
    let injectDataFailure = false;
    let dataSyncs = 0;
    let dataFailed = false;
    let injectReleaseFailure = false;
    let releaseFailed = false;
    const store = await load(stateDir, {
      lockOptions: {
        syncDirectory: async (path) => {
          if (path !== boundStateDir || !injectDataFailure || dataFailed)
            return;
          dataSyncs += 1;
          if (dataSyncs === 2) {
            dataFailed = true;
            throw Object.assign(new Error("DATA-EIO"), { code: "DATA-EIO" });
          }
        },
        beforeReleaseSnapshotRead: async (lockPath) => {
          if (
            injectReleaseFailure &&
            !releaseFailed &&
            lockPath.endsWith(`${BRIDGE_INSTALLATION_FILE}.lock`)
          ) {
            releaseFailed = true;
            throw Object.assign(new Error("RELEASE-EIO"), {
              code: "RELEASE-EIO",
            });
          }
        },
      },
    });
    boundStateDir = dirname(store.installationFile);
    const digest = locatorDigest("reconciliation-release-retry");
    injectDataFailure = true;

    await expect(
      store.bindAuthenticatedCodexSource(digest),
    ).rejects.toMatchObject({ code: "DATA-EIO" });
    injectDataFailure = false;
    injectReleaseFailure = true;
    await expect(store.sourceBindings()).rejects.toMatchObject({
      code: "RELEASE-EIO",
    });

    const bindings = await store.sourceBindings();
    expect(bindings).toHaveLength(1);
    expect(bindings[0]).toMatchObject({ locatorDigest: digest });
  });

  it("reports failed load cleanup and lets the next load finish orphan recovery", async () => {
    const stateDir = join(await root(), "state");
    let loadFailureInjected = false;
    let cleanupFailureInjected = false;
    const lockOptions: StateMutationLockOptions = {
      attempts: 4,
      retryMs: 0,
      beforeInstalledSnapshotRead: async (lockPath) => {
        if (
          !loadFailureInjected &&
          lockPath.endsWith(`${BRIDGE_INSTALLATION_FILE}.lock`)
        ) {
          loadFailureInjected = true;
          throw Object.assign(new Error("LOAD-EIO"), { code: "LOAD-EIO" });
        }
      },
      syncDirectory: async (path) => {
        if (
          loadFailureInjected &&
          !cleanupFailureInjected &&
          path.endsWith(".lifecycle-v1")
        ) {
          cleanupFailureInjected = true;
          throw Object.assign(new Error("CLEANUP-EIO"), {
            code: "CLEANUP-EIO",
          });
        }
      },
    };

    let failure: unknown;
    try {
      await BridgeInstallationStore.load({ stateDir, lockOptions });
    } catch (error) {
      failure = error;
    }
    expect(failure).toBeInstanceOf(AggregateError);
    expect((failure as AggregateError).errors).toEqual([
      expect.objectContaining({ code: "LOAD-EIO" }),
      expect.objectContaining({ code: "CLEANUP-EIO" }),
    ]);

    const recovered = await load(stateDir, { lockOptions });
    expect(recovered.bridgeInstanceId).toMatch(
      /^bridge_instance_[A-Za-z0-9_-]{32}$/,
    );
  });

  it("recovers a failed load mutation-lock release in the same process", async () => {
    const stateDir = join(await root(), "state");
    let failed = false;
    const lockOptions: StateMutationLockOptions = {
      attempts: 4,
      retryMs: 0,
      beforeReleaseSnapshotRead: async (lockPath) => {
        if (!failed && lockPath.endsWith(`${BRIDGE_INSTALLATION_FILE}.lock`)) {
          failed = true;
          throw Object.assign(new Error("MUTATION-RELEASE-EIO"), {
            code: "MUTATION-RELEASE-EIO",
          });
        }
      },
    };

    await expect(
      BridgeInstallationStore.load({ stateDir, lockOptions }),
    ).rejects.toMatchObject({ code: "MUTATION-RELEASE-EIO" });
    expect(failed).toBe(true);

    const recovered = await load(stateDir, { lockOptions });
    expect(recovered.bridgeInstanceId).toMatch(
      /^bridge_instance_[A-Za-z0-9_-]{32}$/,
    );
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
    expect(await store.sourceBindings()).toHaveLength(1);
    expect(await readdir(stateDir)).toEqual([BRIDGE_INSTALLATION_FILE]);
    expect((await lstat(store.writerLeaseFile)).isDirectory()).toBe(true);
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
    expect(await store.sourceBindings()).toHaveLength(16);
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
    ).rejects.toThrow(/generation is already open/);

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
    expect(await reopened.sourceBindings()).toEqual([]);
  });

  it("shares close completion, drains a started mutation, and rejects queued work", async () => {
    const stateDir = join(await root(), "state");
    const store = await load(stateDir);
    const directory = await preparePrivateStateDirectory(stateDir);
    const blockerRelease = await acquireStateMutationLock(
      directory,
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
    ).rejects.toThrow(/generation is already open/);

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
      (await reopened.sourceBindings()).map((binding) => binding.locatorDigest),
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
    expect(await readdir(stateDir)).toEqual([BRIDGE_INSTALLATION_FILE]);
    expect(
      (await lstat(fulfilled[0]!.value.writerLeaseFile)).isDirectory(),
    ).toBe(true);
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
        await reopened.codexSources.isSourceEpochCurrent(
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
        await recovered.codexSources.isSourceEpochCurrent(
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

  it("rejects duplicate JSON keys at every persisted object depth", async () => {
    const stateDir = join(await root(), "duplicate-state");
    await mkdir(stateDir, { mode: 0o700 });
    const digest = locatorDigest("duplicate-binding");
    await writeFile(
      join(stateDir, BRIDGE_INSTALLATION_FILE),
      `{"schemaVersion":1,"bridgeInstanceId":"bridge_instance_12345678901234567890123456789012","sourceBindings":[{"provider":"CODEX","locatorDigest":"${digest}","codexSourceId":"codex_source_12345678901234567890123456789012","codexSourceId":"codex_source_12345678901234567890123456789012"}]}\n`,
      { mode: 0o600 },
    );

    await expect(BridgeInstallationStore.load({ stateDir })).rejects.toThrow(
      /malformed/,
    );
  });

  it("fails closed if the bound directory is replaced before installation authority access", async () => {
    const parent = await root();
    const stateDir = join(parent, "state");
    const displaced = join(parent, "state.displaced");
    const digest = locatorDigest("preserved-binding");
    const first = await load(stateDir);
    const originalInstance = first.bridgeInstanceId;
    const originalBinding = await first.bindAuthenticatedCodexSource(digest);
    await close(first);
    let replaced = false;

    await expect(
      BridgeInstallationStore.load({
        stateDir,
        lockOptions: {
          syncDirectory: async () => {
            if (replaced) return;
            replaced = true;
            await rename(stateDir, displaced);
            await mkdir(stateDir, { mode: 0o700 });
          },
        },
      }),
    ).rejects.toThrow(/directory changed after binding/);

    expect(existsSync(join(stateDir, BRIDGE_INSTALLATION_FILE))).toBe(false);
    const reopened = await load(displaced);
    const reopenedBinding = await reopened.bindAuthenticatedCodexSource(digest);
    expect(reopened.bridgeInstanceId).toBe(originalInstance);
    expect(reopenedBinding.codexSourceId).toBe(originalBinding.codexSourceId);
  });

  it("refuses source mutation after the open store directory is replaced", async () => {
    const parent = await root();
    const stateDir = join(parent, "state");
    const displaced = join(parent, "state.displaced");
    const store = await load(stateDir);
    const bridgeInstanceId = store.bridgeInstanceId;
    await rename(stateDir, displaced);
    await mkdir(stateDir, { mode: 0o700 });

    await expect(store.sourceBindings()).rejects.toThrow(
      /directory changed after binding/,
    );
    await expect(
      store.codexSources.isSourceEpochCurrent(
        locatorDigest("replacement-read"),
        "source_epoch_replacement_read_fixture",
      ),
    ).rejects.toThrow(/directory changed after binding/);
    await expect(
      store.codexSources.assertSourceEpoch(
        locatorDigest("replacement-read"),
        "source_epoch_replacement_read_fixture",
      ),
    ).rejects.toThrow(/directory changed after binding/);
    await expect(
      store.bindAuthenticatedCodexSource(locatorDigest("replacement-write")),
    ).rejects.toThrow(/directory changed after binding/);
    expect(existsSync(join(stateDir, BRIDGE_INSTALLATION_FILE))).toBe(false);

    await rm(stateDir, { recursive: true, force: true });
    await rename(displaced, stateDir);
    await close(store);
    const reopened = await load(stateDir);
    expect(reopened.bridgeInstanceId).toBe(bridgeInstanceId);
    expect(await reopened.sourceBindings()).toEqual([]);
  });

  it("invalidates source authority when only the lifecycle directory is replaced", async () => {
    const parent = await root();
    const stateDir = join(parent, "state");
    const lifecycle = `${stateDir}.lifecycle-v1`;
    const displaced = `${lifecycle}.displaced`;
    const store = await load(stateDir);
    const digest = locatorDigest("lifecycle-replacement");
    const active = await store.bindAuthenticatedCodexSource(digest);

    await rename(lifecycle, displaced);
    await mkdir(lifecycle, { mode: 0o700 });
    await expect(store.sourceBindings()).rejects.toThrow(
      /directory changed after binding/,
    );
    await expect(
      store.codexSources.isSourceEpochCurrent(digest, active.sourceEpoch),
    ).rejects.toThrow(/directory changed after binding/);
    await expect(
      store.bindAuthenticatedCodexSource(locatorDigest("replacement-write")),
    ).rejects.toThrow(/directory changed after binding/);

    await rm(lifecycle, { recursive: true, force: true });
    await rename(displaced, lifecycle);
    await close(store);
  });

  it("allows installation close to retry after final lease namespace sync failure", async () => {
    const stateDir = join(await root(), "state");
    let closing = false;
    let closeSyncs = 0;
    let failed = false;
    const store = await load(stateDir, {
      lockOptions: {
        syncDirectory: async () => {
          if (!closing) return;
          closeSyncs += 1;
          if (!failed && closeSyncs === 2) {
            failed = true;
            throw Object.assign(new Error("EIO"), { code: "EIO" });
          }
        },
      },
    });
    closing = true;

    await expect(store.close()).rejects.toMatchObject({ code: "EIO" });
    await expect(store.close()).resolves.toBeUndefined();
    const index = stores.indexOf(store);
    if (index >= 0) stores.splice(index, 1);
    expect(
      (await readdir(stateDir)).filter((entry) =>
        entry.includes("writer-lease"),
      ),
    ).toEqual([]);
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
    ).rejects.toThrow(/64 lowercase hex/);
    expect(
      await readFile(join(stateDir, BRIDGE_INSTALLATION_FILE), "utf8"),
    ).toBe(before);
  });
});
