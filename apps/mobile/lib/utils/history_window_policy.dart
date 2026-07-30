import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/messages.dart';

const turnAwareHistoryRootTurns = 5;
const turnAwareHistoryToolCalls = 200;
const turnAwareHistoryEnvelopeEntries = 300;
const turnAwareHistoryMaxRetainedEntries = 755;
const turnAwareHistoryGapToolIds = 200;

class TurnAwareServerMessageProjection {
  const TurnAwareServerMessageProjection({
    required this.message,
    required this.sourceIndex,
  });

  final ServerMessage message;
  final int sourceIndex;
}

List<ServerMessage> selectTurnAwareServerMessageWindow(
  List<ServerMessage> messages, {
  int rootTurns = turnAwareHistoryRootTurns,
  int toolCalls = turnAwareHistoryToolCalls,
  int envelopeEntries = turnAwareHistoryEnvelopeEntries,
  int maxRetainedEntries = turnAwareHistoryMaxRetainedEntries,
}) => [
  for (final value in projectTurnAwareServerMessageWindow(
    messages,
    rootTurns: rootTurns,
    toolCalls: toolCalls,
    envelopeEntries: envelopeEntries,
    maxRetainedEntries: maxRetainedEntries,
  ))
    value.message,
];

List<TurnAwareServerMessageProjection> projectTurnAwareServerMessageWindow(
  List<ServerMessage> messages, {
  int rootTurns = turnAwareHistoryRootTurns,
  int toolCalls = turnAwareHistoryToolCalls,
  int envelopeEntries = turnAwareHistoryEnvelopeEntries,
  int maxRetainedEntries = turnAwareHistoryMaxRetainedEntries,
}) {
  if (messages.isEmpty || maxRetainedEntries <= 0) return const [];
  final normalizedRootTurns = rootTurns < 0
      ? turnAwareHistoryRootTurns
      : rootTurns;
  final normalizedToolCalls = toolCalls < 0
      ? turnAwareHistoryToolCalls
      : toolCalls;
  final normalizedEnvelopeEntries = envelopeEntries < 0
      ? turnAwareHistoryEnvelopeEntries
      : envelopeEntries;
  final effectiveRootTurns = normalizedRootTurns
      .clamp(0, maxRetainedEntries)
      .toInt();
  final start = _startOfLatestRootTurns(
    messages,
    rootTurns: effectiveRootTurns,
    isRootTurn: (message) => message is UserInputMessage,
  );
  final retainedToolIds = _newestConcreteToolIds(
    messages,
    start,
    normalizedToolCalls,
  );
  final ordinaryIndexes = _newestOrdinaryEnvelopeIndexes(
    messages,
    start,
    normalizedEnvelopeEntries,
  );
  final projected = _projectMessages(
    messages,
    start,
    retainedToolIds,
    ordinaryIndexes,
  );
  for (final value in projected) {
    final source = messages[value.sourceIndex];
    if (identical(source, value.message) ||
        serverMessageTimestamp(value.message) != null) {
      continue;
    }
    final timestamp = serverMessageTimestamp(source);
    if (timestamp != null) {
      attachServerMessageTimestamp(
        value.message,
        value: timestamp.value,
        isAuthoritative: timestamp.isAuthoritative,
      );
    }
  }
  if (projected.length <= maxRetainedEntries) {
    return List.unmodifiable(projected);
  }
  final retainedIndexes = _hardCapProjectedMessages(
    projected,
    maxRetainedEntries,
  );
  return List.unmodifiable([
    for (final index in retainedIndexes) projected[index],
  ]);
}

List<int> selectTurnAwareServerMessageWindowIndexes(
  List<ServerMessage> messages, {
  int rootTurns = turnAwareHistoryRootTurns,
  int toolCalls = turnAwareHistoryToolCalls,
  int envelopeEntries = turnAwareHistoryEnvelopeEntries,
  int maxRetainedEntries = turnAwareHistoryMaxRetainedEntries,
}) => [
  for (final value in projectTurnAwareServerMessageWindow(
    messages,
    rootTurns: rootTurns,
    toolCalls: toolCalls,
    envelopeEntries: envelopeEntries,
    maxRetainedEntries: maxRetainedEntries,
  ))
    value.sourceIndex,
];

