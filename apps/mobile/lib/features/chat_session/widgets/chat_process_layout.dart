import '../../../models/messages.dart';
import '../../../utils/codex_plan_update.dart';

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
    this.guardianReview,
    this.guardianEntryIndex,
  });

  final String toolUseId;
  final String name;
  final Map<String, dynamic> input;
  final int entryIndex;
  final String? output;
  final bool completed;
  final GuardianApprovalMessage? guardianReview;
  final int? guardianEntryIndex;

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
      guardianReview: guardianReview,
      guardianEntryIndex: guardianEntryIndex,
    );
  }

  ChatProcessToolActivity reviewedBy(
    GuardianApprovalMessage review, {
    required int entryIndex,
  }) {
    return ChatProcessToolActivity(
      toolUseId: toolUseId,
      name: name,
      input: input,
      entryIndex: this.entryIndex,
      output: output,
      completed: completed,
      guardianReview: review,
      guardianEntryIndex: entryIndex,
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
    required this.attachedGuardianEntryIndices,
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
  final Set<int> attachedGuardianEntryIndices;
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
    required this.intermediateSegments,
    required this.intermediateDetailCount,
    required this.intermediateEntryIndices,
    required this.intermediateAssistantEntryIndices,
    required this.intermediateSummaryEntryIndex,
    required this.finalAssistantEntryIndex,
    required this.currentAssistantEntryIndex,
    required this.currentSegment,
    required this.isActive,
    required this.hasTransientCurrentOutput,
    required this.planUpdateEntryIndices,
    required this.planUpdateDisplayEntryIndex,
    required this.latestPlanUpdateInput,
    this.activeTool,
  });

  final String key;
  final List<ChatProcessSegmentLayout> segments;
  final List<ChatProcessSegmentLayout> intermediateSegments;
  final int intermediateDetailCount;
  final Set<int> intermediateEntryIndices;
  final Set<int> intermediateAssistantEntryIndices;
  final int? intermediateSummaryEntryIndex;
  final int? finalAssistantEntryIndex;
  final int? currentAssistantEntryIndex;
  final ChatProcessSegmentLayout? currentSegment;
  final bool isActive;
  final bool hasTransientCurrentOutput;
  final Set<int> planUpdateEntryIndices;
  final int? planUpdateDisplayEntryIndex;
  final Map<String, dynamic>? latestPlanUpdateInput;
  final ChatProcessToolActivity? activeTool;

  int get intermediateOutputCount => intermediateAssistantEntryIndices.length;

  bool get hasIntermediateEntries => intermediateEntryIndices.isNotEmpty;

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

  bool isPlanUpdateEntry(int index) => planUpdateEntryIndices.contains(index);

  bool showsPlanUpdateAt(int index) => planUpdateDisplayEntryIndex == index;

  ChatProcessToolActivity? get currentTool =>
      activeTool ?? currentSegment?.latestTool;
}

class ChatProcessLayout {
  const ChatProcessLayout(
    this._segmentsByEntryIndex,
    this._turnsByEntryIndex, {
    required this.latestTurnKey,
    this.latestTurn,
    this.turnKeyAliases = const {},
  });

  final Map<int, ChatProcessSegmentLayout> _segmentsByEntryIndex;
  final Map<int, ChatProcessTurnLayout> _turnsByEntryIndex;
  final String? latestTurnKey;
  final ChatProcessTurnLayout? latestTurn;
  final Map<String, String> turnKeyAliases;

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
  final turnKeyAliases = <String, String>{};
  String? latestTurnKey;
  ChatProcessTurnLayout? latestTurn;

