import 'package:ccpocket/features/chat_session/widgets/chat_message_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  FixedScrollMetrics metrics(double pixels) => FixedScrollMetrics(
    minScrollExtent: 0,
    maxScrollExtent: 2000,
    pixels: pixels,
    viewportDimension: 700,
    axisDirection: AxisDirection.down,
    devicePixelRatio: 3,
  );

  test('older local history loads only near the oldest visible edge', () {
    expect(shouldLoadOlderLocalHistory(metrics(1000)), isFalse);
    expect(shouldLoadOlderLocalHistory(metrics(1519)), isFalse);
    expect(shouldLoadOlderLocalHistory(metrics(1520)), isTrue);
    expect(shouldLoadOlderLocalHistory(metrics(2000)), isTrue);
  });
}
