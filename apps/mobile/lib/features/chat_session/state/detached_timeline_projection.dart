import '../../../models/messages.dart';

typedef DetachedTimelineEntryAliases =
    Iterable<String> Function(ChatEntry entry);
typedef DetachedTimelineEntryMerger =
    ChatEntry Function(ChatEntry overlay, ChatEntry canonical);

/// Result of composing a detached durable conversation for presentation.
///
/// The canonical list remains ordered exactly as committed by SQLite. Local
/// outgoing and current-runtime overlays may enrich or append to that list,
/// but they can never reorder canonical entries or add the same stable item
/// twice.
class DetachedTimelineProjectionResult {
  const DetachedTimelineProjectionResult({
    required this.entries,
    required this.canonicalCount,
    required this.outgoingOverlayCount,
    required this.runtimeOverlayCount,
    required this.duplicateCanonicalCount,
    required this.duplicateOverlayCount,
  });

  final List<ChatEntry> entries;
  final int canonicalCount;
  final int outgoingOverlayCount;
  final int runtimeOverlayCount;
  final int duplicateCanonicalCount;
  final int duplicateOverlayCount;
}

/// Prepared canonical input for one synchronous history application.
///
/// Admission and receipt evidence come from canonical input, before any
/// current-runtime or local outgoing overlay enriches the presentation.
class DetachedCanonicalHistoryCandidate {
  const DetachedCanonicalHistoryCandidate._(
    this._canonical,
    this._canonicalAliasIndexes,
    this._exactAliases,
    this._mergeEquivalent, {
    required this.canonicalEntries,
    required this.duplicateCanonicalCount,
    required this.acknowledgedClientMessageIds,
  });

  final List<ChatEntry> canonicalEntries;
  final List<ChatEntry> _canonical;
  final Map<String, int> _canonicalAliasIndexes;
  final DetachedTimelineEntryAliases _exactAliases;
  final DetachedTimelineEntryMerger _mergeEquivalent;
  final int duplicateCanonicalCount;
  final List<String> acknowledgedClientMessageIds;

  bool get isAccepted => duplicateCanonicalCount == 0;

  DetachedTimelineProjectionResult compose({
    required List<ChatEntry> outgoingOverlays,
    required List<ChatEntry> runtimeOverlays,
  }) => _projectDetachedTimelineOverlays(
    canonical: List<ChatEntry>.of(_canonical),
    canonicalAliasIndexes: Map<String, int>.of(_canonicalAliasIndexes),
    duplicateCanonicalCount: duplicateCanonicalCount,
    outgoingOverlays: outgoingOverlays,
    runtimeOverlays: runtimeOverlays,
    exactAliases: _exactAliases,
    mergeEquivalent: _mergeEquivalent,
  );
}

/// Pure, O(n) projection for detached conversation_sync_v2 timelines.
///
/// Expected inputs are already committed canonical rows plus bounded local
/// overlays. No timestamp, text similarity, or previous presentation order is
/// used to repair provider order.
DetachedTimelineProjectionResult projectDetachedTimeline({
  required List<ChatEntry> canonicalEntries,
  required List<ChatEntry> outgoingOverlays,
  required List<ChatEntry> runtimeOverlays,
  required DetachedTimelineEntryAliases exactAliases,
  required DetachedTimelineEntryMerger mergeEquivalent,
}) => prepareDetachedCanonicalHistory(
  canonicalEntries: canonicalEntries,
  exactAliases: exactAliases,
  mergeEquivalent: mergeEquivalent,
).compose(outgoingOverlays: outgoingOverlays, runtimeOverlays: runtimeOverlays);

