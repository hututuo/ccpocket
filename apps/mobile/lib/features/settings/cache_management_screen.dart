import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/messages.dart';
import '../../models/machine.dart';
import '../../providers/machine_manager_cubit.dart';
import '../conversation_mirror/conversation_mirror_service.dart';
import '../conversation_mirror/storage/conversation_mirror_models.dart';
import '../session_list/cache/session_catalog_cache_repository.dart';
import '../session_list/state/session_list_cubit.dart';
import 'cache_management_strings.dart';

class CacheManagementDataSource {
  const CacheManagementDataSource({
    required this.target,
    required this.displayName,
    required this.codexSourceId,
    required this.routeCount,
    required this.stats,
    required this.conversations,
  });

  final SessionCatalogCacheTarget target;
  final String displayName;
  final String? codexSourceId;
  final int routeCount;
  final SessionCatalogCacheStats stats;
  final List<SessionCatalogCachedConversation> conversations;
}

abstract interface class CacheManagementBackend {
  List<ConversationMirrorMetadata> get localCopies;

  Future<SessionCatalogCacheStats> temporaryCacheStats();

  Future<List<CacheManagementDataSource>> dataSourceCaches();

  Future<Map<ConversationMirrorKey, String>> localCopyDisplayNames();

  Future<void> clearCatalogCache();

  Future<void> clearDataSource(CacheManagementDataSource dataSource);

  Future<void> removeCachedConversation(
    CacheManagementDataSource dataSource,
    SessionCatalogCachedConversation conversation,
  );

  Future<void> removeLocalCopy(ConversationMirrorMetadata metadata);

  void addListener(VoidCallback listener);

  void removeListener(VoidCallback listener);
}

class _AppCacheManagementBackend implements CacheManagementBackend {
  _AppCacheManagementBackend({
    required this.catalogCache,
    required this.sessionListCubit,
    required this.conversationMirror,
    required this.machineManager,
  });

  final SessionCatalogCacheRepository? catalogCache;
  final SessionListCubit? sessionListCubit;
  final ConversationMirrorService? conversationMirror;
  final MachineManagerCubit? machineManager;

  @override
  List<ConversationMirrorMetadata> get localCopies =>
      conversationMirror?.localCopyMetadata ?? const [];

  @override
  Future<SessionCatalogCacheStats> temporaryCacheStats() =>
      catalogCache?.cacheStats() ??
      Future<SessionCatalogCacheStats>.value(
        const SessionCatalogCacheStats.empty(),
      );

