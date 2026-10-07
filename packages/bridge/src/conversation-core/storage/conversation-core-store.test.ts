import { mkdirSync, symlinkSync, writeFileSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import Database from "better-sqlite3";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

import { canonicalizeJsonObject } from "./canonical-json.js";
import { ConversationCoreStoreClient } from "./conversation-core-store-client.js";
import { ConversationCoreStore, verifyTimelineCoverage } from "./conversation-core-store.js";
import {
  ConversationStoreError,
  type AuthenticatedExecutionContext,
  type InteractionRef,
  type OperationAdmission,
  type StoreFaultStage,
  type ThreadRef,
  type TimelineMaterializationRecord,
  type TimelinePageInput,
} from "./types.js";

const source = {
  bridgeIdentityId: "bridge-identity-a",
  bridgeInstanceId: "bridge-instance-a",
  codexSourceId: "codex-source-a",
} as const;

const thread: ThreadRef = { sourcePartition: source, providerThreadId: "thread-a" };
const context: AuthenticatedExecutionContext = {
  actorId: "actor-a",
  sourceEpoch: { source, connectionGeneration: 7, providerGeneration: 11 },
  origin: { kind: "MOBILE_CLIENT", id: "client-instance-a" },
};
const bridgeContext: AuthenticatedExecutionContext = {
  ...context,
  actorId: "bridge-worker",
  origin: { kind: "BRIDGE_INTERNAL", id: "store-dispatcher" },
};
const wrongActorContext: AuthenticatedExecutionContext = { ...context, actorId: "actor-b" };
const wrongSourceContext: AuthenticatedExecutionContext = {
  ...context,
  sourceEpoch: {
    ...context.sourceEpoch,
    source: { ...source, codexSourceId: "codex-source-b" },
  },
};

const claimToken = "fixture:claim:token:aaaaaaaa";

function turnInput(text: string) {
  return { text, imageRefs: [], structuredRefs: [] };
}

function admission(suffix: string, overrides: Partial<OperationAdmission> = {}): OperationAdmission {
  return {
    context,
    thread,
    operationId: `operation-${suffix}`,
    clientInstanceId: "client-instance-a",
    clientMessageId: `client-message-${suffix}`,
    operationCode: "OP-001",
    conflictFamily: "THREAD_MUTATION",
    target: { targetKind: "THREAD", providerThreadId: thread.providerThreadId },
    payload: { payloadKind: "START_TURN", body: turnInput(suffix) },
    preconditions: { expectedHeadVersion: 1 },
    ...overrides,
  };
}

function evidence(lastTimelineOrdinal = 1) {
  return {
    requestId: `read-${lastTimelineOrdinal}`,
    readKind: "FIRST_READ" as const,
    readScope: "WHOLE_SCOPE" as const,
    providerInstanceEpoch: "provider-instance-1",
    providerRevision: `provider-revision-${lastTimelineOrdinal}`,
    observedAt: 1_000,
    firstTimelineOrdinal: 0,
    lastTimelineOrdinal,
  };
}

function page(
  materializationId: string,
  pageIndex = 0,
  previousPageDigest?: string,
): TimelinePageInput {
  return {
    context,
    thread,
    materializationId,
    pageIndex,
    ...(previousPageDigest ? { previousPageDigest } : {}),
    items: [
      {
        itemId: "item-0",
        providerTurnId: "turn-0",
        turnOrdinal: 0,
        itemOrdinal: 0,
        timelineOrdinal: 0,
        kind: "USER_MESSAGE",
        payload: { text: "hello" },
      },
      {
        itemId: "item-1",
        providerTurnId: "turn-0",
        turnOrdinal: 0,
        itemOrdinal: 1,
        timelineOrdinal: 1,
        kind: "ASSISTANT_MESSAGE",
        payload: { text: "answer" },
      },
    ],
    gaps: [],
    coverageIslands: [
      {
        islandId: "island-0",
        islandOrdinal: 0,
        firstTimelineOrdinal: 0,
        lastTimelineOrdinal: 1,
        structuralCoverage: "COMPLETE",
        payloadCoverage: "COMPLETE",
      },
    ],
  };
}

describe("ConversationCoreStore", () => {
  let root: string;
  let filePath: string;
  let stores: ConversationCoreStore[];

  beforeEach(async () => {
    root = await mkdtemp(join(tmpdir(), "ccpocket-store-v2-"));
    filePath = join(root, "conversation-core-v3.db");
    stores = [];
  });

  afterEach(async () => {
    for (const store of stores) store.close();
    await rm(root, { recursive: true, force: true });
  });

  function open(options: { now?: () => number; faultHook?: (stage: StoreFaultStage) => void; writerLeaseTtlMs?: number } = {}) {
    const store = ConversationCoreStore.openForTesting({ filePath, ...options });
    stores.push(store);
    return store;
  }

  function close(store: ConversationCoreStore) {
    store.close();
    stores = stores.filter((candidate) => candidate !== store);
  }

  it("refuses direct production opens on the main thread", () => {
    expectStoreError(() => ConversationCoreStore.open({ filePath }), "WORKER_REQUIRED");
    expect(() => new Database(filePath, { fileMustExist: true })).toThrow();
  });

  it("uses strict constrained DDL and a persistent writer lease", () => {
    let now = 100;
    const first = open({ now: () => now, writerLeaseTtlMs: 250 });
    expect(first.diagnostics()).toMatchObject({
      schemaVersion: 3,
      journalMode: "wal",
      foreignKeys: true,
      quickCheck: "ok",
      foreignKeyViolations: 0,
      writerOwnerEpoch: 1,
    });
    expectStoreError(
      () => ConversationCoreStore.openForTesting({ filePath, now: () => now, writerLeaseTtlMs: 250 }),
      "WRITER_ALREADY_OPEN",
    );
    now = 351;
    const recovered = ConversationCoreStore.openForTesting({ filePath, now: () => now, writerLeaseTtlMs: 250 });
    stores.push(recovered);
    expect(recovered.diagnostics().writerOwnerEpoch).toBe(2);
    expectStoreError(() => first.diagnostics(), "WRITER_LEASE_LOST");
  });

  it("rechecks the writer epoch after BEGIN IMMEDIATE before any domain write", () => {
    let now = 100;
    let armed = false;
    const store = open({
      now: () => now,
      writerLeaseTtlMs: 250,
      faultHook: (stage) => {
        if (!armed || stage !== "operation.before-transaction") return;
        now = 351;
        const takeover = new Database(filePath);
        takeover.prepare(
          `UPDATE writer_owner SET owner_id='replacement-writer',owner_epoch=owner_epoch+1,
             lease_expires_at=601,updated_at=351 WHERE singleton=1`,
        ).run();
        takeover.close();
      },
    });
    armed = true;
    expectStoreError(() => store.admitOperation(admission("lost-before-begin")), "WRITER_LEASE_LOST");
    const readback = new Database(filePath, { readonly: true });
    expect((readback.prepare("SELECT COUNT(*) AS count FROM operation").get() as { count: number }).count).toBe(0);
    expect(readback.prepare("SELECT owner_id,owner_epoch FROM writer_owner").get()).toEqual({
      owner_id: "replacement-writer",
      owner_epoch: 2,
    });
    readback.close();
  });

  it("canonicalizes the real parent and rejects symlink files and non-regular database paths", () => {
    const realParent = join(root, "real");
    mkdirSync(realParent);
    const linkedParent = join(root, "linked");
    symlinkSync(realParent, linkedParent);
    const canonicalized = ConversationCoreStore.openForTesting({ filePath: join(linkedParent, "db.sqlite") });
    canonicalized.close();
    const target = join(realParent, "target.sqlite");
    writeFileSync(target, "");
    const fileLink = join(root, "file-link.sqlite");
    symlinkSync(target, fileLink);
    expectStoreError(() => ConversationCoreStore.openForTesting({ filePath: fileLink }), "INVALID_DATABASE_PATH");
    expectStoreError(() => ConversationCoreStore.openForTesting({ filePath: realParent }), "INVALID_DATABASE_PATH");
  });

  it("fails before migration when an existing database has another schema version", () => {
    const legacyPath = join(root, "legacy.db");
    const legacy = new Database(legacyPath);
    legacy.exec("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL) STRICT");
    legacy.prepare("INSERT INTO meta (key,value) VALUES ('schema_version','1')").run();
    const before = (legacy.prepare("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name").all() as Array<{ name: string }>).map((row) => row.name);
    legacy.close();
    expect(() => ConversationCoreStore.openForTesting({ filePath: legacyPath })).toThrow(
      "Unsupported conversation core schema version 1",
    );
    const readback = new Database(legacyPath, { readonly: true });
    const after = (readback.prepare("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name").all() as Array<{ name: string }>).map((row) => row.name);
    readback.close();
    expect(after).toEqual(before);
  });

  it("fails closed on missing, noncanonical, or shape-drifted current schema metadata", () => {
    for (const [suffix, value] of [["missing", undefined], ["noncanonical", "3 "]] as const) {
      const malformedPath = join(root, `${suffix}.db`);
      const malformed = new Database(malformedPath);
      malformed.exec("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL) STRICT");
      if (value !== undefined) {
        malformed.prepare("INSERT INTO meta (key,value) VALUES ('schema_version',?)").run(value);
      }
      malformed.close();
      expect(() => ConversationCoreStore.openForTesting({ filePath: malformedPath })).toThrow(
        `Unsupported conversation core schema version ${value ?? "missing"}`,
      );
      const readback = new Database(malformedPath, { readonly: true });
      expect(readback.prepare("SELECT COUNT(*) AS count FROM meta").get()).toEqual({
        count: value === undefined ? 0 : 1,
      });
      readback.close();
    }

    const driftedPath = join(root, "shape-drifted.db");
    const seeded = ConversationCoreStore.openForTesting({ filePath: driftedPath });
    seeded.close();
    const drifted = new Database(driftedPath);
    drifted.exec("DROP TRIGGER interaction_claim_expiry_within_interaction_insert");
    drifted.close();
    expect(() => ConversationCoreStore.openForTesting({ filePath: driftedPath })).toThrow(
      "Unsupported conversation core schema shape",
    );
    const driftedReadback = new Database(driftedPath, { readonly: true });
    expect(driftedReadback.prepare(
      "SELECT COUNT(*) AS count FROM sqlite_master WHERE type='trigger' AND name=?",
    ).get("interaction_claim_expiry_within_interaction_insert")).toEqual({ count: 0 });
    driftedReadback.close();
  });

  it("computes the authoritative RFC8785 fingerprint and checks source before claimed fingerprint", () => {
    const store = open();
    const first = store.admitOperation(admission("jcs", {
      payload: {
        payloadKind: "START_TURN",
        body: { structuredRefs: [], text: "jcs", imageRefs: [] },
      },
    }));
    const replay = store.admitOperation(admission("jcs", {
      payload: {
        payloadKind: "START_TURN",
        body: { imageRefs: [], text: "jcs", structuredRefs: [] },
      },
    }));
    expect(first.kind).toBe("ADMITTED");
    expect(replay.kind).toBe("IDEMPOTENT");
    expect(replay.operation.fingerprint).toBe(first.operation.fingerprint);
    const before = store.diagnostics().tableCounts;
    expectStoreError(
      () => store.admitOperation(admission("bad-claim", { claimedFingerprint: "f".repeat(64) })),
      "OPERATION_FINGERPRINT_CONFLICT",
    );
    expectStoreError(
      () => store.admitOperation(admission("wrong-source", {
        context: wrongSourceContext,
        claimedFingerprint: "f".repeat(64),
      })),
      "SOURCE_FENCE_MISMATCH",
    );
    expectStoreError(
      () => store.admitOperation(admission("wrong-variant", {
        payload: { payloadKind: "CANCEL_QUEUED_INPUT", body: {} },
      })),
      "INVALID_STATE_TRANSITION",
    );
    expect(store.diagnostics().tableCounts).toEqual(before);
    expect(first.operation).toMatchObject({
      actorId: "actor-a",
      operationCode: "OP-001",
      target: { targetKind: "THREAD", providerThreadId: "thread-a" },
      preconditions: { expectedHeadVersion: 1 },
      sourceEpoch: context.sourceEpoch,
    });
  });

  it("rejects cycles, depth, BigInt, hostile keys, accessors, and class instances", () => {
    const store = open();
    const cyclic: Record<string, unknown> = {};
    cyclic.self = cyclic;
    expectStoreError(() => store.admitOperation(admission("cycle", {
      payload: { payloadKind: "START_TURN", body: cyclic },
    })), "INVALID_JSON");
    let deep: Record<string, unknown> = {};
    const rootObject = deep;
    for (let index = 0; index < 40; index += 1) {
      const next: Record<string, unknown> = {};
      deep.next = next;
      deep = next;
    }
    expectStoreError(() => store.admitOperation(admission("deep", {
      payload: { payloadKind: "START_TURN", body: rootObject },
    })), "INVALID_JSON");
    expectStoreError(() => store.admitOperation(admission("bigint", {
      payload: { payloadKind: "START_TURN", body: { value: 1n } },
    })), "INVALID_JSON");
    const hostile = JSON.parse('{"__proto__":{"polluted":true}}') as Record<string, unknown>;
    expectStoreError(() => store.admitOperation(admission("hostile", {
      payload: { payloadKind: "START_TURN", body: hostile },
    })), "INVALID_JSON");
    const accessor: Record<string, unknown> = {};
    Object.defineProperty(accessor, "value", { enumerable: true, get: () => "bad" });
    expectStoreError(() => canonicalizeJsonObject(accessor, 1024), "INVALID_JSON");
    class Payload { value = 1; }
    expectStoreError(
      () => store.admitOperation(admission("class", {
        payload: {
          payloadKind: "START_TURN",
          body: new Payload() as unknown as Record<string, unknown>,
        },
      })),
      "INVALID_JSON",
    );
  });

  it("refuses generic admission around queue and interaction barriers and rejects open payload schemas", () => {
    const store = open();
    const before = store.diagnostics().tableCounts;
    expectStoreError(
      () => store.admitOperation(admission("missing-queue-control", {
        operationCode: "OP-002",
        conflictFamily: "QUEUE_CONTROL",
        target: {
          targetKind: "QUEUE_ENTRY",
          providerThreadId: thread.providerThreadId,
          queueEntryId: "missing-entry",
          rootOperationId: "missing-root",
        },
        payload: { payloadKind: "EDIT_QUEUED_INPUT", body: turnInput("forged") },
        preconditions: { expectedLaneRevision: 0, expectedEntryRevision: 1 },
      })),
      "INVALID_STATE_TRANSITION",
    );
    expectStoreError(
      () => store.admitOperation(admission("missing-interaction", {
        operationCode: "OP-020",
        conflictFamily: "INTERACTION_RESPONSE",
        target: {
          targetKind: "INTERACTION",
          providerThreadId: thread.providerThreadId,
          providerTurnId: "missing-turn",
          interactionId: "missing-interaction",
          variant: "QUESTION",
        },
        payload: {
          payloadKind: "RESPOND_QUESTION",
          body: { answers: [{ kind: "free_text", questionId: "q", text: "forged" }] },
        },
        preconditions: { expectedInteractionRevision: 1, expectedClaimRevision: 1 },
      })),
      "INVALID_STATE_TRANSITION",
    );
    expectStoreError(
      () => store.admitOperation(admission("open-body", {
        payload: { payloadKind: "START_TURN", body: {} },
      })),
      "INVALID_STATE_TRANSITION",
    );
    expectStoreError(
      () => store.admitOperation(admission("extra-field", {
        payload: {
          payloadKind: "START_TURN",
          body: { ...turnInput("hello"), untrusted: true },
        },
      })),
      "INVALID_STATE_TRANSITION",
    );
    expect(store.diagnostics().tableCounts).toEqual(before);
  });

  it("keeps OUTCOME_UNKNOWN immutable while append-only reconcile facts project an effective outcome", () => {
    let store = open();
    const admitted = store.admitOperation(admission("unknown")).operation;
    store.beginIdleDispatch({
      context,
      thread,
      operationId: admitted.operationId,
      expectedOperationRevision: admitted.revision,
      dispatchAttemptId: "attempt-unknown",
    });
    close(store);

    store = open();
    const unknown = store.getOperation(thread, admitted.operationId)!;
    expect(unknown).toMatchObject({ state: "OUTCOME_UNKNOWN", reconcileRequired: true });
    expectStoreError(
      () => store.transitionOperation({
        context,
        thread,
        operationId: unknown.operationId,
        expectedRevision: unknown.revision,
        toState: "CANONICAL_OBSERVED",
        eventKind: "ILLEGAL_UNKNOWN_EDGE",
        dispatchAttemptId: "attempt-unknown",
        providerTurnId: "turn-exact",
        providerEvidence: "VERIFIED_CANONICAL_FACT",
      }),
      "INVALID_STATE_TRANSITION",
    );
    expectStoreError(
      () => store.recordReconcileFact({
        context,
        thread,
        operationId: unknown.operationId,
        reconcileRoundId: "round-missing-turn",
        factId: "fact-missing-turn",
        factKind: "CANONICAL_OBSERVED",
        evidence: {
          verificationKind: "EXACT_PROVIDER_FACT",
          providerEvent: "turn/completed",
          providerFactId: "fact-missing-turn",
          providerThreadId: thread.providerThreadId,
          observedAt: 1_000,
        },
      }),
      "IDENTITY_CONFLICT",
    );
    const resolution = store.recordReconcileFact({
      context,
      thread,
      operationId: unknown.operationId,
      reconcileRoundId: "round-exact",
      factId: "fact-exact",
      factKind: "CANONICAL_OBSERVED",
      providerTurnId: "turn-exact",
      evidence: {
        verificationKind: "EXACT_PROVIDER_FACT",
        providerEvent: "turn/completed",
        providerFactId: "provider-fact-exact",
        providerThreadId: thread.providerThreadId,
        providerTurnId: "turn-exact",
        observedAt: 1_000,
      },
    });
    expect(resolution.projectedOutcome).toBe("SUCCEEDED");
    expect(store.getOperation(thread, unknown.operationId)).toMatchObject({
      state: "OUTCOME_UNKNOWN",
      reconcileRequired: true,
    });
    expectStoreError(
      () => store.admitOperation(admission("blocked-after-unknown")),
      "BLOCKED_BY_UNKNOWN_OUTCOME",
    );
    expect(store.listOperationEvents(thread, unknown.operationId)).toHaveLength(3);
  });

  it("blocks an already-admitted idle operation behind an unknown conflict-family outcome", () => {
    let store = open();
    const first = store.admitOperation(admission("idle-unknown-first")).operation;
    const alreadyAdmitted = store.admitOperation(admission("idle-unknown-second")).operation;
    store.beginIdleDispatch({
      context,
      thread,
      operationId: first.operationId,
      expectedOperationRevision: first.revision,
      dispatchAttemptId: "attempt-idle-unknown-first",
    });
    close(store);

    store = open();
    expect(store.getOperation(thread, first.operationId)?.state).toBe("OUTCOME_UNKNOWN");
    const before = store.listOperationEvents(thread, alreadyAdmitted.operationId);
    expectStoreError(
      () => store.beginIdleDispatch({
        context,
        thread,
        operationId: alreadyAdmitted.operationId,
        expectedOperationRevision: alreadyAdmitted.revision,
        dispatchAttemptId: "attempt-idle-unknown-second",
      }),
      "BLOCKED_BY_UNKNOWN_OUTCOME",
    );
    expect(store.getOperation(thread, alreadyAdmitted.operationId)).toMatchObject({
      state: "DURABLY_ADMITTED",
      revision: alreadyAdmitted.revision,
    });
    expect(store.listOperationEvents(thread, alreadyAdmitted.operationId)).toEqual(before);
  });

  it("atomically admits one queued root and prevents a root from owning multiple active entries", () => {
    const store = open();
    const queued = store.admitAndQueue({
      admission: admission("queue-root"),
      laneFamily: "NEXT_TURN",
      expectedLaneRevision: 0,
      queueEntryId: "queue-entry-1",
      capacity: 2,
    });
    expect(queued).toMatchObject({
      kind: "ADMITTED",
      operation: { state: "QUEUED" },
      entry: { state: "QUEUED", fifoOrdinal: 0 },
      lane: { activeCount: 1, revision: 2 },
    });
    const replay = store.admitAndQueue({
      admission: admission("queue-root"),
      laneFamily: "NEXT_TURN",
      expectedLaneRevision: 2,
      queueEntryId: "queue-entry-1",
      capacity: 2,
    });
    expect(replay.kind).toBe("IDEMPOTENT");
    expectStoreError(
      () => store.admitAndQueue({
        admission: admission("queue-root"),
        laneFamily: "NEXT_TURN",
        expectedLaneRevision: 2,
        queueEntryId: "queue-entry-other",
        capacity: 2,
      }),
      "OPERATION_ID_CONFLICT",
    );
    const second = store.admitAndQueue({
      admission: admission("queue-root-2"),
      laneFamily: "NEXT_TURN",
      expectedLaneRevision: 2,
      queueEntryId: "queue-entry-2",
      capacity: 2,
    });
    expect(second.entry.fifoOrdinal).toBe(1);
    expectStoreError(
      () => store.admitAndQueue({
        admission: admission("queue-root-3"),
        laneFamily: "NEXT_TURN",
        expectedLaneRevision: 3,
        queueEntryId: "queue-entry-3",
        capacity: 2,
      }),
      "QUEUE_FULL",
    );

    const database = (store as unknown as { database: Database.Database }).database;
    expect(database.prepare(
      "SELECT sql FROM sqlite_master WHERE type='table' AND name='queue_lane'",
    ).get()).toMatchObject({ sql: expect.stringContaining("next_fifo_ordinal BETWEEN 0 AND 9007199254740991") });
    expect(database.prepare(
      "SELECT sql FROM sqlite_master WHERE type='table' AND name='queue_entry'",
    ).get()).toMatchObject({ sql: expect.stringContaining("fifo_ordinal BETWEEN 0 AND 9007199254740991") });
    expect(() => database.prepare(
      `INSERT INTO queue_lane (
         bridge_identity_id,bridge_instance_id,codex_source_id,provider_thread_id,lane_family,
         revision,next_fifo_ordinal,active_count,capacity,updated_at
       ) SELECT bridge_identity_id,bridge_instance_id,codex_source_id,provider_thread_id,'UNSAFE',
         1,9007199254740992,0,capacity,updated_at FROM queue_lane WHERE lane_family='NEXT_TURN'`,
    ).run()).toThrow();
    expect(() => database.prepare(
      `INSERT INTO queue_entry (
         bridge_identity_id,bridge_instance_id,codex_source_id,provider_thread_id,lane_family,
         queue_entry_id,root_operation_id,fifo_ordinal,entry_revision,state,payload_digest,payload_json,updated_at
       ) SELECT bridge_identity_id,bridge_instance_id,codex_source_id,provider_thread_id,lane_family,
         'queue-entry-unsafe',root_operation_id,9007199254740992,1,'CANCELLED',payload_digest,payload_json,updated_at
       FROM queue_entry WHERE queue_entry_id='queue-entry-1'`,
    ).run()).toThrow();
  });

  it("records edit and cancel as independent successful control operations without EDITED state", () => {
    const store = open();
    const queued = store.admitAndQueue({
      admission: admission("control-root"),
      laneFamily: "NEXT_TURN",
      expectedLaneRevision: 0,
      queueEntryId: "control-entry",
    });
    const edited = store.controlQueueEntry({
      admission: admission("control-edit", {
        operationCode: "OP-002",
        conflictFamily: "QUEUE_CONTROL",
        target: {
          targetKind: "QUEUE_ENTRY",
          providerThreadId: thread.providerThreadId,
          queueEntryId: "control-entry",
          rootOperationId: "operation-control-root",
        },
        payload: { payloadKind: "EDIT_QUEUED_INPUT", body: turnInput("edited") },
        preconditions: { expectedLaneRevision: 2, expectedEntryRevision: 1 },
      }),
      laneFamily: "NEXT_TURN",
      queueEntryId: "control-entry",
      expectedLaneRevision: queued.lane.revision,
      expectedEntryRevision: queued.entry.revision,
      replacementPayload: turnInput("edited"),
    });
    expect(edited.controlOperation.state).toBe("SUCCEEDED");
    expect(edited.rootOperation.state).toBe("QUEUED");
    expect(edited.entry).toMatchObject({ state: "QUEUED", revision: 2, payload: turnInput("edited") });
    const cancelled = store.controlQueueEntry({
      admission: admission("control-cancel", {
        operationCode: "OP-003",
        conflictFamily: "QUEUE_CONTROL",
        target: {
          targetKind: "QUEUE_ENTRY",
          providerThreadId: thread.providerThreadId,
          queueEntryId: "control-entry",
          rootOperationId: "operation-control-root",
        },
        payload: { payloadKind: "CANCEL_QUEUED_INPUT", body: { reason: "USER_REQUESTED" } },
        preconditions: {
          expectedLaneRevision: edited.lane.revision,
          expectedEntryRevision: edited.entry.revision,
        },
      }),
      laneFamily: "NEXT_TURN",
      queueEntryId: "control-entry",
      expectedLaneRevision: edited.lane.revision,
      expectedEntryRevision: edited.entry.revision,
    });
    expect(cancelled).toMatchObject({
      controlOperation: { state: "SUCCEEDED" },
      rootOperation: { state: "CANCELLED" },
      entry: { state: "CANCELLED" },
      lane: { activeCount: 0 },
    });
    expect(store.listQueueEntries(thread, "NEXT_TURN").some((entry) => (entry.state as string) === "EDITED")).toBe(false);
  });

  it("crosses FIFO queue ownership and CALL_STARTED in one durable dispatch barrier", () => {
    let store = open();
    const first = store.admitAndQueue({
      admission: admission("fifo-1"),
      laneFamily: "NEXT_TURN",
      expectedLaneRevision: 0,
      queueEntryId: "fifo-entry-1",
    });
    store.admitAndQueue({
      admission: admission("fifo-2"),
      laneFamily: "NEXT_TURN",
      expectedLaneRevision: first.lane.revision,
      queueEntryId: "fifo-entry-2",
    });
    const barrier = store.beginQueuedDispatch({
      context,
      thread,
      laneFamily: "NEXT_TURN",
      expectedLaneRevision: 3,
      dispatchAttemptId: "attempt-fifo-1",
    });
    expect(barrier).toMatchObject({
      entry: { queueEntryId: "fifo-entry-1", state: "DISPATCH_RESERVED" },
      operation: { operationId: "operation-fifo-1", state: "CALL_STARTED" },
      lane: { activeCount: 1, revision: 4 },
    });
    close(store);
    store = open();
    expect(store.getOperation(thread, "operation-fifo-1")).toMatchObject({
      state: "OUTCOME_UNKNOWN",
      dispatchAttemptId: "attempt-fifo-1",
    });
    expect(store.listQueueEntries(thread, "NEXT_TURN")[0]).toMatchObject({ state: "CONSUMED" });
    expectStoreError(
      () => store.beginQueuedDispatch({
        context,
        thread,
        laneFamily: "NEXT_TURN",
        expectedLaneRevision: 4,
        dispatchAttemptId: "attempt-fifo-2",
      }),
      "BLOCKED_BY_UNKNOWN_OUTCOME",
    );
  });

  it("rolls back root admission, lane reservation, entry, and operation event at a queue fault seam", () => {
    let armed = false;
    const store = open({
      faultHook: (stage) => {
        if (armed && stage === "queue.after-operation") throw new Error("queue barrier crash");
      },
    });
    armed = true;
    expect(() => store.admitAndQueue({
      admission: admission("queue-fault"),
      laneFamily: "NEXT_TURN",
      expectedLaneRevision: 0,
      queueEntryId: "queue-fault-entry",
    })).toThrow("queue barrier crash");
    armed = false;
    expect(store.diagnostics().tableCounts).toMatchObject({
      source_partition: 0,
      operation: 0,
      operation_event: 0,
      queue_lane: 0,
      queue_entry: 0,
    });
  });

  it("publishes only a verifier-sealed page chain and preserves old materializations", () => {
    const store = open();
    const materialization = store.beginTimelineMaterialization({
      context,
      thread,
      materializationId: "materialization-1",
      evidence: evidence(),
    });
    const committedPage = store.appendTimelinePage(page(materialization.materializationId));
    const head = store.sealTimelineMaterialization({
      context,
      thread,
      materializationId: materialization.materializationId,
      expectedHeadRevision: 0,
      expectedPageCount: 1,
      expectedItemCount: 2,
      expectedGapCount: 0,
      expectedLastPageDigest: committedPage.pageDigest,
    });
    expect(head).toMatchObject({
      headRevision: 1,
      materializationId: "materialization-1",
      totalItemCount: 2,
      receipt: { readEvidenceDigest: materialization.readEvidenceDigest },
    });
    expect(head.items.map((item) => [item.turnOrdinal, item.itemOrdinal, item.timelineOrdinal])).toEqual([
      [0, 0, 0],
      [0, 1, 1],
    ]);

    const replacement = store.beginTimelineMaterialization({
      context,
      thread,
      materializationId: "materialization-2",
      evidence: evidence(),
    });
    const replacementPage = store.appendTimelinePage(page(replacement.materializationId));
    store.sealTimelineMaterialization({
      context,
      thread,
      materializationId: replacement.materializationId,
      expectedHeadRevision: 1,
      expectedPageCount: 1,
      expectedItemCount: 2,
      expectedGapCount: 0,
      expectedLastPageDigest: replacementPage.pageDigest,
    });
    expect(store.diagnostics().tableCounts.timeline_materialization).toBe(2);
    expect(store.readTimeline(thread)?.materializationId).toBe("materialization-2");
  });

  it("stores the complete verified timeline while bounding readback to two hundred entries", () => {
    const store = open();
    const materialization = store.beginTimelineMaterialization({
      context,
      thread,
      materializationId: "materialization-readback-bound",
      evidence: evidence(204),
    });
    const boundedPage = page(materialization.materializationId);
    boundedPage.items = Array.from({ length: 205 }, (_, timelineOrdinal) => ({
      itemId: `item-${timelineOrdinal}`,
      providerTurnId: `turn-${timelineOrdinal}`,
      turnOrdinal: timelineOrdinal,
      itemOrdinal: 0,
      timelineOrdinal,
      kind: "USER_MESSAGE",
      payload: { timelineOrdinal },
    }));
    boundedPage.coverageIslands = [{
      islandId: "island-all",
      islandOrdinal: 0,
      firstTimelineOrdinal: 0,
      lastTimelineOrdinal: 204,
      structuralCoverage: "COMPLETE",
      payloadCoverage: "COMPLETE",
    }];
    const appended = store.appendTimelinePage(boundedPage);
    const readback = store.sealTimelineMaterialization({
      context,
      thread,
      materializationId: materialization.materializationId,
      expectedHeadRevision: 0,
      expectedPageCount: 1,
      expectedItemCount: 205,
      expectedGapCount: 0,
      expectedLastPageDigest: appended.pageDigest,
    });
    expect(readback.totalItemCount).toBe(205);
    expect(readback.items).toHaveLength(200);
    expect(readback.items[0]?.timelineOrdinal).toBe(5);
    expect(store.readTimeline(thread, { startTimelineOrdinal: 2, limit: 3 })?.items.map((item) => item.timelineOrdinal)).toEqual([2, 3, 4]);
  });

  it("makes sealed timeline children immutable and re-verifies the receipt on every read", () => {
    const store = open();
    commitGoodTimeline(store, "tamper-proof", 0);
    const direct = new Database(filePath);
    expect(() => direct.prepare(
      "UPDATE timeline_item SET payload_json='{}' WHERE materialization_id='tamper-proof' AND item_id='item-0'",
    ).run()).toThrow(/sealed timeline item is immutable/);
    expect(() => direct.prepare(
      "DELETE FROM timeline_item WHERE materialization_id='tamper-proof' AND item_id='item-0'",
    ).run()).toThrow(/sealed timeline item is immutable/);
    expect(() => direct.prepare(
      "UPDATE timeline_page SET body_json='{}' WHERE materialization_id='tamper-proof' AND page_index=0",
    ).run()).toThrow(/sealed timeline page is immutable/);
    expect(() => direct.prepare(
      "UPDATE timeline_coverage_island SET last_timeline_ordinal=0 WHERE materialization_id='tamper-proof'",
    ).run()).toThrow(/sealed timeline island is immutable/);
    expect(() => direct.prepare("UPDATE timeline_head SET revision=revision+100").run())
      .toThrow(/timeline head requires sealed materialization/);
    expect(() => direct.prepare("DELETE FROM timeline_head").run())
      .toThrow(/timeline head is canonical and cannot be deleted/);

    // Receipt verification remains fail-closed even if a privileged actor removes a DDL guard.
    direct.exec("DROP TRIGGER timeline_item_sealed_immutable_update");
    direct.prepare(
      "UPDATE timeline_item SET payload_json='{}' WHERE materialization_id='tamper-proof' AND item_id='item-0'",
    ).run();
    direct.close();
    expectStoreError(() => store.readTimeline(thread), "TIMELINE_PAGE_CHAIN_INVALID");
  });

  it("rejects [0,100] without a typed gap and leaves the last-good head unchanged", () => {
    const store = open();
    commitGoodTimeline(store, "last-good", 0);
    const candidate = store.beginTimelineMaterialization({
      context,
      thread,
      materializationId: "materialization-hole",
      evidence: evidence(100),
    });
    const badPage = page(candidate.materializationId);
    badPage.items = [
      { ...badPage.items[0]!, timelineOrdinal: 0 },
      { ...badPage.items[1]!, timelineOrdinal: 100 },
    ];
    badPage.coverageIslands = [
      { ...badPage.coverageIslands[0]!, firstTimelineOrdinal: 0, lastTimelineOrdinal: 100 },
    ];
    const appended = store.appendTimelinePage(badPage);
    expectStoreError(
      () => store.sealTimelineMaterialization({
        context,
        thread,
        materializationId: candidate.materializationId,
        expectedHeadRevision: 1,
        expectedPageCount: 1,
        expectedItemCount: 2,
        expectedGapCount: 0,
        expectedLastPageDigest: appended.pageDigest,
      }),
      "TIMELINE_CANDIDATE_REJECTED",
    );
    expect(store.readTimeline(thread)).toMatchObject({ headRevision: 1, materializationId: "last-good" });
  });

  it("requires coverage island COMPLETE and PARTIAL flags to agree with typed gaps", () => {
    const store = open();
    const completeWithGap = store.beginTimelineMaterialization({
      context,
      thread,
      materializationId: "coverage-complete-with-gap",
      evidence: evidence(2),
    });
    const invalidPage = page(completeWithGap.materializationId);
    invalidPage.items = [
      invalidPage.items[0]!,
      { ...invalidPage.items[1]!, timelineOrdinal: 2 },
    ];
    invalidPage.gaps = [{
      gapId: "gap-1",
      gapOrdinal: 0,
      gapKind: "STRUCTURAL",
      firstMissingTimelineOrdinal: 1,
      lastMissingTimelineOrdinal: 1,
      reason: "PROVIDER_PAGE_MISSING",
      descriptor: { repair: "OLDER_PAGE" },
    }];
    invalidPage.coverageIslands = [{
      ...invalidPage.coverageIslands[0]!,
      lastTimelineOrdinal: 2,
      structuralCoverage: "COMPLETE",
    }];
    const invalidAppended = store.appendTimelinePage(invalidPage);
    expectStoreError(
      () => store.sealTimelineMaterialization({
        context,
        thread,
        materializationId: completeWithGap.materializationId,
        expectedHeadRevision: 0,
        expectedPageCount: 1,
        expectedItemCount: 2,
        expectedGapCount: 1,
        expectedLastPageDigest: invalidAppended.pageDigest,
      }),
      "TIMELINE_CANDIDATE_REJECTED",
    );

    const partialWithoutGap = store.beginTimelineMaterialization({
      context,
      thread,
      materializationId: "coverage-partial-without-gap",
      evidence: evidence(),
    });
    const missingGapPage = page(partialWithoutGap.materializationId);
    missingGapPage.coverageIslands = [{
      ...missingGapPage.coverageIslands[0]!,
      payloadCoverage: "PARTIAL",
    }];
    const missingGapAppended = store.appendTimelinePage(missingGapPage);
    expectStoreError(
      () => store.sealTimelineMaterialization({
        context,
        thread,
        materializationId: partialWithoutGap.materializationId,
        expectedHeadRevision: 0,
        expectedPageCount: 1,
        expectedItemCount: 2,
        expectedGapCount: 0,
        expectedLastPageDigest: missingGapAppended.pageDigest,
      }),
      "TIMELINE_CANDIDATE_REJECTED",
    );

    const validStructuralPartial = store.beginTimelineMaterialization({
      context,
      thread,
      materializationId: "coverage-valid-structural-partial",
      evidence: evidence(2),
    });
    const validStructuralPage = page(validStructuralPartial.materializationId);
    validStructuralPage.items = [
      validStructuralPage.items[0]!,
      { ...validStructuralPage.items[1]!, timelineOrdinal: 2 },
    ];
    validStructuralPage.gaps = [{ ...invalidPage.gaps[0]!, gapId: "gap-valid-structural" }];
    validStructuralPage.coverageIslands = [{
      ...validStructuralPage.coverageIslands[0]!,
      lastTimelineOrdinal: 2,
      structuralCoverage: "PARTIAL",
    }];
    const validStructuralAppended = store.appendTimelinePage(validStructuralPage);
    expect(store.sealTimelineMaterialization({
      context,
      thread,
      materializationId: validStructuralPartial.materializationId,
      expectedHeadRevision: 0,
      expectedPageCount: 1,
      expectedItemCount: 2,
      expectedGapCount: 1,
      expectedLastPageDigest: validStructuralAppended.pageDigest,
    })).toMatchObject({ materializationId: "coverage-valid-structural-partial" });

    const validPayloadPartial = store.beginTimelineMaterialization({
      context,
      thread,
      materializationId: "coverage-valid-payload-partial",
      evidence: evidence(),
    });
    const validPayloadPage = page(validPayloadPartial.materializationId);
    validPayloadPage.gaps = [{
      gapId: "gap-valid-payload",
      gapOrdinal: 0,
      gapKind: "PAYLOAD",
      firstMissingTimelineOrdinal: 0,
      lastMissingTimelineOrdinal: 0,
      reason: "ITEM_PAYLOAD_UNAVAILABLE",
      descriptor: { missingFields: ["text"] },
    }];
    validPayloadPage.coverageIslands = [{
      ...validPayloadPage.coverageIslands[0]!,
      payloadCoverage: "PARTIAL",
    }];
    const validPayloadAppended = store.appendTimelinePage(validPayloadPage);
    expect(store.sealTimelineMaterialization({
      context,
      thread,
      materializationId: validPayloadPartial.materializationId,
      expectedHeadRevision: 1,
      expectedPageCount: 1,
      expectedItemCount: 2,
      expectedGapCount: 1,
      expectedLastPageDigest: validPayloadAppended.pageDigest,
    })).toMatchObject({ materializationId: "coverage-valid-payload-partial" });

    const splitItems = [
      { ...page("split").items[0]!, timelineOrdinal: 0 },
      { ...page("split").items[1]!, timelineOrdinal: 2 },
    ];
    const betweenGap = [{
      gapId: "gap-between-islands",
      gapOrdinal: 0,
      gapKind: "STRUCTURAL" as const,
      firstMissingTimelineOrdinal: 1,
      lastMissingTimelineOrdinal: 1,
      reason: "PROVIDER_PAGE_MISSING" as const,
      descriptor: {},
    }];
    const splitIslands = [
      {
        islandId: "split-left",
        islandOrdinal: 0,
        firstTimelineOrdinal: 0,
        lastTimelineOrdinal: 0,
        structuralCoverage: "COMPLETE" as const,
        payloadCoverage: "COMPLETE" as const,
      },
      {
        islandId: "split-right",
        islandOrdinal: 1,
        firstTimelineOrdinal: 2,
        lastTimelineOrdinal: 2,
        structuralCoverage: "COMPLETE" as const,
        payloadCoverage: "COMPLETE" as const,
      },
    ];
    expectStoreError(
      () => verifyTimelineCoverage(
        evidence(2), splitItems, betweenGap, splitIslands, undefined, "f".repeat(64),
      ),
      "TIMELINE_CANDIDATE_REJECTED",
    );
    expect(() => verifyTimelineCoverage(
      evidence(2),
      splitItems,
      betweenGap,
      splitIslands.map((island) => ({ ...island, structuralCoverage: "PARTIAL" as const })),
      undefined,
      "f".repeat(64),
    )).not.toThrow();

    expectStoreError(
      () => verifyTimelineCoverage(
        evidence(2),
        splitItems,
        [
          ...betweenGap,
          {
            gapId: "payload-without-item",
            gapOrdinal: 1,
            gapKind: "PAYLOAD",
            firstMissingTimelineOrdinal: 1,
            lastMissingTimelineOrdinal: 1,
            reason: "ITEM_PAYLOAD_UNAVAILABLE",
            descriptor: {},
          },
        ],
        [{
          islandId: "payload-island",
          islandOrdinal: 0,
          firstTimelineOrdinal: 0,
          lastTimelineOrdinal: 2,
          structuralCoverage: "PARTIAL",
          payloadCoverage: "PARTIAL",
        }],
        undefined,
        "f".repeat(64),
      ),
      "TIMELINE_CANDIDATE_REJECTED",
    );
  });

  it("preserves signed timeline coordinates and scopes item identity to its provider turn", () => {
    const store = open();
    const materialization = store.beginTimelineMaterialization({
      context,
      thread,
      materializationId: "signed-composite-identity",
      evidence: {
        ...evidence(),
        requestId: "read-signed-composite",
        providerRevision: "provider-revision-signed-composite",
        firstTimelineOrdinal: -2,
        lastTimelineOrdinal: 1,
      },
    });
    const signedPage = page(materialization.materializationId);
    signedPage.items = [
      {
        itemId: "shared-item",
        providerTurnId: "turn-older",
        turnOrdinal: -1,
        itemOrdinal: 0,
        timelineOrdinal: -2,
        kind: "USER_MESSAGE",
        payload: { text: "older" },
      },
      {
        itemId: "older-answer",
        providerTurnId: "turn-older",
        turnOrdinal: -1,
        itemOrdinal: 1,
        timelineOrdinal: -1,
        kind: "ASSISTANT_MESSAGE",
        payload: { text: "older answer" },
      },
      {
        itemId: "shared-item",
        providerTurnId: "turn-current",
        turnOrdinal: 0,
        itemOrdinal: 0,
        timelineOrdinal: 0,
        kind: "USER_MESSAGE",
        payload: { text: "current" },
      },
      {
        itemId: "current-answer",
        providerTurnId: "turn-current",
        turnOrdinal: 0,
        itemOrdinal: 1,
        timelineOrdinal: 1,
        kind: "ASSISTANT_MESSAGE",
        payload: { text: "current answer" },
      },
    ];
    signedPage.coverageIslands = [{
      islandId: "signed-island",
      islandOrdinal: 0,
      firstTimelineOrdinal: -2,
      lastTimelineOrdinal: 1,
      structuralCoverage: "COMPLETE",
      payloadCoverage: "COMPLETE",
    }];
    const appended = store.appendTimelinePage(signedPage);
    const sealed = store.sealTimelineMaterialization({
      context,
      thread,
      materializationId: materialization.materializationId,
      expectedHeadRevision: 0,
      expectedPageCount: 1,
      expectedItemCount: 4,
      expectedGapCount: 0,
      expectedLastPageDigest: appended.pageDigest,
    });
    expect(sealed.items.map((item) => [item.providerTurnId, item.itemId, item.timelineOrdinal])).toEqual([
      ["turn-older", "shared-item", -2],
      ["turn-older", "older-answer", -1],
      ["turn-current", "shared-item", 0],
      ["turn-current", "current-answer", 1],
    ]);
    expect(store.readTimeline(thread, { startTimelineOrdinal: -2, limit: 2 })?.items
      .map((item) => item.timelineOrdinal)).toEqual([-2, -1]);

    const duplicate = store.beginTimelineMaterialization({
      context,
      thread,
      materializationId: "duplicate-composite-identity",
      evidence: evidence(),
    });
    const duplicatePage = page(duplicate.materializationId);
    duplicatePage.items = [
      duplicatePage.items[0]!,
      { ...duplicatePage.items[1]!, itemId: duplicatePage.items[0]!.itemId },
    ];
    expectStoreError(() => store.appendTimelinePage(duplicatePage), "TIMELINE_CANDIDATE_REJECTED");

    const crossPageDuplicate = store.beginTimelineMaterialization({
      context,
      thread,
      materializationId: "cross-page-composite-identity",
      evidence: evidence(),
    });
    const firstPage = page(crossPageDuplicate.materializationId);
    firstPage.items = [firstPage.items[0]!];
    firstPage.coverageIslands = [];
    const firstAppended = store.appendTimelinePage(firstPage);
    const secondPage = page(crossPageDuplicate.materializationId, 1, firstAppended.pageDigest);
    secondPage.items = [{
      ...firstPage.items[0]!,
      itemOrdinal: 1,
      timelineOrdinal: 1,
    }];
    secondPage.coverageIslands = [];
    expect(() => store.appendTimelinePage(secondPage)).toThrow(/UNIQUE constraint failed/);
  });

  it("rejects unsafe ordinal scalars at the SQLite boundary", () => {
    const store = open();
    const materialization = store.beginTimelineMaterialization({
      context,
      thread,
      materializationId: "unsafe-sql-ordinal",
      evidence: evidence(2),
    });
    const stagedPage = page(materialization.materializationId);
    stagedPage.items = [
      stagedPage.items[0]!,
      { ...stagedPage.items[1]!, timelineOrdinal: 2 },
    ];
    stagedPage.gaps = [{
      gapId: "unsafe-sql-gap",
      gapOrdinal: 0,
      gapKind: "STRUCTURAL",
      firstMissingTimelineOrdinal: 1,
      lastMissingTimelineOrdinal: 1,
      reason: "PROVIDER_PAGE_MISSING",
      descriptor: { repair: "OLDER_PAGE" },
    }];
    stagedPage.coverageIslands = [{
      ...stagedPage.coverageIslands[0]!,
      lastTimelineOrdinal: 2,
      structuralCoverage: "PARTIAL",
    }];
    store.appendTimelinePage(stagedPage);
    const database = (store as unknown as { database: Database.Database }).database;
    for (const [table, column] of [
      ["timeline_page", "page_index"],
      ["timeline_item", "turn_ordinal"],
      ["timeline_item", "item_ordinal"],
      ["timeline_item", "timeline_ordinal"],
      ["timeline_gap", "gap_ordinal"],
      ["timeline_gap", "first_missing_timeline_ordinal"],
      ["timeline_gap", "last_missing_timeline_ordinal"],
      ["timeline_coverage_island", "island_ordinal"],
      ["timeline_coverage_island", "first_timeline_ordinal"],
      ["timeline_coverage_island", "last_timeline_ordinal"],
    ] as const) {
      expect(() => database.prepare(
        `UPDATE ${table} SET ${column}=9007199254740992 WHERE materialization_id=?`,
      ).run(materialization.materializationId), `${table}.${column}`).toThrow();
    }
  });

  it("verifies the authorized 100k timeline scale without nested island scans", () => {
    const count = 100_000;
    const items = Array.from({ length: count }, (_, ordinal) => ({
      itemId: `item-${ordinal}`,
      providerTurnId: `turn-${ordinal}`,
      turnOrdinal: ordinal,
      itemOrdinal: 0,
      timelineOrdinal: ordinal,
      kind: "USER_MESSAGE",
      payload: {},
    }));
    const islands = Array.from({ length: count }, (_, ordinal) => ({
      islandId: `island-${ordinal}`,
      islandOrdinal: ordinal,
      firstTimelineOrdinal: ordinal,
      lastTimelineOrdinal: ordinal,
      structuralCoverage: "COMPLETE" as const,
      payloadCoverage: "COMPLETE" as const,
    }));
    expect(() => verifyTimelineCoverage(
      evidence(count - 1),
      items,
      [],
      islands,
      undefined,
      "f".repeat(64),
    )).not.toThrow();
  }, 10_000);

  it("verifies one hundred thousand ordered mixed gaps in linear passes", () => {
    const rangeSize = 100_000;
    const items = Array.from({ length: rangeSize / 2 }, (_, index) => ({
      itemId: `mixed-item-${index}`,
      providerTurnId: `mixed-turn-${index}`,
      turnOrdinal: index,
      itemOrdinal: 0,
      timelineOrdinal: index * 2,
      kind: "USER_MESSAGE",
      payload: {},
    }));
    const gaps = Array.from({ length: rangeSize }, (_, gapOrdinal) => {
      const payload = gapOrdinal % 2 === 0;
      return {
        gapId: `mixed-gap-${gapOrdinal}`,
        gapOrdinal,
        gapKind: payload ? "PAYLOAD" as const : "STRUCTURAL" as const,
        firstMissingTimelineOrdinal: gapOrdinal,
        lastMissingTimelineOrdinal: gapOrdinal,
        reason: payload ? "ITEM_PAYLOAD_UNAVAILABLE" as const : "PROVIDER_PAGE_MISSING" as const,
        descriptor: {},
      };
    });
    expect(() => verifyTimelineCoverage(
      evidence(rangeSize - 1),
      items,
      gaps,
      [{
        islandId: "mixed-island",
        islandOrdinal: 0,
        firstTimelineOrdinal: 0,
        lastTimelineOrdinal: rangeSize - 1,
        structuralCoverage: "PARTIAL",
        payloadCoverage: "PARTIAL",
      }],
      undefined,
      "f".repeat(64),
    )).not.toThrow();
  }, 10_000);

  it("keeps failed, partial, timeout, and read-error evidence away from canonical head", () => {
    const store = open();
    commitGoodTimeline(store, "last-good", 0);
    for (const [index, outcome] of ["FAILED", "PARTIAL", "TIMEOUT", "READ_ERROR"].entries()) {
      store.recordTimelineReadAttempt({
        context,
        thread,
        attemptId: `attempt-${index}`,
        outcome: outcome as "FAILED" | "PARTIAL" | "TIMEOUT" | "READ_ERROR",
        problem: { code: outcome },
      });
    }
    expect(store.diagnostics().tableCounts.timeline_read_attempt).toBe(4);
    expect(store.readTimeline(thread)).toMatchObject({ headRevision: 1, materializationId: "last-good" });
  });

  it("accepts EMPTY_PROVEN only with exact whole-scope read evidence", () => {
    const store = open();
    const materialization = store.beginTimelineMaterialization({
      context,
      thread,
      materializationId: "materialization-empty",
      evidence: evidence(0),
    });
    const empty = store.sealTimelineMaterialization({
      context,
      thread,
      materializationId: materialization.materializationId,
      expectedHeadRevision: 0,
      expectedPageCount: 0,
      expectedItemCount: 0,
      expectedGapCount: 0,
      emptyProof: {
        proofKind: "PROVIDER_CONFIRMED_EMPTY",
        providerRevision: materialization.evidence.providerRevision,
        observationDigest: materialization.readEvidenceDigest,
      },
    });
    expect(empty).toMatchObject({ totalItemCount: 0, totalGapCount: 0, materializationId: "materialization-empty" });

    const invalid = store.beginTimelineMaterialization({
      context,
      thread,
      materializationId: "materialization-empty-invalid",
      evidence: { ...evidence(0), readScope: "BOUNDED_RANGE" },
    });
    expectStoreError(
      () => store.sealTimelineMaterialization({
        context,
        thread,
        materializationId: invalid.materializationId,
        expectedHeadRevision: 1,
        expectedPageCount: 0,
        expectedItemCount: 0,
        expectedGapCount: 0,
        emptyProof: {
          proofKind: "PROVIDER_CONFIRMED_EMPTY",
          providerRevision: invalid.evidence.providerRevision,
          observationDigest: invalid.readEvidenceDigest,
        },
      }),
      "TIMELINE_CANDIDATE_REJECTED",
    );
  });

  it("rejects an open page chain and a page body above 256 KiB", () => {
    const store = open();
    expectStoreError(
      () => store.beginTimelineMaterialization({
        context,
        thread,
        materializationId: "materialization-range-overflow",
        evidence: evidence(100_000),
      }),
      "PAYLOAD_TOO_LARGE",
    );
    const materialization = store.beginTimelineMaterialization({
      context,
      thread,
      materializationId: "materialization-page-bounds",
      evidence: evidence(),
    });
    store.appendTimelinePage(page(materialization.materializationId));
    expectStoreError(
      () => store.appendTimelinePage({
        context,
        thread,
        materializationId: materialization.materializationId,
        pageIndex: 1,
        previousPageDigest: "f".repeat(64),
        items: [],
        gaps: [],
        coverageIslands: [],
      }),
      "TIMELINE_PAGE_CHAIN_INVALID",
    );
    const oversized = store.beginTimelineMaterialization({
      context,
      thread,
      materializationId: "materialization-page-oversized",
      evidence: evidence(),
    });
    const oversizedPage = page(oversized.materializationId);
    oversizedPage.items = [
      { ...oversizedPage.items[0]!, payload: { text: "x".repeat(270_000) } },
    ];
    expectStoreError(() => store.appendTimelinePage(oversizedPage), "PAYLOAD_TOO_LARGE");
  });

  it("rolls back a staged seal fault without deleting or advancing last-good", () => {
    let armed = false;
    const store = open({
      faultHook: (stage) => {
        if (armed && stage === "timeline.after-materialization-seal") throw new Error("seal crash");
      },
    });
    commitGoodTimeline(store, "last-good", 0);
    const candidate = store.beginTimelineMaterialization({
      context,
      thread,
      materializationId: "replacement-crash",
      evidence: evidence(),
    });
    const appended = store.appendTimelinePage(page(candidate.materializationId));
    armed = true;
    expect(() => store.sealTimelineMaterialization({
      context,
      thread,
      materializationId: candidate.materializationId,
      expectedHeadRevision: 1,
      expectedPageCount: 1,
      expectedItemCount: 2,
      expectedGapCount: 0,
      expectedLastPageDigest: appended.pageDigest,
    })).toThrow("seal crash");
    armed = false;
    expect(store.readTimeline(thread)).toMatchObject({ headRevision: 1, materializationId: "last-good" });
  });

  it("resamples time behind the write fence before admitting a claim", () => {
    let now = 1_000;
    const store = open({ now: () => now });
    const ref: InteractionRef = {
      thread,
      providerTurnId: "turn-claim-lock-wait",
      interactionId: "interaction-claim-lock-wait",
    };
    const opened = store.openInteraction({
      context,
      ref,
      providerRequestId: "provider-request-claim-lock-wait",
      variant: "QUESTION",
      expiresAt: 2_000,
      descriptor: { prompt: "Choose", questions: [{ questionId: "q" }] },
    });
    const restore = advanceClockAfterFence(store, 1, () => {
      now = 1_101;
    });
    expectStoreError(
      () => store.claimInteraction({
        context,
        ref,
        expectedInteractionRevision: opened.revision,
        claimId: "claim-lock-wait",
        claimToken,
        expiresAt: 1_100,
      }),
      "CLAIM_EXPIRED",
    );
    restore();
    expect(store.getInteraction(ref)).toMatchObject({ state: "OPEN_UNCLAIMED", revision: 1 });
    expect(store.getActiveClaim(ref)).toBeUndefined();
  });

  it("resamples time behind the write fence before renewing or responding", () => {
    let now = 1_000;
    const store = open({ now: () => now });
    const renewRef: InteractionRef = {
      thread,
      providerTurnId: "turn-renew-lock-wait",
      interactionId: "interaction-renew-lock-wait",
    };
    const renewOpened = store.openInteraction({
      context,
      ref: renewRef,
      providerRequestId: "provider-request-renew-lock-wait",
      variant: "QUESTION",
      expiresAt: 2_000,
      descriptor: { prompt: "Renew", questions: [{ questionId: "q" }] },
    });
    const renewClaimed = store.claimInteraction({
      context,
      ref: renewRef,
      expectedInteractionRevision: renewOpened.revision,
      claimId: "claim-renew-lock-wait",
      claimToken,
      expiresAt: 1_100,
    });
    const responseRef = openClaimedQuestion(store, now, 1_100);

    let restore = advanceClockAfterFence(store, 1, () => {
      now = 1_101;
    });
    expectStoreError(
      () => store.renewInteractionClaim({
        context,
        ref: renewRef,
        expectedInteractionRevision: renewClaimed.interaction.revision,
        claimId: renewClaimed.claim.claimId,
        expectedClaimRevision: renewClaimed.claim.revision,
        claimToken,
        expiresAt: 1_500,
      }),
      "CLAIM_EXPIRED",
    );
    restore();

    now = 1_000;
    const beforeResponse = store.diagnostics().tableCounts;
    restore = advanceClockAfterFence(store, 1, () => {
      now = 1_101;
    });
    expectStoreError(() => store.respondInteraction(responseInput(responseRef)), "CLAIM_EXPIRED");
    restore();
    expect(store.diagnostics().tableCounts).toEqual(beforeResponse);
  });

  it("resamples time behind the write fence for interaction and active-claim reads", () => {
    let now = 1_000;
    const store = open({ now: () => now });
    const openAndClaim = (suffix: string): InteractionRef => {
      const ref: InteractionRef = {
        thread,
        providerTurnId: `turn-read-lock-wait-${suffix}`,
        interactionId: `interaction-read-lock-wait-${suffix}`,
      };
      const opened = store.openInteraction({
        context,
        ref,
        providerRequestId: `provider-request-read-lock-wait-${suffix}`,
        variant: "QUESTION",
        expiresAt: 2_000,
        descriptor: { prompt: "Read", questions: [{ questionId: "q" }] },
      });
      store.claimInteraction({
        context,
        ref,
        expectedInteractionRevision: opened.revision,
        claimId: `claim-read-lock-wait-${suffix}`,
        claimToken: `${claimToken}:${suffix}`,
        expiresAt: 1_100,
      });
      return ref;
    };
    const interactionReadRef = openAndClaim("interaction");
    const claimReadRef = openAndClaim("claim");

    let restore = advanceClockAfterFence(store, 1, () => {
      now = 1_101;
    });
    expect(store.getInteraction(interactionReadRef)).toMatchObject({ state: "OPEN_UNCLAIMED", revision: 3 });
    restore();

    now = 1_000;
    restore = advanceClockAfterFence(store, 1, () => {
      now = 1_101;
    });
    expect(store.getActiveClaim(claimReadRef)).toBeUndefined();
    restore();
    expect(store.getInteraction(claimReadRef)).toMatchObject({ state: "OPEN_UNCLAIMED", revision: 3 });
  });

  it("takes interaction actor only from authenticated context and consumes the claim in the response barrier", () => {
    let now = 1_000;
    const store = open({ now: () => now });
    const ref = openClaimedQuestion(store, now);
    const beforeWrong = store.diagnostics().tableCounts;
    expectStoreError(
      () => store.respondInteraction({
        ...responseInput(ref, wrongActorContext),
        claimedFingerprint: "f".repeat(64),
      }),
      "CLAIM_NOT_OWNED",
    );
    expect(store.diagnostics().tableCounts).toEqual(beforeWrong);
    expectStoreError(
      () => store.respondInteraction({ ...responseInput(ref), variant: "APPROVAL", operationCode: "OP-019" }),
      "WRONG_INTERACTION_VARIANT",
    );
    expect(store.diagnostics().tableCounts).toEqual(beforeWrong);

    const response = store.respondInteraction(responseInput(ref));
    expect(response).toMatchObject({
      kind: "RECORDED",
      interaction: { state: "RESPONDING", responseActorId: "actor-a" },
      operation: { state: "DURABLY_ADMITTED", operationCode: "OP-020" },
    });
    expect(store.getActiveClaim(ref)).toBeUndefined();
    const beforeDuplicate = store.diagnostics().tableCounts;
    expect(store.respondInteraction(responseInput(ref)).kind).toBe("IDEMPOTENT");
    expect(store.diagnostics().tableCounts).toEqual(beforeDuplicate);
    now = 2_001;
    expect(store.respondInteraction(responseInput(ref)).kind).toBe("IDEMPOTENT");
    expect(store.diagnostics().tableCounts).toEqual(beforeDuplicate);
    expectStoreError(
      () => store.respondInteraction({
        ...responseInput(ref),
        response: { answers: [{ kind: "free_text", questionId: "q", text: "other" }] },
      }),
      "OPERATION_FINGERPRINT_CONFLICT",
    );
    expect(store.diagnostics().tableCounts).toEqual(beforeDuplicate);
  });

  it("rolls back claim consumption, RESPONDING state, and response operation at a response fault seam", () => {
    let armed = false;
    const store = open({
      now: () => 1_000,
      faultHook: (stage) => {
        if (armed && stage === "interaction.after-operation") throw new Error("response barrier crash");
      },
    });
    const ref = openClaimedQuestion(store, 1_000);
    armed = true;
    expect(() => store.respondInteraction(responseInput(ref))).toThrow("response barrier crash");
    armed = false;
    expect(store.getInteraction(ref)).toMatchObject({ state: "CLAIMED", revision: 2 });
    expect(store.getActiveClaim(ref)).toMatchObject({ state: "ACTIVE", revision: 1 });
    expect(store.diagnostics().tableCounts.operation).toBe(0);
  });

  it("rejects wrong-source and expired interaction responses with zero side effects", () => {
    let now = 1_000;
    const store = open({ now: () => now });
    const ref = openClaimedQuestion(store, now, 1_100);
    const before = store.diagnostics().tableCounts;
    expectStoreError(
      () => store.respondInteraction(responseInput(ref, wrongSourceContext)),
      "SOURCE_FENCE_MISMATCH",
    );
    expect(store.diagnostics().tableCounts).toEqual(before);
    now = 1_101;
    expectStoreError(() => store.respondInteraction(responseInput(ref)), "CLAIM_EXPIRED");
    expect(store.diagnostics().tableCounts).toEqual(before);
    expect(store.getInteraction(ref)).toMatchObject({ state: "EXPIRED", revision: 3 });
    expect(store.getActiveClaim(ref)).toBeUndefined();
  });

  it("checks the exact source epoch before reclaim expiry normalization", () => {
    let now = 1_000;
    const store = open({ now: () => now });
    const ref: InteractionRef = {
      thread,
      providerTurnId: "turn-stale-epoch-reclaim",
      interactionId: "interaction-stale-epoch-reclaim",
    };
    const opened = store.openInteraction({
      context,
      ref,
      providerRequestId: "provider-request-stale-epoch-reclaim",
      variant: "QUESTION",
      expiresAt: 2_000,
      descriptor: { prompt: "Choose", questions: [{ questionId: "q" }] },
    });
    store.claimInteraction({
      context,
      ref,
      expectedInteractionRevision: opened.revision,
      claimId: "claim-stale-epoch-reclaim",
      claimToken,
      expiresAt: 1_100,
    });
    now = 1_101;
    const staleContext: AuthenticatedExecutionContext = {
      ...context,
      sourceEpoch: { ...context.sourceEpoch, providerGeneration: context.sourceEpoch.providerGeneration + 1 },
    };
    expectStoreError(
      () => store.claimInteraction({
        context: staleContext,
        ref,
        expectedInteractionRevision: 2,
        claimId: "claim-stale-epoch-replacement",
        claimToken: `${claimToken}:replacement`,
        expiresAt: 1_500,
      }),
      "SOURCE_FENCE_MISMATCH",
    );
    const database = (store as unknown as { database: Database.Database }).database;
    expect(database.prepare(
      "SELECT state,revision FROM interaction WHERE interaction_id=?",
    ).get(ref.interactionId)).toEqual({ state: "CLAIMED", revision: 2 });
    expect(database.prepare(
      "SELECT state,revision FROM interaction_claim WHERE interaction_id=?",
    ).get(ref.interactionId)).toEqual({ state: "ACTIVE", revision: 1 });
  });

  it("expires a stale claim on read and allows a revision-fenced reclaim", () => {
    let now = 1_000;
    const store = open({ now: () => now });
    const ref: InteractionRef = {
      thread,
      providerTurnId: "turn-reclaim",
      interactionId: "interaction-reclaim",
    };
    const opened = store.openInteraction({
      context,
      ref,
      providerRequestId: "provider-request-reclaim",
      variant: "QUESTION",
      expiresAt: 2_000,
      descriptor: { prompt: "Choose", questions: [{ questionId: "q" }] },
    });
    store.claimInteraction({
      context,
      ref,
      expectedInteractionRevision: opened.revision,
      claimId: "claim-reclaim-first",
      claimToken,
      expiresAt: 1_100,
    });
    now = 1_101;
    expect(store.getInteraction(ref)).toMatchObject({ state: "OPEN_UNCLAIMED", revision: 3 });
    expect(store.getActiveClaim(ref)).toBeUndefined();
    const database = (store as unknown as { database: Database.Database }).database;
    expect(database.prepare(
      "SELECT state,revision FROM interaction_claim WHERE claim_id='claim-reclaim-first'",
    ).get()).toEqual({ state: "EXPIRED", revision: 2 });

    const reclaimed = store.claimInteraction({
      context,
      ref,
      expectedInteractionRevision: 3,
      claimId: "claim-reclaim-second",
      claimToken: `${claimToken}:second`,
      expiresAt: 1_500,
    });
    expect(reclaimed).toMatchObject({
      interaction: { state: "CLAIMED", revision: 4 },
      claim: { claimId: "claim-reclaim-second", state: "ACTIVE", revision: 1 },
    });
  });

  it("rejects claim and renewal leases beyond the immutable interaction expiry", () => {
    const store = open({ now: () => 1_000 });
    const ref: InteractionRef = {
      thread,
      providerTurnId: "turn-lease-bound",
      interactionId: "interaction-lease-bound",
    };
    const opened = store.openInteraction({
      context,
      ref,
      providerRequestId: "provider-request-lease-bound",
      variant: "QUESTION",
      expiresAt: 1_500,
      descriptor: { prompt: "Choose", questions: [{ questionId: "q" }] },
    });
    expectStoreError(
      () => store.openInteraction({
        context,
        ref,
        providerRequestId: "provider-request-lease-bound",
        variant: "QUESTION",
        expiresAt: 1_499,
        descriptor: { prompt: "Choose", questions: [{ questionId: "q" }] },
      }),
      "INTERACTION_REVISION_CONFLICT",
    );
    expectStoreError(
      () => store.claimInteraction({
        context,
        ref,
        expectedInteractionRevision: opened.revision,
        claimId: "claim-too-long",
        claimToken,
        expiresAt: 1_501,
      }),
      "CLAIM_EXPIRED",
    );
    expect(store.getInteraction(ref)).toMatchObject({ state: "OPEN_UNCLAIMED", revision: 1 });

    const claimed = store.claimInteraction({
      context,
      ref,
      expectedInteractionRevision: opened.revision,
      claimId: "claim-bounded",
      claimToken,
      expiresAt: 1_400,
    });
    expectStoreError(
      () => store.renewInteractionClaim({
        context,
        ref,
        expectedInteractionRevision: claimed.interaction.revision,
        claimId: claimed.claim.claimId,
        expectedClaimRevision: claimed.claim.revision,
        claimToken,
        expiresAt: 1_501,
      }),
      "CLAIM_EXPIRED",
    );
    expect(store.getInteraction(ref)).toMatchObject({ state: "CLAIMED", revision: 2 });
    expect(store.getActiveClaim(ref)).toMatchObject({ expiresAt: 1_400, revision: 1 });
    const database = (store as unknown as { database: Database.Database }).database;
    expect(database.prepare(
      "SELECT sql FROM sqlite_master WHERE type='table' AND name='interaction'",
    ).get()).toMatchObject({ sql: expect.stringContaining("expires_at BETWEEN 1 AND 9007199254740991") });
    expect(database.prepare(
      "SELECT sql FROM sqlite_master WHERE type='table' AND name='interaction_claim'",
    ).get()).toMatchObject({ sql: expect.stringContaining("expires_at BETWEEN 1 AND 9007199254740991") });
    expect(() => database.prepare(
      "UPDATE interaction SET expires_at=9007199254740992,revision=revision+1 WHERE interaction_id='interaction-lease-bound'",
    ).run()).toThrow();
    expect(() => database.prepare(
      "UPDATE interaction_claim SET expires_at=9007199254740992,revision=revision+1 WHERE claim_id='claim-bounded'",
    ).run()).toThrow();
    expect(() => database.prepare(
      "UPDATE interaction_claim SET expires_at=1501,revision=revision+1 WHERE claim_id='claim-bounded'",
    ).run()).toThrow(/claim expiry exceeds interaction expiry/);
    expect(() => database.prepare(
      `UPDATE interaction_claim SET state='RELEASED',expires_at=1501,revision=revision+1
       WHERE claim_id='claim-bounded'`,
    ).run()).toThrow(/claim expiry exceeds interaction expiry/);
  });

  it("projects exact serverRequest/resolved evidence to RESOLVED and local SUCCEEDED", () => {
    const store = open({ now: () => 1_000 });
    const ref = openClaimedQuestion(store, 1_000);
    const responded = store.respondInteraction(responseInput(ref));
    let operation = store.beginIdleDispatch({
      context,
      thread,
      operationId: responded.operation.operationId,
      expectedOperationRevision: responded.operation.revision,
      dispatchAttemptId: "attempt-response",
    });
    operation = store.transitionOperation({
      context,
      thread,
      operationId: operation.operationId,
      expectedRevision: operation.revision,
      toState: "PROVIDER_ACCEPTED",
      eventKind: "SERVER_RESPONSE",
      dispatchAttemptId: "attempt-response",
      providerTurnId: ref.providerTurnId,
      providerEvidence: "SERVER_RESPONSE",
    });
    const resolved = store.resolveInteraction({
      context,
      ref,
      expectedInteractionRevision: responded.interaction.revision,
      responseOperationId: operation.operationId,
      providerRequestId: "provider-request-question",
      providerEvent: "SERVER_REQUEST_RESOLVED",
      evidence: resolvedFact(ref),
    });
    expect(resolved.interaction.state).toBe("RESOLVED");
    expect(resolved.operation.state).toBe("SUCCEEDED");
    expect(resolved.operation.canonicalObserved).toBe(true);
  });

  it("keeps a crashed response operation OUTCOME_UNKNOWN while exact resolved fact reconciles projection", () => {
    let store = open({ now: () => 1_000 });
    const ref = openClaimedQuestion(store, 1_000);
    const responded = store.respondInteraction(responseInput(ref));
    store.beginIdleDispatch({
      context,
      thread,
      operationId: responded.operation.operationId,
      expectedOperationRevision: responded.operation.revision,
      dispatchAttemptId: "attempt-response-crash",
    });
    close(store);
    store = open({ now: () => 1_001 });
    expect(store.getOperation(thread, responded.operation.operationId)?.state).toBe("OUTCOME_UNKNOWN");
    const resolved = store.resolveInteraction({
      context,
      ref,
      expectedInteractionRevision: responded.interaction.revision,
      responseOperationId: responded.operation.operationId,
      providerRequestId: "provider-request-question",
      providerEvent: "SERVER_REQUEST_RESOLVED",
      evidence: resolvedFact(ref),
    });
    expect(resolved.interaction.state).toBe("RESOLVED");
    expect(resolved.operation.state).toBe("OUTCOME_UNKNOWN");
    expect(resolved.reconcileResolution?.projectedOutcome).toBe("SUCCEEDED");
  });

  it("enforces direct-SQL JSON checks, terminal immutability, and operation event coupling", () => {
    const store = open();
    const operation = store.admitOperation(admission("ddl")).operation;
    const database = (store as unknown as { database: Database.Database }).database;
    expect(() => database.prepare("UPDATE operation SET payload_json='not-json' WHERE operation_id=?").run(operation.operationId)).toThrow();
    expect(() => database.prepare("DELETE FROM operation WHERE operation_id=?").run(operation.operationId)).toThrow();
    expect(() => database.prepare(
      `INSERT INTO operation_event (
         operation_id,event_sequence,from_state,to_state,event_kind,created_at
       ) VALUES (?,99,'DURABLY_ADMITTED','CALL_STARTED','FORGED',1)`,
    ).run(operation.operationId)).toThrow();
    const coupled = store.admitOperation(admission("ddl-coupled")).operation;
    database.prepare(
      `UPDATE operation SET state='CALL_STARTED',revision=revision+1,
       dispatch_attempt_id='attempt-ddl-coupled',transition_event_kind='DIRECT_SQL_BARRIER'
       WHERE operation_id=?`,
    ).run(coupled.operationId);
    expect(store.listOperationEvents(thread, coupled.operationId).map((event) => event.toState)).toEqual([
      "DURABLY_ADMITTED",
      "CALL_STARTED",
    ]);
    const dispatched = store.beginIdleDispatch({
      context,
      thread,
      operationId: operation.operationId,
      expectedOperationRevision: operation.revision,
      dispatchAttemptId: "attempt-ddl",
    });
    close(store);
    const reopened = open();
    const unknown = reopened.getOperation(thread, dispatched.operationId)!;
    const reopenedDatabase = (reopened as unknown as { database: Database.Database }).database;
    expect(() => reopenedDatabase.prepare("UPDATE operation SET state='CANCELLED' WHERE operation_id=?").run(unknown.operationId)).toThrow();
    expect(reopened.listOperationEvents(thread, unknown.operationId).map((event) => event.toState)).toEqual([
      "DURABLY_ADMITTED",
      "CALL_STARTED",
      "OUTCOME_UNKNOWN",
    ]);
  });

  it("rejects direct-SQL queue and interaction aggregate splits", () => {
    const store = open({ now: () => 1_000 });
    const queued = store.admitAndQueue({
      admission: admission("ddl-queue-root"),
      laneFamily: "NEXT_TURN",
      expectedLaneRevision: 0,
      queueEntryId: "ddl-queue-entry",
    });
    const database = (store as unknown as { database: Database.Database }).database;
    expect(() => database.prepare("DELETE FROM queue_entry WHERE queue_entry_id=?")
      .run(queued.entry.queueEntryId)).toThrow(/cannot be deleted/);
    expect(() => database.prepare(
      "UPDATE queue_entry SET state='CANCELLED',entry_revision=entry_revision+1 WHERE queue_entry_id=?",
    ).run(queued.entry.queueEntryId)).toThrow(/queue update aggregate mismatch/);
    expect(() => database.prepare(
      "UPDATE queue_lane SET active_count=0,revision=revision+1 WHERE lane_family='NEXT_TURN'",
    ).run()).toThrow(/queue lane revision\/aggregate coupling violation/);
    expect(() => database.prepare("DELETE FROM queue_lane WHERE lane_family='NEXT_TURN'").run())
      .toThrow(/cannot be deleted/);
    expect(store.readQueueLane(thread, "NEXT_TURN")).toMatchObject({ activeCount: 1 });
    expect(store.listQueueEntries(thread, "NEXT_TURN")[0]).toMatchObject({ state: "QUEUED" });
    expect(store.getOperation(thread, queued.operation.operationId)).toMatchObject({ state: "QUEUED" });

    const ref = openClaimedQuestion(store, 1_000);
    expect(() => database.prepare(
      `UPDATE interaction SET state='OPEN_UNCLAIMED',revision=revision+1
       WHERE interaction_id=?`,
    ).run(ref.interactionId)).toThrow(/still has an active claim/);
    expect(() => database.prepare("DELETE FROM interaction_claim WHERE interaction_id=?")
      .run(ref.interactionId)).toThrow(/cannot be deleted/);
    expect(() => database.prepare("DELETE FROM interaction WHERE interaction_id=?")
      .run(ref.interactionId)).toThrow(/cannot be deleted/);
    expect(store.getInteraction(ref)).toMatchObject({ state: "CLAIMED" });
    expect(store.getActiveClaim(ref)).toMatchObject({ state: "ACTIVE" });
  });
});

describe("ConversationCoreStoreClient", () => {
  let root: string;
  let filePath: string;
  let clients: ConversationCoreStoreClient[];

  beforeEach(async () => {
    root = await mkdtemp(join(tmpdir(), "ccpocket-store-worker-"));
    filePath = join(root, "worker.db");
    clients = [];
  });

  afterEach(async () => {
    for (const client of clients) await client.close().catch(() => undefined);
    await rm(root, { recursive: true, force: true });
  });

  it("serializes business access in a dedicated worker and rejects all pending calls on crash", async () => {
    const client = await ConversationCoreStoreClient.open({ filePath, writerLeaseTtlMs: 5_000 });
    clients.push(client);
    expect((await client.diagnostics()).schemaVersion).toBe(3);
    await expect(client.admitOperation(admission("worker"))).resolves.toMatchObject({
      operation: { state: "DURABLY_ADMITTED" },
    });
    await expect(client.unsafeCrashWorkerForTest()).rejects.toMatchObject({
      code: "STORE_WORKER_CRASHED",
    });
    await expect(client.diagnostics()).rejects.toMatchObject({ code: "STORE_CLOSED" });
    const immediate = ConversationCoreStoreClient.open({ filePath, writerLeaseTtlMs: 5_000 });
    await expect(immediate).rejects.toMatchObject({ code: "WRITER_ALREADY_OPEN" });
    const leaseDatabase = new Database(filePath);
    leaseDatabase.prepare("UPDATE writer_owner SET lease_expires_at=1,updated_at=1 WHERE singleton=1").run();
    leaseDatabase.close();
    const restarted = await ConversationCoreStoreClient.open({ filePath, writerLeaseTtlMs: 5_000 });
    clients.push(restarted);
    expect((await restarted.diagnostics()).writerOwnerEpoch).toBe(2);
  });
});

function commitGoodTimeline(store: ConversationCoreStore, materializationId: string, expectedHeadRevision: number) {
  const materialization = store.beginTimelineMaterialization({ context, thread, materializationId, evidence: evidence() });
  const appended = store.appendTimelinePage(page(materializationId));
  return store.sealTimelineMaterialization({
    context,
    thread,
    materializationId,
    expectedHeadRevision,
    expectedPageCount: 1,
    expectedItemCount: 2,
    expectedGapCount: 0,
    expectedLastPageDigest: appended.pageDigest,
  });
}

function openClaimedQuestion(store: ConversationCoreStore, now: number, expiresAt = now + 1_000): InteractionRef {
  const ref: InteractionRef = {
    thread,
    providerTurnId: "turn-question",
    interactionId: "interaction-question",
  };
  const opened = store.openInteraction({
    context,
    ref,
    providerRequestId: "provider-request-question",
    variant: "QUESTION",
    expiresAt,
    descriptor: { prompt: "Choose", questions: [{ questionId: "q" }] },
  });
  store.claimInteraction({
    context,
    ref,
    expectedInteractionRevision: opened.revision,
    claimId: "claim-question",
    claimToken,
    expiresAt,
  });
  return ref;
}

function responseInput(ref: InteractionRef, authenticatedContext = context) {
  return {
    context: authenticatedContext,
    ref,
    variant: "QUESTION" as const,
    expectedInteractionRevision: 2,
    claimId: "claim-question",
    expectedClaimRevision: 1,
    claimToken,
    responseOperationId: "operation-question-response",
    responseClientInstanceId: "client-instance-a",
    responseClientMessageId: "client-message-question-response",
    operationCode: "OP-020" as const,
    operationTarget: {
      targetKind: "INTERACTION" as const,
      providerThreadId: ref.thread.providerThreadId,
      providerTurnId: ref.providerTurnId,
      interactionId: ref.interactionId,
      variant: "QUESTION" as const,
    },
    operationPreconditions: { expectedInteractionRevision: 2, expectedClaimRevision: 1 },
    response: { answers: [{ kind: "free_text", questionId: "q", text: "one" }] },
  };
}

function resolvedFact(ref: InteractionRef) {
  return {
    verificationKind: "EXACT_PROVIDER_FACT" as const,
    providerEvent: "serverRequest/resolved" as const,
    providerFactId: "provider-fact-request-resolved",
    providerThreadId: ref.thread.providerThreadId,
    providerTurnId: ref.providerTurnId,
    providerRequestId: "provider-request-question",
    observedAt: 1_000,
  };
}

function advanceClockAfterFence(
  store: ConversationCoreStore,
  occurrence: number,
  advance: () => void,
): () => void {
  const mutable = store as unknown as { fenceLeaseInTransaction: () => void };
  const original = mutable.fenceLeaseInTransaction;
  let seen = 0;
  mutable.fenceLeaseInTransaction = function patchedFence() {
    original.call(store);
    seen += 1;
    if (seen === occurrence) advance();
  };
  return () => {
    mutable.fenceLeaseInTransaction = original;
  };
}

function expectStoreError(action: () => unknown, code: ConversationStoreError["code"]): void {
  try {
    action();
  } catch (error) {
    expect(error).toBeInstanceOf(ConversationStoreError);
    expect((error as ConversationStoreError).code).toBe(code);
    return;
  }
  throw new Error(`Expected ConversationStoreError(${code})`);
}
