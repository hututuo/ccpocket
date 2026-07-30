import { describe, expect, it, vi } from "vitest";

import type { CodexProcess } from "../codex-process.js";
import type { ServerMessage } from "../parser.js";
import { buildConversationContentSnapshot } from "./conversation-content-sync.js";
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
  it("keeps one subscription across later sync batches", async () => {
    const fixture = createFixture([seed(0)], async (target) =>
      history(target.providerSessionId),
    );
    const client = {};
    const subscription = subscribeMessage();

    await fixture.handler.handle(
      subscription,
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(1),
    );
    const firstComplete = events(fixture.sent, client, "sync_complete")[0]!;
    await fixture.handler.handle(
      {
        type: "conversation_sync_ack",
        protocolVersion: 2,
        subscriptionId: subscription.requestId,
        sequence: firstComplete.sequence,
      },
      context(client, fixture.runtime),
    );
    await fixture.handler.handle(
      {
        type: "conversation_sync_read",
        protocolVersion: 2,
        subscriptionId: subscription.requestId,
        provider: "claude",
        providerSessionId: "session-0",
        readAt: new Date().toISOString(),
      },
      context(client, fixture.runtime),
    );

    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_begin")).toHaveLength(2),
    );
    const begins = events(fixture.sent, client, "sync_begin");
    expect(begins[1]).toMatchObject({
      requestId: subscription.requestId,
      subscriptionId: subscription.requestId,
    });
    expect(begins[1]!.sequence).toBeGreaterThan(firstComplete.sequence);
    fixture.handler.close();
  });

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
      phase: "priority",
      timelineIndex: 0,
      timelineCount: 1,
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

  it("re-reads oversized Codex turn pages with an exact bounded cursor", async () => {
    const turns = Array.from({ length: 4 }, (_, index) => ({
      id: `turn-${index}`,
      items: [
        {
          type: "agentMessage",
          id: `assistant-${index}`,
          text: `${index}:${"x".repeat(30 * 1024)}`,
        },
      ],
    }));
    const listThreadTurns = vi.fn(
      async ({ limit }: { limit?: number | null }) => {
        const pageLimit = limit ?? turns.length;
        return {
          data: turns.slice(0, pageLimit),
          nextCursor: pageLimit < turns.length ? `after-${pageLimit}` : null,
        };
      },
    );
    const fixture = createCodexPageFixture({ listThreadTurns });
    const subscription = subscribeMessage();
    await fixture.handler.handle(
      subscription,
      context(fixture.client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, fixture.client, "sync_complete"),
      ).toHaveLength(1),
    );

    await fixture.handler.handle(
      {
        type: "conversation_turns_page",
        protocolVersion: 2,
        requestId: "bounded-turns",
        subscriptionId: subscription.requestId,
        provider: "codex",
        providerSessionId: "thread-bounded",
        limit: 4,
        sortDirection: "desc",
        itemsView: "full",
      },
      context(fixture.client, fixture.runtime),
    );

    const response = events(
      fixture.sent,
      fixture.client,
      "turns_page_response",
    ).find((event) => event.requestId === "bounded-turns")!;
    const finalLimit = listThreadTurns.mock.calls.at(-1)![0].limit!;
    expect(
      listThreadTurns.mock.calls.map(([request]) => request.limit),
    ).toEqual(expect.arrayContaining([4, finalLimit]));
    expect(listThreadTurns).toHaveBeenCalledTimes(
      decreasingLimitCallCount(4, finalLimit),
    );
    expect(response.data).toHaveLength(finalLimit);
    expect(response.nextCursor).toBe(`after-${finalLimit}`);
    expect(
      Buffer.byteLength(JSON.stringify(response), "utf8"),
    ).toBeLessThanOrEqual(64 * 1024);
    fixture.handler.close();
  });

  it("projects one oversized Codex turn with stable identity and an explicit gap", async () => {
    const listThreadTurns = vi.fn(async () => ({
      data: [
        {
          id: "turn-oversized",
          items: [
            {
              type: "agentMessage",
              id: "assistant-oversized",
              text: "z".repeat(100 * 1024),
            },
          ],
        },
      ],
      nextCursor: "after-oversized",
    }));
    const fixture = createCodexPageFixture({ listThreadTurns });
    const subscription = subscribeMessage();
    await fixture.handler.handle(
      subscription,
      context(fixture.client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, fixture.client, "sync_complete"),
      ).toHaveLength(1),
    );

    await fixture.handler.handle(
      {
        type: "conversation_turns_page",
        protocolVersion: 2,
        requestId: "projected-turn",
        subscriptionId: subscription.requestId,
        provider: "codex",
        providerSessionId: "thread-oversized",
        limit: 1,
        sortDirection: "desc",
        itemsView: "full",
      },
      context(fixture.client, fixture.runtime),
    );

    const response = events(
      fixture.sent,
      fixture.client,
      "turns_page_response",
    ).find((event) => event.requestId === "projected-turn")!;
    expect(response.nextCursor).toBe("after-oversized");
    expect(response.data[0]).toMatchObject({
      turnId: "turn-oversized",
      itemsView: "summary",
      latestTurnComplete: false,
      latestTurnGap: {
        turnId: "turn-oversized",
        payloadOmitted: true,
      },
    });
    expect(JSON.stringify(response.data[0])).toContain("assistant-oversized");
    expect(JSON.stringify(response.data[0])).toContain("truncated");
    expect(
      Buffer.byteLength(JSON.stringify(response), "utf8"),
    ).toBeLessThanOrEqual(64 * 1024);
    fixture.handler.close();
  });

  it("re-reads oversized Codex item pages without skipping provider items", async () => {
    const items = Array.from({ length: 4 }, (_, index) => ({
      turnId: "turn-items",
      item: {
        type: "agentMessage",
        id: `item-${index}`,
        text: `${index}:${"y".repeat(30 * 1024)}`,
      },
    }));
    const listThreadItems = vi.fn(
      async ({ limit }: { limit?: number | null }) => {
        const pageLimit = limit ?? items.length;
        return {
          data: items.slice(0, pageLimit),
          nextCursor:
            pageLimit < items.length ? `items-after-${pageLimit}` : null,
        };
      },
    );
    const fixture = createCodexPageFixture({ listThreadItems });
    const subscription = subscribeMessage();
    await fixture.handler.handle(
      subscription,
      context(fixture.client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, fixture.client, "sync_complete"),
      ).toHaveLength(1),
    );

    await fixture.handler.handle(
      {
        type: "conversation_items_page",
        protocolVersion: 2,
        requestId: "bounded-items",
        subscriptionId: subscription.requestId,
        provider: "codex",
        providerSessionId: "thread-items",
        turnId: "turn-items",
        limit: 4,
        sortDirection: "asc",
      },
      context(fixture.client, fixture.runtime),
    );

    const response = events(
      fixture.sent,
      fixture.client,
      "items_page_response",
    ).find((event) => event.requestId === "bounded-items")!;
    const finalLimit = listThreadItems.mock.calls.at(-1)![0].limit!;
    expect(listThreadItems).toHaveBeenCalledTimes(
      decreasingLimitCallCount(4, finalLimit),
    );
    expect(response.nextCursor).toBe(`items-after-${finalLimit}`);
    expect(
      Buffer.byteLength(JSON.stringify(response), "utf8"),
    ).toBeLessThanOrEqual(64 * 1024);
    fixture.handler.close();
  });

  it("fails one oversized Codex item without advancing its provider cursor", async () => {
    const listThreadItems = vi.fn(async () => ({
      data: [
        {
          turnId: "turn-one-large-item",
          item: {
            type: "agentMessage",
            id: "item-one-large",
            text: "x".repeat(100 * 1024),
          },
        },
      ],
      nextCursor: "after-one-large-item",
    }));
    const fixture = createCodexPageFixture({ listThreadItems });
    const subscription = subscribeMessage();
    await fixture.handler.handle(
      subscription,
      context(fixture.client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, fixture.client, "sync_complete"),
      ).toHaveLength(1),
    );

    await fixture.handler.handle(
      {
        type: "conversation_items_page",
        protocolVersion: 2,
        requestId: "one-large-item",
        subscriptionId: subscription.requestId,
        provider: "codex",
        providerSessionId: "thread-one-large-item",
        turnId: "turn-one-large-item",
        cursor: "before-one-large-item",
        limit: 1,
        sortDirection: "asc",
      },
      context(fixture.client, fixture.runtime),
    );

    expect(
      events(fixture.sent, fixture.client, "items_page_response").find(
        (event) => event.requestId === "one-large-item",
      ),
    ).toBeUndefined();
    expect(
      events(fixture.sent, fixture.client, "error").find(
        (event) => event.requestId === "one-large-item",
      ),
    ).toMatchObject({
      errorCode: "items_page_failed",
      error: expect.stringContaining("retry with the same cursor"),
    });
    expect(listThreadItems).toHaveBeenCalledTimes(1);
    expect(listThreadItems.mock.calls[0]![0]).toMatchObject({
      cursor: "before-one-large-item",
      limit: 1,
    });
    fixture.handler.close();
  });

  it("bounds raw Codex turns before the real conversion and detail path", async () => {
    let latePayloadReads = 0;
    const items: Array<Record<string, unknown>> = Array.from(
      { length: 12 },
      (_, index) => ({
        type: "agentMessage",
        id: `bounded-raw-${index}`,
        text: `${index}:${"r".repeat(30 * 1024)}`,
      }),
    );
    items.push({
      type: "agentMessage",
      id: "late-unread-item",
      get text() {
        latePayloadReads += 1;
        throw new Error("late raw payload must not be materialized");
      },
    });
    const listThreadTurns = vi.fn(async () => ({
      data: [{ id: "turn-bounded-raw", items }],
      nextCursor: "after-bounded-raw",
    }));
    const fixture = createCodexPageFixture({ listThreadTurns });
    const subscription = subscribeMessage();
    await fixture.handler.handle(
      subscription,
      context(fixture.client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, fixture.client, "sync_complete"),
      ).toHaveLength(1),
    );

    await fixture.handler.handle(
      {
        type: "conversation_turns_page",
        protocolVersion: 2,
        requestId: "bounded-raw-turn",
        subscriptionId: subscription.requestId,
        provider: "codex",
        providerSessionId: "thread-bounded-raw",
        limit: 1,
        sortDirection: "desc",
        itemsView: "full",
      },
      context(fixture.client, fixture.runtime),
    );

    const response = events(
      fixture.sent,
      fixture.client,
      "turns_page_response",
    ).find((event) => event.requestId === "bounded-raw-turn")!;
    expect(latePayloadReads).toBe(0);
    expect(response.data[0]).toMatchObject({
      turnId: "turn-bounded-raw",
      itemsView: "summary",
      latestTurnComplete: false,
      latestTurnGap: {
        turnId: "turn-bounded-raw",
        payloadOmitted: true,
        repair: "items_page",
      },
    });
    expect(
      Buffer.byteLength(JSON.stringify(response), "utf8"),
    ).toBeLessThanOrEqual(64 * 1024);
    fixture.handler.close();
  });

  it("keeps a valid turns response queued without a false page error when send throws", async () => {
    const listThreadTurns = vi.fn(async () => ({
      data: [
        {
          id: "turn-send-retry",
          items: [
            {
              type: "agentMessage",
              id: "answer-send-retry",
              text: "answer",
            },
          ],
        },
      ],
      nextCursor: null,
    }));
    const fixture = createCodexPageFixture({ listThreadTurns });
    const subscriptionMessage = subscribeMessage();
    await fixture.handler.handle(
      subscriptionMessage,
      context(fixture.client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, fixture.client, "sync_complete"),
      ).toHaveLength(1),
    );
    const internal = fixture.handler as unknown as {
      subscriptions: Map<
        object,
        {
          nextSequence: number;
          outbound: Array<{ message: ConversationSyncServerMessage }>;
        }
      >;
      flush(client: object, subscription: object): void;
    };
    const state = internal.subscriptions.get(fixture.client)!;
    const sequenceBefore = state.nextSequence;
    const originalSend = fixture.runtime.send;
    let failed = false;
    fixture.runtime.send = (client, message) => {
      if (
        !failed &&
        (message as ConversationSyncServerMessage).event ===
          "turns_page_response"
      ) {
        failed = true;
        throw new Error("socket write failed once");
      }
      originalSend(client, message);
    };

    await fixture.handler.handle(
      {
        type: "conversation_turns_page",
        protocolVersion: 2,
        requestId: "turns-send-retry",
        subscriptionId: subscriptionMessage.requestId,
        provider: "codex",
        providerSessionId: "thread-send-retry",
        limit: 1,
        sortDirection: "desc",
        itemsView: "summary",
      },
      context(fixture.client, fixture.runtime),
    );

    expect(state.outbound).toHaveLength(1);
    expect(state.outbound[0]!.message).toMatchObject({
      event: "turns_page_response",
      requestId: "turns-send-retry",
      sequence: sequenceBefore + 1,
    });
    expect(
      events(fixture.sent, fixture.client, "error").find(
        (event) => event.requestId === "turns-send-retry",
      ),
    ).toBeUndefined();

    internal.flush(fixture.client, state);
    const delivered = events(
      fixture.sent,
      fixture.client,
      "turns_page_response",
    ).find((event) => event.requestId === "turns-send-retry")!;
    expect(delivered.sequence).toBe(sequenceBefore + 1);
    expect(state.outbound).toHaveLength(0);

    await fixture.handler.handle(
      {
        type: "conversation_turns_page",
        protocolVersion: 2,
        requestId: "turns-after-retry",
        subscriptionId: subscriptionMessage.requestId,
        provider: "codex",
        providerSessionId: "thread-send-retry",
        limit: 1,
        sortDirection: "desc",
        itemsView: "summary",
      },
      context(fixture.client, fixture.runtime),
    );
    expect(
      events(fixture.sent, fixture.client, "turns_page_response").find(
        (event) => event.requestId === "turns-after-retry",
      )?.sequence,
    ).toBe(sequenceBefore + 2);
    fixture.handler.close();
  });

  it("keeps a valid items response queued without a false page error when send throws", async () => {
    const listThreadItems = vi.fn(async () => ({
      data: [
        {
          turnId: "turn-items-send-retry",
          item: {
            type: "agentMessage",
            id: "item-send-retry",
            text: "answer",
          },
        },
      ],
      nextCursor: null,
    }));
    const fixture = createCodexPageFixture({ listThreadItems });
    const subscriptionMessage = subscribeMessage();
    await fixture.handler.handle(
      subscriptionMessage,
      context(fixture.client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, fixture.client, "sync_complete"),
      ).toHaveLength(1),
    );
    const internal = fixture.handler as unknown as {
      subscriptions: Map<
        object,
        {
          nextSequence: number;
          outbound: Array<{ message: ConversationSyncServerMessage }>;
        }
      >;
      flush(client: object, subscription: object): void;
    };
    const state = internal.subscriptions.get(fixture.client)!;
    const sequenceBefore = state.nextSequence;
    const originalSend = fixture.runtime.send;
    let failed = false;
    fixture.runtime.send = (client, message) => {
      if (
        !failed &&
        (message as ConversationSyncServerMessage).event ===
          "items_page_response"
      ) {
        failed = true;
        throw new Error("socket write failed once");
      }
      originalSend(client, message);
    };

    await fixture.handler.handle(
      {
        type: "conversation_items_page",
        protocolVersion: 2,
        requestId: "items-send-retry",
        subscriptionId: subscriptionMessage.requestId,
        provider: "codex",
        providerSessionId: "thread-items-send-retry",
        turnId: "turn-items-send-retry",
        limit: 1,
        sortDirection: "asc",
      },
      context(fixture.client, fixture.runtime),
    );

    expect(state.outbound).toHaveLength(1);
    expect(state.outbound[0]!.message).toMatchObject({
      event: "items_page_response",
      requestId: "items-send-retry",
      sequence: sequenceBefore + 1,
    });
    expect(
      events(fixture.sent, fixture.client, "error").find(
        (event) => event.requestId === "items-send-retry",
      ),
    ).toBeUndefined();

    internal.flush(fixture.client, state);
    const delivered = events(
      fixture.sent,
      fixture.client,
      "items_page_response",
    ).find((event) => event.requestId === "items-send-retry")!;
    expect(delivered.sequence).toBe(sequenceBefore + 1);
    expect(state.outbound).toHaveLength(0);

    await fixture.handler.handle(
      {
        type: "conversation_items_page",
        protocolVersion: 2,
        requestId: "items-after-retry",
        subscriptionId: subscriptionMessage.requestId,
        provider: "codex",
        providerSessionId: "thread-items-send-retry",
        turnId: "turn-items-send-retry",
        limit: 1,
        sortDirection: "asc",
      },
      context(fixture.client, fixture.runtime),
    );
    expect(
      events(fixture.sent, fixture.client, "items_page_response").find(
        (event) => event.requestId === "items-after-retry",
      )?.sequence,
    ).toBe(sequenceBefore + 2);
    fixture.handler.close();
  });

  it("falls back to legacy paging only for unsupported Codex reads", async () => {
    const listThreadTurns = vi.fn(async () => {
      throw new Error("Method not found");
    });
    const listThreadItems = vi.fn(async () => {
      throw new Error("unknown method thread/items/list");
    });
    const historyReader = vi.fn(async () => [
      {
        type: "user_input" as const,
        text: "legacy prompt",
        userMessageUuid: "user-fallback",
      },
      {
        type: "assistant" as const,
        historyTurnId: "legacy-turn:user-fallback",
        messageUuid: "legacy-answer",
        message: {
          id: "legacy-answer",
          role: "assistant" as const,
          model: "test",
          content: [{ type: "text" as const, text: "legacy answer" }],
        },
      },
    ]);
    const fixture = createCodexPageFixture(
      { listThreadTurns, listThreadItems },
      historyReader,
    );
    const subscription = subscribeMessage();
    await fixture.handler.handle(
      subscription,
      context(fixture.client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, fixture.client, "sync_complete"),
      ).toHaveLength(1),
    );

    await fixture.handler.handle(
      {
        type: "conversation_turns_page",
        protocolVersion: 2,
        requestId: "legacy-turns",
        subscriptionId: subscription.requestId,
        provider: "codex",
        providerSessionId: "thread-legacy",
        limit: 5,
        sortDirection: "desc",
        itemsView: "summary",
      },
      context(fixture.client, fixture.runtime),
    );
    await fixture.handler.handle(
      {
        type: "conversation_items_page",
        protocolVersion: 2,
        requestId: "legacy-items",
        subscriptionId: subscription.requestId,
        provider: "codex",
        providerSessionId: "thread-legacy",
        turnId: "legacy-turn:user-fallback",
        limit: 50,
        sortDirection: "asc",
      },
      context(fixture.client, fixture.runtime),
    );

    expect(
      events(fixture.sent, fixture.client, "turns_page_response").find(
        (event) => event.requestId === "legacy-turns",
      ),
    ).toMatchObject({
      nextCursor: null,
      data: [{ turnId: expect.any(String) }],
    });
    expect(
      events(fixture.sent, fixture.client, "items_page_response").find(
        (event) => event.requestId === "legacy-items",
      ),
    ).toMatchObject({
      nextCursor: null,
      data: [
        { type: "user_input" },
        { type: "assistant", messageUuid: "legacy-answer" },
      ],
    });
    expect(listThreadItems).toHaveBeenCalledTimes(1);
    expect(listThreadTurns).toHaveBeenCalledTimes(2);
    expect(historyReader).toHaveBeenCalledTimes(2);
    fixture.handler.close();
  });

  it("preserves consumable opaque legacy cursors and rejects unproven ones", async () => {
    const listThreadTurns = vi.fn(async () => {
      throw new Error("Method not found");
    });
    const historyReader = vi.fn(
      async (
        _target: unknown,
        request?: { cursor: string | null },
      ): Promise<{
        messages: ServerMessage[];
        nextTurnCursor: string | null;
        sourceCursor?: string | null;
      }> => {
        if (request?.cursor === "opaque-unhandled") {
          return {
            messages: history("unhandled-window"),
            nextTurnCursor: null,
          };
        }
        const sourceCursor = request?.cursor ?? null;
        return {
          messages: history(
            sourceCursor === "opaque-page-2"
              ? "opaque-window-2"
              : "opaque-window-1",
          ),
          nextTurnCursor:
            sourceCursor === "opaque-page-1" ? "opaque-page-2" : null,
          sourceCursor,
        };
      },
    );
    const fixture = createCodexPageFixture({ listThreadTurns }, historyReader);
    const subscription = subscribeMessage();
    await fixture.handler.handle(
      subscription,
      context(fixture.client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, fixture.client, "sync_complete"),
      ).toHaveLength(1),
    );

    const requestPage = async (requestId: string, cursor: string) => {
      await fixture.handler.handle(
        {
          type: "conversation_turns_page",
          protocolVersion: 2,
          requestId,
          subscriptionId: subscription.requestId,
          provider: "codex",
          providerSessionId: "thread-opaque-legacy",
          cursor,
          limit: 1,
          sortDirection: "desc",
          itemsView: "summary",
        },
        context(fixture.client, fixture.runtime),
      );
    };

    await requestPage("opaque-1", "opaque-page-1");
    const first = events(
      fixture.sent,
      fixture.client,
      "turns_page_response",
    ).find((event) => event.requestId === "opaque-1")!;
    expect(first.nextCursor).toMatch(/^ccp-legacy-window-v1:/);
    expect(JSON.stringify(first.data[0])).toContain("opaque-window-1");

    await requestPage("opaque-2", first.nextCursor!);
    const second = events(
      fixture.sent,
      fixture.client,
      "turns_page_response",
    ).find((event) => event.requestId === "opaque-2")!;
    expect(second.nextCursor).toBeNull();
    expect(JSON.stringify(second.data[0])).toContain("opaque-window-2");

    await requestPage("opaque-unhandled", "opaque-unhandled");
    expect(
      events(fixture.sent, fixture.client, "turns_page_response").find(
        (event) => event.requestId === "opaque-unhandled",
      ),
    ).toBeUndefined();
    expect(
      events(fixture.sent, fixture.client, "error").find(
        (event) => event.requestId === "opaque-unhandled",
      ),
    ).toMatchObject({
      errorCode: "turns_page_failed",
      error: expect.stringContaining("did not consume"),
    });
    fixture.handler.close();
  });

  it("refuses an unsupported Codex page instead of scanning full durable history", async () => {
    const listThreadTurns = vi.fn(async () => {
      throw new Error("Method not found");
    });
    const fixture = createCodexPageFixture({ listThreadTurns });
    const subscription = subscribeMessage();
    await fixture.handler.handle(
      subscription,
      context(fixture.client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, fixture.client, "sync_complete"),
      ).toHaveLength(1),
    );

    await fixture.handler.handle(
      {
        type: "conversation_turns_page",
        protocolVersion: 2,
        requestId: "no-unbounded-fallback",
        subscriptionId: subscription.requestId,
        provider: "codex",
        providerSessionId: "thread-no-unbounded-fallback",
        cursor: "opaque-old-server-cursor",
        limit: 5,
        sortDirection: "desc",
        itemsView: "summary",
      },
      context(fixture.client, fixture.runtime),
    );

    expect(
      events(fixture.sent, fixture.client, "turns_page_response").find(
        (event) => event.requestId === "no-unbounded-fallback",
      ),
    ).toBeUndefined();
    expect(
      events(fixture.sent, fixture.client, "error").find(
        (event) => event.requestId === "no-unbounded-fallback",
      ),
    ).toMatchObject({
      errorCode: "turns_page_failed",
      error: expect.stringContaining("refusing an unbounded"),
    });
    expect(listThreadTurns).toHaveBeenCalledTimes(1);
    fixture.handler.close();
  });

  it("does not hide non-capability Codex page failures behind legacy history", async () => {
    const listThreadTurns = vi.fn(async () => {
      throw new Error("app-server exited");
    });
    const historyReader = vi.fn(async () => history("should-not-be-read"));
    const fixture = createCodexPageFixture({ listThreadTurns }, historyReader);
    const subscription = subscribeMessage();
    await fixture.handler.handle(
      subscription,
      context(fixture.client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, fixture.client, "sync_complete"),
      ).toHaveLength(1),
    );

    await fixture.handler.handle(
      {
        type: "conversation_turns_page",
        protocolVersion: 2,
        requestId: "real-failure",
        subscriptionId: subscription.requestId,
        provider: "codex",
        providerSessionId: "thread-failure",
        limit: 5,
        sortDirection: "desc",
        itemsView: "summary",
      },
      context(fixture.client, fixture.runtime),
    );

    expect(historyReader).not.toHaveBeenCalled();
    expect(
      events(fixture.sent, fixture.client, "error").find(
        (event) => event.requestId === "real-failure",
      ),
    ).toMatchObject({
      errorCode: "turns_page_failed",
      error: "app-server exited",
    });
    fixture.handler.close();
  });

  it("keeps the latest turn spine intact when one turn exceeds 512 KiB", async () => {
    const turnId = "turn-current";
    const largeTurn: ServerMessage[] = [
      {
        type: "user_input",
        text: "current prompt",
        userMessageUuid: "current-user",
      },
      {
        type: "assistant",
        messageUuid: "current-thinking",
        historyTurnId: turnId,
        message: {
          id: "current-thinking",
          role: "assistant",
          model: "test",
          content: [{ type: "thinking", thinking: "investigating" }],
        },
      },
      ...Array.from({ length: 180 }, (_, index) => {
        const toolUseId = `large-tool-${index}`;
        return [
          {
            type: "assistant" as const,
            messageUuid: `large-tool-call-${index}`,
            historyTurnId: turnId,
            message: {
              id: `large-tool-call-${index}`,
              role: "assistant" as const,
              model: "test",
              content: [
                {
                  type: "tool_use" as const,
                  id: toolUseId,
                  name: "Read",
                  input: { payload: "x".repeat(2 * 1024) },
                },
              ],
            },
          },
          {
            type: "tool_result" as const,
            toolUseId,
            toolName: "Read",
            historyTurnId: turnId,
            content: "y".repeat(4 * 1024),
          },
        ];
      }).flat(),
      {
        type: "assistant",
        messageUuid: "current-final",
        historyTurnId: turnId,
        message: {
          id: "current-final",
          role: "assistant",
          model: "test",
          content: [{ type: "text", text: "current final answer" }],
        },
      },
    ];
    const record = codexSeed(0, "thread-current");
    record.status = {
      ...record.status,
      activity: "working",
      confidence: "authoritative",
      runtimeAttachment: "loaded",
    };
    const fixture = createFixture(
      [record],
      vi.fn(async () => ({
        messages: largeTurn,
        nextTurnCursor: "older-turns-after-current",
      })),
      {
        initialExternalCodexMonitors: 0,
        inspectCodexThread: async () => null,
      },
    );
    const client = {};

    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(1),
    );

    const timeline = events(fixture.sent, client, "timeline_page");
    const messages = timeline.flatMap((page) =>
      page.entries.map((entry) => entry.message),
    );
    expect(messages[0]).toMatchObject({
      type: "user_input",
      userMessageUuid: "current-user",
    });
    expect(
      messages.some(
        (message) =>
          message.type === "assistant" &&
          message.message.content.some(
            (content) =>
              content.type === "thinking" &&
              content.thinking === "investigating",
          ),
      ),
    ).toBe(true);
    expect(
      messages.some(
        (message) =>
          message.type === "assistant" &&
          message.message.content.some(
            (content) =>
              content.type === "text" &&
              content.text === "current final answer",
          ),
      ),
    ).toBe(true);
    expect(
      messages.some(
        (message) =>
          message.type === "assistant" &&
          (message.historyToolDetailGaps?.length ?? 0) > 0,
      ),
    ).toBe(true);
    expect(timeline[0]).toMatchObject({
      latestTurnComplete: false,
      latestTurnGap: {
        turnId,
        payloadOmitted: true,
        repair: "items_page",
      },
      turnsNextCursor: "older-turns-after-current",
    });
    expect(timeline[0]!.latestTurnGap?.missingEntryCount).toBeGreaterThan(0);
    for (const message of fixture.sent.get(client) ?? []) {
      expect(
        Buffer.byteLength(JSON.stringify(message), "utf8"),
      ).toBeLessThanOrEqual(64 * 1024);
    }
    fixture.handler.close();
  });

  it("budgets timeline patch entries and deletes in the same final envelope", async () => {
    const target = {
      provider: "codex" as const,
      providerSessionId: "thread-joint-patch",
    };
    const baseMessages: ServerMessage[] = [
      {
        type: "user_input",
        text: "base prompt",
        userMessageUuid: "base-user",
      },
      ...Array.from({ length: 300 }, (_, index) => {
        const toolUseId = `t${index}`;
        return [
          {
            type: "assistant" as const,
            messageUuid: `c${index}`,
            historyTurnId: "base-turn",
            message: {
              id: `c${index}`,
              role: "assistant" as const,
              model: "test",
              content: [
                {
                  type: "tool_use" as const,
                  id: toolUseId,
                  name: "Read",
                  input: { index },
                },
              ],
            },
          },
          {
            type: "tool_result" as const,
            toolUseId,
            toolName: "Read",
            historyTurnId: "base-turn",
            content: "ok",
          },
        ];
      }).flat(),
    ];
    const base = buildConversationContentSnapshot(target, baseMessages, {
      maxMessageTextBytes: 40 * 1024,
      maxSnapshotBytes: 512 * 1024,
      preserveLatestRootTurnTools: true,
    });
    const next = buildConversationContentSnapshot(
      target,
      [
        {
          type: "user_input",
          text: "replacement prompt",
          userMessageUuid: "replacement-user",
        },
        {
          type: "assistant",
          messageUuid: "replacement-answer",
          historyTurnId: "replacement-turn",
          message: {
            id: "replacement-answer",
            role: "assistant",
            model: "test",
            content: [{ type: "text", text: "n".repeat(38 * 1024) }],
          },
        },
      ],
      {
        maxMessageTextBytes: 40 * 1024,
        maxSnapshotBytes: 512 * 1024,
        preserveLatestRootTurnTools: true,
      },
    );
    expect(base.entries.length).toBeGreaterThan(500);
    const patchBase = {
      ...base,
      entries: base.entries.map((entry, index) => ({
        ...entry,
        entryId: `${entry.entryId}:${"d".repeat(96)}:${index}`,
      })),
    };
    const fixture = createFixture([], async () => []);
    const client = {};
    const subscription = subscribeMessage();
    await fixture.handler.handle(
      subscription,
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(1),
    );
    const complete = events(fixture.sent, client, "sync_complete")[0]!;
    await fixture.handler.handle(
      {
        type: "conversation_sync_ack",
        protocolVersion: 2,
        subscriptionId: subscription.requestId,
        sequence: complete.sequence,
      },
      context(client, fixture.runtime),
    );
    const internal = fixture.handler as unknown as {
      subscriptions: Map<object, object>;
      timelinePatchPages(
        subscriptionState: object,
        baseRevision: string,
        nextSnapshot: typeof next,
        entries: typeof next.entries,
        deletes: string[],
        phase: "priority" | "recent" | "cold",
        timelineIndex: number,
        timelineCount: number,
      ): Array<{ entries: typeof next.entries; deletes: string[] }>;
      sendTimelinePatch(
        targetClient: object,
        subscriptionState: object,
        baseSnapshot: typeof base,
        nextSnapshot: typeof next,
        phase: "priority" | "recent" | "cold",
        timelineIndex: number,
        timelineCount: number,
      ): boolean;
    };
    const subscriptionState = internal.subscriptions.get(client)!;
    const rawPages = internal.timelinePatchPages(
      subscriptionState,
      patchBase.revision,
      next,
      next.entries,
      patchBase.entries.map((entry) => entry.entryId),
      "priority",
      0,
      1,
    );
    expect(rawPages.length).toBeGreaterThan(1);

    expect(
      internal.sendTimelinePatch(
        client,
        subscriptionState,
        patchBase,
        next,
        "priority",
        0,
        1,
      ),
    ).toBe(true);

    const patchPages = events(fixture.sent, client, "timeline_page").filter(
      (event) => event.mode === "patch",
    );
    expect(patchPages.length).toBeGreaterThan(1);
    expect(
      patchPages.some(
        (page) => page.entries.length > 0 && page.deletes.length > 0,
      ),
    ).toBe(true);
    expect(patchPages.flatMap((page) => page.deletes)).toHaveLength(
      patchBase.entries.length,
    );
    for (const page of patchPages) {
      expect(
        Buffer.byteLength(JSON.stringify(page), "utf8"),
      ).toBeLessThanOrEqual(64 * 1024);
    }
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

    const staleClient = {};
    await fixture.handler.handle(
      subscribeMessage(completion.nextState.threadContentStates, {
        catalogState: "unavailable-catalog-state",
        statusState: "unavailable-status-state",
      }),
      context(staleClient, fixture.runtime),
    );
    await vi.waitFor(
      () =>
        expect(events(fixture.sent, staleClient, "sync_complete")).toHaveLength(
          1,
        ),
      { timeout: 3_000 },
    );
    expect(
      events(fixture.sent, staleClient, "sync_reset").map(
        (event) => event.scope,
      ),
    ).toEqual(expect.arrayContaining(["catalog", "status"]));
    expect(
      events(fixture.sent, staleClient, "timeline_page").length,
    ).toBeGreaterThan(0);
    // The full hot-window bootstrap reuses the Bridge snapshot cache rather
    // than rereading provider history for every reconnecting phone.
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

  it("retains an outbound frame until runtime.send succeeds", async () => {
    const fixture = createFixture([], async () => []);
    const client = {};
    const subscriptionMessage = subscribeMessage();
    await fixture.handler.handle(
      subscriptionMessage,
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(1),
    );

    const internal = fixture.handler as unknown as {
      subscriptions: Map<
        object,
        {
          nextSequence: number;
          queuedBytes: number;
          outbound: Array<{
            sequence: number;
            bytes: number;
            message: ConversationSyncServerMessage;
          }>;
          outstanding: Map<number, number>;
        }
      >;
      sendEvent(
        client: object,
        subscription: object,
        payload: Record<string, unknown>,
      ): number;
      flush(client: object, subscription: object): void;
    };
    const state = internal.subscriptions.get(client)!;
    const sequenceBeforeFailure = state.nextSequence;
    const originalSend = fixture.runtime.send;
    let shouldThrow = true;
    fixture.runtime.send = (target, message) => {
      if (shouldThrow) {
        shouldThrow = false;
        throw new Error("socket write failed");
      }
      originalSend(target, message);
    };

    expect(() =>
      internal.sendEvent(client, state, {
        event: "error",
        requestId: "retry-frame",
        errorCode: "test",
        error: "retry me",
      }),
    ).toThrow("socket write failed");
    expect(state.outbound).toHaveLength(1);
    expect(state.outbound[0]!.sequence).toBe(sequenceBeforeFailure + 1);
    expect(state.queuedBytes).toBe(state.outbound[0]!.bytes);
    expect(state.outstanding.has(sequenceBeforeFailure + 1)).toBe(false);

    internal.flush(client, state);
    expect(state.outbound).toHaveLength(0);
    expect(state.queuedBytes).toBe(0);
    expect(state.outstanding.has(sequenceBeforeFailure + 1)).toBe(true);
    expect(
      events(fixture.sent, client, "error").find(
        (event) => event.requestId === "retry-frame",
      )?.sequence,
    ).toBe(sequenceBeforeFailure + 1);

    const nextSequence = internal.sendEvent(client, state, {
      event: "error",
      requestId: "next-frame",
      errorCode: "test",
      error: "next",
    });
    expect(nextSequence).toBe(sequenceBeforeFailure + 2);
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

  it("projects Desktop-owned rollout state and live messages without a Bridge runtime", async () => {
    const codex = codexSeed(0, "thread-0");
    type HandlerOptions = NonNullable<
      ConstructorParameters<typeof ConversationSyncV2FeatureHandler>[1]
    >;
    type ObserverCallback = Parameters<
      NonNullable<HandlerOptions["observeCodexThread"]>
    >[1];
    const callbacks = new Map<string, ObserverCallback>();
    const refreshNow = vi.fn(async () => {});
    const close = vi.fn();
    const historyReader = vi.fn(async () => history("canonical-before-live"));
    const fixture = createFixture([codex], historyReader, {
      initialExternalCodexMonitors: 1,
      maxExternalCodexMonitors: 2,
      observeCodexThread: async (threadId, onEvent) => {
        callbacks.set(threadId, onEvent);
        return {
          snapshot: { state: "running" as const, turnId: "turn-live" },
          refreshNow,
          close,
        };
      },
    });
    const client = {};

    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(1),
    );
    expect(
      events(fixture.sent, client, "status_changes")
        .flatMap((event) => event.changes)
        .find((status) => status.providerSessionId === "thread-0"),
    ).toMatchObject({
      activity: "working",
      runtimeAttachment: "ownedElsewhere",
      source: "legacyRollout",
      confidence: "observed",
    });

    const callback = callbacks.get("thread-0");
    expect(callback).toBeDefined();
    callback!({
      kind: "message",
      itemKey: "assistant:desktop-live",
      timestamp: new Date().toISOString(),
      message: {
        type: "assistant",
        messageUuid: "desktop-live",
        message: {
          id: "desktop-live",
          role: "assistant",
          model: "codex",
          content: [{ type: "text", text: "desktop live update" }],
        },
      },
    });

    await vi.waitFor(
      () =>
        expect(
          JSON.stringify(events(fixture.sent, client, "timeline_page")),
        ).toContain("desktop live update"),
      { timeout: 3_000 },
    );
    expect(historyReader.mock.calls.length).toBeGreaterThanOrEqual(2);
    fixture.handler.close();
    expect(close).toHaveBeenCalledTimes(1);
  });

  it("matches canonical and live users one-to-one while preserving equal delta chunks", async () => {
    type HandlerOptions = NonNullable<
      ConstructorParameters<typeof ConversationSyncV2FeatureHandler>[1]
    >;
    type ObserverCallback = Parameters<
      NonNullable<HandlerOptions["observeCodexThread"]>
    >[1];
    let callback: ObserverCallback | undefined;
    const sourceTimestamp = "2026-07-30T02:00:00.000Z";
    const fixture = createFixture(
      [codexSeed(0, "thread-0")],
      async () => [
        {
          type: "user_input",
          text: "继续",
          userMessageUuid: "codex:user-turn:1",
          timestamp: sourceTimestamp,
          sourceTimestamp,
          sourceTimestampIsAuthoritative: true,
        },
      ],
      {
        initialExternalCodexMonitors: 1,
        observeCodexThread: async (_threadId, onEvent) => {
          callback = onEvent;
          return {
            snapshot: {
              state: "running" as const,
              observedAt: "2026-07-30T02:00:01.000Z",
            },
            refreshNow: async () => {},
            close: () => {},
          };
        },
      },
    );
    const client = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() => expect(callback).toBeDefined());
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(1),
    );

    callback!({
      kind: "message",
      itemKey: "user:desktop-1",
      timestamp: "2026-07-30T02:00:00.500Z",
      message: {
        type: "user_input",
        text: "继续",
        clientMessageId: "desktop-1",
        timestamp: "2026-07-30T02:00:00.500Z",
      },
    });
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, client, "sync_complete").length,
      ).toBeGreaterThanOrEqual(2),
    );
    for (const itemKey of ["thinking:1", "thinking:2"]) {
      callback!({
        kind: "message",
        itemKey,
        timestamp: "2026-07-30T02:00:01.000Z",
        message: { type: "thinking_delta", text: "same delta chunk" },
      });
    }

    await vi.waitFor(
      () =>
        expect(
          events(fixture.sent, client, "sync_complete").length,
        ).toBeGreaterThanOrEqual(3),
      { timeout: 3_000 },
    );
    const latestComplete = events(fixture.sent, client, "sync_complete").at(
      -1,
    )!;
    const latestTimeline = events(fixture.sent, client, "timeline_page").filter(
      (event) => event.batchId === latestComplete.batchId,
    );
    const serialized = JSON.stringify(latestTimeline);
    expect(serialized.match(/继续/g)).toHaveLength(1);
    expect(serialized.match(/same delta chunk/g)).toHaveLength(2);
    fixture.handler.close();
  });

  it("does not seed full rollout monitors for unchanged idle recent threads", async () => {
    const observeCodexThread = vi.fn(async () => ({
      snapshot: { state: "idle" as const },
      refreshNow: async () => {},
      close: () => {},
    }));
    const fixture = createFixture(
      [codexSeed(0, "thread-0"), codexSeed(1, "thread-1")],
      async (target) => history(target.providerSessionId),
      {
        inspectCodexThread: async () => ({ state: "idle" as const }),
        observeCodexThread,
      },
    );
    const client = {};

    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(1),
    );
    expect(observeCodexThread).not.toHaveBeenCalled();
    fixture.handler.close();
  });

  it("attaches the existing rollout monitor when any durable Codex thread changes", async () => {
    const callbacks = new Map<string, () => void>();
    const observedThreads: string[] = [];
    const fixture = createFixture(
      [codexSeed(0, "thread-0"), codexSeed(1, "thread-1")],
      async (target) => history(target.providerSessionId),
      {
        initialExternalCodexMonitors: 1,
        maxExternalCodexMonitors: 2,
        observeCodexThread: async (threadId, onEvent) => {
          observedThreads.push(threadId);
          callbacks.set(threadId, () =>
            onEvent({
              kind: "state",
              state: "running",
              turnId: `turn-${threadId}`,
              timestamp: new Date().toISOString(),
            }),
          );
          return {
            snapshot: {
              state: threadId === "thread-1" ? "running" : "idle",
            },
            refreshNow: async () => {},
            close: () => {},
          };
        },
      },
    );
    const client = {};

    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(1),
    );
    expect(observedThreads).toEqual(["thread-0"]);

    fixture.handler.sessionCatalogChanged({
      revision: 2,
      provider: "codex",
      providerSessionId: "thread-1",
    });
    await vi.waitFor(() => expect(observedThreads).toContain("thread-1"));
    callbacks.get("thread-1")!();
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, client, "status_changes").some((event) =>
          event.changes.some(
            (status) =>
              status.providerSessionId === "thread-1" &&
              status.activity === "working" &&
              status.runtimeAttachment === "ownedElsewhere",
          ),
        ),
      ).toBe(true),
    );
    fixture.handler.close();
  });

  it("rewarms external rollout monitors after the last client disconnects", async () => {
    const codex = codexSeed(0, "thread-0");
    type HandlerOptions = NonNullable<
      ConstructorParameters<typeof ConversationSyncV2FeatureHandler>[1]
    >;
    type ObserverCallback = Parameters<
      NonNullable<HandlerOptions["observeCodexThread"]>
    >[1];
    const callbacks: ObserverCallback[] = [];
    const closes: Array<ReturnType<typeof vi.fn>> = [];
    let observations = 0;
    const fixture = createFixture([codex], async () => history("thread-0"), {
      initialExternalCodexMonitors: 1,
      observeCodexThread: async (_threadId, onEvent) => {
        observations += 1;
        callbacks.push(onEvent);
        const close = vi.fn();
        closes.push(close);
        return {
          snapshot: {
            state:
              observations === 1 ? ("idle" as const) : ("running" as const),
          },
          refreshNow: async () => {},
          close,
        };
      },
    });
    const firstClient = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(firstClient, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, firstClient, "sync_complete")).toHaveLength(
        1,
      ),
    );
    expect(observations).toBe(1);

    fixture.handler.disconnect(firstClient);
    expect(closes[0]).toHaveBeenCalledTimes(1);

    const secondClient = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(secondClient, fixture.runtime),
    );
    await vi.waitFor(() => expect(observations).toBe(2));
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, secondClient, "status_changes")
          .flatMap((event) => event.changes)
          .some(
            (status) =>
              status.providerSessionId === "thread-0" &&
              status.activity === "working",
          ),
      ).toBe(true),
    );

    callbacks[0]!({
      kind: "state",
      state: "idle",
      timestamp: new Date().toISOString(),
    });
    await new Promise((resolve) => setTimeout(resolve, 0));
    const latest = events(fixture.sent, secondClient, "status_changes")
      .flatMap((event) => event.changes)
      .filter((status) => status.providerSessionId === "thread-0")
      .at(-1);
    expect(latest?.activity).toBe("working");
    fixture.handler.close();
    expect(closes[1]).toHaveBeenCalledTimes(1);
  });

  it("lets a newer external running observation override app-server idle", async () => {
    const codex = codexSeed(0, "thread-0");
    codex.status = {
      ...codex.status,
      activity: "idle",
      runtimeAttachment: "loaded",
      source: "appServer",
      confidence: "authoritative",
      observedAt: "2026-07-30T00:00:00.000Z",
    };
    const fixture = createFixture([codex], async () => history("thread-0"), {
      initialExternalCodexMonitors: 1,
      observeCodexThread: async () => ({
        snapshot: {
          state: "running" as const,
          turnId: "external-turn",
          observedAt: "2026-07-30T00:00:01.000Z",
        },
        refreshNow: async () => {},
        close: () => {},
      }),
    });
    const client = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, client, "status_changes")
          .flatMap((event) => event.changes)
          .find((status) => status.providerSessionId === "thread-0"),
      ).toMatchObject({
        activity: "working",
        runtimeAttachment: "ownedElsewhere",
        source: "legacyRollout",
        confidence: "observed",
      }),
    );
    fixture.handler.close();
  });

  it("does not let an older external observation override authoritative idle or error", async () => {
    for (const activity of ["idle", "systemError"] as const) {
      const codex = codexSeed(0, `thread-${activity}`);
      codex.status = {
        ...codex.status,
        activity,
        runtimeAttachment: "loaded",
        source: "appServer",
        confidence: "authoritative",
        observedAt: "2026-07-30T00:00:02.000Z",
      };
      const fixture = createFixture(
        [codex],
        async () => history(`thread-${activity}`),
        {
          initialExternalCodexMonitors: 1,
          observeCodexThread: async () => ({
            snapshot: {
              state: "running" as const,
              observedAt: "2026-07-30T00:00:01.000Z",
            },
            refreshNow: async () => {},
            close: () => {},
          }),
        },
      );
      const client = {};
      await fixture.handler.handle(
        subscribeMessage(),
        context(client, fixture.runtime),
      );
      await vi.waitFor(() =>
        expect(
          events(fixture.sent, client, "status_changes")
            .flatMap((event) => event.changes)
            .find((status) => status.providerSessionId === `thread-${activity}`)
            ?.activity,
        ).toBe(activity),
      );
      fixture.handler.close();
    }
  });

  it("keeps observing Desktop activity when an old Bridge runtime is idle", async () => {
    const codex = codexSeed(0, "thread-0");
    codex.status = {
      ...codex.status,
      activity: "idle",
      runtimeAttachment: "loaded",
      source: "appServer",
      confidence: "authoritative",
      observedAt: "2026-07-30T00:00:00.000Z",
    };
    const observeCodexThread = vi.fn(async () => ({
      snapshot: {
        state: "running" as const,
        observedAt: "2026-07-30T00:00:02.000Z",
      },
      refreshNow: async () => {},
      close: () => {},
    }));
    const fixture = createFixture([codex], async () => history("thread-0"), {
      initialExternalCodexMonitors: 1,
      observeCodexThread,
    });
    fixture.runtime.listRuntimeConversationStates = () => [
      {
        bridgeSessionId: "runtime-idle",
        provider: "codex",
        providerSessionId: "thread-0",
        projectPath: "/project/0",
        processStatus: "idle",
        observedAt: "2026-07-30T00:00:01.000Z",
      },
    ];
    const client = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, client, "status_changes")
          .flatMap((event) => event.changes)
          .find((status) => status.providerSessionId === "thread-0"),
      ).toMatchObject({
        activity: "working",
        runtimeAttachment: "ownedElsewhere",
        source: "legacyRollout",
      }),
    );
    expect(observeCodexThread).toHaveBeenCalledTimes(1);
    fixture.handler.close();
  });

  it("keeps local attention authoritative over an external rollout", async () => {
    const codex = codexSeed(0, "thread-0");
    const observeCodexThread = vi.fn(async () => ({
      snapshot: {
        state: "running" as const,
        observedAt: "2026-07-30T00:00:02.000Z",
      },
      refreshNow: async () => {},
      close: () => {},
    }));
    const fixture = createFixture([codex], async () => history("thread-0"), {
      initialExternalCodexMonitors: 1,
      observeCodexThread,
    });
    fixture.runtime.listRuntimeConversationStates = () => [
      {
        bridgeSessionId: "runtime-attention",
        provider: "codex",
        providerSessionId: "thread-0",
        projectPath: "/project/0",
        processStatus: "idle",
        pendingAttention: {
          requestId: "approval-1",
          kind: "approval",
        },
        observedAt: "2026-07-30T00:00:01.000Z",
      },
    ];
    const client = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, client, "status_changes")
          .flatMap((event) => event.changes)
          .find((status) => status.providerSessionId === "thread-0"),
      ).toMatchObject({
        attention: "approval",
        source: "bridgeRuntime",
        confidence: "authoritative",
      }),
    );
    expect(observeCodexThread).not.toHaveBeenCalled();
    fixture.handler.close();
  });

  it("discovers a running thread outside the hot set and rewarms it without rescanning after reconnect", async () => {
    const seeds = Array.from({ length: 12 }, (_, index) =>
      codexSeed(index, `thread-${index}`),
    );
    const inspected: string[] = [];
    const observed: string[] = [];
    const fixture = createFixture(
      seeds,
      async (target) => history(target.providerSessionId),
      {
        initialExternalCodexMonitors: 1,
        maxExternalCodexMonitors: 4,
        inspectCodexThread: async (threadId) => {
          inspected.push(threadId);
          return threadId === "thread-11"
            ? {
                state: "running" as const,
                observedAt: "2026-07-30T00:00:02.000Z",
              }
            : { state: "idle" as const };
        },
        observeCodexThread: async (threadId) => {
          observed.push(threadId);
          return {
            snapshot:
              threadId === "thread-11"
                ? {
                    state: "running" as const,
                    observedAt: "2026-07-30T00:00:02.000Z",
                  }
                : { state: "idle" as const },
            refreshNow: async () => {},
            close: () => {},
          };
        },
      },
    );

    const firstClient = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(firstClient, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, firstClient, "status_changes")
          .flatMap((event) => event.changes)
          .some(
            (status) =>
              status.providerSessionId === "thread-11" &&
              status.activity === "working",
          ),
      ).toBe(true),
    );
    expect(inspected).toHaveLength(12);
    expect(observed).toContain("thread-11");

    fixture.handler.disconnect(firstClient);
    inspected.length = 0;
    observed.length = 0;
    const secondClient = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(secondClient, fixture.runtime),
    );
    await vi.waitFor(() => expect(observed).toContain("thread-11"));
    expect(inspected).toHaveLength(0);
    fixture.handler.close();
  });

  it("rejects a stale discovery result after disconnect and rescans for the next client", async () => {
    let resolveFirstInspection:
      | ((snapshot: { state: "running"; observedAt: string }) => void)
      | undefined;
    const firstInspection = new Promise<{
      state: "running";
      observedAt: string;
    }>((resolve) => {
      resolveFirstInspection = resolve;
    });
    let inspections = 0;
    const fixture = createFixture(
      [codexSeed(0, "thread-0")],
      async () => history("thread-0"),
      {
        initialExternalCodexMonitors: 1,
        inspectCodexThread: async () => {
          inspections += 1;
          return inspections === 1
            ? firstInspection
            : {
                state: "idle" as const,
                observedAt: "2026-07-30T00:00:02.000Z",
              };
        },
        observeCodexThread: async () => ({
          snapshot: {
            state: "idle" as const,
            observedAt: "2026-07-30T00:00:02.000Z",
          },
          refreshNow: async () => {},
          close: () => {},
        }),
      },
    );
    const firstClient = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(firstClient, fixture.runtime),
    );
    await vi.waitFor(() => expect(inspections).toBe(1));
    fixture.handler.disconnect(firstClient);

    const secondClient = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(secondClient, fixture.runtime),
    );
    resolveFirstInspection!({
      state: "running",
      observedAt: "2026-07-30T00:00:01.000Z",
    });
    await vi.waitFor(() => expect(inspections).toBeGreaterThanOrEqual(2));
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, secondClient, "sync_complete").length,
      ).toBeGreaterThanOrEqual(1),
    );
    const latest = events(fixture.sent, secondClient, "status_changes")
      .flatMap((event) => event.changes)
      .filter((status) => status.providerSessionId === "thread-0")
      .at(-1);
    expect(latest?.activity).not.toBe("working");
    fixture.handler.close();
  });

  it("does not resurrect a completed external thread on the next catalog refresh", async () => {
    type HandlerOptions = NonNullable<
      ConstructorParameters<typeof ConversationSyncV2FeatureHandler>[1]
    >;
    type ObserverCallback = Parameters<
      NonNullable<HandlerOptions["observeCodexThread"]>
    >[1];
    let callback: ObserverCallback | undefined;
    const runningAt = new Date(Date.now() - 2_000).toISOString();
    const idleAt = new Date(Date.now() - 1_000).toISOString();
    const fixture = createFixture(
      [codexSeed(0, "thread-terminal")],
      async () => history("thread-terminal"),
      {
        initialExternalCodexMonitors: 1,
        inspectCodexThread: async () => ({
          state: "running",
          runningEvidence: "lifecycle",
          observedAt: runningAt,
        }),
        observeCodexThread: async (_threadId, onEvent) => {
          callback = onEvent;
          return {
            snapshot: {
              state: "running" as const,
              runningEvidence: "lifecycle" as const,
              observedAt: runningAt,
            },
            refreshNow: async () => {},
            close: () => {},
          };
        },
      },
    );
    const client = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, client, "status_changes")
          .flatMap((event) => event.changes)
          .some(
            (status) =>
              status.providerSessionId === "thread-terminal" &&
              status.activity === "working",
          ),
      ).toBe(true),
    );

    callback!({
      kind: "state",
      state: "idle",
      outcome: "completed",
      timestamp: idleAt,
    });
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, client, "status_changes")
          .flatMap((event) => event.changes)
          .filter((status) => status.providerSessionId === "thread-terminal")
          .at(-1)?.activity,
      ).not.toBe("working"),
    );

    const beginCount = events(fixture.sent, client, "sync_begin").length;
    fixture.handler.sessionCatalogChanged();
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_begin").length).toBeGreaterThan(
        beginCount,
      ),
    );
    const latest = events(fixture.sent, client, "status_changes")
      .flatMap((event) => event.changes)
      .filter((status) => status.providerSessionId === "thread-terminal")
      .at(-1);
    expect(latest?.activity).not.toBe("working");
    const internal = fixture.handler as unknown as {
      externalCodexDiscoveredRunning: Map<string, unknown>;
    };
    expect(internal.externalCodexDiscoveredRunning.has("thread-terminal")).toBe(
      false,
    );
    fixture.handler.close();
  });

  it("clears an unmonitored Working state when rediscovery observes idle", async () => {
    const seeds = Array.from({ length: 8 }, (_, index) =>
      codexSeed(index, `thread-${index}`),
    );
    const runningAt = new Date(Date.now() - 2_000).toISOString();
    const idleAt = new Date(Date.now() - 1_000).toISOString();
    let idleThreadId: string | undefined;
    const fixture = createFixture(
      seeds,
      async (target) => history(target.providerSessionId),
      {
        initialExternalCodexMonitors: 1,
        maxExternalCodexMonitors: 4,
        inspectCodexThread: async (threadId) =>
          threadId === idleThreadId
            ? { state: "idle" as const, observedAt: idleAt }
            : {
                state: "running" as const,
                runningEvidence: "lifecycle" as const,
                observedAt: runningAt,
              },
        observeCodexThread: async () => ({
          snapshot: {
            state: "running" as const,
            runningEvidence: "lifecycle" as const,
            observedAt: runningAt,
          },
          refreshNow: async () => {},
          close: () => {},
        }),
      },
    );
    const client = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, client, "status_changes")
          .flatMap((event) => event.changes)
          .filter((status) => status.activity === "working"),
      ).toHaveLength(8),
    );
    const internal = fixture.handler as unknown as {
      externalCodexMonitors: Map<string, unknown>;
      externalCodexDiscoveredRunning: Map<string, unknown>;
      externalCodexDiscoveryCompletedAt: number;
    };
    idleThreadId = [...internal.externalCodexDiscoveredRunning.keys()].find(
      (threadId) => !internal.externalCodexMonitors.has(threadId),
    );
    expect(idleThreadId).toBeDefined();

    internal.externalCodexDiscoveryCompletedAt = 0;
    const beginCount = events(fixture.sent, client, "sync_begin").length;
    fixture.handler.sessionCatalogChanged();
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_begin").length).toBeGreaterThan(
        beginCount,
      ),
    );
    const latest = events(fixture.sent, client, "status_changes")
      .flatMap((event) => event.changes)
      .filter((status) => status.providerSessionId === idleThreadId)
      .at(-1);
    expect(latest?.activity).not.toBe("working");
    expect(internal.externalCodexDiscoveredRunning.has(idleThreadId!)).toBe(
      false,
    );
    fixture.handler.close();
  });

  it("does not promote stale response-only rollout activity to Working", async () => {
    const fixture = createFixture(
      [codexSeed(0, "thread-stale")],
      async () => history("thread-stale"),
      {
        initialExternalCodexMonitors: 1,
        inspectCodexThread: async () => ({
          state: "running",
          runningEvidence: "activity",
          observedAt: "2020-01-01T00:00:00.000Z",
        }),
        observeCodexThread: async () => ({
          snapshot: {
            state: "running",
            runningEvidence: "activity",
            observedAt: "2020-01-01T00:00:00.000Z",
          },
          refreshNow: async () => {},
          close: () => {},
        }),
      },
    );
    const client = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, client, "sync_complete").length,
      ).toBeGreaterThanOrEqual(1),
    );
    const latest = events(fixture.sent, client, "status_changes")
      .flatMap((event) => event.changes)
      .find((status) => status.providerSessionId === "thread-stale");
    expect(latest?.activity).not.toBe("working");
    fixture.handler.close();
  });

  it("retains all discovered Working states when the live-monitor cap is full", async () => {
    const seeds = Array.from({ length: 8 }, (_, index) =>
      codexSeed(index, `thread-${index}`),
    );
    const fixture = createFixture(
      seeds,
      async (target) => history(target.providerSessionId),
      {
        initialExternalCodexMonitors: 1,
        maxExternalCodexMonitors: 4,
        inspectCodexThread: async () => ({
          state: "running",
          runningEvidence: "lifecycle",
          observedAt: "2026-07-30T00:00:00.000Z",
        }),
        observeCodexThread: async () => ({
          snapshot: {
            state: "running",
            runningEvidence: "lifecycle",
            observedAt: "2026-07-30T00:00:00.000Z",
          },
          refreshNow: async () => {},
          close: () => {},
        }),
      },
    );
    const client = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, client, "sync_complete").length,
      ).toBeGreaterThanOrEqual(1),
    );
    const internal = fixture.handler as unknown as {
      externalCodexMonitors: Map<string, unknown>;
      externalCodexStatuses: Map<string, ConversationSyncStatus>;
    };
    expect(internal.externalCodexMonitors.size).toBeLessThanOrEqual(4);
    expect(
      [...internal.externalCodexStatuses.values()].filter(
        (status) => status.activity === "working",
      ),
    ).toHaveLength(8);
    fixture.handler.close();
  });

  it("bounds the external live-message buffer by bytes as well as count", async () => {
    type HandlerOptions = NonNullable<
      ConstructorParameters<typeof ConversationSyncV2FeatureHandler>[1]
    >;
    type ObserverCallback = Parameters<
      NonNullable<HandlerOptions["observeCodexThread"]>
    >[1];
    let callback: ObserverCallback | undefined;
    const fixture = createFixture(
      [codexSeed(0, "thread-0")],
      async () => history("thread-0"),
      {
        initialExternalCodexMonitors: 1,
        observeCodexThread: async (_threadId, onEvent) => {
          callback = onEvent;
          return {
            snapshot: { state: "running" as const },
            refreshNow: async () => {},
            close: () => {},
          };
        },
      },
    );
    const client = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() => expect(callback).toBeDefined());
    for (let index = 0; index < 4; index += 1) {
      callback!({
        kind: "message",
        itemKey: `assistant:large-${index}`,
        timestamp: new Date().toISOString(),
        message: {
          type: "assistant",
          messageUuid: `large-${index}`,
          message: {
            id: `large-${index}`,
            role: "assistant",
            model: "codex",
            content: [{ type: "text", text: "x".repeat(220 * 1024) }],
          },
        },
      });
    }
    const internal = fixture.handler as unknown as {
      externalCodexLiveMessages: Map<string, Map<string, { bytes: number }>>;
      externalCodexLiveBytes: Map<string, number>;
    };
    const key = "codex\0thread-0";
    expect(
      internal.externalCodexLiveMessages.get(key)?.size,
    ).toBeLessThanOrEqual(2);
    expect(internal.externalCodexLiveBytes.get(key)).toBeLessThanOrEqual(
      512 * 1024,
    );
    fixture.handler.close();
  });

  it("reuses one standalone app-server for concurrent hot-window reads", async () => {
    const sent: ConversationSyncServerMessage[] = [];
    const listThreadTurns = vi.fn(async () => ({
      data: [],
      nextCursor: null,
    }));
    const listThreadItems = vi.fn(async () => ({
      data: [],
      nextCursor: null,
    }));
    const stop = vi.fn();
    const standalone = {
      listThreadTurns,
      listThreadItems,
      stop,
    } as unknown as CodexProcess;
    const createStandaloneCodexProcess = vi.fn(async () => standalone);
    const runtime: LocalFeatureRuntime = {
      bridgeInstanceId: "bridge-1",
      codexSourceId: "source-1",
      getSession: () => undefined,
      getCodexThreadId: () => undefined,
      getActiveCodexProcess: () => null,
      createStandaloneCodexProcess,
      send(_client, message) {
        sent.push(message as ConversationSyncServerMessage);
      },
      isClientOpen: () => true,
      supports: (_client, capability) =>
        capability === CONVERSATION_SYNC_V2_CAPABILITY,
    };
    const handler = new ConversationSyncV2FeatureHandler(runtime, {
      catalogReader: async () => [
        codexSeed(0, "thread-0"),
        codexSeed(1, "thread-1"),
      ],
      statusReader: async () => new Map(),
      observeCodexThread: async () => ({
        snapshot: { state: "idle" as const },
        refreshNow: async () => {},
        close: () => {},
      }),
      initialExternalCodexMonitors: 2,
      statusWatchdogMs: 60_000,
      coldReconcileMs: 60_000,
    });
    const client = {};
    const subscription = subscribeMessage();
    await handler.handle(subscription, context(client, runtime));
    await vi.waitFor(() =>
      expect(sent.some((message) => message.event === "sync_complete")).toBe(
        true,
      ),
    );
    await handler.handle(
      {
        type: "conversation_turns_page",
        protocolVersion: 2,
        requestId: "shared-turns-page",
        subscriptionId: subscription.requestId,
        provider: "codex",
        providerSessionId: "thread-0",
        limit: 5,
        sortDirection: "desc",
        itemsView: "summary",
      },
      context(client, runtime),
    );
    await handler.handle(
      {
        type: "conversation_items_page",
        protocolVersion: 2,
        requestId: "shared-items-page",
        subscriptionId: subscription.requestId,
        provider: "codex",
        providerSessionId: "thread-0",
        turnId: "turn-current",
        limit: 50,
        sortDirection: "asc",
      },
      context(client, runtime),
    );

    expect(listThreadTurns).toHaveBeenCalledTimes(3);
    expect(listThreadItems).toHaveBeenCalledTimes(1);
    expect(createStandaloneCodexProcess).toHaveBeenCalledTimes(1);
    handler.close();
    expect(stop).toHaveBeenCalledTimes(1);
  });

  it("falls back to bounded turns/list on the shared reader when items/list is unavailable", async () => {
    const sent: ConversationSyncServerMessage[] = [];
    const listThreadTurns = vi.fn(async () => ({
      data: [
        {
          id: "turn-current",
          items: [
            {
              type: "userMessage",
              id: "user-current",
              content: [{ type: "inputText", text: "prompt" }],
            },
            {
              type: "agentMessage",
              id: "assistant-current",
              text: "answer",
            },
          ],
        },
      ],
      nextCursor: null,
    }));
    const listThreadItems = vi.fn(async () => {
      throw new Error("Method not found");
    });
    const stop = vi.fn();
    const standalone = {
      isRunning: true,
      listThreadTurns,
      listThreadItems,
      stop,
    } as unknown as CodexProcess;
    const createStandaloneCodexProcess = vi.fn(async () => standalone);
    const runtime: LocalFeatureRuntime = {
      bridgeInstanceId: "bridge-1",
      codexSourceId: "source-1",
      getSession: () => undefined,
      getCodexThreadId: () => undefined,
      getActiveCodexProcess: () => null,
      createStandaloneCodexProcess,
      send(_client, message) {
        sent.push(message as ConversationSyncServerMessage);
      },
      isClientOpen: () => true,
      supports: (_client, capability) =>
        capability === CONVERSATION_SYNC_V2_CAPABILITY,
    };
    const handler = new ConversationSyncV2FeatureHandler(runtime, {
      catalogReader: async () => [],
      statusReader: async () => new Map(),
      inspectCodexThread: async () => null,
      statusWatchdogMs: 60_000,
      coldReconcileMs: 60_000,
    });
    const client = {};
    const subscription = subscribeMessage();
    await handler.handle(subscription, context(client, runtime));
    await vi.waitFor(() =>
      expect(sent.some((message) => message.event === "sync_complete")).toBe(
        true,
      ),
    );

    await handler.handle(
      {
        type: "conversation_items_page",
        protocolVersion: 2,
        requestId: "fallback-items-page",
        subscriptionId: subscription.requestId,
        provider: "codex",
        providerSessionId: "thread-current",
        turnId: "turn-current",
        limit: 50,
        sortDirection: "asc",
      },
      context(client, runtime),
    );

    const response = sent.find(
      (message) =>
        message.event === "items_page_response" &&
        message.requestId === "fallback-items-page",
    );
    expect(response).toMatchObject({
      event: "items_page_response",
      turnId: "turn-current",
      nextCursor: null,
    });
    expect(listThreadItems).toHaveBeenCalledTimes(1);
    expect(listThreadTurns).toHaveBeenCalledTimes(1);
    expect(createStandaloneCodexProcess).toHaveBeenCalledTimes(1);
    handler.close();
    expect(stop).toHaveBeenCalledTimes(1);
  });

  it("recreates the shared app-server after its process exits", async () => {
    let firstRunning = true;
    const firstStop = vi.fn();
    const first = {
      get isRunning() {
        return firstRunning;
      },
      listThreadTurns: vi.fn(async () => {
        firstRunning = false;
        throw new Error("app-server exited");
      }),
      stop: firstStop,
    } as unknown as CodexProcess;
    const secondStop = vi.fn();
    const second = {
      isRunning: true,
      listThreadTurns: vi.fn(async () => ({
        data: [],
        nextCursor: null,
      })),
      stop: secondStop,
    } as unknown as CodexProcess;
    const createStandaloneCodexProcess = vi
      .fn()
      .mockResolvedValueOnce(first)
      .mockResolvedValueOnce(second);
    const runtime: LocalFeatureRuntime = {
      bridgeInstanceId: "bridge-1",
      codexSourceId: "source-1",
      getSession: () => undefined,
      getCodexThreadId: () => undefined,
      getActiveCodexProcess: () => null,
      createStandaloneCodexProcess,
      send: () => {},
      isClientOpen: () => true,
      supports: (_client, capability) =>
        capability === CONVERSATION_SYNC_V2_CAPABILITY,
    };
    const handler = new ConversationSyncV2FeatureHandler(runtime, {
      catalogReader: async () => [],
      statusReader: async () => new Map(),
      inspectCodexThread: async () => null,
      statusWatchdogMs: 60_000,
      coldReconcileMs: 60_000,
    });
    const internal = handler as unknown as {
      readRecentConversationHistory(target: {
        provider: "codex";
        providerSessionId: string;
      }): Promise<unknown>;
    };

    await expect(
      internal.readRecentConversationHistory({
        provider: "codex",
        providerSessionId: "thread-0",
      }),
    ).rejects.toThrow("app-server exited");
    await expect(
      internal.readRecentConversationHistory({
        provider: "codex",
        providerSessionId: "thread-0",
      }),
    ).resolves.toBeDefined();
    expect(createStandaloneCodexProcess).toHaveBeenCalledTimes(2);
    expect(firstStop).toHaveBeenCalled();
    handler.close();
    expect(secondStop).toHaveBeenCalledTimes(1);
  });

  it("does not label an in-flight stale snapshot with a newer live revision", async () => {
    let resolveFirstRead: ((messages: ServerMessage[]) => void) | undefined;
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

    await vi.waitFor(() => expect(historyReader).toHaveBeenCalledTimes(2), {
      timeout: 3_000,
    });
    await vi.waitFor(
      () =>
        expect(
          events(fixture.sent, client, "sync_complete").length,
        ).toBeGreaterThanOrEqual(2),
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
  handlerOptions: NonNullable<
    ConstructorParameters<typeof ConversationSyncV2FeatureHandler>[1]
  > = {},
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
      ...handlerOptions,
    }),
  };
}

