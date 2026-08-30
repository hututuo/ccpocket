import { createHash } from "node:crypto";
import { resolve } from "node:path";
import Database from "better-sqlite3";

import {
  CONVERSATION_CORE_DDL,
  CONVERSATION_CORE_SCHEMA_VERSION,
  CONVERSATION_CORE_TABLES,
} from "./schema.js";
import {
  ConversationStoreError,
  type InteractionClaimRecord,
  type InteractionRecord,
  type InteractionRef,
  type InteractionVariant,
  type JsonObject,
  type OperationAdmission,
  type OperationEventRecord,
  type OperationRecord,
  type OperationState,
  type OperationTransition,
  type QueueEntryRecord,
  type QueueLaneRecord,
  type QueueMutationRef,
  type SourcePartition,
  type StoreFaultStage,
  type StoreOpenOptions,
  type ThreadRef,
  type TimelineCandidate,
  type TimelineReadOptions,
  type TimelineReadback,
} from "./types.js";

const ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/;
const SHA256_PATTERN = /^[0-9a-f]{64}$/;
const MAX_TIMELINE_ITEMS = 100_000;
const MAX_TIMELINE_BYTES = 64 * 1024 * 1024;
const OPEN_DATABASES = new Set<string>();

interface TimelineHeadRow {
  bridge_identity_id: string;
  bridge_instance_id: string;
  codex_source_id: string;
  provider_thread_id: string;
  revision: number;
  content_revision: number;
  materialization_id: string | null;
  health: "HEALTHY" | "DEGRADED";
  health_problem_json: string | null;
  metadata_json: string | null;
  item_count: number;
  gap_count: number;
}

interface TimelineItemRow {
  item_id: string;
  provider_turn_id: string;
  item_ordinal: number;
  item_kind: string;
  payload_json: string;
}

interface TimelineGapRow {
  gap_id: string;
  gap_ordinal: number;
  reason: string;
  descriptor_json: string;
}

interface OperationRow {
  bridge_identity_id: string;
  bridge_instance_id: string;
  codex_source_id: string;
  provider_thread_id: string;
  client_message_id: string;
  operation_id: string;
  fingerprint: string;
  dispatch_attempt_id: string | null;
  provider_turn_id: string | null;
  state: OperationState;
  revision: number;
  canonical_observed: number;
  reconcile_required: number;
  payload_json: string;
  dispatch_started_at: number | null;
  provider_accepted_at: number | null;
  canonical_observed_at: number | null;
}

interface OperationEventRow {
  operation_id: string;
  event_sequence: number;
  from_state: OperationState | null;
  to_state: OperationState;
  event_kind: string;
  dispatch_attempt_id: string | null;
  provider_turn_id: string | null;
  details_json: string | null;
}

interface QueueLaneRow {
  bridge_identity_id: string;
  bridge_instance_id: string;
  codex_source_id: string;
  provider_thread_id: string;
  lane_family: string;
  revision: number;
  next_fifo_ordinal: number;
  active_count: number;
  capacity: number;
}

interface QueueEntryRow {
  bridge_identity_id: string;
  bridge_instance_id: string;
  codex_source_id: string;
  provider_thread_id: string;
  lane_family: string;
  queue_entry_id: string;
  root_operation_id: string;
  fifo_ordinal: number;
  entry_revision: number;
  state: QueueEntryRecord["state"];
  payload_digest: string;
  payload_json: string;
}

interface InteractionRow {
  bridge_identity_id: string;
  bridge_instance_id: string;
  codex_source_id: string;
  provider_thread_id: string;
  provider_turn_id: string;
  interaction_id: string;
  provider_request_id: string;
  variant: InteractionVariant;
  state: InteractionRecord["state"];
  revision: number;
  descriptor_json: string;
  response_fingerprint: string | null;
  response_operation_id: string | null;
  response_actor_id: string | null;
  response_json: string | null;
}

interface InteractionClaimRow {
  bridge_identity_id: string;
  bridge_instance_id: string;
  codex_source_id: string;
  provider_thread_id: string;
  provider_turn_id: string;
  interaction_id: string;
  claim_id: string;
  actor_id: string;
  token_hash: string;
  expires_at: number;
  state: InteractionClaimRecord["state"];
  revision: number;
}

export interface StorageDiagnostics {
  schemaVersion: number;
  journalMode: string;
  foreignKeys: boolean;
  quickCheck: string;
  foreignKeyViolations: number;
  strictTables: string[];
  tableCounts: Record<(typeof CONVERSATION_CORE_TABLES)[number], number>;
}

export interface TimelineDegradedObservation {
  problem: JsonObject;
  metadata?: JsonObject;
}

export interface QueueReservation extends QueueMutationRef {
  queueEntryId: string;
  rootOperationId: string;
  payloadDigest: string;
  payload: JsonObject;
}

export interface QueueEntryMutation extends QueueMutationRef {
  queueEntryId: string;
  expectedEntryRevision: number;
}

export interface OpenInteractionInput {
  ref: InteractionRef;
  providerRequestId: string;
  variant: InteractionVariant;
  descriptor: JsonObject;
}

export interface ClaimInteractionInput {
  ref: InteractionRef;
  expectedInteractionRevision: number;
  claimId: string;
  actorId: string;
  claimToken: string;
  expiresAt: number;
}

export interface RespondInteractionInput {
  ref: InteractionRef;
  expectedInteractionRevision: number;
  claimId: string;
  expectedClaimRevision: number;
  actorId: string;
  claimToken: string;
  responseFingerprint: string;
  responseOperationId: string;
  responseClientMessageId: string;
  operationPayload: JsonObject;
  response: JsonObject;
}

export interface InteractionClaimMutationInput {
  ref: InteractionRef;
  expectedInteractionRevision: number;
  claimId: string;
  expectedClaimRevision: number;
  actorId: string;
  claimToken: string;
}

export interface RenewInteractionClaimInput extends InteractionClaimMutationInput {
  expiresAt: number;
}

const OPERATION_TRANSITIONS: Readonly<Record<OperationState, ReadonlySet<OperationState>>> = {
  ADMITTED: new Set(["QUEUED", "DISPATCHING", "REJECTED", "CANCELLED"]),
  QUEUED: new Set(["DISPATCHING", "REJECTED", "CANCELLED"]),
  DISPATCHING: new Set(["PROVIDER_ACCEPTED", "REJECTED", "OUTCOME_UNKNOWN"]),
  PROVIDER_ACCEPTED: new Set(["CANONICAL_OBSERVED", "REJECTED", "OUTCOME_UNKNOWN"]),
  CANONICAL_OBSERVED: new Set(),
  REJECTED: new Set(),
  CANCELLED: new Set(),
  OUTCOME_UNKNOWN: new Set(["RECONCILE_REQUIRED", "CANONICAL_OBSERVED", "REJECTED", "CANCELLED"]),
  RECONCILE_REQUIRED: new Set(["CANONICAL_OBSERVED", "REJECTED", "CANCELLED", "OUTCOME_UNKNOWN"]),
};

function resolveTransitionIdentity(
  current: OperationRecord,
  transition: OperationTransition,
): { dispatchAttemptId?: string; providerTurnId?: string } {
  if (transition.dispatchAttemptId) assertId(transition.dispatchAttemptId, "dispatchAttemptId");
  if (transition.providerTurnId) assertId(transition.providerTurnId, "providerTurnId");
  if (
    current.dispatchAttemptId &&
    transition.dispatchAttemptId &&
    current.dispatchAttemptId !== transition.dispatchAttemptId
  ) {
    throw new ConversationStoreError(
      "IDENTITY_CONFLICT",
      "dispatch attempt does not match the admitted operation",
    );
  }
  if (
    current.providerTurnId &&
    transition.providerTurnId &&
    current.providerTurnId !== transition.providerTurnId
  ) {
    throw new ConversationStoreError(
      "IDENTITY_CONFLICT",
      "provider turn does not match the operation observation",
    );
  }

  const dispatchAttemptId = transition.dispatchAttemptId ?? current.dispatchAttemptId;
  const providerTurnId = transition.providerTurnId ?? current.providerTurnId;
  if (transition.toState === "DISPATCHING") {
    if (!transition.dispatchAttemptId || current.dispatchAttemptId || transition.providerTurnId) {
      throw new ConversationStoreError(
        "IDENTITY_CONFLICT",
        "dispatch start requires one new attempt and cannot bind a provider turn",
      );
    }
  } else if (transition.toState === "PROVIDER_ACCEPTED") {
    if (
      !dispatchAttemptId ||
      transition.dispatchAttemptId !== dispatchAttemptId ||
      !transition.providerTurnId ||
      transition.providerTurnEvidence !== "TURN_START_RESPONSE"
    ) {
      throw new ConversationStoreError(
        "IDENTITY_CONFLICT",
        "provider acceptance requires the exact attempt and turn/start response identity",
      );
    }
  } else if (transition.toState === "CANONICAL_OBSERVED") {
    if (
      !dispatchAttemptId ||
      transition.dispatchAttemptId !== dispatchAttemptId ||
      !transition.providerTurnId ||
      !providerTurnId ||
      transition.providerTurnEvidence !== "VERIFIED_FACT"
    ) {
      throw new ConversationStoreError(
        "IDENTITY_CONFLICT",
        "canonical observation requires exact dispatch and verified provider turn identity",
      );
    }
  } else if (transition.providerTurnId || transition.providerTurnEvidence) {
    throw new ConversationStoreError(
      "IDENTITY_CONFLICT",
      "provider turn identity is accepted only from turn/start response or verified canonical fact",
    );
  }
  return { dispatchAttemptId, providerTurnId };
}

export class ConversationCoreStore {
  private closed = false;

  private constructor(
    private readonly database: Database.Database,
    private readonly canonicalFilePath: string,
    private readonly faultHook: ((stage: StoreFaultStage) => void) | undefined,
    private readonly clock: () => number,
  ) {}

