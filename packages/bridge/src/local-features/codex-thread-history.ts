import type { AssistantContent, ServerMessage } from "../parser.js";
import {
  codexThreadToSessionHistory,
  type SessionHistoryMessage,
} from "../sessions-index.js";

/**
 * Pure Codex thread-history adapter shared by optional read-only surfaces.
 *
 * It deliberately emits protocol messages only. It never resolves paths,
 * registers images, materializes artifacts, or mutates Gallery state, so a
 * feature can render history with the normal mobile chat components without
 * depending on another optional feature.
 */
export function codexThreadToServerMessages(
  threadOrTurns: unknown,
  options: { idPrefix?: string } = {},
): ServerMessage[] {
  const thread = Array.isArray(threadOrTurns)
    ? { turns: threadOrTurns }
    : threadOrTurns;
  return sessionHistoryToServerMessages(codexThreadToSessionHistory(thread), {
    idPrefix: options.idPrefix,
  });
}

export function sessionHistoryToServerMessages(
  history: readonly SessionHistoryMessage[],
  options: { idPrefix?: string } = {},
): ServerMessage[] {
  const idPrefix = options.idPrefix ?? "thread-history";
  return history.flatMap((message, index) =>
    sessionHistoryMessageToServerMessages(message, index, idPrefix),
  );
}

function sessionHistoryMessageToServerMessages(
  history: SessionHistoryMessage,
  index: number,
  idPrefix: string,
): ServerMessage[] {
  if (history.role === "user") {
    const text = historyContentText(history.content);
    if (!text) return [];
    return [
      {
        type: "user_input",
        text,
        ...(history.uuid ? { userMessageUuid: history.uuid } : {}),
        ...(history.isMeta ? { isMeta: true } : {}),
        ...(history.imageCount ? { imageCount: history.imageCount } : {}),
        ...(history.timestamp ? { timestamp: history.timestamp } : {}),
        ...(history.timestamp ? { sourceTimestamp: history.timestamp } : {}),
        ...(history.timestamp && history.timestampIsAuthoritative
          ? { sourceTimestampIsAuthoritative: true }
          : {}),
      },
    ];
  }

  if (history.role === "tool_result") {
    const content = historyContentText(history.content);
    if (!content) return [];
    return [
      {
        type: "tool_result",
        toolUseId:
          history.toolUseId ?? history.uuid ?? `${idPrefix}-tool-${index}`,
        content,
        ...(history.toolName ? { toolName: history.toolName } : {}),
        ...(history.timestamp ? { sourceTimestamp: history.timestamp } : {}),
        ...(history.timestamp && history.timestampIsAuthoritative
          ? { sourceTimestampIsAuthoritative: true }
          : {}),
      },
    ];
  }

  const content = historyAssistantContent(history.content);
  if (content.length === 0) return [];
  const id = history.uuid ?? history.rawItemId ?? `${idPrefix}-${index}`;
  return [
    {
      type: "assistant",
      message: { id, role: "assistant", content, model: "" },
      ...(history.uuid ? { messageUuid: history.uuid } : {}),
      ...(history.timestamp ? { sourceTimestamp: history.timestamp } : {}),
      ...(history.timestamp && history.timestampIsAuthoritative
        ? { sourceTimestampIsAuthoritative: true }
        : {}),
    },
  ];
}

function historyContentText(content: SessionHistoryMessage["content"]): string {
  if (typeof content === "string") return content;
  return content
    .flatMap((item) => {
      if (item.type === "text" && typeof item.text === "string") {
        return [item.text];
      }
      if (item.type === "thinking" && typeof item.thinking === "string") {
        return [item.thinking];
      }
      return [];
    })
    .filter(Boolean)
    .join("\n");
}

function historyAssistantContent(
  content: SessionHistoryMessage["content"],
): AssistantContent[] {
  if (typeof content === "string") {
    return content ? [{ type: "text", text: content }] : [];
  }

  const converted: AssistantContent[] = [];
  for (const item of content) {
    if (item.type === "text" && typeof item.text === "string" && item.text) {
      converted.push({ type: "text", text: item.text });
    } else if (
      item.type === "thinking" &&
      typeof item.thinking === "string" &&
      item.thinking
    ) {
      converted.push({ type: "thinking", thinking: item.thinking });
    } else if (
      item.type === "tool_use" &&
      typeof item.id === "string" &&
      typeof item.name === "string"
    ) {
      converted.push({
        type: "tool_use",
        id: item.id,
        name: item.name,
        input: isRecord(item.input) ? item.input : {},
      });
    }
  }
  return converted;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
