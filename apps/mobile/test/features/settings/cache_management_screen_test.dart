import 'package:ccpocket/features/conversation_mirror/storage/conversation_mirror_models.dart';
import 'package:ccpocket/features/session_list/cache/session_catalog_cache_repository.dart';
import 'package:ccpocket/features/settings/cache_management_screen.dart';
import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeCacheManagementBackend extends ChangeNotifier
    implements CacheManagementBackend {
  _FakeCacheManagementBackend({
    required this.catalogEntries,
    required List<ConversationMirrorMetadata> localCopies,
    List<CacheManagementDataSource> dataSources = const [],
  }) : _dataSources = dataSources.toList() {
    _localCopies.addAll(localCopies);
  }

  int catalogEntries;
  final List<ConversationMirrorMetadata> _localCopies = [];
  final List<CacheManagementDataSource> _dataSources;
  int clearCalls = 0;
  final List<String> clearedDataSources = [];
  final List<String> removedCachedConversations = [];
  final List<ConversationMirrorKey> removedKeys = [];
  final Map<ConversationMirrorKey, String> displayNames = {};

  @override
  List<ConversationMirrorMetadata> get localCopies =>
      List.unmodifiable(_localCopies);

  @override
  Future<SessionCatalogCacheStats> temporaryCacheStats() async =>
      SessionCatalogCacheStats(
        sessionSummaries: catalogEntries,
        conversationWindows: catalogEntries == 0 ? 0 : 7,
      );

  @override
  Future<List<CacheManagementDataSource>> dataSourceCaches() async =>
      List.unmodifiable(_dataSources);

  @override
  Future<Map<ConversationMirrorKey, String>> localCopyDisplayNames() async =>
      Map.unmodifiable(displayNames);

  @override
  Future<void> clearCatalogCache() async {
    clearCalls++;
    catalogEntries = 0;
  }

  @override
  Future<void> clearDataSource(CacheManagementDataSource dataSource) async {
    clearedDataSources.add(dataSource.target.fingerprint);
    final index = _dataSources.indexOf(dataSource);
    _dataSources[index] = CacheManagementDataSource(
      target: dataSource.target,
      displayName: dataSource.displayName,
      codexSourceId: dataSource.codexSourceId,
      routeCount: dataSource.routeCount,
      stats: const SessionCatalogCacheStats.empty(),
      conversations: const [],
    );
  }

  @override
  Future<void> removeCachedConversation(
    CacheManagementDataSource dataSource,
    SessionCatalogCachedConversation conversation,
  ) async {
    removedCachedConversations.add(conversation.providerSessionId);
    final index = _dataSources.indexOf(dataSource);
    final conversations = dataSource.conversations
        .where((candidate) => candidate != conversation)
        .toList();
    _dataSources[index] = CacheManagementDataSource(
      target: dataSource.target,
      displayName: dataSource.displayName,
      codexSourceId: dataSource.codexSourceId,
      routeCount: dataSource.routeCount,
      stats: SessionCatalogCacheStats(
        sessionSummaries: dataSource.stats.sessionSummaries,
        conversationWindows: conversations.length,
      ),
      conversations: conversations,
    );
  }

  @override
  Future<void> removeLocalCopy(ConversationMirrorMetadata metadata) async {
    removedKeys.add(metadata.key);
    _localCopies.removeWhere((candidate) => candidate.key == metadata.key);
    notifyListeners();
  }
}

void main() {
  testWidgets(
    'clears rebuildable catalog and deletes one exact downloaded history',
    (tester) async {
      final first = _metadata(bridgeId: 'bridge-a', project: 'project-a');
      final second = _metadata(bridgeId: 'bridge-b', project: 'project-b');
      final backend = _FakeCacheManagementBackend(
        catalogEntries: 42,
        localCopies: [first, second],
      );
      backend.displayNames[second.key] = '真正的会话标题';

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: CacheManagementScreen(backend: backend),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('42 个会话摘要 · 7 个最近消息窗口'), findsOneWidget);
      expect(find.text('真正的会话标题'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('clear_session_catalog_cache_button')),
      );
      await tester.pumpAndSettle();
      expect(backend.clearCalls, 1);
      expect(find.textContaining('0 个会话摘要 · 0 个最近消息窗口'), findsOneWidget);

      final removeButton = find.byKey(
        const ValueKey('remove_downloaded_history_bridge-b_provider-session-1'),
      );
      await tester.ensureVisible(removeButton);
      await tester.tap(removeButton);
      await tester.pumpAndSettle();

      expect(find.textContaining('不会删除电脑上的 Codex 会话'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('confirm_remove_downloaded_history')),
      );
      await tester.pumpAndSettle();

      expect(backend.removedKeys, [second.key]);
      expect(
        find.byKey(
          const ValueKey('downloaded_history_bridge-b_provider-session-1'),
        ),
        findsNothing,
      );
      expect(
        find.byKey(
          const ValueKey('downloaded_history_bridge-a_provider-session-1'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('manages one Bridge data-source cache and recent window', (
    tester,
  ) async {
    final target = SessionCatalogCacheTarget.fromBridge(
      bridgeInstanceId: 'bridge-a',
      codexSourceId: 'source-a',
    );
    final backend = _FakeCacheManagementBackend(
      catalogEntries: 12,
      localCopies: const [],
      dataSources: [
        CacheManagementDataSource(
          target: target,
          displayName: '我的 Mac',
          codexSourceId: 'source-a',
          routeCount: 2,
          stats: const SessionCatalogCacheStats(
            sessionSummaries: 12,
            conversationWindows: 1,
          ),
          conversations: [
            SessionCatalogCachedConversation(
              provider: 'codex',
              providerSessionId: 'cached-thread',
              entryCount: 27,
              updatedAt: DateTime.utc(2026, 7, 30, 1, 2),
            ),
          ],
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: CacheManagementScreen(backend: backend),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('我的 Mac'), findsOneWidget);
    expect(find.textContaining('2 条连接路线'), findsOneWidget);
    await tester.tap(find.text('我的 Mac'));
    await tester.pumpAndSettle();
    expect(find.textContaining('cached…read'), findsOneWidget);
    await tester.tap(find.byTooltip('删除这条最近会话缓存'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('confirm_remove_cached_conversation')),
    );
    await tester.pumpAndSettle();

    expect(backend.removedCachedConversations, ['cached-thread']);
    expect(find.text('没有已缓存的最近会话窗口'), findsOneWidget);
    await tester.tap(
      find.byKey(ValueKey('clear_cache_data_source_${target.fingerprint}')),
    );
    await tester.pumpAndSettle();
    expect(backend.clearedDataSources, [target.fingerprint]);
  });
}

ConversationMirrorMetadata _metadata({
  required String bridgeId,
  required String project,
}) {
  return ConversationMirrorMetadata(
    key: ConversationMirrorKey(
      bridgeInstanceId: bridgeId,
      provider: 'codex',
      providerSessionId: 'provider-session-1',
    ),
    activeGeneration: 'active',
    revision: 'revision',
    entryCount: 123,
    bytes: 12 * 1024,
    autoSync: bridgeId == 'bridge-a',
    projectPath: '/workspace/$project',
    lastSyncedAt: DateTime.utc(2026, 7, 26),
    error: null,
  );
}
