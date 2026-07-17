import { describe, expect, it, vi } from "vitest";
import { CodexRpcError, type CodexProcess } from "../codex-process.js";
import type { ServerMessage } from "../parser.js";
import type { CodexSubagentInfo as CodexThreadSummary } from "./protocol.js";
import {
  childThreadToServerMessages,
  CodexSubagentService,
  descendantsOf,
  limitSubagentHistoryResponse,
  MAX_SUBAGENT_HISTORY_MESSAGES,
} from "./subagents.js";

function thread(
  id: string,
  parentThreadId: string | null,
): CodexThreadSummary {
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

function processWith(
  overrides: Record<string, unknown>,
): CodexProcess {
  const listThreads =
    (overrides.listThreads as ReturnType<typeof vi.fn> | undefined) ??
    vi.fn(async () => ({ data: [], nextCursor: null }));
  const listThreadItems =
    (overrides.listThreadItems as ReturnType<typeof vi.fn> | undefined) ??
    vi.fn().mockRejectedValue(
      new CodexRpcError(
        "thread/items/list",
        "Method not found: thread/items/list",
        -32601,
      ),
    );
  const listThreadTurns =
    (overrides.listThreadTurns as ReturnType<typeof vi.fn> | undefined) ??
    vi.fn().mockRejectedValue(
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
      async (method: string, params: Record<string, unknown>, options: unknown) => {
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
          return { thread: await readThread(params.threadId, params.includeTurns, options) };
        }
        throw new Error(`Unexpected RPC: ${method}`);
      },
    ),
  } as unknown as CodexProcess;
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

  it("trusts and paginates the official ancestor-filtered result without sourceKinds", async () => {
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
      }),
      expect.objectContaining({ signal: expect.any(AbortSignal) }),
    );
    expect(listThreads).toHaveBeenNthCalledWith(
      2,
      expect.objectContaining({ ancestorThreadId: "root", cursor: "page-2" }),
      expect.objectContaining({ signal: expect.any(AbortSignal) }),
    );
    expect(listThreads.mock.calls[0]?.[0]).not.toHaveProperty("sourceKinds");
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
      });
    const service = new CodexSubagentService();

    await expect(
      service.list(processWith({ listThreads }), "root"),
    ).resolves.toEqual({
      subagents: [thread("child", "root")],
      truncated: false,
    });
    expect(listThreads).toHaveBeenCalledTimes(2);
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
      });

    await expect(
      new CodexSubagentService().list(processWith({ listThreads }), "root"),
    ).resolves.toMatchObject({
      subagents: [{ id: "child" }],
      truncated: false,
    });
    expect(listThreads).toHaveBeenCalledTimes(2);
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
              data: [
                { type: "agentMessage", id: "a1", text: "newest" },
              ],
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
    const listThreadTurns = vi.fn().mockRejectedValue(
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
          (_method: string, _params: unknown, options: { signal: AbortSignal }) =>
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
    expect(Buffer.byteLength(JSON.stringify(limited.messages), "utf8")).toBeLessThanOrEqual(
      300,
    );
  });
});
