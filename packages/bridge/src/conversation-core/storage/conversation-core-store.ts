/** @internal better-sqlite3 must only be instantiated by the store worker in production. */
import { createHash, randomUUID } from "node:crypto";
import { existsSync, lstatSync, realpathSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { isMainThread } from "node:worker_threads";
import Database from "better-sqlite3";

import {
  OPERATION_JSON_MAX_BYTES,
  TIMELINE_PAGE_MAX_BYTES,
  canonicalizeJson,
  canonicalizeJsonObject,
  parseStoredJsonObject,
  sha256CanonicalJson,
  sha256Text,
} from "./canonical-json.js";
import {
  CONVERSATION_CORE_BOOTSTRAP_DDL,
  CONVERSATION_CORE_DDL,
  CONVERSATION_CORE_SCHEMA_VERSION,
  CONVERSATION_CORE_TABLES,
} from "./schema.js";
import {
  ConversationStoreError,
  type AuthenticatedExecutionContext,
  type BeginQueuedDispatchInput,
  type ClaimInteractionInput,
  type DispatchStartInput,
  type InteractionClaimMutationInput,
  type InteractionClaimRecord,
  type InteractionRecord,
  type InteractionRef,
  type JsonObject,
  type OpenInteractionInput,
  type OperationAdmission,
  type OperationCode,
  type OperationEventRecord,
  type OperationRecord,
  type OperationState,
  type OperationTransition,
  type ProviderReadEvidence,
  type QueueAdmissionInput,
  type QueueControlInput,
  type QueueDispatchBarrier,
  type QueueEntryRecord,
  type QueueLaneRecord,
  type ReconcileFactInput,
  type ReconcileResolutionRecord,
  type RenewInteractionClaimInput,
  type ResolveInteractionInput,
  type RespondInteractionInput,
  type SourceEpoch,
  type SourcePartition,
  type StoreFaultStage,
  type StoreOpenOptions,
  type ThreadRef,
  type TimelineCoverageIslandRecord,
  type TimelineGapRecord,
  type TimelineItemRecord,
  type TimelineMaterializationBeginInput,
  type TimelineMaterializationRecord,
  type TimelinePageInput,
  type TimelinePageRecord,
  type TimelineReadAttemptInput,
  type TimelineReadAttemptRecord,
  type TimelineReadOptions,
  type TimelineReadback,
  type TimelineSealInput,
} from "./types.js";

const ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$/;
const SHA256_PATTERN = /^[0-9a-f]{64}$/;
const MAX_TIMELINE_ITEMS = 100_000;
const MAX_TIMELINE_BYTES = 64 * 1024 * 1024;
const DEFAULT_WRITER_LEASE_TTL_MS = 30_000;
const DIRECT_ADMISSION_CODES: ReadonlySet<OperationCode> = new Set(["OP-001", "OP-004", "OP-006"]);

interface WriterOwnerRow {
  owner_id: string;
  owner_pid: number;
  owner_epoch: number;
  lease_expires_at: number;
}

interface MaterializationRow {
  bridge_identity_id: string;
  bridge_instance_id: string;
  codex_source_id: string;
  provider_thread_id: string;
  materialization_id: string;
  connection_generation: number;
  provider_generation: number;
  source_epoch_json: string;
  evidence_json: string;
  read_evidence_digest: string;
  state: TimelineMaterializationRecord["state"];
  page_count: number;
  item_count: number;
  gap_count: number;
  total_bytes: number;
  materialization_digest: string | null;
  order_digest: string | null;
  coverage_digest: string | null;
  empty_proof_json: string | null;
  verified_at: number | null;
}

interface TimelinePageRow {
  materialization_id: string;
  page_index: number;
  previous_page_digest: string | null;
  page_digest: string;
  item_count: number;
  gap_count: number;
  body_bytes: number;
  body_json: string;
}

interface TimelineHeadRow extends MaterializationRow {
  head_revision: number;
}

interface TimelineItemRow {
  item_id: string;
  provider_turn_id: string;
  turn_ordinal: number;
  item_ordinal: number;
  timeline_ordinal: number;
  item_kind: string;
  payload_json: string;
}

interface TimelineGapRow {
  gap_id: string;
  gap_ordinal: number;
  gap_kind: TimelineGapRecord["gapKind"];
  first_missing_timeline_ordinal: number;
  last_missing_timeline_ordinal: number;
  reason: TimelineGapRecord["reason"];
  descriptor_json: string;
}

interface TimelineIslandRow {
  island_id: string;
  island_ordinal: number;
  first_timeline_ordinal: number;
  last_timeline_ordinal: number;
  structural_coverage: TimelineCoverageIslandRecord["structuralCoverage"];
  payload_coverage: TimelineCoverageIslandRecord["payloadCoverage"];
}

interface OperationRow {
  bridge_identity_id: string;
  bridge_instance_id: string;
  codex_source_id: string;
  provider_thread_id: string;
  connection_generation: number;
  provider_generation: number;
  source_epoch_json: string;
  actor_id: string;
  origin_kind: OperationRecord["origin"]["kind"];
  origin_id: string;
  client_instance_id: string;
  client_message_id: string;
  operation_id: string;
  operation_code: OperationRecord["operationCode"];
  conflict_family: OperationRecord["conflictFamily"];
  fingerprint: string;
  target_json: string;
  payload_json: string;
  preconditions_json: string;
  dispatch_attempt_id: string | null;
  provider_turn_id: string | null;
  state: OperationState;
  revision: number;
  canonical_observed: number;
  reconcile_required: number;
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
  connection_generation: number;
  provider_generation: number;
  source_epoch_json: string;
  provider_request_id: string;
  variant: InteractionRecord["variant"];
  state: InteractionRecord["state"];
  revision: number;
  expires_at: number;
  descriptor_json: string;
  response_fingerprint: string | null;
  response_operation_id: string | null;
  response_actor_id: string | null;
  response_json: string | null;
  resolution_evidence_digest: string | null;
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
  writerOwnerEpoch: number;
  tableCounts: Record<(typeof CONVERSATION_CORE_TABLES)[number], number>;
}

export class ConversationCoreStore {
  private closed = false;

  private constructor(
    private readonly database: Database.Database,
    private readonly canonicalFilePath: string,
    private readonly ownerId: string,
    private ownerEpoch: number,
    private readonly leaseTtlMs: number,
    private readonly faultHook: ((stage: StoreFaultStage) => void) | undefined,
    private readonly clock: () => number,
  ) {}

  static open(options: StoreOpenOptions): ConversationCoreStore {
    if (isMainThread) {
      throw new ConversationStoreError(
        "WORKER_REQUIRED",
        "ConversationCoreStore may only open inside its dedicated worker",
      );
    }
    return ConversationCoreStore.openInternal(options);
  }

  /** @internal Direct synchronous access exists only for isolated storage tests. */
  static openForTesting(options: StoreOpenOptions): ConversationCoreStore {
    if (!process.env.VITEST) {
      throw new ConversationStoreError("WORKER_REQUIRED", "direct store access is test-only");
    }
    return ConversationCoreStore.openInternal(options);
  }

  private static openInternal(options: StoreOpenOptions): ConversationCoreStore {
    const canonicalFilePath = canonicalDatabasePath(options.filePath);
    const leaseTtlMs = options.writerLeaseTtlMs ?? DEFAULT_WRITER_LEASE_TTL_MS;
    if (!Number.isSafeInteger(leaseTtlMs) || leaseTtlMs < 250 || leaseTtlMs > 300_000) {
      throw new RangeError("writer lease ttl must be between 250 and 300000 ms");
    }
    const database = new Database(canonicalFilePath);
    let acquiredOwnerId: string | undefined;
    let acquiredOwnerEpoch: number | undefined;
    try {
      const preexistingSchema = readSchemaObjects(database);
      if (preexistingSchema.length > 0) {
        const hasMeta = preexistingSchema.some((entry) => entry.type === "table" && entry.name === "meta");
        if (!hasMeta) {
          throw new Error("Unsupported conversation core schema: schema_version is missing");
        }
        const preexistingVersion = database
          .prepare("SELECT value FROM meta WHERE key='schema_version'")
          .get() as { value: string } | undefined;
        const expectedVersion = String(CONVERSATION_CORE_SCHEMA_VERSION);
        if (!preexistingVersion || preexistingVersion.value !== expectedVersion) {
          throw new Error(
            `Unsupported conversation core schema version ${preexistingVersion?.value ?? "missing"}`,
          );
        }
        assertExistingSchemaShape(preexistingSchema);
      }
      database.pragma("journal_mode = WAL");
      database.pragma("foreign_keys = ON");
      database.pragma("synchronous = FULL");
      database.pragma("busy_timeout = 5000");
      database.exec(CONVERSATION_CORE_BOOTSTRAP_DDL);
      const ownerId = randomUUID();
      const now = (options.now ?? Date.now)();
      const ownerEpoch = acquireWriterLease(database, ownerId, now, leaseTtlMs);
      acquiredOwnerId = ownerId;
      acquiredOwnerEpoch = ownerEpoch;
      database.exec(CONVERSATION_CORE_DDL);
      database
        .prepare("INSERT OR IGNORE INTO meta (key, value) VALUES ('schema_version', ?)")
        .run(String(CONVERSATION_CORE_SCHEMA_VERSION));
      const store = new ConversationCoreStore(
        database,
        canonicalFilePath,
        ownerId,
        ownerEpoch,
        leaseTtlMs,
        options.faultHook,
        options.now ?? Date.now,
      );
      store.recoverUncertainOperations();
      return store;
    } catch (error) {
      if (acquiredOwnerId && acquiredOwnerEpoch) {
        database.prepare(
          "DELETE FROM writer_owner WHERE singleton=1 AND owner_id=? AND owner_epoch=?",
        ).run(acquiredOwnerId, acquiredOwnerEpoch);
      }
      database.close();
      throw error;
    }
  }

  close(): void {
    if (this.closed) return;
    try {
      this.database
        .prepare("DELETE FROM writer_owner WHERE singleton = 1 AND owner_id = ? AND owner_epoch = ?")
        .run(this.ownerId, this.ownerEpoch);
    } finally {
      this.database.close();
      this.closed = true;
    }
  }

  renewWriterLease(): number {
    this.assertOpen();
    const now = this.clock();
    const result = this.database
      .prepare(
        `UPDATE writer_owner SET lease_expires_at = ?, updated_at = ?
         WHERE singleton = 1 AND owner_id = ? AND owner_epoch = ? AND lease_expires_at > ?`,
      )
      .run(now + this.leaseTtlMs, now, this.ownerId, this.ownerEpoch, now);
    if (result.changes !== 1) {
      throw new ConversationStoreError("WRITER_LEASE_LOST", "writer lease is no longer owned");
    }
    return this.ownerEpoch;
  }

  diagnostics(): StorageDiagnostics {
    this.assertLease();
    const owner = this.database.prepare("SELECT * FROM writer_owner WHERE singleton = 1").get() as WriterOwnerRow;
    const strictRows = this.database
      .prepare("SELECT name FROM pragma_table_list WHERE schema = 'main' AND strict = 1 ORDER BY name")
      .all() as Array<{ name: string }>;
    const tableCounts = Object.fromEntries(
      CONVERSATION_CORE_TABLES.map((table) => [
        table,
        (this.database.prepare(`SELECT COUNT(*) AS count FROM ${table}`).get() as { count: number }).count,
      ]),
    ) as StorageDiagnostics["tableCounts"];
    return {
      schemaVersion: Number(
        (this.database.prepare("SELECT value FROM meta WHERE key = 'schema_version'").get() as { value: string }).value,
      ),
      journalMode: this.database.pragma("journal_mode", { simple: true }) as string,
      foreignKeys: (this.database.pragma("foreign_keys", { simple: true }) as number) === 1,
      quickCheck: this.database.pragma("quick_check", { simple: true }) as string,
      foreignKeyViolations: (this.database.pragma("foreign_key_check") as unknown[]).length,
      strictTables: strictRows.map((row) => row.name),
      writerOwnerEpoch: owner.owner_epoch,
      tableCounts,
    };
  }

  beginTimelineMaterialization(input: TimelineMaterializationBeginInput): TimelineMaterializationRecord {
    this.assertLease();
    assertAuthenticatedContext(input.context, input.thread);
    assertId(input.materializationId, "materializationId");
    validateReadEvidence(input.evidence);
    const sourceEpochJson = canonicalizeJson(input.context.sourceEpoch, {
      maxBytes: OPERATION_JSON_MAX_BYTES,
      requireObject: true,
    });
    const { canonical: evidenceJson, digest: readEvidenceDigest } = sha256CanonicalJson(
      input.evidence,
      OPERATION_JSON_MAX_BYTES,
    );
    const params = {
      ...threadParams(input.thread),
      materializationId: input.materializationId,
      connectionGeneration: input.context.sourceEpoch.connectionGeneration,
      providerGeneration: input.context.sourceEpoch.providerGeneration,
      sourceEpochJson,
      evidenceJson,
      readEvidenceDigest,
      now: this.clock(),
    };
    const transaction = this.database.transaction(() => {
      this.fenceLeaseInTransaction();
      this.ensureSource(input.thread.sourcePartition);
      const existing = this.getMaterialization(input.thread, input.materializationId);
      if (existing) {
        if (
          existing.readEvidenceDigest !== readEvidenceDigest ||
          !sameSourceEpoch(existing.sourceEpoch, input.context.sourceEpoch)
        ) {
          throw new ConversationStoreError("TIMELINE_CANDIDATE_REJECTED", "materialization id is already bound");
        }
        return;
      }
      this.database.prepare(
        `INSERT INTO timeline_materialization (
           bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id,
           materialization_id, connection_generation, provider_generation, source_epoch_json,
           evidence_json, read_evidence_digest, state, created_at, updated_at
         ) VALUES (
           @bridgeIdentityId, @bridgeInstanceId, @codexSourceId, @providerThreadId,
           @materializationId, @connectionGeneration, @providerGeneration, @sourceEpochJson,
           @evidenceJson, @readEvidenceDigest, 'STAGING', @now, @now
         )`,
      ).run(params);
    });
    transaction.immediate();
    return this.requireMaterialization(input.thread, input.materializationId);
  }

  appendTimelinePage(input: TimelinePageInput): TimelinePageRecord {
    this.assertLease();
    assertAuthenticatedContext(input.context, input.thread);
    assertId(input.materializationId, "materializationId");
    assertOrdinal(input.pageIndex, "pageIndex");
    if (input.previousPageDigest) assertDigest(input.previousPageDigest, "previousPageDigest");
    validateTimelinePage(input);
    const pageBody = {
      pageIndex: input.pageIndex,
      ...(input.previousPageDigest ? { previousPageDigest: input.previousPageDigest } : {}),
      items: input.items,
      gaps: input.gaps,
      coverageIslands: input.coverageIslands,
    };
    const { canonical: bodyJson, digest: pageDigest } = sha256CanonicalJson(
      pageBody,
      TIMELINE_PAGE_MAX_BYTES,
    );
    const bodyBytes = Buffer.byteLength(bodyJson, "utf8");
    const now = this.clock();
    const transaction = this.database.transaction(() => {
      this.fenceLeaseInTransaction();
      const materialization = this.requireMaterialization(input.thread, input.materializationId);
      assertExactEpoch(materialization.sourceEpoch, input.context.sourceEpoch);
      if (materialization.state !== "STAGING") {
        throw new ConversationStoreError("TIMELINE_CANDIDATE_REJECTED", "materialization is not staging");
      }
      if (materialization.pageCount !== input.pageIndex) {
        throw new ConversationStoreError("TIMELINE_PAGE_CHAIN_INVALID", "page index is not contiguous");
      }
      const expectedPrevious = input.pageIndex === 0
        ? undefined
        : (this.database.prepare(
            `SELECT page_digest FROM timeline_page WHERE
             bridge_identity_id=@bridgeIdentityId AND bridge_instance_id=@bridgeInstanceId AND
             codex_source_id=@codexSourceId AND provider_thread_id=@providerThreadId AND
             materialization_id=@materializationId AND page_index=@previousIndex`,
          ).get({
            ...threadParams(input.thread),
            materializationId: input.materializationId,
            previousIndex: input.pageIndex - 1,
          }) as { page_digest: string } | undefined)?.page_digest;
      if (expectedPrevious !== input.previousPageDigest) {
        throw new ConversationStoreError("TIMELINE_PAGE_CHAIN_INVALID", "previous page digest mismatch");
      }
      if (
        materialization.itemCount + input.items.length > MAX_TIMELINE_ITEMS ||
        materialization.gapCount + input.gaps.length > MAX_TIMELINE_ITEMS ||
        materialization.totalBytes + bodyBytes > MAX_TIMELINE_BYTES
      ) {
        throw new ConversationStoreError("PAYLOAD_TOO_LARGE", "timeline materialization limit exceeded");
      }
      const params = {
        ...threadParams(input.thread),
        materializationId: input.materializationId,
        pageIndex: input.pageIndex,
        previousPageDigest: input.previousPageDigest ?? null,
        pageDigest,
        itemCount: input.items.length,
        gapCount: input.gaps.length,
        bodyBytes,
        bodyJson,
        now,
      };
      this.database.prepare(
        `INSERT INTO timeline_page (
           bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id,
           materialization_id, page_index, previous_page_digest, page_digest, item_count,
           gap_count, body_bytes, body_json, created_at
         ) VALUES (
           @bridgeIdentityId, @bridgeInstanceId, @codexSourceId, @providerThreadId,
           @materializationId, @pageIndex, @previousPageDigest, @pageDigest, @itemCount,
           @gapCount, @bodyBytes, @bodyJson, @now
         )`,
      ).run(params);
      this.insertTimelinePageRows(input);
      this.database.prepare(
        `UPDATE timeline_materialization SET
           page_count=page_count+1, item_count=item_count+@itemCount,
           gap_count=gap_count+@gapCount, total_bytes=total_bytes+@bodyBytes, updated_at=@now
         WHERE bridge_identity_id=@bridgeIdentityId AND bridge_instance_id=@bridgeInstanceId AND
           codex_source_id=@codexSourceId AND provider_thread_id=@providerThreadId AND
           materialization_id=@materializationId AND state='STAGING'`,
      ).run(params);
      this.inject("timeline.after-page");
    });
    transaction.immediate();
    return {
      materializationId: input.materializationId,
      pageIndex: input.pageIndex,
      ...(input.previousPageDigest ? { previousPageDigest: input.previousPageDigest } : {}),
      pageDigest,
      itemCount: input.items.length,
      gapCount: input.gaps.length,
      bodyBytes,
    };
  }

  sealTimelineMaterialization(input: TimelineSealInput): TimelineReadback {
    this.assertLease();
    assertAuthenticatedContext(input.context, input.thread);
    assertId(input.materializationId, "materializationId");
    assertExpectedRevision(input.expectedHeadRevision);
    for (const [label, value] of [
      ["expectedPageCount", input.expectedPageCount],
      ["expectedItemCount", input.expectedItemCount],
      ["expectedGapCount", input.expectedGapCount],
    ] as const) assertOrdinal(value, label);
    if (input.expectedLastPageDigest) assertDigest(input.expectedLastPageDigest, "expectedLastPageDigest");
    const now = this.clock();
    const transaction = this.database.transaction(() => {
      this.fenceLeaseInTransaction();
      const materialization = this.requireMaterialization(input.thread, input.materializationId);
      assertExactEpoch(materialization.sourceEpoch, input.context.sourceEpoch);
      if (materialization.state !== "STAGING") {
        throw new ConversationStoreError("TIMELINE_CANDIDATE_REJECTED", "only staging materializations can seal");
      }
      if (
        materialization.pageCount !== input.expectedPageCount ||
        materialization.itemCount !== input.expectedItemCount ||
        materialization.gapCount !== input.expectedGapCount
      ) {
        throw new ConversationStoreError("TIMELINE_PAGE_CHAIN_INVALID", "materialization counts do not close");
      }
      const pages = this.listTimelinePages(input.thread, input.materializationId);
      verifyPageChain(pages, input.expectedLastPageDigest);
      const items = this.listAllTimelineItems(input.thread, input.materializationId);
      const gaps = this.listAllTimelineGaps(input.thread, input.materializationId);
      const islands = this.listAllTimelineIslands(input.thread, input.materializationId);
      verifyPageChildren(pages, items, gaps, islands);
      verifyTimelineCoverage(materialization.evidence, items, gaps, islands, input.emptyProof, materialization.readEvidenceDigest);
      const orderDigest = sha256CanonicalJson(
        items.map((item) => ({
          providerTurnId: item.providerTurnId,
          itemId: item.itemId,
          turnOrdinal: item.turnOrdinal,
          itemOrdinal: item.itemOrdinal,
          timelineOrdinal: item.timelineOrdinal,
        })),
        MAX_TIMELINE_BYTES,
      ).digest;
      const coverageDigest = sha256CanonicalJson(
        { islands, gaps },
        MAX_TIMELINE_BYTES,
      ).digest;
      const materializationDigest = sha256CanonicalJson(
        {
          materializationId: input.materializationId,
          readEvidenceDigest: materialization.readEvidenceDigest,
          pageDigests: pages.map((page) => page.page_digest),
          orderDigest,
          coverageDigest,
          itemCount: items.length,
          gapCount: gaps.length,
        },
        MAX_TIMELINE_BYTES,
      ).digest;
      const emptyProofJson = input.emptyProof
        ? canonicalizeJson(input.emptyProof, { maxBytes: OPERATION_JSON_MAX_BYTES, requireObject: true })
        : null;
      const params = {
        ...threadParams(input.thread),
        materializationId: input.materializationId,
        materializationDigest,
        orderDigest,
        coverageDigest,
        emptyProofJson,
        now,
      };
      const sealResult = this.database.prepare(
        `UPDATE timeline_materialization SET state='SEALED', materialization_digest=@materializationDigest,
           order_digest=@orderDigest, coverage_digest=@coverageDigest, empty_proof_json=@emptyProofJson,
           verified_at=@now, updated_at=@now
         WHERE bridge_identity_id=@bridgeIdentityId AND bridge_instance_id=@bridgeInstanceId AND
           codex_source_id=@codexSourceId AND provider_thread_id=@providerThreadId AND
           materialization_id=@materializationId AND state='STAGING'`,
      ).run(params);
      if (sealResult.changes !== 1) {
        throw new ConversationStoreError("TIMELINE_CANDIDATE_REJECTED", "materialization seal CAS failed");
      }
      this.inject("timeline.after-materialization-seal");
      const head = this.database.prepare(
        `SELECT revision FROM timeline_head WHERE bridge_identity_id=@bridgeIdentityId AND
         bridge_instance_id=@bridgeInstanceId AND codex_source_id=@codexSourceId AND
         provider_thread_id=@providerThreadId`,
      ).get(params) as { revision: number } | undefined;
      if ((head?.revision ?? 0) !== input.expectedHeadRevision) {
        throw new ConversationStoreError("REVISION_CONFLICT", "timeline head revision changed");
      }
      if (head) {
        const result = this.database.prepare(
          `UPDATE timeline_head SET revision=revision+1, materialization_id=@materializationId, updated_at=@now
           WHERE bridge_identity_id=@bridgeIdentityId AND bridge_instance_id=@bridgeInstanceId AND
             codex_source_id=@codexSourceId AND provider_thread_id=@providerThreadId AND
             revision=@expectedHeadRevision`,
        ).run({ ...params, expectedHeadRevision: input.expectedHeadRevision });
        if (result.changes !== 1) {
          throw new ConversationStoreError("REVISION_CONFLICT", "timeline head CAS failed");
        }
      } else {
        this.database.prepare(
          `INSERT INTO timeline_head (
             bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id,
             revision, materialization_id, updated_at
           ) VALUES (
             @bridgeIdentityId, @bridgeInstanceId, @codexSourceId, @providerThreadId,
             1, @materializationId, @now
           )`,
        ).run(params);
      }
      this.inject("timeline.after-head-cas");
      this.inject("timeline.before-commit");
    });
    transaction.immediate();
    return this.requireTimeline(input.thread);
  }

  readTimeline(thread: ThreadRef, options: TimelineReadOptions = {}): TimelineReadback | undefined {
    this.assertLease();
    assertThread(thread);
    const limit = options.limit ?? 200;
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 200) {
      throw new RangeError("timeline read limit must be between 1 and 200");
    }
    if (options.startTimelineOrdinal !== undefined) {
      assertSignedOrdinal(options.startTimelineOrdinal, "startTimelineOrdinal");
    }
    const params = {
      ...threadParams(thread),
      limit,
      start: options.startTimelineOrdinal ?? 0,
    };
    const head = this.database.prepare(
      `SELECT h.revision AS head_revision, m.* FROM timeline_head h
       JOIN timeline_materialization m ON
         m.bridge_identity_id=h.bridge_identity_id AND m.bridge_instance_id=h.bridge_instance_id AND
         m.codex_source_id=h.codex_source_id AND m.provider_thread_id=h.provider_thread_id AND
         m.materialization_id=h.materialization_id
       WHERE h.bridge_identity_id=@bridgeIdentityId AND h.bridge_instance_id=@bridgeInstanceId AND
         h.codex_source_id=@codexSourceId AND h.provider_thread_id=@providerThreadId`,
    ).get(params) as TimelineHeadRow | undefined;
    if (!head) return undefined;
    verifyStoredTimelineReceipt(
      head,
      this.listTimelinePages(thread, head.materialization_id),
      this.listAllTimelineItems(thread, head.materialization_id),
      this.listAllTimelineGaps(thread, head.materialization_id),
      this.listAllTimelineIslands(thread, head.materialization_id),
    );
    const itemRows = this.database.prepare(
      `SELECT item_id,provider_turn_id,turn_ordinal,item_ordinal,timeline_ordinal,item_kind,payload_json
       FROM timeline_item WHERE bridge_identity_id=@bridgeIdentityId AND
         bridge_instance_id=@bridgeInstanceId AND codex_source_id=@codexSourceId AND
         provider_thread_id=@providerThreadId AND materialization_id=@materializationId
         ${options.startTimelineOrdinal === undefined ? "" : "AND timeline_ordinal >= @start"}
       ORDER BY timeline_ordinal ${options.startTimelineOrdinal === undefined ? "DESC" : "ASC"} LIMIT @limit`,
    ).all({ ...params, materializationId: head.materialization_id }) as TimelineItemRow[];
    const gapRows = this.database.prepare(
      `SELECT gap_id,gap_ordinal,gap_kind,first_missing_timeline_ordinal,last_missing_timeline_ordinal,
              reason,descriptor_json FROM timeline_gap
       WHERE bridge_identity_id=@bridgeIdentityId AND bridge_instance_id=@bridgeInstanceId AND
         codex_source_id=@codexSourceId AND provider_thread_id=@providerThreadId AND
         materialization_id=@materializationId
       ORDER BY gap_ordinal LIMIT @limit`,
    ).all({ ...params, materializationId: head.materialization_id }) as TimelineGapRow[];
    const islandRows = this.database.prepare(
      `SELECT island_id,island_ordinal,first_timeline_ordinal,last_timeline_ordinal,
              structural_coverage,payload_coverage FROM timeline_coverage_island
       WHERE bridge_identity_id=@bridgeIdentityId AND bridge_instance_id=@bridgeInstanceId AND
         codex_source_id=@codexSourceId AND provider_thread_id=@providerThreadId AND
         materialization_id=@materializationId ORDER BY island_ordinal LIMIT @limit`,
    ).all({ ...params, materializationId: head.materialization_id }) as TimelineIslandRow[];
    if (options.startTimelineOrdinal === undefined) itemRows.reverse();
    return timelineReadbackFromRows(thread, head, itemRows, gapRows, islandRows);
  }

  recordTimelineReadAttempt(input: TimelineReadAttemptInput): TimelineReadAttemptRecord {
    this.assertLease();
    assertAuthenticatedContext(input.context, input.thread);
    assertId(input.attemptId, "attemptId");
    const sourceEpochJson = canonicalizeJson(input.context.sourceEpoch, {
      maxBytes: OPERATION_JSON_MAX_BYTES,
      requireObject: true,
    });
    const evidenceDigest = input.evidence
      ? sha256CanonicalJson(input.evidence, OPERATION_JSON_MAX_BYTES).digest
      : undefined;
    const problemJson = canonicalizeJsonObject(input.problem, OPERATION_JSON_MAX_BYTES);
    const now = this.clock();
    const transaction = this.database.transaction(() => {
      this.fenceLeaseInTransaction();
      this.ensureSource(input.thread.sourcePartition);
      this.database.prepare(
        `INSERT INTO timeline_read_attempt (
           attempt_id,bridge_identity_id,bridge_instance_id,codex_source_id,provider_thread_id,
           connection_generation,provider_generation,source_epoch_json,outcome,evidence_digest,
           problem_json,observed_at
         ) VALUES (
           @attemptId,@bridgeIdentityId,@bridgeInstanceId,@codexSourceId,@providerThreadId,
           @connectionGeneration,@providerGeneration,@sourceEpochJson,@outcome,@evidenceDigest,
           @problemJson,@now
         )`,
      ).run({
        ...threadParams(input.thread),
        attemptId: input.attemptId,
        connectionGeneration: input.context.sourceEpoch.connectionGeneration,
        providerGeneration: input.context.sourceEpoch.providerGeneration,
        sourceEpochJson,
        outcome: input.outcome,
        evidenceDigest: evidenceDigest ?? null,
        problemJson,
        now,
      });
    });
    transaction.immediate();
    return {
      attemptId: input.attemptId,
      thread: input.thread,
      sourceEpoch: input.context.sourceEpoch,
      outcome: input.outcome,
      ...(evidenceDigest ? { evidenceDigest } : {}),
      problem: input.problem,
      observedAt: now,
    };
  }

  admitOperation(admission: OperationAdmission): { kind: "ADMITTED" | "IDEMPOTENT"; operation: OperationRecord } {
    this.assertLease();
    if (!DIRECT_ADMISSION_CODES.has(admission.operationCode)) {
      throw new ConversationStoreError(
        "INVALID_STATE_TRANSITION",
        "queue and interaction operations require their transactional domain barrier",
      );
    }
    const prepared = prepareAdmission(admission);
    let kind: "ADMITTED" | "IDEMPOTENT" = "ADMITTED";
    this.inject("operation.before-transaction");
    const transaction = this.database.transaction(() => {
      this.fenceLeaseInTransaction();
      kind = this.admitOperationInTransaction(admission, prepared);
      this.inject("operation.before-commit");
    });
    transaction.immediate();
    this.inject("operation.after-commit-before-readback");
    return { kind, operation: this.requireOperation(admission.thread, admission.operationId) };
  }

  beginIdleDispatch(input: DispatchStartInput): OperationRecord {
    this.assertLease();
    assertAuthenticatedContext(input.context, input.thread);
    assertId(input.operationId, "operationId");
    assertExpectedRevision(input.expectedOperationRevision);
    assertId(input.dispatchAttemptId, "dispatchAttemptId");
    const transaction = this.database.transaction(() => {
      this.fenceLeaseInTransaction();
      const operation = this.requireOperation(input.thread, input.operationId);
      assertExactEpoch(operation.sourceEpoch, input.context.sourceEpoch);
      if (operation.state !== "DURABLY_ADMITTED" || operation.revision !== input.expectedOperationRevision) {
        throw new ConversationStoreError("INVALID_STATE_TRANSITION", "operation is not safe for first dispatch");
      }
      const blockingUnknown = this.findBlockingUnknownOutcome(
        input.thread,
        operation.conflictFamily,
        operation.operationId,
      );
      if (blockingUnknown) {
        throw new ConversationStoreError(
          "BLOCKED_BY_UNKNOWN_OUTCOME",
          `dispatch blocked by outcome-unknown operation ${blockingUnknown}`,
        );
      }
      this.updateOperationState(operation, "CALL_STARTED", {
        eventKind: "CALL_STARTED",
        dispatchAttemptId: input.dispatchAttemptId,
      });
      this.inject("operation.before-commit");
    });
    transaction.immediate();
    this.inject("operation.after-commit-before-readback");
    return this.requireOperation(input.thread, input.operationId);
  }

  transitionOperation(transition: OperationTransition): OperationRecord {
    this.assertLease();
    assertAuthenticatedContext(transition.context, transition.thread);
    assertId(transition.operationId, "operationId");
    assertExpectedRevision(transition.expectedRevision);
    assertId(transition.dispatchAttemptId, "dispatchAttemptId");
    if (transition.providerTurnId) assertId(transition.providerTurnId, "providerTurnId");
    const detailsJson = transition.details
      ? canonicalizeJsonObject(transition.details, OPERATION_JSON_MAX_BYTES)
      : undefined;
    const transaction = this.database.transaction(() => {
      this.fenceLeaseInTransaction();
      const operation = this.requireOperation(transition.thread, transition.operationId);
      assertExactEpoch(operation.sourceEpoch, transition.context.sourceEpoch);
      if (operation.revision !== transition.expectedRevision) {
        throw new ConversationStoreError("REVISION_CONFLICT", "operation revision changed");
      }
      if (operation.state === "OUTCOME_UNKNOWN") {
        throw new ConversationStoreError("INVALID_STATE_TRANSITION", "OUTCOME_UNKNOWN has no state edge");
      }
      if (operation.dispatchAttemptId !== transition.dispatchAttemptId) {
        throw new ConversationStoreError("IDENTITY_CONFLICT", "dispatch attempt mismatch");
      }
      if (transition.toState === "PROVIDER_ACCEPTED") {
        if (
          operation.state !== "CALL_STARTED" || !transition.providerTurnId ||
          transition.providerEvidence !== "SERVER_RESPONSE"
        ) {
          throw new ConversationStoreError("IDENTITY_CONFLICT", "provider acceptance requires exact response fact");
        }
      } else if (transition.toState === "CANONICAL_OBSERVED") {
        if (
          operation.state !== "PROVIDER_ACCEPTED" || !transition.providerTurnId ||
          transition.providerEvidence !== "VERIFIED_CANONICAL_FACT" ||
          (operation.providerTurnId && operation.providerTurnId !== transition.providerTurnId)
        ) {
          throw new ConversationStoreError("IDENTITY_CONFLICT", "canonical observation requires exact verified fact");
        }
      } else if (transition.toState === "SUCCEEDED") {
        if (operation.state !== "CANONICAL_OBSERVED" || transition.providerEvidence !== "VERIFIED_CANONICAL_FACT") {
          throw new ConversationStoreError("INVALID_STATE_TRANSITION", "success requires canonical observation");
        }
      } else if (transition.toState === "REJECTED") {
        if (operation.state !== "CALL_STARTED" || transition.providerEvidence !== "SERVER_RESPONSE") {
          throw new ConversationStoreError("INVALID_STATE_TRANSITION", "rejection requires exact server response");
        }
      }
      this.updateOperationState(operation, transition.toState, {
        eventKind: transition.eventKind,
        dispatchAttemptId: transition.dispatchAttemptId,
        providerTurnId: transition.providerTurnId,
        detailsJson,
      });
      if (transition.toState === "PROVIDER_ACCEPTED" || transition.toState === "REJECTED") {
        this.consumeReservedEntryForOperation(operation.operationId);
      }
      this.inject("operation.before-commit");
    });
    transaction.immediate();
    this.inject("operation.after-commit-before-readback");
    return this.requireOperation(transition.thread, transition.operationId);
  }

  getOperation(thread: ThreadRef, operationId: string): OperationRecord | undefined {
    this.assertLease();
    assertThread(thread);
    assertId(operationId, "operationId");
    const row = this.database.prepare(
      `SELECT * FROM operation WHERE operation_id=@operationId AND
       bridge_identity_id=@bridgeIdentityId AND bridge_instance_id=@bridgeInstanceId AND
       codex_source_id=@codexSourceId AND provider_thread_id=@providerThreadId`,
    ).get({ ...threadParams(thread), operationId }) as OperationRow | undefined;
    return row ? operationFromRow(row) : undefined;
  }

  listOperationEvents(thread: ThreadRef, operationId: string): OperationEventRecord[] {
    this.assertLease();
    this.requireOperation(thread, operationId);
    const rows = this.database.prepare(
      `SELECT operation_id,event_sequence,from_state,to_state,event_kind,dispatch_attempt_id,
              provider_turn_id,details_json FROM operation_event
       WHERE operation_id=? ORDER BY event_sequence`,
    ).all(operationId) as OperationEventRow[];
    return rows.map((row) => ({
      operationId: row.operation_id,
      sequence: row.event_sequence,
      ...(row.from_state ? { fromState: row.from_state } : {}),
      toState: row.to_state,
      kind: row.event_kind,
      ...(row.dispatch_attempt_id ? { dispatchAttemptId: row.dispatch_attempt_id } : {}),
      ...(row.provider_turn_id ? { providerTurnId: row.provider_turn_id } : {}),
      ...(row.details_json ? { details: parseStoredJsonObject(row.details_json) } : {}),
    }));
  }

  listOperationsRequiringReconcile(): OperationRecord[] {
    this.assertLease();
    return (this.database.prepare(
      "SELECT * FROM operation WHERE state='OUTCOME_UNKNOWN' AND reconcile_required=1 ORDER BY updated_at,operation_id",
    ).all() as OperationRow[]).map(operationFromRow);
  }

  recordReconcileFact(input: ReconcileFactInput): ReconcileResolutionRecord {
    this.assertLease();
    assertAuthenticatedContext(input.context, input.thread);
    assertId(input.operationId, "operationId");
    assertId(input.reconcileRoundId, "reconcileRoundId");
    assertId(input.factId, "factId");
    if (input.providerTurnId) assertId(input.providerTurnId, "providerTurnId");
    validateVerifiedReconcileFact(input);
    const { canonical: evidenceJson, digest: evidenceDigest } = sha256CanonicalJson(
      input.evidence,
      OPERATION_JSON_MAX_BYTES,
    );
    const projectedOutcome = reconcileProjectedOutcome(input.factKind);
    const now = this.clock();
    const transaction = this.database.transaction(() => {
      this.fenceLeaseInTransaction();
      const operation = this.requireOperation(input.thread, input.operationId);
      assertExactEpoch(operation.sourceEpoch, input.context.sourceEpoch);
      if (operation.state !== "OUTCOME_UNKNOWN" || !operation.reconcileRequired) {
        throw new ConversationStoreError("INVALID_STATE_TRANSITION", "operation is not outcome-unknown");
      }
      if (
        input.factKind === "CANONICAL_OBSERVED" &&
        (!input.providerTurnId || (operation.providerTurnId && operation.providerTurnId !== input.providerTurnId))
      ) {
        throw new ConversationStoreError("IDENTITY_CONFLICT", "canonical reconcile fact lacks exact provider turn");
      }
      this.database.prepare(
        `INSERT INTO reconcile_round (operation_id,reconcile_round_id,created_at)
         VALUES (?,?,?)`,
      ).run(input.operationId, input.reconcileRoundId, now);
      this.database.prepare(
        `INSERT INTO reconcile_fact (
           operation_id,reconcile_round_id,fact_id,fact_kind,evidence_digest,evidence_json,
           provider_turn_id,created_at
         ) VALUES (?,?,?,?,?,?,?,?)`,
      ).run(
        input.operationId,
        input.reconcileRoundId,
        input.factId,
        input.factKind,
        evidenceDigest,
        evidenceJson,
        input.providerTurnId ?? null,
        now,
      );
      this.database.prepare(
        `INSERT INTO reconcile_resolution (
           operation_id,reconcile_round_id,fact_id,projected_outcome,evidence_digest,resolved_at
         ) VALUES (?,?,?,?,?,?)`,
      ).run(input.operationId, input.reconcileRoundId, input.factId, projectedOutcome, evidenceDigest, now);
    });
    transaction.immediate();
    return {
      operationId: input.operationId,
      reconcileRoundId: input.reconcileRoundId,
      factId: input.factId,
      projectedOutcome,
      evidenceDigest,
      resolvedAt: now,
    };
  }

  listReconcileResolutions(operationId: string): ReconcileResolutionRecord[] {
    this.assertLease();
    assertId(operationId, "operationId");
    return (this.database.prepare(
      `SELECT operation_id,reconcile_round_id,fact_id,projected_outcome,evidence_digest,resolved_at
       FROM reconcile_resolution WHERE operation_id=? ORDER BY resolved_at,reconcile_round_id`,
    ).all(operationId) as Array<{
      operation_id: string;
      reconcile_round_id: string;
      fact_id: string;
      projected_outcome: ReconcileResolutionRecord["projectedOutcome"];
      evidence_digest: string;
      resolved_at: number;
    }>).map((row) => ({
      operationId: row.operation_id,
      reconcileRoundId: row.reconcile_round_id,
      factId: row.fact_id,
      projectedOutcome: row.projected_outcome,
      evidenceDigest: row.evidence_digest,
      resolvedAt: row.resolved_at,
    }));
  }

  openQueueLane(thread: ThreadRef, laneFamily: string, capacity = 16): QueueLaneRecord {
    this.assertLease();
    assertThread(thread);
    assertId(laneFamily, "laneFamily");
    assertQueueCapacity(capacity);
    const transaction = this.database.transaction(() => {
      this.fenceLeaseInTransaction();
      this.ensureSource(thread.sourcePartition);
      const existing = this.readQueueLane(thread, laneFamily);
      if (existing) {
        if (existing.capacity !== capacity) {
          throw new ConversationStoreError("QUEUE_REVISION_CONFLICT", "queue lane capacity differs");
        }
        return;
      }
      this.database.prepare(
        `INSERT INTO queue_lane (
           bridge_identity_id,bridge_instance_id,codex_source_id,provider_thread_id,lane_family,
           revision,next_fifo_ordinal,active_count,capacity,updated_at
         ) VALUES (@bridgeIdentityId,@bridgeInstanceId,@codexSourceId,@providerThreadId,@laneFamily,
           1,0,0,@capacity,@now)`,
      ).run({ ...threadParams(thread), laneFamily, capacity, now: this.clock() });
    });
    transaction.immediate();
    return this.requireQueueLane(thread, laneFamily);
  }

  admitAndQueue(input: QueueAdmissionInput): {
    kind: "ADMITTED" | "IDEMPOTENT";
    operation: OperationRecord;
    entry: QueueEntryRecord;
    lane: QueueLaneRecord;
  } {
    this.assertLease();
    if (input.admission.operationCode !== "OP-001") {
      throw new ConversationStoreError("INVALID_STATE_TRANSITION", "queue root must be OP-001");
    }
    const prepared = prepareAdmission(input.admission);
    assertId(input.laneFamily, "laneFamily");
    assertId(input.queueEntryId, "queueEntryId");
    assertExpectedRevision(input.expectedLaneRevision);
    const capacity = input.capacity ?? 16;
    assertQueueCapacity(capacity);
    let kind: "ADMITTED" | "IDEMPOTENT" = "ADMITTED";
    const transaction = this.database.transaction(() => {
      this.fenceLeaseInTransaction();
      const existing = this.findOperationByAdmissionKey(
        input.admission.thread,
        input.admission.clientInstanceId,
        input.admission.clientMessageId,
      );
      if (existing) {
        assertExistingAdmission(existing, input.admission, prepared.fingerprint);
        const existingEntry = this.findQueueEntryByRoot(existing.operationId);
        if (!existingEntry || existingEntry.queueEntryId !== input.queueEntryId) {
          throw new ConversationStoreError("OPERATION_ID_CONFLICT", "queued replay does not match root entry");
        }
        kind = "IDEMPOTENT";
        return;
      }
      kind = this.admitOperationInTransaction(input.admission, prepared);
      let lane = this.readQueueLane(input.admission.thread, input.laneFamily);
      if (!lane) {
        if (input.expectedLaneRevision !== 0) {
          throw new ConversationStoreError("QUEUE_REVISION_CONFLICT", "queue lane does not exist");
        }
        this.database.prepare(
          `INSERT INTO queue_lane (
             bridge_identity_id,bridge_instance_id,codex_source_id,provider_thread_id,lane_family,
             revision,next_fifo_ordinal,active_count,capacity,updated_at
           ) VALUES (@bridgeIdentityId,@bridgeInstanceId,@codexSourceId,@providerThreadId,@laneFamily,
             1,0,0,@capacity,@now)`,
        ).run({
          ...threadParams(input.admission.thread),
          laneFamily: input.laneFamily,
          capacity,
          now: this.clock(),
        });
        lane = this.requireQueueLane(input.admission.thread, input.laneFamily);
      } else if (lane.revision !== input.expectedLaneRevision || lane.capacity !== capacity) {
        throw new ConversationStoreError("QUEUE_REVISION_CONFLICT", "queue lane revision changed");
      }
      if (lane.activeCount >= lane.capacity) {
        throw new ConversationStoreError("QUEUE_FULL", "queue lane is full");
      }
      const payloadJson = canonicalizeJsonObject(input.admission.payload.body, OPERATION_JSON_MAX_BYTES);
      const payloadDigest = sha256Text(payloadJson);
      const params = {
        ...threadParams(input.admission.thread),
        laneFamily: input.laneFamily,
        queueEntryId: input.queueEntryId,
        rootOperationId: input.admission.operationId,
        fifoOrdinal: lane.nextFifoOrdinal,
        expectedLaneRevision: lane.revision,
        payloadDigest,
        payloadJson,
        now: this.clock(),
      };
      this.updateOperationState(this.requireOperation(input.admission.thread, input.admission.operationId), "QUEUED", {
        eventKind: "QUEUED",
      });
      this.inject("queue.after-operation");
      this.database.prepare(
        `INSERT INTO queue_entry (
           bridge_identity_id,bridge_instance_id,codex_source_id,provider_thread_id,lane_family,
           queue_entry_id,root_operation_id,fifo_ordinal,entry_revision,state,payload_digest,payload_json,updated_at
         ) VALUES (
           @bridgeIdentityId,@bridgeInstanceId,@codexSourceId,@providerThreadId,@laneFamily,
           @queueEntryId,@rootOperationId,@fifoOrdinal,1,'QUEUED',@payloadDigest,@payloadJson,@now
         )`,
      ).run(params);
      this.inject("queue.after-entry");
      const laneResult = this.database.prepare(
        `UPDATE queue_lane SET revision=revision+1,next_fifo_ordinal=next_fifo_ordinal+1,
           active_count=active_count+1,updated_at=@now
         WHERE bridge_identity_id=@bridgeIdentityId AND bridge_instance_id=@bridgeInstanceId AND
           codex_source_id=@codexSourceId AND provider_thread_id=@providerThreadId AND
           lane_family=@laneFamily AND revision=@expectedLaneRevision AND active_count < capacity`,
      ).run(params);
      if (laneResult.changes !== 1) {
        throw new ConversationStoreError("QUEUE_REVISION_CONFLICT", "queue lane CAS failed");
      }
      this.inject("queue.after-lane-cas");
      this.inject("queue.before-commit");
    });
    transaction.immediate();
    return {
      kind,
      operation: this.requireOperation(input.admission.thread, input.admission.operationId),
      entry: this.requireQueueEntry(input.admission.thread, input.laneFamily, input.queueEntryId),
      lane: this.requireQueueLane(input.admission.thread, input.laneFamily),
    };
  }

  controlQueueEntry(input: QueueControlInput): {
    kind: "RECORDED" | "IDEMPOTENT";
    controlOperation: OperationRecord;
    rootOperation: OperationRecord;
    entry: QueueEntryRecord;
    lane: QueueLaneRecord;
  } {
    this.assertLease();
    const action = input.admission.operationCode === "OP-002"
      ? "EDIT"
      : input.admission.operationCode === "OP-003"
        ? "CANCEL"
        : undefined;
    if (!action) throw new ConversationStoreError("INVALID_STATE_TRANSITION", "queue control must be OP-002 or OP-003");
    if (action === "EDIT" && !input.replacementPayload) {
      throw new ConversationStoreError("QUEUE_ENTRY_NOT_EDITABLE", "edit requires replacement payload");
    }
    const prepared = prepareAdmission(input.admission);
    assertId(input.laneFamily, "laneFamily");
    assertId(input.queueEntryId, "queueEntryId");
    assertExpectedRevision(input.expectedLaneRevision);
    assertExpectedRevision(input.expectedEntryRevision);
    const replacementJson = input.replacementPayload
      ? canonicalizeJsonObject(input.replacementPayload, OPERATION_JSON_MAX_BYTES)
      : undefined;
    if (
      input.admission.preconditions.expectedLaneRevision !== input.expectedLaneRevision ||
      input.admission.preconditions.expectedEntryRevision !== input.expectedEntryRevision ||
      input.admission.target.targetKind !== "QUEUE_ENTRY" ||
      input.admission.target.queueEntryId !== input.queueEntryId ||
      (action === "EDIT" &&
        canonicalizeJsonObject(input.admission.payload.body, OPERATION_JSON_MAX_BYTES) !== replacementJson)
    ) {
      throw new ConversationStoreError("INVALID_STATE_TRANSITION", "queue control envelope does not match target mutation");
    }
    const queueTarget = input.admission.target as Extract<
      OperationRecord["target"],
      { targetKind: "QUEUE_ENTRY" }
    >;
    let kind: "RECORDED" | "IDEMPOTENT" = "RECORDED";
    const transaction = this.database.transaction(() => {
      this.fenceLeaseInTransaction();
      const existing = this.findOperationByAdmissionKey(
        input.admission.thread,
        input.admission.clientInstanceId,
        input.admission.clientMessageId,
      );
      if (existing) {
        assertExistingAdmission(existing, input.admission, prepared.fingerprint);
        if (existing.state !== "SUCCEEDED") {
          throw new ConversationStoreError("OPERATION_ID_CONFLICT", "queue control replay is incomplete");
        }
        kind = "IDEMPOTENT";
        return;
      }
      const lane = this.requireQueueLane(input.admission.thread, input.laneFamily);
      const entry = this.requireQueueEntry(input.admission.thread, input.laneFamily, input.queueEntryId);
      const root = this.requireOperation(input.admission.thread, entry.rootOperationId);
      if (queueTarget.rootOperationId !== entry.rootOperationId) {
        throw new ConversationStoreError("IDENTITY_CONFLICT", "queue control root operation mismatch");
      }
      if (lane.revision !== input.expectedLaneRevision) {
        throw new ConversationStoreError("QUEUE_REVISION_CONFLICT", "queue lane revision changed");
      }
      if (entry.revision !== input.expectedEntryRevision) {
        throw new ConversationStoreError("ENTRY_REVISION_CONFLICT", "queue entry revision changed");
      }
      if (entry.state !== "QUEUED" || root.state !== "QUEUED") {
        throw new ConversationStoreError(
          action === "EDIT" ? "QUEUE_ENTRY_NOT_EDITABLE" : "QUEUE_ENTRY_NOT_CANCELLABLE",
          "queue entry is no longer queued",
        );
      }
      this.admitOperationInTransaction(input.admission, prepared);
      const now = this.clock();
      if (action === "CANCEL") this.updateOperationState(root, "CANCELLED", { eventKind: "QUEUE_CANCELLED" });
      const entryResult = action === "EDIT"
        ? this.database.prepare(
            `UPDATE queue_entry SET entry_revision=entry_revision+1,payload_digest=@payloadDigest,
               payload_json=@payloadJson,updated_at=@now
             WHERE bridge_identity_id=@bridgeIdentityId AND bridge_instance_id=@bridgeInstanceId AND
               codex_source_id=@codexSourceId AND provider_thread_id=@providerThreadId AND
               lane_family=@laneFamily AND queue_entry_id=@queueEntryId AND
               entry_revision=@expectedEntryRevision AND state='QUEUED'`,
          ).run({
            ...threadParams(input.admission.thread),
            laneFamily: input.laneFamily,
            queueEntryId: input.queueEntryId,
            expectedEntryRevision: input.expectedEntryRevision,
            payloadDigest: sha256Text(replacementJson!),
            payloadJson: replacementJson,
            now,
          })
        : this.database.prepare(
            `UPDATE queue_entry SET entry_revision=entry_revision+1,state='CANCELLED',updated_at=@now
             WHERE bridge_identity_id=@bridgeIdentityId AND bridge_instance_id=@bridgeInstanceId AND
               codex_source_id=@codexSourceId AND provider_thread_id=@providerThreadId AND
               lane_family=@laneFamily AND queue_entry_id=@queueEntryId AND
               entry_revision=@expectedEntryRevision AND state='QUEUED'`,
          ).run({
            ...threadParams(input.admission.thread),
            laneFamily: input.laneFamily,
            queueEntryId: input.queueEntryId,
            expectedEntryRevision: input.expectedEntryRevision,
            now,
          });
      if (entryResult.changes !== 1) throw new ConversationStoreError("ENTRY_REVISION_CONFLICT", "entry CAS failed");
      this.inject("queue.after-entry");
      this.updateOperationState(
        this.requireOperation(input.admission.thread, input.admission.operationId),
        "SUCCEEDED",
        { eventKind: "LOCAL_CONTROL_SUCCEEDED", allowLocalSuccess: true },
      );
      this.inject("queue.after-operation");
      const laneResult = this.database.prepare(
        `UPDATE queue_lane SET revision=revision+1,active_count=active_count-@decrement,updated_at=@now
         WHERE bridge_identity_id=@bridgeIdentityId AND bridge_instance_id=@bridgeInstanceId AND
           codex_source_id=@codexSourceId AND provider_thread_id=@providerThreadId AND
           lane_family=@laneFamily AND revision=@expectedLaneRevision AND active_count>=@decrement`,
      ).run({
        ...threadParams(input.admission.thread),
        laneFamily: input.laneFamily,
        expectedLaneRevision: input.expectedLaneRevision,
        decrement: action === "CANCEL" ? 1 : 0,
        now,
      });
      if (laneResult.changes !== 1) throw new ConversationStoreError("QUEUE_REVISION_CONFLICT", "lane CAS failed");
      this.inject("queue.after-lane-cas");
      this.inject("queue.before-commit");
    });
    transaction.immediate();
    const entry = this.requireQueueEntry(input.admission.thread, input.laneFamily, input.queueEntryId);
    return {
      kind,
      controlOperation: this.requireOperation(input.admission.thread, input.admission.operationId),
      rootOperation: this.requireOperation(input.admission.thread, entry.rootOperationId),
      entry,
      lane: this.requireQueueLane(input.admission.thread, input.laneFamily),
    };
  }

  beginQueuedDispatch(input: BeginQueuedDispatchInput): QueueDispatchBarrier | undefined {
    this.assertLease();
    assertAuthenticatedContext(input.context, input.thread);
    assertId(input.laneFamily, "laneFamily");
    assertExpectedRevision(input.expectedLaneRevision);
    assertId(input.dispatchAttemptId, "dispatchAttemptId");
    let queueEntryId: string | undefined;
    let operationId: string | undefined;
    const transaction = this.database.transaction(() => {
      this.fenceLeaseInTransaction();
      const lane = this.requireQueueLane(input.thread, input.laneFamily);
      if (lane.revision !== input.expectedLaneRevision) {
        throw new ConversationStoreError("QUEUE_REVISION_CONFLICT", "queue lane revision changed");
      }
      const next = this.database.prepare(
        `SELECT * FROM queue_entry WHERE bridge_identity_id=@bridgeIdentityId AND
         bridge_instance_id=@bridgeInstanceId AND codex_source_id=@codexSourceId AND
         provider_thread_id=@providerThreadId AND lane_family=@laneFamily AND state='QUEUED'
         ORDER BY fifo_ordinal LIMIT 1`,
      ).get({ ...threadParams(input.thread), laneFamily: input.laneFamily }) as QueueEntryRow | undefined;
      if (!next) return;
      queueEntryId = next.queue_entry_id;
      operationId = next.root_operation_id;
      const operation = this.requireOperation(input.thread, operationId);
      assertExactEpoch(operation.sourceEpoch, input.context.sourceEpoch);
      const blockingUnknown = this.findBlockingUnknownOutcome(
        input.thread,
        operation.conflictFamily,
        operation.operationId,
      );
      if (blockingUnknown) {
        throw new ConversationStoreError(
          "BLOCKED_BY_UNKNOWN_OUTCOME",
          `dispatch blocked by outcome-unknown operation ${blockingUnknown}`,
        );
      }
      if (operation.state !== "QUEUED") {
        throw new ConversationStoreError("INVALID_STATE_TRANSITION", "queue root is not queued");
      }
      const now = this.clock();
      this.updateOperationState(operation, "CALL_STARTED", {
        eventKind: "CALL_STARTED",
        dispatchAttemptId: input.dispatchAttemptId,
      });
      this.inject("queue.after-operation");
      const entryResult = this.database.prepare(
        `UPDATE queue_entry SET state='DISPATCH_RESERVED',entry_revision=entry_revision+1,updated_at=@now
         WHERE bridge_identity_id=@bridgeIdentityId AND bridge_instance_id=@bridgeInstanceId AND
           codex_source_id=@codexSourceId AND provider_thread_id=@providerThreadId AND
           lane_family=@laneFamily AND queue_entry_id=@queueEntryId AND
           entry_revision=@entryRevision AND state='QUEUED'`,
      ).run({
        ...threadParams(input.thread),
        laneFamily: input.laneFamily,
        queueEntryId,
        entryRevision: next.entry_revision,
        now,
      });
      if (entryResult.changes !== 1) throw new ConversationStoreError("ENTRY_REVISION_CONFLICT", "entry CAS failed");
      this.inject("queue.after-entry");
      const laneResult = this.database.prepare(
        `UPDATE queue_lane SET revision=revision+1,active_count=active_count-1,updated_at=@now
         WHERE bridge_identity_id=@bridgeIdentityId AND bridge_instance_id=@bridgeInstanceId AND
           codex_source_id=@codexSourceId AND provider_thread_id=@providerThreadId AND
           lane_family=@laneFamily AND revision=@expectedLaneRevision AND active_count>0`,
      ).run({
        ...threadParams(input.thread),
        laneFamily: input.laneFamily,
        expectedLaneRevision: input.expectedLaneRevision,
        now,
      });
      if (laneResult.changes !== 1) throw new ConversationStoreError("QUEUE_REVISION_CONFLICT", "lane CAS failed");
      this.inject("queue.after-lane-cas");
      this.inject("queue.before-commit");
    });
    transaction.immediate();
    if (!queueEntryId || !operationId) return undefined;
    return {
      lane: this.requireQueueLane(input.thread, input.laneFamily),
      entry: this.requireQueueEntry(input.thread, input.laneFamily, queueEntryId),
      operation: this.requireOperation(input.thread, operationId),
    };
  }

  readQueueLane(thread: ThreadRef, laneFamily: string): QueueLaneRecord | undefined {
    this.assertLease();
    assertThread(thread);
    assertId(laneFamily, "laneFamily");
    const row = this.database.prepare(
      `SELECT * FROM queue_lane WHERE bridge_identity_id=@bridgeIdentityId AND
       bridge_instance_id=@bridgeInstanceId AND codex_source_id=@codexSourceId AND
       provider_thread_id=@providerThreadId AND lane_family=@laneFamily`,
    ).get({ ...threadParams(thread), laneFamily }) as QueueLaneRow | undefined;
    return row ? queueLaneFromRow(row) : undefined;
  }

  listQueueEntries(thread: ThreadRef, laneFamily: string): QueueEntryRecord[] {
    this.assertLease();
    this.requireQueueLane(thread, laneFamily);
    return (this.database.prepare(
      `SELECT * FROM queue_entry WHERE bridge_identity_id=@bridgeIdentityId AND
       bridge_instance_id=@bridgeInstanceId AND codex_source_id=@codexSourceId AND
       provider_thread_id=@providerThreadId AND lane_family=@laneFamily ORDER BY fifo_ordinal`,
    ).all({ ...threadParams(thread), laneFamily }) as QueueEntryRow[]).map(queueEntryFromRow);
  }

  openInteraction(input: OpenInteractionInput): InteractionRecord {
    this.assertLease();
    assertAuthenticatedContext(input.context, input.ref.thread);
    assertInteractionRef(input.ref);
    assertId(input.providerRequestId, "providerRequestId");
    if (!Number.isSafeInteger(input.expiresAt) || input.expiresAt <= 0) {
      throw new ConversationStoreError("CLAIM_EXPIRED", "interaction expiry is invalid");
    }
    const sourceEpochJson = canonicalizeJson(input.context.sourceEpoch, {
      maxBytes: OPERATION_JSON_MAX_BYTES,
      requireObject: true,
    });
    const descriptorJson = canonicalizeJsonObject(input.descriptor, OPERATION_JSON_MAX_BYTES);
    const transaction = this.database.transaction(() => {
      this.fenceLeaseInTransaction();
      const now = this.clock();
      if (input.expiresAt <= now) {
        throw new ConversationStoreError("CLAIM_EXPIRED", "interaction expiry must be in the future");
      }
      this.ensureSource(input.ref.thread.sourcePartition);
      const existing = this.findInteraction(input.ref);
      if (existing) {
        if (
          !sameSourceEpoch(existing.sourceEpoch, input.context.sourceEpoch) ||
          existing.providerRequestId !== input.providerRequestId ||
          existing.variant !== input.variant ||
          existing.expiresAt !== input.expiresAt ||
          canonicalizeJsonObject(existing.descriptor, OPERATION_JSON_MAX_BYTES) !== descriptorJson
        ) {
          throw new ConversationStoreError("INTERACTION_REVISION_CONFLICT", "interaction identity already differs");
        }
        return;
      }
      this.database.prepare(
        `INSERT INTO interaction (
           bridge_identity_id,bridge_instance_id,codex_source_id,provider_thread_id,provider_turn_id,
           interaction_id,connection_generation,provider_generation,source_epoch_json,
           provider_request_id,variant,state,revision,expires_at,descriptor_json,updated_at
         ) VALUES (
           @bridgeIdentityId,@bridgeInstanceId,@codexSourceId,@providerThreadId,@providerTurnId,
           @interactionId,@connectionGeneration,@providerGeneration,@sourceEpochJson,
           @providerRequestId,@variant,'OPEN_UNCLAIMED',1,@expiresAt,@descriptorJson,@now
         )`,
      ).run({
        ...interactionParams(input.ref),
        connectionGeneration: input.context.sourceEpoch.connectionGeneration,
        providerGeneration: input.context.sourceEpoch.providerGeneration,
        sourceEpochJson,
        providerRequestId: input.providerRequestId,
        variant: input.variant,
        expiresAt: input.expiresAt,
        descriptorJson,
        now,
      });
      this.inject("interaction.after-row");
      this.inject("interaction.before-commit");
    });
    transaction.immediate();
    return this.requireInteraction(input.ref);
  }

  claimInteraction(input: ClaimInteractionInput): { interaction: InteractionRecord; claim: InteractionClaimRecord } {
    this.assertLease();
    assertAuthenticatedContext(input.context, input.ref.thread);
    assertInteractionRef(input.ref);
    assertExpectedRevision(input.expectedInteractionRevision);
    assertId(input.claimId, "claimId");
    assertClaimToken(input.claimToken);
    if (!Number.isSafeInteger(input.expiresAt) || input.expiresAt <= 0) {
      throw new ConversationStoreError("CLAIM_EXPIRED", "claim expiry is invalid");
    }
    const transaction = this.database.transaction(() => {
      this.fenceLeaseInTransaction();
      const now = this.clock();
      let interaction = this.requireInteraction(input.ref);
      assertExactEpoch(interaction.sourceEpoch, input.context.sourceEpoch);
      if (input.expiresAt <= now) {
        throw new ConversationStoreError("CLAIM_EXPIRED", "claim expiry must be in the future");
      }
      this.refreshInteractionExpiryInTransaction(input.ref, now);
      interaction = this.requireInteraction(input.ref);
      if (interaction.expiresAt <= now) throw new ConversationStoreError("CLAIM_EXPIRED", "interaction expired");
      if (input.expiresAt > interaction.expiresAt) {
        throw new ConversationStoreError("CLAIM_EXPIRED", "claim expiry exceeds interaction expiry");
      }
      if (interaction.revision !== input.expectedInteractionRevision || interaction.state !== "OPEN_UNCLAIMED") {
        throw new ConversationStoreError("INTERACTION_REVISION_CONFLICT", "interaction is not claimable at revision");
      }
      const active = this.findActiveClaim(input.ref);
      if (active && active.expiresAt > now) {
        throw new ConversationStoreError("INTERACTION_CONTENDED", "interaction already has an active claim");
      }
      if (active) {
        this.database.prepare(
          `UPDATE interaction_claim SET state='EXPIRED',revision=revision+1,updated_at=@now
           WHERE bridge_identity_id=@bridgeIdentityId AND bridge_instance_id=@bridgeInstanceId AND
             codex_source_id=@codexSourceId AND provider_thread_id=@providerThreadId AND
             provider_turn_id=@providerTurnId AND interaction_id=@interactionId AND
             claim_id=@claimId AND revision=@claimRevision AND state='ACTIVE'`,
        ).run({ ...interactionParams(input.ref), claimId: active.claimId, claimRevision: active.revision, now });
      }
      const interactionResult = this.database.prepare(
        `UPDATE interaction SET state='CLAIMED',revision=revision+1,updated_at=@now
         WHERE bridge_identity_id=@bridgeIdentityId AND bridge_instance_id=@bridgeInstanceId AND
           codex_source_id=@codexSourceId AND provider_thread_id=@providerThreadId AND
           provider_turn_id=@providerTurnId AND interaction_id=@interactionId AND
           revision=@expectedRevision AND state='OPEN_UNCLAIMED'`,
      ).run({
        ...interactionParams(input.ref),
        expectedRevision: input.expectedInteractionRevision,
        now,
      });
      if (interactionResult.changes !== 1) {
        throw new ConversationStoreError("INTERACTION_REVISION_CONFLICT", "interaction claim CAS failed");
      }
      this.inject("interaction.after-row");
      this.database.prepare(
        `INSERT INTO interaction_claim (
           bridge_identity_id,bridge_instance_id,codex_source_id,provider_thread_id,provider_turn_id,
           interaction_id,claim_id,actor_id,token_hash,expires_at,state,revision,updated_at
         ) VALUES (
           @bridgeIdentityId,@bridgeInstanceId,@codexSourceId,@providerThreadId,@providerTurnId,
           @interactionId,@claimId,@actorId,@tokenHash,@expiresAt,'ACTIVE',1,@now
         )`,
      ).run({
        ...interactionParams(input.ref),
        claimId: input.claimId,
        actorId: input.context.actorId,
        tokenHash: hashClaimToken(input.claimToken),
        expiresAt: input.expiresAt,
        now,
      });
      this.inject("interaction.after-claim");
      this.inject("interaction.before-commit");
    });
    transaction.immediate();
    return {
      interaction: this.requireInteraction(input.ref),
      claim: this.requireClaim(input.ref, input.claimId),
    };
  }

  respondInteraction(input: RespondInteractionInput): {
    kind: "RECORDED" | "IDEMPOTENT";
    interaction: InteractionRecord;
    operation: OperationRecord;
  } {
    this.assertLease();
    assertAuthenticatedContext(input.context, input.ref.thread);
    assertInteractionRef(input.ref);
    assertExpectedRevision(input.expectedInteractionRevision);
    assertExpectedRevision(input.expectedClaimRevision);
    assertId(input.claimId, "claimId");
    assertClaimToken(input.claimToken);
    assertResponseVariant(input.variant, input.operationCode);
    const admission: OperationAdmission = {
      context: input.context,
      thread: input.ref.thread,
      operationId: input.responseOperationId,
      clientInstanceId: input.responseClientInstanceId,
      clientMessageId: input.responseClientMessageId,
      operationCode: input.operationCode,
      conflictFamily: "INTERACTION_RESPONSE",
      target: input.operationTarget,
      payload: {
        payloadKind: {
          "OP-019": "RESPOND_APPROVAL",
          "OP-020": "RESPOND_QUESTION",
          "OP-021": "RESPOND_MCP_ELICITATION",
          "OP-022": "RESPOND_EXIT_PLAN",
        }[input.operationCode] as OperationRecord["payload"]["payloadKind"],
        body: input.response,
      },
      preconditions: input.operationPreconditions,
    };
    if (input.operationTarget.variant !== input.variant) {
      throw new ConversationStoreError("WRONG_INTERACTION_VARIANT", "response target variant mismatch");
    }
    if (
      input.operationTarget.providerThreadId !== input.ref.thread.providerThreadId ||
      input.operationTarget.providerTurnId !== input.ref.providerTurnId ||
      input.operationTarget.interactionId !== input.ref.interactionId ||
      input.operationPreconditions.expectedInteractionRevision !== input.expectedInteractionRevision ||
      input.operationPreconditions.expectedClaimRevision !== input.expectedClaimRevision
    ) {
      throw new ConversationStoreError("INTERACTION_REVISION_CONFLICT", "response operation envelope mismatches barrier target");
    }
    const prepared = prepareAdmission(admission);
    const responseJson = canonicalizeJsonObject(input.response, OPERATION_JSON_MAX_BYTES);
    let kind: "RECORDED" | "IDEMPOTENT" = "RECORDED";
    const transaction = this.database.transaction(() => {
      this.fenceLeaseInTransaction();
      const now = this.clock();
      const interaction = this.requireInteraction(input.ref);
      assertExactEpoch(interaction.sourceEpoch, input.context.sourceEpoch);
      if (interaction.variant !== input.variant) {
        throw new ConversationStoreError("WRONG_INTERACTION_VARIANT", "interaction response variant mismatch");
      }
      const claim = this.requireClaim(input.ref, input.claimId);
      if (
        claim.actorId !== input.context.actorId ||
        claim.tokenHash !== hashClaimToken(input.claimToken)
      ) {
        throw new ConversationStoreError("CLAIM_NOT_OWNED", "authenticated actor or token mismatch");
      }
      if (input.claimedFingerprint && input.claimedFingerprint !== prepared.fingerprint) {
        throw new ConversationStoreError(
          "OPERATION_FINGERPRINT_CONFLICT",
          "claimed response fingerprint does not match server computation",
        );
      }
      if (interaction.responseFingerprint) {
        if (
          claim.state === "CONSUMED" &&
          interaction.state === "RESPONDING" &&
          interaction.responseFingerprint === prepared.fingerprint &&
          interaction.responseOperationId === input.responseOperationId &&
          interaction.responseActorId === input.context.actorId &&
          interaction.response !== undefined
        ) {
          const operation = this.requireOperation(input.ref.thread, input.responseOperationId);
          assertExistingAdmission(operation, admission, prepared.fingerprint);
          kind = "IDEMPOTENT";
          return;
        }
        throw new ConversationStoreError("OPERATION_FINGERPRINT_CONFLICT", "interaction already has another response");
      }
      // An exact replay is immutable evidence lookup, not a second response barrier.  Once the
      // claim was consumed successfully, later wall-clock expiry must not make the same request
      // non-idempotent.  Expiry is still mandatory before crossing a first response barrier.
      if (interaction.expiresAt <= now) throw new ConversationStoreError("CLAIM_EXPIRED", "interaction expired");
      if (claim.expiresAt <= now) throw new ConversationStoreError("CLAIM_EXPIRED", "claim expired");
      if (
        interaction.revision !== input.expectedInteractionRevision ||
        interaction.state !== "CLAIMED"
      ) {
        throw new ConversationStoreError("INTERACTION_REVISION_CONFLICT", "interaction is not claimed at revision");
      }
      if (claim.revision !== input.expectedClaimRevision || claim.state !== "ACTIVE") {
        throw new ConversationStoreError("CLAIM_NOT_OWNED", "claim revision or state changed");
      }
      this.admitOperationInTransaction(admission, prepared);
      const claimResult = this.database.prepare(
        `UPDATE interaction_claim SET state='CONSUMED',revision=revision+1,updated_at=@now
         WHERE bridge_identity_id=@bridgeIdentityId AND bridge_instance_id=@bridgeInstanceId AND
           codex_source_id=@codexSourceId AND provider_thread_id=@providerThreadId AND
           provider_turn_id=@providerTurnId AND interaction_id=@interactionId AND claim_id=@claimId AND
           revision=@expectedClaimRevision AND state='ACTIVE'`,
      ).run({
        ...interactionParams(input.ref),
        claimId: input.claimId,
        expectedClaimRevision: input.expectedClaimRevision,
        now,
      });
      if (claimResult.changes !== 1) throw new ConversationStoreError("CLAIM_NOT_OWNED", "claim consume CAS failed");
      this.inject("interaction.after-claim");
      const interactionResult = this.database.prepare(
        `UPDATE interaction SET state='RESPONDING',revision=revision+1,
           response_fingerprint=@fingerprint,response_operation_id=@operationId,
           response_actor_id=@actorId,response_json=@responseJson,updated_at=@now
         WHERE bridge_identity_id=@bridgeIdentityId AND bridge_instance_id=@bridgeInstanceId AND
           codex_source_id=@codexSourceId AND provider_thread_id=@providerThreadId AND
           provider_turn_id=@providerTurnId AND interaction_id=@interactionId AND
           revision=@expectedInteractionRevision AND state='CLAIMED'`,
      ).run({
        ...interactionParams(input.ref),
        fingerprint: prepared.fingerprint,
        operationId: input.responseOperationId,
        actorId: input.context.actorId,
        responseJson,
        expectedInteractionRevision: input.expectedInteractionRevision,
        now,
      });
      if (interactionResult.changes !== 1) {
        throw new ConversationStoreError("INTERACTION_REVISION_CONFLICT", "response barrier CAS failed");
      }
      this.inject("interaction.after-row");
      this.inject("interaction.after-operation");
      this.inject("interaction.before-commit");
    });
    transaction.immediate();
    return {
      kind,
      interaction: this.requireInteraction(input.ref),
      operation: this.requireOperation(input.ref.thread, input.responseOperationId),
    };
  }

  renewInteractionClaim(input: RenewInteractionClaimInput): {
    interaction: InteractionRecord;
    claim: InteractionClaimRecord;
  } {
    this.assertLease();
    this.validateClaimMutation(input);
    if (!Number.isSafeInteger(input.expiresAt) || input.expiresAt <= 0) {
      throw new ConversationStoreError("CLAIM_EXPIRED", "claim expiry is invalid");
    }
    const transaction = this.database.transaction(() => {
      this.fenceLeaseInTransaction();
      const now = this.clock();
      const { interaction, claim } = this.requireOwnedActiveClaim(input, now);
      if (input.expiresAt <= now) {
        throw new ConversationStoreError("CLAIM_EXPIRED", "claim expiry must be in the future");
      }
      if (interaction.state !== "CLAIMED") throw new ConversationStoreError("INTERACTION_NOT_OPEN", "interaction not claimed");
      if (input.expiresAt > interaction.expiresAt) {
        throw new ConversationStoreError("CLAIM_EXPIRED", "claim expiry exceeds interaction expiry");
      }
      this.database.prepare(
        `UPDATE interaction SET revision=revision+1,updated_at=@now
         WHERE bridge_identity_id=@bridgeIdentityId AND bridge_instance_id=@bridgeInstanceId AND
           codex_source_id=@codexSourceId AND provider_thread_id=@providerThreadId AND
           provider_turn_id=@providerTurnId AND interaction_id=@interactionId AND
           revision=@expectedInteractionRevision AND state='CLAIMED'`,
      ).run({ ...interactionParams(input.ref), expectedInteractionRevision: input.expectedInteractionRevision, now });
      this.inject("interaction.after-row");
      const result = this.database.prepare(
        `UPDATE interaction_claim SET expires_at=@expiresAt,revision=revision+1,updated_at=@now
         WHERE bridge_identity_id=@bridgeIdentityId AND bridge_instance_id=@bridgeInstanceId AND
           codex_source_id=@codexSourceId AND provider_thread_id=@providerThreadId AND
           provider_turn_id=@providerTurnId AND interaction_id=@interactionId AND claim_id=@claimId AND
           revision=@expectedClaimRevision AND state='ACTIVE'`,
      ).run({
        ...interactionParams(input.ref),
        claimId: claim.claimId,
        expectedClaimRevision: input.expectedClaimRevision,
        expiresAt: input.expiresAt,
        now,
      });
      if (result.changes !== 1) throw new ConversationStoreError("CLAIM_NOT_OWNED", "claim renew CAS failed");
      this.inject("interaction.after-claim");
      this.inject("interaction.before-commit");
    });
    transaction.immediate();
    return { interaction: this.requireInteraction(input.ref), claim: this.requireClaim(input.ref, input.claimId) };
  }

  releaseInteractionClaim(input: InteractionClaimMutationInput): {
    interaction: InteractionRecord;
    claim: InteractionClaimRecord;
  } {
    this.assertLease();
    this.validateClaimMutation(input);
    const transaction = this.database.transaction(() => {
      this.fenceLeaseInTransaction();
      const now = this.clock();
      const { claim } = this.requireOwnedActiveClaim(input, now);
      const claimResult = this.database.prepare(
        `UPDATE interaction_claim SET state='RELEASED',revision=revision+1,updated_at=@now
         WHERE bridge_identity_id=@bridgeIdentityId AND bridge_instance_id=@bridgeInstanceId AND
           codex_source_id=@codexSourceId AND provider_thread_id=@providerThreadId AND
           provider_turn_id=@providerTurnId AND interaction_id=@interactionId AND claim_id=@claimId AND
           revision=@expectedClaimRevision AND state='ACTIVE'`,
      ).run({
        ...interactionParams(input.ref),
        claimId: claim.claimId,
        expectedClaimRevision: input.expectedClaimRevision,
        now,
      });
      if (claimResult.changes !== 1) throw new ConversationStoreError("CLAIM_NOT_OWNED", "claim release CAS failed");
      this.inject("interaction.after-claim");
      const interactionResult = this.database.prepare(
        `UPDATE interaction SET state='OPEN_UNCLAIMED',revision=revision+1,updated_at=@now
         WHERE bridge_identity_id=@bridgeIdentityId AND bridge_instance_id=@bridgeInstanceId AND
           codex_source_id=@codexSourceId AND provider_thread_id=@providerThreadId AND
           provider_turn_id=@providerTurnId AND interaction_id=@interactionId AND
           revision=@expectedInteractionRevision AND state='CLAIMED'`,
      ).run({ ...interactionParams(input.ref), expectedInteractionRevision: input.expectedInteractionRevision, now });
      if (interactionResult.changes !== 1) {
        throw new ConversationStoreError("INTERACTION_REVISION_CONFLICT", "interaction release CAS failed");
      }
      this.inject("interaction.after-row");
      this.inject("interaction.before-commit");
    });
    transaction.immediate();
    return { interaction: this.requireInteraction(input.ref), claim: this.requireClaim(input.ref, input.claimId) };
  }

  resolveInteraction(input: ResolveInteractionInput): {
    interaction: InteractionRecord;
    operation: OperationRecord;
    reconcileResolution?: ReconcileResolutionRecord;
  } {
    this.assertLease();
    assertAuthenticatedContext(input.context, input.ref.thread);
    assertInteractionRef(input.ref);
    assertExpectedRevision(input.expectedInteractionRevision);
    assertId(input.responseOperationId, "responseOperationId");
    assertId(input.providerRequestId, "providerRequestId");
    validateVerifiedInteractionFact(input);
    const { canonical: evidenceJson, digest: evidenceDigest } = sha256CanonicalJson(
      input.evidence,
      OPERATION_JSON_MAX_BYTES,
    );
    let reconcileResolution: ReconcileResolutionRecord | undefined;
    const now = this.clock();
    const transaction = this.database.transaction(() => {
      this.fenceLeaseInTransaction();
      const interaction = this.requireInteraction(input.ref);
      assertExactEpoch(interaction.sourceEpoch, input.context.sourceEpoch);
      if (
        interaction.state !== "RESPONDING" ||
        interaction.revision !== input.expectedInteractionRevision ||
        interaction.providerRequestId !== input.providerRequestId ||
        interaction.responseOperationId !== input.responseOperationId ||
        input.providerEvent !== "SERVER_REQUEST_RESOLVED"
      ) {
        throw new ConversationStoreError("INTERACTION_REVISION_CONFLICT", "resolved fact does not match response barrier");
      }
      let operation = this.requireOperation(input.ref.thread, input.responseOperationId);
      assertExactEpoch(operation.sourceEpoch, input.context.sourceEpoch);
      if (operation.state === "OUTCOME_UNKNOWN") {
        const reconcileRoundId = `interaction-${input.ref.interactionId}-${interaction.revision}`;
        const factId = `resolved-${evidenceDigest.slice(0, 32)}`;
        this.database.prepare(
          "INSERT INTO reconcile_round (operation_id,reconcile_round_id,created_at) VALUES (?,?,?)",
        ).run(operation.operationId, reconcileRoundId, now);
        this.database.prepare(
          `INSERT INTO reconcile_fact (
             operation_id,reconcile_round_id,fact_id,fact_kind,evidence_digest,evidence_json,
             provider_turn_id,created_at
           ) VALUES (?,?,?,?,?,?,?,?)`,
        ).run(operation.operationId, reconcileRoundId, factId, "CANONICAL_OBSERVED", evidenceDigest,
          evidenceJson, input.ref.providerTurnId, now);
        this.database.prepare(
          `INSERT INTO reconcile_resolution (
             operation_id,reconcile_round_id,fact_id,projected_outcome,evidence_digest,resolved_at
           ) VALUES (?,?,?,?,?,?)`,
        ).run(operation.operationId, reconcileRoundId, factId, "SUCCEEDED", evidenceDigest, now);
        reconcileResolution = {
          operationId: operation.operationId,
          reconcileRoundId,
          factId,
          projectedOutcome: "SUCCEEDED",
          evidenceDigest,
          resolvedAt: now,
        };
      } else {
        if (operation.state === "CALL_STARTED") {
          this.updateOperationState(operation, "PROVIDER_ACCEPTED", {
            eventKind: "SERVER_REQUEST_RESOLVED_ACCEPTED",
            dispatchAttemptId: operation.dispatchAttemptId,
            providerTurnId: input.ref.providerTurnId,
            detailsJson: evidenceJson,
          });
          this.consumeReservedEntryForOperation(operation.operationId);
          operation = this.requireOperation(input.ref.thread, operation.operationId);
        }
        if (operation.state === "PROVIDER_ACCEPTED") {
          this.updateOperationState(operation, "CANONICAL_OBSERVED", {
            eventKind: "SERVER_REQUEST_RESOLVED_CANONICAL",
            dispatchAttemptId: operation.dispatchAttemptId,
            providerTurnId: input.ref.providerTurnId,
            detailsJson: evidenceJson,
          });
          operation = this.requireOperation(input.ref.thread, operation.operationId);
        }
        if (operation.state !== "CANONICAL_OBSERVED") {
          throw new ConversationStoreError("INVALID_STATE_TRANSITION", "response operation cannot resolve");
        }
        this.updateOperationState(operation, "SUCCEEDED", {
          eventKind: "SERVER_REQUEST_RESOLVED_SUCCEEDED",
          dispatchAttemptId: operation.dispatchAttemptId,
          providerTurnId: input.ref.providerTurnId,
          detailsJson: evidenceJson,
        });
      }
      const result = this.database.prepare(
        `UPDATE interaction SET state='RESOLVED',revision=revision+1,
           resolution_evidence_digest=@evidenceDigest,updated_at=@now
         WHERE bridge_identity_id=@bridgeIdentityId AND bridge_instance_id=@bridgeInstanceId AND
           codex_source_id=@codexSourceId AND provider_thread_id=@providerThreadId AND
           provider_turn_id=@providerTurnId AND interaction_id=@interactionId AND
           revision=@expectedRevision AND state='RESPONDING'`,
      ).run({
        ...interactionParams(input.ref),
        expectedRevision: input.expectedInteractionRevision,
        evidenceDigest,
        now,
      });
      if (result.changes !== 1) throw new ConversationStoreError("INTERACTION_REVISION_CONFLICT", "resolve CAS failed");
      this.inject("interaction.after-row");
      this.inject("interaction.before-commit");
    });
    transaction.immediate();
    return {
      interaction: this.requireInteraction(input.ref),
      operation: this.requireOperation(input.ref.thread, input.responseOperationId),
      ...(reconcileResolution ? { reconcileResolution } : {}),
    };
  }

  getInteraction(ref: InteractionRef): InteractionRecord | undefined {
    this.assertLease();
    assertInteractionRef(ref);
    this.refreshInteractionExpiry(ref);
    return this.findInteraction(ref);
  }

  getActiveClaim(ref: InteractionRef): InteractionClaimRecord | undefined {
    this.assertLease();
    assertInteractionRef(ref);
    this.refreshInteractionExpiry(ref);
    return this.findActiveClaim(ref);
  }

  private insertTimelinePageRows(input: TimelinePageInput): void {
    const params = { ...threadParams(input.thread), materializationId: input.materializationId };
    const insertItem = this.database.prepare(
      `INSERT INTO timeline_item (
         bridge_identity_id,bridge_instance_id,codex_source_id,provider_thread_id,materialization_id,
         item_id,provider_turn_id,turn_ordinal,item_ordinal,timeline_ordinal,item_kind,payload_json
       ) VALUES (
         @bridgeIdentityId,@bridgeInstanceId,@codexSourceId,@providerThreadId,@materializationId,
         @itemId,@providerTurnId,@turnOrdinal,@itemOrdinal,@timelineOrdinal,@kind,@payloadJson
       )`,
    );
    for (const item of input.items) {
      insertItem.run({
        ...params,
        ...item,
        payloadJson: canonicalizeJsonObject(item.payload, TIMELINE_PAGE_MAX_BYTES),
      });
    }
    const insertGap = this.database.prepare(
      `INSERT INTO timeline_gap (
         bridge_identity_id,bridge_instance_id,codex_source_id,provider_thread_id,materialization_id,
         gap_id,gap_ordinal,gap_kind,first_missing_timeline_ordinal,last_missing_timeline_ordinal,
         reason,descriptor_json
       ) VALUES (
         @bridgeIdentityId,@bridgeInstanceId,@codexSourceId,@providerThreadId,@materializationId,
         @gapId,@gapOrdinal,@gapKind,@firstMissingTimelineOrdinal,@lastMissingTimelineOrdinal,
         @reason,@descriptorJson
       )`,
    );
    for (const gap of input.gaps) {
      insertGap.run({
        ...params,
        ...gap,
        descriptorJson: canonicalizeJsonObject(gap.descriptor, TIMELINE_PAGE_MAX_BYTES),
      });
    }
    const insertIsland = this.database.prepare(
      `INSERT INTO timeline_coverage_island (
         bridge_identity_id,bridge_instance_id,codex_source_id,provider_thread_id,materialization_id,
         island_id,island_ordinal,first_timeline_ordinal,last_timeline_ordinal,
         structural_coverage,payload_coverage
       ) VALUES (
         @bridgeIdentityId,@bridgeInstanceId,@codexSourceId,@providerThreadId,@materializationId,
         @islandId,@islandOrdinal,@firstTimelineOrdinal,@lastTimelineOrdinal,
         @structuralCoverage,@payloadCoverage
       )`,
    );
    for (const island of input.coverageIslands) insertIsland.run({ ...params, ...island });
  }

  private listTimelinePages(thread: ThreadRef, materializationId: string): TimelinePageRow[] {
    return this.database.prepare(
      `SELECT materialization_id,page_index,previous_page_digest,page_digest,item_count,gap_count,
              body_bytes,body_json FROM timeline_page
       WHERE bridge_identity_id=@bridgeIdentityId AND bridge_instance_id=@bridgeInstanceId AND
         codex_source_id=@codexSourceId AND provider_thread_id=@providerThreadId AND
         materialization_id=@materializationId ORDER BY page_index`,
    ).all({ ...threadParams(thread), materializationId }) as TimelinePageRow[];
  }

  private listAllTimelineItems(thread: ThreadRef, materializationId: string): TimelineItemRecord[] {
    const rows = this.database.prepare(
      `SELECT item_id,provider_turn_id,turn_ordinal,item_ordinal,timeline_ordinal,item_kind,payload_json
       FROM timeline_item WHERE bridge_identity_id=@bridgeIdentityId AND
         bridge_instance_id=@bridgeInstanceId AND codex_source_id=@codexSourceId AND
         provider_thread_id=@providerThreadId AND materialization_id=@materializationId
       ORDER BY timeline_ordinal`,
    ).all({ ...threadParams(thread), materializationId }) as TimelineItemRow[];
    return rows.map(timelineItemFromRow);
  }

  private listAllTimelineGaps(thread: ThreadRef, materializationId: string): TimelineGapRecord[] {
    const rows = this.database.prepare(
      `SELECT gap_id,gap_ordinal,gap_kind,first_missing_timeline_ordinal,
              last_missing_timeline_ordinal,reason,descriptor_json
       FROM timeline_gap WHERE bridge_identity_id=@bridgeIdentityId AND
         bridge_instance_id=@bridgeInstanceId AND codex_source_id=@codexSourceId AND
         provider_thread_id=@providerThreadId AND materialization_id=@materializationId
       ORDER BY gap_ordinal`,
    ).all({ ...threadParams(thread), materializationId }) as TimelineGapRow[];
    return rows.map(timelineGapFromRow);
  }

  private listAllTimelineIslands(thread: ThreadRef, materializationId: string): TimelineCoverageIslandRecord[] {
    const rows = this.database.prepare(
      `SELECT island_id,island_ordinal,first_timeline_ordinal,last_timeline_ordinal,
              structural_coverage,payload_coverage FROM timeline_coverage_island
       WHERE bridge_identity_id=@bridgeIdentityId AND bridge_instance_id=@bridgeInstanceId AND
         codex_source_id=@codexSourceId AND provider_thread_id=@providerThreadId AND
         materialization_id=@materializationId ORDER BY island_ordinal`,
    ).all({ ...threadParams(thread), materializationId }) as TimelineIslandRow[];
    return rows.map(timelineIslandFromRow);
  }

  private getMaterialization(thread: ThreadRef, materializationId: string): TimelineMaterializationRecord | undefined {
    const row = this.database.prepare(
      `SELECT * FROM timeline_materialization WHERE bridge_identity_id=@bridgeIdentityId AND
       bridge_instance_id=@bridgeInstanceId AND codex_source_id=@codexSourceId AND
       provider_thread_id=@providerThreadId AND materialization_id=@materializationId`,
    ).get({ ...threadParams(thread), materializationId }) as MaterializationRow | undefined;
    return row ? materializationFromRow(row) : undefined;
  }

  private requireMaterialization(thread: ThreadRef, materializationId: string): TimelineMaterializationRecord {
    const materialization = this.getMaterialization(thread, materializationId);
    if (!materialization) {
      throw new ConversationStoreError("TIMELINE_CANDIDATE_REJECTED", "materialization does not exist");
    }
    return materialization;
  }

  private requireTimeline(thread: ThreadRef): TimelineReadback {
    const timeline = this.readTimeline(thread);
    if (!timeline) throw new Error("timeline head readback missing");
    return timeline;
  }

  private admitOperationInTransaction(
    admission: OperationAdmission,
    prepared: PreparedAdmission,
  ): "ADMITTED" | "IDEMPOTENT" {
    const existing = this.findOperationByAdmissionKey(
      admission.thread,
      admission.clientInstanceId,
      admission.clientMessageId,
    );
    if (existing) {
      assertExistingAdmission(existing, admission, prepared.fingerprint);
      return "IDEMPOTENT";
    }
    const reusedId = this.database.prepare("SELECT operation_id FROM operation WHERE operation_id=?")
      .get(admission.operationId) as { operation_id: string } | undefined;
    if (reusedId) throw new ConversationStoreError("OPERATION_ID_CONFLICT", "operation id is already bound");
    const unknown = this.findBlockingUnknownOutcome(admission.thread, admission.conflictFamily);
    if (unknown) {
      throw new ConversationStoreError(
        "BLOCKED_BY_UNKNOWN_OUTCOME",
        `mutation blocked by outcome-unknown operation ${unknown}`,
      );
    }
    this.ensureSource(admission.thread.sourcePartition);
    this.database.prepare(
      `INSERT INTO operation (
         bridge_identity_id,bridge_instance_id,codex_source_id,provider_thread_id,
         connection_generation,provider_generation,source_epoch_json,actor_id,origin_kind,origin_id,
         client_instance_id,client_message_id,operation_id,operation_code,conflict_family,fingerprint,
         target_json,payload_json,preconditions_json,state,revision,canonical_observed,reconcile_required,
         transition_event_kind,created_at,updated_at
       ) VALUES (
         @bridgeIdentityId,@bridgeInstanceId,@codexSourceId,@providerThreadId,
         @connectionGeneration,@providerGeneration,@sourceEpochJson,@actorId,@originKind,@originId,
         @clientInstanceId,@clientMessageId,@operationId,@operationCode,@conflictFamily,@fingerprint,
         @targetJson,@payloadJson,@preconditionsJson,'DURABLY_ADMITTED',1,0,0,
         'DURABLY_ADMITTED',@now,@now
       )`,
    ).run({
      ...threadParams(admission.thread),
      connectionGeneration: admission.context.sourceEpoch.connectionGeneration,
      providerGeneration: admission.context.sourceEpoch.providerGeneration,
      sourceEpochJson: prepared.sourceEpochJson,
      actorId: admission.context.actorId,
      originKind: admission.context.origin.kind,
      originId: admission.context.origin.id,
      clientInstanceId: admission.clientInstanceId,
      clientMessageId: admission.clientMessageId,
      operationId: admission.operationId,
      operationCode: admission.operationCode,
      conflictFamily: admission.conflictFamily,
      fingerprint: prepared.fingerprint,
      targetJson: prepared.targetJson,
      payloadJson: prepared.payloadJson,
      preconditionsJson: prepared.preconditionsJson,
      now: this.clock(),
    });
    this.inject("operation.after-row");
    this.inject("operation.after-event");
    return "ADMITTED";
  }

  private findOperationByAdmissionKey(
    thread: ThreadRef,
    clientInstanceId: string,
    clientMessageId: string,
  ): OperationRecord | undefined {
    const row = this.database.prepare(
      `SELECT * FROM operation WHERE bridge_identity_id=@bridgeIdentityId AND
       bridge_instance_id=@bridgeInstanceId AND codex_source_id=@codexSourceId AND
       provider_thread_id=@providerThreadId AND client_instance_id=@clientInstanceId AND
       client_message_id=@clientMessageId`,
    ).get({ ...threadParams(thread), clientInstanceId, clientMessageId }) as OperationRow | undefined;
    return row ? operationFromRow(row) : undefined;
  }

  private findBlockingUnknownOutcome(
    thread: ThreadRef,
    conflictFamily: OperationRecord["conflictFamily"],
    excludedOperationId?: string,
  ): string | undefined {
    const row = this.database.prepare(
      `SELECT operation_id FROM operation WHERE bridge_identity_id=@bridgeIdentityId AND
       bridge_instance_id=@bridgeInstanceId AND codex_source_id=@codexSourceId AND
       provider_thread_id=@providerThreadId AND conflict_family=@conflictFamily AND
       state='OUTCOME_UNKNOWN'
       ${excludedOperationId === undefined ? "" : "AND operation_id!=@excludedOperationId"}
       ORDER BY created_at,operation_id LIMIT 1`,
    ).get({
      ...threadParams(thread),
      conflictFamily,
      ...(excludedOperationId === undefined ? {} : { excludedOperationId }),
    }) as { operation_id: string } | undefined;
    return row?.operation_id;
  }

  private requireOperation(thread: ThreadRef, operationId: string): OperationRecord {
    const operation = this.getOperation(thread, operationId);
    if (!operation) throw new ConversationStoreError("OPERATION_NOT_FOUND", "operation does not exist in source");
    return operation;
  }

  private updateOperationState(
    operation: OperationRecord,
    toState: OperationState,
    input: {
      eventKind: string;
      dispatchAttemptId?: string;
      providerTurnId?: string;
      detailsJson?: string;
      allowLocalSuccess?: boolean;
    },
  ): void {
    assertId(input.eventKind, "eventKind");
    if (input.dispatchAttemptId) assertId(input.dispatchAttemptId, "dispatchAttemptId");
    if (input.providerTurnId) assertId(input.providerTurnId, "providerTurnId");
    if (toState === "SUCCEEDED" && operation.state === "DURABLY_ADMITTED" && !input.allowLocalSuccess) {
      throw new ConversationStoreError("INVALID_STATE_TRANSITION", "only local controls may succeed before dispatch");
    }
    const now = this.clock();
    const result = this.database.prepare(
      `UPDATE operation SET state=@toState,revision=revision+1,
         dispatch_attempt_id=COALESCE(dispatch_attempt_id,@dispatchAttemptId),
         provider_turn_id=COALESCE(provider_turn_id,@providerTurnId),
         canonical_observed=CASE WHEN @toState='CANONICAL_OBSERVED' THEN 1 ELSE canonical_observed END,
         reconcile_required=CASE WHEN @toState='OUTCOME_UNKNOWN' THEN 1 ELSE reconcile_required END,
         transition_event_kind=@eventKind,transition_details_json=@detailsJson,
         dispatch_started_at=CASE WHEN @toState='CALL_STARTED' THEN @now ELSE dispatch_started_at END,
         provider_accepted_at=CASE WHEN @toState='PROVIDER_ACCEPTED' THEN @now ELSE provider_accepted_at END,
         canonical_observed_at=CASE WHEN @toState='CANONICAL_OBSERVED' THEN @now ELSE canonical_observed_at END,
         updated_at=@now
       WHERE operation_id=@operationId AND revision=@expectedRevision AND state=@expectedState`,
    ).run({
      operationId: operation.operationId,
      expectedRevision: operation.revision,
      expectedState: operation.state,
      toState,
      dispatchAttemptId: input.dispatchAttemptId ?? null,
      providerTurnId: input.providerTurnId ?? null,
      eventKind: input.eventKind,
      detailsJson: input.detailsJson ?? null,
      now,
    });
    if (result.changes !== 1) throw new ConversationStoreError("REVISION_CONFLICT", "operation state CAS failed");
  }

  private consumeReservedEntryForOperation(operationId: string): void {
    const row = this.database.prepare(
      "SELECT * FROM queue_entry WHERE root_operation_id=? AND state='DISPATCH_RESERVED'",
    ).get(operationId) as QueueEntryRow | undefined;
    if (!row) return;
    const result = this.database.prepare(
      `UPDATE queue_entry SET state='CONSUMED',entry_revision=entry_revision+1,updated_at=@now
       WHERE root_operation_id=@operationId AND entry_revision=@entryRevision AND state='DISPATCH_RESERVED'`,
    ).run({ operationId, entryRevision: row.entry_revision, now: this.clock() });
    if (result.changes !== 1) throw new ConversationStoreError("ENTRY_REVISION_CONFLICT", "reserved entry consume failed");
  }

  private findQueueEntryByRoot(operationId: string): QueueEntryRecord | undefined {
    const row = this.database.prepare(
      "SELECT * FROM queue_entry WHERE root_operation_id=? ORDER BY fifo_ordinal DESC LIMIT 1",
    ).get(operationId) as QueueEntryRow | undefined;
    return row ? queueEntryFromRow(row) : undefined;
  }

  private requireQueueLane(thread: ThreadRef, laneFamily: string): QueueLaneRecord {
    const lane = this.readQueueLane(thread, laneFamily);
    if (!lane) throw new ConversationStoreError("QUEUE_REVISION_CONFLICT", "queue lane does not exist");
    return lane;
  }

  private requireQueueEntry(thread: ThreadRef, laneFamily: string, queueEntryId: string): QueueEntryRecord {
    const row = this.database.prepare(
      `SELECT * FROM queue_entry WHERE bridge_identity_id=@bridgeIdentityId AND
       bridge_instance_id=@bridgeInstanceId AND codex_source_id=@codexSourceId AND
       provider_thread_id=@providerThreadId AND lane_family=@laneFamily AND queue_entry_id=@queueEntryId`,
    ).get({ ...threadParams(thread), laneFamily, queueEntryId }) as QueueEntryRow | undefined;
    if (!row) throw new ConversationStoreError("QUEUE_ENTRY_NOT_FOUND", "queue entry does not exist");
    return queueEntryFromRow(row);
  }

  private findActiveClaim(ref: InteractionRef): InteractionClaimRecord | undefined {
    const row = this.database.prepare(
      `SELECT * FROM interaction_claim WHERE bridge_identity_id=@bridgeIdentityId AND
       bridge_instance_id=@bridgeInstanceId AND codex_source_id=@codexSourceId AND
       provider_thread_id=@providerThreadId AND provider_turn_id=@providerTurnId AND
       interaction_id=@interactionId AND state='ACTIVE'`,
    ).get(interactionParams(ref)) as InteractionClaimRow | undefined;
    return row ? claimFromRow(row) : undefined;
  }

  private findInteraction(ref: InteractionRef): InteractionRecord | undefined {
    const row = this.database.prepare(
      `SELECT * FROM interaction WHERE bridge_identity_id=@bridgeIdentityId AND
       bridge_instance_id=@bridgeInstanceId AND codex_source_id=@codexSourceId AND
       provider_thread_id=@providerThreadId AND provider_turn_id=@providerTurnId AND
       interaction_id=@interactionId`,
    ).get(interactionParams(ref)) as InteractionRow | undefined;
    return row ? interactionFromRow(row) : undefined;
  }

  private refreshInteractionExpiry(ref: InteractionRef): void {
    const transaction = this.database.transaction(() => {
      this.fenceLeaseInTransaction();
      this.refreshInteractionExpiryInTransaction(ref, this.clock());
    });
    transaction.immediate();
  }

  private refreshInteractionExpiryInTransaction(ref: InteractionRef, now: number): void {
    const interaction = this.findInteraction(ref);
    if (!interaction || interaction.state === "RESOLVED" || interaction.state === "EXPIRED" ||
        interaction.state === "WITHDRAWN" || interaction.state === "RESPONDING") {
      return;
    }
    const claim = interaction.state === "CLAIMED" ? this.findActiveClaim(ref) : undefined;
    const interactionExpired = interaction.expiresAt <= now;
    const claimExpired = interaction.state === "CLAIMED" && (!claim || claim.expiresAt <= now);
    if (!interactionExpired && !claimExpired) return;

    if (claim) {
      const claimResult = this.database.prepare(
        `UPDATE interaction_claim SET state='EXPIRED',revision=revision+1,updated_at=@now
         WHERE bridge_identity_id=@bridgeIdentityId AND bridge_instance_id=@bridgeInstanceId AND
           codex_source_id=@codexSourceId AND provider_thread_id=@providerThreadId AND
           provider_turn_id=@providerTurnId AND interaction_id=@interactionId AND
           claim_id=@claimId AND revision=@claimRevision AND state='ACTIVE'`,
      ).run({
        ...interactionParams(ref),
        claimId: claim.claimId,
        claimRevision: claim.revision,
        now,
      });
      if (claimResult.changes !== 1) {
        throw new ConversationStoreError("CLAIM_NOT_OWNED", "expired claim CAS failed");
      }
    }

    const nextState = interactionExpired ? "EXPIRED" : "OPEN_UNCLAIMED";
    const interactionResult = this.database.prepare(
      `UPDATE interaction SET state=@nextState,revision=revision+1,updated_at=@now
       WHERE bridge_identity_id=@bridgeIdentityId AND bridge_instance_id=@bridgeInstanceId AND
         codex_source_id=@codexSourceId AND provider_thread_id=@providerThreadId AND
         provider_turn_id=@providerTurnId AND interaction_id=@interactionId AND
         revision=@expectedRevision AND state=@expectedState`,
    ).run({
      ...interactionParams(ref),
      nextState,
      expectedRevision: interaction.revision,
      expectedState: interaction.state,
      now,
    });
    if (interactionResult.changes !== 1) {
      throw new ConversationStoreError("INTERACTION_REVISION_CONFLICT", "interaction expiry CAS failed");
    }
  }

  private requireInteraction(ref: InteractionRef): InteractionRecord {
    const interaction = this.findInteraction(ref);
    if (!interaction) throw new ConversationStoreError("INTERACTION_NOT_OPEN", "interaction does not exist in source");
    return interaction;
  }

  private requireClaim(ref: InteractionRef, claimId: string): InteractionClaimRecord {
    const row = this.database.prepare(
      `SELECT * FROM interaction_claim WHERE bridge_identity_id=@bridgeIdentityId AND
       bridge_instance_id=@bridgeInstanceId AND codex_source_id=@codexSourceId AND
       provider_thread_id=@providerThreadId AND provider_turn_id=@providerTurnId AND
       interaction_id=@interactionId AND claim_id=@claimId`,
    ).get({ ...interactionParams(ref), claimId }) as InteractionClaimRow | undefined;
    if (!row) throw new ConversationStoreError("CLAIM_NOT_OWNED", "claim does not exist in source");
    return claimFromRow(row);
  }

  private validateClaimMutation(input: InteractionClaimMutationInput): void {
    assertAuthenticatedContext(input.context, input.ref.thread);
    assertInteractionRef(input.ref);
    assertExpectedRevision(input.expectedInteractionRevision);
    assertExpectedRevision(input.expectedClaimRevision);
    assertId(input.claimId, "claimId");
    assertClaimToken(input.claimToken);
  }

  private requireOwnedActiveClaim(
    input: InteractionClaimMutationInput,
    now: number,
  ): { interaction: InteractionRecord; claim: InteractionClaimRecord } {
    const interaction = this.requireInteraction(input.ref);
    assertExactEpoch(interaction.sourceEpoch, input.context.sourceEpoch);
    const claim = this.requireClaim(input.ref, input.claimId);
    if (interaction.revision !== input.expectedInteractionRevision) {
      throw new ConversationStoreError("INTERACTION_REVISION_CONFLICT", "interaction revision changed");
    }
    if (claim.revision !== input.expectedClaimRevision) {
      throw new ConversationStoreError("CLAIM_NOT_OWNED", "claim revision changed");
    }
    if (claim.actorId !== input.context.actorId || claim.tokenHash !== hashClaimToken(input.claimToken)) {
      throw new ConversationStoreError("CLAIM_NOT_OWNED", "authenticated actor or token mismatch");
    }
    if (claim.state !== "ACTIVE" || claim.expiresAt <= now || interaction.expiresAt <= now) {
      throw new ConversationStoreError("CLAIM_EXPIRED", "claim or interaction expired");
    }
    return { interaction, claim };
  }

  private recoverUncertainOperations(): void {
    this.assertLease();
    const rows = this.database.prepare(
      `SELECT * FROM operation WHERE state IN ('CALL_STARTED','PROVIDER_ACCEPTED')
       ORDER BY created_at,operation_id`,
    ).all() as OperationRow[];
    if (rows.length === 0) return;
    const transaction = this.database.transaction(() => {
      this.fenceLeaseInTransaction();
      for (const row of rows) {
        const operation = operationFromRow(row);
        this.updateOperationState(operation, "OUTCOME_UNKNOWN", {
          eventKind: "RESTART_REQUIRES_READ_ONLY_RECONCILE",
          dispatchAttemptId: operation.dispatchAttemptId,
          providerTurnId: operation.providerTurnId,
          detailsJson: canonicalizeJsonObject({ redispatchAuthorized: false }, OPERATION_JSON_MAX_BYTES),
        });
        this.consumeReservedEntryForOperation(operation.operationId);
        this.inject("recovery.after-operation");
      }
    });
    transaction.immediate();
  }

  private ensureSource(source: SourcePartition): void {
    assertSource(source);
    this.database.prepare(
      `INSERT OR IGNORE INTO source_partition (
         bridge_identity_id,bridge_instance_id,codex_source_id,created_at
       ) VALUES (@bridgeIdentityId,@bridgeInstanceId,@codexSourceId,@now)`,
    ).run({ ...sourceParams(source), now: this.clock() });
  }

  private inject(stage: StoreFaultStage): void {
    this.faultHook?.(stage);
  }

  /** Must run after BEGIN IMMEDIATE: the SQLite writer lock then fences takeover until commit. */
  private fenceLeaseInTransaction(): void {
    const now = this.clock();
    const result = this.database.prepare(
      `UPDATE writer_owner SET lease_expires_at=?,updated_at=?
       WHERE singleton=1 AND owner_id=? AND owner_epoch=? AND lease_expires_at>?`,
    ).run(now + this.leaseTtlMs, now, this.ownerId, this.ownerEpoch, now);
    if (result.changes !== 1) {
      throw new ConversationStoreError("WRITER_LEASE_LOST", "writer lease fence failed inside transaction");
    }
  }

  private assertLease(): void {
    this.assertOpen();
    const now = this.clock();
    // Renewing under this exact owner/epoch fence closes the check-to-transaction race.
    const result = this.database.prepare(
      `UPDATE writer_owner SET lease_expires_at=?,updated_at=?
       WHERE singleton=1 AND owner_id=? AND owner_epoch=? AND lease_expires_at>?`,
    ).run(now + this.leaseTtlMs, now, this.ownerId, this.ownerEpoch, now);
    if (result.changes !== 1) {
      throw new ConversationStoreError("WRITER_LEASE_LOST", "writer lease is absent, expired, or replaced");
    }
  }

  private assertOpen(): void {
    if (this.closed) throw new ConversationStoreError("STORE_CLOSED", "conversation store is closed");
  }
}

