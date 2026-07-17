import 'package:ccpocket/features/chat_selection_add_to_conversation/chat_selection_add_to_conversation.dart';
import 'package:ccpocket/services/draft_service.dart';
import 'package:ccpocket/widgets/chat_selection_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('inserts a selected excerpt as a draft-only Markdown quote', () {
    final controller = TextEditingController(text: 'Existing prompt');
    addTearDown(controller.dispose);
    controller.selection = const TextSelection.collapsed(offset: 15);

    insertSelectionQuote(controller, 'first line\nsecond line');

    expect(
      controller.text,
      'Existing prompt\n\n> first line\n> second line\n\n',
    );
    expect(controller.selection.isCollapsed, true);
    expect(controller.selection.end, controller.text.length);
  });

  test('replaces the current composer selection without sending anything', () {
    final controller = TextEditingController(text: 'before replace after');
    addTearDown(controller.dispose);
    controller.selection = const TextSelection(baseOffset: 7, extentOffset: 14);

    insertSelectionQuote(controller, 'quoted');

    expect(controller.text, 'before \n\n> quoted\n\n after');
  });

  testWidgets('feature owns its localized label and draft persistence', (
    tester,
  ) async {
    final draftService = DraftService(await SharedPreferences.getInstance());
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    late ChatSelectionAction action;

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        supportedLocales: const [Locale('en'), Locale('zh')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Builder(
          builder: (context) {
            action = createAddToConversationSelectionAction(
              context: context,
              sessionId: 'session-1',
              inputController: controller,
              draftService: draftService,
            );
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(action.label, '添加到会话');
    action.onSelected('内容');
    expect(draftService.getDraft('session-1'), '> 内容\n\n');
  });
}
