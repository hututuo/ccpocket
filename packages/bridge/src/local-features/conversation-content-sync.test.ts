import { describe, expect, it, vi } from "vitest";

import type { ServerMessage } from "../parser.js";
import type { SessionIndexEntry } from "../sessions-index.js";
import {
  buildConversationContentSnapshot,
  ConversationContentSyncFeatureHandler,
} from "./conversation-content-sync.js";
import {
  CONVERSATION_CONTENT_EVENT_CAPABILITY,
  conversationContentProtocolContribution,
  type ConversationContentClientMessage,
  type ConversationContentServerMessage,
  type ConversationContentTarget,
} from "./slots/conversation-content-protocol.js";
import type { LocalFeatureRuntime } from "./runtime.js";

describe("conversation content protocol", () => {
  it("accepts one bounded global subscription and rejects ambiguous cursors", () => {
    expect(
      conversationContentProtocolContribution.parseClient({
        type: "conversation_content_subscribe",
        protocolVersion: 1,
        requestId: "subscription-1",
        knownRevisions: [
          {
            provider: "codex",
            providerSessionId: "thread-1",
            revision: "revision-1",
          },
        ],
        focused: {
          provider: "codex",
          providerSessionId: "thread-1",
        },
      }),
    ).toMatchObject({
      type: "conversation_content_subscribe",
      requestId: "subscription-1",
      knownRevisions: [{ providerSessionId: "thread-1" }],
    });

    expect(
      conversationContentProtocolContribution.parseClient({
        type: "conversation_content_subscribe",
        protocolVersion: 1,
        requestId: "subscription-1",
        knownRevisions: [
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
        ],
      }),
    ).toBeNull();
  });

  it("requires ACKs to name the exact subscription and durable identity", () => {
    expect(
      conversationContentProtocolContribution.parseClient({
        type: "conversation_content_ack",
        protocolVersion: 1,
        subscriptionId: "subscription-1",
        provider: "claude",
        providerSessionId: "session-1",
        revision: "revision-1",
      }),
    ).toMatchObject({
      type: "conversation_content_ack",
      providerSessionId: "session-1",
    });
    expect(
      conversationContentProtocolContribution.parseClient({
        type: "conversation_content_ack",
        protocolVersion: 1,
        subscriptionId: "subscription-1",
        provider: "claude",
        providerSessionId: "session-1",
        revision: "revision-1",
        projectPath: "/not/accepted",
      }),
    ).toBeNull();
  });
});

