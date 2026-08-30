import type {
  CanonicalItemKind,
  CanonicalTimelineItem,
  CanonicalTimelineSnapshot,
  CanonicalTurnRef,
  CoverageBoundary,
  CoverageIsland,
  JsonValue,
  LiveApplyResult,
  LiveOverlay,
  LiveOverlayItem,
  ProviderItemSnapshot,
  ProviderLiveItem,
  ProviderReadStatus,
  ProviderThreadSnapshot,
  ReadHealth,
  SourcePartition,
  ThreadRef,
  TimelineGap,
} from "../domain/conversation.js";
import {
  ProviderHistoryReadError,
  ProviderHistoryTimeoutError,
  type ProviderHistoryReader,
} from "./provider-history-reader.js";

const DEFAULT_MAX_PAGE_SIZE = 200;
const ORDER_WIDTH = 12;
const KNOWN_ITEM_KINDS = new Set<CanonicalItemKind>([
  "user",
  "assistant",
  "thinking",
  "tool_use",
  "tool_result",
  "system",
]);

export interface ConversationReceiveCoreOptions {
  readonly maxPageSize?: number;
}

export interface LoadOptions {
  readonly pageSize?: number;
  /** Exclusive canonical ordinal. Omit to read the newest window. */
  readonly beforeOrdinal?: number;
  readonly refresh?: boolean;
}

export class ReceiveCoreLoadError extends Error {
  readonly code: string;

  constructor(code: string, message = code) {
    super(message);
    this.name = "ReceiveCoreLoadError";
    this.code = code;
  }
}

interface NormalizedTimeline {
  readonly thread: ThreadRef;
  readonly readGeneration: number;
  readonly providerReadStatus: ProviderReadStatus;
  readonly turns: readonly CanonicalTurnRef[];
  readonly items: readonly CanonicalTimelineItem[];
  readonly islands: readonly CoverageIsland[];
  readonly providerGaps: readonly TimelineGap[];
}

interface CacheEntry {
  readonly timeline: NormalizedTimeline;
  readonly health: ReadHealth;
  readonly readGenerationFence: number;
}

interface MutableLiveState {
  liveGeneration: number;
  nextArrivalOrdinal: number;
  items: LiveOverlayItem[];
}

export class ConversationReceiveCore {
  readonly #reader: ProviderHistoryReader;
  readonly #maxPageSize: number;
  readonly #cache = new Map<string, CacheEntry>();
  readonly #initialLoads = new Map<string, Promise<CacheEntry>>();
  readonly #live = new Map<string, MutableLiveState>();

  constructor(
    reader: ProviderHistoryReader,
    options: ConversationReceiveCoreOptions = {},
  ) {
    this.#reader = reader;
    this.#maxPageSize = options.maxPageSize ?? DEFAULT_MAX_PAGE_SIZE;
    if (!Number.isSafeInteger(this.#maxPageSize) || this.#maxPageSize <= 0) {
      throw new RangeError("maxPageSize must be a positive safe integer");
    }
  }

  async load(
    thread: ThreadRef,
    options: LoadOptions = {},
  ): Promise<CanonicalTimelineSnapshot> {
    assertThreadRef(thread);
    const key = threadKey(thread);
    let entry = this.#cache.get(key);

    if (entry === undefined && options.refresh !== true) {
      let initialLoad = this.#initialLoads.get(key);
      if (initialLoad === undefined) {
        initialLoad = this.#refresh(thread, undefined).finally(() => {
          if (this.#initialLoads.get(key) === initialLoad) {
            this.#initialLoads.delete(key);
          }
        });
        this.#initialLoads.set(key, initialLoad);
      }
      entry = await initialLoad;
    } else if (options.refresh === true) {
      entry = await this.#refresh(thread, entry);
    }
    if (entry === undefined) {
      throw new ReceiveCoreLoadError("internal_cache_miss");
    }