interface SchemaObjectRow {
  type: string;
  name: string;
  tableName: string;
  sql: string;
}

function readSchemaObjects(database: Database.Database): SchemaObjectRow[] {
  return database.prepare(
    `SELECT type,name,tbl_name AS tableName,sql FROM sqlite_master
     WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' ORDER BY type,name`,
  ).all() as SchemaObjectRow[];
}

function assertExistingSchemaShape(actual: SchemaObjectRow[]): void {
  const expectedDatabase = new Database(":memory:");
  try {
    expectedDatabase.exec(CONVERSATION_CORE_BOOTSTRAP_DDL);
    expectedDatabase.exec(CONVERSATION_CORE_DDL);
    const expected = readSchemaObjects(expectedDatabase);
    if (JSON.stringify(actual) !== JSON.stringify(expected)) {
      throw new Error("Unsupported conversation core schema shape");
    }
  } finally {
    expectedDatabase.close();
  }
}

interface PreparedAdmission {
  fingerprint: string;
  sourceEpochJson: string;
  targetJson: string;
  payloadJson: string;
  preconditionsJson: string;
}

function prepareAdmission(admission: OperationAdmission): PreparedAdmission {
  // Authority checks intentionally precede claimed-fingerprint comparison and every write.
  assertAuthenticatedContext(admission.context, admission.thread);
  assertId(admission.operationId, "operationId");
  assertId(admission.clientInstanceId, "clientInstanceId");
  assertId(admission.clientMessageId, "clientMessageId");
  assertId(admission.context.actorId, "actorId");
  assertId(admission.context.origin.id, "originId");
  const sourceEpochJson = canonicalizeJson(admission.context.sourceEpoch, {
    maxBytes: OPERATION_JSON_MAX_BYTES,
    requireObject: true,
  });
  const targetJson = canonicalizeJsonObject(admission.target, OPERATION_JSON_MAX_BYTES);
  const payloadJson = canonicalizeJsonObject(admission.payload, OPERATION_JSON_MAX_BYTES);
  const preconditionsJson = canonicalizeJsonObject(
    admission.preconditions as unknown as JsonObject,
    OPERATION_JSON_MAX_BYTES,
  );
  // Canonicalization runs first so hostile/cyclic/non-JSON shapes fail with INVALID_JSON;
  // closed operation schemas are then checked over the proven plain JSON values.
  validateTypedOperation(admission);
  const fingerprint = sha256CanonicalJson(
    {
      version: 1,
      sourceEpoch: admission.context.sourceEpoch,
      actorId: admission.context.actorId,
      origin: admission.context.origin,
      thread: admission.thread,
      admissionKey: {
        clientInstanceId: admission.clientInstanceId,
        clientMessageId: admission.clientMessageId,
      },
      operationCode: admission.operationCode,
      conflictFamily: admission.conflictFamily,
      target: admission.target,
      payload: admission.payload,
      preconditions: admission.preconditions,
    },
    OPERATION_JSON_MAX_BYTES,
  ).digest;
  if (admission.claimedFingerprint && admission.claimedFingerprint !== fingerprint) {
    throw new ConversationStoreError(
      "OPERATION_FINGERPRINT_CONFLICT",
      "claimed fingerprint does not match the server-computed RFC8785 fingerprint",
    );
  }
  return { fingerprint, sourceEpochJson, targetJson, payloadJson, preconditionsJson };
}

