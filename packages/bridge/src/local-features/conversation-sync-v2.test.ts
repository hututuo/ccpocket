import { describe, expect, it, vi } from "vitest";

import type { ServerMessage } from "../parser.js";
import { ConversationSyncV2FeatureHandler } from "./conversation-sync-v2.js";
import {
  APP_SERVER_STATUS_CAPABILITY,
  CONVERSATION_SYNC_V2_CAPABILITY,
  conversationSyncV2ProtocolContribution,
  type ConversationSyncCatalogEntry,
  type ConversationSyncClientMessage,
  type ConversationSyncServerMessage,
  type ConversationSyncStatus,
} from "./slots/conversation-sync-v2-protocol.js";
import type { LocalFeatureRuntime, LocalFeatureSession } from "./runtime.js";

describe("conversation_sync_v2 protocol", () => {
  it("accepts bounded state cursors and rejects duplicate thread identities", () => {
    expect(
      conversationSyncV2ProtocolContribution.parseClient(
        subscribeMessage([
          {
            provider: "codex",
            providerSessionId: "thread-1",
            revision: "revision-1",
          },
        ]),
      ),
    ).toMatchObject({
      type: "conversation_sync_subscribe",
      protocolVersion: 2,
      threadContentStates: [{ providerSessionId: "thread-1" }],
    });

    expect(
      conversationSyncV2ProtocolContribution.parseClient(
        subscribeMessage([
          {
            provider: "codex",
            providerSessionId: "thread-1",
            revision: "revision-1",
          },
          {
            provider: "codex",
            providerSessionId: "thread-1",
            revision: "revision-2",
          },
        ]),
      ),
    ).toBeNull();
  });

  it("keeps page requests read-only and rejects unbounded limits", () => {
    expect(
      conversationSyncV2ProtocolContribution.parseClient({
        type: "conversation_turns_page",
        protocolVersion: 2,
        requestId: "turns-1",
        subscriptionId: "sync-1",
        provider: "codex",
        providerSessionId: "thread-1",
        limit: 5,
        sortDirection: "desc",
        itemsView: "summary",
      }),
    ).toMatchObject({
      type: "conversation_turns_page",
      providerSessionId: "thread-1",
    });
    expect(
      conversationSyncV2ProtocolContribution.parseClient({
        type: "conversation_items_page",
        protocolVersion: 2,
        requestId: "items-1",
        subscriptionId: "sync-1",
        provider: "codex",
        providerSessionId: "thread-1",
        limit: 201,
      }),
    ).toBeNull();
    expect(
      conversationSyncV2ProtocolContribution.parseClient({
        type: "conversation_items_page",
        protocolVersion: 2,
        requestId: "items-2",
        subscriptionId: "sync-1",
        provider: "codex",
        providerSessionId: "thread-1",
        turnId: "turn-1",
        toolUseIds: ["tool-1", "tool-2"],
      }),
    ).toMatchObject({
      type: "conversation_items_page",
      turnId: "turn-1",
      toolUseIds: ["tool-1", "tool-2"],
    });
    expect(
      conversationSyncV2ProtocolContribution.parseClient({
        type: "conversation_items_page",
        protocolVersion: 2,
        requestId: "items-3",
        subscriptionId: "sync-1",
        provider: "codex",
        providerSessionId: "thread-1",
        toolUseIds: ["tool-1"],
      }),
    ).toBeNull();
  });

  it("accepts a bounded per-subscription read watermark", () => {
    expect(
      conversationSyncV2ProtocolContribution.parseClient({
        type: "conversation_sync_read",
        protocolVersion: 2,
        subscriptionId: "sync-1",
        provider: "codex",
        providerSessionId: "thread-1",
        readAt: "2026-07-30T00:00:00.000Z",
      }),
    ).toMatchObject({
      type: "conversation_sync_read",
      providerSessionId: "thread-1",
    });
    expect(
      conversationSyncV2ProtocolContribution.parseClient({
        type: "conversation_sync_read",
        protocolVersion: 2,
        subscriptionId: "sync-1",
        provider: "codex",
        providerSessionId: "thread-1",
        readAt: "not-a-date",
      }),
    ).toBeNull();
  });
});

