import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ccpocket/features/artifact_preview/artifact_quick_look_service.dart';
import 'package:ccpocket/features/file_transfer/file_transfer_service.dart';
import 'package:ccpocket/features/file_transfer/file_transfer_sheet.dart';
import 'package:ccpocket/features/file_transfer/file_transfer_storage.dart';
import 'package:ccpocket/features/file_transfer/received_file_inbox_banner.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _transferId = '123e4567-e89b-12d3-a456-426614174000';
const _token = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _etag = '"EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE"';

void main() {
  late Directory root;
  late Directory support;
  late Directory downloads;
  late FileTransferStorage storage;
  late _MemorySecrets secrets;
  late _UiBridge bridge;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('ccpocket-transfer-ui-');
    support = Directory('${root.path}/support')..createSync(recursive: true);
    downloads = Directory('${root.path}/downloads')
      ..createSync(recursive: true);
    secrets = _MemorySecrets();
    storage = FileTransferStorage(
      applicationSupportDirectory: () async => support,
      downloadsDirectory: () async => downloads,
      secretStore: secrets,
      clock: () => DateTime.utc(2026, 7, 18, 12),
    );
    bridge = _UiBridge();
  });

  tearDown(() async {
    await bridge.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  FileTransferService makeService({
    required http.Client client,
    FileTransferDocumentPicker picker = const _Picker(null),
    SharedPreferences? preferences,
    bool platformSupported = true,
    bool receivedFileExportSupported = false,
  }) => FileTransferService(
    bridge: bridge,
    storage: storage,
    picker: picker,
    capacity: const _Capacity(),
    commit: const _Commit(),
    platformSupported: platformSupported,
    receivedFileExportSupported: receivedFileExportSupported,
    httpClient: client,
    preferences: preferences,
    clock: () => DateTime.utc(2026, 7, 18, 12),
    requestIdGenerator: _Ids().next,
  );

  testWidgets('old Bridge stays disabled with a clear fallback', (
    tester,
  ) async {
    bridge.capabilityValues = const {};
    final service = makeService(
      client: MockClient((_) async => http.Response('', 500)),
    );
    await _pumpTile(tester, service);

    await tester.tap(find.byKey(const ValueKey('file_transfer_settings_tile')));
    await tester.pumpAndSettle();

    expect(find.text('File Transfer V2 unavailable'), findsOneWidget);
    expect(find.text('15 GiB per file · streamed in chunks'), findsOneWidget);
    final upload = tester.widget<FilledButton>(
      find.byKey(const ValueKey('file_transfer_upload_button')),
    );
    expect(upload.onPressed, isNull);
    expect(tester.takeException(), isNull);
    service.dispose();
  });

  testWidgets('unsupported iPhone build is detected before upload is offered', (
    tester,
  ) async {
    final service = makeService(
      platformSupported: false,
      client: MockClient((_) async => http.Response('', 500)),
    );
    await _pumpTile(tester, service);

    await tester.tap(find.byKey(const ValueKey('file_transfer_settings_tile')));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'This iPhone system or app build does not support File Transfer',
      ),
      findsOneWidget,
    );
    final upload = tester.widget<FilledButton>(
      find.byKey(const ValueKey('file_transfer_upload_button')),
    );
    expect(upload.onPressed, isNull);
    expect(bridge.sent, isEmpty);
    service.dispose();
  });

  testWidgets('auto-resume off exposes and runs the queued-start action', (
    tester,
  ) async {
    late FileTransferService service;
    await tester.runAsync(() async {
      SharedPreferences.setMockInitialValues({
        'file_transfer_v2_auto_resume': false,
      });
      final preferences = await SharedPreferences.getInstance();
      final checkpoint = storage.newReceiveCheckpoint(
        logicalIdentity: 'machine-1',
        offer: _offer(sizeBytes: 3),
      );
      await storage.initializeReceive(checkpoint);
      await storage.writeDownloadSecret(
        checkpoint,
        const DownloadTransferSecret(
          downloadUrl:
              'https://mac.example/api/file-transfers/downloads/$_transferId',
          downloadToken: _token,
          logicalBridgeIdentity: 'machine-1',
        ),
      );
      bridge.autoDownloadResumeSize = 3;
      service = makeService(
        preferences: preferences,
        client: MockClient.streaming((request, body) async {
          if (request.method == 'HEAD') {
            return _downloadHead(3);
          }
          return http.StreamedResponse(
            Stream.value(const [1, 2, 3]),
            HttpStatus.partialContent,
            contentLength: 3,
            headers: {
              'content-length': '3',
              'content-range': 'bytes 0-2/3',
              'etag': _etag,
            },
          );
        }),
      );
      await service.initialize();
      await _waitUntil(() => service.queuedTransferCount == 1);
    });
    await _pumpSheet(tester, service);

    final startFinder = find.widgetWithText(
      OutlinedButton,
      'Start 1 queued transfer(s)',
    );
    expect(startFinder, findsOneWidget);
    final start = tester.widget<OutlinedButton>(startFinder);
    expect(start.onPressed, isNotNull);
    await tester.runAsync(() async {
      start.onPressed!();
      await _waitUntil(() => service.recentResults.isNotEmpty);
    });
    expect(
      service.recentResults.first.status,
      FileTransferStatus.succeeded,
      reason:
          '${service.recentResults.first.errorCode}: ${service.recentResults.first.error}',
    );
    await tester.pump();

    expect(find.textContaining('Completed'), findsOneWidget);
    service.dispose();
  });

  testWidgets('active transfer changes Pause to Resume and confirms cancel', (
    tester,
  ) async {
    late FileTransferService service;
    late Future<void> upload;
    await tester.runAsync(() async {
      final pickerRoot = await storage.pickerStagingDirectory();
      final picked = File('${pickerRoot.path}/picked.bin');
      await picked.writeAsBytes(const [1]);
      service = makeService(
        client: MockClient.streaming((request, body) async {
          throw StateError('HTTP must not run before upload ready');
        }),
        picker: _Picker(
          FileTransferSelection(
            path: picked.path,
            filename: 'picked.bin',
            sizeBytes: 1,
          ),
        ),
      );
      upload = service.uploadToMac();
      await _waitUntil(
        () => bridge.sent.any(
          (json) => json['type'] == 'file_transfer_upload_prepare_v2',
        ),
      );
    });
    await _pumpSheet(tester, service);
    expect(find.text('Pause'), findsOneWidget);

    await tester.tap(find.text('Pause'));
    await tester.runAsync(() => upload);
    await tester.pump();
    expect(find.text('Resume'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Completed files are never deleted'),
      findsOneWidget,
    );
    expect(find.widgetWithText(FilledButton, 'Cancel'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(TextButton, 'Cancel'),
      ),
    );
    await tester.pumpAndSettle();
    service.dispose();
  });

  testWidgets('15 GiB progress layout stays bounded on a narrow phone', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late FileTransferService service;
    late Future<void> upload;
    await tester.runAsync(() async {
      final pickerRoot = await storage.pickerStagingDirectory();
      final picked = File('${pickerRoot.path}/maximum.bin');
      final handle = await picked.open(mode: FileMode.write);
      await handle.truncate(maxFileTransferBytes);
      await handle.close();
      service = makeService(
        client: MockClient.streaming((request, requestBody) async {
          throw StateError('HTTP must not run before upload ready');
        }),
        picker: _Picker(
          FileTransferSelection(
            path: picked.path,
            filename:
                'a-very-long-file-name-that-must-not-overflow-the-phone.bin',
            sizeBytes: maxFileTransferBytes,
          ),
        ),
      );
      upload = service.uploadToMac();
      await _waitUntil(() => service.activeTransfer != null);
    });
    await _pumpSheet(tester, service);
    await tester.drag(find.byType(ListView), const Offset(0, -220));
    await tester.pump();

    expect(find.textContaining('15.00 GiB'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(tester.takeException(), isNull);

    service.pauseActive();
    await tester.runAsync(() => upload);
    service.dispose();
  });

  testWidgets('received inbox exposes preview share and compatible save', (
    tester,
  ) async {
    late FileTransferService service;
    await tester.runAsync(() async {
      await File('${downloads.path}/report.pdf').writeAsBytes(const [1, 2]);
      service = makeService(
        receivedFileExportSupported: true,
        client: MockClient((_) async => http.Response('', 500)),
      );
      await service.refreshReceivedFiles();
    });

    await _pumpSheet(tester, service);

    expect(find.text('Files received from Mac'), findsOneWidget);
    expect(find.text('report.pdf'), findsOneWidget);
    expect(
      find.byKey(
        ValueKey('preview_received_file_${downloads.path}/report.pdf'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey('share_received_file_${downloads.path}/report.pdf')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey('save_received_file_${downloads.path}/report.pdf')),
      findsOneWidget,
    );
    service.dispose();
  });

  testWidgets('preview routes ineligible files to share instead of QuickLook', (
    tester,
  ) async {
    final quickLookCalls = <MethodCall>[];
    final shareCalls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('ccpocket/artifact_quick_look'),
      (call) async {
        quickLookCalls.add(call);
        return null;
      },
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/share'),
      (call) async {
        shareCalls.add(call);
        return 'dev.fluttercommunity.plus/share/success';
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('ccpocket/artifact_quick_look'),
        null,
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/share'),
        null,
      );
    });

    late FileTransferService service;
    await tester.runAsync(() async {
      await File('${downloads.path}/page.html').writeAsString('<p>hi</p>');
      await File('${downloads.path}/notes.txt').writeAsString('plain');
      service = makeService(
        client: MockClient((_) async => http.Response('', 500)),
      );
      await service.refreshReceivedFiles();
    });
    await _pumpSheet(tester, service);

    await tester.tap(
      find.byKey(ValueKey('preview_received_file_${downloads.path}/page.html')),
    );
    await tester.pump();
    expect(quickLookCalls, isEmpty);
    expect(shareCalls, hasLength(1));

    await tester.tap(
      find.byKey(ValueKey('preview_received_file_${downloads.path}/notes.txt')),
    );
    await tester.pump();
    expect(quickLookCalls, hasLength(1));
    expect(shareCalls, hasLength(1));

    service.dispose();
  });

  testWidgets('large local received files still use native Quick Look', (
    tester,
  ) async {
    final quickLookCalls = <MethodCall>[];
    final shareCalls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('ccpocket/artifact_quick_look'),
      (call) async {
        quickLookCalls.add(call);
        return null;
      },
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/share'),
      (call) async {
        shareCalls.add(call);
        return 'dev.fluttercommunity.plus/share/success';
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('ccpocket/artifact_quick_look'),
        null,
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/share'),
        null,
      );
    });

    late FileTransferService service;
    await tester.runAsync(() async {
      final largePdf = await File(
        '${downloads.path}/large.pdf',
      ).open(mode: FileMode.write);
      await largePdf.truncate(artifactQuickLookAutomaticMaxBytes + 1);
      await largePdf.close();
      service = makeService(
        client: MockClient((_) async => http.Response('', 500)),
      );
      await service.refreshReceivedFiles();
    });
    await _pumpSheet(tester, service);

    await tester.tap(
      find.byKey(ValueKey('preview_received_file_${downloads.path}/large.pdf')),
    );
    await tester.pump();
    expect(quickLookCalls, hasLength(1));
    expect(shareCalls, isEmpty);
    service.dispose();
  });

  testWidgets('newly received file stays visible in the Home inbox banner', (
    tester,
  ) async {
    late FileTransferService service;
    await tester.runAsync(() async {
      await File('${downloads.path}/incoming.txt').writeAsBytes(const [1]);
      service = makeService(
        client: MockClient((_) async => http.Response('', 500)),
      );
      await service.refreshReceivedFiles();
    });
    await tester.pumpWidget(
      ChangeNotifierProvider<FileTransferService>.value(
        value: service,
        child: MaterialApp(
          home: Scaffold(body: ReceivedFileInboxBanner(service: service)),
        ),
      ),
    );

    expect(find.text('1 file(s) received from Mac'), findsOneWidget);
    expect(find.text('incoming.txt'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('dismiss_received_file_inbox_banner')),
    );
    await tester.pump();
    expect(service.unreadReceivedCount, 0);
    service.dispose();
  });
}

