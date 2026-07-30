import { describe, expect, it, vi } from "vitest";

import type { CodexProcess } from "../codex-process.js";
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
    const stop = vi.fn();
    const standalone = { listThreadTurns, stop } as unknown as CodexProcess;
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
    await handler.handle(subscribeMessage(), context(client, runtime));
    await vi.waitFor(() =>
      expect(sent.some((message) => message.event === "sync_complete")).toBe(
        true,
      ),
    );
    expect(listThreadTurns).toHaveBeenCalledTimes(2);
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
