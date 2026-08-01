import { randomUUID } from "node:crypto";
import { constants as fsConstants } from "node:fs";
import { chmod, lstat, mkdir, open, rename, rm } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

const STORE_VERSION = 1;
const DEFAULT_BRIDGE_PORT = 8765;
const DEFAULT_MAX_RECORDS = 4_096;
const DEFAULT_MAX_STORE_BYTES = 8 * 1024 * 1024;
const DEFAULT_MAX_PAYLOAD_BYTES = 512 * 1024;
const DEFAULT_TERMINAL_RETENTION_MS = 7 * 24 * 60 * 60 * 1_000;
const MAX_ID_LENGTH = 256;
const MAX_SOURCE_ID_LENGTH = 160;
const MAX_TEXT_FIELD_LENGTH = 32 * 1024;
const MAX_STRUCTURED_REFS = 64;

export interface InputDeliveryScope {
  bridgeInstanceId: string;
  codexSourceId: string;
}

export interface InputDeliveryIdentity extends InputDeliveryScope {
  providerThreadId: string;
  clientMessageId: string;
}

export interface DurableInputPayload {
  itemId: string;
  text: string;
  createdAt: string;
  updatedAt?: string;
  userMessageUuid?: string;
  skills?: Array<{ name: string; path: string }>;
  mentions?: Array<{ name: string; path: string }>;
}

export type DurableInputDeliveryState =
  | "queued"
  | "provider_dispatching"
  | "provider_accepted"
  | "provider_rejected"
  | "outcome_unknown"
  | "cancelled";

export type DurableInputDeliveryMethod = "turn/start" | "turn/steer";

export interface DurableInputDeliveryRecord extends InputDeliveryIdentity {
  state: DurableInputDeliveryState;
  acceptedSeq: number;
  queued: boolean;
  payload?: DurableInputPayload;
  containsImages: boolean;
  method?: DurableInputDeliveryMethod;
  replaySafety: "queue_exact" | "client_message_id" | "none";
  clientUserMessageIdAccepted?: boolean;
  occurredAt: string;
  updatedAt: string;
  errorCode?: string;
  error?: string;
  revision: number;
}

export interface InputDeliveryLedgerHealth {
  initialized: boolean;
  ready: boolean;
  degraded: boolean;
  revision: number;
  recordCount: number;
  activeCount: number;
  lastFailureAt?: string;
  lastError?: string;
}

export interface InputDeliveryAdmission {
  identity: InputDeliveryIdentity;
  acceptedSeq: number;
  queued: boolean;
  payload: DurableInputPayload;
  containsImages?: boolean;
}

export interface InputDeliveryProviderOutcome {
  identity: InputDeliveryIdentity;
  stage: "provider_accepted" | "provider_rejected";
  method: DurableInputDeliveryMethod;
  occurredAt: string;
  clientUserMessageIdAccepted?: boolean;
  error?: string;
}

export interface InputDeliveryRecoveryPlan {
  records: DurableInputDeliveryRecord[];
  replay: Array<{
    record: DurableInputDeliveryRecord;
    payload: DurableInputPayload;
    requireClientUserMessageId: boolean;
  }>;
  outcomeUnknown: DurableInputDeliveryRecord[];
}

interface ClientIdCapabilityRecord extends InputDeliveryScope {
  method: DurableInputDeliveryMethod;
  supported: boolean;
  observedAt: string;
}

interface PersistedInputDeliveryStore {
  version: 1;
  revision: number;
  records: DurableInputDeliveryRecord[];
  clientIdCapabilities: ClientIdCapabilityRecord[];
}

export type InputDeliveryLedgerErrorCode =
  | "unavailable"
  | "capacity"
  | "payload_too_large"
  | "unsafe_payload"
  | "identity_conflict"
  | "queue_full"
  | "record_missing";

export class InputDeliveryLedgerError extends Error {
  constructor(
    readonly code: InputDeliveryLedgerErrorCode,
    message: string,
  ) {
    super(message);
    this.name = "InputDeliveryLedgerError";
  }
}

export interface InputDeliveryLedgerOptions {
  filePath?: string;
  port?: number | string;
  maxRecords?: number;
  maxStoreBytes?: number;
  maxPayloadBytes?: number;
  terminalRetentionMs?: number;
  now?: () => Date;
}

const DEFAULT_STORE_FILE = join(
  homedir(),
  ".ccpocket",
  "input-delivery-v1.json",
);

export function inputDeliveryLedgerFileForPort(
  port: number | string | undefined,
  explicitFile?: string,
): string {
  if (explicitFile?.trim()) return explicitFile.trim();
  const parsedPort =
    typeof port === "number" ? port : Number.parseInt(port ?? "", 10);
  if (!Number.isInteger(parsedPort) || parsedPort === DEFAULT_BRIDGE_PORT) {
    return DEFAULT_STORE_FILE;
  }
  return join(homedir(), ".ccpocket", `input-delivery-v1-${parsedPort}.json`);
}

