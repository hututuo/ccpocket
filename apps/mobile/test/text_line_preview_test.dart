import 'package:ccpocket/utils/text_line_preview.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('buildTextLinePreview', () {
    test('returns the complete content when it fits', () {
      expect(buildTextLinePreview('one\ntwo\nthree', maxLines: 3), (
        text: 'one\ntwo\nthree',
        hasMore: false,
      ));
    });

    test('cuts at the requested line boundary', () {
      expect(buildTextLinePreview('one\ntwo\nthree\nfour', maxLines: 3), (
        text: 'one\ntwo\nthree',
        hasMore: true,
      ));
    });

    test('treats a trailing newline as an additional line', () {
      expect(buildTextLinePreview('one\ntwo\nthree\n', maxLines: 3), (
        text: 'one\ntwo\nthree',
        hasMore: true,
      ));
    });

    test('does not copy the unseen tail into the preview', () {
      final tail = List.filled(100000, 'unseen').join('\n');
      final preview = buildTextLinePreview(
        'one\ntwo\nthree\nfour\nfive\n$tail',
        maxLines: 5,
      );

      expect(preview.text, 'one\ntwo\nthree\nfour\nfive');
      expect(preview.hasMore, true);
      expect(preview.text.length, lessThan(30));
    });

    test('rejects a non-positive line limit', () {
      expect(
        () => buildTextLinePreview('content', maxLines: 0),
        throwsArgumentError,
      );
    });
  });
}
