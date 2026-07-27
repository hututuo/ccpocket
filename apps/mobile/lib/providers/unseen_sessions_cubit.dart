import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/messages.dart';

/// Tracks completed sessions whose latest authoritative activity has not been
/// viewed on this device.
///
/// Persistence uses Bridge scope + provider + durable provider session
/// identity when available, so a Bridge reconnect that replaces the runtime ID
/// does not erase unread state and two Bridges cannot share seen state.
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
  String? _latestScopeKey;
  String? _latestVisibleSessionId;
  String? _latestVisibleProvider;
  String? _activeScopeKey;

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
          scopeKey: _latestScopeKey!,
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
    String scopeKey = 'legacy-default-bridge',
    String? visibleSessionId,
    String? visibleProvider,
  }) {
    final normalizedScope = _normalizedScope(scopeKey);
    _latestSessions = List<SessionInfo>.of(sessions);
    _latestScopeKey = normalizedScope;
    _latestVisibleSessionId = visibleSessionId;
    _latestVisibleProvider = visibleProvider;
    _switchScope(normalizedScope);
    if (!_loaded) return;

    final unseen = <String>{};
    final currentRuntimeIds = <String>{};
    final currentStableKeys = <String>{};
    var persistenceChanged = false;

    for (final session in sessions) {
      final runtimeKey = _runtimeKey(normalizedScope, session.id);
      currentRuntimeIds.add(runtimeKey);
      final stableKey = _stableKey(normalizedScope, session);
      currentStableKeys.add(stableKey);
      _runtimeToStable[runtimeKey] = stableKey;

      final legacyRuntimeSeenAt = _seenAt.remove(session.id);
      final legacyStableSeenAt = _seenAt.remove(_legacyStableKey(session));
      final legacySeenAt = _newestTimestamp([
        legacyRuntimeSeenAt,
        legacyStableSeenAt,
      ]);
      if (legacyRuntimeSeenAt != null || legacyStableSeenAt != null) {
        persistenceChanged = true;
      }
      if (legacySeenAt != null && !_seenAt.containsKey(stableKey)) {
        _seenAt[stableKey] = legacySeenAt;
      }

      final lastActivity = session.lastActivityAt.trim();
      if (lastActivity.isNotEmpty) {
        _lastActivityAt[stableKey] = lastActivity;
      }

      final pendingRuntimeSeen =
          _pendingInitialSeen.remove(_pendingRuntimeKey(runtimeKey)) != null;
      final pendingStableSeen =
          _pendingInitialSeen.remove(_pendingStableKey(stableKey)) != null;
      final pendingInitialSeen = pendingRuntimeSeen || pendingStableSeen;
      if (pendingInitialSeen && lastActivity.isNotEmpty) {
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
  void markSeen(
    String sessionId, {
    String scopeKey = 'legacy-default-bridge',
    String? provider,
    String? durableProviderSessionId,
  }) {
    final normalizedScope = _normalizedScope(scopeKey);
    final scopeChanged = _switchScope(normalizedScope);
    final runtimeKey = _runtimeKey(normalizedScope, sessionId);
    final durableId = durableProviderSessionId?.trim();
    final stableKey = durableId?.isNotEmpty == true
        ? _stableKeyForIdentity(
            normalizedScope,
            _normalizedProvider(provider),
            durableId!,
          )
        : _runtimeToStable[runtimeKey];
    final lastActivity = stableKey == null ? null : _lastActivityAt[stableKey];
    if (_loaded &&
        stableKey != null &&
        lastActivity != null &&
        lastActivity.isNotEmpty) {
      if (_setSeenAt(stableKey, lastActivity)) {
        _scheduleSave();
      }
      _pendingInitialSeen.remove(_pendingRuntimeKey(runtimeKey));
      _pendingInitialSeen.remove(_pendingStableKey(stableKey));
    } else {
      final pendingKey = stableKey == null
          ? _pendingRuntimeKey(runtimeKey)
          : _pendingStableKey(stableKey);
      _pendingInitialSeen[pendingKey] = DateTime.now().toUtc();
      _prunePendingInitialSeen();
    }

    final next = scopeChanged
        ? <String>{}
        : (Set<String>.from(state)..remove(sessionId));
    if (!setEquals(state, next)) emit(next);
  }

  bool isUnseen(String sessionId) => state.contains(sessionId);

  String _stableKey(String scopeKey, SessionInfo session) {
    final provider = _normalizedProvider(session.provider);
    final durableId = session.claudeSessionId?.trim();
    final identity = durableId?.isNotEmpty == true ? durableId! : session.id;
    return _stableKeyForIdentity(scopeKey, provider, identity);
  }

  String _stableKeyForIdentity(
    String scopeKey,
    String provider,
    String identity,
  ) {
    return 'v2|${Uri.encodeComponent(scopeKey)}|$provider|'
        '${Uri.encodeComponent(identity)}';
  }

  String _legacyStableKey(SessionInfo session) {
    final provider = _normalizedProvider(session.provider);
    final durableId = session.claudeSessionId?.trim();
    return '$provider:${durableId?.isNotEmpty == true ? durableId : session.id}';
  }

  String _runtimeKey(String scopeKey, String sessionId) =>
      '${Uri.encodeComponent(scopeKey)}|${Uri.encodeComponent(sessionId)}';

  String _pendingRuntimeKey(String runtimeKey) => 'runtime|$runtimeKey';

  String _pendingStableKey(String stableKey) => 'stable|$stableKey';

  String _normalizedScope(String scopeKey) {
    final normalized = scopeKey.trim();
    return normalized.isEmpty ? 'unknown-bridge' : normalized;
  }

  String _normalizedProvider(String? provider) =>
      provider == Provider.codex.value
      ? Provider.codex.value
      : Provider.claude.value;

  bool _switchScope(String scopeKey) {
    if (_activeScopeKey == scopeKey) return false;
    _activeScopeKey = scopeKey;
    _runtimeToStable.clear();
    _lastActivityAt.clear();
    _pendingInitialSeen.clear();
    return true;
  }

  String? _newestTimestamp(Iterable<String?> timestamps) {
    String? newest;
    for (final timestamp in timestamps) {
      if (timestamp == null) continue;
      if (newest == null || _isAfter(timestamp, newest)) newest = timestamp;
    }
    return newest;
  }

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
