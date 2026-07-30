import '../models/messages.dart';
import '../utils/history_window_policy.dart';

class ExplorerHistorySnapshot {
  const ExplorerHistorySnapshot({
    this.currentPath = '',
    this.recentPeekedFiles = const [],
  });

  final String currentPath;
  final List<String> recentPeekedFiles;
}

class SessionRuntimeSnapshot {
  const SessionRuntimeSnapshot({
    required this.sessionId,
    this.messages = const [],
    this.historySeq = 0,
    this.cachedHistorySeq = 0,
    this.contentEpoch = 0,
    this.explorerHistory = const ExplorerHistorySnapshot(),
  });

  final String sessionId;
  final List<ServerMessage> messages;

  /// Highest history sequence observed from the bridge.
  final int historySeq;

  /// Highest contiguous history sequence represented by [messages].
  ///
  /// This can lag behind [historySeq] when live messages arrive with a gap
  /// (for example an input_ack advances acceptedSeq before the corresponding
  /// user_input is cached).
  final int cachedHistorySeq;

  /// Process-local monotonic marker for canonical runtime-cache mutations.
  /// Unlike [historySeq], this never moves backwards when a full history
  /// snapshot resets provider sequence semantics.
  final int contentEpoch;
  final ExplorerHistorySnapshot explorerHistory;
}

class SessionRuntimeState {
  SessionRuntimeState({required this.sessionId});

  final String sessionId;
  final List<ServerMessage> _messages = [];
  final List<int?> _messageSeqs = [];
  int historySeq = 0;
  int cachedHistorySeq = 0;
  int contentEpoch = 0;
  ExplorerHistorySnapshot explorerHistory = const ExplorerHistorySnapshot();

  List<ServerMessage> get messages => List.unmodifiable(_messages);
}

class SessionRuntimeStore {
  SessionRuntimeStore({
    this.maxMessagesPerSession = turnAwareHistoryMaxRetainedEntries,
  });

  final int maxMessagesPerSession;
  final Map<String, SessionRuntimeState> _sessions = {};
  int _contentEpochCounter = 0;

  SessionRuntimeSnapshot snapshot(String sessionId) {
    final state = _sessions[sessionId];
    if (state == null) {
      return SessionRuntimeSnapshot(sessionId: sessionId);
    }
    return SessionRuntimeSnapshot(
      sessionId: sessionId,
      messages: state.messages,
      historySeq: state.historySeq,
      cachedHistorySeq: state.cachedHistorySeq,
      contentEpoch: state.contentEpoch,
      explorerHistory: state.explorerHistory,
    );
  }

  List<ServerMessage> messages(String sessionId) =>
      snapshot(sessionId).messages;

  int latestHistorySeq(String sessionId) => snapshot(sessionId).historySeq;

  int cachedHistorySeq(String sessionId) =>
      snapshot(sessionId).cachedHistorySeq;

  bool applyServerMessage(
    String sessionId,
    ServerMessage message, {
    int? historySeq,
  }) {
    final state = _stateFor(sessionId);
    if (_shouldIgnore(message)) {
      _recordLatestSeq(state, historySeq);
      return false;
    }
    state.contentEpoch = ++_contentEpochCounter;
    if (message is HistoryMessage) {
      state._messages
        ..clear()
        ..addAll(message.messages.where((m) => !_shouldIgnore(m)));
      state._messageSeqs
        ..clear()
        ..addAll(List<int?>.filled(state._messages.length, null));
      state.historySeq = 0;
      state.cachedHistorySeq = 0;
      return _trim(state);
    }
    if (message is HistorySnapshotMessage) {
      state._messages
        ..clear()
        ..addAll(
          message.entries
              .map((entry) => entry.message)
              .where((m) => !_shouldIgnore(m)),
        );
      state._messageSeqs
        ..clear()
        ..addAll(
          message.entries
              .where((entry) => !_shouldIgnore(entry.message))
              .map((entry) => entry.seq),
        );
      state.historySeq = message.toSeq;
      state.cachedHistorySeq = message.toSeq;
      return _trim(state);
    }
    if (message is HistoryDeltaMessage) {
      final previousCachedSeq = state.cachedHistorySeq;
      if (state.cachedHistorySeq == 0 &&
          state._messages.isNotEmpty &&
          message.fromSeq <= 1) {
        _clearMessages(state);
      }
      _mergeHistoryEntries(state, message.entries);
      _recordLatestSeq(state, message.toSeq);
      if (_deltaExtendsCachedHistory(previousCachedSeq, message)) {
        state.cachedHistorySeq = message.toSeq;
        _advanceCachedHistorySeq(state);
      }
      return _trim(state);
    }

    final messageSeq = _representsHistoryEntry(message) ? historySeq : null;
    _upsertMessage(state, message, messageSeq);
    _recordLatestSeq(state, historySeq);
    if (messageSeq != null && messageSeq <= state.cachedHistorySeq + 1) {
      if (messageSeq > state.cachedHistorySeq) {
        state.cachedHistorySeq = messageSeq;
      }
      _advanceCachedHistorySeq(state);
    }
    return _trim(state);
  }

  ExplorerHistorySnapshot getExplorerHistory(String sessionId) =>
      snapshot(sessionId).explorerHistory;

  void setExplorerHistory(
    String sessionId, {
    required String currentPath,
    required List<String> recentPeekedFiles,
  }) {
    final normalizedPath = currentPath.trim();
    final normalizedFiles = recentPeekedFiles
        .map((file) => file.trim())
        .where((file) => file.isNotEmpty)
        .take(10)
        .toList();
    if (normalizedPath.isEmpty && normalizedFiles.isEmpty) {
      final state = _sessions[sessionId];
      if (state == null) return;
      state.explorerHistory = const ExplorerHistorySnapshot();
      _removeIfEmpty(state);
      return;
    }
    _stateFor(sessionId).explorerHistory = ExplorerHistorySnapshot(
      currentPath: normalizedPath,
      recentPeekedFiles: normalizedFiles,
    );
  }