  @override
  Future<List<CacheManagementDataSource>> dataSourceCaches() async {
    final cache = catalogCache;
    if (cache == null) return const [];
    final groups =
        <String, ({SessionCatalogCacheTarget target, List<Machine> routes})>{};
    for (final machineWithStatus
        in machineManager?.state.machines ?? const []) {
      final machine = machineWithStatus.machine;
      final target = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: machine.bridgeInstanceId,
        codexSourceId: machine.codexSourceId,
        websocketUrl: machine.wsUrl,
      );
      if (!target.isValid) continue;
      final existing = groups[target.fingerprint];
      if (existing == null) {
        groups[target.fingerprint] = (target: target, routes: [machine]);
      } else {
        existing.routes.add(machine);
      }
    }
    final result = <CacheManagementDataSource>[];
    for (final group in groups.values) {
      group.routes.sort(
        (left, right) =>
            (right.lastConnected ?? DateTime.fromMillisecondsSinceEpoch(0))
                .compareTo(
                  left.lastConnected ?? DateTime.fromMillisecondsSinceEpoch(0),
                ),
      );
      final namedRoutes = group.routes
          .where((route) => route.name?.trim().isNotEmpty == true)
          .toList(growable: false);
      final preferred = namedRoutes.isEmpty
          ? group.routes.first
          : namedRoutes.first;
      result.add(
        CacheManagementDataSource(
          target: group.target,
          displayName: preferred.displayName,
          codexSourceId: preferred.codexSourceId,
          routeCount: group.routes.length,
          stats: await cache.cacheStatsForTarget(group.target),
          conversations: await cache.cachedConversations(group.target),
        ),
      );
    }
    result.sort((left, right) => left.displayName.compareTo(right.displayName));
    return List.unmodifiable(result);
  }

  @override
  Future<Map<ConversationMirrorKey, String>> localCopyDisplayNames() async {
    final cache = catalogCache;
    final copies = localCopies;
    final identities = <ConversationMirrorKey, SessionCatalogCacheIdentity>{
      for (final metadata in copies)
        metadata.key: SessionCatalogCacheIdentity(
          bridgeInstanceId: metadata.key.bridgeInstanceId,
          provider: metadata.key.provider,
          providerSessionId: metadata.key.providerSessionId,
          codexSourceId: metadata.key.codexSourceId,
        ),
    };
    final sessions = cache == null
        ? const <SessionCatalogCacheIdentity, RecentSession>{}
        : await cache.findSessionsByIdentities(identities.values);
    final result = <ConversationMirrorKey, String>{};
    for (final metadata in copies) {
      final session = sessions[identities[metadata.key]];
      final displayName = _catalogDisplayName(session);
      final resolved = displayName ?? metadata.storedDisplayName;
      if (resolved != null) result[metadata.key] = resolved;
    }
    return Map.unmodifiable(result);
  }

  @override
  Future<void> clearCatalogCache() {
    final cubit = sessionListCubit;
    if (cubit != null) return cubit.clearPersistentCatalogCache();
    return catalogCache?.clearAll() ?? Future<void>.value();
  }

  @override
  Future<void> clearDataSource(CacheManagementDataSource dataSource) {
    final cubit = sessionListCubit;
    if (cubit != null) {
      return cubit.clearPersistentCatalogCacheForTarget(dataSource.target);
    }
    return catalogCache?.clearTarget(dataSource.target) ?? Future<void>.value();
  }

  @override
  Future<void> removeCachedConversation(
    CacheManagementDataSource dataSource,
    SessionCatalogCachedConversation conversation,
  ) =>
      catalogCache?.deleteConversationWindow(
        target: dataSource.target,
        provider: conversation.provider,
        providerSessionId: conversation.providerSessionId,
      ) ??
      Future<void>.value();

  @override
  Future<void> removeLocalCopy(ConversationMirrorMetadata metadata) =>
      conversationMirror?.removeLocalCopyByKey(metadata.key) ??
      Future<void>.value();

  @override
  void addListener(VoidCallback listener) {
    conversationMirror?.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    conversationMirror?.removeListener(listener);
  }
}

class CacheManagementSettingsTile extends StatelessWidget {
  const CacheManagementSettingsTile({super.key});

  @override
  Widget build(BuildContext context) {
    final strings = CacheManagementStrings.of(context);
    final mirror = context.watch<ConversationMirrorService?>();
    final localCopies = mirror?.localCopyMetadata.length ?? 0;
    return ListTile(
      key: const ValueKey('cache_management_settings_tile'),
      leading: Icon(
        Icons.storage_outlined,
        color: Theme.of(context).colorScheme.primary,
      ),
      title: Text(strings.title),
      subtitle: Text(strings.summary(localCopies)),
      trailing: const Icon(Icons.chevron_right, size: 20),
      onTap: () => Navigator.of(context).push<void>(
        MaterialPageRoute(builder: (_) => const CacheManagementScreen()),
      ),
    );
  }
}

class CacheManagementScreen extends StatefulWidget {
  const CacheManagementScreen({super.key, this.backend});

  final CacheManagementBackend? backend;

  @override
  State<CacheManagementScreen> createState() => _CacheManagementScreenState();
}