/**
 * Durable Bridge admission and provider-receipt ledger.
 *
 * The ledger is deliberately independent from Mobile's outbox. Once Bridge
 * has acknowledged a queued input, this file is the authority that survives a
 * Bridge-only restart. Payloads are retained only while delivery is active;
 * terminal receipts discard message text and structured references.
 */
export class InputDeliveryLedger {
  readonly filePath: string;

  private data: PersistedInputDeliveryStore = emptyStore();
  private mutationTail: Promise<void> = Promise.resolve();
  private loadPromise: Promise<void> | undefined;
  private healthState: InputDeliveryLedgerHealth = {
    initialized: false,
    ready: false,
    degraded: false,
    revision: 0,
    recordCount: 0,
    activeCount: 0,
  };
  private readonly maxRecords: number;
  private readonly maxStoreBytes: number;
  private readonly maxPayloadBytes: number;
  private readonly terminalRetentionMs: number;
  private readonly now: () => Date;

  constructor(options: InputDeliveryLedgerOptions = {}) {
    this.filePath =
      options.filePath ?? inputDeliveryLedgerFileForPort(options.port);
    this.maxRecords = positiveInteger(
      options.maxRecords,
      DEFAULT_MAX_RECORDS,
      "record capacity",
    );
    this.maxStoreBytes = positiveInteger(
      options.maxStoreBytes,
      DEFAULT_MAX_STORE_BYTES,
      "store byte limit",
    );
    this.maxPayloadBytes = positiveInteger(
      options.maxPayloadBytes,
      DEFAULT_MAX_PAYLOAD_BYTES,
      "payload byte limit",
    );
    this.terminalRetentionMs = nonNegativeInteger(
      options.terminalRetentionMs,
      DEFAULT_TERMINAL_RETENTION_MS,
      "terminal retention",
    );
    this.now = options.now ?? (() => new Date());
  }

  get health(): InputDeliveryLedgerHealth {
    return { ...this.healthState };
  }

  init(): Promise<void> {
    this.loadPromise ??= this.load().then(
      () => {
        this.refreshHealth(false);
      },
      (error) => {
        this.markDegraded(error, false);
        throw error;
      },
    );
    return this.loadPromise;
  }

  get(identity: InputDeliveryIdentity): DurableInputDeliveryRecord | undefined {
    const normalized = normalizeIdentity(identity);
    const record = this.data.records.find(
      (candidate) =>
        inputDeliveryKey(candidate) === inputDeliveryKey(normalized),
    );
    return record ? cloneRecord(record) : undefined;
  }

  listThread(
    scope: InputDeliveryScope,
    providerThreadId: string,
  ): DurableInputDeliveryRecord[] {
    const normalizedScope = normalizeScope(scope);
    const threadId = normalizeId(providerThreadId, "provider thread");
    return this.data.records
      .filter(
        (record) =>
          record.bridgeInstanceId === normalizedScope.bridgeInstanceId &&
          record.codexSourceId === normalizedScope.codexSourceId &&
          record.providerThreadId === threadId,
      )
      .map(cloneRecord);
  }

  recoveryPlan(
    scope: InputDeliveryScope,
    providerThreadId: string,
  ): InputDeliveryRecoveryPlan {
    const records = this.listThread(scope, providerThreadId);
    const replay: InputDeliveryRecoveryPlan["replay"] = [];
    const outcomeUnknown: DurableInputDeliveryRecord[] = [];
    for (const record of records) {
      if (record.state === "queued") {
        if (record.payload && !record.containsImages) {
          replay.push({
            record,
            payload: clonePayload(record.payload),
            requireClientUserMessageId: false,
          });
        } else {
          outcomeUnknown.push(record);
        }
        continue;
      }
      if (record.state !== "provider_dispatching") continue;
      if (
        record.method === "turn/start" &&
        record.replaySafety === "client_message_id" &&
        record.payload &&
        !record.containsImages
      ) {
        replay.push({
          record,
          payload: clonePayload(record.payload),
          requireClientUserMessageId: true,
        });
      } else {
        outcomeUnknown.push(record);
      }
    }
    return { records, replay, outcomeUnknown };
  }

