import 'package:flutter/material.dart';

import '../../services/draft_service.dart';
import '../../widgets/chat_selection_actions.dart';

const _addToConversationActionId = 'add_to_conversation';

ChatSelectionAction createAddToConversationSelectionAction({
  required BuildContext context,
  required String sessionId,
  required TextEditingController inputController,
  required DraftService draftService,
}) {
  return ChatSelectionAction(
    id: _addToConversationActionId,
    label: _addToConversationLabel(context),
    onSelected: (selectedText) {
      insertSelectionQuote(inputController, selectedText);
      draftService.saveDraft(sessionId, inputController.text);
    },
  );
}

/// Insert selected transcript text as a Markdown quote at the current composer
/// selection. This changes the draft only and never sends a message.
void insertSelectionQuote(
  TextEditingController controller,
  String selectedText,
) {
  final normalized = normalizeChatSelection(selectedText);
  if (normalized.isEmpty) return;

  final value = controller.value;
  final selection = value.selection.isValid
      ? value.selection
      : TextSelection.collapsed(offset: value.text.length);
  final start = selection.start.clamp(0, value.text.length).toInt();
  final end = selection.end.clamp(start, value.text.length).toInt();
  final before = value.text.substring(0, start);
  final after = value.text.substring(end);
  final prefix = before.isEmpty
      ? ''
      : before.endsWith('\n\n')
      ? ''
      : before.endsWith('\n')
      ? '\n'
      : '\n\n';
  final quote = normalized
      .split('\n')
      .map((line) => line.isEmpty ? '>' : '> $line')
      .join('\n');
  final suffix = after.isEmpty
      ? '\n\n'
      : after.startsWith('\n\n')
      ? ''
      : after.startsWith('\n')
      ? '\n'
      : '\n\n';
  final inserted = '$prefix$quote$suffix';
  final nextText = '$before$inserted$after';
  final cursorOffset = before.length + inserted.length;
  controller.value = value.copyWith(
    text: nextText,
    selection: TextSelection.collapsed(offset: cursorOffset),
    composing: TextRange.empty,
  );
}

String _addToConversationLabel(BuildContext context) {
  return switch (Localizations.localeOf(context).languageCode) {
    'zh' => '添加到会话',
    'ja' => '会話に追加',
    'ko' => '대화에 추가',
    _ => 'Add to conversation',
  };
}
