import { createHash } from "node:crypto";
import { describe, expect, it, vi } from "vitest";
import { CodexRpcError, type CodexProcess } from "../codex-process.js";
import type { ServerMessage } from "../parser.js";
import type { LocalFeatureRuntime } from "./runtime.js";
import {
  chunkConversationMirrorEntries,
  CodexConversationMirrorReader,
  ConversationMirrorError,
  ConversationMirrorFeatureHandler,
  diffSnapshots,
  MAX_CONVERSATION_MIRROR_ENTRIES,
  MAX_CONVERSATION_MIRROR_EVENT_BYTES,
  normalizeConversationMirrorSnapshot,
  type ConversationMirrorSnapshot,
} from "./conversation-mirror.js";

function fakeProcess(
  rpc: (
    method: string,
    params: Record<string, unknown>,
  ) => unknown | Promise<unknown>,
): CodexProcess {
  return {
    requestReadOnlyRpc: vi.fn(rpc),
    stop: vi.fn(),
  } as unknown as CodexProcess;
}

function turn(
  id: string,
  items: Array<Record<string, unknown>>,
): Record<string, unknown> {
  return { id, startedAt: 1, completedAt: 2, items };
}

function markerThread(updatedAt: number, status = "idle") {
  return { id: "thread-1", updatedAt, status, cwd: "/tmp/project" };
}

function snapshot(
  revision: string,
  entries: ConversationMirrorSnapshot["entries"],
  status: string | null = "idle",
): ConversationMirrorSnapshot {
  return {
    revision,
    entries,
    totalBytes: entries.reduce(
      (sum, entry) =>
        sum + Buffer.byteLength(JSON.stringify(entry.message), "utf8"),
      0,
    ),
    threadStatus: status,
    digest: `marker-${revision}`,
  };
}

function entry(
  entryId: string,
  index: number,
  text: string,
): ConversationMirrorSnapshot["entries"][number] {
  const message: ServerMessage = { type: "user_input", text };
  return {
    entryId,
    index,
    contentHash: createHash("sha256")
      .update(JSON.stringify(message))
      .digest("hex"),
    message,
  };
}

function runtimeFor(
  process: CodexProcess,
  options: {
    supported?: Set<object>;
    pathAllowed?: boolean;
    activeProcess?: boolean;
    entryChunks?: boolean;
    codexSourceId?: string;
  } = {},
): {
  runtime: LocalFeatureRuntime;
  sent: Map<object, any[]>;
  createStandalone: ReturnType<typeof vi.fn>;
} {
  const sent = new Map<object, any[]>();
  const createStandalone = vi.fn(async () => process);
  const runtime: LocalFeatureRuntime = {
    bridgeInstanceId: "bridge-test",
    codexSourceId: options.codexSourceId,
    getSession: () => undefined,
    getCodexThreadId: () => undefined,
    getActiveCodexProcess: () =>
      options.activeProcess === false ? null : process,
    createStandaloneCodexProcess: createStandalone,
    isProjectPathAllowed: () => options.pathAllowed !== false,
    send(client, message) {
      const messages = sent.get(client) ?? [];
      messages.push(message);
      sent.set(client, messages);
    },
    supports: (client, type) => {
      const clientSupported = options.supported
        ? options.supported.has(client)
        : true;
      if (!clientSupported) return false;
      return (
        type === "conversation_mirror_event_v1" ||
        (type === "conversation_mirror_entry_chunk_v1" &&
          options.entryChunks === true)
      );
    },
  };
  return { runtime, sent, createStandalone };
}

function signal(): AbortSignal {
  return new AbortController().signal;
}