Future<void> _pumpTile(WidgetTester tester, FileTransferService service) =>
    tester.pumpWidget(
      ChangeNotifierProvider<FileTransferService>.value(
        value: service,
        child: const MaterialApp(
          locale: Locale('en'),
          home: Scaffold(body: FileTransferSettingsTile()),
        ),
      ),
    );

Future<void> _pumpSheet(WidgetTester tester, FileTransferService service) =>
    tester.pumpWidget(
      ChangeNotifierProvider<FileTransferService>.value(
        value: service,
        child: const MaterialApp(
          locale: Locale('en'),
          home: Scaffold(body: FileTransferSheet()),
        ),
      ),
    );

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 300; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw TimeoutException('state');
}

FileTransferOfferMessage _offer({required int sizeBytes}) =>
    FileTransferOfferMessage(
      transferId: _transferId,
      filename: 'a-very-long-file-name-that-must-not-overflow-the-phone.bin',
      mimeType: 'application/octet-stream',
      sizeBytes: sizeBytes,
      downloadUrl:
          'https://mac.example/api/file-transfers/downloads/$_transferId',
      downloadToken: _token,
      etag: _etag,
      expiresAt: '2026-07-19T12:00:00.000Z',
    );

http.StreamedResponse _downloadHead(int size) => http.StreamedResponse(
  const Stream.empty(),
  HttpStatus.ok,
  headers: {
    'content-length': '$size',
    'etag': _etag,
    'accept-ranges': 'bytes',
    'x-ccpocket-max-chunk-bytes': '${16 * 1024 * 1024}',
    'x-ccpocket-transfer-expires': '2026-07-19T12:00:00.000Z',
  },
);

