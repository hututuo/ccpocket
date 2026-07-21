import '../../../models/messages.dart';

/// One independently collapsible reasoning/tool block associated with one
/// visible assistant update (or a process-only tail before output exists).
class ChatProcessSegmentLayout {
  const ChatProcessSegmentLayout({
    required this.key,
    required this.turnKey,
    required this.processEntryIndices,
    required this.summaryEntryIndex,
    required this.assistantEntryIndex,
    required this.thinkingBlocks,
    required this.toolCalls,
    required this.toolResults,
    required this.hasInlineAssistantProcess,
  });

  final String key;
  final String turnKey;
  final Set<int> processEntryIndices;
  final int summaryEntryIndex;
  final int? assistantEntryIndex;
  final int thinkingBlocks;
  final int toolCalls;
  final int toolResults;
  final bool hasInlineAssistantProcess;

  int get detailCount {
    final explicit = thinkingBlocks + toolCalls + toolResults;
    return explicit > 0 ? explicit : processEntryIndices.length;
  }

  bool isProcessEntry(int index) => processEntryIndices.contains(index);
  bool showsSummaryAt(int index) => summaryEntryIndex == index;
  bool hasInlineProcessAt(int index) =>
      assistantEntryIndex == index && hasInlineAssistantProcess;
}

/// The second-level disclosure for one user turn.
///
/// Intermediate visible assistant updates and their own process segments are
/// hidden together by default. The final assistant result and its process
/// segment remain outside this set.
class ChatProcessTurnLayout {
  const ChatProcessTurnLayout({
    required this.key,
    required this.segments,
    required this.intermediateEntryIndices,
    required this.intermediateAssistantEntryIndices,
    required this.intermediateSummaryEntryIndex,
    required this.finalAssistantEntryIndex,
  });

  final String key;
  final List<ChatProcessSegmentLayout> segments;
  final Set<int> intermediateEntryIndices;
  final Set<int> intermediateAssistantEntryIndices;
  final int? intermediateSummaryEntryIndex;
  final int? finalAssistantEntryIndex;

  int get intermediateOutputCount => intermediateAssistantEntryIndices.length;
  bool get hasIntermediateOutputs => intermediateOutputCount > 0;
  bool isIntermediateEntry(int index) =>
      intermediateEntryIndices.contains(index);
  bool showsIntermediateSummaryAt(int index) =>
      intermediateSummaryEntryIndex == index;
}

class ChatProcessLayout {
  const ChatProcessLayout(
    this._segmentsByEntryIndex,
    this._turnsByIntermediateEntryIndex,
    this.latestTurnKey,
  );

  final Map<int, ChatProcessSegmentLayout> _segmentsByEntryIndex;
  final Map<int, ChatProcessTurnLayout> _turnsByIntermediateEntryIndex;
  final String? latestTurnKey;

  ChatProcessSegmentLayout? segmentForEntry(int index) =>
      _segmentsByEntryIndex[index];
  ChatProcessTurnLayout? turnForEntry(int index) =>
      _turnsByIntermediateEntryIndex[index];
}