class _CacheManagementScreenState extends State<CacheManagementScreen> {
  CacheManagementBackend? _backend;
  SessionCatalogCacheStats _cacheStats = const SessionCatalogCacheStats.empty();
  Map<ConversationMirrorKey, String> _localCopyDisplayNames = const {};
  List<CacheManagementDataSource> _dataSources = const [];
  int _loadGeneration = 0;
  bool _isLoadingCacheStats = true;
  bool _isClearingCatalog = false;
  final Set<String> _clearingDataSources = {};
  final Set<String> _removingCachedConversations = {};
  final Set<ConversationMirrorKey> _removingCopies = {};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_backend != null) return;
    _backend =
        widget.backend ??
        _AppCacheManagementBackend(
          catalogCache: context.read<SessionCatalogCacheRepository?>(),
          sessionListCubit: context.read<SessionListCubit?>(),
          conversationMirror: context.read<ConversationMirrorService?>(),
          machineManager: context.read<MachineManagerCubit?>(),
        );
    _backend!.addListener(_handleBackendChange);
    unawaited(_reloadCacheState());
  }

  void _handleBackendChange() {
    if (mounted) setState(() {});
    unawaited(_reloadCacheState());
  }

  Future<void> _reloadCacheState() async {
    final generation = ++_loadGeneration;
    try {
      final stats = await _backend!.temporaryCacheStats();
      final displayNames = await _backend!.localCopyDisplayNames();
      final dataSources = await _backend!.dataSourceCaches();
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _cacheStats = stats;
        _localCopyDisplayNames = displayNames;
        _dataSources = dataSources;
        _isLoadingCacheStats = false;
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() => _isLoadingCacheStats = false);
      _showError(error);
    }
  }

  Future<void> _clearDataSource(CacheManagementDataSource dataSource) async {
    final key = dataSource.target.fingerprint;
    if (_clearingDataSources.contains(key)) return;
    setState(() => _clearingDataSources.add(key));
    try {
      await _backend!.clearDataSource(dataSource);
      await _reloadCacheState();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            CacheManagementStrings.of(
              context,
            ).dataSourceCleared(dataSource.displayName),
          ),
        ),
      );
    } catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _clearingDataSources.remove(key));
    }
  }

  Future<void> _confirmRemoveCachedConversation(
    CacheManagementDataSource dataSource,
    SessionCatalogCachedConversation conversation,
  ) async {
    final strings = CacheManagementStrings.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(strings.removeRecentWindow),
        content: Text(strings.removeRecentWindowWarning),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.cancel),
          ),
          FilledButton(
            key: const ValueKey('confirm_remove_cached_conversation'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(strings.removeRecentWindow),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final key =
        '${dataSource.target.fingerprint}\n${conversation.provider}\n'
        '${conversation.providerSessionId}';
    setState(() => _removingCachedConversations.add(key));
    try {
      await _backend!.removeCachedConversation(dataSource, conversation);
      await _reloadCacheState();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(strings.recentWindowRemoved)));
    } catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _removingCachedConversations.remove(key));
    }
  }

  Future<void> _clearCatalogCache() async {
    if (_isClearingCatalog) return;
    setState(() => _isClearingCatalog = true);
    try {
      await _backend!.clearCatalogCache();
      await _reloadCacheState();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(CacheManagementStrings.of(context).cacheCleared),
        ),
      );
    } catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _isClearingCatalog = false);
    }
  }

  Future<void> _confirmRemoveCopy(ConversationMirrorMetadata metadata) async {
    final strings = CacheManagementStrings.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(strings.removeCopy),
        content: Text(strings.removeCopyWarning),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.cancel),
          ),
          FilledButton(
            key: const ValueKey('confirm_remove_downloaded_history'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(strings.removeCopy),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _removingCopies.add(metadata.key));
    try {
      await _backend!.removeLocalCopy(metadata);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(strings.removed)));
    } catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _removingCopies.remove(metadata.key));
    }
  }

  void _showError(Object error) {
    if (!mounted) return;
    final strings = CacheManagementStrings.of(context);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(strings.failed('$error'))));
  }

  @override
  void dispose() {
    _loadGeneration++;
    _backend?.removeListener(_handleBackendChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = CacheManagementStrings.of(context);
    final copies = _backend?.localCopies ?? const [];
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(strings.title)),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _CacheSectionHeader(strings.temporaryCacheSection),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            child: ListTile(
              key: const ValueKey('clear_session_catalog_cache_tile'),
              leading: _isLoadingCacheStats
                  ? const SizedBox.square(
                      dimension: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(Icons.list_alt_outlined, color: cs.primary),
              title: Text(strings.catalogCacheTitle),
              subtitle: Text(
                strings.catalogCacheSubtitle(
                  summaries: _cacheStats.sessionSummaries,
                  windows: _cacheStats.conversationWindows,
                ),
              ),
              trailing: _isClearingCatalog
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : TextButton(
                      key: const ValueKey('clear_session_catalog_cache_button'),
                      onPressed: _clearCatalogCache,
                      child: Text(strings.clear),
                    ),
            ),
          ),
          if (_dataSources.isNotEmpty) ...[
            _CacheSectionHeader(strings.byDataSourceSection),
            for (final dataSource in _dataSources)
              _DataSourceCacheCard(
                dataSource: dataSource,
                isClearing: _clearingDataSources.contains(
                  dataSource.target.fingerprint,
                ),
                removingConversationKeys: _removingCachedConversations,
                onClear: () => _clearDataSource(dataSource),
                onRemoveConversation: (conversation) =>
                    _confirmRemoveCachedConversation(dataSource, conversation),
              ),
          ],
          _CacheSectionHeader(strings.downloadedSection),
          if (copies.isEmpty)
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  strings.noDownloadedHistories,
                  style: TextStyle(color: cs.onSurfaceVariant),
                ),
              ),
            )
          else
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: [
                  for (var index = 0; index < copies.length; index++) ...[
                    _DownloadedHistoryTile(
                      metadata: copies[index],
                      displayName: _localCopyDisplayNames[copies[index].key],
                      isRemoving: _removingCopies.contains(copies[index].key),
                      onRemove: () => _confirmRemoveCopy(copies[index]),
                    ),
                    if (index != copies.length - 1)
                      const Divider(height: 1, indent: 16, endIndent: 16),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _DataSourceCacheCard extends StatelessWidget {
  const _DataSourceCacheCard({
    required this.dataSource,
    required this.isClearing,
    required this.removingConversationKeys,
    required this.onClear,
    required this.onRemoveConversation,
  });

  final CacheManagementDataSource dataSource;
  final bool isClearing;
  final Set<String> removingConversationKeys;
  final VoidCallback onClear;
  final ValueChanged<SessionCatalogCachedConversation> onRemoveConversation;

  @override
  Widget build(BuildContext context) {
    final strings = CacheManagementStrings.of(context);
    final source = dataSource.codexSourceId;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: ExpansionTile(
        key: ValueKey('cache_data_source_${dataSource.target.fingerprint}'),
        leading: const Icon(Icons.computer_outlined),
        title: Text(
          dataSource.displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          strings.dataSourceSubtitle(
            routes: dataSource.routeCount,
            source: source == null ? null : _shortIdentity(source),
            summaries: dataSource.stats.sessionSummaries,
            windows: dataSource.stats.conversationWindows,
          ),
        ),
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextButton.icon(
                key: ValueKey(
                  'clear_cache_data_source_${dataSource.target.fingerprint}',
                ),
                onPressed: isClearing ? null : onClear,
                icon: isClearing
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.cleaning_services_outlined),
                label: Text(strings.clearThisDataSource),
              ),
            ),
          ),
          if (dataSource.conversations.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(strings.noRecentWindows),
              ),
            )
          else
            for (final conversation in dataSource.conversations)
              _CachedConversationTile(
                dataSource: dataSource,
                conversation: conversation,
                isRemoving: removingConversationKeys.contains(
                  '${dataSource.target.fingerprint}\n'
                  '${conversation.provider}\n'
                  '${conversation.providerSessionId}',
                ),
                onRemove: () => onRemoveConversation(conversation),
              ),
        ],
      ),
    );
  }
}

