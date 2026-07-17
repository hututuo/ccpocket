import '../../../widgets/chat_selection_actions.dart';
import '../../chat_selection_add_to_conversation/chat_selection_add_to_conversation.dart';
import '../host/local_session_feature.dart';

final LocalSessionFeatureSlot addToConversationUiSlot =
    _AddToConversationUiSlot();

class _AddToConversationUiSlot extends LocalSessionFeatureSlot {
  @override
  String get featureId => 'add_to_conversation';

  @override
  List<ChatSelectionAction> selectionActions(
    CodexSessionFeatureContext context,
  ) => [
    createAddToConversationSelectionAction(
      context: context.context,
      sessionId: context.sessionId,
      inputController: context.inputController,
      draftService: context.draftService,
    ),
  ];
}