describe("ConversationSyncV2FeatureHandler", () => {
  it("preserves an older-turn cursor and returns legacy pages chronologically", async () => {
    const historyReader = vi.fn(async (target) => ({
      messages: history(target.providerSessionId),
      nextTurnCursor: "older-turns-1",
    }));
    const fixture = createFixture([seed(0)], historyReader);
    const client = {};
    const subscription = subscribeMessage();

    await fixture.handler.handle(
      subscription,
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(1),
    );
    expect(events(fixture.sent, client, "timeline_page")[0]).toMatchObject({
      hasEarlier: true,
      turnsNextCursor: "older-turns-1",
    });

    await fixture.handler.handle(
      {
        type: "conversation_turns_page",
        protocolVersion: 2,
        requestId: "turns-page-1",
        subscriptionId: subscription.requestId,
        provider: "claude",
        providerSessionId: "session-0",
        cursor: null,
        limit: 5,
        sortDirection: "desc",
        itemsView: "summary",
      },
      context(client, fixture.runtime),
    );

    const response = events(fixture.sent, client, "turns_page_response")[0]!;
    expect(response.data).toHaveLength(1);
    expect(response.data[0]).toMatchObject({
      messages: [
        { type: "user_input", text: "session-0" },
        { type: "assistant" },
      ],
    });
    fixture.handler.close();
  });

  it("sends special state first, limits provider concurrency, and reuses revisions", async () => {
    const seeds = Array.from({ length: 12 }, (_, index) =>
      seed(index, index === 10 ? workingStatus(index) : undefined),
    );
    let activeReads = 0;
    let maxActiveReads = 0;
    const historyReader = vi.fn(async (target) => {
      activeReads += 1;
      maxActiveReads = Math.max(maxActiveReads, activeReads);
      await new Promise<void>((resolve) => setTimeout(resolve, 2));
      activeReads -= 1;
      return history(target.providerSessionId);
    });
    const fixture = createFixture(seeds, historyReader);
    const firstClient = {};

    await fixture.handler.handle(
      subscribeMessage(),
      context(firstClient, fixture.runtime),
    );
    await vi.waitFor(
      () =>
        expect(events(fixture.sent, firstClient, "sync_complete")).toHaveLength(
          1,
        ),
      { timeout: 3_000 },
    );

    const timeline = events(fixture.sent, firstClient, "timeline_page");
    expect(timeline[0]).toMatchObject({
      providerSessionId: "session-10",
    });
    expect(maxActiveReads).toBeLessThanOrEqual(2);
    expect(
      events(fixture.sent, firstClient, "status_changes")
        .flatMap((event) => event.changes)
        .find((status) => status.providerSessionId === "session-0"),
    ).toMatchObject({
      activity: "idle",
      confidence: "unknown",
      runtimeAttachment: "notLoaded",
    });
    for (const message of fixture.sent.get(firstClient) ?? []) {
      expect(
        Buffer.byteLength(JSON.stringify(message), "utf8"),
      ).toBeLessThanOrEqual(64 * 1024);
    }

    const completion = events(fixture.sent, firstClient, "sync_complete")[0]!;
    const readsAfterFirstSync = historyReader.mock.calls.length;
    const secondClient = {};
    await fixture.handler.handle(
      subscribeMessage(completion.nextState.threadContentStates, {
        catalogState: completion.nextState.catalogState,
        statusState: completion.nextState.statusState,
      }),
      context(secondClient, fixture.runtime),
    );
    await vi.waitFor(
      () =>
        expect(
          events(fixture.sent, secondClient, "sync_complete"),
        ).toHaveLength(1),
      { timeout: 3_000 },
    );
    expect(historyReader).toHaveBeenCalledTimes(readsAfterFirstSync);
    fixture.handler.close();
  });

  it("keeps notLoaded status truthful for capable clients and neutral for legacy Mobile", async () => {
    const fixture = createFixture([seed(0)], async (target) =>
      history(target.providerSessionId),
    );
    const legacyClient = {};
    const capableClient = {};
    fixture.runtime.supports = (client: object, type: string) =>
      type === CONVERSATION_SYNC_V2_CAPABILITY ||
      (client === capableClient && type === APP_SERVER_STATUS_CAPABILITY);

    await fixture.handler.handle(
      subscribeMessage([], { statusState: "legacy-status-state" }),
      context(legacyClient, fixture.runtime),
    );
    await fixture.handler.handle(
      subscribeMessage(),
      context(capableClient, fixture.runtime),
    );
    await vi.waitFor(
      () => {
        expect(
          events(fixture.sent, legacyClient, "sync_complete"),
        ).toHaveLength(1);
        expect(
          events(fixture.sent, capableClient, "sync_complete"),
        ).toHaveLength(1);
      },
      { timeout: 3_000 },
    );

    expect(events(fixture.sent, legacyClient, "sync_reset")).toContainEqual(
      expect.objectContaining({ scope: "status" }),
    );
    expect(
      events(fixture.sent, legacyClient, "status_changes")
        .flatMap((event) => event.changes)
        .find((status) => status.providerSessionId === "session-0"),
    ).toMatchObject({
      activity: "idle",
      runtimeAttachment: "notLoaded",
      confidence: "unknown",
    });
    expect(
      events(fixture.sent, capableClient, "status_changes")
        .flatMap((event) => event.changes)
        .find((status) => status.providerSessionId === "session-0"),
    ).toMatchObject({
      activity: "unknown",
      runtimeAttachment: "notLoaded",
      confidence: "unknown",
    });
    fixture.handler.close();
  });

  it("keeps sent but unacknowledged frames within one MiB", async () => {
    const seeds = Array.from({ length: 40 }, (_, index) => seed(index));
    const historyReader = vi.fn(async (target) => [
      {
        type: "user_input" as const,
        text: target.providerSessionId,
        userMessageUuid: `user-${target.providerSessionId}`,
      },
      {
        type: "assistant" as const,
        messageUuid: `assistant-${target.providerSessionId}`,
        message: {
          id: `assistant-${target.providerSessionId}`,
          role: "assistant" as const,
          model: "test",
          content: [{ type: "text" as const, text: "x".repeat(34 * 1024) }],
        },
      },
    ]);
    const fixture = createFixture(seeds, historyReader);
    const client = {};

    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(
      () => expect(historyReader.mock.calls.length).toBeGreaterThan(20),
      {
        timeout: 3_000,
      },
    );
    const sentBytes = (fixture.sent.get(client) ?? []).reduce(
      (total, message) =>
        total + Buffer.byteLength(JSON.stringify(message), "utf8"),
      0,
    );
    expect(sentBytes).toBeLessThanOrEqual(1024 * 1024);
    for (const message of fixture.sent.get(client) ?? []) {
      expect(
        Buffer.byteLength(JSON.stringify(message), "utf8"),
      ).toBeLessThanOrEqual(64 * 1024);
    }
    fixture.handler.close();
  });

  it("bounds catalog display text before sending it to Mobile", async () => {
    const oversized = seed(0);
    oversized.entry.name = "n".repeat(800);
    oversized.entry.summary = "s".repeat(8_000);
    oversized.entry.firstPrompt = `${"p".repeat(4_094)}😀${"x".repeat(24_000)}`;
    const fixture = createFixture(
      [oversized],
      vi.fn(async (target) => history(target.providerSessionId)),
    );
    const client = {};

    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "catalog_changes")).toHaveLength(1),
    );

    const entry = events(fixture.sent, client, "catalog_changes")[0]!
      .created[0]!;
    expect(entry.name).toHaveLength(512);
    expect(entry.summary).toHaveLength(4_096);
    expect(entry.firstPrompt).toHaveLength(4_095);
    expect(entry.firstPrompt).toMatch(/…$/);
    expect(entry.firstPrompt).not.toContain("\ud83d");
    for (const message of fixture.sent.get(client) ?? []) {
      expect(
        Buffer.byteLength(JSON.stringify(message), "utf8"),
      ).toBeLessThanOrEqual(64 * 1024);
    }
    fixture.handler.close();
  });

  it("returns bounded detached tool details without a runtime session", async () => {
    const historyReader = vi.fn(async () => [
      {
        type: "user_input" as const,
        text: "prompt",
        userMessageUuid: "user-session-0",
      },
      {
        type: "assistant" as const,
        message: {
          id: "assistant-tools",
          role: "assistant" as const,
          model: "test",
          content: [
            {
              type: "tool_use" as const,
              id: "tool-1",
              name: "Read",
              input: { path: "/outside/runtime.txt" },
            },
          ],
        },
      },
      {
        type: "tool_result" as const,
        toolUseId: "tool-1",
        toolName: "Read",
        content: "detail result",
      },
    ]);
    const fixture = createFixture([seed(0)], historyReader);
    const client = {};
    const subscription = subscribeMessage();
    await fixture.handler.handle(
      subscription,
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(1),
    );

    await fixture.handler.handle(
      {
        type: "conversation_items_page",
        protocolVersion: 2,
        requestId: "items-page-1",
        subscriptionId: subscription.requestId,
        provider: "claude",
        providerSessionId: "session-0",
        turnId: "legacy-turn:user-session-0",
        toolUseIds: ["tool-1"],
        limit: 200,
        sortDirection: "asc",
      },
      context(client, fixture.runtime),
    );

    expect(
      events(fixture.sent, client, "items_page_response")[0],
    ).toMatchObject({
      requestId: "items-page-1",
      turnId: "legacy-turn:user-session-0",
      data: [
        {
          type: "history_tool_details",
          details: [
            {
              toolUseId: "tool-1",
              toolName: "Read",
              input: { path: "/outside/runtime.txt" },
              result: { content: "detail result" },
            },
          ],
        },
      ],
    });
    fixture.handler.close();
  });

  it("publishes a catalog change immediately without rereading a clean catalog", async () => {
    const seeds = [seed(0)];
    const historyReader = vi.fn(async (target) =>
      history(target.providerSessionId),
    );
    const fixture = createFixture(seeds, historyReader);
    const client = {};

    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(1),
    );
    const initialCatalogReads = fixture.catalogReader.mock.calls.length;

    seeds.push(seed(1));
    fixture.handler.sessionCatalogChanged();

    await vi.waitFor(() =>
      expect(
        events(fixture.sent, client, "catalog_changes").some((event) =>
          event.created.some(
            (entry) => entry.providerSessionId === "session-1",
          ),
        ),
      ).toBe(true),
    );
    expect(fixture.catalogReader).toHaveBeenCalledTimes(
      initialCatalogReads + 1,
    );
    fixture.handler.close();
  });

  it("coalesces live deltas into one history read without rescanning the catalog", async () => {
    const historyReader = vi.fn(async (target) =>
      history(target.providerSessionId),
    );
    const fixture = createFixture([seed(0)], historyReader);
    const client = {};
    fixture.runtime.getProviderSessionId = () => "session-0";
    const session: LocalFeatureSession = {
      id: "runtime-0",
      provider: "claude",
      process: {},
      projectPath: "/project/0",
    };

    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(1),
    );
    const initialHistoryReads = historyReader.mock.calls.length;

    for (let index = 0; index < 100; index += 1) {
      fixture.handler.sessionMessage(session, {
        type: index % 2 === 0 ? "stream_delta" : "thinking_delta",
        text: `delta-${index}`,
      });
    }

    await vi.waitFor(
      () =>
        expect(events(fixture.sent, client, "sync_complete")).toHaveLength(2),
      { timeout: 3_000 },
    );
    expect(historyReader).toHaveBeenCalledTimes(initialHistoryReads + 1);
    expect(fixture.catalogReader).toHaveBeenCalledTimes(1);
    fixture.handler.close();
  });

  it("does not label an in-flight stale snapshot with a newer live revision", async () => {
    let resolveFirstRead:
      | ((messages: ServerMessage[]) => void)
      | undefined;
    const firstRead = new Promise<ServerMessage[]>((resolve) => {
      resolveFirstRead = resolve;
    });
    let readCount = 0;
    const historyReader = vi.fn(async (target) => {
      readCount += 1;
      if (readCount === 1) return firstRead;
      return history(`${target.providerSessionId}-new`);
    });
    const fixture = createFixture([seed(0)], historyReader);
    const client = {};
    fixture.runtime.getProviderSessionId = () => "session-0";
    const session: LocalFeatureSession = {
      id: "runtime-0",
      provider: "claude",
      process: {},
      projectPath: "/project/0",
    };

    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() => expect(historyReader).toHaveBeenCalledTimes(1));

    fixture.handler.sessionMessage(session, {
      type: "assistant",
      messageUuid: "assistant-live",
      message: {
        id: "assistant-live",
        role: "assistant",
        model: "test",
        content: [{ type: "text", text: "new live content" }],
      },
    });
    resolveFirstRead!(history("session-0-old"));

    await vi.waitFor(
      () => expect(historyReader).toHaveBeenCalledTimes(2),
      { timeout: 3_000 },
    );
    await vi.waitFor(
      () =>
        expect(events(fixture.sent, client, "sync_complete").length).toBeGreaterThanOrEqual(2),
      { timeout: 3_000 },
    );
    const revisions = new Set(
      events(fixture.sent, client, "timeline_page").map(
        (event) => event.revision,
      ),
    );
    expect(revisions.size).toBeGreaterThanOrEqual(2);
    fixture.handler.close();
  });

  it("pushes Need You state without rereading conversation content", async () => {
    const historyReader = vi.fn(async (target) =>
      history(target.providerSessionId),
    );
    const fixture = createFixture([seed(0)], historyReader);
    const client = {};
    fixture.runtime.getProviderSessionId = () => "session-0";
    let pendingApproval = false;
    fixture.runtime.listRuntimeConversationStates = () => [
      {
        bridgeSessionId: "runtime-0",
        provider: "claude",
        providerSessionId: "session-0",
        projectPath: "/project/0",
        processStatus: pendingApproval ? "waiting_approval" : "idle",
        ...(pendingApproval
          ? {
              pendingAttention: {
                requestId: "approval-1",
                kind: "approval" as const,
              },
            }
          : {}),
        observedAt: new Date().toISOString(),
      },
    ];
    const session: LocalFeatureSession = {
      id: "runtime-0",
      provider: "claude",
      process: {},
      projectPath: "/project/0",
    };

    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(1),
    );
    const initialHistoryReads = historyReader.mock.calls.length;

    pendingApproval = true;
    fixture.handler.sessionMessage(session, {
      type: "permission_request",
      toolUseId: "approval-1",
      toolName: "Bash",
      input: {},
    });

    await vi.waitFor(() =>
      expect(
        events(fixture.sent, client, "status_changes").some((event) =>
          event.changes.some(
            (status) =>
              status.providerSessionId === "session-0" &&
              status.attention === "approval",
          ),
        ),
      ).toBe(true),
    );
    expect(historyReader).toHaveBeenCalledTimes(initialHistoryReads);
    expect(fixture.catalogReader).toHaveBeenCalledTimes(1);
    fixture.handler.close();
  });
});