  static open(options: StoreOpenOptions): ConversationCoreStore {
    if (!options.filePath) {
      throw new Error("filePath is required");
    }
    const canonicalFilePath = resolve(options.filePath);
    if (OPEN_DATABASES.has(canonicalFilePath)) {
      throw new ConversationStoreError(
        "WRITER_ALREADY_OPEN",
        "conversation core database already has a writer connection in this process",
      );
    }
    OPEN_DATABASES.add(canonicalFilePath);
    let database: Database.Database | undefined;
    try {
      database = new Database(canonicalFilePath);
      database.pragma("journal_mode = WAL");
      database.pragma("foreign_keys = ON");
      database.pragma("synchronous = FULL");
      database.pragma("busy_timeout = 5000");
      const openedDatabase = database;
      const initialize = openedDatabase.transaction(() => {
        openedDatabase.exec(CONVERSATION_CORE_DDL);
        const stored = openedDatabase
          .prepare<[], { value: string }>("SELECT value FROM meta WHERE key = 'schema_version'")
          .get();
        if (stored && Number(stored.value) !== CONVERSATION_CORE_SCHEMA_VERSION) {
          throw new Error(`Unsupported conversation core schema version ${stored.value}`);
        }
        openedDatabase
          .prepare("INSERT OR IGNORE INTO meta (key, value) VALUES ('schema_version', ?)")
          .run(String(CONVERSATION_CORE_SCHEMA_VERSION));
      });
      initialize.immediate();
      const store = new ConversationCoreStore(
        openedDatabase,
        canonicalFilePath,
        options.faultHook,
        options.now ?? Date.now,
      );
      store.recoverUncertainOperations();
      return store;
    } catch (error) {
      database?.close();
      OPEN_DATABASES.delete(canonicalFilePath);
      throw error;
    }
  }

  close(): void {
    if (!this.closed) {
      this.database.close();
      OPEN_DATABASES.delete(this.canonicalFilePath);
      this.closed = true;
    }
  }

  diagnostics(): StorageDiagnostics {
    this.assertOpen();
    const quickCheck = this.database.pragma("quick_check", { simple: true }) as string;
    const journalMode = this.database.pragma("journal_mode", { simple: true }) as string;
    const foreignKeys = this.database.pragma("foreign_keys", { simple: true }) as number;
    const violations = this.database.pragma("foreign_key_check") as unknown[];
    const strictRows = this.database
      .prepare<[], { name: string }>(
        "SELECT name FROM pragma_table_list WHERE schema = 'main' AND strict = 1 ORDER BY name",
      )
      .all();
    const tableCounts = Object.fromEntries(
      CONVERSATION_CORE_TABLES.map((table) => [
        table,
        (this.database.prepare(`SELECT COUNT(*) AS count FROM ${table}`).get() as { count: number })
          .count,
      ]),
    ) as StorageDiagnostics["tableCounts"];
    return {
      schemaVersion: Number(
        this.database
          .prepare<[], { value: string }>("SELECT value FROM meta WHERE key = 'schema_version'")
          .get()?.value,
      ),
      journalMode,
      foreignKeys: foreignKeys === 1,
      quickCheck,
      foreignKeyViolations: violations.length,
      strictTables: strictRows.map((row) => row.name),
      tableCounts,
    };
  }

  readTimeline(
    thread: ThreadRef,
    options: TimelineReadOptions = {},
  ): TimelineReadback | undefined {
    this.assertOpen();
    assertThread(thread);
    const limit = options.limit ?? 200;
    if (!Number.isInteger(limit) || limit < 1 || limit > 200) {
      throw new RangeError("timeline read limit must be between 1 and 200");
    }
    if (options.startOrdinal !== undefined) {
      assertOrdinal(options.startOrdinal, "start ordinal");
    }
    const params = {
      ...threadParams(thread),
      limit,
      startOrdinal: options.startOrdinal ?? 0,
    };
    const head = this.database
      .prepare<typeof params, TimelineHeadRow>(
        `SELECT * FROM timeline_head
         WHERE bridge_identity_id = @bridgeIdentityId
           AND bridge_instance_id = @bridgeInstanceId
           AND codex_source_id = @codexSourceId
           AND provider_thread_id = @providerThreadId`,
      )
      .get(params);
    if (!head) return undefined;
    const itemRows = this.database
      .prepare<typeof params, TimelineItemRow>(
        `SELECT item_id, provider_turn_id, item_ordinal, item_kind, payload_json
         FROM timeline_item
         WHERE bridge_identity_id = @bridgeIdentityId
           AND bridge_instance_id = @bridgeInstanceId
           AND codex_source_id = @codexSourceId
           AND provider_thread_id = @providerThreadId
           ${options.startOrdinal === undefined ? "" : "AND item_ordinal >= @startOrdinal"}
         ORDER BY item_ordinal ${options.startOrdinal === undefined ? "DESC" : "ASC"}
         LIMIT @limit`,
      )
      .all(params);
    const gapRows = this.database
      .prepare<typeof params, TimelineGapRow>(
        `SELECT gap_id, gap_ordinal, reason, descriptor_json
         FROM timeline_gap
         WHERE bridge_identity_id = @bridgeIdentityId
           AND bridge_instance_id = @bridgeInstanceId
           AND codex_source_id = @codexSourceId
           AND provider_thread_id = @providerThreadId
           ${options.startOrdinal === undefined ? "" : "AND gap_ordinal >= @startOrdinal"}
         ORDER BY gap_ordinal ${options.startOrdinal === undefined ? "DESC" : "ASC"}
         LIMIT @limit`,
      )
      .all(params);
    const items = options.startOrdinal === undefined ? itemRows.reverse() : itemRows;
    const gaps = options.startOrdinal === undefined ? gapRows.reverse() : gapRows;
    return {
      thread,
      revision: head.revision,
      contentRevision: head.content_revision,
      ...(head.materialization_id ? { materializationId: head.materialization_id } : {}),
      health: head.health,
      ...(head.health_problem_json
        ? { healthProblem: parseJsonObject(head.health_problem_json) }
        : {}),
      ...(head.metadata_json ? { metadata: parseJsonObject(head.metadata_json) } : {}),
      totalItemCount: head.item_count,
      totalGapCount: head.gap_count,
      items: items.map((row) => ({
        itemId: row.item_id,
        providerTurnId: row.provider_turn_id,
        ordinal: row.item_ordinal,
        kind: row.item_kind,
        payload: parseJsonObject(row.payload_json),
      })),
      gaps: gaps.map((row) => ({
        gapId: row.gap_id,
        ordinal: row.gap_ordinal,
        reason: row.reason,
        descriptor: parseJsonObject(row.descriptor_json),
      })),
    };
  }

  commitTimelineCandidate(
    thread: ThreadRef,
    expectedRevision: number,
    candidate: TimelineCandidate,
  ): TimelineReadback {
    this.assertOpen();
    assertThread(thread);
    assertExpectedRevision(expectedRevision);
    validateTimelineCandidate(candidate);
    const params = threadParams(thread);
    const now = this.clock();
    const transaction = this.database.transaction(() => {
      this.ensureSource(thread.sourcePartition);
      const current = this.database
        .prepare<typeof params, Pick<TimelineHeadRow, "revision" | "content_revision">>(
          `SELECT revision, content_revision FROM timeline_head
           WHERE bridge_identity_id = @bridgeIdentityId
             AND bridge_instance_id = @bridgeInstanceId
             AND codex_source_id = @codexSourceId
             AND provider_thread_id = @providerThreadId`,
        )
        .get(params);
      if ((current?.revision ?? 0) !== expectedRevision) {
        throw new ConversationStoreError("REVISION_CONFLICT", "timeline revision changed");
      }
      const revision = expectedRevision + 1;
      const contentRevision = (current?.content_revision ?? 0) + 1;
      const metadataJson = candidate.metadata ? stringifyJson(candidate.metadata) : null;
      if (current) {
        const result = this.database
          .prepare(
            `UPDATE timeline_head
             SET revision = @revision,
                 content_revision = @contentRevision,
                 materialization_id = @materializationId,
                 health = 'HEALTHY',
                 health_problem_json = NULL,
                 metadata_json = @metadataJson,
                 item_count = @itemCount,
                 gap_count = @gapCount,
                 updated_at = @now
             WHERE bridge_identity_id = @bridgeIdentityId
               AND bridge_instance_id = @bridgeInstanceId
               AND codex_source_id = @codexSourceId
               AND provider_thread_id = @providerThreadId
               AND revision = @expectedRevision`,
          )
          .run({
            ...params,
            expectedRevision,
            revision,
            contentRevision,
            materializationId: candidate.materializationId,
            metadataJson,
            itemCount: candidate.items.length,
            gapCount: candidate.gaps.length,
            now,
          });
        if (result.changes !== 1) {
          throw new ConversationStoreError("REVISION_CONFLICT", "timeline CAS failed");
        }
      } else {
        this.database
          .prepare(
            `INSERT INTO timeline_head (
               bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id,
               revision, content_revision, materialization_id, health, health_problem_json,
               metadata_json, item_count, gap_count, updated_at
             ) VALUES (
               @bridgeIdentityId, @bridgeInstanceId, @codexSourceId, @providerThreadId,
               @revision, @contentRevision, @materializationId, 'HEALTHY', NULL,
               @metadataJson, @itemCount, @gapCount, @now
             )`,
          )
          .run({
            ...params,
            revision,
            contentRevision,
            materializationId: candidate.materializationId,
            metadataJson,
            itemCount: candidate.items.length,
            gapCount: candidate.gaps.length,
            now,
          });
      }
      this.inject("timeline.after-head-cas");
      this.database
        .prepare(
          `DELETE FROM timeline_item
           WHERE bridge_identity_id = @bridgeIdentityId
             AND bridge_instance_id = @bridgeInstanceId
             AND codex_source_id = @codexSourceId
             AND provider_thread_id = @providerThreadId`,
        )
        .run(params);
      this.database
        .prepare(
          `DELETE FROM timeline_gap
           WHERE bridge_identity_id = @bridgeIdentityId
             AND bridge_instance_id = @bridgeInstanceId
             AND codex_source_id = @codexSourceId
             AND provider_thread_id = @providerThreadId`,
        )
        .run(params);
      this.inject("timeline.after-delete");
      const insertItem = this.database.prepare(
        `INSERT INTO timeline_item (
           bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id,
           item_id, provider_turn_id, item_ordinal, item_kind, payload_json
         ) VALUES (
           @bridgeIdentityId, @bridgeInstanceId, @codexSourceId, @providerThreadId,
           @itemId, @providerTurnId, @ordinal, @kind, @payloadJson
         )`,
      );
      for (const item of candidate.items) {
        insertItem.run({ ...params, ...item, payloadJson: stringifyJson(item.payload) });
      }
      const insertGap = this.database.prepare(
        `INSERT INTO timeline_gap (
           bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id,
           gap_id, gap_ordinal, reason, descriptor_json
         ) VALUES (
           @bridgeIdentityId, @bridgeInstanceId, @codexSourceId, @providerThreadId,
           @gapId, @ordinal, @reason, @descriptorJson
         )`,
      );
      for (const gap of candidate.gaps) {
        insertGap.run({ ...params, ...gap, descriptorJson: stringifyJson(gap.descriptor) });
      }
      this.inject("timeline.after-items");
      this.inject("timeline.before-commit");
    });
    transaction.immediate();
    this.inject("timeline.after-commit-before-readback");
    return this.requireTimeline(thread);
  }

