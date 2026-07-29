import { createHash } from "node:crypto";

import type { HistoryToolDetailGap, ServerMessage } from "./parser.js";

export const TURN_AWARE_HISTORY_WINDOW_CAPABILITY =
  "turn_aware_history_window_v1";
export const HISTORY_PAGE_CAPABILITY = "history_page_v1";
export const HISTORY_TOOL_DETAIL_CAPABILITY = "history_tool_detail_v1";
export const TURN_AWARE_HISTORY_ROOT_TURNS = 5;
export const TURN_AWARE_HISTORY_TOOL_CALLS = 200;
export const TURN_AWARE_HISTORY_ENVELOPE_ENTRIES = 300;
export const TURN_AWARE_HISTORY_MAX_RETAINED_ENTRIES = 755;
export const TURN_AWARE_HISTORY_GAP_TOOL_IDS = 200;

type SequencedServerMessage = { message: ServerMessage };
type ProjectedEntry<T extends SequencedServerMessage> = {
  sourceIndex: number;
  entry: T;
};

/**
 * Keeps the conversational spine of the latest root turns while bounding
 * expensive tool input/result details independently from ordinary text.
 *
 * The newest tool calls retain their complete envelopes. Older calls are
 * represented by compact, stable gap metadata attached to one assistant
 * envelope per process segment. A client can then request the omitted details
 * explicitly without downloading or parsing them during the initial render.
 */
