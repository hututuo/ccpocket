import 'package:ccpocket/features/conversation_mirror/storage/conversation_mirror_models.dart';
import 'package:ccpocket/features/session_list/cache/session_catalog_cache_repository.dart';
import 'package:ccpocket/features/settings/cache_management_screen.dart';
import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:ccpocket/models/machine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeCacheManagementBackend extends ChangeNotifier
    implements CacheManagementBackend {
  _FakeCacheManagementBackend({
    required this.catalogEntries,
    required List<ConversationMirrorMetadata> localCopies,
    List<CacheManagementMachine> machines = const [],
  }) : _machines = machines.toList() {
    _localCopies.addAll(localCopies);
  }

  int catalogEntries;
  final List<ConversationMirrorMetadata> _localCopies = [];
  final List<CacheManagementMachine> _machines;
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
  Future<List<CacheManagementMachine>> machineCaches() async =>
      List.unmodifiable(_machines);

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
    _replaceDataSource(
      dataSource,
      CacheManagementDataSource(
        target: dataSource.target,
        bridgeInstanceId: dataSource.bridgeInstanceId,
        codexSourceId: dataSource.codexSourceId,
        routeCount: dataSource.routeCount,
        usesStableIdentity: dataSource.usesStableIdentity,
        legacyRouteLabel: dataSource.legacyRouteLabel,
        stats: const SessionCatalogCacheStats.empty(),
        conversations: const [],
      ),
    );
  }

  @override
  Future<void> removeCachedConversation(
    CacheManagementDataSource dataSource,
    SessionCatalogCachedConversation conversation,
  ) async {
    removedCachedConversations.add(conversation.providerSessionId);
    final conversations = dataSource.conversations
        .where((candidate) => candidate != conversation)
        .toList();
    _replaceDataSource(
      dataSource,
      CacheManagementDataSource(
        target: dataSource.target,
        bridgeInstanceId: dataSource.bridgeInstanceId,
        codexSourceId: dataSource.codexSourceId,
        routeCount: dataSource.routeCount,
        usesStableIdentity: dataSource.usesStableIdentity,
        legacyRouteLabel: dataSource.legacyRouteLabel,
        stats: SessionCatalogCacheStats(
          sessionSummaries: dataSource.stats.sessionSummaries,
          conversationWindows: conversations.length,
        ),
        conversations: conversations,
      ),
    );
  }

  void _replaceDataSource(
    CacheManagementDataSource current,
    CacheManagementDataSource replacement,
  ) {
    for (
      var machineIndex = 0;
      machineIndex < _machines.length;
      machineIndex++
    ) {
      final machine = _machines[machineIndex];
      final sourceIndex = machine.dataSources.indexOf(current);
      if (sourceIndex == -1) continue;
      final sources = machine.dataSources.toList();
      sources[sourceIndex] = replacement;
      _machines[machineIndex] = CacheManagementMachine(
        id: machine.id,
        displayName: machine.displayName,
        routeCount: machine.routeCount,
        hasStableIdentity: machine.hasStableIdentity,
        dataSources: sources,
      );
      return;
    }
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
        ValueKey<Object>(('remove_downloaded_history', second.key)),
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
        find.byKey(ValueKey<Object>(('downloaded_history', second.key))),
        findsNothing,
      );
      expect(
        find.byKey(ValueKey<Object>(('downloaded_history', first.key))),
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
      machines: [
        CacheManagementMachine(
          id: 'signed:studio-mac',
          displayName: '我的 Mac',
          routeCount: 2,
          hasStableIdentity: true,
          dataSources: [
            CacheManagementDataSource(
              target: target,
              bridgeInstanceId: 'bridge-a',
              codexSourceId: 'source-a',
              routeCount: 2,
              usesStableIdentity: true,
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
    expect(find.textContaining('Codex 数据源'), findsOneWidget);
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

  test('cache management reuses computer identity and preserves sources', () {
    final groups = groupCacheManagementRoutes([
      _route(
        id: 'lan',
        host: '192.168.1.20',
        signedId: 'signed-studio',
        bridgeId: 'bridge-studio',
        sourceId: 'source-a',
      ),
      _route(
        id: 'tailnet',
        host: '100.64.0.20',
        signedId: 'signed-studio',
        bridgeId: 'bridge-studio',
        sourceId: 'source-a',
      ),
      _route(
        id: 'alternate-source',
        host: 'studio.local',
        signedId: 'signed-studio',
        bridgeId: 'bridge-studio',
        sourceId: 'source-b',
      ),
    ]);

    expect(groups, hasLength(1));
    expect(groups.single.machine.displayName, 'Studio Mac');
    expect(groups.single.machine.routes, hasLength(3));
    expect(groups.single.sources, hasLength(2));
    expect(
      groups.single.sources.map((source) => source.codexSourceId).toSet(),
      {'source-a', 'source-b'},
    );
    expect(
      groups.single.sources
          .singleWhere((source) => source.codexSourceId == 'source-a')
          .routeCount,
      2,
    );
  });

  test('unproven routes remain isolated even when their names match', () {
    final groups = groupCacheManagementRoutes([
      _route(id: 'lan', host: '192.168.1.20', name: 'Studio Mac'),
      _route(id: 'tailnet', host: '100.64.0.20', name: 'Studio Mac'),
    ]);

    expect(groups, hasLength(2));
    expect(
      groups.every((group) => group.sources.single.routeCount == 1),
      isTrue,
    );
    expect(
      groups.every((group) => !group.sources.single.usesStableIdentity),
      isTrue,
    );
  });

  test('signed route never guesses another route Codex source', () {
    final groups = groupCacheManagementRoutes([
      _route(
        id: 'authenticated-lan',
        host: '192.168.1.20',
        signedId: 'signed-studio',
        bridgeId: 'bridge-studio',
        sourceId: 'source-a',
      ),
      _route(
        id: 'signed-tailnet',
        host: '100.64.0.20',
        signedId: 'signed-studio',
      ),
    ]);

    expect(groups, hasLength(1));
    expect(groups.single.sources, hasLength(2));
    expect(
      groups.single.sources.map((source) => source.codexSourceId).toSet(),
      {'source-a', null},
    );
    expect(
      groups.single.sources.every((source) => source.routeCount == 1),
      isTrue,
    );
    expect(
      groups.single.sources.every((source) => source.usesStableIdentity),
      isTrue,
    );
  });

  testWidgets('downloaded copies keep provider and Codex source identity', (
    tester,
  ) async {
    final sourceA = _metadata(
      bridgeId: 'bridge-shared',
      project: 'source-a',
      sourceId: 'source-a',
    );
    final sourceB = _metadata(
      bridgeId: 'bridge-shared',
      project: 'source-b',
      sourceId: 'source-b',
    );
    final backend = _FakeCacheManagementBackend(
      catalogEntries: 0,
      localCopies: [sourceA, sourceB],
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

    expect(
      find.byKey(ValueKey<Object>(('downloaded_history', sourceA.key))),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey<Object>(('downloaded_history', sourceB.key))),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(ValueKey<Object>(('remove_downloaded_history', sourceB.key))),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('confirm_remove_downloaded_history')),
    );
    await tester.pumpAndSettle();

    expect(backend.removedKeys, [sourceB.key]);
    expect(
      find.byKey(ValueKey<Object>(('downloaded_history', sourceA.key))),
      findsOneWidget,
    );
  });
}

MachineWithStatus _route({
  required String id,
  required String host,
  String? name,
  String? signedId,
  String? bridgeId,
  String? sourceId,
}) {
  return MachineWithStatus(
    machine: Machine(
      id: id,
      host: host,
      name: name,
      bridgeIdentityId: signedId,
      bridgeComputerName: signedId == null ? null : 'Studio Mac',
      bridgeInstanceId: bridgeId,
      codexSourceId: sourceId,
    ),
  );
}

ConversationMirrorMetadata _metadata({
  required String bridgeId,
  required String project,
  String? sourceId,
}) {
  return ConversationMirrorMetadata(
    key: ConversationMirrorKey(
      bridgeInstanceId: bridgeId,
      provider: 'codex',
      providerSessionId: 'provider-session-1',
      codexSourceId: sourceId,
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
