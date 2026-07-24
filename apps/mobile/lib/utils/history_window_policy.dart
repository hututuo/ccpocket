import '../models/messages.dart';

const turnAwareHistoryRootTurns = 5;
const turnAwareHistoryToolCalls = 200;
const turnAwareHistoryEnvelopeEntries = 300;
const turnAwareHistoryMaxRetainedEntries = 705;

List<ServerMessage> selectTurnAwareServerMessageWindow(
  List<ServerMessage> messages, {
  int rootTurns = turnAwareHistoryRootTurns,
  int toolCalls = turnAwareHistoryToolCalls,
  int envelopeEntries = turnAwareHistoryEnvelopeEntries,
  int maxRetainedEntries = turnAwareHistoryMaxRetainedEntries,
}) => [
  for (final index in selectTurnAwareServerMessageWindowIndexes(
    messages,
    rootTurns: rootTurns,
    toolCalls: toolCalls,
    envelopeEntries: envelopeEntries,
    maxRetainedEntries: maxRetainedEntries,
  ))
    messages[index],
];

List<int> selectTurnAwareServerMessageWindowIndexes(
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
  final effectiveRootTurns = normalizedRootTurns.clamp(
    0,
    maxRetainedEntries,
  ).toInt();
  final start = _startOfLatestRootTurns(
    messages,
    rootTurns: effectiveRootTurns,
    isRootTurn: (message) => message is UserInputMessage,
  );
  final retainedRootTurns = messages
      .skip(start)
      .whereType<UserInputMessage>()
      .length;
  final nonRootEntryLimit = (maxRetainedEntries - retainedRootTurns).clamp(
    0,
    maxRetainedEntries,
  );
  final selectedIndexes = <int>[];
  final selectedToolIds = <String>{};
  var anonymousToolCalls = 0;
  var retainedEnvelopes = 0;
  var retainedNonRootEntries = 0;

  for (var index = messages.length - 1; index >= start; index--) {
    final message = messages[index];
    final isRootTurn = message is UserInputMessage;
    final toolIdentity = _toolIdentityForMessage(message);
    final newToolIds = toolIdentity.ids
        .where((id) => !selectedToolIds.contains(id))
        .toList(growable: false);
    final newToolCalls = newToolIds.length + toolIdentity.anonymousCount;
    final hasToolDetail =
        toolIdentity.ids.isNotEmpty || toolIdentity.anonymousCount > 0;
    final requiredTextEnvelope =
        message is AssistantServerMessage &&
        message.message.content.whereType<TextContent>().any(
          (content) => content.text.trim().isNotEmpty,
        );

    if (!isRootTurn && retainedNonRootEntries >= nonRootEntryLimit) {
      continue;
    }
    if (hasToolDetail &&
        !requiredTextEnvelope &&
        selectedToolIds.length + anonymousToolCalls + newToolCalls >
            normalizedToolCalls) {
      continue;
    }
    if (!hasToolDetail &&
        !isRootTurn &&
        retainedEnvelopes >= normalizedEnvelopeEntries) {
      continue;
    }

    selectedIndexes.add(index);
    if (!isRootTurn) retainedNonRootEntries++;
    selectedToolIds.addAll(newToolIds);
    anonymousToolCalls += toolIdentity.anonymousCount;
    if (!hasToolDetail && !isRootTurn) retainedEnvelopes++;
  }

  return selectedIndexes.reversed.toList(growable: false);
}

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

({Set<String> ids, int anonymousCount}) _toolIdentityForMessage(
  ServerMessage message,
) {
  if (message is ToolResultMessage) {
    final id = message.toolUseId.trim();
    return (
      ids: id.isEmpty ? const <String>{} : {id},
      anonymousCount: id.isEmpty ? 1 : 0,
    );
  }
  if (message is ToolUseSummaryMessage) {
    final ids = message.precedingToolUseIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    return (ids: ids, anonymousCount: ids.isEmpty ? 1 : 0);
  }
  if (message is! AssistantServerMessage) {
    return (ids: const <String>{}, anonymousCount: 0);
  }
  final toolUses = message.message.content.whereType<ToolUseContent>().toList(
    growable: false,
  );
  final ids = toolUses
      .map((content) => content.id.trim())
      .where((id) => id.isNotEmpty)
      .toSet();
  return (ids: ids, anonymousCount: toolUses.length - ids.length);
}