ChatProcessLayout buildChatProcessLayout(List<ChatEntry> entries) {
  final segmentsByIndex = <int, ChatProcessSegmentLayout>{};
  final turnsByIntermediateIndex = <int, ChatProcessTurnLayout>{};
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
    for (var index = turnStart + 1; index < turnEnd; index++) {
      if (entries[index] case ServerChatEntry(
        message: final AssistantServerMessage assistant,
      ) when _hasVisibleText(assistant)) {
        visibleAssistantIndices.add(index);
      }
    }

    final accumulators = visibleAssistantIndices.isEmpty
        ? [_SegmentAccumulator(assistantEntryIndex: null)]
        : visibleAssistantIndices
              .map(
                (index) => _SegmentAccumulator(assistantEntryIndex: index),
              )
              .toList();
    final visiblePositionByIndex = <int, int>{
      for (var position = 0;
          position < visibleAssistantIndices.length;
          position++)
        visibleAssistantIndices[position]: position,
    };
    final toolSegmentById = <String, int>{};

    int segmentForPosition(int entryIndex) {
      final exact = visiblePositionByIndex[entryIndex];
      if (exact != null) return exact;
      for (var position = 0;
          position < visibleAssistantIndices.length;
          position++) {
        if (entryIndex < visibleAssistantIndices[position]) return position;
      }
      return accumulators.length - 1;
    }

    // Tool results stay with the assistant block that issued the tool, even
    // when a later visible update appears before the result is rendered.
    for (var index = turnStart + 1; index < turnEnd; index++) {
      final entry = entries[index];
      if (entry is! ServerChatEntry ||
          entry.message is! AssistantServerMessage) {
        continue;
      }
      final segmentPosition = segmentForPosition(index);
      final assistant = entry.message as AssistantServerMessage;
      for (final content in assistant.message.content) {
        if (content is ToolUseContent && content.name != 'ExitPlanMode') {
          toolSegmentById[content.id] = segmentPosition;
        }
      }
    }

    for (var index = turnStart + 1; index < turnEnd; index++) {
      final entry = entries[index];
      if (entry is! ServerChatEntry) continue;
      final message = entry.message;
      if (message is AssistantServerMessage) {
        final segment = accumulators[segmentForPosition(index)];
        final counts = _assistantProcessCounts(message);
        segment.thinkingBlocks += counts.thinking;
        segment.toolCalls += counts.tools;
        if (_hasVisibleText(message)) {
          segment.inlineThinkingBlocks += counts.thinking;
          segment.inlineToolCalls += counts.tools;
        }
        if (!_hasVisibleText(message)) {
          segment.processEntryIndices.add(index);
        }
        continue;
      }
      if (message is ToolResultMessage &&
          message.images.isEmpty &&
          message.artifacts.isEmpty) {
        final segmentPosition =
            toolSegmentById[message.toolUseId] ?? segmentForPosition(index);
        final segment = accumulators[segmentPosition];
        segment.processEntryIndices.add(index);
        segment.toolResults++;
        continue;
      }
      if (message is ToolUseSummaryMessage) {
        final segment = accumulators[segmentForPosition(index)];
        segment.processEntryIndices.add(index);
        segment.toolResults++;
      }
    }

    final segments = <ChatProcessSegmentLayout>[];
    for (var position = 0; position < accumulators.length; position++) {
      final accumulator = accumulators[position];
      final hasInlineProcess =
          accumulator.assistantEntryIndex != null &&
          (accumulator.inlineThinkingBlocks > 0 ||
              accumulator.inlineToolCalls > 0);
      if (accumulator.processEntryIndices.isEmpty && !hasInlineProcess) {
        continue;
      }
      final summaryIndex = [
        ...accumulator.processEntryIndices,
        if (hasInlineProcess) accumulator.assistantEntryIndex!,
      ].reduce((left, right) => left < right ? left : right);
      final segment = ChatProcessSegmentLayout(
        key: '$turnKey:segment:${_segmentIdentity(entries, accumulator, position)}',
        turnKey: turnKey,
        processEntryIndices: Set.unmodifiable(
          accumulator.processEntryIndices,
        ),
        summaryEntryIndex: summaryIndex,
        assistantEntryIndex: accumulator.assistantEntryIndex,
        thinkingBlocks: accumulator.thinkingBlocks,
        toolCalls: accumulator.toolCalls,
        toolResults: accumulator.toolResults,
        hasInlineAssistantProcess: hasInlineProcess,
      );
      segments.add(segment);
      for (final index in segment.processEntryIndices) {
        segmentsByIndex[index] = segment;
      }
      segmentsByIndex[segment.summaryEntryIndex] = segment;
      if (hasInlineProcess) {
        segmentsByIndex[segment.assistantEntryIndex!] = segment;
      }
    }

    final finalAssistantIndex = visibleAssistantIndices.isEmpty
        ? null
        : visibleAssistantIndices.last;
    final intermediateAssistants = finalAssistantIndex == null
        ? const <int>{}
        : visibleAssistantIndices
              .where((index) => index != finalAssistantIndex)
              .toSet();
    final intermediateEntries = <int>{...intermediateAssistants};
    for (final segment in segments) {
      if (segment.assistantEntryIndex != null &&
          intermediateAssistants.contains(segment.assistantEntryIndex)) {
        intermediateEntries.addAll(segment.processEntryIndices);
      }
    }
    final intermediateSummaryIndex = intermediateEntries.isEmpty
        ? null
        : intermediateEntries.reduce(
            (left, right) => left < right ? left : right,
          );
    final turn = ChatProcessTurnLayout(
      key: turnKey,
      segments: List.unmodifiable(segments),
      intermediateEntryIndices: Set.unmodifiable(intermediateEntries),
      intermediateAssistantEntryIndices: Set.unmodifiable(
        intermediateAssistants,
      ),
      intermediateSummaryEntryIndex: intermediateSummaryIndex,
      finalAssistantEntryIndex: finalAssistantIndex,
    );
    for (final index in intermediateEntries) {
      turnsByIntermediateIndex[index] = turn;
    }
    cursor = turnEnd;
  }

  return ChatProcessLayout(
    Map.unmodifiable(segmentsByIndex),
    Map.unmodifiable(turnsByIntermediateIndex),
    latestTurnKey,
  );
}

class _SegmentAccumulator {
  _SegmentAccumulator({required this.assistantEntryIndex});

  final int? assistantEntryIndex;
  final Set<int> processEntryIndices = {};
  int thinkingBlocks = 0;
  int toolCalls = 0;
  int toolResults = 0;
  int inlineThinkingBlocks = 0;
  int inlineToolCalls = 0;
}

String _segmentIdentity(
  List<ChatEntry> entries,
  _SegmentAccumulator accumulator,
  int position,
) {
  final index = accumulator.assistantEntryIndex;
  if (index == null) return 'pending-$position';
  final entry = entries[index];
  if (entry case ServerChatEntry(
    message: AssistantServerMessage(:final messageUuid, :final message),
  )) {
    if (messageUuid?.trim().isNotEmpty == true) return 'uuid:$messageUuid';
    if (message.id.trim().isNotEmpty) return 'id:${message.id}';
  }
  return 'index:$index';
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