describe("ConversationContentSyncFeatureHandler", () => {
  it("does not advertise a synthetic user UUID as an app-server turn id", () => {
    const messages: ServerMessage[] = [
      {
        type: "user_input",
        text: "prompt",
        userMessageUuid: "user-only-identity",
      },
      ...Array.from({ length: 30 }, (_, index) => {
        const toolUseId = `tool-${index}`;
        return [
          {
            type: "assistant" as const,
            messageUuid: `tool-call-${index}`,
            message: {
              id: `tool-call-${index}`,
              role: "assistant" as const,
              model: "test",
              content: [
                {
                  type: "tool_use" as const,
                  id: toolUseId,
                  name: "Read",
                  input: { payload: "x".repeat(256) },
                },
              ],
            },
          },
          {
            type: "tool_result" as const,
            toolUseId,
            toolName: "Read",
            content: "y".repeat(256),
          },
        ];
      }).flat(),
      {
        type: "assistant",
        messageUuid: "final",
        message: {
          id: "final",
          role: "assistant",
          model: "test",
          content: [{ type: "text", text: "answer" }],
        },
      },
    ];

    const snapshot = buildConversationContentSnapshot(
      { provider: "codex", providerSessionId: "thread-1" },
      messages,
      {
        maxMessageTextBytes: 256,
        maxSnapshotBytes: 4 * 1024,
        preserveLatestRootTurnTools: true,
      },
    );

    expect(snapshot.latestTurnComplete).toBe(false);
    expect(snapshot.latestTurnGap).toMatchObject({
      repair: "turns_page",
      payloadOmitted: true,
    });
    expect(snapshot.latestTurnGap).not.toHaveProperty("turnId");
  });

  it("bounds aggregate text per message without changing the wire envelope", async () => {
    const fixture = createFixture(1, {
      maxMessageTextBytes: 64,
      maxSnapshotBytes: 4 * 1024,
    });
    const client = {};
    fixture.historyReader.mockResolvedValue([
      {
        type: "user_input",
        text: "😀".repeat(100),
        userMessageUuid: "large-user",
      },
      {
        type: "assistant",
        messageUuid: "large-assistant",
        message: {
          id: "large-assistant",
          role: "assistant",
          model: "gpt-test",
          content: [
            { type: "text", text: "A".repeat(48) },
            { type: "thinking", thinking: "B".repeat(48) },
            { type: "text", text: "C".repeat(48) },
          ],
        },
      },
    ]);

    await fixture.handler.handle(subscribe("subscription-1"), {
      client,
      signal: new AbortController().signal,
      runtime: fixture.runtime,
    });
    await vi.waitFor(
      () =>
        expect(events(fixture.sent, client, "snapshot_complete")).toHaveLength(
          1,
        ),
      { timeout: 3_000 },
    );

    const pages = events(fixture.sent, client, "snapshot_page");
    const messages = pages.flatMap((page) =>
      page.entries.map((entry) => entry.message),
    );
    expect(messages).toHaveLength(2);
    for (const message of messages) {
      expect(aggregateTextBytes(message)).toBeLessThanOrEqual(64);
    }
    expect(
      messages.some((message) =>
        JSON.stringify(message).includes("[truncated; load details on demand]"),
      ),
    ).toBe(true);

    fixture.handler.close();
  });

  it("retains the newest entries within one bounded snapshot", async () => {
    const fixture = createFixture(1, {
      maxMessageTextBytes: 256,
      maxSnapshotBytes: 1_200,
    });
    const client = {};
    fixture.historyReader.mockResolvedValue(
      Array.from({ length: 20 }, (_, index) => ({
        type: "user_input" as const,
        text: `${index}:`.padEnd(180, "x"),
        userMessageUuid: `large-user-${index}`,
      })),
    );

    await fixture.handler.handle(subscribe("subscription-1"), {
      client,
      signal: new AbortController().signal,
      runtime: fixture.runtime,
    });
    await vi.waitFor(
      () =>
        expect(events(fixture.sent, client, "snapshot_complete")).toHaveLength(
          1,
        ),
      { timeout: 3_000 },
    );

    const begin = events(fixture.sent, client, "snapshot_begin")[0]!;
    const entries = events(fixture.sent, client, "snapshot_page").flatMap(
      (page) => page.entries,
    );
    expect(begin.entryCount).toBeGreaterThan(0);
    expect(begin.entryCount).toBeLessThan(5);
    expect(begin.hasEarlier).toBe(true);
    expect(entries.at(-1)?.message).toMatchObject({
      type: "user_input",
      userMessageUuid: "large-user-19",
    });

    fixture.handler.close();
  });

  it("does not let an oversized stale message outside the latest root window block sync", async () => {
    const fixture = createFixture(1);
    const client = {};
    fixture.historyReader.mockResolvedValue([
      {
        type: "user_input",
        text: "stale root",
        userMessageUuid: "stale-root",
      },
      {
        type: "assistant",
        messageUuid: "stale-oversized-assistant",
        message: {
          id: "stale-oversized-assistant",
          role: "assistant",
          model: "gpt-test",
          content: Array.from({ length: 1_025 }, () => ({
            type: "text" as const,
            text: "",
          })),
        },
      },
      ...Array.from({ length: 5 }, (_, index) => ({
        type: "user_input" as const,
        text: `recent root ${index}`,
        userMessageUuid: `recent-root-${index}`,
      })),
    ]);

    await fixture.handler.handle(subscribe("subscription-1"), {
      client,
      signal: new AbortController().signal,
      runtime: fixture.runtime,
    });
    await vi.waitFor(
      () =>
        expect(events(fixture.sent, client, "snapshot_complete")).toHaveLength(
          1,
        ),
      { timeout: 3_000 },
    );
    expect(events(fixture.sent, client, "snapshot_begin")[0]).toMatchObject({
      entryCount: 5,
      hasEarlier: true,
    });

    fixture.handler.close();
  });

  it("rejects an exact-fill message instead of silently emitting later empty blocks", async () => {
    const fixture = createFixture(0, { maxMessageTextBytes: 64 });
    const client = {};
    fixture.historyReader.mockResolvedValue([
      {
        type: "assistant",
        messageUuid: "exact-fill-assistant",
        message: {
          id: "exact-fill-assistant",
          role: "assistant",
          model: "gpt-test",
          content: [
            { type: "text", text: "x".repeat(64) },
            { type: "text", text: "must-not-disappear" },
          ],
        },
      },
    ]);

    await fixture.handler.handle(
      {
        ...subscribe("subscription-1"),
        focused: { provider: "codex", providerSessionId: "thread-0" },
      },
      {
        client,
        signal: new AbortController().signal,
        runtime: fixture.runtime,
      },
    );
    await vi.waitFor(
      () => expect(events(fixture.sent, client, "error").length).toBeGreaterThan(0),
      { timeout: 3_000 },
    );
    expect(events(fixture.sent, client, "snapshot_begin")).toHaveLength(0);

    fixture.handler.close();
  });

  it("rejects a single escaped entry that cannot fit the complete wire page", async () => {
    const fixture = createFixture(0, {
      maxMessageTextBytes: 1024,
      maxSnapshotBytes: 4 * 1024,
      maxPageBytes: 1_500,
    });
    const client = {};
    fixture.historyReader.mockResolvedValue([
      {
        type: "user_input",
        text: "\u0001".repeat(300),
        userMessageUuid: "escaped-user",
      },
    ]);

    await fixture.handler.handle(
      {
        ...subscribe("subscription-1"),
        focused: { provider: "codex", providerSessionId: "thread-0" },
      },
      {
        client,
        signal: new AbortController().signal,
        runtime: fixture.runtime,
      },
    );
    await vi.waitFor(
      () =>
        expect(
          events(fixture.sent, client, "error").some((event) =>
            event.error.includes("page byte budget"),
          ),
        ).toBe(true),
      { timeout: 3_000 },
    );
    expect(events(fixture.sent, client, "snapshot_begin")).toHaveLength(0);

    fixture.handler.close();
  });

  it("falls back to a full snapshot when the per-target cache budget rejects the base", async () => {
    const fixture = createFixture(0, {
      maxCachedTargetBytes: 1,
      maxCachedBytes: 4 * 1024,
    });
    const client = {};
    let version = 1;
    fixture.historyReader.mockImplementation(async (target) =>
      history(target.providerSessionId, version),
    );
    const focused: ConversationContentTarget = {
      provider: "codex",
      providerSessionId: "thread-0",
    };

    await fixture.handler.handle(
      { ...subscribe("subscription-1"), focused },
      {
        client,
        signal: new AbortController().signal,
        runtime: fixture.runtime,
      },
    );
    await vi.waitFor(
      () =>
        expect(events(fixture.sent, client, "snapshot_complete")).toHaveLength(
          1,
        ),
      { timeout: 3_000 },
    );
    const initial = events(fixture.sent, client, "snapshot_complete")[0]!;
    await fixture.handler.handle(
      {
        type: "conversation_content_ack",
        protocolVersion: 1,
        subscriptionId: "subscription-1",
        ...focused,
        revision: initial.revision,
      },
      {
        client,
        signal: new AbortController().signal,
        runtime: fixture.runtime,
      },
    );

    version = 2;
    fixture.handler.sessionCatalogChanged({ revision: 2, ...focused });
    await vi.waitFor(
      () =>
        expect(events(fixture.sent, client, "snapshot_complete")).toHaveLength(
          2,
        ),
      { timeout: 3_000 },
    );
    expect(events(fixture.sent, client, "patch")).toHaveLength(0);
    const second = events(fixture.sent, client, "snapshot_complete")[1]!;
    await fixture.handler.handle(
      {
        type: "conversation_content_ack",
        protocolVersion: 1,
        subscriptionId: "subscription-1",
        ...focused,
        revision: second.revision,
      },
      {
        client,
        signal: new AbortController().signal,
        runtime: fixture.runtime,
      },
    );
    const subscription = (
      fixture.handler as unknown as {
        clients: Map<object, { cursors: Map<string, string> }>;
      }
    ).clients.get(client);
    expect(subscription?.cursors.get("codex\u0000thread-0")).toBe(
      second.revision,
    );
    version = 3;
    fixture.handler.sessionCatalogChanged({ revision: 3, ...focused });
    await vi.waitFor(
      () =>
        expect(events(fixture.sent, client, "snapshot_complete")).toHaveLength(
          3,
        ),
      { timeout: 3_000 },
    );
    expect(events(fixture.sent, client, "patch")).toHaveLength(0);

    fixture.handler.close();
  });

  it("does not defer a revision that cannot be retained until ACK", async () => {
    const fixture = createFixture(0, {
      maxCachedTargetBytes: 1,
      maxCachedBytes: 4 * 1024,
    });
    const client = {};
    let version = 1;
    fixture.historyReader.mockImplementation(async (target) =>
      history(target.providerSessionId, version),
    );
    const focused: ConversationContentTarget = {
      provider: "codex",
      providerSessionId: "thread-0",
    };

    await fixture.handler.handle(
      { ...subscribe("subscription-1"), focused },
      {
        client,
        signal: new AbortController().signal,
        runtime: fixture.runtime,
      },
    );
    await vi.waitFor(
      () =>
        expect(events(fixture.sent, client, "snapshot_complete")).toHaveLength(
          1,
        ),
      { timeout: 3_000 },
    );

    version = 2;
    fixture.handler.sessionCatalogChanged({ revision: 2, ...focused });
    await vi.waitFor(
      () =>
        expect(events(fixture.sent, client, "snapshot_complete")).toHaveLength(
          2,
        ),
      { timeout: 3_000 },
    );

    fixture.handler.close();
  });

  it("evicts globally in existing recency order and only reuses the newest target", async () => {
    const fixture = createFixture(3, {
      maxMessageTextBytes: 4 * 1024,
      maxSnapshotBytes: 8 * 1024,
      maxCachedTargetBytes: 8 * 1024,
      maxCachedBytes: 5 * 1024,
    });
    const first = {};
    const second = {};
    fixture.historyReader.mockImplementation(async (target) => [
      {
        type: "user_input",
        text: `${target.providerSessionId}:`.padEnd(3_000, "x"),
        userMessageUuid: `${target.providerSessionId}-large-user`,
      },
    ]);

    await fixture.handler.handle(subscribe("first"), {
      client: first,
      signal: new AbortController().signal,
      runtime: fixture.runtime,
    });
    await vi.waitFor(
      () =>
        expect(events(fixture.sent, first, "snapshot_complete")).toHaveLength(
          3,
        ),
      { timeout: 3_000 },
    );

    await fixture.handler.handle(subscribe("second"), {
      client: second,
      signal: new AbortController().signal,
      runtime: fixture.runtime,
    });
    expect(
      events(fixture.sent, second, "snapshot_complete").map(
        (event) => event.providerSessionId,
      ),
    ).toEqual(["thread-2"]);

    fixture.handler.close();
  });

  it("touches a read hit before global LRU eviction", async () => {
    const fixture = createFixture(3, {
      maxMessageTextBytes: 4 * 1024,
      maxSnapshotBytes: 8 * 1024,
      maxCachedTargetBytes: 8 * 1024,
      maxCachedBytes: 8 * 1024,
    });
    const client = {};
    fixture.historyReader.mockImplementation(async (target) => [
      {
        type: "user_input",
        text: `${target.providerSessionId}:`.padEnd(3_000, "x"),
        userMessageUuid: `${target.providerSessionId}-lru-user`,
      },
    ]);
    await fixture.handler.handle(subscribe("subscription-1"), {
      client,
      signal: new AbortController().signal,
      runtime: fixture.runtime,
    });
    await vi.waitFor(
      () => expect(fixture.historyReader).toHaveBeenCalledTimes(3),
      { timeout: 3_000 },
    );

    const inspectable = fixture.handler as unknown as {
      snapshots: Map<string, Array<{ revision: string }>>;
      findSnapshot: (key: string, revision: string) => unknown;
    };
    expect([...inspectable.snapshots.keys()]).toEqual([
      "codex\u0000thread-1",
      "codex\u0000thread-2",
    ]);
    const thread1Revision = events(
      fixture.sent,
      client,
      "snapshot_complete",
    ).find((event) => event.providerSessionId === "thread-1")!.revision;
    expect(
      inspectable.findSnapshot("codex\u0000thread-1", thread1Revision),
    ).toBeDefined();

    fixture.handler.sessionCatalogChanged({
      revision: 2,
      provider: "codex",
      providerSessionId: "thread-0",
    });
    await vi.waitFor(
      () => expect(fixture.historyReader).toHaveBeenCalledTimes(4),
      { timeout: 3_000 },
    );
    expect([...inspectable.snapshots.keys()]).toEqual([
      "codex\u0000thread-1",
      "codex\u0000thread-0",
    ]);

    fixture.handler.close();
  });

  it("replaces unsafe oversized tool input before invoking custom serialization", async () => {
    const fixture = createFixture(1, {
      maxMessageTextBytes: 128,
      maxSnapshotBytes: 4 * 1024,
    });
    const client = {};
    const toJSON = vi.fn(() => {
      throw new Error("unsafe serializer must not run");
    });
    fixture.historyReader.mockResolvedValue([
      {
        type: "assistant",
        messageUuid: "tool-assistant",
        message: {
          id: "tool-assistant",
          role: "assistant",
          model: "gpt-test",
          content: [
            {
              type: "tool_use",
              id: "tool-1",
              name: "unsafe_tool",
              input: { payload: "x".repeat(1024 * 1024), toJSON },
            },
          ],
        },
      },
    ]);

    await fixture.handler.handle(subscribe("subscription-1"), {
      client,
      signal: new AbortController().signal,
      runtime: fixture.runtime,
    });
    await vi.waitFor(
      () =>
        expect(events(fixture.sent, client, "snapshot_complete")).toHaveLength(
          1,
        ),
      { timeout: 3_000 },
    );

    expect(toJSON).not.toHaveBeenCalled();
    const toolUse = events(fixture.sent, client, "snapshot_page")
      .flatMap((page) => page.entries)
      .flatMap((entry) =>
        entry.message.type === "assistant" ? entry.message.message.content : [],
      )
      .find((content) => content.type === "tool_use");
    expect(toolUse).toMatchObject({
      type: "tool_use",
      input: { ccpocketTruncated: true },
    });

    fixture.handler.close();
  });

  it("serializes the hot set and pushes a patch after an acknowledged change", async () => {
    const fixture = createFixture();
    const client = {};
    let activeReads = 0;
    let maxActiveReads = 0;
    const versions = new Map<string, number>();
    fixture.historyReader.mockImplementation(async (target) => {
      activeReads += 1;
      maxActiveReads = Math.max(maxActiveReads, activeReads);
      await new Promise((resolve) => setTimeout(resolve, 2));
      activeReads -= 1;
      const version = versions.get(target.providerSessionId) ?? 1;
      return history(target.providerSessionId, version);
    });

    await fixture.handler.handle(subscribe("subscription-1"), {
      client,
      signal: new AbortController().signal,
      runtime: fixture.runtime,
    });
    await vi.waitFor(
      () =>
        expect(events(fixture.sent, client, "snapshot_complete")).toHaveLength(
          10,
        ),
      { timeout: 3_000 },
    );

    expect(maxActiveReads).toBe(1);
    expect(
      fixture.historyReader.mock.calls.map(
        ([target]) => target.providerSessionId,
      ),
    ).toEqual(Array.from({ length: 10 }, (_, index) => `thread-${index}`));

    const initial = events(fixture.sent, client, "snapshot_complete").find(
      (event) => event.providerSessionId === "thread-0",
    )!;
    await fixture.handler.handle(
      {
        type: "conversation_content_ack",
        protocolVersion: 1,
        subscriptionId: "subscription-1",
        provider: "codex",
        providerSessionId: "thread-0",
        revision: initial.revision!,
      },
      {
        client,
        signal: new AbortController().signal,
        runtime: fixture.runtime,
      },
    );

    versions.set("thread-0", 2);
    fixture.handler.sessionCatalogChanged({
      revision: 2,
      provider: "codex",
      providerSessionId: "thread-0",
    });
    await vi.waitFor(
      () =>
        expect(
          events(fixture.sent, client, "patch").filter(
            (event) => event.providerSessionId === "thread-0",
          ),
        ).toHaveLength(1),
      { timeout: 3_000 },
    );
    const patch = events(fixture.sent, client, "patch").at(-1)!;
    expect(patch.baseRevision).toBe(initial.revision);
    expect(patch.upserts).toHaveLength(1);
    expect(patch.deletes).toEqual([]);

    fixture.handler.close();
  });

  it("coalesces newer revisions behind one pending ACK", async () => {
    const fixture = createFixture(1);
    const client = {};
    let version = 1;
    fixture.historyReader.mockImplementation(async (target) =>
      history(target.providerSessionId, version),
    );

    await fixture.handler.handle(subscribe("subscription-1"), {
      client,
      signal: new AbortController().signal,
      runtime: fixture.runtime,
    });
    await vi.waitFor(
      () =>
        expect(events(fixture.sent, client, "snapshot_complete")).toHaveLength(
          1,
        ),
      { timeout: 3_000 },
    );
    const initialRevision = events(
      fixture.sent,
      client,
      "snapshot_complete",
    )[0]!.revision;
    await fixture.handler.handle(
      {
        type: "conversation_content_ack",
        protocolVersion: 1,
        subscriptionId: "subscription-1",
        provider: "codex",
        providerSessionId: "thread-0",
        revision: initialRevision,
      },
      {
        client,
        signal: new AbortController().signal,
        runtime: fixture.runtime,
      },
    );

    version = 2;
    fixture.handler.sessionCatalogChanged({
      revision: 2,
      provider: "codex",
      providerSessionId: "thread-0",
    });
    await vi.waitFor(
      () => expect(events(fixture.sent, client, "patch")).toHaveLength(1),
      { timeout: 3_000 },
    );
    const pendingRevision = events(fixture.sent, client, "patch")[0]!.revision;

    version = 3;
    fixture.handler.sessionCatalogChanged({
      revision: 3,
      provider: "codex",
      providerSessionId: "thread-0",
    });
    const inspectable = fixture.handler as unknown as {
      latestSnapshot: (
        key: string,
      ) => { revision: string } | undefined;
    };
    await vi.waitFor(
      () =>
        expect(
          inspectable.latestSnapshot("codex\u0000thread-0")?.revision,
        ).not.toBe(pendingRevision),
      { timeout: 3_000 },
    );
    expect(events(fixture.sent, client, "patch")).toHaveLength(1);

    await fixture.handler.handle(
      {
        type: "conversation_content_ack",
        protocolVersion: 1,
        subscriptionId: "subscription-1",
        provider: "codex",
        providerSessionId: "thread-0",
        revision: pendingRevision,
      },
      {
        client,
        signal: new AbortController().signal,
        runtime: fixture.runtime,
      },
    );
    await vi.waitFor(
      () => expect(events(fixture.sent, client, "patch")).toHaveLength(2),
      { timeout: 3_000 },
    );
    expect(events(fixture.sent, client, "patch")[1]!.baseRevision).toBe(
      pendingRevision,
    );

    fixture.handler.close();
  });

  it("flushes a coalesced revision before its cache entry is evicted", async () => {
    const fixture = createFixture(0, { maxCachedConversations: 1 });
    const client = {};
    const versions = new Map<string, number>([["thread-0", 1]]);
    fixture.historyReader.mockImplementation(async (target) =>
      history(
        target.providerSessionId,
        versions.get(target.providerSessionId) ?? 1,
      ),
    );
    const focused: ConversationContentTarget = {
      provider: "codex",
      providerSessionId: "thread-0",
    };

    await fixture.handler.handle(
      { ...subscribe("subscription-1"), focused },
      {
        client,
        signal: new AbortController().signal,
        runtime: fixture.runtime,
      },
    );
    await vi.waitFor(
      () =>
        expect(events(fixture.sent, client, "snapshot_complete")).toHaveLength(
          1,
        ),
      { timeout: 3_000 },
    );
    const initialRevision = events(
      fixture.sent,
      client,
      "snapshot_complete",
    )[0]!.revision;
    await fixture.handler.handle(
      {
        type: "conversation_content_ack",
        protocolVersion: 1,
        subscriptionId: "subscription-1",
        ...focused,
        revision: initialRevision,
      },
      {
        client,
        signal: new AbortController().signal,
        runtime: fixture.runtime,
      },
    );

    versions.set("thread-0", 2);
    fixture.handler.sessionCatalogChanged({ revision: 2, ...focused });
    await vi.waitFor(
      () => expect(events(fixture.sent, client, "patch")).toHaveLength(1),
      { timeout: 3_000 },
    );
    const pendingRevision = events(fixture.sent, client, "patch")[0]!.revision;

    versions.set("thread-0", 3);
    fixture.handler.sessionCatalogChanged({ revision: 3, ...focused });
    const inspectable = fixture.handler as unknown as {
      latestSnapshot: (
        key: string,
      ) => { revision: string } | undefined;
    };
    await vi.waitFor(
      () =>
        expect(
          inspectable.latestSnapshot("codex\u0000thread-0")?.revision,
        ).not.toBe(pendingRevision),
      { timeout: 3_000 },
    );
    expect(events(fixture.sent, client, "patch")).toHaveLength(1);

    fixture.handler.sessionCatalogChanged({
      revision: 4,
      provider: "codex",
      providerSessionId: "thread-1",
    });
    await vi.waitFor(
      () =>
        expect(
          events(fixture.sent, client, "snapshot_complete").filter(
            (event) => event.providerSessionId === "thread-0",
          ),
        ).toHaveLength(2),
      { timeout: 3_000 },
    );

    fixture.handler.close();
  });

  it("reuses Bridge snapshots for a second client without rereading history", async () => {
    const fixture = createFixture();
    const first = {};
    const second = {};

    await fixture.handler.handle(subscribe("first"), {
      client: first,
      signal: new AbortController().signal,
      runtime: fixture.runtime,
    });
    await vi.waitFor(
      () =>
        expect(events(fixture.sent, first, "snapshot_complete")).toHaveLength(
          10,
        ),
      { timeout: 3_000 },
    );
    const readsAfterFirst = fixture.historyReader.mock.calls.length;

    await fixture.handler.handle(subscribe("second"), {
      client: second,
      signal: new AbortController().signal,
      runtime: fixture.runtime,
    });
    await vi.waitFor(
      () =>
        expect(events(fixture.sent, second, "snapshot_complete")).toHaveLength(
          10,
        ),
      { timeout: 3_000 },
    );
    expect(fixture.historyReader).toHaveBeenCalledTimes(readsAfterFirst);

    fixture.handler.close();
  });

  it("stops body work in notification-only mode and catches up on foreground", async () => {
    const fixture = createFixture();
    const client = {};
    await fixture.handler.handle(subscribe("subscription-1"), {
      client,
      signal: new AbortController().signal,
      runtime: fixture.runtime,
    });
    await vi.waitFor(
      () => expect(fixture.historyReader).toHaveBeenCalledTimes(10),
      {
        timeout: 3_000,
      },
    );
    const readsBeforeBackground = fixture.historyReader.mock.calls.length;

    fixture.handler.clientDeliveryModeChanged(client, "notifications_only");
    fixture.catalog[0] = catalogSession(0, "changed");
    fixture.handler.sessionCatalogChanged({
      revision: 2,
      provider: "codex",
      providerSessionId: "thread-0",
    });
    await new Promise((resolve) => setTimeout(resolve, 150));
    expect(fixture.historyReader).toHaveBeenCalledTimes(readsBeforeBackground);

    fixture.handler.clientDeliveryModeChanged(client, "interactive");
    await vi.waitFor(
      () =>
        expect(fixture.historyReader.mock.calls.length).toBeGreaterThan(
          readsBeforeBackground,
        ),
      { timeout: 3_000 },
    );
    expect(
      fixture.historyReader.mock.calls
        .slice(readsBeforeBackground)
        .some(([target]) => target.providerSessionId === "thread-0"),
    ).toBe(true);

    fixture.handler.close();
  });

  it("does not start body work when subscription arrives after background mode", async () => {
    const fixture = createFixture();
    const client = {};
    fixture.runtime.getClientDeliveryMode = () => "notifications_only";

    await fixture.handler.handle(subscribe("subscription-1"), {
      client,
      signal: new AbortController().signal,
      runtime: fixture.runtime,
    });
    await new Promise((resolve) => setTimeout(resolve, 150));
    expect(fixture.historyReader).not.toHaveBeenCalled();

    fixture.handler.clientDeliveryModeChanged(client, "interactive");
    await vi.waitFor(
      () => expect(fixture.historyReader).toHaveBeenCalledTimes(10),
      { timeout: 3_000 },
    );
    fixture.handler.close();
  });

  it("does not let sustained focused updates starve another conversation", async () => {
    const fixture = createFixture(0);
    const client = {};
    let focusedReads = 0;
    let releaseFirstFocusedRead!: () => void;
    let reportFirstFocusedRead!: () => void;
    const firstFocusedRead = new Promise<void>((resolve) => {
      reportFirstFocusedRead = resolve;
    });
    const firstFocusedReadRelease = new Promise<void>((resolve) => {
      releaseFirstFocusedRead = resolve;
    });
    fixture.historyReader.mockImplementation(async (target) => {
      if (target.providerSessionId === "thread-focused") {
        focusedReads += 1;
        if (focusedReads <= 20) {
          fixture.handler.sessionCatalogChanged({
            revision: focusedReads,
            provider: "codex",
            providerSessionId: "thread-focused",
          });
        }
        if (focusedReads === 1) {
          reportFirstFocusedRead();
          await firstFocusedReadRelease;
        }
      }
      return history(target.providerSessionId, 1);
    });

    await fixture.handler.handle(
      {
        ...subscribe("subscription-1"),
        focused: {
          provider: "codex",
          providerSessionId: "thread-focused",
        },
      },
      {
        client,
        signal: new AbortController().signal,
        runtime: fixture.runtime,
      },
    );
    await firstFocusedRead;
    fixture.handler.sessionCatalogChanged({
      revision: 1,
      provider: "codex",
      providerSessionId: "thread-other",
    });
    releaseFirstFocusedRead();

    await vi.waitFor(
      () =>
        expect(
          fixture.historyReader.mock.calls.some(
            ([target]) => target.providerSessionId === "thread-other",
          ),
        ).toBe(true),
      { timeout: 3_000 },
    );
    const readOrder = fixture.historyReader.mock.calls.map(
      ([target]) => target.providerSessionId,
    );
    expect(readOrder.indexOf("thread-other")).toBeLessThanOrEqual(4);
    fixture.handler.close();
  });
});

