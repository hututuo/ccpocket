import { randomBytes } from "node:crypto";
import { homedir } from "node:os";
import { join } from "node:path";

import {
  acquirePrivateStateGenerationLease,
  acquireStateMutationLock,
  atomicPrivateWrite,
  assertPrivateStateDirectory,
  confirmPrivateStateDirectoryDurability,
  parseJsonWithoutDuplicateKeys,
  preparePrivateStateDirectory,
  readBoundedPrivateFile,
  type PrivateStateDirectoryBinding,
  type StateMutationLockOptions,
} from "./private-state.js";

export const BRIDGE_INSTALLATION_SCHEMA_VERSION = 1 as const;
export const BRIDGE_INSTALLATION_FILE =
  "conversation-core-installation-v1.json" as const;
export const CODEX_SOURCE_PROVIDER = "CODEX" as const;

const MAX_INSTALLATION_FILE_BYTES = 1024 * 1024;
const MAX_SOURCE_BINDINGS = 4096;
const LOCATOR_DIGEST_PATTERN = /^[0-9a-f]{64}$/;
const OPAQUE_ID_PATTERN = /^[A-Za-z0-9_-]{32,128}$/;
let sourceEpochSequence = 0;

export interface CodexSourceBinding {
  provider: typeof CODEX_SOURCE_PROVIDER;
  locatorDigest: string;
  codexSourceId: string;
}

export interface ResolvedCodexSource {
  codexSourceId: string;
  sourceEpoch: string;
}

interface BridgeInstallationFileData {
  schemaVersion: typeof BRIDGE_INSTALLATION_SCHEMA_VERSION;
  bridgeInstanceId: string;
  sourceBindings: CodexSourceBinding[];
}

export interface BridgeInstallationStoreOptions {
  stateDir?: string;
  now?: () => number;
  lockOptions?: StateMutationLockOptions;
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function hasExactKeys(
  value: Record<string, unknown>,
  keys: readonly string[],
): boolean {
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  return (
    actual.length === expected.length &&
    actual.every((key, index) => key === expected[index])
  );
}

function createOpaqueId(prefix: "bridge_instance" | "codex_source"): string {
  return `${prefix}_${randomBytes(24).toString("base64url")}`;
}

function createSourceEpoch(): string {
  sourceEpochSequence += 1;
  return `source_epoch_${sourceEpochSequence.toString(36)}_${randomBytes(
    24,
  ).toString("base64url")}`;
}

function cloneBinding(binding: CodexSourceBinding): CodexSourceBinding {
  return { ...binding };
}

function parseInstallationFile(
  contents: string,
  path: string,
): BridgeInstallationFileData {
  let parsed: unknown;
  try {
    parsed = parseJsonWithoutDuplicateKeys(contents);
  } catch (error) {
    throw new Error(`Bridge installation state is malformed: ${path}`, {
      cause: error,
    });
  }
  if (
    !isPlainObject(parsed) ||
    !hasExactKeys(parsed, [
      "schemaVersion",
      "bridgeInstanceId",
      "sourceBindings",
    ]) ||
    parsed.schemaVersion !== BRIDGE_INSTALLATION_SCHEMA_VERSION ||
    typeof parsed.bridgeInstanceId !== "string" ||
    !OPAQUE_ID_PATTERN.test(parsed.bridgeInstanceId) ||
    !Array.isArray(parsed.sourceBindings) ||
    parsed.sourceBindings.length > MAX_SOURCE_BINDINGS
  ) {
    throw new Error(`Bridge installation state is invalid: ${path}`);
  }

  const digests = new Set<string>();
  const sourceIds = new Set<string>();
  const sourceBindings: CodexSourceBinding[] = [];
  for (const candidate of parsed.sourceBindings) {
    if (
      !isPlainObject(candidate) ||
      !hasExactKeys(candidate, [
        "provider",
        "locatorDigest",
        "codexSourceId",
      ]) ||
      candidate.provider !== CODEX_SOURCE_PROVIDER ||
      typeof candidate.locatorDigest !== "string" ||
      !LOCATOR_DIGEST_PATTERN.test(candidate.locatorDigest) ||
      typeof candidate.codexSourceId !== "string" ||
      !OPAQUE_ID_PATTERN.test(candidate.codexSourceId) ||
      digests.has(candidate.locatorDigest) ||
      sourceIds.has(candidate.codexSourceId)
    ) {
      throw new Error(`Bridge installation source binding is invalid: ${path}`);
    }
    digests.add(candidate.locatorDigest);
    sourceIds.add(candidate.codexSourceId);
    sourceBindings.push({
      provider: CODEX_SOURCE_PROVIDER,
      locatorDigest: candidate.locatorDigest,
      codexSourceId: candidate.codexSourceId,
    });
  }
  return {
    schemaVersion: BRIDGE_INSTALLATION_SCHEMA_VERSION,
    bridgeInstanceId: parsed.bridgeInstanceId,
    sourceBindings,
  };
}

function newInstallation(): BridgeInstallationFileData {
  return {
    schemaVersion: BRIDGE_INSTALLATION_SCHEMA_VERSION,
    bridgeInstanceId: createOpaqueId("bridge_instance"),
    sourceBindings: [],
  };
}

export class CodexSourceRegistry {
  private readonly installation: BridgeInstallationStore;

