import { EventEmitter } from "node:events";
import { describe, expect, it, vi } from "vitest";
import type {
  CodexProcess,
  CodexStartOptions,
} from "../codex-process.js";
import type { ServerMessage } from "../parser.js";
import {
  isLocalFeatureServerMessageType,
  parseLocalFeatureClientMessage,
} from "./protocol.js";
import { SideChatFeatureHandler } from "./side-chat.js";
import type {
  LocalFeatureHandleContext,
  LocalFeatureRuntime,
  LocalFeatureSession,
} from "./runtime.js";

class FakeCodexProcess extends EventEmitter {
  status = "starting" as const;
  readonly start = vi.fn(
    (_cwd: string, _options?: CodexStartOptions): void => {},
  );
  readonly sendInput = vi.fn((_text: string): void => {});
  readonly approve = vi.fn((_id?: string): void => {});
  readonly approveAlways = vi.fn((_id?: string): void => {});
  readonly reject = vi.fn((_id?: string): void => {});
  readonly answer = vi.fn((_id: string, _answer: string): void => {});
  readonly interrupt = vi.fn((): void => {});
  readonly stop = vi.fn((): void => {});

  emitMessage(message: ServerMessage): void {
    this.emit("message", message);
  }

  ready(): void {
    this.emit("input_ready");
  }

  exit(): void {
    this.emit("exit", 0);
  }

  asCodex(): CodexProcess {
    return this as unknown as CodexProcess;
  }
}

interface ParentProcessOptions {
  approvalPolicy?: string;
  approvalsReviewer?: string;
  codexPermissionsMode?: CodexStartOptions["codexPermissionsMode"];
  model?: string;
  modelReasoningEffort?: string;
  serviceTier?: string;
  collaborationMode?: "plan" | "default";
}

interface TestSession extends LocalFeatureSession {
  status?: string;
  codexQueuedInput?: unknown;
  projectPath?: string;
  worktreePath?: string;
  codexSettings?: {
    profile?: string;
    approvalPolicy?: string;
    approvalsReviewer?: string;
    codexPermissionsMode?: string;
    sandboxMode?: string;
    model?: string;
    modelReasoningEffort?: string;
    serviceTier?: string;
    networkAccessEnabled?: boolean;
    webSearchMode?: string;
    additionalWritableRoots?: string[];
  };
}

function parentProcess(options: ParentProcessOptions = {}): CodexProcess {
  return {
    forkThread: vi.fn(),
    archiveThread: vi.fn(),
    approvalPolicy: options.approvalPolicy ?? "on-request",
    approvalsReviewer: options.approvalsReviewer ?? "user",
    codexPermissionsMode: options.codexPermissionsMode,
    model: options.model ?? "gpt-parent",
    modelReasoningEffort: options.modelReasoningEffort,
    serviceTier: options.serviceTier ?? "standard",
    collaborationMode: options.collaborationMode ?? "default",
  } as unknown as CodexProcess;
}

interface SentMessage {
  client: object;
  message: Record<string, unknown>;
}

function harness(options: {
  parent?: CodexProcess;
  session?: TestSession;
  children?: FakeCodexProcess[];
  supports?: boolean;
} = {}): {
  runtime: LocalFeatureRuntime;
  sent: SentMessage[];
  children: FakeCodexProcess[];
} {
  const parent = options.parent ?? parentProcess();
  const session = options.session ?? {
    id: "parent-session",
    provider: "codex",
    process: parent,
    status: "idle",
    projectPath: "/repo",
  };
  const children = options.children ?? [new FakeCodexProcess()];
  let childIndex = 0;
  const sent: SentMessage[] = [];
  const runtime: LocalFeatureRuntime = {
    getSession: (sessionId) =>
      sessionId === session.id ? session : undefined,
    getCodexThreadId: () => "parent-thread",
    getActiveCodexProcess: () => parent,
    createStandaloneCodexProcess: async () => parent,
    createDedicatedCodexProcess: () => {
      const child = children[childIndex++];
      if (!child) throw new Error("No fake child process available");
      return child.asCodex();
    },
    send: (client, message) => {
      sent.push({
        client,
        message: message as unknown as Record<string, unknown>,
      });
    },
    supports: () => options.supports ?? true,
  };
  return { runtime, sent, children };
}

function context(
  runtime: LocalFeatureRuntime,
  client: object,
  controller = new AbortController(),
): LocalFeatureHandleContext {
  return { runtime, client, signal: controller.signal };
}

function openMessage(requestId = "open-request") {
  return {
    type: "open_side_chat" as const,
    parentSessionId: "parent-session",
    requestId,
  };
}