List<ChatEntry> selectTurnAwareChatEntryWindow(
  List<ChatEntry> entries, {
  int rootTurns = turnAwareHistoryRootTurns,
  int toolCalls = turnAwareHistoryToolCalls,
  int envelopeEntries = turnAwareHistoryEnvelopeEntries,
  int maxRetainedEntries = turnAwareHistoryMaxRetainedEntries,
}) {
  final messages = <ServerMessage>[
    for (var index = 0; index < entries.length; index++)
      switch (entries[index]) {
        ServerChatEntry(:final message) => message,
        UserChatEntry(:final text) => UserInputMessage(text: text),
        StreamingChatEntry(:final text) => AssistantServerMessage(
          message: AssistantMessage(
            id: 'streaming-window-$index',
            role: 'assistant',
            content: [TextContent(text: text)],
            model: '',
          ),
        ),
      },
  ];
  return [
    for (final value in projectTurnAwareServerMessageWindow(
      messages,
      rootTurns: rootTurns,
      toolCalls: toolCalls,
      envelopeEntries: envelopeEntries,
      maxRetainedEntries: maxRetainedEntries,
    ))
      switch (entries[value.sourceIndex]) {
        final ServerChatEntry entry => ServerChatEntry(
          value.message,
          timestamp: entry.timestamp,
          timestampIsAuthoritative: entry.timestampIsAuthoritative,
        ),
        final UserChatEntry entry => entry,
        final StreamingChatEntry entry => entry,
      },
  ];
}

List<int> selectTurnAwareChatEntryWindowIndexes(
  List<ChatEntry> entries, {
  int rootTurns = turnAwareHistoryRootTurns,
  int toolCalls = turnAwareHistoryToolCalls,
  int envelopeEntries = turnAwareHistoryEnvelopeEntries,
  int maxRetainedEntries = turnAwareHistoryMaxRetainedEntries,
}) {
  final messages = [
    for (var index = 0; index < entries.length; index++)
      switch (entries[index]) {
        ServerChatEntry(:final message) => message,
        UserChatEntry(:final text) => UserInputMessage(text: text),
        StreamingChatEntry(:final text) => AssistantServerMessage(
          message: AssistantMessage(
            id: 'streaming-window-$index',
            role: 'assistant',
            content: [TextContent(text: text)],
            model: '',
          ),
        ),
      },
  ];
  return selectTurnAwareServerMessageWindowIndexes(
    messages,
    rootTurns: rootTurns,
    toolCalls: toolCalls,
    envelopeEntries: envelopeEntries,
    maxRetainedEntries: maxRetainedEntries,
  );
}

Set<String> _newestConcreteToolIds(
  List<ServerMessage> messages,
  int start,
  int limit,
) {
  final selected = <String>{};
  if (limit <= 0) return selected;
  for (var index = messages.length - 1; index >= start; index--) {
    final ids = _concreteToolIdsForMessage(messages[index]);
    for (var position = ids.length - 1; position >= 0; position--) {
      final id = ids[position];
      if (selected.contains(id)) continue;
      if (selected.length >= limit) return selected;
      selected.add(id);
    }
  }
  return selected;
}

Set<int> _newestOrdinaryEnvelopeIndexes(
  List<ServerMessage> messages,
  int start,
  int limit,
) {
  final selected = <int>{};
  if (limit <= 0) return selected;
  for (var index = messages.length - 1; index >= start; index--) {
    final message = messages[index];
    if (message is UserInputMessage) continue;
    if (_allHeavyToolIdsForMessage(message).isNotEmpty) continue;
    selected.add(index);
    if (selected.length >= limit) break;
  }
  return selected;
}

