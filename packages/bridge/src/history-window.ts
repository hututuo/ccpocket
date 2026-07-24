import type { ServerMessage } from "./parser.js";

export const TURN_AWARE_HISTORY_WINDOW_CAPABILITY =
  "turn_aware_history_window_v1";
export const TURN_AWARE_HISTORY_ROOT_TURNS = 5;
export const TURN_AWARE_HISTORY_TOOL_CALLS = 200;
export const TURN_AWARE_HISTORY_ENVELOPE_ENTRIES = 300;
export const TURN_AWARE_HISTORY_MAX_RETAINED_ENTRIES = 705;

type SequencedServerMessage = { message: ServerMessage };

/**
 * Keeps the conversational spine of the latest root turns while bounding
 * expensive tool detail independently from ordinary assistant text.
 *
 * Selection runs newest-first so the most recent tool activity wins the
 * budget. Tool-use and tool-result envelopes sharing an id count as one call.
 * The returned entries retain their original chronological order and sequence
 * numbers, which keeps live history deltas compatible with the projection.
 */
export function selectTurnAwareHistoryWindow<T extends SequencedServerMessage>(
  entries: readonly T[],
  options: {
    rootTurns?: number;
    toolCalls?: number;
    envelopeEntries?: number;
    maxRetainedEntries?: number;
  } = {},
): T[] {
  if (entries.length === 0) return [];
  const rootTurns = positiveLimit(
    options.rootTurns,
    TURN_AWARE_HISTORY_ROOT_TURNS,
  );
  const toolCalls = positiveLimit(
    options.toolCalls,
    TURN_AWARE_HISTORY_TOOL_CALLS,
  );
  const envelopeEntries = positiveLimit(
    options.envelopeEntries,
    TURN_AWARE_HISTORY_ENVELOPE_ENTRIES,
  );
  const maxRetainedEntries = positiveLimit(
    options.maxRetainedEntries,
    TURN_AWARE_HISTORY_MAX_RETAINED_ENTRIES,
  );
  const effectiveRootTurns = Math.min(rootTurns, maxRetainedEntries);
  const start = startOfLatestRootTurns(entries, effectiveRootTurns);
  const retainedRootTurns = entries
    .slice(start)
    .filter((entry) => entry.message.type === "user_input").length;
  const nonRootEntryLimit = Math.max(0, maxRetainedEntries - retainedRootTurns);
  const selectedIndexes: number[] = [];
  const selectedToolIds = new Set<string>();
  let anonymousToolCalls = 0;
  let retainedEnvelopes = 0;
  let retainedNonRootEntries = 0;

  for (let index = entries.length - 1; index >= start; index -= 1) {
    const message = entries[index].message;
    const isRootTurn = message.type === "user_input";
    const toolIdentity = toolIdentityForMessage(message);
    const newToolIds = toolIdentity.ids.filter(
      (id) => !selectedToolIds.has(id),
    );
    const newToolCalls = newToolIds.length + toolIdentity.anonymousCount;
    const hasToolDetail =
      toolIdentity.ids.length > 0 || toolIdentity.anonymousCount > 0;
    const requiredTextEnvelope =
      message.type === "assistant" && assistantHasVisibleText(message);

    if (!isRootTurn && retainedNonRootEntries >= nonRootEntryLimit) {
      continue;
    }
    if (
      hasToolDetail &&
      !requiredTextEnvelope &&
      selectedToolIds.size + anonymousToolCalls + newToolCalls > toolCalls
    ) {
      continue;
    }
    if (!hasToolDetail && !isRootTurn && retainedEnvelopes >= envelopeEntries) {
      continue;
    }

    selectedIndexes.push(index);
    if (!isRootTurn) retainedNonRootEntries += 1;
    for (const id of newToolIds) selectedToolIds.add(id);
    anonymousToolCalls += toolIdentity.anonymousCount;
    if (!hasToolDetail && !isRootTurn) retainedEnvelopes += 1;
  }

  selectedIndexes.reverse();
  return selectedIndexes.map((index) => entries[index]);
}

function startOfLatestRootTurns<T extends SequencedServerMessage>(
  entries: readonly T[],
  rootTurns: number,
): number {
  if (rootTurns <= 0) return entries.length;
  let seen = 0;
  for (let index = entries.length - 1; index >= 0; index -= 1) {
    if (entries[index].message.type !== "user_input") continue;
    seen += 1;
    if (seen === rootTurns) return index;
  }
  return 0;
}

function assistantHasVisibleText(
  message: Extract<ServerMessage, { type: "assistant" }>,
): boolean {
  return message.message.content.some(
    (content) => content.type === "text" && content.text.trim().length > 0,
  );
}

function toolIdentityForMessage(message: ServerMessage): {
  ids: string[];
  anonymousCount: number;
} {
  if (message.type === "tool_result") {
    const id = message.toolUseId.trim();
    return id
      ? { ids: [id], anonymousCount: 0 }
      : { ids: [], anonymousCount: 1 };
  }
  if (message.type === "tool_use_summary") {
    const ids = uniqueNonEmpty(message.precedingToolUseIds);
    return ids.length > 0
      ? { ids, anonymousCount: 0 }
      : { ids: [], anonymousCount: 1 };
  }
  if (message.type !== "assistant") {
    return { ids: [], anonymousCount: 0 };
  }
  const toolUses = message.message.content.filter(
    (content) => content.type === "tool_use",
  );
  const ids = uniqueNonEmpty(toolUses.map((content) => content.id));
  return {
    ids,
    anonymousCount: toolUses.length - ids.length,
  };
}

function uniqueNonEmpty(values: readonly string[]): string[] {
  return [...new Set(values.map((value) => value.trim()).filter(Boolean))];
}

function positiveLimit(value: number | undefined, fallback: number): number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0
    ? value
    : fallback;
}
