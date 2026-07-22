import '../../../models/messages.dart';

/// A single tool invocation as represented by the public Bridge protocol.
///
/// This deliberately retains the generic name/input/output shape instead of
/// hard-coding the current Codex tool list. New app-server tools can therefore
/// appear in the mobile transcript as soon as Bridge can forward them.
class ChatProcessToolActivity {
  const ChatProcessToolActivity({
    required this.toolUseId,
    required this.name,
    required this.input,
    required this.entryIndex,
    this.output,
    this.completed = false,
  });

  final String toolUseId;
  final String name;
  final Map<String, dynamic> input;
  final int entryIndex;
  final String? output;
  final bool completed;

  ChatProcessToolActivity completedWith({
    required String output,
    required int entryIndex,
    String? name,
  }) {
    return ChatProcessToolActivity(
      toolUseId: toolUseId,
      name: name ?? this.name,
      input: input,
      entryIndex: entryIndex,
      output: output,
      completed: true,
    );
  }
}

/// One assistant-output interval and the thought/tool activity attached to it.
///
/// An interval starts at a visible assistant update and ends immediately before
/// the next visible assistant update. Tool results are additionally linked by
/// tool-use id, so a delayed result stays with the update that issued it.
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
    required this.firstEntryIndex,
    required this.lastEntryIndex,
    this.latestTool,
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
  final int firstEntryIndex;
  final int lastEntryIndex;
  final ChatProcessToolActivity? latestTool;

  int get detailCount {
    final explicit = thinkingBlocks + toolCalls + toolResults;
    return explicit > 0 ? explicit : processEntryIndices.length;
  }

  bool isProcessEntry(int index) => processEntryIndices.contains(index);

  bool showsSummaryAt(int index) => summaryEntryIndex == index;

  bool hasInlineProcessAt(int index) =>
      assistantEntryIndex == index && hasInlineAssistantProcess;

  bool containsEntry(int index) =>
      assistantEntryIndex == index || processEntryIndices.contains(index);
}

/// Layout for one user turn.
///
/// Historical assistant updates and all of their thought/tool activity are
/// represented by [intermediateEntryIndices]. During an active turn, exactly
/// one latest interval is kept outside that fold as [currentSegment]. A live
/// stream without a persisted assistant item keeps [currentSegment] null and
/// is rendered by the dedicated transient progress surface instead.
class ChatProcessTurnLayout {
  const ChatProcessTurnLayout({
    required this.key,
    required this.segments,
    required this.intermediateEntryIndices,
    required this.intermediateAssistantEntryIndices,
    required this.intermediateSummaryEntryIndex,
    required this.finalAssistantEntryIndex,
    required this.currentAssistantEntryIndex,
    required this.currentSegment,
    required this.isActive,
    required this.hasTransientCurrentOutput,
    this.activeTool,
  });

  final String key;
  final List<ChatProcessSegmentLayout> segments;
  final Set<int> intermediateEntryIndices;
  final Set<int> intermediateAssistantEntryIndices;
  final int? intermediateSummaryEntryIndex;
  final int? finalAssistantEntryIndex;
  final int? currentAssistantEntryIndex;
  final ChatProcessSegmentLayout? currentSegment;
  final bool isActive;
  final bool hasTransientCurrentOutput;
  final ChatProcessToolActivity? activeTool;

  int get intermediateOutputCount => intermediateAssistantEntryIndices.length;

  int get intermediateDetailCount => segments
      .where(
        (segment) =>
            (segment.assistantEntryIndex != null &&
                intermediateEntryIndices.contains(
                  segment.assistantEntryIndex,
                )) ||
            segment.processEntryIndices.any(intermediateEntryIndices.contains),
      )
      .fold<int>(0, (count, segment) => count + segment.detailCount);

  bool get hasIntermediateEntries => intermediateEntryIndices.isNotEmpty;

  List<ChatProcessSegmentLayout> get intermediateSegments => segments
      .where(
        (segment) =>
            (segment.assistantEntryIndex != null &&
                intermediateAssistantEntryIndices.contains(
                  segment.assistantEntryIndex,
                )) ||
            segment.processEntryIndices.any(intermediateEntryIndices.contains),
      )
      .toList(growable: false);

