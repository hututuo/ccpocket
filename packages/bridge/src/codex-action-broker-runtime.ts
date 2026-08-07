import { EventEmitter } from "node:events";
import { createHash } from "node:crypto";
import { isCodexActionPayloadWithinLimits } from "./codex-action-payload-limits.js";
import {
  CodexActionBroker,
  CodexActionBrokerDegradedError,
  type CodexActionBrokerHealth,
  type CodexActionRequestIdentity,
  type CodexActionRequestKind,
  type CodexActionRequestRecord,
  type CodexActionRequestState,
} from "./codex-action-broker.js";
import {
  buildCodexServerActionResponse,
  projectCodexServerActionRequest,
  type CodexServerActionDecision,
  type CodexServerActionProjection,
} from "./codex-process.js";
import type {
  CodexSharedRuntimeControl,
  CodexSharedRuntimeControlEvent,
  CodexSharedRuntimeServerRequest,
} from "./codex-shared-runtime-control.js";
import type { CodexActionBrokerWriterLease } from "./codex-action-broker-writer-lease.js";
import type { CodexActionBrokerWriterLeaseLossReason } from "./codex-action-broker-writer-lease.js";

const MAX_BUFFERED_SERVER_REQUESTS = 64;
const WRITER_LEASE_RETRY_MS = 1_000;

export interface CodexActionBrokerRuntimeHealth {
  ready: boolean;
  controlReady: boolean;
  degraded: boolean;
  degradedReason?:
    | CodexActionBrokerHealth["degradedReason"]
    | "generation_unavailable"
    | "writer_lease_unavailable"
    | "runtime_draining"
    | "unsupported_server_request";
  authorityGeneration?: string;
  writerLeaseHeld: boolean;
}

export interface CodexActionBrokerRuntimeRequest {
  opaqueRequestId: string;
  codexSourceId: string;
  threadId: string;
  turnId: string;
  kind: CodexActionRequestKind;
  state: CodexActionRequestState;
  observedAt: string;
  expiresAt: string;
  updatedAt: string;
  authorityGeneration: string;
  live: boolean;
  payloadUnavailableReason?: "payload_too_large";
  toolName?: string;
  input?: Record<string, unknown>;
  allowedActions?: CodexServerActionDecision[];
}

export type CodexActionBrokerRuntimeUpdate =
  | {
      kind: "request";
      request: CodexActionBrokerRuntimeRequest;
    }
  | {
      kind: "health";
      health: CodexActionBrokerRuntimeHealth;
    };

export interface CodexActionBrokerRespondInput {
  opaqueRequestId: string;
  codexSourceId: string;
  threadId: string;
  turnId: string;
  authorityGeneration: string;
  claimantId: string;
  operationId: string;
  action: CodexServerActionDecision;
  answer?: string;
}

export type CodexActionBrokerRespondOutcome =
  | "submitted"
  | "outcomeUnknown"
  | "alreadyResolved"
  | "contended"
  | "expired"
  | "staleGeneration"
  | "unavailable"
  | "invalid";

export interface CodexActionBrokerRespondResult {
  outcome: CodexActionBrokerRespondOutcome;
  request?: CodexActionBrokerRuntimeRequest;
  error?: string;
}

interface LiveBinding {
  identity: CodexActionRequestIdentity;
  transportRequest: CodexSharedRuntimeServerRequest;
  projection: CodexServerActionProjection | null;
}

interface CodexActionBrokerRuntimeEvents {
  update: [CodexActionBrokerRuntimeUpdate];
}

/**
 * Binds the durable identity-only broker to one shared app-server control
 * connection. Request bodies remain exclusively in `liveBindings` and are
 * discarded whenever the transport generation changes.
 */
export class CodexActionBrokerRuntime extends EventEmitter<CodexActionBrokerRuntimeEvents> {
  private started = false;
  private closed = false;
  private draining = false;
  private controlGeneration = 0;
  private brokerGeneration?: number;
  private leaseEpoch?: number;
  private unsupportedRequestObserved = false;
  private activationEpoch = 0;
  private mutationTail: Promise<void> = Promise.resolve();
  private brokerHealth: CodexActionBrokerHealth | undefined;
  private readonly records = new Map<string, CodexActionRequestRecord>();
  private readonly liveBindings = new Map<string, LiveBinding>();
  private readonly payloadUnavailableReasons = new Map<
    string,
    "payload_too_large"
  >();
  private readonly bufferedRequests: CodexSharedRuntimeServerRequest[] = [];
  private readonly inFlightResponses = new Set<
    Promise<CodexActionBrokerRespondResult>
  >();
  private leaseRetryTimer?: ReturnType<typeof setTimeout>;
  private readonly onWriterLeaseLost = (
    reason: CodexActionBrokerWriterLeaseLossReason,
  ): void => {
    console.warn(
      `[codex-action-broker] writer lease lost (${reason}); scheduling recovery`,
    );
    this.enqueue(async () => {
      if (this.closed || this.draining) return;
      const affected = [...this.liveBindings.keys()];
      this.liveBindings.clear();
      this.brokerGeneration = undefined;
      this.leaseEpoch = undefined;
      for (const opaqueRequestId of affected) this.emitRecord(opaqueRequestId);
      if (this.control.ready) {
        this.scheduleLeaseRetry(this.control.connectionGeneration);
      }
      this.emitHealth();
    });
  };

