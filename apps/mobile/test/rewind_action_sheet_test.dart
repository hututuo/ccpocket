import 'package:ccpocket/features/claude_session/widgets/rewind_action_sheet.dart';
import 'package:ccpocket/features/codex_session/widgets/codex_edit_message_dialog.dart';
import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('rewind action sheet can be limited to conversation mode', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        theme: AppTheme.lightTheme,
        home: Scaffold(
          body: RewindActionSheet(
            userMessage: UserChatEntry(
              'first codex turn',
              messageUuid: 'codex:user-turn:1',
            ),
            availableModes: const [RewindMode.conversation],
            showPreview: false,
            onRewind: (_) {},
          ),
        ),
      ),
    );

    expect(find.text('Restore conversation only'), findsOneWidget);
    expect(find.text('Restore code only'), findsNothing);
    expect(find.text('Restore conversation & code'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('file'), findsNothing);
  });

  testWidgets('codex message edit explains the native branch semantics', (
    tester,
  ) async {
    var confirmed = false;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        theme: AppTheme.lightTheme,
        home: Scaffold(
          body: CodexEditMessageDialog(
            messageText: 'first codex turn',
            onConfirm: () {
              confirmed = true;
            },
          ),
        ),
      ),
    );

    expect(find.text('Edit this message?'), findsOneWidget);
    expect(find.textContaining('new branch'), findsOneWidget);
    expect(find.text('first codex turn'), findsOneWidget);
    expect(find.text('Restore conversation only'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('codex_edit_message_confirm_button')),
    );
    expect(confirmed, isTrue);
  });
}