function validateTypedOperation(admission: OperationAdmission): void {
  const expected = {
    "OP-001": ["THREAD", "START_TURN", "THREAD_MUTATION"],
    "OP-002": ["QUEUE_ENTRY", "EDIT_QUEUED_INPUT", "QUEUE_CONTROL"],
    "OP-003": ["QUEUE_ENTRY", "CANCEL_QUEUED_INPUT", "QUEUE_CONTROL"],
    "OP-004": ["TURN", "STEER_ACTIVE_TURN", "THREAD_MUTATION"],
    "OP-005": ["QUEUE_ENTRY", "STEER_QUEUED_INPUT", "QUEUE_CONTROL"],
    "OP-006": ["TURN", "INTERRUPT_TURN", "THREAD_MUTATION"],
    "OP-016": ["INTERACTION", "CLAIM_INTERACTION", "INTERACTION_RESPONSE"],
    "OP-017": ["INTERACTION", "RENEW_INTERACTION", "INTERACTION_RESPONSE"],
    "OP-018": ["INTERACTION", "RELEASE_INTERACTION", "INTERACTION_RESPONSE"],
    "OP-019": ["INTERACTION", "RESPOND_APPROVAL", "INTERACTION_RESPONSE"],
    "OP-020": ["INTERACTION", "RESPOND_QUESTION", "INTERACTION_RESPONSE"],
    "OP-021": ["INTERACTION", "RESPOND_MCP_ELICITATION", "INTERACTION_RESPONSE"],
    "OP-022": ["INTERACTION", "RESPOND_EXIT_PLAN", "INTERACTION_RESPONSE"],
  } as const;
  const [targetKind, payloadKind, conflictFamily] = expected[admission.operationCode];
  if (
    admission.target.targetKind !== targetKind ||
    admission.payload.payloadKind !== payloadKind ||
    admission.conflictFamily !== conflictFamily ||
    admission.target.providerThreadId !== admission.thread.providerThreadId
  ) {
    throw new ConversationStoreError("INVALID_STATE_TRANSITION", "operation code/target/payload family mismatch");
  }
  assertClosedOperationTarget(admission.target);
  assertClosedObject(admission.payload, ["payloadKind", "body"], [], "operation payload");
  validateOperationBody(admission.operationCode, admission.payload.body);
  validateOperationPreconditions(admission.operationCode, admission.preconditions);
}