describe("CodexConversationMirrorReader", () => {
  it("prefers item pagination, restores chronological order, and preserves clientId", async () => {
    const rpc = vi.fn(
      async (method: string, params: Record<string, unknown>) => {
        if (method === "thread/read") {
          return { thread: markerThread(2, "idle") };
        }
        if (method !== "thread/items/list") throw new Error(method);
        if (params.cursor === null) {
          return {
            data: [
              {
                item: {
                  type: "agentMessage",
                  id: "assistant-2",
                  text: "new",
                },
              },
            ],
            nextCursor: "older",
          };
        }
        return {
          data: [
            {
              item: {
                type: "userMessage",
                id: "user-1",
                clientId: "client-message-1",
                content: [{ type: "text", text: "old" }],
              },
            },
          ],
          nextCursor: null,
        };
      },
    );
    const process = fakeProcess(rpc);

    const result = await new CodexConversationMirrorReader().readSnapshot(
      process,
      "thread-1",
    );

    expect(result.entries.map((value) => value.entryId)).toEqual([
      "user-1",
      "assistant-2",
    ]);
    expect(result.entries[0]?.message).toMatchObject({
      type: "user_input",
      text: "old",
      clientMessageId: "client-message-1",
      providerItemId: "user-1",
      historyTurnId: "thread-1:bounded-items",
      userMessageUuid: "codex:user-turn:1",
    });
    expect(result.entries[0]?.contentHash).toBe(
      createHash("sha256")
        .update(JSON.stringify(result.entries[0]?.message))
        .digest("hex"),
    );
    expect(result.totalBytes).toBe(
      result.entries.reduce(
        (sum, value) =>
          sum + Buffer.byteLength(JSON.stringify(value.message), "utf8"),
        0,
      ),
    );
    const itemCalls = rpc.mock.calls.filter(
      ([method]) => method === "thread/items/list",
    );
    expect(itemCalls).toHaveLength(2);
    expect(itemCalls[0]?.[1]).toEqual({
      threadId: "thread-1",
      limit: 100,
      cursor: null,
      sortDirection: "desc",
    });
  });

  it("persists Desktop-only Skill and sub-agent tools in their turn order", async () => {
    const process = fakeProcess(
      async (method: string, params: Record<string, unknown>) => {
        if (method === "thread/read") {
          return { thread: markerThread(2, "idle") };
        }
        if (method === "thread/items/list" && params.cursor === null) {
          return {
            data: [
              {
                turnId: "turn-1",
                item: {
                  type: "agentMessage",
                  id: "assistant-1",
                  text: "inspection complete",
                },
              },
              {
                turnId: "turn-1",
                item: {
                  type: "userMessage",
                  id: "user-1",
                  content: [{ type: "text", text: "inspect this" }],
                },
              },
            ],
            nextCursor: null,
          };
        }
        throw new Error(method);
      },
    );
    const desktopToolTimelineReader = vi.fn(async () => ({
      callIds: new Set(["call-skill", "call-agent"]),
      events: [
        {
          turnId: "turn-1",
          callId: "call-skill",
          afterVisibleMessage: 1,
          sequence: 1,
          type: "tool_use" as const,
          name: "ReadSkill",
          input: { file_path: "/tmp/pdf/SKILL.md", skill: "pdf" },
          timestamp: "2026-07-30T03:00:01.000Z",
        },
        {
          turnId: "turn-1",
          callId: "call-skill",
          afterVisibleMessage: 1,
          sequence: 2,
          type: "tool_result" as const,
          name: "ReadSkill",
          content: "skill body",
          timestamp: "2026-07-30T03:00:02.000Z",
        },
        {
          turnId: "turn-1",
          callId: "call-agent",
          afterVisibleMessage: 2,
          sequence: 3,
          type: "tool_use" as const,
          name: "SpawnAgent",
          input: { task_name: "review" },
          timestamp: "2026-07-30T03:00:04.000Z",
        },
        {
          turnId: "turn-1",
          callId: "call-agent",
          afterVisibleMessage: 2,
          sequence: 4,
          type: "tool_result" as const,
          name: "SpawnAgent",
          content: "agent started",
          timestamp: "2026-07-30T03:00:05.000Z",
        },
      ],
      itemTimestamps: new Map([
        [
          "user-1",
          {
            startedAt: "2026-07-30T03:00:00.000Z",
            completedAt: "2026-07-30T03:00:00.000Z",
          },
        ],
        [
          "assistant-1",
          {
            startedAt: "2026-07-30T03:00:03.000Z",
            completedAt: "2026-07-30T03:00:03.000Z",
          },
        ],
      ]),
    }));

    const result = await new CodexConversationMirrorReader({
      desktopToolTimelineReader,
    }).readSnapshot(process, "thread-1");

    expect(desktopToolTimelineReader).toHaveBeenCalledWith("thread-1");
    expect(result.entries.map((value) => value.entryId)).toEqual([
      "user-1",
      "call-skill",
      "call-skill:part-2",
      "assistant-1",
      "call-agent",
      "call-agent:part-2",
    ]);
    const toolNames = result.entries.flatMap((value) =>
      value.message.type === "assistant"
        ? value.message.message.content
            .filter((content) => content.type === "tool_use")
            .map((content) => content.name)
        : [],
    );
    expect(toolNames).toEqual(["ReadSkill", "SpawnAgent"]);
    expect(
      result.entries.map((value) => ({
        entryId: value.entryId,
        sourceTimestamp: value.message.sourceTimestamp,
        authoritative: value.message.sourceTimestampIsAuthoritative,
      })),
    ).toEqual([
      {
        entryId: "user-1",
        sourceTimestamp: "2026-07-30T03:00:00.000Z",
        authoritative: true,
      },
      {
        entryId: "call-skill",
        sourceTimestamp: "2026-07-30T03:00:01.000Z",
        authoritative: true,
      },
      {
        entryId: "call-skill:part-2",
        sourceTimestamp: "2026-07-30T03:00:02.000Z",
        authoritative: true,
      },
      {
        entryId: "assistant-1",
        sourceTimestamp: "2026-07-30T03:00:03.000Z",
        authoritative: true,
      },
      {
        entryId: "call-agent",
        sourceTimestamp: "2026-07-30T03:00:04.000Z",
        authoritative: true,
      },
      {
        entryId: "call-agent:part-2",
        sourceTimestamp: "2026-07-30T03:00:05.000Z",
        authoritative: true,
      },
    ]);
  });

  it("preserves item-pagination turn identity when raw items have no id", async () => {
    const process = fakeProcess(
      async (method: string, params: Record<string, unknown>) => {
        if (method === "thread/read") {
          return { thread: markerThread(1) };
        }
        if (method === "thread/items/list") {
          return {
            data: [
              {
                turnId: "turn-new",
                item: { type: "agentMessage", text: "new" },
              },
              {
                turnId: "turn-old",
                item: {
                  type: "userMessage",
                  content: [{ type: "text", text: "old" }],
                },
              },
            ],
            nextCursor: null,
          };
        }
        throw new Error(method);
      },
    );
    const reader = new CodexConversationMirrorReader();

    const first = await reader.readSnapshot(process, "thread-1");
    const second = await reader.readSnapshot(process, "thread-1");

    expect(first.entries.map((value) => value.entryId)).toEqual(
      second.entries.map((value) => value.entryId),
    );
    expect(first.entries[0]?.entryId).toMatch(/^turn-old:item-/);
    expect(first.entries[1]?.entryId).toMatch(/^turn-new:item-/);
  });

  it("falls back to full-turn pagination when item pagination is unsupported", async () => {
    const rpc = vi.fn(
      async (method: string, params: Record<string, unknown>) => {
        if (method === "thread/read") {
          return { thread: markerThread(2, "idle") };
        }
        if (method === "thread/items/list") {
          throw new CodexRpcError(
            method,
            "Method not found: thread/items/list",
            -32601,
          );
        }
        if (method !== "thread/turns/list") throw new Error(method);
        return params.cursor === null
          ? {
              data: [
                {
                  turn: turn("turn-2", [
                    { type: "agentMessage", id: "assistant-2", text: "new" },
                  ]),
                },
              ],
              nextCursor: "older",
            }
          : {
              data: [
                turn("turn-1", [
                  {
                    type: "userMessage",
                    id: "user-1",
                    clientId: "client-message-1",
                    content: [{ type: "text", text: "old" }],
                  },
                ]),
              ],
              nextCursor: null,
            };
      },
    );
    const warning = vi.spyOn(console, "warn").mockImplementation(() => {});

    const result = await new CodexConversationMirrorReader().readSnapshot(
      fakeProcess(rpc),
      "thread-1",
    );

    expect(result.entries.map((value) => value.entryId)).toEqual([
      "user-1",
      "assistant-2",
    ]);
    expect(rpc.mock.calls.filter(([method]) => method === "thread/items/list"))
      .toHaveLength(1);
    const turnsCalls = rpc.mock.calls.filter(
      ([method]) => method === "thread/turns/list",
    );
    expect(turnsCalls).toHaveLength(2);
    expect(turnsCalls[0]?.[1]).toEqual({
      threadId: "thread-1",
      itemsView: "full",
      limit: 100,
      cursor: null,
      sortDirection: "desc",
    });
    warning.mockRestore();
  });

  it("rejects a non-advancing provider cursor without a whole-thread read", async () => {
    let wholeThreadReads = 0;
    const process = fakeProcess(
      async (method: string, params: Record<string, unknown>) => {
        if (method === "thread/read" && params.includeTurns === false) {
          return { thread: markerThread(2, "idle") };
        }
        if (method === "thread/read" && params.includeTurns === true) {
          wholeThreadReads += 1;
          throw new Error("whole-thread read must not run");
        }
        if (method === "thread/items/list") {
          return {
            data: [],
            nextCursor: "same-cursor",
          };
        }
        throw new Error(method);
      },
    );

    await expect(
      new CodexConversationMirrorReader().readSnapshot(process, "thread-1"),
    ).rejects.toThrow("repeated cursor");
    expect(wholeThreadReads).toBe(0);
  });

  it("retries legacy turn pagination without itemsView and accepts only full-shaped turns", async () => {
    let itemCalls = 0;
    let fullTurnCalls = 0;
    let legacyTurnCalls = 0;
    const process = fakeProcess(
      async (method: string, params: Record<string, unknown>) => {
        if (method === "thread/read" && params.includeTurns === false) {
          return { thread: markerThread(1) };
        }
        if (method === "thread/items/list") {
          itemCalls += 1;
          throw new CodexRpcError(
            method,
            "Method not found: thread/items/list",
            -32601,
          );
        }
        if (method === "thread/turns/list" && params.itemsView === "full") {
          fullTurnCalls += 1;
          throw new CodexRpcError(
            method,
            "Invalid params: unknown field itemsView",
            -32602,
          );
        }
        if (method === "thread/turns/list") {
          legacyTurnCalls += 1;
          return {
            data: [
              turn("legacy-turn", [
                { type: "agentMessage", id: "legacy-answer", text: "ok" },
              ]),
            ],
            nextCursor: null,
          };
        }
        throw new Error(method);
      },
    );
    const reader = new CodexConversationMirrorReader();
    await reader.readSnapshot(process, "thread-1");
    await reader.readSnapshot(process, "thread-1");

    expect(itemCalls).toBe(1);
    expect(fullTurnCalls).toBe(1);
    expect(legacyTurnCalls).toBe(2);
  });

  it("fails closed instead of committing summary-only turn pagination", async () => {
    let fullReads = 0;
    const process = fakeProcess(
      async (method: string, params: Record<string, unknown>) => {
        if (method === "thread/read" && params.includeTurns === false) {
          return { thread: markerThread(1) };
        }
        if (method === "thread/items/list") {
          throw new CodexRpcError(
            method,
            "Method not found: thread/items/list",
            -32601,
          );
        }
        if (method === "thread/turns/list") {
          return {
            data: [
              {
                ...turn("summary-turn", [
                  { type: "agentMessage", id: "summary", text: "summary" },
                ]),
                itemsView: "summary",
              },
            ],
            nextCursor: null,
          };
        }
        if (method === "thread/read" && params.includeTurns === true) {
          fullReads += 1;
          return {
            thread: {
              ...markerThread(1),
              turns: [
                turn("full-turn", [
                  { type: "agentMessage", id: "full", text: "full" },
                ]),
              ],
            },
          };
        }
        throw new Error(method);
      },
    );
    await expect(
      new CodexConversationMirrorReader().readSnapshot(process, "thread-1"),
    ).rejects.toThrow("non-full itemsView");
    expect(fullReads).toBe(0);
  });

  it("fails closed after both pagination adapters are unavailable", async () => {
    let itemCalls = 0;
    let turnCalls = 0;
    let fullReads = 0;
    const process = fakeProcess(
      async (method: string, params: Record<string, unknown>) => {
        if (method === "thread/items/list") {
          itemCalls += 1;
          throw new CodexRpcError(
            method,
            "Method not found: thread/items/list",
            -32601,
          );
        }
        if (method === "thread/turns/list") {
          turnCalls += 1;
          throw new CodexRpcError(
            method,
            "Method not found: thread/turns/list",
            -32601,
          );
        }
        if (method === "thread/read" && params.includeTurns === false) {
          return { thread: markerThread(fullReads) };
        }
        if (method === "thread/read" && params.includeTurns === true) {
          fullReads += 1;
          return {
            thread: {
              ...markerThread(fullReads),
              turns: [
                turn("turn-1", [
                  { type: "agentMessage", id: "answer", text: "ok" },
                ]),
              ],
            },
          };
        }
        throw new Error(method);
      },
    );
    const reader = new CodexConversationMirrorReader();
    await expect(reader.readSnapshot(process, "thread-1")).rejects.toThrow(
      "Method not found: thread/turns/list",
    );
    await expect(reader.readSnapshot(process, "thread-1")).rejects.toThrow(
      "Method not found: thread/turns/list",
    );

    expect(itemCalls).toBe(1);
    expect(turnCalls).toBe(2);
    expect(fullReads).toBe(0);
  });

  it("fails closed when an older endpoint rejects pagination parameters", async () => {
    let itemCalls = 0;
    let turnCalls = 0;
    let fullReads = 0;
    const process = fakeProcess(
      async (method: string, params: Record<string, unknown>) => {
        if (method === "thread/items/list") {
          itemCalls += 1;
          throw new CodexRpcError(
            method,
            "Method not found: thread/items/list",
            -32601,
          );
        }
        if (method === "thread/turns/list") {
          turnCalls += 1;
          throw new CodexRpcError(
            "thread/turns/list",
            "Invalid params: unknown field sortDirection",
            -32602,
          );
        }
        if (method === "thread/read" && params.includeTurns === false) {
          return { thread: markerThread(fullReads) };
        }
        if (method === "thread/read" && params.includeTurns === true) {
          fullReads += 1;
          return {
            thread: {
              ...markerThread(fullReads),
              turns: [],
            },
          };
        }
        throw new Error(method);
      },
    );
    const reader = new CodexConversationMirrorReader();
    await expect(reader.readSnapshot(process, "thread-1")).rejects.toThrow(
      "unknown field sortDirection",
    );
    await expect(reader.readSnapshot(process, "thread-1")).rejects.toThrow(
      "unknown field sortDirection",
    );

    expect(itemCalls).toBe(1);
    expect(turnCalls).toBe(2);
    expect(fullReads).toBe(0);
  });

  it("does not sticky-downgrade pagination after a transport failure", async () => {
    let itemCalls = 0;
    const process = fakeProcess(
      async (method: string, params: Record<string, unknown>) => {
        if (method === "thread/read" && params.includeTurns === false) {
          return { thread: markerThread(itemCalls) };
        }
        if (method === "thread/items/list") {
          itemCalls += 1;
          if (itemCalls === 1) throw new Error("connection reset");
          return { data: [], nextCursor: null };
        }
        throw new Error(method);
      },
    );
    const reader = new CodexConversationMirrorReader();

    await expect(reader.readSnapshot(process, "thread-1")).rejects.toThrow(
      "connection reset",
    );
    await expect(reader.readSnapshot(process, "thread-1")).resolves.toMatchObject({
      entries: [],
    });
    expect(itemCalls).toBe(2);
  });

  it("keeps legacy and paginated thread modes separate on one app-server process", async () => {
    const itemCalls: string[] = [];
    const turnCalls: string[] = [];
    const process = fakeProcess(
      async (method: string, params: Record<string, unknown>) => {
        const threadId = params.threadId as string;
        if (method === "thread/read" && params.includeTurns === false) {
          return {
            thread: {
              ...markerThread(1),
              id: threadId,
            },
          };
        }
        if (method === "thread/items/list") {
          itemCalls.push(threadId);
          if (threadId === "legacy") {
            throw new CodexRpcError(
              method,
              "Method not found for legacy thread: thread/items/list",
              -32601,
            );
          }
          return {
            data: [
              {
                item: {
                  type: "agentMessage",
                  id: `item-${threadId}`,
                  text: threadId,
                },
              },
            ],
            nextCursor: null,
          };
        }
        if (method === "thread/turns/list") {
          turnCalls.push(threadId);
          return {
            data: [
              turn(`turn-${threadId}`, [
                {
                  type: "agentMessage",
                  id: `item-${threadId}`,
                  text: threadId,
                },
              ]),
            ],
            nextCursor: null,
          };
        }
        throw new Error(method);
      },
    );
    const reader = new CodexConversationMirrorReader();
    await reader.readSnapshot(process, "legacy");
    await reader.readSnapshot(process, "paginated");
    await reader.readSnapshot(process, "legacy");
    await reader.readSnapshot(process, "paginated");

    expect(itemCalls).toEqual(["legacy", "paginated", "paginated"]);
    expect(turnCalls).toEqual(["legacy", "legacy"]);
  });

  it("keeps pagination fallback state isolated between app-server processes", async () => {
    const oldRpc = vi.fn(
      async (method: string, params: Record<string, unknown>) => {
        if (method === "thread/read" && params.includeTurns === false) {
          return { thread: markerThread(1) };
        }
        if (method === "thread/read" && params.includeTurns === true) {
          return { thread: { ...markerThread(1), turns: [] } };
        }
        if (method === "thread/items/list" || method === "thread/turns/list") {
          throw new CodexRpcError(method, `Method not found: ${method}`, -32601);
        }
        throw new Error(method);
      },
    );
    const newRpc = vi.fn(
      async (method: string, params: Record<string, unknown>) => {
        if (method === "thread/read" && params.includeTurns === false) {
          return { thread: markerThread(1) };
        }
        if (method === "thread/items/list") {
          return { data: [], nextCursor: null };
        }
        throw new Error(method);
      },
    );
    const reader = new CodexConversationMirrorReader();
    await expect(
      reader.readSnapshot(fakeProcess(oldRpc), "thread-1"),
    ).rejects.toThrow("Method not found: thread/turns/list");
    await reader.readSnapshot(fakeProcess(newRpc), "thread-1");

    expect(newRpc.mock.calls.some(([method]) => method === "thread/items/list"))
      .toBe(true);
  });

  it("reports explicit normalized entry and byte limits", () => {
    const raw = {
      turns: [
        turn("turn", [
          { type: "agentMessage", id: "one", text: "1" },
          { type: "agentMessage", id: "two", text: "2" },
        ]),
      ],
    };
    expect(() =>
      normalizeConversationMirrorSnapshot(raw, undefined, {
        maxEntries: 1,
        maxTotalBytes: 10_000,
      }),
    ).toThrowError(ConversationMirrorError);
    expect(() =>
      normalizeConversationMirrorSnapshot(raw, undefined, {
        maxEntries: 10,
        maxTotalBytes: 1,
      }),
    ).toThrow(/normalized bytes/);
  });

  it("accepts a default full download above the former 10k ceiling", () => {
    const itemCount = 10_001;
    const result = normalizeConversationMirrorSnapshot({
      turns: [
        turn(
          "large-turn",
          Array.from({ length: itemCount }, (_, index) => ({
            type: "agentMessage",
            id: `assistant-${index}`,
            text: `message ${index}`,
          })),
        ),
      ],
    });

    expect(MAX_CONVERSATION_MIRROR_ENTRIES).toBe(100_000);
    expect(result.entries).toHaveLength(itemCount);
  });

  it("keeps display user UUID ordinals separate from raw entry identity", () => {
    const result = normalizeConversationMirrorSnapshot({
      turns: [
        turn("turn-1", [
          {
            type: "userMessage",
            id: "raw-user-1",
            clientId: "client-1",
            content: [{ type: "text", text: "first" }],
          },
          {
            type: "userMessage",
            id: "raw-user-2",
            clientId: "client-2",
            content: [{ type: "text", text: "second" }],
          },
        ]),
      ],
    });

    expect(result.entries.map((value) => value.entryId)).toEqual([
      "raw-user-1",
      "raw-user-2",
    ]);
    expect(result.entries.map((value) => value.message)).toEqual([
      expect.objectContaining({
        type: "user_input",
        userMessageUuid: "codex:user-turn:1",
        providerItemId: "raw-user-1",
        historyTurnId: "turn-1",
        clientMessageId: "client-1",
      }),
      expect.objectContaining({
        type: "user_input",
        userMessageUuid: "codex:user-turn:2",
        providerItemId: "raw-user-2",
        historyTurnId: "turn-1",
        clientMessageId: "client-2",
      }),
    ]);
  });

  it("records image counts without persisting local paths or image bytes", () => {
    const result = normalizeConversationMirrorSnapshot({
      turns: [
        turn("turn-1", [
          {
            type: "userMessage",
            id: "user-with-images",
            content: [
              { type: "text", text: "inspect this" },
              { type: "localImage", path: "/private/user/image.png" },
              {
                type: "image",
                imageUrl: "data:image/png;base64,c2VjcmV0LWltYWdl",
              },
            ],
          },
        ]),
      ],
    });

    expect(result.entries).toHaveLength(1);
    expect(result.entries[0]?.message).toEqual(
      expect.objectContaining({
        type: "user_input",
        text: "inspect this",
        imageCount: 2,
      }),
    );
    const serialized = JSON.stringify(result.entries);
    expect(serialized).not.toContain("/private/user/image.png");
    expect(serialized).not.toContain("c2VjcmV0LWltYWdl");
  });

  it("keeps entry identity and revision stable across nested object key order", () => {
    const makeThread = (argumentsValue: Record<string, unknown>) => ({
      id: "thread-1",
      cwd: "/tmp/project",
      status: "idle",
      turns: [
        turn("turn-1", [
          {
            type: "dynamicToolCall",
            tool: "example",
            arguments: argumentsValue,
            contentItems: [{ type: "inputText", text: "done" }],
          },
        ]),
      ],
    });
    const first = normalizeConversationMirrorSnapshot(
      makeThread({ alpha: 1, nested: { beta: 2, gamma: 3 } }),
    );
    const second = normalizeConversationMirrorSnapshot(
      makeThread({ nested: { gamma: 3, beta: 2 }, alpha: 1 }),
    );

    expect(second.revision).toBe(first.revision);
    expect(second.entries).toEqual(first.entries);
    for (const value of first.entries) {
      expect(value.contentHash).toBe(
        createHash("sha256")
          .update(JSON.stringify(value.message))
          .digest("hex"),
      );
    }
  });
});