List<TurnAwareServerMessageProjection> _projectMessages(
  List<ServerMessage> messages,
  int start,
  Set<String> retainedToolIds,
  Set<int> ordinaryIndexes,
) {
  final projected = <TurnAwareServerMessageProjection>[];
  final gappedToolIds = <String>{};
  final hosts = <_GapHost>[];
  _GapHost? gapHost;

  _GapHost createGapHost(int sourceIndex) {
    final source = messages[sourceIndex];
    final outputIndex = projected.length;
    projected.add(
      TurnAwareServerMessageProjection(
        sourceIndex: sourceIndex,
        message: AssistantServerMessage(
          message: source is AssistantServerMessage
              ? AssistantMessage(
                  id: source.message.id,
                  role: source.message.role,
                  content: const [],
                  model: source.message.model,
                )
              : AssistantMessage(
                  id: 'history-tool-gap-$sourceIndex',
                  role: 'assistant',
                  content: const [],
                  model: '',
                ),
          messageUuid: source is AssistantServerMessage
              ? source.messageUuid
              : null,
        ),
      ),
    );
    final host = _GapHost(outputIndex);
    hosts.add(host);
    gapHost = host;
    return host;
  }

  void addGapTool(int sourceIndex, String toolUseId, String toolName) {
    final id = toolUseId.trim();
    if (id.isEmpty || !gappedToolIds.add(id)) return;
    final host = gapHost ?? createGapHost(sourceIndex);
    var gap = host.gaps.lastOrNull;
    if (gap == null || gap.toolUseIds.length >= turnAwareHistoryGapToolIds) {
      gap = _GapBuilder();
      host.gaps.add(gap);
    }
    gap.toolUseIds.add(id);
    gap.toolNames.add(toolName.trim());
  }

  for (var index = start; index < messages.length; index++) {
    final message = messages[index];
    if (message is UserInputMessage) {
      gapHost = null;
      projected.add(
        TurnAwareServerMessageProjection(message: message, sourceIndex: index),
      );
      continue;
    }

    if (message is AssistantServerMessage) {
      final hasVisibleText = _assistantHasVisibleText(message);
      final hasVisibleSpine = _assistantHasVisibleSpine(message);
      if (hasVisibleText) gapHost = null;
      final retainedContent = [
        for (final content in message.message.content)
          if (content is! ToolUseContent ||
              (content.id.trim().isNotEmpty &&
                  retainedToolIds.contains(content.id.trim())))
            content,
      ];
      final omittedTools = [
        for (final content in message.message.content)
          if (content is ToolUseContent &&
              content.id.trim().isNotEmpty &&
              !retainedToolIds.contains(content.id.trim()))
            content,
      ];
      final hasRetainedTool = retainedContent.any(
        (content) => content is ToolUseContent,
      );
      final shouldRetainEnvelope =
          hasVisibleSpine ||
          hasRetainedTool ||
          message.artifacts.isNotEmpty ||
          ordinaryIndexes.contains(index);

      if (shouldRetainEnvelope) {
        final outputIndex = projected.length;
        projected.add(
          TurnAwareServerMessageProjection(
            sourceIndex: index,
            message: AssistantServerMessage(
              message: AssistantMessage(
                id: message.message.id,
                role: message.message.role,
                content: retainedContent,
                model: message.message.model,
              ),
              messageUuid: message.messageUuid,
              artifacts: message.artifacts,
              artifactContentIndexOffset: message.artifactContentIndexOffset,
            ),
          ),
        );
        if (hasVisibleText) {
          gapHost = _GapHost(outputIndex);
          hosts.add(gapHost!);
        }
      }

      if ((message.historyToolDetailGaps.isNotEmpty ||
              omittedTools.isNotEmpty) &&
          gapHost == null &&
          shouldRetainEnvelope) {
        gapHost = _GapHost(projected.length - 1);
        hosts.add(gapHost!);
      }
      for (final existing in message.historyToolDetailGaps) {
        for (
          var position = 0;
          position < existing.toolUseIds.length;
          position++
        ) {
          addGapTool(
            index,
            existing.toolUseIds[position],
            position < existing.toolNames.length
                ? existing.toolNames[position]
                : '',
          );
        }
      }
      for (final content in omittedTools) {
        addGapTool(index, content.id, content.name);
      }
      continue;
    }

    if (message is ToolResultMessage) {
      final id = message.toolUseId.trim();
      if (id.isNotEmpty && !retainedToolIds.contains(id)) {
        addGapTool(index, id, message.toolName ?? '');
        continue;
      }
      projected.add(
        TurnAwareServerMessageProjection(message: message, sourceIndex: index),
      );
      continue;
    }

    if (message is ToolUseSummaryMessage || ordinaryIndexes.contains(index)) {
      projected.add(
        TurnAwareServerMessageProjection(message: message, sourceIndex: index),
      );
    }
  }

  for (final host in hosts) {
    if (host.gaps.isEmpty) continue;
    final current = projected[host.outputIndex];
    final message = current.message as AssistantServerMessage;
    projected[host.outputIndex] = TurnAwareServerMessageProjection(
      sourceIndex: current.sourceIndex,
      message: AssistantServerMessage(
        message: message.message,
        messageUuid: message.messageUuid,
        artifacts: message.artifacts,
        historyToolDetailGaps: [for (final gap in host.gaps) gap.build()],
        artifactContentIndexOffset: message.artifactContentIndexOffset,
      ),
    );
  }
  return projected;
}