    return projectWindow(
      entry.timeline,
      entry.health,
      this.#pageSize(options.pageSize),
      options.beforeOrdinal,
    );
  }

  applyLive(thread: ThreadRef, event: ProviderLiveItem): LiveApplyResult {
    assertThreadRef(thread);
    const key = threadKey(thread);
    let state = this.#live.get(key);

    if (!sameThread(thread, event)) {
      return freezeLiveResult(false, "source_mismatch", thread, state);
    }
    if (
      !Number.isSafeInteger(event.liveGeneration) ||
      event.liveGeneration < 0
    ) {
      return freezeLiveResult(
        false,
        "stale_live_generation",
        thread,
        state,
      );
    }
    try {
      assertStableId(event.providerTurnId, "providerTurnId");
      validateProviderItem(event.item);
    } catch {
      return freezeLiveResult(
        false,
        "invalid_provider_fact",
        thread,
        state,
      );
    }

    if (state !== undefined && event.liveGeneration < state.liveGeneration) {
      return freezeLiveResult(
        false,
        "stale_live_generation",
        thread,
        state,
      );
    }

    if (state === undefined || event.liveGeneration > state.liveGeneration) {
      state = {
        liveGeneration: event.liveGeneration,
        nextArrivalOrdinal: 0,
        items: [],
      };
      this.#live.set(key, state);
    }

    const canonical = this.#cache.get(key)?.timeline;
    if (canonicalHasItem(canonical, event.providerTurnId, event.item.providerItemId)) {
      return freezeLiveResult(true, undefined, thread, state);
    }
    if (
      canonical?.items.some(
        (candidate) =>
          candidate.ref.providerItemId === event.item.providerItemId &&
          candidate.ref.turn.providerTurnId !== event.providerTurnId,
      ) === true
    ) {
      return freezeLiveResult(
        false,
        "duplicate_provider_identity",
        thread,
        state,
      );
    }

    const duplicateIndex = state.items.findIndex(
      (candidate) => candidate.item.providerItemId === event.item.providerItemId,
    );
    if (duplicateIndex >= 0) {
      const duplicate = state.items[duplicateIndex];
      if (duplicate.providerTurnId !== event.providerTurnId) {
        return freezeLiveResult(
          false,
          "duplicate_provider_identity",
          thread,
          state,
        );
      }
      state.items[duplicateIndex] = freeze({
        ...duplicate,
        item: cloneProviderItem(event.item),
      });
      return freezeLiveResult(true, undefined, thread, state);
    }

    const arrivalOrdinal = state.nextArrivalOrdinal;
    state.nextArrivalOrdinal += 1;
    state.items.push(
      freeze({
        providerTurnId: event.providerTurnId,
        item: cloneProviderItem(event.item),
        arrivalOrdinal,
        orderKey: `live:${pad(event.liveGeneration)}:${pad(arrivalOrdinal)}`,
      }),
    );
    return freezeLiveResult(true, undefined, thread, state);
  }

  getLiveOverlay(thread: ThreadRef): LiveOverlay | undefined {
    assertThreadRef(thread);
    const state = this.#live.get(threadKey(thread));
    return state === undefined ? undefined : snapshotLiveOverlay(thread, state);
  }

  #pageSize(requested: number | undefined): number {
    const pageSize = requested ?? this.#maxPageSize;
    if (!Number.isSafeInteger(pageSize) || pageSize <= 0) {
      throw new RangeError("pageSize must be a positive safe integer");
    }
    return Math.min(pageSize, this.#maxPageSize);
  }

  async #refresh(
    thread: ThreadRef,
    previous: CacheEntry | undefined,
  ): Promise<CacheEntry> {
    const key = threadKey(thread);
    let candidate: ProviderThreadSnapshot;
    try {
      candidate = await this.#reader.readThread(freezeThreadRef(thread));
    } catch (error) {
      const current = this.#cache.get(key) ?? previous;
      const timeout = error instanceof ProviderHistoryTimeoutError;
      const code =
        error instanceof ProviderHistoryReadError
          ? error.code
          : timeout
            ? "provider_history_timeout"
            : "provider_history_error";
      return this.#preserveOrThrow(
        thread,
        current,
        timeout ? "timeout" : "error",
        code,
      );
    }

    const current = this.#cache.get(key) ?? previous;

    if (!sameThread(thread, candidate)) {
      return this.#preserveOrThrow(
        thread,
        current,
        "rejected",
        "source_mismatch",
        candidate.readGeneration,
      );
    }

    let normalized: NormalizedTimeline;
    try {
      normalized = normalizeProviderSnapshot(candidate);
    } catch (error) {
      const code =
        error instanceof ReceiveCoreLoadError
          ? error.code
          : "invalid_provider_snapshot";
      return this.#preserveOrThrow(
        thread,
        current,
        "rejected",
        code,
        candidate.readGeneration,
      );
    }

    if (
      current !== undefined &&
      normalized.readGeneration <= current.readGenerationFence
    ) {
      return this.#preserveOrThrow(
        thread,
        current,
        "rejected",
        "stale_read_generation",
        normalized.readGeneration,
        true,
      );
    }

    if (current !== undefined && normalized.providerReadStatus !== "complete") {
      const state = normalized.providerReadStatus === "empty" ? "empty" : "partial";
      return this.#preserveOrThrow(
        thread,
        current,
        state,
        `weaker_${normalized.providerReadStatus}_snapshot`,
        normalized.readGeneration,
        true,
      );
    }

    const health = freeze<ReadHealth>({
      state:
        normalized.providerReadStatus === "complete"
          ? "healthy"
          : normalized.providerReadStatus,
      servedReadGeneration: normalized.readGeneration,
      observedReadGeneration: normalized.readGeneration,
    });
    const accepted = freeze<CacheEntry>({
      timeline: normalized,
      health,
      readGenerationFence: normalized.readGeneration,
    });
    this.#cache.set(key, accepted);
    this.#promoteLiveItems(key, normalized);
    return accepted;
  }

  #preserveOrThrow(
    thread: ThreadRef,
    previous: CacheEntry | undefined,
    state: ReadHealth["state"],
    code: string,
    observedReadGeneration?: number,
    advanceReadFence = false,
  ): CacheEntry {
    if (previous === undefined) {
      throw new ReceiveCoreLoadError(code);
    }
    const preserved = freeze<CacheEntry>({
      timeline: previous.timeline,
      health: freeze({
        state,
        servedReadGeneration: previous.timeline.readGeneration,
        observedReadGeneration,
        code,
      }),
      readGenerationFence:
        advanceReadFence && observedReadGeneration !== undefined
          ? Math.max(previous.readGenerationFence, observedReadGeneration)
          : previous.readGenerationFence,
    });
    this.#cache.set(threadKey(thread), preserved);
    return preserved;
  }

  #promoteLiveItems(key: string, timeline: NormalizedTimeline): void {
    const state = this.#live.get(key);
    if (state === undefined) return;
    const canonicalIdentities = new Set(
      timeline.items.map((item) =>
        itemIdentity(
          item.ref.turn.providerTurnId,
          item.ref.providerItemId,
        ),
      ),
    );
    state.items = state.items.filter(
      (item) =>
        !canonicalIdentities.has(
          itemIdentity(item.providerTurnId, item.item.providerItemId),
        ),
    );
  }
}

