import { describe, expect, it, vi } from "vitest";
import {
  CodexCoreActionPreconditionError,
  CodexRpcError,
  type CodexProcess,
} from "../codex-process.js";
import { CodexCoreActionsFeatureHandler } from "./codex-core-actions.js";
import type { LocalFeatureClientMessage } from "./protocol.js";
import type {
  LocalFeatureHandleContext,
  LocalFeatureRuntime,
} from "./runtime.js";

describe("CodexCoreActionsFeatureHandler", () => {
  it("routes compact and each review target as correlated inline actions", async () => {
    const sent: unknown[] = [];
    const process = processWith();
    const { context, runtime } = testContext(process, sent);
    const actionAccepted = vi.fn();
    runtime.codexCoreActionAccepted = actionAccepted;
    const handler = new CodexCoreActionsFeatureHandler();

    await handler.handle(
      request({
        type: "codex_compact_request",
        sessionId: "session-1",
        requestId: "compact-1",
      }),
      context,
    );
    await handler.handle(
      request({
        type: "codex_review_request",
        sessionId: "session-1",
        requestId: "review-1",
        target: { type: "baseBranch", branch: "origin/main" },
      }),
      context,
    );

    expect(process.compactThread).toHaveBeenCalledWith({
      signal: context.signal,
      timeoutMs: 15_000,
    });
    expect(process.startInlineReview).toHaveBeenCalledWith(
      { type: "baseBranch", branch: "origin/main" },
      { signal: context.signal, timeoutMs: 15_000 },
    );
    expect(actionAccepted).toHaveBeenNthCalledWith(
      1,
      expect.objectContaining({ id: "session-1" }),
      "compact",
    );
    expect(actionAccepted).toHaveBeenNthCalledWith(
      2,
      expect.objectContaining({ id: "session-1" }),
      "review",
    );
    expect(sent).toEqual([
      {
        type: "codex_action_result",
        sessionId: "session-1",
        requestId: "compact-1",
        action: "compact",
        status: "accepted",
      },
      {
        type: "codex_action_result",
        sessionId: "session-1",
        requestId: "review-1",
        action: "review",
        status: "accepted",
        turnId: "turn-review",
        reviewThreadId: "thread-1",
      },
    ]);
  });

  it("fails closed while the process or the feature session lock is busy", async () => {
    const sent: unknown[] = [];
    const process = processWith({ status: "running" });
    const { context } = testContext(process, sent);
    const handler = new CodexCoreActionsFeatureHandler();

    await handler.handle(
      request({
        type: "codex_compact_request",
        sessionId: "session-1",
        requestId: "busy-1",
      }),
      context,
    );
    expect(process.compactThread).not.toHaveBeenCalled();
    expect(sent).toContainEqual(
      expect.objectContaining({
        requestId: "busy-1",
        status: "rejected",
        errorCode: "session_busy",
      }),
    );

    const queuedSent: unknown[] = [];
    process.status = "idle";
    const { context: queuedContext } = testContext(process, queuedSent, {
      queuedInput: true,
    });
    await handler.handle(
      request({
        type: "codex_compact_request",
        sessionId: "session-1",
        requestId: "queued-1",
      }),
      queuedContext,
    );
    expect(queuedSent).toContainEqual(
      expect.objectContaining({
        requestId: "queued-1",
        status: "rejected",
        errorCode: "session_busy",
      }),
    );

    let release!: () => void;
    process.compactThread.mockImplementationOnce(
      () => new Promise<void>((resolve) => (release = resolve)),
    );
    const first = handler.handle(
      request({
        type: "codex_compact_request",
        sessionId: "session-1",
        requestId: "locked-1",
      }),
      context,
    );
    await vi.waitFor(() => expect(process.compactThread).toHaveBeenCalled());
    await handler.handle(
      request({
        type: "codex_review_request",
        sessionId: "session-1",
        requestId: "locked-2",
        target: { type: "uncommittedChanges" },
      }),
      context,
    );
    expect(sent).toContainEqual(
      expect.objectContaining({
        requestId: "locked-2",
        status: "rejected",
        errorCode: "session_busy",
      }),
    );
    release();
    await first;
  });

  it("uses the host authority gate for mutations but keeps MCP status read-only", async () => {
    const sent: unknown[] = [];
    const process = processWith();
    const { context } = testContext(process, sent, {
      mutationBlock: {
        errorCode: "codex_shared_runtime_turn_owned_elsewhere",
        message: "Desktop owns the active turn.",
      },
    });
    const handler = new CodexCoreActionsFeatureHandler();

    await handler.handle(
      request({
        type: "codex_compact_request",
        sessionId: "session-1",
        requestId: "compact-foreign",
      }),
      context,
    );
    await handler.handle(
      request({
        type: "codex_mcp_status_request",
        sessionId: "session-1",
        requestId: "mcp-read",
      }),
      context,
    );

    expect(process.compactThread).not.toHaveBeenCalled();
    expect(process.listMcpServerStatus).toHaveBeenCalledOnce();
    expect(sent).toEqual([
      expect.objectContaining({
        requestId: "compact-foreign",
        status: "rejected",
        errorCode: "codex_shared_runtime_turn_owned_elsewhere",
      }),
      expect.objectContaining({
        requestId: "mcp-read",
        status: "completed",
      }),
    ]);
  });

  it("keeps using the process-owned admission lock after the RPC ack", async () => {
    const sent: unknown[] = [];
    const process = processWith();
    process.compactThread.mockImplementationOnce(async () => {
      process.hasPendingCoreAction = true;
    });
    const { context } = testContext(process, sent);
    const handler = new CodexCoreActionsFeatureHandler();

    await handler.handle(
      request({
        type: "codex_compact_request",
        sessionId: "session-1",
        requestId: "compact-acked",
      }),
      context,
    );
    await handler.handle(
      request({
        type: "codex_review_request",
        sessionId: "session-1",
        requestId: "review-during-ack-window",
        target: { type: "uncommittedChanges" },
      }),
      context,
    );
    await handler.handle(
      request({
        type: "codex_mcp_status_request",
        sessionId: "session-1",
        requestId: "mcp-during-ack-window",
      }),
      context,
    );

    expect(process.startInlineReview).not.toHaveBeenCalled();
    expect(process.listMcpServerStatus).toHaveBeenCalledOnce();
    expect(sent).toEqual([
      expect.objectContaining({
        requestId: "compact-acked",
        status: "accepted",
      }),
      expect.objectContaining({
        requestId: "review-during-ack-window",
        status: "rejected",
        errorCode: "session_busy",
      }),
      expect.objectContaining({
        requestId: "mcp-during-ack-window",
        status: "completed",
      }),
    ]);
  });

  it("maps method-not-found to unsupported and preserves precondition errors", async () => {
    const sent: unknown[] = [];
    const process = processWith();
    process.compactThread.mockRejectedValueOnce(
      new CodexRpcError(
        "thread/compact/start",
        "Method not found: thread/compact/start",
        -32601,
      ),
    );
    process.startInlineReview.mockRejectedValueOnce(
      new CodexCoreActionPreconditionError("session_busy", "Codex became busy"),
    );
    const { context } = testContext(process, sent);
    const handler = new CodexCoreActionsFeatureHandler();

    await handler.handle(
      request({
        type: "codex_compact_request",
        sessionId: "session-1",
        requestId: "unsupported-1",
      }),
      context,
    );
    await handler.handle(
      request({
        type: "codex_review_request",
        sessionId: "session-1",
        requestId: "race-1",
        target: { type: "custom", instructions: "Review safety" },
      }),
      context,
    );

    expect(sent).toContainEqual(
      expect.objectContaining({
        requestId: "unsupported-1",
        status: "unsupported",
        errorCode: "unsupported_backend",
      }),
    );
    expect(sent).toContainEqual(
      expect.objectContaining({
        requestId: "race-1",
        status: "rejected",
        errorCode: "session_busy",
      }),
    );
  });

  it("returns only bounded, whitelisted MCP status fields", async () => {
    const sent: unknown[] = [];
    const rawTools = Object.fromEntries(
      Array.from({ length: 70 }, (_, index) => [
        `tool-${index}`,
        {
          name: `tool-${index}`,
          title: `Tool ${index}`,
          description: "d".repeat(700),
          inputSchema: { secret: true },
          _meta: { secret: true },
        },
      ]),
    );
    const process = processWith();
    process.listMcpServerStatus.mockResolvedValueOnce({
      data: [
        {
          name: "filesystem",
          authStatus: "oAuth",
          serverInfo: {
            name: "Filesystem MCP",
            title: "Filesystem",
            version: "1.0.0",
            description: "Server description",
            websiteUrl: "javascript:alert(1)",
            icons: [{ src: "secret" }],
          },
          tools: rawTools,
          resources: [{ uri: "file:///secret" }],
        },
      ],
      nextCursor: "more",
    });
    const { context } = testContext(process, sent);

    await new CodexCoreActionsFeatureHandler().handle(
      request({
        type: "codex_mcp_status_request",
        sessionId: "session-1",
        requestId: "mcp-1",
      }),
      context,
    );

    expect(process.listMcpServerStatus).toHaveBeenCalledWith({
      signal: context.signal,
      timeoutMs: 12_000,
    });
    const response = sent[0] as Record<string, any>;
    expect(response).toMatchObject({
      type: "codex_mcp_status_result",
      sessionId: "session-1",
      requestId: "mcp-1",
      status: "completed",
      serversTruncated: true,
    });
    expect(response.servers[0].tools).toHaveLength(64);
    expect(response.servers[0].toolCount).toBe(70);
    expect(response.servers[0].toolsTruncated).toBe(true);
    expect(response.servers[0].tools[0].description).toHaveLength(512);
    expect(response.servers[0].tools[0]).not.toHaveProperty("inputSchema");
    expect(response.servers[0]).not.toHaveProperty("resources");
    expect(response.servers[0].serverInfo).not.toHaveProperty("icons");
    expect(response.servers[0].serverInfo).not.toHaveProperty("websiteUrl");
    expect(Buffer.byteLength(JSON.stringify(response), "utf8")).toBeLessThan(
      256 * 1024 + 4096,
    );
  });

  it("reports MCP method-not-found without pretending the list is empty", async () => {
    const sent: unknown[] = [];
    const process = processWith();
    process.listMcpServerStatus.mockRejectedValueOnce(
      new CodexRpcError("mcpServerStatus/list", "Method not found", -32601),
    );
    const { context } = testContext(process, sent);

    await new CodexCoreActionsFeatureHandler().handle(
      request({
        type: "codex_mcp_status_request",
        sessionId: "session-1",
        requestId: "mcp-old-server",
      }),
      context,
    );

    expect(sent).toEqual([
      expect.objectContaining({
        type: "codex_mcp_status_result",
        requestId: "mcp-old-server",
        status: "unsupported",
        servers: [],
        errorCode: "unsupported_backend",
      }),
    ]);
  });

  it("rejects a missing or non-Codex runtime before calling any action", async () => {
    const sent: unknown[] = [];
    const process = processWith();
    const { context } = testContext(process, sent, { provider: "claude" });

    await new CodexCoreActionsFeatureHandler().handle(
      request({
        type: "codex_review_request",
        sessionId: "session-1",
        requestId: "wrong-provider",
        target: { type: "uncommittedChanges" },
      }),
      context,
    );

    expect(process.startInlineReview).not.toHaveBeenCalled();
    expect(sent).toEqual([
      expect.objectContaining({
        requestId: "wrong-provider",
        status: "rejected",
        errorCode: "session_not_found",
      }),
    ]);
  });
});

