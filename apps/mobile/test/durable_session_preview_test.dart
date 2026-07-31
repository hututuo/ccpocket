import 'dart:async';

import 'package:ccpocket/features/chat_session/state/chat_session_cubit.dart';
import 'package:ccpocket/features/chat_session/state/streaming_state_cubit.dart';
import 'package:ccpocket/features/chat_session/widgets/durable_session_preview.dart';
import 'package:ccpocket/features/conversation_content_sync/conversation_content_sync_service.dart';
import 'package:ccpocket/features/session_list/cache/session_catalog_cache_database.dart';
import 'package:ccpocket/features/session_list/cache/session_catalog_cache_repository.dart';
import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:ccpocket/models/bridge_data_source_identity.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_screen/helpers/chat_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('online attachment is not presented as a local queue', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: DurableSessionBindingBanner(queuedLocally: false)),
      ),
    );

    expect(
      find.text('Connected. Loading live session status…'),
      findsOneWidget,
    );
    expect(find.textContaining('Queued locally'), findsNothing);
  });

  testWidgets('disconnected attachment identifies the local outbox', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: DurableSessionBindingBanner(queuedLocally: true)),
      ),
    );

    expect(find.textContaining('Queued locally'), findsOneWidget);
  });

  testWidgets(
    'cache revisions update the detached cubit without rebuilding child state',
    (tester) async {
      final bridge = MockBridgeService();
      final streaming = StreamingStateCubit();
      final cubit = ChatSessionCubit(
        sessionId: 'durable-thread',
        provider: Provider.codex,
        bridge: bridge,
        streamingCubit: streaming,
        detachedPreview: true,
      );
      final revision = ValueNotifier('revision-1');
      addTearDown(revision.dispose);
      addTearDown(cubit.close);
      addTearDown(streaming.close);
      addTearDown(bridge.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: BlocProvider<ChatSessionCubit>.value(
            value: cubit,
            child: Scaffold(
              body: ValueListenableBuilder<String>(
                valueListenable: revision,
                builder: (context, value, _) {
                  final messages = value == 'revision-1'
                      ? const <ServerMessage>[
                          UserInputMessage(text: 'First cached turn'),
                        ]
                      : const <ServerMessage>[
                          UserInputMessage(text: 'First cached turn'),
                          AssistantServerMessage(
                            message: AssistantMessage(
                              id: 'assistant-2',
                              role: 'assistant',
                              content: [
                                TextContent(text: 'Incremental answer'),
                              ],
                              model: 'gpt-test',
                            ),
                          ),
                        ];
                  return DurableSessionPreviewUpdater(
                    revision: value,
                    messages: messages,
                    hasEarlier: false,
                    child: const TextField(key: ValueKey('durable-composer')),
                  );
                },
              ),
            ),
          ),
        ),
      );

      await tester.enterText(
        find.byKey(const ValueKey('durable-composer')),
        'unsent draft',
      );
      revision.value = 'revision-2';
      await tester.pump();
      await tester.pump();

      expect(find.text('unsent draft'), findsOneWidget);
      expect(
        cubit.state.entries.whereType<ServerChatEntry>().where(
          (entry) =>
              entry.message is AssistantServerMessage &&
              (entry.message as AssistantServerMessage).message.id ==
                  'assistant-2',
        ),
        hasLength(1),
      );
    },
  );

  test(
    'detached history paging keeps the cubit and advances hasMore',
    () async {
      final bridge = MockBridgeService();
      final streaming = StreamingStateCubit();
      var loads = 0;
      final cubit = ChatSessionCubit(
        sessionId: 'durable-paged-thread',
        provider: Provider.codex,
        bridge: bridge,
        streamingCubit: streaming,
        detachedPreview: true,
        initialHistoryHasEarlier: true,
        detachedHistoryPageLoader: () async {
          loads += 1;
          return (loaded: true, hasMore: false);
        },
      );
      addTearDown(cubit.close);
      addTearDown(streaming.close);
      addTearDown(bridge.dispose);

      expect(cubit.localHistoryPaging.value.hasMore, isTrue);
      await cubit.loadOlderLocalHistory();

      expect(loads, 1);
      expect(cubit.localHistoryPaging.value.loading, isFalse);
      expect(cubit.localHistoryPaging.value.hasMore, isFalse);
      expect(cubit.localHistoryPaging.value.error, isNull);
    },
  );

  testWidgets(
    'authenticated cache target reloads a durable Codex preview without input',
    (tester) async {
      final bridge = MockBridgeService()
        ..mockLogicalConnectionIdentity = 'machine:durable-preview'
        ..mockLastUrl = 'wss://durable-preview.test/socket';
      final authenticatedTarget = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: 'bridge-authenticated',
        codexSourceId: 'codex-source-authenticated',
      );
      final repository = _CountingSessionCatalogCacheRepository(
        SessionCatalogCacheDatabase(databasePath: 'unused-test-cache.db'),
        snapshots: {
          authenticatedTarget.fingerprint: ConversationHotWindowSnapshot(
            partitionId: authenticatedTarget.fingerprint,
            provider: Provider.codex.value,
            providerSessionId: 'durable-thread-auth',
            revision: 'revision-authenticated',
            entries: const [
              ConversationContentWireEntry(
                entryId: 'user:durable-auth',
                index: 0,
                contentHash: 'hash-durable-auth',
                rawMessage: {
                  'type': 'user_input',
                  'text': 'Recovered cached turn',
                  'userMessageUuid': 'durable-auth',
                },
              ),
            ],
            hasEarlier: false,
            turnsNextCursor: null,
            latestTurnComplete: true,
            latestTurnGap: null,
            latestTurnGapCursor: null,
            sourceEntryCount: 1,
            cachedAt: DateTime.utc(2026, 7, 31),
          ),
        },
      );
      final sync = ConversationContentSyncService(
        bridge: BridgeServiceConversationContentSyncGateway(bridge),
        cache: repository,
      );
      final hintedIdentity = BridgeDataSourceIdentity.fromConnection(
        bridgeInstanceId: 'bridge-authenticated',
        codexSourceId: 'codex-source-authenticated',
        logicalConnectionIdentity: bridge.mockLogicalConnectionIdentity,
        websocketUrl: bridge.mockLastUrl,
      );

      try {
        await tester.pumpWidget(
          await buildTestCodexSessionScreen(
            bridge: bridge,
            sessionId: 'pending-runtime',
            isPending: true,
            durableProviderSessionId: 'durable-thread-auth',
            dataSourceIdentity: hintedIdentity,
            conversationContentSync: sync,
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(find.text('Recovered cached turn'), findsNothing);
        expect(repository.loadConversationWindowCalls, 1);

        bridge
          ..authenticatedBridgeInstanceId = 'bridge-authenticated'
          ..authenticatedCodexSourceId = 'codex-source-authenticated';
        bridge.emitSessionList([
          const SessionInfo(
            id: 'runtime-authenticated',
            provider: 'codex',
            projectPath: '/workspace/authenticated',
            claudeSessionId: 'durable-thread-auth',
            status: 'idle',
            createdAt: '2026-07-31T00:00:00.000Z',
            lastActivityAt: '2026-07-31T00:00:00.000Z',
          ),
        ]);
        await tester.pump();
        await tester.pump();
        await tester.pump();

        expect(find.text('Recovered cached turn'), findsOneWidget);
        expect(repository.loadConversationWindowCalls, 2);

        bridge.emitSessionList(bridge.currentSessions);
        await tester.pump();
        await tester.pump();
        expect(repository.loadConversationWindowCalls, 2);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await sync.dispose();
        await repository.close();
        bridge.dispose();
      }
    },
  );

  testWidgets(
    'timeline commit during a cache read triggers one same-target reread',
    (tester) async {
      final bridge = MockBridgeService()
        ..authenticatedBridgeInstanceId = 'bridge-same-target'
        ..authenticatedCodexSourceId = 'codex-source-same-target'
        ..mockLogicalConnectionIdentity = 'machine:same-target'
        ..mockLastUrl = 'wss://same-target.test/socket';
      final target = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: bridge.authenticatedBridgeInstanceId,
        codexSourceId: bridge.authenticatedCodexSourceId,
      );
      final firstRead = Completer<ConversationHotWindowSnapshot?>();
      final staleSnapshot = _previewSnapshot(
        partitionId: target.fingerprint,
        providerSessionId: 'durable-thread-race',
        revision: 'revision-before-commit',
        entryId: 'user:before-commit',
        text: 'Stale cached turn',
      );
      final committedSnapshot = _previewSnapshot(
        partitionId: target.fingerprint,
        providerSessionId: 'durable-thread-race',
        revision: 'revision-after-commit',
        entryId: 'user:after-commit',
        text: 'Committed cached turn',
      );
      final repository = _CountingSessionCatalogCacheRepository(
        SessionCatalogCacheDatabase(databasePath: 'unused-race-cache.db'),
        snapshots: const {},
        queuedReads: [
          firstRead.future,
          Future<ConversationHotWindowSnapshot?>.value(committedSnapshot),
        ],
      );
      final sync = _ControllableConversationContentSyncService(
        bridge: BridgeServiceConversationContentSyncGateway(bridge),
        cache: repository,
      );

      try {
        await tester.pumpWidget(
          await buildTestCodexSessionScreen(
            bridge: bridge,
            sessionId: 'pending-runtime-race',
            isPending: true,
            durableProviderSessionId: 'durable-thread-race',
            dataSourceIdentity: bridge.dataSourceIdentity,
            conversationContentSync: sync,
          ),
        );
        await tester.pump();
        expect(repository.loadConversationWindowCalls, 1);

        sync.emitTimelineCommit(
          provider: Provider.codex.value,
          providerSessionId: 'durable-thread-race',
          revision: 'revision-after-commit',
        );
        await tester.pump();
        firstRead.complete(staleSnapshot);
        await tester.pump();
        await tester.pump();
        await tester.pump();

        expect(repository.loadConversationWindowCalls, 2);
        expect(find.text('Committed cached turn'), findsOneWidget);
        expect(find.text('Stale cached turn'), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await sync.dispose();
        await repository.close();
        bridge.dispose();
      }
    },
  );
}