function normalizeProviderSnapshot(
  snapshot: ProviderThreadSnapshot,
): NormalizedTimeline {
  assertSource(snapshot.source);
  assertStableId(snapshot.providerThreadId, "providerThreadId");
  if (
    !Number.isSafeInteger(snapshot.readGeneration) ||
    snapshot.readGeneration < 0
  ) {
    throw new ReceiveCoreLoadError("invalid_read_generation");
  }
  if (
    snapshot.readStatus !== "complete" &&
    snapshot.readStatus !== "partial" &&
    snapshot.readStatus !== "empty"
  ) {
    throw new ReceiveCoreLoadError("invalid_read_status");
  }
  if (snapshot.readStatus === "empty" && snapshot.turns.length > 0) {
    throw new ReceiveCoreLoadError("nonempty_provider_empty_snapshot");
  }

  const thread = freezeThreadRef(snapshot);
  const seenTurns = new Set<string>();
  const seenItems = new Set<string>();
  const turns: CanonicalTurnRef[] = [];
  const items: CanonicalTimelineItem[] = [];
  const turnItemRanges: Array<{
    start: CanonicalTimelineItem;
    end: CanonicalTimelineItem;
    count: number;
  }> = [];

  snapshot.turns.forEach((turn, turnOrdinal) => {
    assertStableId(turn.providerTurnId, "providerTurnId");
    if (seenTurns.has(turn.providerTurnId)) {
      throw new ReceiveCoreLoadError("duplicate_provider_turn_id");
    }
    seenTurns.add(turn.providerTurnId);
    const turnRef = freeze<CanonicalTurnRef>({
      thread,
      providerTurnId: turn.providerTurnId,
      turnOrdinal,
      orderKey: `turn:${pad(turnOrdinal)}`,
    });
    turns.push(turnRef);
    const firstIndex = items.length;

    turn.items.forEach((item, itemOrdinal) => {
      validateProviderItem(item);
      if (seenItems.has(item.providerItemId)) {
        throw new ReceiveCoreLoadError("duplicate_provider_item_id");
      }
      seenItems.add(item.providerItemId);
      const ordinal = items.length;
      const providerKind = item.kind;
      const canonicalItem = freeze<CanonicalTimelineItem>({
        ref: freeze({
          turn: turnRef,
          providerItemId: item.providerItemId,
          itemOrdinal,
          ordinal,
          orderKey: `item:${pad(ordinal)}:${pad(turnOrdinal)}:${pad(itemOrdinal)}`,
        }),
        kind: KNOWN_ITEM_KINDS.has(providerKind as CanonicalItemKind)
          ? (providerKind as CanonicalItemKind)
          : "unknown",
        providerKind,
        payload: cloneJson(item.payload),
      });
      items.push(canonicalItem);
    });

    if (items.length > firstIndex) {
      turnItemRanges.push({
        start: items[firstIndex],
        end: items[items.length - 1],
        count: items.length - firstIndex,
      });
    }
  });

  const islands = buildIslands(snapshot.readStatus, items, turnItemRanges);
  const providerGaps = buildProviderGaps(thread, snapshot.readStatus, islands);
  return freeze<NormalizedTimeline>({
    thread,
    readGeneration: snapshot.readGeneration,
    providerReadStatus: snapshot.readStatus,
    turns: freeze(turns),
    items: freeze(items),
    islands,
    providerGaps,
  });
}

