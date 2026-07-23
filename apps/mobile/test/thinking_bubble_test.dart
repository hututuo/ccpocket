import 'package:ccpocket/widgets/bubbles/thinking_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('collapse signal closes an expanded thinking disclosure', (
    tester,
  ) async {
    final notifier = ValueNotifier<int>(0);
    addTearDown(notifier.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ThinkingBubble(
            thinking: 'private reasoning details',
            collapseNotifier: notifier,
          ),
        ),
      ),
    );

    expect(find.byType(SelectableText), findsNothing);
    await tester.tap(find.byType(InkWell));
    await tester.pump();
    expect(find.byType(SelectableText), findsOneWidget);

    notifier.value++;
    await tester.pump();
    expect(find.byType(SelectableText), findsNothing);
  });
}