export function selectTurnAwareHistoryWindow<T extends SequencedServerMessage>(
  entries: readonly T[],
  options: {
    rootTurns?: number;
    toolCalls?: number;
    envelopeEntries?: number;
    maxRetainedEntries?: number;
    preserveLatestRootTurnTools?: boolean;
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
  const baseMaxRetainedEntries = positiveLimit(
    options.maxRetainedEntries,
    TURN_AWARE_HISTORY_MAX_RETAINED_ENTRIES,
  );
  const maxRetainedEntries = options.preserveLatestRootTurnTools
    ? baseMaxRetainedEntries +
      Math.max(0, entries.length - startOfLatestRootTurns(entries, 1))
    : baseMaxRetainedEntries;
  const effectiveRootTurns = Math.min(rootTurns, maxRetainedEntries);
  const start = startOfLatestRootTurns(entries, effectiveRootTurns);
  const retainedToolIds = options.preserveLatestRootTurnTools
    ? newestHistoricalAndAllLatestTurnToolIds(entries, start, toolCalls)
    : newestToolIds(entries, start, toolCalls);
  const ordinaryIndexes = newestOrdinaryEnvelopeIndexes(
    entries,
    start,
    envelopeEntries,
  );
  const projected = projectEntries(
    entries,
    start,
    retainedToolIds,
    ordinaryIndexes,
  );
  if (projected.length <= maxRetainedEntries) {
    return projected.map((value) => value.entry);
  }
  return hardCapProjectedEntries(projected, maxRetainedEntries).map(
    (index) => projected[index].entry,
  );
}

function newestHistoricalAndAllLatestTurnToolIds<
  T extends SequencedServerMessage,
>(entries: readonly T[], start: number, historicalLimit: number): Set<string> {
  let latestTurnStart = start;
  for (let index = entries.length - 1; index >= start; index -= 1) {
    if (entries[index].message.type === "user_input") {
      latestTurnStart = index;
      break;
    }
  }
  const selected = new Set<string>();
  for (
    let index = latestTurnStart - 1;
    index >= start && selected.size < historicalLimit;
    index -= 1
  ) {
    const ids = concreteToolIdsForMessage(entries[index].message);
    for (let position = ids.length - 1; position >= 0; position -= 1) {
      const id = ids[position];
      if (selected.has(id)) continue;
      if (selected.size >= historicalLimit) break;
      selected.add(id);
    }
  }
  for (let index = latestTurnStart; index < entries.length; index += 1) {
    for (const id of concreteToolIdsForMessage(entries[index].message)) {
      selected.add(id);
    }
  }
  return selected;
}

function newestToolIds<T extends SequencedServerMessage>(
  entries: readonly T[],
  start: number,
  limit: number,
): Set<string> {
  const selected = new Set<string>();
  if (limit <= 0) return selected;
  for (let index = entries.length - 1; index >= start; index -= 1) {
    const ids = concreteToolIdsForMessage(entries[index].message);
    for (let position = ids.length - 1; position >= 0; position -= 1) {
      const id = ids[position];
      if (selected.has(id)) continue;
      if (selected.size >= limit) return selected;
      selected.add(id);
    }
  }
  return selected;
}

function newestOrdinaryEnvelopeIndexes<T extends SequencedServerMessage>(
  entries: readonly T[],
  start: number,
  limit: number,
): Set<number> {
  const selected = new Set<number>();
  if (limit <= 0) return selected;
  for (let index = entries.length - 1; index >= start; index -= 1) {
    const message = entries[index].message;
    if (message.type === "user_input") continue;
    if (heavyToolIdsForMessage(message).length > 0) continue;
    selected.add(index);
    if (selected.size >= limit) break;
  }
  return selected;
}

function projectEntries<T extends SequencedServerMessage>(
  entries: readonly T[],
  start: number,
  retainedToolIds: ReadonlySet<string>,
  ordinaryIndexes: ReadonlySet<number>,
): Array<ProjectedEntry<T>> {
  const projected: Array<ProjectedEntry<T>> = [];
  const gappedToolIds = new Set<string>();
  let gapHost: { outputIndex: number; gaps: HistoryToolDetailGap[] } | null =
    null;

  const setHostGaps = (host: {
    outputIndex: number;
    gaps: HistoryToolDetailGap[];
  }) => {
    const current = projected[host.outputIndex];
    const message = current.entry.message;
    if (message.type !== "assistant") return;
    projected[host.outputIndex] = {
      sourceIndex: current.sourceIndex,
      entry: withMessage(current.entry, {
        ...message,
        historyToolDetailGaps: host.gaps,
      }),
    };
  };

  const createGapHost = (sourceIndex: number) => {
    const source = entries[sourceIndex];
    const sourceMessage = source.message;
    const outputIndex = projected.length;
    const gaps: HistoryToolDetailGap[] = [];
    projected.push({
      sourceIndex,
      entry: withMessage(source, {
        type: "assistant",
        message:
          sourceMessage.type === "assistant"
            ? { ...sourceMessage.message, content: [] }
            : {
                id: `history-tool-gap-${sourceIndex}`,
                role: "assistant",
                model: "",
                content: [],
              },
        ...(sourceMessage.type === "assistant" && sourceMessage.messageUuid
          ? { messageUuid: sourceMessage.messageUuid }
          : {}),
        historyToolDetailGaps: gaps,
      }),
    });
    gapHost = { outputIndex, gaps };
    return gapHost;
  };

  const addGapTool = (
    sourceIndex: number,
    toolUseId: string,
    toolName: string,
    turnId?: string,
  ) => {
    const id = toolUseId.trim();
    if (!id || gappedToolIds.has(id)) return;
    const host = gapHost ?? createGapHost(sourceIndex);
    let gap = host.gaps.at(-1);
    if (
      !gap ||
      gap.toolUseIds.length >= TURN_AWARE_HISTORY_GAP_TOOL_IDS ||
      gap.turnId !== turnId
    ) {
      gap = {
        gapId: "",
        toolUseIds: [],
        toolNames: [],
        toolCallCount: 0,
        ...(turnId ? { turnId } : {}),
      };
      host.gaps.push(gap);
    }
    gap.toolUseIds.push(id);
    gap.toolNames.push(toolName.trim());
    gap.toolCallCount = gap.toolUseIds.length;
    gap.gapId = historyToolDetailGapId(gap.toolUseIds);
    gappedToolIds.add(id);
    setHostGaps(host);
  };

  for (let index = start; index < entries.length; index += 1) {
    const entry = entries[index];
    const message = entry.message;
    if (message.type === "user_input") {
      gapHost = null;
      projected.push({ sourceIndex: index, entry });
      continue;
    }

    if (message.type === "assistant") {
      const hasVisibleText = assistantHasVisibleText(message);
      const hasVisibleSpine = assistantHasVisibleSpine(message);
      if (hasVisibleText) gapHost = null;
      const retainedContent = message.message.content.filter(
        (content) =>
          content.type !== "tool_use" ||
          (content.id.trim().length > 0 &&
            retainedToolIds.has(content.id.trim())),
      );
      const omittedTools = message.message.content.filter(
        (content) =>
          content.type === "tool_use" &&
          content.id.trim().length > 0 &&
          !retainedToolIds.has(content.id.trim()),
      );
      const existingGaps = message.historyToolDetailGaps ?? [];
      const hasRetainedTool = retainedContent.some(
        (content) => content.type === "tool_use",
      );
      const shouldRetainEnvelope =
        hasVisibleSpine ||
        hasRetainedTool ||
        (message.artifacts?.length ?? 0) > 0 ||
        ordinaryIndexes.has(index);

      if (shouldRetainEnvelope) {
        const outputIndex = projected.length;
        projected.push({
          sourceIndex: index,
          entry: withMessage(entry, {
            ...message,
            message: { ...message.message, content: retainedContent },
            historyToolDetailGaps: undefined,
          }),
        });
        if (hasVisibleText) gapHost = { outputIndex, gaps: [] };
      }

      if (
        (existingGaps.length > 0 || omittedTools.length > 0) &&
        gapHost === null &&
        shouldRetainEnvelope
      ) {
        gapHost = { outputIndex: projected.length - 1, gaps: [] };
      }
      for (const existing of existingGaps) {
        for (
          let position = 0;
          position < existing.toolUseIds.length;
          position += 1
        ) {
          addGapTool(
            index,
            existing.toolUseIds[position],
            existing.toolNames[position] ?? "",
            existing.turnId ?? message.historyTurnId,
          );
        }
      }
      for (const content of omittedTools) {
        if (content.type === "tool_use") {
          addGapTool(index, content.id, content.name, message.historyTurnId);
        }
      }
      continue;
    }

    if (message.type === "tool_result") {
      const id = message.toolUseId.trim();
      if (id && !retainedToolIds.has(id)) {
        addGapTool(index, id, message.toolName ?? "", message.historyTurnId);
        continue;
      }
      projected.push({ sourceIndex: index, entry });
      continue;
    }

    if (message.type === "tool_use_summary" || ordinaryIndexes.has(index)) {
      projected.push({ sourceIndex: index, entry });
    }
  }

  return projected;
}

function withMessage<T extends SequencedServerMessage>(
  entry: T,
  message: ServerMessage,
): T {
  return { ...entry, message } as T;
}

function hardCapProjectedEntries<T extends SequencedServerMessage>(
  projected: Array<ProjectedEntry<T>>,
  limit: number,
): number[] {
  const selected = new Set<number>();
  for (let index = 0; index < projected.length; index += 1) {
    if (projected[index].entry.message.type === "user_input") {
      selected.add(index);
    }
  }
  for (
    let index = projected.length - 1;
    index >= 0 && selected.size < limit;
    index -= 1
  ) {
    selected.add(index);
  }
  return [...selected].sort((left, right) => left - right);
}

export function historyToolDetailGapId(toolUseIds: readonly string[]): string {
  const digest = createHash("sha256")
    .update(JSON.stringify(toolUseIds))
    .digest("hex")
    .slice(0, 24);
  return `tool-gap-v1:${toolUseIds.length}:${digest}`;
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

function assistantHasVisibleSpine(
  message: Extract<ServerMessage, { type: "assistant" }>,
): boolean {
  return message.message.content.some(
    (content) =>
      (content.type === "text" && content.text.trim().length > 0) ||
      (content.type === "thinking" && content.thinking.trim().length > 0),
  );
}

function concreteToolIdsForMessage(message: ServerMessage): string[] {
  if (message.type === "tool_result") {
    return uniqueNonEmpty([message.toolUseId]);
  }
  if (message.type !== "assistant") return [];
  return uniqueNonEmpty(
    message.message.content
      .filter((content) => content.type === "tool_use")
      .map((content) => content.id),
  );
}

function heavyToolIdsForMessage(message: ServerMessage): string[] {
  if (message.type !== "assistant") {
    return concreteToolIdsForMessage(message);
  }
  return uniqueNonEmpty([
    ...concreteToolIdsForMessage(message),
    ...(message.historyToolDetailGaps ?? []).flatMap((gap) => gap.toolUseIds),
  ]);
}

function uniqueNonEmpty(values: readonly string[]): string[] {
  return [...new Set(values.map((value) => value.trim()).filter(Boolean))];
}

function positiveLimit(value: number | undefined, fallback: number): number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0
    ? value
    : fallback;
}