function buildIslands(
  status: ProviderReadStatus,
  items: readonly CanonicalTimelineItem[],
  turnRanges: readonly {
    start: CanonicalTimelineItem;
    end: CanonicalTimelineItem;
    count: number;
  }[],
): readonly CoverageIsland[] {
  if (items.length === 0) return freeze([]);
  if (status === "complete") {
    return freeze([
      freeze({
        start: boundary(items[0]),
        end: boundary(items[items.length - 1]),
        itemCount: items.length,
      }),
    ]);
  }
  return freeze(
    turnRanges.map((range) =>
      freeze({
        start: boundary(range.start),
        end: boundary(range.end),
        itemCount: range.count,
      }),
    ),
  );
}

function buildProviderGaps(
  thread: ThreadRef,
  status: ProviderReadStatus,
  islands: readonly CoverageIsland[],
): readonly TimelineGap[] {
  if (status === "complete") return freeze([]);
  if (islands.length === 0) {
    return freeze([makeGap(thread, "provider_history_unknown")]);
  }
  const gaps: TimelineGap[] = [
    makeGap(thread, "provider_history_unknown", undefined, islands[0].start),
  ];
  for (let index = 1; index < islands.length; index += 1) {
    gaps.push(
      makeGap(
        thread,
        "provider_history_unknown",
        islands[index - 1].end,
        islands[index].start,
      ),
    );
  }
  gaps.push(
    makeGap(
      thread,
      "provider_history_unknown",
      islands[islands.length - 1].end,
    ),
  );
  return freeze(gaps);
}

