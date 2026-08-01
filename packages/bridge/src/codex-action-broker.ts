import { createHash, randomUUID, timingSafeEqual } from "node:crypto";
import { constants as fsConstants } from "node:fs";
import { chmod, lstat, mkdir, open, rename, rm } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";

const STORE_VERSION = 1;
const DEFAULT_REQUEST_TTL_MS = 24 * 60 * 60 * 1_000;
const MAX_REQUEST_TTL_MS = 7 * 24 * 60 * 60 * 1_000;
const DEFAULT_TERMINAL_RETENTION_MS = 7 * 24 * 60 * 60 * 1_000;
const DEFAULT_MAX_RECORDS = 4_096;
const MAX_RECORDS_LIMIT = 16_384;
const MAX_STORE_BYTES = 8 * 1024 * 1024;
const MAX_SOURCE_ID_LENGTH = 128;
const MAX_OPAQUE_ID_LENGTH = 256;
const MAX_METHOD_LENGTH = 192;
const MAX_OPERATION_ID_LENGTH = 256;
const DEFAULT_BRIDGE_PORT = 8765;
const DEFAULT_STORE_FILE = join(
  homedir(),
  ".ccpocket",
  "codex-action-broker-v1.json",
);

export type CodexActionRequestId = string | number;

/**
 * Canonical request identity. The JSON-RPC request-id type is significant:
 * numeric `7` and string `"7"` are deliberately different requests.
 */
export interface CodexActionRequestIdentity {
  codexSourceId: string;
  threadId: string;
  turnId: string;
  requestId: CodexActionRequestId;
  generation: number;
}

export type CodexActionRequestKind =
  | "command_approval"
  | "file_approval"
  | "permissions_approval"
  | "user_input"
  | "mcp_elicitation"
  | "tool_suggestion"
  | "current_time"
  | "unknown";

export type CodexActionRequestState =
  "pending" | "claimed" | "resolved" | "expired";

export type CodexActionResolutionOutcome =
  | "accepted"
  | "accepted_for_session"
  | "declined"
  | "cancelled"
  | "answered"
  | "resolved_elsewhere"
  | "unsupported"
  | "failed"
  | "unknown";

export type CodexActionExpirationReason =
  "deadline" | "generation_superseded" | "operator";

export interface CodexActionRequestClaim {
  claimantFingerprint: string;
  operationFingerprint: string;
  claimToken: string;
  claimedAt: string;
  submittingAt?: string;
  submittedAt?: string;
}

export interface CodexActionRequestResolution {
  resolutionFingerprint: string;
  authority: "claimant" | "app_server";
  outcome: CodexActionResolutionOutcome;
  resolvedAt: string;
}

export interface CodexActionRequestExpiration {
  reason: CodexActionExpirationReason;
  expiredAt: string;
}

/**
 * Trusted Bridge-internal record. It intentionally contains no request body,
 * command, path, prompt, question, answer, or tool payload. Those remain on
 * the live attachment and are never accepted by this persistence API.
 */
export interface CodexActionRequestRecord {
  identity: CodexActionRequestIdentity;
  opaqueRequestId: string;
  method: string;
  kind: CodexActionRequestKind;
  state: CodexActionRequestState;
  observedAt: string;
  expiresAt: string;
  updatedAt: string;
  claim?: CodexActionRequestClaim;
  resolution?: CodexActionRequestResolution;
  expiration?: CodexActionRequestExpiration;
}

/** Safe to expose to protocol/UI code; canonical source/request IDs stay local. */
export interface CodexActionPublicRequest {
  opaqueRequestId: string;
  kind: CodexActionRequestKind;
  state: CodexActionRequestState;
  observedAt: string;
  expiresAt: string;
  updatedAt: string;
}

export interface CodexActionBrokerHealth {
  ready: boolean;
  degraded: boolean;
  degradedReason?: "unreadable_state" | "unsafe_state";
  revision: number;
  pendingCount: number;
  claimedCount: number;
  resolvedCount: number;
  expiredCount: number;
}

export interface CodexActionBrokerOptions {
  filePath?: string;
  /** Used only to isolate the default path; an explicit filePath wins. */
  port?: number | string;
  now?: () => Date;
  randomToken?: () => string;
  defaultRequestTtlMs?: number;
  maxRequestTtlMs?: number;
  terminalRetentionMs?: number;
  maxRecords?: number;
}

export interface ObserveCodexActionRequest {
  identity: CodexActionRequestIdentity;
  method: string;
  kind: CodexActionRequestKind;
  observedAt?: string;
  expiresAt?: string;
}

export type ObserveCodexActionResult =
  | {
      outcome: "created" | "existing";
      request: CodexActionPublicRequest;
    }
  | {
      outcome: "stale_generation";
      currentGeneration: number;
    };

export interface ClaimCodexActionRequest {
  claimantId: string;
  operationId: string;
}

export type ClaimCodexActionResult =
  | {
      outcome: "claimed" | "idempotent";
      request: CodexActionPublicRequest;
      claimToken: string;
    }
  | {
      outcome: "contended" | "resolved" | "expired" | "missing";
      request?: CodexActionPublicRequest;
    }
  | {
      outcome: "stale_generation";
      currentGeneration: number;
    };

export interface MarkCodexActionSubmittedRequest {
  operationId: string;
  claimToken: string;
  submittedAt?: string;
}

export type MarkCodexActionSubmittingResult =
  | {
      outcome: "submitting" | "idempotent";
      request: CodexActionPublicRequest;
    }
  | {
      outcome:
        "expired" | "resolved" | "missing" | "not_claimed" | "claim_mismatch";
      request?: CodexActionPublicRequest;
    }
  | {
      outcome: "stale_generation";
      currentGeneration: number;
    };

export type MarkCodexActionSubmittedResult =
  | {
      outcome: "submitted" | "idempotent";
      request: CodexActionPublicRequest;
    }
  | {
      outcome:
        | "expired"
        | "resolved"
        | "missing"
        | "not_claimed"
        | "not_submitting"
        | "claim_mismatch";
      request?: CodexActionPublicRequest;
    }
  | {
      outcome: "stale_generation";
      currentGeneration: number;
    };

export interface ResolveCodexActionRequest {
  authority: "claimant" | "app_server";
  resolutionId: string;
  outcome: CodexActionResolutionOutcome;
  claimToken?: string;
  /** Needed when an app-server terminal event arrives before its request. */
  resolvedAt?: string;
}

export type ResolveCodexActionResult =
  | {
      outcome: "resolved" | "idempotent" | "already_resolved";
      request: CodexActionPublicRequest;
    }
  | {
      outcome: "expired" | "missing" | "not_claimed" | "claim_mismatch";
      request?: CodexActionPublicRequest;
    }
  | {
      outcome: "stale_generation";
      currentGeneration: number;
    };

export type ExpireCodexActionResult =
  | {
      outcome: "expired" | "already_terminal" | "missing";
      request?: CodexActionPublicRequest;
    }
  | {
      outcome: "stale_generation";
      currentGeneration: number;
    };