function openedFor(sent: SentMessage[], client: object): Record<string, unknown> {
  const opened = sent.find(
    (entry) =>
      entry.client === client &&
      entry.message.type === "side_chat_event" &&
      entry.message.event === "opened",
  )?.message;
  if (!opened) throw new Error("opened event not found");
  return opened;
}

async function openReady(params: {
  handler: SideChatFeatureHandler;
  runtime: LocalFeatureRuntime;
  sent: SentMessage[];
  client: object;
  child: FakeCodexProcess;
  requestId?: string;
}): Promise<string> {
  await params.handler.handle(
    openMessage(params.requestId),
    context(params.runtime, params.client),
  );
  expect(
    params.sent.some(
      (entry) =>
        entry.client === params.client && entry.message.event === "opened",
    ),
  ).toBe(false);
  params.child.ready();
  return String(openedFor(params.sent, params.client).sideChatId);
}

describe("SideChatFeatureHandler", () => {
  it("starts an ephemeral fork on the child connection and opens only when it is ready", async () => {
    const parent = parentProcess();
    const child = new FakeCodexProcess();
    const state = harness({ parent, children: [child] });
    const handler = new SideChatFeatureHandler();
    const client = {};

    await handler.handle(
      openMessage(),
      context(state.runtime, client),
    );

    expect(parent.forkThread).not.toHaveBeenCalled();
    expect(parent.archiveThread).not.toHaveBeenCalled();
    expect(child.start).toHaveBeenCalledWith(
      "/repo",
      expect.objectContaining({
        ephemeralForkFromThreadId: "parent-thread",
        collaborationMode: "default",
      }),
    );
    expect(state.sent.some((entry) => entry.message.event === "opened")).toBe(
      false,
    );
    child.ready();
    expect(openedFor(state.sent, client)).toMatchObject({
      requestId: "open-request",
    });
  });

  it("refuses to fork a busy parent or one with queued input", async () => {
    const parent = parentProcess();
    const session: TestSession = {
      id: "parent-session",
      provider: "codex",
      process: parent,
      status: "running",
      projectPath: "/repo",
      codexQueuedInput: { text: "queued" },
    };
    const child = new FakeCodexProcess();
    const state = harness({ parent, session, children: [child] });
    const client = {};

    await new SideChatFeatureHandler().handle(
      openMessage(),
      context(state.runtime, client),
    );

    expect(child.start).not.toHaveBeenCalled();
    expect(state.sent).toContainEqual({
      client,
      message: expect.objectContaining({
        event: "error",
        requestId: "open-request",
        error: expect.objectContaining({ code: "parent_session_busy" }),
      }),
    });
  });

  it("stops an unopened child when ephemeral fork initialization times out", async () => {
    vi.useFakeTimers();
    try {
      const child = new FakeCodexProcess();
      const state = harness({ children: [child] });
      const handler = new SideChatFeatureHandler();
      const client = {};
      await handler.handle(openMessage(), context(state.runtime, client));

      await vi.advanceTimersByTimeAsync(10_000);

      expect(child.interrupt).toHaveBeenCalledOnce();
      expect(child.stop).toHaveBeenCalledOnce();
      expect(state.sent.at(-1)).toEqual({
        client,
        message: expect.objectContaining({
          event: "error",
          requestId: "open-request",
          error: { code: "side_chat_open_timeout", message: expect.any(String) },
        }),
      });
    } finally {
      vi.useRealTimers();
    }
  });

  it("inherits the worktree and parent settings without granting new authority", async () => {
    const parent = parentProcess({
      approvalPolicy: "never",
      approvalsReviewer: "auto_review",
      codexPermissionsMode: "fullAccess",
      model: "gpt-runtime",
      modelReasoningEffort: "high",
      serviceTier: "fast",
      collaborationMode: "plan",
    });
    const session: TestSession = {
      id: "parent-session",
      provider: "codex",
      process: parent,
      status: "idle",
      projectPath: "/repo",
      worktreePath: "/repo-worktree",
      codexSettings: {
        profile: "safe-profile",
        approvalPolicy: "on-request",
        approvalsReviewer: "auto_review",
        codexPermissionsMode: "autoReview",
        sandboxMode: "workspace-write",
        model: "gpt-session",
        modelReasoningEffort: "xhigh",
        serviceTier: "fast",
        networkAccessEnabled: false,
        webSearchMode: "cached",
        additionalWritableRoots: ["/repo/shared"],
      },
    };
    const child = new FakeCodexProcess();
    const state = harness({ parent, session, children: [child] });

    await new SideChatFeatureHandler().handle(
      openMessage(),
      context(state.runtime, {}),
    );

    expect(child.start).toHaveBeenCalledWith("/repo-worktree", {
      ephemeralForkFromThreadId: "parent-thread",
      profile: "safe-profile",
      approvalPolicy: "on-request",
      approvalsReviewer: "auto_review",
      codexPermissionsMode: "autoReview",
      sandboxMode: "workspace-write",
      model: "gpt-session",
      modelReasoningEffort: "xhigh",
      serviceTier: "fast",
      networkAccessEnabled: false,
      webSearchMode: "cached",
      collaborationMode: "default",
      additionalWritableRoots: ["/repo/shared"],
    });
    const passed = child.start.mock.calls[0]?.[1];
    expect(passed?.additionalWritableRoots).not.toBe(
      session.codexSettings?.additionalWritableRoots,
    );
    child.ready();
  });

  it("falls back to restrictive settings when parent metadata is incomplete", async () => {
    const parent = parentProcess();
    const child = new FakeCodexProcess();
    const state = harness({ parent, children: [child] });

    await new SideChatFeatureHandler().handle(
      openMessage(),
      context(state.runtime, {}),
    );

    expect(child.start.mock.calls[0]?.[1]).toMatchObject({
      approvalPolicy: "on-request",
      approvalsReviewer: "user",
      sandboxMode: "read-only",
      networkAccessEnabled: false,
      webSearchMode: "disabled",
    });
    child.ready();
  });

  it("opens a side chat when the parent approval policy is unknown", async () => {
    // A Desktop-resumed thread can have no known approval policy; the parent
    // getter then reports undefined instead of a fabricated value, and the
    // fork must still open with the restrictive fallback.
    const parent = parentProcess();
    (parent as { approvalPolicy?: string }).approvalPolicy = undefined;
    const child = new FakeCodexProcess();
    const state = harness({ parent, children: [child] });

    await new SideChatFeatureHandler().handle(
      openMessage(),
      context(state.runtime, {}),
    );

    expect(
      state.sent
        .map((entry) => entry.message)
        .filter((message) => message.event === "error"),
    ).toEqual([]);
    expect(child.start.mock.calls[0]?.[1]).toMatchObject({
      approvalPolicy: "on-request",
    });
    child.ready();
  });

  it("isolates identical parent sessions by owner and never broadcasts child events", async () => {
    const parent = parentProcess();
    const childA = new FakeCodexProcess();
    const childB = new FakeCodexProcess();
    const state = harness({ parent, children: [childA, childB] });
    const handler = new SideChatFeatureHandler();
    const clientA = {};
    const clientB = {};

    await handler.handle(openMessage("open-a"), context(state.runtime, clientA));
    await handler.handle(openMessage("open-b"), context(state.runtime, clientB));
    childA.ready();
    childB.ready();
    const sideChatA = String(openedFor(state.sent, clientA).sideChatId);
    const sentBeforeMessage = state.sent.length;

    childA.emitMessage({
      type: "assistant",
      message: {
        id: "assistant-a",
        role: "assistant",
        content: [{ type: "text", text: "owner A only" }],
        model: "gpt-test",
      },
    });

    expect(state.sent.slice(sentBeforeMessage)).toEqual([
      {
        client: clientA,
        message: expect.objectContaining({
          event: "message",
          parentSessionId: "parent-session",
          sideChatId: sideChatA,
          message: {
            id: "assistant-a",
            role: "assistant",
            text: "owner A only",
          },
        }),
      },
    ]);

    await handler.handle(
      {
        type: "side_chat_input",
        parentSessionId: "parent-session",
        sideChatId: sideChatA,
        requestId: "stolen-request",
        clientMessageId: "stolen-message",
        text: "must not reach A",
      },
      context(state.runtime, clientB),
    );
    expect(childA.sendInput).not.toHaveBeenCalled();
    expect(state.sent.at(-1)).toEqual({
      client: clientB,
      message: expect.objectContaining({
        event: "error",
        requestId: "stolen-request",
        clientMessageId: "stolen-message",
        error: expect.objectContaining({ code: "side_chat_not_found" }),
      }),
    });
  });

  it("keeps request correlation across input, messages, permissions, questions, interrupt, and close", async () => {
    const child = new FakeCodexProcess();
    const state = harness({ children: [child] });
    const handler = new SideChatFeatureHandler();
    const client = {};
    const ctx = context(state.runtime, client);
    await handler.handle(openMessage(), ctx);
    child.ready();
    const sideChatId = String(openedFor(state.sent, client).sideChatId);

    await handler.handle(
      {
        type: "side_chat_input",
        parentSessionId: "parent-session",
        sideChatId,
        requestId: "input-request",
        clientMessageId: "client-message",
        text: "hello",
      },
      ctx,
    );
    expect(child.sendInput).toHaveBeenCalledWith("hello");
    expect(state.sent).toContainEqual({
      client,
      message: expect.objectContaining({
        event: "input_accepted",
        parentSessionId: "parent-session",
        sideChatId,
        requestId: "input-request",
        clientMessageId: "client-message",
        queued: false,
      }),
    });

    child.emitMessage({
      type: "user_input",
      text: "hello",
      userMessageUuid: "server-user-id",
    });
    expect(state.sent.at(-1)?.message).toMatchObject({
      event: "message",
      requestId: "input-request",
      clientMessageId: "client-message",
      message: {
        id: "client-message",
        role: "user",
        text: "hello",
      },
    });

    const sentBeforeStream = state.sent.length;
    child.emitMessage({ type: "stream_delta", text: "hel" });
    expect(state.sent).toHaveLength(sentBeforeStream);
    await new Promise((resolve) => setTimeout(resolve, 100));
    child.emitMessage({
      type: "assistant",
      message: {
        id: "final-id",
        role: "assistant",
        content: [{ type: "text", text: "hello back" }],
        model: "gpt-test",
      },
    });
    const correlatedMessages = state.sent.filter(
      (entry) => entry.message.event === "message",
    );
    expect(correlatedMessages).toHaveLength(3);
    expect(correlatedMessages[1]?.message).toMatchObject({
      requestId: "input-request",
      clientMessageId: "client-message",
      message: { role: "assistant", text: "hel" },
    });
    expect(correlatedMessages[2]?.message).toMatchObject({
      requestId: "input-request",
      clientMessageId: "client-message",
      message: { role: "assistant", text: "hello back" },
    });
    expect(
      (correlatedMessages[1]?.message.message as Record<string, unknown>).id,
    ).toBe(
      (correlatedMessages[2]?.message.message as Record<string, unknown>).id,
    );

    child.emitMessage({
      type: "permission_request",
      toolUseId: "permission-1",
      toolName: "Bash",
      input: { command: "pwd" },
    });
    expect(state.sent.at(-1)?.message).toMatchObject({
      event: "permission_request",
      requestId: "input-request",
      clientMessageId: "client-message",
      permission: {
        requestId: "permission-1",
        toolName: "Bash",
        input: { command: "pwd" },
      },
    });
    await handler.handle(
      {
        type: "side_chat_permission_response",
        parentSessionId: "parent-session",
        sideChatId,
        requestId: "permission-response",
        permissionRequestId: "permission-1",
        decision: "allow_always",
      },
      ctx,
    );
    expect(child.approveAlways).toHaveBeenCalledWith("permission-1");
    expect(state.sent.at(-1)?.message).toMatchObject({
      event: "status",
      requestId: "permission-response",
    });

    child.emitMessage({
      type: "permission_request",
      toolUseId: "question-1",
      toolName: "AskUserQuestion",
      input: { questions: [{ id: "q", question: "Continue?" }] },
    });
    expect(state.sent.at(-1)?.message).toMatchObject({
      event: "question",
      question: {
        requestId: "question-1",
        questions: [{ id: "q", question: "Continue?" }],
      },
    });
    await handler.handle(
      {
        type: "side_chat_answer",
        parentSessionId: "parent-session",
        sideChatId,
        requestId: "answer-response",
        questionRequestId: "question-1",
        answer: '{"q":"yes"}',
      },
      ctx,
    );
    expect(child.answer).toHaveBeenCalledWith(
      "question-1",
      '{"q":"yes"}',
    );

    await handler.handle(
      {
        type: "side_chat_interrupt",
        parentSessionId: "parent-session",
        sideChatId,
        requestId: "interrupt-request",
      },
      ctx,
    );
    expect(child.interrupt).toHaveBeenCalledOnce();
    expect(state.sent.at(-1)?.message).toMatchObject({
      event: "status",
      requestId: "interrupt-request",
    });

    await handler.handle(
      {
        type: "close_side_chat",
        parentSessionId: "parent-session",
        sideChatId,
        requestId: "close-request",
      },
      ctx,
    );
    expect(child.stop).toHaveBeenCalledOnce();
    expect(state.sent.at(-1)).toEqual({
      client,
      message: expect.objectContaining({
        event: "closed",
        parentSessionId: "parent-session",
        sideChatId,
        requestId: "close-request",
      }),
    });
  });

  it("throttles cumulative streaming and bounds its text and transmission budget", async () => {
    vi.useFakeTimers();
    try {
      const child = new FakeCodexProcess();
      const state = harness({ children: [child] });
      const handler = new SideChatFeatureHandler();
      const client = {};
      const ctx = context(state.runtime, client);
      await handler.handle(openMessage(), ctx);
      child.ready();
      const sideChatId = String(openedFor(state.sent, client).sideChatId);
      await handler.handle(
        {
          type: "side_chat_input",
          parentSessionId: "parent-session",
          sideChatId,
          requestId: "stream-request",
          clientMessageId: "stream-message",
          text: "stream",
        },
        ctx,
      );

      for (let index = 0; index < 50; index += 1) {
        const beforeDelta = state.sent.length;
        child.emitMessage({
          type: "stream_delta",
          text: "x".repeat(2_500),
        });
        expect(state.sent).toHaveLength(beforeDelta);
        await vi.advanceTimersByTimeAsync(75);
      }

      const streamMessages = state.sent.filter(
        (entry) =>
          entry.message.event === "message" &&
          entry.message.clientMessageId === "stream-message",
      );
      expect(streamMessages.length).toBeGreaterThan(0);
      expect(streamMessages.length).toBeLessThan(40);
      for (const entry of streamMessages) {
        const payload = entry.message.message as Record<string, unknown>;
        expect(String(payload.text).length).toBeLessThanOrEqual(100_000);
      }
      handler.close();
    } finally {
      vi.useRealTimers();
    }
  });

  it("interrupts and stops on disconnect, then suppresses late child events", async () => {
    const child = new FakeCodexProcess();
    const state = harness({ children: [child] });
    const handler = new SideChatFeatureHandler();
    const client = {};
    await handler.handle(openMessage(), context(state.runtime, client));
    const sentBeforeDisconnect = state.sent.length;

    handler.disconnect(client);
    expect(child.interrupt).toHaveBeenCalledOnce();
    expect(child.stop).toHaveBeenCalledOnce();

    child.emitMessage({
      type: "assistant",
      message: {
        id: "late",
        role: "assistant",
        content: [{ type: "text", text: "late" }],
        model: "gpt-test",
      },
    });
    child.ready();
    child.exit();
    expect(state.sent).toHaveLength(sentBeforeDisconnect);
  });

  it("stops every owned child on Bridge close without emitting shutdown events", async () => {
    const parent = parentProcess();
    const childA = new FakeCodexProcess();
    const childB = new FakeCodexProcess();
    const state = harness({ parent, children: [childA, childB] });
    const handler = new SideChatFeatureHandler();
    await handler.handle(openMessage("open-a"), context(state.runtime, {}));
    await handler.handle(openMessage("open-b"), context(state.runtime, {}));
    const sentBeforeClose = state.sent.length;

    handler.close();

    expect(childA.interrupt).toHaveBeenCalledOnce();
    expect(childA.stop).toHaveBeenCalledOnce();
    expect(childB.interrupt).toHaveBeenCalledOnce();
    expect(childB.stop).toHaveBeenCalledOnce();
    childA.emitMessage({ type: "status", status: "idle" });
    childB.emitMessage({ type: "status", status: "idle" });
    expect(state.sent).toHaveLength(sentBeforeClose);
  });

  it("fully stops a child and emits an uncorrelated close when its runtime exits", async () => {
    const child = new FakeCodexProcess();
    const state = harness({ children: [child] });
    const handler = new SideChatFeatureHandler();
    const client = {};
    await handler.handle(openMessage(), context(state.runtime, client));
    child.ready();
    const sideChatId = String(openedFor(state.sent, client).sideChatId);

    child.exit();

    expect(child.interrupt).toHaveBeenCalledOnce();
    expect(child.stop).toHaveBeenCalledOnce();
    expect(state.sent.at(-1)).toEqual({
      client,
      message: {
        type: "side_chat_event",
        event: "closed",
        parentSessionId: "parent-session",
        sideChatId,
      },
    });
  });

  it("acknowledges a queued input only after it is delivered to the child", async () => {
    const child = new FakeCodexProcess();
    const state = harness({ children: [child] });
    const handler = new SideChatFeatureHandler();
    const client = {};
    const ctx = context(state.runtime, client);
    const sideChatId = await openReady({
      handler,
      runtime: state.runtime,
      sent: state.sent,
      client,
      child,
    });

    await handler.handle(
      {
        type: "side_chat_input",
        parentSessionId: "parent-session",
        sideChatId,
        requestId: "active-request",
        clientMessageId: "active-message",
        text: "active",
      },
      ctx,
    );
    await handler.handle(
      {
        type: "side_chat_input",
        parentSessionId: "parent-session",
        sideChatId,
        requestId: "queued-request",
        clientMessageId: "queued-message",
        text: "queued",
      },
      ctx,
    );

    const queuedAcks = () =>
      state.sent
        .filter(
          (entry) =>
            entry.message.event === "input_accepted" &&
            entry.message.clientMessageId === "queued-message",
        )
        .map((entry) => entry.message.queued);
    expect(queuedAcks()).toEqual([true]);
    expect(child.sendInput).toHaveBeenCalledTimes(1);

    child.ready();

    expect(child.sendInput.mock.calls.map(([text]) => text)).toEqual([
      "active",
      "queued",
    ]);
    expect(queuedAcks()).toEqual([true, false]);
    const deliveredAck = state.sent.findLast(
      (entry) =>
        entry.message.event === "input_accepted" &&
        entry.message.clientMessageId === "queued-message",
    );
    expect(deliveredAck?.message).toMatchObject({
      requestId: "queued-request",
      clientMessageId: "queued-message",
      queued: false,
    });
  });

  it("reports queued inputs as undelivered before closing on child exit", async () => {
    const child = new FakeCodexProcess();
    const state = harness({ children: [child] });
    const handler = new SideChatFeatureHandler();
    const client = {};
    const ctx = context(state.runtime, client);
    const sideChatId = await openReady({
      handler,
      runtime: state.runtime,
      sent: state.sent,
      client,
      child,
    });

    await handler.handle(
      {
        type: "side_chat_input",
        parentSessionId: "parent-session",
        sideChatId,
        requestId: "active-request",
        clientMessageId: "active-message",
        text: "active",
      },
      ctx,
    );
    await handler.handle(
      {
        type: "side_chat_input",
        parentSessionId: "parent-session",
        sideChatId,
        requestId: "queued-request",
        clientMessageId: "queued-message",
        text: "queued",
      },
      ctx,
    );

    child.exit();

    expect(state.sent.slice(-2)).toEqual([
      {
        client,
        message: {
          type: "side_chat_event",
          event: "error",
          parentSessionId: "parent-session",
          sideChatId,
          requestId: "queued-request",
          clientMessageId: "queued-message",
          error: {
            code: "side_chat_input_not_delivered",
            message: "Side chat closed before queued input was delivered",
          },
        },
      },
      {
        client,
        message: {
          type: "side_chat_event",
          event: "closed",
          parentSessionId: "parent-session",
          sideChatId,
        },
      },
    ]);
    expect(
      state.sent.filter(
        (entry) =>
          entry.message.event === "error" &&
          entry.message.clientMessageId === "active-message",
      ),
    ).toHaveLength(0);
  });

  it("bounds queued input characters and stores only digests for idempotency", async () => {
    const child = new FakeCodexProcess();
    const state = harness({ children: [child] });
    const handler = new SideChatFeatureHandler();
    const client = {};
    const ctx = context(state.runtime, client);
    const sideChatId = await openReady({
      handler,
      runtime: state.runtime,
      sent: state.sent,
      client,
      child,
    });
    const send = async (
      requestId: string,
      clientMessageId: string,
      text: string,
    ) =>
      handler.handle(
        {
          type: "side_chat_input",
          parentSessionId: "parent-session",
          sideChatId,
          requestId,
          clientMessageId,
          text,
        },
        ctx,
      );

    await send("active-request", "active-message", "a".repeat(100_000));
    await send("queued-request-1", "queued-message-1", "b".repeat(100_000));
    await send("queued-request-2", "queued-message-2", "c".repeat(100_000));
    await send("over-budget-request", "over-budget-message", "d");

    expect(child.sendInput).toHaveBeenCalledTimes(1);
    expect(state.sent.at(-1)?.message).toMatchObject({
      event: "error",
      requestId: "over-budget-request",
      clientMessageId: "over-budget-message",
      error: { code: "side_chat_queue_full" },
    });

    const recordsByClient = (
      handler as unknown as {
        recordsByClient: Map<
          object,
          Map<
            string,
            {
              acceptedInputs: Map<
                string,
                { requestId: string; textDigest: string; delivered: boolean }
              >;
            }
          >
        >;
      }
    ).recordsByClient;
    const acceptedInputs = recordsByClient
      .get(client)
      ?.get("parent-session")?.acceptedInputs;
    expect(acceptedInputs?.get("queued-message-1")).toEqual({
      requestId: "queued-request-1",
      textDigest: expect.stringMatching(/^[0-9a-f]{64}$/),
      delivered: false,
    });
    expect(acceptedInputs?.get("queued-message-1")).not.toHaveProperty("text");
    expect(acceptedInputs?.has("over-budget-message")).toBe(false);
  });

  it("rejects tool suggestions that require the main conversation install flow", async () => {
    const child = new FakeCodexProcess();
    const state = harness({ children: [child] });
    const handler = new SideChatFeatureHandler();
    const client = {};
    const ctx = context(state.runtime, client);
    const sideChatId = await openReady({
      handler,
      runtime: state.runtime,
      sent: state.sent,
      client,
      child,
    });
    await handler.handle(
      {
        type: "side_chat_input",
        parentSessionId: "parent-session",
        sideChatId,
        requestId: "suggestion-request",
        clientMessageId: "suggestion-message",
        text: "find a suitable tool",
      },
      ctx,
    );
    const sentBeforeSuggestion = state.sent.length;

    child.emitMessage({
      type: "permission_request",
      toolUseId: "tool-suggestion-1",
      toolName: "ToolSuggestion",
      input: {
        toolName: "GitHub",
        toolType: "plugin",
        installState: "needs_auth",
      },
    });

    expect(child.reject).toHaveBeenCalledWith("tool-suggestion-1");
    expect(state.sent.slice(sentBeforeSuggestion)).toEqual([
      {
        client,
        message: {
          type: "side_chat_event",
          event: "error",
          parentSessionId: "parent-session",
          sideChatId,
          requestId: "suggestion-request",
          clientMessageId: "suggestion-message",
          error: {
            code: "side_chat_tool_suggestion_unsupported",
            message:
              "Tool suggestions must be installed from the main conversation",
          },
        },
      },
    ]);
  });

  it("reuses one child for repeated open/input identifiers without duplicate execution", async () => {
    const parent = parentProcess();
    const child = new FakeCodexProcess();
    const state = harness({ parent, children: [child] });
    const handler = new SideChatFeatureHandler();
    const client = {};
    const ctx = context(state.runtime, client);
    await handler.handle(openMessage("open-1"), ctx);
    await handler.handle(openMessage("open-2"), ctx);
    expect(child.start).toHaveBeenCalledOnce();
    child.ready();
    const opened = openedFor(state.sent, client);
    expect(opened.requestId).toBe("open-2");
    const sideChatId = String(opened.sideChatId);

    await handler.handle(openMessage("open-3"), ctx);
    expect(child.start).toHaveBeenCalledOnce();
    expect(state.sent.at(-1)?.message).toMatchObject({
      event: "opened",
      sideChatId,
      requestId: "open-3",
    });

    const input = {
      type: "side_chat_input" as const,
      parentSessionId: "parent-session",
      sideChatId,
      requestId: "input-1",
      clientMessageId: "message-1",
      text: "run once",
    };
    await handler.handle(input, ctx);
    await handler.handle(input, ctx);
    expect(child.sendInput).toHaveBeenCalledOnce();
    expect(
      state.sent.filter(
        (entry) =>
          entry.message.event === "input_accepted" &&
          entry.message.clientMessageId === "message-1",
      ),
    ).toHaveLength(2);

    await handler.handle(
      { ...input, requestId: "input-2", text: "different" },
      ctx,
    );
    expect(child.sendInput).toHaveBeenCalledOnce();
    expect(state.sent.at(-1)?.message).toMatchObject({
      event: "error",
      error: { code: "side_chat_input_conflict" },
    });
  });

  it("enforces per-client and global child process limits", async () => {
    const makeLimitedState = (count: number) => {
      const parent = parentProcess();
      const state = harness({
        parent,
        children: Array.from({ length: count }, () => new FakeCodexProcess()),
      });
      state.runtime.getSession = (sessionId) => ({
        id: sessionId,
        provider: "codex",
        process: parent,
        status: "idle",
        projectPath: "/repo",
      });
      state.runtime.getCodexThreadId = (session) => `thread-${session.id}`;
      return state;
    };

    const clientState = makeLimitedState(4);
    const clientHandler = new SideChatFeatureHandler();
    const client = {};
    for (let index = 0; index < 4; index += 1) {
      await clientHandler.handle(
        {
          type: "open_side_chat",
          parentSessionId: `parent-${index}`,
          requestId: `open-${index}`,
        },
        context(clientState.runtime, client),
      );
    }
    await clientHandler.handle(
      {
        type: "open_side_chat",
        parentSessionId: "parent-over-limit",
        requestId: "open-over-limit",
      },
      context(clientState.runtime, client),
    );
    expect(clientState.sent.at(-1)?.message).toMatchObject({
      event: "error",
      error: { code: "side_chat_client_limit" },
    });
    clientHandler.close();

    const globalState = makeLimitedState(8);
    const globalHandler = new SideChatFeatureHandler();
    for (let index = 0; index < 8; index += 1) {
      await globalHandler.handle(
        {
          type: "open_side_chat",
          parentSessionId: `global-parent-${index}`,
          requestId: `global-open-${index}`,
        },
        context(globalState.runtime, {}),
      );
    }
    await globalHandler.handle(
      {
        type: "open_side_chat",
        parentSessionId: "global-parent-over-limit",
        requestId: "global-open-over-limit",
      },
      context(globalState.runtime, {}),
    );
    expect(globalState.sent.at(-1)?.message).toMatchObject({
      event: "error",
      error: { code: "side_chat_global_limit" },
    });
    globalHandler.close();
  });

  it("rejects side chat commands when the capability was not negotiated", async () => {
    const state = harness({ supports: false });
    const client = {};
    await new SideChatFeatureHandler().handle(
      openMessage(),
      context(state.runtime, client),
    );
    expect(state.sent).toEqual([
      {
        client,
        message: {
          type: "error",
          errorCode: "unsupported_capability",
          message: "Side chat capability was not negotiated",
        },
      },
    ]);
  });

  it("allows an existing owner to close after capability renegotiation removes side chat", async () => {
    const child = new FakeCodexProcess();
    const state = harness({ children: [child] });
    const handler = new SideChatFeatureHandler();
    const client = {};
    const ctx = context(state.runtime, client);
    const sideChatId = await openReady({
      handler,
      runtime: state.runtime,
      sent: state.sent,
      client,
      child,
    });

    state.runtime.supports = () => false;
    await handler.handle(
      {
        type: "close_side_chat",
        parentSessionId: "parent-session",
        sideChatId,
        requestId: "close-after-renegotiation",
      },
      ctx,
    );

    expect(child.interrupt).toHaveBeenCalledOnce();
    expect(child.stop).toHaveBeenCalledOnce();
    expect(state.sent.at(-1)?.message).toMatchObject({
      event: "closed",
      requestId: "close-after-renegotiation",
      sideChatId,
    });
  });

  it("actively stops owned children when capability renegotiation removes side chat", async () => {
    const child = new FakeCodexProcess();
    const state = harness({ children: [child] });
    const handler = new SideChatFeatureHandler();
    const client = {};
    await openReady({
      handler,
      runtime: state.runtime,
      sent: state.sent,
      client,
      child,
    });
    const sentBeforeChange = state.sent.length;

    state.runtime.supports = () => false;
    handler.capabilitiesChanged(client);

    expect(child.interrupt).toHaveBeenCalledOnce();
    expect(child.stop).toHaveBeenCalledOnce();
    expect(state.sent).toHaveLength(sentBeforeChange);
  });
});