  async admit(admission: InputDeliveryAdmission): Promise<{
    outcome: "created" | "existing";
    record: DurableInputDeliveryRecord;
  }> {
    const identity = normalizeIdentity(admission.identity);
    const payload = normalizePayload(admission.payload, this.maxPayloadBytes);
    const acceptedSeq = normalizeSequence(admission.acceptedSeq);
    const queued = admission.queued === true;
    const containsImages = admission.containsImages === true;
    if (queued && containsImages) {
      throw new InputDeliveryLedgerError(
        "unsafe_payload",
        "Queued image input cannot be recovered safely after a Bridge restart.",
      );
    }
    return this.runMutation<{
      outcome: "created" | "existing";
      record: DurableInputDeliveryRecord;
    }>(async (next) => {
      const key = inputDeliveryKey(identity);
      const existing = next.records.find(
        (record) => inputDeliveryKey(record) === key,
      );
      if (existing) {
        if (!sameAdmission(existing, queued, payload, containsImages)) {
          throw new InputDeliveryLedgerError(
            "identity_conflict",
            "The client message id is already bound to different input.",
          );
        }
        return {
          changed: false,
          value: {
            outcome: "existing" as const,
            record: cloneRecord(existing),
          },
        };
      }
      if (
        queued &&
        next.records.some(
          (record) =>
            sameThread(record, identity) &&
            (record.state === "queued" ||
              (record.state === "provider_dispatching" && record.queued)),
        )
      ) {
        throw new InputDeliveryLedgerError(
          "queue_full",
          "The durable next-turn queue is full.",
        );
      }
      const now = this.now().toISOString();
      next.revision += 1;
      const record: DurableInputDeliveryRecord = {
        ...identity,
        state: queued ? "queued" : "provider_dispatching",
        acceptedSeq,
        queued,
        payload,
        containsImages,
        ...(queued ? {} : { method: "turn/start" as const }),
        replaySafety: queued
          ? "queue_exact"
          : containsImages
            ? "none"
            : capabilityFor(next, identity, "turn/start") !== false
              ? "client_message_id"
              : "none",
        occurredAt: now,
        updatedAt: now,
        revision: next.revision,
      };
      next.records.push(record);
      this.prune(next, key);
      return {
        changed: true,
        value: { outcome: "created" as const, record: cloneRecord(record) },
      };
    });
  }

  async updateQueued(
    identity: InputDeliveryIdentity,
    payload: DurableInputPayload,
  ): Promise<DurableInputDeliveryRecord> {
    const normalizedIdentity = normalizeIdentity(identity);
    const normalizedPayload = normalizePayload(payload, this.maxPayloadBytes);
    return this.runMutation(async (next) => {
      const record = requireMutableRecord(next, normalizedIdentity);
      if (record.state !== "queued") {
        throw new InputDeliveryLedgerError(
          "record_missing",
          "The durable input is no longer queued.",
        );
      }
      next.revision += 1;
      record.payload = normalizedPayload;
      record.updatedAt = this.now().toISOString();
      record.revision = next.revision;
      this.prune(next, inputDeliveryKey(record));
      return { changed: true, value: cloneRecord(record) };
    });
  }

  async markDispatching(
    identity: InputDeliveryIdentity,
    method: DurableInputDeliveryMethod,
  ): Promise<DurableInputDeliveryRecord> {
    const normalizedIdentity = normalizeIdentity(identity);
    const normalizedMethod = normalizeMethod(method);
    return this.runMutation(async (next) => {
      const record = requireMutableRecord(next, normalizedIdentity);
      if (isProviderTerminal(record.state)) {
        return { changed: false, value: cloneRecord(record) };
      }
      if (
        record.state === "provider_dispatching" &&
        record.method === normalizedMethod
      ) {
        return { changed: false, value: cloneRecord(record) };
      }
      if (record.state !== "queued") {
        throw new InputDeliveryLedgerError(
          "record_missing",
          "The durable input is not available for provider dispatch.",
        );
      }
      next.revision += 1;
      record.state = "provider_dispatching";
      record.method = normalizedMethod;
      record.replaySafety =
        normalizedMethod === "turn/start" &&
        !record.containsImages &&
        capabilityFor(next, normalizedIdentity, normalizedMethod) !== false
          ? "client_message_id"
          : "none";
      record.updatedAt = this.now().toISOString();
      record.revision = next.revision;
      this.prune(next, inputDeliveryKey(record));
      return { changed: true, value: cloneRecord(record) };
    });
  }

  async recordProviderOutcome(
    outcome: InputDeliveryProviderOutcome,
  ): Promise<DurableInputDeliveryRecord> {
    const identity = normalizeIdentity(outcome.identity);
    const stage = normalizeProviderStage(outcome.stage);
    const method = normalizeMethod(outcome.method);
    const occurredAt = normalizeIso(outcome.occurredAt);
    const error = normalizeOptionalError(outcome.error);
    return this.runMutation(async (next) => {
      const record = requireMutableRecord(next, identity);
      if (
        record.state === "provider_accepted" ||
        record.state === "provider_rejected"
      ) {
        return { changed: false, value: cloneRecord(record) };
      }
      if (outcome.clientUserMessageIdAccepted !== undefined) {
        setCapability(
          next,
          identity,
          method,
          outcome.clientUserMessageIdAccepted,
          occurredAt,
        );
      }
      next.revision += 1;
      record.state = stage;
      record.method = method;
      record.clientUserMessageIdAccepted = outcome.clientUserMessageIdAccepted;
      record.occurredAt = occurredAt;
      record.updatedAt = occurredAt;
      record.error = error;
      record.errorCode = error ? "provider_rejected" : undefined;
      record.payload = undefined;
      record.replaySafety = "none";
      record.revision = next.revision;
      this.prune(next, inputDeliveryKey(record));
      return { changed: true, value: cloneRecord(record) };
    });
  }