  recordTimelineDegraded(
    thread: ThreadRef,
    expectedRevision: number,
    observation: TimelineDegradedObservation,
  ): TimelineReadback {
    this.assertOpen();
    assertThread(thread);
    assertExpectedRevision(expectedRevision);
    const params = threadParams(thread);
    const now = this.clock();
    const problemJson = stringifyJson(observation.problem);
    const metadataJson = observation.metadata ? stringifyJson(observation.metadata) : null;
    const transaction = this.database.transaction(() => {
      this.ensureSource(thread.sourcePartition);
      const current = this.database
        .prepare<typeof params, Pick<TimelineHeadRow, "revision">>(
          `SELECT revision FROM timeline_head
           WHERE bridge_identity_id = @bridgeIdentityId
             AND bridge_instance_id = @bridgeInstanceId
             AND codex_source_id = @codexSourceId
             AND provider_thread_id = @providerThreadId`,
        )
        .get(params);
      if ((current?.revision ?? 0) !== expectedRevision) {
        throw new ConversationStoreError("REVISION_CONFLICT", "timeline revision changed");
      }
      if (current) {
        const result = this.database
          .prepare(
            `UPDATE timeline_head
             SET revision = revision + 1,
                 health = 'DEGRADED',
                 health_problem_json = @problemJson,
                 metadata_json = COALESCE(@metadataJson, metadata_json),
                 updated_at = @now
             WHERE bridge_identity_id = @bridgeIdentityId
               AND bridge_instance_id = @bridgeInstanceId
               AND codex_source_id = @codexSourceId
               AND provider_thread_id = @providerThreadId
               AND revision = @expectedRevision`,
          )
          .run({ ...params, expectedRevision, problemJson, metadataJson, now });
        if (result.changes !== 1) {
          throw new ConversationStoreError("REVISION_CONFLICT", "timeline CAS failed");
        }
      } else {
        this.database
          .prepare(
            `INSERT INTO timeline_head (
               bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id,
               revision, content_revision, materialization_id, health, health_problem_json,
               metadata_json, item_count, gap_count, updated_at
             ) VALUES (
               @bridgeIdentityId, @bridgeInstanceId, @codexSourceId, @providerThreadId,
               1, 0, NULL, 'DEGRADED', @problemJson, @metadataJson, 0, 0, @now
             )`,
          )
          .run({ ...params, problemJson, metadataJson, now });
      }
      this.inject("timeline.before-commit");
    });
    transaction.immediate();
    this.inject("timeline.after-commit-before-readback");
    return this.requireTimeline(thread);
  }

  admitOperation(admission: OperationAdmission): {
    kind: "ADMITTED" | "IDEMPOTENT";
    operation: OperationRecord;
  } {
    this.assertOpen();
    assertThread(admission.thread);
    assertId(admission.operationId, "operationId");
    assertId(admission.clientMessageId, "clientMessageId");
    assertDigest(admission.fingerprint, "fingerprint");
    const params = {
      ...threadParams(admission.thread),
      operationId: admission.operationId,
      clientMessageId: admission.clientMessageId,
      fingerprint: admission.fingerprint,
      now: this.clock(),
    };
    let kind: "ADMITTED" | "IDEMPOTENT" = "ADMITTED";
    const transaction = this.database.transaction(() => {
      kind = this.admitOperationInTransaction(admission, params.now);
      if (kind === "IDEMPOTENT") return;
      this.inject("operation.before-commit");
    });
    transaction.immediate();
    this.inject("operation.after-commit-before-readback");
    return { kind, operation: this.requireOperation(admission.thread, admission.operationId) };
  }

  transitionOperation(transition: OperationTransition): OperationRecord {
    this.assertOpen();
    assertThread(transition.thread);
    assertId(transition.operationId, "operationId");
    assertExpectedRevision(transition.expectedRevision);
    const now = this.clock();
    const transaction = this.database.transaction(() => {
      const current = this.requireOperation(transition.thread, transition.operationId);
      if (current.revision !== transition.expectedRevision) {
        throw new ConversationStoreError("REVISION_CONFLICT", "operation revision changed");
      }
      if (!OPERATION_TRANSITIONS[current.state].has(transition.toState)) {
        throw new ConversationStoreError(
          "INVALID_STATE_TRANSITION",
          `operation cannot move from ${current.state} to ${transition.toState}`,
        );
      }
      const identity = resolveTransitionIdentity(current, transition);
      const params = {
        ...threadParams(transition.thread),
        operationId: transition.operationId,
        expectedRevision: transition.expectedRevision,
        toState: transition.toState,
        dispatchAttemptId: identity.dispatchAttemptId ?? null,
        providerTurnId: identity.providerTurnId ?? null,
        canonicalObserved: transition.toState === "CANONICAL_OBSERVED" ? 1 : 0,
        reconcileRequired:
          transition.toState === "OUTCOME_UNKNOWN" || transition.toState === "RECONCILE_REQUIRED"
            ? 1
            : 0,
        now,
      };
      const result = this.database
        .prepare(
          `UPDATE operation
           SET state = @toState,
               revision = revision + 1,
               dispatch_attempt_id = COALESCE(dispatch_attempt_id, @dispatchAttemptId),
               provider_turn_id = COALESCE(provider_turn_id, @providerTurnId),
               canonical_observed = @canonicalObserved,
               reconcile_required = @reconcileRequired,
               dispatch_started_at = CASE
                 WHEN @toState = 'DISPATCHING' THEN @now ELSE dispatch_started_at END,
               provider_accepted_at = CASE
                 WHEN @toState = 'PROVIDER_ACCEPTED' THEN @now ELSE provider_accepted_at END,
               canonical_observed_at = CASE
                 WHEN @toState = 'CANONICAL_OBSERVED' THEN @now ELSE canonical_observed_at END,
               updated_at = @now
           WHERE operation_id = @operationId
             AND bridge_identity_id = @bridgeIdentityId
             AND bridge_instance_id = @bridgeInstanceId
             AND codex_source_id = @codexSourceId
             AND provider_thread_id = @providerThreadId
             AND revision = @expectedRevision`,
        )
        .run(params);
      if (result.changes !== 1) {
        throw new ConversationStoreError("REVISION_CONFLICT", "operation CAS failed");
      }
      this.inject("operation.after-row");
      this.insertOperationEvent({
        thread: transition.thread,
        operationId: transition.operationId,
        sequence: transition.expectedRevision + 1,
        fromState: current.state,
        toState: transition.toState,
        kind: transition.eventKind,
        dispatchAttemptId: identity.dispatchAttemptId,
        providerTurnId: identity.providerTurnId,
        details: transition.details,
        now,
      });
      this.inject("operation.after-event");
      this.inject("operation.before-commit");
    });
    transaction.immediate();
    this.inject("operation.after-commit-before-readback");
    return this.requireOperation(transition.thread, transition.operationId);
  }

  getOperation(thread: ThreadRef, operationId: string): OperationRecord | undefined {
    this.assertOpen();
    assertThread(thread);
    assertId(operationId, "operationId");
    const params = { ...threadParams(thread), operationId };
    const row = this.database
      .prepare<typeof params, OperationRow>(
        `SELECT * FROM operation
         WHERE operation_id = @operationId
           AND bridge_identity_id = @bridgeIdentityId
           AND bridge_instance_id = @bridgeInstanceId
           AND codex_source_id = @codexSourceId
           AND provider_thread_id = @providerThreadId`,
      )
      .get(params);
    return row ? operationFromRow(row) : undefined;
  }

  listOperationEvents(thread: ThreadRef, operationId: string): OperationEventRecord[] {
    this.assertOpen();
    const operation = this.requireOperation(thread, operationId);
    const rows = this.database
      .prepare<[string], OperationEventRow>(
        `SELECT operation_id, event_sequence, from_state, to_state, event_kind,
                dispatch_attempt_id, provider_turn_id, details_json
         FROM operation_event WHERE operation_id = ? ORDER BY event_sequence`,
      )
      .all(operation.operationId);
    return rows.map((row) => ({
      operationId: row.operation_id,
      sequence: row.event_sequence,
      ...(row.from_state ? { fromState: row.from_state } : {}),
      toState: row.to_state,
      kind: row.event_kind,
      ...(row.dispatch_attempt_id ? { dispatchAttemptId: row.dispatch_attempt_id } : {}),
      ...(row.provider_turn_id ? { providerTurnId: row.provider_turn_id } : {}),
      ...(row.details_json ? { details: parseJsonObject(row.details_json) } : {}),
    }));
  }

  listOperationsRequiringReconcile(): OperationRecord[] {
    this.assertOpen();
    return this.database
      .prepare<[], OperationRow>(
        "SELECT * FROM operation WHERE reconcile_required = 1 ORDER BY updated_at, operation_id",
      )
      .all()
      .map(operationFromRow);
  }

