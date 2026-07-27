import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:crypto/crypto.dart';

import '../core/logger.dart';
import '../models/machine.dart';
import '../models/messages.dart';
import '../utils/command_parser.dart';
import '../utils/network_endpoint.dart';
import 'bridge_service.dart';
import 'database_service.dart';
import 'machine_manager_service.dart';

int _compareIso(String left, String right) {
  final leftTime = DateTime.tryParse(left);
  final rightTime = DateTime.tryParse(right);
  if (leftTime != null && rightTime != null) {
    return leftTime.toUtc().compareTo(rightTime.toUtc());
  }
  return left.compareTo(right);
}

String _maxIso(String left, String right) =>
    _compareIso(left, right) >= 0 ? left : right;

/// Sort order for prompt history queries.
enum PromptSortOrder {
  /// Most recently used first.
  recency,

  /// Most frequently used first.
  frequency,

  /// Favorites first, then by recency.
  favoritesFirst,
}

class PromptHistoryFilters {
  final bool selfOnly;
  final bool currentProjectOnly;
  final bool currentBridgeOnly;
  final bool favoritesOnly;
  final bool commandsOnly;

  const PromptHistoryFilters({
    this.selfOnly = false,
    this.currentProjectOnly = false,
    this.currentBridgeOnly = false,
    this.favoritesOnly = false,
    this.commandsOnly = false,
  });

  bool get hasActiveFilter =>
      selfOnly ||
      currentProjectOnly ||
      currentBridgeOnly ||
      favoritesOnly ||
      commandsOnly;

  PromptHistoryFilters copyWith({
    bool? selfOnly,
    bool? currentProjectOnly,
    bool? currentBridgeOnly,
    bool? favoritesOnly,
    bool? commandsOnly,
  }) {
    return PromptHistoryFilters(
      selfOnly: selfOnly ?? this.selfOnly,
      currentProjectOnly: currentProjectOnly ?? this.currentProjectOnly,
      currentBridgeOnly: currentBridgeOnly ?? this.currentBridgeOnly,
      favoritesOnly: favoritesOnly ?? this.favoritesOnly,
      commandsOnly: commandsOnly ?? this.commandsOnly,
    );
  }
}

/// Cache row identity that contributed to a displayed prompt history row.
class PromptHistorySource {
  final String id;
  final String bridgeId;

  const PromptHistorySource({required this.id, required this.bridgeId});
}

/// A single prompt history entry after app-side multi-Bridge merge.
class PromptHistoryEntry {
  final String id;
  final String text;
  final String projectPath;
  final int useCount;
  final bool isFavorite;
  final DateTime createdAt;
  final DateTime lastUsedAt;
  final DateTime updatedAt;
  final String commandKind;
  final List<String> bridgeIds;
  final List<String> bridgeNames;
  final Map<String, PromptHistoryClientStat> clientStats;
  final Map<String, PromptHistorySessionStat> sessionStats;
  final List<PromptHistorySource> sources;

  const PromptHistoryEntry({
    required this.id,
    required this.text,
    required this.projectPath,
    required this.useCount,
    required this.isFavorite,
    required this.createdAt,
    required this.lastUsedAt,
    required this.updatedAt,
    required this.commandKind,
    required this.bridgeIds,
    required this.bridgeNames,
    required this.clientStats,
    required this.sessionStats,
    this.sources = const [],
  });

  /// Display name for the project (last path component or empty string).
  String get projectName {
    if (projectPath.isEmpty) return '';
    return projectPath.split('/').last;
  }

  bool get isLegacy => id.startsWith('v1_');

  PromptHistoryEntry merge(PromptHistoryEntry other) {
    final clients = Map<String, PromptHistoryClientStat>.from(clientStats);
    for (final item in other.clientStats.entries) {
      final current = clients[item.key];
      clients[item.key] = current == null
          ? item.value
          : PromptHistoryClientStat(
              useCount: current.useCount + item.value.useCount,
              lastUsedAt: _maxIso(current.lastUsedAt, item.value.lastUsedAt),
              clientName: item.value.clientName ?? current.clientName,
            );
    }

    final sessions = Map<String, PromptHistorySessionStat>.from(sessionStats);
    for (final item in other.sessionStats.entries) {
      final current = sessions[item.key];
      sessions[item.key] = current == null
          ? item.value
          : PromptHistorySessionStat(
              useCount: current.useCount + item.value.useCount,
              lastUsedAt: _maxIso(current.lastUsedAt, item.value.lastUsedAt),
            );
    }

    return PromptHistoryEntry(
      id: id,
      text: text,
      projectPath: projectPath,
      useCount: useCount + other.useCount,
      isFavorite: isFavorite || other.isFavorite,
      createdAt: createdAt.isBefore(other.createdAt)
          ? createdAt
          : other.createdAt,
      lastUsedAt: lastUsedAt.isAfter(other.lastUsedAt)
          ? lastUsedAt
          : other.lastUsedAt,
      updatedAt: updatedAt.isAfter(other.updatedAt)
          ? updatedAt
          : other.updatedAt,
      commandKind: commandKind == 'none' ? other.commandKind : commandKind,
      bridgeIds: {...bridgeIds, ...other.bridgeIds}.toList(),
      bridgeNames: {...bridgeNames, ...other.bridgeNames}.toList(),
      clientStats: clients,
      sessionStats: sessions,
      sources: _mergeSources(sources, other.sources),
    );
  }

  static List<PromptHistorySource> _mergeSources(
    List<PromptHistorySource> left,
    List<PromptHistorySource> right,
  ) {
    final merged = <String, PromptHistorySource>{};
    for (final source in [...left, ...right]) {
      merged['${source.bridgeId}\u0000${source.id}'] = source;
    }
    return merged.values.toList();
  }
}

class PromptHistorySyncStatus {
  final String bridgeId;
  final String bridgeUrl;
  final String bridgeName;
  final DateTime? lastSyncAt;
  final int revision;
  final int entryCount;
  final String? error;

  const PromptHistorySyncStatus({
    required this.bridgeId,
    required this.bridgeUrl,
    required this.bridgeName,
    this.lastSyncAt,
    required this.revision,
    required this.entryCount,
    this.error,
  });
}

class PromptHistorySyncTarget {
  final String bridgeId;
  final String bridgeUrl;
  final String bridgeName;

