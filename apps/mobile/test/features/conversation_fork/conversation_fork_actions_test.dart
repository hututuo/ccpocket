import 'package:ccpocket/features/conversation_fork/conversation_fork_actions.dart';
import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/widgets/adaptive_context_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('finds the latest Codex user turn through a history snapshot', () {
    expect(
      latestCodexUserTurnUuid(const [
        HistoryMessage(
          messages: [
            UserInputMessage(
              text: 'first',
              userMessageUuid: 'codex:user-turn:1',
            ),
            UserInputMessage(
              text: 'second',
              userMessageUuid: 'codex:user-turn:2',
            ),
          ],
        ),
      ]),
      'codex:user-turn:2',
    );
  });

  testWidgets('builds fork actions for context and overflow menus', (
    tester,
  ) async {
    late AdaptiveActionMenuItem<String> contextAction;
    late PopupMenuItem<String> overflowAction;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            contextAction = conversationForkActionItem(context);
            overflowAction = conversationForkPopupMenuItem(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(contextAction.value, conversationForkAction);
    expect(contextAction.key, const ValueKey('conversation_fork_action'));
    expect(overflowAction.value, conversationForkAction);
    expect(overflowAction.key, const ValueKey('menu_fork_conversation'));
  });
}
