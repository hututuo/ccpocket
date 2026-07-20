import 'dart:async';

import '../../../widgets/chat_selection_actions.dart';
import '../../side_chat/side_chat_selection_action.dart';
import '../host/local_session_feature.dart';

final LocalSessionFeatureSlot sideChatUiSlot = _SideChatUiSlot();

class _SideChatUiSlot extends LocalSessionFeatureSlot {
  @override
  String get featureId => 'side_chat';

  @override
  List<ChatSelectionAction> selectionActions(
    CodexSessionFeatureContext context,
  ) {
    final forkConversation = context.forkConversation;
    if (forkConversation == null) return const [];
    return [
      createSideChatSelectionAction(
        context: context.context,
        onOpen: (selectedText) {
          unawaited(forkConversation(initialDraft: selectedText));
        },
      ),
    ];
  }
}