interface PersistedCodexActionBrokerFile {
  version: typeof STORE_VERSION;
  revision: number;
  currentGenerations: Array<{
    codexSourceId: string;
    generation: number;
  }>;
  requests: CodexActionRequestRecord[];
}

interface MutableBrokerState {
  records: Map<string, CodexActionRequestRecord>;
  generations: Map<string, number>;
}

export class CodexActionBrokerDegradedError extends Error {
  constructor(public readonly reason: "unreadable_state" | "unsafe_state") {
    super(
      "Codex Action Broker state is degraded; pending requests remain fail-closed",
    );
    this.name = "CodexActionBrokerDegradedError";
  }
}

/**
 * Durable single-writer request ledger for the future shared-runtime Action
 * Broker. The external coordinator remains responsible for granting exactly
 * one Bridge writer generation; this class provides atomic in-process claim
 * serialization, durable idempotency, restart recovery, and generation fences.
 */
export class CodexActionBroker {
  readonly filePath: string;

  private readonly now: () => Date;
  private readonly randomToken: () => string;
  private readonly defaultRequestTtlMs: number;
  private readonly maxRequestTtlMs: number;
  private readonly terminalRetentionMs: number;
  private readonly maxRecords: number;
  private records = new Map<string, CodexActionRequestRecord>();
  private currentGenerations = new Map<string, number>();
  private revision = 0;
  private mutationTail: Promise<void> = Promise.resolve();
  private loadPromise: Promise<void> | undefined;
  private degradedReason: "unreadable_state" | "unsafe_state" | undefined;

  constructor(options: CodexActionBrokerOptions = {}) {
    this.filePath = options.filePath ?? defaultActionBrokerPath(options.port);
    this.now = options.now ?? (() => new Date());
    this.randomToken = options.randomToken ?? randomUUID;
    this.defaultRequestTtlMs = boundedDuration(
      options.defaultRequestTtlMs,
      DEFAULT_REQUEST_TTL_MS,
      "default request TTL",
    );
    this.maxRequestTtlMs = boundedDuration(
      options.maxRequestTtlMs,
      MAX_REQUEST_TTL_MS,
      "maximum request TTL",
    );
    if (this.defaultRequestTtlMs > this.maxRequestTtlMs) {
      throw new Error(
        "Codex Action Broker default request TTL exceeds its maximum",
      );
    }
    this.terminalRetentionMs = boundedDuration(
      options.terminalRetentionMs,
      DEFAULT_TERMINAL_RETENTION_MS,
      "terminal retention",
    );
    this.maxRecords = boundedRecordLimit(options.maxRecords);
  }

  async ready(): Promise<CodexActionBrokerHealth> {
    await this.ensureLoaded();
    if (!this.degradedReason) await this.expireDue();
    return this.health();
  }

  async health(): Promise<CodexActionBrokerHealth> {
    await this.ensureLoaded();
    await this.mutationTail;
    const counts: Record<CodexActionRequestState, number> = {
      pending: 0,
      claimed: 0,
      resolved: 0,
      expired: 0,
    };
    for (const record of this.records.values()) counts[record.state] += 1;
    return {
      ready: true,
      degraded: this.degradedReason !== undefined,
      ...(this.degradedReason ? { degradedReason: this.degradedReason } : {}),
      revision: this.revision,
      pendingCount: counts.pending,
      claimedCount: counts.claimed,
      resolvedCount: counts.resolved,
      expiredCount: counts.expired,
    };
  }

  /**
   * Re-read the canonical ledger after a cross-process writer lease is won.
   * Standby runtimes may have loaded an older read-only snapshot; they must not
   * mutate from that snapshot during handoff.
   */
  async reloadFromDisk(): Promise<CodexActionBrokerHealth> {
    await this.mutationTail;
    this.loadPromise = undefined;
    this.records = new Map();
    this.currentGenerations = new Map();
    this.revision = 0;
    this.degradedReason = undefined;
    await this.ensureLoaded();
    return this.health();
  }

  async observePending(
    input: ObserveCodexActionRequest,
  ): Promise<ObserveCodexActionResult> {
    const normalized = normalizeObservation(
      input,
      this.now(),
      this.defaultRequestTtlMs,
      this.maxRequestTtlMs,
    );
    return this.serializeMutation(async () => {
      await this.ensureLoaded();
      this.assertWritable();
      const next = this.mutableClone();
      const now = this.now();
      let changed = expireDueInState(next.records, now);
      const generation = advanceGenerationInState(
        next,
        normalized.identity.codexSourceId,
        normalized.identity.generation,
        now,
      );
      if (generation.outcome === "stale_generation") {
        if (changed) await this.persistAndCommit(next);
        return generation;
      }
      changed ||= generation.changed;

      const key = requestIdentityKey(normalized.identity);
      const existing = next.records.get(key);
      if (existing) {
        if (
          (existing.state === "pending" || existing.state === "claimed") &&
          (existing.method !== normalized.method ||
            existing.kind !== normalized.kind)
        ) {
          throw new Error(
            "Codex Action Broker request identity was reused with different metadata",
          );
        }
        if (changed) await this.persistAndCommit(next);
        return { outcome: "existing", request: publicRequest(existing) };
      }

      pruneTerminalRecords(
        next.records,
        now.getTime() - this.terminalRetentionMs,
      );
      if (next.records.size >= this.maxRecords) {
        throw new Error("Codex Action Broker request limit reached");
      }
      const record: CodexActionRequestRecord = {
        identity: cloneIdentity(normalized.identity),
        opaqueRequestId: opaqueRequestId(normalized.identity),
        method: normalized.method,
        kind: normalized.kind,
        state: "pending",
        observedAt: normalized.observedAt,
        expiresAt: normalized.expiresAt,
        updatedAt: normalized.observedAt,
      };
      next.records.set(key, record);
      await this.persistAndCommit(next);
      return { outcome: "created", request: publicRequest(record) };
    });
  }

  async claim(
    identityInput: CodexActionRequestIdentity,
    input: ClaimCodexActionRequest,
  ): Promise<ClaimCodexActionResult> {
    const identity = normalizeIdentity(identityInput);
    const claimantFingerprint = privateFingerprint(
      requireOpaqueOperation(input.claimantId, "claimant ID"),
    );
    const operationFingerprint = privateFingerprint(
      requireOpaqueOperation(input.operationId, "claim operation ID"),
    );
    return this.serializeMutation(async () => {
      await this.ensureLoaded();
      this.assertWritable();
      const next = this.mutableClone();
      const now = this.now();
      const changed = expireDueInState(next.records, now);
      const stale = staleGenerationResult(next, identity);
      if (stale) {
        if (changed) await this.persistAndCommit(next);
        return stale;
      }
      const record = next.records.get(requestIdentityKey(identity));
      if (!record) {
        if (changed) await this.persistAndCommit(next);
        return { outcome: "missing" };
      }
      if (record.state === "resolved" || record.state === "expired") {
        if (changed) await this.persistAndCommit(next);
        return {
          outcome: record.state,
          request: publicRequest(record),
        };
      }
      if (record.state === "claimed") {
        if (
          record.claim?.claimantFingerprint === claimantFingerprint &&
          record.claim.operationFingerprint === operationFingerprint
        ) {
          if (changed) await this.persistAndCommit(next);
          return {
            outcome: "idempotent",
            request: publicRequest(record),
            claimToken: record.claim.claimToken,
          };
        }
        if (changed) await this.persistAndCommit(next);
        return { outcome: "contended", request: publicRequest(record) };
      }

      const claimedAt = now.toISOString();
      record.state = "claimed";
      record.updatedAt = claimedAt;
      record.claim = {
        claimantFingerprint,
        operationFingerprint,
        claimToken: requireGeneratedToken(this.randomToken()),
        claimedAt,
      };
      await this.persistAndCommit(next);
      return {
        outcome: "claimed",
        request: publicRequest(record),
        claimToken: record.claim.claimToken,
      };
    });
  }

