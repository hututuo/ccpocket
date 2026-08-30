import { createHash } from "node:crypto";
import { existsSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

import {
  ConversationCoreStore,
  ConversationStoreError,
  type InteractionRef,
  type OperationState,
  type StoreFaultStage,
  type ThreadRef,
  type TimelineCandidate,
} from "./index.js";

const source = {
  bridgeIdentityId: "bridge-identity-a",
  bridgeInstanceId: "bridge-instance-a",
  codexSourceId: "codex-source-a",
} as const;

const thread: ThreadRef = {
  sourcePartition: source,
  providerThreadId: "thread-a",
};

const wrongSourceThread: ThreadRef = {
  sourcePartition: { ...source, codexSourceId: "codex-source-b" },
  providerThreadId: "thread-a",
};

const claimProofA = ["fixture", "claim", "proof", "a"].join(":");
const claimProofB = ["fixture", "claim", "proof", "b"].join(":");
const expiredClaimProof = ["fixture", "expired", "claim", "proof"].join(":");
const rollbackClaimProof = ["fixture", "rollback", "claim", "proof"].join(":");
const renewClaimProof = ["fixture", "renew", "claim", "proof"].join(":");

const timelineV1: TimelineCandidate = {
  materializationId: "materialization-1",
  verified: true,
  items: [
    {
      itemId: "item-1",
      providerTurnId: "turn-1",
      ordinal: 0,
      kind: "USER_INPUT",
      payload: { text: "first" },
    },
    {
      itemId: "item-2",
      providerTurnId: "turn-1",
      ordinal: 1,
      kind: "ASSISTANT_OUTPUT",
      payload: { text: "answer" },
    },
  ],
  gaps: [],
  metadata: { proof: "strong" },
};

function digest(character: string): string {
  const nibble = ((character.codePointAt(0) ?? 0) % 16).toString(16);
  return nibble.repeat(64);
}

describe("ConversationCoreStore", () => {
  let root: string;
  let filePath: string;
  let stores: ConversationCoreStore[];

  beforeEach(async () => {
    root = await mkdtemp(join(tmpdir(), "ccpocket-conversation-core-"));
    filePath = join(root, "conversation-core-v1.db");
    stores = [];
  });

  afterEach(async () => {
    for (const store of stores) store.close();
    await rm(root, { recursive: true, force: true });
  });

  function open(options?: {
    faultHook?: (stage: StoreFaultStage) => void;
    now?: () => number;
  }): ConversationCoreStore {
    const store = ConversationCoreStore.open({ filePath, ...options });
    stores.push(store);
    return store;
  }

  function close(store: ConversationCoreStore): void {
    store.close();
    stores = stores.filter((candidate) => candidate !== store);
  }

  function admit(
    store: ConversationCoreStore,
    suffix: string,
    targetThread: ThreadRef = thread,
  ) {
    return store.admitOperation({
      thread: targetThread,
      operationId: `operation-${suffix}`,
      clientMessageId: `client-${suffix}`,
      fingerprint: digest(suffix[0] ?? "a"),
      payload: { text: suffix },
    }).operation;
  }

  it("opens explicitly with WAL, foreign keys, strict tables, and a clean database", () => {
    expect(existsSync(filePath)).toBe(false);

    const store = open();
    const diagnostics = store.diagnostics();

    expect(existsSync(filePath)).toBe(true);
    expect(diagnostics.schemaVersion).toBe(1);
    expect(diagnostics.journalMode).toBe("wal");
    expect(diagnostics.foreignKeys).toBe(true);
    expect(diagnostics.quickCheck).toBe("ok");
    expect(diagnostics.foreignKeyViolations).toBe(0);
    expect(diagnostics.strictTables).toEqual([
      "interaction",
      "interaction_claim",
      "meta",
      "operation",
      "operation_event",
      "queue_entry",
      "queue_lane",
      "source_partition",
      "timeline_gap",
      "timeline_head",
      "timeline_item",
    ]);
    expect(Object.values(diagnostics.tableCounts).reduce((sum, count) => sum + count, 0)).toBe(1);
    expectStoreError(
      () => ConversationCoreStore.open({ filePath }),
      "WRITER_ALREADY_OPEN",
    );
  });

  it("commits a verified timeline atomically and returns committed readback", () => {
    const store = open();

    const readback = store.commitTimelineCandidate(thread, 0, timelineV1);

    expect(readback).toMatchObject({
      revision: 1,
      contentRevision: 1,
      materializationId: "materialization-1",
      health: "HEALTHY",
      metadata: { proof: "strong" },
    });
    expect(readback.items.map((item) => item.itemId)).toEqual(["item-1", "item-2"]);
    expect(store.diagnostics().quickCheck).toBe("ok");
  });

  it("stores a full timeline while bounding latest and target readbacks to two hundred", () => {
    const store = open();
    const candidate: TimelineCandidate = {
      materializationId: "materialization-bounded",
      verified: true,
      items: Array.from({ length: 205 }, (_, ordinal) => ({
        itemId: `item-${ordinal}`,
        providerTurnId: `turn-${ordinal}`,
        ordinal,
        kind: "USER_INPUT",
        payload: { ordinal },
      })),
      gaps: [],
    };

    const latest = store.commitTimelineCandidate(thread, 0, candidate);
    expect(latest.totalItemCount).toBe(205);
    expect(latest.items).toHaveLength(200);
    expect(latest.items[0]?.ordinal).toBe(5);
    expect(latest.items.at(-1)?.ordinal).toBe(204);

    const target = store.readTimeline(thread, { startOrdinal: 2, limit: 3 });
    expect(target?.items.map((item) => item.ordinal)).toEqual([2, 3, 4]);
    expect(() => store.readTimeline(thread, { limit: 201 })).toThrow(RangeError);
  });

  it("rolls back a failed timeline stage and preserves last-good across restart", () => {
    let store = open();
    store.commitTimelineCandidate(thread, 0, timelineV1);
    close(store);

    let armed = true;
    store = open({
      faultHook: (stage) => {
        if (armed && stage === "timeline.after-delete") throw new Error("injected crash");
      },
    });
    const replacement: TimelineCandidate = {
      materializationId: "materialization-2",
      verified: true,
      items: [
        {
          itemId: "item-3",
          providerTurnId: "turn-2",
          ordinal: 0,
          kind: "USER_INPUT",
          payload: { text: "replacement" },
        },
      ],
      gaps: [],
    };

    expect(() => store.commitTimelineCandidate(thread, 1, replacement)).toThrow("injected crash");
    armed = false;
    expect(store.readTimeline(thread)?.items.map((item) => item.itemId)).toEqual([
      "item-1",
      "item-2",
    ]);
    close(store);

    store = open();
    expect(store.readTimeline(thread)).toMatchObject({
      revision: 1,
      contentRevision: 1,
      materializationId: "materialization-1",
    });
  });

  it("recovers committed timeline content when the process stops before readback", () => {
    let armed = true;
    let store = open({
      faultHook: (stage) => {
        if (armed && stage === "timeline.after-commit-before-readback") {
          throw new Error("timeline readback interrupted");
        }
      },
    });
    expect(() => store.commitTimelineCandidate(thread, 0, timelineV1)).toThrow(
      "timeline readback interrupted",
    );
    armed = false;
    close(store);

    store = open();
    expect(store.readTimeline(thread)).toMatchObject({
      revision: 1,
      contentRevision: 1,
      materializationId: "materialization-1",
    });
  });

  it("keeps last-good content for degraded, empty, weak, and stale observations", () => {
    const store = open();
    store.commitTimelineCandidate(thread, 0, timelineV1);

    const degraded = store.recordTimelineDegraded(thread, 1, {
      problem: { code: "READ_FAILED" },
    });
    expect(degraded).toMatchObject({
      revision: 2,
      contentRevision: 1,
      health: "DEGRADED",
      healthProblem: { code: "READ_FAILED" },
    });
    expect(degraded.items).toHaveLength(2);

    expectStoreError(
      () =>
        store.commitTimelineCandidate(thread, 2, {
          materializationId: "empty",
          verified: true,
          items: [],
          gaps: [],
        }),
      "TIMELINE_CANDIDATE_REJECTED",
    );
    expectStoreError(
      () => store.commitTimelineCandidate(thread, 2, { ...timelineV1, verified: false }),
      "TIMELINE_CANDIDATE_REJECTED",
    );
    expectStoreError(
      () => store.commitTimelineCandidate(thread, 1, timelineV1),
      "REVISION_CONFLICT",
    );
    expect(store.readTimeline(thread)).toMatchObject({ revision: 2, contentRevision: 1 });
    expect(store.readTimeline(thread)?.items).toHaveLength(2);
  });

  it("persists operation admission idempotently and rejects identity conflicts without changes", () => {
    const store = open();
    const admission = {
      thread,
      operationId: "operation-a",
      clientMessageId: "client-a",
      fingerprint: digest("a"),
      payload: { text: "hello" },
    } as const;

    expect(store.admitOperation(admission).kind).toBe("ADMITTED");
    expect(store.admitOperation(admission).kind).toBe("IDEMPOTENT");
    const before = store.diagnostics().tableCounts;

    expectStoreError(
      () => store.admitOperation({ ...admission, fingerprint: digest("b") }),
      "OPERATION_FINGERPRINT_CONFLICT",
    );
    expectStoreError(
      () => store.admitOperation({ ...admission, clientMessageId: "client-b" }),
      "OPERATION_ID_CONFLICT",
    );
    expect(store.getOperation(wrongSourceThread, "operation-a")).toBeUndefined();
    expect(store.diagnostics().tableCounts).toEqual(before);
    expect(store.listOperationEvents(thread, "operation-a")).toHaveLength(1);
  });

  it("rolls back operation rows and events together at every in-transaction fault seam", () => {
    for (const faultStage of ["operation.after-row", "operation.after-event"] as const) {
      let armed = true;
      const stagePath = join(root, `${faultStage}.db`);
      const store = ConversationCoreStore.open({
        filePath: stagePath,
        faultHook: (stage) => {
          if (armed && stage === faultStage) throw new Error(faultStage);
        },
      });
      stores.push(store);
      expect(() =>
        store.admitOperation({
          thread,
          operationId: `operation-${faultStage}`,
          clientMessageId: `client-${faultStage}`,
          fingerprint: digest("c"),
          payload: {},
        }),
      ).toThrow(faultStage);
      armed = false;
      expect(store.diagnostics().tableCounts.operation).toBe(0);
      expect(store.diagnostics().tableCounts.operation_event).toBe(0);
    }
  });

  it.each([
    ["ADMITTED", "ADMITTED", false],
    ["QUEUED", "QUEUED", false],
    ["DISPATCHING", "OUTCOME_UNKNOWN", true],
    ["PROVIDER_ACCEPTED", "OUTCOME_UNKNOWN", true],
    ["CANONICAL_OBSERVED", "CANONICAL_OBSERVED", false],
  ] as const)(
    "recovers a %s restart window as %s without a replay directive",
    (beforeRestart, afterRestart, reconcileRequired) => {
      let store = open();
      let operation = admit(store, "d");
      operation = advanceOperation(store, operation.state, beforeRestart, operation);
      const revisionBeforeRestart = operation.revision;
      close(store);

      store = open();
      const recovered = store.getOperation(thread, "operation-d");
      expect(recovered?.state).toBe(afterRestart);
      expect(recovered?.reconcileRequired).toBe(reconcileRequired);
      expect("replay" in (recovered ?? {})).toBe(false);
      expect(recovered?.revision).toBe(
        reconcileRequired ? revisionBeforeRestart + 1 : revisionBeforeRestart,
      );
      if (reconcileRequired) {
        expect(store.listOperationsRequiringReconcile()).toHaveLength(1);
        expect(store.listOperationEvents(thread, "operation-d").at(-1)).toMatchObject({
          kind: "RESTART_REQUIRES_RECONCILE",
          details: { replayAuthorized: false },
        });
      }
    },
  );

  it("persists a committed dispatch seam even when readback is interrupted", () => {
    let armed = false;
    let store = open({
      faultHook: (stage) => {
        if (armed && stage === "operation.after-commit-before-readback") {
          throw new Error("process stopped before readback");
        }
      },
    });
    const operation = admit(store, "e");
    armed = true;
    expect(() =>
      store.transitionOperation({
        thread,
        operationId: operation.operationId,
        expectedRevision: operation.revision,
        toState: "DISPATCHING",
        eventKind: "DISPATCH_STARTED",
        dispatchAttemptId: "attempt-e",
      }),
    ).toThrow("process stopped before readback");
    close(store);

    store = open();
    expect(store.getOperation(thread, operation.operationId)).toMatchObject({
      state: "OUTCOME_UNKNOWN",
      dispatchAttemptId: "attempt-e",
      reconcileRequired: true,
    });
    expect(store.getOperation(thread, operation.operationId)?.providerTurnId).toBeUndefined();
  });

  it("binds provider turn identity only from exact response and canonical fact CAS", () => {
    let now = 100;
    const store = open({ now: () => now });
    let operation = admit(store, "turn-binding");
    expect(operation.providerTurnId).toBeUndefined();
    expect(operation.dispatchAttemptId).toBeUndefined();

    operation = store.transitionOperation({
      thread,
      operationId: operation.operationId,
      expectedRevision: operation.revision,
      toState: "DISPATCHING",
      eventKind: "DISPATCH_STARTED",
      dispatchAttemptId: "attempt-turn-binding",
    });
    expect(operation).toMatchObject({
      state: "DISPATCHING",
      revision: 2,
      dispatchAttemptId: "attempt-turn-binding",
      dispatchStartedAt: 100,
    });
    expect(operation.providerTurnId).toBeUndefined();

    now = 110;
    expectStoreError(
      () =>
        store.transitionOperation({
          thread,
          operationId: operation.operationId,
          expectedRevision: operation.revision,
          toState: "PROVIDER_ACCEPTED",
          eventKind: "TURN_START_ACCEPTED",
          dispatchAttemptId: "attempt-other",
          providerTurnId: "provider-turn-1",
          providerTurnEvidence: "TURN_START_RESPONSE",
        }),
      "IDENTITY_CONFLICT",
    );
    expect(store.getOperation(thread, operation.operationId)).toMatchObject({
      state: "DISPATCHING",
      revision: 2,
    });
    expect(store.getOperation(thread, operation.operationId)?.providerTurnId).toBeUndefined();

    operation = store.transitionOperation({
      thread,
      operationId: operation.operationId,
      expectedRevision: operation.revision,
      toState: "PROVIDER_ACCEPTED",
      eventKind: "TURN_START_ACCEPTED",
      dispatchAttemptId: "attempt-turn-binding",
      providerTurnId: "provider-turn-1",
      providerTurnEvidence: "TURN_START_RESPONSE",
    });
    expect(operation).toMatchObject({
      state: "PROVIDER_ACCEPTED",
      revision: 3,
      providerTurnId: "provider-turn-1",
      providerAcceptedAt: 110,
    });

    now = 120;
    expectStoreError(
      () =>
        store.transitionOperation({
          thread,
          operationId: operation.operationId,
          expectedRevision: operation.revision,
          toState: "CANONICAL_OBSERVED",
          eventKind: "CANONICAL_FACT",
          dispatchAttemptId: "attempt-turn-binding",
          providerTurnId: "provider-turn-other",
          providerTurnEvidence: "VERIFIED_FACT",
        }),
      "IDENTITY_CONFLICT",
    );
    operation = store.transitionOperation({
      thread,
      operationId: operation.operationId,
      expectedRevision: operation.revision,
      toState: "CANONICAL_OBSERVED",
      eventKind: "CANONICAL_FACT",
      dispatchAttemptId: "attempt-turn-binding",
      providerTurnId: "provider-turn-1",
      providerTurnEvidence: "VERIFIED_FACT",
    });
    expect(operation).toMatchObject({
      state: "CANONICAL_OBSERVED",
      revision: 4,
      canonicalObserved: true,
      canonicalObservedAt: 120,
    });
    expect(store.listOperationEvents(thread, operation.operationId).slice(1)).toEqual([
      expect.objectContaining({
        sequence: 2,
        dispatchAttemptId: "attempt-turn-binding",
      }),
      expect.objectContaining({
        sequence: 3,
        dispatchAttemptId: "attempt-turn-binding",
        providerTurnId: "provider-turn-1",
      }),
      expect.objectContaining({
        sequence: 4,
        dispatchAttemptId: "attempt-turn-binding",
        providerTurnId: "provider-turn-1",
      }),
    ]);
  });

  it("reconciles a response-before-crash gap only with an exact verified provider turn", () => {
    let store = open();
    let operation = admit(store, "reconcile-turn");
    operation = store.transitionOperation({
      thread,
      operationId: operation.operationId,
      expectedRevision: operation.revision,
      toState: "DISPATCHING",
      eventKind: "DISPATCH_STARTED",
      dispatchAttemptId: "attempt-reconcile-turn",
    });
    close(store);

    store = open();
    operation = store.getOperation(thread, operation.operationId)!;
    expect(operation).toMatchObject({
      state: "OUTCOME_UNKNOWN",
      dispatchAttemptId: "attempt-reconcile-turn",
      reconcileRequired: true,
    });
    expect(operation.providerTurnId).toBeUndefined();
    expectStoreError(
      () =>
        store.transitionOperation({
          thread,
          operationId: operation.operationId,
          expectedRevision: operation.revision,
          toState: "CANONICAL_OBSERVED",
          eventKind: "RECONCILE_CANONICAL_FACT",
          dispatchAttemptId: "attempt-wrong",
          providerTurnId: "provider-turn-reconciled",
          providerTurnEvidence: "VERIFIED_FACT",
        }),
      "IDENTITY_CONFLICT",
    );
    operation = store.transitionOperation({
      thread,
      operationId: operation.operationId,
      expectedRevision: operation.revision,
      toState: "CANONICAL_OBSERVED",
      eventKind: "RECONCILE_CANONICAL_FACT",
      dispatchAttemptId: "attempt-reconcile-turn",
      providerTurnId: "provider-turn-reconciled",
      providerTurnEvidence: "VERIFIED_FACT",
    });
    expect(operation).toMatchObject({
      state: "CANONICAL_OBSERVED",
      providerTurnId: "provider-turn-reconciled",
      reconcileRequired: false,
    });
  });

  it("enforces queue lane and entry revisions, capacity, and FIFO ownership", () => {
    const store = open();
    const operationA = admit(store, "f");
    const operationB = admit(store, "g");
    const operationC = admit(store, "h");
    const lane = store.openQueueLane(thread, "NEXT_TURN", 2);

    const first = store.reserveQueueEntry({
      thread,
      laneFamily: lane.laneFamily,
      expectedLaneRevision: lane.revision,
      queueEntryId: "queue-1",
      rootOperationId: operationA.operationId,
      payloadDigest: digest("1"),
      payload: { text: "first" },
    });
    expect(first).toMatchObject({ fifoOrdinal: 0, revision: 1, state: "QUEUED" });
    expectStoreError(
      () =>
        store.reserveQueueEntry({
          thread,
          laneFamily: lane.laneFamily,
          expectedLaneRevision: lane.revision,
          queueEntryId: "queue-stale",
          rootOperationId: operationB.operationId,
          payloadDigest: digest("2"),
          payload: {},
        }),
      "QUEUE_REVISION_CONFLICT",
    );

    const second = store.reserveQueueEntry({
      thread,
      laneFamily: lane.laneFamily,
      expectedLaneRevision: 2,
      queueEntryId: "queue-2",
      rootOperationId: operationB.operationId,
      payloadDigest: digest("2"),
      payload: { text: "second" },
    });
    expect(second.fifoOrdinal).toBe(1);
    expectStoreError(
      () =>
        store.reserveQueueEntry({
          thread,
          laneFamily: lane.laneFamily,
          expectedLaneRevision: 3,
          queueEntryId: "queue-3",
          rootOperationId: operationC.operationId,
          payloadDigest: digest("3"),
          payload: {},
        }),
      "QUEUE_FULL",
    );

    const edited = store.editQueueEntry({
      thread,
      laneFamily: lane.laneFamily,
      expectedLaneRevision: 3,
      queueEntryId: second.queueEntryId,
      expectedEntryRevision: second.revision,
      payloadDigest: digest("4"),
      payload: { text: "edited" },
    });
    expect(edited).toMatchObject({ revision: 2, state: "EDITED", payload: { text: "edited" } });
    expectStoreError(
      () =>
        store.editQueueEntry({
          thread,
          laneFamily: lane.laneFamily,
          expectedLaneRevision: 4,
          queueEntryId: second.queueEntryId,
          expectedEntryRevision: 1,
          payloadDigest: digest("5"),
          payload: {},
        }),
      "ENTRY_REVISION_CONFLICT",
    );
    expect(store.readQueueLane(thread, lane.laneFamily)?.revision).toBe(4);

    const owned = store.reserveNextQueueEntry({
      thread,
      laneFamily: lane.laneFamily,
      expectedLaneRevision: 4,
    });
    expect(owned).toMatchObject({ queueEntryId: "queue-1", state: "DISPATCH_OWNED" });
    const consumed = store.consumeQueueEntry({
      thread,
      laneFamily: lane.laneFamily,
      expectedLaneRevision: 5,
      queueEntryId: "queue-1",
      expectedEntryRevision: 2,
    });
    expect(consumed.state).toBe("CONSUMED");
    const cancelled = store.cancelQueueEntry({
      thread,
      laneFamily: lane.laneFamily,
      expectedLaneRevision: 6,
      queueEntryId: "queue-2",
      expectedEntryRevision: 2,
    });
    expect(cancelled.state).toBe("CANCELLED");
    expect(store.readQueueLane(thread, lane.laneFamily)).toMatchObject({
      revision: 7,
      activeCount: 0,
      nextFifoOrdinal: 2,
    });
  });

  it("bounds each queue lane at sixteen entries", () => {
    const store = open();
    const operation = admit(store, "i");
    let lane = store.openQueueLane(thread, "START_TURN", 16);
    for (let index = 0; index < 16; index += 1) {
      store.reserveQueueEntry({
        thread,
        laneFamily: lane.laneFamily,
        expectedLaneRevision: lane.revision,
        queueEntryId: `queue-${index}`,
        rootOperationId: operation.operationId,
        payloadDigest: digest((index % 10).toString()),
        payload: { index },
      });
      lane = store.readQueueLane(thread, lane.laneFamily)!;
    }
    expect(lane.activeCount).toBe(16);
    expectStoreError(
      () =>
        store.reserveQueueEntry({
          thread,
          laneFamily: lane.laneFamily,
          expectedLaneRevision: lane.revision,
          queueEntryId: "queue-overflow",
          rootOperationId: operation.operationId,
          payloadDigest: digest("f"),
          payload: {},
        }),
      "QUEUE_FULL",
    );
    expect(store.listQueueEntries(thread, lane.laneFamily)).toHaveLength(16);
  });

  it("rolls back a queue reservation when the writer fails after lane CAS", () => {
    let armed = false;
    const store = open({
      faultHook: (stage) => {
        if (armed && stage === "queue.after-lane-cas") throw new Error("queue crash");
      },
    });
    const operation = admit(store, "j");
    const lane = store.openQueueLane(thread, "NEXT_TURN", 16);
    armed = true;

    expect(() =>
      store.reserveQueueEntry({
        thread,
        laneFamily: lane.laneFamily,
        expectedLaneRevision: lane.revision,
        queueEntryId: "queue-rollback",
        rootOperationId: operation.operationId,
        payloadDigest: digest("a"),
        payload: {},
      }),
    ).toThrow("queue crash");
    armed = false;
    expect(store.readQueueLane(thread, lane.laneFamily)).toMatchObject({
      revision: 1,
      activeCount: 0,
      nextFifoOrdinal: 0,
    });
    expect(store.listQueueEntries(thread, lane.laneFamily)).toHaveLength(0);
  });

  it("enforces one active interaction claim and records a provider-free response barrier", () => {
    let now = 1_000;
    const store = open({ now: () => now });
    const ref: InteractionRef = {
      thread,
      providerTurnId: "turn-claim",
      interactionId: "interaction-claim",
    };
    const opened = store.openInteraction({
      ref,
      providerRequestId: "provider-request-1",
      variant: "QUESTION",
      descriptor: { question: "Choose" },
    });
    const claimed = store.claimInteraction({
      ref,
      expectedInteractionRevision: opened.revision,
      claimId: "claim-a",
      actorId: "actor-a",
      claimToken: claimProofA,
      expiresAt: 2_000,
    });
    expect(claimed.claim.tokenHash).toBe(digestFromText(claimProofA));
    expect(claimed.claim.tokenHash).not.toContain(claimProofA);
    const beforeContention = store.diagnostics().tableCounts;

    expectStoreError(
      () =>
        store.claimInteraction({
          ref,
          expectedInteractionRevision: claimed.interaction.revision,
          claimId: "claim-b",
          actorId: "actor-b",
          claimToken: claimProofB,
          expiresAt: 2_000,
        }),
      "INTERACTION_CONTENDED",
    );
    expect(store.diagnostics().tableCounts).toEqual(beforeContention);
    expect(store.getInteraction(ref)?.revision).toBe(2);
    expect(store.getActiveClaim(ref)?.claimId).toBe("claim-a");

    const wrongRef: InteractionRef = { ...ref, thread: wrongSourceThread };
    expectStoreError(
      () =>
        store.respondInteraction({
          ref: wrongRef,
          expectedInteractionRevision: 2,
          claimId: "claim-a",
          expectedClaimRevision: 1,
          actorId: "actor-a",
          claimToken: claimProofA,
          responseFingerprint: digest("a"),
          responseOperationId: "response-operation-a",
          responseClientMessageId: "response-client-a",
          operationPayload: { kind: "RESPOND_QUESTION" },
          response: { answer: "one" },
        }),
      "INTERACTION_NOT_OPEN",
    );
    expectStoreError(
      () =>
        store.respondInteraction({
          ref,
          expectedInteractionRevision: 2,
          claimId: "claim-a",
          expectedClaimRevision: 1,
          actorId: "actor-b",
          claimToken: claimProofA,
          responseFingerprint: digest("a"),
          responseOperationId: "response-operation-a",
          responseClientMessageId: "response-client-a",
          operationPayload: { kind: "RESPOND_QUESTION" },
          response: { answer: "one" },
        }),
      "CLAIM_NOT_OWNED",
    );
    expect(store.diagnostics().tableCounts).toEqual(beforeContention);

    const responseInput = {
      ref,
      expectedInteractionRevision: 2,
      claimId: "claim-a",
      expectedClaimRevision: 1,
      actorId: "actor-a",
      claimToken: claimProofA,
      responseFingerprint: digest("a"),
      responseOperationId: "response-operation-a",
      responseClientMessageId: "response-client-a",
      operationPayload: { kind: "RESPOND_QUESTION" },
      response: { answer: "one" },
    } as const;
    const response = store.respondInteraction(responseInput);
    expect(response.kind).toBe("RECORDED");
    expect(response.interaction).toMatchObject({
      state: "RESPONSE_PENDING",
      revision: 3,
      responseOperationId: "response-operation-a",
      response: { answer: "one" },
    });
    expect("providerEffect" in response).toBe(false);
    expect(store.diagnostics().tableCounts.operation).toBe(1);
    expect(store.getOperation(thread, "response-operation-a")).toMatchObject({
      state: "ADMITTED",
      clientMessageId: "response-client-a",
    });
    expect(store.diagnostics().tableCounts.interaction_claim).toBe(1);

    const beforeDuplicate = store.diagnostics().tableCounts;
    expect(store.respondInteraction(responseInput).kind).toBe("IDEMPOTENT");
    expect(store.getInteraction(ref)?.revision).toBe(3);
    expect(store.diagnostics().tableCounts).toEqual(beforeDuplicate);
    expectStoreError(
      () =>
        store.respondInteraction({
          ...responseInput,
          responseFingerprint: digest("b"),
        }),
      "INTERACTION_REVISION_CONFLICT",
    );
    expect(store.getInteraction(ref)?.revision).toBe(3);
    now = 1_500;
  });

  it("rejects an expired interaction response without operation or claim side effects", () => {
    let now = 10;
    const store = open({ now: () => now });
    const ref: InteractionRef = {
      thread,
      providerTurnId: "turn-expired",
      interactionId: "interaction-expired",
    };
    const interaction = store.openInteraction({
      ref,
      providerRequestId: "provider-request-expired",
      variant: "APPROVAL",
      descriptor: {},
    });
    store.claimInteraction({
      ref,
      expectedInteractionRevision: interaction.revision,
      claimId: "claim-expired",
      actorId: "actor-a",
      claimToken: expiredClaimProof,
      expiresAt: 20,
    });
    now = 21;
    const before = store.diagnostics().tableCounts;

    expectStoreError(
      () =>
        store.respondInteraction({
          ref,
          expectedInteractionRevision: 2,
          claimId: "claim-expired",
          expectedClaimRevision: 1,
          actorId: "actor-a",
          claimToken: expiredClaimProof,
          responseFingerprint: digest("e"),
          responseOperationId: "response-operation-expired",
          responseClientMessageId: "response-client-expired",
          operationPayload: { kind: "RESPOND_APPROVAL" },
          response: { approved: true },
        }),
      "CLAIM_EXPIRED",
    );
    expect(store.diagnostics().tableCounts).toEqual(before);
    expect(store.getInteraction(ref)).toMatchObject({ state: "OPEN_CLAIMED", revision: 2 });
    expect(store.getActiveClaim(ref)).toMatchObject({ state: "ACTIVE", revision: 1 });
  });

  it("rolls back an interaction response barrier when its transaction is interrupted", () => {
    let armed = false;
    const store = open({
      now: () => 100,
      faultHook: (stage) => {
        if (armed && stage === "interaction.after-row") throw new Error("interaction crash");
      },
    });
    const ref: InteractionRef = {
      thread,
      providerTurnId: "turn-rollback",
      interactionId: "interaction-rollback",
    };
    const opened = store.openInteraction({
      ref,
      providerRequestId: "provider-request-rollback",
      variant: "MCP",
      descriptor: {},
    });
    const claimed = store.claimInteraction({
      ref,
      expectedInteractionRevision: opened.revision,
      claimId: "claim-rollback",
      actorId: "actor-rollback",
      claimToken: rollbackClaimProof,
      expiresAt: 200,
    });
    armed = true;
    expect(() =>
      store.respondInteraction({
        ref,
        expectedInteractionRevision: claimed.interaction.revision,
        claimId: claimed.claim.claimId,
        expectedClaimRevision: claimed.claim.revision,
        actorId: claimed.claim.actorId,
        claimToken: rollbackClaimProof,
        responseFingerprint: digest("a"),
        responseOperationId: "response-operation-rollback",
        responseClientMessageId: "response-client-rollback",
        operationPayload: { kind: "RESPOND_MCP_ELICITATION" },
        response: {},
      }),
    ).toThrow("interaction crash");
    armed = false;
    expect(store.getInteraction(ref)).toMatchObject({ state: "OPEN_CLAIMED", revision: 2 });
    expect(store.getActiveClaim(ref)).toMatchObject({ state: "ACTIVE", revision: 1 });
    expect(store.diagnostics().tableCounts.operation).toBe(0);
  });

  it("renews and releases a claim with exact interaction and claim revisions", () => {
    let now = 100;
    const store = open({ now: () => now });
    const ref: InteractionRef = {
      thread,
      providerTurnId: "turn-renew",
      interactionId: "interaction-renew",
    };
    const opened = store.openInteraction({
      ref,
      providerRequestId: "provider-request-renew",
      variant: "EXIT_PLAN",
      descriptor: {},
    });
    const claimed = store.claimInteraction({
      ref,
      expectedInteractionRevision: opened.revision,
      claimId: "claim-renew",
      actorId: "actor-renew",
      claimToken: renewClaimProof,
      expiresAt: 200,
    });
    const renewed = store.renewInteractionClaim({
      ref,
      expectedInteractionRevision: claimed.interaction.revision,
      claimId: claimed.claim.claimId,
      expectedClaimRevision: claimed.claim.revision,
      actorId: claimed.claim.actorId,
      claimToken: renewClaimProof,
      expiresAt: 300,
    });
    expect(renewed.interaction).toMatchObject({ state: "OPEN_CLAIMED", revision: 3 });
    expect(renewed.claim).toMatchObject({ state: "ACTIVE", revision: 2, expiresAt: 300 });

    const beforeStale = store.diagnostics().tableCounts;
    expectStoreError(
      () =>
        store.releaseInteractionClaim({
          ref,
          expectedInteractionRevision: 2,
          claimId: renewed.claim.claimId,
          expectedClaimRevision: renewed.claim.revision,
          actorId: renewed.claim.actorId,
          claimToken: renewClaimProof,
        }),
      "INTERACTION_REVISION_CONFLICT",
    );
    expect(store.diagnostics().tableCounts).toEqual(beforeStale);

    now = 150;
    const released = store.releaseInteractionClaim({
      ref,
      expectedInteractionRevision: renewed.interaction.revision,
      claimId: renewed.claim.claimId,
      expectedClaimRevision: renewed.claim.revision,
      actorId: renewed.claim.actorId,
      claimToken: renewClaimProof,
    });
    expect(released.interaction).toMatchObject({ state: "OPEN_UNCLAIMED", revision: 4 });
    expect(released.claim).toMatchObject({ state: "RELEASED", revision: 3 });
    expect(store.getActiveClaim(ref)).toBeUndefined();
  });
});

function advanceOperation(
  store: ConversationCoreStore,
  initialState: OperationState,
  targetState: OperationState,
  initial: ReturnType<ConversationCoreStore["getOperation"]> & {},
) {
  let operation = initial;
  const path: OperationState[] =
    targetState === "ADMITTED"
      ? []
      : targetState === "QUEUED"
        ? ["QUEUED"]
        : targetState === "DISPATCHING"
          ? ["DISPATCHING"]
          : targetState === "PROVIDER_ACCEPTED"
            ? ["DISPATCHING", "PROVIDER_ACCEPTED"]
            : ["DISPATCHING", "PROVIDER_ACCEPTED", "CANONICAL_OBSERVED"];
  expect(operation.state).toBe(initialState);
  for (const state of path) {
    const dispatchAttemptId = `attempt-${operation.operationId}`;
    const providerTurnId = `provider-turn-${operation.operationId}`;
    operation = store.transitionOperation({
      thread,
      operationId: operation.operationId,
      expectedRevision: operation.revision,
      toState: state,
      eventKind: `TO_${state}`,
      ...(state === "DISPATCHING" ? { dispatchAttemptId } : {}),
      ...(state === "PROVIDER_ACCEPTED"
        ? {
            dispatchAttemptId,
            providerTurnId,
            providerTurnEvidence: "TURN_START_RESPONSE" as const,
          }
        : {}),
      ...(state === "CANONICAL_OBSERVED"
        ? {
            dispatchAttemptId,
            providerTurnId,
            providerTurnEvidence: "VERIFIED_FACT" as const,
          }
        : {}),
    });
  }
  return operation;
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

function digestFromText(value: string): string {
  return createHash("sha256").update(value, "utf8").digest("hex");
}