class _UiBridge implements FileTransferBridgeGateway {
  final _messages = StreamController<LocalFeatureServerMessage>.broadcast();
  final _connections = StreamController<BridgeConnectionState>.broadcast();
  final _capabilities = StreamController<void>.broadcast();
  final sent = <Map<String, dynamic>>[];
  Set<String> capabilityValues = {fileTransferCapability};
  int? autoDownloadResumeSize;
  bool replyToCancel = false;

  @override
  bool get isConnected => true;
  @override
  String? get httpBaseUrl => 'https://mac.example';
  @override
  String? get logicalConnectionIdentity => 'machine-1';
  @override
  Set<String> get capabilities => capabilityValues;
  @override
  Stream<BridgeConnectionState> get connectionStatus => _connections.stream;
  @override
  Stream<void> get capabilityChanges => _capabilities.stream;
  @override
  Stream<LocalFeatureServerMessage> get messages => _messages.stream;

  void emit(LocalFeatureServerMessage message) => _messages.add(message);

  @override
  void send(ClientMessage message) {
    final json = jsonDecode(message.toJson()) as Map<String, dynamic>;
    sent.add(json);
    if (json['type'] == 'file_transfer_download_resume_v2') {
      scheduleMicrotask(() {
        emit(
          FileTransferDownloadResumedMessage(
            requestId: json['requestId'] as String,
            transferId: json['transferId'] as String,
            success: true,
            sizeBytes: autoDownloadResumeSize,
            etag: _etag,
            expiresAt: '2026-07-20T12:00:00.000Z',
          ),
        );
      });
    } else if (json['type'] == 'file_transfer_cancel_v2' && replyToCancel) {
      scheduleMicrotask(() {
        emit(
          FileTransferCancelResultMessage(
            requestId: json['requestId'] as String,
            transferId: json['transferId'] as String,
            direction: FileTransferCancelDirection.upload,
            success: true,
          ),
        );
      });
    }
  }

