import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/theme/app_theme.dart';
import 'package:ccpocket/widgets/bubbles/assistant_bubble.dart';
import 'package:ccpocket/widgets/bubbles/message_action_bar.dart';
import 'package:ccpocket/widgets/bubbles/tool_use_summary_bubble.dart';
import 'package:ccpocket/widgets/bubbles/user_bubble.dart';
import 'package:ccpocket/widgets/chat_message_timestamp.dart';
import 'package:ccpocket/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: AppTheme.lightTheme,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  );
}

void main() {
  testWidgets('puts user timestamps inside their bubbles with provenance', (
    tester,
  ) async {
    final timestamp = DateTime(2026, 7, 25, 3, 4, 5);
    final exact = UserChatEntry(
      'exact',
      timestamp: timestamp,
      timestampIsAuthoritative: true,
    );
    final approximate = UserChatEntry('approximate', timestamp: timestamp);

    await tester.pumpWidget(
      _wrap(
        Column(
          children: [
            ChatEntryWidget(entry: exact),
            ChatEntryWidget(entry: approximate, previous: exact),
          ],
        ),
      ),
    );

    expect(find.text('03:04:05'), findsOneWidget);
    expect(find.text('~03:04:05'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(UserBubble),
        matching: find.byType(ChatMessageTimestampText),
      ),
      findsNWidgets(2),
    );
  });

  testWidgets('puts assistant time in its existing action row', (tester) async {
    final entry = ServerChatEntry(
      AssistantServerMessage(
        message: const AssistantMessage(
          id: 'assistant-time',
          role: 'assistant',
          content: [TextContent(text: 'Finished.')],
          model: 'codex',
        ),
      ),
      timestamp: DateTime(2026, 7, 25, 6, 7, 8),
      timestampIsAuthoritative: true,
    );

    await tester.pumpWidget(_wrap(ChatEntryWidget(entry: entry)));

    expect(find.text('06:07:08'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(MessageActionBar),
        matching: find.byType(ChatMessageTimestampText),
      ),
      findsOneWidget,
    );
    expect(find.byType(AssistantBubble), findsOneWidget);
  });

  testWidgets('does not create timestamp rows for status-only entries', (
    tester,
  ) async {
    final entry = ServerChatEntry(
      const StatusMessage(status: ProcessStatus.running),
      timestamp: DateTime(2026, 7, 25, 9, 10, 11),
      timestampIsAuthoritative: true,
    );

    await tester.pumpWidget(_wrap(ChatEntryWidget(entry: entry)));

    expect(find.text('09:10:11'), findsNothing);
    expect(find.byType(ChatMessageTimestampText), findsNothing);
  });

  testWidgets('keeps tool summaries and their time on one compact row', (
    tester,
  ) async {
    final entry = ServerChatEntry(
      const ToolUseSummaryMessage(summary: 'Multiple commands completed'),
      timestamp: DateTime(2026, 7, 25, 12, 13, 14),
      timestampIsAuthoritative: true,
    );

    await tester.pumpWidget(_wrap(ChatEntryWidget(entry: entry)));

    final summary = find.byType(ToolUseSummaryBubble);
    expect(summary, findsOneWidget);
    expect(
      find.descendant(
        of: summary,
        matching: find.byType(ChatMessageTimestampText),
      ),
      findsOneWidget,
    );
    expect(find.text('12:13:14'), findsOneWidget);
  });

  testWidgets('keeps long text and command timestamps inside narrow bubbles', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(280, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final timestamp = DateTime(2026, 7, 25, 15, 16, 17);

    await tester.pumpWidget(
      _wrap(
        ListView(
          children: [
            ChatEntryWidget(
              entry: UserChatEntry(
                'A long phone message that wraps while preserving its time.',
                timestamp: timestamp,
                timestampIsAuthoritative: true,
              ),
            ),
            ChatEntryWidget(
              entry: UserChatEntry(
                '<command-message>'
                '<command-name>/review</command-name>'
                '<command-args>a very long command argument for the phone</command-args>'
                '</command-message>',
                timestamp: timestamp,
                timestampIsAuthoritative: true,
              ),
            ),
          ],
        ),
      ),
    );

    expect(find.text('15:16:17'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });
}