describe("conversation mirror snapshots", () => {
  it("detects same-count mutations and rollback deletions", () => {
    const before = snapshot("before", [
      entry("a", 0, "a"),
      entry("b", 1, "before"),
      entry("c", 2, "c"),
    ]);
    const sameCount = snapshot("after", [
      entry("a", 0, "a"),
      entry("b", 1, "after"),
      entry("c", 2, "c"),
    ]);
    expect(diffSnapshots(before, sameCount)).toEqual({
      upserts: [sameCount.entries[1]],
      deletes: [],
    });

    const rolledBack = snapshot("rolled-back", [entry("a", 0, "a")]);
    expect(diffSnapshots(before, rolledBack)).toEqual({
      upserts: [],
      deletes: ["b", "c"],
    });
  });

  it("chunks by both 100 entries and the 512 KiB encoded event limit", () => {
    const entries = Array.from({ length: 205 }, (_, index) =>
      entry(`entry-${index}`, index, "x".repeat(6_000)),
    );
    const pages = chunkConversationMirrorEntries(
      {
        requestId: "request",
        provider: "codex",
        providerSessionId: "thread",
      },
      snapshot("revision", entries),
      { bridgeInstanceId: "bridge" },
    );
    expect(pages.flat()).toHaveLength(205);
    expect(pages.every((page) => page.length <= 100)).toBe(true);
    for (let pageIndex = 0; pageIndex < pages.length; pageIndex += 1) {
      const encoded = Buffer.byteLength(
        JSON.stringify({
          type: "conversation_mirror_event_v1",
          event: "snapshot_page",
          requestId: "request",
          bridgeInstanceId: "bridge",
          provider: "codex",
          providerSessionId: "thread",
          revision: "revision",
          pageIndex,
          pageCount: pages.length,
          entries: pages[pageIndex],
        }),
        "utf8",
      );
      expect(encoded).toBeLessThanOrEqual(MAX_CONVERSATION_MIRROR_EVENT_BYTES);
    }
  });

  it("rejects an entry that cannot fit in one event", () => {
    expect(() =>
      chunkConversationMirrorEntries(
        {
          requestId: "request",
          provider: "codex",
          providerSessionId: "thread",
        },
        snapshot("revision", [entry("huge", 0, "x".repeat(600_000))]),
        { bridgeInstanceId: "bridge" },
      ),
    ).toThrow(/512 KiB/);
  });
});

