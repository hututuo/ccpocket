import type {
  CodexActionBrokerRuntimeHealth,
  CodexActionBrokerRuntimeRequest,
  CodexActionBrokerRuntimeUpdate,
} from "../codex-action-broker-runtime.js";
import { isCodexActionPayloadWithinLimits } from "../codex-action-payload-limits.js";
import type {
  LocalFeatureHandleContext,
  LocalFeatureHandler,
  LocalFeatureRuntime,
} from "./runtime.js";
import {
  CODEX_ACTION_BROKER_CAPABILITY,
  type CodexActionBrokerClientMessage,
  type CodexActionBrokerServerMessage,
  type CodexActionBrokerSnapshotScope,
  type CodexActionWireHealth,
  type CodexActionWireRequest,
} from "./slots/codex-action-broker-protocol.js";

const CODEX_ACTION_SNAPSHOT_MAX_BYTES = 64 * 1024;
const CODEX_ACTION_SCOPED_SNAPSHOT_MAX_REQUESTS = 8;
const CODEX_ACTION_LEGACY_SNAPSHOT_MAX_REQUESTS = 16;

type CodexActionSnapshotMessage = Extract<
  CodexActionBrokerServerMessage,
  { event: "snapshot" }
>;

export class CodexActionBrokerFeatureHandler implements LocalFeatureHandler {
  readonly messageTypes = [
    "get_codex_actions",
    "respond_codex_action",
  ] as const;
  private readonly clients = new Map<
    object,
    CodexActionBrokerSnapshotScope | null
  >();
  private readonly unsubscribe?: () => void;

  constructor(private readonly runtime: LocalFeatureRuntime) {
    this.unsubscribe = runtime.codexActionBroker?.subscribe((update) =>
      this.handleRuntimeUpdate(update),
    );
  }

  async handle(
    message: CodexActionBrokerClientMessage,
    context: LocalFeatureHandleContext,
  ): Promise<void> {
    if (
      !this.runtime.supports(context.client, CODEX_ACTION_BROKER_CAPABILITY)
    ) {
      return;
    }
    if (!this.clients.has(context.client)) {
      this.clients.set(context.client, null);
    }
    if (message.type === "get_codex_actions") {
      const scope = snapshotScope(message);
      this.clients.set(context.client, scope);
      this.sendSnapshot(context.client, message.requestId, scope);
      return;
    }
    const broker = this.runtime.codexActionBroker;
    if (!broker) {
      this.runtime.send(context.client, {
        type: CODEX_ACTION_BROKER_CAPABILITY,
        event: "response",
        requestId: message.requestId,
        opaqueRequestId: message.opaqueRequestId,
        outcome: "unavailable",
      });
      return;
    }
    const result = await broker.respond(message);
    this.runtime.send(context.client, {
      type: CODEX_ACTION_BROKER_CAPABILITY,
      event: "response",
      requestId: message.requestId,
      opaqueRequestId: message.opaqueRequestId,
      outcome: result.outcome,
      ...(result.request ? { request: wireRequest(result.request) } : {}),
      ...(result.error ? { error: result.error } : {}),
    });
  }

  capabilitiesChanged(client: object): void {
    if (!this.runtime.supports(client, CODEX_ACTION_BROKER_CAPABILITY)) {
      this.clients.delete(client);
      return;
    }
    const scope = this.clients.get(client) ?? null;
    this.clients.set(client, scope);
    this.sendSnapshot(client, undefined, scope);
  }

  disconnect(client: object): void {
    this.clients.delete(client);
  }

  close(): void {
    this.unsubscribe?.();
    this.clients.clear();
  }