  private readonly onReady = (connectionGeneration: number): void => {
    this.enqueue(() => this.activateGeneration(connectionGeneration));
  };
  private readonly onNotReady = (connectionGeneration: number): void => {
    this.enqueue(async () => this.markControlUnavailable(connectionGeneration));
  };
  private readonly onServerRequest = (
    request: CodexSharedRuntimeServerRequest,
  ): void => {
    this.enqueue(() => this.observeServerRequest(request));
  };
  private readonly onControlEvent = (
    event: CodexSharedRuntimeControlEvent,
  ): void => {
    if (event.method !== "serverRequest/resolved") return;
    // Activation awaits filesystem work. Clear an already-buffered request at
    // event receipt as well as in the serialized resolver so a resolved event
    // cannot sit behind lease acquisition while that buffer is replayed.
    this.discardResolvedBufferedRequests(event);
    this.enqueue(() => this.resolveFromAppServer(event));
  };

  constructor(
    private readonly broker: CodexActionBroker,
    private readonly control: CodexSharedRuntimeControl,
    private readonly codexSourceId: string,
    private readonly writerLease?: CodexActionBrokerWriterLease,
  ) {
    super();
    if (typeof this.writerLease?.on === "function") {
      this.writerLease.on("lost", this.onWriterLeaseLost);
    }
  }

  get health(): CodexActionBrokerRuntimeHealth {
    const degraded =
      this.brokerHealth?.degraded === true || this.unsupportedRequestObserved;
    const controlReady = this.control.ready;
    const generationReady = this.brokerGeneration !== undefined;
    const writerLeaseHeld = this.writerLease?.health.held ?? true;
    return {
      ready:
        !this.closed &&
        !this.draining &&
        controlReady &&
        writerLeaseHeld &&
        generationReady &&
        !degraded,
      controlReady,
      degraded,
      writerLeaseHeld,
      ...(this.brokerHealth?.degradedReason
        ? { degradedReason: this.brokerHealth.degradedReason }
        : this.unsupportedRequestObserved
          ? { degradedReason: "unsupported_server_request" as const }
          : this.closed || this.draining
            ? { degradedReason: "runtime_draining" as const }
            : !writerLeaseHeld && controlReady
              ? { degradedReason: "writer_lease_unavailable" as const }
              : !generationReady && controlReady
                ? { degradedReason: "generation_unavailable" as const }
                : {}),
      ...(generationReady
        ? {
            authorityGeneration: authorityGeneration(
              this.brokerGeneration!,
              this.leaseEpoch,
            ),
          }
        : {}),
    };
  }

  async start(): Promise<void> {
    if (this.started || this.closed) {
      throw new Error("Codex Action Broker runtime is already started");
    }
    this.started = true;
    this.control.on("ready", this.onReady);
    this.control.on("not_ready", this.onNotReady);
    this.control.on("server_request", this.onServerRequest);
    this.control.on("event", this.onControlEvent);
    // Standby Bridges may inspect the ledger, but only a lease holder may run
    // expiration or any other persistence mutation.
    this.brokerHealth = await this.broker.health();
    await this.reloadRecords(false, true);
    if (this.control.ready && !this.brokerHealth.degraded) {
      await this.activateGeneration(this.control.connectionGeneration);
    } else {
      this.emitHealth();
    }
  }

  async close(): Promise<void> {
    if (this.closed) return;
    this.beginDraining();
    this.closed = true;
    this.control.off("ready", this.onReady);
    this.control.off("not_ready", this.onNotReady);
    this.control.off("server_request", this.onServerRequest);
    this.control.off("event", this.onControlEvent);
    if (typeof this.writerLease?.off === "function") {
      this.writerLease.off("lost", this.onWriterLeaseLost);
    }
    this.clearLeaseRetry();
    await this.mutationTail;
    await Promise.allSettled([...this.inFlightResponses]);
    this.liveBindings.clear();
    this.payloadUnavailableReasons.clear();
    this.bufferedRequests.length = 0;
    await this.writerLease?.release();
  }