function assertClosedOperationTarget(target: OperationAdmission["target"]): void {
  if (target.targetKind === "THREAD") {
    assertClosedObject(target, ["targetKind", "providerThreadId"], [], "thread target");
    assertId(target.providerThreadId, "target.providerThreadId");
  } else if (target.targetKind === "TURN") {
    assertClosedObject(target, ["targetKind", "providerThreadId", "providerTurnId"], [], "turn target");
    assertId(target.providerThreadId, "target.providerThreadId");
    assertId(target.providerTurnId, "target.providerTurnId");
  } else if (target.targetKind === "QUEUE_ENTRY") {
    assertClosedObject(
      target,
      ["targetKind", "providerThreadId", "queueEntryId", "rootOperationId"],
      [],
      "queue target",
    );
    assertId(target.providerThreadId, "target.providerThreadId");
    assertId(target.queueEntryId, "target.queueEntryId");
    assertId(target.rootOperationId, "target.rootOperationId");
  } else {
    assertClosedObject(
      target,
      ["targetKind", "providerThreadId", "providerTurnId", "interactionId", "variant"],
      [],
      "interaction target",
    );
    assertId(target.providerThreadId, "target.providerThreadId");
    assertId(target.providerTurnId, "target.providerTurnId");
    assertId(target.interactionId, "target.interactionId");
    if (!["APPROVAL", "QUESTION", "MCP_ELICITATION", "EXIT_PLAN"].includes(target.variant)) {
      throw invalidOperationShape("interaction target variant is invalid");
    }
  }
}