  async markSubmitted(
    identityInput: CodexActionRequestIdentity,
    input: MarkCodexActionSubmittedRequest,
  ): Promise<MarkCodexActionSubmittedResult> {
    const identity = normalizeIdentity(identityInput);
    const operationFingerprint = privateFingerprint(
      requireOpaqueOperation(input.operationId, "claim operation ID"),
    );
    const submittedAt = normalizeTimestamp(
      input.submittedAt ?? this.now().toISOString(),
      "submission timestamp",
    );
    return this.serializeMutation(async () => {
      await this.ensureLoaded();
      this.assertWritable();
      const next = this.mutableClone();
      const now = this.now();
      const changed = expireDueInState(next.records, now);
      const stale = staleGenerationResult(next, identity);
      if (stale) {
        if (changed) await this.persistAndCommit(next);
        return stale;
      }
      const record = next.records.get(requestIdentityKey(identity));
      if (!record) {
        if (changed) await this.persistAndCommit(next);
        return { outcome: "missing" };
      }
      if (record.state === "resolved" || record.state === "expired") {
        if (changed) await this.persistAndCommit(next);
        return { outcome: record.state, request: publicRequest(record) };
      }
      if (record.state !== "claimed" || !record.claim) {
        if (changed) await this.persistAndCommit(next);
        return { outcome: "not_claimed", request: publicRequest(record) };
      }
      if (
        record.claim.operationFingerprint !== operationFingerprint ||
        !claimTokensEqual(record.claim.claimToken, input.claimToken)
      ) {
        if (changed) await this.persistAndCommit(next);
        return { outcome: "claim_mismatch", request: publicRequest(record) };
      }
      if (!record.claim.submittingAt) {
        if (changed) await this.persistAndCommit(next);
        return { outcome: "not_submitting", request: publicRequest(record) };
      }
      if (record.claim.submittedAt) {
        if (changed) await this.persistAndCommit(next);
        return { outcome: "idempotent", request: publicRequest(record) };
      }
      record.claim.submittedAt = submittedAt;
      record.updatedAt = submittedAt;
      await this.persistAndCommit(next);
      return { outcome: "submitted", request: publicRequest(record) };
    });
  }

  async markSubmitting(
    identityInput: CodexActionRequestIdentity,
    input: MarkCodexActionSubmittedRequest,
  ): Promise<MarkCodexActionSubmittingResult> {
    const identity = normalizeIdentity(identityInput);
    const operationFingerprint = privateFingerprint(
      requireOpaqueOperation(input.operationId, "claim operation ID"),
    );
    const submittingAt = normalizeTimestamp(
      input.submittedAt ?? this.now().toISOString(),
      "submission intent timestamp",
    );
    return this.serializeMutation(async () => {
      await this.ensureLoaded();
      this.assertWritable();
      const next = this.mutableClone();
      const now = this.now();
      const changed = expireDueInState(next.records, now);
      const stale = staleGenerationResult(next, identity);
      if (stale) {
        if (changed) await this.persistAndCommit(next);
        return stale;
      }
      const record = next.records.get(requestIdentityKey(identity));
      if (!record) {
        if (changed) await this.persistAndCommit(next);
        return { outcome: "missing" };
      }
      if (record.state === "resolved" || record.state === "expired") {
        if (changed) await this.persistAndCommit(next);
        return { outcome: record.state, request: publicRequest(record) };
      }
      if (record.state !== "claimed" || !record.claim) {
        if (changed) await this.persistAndCommit(next);
        return { outcome: "not_claimed", request: publicRequest(record) };
      }
      if (
        record.claim.operationFingerprint !== operationFingerprint ||
        !claimTokensEqual(record.claim.claimToken, input.claimToken)
      ) {
        if (changed) await this.persistAndCommit(next);
        return { outcome: "claim_mismatch", request: publicRequest(record) };
      }
      if (record.claim.submittingAt) {
        if (changed) await this.persistAndCommit(next);
        return { outcome: "idempotent", request: publicRequest(record) };
      }
      record.claim.submittingAt = submittingAt;
      record.updatedAt = submittingAt;
      await this.persistAndCommit(next);
      return { outcome: "submitting", request: publicRequest(record) };
    });
  }

  async releaseUnsubmittedClaim(
    identityInput: CodexActionRequestIdentity,
    input: MarkCodexActionSubmittedRequest,
  ): Promise<boolean> {
    const identity = normalizeIdentity(identityInput);
    const operationFingerprint = privateFingerprint(
      requireOpaqueOperation(input.operationId, "claim operation ID"),
    );
    return this.serializeMutation(async () => {
      await this.ensureLoaded();
      this.assertWritable();
      const next = this.mutableClone();
      const record = next.records.get(requestIdentityKey(identity));
      if (
        !record ||
        record.state !== "claimed" ||
        !record.claim ||
        record.claim.submittedAt ||
        record.claim.operationFingerprint !== operationFingerprint ||
        !claimTokensEqual(record.claim.claimToken, input.claimToken)
      ) {
        return false;
      }
      record.state = "pending";
      record.updatedAt = this.now().toISOString();
      delete record.claim;
      await this.persistAndCommit(next);
      return true;
    });
  }