  async markOutcomeUnknown(
    identity: InputDeliveryIdentity,
    reason = "Bridge restarted after provider dispatch began; the input was not replayed.",
  ): Promise<DurableInputDeliveryRecord> {
    const normalizedIdentity = normalizeIdentity(identity);
    const safeReason =
      normalizeOptionalError(reason) ?? "Delivery outcome is unknown.";
    return this.runMutation(async (next) => {
      const record = requireMutableRecord(next, normalizedIdentity);
      if (isProviderTerminal(record.state)) {
        return { changed: false, value: cloneRecord(record) };
      }
      next.revision += 1;
      record.state = "outcome_unknown";
      record.errorCode = "outcome_unknown_after_restart";
      record.error = safeReason;
      record.payload = undefined;
      record.replaySafety = "none";
      record.updatedAt = this.now().toISOString();
      record.revision = next.revision;
      this.prune(next, inputDeliveryKey(record));
      return { changed: true, value: cloneRecord(record) };
    });
  }

  async cancel(
    identity: InputDeliveryIdentity,
  ): Promise<DurableInputDeliveryRecord> {
    const normalizedIdentity = normalizeIdentity(identity);
    return this.runMutation(async (next) => {
      const record = requireMutableRecord(next, normalizedIdentity);
      if (record.state === "cancelled") {
        return { changed: false, value: cloneRecord(record) };
      }
      if (record.state !== "queued") {
        throw new InputDeliveryLedgerError(
          "record_missing",
          "The durable input can no longer be cancelled.",
        );
      }
      next.revision += 1;
      record.state = "cancelled";
      record.errorCode = "cancelled";
      record.error = "The queued input was cancelled before provider delivery.";
      record.payload = undefined;
      record.replaySafety = "none";
      record.updatedAt = this.now().toISOString();
      record.revision = next.revision;
      this.prune(next, inputDeliveryKey(record));
      return { changed: true, value: cloneRecord(record) };
    });
  }

  async flush(): Promise<void> {
    await this.mutationTail;
  }

  private async load(): Promise<void> {
    const directory = dirname(this.filePath);
    await mkdir(directory, { recursive: true, mode: 0o700 });
    let handle: Awaited<ReturnType<typeof open>> | undefined;
    try {
      handle = await open(
        this.filePath,
        fsConstants.O_RDONLY |
          (process.platform === "win32" ? 0 : fsConstants.O_NOFOLLOW),
      );
    } catch (error) {
      const code = (error as NodeJS.ErrnoException)?.code;
      if (code === "ENOENT") {
        this.data = emptyStore();
        return;
      }
      throw error;
    }
    try {
      const metadata = await handle.stat();
      if (!metadata.isFile() || metadata.size > this.maxStoreBytes) {
        throw new Error("Input delivery ledger is unsafe or oversized");
      }
      if (process.platform !== "win32" && (metadata.mode & 0o077) !== 0) {
        await handle.chmod(0o600);
      }
      const raw = await handle.readFile("utf8");
      if (Buffer.byteLength(raw, "utf8") > this.maxStoreBytes) {
        throw new Error("Input delivery ledger exceeds its byte limit");
      }
      this.data = parseStore(
        JSON.parse(raw),
        this.maxRecords,
        this.maxPayloadBytes,
      );
      this.pruneExpiredTerminals(this.data);
    } finally {
      await handle.close().catch(() => undefined);
    }
  }

