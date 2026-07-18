import 'dart:async';
import 'dart:io';

import 'package:ccpocket/features/file_transfer/file_transfer_cancellation.dart';
import 'package:ccpocket/features/file_transfer/file_transfer_http.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const token = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const etag = '"EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE"';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('ccpocket-v2-http-');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
    'download HEAD disables redirects and validates resume headers',
    () async {
      final transport = FileTransferHttpTransport(
        MockClient.streaming((request, body) async {
          expect(request.method, 'HEAD');
          expect(request.followRedirects, isFalse);
          expect(request.maxRedirects, 0);
          expect(request.headers[fileTransferTokenHeader.toLowerCase()], token);
          return http.StreamedResponse(
            const Stream.empty(),
            HttpStatus.ok,
            headers: {
              'content-length': '32',
              'etag': etag,
              'accept-ranges': 'bytes',
              'x-ccpocket-max-chunk-bytes': '16',
              'x-ccpocket-transfer-expires': '2026-07-25T12:00:00.000Z',
            },
          );
        }),
      );

      final head = await transport.headDownload(
        url: Uri.parse('https://mac.example/download'),
        token: token,
        cancellation: FileTransferCancellation(),
      );

      expect(head.sizeBytes, 32);
      expect(head.etag, etag);
      expect(head.maxChunkSizeBytes, 16);
    },
  );

  test('download range appends exact bytes and keeps explicit end', () async {
    final partial = File('${root.path}/download.part');
    await partial.writeAsBytes(const [1, 2]);
    final transport = FileTransferHttpTransport(
      MockClient.streaming((request, body) async {
        expect(request.headers['range'], 'bytes=2-3');
        expect(request.headers['if-range'], etag);
        return http.StreamedResponse(
          Stream.value(const [3, 4]),
          HttpStatus.partialContent,
          contentLength: 2,
          headers: {
            'content-length': '2',
            'content-range': 'bytes 2-3/4',
            'etag': etag,
          },
        );
      }),
    );

    final next = await transport.downloadChunk(
      url: Uri.parse('https://mac.example/download'),
      token: token,
      etag: etag,
      partial: partial,
      offset: 2,
      endInclusive: 3,
      totalSizeBytes: 4,
      cancellation: FileTransferCancellation(),
    );

    expect(next, 4);
    expect(await partial.readAsBytes(), const [1, 2, 3, 4]);
  });

  test(
    'mid-chunk failure truncates partial back to checkpoint offset',
    () async {
      final partial = File('${root.path}/download.part');
      await partial.writeAsBytes(const [1, 2]);
      final controller = StreamController<List<int>>();
      final transport = FileTransferHttpTransport(
        MockClient.streaming((request, body) async {
          scheduleMicrotask(() {
            controller.add(const [3]);
            controller.addError(StateError('socket lost'));
            controller.close();
          });
          return http.StreamedResponse(
            controller.stream,
            HttpStatus.partialContent,
            contentLength: 2,
            headers: {
              'content-length': '2',
              'content-range': 'bytes 2-3/4',
              'etag': etag,
            },
          );
        }),
      );

      await expectLater(
        transport.downloadChunk(
          url: Uri.parse('https://mac.example/download'),
          token: token,
          etag: etag,
          partial: partial,
          offset: 2,
          endInclusive: 3,
          totalSizeBytes: 4,
          cancellation: FileTransferCancellation(),
        ),
        throwsStateError,
      );
      expect(await partial.readAsBytes(), const [1, 2]);
    },
  );

  test('redirect response is rejected without forwarding the token', () async {
    var calls = 0;
    final transport = FileTransferHttpTransport(
      MockClient.streaming((request, body) async {
        calls++;
        expect(request.followRedirects, isFalse);
        return http.StreamedResponse(
          const Stream.empty(),
          HttpStatus.found,
          headers: {'location': 'https://evil.example/steal'},
        );
      }),
    );

    await expectLater(
      transport.headDownload(
        url: Uri.parse('https://mac.example/download'),
        token: token,
        cancellation: FileTransferCancellation(),
      ),
      throwsA(
        isA<FileTransferHttpException>().having(
          (error) => error.statusCode,
          'statusCode',
          HttpStatus.found,
        ),
      ),
    );
    expect(calls, 1);
  });

  test(
    'upload HEAD consumes non-200 and invalid-header response bodies',
    () async {
      var non200Consumed = false;
      var invalidConsumed = false;
      var call = 0;
      final transport = FileTransferHttpTransport(
        MockClient.streaming((request, body) async {
          call++;
          if (call == 1) {
            return http.StreamedResponse(
              Stream.value(const [1]).map((chunk) {
                non200Consumed = true;
                return chunk;
              }),
              HttpStatus.serviceUnavailable,
            );
          }
          return http.StreamedResponse(
            Stream.value(const [2]).map((chunk) {
              invalidConsumed = true;
              return chunk;
            }),
            HttpStatus.ok,
            headers: const {'upload-complete': '0'},
          );
        }),
      );

      await expectLater(
        transport.headUpload(
          url: Uri.parse('https://mac.example/upload'),
          token: token,
          cancellation: FileTransferCancellation(),
        ),
        throwsA(
          isA<FileTransferHttpException>().having(
            (error) => error.statusCode,
            'statusCode',
            HttpStatus.serviceUnavailable,
          ),
        ),
      );
      await expectLater(
        transport.headUpload(
          url: Uri.parse('https://mac.example/upload'),
          token: token,
          cancellation: FileTransferCancellation(),
        ),
        throwsA(isA<FileTransferHttpException>()),
      );
      expect(non200Consumed, isTrue);
      expect(invalidConsumed, isTrue);
    },
  );

  test('download 206 header mismatch aborts the live response', () async {
    final partial = File('${root.path}/mismatch.part');
    await partial.create();
    Future<void>? abortTrigger;
    final transport = FileTransferHttpTransport(
      MockClient.streaming((request, body) async {
        abortTrigger = (request as http.Abortable).abortTrigger;
        return http.StreamedResponse(
          const Stream.empty(),
          HttpStatus.partialContent,
          contentLength: 2,
          headers: {
            'content-length': '2',
            'content-range': 'bytes 0-1/999',
            'etag': etag,
          },
        );
      }),
    );

    await expectLater(
      transport.downloadChunk(
        url: Uri.parse('https://mac.example/download'),
        token: token,
        etag: etag,
        partial: partial,
        offset: 0,
        endInclusive: 1,
        totalSizeBytes: 2,
        cancellation: FileTransferCancellation(),
      ),
      throwsA(
        isA<FileTransferHttpException>().having(
          (error) => error.code,
          'code',
          'download_range_mismatch',
        ),
      ),
    );
    await abortTrigger!.timeout(const Duration(seconds: 1));
    expect(await partial.length(), 0);
  });

  test(
    'upload PATCH streams only the requested offset without repetition',
    () async {
      final staged = File('${root.path}/upload.stage');
      await staged.writeAsBytes(const [1, 2, 3, 4]);
      final bodies = <List<int>>[];
      final transport = FileTransferHttpTransport(
        MockClient.streaming((request, body) async {
          expect(request.method, 'PATCH');
          expect(request.followRedirects, isFalse);
          expect(request.headers['upload-offset'], '2');
          expect(
            request.headers['content-type'],
            'application/offset+octet-stream',
          );
          bodies.add(await body.toBytes());
          return http.StreamedResponse(
            const Stream.empty(),
            HttpStatus.noContent,
            headers: {'upload-offset': '4', 'upload-complete': '1'},
          );
        }),
      );

      final result = await transport.uploadChunk(
        url: Uri.parse('https://mac.example/upload'),
        token: token,
        stagedFile: staged,
        offset: 2,
        chunkLength: 2,
        totalSizeBytes: 4,
        cancellation: FileTransferCancellation(),
      );

      expect(bodies, [
        const [3, 4],
      ]);
      expect(result.uploadOffset, 4);
      expect(result.complete, isTrue);
    },
  );
}