interface TestSyncOptions {
  maxMessageTextBytes?: number;
  maxSnapshotBytes?: number;
  maxPageBytes?: number;
  maxCachedConversations?: number;
  maxCachedTargetBytes?: number;
  maxCachedBytes?: number;
}

function createFixture(catalogSize = 12, options: TestSyncOptions = {}) {
  const sent = new Map<object, ConversationContentServerMessage[]>();
  const catalog = Array.from({ length: catalogSize }, (_, index) =>
    catalogSession(index),
  );
  const historyReader = vi.fn(async (target: ConversationContentTarget) =>
    history(target.providerSessionId, 1),
  );
  const runtime: LocalFeatureRuntime = {
    bridgeInstanceId: "bridge-1",
    getSession: () => undefined,
    getCodexThreadId: () => undefined,
    getProviderSessionId: () => undefined,
    getActiveCodexProcess: () => null,
    createStandaloneCodexProcess: async () => {
      throw new Error("not used");
    },
    send: (client, message) => {
      const values = sent.get(client) ?? [];
      values.push(message as ConversationContentServerMessage);
      sent.set(client, values);
    },
    isClientOpen: () => true,
    supports: (_client, type) => type === CONVERSATION_CONTENT_EVENT_CAPABILITY,
  };
  const handler = new ConversationContentSyncFeatureHandler(runtime, {
    catalogReader: async () => [...catalog],
    historyReader,
    coldScanMinMs: 60_000,
    coldScanMaxMs: 60_000,
    ...options,
  });
  return { handler, runtime, sent, catalog, historyReader };
}

