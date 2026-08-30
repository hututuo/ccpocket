import { describe, expect, it } from "vitest";

import type {
  JsonValue,
  ProviderItemSnapshot,
  ProviderThreadSnapshot,
  ProviderTurnSnapshot,
  SourcePartition,
  ThreadRef,
} from "../domain/conversation.js";
import {
  ConversationReceiveCore,
  ReceiveCoreLoadError,
} from "./conversation-receive-core.js";
import {
  ProviderHistoryReadError,
  ProviderHistoryTimeoutError,
  type ProviderHistoryReader,
} from "./provider-history-reader.js";

const SOURCE: SourcePartition = {
  bridgeIdentityId: "bridge-identity-a",
  bridgeInstanceId: "bridge-a",
  codexSourceId: "codex-source-a",
};

const THREAD: ThreadRef = {
  source: SOURCE,
  providerThreadId: "thread-a",
};

type ReaderValue =
  | ProviderThreadSnapshot
  | Error
  | Promise<ProviderThreadSnapshot>;

class FixtureReader implements ProviderHistoryReader {
  readCount = 0;
  readonly #values: ReaderValue[];

  constructor(values: ReaderValue[]) {
    this.#values = [...values];
  }

  async readThread(): Promise<ProviderThreadSnapshot> {
    this.readCount += 1;
    const value = this.#values.shift();
    if (value === undefined) throw new Error("fixture reader exhausted");
    if (value instanceof Error) throw value;
    return value;
  }
}

function providerItem(
  providerItemId: string,
  kind = "assistant",
  payload: JsonValue = { text: providerItemId },
): ProviderItemSnapshot {
  return { providerItemId, kind, payload };
}

function providerTurn(
  providerTurnId: string,
  itemIds: readonly string[],
): ProviderTurnSnapshot {
  return {
    providerTurnId,
    items: itemIds.map((id) => providerItem(id)),
  };
}

function snapshot(
  readGeneration: number,
  readStatus: ProviderThreadSnapshot["readStatus"],
  turns: readonly ProviderTurnSnapshot[],
  overrides: Partial<Pick<ProviderThreadSnapshot, "source" | "providerThreadId">> = {},
): ProviderThreadSnapshot {
  return {
    source: overrides.source ?? SOURCE,
    providerThreadId: overrides.providerThreadId ?? THREAD.providerThreadId,
    readGeneration,
    readStatus,
    turns,
  };
}

function deferred<T>(): {
  promise: Promise<T>;
  resolve: (value: T) => void;
} {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((resolver) => {
    resolve = resolver;
  });
  return { promise, resolve };
}