/// Runs the original canonical identity pass without applying any overlays.
DetachedCanonicalHistoryCandidate prepareDetachedCanonicalHistory({
  required List<ChatEntry> canonicalEntries,
  required DetachedTimelineEntryAliases exactAliases,
  required DetachedTimelineEntryMerger mergeEquivalent,
}) {
  final originalCanonical = List<ChatEntry>.unmodifiable(canonicalEntries);
  final canonical = <ChatEntry>[];
  final canonicalAliasIndexes = <String, int>{};
  var duplicateCanonicalCount = 0;

  for (final entry in originalCanonical) {
    final aliases = exactAliases(entry).toSet();
    int? existingIndex;
    for (final alias in aliases) {
      existingIndex = canonicalAliasIndexes[alias];
      if (existingIndex != null) break;
    }
    if (existingIndex != null) {
      duplicateCanonicalCount += 1;
      canonical[existingIndex] = mergeEquivalent(
        canonical[existingIndex],
        entry,
      );
      for (final alias in exactAliases(canonical[existingIndex])) {
        canonicalAliasIndexes[alias] = existingIndex;
      }
      continue;
    }
    final index = canonical.length;
    canonical.add(entry);
    for (final alias in aliases) {
      canonicalAliasIndexes[alias] = index;
    }
  }

  return DetachedCanonicalHistoryCandidate._(
    List<ChatEntry>.unmodifiable(canonical),
    Map<String, int>.unmodifiable(canonicalAliasIndexes),
    exactAliases,
    mergeEquivalent,
    canonicalEntries: originalCanonical,
    duplicateCanonicalCount: duplicateCanonicalCount,
    acknowledgedClientMessageIds: duplicateCanonicalCount > 0
        ? const []
        : List<String>.unmodifiable([
            for (final entry in originalCanonical.whereType<UserChatEntry>())
              if (entry.clientMessageId?.trim().isNotEmpty == true)
                entry.clientMessageId!,
          ]),
  );
}

DetachedTimelineProjectionResult _projectDetachedTimelineOverlays({
  required List<ChatEntry> canonical,
  required Map<String, int> canonicalAliasIndexes,
  required int duplicateCanonicalCount,
  required List<ChatEntry> outgoingOverlays,
  required List<ChatEntry> runtimeOverlays,
  required DetachedTimelineEntryAliases exactAliases,
  required DetachedTimelineEntryMerger mergeEquivalent,
}) {
  final appended = <ChatEntry>[];
  final appendedAliases = <String>{};
  final seenOverlayAliases = <String>{};
  var outgoingOverlayCount = 0;
  var runtimeOverlayCount = 0;
  var duplicateOverlayCount = 0;

  void applyOverlay(ChatEntry overlay, {required bool outgoing}) {
    final aliases = exactAliases(overlay).toSet();
    if (aliases.isNotEmpty && aliases.any(seenOverlayAliases.contains)) {
      duplicateOverlayCount += 1;
    }
    seenOverlayAliases.addAll(aliases);
    int? canonicalIndex;
    for (final alias in aliases) {
      canonicalIndex = canonicalAliasIndexes[alias];
      if (canonicalIndex != null) break;
    }
    if (canonicalIndex != null) {
      canonical[canonicalIndex] = mergeEquivalent(
        overlay,
        canonical[canonicalIndex],
      );
      for (final alias in exactAliases(canonical[canonicalIndex])) {
        canonicalAliasIndexes[alias] = canonicalIndex;
      }
      return;
    }
    if (aliases.isNotEmpty && aliases.any(appendedAliases.contains)) {
      duplicateOverlayCount += 1;
      return;
    }
    appended.add(overlay);
    appendedAliases.addAll(aliases);
    if (outgoing) {
      outgoingOverlayCount += 1;
    } else {
      runtimeOverlayCount += 1;
    }
  }

  for (final overlay in outgoingOverlays) {
    applyOverlay(overlay, outgoing: true);
  }
  for (final overlay in runtimeOverlays) {
    applyOverlay(overlay, outgoing: false);
  }

  return DetachedTimelineProjectionResult(
    entries: List<ChatEntry>.unmodifiable([...canonical, ...appended]),
    canonicalCount: canonical.length,
    outgoingOverlayCount: outgoingOverlayCount,
    runtimeOverlayCount: runtimeOverlayCount,
    duplicateCanonicalCount: duplicateCanonicalCount,
    duplicateOverlayCount: duplicateOverlayCount,
  );
}
