import 'package:flutter/material.dart';

import '../../widgets/chat_selection_actions.dart';
import 'l10n/side_chat_strings.dart';

const _sideChatSelectionActionId = 'side_chat';

ChatSelectionAction createSideChatSelectionAction({
  required BuildContext context,
  required ValueChanged<String> onOpen,
}) => ChatSelectionAction(
  id: _sideChatSelectionActionId,
  label: SideChatStrings.of(context).selectionAction,
  // The selected text is placed in the composer of an official persisted
  // thread/fork. Sending remains explicit in the standard conversation view.
  onSelected: onOpen,
);