function projectWindow(
  timeline: NormalizedTimeline,
  health: ReadHealth,
  pageSize: number,
  beforeOrdinal: number | undefined,
): CanonicalTimelineSnapshot {
  if (
    beforeOrdinal !== undefined &&
    (!Number.isSafeInteger(beforeOrdinal) || beforeOrdinal < 0)
  ) {
    throw new RangeError("beforeOrdinal must be a non-negative safe integer");
  }
  const end = Math.min(beforeOrdinal ?? timeline.items.length, timeline.items.length);
  const start = Math.max(0, end - pageSize);
  const items = freeze(timeline.items.slice(start, end));
  const knownTurns = freeze(
    items.reduce<CanonicalTurnRef[]>((result, item) => {
      if (result.at(-1)?.providerTurnId !== item.ref.turn.providerTurnId) {
        result.push(item.ref.turn);
      }
      return result;
    }, []),
  );
  const gaps = [...timeline.providerGaps];
  if (start > 0) {
    gaps.push(
      makeGap(
        timeline.thread,
        "window_not_loaded",
        boundary(timeline.items[start - 1]),
        boundary(timeline.items[start]),
      ),
    );
  }
  if (end < timeline.items.length) {
    gaps.push(
      makeGap(
        timeline.thread,
        "window_not_loaded",
        end > 0 ? boundary(timeline.items[end - 1]) : undefined,
        boundary(timeline.items[end]),
      ),
    );
  }
  return freeze({
    thread: timeline.thread,
    readGeneration: timeline.readGeneration,
    knownTurns,
    items,
    coverage: freeze({
      providerReadStatus: timeline.providerReadStatus,
      knownItemCount: timeline.items.length,
      windowStartOrdinal: items[0]?.ref.ordinal,
      windowEndOrdinal: items.at(-1)?.ref.ordinal,
      hasEarlierWindowItems: start > 0,
      hasLaterWindowItems: end < timeline.items.length,
      islands: timeline.islands,
      gaps: freeze(gaps),
    }),
    readHealth: health,
  });
}

function makeGap(
  thread: ThreadRef,
  kind: TimelineGap["kind"],
  after?: CoverageBoundary,
  before?: CoverageBoundary,
): TimelineGap {
  const gapId = stableKey([
    "gap-v1",
    thread.source.bridgeIdentityId,
    thread.source.bridgeInstanceId,
    thread.source.codexSourceId,
    thread.providerThreadId,
    kind,
    boundaryKey(after),
    boundaryKey(before),
  ]);
  return freeze({ gapId, kind, after, before });
}

function boundary(item: CanonicalTimelineItem): CoverageBoundary {
  return freeze({
    providerTurnId: item.ref.turn.providerTurnId,
    providerItemId: item.ref.providerItemId,
    ordinal: item.ref.ordinal,
  });
}

function boundaryKey(value: CoverageBoundary | undefined): string {
  if (value === undefined) return "";
  return stableKey([
    value.providerTurnId,
    value.providerItemId,
  ]);
}

function canonicalHasItem(
  timeline: NormalizedTimeline | undefined,
  providerTurnId: string,
  providerItemId: string,
): boolean {
  return (
    timeline?.items.some(
      (item) =>
        item.ref.turn.providerTurnId === providerTurnId &&
        item.ref.providerItemId === providerItemId,
    ) ?? false
  );
}

