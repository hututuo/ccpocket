import '../../../models/messages.dart';

class ChatProcessTurnLayout {
  const ChatProcessTurnLayout({
    required this.key,
    required this.processEntryIndices,
    required this.summaryEntryIndex,
    required this.finalAssistantEntryIndex,
    required this.thinkingBlocks,
    required this.toolCalls,
    required this.toolResults,
  });

  final String key;
  final Set<int> processEntryIndices;
  final int summaryEntryIndex;
  final int? finalAssistantEntryIndex;
  final int thinkingBlocks;
  final int toolCalls;
  final int toolResults;

  int get detailCount {
    final explicit = thinkingBlocks + toolCalls + toolResults;
    return explicit > 0 ? explicit : processEntryIndices.length;
  }

  bool isProcessEntry(int index) => processEntryIndices.contains(index);
  bool showsSummaryAt(int index) => summaryEntryIndex == index;
  bool hasInlineProcessAt(int index) =>
      finalAssistantEntryIndex == index &&
      (thinkingBlocks > 0 || toolCalls > 0);
}

class ChatProcessLayout {
  const ChatProcessLayout(this._turnsByEntryIndex, this.latestTurnKey);

  final Map<int, ChatProcessTurnLayout> _turnsByEntryIndex;
  final String? latestTurnKey;

  ChatProcessTurnLayout? turnForEntry(int index) => _turnsByEntryIndex[index];
}

ChatProcessLayout buildChatProcessLayout(List<ChatEntry> entries) {
  final turnsByIndex = <int, ChatProcessTurnLayout>{};
  String? latestTurnKey;

  var cursor = 0;
  while (cursor < entries.length) {
    final current = entries[cursor];
    if (current is! UserChatEntry) {
      cursor++;
      continue;
    }

    final turnStart = cursor;
    var turnEnd = turnStart + 1;
    while (turnEnd < entries.length && entries[turnEnd] is! UserChatEntry) {
      turnEnd++;
    }

    final turnKey = _turnKey(current);
    latestTurnKey = turnKey;
    final visibleAssistantIndices = <int>[];
    for (var i = turnStart + 1; i < turnEnd; i++) {
      final entry = entries[i];
      if (entry case ServerChatEntry(
        message: final AssistantServerMessage assistant,
      ) when _hasVisibleText(assistant)) {
        visibleAssistantIndices.add(i);
      }
    }
    final finalAssistantIndex = visibleAssistantIndices.isEmpty
        ? null
        : visibleAssistantIndices.last;

    final processIndices = <int>{};
    var thinkingBlocks = 0;
    var toolCalls = 0;
    var toolResults = 0;
    for (var i = turnStart + 1; i < turnEnd; i++) {
      final entry = entries[i];
      if (entry is! ServerChatEntry) continue;
      final message = entry.message;
      if (message is AssistantServerMessage) {
        final counts = _assistantProcessCounts(message);
        thinkingBlocks += counts.thinking;
        toolCalls += counts.tools;
        if (i != finalAssistantIndex &&
            (counts.thinking > 0 ||
                counts.tools > 0 ||
                !_hasVisibleText(message))) {
          processIndices.add(i);
        }
        continue;
      }
      if (message is ToolResultMessage &&
          message.images.isEmpty &&
          message.artifacts.isEmpty) {
        processIndices.add(i);
        toolResults++;
        continue;
      }
      if (message is ToolUseSummaryMessage) {
        processIndices.add(i);
        toolResults++;
      }
    }

    final finalCounts = finalAssistantIndex == null
        ? const (thinking: 0, tools: 0)
        : _assistantProcessCounts(
            (entries[finalAssistantIndex] as ServerChatEntry).message
                as AssistantServerMessage,
          );
    final hasInlineFinalProcess =
        finalCounts.thinking > 0 || finalCounts.tools > 0;
    if (processIndices.isNotEmpty || hasInlineFinalProcess) {
      final firstProcessIndex = processIndices.isEmpty
          ? finalAssistantIndex!
          : processIndices.reduce((left, right) => left < right ? left : right);
      final summaryIndex = finalAssistantIndex == null
          ? firstProcessIndex
          : firstProcessIndex < finalAssistantIndex
          ? firstProcessIndex
          : finalAssistantIndex;
      final layout = ChatProcessTurnLayout(
        key: turnKey,
        processEntryIndices: Set.unmodifiable(processIndices),
        summaryEntryIndex: summaryIndex,
        finalAssistantEntryIndex: hasInlineFinalProcess
            ? finalAssistantIndex
            : null,
        thinkingBlocks: thinkingBlocks,
        toolCalls: toolCalls,
        toolResults: toolResults,
      );
      for (final index in processIndices) {
        turnsByIndex[index] = layout;
      }
      turnsByIndex[summaryIndex] = layout;
      if (hasInlineFinalProcess) turnsByIndex[finalAssistantIndex!] = layout;
    }
    cursor = turnEnd;
  }

  return ChatProcessLayout(Map.unmodifiable(turnsByIndex), latestTurnKey);
}

String _turnKey(UserChatEntry entry) {
  final messageUuid = entry.messageUuid?.trim();
  if (messageUuid?.isNotEmpty == true) return 'uuid:$messageUuid';
  final clientId = entry.clientMessageId?.trim();
  if (clientId?.isNotEmpty == true) return 'client:$clientId';
  return 'time:${entry.timestamp.microsecondsSinceEpoch}:${entry.text.length}';
}

bool _hasVisibleText(AssistantServerMessage message) => message.message.content
    .whereType<TextContent>()
    .any((content) => content.text.trim().isNotEmpty);

({int thinking, int tools}) _assistantProcessCounts(
  AssistantServerMessage message,
) {
  var thinking = 0;
  var tools = 0;
  for (final content in message.message.content) {
    if (content is ThinkingContent && content.thinking.trim().isNotEmpty) {
      thinking++;
    } else if (content is ToolUseContent && content.name != 'ExitPlanMode') {
      tools++;
    }
  }
  return (thinking: thinking, tools: tools);
}