describe("side chat protocol parsing", () => {
  const validMessages = [
    {
      type: "open_side_chat",
      parentSessionId: "parent",
      requestId: "open",
    },
    {
      type: "side_chat_input",
      parentSessionId: "parent",
      sideChatId: "side",
      requestId: "input",
      clientMessageId: "client-message",
      text: "hello",
    },
    {
      type: "side_chat_permission_response",
      parentSessionId: "parent",
      sideChatId: "side",
      requestId: "permission-response",
      permissionRequestId: "permission",
      decision: "allow_always",
    },
    {
      type: "side_chat_answer",
      parentSessionId: "parent",
      sideChatId: "side",
      requestId: "answer",
      questionRequestId: "question",
      answer: "",
    },
    {
      type: "side_chat_interrupt",
      parentSessionId: "parent",
      sideChatId: "side",
      requestId: "interrupt",
    },
    {
      type: "close_side_chat",
      parentSessionId: "parent",
      sideChatId: "side",
      requestId: "close",
    },
  ] as const;

  it("accepts only the canonical six client shapes", () => {
    for (const message of validMessages) {
      expect(
        parseLocalFeatureClientMessage(
          message as unknown as Record<string, unknown>,
        ),
      ).toEqual(message);
    }
    expect(
      parseLocalFeatureClientMessage({
        ...validMessages[1],
        text: "a".repeat(100_000),
      }),
    ).not.toBeNull();
    expect(isLocalFeatureServerMessageType("side_chat_event")).toBe(true);
  });

  it("rejects extra keys, invalid enums, blank input, and oversized fields", () => {
    expect(
      parseLocalFeatureClientMessage({
        ...validMessages[0],
        unexpected: true,
      }),
    ).toBeNull();
    expect(
      parseLocalFeatureClientMessage({
        ...validMessages[1],
        text: "   ",
      }),
    ).toBeNull();
    expect(
      parseLocalFeatureClientMessage({
        ...validMessages[2],
        decision: "yes",
      }),
    ).toBeNull();
    expect(
      parseLocalFeatureClientMessage({
        ...validMessages[3],
        answer: "a".repeat(100_001),
      }),
    ).toBeNull();
    expect(
      parseLocalFeatureClientMessage({
        ...validMessages[4],
        requestId: "x".repeat(129),
      }),
    ).toBeNull();
    expect(
      parseLocalFeatureClientMessage({ type: "not_a_local_feature" }),
    ).toBeUndefined();
  });
});
