import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ccpocket/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppTheme font fallback', () {
    test('applies Chinese system font fallback only for zh locale', () {
      final zhFallback = AppTheme.fontFamilyFallbackForLocale(
        const Locale('zh'),
      );

      _expectChineseFallback(zhFallback);

      for (final locale in [
        null,
        const Locale('en'),
        const Locale('ja'),
        const Locale('ko'),
      ]) {
        final fallback = AppTheme.fontFamilyFallbackForLocale(locale);
        _expectNoChineseFallback(fallback, reason: 'locale=$locale');
      }
    });
  });
}

void _expectChineseFallback(List<String>? fallback) {
  expect(
    fallback,
    containsAll(['Microsoft YaHei', 'PingFang SC', 'Noto Sans CJK SC']),
  );
}

void _expectNoChineseFallback(
  List<String>? fallback, {
  required String reason,
}) {
  for (final family in ['Microsoft YaHei', 'PingFang SC', 'Noto Sans CJK SC']) {
    expect(
      fallback ?? const <String>[],
      isNot(contains(family)),
      reason: reason,
    );
  }
}
