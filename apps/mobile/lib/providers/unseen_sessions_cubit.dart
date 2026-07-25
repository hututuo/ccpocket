import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/messages.dart';

/// Tracks completed sessions whose latest authoritative activity has not been
/// viewed on this device.
///
/// Persistence uses provider + durable provider session identity when
/// available, so a Bridge reconnect that replaces the runtime ID does not
/// erase or misattribute unread state.
class UnseenSessionsCubit extends Cubit<Set<String>> {
  static const _prefsKey = 'unseen_sessions_seen_at';
  static const _maximumPersistedSessions = 1000;
  static const _maximumPendingInitialSeen = 64;
  static const _pendingInitialSeenMaxAge = Duration(minutes: 2);

  final Map<String, String> _seenAt = <String, String>{};
  final Map<String, DateTime> _pendingInitialSeen = <String, DateTime>{};
  final Map<String, String> _runtimeToStable = <String, String>{};
  final Map<String, String> _lastActivityAt = <String, String>{};
  late final Future<void> _ready;
  Future<void> _saveChain = Future<void>.value();
  bool _loaded = false;
  List<SessionInfo>? _latestSessions;
  String? _latestVisibleSessionId;
  String? _latestVisibleProvider;

  UnseenSessionsCubit() : super(const <String>{}) {
    _ready = _loadSeenAt();
  }

  Future<void> get ready => _ready;