describe("ConversationReceiveCore load", () => {
  it.each([
    {
      field: "bridgeIdentityId",
      source: { ...SOURCE, bridgeIdentityId: "bridge-identity-b" },
    },
    {
      field: "bridgeInstanceId",
      source: { ...SOURCE, bridgeInstanceId: "bridge-b" },
    },
    {
      field: "codexSourceId",
      source: { ...SOURCE, codexSourceId: "codex-source-b" },
    },
  ])(
    "partitions cache, gap, and live identity by $field",
    async ({ source }) => {
      const otherThread: ThreadRef = {
        source,
        providerThreadId: THREAD.providerThreadId,
      };
      const reader = new FixtureReader([
        snapshot(1, "partial", [providerTurn("turn-1", ["base"])]),
        snapshot(
          1,
          "partial",
          [providerTurn("turn-1", ["other"])],
          { source },
        ),
      ]);
      const core = new ConversationReceiveCore(reader);

      const base = await core.load(THREAD);
      const other = await core.load(otherThread);
      const mismatchedLive = core.applyLive(THREAD, {
        source,
        providerThreadId: THREAD.providerThreadId,
        liveGeneration: 1,
        providerTurnId: "turn-1",
        item: providerItem("live-other"),
      });

      expect(reader.readCount).toBe(2);
      expect(base.items[0].ref.providerItemId).toBe("base");
      expect(other.items[0].ref.providerItemId).toBe("other");
      expect(base.coverage.gaps[0].gapId).not.toBe(
        other.coverage.gaps[0].gapId,
      );
      expect(mismatchedLive).toMatchObject({
        accepted: false,
        rejection: "source_mismatch",
      });
    },
  );

  it.each(["bridgeIdentityId", "bridgeInstanceId", "codexSourceId"] as const)(
    "fails closed when source partition %s is empty",
    async (field) => {
      const source = { ...SOURCE, [field]: "" };
      const core = new ConversationReceiveCore(new FixtureReader([]));

      await expect(
        core.load({ source, providerThreadId: THREAD.providerThreadId }),
      ).rejects.toMatchObject({ code: `invalid_${field}` });
    },
  );

  it("reads once and slices later pages from the complete in-memory cache", async () => {
    const reader = new FixtureReader([
      snapshot(1, "complete", [
        providerTurn("turn-1", ["item-0", "item-1"]),
        providerTurn("turn-2", ["item-2", "item-3"]),
        providerTurn("turn-3", ["item-4", "item-5"]),
      ]),
    ]);
    const core = new ConversationReceiveCore(reader, { maxPageSize: 3 });

    const latest = await core.load(THREAD, { pageSize: 2 });
    const previous = await core.load(THREAD, {
      pageSize: 2,
      beforeOrdinal: 4,
    });
    const clamped = await core.load(THREAD, { pageSize: 99 });

    expect(reader.readCount).toBe(1);
    expect(latest.items.map((entry) => entry.ref.ordinal)).toEqual([4, 5]);
    expect(previous.items.map((entry) => entry.ref.ordinal)).toEqual([2, 3]);
    expect(clamped.items.map((entry) => entry.ref.ordinal)).toEqual([3, 4, 5]);
    expect(previous.coverage.gaps.map((gap) => gap.kind)).toEqual([
      "window_not_loaded",
      "window_not_loaded",
    ]);
    expect(latest.coverage.knownItemCount).toBe(6);
    expect(Object.isFrozen(latest)).toBe(true);
    expect(Object.isFrozen(latest.items)).toBe(true);
    expect(Object.isFrozen(latest.items[0].payload)).toBe(true);
  });

  it("coalesces concurrent initial loads for the same source thread", async () => {
    const pending = deferred<ProviderThreadSnapshot>();
    const reader = new FixtureReader([pending.promise]);
    const core = new ConversationReceiveCore(reader);

    const first = core.load(THREAD, { pageSize: 1 });
    const second = core.load(THREAD, { pageSize: 2 });
    expect(reader.readCount).toBe(1);
    pending.resolve(
      snapshot(1, "complete", [providerTurn("turn-1", ["item-a", "item-b"])]),
    );

    await expect(first).resolves.toMatchObject({
      items: [{ ref: { providerItemId: "item-b" } }],
    });
    await expect(second).resolves.toMatchObject({
      items: [
        { ref: { providerItemId: "item-a" } },
        { ref: { providerItemId: "item-b" } },
      ],
    });
    expect(reader.readCount).toBe(1);
  });

  it("keeps partial known islands in certified array order with deterministic gaps", async () => {
    const candidate = snapshot(4, "partial", [
      providerTurn("turn-z", ["item-z1", "item-z2"]),
      providerTurn("turn-a", ["item-a1"]),
    ]);
    const first = await new ConversationReceiveCore(
      new FixtureReader([candidate]),
    ).load(THREAD);
    const second = await new ConversationReceiveCore(
      new FixtureReader([candidate]),
    ).load(THREAD);

    expect(first.items.map((entry) => entry.ref.providerItemId)).toEqual([
      "item-z1",
      "item-z2",
      "item-a1",
    ]);
    expect(first.items.map((entry) => entry.ref.ordinal)).toEqual([0, 1, 2]);
    expect(first.coverage.islands).toHaveLength(2);
    expect(first.coverage.islands.map((island) => island.itemCount)).toEqual([
      2, 1,
    ]);
    expect(first.coverage.gaps).toHaveLength(3);
    expect(first.coverage.gaps.map((gap) => gap.gapId)).toEqual(
      second.coverage.gaps.map((gap) => gap.gapId),
    );
    expect(first.readHealth.state).toBe("partial");
  });

  it("represents an initial empty observation without inventing completeness", async () => {
    const core = new ConversationReceiveCore(
      new FixtureReader([snapshot(1, "empty", [])]),
    );

    const result = await core.load(THREAD);

    expect(result.items).toEqual([]);
    expect(result.coverage.providerReadStatus).toBe("empty");
    expect(result.coverage.gaps).toHaveLength(1);
    expect(result.coverage.gaps[0].kind).toBe("provider_history_unknown");
    expect(result.readHealth.state).toBe("empty");
  });

  it("preserves last-good content across partial, empty, error, and timeout refreshes", async () => {
    const reader = new FixtureReader([
      snapshot(10, "complete", [providerTurn("turn-1", ["last-good"])]),
      snapshot(11, "partial", [providerTurn("turn-2", ["partial-only"])]),
      snapshot(12, "empty", []),
      new ProviderHistoryReadError("provider_unavailable"),
      new ProviderHistoryTimeoutError(),
    ]);
    const core = new ConversationReceiveCore(reader);
    const initial = await core.load(THREAD);

    const partial = await core.load(THREAD, { refresh: true });
    const empty = await core.load(THREAD, { refresh: true });
    const error = await core.load(THREAD, { refresh: true });
    const timeout = await core.load(THREAD, { refresh: true });

    for (const result of [partial, empty, error, timeout]) {
      expect(result.items[0].ref.providerItemId).toBe("last-good");
      expect(result.readGeneration).toBe(initial.readGeneration);
    }
    expect(partial.readHealth).toMatchObject({
      state: "partial",
      code: "weaker_partial_snapshot",
      observedReadGeneration: 11,
      servedReadGeneration: 10,
    });
    expect(empty.readHealth).toMatchObject({
      state: "empty",
      code: "weaker_empty_snapshot",
      observedReadGeneration: 12,
    });
    expect(error.readHealth).toMatchObject({
      state: "error",
      code: "provider_unavailable",
    });
    expect(timeout.readHealth).toMatchObject({
      state: "timeout",
      code: "provider_history_timeout",
    });
  });

  it("fails explicitly when no last-good snapshot exists", async () => {
    const errorCore = new ConversationReceiveCore(
      new FixtureReader([new ProviderHistoryReadError("offline")]),
    );
    const timeoutCore = new ConversationReceiveCore(
      new FixtureReader([new ProviderHistoryTimeoutError()]),
    );

    await expect(errorCore.load(THREAD)).rejects.toMatchObject({ code: "offline" });
    await expect(timeoutCore.load(THREAD)).rejects.toMatchObject({
      code: "provider_history_timeout",
    });
  });

  it("rejects stale and source-mismatched refreshes without overwriting the cache", async () => {
    const reader = new FixtureReader([
      snapshot(8, "complete", [providerTurn("turn-1", ["current"])]),
      snapshot(7, "complete", [providerTurn("turn-1", ["stale"])]),
      snapshot(
        100,
        "complete",
        [providerTurn("turn-1", ["wrong-source"])],
        { source: { ...SOURCE, codexSourceId: "codex-source-b" } },
      ),
      snapshot(9, "complete", [providerTurn("turn-1", ["valid-newer"])]),
    ]);
    const core = new ConversationReceiveCore(reader);
    await core.load(THREAD);

    const stale = await core.load(THREAD, { refresh: true });
    const mismatched = await core.load(THREAD, { refresh: true });
    const valid = await core.load(THREAD, { refresh: true });

    expect(stale.items[0].ref.providerItemId).toBe("current");
    expect(stale.readHealth).toMatchObject({
      state: "rejected",
      code: "stale_read_generation",
      observedReadGeneration: 7,
    });
    expect(mismatched.items[0].ref.providerItemId).toBe("current");
    expect(mismatched.readHealth).toMatchObject({
      state: "rejected",
      code: "source_mismatch",
      observedReadGeneration: 100,
    });
    expect(valid.readGeneration).toBe(9);
    expect(valid.items[0].ref.providerItemId).toBe("valid-newer");
  });

  it("keeps the highest valid observed read generation as a fence", async () => {
    const reader = new FixtureReader([
      snapshot(1, "complete", [providerTurn("turn-1", ["base"])]),
      snapshot(3, "partial", [providerTurn("turn-1", ["partial-gen-3"])]),
      snapshot(2, "complete", [providerTurn("turn-1", ["late-full-gen-2"])]),
      snapshot(4, "complete", [providerTurn("turn-1", ["full-gen-4"])]),
    ]);
    const core = new ConversationReceiveCore(reader);
    await core.load(THREAD);

    const partial = await core.load(THREAD, { refresh: true });
    const lateFull = await core.load(THREAD, { refresh: true });
    const newerFull = await core.load(THREAD, { refresh: true });

    expect(partial.items[0].ref.providerItemId).toBe("base");
    expect(lateFull.items[0].ref.providerItemId).toBe("base");
    expect(lateFull.readHealth).toMatchObject({
      state: "rejected",
      code: "stale_read_generation",
      observedReadGeneration: 2,
    });
    expect(newerFull.items[0].ref.providerItemId).toBe("full-gen-4");
    expect(newerFull.readHealth.state).toBe("healthy");
  });

  it("fences a late concurrent read against the newest accepted generation", async () => {
    const older = deferred<ProviderThreadSnapshot>();
    const newer = deferred<ProviderThreadSnapshot>();
    const reader = new FixtureReader([
      snapshot(1, "complete", [providerTurn("turn-1", ["base"])]),
      older.promise,
      newer.promise,
    ]);
    const core = new ConversationReceiveCore(reader);
    await core.load(THREAD);

    const olderLoad = core.load(THREAD, { refresh: true });
    const newerLoad = core.load(THREAD, { refresh: true });
    newer.resolve(
      snapshot(3, "complete", [providerTurn("turn-1", ["newest"])]),
    );
    await expect(newerLoad).resolves.toMatchObject({ readGeneration: 3 });
    older.resolve(
      snapshot(2, "complete", [providerTurn("turn-1", ["late-old"])]),
    );

    const late = await olderLoad;
    const cached = await core.load(THREAD);
    expect(late.items[0].ref.providerItemId).toBe("newest");
    expect(late.readHealth.code).toBe("stale_read_generation");
    expect(cached.readGeneration).toBe(3);
    expect(cached.items[0].ref.providerItemId).toBe("newest");
  });

  it.each([
    {
      name: "turn ids",
      candidate: snapshot(2, "complete", [
        providerTurn("duplicate", ["item-a"]),
        providerTurn("duplicate", ["item-b"]),
      ]),
      code: "duplicate_provider_turn_id",
    },
    {
      name: "item ids",
      candidate: snapshot(2, "complete", [
        providerTurn("turn-a", ["duplicate"]),
        providerTurn("turn-b", ["duplicate"]),
      ]),
      code: "duplicate_provider_item_id",
    },
  ])("fails closed for duplicate provider $name", async ({ candidate, code }) => {
    const firstCore = new ConversationReceiveCore(
      new FixtureReader([candidate]),
    );
    await expect(firstCore.load(THREAD)).rejects.toMatchObject({ code });

    const reader = new FixtureReader([
      snapshot(1, "complete", [providerTurn("turn-base", ["base"])]),
      candidate,
    ]);
    const core = new ConversationReceiveCore(reader);
    await core.load(THREAD);
    const preserved = await core.load(THREAD, { refresh: true });
    expect(preserved.items[0].ref.providerItemId).toBe("base");
    expect(preserved.readHealth).toMatchObject({ state: "rejected", code });
  });

  it("preserves unknown item identity, payload, and certified position", async () => {
    const payload = {
      futureField: ["opaque", { nested: true }],
    } as const;
    const core = new ConversationReceiveCore(
      new FixtureReader([
        snapshot(1, "complete", [
          {
            providerTurnId: "turn-future",
            items: [
              providerItem("before", "user"),
              providerItem("future-id", "future/provider-kind", payload),
              providerItem("after", "assistant"),
            ],
          },
        ]),
      ]),
    );

    const result = await core.load(THREAD);
    const unknown = result.items[1];

    expect(unknown).toMatchObject({
      kind: "unknown",
      providerKind: "future/provider-kind",
      ref: { providerItemId: "future-id", ordinal: 1, itemOrdinal: 1 },
      payload,
    });
    expect(Object.isFrozen(unknown.payload)).toBe(true);
  });
});