  private async runMutation<T>(
    operation: (
      next: PersistedInputDeliveryStore,
    ) => Promise<{ changed: boolean; value: T }>,
  ): Promise<T> {
    if (!this.healthState.ready) {
      throw new InputDeliveryLedgerError(
        "unavailable",
        "Durable input delivery is unavailable; the message was not accepted.",
      );
    }
    const previous = this.mutationTail;
    let release!: () => void;
    this.mutationTail = new Promise<void>((resolve) => {
      release = resolve;
    });
    await previous;
    try {
      if (!this.healthState.ready) {
        throw new InputDeliveryLedgerError(
          "unavailable",
          "Durable input delivery is unavailable; the message was not accepted.",
        );
      }
      const next = cloneStore(this.data);
      this.pruneExpiredTerminals(next);
      const result = await operation(next);
      if (!result.changed) return result.value;
      const publication = await this.save(next);
      this.data = next;
      if (publication.postPublishError !== undefined) {
        // rename() already made this exact admission visible at the canonical
        // ledger path. Reporting "not accepted" now would be false: the live
        // Bridge continues from the published record and a restart may recover
        // it. Keep this operation successful, degrade the ledger before any
        // later mutation, and let the same clientMessageId reconcile the exact
        // durable record. This prevents the rejected-now/replayed-later ghost
        // send split-brain.
        this.markDegraded(publication.postPublishError, true);
        return result.value;
      }
      this.refreshHealth(false);
      return result.value;
    } catch (error) {
      if (
        !(error instanceof InputDeliveryLedgerError) ||
        error.code === "unavailable"
      ) {
        this.markDegraded(error, true);
      }
      throw error;
    } finally {
      release();
    }
  }

  private prune(next: PersistedInputDeliveryStore, protectedKey: string): void {
    this.pruneExpiredTerminals(next);
    const removable = () =>
      next.records
        .filter(
          (record) =>
            isTerminal(record.state) &&
            inputDeliveryKey(record) !== protectedKey,
        )
        .sort((left, right) => left.updatedAt.localeCompare(right.updatedAt));
    while (next.records.length > this.maxRecords) {
      const candidate = removable()[0];
      if (!candidate) {
        throw new InputDeliveryLedgerError(
          "capacity",
          "The durable input delivery ledger is full.",
        );
      }
      next.records = next.records.filter(
        (record) => inputDeliveryKey(record) !== inputDeliveryKey(candidate),
      );
    }
    while (serializedBytes(next) > this.maxStoreBytes) {
      const candidate = removable()[0];
      if (!candidate) {
        throw new InputDeliveryLedgerError(
          "capacity",
          "The durable input delivery ledger exceeds its byte limit.",
        );
      }
      next.records = next.records.filter(
        (record) => inputDeliveryKey(record) !== inputDeliveryKey(candidate),
      );
    }
  }

  private pruneExpiredTerminals(next: PersistedInputDeliveryStore): void {
    const cutoff = this.now().getTime() - this.terminalRetentionMs;
    next.records = next.records.filter((record) => {
      if (!isTerminal(record.state)) return true;
      const updatedAt = Date.parse(record.updatedAt);
      return !Number.isFinite(updatedAt) || updatedAt >= cutoff;
    });
  }

  private async save(
    data: PersistedInputDeliveryStore,
  ): Promise<{ postPublishError?: unknown }> {
    const directory = dirname(this.filePath);
    await mkdir(directory, { recursive: true, mode: 0o700 });
    const serialized = `${JSON.stringify(data)}\n`;
    if (Buffer.byteLength(serialized, "utf8") > this.maxStoreBytes) {
      throw new InputDeliveryLedgerError(
        "capacity",
        "The durable input delivery ledger exceeds its byte limit.",
      );
    }
    const temporary = `${this.filePath}.${process.pid}.${randomUUID()}.tmp`;
    let handle: Awaited<ReturnType<typeof open>> | undefined;
    let postPublishError: unknown;
    try {
      handle = await open(
        temporary,
        fsConstants.O_WRONLY |
          fsConstants.O_CREAT |
          fsConstants.O_EXCL |
          (process.platform === "win32" ? 0 : fsConstants.O_NOFOLLOW),
        0o600,
      );
      await handle.writeFile(serialized, "utf8");
      await handle.sync();
      await handle.close();
      handle = undefined;
      await rename(temporary, this.filePath);
      try {
        await this.hardenPublishedStore(directory);
      } catch (error) {
        postPublishError = error;
      }
    } finally {
      await handle?.close().catch(() => undefined);
      await rm(temporary, { force: true }).catch(() => undefined);
    }
    return postPublishError === undefined ? {} : { postPublishError };
  }

  /** Post-publication seam used by deterministic durability-failure tests. */
  protected async hardenPublishedStore(directory: string): Promise<void> {
    const published = await lstat(this.filePath);
    if (!published.isFile() || published.isSymbolicLink()) {
      throw new Error("Input delivery ledger publication was unsafe");
    }
    await chmod(this.filePath, 0o600);
    await fsyncDirectory(directory);
  }

  private refreshHealth(degraded: boolean): void {
    this.healthState = {
      initialized: true,
      ready: !degraded,
      degraded,
      revision: this.data.revision,
      recordCount: this.data.records.length,
      activeCount: this.data.records.filter(
        (record) => !isTerminal(record.state),
      ).length,
    };
  }

