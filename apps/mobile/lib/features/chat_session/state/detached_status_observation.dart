import '../../../models/messages.dart';

/// The latest accepted status observation for one detached provider binding.
///
/// Owns observed time, business signature and local commit receipt together.
/// The caller qualifies source/runtime identity and receipts, grants authority,
/// and decides how queued overlays are applied or retired.
class DetachedStatusObservation {
  DateTime? _observedAt;
  String? _signature;
  ConversationSyncV2CommitReceipt? _commitReceipt;

  DateTime? get observedAt => _observedAt;
  ConversationSyncV2CommitReceipt? get commitReceipt => _commitReceipt;

  bool rejectsObservedAt(DateTime observedAt) {
    final previous = _observedAt;
    return previous != null && observedAt.isBefore(previous);
  }

  /// Receipts establish order only within the same source and subscription.
  /// The caller supplies a receipt already qualified for the current runtime.
  bool rejectsReceipt(ConversationSyncV2CommitReceipt? receipt) {
    final previous = _commitReceipt;
    return receipt != null &&
        previous != null &&
        receipt.sourceFingerprint == previous.sourceFingerprint &&
        receipt.subscriptionId == previous.subscriptionId &&
        receipt.sequence <= previous.sequence;
  }

  bool matches(ConversationSyncV2Status status, DateTime observedAt) =>
      _observedAt == observedAt && _signature == _signatureFor(status);

  void record({
    required ConversationSyncV2Status status,
    required DateTime observedAt,
    required ConversationSyncV2CommitReceipt? receipt,
  }) {
    _observedAt = observedAt;
    _signature = _signatureFor(status);
    _commitReceipt = receipt;
  }

  /// An identical cached status can clear order proof without changing facts.
  /// Restoring a withdrawn authority lease remains the caller's responsibility.
  void refreshReceipt(ConversationSyncV2CommitReceipt? receipt) {
    _commitReceipt = receipt;
  }

  void clear() {
    _observedAt = null;
    _signature = null;
    _commitReceipt = null;
  }

  static String _signatureFor(ConversationSyncV2Status status) => [
    status.activity,
    status.attention,
    status.result,
    status.runtimeAttachment,
    status.source,
    status.confidence,
    status.observedAt,
    status.attentionRequestId ?? '',
    status.executionHost ?? '',
    status.activeTurnId ?? '',
    status.controlState ?? '',
    status.authorityGeneration ?? '',
    status.runtimeSessionId ?? '',
  ].join('\u0000');
}