function validateOperationPreconditions(
  operationCode: OperationCode,
  preconditions: OperationAdmission["preconditions"],
): void {
  const keys: Record<OperationCode, readonly string[]> = {
    "OP-001": ["expectedHeadVersion"],
    "OP-002": ["expectedLaneRevision", "expectedEntryRevision"],
    "OP-003": ["expectedLaneRevision", "expectedEntryRevision"],
    "OP-004": [],
    "OP-005": ["expectedLaneRevision", "expectedEntryRevision"],
    "OP-006": [],
    "OP-016": ["expectedInteractionRevision"],
    "OP-017": ["expectedInteractionRevision", "expectedClaimRevision"],
    "OP-018": ["expectedInteractionRevision", "expectedClaimRevision"],
    "OP-019": ["expectedInteractionRevision", "expectedClaimRevision"],
    "OP-020": ["expectedInteractionRevision", "expectedClaimRevision"],
    "OP-021": ["expectedInteractionRevision", "expectedClaimRevision"],
    "OP-022": ["expectedInteractionRevision", "expectedClaimRevision"],
  };
  const required = keys[operationCode];
  const object = assertClosedObject(preconditions, required, [], "operation preconditions");
  for (const key of required) {
    const value = object[key];
    if (!Number.isSafeInteger(value) || (value as number) < 0) {
      throw invalidOperationShape(`operation precondition ${key} is invalid`);
    }
  }
}