  openQueueLane(thread: ThreadRef, laneFamily: string, capacity = 16): QueueLaneRecord {
    this.assertOpen();
    assertThread(thread);
    assertId(laneFamily, "laneFamily");
    if (!Number.isInteger(capacity) || capacity < 1 || capacity > 16) {
      throw new RangeError("queue capacity must be between 1 and 16");
    }
    const params = { ...threadParams(thread), laneFamily, capacity, now: this.clock() };
    const transaction = this.database.transaction(() => {
      this.ensureSource(thread.sourcePartition);
      const existing = this.readQueueLane(thread, laneFamily);
      if (existing) {
        if (existing.capacity !== capacity) {
          throw new ConversationStoreError(
            "QUEUE_REVISION_CONFLICT",
            "lane already exists with another capacity",
          );
        }
        return;
      }
      this.database
        .prepare(
          `INSERT INTO queue_lane (
             bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id,
             lane_family, revision, next_fifo_ordinal, active_count, capacity, updated_at
           ) VALUES (
             @bridgeIdentityId, @bridgeInstanceId, @codexSourceId, @providerThreadId,
             @laneFamily, 1, 0, 0, @capacity, @now
           )`,
        )
        .run(params);
      this.inject("queue.before-commit");
    });
    transaction.immediate();
    return this.requireQueueLane(thread, laneFamily);
  }

  reserveQueueEntry(input: QueueReservation): QueueEntryRecord {
    this.assertOpen();
    assertQueueMutationRef(input);
    assertId(input.queueEntryId, "queueEntryId");
    assertId(input.rootOperationId, "rootOperationId");
    assertDigest(input.payloadDigest, "payloadDigest");
    const now = this.clock();
    const transaction = this.database.transaction(() => {
      const lane = this.requireQueueLane(input.thread, input.laneFamily);
      if (lane.revision !== input.expectedLaneRevision) {
        throw new ConversationStoreError("QUEUE_REVISION_CONFLICT", "queue lane revision changed");
      }
      if (lane.activeCount >= lane.capacity) {
        throw new ConversationStoreError("QUEUE_FULL", "queue lane is full");
      }
      this.requireOperation(input.thread, input.rootOperationId);
      const params = {
        ...threadParams(input.thread),
        laneFamily: input.laneFamily,
        queueEntryId: input.queueEntryId,
        rootOperationId: input.rootOperationId,
        fifoOrdinal: lane.nextFifoOrdinal,
        expectedLaneRevision: input.expectedLaneRevision,
        payloadDigest: input.payloadDigest,
        payloadJson: stringifyJson(input.payload),
        now,
      };
      const laneResult = this.database
        .prepare(
          `UPDATE queue_lane
           SET revision = revision + 1,
               next_fifo_ordinal = next_fifo_ordinal + 1,
               active_count = active_count + 1,
               updated_at = @now
           WHERE bridge_identity_id = @bridgeIdentityId
             AND bridge_instance_id = @bridgeInstanceId
             AND codex_source_id = @codexSourceId
             AND provider_thread_id = @providerThreadId
             AND lane_family = @laneFamily
             AND revision = @expectedLaneRevision`,
        )
        .run(params);
      if (laneResult.changes !== 1) {
        throw new ConversationStoreError("QUEUE_REVISION_CONFLICT", "queue lane CAS failed");
      }
      this.inject("queue.after-lane-cas");
      this.database
        .prepare(
          `INSERT INTO queue_entry (
             bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id,
             lane_family, queue_entry_id, root_operation_id, fifo_ordinal,
             entry_revision, state, payload_digest, payload_json, updated_at
           ) VALUES (
             @bridgeIdentityId, @bridgeInstanceId, @codexSourceId, @providerThreadId,
             @laneFamily, @queueEntryId, @rootOperationId, @fifoOrdinal,
             1, 'QUEUED', @payloadDigest, @payloadJson, @now
           )`,
        )
        .run(params);
      this.inject("queue.after-entry");
      this.inject("queue.before-commit");
    });
    transaction.immediate();
    this.inject("queue.after-commit-before-readback");
    return this.requireQueueEntry(input.thread, input.laneFamily, input.queueEntryId);
  }

  editQueueEntry(
    input: QueueEntryMutation & { payloadDigest: string; payload: JsonObject },
  ): QueueEntryRecord {
    assertDigest(input.payloadDigest, "payloadDigest");
    return this.mutateQueueEntry(input, "EDIT", input.payloadDigest, input.payload);
  }

  cancelQueueEntry(input: QueueEntryMutation): QueueEntryRecord {
    return this.mutateQueueEntry(input, "CANCEL");
  }

  reserveNextQueueEntry(input: QueueMutationRef): QueueEntryRecord | undefined {
    this.assertOpen();
    assertQueueMutationRef(input);
    let queueEntryId: string | undefined;
    const now = this.clock();
    const transaction = this.database.transaction(() => {
      const lane = this.requireQueueLane(input.thread, input.laneFamily);
      if (lane.revision !== input.expectedLaneRevision) {
        throw new ConversationStoreError("QUEUE_REVISION_CONFLICT", "queue lane revision changed");
      }
      const params = { ...threadParams(input.thread), laneFamily: input.laneFamily };
      const next = this.database
        .prepare<typeof params, Pick<QueueEntryRow, "queue_entry_id" | "entry_revision">>(
          `SELECT queue_entry_id, entry_revision FROM queue_entry
           WHERE bridge_identity_id = @bridgeIdentityId
             AND bridge_instance_id = @bridgeInstanceId
             AND codex_source_id = @codexSourceId
             AND provider_thread_id = @providerThreadId
             AND lane_family = @laneFamily
             AND state IN ('QUEUED', 'EDITED')
           ORDER BY fifo_ordinal LIMIT 1`,
        )
        .get(params);
      if (!next) return;
      queueEntryId = next.queue_entry_id;
      this.updateLaneRevision(input, now, false);
      this.inject("queue.after-lane-cas");
      const entryResult = this.database
        .prepare(
          `UPDATE queue_entry
           SET state = 'DISPATCH_OWNED', entry_revision = entry_revision + 1, updated_at = @now
           WHERE bridge_identity_id = @bridgeIdentityId
             AND bridge_instance_id = @bridgeInstanceId
             AND codex_source_id = @codexSourceId
             AND provider_thread_id = @providerThreadId
             AND lane_family = @laneFamily
             AND queue_entry_id = @queueEntryId
             AND entry_revision = @entryRevision
             AND state IN ('QUEUED', 'EDITED')`,
        )
        .run({
          ...params,
          queueEntryId,
          entryRevision: next.entry_revision,
          now,
        });
      if (entryResult.changes !== 1) {
        throw new ConversationStoreError("ENTRY_REVISION_CONFLICT", "queue entry CAS failed");
      }
      this.inject("queue.after-entry");
      this.inject("queue.before-commit");
    });
    transaction.immediate();
    if (!queueEntryId) return undefined;
    this.inject("queue.after-commit-before-readback");
    return this.requireQueueEntry(input.thread, input.laneFamily, queueEntryId);
  }

  consumeQueueEntry(input: QueueEntryMutation): QueueEntryRecord {
    this.assertOpen();
    assertQueueMutationRef(input);
    assertId(input.queueEntryId, "queueEntryId");
    assertExpectedRevision(input.expectedEntryRevision);
    const now = this.clock();
    const transaction = this.database.transaction(() => {
      const lane = this.requireQueueLane(input.thread, input.laneFamily);
      const entry = this.requireQueueEntry(input.thread, input.laneFamily, input.queueEntryId);
      if (lane.revision !== input.expectedLaneRevision) {
        throw new ConversationStoreError("QUEUE_REVISION_CONFLICT", "queue lane revision changed");
      }
      if (entry.revision !== input.expectedEntryRevision) {
        throw new ConversationStoreError("ENTRY_REVISION_CONFLICT", "queue entry revision changed");
      }
      if (entry.state !== "DISPATCH_OWNED") {
        throw new ConversationStoreError("QUEUE_ENTRY_NOT_EDITABLE", "entry is not dispatch-owned");
      }
      this.updateLaneRevision(input, now, true);
      this.inject("queue.after-lane-cas");
      const params = {
        ...threadParams(input.thread),
        laneFamily: input.laneFamily,
        queueEntryId: input.queueEntryId,
        expectedEntryRevision: input.expectedEntryRevision,
        now,
      };
      const result = this.database
        .prepare(
          `UPDATE queue_entry
           SET state = 'CONSUMED', entry_revision = entry_revision + 1, updated_at = @now
           WHERE bridge_identity_id = @bridgeIdentityId
             AND bridge_instance_id = @bridgeInstanceId
             AND codex_source_id = @codexSourceId
             AND provider_thread_id = @providerThreadId
             AND lane_family = @laneFamily
             AND queue_entry_id = @queueEntryId
             AND entry_revision = @expectedEntryRevision
             AND state = 'DISPATCH_OWNED'`,
        )
        .run(params);
      if (result.changes !== 1) {
        throw new ConversationStoreError("ENTRY_REVISION_CONFLICT", "queue entry CAS failed");
      }
      this.inject("queue.after-entry");
      this.inject("queue.before-commit");
    });
    transaction.immediate();
    this.inject("queue.after-commit-before-readback");
    return this.requireQueueEntry(input.thread, input.laneFamily, input.queueEntryId);
  }

  readQueueLane(thread: ThreadRef, laneFamily: string): QueueLaneRecord | undefined {
    this.assertOpen();
    assertThread(thread);
    assertId(laneFamily, "laneFamily");
    const params = { ...threadParams(thread), laneFamily };
    const row = this.database
      .prepare<typeof params, QueueLaneRow>(
        `SELECT * FROM queue_lane
         WHERE bridge_identity_id = @bridgeIdentityId
           AND bridge_instance_id = @bridgeInstanceId
           AND codex_source_id = @codexSourceId
           AND provider_thread_id = @providerThreadId
           AND lane_family = @laneFamily`,
      )
      .get(params);
    return row ? queueLaneFromRow(row) : undefined;
  }