  async resolve(
    identityInput: CodexActionRequestIdentity,
    input: ResolveCodexActionRequest,
  ): Promise<ResolveCodexActionResult> {
    const identity = normalizeIdentity(identityInput);
    const resolutionFingerprint = privateFingerprint(
      requireOpaqueOperation(input.resolutionId, "resolution ID"),
    );
    requireResolutionOutcome(input.outcome);
    if (input.authority !== "claimant" && input.authority !== "app_server") {
      throw new Error("Invalid Codex Action Broker resolution authority");
    }
    const resolvedAt = normalizeTimestamp(
      input.resolvedAt ?? this.now().toISOString(),
      "resolution timestamp",
    );
    return this.serializeMutation(async () => {
      await this.ensureLoaded();
      this.assertWritable();
      const next = this.mutableClone();
      const now = this.now();
      let changed = expireDueInState(next.records, now);
      if (input.authority === "app_server") {
        const generation = advanceGenerationInState(
          next,
          identity.codexSourceId,
          identity.generation,
          now,
        );
        if (generation.outcome === "stale_generation") {
          if (changed) await this.persistAndCommit(next);
          return generation;
        }
        changed ||= generation.changed;
      } else {
        const stale = staleGenerationResult(next, identity);
        if (stale) {
          if (changed) await this.persistAndCommit(next);
          return stale;
        }
      }

      const key = requestIdentityKey(identity);
      let record = next.records.get(key);
      if (!record) {
        if (input.authority !== "app_server") {
          if (changed) await this.persistAndCommit(next);
          return { outcome: "missing" };
        }
        pruneTerminalRecords(
          next.records,
          now.getTime() - this.terminalRetentionMs,
        );
        if (next.records.size >= this.maxRecords) {
          throw new Error("Codex Action Broker request limit reached");
        }
        record = {
          identity: cloneIdentity(identity),
          opaqueRequestId: opaqueRequestId(identity),
          method: "serverRequest/resolved",
          kind: "unknown",
          state: "resolved",
          observedAt: resolvedAt,
          expiresAt: resolvedAt,
          updatedAt: resolvedAt,
          resolution: {
            resolutionFingerprint,
            authority: input.authority,
            outcome: input.outcome,
            resolvedAt,
          },
        };
        next.records.set(key, record);
        await this.persistAndCommit(next);
        return { outcome: "resolved", request: publicRequest(record) };
      }

      if (record.state === "resolved") {
        const idempotent =
          record.resolution?.resolutionFingerprint === resolutionFingerprint &&
          record.resolution.authority === input.authority &&
          record.resolution.outcome === input.outcome;
        if (changed) await this.persistAndCommit(next);
        return {
          outcome: idempotent ? "idempotent" : "already_resolved",
          request: publicRequest(record),
        };
      }
      if (record.state === "expired") {
        if (changed) await this.persistAndCommit(next);
        return { outcome: "expired", request: publicRequest(record) };
      }
      if (input.authority === "claimant") {
        if (record.state !== "claimed" || !record.claim) {
          if (changed) await this.persistAndCommit(next);
          return { outcome: "not_claimed", request: publicRequest(record) };
        }
        if (!claimTokensEqual(record.claim.claimToken, input.claimToken)) {
          if (changed) await this.persistAndCommit(next);
          return { outcome: "claim_mismatch", request: publicRequest(record) };
        }
      }

      record.state = "resolved";
      record.updatedAt = resolvedAt;
      delete record.claim;
      delete record.expiration;
      record.resolution = {
        resolutionFingerprint,
        authority: input.authority,
        outcome: input.outcome,
        resolvedAt,
      };
      await this.persistAndCommit(next);
      return { outcome: "resolved", request: publicRequest(record) };
    });
  }

  async expire(
    identityInput: CodexActionRequestIdentity,
    reason: Exclude<
      CodexActionExpirationReason,
      "generation_superseded"
    > = "operator",
  ): Promise<ExpireCodexActionResult> {
    const identity = normalizeIdentity(identityInput);
    if (reason !== "deadline" && reason !== "operator") {
      throw new Error("Invalid Codex Action Broker expiration reason");
    }
    return this.serializeMutation(async () => {
      await this.ensureLoaded();
      this.assertWritable();
      const next = this.mutableClone();
      const now = this.now();
      const dueChanged = expireDueInState(next.records, now);
      const stale = staleGenerationResult(next, identity);
      if (stale) {
        if (dueChanged) await this.persistAndCommit(next);
        return stale;
      }
      const record = next.records.get(requestIdentityKey(identity));
      if (!record) {
        if (dueChanged) await this.persistAndCommit(next);
        return { outcome: "missing" };
      }
      if (record.state === "resolved" || record.state === "expired") {
        if (dueChanged) await this.persistAndCommit(next);
        return {
          outcome: "already_terminal",
          request: publicRequest(record),
        };
      }
      expireRecord(record, reason, now.toISOString());
      await this.persistAndCommit(next);
      return { outcome: "expired", request: publicRequest(record) };
    });
  }

  async advanceGeneration(
    codexSourceIdInput: string,
    generationInput: number,
  ): Promise<{
    outcome: "advanced" | "unchanged" | "stale_generation";
    currentGeneration: number;
    expiredCount: number;
  }> {
    const codexSourceId = requireOpaqueId(
      codexSourceIdInput,
      MAX_SOURCE_ID_LENGTH,
      "Codex source ID",
    );
    const generation = requireGeneration(generationInput);
    return this.serializeMutation(async () => {
      await this.ensureLoaded();
      this.assertWritable();
      const next = this.mutableClone();
      const current = next.generations.get(codexSourceId);
      if (current !== undefined && generation < current) {
        return {
          outcome: "stale_generation",
          currentGeneration: current,
          expiredCount: 0,
        };
      }
      if (current === generation) {
        return {
          outcome: "unchanged",
          currentGeneration: current,
          expiredCount: 0,
        };
      }
      const now = this.now();
      next.generations.set(codexSourceId, generation);
      let expiredCount = 0;
      for (const record of next.records.values()) {
        if (
          record.identity.codexSourceId === codexSourceId &&
          record.identity.generation < generation &&
          (record.state === "pending" || record.state === "claimed")
        ) {
          expireRecord(record, "generation_superseded", now.toISOString());
          expiredCount += 1;
        }
      }
      await this.persistAndCommit(next);
      return {
        outcome: "advanced",
        currentGeneration: generation,
        expiredCount,
      };
    });
  }

  /**
   * Allocate the next durable broker generation for one Codex source.
   *
   * Host integration must call this once for every newly authoritative
   * control connection and use the returned value for all request identities
   * in that connection. Never persist the transport's process-local
   * `connectionGeneration` directly: it restarts at one after Bridge restart.
   */
  async beginSourceGeneration(codexSourceIdInput: string): Promise<{
    generation: number;
    expiredCount: number;
  }> {
    const codexSourceId = requireOpaqueId(
      codexSourceIdInput,
      MAX_SOURCE_ID_LENGTH,
      "Codex source ID",
    );
    return this.serializeMutation(async () => {
      await this.ensureLoaded();
      this.assertWritable();
      const next = this.mutableClone();
      const previous = next.generations.get(codexSourceId) ?? 0;
      if (previous >= Number.MAX_SAFE_INTEGER) {
        throw new Error("Codex Action Broker generation space is exhausted");
      }
      const generation = previous + 1;
      const now = this.now();
      next.generations.set(codexSourceId, generation);
      let expiredCount = 0;
      for (const record of next.records.values()) {
        if (
          record.identity.codexSourceId === codexSourceId &&
          record.identity.generation < generation &&
          (record.state === "pending" || record.state === "claimed")
        ) {
          expireRecord(record, "generation_superseded", now.toISOString());
          expiredCount += 1;
        }
      }
      await this.persistAndCommit(next);
      return { generation, expiredCount };
    });
  }

  async currentGeneration(
    codexSourceIdInput: string,
  ): Promise<number | undefined> {
    const codexSourceId = requireOpaqueId(
      codexSourceIdInput,
      MAX_SOURCE_ID_LENGTH,
      "Codex source ID",
    );
    await this.ensureLoaded();
    await this.mutationTail;
    return this.currentGenerations.get(codexSourceId);
  }

