const MIN_RETAINED_TURNS = 4;
const DEFAULT_RETAINED_TURNS = 8;
const MAX_RETAINED_TURNS = 64;
const DEFAULT_TOMBSTONE_CAPACITY = 512;
const MAX_TOMBSTONE_CAPACITY = 4096;

interface AgentTurnState {
  readonly turnId: string;
  readonly openItemIds: Set<string>;
  readonly pendingTextByItemId: Map<string, string>;
  readonly tombstonedItemIds: Set<string>;
  anonymousPendingText: string;
  closed: boolean;
}

interface TombstoneEntry {
  readonly state: AgentTurnState;
  readonly itemId: string;
}

export interface CodexAgentTurnTrackerOptions {
  /** Completed turns retained for late item/completed notifications. */
  retainedTurnCount?: number;
  /** Global item tombstone bound across retained and active turns. */
  tombstoneCapacity?: number;
}

export interface CodexAgentTextEmission {
  readonly turnId: string | null;
  /** Null only for deltas that could not be attributed to one item. */
  readonly itemId: string | null;
  readonly text: string;
  readonly affectsActiveTurn: boolean;
  readonly source: "completed" | "turn_fallback";
}

export type CodexAgentItemCompletion =
  | {
      readonly kind: "emit";
      readonly emission: CodexAgentTextEmission;
    }
  | { readonly kind: "suppress" }
  | { readonly kind: "empty" };

/**
 * Tracks Codex agent-message streaming by turn and item identity.
 *
 * Text is deliberately never used as an identity key. Ambiguous anonymous
 * deltas remain separate and are emitted at turn completion (fail-open), while
 * identified fallbacks leave bounded tombstones for delayed completions.
 */
export class CodexAgentTurnTracker {
  private readonly retainedTurnCount: number;
  private readonly tombstoneCapacity: number;
  private readonly turns = new Map<string, AgentTurnState>();
  private readonly closedTurnIds: string[] = [];
  private readonly tombstoneOrder: TombstoneEntry[] = [];
  private activeTurnId: string | null = null;

  constructor(options: CodexAgentTurnTrackerOptions = {}) {
    this.retainedTurnCount = boundedInteger(
      options.retainedTurnCount,
      DEFAULT_RETAINED_TURNS,
      MIN_RETAINED_TURNS,
      MAX_RETAINED_TURNS,
    );
    this.tombstoneCapacity = boundedInteger(
      options.tombstoneCapacity,
      DEFAULT_TOMBSTONE_CAPACITY,
      this.retainedTurnCount,
      MAX_TOMBSTONE_CAPACITY,
    );
  }

  startTurn(turnId: string | null | undefined): void {
    const normalizedTurnId = nonEmpty(turnId);
    if (!normalizedTurnId) return;
    if (this.activeTurnId && this.activeTurnId !== normalizedTurnId) {
      const previousState = this.turns.get(this.activeTurnId);
      if (previousState) this.closeTurn(previousState);
    }
    this.activeTurnId = normalizedTurnId;
    const state = this.getOrCreateTurn(normalizedTurnId);
    if (state.closed) {
      const closedIndex = this.closedTurnIds.indexOf(normalizedTurnId);
      if (closedIndex >= 0) this.closedTurnIds.splice(closedIndex, 1);
    }
    state.closed = false;
  }

  startAgentItem(input: {
    turnId?: string | null;
    itemId?: string | null;
  }): void {
    const turnId = this.resolveTurnId(input.turnId);
    const itemId = nonEmpty(input.itemId);
    if (!turnId || !itemId) return;
    const state = this.getOrCreateTurn(turnId);
    state.openItemIds.add(itemId);
  }

  appendDelta(input: {
    turnId?: string | null;
    itemId?: string | null;
    text: string;
  }): void {
    if (!input.text) return;
    const turnId = this.resolveTurnId(input.turnId);
    if (!turnId) return;
    const state = this.getOrCreateTurn(turnId);
    const explicitItemId = nonEmpty(input.itemId);
    if (explicitItemId) {
      state.openItemIds.add(explicitItemId);
      appendPendingText(state, explicitItemId, input.text);
      return;
    }

    if (state.openItemIds.size === 1) {
      const [onlyOpenItemId] = state.openItemIds;
      appendPendingText(state, onlyOpenItemId, input.text);
      return;
    }

    state.anonymousPendingText += input.text;
  }

  completeAgentItem(input: {
    turnId?: string | null;
    itemId?: string | null;
    completedText?: string | null;
  }): CodexAgentItemCompletion {
    const itemId = nonEmpty(input.itemId);
    if (!itemId) return { kind: "empty" };

    const explicitTurnId = nonEmpty(input.turnId);
    const turnId = this.resolveCompletionTurnId(explicitTurnId, itemId);
    if (!turnId) {
      const text = nonBlank(input.completedText);
      return text
        ? {
            kind: "emit",
            emission: {
              turnId: null,
              itemId,
              text,
              affectsActiveTurn: false,
              source: "completed",
            },
          }
        : { kind: "empty" };
    }

    const state = this.getOrCreateTurn(turnId);
    if (state.tombstonedItemIds.has(itemId)) {
      return { kind: "suppress" };
    }

    const completedText = nonBlank(input.completedText);
    const pendingText = state.pendingTextByItemId.get(itemId) ?? null;
    state.pendingTextByItemId.delete(itemId);
    state.openItemIds.delete(itemId);

    const text = completedText ?? nonBlank(pendingText);
    if (!text) {
      if (turnId !== this.activeTurnId) this.closeTurn(state);
      return { kind: "empty" };
    }

    this.addTombstone(state, itemId);
    const affectsActiveTurn = turnId === this.activeTurnId;
    if (!affectsActiveTurn) this.closeTurn(state);
    return {
      kind: "emit",
      emission: {
        turnId,
        itemId,
        text,
        affectsActiveTurn,
        source: "completed",
      },
    };
  }

