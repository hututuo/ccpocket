import { describe, expect, it, vi } from "vitest";
import type {
  CodexActionBrokerRuntime,
  CodexActionBrokerRuntimeUpdate,
} from "../codex-action-broker-runtime.js";
import { CodexActionBrokerFeatureHandler } from "./codex-action-broker.js";
import { parseLocalFeatureClientMessage } from "./protocol.js";
import type {
  LocalFeatureHandleContext,
  LocalFeatureRuntime,
} from "./runtime.js";

describe("Codex Action Broker local feature", () => {
  it("parses only exact, bounded action messages", () => {
    expect(
      parseLocalFeatureClientMessage({
        type: "get_codex_actions",
        requestId: "wire-legacy",
      }),
    ).toEqual({ type: "get_codex_actions", requestId: "wire-legacy" });
    expect(
      parseLocalFeatureClientMessage({
        type: "get_codex_actions",
        requestId: "wire-scoped",
        codexSourceId: "source-a",
        threadId: "thread-a",
      }),
    ).toEqual({
      type: "get_codex_actions",
      requestId: "wire-scoped",
      codexSourceId: "source-a",
      threadId: "thread-a",
    });
    expect(
      parseLocalFeatureClientMessage({
        type: "get_codex_actions",
        requestId: "wire-partial-scope",
        threadId: "thread-a",
      }),
    ).toBeNull();
    expect(
      parseLocalFeatureClientMessage({
        type: "respond_codex_action",
        requestId: "wire-1",
        opaqueRequestId: "opaque-1",
        codexSourceId: "source-a",
        threadId: "thread-a",
        turnId: "turn-a",
        authorityGeneration: "cab:1:2",
        claimantId: "phone-a",
        operationId: "operation-a",
        action: "approve",
      }),
    ).toMatchObject({ type: "respond_codex_action", action: "approve" });
    expect(
      parseLocalFeatureClientMessage({
        type: "respond_codex_action",
        requestId: "wire-1",
        opaqueRequestId: "opaque-1",
        codexSourceId: "source-a",
        threadId: "thread-a",
        turnId: "turn-a",
        authorityGeneration: "cab:1:2",
        claimantId: "phone-a",
        operationId: "operation-a",
        action: "approve_always",
        answer: "must-not-be-present",
      }),
    ).toBeNull();
    expect(
      parseLocalFeatureClientMessage({
        type: "get_codex_actions",
        requestId: "wire-2",
        unexpected: true,
      }),
    ).toBeNull();
  });

  it("sends opt-in snapshots, routes responses, and withholds live payload in notification-only mode", async () => {
    const updates: Array<(update: CodexActionBrokerRuntimeUpdate) => void> = [];
    const request = {
      opaqueRequestId: "opaque-1",
      codexSourceId: "source-a",
      threadId: "thread-a",
      turnId: "turn-a",
      kind: "command_approval" as const,
      state: "pending" as const,
      observedAt: "2026-08-01T00:00:00.000Z",
      expiresAt: "2026-08-02T00:00:00.000Z",
      updatedAt: "2026-08-01T00:00:00.000Z",
      authorityGeneration: "cab:1:2",
      live: true,
      toolName: "Bash",
      input: { command: "pwd" },
      allowedActions: ["approve", "reject"] as const,
    };
    const actionRuntime = {
      health: {
        ready: true,
        controlReady: true,
        degraded: false,
        writerLeaseHeld: true,
        authorityGeneration: "cab:1:2",
      },
      listRequests: vi.fn(() => [request]),
      respond: vi.fn(async () => ({ outcome: "submitted", request })),
      subscribe: vi.fn((listener) => {
        updates.push(listener);
        return () => {
          const index = updates.indexOf(listener);
          if (index >= 0) updates.splice(index, 1);
        };
      }),
    } as unknown as CodexActionBrokerRuntime;
    const sent = new Map<object, unknown[]>();
    const supported = new Set<object>();
    const notificationOnly = new Set<object>();
    const runtime = {
      codexActionBroker: actionRuntime,
      getSession: () => undefined,
      getCodexThreadId: () => undefined,
      getActiveCodexProcess: () => null,
      createStandaloneCodexProcess: vi.fn(),
      hasCodexQueuedInput: () => false,
      send: (client: object, message: unknown) => {
        const messages = sent.get(client) ?? [];
        messages.push(message);
        sent.set(client, messages);
      },
      supports: (client: object) => supported.has(client),
      getClientDeliveryMode: (client: object) =>
        notificationOnly.has(client) ? "notifications_only" : "interactive",
      isClientOpen: () => true,
    } as unknown as LocalFeatureRuntime;
    const handler = new CodexActionBrokerFeatureHandler(runtime);
    const interactive = {};
    const background = {};
    supported.add(interactive);
    supported.add(background);
    notificationOnly.add(background);

    handler.capabilitiesChanged(interactive);
    handler.capabilitiesChanged(background);
    expect(sent.get(interactive)?.[0]).toMatchObject({
      type: "codex_action_broker_v1",
      event: "snapshot",
      health: { writerLeaseHeld: true },
      requests: [{ opaqueRequestId: "opaque-1", live: false }],
    });
    expect(sent.get(interactive)?.[0]).not.toHaveProperty("requests.0.input");

    sent.set(interactive, []);
    updates[0]({
      kind: "request",
      request: {
        ...request,
        opaqueRequestId: "opaque-legacy-other-thread",
        threadId: "thread-foreign",
        input: { command: "private-other-thread-command" },
      },
    });
    expect(sent.get(interactive)?.[0]).toMatchObject({
      event: "request",
      request: {
        opaqueRequestId: "opaque-legacy-other-thread",
        live: false,
      },
    });
    expect(sent.get(interactive)?.[0]).not.toHaveProperty("request.input");

    sent.set(interactive, []);
    const scopedSnapshotRequest = parseLocalFeatureClientMessage({
      type: "get_codex_actions",
      requestId: "wire-scoped-snapshot",
      codexSourceId: "source-a",
      threadId: "thread-a",
    })!;
    await handler.handle(scopedSnapshotRequest, {
      client: interactive,
      signal: new AbortController().signal,
      runtime,
    } as LocalFeatureHandleContext);
    expect(sent.get(interactive)?.[0]).toMatchObject({
      type: "codex_action_broker_v1",
      event: "snapshot",
      requestId: "wire-scoped-snapshot",
      scope: { codexSourceId: "source-a", threadId: "thread-a" },
      requests: [{ opaqueRequestId: "opaque-1", input: { command: "pwd" } }],
    });
    expect(actionRuntime.listRequests).toHaveBeenLastCalledWith({
      codexSourceId: "source-a",
      threadId: "thread-a",
      limit: 9,
    });

    sent.set(interactive, []);
    sent.set(background, []);
    updates[0]({
      kind: "request",
      request: {
        ...request,
        opaqueRequestId: "opaque-foreign",
        threadId: "thread-foreign",
        input: { command: "private-other-thread-command" },
      },
    });
    expect(sent.get(interactive)).toEqual([]);
    updates[0]({ kind: "request", request });
    expect(sent.get(interactive)).toHaveLength(1);
    expect(sent.get(background)).toEqual([]);

    sent.set(interactive, []);
    updates[0]({
      kind: "request",
      request: {
        ...request,
        input: { commandActions: [{ detail: "x".repeat(64 * 1024) }] },
      },
    });
    const oversizedWire = sent.get(interactive)?.[0] as Record<string, unknown>;
    expect(oversizedWire).toMatchObject({
      event: "request",
      request: {
        opaqueRequestId: "opaque-1",
        live: false,
        payloadUnavailableReason: "payload_too_large",
      },
    });
    expect(oversizedWire).not.toHaveProperty("request.input");
    expect(oversizedWire).not.toHaveProperty("request.allowedActions");
    expect(
      Buffer.byteLength(JSON.stringify(oversizedWire), "utf8"),
    ).toBeLessThan(4 * 1024);

    const parsed = parseLocalFeatureClientMessage({
      type: "respond_codex_action",
      requestId: "wire-response",
      opaqueRequestId: "opaque-1",
      codexSourceId: "source-a",
      threadId: "thread-a",
      turnId: "turn-a",
      authorityGeneration: "cab:1:2",
      claimantId: "phone-a",
      operationId: "operation-a",
      action: "approve",
    })!;
    await handler.handle(parsed, {
      client: interactive,
      signal: new AbortController().signal,
      runtime,
    } as LocalFeatureHandleContext);
    expect(actionRuntime.respond).toHaveBeenCalledWith(
      expect.objectContaining({ operationId: "operation-a" }),
    );
    expect(sent.get(interactive)).toContainEqual(
      expect.objectContaining({
        event: "response",
        requestId: "wire-response",
        outcome: "submitted",
      }),
    );
    handler.close();
  });

  it("bounds legacy and scoped snapshots by count and encoded frame bytes", async () => {
    const largeInput = {
      chunks: [
        "a".repeat(15 * 1024),
        "b".repeat(15 * 1024),
        "c".repeat(15 * 1024),
      ],
    };
    const requests = Array.from({ length: 40 }, (_, index) => ({
      opaqueRequestId: `opaque-${index}`,
      codexSourceId: "source-a",
      threadId: "thread-a",
      turnId: `turn-${index}`,
      kind: "command_approval" as const,
      state: "pending" as const,
      observedAt: `2026-08-01T00:00:${String(index).padStart(2, "0")}.000Z`,
      expiresAt: "2026-08-02T00:00:00.000Z",
      updatedAt: `2026-08-01T00:00:${String(index).padStart(2, "0")}.000Z`,
      authorityGeneration: "cab:1:2",
      live: true,
      toolName: "Bash",
      input: largeInput,
      allowedActions: ["approve", "reject"] as const,
    }));
    requests.push({
      ...requests[0],
      opaqueRequestId: "opaque-other-thread",
      threadId: "thread-other",
      turnId: "turn-other",
      input: { chunks: ["OTHER_THREAD_SECRET"] },
    });
    const listRequests = vi.fn(
      (
        options: {
          codexSourceId?: string;
          threadId?: string;
          limit?: number;
        } = {},
      ) => {
        const matching = requests.filter(
          (request) =>
            (!options.codexSourceId ||
              request.codexSourceId === options.codexSourceId) &&
            (!options.threadId || request.threadId === options.threadId),
        );
        return options.limit === undefined
          ? matching
          : matching.slice(-options.limit);
      },
    );
    const actionRuntime = {
      health: {
        ready: true,
        controlReady: true,
        degraded: false,
        writerLeaseHeld: true,
        authorityGeneration: "cab:1:2",
      },
      listRequests,
      respond: vi.fn(),
      subscribe: vi.fn(() => () => undefined),
    } as unknown as CodexActionBrokerRuntime;
    const sent: unknown[] = [];
    const client = {};
    const runtime = {
      codexActionBroker: actionRuntime,
      send: (_client: object, message: unknown) => sent.push(message),
      supports: () => true,
      isClientOpen: () => true,
      getClientDeliveryMode: () => "interactive",
    } as unknown as LocalFeatureRuntime;
    const handler = new CodexActionBrokerFeatureHandler(runtime);

    handler.capabilitiesChanged(client);
    const legacy = sent.at(-1) as {
      requests: Array<Record<string, unknown>>;
      truncated?: boolean;
    };
    expect(legacy.requests).toHaveLength(16);
    expect(legacy.truncated).toBe(true);
    expect(legacy.requests.every((request) => request.live === false)).toBe(
      true,
    );
    expect(JSON.stringify(legacy)).not.toContain("OTHER_THREAD_SECRET");
    expect(
      Buffer.byteLength(JSON.stringify(legacy), "utf8"),
    ).toBeLessThanOrEqual(64 * 1024);

    sent.length = 0;
    await handler.handle(
      {
        type: "get_codex_actions",
        requestId: "wire-large-scoped",
        codexSourceId: "source-a",
        threadId: "thread-a",
      },
      {
        client,
        signal: new AbortController().signal,
        runtime,
      } as LocalFeatureHandleContext,
    );
    const scoped = sent.at(-1) as {
      requests: Array<Record<string, unknown>>;
      scope?: Record<string, unknown>;
      truncated?: boolean;
    };
    expect(scoped.scope).toEqual({
      codexSourceId: "source-a",
      threadId: "thread-a",
    });
    expect(scoped.requests.length).toBeGreaterThan(0);
    expect(scoped.requests.length).toBeLessThanOrEqual(8);
    expect(
      scoped.requests.every((request) => request.threadId === "thread-a"),
    ).toBe(true);
    expect(scoped.requests.some((request) => request.live === true)).toBe(true);
    expect(scoped.truncated).toBe(true);
    expect(JSON.stringify(scoped)).not.toContain("OTHER_THREAD_SECRET");
    expect(
      Buffer.byteLength(JSON.stringify(scoped), "utf8"),
    ).toBeLessThanOrEqual(64 * 1024);
    handler.close();
  });

  it("reports an unsupported topology without exposing actions", () => {
    const sent: unknown[] = [];
    const client = {};
    const runtime = {
      getSession: () => undefined,
      getCodexThreadId: () => undefined,
      getActiveCodexProcess: () => null,
      createStandaloneCodexProcess: vi.fn(),
      hasCodexQueuedInput: () => false,
      send: (_client: object, message: unknown) => sent.push(message),
      supports: () => true,
    } as unknown as LocalFeatureRuntime;
    const handler = new CodexActionBrokerFeatureHandler(runtime);
    handler.capabilitiesChanged(client);
    expect(sent).toEqual([
      expect.objectContaining({
        event: "snapshot",
        health: expect.objectContaining({
          ready: false,
          writerLeaseHeld: false,
          degradedReason: "unsupported_topology",
        }),
        requests: [],
      }),
    ]);
    handler.close();
  });
});