  const PromptHistorySyncTarget({
    required this.bridgeId,
    required this.bridgeUrl,
    required this.bridgeName,
  });
}

class _PendingPromptCacheRow {
  const _PendingPromptCacheRow({
    required this.row,
    required this.pendingLocalAt,
  });

  final Map<String, Object?> row;
  final String pendingLocalAt;
}

/// Service for managing Prompt History 2.0 cache and Bridge sync.
///
/// The Bridge is the SSoT. The local database is a cache plus a retained 1.0
/// table for fallback and migration.
class PromptHistoryService {
  static const _clientDeviceIdKey = 'prompt_history_client_device_id_v2';
  static const _bridgeAliasMapKey = 'prompt_history_bridge_alias_map_v2';
  static const _defaultSelfOnlyKey = 'prompt_history_default_self_only_v2';
  static const _defaultProjectOnlyKey =
      'prompt_history_default_project_only_v2';
  static const _defaultBridgeOnlyKey = 'prompt_history_default_bridge_only_v2';
  static const _defaultFavoritesOnlyKey =
      'prompt_history_default_favorites_only_v2';
  static const _defaultCommandsOnlyKey =
      'prompt_history_default_commands_only_v2';
  static const _filtersExpandedKey = 'prompt_history_filters_expanded_v2';
  static const _legacyMigrationDismissedKey =
      'prompt_history_legacy_migration_dismissed_v2';
  static const _syncTimeout = Duration(seconds: 8);
  static const _uuid = Uuid();

  final DatabaseService _dbService;
  final Map<String, Future<String?>> _bridgeSyncsInFlight = {};
  Future<void>? _pendingLocalTableReady;
  Future<void> _cacheMutationTail = Future<void>.value();

  PromptHistoryService(this._dbService);

  Future<Database?> get _db => _dbService.database;

  Future<T> _serializeCacheMutation<T>(Future<T> Function() operation) {
    final result = _cacheMutationTail.then((_) => operation());
    _cacheMutationTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<String> get clientDeviceId async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_clientDeviceIdKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final value = _uuid.v4();
    await prefs.setString(_clientDeviceIdKey, value);
    return value;
  }

  Future<String> get clientName async => 'CC Pocket';