  /** Stop new mutations synchronously while existing claimed responses drain. */
  beginDraining(): void {
    if (this.closed || this.draining) return;
    this.draining = true;
    this.activationEpoch += 1;
    this.clearLeaseRetry();
    this.emitHealth();
  }

  subscribe(
    listener: (update: CodexActionBrokerRuntimeUpdate) => void,
  ): () => void {
    this.on("update", listener);
    return () => this.off("update", listener);
  }

  listRequests(
    options: {
      includeTerminal?: boolean;
      codexSourceId?: string;
      threadId?: string;
      /** Return only the newest matching records, still ordered oldest-first. */
      limit?: number;
    } = {},
  ): CodexActionBrokerRuntimeRequest[] {
    if (
      options.codexSourceId !== undefined &&
      options.codexSourceId !== this.codexSourceId
    ) {
      return [];
    }
    if (
      options.limit !== undefined &&
      (!Number.isSafeInteger(options.limit) || options.limit < 0)
    ) {
      throw new Error("Codex Action Broker request limit is invalid");
    }
    const matching = [...this.records.values()]
      .filter(
        (record) =>
          record.identity.codexSourceId === this.codexSourceId &&
          (!options.threadId ||
            record.identity.threadId === options.threadId) &&
          (options.includeTerminal === true ||
            record.state === "pending" ||
            record.state === "claimed"),
      )
      .sort((left, right) => left.updatedAt.localeCompare(right.updatedAt));
    const limited =
      options.limit === undefined
        ? matching
        : options.limit === 0
          ? []
          : matching.slice(-options.limit);
    return limited.map((record) => this.runtimeRequest(record));
  }

  currentRequestForThread(
    threadId: string,
    turnId?: string,
  ): CodexActionBrokerRuntimeRequest | undefined {
    return this.listRequests({ threadId })
      .filter(
        (request) =>
          (request.state === "pending" || request.state === "claimed") &&
          request.live &&
          (!turnId || request.turnId === turnId),
      )
      .at(-1);
  }

  async respond(
    input: CodexActionBrokerRespondInput,
  ): Promise<CodexActionBrokerRespondResult> {
    if (this.closed) return { outcome: "unavailable" };
    const flight = this.respondInternal(input);
    this.inFlightResponses.add(flight);
    try {
      return await flight;
    } finally {
      this.inFlightResponses.delete(flight);
    }
  }