  constructor(installation: BridgeInstallationStore) {
    this.installation = installation;
  }

  bindAuthenticatedCodexSource(
    locatorDigest: string,
  ): Promise<ResolvedCodexSource> {
    return this.installation.bindAuthenticatedCodexSource(locatorDigest);
  }

  replaceAuthenticatedCodexSource(
    locatorDigest: string,
  ): Promise<ResolvedCodexSource> {
    return this.installation.replaceAuthenticatedCodexSource(locatorDigest);
  }

  isSourceEpochCurrent(
    locatorDigest: string,
    sourceEpoch: string,
  ): Promise<boolean> {
    return this.installation.isSourceEpochCurrent(locatorDigest, sourceEpoch);
  }

  async assertSourceEpoch(
    locatorDigest: string,
    sourceEpoch: string,
    codexSourceId?: string,
  ): Promise<void> {
    return this.installation.assertSourceEpoch(
      locatorDigest,
      sourceEpoch,
      codexSourceId,
    );
  }
}

export class BridgeInstallationStore {
  readonly stateDir: string;
  readonly installationFile: string;
  readonly writerLeaseFile: string;
  readonly bridgeInstanceId: string;
  readonly codexSources: CodexSourceRegistry;
  private readonly writerLeaseRelease: () => Promise<void>;
  private readonly directory: PrivateStateDirectoryBinding;
  private readonly lockOptions: StateMutationLockOptions;
  private state: BridgeInstallationFileData;
  private needsReconciliation = false;
  private readonly activeSourceEpochs = new Map<
    string,
    { codexSourceId: string; sourceEpoch: string }
  >();
  private closed = false;
  private closePromise: Promise<void> | undefined;
  private operations: Promise<void> = Promise.resolve();

  private constructor(input: {
    stateDir: string;
    installationFile: string;
    writerLeaseFile: string;
    writerLeaseRelease: () => Promise<void>;
    directory: PrivateStateDirectoryBinding;
    state: BridgeInstallationFileData;
    lockOptions: StateMutationLockOptions;
  }) {
    this.stateDir = input.stateDir;
    this.installationFile = input.installationFile;
    this.writerLeaseFile = input.writerLeaseFile;
    this.writerLeaseRelease = input.writerLeaseRelease;
    this.directory = input.directory;
    this.state = input.state;
    this.bridgeInstanceId = input.state.bridgeInstanceId;
    this.lockOptions = input.lockOptions;
    this.codexSources = new CodexSourceRegistry(this);
  }

