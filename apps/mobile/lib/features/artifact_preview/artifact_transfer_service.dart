import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;

const maxArtifactTransferBytes = 2 * 1024 * 1024 * 1024;
const _maxFilenameBytes = 240;

class ArtifactTransferException implements Exception {
  final String code;
  final int? statusCode;

  const ArtifactTransferException(this.code, {this.statusCode});

  @override
  String toString() => statusCode == null
      ? 'ArtifactTransferException($code)'
      : 'ArtifactTransferException($code, HTTP $statusCode)';
}

class ArtifactTransferCancellation {
  final _cancelled = Completer<void>();
  var _isCancelled = false;

  bool get isCancelled => _isCancelled;
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    _cancelled.complete();
  }
}

Future<int> streamArtifactToFile({
  required http.Client client,
  required Uri url,
  required File destination,
  required int expectedSizeBytes,
  ArtifactTransferCancellation? cancellation,
  Duration connectTimeout = const Duration(seconds: 30),
  Duration idleTimeout = const Duration(seconds: 30),
  Duration totalTimeout = const Duration(hours: 2),
  void Function(int receivedBytes, int totalBytes)? onProgress,
}) async {
  IOSink? sink;
  File? partialFile;
  Timer? totalTimer;
  var receivedBytes = 0;
  var totalTimedOut = false;
  var abortRequested = cancellation?.isCancelled ?? false;
  final requestAbort = Completer<void>();

  void abortRequest() {
    abortRequested = true;
    if (!requestAbort.isCompleted) requestAbort.complete();
  }

  void throwIfAborted() {
    if (!abortRequested && !(cancellation?.isCancelled ?? false)) return;
    throw ArtifactTransferException(
      totalTimedOut ? 'total_timeout' : 'cancelled',
    );
  }

  if (cancellation != null) {
    unawaited(cancellation.whenCancelled.then<void>((_) => abortRequest()));
  }

  try {
    if (expectedSizeBytes < 0 || expectedSizeBytes > maxArtifactTransferBytes) {
      throw const ArtifactTransferException('size_out_of_range');
    }
    if (await FileSystemEntity.type(destination.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const ArtifactTransferException('destination_not_reserved');
    }
    if (await destination.length() != 0) {
      throw const ArtifactTransferException('destination_not_reserved');
    }
    throwIfAborted();

    totalTimer = Timer(totalTimeout, () {
      totalTimedOut = true;
      abortRequest();
    });
    final request = http.AbortableRequest(
      'GET',
      url,
      abortTrigger: requestAbort.future,
    );
    final response = await client
        .send(request)
        .timeout(
          connectTimeout,
          onTimeout: () {
            abortRequest();
            throw const ArtifactTransferException('connect_timeout');
          },
        );
    if (response.statusCode != HttpStatus.ok) {
      throw ArtifactTransferException(
        'http_error',
        statusCode: response.statusCode,
      );
    }
    final declaredSize = response.contentLength;
    if (declaredSize != null && declaredSize != expectedSizeBytes) {
      throw const ArtifactTransferException('size_mismatch');
    }

    throwIfAborted();
    partialFile = await _createPartialFile(destination);
    sink = partialFile.openWrite(mode: FileMode.writeOnly);
    final boundedStream = response.stream.timeout(idleTimeout).map((chunk) {
      if (chunk.length > expectedSizeBytes - receivedBytes) {
        throw const ArtifactTransferException('size_mismatch');
      }
      receivedBytes += chunk.length;
      onProgress?.call(receivedBytes, expectedSizeBytes);
      return chunk;
    });
    await sink.addStream(boundedStream);
    await sink.flush();
    await sink.close();
    sink = null;

    if (receivedBytes != expectedSizeBytes) {
      throw const ArtifactTransferException('size_mismatch');
    }
    // Cancellation remains effective until this final commit point. Once the
    // atomic rename starts, the verified file is intentionally committed.
    throwIfAborted();
    await partialFile.rename(destination.path);
    partialFile = null;
    return receivedBytes;
  } catch (error) {
    if (sink != null) {
      try {
        await sink.close();
      } catch (_) {}
    }
    if (partialFile != null && await partialFile.exists()) {
      try {
        await partialFile.delete();
      } catch (_) {}
    }
    if (await destination.exists()) {
      try {
        if (await destination.length() == 0) await destination.delete();
      } catch (_) {}
    }
    if (error is http.RequestAbortedException) {
      throw ArtifactTransferException(
        totalTimedOut ? 'total_timeout' : 'cancelled',
      );
    }
    if (error is TimeoutException) {
      throw const ArtifactTransferException('idle_timeout');
    }
    rethrow;
  } finally {
    totalTimer?.cancel();
  }
}

Future<File> _createPartialFile(File destination) async {
  final timestamp = DateTime.now().microsecondsSinceEpoch;
  for (var suffix = 0; suffix < 100; suffix += 1) {
    final partial = File(
      path.join(
        destination.parent.path,
        '.ccpocket-$pid-$timestamp-$suffix.part',
      ),
    );
    try {
      return await partial.create(exclusive: true);
    } on FileSystemException {
      if (await FileSystemEntity.type(partial.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        continue;
      }
      rethrow;
    }
  }
  throw const ArtifactTransferException('partial_filename_exhausted');
}

String _truncateUtf8(String value, int maxBytes) {
  final output = StringBuffer();
  var usedBytes = 0;
  for (final rune in value.runes) {
    final character = String.fromCharCode(rune);
    final characterBytes = utf8.encode(character).length;
    if (usedBytes + characterBytes > maxBytes) break;
    output.write(character);
    usedBytes += characterBytes;
  }
  return output.toString();
}

String safeArtifactDownloadFilename(String value) {
  final cleaned = value
      .replaceAll(RegExp(r'[\u0000-\u001f\u007f/\\]'), '_')
      .trim();
  if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') return 'download';
  if (utf8.encode(cleaned).length <= _maxFilenameBytes) return cleaned;

  final candidateExtension = path.extension(cleaned);
  final extension = utf8.encode(candidateExtension).length <= 40
      ? candidateExtension
      : '';
  final stem = extension.isEmpty
      ? cleaned
      : cleaned.substring(0, cleaned.length - extension.length);
  final truncatedStem = _truncateUtf8(
    stem,
    _maxFilenameBytes - utf8.encode(extension).length,
  );
  final result = '$truncatedStem$extension';
  return result.isEmpty || result == '.' || result == '..'
      ? 'download'
      : result;
}

Future<File> reserveNextAvailableArtifactFile(
  Directory directory,
  String requestedFilename,
) async {
  await directory.create(recursive: true);
  final filename = safeArtifactDownloadFilename(requestedFilename);
  for (var suffix = 0; suffix < 10_000; suffix += 1) {
    final candidateName = _artifactFilenameWithSuffix(filename, suffix);
    final candidate = File(path.join(directory.path, candidateName));
    try {
      return await candidate.create(exclusive: true);
    } on FileSystemException {
      if (await FileSystemEntity.type(candidate.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        continue;
      }
      rethrow;
    }
  }
  throw const ArtifactTransferException('filename_exhausted');
}

String _artifactFilenameWithSuffix(String filename, int suffix) {
  if (suffix == 0) return filename;
  final suffixText = ' ($suffix)';
  var extension = path.extension(filename);
  var stem = path.basenameWithoutExtension(filename);
  if (stem.isEmpty) {
    stem = filename;
    extension = '';
  }
  final availableStemBytes =
      _maxFilenameBytes -
      utf8.encode(suffixText).length -
      utf8.encode(extension).length;
  return '${_truncateUtf8(stem, availableStemBytes)}$suffixText$extension';
}
