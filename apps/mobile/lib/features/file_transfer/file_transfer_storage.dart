import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import '../../models/messages.dart';

const fileTransferCheckpointVersion = 2;
const fileTransferCheckpointRetention = Duration(days: 7);
const fileTransferCheckpointScanLimit = 512;
const fileTransferCheckpointMaxBytes = 64 * 1024;

abstract interface class FileTransferSecretStore {
  Future<void> write(String key, String value);
  Future<String?> read(String key);
  Future<void> delete(String key);
}

class ReceiveTransferCheckpoint {
  final String bridgeKey;
  final String transferId;
  final String filename;
  final String? mimeType;
  final int sizeBytes;
  final String etag;
  final int receivedBytes;
  final String partialFilename;
  final String commitState;
  final String? finalFilename;
  final String? finalResourceIdentifier;
  final bool notificationPending;
  final DateTime createdAt;
  final DateTime expiresAt;
  final DateTime updatedAt;

  const ReceiveTransferCheckpoint({
    required this.bridgeKey,
    required this.transferId,
    required this.filename,
    required this.mimeType,
    required this.sizeBytes,
    required this.etag,
    required this.receivedBytes,
    required this.partialFilename,
    required this.commitState,
    required this.finalFilename,
    required this.finalResourceIdentifier,
    this.notificationPending = false,
    required this.createdAt,
    required this.expiresAt,
    required this.updatedAt,
  });