  listQueueEntries(thread: ThreadRef, laneFamily: string): QueueEntryRecord[] {
    this.assertOpen();
    this.requireQueueLane(thread, laneFamily);
    const params = { ...threadParams(thread), laneFamily };
    return this.database
      .prepare<typeof params, QueueEntryRow>(
        `SELECT * FROM queue_entry
         WHERE bridge_identity_id = @bridgeIdentityId
           AND bridge_instance_id = @bridgeInstanceId
           AND codex_source_id = @codexSourceId
           AND provider_thread_id = @providerThreadId
           AND lane_family = @laneFamily
         ORDER BY fifo_ordinal`,
      )
      .all(params)
      .map(queueEntryFromRow);
  }

  openInteraction(input: OpenInteractionInput): InteractionRecord {
    this.assertOpen();
    assertInteractionRef(input.ref);
    assertId(input.providerRequestId, "providerRequestId");
    const params = {
      ...interactionParams(input.ref),
      providerRequestId: input.providerRequestId,
      variant: input.variant,
      descriptorJson: stringifyJson(input.descriptor),
      now: this.clock(),
    };
    const transaction = this.database.transaction(() => {
      this.ensureSource(input.ref.thread.sourcePartition);
      const existing = this.getInteraction(input.ref);
      if (existing) {
        if (
          existing.providerRequestId !== input.providerRequestId ||
          existing.variant !== input.variant ||
          stringifyJson(existing.descriptor) !== params.descriptorJson
        ) {
          throw new ConversationStoreError(
            "INTERACTION_REVISION_CONFLICT",
            "interaction identity is already bound to another descriptor",
          );
        }
        return;
      }
      this.database
        .prepare(
          `INSERT INTO interaction (
             bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id,
             provider_turn_id, interaction_id, provider_request_id, variant, state,
             revision, descriptor_json, updated_at
           ) VALUES (
             @bridgeIdentityId, @bridgeInstanceId, @codexSourceId, @providerThreadId,
             @providerTurnId, @interactionId, @providerRequestId, @variant, 'OPEN_UNCLAIMED',
             1, @descriptorJson, @now
           )`,
        )
        .run(params);
      this.inject("interaction.after-row");
      this.inject("interaction.before-commit");
    });
    transaction.immediate();
    this.inject("interaction.after-commit-before-readback");
    return this.requireInteraction(input.ref);
  }

  claimInteraction(input: ClaimInteractionInput): {
    interaction: InteractionRecord;
    claim: InteractionClaimRecord;
  } {
    this.assertOpen();
    assertInteractionRef(input.ref);
    assertExpectedRevision(input.expectedInteractionRevision);
    assertId(input.claimId, "claimId");
    assertId(input.actorId, "actorId");
    assertClaimToken(input.claimToken);
    const now = this.clock();
    if (!Number.isSafeInteger(input.expiresAt) || input.expiresAt <= now) {
      throw new ConversationStoreError("CLAIM_EXPIRED", "claim expiry must be in the future");
    }
    const transaction = this.database.transaction(() => {
      const interaction = this.requireInteraction(input.ref);
      if (interaction.revision !== input.expectedInteractionRevision) {
        throw new ConversationStoreError(
          "INTERACTION_REVISION_CONFLICT",
          "interaction revision changed",
        );
      }
      if (interaction.state !== "OPEN_UNCLAIMED" && interaction.state !== "OPEN_CLAIMED") {
        throw new ConversationStoreError("INTERACTION_NOT_OPEN", "interaction is not claimable");
      }
      const active = this.findActiveClaim(input.ref);
      if (active && active.expiresAt > now) {
        throw new ConversationStoreError("INTERACTION_CONTENDED", "interaction already has a claim");
      }
      if (active) {
        this.database
          .prepare(
            `UPDATE interaction_claim
             SET state = 'EXPIRED', revision = revision + 1, updated_at = @now
             WHERE bridge_identity_id = @bridgeIdentityId
               AND bridge_instance_id = @bridgeInstanceId
               AND codex_source_id = @codexSourceId
               AND provider_thread_id = @providerThreadId
               AND provider_turn_id = @providerTurnId
               AND interaction_id = @interactionId
               AND claim_id = @claimId
               AND revision = @claimRevision
               AND state = 'ACTIVE'`,
          )
          .run({
            ...interactionParams(input.ref),
            claimId: active.claimId,
            claimRevision: active.revision,
            now,
          });
      }
      const interactionResult = this.database
        .prepare(
          `UPDATE interaction
           SET state = 'OPEN_CLAIMED', revision = revision + 1, updated_at = @now
           WHERE bridge_identity_id = @bridgeIdentityId
             AND bridge_instance_id = @bridgeInstanceId
             AND codex_source_id = @codexSourceId
             AND provider_thread_id = @providerThreadId
             AND provider_turn_id = @providerTurnId
             AND interaction_id = @interactionId
             AND revision = @expectedInteractionRevision`,
        )
        .run({
          ...interactionParams(input.ref),
          expectedInteractionRevision: input.expectedInteractionRevision,
          now,
        });
      if (interactionResult.changes !== 1) {
        throw new ConversationStoreError(
          "INTERACTION_REVISION_CONFLICT",
          "interaction CAS failed",
        );
      }
      this.inject("interaction.after-row");
      this.database
        .prepare(
          `INSERT INTO interaction_claim (
             bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id,
             provider_turn_id, interaction_id, claim_id, actor_id, token_hash,
             expires_at, state, revision, updated_at
           ) VALUES (
             @bridgeIdentityId, @bridgeInstanceId, @codexSourceId, @providerThreadId,
             @providerTurnId, @interactionId, @claimId, @actorId, @tokenHash,
             @expiresAt, 'ACTIVE', 1, @now
           )`,
        )
        .run({
          ...interactionParams(input.ref),
          claimId: input.claimId,
          actorId: input.actorId,
          tokenHash: hashClaimToken(input.claimToken),
          expiresAt: input.expiresAt,
          now,
        });
      this.inject("interaction.after-claim");
      this.inject("interaction.before-commit");
    });
    transaction.immediate();
    this.inject("interaction.after-commit-before-readback");
    return {
      interaction: this.requireInteraction(input.ref),
      claim: this.requireClaim(input.ref, input.claimId),
    };
  }

  respondInteraction(input: RespondInteractionInput): {
    kind: "RECORDED" | "IDEMPOTENT";
    interaction: InteractionRecord;
  } {
    this.assertOpen();
    assertInteractionRef(input.ref);
    assertExpectedRevision(input.expectedInteractionRevision);
    assertExpectedRevision(input.expectedClaimRevision);
    assertId(input.claimId, "claimId");
    assertId(input.actorId, "actorId");
    assertClaimToken(input.claimToken);
    assertDigest(input.responseFingerprint, "responseFingerprint");
    assertId(input.responseOperationId, "responseOperationId");
    assertId(input.responseClientMessageId, "responseClientMessageId");
    const now = this.clock();
    let kind: "RECORDED" | "IDEMPOTENT" = "RECORDED";
    const transaction = this.database.transaction(() => {
      const interaction = this.requireInteraction(input.ref);
      const claim = this.requireClaim(input.ref, input.claimId);
      if (claim.actorId !== input.actorId || claim.tokenHash !== hashClaimToken(input.claimToken)) {
        throw new ConversationStoreError("CLAIM_NOT_OWNED", "claim actor or token does not match");
      }
      if (claim.state !== "ACTIVE" || claim.expiresAt <= now) {
        throw new ConversationStoreError("CLAIM_EXPIRED", "claim is not active");
      }
      if (claim.revision !== input.expectedClaimRevision) {
        throw new ConversationStoreError("CLAIM_NOT_OWNED", "claim revision changed");
      }
      if (interaction.responseFingerprint) {
        if (
          interaction.responseFingerprint === input.responseFingerprint &&
          interaction.responseOperationId === input.responseOperationId &&
          interaction.responseActorId === input.actorId
        ) {
          const responseOperation = this.getOperation(input.ref.thread, input.responseOperationId);
          if (
            !responseOperation ||
            responseOperation.clientMessageId !== input.responseClientMessageId ||
            responseOperation.fingerprint !== input.responseFingerprint
          ) {
            throw new ConversationStoreError(
              "INTERACTION_REVISION_CONFLICT",
              "response barrier does not match its admitted operation",
            );
          }
          kind = "IDEMPOTENT";
          return;
        }
        throw new ConversationStoreError(
          "INTERACTION_REVISION_CONFLICT",
          "interaction already has another response barrier",
        );
      }
      if (interaction.revision !== input.expectedInteractionRevision) {
        throw new ConversationStoreError(
          "INTERACTION_REVISION_CONFLICT",
          "interaction revision changed",
        );
      }
      if (interaction.state !== "OPEN_CLAIMED") {
        throw new ConversationStoreError("INTERACTION_NOT_OPEN", "interaction is not open");
      }
      const admissionKind = this.admitOperationInTransaction(
        {
          thread: input.ref.thread,
          operationId: input.responseOperationId,
          clientMessageId: input.responseClientMessageId,
          fingerprint: input.responseFingerprint,
          payload: input.operationPayload,
        },
        now,
      );
      if (admissionKind !== "ADMITTED") {
        throw new ConversationStoreError(
          "INTERACTION_REVISION_CONFLICT",
          "response operation already exists without this response barrier",
        );
      }
      const params = {
        ...interactionParams(input.ref),
        expectedInteractionRevision: input.expectedInteractionRevision,
        responseFingerprint: input.responseFingerprint,
        responseOperationId: input.responseOperationId,
        responseActorId: input.actorId,
        responseJson: stringifyJson(input.response),
        now,
      };
      const result = this.database
        .prepare(
          `UPDATE interaction
           SET state = 'RESPONSE_PENDING',
               revision = revision + 1,
               response_fingerprint = @responseFingerprint,
               response_operation_id = @responseOperationId,
               response_actor_id = @responseActorId,
               response_json = @responseJson,
               updated_at = @now
           WHERE bridge_identity_id = @bridgeIdentityId
             AND bridge_instance_id = @bridgeInstanceId
             AND codex_source_id = @codexSourceId
             AND provider_thread_id = @providerThreadId
             AND provider_turn_id = @providerTurnId
             AND interaction_id = @interactionId
             AND revision = @expectedInteractionRevision
             AND state = 'OPEN_CLAIMED'`,
        )
        .run(params);
      if (result.changes !== 1) {
        throw new ConversationStoreError(
          "INTERACTION_REVISION_CONFLICT",
          "interaction response CAS failed",
        );
      }
      this.inject("interaction.after-row");
      this.inject("interaction.before-commit");
    });
    transaction.immediate();
    this.inject("interaction.after-commit-before-readback");
    return { kind, interaction: this.requireInteraction(input.ref) };
  }

