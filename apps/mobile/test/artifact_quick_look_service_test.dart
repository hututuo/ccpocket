import 'dart:async';
import 'dart:io';

import 'package:ccpocket/features/artifact_preview/artifact_quick_look_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingGateway implements ArtifactQuickLookGateway {
  _RecordingGateway({this.onPreview});

  final Future<void> Function(String path, String title)? onPreview;
  var calls = 0;

  @override
  Future<void> previewFile({
    required String path,
    required String title,
  }) async {
    calls += 1;
    await onPreview?.call(path, title);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('recognizes the stable Office formats by extension and MIME type', () {
    for (final filename in <String>[
      'report.doc',
      'report.DOCX',
      'table.xls',
      'table.xlsx',
      'slides.ppt',
      'slides.pptx',
      'notes.rtf',
    ]) {
      expect(
        isOfficeArtifactForQuickLook(filename, 'application/octet-stream'),
        isTrue,
        reason: filename,
      );
    }

    expect(
      isOfficeArtifactForQuickLook(
        'download',
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet; charset=binary',
      ),
      isTrue,
    );
    expect(
      isOfficeArtifactForQuickLook('report.pdf', 'application/pdf'),
      isFalse,
    );
    expect(isOfficeArtifactForQuickLook('notes.txt', 'text/plain'), isFalse);
  });

  test(
    'method channel gateway sends only the native preview contract',
    () async {
      const channel = MethodChannel('ccpocket/artifact_quick_look_test');
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'previewFile');
            expect(call.arguments, <String, String>{
              'path': '/tmp/report.xlsx',
              'title': '报告.xlsx',
            });
            return true;
          });

      await const MethodChannelArtifactQuickLookGateway(
        channel,
      ).previewFile(path: '/tmp/report.xlsx', title: '报告.xlsx');
    },
  );

  test('temporary preview file is deleted after Quick Look closes', () async {
    final directory = await Directory.systemTemp.createTemp(
      'ccpocket-quick-look-success-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/report.xlsx');
    final gateway = _RecordingGateway(
      onPreview: (path, title) async {
        expect(path, file.path);
        expect(title, 'report.xlsx');
        expect(await File(path).exists(), isTrue);
      },
    );
    final service = ArtifactQuickLookService(gateway: gateway);

    await service.previewTemporaryArtifact(
      prepareFile: () async {
        await file.writeAsBytes(<int>[1, 2, 3]);
        return file;
      },
      title: 'report.xlsx',
      isCancelled: () => false,
    );

    expect(gateway.calls, 1);
    expect(await file.exists(), isFalse);
  });

  test('temporary preview file is deleted when native preview fails', () async {
    final directory = await Directory.systemTemp.createTemp(
      'ccpocket-quick-look-failure-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/report.pptx');
    final gateway = _RecordingGateway(
      onPreview: (_, _) async {
        throw PlatformException(code: 'preview_failed');
      },
    );
    final service = ArtifactQuickLookService(gateway: gateway);

    await expectLater(
      service.previewTemporaryArtifact(
        prepareFile: () async {
          await file.writeAsBytes(<int>[4, 5, 6]);
          return file;
        },
        title: 'report.pptx',
        isCancelled: () => false,
      ),
      throwsA(isA<PlatformException>()),
    );

    expect(gateway.calls, 1);
    expect(await file.exists(), isFalse);
  });

  test('prepare cancellation never calls the native gateway', () async {
    final gateway = _RecordingGateway();
    final service = ArtifactQuickLookService(gateway: gateway);

    await expectLater(
      service.previewTemporaryArtifact(
        prepareFile: () => throw const FileSystemException('cancelled'),
        title: 'report.docx',
        isCancelled: () => true,
      ),
      throwsA(isA<FileSystemException>()),
    );

    expect(gateway.calls, 0);
  });

  test(
    'handoff cancellation skips native preview and deletes the prepared file',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'ccpocket-quick-look-handoff-cancel-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/report.xlsx');
      await file.writeAsBytes(<int>[7, 8, 9]);
      final prepared = Completer<File>();
      final gateway = _RecordingGateway();
      final service = ArtifactQuickLookService(gateway: gateway);
      var cancelled = false;

      final preview = service.previewTemporaryArtifact(
        prepareFile: () => prepared.future,
        title: 'report.xlsx',
        isCancelled: () => cancelled,
      );
      cancelled = true;
      prepared.complete(file);
      await preview;

      expect(gateway.calls, 0);
      expect(await file.exists(), isFalse);
    },
  );
}
