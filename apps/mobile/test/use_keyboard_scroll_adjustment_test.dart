import 'package:ccpocket/hooks/use_keyboard_scroll_adjustment.dart';
import 'package:ccpocket/features/chat_session/widgets/maintain_reading_position_physics.dart';
import 'package:ccpocket/features/chat_session/widgets/reading_position_auto_scroll_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('does not adjust a reversed list anchored at the bottom', () {
    expect(shouldAdjustForKeyboard(pixels: 0, minScrollExtent: 0), isFalse);
    expect(shouldAdjustForKeyboard(pixels: 0.5, minScrollExtent: 0), isFalse);
  });

  test('keeps reading position when the list is scrolled up', () {
    expect(shouldAdjustForKeyboard(pixels: 20, minScrollExtent: 0), isTrue);
  });

  testWidgets('keyboard resize adjusts a scrolled chat once, not twice', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 900);
    addTearDown(tester.view.reset);
    final controller = ReadingPositionAutoScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: HookBuilder(
          builder: (context) {
            useKeyboardScrollAdjustment(controller);
            return Scaffold(
              body: ListView.builder(
                controller: controller,
                reverse: true,
                physics: MaintainReadingPositionPhysics(
                  shouldMaintain: () =>
                      !controller.suppressPassiveExtentCorrection,
                ),
                itemCount: 40,
                itemExtent: 100,
                itemBuilder: (context, index) => Text('Message $index'),
              ),
            );
          },
        ),
      ),
    );
    await tester.pump();
    controller.jumpTo(400);
    await tester.pumpAndSettle();

    tester.view.viewInsets = const FakeViewPadding(bottom: 200);
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(600, 1));

    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(400, 1));
  });
}
