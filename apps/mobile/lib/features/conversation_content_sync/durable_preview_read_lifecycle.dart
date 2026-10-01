/// The owner of one page-local read, not a provider or cache revision.
final class DurablePreviewReadTicket {
  DurablePreviewReadTicket._({
    required this.targetFingerprint,
    required this.providerSessionId,
    required this.cacheCommitEpoch,
  });

  final String targetFingerprint;
  final String providerSessionId;
  final int cacheCommitEpoch;
}

/// Coalesces page cache reads and retires only the active read's owner.
///
/// The page supplies source/route currentness and the Service's cache epoch.
/// This class never reads SQLite, resolves identity, or owns rendered content.
class DurablePreviewReadLifecycle {
  DurablePreviewReadTicket? _active;
  bool _dirty = false;
  bool _disposed = false;

  bool get isLoading => _active != null;
  String? get loadingTargetFingerprint => _active?.targetFingerprint;

  /// Target changes must invalidate the previous read before starting here.
  /// Requests arriving during a read coalesce into its follow-up.
  DurablePreviewReadTicket? begin({
    required String targetFingerprint,
    required String providerSessionId,
    required int cacheCommitEpoch,
  }) {
    if (_disposed) return null;
    if (_active != null) {
      _dirty = true;
      return null;
    }
    _dirty = false;
    return _active = DurablePreviewReadTicket._(
      targetFingerprint: targetFingerprint,
      providerSessionId: providerSessionId,
      cacheCommitEpoch: cacheCommitEpoch,
    );
  }

  bool owns(DurablePreviewReadTicket ticket) =>
      !_disposed && identical(_active, ticket);

  /// Both successful results and errors use this acceptance contract.
  bool shouldAccept(
    DurablePreviewReadTicket ticket, {
    required bool targetIsCurrent,
    required int currentCacheCommitEpoch,
  }) {
    if (!owns(ticket)) return false;
    if (!targetIsCurrent ||
        currentCacheCommitEpoch != ticket.cacheCommitEpoch) {
      _dirty = true;
      return false;
    }
    return !_dirty;
  }

  void markDirty() {
    if (_active != null) _dirty = true;
  }

  /// Returns whether the owner needs one follow-up, then releases its loading
  /// state. An invalidated ticket cannot consume a newer owner's dirty state.
  bool finish(DurablePreviewReadTicket ticket) {
    if (!owns(ticket)) return false;
    _active = null;
    final reread = _dirty;
    _dirty = false;
    return reread;
  }

  void invalidate() {
    _active = null;
    _dirty = false;
  }

  void dispose() {
    _disposed = true;
    invalidate();
  }
}
