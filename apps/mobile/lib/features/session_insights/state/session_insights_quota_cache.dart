import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../models/messages.dart'
    show SessionUsageInfo, SessionUsageLimitCard, SessionUsageWindow;

/// A bounded, display-only snapshot of the quota rings for one durable thread.
class SessionInsightsCachedQuota {
  const SessionInsightsCachedQuota({
    required this.quota,
    required this.cachedAt,
  });

  final SessionUsageInfo quota;
  final DateTime cachedAt;
}

/// Best-effort phone-local storage for stale-while-refresh quota rendering.
///
/// Only quota windows are persisted. Reset-credit profile data, request IDs,
/// errors, and session content never enter this cache.
class SessionInsightsQuotaCache {
  static const _schemaVersion = 1;
  static const _preferenceKey = 'session_insights_quota_windows_v1';
  static const _maximumEncodedBytes = 64 * 1024;
  static const _maximumEntries = 32;
  static const _maximumLimitCards = 32;
  static const _maximumRetention = Duration(days: 1);
  static const _maximumFutureClockSkew = Duration(minutes: 5);

  Future<void> _operationTail = Future<void>.value();

  Future<SessionInsightsCachedQuota?> read({
    required String sourceKey,
    required String sessionId,
    required DateTime now,
    required Duration timeToLive,
  }) => _enqueue(
    () => _read(
      identity: _identity(sourceKey, sessionId),
      now: now,
      timeToLive: timeToLive,
    ),
  );

  Future<void> write({
    required String sourceKey,
    required String sessionId,
    required SessionUsageInfo quota,
    required DateTime cachedAt,
  }) => _enqueue(
    () => _write(
      identity: _identity(sourceKey, sessionId),
      quota: quota,
      cachedAt: cachedAt,
    ),
  );