function validateOperationBody(operationCode: OperationCode, value: unknown): void {
  switch (operationCode) {
    case "OP-001":
    case "OP-002":
    case "OP-004":
      validateTurnInput(value);
      return;
    case "OP-003": {
      const body = assertClosedObject(value, ["reason"], [], "cancel body");
      if (body.reason !== "USER_REQUESTED") throw invalidOperationShape("cancel reason is invalid");
      return;
    }
    case "OP-005": {
      const body = assertClosedObject(value, ["activeTurn"], [], "queued steer body");
      const turn = assertClosedObject(body.activeTurn, ["providerThreadId", "providerTurnId"], [], "active turn");
      assertRequiredString(turn.providerThreadId, "activeTurn.providerThreadId");
      assertRequiredString(turn.providerTurnId, "activeTurn.providerTurnId");
      return;
    }
    case "OP-006": {
      const body = assertClosedObject(value, ["reason"], [], "interrupt body");
      if (body.reason !== "USER_REQUESTED" && body.reason !== "SAFETY_STOP") {
        throw invalidOperationShape("interrupt reason is invalid");
      }
      return;
    }
    case "OP-016": {
      const body = assertClosedObject(value, ["requestedLeaseSeconds"], [], "claim body");
      assertPositiveInteger(body.requestedLeaseSeconds, "requestedLeaseSeconds");
      return;
    }
    case "OP-017": {
      const body = assertClosedObject(value, ["requestedExtensionSeconds"], [], "renew body");
      assertPositiveInteger(body.requestedExtensionSeconds, "requestedExtensionSeconds");
      return;
    }
    case "OP-018":
      assertClosedObject(value, [], [], "release body");
      return;
    case "OP-019":
      validateApprovalResponse(value);
      return;
    case "OP-020":
      validateQuestionResponse(value);
      return;
    case "OP-021":
      validateMcpResponse(value);
      return;
    case "OP-022":
      validateExitPlanResponse(value);
  }
}

function validateTurnInput(value: unknown): void {
  const body = assertClosedObject(value, ["text", "imageRefs", "structuredRefs"], [], "turn input");
  assertRequiredString(body.text, "turn input text", true);
  if (!Array.isArray(body.imageRefs) || !Array.isArray(body.structuredRefs)) {
    throw invalidOperationShape("turn input attachment refs must be arrays");
  }
  for (const candidate of body.imageRefs) validateImageRef(candidate);
  for (const candidate of body.structuredRefs) validateStructuredRef(candidate);
}

function validateImageRef(value: unknown): void {
  const image = assertClosedObject(value, ["imageId", "contentRef"], ["pixelWidth", "pixelHeight"], "image ref");
  assertRequiredString(image.imageId, "imageId");
  const content = assertClosedObject(
    image.contentRef,
    ["contentRefId", "source", "mediaType", "sizeBytes", "sha256", "objectGeneration"],
    [],
    "content ref",
  );
  assertRequiredString(content.contentRefId, "contentRefId");
  assertRequiredString(content.mediaType, "mediaType");
  assertPositiveInteger(content.sizeBytes, "sizeBytes", true);
  if (typeof content.sha256 !== "string" || !SHA256_PATTERN.test(content.sha256)) {
    throw invalidOperationShape("contentRef sha256 is invalid");
  }
  assertPositiveInteger(content.objectGeneration, "objectGeneration", true);
  const source = assertClosedObject(
    content.source,
    ["bridgeIdentityId", "bridgeInstanceId", "codexSourceId"],
    [],
    "content source",
  );
  assertRequiredString(source.bridgeIdentityId, "content source bridgeIdentityId");
  assertRequiredString(source.bridgeInstanceId, "content source bridgeInstanceId");
  assertRequiredString(source.codexSourceId, "content source codexSourceId");
  for (const dimension of [image.pixelWidth, image.pixelHeight]) {
    if (dimension !== undefined) assertPositiveInteger(dimension, "image dimension");
  }
}

function validateStructuredRef(value: unknown): void {
  const reference = assertClosedObject(value, ["kind", "name", "path"], [], "structured ref");
  if (reference.kind !== "skill_ref" && reference.kind !== "file_mention_ref") {
    throw invalidOperationShape("structured ref kind is invalid");
  }
  assertRequiredString(reference.name, "structured ref name");
  assertRequiredString(reference.path, "structured ref path");
}

