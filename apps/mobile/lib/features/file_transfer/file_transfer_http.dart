import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../models/messages.dart';
import 'file_transfer_cancellation.dart';

const fileTransferTokenHeader = 'X-CCPocket-Transfer-Token';

class DownloadTransferHead {
  final int sizeBytes;
  final String etag;
  final int maxChunkSizeBytes;
  final DateTime expiresAt;

  const DownloadTransferHead({
    required this.sizeBytes,
    required this.etag,
    required this.maxChunkSizeBytes,
    required this.expiresAt,
  });
}

class UploadTransferHead {
  final int uploadOffset;
  final int sizeBytes;
  final int maxChunkSizeBytes;
  final DateTime expiresAt;
  final bool complete;
  final String? filename;

  const UploadTransferHead({
    required this.uploadOffset,
    required this.sizeBytes,
    required this.maxChunkSizeBytes,
    required this.expiresAt,
    required this.complete,
    required this.filename,
  });
}

class UploadChunkResult {
  final int uploadOffset;
  final bool complete;

  const UploadChunkResult({required this.uploadOffset, required this.complete});
}

class FileTransferHttpException implements Exception {
  final String code;
  final int? statusCode;
  final int? authoritativeOffset;

  const FileTransferHttpException(
    this.code, {
    this.statusCode,
    this.authoritativeOffset,
  });
}

class FileTransferHttpTransport {
  const FileTransferHttpTransport(this._client);

  final http.Client _client;

  Future<DownloadTransferHead> headDownload({
    required Uri url,
    required String token,
    required FileTransferCancellation cancellation,
    Duration totalTimeout = const Duration(seconds: 45),
  }) async {
    _requireToken(token);
    final pending = await _sendNoBody(
      method: 'HEAD',
      url: url,
      token: token,
      cancellation: cancellation,
      totalTimeout: totalTimeout,
    );
    var consumed = false;
    try {
      final response = pending.response;
      if (response.statusCode != HttpStatus.ok) {
        await _drainBounded(response.stream, totalTimeout);
        consumed = true;
        throw FileTransferHttpException(
          'download_head_http_error',
          statusCode: response.statusCode,
        );
      }
      await _drainBounded(response.stream, totalTimeout);
      consumed = true;
      if (response.headers['accept-ranges']?.toLowerCase() != 'bytes') {
        throw const FileTransferHttpException('download_range_unsupported');
      }
      return DownloadTransferHead(
        sizeBytes: _requiredBoundedInt(response.headers, 'content-length'),
        etag: _requiredHeader(response.headers, 'etag', 512),
        maxChunkSizeBytes: _requiredChunkLimit(
          response.headers,
          'x-ccpocket-max-chunk-bytes',
        ),
        expiresAt: _requiredDate(
          response.headers,
          'x-ccpocket-transfer-expires',
        ),
      );
    } finally {
      pending.close(abort: !consumed);
    }
  }

