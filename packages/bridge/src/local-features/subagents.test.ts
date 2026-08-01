import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";
import { CodexRpcError, type CodexProcess } from "../codex-process.js";
import type { ServerMessage } from "../parser.js";
import type { CodexSubagentInfo as CodexThreadSummary } from "./protocol.js";
import type {
  LocalFeatureHandleContext,
  LocalFeatureRuntime,
} from "./runtime.js";
import {
  childThreadToServerMessages,
  CodexSubagentService,
  descendantsOf,
  limitSubagentHistoryResponse,
  MAX_SUBAGENT_HISTORY_MESSAGES,
  SubagentsFeatureHandler,
} from "./subagents.js";

function thread(id: string, parentThreadId: string | null): CodexThreadSummary {
  return {
    id,
    sessionId: "tree",
    parentThreadId,
    forkedFromId: null,
    preview: id,
    createdAt: 1,
    updatedAt: 1,
    cwd: "/tmp",
    status: "idle",
    activeFlags: [],
    source: "subAgentThreadSpawn",
    threadSource: "subagent",
    agentNickname: null,
    agentRole: null,
    agentPath: null,
    gitBranch: null,
    name: null,
    ephemeral: false,
  };
}

function processWith(overrides: Record<string, unknown>): CodexProcess {
  const listThreads =
    (overrides.listThreads as ReturnType<typeof vi.fn> | undefined) ??
    vi.fn(async () => ({ data: [], nextCursor: null }));
  const listThreadItems =
    (overrides.listThreadItems as ReturnType<typeof vi.fn> | undefined) ??
    vi
      .fn()
      .mockRejectedValue(
        new CodexRpcError(
          "thread/items/list",
          "Method not found: thread/items/list",
          -32601,
        ),
      );
  const listThreadTurns =
    (overrides.listThreadTurns as ReturnType<typeof vi.fn> | undefined) ??
    vi
      .fn()
      .mockRejectedValue(
        new CodexRpcError(
          "thread/turns/list",
          "Method not found: thread/turns/list",
          -32601,
        ),
      );
  const readThread =
    (overrides.readThread as ReturnType<typeof vi.fn> | undefined) ?? vi.fn();
  return {
    requestReadOnlyRpc: vi.fn(
      async (
        method: string,
        params: Record<string, unknown>,
        options: unknown,
      ) => {
        if (method === "thread/list") return listThreads(params, options);
        if (method === "thread/items/list") {
          return listThreadItems(
            {
              threadId: params.threadId,
              limit: params.limit,
              cursor: params.cursor,
              sortOrder: params.sortDirection,
            },
            options,
          );
        }
        if (method === "thread/turns/list") {
          return listThreadTurns(
            {
              threadId: params.threadId,
              limit: params.limit,
              cursor: params.cursor,
              sortOrder: params.sortDirection,
            },
            options,
          );
        }
        if (method === "thread/read") {
          return {
            thread: await readThread(
              params.threadId,
              params.includeTurns,
              options,
            ),
          };
        }
        throw new Error(`Unexpected RPC: ${method}`);
      },
    ),
  } as unknown as CodexProcess;
}

function handlerProcess(
  overrides: Record<string, unknown>,
  options: { running?: boolean } = {},
): CodexProcess {
  return Object.assign(processWith(overrides), {
    isRunning: options.running ?? true,
    stop: vi.fn(),
  }) as unknown as CodexProcess;
}

function assistantText(id: string, text: string): ServerMessage {
  return {
    type: "assistant",
    message: {
      id,
      role: "assistant",
      content: [{ type: "text", text }],
      model: "",
    },
  };
}