  private markDegraded(error: unknown, initialized: boolean): void {
    this.healthState = {
      initialized,
      ready: false,
      degraded: true,
      revision: this.data.revision,
      recordCount: this.data.records.length,
      activeCount: this.data.records.filter(
        (record) => !isTerminal(record.state),
      ).length,
      lastFailureAt: this.now().toISOString(),
      lastError: error instanceof Error ? error.name : "UnknownError",
    };
  }
}

function emptyStore(): PersistedInputDeliveryStore {
  return {
    version: STORE_VERSION,
    revision: 0,
    records: [],
    clientIdCapabilities: [],
  };
}

function cloneStore(
  store: PersistedInputDeliveryStore,
): PersistedInputDeliveryStore {
  return {
    version: STORE_VERSION,
    revision: store.revision,
    records: store.records.map(cloneRecord),
    clientIdCapabilities: store.clientIdCapabilities.map((record) => ({
      ...record,
    })),
  };
}

function cloneRecord(
  record: DurableInputDeliveryRecord,
): DurableInputDeliveryRecord {
  return {
    ...record,
    ...(record.payload ? { payload: clonePayload(record.payload) } : {}),
  };
}

function clonePayload(payload: DurableInputPayload): DurableInputPayload {
  return {
    ...payload,
    ...(payload.skills
      ? { skills: payload.skills.map((entry) => ({ ...entry })) }
      : {}),
    ...(payload.mentions
      ? { mentions: payload.mentions.map((entry) => ({ ...entry })) }
      : {}),
  };
}

function parseStore(
  value: unknown,
  maxRecords: number,
  maxPayloadBytes: number,
): PersistedInputDeliveryStore {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Input delivery ledger is malformed");
  }
  const raw = value as Record<string, unknown>;
  if (
    raw.version !== STORE_VERSION ||
    !Number.isSafeInteger(raw.revision) ||
    (raw.revision as number) < 0 ||
    !Array.isArray(raw.records) ||
    !Array.isArray(raw.clientIdCapabilities) ||
    raw.records.length > maxRecords
  ) {
    throw new Error("Input delivery ledger schema is invalid");
  }
  const records = raw.records.map((entry) =>
    normalizePersistedRecord(entry, maxPayloadBytes),
  );
  const keys = new Set<string>();
  const activeQueues = new Set<string>();
  for (const record of records) {
    const key = inputDeliveryKey(record);
    if (keys.has(key))
      throw new Error("Input delivery ledger has duplicate ids");
    keys.add(key);
    if (
      record.queued &&
      (record.state === "queued" || record.state === "provider_dispatching")
    ) {
      const thread = threadKey(record);
      if (activeQueues.has(thread)) {
        throw new Error("Input delivery ledger has multiple active queues");
      }
      activeQueues.add(thread);
    }
  }
  const clientIdCapabilities =
    raw.clientIdCapabilities.map(normalizeCapability);
  return {
    version: STORE_VERSION,
    revision: raw.revision as number,
    records,
    clientIdCapabilities,
  };
}

function normalizePersistedRecord(
  value: unknown,
  maxPayloadBytes: number,
): DurableInputDeliveryRecord {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Input delivery record is malformed");
  }
  const raw = value as Record<string, unknown>;
  const state = normalizeState(raw.state);
  const payload =
    raw.payload === undefined
      ? undefined
      : normalizePayload(raw.payload as DurableInputPayload, maxPayloadBytes);
  if ((state === "queued" || state === "provider_dispatching") && !payload) {
    throw new Error("Active input delivery record is missing its payload");
  }
  const replaySafety = raw.replaySafety;
  if (
    replaySafety !== "queue_exact" &&
    replaySafety !== "client_message_id" &&
    replaySafety !== "none"
  ) {
    throw new Error("Input delivery replay safety is invalid");
  }
  const queued = raw.queued === true;
  const containsImages = raw.containsImages === true;
  const method =
    raw.method === undefined ? undefined : normalizeMethod(raw.method);
  if (state === "queued" && !queued) {
    throw new Error("Queued input delivery record is inconsistent");
  }
  if (queued && containsImages) {
    throw new Error("Queued image delivery record is unsafe");
  }
  if (state === "provider_dispatching" && !method) {
    throw new Error("Dispatching input delivery record has no method");
  }
  if (replaySafety === "queue_exact" && state !== "queued") {
    throw new Error("Exact queue replay marker is inconsistent");
  }
  if (
    replaySafety === "client_message_id" &&
    (state !== "provider_dispatching" ||
      method !== "turn/start" ||
      containsImages)
  ) {
    throw new Error("Idempotent replay marker is inconsistent");
  }
  return {
    ...normalizeIdentity(raw as unknown as InputDeliveryIdentity),
    state,
    acceptedSeq: normalizeSequence(raw.acceptedSeq),
    queued,
    ...(payload ? { payload } : {}),
    containsImages,
    ...(method ? { method } : {}),
    replaySafety,
    ...(typeof raw.clientUserMessageIdAccepted === "boolean"
      ? { clientUserMessageIdAccepted: raw.clientUserMessageIdAccepted }
      : {}),
    occurredAt: normalizeIso(raw.occurredAt),
    updatedAt: normalizeIso(raw.updatedAt),
    ...(typeof raw.errorCode === "string"
      ? { errorCode: normalizeBoundedText(raw.errorCode, 128, "error code") }
      : {}),
    ...(typeof raw.error === "string"
      ? { error: normalizeOptionalError(raw.error) }
      : {}),
    revision: normalizeSequence(raw.revision),
  };
}

