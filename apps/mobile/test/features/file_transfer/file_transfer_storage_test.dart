import 'dart:convert';
import 'dart:io';

import 'package:ccpocket/features/file_transfer/file_transfer_storage.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:flutter_test/flutter_test.dart';

const transferId = '123e4567-e89b-12d3-a456-426614174000';
const token = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const etag = '"EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE"';

void main() {
  late Directory root;
  late Directory support;
  late Directory downloads;
  late _MemorySecretStore secrets;
  late FileTransferStorage storage;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('ccpocket-v2-storage-');
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
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('receive checkpoint persists only non-secret resume metadata', () async {
    final offer = _offer();
    final checkpoint = storage.newReceiveCheckpoint(
      logicalIdentity: 'machine-1',
      offer: offer,
    );
    final partial = await storage.receivePartial(checkpoint);
    await partial.create();
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

    final loaded = await storage.loadReceives('machine-1');
    expect(loaded, hasLength(1));
    expect(loaded.single.receivedBytes, 0);
    expect(loaded.single.etag, etag);
    final sidecar = support
        .listSync(recursive: true)
        .whereType<File>()
        .singleWhere((file) => file.path.endsWith('.json'));
    final raw = await sidecar.readAsString();
    expect(raw, isNot(contains(token)));
    expect(raw, isNot(contains('https://')));
    expect(
      (await storage.readDownloadSecret(checkpoint))!.downloadToken,
      token,
    );
  });

  test(
    'corrupt receive sidecar cleans its derived partial and Keychain token',
    () async {
      final checkpoint = storage.newReceiveCheckpoint(
        logicalIdentity: 'machine-1',
        offer: _offer(),
      );
      await storage.initializeReceive(checkpoint);
      final partial = await storage.receivePartial(checkpoint);
      await partial.writeAsBytes(const [1, 2, 3]);
      await storage.writeDownloadSecret(
        checkpoint,
        const DownloadTransferSecret(
          downloadUrl:
              'https://mac.example/api/file-transfers/downloads/$transferId',
          downloadToken: token,
          logicalBridgeIdentity: 'machine-1',
        ),
      );
      final sidecar = support
          .listSync(recursive: true)
          .whereType<File>()
          .singleWhere((file) => file.path.endsWith('/$transferId.json'));
      await sidecar.writeAsString('{not-json');

      expect(await storage.loadReceives('machine-1'), isEmpty);

      expect(await sidecar.exists(), isFalse);
      expect(await partial.exists(), isFalse);
      expect(secrets.values, isEmpty);
    },
  );

  test(
    'invalid schema values are corruption rather than future state',
    () async {
      final cases = <String, String>{
        'missing': '{}',
        'string': '{"schemaVersion":"bad"}',
        'negative': '{"schemaVersion":-1}',
      };
      var index = 0;
      for (final entry in cases.entries) {
        index++;
        final id =
            'invalid_schema_${entry.key}_${index.toString().padLeft(16, '0')}';
        final checkpoint = storage.newReceiveCheckpoint(
          logicalIdentity: 'machine-1',
          offer: _offerWithId(id),
        );
        await storage.initializeReceive(checkpoint);
        final partial = await storage.receivePartial(checkpoint);
        await partial.writeAsBytes(const [1, 2, 3]);
        await storage.writeDownloadSecret(
          checkpoint,
          const DownloadTransferSecret(
            downloadUrl:
                'https://mac.example/api/file-transfers/downloads/$transferId',
            downloadToken: token,
            logicalBridgeIdentity: 'machine-1',
          ),
        );
        final sidecar = support
            .listSync(recursive: true)
            .whereType<File>()
            .singleWhere((file) => file.path.endsWith('/$id.json'));
        await sidecar.writeAsString(entry.value);

        expect(
          await storage.loadReceives('machine-1'),
          isEmpty,
          reason: entry.key,
        );
        expect(await sidecar.exists(), isFalse, reason: entry.key);
        expect(await partial.exists(), isFalse, reason: entry.key);
        expect(secrets.values, isEmpty, reason: entry.key);
      }
    },
  );

  test('oversized current receive schema is cleaned as corrupt', () async {
    final checkpoint = storage.newReceiveCheckpoint(
      logicalIdentity: 'machine-1',
      offer: _offer(),
    );
    await storage.initializeReceive(checkpoint);
    final partial = await storage.receivePartial(checkpoint);
    await partial.writeAsBytes(const [1, 2, 3]);
    await storage.writeDownloadSecret(
      checkpoint,
      const DownloadTransferSecret(
        downloadUrl:
            'https://mac.example/api/file-transfers/downloads/$transferId',
        downloadToken: token,
        logicalBridgeIdentity: 'machine-1',
      ),
    );
    final sidecar = support
        .listSync(recursive: true)
        .whereType<File>()
        .singleWhere((file) => file.path.endsWith('/$transferId.json'));
    await _resizeFile(sidecar, fileTransferCheckpointMaxBytes + 1);

    expect(await storage.loadReceives('machine-1'), isEmpty);

    expect(await sidecar.exists(), isFalse);
    expect(await partial.exists(), isFalse);
    expect(secrets.values, isEmpty);
  });

  test('future receive schema survives an app downgrade intact', () async {
    final checkpoint = storage.newReceiveCheckpoint(
      logicalIdentity: 'machine-1',
      offer: _offer(),
    );
    await storage.initializeReceive(checkpoint);
    final partial = await storage.receivePartial(checkpoint);
    await partial.writeAsBytes(const [1, 2, 3]);
    await storage.writeDownloadSecret(
      checkpoint,
      const DownloadTransferSecret(
        downloadUrl:
            'https://mac.example/api/file-transfers/downloads/$transferId',
        downloadToken: token,
        logicalBridgeIdentity: 'machine-1',
      ),
    );
    final sidecar = support
        .listSync(recursive: true)
        .whereType<File>()
        .singleWhere((file) => file.path.endsWith('/$transferId.json'));
    final future =
        jsonDecode(await sidecar.readAsString()) as Map<String, dynamic>;
    future['schemaVersion'] = fileTransferCheckpointVersion + 1;
    await sidecar.writeAsString(jsonEncode(future));
    await _resizeFile(sidecar, fileTransferCheckpointMaxBytes + 1);

    expect(await storage.loadReceives('machine-1'), isEmpty);

    expect(await sidecar.exists(), isTrue);
    expect(await partial.readAsBytes(), const [1, 2, 3]);
    expect(await secrets.read(secrets.values.keys.single), isNotNull);
  });

  test('rejects offsets above declared transfer size', () {
    final now = DateTime.utc(2026, 7, 18).toIso8601String();
    expect(
      () => ReceiveTransferCheckpoint.fromJson({
        'schemaVersion': 2,
        'bridgeKey': 'a' * 64,
        'transferId': transferId,
        'filename': 'report.bin',
        'mimeType': null,
        'sizeBytes': 1,
        'etag': etag,
        'receivedBytes': 2,
        'partialFilename': '.transfer.part',
        'commitState': 'pending',
        'finalFilename': null,
        'createdAt': now,
        'expiresAt': now,
        'updatedAt': now,
      }),
      throwsFormatException,
    );
    expect(
      () => UploadTransferCheckpoint.fromJson({
        'schemaVersion': 2,
        'bridgeKey': 'a' * 64,
        'localId': 'local-1',
        'requestId': 'request-1',
        'transferId': transferId,
        'filename': 'report.bin',
        'sizeBytes': 1,
        'uploadedBytes': 2,
        'stagedFilename': 'local.stage',
        'createdAt': now,
        'expiresAt': now,
        'updatedAt': now,
      }),
      throwsFormatException,
    );
  });

  test('old v2 completions default to no pending notification', () {
    final now = DateTime.utc(2026, 7, 18).toIso8601String();
    final checkpoint = ReceiveTransferCheckpoint.fromJson({
      'schemaVersion': 2,
      'bridgeKey': 'a' * 64,
      'transferId': transferId,
      'filename': 'report.bin',
      'mimeType': null,
      'sizeBytes': 1,
      'etag': etag,
      'receivedBytes': 1,
      'partialFilename': '.transfer.part',
      'commitState': 'complete',
      'finalFilename': 'report.bin',
      'finalResourceIdentifier': 'resource-1',
      'createdAt': now,
      'expiresAt': now,
      'updatedAt': now,
    });

    expect(checkpoint.notificationPending, isFalse);
  });

  test('rejects a pending notification before receive completion', () {
    final now = DateTime.utc(2026, 7, 18).toIso8601String();
    expect(
      () => ReceiveTransferCheckpoint.fromJson({
        'schemaVersion': 2,
        'bridgeKey': 'a' * 64,
        'transferId': transferId,
        'filename': 'report.bin',
        'mimeType': null,
        'sizeBytes': 1,
        'etag': etag,
        'receivedBytes': 0,
        'partialFilename': '.transfer.part',
        'commitState': 'pending',
        'finalFilename': null,
        'finalResourceIdentifier': null,
        'notificationPending': true,
        'createdAt': now,
        'expiresAt': now,
        'updatedAt': now,
      }),
      throwsFormatException,
    );
  });

  test('picker adoption is transactional when secure storage fails', () async {
    final picker = await storage.pickerStagingDirectory();
    final source = File('${picker.path}/picked.bin');
    await source.writeAsBytes(const [1, 2, 3]);
    secrets.failWrites = true;

    await expectLater(
      storage.adoptPickerCopy(
        logicalIdentity: 'machine-1',
        localId: 'local-1',
        requestId: 'request-1',
        transferId: transferId,
        resumeToken: token,
        filename: 'picked.bin',
        sizeBytes: 3,
        pickerCopy: source,
      ),
      throwsStateError,
    );

    expect(
      support
          .listSync(recursive: true)
          .whereType<File>()
          .where(
            (file) =>
                file.path.endsWith('.stage') || file.path.endsWith('.json'),
          ),
      isEmpty,
    );
  });

  test(
    'successful picker adoption removes its owned empty directory',
    () async {
      final picker = await storage.pickerStagingDirectory();
      final owned = Directory(
        '${picker.path}/ccpocket-picker-123E4567-E89B-12D3-A456-426614174000',
      )..createSync();
      final source = File('${owned.path}/picked.stage');
      await source.writeAsBytes(const [1, 2, 3]);

      final checkpoint = await storage.adoptPickerCopy(
        logicalIdentity: 'machine-1',
        localId: 'local-1',
        requestId: 'request-1',
        transferId: transferId,
        resumeToken: token,
        filename: 'picked.bin',
        sizeBytes: 3,
        pickerCopy: source,
      );

      expect(await owned.exists(), isFalse);
      expect(await (await storage.uploadStaged(checkpoint)).readAsBytes(), [
        1,
        2,
        3,
      ]);
    },
  );

  test(
    'startup removes only owned picker orphans without following links',
    () async {
      final picker = await storage.pickerStagingDirectory();
      final owned = Directory(
        '${picker.path}/ccpocket-picker-123E4567-E89B-12D3-A456-426614174000',
      )..createSync();
      await File('${owned.path}/picked.stage').writeAsBytes(const [1, 2, 3]);
      final outside = File('${root.path}/outside.bin');
      await outside.writeAsBytes(const [9]);
      await Link('${owned.path}/outside-link').create(outside.path);
      final unrelated = Directory('${picker.path}/keep-me')..createSync();
      await File('${unrelated.path}/file').writeAsBytes(const [4]);

      await storage.cleanupPickerOrphans();

      expect(await owned.exists(), isFalse);
      expect(await outside.readAsBytes(), [9]);
      expect(await unrelated.exists(), isTrue);
    },
  );

  test(
    'recovery removes an untracked 15 GiB stage without following links',
    () async {
      final paths = await storage.transientDirectoryPaths('machine-1');
      final upload = Directory(paths[2]);
      final orphan = File('${upload.path}/crash-window.stage');
      final orphanHandle = await orphan.open(mode: FileMode.write);
      await orphanHandle.truncate(maxFileTransferBytes);
      await orphanHandle.close();

      final outside = File('${root.path}/outside.bin');
      await outside.writeAsBytes(const [9]);
      final link = Link('${upload.path}/linked.stage');
      await link.create(outside.path);
      final disguisedDirectory = Directory('${upload.path}/directory.stage')
        ..createSync();

      await storage.cleanupUnreferencedUploadStages('machine-1');

      expect(await orphan.exists(), isFalse);
      expect(await outside.readAsBytes(), const [9]);
      expect(
        await FileSystemEntity.type(link.path, followLinks: false),
        FileSystemEntityType.link,
      );
      expect(await disguisedDirectory.exists(), isTrue);
    },
  );

  test('valid upload checkpoint protects its referenced stage', () async {
    final picker = await storage.pickerStagingDirectory();
    final source = File('${picker.path}/picked.bin');
    await source.writeAsBytes(const [1]);
    final checkpoint = await storage.adoptPickerCopy(
      logicalIdentity: 'machine-1',
      localId: 'local-1',
      requestId: 'request-1',
      transferId: transferId,
      resumeToken: token,
      filename: 'picked.bin',
      sizeBytes: 1,
      pickerCopy: source,
    );

    await storage.cleanupUnreferencedUploadStages('machine-1');

    expect(await (await storage.uploadStaged(checkpoint)).readAsBytes(), [1]);
  });

  test('future upload schema protects its staged file on downgrade', () async {
    final picker = await storage.pickerStagingDirectory();
    final source = File('${picker.path}/picked.bin');
    await source.writeAsBytes(const [1]);
    final checkpoint = await storage.adoptPickerCopy(
      logicalIdentity: 'machine-1',
      localId: 'local-1',
      requestId: 'request-1',
      transferId: transferId,
      resumeToken: token,
      filename: 'picked.bin',
      sizeBytes: 1,
      pickerCopy: source,
    );
    final sidecar = support
        .listSync(recursive: true)
        .whereType<File>()
        .singleWhere((file) => file.path.endsWith('/local-1.json'));
    final future =
        jsonDecode(await sidecar.readAsString()) as Map<String, dynamic>;
    future['schemaVersion'] = fileTransferCheckpointVersion + 1;
    await sidecar.writeAsString(jsonEncode(future));
    await _resizeFile(sidecar, fileTransferCheckpointMaxBytes + 1);

    expect(await storage.loadUploads('machine-1'), isEmpty);
    await storage.cleanupUnreferencedUploadStages('machine-1');

    expect(await sidecar.exists(), isTrue);
    expect(await (await storage.uploadStaged(checkpoint)).readAsBytes(), [1]);
  });

  test(
    'stage cleanup fails closed above the checkpoint capacity invariant',
    () async {
      final paths = await storage.transientDirectoryPaths('machine-1');
      final upload = Directory(paths[2]);
      final now = DateTime.utc(2026, 7, 18, 12);
      late File protected;
      for (var index = 0; index <= fileTransferCheckpointScanLimit; index++) {
        final suffix = index.toString().padLeft(8, '0');
        final localId = 'local_$suffix';
        final checkpoint = UploadTransferCheckpoint(
          bridgeKey: storage.bridgeKey('machine-1'),
          localId: localId,
          requestId: 'request_$suffix',
          transferId: 'transfer_identity_$suffix',
          filename: 'file-$suffix.bin',
          sizeBytes: 1,
          uploadedBytes: 0,
          stagedFilename: '$localId.stage',
          createdAt: now,
          expiresAt: now.add(fileTransferCheckpointRetention),
          updatedAt: now,
        );
        await File(
          '${upload.path}/$localId.json',
        ).writeAsString(jsonEncode(checkpoint.toJson()));
        if (index == fileTransferCheckpointScanLimit) {
          protected = File('${upload.path}/${checkpoint.stagedFilename}');
          await protected.writeAsBytes(const [1]);
        }
      }

      await storage.cleanupUnreferencedUploadStages('machine-1');

      expect(await protected.readAsBytes(), const [1]);
    },
  );

  test('concurrent atomic saves never share a temporary filename', () async {
    final checkpoint = storage.newReceiveCheckpoint(
      logicalIdentity: 'machine-1',
      offer: _offer(),
    );
    await Future.wait([
      storage.saveReceive(checkpoint),
      storage.saveReceive(
        checkpoint.copyWith(updatedAt: DateTime.utc(2026, 7, 19)),
      ),
    ]);

    final loaded = await storage.loadReceives('machine-1');
    expect(loaded, hasLength(1));
    expect(
      support
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.tmp')),
      isEmpty,
    );
  });

  test(
    'committing checkpoint survives restart for crash reconciliation',
    () async {
      final pending = storage.newReceiveCheckpoint(
        logicalIdentity: 'machine-1',
        offer: _offer(sizeBytes: 3),
      );
      final partial = await storage.receivePartial(pending);
      await partial.writeAsBytes(const [1, 2, 3]);
      final committing = pending.copyWith(
        receivedBytes: 3,
        commitState: 'committing',
        finalFilename: 'report.bin',
      );
      await storage.saveReceive(committing);

      final loaded = (await storage.loadReceives('machine-1')).single;
      expect(loaded.commitState, 'committing');
      expect(loaded.finalFilename, 'report.bin');
      expect(await (await storage.receivePartial(loaded)).length(), 3);
    },
  );

  test(
    'failed sidecar commit truncates and flushes the part to old offset',
    () async {
      final pending = storage.newReceiveCheckpoint(
        logicalIdentity: 'machine-1',
        offer: _offer(sizeBytes: 1),
      );
      final partial = await storage.receivePartial(pending);
      await partial.writeAsBytes(const [1, 2]);
      final invalid = pending.copyWith(receivedBytes: 2);

      await expectLater(
        storage.commitReceiveChunk(
          checkpoint: invalid,
          partial: partial,
          previousOffset: 1,
        ),
        throwsA(isA<FileTransferStorageException>()),
      );
      expect(await partial.readAsBytes(), const [1]);
    },
  );

  test(
    'recovery truncates crash-only bytes to the durable checkpoint',
    () async {
      final pending = storage
          .newReceiveCheckpoint(
            logicalIdentity: 'machine-1',
            offer: _offer(sizeBytes: 4),
          )
          .copyWith(receivedBytes: 2);
      final partial = await storage.receivePartial(pending);
      await partial.writeAsBytes(const [1, 2, 3, 4]);
      await storage.saveReceive(pending);

      final reconciled = await storage.reconcileReceivePartial(pending);

      expect(await reconciled.readAsBytes(), const [1, 2]);
    },
  );

  test(
    'recovery recreates only a zero-offset pending partial after a crash',
    () async {
      final zero = storage.newReceiveCheckpoint(
        logicalIdentity: 'machine-1',
        offer: _offer(sizeBytes: 2),
      );
      await storage.saveReceive(zero);

      final recreated = await storage.reconcileReceivePartial(zero);

      expect(await recreated.length(), 0);

      final nonzero = zero.copyWith(receivedBytes: 1);
      await recreated.delete();
      await expectLater(
        storage.reconcileReceivePartial(nonzero),
        throwsA(
          isA<FileTransferStorageException>().having(
            (error) => error.code,
            'code',
            'checkpoint_mismatch',
          ),
        ),
      );
    },
  );

  test(
    'upload cleanup keeps metadata last when Keychain deletion fails',
    () async {
      final picker = await storage.pickerStagingDirectory();
      final source = File('${picker.path}/picked.bin');
      await source.writeAsBytes(const [1]);
      final checkpoint = await storage.adoptPickerCopy(
        logicalIdentity: 'machine-1',
        localId: 'local-1',
        requestId: 'request-1',
        transferId: transferId,
        resumeToken: token,
        filename: 'picked.bin',
        sizeBytes: 1,
        pickerCopy: source,
      );
      secrets.failDeletes = true;

      await expectLater(
        storage.deleteUpload(checkpoint, deleteStaged: true),
        throwsStateError,
      );

      expect(await storage.loadUploads('machine-1'), hasLength(1));
      expect(await (await storage.uploadStaged(checkpoint)).exists(), isTrue);
    },
  );

  test(
    'receive cleanup keeps metadata and partial when Keychain deletion fails',
    () async {
      final checkpoint = storage.newReceiveCheckpoint(
        logicalIdentity: 'machine-1',
        offer: _offer(sizeBytes: 1),
      );
      await storage.initializeReceive(checkpoint);
      await storage.writeDownloadSecret(
        checkpoint,
        const DownloadTransferSecret(
          downloadUrl:
              'https://mac.example/api/file-transfers/downloads/$transferId',
          downloadToken: token,
          logicalBridgeIdentity: 'machine-1',
        ),
      );
      secrets.failDeletes = true;

      await expectLater(
        storage.deleteReceive(checkpoint, deletePartial: true),
        throwsStateError,
      );

      expect(await storage.loadReceives('machine-1'), hasLength(1));
      expect(await (await storage.receivePartial(checkpoint)).exists(), isTrue);
    },
  );

  test(
    'checkpoint capacity fails before creating an untracked partial',
    () async {
      final checkpoint = storage.newReceiveCheckpoint(
        logicalIdentity: 'machine-1',
        offer: _offer(),
      );
      final directory = (await storage.receivePartial(checkpoint)).parent;
      for (var index = 0; index < fileTransferCheckpointScanLimit; index++) {
        await File(
          '${directory.path}/dummy-${index.toString().padLeft(4, '0')}.json',
        ).writeAsString('{}');
      }

      await expectLater(
        storage.initializeReceive(checkpoint),
        throwsA(
          isA<FileTransferStorageException>().having(
            (error) => error.code,
            'code',
            'checkpoint_capacity',
          ),
        ),
      );
      expect(
        await (await storage.receivePartial(checkpoint)).exists(),
        isFalse,
      );
    },
  );

  test(
    'bounded loader keeps the newest checkpoint beyond lexical cutoff',
    () async {
      final base = storage.newReceiveCheckpoint(
        logicalIdentity: 'machine-1',
        offer: _offer(),
      );
      final directory = (await storage.receivePartial(base)).parent;
      final oldTime = DateTime.utc(2026, 7, 1);
      for (var index = 0; index < fileTransferCheckpointScanLimit; index++) {
        final id = 'transfer_${index.toString().padLeft(8, '0')}';
        final checkpoint = storage.newReceiveCheckpoint(
          logicalIdentity: 'machine-1',
          offer: _offerWithId(id),
        );
        final file = File('${directory.path}/$id.json');
        await file.writeAsString(jsonEncode(checkpoint.toJson()));
        await file.setLastModified(oldTime);
      }
      const newestId = 'newest_checkpoint';
      final newest = storage.newReceiveCheckpoint(
        logicalIdentity: 'machine-1',
        offer: _offerWithId(newestId),
      );
      await File(
        '${directory.path}/$newestId.json',
      ).writeAsString(jsonEncode(newest.toJson()));

      final loaded = await storage.loadReceives('machine-1');

      expect(loaded, hasLength(fileTransferCheckpointScanLimit));
      expect(loaded.any((item) => item.transferId == newestId), isTrue);
    },
  );
}

