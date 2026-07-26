import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../conversation_mirror/conversation_mirror_service.dart';
import '../conversation_mirror/storage/conversation_mirror_models.dart';
import '../session_list/cache/session_catalog_cache_repository.dart';
import '../session_list/state/session_list_cubit.dart';
import 'cache_management_strings.dart';

abstract interface class CacheManagementBackend {
  List<ConversationMirrorMetadata> get localCopies;

  Future<int> catalogEntryCount();

  Future<void> clearCatalogCache();

  Future<void> removeLocalCopy(ConversationMirrorMetadata metadata);

  void addListener(VoidCallback listener);

  void removeListener(VoidCallback listener);
}

class _AppCacheManagementBackend implements CacheManagementBackend {
  const _AppCacheManagementBackend({
    required this.catalogCache,
    required this.sessionListCubit,
    required this.conversationMirror,
  });

  final SessionCatalogCacheRepository? catalogCache;
  final SessionListCubit? sessionListCubit;
  final ConversationMirrorService? conversationMirror;

  @override
  List<ConversationMirrorMetadata> get localCopies =>
      conversationMirror?.localCopyMetadata ?? const [];

  @override
  Future<int> catalogEntryCount() =>
      catalogCache?.countAllSessions() ?? Future<int>.value(0);

  @override
  Future<void> clearCatalogCache() {
    final cubit = sessionListCubit;
    if (cubit != null) return cubit.clearPersistentCatalogCache();
    return catalogCache?.clearAll() ?? Future<void>.value();
  }

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
  int _catalogEntryCount = 0;
  int _loadGeneration = 0;
  bool _isLoadingCatalogCount = true;
  bool _isClearingCatalog = false;
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
        );
    _backend!.addListener(_handleBackendChange);
    unawaited(_reloadCatalogCount());
  }

  void _handleBackendChange() {
    if (mounted) setState(() {});
  }

  Future<void> _reloadCatalogCount() async {
    final generation = ++_loadGeneration;
    try {
      final count = await _backend!.catalogEntryCount();
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _catalogEntryCount = count;
        _isLoadingCatalogCount = false;
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() => _isLoadingCatalogCount = false);
      _showError(error);
    }
  }

  Future<void> _clearCatalogCache() async {
    if (_isClearingCatalog) return;
    setState(() => _isClearingCatalog = true);
    try {
      await _backend!.clearCatalogCache();
      await _reloadCatalogCount();
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
              leading: _isLoadingCatalogCount
                  ? const SizedBox.square(
                      dimension: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(Icons.list_alt_outlined, color: cs.primary),
              title: Text(strings.catalogCacheTitle),
              subtitle: Text(strings.catalogCacheSubtitle(_catalogEntryCount)),
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

class _DownloadedHistoryTile extends StatelessWidget {
  const _DownloadedHistoryTile({
    required this.metadata,
    required this.isRemoving,
    required this.onRemove,
  });

  final ConversationMirrorMetadata metadata;
  final bool isRemoving;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final strings = CacheManagementStrings.of(context);
    final title = _displayName(metadata);
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

  static String _displayName(ConversationMirrorMetadata metadata) {
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