function freezeLiveResult(
  accepted: boolean,
  rejection: LiveApplyResult["rejection"],
  thread: ThreadRef,
  state: MutableLiveState | undefined,
): LiveApplyResult {
  const overlay =
    state === undefined
      ? freeze<LiveOverlay>({
          thread: freezeThreadRef(thread),
          liveGeneration: -1,
          items: freeze([]),
        })
      : snapshotLiveOverlay(thread, state);
  return freeze({ accepted, rejection, overlay });
}

function snapshotLiveOverlay(
  thread: ThreadRef,
  state: MutableLiveState,
): LiveOverlay {
  return freeze({
    thread: freezeThreadRef(thread),
    liveGeneration: state.liveGeneration,
    items: freeze([...state.items]),
  });
}

function validateProviderItem(item: ProviderItemSnapshot): void {
  assertStableId(item.providerItemId, "providerItemId");
  if (typeof item.kind !== "string") {
    throw new ReceiveCoreLoadError("invalid_provider_item_kind");
  }
  cloneJson(item.payload);
}

function cloneProviderItem(item: ProviderItemSnapshot): ProviderItemSnapshot {
  return freeze({
    providerItemId: item.providerItemId,
    kind: item.kind,
    payload: cloneJson(item.payload),
  });
}

function cloneJson(value: JsonValue): JsonValue {
  if (Array.isArray(value)) {
    return freeze(value.map((entry) => cloneJson(entry)));
  }
  if (value !== null && typeof value === "object") {
    const result: Record<string, JsonValue> = {};
    for (const [key, entry] of Object.entries(value)) {
      result[key] = cloneJson(entry);
    }
    return freeze(result);
  }
  if (
    value === null ||
    typeof value === "string" ||
    typeof value === "boolean" ||
    (typeof value === "number" && Number.isFinite(value))
  ) {
    return value;
  }
  throw new ReceiveCoreLoadError("invalid_provider_item_payload");
}

function assertThreadRef(thread: ThreadRef): void {
  assertSource(thread.source);
  assertStableId(thread.providerThreadId, "providerThreadId");
}

function assertSource(source: SourcePartition): void {
  assertStableId(source.bridgeIdentityId, "bridgeIdentityId");
  assertStableId(source.bridgeInstanceId, "bridgeInstanceId");
  assertStableId(source.codexSourceId, "codexSourceId");
}

function assertStableId(value: string, field: string): void {
  if (typeof value !== "string" || value.length === 0) {
    throw new ReceiveCoreLoadError(`invalid_${field}`);
  }
}

function sameThread(
  expected: ThreadRef,
  actual: Pick<ThreadRef, "source" | "providerThreadId">,
): boolean {
  return (
    expected.providerThreadId === actual.providerThreadId &&
    expected.source.bridgeIdentityId === actual.source.bridgeIdentityId &&
    expected.source.bridgeInstanceId === actual.source.bridgeInstanceId &&
    expected.source.codexSourceId === actual.source.codexSourceId
  );
}

function freezeThreadRef(thread: ThreadRef): ThreadRef {
  return freeze({
    source: freeze({ ...thread.source }),
    providerThreadId: thread.providerThreadId,
  });
}

function threadKey(thread: ThreadRef): string {
  return stableKey([
    thread.source.bridgeIdentityId,
    thread.source.bridgeInstanceId,
    thread.source.codexSourceId,
    thread.providerThreadId,
  ]);
}

function itemIdentity(providerTurnId: string, providerItemId: string): string {
  return stableKey([providerTurnId, providerItemId]);
}

function stableKey(parts: readonly string[]): string {
  return parts.map((part) => `${part.length}:${part}`).join("|");
}

function pad(value: number): string {
  return String(value).padStart(ORDER_WIDTH, "0");
}

function freeze<T>(value: T): T {
  return Object.freeze(value);
}