FileTransferOfferMessage _offer({int sizeBytes = 32}) =>
    FileTransferOfferMessage(
      transferId: transferId,
      filename: 'report.bin',
      mimeType: 'application/octet-stream',
      sizeBytes: sizeBytes,
      downloadUrl:
          'https://mac.example/api/file-transfers/downloads/$transferId',
      downloadToken: token,
      etag: etag,
      expiresAt: '2026-07-19T12:00:00.000Z',
    );

FileTransferOfferMessage _offerWithId(String id) => FileTransferOfferMessage(
  transferId: id,
  filename: 'report.bin',
  mimeType: 'application/octet-stream',
  sizeBytes: 32,
  downloadUrl: 'https://mac.example/api/file-transfers/downloads/$id',
  downloadToken: token,
  etag: etag,
  expiresAt: '2026-07-19T12:00:00.000Z',
);

Future<void> _resizeFile(File file, int length) async {
  final handle = await file.open(mode: FileMode.append);
  try {
    await handle.truncate(length);
    await handle.flush();
  } finally {
    await handle.close();
  }
}

class _MemorySecretStore implements FileTransferSecretStore {
  final values = <String, String>{};
  bool failWrites = false;
  bool failDeletes = false;

  @override
  Future<void> write(String key, String value) async {
    if (failWrites) throw StateError('write failed');
    values[key] = value;
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> delete(String key) async {
    if (failDeletes) throw StateError('delete failed');
    values.remove(key);
  }
}