  private async respondInternal(
    input: CodexActionBrokerRespondInput,
  ): Promise<CodexActionBrokerRespondResult> {
    await this.mutationTail;
    if (this.closed || !this.health.ready || !this.brokerGeneration) {
      return { outcome: "unavailable" };
    }
    const record = this.records.get(input.opaqueRequestId);
    if (!record || !matchesResponseIdentity(record, input)) {
      return { outcome: "invalid" };
    }
    const request = this.runtimeRequest(record);
    if (record.state === "resolved") {
      return { outcome: "alreadyResolved", request };
    }
    if (record.state === "expired") {
      return { outcome: "expired", request };
    }
    const expectedAuthorityGeneration = authorityGeneration(
      record.identity.generation,
      record.identity.generation === this.brokerGeneration
        ? this.leaseEpoch
        : undefined,
    );
    if (
      record.identity.generation !== this.brokerGeneration ||
      input.authorityGeneration !== expectedAuthorityGeneration
    ) {
      return { outcome: "staleGeneration", request };
    }
    const binding = this.liveBindings.get(input.opaqueRequestId);
    if (!binding || !binding.projection) {
      return { outcome: "unavailable", request };
    }

    let response: Record<string, unknown>;
    try {
      response = buildCodexServerActionResponse(
        binding.identity.requestId,
        binding.projection,
        input.action,
        input.answer,
      );
    } catch (error) {
      return {
        outcome: "invalid",
        request,
        error: error instanceof Error ? error.message : String(error),
      };
    }

    if (this.closed) return { outcome: "unavailable", request };
    if (!(await this.writerLeaseStillHeld()) || this.closed) {
      return { outcome: "unavailable", request };
    }

    const claimOperation = claimOperationId(input);
    let claim;
    try {
      claim = await this.broker.claim(binding.identity, {
        claimantId: input.claimantId,
        operationId: claimOperation,
      });
    } catch (error) {
      this.handleBrokerFailure(error);
      return { outcome: "unavailable", request };
    }
    if (claim.outcome === "contended") {
      await this.refreshRecord(input.opaqueRequestId);
      return {
        outcome: "contended",
        request: this.requestIfKnown(input.opaqueRequestId),
      };
    }
    if (claim.outcome === "resolved") {
      await this.refreshRecord(input.opaqueRequestId);
      return {
        outcome: "alreadyResolved",
        request: this.requestIfKnown(input.opaqueRequestId),
      };
    }
    if (claim.outcome === "expired") {
      await this.refreshRecord(input.opaqueRequestId);
      return {
        outcome: "expired",
        request: this.requestIfKnown(input.opaqueRequestId),
      };
    }
    if (claim.outcome === "stale_generation") {
      return { outcome: "staleGeneration", request };
    }
    if (claim.outcome === "missing") {
      return { outcome: "invalid", request };
    }
    if (claim.outcome !== "claimed" && claim.outcome !== "idempotent") {
      return { outcome: "invalid", request };
    }

    await this.refreshRecord(input.opaqueRequestId);
    this.emitRecord(input.opaqueRequestId);
    const claimedRecord = this.records.get(input.opaqueRequestId);
    if (claim.outcome === "idempotent" && claimedRecord?.claim?.submittedAt) {
      return {
        outcome: "submitted",
        request: this.requestIfKnown(input.opaqueRequestId),
      };
    }
    if (claim.outcome === "idempotent" && claimedRecord?.claim?.submittingAt) {
      return {
        outcome: "outcomeUnknown",
        request: this.requestIfKnown(input.opaqueRequestId),
      };
    }

    if (this.closed) {
      await this.releaseUnsubmittedClaim(
        binding.identity,
        claimOperation,
        claim.claimToken,
      );
      return {
        outcome: "unavailable",
        request: this.requestIfKnown(input.opaqueRequestId),
      };
    }

    const submitting = await this.broker.markSubmitting(binding.identity, {
      operationId: claimOperation,
      claimToken: claim.claimToken,
    });
    await this.refreshRecord(input.opaqueRequestId);
    this.emitRecord(input.opaqueRequestId);
    if (submitting.outcome === "idempotent") {
      // Only the mutation that changes the durable claim to `submitting` owns
      // the app-server write. A concurrent retry can observe the same claim
      // before the owner writes or persists `submittedAt`; treating that retry
      // as another writer would send two JSON-RPC responses for one request.
      const current = this.records.get(input.opaqueRequestId);
      return {
        outcome: current?.claim?.submittedAt ? "submitted" : "outcomeUnknown",
        request: this.requestIfKnown(input.opaqueRequestId),
      };
    }
    if (submitting.outcome !== "submitting") {
      return {
        outcome:
          submitting.outcome === "resolved"
            ? "alreadyResolved"
            : submitting.outcome === "expired"
              ? "expired"
              : submitting.outcome === "stale_generation"
                ? "staleGeneration"
                : "unavailable",
        request: this.requestIfKnown(input.opaqueRequestId),
      };
    }

    try {
      if (this.closed) {
        return {
          outcome: "outcomeUnknown",
          request: this.requestIfKnown(input.opaqueRequestId),
        };
      }
      const writerLeaseHeld = await this.writerLeaseStillHeld();
      if (!writerLeaseHeld || this.closed) {
        return {
          outcome: "outcomeUnknown",
          request: this.requestIfKnown(input.opaqueRequestId),
        };
      }
      if (
        !this.control.respondToServerRequest(binding.transportRequest, response)
      ) {
        await this.releaseUnsubmittedClaim(
          binding.identity,
          claimOperation,
          claim.claimToken,
        );
        await this.refreshRecord(input.opaqueRequestId);
        return {
          outcome: "unavailable",
          request: this.requestIfKnown(input.opaqueRequestId),
        };
      }
      // `write()` only proves that the response was submitted to the exact
      // control generation. Keep the durable request claimed until the
      // canonical app-server emits serverRequest/resolved. If the transport
      // drops after this point, a generation change expires the claim rather
      // than manufacturing a successful resolution.
      const submission = await this.broker.markSubmitted(binding.identity, {
        operationId: claimOperation,
        claimToken: claim.claimToken,
      });
      await this.refreshRecord(input.opaqueRequestId);
      this.emitRecord(input.opaqueRequestId);
      return {
        outcome:
          submission.outcome === "submitted" ||
          submission.outcome === "idempotent"
            ? "submitted"
            : submission.outcome === "resolved"
              ? "alreadyResolved"
              : submission.outcome === "expired"
                ? "expired"
                : submission.outcome === "stale_generation"
                  ? "staleGeneration"
                  : "outcomeUnknown",
        request: this.requestIfKnown(input.opaqueRequestId),
      };
    } catch (error) {
      this.handleBrokerFailure(error);
      await this.refreshRecord(input.opaqueRequestId).catch(() => undefined);
      return {
        outcome: "outcomeUnknown",
        request: this.requestIfKnown(input.opaqueRequestId),
      };
    }
  }