function validateApprovalResponse(value: unknown): void {
  const first = assertClosedObject(value, ["disposition"], ["message"], "approval response");
  if (first.disposition === "approve") {
    assertClosedObject(value, ["disposition"], [], "approval response");
  } else if (first.disposition === "reject") {
    assertClosedObject(value, ["disposition"], ["message"], "approval response");
    if (first.message !== undefined) assertRequiredString(first.message, "approval rejection message", true);
  } else {
    throw invalidOperationShape("approval disposition is invalid");
  }
}

function validateQuestionResponse(value: unknown): void {
  const body = assertClosedObject(value, ["answers"], [], "question response");
  if (!Array.isArray(body.answers)) throw invalidOperationShape("question answers must be an array");
  const questionIds = new Set<string>();
  for (const candidate of body.answers) {
    const answer = assertClosedObject(candidate, ["kind", "questionId"], ["choice", "choices", "text"], "question answer");
    assertRequiredString(answer.questionId, "questionId");
    if (questionIds.has(answer.questionId as string)) throw invalidOperationShape("duplicate question answer");
    questionIds.add(answer.questionId as string);
    if (answer.kind === "single_choice") {
      assertClosedObject(candidate, ["kind", "questionId", "choice"], [], "single choice answer");
      assertRequiredString(answer.choice, "choice");
    } else if (answer.kind === "multi_choice") {
      assertClosedObject(candidate, ["kind", "questionId", "choices"], [], "multi choice answer");
      if (!Array.isArray(answer.choices)) throw invalidOperationShape("choices must be an array");
      for (const choice of answer.choices) assertRequiredString(choice, "choice");
    } else if (answer.kind === "free_text") {
      assertClosedObject(candidate, ["kind", "questionId", "text"], [], "free text answer");
      assertRequiredString(answer.text, "answer text", true);
    } else {
      throw invalidOperationShape("question answer kind is invalid");
    }
  }
}

function validateMcpResponse(value: unknown): void {
  const body = assertClosedObject(value, ["disposition"], ["text", "confirmed", "message"], "MCP response");
  if (body.disposition === "accept_text") {
    assertClosedObject(value, ["disposition", "text"], [], "MCP text response");
    assertRequiredString(body.text, "MCP response text", true);
  } else if (body.disposition === "accept_confirmation") {
    assertClosedObject(value, ["disposition", "confirmed"], [], "MCP confirmation response");
    if (typeof body.confirmed !== "boolean") throw invalidOperationShape("MCP confirmation is invalid");
  } else if (body.disposition === "reject") {
    assertClosedObject(value, ["disposition"], ["message"], "MCP rejection response");
    if (body.message !== undefined) assertRequiredString(body.message, "MCP rejection message", true);
  } else {
    throw invalidOperationShape("MCP response disposition is invalid");
  }
}

function validateExitPlanResponse(value: unknown): void {
  const body = assertClosedObject(value, ["disposition"], ["feedback"], "exit-plan response");
  if (body.disposition === "accept") {
    assertClosedObject(value, ["disposition"], [], "exit-plan response");
  } else if (body.disposition === "reject") {
    assertClosedObject(value, ["disposition"], ["feedback"], "exit-plan response");
    if (body.feedback !== undefined) assertRequiredString(body.feedback, "exit-plan feedback", true);
  } else {
    throw invalidOperationShape("exit-plan disposition is invalid");
  }
}

function assertClosedObject(
  value: unknown,
  required: readonly string[],
  optional: readonly string[],
  label: string,
): Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw invalidOperationShape(`${label} must be an object`);
  }
  const object = value as Record<string, unknown>;
  const allowed = new Set([...required, ...optional]);
  const keys = Object.keys(object);
  if (required.some((key) => !Object.hasOwn(object, key)) || keys.some((key) => !allowed.has(key))) {
    throw invalidOperationShape(`${label} has missing or unknown fields`);
  }
  return object;
}

function assertRequiredString(value: unknown, label: string, allowEmpty = false): asserts value is string {
  if (typeof value !== "string" || (!allowEmpty && value.length === 0)) {
    throw invalidOperationShape(`${label} must be a string`);
  }
}

function assertPositiveInteger(value: unknown, label: string, allowZero = false): asserts value is number {
  if (!Number.isSafeInteger(value) || (allowZero ? (value as number) < 0 : (value as number) <= 0)) {
    throw invalidOperationShape(`${label} must be ${allowZero ? "a non-negative" : "a positive"} integer`);
  }
}

function invalidOperationShape(message: string): ConversationStoreError {
  return new ConversationStoreError("INVALID_STATE_TRANSITION", message);
}

function assertExistingAdmission(
  existing: OperationRecord,
  admission: OperationAdmission,
  computedFingerprint: string,
): void {
  if (existing.fingerprint !== computedFingerprint) {
    throw new ConversationStoreError("OPERATION_FINGERPRINT_CONFLICT", "admission key has another fingerprint");
  }
  if (existing.operationId !== admission.operationId) {
    throw new ConversationStoreError("OPERATION_ID_CONFLICT", "admission key has another operation id");
  }
}

function canonicalDatabasePath(filePath: string): string {
  if (!filePath || filePath === ":memory:") {
    throw new ConversationStoreError("INVALID_DATABASE_PATH", "a real database file path is required");
  }
  const absolute = resolve(filePath);
  const requestedParent = dirname(absolute);
  let realParent: string;
  try {
    realParent = realpathSync.native(requestedParent);
  } catch {
    throw new ConversationStoreError("INVALID_DATABASE_PATH", "database parent does not exist");
  }
  const canonical = join(realParent, basename(absolute));
  if (existsSync(canonical)) {
    const stat = lstatSync(canonical);
    if (stat.isSymbolicLink() || !stat.isFile()) {
      throw new ConversationStoreError("INVALID_DATABASE_PATH", "database path is symlink or non-regular");
    }
    if (realpathSync.native(canonical) !== canonical) {
      throw new ConversationStoreError("INVALID_DATABASE_PATH", "database file is not canonical");
    }
  }
  return canonical;
}

function acquireWriterLease(
  database: Database.Database,
  ownerId: string,
  now: number,
  ttl: number,
): number {
  let epoch = 1;
  const transaction = database.transaction(() => {
    const current = database.prepare("SELECT * FROM writer_owner WHERE singleton=1").get() as
      | WriterOwnerRow
      | undefined;
    if (!current) {
      database.prepare(
        `INSERT INTO writer_owner (
           singleton,owner_id,owner_pid,owner_epoch,lease_expires_at,updated_at
         ) VALUES (1,?,?,?,?,?)`,
      ).run(ownerId, process.pid, 1, now + ttl, now);
      epoch = 1;
      return;
    }
    if (current.lease_expires_at > now && processIsAlive(current.owner_pid)) {
      throw new ConversationStoreError("WRITER_ALREADY_OPEN", "database has a live persistent writer lease");
    }
    epoch = current.owner_epoch + 1;
    database.prepare(
      `UPDATE writer_owner SET owner_id=?,owner_pid=?,owner_epoch=?,lease_expires_at=?,updated_at=?
       WHERE singleton=1 AND owner_epoch=?`,
    ).run(ownerId, process.pid, epoch, now + ttl, now, current.owner_epoch);
  });
  transaction.immediate();
  return epoch;
}

function processIsAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === "EPERM";
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

function materializationFromRow(row: MaterializationRow): TimelineMaterializationRecord {
  return {
    thread: threadFromRow(row),
    materializationId: row.materialization_id,
    sourceEpoch: parseStoredJsonObject(row.source_epoch_json) as unknown as SourceEpoch,
    evidence: parseStoredJsonObject(row.evidence_json) as unknown as ProviderReadEvidence,
    readEvidenceDigest: row.read_evidence_digest,
    state: row.state,
    pageCount: row.page_count,
    itemCount: row.item_count,
    gapCount: row.gap_count,
    totalBytes: row.total_bytes,
  };
}

function timelineReadbackFromRows(
  thread: ThreadRef,
  head: TimelineHeadRow,
  itemRows: TimelineItemRow[],
  gapRows: TimelineGapRow[],
  islandRows: TimelineIslandRow[],
): TimelineReadback {
  if (!head.materialization_digest || !head.order_digest || !head.coverage_digest || !head.verified_at) {
    throw new ConversationStoreError("TIMELINE_CANDIDATE_REJECTED", "head points to unverified materialization");
  }
  return {
    thread,
    headRevision: head.head_revision,
    materializationId: head.materialization_id,
    sourceEpoch: parseStoredJsonObject(head.source_epoch_json) as unknown as SourceEpoch,
    evidence: parseStoredJsonObject(head.evidence_json) as unknown as ProviderReadEvidence,
    receipt: {
      materializationDigest: head.materialization_digest,
      orderDigest: head.order_digest,
      coverageDigest: head.coverage_digest,
      readEvidenceDigest: head.read_evidence_digest,
      verifiedAt: head.verified_at,
    },
    totalItemCount: head.item_count,
    totalGapCount: head.gap_count,
    items: itemRows.map(timelineItemFromRow),
    gaps: gapRows.map(timelineGapFromRow),
    coverageIslands: islandRows.map(timelineIslandFromRow),
  };
}

function timelineItemFromRow(row: TimelineItemRow): TimelineItemRecord {
  return {
    itemId: row.item_id,
    providerTurnId: row.provider_turn_id,
    turnOrdinal: row.turn_ordinal,
    itemOrdinal: row.item_ordinal,
    timelineOrdinal: row.timeline_ordinal,
    kind: row.item_kind,
    payload: parseStoredJsonObject(row.payload_json),
  };
}

function timelineGapFromRow(row: TimelineGapRow): TimelineGapRecord {
  return {
    gapId: row.gap_id,
    gapOrdinal: row.gap_ordinal,
    gapKind: row.gap_kind,
    firstMissingTimelineOrdinal: row.first_missing_timeline_ordinal,
    lastMissingTimelineOrdinal: row.last_missing_timeline_ordinal,
    reason: row.reason,
    descriptor: parseStoredJsonObject(row.descriptor_json),
  };
}

function timelineIslandFromRow(row: TimelineIslandRow): TimelineCoverageIslandRecord {
  return {
    islandId: row.island_id,
    islandOrdinal: row.island_ordinal,
    firstTimelineOrdinal: row.first_timeline_ordinal,
    lastTimelineOrdinal: row.last_timeline_ordinal,
    structuralCoverage: row.structural_coverage,
    payloadCoverage: row.payload_coverage,
  };
}

function operationFromRow(row: OperationRow): OperationRecord {
  return {
    thread: threadFromRow(row),
    sourceEpoch: parseStoredJsonObject(row.source_epoch_json) as unknown as SourceEpoch,
    actorId: row.actor_id,
    origin: { kind: row.origin_kind, id: row.origin_id },
    operationId: row.operation_id,
    clientInstanceId: row.client_instance_id,
    clientMessageId: row.client_message_id,
    operationCode: row.operation_code,
    conflictFamily: row.conflict_family,
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
    target: parseStoredJsonObject(row.target_json) as unknown as OperationRecord["target"],
    payload: parseStoredJsonObject(row.payload_json) as unknown as OperationRecord["payload"],
    preconditions: parseStoredJsonObject(row.preconditions_json) as unknown as OperationRecord["preconditions"],
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
    payload: parseStoredJsonObject(row.payload_json),
  };
}

function interactionRefFromRow(row: InteractionRow | InteractionClaimRow): InteractionRef {
  return {
    thread: threadFromRow(row),
    providerTurnId: row.provider_turn_id,
    interactionId: row.interaction_id,
  };
}

