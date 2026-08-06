import 'package:ccpocket/hooks/use_keyboard_scroll_adjustment.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('does not adjust a reversed list anchored at the bottom', () {
    expect(shouldAdjustForKeyboard(pixels: 0, minScrollExtent: 0), isFalse);
    expect(shouldAdjustForKeyboard(pixels: 0.5, minScrollExtent: 0), isFalse);
  });

  test('keeps reading position when the list is scrolled up', () {
    expect(shouldAdjustForKeyboard(pixels: 20, minScrollExtent: 0), isTrue);
  });
}