  async expireDue(): Promise<number> {
    return this.serializeMutation(async () => {
      await this.ensureLoaded();
      this.assertWritable();
      const next = this.mutableClone();
      const before = countState(next.records, "expired");
      const changed = expireDueInState(next.records, this.now());
      if (!changed) return 0;
      const expired = countState(next.records, "expired") - before;
      await this.persistAndCommit(next);
      return expired;
    });
  }

  async get(
    identityInput: CodexActionRequestIdentity,
  ): Promise<CodexActionRequestRecord | undefined> {
    const identity = normalizeIdentity(identityInput);
    await this.ensureLoaded();
    await this.mutationTail;
    if (!this.degradedReason) await this.expireDue();
    const record = this.records.get(requestIdentityKey(identity));
    return record ? cloneRecord(record) : undefined;
  }

  async getByOpaqueId(
    opaqueIdInput: string,
  ): Promise<CodexActionPublicRequest | undefined> {
    const opaqueId = requireOpaqueId(
      opaqueIdInput,
      MAX_OPAQUE_ID_LENGTH,
      "opaque request ID",
    );
    await this.ensureLoaded();
    await this.mutationTail;
    if (!this.degradedReason) await this.expireDue();
    for (const record of this.records.values()) {
      if (record.opaqueRequestId === opaqueId) return publicRequest(record);
    }
    return undefined;
  }

  async list(
    options: {
      codexSourceId?: string;
      threadId?: string;
      includeTerminal?: boolean;
    } = {},
  ): Promise<CodexActionRequestRecord[]> {
    const codexSourceId = options.codexSourceId
      ? requireOpaqueId(
          options.codexSourceId,
          MAX_SOURCE_ID_LENGTH,
          "Codex source ID",
        )
      : undefined;
    const threadId = options.threadId
      ? requireOpaqueId(options.threadId, MAX_OPAQUE_ID_LENGTH, "thread ID")
      : undefined;
    await this.ensureLoaded();
    await this.mutationTail;
    if (!this.degradedReason) await this.expireDue();
    return [...this.records.values()]
      .filter(
        (record) =>
          (!codexSourceId || record.identity.codexSourceId === codexSourceId) &&
          (!threadId || record.identity.threadId === threadId) &&
          (options.includeTerminal === true ||
            record.state === "pending" ||
            record.state === "claimed"),
      )
      .sort(compareRecords)
      .map(cloneRecord);
  }

  /** Read-only snapshot for a standby Bridge; never expires or persists rows. */
  async listReadonly(
    options: {
      codexSourceId?: string;
      threadId?: string;
      includeTerminal?: boolean;
    } = {},
  ): Promise<CodexActionRequestRecord[]> {
    const codexSourceId = options.codexSourceId
      ? requireOpaqueId(
          options.codexSourceId,
          MAX_SOURCE_ID_LENGTH,
          "Codex source ID",
        )
      : undefined;
    const threadId = options.threadId
      ? requireOpaqueId(options.threadId, MAX_OPAQUE_ID_LENGTH, "thread ID")
      : undefined;
    await this.ensureLoaded();
    await this.mutationTail;
    return [...this.records.values()]
      .filter(
        (record) =>
          (!codexSourceId || record.identity.codexSourceId === codexSourceId) &&
          (!threadId || record.identity.threadId === threadId) &&
          (options.includeTerminal === true ||
            record.state === "pending" ||
            record.state === "claimed"),
      )
      .sort(compareRecords)
      .map(cloneRecord);
  }

  private ensureLoaded(): Promise<void> {
    this.loadPromise ??= this.load();
    return this.loadPromise;
  }

  private async load(): Promise<void> {
    let handle: Awaited<ReturnType<typeof open>> | undefined;
    try {
      handle = await open(
        this.filePath,
        fsConstants.O_RDONLY |
          (process.platform === "win32" ? 0 : fsConstants.O_NOFOLLOW),
      );
      const stats = await handle.stat();
      if (
        !stats.isFile() ||
        stats.size > MAX_STORE_BYTES ||
        (!process.platform.startsWith("win") && (stats.mode & 0o077) !== 0)
      ) {
        this.degradedReason = "unsafe_state";
        return;
      }
      const decoded = JSON.parse(
        await readBoundedUtf8(handle, stats.size),
      ) as unknown;
      const state = validatePersistedState(decoded, this.maxRecords);
      this.records = state.records;
      this.currentGenerations = state.generations;
      this.revision = state.revision;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return;
      this.degradedReason = "unreadable_state";
    } finally {
      await handle?.close().catch(() => undefined);
    }
  }

  private assertWritable(): void {
    if (this.degradedReason) {
      throw new CodexActionBrokerDegradedError(this.degradedReason);
    }
  }

  private serializeMutation<T>(operation: () => Promise<T>): Promise<T> {
    const current = this.mutationTail.then(operation);
    this.mutationTail = current.then(
      () => undefined,
      () => undefined,
    );
    return current;
  }

  private mutableClone(): MutableBrokerState {
    return {
      records: new Map(
        [...this.records].map(([key, record]) => [key, cloneRecord(record)]),
      ),
      generations: new Map(this.currentGenerations),
    };
  }

