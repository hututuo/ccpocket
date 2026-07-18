import 'dart:async';

/// Transfer-local cancellation primitive.
///
/// It intentionally lives inside the optional file-transfer module so the
/// module has no compile-time dependency on artifact preview or other features.
class FileTransferCancellation {
  final Completer<void> _cancelled = Completer<void>();
  bool _isCancelled = false;

  bool get isCancelled => _isCancelled;
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    _cancelled.complete();
  }
}
