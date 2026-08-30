import { randomBytes } from "node:crypto";
import { homedir } from "node:os";
import { join } from "node:path";

import {
  acquireStateMutationLock,
  atomicPrivateWrite,
  preparePrivateStateDirectory,
  readBoundedPrivateFile,
} from "./private-state.js";

export const BRIDGE_INSTALLATION_SCHEMA_VERSION = 1 as const;
export const BRIDGE_INSTALLATION_FILE = "conversation-core-installation-v1.json" as const;
export const CODEX_SOURCE_PROVIDER = "CODEX" as const;

const MAX_INSTALLATION_FILE_BYTES = 1024 * 1024;
const MAX_SOURCE_BINDINGS = 4096;
const LOCATOR_DIGEST_PATTERN = /^[0-9a-f]{64}$/;
const OPAQUE_ID_PATTERN = /^[A-Za-z0-9_-]{32,128}$/;
const ACTIVE_WRITERS = new Map<string, BridgeInstallationStore>();
const PENDING_WRITERS = new Set<string>();

export interface CodexSourceBinding {
  provider: typeof CODEX_SOURCE_PROVIDER;
  locatorDigest: string;
  codexSourceId: string;
  sourceEpoch: string;
  createdAt: string;
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
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function hasExactKeys(value: Record<string, unknown>, keys: readonly string[]): boolean {
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  return actual.length === expected.length && actual.every((key, index) => key === expected[index]);
}

function isCanonicalTimestamp(value: string): boolean {
  const parsed = new Date(value);
  return !Number.isNaN(parsed.valueOf()) && parsed.toISOString() === value;
}

function createOpaqueId(
  prefix: "bridge_instance" | "codex_source" | "source_epoch",
): string {
  return `${prefix}_${randomBytes(24).toString("base64url")}`;
}

function cloneBinding(binding: CodexSourceBinding): CodexSourceBinding {
  return { ...binding };
}

function parseInstallationFile(contents: string, path: string): BridgeInstallationFileData {
  let parsed: unknown;
  try {
    parsed = JSON.parse(contents);
  } catch (error) {
    throw new Error(`Bridge installation state is malformed: ${path}`, { cause: error });
  }
  if (
    !isPlainObject(parsed) ||
    !hasExactKeys(parsed, ["schemaVersion", "bridgeInstanceId", "sourceBindings"]) ||
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
  const sourceEpochs = new Set<string>();
  const sourceBindings: CodexSourceBinding[] = [];
  for (const candidate of parsed.sourceBindings) {
    if (
      !isPlainObject(candidate) ||
      !hasExactKeys(candidate, [
        "provider",
        "locatorDigest",
        "codexSourceId",
        "sourceEpoch",
        "createdAt",
      ]) ||
      candidate.provider !== CODEX_SOURCE_PROVIDER ||
      typeof candidate.locatorDigest !== "string" ||
      !LOCATOR_DIGEST_PATTERN.test(candidate.locatorDigest) ||
      typeof candidate.codexSourceId !== "string" ||
      !OPAQUE_ID_PATTERN.test(candidate.codexSourceId) ||
      typeof candidate.sourceEpoch !== "string" ||
      !OPAQUE_ID_PATTERN.test(candidate.sourceEpoch) ||
      typeof candidate.createdAt !== "string" ||
      !isCanonicalTimestamp(candidate.createdAt) ||
      digests.has(candidate.locatorDigest) ||
      sourceIds.has(candidate.codexSourceId) ||
      sourceEpochs.has(candidate.sourceEpoch)
    ) {
      throw new Error(`Bridge installation source binding is invalid: ${path}`);
    }
    digests.add(candidate.locatorDigest);
    sourceIds.add(candidate.codexSourceId);
    sourceEpochs.add(candidate.sourceEpoch);
    sourceBindings.push({
      provider: CODEX_SOURCE_PROVIDER,
      locatorDigest: candidate.locatorDigest,
      codexSourceId: candidate.codexSourceId,
      sourceEpoch: candidate.sourceEpoch,
      createdAt: candidate.createdAt,
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

  resolveCodexSource(locatorDigest: string): Promise<ResolvedCodexSource> {
    return this.installation.resolveCodexSource(locatorDigest);
  }
}

export class BridgeInstallationStore {
  readonly stateDir: string;
  readonly installationFile: string;
  readonly bridgeInstanceId: string;
  readonly codexSources: CodexSourceRegistry;
  private readonly writerKey: string;
  private readonly now: () => number;
  private state: BridgeInstallationFileData;
  private closed = false;
  private pendingOperations = 0;
  private operations: Promise<void> = Promise.resolve();

  private constructor(input: {
    stateDir: string;
    installationFile: string;
    writerKey: string;
    state: BridgeInstallationFileData;
    now: () => number;
  }) {
    this.stateDir = input.stateDir;
    this.installationFile = input.installationFile;
    this.writerKey = input.writerKey;
    this.state = input.state;
    this.bridgeInstanceId = input.state.bridgeInstanceId;
    this.now = input.now;
    this.codexSources = new CodexSourceRegistry(this);
  }

  static async load(
    options: BridgeInstallationStoreOptions = {},
  ): Promise<BridgeInstallationStore> {
    const requestedStateDir =
      options.stateDir ?? process.env.CCPOCKET_STATE_DIR ?? join(homedir(), ".ccpocket");
    const stateDir = await preparePrivateStateDirectory(requestedStateDir);
    const installationFile = join(stateDir, BRIDGE_INSTALLATION_FILE);
    const writerKey = installationFile;
    if (PENDING_WRITERS.has(writerKey) || ACTIVE_WRITERS.has(writerKey)) {
      throw new Error("Bridge installation writer is already open for this state path");
    }
    PENDING_WRITERS.add(writerKey);
    try {
      const releaseLock = await acquireStateMutationLock(
        installationFile,
        "Bridge installation state",
      );
      let state: BridgeInstallationFileData;
      try {
        const contents = await readBoundedPrivateFile(
          installationFile,
          MAX_INSTALLATION_FILE_BYTES,
          "Bridge installation state",
        );
        if (contents === undefined) {
          state = newInstallation();
          await atomicPrivateWrite(
            installationFile,
            `${JSON.stringify(state)}\n`,
            MAX_INSTALLATION_FILE_BYTES,
            "Bridge installation state",
          );
        } else {
          state = parseInstallationFile(contents, installationFile);
        }
      } finally {
        await releaseLock();
      }

      const store = new BridgeInstallationStore({
        stateDir,
        installationFile,
        writerKey,
        state,
        now: options.now ?? Date.now,
      });
      ACTIVE_WRITERS.set(writerKey, store);
      return store;
    } finally {
      PENDING_WRITERS.delete(writerKey);
    }
  }

  private runExclusive<T>(operation: () => Promise<T>): Promise<T> {
    this.pendingOperations += 1;
    const wrapped = async (): Promise<T> => {
      try {
        return await operation();
      } finally {
        this.pendingOperations -= 1;
        this.releaseWriterIfClosed();
      }
    };
    const result = this.operations.then(wrapped, wrapped);
    this.operations = result.then(
      () => undefined,
      () => undefined,
    );
    return result;
  }

  async resolveCodexSource(locatorDigest: string): Promise<ResolvedCodexSource> {
    if (!LOCATOR_DIGEST_PATTERN.test(locatorDigest)) {
      throw new Error("Codex source locator digest must be 64 lowercase hex characters");
    }
    return this.runExclusive(async () => {
      if (this.closed) throw new Error("Bridge installation store is closed");
      const releaseLock = await acquireStateMutationLock(
        this.installationFile,
        "Bridge installation state",
      );
      try {
        const contents = await readBoundedPrivateFile(
          this.installationFile,
          MAX_INSTALLATION_FILE_BYTES,
          "Bridge installation state",
        );
        if (contents === undefined) {
          throw new Error("Bridge installation state disappeared after load");
        }
        const current = parseInstallationFile(contents, this.installationFile);
        if (current.bridgeInstanceId !== this.bridgeInstanceId) {
          throw new Error("Bridge installation identity changed while the writer was open");
        }
        const existing = current.sourceBindings.find(
          (binding) => binding.locatorDigest === locatorDigest,
        );
        if (existing) {
          this.state = current;
          return {
            codexSourceId: existing.codexSourceId,
            sourceEpoch: existing.sourceEpoch,
          };
        }
        if (current.sourceBindings.length >= MAX_SOURCE_BINDINGS) {
          throw new Error("Bridge installation source binding limit reached");
        }

        const usedIds = new Set(current.sourceBindings.map((binding) => binding.codexSourceId));
        let codexSourceId = createOpaqueId("codex_source");
        while (usedIds.has(codexSourceId)) {
          codexSourceId = createOpaqueId("codex_source");
        }
        const usedEpochs = new Set(
          current.sourceBindings.map((binding) => binding.sourceEpoch),
        );
        let sourceEpoch = createOpaqueId("source_epoch");
        while (usedEpochs.has(sourceEpoch)) {
          sourceEpoch = createOpaqueId("source_epoch");
        }
        const binding: CodexSourceBinding = {
          provider: CODEX_SOURCE_PROVIDER,
          locatorDigest,
          codexSourceId,
          sourceEpoch,
          createdAt: new Date(this.now()).toISOString(),
        };
        const next: BridgeInstallationFileData = {
          ...current,
          sourceBindings: [...current.sourceBindings.map(cloneBinding), binding],
        };
        await atomicPrivateWrite(
          this.installationFile,
          `${JSON.stringify(next)}\n`,
          MAX_INSTALLATION_FILE_BYTES,
          "Bridge installation state",
        );
        this.state = next;
        return { codexSourceId, sourceEpoch: binding.sourceEpoch };
      } finally {
        await releaseLock();
      }
    });
  }

  sourceBindings(): readonly CodexSourceBinding[] {
    if (this.closed) throw new Error("Bridge installation store is closed");
    return this.state.sourceBindings.map(cloneBinding);
  }

  close(): void {
    if (this.closed) return;
    this.closed = true;
    this.releaseWriterIfClosed();
  }

  private releaseWriterIfClosed(): void {
    if (!this.closed || this.pendingOperations !== 0) return;
    if (ACTIVE_WRITERS.get(this.writerKey) === this) {
      ACTIVE_WRITERS.delete(this.writerKey);
    }
  }
}