describe("ConversationReceiveCore live overlay", () => {
  it("fences source and generation then promotes canonical identity without duplication or movement", async () => {
    const reader = new FixtureReader([
      snapshot(1, "complete", [providerTurn("turn-1", ["item-a"])]),
      snapshot(2, "complete", [providerTurn("turn-1", ["item-a", "item-b"])]),
    ]);
    const core = new ConversationReceiveCore(reader);
    const initial = await core.load(THREAD);

    const liveB = core.applyLive(THREAD, {
      ...THREAD,
      liveGeneration: 5,
      providerTurnId: "turn-1",
      item: providerItem("item-b"),
    });
    const visibleBefore = [
      ...initial.items.map((entry) => entry.ref.providerItemId),
      ...liveB.overlay.items.map((entry) => entry.item.providerItemId),
    ];
    const stale = core.applyLive(THREAD, {
      ...THREAD,
      liveGeneration: 4,
      providerTurnId: "turn-1",
      item: providerItem("stale-item"),
    });
    const mismatched = core.applyLive(THREAD, {
      source: { ...SOURCE, bridgeIdentityId: "bridge-identity-b" },
      providerThreadId: THREAD.providerThreadId,
      liveGeneration: 6,
      providerTurnId: "turn-1",
      item: providerItem("wrong-source"),
    });

    expect(visibleBefore).toEqual(["item-a", "item-b"]);
    expect(stale).toMatchObject({
      accepted: false,
      rejection: "stale_live_generation",
    });
    expect(mismatched).toMatchObject({
      accepted: false,
      rejection: "source_mismatch",
    });
    expect(stale.overlay.items.map((entry) => entry.item.providerItemId)).toEqual([
      "item-b",
    ]);

    const canonical = await core.load(THREAD, { refresh: true });
    const overlayAfter = core.getLiveOverlay(THREAD);
    const visibleAfter = [
      ...canonical.items.map((entry) => entry.ref.providerItemId),
      ...(overlayAfter?.items.map((entry) => entry.item.providerItemId) ?? []),
    ];

    expect(visibleAfter).toEqual(visibleBefore);
    expect(canonical.items[1].ref).toMatchObject({
      providerItemId: "item-b",
      ordinal: 1,
    });
    expect(overlayAfter?.items).toEqual([]);
  });

  it("updates a matching live item in place and resets only for a newer generation", () => {
    const core = new ConversationReceiveCore(new FixtureReader([]));
    const first = core.applyLive(THREAD, {
      ...THREAD,
      liveGeneration: 3,
      providerTurnId: "turn-live",
      item: providerItem("live-id", "assistant", { text: "draft" }),
    });
    const updated = core.applyLive(THREAD, {
      ...THREAD,
      liveGeneration: 3,
      providerTurnId: "turn-live",
      item: providerItem("live-id", "assistant", { text: "final" }),
    });
    const nextGeneration = core.applyLive(THREAD, {
      ...THREAD,
      liveGeneration: 4,
      providerTurnId: "turn-next",
      item: providerItem("next-id"),
    });

    expect(updated.overlay.items).toHaveLength(1);
    expect(updated.overlay.items[0].orderKey).toBe(first.overlay.items[0].orderKey);
    expect(updated.overlay.items[0].item.payload).toEqual({ text: "final" });
    expect(nextGeneration.overlay.items.map((entry) => entry.item.providerItemId)).toEqual([
      "next-id",
    ]);
    expect(nextGeneration.overlay.items[0].arrivalOrdinal).toBe(0);
  });
});

describe("ReceiveCoreLoadError", () => {
  it("retains a stable machine-readable code", () => {
    expect(new ReceiveCoreLoadError("example")).toMatchObject({
      name: "ReceiveCoreLoadError",
      code: "example",
    });
  });
});
