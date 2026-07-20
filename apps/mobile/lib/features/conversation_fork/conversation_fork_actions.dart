import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/messages.dart';
import '../../widgets/adaptive_context_menu.dart';
import 'conversation_fork_strings.dart';

const conversationForkAction = 'conversation_fork';
const latestCodexForkTarget = 'codex:user-turn:latest';

AdaptiveActionMenuItem<String> conversationForkActionItem(
  BuildContext context,
) => AdaptiveActionMenuItem(
  key: const ValueKey('conversation_fork_action'),
  value: conversationForkAction,
  icon: Icons.call_split,
  label: AppLocalizations.of(context).forkConversation,
);

PopupMenuItem<String> conversationForkPopupMenuItem(
  BuildContext context, {
  bool enabled = true,
}) => PopupMenuItem<String>(
  key: const ValueKey('menu_fork_conversation'),
  value: conversationForkAction,
  enabled: enabled,
  child: ListTile(
    leading: const Icon(Icons.call_split, size: 20),
    title: Text(AppLocalizations.of(context).forkConversation),
    dense: true,
    contentPadding: EdgeInsets.zero,
  ),
);

Future<bool> confirmConversationFork(BuildContext context) async {
  final l = AppLocalizations.of(context);
  final strings = ConversationForkStrings.of(context);
  return await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(l.forkConversationTitle),
          content: Text(strings.currentConversationBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(l.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(l.fork),
            ),
          ],
        ),
      ) ??
      false;
}

String? latestCodexUserTurnUuid(Iterable<ServerMessage> messages) {
  String? latest;

  void observe(ServerMessage message) {
    if (message is HistoryMessage) {
      for (final nested in message.messages) {
        observe(nested);
      }
      return;
    }
    if (message case UserInputMessage(:final userMessageUuid)) {
      final candidate = userMessageUuid?.trim();
      if (candidate != null && candidate.startsWith('codex:user-turn:')) {
        latest = candidate;
      }
    }
  }

  for (final message in messages) {
    observe(message);
  }
  return latest;
}
