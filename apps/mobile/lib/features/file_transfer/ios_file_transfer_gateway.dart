import 'package:flutter/services.dart';

import 'file_transfer_service.dart';

const iosFileTransferChannelName = 'ccpocket/file_transfer';

abstract interface class FileTransferPlatformGateway
    implements
        FileTransferDocumentPicker,
        FileTransferCapacityGateway,
        FileTransferCommitGateway {}

class IosFileTransferGateway implements FileTransferPlatformGateway {
  const IosFileTransferGateway([
    this._channel = const MethodChannel(iosFileTransferChannelName),
  ]);

  final MethodChannel _channel;

  @override
  Future<FileTransferSelection?> pickFile({required int maxSizeBytes}) async {
    final result = await _invokeMap('pickFile', <String, Object>{
      'maxSizeBytes': maxSizeBytes,
    });
    if (result == null) return null;
    final path = result['path'];
    final filename = result['filename'];
    final sizeBytes = result['sizeBytes'];
    if (path is! String ||
        filename is! String ||
        sizeBytes is! int ||
        path.isEmpty ||
        filename.isEmpty ||
        sizeBytes < 0 ||
        sizeBytes > maxSizeBytes) {
      throw const FileTransferException('invalid_picker_result');
    }
    return FileTransferSelection(
      path: path,
      filename: filename,
      sizeBytes: sizeBytes,
    );
  }

  @override
  Future<int?> availableCapacityBytes(String path) async {
    final value = await _invoke<int>('availableCapacity', <String, String>{
      'path': path,
    });
    return value == null || value < 0 ? null : value;
  }

  @override
  Future<void> markTransient(String path) =>
      _invoke<void>('markTransient', <String, String>{'path': path});

  @override
  Future<String> chooseFinalFilename({
    required String directoryPath,
    required String requestedFilename,
  }) async {
    final value = await _invoke<String>('chooseFinalFilename', {
      'directoryPath': directoryPath,
      'requestedFilename': requestedFilename,
    });
    if (value == null || value.isEmpty) {
      throw const FileTransferException('invalid_final_filename');
    }
    return value;
  }

  @override
  Future<FileTransferCommitProbeResult> probeCommit({
    required String partialPath,
    required String finalPath,
    String? expectedResourceIdentifier,
  }) async {
    final value = await _invokeMap('probeCommit', {
      'partialPath': partialPath,
      'finalPath': finalPath,
      'expectedResourceIdentifier': expectedResourceIdentifier,
    });
    final state = switch (value?['state']) {
      'ready' => FileTransferCommitProbe.ready,
      'linked' => FileTransferCommitProbe.linked,
      'complete' => FileTransferCommitProbe.complete,
      'collision' => FileTransferCommitProbe.collision,
      _ => throw const FileTransferException('invalid_commit_probe'),
    };
    final identifier = value?['resourceIdentifier'];
    if (identifier != null && identifier is! String) {
      throw const FileTransferException('invalid_commit_probe');
    }
    return FileTransferCommitProbeResult(
      state,
      resourceIdentifier: identifier as String?,
    );
  }

  @override
  Future<String> linkNoClobber({
    required String partialPath,
    required String finalPath,
  }) async {
    final value = await _invoke<String>('linkNoClobber', {
      'partialPath': partialPath,
      'finalPath': finalPath,
    });
    if (value == null || value.isEmpty) {
      throw const FileTransferException('invalid_commit_identifier');
    }
    return value;
  }

  @override
  Future<void> finalizeLinkedCommit({
    required String partialPath,
    required String finalPath,
    required String expectedResourceIdentifier,
  }) => _invoke<void>('finalizeLinkedCommit', {
    'partialPath': partialPath,
    'finalPath': finalPath,
    'expectedResourceIdentifier': expectedResourceIdentifier,
  });

  Future<T?> _invoke<T>(String method, Object? arguments) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (error) {
      throw FileTransferException(error.code, error.message);
    }
  }

  Future<Map<Object?, Object?>?> _invokeMap(
    String method,
    Object? arguments,
  ) async {
    try {
      return await _channel.invokeMapMethod<Object?, Object?>(
        method,
        arguments,
      );
    } on PlatformException catch (error) {
      throw FileTransferException(error.code, error.message);
    }
  }
}

class UnsupportedFileTransferGateway implements FileTransferPlatformGateway {
  const UnsupportedFileTransferGateway();

  @override
  Future<void> markTransient(String path) =>
      throw const FileTransferException('platform_unsupported');

  @override
  Future<FileTransferSelection?> pickFile({required int maxSizeBytes}) =>
      throw const FileTransferException('platform_unsupported');
  @override
  Future<int?> availableCapacityBytes(String path) async => null;
  @override
  Future<String> chooseFinalFilename({
    required String directoryPath,
    required String requestedFilename,
  }) => throw const FileTransferException('platform_unsupported');
  @override
  Future<FileTransferCommitProbeResult> probeCommit({
    required String partialPath,
    required String finalPath,
    String? expectedResourceIdentifier,
  }) => throw const FileTransferException('platform_unsupported');
  @override
  Future<String> linkNoClobber({
    required String partialPath,
    required String finalPath,
  }) => throw const FileTransferException('platform_unsupported');
  @override
  Future<void> finalizeLinkedCommit({
    required String partialPath,
    required String finalPath,
    required String expectedResourceIdentifier,
  }) => throw const FileTransferException('platform_unsupported');
}
