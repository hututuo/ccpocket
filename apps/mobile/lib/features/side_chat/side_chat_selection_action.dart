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
  // Opening only pre-fills the isolated draft. Sending always requires a
  // separate explicit tap in SideChatPanel.
  onSelected: onOpen,
);