  private async persistAndCommit(next: MutableBrokerState): Promise<void> {
    pruneTerminalRecords(
      next.records,
      this.now().getTime() - this.terminalRetentionMs,
    );
    const nextRevision = this.revision + 1;
    const data: PersistedCodexActionBrokerFile = {
      version: STORE_VERSION,
      revision: nextRevision,
      currentGenerations: [...next.generations]
        .map(([codexSourceId, generation]) => ({
          codexSourceId,
          generation,
        }))
        .sort((left, right) =>
          left.codexSourceId.localeCompare(right.codexSourceId),
        ),
      requests: [...next.records.values()].sort(compareRecords),
    };
    const serialized = `${JSON.stringify(data, null, 2)}\n`;
    if (Buffer.byteLength(serialized, "utf8") > MAX_STORE_BYTES) {
      throw new Error("Codex Action Broker state exceeds its size limit");
    }

    const directory = dirname(this.filePath);
    const temporaryPath = `${this.filePath}.tmp-${process.pid}-${randomUUID()}`;
    await mkdir(directory, { recursive: true, mode: 0o700 });
    await chmod(directory, 0o700).catch(() => undefined);
    let handle: Awaited<ReturnType<typeof open>> | undefined;
    try {
      handle = await open(
        temporaryPath,
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
      await rename(temporaryPath, this.filePath);

      // rename() is the publication point. Once it succeeds, the durable path
      // contains the new revision, so keeping the old in-memory state would let
      // a later mutation overwrite a claim/result that has already been
      // published. Install the new snapshot immediately and fail closed if a
      // post-publication safety or durability check fails.
      this.records = next.records;
      this.currentGenerations = next.generations;
      this.revision = nextRevision;
      try {
        const published = await lstat(this.filePath);
        if (!published.isFile() || published.isSymbolicLink()) {
          throw new Error("Codex Action Broker state publication was unsafe");
        }
        await chmod(this.filePath, 0o600);
        await fsyncDirectory(directory);
      } catch (error) {
        this.degradedReason = "unsafe_state";
        throw error;
      }
    } finally {
      await handle?.close().catch(() => undefined);
      await rm(temporaryPath, { force: true }).catch(() => undefined);
    }
  }
}

function normalizeObservation(
  input: ObserveCodexActionRequest,
  now: Date,
  defaultTtlMs: number,
  maxTtlMs: number,
): Required<ObserveCodexActionRequest> {
  const identity = normalizeIdentity(input.identity);
  const method = requireOpaqueId(input.method, MAX_METHOD_LENGTH, "method");
  requireRequestKind(input.kind);
  const observedAt = normalizeTimestamp(
    input.observedAt ?? now.toISOString(),
    "observation timestamp",
  );
  const observedMs = Date.parse(observedAt);
  const expiresAt = normalizeTimestamp(
    input.expiresAt ?? new Date(observedMs + defaultTtlMs).toISOString(),
    "expiration timestamp",
  );
  const lifetime = Date.parse(expiresAt) - observedMs;
  if (lifetime <= 0 || lifetime > maxTtlMs) {
    throw new Error("Invalid Codex Action Broker request lifetime");
  }
  return { identity, method, kind: input.kind, observedAt, expiresAt };
}

function normalizeIdentity(
  input: CodexActionRequestIdentity,
): CodexActionRequestIdentity {
  return {
    codexSourceId: requireOpaqueId(
      input.codexSourceId,
      MAX_SOURCE_ID_LENGTH,
      "Codex source ID",
    ),
    threadId: requireOpaqueId(
      input.threadId,
      MAX_OPAQUE_ID_LENGTH,
      "thread ID",
    ),
    turnId: requireOpaqueId(input.turnId, MAX_OPAQUE_ID_LENGTH, "turn ID"),
    requestId: requireRequestId(input.requestId),
    generation: requireGeneration(input.generation),
  };
}

function requestIdentityKey(identity: CodexActionRequestIdentity): string {
  return JSON.stringify([
    identity.codexSourceId,
    identity.threadId,
    identity.turnId,
    typeof identity.requestId,
    identity.requestId,
    identity.generation,
  ]);
}

export function opaqueCodexActionRequestId(
  identityInput: CodexActionRequestIdentity,
): string {
  return opaqueRequestId(normalizeIdentity(identityInput));
}

function opaqueRequestId(identity: CodexActionRequestIdentity): string {
  return `cab_${createHash("sha256")
    .update(requestIdentityKey(identity))
    .digest("base64url")}`;
}

function privateFingerprint(value: string): string {
  return createHash("sha256").update(value).digest("base64url");
}

function publicRequest(
  record: CodexActionRequestRecord,
): CodexActionPublicRequest {
  return {
    opaqueRequestId: record.opaqueRequestId,
    kind: record.kind,
    state: record.state,
    observedAt: record.observedAt,
    expiresAt: record.expiresAt,
    updatedAt: record.updatedAt,
  };
}

function cloneIdentity(
  identity: CodexActionRequestIdentity,
): CodexActionRequestIdentity {
  return { ...identity };
}

function cloneRecord(
  record: CodexActionRequestRecord,
): CodexActionRequestRecord {
  return {
    ...record,
    identity: cloneIdentity(record.identity),
    ...(record.claim ? { claim: { ...record.claim } } : {}),
    ...(record.resolution ? { resolution: { ...record.resolution } } : {}),
    ...(record.expiration ? { expiration: { ...record.expiration } } : {}),
  };
}

function compareRecords(
  left: CodexActionRequestRecord,
  right: CodexActionRequestRecord,
): number {
  return (
    left.identity.codexSourceId.localeCompare(right.identity.codexSourceId) ||
    left.identity.threadId.localeCompare(right.identity.threadId) ||
    left.identity.turnId.localeCompare(right.identity.turnId) ||
    left.identity.generation - right.identity.generation ||
    String(left.identity.requestId).localeCompare(
      String(right.identity.requestId),
    ) ||
    (typeof left.identity.requestId).localeCompare(
      typeof right.identity.requestId,
    ) ||
    left.updatedAt.localeCompare(right.updatedAt)
  );
}

function advanceGenerationInState(
  state: MutableBrokerState,
  codexSourceId: string,
  generation: number,
  now: Date,
):
  | { outcome: "current"; currentGeneration: number; changed: boolean }
  | { outcome: "stale_generation"; currentGeneration: number } {
  const current = state.generations.get(codexSourceId);
  if (current !== undefined && generation < current) {
    return { outcome: "stale_generation", currentGeneration: current };
  }
  if (current === generation) {
    return { outcome: "current", currentGeneration: current, changed: false };
  }
  state.generations.set(codexSourceId, generation);
  let changed = true;
  const expiredAt = now.toISOString();
  for (const record of state.records.values()) {
    if (
      record.identity.codexSourceId === codexSourceId &&
      record.identity.generation < generation &&
      (record.state === "pending" || record.state === "claimed")
    ) {
      expireRecord(record, "generation_superseded", expiredAt);
    }
  }
  return { outcome: "current", currentGeneration: generation, changed };
}

function staleGenerationResult(
  state: MutableBrokerState,
  identity: CodexActionRequestIdentity,
): { outcome: "stale_generation"; currentGeneration: number } | undefined {
  const current = state.generations.get(identity.codexSourceId);
  if (current !== undefined && current !== identity.generation) {
    return { outcome: "stale_generation", currentGeneration: current };
  }
  return undefined;
}

function expireDueInState(
  records: Map<string, CodexActionRequestRecord>,
  now: Date,
): boolean {
  const nowMs = now.getTime();
  const expiredAt = now.toISOString();
  let changed = false;
  for (const record of records.values()) {
    if (
      (record.state === "pending" || record.state === "claimed") &&
      Date.parse(record.expiresAt) <= nowMs
    ) {
      expireRecord(record, "deadline", expiredAt);
      changed = true;
    }
  }
  return changed;
}

function expireRecord(
  record: CodexActionRequestRecord,
  reason: CodexActionExpirationReason,
  expiredAt: string,
): void {
  record.state = "expired";
  record.updatedAt = expiredAt;
  delete record.claim;
  delete record.resolution;
  record.expiration = { reason, expiredAt };
}

function pruneTerminalRecords(
  records: Map<string, CodexActionRequestRecord>,
  cutoffMs: number,
): void {
  for (const [key, record] of records) {
    if (
      (record.state === "resolved" || record.state === "expired") &&
      Date.parse(record.updatedAt) < cutoffMs
    ) {
      records.delete(key);
    }
  }
}

function countState(
  records: ReadonlyMap<string, CodexActionRequestRecord>,
  state: CodexActionRequestState,
): number {
  let count = 0;
  for (const record of records.values()) {
    if (record.state === state) count += 1;
  }
  return count;
}

function claimTokensEqual(
  expected: string,
  actual: string | undefined,
): boolean {
  if (!actual) return false;
  const left = Buffer.from(expected);
  const right = Buffer.from(actual);
  return left.length === right.length && timingSafeEqual(left, right);
}

function validatePersistedState(
  raw: unknown,
  maxRecords: number,
): MutableBrokerState & { revision: number } {
  const data = requireRecord(raw, "state file");
  requireOnlyKeys(
    data,
    ["version", "revision", "currentGenerations", "requests"],
    "state file",
  );
  if (data.version !== STORE_VERSION) {
    throw new Error("Unsupported Codex Action Broker state version");
  }
  const revision = requireNonNegativeSafeInteger(data.revision, "revision");
  if (!Array.isArray(data.currentGenerations)) {
    throw new Error("Invalid Codex Action Broker generation list");
  }
  if (!Array.isArray(data.requests) || data.requests.length > maxRecords) {
    throw new Error("Invalid Codex Action Broker request list");
  }
  const generations = new Map<string, number>();
  for (const rawGeneration of data.currentGenerations) {
    const value = requireRecord(rawGeneration, "generation");
    requireOnlyKeys(value, ["codexSourceId", "generation"], "generation");
    const sourceId = requireOpaqueId(
      value.codexSourceId,
      MAX_SOURCE_ID_LENGTH,
      "Codex source ID",
    );
    const generation = requireGeneration(value.generation);
    if (generations.has(sourceId)) {
      throw new Error("Duplicate Codex Action Broker generation");
    }
    generations.set(sourceId, generation);
  }

  const records = new Map<string, CodexActionRequestRecord>();
  for (const rawRequest of data.requests) {
    const record = validatePersistedRecord(rawRequest);
    const current = generations.get(record.identity.codexSourceId);
    if (current === undefined || record.identity.generation > current) {
      throw new Error("Codex Action Broker request has an invalid generation");
    }
    const key = requestIdentityKey(record.identity);
    if (records.has(key)) {
      throw new Error("Duplicate Codex Action Broker request identity");
    }
    if (record.opaqueRequestId !== opaqueRequestId(record.identity)) {
      throw new Error("Codex Action Broker opaque request identity mismatch");
    }
    records.set(key, record);
  }
  return { revision, records, generations };
}

function validatePersistedRecord(raw: unknown): CodexActionRequestRecord {
  const value = requireRecord(raw, "request record");
  requireOnlyKeys(
    value,
    [
      "identity",
      "opaqueRequestId",
      "method",
      "kind",
      "state",
      "observedAt",
      "expiresAt",
      "updatedAt",
      "claim",
      "resolution",
      "expiration",
    ],
    "request record",
  );
  const identityRecord = requireRecord(value.identity, "request identity");
  requireOnlyKeys(
    identityRecord,
    ["codexSourceId", "threadId", "turnId", "requestId", "generation"],
    "request identity",
  );
  const identity = normalizeIdentity(
    identityRecord as unknown as CodexActionRequestIdentity,
  );
  const opaqueId = requireOpaqueId(
    value.opaqueRequestId,
    MAX_OPAQUE_ID_LENGTH,
    "opaque request ID",
  );
  const method = requireOpaqueId(value.method, MAX_METHOD_LENGTH, "method");
  requireRequestKind(value.kind);
  requireRequestState(value.state);
  const observedAt = normalizeTimestamp(value.observedAt, "observedAt");
  const expiresAt = normalizeTimestamp(value.expiresAt, "expiresAt");
  const updatedAt = normalizeTimestamp(value.updatedAt, "updatedAt");
  if (Date.parse(expiresAt) < Date.parse(observedAt)) {
    throw new Error("Codex Action Broker request timestamps are invalid");
  }

  const record: CodexActionRequestRecord = {
    identity,
    opaqueRequestId: opaqueId,
    method,
    kind: value.kind,
    state: value.state,
    observedAt,
    expiresAt,
    updatedAt,
  };
  if (value.state === "claimed") {
    const claim = requireRecord(value.claim, "claim");
    requireOnlyKeys(
      claim,
      [
        "claimantFingerprint",
        "operationFingerprint",
        "claimToken",
        "claimedAt",
        "submittingAt",
        "submittedAt",
      ],
      "claim",
    );
    record.claim = {
      claimantFingerprint: requireFingerprint(
        claim.claimantFingerprint,
        "claimant fingerprint",
      ),
      operationFingerprint: requireFingerprint(
        claim.operationFingerprint,
        "operation fingerprint",
      ),
      claimToken: requireGeneratedToken(claim.claimToken),
      claimedAt: normalizeTimestamp(claim.claimedAt, "claimedAt"),
      ...(claim.submittingAt !== undefined
        ? {
            submittingAt: normalizeTimestamp(
              claim.submittingAt,
              "submittingAt",
            ),
          }
        : {}),
      ...(claim.submittedAt !== undefined
        ? {
            submittedAt: normalizeTimestamp(claim.submittedAt, "submittedAt"),
          }
        : {}),
    };
    if (
      record.claim.submittingAt &&
      Date.parse(record.claim.submittingAt) < Date.parse(record.claim.claimedAt)
    ) {
      throw new Error("Codex Action Broker submission predates its claim");
    }
    if (
      record.claim.submittedAt &&
      (!record.claim.submittingAt ||
        Date.parse(record.claim.submittedAt) <
          Date.parse(record.claim.submittingAt))
    ) {
      throw new Error("Codex Action Broker submitted state is invalid");
    }
  } else if (value.claim !== undefined) {
    throw new Error("Unexpected Codex Action Broker claim metadata");
  }
  if (value.state === "resolved") {
    const resolution = requireRecord(value.resolution, "resolution");
    requireOnlyKeys(
      resolution,
      ["resolutionFingerprint", "authority", "outcome", "resolvedAt"],
      "resolution",
    );
    if (
      resolution.authority !== "claimant" &&
      resolution.authority !== "app_server"
    ) {
      throw new Error("Invalid Codex Action Broker resolution authority");
    }
    requireResolutionOutcome(resolution.outcome);
    record.resolution = {
      resolutionFingerprint: requireFingerprint(
        resolution.resolutionFingerprint,
        "resolution fingerprint",
      ),
      authority: resolution.authority,
      outcome: resolution.outcome,
      resolvedAt: normalizeTimestamp(resolution.resolvedAt, "resolvedAt"),
    };
  } else if (value.resolution !== undefined) {
    throw new Error("Unexpected Codex Action Broker resolution metadata");
  }
  if (value.state === "expired") {
    const expiration = requireRecord(value.expiration, "expiration");
    requireOnlyKeys(expiration, ["reason", "expiredAt"], "expiration");
    requireExpirationReason(expiration.reason);
    record.expiration = {
      reason: expiration.reason,
      expiredAt: normalizeTimestamp(expiration.expiredAt, "expiredAt"),
    };
  } else if (value.expiration !== undefined) {
    throw new Error("Unexpected Codex Action Broker expiration metadata");
  }
  return record;
}

function requireRecord(value: unknown, label: string): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`Invalid Codex Action Broker ${label}`);
  }
  return value as Record<string, unknown>;
}