function normalizeCapability(value: unknown): ClientIdCapabilityRecord {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Input delivery capability record is malformed");
  }
  const raw = value as Record<string, unknown>;
  return {
    ...normalizeScope(raw as unknown as InputDeliveryScope),
    method: normalizeMethod(raw.method),
    supported: raw.supported === true,
    observedAt: normalizeIso(raw.observedAt),
  };
}

function normalizeScope(scope: InputDeliveryScope): InputDeliveryScope {
  return {
    bridgeInstanceId: normalizeSourceId(scope.bridgeInstanceId, "Bridge"),
    codexSourceId: normalizeSourceId(scope.codexSourceId, "Codex source"),
  };
}

function normalizeIdentity(
  identity: InputDeliveryIdentity,
): InputDeliveryIdentity {
  return {
    ...normalizeScope(identity),
    providerThreadId: normalizeId(identity.providerThreadId, "provider thread"),
    clientMessageId: normalizeId(identity.clientMessageId, "client message"),
  };
}

function normalizePayload(
  payload: DurableInputPayload,
  maxPayloadBytes: number,
): DurableInputPayload {
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    throw new InputDeliveryLedgerError(
      "unsafe_payload",
      "The durable input payload is invalid.",
    );
  }
  const normalized: DurableInputPayload = {
    itemId: normalizeId(payload.itemId, "queued item"),
    text: normalizeBoundedText(
      payload.text,
      Math.max(MAX_TEXT_FIELD_LENGTH, maxPayloadBytes),
      "input text",
      true,
    ),
    createdAt: normalizeIso(payload.createdAt),
    ...(payload.updatedAt
      ? { updatedAt: normalizeIso(payload.updatedAt) }
      : {}),
    ...(payload.userMessageUuid
      ? {
          userMessageUuid: normalizeId(payload.userMessageUuid, "user message"),
        }
      : {}),
    ...(payload.skills
      ? { skills: normalizeRefs(payload.skills, "skill") }
      : {}),
    ...(payload.mentions
      ? { mentions: normalizeRefs(payload.mentions, "mention") }
      : {}),
  };
  if (Buffer.byteLength(JSON.stringify(normalized), "utf8") > maxPayloadBytes) {
    throw new InputDeliveryLedgerError(
      "payload_too_large",
      "The input is too large for durable Bridge delivery.",
    );
  }
  return normalized;
}

function normalizeRefs(
  values: Array<{ name: string; path: string }>,
  label: string,
): Array<{ name: string; path: string }> {
  if (!Array.isArray(values) || values.length > MAX_STRUCTURED_REFS) {
    throw new InputDeliveryLedgerError(
      "unsafe_payload",
      `The durable ${label} list is invalid.`,
    );
  }
  return values.map((entry) => ({
    name: normalizeBoundedText(entry?.name, 1_024, `${label} name`),
    path: normalizeBoundedText(
      entry?.path,
      MAX_TEXT_FIELD_LENGTH,
      `${label} path`,
    ),
  }));
}

function normalizeState(value: unknown): DurableInputDeliveryState {
  switch (value) {
    case "queued":
    case "provider_dispatching":
    case "provider_accepted":
    case "provider_rejected":
    case "outcome_unknown":
    case "cancelled":
      return value;
    default:
      throw new Error("Input delivery state is invalid");
  }
}

function normalizeProviderStage(
  value: unknown,
): "provider_accepted" | "provider_rejected" {
  if (value === "provider_accepted" || value === "provider_rejected") {
    return value;
  }
  throw new Error("Provider input delivery stage is invalid");
}

function normalizeMethod(value: unknown): DurableInputDeliveryMethod {
  if (value === "turn/start" || value === "turn/steer") return value;
  throw new Error("Provider input delivery method is invalid");
}

function normalizeSourceId(value: unknown, label: string): string {
  return normalizeBoundedText(value, MAX_SOURCE_ID_LENGTH, `${label} identity`);
}

function normalizeId(value: unknown, label: string): string {
  return normalizeBoundedText(value, MAX_ID_LENGTH, `${label} id`);
}

