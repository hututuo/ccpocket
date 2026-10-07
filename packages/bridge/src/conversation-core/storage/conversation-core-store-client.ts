import { Worker } from "node:worker_threads";

import type { StorageDiagnostics } from "./conversation-core-store.js";
import {
  ConversationStoreError,
  type BeginQueuedDispatchInput,
  type ClaimInteractionInput,
  type DispatchStartInput,
  type InteractionClaimMutationInput,
  type InteractionClaimRecord,
  type InteractionRecord,
  type InteractionRef,
  type OpenInteractionInput,
  type OperationAdmission,
  type OperationEventRecord,
  type OperationRecord,
  type OperationTransition,
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
  type ThreadRef,
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

export interface ConversationCoreStoreClientOptions {
  filePath: string;
  writerLeaseTtlMs?: number;
}

interface PendingCall {
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
}

interface SerializedError {
  name: string;
  message: string;
  code?: string;
  stack?: string;
}

/** The only production entry point: every SQLite call is serialized in one dedicated worker. */
export class ConversationCoreStoreClient {
  private nextId = 1;
  private readonly pending = new Map<number, PendingCall>();
  private closed = false;

  private constructor(private readonly worker: Worker) {}

  static async open(options: ConversationCoreStoreClientOptions): Promise<ConversationCoreStoreClient> {
    const runningTypeScript = import.meta.url.endsWith(".ts");
    const workerUrl = new URL(
      runningTypeScript
        ? "./conversation-core-store-worker-bootstrap.mjs"
        : "./conversation-core-store-worker.js",
      import.meta.url,
    );
    const worker = new Worker(workerUrl, {
      workerData: options,
    });
    const client = new ConversationCoreStoreClient(worker);
    await client.waitUntilReady();
    return client;
  }

  diagnostics(): Promise<StorageDiagnostics> { return this.call("diagnostics"); }
  beginTimelineMaterialization(input: TimelineMaterializationBeginInput): Promise<TimelineMaterializationRecord> {
    return this.call("beginTimelineMaterialization", input);
  }
  appendTimelinePage(input: TimelinePageInput): Promise<TimelinePageRecord> {
    return this.call("appendTimelinePage", input);
  }
  sealTimelineMaterialization(input: TimelineSealInput): Promise<TimelineReadback> {
    return this.call("sealTimelineMaterialization", input);
  }
  readTimeline(thread: ThreadRef, options?: TimelineReadOptions): Promise<TimelineReadback | undefined> {
    return this.call("readTimeline", thread, options ?? {});
  }
  recordTimelineReadAttempt(input: TimelineReadAttemptInput): Promise<TimelineReadAttemptRecord> {
    return this.call("recordTimelineReadAttempt", input);
  }
  admitOperation(admission: OperationAdmission): Promise<{ kind: "ADMITTED" | "IDEMPOTENT"; operation: OperationRecord }> {
    return this.call("admitOperation", admission);
  }
  beginIdleDispatch(input: DispatchStartInput): Promise<OperationRecord> {
    return this.call("beginIdleDispatch", input);
  }
  transitionOperation(input: OperationTransition): Promise<OperationRecord> {
    return this.call("transitionOperation", input);
  }
  getOperation(thread: ThreadRef, operationId: string): Promise<OperationRecord | undefined> {
    return this.call("getOperation", thread, operationId);
  }
  listOperationEvents(thread: ThreadRef, operationId: string): Promise<OperationEventRecord[]> {
    return this.call("listOperationEvents", thread, operationId);
  }
  listOperationsRequiringReconcile(): Promise<OperationRecord[]> {
    return this.call("listOperationsRequiringReconcile");
  }
  recordReconcileFact(input: ReconcileFactInput): Promise<ReconcileResolutionRecord> {
    return this.call("recordReconcileFact", input);
  }
  listReconcileResolutions(operationId: string): Promise<ReconcileResolutionRecord[]> {
    return this.call("listReconcileResolutions", operationId);
  }
  openQueueLane(thread: ThreadRef, laneFamily: string, capacity?: number): Promise<QueueLaneRecord> {
    return this.call("openQueueLane", thread, laneFamily, capacity ?? 16);
  }
  admitAndQueue(input: QueueAdmissionInput): Promise<{
    kind: "ADMITTED" | "IDEMPOTENT";
    operation: OperationRecord;
    entry: QueueEntryRecord;
    lane: QueueLaneRecord;
  }> { return this.call("admitAndQueue", input); }
  controlQueueEntry(input: QueueControlInput): Promise<{
    kind: "RECORDED" | "IDEMPOTENT";
    controlOperation: OperationRecord;
    rootOperation: OperationRecord;
    entry: QueueEntryRecord;
    lane: QueueLaneRecord;
  }> { return this.call("controlQueueEntry", input); }
  beginQueuedDispatch(input: BeginQueuedDispatchInput): Promise<QueueDispatchBarrier | undefined> {
    return this.call("beginQueuedDispatch", input);
  }
  readQueueLane(thread: ThreadRef, laneFamily: string): Promise<QueueLaneRecord | undefined> {
    return this.call("readQueueLane", thread, laneFamily);
  }
  listQueueEntries(thread: ThreadRef, laneFamily: string): Promise<QueueEntryRecord[]> {
    return this.call("listQueueEntries", thread, laneFamily);
  }
  openInteraction(input: OpenInteractionInput): Promise<InteractionRecord> {
    return this.call("openInteraction", input);
  }
  claimInteraction(input: ClaimInteractionInput): Promise<{ interaction: InteractionRecord; claim: InteractionClaimRecord }> {
    return this.call("claimInteraction", input);
  }
  respondInteraction(input: RespondInteractionInput): Promise<{
    kind: "RECORDED" | "IDEMPOTENT";
    interaction: InteractionRecord;
    operation: OperationRecord;
  }> { return this.call("respondInteraction", input); }
  renewInteractionClaim(input: RenewInteractionClaimInput): Promise<{
    interaction: InteractionRecord;
    claim: InteractionClaimRecord;
  }> { return this.call("renewInteractionClaim", input); }
  releaseInteractionClaim(input: InteractionClaimMutationInput): Promise<{
    interaction: InteractionRecord;
    claim: InteractionClaimRecord;
  }> { return this.call("releaseInteractionClaim", input); }
  resolveInteraction(input: ResolveInteractionInput): Promise<{
    interaction: InteractionRecord;
    operation: OperationRecord;
    reconcileResolution?: ReconcileResolutionRecord;
  }> { return this.call("resolveInteraction", input); }
  getInteraction(ref: InteractionRef): Promise<InteractionRecord | undefined> {
    return this.call("getInteraction", ref);
  }
  getActiveClaim(ref: InteractionRef): Promise<InteractionClaimRecord | undefined> {
    return this.call("getActiveClaim", ref);
  }

  async close(): Promise<void> {
    if (this.closed) return;
    await this.call("close");
    this.closed = true;
    await this.worker.terminate();
  }

  /** @internal Regression seam proving pending calls fail when the worker crashes. */
  unsafeCrashWorkerForTest(): Promise<never> {
    return this.call("__testCrash");
  }

  private call<T>(method: string, ...args: unknown[]): Promise<T> {
    if (this.closed) return Promise.reject(new ConversationStoreError("STORE_CLOSED", "store client is closed"));
    const id = this.nextId++;
    return new Promise<T>((resolve, reject) => {
      this.pending.set(id, { resolve: resolve as (value: unknown) => void, reject });
      this.worker.postMessage({ id, method, args });
    });
  }

  private waitUntilReady(): Promise<void> {
    return new Promise((resolve, reject) => {
      const onMessage = (message: { type: string; error?: SerializedError }) => {
        if (message.type === "ready") {
          cleanup();
          this.attachSteadyStateListeners();
          resolve();
        } else if (message.type === "fatal") {
          cleanup();
          reject(deserializeError(message.error));
        }
      };
      const onError = (error: Error) => { cleanup(); reject(error); };
      const onExit = (code: number) => {
        cleanup();
        reject(new ConversationStoreError("STORE_WORKER_CRASHED", `store worker exited before ready (${code})`));
      };
      const cleanup = () => {
        this.worker.off("message", onMessage);
        this.worker.off("error", onError);
        this.worker.off("exit", onExit);
      };
      this.worker.on("message", onMessage);
      this.worker.once("error", onError);
      this.worker.once("exit", onExit);
    });
  }

  private attachSteadyStateListeners(): void {
    this.worker.on("message", (message: {
      type: string;
      id?: number;
      result?: unknown;
      error?: SerializedError;
    }) => {
      if (message.type === "fatal") {
        this.failAll(deserializeError(message.error));
        return;
      }
      if (message.type !== "response" || message.id === undefined) return;
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      if (message.error) pending.reject(deserializeError(message.error));
      else pending.resolve(message.result);
    });
    this.worker.once("error", (error) => this.failAll(error));
    this.worker.once("exit", (code) => {
      if (!this.closed || this.pending.size > 0) {
        this.failAll(new ConversationStoreError("STORE_WORKER_CRASHED", `store worker exited (${code})`));
      }
    });
  }

  private failAll(error: Error): void {
    this.closed = true;
    for (const pending of this.pending.values()) pending.reject(error);
    this.pending.clear();
  }
}

function deserializeError(error: SerializedError | undefined): Error {
  if (!error) return new ConversationStoreError("STORE_WORKER_CRASHED", "store worker failed without details");
  const restored = error.code
    ? new ConversationStoreError(error.code as ConversationStoreError["code"], error.message)
    : new Error(error.message);
  restored.name = error.name;
  if (error.stack) restored.stack = error.stack;
  return restored;
}