function requireOnlyKeys(
  value: Record<string, unknown>,
  allowed: readonly string[],
  label: string,
): void {
  const allowedSet = new Set(allowed);
  if (Object.keys(value).some((key) => !allowedSet.has(key))) {
    throw new Error(`Unexpected field in Codex Action Broker ${label}`);
  }
}

function requireOpaqueId(
  value: unknown,
  maxLength: number,
  label: string,
): string {
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    value.length > maxLength ||
    value.trim() !== value ||
    /[\u0000-\u001f\u007f]/.test(value)
  ) {
    throw new Error(`Invalid Codex Action Broker ${label}`);
  }
  return value;
}

function requireRequestId(value: unknown): CodexActionRequestId {
  if (typeof value === "string") {
    return requireOpaqueId(value, MAX_OPAQUE_ID_LENGTH, "request ID");
  }
  if (typeof value === "number" && Number.isSafeInteger(value)) return value;
  throw new Error("Invalid Codex Action Broker request ID");
}

function requireGeneration(value: unknown): number {
  if (!Number.isSafeInteger(value) || (value as number) < 1) {
    throw new Error("Invalid Codex Action Broker generation");
  }
  return value as number;
}

function requireNonNegativeSafeInteger(value: unknown, label: string): number {
  if (!Number.isSafeInteger(value) || (value as number) < 0) {
    throw new Error(`Invalid Codex Action Broker ${label}`);
  }
  return value as number;
}