  Future<int> downloadChunk({
    required Uri url,
    required String token,
    required String etag,
    required File partial,
    required int offset,
    required int endInclusive,
    required int totalSizeBytes,
    required FileTransferCancellation cancellation,
    void Function(int persistedBytes)? onProgress,
    Duration idleTimeout = const Duration(seconds: 30),
    Duration totalTimeout = const Duration(minutes: 10),
  }) async {
    _requireToken(token);
    _requireEtag(etag);
    if (offset < 0 ||
        endInclusive < offset ||
        endInclusive >= totalSizeBytes ||
        endInclusive - offset + 1 > fileTransferChunkBytes) {
      throw const FileTransferHttpException('invalid_download_range');
    }
    if (await FileSystemEntity.type(partial.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await partial.length() != offset) {
      throw const FileTransferHttpException('partial_offset_mismatch');
    }

    final abort = Completer<void>();
    _bindCancellation(cancellation, abort);
    final request =
        http.AbortableRequest('GET', url, abortTrigger: abort.future)
          ..followRedirects = false
          ..maxRedirects = 0
          ..headers.addAll({
            fileTransferTokenHeader: token,
            HttpHeaders.rangeHeader: 'bytes=$offset-$endInclusive',
            'If-Range': etag,
          });
    final timer = _abortAfter(totalTimeout, abort);
    IOSink? sink;
    var committed = false;
    try {
      final response = await _client.send(request).timeout(totalTimeout);
      if (response.statusCode != HttpStatus.partialContent) {
        await _drainBounded(response.stream, idleTimeout);
        throw FileTransferHttpException(
          'download_range_http_error',
          statusCode: response.statusCode,
        );
      }
      final expectedLength = endInclusive - offset + 1;
      if (response.contentLength != expectedLength ||
          response.headers['etag'] != etag ||
          response.headers['content-range'] !=
              'bytes $offset-$endInclusive/$totalSizeBytes') {
        throw const FileTransferHttpException('download_range_mismatch');
      }
      var written = 0;
      sink = partial.openWrite(mode: FileMode.append);
      await for (final chunk in response.stream.timeout(idleTimeout)) {
        if (chunk.length > expectedLength - written) {
          throw const FileTransferHttpException('download_range_mismatch');
        }
        sink.add(chunk);
        written += chunk.length;
        onProgress?.call(offset + written);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (written != expectedLength ||
          await partial.length() != endInclusive + 1) {
        throw const FileTransferHttpException('download_range_mismatch');
      }
      committed = true;
      return endInclusive + 1;
    } on http.RequestAbortedException {
      throw FileTransferHttpException(
        cancellation.isCancelled ? 'paused' : 'total_timeout',
      );
    } on TimeoutException {
      if (!abort.isCompleted) abort.complete();
      throw const FileTransferHttpException('idle_timeout');
    } finally {
      timer.cancel();
      if (!committed && !abort.isCompleted) abort.complete();
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {}
      }
      if (!committed) {
        try {
          final handle = await partial.open(mode: FileMode.writeOnlyAppend);
          await handle.truncate(offset);
          await handle.flush();
          await handle.close();
        } catch (_) {}
      }
    }
  }

  Future<UploadTransferHead> headUpload({
    required Uri url,
    required String token,
    required FileTransferCancellation cancellation,
    Duration totalTimeout = const Duration(seconds: 45),
  }) async {
    _requireToken(token);
    final pending = await _sendNoBody(
      method: 'HEAD',
      url: url,
      token: token,
      cancellation: cancellation,
      totalTimeout: totalTimeout,
    );
    var consumed = false;
    try {
      final response = pending.response;
      if (response.statusCode != HttpStatus.ok) {
        await _drainBounded(response.stream, totalTimeout);
        consumed = true;
        throw FileTransferHttpException(
          'upload_head_http_error',
          statusCode: response.statusCode,
        );
      }
      await _drainBounded(response.stream, totalTimeout);
      consumed = true;
      final complete = _requiredHeader(response.headers, 'upload-complete', 1);
      if (complete != '0' && complete != '1') {
        throw const FileTransferHttpException('invalid_upload_complete');
      }
      final rawFilename = response.headers['upload-filename'];
      final filename = rawFilename == null
          ? null
          : _validatedUploadFilename(rawFilename);
      return UploadTransferHead(
        uploadOffset: _requiredBoundedInt(response.headers, 'upload-offset'),
        sizeBytes: _requiredBoundedInt(response.headers, 'upload-length'),
        maxChunkSizeBytes: _requiredChunkLimit(
          response.headers,
          'x-ccpocket-max-chunk-bytes',
        ),
        expiresAt: _requiredDate(response.headers, 'upload-expires'),
        complete: complete == '1',
        filename: filename,
      );
    } finally {
      pending.close(abort: !consumed);
    }
  }

  Future<UploadChunkResult> uploadChunk({
    required Uri url,
    required String token,
    required File stagedFile,
    required int offset,
    required int chunkLength,
    required int totalSizeBytes,
    required FileTransferCancellation cancellation,
    void Function(int sentBytes)? onProgress,
    Duration idleTimeout = const Duration(seconds: 30),
    Duration totalTimeout = const Duration(minutes: 10),
  }) async {
    _requireToken(token);
    if (offset < 0 ||
        chunkLength <= 0 ||
        chunkLength > fileTransferChunkBytes ||
        offset + chunkLength > totalSizeBytes ||
        await stagedFile.length() != totalSizeBytes) {
      throw const FileTransferHttpException('invalid_upload_range');
    }
    final abort = Completer<void>();
    _bindCancellation(cancellation, abort);
    final request =
        http.AbortableStreamedRequest('PATCH', url, abortTrigger: abort.future)
          ..followRedirects = false
          ..maxRedirects = 0
          ..headers.addAll({
            fileTransferTokenHeader: token,
            HttpHeaders.contentTypeHeader: 'application/offset+octet-stream',
            'Upload-Offset': offset.toString(),
          })
          ..contentLength = chunkLength;
    final timer = _abortAfter(totalTimeout, abort);
    final responseFuture = _client.send(request).timeout(totalTimeout);
    try {
      var sent = 0;
      final stream = stagedFile
          .openRead(offset, offset + chunkLength)
          .timeout(idleTimeout)
          .map((chunk) {
            if (chunk.length > chunkLength - sent) {
              throw const FileTransferHttpException('upload_range_mismatch');
            }
            sent += chunk.length;
            onProgress?.call(offset + sent);
            return chunk;
          });
      await request.sink.addStream(stream);
      await request.sink.close();
      if (sent != chunkLength) {
        throw const FileTransferHttpException('upload_range_mismatch');
      }
      final response = await responseFuture;
      if (response.statusCode != HttpStatus.noContent) {
        await _drainBounded(response.stream, idleTimeout);
        final authoritativeOffset = int.tryParse(
          response.headers['upload-offset'] ?? '',
        );
        throw FileTransferHttpException(
          'upload_patch_http_error',
          statusCode: response.statusCode,
          authoritativeOffset: authoritativeOffset,
        );
      }
      await response.stream.timeout(idleTimeout).drain<void>();
      final nextOffset = _requiredBoundedInt(response.headers, 'upload-offset');
      if (nextOffset != offset + chunkLength) {
        throw FileTransferHttpException(
          'upload_offset_mismatch',
          authoritativeOffset: nextOffset,
        );
      }
      final complete = _requiredHeader(response.headers, 'upload-complete', 1);
      if (complete != '0' && complete != '1') {
        throw const FileTransferHttpException('invalid_upload_complete');
      }
      return UploadChunkResult(
        uploadOffset: nextOffset,
        complete: complete == '1',
      );
    } on http.RequestAbortedException {
      throw FileTransferHttpException(
        cancellation.isCancelled ? 'paused' : 'total_timeout',
      );
    } on TimeoutException {
      if (!abort.isCompleted) abort.complete();
      throw const FileTransferHttpException('idle_timeout');
    } catch (_) {
      if (!abort.isCompleted) abort.complete();
      try {
        await responseFuture;
      } catch (_) {}
      rethrow;
    } finally {
      timer.cancel();
      try {
        await request.sink.close();
      } catch (_) {}
    }
  }

  Future<_PendingHttpResponse> _sendNoBody({
    required String method,
    required Uri url,
    required String token,
    required FileTransferCancellation cancellation,
    required Duration totalTimeout,
  }) async {
    final abort = Completer<void>();
    _bindCancellation(cancellation, abort);
    final request =
        http.AbortableRequest(method, url, abortTrigger: abort.future)
          ..followRedirects = false
          ..maxRedirects = 0
          ..headers[fileTransferTokenHeader] = token;
    final timer = _abortAfter(totalTimeout, abort);
    try {
      final response = await _client.send(request).timeout(totalTimeout);
      return _PendingHttpResponse(response, abort, timer);
    } on http.RequestAbortedException {
      timer.cancel();
      throw FileTransferHttpException(
        cancellation.isCancelled ? 'paused' : 'total_timeout',
      );
    } on TimeoutException {
      timer.cancel();
      if (!abort.isCompleted) abort.complete();
      throw const FileTransferHttpException('total_timeout');
    } catch (_) {
      timer.cancel();
      rethrow;
    }
  }
}

class _PendingHttpResponse {
  final http.StreamedResponse response;
  final Completer<void> _abort;
  final Timer _timer;