  async flush(): Promise<void> {
    await this.mutationTail;
  }

  private enqueue(operation: () => Promise<void>): void {
    this.mutationTail = this.mutationTail.then(operation).catch((error) => {
      this.handleBrokerFailure(error);
    });
  }

  private async activateGeneration(
    connectionGeneration: number,
  ): Promise<void> {
    if (this.closed || this.draining || !this.control.ready) return;
    if (connectionGeneration < this.controlGeneration) return;
    const epoch = ++this.activationEpoch;
    this.controlGeneration = connectionGeneration;
    this.brokerGeneration = undefined;
    this.unsupportedRequestObserved = false;
    this.liveBindings.clear();
    this.payloadUnavailableReasons.clear();
    this.emitHealth();
    if (this.brokerHealth?.degraded) return;

    try {
      if (this.writerLease) {
        const lease = await this.writerLease.acquire(
          this.control.daemonIdentity,
        );
        if (!lease.held || lease.leaseEpoch === undefined) {
          this.leaseEpoch = undefined;
          this.scheduleLeaseRetry(connectionGeneration);
          this.emitHealth();
          return;
        }
        this.leaseEpoch = lease.leaseEpoch;
      }
      this.brokerHealth = await this.broker.reloadFromDisk();
      if (this.brokerHealth.degraded) {
        this.emitHealth();
        return;
      }
      const terminalBufferedRequests = terminalBufferedRequestFences(
        await this.broker.listReadonly({
          codexSourceId: this.codexSourceId,
          includeTerminal: true,
        }),
      );
      const generation = await this.broker.beginSourceGeneration(
        this.codexSourceId,
      );
      if (
        this.closed ||
        this.draining ||
        epoch !== this.activationEpoch ||
        !this.control.ready ||
        this.control.connectionGeneration !== connectionGeneration
      ) {
        return;
      }
      this.brokerGeneration = generation.generation;
      this.clearLeaseRetry();
      this.brokerHealth = await this.broker.health();
      await this.reloadRecords(true);
      this.emitHealth();
      const buffered = this.bufferedRequests.splice(0);
      for (const request of buffered) {
        if (
          request.connectionGeneration === connectionGeneration &&
          !bufferedRequestAlreadyTerminal(request, terminalBufferedRequests)
        ) {
          await this.observeServerRequest(request);
        }
      }
    } catch (error) {
      this.handleBrokerFailure(error);
    }
  }

  private async markControlUnavailable(
    connectionGeneration: number,
  ): Promise<void> {
    if (connectionGeneration < this.controlGeneration) return;
    this.activationEpoch += 1;
    this.controlGeneration = connectionGeneration;
    this.brokerGeneration = undefined;
    const affected = [...this.liveBindings.keys()];
    this.liveBindings.clear();
    this.bufferedRequests.length = 0;
    this.clearLeaseRetry();
    for (const opaqueRequestId of affected) this.emitRecord(opaqueRequestId);
    this.emitHealth();
  }