function interactionFromRow(row: InteractionRow): InteractionRecord {
  return {
    ref: interactionRefFromRow(row),
    sourceEpoch: parseStoredJsonObject(row.source_epoch_json) as unknown as SourceEpoch,
    providerRequestId: row.provider_request_id,
    variant: row.variant,
    state: row.state,
    revision: row.revision,
    expiresAt: row.expires_at,
    descriptor: parseStoredJsonObject(row.descriptor_json),
    ...(row.response_fingerprint ? { responseFingerprint: row.response_fingerprint } : {}),
    ...(row.response_operation_id ? { responseOperationId: row.response_operation_id } : {}),
    ...(row.response_actor_id ? { responseActorId: row.response_actor_id } : {}),
    ...(row.response_json ? { response: parseStoredJsonObject(row.response_json) } : {}),
    ...(row.resolution_evidence_digest
      ? { resolutionEvidenceDigest: row.resolution_evidence_digest }
      : {}),
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

function validateTimelinePage(input: TimelinePageInput): void {
  const itemIdentities = new Set<string>();
  const timelineOrdinals = new Set<number>();
  const turnItemOrdinals = new Set<string>();
  for (const item of input.items) {
    assertId(item.itemId, "itemId");
    assertId(item.providerTurnId, "providerTurnId");
    assertSignedOrdinal(item.turnOrdinal, "turnOrdinal");
    assertOrdinal(item.itemOrdinal, "itemOrdinal");
    assertSignedOrdinal(item.timelineOrdinal, "timelineOrdinal");
    assertId(item.kind, "itemKind");
    const itemIdentity = `${item.providerTurnId}\u0000${item.itemId}`;
    const turnItemKey = `${item.turnOrdinal}:${item.itemOrdinal}`;
    if (
      itemIdentities.has(itemIdentity) || timelineOrdinals.has(item.timelineOrdinal) ||
      turnItemOrdinals.has(turnItemKey)
    ) {
      throw new ConversationStoreError("TIMELINE_CANDIDATE_REJECTED", "duplicate timeline item identity or ordinal");
    }
    itemIdentities.add(itemIdentity);
    timelineOrdinals.add(item.timelineOrdinal);
    turnItemOrdinals.add(turnItemKey);
  }
  const gapIds = new Set<string>();
  const gapOrdinals = new Set<number>();
  for (const gap of input.gaps) {
    assertId(gap.gapId, "gapId");
    assertOrdinal(gap.gapOrdinal, "gapOrdinal");
    assertSignedOrdinal(gap.firstMissingTimelineOrdinal, "firstMissingTimelineOrdinal");
    assertSignedOrdinal(gap.lastMissingTimelineOrdinal, "lastMissingTimelineOrdinal");
    if (gap.lastMissingTimelineOrdinal < gap.firstMissingTimelineOrdinal) {
      throw new ConversationStoreError("TIMELINE_CANDIDATE_REJECTED", "gap endpoints are reversed");
    }
    if (gapIds.has(gap.gapId) || gapOrdinals.has(gap.gapOrdinal)) {
      throw new ConversationStoreError("TIMELINE_CANDIDATE_REJECTED", "duplicate timeline gap identity or ordinal");
    }
    gapIds.add(gap.gapId);
    gapOrdinals.add(gap.gapOrdinal);
  }
  const islandIds = new Set<string>();
  const islandOrdinals = new Set<number>();
  for (const island of input.coverageIslands) {
    assertId(island.islandId, "islandId");
    assertOrdinal(island.islandOrdinal, "islandOrdinal");
    assertSignedOrdinal(island.firstTimelineOrdinal, "firstTimelineOrdinal");
    assertSignedOrdinal(island.lastTimelineOrdinal, "lastTimelineOrdinal");
    if (island.lastTimelineOrdinal < island.firstTimelineOrdinal) {
      throw new ConversationStoreError("TIMELINE_CANDIDATE_REJECTED", "coverage island endpoints are reversed");
    }
    if (islandIds.has(island.islandId) || islandOrdinals.has(island.islandOrdinal)) {
      throw new ConversationStoreError("TIMELINE_CANDIDATE_REJECTED", "duplicate coverage island identity or ordinal");
    }
    islandIds.add(island.islandId);
    islandOrdinals.add(island.islandOrdinal);
  }
}

function verifyPageChain(pages: TimelinePageRow[], expectedLastPageDigest?: string): void {
  let previous: string | undefined;
  pages.forEach((page, index) => {
    if (page.page_index !== index || (page.previous_page_digest ?? undefined) !== previous) {
      throw new ConversationStoreError("TIMELINE_PAGE_CHAIN_INVALID", "page index or previous digest chain is open");
    }
    if (Buffer.byteLength(page.body_json, "utf8") !== page.body_bytes || sha256Text(page.body_json) !== page.page_digest) {
      throw new ConversationStoreError("TIMELINE_PAGE_CHAIN_INVALID", "page body digest or count mismatch");
    }
    const body = parseStoredJsonObject(page.body_json);
    if (
      body.pageIndex !== index ||
      (body.previousPageDigest as string | undefined) !== previous ||
      !Array.isArray(body.items) || body.items.length !== page.item_count ||
      !Array.isArray(body.gaps) || body.gaps.length !== page.gap_count
    ) {
      throw new ConversationStoreError("TIMELINE_PAGE_CHAIN_INVALID", "page body counters do not close");
    }
    previous = page.page_digest;
  });
  if (previous !== expectedLastPageDigest) {
    throw new ConversationStoreError("TIMELINE_PAGE_CHAIN_INVALID", "last page digest mismatch");
  }
}

function verifyPageChildren(
  pages: TimelinePageRow[],
  items: TimelineItemRecord[],
  gaps: TimelineGapRecord[],
  islands: TimelineCoverageIslandRecord[],
): void {
  const pageItems: unknown[] = [];
  const pageGaps: unknown[] = [];
  const pageIslands: unknown[] = [];
  for (const page of pages) {
    const body = parseStoredJsonObject(page.body_json);
    if (!Array.isArray(body.items) || !Array.isArray(body.gaps) || !Array.isArray(body.coverageIslands)) {
      throw new ConversationStoreError("TIMELINE_PAGE_CHAIN_INVALID", "page body collections are incomplete");
    }
    pageItems.push(...body.items);
    pageGaps.push(...body.gaps);
    pageIslands.push(...body.coverageIslands);
  }
  for (const [label, pageValue, childValue] of [
    ["items", pageItems, items],
    ["gaps", pageGaps, gaps],
    ["coverage islands", pageIslands, islands],
  ] as const) {
    if (
      canonicalizeJson(pageValue, { maxBytes: MAX_TIMELINE_BYTES }) !==
      canonicalizeJson(childValue, { maxBytes: MAX_TIMELINE_BYTES })
    ) {
      throw new ConversationStoreError("TIMELINE_PAGE_CHAIN_INVALID", `page ${label} do not match materialized rows`);
    }
  }
}

function verifyStoredTimelineReceipt(
  head: TimelineHeadRow,
  pages: TimelinePageRow[],
  items: TimelineItemRecord[],
  gaps: TimelineGapRecord[],
  islands: TimelineCoverageIslandRecord[],
): void {
  if (
    head.state !== "SEALED" || !head.materialization_digest || !head.order_digest ||
    !head.coverage_digest || !head.verified_at ||
    head.page_count !== pages.length || head.item_count !== items.length || head.gap_count !== gaps.length ||
    head.total_bytes !== pages.reduce((total, page) => total + page.body_bytes, 0)
  ) {
    throw new ConversationStoreError("TIMELINE_CANDIDATE_REJECTED", "sealed timeline counters or receipt are invalid");
  }
  const lastPageDigest = pages.length === 0 ? undefined : pages[pages.length - 1]!.page_digest;
  verifyPageChain(pages, lastPageDigest);
  verifyPageChildren(pages, items, gaps, islands);
  const emptyProof = head.empty_proof_json
    ? parseStoredJsonObject(head.empty_proof_json) as unknown as TimelineSealInput["emptyProof"]
    : undefined;
  verifyTimelineCoverage(
    parseStoredJsonObject(head.evidence_json) as unknown as ProviderReadEvidence,
    items,
    gaps,
    islands,
    emptyProof,
    head.read_evidence_digest,
  );
  const orderDigest = sha256CanonicalJson(
    items.map((item) => ({
      providerTurnId: item.providerTurnId,
      itemId: item.itemId,
      turnOrdinal: item.turnOrdinal,
      itemOrdinal: item.itemOrdinal,
      timelineOrdinal: item.timelineOrdinal,
    })),
    MAX_TIMELINE_BYTES,
  ).digest;
  const coverageDigest = sha256CanonicalJson({ islands, gaps }, MAX_TIMELINE_BYTES).digest;
  const materializationDigest = sha256CanonicalJson(
    {
      materializationId: head.materialization_id,
      readEvidenceDigest: head.read_evidence_digest,
      pageDigests: pages.map((page) => page.page_digest),
      orderDigest,
      coverageDigest,
      itemCount: items.length,
      gapCount: gaps.length,
    },
    MAX_TIMELINE_BYTES,
  ).digest;
  if (
    orderDigest !== head.order_digest || coverageDigest !== head.coverage_digest ||
    materializationDigest !== head.materialization_digest
  ) {
    throw new ConversationStoreError("TIMELINE_CANDIDATE_REJECTED", "sealed timeline verification receipt mismatch");
  }
}

export function verifyTimelineCoverage(
  evidence: ProviderReadEvidence,
  items: TimelineItemRecord[],
  gaps: TimelineGapRecord[],
  islands: TimelineCoverageIslandRecord[],
  emptyProof: TimelineSealInput["emptyProof"],
  readEvidenceDigest: string,
): void {
  validateReadEvidence(evidence);
  if (items.length === 0) {
    if (
      evidence.readScope !== "WHOLE_SCOPE" || evidence.firstTimelineOrdinal !== 0 ||
      evidence.lastTimelineOrdinal !== 0 || gaps.length !== 0 || islands.length !== 0 ||
      !emptyProof || emptyProof.proofKind !== "PROVIDER_CONFIRMED_EMPTY" ||
      emptyProof.providerRevision !== evidence.providerRevision ||
      emptyProof.observationDigest !== readEvidenceDigest
    ) {
      throw new ConversationStoreError("TIMELINE_CANDIDATE_REJECTED", "empty timeline lacks exact whole-scope proof");
    }
    return;
  }
  if (emptyProof) throw new ConversationStoreError("TIMELINE_CANDIDATE_REJECTED", "non-empty timeline has empty proof");
  if (islands.length === 0) {
    throw new ConversationStoreError("TIMELINE_CANDIDATE_REJECTED", "non-empty timeline lacks coverage islands");
  }
  let previousTimeline: number | undefined;
  let previousTurn: number | undefined;
  let previousItem: number | undefined;
  const providerTurnByOrdinal = new Map<number, string>();
  const ordinalByProviderTurn = new Map<string, number>();
  const itemIdentities = new Set<string>();
  for (const item of items) {
    assertId(item.itemId, "itemId");
    assertId(item.providerTurnId, "providerTurnId");
    assertSignedOrdinal(item.turnOrdinal, "turnOrdinal");
    assertOrdinal(item.itemOrdinal, "itemOrdinal");
    assertSignedOrdinal(item.timelineOrdinal, "timelineOrdinal");
    if (
      previousTimeline !== undefined &&
      (item.timelineOrdinal <= previousTimeline ||
        (previousTurn !== undefined && item.turnOrdinal < previousTurn))
    ) {
      throw new ConversationStoreError("TIMELINE_CANDIDATE_REJECTED", "timeline order is not monotonic");
    }
    if (
      previousTurn !== undefined && previousItem !== undefined &&
      item.turnOrdinal === previousTurn && item.itemOrdinal <= previousItem
    ) {
      throw new ConversationStoreError("TIMELINE_CANDIDATE_REJECTED", "item ordinal is not monotonic within turn");
    }
    if (
      previousTurn !== undefined && previousItem !== undefined &&
      item.turnOrdinal === previousTurn && item.itemOrdinal !== previousItem + 1
    ) {
      throw new ConversationStoreError("TIMELINE_CANDIDATE_REJECTED", "item ordinal is not contiguous within turn");
    }
    if (item.turnOrdinal !== previousTurn && item.itemOrdinal !== 0) {
      throw new ConversationStoreError("TIMELINE_CANDIDATE_REJECTED", "first item ordinal in a turn must be zero");
    }
    const itemIdentity = `${item.providerTurnId}\u0000${item.itemId}`;
    if (itemIdentities.has(itemIdentity)) {
      throw new ConversationStoreError("TIMELINE_CANDIDATE_REJECTED", "duplicate provider turn/item identity");
    }
    itemIdentities.add(itemIdentity);
    const knownTurnId = providerTurnByOrdinal.get(item.turnOrdinal);
    const knownTurnOrdinal = ordinalByProviderTurn.get(item.providerTurnId);
    if (
      (knownTurnId !== undefined && knownTurnId !== item.providerTurnId) ||
      (knownTurnOrdinal !== undefined && knownTurnOrdinal !== item.turnOrdinal)
    ) {
      throw new ConversationStoreError("TIMELINE_CANDIDATE_REJECTED", "provider turn and turn ordinal mapping is not one-to-one");
    }
    providerTurnByOrdinal.set(item.turnOrdinal, item.providerTurnId);
    ordinalByProviderTurn.set(item.providerTurnId, item.turnOrdinal);
    previousTimeline = item.timelineOrdinal;
    previousItem = item.itemOrdinal;
    previousTurn = item.turnOrdinal;
  }

  const structuralGaps: TimelineGapRecord[] = [];
  const payloadGaps: TimelineGapRecord[] = [];
  let lastStructuralGapEnd: number | undefined;
  let lastPayloadGapEnd: number | undefined;
  gaps.forEach((gap, index) => {
    assertId(gap.gapId, "gapId");
    assertOrdinal(gap.gapOrdinal, "gapOrdinal");
    assertSignedOrdinal(gap.firstMissingTimelineOrdinal, "firstMissingTimelineOrdinal");
    assertSignedOrdinal(gap.lastMissingTimelineOrdinal, "lastMissingTimelineOrdinal");
    if (
      gap.gapOrdinal !== index ||
      gap.lastMissingTimelineOrdinal < gap.firstMissingTimelineOrdinal ||
      gap.firstMissingTimelineOrdinal < evidence.firstTimelineOrdinal ||
      gap.lastMissingTimelineOrdinal > evidence.lastTimelineOrdinal
    ) {
      throw new ConversationStoreError("TIMELINE_CANDIDATE_REJECTED", "gap ordinal or evidence range is invalid");
    }
    if (gap.gapKind === "STRUCTURAL") {
      if (lastStructuralGapEnd !== undefined && gap.firstMissingTimelineOrdinal <= lastStructuralGapEnd) {
        throw new ConversationStoreError("TIMELINE_CANDIDATE_REJECTED", "structural gaps overlap or are unordered");
      }
      structuralGaps.push(gap);
      lastStructuralGapEnd = gap.lastMissingTimelineOrdinal;
    } else {
      if (lastPayloadGapEnd !== undefined && gap.firstMissingTimelineOrdinal <= lastPayloadGapEnd) {
        throw new ConversationStoreError("TIMELINE_CANDIDATE_REJECTED", "payload gaps overlap or are unordered");
      }
      payloadGaps.push(gap);
      lastPayloadGapEnd = gap.lastMissingTimelineOrdinal;
    }
  });

  let lastIslandEnd: number | undefined;
  let itemIslandCursor = 0;
  let structuralGapCursor = 0;
  let payloadGapCursor = 0;
  islands.forEach((island, index) => {
    assertId(island.islandId, "islandId");
    assertOrdinal(island.islandOrdinal, "islandOrdinal");
    assertSignedOrdinal(island.firstTimelineOrdinal, "firstTimelineOrdinal");
    assertSignedOrdinal(island.lastTimelineOrdinal, "lastTimelineOrdinal");
    if (
      island.islandOrdinal !== index ||
      island.lastTimelineOrdinal < island.firstTimelineOrdinal ||
      (lastIslandEnd !== undefined && island.firstTimelineOrdinal <= lastIslandEnd) ||
      island.firstTimelineOrdinal < evidence.firstTimelineOrdinal ||
      island.lastTimelineOrdinal > evidence.lastTimelineOrdinal
    ) {
      throw new ConversationStoreError("TIMELINE_CANDIDATE_REJECTED", "coverage islands overlap or are unordered");
    }
    if (
      itemIslandCursor < items.length &&
      items[itemIslandCursor]!.timelineOrdinal < island.firstTimelineOrdinal
    ) {
      throw new ConversationStoreError("TIMELINE_CANDIDATE_REJECTED", "timeline item is outside coverage islands");
    }
    const firstItemIndex = itemIslandCursor;
    while (
      itemIslandCursor < items.length &&
      items[itemIslandCursor]!.timelineOrdinal <= island.lastTimelineOrdinal
    ) itemIslandCursor += 1;
    if (itemIslandCursor === firstItemIndex) {
      throw new ConversationStoreError("TIMELINE_CANDIDATE_REJECTED", "coverage island contains no materialized item");
    }

    while (
      structuralGapCursor < structuralGaps.length &&
      structuralGaps[structuralGapCursor]!.lastMissingTimelineOrdinal < island.firstTimelineOrdinal &&
      island.firstTimelineOrdinal - structuralGaps[structuralGapCursor]!.lastMissingTimelineOrdinal > 1
    ) structuralGapCursor += 1;
    const hasStructuralGap = structuralGapCursor < structuralGaps.length &&
      rangesTouch(
        island.firstTimelineOrdinal,
        island.lastTimelineOrdinal,
        structuralGaps[structuralGapCursor]!.firstMissingTimelineOrdinal,
        structuralGaps[structuralGapCursor]!.lastMissingTimelineOrdinal,
      );
    while (
      payloadGapCursor < payloadGaps.length &&
      payloadGaps[payloadGapCursor]!.lastMissingTimelineOrdinal < island.firstTimelineOrdinal
    ) payloadGapCursor += 1;
    const hasPayloadGap = payloadGapCursor < payloadGaps.length &&
      payloadGaps[payloadGapCursor]!.firstMissingTimelineOrdinal <= island.lastTimelineOrdinal;
    if ((island.structuralCoverage === "PARTIAL") !== hasStructuralGap) {
      throw new ConversationStoreError(
        "TIMELINE_CANDIDATE_REJECTED",
        "coverage island structural status disagrees with structural gaps",
      );
    }
    if ((island.payloadCoverage === "PARTIAL") !== hasPayloadGap) {
      throw new ConversationStoreError(
        "TIMELINE_CANDIDATE_REJECTED",
        "coverage island payload status disagrees with payload gaps",
      );
    }
    lastIslandEnd = island.lastTimelineOrdinal;
  });
  if (itemIslandCursor !== items.length) {
    throw new ConversationStoreError("TIMELINE_CANDIDATE_REJECTED", "timeline item is outside coverage islands");
  }

  let payloadIslandCursor = 0;
  let payloadItemCursor = 0;
  for (const gap of payloadGaps) {
    while (
      payloadIslandCursor < islands.length &&
      islands[payloadIslandCursor]!.lastTimelineOrdinal < gap.firstMissingTimelineOrdinal
    ) payloadIslandCursor += 1;
    const island = islands[payloadIslandCursor];
    if (
      !island || gap.firstMissingTimelineOrdinal < island.firstTimelineOrdinal ||
      gap.lastMissingTimelineOrdinal > island.lastTimelineOrdinal
    ) {
      throw new ConversationStoreError("TIMELINE_CANDIDATE_REJECTED", "payload gap is outside a coverage island");
    }
    while (
      payloadItemCursor < items.length &&
      items[payloadItemCursor]!.timelineOrdinal < gap.firstMissingTimelineOrdinal
    ) payloadItemCursor += 1;
    let expectedOrdinal = gap.firstMissingTimelineOrdinal;
    while (true) {
      if (
        payloadItemCursor >= items.length ||
        items[payloadItemCursor]!.timelineOrdinal !== expectedOrdinal
      ) {
        throw new ConversationStoreError(
          "TIMELINE_CANDIDATE_REJECTED",
          "payload gap does not identify a materialized item",
        );
      }
      payloadItemCursor += 1;
      if (expectedOrdinal === gap.lastMissingTimelineOrdinal) break;
      expectedOrdinal += 1;
    }
  }

  const rangeLength = evidence.lastTimelineOrdinal - evidence.firstTimelineOrdinal + 1;
  let coveredOffset = 0;
  let itemCoverageCursor = 0;
  let gapCoverageCursor = 0;
  while (coveredOffset < rangeLength) {
    const itemOffset = itemCoverageCursor < items.length
      ? items[itemCoverageCursor]!.timelineOrdinal - evidence.firstTimelineOrdinal
      : Number.POSITIVE_INFINITY;
    const gapStartOffset = gapCoverageCursor < structuralGaps.length
      ? structuralGaps[gapCoverageCursor]!.firstMissingTimelineOrdinal - evidence.firstTimelineOrdinal
      : Number.POSITIVE_INFINITY;
    if (itemOffset < coveredOffset || gapStartOffset < coveredOffset || itemOffset === gapStartOffset) {
      throw new ConversationStoreError("TIMELINE_CANDIDATE_REJECTED", "structural gap overlaps a materialized item");
    }
    if (itemOffset === coveredOffset) {
      itemCoverageCursor += 1;
      coveredOffset += 1;
      continue;
    }
    if (gapStartOffset === coveredOffset) {
      coveredOffset = structuralGaps[gapCoverageCursor]!.lastMissingTimelineOrdinal -
        evidence.firstTimelineOrdinal + 1;
      gapCoverageCursor += 1;
      continue;
    }
    throw new ConversationStoreError(
      "TIMELINE_CANDIDATE_REJECTED",
      `unproved timeline hole at ordinal ${evidence.firstTimelineOrdinal + coveredOffset}`,
    );
  }
  if (itemCoverageCursor !== items.length || gapCoverageCursor !== structuralGaps.length) {
    throw new ConversationStoreError("TIMELINE_CANDIDATE_REJECTED", "timeline coverage extends beyond read evidence");
  }
}

function rangesTouch(firstA: number, lastA: number, firstB: number, lastB: number): boolean {
  if (firstA <= lastB && firstB <= lastA) return true;
  if (lastB < firstA) return firstA - lastB === 1;
  return firstB - lastA === 1;
}

function validateReadEvidence(evidence: ProviderReadEvidence): void {
  assertId(evidence.requestId, "requestId");
  assertId(evidence.providerInstanceEpoch, "providerInstanceEpoch");
  assertId(evidence.providerRevision, "providerRevision");
  if (!Number.isSafeInteger(evidence.observedAt) || evidence.observedAt <= 0) {
    throw new ConversationStoreError("TIMELINE_CANDIDATE_REJECTED", "read evidence time is invalid");
  }
  assertSignedOrdinal(evidence.firstTimelineOrdinal, "firstTimelineOrdinal");
  assertSignedOrdinal(evidence.lastTimelineOrdinal, "lastTimelineOrdinal");
  if (evidence.lastTimelineOrdinal < evidence.firstTimelineOrdinal) {
    throw new ConversationStoreError("TIMELINE_CANDIDATE_REJECTED", "read evidence endpoints are reversed");
  }
  if (evidence.lastTimelineOrdinal - evidence.firstTimelineOrdinal + 1 > MAX_TIMELINE_ITEMS) {
    throw new ConversationStoreError("PAYLOAD_TOO_LARGE", "read evidence range exceeds timeline item bound");
  }
}

function assertAuthenticatedContext(context: AuthenticatedExecutionContext, thread: ThreadRef): void {
  assertThread(thread);
  assertSource(context.sourceEpoch.source);
  assertId(context.actorId, "actorId");
  assertId(context.origin.id, "originId");
  assertGeneration(context.sourceEpoch.connectionGeneration, "connectionGeneration");
  assertGeneration(context.sourceEpoch.providerGeneration, "providerGeneration");
  if (!sameSource(context.sourceEpoch.source, thread.sourcePartition)) {
    throw new ConversationStoreError("SOURCE_FENCE_MISMATCH", "authenticated source does not match target thread");
  }
}

function assertExactEpoch(expected: SourceEpoch, actual: SourceEpoch): void {
  if (!sameSourceEpoch(expected, actual)) {
    throw new ConversationStoreError("SOURCE_FENCE_MISMATCH", "authenticated source epoch is stale or mismatched");
  }
}

function sameSourceEpoch(a: SourceEpoch, b: SourceEpoch): boolean {
  return sameSource(a.source, b.source) &&
    a.connectionGeneration === b.connectionGeneration &&
    a.providerGeneration === b.providerGeneration;
}

function sameSource(a: SourcePartition, b: SourcePartition): boolean {
  return a.bridgeIdentityId === b.bridgeIdentityId &&
    a.bridgeInstanceId === b.bridgeInstanceId &&
    a.codexSourceId === b.codexSourceId;
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

function assertResponseVariant(
  variant: InteractionRecord["variant"],
  operationCode: RespondInteractionInput["operationCode"],
): void {
  const expected = {
    APPROVAL: "OP-019",
    QUESTION: "OP-020",
    MCP_ELICITATION: "OP-021",
    EXIT_PLAN: "OP-022",
  } as const;
  if (expected[variant] !== operationCode) {
    throw new ConversationStoreError("WRONG_INTERACTION_VARIANT", "response operation code does not match variant");
  }
}

function validateVerifiedReconcileFact(input: ReconcileFactInput): void {
  const expectedEvent = {
    PROVIDER_ACCEPTED: "turn/started",
    CANONICAL_OBSERVED: "turn/completed",
    PROVIDER_REJECTED: "turn/rejected",
    PROVIDER_CANCELLED: "turn/cancelled",
  } as const;
  const evidence = input.evidence;
  assertId(evidence.providerFactId, "providerFactId");
  assertId(evidence.providerThreadId, "evidence.providerThreadId");
  if (evidence.providerTurnId) assertId(evidence.providerTurnId, "evidence.providerTurnId");
  if (
    evidence.verificationKind !== "EXACT_PROVIDER_FACT" ||
    evidence.providerEvent !== expectedEvent[input.factKind] ||
    evidence.providerThreadId !== input.thread.providerThreadId ||
    evidence.providerTurnId !== input.providerTurnId ||
    !Number.isSafeInteger(evidence.observedAt) || evidence.observedAt <= 0
  ) {
    throw new ConversationStoreError("IDENTITY_CONFLICT", "reconcile fact is not an exact provider fact");
  }
}

function validateVerifiedInteractionFact(input: ResolveInteractionInput): void {
  const evidence = input.evidence;
  assertId(evidence.providerFactId, "providerFactId");
  if (
    evidence.verificationKind !== "EXACT_PROVIDER_FACT" ||
    evidence.providerEvent !== "serverRequest/resolved" ||
    evidence.providerThreadId !== input.ref.thread.providerThreadId ||
    evidence.providerTurnId !== input.ref.providerTurnId ||
    evidence.providerRequestId !== input.providerRequestId ||
    !Number.isSafeInteger(evidence.observedAt) || evidence.observedAt <= 0
  ) {
    throw new ConversationStoreError("IDENTITY_CONFLICT", "interaction resolution is not an exact provider fact");
  }
}

function reconcileProjectedOutcome(
  kind: ReconcileFactInput["factKind"],
): ReconcileResolutionRecord["projectedOutcome"] {
  switch (kind) {
    case "PROVIDER_ACCEPTED":
      return "PROVIDER_ACCEPTED";
    case "CANONICAL_OBSERVED":
      return "SUCCEEDED";
    case "PROVIDER_REJECTED":
      return "REJECTED";
    case "PROVIDER_CANCELLED":
      return "CANCELLED";
  }
}

function assertQueueCapacity(capacity: number): void {
  if (!Number.isSafeInteger(capacity) || capacity < 1 || capacity > 16) {
    throw new RangeError("queue capacity must be between 1 and 16");
  }
}

function assertExpectedRevision(value: number): void {
  if (!Number.isSafeInteger(value) || value < 0) throw new RangeError("expected revision is invalid");
}

function assertOrdinal(value: number, label: string): void {
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new ConversationStoreError("TIMELINE_CANDIDATE_REJECTED", `${label} is invalid`);
  }
}

function assertSignedOrdinal(value: number, label: string): void {
  if (!Number.isSafeInteger(value)) {
    throw new ConversationStoreError("TIMELINE_CANDIDATE_REJECTED", `${label} is invalid`);
  }
}

function assertGeneration(value: number, label: string): void {
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new ConversationStoreError("SOURCE_FENCE_MISMATCH", `${label} is invalid`);
  }
}

function assertId(value: string, label: string): void {
  if (typeof value !== "string" || !ID_PATTERN.test(value)) {
    throw new ConversationStoreError("IDENTITY_CONFLICT", `${label} is not a canonical id`);
  }
}

function assertDigest(value: string, label: string): void {
  if (!SHA256_PATTERN.test(value)) {
    throw new ConversationStoreError("IDENTITY_CONFLICT", `${label} must be lowercase sha256`);
  }
}

function assertClaimToken(value: string): void {
  if (typeof value !== "string" || value.length < 16 || Buffer.byteLength(value, "utf8") > 4096) {
    throw new ConversationStoreError("CLAIM_NOT_OWNED", "claim token has invalid bounds");
  }
}

function hashClaimToken(value: string): string {
  return createHash("sha256").update(value, "utf8").digest("hex");
}