  static async load(
    options: BridgeInstallationStoreOptions = {},
  ): Promise<BridgeInstallationStore> {
    const requestedStateDir =
      options.stateDir ??
      process.env.CCPOCKET_STATE_DIR ??
      join(homedir(), ".ccpocket");
    const directory = await preparePrivateStateDirectory(requestedStateDir);
    const stateDir = directory.path;
    const installationFile = join(stateDir, BRIDGE_INSTALLATION_FILE);
    const lockOptions = { ...options.lockOptions };
    if (lockOptions.now === undefined && options.now !== undefined) {
      lockOptions.now = options.now;
    }
    let generationLease:
      | Awaited<ReturnType<typeof acquirePrivateStateGenerationLease>>
      | undefined;
    let writerLeaseRelease: (() => Promise<void>) | undefined;
    let writerLeaseFile: string;
    try {
      generationLease = await acquirePrivateStateGenerationLease(
        directory,
        "bridge-installation",
        lockOptions,
      );
      writerLeaseRelease = generationLease.release;
      writerLeaseFile = generationLease.writerLeaseFile;
      const releaseLock = await acquireStateMutationLock(
        directory,
        installationFile,
        "Bridge installation state",
        lockOptions,
      );
      let state: BridgeInstallationFileData;
      try {
        const contents = await readBoundedPrivateFile(
          directory,
          installationFile,
          MAX_INSTALLATION_FILE_BYTES,
          "Bridge installation state",
        );
        if (contents === undefined) {
          state = newInstallation();
          await atomicPrivateWrite(
            directory,
            installationFile,
            `${JSON.stringify(state)}\n`,
            MAX_INSTALLATION_FILE_BYTES,
            "Bridge installation state",
            {
              syncDirectory: lockOptions.syncDirectory,
              createOnly: true,
            },
          );
        } else {
          state = parseInstallationFile(contents, installationFile);
        }
        await confirmPrivateStateDirectoryDurability(
          directory,
          lockOptions.syncDirectory,
        );
      } finally {
        await releaseLock();
      }
      return new BridgeInstallationStore({
        stateDir,
        installationFile,
        writerLeaseFile,
        writerLeaseRelease,
        directory,
        state,
        lockOptions,
      });
    } catch (error) {
      if (writerLeaseRelease !== undefined) {
        try {
          await writerLeaseRelease();
        } catch (cleanupError) {
          await generationLease?.abandon();
          throw new AggregateError(
            [error, cleanupError],
            "Bridge installation load and generation cleanup both failed",
          );
        }
      }
      throw error;
    }
  }

  private runExclusive<T>(operation: () => Promise<T>): Promise<T> {
    const wrapped = async (): Promise<T> => {
      if (this.closed) throw new Error("Bridge installation store is closed");
      return operation();
    };
    const result = this.operations.then(wrapped, wrapped);
    this.operations = result.then(
      () => undefined,
      () => undefined,
    );
    return result;
  }

  async bindAuthenticatedCodexSource(
    locatorDigest: string,
  ): Promise<ResolvedCodexSource> {
    return this.runExclusive(() => this.bindCodexSource(locatorDigest, false));
  }

  async replaceAuthenticatedCodexSource(
    locatorDigest: string,
  ): Promise<ResolvedCodexSource> {
    return this.runExclusive(() => this.bindCodexSource(locatorDigest, true));
  }

