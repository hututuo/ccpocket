import 'package:ccpocket/hooks/use_scroll_tracking.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late ScrollTrackingResult tracking;

  Widget subject(String sessionId) => Directionality(
    textDirection: TextDirection.ltr,
    child: HookBuilder(
      builder: (context) {
        tracking = useScrollTracking(sessionId, persistRawOffset: false);
        return ListView.builder(
          controller: tracking.controller,
          reverse: true,
          itemCount: 30,
          itemExtent: 100,
          itemBuilder: (context, index) => Text('Message $index'),
        );
      },
    ),
  );

  testWidgets('pending follow-latest does not override a new reading position', (
    tester,
  ) async {
    await tester.pumpWidget(subject('reading-intent'));
    await tester.pump();

    tracking.scrollToBottom();
    tracking.controller.jumpTo(400);
    await tester.pumpAndSettle();

    expect(tracking.controller.offset, 400);
    expect(tracking.isScrolledUp, isTrue);
  });

  testWidgets('a callback from the previous session cannot move the new one', (
    tester,
  ) async {
    await tester.pumpWidget(subject('previous-session'));
    await tester.pump();
    tracking.controller.jumpTo(40);
    await tester.pump();
    tracking.scrollToBottom();

    await tester.pumpWidget(subject('new-session'));
    await tester.pumpAndSettle();

    expect(tracking.controller.offset, 40);
  });

  testWidgets('following output still returns a nearby reader to latest', (
    tester,
  ) async {
    await tester.pumpWidget(subject('follow-latest'));
    await tester.pump();
    tracking.controller.jumpTo(40);
    await tester.pump();

    tracking.scrollToBottom();
    await tester.pumpAndSettle();

    expect(tracking.controller.offset, 0);
    expect(tracking.isScrolledUp, isFalse);
  });
}