  const _PendingHttpResponse(this.response, this._abort, this._timer);

  void close({required bool abort}) {
    _timer.cancel();
    if (abort && !_abort.isCompleted) _abort.complete();
  }
}

Future<void> _drainBounded(
  Stream<List<int>> stream,
  Duration idleTimeout,
) async {
  var bytes = 0;
  await for (final chunk in stream.timeout(idleTimeout)) {
    bytes += chunk.length;
    if (bytes > 64 * 1024) {
      throw const FileTransferHttpException('response_too_large');
    }
  }
}

void _requireToken(String value) {
  if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value)) {
    throw const FileTransferHttpException('invalid_transfer_token');
  }
}

void _requireEtag(String value) {
  if (!RegExp(r'^"[A-Za-z0-9_-]{32}"$').hasMatch(value)) {
    throw const FileTransferHttpException('invalid_etag');
  }
}

String _validatedUploadFilename(String encoded) {
  if (encoded.length > 3072 || encoded.contains('\u0000')) {
    throw const FileTransferHttpException('invalid_upload_filename');
  }
  final value = Uri.decodeComponent(encoded);
  if (value.trim().isEmpty ||
      value.length > 1024 ||
      value.contains(RegExp(r'[\u0000-\u001f\u007f/\\]')) ||
      value == '.' ||
      value == '..') {
    throw const FileTransferHttpException('invalid_upload_filename');
  }
  return value;
}

void _bindCancellation(
  FileTransferCancellation cancellation,
  Completer<void> abort,
) {
  if (cancellation.isCancelled) {
    abort.complete();
    return;
  }
  unawaited(
    cancellation.whenCancelled.then<void>((_) {
      if (!abort.isCompleted) abort.complete();
    }),
  );
}

Timer _abortAfter(Duration timeout, Completer<void> abort) =>
    Timer(timeout, () {
      if (!abort.isCompleted) abort.complete();
    });

String _requiredHeader(
  Map<String, String> headers,
  String name,
  int maxLength,
) {
  final value = headers[name];
  if (value == null ||
      value.trim().isEmpty ||
      value.length > maxLength ||
      value.contains('\u0000')) {
    throw FileTransferHttpException('missing_or_invalid_$name');
  }
  return value;
}

int _requiredBoundedInt(Map<String, String> headers, String name) {
  final value = int.tryParse(headers[name] ?? '');
  if (value == null || value < 0 || value > maxFileTransferBytes) {
    throw FileTransferHttpException('missing_or_invalid_$name');
  }
  return value;
}

int _requiredChunkLimit(Map<String, String> headers, String name) {
  final value = int.tryParse(headers[name] ?? '');
  if (value == null || value <= 0 || value > fileTransferChunkBytes) {
    throw FileTransferHttpException('missing_or_invalid_$name');
  }
  return value;
}

DateTime _requiredDate(Map<String, String> headers, String name) {
  final value = DateTime.tryParse(headers[name] ?? '');
  if (value == null) {
    throw FileTransferHttpException('missing_or_invalid_$name');
  }
  return value.toUtc();
}