  renewInteractionClaim(input: RenewInteractionClaimInput): {
    interaction: InteractionRecord;
    claim: InteractionClaimRecord;
  } {
    this.assertOpen();
    this.validateClaimMutation(input);
    const now = this.clock();
    if (!Number.isSafeInteger(input.expiresAt) || input.expiresAt <= now) {
      throw new ConversationStoreError("CLAIM_EXPIRED", "claim expiry must be in the future");
    }
    const transaction = this.database.transaction(() => {
      const { interaction, claim } = this.requireOwnedActiveClaim(input, now);
      if (interaction.state !== "OPEN_CLAIMED") {
        throw new ConversationStoreError("INTERACTION_NOT_OPEN", "interaction is not claimed");
      }
      this.updateInteractionForClaim(
        input.ref,
        input.expectedInteractionRevision,
        "OPEN_CLAIMED",
        now,
      );
      this.inject("interaction.after-row");
      const result = this.database
        .prepare(
          `UPDATE interaction_claim
           SET expires_at = @expiresAt, revision = revision + 1, updated_at = @now
           WHERE bridge_identity_id = @bridgeIdentityId
             AND bridge_instance_id = @bridgeInstanceId
             AND codex_source_id = @codexSourceId
             AND provider_thread_id = @providerThreadId
             AND provider_turn_id = @providerTurnId
             AND interaction_id = @interactionId
             AND claim_id = @claimId
             AND revision = @expectedClaimRevision
             AND state = 'ACTIVE'`,
        )
        .run({
          ...interactionParams(input.ref),
          claimId: claim.claimId,
          expectedClaimRevision: input.expectedClaimRevision,
          expiresAt: input.expiresAt,
          now,
        });
      if (result.changes !== 1) {
        throw new ConversationStoreError("CLAIM_NOT_OWNED", "claim CAS failed");
      }
      this.inject("interaction.after-claim");
      this.inject("interaction.before-commit");
    });
    transaction.immediate();
    this.inject("interaction.after-commit-before-readback");
    return {
      interaction: this.requireInteraction(input.ref),
      claim: this.requireClaim(input.ref, input.claimId),
    };
  }

  releaseInteractionClaim(input: InteractionClaimMutationInput): {
    interaction: InteractionRecord;
    claim: InteractionClaimRecord;
  } {
    this.assertOpen();
    this.validateClaimMutation(input);
    const now = this.clock();
    const transaction = this.database.transaction(() => {
      const { claim } = this.requireOwnedActiveClaim(input, now);
      this.updateInteractionForClaim(
        input.ref,
        input.expectedInteractionRevision,
        "OPEN_UNCLAIMED",
        now,
      );
      this.inject("interaction.after-row");
      const result = this.database
        .prepare(
          `UPDATE interaction_claim
           SET state = 'RELEASED', revision = revision + 1, updated_at = @now
           WHERE bridge_identity_id = @bridgeIdentityId
             AND bridge_instance_id = @bridgeInstanceId
             AND codex_source_id = @codexSourceId
             AND provider_thread_id = @providerThreadId
             AND provider_turn_id = @providerTurnId
             AND interaction_id = @interactionId
             AND claim_id = @claimId
             AND revision = @expectedClaimRevision
             AND state = 'ACTIVE'`,
        )
        .run({
          ...interactionParams(input.ref),
          claimId: claim.claimId,
          expectedClaimRevision: input.expectedClaimRevision,
          now,
        });
      if (result.changes !== 1) {
        throw new ConversationStoreError("CLAIM_NOT_OWNED", "claim CAS failed");
      }
      this.inject("interaction.after-claim");
      this.inject("interaction.before-commit");
    });
    transaction.immediate();
    this.inject("interaction.after-commit-before-readback");
    return {
      interaction: this.requireInteraction(input.ref),
      claim: this.requireClaim(input.ref, input.claimId),
    };
  }

  getInteraction(ref: InteractionRef): InteractionRecord | undefined {
    this.assertOpen();
    assertInteractionRef(ref);
    const params = interactionParams(ref);
    const row = this.database
      .prepare<typeof params, InteractionRow>(
        `SELECT * FROM interaction
         WHERE bridge_identity_id = @bridgeIdentityId
           AND bridge_instance_id = @bridgeInstanceId
           AND codex_source_id = @codexSourceId
           AND provider_thread_id = @providerThreadId
           AND provider_turn_id = @providerTurnId
           AND interaction_id = @interactionId`,
      )
      .get(params);
    return row ? interactionFromRow(row) : undefined;
  }

  getActiveClaim(ref: InteractionRef): InteractionClaimRecord | undefined {
    this.assertOpen();
    assertInteractionRef(ref);
    return this.findActiveClaim(ref);
  }

  private mutateQueueEntry(
    input: QueueEntryMutation,
    action: "EDIT" | "CANCEL",
    payloadDigest?: string,
    payload?: JsonObject,
  ): QueueEntryRecord {
    this.assertOpen();
    assertQueueMutationRef(input);
    assertId(input.queueEntryId, "queueEntryId");
    assertExpectedRevision(input.expectedEntryRevision);
    const now = this.clock();
    const transaction = this.database.transaction(() => {
      const lane = this.requireQueueLane(input.thread, input.laneFamily);
      const entry = this.requireQueueEntry(input.thread, input.laneFamily, input.queueEntryId);
      if (lane.revision !== input.expectedLaneRevision) {
        throw new ConversationStoreError("QUEUE_REVISION_CONFLICT", "queue lane revision changed");
      }
      if (entry.revision !== input.expectedEntryRevision) {
        throw new ConversationStoreError("ENTRY_REVISION_CONFLICT", "queue entry revision changed");
      }
      if (entry.state !== "QUEUED" && entry.state !== "EDITED") {
        throw new ConversationStoreError(
          action === "CANCEL" ? "QUEUE_ENTRY_NOT_CANCELLABLE" : "QUEUE_ENTRY_NOT_EDITABLE",
          `queue entry cannot ${action.toLowerCase()} from ${entry.state}`,
        );
      }
      this.updateLaneRevision(input, now, action === "CANCEL");
      this.inject("queue.after-lane-cas");
      const params = {
        ...threadParams(input.thread),
        laneFamily: input.laneFamily,
        queueEntryId: input.queueEntryId,
        expectedEntryRevision: input.expectedEntryRevision,
        state: action === "EDIT" ? "EDITED" : "CANCELLED",
        payloadDigest: payloadDigest ?? entry.payloadDigest,
        payloadJson: payload ? stringifyJson(payload) : stringifyJson(entry.payload),
        now,
      };
      const result = this.database
        .prepare(
          `UPDATE queue_entry
           SET state = @state,
               entry_revision = entry_revision + 1,
               payload_digest = @payloadDigest,
               payload_json = @payloadJson,
               updated_at = @now
           WHERE bridge_identity_id = @bridgeIdentityId
             AND bridge_instance_id = @bridgeInstanceId
             AND codex_source_id = @codexSourceId
             AND provider_thread_id = @providerThreadId
             AND lane_family = @laneFamily
             AND queue_entry_id = @queueEntryId
             AND entry_revision = @expectedEntryRevision
             AND state IN ('QUEUED', 'EDITED')`,
        )
        .run(params);
      if (result.changes !== 1) {
        throw new ConversationStoreError("ENTRY_REVISION_CONFLICT", "queue entry CAS failed");
      }
      this.inject("queue.after-entry");
      this.inject("queue.before-commit");
    });
    transaction.immediate();
    this.inject("queue.after-commit-before-readback");
    return this.requireQueueEntry(input.thread, input.laneFamily, input.queueEntryId);
  }

  private updateLaneRevision(input: QueueMutationRef, now: number, decrementActive: boolean): void {
    const params = {
      ...threadParams(input.thread),
      laneFamily: input.laneFamily,
      expectedLaneRevision: input.expectedLaneRevision,
      decrementActive: decrementActive ? 1 : 0,
      now,
    };
    const result = this.database
      .prepare(
        `UPDATE queue_lane
         SET revision = revision + 1,
             active_count = active_count - @decrementActive,
             updated_at = @now
         WHERE bridge_identity_id = @bridgeIdentityId
           AND bridge_instance_id = @bridgeInstanceId
           AND codex_source_id = @codexSourceId
           AND provider_thread_id = @providerThreadId
           AND lane_family = @laneFamily
           AND revision = @expectedLaneRevision
           AND active_count >= @decrementActive`,
      )
      .run(params);
    if (result.changes !== 1) {
      throw new ConversationStoreError("QUEUE_REVISION_CONFLICT", "queue lane CAS failed");
    }
  }

  private requireQueueLane(thread: ThreadRef, laneFamily: string): QueueLaneRecord {
    const lane = this.readQueueLane(thread, laneFamily);
    if (!lane) {
      throw new ConversationStoreError("QUEUE_REVISION_CONFLICT", "queue lane does not exist");
    }
    return lane;
  }

