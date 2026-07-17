import 'dart:convert';
import 'dart:io';

import 'package:ccpocket/features/artifact_preview/artifact_transfer_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('ccpocket-transfer-test-');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('streams the exact artifact bytes and reports progress', () async {
    final bytes = <int>[0, 1, 2, 3, 4, 255];
    final client = MockClient(
      (_) async => http.Response.bytes(bytes, HttpStatus.ok),
    );
    final destination = await reserveNextAvailableArtifactFile(
      root,
      'report.bin',
    );
    final progress = <int>[];

    final written = await streamArtifactToFile(
      client: client,
      url: Uri.parse('http://100.64.0.1/artifacts/token/download'),
      destination: destination,
      expectedSizeBytes: bytes.length,
      onProgress: (received, _) => progress.add(received),
    );

    expect(written, bytes.length);
    expect(await destination.readAsBytes(), bytes);
    expect(progress.last, bytes.length);
  });

  test('rejects size mismatches and removes the partial file', () async {
    final client = MockClient(
      (_) async => http.Response.bytes(<int>[1, 2, 3], HttpStatus.ok),
    );
    final destination = await reserveNextAvailableArtifactFile(
      root,
      'partial.bin',
    );

    await expectLater(
      streamArtifactToFile(
        client: client,
        url: Uri.parse('http://100.64.0.1/artifacts/token/download'),
        destination: destination,
        expectedSizeBytes: 4,
      ),
      throwsA(
        isA<ArtifactTransferException>().having(
          (error) => error.code,
          'code',
          'size_mismatch',
        ),
      ),
    );
    expect(await destination.exists(), isFalse);
  });

  test('surfaces expired links without keeping a file', () async {
    final client = MockClient(
      (_) async => http.Response('Gone', HttpStatus.gone),
    );
    final destination = await reserveNextAvailableArtifactFile(
      root,
      'gone.bin',
    );

    await expectLater(
      streamArtifactToFile(
        client: client,
        url: Uri.parse('http://100.64.0.1/artifacts/token/download'),
        destination: destination,
        expectedSizeBytes: 4,
      ),
      throwsA(
        isA<ArtifactTransferException>()
            .having((error) => error.code, 'code', 'http_error')
            .having((error) => error.statusCode, 'statusCode', HttpStatus.gone),
      ),
    );
    expect(await destination.exists(), isFalse);
  });

  test(
    'keeps downloads stable and avoids overwriting an existing file',
    () async {
      await File('${root.path}/report.docx').writeAsString('first');

      final next = await reserveNextAvailableArtifactFile(root, 'report.docx');

      expect(next.path, endsWith('report (1).docx'));
      expect(await next.exists(), isTrue);
      expect(await next.length(), 0);
      expect(
        safeArtifactDownloadFilename('../bad\\name.docx'),
        '.._bad_name.docx',
      );
    },
  );

  test('rejects a streamed overrun before writing excess bytes', () async {
    final client = MockClient.streaming((_, _) async {
      return http.StreamedResponse(
        Stream<List<int>>.fromIterable(<List<int>>[
          <int>[1, 2],
          <int>[3, 4],
        ]),
        HttpStatus.ok,
      );
    });
    final destination = await reserveNextAvailableArtifactFile(
      root,
      'overrun.bin',
    );

    await expectLater(
      streamArtifactToFile(
        client: client,
        url: Uri.parse('http://100.64.0.1/artifacts/token/download'),
        destination: destination,
        expectedSizeBytes: 3,
      ),
      throwsA(
        isA<ArtifactTransferException>().having(
          (error) => error.code,
          'code',
          'size_mismatch',
        ),
      ),
    );
    expect(await destination.exists(), isFalse);
    expect(
      root.listSync().where((entry) => entry.path.endsWith('.part')),
      isEmpty,
    );
  });

  test('rejects sizes outside the Bridge transfer contract', () async {
    final destination = await reserveNextAvailableArtifactFile(
      root,
      'huge.bin',
    );
    final client = MockClient((_) async => http.Response('', HttpStatus.ok));

    await expectLater(
      streamArtifactToFile(
        client: client,
        url: Uri.parse('http://100.64.0.1/artifacts/token/download'),
        destination: destination,
        expectedSizeBytes: maxArtifactTransferBytes + 1,
      ),
      throwsA(
        isA<ArtifactTransferException>().having(
          (error) => error.code,
          'code',
          'size_out_of_range',
        ),
      ),
    );
    expect(await destination.exists(), isFalse);
  });

  test('does not send an already-cancelled transfer', () async {
    var requestSent = false;
    final client = MockClient((_) async {
      requestSent = true;
      return http.Response.bytes(<int>[1], HttpStatus.ok);
    });
    final destination = await reserveNextAvailableArtifactFile(
      root,
      'cancelled.bin',
    );
    final cancellation = ArtifactTransferCancellation()..cancel();

    await expectLater(
      streamArtifactToFile(
        client: client,
        url: Uri.parse('http://100.64.0.1/artifacts/token/download'),
        destination: destination,
        expectedSizeBytes: 1,
        cancellation: cancellation,
      ),
      throwsA(
        isA<ArtifactTransferException>().having(
          (error) => error.code,
          'code',
          'cancelled',
        ),
      ),
    );
    expect(requestSent, isFalse);
    expect(await destination.exists(), isFalse);
  });

  test('cancels after the last chunk without committing the file', () async {
    final cancellation = ArtifactTransferCancellation();
    final client = MockClient(
      (_) async => http.Response.bytes(<int>[1, 2, 3], HttpStatus.ok),
    );
    final destination = await reserveNextAvailableArtifactFile(
      root,
      'late-cancel.bin',
    );

    await expectLater(
      streamArtifactToFile(
        client: client,
        url: Uri.parse('http://100.64.0.1/artifacts/token/download'),
        destination: destination,
        expectedSizeBytes: 3,
        cancellation: cancellation,
        onProgress: (received, _) {
          if (received == 3) cancellation.cancel();
        },
      ),
      throwsA(
        isA<ArtifactTransferException>().having(
          (error) => error.code,
          'code',
          'cancelled',
        ),
      ),
    );
    expect(await destination.exists(), isFalse);
    expect(
      root.listSync().where((entry) => entry.path.endsWith('.part')),
      isEmpty,
    );
  });

  test(
    'transfers long UTF-8 names and keeps collision suffixes in budget',
    () async {
      final bytes = <int>[4, 5, 6];
      final client = MockClient(
        (_) async => http.Response.bytes(bytes, HttpStatus.ok),
      );
      final requested = '${List<String>.filled(100, '报告').join()}.docx';
      final safe = safeArtifactDownloadFilename(requested);
      final first = await reserveNextAvailableArtifactFile(root, requested);
      await streamArtifactToFile(
        client: client,
        url: Uri.parse('http://100.64.0.1/artifacts/token/download'),
        destination: first,
        expectedSizeBytes: bytes.length,
      );
      final second = await reserveNextAvailableArtifactFile(root, requested);
      await streamArtifactToFile(
        client: client,
        url: Uri.parse('http://100.64.0.1/artifacts/token/download'),
        destination: second,
        expectedSizeBytes: bytes.length,
      );

      expect(safe, endsWith('.docx'));
      expect(utf8.encode(safe).length, lessThanOrEqualTo(240));
      expect(
        utf8.encode(first.uri.pathSegments.last).length,
        lessThanOrEqualTo(240),
      );
      expect(
        utf8.encode(second.uri.pathSegments.last).length,
        lessThanOrEqualTo(240),
      );
      expect(second.path, isNot(first.path));
      expect(await first.readAsBytes(), bytes);
      expect(await second.readAsBytes(), bytes);
      expect(safeArtifactDownloadFilename('..'), 'download');
    },
  );
}