  var cursor = 0;
  while (cursor < entries.length) {
    final turnStart = cursor;
    final userEntry = entries[turnStart] is UserChatEntry
        ? entries[turnStart] as UserChatEntry
        : null;
    final turnContentStart = userEntry == null ? turnStart : turnStart + 1;
    var turnEnd = turnContentStart;
    while (turnEnd < entries.length && entries[turnEnd] is! UserChatEntry) {
      turnEnd++;
    }

    // A bounded render window can begin in the middle of a tool-heavy turn,
    // after its UserChatEntry has already been paged out. Treat that leading
    // range as one partial turn so its thought/tool hierarchy keeps the same
    // two-level disclosure instead of falling back to independent bubbles.
    final partialTurnKey = _partialTurnKey(entries, turnContentStart, turnEnd);
    final turnKey = userEntry == null ? partialTurnKey : _turnKey(userEntry);
    if (userEntry != null &&
        partialTurnKey != 'partial:empty' &&
        partialTurnKey != turnKey) {
      turnKeyAliases[partialTurnKey] = turnKey;
    }
    final isLatestTurn = turnEnd == entries.length;
    final isActive = isLatestTurn && latestTurnIsActive;
    final usesTransientCurrentOutput = isActive && hasTransientCurrentOutput;
    latestTurnKey = turnKey;

    final visibleAssistantIndices = <int>[];
    final planUpdateEntryIndices = <int>{};
    Map<String, dynamic>? latestPlanUpdateInput;
    int? planUpdateDisplayEntryIndex;
    for (var index = turnContentStart; index < turnEnd; index++) {
      final entry = entries[index];
      if (entry case ServerChatEntry(
        message: final AssistantServerMessage assistant,
      )) {
        final planInput = _planOnlyUpdateInput(assistant);
        if (planInput != null) {
          planUpdateEntryIndices.add(index);
          planUpdateDisplayEntryIndex = index;
          latestPlanUpdateInput = planInput;
        } else if (_hasVisibleText(assistant)) {
          visibleAssistantIndices.add(index);
        }
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
    final toolActivityById = <String, ChatProcessToolActivity>{};
    final activeToolById = <String, ChatProcessToolActivity>{};
    final activeToolOrder = <String>[];
    final planToolUseIds = <String>{};

    void markToolStarted(
      _SegmentAccumulator accumulator,
      ToolUseContent tool,
      int entryIndex,
    ) {
      if (tool.name == 'ExitPlanMode' || isCodexUpdatePlanTool(tool.name)) {
        return;
      }
      final activity = ChatProcessToolActivity(
        toolUseId: tool.id,
        name: tool.name,
        input: tool.input,
        entryIndex: entryIndex,
      );
      accumulator.toolCalls++;
      accumulator.latestTool = activity;
      toolAccumulatorById[tool.id] = accumulator;
      toolActivityById[tool.id] = activity;
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
      var hasProcess = false;
      for (final content in assistant.message.content) {
        if (content is ThinkingContent && content.thinking.trim().isNotEmpty) {
          accumulator.thinkingBlocks++;
          if (visible) accumulator.inlineThinkingBlocks++;
          hasProcess = true;
        } else if (content is ToolUseContent &&
            content.name != 'ExitPlanMode' &&
            !isCodexUpdatePlanTool(content.name)) {
          if (visible) accumulator.inlineToolCalls++;
          markToolStarted(accumulator, content, entryIndex);
          hasProcess = true;
        } else if (content is ToolUseContent &&
            isCodexUpdatePlanTool(content.name)) {
          planToolUseIds.add(content.id);
        }
      }
      for (final gap in assistant.historyToolDetailGaps) {
        if (gap.toolCallCount <= 0) continue;
        accumulator.toolCalls += gap.toolCallCount;
        if (visible) accumulator.inlineToolCalls += gap.toolCallCount;
        hasProcess = true;
      }
      if (visible || hasProcess) accumulator.noteEntry(entryIndex);
      if (!visible && hasProcess) {
        accumulator.processEntryIndices.add(entryIndex);
      }
    }

    for (var index = turnContentStart; index < turnEnd; index++) {
      final entry = entries[index];
      if (entry is! ServerChatEntry) continue;
      final message = entry.message;

      if (message is AssistantServerMessage) {
        final isVisible =
            !planUpdateEntryIndices.contains(index) && _hasVisibleText(message);
        if (isVisible) {
          activeAccumulator = accumulatorByAssistantIndex[index]!;
        }
        noteAssistant(activeAccumulator, message, index, visible: isVisible);
        continue;
      }

      if (message is ToolResultMessage) {
        if (planToolUseIds.contains(message.toolUseId)) {
          planUpdateEntryIndices.add(index);
          continue;
        }
        final accumulator =
            toolAccumulatorById[message.toolUseId] ?? activeAccumulator;
        accumulator.noteEntry(index);
        accumulator.processEntryIndices.add(index);
        accumulator.toolResults++;
        final prior =
            toolActivityById[message.toolUseId] ??
            activeToolById.remove(message.toolUseId);
        activeToolById.remove(message.toolUseId);
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
        toolActivityById[message.toolUseId] = activity;
        accumulator.latestTool = activity;
        continue;
      }

      if (message is GuardianApprovalMessage) {
        final targetItemId = message.targetItemId?.trim();
        final target = targetItemId?.isNotEmpty == true ? targetItemId : null;
        final accumulator = target == null
            ? activeAccumulator
            : (toolAccumulatorById[target] ?? activeAccumulator);
        accumulator.noteEntry(index);
        accumulator.processEntryIndices.add(index);

        final prior = target == null
            ? accumulator.latestTool
            : toolActivityById[target];
        if (prior != null) {
          final reviewed = prior.reviewedBy(message, entryIndex: index);
          toolActivityById[prior.toolUseId] = reviewed;
          if (activeToolById.containsKey(prior.toolUseId)) {
            activeToolById[prior.toolUseId] = reviewed;
          }
          accumulator.latestTool = reviewed;
          accumulator.attachedGuardianEntryIndices.add(index);
        }
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
        attachedGuardianEntryIndices: Set.unmodifiable(
          accumulator.attachedGuardianEntryIndices,
        ),
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
      for (var index = turnContentStart; index < intervalEnd; index++) {
        if (!planUpdateEntryIndices.contains(index)) {
          intermediateEntries.add(index);
        }
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
      intermediateEntries.removeAll(planUpdateEntryIndices);
    }

    final intermediateSummaryIndex = intermediateEntries.isEmpty
        ? null
        : intermediateEntries.reduce(
            (left, right) => left < right ? left : right,
          );
    final intermediateDetailCount = intermediateSegments.fold<int>(
      0,
      (count, segment) => count + segment.detailCount,
    );
    final turn = ChatProcessTurnLayout(
      key: turnKey,
      segments: List.unmodifiable(segments),
      intermediateSegments: List.unmodifiable(intermediateSegments),
      intermediateDetailCount: intermediateDetailCount,
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
      planUpdateEntryIndices: Set.unmodifiable(planUpdateEntryIndices),
      planUpdateDisplayEntryIndex: planUpdateDisplayEntryIndex,
      latestPlanUpdateInput: latestPlanUpdateInput == null
          ? null
          : Map.unmodifiable(latestPlanUpdateInput),
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
    for (final index in planUpdateEntryIndices) {
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
    turnKeyAliases: Map.unmodifiable(turnKeyAliases),
  );
}

class _SegmentAccumulator {
  _SegmentAccumulator({required this.assistantEntryIndex});

  final int? assistantEntryIndex;
  final Set<int> processEntryIndices = <int>{};
  final Set<int> attachedGuardianEntryIndices = <int>{};
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
    final firstIndex = accumulator.firstEntryIndex;
    if (firstIndex != null && firstIndex >= 0 && firstIndex < entries.length) {
      return 'leading:${_processEntryIdentity(entries[firstIndex])}';
    }
    return 'leading:empty:$position';
  }
  return _processEntryIdentity(entries[index]);
}

String _turnKey(UserChatEntry entry) {
  final providerItemId = entry.providerItemId?.trim();
  if (providerItemId?.isNotEmpty == true) {
    return 'provider:$providerItemId';
  }
  final messageUuid = entry.messageUuid?.trim();
  if (messageUuid?.isNotEmpty == true) return 'uuid:$messageUuid';
  final clientId = entry.clientMessageId?.trim();
  if (clientId?.isNotEmpty == true) return 'client:$clientId';
  return 'time:${entry.timestamp.microsecondsSinceEpoch}:${entry.text.length}';
}

String _partialTurnKey(List<ChatEntry> entries, int start, int end) {
  for (var index = start; index < end; index++) {
    final entry = entries[index];
    if (entry is! ServerChatEntry) continue;
    final message = entry.message;
    if (message is AssistantServerMessage) {
      final messageUuid = message.messageUuid?.trim();
      if (messageUuid?.isNotEmpty == true) {
        return 'partial:uuid:$messageUuid';
      }
      final messageId = message.message.id.trim();
      if (messageId.isNotEmpty) return 'partial:id:$messageId';
    }
    if (message is ToolResultMessage) {
      final toolUseId = message.toolUseId.trim();
      if (toolUseId.isNotEmpty) return 'partial:tool:$toolUseId';
    }
    if (message is ToolUseSummaryMessage &&
        message.precedingToolUseIds.isNotEmpty) {
      return 'partial:tool:${message.precedingToolUseIds.first}';
    }
  }
  final timestamp = start < entries.length
      ? _processEntryIdentity(entries[start])
      : 'empty';
  return 'partial:$timestamp';
}

String _processEntryIdentity(ChatEntry entry) {
  if (entry is UserChatEntry) return _turnKey(entry);
  if (entry is StreamingChatEntry) return 'streaming';
  final message = (entry as ServerChatEntry).message;
  return switch (message) {
    AssistantServerMessage(:final messageUuid, :final message) =>
      _assistantProcessIdentity(messageUuid, message, entry.timestamp),
    ToolResultMessage(:final toolUseId) =>
      toolUseId.trim().isNotEmpty
          ? 'tool-result:${toolUseId.trim()}'
          : 'tool-result:${entry.timestamp.microsecondsSinceEpoch}',
    PermissionRequestMessage(:final toolUseId) =>
      toolUseId.trim().isNotEmpty
          ? 'permission:${toolUseId.trim()}'
          : 'permission:${entry.timestamp.microsecondsSinceEpoch}',
    ToolUseSummaryMessage(:final precedingToolUseIds, :final summary) =>
      precedingToolUseIds.isNotEmpty
          ? 'tool-summary:${precedingToolUseIds.first}'
          : 'tool-summary:${_stableFingerprint(_boundedIdentityText(summary))}',
    _ => '${message.runtimeType}:${entry.timestamp.microsecondsSinceEpoch}',
  };
}

String _assistantProcessIdentity(
  String? messageUuid,
  AssistantMessage message,
  DateTime timestamp,
) {
  final uuid = messageUuid?.trim();
  if (uuid?.isNotEmpty == true) return 'uuid:$uuid';
  final messageId = message.id.trim();
  if (messageId.isNotEmpty) return 'id:$messageId';
  for (final content in message.content) {
    if (content case ToolUseContent(:final id) when id.trim().isNotEmpty) {
      return 'tool:${id.trim()}';
    }
  }
  final signature = message.content
      .map(
        (content) => switch (content) {
          TextContent(:final text) => 'text:${_boundedIdentityText(text)}',
          ThinkingContent(:final thinking) =>
            'thinking:${_boundedIdentityText(thinking)}',
          ToolUseContent(:final name, :final input) =>
            'tool:$name:${input.keys.join(',')}',
        },
      )
      .join('|');
  if (signature.isNotEmpty) {
    return 'content:${_stableFingerprint(signature)}';
  }
  return 'time:${timestamp.microsecondsSinceEpoch}';
}

String _boundedIdentityText(String value) {
  const edgeLength = 128;
  if (value.length <= edgeLength * 2) return value;
  return '${value.substring(0, edgeLength)}'
      ':${value.length}:'
      '${value.substring(value.length - edgeLength)}';
}

String _stableFingerprint(String value) {
  var hash = 0x811c9dc5;
  for (final unit in value.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

bool _hasVisibleText(AssistantServerMessage message) => message.message.content
    .whereType<TextContent>()
    .any((content) => content.text.trim().isNotEmpty);

Map<String, dynamic>? _planOnlyUpdateInput(AssistantServerMessage message) {
  Map<String, dynamic>? planInput;
  var hasOtherContent = false;
  for (final content in message.message.content) {
    switch (content) {
      case ToolUseContent(:final name, :final input):
        if (isCodexUpdatePlanTool(name)) {
          planInput = input;
        } else {
          hasOtherContent = true;
        }
      case TextContent(:final text):
        if (text.trim().isEmpty) continue;
        final legacyInput = codexPlanUpdateInputFromText(text);
        if (legacyInput == null) {
          hasOtherContent = true;
        } else {
          planInput = legacyInput;
        }
      case ThinkingContent(:final thinking):
        if (thinking.trim().isNotEmpty) hasOtherContent = true;
    }
  }
  return hasOtherContent ? null : planInput;
}