  private async observeServerRequest(
    request: CodexSharedRuntimeServerRequest,
  ): Promise<void> {
    if (
      this.closed ||
      this.draining ||
      request.connectionGeneration !== this.control.connectionGeneration ||
      !this.control.ready
    ) {
      return;
    }
    if (!this.brokerGeneration) {
      if (this.bufferedRequests.length < MAX_BUFFERED_SERVER_REQUESTS) {
        this.bufferedRequests.push(cloneTransportRequest(request));
      }
      return;
    }
    if (!(await this.writerLeaseStillHeld())) {
      if (this.bufferedRequests.length < MAX_BUFFERED_SERVER_REQUESTS) {
        this.bufferedRequests.push(cloneTransportRequest(request));
      }
      this.scheduleLeaseRetry(request.connectionGeneration);
      return;
    }
    const supportedKind = actionRequestKindForMethod(request.method);
    if (!supportedKind) {
      this.unsupportedRequestObserved = true;
      console.warn(
        `[codex-action-broker] unsupported server request: ${request.method}`,
      );
      this.emitHealth();
      return;
    }
    if (!request.threadId || !request.turnId) {
      this.unsupportedRequestObserved = true;
      console.warn(
        `[codex-action-broker] ignored ${request.method} without exact thread/turn identity`,
      );
      this.emitHealth();
      return;
    }

    let projection: CodexServerActionProjection | null = null;
    let payloadUnavailableReason: "payload_too_large" | undefined;
    if (isCodexActionPayloadWithinLimits(request.params)) {
      projection = projectCodexServerActionRequest(
        request.requestId,
        request.method,
        request.params,
      );
      if (
        projection &&
        !isCodexActionPayloadWithinLimits({
          toolName: projection.toolName,
          input: projection.input,
          allowedActions: projection.allowedActions,
          responseShape: projection.responseShape,
        })
      ) {
        projection = null;
        payloadUnavailableReason = "payload_too_large";
      }
    } else {
      payloadUnavailableReason = "payload_too_large";
    }
    if (!projection && !payloadUnavailableReason) {
      this.unsupportedRequestObserved = true;
      console.warn(
        `[codex-action-broker] unsupported server request shape: ${request.method}`,
      );
      this.emitHealth();
      return;
    }
    const identity: CodexActionRequestIdentity = {
      codexSourceId: this.codexSourceId,
      threadId: request.threadId,
      turnId: request.turnId,
      requestId: request.requestId,
      generation: this.brokerGeneration,
    };
    const observed = await this.broker.observePending({
      identity,
      method: request.method,
      kind: projection?.kind ?? supportedKind,
      observedAt: request.observedAt,
    });
    if (observed.outcome === "stale_generation") return;
    const record = await this.broker.get(identity);
    if (!record) return;
    this.records.set(record.opaqueRequestId, record);
    if (payloadUnavailableReason) {
      this.liveBindings.delete(record.opaqueRequestId);
      this.payloadUnavailableReasons.set(
        record.opaqueRequestId,
        payloadUnavailableReason,
      );
    } else if (
      projection &&
      (record.state === "pending" || record.state === "claimed")
    ) {
      this.payloadUnavailableReasons.delete(record.opaqueRequestId);
      this.liveBindings.set(record.opaqueRequestId, {
        identity,
        transportRequest: cloneTransportRequest(request),
        projection,
      });
    }
    this.emitRecord(record.opaqueRequestId);
  }

  private async resolveFromAppServer(
    event: CodexSharedRuntimeControlEvent,
  ): Promise<void> {
    if (
      event.connectionGeneration !== this.controlGeneration ||
      event.requestId === undefined ||
      !event.threadId
    ) {
      return;
    }
    this.discardResolvedBufferedRequests(event);
    if (!this.brokerGeneration) return;
    const requestId = event.requestId;
    const candidates = [...this.records.values()].filter(
      (record) =>
        record.identity.codexSourceId === this.codexSourceId &&
        record.identity.threadId === event.threadId &&
        record.identity.generation === this.brokerGeneration &&
        requestIdsEqual(record.identity.requestId, requestId) &&
        (!event.turnId || record.identity.turnId === event.turnId) &&
        (record.state === "pending" || record.state === "claimed"),
    );
    if (candidates.length !== 1) return;
    const record = candidates[0];
    await this.broker.resolve(record.identity, {
      authority: "app_server",
      resolutionId: `control:${event.connectionGeneration}:${event.sequence}`,
      outcome: "resolved_elsewhere",
      resolvedAt: event.observedAt,
    });
    this.liveBindings.delete(record.opaqueRequestId);
    this.payloadUnavailableReasons.delete(record.opaqueRequestId);
    await this.refreshRecord(record.opaqueRequestId);
    this.emitRecord(record.opaqueRequestId);
  }

  private discardResolvedBufferedRequests(
    event: CodexSharedRuntimeControlEvent,
  ): void {
    if (event.requestId === undefined || !event.threadId) return;
    const requestId = event.requestId;
    const threadId = event.threadId;
    const matching = this.bufferedRequests.filter(
      (request) =>
        request.connectionGeneration === event.connectionGeneration &&
        requestIdsEqual(request.requestId, requestId) &&
        request.threadId === threadId &&
        (event.turnId === undefined || request.turnId === event.turnId),
    );
    if (matching.length === 0) return;

    // Older app-server builds can omit turnId from serverRequest/resolved. In
    // that shape, clear only when the buffered request set proves one exact
    // turn identity; never let a request-id collision clear another turn.
    const exactTurnId =
      event.turnId ??
      (() => {
        const turnIds = new Set(
          matching
            .map((request) => request.turnId)
            .filter((turnId): turnId is string => turnId !== undefined),
        );
        return turnIds.size === 1 ? turnIds.values().next().value : undefined;
      })();
    if (!exactTurnId) return;

    for (let index = this.bufferedRequests.length - 1; index >= 0; index -= 1) {
      const request = this.bufferedRequests[index];
      if (
        request.connectionGeneration === event.connectionGeneration &&
        requestIdsEqual(request.requestId, requestId) &&
        request.threadId === threadId &&
        request.turnId === exactTurnId
      ) {
        this.bufferedRequests.splice(index, 1);
      }
    }
  }

