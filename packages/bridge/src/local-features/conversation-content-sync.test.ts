import { describe, expect, it, vi } from "vitest";

import type { ServerMessage } from "../parser.js";
import type { SessionIndexEntry } from "../sessions-index.js";
import { ConversationContentSyncFeatureHandler } from "./conversation-content-sync.js";
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

function createFixture(catalogSize = 12) {
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
