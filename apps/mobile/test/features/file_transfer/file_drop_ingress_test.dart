import 'dart:convert';
import 'dart:typed_data';

import 'package:ccpocket/features/file_transfer/file_drop_ingress.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('dropped file names are reduced to a safe leaf', () {
    expect(
      safeDroppedFilename(
        r'../folder\report.pdf',
        isPng: false,
        isJpeg: false,
      ),
      'report.pdf',
    );
    expect(
      safeDroppedFilename(null, isPng: true, isJpeg: false, fallbackIndex: 3),
      'dropped-file-3.png',
    );
    expect(
      safeDroppedFilename(
        '${'a' * 300}.txt',
        isPng: false,
        isJpeg: false,
      ).length,
      255,
    );
    final unicode = safeDroppedFilename(
      '${'文件' * 200}.pdf',
      isPng: false,
      isJpeg: false,
    );
    expect(utf8.encode(unicode).length, lessThanOrEqualTo(255));
    expect(unicode, endsWith('.pdf'));
  });

  test('only known small image drops use inline message memory', () {
    DroppedFilePayload payload({required int? size, required bool isPng}) =>
        DroppedFilePayload(
          filename: isPng ? 'image.png' : 'archive.zip',
          bytes: const Stream<Uint8List>.empty(),
          sizeBytes: size,
          isPng: isPng,
          isJpeg: false,
        );

    expect(
      canInlineDroppedImage(
        payload(size: maxInlineDroppedImageBytes, isPng: true),
      ),
      isTrue,
    );
    expect(
      canInlineDroppedImage(
        payload(size: maxInlineDroppedImageBytes + 1, isPng: true),
      ),
      isFalse,
    );
    expect(canInlineDroppedImage(payload(size: null, isPng: true)), isFalse);
    expect(canInlineDroppedImage(payload(size: 10, isPng: false)), isFalse);
  });
}