  ChatProcessSegmentLayout? segmentForIntermediateEntry(int index) {
    for (final segment in intermediateSegments) {
      if (segment.containsEntry(index)) return segment;
    }
    return null;
  }

  bool isIntermediateEntry(int index) =>
      intermediateEntryIndices.contains(index);

  bool showsIntermediateSummaryAt(int index) =>
      intermediateSummaryEntryIndex == index;

  bool isCurrentAssistantEntry(int index) =>
      currentAssistantEntryIndex == index;

  bool isCurrentProcessEntry(int index) =>
      currentSegment?.isProcessEntry(index) == true;

  ChatProcessToolActivity? get currentTool =>
      activeTool ?? currentSegment?.latestTool;
}

class ChatProcessLayout {
  const ChatProcessLayout(
    this._segmentsByEntryIndex,
    this._turnsByEntryIndex, {
    required this.latestTurnKey,
    this.latestTurn,
  });

  final Map<int, ChatProcessSegmentLayout> _segmentsByEntryIndex;
  final Map<int, ChatProcessTurnLayout> _turnsByEntryIndex;
  final String? latestTurnKey;
  final ChatProcessTurnLayout? latestTurn;

  ChatProcessSegmentLayout? segmentForEntry(int index) =>
      _segmentsByEntryIndex[index];

  ChatProcessTurnLayout? turnForEntry(int index) => _turnsByEntryIndex[index];
}