function subscribe(
  requestId: string,
): Extract<
  ConversationContentClientMessage,
  { type: "conversation_content_subscribe" }
> {
  return {
    type: "conversation_content_subscribe",
    protocolVersion: 1,
    requestId,
    knownRevisions: [],
  };
}

function catalogSession(
  index: number,
  modified = `2026-07-26T00:00:${index.toString().padStart(2, "0")}.000Z`,
): SessionIndexEntry {
  return {
    sessionId: `thread-${index}`,
    provider: "codex",
    firstPrompt: `Prompt ${index}`,
    created: modified,
    modified,
    gitBranch: "main",
    projectPath: "/project",
    isSidechain: false,
  };
}

function history(id: string, version: number): ServerMessage[] {
  return [
    {
      type: "user_input",
      text: `Question ${id}`,
      userMessageUuid: `${id}-user`,
    },
    {
      type: "assistant",
      messageUuid: `${id}-assistant`,
      message: {
        id: `${id}-assistant`,
        role: "assistant",
        model: "gpt-test",
        content: [{ type: "text", text: `Answer ${version}` }],
      },
    },
  ];
}

function aggregateTextBytes(message: ServerMessage): number {
  if (message.type === "user_input") {
    return Buffer.byteLength(message.text, "utf8");
  }
  if (message.type === "tool_result") {
    return Buffer.byteLength(message.content, "utf8");
  }
  if (message.type === "tool_use_summary") {
    return Buffer.byteLength(message.summary, "utf8");
  }
  if (message.type !== "assistant") return 0;
  return message.message.content.reduce((total, content) => {
    if (content.type === "text") {
      return total + Buffer.byteLength(content.text, "utf8");
    }
    if (content.type === "thinking") {
      return total + Buffer.byteLength(content.thinking, "utf8");
    }
    return total;
  }, 0);
}

function events<Event extends ConversationContentServerMessage["event"]>(
  sent: Map<object, ConversationContentServerMessage[]>,
  client: object,
  event: Event,
): Array<Extract<ConversationContentServerMessage, { event: Event }>> {
  return (sent.get(client) ?? []).filter(
    (
      message,
    ): message is Extract<ConversationContentServerMessage, { event: Event }> =>
      message.event === event,
  );
}