ConversationHotWindowSnapshot _previewSnapshot({
  required String partitionId,
  required String providerSessionId,
  required String revision,
  required String entryId,
  required String text,
}) {
  return ConversationHotWindowSnapshot(
    partitionId: partitionId,
    provider: Provider.codex.value,
    providerSessionId: providerSessionId,
    revision: revision,
    entries: [
      ConversationContentWireEntry(
        entryId: entryId,
        index: 0,
        contentHash: 'hash-$entryId',
        rawMessage: {
          'type': 'user_input',
          'text': text,
          'userMessageUuid': entryId,
        },
      ),
    ],
    hasEarlier: false,
    turnsNextCursor: null,
    latestTurnComplete: true,
    latestTurnGap: null,
    latestTurnGapCursor: null,
    sourceEntryCount: 1,
    cachedAt: DateTime.utc(2026, 7, 31),
  );
}

class _CountingSessionCatalogCacheRepository
    extends SessionCatalogCacheRepository {
  _CountingSessionCatalogCacheRepository(
    super.database, {
    required this.snapshots,
    this.queuedReads = const [],
  });

  final Map<String, ConversationHotWindowSnapshot?> snapshots;
  final List<Future<ConversationHotWindowSnapshot?>> queuedReads;
  int loadConversationWindowCalls = 0;

  @override
  Future<ConversationHotWindowSnapshot?> loadConversationWindow({
    required SessionCatalogCacheTarget target,
    required String provider,
    required String providerSessionId,
  }) {
    loadConversationWindowCalls += 1;
    if (queuedReads.isNotEmpty) return queuedReads.removeAt(0);
    return Future.value(snapshots[target.fingerprint]);
  }
}

class _ControllableConversationContentSyncService
    extends ConversationContentSyncService {
  _ControllableConversationContentSyncService({
    required super.bridge,
    required super.cache,
  });

  final StreamController<ConversationContentCacheUpdate> _testUpdates =
      StreamController<ConversationContentCacheUpdate>.broadcast();

  @override
  Stream<ConversationContentCacheUpdate> get updates => _testUpdates.stream;

  void emitTimelineCommit({
    required String provider,
    required String providerSessionId,
    required String revision,
  }) {
    _testUpdates.add(
      ConversationContentCacheUpdate(
        provider: provider,
        providerSessionId: providerSessionId,
        revision: revision,
      ),
    );
  }

  @override
  Future<void> dispose() async {
    await _testUpdates.close();
    await super.dispose();
  }
}