describe("CodexSubagentService", () => {
  it("keeps nested descendants and excludes unrelated subagents", () => {
    expect(
      descendantsOf(
        [
          thread("child", "root"),
          thread("grandchild", "child"),
          thread("other", "foreign"),
        ],
        "root",
      ).map((entry) => entry.id),
    ).toEqual(["child", "grandchild"]);
  });

  it("uses the official DB-backed descendant filter with explicit subagent sources", async () => {
    const listThreads = vi.fn(async (params: { cursor?: string | null }) =>
      params.cursor === null
        ? {
            data: [thread("newer", "server-authoritative")],
            nextCursor: "page-2",
          }
        : {
            data: [thread("older", "server-authoritative")],
            nextCursor: null,
          },
    );
    const service = new CodexSubagentService();

    await expect(
      service.list(processWith({ listThreads }), "root"),
    ).resolves.toEqual({
      subagents: [
        thread("newer", "server-authoritative"),
        thread("older", "server-authoritative"),
      ],
      truncated: false,
    });
    expect(listThreads).toHaveBeenNthCalledWith(
      1,
      expect.objectContaining({
        ancestorThreadId: "root",
        cursor: null,
        limit: 100,
        sourceKinds: expect.arrayContaining(["subAgentThreadSpawn"]),
        useStateDbOnly: true,
      }),
      expect.objectContaining({ signal: expect.any(AbortSignal) }),
    );
    expect(listThreads).toHaveBeenNthCalledWith(
      2,
      expect.objectContaining({ ancestorThreadId: "root", cursor: "page-2" }),
      expect.objectContaining({ signal: expect.any(AbortSignal) }),
    );
  });

  it("retries without useStateDbOnly on older app-server versions", async () => {
    const listThreads = vi
      .fn()
      .mockRejectedValueOnce(
        new CodexRpcError(
          "thread/list",
          "Invalid parameter useStateDbOnly: unknown field",
          -32602,
        ),
      )
      .mockResolvedValueOnce({
        data: [thread("child", "root")],
        nextCursor: null,
      })
      .mockResolvedValueOnce({ data: [], nextCursor: null });

    await expect(
      new CodexSubagentService().list(processWith({ listThreads }), "root"),
    ).resolves.toMatchObject({
      subagents: [{ id: "child" }],
      truncated: false,
    });
    expect(listThreads).toHaveBeenCalledTimes(3);
    expect(listThreads.mock.calls[0]?.[0]).toMatchObject({
      useStateDbOnly: true,
    });
    expect(listThreads.mock.calls[1]?.[0]).not.toHaveProperty("useStateDbOnly");
    expect(listThreads.mock.calls[1]?.[0]).toMatchObject({
      ancestorThreadId: "root",
      sourceKinds: expect.arrayContaining(["subAgentThreadSpawn"]),
    });
  });

  it("keeps descendants scoped to the exact conversation across archive states", async () => {
    const currentChild = {
      ...thread("current-child", "current"),
      updatedAt: 3,
    };
    const archivedCurrentChild = {
      ...thread("archived-current-child", "current"),
      updatedAt: 2,
    };
    const previousChild = {
      ...thread("previous-child", "previous"),
      updatedAt: 1,
    };
    const readThread = vi.fn();
    const listThreads = vi.fn(
      async (params: { ancestorThreadId?: string; archived?: boolean }) => ({
        data:
          params.ancestorThreadId === "current"
            ? params.archived
              ? [archivedCurrentChild]
              : [currentChild]
            : params.archived
              ? []
              : [previousChild],
        nextCursor: null,
      }),
    );

    await expect(
      new CodexSubagentService().list(
        processWith({ readThread, listThreads }),
        "current",
      ),
    ).resolves.toEqual({
      subagents: [currentChild, archivedCurrentChild],
      truncated: false,
    });
    expect(readThread).not.toHaveBeenCalled();
    expect(listThreads).toHaveBeenCalledTimes(2);
    expect(listThreads.mock.calls.map(([params]) => params)).toEqual([
      expect.objectContaining({
        ancestorThreadId: "current",
        archived: false,
      }),
      expect.objectContaining({
        ancestorThreadId: "current",
        archived: true,
      }),
    ]);
  });

  it("replaces the first-message preview with the latest bounded exchange", async () => {
    const directory = await mkdtemp(
      join(tmpdir(), "ccpocket-subagent-preview-"),
    );
    try {
      const filePath = join(directory, "child.jsonl");
      await writeFile(
        filePath,
        [
          JSON.stringify({
            timestamp: "2026-07-20T00:00:00.000Z",
            type: "session_meta",
            payload: {
              id: "child",
              cwd: "/tmp",
              source: { subAgent: "other" },
            },
          }),
          JSON.stringify({
            timestamp: "2026-07-20T00:00:01.000Z",
            type: "event_msg",
            payload: { type: "user_message", message: "shared first prompt" },
          }),
          JSON.stringify({
            timestamp: "2026-07-20T00:00:02.000Z",
            type: "event_msg",
            payload: { type: "user_message", message: "latest question" },
          }),
          JSON.stringify({
            timestamp: "2026-07-20T00:00:03.000Z",
            type: "event_msg",
            payload: {
              type: "agent_message",
              message: "latest answer",
              phase: "final_answer",
            },
          }),
        ].join("\n"),
        "utf8",
      );
      const rawThread = {
        ...thread("child", "root"),
        preview: "shared first prompt",
        path: filePath,
      };
      const listThreads = vi.fn(async (params: { archived?: boolean }) => ({
        data: params.archived ? [] : [rawThread],
        nextCursor: null,
      }));

      const result = await new CodexSubagentService().list(
        processWith({
          readThread: vi.fn(async () => ({ forkedFromId: null })),
          listThreads,
        }),
        "root",
      );

      expect(result.subagents[0]?.preview).toBe(
        "latest question\nlatest answer",
      );
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  it("does not pair an inherited first prompt with a later answer", async () => {
    const directory = await mkdtemp(
      join(tmpdir(), "ccpocket-subagent-answer-"),
    );
    try {
      const filePath = join(directory, "child.jsonl");
      await writeFile(
        filePath,
        [
          JSON.stringify({
            timestamp: "2026-07-20T00:00:00.000Z",
            type: "session_meta",
            payload: {
              id: "child",
              cwd: "/tmp",
              source: { subAgent: "other" },
            },
          }),
          JSON.stringify({
            timestamp: "2026-07-20T00:00:01.000Z",
            type: "event_msg",
            payload: { type: "user_message", message: "shared first prompt" },
          }),
          JSON.stringify({
            timestamp: "2026-07-20T00:00:02.000Z",
            type: "event_msg",
            payload: {
              type: "agent_message",
              message: "latest child answer",
              phase: "final_answer",
            },
          }),
        ].join("\n"),
        "utf8",
      );
      const rawThread = {
        ...thread("child", "root"),
        preview: "shared first prompt",
        path: filePath,
      };
      const listThreads = vi.fn(async (params: { archived?: boolean }) => ({
        data: params.archived ? [] : [rawThread],
        nextCursor: null,
      }));

      const result = await new CodexSubagentService().list(
        processWith({
          readThread: vi.fn(async () => ({ forkedFromId: null })),
          listThreads,
        }),
        "root",
      );

      expect(result.subagents[0]?.preview).toBe("latest child answer");
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  it("falls back to a bounded local scan only for an explicit unsupported ancestor parameter", async () => {
    const listThreads = vi
      .fn()
      .mockRejectedValueOnce(
        new CodexRpcError(
          "thread/list",
          "Invalid parameter ancestorThreadId: unknown field",
          -32602,
        ),
      )
      .mockResolvedValueOnce({
        data: [thread("child", "root"), thread("other", "foreign")],
        nextCursor: null,
      })
      .mockResolvedValueOnce({
        data: [],
        nextCursor: null,
      });
    const service = new CodexSubagentService();

    await expect(
      service.list(processWith({ listThreads }), "root"),
    ).resolves.toEqual({
      subagents: [thread("child", "root")],
      truncated: false,
    });
    expect(listThreads).toHaveBeenCalledTimes(3);
    expect(listThreads.mock.calls[1]?.[0]).not.toHaveProperty(
      "ancestorThreadId",
    );
    expect(listThreads.mock.calls[1]?.[0]).toMatchObject({
      sourceKinds: expect.arrayContaining(["subAgentThreadSpawn"]),
    });
  });

  it("prioritizes JSON-RPC method-not-found for old ancestor-filter servers", async () => {
    const listThreads = vi
      .fn()
      .mockRejectedValueOnce(
        new CodexRpcError("thread/list", "not available", -32601),
      )
      .mockResolvedValueOnce({
        data: [thread("child", "root")],
        nextCursor: null,
      })
      .mockResolvedValueOnce({
        data: [],
        nextCursor: null,
      });

    await expect(
      new CodexSubagentService().list(processWith({ listThreads }), "root"),
    ).resolves.toMatchObject({
      subagents: [{ id: "child" }],
      truncated: false,
    });
    expect(listThreads).toHaveBeenCalledTimes(3);
  });

  it("does not hide network errors behind the local fallback", async () => {
    const listThreads = vi.fn().mockRejectedValue(new Error("socket closed"));
    const service = new CodexSubagentService();

    await expect(
      service.list(processWith({ listThreads }), "root"),
    ).rejects.toThrow("socket closed");
    expect(listThreads).toHaveBeenCalledTimes(1);
  });

  it("does not fallback for an invalid parameter error that does not identify ancestorThreadId", async () => {
    const listThreads = vi
      .fn()
      .mockRejectedValue(new Error("Invalid parameter sourceKinds"));
    const service = new CodexSubagentService();

    await expect(
      service.list(processWith({ listThreads }), "root"),
    ).rejects.toThrow("sourceKinds");
    expect(listThreads).toHaveBeenCalledTimes(1);
  });

  it("bounds list pagination and exposes only a truncated flag", async () => {
    const listThreads = vi.fn(async (params: { cursor?: string | null }) => {
      const page = params.cursor === null ? 0 : Number(params.cursor);
      return {
        data: Array.from({ length: 100 }, (_, index) =>
          thread(`child-${page}-${index}`, "root"),
        ),
        nextCursor: String(page + 1),
      };
    });
    const service = new CodexSubagentService();

    const result = await service.list(processWith({ listThreads }), "root");
    expect(result.subagents).toHaveLength(2000);
    expect(result).toEqual({
      subagents: expect.any(Array),
      truncated: true,
    });
    expect(result).not.toHaveProperty("nextCursor");
    expect(listThreads).toHaveBeenCalledTimes(20);
  });

  it("rejects a non-descendant before any history read", async () => {
    const readThread = vi.fn();
    const listThreadTurns = vi.fn();
    const listThreadItems = vi.fn();
    const process = processWith({
      listThreads: vi
        .fn()
        .mockRejectedValueOnce(
          new CodexRpcError(
            "thread/list",
            "Invalid parameter ancestorThreadId",
            -32602,
          ),
        )
        .mockResolvedValueOnce({
          data: [thread("other", "foreign")],
          nextCursor: null,
        })
        .mockResolvedValueOnce({
          data: [],
          nextCursor: null,
        }),
      listThreadTurns,
      listThreadItems,
      readThread,
    });
    const service = new CodexSubagentService();

    await expect(
      service.readVerified(process, "root", "other"),
    ).rejects.toThrow("not a subagent descendant");
    expect(listThreadTurns).not.toHaveBeenCalled();
    expect(listThreadItems).not.toHaveBeenCalled();
    expect(readThread).not.toHaveBeenCalled();
  });

  it("prefers bounded newest-first item pagination and returns chronological messages", async () => {
    const listThreadItems = vi.fn(
      async (params: { cursor: string | null; sortOrder: string }) => {
        expect(params.sortOrder).toBe("desc");
        return params.cursor === null
          ? {
              data: [{ type: "agentMessage", id: "a1", text: "newest" }],
              nextCursor: "older",
            }
          : {
              data: [
                {
                  type: "userMessage",
                  id: "u1",
                  content: [{ type: "text", text: "oldest" }],
                },
              ],
              nextCursor: null,
            };
      },
    );
    const listThreadTurns = vi.fn();
    const readThread = vi.fn();
    const process = processWith({
      listThreads: vi.fn(async () => ({
        data: [thread("child", "root")],
        nextCursor: null,
      })),
      listThreadTurns,
      listThreadItems,
      readThread,
    });
    const service = new CodexSubagentService();

    const result = await service.readVerified(process, "root", "child");
    expect(result.messages).toMatchObject([
      { type: "user_input", text: "oldest" },
      { type: "assistant", message: { content: [{ text: "newest" }] } },
    ]);
    expect(result.truncated).toBe(false);
    expect(listThreadItems).toHaveBeenCalledTimes(2);
    expect(listThreadTurns).not.toHaveBeenCalled();
    expect(readThread).not.toHaveBeenCalled();
  });

  it("uses full-turn pagination when item pagination is explicitly unsupported", async () => {
    const listThreadItems = vi
      .fn()
      .mockRejectedValue(new Error("Method not found: thread/items/list"));
    const listThreadTurns = vi.fn(async () => ({
      data: [
        {
          items: [
            {
              type: "commandExecution",
              id: "cmd-1",
              command: "git status",
              cwd: "/repo",
              status: "completed",
              exitCode: 0,
              aggregatedOutput: "clean",
            },
          ],
        },
      ],
      nextCursor: null,
    }));
    const readThread = vi.fn();
    const process = processWith({
      listThreads: vi.fn(async () => ({
        data: [thread("child", "root")],
        nextCursor: null,
      })),
      listThreadTurns,
      listThreadItems,
      readThread,
    });
    const service = new CodexSubagentService();

    const result = await service.readVerified(process, "root", "child");
    expect(result.messages).toMatchObject([
      {
        type: "assistant",
        message: {
          content: [
            {
              type: "tool_use",
              name: "Bash",
              input: { command: "git status", cwd: "/repo" },
            },
          ],
        },
      },
      {
        type: "tool_result",
        toolUseId: "cmd-1",
        content: "status: completed\nexitCode: 0\nclean",
      },
    ]);
    expect(listThreadItems).toHaveBeenCalledOnce();
    expect(listThreadTurns).toHaveBeenCalledOnce();
    expect(listThreadTurns.mock.calls[0]?.[0]).not.toHaveProperty("itemsView");
    expect(readThread).not.toHaveBeenCalled();
  });

  it("refuses an unbounded legacy read when both pagination adapters are unsupported", async () => {
    const listThreadTurns = vi
      .fn()
      .mockRejectedValue(
        new CodexRpcError(
          "thread/turns/list",
          "Method not found: thread/turns/list",
          -32601,
        ),
      );
    const listThreadItems = vi
      .fn()
      .mockRejectedValue(new Error("Unsupported item/list method"));
    const readThread = vi.fn();
    const process = processWith({
      listThreads: vi.fn(async () => ({
        data: [thread("child", "root")],
        nextCursor: null,
      })),
      listThreadTurns,
      listThreadItems,
      readThread,
    });
    const service = new CodexSubagentService();

    await expect(
      service.readVerified(process, "root", "child"),
    ).rejects.toThrow(
      "Subagent history pagination is not supported by this Codex app-server",
    );
    expect(readThread).not.toHaveBeenCalled();
  });

  it("does not turn paginated-history network failures into legacy reads", async () => {
    const listThreadItems = vi
      .fn()
      .mockRejectedValue(new Error("item/list connection reset"));
    const listThreadTurns = vi.fn();
    const readThread = vi.fn();
    const process = processWith({
      listThreads: vi.fn(async () => ({
        data: [thread("child", "root")],
        nextCursor: null,
      })),
      listThreadTurns,
      listThreadItems,
      readThread,
    });
    const service = new CodexSubagentService();

    await expect(
      service.readVerified(process, "root", "child"),
    ).rejects.toThrow("connection reset");
    expect(listThreadTurns).not.toHaveBeenCalled();
    expect(readThread).not.toHaveBeenCalled();
  });

  it("applies one abortable total deadline to the whole list operation", async () => {
    vi.useFakeTimers();
    try {
      const process = {
        requestReadOnlyRpc: vi.fn(
          (
            _method: string,
            _params: unknown,
            options: { signal: AbortSignal },
          ) =>
            new Promise((_resolve, reject) => {
              options.signal.addEventListener(
                "abort",
                () => reject(options.signal.reason),
                { once: true },
              );
            }),
        ),
      } as unknown as CodexProcess;
      const result = new CodexSubagentService().list(process, "root", {
        timeoutMs: 25,
      });
      const rejection = expect(result).rejects.toThrow("deadline exceeded");
      await vi.advanceTimersByTimeAsync(25);
      await rejection;
      expect(process.requestReadOnlyRpc).toHaveBeenCalledTimes(1);
    } finally {
      vi.useRealTimers();
    }
  });
});

describe("childThreadToServerMessages", () => {
  it("purely preserves user, assistant, thinking, tool input, and tool result text", () => {
    const messages = childThreadToServerMessages({
      turns: [
        {
          items: [
            {
              type: "userMessage",
              id: "u1",
              content: [{ type: "text", text: "inspect" }],
            },
            {
              type: "reasoning",
              id: "r1",
              summary: ["thought"],
              content: [],
            },
            { type: "agentMessage", id: "a1", text: "answer" },
            {
              type: "commandExecution",
              id: "cmd1",
              command: "pwd",
              cwd: "/repo",
              status: "completed",
              aggregatedOutput: "/repo",
              exitCode: 0,
            },
          ],
        },
      ],
    });

    expect(messages).toMatchObject([
      { type: "user_input", text: "inspect" },
      {
        type: "assistant",
        message: { content: [{ type: "thinking", thinking: "thought" }] },
      },
      {
        type: "assistant",
        message: { content: [{ type: "text", text: "answer" }] },
      },
      {
        type: "assistant",
        message: {
          content: [
            {
              type: "tool_use",
              input: { command: "pwd", cwd: "/repo" },
            },
          ],
        },
      },
      { type: "tool_result", content: "status: completed\nexitCode: 0\n/repo" },
    ]);
    expect(JSON.stringify(messages)).not.toContain("imagePaths");
    expect(JSON.stringify(messages)).not.toContain("artifact");
  });
});

describe("SubagentsFeatureHandler", () => {
  it("reads a detached Desktop thread without resolving or acquiring a runtime session", async () => {
    const listThreads = vi.fn(async (params: { archived?: boolean }) => ({
      data: params.archived ? [] : [thread("child", "provider-parent")],
      nextCursor: null,
    }));
    const listThreadItems = vi.fn(async () => ({
      data: [{ type: "agentMessage", id: "answer-1", text: "done" }],
      nextCursor: null,
    }));
    const process = handlerProcess({ listThreads, listThreadItems });
    const sent: unknown[] = [];
    const getSession = vi.fn();
    const acquireWriterOwnership = vi.fn();
    const createStandaloneCodexProcess = vi.fn(async () => process);
    const runtime = {
      codexSourceId: "source-1",
      getSession,
      getCodexThreadId: vi.fn(),
      getActiveCodexProcess: () => null,
      createStandaloneCodexProcess,
      createPersistedCodexChildSession: acquireWriterOwnership,
      hasCodexQueuedInput: () => false,
      send: (_client: object, message: unknown) => sent.push(message),
      supports: (_client: object, type: string) =>
        type === "detached_subagent_list" ||
        type === "detached_subagent_history",
    } as unknown as LocalFeatureRuntime;
    const context: LocalFeatureHandleContext = {
      client: {},
      signal: new AbortController().signal,
      runtime,
    };

    const handler = new SubagentsFeatureHandler();
    await handler.handle(
      {
        type: "get_detached_subagents",
        ownerSessionId: "pane-1",
        providerThreadId: "provider-parent",
        codexSourceId: "source-1",
        requestId: "request-1",
      },
      context,
    );
    await handler.handle(
      {
        type: "get_detached_subagent_history",
        ownerSessionId: "pane-1",
        providerThreadId: "provider-parent",
        codexSourceId: "source-1",
        threadId: "child",
        requestId: "history-1",
      },
      context,
    );

    expect(sent).toEqual([
      expect.objectContaining({
        type: "detached_subagent_list",
        ownerSessionId: "pane-1",
        providerThreadId: "provider-parent",
        codexSourceId: "source-1",
        requestId: "request-1",
        subagents: [expect.objectContaining({ id: "child" })],
      }),
      expect.objectContaining({
        type: "detached_subagent_history",
        ownerSessionId: "pane-1",
        providerThreadId: "provider-parent",
        codexSourceId: "source-1",
        requestId: "history-1",
        threadId: "child",
        messages: [expect.objectContaining({ type: "assistant" })],
      }),
    ]);
    expect(getSession).not.toHaveBeenCalled();
    expect(acquireWriterOwnership).not.toHaveBeenCalled();
    expect(createStandaloneCodexProcess).toHaveBeenCalledTimes(2);
    expect(createStandaloneCodexProcess).toHaveBeenCalledWith(15_000);
    expect(process.stop).toHaveBeenCalledTimes(2);
    const readMethods = (
      process.requestReadOnlyRpc as ReturnType<typeof vi.fn>
    ).mock.calls.map(([method]) => method);
    expect(readMethods).toEqual([
      "thread/list",
      "thread/list",
      "thread/list",
      "thread/list",
      "thread/items/list",
    ]);
    expect(readMethods).not.toContain("thread/resume");
    expect(readMethods).not.toContain("thread/start");
    expect(readMethods).not.toContain("thread/fork");
  });

  it("rejects a detached source mismatch before opening any provider reader", async () => {
    const process = handlerProcess({});
    const sent: unknown[] = [];
    const getSession = vi.fn();
    const createStandaloneCodexProcess = vi.fn(async () => process);
    const runtime = {
      codexSourceId: "authenticated-source",
      getSession,
      getCodexThreadId: vi.fn(),
      getActiveCodexProcess: vi.fn(() => null),
      createStandaloneCodexProcess,
      hasCodexQueuedInput: () => false,
      send: (_client: object, message: unknown) => sent.push(message),
      supports: () => true,
    } as unknown as LocalFeatureRuntime;

    await new SubagentsFeatureHandler().handle(
      {
        type: "get_detached_subagents",
        ownerSessionId: "pane-1",
        providerThreadId: "provider-parent",
        codexSourceId: "other-source",
        requestId: "request-1",
      },
      {
        client: {},
        signal: new AbortController().signal,
        runtime,
      },
    );

    expect(sent).toEqual([
      expect.objectContaining({
        type: "detached_subagent_list",
        errorCode: "codex_source_mismatch",
        codexSourceId: "authenticated-source",
        subagents: [],
      }),
    ]);
    expect(getSession).not.toHaveBeenCalled();
    expect(runtime.getActiveCodexProcess).not.toHaveBeenCalled();
    expect(createStandaloneCodexProcess).not.toHaveBeenCalled();
    expect(process.requestReadOnlyRpc).not.toHaveBeenCalled();
  });

  it("keeps detached Desktop activity summaries fenced to source and parent", async () => {
    let running = true;
    const listThreads = vi.fn(async (params: { archived?: boolean }) => ({
      data: params.archived
        ? []
        : [
            {
              ...thread("desktop-child", "desktop-parent"),
              status: running ? "active" : "idle",
              updatedAt: running ? 2 : 3,
            },
          ],
      nextCursor: null,
    }));
    const process = handlerProcess({ listThreads });
    const sent: unknown[] = [];
    const client = {};
    const runtime = {
      codexSourceId: "source-1",
      getSession: vi.fn(),
      getCodexThreadId: vi.fn(),
      getActiveCodexProcess: vi.fn(() => process),
      createStandaloneCodexProcess: vi.fn(),
      hasCodexQueuedInput: () => false,
      isClientOpen: () => true,
      send: (_client: object, message: unknown) => sent.push(message),
      supports: (_client: object, type: string) =>
        type === "detached_subagent_list" ||
        type === "subagent_activity_summary_v1",
    } as unknown as LocalFeatureRuntime;
    const context: LocalFeatureHandleContext = {
      client,
      signal: new AbortController().signal,
      runtime,
    };
    const handler = new SubagentsFeatureHandler();

    await handler.handle(
      {
        type: "get_detached_subagents",
        ownerSessionId: "pane-1",
        providerThreadId: "desktop-parent",
        codexSourceId: "source-1",
        requestId: "list-1",
      },
      context,
    );
    expect(sent.at(-1)).toEqual(
      expect.objectContaining({
        type: "subagent_activity_summary_v1",
        scope: "provider",
        ownerSessionId: "pane-1",
        providerThreadId: "desktop-parent",
        codexSourceId: "source-1",
        listRequestId: "list-1",
        activeCount: 1,
      }),
    );
    await handler.handle(
      {
        type: "watch_detached_subagent_activity_v1",
        ownerSessionId: "pane-1",
        providerThreadId: "desktop-parent",
        codexSourceId: "source-1",
        listRequestId: "list-1",
        subscriptionId: "watch-1",
      },
      context,
    );

    running = false;
    handler.sessionCatalogChanged({
      revision: 2,
      provider: "codex",
      // A new descendant is not in the previous known-id set yet.
      providerSessionId: "new-or-unrelated-thread",
    });
    await vi.waitFor(
      () => {
        expect(sent.at(-1)).toEqual(
          expect.objectContaining({
            type: "subagent_activity_summary_v1",
            scope: "provider",
            codexSourceId: "source-1",
            subscriptionId: "watch-1",
            activeCount: 0,
          }),
        );
      },
      { timeout: 2_000 },
    );
  });

  it("keeps the attached runtime-session read path unchanged", async () => {
    const listThreads = vi.fn(async (params: { archived?: boolean }) => ({
      data: params.archived ? [] : [thread("child", "runtime-parent")],
      nextCursor: null,
    }));
    const process = handlerProcess({ listThreads });
    const sent: unknown[] = [];
    const getSession = vi.fn(() => ({
      id: "runtime-session",
      provider: "codex",
      process,
    }));
    const createStandaloneCodexProcess = vi.fn();
    const runtime = {
      codexSourceId: "source-1",
      getSession,
      getCodexThreadId: vi.fn(() => "runtime-parent"),
      getActiveCodexProcess: vi.fn(() => null),
      createStandaloneCodexProcess,
      hasCodexQueuedInput: () => false,
      send: (_client: object, message: unknown) => sent.push(message),
      supports: (_client: object, type: string) => type === "subagent_list",
    } as unknown as LocalFeatureRuntime;

    await new SubagentsFeatureHandler().handle(
      {
        type: "get_subagents",
        sessionId: "runtime-session",
        requestId: "request-1",
      },
      {
        client: {},
        signal: new AbortController().signal,
        runtime,
      },
    );

    expect(getSession).toHaveBeenCalledWith("runtime-session");
    expect(createStandaloneCodexProcess).not.toHaveBeenCalled();
    expect(process.stop).not.toHaveBeenCalled();
    expect(sent).toEqual([
      expect.objectContaining({
        type: "subagent_list",
        sessionId: "runtime-session",
        requestId: "request-1",
        subagents: [expect.objectContaining({ id: "child" })],
      }),
    ]);
    expect(sent[0]).not.toHaveProperty("providerThreadId");
    expect(sent[0]).not.toHaveProperty("codexSourceId");
  });

  it("pushes a coalesced source-scoped activity summary and stops after unwatch", async () => {
    let running = true;
    const listThreads = vi.fn(async (params: { archived?: boolean }) => ({
      data: params.archived
        ? []
        : [
            {
              ...thread("child", "runtime-parent"),
              status: running ? "active" : "idle",
              activeFlags: running ? ["waitingOnUserInput"] : [],
              updatedAt: running ? 2 : 3,
            },
          ],
      nextCursor: null,
    }));
    const process = handlerProcess({ listThreads });
    const sent: unknown[] = [];
    const client = {};
    const runtime = {
      codexSourceId: "source-1",
      getSession: vi.fn(() => ({
        id: "runtime-session",
        provider: "codex",
        process,
      })),
      getCodexThreadId: vi.fn(() => "runtime-parent"),
      getActiveCodexProcess: vi.fn(() => null),
      createStandaloneCodexProcess: vi.fn(),
      hasCodexQueuedInput: () => false,
      isClientOpen: () => true,
      send: (_client: object, message: unknown) => sent.push(message),
      supports: (_client: object, type: string) =>
        type === "subagent_list" || type === "subagent_activity_summary_v1",
    } as unknown as LocalFeatureRuntime;
    const context: LocalFeatureHandleContext = {
      client,
      signal: new AbortController().signal,
      runtime,
    };
    const handler = new SubagentsFeatureHandler();

    await handler.handle(
      {
        type: "get_subagents",
        sessionId: "runtime-session",
        requestId: "list-1",
      },
      context,
    );
    expect(sent).toEqual([
      expect.objectContaining({ type: "subagent_list" }),
      expect.objectContaining({
        type: "subagent_activity_summary_v1",
        scope: "runtime",
        ownerSessionId: "runtime-session",
        providerThreadId: "runtime-parent",
        listRequestId: "list-1",
        subscribed: false,
        activeCount: 1,
      }),
    ]);

    await handler.handle(
      {
        type: "watch_subagent_activity_v1",
        sessionId: "runtime-session",
        listRequestId: "list-1",
        subscriptionId: "watch-1",
      },
      context,
    );
    expect(sent.at(-1)).toEqual(
      expect.objectContaining({
        type: "subagent_activity_summary_v1",
        subscriptionId: "watch-1",
        subscribed: true,
        activeCount: 1,
      }),
    );

    const callsBeforeInvalidation = listThreads.mock.calls.length;
    running = false;
    handler.sessionCatalogChanged({
      revision: 2,
      provider: "codex",
      providerSessionId: "child",
    });
    handler.sessionCatalogChanged({
      revision: 3,
      provider: "codex",
      providerSessionId: "child",
    });
    await vi.waitFor(
      () => {
        expect(sent.at(-1)).toEqual(
          expect.objectContaining({
            type: "subagent_activity_summary_v1",
            subscriptionId: "watch-1",
            activeCount: 0,
          }),
        );
      },
      { timeout: 2_000 },
    );
    expect(listThreads.mock.calls.length - callsBeforeInvalidation).toBe(2);

    await handler.handle(
      { type: "unwatch_subagent_activity_v1", subscriptionId: "watch-1" },
      context,
    );
    const callsAfterUnwatch = listThreads.mock.calls.length;
    handler.sessionCatalogChanged({ revision: 4, provider: "codex" });
    await new Promise((resolve) => setTimeout(resolve, 250));
    expect(listThreads).toHaveBeenCalledTimes(callsAfterUnwatch);
  });
});

describe("limitSubagentHistoryResponse", () => {
  it("keeps the newest 400 messages deterministically", () => {
    const messages = Array.from({ length: 405 }, (_, index) =>
      assistantText(String(index), `message-${index}`),
    );

    const limited = limitSubagentHistoryResponse(messages);
    expect(limited.truncated).toBe(true);
    expect(limited.messages).toHaveLength(MAX_SUBAGENT_HISTORY_MESSAGES);
    expect(limited.messages[0]).toMatchObject({
      type: "assistant",
      message: { id: "5" },
    });
    expect(limited.messages.at(-1)).toMatchObject({
      type: "assistant",
      message: { id: "404" },
    });
  });

  it("enforces the byte limit while retaining the tail of the newest message", () => {
    const messages = [assistantText("huge", `${"old".repeat(1000)}LATEST`)];
    const limited = limitSubagentHistoryResponse(messages, {
      maxMessages: 10,
      maxBytes: 300,
    });

    expect(limited.truncated).toBe(true);
    expect(limited.messages).toHaveLength(1);
    expect(JSON.stringify(limited.messages)).toContain("LATEST");
    expect(JSON.stringify(limited.messages)).toContain(
      "earlier content truncated",
    );
    expect(
      Buffer.byteLength(JSON.stringify(limited.messages), "utf8"),
    ).toBeLessThanOrEqual(300);
  });
});
