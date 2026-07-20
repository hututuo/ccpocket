import 'dart:async';

import 'package:flutter/services.dart';

import 'file_transfer_service.dart';

const iosFileTransferChannelName = 'ccpocket/file_transfer';
const minimumIosFileTransferMajorVersion = 15;
const fileTransferNativeApiVersion = 1;
const receivedFileExportNativeApiVersion = 2;
const fileTransferSupportProbeTimeout = Duration(seconds: 2);

class FileTransferPlatformSupport {
  const FileTransferPlatformSupport({
    required this.supported,
    required this.reason,
    this.iosMajor,
    this.iosMinor,
    this.iosPatch,
    this.nativeApiVersion,
    this.appVersion,
    this.buildNumber,
  });

  final bool supported;
  final String reason;
  final int? iosMajor;
  final int? iosMinor;
  final int? iosPatch;
  final int? nativeApiVersion;
  final String? appVersion;
  final String? buildNumber;
}

abstract interface class FileTransferPlatformGateway
    implements
        FileTransferDocumentPicker,
        FileTransferCapacityGateway,
        FileTransferCommitGateway {
  Future<FileTransferPlatformSupport> probeSupport();
}

class IosFileTransferGateway implements FileTransferPlatformGateway {
  const IosFileTransferGateway([
    this._channel = const MethodChannel(iosFileTransferChannelName),
  ]);

  final MethodChannel _channel;

  @override
  Future<FileTransferPlatformSupport> probeSupport() async {
    try {
      final value = await _channel
          .invokeMapMethod<Object?, Object?>('getSupportInfo')
          .timeout(fileTransferSupportProbeTimeout);
      if (value == null) {
        return const FileTransferPlatformSupport(
          supported: false,
          reason: 'invalid_support_response',
        );
      }
      final nativeSupported = value['supported'];
      final iosMajor = value['iosMajor'];
      final iosMinor = value['iosMinor'];
      final iosPatch = value['iosPatch'];
      final nativeApi = value['nativeApiVersion'];
      final appVersion = value['appVersion'];
      final buildNumber = value['buildNumber'];
      if (nativeSupported is! bool ||
          iosMajor is! int ||
          iosMinor is! int ||
          iosPatch is! int ||
          nativeApi is! int ||
          (appVersion != null && appVersion is! String) ||
          (buildNumber != null && buildNumber is! String)) {
        return const FileTransferPlatformSupport(
          supported: false,
          reason: 'invalid_support_response',
        );
      }
      final reason =
          !nativeSupported || iosMajor < minimumIosFileTransferMajorVersion
          ? 'ios_version_unsupported'
          : nativeApi < fileTransferNativeApiVersion
          ? 'native_api_unsupported'
          : 'supported';
      return FileTransferPlatformSupport(
        supported: reason == 'supported',
        reason: reason,
        iosMajor: iosMajor,
        iosMinor: iosMinor,
        iosPatch: iosPatch,
        nativeApiVersion: nativeApi,
        appVersion: appVersion as String?,
        buildNumber: buildNumber as String?,
      );
    } on MissingPluginException {
      return const FileTransferPlatformSupport(
        supported: false,
        reason: 'native_plugin_missing',
      );
    } on PlatformException catch (error) {
      return FileTransferPlatformSupport(
        supported: false,
        reason: 'platform_error:${error.code}',
      );
    } on TimeoutException {
      return const FileTransferPlatformSupport(
        supported: false,
        reason: 'support_probe_timeout',
      );
    }
  }

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
    } on MissingPluginException {
      throw const FileTransferException('native_plugin_unavailable');
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
    } on MissingPluginException {
      throw const FileTransferException('native_plugin_unavailable');
    }
  }
}

class UnsupportedFileTransferGateway implements FileTransferPlatformGateway {
  const UnsupportedFileTransferGateway();

  @override
  Future<FileTransferPlatformSupport> probeSupport() async =>
      const FileTransferPlatformSupport(
        supported: false,
        reason: 'platform_unsupported',
      );

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