/// Builds a display-only process layout from the existing chat entries.
///
/// [latestTurnIsActive] is passed by the session surface rather than inferred
/// from a message shape: Desktop-owned turns and pending approvals can be
/// running even before a stream delta reaches the phone. [hasTransientCurrentOutput]
/// is true when the fast streaming surface contains the newest unfinished
/// assistant text or reasoning.
ChatProcessLayout buildChatProcessLayout(
  List<ChatEntry> entries, {
  bool latestTurnIsActive = false,
  bool hasTransientCurrentOutput = false,
}) {
  final segmentsByIndex = <int, ChatProcessSegmentLayout>{};
  final turnsByIndex = <int, ChatProcessTurnLayout>{};
  String? latestTurnKey;
  ChatProcessTurnLayout? latestTurn;

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
    final isLatestTurn = turnEnd == entries.length;
    final isActive = isLatestTurn && latestTurnIsActive;
    final usesTransientCurrentOutput = isActive && hasTransientCurrentOutput;
    latestTurnKey = turnKey;

    final visibleAssistantIndices = <int>[];
    for (var index = turnStart + 1; index < turnEnd; index++) {
      final entry = entries[index];
      if (entry case ServerChatEntry(
        message: final AssistantServerMessage assistant,
      ) when _hasVisibleText(assistant)) {
        visibleAssistantIndices.add(index);
      }
    }

    final accumulators = <_SegmentAccumulator>[
      _SegmentAccumulator(assistantEntryIndex: null),
    ];
    final accumulatorByAssistantIndex = <int, _SegmentAccumulator>{};
    for (final index in visibleAssistantIndices) {
      final accumulator = _SegmentAccumulator(assistantEntryIndex: index);
      accumulators.add(accumulator);
      accumulatorByAssistantIndex[index] = accumulator;
    }

    var activeAccumulator = accumulators.first;
    final toolAccumulatorById = <String, _SegmentAccumulator>{};
    final activeToolById = <String, ChatProcessToolActivity>{};
    final activeToolOrder = <String>[];

    void markToolStarted(
      _SegmentAccumulator accumulator,
      ToolUseContent tool,
      int entryIndex,
    ) {
      if (tool.name == 'ExitPlanMode') return;
      final activity = ChatProcessToolActivity(
        toolUseId: tool.id,
        name: tool.name,
        input: tool.input,
        entryIndex: entryIndex,
      );
      accumulator.toolCalls++;
      accumulator.latestTool = activity;
      toolAccumulatorById[tool.id] = accumulator;
      activeToolById[tool.id] = activity;
      activeToolOrder.remove(tool.id);
      activeToolOrder.add(tool.id);
    }

    void noteAssistant(
      _SegmentAccumulator accumulator,
      AssistantServerMessage assistant,
      int entryIndex, {
      required bool visible,
    }) {
      accumulator.noteEntry(entryIndex);
      var hasProcess = false;
      for (final content in assistant.message.content) {
        if (content is ThinkingContent && content.thinking.trim().isNotEmpty) {
          accumulator.thinkingBlocks++;
          if (visible) accumulator.inlineThinkingBlocks++;
          hasProcess = true;
        } else if (content is ToolUseContent &&
            content.name != 'ExitPlanMode') {
          if (visible) accumulator.inlineToolCalls++;
          markToolStarted(accumulator, content, entryIndex);
          hasProcess = true;
        }
      }
      if (!visible && hasProcess) {
        accumulator.processEntryIndices.add(entryIndex);
      }
    }

    for (var index = turnStart + 1; index < turnEnd; index++) {
      final entry = entries[index];
      if (entry is! ServerChatEntry) continue;
      final message = entry.message;

      if (message is AssistantServerMessage) {
        final isVisible = _hasVisibleText(message);
        if (isVisible) {
          activeAccumulator = accumulatorByAssistantIndex[index]!;
        }
        noteAssistant(activeAccumulator, message, index, visible: isVisible);
        continue;
      }

      if (message is ToolResultMessage) {
        final accumulator =
            toolAccumulatorById[message.toolUseId] ?? activeAccumulator;
        accumulator.noteEntry(index);
        accumulator.processEntryIndices.add(index);
        accumulator.toolResults++;
        final prior = activeToolById.remove(message.toolUseId);
        activeToolOrder.remove(message.toolUseId);
        final activity =
            (prior ??
                    ChatProcessToolActivity(
                      toolUseId: message.toolUseId,
                      name: message.toolName?.trim().isNotEmpty == true
                          ? message.toolName!.trim()
                          : 'Tool',
                      input: const <String, dynamic>{},
                      entryIndex: index,
                    ))
                .completedWith(
                  output: message.content,
                  entryIndex: index,
                  name: message.toolName?.trim().isNotEmpty == true
                      ? message.toolName!.trim()
                      : null,
                );
        accumulator.latestTool = activity;
        continue;
      }

      if (message is ToolUseSummaryMessage) {
        activeAccumulator.noteEntry(index);
        activeAccumulator.processEntryIndices.add(index);
        activeAccumulator.toolResults++;
        activeAccumulator.latestTool = ChatProcessToolActivity(
          toolUseId: 'summary:$index',
          name: 'Subagent',
          input: const <String, dynamic>{},
          output: message.summary,
          completed: true,
          entryIndex: index,
        );
      }
    }

    final segments = <ChatProcessSegmentLayout>[];
    for (var position = 0; position < accumulators.length; position++) {
      final accumulator = accumulators[position];
      if (!accumulator.hasEntries) continue;
      final hasInlineProcess =
          accumulator.assistantEntryIndex != null &&
          (accumulator.inlineThinkingBlocks > 0 ||
              accumulator.inlineToolCalls > 0);
      final summaryEntryIndex =
          accumulator.assistantEntryIndex ?? accumulator.firstEntryIndex!;
      final segment = ChatProcessSegmentLayout(
        key:
            '$turnKey:segment:${_segmentIdentity(entries, accumulator, position)}',
        turnKey: turnKey,
        processEntryIndices: Set.unmodifiable(accumulator.processEntryIndices),
        summaryEntryIndex: summaryEntryIndex,
        assistantEntryIndex: accumulator.assistantEntryIndex,
        thinkingBlocks: accumulator.thinkingBlocks,
        toolCalls: accumulator.toolCalls,
        toolResults: accumulator.toolResults,
        hasInlineAssistantProcess: hasInlineProcess,
        firstEntryIndex: accumulator.firstEntryIndex!,
        lastEntryIndex: accumulator.lastEntryIndex!,
        latestTool: accumulator.latestTool,
      );
      segments.add(segment);
      if (segment.assistantEntryIndex case final assistantIndex?) {
        segmentsByIndex[assistantIndex] = segment;
      }
      for (final index in segment.processEntryIndices) {
        segmentsByIndex[index] = segment;
      }
    }

    ChatProcessSegmentLayout? segmentForAssistant(int? assistantIndex) {
      if (assistantIndex == null) return null;
      for (final segment in segments) {
        if (segment.assistantEntryIndex == assistantIndex) return segment;
      }
      return null;
    }

    ChatProcessToolActivity? activeTool;
    if (activeToolOrder.isNotEmpty) {
      activeTool = activeToolById[activeToolOrder.last];
    }
    ChatProcessSegmentLayout? currentSegment;
    int? currentAssistantEntryIndex;
    if (isActive) {
      if (!usesTransientCurrentOutput) {
        final lastVisible = visibleAssistantIndices.isEmpty
            ? null
            : visibleAssistantIndices.last;
        currentSegment = segmentForAssistant(lastVisible);
        if (currentSegment == null && segments.isNotEmpty) {
          currentSegment = segments.last;
        }
      }
      currentAssistantEntryIndex = currentSegment?.assistantEntryIndex;
    }

    final finalAssistantIndex = visibleAssistantIndices.isEmpty
        ? null
        : visibleAssistantIndices.last;
    final finalSegment = segmentForAssistant(finalAssistantIndex);
    final protectedSegment = isActive ? currentSegment : finalSegment;

    final intermediateSegments = <ChatProcessSegmentLayout>[];
    final intermediateAssistants = <int>{};
    for (final segment in segments) {
      if (identical(segment, protectedSegment)) continue;
      intermediateSegments.add(segment);
      if (segment.assistantEntryIndex case final assistantIndex?) {
        intermediateAssistants.add(assistantIndex);
      }
    }

    // The outer disclosure owns one contiguous historical interval. Keeping
    // every entry in that interval under the same parent preserves transcript
    // order for status/permission/system items that may sit between visible
    // assistant updates instead of leaving them as unrelated ListView rows.
    final intermediateEntries = <int>{};
    if (intermediateSegments.isNotEmpty) {
      final intervalEnd = protectedSegment?.firstEntryIndex ?? turnEnd;
      for (var index = turnStart + 1; index < intervalEnd; index++) {
        intermediateEntries.add(index);
      }
      // A tool can finish after the next visible assistant update. Its result
      // still belongs to the segment that started it, so keep every explicit
      // process entry owned by a historical segment inside that segment's
      // disclosure even when the raw event index crosses the interval end.
      for (final segment in intermediateSegments) {
        if (segment.assistantEntryIndex case final assistantIndex?) {
          intermediateEntries.add(assistantIndex);
        }
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
      currentAssistantEntryIndex: currentAssistantEntryIndex,
      currentSegment: currentSegment,
      isActive: isActive,
      hasTransientCurrentOutput: usesTransientCurrentOutput,
      activeTool: activeTool,
    );

    for (final segment in segments) {
      if (segment.assistantEntryIndex case final assistantIndex?) {
        turnsByIndex[assistantIndex] = turn;
      }
      for (final index in segment.processEntryIndices) {
        turnsByIndex[index] = turn;
      }
    }
    for (final index in intermediateEntries) {
      turnsByIndex[index] = turn;
    }
    if (isLatestTurn) latestTurn = turn;
    cursor = turnEnd;
  }

  return ChatProcessLayout(
    Map.unmodifiable(segmentsByIndex),
    Map.unmodifiable(turnsByIndex),
    latestTurnKey: latestTurnKey,
    latestTurn: latestTurn,
  );
}

class _SegmentAccumulator {
  _SegmentAccumulator({required this.assistantEntryIndex});

  final int? assistantEntryIndex;
  final Set<int> processEntryIndices = <int>{};
  int thinkingBlocks = 0;
  int toolCalls = 0;
  int toolResults = 0;
  int inlineThinkingBlocks = 0;
  int inlineToolCalls = 0;
  int? firstEntryIndex;
  int? lastEntryIndex;
  ChatProcessToolActivity? latestTool;

  bool get hasEntries => firstEntryIndex != null;

  void noteEntry(int index) {
    firstEntryIndex ??= index;
    lastEntryIndex = index;
  }
}

String _segmentIdentity(
  List<ChatEntry> entries,
  _SegmentAccumulator accumulator,
  int position,
) {
  final index = accumulator.assistantEntryIndex;
  if (index == null) {
    return 'leading:${accumulator.firstEntryIndex ?? position}';
  }
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