  ReceiveTransferCheckpoint copyWith({
    int? receivedBytes,
    DateTime? expiresAt,
    DateTime? updatedAt,
    String? commitState,
    String? finalFilename,
    String? finalResourceIdentifier,
    bool? notificationPending,
  }) => ReceiveTransferCheckpoint(
    bridgeKey: bridgeKey,
    transferId: transferId,
    filename: filename,
    mimeType: mimeType,
    sizeBytes: sizeBytes,
    etag: etag,
    receivedBytes: receivedBytes ?? this.receivedBytes,
    partialFilename: partialFilename,
    commitState: commitState ?? this.commitState,
    finalFilename: finalFilename ?? this.finalFilename,
    finalResourceIdentifier:
        finalResourceIdentifier ?? this.finalResourceIdentifier,
    notificationPending: notificationPending ?? this.notificationPending,
    createdAt: createdAt,
    expiresAt: expiresAt ?? this.expiresAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, Object?> toJson() => {
    'schemaVersion': fileTransferCheckpointVersion,
    'bridgeKey': bridgeKey,
    'transferId': transferId,
    'filename': filename,
    'mimeType': mimeType,
    'sizeBytes': sizeBytes,
    'etag': etag,
    'receivedBytes': receivedBytes,
    'partialFilename': partialFilename,
    'commitState': commitState,
    'finalFilename': finalFilename,
    'finalResourceIdentifier': finalResourceIdentifier,
    'notificationPending': notificationPending,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  factory ReceiveTransferCheckpoint.fromJson(Map<String, dynamic> json) {
    _requireCheckpointSchemaVersion(json, 'receive');
    final sizeBytes = _boundedSize(json, 'sizeBytes');
    final receivedBytes = _boundedSize(json, 'receivedBytes');
    if (receivedBytes > sizeBytes) {
      throw const FormatException('Receive checkpoint offset exceeds size');
    }
    final commitState = _requiredText(json, 'commitState', 16);
    if (!const {'pending', 'committing', 'complete'}.contains(commitState)) {
      throw const FormatException('Invalid receive commit state');
    }
    final finalFilename = json['finalFilename'] == null
        ? null
        : _safeLeaf(json, 'finalFilename');
    final finalResourceIdentifier = _optionalText(
      json,
      'finalResourceIdentifier',
      512,
    );
    final rawNotificationPending = json['notificationPending'];
    if (rawNotificationPending != null && rawNotificationPending is! bool) {
      throw const FormatException('Invalid notification state');
    }
    final notificationPending = rawNotificationPending == true;
    if (commitState == 'committing' &&
        (receivedBytes != sizeBytes || finalFilename == null)) {
      throw const FormatException('Invalid committing checkpoint');
    }
    if (commitState == 'complete' &&
        (receivedBytes != sizeBytes ||
            finalFilename == null ||
            finalResourceIdentifier == null)) {
      throw const FormatException('Invalid complete checkpoint');
    }
    if (notificationPending && commitState != 'complete') {
      throw const FormatException('Invalid notification state');
    }
    return ReceiveTransferCheckpoint(
      bridgeKey: _requiredText(json, 'bridgeKey', 64),
      transferId: _requiredTransferId(json, 'transferId'),
      filename: _requiredText(json, 'filename', 1024),
      mimeType: _optionalText(json, 'mimeType', 256),
      sizeBytes: sizeBytes,
      etag: _requiredEtag(json, 'etag'),
      receivedBytes: receivedBytes,
      partialFilename: _safeLeaf(json, 'partialFilename'),
      commitState: commitState,
      finalFilename: finalFilename,
      finalResourceIdentifier: finalResourceIdentifier,
      notificationPending: notificationPending,
      createdAt: _requiredDate(json, 'createdAt'),
      expiresAt: _requiredDate(json, 'expiresAt'),
      updatedAt: _requiredDate(json, 'updatedAt'),
    );
  }
}

class UploadTransferCheckpoint {
  final String bridgeKey;
  final String localId;
  final String requestId;
  final String transferId;
  final String filename;
  final int sizeBytes;
  final int uploadedBytes;
  final String stagedFilename;
  final DateTime createdAt;
  final DateTime expiresAt;
  final DateTime updatedAt;

  const UploadTransferCheckpoint({
    required this.bridgeKey,
    required this.localId,
    required this.requestId,
    required this.transferId,
    required this.filename,
    required this.sizeBytes,
    required this.uploadedBytes,
    required this.stagedFilename,
    required this.createdAt,
    required this.expiresAt,
    required this.updatedAt,
  });

  UploadTransferCheckpoint copyWith({
    String? requestId,
    int? uploadedBytes,
    DateTime? expiresAt,
    DateTime? updatedAt,
  }) => UploadTransferCheckpoint(
    bridgeKey: bridgeKey,
    localId: localId,
    requestId: requestId ?? this.requestId,
    transferId: transferId,
    filename: filename,
    sizeBytes: sizeBytes,
    uploadedBytes: uploadedBytes ?? this.uploadedBytes,
    stagedFilename: stagedFilename,
    createdAt: createdAt,
    expiresAt: expiresAt ?? this.expiresAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, Object?> toJson() => {
    'schemaVersion': fileTransferCheckpointVersion,
    'bridgeKey': bridgeKey,
    'localId': localId,
    'requestId': requestId,
    'transferId': transferId,
    'filename': filename,
    'sizeBytes': sizeBytes,
    'uploadedBytes': uploadedBytes,
    'stagedFilename': stagedFilename,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  factory UploadTransferCheckpoint.fromJson(Map<String, dynamic> json) {
    _requireCheckpointSchemaVersion(json, 'upload');
    final sizeBytes = _boundedSize(json, 'sizeBytes');
    final uploadedBytes = _boundedSize(json, 'uploadedBytes');
    if (uploadedBytes > sizeBytes) {
      throw const FormatException('Upload checkpoint offset exceeds size');
    }
    return UploadTransferCheckpoint(
      bridgeKey: _requiredText(json, 'bridgeKey', 64),
      localId: _requiredText(json, 'localId', 128),
      requestId: _requiredText(json, 'requestId', 128),
      transferId: _requiredTransferId(json, 'transferId'),
      filename: _requiredText(json, 'filename', 1024),
      sizeBytes: sizeBytes,
      uploadedBytes: uploadedBytes,
      stagedFilename: _safeLeaf(json, 'stagedFilename'),
      createdAt: _requiredDate(json, 'createdAt'),
      expiresAt: _requiredDate(json, 'expiresAt'),
      updatedAt: _requiredDate(json, 'updatedAt'),
    );
  }
}

class DownloadTransferSecret {
  final String downloadUrl;
  final String downloadToken;
  final String logicalBridgeIdentity;

  const DownloadTransferSecret({
    required this.downloadUrl,
    required this.downloadToken,
    required this.logicalBridgeIdentity,
  });

  String encode() => jsonEncode({
    'downloadUrl': downloadUrl,
    'downloadToken': downloadToken,
    'logicalBridgeIdentity': logicalBridgeIdentity,
  });

  factory DownloadTransferSecret.decode(String value) {
    final json = jsonDecode(value);
    if (json is! Map<String, dynamic>) {
      throw const FormatException('Invalid download secret');
    }
    return DownloadTransferSecret(
      downloadUrl: _requiredText(json, 'downloadUrl', 4096),
      downloadToken: _requiredToken(json, 'downloadToken'),
      logicalBridgeIdentity: _requiredText(json, 'logicalBridgeIdentity', 512),
    );
  }
}

class UploadTransferSecret {
  final String? uploadUrl;
  final String? uploadToken;
  final String resumeToken;
  final String logicalBridgeIdentity;

  const UploadTransferSecret({
    required this.uploadUrl,
    required this.uploadToken,
    required this.resumeToken,
    required this.logicalBridgeIdentity,
  });

  String encode() => jsonEncode({
    'uploadUrl': uploadUrl,
    'uploadToken': uploadToken,
    'resumeToken': resumeToken,
    'logicalBridgeIdentity': logicalBridgeIdentity,
  });

  factory UploadTransferSecret.decode(String value) {
    final json = jsonDecode(value);
    if (json is! Map<String, dynamic>) {
      throw const FormatException('Invalid upload secret');
    }
    return UploadTransferSecret(
      uploadUrl: _optionalText(json, 'uploadUrl', 4096),
      uploadToken: _optionalToken(json, 'uploadToken'),
      resumeToken: _requiredToken(json, 'resumeToken'),
      logicalBridgeIdentity: _requiredText(json, 'logicalBridgeIdentity', 512),
    );
  }
}

typedef TransferDirectoryProvider = Future<Directory> Function();

class FileTransferStorage {
  FileTransferStorage({
    required TransferDirectoryProvider applicationSupportDirectory,
    required TransferDirectoryProvider downloadsDirectory,
    required FileTransferSecretStore secretStore,
    DateTime Function()? clock,
  }) : _applicationSupportDirectory = applicationSupportDirectory,
       _downloadsDirectory = downloadsDirectory,
       _secretStore = secretStore,
       _clock = clock ?? DateTime.now;

  final TransferDirectoryProvider _applicationSupportDirectory;
  final TransferDirectoryProvider _downloadsDirectory;
  final FileTransferSecretStore _secretStore;
  final DateTime Function() _clock;
  Future<void> _checkpointWriteTail = Future<void>.value();
  Future<void> _uploadMutationTail = Future<void>.value();

  String bridgeKey(String logicalIdentity) =>
      sha256.convert(utf8.encode(logicalIdentity)).toString();

  Future<Directory> pickerStagingDirectory() async {
    final support = await _applicationSupportDirectory();
    final directory = Directory(
      path.join(support.path, 'CCPocketFileTransfers', 'v2', 'picker'),
    );
    await directory.create(recursive: true);
    return directory;
  }

  Future<File> receivePartial(ReceiveTransferCheckpoint checkpoint) async {
    final directory = await _receiveDirectory(checkpoint.bridgeKey);
    return File(path.join(directory.path, checkpoint.partialFilename));
  }

  Future<Directory> downloadsDirectory() async {
    final downloads = await _downloadsDirectory();
    await downloads.create(recursive: true);
    return downloads;
  }

  Future<List<String>> transientDirectoryPaths(String logicalIdentity) async {
    final key = bridgeKey(logicalIdentity);
    final root = await _scopeRoot(key);
    final receive = await _receiveDirectory(key);
    final upload = await _uploadDirectory(key);
    final picker = await pickerStagingDirectory();
    return [root.path, receive.path, upload.path, picker.path];
  }

  Future<File> uploadStaged(UploadTransferCheckpoint checkpoint) async {
    final directory = await _uploadDirectory(checkpoint.bridgeKey);
    return File(path.join(directory.path, checkpoint.stagedFilename));
  }

  Future<UploadTransferCheckpoint> adoptPickerCopy({
    required String logicalIdentity,
    required String localId,
    required String requestId,
    required String transferId,
    required String resumeToken,
    required String filename,
    required int sizeBytes,
    required File pickerCopy,
  }) => _withUploadMutation(() async {
    final pickerRoot = await pickerStagingDirectory();
    final pickerResolved = await pickerRoot.resolveSymbolicLinks();
    final sourceResolved = await pickerCopy.resolveSymbolicLinks();
    if (!_isDescendant(pickerResolved, sourceResolved) ||
        await FileSystemEntity.type(pickerCopy.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await pickerCopy.length() != sizeBytes) {
      throw const FileTransferStorageException('invalid_picker_copy');
    }
    final key = bridgeKey(logicalIdentity);
    final directory = await _uploadDirectory(key);
    final stagedFilename = '${_safeId(localId)}.stage';
    final staged = File(path.join(directory.path, stagedFilename));
    if (await staged.exists()) {
      throw const FileTransferStorageException('staging_collision');
    }
    UploadTransferCheckpoint? checkpoint;
    try {
      await pickerCopy.rename(staged.path);
      final now = _clock().toUtc();
      checkpoint = UploadTransferCheckpoint(
        bridgeKey: key,
        localId: localId,
        requestId: requestId,
        transferId: transferId,
        filename: filename,
        sizeBytes: sizeBytes,
        uploadedBytes: 0,
        stagedFilename: stagedFilename,
        createdAt: now,
        expiresAt: now.add(fileTransferCheckpointRetention),
        updatedAt: now,
      );
      await saveUpload(checkpoint);
      await writeUploadSecret(
        checkpoint,
        UploadTransferSecret(
          uploadUrl: null,
          uploadToken: null,
          resumeToken: resumeToken,
          logicalBridgeIdentity: logicalIdentity,
        ),
      );
      return checkpoint;
    } catch (_) {
      if (checkpoint != null) {
        await _deleteUploadUnlocked(checkpoint, deleteStaged: true);
      } else {
        await _deleteIfExists(staged);
      }
      rethrow;
    } finally {
      await _deleteOwnedPickerDirectory(
        pickerRoot: pickerRoot,
        candidate: pickerCopy.parent,
      );
    }
  });

  Future<void> cleanupPickerOrphans() async {
    final pickerRoot = await pickerStagingDirectory();
    await for (final entity in pickerRoot.list(followLinks: false)) {
      if (!_isOwnedPickerDirectoryName(path.basename(entity.path))) continue;
      await _deleteOwnedPickerDirectory(
        pickerRoot: pickerRoot,
        candidate: Directory(entity.path),
      );
    }
  }

  ReceiveTransferCheckpoint newReceiveCheckpoint({
    required String logicalIdentity,
    required FileTransferOfferMessage offer,
  }) {
    final key = bridgeKey(logicalIdentity);
    final now = _clock().toUtc();
    return ReceiveTransferCheckpoint(
      bridgeKey: key,
      transferId: offer.transferId,
      filename: offer.filename,
      mimeType: offer.mimeType,
      sizeBytes: offer.sizeBytes,
      etag: offer.etag,
      receivedBytes: 0,
      partialFilename: _receivePartialFilename(offer.transferId),
      commitState: 'pending',
      finalFilename: null,
      finalResourceIdentifier: null,
      createdAt: now,
      expiresAt: now.add(fileTransferCheckpointRetention),
      updatedAt: now,
    );
  }

  Future<void> saveReceive(ReceiveTransferCheckpoint checkpoint) async {
    if (checkpoint.receivedBytes > checkpoint.sizeBytes) {
      throw const FileTransferStorageException('invalid_receive_offset');
    }
    if (checkpoint.commitState == 'committing' &&
        (checkpoint.receivedBytes != checkpoint.sizeBytes ||
            checkpoint.finalFilename == null)) {
      throw const FileTransferStorageException('invalid_commit_checkpoint');
    }
    if (checkpoint.commitState == 'complete' &&
        (checkpoint.receivedBytes != checkpoint.sizeBytes ||
            checkpoint.finalFilename == null ||
            checkpoint.finalResourceIdentifier == null)) {
      throw const FileTransferStorageException('invalid_complete_checkpoint');
    }
    if (checkpoint.notificationPending &&
        checkpoint.commitState != 'complete') {
      throw const FileTransferStorageException(
        'invalid_notification_checkpoint',
      );
    }
    final directory = await _receiveDirectory(checkpoint.bridgeKey);
    final destination = File(
      path.join(directory.path, '${_safeId(checkpoint.transferId)}.json'),
    );
    await _saveBoundedCheckpoint(destination, checkpoint.toJson());
  }

  Future<void> initializeReceive(ReceiveTransferCheckpoint checkpoint) async {
    final partial = await receivePartial(checkpoint);
    try {
      await saveReceive(checkpoint);
      await partial.create(exclusive: true);
    } catch (_) {
      await deleteReceive(checkpoint, deletePartial: true);
      rethrow;
    }
  }

  Future<File> reconcileReceivePartial(
    ReceiveTransferCheckpoint checkpoint,
  ) async {
    final partial = await receivePartial(checkpoint);
    var type = await FileSystemEntity.type(partial.path, followLinks: false);
    if (type == FileSystemEntityType.notFound &&
        checkpoint.commitState == 'pending' &&
        checkpoint.receivedBytes == 0) {
      try {
        await partial.create(exclusive: true);
      } on FileSystemException {
        // Another recovery path may have created the same private part after
        // the no-follow probe. Re-check its type before accepting it.
      }
      type = await FileSystemEntity.type(partial.path, followLinks: false);
    }
    if (type != FileSystemEntityType.file) {
      throw const FileTransferStorageException('checkpoint_mismatch');
    }
    final length = await partial.length();
    if (length < checkpoint.receivedBytes) {
      throw const FileTransferStorageException('checkpoint_mismatch');
    }
    if (length > checkpoint.receivedBytes) {
      final handle = await partial.open(mode: FileMode.writeOnlyAppend);
      try {
        await handle.truncate(checkpoint.receivedBytes);
        await handle.flush();
      } finally {
        await handle.close();
      }
    }
    return partial;
  }

  Future<void> commitReceiveChunk({
    required ReceiveTransferCheckpoint checkpoint,
    required File partial,
    required int previousOffset,
  }) async {
    if (previousOffset < 0 ||
        checkpoint.receivedBytes < previousOffset ||
        await partial.length() != checkpoint.receivedBytes) {
      throw const FileTransferStorageException('invalid_chunk_commit');
    }
    try {
      await saveReceive(checkpoint);
    } catch (_) {
      final handle = await partial.open(mode: FileMode.writeOnlyAppend);
      try {
        await handle.truncate(previousOffset);
        await handle.flush();
      } finally {
        await handle.close();
      }
      rethrow;
    }
  }

  Future<void> saveUpload(UploadTransferCheckpoint checkpoint) async {
    if (checkpoint.uploadedBytes > checkpoint.sizeBytes) {
      throw const FileTransferStorageException('invalid_upload_offset');
    }
    final directory = await _uploadDirectory(checkpoint.bridgeKey);
    final destination = File(
      path.join(directory.path, '${_safeId(checkpoint.localId)}.json'),
    );
    await _saveBoundedCheckpoint(destination, checkpoint.toJson());
  }

  Future<List<ReceiveTransferCheckpoint>> loadReceives(
    String logicalIdentity,
  ) async {
    final key = bridgeKey(logicalIdentity);
    final directory = await _receiveDirectory(key);
    final items = (await _loadJsonFiles(
      directory,
      ReceiveTransferCheckpoint.fromJson,
      onInvalid: (sidecar) => _cleanupInvalidReceiveSidecar(
        sidecar: sidecar,
        directory: directory,
        bridgeKey: key,
      ),
    )).where((item) => item.bridgeKey == key).toList();
    items.sort((left, right) {
      final state = _receiveStatePriority(
        left.commitState,
      ).compareTo(_receiveStatePriority(right.commitState));
      return state != 0 ? state : right.updatedAt.compareTo(left.updatedAt);
    });
    return items.take(fileTransferCheckpointScanLimit).toList(growable: false);
  }

  Future<List<UploadTransferCheckpoint>> loadUploads(
    String logicalIdentity,
  ) async {
    final key = bridgeKey(logicalIdentity);
    final directory = await _uploadDirectory(key);
    final items = (await _loadJsonFiles(
      directory,
      UploadTransferCheckpoint.fromJson,
    )).where((item) => item.bridgeKey == key).toList();
    items.sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
    return items.take(fileTransferCheckpointScanLimit).toList(growable: false);
  }

  Future<void> writeDownloadSecret(
    ReceiveTransferCheckpoint checkpoint,
    DownloadTransferSecret secret,
  ) => _secretStore.write(_downloadSecretKey(checkpoint), secret.encode());

  Future<DownloadTransferSecret?> readDownloadSecret(
    ReceiveTransferCheckpoint checkpoint,
  ) async {
    final value = await _secretStore.read(_downloadSecretKey(checkpoint));
    if (value == null) return null;
    return DownloadTransferSecret.decode(value);
  }

  Future<void> writeUploadSecret(
    UploadTransferCheckpoint checkpoint,
    UploadTransferSecret secret,
  ) => _secretStore.write(_uploadSecretKey(checkpoint), secret.encode());

  Future<UploadTransferSecret?> readUploadSecret(
    UploadTransferCheckpoint checkpoint,
  ) async {
    final value = await _secretStore.read(_uploadSecretKey(checkpoint));
    if (value == null) return null;
    return UploadTransferSecret.decode(value);
  }

  Future<void> deleteReceive(
    ReceiveTransferCheckpoint checkpoint, {
    required bool deletePartial,
  }) async {
    final directory = await _receiveDirectory(checkpoint.bridgeKey);
    await _secretStore.delete(_downloadSecretKey(checkpoint));
    if (deletePartial) {
      await _deleteRegularFileIfExists(await receivePartial(checkpoint));
    }
    await _deleteRegularFileIfExists(
      File(path.join(directory.path, '${_safeId(checkpoint.transferId)}.json')),
    );
  }

  Future<void> clearDownloadSecret(ReceiveTransferCheckpoint checkpoint) =>
      _secretStore.delete(_downloadSecretKey(checkpoint));

  Future<void> deleteUpload(
    UploadTransferCheckpoint checkpoint, {
    required bool deleteStaged,
  }) => _withUploadMutation(
    () => _deleteUploadUnlocked(checkpoint, deleteStaged: deleteStaged),
  );

  Future<void> _deleteUploadUnlocked(
    UploadTransferCheckpoint checkpoint, {
    required bool deleteStaged,
  }) async {
    final directory = await _uploadDirectory(checkpoint.bridgeKey);
    await _secretStore.delete(_uploadSecretKey(checkpoint));
    if (deleteStaged) {
      await _deleteRegularFileIfExists(await uploadStaged(checkpoint));
    }
    await _deleteRegularFileIfExists(
      File(path.join(directory.path, '${_safeId(checkpoint.localId)}.json')),
    );
  }

  Future<void> cleanupUnreferencedUploadStages(
    String logicalIdentity,
  ) => _withUploadMutation(() async {
    final key = bridgeKey(logicalIdentity);
    final directory = await _uploadDirectory(key);
    // Read every sidecar allowed by the write-capacity invariant while holding
    // the same mutation lease used by adoption. Never derive ownership from a
    // recent-results view: an older valid checkpoint still owns its stage.
    final referenced = <String>{};
    var sidecarCount = 0;
    await for (final entity in directory.list(followLinks: false)) {
      if (!entity.path.endsWith('.json') ||
          await FileSystemEntity.type(entity.path, followLinks: false) !=
              FileSystemEntityType.file) {
        continue;
      }
      sidecarCount++;
      if (sidecarCount > fileTransferCheckpointScanLimit) {
        // Out-of-invariant state: fail closed instead of risking deletion of a
        // stage referenced by a sidecar outside a bounded scan.
        return;
      }
      final sidecar = File(entity.path);
      try {
        if (await sidecar.length() > fileTransferCheckpointMaxBytes) {
          if (await _oversizedCheckpointMayUseUnsupportedSchema(sidecar)) {
            return;
          }
          continue;
        }
        final decoded = jsonDecode(await sidecar.readAsString());
        if (decoded is! Map<String, dynamic>) continue;
        final checkpoint = UploadTransferCheckpoint.fromJson(decoded);
        if (checkpoint.bridgeKey == key) {
          referenced.add(checkpoint.stagedFilename);
        }
      } on _UnsupportedFileTransferCheckpointVersion {
        // A downgraded app must not destroy a stage owned by a newer schema it
        // cannot decode. Fail closed for this cleanup pass; a future version
        // can recover both the sidecar and its private staged file.
        return;
      } catch (_) {
        // Invalid metadata does not establish ownership of a raw stage.
      }
    }
    await for (final entity in directory.list(followLinks: false)) {
      final leaf = path.basename(entity.path);
      if (!_isOwnedUploadStageName(leaf) || referenced.contains(leaf)) {
        continue;
      }
      if (await FileSystemEntity.type(entity.path, followLinks: false) !=
          FileSystemEntityType.file) {
        continue;
      }
      await File(entity.path).delete();
    }
  });

  Future<T> _withUploadMutation<T>(Future<T> Function() action) async {
    final previous = _uploadMutationTail;
    final release = Completer<void>();
    _uploadMutationTail = release.future;
    await previous;
    try {
      return await action();
    } finally {
      release.complete();
    }
  }

  Future<void> _saveBoundedCheckpoint(
    File destination,
    Map<String, Object?> json,
  ) async {
    if (await destination.exists()) {
      await _atomicJson(destination, json);
      return;
    }
    final previous = _checkpointWriteTail;
    final release = Completer<void>();
    _checkpointWriteTail = release.future;
    await previous;
    try {
      if (!await destination.exists()) {
        var count = 0;
        await for (final entity in destination.parent.list(
          followLinks: false,
        )) {
          if (!entity.path.endsWith('.json')) continue;
          if (await FileSystemEntity.type(entity.path, followLinks: false) !=
              FileSystemEntityType.file) {
            continue;
          }
          count++;
          if (count >= fileTransferCheckpointScanLimit) {
            throw const FileTransferStorageException('checkpoint_capacity');
          }
        }
      }
      await _atomicJson(destination, json);
    } finally {
      release.complete();
    }
  }

  Future<Directory> _scopeRoot(String bridgeKey) async {
    final support = await _applicationSupportDirectory();
    final directory = Directory(
      path.join(
        support.path,
        'CCPocketFileTransfers',
        'v2',
        _safeId(bridgeKey),
      ),
    );
    await directory.create(recursive: true);
    return directory;
  }

  Future<Directory> _receiveDirectory(String bridgeKey) async {
    final root = await _scopeRoot(bridgeKey);
    final directory = Directory(path.join(root.path, 'receive'));
    await directory.create(recursive: true);
    return directory;
  }

  Future<Directory> _uploadDirectory(String bridgeKey) async {
    final root = await _scopeRoot(bridgeKey);
    final directory = Directory(path.join(root.path, 'upload'));
    await directory.create(recursive: true);
    return directory;
  }

  Future<void> _cleanupInvalidReceiveSidecar({
    required File sidecar,
    required Directory directory,
    required String bridgeKey,
  }) async {
    final directoryPath = path.normalize(path.absolute(directory.path));
    final sidecarPath = path.normalize(path.absolute(sidecar.path));
    if (path.dirname(sidecarPath) != directoryPath) return;
    final leaf = path.basename(sidecarPath);
    if (!leaf.endsWith('.json')) return;
    final transferId = leaf.substring(0, leaf.length - '.json'.length);
    if (!RegExp(r'^[A-Za-z0-9_-]{16,128}$').hasMatch(transferId)) return;

    // Legitimate v2 receive sidecars are named from the validated transfer id,
    // so corrupt metadata cannot redirect cleanup. Keep the sidecar until both
    // its Keychain token and strictly derived regular partial are gone; a
    // transient cleanup failure can therefore be retried on the next scan.
    await _secretStore.delete(_downloadSecretKeyParts(bridgeKey, transferId));
    await _deleteRegularFileIfExists(
      File(path.join(directoryPath, _receivePartialFilename(transferId))),
    );
  }
}

class FileTransferStorageException implements Exception {
  final String code;
  const FileTransferStorageException(this.code);
}

class _UnsupportedFileTransferCheckpointVersion extends FormatException {
  const _UnsupportedFileTransferCheckpointVersion(super.message);
}

Future<List<T>> _loadJsonFiles<T>(
  Directory directory,
  T Function(Map<String, dynamic>) decode, {
  Future<void> Function(File sidecar)? onInvalid,
}) async {
  final entities = await directory
      .list(followLinks: false)
      .where((entity) => entity.path.endsWith('.json'))
      .take(fileTransferCheckpointScanLimit * 2)
      .toList();
  final candidates = <({File file, DateTime modified})>[];
  for (final entity in entities) {
    if (await FileSystemEntity.type(entity.path, followLinks: false) !=
        FileSystemEntityType.file) {
      continue;
    }
    final file = File(entity.path);
    final stat = await file.stat();
    candidates.add((file: file, modified: stat.modified));
  }
  candidates.sort((left, right) {
    final modified = right.modified.compareTo(left.modified);
    return modified != 0 ? modified : right.file.path.compareTo(left.file.path);
  });
  final values = <T>[];
  for (final candidate in candidates.take(fileTransferCheckpointScanLimit)) {
    final file = candidate.file;
    try {
      if (await file.length() > fileTransferCheckpointMaxBytes) {
        if (await _oversizedCheckpointMayUseUnsupportedSchema(file)) {
          // The current writer always emits schemaVersion first. If a bounded
          // prefix cannot prove that this oversized file is current v2 state,
          // preserve it across a downgrade instead of destructively guessing.
          continue;
        }
        await onInvalid?.call(file);
        await _deleteRegularFileIfExists(file);
        continue;
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Invalid checkpoint object');
      }
      values.add(decode(decoded));
    } on _UnsupportedFileTransferCheckpointVersion {
      // Preserve a future schema and all of its private assets across an app
      // downgrade. It remains outside the current recovery view.
    } catch (_) {
      // This is an app-private sidecar. Invalid state cannot safely resume and
      // is removed only after any strictly derivable owned assets are cleaned.
      // If cleanup fails, metadata remains the durable retry marker.
      try {
        await onInvalid?.call(file);
        await _deleteRegularFileIfExists(file);
      } catch (_) {}
    }
  }
  return values;
}

bool _isOwnedPickerDirectoryName(String value) => RegExp(
  r'^ccpocket-picker-[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$',
).hasMatch(value);

bool _isOwnedUploadStageName(String value) =>
    RegExp(r'^[A-Za-z0-9_-]{1,128}\.stage$').hasMatch(value);

Future<void> _deleteOwnedPickerDirectory({
  required Directory pickerRoot,
  required Directory candidate,
}) async {
  try {
    final rootPath = path.normalize(path.absolute(pickerRoot.path));
    final candidatePath = path.normalize(path.absolute(candidate.path));
    if (path.dirname(candidatePath) != rootPath ||
        !_isOwnedPickerDirectoryName(path.basename(candidatePath))) {
      return;
    }
    final type = await FileSystemEntity.type(candidatePath, followLinks: false);
    if (type == FileSystemEntityType.link) {
      await Link(candidatePath).delete();
      return;
    }
    if (type != FileSystemEntityType.directory) return;
    await _deleteTreeNoFollow(Directory(candidatePath));
  } catch (_) {
    // Best-effort cleanup must never mask the transfer result.
  }
}

Future<void> _deleteTreeNoFollow(Directory directory) async {
  await for (final entity in directory.list(followLinks: false)) {
    final type = await FileSystemEntity.type(entity.path, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      await _deleteTreeNoFollow(Directory(entity.path));
    } else if (type == FileSystemEntityType.file) {
      await File(entity.path).delete();
    } else if (type == FileSystemEntityType.link) {
      await Link(entity.path).delete();
    }
  }
  await directory.delete();
}

int _receiveStatePriority(String value) => switch (value) {
  'committing' => 0,
  'pending' => 1,
  'complete' => 2,
  _ => 3,
};

Future<void> _atomicJson(File destination, Map<String, Object?> json) async {
  await destination.parent.create(recursive: true);
  final random = Random.secure();
  final nonce = List<int>.generate(12, (_) => random.nextInt(256));
  final suffix = base64Url.encode(nonce).replaceAll('=', '');
  final temporary = File('${destination.path}.$suffix.tmp');
  try {
    final handle = await temporary.open(mode: FileMode.writeOnly);
    try {
      await handle.writeString(jsonEncode(json));
      await handle.flush();
    } finally {
      await handle.close();
    }
    await temporary.rename(destination.path);
  } finally {
    await _deleteIfExists(temporary);
  }
}

Future<void> _deleteIfExists(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } catch (_) {}
}

Future<void> _deleteRegularFileIfExists(File file) async {
  final type = await FileSystemEntity.type(file.path, followLinks: false);
  if (type == FileSystemEntityType.notFound) return;
  if (type != FileSystemEntityType.file) {
    throw const FileTransferStorageException('unsafe_cleanup_target');
  }
  await file.delete();
}

String _downloadSecretKey(ReceiveTransferCheckpoint checkpoint) =>
    _downloadSecretKeyParts(checkpoint.bridgeKey, checkpoint.transferId);

String _downloadSecretKeyParts(String bridgeKey, String transferId) =>
    'file_transfer_v2:$bridgeKey:download:$transferId';

String _uploadSecretKey(UploadTransferCheckpoint checkpoint) =>
    'file_transfer_v2:${checkpoint.bridgeKey}:upload:${checkpoint.localId}';

String _safeId(String value) {
  if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(value)) {
    return sha256.convert(utf8.encode(value)).toString();
  }
  return value;
}

String _receivePartialFilename(String transferId) =>
    '.ccpocket-v2-${sha256.convert(utf8.encode(transferId)).toString().substring(0, 32)}.part';

void _requireCheckpointSchemaVersion(Map<String, dynamic> json, String kind) {
  final value = json['schemaVersion'];
  if (value is! int || value < 1 || value > 0x7fffffff) {
    throw FormatException('Invalid $kind checkpoint version');
  }
  if (value != fileTransferCheckpointVersion) {
    throw _UnsupportedFileTransferCheckpointVersion(
      'Unsupported $kind checkpoint version',
    );
  }
}

Future<bool> _oversizedCheckpointMayUseUnsupportedSchema(File file) async {
  RandomAccessFile? handle;
  try {
    handle = await file.open(mode: FileMode.read);
    final prefix = utf8.decode(
      await handle.read(min(fileTransferCheckpointMaxBytes, 4096)),
      allowMalformed: true,
    );
    final match = RegExp(
      r'^\s*\{\s*"schemaVersion"\s*:\s*(-?[0-9]+)',
    ).firstMatch(prefix);
    if (match == null) return true;
    final version = int.tryParse(match.group(1)!);
    if (version == fileTransferCheckpointVersion) return false;
    return version != null && version >= 1 && version <= 0x7fffffff;
  } catch (_) {
    // An unreadable or ambiguous oversized file is not proof that its private
    // assets are abandoned. Preserve it for a future compatible app version.
    return true;
  } finally {
    try {
      await handle?.close();
    } catch (_) {}
  }
}

String _requiredText(Map<String, dynamic> json, String key, int maxLength) {
  final value = json[key];
  if (value is! String ||
      value.trim().isEmpty ||
      value.length > maxLength ||
      value.contains('\u0000')) {
    throw FormatException('Invalid $key');
  }
  return value;
}

String? _optionalText(Map<String, dynamic> json, String key, int maxLength) {
  final value = json[key];
  if (value == null) return null;
  return _requiredText(json, key, maxLength);
}

String _requiredTransferId(Map<String, dynamic> json, String key) {
  final value = _requiredText(json, key, 128);
  if (!RegExp(r'^[A-Za-z0-9_-]{16,128}$').hasMatch(value)) {
    throw FormatException('Invalid $key');
  }
  return value;
}

String _requiredToken(Map<String, dynamic> json, String key) {
  final value = _requiredText(json, key, 43);
  if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value)) {
    throw FormatException('Invalid $key');
  }
  return value;
}

String? _optionalToken(Map<String, dynamic> json, String key) {
  if (json[key] == null) return null;
  return _requiredToken(json, key);
}

String _requiredEtag(Map<String, dynamic> json, String key) {
  final value = _requiredText(json, key, 34);
  if (!RegExp(r'^"[A-Za-z0-9_-]{32}"$').hasMatch(value)) {
    throw FormatException('Invalid $key');
  }
  return value;
}

String _safeLeaf(Map<String, dynamic> json, String key) {
  final value = _requiredText(json, key, 512);
  if (path.basename(value) != value || value == '.' || value == '..') {
    throw FormatException('Invalid $key');
  }
  return value;
}

int _boundedSize(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! int || value < 0 || value > maxFileTransferBytes) {
    throw FormatException('Invalid $key');
  }
  return value;
}

DateTime _requiredDate(Map<String, dynamic> json, String key) {
  final value = _requiredText(json, key, 128);
  final date = DateTime.tryParse(value);
  if (date == null) throw FormatException('Invalid $key');
  return date.toUtc();
}

bool _isDescendant(String root, String candidate) {
  final relative = path.relative(candidate, from: root);
  return relative != '.' &&
      relative != '..' &&
      !relative.startsWith('..${path.separator}') &&
      !path.isAbsolute(relative);
}