  private async bindCodexSource(
    locatorDigest: string,
    forceNewEpoch: boolean,
  ): Promise<ResolvedCodexSource> {
    if (!LOCATOR_DIGEST_PATTERN.test(locatorDigest)) {
      throw new Error(
        "Codex source locator digest must be 64 lowercase hex characters",
      );
    }
    const releaseLock = await acquireStateMutationLock(
      this.directory,
      this.installationFile,
      "Bridge installation state",
      this.lockOptions,
    );
    let writeAttempted = false;
    try {
      const contents = await readBoundedPrivateFile(
        this.directory,
        this.installationFile,
        MAX_INSTALLATION_FILE_BYTES,
        "Bridge installation state",
      );
      if (contents === undefined) {
        throw new Error("Bridge installation state disappeared after load");
      }
      const current = parseInstallationFile(contents, this.installationFile);
      if (current.bridgeInstanceId !== this.bridgeInstanceId) {
        throw new Error(
          "Bridge installation identity changed while the writer was open",
        );
      }
      this.state = current;
      this.needsReconciliation = false;
      const existing = current.sourceBindings.find(
        (binding) => binding.locatorDigest === locatorDigest,
      );
      let codexSourceId = existing?.codexSourceId;
      if (codexSourceId === undefined) {
        if (current.sourceBindings.length >= MAX_SOURCE_BINDINGS) {
          throw new Error("Bridge installation source binding limit reached");
        }
        const usedIds = new Set(
          current.sourceBindings.map((binding) => binding.codexSourceId),
        );
        codexSourceId = createOpaqueId("codex_source");
        while (usedIds.has(codexSourceId)) {
          codexSourceId = createOpaqueId("codex_source");
        }
        const binding: CodexSourceBinding = {
          provider: CODEX_SOURCE_PROVIDER,
          locatorDigest,
          codexSourceId,
        };
        const next: BridgeInstallationFileData = {
          ...current,
          sourceBindings: [
            ...current.sourceBindings.map(cloneBinding),
            binding,
          ],
        };
        writeAttempted = true;
        await atomicPrivateWrite(
          this.directory,
          this.installationFile,
          `${JSON.stringify(next)}\n`,
          MAX_INSTALLATION_FILE_BYTES,
          "Bridge installation state",
          { syncDirectory: this.lockOptions.syncDirectory },
        );
        this.state = next;
      }

      const active = this.activeSourceEpochs.get(locatorDigest);
      const resolved =
        !forceNewEpoch && active?.codexSourceId === codexSourceId
          ? { ...active }
          : { codexSourceId, sourceEpoch: createSourceEpoch() };
      await releaseLock();
      this.activeSourceEpochs.set(locatorDigest, resolved);
      return { ...resolved };
    } catch (error) {
      if (writeAttempted) this.needsReconciliation = true;
      await releaseLock().catch(() => undefined);
      throw error;
    }
  }

  async sourceBindings(): Promise<readonly CodexSourceBinding[]> {
    return this.runExclusive(async () => {
      await assertPrivateStateDirectory(this.directory);
      if (this.needsReconciliation) {
        const releaseLock = await acquireStateMutationLock(
          this.directory,
          this.installationFile,
          "Bridge installation state",
          this.lockOptions,
        );
        try {
          const contents = await readBoundedPrivateFile(
            this.directory,
            this.installationFile,
            MAX_INSTALLATION_FILE_BYTES,
            "Bridge installation state",
          );
          if (contents === undefined) {
            throw new Error("Bridge installation state disappeared after load");
          }
          const persisted = parseInstallationFile(
            contents,
            this.installationFile,
          );
          if (persisted.bridgeInstanceId !== this.bridgeInstanceId) {
            throw new Error(
              "Bridge installation identity changed while the writer was open",
            );
          }
          this.state = persisted;
          this.needsReconciliation = false;
        } finally {
          await releaseLock();
        }
      }
      return this.state.sourceBindings.map(cloneBinding);
    });
  }

  async isSourceEpochCurrent(
    locatorDigest: string,
    sourceEpoch: string,
  ): Promise<boolean> {
    if (this.closed) return false;
    await assertPrivateStateDirectory(this.directory);
    return (
      this.activeSourceEpochs.get(locatorDigest)?.sourceEpoch === sourceEpoch
    );
  }

  async assertSourceEpoch(
    locatorDigest: string,
    sourceEpoch: string,
    codexSourceId?: string,
  ): Promise<void> {
    if (!this.closed) await assertPrivateStateDirectory(this.directory);
    const active = this.activeSourceEpochs.get(locatorDigest);
    if (
      this.closed ||
      active === undefined ||
      active.sourceEpoch !== sourceEpoch ||
      (codexSourceId !== undefined && active.codexSourceId !== codexSourceId)
    ) {
      throw new Error("Codex source epoch is not current");
    }
  }

  close(): Promise<void> {
    if (this.closePromise) return this.closePromise;
    this.closed = true;
    this.activeSourceEpochs.clear();
    const releaseAttempt = this.operations.then(() =>
      this.writerLeaseRelease(),
    );
    const trackedAttempt = releaseAttempt.catch((error: unknown) => {
      if (this.closePromise === trackedAttempt) this.closePromise = undefined;
      throw error;
    });
    this.closePromise = trackedAttempt;
    return trackedAttempt;
  }
}