  private sendSnapshot(
    client: object,
    requestId?: string,
    scope: CodexActionBrokerSnapshotScope | null = null,
  ): void {
    const broker = this.runtime.codexActionBroker;
    const health: CodexActionWireHealth = broker
      ? wireHealth(broker.health)
      : {
          ready: false,
          controlReady: false,
          degraded: false,
          writerLeaseHeld: false,
          degradedReason: "unsupported_topology",
        };
    const requestLimit = scope
      ? CODEX_ACTION_SCOPED_SNAPSHOT_MAX_REQUESTS
      : CODEX_ACTION_LEGACY_SNAPSHOT_MAX_REQUESTS;
    const candidates =
      broker?.health.ready === true
        ? broker.listRequests({
            ...(scope
              ? {
                  codexSourceId: scope.codexSourceId,
                  threadId: scope.threadId,
                }
              : {}),
            // One extra record proves count truncation while bounding live
            // payload cloning before the local-feature projection runs.
            limit: requestLimit + 1,
          })
        : [];
    let truncated = candidates.length > requestLimit;
    const requests: CodexActionWireRequest[] = [];
    const newestCandidates = candidates.slice(-requestLimit).reverse();
    for (const candidate of newestCandidates) {
      const projected = scope
        ? wireRequest(candidate)
        : wireRequestWithoutLivePayload(candidate);
      const probe = snapshotMessage({
        requestId,
        health,
        requests: [projected, ...requests],
        scope,
        // Always reserve the truncation marker while enforcing the byte cap.
        truncated: true,
      });
      if (jsonBytes(probe) > CODEX_ACTION_SNAPSHOT_MAX_BYTES) {
        truncated = true;
        continue;
      }
      requests.unshift(projected);
    }
    let message = snapshotMessage({
      requestId,
      health,
      requests,
      scope,
      truncated,
    });
    if (jsonBytes(message) > CODEX_ACTION_SNAPSHOT_MAX_BYTES) {
      // The fixed envelope is tiny, but keep the budget fail-closed if future
      // additive health/scope fields grow unexpectedly.
      message = snapshotMessage({
        requestId,
        health,
        requests: [],
        scope,
        truncated: true,
      });
    }
    this.runtime.send(client, message);
  }

  private handleRuntimeUpdate(update: CodexActionBrokerRuntimeUpdate): void {
    for (const [client, scope] of this.clients) {
      if (
        this.runtime.isClientOpen?.(client) === false ||
        this.runtime.getClientDeliveryMode?.(client) === "notifications_only"
      ) {
        continue;
      }
      if (update.kind === "health") {
        this.runtime.send(client, {
          type: CODEX_ACTION_BROKER_CAPABILITY,
          event: "health",
          health: wireHealth(update.health),
        });
      } else {
        if (scope && !requestMatchesScope(update.request, scope)) continue;
        this.runtime.send(client, {
          type: CODEX_ACTION_BROKER_CAPABILITY,
          event: "request",
          request: scope
            ? wireRequest(update.request)
            : wireRequestWithoutLivePayload(update.request),
        });
      }
    }
  }
}

function wireRequest(
  request: CodexActionBrokerRuntimeRequest,
): CodexActionWireRequest {
  const { input, allowedActions, toolName, ...identityAndState } = request;
  if (!request.live) return identityAndState;
  if (
    !input ||
    !isCodexActionPayloadWithinLimits({
      toolName,
      input,
      allowedActions,
    })
  ) {
    return {
      ...identityAndState,
      live: false,
      payloadUnavailableReason: "payload_too_large",
    };
  }
  return {
    ...identityAndState,
    ...(toolName ? { toolName } : {}),
    ...(input ? { input: structuredClone(input) } : {}),
    ...(allowedActions ? { allowedActions: [...allowedActions] } : {}),
  };
}

function wireRequestWithoutLivePayload(
  request: CodexActionBrokerRuntimeRequest,
): CodexActionWireRequest {
  const {
    input: _input,
    allowedActions: _allowedActions,
    toolName: _toolName,
    ...safe
  } = request;
  return { ...safe, live: false };
}

function snapshotScope(
  message: Extract<
    CodexActionBrokerClientMessage,
    { type: "get_codex_actions" }
  >,
): CodexActionBrokerSnapshotScope | null {
  return message.codexSourceId && message.threadId
    ? {
        codexSourceId: message.codexSourceId,
        threadId: message.threadId,
      }
    : null;
}

function requestMatchesScope(
  request: CodexActionBrokerRuntimeRequest,
  scope: CodexActionBrokerSnapshotScope,
): boolean {
  return (
    request.codexSourceId === scope.codexSourceId &&
    request.threadId === scope.threadId
  );
}

function snapshotMessage(input: {
  requestId?: string;
  health: CodexActionWireHealth;
  requests: CodexActionWireRequest[];
  scope: CodexActionBrokerSnapshotScope | null;
  truncated: boolean;
}): CodexActionSnapshotMessage {
  return {
    type: CODEX_ACTION_BROKER_CAPABILITY,
    event: "snapshot",
    ...(input.requestId ? { requestId: input.requestId } : {}),
    health: input.health,
    requests: input.requests,
    ...(input.scope ? { scope: { ...input.scope } } : {}),
    ...(input.truncated ? { truncated: true } : {}),
  };
}

function jsonBytes(value: unknown): number {
  return Buffer.byteLength(JSON.stringify(value), "utf8");
}

function wireHealth(
  health: CodexActionBrokerRuntimeHealth,
): CodexActionWireHealth {
  return { ...health };
}