function normalizeBoundedText(
  value: unknown,
  maxLength: number,
  label: string,
  allowEmpty = false,
): string {
  if (typeof value !== "string") throw new Error(`${label} is invalid`);
  const normalized = allowEmpty ? value : value.trim();
  if ((!allowEmpty && !normalized) || normalized.length > maxLength) {
    throw new Error(`${label} is invalid`);
  }
  return normalized;
}

function normalizeOptionalError(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const normalized = value.trim();
  return normalized ? normalized.slice(0, 1_024) : undefined;
}

function normalizeIso(value: unknown): string {
  if (typeof value !== "string" || !Number.isFinite(Date.parse(value))) {
    throw new Error("Input delivery timestamp is invalid");
  }
  return new Date(value).toISOString();
}

function normalizeSequence(value: unknown): number {
  if (!Number.isSafeInteger(value) || (value as number) < 0) {
    throw new Error("Input delivery sequence is invalid");
  }
  return value as number;
}

function positiveInteger(
  value: number | undefined,
  fallback: number,
  label: string,
): number {
  const candidate = value ?? fallback;
  if (!Number.isSafeInteger(candidate) || candidate < 1) {
    throw new Error(`Input delivery ${label} is invalid`);
  }
  return candidate;
}

function nonNegativeInteger(
  value: number | undefined,
  fallback: number,
  label: string,
): number {
  const candidate = value ?? fallback;
  if (!Number.isSafeInteger(candidate) || candidate < 0) {
    throw new Error(`Input delivery ${label} is invalid`);
  }
  return candidate;
}

function inputDeliveryKey(identity: InputDeliveryIdentity): string {
  return [
    identity.bridgeInstanceId,
    identity.codexSourceId,
    identity.providerThreadId,
    identity.clientMessageId,
  ].join("\u0000");
}

function threadKey(
  identity: Omit<InputDeliveryIdentity, "clientMessageId">,
): string {
  return [
    identity.bridgeInstanceId,
    identity.codexSourceId,
    identity.providerThreadId,
  ].join("\u0000");
}

function sameThread(
  left: InputDeliveryIdentity,
  right: InputDeliveryIdentity,
): boolean {
  return threadKey(left) === threadKey(right);
}

function sameAdmission(
  record: DurableInputDeliveryRecord,
  queued: boolean,
  payload: DurableInputPayload,
  containsImages: boolean,
): boolean {
  return (
    record.queued === queued &&
    record.containsImages === containsImages &&
    record.payload !== undefined &&
    JSON.stringify(record.payload) === JSON.stringify(payload)
  );
}

function requireMutableRecord(
  store: PersistedInputDeliveryStore,
  identity: InputDeliveryIdentity,
): DurableInputDeliveryRecord {
  const key = inputDeliveryKey(identity);
  const record = store.records.find(
    (candidate) => inputDeliveryKey(candidate) === key,
  );
  if (!record) {
    throw new InputDeliveryLedgerError(
      "record_missing",
      "The durable input delivery record is missing.",
    );
  }
  return record;
}

function capabilityFor(
  store: PersistedInputDeliveryStore,
  scope: InputDeliveryScope,
  method: DurableInputDeliveryMethod,
): boolean | undefined {
  return store.clientIdCapabilities.find(
    (candidate) =>
      candidate.bridgeInstanceId === scope.bridgeInstanceId &&
      candidate.codexSourceId === scope.codexSourceId &&
      candidate.method === method,
  )?.supported;
}

function setCapability(
  store: PersistedInputDeliveryStore,
  scope: InputDeliveryScope,
  method: DurableInputDeliveryMethod,
  supported: boolean,
  observedAt: string,
): void {
  const index = store.clientIdCapabilities.findIndex(
    (candidate) =>
      candidate.bridgeInstanceId === scope.bridgeInstanceId &&
      candidate.codexSourceId === scope.codexSourceId &&
      candidate.method === method,
  );
  const record: ClientIdCapabilityRecord = {
    ...normalizeScope(scope),
    method,
    supported,
    observedAt,
  };
  if (index >= 0) store.clientIdCapabilities[index] = record;
  else store.clientIdCapabilities.push(record);
}

function isProviderTerminal(state: DurableInputDeliveryState): boolean {
  return state === "provider_accepted" || state === "provider_rejected";
}

function isTerminal(state: DurableInputDeliveryState): boolean {
  return (
    isProviderTerminal(state) ||
    state === "outcome_unknown" ||
    state === "cancelled"
  );
}

function serializedBytes(store: PersistedInputDeliveryStore): number {
  return Buffer.byteLength(JSON.stringify(store), "utf8") + 1;
}

async function fsyncDirectory(directory: string): Promise<void> {
  if (process.platform === "win32") return;
  let handle: Awaited<ReturnType<typeof open>> | undefined;
  try {
    handle = await open(directory, fsConstants.O_RDONLY);
    await handle.sync();
  } finally {
    await handle?.close().catch(() => undefined);
  }
}
