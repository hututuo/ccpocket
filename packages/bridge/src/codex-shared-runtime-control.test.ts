import { describe, expect, it, vi } from "vitest";
import { CodexTransport } from "./codex-transport.js";
import {
  CodexSharedRuntimeControl,
  recordSharedRuntimeAttachmentLifecycle,
  type CodexSharedRuntimeSafeDaemonIdentity,
} from "./codex-shared-runtime-control.js";

const baseEnv: NodeJS.ProcessEnv = {
  BRIDGE_CODEX_APP_SERVER_MODE: "daemon",
  BRIDGE_CODEX_SHARED_PILOT: "1",
  BRIDGE_CODEX_SOURCE_ID: "source-control-test",
  BRIDGE_CODEX_SHARED_PILOT_ALLOW_THREAD_START: "0",
  BRIDGE_CODEX_SHARED_PILOT_ALLOW_TURN_START: "0",
};

const safeIdentity: CodexSharedRuntimeSafeDaemonIdentity = {
  expectedVersion: "0.146.0-alpha.9.2",
  expectedAppServerVersion: "0.146.0",
  cliVersion: "0.146.0-alpha.9.2",
  appServerVersion: "0.146.0",
  socketDevice: 17,
  socketInode: 29,
};

class FakeControlTransport extends CodexTransport {
  writes: Array<Record<string, unknown>> = [];
  stopCalls = 0;
  private running = false;
  private generation = 0;

  constructor(private readonly startFailure?: Error) {
    super();
  }

  get isRunning(): boolean {
    return this.running;
  }

  get connectionGeneration(): number {
    return this.generation;
  }

  start(_projectPath: string): void {
    if (this.startFailure) throw this.startFailure;
    this.running = true;
    this.generation += 1;
  }

  write(envelope: Record<string, unknown>): void {
    if (!this.running) throw new Error("fake transport is stopped");
    this.writes.push(envelope);
  }

  stop(): void {
    this.stopCalls += 1;
    this.running = false;
    this.generation += 1;
  }

  receive(envelope: Record<string, unknown>): void {
    this.emit("data", `${JSON.stringify(envelope)}\n`);
  }

  disconnect(): void {
    this.running = false;
    this.emit("exit", 1);
  }

  fail(): void {
    this.running = false;
    this.emit("error", new Error("fake transport failure"));
  }
}

function createControl(
  transport: FakeControlTransport,
  options: {
    env?: NodeJS.ProcessEnv;
    eventCapacity?: number;
    identity?: CodexSharedRuntimeSafeDaemonIdentity;
    transportFactory?: () => CodexTransport;
    reconnectBaseDelayMs?: number;
    reconnectMaxDelayMs?: number;
    random?: () => number;
  } = {},
): CodexSharedRuntimeControl {
  return new CodexSharedRuntimeControl({
    projectPath: "/tmp/control-observer",
    env: options.env ?? baseEnv,
    eventCapacity: options.eventCapacity,
    now: () => new Date("2026-08-01T00:00:00.000Z"),
    transportFactory: options.transportFactory ?? (() => transport),
    daemonIdentityProvider: () => options.identity ?? safeIdentity,
    reconnectBaseDelayMs: options.reconnectBaseDelayMs,
    reconnectMaxDelayMs: options.reconnectMaxDelayMs,
    random: options.random,
  });
}

function acknowledgeInitialize(
  transport: FakeControlTransport,
  config: Record<string, unknown> = {},
): void {
  const request = transport.writes.findLast(
    (entry) => entry.method === "initialize",
  );
  expect(request).toBeDefined();
  transport.receive({ id: request!.id, result: {} });
  expect(transport.writes.at(-2)).toEqual({
    method: "initialized",
    params: {},
  });
  const configRead = transport.writes.at(-1);
  expect(configRead).toMatchObject({
    method: "config/read",
    params: { includeLayers: false },
  });
  transport.receive({
    id: configRead!.id,
    result: { config, origins: {}, layers: null },
  });
}

