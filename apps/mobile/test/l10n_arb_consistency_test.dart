import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Set<String> _messageKeys(String path) {
  final json = jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;
  return json.keys.where((key) => !key.startsWith('@')).toSet();
}

void main() {
  test('all locale ARBs expose the template message key set', () {
    const templatePath = 'lib/l10n/app_ja.arb';
    final templateKeys = _messageKeys(templatePath);

    for (final locale in const ['en', 'ko', 'zh']) {
      final localeKeys = _messageKeys('lib/l10n/app_$locale.arb');
      final missing = templateKeys.difference(localeKeys).toList()..sort();
      final extra = localeKeys.difference(templateKeys).toList()..sort();

      expect(
        {'missing': missing, 'extra': extra},
        const {'missing': <String>[], 'extra': <String>[]},
        reason:
            'app_$locale.arb must match the app_ja.arb template. '
            'Non-template keys are silently ignored by flutter gen-l10n.',
      );
    }
  });
}