  Future<void> close() async {
    await _messages.close();
    await _connections.close();
    await _capabilities.close();
  }
}

class _Picker implements FileTransferDocumentPicker {
  final FileTransferSelection? value;
  const _Picker(this.value);
  @override
  Future<FileTransferSelection?> pickFile({required int maxSizeBytes}) async =>
      value;
}

class _Capacity implements FileTransferCapacityGateway {
  const _Capacity();
  @override
  Future<int?> availableCapacityBytes(String path) async =>
      maxFileTransferBytes + fileTransferStorageSafetyReserveBytes;
}

class _Commit implements FileTransferCommitGateway {
  const _Commit();
  @override
  Future<void> markTransient(String path) async {}
  @override
  Future<String> chooseFinalFilename({
    required String directoryPath,
    required String requestedFilename,
  }) async => requestedFilename;
  @override
  Future<FileTransferCommitProbeResult> probeCommit({
    required String partialPath,
    required String finalPath,
    String? expectedResourceIdentifier,
  }) async =>
      const FileTransferCommitProbeResult(FileTransferCommitProbe.ready);
  @override
  Future<String> linkNoClobber({
    required String partialPath,
    required String finalPath,
  }) async {
    await File(partialPath).copy(finalPath);
    return 'resource-1';
  }

  @override
  Future<void> finalizeLinkedCommit({
    required String partialPath,
    required String finalPath,
    required String expectedResourceIdentifier,
  }) async => File(partialPath).delete();
}

class _MemorySecrets implements FileTransferSecretStore {
  final values = <String, String>{};
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _Ids {
  var value = 0;
  String next() => 'request-${++value}-abcdefghijkl';
}