  void migrateSession(String fromSessionId, String toSessionId) {
    if (fromSessionId == toSessionId) return;
    final source = _sessions.remove(fromSessionId);
    if (source == null) return;
    final target = _stateFor(toSessionId);
    if (source._messages.isNotEmpty) {
      target._messages
        ..clear()
        ..addAll(source._messages);
      target._messageSeqs
        ..clear()
        ..addAll(source._messageSeqs);
    }
    target.historySeq = source.historySeq;
    target.cachedHistorySeq = source.cachedHistorySeq;
    target.contentEpoch = source.contentEpoch;
    target.explorerHistory = source.explorerHistory;
    _trim(target);
  }

  void clearSession(String sessionId) {
    _sessions.remove(sessionId);
  }

  void clearAll() {
    _sessions.clear();
  }

  SessionRuntimeState _stateFor(String sessionId) {
    return _sessions.putIfAbsent(
      sessionId,
      () => SessionRuntimeState(sessionId: sessionId),
    );
  }

  bool _shouldIgnore(ServerMessage message) {
    return message is LocalFeatureTransientMessage ||
        message is PastHistoryMessage ||
        message is StreamDeltaMessage ||
        message is ThinkingDeltaMessage ||
        message is InputAckMessage ||
        message is InputDeliveryStatusMessage ||
        message is InputRejectedMessage ||
        message is ArtifactResolvedMessage ||
        message is GoalStateMessage ||
        (message is SystemMessage && message.subtype == 'codex_settings');
  }

  bool _representsHistoryEntry(ServerMessage message) =>
      !_shouldIgnore(message);

  void _recordLatestSeq(SessionRuntimeState state, int? historySeq) {
    if (historySeq != null && historySeq > state.historySeq) {
      state.historySeq = historySeq;
    }
  }

  void _clearMessages(SessionRuntimeState state) {
    state._messages.clear();
    state._messageSeqs.clear();
  }

  void _mergeHistoryEntries(
    SessionRuntimeState state,
    List<HistoryEntry> entries,
  ) {
    for (final entry in entries) {
      if (_shouldIgnore(entry.message)) continue;
      _upsertMessage(state, entry.message, entry.seq);
    }
  }

  void _upsertMessage(
    SessionRuntimeState state,
    ServerMessage message,
    int? historySeq,
  ) {
    if (historySeq == null) {
      state._messages.add(message);
      state._messageSeqs.add(null);
      return;
    }
    final insertionIndex = _sequencedInsertionIndex(
      state._messageSeqs,
      historySeq,
    );
    if (insertionIndex < state._messageSeqs.length &&
        state._messageSeqs[insertionIndex] == historySeq) {
      state._messages[insertionIndex] = message;
      return;
    }
    state._messages.insert(insertionIndex, message);
    state._messageSeqs.insert(insertionIndex, historySeq);
  }

  int _sequencedInsertionIndex(List<int?> sequences, int target) {
    var low = 0;
    var high = sequences.length;
    while (low < high) {
      final middle = low + ((high - low) >> 1);
      final sequence = sequences[middle];
      if (sequence == null || sequence >= target) {
        high = middle;
      } else {
        low = middle + 1;
      }
    }
    return low;
  }

  void _advanceCachedHistorySeq(SessionRuntimeState state) {
    var nextSeq = state.cachedHistorySeq + 1;
    while (state._messageSeqs.contains(nextSeq)) {
      state.cachedHistorySeq = nextSeq;
      nextSeq++;
    }
  }

  bool _deltaExtendsCachedHistory(
    int cachedHistorySeq,
    HistoryDeltaMessage message,
  ) {
    if (message.fromSeq > cachedHistorySeq + 1) return false;
    if (message.toSeq <= cachedHistorySeq) return true;

    final entrySeqs = message.entries
        .where((entry) => !_shouldIgnore(entry.message))
        .map((entry) => entry.seq)
        .toSet();
    for (var seq = message.fromSeq; seq <= message.toSeq; seq++) {
      if (seq <= cachedHistorySeq) continue;
      if (!entrySeqs.contains(seq)) return false;
    }
    return true;
  }

  bool _trim(SessionRuntimeState state) {
    if (maxMessagesPerSession <= 0) {
      final changed = state._messages.isNotEmpty;
      _clearMessages(state);
      return changed;
    }
    final projected = projectTurnAwareServerMessageWindow(
      state._messages,
      maxRetainedEntries: maxMessagesPerSession,
    );
    final unchanged =
        projected.length == state._messages.length &&
        projected.indexed.every(
          (value) =>
              value.$2.sourceIndex == value.$1 &&
              identical(value.$2.message, state._messages[value.$1]),
        );
    if (unchanged) return false;
    final selectedMessages = [for (final value in projected) value.message];
    final selectedSeqs = [
      for (final value in projected) state._messageSeqs[value.sourceIndex],
    ];
    state._messages
      ..clear()
      ..addAll(selectedMessages);
    state._messageSeqs
      ..clear()
      ..addAll(selectedSeqs);
    return true;
  }

  void _removeIfEmpty(SessionRuntimeState state) {
    if (state._messages.isEmpty &&
        state.explorerHistory.currentPath.isEmpty &&
        state.explorerHistory.recentPeekedFiles.isEmpty) {
      _sessions.remove(state.sessionId);
    }
  }
}