describe("ConversationMirrorFeatureHandler", () => {
  it("rejects a mismatched Codex source before any provider read", async () => {
    const process = fakeProcess(() => {
      throw new Error("mismatched source must not read");
    });
    const client = {};
    const { runtime, sent, createStandalone } = runtimeFor(process, {
      codexSourceId: "codex-home-source-b",
    });
    const handler = new ConversationMirrorFeatureHandler(runtime);

    await handler.handle(
      {
        type: "conversation_mirror_sync",
        protocolVersion: 1,
        requestId: "wrong-source",
        provider: "codex",
        providerSessionId: "thread-1",
        codexSourceId: "codex-home-source-a",
        projectPath: "/tmp/project",
      },
      { client, signal: signal(), runtime },
    );

    expect(sent.get(client)?.at(-1)).toMatchObject({
      event: "error",
      requestId: "wrong-source",
      errorCode: "codex_source_mismatch",
    });
    expect(process.requestReadOnlyRpc).not.toHaveBeenCalled();
    expect(createStandalone).not.toHaveBeenCalled();
    handler.close();
  });

  it("stays dormant for an old client without the mirror capability", async () => {
    const process = fakeProcess(() => {
      throw new Error("mirror reader must stay dormant");
    });
    const oldClient = {};
    const { runtime, sent, createStandalone } = runtimeFor(process, {
      supported: new Set(),
      activeProcess: false,
    });
    const handler = new ConversationMirrorFeatureHandler(runtime);

    // Connecting/capability negotiation alone is deliberately passive.
    handler.capabilitiesChanged(oldClient);
    expect(sent.get(oldClient)).toBeUndefined();
    expect(createStandalone).not.toHaveBeenCalled();
    expect((handler as any).watches.size).toBe(0);

    // Even a mirror-shaped request is ignored unless the client opted in.
    await handler.handle(
      {
        type: "conversation_mirror_watch",
        requestId: "old-client",
        provider: "codex",
        providerSessionId: "thread-1",
        projectPath: "/tmp/project",
      },
      { client: oldClient, signal: signal(), runtime },
    );
    expect(sent.get(oldClient)).toBeUndefined();
    expect(createStandalone).not.toHaveBeenCalled();
    expect(process.requestReadOnlyRpc).not.toHaveBeenCalled();
    expect((handler as any).watches.size).toBe(0);
    handler.close();
  });

  it("fragments one oversized entry for a chunk-capable client", async () => {
    const text = "x".repeat(700_000);
    const process = fakeProcess(async (method) => {
      if (method === "thread/read") return { thread: markerThread(1) };
      if (method !== "thread/items/list") throw new Error(method);
      return {
        data: [
          {
            turnId: "turn-large",
            item: {
              type: "userMessage",
              id: "large-user-entry",
              content: [{ type: "text", text }],
            },
          },
        ],
        nextCursor: null,
      };
    });
    const client = {};
    const { runtime, sent } = runtimeFor(process, { entryChunks: true });
    const handler = new ConversationMirrorFeatureHandler(runtime);

    await handler.handle(
      {
        type: "conversation_mirror_sync",
        requestId: "large-sync",
        provider: "codex",
        providerSessionId: "thread-1",
        projectPath: "/tmp/project",
      },
      { client, signal: signal(), runtime },
    );

    const messages = sent.get(client) ?? [];
    const chunks = messages.filter(
      (message) => message.type === "conversation_mirror_entry_chunk_v1",
    );
    expect(messages.some((message) => message.event === "error")).toBe(false);
    expect(chunks.length).toBeGreaterThan(1);
    expect(chunks.map((message) => message.chunkIndex)).toEqual(
      Array.from({ length: chunks.length }, (_, index) => index),
    );
    for (const chunk of chunks) {
      expect(Buffer.byteLength(JSON.stringify(chunk), "utf8")).toBeLessThanOrEqual(
        MAX_CONVERSATION_MIRROR_EVENT_BYTES,
      );
    }
    const decoded = Buffer.concat(
      chunks.map((message) => Buffer.from(message.payloadBase64, "base64")),
    );
    expect(JSON.parse(decoded.toString("utf8"))).toMatchObject({
      type: "user_input",
      text,
    });
    expect(messages.at(-1)).toMatchObject({
      event: "snapshot_complete",
      entryCount: 1,
    });
    handler.close();
  });

  it("keeps the explicit old-client error for an oversized entry", async () => {
    const process = fakeProcess(async (method) => {
      if (method === "thread/read") return { thread: markerThread(1) };
      if (method !== "thread/items/list") throw new Error(method);
      return {
        data: [
          {
            item: {
              type: "userMessage",
              id: "legacy-large-entry",
              content: [{ type: "text", text: "x".repeat(700_000) }],
            },
          },
        ],
        nextCursor: null,
      };
    });
    const client = {};
    const { runtime, sent } = runtimeFor(process);
    const handler = new ConversationMirrorFeatureHandler(runtime);

    await handler.handle(
      {
        type: "conversation_mirror_sync",
        requestId: "legacy-large-sync",
        provider: "codex",
        providerSessionId: "thread-1",
        projectPath: "/tmp/project",
      },
      { client, signal: signal(), runtime },
    );

    expect(sent.get(client)?.at(-1)).toMatchObject({
      event: "error",
      errorCode: "entry_too_large",
    });
    handler.close();
  });

  it("returns not_modified for a matching revision and gates old clients", async () => {
    const process = fakeProcess(async (method) => {
      if (method === "thread/read") return { thread: markerThread(1) };
      if (method !== "thread/items/list") throw new Error(method);
      return {
        data: [
          {
            turnId: "turn",
            item: { type: "agentMessage", id: "answer", text: "same" },
          },
        ],
        nextCursor: null,
      };
    });
    const supportedClient = {};
    const oldClient = {};
    const supported = new Set<object>([supportedClient]);
    const { runtime, sent } = runtimeFor(process, { supported });
    const handler = new ConversationMirrorFeatureHandler(runtime);
    const reader = new CodexConversationMirrorReader();
    const expected = await reader.readSnapshot(process, "thread-1");
    (process.requestReadOnlyRpc as ReturnType<typeof vi.fn>).mockClear();

    await handler.handle(
      {
        type: "conversation_mirror_sync",
        requestId: "sync",
        provider: "codex",
        providerSessionId: "thread-1",
        projectPath: "/tmp/project",
        knownRevision: expected.revision,
      },
      { client: supportedClient, signal: signal(), runtime },
    );
    await handler.handle(
      {
        type: "conversation_mirror_sync",
        requestId: "old",
        provider: "codex",
        providerSessionId: "thread-1",
        projectPath: "/tmp/project",
      },
      { client: oldClient, signal: signal(), runtime },
    );

    expect(sent.get(supportedClient)?.[0]).toMatchObject({
      event: "accepted",
      requestId: "sync",
    });
    expect(sent.get(supportedClient)?.at(-1)).toMatchObject({
      event: "not_modified",
      revision: expected.revision,
      bridgeInstanceId: "bridge-test",
    });
    expect(sent.get(oldClient)).toBeUndefined();
    handler.close();
  });

  it("shares a same-thread read, keeps client revisions isolated, and cleans disconnects", async () => {
    let generation = 1;
    let markerReads = 0;
    let historyReads = 0;
    const process = fakeProcess(
      async (method: string, params: Record<string, unknown>) => {
        if (method === "thread/read" && params.includeTurns === false) {
          markerReads += 1;
          return { thread: markerThread(generation) };
        }
        if (method === "thread/items/list") {
          historyReads += 1;
          await Promise.resolve();
          return {
            data: [
              {
                turnId: "turn",
                item: {
                  type: "agentMessage",
                  id: "answer",
                  text: generation === 1 ? "before" : "after",
                },
              },
            ],
            nextCursor: null,
          };
        }
        throw new Error(`${method} ${JSON.stringify(params)}`);
      },
    );
    const clientA = {};
    const clientB = {};
    const { runtime, sent } = runtimeFor(process);
    const handler = new ConversationMirrorFeatureHandler(runtime, {
      markerPollMs: 60_000,
      fullReconcileMs: 60_000,
    });
    const makeWatch = (requestId: string) => ({
      type: "conversation_mirror_watch" as const,
      requestId,
      provider: "codex" as const,
      providerSessionId: "thread-1",
      projectPath: "/tmp/project",
    });

    await Promise.all([
      handler.handle(makeWatch("watch-a"), {
        client: clientA,
        signal: signal(),
        runtime,
      }),
      handler.handle(makeWatch("watch-b"), {
        client: clientB,
        signal: signal(),
        runtime,
      }),
    ]);

    expect(historyReads).toBe(1);
    expect(sent.get(clientA)?.map((message) => message.requestId)).toEqual([
      "watch-a",
      "watch-a",
      "watch-a",
      "watch-a",
      "watch-a",
    ]);
    expect(sent.get(clientB)?.map((message) => message.requestId)).toEqual([
      "watch-b",
      "watch-b",
      "watch-b",
      "watch-b",
      "watch-b",
    ]);

    handler.disconnect(clientA);
    const aCount = sent.get(clientA)?.length ?? 0;
    generation = 2;
    const state = [...((handler as any).watches.values() as Iterable<any>)][0];
    await (handler as any).poll(state);

    expect(markerReads).toBeGreaterThanOrEqual(2);
    expect(sent.get(clientA)).toHaveLength(aCount);
    expect(sent.get(clientB)?.slice(-2).map((message) => message.event)).toEqual(
      ["accepted", "patch"],
    );
    expect(sent.get(clientB)?.at(-1)).toMatchObject({
      event: "patch",
      requestId: "watch-b",
      upserts: [
        expect.objectContaining({
          entryId: "answer",
          message: expect.objectContaining({ type: "assistant" }),
        }),
      ],
      deletes: [],
    });

    await (handler as any).reconcile(state);
    expect(sent.get(clientB)?.slice(-2).map((message) => message.event)).toEqual(
      ["accepted", "not_modified"],
    );

    handler.disconnect(clientB);
    expect((handler as any).watches.size).toBe(0);
    handler.close();
  });

  it("does not publish an older in-flight reconcile to later sync and watch requests", async () => {
    let historyReads = 0;
    let signalOlderReadStarted!: () => void;
    let releaseOlderRead!: () => void;
    const olderReadStarted = new Promise<void>((resolve) => {
      signalOlderReadStarted = resolve;
    });
    const olderReadGate = new Promise<void>((resolve) => {
      releaseOlderRead = resolve;
    });
    const timeline: string[] = [];
    const process = fakeProcess(
      async (method: string, params: Record<string, unknown>) => {
        if (method === "thread/read" && params.includeTurns === false) {
          return { thread: markerThread(historyReads + 1) };
        }
        if (method === "thread/items/list") {
          historyReads += 1;
          const readNumber = historyReads;
          timeline.push(`read:${readNumber}`);
          if (readNumber === 2) {
            signalOlderReadStarted();
            await olderReadGate;
          }
          const text =
            readNumber === 1
              ? "initial"
              : readNumber === 2
                ? "older in-flight"
                : "fresh after acceptance";
          return {
            data: [
              {
                turnId: "turn",
                item: {
                  type: "agentMessage",
                  id: "answer",
                  text,
                },
              },
            ],
            nextCursor: null,
          };
        }
        throw new Error(`${method} ${JSON.stringify(params)}`);
      },
    );
    const establishedClient = {};
    const syncClient = {};
    const joiningWatchClient = {};
    const { runtime, sent } = runtimeFor(process);
    const originalSend = runtime.send.bind(runtime);
    (runtime as any).send = (
      client: object,
      message: ConversationMirrorEventMessage,
    ) => {
      if (message.event === "accepted") {
        timeline.push(`accepted:${message.requestId}`);
      }
      originalSend(client, message);
    };
    const handler = new ConversationMirrorFeatureHandler(runtime, {
      markerPollMs: 60_000,
      fullReconcileMs: 60_000,
    });
    const watch = (requestId: string) => ({
      type: "conversation_mirror_watch" as const,
      requestId,
      provider: "codex" as const,
      providerSessionId: "thread-1",
      projectPath: "/tmp/project",
    });

    await handler.handle(watch("watch-established"), {
      client: establishedClient,
      signal: signal(),
      runtime,
    });
    expect(historyReads).toBe(1);

    const state = [...((handler as any).watches.values() as Iterable<any>)][0];
    const olderReconcile = (handler as any).reconcile(
      state,
    ) as Promise<ConversationMirrorSnapshot>;
    await olderReadStarted;

    const sync = handler.handle(
      {
        type: "conversation_mirror_sync",
        requestId: "sync-late",
        provider: "codex",
        providerSessionId: "thread-1",
        projectPath: "/tmp/project",
      },
      { client: syncClient, signal: signal(), runtime },
    );
    const joiningWatch = handler.handle(watch("watch-late"), {
      client: joiningWatchClient,
      signal: signal(),
      runtime,
    });

    expect(sent.get(syncClient)?.map((message) => message.event)).toEqual([
      "accepted",
    ]);
    expect(
      sent.get(joiningWatchClient)?.map((message) => message.event),
    ).toEqual(["accepted"]);
    expect(timeline.indexOf("read:2")).toBeLessThan(
      timeline.indexOf("accepted:sync-late"),
    );
    expect(timeline.indexOf("read:2")).toBeLessThan(
      timeline.indexOf("accepted:watch-late"),
    );

    releaseOlderRead();
    await Promise.all([olderReconcile, sync, joiningWatch]);

    expect(historyReads).toBe(3);
    expect(timeline.indexOf("accepted:sync-late")).toBeLessThan(
      timeline.indexOf("read:3"),
    );
    expect(timeline.indexOf("accepted:watch-late")).toBeLessThan(
      timeline.indexOf("read:3"),
    );
    expect(
      sent
        .get(syncClient)
        ?.find((message) => message.event === "snapshot_page"),
    ).toMatchObject({
      entries: [
        expect.objectContaining({
          message: expect.objectContaining({
            type: "assistant",
            message: expect.objectContaining({
              content: [
                expect.objectContaining({
                  type: "text",
                  text: "fresh after acceptance",
                }),
              ],
            }),
          }),
        }),
      ],
    });
    expect(
      sent
        .get(joiningWatchClient)
        ?.find((message) => message.event === "snapshot_page"),
    ).toMatchObject({
      entries: [
        expect.objectContaining({
          message: expect.objectContaining({
            type: "assistant",
            message: expect.objectContaining({
              content: [
                expect.objectContaining({
                  type: "text",
                  text: "fresh after acceptance",
                }),
              ],
            }),
          }),
        }),
      ],
    });
    expect(JSON.stringify(sent.get(syncClient))).not.toContain(
      "older in-flight",
    );
    expect(JSON.stringify(sent.get(joiningWatchClient))).not.toContain(
      "older in-flight",
    );
    handler.close();
  });

  it("aborts a disconnected watch read so a reconnect can use the permit immediately", async () => {
    let historyReads = 0;
    let signalFirstHistoryStarted!: () => void;
    let signalFirstHistoryAborted!: () => void;
    const firstHistoryStarted = new Promise<void>((resolve) => {
      signalFirstHistoryStarted = resolve;
    });
    const firstHistoryAborted = new Promise<void>((resolve) => {
      signalFirstHistoryAborted = resolve;
    });
    const process = {
      requestReadOnlyRpc: vi.fn(
        async (
          method: string,
          _params: Record<string, unknown>,
          options: { signal: AbortSignal },
        ) => {
          if (method === "thread/read") {
            return { thread: markerThread(historyReads + 1) };
          }
          if (method === "thread/items/list") {
            historyReads += 1;
            if (historyReads === 1) {
              signalFirstHistoryStarted();
              return new Promise((_resolve, reject) => {
                const rejectAborted = () => {
                  signalFirstHistoryAborted();
                  reject(options.signal.reason);
                };
                if (options.signal.aborted) {
                  rejectAborted();
                } else {
                  options.signal.addEventListener("abort", rejectAborted, {
                    once: true,
                  });
                }
              });
            }
            return {
              data: [
                {
                  turnId: "turn-reconnected",
                  item: {
                    type: "agentMessage",
                    id: "reconnected-answer",
                    text: "reconnected",
                  },
                },
              ],
              nextCursor: null,
            };
          }
          throw new Error(method);
        },
      ),
      stop: vi.fn(),
    } as unknown as CodexProcess;
    const clientA = {};
    const clientB = {};
    const { runtime, sent } = runtimeFor(process);
    const handler = new ConversationMirrorFeatureHandler(runtime, {
      markerPollMs: 60_000,
      fullReconcileMs: 60_000,
      maxConcurrentReads: 1,
    });
    const controllerA = new AbortController();
    const watch = (requestId: string) => ({
      type: "conversation_mirror_watch" as const,
      requestId,
      provider: "codex" as const,
      providerSessionId: "thread-1",
      projectPath: "/tmp/project",
    });

    const first = handler.handle(watch("watch-a"), {
      client: clientA,
      signal: controllerA.signal,
      runtime,
    });
    await firstHistoryStarted;
    controllerA.abort();
    handler.disconnect(clientA);
    await firstHistoryAborted;

    const second = handler.handle(watch("watch-b"), {
      client: clientB,
      signal: signal(),
      runtime,
    });
    await Promise.all([first, second]);

    expect(historyReads).toBe(2);
    expect(sent.get(clientB)?.at(-1)).toMatchObject({
      event: "snapshot_complete",
      requestId: "watch-b",
    });
    handler.close();
  });

  it("removes an aborted queued read before it can start a standalone reader", async () => {
    let activeAvailable = true;
    let releaseFirstRead!: () => void;
    let signalFirstReadStarted!: () => void;
    const firstReadStarted = new Promise<void>((resolve) => {
      signalFirstReadStarted = resolve;
    });
    const firstReadGate = new Promise<void>((resolve) => {
      releaseFirstRead = resolve;
    });
    const active = fakeProcess(
      async (method: string, params: Record<string, unknown>) => {
        if (method === "thread/read") {
          return { thread: markerThread(1) };
        }
        if (method === "thread/items/list") {
          expect(params.threadId).toBe("thread-a");
          signalFirstReadStarted();
          await firstReadGate;
          return { data: [], nextCursor: null };
        }
        throw new Error(method);
      },
    );
    const standalone = fakeProcess(
      async (method: string, params: Record<string, unknown>) => {
        if (method === "thread/read") {
          return { thread: markerThread(2) };
        }
        if (method === "thread/items/list") {
          expect(params.threadId).toBe("thread-c");
          return { data: [], nextCursor: null };
        }
        throw new Error(method);
      },
    );
    const clientA = {};
    const clientB = {};
    const clientC = {};
    const { runtime, createStandalone } = runtimeFor(standalone, {
      activeProcess: false,
    });
    runtime.getActiveCodexProcess = () =>
      activeAvailable ? active : undefined;
    const handler = new ConversationMirrorFeatureHandler(runtime, {
      markerPollMs: 60_000,
      fullReconcileMs: 60_000,
      maxConcurrentReads: 1,
    });
    const request = (requestId: string, providerSessionId: string) => ({
      type: "conversation_mirror_watch" as const,
      requestId,
      provider: "codex" as const,
      providerSessionId,
      projectPath: "/tmp/project",
    });

    const first = handler.handle(request("watch-a", "thread-a"), {
      client: clientA,
      signal: signal(),
      runtime,
    });
    await firstReadStarted;
    activeAvailable = false;

    const controllerB = new AbortController();
    let queuedSettled = false;
    const queued = handler
      .handle(request("watch-b", "thread-b"), {
        client: clientB,
        signal: controllerB.signal,
        runtime,
      })
      .then(() => {
        queuedSettled = true;
      });
    controllerB.abort(new Error("client B disconnected"));
    handler.disconnect(clientB);
    await vi.waitFor(() => expect(queuedSettled).toBe(true));
    expect(createStandalone).not.toHaveBeenCalled();

    releaseFirstRead();
    await Promise.all([first, queued]);
    handler.disconnect(clientA);

    await handler.handle(request("watch-c", "thread-c"), {
      client: clientC,
      signal: signal(),
      runtime,
    });
    expect(createStandalone).toHaveBeenCalledTimes(1);
    handler.close();
  });

  it("globally bounds eight simultaneous watch history reads", async () => {
    let enteredHistoryReads = 0;
    let activeHistoryReads = 0;
    let maxActiveHistoryReads = 0;
    const releases: Array<() => void> = [];
    const process = fakeProcess(
      async (method: string, params: Record<string, unknown>) => {
        const threadId = String(params.threadId);
        if (method === "thread/read" && params.includeTurns === false) {
          return {
            thread: {
              id: threadId,
              cwd: "/tmp/project",
              updatedAt: 1,
              status: "idle",
            },
          };
        }
        if (method === "thread/items/list") {
          enteredHistoryReads += 1;
          activeHistoryReads += 1;
          maxActiveHistoryReads = Math.max(
            maxActiveHistoryReads,
            activeHistoryReads,
          );
          await new Promise<void>((resolve) => releases.push(resolve));
          activeHistoryReads -= 1;
          return { data: [], nextCursor: null };
        }
        throw new Error(method);
      },
    );
    const client = {};
    const { runtime } = runtimeFor(process);
    const handler = new ConversationMirrorFeatureHandler(runtime, {
      markerPollMs: 60_000,
      fullReconcileMs: 60_000,
      maxConcurrentReads: 2,
    });

    const pending = Array.from({ length: 8 }, (_, index) =>
      handler.handle(
        {
          type: "conversation_mirror_watch",
          requestId: `watch-${index}`,
          provider: "codex",
          providerSessionId: `thread-${index}`,
          projectPath: "/tmp/project",
        },
        { client, signal: signal(), runtime },
      ),
    );

    for (let completed = 0; completed < 8; completed += 2) {
      await vi.waitFor(() => {
        expect(enteredHistoryReads).toBe(completed + 2);
      });
      expect(activeHistoryReads).toBe(2);
      expect(releases).toHaveLength(2);
      releases.splice(0).forEach((release) => release());
    }
    await Promise.all(pending);

    expect(maxActiveHistoryReads).toBe(2);
    const scheduledDelays = [
      ...((handler as any).watches.values() as Iterable<any>),
    ].map((state) => state.lastScheduledDelayMs as number);
    expect(scheduledDelays).toHaveLength(8);
    expect(
      scheduledDelays.every((delay) => delay >= 48_000 && delay <= 72_000),
    ).toBe(true);
    expect(new Set(scheduledDelays).size).toBeGreaterThan(1);
    handler.close();
  });

  it("backs off failed marker polls and resets after the next success", async () => {
    vi.useFakeTimers();
    const warning = vi.spyOn(console, "warn").mockImplementation(() => {});
    try {
      let failMarker = false;
      const process = fakeProcess(
        async (method: string, params: Record<string, unknown>) => {
          if (method === "thread/read" && params.includeTurns === false) {
            if (failMarker) throw new Error("marker temporarily unavailable");
            return { thread: markerThread(1) };
          }
          if (method === "thread/items/list") {
            return { data: [], nextCursor: null };
          }
          throw new Error(method);
        },
      );
      const client = {};
      const { runtime } = runtimeFor(process);
      const handler = new ConversationMirrorFeatureHandler(runtime, {
        markerPollMs: 100,
        fullReconcileMs: 300_000,
        maxPollBackoffMs: 800,
        pollJitterRatio: 0,
      });

      await handler.handle(
        {
          type: "conversation_mirror_watch",
          requestId: "watch",
          provider: "codex",
          providerSessionId: "thread-1",
          projectPath: "/tmp/project",
        },
        { client, signal: signal(), runtime },
      );
      const state = [
        ...((handler as any).watches.values() as Iterable<any>),
      ][0];
      expect(state.lastScheduledDelayMs).toBe(100);

      failMarker = true;
      await vi.advanceTimersByTimeAsync(100);
      expect(state.pollFailureCount).toBe(1);
      expect(state.lastScheduledDelayMs).toBe(200);

      failMarker = false;
      await vi.advanceTimersByTimeAsync(200);
      expect(state.pollFailureCount).toBe(0);
      expect(state.lastScheduledDelayMs).toBe(100);
      expect(warning).toHaveBeenCalledTimes(1);
      handler.close();
    } finally {
      warning.mockRestore();
      vi.useRealTimers();
    }
  });

  it("drops only a watcher whose incremental delivery fails", async () => {
    let generation = 1;
    const process = fakeProcess(
      async (method: string, params: Record<string, unknown>) => {
        if (method === "thread/read" && params.includeTurns === false) {
          return { thread: markerThread(generation) };
        }
        if (method === "thread/items/list") {
          return {
            data: [
              {
                turnId: "turn",
                item: {
                  type: "agentMessage",
                  id: "answer",
                  text: `generation-${generation}`,
                },
              },
            ],
            nextCursor: null,
          };
        }
        throw new Error(`${method} ${JSON.stringify(params)}`);
      },
    );
    const clientA = {};
    const clientB = {};
    const { runtime, sent } = runtimeFor(process);
    const handler = new ConversationMirrorFeatureHandler(runtime, {
      markerPollMs: 60_000,
      fullReconcileMs: 60_000,
    });
    const watch = (requestId: string) => ({
      type: "conversation_mirror_watch" as const,
      requestId,
      provider: "codex" as const,
      providerSessionId: "thread-1",
      projectPath: "/tmp/project",
    });

    await handler.handle(watch("watch-a"), {
      client: clientA,
      signal: signal(),
      runtime,
    });
    await handler.handle(watch("watch-b"), {
      client: clientB,
      signal: signal(),
      runtime,
    });

    const originalSend = runtime.send.bind(runtime);
    (runtime as any).send = (
      client: object,
      message: ConversationMirrorEventMessage,
    ) => {
      if (client === clientA && message.event === "patch") {
        throw new Error("client A transport failed");
      }
      originalSend(client, message);
    };
    generation = 2;
    const state = [...((handler as any).watches.values() as Iterable<any>)][0];
    await (handler as any).poll(state);

    expect(sent.get(clientA)?.at(-1)).toMatchObject({
      event: "error",
      requestId: "watch-a",
      errorCode: "read_failed",
      error: "client A transport failed",
    });
    expect(sent.get(clientB)?.at(-1)).toMatchObject({
      event: "patch",
      requestId: "watch-b",
    });
    expect(state.clients.has(clientA)).toBe(false);
    expect(state.clients.has(clientB)).toBe(true);
    handler.close();
  });

  it("shares at most one owned standalone process across different watched threads", async () => {
    vi.useFakeTimers();
    try {
      const process = fakeProcess(
        async (method: string, params: Record<string, unknown>) => {
          const threadId = String(params.threadId);
          if (method === "thread/read") {
            return {
              thread: {
                id: threadId,
                cwd: "/tmp/project",
                updatedAt: 1,
                status: "idle",
              },
            };
          }
          if (method === "thread/items/list") {
            return {
              data: [
                {
                  turnId: `turn-${threadId}`,
                  item: {
                    type: "agentMessage",
                    id: `answer-${threadId}`,
                    text: threadId,
                  },
                },
              ],
              nextCursor: null,
            };
          }
          throw new Error(method);
        },
      );
      const clientA = {};
      const clientB = {};
      const { runtime, createStandalone } = runtimeFor(process, {
        activeProcess: false,
      });
      const handler = new ConversationMirrorFeatureHandler(runtime, {
        markerPollMs: 60_000,
        fullReconcileMs: 60_000,
        standaloneIdleMs: 5,
      });

      await Promise.all([
        handler.handle(
          {
            type: "conversation_mirror_watch",
            requestId: "watch-a",
            provider: "codex",
            providerSessionId: "thread-a",
            projectPath: "/tmp/a",
          },
          { client: clientA, signal: signal(), runtime },
        ),
        handler.handle(
          {
            type: "conversation_mirror_watch",
            requestId: "watch-b",
            provider: "codex",
            providerSessionId: "thread-b",
            projectPath: "/tmp/b",
          },
          { client: clientB, signal: signal(), runtime },
        ),
      ]);

      expect(createStandalone).toHaveBeenCalledTimes(1);
      handler.disconnect(clientA);
      handler.disconnect(clientB);
      expect(process.stop).not.toHaveBeenCalled();
      await vi.advanceTimersByTimeAsync(5);
      expect(process.stop).toHaveBeenCalledTimes(1);
      handler.close();
    } finally {
      vi.useRealTimers();
    }
  });

  it("falls back from a failed active reader to the shared standalone only once", async () => {
    const active = fakeProcess(async () => {
      throw new Error("active transport closed");
    });
    const standalone = fakeProcess(
      async (method: string, params: Record<string, unknown>) => {
        if (method === "thread/read") {
          return { thread: markerThread(1) };
        }
        if (method === "thread/items/list") {
          return {
            data: [
              {
                turnId: "turn",
                item: {
                  type: "agentMessage",
                  id: "answer",
                  text: "recovered",
                },
              },
            ],
            nextCursor: null,
          };
        }
        throw new Error(`${method} ${JSON.stringify(params)}`);
      },
    );
    const client = {};
    const { runtime, createStandalone } = runtimeFor(standalone, {
      activeProcess: false,
    });
    runtime.getActiveCodexProcess = () => active;
    const handler = new ConversationMirrorFeatureHandler(runtime);
    const warning = vi.spyOn(console, "warn").mockImplementation(() => {});
    const request = (requestId: string) => ({
      type: "conversation_mirror_sync" as const,
      requestId,
      provider: "codex" as const,
      providerSessionId: "thread-1",
      projectPath: "/tmp/project",
    });

    await handler.handle(request("first"), {
      client,
      signal: signal(),
      runtime,
    });
    await handler.handle(request("second"), {
      client,
      signal: signal(),
      runtime,
    });

    expect(active.requestReadOnlyRpc).toHaveBeenCalledTimes(1);
    expect(createStandalone).toHaveBeenCalledTimes(1);
    expect(warning).toHaveBeenCalledWith(
      expect.stringContaining("using shared standalone"),
    );
    warning.mockRestore();
    handler.close();
  });

  it("does not blacklist or stop healthy readers for RPC domain errors", async () => {
    const active = fakeProcess(async () => {
      throw new CodexRpcError("thread/read", "thread not found", -32602);
    });
    const unusedStandalone = fakeProcess(async () => {
      throw new Error("standalone must not start");
    });
    const client = {};
    const { runtime, createStandalone } = runtimeFor(unusedStandalone, {
      activeProcess: false,
    });
    runtime.getActiveCodexProcess = () => active;
    const handler = new ConversationMirrorFeatureHandler(runtime);
    const request = (requestId: string) => ({
      type: "conversation_mirror_sync" as const,
      requestId,
      provider: "codex" as const,
      providerSessionId: "missing-thread",
      projectPath: "/tmp/project",
    });

    await handler.handle(request("first"), {
      client,
      signal: signal(),
      runtime,
    });
    await handler.handle(request("second"), {
      client,
      signal: signal(),
      runtime,
    });

    expect(active.requestReadOnlyRpc).toHaveBeenCalledTimes(2);
    expect(createStandalone).not.toHaveBeenCalled();
    expect(active.stop).not.toHaveBeenCalled();
    handler.close();

    const owned = fakeProcess(async () => {
      throw new CodexRpcError("thread/read", "thread not found", -32602);
    });
    const ownedClient = {};
    const ownedRuntimeResult = runtimeFor(owned, { activeProcess: false });
    const ownedHandler = new ConversationMirrorFeatureHandler(
      ownedRuntimeResult.runtime,
    );
    await ownedHandler.handle(request("owned-first"), {
      client: ownedClient,
      signal: signal(),
      runtime: ownedRuntimeResult.runtime,
    });
    await ownedHandler.handle(request("owned-second"), {
      client: ownedClient,
      signal: signal(),
      runtime: ownedRuntimeResult.runtime,
    });
    expect(ownedRuntimeResult.createStandalone).toHaveBeenCalledTimes(1);
    expect(owned.stop).not.toHaveBeenCalled();
    ownedHandler.close();
    expect(owned.stop).toHaveBeenCalledTimes(1);
  });

  it("bounds watches per client and globally, then releases capacity on unwatch", async () => {
    const process = fakeProcess(
      async (method: string, params: Record<string, unknown>) => {
        const threadId = String(params.threadId);
        if (method === "thread/read") {
          return {
            thread: {
              id: threadId,
              cwd: "/tmp/project",
              updatedAt: 1,
              status: "idle",
            },
          };
        }
        if (method === "thread/items/list") {
          return { data: [], nextCursor: null };
        }
        throw new Error(method);
      },
    );
    const clientA = {};
    const clientB = {};
    const { runtime, sent } = runtimeFor(process);
    const handler = new ConversationMirrorFeatureHandler(runtime, {
      markerPollMs: 60_000,
      fullReconcileMs: 60_000,
      maxClientWatches: 2,
      maxWatchedThreads: 2,
    });
    const watch = (requestId: string, providerSessionId: string) => ({
      type: "conversation_mirror_watch" as const,
      requestId,
      provider: "codex" as const,
      providerSessionId,
      projectPath: "/tmp/project",
    });

    await handler.handle(watch("a-1", "thread-1"), {
      client: clientA,
      signal: signal(),
      runtime,
    });
    await handler.handle(watch("a-2", "thread-2"), {
      client: clientA,
      signal: signal(),
      runtime,
    });
    await handler.handle(watch("a-over", "thread-3"), {
      client: clientA,
      signal: signal(),
      runtime,
    });
    await handler.handle(watch("b-over", "thread-3"), {
      client: clientB,
      signal: signal(),
      runtime,
    });

    expect(sent.get(clientA)?.at(-1)).toMatchObject({
      event: "error",
      requestId: "a-over",
      errorCode: "invalid_state",
      error: expect.stringContaining("client may watch at most 2"),
    });
    expect(sent.get(clientB)?.at(-1)).toMatchObject({
      event: "error",
      requestId: "b-over",
      errorCode: "invalid_state",
      error: expect.stringContaining("Bridge may watch at most 2"),
    });

    await handler.handle(
      {
        type: "conversation_mirror_unwatch",
        requestId: "release",
        provider: "codex",
        providerSessionId: "thread-1",
      },
      { client: clientA, signal: signal(), runtime },
    );
    await handler.handle(watch("a-3", "thread-3"), {
      client: clientA,
      signal: signal(),
      runtime,
    });

    expect((handler as any).watches.size).toBe(2);
    expect(sent.get(clientA)?.at(-1)).toMatchObject({
      event: "snapshot_complete",
      requestId: "a-3",
    });
    handler.close();
  });

  it("correlates a missing bridge identity error inside the mirror channel", async () => {
    const process = fakeProcess(() => {
      throw new Error("must not read");
    });
    const client = {};
    const { runtime, sent } = runtimeFor(process);
    delete (runtime as { bridgeInstanceId?: string }).bridgeInstanceId;
    const handler = new ConversationMirrorFeatureHandler(runtime);

    await handler.handle(
      {
        type: "conversation_mirror_probe",
        requestId: "identity",
        provider: "codex",
        providerSessionId: "thread",
        projectPath: "/tmp",
      },
      { client, signal: signal(), runtime },
    );

    expect(sent.get(client)).toEqual([
      expect.objectContaining({
        type: "conversation_mirror_event_v1",
        event: "error",
        requestId: "identity",
        bridgeInstanceId: "unavailable",
        errorCode: "invalid_state",
      }),
    ]);
    handler.close();
  });

  it("rejects unsupported providers and unauthorized project paths", async () => {
    const process = fakeProcess(() => {
      throw new Error("must not read");
    });
    const client = {};
    const { runtime, sent } = runtimeFor(process, { pathAllowed: false });
    const handler = new ConversationMirrorFeatureHandler(runtime);

    await handler.handle(
      {
        type: "conversation_mirror_sync",
        requestId: "claude",
        provider: "claude",
        providerSessionId: "session",
        projectPath: "/tmp",
      },
      { client, signal: signal(), runtime },
    );
    await handler.handle(
      {
        type: "conversation_mirror_sync",
        requestId: "path",
        provider: "codex",
        providerSessionId: "thread",
        projectPath: "/forbidden",
      },
      { client, signal: signal(), runtime },
    );

    expect(sent.get(client)).toEqual([
      expect.objectContaining({
        event: "error",
        requestId: "claude",
        errorCode: "unsupported_provider",
      }),
      expect.objectContaining({
        event: "error",
        requestId: "path",
        errorCode: "path_not_allowed",
      }),
    ]);
    handler.close();
  });

  it("authorizes the provider-reported thread cwd before reading history", async () => {
    const process = fakeProcess(
      async (method: string, params: Record<string, unknown>) => {
        if (method === "thread/read" && params.includeTurns === false) {
          return {
            thread: {
              id: "thread-secret",
              cwd: "/secret/project",
              updatedAt: 1,
              status: "idle",
            },
          };
        }
        throw new Error("history must not be read before cwd authorization");
      },
    );
    const client = {};
    const { runtime, sent } = runtimeFor(process);
    runtime.isProjectPathAllowed = (path) => path === "/tmp/project";
    const handler = new ConversationMirrorFeatureHandler(runtime);

    await handler.handle(
      {
        type: "conversation_mirror_sync",
        requestId: "actual-cwd",
        provider: "codex",
        providerSessionId: "thread-secret",
        projectPath: "/tmp/project",
      },
      { client, signal: signal(), runtime },
    );

    expect(sent.get(client)?.at(-1)).toMatchObject({
      event: "error",
      requestId: "actual-cwd",
      errorCode: "path_not_allowed",
    });
    expect(process.requestReadOnlyRpc).toHaveBeenCalledTimes(1);
    handler.close();
  });

  it("fails closed when Codex omits cwd under an enforced path policy", async () => {
    const process = fakeProcess(
      async (method: string, params: Record<string, unknown>) => {
        if (method === "thread/read" && params.includeTurns === false) {
          return {
            thread: {
              id: "thread-without-cwd",
              updatedAt: 1,
              status: "idle",
            },
          };
        }
        throw new Error("history must not be read without an authorized cwd");
      },
    );
    const client = {};
    const { runtime, sent } = runtimeFor(process);
    const handler = new ConversationMirrorFeatureHandler(runtime);

    await handler.handle(
      {
        type: "conversation_mirror_sync",
        requestId: "missing-cwd",
        provider: "codex",
        providerSessionId: "thread-without-cwd",
        projectPath: "/tmp/project",
      },
      { client, signal: signal(), runtime },
    );

    expect(sent.get(client)?.at(-1)).toMatchObject({
      event: "error",
      requestId: "missing-cwd",
      errorCode: "path_not_allowed",
      error: expect.stringContaining("did not report"),
    });
    expect(process.requestReadOnlyRpc).toHaveBeenCalledTimes(1);
    handler.close();
  });
});
