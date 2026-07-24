import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/theme/app_theme.dart';
import 'package:ccpocket/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: AppTheme.lightTheme,
    home: Scaffold(body: child),
  );
}

void main() {
  testWidgets('shows every message time to the second with provenance', (
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
  });
}