  private async reloadRecords(
    emitChanges = false,
    readOnly = false,
  ): Promise<void> {
    const previous = new Map(this.records);
    this.records.clear();
    const records = readOnly
      ? await this.broker.listReadonly({
          codexSourceId: this.codexSourceId,
          includeTerminal: true,
        })
      : await this.broker.list({
          codexSourceId: this.codexSourceId,
          includeTerminal: true,
        });
    for (const record of records) {
      this.records.set(record.opaqueRequestId, record);
    }
    if (!emitChanges) return;
    const keys = new Set([...previous.keys(), ...this.records.keys()]);
    for (const key of keys) {
      if (!sameRecord(previous.get(key), this.records.get(key))) {
        this.emitRecord(key);
      }
    }
  }

  private async refreshRecord(opaqueRequestId: string): Promise<void> {
    const existing = this.records.get(opaqueRequestId);
    if (!existing) return;
    const record = await this.broker.get(existing.identity);
    if (record) this.records.set(opaqueRequestId, record);
  }

  private runtimeRequest(
    record: CodexActionRequestRecord,
  ): CodexActionBrokerRuntimeRequest {
    const binding = this.liveBindings.get(record.opaqueRequestId);
    const projection = binding?.projection;
    return {
      opaqueRequestId: record.opaqueRequestId,
      codexSourceId: record.identity.codexSourceId,
      threadId: record.identity.threadId,
      turnId: record.identity.turnId,
      kind: record.kind,
      state: record.state,
      observedAt: record.observedAt,
      expiresAt: record.expiresAt,
      updatedAt: record.updatedAt,
      authorityGeneration: authorityGeneration(
        record.identity.generation,
        record.identity.generation === this.brokerGeneration
          ? this.leaseEpoch
          : undefined,
      ),
      live: binding !== undefined && projection !== null,
      ...(this.payloadUnavailableReasons.has(record.opaqueRequestId)
        ? { payloadUnavailableReason: "payload_too_large" as const }
        : {}),
      ...(projection
        ? {
            toolName: projection.toolName,
            input: structuredClone(projection.input),
            allowedActions: [...projection.allowedActions],
          }
        : {}),
    };
  }

  private requestIfKnown(
    opaqueRequestId: string,
  ): CodexActionBrokerRuntimeRequest | undefined {
    const record = this.records.get(opaqueRequestId);
    return record ? this.runtimeRequest(record) : undefined;
  }

  private emitRecord(opaqueRequestId: string): void {
    const request = this.requestIfKnown(opaqueRequestId);
    if (request) this.emit("update", { kind: "request", request });
  }

  private emitHealth(): void {
    this.emit("update", { kind: "health", health: this.health });
  }

  private handleBrokerFailure(error: unknown): void {
    if (error instanceof CodexActionBrokerDegradedError) {
      this.brokerHealth = {
        ready: true,
        degraded: true,
        degradedReason: error.reason,
        revision: this.brokerHealth?.revision ?? 0,
        pendingCount: this.brokerHealth?.pendingCount ?? 0,
        claimedCount: this.brokerHealth?.claimedCount ?? 0,
        resolvedCount: this.brokerHealth?.resolvedCount ?? 0,
        expiredCount: this.brokerHealth?.expiredCount ?? 0,
      };
    }
    console.warn(
      `[codex-action-broker] ${error instanceof Error ? error.message : String(error)}`,
    );
    this.emitHealth();
  }

  private async releaseUnsubmittedClaim(
    identity: CodexActionRequestIdentity,
    operationId: string,
    claimToken: string,
  ): Promise<void> {
    try {
      await this.broker.releaseUnsubmittedClaim(identity, {
        operationId,
        claimToken,
      });
    } catch (error) {
      this.handleBrokerFailure(error);
    }
  }

  private async writerLeaseStillHeld(): Promise<boolean> {
    if (!this.writerLease) return true;
    const held = await this.writerLease.assertHeld(this.control.daemonIdentity);
    if (!held) {
      const affected = [...this.liveBindings.keys()];
      this.liveBindings.clear();
      this.brokerGeneration = undefined;
      this.leaseEpoch = undefined;
      for (const opaqueRequestId of affected) this.emitRecord(opaqueRequestId);
      if (this.control.ready) {
        this.scheduleLeaseRetry(this.control.connectionGeneration);
      }
      this.emitHealth();
    }
    return held;
  }