  Future<void> _loadSeenAt() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            final key = entry.key;
            final value = entry.value;
            if (key is String &&
                key.isNotEmpty &&
                key.length <= 600 &&
                value is String &&
                value.length <= 64) {
              _seenAt[key] = value;
            }
          }
        }
      }
    } on FormatException {
      _seenAt.clear();
    } finally {
      _loaded = true;
      final sessions = _latestSessions;
      if (sessions != null && !isClosed) {
        updateSessions(
          sessions,
          visibleSessionId: _latestVisibleSessionId,
          visibleProvider: _latestVisibleProvider,
        );
      }
    }
  }

  void _scheduleSave() {
    final encoded = jsonEncode(Map<String, String>.of(_seenAt));
    _saveChain = _saveChain
        .then((_) async {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_prefsKey, encoded);
        })
        .catchError((Object _) {
          // Keep the chain usable after a storage failure. The next authoritative
          // update will retry with a fresh snapshot.
        });
  }

  /// Recomputes unread state from the authoritative active-session snapshot.
  ///
  /// A visible session is advanced to its exact activity timestamp. There is
  /// deliberately no future-time buffer: once the user leaves, a later
  /// completion becomes unread immediately.
  void updateSessions(
    List<SessionInfo> sessions, {
    String? visibleSessionId,
    String? visibleProvider,
  }) {
    _latestSessions = List<SessionInfo>.of(sessions);
    _latestVisibleSessionId = visibleSessionId;
    _latestVisibleProvider = visibleProvider;
    if (!_loaded) return;

    final unseen = <String>{};
    final currentRuntimeIds = <String>{};
    final currentStableKeys = <String>{};
    var persistenceChanged = false;

    for (final session in sessions) {
      currentRuntimeIds.add(session.id);
      final stableKey = _stableKey(session);
      currentStableKeys.add(stableKey);
      _runtimeToStable[session.id] = stableKey;

      final legacySeenAt = _seenAt.remove(session.id);
      if (legacySeenAt != null) {
        _seenAt.putIfAbsent(stableKey, () => legacySeenAt);
        persistenceChanged = true;
      }

      final lastActivity = session.lastActivityAt.trim();
      if (lastActivity.isNotEmpty) {
        _lastActivityAt[stableKey] = lastActivity;
      }

      if (_pendingInitialSeen.remove(session.id) != null &&
          lastActivity.isNotEmpty) {
        persistenceChanged =
            _setSeenAt(stableKey, lastActivity) || persistenceChanged;
      }

      final isVisible =
          visibleSessionId == session.id &&
          _normalizedProvider(visibleProvider) ==
              _normalizedProvider(session.provider);
      if (isVisible && lastActivity.isNotEmpty) {
        persistenceChanged =
            _setSeenAt(stableKey, lastActivity) || persistenceChanged;
        continue;
      }

      // Working and Needs You already have their own stronger indicators.
      if (session.status != 'idle' || lastActivity.isEmpty) continue;
      final seenAt = _seenAt[stableKey];
      if (seenAt == null || _isAfter(lastActivity, seenAt)) {
        unseen.add(session.id);
      }
    }

    _runtimeToStable.removeWhere(
      (runtimeId, _) => !currentRuntimeIds.contains(runtimeId),
    );
    _prunePendingInitialSeen();
    _lastActivityAt.removeWhere(
      (stableKey, _) => !currentStableKeys.contains(stableKey),
    );
    persistenceChanged = _pruneSeenAt() || persistenceChanged;

    if (!setEquals(state, unseen)) emit(unseen);
    if (persistenceChanged) _scheduleSave();
  }

  /// Marks the currently known activity for [sessionId] as seen.
  ///
  /// A just-created runtime ID may arrive before its first session snapshot;
  /// that one initial timestamp is suppressed once and then normal comparison
  /// resumes.
  void markSeen(String sessionId) {
    final stableKey = _runtimeToStable[sessionId];
    final lastActivity = stableKey == null ? null : _lastActivityAt[stableKey];
    if (_loaded &&
        stableKey != null &&
        lastActivity != null &&
        lastActivity.isNotEmpty) {
      if (_setSeenAt(stableKey, lastActivity)) {
        _scheduleSave();
      }
      _pendingInitialSeen.remove(sessionId);
    } else {
      _pendingInitialSeen[sessionId] = DateTime.now().toUtc();
      _prunePendingInitialSeen();
    }

    final next = Set<String>.from(state)..remove(sessionId);
    if (!setEquals(state, next)) emit(next);
  }

  bool isUnseen(String sessionId) => state.contains(sessionId);

  String _stableKey(SessionInfo session) {
    final provider = _normalizedProvider(session.provider);
    final durableId = session.claudeSessionId?.trim();
    return '$provider:${durableId?.isNotEmpty == true ? durableId : session.id}';
  }

  String _normalizedProvider(String? provider) =>
      provider == Provider.codex.value
      ? Provider.codex.value
      : Provider.claude.value;

  bool _setSeenAt(String stableKey, String timestamp) {
    if (_seenAt[stableKey] == timestamp) return false;
    _seenAt[stableKey] = timestamp;
    return true;
  }

  bool _isAfter(String candidate, String baseline) {
    final candidateTime = DateTime.tryParse(candidate);
    final baselineTime = DateTime.tryParse(baseline);
    if (candidateTime != null && baselineTime != null) {
      return candidateTime.toUtc().isAfter(baselineTime.toUtc());
    }
    return candidate.compareTo(baseline) > 0;
  }

  bool _pruneSeenAt() {
    if (_seenAt.length <= _maximumPersistedSessions) return false;
    final entries = _seenAt.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    final removeCount = entries.length - _maximumPersistedSessions;
    for (final entry in entries.take(removeCount)) {
      _seenAt.remove(entry.key);
    }
    return true;
  }

  void _prunePendingInitialSeen() {
    final cutoff = DateTime.now().toUtc().subtract(_pendingInitialSeenMaxAge);
    _pendingInitialSeen.removeWhere(
      (_, createdAt) => createdAt.isBefore(cutoff),
    );
    if (_pendingInitialSeen.length <= _maximumPendingInitialSeen) return;
    final entries = _pendingInitialSeen.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    final removeCount = entries.length - _maximumPendingInitialSeen;
    for (final entry in entries.take(removeCount)) {
      _pendingInitialSeen.remove(entry.key);
    }
  }

  @override
  Future<void> close() async {
    await _ready;
    await _saveChain;
    return super.close();
  }
}
