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
  }) : _localCopies = localCopies;

  int catalogEntries;
  final List<ConversationMirrorMetadata> _localCopies;
  int clearCalls = 0;
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
  Future<Map<ConversationMirrorKey, String>> localCopyDisplayNames() async =>
      Map.unmodifiable(displayNames);

  @override
  Future<void> clearCatalogCache() async {
    clearCalls++;
    catalogEntries = 0;
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
