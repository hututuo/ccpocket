import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

const artifactQuickLookChannelName = 'ccpocket/artifact_quick_look';
const artifactQuickLookAutomaticMaxBytes = 64 * 1024 * 1024;

const _officeExtensions = <String>{
  '.doc',
  '.docx',
  '.xls',
  '.xlsx',
  '.ppt',
  '.pptx',
  '.rtf',
};

const _officeMimeTypes = <String>{
  'application/msword',
  'application/rtf',
  'application/vnd.ms-excel',
  'application/vnd.ms-powerpoint',
  'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/x-rtf',
  'text/rtf',
};

bool isOfficeArtifactForQuickLook(String filename, String mimeType) {
  if (_officeExtensions.contains(path.extension(filename).toLowerCase())) {
    return true;
  }
  final mediaType = mimeType.split(';').first.trim().toLowerCase();
  return _officeMimeTypes.contains(mediaType);
}

bool isHtmlArtifact(String filename, String mimeType) {
  final extension = path.extension(filename).toLowerCase();
  final mediaType = mimeType.split(';').first.trim().toLowerCase();
  return extension == '.html' ||
      extension == '.htm' ||
      mediaType == 'text/html';
}

/// Quick Look remains the first choice for bounded local files, while HTML is
/// deliberately kept in the app's isolated WebView sandbox.
bool shouldTryQuickLookForArtifact(
  String filename,
  String mimeType,
  int sizeBytes,
) {
  if (sizeBytes < 0 || sizeBytes > artifactQuickLookAutomaticMaxBytes) {
    return false;
  }
  return !isHtmlArtifact(filename, mimeType);
}

class ArtifactQuickLookUnsupportedException implements Exception {
  const ArtifactQuickLookUnsupportedException([this.code = 'unsupported']);

  final String code;

  @override
  String toString() => 'ArtifactQuickLookUnsupportedException($code)';
}

abstract interface class ArtifactQuickLookGateway {
  Future<void> previewFile({required String path, required String title});
}

class MethodChannelArtifactQuickLookGateway
    implements ArtifactQuickLookGateway {
  const MethodChannelArtifactQuickLookGateway([
    this._channel = const MethodChannel(artifactQuickLookChannelName),
  ]);

  final MethodChannel _channel;

  @override
  Future<void> previewFile({
    required String path,
    required String title,
  }) async {
    try {
      await _channel.invokeMethod<void>('previewFile', <String, String>{
        'path': path,
        'title': title,
      });
    } on MissingPluginException {
      throw const ArtifactQuickLookUnsupportedException('plugin_missing');
    } on PlatformException catch (error) {
      if (error.code == 'unsupported') {
        throw const ArtifactQuickLookUnsupportedException();
      }
      rethrow;
    }
  }
}

abstract interface class ArtifactQuickLookPreviewer {
  Future<void> previewTemporaryArtifact({
    required Future<File> Function() prepareFile,
    required String title,
    required bool Function() isCancelled,
  });
}

class ArtifactQuickLookService implements ArtifactQuickLookPreviewer {
  const ArtifactQuickLookService({ArtifactQuickLookGateway? gateway})
    : _gateway = gateway ?? const MethodChannelArtifactQuickLookGateway();

  final ArtifactQuickLookGateway _gateway;

  @override
  Future<void> previewTemporaryArtifact({
    required Future<File> Function() prepareFile,
    required String title,
    required bool Function() isCancelled,
  }) async {
    File? temporaryFile;
    try {
      temporaryFile = await prepareFile();
      if (isCancelled()) return;
      await _gateway.previewFile(path: temporaryFile.path, title: title);
    } finally {
      if (temporaryFile != null) await _deleteTemporaryFile(temporaryFile);
    }
  }

  Future<void> _deleteTemporaryFile(File file) async {
    for (var attempt = 0; attempt < 2; attempt += 1) {
      try {
        if (!await file.exists()) return;
        await file.delete();
        return;
      } catch (_) {
        // Quick Look can briefly retain the file while its controller is
        // dismissing. Give that handle one short chance to drain.
        if (attempt == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    }
  }
}
