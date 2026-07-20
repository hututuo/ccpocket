import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ccpocket/features/file_transfer/file_transfer_service.dart';
import 'package:ccpocket/features/file_transfer/file_transfer_http.dart';
import 'package:ccpocket/features/file_transfer/file_transfer_storage.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const transferId = '123e4567-e89b-12d3-a456-426614174000';
const token = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const replayToken = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';
const etag = '"EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE"';
const changedEtag = '"FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"';

DateTime _fixtureNow() => DateTime.utc(2026, 7, 18, 12);

void main() {
  late Directory root;
  late Directory support;
  late Directory downloads;
  late _MemorySecretStore secrets;
  late FileTransferStorage storage;
  late _FakeBridge bridge;
  late _FakeNotifications notifications;

  FileTransferService createService({
    required http.Client client,
    FileTransferDocumentPicker? picker,
    SharedPreferences? preferences,
    FileTransferStorage? storageOverride,
    FileTransferNotificationGateway? notificationsOverride,
    DateTime Function()? clock,
    Duration completionRecoveryRetryDelay = const Duration(seconds: 5),
    int completionRecoveryRetryLimit = fileTransferCompletionRecoveryRetryLimit,
    Duration completionRecoveryMaxRetryDelay =
        fileTransferCompletionRecoveryMaxRetryDelay,
  }) => FileTransferService(
    bridge: bridge,
    storage: storageOverride ?? storage,
    picker: picker ?? const _FakePicker(null),
    capacity: const _FakeCapacity(),
    commit: const _FakeCommit(),
    platformSupported: true,
    notifications: notificationsOverride ?? notifications,
    httpClient: client,
    preferences: preferences,
    clock: clock ?? _fixtureNow,
    requestIdGenerator: _SequenceIds().next,
    completionRecoveryRetryDelay: completionRecoveryRetryDelay,
    completionRecoveryRetryLimit: completionRecoveryRetryLimit,
    completionRecoveryMaxRetryDelay: completionRecoveryMaxRetryDelay,
  );

  Future<ReceiveTransferCheckpoint> seedCompletedReceive({
    bool notificationPending = false,
  }) async {
    final checkpoint = storage
        .newReceiveCheckpoint(logicalIdentity: 'machine-1', offer: _offer())
        .copyWith(
          receivedBytes: 3,
          commitState: 'complete',
          finalFilename: 'report.bin',
          finalResourceIdentifier: 'resource-1',
          notificationPending: notificationPending,
        );
    await (await storage.receivePartial(
      checkpoint,
    )).writeAsBytes(const [1, 2, 3]);
    await File('${downloads.path}/report.bin').writeAsBytes(const [1, 2, 3]);
    await storage.saveReceive(checkpoint);
    await storage.writeDownloadSecret(
      checkpoint,
      const DownloadTransferSecret(
        downloadUrl:
            'https://mac.example/api/file-transfers/downloads/$transferId',
        downloadToken: token,
        logicalBridgeIdentity: 'machine-1',
      ),
    );
    return checkpoint;
  }

  Future<ReceiveTransferCheckpoint> seedCommittingReceive({
    required bool finalAlreadyLinked,
  }) async {
    final checkpoint = storage
        .newReceiveCheckpoint(logicalIdentity: 'machine-1', offer: _offer())
        .copyWith(
          receivedBytes: 3,
          commitState: 'committing',
          finalFilename: 'report.bin',
          finalResourceIdentifier: finalAlreadyLinked ? 'resource-1' : null,
        );
    await (await storage.receivePartial(
      checkpoint,
    )).writeAsBytes(const [1, 2, 3]);
    if (finalAlreadyLinked) {
      await File('${downloads.path}/report.bin').writeAsBytes(const [1, 2, 3]);
    }
    await storage.saveReceive(checkpoint);
    await storage.writeDownloadSecret(
      checkpoint,
      const DownloadTransferSecret(
        downloadUrl:
            'https://mac.example/api/file-transfers/downloads/$transferId',
        downloadToken: token,
        logicalBridgeIdentity: 'machine-1',
      ),
    );
    return checkpoint;
  }

  Future<void> seedPendingReceives(int count) async {
    for (var index = 0; index < count; index++) {
      final id = '00000000-0000-4000-8000-${index.toString().padLeft(12, '0')}';
      final checkpoint = storage.newReceiveCheckpoint(
        logicalIdentity: 'machine-1',
        offer: FileTransferOfferMessage(
          transferId: id,
          filename: 'batch-$index.bin',
          mimeType: 'application/octet-stream',
          sizeBytes: 1,
          downloadUrl: 'https://mac.example/api/file-transfers/downloads/$id',
          downloadToken: token,
          etag: etag,
          expiresAt: '2026-07-19T12:00:00.000Z',
        ),
      );
      await storage.initializeReceive(checkpoint);
      await storage.writeDownloadSecret(
        checkpoint,
        DownloadTransferSecret(
          downloadUrl: 'https://mac.example/api/file-transfers/downloads/$id',
          downloadToken: token,
          logicalBridgeIdentity: 'machine-1',
        ),
      );
    }
  }

  http.Client oneByteDownloadClient() =>
      MockClient.streaming((request, body) async {
        if (request.method == 'HEAD') {
          return http.StreamedResponse(
            const Stream.empty(),
            HttpStatus.ok,
            headers: {
              'content-length': '1',
              'etag': etag,
              'accept-ranges': 'bytes',
              'x-ccpocket-max-chunk-bytes': '16777216',
              'x-ccpocket-transfer-expires': '2026-07-19T12:00:00.000Z',
            },
          );
        }
        expect(request.headers['range'], 'bytes=0-0');
        return http.StreamedResponse(
          Stream.value(const [1]),
          HttpStatus.partialContent,
          contentLength: 1,
          headers: {
            'content-length': '1',
            'content-range': 'bytes 0-0/1',
            'etag': etag,
          },
        );
      });

  Future<void> expectRejectedUploadConfirmation({
    required String? filename,
    required int? sizeBytes,
  }) async {
    final pickerRoot = await storage.pickerStagingDirectory();
    final picked = File('${pickerRoot.path}/unconfirmed.bin');
    await picked.writeAsBytes(const [9]);
    String? requestId;
    String? stableTransferId;
    String? resumeToken;
    final client = MockClient.streaming((request, body) async {
      if (request.method == 'HEAD') {
        return http.StreamedResponse(
          const Stream.empty(),
          HttpStatus.ok,
          headers: {
            'upload-offset': '0',
            'upload-length': '1',
            'upload-expires': '2026-07-19T12:00:00.000Z',
            'upload-complete': '0',
            'x-ccpocket-max-chunk-bytes': '16777216',
          },
        );
      }
      expect(await body.toBytes(), [9]);
      scheduleMicrotask(() {
        bridge.emit(
          FileTransferUploadResultMessage(
            requestId: requestId!,
            transferId: stableTransferId!,
            success: true,
            filename: filename,
            sizeBytes: sizeBytes,
          ),
        );
      });
      return http.StreamedResponse(
        const Stream.empty(),
        HttpStatus.noContent,
        headers: {'upload-offset': '1', 'upload-complete': '1'},
      );
    });
    final service = createService(
      client: client,
      picker: _FakePicker(
        FileTransferSelection(
          path: picked.path,
          filename: 'unconfirmed.bin',
          sizeBytes: 1,
        ),
      ),
    );
    bridge.onSend = (json) {
      if (json['type'] != 'file_transfer_upload_prepare_v2') return;
      requestId = json['requestId'] as String;
      stableTransferId = json['transferId'] as String;
      resumeToken = json['resumeToken'] as String;
      scheduleMicrotask(() {
        bridge.emit(
          FileTransferUploadReadyMessage(
            requestId: requestId!,
            transferId: stableTransferId!,
            uploadUrl:
                'https://mac.example/api/file-transfers/uploads/$stableTransferId',
            uploadToken: token,
            resumeToken: resumeToken!,
            uploadOffset: 0,
            sizeBytes: 1,
            maxChunkSizeBytes: fileTransferChunkBytes,
            expiresAt: '2026-07-19T12:00:00.000Z',
          ),
        );
      });
    };

    await service.uploadToMac();

    expect(service.recentResults.first.status, FileTransferStatus.failed);
    expect(service.recentResults.first.errorCode, 'upload_failed');
    final retained = (await storage.loadUploads('machine-1')).single;
    expect(await (await storage.uploadStaged(retained)).exists(), isTrue);
    service.dispose();
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('ccpocket-v2-service-');
    support = Directory('${root.path}/support')..createSync(recursive: true);
    downloads = Directory('${root.path}/downloads')
      ..createSync(recursive: true);
    secrets = _MemorySecretStore();
    storage = FileTransferStorage(
      applicationSupportDirectory: () async => support,
      downloadsDirectory: () async => downloads,
      secretStore: secrets,
      clock: () => DateTime.utc(2026, 7, 18, 12),
    );
    bridge = _FakeBridge();
    notifications = _FakeNotifications();
  });

  tearDown(() async {
    await bridge.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
    'auto-receive is idempotent and persists a completion tombstone',
    () async {
      var getCount = 0;
      final client = MockClient.streaming((request, body) async {
        if (request.method == 'HEAD') {
          return http.StreamedResponse(
            const Stream.empty(),
            HttpStatus.ok,
            headers: {
              'content-length': '3',
              'etag': etag,
              'accept-ranges': 'bytes',
              'x-ccpocket-max-chunk-bytes': '16777216',
              'x-ccpocket-transfer-expires': '2026-07-19T12:00:00.000Z',
            },
          );
        }
        getCount++;
        return http.StreamedResponse(
          Stream.value(const [1, 2, 3]),
          HttpStatus.partialContent,
          contentLength: 3,
          headers: {
            'content-length': '3',
            'content-range': 'bytes 0-2/3',
            'etag': etag,
          },
        );
      });
      final service = createService(client: client);

      bridge.emit(_offer());
      await _waitUntil(
        () => service.recentResults.any(
          (item) => item.status == FileTransferStatus.succeeded,
        ),
      );
      expect(await File('${downloads.path}/report.bin').readAsBytes(), [
        1,
        2,
        3,
      ]);
      expect(getCount, 1);
      expect(notifications.receivedNames, ['report.bin']);
      final firstAck = bridge.sentJson.lastWhere(
        (json) => json['type'] == 'file_transfer_receive_result_v2',
      );
      expect(firstAck['success'], isTrue);

      bridge.emit(_offer());
      await _waitUntil(
        () =>
            bridge.sentJson
                .where(
                  (json) => json['type'] == 'file_transfer_receive_result_v2',
                )
                .length ==
            2,
      );
      expect(getCount, 1);
      expect(downloads.listSync().whereType<File>(), hasLength(1));
      final tombstone = (await storage.loadReceives('machine-1')).single;
      expect(tombstone.commitState, 'complete');
      expect(tombstone.finalFilename, 'report.bin');
      expect(await storage.readDownloadSecret(tombstone), isNotNull);

      bridge.emit(_offer(sourceEtag: changedEtag));
      await _waitUntil(
        () =>
            bridge.sentJson
                .where(
                  (json) => json['type'] == 'file_transfer_receive_result_v2',
                )
                .length ==
            3,
      );
      final rejectedReplay = bridge.sentJson.last;
      expect(rejectedReplay['success'], isFalse);
      expect(rejectedReplay['errorCode'], 'source_identity_changed');
      expect(getCount, 1);
      expect(
        (await storage.readDownloadSecret(tombstone))!.downloadToken,
        token,
      );
      service.dispose();
    },
  );

  test(
    'stored completion finishes automatically while manual bytes stay queued',
    () async {
      final tombstone = await seedCompletedReceive();
      SharedPreferences.setMockInitialValues({
        'file_transfer_v2_auto_resume': false,
      });
      final preferences = await SharedPreferences.getInstance();
      final service = createService(
        client: oneByteDownloadClient(),
        preferences: preferences,
      );
      const pendingId = '00000000-0000-4000-8000-999999999999';
      bridge.emit(
        const FileTransferOfferMessage(
          transferId: pendingId,
          filename: 'pending.bin',
          mimeType: 'application/octet-stream',
          sizeBytes: 1,
          downloadUrl:
              'https://mac.example/api/file-transfers/downloads/$pendingId',
          downloadToken: token,
          etag: etag,
          expiresAt: '2026-07-19T12:00:00.000Z',
        ),
      );
      await _waitUntil(() => service.queuedReceiveCount == 1);

      bridge.emit(_offer(sourceEtag: changedEtag, downloadToken: replayToken));
      await _waitUntil(
        () => bridge.sentJson.any(
          (json) =>
              json['type'] == 'file_transfer_receive_result_v2' &&
              json['errorCode'] == 'source_identity_changed',
        ),
      );
      expect(service.queuedReceiveCount, 1);
      expect(
        (await storage.readDownloadSecret(tombstone))!.downloadToken,
        token,
      );

      bridge.emit(_offer(downloadToken: replayToken));
      await _waitUntil(
        () => bridge.sentJson.any(
          (json) =>
              json['type'] == 'file_transfer_receive_result_v2' &&
              json['success'] == true,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(service.queuedReceiveCount, 1);
      expect(service.queuedReceiveBytes, 1);
      expect(service.recentResults.first.status, FileTransferStatus.succeeded);
      expect(downloads.listSync().whereType<File>(), hasLength(1));
      expect(
        (await storage.readDownloadSecret(tombstone))!.downloadToken,
        replayToken,
      );
      service.dispose();
    },
  );

  test(
    'manual mode auto-finishes completion recovery without queue bytes',
    () async {
      await seedCompletedReceive();
      SharedPreferences.setMockInitialValues({
        'file_transfer_v2_auto_resume': false,
      });
      final preferences = await SharedPreferences.getInstance();
      bridge.autoDownloadResumeSize = 3;
      final service = createService(
        client: MockClient((_) async => http.Response('', 500)),
        preferences: preferences,
      );

      await service.initialize();
      await _waitUntil(
        () => service.recentResults.any(
          (item) => item.status == FileTransferStatus.succeeded,
        ),
      );

      expect(service.queuedReceiveCount, 0);
      expect(service.queuedReceiveBytes, 0);
      expect(service.recentResults.first.status, FileTransferStatus.succeeded);
      service.dispose();
    },
  );

  test(
    'completion recovery retries and durably clears a pending notification',
    () async {
      await seedCompletedReceive(notificationPending: true);
      SharedPreferences.setMockInitialValues({
        'file_transfer_v2_auto_resume': false,
      });
      final preferences = await SharedPreferences.getInstance();
      bridge.autoDownloadResumeSize = 3;
      final service = createService(
        client: MockClient((_) async => http.Response('', 500)),
        preferences: preferences,
      );

      await service.initialize();
      await _waitUntil(() => notifications.receivedNames.length == 1);
      await _waitUntilAsync(() async {
        final items = await storage.loadReceives('machine-1');
        return items.length == 1 && !items.single.notificationPending;
      });

      expect(notifications.receivedNames, ['report.bin']);
      expect(service.recentResults.first.status, FileTransferStatus.succeeded);
      service.dispose();
    },
  );

  test(
    'recovery rebuilds the download URL for the current same-machine origin',
    () async {
      final initialCheckpoint = storage.newReceiveCheckpoint(
        logicalIdentity: 'machine-1',
        offer: _offer(),
      );
      await storage.initializeReceive(initialCheckpoint);
      final partial = await storage.receivePartial(initialCheckpoint);
      await partial.writeAsBytes(const [1]);
      final checkpoint = initialCheckpoint.copyWith(receivedBytes: 1);
      await storage.saveReceive(checkpoint);
      await storage.writeDownloadSecret(
        checkpoint,
        const DownloadTransferSecret(
          downloadUrl:
              'https://old.example/api/file-transfers/downloads/$transferId',
          downloadToken: token,
          logicalBridgeIdentity: 'machine-1',
        ),
      );
      bridge.httpBaseUrlValue = 'https://new.example:9443';
      bridge.autoDownloadResumeSize = 3;
      final observedUrls = <Uri>[];
      final client = MockClient.streaming((request, body) async {
        observedUrls.add(request.url);
        expect(request.url.scheme, 'https');
        expect(request.url.host, 'new.example');
        expect(request.url.port, 9443);
        if (request.method == 'HEAD') {
          return http.StreamedResponse(
            const Stream.empty(),
            HttpStatus.ok,
            headers: {
              'content-length': '3',
              'etag': etag,
              'accept-ranges': 'bytes',
              'x-ccpocket-max-chunk-bytes': '16777216',
              'x-ccpocket-transfer-expires': '2026-07-19T12:00:00.000Z',
            },
          );
        }
        expect(request.headers['range'], 'bytes=1-2');
        return http.StreamedResponse(
          Stream.value(const [2, 3]),
          HttpStatus.partialContent,
          contentLength: 2,
          headers: {
            'content-length': '2',
            'content-range': 'bytes 1-2/3',
            'etag': etag,
          },
        );
      });
      final service = createService(client: client);

      await service.initialize();
      await _waitUntil(
        () => service.recentResults.any(
          (item) => item.status == FileTransferStatus.succeeded,
        ),
      );

      expect(observedUrls, hasLength(2));
      final tombstone = (await storage.loadReceives('machine-1')).single;
      expect(
        (await storage.readDownloadSecret(tombstone))!.downloadUrl,
        'https://new.example:9443/api/file-transfers/downloads/$transferId',
      );
      expect(await File('${downloads.path}/report.bin').readAsBytes(), [
        1,
        2,
        3,
      ]);
      service.dispose();
    },
  );

  test(
    'automatic recovery drains more than one bounded receive batch',
    () async {
      await seedPendingReceives(9);
      bridge.autoDownloadResumeSize = 1;
      final service = createService(client: oneByteDownloadClient());

      await service.initialize();
      await _waitUntil(() => service.recentResults.length == 9);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(
        service.recentResults,
        everyElement(
          isA<FileTransferRecord>().having(
            (item) => item.status,
            'status',
            FileTransferStatus.succeeded,
          ),
        ),
      );
      expect(service.queuedReceiveCount, 0);
      expect(service.queuedReceiveBytes, 0);
      expect(downloads.listSync().whereType<File>(), hasLength(9));
      expect(
        bridge.sentJson.where(
          (json) => json['type'] == 'file_transfer_download_resume_v2',
        ),
        hasLength(9),
      );
      service.dispose();
    },
  );

  test('manual recovery exposes the next bounded receive batch', () async {
    await seedPendingReceives(9);
    SharedPreferences.setMockInitialValues({
      'file_transfer_v2_auto_resume': false,
    });
    final preferences = await SharedPreferences.getInstance();
    bridge.autoDownloadResumeSize = 1;
    final service = createService(
      client: oneByteDownloadClient(),
      preferences: preferences,
    );

    await service.initialize();
    await _waitUntil(() => service.queuedReceiveCount == 8);
    expect(service.queuedReceiveBytes, 8);

    await service.startQueuedTransfers();
    await _waitUntil(
      () =>
          service.recentResults.length == 8 && service.queuedReceiveCount == 1,
    );
    expect(service.queuedReceiveBytes, 1);

    await service.startQueuedTransfers();
    await _waitUntil(() => service.recentResults.length == 9);
    expect(service.queuedReceiveCount, 0);
    expect(service.queuedReceiveBytes, 0);
    expect(downloads.listSync().whereType<File>(), hasLength(9));
    service.dispose();
  });

  test(
    'missing Bridge state still delivers a pending completion notification',
    () async {
      await seedCompletedReceive(notificationPending: true);
      bridge.onSend = (json) {
        if (json['type'] != 'file_transfer_download_resume_v2') return;
        scheduleMicrotask(() {
          bridge.emit(
            FileTransferDownloadResumedMessage(
              requestId: json['requestId'] as String,
              transferId: transferId,
              success: false,
              errorCode: 'download_not_found',
            ),
          );
        });
      };
      final service = createService(
        client: MockClient((_) async => http.Response('', 500)),
      );

      await service.initialize();
      await _waitUntil(() => notifications.receivedNames.length == 1);
      await _waitUntilAsync(
        () async => (await storage.loadReceives('machine-1')).isEmpty,
      );

      expect(notifications.receivedNames, ['report.bin']);
      expect(await File('${downloads.path}/report.bin').exists(), isTrue);
      expect(service.recentResults.first.status, FileTransferStatus.succeeded);
      service.dispose();
    },
  );

  test('explicit upload reveals a deferred manual receive batch', () async {
    await seedPendingReceives(9);
    SharedPreferences.setMockInitialValues({
      'file_transfer_v2_auto_resume': false,
    });
    final preferences = await SharedPreferences.getInstance();
    final pickerRoot = await storage.pickerStagingDirectory();
    final picked = File('${pickerRoot.path}/manual-upload.bin');
    await picked.writeAsBytes(const [9]);
    final picker = _FakePicker(
      FileTransferSelection(
        path: picked.path,
        filename: 'manual-upload.bin',
        sizeBytes: 1,
      ),
    );
    bridge.autoDownloadResumeSize = 1;
    String? uploadRequestId;
    String? uploadTransferId;
    String? uploadResumeToken;
    final client = MockClient.streaming((request, body) async {
      final isUpload = request.url.path.contains('/uploads/');
      if (isUpload && request.method == 'HEAD') {
        return http.StreamedResponse(
          const Stream.empty(),
          HttpStatus.ok,
          headers: {
            'upload-offset': '0',
            'upload-length': '1',
            'upload-expires': '2026-07-19T12:00:00.000Z',
            'upload-complete': '0',
            'x-ccpocket-max-chunk-bytes': '16777216',
          },
        );
      }
      if (isUpload) {
        expect(await body.toBytes(), [9]);
        scheduleMicrotask(() {
          bridge.emit(
            FileTransferUploadResultMessage(
              requestId: uploadRequestId!,
              transferId: uploadTransferId!,
              success: true,
              filename: 'manual-upload.bin',
              sizeBytes: 1,
            ),
          );
        });
        return http.StreamedResponse(
          const Stream.empty(),
          HttpStatus.noContent,
          headers: {'upload-offset': '1', 'upload-complete': '1'},
        );
      }
      if (request.method == 'HEAD') {
        return http.StreamedResponse(
          const Stream.empty(),
          HttpStatus.ok,
          headers: {
            'content-length': '1',
            'etag': etag,
            'accept-ranges': 'bytes',
            'x-ccpocket-max-chunk-bytes': '16777216',
            'x-ccpocket-transfer-expires': '2026-07-19T12:00:00.000Z',
          },
        );
      }
      return http.StreamedResponse(
        Stream.value(const [1]),
        HttpStatus.partialContent,
        contentLength: 1,
        headers: {
          'content-length': '1',
          'content-range': 'bytes 0-0/1',
          'etag': etag,
        },
      );
    });
    final service = createService(
      client: client,
      picker: picker,
      preferences: preferences,
    );
    bridge.onSend = (json) {
      if (json['type'] != 'file_transfer_upload_prepare_v2') return;
      uploadRequestId = json['requestId'] as String;
      uploadTransferId = json['transferId'] as String;
      uploadResumeToken = json['resumeToken'] as String;
      scheduleMicrotask(() {
        bridge.emit(
          FileTransferUploadReadyMessage(
            requestId: uploadRequestId!,
            transferId: uploadTransferId!,
            uploadUrl:
                'https://mac.example/api/file-transfers/uploads/$uploadTransferId',
            uploadToken: token,
            resumeToken: uploadResumeToken!,
            uploadOffset: 0,
            sizeBytes: 1,
            maxChunkSizeBytes: fileTransferChunkBytes,
            expiresAt: '2026-07-19T12:00:00.000Z',
          ),
        );
      });
    };

    await service.initialize();
    await _waitUntil(() => service.queuedReceiveCount == 8);
    await service.uploadToMac();
    await _waitUntil(() => service.queuedReceiveCount == 1);

    expect(service.queuedReceiveBytes, 1);
    expect(downloads.listSync().whereType<File>(), hasLength(8));
    expect(await storage.loadUploads('machine-1'), isEmpty);
    expect(await picked.exists(), isFalse);
    service.dispose();
  });

  test(
    'manual cancel reveals a deferred receive batch without running it',
    () async {
      await seedPendingReceives(9);
      SharedPreferences.setMockInitialValues({
        'file_transfer_v2_auto_resume': false,
      });
      final preferences = await SharedPreferences.getInstance();
      bridge.autoDownloadResumeSize = 1;
      var rangeAttempt = 0;
      final client = MockClient.streaming((request, body) async {
        if (request.method == 'HEAD') {
          return http.StreamedResponse(
            const Stream.empty(),
            HttpStatus.ok,
            headers: {
              'content-length': '1',
              'etag': etag,
              'accept-ranges': 'bytes',
              'x-ccpocket-max-chunk-bytes': '16777216',
              'x-ccpocket-transfer-expires': '2026-07-19T12:00:00.000Z',
            },
          );
        }
        rangeAttempt++;
        if (rangeAttempt >= 8) {
          return http.StreamedResponse(
            const Stream.empty(),
            HttpStatus.serviceUnavailable,
          );
        }
        return http.StreamedResponse(
          Stream.value(const [1]),
          HttpStatus.partialContent,
          contentLength: 1,
          headers: {
            'content-length': '1',
            'content-range': 'bytes 0-0/1',
            'etag': etag,
          },
        );
      });
      final service = createService(client: client, preferences: preferences);
      bridge.onSend = (json) {
        if (json['type'] != 'file_transfer_cancel_v2') return;
        scheduleMicrotask(() {
          bridge.emit(
            FileTransferCancelResultMessage(
              requestId: json['requestId'] as String,
              transferId: json['transferId'] as String,
              direction: FileTransferCancelDirection.download,
              success: true,
            ),
          );
        });
      };

      await service.initialize();
      await _waitUntil(() => service.queuedReceiveCount == 8);
      await service.startQueuedTransfers();
      expect(service.pausedTransfer, isNotNull);
      expect(service.queuedReceiveCount, 0);
      expect(downloads.listSync().whereType<File>(), hasLength(7));

      await service.cancelTransfer(service.pausedTransfer!.id);
      await _waitUntil(() => service.queuedReceiveCount == 1);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(service.pausedTransfer, isNull);
      expect(service.queuedReceiveCount, 1);
      expect(service.queuedReceiveBytes, 1);
      expect(downloads.listSync().whereType<File>(), hasLength(7));
      service.dispose();
    },
  );

  for (final finalAlreadyLinked in [false, true]) {
    test('committing recovery rebinds before acknowledgement '
        '(${finalAlreadyLinked ? 'linked' : 'ready'})', () async {
      await seedCommittingReceive(finalAlreadyLinked: finalAlreadyLinked);
      bridge.autoDownloadResumeSize = 3;
      final service = createService(
        client: MockClient((_) async => http.Response('', 500)),
      );

      await service.initialize();
      await _waitUntil(
        () => service.recentResults.any(
          (item) => item.status == FileTransferStatus.succeeded,
        ),
      );

      final transferMessages = bridge.sentJson
          .map((json) => json['type'])
          .whereType<String>()
          .toList();
      expect(
        transferMessages.indexOf('file_transfer_download_resume_v2'),
        lessThan(transferMessages.indexOf('file_transfer_receive_result_v2')),
      );
      expect(await File('${downloads.path}/report.bin').readAsBytes(), [
        1,
        2,
        3,
      ]);
      expect(service.queuedReceiveBytes, 0);
      service.dispose();
    });
  }

  test(
    'disconnect after commit rebinds before acknowledgement cleanup',
    () async {
      final client = MockClient.streaming((request, body) async {
        if (request.method == 'HEAD') {
          return http.StreamedResponse(
            const Stream.empty(),
            HttpStatus.ok,
            headers: {
              'content-length': '3',
              'etag': etag,
              'accept-ranges': 'bytes',
              'x-ccpocket-max-chunk-bytes': '16777216',
              'x-ccpocket-transfer-expires': '2026-07-19T12:00:00.000Z',
            },
          );
        }
        return http.StreamedResponse(
          Stream.value(const [1, 2, 3]),
          HttpStatus.partialContent,
          contentLength: 3,
          headers: {
            'content-length': '3',
            'content-range': 'bytes 0-2/3',
            'etag': etag,
          },
        );
      });
      final service = createService(client: client);
      bridge.throwOnSendOnce = true;

      bridge.emit(_offer());
      await _waitUntil(
        () => service.recentResults.any(
          (item) => item.status == FileTransferStatus.succeeded,
        ),
      );
      await _waitUntil(() => service.activeTransfer == null);
      final tombstone = (await storage.loadReceives('machine-1')).single;
      expect(await storage.readDownloadSecret(tombstone), isNotNull);
      expect(
        bridge.sentJson.where(
          (json) => json['type'] == 'file_transfer_receive_result_v2',
        ),
        isEmpty,
      );

      var resumeCount = 0;
      bridge.onSend = (json) {
        if (json['type'] != 'file_transfer_download_resume_v2') return;
        resumeCount++;
        scheduleMicrotask(() {
          bridge.emit(
            FileTransferDownloadResumedMessage(
              requestId: json['requestId'] as String,
              transferId: transferId,
              success: resumeCount == 1,
              sizeBytes: resumeCount == 1 ? 3 : null,
              etag: resumeCount == 1 ? etag : null,
              expiresAt: resumeCount == 1 ? '2026-08-01T12:00:00.000Z' : null,
              errorCode: resumeCount == 1 ? null : 'download_not_found',
            ),
          );
        });
      };

      bridge.setConnected(false);
      bridge.setConnected(true);
      await _waitUntil(
        () =>
            resumeCount == 1 &&
            bridge.sentJson.any(
              (json) => json['type'] == 'file_transfer_receive_result_v2',
            ),
      );
      await _waitUntil(() => service.activeTransfer == null);
      expect(await storage.readDownloadSecret(tombstone), isNotNull);
      expect(notifications.receivedNames, ['report.bin']);

      bridge.setConnected(false);
      bridge.setConnected(true);
      await _waitUntilAsync(
        () async =>
            resumeCount == 2 &&
            (await storage.loadReceives('machine-1')).isEmpty,
      );

      expect(await File('${downloads.path}/report.bin').readAsBytes(), [
        1,
        2,
        3,
      ]);
      expect(await storage.readDownloadSecret(tombstone), isNull);
      expect(service.queuedReceiveBytes, 0);
      service.dispose();
    },
  );

  test('unchanged capability events do not rescan transfer storage', () async {
    final countingStorage = _CountingFileTransferStorage(
      applicationSupportDirectory: () async => support,
      downloadsDirectory: () async => downloads,
      secretStore: secrets,
      clock: () => DateTime.utc(2026, 7, 18, 12),
    );
    final service = createService(
      client: MockClient((_) async => http.Response('', 500)),
      storageOverride: countingStorage,
    );

    await service.initialize();
    await _waitUntil(() => countingStorage.loadReceivesCount == 1);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    bridge.emitCapabilityEvent();
    bridge.emitCapabilityEvent();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(countingStorage.loadUploadsCount, 1);
    expect(countingStorage.loadReceivesCount, 1);

    bridge.setCapabilities({});
    bridge.emitCapabilityEvent();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(countingStorage.loadUploadsCount, 1);
    bridge.setCapabilities({fileTransferCapability});
    await _waitUntil(() => countingStorage.loadReceivesCount == 2);
    expect(countingStorage.loadUploadsCount, 2);
    service.dispose();
  });

  for (final changeOrigin in [false, true]) {
    test('machine switch clears manual queues without touching machine A '
        '${changeOrigin ? 'across origins' : 'on the same origin'}', () async {
      await seedPendingReceives(1);
      SharedPreferences.setMockInitialValues({
        'file_transfer_v2_auto_resume': false,
      });
      final preferences = await SharedPreferences.getInstance();
      var httpRequests = 0;
      final service = createService(
        client: MockClient.streaming((request, body) async {
          httpRequests++;
          if (request.method == 'HEAD') {
            return http.StreamedResponse(
              const Stream.empty(),
              HttpStatus.ok,
              headers: {
                'content-length': '1',
                'etag': etag,
                'accept-ranges': 'bytes',
                'x-ccpocket-max-chunk-bytes': '16777216',
                'x-ccpocket-transfer-expires': '2026-07-19T12:00:00.000Z',
              },
            );
          }
          return http.StreamedResponse(
            Stream.value(const [1]),
            HttpStatus.partialContent,
            contentLength: 1,
            headers: {
              'content-length': '1',
              'content-range': 'bytes 0-0/1',
              'etag': etag,
            },
          );
        }),
        preferences: preferences,
      );

      await service.initialize();
      await _waitUntil(() => service.queuedReceiveCount == 1);
      expect(service.queuedReceiveBytes, 1);
      final sentBeforeSwitch = bridge.sentJson.length;
      if (changeOrigin) bridge.httpBaseUrlValue = 'https://other.example';
      bridge.setLogicalIdentity('machine-2');
      await _waitUntil(
        () =>
            service.queuedReceiveCount == 0 && service.queuedReceiveBytes == 0,
      );

      await service.startQueuedTransfers();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(httpRequests, 0);
      expect(service.pausedTransfer, isNull);
      expect(await storage.loadReceives('machine-1'), hasLength(1));
      expect(await storage.loadReceives('machine-2'), isEmpty);
      expect(
        bridge.sentJson
            .skip(sentBeforeSwitch)
            .where(
              (json) =>
                  json.containsKey('downloadToken') ||
                  json.containsKey('resumeToken') ||
                  json.containsKey('uploadToken'),
            ),
        isEmpty,
      );

      bridge.httpBaseUrlValue = 'https://mac.example';
      bridge.autoDownloadResumeSize = 1;
      bridge.setLogicalIdentity('machine-1');
      await _waitUntil(() => service.queuedReceiveCount == 1);
      await service.startQueuedTransfers();
      await _waitUntil(
        () => service.recentResults.any(
          (item) => item.status == FileTransferStatus.succeeded,
        ),
      );
      expect(httpRequests, 2);
      service.dispose();
    });
  }

  test('A to null to C cannot leave an A queue blocking machine C', () async {
    SharedPreferences.setMockInitialValues({
      'file_transfer_v2_auto_resume': false,
    });
    final preferences = await SharedPreferences.getInstance();
    final requestHosts = <String>[];
    final requestTokens = <String?>[];
    final service = createService(
      client: MockClient.streaming((request, body) async {
        requestHosts.add(request.url.host);
        requestTokens.add(request.headers[fileTransferTokenHeader]);
        if (request.method == 'HEAD') {
          return http.StreamedResponse(
            const Stream.empty(),
            HttpStatus.ok,
            headers: {
              'content-length': '3',
              'etag': etag,
              'accept-ranges': 'bytes',
              'x-ccpocket-max-chunk-bytes': '16777216',
              'x-ccpocket-transfer-expires': '2026-07-19T12:00:00.000Z',
            },
          );
        }
        return http.StreamedResponse(
          Stream.value(const [1, 2, 3]),
          HttpStatus.partialContent,
          contentLength: 3,
          headers: {
            'content-length': '3',
            'content-range': 'bytes 0-2/3',
            'etag': etag,
          },
        );
      }),
      preferences: preferences,
    );

    bridge.emit(_offer());
    await _waitUntil(() => service.queuedReceiveCount == 1);
    bridge.setLogicalIdentity(null);
    await _waitUntil(() => service.queuedReceiveCount == 0);
    bridge.httpBaseUrlValue = 'https://machine-c.example';
    bridge.setLogicalIdentity('machine-3');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    const machineCTransferId = '323e4567-e89b-42d3-a456-426614174000';
    bridge.emit(
      _offer(
        id: machineCTransferId,
        downloadOrigin: 'https://machine-c.example',
        downloadToken: replayToken,
      ),
    );
    await _waitUntil(() => service.queuedReceiveCount == 1);
    await service.startQueuedTransfers();
    await _waitUntil(
      () => service.recentResults.any(
        (item) =>
            item.id == machineCTransferId &&
            item.status == FileTransferStatus.succeeded,
      ),
    );

    expect(requestHosts, everyElement('machine-c.example'));
    expect(requestTokens, everyElement(replayToken));
    expect(await storage.loadReceives('machine-1'), hasLength(1));
    expect(
      bridge.sentJson.where(
        (json) =>
            json['downloadToken'] == token || json['resumeToken'] == token,
      ),
      isEmpty,
    );
    service.dispose();
  });

  test(
    'same-machine origin change renews a queued receive before HTTP',
    () async {
      SharedPreferences.setMockInitialValues({
        'file_transfer_v2_auto_resume': false,
      });
      final preferences = await SharedPreferences.getInstance();
      final requestHosts = <String>[];
      final service = createService(
        client: MockClient.streaming((request, body) async {
          requestHosts.add(request.url.host);
          if (request.method == 'HEAD') {
            return http.StreamedResponse(
              const Stream.empty(),
              HttpStatus.ok,
              headers: {
                'content-length': '3',
                'etag': etag,
                'accept-ranges': 'bytes',
                'x-ccpocket-max-chunk-bytes': '16777216',
                'x-ccpocket-transfer-expires': '2026-07-19T12:00:00.000Z',
              },
            );
          }
          return http.StreamedResponse(
            Stream.value(const [1, 2, 3]),
            HttpStatus.partialContent,
            contentLength: 3,
            headers: {
              'content-length': '3',
              'content-range': 'bytes 0-2/3',
              'etag': etag,
            },
          );
        }),
        preferences: preferences,
      );

      bridge.emit(_offer());
      await _waitUntil(() => service.queuedReceiveCount == 1);
      bridge.setConnected(false);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final sentBeforeReconnect = bridge.sentJson.length;
      bridge.httpBaseUrlValue = 'https://new-route.example';
      bridge.autoDownloadResumeSize = 3;
      bridge.setConnected(true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await service.startQueuedTransfers();
      await _waitUntil(
        () => service.recentResults.any(
          (item) => item.status == FileTransferStatus.succeeded,
        ),
      );

      final types = bridge.sentJson
          .skip(sentBeforeReconnect)
          .map((json) => json['type'])
          .whereType<String>()
          .toList();
      expect(types.first, 'file_transfer_download_resume_v2');
      expect(
        types.indexOf('file_transfer_download_resume_v2'),
        lessThan(types.indexOf('file_transfer_receive_result_v2')),
      );
      expect(requestHosts, everyElement('new-route.example'));
      expect(
        service.recentResults.where(
          (item) => item.status == FileTransferStatus.failed,
        ),
        isEmpty,
      );
      service.dispose();
    },
  );

  test(
    'same-machine origin change rebinds completion before acknowledgement',
    () async {
      final checkpoint = await seedCompletedReceive(notificationPending: true);
      SharedPreferences.setMockInitialValues({
        'file_transfer_v2_auto_resume': false,
      });
      final preferences = await SharedPreferences.getInstance();
      final flakyNotifications = _FlakyNotifications();
      bridge.autoDownloadResumeSize = 3;
      final service = createService(
        client: MockClient.streaming((request, body) async {
          throw StateError('completion recovery must not transfer bytes');
        }),
        preferences: preferences,
        notificationsOverride: flakyNotifications,
        completionRecoveryRetryDelay: const Duration(seconds: 1),
      );

      await service.initialize();
      await _waitUntil(() => flakyNotifications.attempts == 1);
      await _waitUntil(() => service.activeTransfer == null);
      bridge.setConnected(false);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final sentBeforeReconnect = bridge.sentJson.length;
      bridge.httpBaseUrlValue = 'https://new-route.example';
      bridge.setConnected(true);
      await _waitUntil(() => flakyNotifications.attempts == 2);

      final types = bridge.sentJson
          .skip(sentBeforeReconnect)
          .map((json) => json['type'])
          .whereType<String>()
          .toList();
      expect(types.first, 'file_transfer_download_resume_v2');
      expect(
        types.indexOf('file_transfer_download_resume_v2'),
        lessThan(types.indexOf('file_transfer_receive_result_v2')),
      );
      final refreshed = await storage.readDownloadSecret(checkpoint);
      expect(refreshed?.downloadUrl, contains('new-route.example'));
      expect(flakyNotifications.receivedNames, ['report.bin']);
      service.dispose();
    },
  );

  test(
    'same-machine reconnect invalidates an awaiting offer and recovers its checkpoint',
    () async {
      final blockingStorage = _BlockingDownloadSecretWriteStorage(
        applicationSupportDirectory: () async => support,
        downloadsDirectory: () async => downloads,
        secretStore: secrets,
        clock: () => DateTime.utc(2026, 7, 18, 12),
      );
      SharedPreferences.setMockInitialValues({
        'file_transfer_v2_auto_resume': false,
      });
      final preferences = await SharedPreferences.getInstance();
      final requestHosts = <String>[];
      final service = createService(
        client: MockClient.streaming((request, body) async {
          requestHosts.add(request.url.host);
          if (request.method == 'HEAD') {
            return http.StreamedResponse(
              const Stream.empty(),
              HttpStatus.ok,
              headers: {
                'content-length': '3',
                'etag': etag,
                'accept-ranges': 'bytes',
                'x-ccpocket-max-chunk-bytes': '16777216',
                'x-ccpocket-transfer-expires': '2026-07-19T12:00:00.000Z',
              },
            );
          }
          return http.StreamedResponse(
            Stream.value(const [1, 2, 3]),
            HttpStatus.partialContent,
            contentLength: 3,
            headers: {
              'content-length': '3',
              'content-range': 'bytes 0-2/3',
              'etag': etag,
            },
          );
        }),
        preferences: preferences,
        storageOverride: blockingStorage,
      );

      bridge.emit(_offer());
      await blockingStorage.secretWritten.future.timeout(
        const Duration(seconds: 1),
      );
      bridge.setConnected(false);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final sentBeforeReconnect = bridge.sentJson.length;
      bridge.httpBaseUrlValue = 'https://new-route.example';
      bridge.autoDownloadResumeSize = 3;
      bridge.setConnected(true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      blockingStorage.releaseFirstSecretWrite.complete();
      await _waitUntil(() => service.queuedReceiveCount == 1);

      expect(
        bridge.sentJson
            .skip(sentBeforeReconnect)
            .where((json) => json['type'] == 'file_transfer_receive_result_v2'),
        isEmpty,
      );
      await service.startQueuedTransfers();
      await _waitUntil(
        () => service.recentResults.any(
          (item) => item.status == FileTransferStatus.succeeded,
        ),
      );

      final types = bridge.sentJson
          .skip(sentBeforeReconnect)
          .map((json) => json['type'])
          .whereType<String>()
          .toList();
      expect(types.first, 'file_transfer_download_resume_v2');
      expect(requestHosts, everyElement('new-route.example'));
      expect(await blockingStorage.loadReceives('machine-1'), hasLength(1));
      service.dispose();
    },
  );

  test(
    'concurrent offers atomically preserve the eight-item queue limit',
    () async {
      final blockingStorage = _BlockingReceiveLoadStorage(
        applicationSupportDirectory: () async => support,
        downloadsDirectory: () async => downloads,
        secretStore: secrets,
        clock: () => DateTime.utc(2026, 7, 18, 12),
      );
      SharedPreferences.setMockInitialValues({
        'file_transfer_v2_auto_resume': false,
      });
      final preferences = await SharedPreferences.getInstance();
      final service = createService(
        client: MockClient.streaming((request, body) async {
          throw StateError('manual offers must not start HTTP');
        }),
        preferences: preferences,
        storageOverride: blockingStorage,
      );

      for (var index = 0; index < 9; index++) {
        final id =
            '40000000-0000-4000-8000-${index.toString().padLeft(12, '0')}';
        bridge.emit(_offer(id: id, filename: 'concurrent-$index.bin'));
      }
      await _waitUntil(
        () =>
            bridge.sentJson
                .where(
                  (json) =>
                      json['type'] == 'file_transfer_receive_result_v2' &&
                      json['errorCode'] == 'queue_limit',
                )
                .length ==
            1,
      );
      blockingStorage.releaseFirstLoad.complete();
      await _waitUntilAsync(
        () async =>
            service.queuedReceiveCount == fileTransferReceiveQueueLimit &&
            (await blockingStorage.loadReceives('machine-1')).length ==
                fileTransferReceiveQueueLimit,
      );

      expect(service.queuedReceiveCount, fileTransferReceiveQueueLimit);
      expect(service.queuedReceiveBytes, fileTransferReceiveQueueLimit * 3);
      service.dispose();
    },
  );

  test(
    'concurrent 15 GiB offers atomically preserve the 30 GiB byte limit',
    () async {
      final blockingStorage = _BlockingReceiveLoadStorage(
        applicationSupportDirectory: () async => support,
        downloadsDirectory: () async => downloads,
        secretStore: secrets,
        clock: () => DateTime.utc(2026, 7, 18, 12),
      );
      SharedPreferences.setMockInitialValues({
        'file_transfer_v2_auto_resume': false,
      });
      final preferences = await SharedPreferences.getInstance();
      final service = createService(
        client: MockClient.streaming((request, body) async {
          throw StateError('manual offers must not start HTTP');
        }),
        preferences: preferences,
        storageOverride: blockingStorage,
      );
      const fifteenGiB = 15 * 1024 * 1024 * 1024;

      for (var index = 0; index < 3; index++) {
        final id =
            '50000000-0000-4000-8000-${index.toString().padLeft(12, '0')}';
        bridge.emit(
          _offer(
            id: id,
            filename: 'fifteen-gib-$index.bin',
            sizeBytes: fifteenGiB,
          ),
        );
      }
      await _waitUntil(
        () => bridge.sentJson.any(
          (json) =>
              json['type'] == 'file_transfer_receive_result_v2' &&
              json['errorCode'] == 'queue_limit',
        ),
      );
      blockingStorage.releaseFirstLoad.complete();
      await _waitUntil(() => service.queuedReceiveCount == 2);

      expect(service.queuedReceiveBytes, 30 * 1024 * 1024 * 1024);
      expect(await blockingStorage.loadReceives('machine-1'), hasLength(2));
      service.dispose();
    },
  );

  test(
    'recovery reserves an item slot while partial reconciliation awaits',
    () async {
      final blockingStorage = _BlockingReceiveReconcileStorage(
        applicationSupportDirectory: () async => support,
        downloadsDirectory: () async => downloads,
        secretStore: secrets,
        clock: () => DateTime.utc(2026, 7, 18, 12),
      );
      const recoveredId = '70000000-0000-4000-8000-000000000000';
      final recovered = blockingStorage.newReceiveCheckpoint(
        logicalIdentity: 'machine-1',
        offer: _offer(id: recoveredId, filename: 'recovered.bin'),
      );
      await blockingStorage.initializeReceive(recovered);
      await blockingStorage.writeDownloadSecret(
        recovered,
        const DownloadTransferSecret(
          downloadUrl:
              'https://mac.example/api/file-transfers/downloads/$recoveredId',
          downloadToken: token,
          logicalBridgeIdentity: 'machine-1',
        ),
      );
      SharedPreferences.setMockInitialValues({
        'file_transfer_v2_auto_resume': false,
      });
      final preferences = await SharedPreferences.getInstance();
      final service = createService(
        client: MockClient.streaming((request, body) async {
          throw StateError('manual recovery must not start HTTP');
        }),
        preferences: preferences,
        storageOverride: blockingStorage,
      );

      await service.initialize();
      await blockingStorage.reconcileStarted.future.timeout(
        const Duration(seconds: 1),
      );
      for (var index = 0; index < fileTransferReceiveQueueLimit; index++) {
        final id =
            '71000000-0000-4000-8000-${index.toString().padLeft(12, '0')}';
        bridge.emit(_offer(id: id, filename: 'new-$index.bin'));
      }
      await _waitUntil(
        () =>
            bridge.sentJson
                .where(
                  (json) =>
                      json['type'] == 'file_transfer_receive_result_v2' &&
                      json['errorCode'] == 'queue_limit',
                )
                .length ==
            1,
      );
      blockingStorage.releaseFirstReconcile.complete();
      await _waitUntilAsync(
        () async =>
            service.queuedReceiveCount == fileTransferReceiveQueueLimit &&
            (await blockingStorage.loadReceives('machine-1')).length ==
                fileTransferReceiveQueueLimit,
      );

      expect(service.queuedReceiveBytes, fileTransferReceiveQueueLimit * 3);
      service.dispose();
    },
  );

  test(
    'recovery reserves 15 GiB while partial reconciliation awaits',
    () async {
      final blockingStorage = _BlockingReceiveReconcileStorage(
        applicationSupportDirectory: () async => support,
        downloadsDirectory: () async => downloads,
        secretStore: secrets,
        clock: () => DateTime.utc(2026, 7, 18, 12),
      );
      const fifteenGiB = 15 * 1024 * 1024 * 1024;
      const recoveredId = '72000000-0000-4000-8000-000000000000';
      final recovered = blockingStorage.newReceiveCheckpoint(
        logicalIdentity: 'machine-1',
        offer: _offer(
          id: recoveredId,
          filename: 'recovered-15g.bin',
          sizeBytes: fifteenGiB,
        ),
      );
      await blockingStorage.initializeReceive(recovered);
      await blockingStorage.writeDownloadSecret(
        recovered,
        const DownloadTransferSecret(
          downloadUrl:
              'https://mac.example/api/file-transfers/downloads/$recoveredId',
          downloadToken: token,
          logicalBridgeIdentity: 'machine-1',
        ),
      );
      SharedPreferences.setMockInitialValues({
        'file_transfer_v2_auto_resume': false,
      });
      final preferences = await SharedPreferences.getInstance();
      final service = createService(
        client: MockClient.streaming((request, body) async {
          throw StateError('manual recovery must not start HTTP');
        }),
        preferences: preferences,
        storageOverride: blockingStorage,
      );

      await service.initialize();
      await blockingStorage.reconcileStarted.future.timeout(
        const Duration(seconds: 1),
      );
      for (var index = 0; index < 2; index++) {
        final id =
            '73000000-0000-4000-8000-${index.toString().padLeft(12, '0')}';
        bridge.emit(
          _offer(id: id, filename: 'new-15g-$index.bin', sizeBytes: fifteenGiB),
        );
      }
      await _waitUntil(
        () => bridge.sentJson.any(
          (json) =>
              json['type'] == 'file_transfer_receive_result_v2' &&
              json['errorCode'] == 'queue_limit',
        ),
      );
      blockingStorage.releaseFirstReconcile.complete();
      await _waitUntil(() => service.queuedReceiveCount == 2);

      expect(service.queuedReceiveBytes, 30 * 1024 * 1024 * 1024);
      expect(await blockingStorage.loadReceives('machine-1'), hasLength(2));
      service.dispose();
    },
  );

  test(
    'a stale offer cannot enqueue or acknowledge after a machine switch',
    () async {
      final blockingStorage = _BlockingReceiveLoadStorage(
        applicationSupportDirectory: () async => support,
        downloadsDirectory: () async => downloads,
        secretStore: secrets,
        clock: () => DateTime.utc(2026, 7, 18, 12),
      );
      SharedPreferences.setMockInitialValues({
        'file_transfer_v2_auto_resume': false,
      });
      final preferences = await SharedPreferences.getInstance();
      final service = createService(
        client: MockClient.streaming((request, body) async {
          throw StateError('manual offers must not start HTTP');
        }),
        preferences: preferences,
        storageOverride: blockingStorage,
      );

      bridge.emit(_offer());
      await blockingStorage.loadStarted.future.timeout(
        const Duration(seconds: 1),
      );
      bridge.setLogicalIdentity('machine-2');
      bridge.emit(_offer(downloadToken: replayToken));
      for (var index = 1; index < fileTransferReceiveQueueLimit; index++) {
        final id =
            '60000000-0000-4000-8000-${index.toString().padLeft(12, '0')}';
        bridge.emit(
          _offer(
            id: id,
            filename: 'machine-b-$index.bin',
            downloadToken: replayToken,
          ),
        );
      }
      await _waitUntilAsync(
        () async =>
            service.queuedReceiveCount == fileTransferReceiveQueueLimit &&
            (await blockingStorage.loadReceives('machine-2')).length ==
                fileTransferReceiveQueueLimit,
      );
      blockingStorage.releaseFirstLoad.complete();
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(await blockingStorage.loadReceives('machine-1'), isEmpty);
      final machineB = (await blockingStorage.loadReceives(
        'machine-2',
      )).singleWhere((item) => item.transferId == transferId);
      final machineBSecret = await blockingStorage.readDownloadSecret(machineB);
      expect(machineBSecret?.logicalBridgeIdentity, 'machine-2');
      expect(machineBSecret?.downloadToken, replayToken);
      expect(service.queuedReceiveCount, fileTransferReceiveQueueLimit);
      expect(
        bridge.sentJson.where(
          (json) => json['type'] == 'file_transfer_receive_result_v2',
        ),
        isEmpty,
      );
      service.dispose();
    },
  );

  test('completion retry stays with its original machine identity', () async {
    await seedCompletedReceive(notificationPending: true);
    SharedPreferences.setMockInitialValues({
      'file_transfer_v2_auto_resume': false,
    });
    final preferences = await SharedPreferences.getInstance();
    final flakyNotifications = _FlakyNotifications();
    bridge.autoDownloadResumeSize = 3;
    final service = createService(
      client: MockClient.streaming((request, body) async {
        throw StateError('completed receives must not transfer bytes');
      }),
      preferences: preferences,
      notificationsOverride: flakyNotifications,
      completionRecoveryRetryDelay: const Duration(milliseconds: 100),
    );

    await service.initialize();
    await _waitUntil(() => flakyNotifications.attempts == 1);
    await _waitUntil(() => service.activeTransfer == null);
    final sentBeforeSwitch = bridge.sentJson.length;
    bridge.setLogicalIdentity('machine-2');
    await Future<void>.delayed(const Duration(milliseconds: 160));

    expect(bridge.sentJson.length, sentBeforeSwitch);
    expect(flakyNotifications.attempts, 1);
    expect(await storage.loadReceives('machine-2'), isEmpty);
    expect(
      (await storage.loadReceives('machine-1')).single.notificationPending,
      isTrue,
    );

    bridge.setLogicalIdentity('machine-1');
    await _waitUntil(() => flakyNotifications.attempts == 2);
    await _waitUntilAsync(
      () async =>
          !(await storage.loadReceives('machine-1')).single.notificationPending,
    );
    expect(flakyNotifications.receivedNames, ['report.bin']);
    service.dispose();
  });

  test(
    'machine switch clears paused work and recovers it only on machine A',
    () async {
      var failHead = true;
      var httpRequests = 0;
      final service = createService(
        client: MockClient.streaming((request, body) async {
          httpRequests++;
          if (request.method == 'HEAD') {
            if (failHead) {
              throw http.ClientException('temporary route failure');
            }
            return http.StreamedResponse(
              const Stream.empty(),
              HttpStatus.ok,
              headers: {
                'content-length': '3',
                'etag': etag,
                'accept-ranges': 'bytes',
                'x-ccpocket-max-chunk-bytes': '16777216',
                'x-ccpocket-transfer-expires': '2026-07-19T12:00:00.000Z',
              },
            );
          }
          return http.StreamedResponse(
            Stream.value(const [1, 2, 3]),
            HttpStatus.partialContent,
            contentLength: 3,
            headers: {
              'content-length': '3',
              'content-range': 'bytes 0-2/3',
              'etag': etag,
            },
          );
        }),
      );

      bridge.emit(_offer());
      await _waitUntil(() => service.pausedTransfer != null);
      expect(httpRequests, 3);
      final sentBeforeSwitch = bridge.sentJson.length;
      bridge.setLogicalIdentity('machine-2');
      await _waitUntil(() => service.pausedTransfer == null);
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(await storage.loadReceives('machine-1'), hasLength(1));
      expect(await storage.loadReceives('machine-2'), isEmpty);
      expect(
        bridge.sentJson
            .skip(sentBeforeSwitch)
            .where(
              (json) =>
                  json.containsKey('downloadToken') ||
                  json.containsKey('resumeToken') ||
                  json.containsKey('uploadToken'),
            ),
        isEmpty,
      );

      failHead = false;
      bridge.autoDownloadResumeSize = 3;
      bridge.setLogicalIdentity('machine-1');
      await _waitUntil(
        () => service.recentResults.any(
          (item) => item.status == FileTransferStatus.succeeded,
        ),
      );
      expect(httpRequests, 5);
      service.dispose();
    },
  );

  test(
    'machine switch keeps a queued upload staged for its original machine',
    () async {
      final pickerRoot = await storage.pickerStagingDirectory();
      final picked = File('${pickerRoot.path}/queued-upload.bin');
      await picked.writeAsBytes(const [4, 5, 6]);
      final checkpoint = await storage.adoptPickerCopy(
        logicalIdentity: 'machine-1',
        localId: 'local-upload-abcdefghijkl',
        requestId: 'request-upload-abcdefghijk',
        transferId: '223e4567-e89b-42d3-a456-426614174000',
        resumeToken: replayToken,
        filename: 'queued-upload.bin',
        sizeBytes: 3,
        pickerCopy: picked,
      );
      SharedPreferences.setMockInitialValues({
        'file_transfer_v2_auto_resume': false,
      });
      final preferences = await SharedPreferences.getInstance();
      final service = createService(
        client: MockClient.streaming((request, body) async {
          throw StateError('manual queued upload must not start HTTP');
        }),
        preferences: preferences,
      );

      await service.initialize();
      await _waitUntil(() => service.queuedUploadCount == 1);
      bridge.setLogicalIdentity('machine-2');
      await _waitUntil(() => service.queuedUploadCount == 0);

      expect(await storage.loadUploads('machine-1'), hasLength(1));
      expect(await (await storage.uploadStaged(checkpoint)).exists(), isTrue);
      expect(await storage.loadUploads('machine-2'), isEmpty);

      bridge.setLogicalIdentity('machine-1');
      await _waitUntil(() => service.queuedUploadCount == 1);
      expect(await (await storage.uploadStaged(checkpoint)).exists(), isTrue);
      service.dispose();
    },
  );

  test('notification failure cannot change a completed receive', () async {
    final client = MockClient.streaming((request, body) async {
      if (request.method == 'HEAD') {
        return http.StreamedResponse(
          const Stream.empty(),
          HttpStatus.ok,
          headers: {
            'content-length': '3',
            'etag': etag,
            'accept-ranges': 'bytes',
            'x-ccpocket-max-chunk-bytes': '16777216',
            'x-ccpocket-transfer-expires': '2026-07-19T12:00:00.000Z',
          },
        );
      }
      return http.StreamedResponse(
        Stream.value(const [7, 8, 9]),
        HttpStatus.partialContent,
        contentLength: 3,
        headers: {
          'content-length': '3',
          'content-range': 'bytes 0-2/3',
          'etag': etag,
        },
      );
    });
    final service = createService(
      client: client,
      notificationsOverride: const _ThrowingNotifications(),
    );

    bridge.emit(_offer());
    await _waitUntil(
      () => service.recentResults.any(
        (item) => item.status == FileTransferStatus.succeeded,
      ),
    );
    await _waitUntil(() => service.activeTransfer == null);
    expect(await File('${downloads.path}/report.bin').readAsBytes(), [7, 8, 9]);
    expect(service.recentResults.first.status, FileTransferStatus.succeeded);
    expect(
      (await storage.loadReceives('machine-1')).single.notificationPending,
      isTrue,
    );
    service.dispose();
  });

  test(
    'permanent notification failure has a bounded retry round per connection',
    () async {
      await seedCompletedReceive(notificationPending: true);
      SharedPreferences.setMockInitialValues({
        'file_transfer_v2_auto_resume': false,
      });
      final preferences = await SharedPreferences.getInstance();
      final failingNotifications = _CountingThrowingNotifications();
      bridge.autoDownloadResumeSize = 3;
      final service = createService(
        client: MockClient.streaming((request, body) async {
          throw StateError('completed receives must not transfer bytes');
        }),
        preferences: preferences,
        notificationsOverride: failingNotifications,
        completionRecoveryRetryDelay: const Duration(milliseconds: 5),
        completionRecoveryRetryLimit: 3,
        completionRecoveryMaxRetryDelay: const Duration(milliseconds: 20),
      );

      await service.initialize();
      await _waitUntil(() => failingNotifications.attempts == 3);
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(failingNotifications.attempts, 3);
      expect(
        (await storage.loadReceives('machine-1')).single.notificationPending,
        isTrue,
      );

      bridge.setConnected(false);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      bridge.setConnected(true);
      await _waitUntil(() => failingNotifications.attempts == 6);
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(failingNotifications.attempts, 6);
      expect(
        (await storage.loadReceives('machine-1')).single.notificationPending,
        isTrue,
      );
      service.dispose();
    },
  );

  test(
    'manual mode retries a failed completion notification without byte transfer',
    () async {
      await seedCompletedReceive(notificationPending: true);
      await seedPendingReceives(1);
      SharedPreferences.setMockInitialValues({
        'file_transfer_v2_auto_resume': false,
      });
      final preferences = await SharedPreferences.getInstance();
      final flakyNotifications = _FlakyNotifications();
      bridge.autoDownloadResumeSize = 3;
      final service = createService(
        client: MockClient.streaming((request, body) async {
          throw StateError('manual incomplete bytes must not start');
        }),
        preferences: preferences,
        notificationsOverride: flakyNotifications,
        completionRecoveryRetryDelay: const Duration(milliseconds: 10),
      );

      await service.initialize();
      await _waitUntil(() => flakyNotifications.attempts == 2);
      await _waitUntilAsync(() async {
        final items = await storage.loadReceives('machine-1');
        final complete = items.singleWhere(
          (item) => item.transferId == transferId,
        );
        return !complete.notificationPending;
      });

      expect(flakyNotifications.receivedNames, ['report.bin']);
      expect(service.queuedReceiveCount, 1);
      expect(service.queuedReceiveBytes, 1);
      expect(service.pausedTransfer, isNull);
      service.dispose();
    },
  );

  test('upload confirmation missing filename preserves the staged file', () {
    return expectRejectedUploadConfirmation(filename: null, sizeBytes: 1);
  });

  test('upload confirmation missing size preserves the staged file', () {
    return expectRejectedUploadConfirmation(
      filename: 'unconfirmed.bin',
      sizeBytes: null,
    );
  });

  test('upload confirmation with wrong size preserves the staged file', () {
    return expectRejectedUploadConfirmation(
      filename: 'unconfirmed.bin',
      sizeBytes: 2,
    );
  });

  test('upload confirmation with an overlong filename preserves staging', () {
    return expectRejectedUploadConfirmation(
      filename: '${List.filled(1025, 'x').join()}.bin',
      sizeBytes: 1,
    );
  });

  test('dropped upload returns the negotiated Mac saved path', () async {
    final service = createService(
      client: MockClient((_) async => http.Response('', 500)),
    );
    bridge.onSend = (json) {
      if (json['type'] != 'file_transfer_upload_prepare_v2') return;
      scheduleMicrotask(() {
        bridge.emit(
          FileTransferUploadResultMessage(
            requestId: json['requestId'] as String,
            transferId: json['transferId'] as String,
            success: true,
            filename: 'notes.txt',
            sizeBytes: 3,
            savedPath: '/Users/test/Downloads/notes.txt',
          ),
        );
      });
    };

    final ticket = await service.enqueueDroppedFile(
      filename: 'notes.txt',
      bytes: Stream<List<int>>.fromIterable(const [
        [1],
        [2, 3],
      ]),
      expectedSizeBytes: 3,
    );
    final result = await ticket.completion;

    expect(result.status, FileTransferStatus.succeeded);
    expect(result.savedFilename, 'notes.txt');
    expect(result.savedPath, '/Users/test/Downloads/notes.txt');
    expect(await storage.loadUploads('machine-1'), isEmpty);
    service.dispose();
  });

  test('unsupported Bridge rejects a drop before reading its bytes', () async {
    bridge.setCapabilities(const {});
    var listened = false;
    final bytes = StreamController<List<int>>.broadcast(
      onListen: () => listened = true,
    );
    final service = createService(
      client: MockClient((_) async => http.Response('', 500)),
    );

    await expectLater(
      service.enqueueDroppedFile(
        filename: 'blocked.bin',
        bytes: bytes.stream,
        expectedSizeBytes: 1,
      ),
      throwsA(
        isA<FileTransferException>().having(
          (error) => error.code,
          'code',
          'bridge_unsupported',
        ),
      ),
    );

    expect(listened, isFalse);
    expect(bridge.sentJson, isEmpty);
    await bytes.close();
    service.dispose();
  });

  test('lost first ready retries same identity with a new request id', () async {
    final pickerRoot = await storage.pickerStagingDirectory();
    final picked = File('${pickerRoot.path}/picked.bin');
    await picked.writeAsBytes(const [7, 8, 9]);
    final picker = _FakePicker(
      FileTransferSelection(
        path: picked.path,
        filename: 'picked.bin',
        sizeBytes: 3,
      ),
    );
    String? currentRequestId;
    String? stableTransferId;
    String? stableResumeToken;
    var prepareCount = 0;
    final client = MockClient.streaming((request, body) async {
      if (request.method == 'HEAD') {
        return http.StreamedResponse(
          const Stream.empty(),
          HttpStatus.ok,
          headers: {
            'upload-offset': '0',
            'upload-length': '3',
            'upload-expires': '2026-07-19T12:00:00.000Z',
            'upload-complete': '0',
            'x-ccpocket-max-chunk-bytes': '16777216',
          },
        );
      }
      expect(await body.toBytes(), [7, 8, 9]);
      scheduleMicrotask(() {
        bridge.emit(
          FileTransferUploadResultMessage(
            requestId: currentRequestId!,
            transferId: stableTransferId!,
            success: true,
            filename: 'picked.bin',
            sizeBytes: 3,
          ),
        );
      });
      return http.StreamedResponse(
        const Stream.empty(),
        HttpStatus.noContent,
        headers: {'upload-offset': '3', 'upload-complete': '1'},
      );
    });
    final service = createService(client: client, picker: picker);
    bridge.onSend = (json) {
      if (json['type'] != 'file_transfer_upload_prepare_v2') return;
      prepareCount++;
      if (prepareCount == 1) {
        stableTransferId = json['transferId'] as String;
        stableResumeToken = json['resumeToken'] as String;
        scheduleMicrotask(() => bridge.setConnected(false));
        return;
      }
      expect(json['transferId'], stableTransferId);
      expect(json['resumeToken'], stableResumeToken);
      currentRequestId = json['requestId'] as String;
      final previousRequest = bridge.sentJson
          .where((item) => item['type'] == 'file_transfer_upload_prepare_v2')
          .first['requestId'];
      expect(currentRequestId, isNot(previousRequest));
      scheduleMicrotask(() {
        bridge.emit(
          FileTransferUploadReadyMessage(
            requestId: currentRequestId!,
            transferId: stableTransferId!,
            uploadUrl:
                'https://mac.example/api/file-transfers/uploads/$stableTransferId',
            uploadToken: token,
            resumeToken: stableResumeToken!,
            uploadOffset: 0,
            sizeBytes: 3,
            maxChunkSizeBytes: fileTransferChunkBytes,
            expiresAt: '2026-07-19T12:00:00.000Z',
          ),
        );
      });
    };

    await service.uploadToMac();
    expect(service.pausedTransfer, isNotNull);
    bridge.setConnected(true);
    await _waitUntil(
      () => service.recentResults.any(
        (item) => item.status == FileTransferStatus.succeeded,
      ),
    );
    expect(prepareCount, 2);
    expect(await picked.exists(), isFalse);
    expect(await storage.loadUploads('machine-1'), isEmpty);
    service.dispose();
  });

  test(
    'upload ready ignores a correlated request with the wrong transfer id',
    () async {
      final pickerRoot = await storage.pickerStagingDirectory();
      final picked = File('${pickerRoot.path}/ready.bin');
      await picked.writeAsBytes(const [4]);
      String? requestId;
      String? stableTransferId;
      String? resumeToken;
      final client = MockClient.streaming((request, body) async {
        if (request.method == 'HEAD') {
          return http.StreamedResponse(
            const Stream.empty(),
            HttpStatus.ok,
            headers: {
              'upload-offset': '0',
              'upload-length': '1',
              'upload-expires': '2026-07-19T12:00:00.000Z',
              'upload-complete': '0',
              'x-ccpocket-max-chunk-bytes': '16777216',
            },
          );
        }
        expect(await body.toBytes(), [4]);
        scheduleMicrotask(() {
          bridge.emit(
            FileTransferUploadResultMessage(
              requestId: requestId!,
              transferId: stableTransferId!,
              success: true,
              filename: 'ready.bin',
              sizeBytes: 1,
            ),
          );
        });
        return http.StreamedResponse(
          const Stream.empty(),
          HttpStatus.noContent,
          headers: {'upload-offset': '1', 'upload-complete': '1'},
        );
      });
      final service = createService(
        client: client,
        picker: _FakePicker(
          FileTransferSelection(
            path: picked.path,
            filename: 'ready.bin',
            sizeBytes: 1,
          ),
        ),
      );
      bridge.onSend = (json) {
        if (json['type'] != 'file_transfer_upload_prepare_v2') return;
        requestId = json['requestId'] as String;
        stableTransferId = json['transferId'] as String;
        resumeToken = json['resumeToken'] as String;
        scheduleMicrotask(() {
          bridge.emit(
            FileTransferUploadReadyMessage(
              requestId: requestId!,
              transferId: 'wrong-transfer-id-123456',
              uploadUrl:
                  'https://mac.example/api/file-transfers/uploads/wrong-transfer-id-123456',
              uploadToken: token,
              resumeToken: resumeToken!,
              uploadOffset: 0,
              sizeBytes: 1,
              maxChunkSizeBytes: fileTransferChunkBytes,
              expiresAt: '2026-07-19T12:00:00.000Z',
            ),
          );
          bridge.emit(
            FileTransferUploadReadyMessage(
              requestId: requestId!,
              transferId: stableTransferId!,
              uploadUrl:
                  'https://mac.example/api/file-transfers/uploads/$stableTransferId',
              uploadToken: token,
              resumeToken: resumeToken!,
              uploadOffset: 0,
              sizeBytes: 1,
              maxChunkSizeBytes: fileTransferChunkBytes,
              expiresAt: '2026-07-19T12:00:00.000Z',
            ),
          );
        });
      };

      await service.uploadToMac();
      expect(service.recentResults.first.status, FileTransferStatus.succeeded);
      service.dispose();
    },
  );

  test('auto-resume off still loads checkpoints for manual start', () async {
    SharedPreferences.setMockInitialValues({
      'file_transfer_v2_auto_resume': false,
    });
    final preferences = await SharedPreferences.getInstance();
    final checkpoint = storage.newReceiveCheckpoint(
      logicalIdentity: 'machine-1',
      offer: _offer(),
    );
    await (await storage.receivePartial(checkpoint)).create(exclusive: true);
    await storage.saveReceive(checkpoint);
    await storage.writeDownloadSecret(
      checkpoint,
      const DownloadTransferSecret(
        downloadUrl:
            'https://mac.example/api/file-transfers/downloads/$transferId',
        downloadToken: token,
        logicalBridgeIdentity: 'machine-1',
      ),
    );
    var requestCount = 0;
    final client = MockClient.streaming((request, body) async {
      requestCount++;
      if (request.method == 'HEAD') {
        return http.StreamedResponse(
          const Stream.empty(),
          HttpStatus.ok,
          headers: {
            'content-length': '3',
            'etag': etag,
            'accept-ranges': 'bytes',
            'x-ccpocket-max-chunk-bytes': '16777216',
            'x-ccpocket-transfer-expires': '2026-07-19T12:00:00.000Z',
          },
        );
      }
      return http.StreamedResponse(
        Stream.value(const [1, 2, 3]),
        HttpStatus.partialContent,
        contentLength: 3,
        headers: {
          'content-length': '3',
          'content-range': 'bytes 0-2/3',
          'etag': etag,
        },
      );
    });
    final service = createService(client: client, preferences: preferences);
    bridge.autoDownloadResumeSize = 3;
    var notifyCount = 0;
    service.addListener(() => notifyCount++);
    await service.initialize();
    await _waitUntil(() => service.queuedReceiveCount == 1);
    expect(service.autoResume, isFalse);
    expect(requestCount, 0);
    expect(notifyCount, greaterThan(0));

    await service.startQueuedTransfers();
    expect(requestCount, 2);
    expect(service.recentResults.first.status, FileTransferStatus.succeeded);
    service.dispose();
  });

  test(
    'restart removes a staged upload whose checkpoint has no resume secret',
    () async {
      final pickerRoot = await storage.pickerStagingDirectory();
      final picked = File('${pickerRoot.path}/crash-window.bin');
      await picked.writeAsBytes(const [1, 2, 3]);
      final checkpoint = await storage.adoptPickerCopy(
        logicalIdentity: 'machine-1',
        localId: 'local-crash-window',
        requestId: 'request-crash-window',
        transferId: transferId,
        resumeToken: token,
        filename: 'crash-window.bin',
        sizeBytes: 3,
        pickerCopy: picked,
      );
      secrets.values.clear();
      final staged = await storage.uploadStaged(checkpoint);
      final service = createService(
        client: MockClient((_) async => http.Response('', 500)),
      );

      await service.initialize();
      await _waitUntilAsync(
        () async => (await storage.loadUploads('machine-1')).isEmpty,
      );

      expect(await staged.exists(), isFalse);
      expect(
        bridge.sentJson.where(
          (json) => json['type'] == 'file_transfer_upload_prepare_v2',
        ),
        isEmpty,
      );
      service.dispose();
    },
  );

  test('restart removes a pending receive with no resume secret', () async {
    final checkpoint = storage.newReceiveCheckpoint(
      logicalIdentity: 'machine-1',
      offer: _offer(),
    );
    await storage.initializeReceive(checkpoint);
    final partial = await storage.receivePartial(checkpoint);
    final service = createService(
      client: MockClient((_) async => http.Response('', 500)),
    );

    await service.initialize();
    await _waitUntilAsync(
      () async => (await storage.loadReceives('machine-1')).isEmpty,
    );

    expect(await partial.exists(), isFalse);
    service.dispose();
  });

  test(
    'confirmed upload stays successful when local Keychain cleanup fails',
    () async {
      final pickerRoot = await storage.pickerStagingDirectory();
      final picked = File('${pickerRoot.path}/confirmed.bin');
      await picked.writeAsBytes(const [7]);
      secrets.failDeletes = true;
      final service = createService(
        client: MockClient((_) async => http.Response('', 500)),
        picker: _FakePicker(
          FileTransferSelection(
            path: picked.path,
            filename: 'confirmed.bin',
            sizeBytes: 1,
          ),
        ),
      );
      bridge.onSend = (json) {
        if (json['type'] != 'file_transfer_upload_prepare_v2') return;
        scheduleMicrotask(() {
          bridge.emit(
            FileTransferUploadResultMessage(
              requestId: json['requestId'] as String,
              transferId: json['transferId'] as String,
              success: true,
              filename: 'confirmed.bin',
              sizeBytes: 1,
            ),
          );
        });
      };

      await service.uploadToMac();

      expect(service.recentResults.first.status, FileTransferStatus.succeeded);
      final retained = (await storage.loadUploads('machine-1')).single;
      expect(retained.uploadedBytes, 1);
      expect(await (await storage.uploadStaged(retained)).exists(), isTrue);
      service.dispose();
    },
  );

  test(
    'file-transfer storage failure never blocks app initialization',
    () async {
      final failingStorage = FileTransferStorage(
        applicationSupportDirectory: () async =>
            throw FileSystemException('Application Support unavailable'),
        downloadsDirectory: () async => downloads,
        secretStore: secrets,
      );
      final service = createService(
        client: MockClient((_) async => http.Response('', 500)),
        storageOverride: failingStorage,
      );

      await expectLater(service.initialize(), completes);
      service.dispose();
    },
  );

  test('received-file inbox persists an unread watermark', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final existing = File('${downloads.path}/existing.txt');
    await existing.writeAsBytes(const [1]);
    await existing.setLastModified(DateTime.utc(2026, 7, 18, 10));
    final service = createService(
      client: MockClient((_) async => http.Response('', 500)),
      preferences: preferences,
    );

    await service.initialize();
    expect(service.receivedFiles.map((file) => file.filename), ['existing.txt']);
    expect(service.unreadReceivedCount, 0);

    final incoming = File('${downloads.path}/incoming.pdf');
    await incoming.writeAsBytes(const [2, 3]);
    await incoming.setLastModified(DateTime.utc(2026, 7, 18, 11));
    await service.refreshReceivedFiles();
    expect(service.unreadReceivedCount, 1);

    await service.markReceivedFilesSeen();
    expect(service.unreadReceivedCount, 0);

    service.dispose();
    final restored = createService(
      client: MockClient((_) async => http.Response('', 500)),
      preferences: preferences,
    );
    await restored.initialize();
    expect(restored.unreadReceivedCount, 0);
    restored.dispose();
  });

  test('restart truncates crash-only download bytes and resumes', () async {
    final checkpoint = storage
        .newReceiveCheckpoint(
          logicalIdentity: 'machine-1',
          offer: _offer(sizeBytes: 4),
        )
        .copyWith(receivedBytes: 2);
    await (await storage.receivePartial(
      checkpoint,
    )).writeAsBytes(const [1, 2, 9, 9]);
    await storage.saveReceive(checkpoint);
    await storage.writeDownloadSecret(
      checkpoint,
      const DownloadTransferSecret(
        downloadUrl:
            'https://mac.example/api/file-transfers/downloads/$transferId',
        downloadToken: token,
        logicalBridgeIdentity: 'machine-1',
      ),
    );
    final client = MockClient.streaming((request, body) async {
      if (request.method == 'HEAD') {
        return http.StreamedResponse(
          const Stream.empty(),
          HttpStatus.ok,
          headers: {
            'content-length': '4',
            'etag': etag,
            'accept-ranges': 'bytes',
            'x-ccpocket-max-chunk-bytes': '16777216',
            'x-ccpocket-transfer-expires': '2026-07-19T12:00:00.000Z',
          },
        );
      }
      expect(request.headers['range'], 'bytes=2-3');
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
    });
    final service = createService(client: client);
    bridge.autoDownloadResumeSize = 4;

    await service.initialize();
    await _waitUntil(
      () => service.recentResults.any(
        (item) => item.status == FileTransferStatus.succeeded,
      ),
    );

    expect(await File('${downloads.path}/report.bin').readAsBytes(), [
      1,
      2,
      3,
      4,
    ]);
    service.dispose();
  });

  test(
    'durable activity renews retention from the latest checkpoint',
    () async {
      var now = DateTime.utc(2026, 7, 18, 12);
      final movingStorage = FileTransferStorage(
        applicationSupportDirectory: () async => support,
        downloadsDirectory: () async => downloads,
        secretStore: secrets,
        clock: () => now,
      );
      final checkpoint = movingStorage
          .newReceiveCheckpoint(
            logicalIdentity: 'machine-1',
            offer: _offer(sizeBytes: 2),
          )
          .copyWith(receivedBytes: 1);
      await (await movingStorage.receivePartial(
        checkpoint,
      )).writeAsBytes(const [1]);
      await movingStorage.saveReceive(checkpoint);
      await movingStorage.writeDownloadSecret(
        checkpoint,
        const DownloadTransferSecret(
          downloadUrl:
              'https://mac.example/api/file-transfers/downloads/$transferId',
          downloadToken: token,
          logicalBridgeIdentity: 'machine-1',
        ),
      );
      now = now.add(const Duration(days: 6));
      final client = MockClient.streaming((request, body) async {
        if (request.method == 'HEAD') {
          return http.StreamedResponse(
            const Stream.empty(),
            HttpStatus.ok,
            headers: {
              'content-length': '2',
              'etag': etag,
              'accept-ranges': 'bytes',
              'x-ccpocket-max-chunk-bytes': '16777216',
              'x-ccpocket-transfer-expires': '2026-08-01T12:00:00.000Z',
            },
          );
        }
        return http.StreamedResponse(
          Stream.value(const [2]),
          HttpStatus.partialContent,
          contentLength: 1,
          headers: {
            'content-length': '1',
            'content-range': 'bytes 1-1/2',
            'etag': etag,
          },
        );
      });
      final service = createService(
        client: client,
        storageOverride: movingStorage,
        clock: () => now,
      );
      bridge.autoDownloadResumeSize = 2;

      await service.initialize();
      await _waitUntil(
        () => service.recentResults.any(
          (item) => item.status == FileTransferStatus.succeeded,
        ),
      );

      final tombstone = (await movingStorage.loadReceives('machine-1')).single;
      expect(tombstone.expiresAt, now.add(fileTransferCheckpointRetention));
      service.dispose();
    },
  );

  test('HTTP recovery matrix fails closed for auth and range violations', () {
    for (final status in [400, 401, 403, 412, 413, 416]) {
      expect(
        fileTransferErrorIsRecoverableForTest(
          FileTransferHttpException(
            'download_range_http_error',
            statusCode: status,
          ),
        ),
        isFalse,
        reason: 'HTTP $status must be terminal',
      );
    }
    for (final status in [408, 425, 429, 500, 503]) {
      expect(
        fileTransferErrorIsRecoverableForTest(
          FileTransferHttpException(
            'download_range_http_error',
            statusCode: status,
          ),
        ),
        isTrue,
        reason: 'HTTP $status should pause/retry',
      );
    }
    expect(
      fileTransferErrorIsRecoverableForTest(
        const FileTransferHttpException(
          'upload_patch_http_error',
          statusCode: 409,
        ),
      ),
      isTrue,
    );
    expect(
      fileTransferErrorIsRecoverableForTest(
        const FileTransferHttpException(
          'download_range_http_error',
          statusCode: 409,
        ),
      ),
      isFalse,
    );
  });

  test(
    'pause is local-only and explicit cancel uses stable live secret',
    () async {
      final pickerRoot = await storage.pickerStagingDirectory();
      final picked = File('${pickerRoot.path}/cancel.bin');
      await picked.writeAsBytes(const [1, 2, 3]);
      final service = createService(
        client: MockClient.streaming((request, body) async {
          if (request.method == 'HEAD') {
            return http.StreamedResponse(
              const Stream.empty(),
              HttpStatus.ok,
              headers: {
                'content-length': '3',
                'etag': etag,
                'accept-ranges': 'bytes',
                'x-ccpocket-max-chunk-bytes': '16777216',
                'x-ccpocket-transfer-expires': '2026-07-19T12:00:00.000Z',
              },
            );
          }
          return http.StreamedResponse(
            Stream.value(const [4, 5, 6]),
            HttpStatus.partialContent,
            contentLength: 3,
            headers: {
              'content-length': '3',
              'content-range': 'bytes 0-2/3',
              'etag': etag,
            },
          );
        }),
        picker: _FakePicker(
          FileTransferSelection(
            path: picked.path,
            filename: 'cancel.bin',
            sizeBytes: 3,
          ),
        ),
      );
      final upload = service.uploadToMac();
      await _waitUntil(
        () => bridge.sentJson.any(
          (json) => json['type'] == 'file_transfer_upload_prepare_v2',
        ),
      );

      service.pauseActive();
      await upload;
      expect(service.pausedTransfer, isNotNull);
      expect(
        bridge.sentJson.where(
          (json) => json['type'] == 'file_transfer_cancel_v2',
        ),
        isEmpty,
      );

      bridge.emit(_offer());
      await _waitUntil(() => service.queuedReceiveCount == 1);

      bridge.onSend = (json) {
        if (json['type'] != 'file_transfer_cancel_v2') return;
        scheduleMicrotask(() {
          bridge.emit(
            FileTransferCancelResultMessage(
              requestId: json['requestId'] as String,
              transferId: json['transferId'] as String,
              direction: FileTransferCancelDirection.upload,
              success: false,
              errorCode: 'not_found',
            ),
          );
        });
      };
      final pausedId = service.pausedTransfer!.id;
      await service.cancelTransfer(pausedId);
      final cancel = bridge.sentJson.lastWhere(
        (json) => json['type'] == 'file_transfer_cancel_v2',
      );
      final prepare = bridge.sentJson.firstWhere(
        (json) => json['type'] == 'file_transfer_upload_prepare_v2',
      );
      expect(cancel['direction'], 'upload');
      expect(cancel['transferId'], prepare['transferId']);
      expect(cancel['resumeToken'], prepare['resumeToken']);
      expect(service.pausedTransfer, isNull);
      expect(await storage.loadUploads('machine-1'), isEmpty);
      await _waitUntil(
        () => service.recentResults.any(
          (item) => item.status == FileTransferStatus.succeeded,
        ),
      );
      expect(service.queuedReceiveCount, 0);
      expect(
        service.recentResults.any(
          (item) => item.status == FileTransferStatus.cancelled,
        ),
        isTrue,
      );
      expect(await File('${downloads.path}/report.bin').readAsBytes(), [
        4,
        5,
        6,
      ]);
      service.dispose();
    },
  );

  test('ephemeral send race becomes a recoverable paused checkpoint', () async {
    final pickerRoot = await storage.pickerStagingDirectory();
    final picked = File('${pickerRoot.path}/send-race.bin');
    await picked.writeAsBytes(const [1]);
    bridge.throwOnSendOnce = true;
    final service = createService(
      client: MockClient.streaming((request, body) async {
        throw StateError('HTTP must not start after a failed prepare send');
      }),
      picker: _FakePicker(
        FileTransferSelection(
          path: picked.path,
          filename: 'send-race.bin',
          sizeBytes: 1,
        ),
      ),
    );

    await service.uploadToMac();

    expect(service.pausedTransfer, isNotNull);
    expect(service.recentResults.first.errorCode, 'bridge_disconnected');
    expect(await storage.loadUploads('machine-1'), hasLength(1));
    service.dispose();
  });

  test('paused transfer waits for capability after connected event', () async {
    final pickerRoot = await storage.pickerStagingDirectory();
    final picked = File('${pickerRoot.path}/capability-race.bin');
    await picked.writeAsBytes(const [5]);
    var prepareCount = 0;
    String? currentRequestId;
    String? stableTransferId;
    String? resumeToken;
    final client = MockClient.streaming((request, body) async {
      if (request.method == 'HEAD') {
        return http.StreamedResponse(
          const Stream.empty(),
          HttpStatus.ok,
          headers: {
            'upload-offset': '0',
            'upload-length': '1',
            'upload-expires': '2026-07-19T12:00:00.000Z',
            'upload-complete': '0',
            'x-ccpocket-max-chunk-bytes': '16777216',
          },
        );
      }
      expect(await body.toBytes(), [5]);
      scheduleMicrotask(() {
        bridge.emit(
          FileTransferUploadResultMessage(
            requestId: currentRequestId!,
            transferId: stableTransferId!,
            success: true,
            filename: 'capability-race.bin',
            sizeBytes: 1,
          ),
        );
      });
      return http.StreamedResponse(
        const Stream.empty(),
        HttpStatus.noContent,
        headers: {'upload-offset': '1', 'upload-complete': '1'},
      );
    });
    final service = createService(
      client: client,
      picker: _FakePicker(
        FileTransferSelection(
          path: picked.path,
          filename: 'capability-race.bin',
          sizeBytes: 1,
        ),
      ),
    );
    bridge.onSend = (json) {
      if (json['type'] != 'file_transfer_upload_prepare_v2') return;
      prepareCount++;
      currentRequestId = json['requestId'] as String;
      stableTransferId = json['transferId'] as String;
      resumeToken = json['resumeToken'] as String;
      if (prepareCount != 2) return;
      scheduleMicrotask(() {
        bridge.emit(
          FileTransferUploadReadyMessage(
            requestId: currentRequestId!,
            transferId: stableTransferId!,
            uploadUrl:
                'https://mac.example/api/file-transfers/uploads/$stableTransferId',
            uploadToken: token,
            resumeToken: resumeToken!,
            uploadOffset: 0,
            sizeBytes: 1,
            maxChunkSizeBytes: fileTransferChunkBytes,
            expiresAt: '2026-07-19T12:00:00.000Z',
          ),
        );
      });
    };

    final upload = service.uploadToMac();
    await _waitUntil(() => prepareCount == 1);
    service.pauseActive();
    await upload;
    bridge.setCapabilities(const {});
    bridge.setConnected(false);
    bridge.setConnected(true);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(prepareCount, 1);

    bridge.setCapabilities({fileTransferCapability});
    await _waitUntil(
      () => service.recentResults.any(
        (item) => item.status == FileTransferStatus.succeeded,
      ),
    );
    expect(prepareCount, 2);
    service.dispose();
  });

  test('download requests an exact one-byte tail after 16 MiB', () async {
    const offset = fileTransferChunkBytes;
    const total = offset + 1;
    final checkpoint = storage
        .newReceiveCheckpoint(
          logicalIdentity: 'machine-1',
          offer: _offer(sizeBytes: total),
        )
        .copyWith(receivedBytes: offset);
    final partial = await storage.receivePartial(checkpoint);
    final handle = await partial.open(mode: FileMode.write);
    await handle.truncate(offset);
    await handle.close();
    await storage.saveReceive(checkpoint);
    await storage.writeDownloadSecret(
      checkpoint,
      const DownloadTransferSecret(
        downloadUrl:
            'https://mac.example/api/file-transfers/downloads/$transferId',
        downloadToken: token,
        logicalBridgeIdentity: 'machine-1',
      ),
    );
    final client = MockClient.streaming((request, body) async {
      if (request.method == 'HEAD') {
        return http.StreamedResponse(
          const Stream.empty(),
          HttpStatus.ok,
          headers: {
            'content-length': '$total',
            'etag': etag,
            'accept-ranges': 'bytes',
            'x-ccpocket-max-chunk-bytes': '$fileTransferChunkBytes',
            'x-ccpocket-transfer-expires': '2026-07-19T12:00:00.000Z',
          },
        );
      }
      expect(request.headers['range'], 'bytes=$offset-$offset');
      return http.StreamedResponse(
        Stream.value(const [7]),
        HttpStatus.partialContent,
        contentLength: 1,
        headers: {
          'content-length': '1',
          'content-range': 'bytes $offset-$offset/$total',
          'etag': etag,
        },
      );
    });
    final service = createService(client: client);
    bridge.autoDownloadResumeSize = total;

    await service.initialize();
    await _waitUntil(
      () => service.recentResults.any(
        (item) => item.status == FileTransferStatus.succeeded,
      ),
    );

    expect(await File('${downloads.path}/report.bin').length(), total);
    service.dispose();
  });

  test('upload streams an exact 512 KiB tail after 20 MiB', () async {
    const offset = 20 * 1024 * 1024;
    const tail = 512 * 1024;
    const total = offset + tail;
    final pickerRoot = await storage.pickerStagingDirectory();
    final picked = File('${pickerRoot.path}/tail.bin');
    final handle = await picked.open(mode: FileMode.write);
    await handle.truncate(total);
    await handle.close();
    String? requestId;
    String? stableTransferId;
    final client = MockClient.streaming((request, body) async {
      if (request.method == 'HEAD') {
        return http.StreamedResponse(
          const Stream.empty(),
          HttpStatus.ok,
          headers: {
            'upload-offset': '$offset',
            'upload-length': '$total',
            'upload-expires': '2026-07-19T12:00:00.000Z',
            'upload-complete': '0',
            'x-ccpocket-max-chunk-bytes': '$fileTransferChunkBytes',
          },
        );
      }
      expect(request.contentLength, tail);
      var streamed = 0;
      await for (final chunk in body) {
        streamed += chunk.length;
      }
      expect(streamed, tail);
      scheduleMicrotask(() {
        bridge.emit(
          FileTransferUploadResultMessage(
            requestId: requestId!,
            transferId: stableTransferId!,
            success: true,
            filename: 'tail.bin',
            sizeBytes: total,
          ),
        );
      });
      return http.StreamedResponse(
        const Stream.empty(),
        HttpStatus.noContent,
        headers: {'upload-offset': '$total', 'upload-complete': '1'},
      );
    });
    final service = createService(
      client: client,
      picker: _FakePicker(
        FileTransferSelection(
          path: picked.path,
          filename: 'tail.bin',
          sizeBytes: total,
        ),
      ),
    );
    bridge.onSend = (json) {
      if (json['type'] != 'file_transfer_upload_prepare_v2') return;
      requestId = json['requestId'] as String;
      stableTransferId = json['transferId'] as String;
      final resumeToken = json['resumeToken'] as String;
      scheduleMicrotask(() {
        bridge.emit(
          FileTransferUploadReadyMessage(
            requestId: requestId!,
            transferId: stableTransferId!,
            uploadUrl:
                'https://mac.example/api/file-transfers/uploads/$stableTransferId',
            uploadToken: token,
            resumeToken: resumeToken,
            uploadOffset: offset,
            sizeBytes: total,
            maxChunkSizeBytes: fileTransferChunkBytes,
            expiresAt: '2026-07-19T12:00:00.000Z',
          ),
        );
      });
    };

    await service.uploadToMac();

    expect(service.recentResults.first.status, FileTransferStatus.succeeded);
    service.dispose();
  });

  test('failed 4 MiB chunk resumes at a reduced 2 MiB range', () async {
    const total = 20 * 1024 * 1024;
    var rangeAttempts = 0;
    final ranges = <String>[];
    final client = MockClient.streaming((request, body) async {
      if (request.method == 'HEAD') {
        return http.StreamedResponse(
          const Stream.empty(),
          HttpStatus.ok,
          headers: {
            'content-length': '$total',
            'etag': etag,
            'accept-ranges': 'bytes',
            'x-ccpocket-max-chunk-bytes': '16777216',
            'x-ccpocket-transfer-expires': '2026-07-19T12:00:00.000Z',
          },
        );
      }
      rangeAttempts++;
      ranges.add(request.headers['range']!);
      if (rangeAttempts <= 3) {
        return http.StreamedResponse(
          const Stream.empty(),
          HttpStatus.serviceUnavailable,
        );
      }
      final match = RegExp(
        r'^bytes=(\d+)-(\d+)$',
      ).firstMatch(request.headers['range']!)!;
      final start = int.parse(match.group(1)!);
      final end = int.parse(match.group(2)!);
      final length = end - start + 1;
      return http.StreamedResponse(
        Stream.value(Uint8List(length)),
        HttpStatus.partialContent,
        contentLength: length,
        headers: {
          'content-length': '$length',
          'content-range': 'bytes $start-$end/$total',
          'etag': etag,
        },
      );
    });
    final service = createService(client: client);
    bridge.autoDownloadResumeSize = total;
    bridge.emit(_offer(sizeBytes: total));
    await _waitUntil(() => service.pausedTransfer != null);
    expect(ranges.take(3), everyElement('bytes=0-4194303'));

    await service.continuePaused();
    expect(ranges[3], 'bytes=0-2097151');
    expect(service.recentResults.first.status, FileTransferStatus.succeeded);
    service.dispose();
  });
}

FileTransferOfferMessage _offer({
  String id = transferId,
  String downloadOrigin = 'https://mac.example',
  int sizeBytes = 3,
  String filename = 'report.bin',
  String sourceEtag = etag,
  String downloadToken = token,
}) => FileTransferOfferMessage(
  transferId: id,
  filename: filename,
  mimeType: 'application/octet-stream',
  sizeBytes: sizeBytes,
  downloadUrl: '$downloadOrigin/api/file-transfers/downloads/$id',
  downloadToken: downloadToken,
  etag: sourceEtag,
  expiresAt: '2026-07-19T12:00:00.000Z',
);

class _FakeBridge implements FileTransferBridgeGateway {
  final _messages = StreamController<LocalFeatureServerMessage>.broadcast();
  final _connection = StreamController<BridgeConnectionState>.broadcast();
  final _capabilities = StreamController<void>.broadcast();
  final sentJson = <Map<String, dynamic>>[];
  void Function(Map<String, dynamic>)? onSend;
  bool connected = true;
  bool throwOnSendOnce = false;
  int? autoDownloadResumeSize;
  String httpBaseUrlValue = 'https://mac.example';
  String? logicalIdentityValue = 'machine-1';
  Set<String> capabilityValues = {fileTransferCapability};

  @override
  bool get isConnected => connected;
  @override
  String? get httpBaseUrl => httpBaseUrlValue;
  @override
  String? get logicalConnectionIdentity => logicalIdentityValue;
  @override
  Set<String> get capabilities => capabilityValues;
  @override
  Stream<BridgeConnectionState> get connectionStatus => _connection.stream;
  @override
  Stream<void> get capabilityChanges => _capabilities.stream;
  @override
  Stream<LocalFeatureServerMessage> get messages => _messages.stream;

  void emit(LocalFeatureServerMessage message) => _messages.add(message);

  void setConnected(bool value) {
    connected = value;
    _connection.add(
      value
          ? BridgeConnectionState.connected
          : BridgeConnectionState.disconnected,
    );
  }

  void setCapabilities(Set<String> values) {
    capabilityValues = values;
    _capabilities.add(null);
  }

  void setLogicalIdentity(String? value) {
    logicalIdentityValue = value;
    _capabilities.add(null);
  }

  void emitCapabilityEvent() => _capabilities.add(null);

  @override
  void send(ClientMessage message) {
    if (!connected) throw StateError('disconnected');
    if (throwOnSendOnce) {
      throwOnSendOnce = false;
      throw StateError('socket closed during send');
    }
    final json = jsonDecode(message.toJson()) as Map<String, dynamic>;
    sentJson.add(json);
    onSend?.call(json);
    if (json['type'] == 'file_transfer_download_resume_v2' &&
        autoDownloadResumeSize != null) {
      scheduleMicrotask(() {
        emit(
          FileTransferDownloadResumedMessage(
            requestId: json['requestId'] as String,
            transferId: json['transferId'] as String,
            success: true,
            sizeBytes: autoDownloadResumeSize,
            etag: etag,
            expiresAt: '2026-08-01T12:00:00.000Z',
          ),
        );
      });
    }
  }

  Future<void> close() async {
    await _messages.close();
    await _connection.close();
    await _capabilities.close();
  }
}

class _MemorySecretStore implements FileTransferSecretStore {
  final values = <String, String>{};
  bool failDeletes = false;
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> delete(String key) async {
    if (failDeletes) throw StateError('delete failed');
    values.remove(key);
  }
}

class _CountingFileTransferStorage extends FileTransferStorage {
  _CountingFileTransferStorage({
    required super.applicationSupportDirectory,
    required super.downloadsDirectory,
    required super.secretStore,
    super.clock,
  });

  int loadReceivesCount = 0;
  int loadUploadsCount = 0;

  @override
  Future<List<ReceiveTransferCheckpoint>> loadReceives(String logicalIdentity) {
    loadReceivesCount++;
    return super.loadReceives(logicalIdentity);
  }

  @override
  Future<List<UploadTransferCheckpoint>> loadUploads(String logicalIdentity) {
    loadUploadsCount++;
    return super.loadUploads(logicalIdentity);
  }
}

class _BlockingReceiveLoadStorage extends FileTransferStorage {
  _BlockingReceiveLoadStorage({
    required super.applicationSupportDirectory,
    required super.downloadsDirectory,
    required super.secretStore,
    super.clock,
  });

  final loadStarted = Completer<void>();
  final releaseFirstLoad = Completer<void>();
  var _shouldBlock = true;

  @override
  Future<List<ReceiveTransferCheckpoint>> loadReceives(
    String logicalIdentity,
  ) async {
    if (_shouldBlock) {
      _shouldBlock = false;
      loadStarted.complete();
      await releaseFirstLoad.future;
    }
    return super.loadReceives(logicalIdentity);
  }
}

class _BlockingReceiveReconcileStorage extends FileTransferStorage {
  _BlockingReceiveReconcileStorage({
    required super.applicationSupportDirectory,
    required super.downloadsDirectory,
    required super.secretStore,
    super.clock,
  });

  final reconcileStarted = Completer<void>();
  final releaseFirstReconcile = Completer<void>();
  var _shouldBlock = true;

  @override
  Future<File> reconcileReceivePartial(
    ReceiveTransferCheckpoint checkpoint,
  ) async {
    if (_shouldBlock) {
      _shouldBlock = false;
      reconcileStarted.complete();
      await releaseFirstReconcile.future;
    }
    return super.reconcileReceivePartial(checkpoint);
  }
}

class _BlockingDownloadSecretWriteStorage extends FileTransferStorage {
  _BlockingDownloadSecretWriteStorage({
    required super.applicationSupportDirectory,
    required super.downloadsDirectory,
    required super.secretStore,
    super.clock,
  });

  final secretWritten = Completer<void>();
  final releaseFirstSecretWrite = Completer<void>();
  var _shouldBlock = true;

  @override
  Future<void> writeDownloadSecret(
    ReceiveTransferCheckpoint checkpoint,
    DownloadTransferSecret secret,
  ) async {
    await super.writeDownloadSecret(checkpoint, secret);
    if (_shouldBlock) {
      _shouldBlock = false;
      secretWritten.complete();
      await releaseFirstSecretWrite.future;
    }
  }
}

class _FakePicker implements FileTransferDocumentPicker {
  final FileTransferSelection? selection;
  const _FakePicker(this.selection);
  @override
  Future<FileTransferSelection?> pickFile({required int maxSizeBytes}) async =>
      selection;
}

class _FakeCapacity implements FileTransferCapacityGateway {
  const _FakeCapacity();
  @override
  Future<int?> availableCapacityBytes(String path) async =>
      maxFileTransferBytes + fileTransferStorageSafetyReserveBytes;
}

class _FakeCommit implements FileTransferCommitGateway {
  const _FakeCommit();

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
  }) async {
    final partial = File(partialPath);
    final finalFile = File(finalPath);
    if (await partial.exists() && await finalFile.exists()) {
      return const FileTransferCommitProbeResult(
        FileTransferCommitProbe.linked,
        resourceIdentifier: 'resource-1',
      );
    }
    if (!await partial.exists() && await finalFile.exists()) {
      return const FileTransferCommitProbeResult(
        FileTransferCommitProbe.complete,
        resourceIdentifier: 'resource-1',
      );
    }
    return const FileTransferCommitProbeResult(FileTransferCommitProbe.ready);
  }

  @override
  Future<String> linkNoClobber({
    required String partialPath,
    required String finalPath,
  }) async {
    if (await File(finalPath).exists()) {
      throw const FileTransferException('commit_collision');
    }
    await File(partialPath).copy(finalPath);
    return 'resource-1';
  }

  @override
  Future<void> finalizeLinkedCommit({
    required String partialPath,
    required String finalPath,
    required String expectedResourceIdentifier,
  }) async {
    await File(partialPath).delete();
  }
}

class _FakeNotifications implements FileTransferNotificationGateway {
  final receivedNames = <String>[];
  @override
  Future<void> received(String filename) async => receivedNames.add(filename);
  @override
  Future<void> failed(String filename, String message) async {}
}

class _ThrowingNotifications implements FileTransferNotificationGateway {
  const _ThrowingNotifications();

  @override
  Future<void> received(String filename) =>
      Future<void>.error(StateError('notification channel failed'));

  @override
  Future<void> failed(String filename, String message) =>
      throw StateError('notification channel failed');
}

class _CountingThrowingNotifications
    implements FileTransferNotificationGateway {
  var attempts = 0;

  @override
  Future<void> received(String filename) async {
    attempts++;
    throw StateError('notification channel failed');
  }

  @override
  Future<void> failed(String filename, String message) async {}
}

class _FlakyNotifications implements FileTransferNotificationGateway {
  var attempts = 0;
  final receivedNames = <String>[];

  @override
  Future<void> received(String filename) async {
    attempts++;
    if (attempts == 1) throw StateError('notification channel warming up');
    receivedNames.add(filename);
  }

  @override
  Future<void> failed(String filename, String message) async {}
}

class _SequenceIds {
  var value = 0;
  String next() => 'request-${++value}-abcdefghijkl';
}

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition was not reached');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> _waitUntilAsync(Future<bool> Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('async condition was not reached');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
