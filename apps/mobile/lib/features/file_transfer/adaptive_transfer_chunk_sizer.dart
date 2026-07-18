import 'dart:math';

import '../../models/messages.dart';

const adaptiveTransferInitialChunkBytes = 4 * 1024 * 1024;
const adaptiveTransferMinimumChunkBytes = 1024 * 1024;

/// In-memory transfer tuning shared by upload and download.
///
/// Offsets remain authoritative and persisted elsewhere. This object is
/// deliberately disposable: restarting it can change performance, never
/// correctness or resumability.
class AdaptiveTransferChunkSizer {
  AdaptiveTransferChunkSizer()
    : _targetBytes = adaptiveTransferInitialChunkBytes;

  int _targetBytes;
  double? _throughputBytesPerSecond;
  int _successStreak = 0;

  int nextChunkBytes({
    required int totalBytes,
    required int remainingBytes,
    required int serverMaxBytes,
  }) {
    if (totalBytes <= 0 ||
        remainingBytes <= 0 ||
        remainingBytes > totalBytes ||
        serverMaxBytes <= 0 ||
        serverMaxBytes > fileTransferChunkBytes) {
      throw ArgumentError('invalid adaptive chunk bounds');
    }
    // A final transfer of up to the negotiated server maximum is one exact
    // range. It never allocates or pads to that maximum.
    if (totalBytes <= serverMaxBytes) return remainingBytes;
    final boundedTarget = _targetBytes
        .clamp(
          min(adaptiveTransferMinimumChunkBytes, serverMaxBytes),
          serverMaxBytes,
        )
        .toInt();
    return min(remainingBytes, boundedTarget);
  }

  void recordSuccess({required int bytes, required Duration elapsed}) {
    if (bytes <= 0 || elapsed <= Duration.zero) return;
    final sample = bytes * 1000000 / elapsed.inMicroseconds;
    _throughputBytesPerSecond = _throughputBytesPerSecond == null
        ? sample
        : (_throughputBytesPerSecond! * 0.65) + (sample * 0.35);
    _successStreak++;

    final desired = (_throughputBytesPerSecond! * 3).round();
    if (_successStreak >= 2) {
      final boundedGrowth = min(desired, _targetBytes * 2);
      _targetBytes = _roundedChunk(
        boundedGrowth.clamp(
          adaptiveTransferMinimumChunkBytes,
          fileTransferChunkBytes,
        ),
      );
    } else if (elapsed > const Duration(seconds: 4)) {
      _targetBytes = _roundedChunk(
        desired.clamp(adaptiveTransferMinimumChunkBytes, _targetBytes),
      );
    }
  }

  void recordFailure() {
    _targetBytes = max(
      adaptiveTransferMinimumChunkBytes,
      _roundedChunk(_targetBytes ~/ 2),
    );
    _successStreak = 0;
  }
}

int _roundedChunk(int value) {
  final quantum = value <= 4 * 1024 * 1024 ? 256 * 1024 : 1024 * 1024;
  return max(quantum, (value ~/ quantum) * quantum);
}