class _CachedConversationTile extends StatelessWidget {
  const _CachedConversationTile({
    required this.dataSource,
    required this.conversation,
    required this.isRemoving,
    required this.onRemove,
  });

  final CacheManagementDataSource dataSource;
  final SessionCatalogCachedConversation conversation;
  final bool isRemoving;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final strings = CacheManagementStrings.of(context);
    final title =
        _catalogDisplayName(conversation.session) ??
        _shortIdentity(conversation.providerSessionId);
    return ListTile(
      key: ValueKey(
        'cached_conversation_${dataSource.target.fingerprint}_'
        '${conversation.provider}_${conversation.providerSessionId}',
      ),
      dense: true,
      leading: const Icon(Icons.forum_outlined, size: 20),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        strings.recentWindowSubtitle(
          entries: conversation.entryCount,
          updatedAt: conversation.updatedAt.toLocal(),
        ),
      ),
      trailing: isRemoving
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : IconButton(
              tooltip: strings.removeRecentWindow,
              onPressed: onRemove,
              icon: const Icon(Icons.delete_outline),
            ),
    );
  }
}

String _shortIdentity(String value) {
  final normalized = value.trim();
  return normalized.length <= 12
      ? normalized
      : '${normalized.substring(0, 6)}…${normalized.substring(normalized.length - 4)}';
}

