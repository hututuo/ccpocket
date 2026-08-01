import { EventEmitter } from "node:events";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { CodexActionBroker } from "./codex-action-broker.js";
import { CodexActionBrokerWriterLease } from "./codex-action-broker-writer-lease.js";
import {
  CodexActionBrokerRuntime,
  type CodexActionBrokerRespondInput,
} from "./codex-action-broker-runtime.js";
import type {
  CodexSharedRuntimeControl,
  CodexSharedRuntimeControlEvent,
  CodexSharedRuntimeSafeDaemonIdentity,
  CodexSharedRuntimeServerRequest,
} from "./codex-shared-runtime-control.js";

const roots: string[] = [];
const NOW = "2026-08-01T00:00:00.000Z";

class FakeSharedControl extends EventEmitter {
  ready = false;
  connectionGeneration = 0;
  acceptResponses = true;
  readonly responses: Array<{
    request: Pick<
      CodexSharedRuntimeServerRequest,
      "requestId" | "connectionGeneration"
    >;
    result: Record<string, unknown>;
  }> = [];
  daemonIdentity: CodexSharedRuntimeSafeDaemonIdentity = {
    expectedVersion: "1.0.0",
    cliVersion: "1.0.0",
    appServerVersion: "1.0.0",
    socketDevice: 17,
    socketInode: 29,
  };

  becomeReady(): void {
    this.connectionGeneration += 1;
    this.ready = true;
    this.emit("ready", this.connectionGeneration);
  }

  becomeUnavailable(): void {
    this.ready = false;
    this.emit("not_ready", this.connectionGeneration);
  }

  request(
    request: Omit<
      CodexSharedRuntimeServerRequest,
      "connectionGeneration" | "observedAt"
    >,
  ): void {
    this.emit("server_request", {
      ...request,
      observedAt: NOW,
      connectionGeneration: this.connectionGeneration,
    } satisfies CodexSharedRuntimeServerRequest);
  }

  resolved(
    event: Omit<
      CodexSharedRuntimeControlEvent,
      "sequence" | "observedAt" | "connectionGeneration" | "method"
    >,
  ): void {
    this.emit("event", {
      ...event,
      method: "serverRequest/resolved",
      sequence: 100 + this.responses.length,
      observedAt: NOW,
      connectionGeneration: this.connectionGeneration,
    } satisfies CodexSharedRuntimeControlEvent);
  }

  respondToServerRequest(
    request: Pick<
      CodexSharedRuntimeServerRequest,
      "requestId" | "connectionGeneration"
    >,
    result: Record<string, unknown>,
  ): boolean {
    if (
      !this.acceptResponses ||
      !this.ready ||
      request.connectionGeneration !== this.connectionGeneration
    ) {
      return false;
    }
    this.responses.push({ request, result });
    return true;
  }
}

afterEach(async () => {
  await Promise.all(
    roots.splice(0).map((root) => rm(root, { recursive: true, force: true })),
  );
});

async function fixture(filePath?: string) {
  const root = filePath
    ? undefined
    : await mkdtemp(join(tmpdir(), "cab-runtime-"));
  if (root) roots.push(root);
  const broker = new CodexActionBroker({
    filePath: filePath ?? join(root!, "broker.json"),
    now: () => new Date(NOW),
    randomToken: () => "claim-token",
  });
  const control = new FakeSharedControl();
  const runtime = new CodexActionBrokerRuntime(
    broker,
    control as unknown as CodexSharedRuntimeControl,
    "source-a",
  );
  await runtime.start();
  control.becomeReady();
  await runtime.flush();
  return { broker, control, runtime };
}

function commandRequest(requestId: number | string = "request-a") {
  return {
    requestId,
    method: "item/commandExecution/requestApproval",
    threadId: "thread-a",
    turnId: "turn-a",
    params: {
      threadId: "thread-a",
      turnId: "turn-a",
      itemId: "item-a",
      command: "cat /private/top-secret.txt",
      cwd: "/private/top-secret",
    },
  } as const;
}

function respondInput(
  request: ReturnType<CodexActionBrokerRuntime["listRequests"]>[number],
  overrides: Partial<CodexActionBrokerRespondInput> = {},
): CodexActionBrokerRespondInput {
  return {
    opaqueRequestId: request.opaqueRequestId,
    codexSourceId: request.codexSourceId,
    threadId: request.threadId,
    turnId: request.turnId,
    authorityGeneration: request.authorityGeneration,
    claimantId: "mobile-a",
    operationId: "operation-a",
    action: "approve",
    ...overrides,
  };
}