  completeTurn(explicitTurnId?: string | null): CodexAgentTextEmission[] {
    const turnId = this.resolveTurnId(explicitTurnId);
    if (!turnId) return [];
    const state = this.getOrCreateTurn(turnId);
    const affectsActiveTurn = turnId === this.activeTurnId;
    const emissions: CodexAgentTextEmission[] = [];

    for (const [itemId, pendingText] of state.pendingTextByItemId) {
      const text = nonBlank(pendingText);
      if (!text) continue;
      this.addTombstone(state, itemId);
      emissions.push({
        turnId,
        itemId,
        text,
        affectsActiveTurn,
        source: "turn_fallback",
      });
    }

    const anonymousText = nonBlank(state.anonymousPendingText);
    if (anonymousText) {
      emissions.push({
        turnId,
        itemId: null,
        text: anonymousText,
        affectsActiveTurn,
        source: "turn_fallback",
      });
    }

    state.pendingTextByItemId.clear();
    state.openItemIds.clear();
    state.anonymousPendingText = "";
    this.closeTurn(state);
    if (affectsActiveTurn) this.activeTurnId = null;
    return emissions;
  }

  reset(): void {
    this.activeTurnId = null;
    this.turns.clear();
    this.closedTurnIds.length = 0;
    this.tombstoneOrder.length = 0;
  }

  private resolveTurnId(
    explicitTurnId: string | null | undefined,
  ): string | null {
    return nonEmpty(explicitTurnId) ?? this.activeTurnId;
  }

  private resolveCompletionTurnId(
    explicitTurnId: string | null,
    itemId: string,
  ): string | null {
    if (explicitTurnId) return explicitTurnId;

    if (this.activeTurnId) {
      const activeState = this.turns.get(this.activeTurnId);
      if (
        activeState?.openItemIds.has(itemId) ||
        activeState?.pendingTextByItemId.has(itemId) ||
        activeState?.tombstonedItemIds.has(itemId)
      ) {
        return this.activeTurnId;
      }
    }

    for (let index = this.closedTurnIds.length - 1; index >= 0; index -= 1) {
      const turnId = this.closedTurnIds[index];
      if (this.turns.get(turnId)?.tombstonedItemIds.has(itemId)) {
        return turnId;
      }
    }
    return this.activeTurnId;
  }

  private getOrCreateTurn(turnId: string): AgentTurnState {
    const existing = this.turns.get(turnId);
    if (existing) return existing;
    const state: AgentTurnState = {
      turnId,
      openItemIds: new Set(),
      pendingTextByItemId: new Map(),
      tombstonedItemIds: new Set(),
      anonymousPendingText: "",
      closed: false,
    };
    this.turns.set(turnId, state);
    return state;
  }

  private addTombstone(state: AgentTurnState, itemId: string): void {
    if (state.tombstonedItemIds.has(itemId)) return;
    state.tombstonedItemIds.add(itemId);
    this.tombstoneOrder.push({ state, itemId });
    while (this.tombstoneOrder.length > this.tombstoneCapacity) {
      const oldest = this.tombstoneOrder.shift();
      if (!oldest) break;
      if (this.turns.get(oldest.state.turnId) === oldest.state) {
        oldest.state.tombstonedItemIds.delete(oldest.itemId);
      }
    }
  }

  private closeTurn(state: AgentTurnState): void {
    if (!state.closed) {
      state.closed = true;
      this.closedTurnIds.push(state.turnId);
    }
    while (this.closedTurnIds.length > this.retainedTurnCount) {
      const oldestTurnId = this.closedTurnIds.shift();
      if (!oldestTurnId) break;
      const oldestState = this.turns.get(oldestTurnId);
      if (oldestState?.closed) this.turns.delete(oldestTurnId);
    }
  }
}

function appendPendingText(
  state: AgentTurnState,
  itemId: string,
  delta: string,
): void {
  state.pendingTextByItemId.set(
    itemId,
    (state.pendingTextByItemId.get(itemId) ?? "") + delta,
  );
}

function nonEmpty(value: string | null | undefined): string | null {
  return typeof value === "string" && value.length > 0 ? value : null;
}

function nonBlank(value: string | null | undefined): string | null {
  return typeof value === "string" && value.trim().length > 0 ? value : null;
}

function boundedInteger(
  value: number | undefined,
  fallback: number,
  minimum: number,
  maximum: number,
): number {
  const candidate =
    typeof value === "number" && Number.isFinite(value)
      ? Math.floor(value)
      : fallback;
  return Math.min(maximum, Math.max(minimum, candidate));
}