class _DownloadedHistoryTile extends StatelessWidget {
  const _DownloadedHistoryTile({
    required this.metadata,
    required this.displayName,
    required this.isRemoving,
    required this.onRemove,
  });

  final ConversationMirrorMetadata metadata;
  final String? displayName;
  final bool isRemoving;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final strings = CacheManagementStrings.of(context);
    final title = displayName ?? _fallbackDisplayName(metadata);
    return ListTile(
      key: ValueKey(
        'downloaded_history_${metadata.key.bridgeInstanceId}_'
        '${metadata.key.providerSessionId}',
      ),
      leading: Icon(
        metadata.autoSync ? Icons.offline_pin : Icons.download_done_outlined,
        color: Theme.of(context).colorScheme.primary,
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        strings.downloadedSubtitle(
          entries: metadata.entryCount,
          bytes: _formatBytes(metadata.bytes),
          resident: metadata.autoSync,
        ),
      ),
      trailing: isRemoving
          ? const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : IconButton(
              key: ValueKey(
                'remove_downloaded_history_${metadata.key.bridgeInstanceId}_'
                '${metadata.key.providerSessionId}',
              ),
              tooltip: strings.removeCopy,
              onPressed: onRemove,
              icon: const Icon(Icons.delete_outline),
            ),
    );
  }

  static String _fallbackDisplayName(ConversationMirrorMetadata metadata) {
    final normalized = metadata.projectPath.trim().replaceAll('\\', '/');
    final parts = normalized
        .split('/')
        .where((part) => part.isNotEmpty)
        .toList(growable: false);
    final project = parts.isEmpty ? null : parts.last;
    if (project != null && project.isNotEmpty) return project;
    final id = metadata.key.providerSessionId;
    return id.length <= 16 ? id : '${id.substring(0, 16)}…';
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kib = bytes / 1024;
    if (kib < 1024) return '${kib.toStringAsFixed(kib < 10 ? 1 : 0)} KB';
    final mib = kib / 1024;
    return '${mib.toStringAsFixed(mib < 10 ? 1 : 0)} MB';
  }
}

String? _catalogDisplayName(RecentSession? session) {
  if (session == null) return null;
  for (final value in [session.name, session.summary, session.firstPrompt]) {
    final normalized = value?.trim();
    if (normalized != null && normalized.isNotEmpty) return normalized;
  }
  return null;
}

class _CacheSectionHeader extends StatelessWidget {
  const _CacheSectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 24, 16, 8),
    child: Text(
      title,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        color: Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}
