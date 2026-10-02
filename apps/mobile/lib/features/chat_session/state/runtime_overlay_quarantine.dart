import '../../../models/messages.dart';

typedef RuntimeOverlayQuarantineEntry = ({
  String overlayId,
  ConversationSyncV2EventMessage event,
  int bytes,
});

enum RuntimeOverlayQuarantineAdmission { accepted, duplicate, capacityRejected }

/// Pending presentation events whose envelope passed admission but whose
/// authority/turn still awaits the separate status observer.
///
/// Owns FIFO storage and its byte accounting together. The caller computes
/// message bytes and decides identity, authority, staleness and application;
/// this queue neither evicts existing events nor grants any authority.
class RuntimeOverlayQuarantine {
  RuntimeOverlayQuarantine({required this.maxEntries, required this.maxBytes})
    : assert(maxEntries > 0),
      assert(maxBytes > 0);

  final int maxEntries;
  final int maxBytes;
  final Map<String, RuntimeOverlayQuarantineEntry> _pending = {};
  int _bytes = 0;

  int get length => _pending.length;
  int get bytes => _bytes;
  bool get isEmpty => _pending.isEmpty;
  bool contains(String overlayId) => _pending.containsKey(overlayId);

  /// A fixed iteration window: remove-before-apply can safely change storage
  /// while the caller processes the already observed pending events.
  List<RuntimeOverlayQuarantineEntry> get snapshot =>
      List.unmodifiable(_pending.values);

  RuntimeOverlayQuarantineAdmission add({
    required String overlayId,
    required ConversationSyncV2EventMessage event,
    required int bytes,
  }) {
    assert(bytes >= 0);
    if (_pending.containsKey(overlayId)) {
      return RuntimeOverlayQuarantineAdmission.duplicate;
    }
    if (bytes > maxBytes ||
        _pending.length >= maxEntries ||
        _bytes + bytes > maxBytes) {
      return RuntimeOverlayQuarantineAdmission.capacityRejected;
    }
    _pending[overlayId] = (overlayId: overlayId, event: event, bytes: bytes);
    _bytes += bytes;
    return RuntimeOverlayQuarantineAdmission.accepted;
  }

  void remove(String overlayId) {
    final removed = _pending.remove(overlayId);
    if (removed == null) return;
    final nextBytes = _bytes - removed.bytes;
    _bytes = nextBytes < 0 ? 0 : nextBytes;
  }

  void clear() {
    _pending.clear();
    _bytes = 0;
  }
}