describe("CodexActionBrokerRuntime", () => {
  it("persists only composite identity while serving a live first-responder request", async () => {
    const { broker, control, runtime } = await fixture();
    control.request(commandRequest());
    await runtime.flush();

    const [request] = runtime.listRequests();
    expect(request).toMatchObject({
      codexSourceId: "source-a",
      threadId: "thread-a",
      turnId: "turn-a",
      kind: "command_approval",
      state: "pending",
      live: true,
      toolName: "Bash",
      allowedActions: ["approve", "approve_always", "reject"],
      input: { command: "cat /private/top-secret.txt" },
    });

    const serialized = await readFile(broker.filePath, "utf8");
    expect(serialized).not.toContain("top-secret");
    expect(serialized).not.toContain("item-a");

    await expect(runtime.respond(respondInput(request))).resolves.toMatchObject(
      {
        outcome: "submitted",
        request: { state: "claimed", live: true },
      },
    );
    expect(control.responses).toHaveLength(1);
    expect(control.responses[0]).toMatchObject({
      request: { requestId: "request-a", connectionGeneration: 1 },
      result: { decision: "accept" },
    });
    await expect(runtime.respond(respondInput(request))).resolves.toMatchObject(
      {
        outcome: "submitted",
        request: { state: "claimed" },
      },
    );
    expect(control.responses).toHaveLength(1);
    await expect(
      runtime.respond(
        respondInput(request, {
          claimantId: "mobile-b",
          operationId: "operation-b",
        }),
      ),
    ).resolves.toMatchObject({ outcome: "contended" });

    control.resolved({
      threadId: "thread-a",
      turnId: "turn-a",
      requestId: "request-a",
    });
    await runtime.flush();
    await expect(
      runtime.respond(
        respondInput(request, {
          claimantId: "mobile-b",
          operationId: "operation-b",
        }),
      ),
    ).resolves.toMatchObject({ outcome: "alreadyResolved" });

    await runtime.close();
  });

  it("serializes two phones and rejects foreign source, turn, and generation fences", async () => {
    const { control, runtime } = await fixture();
    control.request(commandRequest(7));
    await runtime.flush();
    const [request] = runtime.listRequests();

    await expect(
      runtime.respond(respondInput(request, { codexSourceId: "source-b" })),
    ).resolves.toMatchObject({ outcome: "invalid" });
    await expect(
      runtime.respond(respondInput(request, { turnId: "turn-foreign" })),
    ).resolves.toMatchObject({ outcome: "invalid" });
    await expect(
      runtime.respond(
        respondInput(request, { authorityGeneration: "cab:999" }),
      ),
    ).resolves.toMatchObject({ outcome: "staleGeneration" });
    expect(control.responses).toEqual([]);

    control.acceptResponses = false;
    await expect(runtime.respond(respondInput(request))).resolves.toMatchObject(
      {
        outcome: "unavailable",
        request: { state: "pending" },
      },
    );
    await expect(
      runtime.respond(
        respondInput(request, {
          claimantId: "mobile-b",
          operationId: "operation-b",
        }),
      ),
    ).resolves.toMatchObject({
      outcome: "unavailable",
      request: { state: "pending" },
    });
    control.acceptResponses = true;
    await expect(runtime.respond(respondInput(request))).resolves.toMatchObject(
      {
        outcome: "submitted",
        request: { state: "claimed" },
      },
    );
    expect(control.responses).toHaveLength(1);

    await runtime.close();
  });

  it("lets only one truly concurrent retry write the app-server response", async () => {
    const { broker, control, runtime } = await fixture();
    control.request(commandRequest("request-concurrent"));
    await runtime.flush();
    const request = runtime.currentRequestForThread("thread-a")!;
    const originalMarkSubmitting = broker.markSubmitting.bind(broker);
    let entered = 0;
    let releaseBarrier!: () => void;
    const barrier = new Promise<void>((resolve) => {
      releaseBarrier = resolve;
    });
    vi.spyOn(broker, "markSubmitting").mockImplementation(
      async (identity, input) => {
        entered += 1;
        await barrier;
        return originalMarkSubmitting(identity, input);
      },
    );

    const first = runtime.respond(
      respondInput(request, { operationId: "operation-concurrent" }),
    );
    const retry = runtime.respond(
      respondInput(request, { operationId: "operation-concurrent" }),
    );
    try {
      await vi.waitFor(() => expect(entered).toBe(2));
    } finally {
      releaseBarrier();
    }
    const outcomes = (await Promise.all([first, retry]))
      .map((result) => result.outcome)
      .sort();

    expect(outcomes).toEqual(["outcomeUnknown", "submitted"]);
    expect(control.responses).toHaveLength(1);
    expect(control.responses[0]).toMatchObject({
      request: { requestId: "request-concurrent", connectionGeneration: 1 },
      result: { decision: "accept" },
    });
    await runtime.close();
  });

  it("bounds newest request projections before cloning live payloads", async () => {
    const { control, runtime } = await fixture();
    for (let index = 0; index < 4; index += 1) {
      control.request({
        ...commandRequest(`request-${index}`),
        threadId: `thread-${index}`,
        turnId: `turn-${index}`,
        params: {
          threadId: `thread-${index}`,
          turnId: `turn-${index}`,
          itemId: `item-${index}`,
          command: `command-${index}`,
        },
      });
    }
    await runtime.flush();

    expect(
      runtime.listRequests({ limit: 2 }).map((entry) => entry.threadId),
    ).toEqual(["thread-2", "thread-3"]);
    expect(
      runtime.listRequests({
        codexSourceId: "source-a",
        threadId: "thread-1",
        limit: 1,
      }),
    ).toHaveLength(1);
    expect(
      runtime.listRequests({ codexSourceId: "source-foreign", limit: 1 }),
    ).toEqual([]);
    expect(() => runtime.listRequests({ limit: -1 })).toThrow(
      "request limit is invalid",
    );
    await runtime.close();
  });

  it("maps authoritative app-server resolution to alreadyResolved without a turn id", async () => {
    const { control, runtime } = await fixture();
    control.request(commandRequest());
    await runtime.flush();
    const [request] = runtime.listRequests();

    control.resolved({
      threadId: "thread-a",
      requestId: "request-a",
    });
    await runtime.flush();
    expect(runtime.listRequests()).toEqual([]);
    await expect(runtime.respond(respondInput(request))).resolves.toMatchObject(
      {
        outcome: "alreadyResolved",
        request: { state: "resolved" },
      },
    );

    await runtime.close();
  });

  it("does not resend after transport write when submitted persistence is uncertain", async () => {
    const { broker, control, runtime } = await fixture();
    control.request(commandRequest("request-uncertain"));
    await runtime.flush();
    const request = runtime.currentRequestForThread("thread-a")!;
    vi.spyOn(broker, "markSubmitted").mockRejectedValueOnce(
      new Error("simulated fsync failure after write"),
    );

    await expect(
      runtime.respond(
        respondInput(request, { operationId: "operation-uncertain" }),
      ),
    ).resolves.toMatchObject({
      outcome: "outcomeUnknown",
      request: { state: "claimed" },
    });
    expect(control.responses).toHaveLength(1);
    await expect(
      runtime.respond(
        respondInput(request, { operationId: "operation-uncertain" }),
      ),
    ).resolves.toMatchObject({ outcome: "outcomeUnknown" });
    expect(control.responses).toHaveLength(1);
    await runtime.close();
  });

  it("expires the old generation on restart and accepts only the replayed request", async () => {
    const first = await fixture();
    first.control.request(commandRequest());
    await first.runtime.flush();
    const [oldRequest] = first.runtime.listRequests();
    const filePath = first.broker.filePath;
    await first.runtime.close();

    const second = await fixture(filePath);
    expect(
      second.runtime.listRequests({ includeTerminal: true }),
    ).toContainEqual(
      expect.objectContaining({
        opaqueRequestId: oldRequest.opaqueRequestId,
        state: "expired",
        live: false,
      }),
    );
    second.control.request(commandRequest());
    await second.runtime.flush();
    const current = second.runtime
      .listRequests()
      .find((request) => request.state === "pending")!;
    expect(current.opaqueRequestId).not.toBe(oldRequest.opaqueRequestId);
    await expect(
      second.runtime.respond(respondInput(oldRequest)),
    ).resolves.toMatchObject({ outcome: "expired" });
    await expect(
      second.runtime.respond(respondInput(current)),
    ).resolves.toMatchObject({ outcome: "submitted" });

    await second.runtime.close();
  });

  it("projects questions and MCP forms and builds their exact response shapes", async () => {
    const { control, runtime } = await fixture();
    control.request({
      requestId: "question-a",
      method: "item/tool/requestUserInput",
      threadId: "thread-question",
      turnId: "turn-question",
      params: {
        threadId: "thread-question",
        turnId: "turn-question",
        itemId: "item-question",
        questions: [
          { id: "database", header: "DB", question: "Which database?" },
        ],
      },
    });
    control.request({
      requestId: "form-a",
      method: "mcpServer/elicitation/request",
      threadId: "thread-form",
      turnId: "turn-form",
      params: {
        threadId: "thread-form",
        turnId: "turn-form",
        serverName: "Example MCP",
        message: "Provide configuration",
        mode: "form",
        requestedSchema: {
          type: "object",
          properties: {
            region: { type: "string", title: "Region" },
          },
          required: ["region"],
        },
      },
    });
    await runtime.flush();

    const question = runtime.currentRequestForThread("thread-question")!;
    await expect(
      runtime.respond(
        respondInput(question, {
          operationId: "answer-question",
          action: "answer",
          answer: "SQLite",
        }),
      ),
    ).resolves.toMatchObject({ outcome: "submitted" });
    const form = runtime.currentRequestForThread("thread-form")!;
    await expect(
      runtime.respond(
        respondInput(form, {
          operationId: "answer-form",
          action: "answer",
          answer: JSON.stringify({ answers: { region: "ap-southeast" } }),
        }),
      ),
    ).resolves.toMatchObject({ outcome: "submitted" });

    expect(control.responses).toContainEqual(
      expect.objectContaining({
        request: expect.objectContaining({
          requestId: "question-a",
          connectionGeneration: 1,
        }),
        result: { answers: { database: { answers: ["SQLite"] } } },
      }),
    );
    expect(control.responses).toContainEqual(
      expect.objectContaining({
        request: expect.objectContaining({
          requestId: "form-a",
          connectionGeneration: 1,
        }),
        result: {
          action: "accept",
          content: { region: "ap-southeast" },
          _meta: null,
        },
      }),
    );

    await runtime.close();
  });

  it("turns an oversized approval into a non-operable safe record without blocking later actions", async () => {
    const { control, runtime } = await fixture();
    control.request({
      ...commandRequest("request-oversized"),
      threadId: "thread-oversized",
      turnId: "turn-oversized",
      params: {
        threadId: "thread-oversized",
        turnId: "turn-oversized",
        itemId: "item-oversized",
        command: "safe-command",
        commandActions: [{ detail: "x".repeat(64 * 1024) }],
      },
    });
    await runtime.flush();

    const oversized = runtime
      .listRequests()
      .find((request) => request.threadId === "thread-oversized")!;
    expect(oversized).toMatchObject({
      kind: "command_approval",
      state: "pending",
      live: false,
      payloadUnavailableReason: "payload_too_large",
    });
    expect(oversized).not.toHaveProperty("input");
    expect(oversized).not.toHaveProperty("allowedActions");
    await expect(
      runtime.respond(respondInput(oversized)),
    ).resolves.toMatchObject({
      outcome: "unavailable",
    });
    expect(control.responses).toEqual([]);
    expect(runtime.health).toMatchObject({ ready: true, degraded: false });

    control.request({
      ...commandRequest("request-after-oversized"),
      threadId: "thread-normal",
      turnId: "turn-normal",
      params: {
        threadId: "thread-normal",
        turnId: "turn-normal",
        itemId: "item-normal",
        command: "pwd",
      },
    });
    await runtime.flush();
    const normal = runtime.currentRequestForThread("thread-normal")!;
    await expect(runtime.respond(respondInput(normal))).resolves.toMatchObject({
      outcome: "submitted",
    });
    expect(control.responses).toHaveLength(1);
    await runtime.close();
  });

  it("degrades on an unsupported or external-current-time server request without replying", async () => {
    const { control, runtime } = await fixture();
    control.request({
      requestId: "future-request",
      method: "future/request",
      threadId: "thread-future",
      turnId: "turn-future",
      params: { threadId: "thread-future", turnId: "turn-future" },
    });
    await runtime.flush();
    expect(runtime.listRequests()).toEqual([]);
    expect(control.responses).toEqual([]);
    expect(runtime.health).toMatchObject({
      ready: false,
      degraded: true,
      degradedReason: "unsupported_server_request",
    });
    await runtime.close();

    const currentTimeFixture = await fixture();
    currentTimeFixture.control.request({
      requestId: "time-request",
      method: "currentTime/read",
      threadId: "thread-time",
      params: { threadId: "thread-time" },
    });
    await currentTimeFixture.runtime.flush();
    expect(currentTimeFixture.control.responses).toEqual([]);
    expect(currentTimeFixture.runtime.health).toMatchObject({
      ready: false,
      degradedReason: "unsupported_server_request",
    });
    await currentTimeFixture.runtime.close();
  });

  it("keeps an overlapping Bridge read-only and reloads the ledger on handoff", async () => {
    const root = await mkdtemp(join(tmpdir(), "cab-runtime-overlap-"));
    roots.push(root);
    const ledgerPath = join(root, "broker.json");
    const leaseRoot = join(root, "lease");
    const alive = new Map([
      [101, true],
      [202, true],
    ]);
    const firstControl = new FakeSharedControl();
    const first = new CodexActionBrokerRuntime(
      new CodexActionBroker({ filePath: ledgerPath }),
      firstControl as unknown as CodexSharedRuntimeControl,
      "source-a",
      new CodexActionBrokerWriterLease("source-a", {
        rootDir: leaseRoot,
        pid: 101,
        randomToken: () => "runtime-first",
        processAlive: (pid) => alive.get(pid) ?? false,
      }),
    );
    await first.start();
    firstControl.becomeReady();
    await first.flush();
    expect(first.health).toMatchObject({
      ready: true,
      writerLeaseHeld: true,
    });

    const secondControl = new FakeSharedControl();
    const second = new CodexActionBrokerRuntime(
      new CodexActionBroker({ filePath: ledgerPath }),
      secondControl as unknown as CodexSharedRuntimeControl,
      "source-a",
      new CodexActionBrokerWriterLease("source-a", {
        rootDir: leaseRoot,
        pid: 202,
        randomToken: () => "runtime-second",
        processAlive: (pid) => alive.get(pid) ?? false,
      }),
    );
    await second.start();
    secondControl.becomeReady();
    await second.flush();
    expect(second.health).toMatchObject({
      ready: false,
      writerLeaseHeld: false,
      degradedReason: "writer_lease_unavailable",
    });

    firstControl.request(commandRequest("request-before-handoff"));
    secondControl.request(commandRequest("request-before-handoff"));
    await Promise.all([first.flush(), second.flush()]);
    expect(first.listRequests()).toHaveLength(1);
    expect(second.listRequests()).toHaveLength(0);
    const requestBeforeHandoff = first.listRequests()[0];

    await first.close();
    secondControl.becomeUnavailable();
    secondControl.becomeReady();
    await second.flush();
    expect(second.health).toMatchObject({
      ready: true,
      writerLeaseHeld: true,
    });
    expect(
      second
        .listRequests({ includeTerminal: true })
        .find((request) => request.threadId === "thread-a"),
    ).toMatchObject({ state: "expired", live: false });
    await expect(
      second.respond(
        respondInput(requestBeforeHandoff, {
          operationId: "stale-after-handoff",
        }),
      ),
    ).resolves.toMatchObject({ outcome: "expired" });
    expect(secondControl.responses).toEqual([]);

    secondControl.request(commandRequest("request-after-handoff"));
    await second.flush();
    const current = second.currentRequestForThread("thread-a")!;
    await expect(
      second.respond(respondInput(current, { operationId: "after-handoff" })),
    ).resolves.toMatchObject({ outcome: "submitted" });
    expect(secondControl.responses).toHaveLength(1);
    await second.close();
  });

  it("does not revive a resolved standby request during same-connection handoff", async () => {
    const root = await mkdtemp(join(tmpdir(), "cab-runtime-resolved-handoff-"));
    roots.push(root);
    const ledgerPath = join(root, "broker.json");
    const leaseRoot = join(root, "lease");
    const alive = new Map([
      [301, true],
      [302, true],
    ]);
    const firstControl = new FakeSharedControl();
    const first = new CodexActionBrokerRuntime(
      new CodexActionBroker({ filePath: ledgerPath }),
      firstControl as unknown as CodexSharedRuntimeControl,
      "source-a",
      new CodexActionBrokerWriterLease("source-a", {
        rootDir: leaseRoot,
        pid: 301,
        randomToken: () => "runtime-resolved-first",
        processAlive: (pid) => alive.get(pid) ?? false,
      }),
    );
    await first.start();
    firstControl.becomeReady();
    await first.flush();

    const secondControl = new FakeSharedControl();
    const second = new CodexActionBrokerRuntime(
      new CodexActionBroker({ filePath: ledgerPath }),
      secondControl as unknown as CodexSharedRuntimeControl,
      "source-a",
      new CodexActionBrokerWriterLease("source-a", {
        rootDir: leaseRoot,
        pid: 302,
        randomToken: () => "runtime-resolved-second",
        processAlive: (pid) => alive.get(pid) ?? false,
      }),
    );
    await second.start();
    secondControl.becomeReady();
    await second.flush();

    firstControl.request(commandRequest("request-resolved-handoff"));
    secondControl.request(commandRequest("request-resolved-handoff"));
    await Promise.all([first.flush(), second.flush()]);
    expect((second as any).bufferedRequests).toHaveLength(1);

    secondControl.resolved({
      threadId: "thread-a",
      turnId: "another-turn",
      requestId: "request-resolved-handoff",
    });
    await second.flush();
    expect((second as any).bufferedRequests).toHaveLength(1);

    firstControl.resolved({
      threadId: "thread-a",
      turnId: "turn-a",
      requestId: "request-resolved-handoff",
    });
    secondControl.resolved({
      threadId: "thread-a",
      turnId: "turn-a",
      requestId: "request-resolved-handoff",
    });
    expect((second as any).bufferedRequests).toHaveLength(0);
    await Promise.all([first.flush(), second.flush()]);
    expect((second as any).bufferedRequests).toHaveLength(0);

    await first.close();
    // Trigger the same activation used by the lease retry without changing the
    // control generation: this is a warm writer handoff, not a reconnect.
    secondControl.emit("ready", secondControl.connectionGeneration);
    await second.flush();

    expect(second.health).toMatchObject({
      ready: true,
      writerLeaseHeld: true,
    });
    expect(second.listRequests()).toEqual([]);
    expect(
      second
        .listRequests({ includeTerminal: true })
        .filter((request) => request.threadId === "thread-a"),
    ).toEqual([expect.objectContaining({ state: "resolved", live: false })]);
    expect(secondControl.responses).toEqual([]);
    await second.close();
  });

  it("does not revive an expired durable request from the standby buffer", async () => {
    const root = await mkdtemp(join(tmpdir(), "cab-runtime-expired-handoff-"));
    roots.push(root);
    const ledgerPath = join(root, "broker.json");
    const leaseRoot = join(root, "lease");
    const alive = new Map([
      [401, true],
      [402, true],
    ]);
    const firstBroker = new CodexActionBroker({ filePath: ledgerPath });
    const firstControl = new FakeSharedControl();
    const first = new CodexActionBrokerRuntime(
      firstBroker,
      firstControl as unknown as CodexSharedRuntimeControl,
      "source-a",
      new CodexActionBrokerWriterLease("source-a", {
        rootDir: leaseRoot,
        pid: 401,
        randomToken: () => "runtime-expired-first",
        processAlive: (pid) => alive.get(pid) ?? false,
      }),
    );
    await first.start();
    firstControl.becomeReady();
    await first.flush();

    const secondControl = new FakeSharedControl();
    const second = new CodexActionBrokerRuntime(
      new CodexActionBroker({ filePath: ledgerPath }),
      secondControl as unknown as CodexSharedRuntimeControl,
      "source-a",
      new CodexActionBrokerWriterLease("source-a", {
        rootDir: leaseRoot,
        pid: 402,
        randomToken: () => "runtime-expired-second",
        processAlive: (pid) => alive.get(pid) ?? false,
      }),
    );
    await second.start();
    secondControl.becomeReady();
    await second.flush();

    firstControl.request(commandRequest("request-expired-handoff"));
    secondControl.request(commandRequest("request-expired-handoff"));
    await Promise.all([first.flush(), second.flush()]);
    const [pending] = await firstBroker.listReadonly({
      codexSourceId: "source-a",
    });
    expect(pending).toBeDefined();
    await firstBroker.expire(pending.identity, "operator");

    await first.close();
    secondControl.emit("ready", secondControl.connectionGeneration);
    await second.flush();

    expect(second.health).toMatchObject({
      ready: true,
      writerLeaseHeld: true,
    });
    expect(second.listRequests()).toEqual([]);
    expect(
      second
        .listRequests({ includeTerminal: true })
        .filter((request) => request.threadId === "thread-a"),
    ).toEqual([expect.objectContaining({ state: "expired", live: false })]);
    await second.close();
  });

  it("drains an in-flight response before releasing the writer lease", async () => {
    const root = await mkdtemp(join(tmpdir(), "cab-runtime-drain-"));
    roots.push(root);
    const broker = new CodexActionBroker({
      filePath: join(root, "broker.json"),
      now: () => new Date(NOW),
      randomToken: () => "drain-claim-token",
    });
    const control = new FakeSharedControl();
    let releaseSecondCheck!: () => void;
    let secondCheckStarted!: () => void;
    const secondCheck = new Promise<void>((resolve) => {
      releaseSecondCheck = resolve;
    });
    const checkStarted = new Promise<void>((resolve) => {
      secondCheckStarted = resolve;
    });
    let checks = 0;
    const releaseLease = vi.fn(async () => undefined);
    const lease = {
      health: { held: true, leaseEpoch: 1 },
      acquire: vi.fn(async () => ({ held: true, leaseEpoch: 1 })),
      assertHeld: vi.fn(async () => {
        checks += 1;
        if (checks === 2) {
          secondCheckStarted();
          await secondCheck;
        }
        return true;
      }),
      release: releaseLease,
    } as unknown as CodexActionBrokerWriterLease;
    const runtime = new CodexActionBrokerRuntime(
      broker,
      control as unknown as CodexSharedRuntimeControl,
      "source-a",
      lease,
    );
    await runtime.start();
    control.becomeReady();
    await runtime.flush();
    control.request(commandRequest("request-drain"));
    await runtime.flush();
    const request = runtime.currentRequestForThread("thread-a")!;
    checks = 0;

    const response = runtime.respond(
      respondInput(request, { operationId: "operation-drain" }),
    );
    await checkStarted;
    const closing = runtime.close();
    expect(runtime.health).toMatchObject({
      ready: false,
      degradedReason: "runtime_draining",
      writerLeaseHeld: true,
    });
    expect(releaseLease).not.toHaveBeenCalled();
    releaseSecondCheck();
    await expect(response).resolves.toMatchObject({
      outcome: "outcomeUnknown",
      request: { state: "claimed" },
    });
    await closing;
    expect(control.responses).toEqual([]);
    expect(releaseLease).toHaveBeenCalledTimes(1);
  });

  it("reacquires a new lease epoch after the daemon socket identity changes", async () => {
    const root = await mkdtemp(join(tmpdir(), "cab-runtime-daemon-restart-"));
    roots.push(root);
    const control = new FakeSharedControl();
    const runtime = new CodexActionBrokerRuntime(
      new CodexActionBroker({ filePath: join(root, "broker.json") }),
      control as unknown as CodexSharedRuntimeControl,
      "source-a",
      new CodexActionBrokerWriterLease("source-a", {
        rootDir: join(root, "lease"),
        pid: 303,
        randomToken: () => "daemon-restart-runtime",
        processAlive: (pid) => pid === 303,
      }),
    );
    await runtime.start();
    control.becomeReady();
    await runtime.flush();
    expect(runtime.health.authorityGeneration).toBe("cab:1:1");

    control.becomeUnavailable();
    control.daemonIdentity = {
      ...control.daemonIdentity,
      socketInode: control.daemonIdentity.socketInode + 1,
    };
    control.becomeReady();
    await runtime.flush();
    expect(runtime.health).toMatchObject({
      ready: true,
      writerLeaseHeld: true,
      authorityGeneration: "cab:2:2",
    });
    control.request(commandRequest("request-new-daemon"));
    await runtime.flush();
    const request = runtime.currentRequestForThread("thread-a")!;
    await expect(
      runtime.respond(respondInput(request, { operationId: "new-daemon" })),
    ).resolves.toMatchObject({ outcome: "submitted" });
    expect(control.responses).toHaveLength(1);
    await runtime.close();
  });
});