function createFixture(
  seeds: Array<{
    entry: ConversationSyncCatalogEntry;
    status: ConversationSyncStatus;
  }>,
  historyReader: (target: {
    provider: "claude" | "codex";
    providerSessionId: string;
  }) => Promise<
    | ServerMessage[]
    | { messages: ServerMessage[]; nextTurnCursor: string | null }
  >,
) {
  const sent = new Map<object, ConversationSyncServerMessage[]>();
  const catalogReader = vi.fn(async () => seeds);
  const runtime: LocalFeatureRuntime = {
    bridgeInstanceId: "bridge-1",
    codexSourceId: "source-1",
    getSession: () => undefined,
    getCodexThreadId: () => undefined,
    getProviderSessionId: () => undefined,
    getActiveCodexProcess: () => null,
    createStandaloneCodexProcess: async () => {
      throw new Error("not used");
    },
    send(client: object, message: ConversationSyncServerMessage) {
      const messages = sent.get(client) ?? [];
      messages.push(message);
      sent.set(client, messages);
    },
    isClientOpen: () => true,
    supports: (_client: object, type: string) =>
      type === CONVERSATION_SYNC_V2_CAPABILITY,
  };
  return {
    runtime,
    sent,
    catalogReader,
    handler: new ConversationSyncV2FeatureHandler(runtime, {
      catalogReader,
      statusReader: async () => new Map(),
      historyReader,
      statusWatchdogMs: 60_000,
      coldReconcileMs: 60_000,
    }),
  };
}