  static bool hasQuotaWindows(SessionUsageInfo quota) =>
      quota.fiveHour != null ||
      quota.sevenDay != null ||
      quota.limitCards.any(
        (card) => card.fiveHour != null || card.sevenDay != null,
      );

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final result = _operationTail.then((_) => operation());
    _operationTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<SessionInsightsCachedQuota?> _read({
    required String identity,
    required DateTime now,
    required Duration timeToLive,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    final entries = await _loadEntries(preferences);
    final stored = entries[identity];
    if (stored == null) return null;
    if (stored.cachedAt.isBefore(now.subtract(timeToLive)) ||
        stored.cachedAt.isAfter(now.add(_maximumFutureClockSkew))) {
      entries.remove(identity);
      await _storeEntries(preferences, entries);
      return null;
    }
    try {
      final quota = SessionUsageInfo.fromJson(stored.quota);
      if (quota.provider != 'codex' || !hasQuotaWindows(quota)) {
        entries.remove(identity);
        await _storeEntries(preferences, entries);
        return null;
      }
      return SessionInsightsCachedQuota(
        quota: quota,
        cachedAt: stored.cachedAt,
      );
    } catch (_) {
      entries.remove(identity);
      await _storeEntries(preferences, entries);
      return null;
    }
  }

  Future<void> _write({
    required String identity,
    required SessionUsageInfo quota,
    required DateTime cachedAt,
  }) async {
    final projected = _quotaToJson(quota);
    if (projected == null) return;
    final preferences = await SharedPreferences.getInstance();
    final entries = await _loadEntries(preferences);
    entries.removeWhere(
      (_, entry) =>
          entry.cachedAt.isBefore(cachedAt.subtract(_maximumRetention)) ||
          entry.cachedAt.isAfter(cachedAt.add(_maximumFutureClockSkew)),
    );
    entries.remove(identity);
    entries[identity] = _StoredQuota(cachedAt: cachedAt, quota: projected);
    await _storeEntries(preferences, entries);
  }

  Future<Map<String, _StoredQuota>> _loadEntries(
    SharedPreferences preferences,
  ) async {
    final entries = <String, _StoredQuota>{};
    try {
      final raw = preferences.getString(_preferenceKey);
      if (raw == null) return entries;
      if (raw.length > _maximumEncodedBytes ||
          utf8.encode(raw).length > _maximumEncodedBytes) {
        await preferences.remove(_preferenceKey);
        return entries;
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['version'] != _schemaVersion) {
        await preferences.remove(_preferenceKey);
        return entries;
      }
      final rawEntries = decoded['entries'];
      if (rawEntries is! Map) {
        await preferences.remove(_preferenceKey);
        return entries;
      }
      var needsRewrite = false;
      for (final entry in rawEntries.entries) {
        if (entry.key is! String || entry.value is! Map) {
          needsRewrite = true;
          continue;
        }
        try {
          entries[entry.key as String] = _StoredQuota.fromJson(
            Map<String, dynamic>.from(entry.value as Map),
          );
        } catch (_) {
          needsRewrite = true;
        }
      }
      if (entries.length > _maximumEntries) {
        _trimOldestEntries(entries);
        needsRewrite = true;
      }
      if (needsRewrite) await _storeEntries(preferences, entries);
      return entries;
    } catch (_) {
      await preferences.remove(_preferenceKey);
      return entries;
    }
  }

  Future<void> _storeEntries(
    SharedPreferences preferences,
    Map<String, _StoredQuota> entries,
  ) async {
    final ordered = entries.entries.toList(growable: true)
      ..sort(
        (left, right) => left.value.cachedAt.compareTo(right.value.cachedAt),
      );
    while (ordered.length > _maximumEntries) {
      ordered.removeAt(0);
    }
    while (ordered.isNotEmpty) {
      final encoded = jsonEncode(<String, dynamic>{
        'version': _schemaVersion,
        'entries': <String, dynamic>{
          for (final entry in ordered) entry.key: entry.value.toJson(),
        },
      });
      if (utf8.encode(encoded).length <= _maximumEncodedBytes) {
        await preferences.setString(_preferenceKey, encoded);
        return;
      }
      ordered.removeAt(0);
    }
    await preferences.remove(_preferenceKey);
  }

  static void _trimOldestEntries(Map<String, _StoredQuota> entries) {
    if (entries.length <= _maximumEntries) return;
    final ordered = entries.entries.toList(growable: false)
      ..sort(
        (left, right) => left.value.cachedAt.compareTo(right.value.cachedAt),
      );
    for (final entry in ordered.take(entries.length - _maximumEntries)) {
      entries.remove(entry.key);
    }
  }

  static String _identity(String sourceKey, String sessionId) =>
      base64Url.encode(utf8.encode('$sourceKey\u0000$sessionId'));

  static Map<String, dynamic>? _quotaToJson(SessionUsageInfo quota) {
    if (quota.provider != 'codex' || !hasQuotaWindows(quota)) return null;
    final cards = quota.limitCards
        .take(_maximumLimitCards)
        .map(_cardToJson)
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);
    final fiveHour = _windowToJson(quota.fiveHour);
    final sevenDay = _windowToJson(quota.sevenDay);
    return <String, dynamic>{
      'provider': 'codex',
      'fiveHour': ?fiveHour,
      'sevenDay': ?sevenDay,
      if (cards.isNotEmpty) 'limitCards': cards,
    };
  }

  static Map<String, dynamic>? _cardToJson(SessionUsageLimitCard card) {
    final fiveHour = _windowToJson(card.fiveHour);
    final sevenDay = _windowToJson(card.sevenDay);
    if (fiveHour == null && sevenDay == null) return null;
    return <String, dynamic>{
      'id': card.id,
      'fiveHour': ?fiveHour,
      'sevenDay': ?sevenDay,
    };
  }

  static Map<String, dynamic>? _windowToJson(SessionUsageWindow? window) {
    if (window == null || !window.utilization.isFinite) return null;
    return <String, dynamic>{
      'utilization': window.utilization,
      if (window.resetsAt != null) 'resetsAt': window.resetsAt,
      if (window.windowDurationMins != null)
        'windowDurationMins': window.windowDurationMins,
    };
  }
}

class _StoredQuota {
  const _StoredQuota({required this.cachedAt, required this.quota});

  final DateTime cachedAt;
  final Map<String, dynamic> quota;

  factory _StoredQuota.fromJson(Map<String, dynamic> json) {
    final cachedAtMilliseconds = json['cachedAtMs'];
    final rawQuota = json['quota'];
    if (cachedAtMilliseconds is! int || rawQuota is! Map) {
      throw const FormatException('Invalid session insights quota cache row');
    }
    return _StoredQuota(
      cachedAt: DateTime.fromMillisecondsSinceEpoch(
        cachedAtMilliseconds,
        isUtc: true,
      ),
      quota: Map<String, dynamic>.from(rawQuota),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'cachedAtMs': cachedAt.toUtc().millisecondsSinceEpoch,
    'quota': quota,
  };
}