function requireOpaqueOperation(value: unknown, label: string): string {
  return requireOpaqueId(value, MAX_OPERATION_ID_LENGTH, label);
}

function requireGeneratedToken(value: unknown): string {
  return requireOpaqueId(value, MAX_OPERATION_ID_LENGTH, "claim token");
}

function requireFingerprint(value: unknown, label: string): string {
  const result = requireOpaqueId(value, 128, label);
  if (!/^[A-Za-z0-9_-]{43}$/.test(result)) {
    throw new Error(`Invalid Codex Action Broker ${label}`);
  }
  return result;
}

function requireRequestKind(
  value: unknown,
): asserts value is CodexActionRequestKind {
  if (
    value !== "command_approval" &&
    value !== "file_approval" &&
    value !== "permissions_approval" &&
    value !== "user_input" &&
    value !== "mcp_elicitation" &&
    value !== "tool_suggestion" &&
    value !== "current_time" &&
    value !== "unknown"
  ) {
    throw new Error("Invalid Codex Action Broker request kind");
  }
}

function requireRequestState(
  value: unknown,
): asserts value is CodexActionRequestState {
  if (
    value !== "pending" &&
    value !== "claimed" &&
    value !== "resolved" &&
    value !== "expired"
  ) {
    throw new Error("Invalid Codex Action Broker request state");
  }
}

function requireResolutionOutcome(
  value: unknown,
): asserts value is CodexActionResolutionOutcome {
  if (
    value !== "accepted" &&
    value !== "accepted_for_session" &&
    value !== "declined" &&
    value !== "cancelled" &&
    value !== "answered" &&
    value !== "resolved_elsewhere" &&
    value !== "unsupported" &&
    value !== "failed" &&
    value !== "unknown"
  ) {
    throw new Error("Invalid Codex Action Broker resolution outcome");
  }
}

function requireExpirationReason(
  value: unknown,
): asserts value is CodexActionExpirationReason {
  if (
    value !== "deadline" &&
    value !== "generation_superseded" &&
    value !== "operator"
  ) {
    throw new Error("Invalid Codex Action Broker expiration reason");
  }
}

function normalizeTimestamp(value: unknown, label: string): string {
  if (typeof value !== "string") {
    throw new Error(`Invalid Codex Action Broker ${label}`);
  }
  const parsed = Date.parse(value);
  if (!Number.isFinite(parsed) || new Date(parsed).toISOString() !== value) {
    throw new Error(`Invalid Codex Action Broker ${label}`);
  }
  return value;
}

function boundedDuration(
  value: number | undefined,
  fallback: number,
  label: string,
): number {
  const result = value ?? fallback;
  if (
    !Number.isSafeInteger(result) ||
    result < 1 ||
    result > MAX_REQUEST_TTL_MS
  ) {
    throw new Error(`Invalid Codex Action Broker ${label}`);
  }
  return result;
}

function boundedRecordLimit(value: number | undefined): number {
  const result = value ?? DEFAULT_MAX_RECORDS;
  if (
    !Number.isSafeInteger(result) ||
    result < 1 ||
    result > MAX_RECORDS_LIMIT
  ) {
    throw new Error("Invalid Codex Action Broker record limit");
  }
  return result;
}

async function fsyncDirectory(path: string): Promise<void> {
  let handle: Awaited<ReturnType<typeof open>> | undefined;
  try {
    handle = await open(path, "r");
    await handle.sync();
  } finally {
    await handle?.close().catch(() => undefined);
  }
}

async function readBoundedUtf8(
  handle: Awaited<ReturnType<typeof open>>,
  expectedSize: number,
): Promise<string> {
  const buffer = Buffer.allocUnsafe(expectedSize + 1);
  let offset = 0;
  while (offset < buffer.length) {
    const { bytesRead } = await handle.read(
      buffer,
      offset,
      buffer.length - offset,
      null,
    );
    if (bytesRead === 0) break;
    offset += bytesRead;
    if (offset > expectedSize) {
      throw new Error("Codex Action Broker state changed while loading");
    }
  }
  if (offset !== expectedSize) {
    throw new Error("Codex Action Broker state changed while loading");
  }
  return buffer.subarray(0, offset).toString("utf8");
}

export function actionBrokerFileForPort(
  port: number | string | undefined,
  explicitFile?: string,
): string {
  if (explicitFile?.trim()) return explicitFile.trim();
  const parsedPort =
    typeof port === "number" ? port : Number.parseInt(port ?? "", 10);
  if (!Number.isInteger(parsedPort) || parsedPort === DEFAULT_BRIDGE_PORT) {
    return DEFAULT_STORE_FILE;
  }
  return join(
    homedir(),
    ".ccpocket",
    `codex-action-broker-v1-${parsedPort}.json`,
  );
}

/**
 * Production Action Broker state follows the canonical Codex data source, not
 * a Bridge listening port. LAN, Tailscale and warm-up ports for the same source
 * must arbitrate through the same ledger.
 */
export function actionBrokerFileForSource(
  codexSourceId: string,
  explicitFile?: string,
): string {
  if (explicitFile?.trim()) return explicitFile.trim();
  if (!codexSourceId.trim() || codexSourceId.length > MAX_SOURCE_ID_LENGTH) {
    throw new Error("Codex source ID is invalid");
  }
  const sourceKey = createHash("sha256")
    .update(codexSourceId)
    .digest("hex")
    .slice(0, 32);
  return join(
    homedir(),
    ".ccpocket",
    `codex-action-broker-v1-${sourceKey}.json`,
  );
}

function defaultActionBrokerPath(port?: number | string): string {
  const override = process.env.CCPOCKET_CODEX_ACTION_BROKER_STATE_FILE?.trim();
  if (override) return override;
  if (process.env.NODE_ENV === "test") {
    return join(
      tmpdir(),
      `ccpocket-codex-action-broker-${process.pid}-${randomUUID()}.json`,
    );
  }
  return actionBrokerFileForPort(port);
}