List<int> _hardCapProjectedMessages(
  List<TurnAwareServerMessageProjection> projected,
  int limit,
) {
  final selected = <int>{};
  for (var index = 0; index < projected.length; index++) {
    if (projected[index].message is UserInputMessage) selected.add(index);
  }
  for (
    var index = projected.length - 1;
    index >= 0 && selected.length < limit;
    index--
  ) {
    selected.add(index);
  }
  return selected.toList()..sort();
}

String historyToolDetailGapId(List<String> toolUseIds) {
  final digest = sha256
      .convert(utf8.encode(jsonEncode(toolUseIds)))
      .toString()
      .substring(0, 24);
  return 'tool-gap-v1:${toolUseIds.length}:$digest';
}

bool _assistantHasVisibleText(AssistantServerMessage message) => message
    .message
    .content
    .whereType<TextContent>()
    .any((content) => content.text.trim().isNotEmpty);

bool _assistantHasVisibleSpine(AssistantServerMessage message) =>
    message.message.content.any(
      (content) =>
          content is TextContent && content.text.trim().isNotEmpty ||
          content is ThinkingContent && content.thinking.trim().isNotEmpty,
    );

List<String> _concreteToolIdsForMessage(ServerMessage message) {
  if (message is ToolResultMessage) {
    final id = message.toolUseId.trim();
    return id.isEmpty ? const [] : [id];
  }
  if (message is! AssistantServerMessage) return const [];
  return _uniqueNonEmpty(
    message.message.content.whereType<ToolUseContent>().map(
      (content) => content.id,
    ),
  );
}

List<String> _allHeavyToolIdsForMessage(ServerMessage message) {
  if (message is! AssistantServerMessage) {
    return _concreteToolIdsForMessage(message);
  }
  return _uniqueNonEmpty([
    ..._concreteToolIdsForMessage(message),
    for (final gap in message.historyToolDetailGaps) ...gap.toolUseIds,
  ]);
}

List<String> _uniqueNonEmpty(Iterable<String> values) => values
    .map((value) => value.trim())
    .where((value) => value.isNotEmpty)
    .toSet()
    .toList();

int _startOfLatestRootTurns<T>(
  List<T> values, {
  required int rootTurns,
  required bool Function(T value) isRootTurn,
}) {
  if (rootTurns <= 0) return values.length;
  var seen = 0;
  for (var index = values.length - 1; index >= 0; index--) {
    if (!isRootTurn(values[index])) continue;
    seen++;
    if (seen == rootTurns) return index;
  }
  return 0;
}

class _GapHost {
  _GapHost(this.outputIndex);

  final int outputIndex;
  final List<_GapBuilder> gaps = [];
}

class _GapBuilder {
  final List<String> toolUseIds = [];
  final List<String> toolNames = [];

  HistoryToolDetailGap build() => HistoryToolDetailGap(
    gapId: historyToolDetailGapId(toolUseIds),
    toolUseIds: List.unmodifiable(toolUseIds),
    toolNames: List.unmodifiable(toolNames),
    toolCallCount: toolUseIds.length,
  );
}