  private requireQueueEntry(
    thread: ThreadRef,
    laneFamily: string,
    queueEntryId: string,
  ): QueueEntryRecord {
    const params = { ...threadParams(thread), laneFamily, queueEntryId };
    const row = this.database
      .prepare<typeof params, QueueEntryRow>(
        `SELECT * FROM queue_entry
         WHERE bridge_identity_id = @bridgeIdentityId
           AND bridge_instance_id = @bridgeInstanceId
           AND codex_source_id = @codexSourceId
           AND provider_thread_id = @providerThreadId
           AND lane_family = @laneFamily
           AND queue_entry_id = @queueEntryId`,
      )
      .get(params);
    if (!row) {
      throw new ConversationStoreError("QUEUE_ENTRY_NOT_FOUND", "queue entry does not exist");
    }
    return queueEntryFromRow(row);
  }

  private requireTimeline(thread: ThreadRef): TimelineReadback {
    const timeline = this.readTimeline(thread);
    if (!timeline) throw new Error("timeline readback missing after commit");
    return timeline;
  }

  private findOperationByAdmissionKey(
    thread: ThreadRef,
    clientMessageId: string,
  ): OperationRecord | undefined {
    const params = { ...threadParams(thread), clientMessageId };
    const row = this.database
      .prepare<typeof params, OperationRow>(
        `SELECT * FROM operation
         WHERE bridge_identity_id = @bridgeIdentityId
           AND bridge_instance_id = @bridgeInstanceId
           AND codex_source_id = @codexSourceId
           AND provider_thread_id = @providerThreadId
           AND client_message_id = @clientMessageId`,
      )
      .get(params);
    return row ? operationFromRow(row) : undefined;
  }

  private admitOperationInTransaction(admission: OperationAdmission, now: number): "ADMITTED" | "IDEMPOTENT" {
    this.ensureSource(admission.thread.sourcePartition);
    const existing = this.findOperationByAdmissionKey(admission.thread, admission.clientMessageId);
    if (existing) {
      if (existing.fingerprint !== admission.fingerprint) {
        throw new ConversationStoreError(
          "OPERATION_FINGERPRINT_CONFLICT",
          "clientMessageId is already bound to another fingerprint",
        );
      }
      if (existing.operationId !== admission.operationId) {
        throw new ConversationStoreError(
          "OPERATION_ID_CONFLICT",
          "clientMessageId is already bound to another operationId",
        );
      }
      return "IDEMPOTENT";
    }
    const reusedId = this.database
      .prepare<[string], { operation_id: string }>(
        "SELECT operation_id FROM operation WHERE operation_id = ?",
      )
      .get(admission.operationId);
    if (reusedId) {
      throw new ConversationStoreError(
        "OPERATION_ID_CONFLICT",
        "operationId is already bound to another admission key",
      );
    }
    this.database
      .prepare(
        `INSERT INTO operation (
           bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id,
           client_message_id, operation_id, fingerprint, state, revision,
           canonical_observed, reconcile_required, payload_json, created_at, updated_at
         ) VALUES (
           @bridgeIdentityId, @bridgeInstanceId, @codexSourceId, @providerThreadId,
           @clientMessageId, @operationId, @fingerprint, 'ADMITTED', 1,
           0, 0, @payloadJson, @now, @now
         )`,
      )
      .run({
        ...threadParams(admission.thread),
        operationId: admission.operationId,
        clientMessageId: admission.clientMessageId,
        fingerprint: admission.fingerprint,
        payloadJson: stringifyJson(admission.payload),
        now,
      });
    this.inject("operation.after-row");
    this.insertOperationEvent({
      thread: admission.thread,
      operationId: admission.operationId,
      sequence: 1,
      toState: "ADMITTED",
      kind: "ADMITTED",
      now,
    });
    this.inject("operation.after-event");
    return "ADMITTED";
  }

  private requireOperation(thread: ThreadRef, operationId: string): OperationRecord {
    const operation = this.getOperation(thread, operationId);
    if (!operation) {
      throw new ConversationStoreError("OPERATION_NOT_FOUND", "operation does not exist in source");
    }
    return operation;
  }

  private insertOperationEvent(input: {
    thread: ThreadRef;
    operationId: string;
    sequence: number;
    fromState?: OperationState;
    toState: OperationState;
    kind: string;
    dispatchAttemptId?: string;
    providerTurnId?: string;
    details?: JsonObject;
    now: number;
  }): void {
    this.database
      .prepare(
        `INSERT INTO operation_event (
           operation_id, bridge_identity_id, bridge_instance_id, codex_source_id,
           provider_thread_id, event_sequence, from_state, to_state, event_kind,
           dispatch_attempt_id, provider_turn_id, details_json, created_at
         ) VALUES (
           @operationId, @bridgeIdentityId, @bridgeInstanceId, @codexSourceId,
           @providerThreadId, @sequence, @fromState, @toState, @kind,
           @dispatchAttemptId, @providerTurnId, @detailsJson, @now
         )`,
      )
      .run({
        ...threadParams(input.thread),
        operationId: input.operationId,
        sequence: input.sequence,
        fromState: input.fromState ?? null,
        toState: input.toState,
        kind: input.kind,
        dispatchAttemptId: input.dispatchAttemptId ?? null,
        providerTurnId: input.providerTurnId ?? null,
        detailsJson: input.details ? stringifyJson(input.details) : null,
        now: input.now,
      });
  }

  private requireInteraction(ref: InteractionRef): InteractionRecord {
    const interaction = this.getInteraction(ref);
    if (!interaction) {
      throw new ConversationStoreError("INTERACTION_NOT_OPEN", "interaction does not exist in source");
    }
    return interaction;
  }

  private findActiveClaim(ref: InteractionRef): InteractionClaimRecord | undefined {
    const params = interactionParams(ref);
    const row = this.database
      .prepare<typeof params, InteractionClaimRow>(
        `SELECT * FROM interaction_claim
         WHERE bridge_identity_id = @bridgeIdentityId
           AND bridge_instance_id = @bridgeInstanceId
           AND codex_source_id = @codexSourceId
           AND provider_thread_id = @providerThreadId
           AND provider_turn_id = @providerTurnId
           AND interaction_id = @interactionId
           AND state = 'ACTIVE'`,
      )
      .get(params);
    return row ? claimFromRow(row) : undefined;
  }

  private requireClaim(ref: InteractionRef, claimId: string): InteractionClaimRecord {
    const params = { ...interactionParams(ref), claimId };
    const row = this.database
      .prepare<typeof params, InteractionClaimRow>(
        `SELECT * FROM interaction_claim
         WHERE bridge_identity_id = @bridgeIdentityId
           AND bridge_instance_id = @bridgeInstanceId
           AND codex_source_id = @codexSourceId
           AND provider_thread_id = @providerThreadId
           AND provider_turn_id = @providerTurnId
           AND interaction_id = @interactionId
           AND claim_id = @claimId`,
      )
      .get(params);
    if (!row) {
      throw new ConversationStoreError("CLAIM_NOT_OWNED", "claim does not exist in source");
    }
    return claimFromRow(row);
  }

  private validateClaimMutation(input: InteractionClaimMutationInput): void {
    assertInteractionRef(input.ref);
    assertExpectedRevision(input.expectedInteractionRevision);
    assertExpectedRevision(input.expectedClaimRevision);
    assertId(input.claimId, "claimId");
    assertId(input.actorId, "actorId");
    assertClaimToken(input.claimToken);
  }

  private requireOwnedActiveClaim(
    input: InteractionClaimMutationInput,
    now: number,
  ): { interaction: InteractionRecord; claim: InteractionClaimRecord } {
    const interaction = this.requireInteraction(input.ref);
    const claim = this.requireClaim(input.ref, input.claimId);
    if (interaction.revision !== input.expectedInteractionRevision) {
      throw new ConversationStoreError(
        "INTERACTION_REVISION_CONFLICT",
        "interaction revision changed",
      );
    }
    if (claim.revision !== input.expectedClaimRevision) {
      throw new ConversationStoreError("CLAIM_NOT_OWNED", "claim revision changed");
    }
    if (claim.actorId !== input.actorId || claim.tokenHash !== hashClaimToken(input.claimToken)) {
      throw new ConversationStoreError("CLAIM_NOT_OWNED", "claim actor or token does not match");
    }
    if (claim.state !== "ACTIVE" || claim.expiresAt <= now) {
      throw new ConversationStoreError("CLAIM_EXPIRED", "claim is not active");
    }
    return { interaction, claim };
  }

  private updateInteractionForClaim(
    ref: InteractionRef,
    expectedInteractionRevision: number,
    state: "OPEN_CLAIMED" | "OPEN_UNCLAIMED",
    now: number,
  ): void {
    const result = this.database
      .prepare(
        `UPDATE interaction
         SET state = @state, revision = revision + 1, updated_at = @now
         WHERE bridge_identity_id = @bridgeIdentityId
           AND bridge_instance_id = @bridgeInstanceId
           AND codex_source_id = @codexSourceId
           AND provider_thread_id = @providerThreadId
           AND provider_turn_id = @providerTurnId
           AND interaction_id = @interactionId
           AND revision = @expectedInteractionRevision
           AND state = 'OPEN_CLAIMED'`,
      )
      .run({
        ...interactionParams(ref),
        expectedInteractionRevision,
        state,
        now,
      });
    if (result.changes !== 1) {
      throw new ConversationStoreError(
        "INTERACTION_REVISION_CONFLICT",
        "interaction claim CAS failed",
      );
    }
  }