function context(client: object, runtime: LocalFeatureRuntime) {
  return {
    client,
    signal: new AbortController().signal,
    runtime,
  };
}

function subscribeMessage(
  threadContentStates: Array<{
    provider: "claude" | "codex";
    providerSessionId: string;
    revision: string;
  }> = [],
  state: { catalogState?: string; statusState?: string } = {},
): Extract<
  ConversationSyncClientMessage,
  { type: "conversation_sync_subscribe" }
> {
  return {
    type: "conversation_sync_subscribe",
    protocolVersion: 2,
    requestId: `sync-${Math.random().toString(36).slice(2)}`,
    ...state,
    threadContentStates,
    readWatermarks: [],
  };
}

function seed(
  index: number,
  status = unknownStatus(index),
): {
  entry: ConversationSyncCatalogEntry;
  status: ConversationSyncStatus;
} {
  const recency = new Date(Date.now() - index * 60_000).toISOString();
  return {
    entry: {
      provider: "claude",
      providerSessionId: `session-${index}`,
      revision: `revision-${index}`,
      projectPath: `/project/${index}`,
      firstPrompt: `Conversation ${index}`,
      createdAt: recency,
      modifiedAt: recency,
      recencyAt: recency,
      availability: "durable",
    },
    status,
  };
}

