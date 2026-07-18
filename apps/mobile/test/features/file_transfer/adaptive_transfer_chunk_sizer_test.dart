import 'package:ccpocket/features/file_transfer/adaptive_transfer_chunk_sizer.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a 1-10 MiB transfer uses one exact chunk', () {
    for (final mebibytes in [1, 3, 10]) {
      final size = mebibytes * 1024 * 1024;
      expect(
        AdaptiveTransferChunkSizer().nextChunkBytes(
          totalBytes: size,
          remainingBytes: size,
          serverMaxBytes: fileTransferChunkBytes,
        ),
        size,
      );
    }
  });

  test('fast healthy chunks grow from 4 MiB to the 16 MiB cap', () {
    final sizer = AdaptiveTransferChunkSizer();
    const large = 512 * 1024 * 1024;
    expect(
      sizer.nextChunkBytes(
        totalBytes: large,
        remainingBytes: large,
        serverMaxBytes: fileTransferChunkBytes,
      ),
      4 * 1024 * 1024,
    );
    for (var index = 0; index < 3; index++) {
      sizer.recordSuccess(
        bytes: 4 * 1024 * 1024,
        elapsed: const Duration(milliseconds: 250),
      );
    }
    expect(
      sizer.nextChunkBytes(
        totalBytes: large,
        remainingBytes: large,
        serverMaxBytes: fileTransferChunkBytes,
      ),
      fileTransferChunkBytes,
    );
  });

  test('a large transfer does not jump to a 16 MiB remainder', () {
    final sizer = AdaptiveTransferChunkSizer();
    const total = 20 * 1024 * 1024;
    const fourMiB = 4 * 1024 * 1024;
    expect(
      sizer.nextChunkBytes(
        totalBytes: total,
        remainingBytes: total,
        serverMaxBytes: fileTransferChunkBytes,
      ),
      fourMiB,
    );
    sizer.recordSuccess(bytes: fourMiB, elapsed: const Duration(seconds: 1));
    expect(
      sizer.nextChunkBytes(
        totalBytes: total,
        remainingBytes: fileTransferChunkBytes,
        serverMaxBytes: fileTransferChunkBytes,
      ),
      fourMiB,
    );
    sizer.recordSuccess(bytes: fourMiB, elapsed: const Duration(seconds: 1));
    expect(
      sizer.nextChunkBytes(
        totalBytes: total,
        remainingBytes: 12 * 1024 * 1024,
        serverMaxBytes: fileTransferChunkBytes,
      ),
      greaterThan(fourMiB),
    );
  });

  test('a 16 MiB plus one-byte transfer keeps its one-byte tail exact', () {
    const total = fileTransferChunkBytes + 1;
    expect(
      AdaptiveTransferChunkSizer().nextChunkBytes(
        totalBytes: total,
        remainingBytes: 1,
        serverMaxBytes: fileTransferChunkBytes,
      ),
      1,
    );
  });

  test('a large transfer keeps a 512 KiB tail below the 1 MiB target', () {
    const tail = 512 * 1024;
    expect(
      AdaptiveTransferChunkSizer().nextChunkBytes(
        totalBytes: 20 * 1024 * 1024 + tail,
        remainingBytes: tail,
        serverMaxBytes: fileTransferChunkBytes,
      ),
      tail,
    );
  });

  test('timeout or disconnect halves the next large-file chunk', () {
    final sizer = AdaptiveTransferChunkSizer();
    const large = 512 * 1024 * 1024;
    sizer.recordFailure();
    expect(
      sizer.nextChunkBytes(
        totalBytes: large,
        remainingBytes: large,
        serverMaxBytes: fileTransferChunkBytes,
      ),
      2 * 1024 * 1024,
    );
    sizer.recordFailure();
    expect(
      sizer.nextChunkBytes(
        totalBytes: large,
        remainingBytes: large,
        serverMaxBytes: fileTransferChunkBytes,
      ),
      adaptiveTransferMinimumChunkBytes,
    );
  });

  test('server max lower than the local target always wins', () {
    final sizer = AdaptiveTransferChunkSizer();
    const serverMax = 2 * 1024 * 1024;
    expect(
      sizer.nextChunkBytes(
        totalBytes: 100 * 1024 * 1024,
        remainingBytes: 100 * 1024 * 1024,
        serverMaxBytes: serverMax,
      ),
      serverMax,
    );
  });
}
