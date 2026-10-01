class ConversationTurnsPageLoadResult {
  const ConversationTurnsPageLoadResult({
    required this.loaded,
    required this.hasMore,
    this.latestTurnComplete,
    this.repairObservation,
  });

  final bool loaded;
  final bool hasMore;

  /// Repair coverage is independent of accepting a readable summary page.
  final bool? latestTurnComplete;

  /// Local content/coverage identity, never a Provider or wire revision.
  final String? repairObservation;
}