function request(value: Record<string, unknown>): LocalFeatureClientMessage {
  return value as LocalFeatureClientMessage;
}

function processWith(options: { status?: string } = {}) {
  return {
    status: options.status ?? "idle",
    sessionId: "thread-1",
    hasPendingCoreAction: false,
    compactThread: vi.fn(async () => {}),
    startInlineReview: vi.fn(async () => ({
      turnId: "turn-review",
      reviewThreadId: "thread-1",
    })),
    listMcpServerStatus: vi.fn(async () => ({
      data: [],
      nextCursor: null,
    })),
  };
}

function testContext(
  process: ReturnType<typeof processWith>,
  sent: unknown[],
  options: {
    provider?: string;
    supports?: boolean;
    sessionStatus?: string;
    queuedInput?: boolean;
    permissionRestartInProgress?: boolean;
    mutationBlock?: { errorCode: string; message: string };
  } = {},
): {
  context: LocalFeatureHandleContext;
  runtime: LocalFeatureRuntime;
} {
  const runtime: LocalFeatureRuntime = {
    getSession: (sessionId) =>
      sessionId === "session-1"
        ? {
            id: sessionId,
            provider: options.provider ?? "codex",
            process: process as unknown as CodexProcess,
            ...(options.sessionStatus ? { status: options.sessionStatus } : {}),
            ...(options.queuedInput
              ? { codexQueuedInput: { itemId: "queued" } }
              : {}),
            ...(options.permissionRestartInProgress
              ? { permissionRestartInProgress: true }
              : {}),
          }
        : undefined,
    getCodexThreadId: () => "thread-1",
    getActiveCodexProcess: () => null,
    createStandaloneCodexProcess: async () => {
      throw new Error("not used");
    },
    send: (_client, message) => sent.push(message),
    supports: () => options.supports ?? true,
    codexThreadMutationBlock: () => options.mutationBlock ?? null,
  };
  return {
    runtime,
    context: {
      client: {},
      signal: new AbortController().signal,
      runtime,
    },
  };
}
