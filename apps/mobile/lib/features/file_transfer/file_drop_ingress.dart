import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:path/path.dart' as path;
import 'package:super_clipboard/super_clipboard.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

const maxInlineDroppedImageBytes = 20 * 1024 * 1024;
const maxDroppedFileItems = 64;
const genericDroppedFileFormat = SimpleFileFormat(
  uniformTypeIdentifiers: ['public.item', 'public.data'],
  mimeTypes: ['application/octet-stream'],
);
const droppedFileFormats = <DataFormat>[
  ...Formats.standardFormats,
  genericDroppedFileFormat,
];

class DroppedFilePayload {
  const DroppedFilePayload({
    required this.filename,
    required this.bytes,
    required this.sizeBytes,
    required this.isPng,
    required this.isJpeg,
  });

  final String filename;
  final Stream<Uint8List> bytes;
  final int? sizeBytes;
  final bool isPng;
  final bool isJpeg;
}

bool dropSessionContainsFile(DropSession session) => session.items.any(
  (item) =>
      item.canProvide(Formats.fileUri) ||
      droppedFileFormats
          .whereType<FileFormat>()
          .any(item.canProvide) ||
      item.platformFormats.isNotEmpty,
);

bool canInlineDroppedImage(DroppedFilePayload payload) {
  final size = payload.sizeBytes;
  return (payload.isPng || payload.isJpeg) &&
      size != null &&
      size <= maxInlineDroppedImageBytes;
}

String safeDroppedFilename(
  String? candidate, {
  required bool isPng,
  required bool isJpeg,
  int fallbackIndex = 1,
}) {
  var value = candidate?.replaceAll('\\', '/').trim() ?? '';
  value = path
      .basename(value)
      .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '')
      .trim();
  if (value.isEmpty || value == '.' || value == '..') {
    final extension = isPng ? 'png' : (isJpeg ? 'jpg' : 'bin');
    value = 'dropped-file-$fallbackIndex.$extension';
  }
  if (utf8.encode(value).length <= 255) return value;

  final extension = path.extension(value);
  final suffix = utf8.encode(extension).length <= 32 ? extension : '';
  final stemBytes = 255 - utf8.encode(suffix).length;
  final stem = path.basenameWithoutExtension(value);
  return '${_truncateUtf8(stem, stemBytes)}$suffix';
}

String _truncateUtf8(String value, int maxBytes) {
  final buffer = StringBuffer();
  var used = 0;
  for (final rune in value.runes) {
    final scalar = String.fromCharCode(rune);
    final size = utf8.encode(scalar).length;
    if (used + size > maxBytes) break;
    buffer.write(scalar);
    used += size;
  }
  return buffer.toString();
}

Future<void> consumeDroppedFiles(
  PerformDropEvent event,
  Future<void> Function(DroppedFilePayload payload) onFile,
) async {
  var fallbackIndex = 0;
  for (final item in event.session.items.take(maxDroppedFileItems)) {
    final reader = item.dataReader;
    if (reader == null) continue;
    fallbackIndex += 1;
    // Serialize staging so several large drops cannot all reserve the same
    // free space before any one of them has started writing.
    await _consumeDroppedFile(reader, fallbackIndex, onFile);
  }
}

Future<void> _consumeDroppedFile(
  DataReader reader,
  int fallbackIndex,
  Future<void> Function(DroppedFilePayload payload) onFile,
) async {
  final completion = Completer<void>();
  final providesPng = reader.canProvide(Formats.png);
  final providesJpeg = !providesPng && reader.canProvide(Formats.jpeg);
  final progress = reader.getFile(
    null,
    (file) async {
      // The package requires the stream to be obtained synchronously inside
      // this callback. It remains streaming, so a 15 GiB drop is never loaded
      // into Dart memory as one object.
      final stream = file.getStream();
      String? suggestedName = file.fileName;
      if (suggestedName == null || suggestedName.trim().isEmpty) {
        try {
          suggestedName = await reader.getSuggestedName();
        } catch (_) {
          suggestedName = null;
        }
      }
      try {
        final safeName = safeDroppedFilename(
          suggestedName,
          isPng: providesPng,
          isJpeg: providesJpeg,
          fallbackIndex: fallbackIndex,
        );
        final extension = path.extension(safeName).toLowerCase();
        final hasKnownExtension = extension.isNotEmpty;
        final isPng = extension == '.png' || !hasKnownExtension && providesPng;
        final isJpeg =
            extension == '.jpg' ||
            extension == '.jpeg' ||
            !hasKnownExtension && providesJpeg;
        await onFile(
          DroppedFilePayload(
            filename: safeName,
            bytes: stream,
            sizeBytes: file.fileSize,
            isPng: isPng,
            isJpeg: isJpeg,
          ),
        );
        if (!completion.isCompleted) completion.complete();
      } catch (error, stackTrace) {
        if (!completion.isCompleted) {
          completion.completeError(error, stackTrace);
        }
      }
    },
    onError: (error) {
      if (!completion.isCompleted) completion.completeError(error);
    },
  );
  if (progress == null && !completion.isCompleted) completion.complete();
  await completion.future;
}