function createCodexPageFixture(
  processMethods: Partial<
    Pick<CodexProcess, "listThreadTurns" | "listThreadItems">
  >,
  historyReader?: (target: {
    provider: "claude" | "codex";
    providerSessionId: string;
  }) => Promise<
    | ServerMessage[]
    | { messages: ServerMessage[]; nextTurnCursor: string | null }
  >,
) {
  const sent = new Map<object, ConversationSyncServerMessage[]>();
  const client = {};
  const process = {
    isRunning: true,
    listThreadTurns:
      processMethods.listThreadTurns ??
      (async () => ({ data: [], nextCursor: null })),
    listThreadItems:
      processMethods.listThreadItems ??
      (async () => ({ data: [], nextCursor: null })),
    stop: vi.fn(),
  } as unknown as CodexProcess;
  const runtime: LocalFeatureRuntime = {
    bridgeInstanceId: "bridge-1",
    codexSourceId: "source-1",
    getSession: () => undefined,
    getCodexThreadId: () => undefined,
    getProviderSessionId: () => undefined,
    getActiveCodexProcess: () => process,
    createStandaloneCodexProcess: async () => {
      throw new Error("active reader should be reused");
    },
    send(targetClient: object, message: ConversationSyncServerMessage) {
      const messages = sent.get(targetClient) ?? [];
      messages.push(message);
      sent.set(targetClient, messages);
    },
    isClientOpen: () => true,
    supports: (_client: object, type: string) =>
      type === CONVERSATION_SYNC_V2_CAPABILITY,
  };
  return {
    client,
    runtime,
    sent,
    handler: new ConversationSyncV2FeatureHandler(runtime, {
      catalogReader: async () => [],
      statusReader: async () => new Map(),
      ...(historyReader ? { historyReader } : {}),
      inspectCodexThread: async () => null,
      statusWatchdogMs: 60_000,
      coldReconcileMs: 60_000,
    }),
  };
}

function decreasingLimitCallCount(initial: number, final: number): number {
  let count = 1;
  let current = initial;
  while (current > final) {
    current = Math.max(1, Math.floor(current / 2));
    count += 1;
  }
  return count;
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

function codexSeed(index: number, threadId: string) {
  const value = seed(index);
  return {
    entry: {
      ...value.entry,
      provider: "codex" as const,
      providerSessionId: threadId,
    },
    status: {
      ...value.status,
      provider: "codex" as const,
      providerSessionId: threadId,
      source: "appServer" as const,
    },
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
