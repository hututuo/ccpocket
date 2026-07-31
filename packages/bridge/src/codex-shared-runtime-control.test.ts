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
  cliVersion: "0.146.0-alpha.9.2",
  appServerVersion: "0.146.0-alpha.9.2",
  socketDevice: 17,
  socketInode: 29,
};

class FakeControlTransport extends CodexTransport {
  writes: Array<Record<string, unknown>> = [];
  stopCalls = 0;
  private running = false;
  private generation = 0;

  get isRunning(): boolean {
    return this.running;
  }

  get connectionGeneration(): number {
    return this.generation;
  }

  start(_projectPath: string): void {
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
}

function createControl(
  transport: FakeControlTransport,
  options: {
    env?: NodeJS.ProcessEnv;
    eventCapacity?: number;
    identity?: CodexSharedRuntimeSafeDaemonIdentity;
  } = {},
): CodexSharedRuntimeControl {
  return new CodexSharedRuntimeControl({
    projectPath: "/tmp/control-observer",
    env: options.env ?? baseEnv,
    eventCapacity: options.eventCapacity,
    now: () => new Date("2026-08-01T00:00:00.000Z"),
    transportFactory: () => transport,
    daemonIdentityProvider: () => options.identity ?? safeIdentity,
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
  transport.receive({ id: request.id, result: {} });
  expect(transport.writes[1]).toEqual({
    method: "initialized",
    params: {},
  });
}

describe("CodexSharedRuntimeControl", () => {
  it("freezes pilot gates and becomes ready only after initialize", async () => {
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

  it("never answers server requests, including allowed observation methods", () => {
    const transport = new FakeControlTransport();
    const control = createControl(transport);
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

    expect(transport.writes).toEqual([]);
    expect(control.events).toEqual([]);
    control.stop();
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

  it("becomes not-ready on disconnect and stop only closes its transport", async () => {
    const transport = new FakeControlTransport();
    const control = createControl(transport);
    const notReady = vi.fn();
    control.on("not_ready", notReady);
    initialize(control, transport);

    transport.disconnect();
    expect(control.ready).toBe(false);
    expect(notReady).toHaveBeenCalledWith(1);
    expect(transport.stopCalls).toBe(0);
    await expect(control.waitUntilReady(1_000)).rejects.toThrow(
      "transport exited",
    );

    control.stop();
    expect(transport.stopCalls).toBe(1);
    expect(control.connectionGeneration).toBe(2);
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