function unknownStatus(index: number): ConversationSyncStatus {
  return {
    provider: "claude",
    providerSessionId: `session-${index}`,
    activity: "unknown",
    attention: "none",
    result: "none",
    runtimeAttachment: "notLoaded",
    source: "legacyRollout",
    confidence: "unknown",
    observedAt: new Date(Date.now() - index * 60_000).toISOString(),
  };
}

function workingStatus(index: number): ConversationSyncStatus {
  return {
    ...unknownStatus(index),
    activity: "working",
    runtimeAttachment: "loaded",
    source: "bridgeRuntime",
    confidence: "authoritative",
  };
}

function history(id: string): ServerMessage[] {
  return [
    {
      type: "user_input",
      text: id,
      userMessageUuid: `user-${id}`,
    },
    {
      type: "assistant",
      messageUuid: `assistant-${id}`,
      message: {
        id: `assistant-${id}`,
        role: "assistant",
        model: "test",
        content: [{ type: "text", text: `reply-${id}` }],
      },
    },
  ];
}

function events<Event extends ConversationSyncServerMessage["event"]>(
  sent: Map<object, ConversationSyncServerMessage[]>,
  client: object,
  event: Event,
): Array<Extract<ConversationSyncServerMessage, { event: Event }>> {
  return (sent.get(client) ?? []).filter(
    (
      message,
    ): message is Extract<ConversationSyncServerMessage, { event: Event }> =>
      message.event === event,
  );
}