  private recoverUncertainOperations(): void {
    const rows = this.database
      .prepare<[], OperationRow>(
        `SELECT * FROM operation
         WHERE state IN ('DISPATCHING', 'PROVIDER_ACCEPTED')
           AND canonical_observed = 0
         ORDER BY created_at, operation_id`,
      )
      .all();
    if (rows.length === 0) return;
    const transaction = this.database.transaction(() => {
      for (const row of rows) {
        const thread = threadFromRow(row);
        const result = this.database
          .prepare(
            `UPDATE operation
             SET state = 'OUTCOME_UNKNOWN',
                 revision = revision + 1,
                 reconcile_required = 1,
                 updated_at = @now
             WHERE operation_id = @operationId
               AND revision = @revision
               AND state = @state
               AND canonical_observed = 0`,
          )
          .run({
            operationId: row.operation_id,
            revision: row.revision,
            state: row.state,
            now: this.clock(),
          });
        if (result.changes !== 1) {
          throw new ConversationStoreError("REVISION_CONFLICT", "operation recovery CAS failed");
        }
        this.insertOperationEvent({
          thread,
          operationId: row.operation_id,
          sequence: row.revision + 1,
          fromState: row.state,
          toState: "OUTCOME_UNKNOWN",
          kind: "RESTART_REQUIRES_RECONCILE",
          dispatchAttemptId: row.dispatch_attempt_id ?? undefined,
          providerTurnId: row.provider_turn_id ?? undefined,
          details: { replayAuthorized: false },
          now: this.clock(),
        });
        this.inject("recovery.after-operation");
      }
    });
    transaction.immediate();
  }

  private ensureSource(source: SourcePartition): void {
    assertSource(source);
    this.database
      .prepare(
        `INSERT OR IGNORE INTO source_partition (
           bridge_identity_id, bridge_instance_id, codex_source_id, created_at
         ) VALUES (@bridgeIdentityId, @bridgeInstanceId, @codexSourceId, @now)`,
      )
      .run({ ...sourceParams(source), now: this.clock() });
  }

  private inject(stage: StoreFaultStage): void {
    this.faultHook?.(stage);
  }

  private assertOpen(): void {
    if (this.closed) {
      throw new ConversationStoreError("STORE_CLOSED", "conversation store is closed");
    }
  }
}

function sourceParams(source: SourcePartition) {
  return {
    bridgeIdentityId: source.bridgeIdentityId,
    bridgeInstanceId: source.bridgeInstanceId,
    codexSourceId: source.codexSourceId,
  };
}

function threadParams(thread: ThreadRef) {
  return { ...sourceParams(thread.sourcePartition), providerThreadId: thread.providerThreadId };
}

function interactionParams(ref: InteractionRef) {
  return {
    ...threadParams(ref.thread),
    providerTurnId: ref.providerTurnId,
    interactionId: ref.interactionId,
  };
}

function threadFromRow(row: {
  bridge_identity_id: string;
  bridge_instance_id: string;
  codex_source_id: string;
  provider_thread_id: string;
}): ThreadRef {
  return {
    sourcePartition: {
      bridgeIdentityId: row.bridge_identity_id,
      bridgeInstanceId: row.bridge_instance_id,
      codexSourceId: row.codex_source_id,
    },
    providerThreadId: row.provider_thread_id,
  };
}

function interactionRefFromRow(row: InteractionRow | InteractionClaimRow): InteractionRef {
  return {
    thread: threadFromRow(row),
    providerTurnId: row.provider_turn_id,
    interactionId: row.interaction_id,
  };
}

function operationFromRow(row: OperationRow): OperationRecord {
  return {
    thread: threadFromRow(row),
    operationId: row.operation_id,
    clientMessageId: row.client_message_id,
    fingerprint: row.fingerprint,
    ...(row.dispatch_attempt_id ? { dispatchAttemptId: row.dispatch_attempt_id } : {}),
    ...(row.provider_turn_id ? { providerTurnId: row.provider_turn_id } : {}),
    state: row.state,
    revision: row.revision,
    canonicalObserved: row.canonical_observed === 1,
    reconcileRequired: row.reconcile_required === 1,
    ...(row.dispatch_started_at ? { dispatchStartedAt: row.dispatch_started_at } : {}),
    ...(row.provider_accepted_at ? { providerAcceptedAt: row.provider_accepted_at } : {}),
    ...(row.canonical_observed_at ? { canonicalObservedAt: row.canonical_observed_at } : {}),
    payload: parseJsonObject(row.payload_json),
  };
}

function queueLaneFromRow(row: QueueLaneRow): QueueLaneRecord {
  return {
    thread: threadFromRow(row),
    laneFamily: row.lane_family,
    revision: row.revision,
    nextFifoOrdinal: row.next_fifo_ordinal,
    activeCount: row.active_count,
    capacity: row.capacity,
  };
}

function queueEntryFromRow(row: QueueEntryRow): QueueEntryRecord {
  return {
    thread: threadFromRow(row),
    laneFamily: row.lane_family,
    queueEntryId: row.queue_entry_id,
    rootOperationId: row.root_operation_id,
    fifoOrdinal: row.fifo_ordinal,
    revision: row.entry_revision,
    state: row.state,
    payloadDigest: row.payload_digest,
    payload: parseJsonObject(row.payload_json),
  };
}

function interactionFromRow(row: InteractionRow): InteractionRecord {
  return {
    ref: interactionRefFromRow(row),
    providerRequestId: row.provider_request_id,
    variant: row.variant,
    state: row.state,
    revision: row.revision,
    descriptor: parseJsonObject(row.descriptor_json),
    ...(row.response_fingerprint ? { responseFingerprint: row.response_fingerprint } : {}),
    ...(row.response_operation_id ? { responseOperationId: row.response_operation_id } : {}),
    ...(row.response_actor_id ? { responseActorId: row.response_actor_id } : {}),
    ...(row.response_json ? { response: parseJsonObject(row.response_json) } : {}),
  };
}

function claimFromRow(row: InteractionClaimRow): InteractionClaimRecord {
  return {
    ref: interactionRefFromRow(row),
    claimId: row.claim_id,
    actorId: row.actor_id,
    tokenHash: row.token_hash,
    expiresAt: row.expires_at,
    state: row.state,
    revision: row.revision,
  };
}

function assertSource(source: SourcePartition): void {
  assertId(source.bridgeIdentityId, "bridgeIdentityId");
  assertId(source.bridgeInstanceId, "bridgeInstanceId");
  assertId(source.codexSourceId, "codexSourceId");
}

function assertThread(thread: ThreadRef): void {
  assertSource(thread.sourcePartition);
  assertId(thread.providerThreadId, "providerThreadId");
}

function assertInteractionRef(ref: InteractionRef): void {
  assertThread(ref.thread);
  assertId(ref.providerTurnId, "providerTurnId");
  assertId(ref.interactionId, "interactionId");
}

function assertQueueMutationRef(input: QueueMutationRef): void {
  assertThread(input.thread);
  assertId(input.laneFamily, "laneFamily");
  assertExpectedRevision(input.expectedLaneRevision);
}

function assertId(value: string, label: string): void {
  if (!ID_PATTERN.test(value)) {
    throw new ConversationStoreError("IDENTITY_CONFLICT", `${label} is not a canonical id`);
  }
}

function assertDigest(value: string, label: string): void {
  if (!SHA256_PATTERN.test(value)) {
    throw new ConversationStoreError("IDENTITY_CONFLICT", `${label} must be lowercase sha256`);
  }
}

function assertExpectedRevision(value: number): void {
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new RangeError("expected revision must be a non-negative safe integer");
  }
}

function assertClaimToken(value: string): void {
  if (value.length < 16 || Buffer.byteLength(value, "utf8") > 4096) {
    throw new ConversationStoreError("CLAIM_NOT_OWNED", "claim token has invalid bounds");
  }
}

function hashClaimToken(value: string): string {
  return createHash("sha256").update(value, "utf8").digest("hex");
}

function validateTimelineCandidate(candidate: TimelineCandidate): void {
  assertId(candidate.materializationId, "materializationId");
  if (!candidate.verified || candidate.items.length === 0) {
    throw new ConversationStoreError(
      "TIMELINE_CANDIDATE_REJECTED",
      "only a verified non-empty candidate can replace last-good timeline content",
    );
  }
  if (candidate.items.length > MAX_TIMELINE_ITEMS) {
    throw new ConversationStoreError("PAYLOAD_TOO_LARGE", "timeline item limit exceeded");
  }
  const itemIds = new Set<string>();
  const itemOrdinals = new Set<number>();
  for (const item of candidate.items) {
    assertId(item.itemId, "itemId");
    assertId(item.providerTurnId, "providerTurnId");
    assertOrdinal(item.ordinal, "item ordinal");
    if (itemIds.has(item.itemId) || itemOrdinals.has(item.ordinal)) {
      throw new ConversationStoreError(
        "TIMELINE_CANDIDATE_REJECTED",
        "timeline candidate contains duplicate item identity or ordinal",
      );
    }
    itemIds.add(item.itemId);
    itemOrdinals.add(item.ordinal);
  }
  const gapIds = new Set<string>();
  const gapOrdinals = new Set<number>();
  for (const gap of candidate.gaps) {
    assertId(gap.gapId, "gapId");
    assertOrdinal(gap.ordinal, "gap ordinal");
    if (gapIds.has(gap.gapId) || gapOrdinals.has(gap.ordinal)) {
      throw new ConversationStoreError(
        "TIMELINE_CANDIDATE_REJECTED",
        "timeline candidate contains duplicate gap identity or ordinal",
      );
    }
    gapIds.add(gap.gapId);
    gapOrdinals.add(gap.ordinal);
  }
  const encodedBytes = Buffer.byteLength(
    JSON.stringify({ items: candidate.items, gaps: candidate.gaps, metadata: candidate.metadata }),
    "utf8",
  );
  if (encodedBytes > MAX_TIMELINE_BYTES) {
    throw new ConversationStoreError("PAYLOAD_TOO_LARGE", "timeline byte limit exceeded");
  }
}

function assertOrdinal(value: number, label: string): void {
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new ConversationStoreError("TIMELINE_CANDIDATE_REJECTED", `${label} is invalid`);
  }
}

function stringifyJson(value: JsonObject): string {
  const encoded = JSON.stringify(value);
  if (encoded === undefined) throw new TypeError("value is not JSON serializable");
  return encoded;
}

function parseJsonObject(value: string): JsonObject {
  const decoded: unknown = JSON.parse(value);
  if (typeof decoded !== "object" || decoded === null || Array.isArray(decoded)) {
    throw new Error("stored JSON value is not an object");
  }
  return decoded as JsonObject;
}