  private scheduleLeaseRetry(connectionGeneration: number): void {
    if (
      this.closed ||
      this.draining ||
      !this.control.ready ||
      this.leaseRetryTimer !== undefined
    ) {
      return;
    }
    this.leaseRetryTimer = setTimeout(() => {
      this.leaseRetryTimer = undefined;
      if (
        this.closed ||
        this.draining ||
        !this.control.ready ||
        this.control.connectionGeneration !== connectionGeneration
      ) {
        return;
      }
      this.enqueue(() => this.activateGeneration(connectionGeneration));
    }, WRITER_LEASE_RETRY_MS);
    this.leaseRetryTimer.unref?.();
  }

  private clearLeaseRetry(): void {
    if (!this.leaseRetryTimer) return;
    clearTimeout(this.leaseRetryTimer);
    this.leaseRetryTimer = undefined;
  }
}

function authorityGeneration(generation: number, leaseEpoch?: number): string {
  return leaseEpoch === undefined
    ? `cab:${generation}`
    : `cab:${leaseEpoch}:${generation}`;
}

function actionRequestKindForMethod(
  method: string,
): CodexActionRequestKind | null {
  switch (method) {
    case "item/commandExecution/requestApproval":
      return "command_approval";
    case "item/fileChange/requestApproval":
      return "file_approval";
    case "item/permissions/requestApproval":
      return "permissions_approval";
    case "item/tool/requestUserInput":
      return "user_input";
    case "mcpServer/elicitation/request":
      return "mcp_elicitation";
    default:
      return null;
  }
}

function matchesResponseIdentity(
  record: CodexActionRequestRecord,
  input: CodexActionBrokerRespondInput,
): boolean {
  return (
    record.opaqueRequestId === input.opaqueRequestId &&
    record.identity.codexSourceId === input.codexSourceId &&
    record.identity.threadId === input.threadId &&
    record.identity.turnId === input.turnId
  );
}

function claimOperationId(input: CodexActionBrokerRespondInput): string {
  return createHash("sha256")
    .update(input.operationId)
    .update("\0")
    .update(input.action)
    .update("\0")
    .update(input.answer ?? "")
    .digest("hex");
}

function requestIdsEqual(
  left: number | string,
  right: number | string,
): boolean {
  return typeof left === typeof right && left === right;
}

function terminalBufferedRequestFences(
  records: readonly CodexActionRequestRecord[],
): ReadonlyMap<string, string> {
  const terminal = new Map<string, string>();
  for (const record of records) {
    if (record.state !== "resolved" && record.state !== "expired") continue;
    const key = bufferedRequestFenceKey({
      requestId: record.identity.requestId,
      threadId: record.identity.threadId,
      turnId: record.identity.turnId,
      method: record.method,
    });
    const previous = terminal.get(key);
    if (previous === undefined || record.updatedAt > previous) {
      terminal.set(key, record.updatedAt);
    }
  }
  return terminal;
}

function bufferedRequestAlreadyTerminal(
  request: CodexSharedRuntimeServerRequest,
  terminal: ReadonlyMap<string, string>,
): boolean {
  if (!request.threadId || !request.turnId) return false;
  const terminalAt = terminal.get(
    bufferedRequestFenceKey({
      requestId: request.requestId,
      threadId: request.threadId,
      turnId: request.turnId,
      method: request.method,
    }),
  );
  if (terminalAt === undefined) return false;
  const observedAtMs = Date.parse(request.observedAt);
  const terminalAtMs = Date.parse(terminalAt);
  return (
    Number.isFinite(observedAtMs) &&
    Number.isFinite(terminalAtMs) &&
    observedAtMs <= terminalAtMs
  );
}

function bufferedRequestFenceKey(input: {
  requestId: number | string;
  threadId: string;
  turnId: string;
  method: string;
}): string {
  return JSON.stringify([
    typeof input.requestId,
    input.requestId,
    input.threadId,
    input.turnId,
    input.method,
  ]);
}

function cloneTransportRequest(
  request: CodexSharedRuntimeServerRequest,
): CodexSharedRuntimeServerRequest {
  return {
    ...request,
    params: structuredClone(request.params),
  };
}

function sameRecord(
  left: CodexActionRequestRecord | undefined,
  right: CodexActionRequestRecord | undefined,
): boolean {
  return JSON.stringify(left) === JSON.stringify(right);
}