function initialize(
  control: CodexSharedRuntimeControl,
  transport: FakeControlTransport,
): void {
  control.start();
  const request = transport.writes[0];
  expect(request).toMatchObject({
    method: "initialize",
    params: {
      clientInfo: { name: "ccpocket_bridge_control_observer" },
    },
  });
  acknowledgeInitialize(transport);
}

describe("CodexSharedRuntimeControl", () => {
  it("freezes pilot gates and becomes ready only after initialize and effective-config preflight", async () => {
    const env = { ...baseEnv };
    const transport = new FakeControlTransport();
    const control = createControl(transport, { env });
    const ready = vi.fn();
    control.on("ready", ready);

    env.BRIDGE_CODEX_SHARED_PILOT_ALLOW_THREAD_START = "1";
    expect(Object.isFrozen(control.pilotGates)).toBe(true);
    expect(control.pilotGates).toMatchObject({
      allowThreadStart: false,
      allowTurnStart: false,
      codexSourceId: "source-control-test",
    });
    expect(control.ready).toBe(false);
    const readiness = control.waitUntilReady(1_000);

    initialize(control, transport);
    await readiness;

    expect(control.ready).toBe(true);
    expect(control.connectionGeneration).toBe(1);
    expect(ready).toHaveBeenCalledWith(1);
    expect(control.daemonIdentity).toEqual(safeIdentity);

    control.stop();
  });

  it("observes server requests only in memory and answers only on the exact connection generation", () => {
    const transport = new FakeControlTransport();
    const control = createControl(transport);
    const requests: unknown[] = [];
    control.on("server_request", (request) => requests.push(request));
    initialize(control, transport);
    transport.writes = [];

    transport.receive({
      id: "approval-1",
      method: "item/commandExecution/requestApproval",
      params: {
        threadId: "thread-1",
        turnId: "turn-1",
        command: "cat /private/secret",
      },
    });
    transport.receive({
      id: "request-shaped-status",
      method: "thread/status/changed",
      params: {
        threadId: "thread-1",
        status: { type: "active", activeFlags: [] },
      },
    });
    transport.receive({
      id: "time-shared",
      method: "currentTime/read",
      params: { threadId: "thread-1" },
    });

    expect(transport.writes).toEqual([]);
    expect(control.events).toEqual([]);
    expect(requests).toEqual([
      expect.objectContaining({
        requestId: "approval-1",
        method: "item/commandExecution/requestApproval",
        threadId: "thread-1",
        turnId: "turn-1",
        connectionGeneration: 1,
        params: expect.objectContaining({
          command: "cat /private/secret",
        }),
      }),
      expect.objectContaining({
        requestId: "request-shaped-status",
        method: "thread/status/changed",
      }),
      expect.objectContaining({
        requestId: "time-shared",
        method: "currentTime/read",
        threadId: "thread-1",
      }),
    ]);
    expect(
      control.respondToServerRequest(
        {
          requestId: "approval-1",
          connectionGeneration: control.connectionGeneration + 1,
        },
        { decision: "accept" },
      ),
    ).toBe(false);
    expect(
      control.respondToServerRequest(
        requests[0] as {
          requestId: string;
          connectionGeneration: number;
        },
        { decision: "accept" },
      ),
    ).toBe(true);
    expect(transport.writes).toEqual([
      { id: "approval-1", result: { decision: "accept" } },
    ]);
    control.stop();
  });

  it("fails closed before readiness when effective config uses an external current-time source", async () => {
    const transport = new FakeControlTransport();
    const control = createControl(transport);
    const diagnostics: string[] = [];
    control.on("diagnostic", (diagnostic) => diagnostics.push(diagnostic));
    const readiness = control.waitUntilReady(1_000);

    control.start();
    const initializeRequest = transport.writes.find(
      (entry) => entry.method === "initialize",
    );
    transport.receive({ id: initializeRequest!.id, result: {} });
    const configRead = transport.writes.find(
      (entry) => entry.method === "config/read",
    );
    expect(control.ready).toBe(false);
    transport.receive({
      id: configRead!.id,
      result: {
        config: {
          features: {
            current_time_reminder: {
              enabled: true,
              clock_source: "external",
            },
          },
        },
        origins: {},
        layers: null,
      },
    });

    await expect(readiness).rejects.toThrow(
      "incompatible with external current-time reminders",
    );
    expect(control.ready).toBe(false);
    expect(transport.stopCalls).toBe(1);
    expect(diagnostics).toEqual(["incompatible_config"]);
  });

  it("keeps only a bounded ring of sanitized lifecycle events", () => {
    const transport = new FakeControlTransport();
    const control = createControl(transport, { eventCapacity: 3 });
    initialize(control, transport);

    transport.receive({
      method: "thread/started",
      params: {
        thread: {
          id: "thread-safe",
          name: "sensitive title",
          cwd: "/private/sensitive/path",
          preview: "sensitive prompt",
          status: {
            type: "active",
            activeFlags: ["waitingOnApproval", "unsupported"],
          },
        },
      },
    });
    expect(control.events[0]).toMatchObject({
      method: "thread/started",
      threadId: "thread-safe",
      threadStatus: {
        type: "active",
        activeFlags: ["waitingOnApproval"],
      },
    });

    transport.receive({
      method: "thread/name/updated",
      params: { threadId: "thread-safe", name: "another sensitive title" },
    });
    transport.receive({
      method: "item/agentMessage/delta",
      params: { threadId: "thread-safe", delta: "sensitive output" },
    });
    transport.receive({
      method: "turn/started",
      params: {
        threadId: "thread-safe",
        turn: {
          id: "turn-safe",
          status: "inProgress",
          items: [{ text: "sensitive turn body" }],
        },
      },
    });
    transport.receive({
      method: "serverRequest/resolved",
      params: {
        threadId: "thread-safe",
        requestId: "request-safe",
        result: "sensitive result",
      },
    });

    expect(control.events.map((event) => event.method)).toEqual([
      "thread/name/updated",
      "turn/started",
      "serverRequest/resolved",
    ]);
    expect(control.events[1]).toMatchObject({
      threadId: "thread-safe",
      turnId: "turn-safe",
      turnStatus: "inProgress",
    });
    expect(control.events[2]).toMatchObject({
      requestId: "request-safe",
    });
    const serialized = JSON.stringify(control.events);
    for (const secret of [
      "sensitive title",
      "/private/sensitive/path",
      "sensitive prompt",
      "sensitive output",
      "sensitive turn body",
      "sensitive result",
    ]) {
      expect(serialized).not.toContain(secret);
    }
    control.stop();
  });

  it("publishes content-free durable settings invalidations", () => {
    const transport = new FakeControlTransport();
    const control = createControl(transport);
    initialize(control, transport);

    transport.receive({
      method: "thread/settings/updated",
      params: {
        threadId: "thread-provider-settings",
        model: "sensitive-model-selection",
        cwd: "/private/sensitive/path",
      },
    });
    control.recordThreadSettingsUpdated("thread-bridge-settings");

    expect(control.events).toEqual([
      expect.objectContaining({
        method: "thread/settings/updated",
        threadId: "thread-provider-settings",
      }),
      expect.objectContaining({
        method: "thread/settings/updated",
        threadId: "thread-bridge-settings",
      }),
    ]);
    const serialized = JSON.stringify(control.events);
    expect(serialized).not.toContain("sensitive-model-selection");
    expect(serialized).not.toContain("/private/sensitive/path");
    control.stop();
  });

  it("accepts sanitized turn lifecycle from the owning attachment without issuing an RPC", () => {
    const transport = new FakeControlTransport();
    const control = createControl(transport);
    initialize(control, transport);
    transport.writes = [];

    recordSharedRuntimeAttachmentLifecycle("turn/started", {
      threadId: "thread-owned",
      turn: {
        id: "turn-owned",
        status: "inProgress",
        items: [{ text: "must never enter diagnostics" }],
      },
    });

    expect(transport.writes).toEqual([]);
    expect(control.events).toEqual([
      expect.objectContaining({
        method: "turn/started",
        threadId: "thread-owned",
        turnId: "turn-owned",
        turnStatus: "inProgress",
      }),
    ]);
    expect(JSON.stringify(control.events)).not.toContain(
      "must never enter diagnostics",
    );

    control.stop();
    recordSharedRuntimeAttachmentLifecycle("turn/completed", {
      threadId: "thread-owned",
      turn: { id: "turn-owned", status: "completed" },
    });
    expect(control.events).toHaveLength(1);
  });

  it("reconnects an established observer and fences late events from the old transport", async () => {
    vi.useFakeTimers();
    try {
      const first = new FakeControlTransport();
      const second = new FakeControlTransport();
      const transports = [first, second];
      const transportFactory = vi.fn(() => {
        const transport = transports.shift();
        if (!transport) throw new Error("unexpected transport allocation");
        return transport;
      });
      const control = createControl(first, {
        transportFactory,
        reconnectBaseDelayMs: 100,
        reconnectMaxDelayMs: 400,
        random: () => 1,
      });
      const ready = vi.fn();
      const notReady = vi.fn();
      control.on("ready", ready);
      control.on("not_ready", notReady);
      initialize(control, first);

      first.disconnect();
      expect(control.ready).toBe(false);
      expect(notReady).toHaveBeenCalledWith(1);
      expect(first.stopCalls).toBe(1);
      const recovered = control.waitUntilReady(1_000);

      await vi.advanceTimersByTimeAsync(99);
      expect(transportFactory).toHaveBeenCalledTimes(1);
      await vi.advanceTimersByTimeAsync(1);
      expect(transportFactory).toHaveBeenCalledTimes(2);
      expect(second.writes[0]).toMatchObject({ method: "initialize" });

      // The first transport may still deliver buffered data/exit after stop.
      // Neither may mutate readiness or the current-generation event ring.
      first.receive({
        method: "thread/status/changed",
        params: { threadId: "stale-thread", status: { type: "active" } },
      });
      first.fail();
      first.disconnect();
      expect(notReady).toHaveBeenCalledTimes(1);
      expect(control.events).toEqual([]);

      acknowledgeInitialize(second);
      await recovered;
      expect(control.ready).toBe(true);
      expect(control.connectionGeneration).toBe(2);
      expect(ready.mock.calls.map(([generation]) => generation)).toEqual([
        1, 2,
      ]);

      second.receive({
        method: "thread/status/changed",
        params: { threadId: "current-thread", status: { type: "active" } },
      });
      expect(control.events).toEqual([
        expect.objectContaining({
          connectionGeneration: 2,
          threadId: "current-thread",
        }),
      ]);

      control.stop();
      expect(first.stopCalls).toBe(1);
      expect(second.stopCalls).toBe(1);
      expect(vi.getTimerCount()).toBe(0);
    } finally {
      vi.useRealTimers();
    }
  });

  it("backs off failed recovery attempts exponentially with a hard cap", async () => {
    vi.useFakeTimers();
    try {
      const first = new FakeControlTransport();
      const startFailure = new FakeControlTransport(
        new Error("reconnect start failed"),
      );
      const initializeRejected = new FakeControlTransport();
      const recovered = new FakeControlTransport();
      const transports = [first, startFailure, initializeRejected, recovered];
      const transportFactory = vi.fn(() => {
        const transport = transports.shift();
        if (!transport) throw new Error("unexpected transport allocation");
        return transport;
      });
      const control = createControl(first, {
        transportFactory,
        reconnectBaseDelayMs: 100,
        reconnectMaxDelayMs: 250,
        random: () => 1,
      });
      initialize(control, first);
      first.fail();
      expect(first.stopCalls).toBe(1);

      await vi.advanceTimersByTimeAsync(100);
      expect(transportFactory).toHaveBeenCalledTimes(2);
      expect(startFailure.stopCalls).toBe(1);

      await vi.advanceTimersByTimeAsync(199);
      expect(transportFactory).toHaveBeenCalledTimes(2);
      await vi.advanceTimersByTimeAsync(1);
      expect(transportFactory).toHaveBeenCalledTimes(3);
      const rejectedRequest = initializeRejected.writes[0];
      initializeRejected.receive({
        id: rejectedRequest?.id,
        error: { code: -32000 },
      });
      expect(initializeRejected.stopCalls).toBe(1);

      await vi.advanceTimersByTimeAsync(249);
      expect(transportFactory).toHaveBeenCalledTimes(3);
      await vi.advanceTimersByTimeAsync(1);
      expect(transportFactory).toHaveBeenCalledTimes(4);
      acknowledgeInitialize(recovered);
      expect(control.ready).toBe(true);
      expect(control.connectionGeneration).toBe(4);

      control.stop();
      expect(recovered.stopCalls).toBe(1);
      expect(vi.getTimerCount()).toBe(0);
    } finally {
      vi.useRealTimers();
    }
  });

  it("cancels a pending reconnect on stop without allocating another transport", async () => {
    vi.useFakeTimers();
    try {
      const transport = new FakeControlTransport();
      const transportFactory = vi.fn(() => transport);
      const control = createControl(transport, {
        transportFactory,
        reconnectBaseDelayMs: 100,
        reconnectMaxDelayMs: 400,
        random: () => 1,
      });
      initialize(control, transport);
      transport.disconnect();
      const readiness = control.waitUntilReady(1_000);

      control.stop();
      await expect(readiness).rejects.toThrow("control stopped");
      await vi.advanceTimersByTimeAsync(10_000);
      expect(transportFactory).toHaveBeenCalledTimes(1);
      expect(transport.stopCalls).toBe(1);
      expect(vi.getTimerCount()).toBe(0);
    } finally {
      vi.useRealTimers();
    }
  });

  it("fails fast before first readiness and does not start a reconnect loop", async () => {
    vi.useFakeTimers();
    try {
      const transport = new FakeControlTransport();
      const transportFactory = vi.fn(() => transport);
      const control = createControl(transport, {
        transportFactory,
        reconnectBaseDelayMs: 100,
        reconnectMaxDelayMs: 400,
        random: () => 1,
      });
      const readiness = control.waitUntilReady(1_000);
      control.start();
      transport.disconnect();

      await expect(readiness).rejects.toThrow("transport exited");
      await vi.advanceTimersByTimeAsync(10_000);
      expect(transportFactory).toHaveBeenCalledTimes(1);
      expect(transport.stopCalls).toBe(1);
      expect(vi.getTimerCount()).toBe(0);
      control.stop();
    } finally {
      vi.useRealTimers();
    }
  });

  it("fails fast when the first initialize request is rejected", async () => {
    vi.useFakeTimers();
    try {
      const transport = new FakeControlTransport();
      const transportFactory = vi.fn(() => transport);
      const control = createControl(transport, {
        transportFactory,
        reconnectBaseDelayMs: 100,
        reconnectMaxDelayMs: 400,
        random: () => 1,
      });
      const readiness = control.waitUntilReady(1_000);
      control.start();
      transport.receive({
        id: transport.writes[0]?.id,
        error: { code: -32000 },
      });

      await expect(readiness).rejects.toThrow("initialize was rejected");
      await vi.advanceTimersByTimeAsync(10_000);
      expect(transportFactory).toHaveBeenCalledTimes(1);
      expect(transport.stopCalls).toBe(1);
      expect(vi.getTimerCount()).toBe(0);
      control.stop();
    } finally {
      vi.useRealTimers();
    }
  });

  it("fails closed on a mismatched daemon identity", () => {
    const transport = new FakeControlTransport();
    const control = createControl(transport, {
      identity: { ...safeIdentity, appServerVersion: "different" },
    });

    expect(() => control.start()).toThrow("daemon version mismatch");
    expect(transport.writes).toEqual([]);
    expect(transport.stopCalls).toBe(0);
  });
});