  Future<Map<String, String>> getBridgeAliasMap() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_bridgeAliasMapKey);
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((key, value) => MapEntry(key, value as String));
    } catch (e) {
      logger.warning('[PromptHistory] bridge alias map decode failed', e);
      return const {};
    }
  }

  Future<void> _rememberBridgeAlias({
    required String aliasBridgeId,
    required String canonicalBridgeId,
  }) async {
    if (aliasBridgeId.isEmpty || canonicalBridgeId.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final aliases = Map<String, String>.from(await getBridgeAliasMap());
    aliases[aliasBridgeId] = canonicalBridgeId;
    aliases[canonicalBridgeId] = canonicalBridgeId;
    await prefs.setString(_bridgeAliasMapKey, jsonEncode(aliases));
  }

  Future<PromptHistoryFilters> getDefaultFilters() async {
    final prefs = await SharedPreferences.getInstance();
    return PromptHistoryFilters(
      selfOnly: prefs.getBool(_defaultSelfOnlyKey) ?? false,
      currentProjectOnly: prefs.getBool(_defaultProjectOnlyKey) ?? false,
      currentBridgeOnly: prefs.getBool(_defaultBridgeOnlyKey) ?? false,
      favoritesOnly: prefs.getBool(_defaultFavoritesOnlyKey) ?? false,
      commandsOnly: prefs.getBool(_defaultCommandsOnlyKey) ?? false,
    );
  }

  Future<void> setDefaultFilters(PromptHistoryFilters filters) async {
    final prefs = await SharedPreferences.getInstance();
    await Future.wait([
      prefs.setBool(_defaultSelfOnlyKey, filters.selfOnly),
      prefs.setBool(_defaultProjectOnlyKey, filters.currentProjectOnly),
      prefs.setBool(_defaultBridgeOnlyKey, filters.currentBridgeOnly),
      prefs.setBool(_defaultFavoritesOnlyKey, filters.favoritesOnly),
      prefs.setBool(_defaultCommandsOnlyKey, filters.commandsOnly),
    ]);
  }

  Future<bool> getFiltersExpanded() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_filtersExpandedKey) ?? false;
  }

  Future<void> setFiltersExpanded(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_filtersExpandedKey, value);
  }

  Future<void> setDefaultSelfOnly(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_defaultSelfOnlyKey, value);
  }

  Future<void> setDefaultFavoritesOnly(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_defaultFavoritesOnlyKey, value);
  }

  Future<bool> isLegacyMigrationDismissed() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_legacyMigrationDismissedKey) ?? false;
  }

  Future<void> setLegacyMigrationDismissed(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_legacyMigrationDismissedKey, value);
  }

  String? bridgeIdForUrl(String? url) {
    if (url == null || url.isEmpty) return null;
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return null;
    final port = uri.hasPort
        ? uri.port
        : uri.scheme.toLowerCase() == 'wss'
        ? 443
        : 80;
    return endpointIdentityKey(uri.host, port);
  }

  // ---------------------------------------------------------------------------
  // Recording
  // ---------------------------------------------------------------------------

  Future<void> recordPrompt(
    String text, {
    String projectPath = '',
    BridgeService? bridgeService,
    String? sessionId,
  }) async {
    final trimmed = text.trim();
    if (!_shouldRecord(trimmed)) return;

    await _recordPromptV1(trimmed, projectPath: projectPath);

    final bridgeUrl = bridgeService?.lastUrl;
    final bridgeId =
        bridgeService?.promptHistoryBridgeId ?? bridgeIdForUrl(bridgeUrl);
    final clientId = await clientDeviceId;
    final name = await clientName;
    final usedAt = DateTime.now().toUtc().toIso8601String();

    if (bridgeService?.isConnected == true && bridgeId != null) {
      bridgeService!.send(
        ClientMessage.recordPromptHistory(
          text: trimmed,
          projectPath: projectPath,
          clientId: clientId,
          clientName: name,
          sessionId: sessionId,
          usedAt: usedAt,
        ),
      );
      await _recordCacheUse(
        bridgeId: bridgeId,
        bridgeUrl: _redactBridgeUrl(bridgeUrl!),
        bridgeName: bridgeId,
        text: trimmed,
        projectPath: projectPath,
        clientId: clientId,
        clientName: name,
        sessionId: sessionId,
        usedAt: usedAt,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Sync
  // ---------------------------------------------------------------------------

  Future<List<PromptHistorySyncStatus>> syncAll({
    MachineManagerService? machineManager,
    BridgeService? bridgeService,
  }) async {
    final targets = <PromptHistorySyncTarget>[];
    final seen = <String>{};
    void addTarget(PromptHistorySyncTarget target) {
      final key = target.bridgeId.isNotEmpty
          ? target.bridgeId
          : target.bridgeUrl;
      if (seen.add(key)) {
        targets.add(target);
      }
    }

    final currentUrl = bridgeService?.lastUrl;
    final currentBridgeId = bridgeIdForUrl(currentUrl);
    if (currentUrl != null && currentBridgeId != null) {
      addTarget(
        PromptHistorySyncTarget(
          bridgeId: currentBridgeId,
          bridgeUrl: currentUrl,
          bridgeName: currentBridgeId,
        ),
      );
    }

    if (machineManager != null) {
      for (final item in machineManager.machinesWithStatus) {
        if (item.status != MachineStatus.online) continue;
        final bridgeUrl = await machineManager.buildWsUrl(item.machine.id);
        addTarget(
          PromptHistorySyncTarget(
            bridgeId: bridgeIdForUrl(bridgeUrl) ?? item.machine.id,
            bridgeUrl: bridgeUrl,
            bridgeName: item.machine.displayName,
          ),
        );
      }
    }

    final currentStatusIds = <String>{};
    for (final target in targets) {
      final statusId = await syncBridge(target);
      if (statusId != null) currentStatusIds.add(statusId);
    }
    if (currentStatusIds.isNotEmpty) {
      await _pruneSyncStatuses(currentStatusIds);
    }
    return getSyncStatuses();
  }

  Future<String?> syncBridge(PromptHistorySyncTarget target) {
    final key = target.bridgeId.isNotEmpty ? target.bridgeId : target.bridgeUrl;
    final inFlight = _bridgeSyncsInFlight[key];
    if (inFlight != null) return inFlight;

    final operation = _performSyncBridge(target);
    _bridgeSyncsInFlight[key] = operation;
    void clearInFlight() {
      if (identical(_bridgeSyncsInFlight[key], operation)) {
        _bridgeSyncsInFlight.remove(key);
      }
    }

    unawaited(
      operation.then<void>(
        (_) => clearInFlight(),
        onError: (Object _, StackTrace _) => clearInFlight(),
      ),
    );
    return operation;
  }

  Future<String?> _performSyncBridge(PromptHistorySyncTarget target) async {
    final db = await _db;
    if (db == null) return null;
    final clientId = await clientDeviceId;
    final name = await clientName;
    WebSocketChannel? channel;

    try {
      channel = WebSocketChannel.connect(Uri.parse(target.bridgeUrl));
      channel.sink.add(ClientMessage.clientCapabilities().toJson());
      channel.sink.add(
        ClientMessage.syncPromptHistory(
          clientId: clientId,
          clientName: name,
          includeDeleted: true,
        ).toJson(),
      );

      final result = await channel.stream
          .map((raw) => ServerMessage.fromJson(jsonDecode(raw as String)))
          .where(
            (msg) =>
                msg is PromptHistorySyncResultMessage || msg is ErrorMessage,
          )
          .first
          .timeout(_syncTimeout);

      if (result is PromptHistorySyncResultMessage && result.success) {
        final syncedAt =
            result.syncedAt ?? DateTime.now().toUtc().toIso8601String();
        final canonicalBridgeId = result.bridgeInstanceId ?? target.bridgeId;
        await _rememberBridgeAlias(
          aliasBridgeId: target.bridgeId,
          canonicalBridgeId: canonicalBridgeId,
        );
        await _upsertCacheEntries(
          bridgeId: canonicalBridgeId,
          aliasBridgeIds: [target.bridgeId],
          bridgeUrl: _redactBridgeUrl(target.bridgeUrl),
          bridgeName: target.bridgeName,
          revision: result.revision ?? 0,
          syncedAt: syncedAt,
          entries: result.entries,
        );
        await _upsertSyncStatus(
          bridgeId: canonicalBridgeId,
          aliasBridgeIds: [target.bridgeId],
          bridgeUrl: _redactBridgeUrl(target.bridgeUrl),
          bridgeName: target.bridgeName,
          lastSyncAt: syncedAt,
          revision: result.revision ?? 0,
          entryCount: result.entries
              .where((entry) => entry.deletedAt == null)
              .length,
        );
        return canonicalBridgeId;
      } else {
        final error = result is ErrorMessage
            ? result.message
            : (result as PromptHistorySyncResultMessage).error;
        await _upsertSyncStatus(
          bridgeId: target.bridgeId,
          bridgeUrl: _redactBridgeUrl(target.bridgeUrl),
          bridgeName: target.bridgeName,
          error: error ?? 'Sync failed',
        );
        return target.bridgeId;
      }
    } catch (e) {
      await _upsertSyncStatus(
        bridgeId: target.bridgeId,
        bridgeUrl: _redactBridgeUrl(target.bridgeUrl),
        bridgeName: target.bridgeName,
        error: '$e',
      );
      return target.bridgeId;
    } finally {
      unawaited(channel?.sink.close());
    }
  }

  Future<List<PromptHistorySyncStatus>> getSyncStatuses() async {
    final db = await _db;
    if (db == null) return const [];
    final rows = await db.query(
      'prompt_history_sync_status',
      orderBy: 'last_sync_at DESC',
    );
    return rows.map(_statusFromRow).toList();
  }

  // ---------------------------------------------------------------------------
  // Querying
  // ---------------------------------------------------------------------------

  Future<List<PromptHistoryEntry>> getPrompts({
    PromptSortOrder sort = PromptSortOrder.recency,
    String? projectPath,
    PromptHistoryFilters filters = const PromptHistoryFilters(),
    String? currentSessionId,
    String? currentProjectPath,
    String? currentBridgeId,
    int limit = 30,
    int offset = 0,
  }) async {
    final db = await _db;
    if (db == null) return const [];

    final rows = await db.query('prompt_history_cache');
    if (rows.isEmpty) {
      return _getLegacyPrompts(
        sort: sort,
        projectPath: projectPath,
        limit: limit,
        offset: offset,
      );
    }

    final clientId = await clientDeviceId;
    final filtered = <PromptHistoryEntry>[];
    for (final row in rows) {
      if (row['deleted_at'] != null) continue;
      final entry = _entryFromCacheRow(row);
      if (!matchesFilters(
        entry,
        projectPath: projectPath,
        filters: filters,
        clientId: clientId,
        currentProjectPath: currentProjectPath,
        currentBridgeId: currentBridgeId,
      )) {
        continue;
      }
      filtered.add(entry);
    }

    final entries = mergeEntriesForDisplay(filtered, sort: sort);
    return entries.skip(offset).take(limit).toList();
  }

  static List<PromptHistoryEntry> mergeEntriesForDisplay(
    Iterable<PromptHistoryEntry> entries, {
    PromptSortOrder sort = PromptSortOrder.recency,
  }) {
    final merged = <String, PromptHistoryEntry>{};
    for (final entry in entries) {
      final key = _displayMergeKey(entry.text);
      final current = merged[key];
      if (current == null) {
        merged[key] = entry;
        continue;
      }
      merged[key] = current.lastUsedAt.isAfter(entry.lastUsedAt)
          ? current.merge(entry)
          : entry.merge(current);
    }
    return merged.values.toList()..sort(_sorter(sort));
  }

  static bool matchesFilters(
    PromptHistoryEntry entry, {
    String? projectPath,
    PromptHistoryFilters filters = const PromptHistoryFilters(),
    required String clientId,
    String? currentProjectPath,
    String? currentBridgeId,
  }) {
    if (projectPath != null && entry.projectPath != projectPath) return false;
    if (filters.currentProjectOnly &&
        (currentProjectPath == null ||
            currentProjectPath.trim().isEmpty ||
            entry.projectPath.trim().isEmpty ||
            entry.projectPath != currentProjectPath)) {
      return false;
    }
    if (filters.currentBridgeOnly &&
        (currentBridgeId == null ||
            !entry.bridgeIds.contains(currentBridgeId))) {
      return false;
    }
    if (filters.selfOnly && !entry.clientStats.containsKey(clientId)) {
      return false;
    }
    if (filters.favoritesOnly && !entry.isFavorite) return false;
    if (filters.commandsOnly && entry.commandKind == 'none') return false;
    return true;
  }

  Future<List<String>> getProjectPaths() async {
    final db = await _db;
    if (db == null) return const [];
    final cacheRows = await db.rawQuery(
      "SELECT DISTINCT project_path FROM prompt_history_cache WHERE project_path != '' ORDER BY project_path",
    );
    if (cacheRows.isNotEmpty) {
      return cacheRows.map((r) => r['project_path'] as String).toList();
    }

    final rows = await db.rawQuery(
      "SELECT DISTINCT project_path FROM prompt_history WHERE project_path != '' ORDER BY project_path",
    );
    return rows.map((r) => r['project_path'] as String).toList();
  }

  Future<bool> hasLegacyHistory() async {
    final db = await _db;
    if (db == null) return false;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS count FROM prompt_history',
    );
    return (rows.first['count'] as int? ?? 0) > 0;
  }

  Future<List<PromptHistoryServerEntry>> legacyEntriesForImport() async {
    final db = await _db;
    if (db == null) return const [];
    final rows = await db.query('prompt_history');
    return rows.map((row) {
      final text = row['text'] as String;
      final projectPath = row['project_path'] as String? ?? '';
      final createdAt = _millisToIso(row['created_at'] as int?);
      final lastUsedAt = _millisToIso(row['last_used_at'] as int?);
      return PromptHistoryServerEntry(
        id: _stableId(text, projectPath),
        text: text,
        projectPath: projectPath,
        totalUseCount: row['use_count'] as int? ?? 1,
        isFavorite: (row['is_favorite'] as int? ?? 0) == 1,
        createdAt: createdAt,
        lastUsedAt: lastUsedAt,
        updatedAt: lastUsedAt,
        favoriteUpdatedAt: (row['is_favorite'] as int? ?? 0) == 1
            ? lastUsedAt
            : null,
        commandKind: _detectCommandKind(text),
        clientStats: const {},
        sessionStats: const {},
      );
    }).toList();
  }

  // ---------------------------------------------------------------------------
  // Mutations
  // ---------------------------------------------------------------------------

  Future<bool> toggleFavorite(
    String id, {
    List<PromptHistorySource> sources = const [],
    BridgeService? bridgeService,
  }) async {
    if (id.startsWith('v1_')) {
      return _toggleLegacyFavorite(int.parse(id.substring(3)));
    }
    final sourceWhere = _sourceWhereClause(id, sources);
    final mutation = await _serializeCacheMutation(() async {
      final db = await _db;
      if (db == null) return null;
      final rows = await db.query(
        'prompt_history_cache',
        where: '${sourceWhere.where} AND deleted_at IS NULL',
        whereArgs: sourceWhere.args,
      );
      if (rows.isEmpty) return null;

      final newValue = !rows.any(
        (row) => (row['is_favorite'] as int? ?? 0) == 1,
      );
      final now = DateTime.now().toUtc().toIso8601String();
      await db.update(
        'prompt_history_cache',
        {
          'is_favorite': newValue ? 1 : 0,
          'favorite_updated_at': now,
          'updated_at': now,
        },
        where: sourceWhere.where,
        whereArgs: sourceWhere.args,
      );
      await _markPendingRows(db, rows, now);
      return (value: newValue, updatedAt: now);
    });
    if (mutation == null) return false;
    for (final mutationId in _mutationIdsForConnectedBridge(
      id,
      sources,
      bridgeService,
    )) {
      bridgeService?.send(
        ClientMessage.mutatePromptHistory(
          id: mutationId,
          action: 'favorite',
          isFavorite: mutation.value,
          updatedAt: mutation.updatedAt,
        ),
      );
    }
    return mutation.value;
  }

  Future<void> delete(
    String id, {
    List<PromptHistorySource> sources = const [],
    BridgeService? bridgeService,
  }) async {
    if (id.startsWith('v1_')) {
      await _deleteLegacy(int.parse(id.substring(3)));
      return;
    }
    final now = DateTime.now().toUtc().toIso8601String();
    final sourceWhere = _sourceWhereClause(id, sources);
    final cacheAvailable = await _serializeCacheMutation(() async {
      final db = await _db;
      if (db == null) return false;
      final rows = await db.query(
        'prompt_history_cache',
        columns: ['id', 'bridge_id'],
        where: sourceWhere.where,
        whereArgs: sourceWhere.args,
      );
      await db.update(
        'prompt_history_cache',
        {'deleted_at': now, 'updated_at': now},
        where: sourceWhere.where,
        whereArgs: sourceWhere.args,
      );
      await _markPendingRows(db, rows, now);
      return true;
    });
    if (!cacheAvailable) return;
    for (final mutationId in _mutationIdsForConnectedBridge(
      id,
      sources,
      bridgeService,
    )) {
      bridgeService?.send(
        ClientMessage.mutatePromptHistory(
          id: mutationId,
          action: 'delete',
          updatedAt: now,
        ),
      );
    }
  }

  Future<bool> importLegacyToCurrentBridge({
    required BridgeService bridgeService,
  }) async {
    final entries = await legacyEntriesForImport();
    if (entries.isEmpty || !bridgeService.isConnected) return false;
    final bridgeUrl = bridgeService.lastUrl;
    final bridgeId =
        bridgeService.promptHistoryBridgeId ?? bridgeIdForUrl(bridgeUrl);
    final resultFuture = bridgeService.promptHistorySyncResults.first.timeout(
      _syncTimeout,
    );
    bridgeService.send(
      ClientMessage.importPromptHistoryV1(
        clientId: await clientDeviceId,
        clientName: await clientName,
        entries: entries,
      ),
    );
    try {
      final result = await resultFuture;
      if (result.success && bridgeUrl != null && bridgeId != null) {
        final syncedAt =
            result.syncedAt ?? DateTime.now().toUtc().toIso8601String();
        final canonicalBridgeId = result.bridgeInstanceId ?? bridgeId;
        await _rememberBridgeAlias(
          aliasBridgeId: bridgeId,
          canonicalBridgeId: canonicalBridgeId,
        );
        await _upsertCacheEntries(
          bridgeId: canonicalBridgeId,
          aliasBridgeIds: [bridgeId],
          bridgeUrl: _redactBridgeUrl(bridgeUrl),
          bridgeName: canonicalBridgeId,
          revision: result.revision ?? 0,
          syncedAt: syncedAt,
          entries: result.entries,
        );
        await _upsertSyncStatus(
          bridgeId: canonicalBridgeId,
          aliasBridgeIds: [bridgeId],
          bridgeUrl: _redactBridgeUrl(bridgeUrl),
          bridgeName: canonicalBridgeId,
          lastSyncAt: syncedAt,
          revision: result.revision ?? 0,
          entryCount: result.entries
              .where((entry) => entry.deletedAt == null)
              .length,
        );
        return true;
      }
    } catch (e) {
      logger.warning('[PromptHistory] import result wait failed', e);
    }
    return false;
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  bool _shouldRecord(String text) =>
      text.isNotEmpty && text.length >= 5 && text.length <= 2000;

  Future<void> _recordPromptV1(String text, {String projectPath = ''}) async {
    final db = await _db;
    if (db == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final updated = await db.rawUpdate(
      '''
      UPDATE prompt_history
      SET use_count = use_count + 1, last_used_at = ?
      WHERE text = ? AND project_path = ?
      ''',
      [now, text, projectPath],
    );
    if (updated == 0) {
      try {
        await db.insert('prompt_history', {
          'text': text,
          'project_path': projectPath,
          'use_count': 1,
          'is_favorite': 0,
          'created_at': now,
          'last_used_at': now,
        });
      } catch (e) {
        logger.warning('[PromptHistory] v1 insert conflict, updating', e);
        await db.rawUpdate(
          '''
          UPDATE prompt_history
          SET use_count = use_count + 1, last_used_at = ?
          WHERE text = ? AND project_path = ?
          ''',
          [now, text, projectPath],
        );
      }
    }
  }

  Future<List<PromptHistoryEntry>> _getLegacyPrompts({
    required PromptSortOrder sort,
    String? projectPath,
    required int limit,
    required int offset,
  }) async {
    final db = await _db;
    if (db == null) return const [];
    final where = <String>[];
    final args = <dynamic>[];
    if (projectPath != null) {
      where.add('project_path = ?');
      args.add(projectPath);
    }
    final whereClause = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';
    final orderBy = switch (sort) {
      PromptSortOrder.recency => 'last_used_at DESC',
      PromptSortOrder.frequency => 'use_count DESC, last_used_at DESC',
      PromptSortOrder.favoritesFirst => 'is_favorite DESC, last_used_at DESC',
    };
    final rows = await db.rawQuery(
      'SELECT * FROM prompt_history $whereClause ORDER BY $orderBy LIMIT ? OFFSET ?',
      [...args, limit, offset],
    );
    return rows.map(_legacyEntryFromRow).toList();
  }

  Future<bool> _toggleLegacyFavorite(int id) async {
    final db = await _db;
    if (db == null) return false;
    final rows = await db.query(
      'prompt_history',
      columns: ['is_favorite'],
      where: 'id = ?',
      whereArgs: [id],
    );
    if (rows.isEmpty) return false;
    final current = (rows.first['is_favorite'] as int) == 1;
    await db.update(
      'prompt_history',
      {'is_favorite': current ? 0 : 1},
      where: 'id = ?',
      whereArgs: [id],
    );
    return !current;
  }

  Future<void> _deleteLegacy(int id) async {
    final db = await _db;
    if (db == null) return;
    await db.delete('prompt_history', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> _recordCacheUse({
    required String bridgeId,
    required String bridgeUrl,
    required String bridgeName,
    required String text,
    required String projectPath,
    required String clientId,
    required String clientName,
    required String usedAt,
    String? sessionId,
  }) {
    return _serializeCacheMutation(
      () => _recordCacheUseLocked(
        bridgeId: bridgeId,
        bridgeUrl: bridgeUrl,
        bridgeName: bridgeName,
        text: text,
        projectPath: projectPath,
        clientId: clientId,
        clientName: clientName,
        usedAt: usedAt,
        sessionId: sessionId,
      ),
    );
  }

  Future<void> _recordCacheUseLocked({
    required String bridgeId,
    required String bridgeUrl,
    required String bridgeName,
    required String text,
    required String projectPath,
    required String clientId,
    required String clientName,
    required String usedAt,
    String? sessionId,
  }) async {
    final db = await _db;
    if (db == null) return;
    final id = _stableId(text, projectPath);
    final rows = await db.query(
      'prompt_history_cache',
      where: 'id = ? AND bridge_id = ?',
      whereArgs: [id, bridgeId],
      limit: 1,
    );

    if (rows.isEmpty) {
      final entry = PromptHistoryServerEntry(
        id: id,
        text: text,
        projectPath: projectPath,
        totalUseCount: 1,
        isFavorite: false,
        createdAt: usedAt,
        lastUsedAt: usedAt,
        updatedAt: usedAt,
        commandKind: _detectCommandKind(text),
        clientStats: {
          clientId: PromptHistoryClientStat(
            useCount: 1,
            lastUsedAt: usedAt,
            clientName: clientName,
          ),
        },
        sessionStats: sessionId == null
            ? const {}
            : {
                sessionId: PromptHistorySessionStat(
                  useCount: 1,
                  lastUsedAt: usedAt,
                ),
              },
      );
      await db.insert(
        'prompt_history_cache',
        _cacheRowForServerEntry(
          entry,
          bridgeId: bridgeId,
          bridgeUrl: bridgeUrl,
          bridgeName: bridgeName,
          revision: 0,
          syncedAt: usedAt,
        ),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await _markPendingLocal(db, id, bridgeId, usedAt);
      return;
    }

    final row = rows.first;
    final clients = _decodeClientStats(row['client_stats_json'] as String?);
    final currentClient = clients[clientId];
    clients[clientId] = PromptHistoryClientStat(
      useCount: (currentClient?.useCount ?? 0) + 1,
      lastUsedAt: _maxIso(currentClient?.lastUsedAt ?? usedAt, usedAt),
      clientName: clientName,
    );

    final sessions = _decodeSessionStats(row['session_stats_json'] as String?);
    if (sessionId != null) {
      final currentSession = sessions[sessionId];
      sessions[sessionId] = PromptHistorySessionStat(
        useCount: (currentSession?.useCount ?? 0) + 1,
        lastUsedAt: _maxIso(currentSession?.lastUsedAt ?? usedAt, usedAt),
      );
    }

    await db.update(
      'prompt_history_cache',
      {
        'total_use_count': (row['total_use_count'] as int? ?? 0) + 1,
        'last_used_at': _maxIso(
          row['last_used_at'] as String? ?? usedAt,
          usedAt,
        ),
        'updated_at': _maxIso(row['updated_at'] as String? ?? usedAt, usedAt),
        'deleted_at': null,
        'client_stats_json': jsonEncode(
          clients.map((key, value) => MapEntry(key, value.toJson())),
        ),
        'session_stats_json': jsonEncode(
          sessions.map((key, value) => MapEntry(key, value.toJson())),
        ),
      },
      where: 'id = ? AND bridge_id = ?',
      whereArgs: [id, bridgeId],
    );
    await _markPendingLocal(db, id, bridgeId, usedAt);
  }

  Future<void> _ensurePendingLocalTable(Database db) {
    return _pendingLocalTableReady ??= _initializePendingLocalTable(db);
  }

  Future<void> _initializePendingLocalTable(Database db) async {
    try {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS prompt_history_pending_local (
          id TEXT NOT NULL,
          bridge_id TEXT NOT NULL,
          pending_local_at TEXT NOT NULL,
          PRIMARY KEY (id, bridge_id)
        )
      ''');
    } catch (_) {
      _pendingLocalTableReady = null;
      rethrow;
    }
  }

  Future<void> _markPendingLocal(
    Database db,
    String id,
    String bridgeId,
    String pendingLocalAt,
  ) async {
    await _ensurePendingLocalTable(db);
    await db.insert('prompt_history_pending_local', {
      'id': id,
      'bridge_id': bridgeId,
      'pending_local_at': pendingLocalAt,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> _markPendingRows(
    Database db,
    Iterable<Map<String, Object?>> rows,
    String pendingLocalAt,
  ) async {
    await _ensurePendingLocalTable(db);
    final batch = db.batch();
    for (final row in rows) {
      final id = row['id'];
      final bridgeId = row['bridge_id'];
      if (id is! String || bridgeId is! String) continue;
      batch.insert(
        'prompt_history_pending_local',
        {'id': id, 'bridge_id': bridgeId, 'pending_local_at': pendingLocalAt},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  String _pendingSourceKey(String id, String bridgeId) => '$bridgeId\u0000$id';

  Future<void> _upsertCacheEntries({
    required String bridgeId,
    List<String> aliasBridgeIds = const [],
    required String bridgeUrl,
    required String bridgeName,
    required int revision,
    required String syncedAt,
    required List<PromptHistoryServerEntry> entries,
  }) {
    return _serializeCacheMutation(
      () => _upsertCacheEntriesLocked(
        bridgeId: bridgeId,
        aliasBridgeIds: aliasBridgeIds,
        bridgeUrl: bridgeUrl,
        bridgeName: bridgeName,
        revision: revision,
        syncedAt: syncedAt,
        entries: entries,
      ),
    );
  }

  Future<void> _upsertCacheEntriesLocked({
    required String bridgeId,
    List<String> aliasBridgeIds = const [],
    required String bridgeUrl,
    required String bridgeName,
    required int revision,
    required String syncedAt,
    required List<PromptHistoryServerEntry> entries,
  }) async {
    final db = await _db;
    if (db == null) return;
    await _ensurePendingLocalTable(db);
    final scopedBridgeIds = {bridgeId, ...aliasBridgeIds};
    final placeholders = List.filled(scopedBridgeIds.length, '?').join(',');
    final existingRows = await db.query(
      'prompt_history_cache',
      where: 'bridge_id IN ($placeholders)',
      whereArgs: scopedBridgeIds.toList(),
    );
    final pendingMarkers = await db.query(
      'prompt_history_pending_local',
      where: 'bridge_id IN ($placeholders)',
      whereArgs: scopedBridgeIds.toList(),
    );
    final pendingBySource = <String, String>{};
    for (final marker in pendingMarkers) {
      final id = marker['id'];
      final sourceBridgeId = marker['bridge_id'];
      final pendingLocalAt = marker['pending_local_at'];
      if (id is String &&
          sourceBridgeId is String &&
          pendingLocalAt is String &&
          pendingLocalAt.isNotEmpty) {
        pendingBySource[_pendingSourceKey(id, sourceBridgeId)] = pendingLocalAt;
      }
    }
    final remoteEntries = {for (final entry in entries) entry.id: entry};
    final pendingRows = <String, _PendingPromptCacheRow>{};
    for (final row in existingRows) {
      final id = row['id'];
      final sourceBridgeId = row['bridge_id'];
      if (id is! String || sourceBridgeId is! String) continue;
      final pendingLocalAt =
          pendingBySource[_pendingSourceKey(id, sourceBridgeId)];
      if (pendingLocalAt == null) continue;
      final remote = remoteEntries[id];
      if (remote != null &&
          _compareIso(remote.updatedAt, pendingLocalAt) >= 0) {
        continue;
      }
      final current = pendingRows[id];
      if (current == null ||
          _compareIso(pendingLocalAt, current.pendingLocalAt) > 0) {
        pendingRows[id] = _PendingPromptCacheRow(
          row: Map<String, Object?>.from(row),
          pendingLocalAt: pendingLocalAt,
        );
      }
    }

    final batch = db.batch();
    for (final id in scopedBridgeIds) {
      batch.delete(
        'prompt_history_cache',
        where: 'bridge_id = ?',
        whereArgs: [id],
      );
      batch.delete(
        'prompt_history_pending_local',
        where: 'bridge_id = ?',
        whereArgs: [id],
      );
    }
    for (final entry in entries) {
      if (pendingRows.containsKey(entry.id)) continue;
      batch.insert(
        'prompt_history_cache',
        _cacheRowForServerEntry(
          entry,
          bridgeId: bridgeId,
          bridgeUrl: bridgeUrl,
          bridgeName: bridgeName,
          revision: revision,
          syncedAt: syncedAt,
        ),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    for (final pending in pendingRows.values) {
      final row = pending.row;
      row
        ..['bridge_id'] = bridgeId
        ..['bridge_url'] = bridgeUrl
        ..['bridge_name'] = bridgeName;
      batch.insert(
        'prompt_history_cache',
        row,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      batch.insert(
        'prompt_history_pending_local',
        {
          'id': row['id'],
          'bridge_id': bridgeId,
          'pending_local_at': pending.pendingLocalAt,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Map<String, Object?> _cacheRowForServerEntry(
    PromptHistoryServerEntry entry, {
    required String bridgeId,
    required String bridgeUrl,
    required String bridgeName,
    required int revision,
    required String syncedAt,
  }) {
    return {
      'id': entry.id,
      'bridge_id': bridgeId,
      'bridge_url': bridgeUrl,
      'bridge_name': bridgeName,
      'text': entry.text,
      'project_path': entry.projectPath,
      'total_use_count': entry.totalUseCount,
      'is_favorite': entry.isFavorite ? 1 : 0,
      'created_at': entry.createdAt,
      'last_used_at': entry.lastUsedAt,
      'updated_at': entry.updatedAt,
      'favorite_updated_at': entry.favoriteUpdatedAt,
      'deleted_at': entry.deletedAt,
      'command_kind': entry.commandKind,
      'client_stats_json': jsonEncode(
        entry.clientStats.map((key, value) => MapEntry(key, value.toJson())),
      ),
      'session_stats_json': jsonEncode(
        entry.sessionStats.map((key, value) => MapEntry(key, value.toJson())),
      ),
      'synced_revision': revision,
      'synced_at': syncedAt,
    };
  }

  @visibleForTesting
  Future<void> replaceCacheSnapshotForTest({
    required String bridgeId,
    required String syncedAt,
    required List<PromptHistoryServerEntry> entries,
  }) {
    return _upsertCacheEntries(
      bridgeId: bridgeId,
      bridgeUrl: 'ws://test.invalid',
      bridgeName: bridgeId,
      revision: 1,
      syncedAt: syncedAt,
      entries: entries,
    );
  }

  @visibleForTesting
  Future<void> recordCacheUseForTest({
    required String bridgeId,
    required String text,
    required String projectPath,
    required String usedAt,
  }) {
    return _recordCacheUse(
      bridgeId: bridgeId,
      bridgeUrl: 'ws://test.invalid',
      bridgeName: bridgeId,
      text: text,
      projectPath: projectPath,
      clientId: 'test-client',
      clientName: 'Test Client',
      usedAt: usedAt,
    );
  }

  Future<void> _upsertSyncStatus({
    required String bridgeId,
    List<String> aliasBridgeIds = const [],
    required String bridgeUrl,
    required String bridgeName,
    String? lastSyncAt,
    int? revision,
    int? entryCount,
    String? error,
  }) async {
    final db = await _db;
    if (db == null) return;
    for (final id in aliasBridgeIds.where((id) => id != bridgeId)) {
      await db.delete(
        'prompt_history_sync_status',
        where: 'bridge_id = ?',
        whereArgs: [id],
      );
    }
    await db.insert('prompt_history_sync_status', {
      'bridge_id': bridgeId,
      'bridge_url': bridgeUrl,
      'bridge_name': bridgeName,
      'last_sync_at': lastSyncAt,
      'revision': revision ?? 0,
      'entry_count': entryCount ?? 0,
      'error': error,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> _pruneSyncStatuses(Set<String> keepBridgeIds) async {
    final db = await _db;
    if (db == null || keepBridgeIds.isEmpty) return;
    final placeholders = List.filled(keepBridgeIds.length, '?').join(',');
    await db.delete(
      'prompt_history_sync_status',
      where: 'bridge_id NOT IN ($placeholders)',
      whereArgs: keepBridgeIds.toList(),
    );
  }

  PromptHistoryEntry _entryFromCacheRow(Map<String, Object?> row) {
    final bridgeName = row['bridge_name'] as String? ?? '';
    return PromptHistoryEntry(
      id: row['id'] as String,
      text: row['text'] as String,
      projectPath: row['project_path'] as String? ?? '',
      useCount: row['total_use_count'] as int? ?? 0,
      isFavorite: (row['is_favorite'] as int? ?? 0) == 1,
      createdAt: _parseIso(row['created_at'] as String?),
      lastUsedAt: _parseIso(row['last_used_at'] as String?),
      updatedAt: _parseIso(row['updated_at'] as String?),
      commandKind: row['command_kind'] as String? ?? 'none',
      bridgeIds: [row['bridge_id'] as String],
      bridgeNames: [if (bridgeName.isNotEmpty) bridgeName],
      clientStats: _decodeClientStats(row['client_stats_json'] as String?),
      sessionStats: _decodeSessionStats(row['session_stats_json'] as String?),
      sources: [
        PromptHistorySource(
          id: row['id'] as String,
          bridgeId: row['bridge_id'] as String,
        ),
      ],
    );
  }

  PromptHistoryEntry _legacyEntryFromRow(Map<String, Object?> row) {
    final text = row['text'] as String;
    final projectPath = row['project_path'] as String? ?? '';
    final createdAt = DateTime.fromMillisecondsSinceEpoch(
      row['created_at'] as int? ?? 0,
    );
    final lastUsedAt = DateTime.fromMillisecondsSinceEpoch(
      row['last_used_at'] as int? ?? 0,
    );
    return PromptHistoryEntry(
      id: 'v1_${row['id']}',
      text: text,
      projectPath: projectPath,
      useCount: row['use_count'] as int? ?? 1,
      isFavorite: (row['is_favorite'] as int? ?? 0) == 1,
      createdAt: createdAt,
      lastUsedAt: lastUsedAt,
      updatedAt: lastUsedAt,
      commandKind: _detectCommandKind(text),
      bridgeIds: const ['local'],
      bridgeNames: const ['Local'],
      clientStats: const {},
      sessionStats: const {},
      sources: [PromptHistorySource(id: 'v1_${row['id']}', bridgeId: 'local')],
    );
  }

  PromptHistorySyncStatus _statusFromRow(Map<String, Object?> row) {
    return PromptHistorySyncStatus(
      bridgeId: row['bridge_id'] as String,
      bridgeUrl: row['bridge_url'] as String? ?? '',
      bridgeName: row['bridge_name'] as String? ?? '',
      lastSyncAt: row['last_sync_at'] == null
          ? null
          : DateTime.tryParse(row['last_sync_at'] as String),
      revision: row['revision'] as int? ?? 0,
      entryCount: row['entry_count'] as int? ?? 0,
      error: row['error'] as String?,
    );
  }

  static int Function(PromptHistoryEntry, PromptHistoryEntry) _sorter(
    PromptSortOrder sort,
  ) {
    return switch (sort) {
      PromptSortOrder.recency => (a, b) => b.lastUsedAt.compareTo(a.lastUsedAt),
      PromptSortOrder.frequency => (a, b) {
        final count = b.useCount.compareTo(a.useCount);
        return count != 0 ? count : b.lastUsedAt.compareTo(a.lastUsedAt);
      },
      PromptSortOrder.favoritesFirst => (a, b) {
        if (a.isFavorite != b.isFavorite) return a.isFavorite ? -1 : 1;
        return b.lastUsedAt.compareTo(a.lastUsedAt);
      },
    };
  }

  Map<String, PromptHistoryClientStat> _decodeClientStats(String? raw) {
    if (raw == null || raw.isEmpty) return const {};
    try {
      return (jsonDecode(raw) as Map<String, dynamic>).map(
        (key, value) => MapEntry(
          key,
          PromptHistoryClientStat.fromJson(value as Map<String, dynamic>),
        ),
      );
    } catch (_) {
      return const {};
    }
  }

  Map<String, PromptHistorySessionStat> _decodeSessionStats(String? raw) {
    if (raw == null || raw.isEmpty) return const {};
    try {
      return (jsonDecode(raw) as Map<String, dynamic>).map(
        (key, value) => MapEntry(
          key,
          PromptHistorySessionStat.fromJson(value as Map<String, dynamic>),
        ),
      );
    } catch (_) {
      return const {};
    }
  }

  static DateTime _parseIso(String? value) =>
      DateTime.tryParse(value ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);

  static String _millisToIso(int? millis) =>
      DateTime.fromMillisecondsSinceEpoch(
        millis ?? 0,
      ).toUtc().toIso8601String();

  static String _redactBridgeUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    return uri.replace(query: '').toString();
  }

  static String _stableId(String text, String projectPath) {
    final stableKey = '${projectPath.trim()}\u0000${text.trim()}';
    return 'ph_${sha256.convert(utf8.encode(stableKey)).toString().substring(0, 24)}';
  }

  static String _detectCommandKind(String text) {
    final trimmed = text.trimLeft();
    if (trimmed.startsWith(r'$')) return 'skill';
    if (trimmed.startsWith('/')) return 'slash';
    return 'none';
  }

  static String _displayMergeKey(String text) {
    return formatCommandText(text).trim().replaceAll(RegExp(r'\s+'), ' ');
  }

  static _SourceWhereClause _sourceWhereClause(
    String fallbackId,
    List<PromptHistorySource> sources,
  ) {
    final cacheSources = sources
        .where((source) => !source.id.startsWith('v1_'))
        .toList();
    if (cacheSources.isEmpty) {
      return _SourceWhereClause('id = ?', [fallbackId]);
    }

    final clauses = <String>[];
    final args = <Object?>[];
    for (final source in cacheSources) {
      if (source.bridgeId.isEmpty) {
        clauses.add('id = ?');
        args.add(source.id);
      } else {
        clauses.add('(id = ? AND bridge_id = ?)');
        args.addAll([source.id, source.bridgeId]);
      }
    }
    return _SourceWhereClause('(${clauses.join(' OR ')})', args);
  }

  Iterable<String> _mutationIdsForConnectedBridge(
    String fallbackId,
    List<PromptHistorySource> sources,
    BridgeService? bridgeService,
  ) {
    if (bridgeService == null) return const [];
    if (sources.isEmpty) return [fallbackId];

    final bridgeUrl = bridgeService.lastUrl;
    final currentBridgeId =
        bridgeService.promptHistoryBridgeId ?? bridgeIdForUrl(bridgeUrl);
    if (currentBridgeId == null) return const [];

    return sources
        .where((source) => source.bridgeId == currentBridgeId)
        .map((source) => source.id)
        .toSet();
  }
}

class _SourceWhereClause {
  final String where;
  final List<Object?> args;

  const _SourceWhereClause(this.where, this.args);
}
