import 'dart:async';

import 'package:ccpocket/features/claude_session/claude_session_screen.dart';
import 'package:ccpocket/features/chat_session/state/chat_session_cubit.dart';
import 'package:ccpocket/features/chat_session/state/streaming_state_cubit.dart';
import 'package:ccpocket/features/chat_session/widgets/durable_session_preview.dart';
import 'package:ccpocket/features/codex_session/codex_session_screen.dart';
import 'package:ccpocket/features/conversation_content_sync/conversation_content_sync_service.dart';
import 'package:ccpocket/features/session_list/cache/session_catalog_cache_database.dart';
import 'package:ccpocket/features/session_list/cache/session_catalog_cache_repository.dart';
import 'package:ccpocket/features/session_list/state/session_list_cubit.dart';
import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:ccpocket/models/bridge_data_source_identity.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chat_screen/helpers/chat_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

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

  testWidgets(
    'detached projection rejects status and settings from another source',
    (tester) async {
      final bridge = MockBridgeService()
        ..advertisedBridgeCapabilities = const {conversationSyncV2Capability};
      final streaming = StreamingStateCubit();
      final cubit = ChatSessionCubit(
        sessionId: 'same-thread',
        provider: Provider.codex,
        bridge: bridge,
        streamingCubit: streaming,
        detachedPreview: true,
        initialLiveRuntimeSessionId: 'runtime-source-a',
      );
      final sessionList = _ProjectionSessionListCubit(
        bridge: bridge,
        sourceFingerprint: 'source-b',
        status: const ConversationSyncV2Status(
          provider: 'codex',
          providerSessionId: 'same-thread',
          activity: 'idle',
          attention: 'none',
          result: 'none',
          runtimeAttachment: 'loaded',
          source: 'appServer',
          confidence: 'authoritative',
          observedAt: '2026-08-01T06:00:00.000Z',
          executionHost: 'bridge',
          controlState: 'writable',
          authorityGeneration: 'authority-source-b',
        ),
        metadata: const RecentSession(
          sessionId: 'same-thread',
          provider: 'codex',
          firstPrompt: 'Source B',
          created: '2026-08-01T05:00:00.000Z',
          modified: '2026-08-01T06:00:00.000Z',
          gitBranch: 'main',
          projectPath: '/source-b',
          isSidechain: false,
          codexModel: 'model-source-b',
          codexModelReasoningEffort: 'high',
        ),
      );
      addTearDown(cubit.close);
      addTearDown(streaming.close);
      addTearDown(sessionList.close);
      addTearDown(bridge.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: MultiBlocProvider(
            providers: [
              BlocProvider<ChatSessionCubit>.value(value: cubit),
              BlocProvider<SessionListCubit>.value(value: sessionList),
            ],
            child: const DurableSessionPreviewUpdater(
              revision: 'source-fence',
              messages: [],
              hasEarlier: false,
              statusProvider: 'codex',
              statusProviderSessionId: 'same-thread',
              expectedSourceFingerprint: 'source-a',
              liveRuntimeSessionId: 'runtime-source-a',
              child: SizedBox.shrink(),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(cubit.state.status, ProcessStatus.unknown);
      expect(cubit.state.codexModel, isNull);
      expect(cubit.canMutateAttachedRuntime, isFalse);

      sessionList.replace(
        sourceFingerprint: 'source-a',
        status: const ConversationSyncV2Status(
          provider: 'codex',
          providerSessionId: 'same-thread',
          activity: 'idle',
          attention: 'none',
          result: 'none',
          runtimeAttachment: 'loaded',
          source: 'appServer',
          confidence: 'authoritative',
          observedAt: '2026-08-01T06:01:00.000Z',
          executionHost: 'unknown',
          controlState: 'writable',
          authorityGeneration: 'authority-source-a',
        ),
        metadata: const RecentSession(
          sessionId: 'same-thread',
          provider: 'codex',
          firstPrompt: 'Source A',
          created: '2026-08-01T05:00:00.000Z',
          modified: '2026-08-01T06:01:00.000Z',
          gitBranch: 'main',
          projectPath: '/source-a',
          isSidechain: false,
          codexModel: 'model-source-a',
          codexModelReasoningEffort: 'ultra',
        ),
      );
      await tester.pump();

      expect(cubit.state.status, ProcessStatus.idle);
      expect(cubit.state.codexModel, 'model-source-a');
      expect(cubit.state.codexModelReasoningEffort, ReasoningEffort.ultra);
      expect(cubit.canMutateAttachedRuntime, isTrue);
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
    'a scoped durable route renders its cache before the socket is authoritative',
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

        expect(find.text('Recovered cached turn'), findsOneWidget);
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
        expect(repository.loadConversationWindowCalls, 1);

        bridge.emitSessionList(bridge.currentSessions);
        await tester.pump();
        await tester.pump();
        expect(repository.loadConversationWindowCalls, 1);
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
    'provisional identity authentication preserves the chat state subtree',
    (tester) async {
      final bridge = MockBridgeService()
        ..mockLogicalConnectionIdentity = 'machine:provisional-upgrade'
        ..mockLastUrl = 'wss://provisional-upgrade.test/socket';
      final provisionalTarget = SessionCatalogCacheTarget.fromBridge(
        logicalConnectionIdentity: bridge.mockLogicalConnectionIdentity,
        websocketUrl: bridge.mockLastUrl,
      );
      final authenticatedTarget = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: 'bridge-authenticated-upgrade',
        codexSourceId: 'source-authenticated-upgrade',
      );
      final repository = _CountingSessionCatalogCacheRepository(
        SessionCatalogCacheDatabase(databasePath: 'unused-upgrade-cache.db'),
        snapshots: {
          provisionalTarget.fingerprint: _previewSnapshot(
            partitionId: provisionalTarget.fingerprint,
            providerSessionId: 'durable-upgrade-thread',
            revision: 'provisional-revision',
            entryId: 'provisional-entry',
            text: 'Provisional cached turn',
          ),
          authenticatedTarget.fingerprint: _previewSnapshot(
            partitionId: authenticatedTarget.fingerprint,
            providerSessionId: 'durable-upgrade-thread',
            revision: 'authenticated-revision',
            entryId: 'authenticated-entry',
            text: 'Authenticated cached turn',
          ),
        },
      );
      final sync = _ControllableConversationContentSyncService(
        bridge: BridgeServiceConversationContentSyncGateway(bridge),
        cache: repository,
      );
      final provisionalIdentity = bridge.dataSourceIdentity;

      try {
        await tester.pumpWidget(
          await buildTestCodexSessionScreen(
            bridge: bridge,
            sessionId: 'pending-upgrade-runtime',
            isPending: true,
            durableProviderSessionId: 'durable-upgrade-thread',
            dataSourceIdentity: provisionalIdentity,
            conversationContentSync: sync,
          ),
        );
        await tester.pump();
        await tester.pump();

        final inputFinder = find.byKey(const ValueKey('message_input'));
        final cubitBefore = BlocProvider.of<ChatSessionCubit>(
          tester.element(inputFinder),
        );
        await tester.enterText(inputFinder, 'draft survives authentication');

        bridge
          ..authenticatedBridgeInstanceId = 'bridge-authenticated-upgrade'
          ..authenticatedCodexSourceId = 'source-authenticated-upgrade';
        bridge.emitSessionList([
          const SessionInfo(
            id: 'runtime-authenticated-upgrade',
            provider: 'codex',
            projectPath: '/workspace/upgrade',
            claudeSessionId: 'durable-upgrade-thread',
            status: 'idle',
            createdAt: '2026-08-01T00:00:00.000Z',
            lastActivityAt: '2026-08-01T00:00:00.000Z',
          ),
        ]);
        await tester.pump();
        await tester.pump();
        await tester.pump();

        final cubitAfter = BlocProvider.of<ChatSessionCubit>(
          tester.element(inputFinder),
        );
        expect(cubitAfter, same(cubitBefore));
        expect(find.text('draft survives authentication'), findsOneWidget);
        expect(find.text('Authenticated cached turn'), findsOneWidget);
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
    'Claude authentication rebinds cache without replacing chat state',
    (tester) async {
      final bridge = MockBridgeService()
        ..mockLogicalConnectionIdentity = 'machine:claude-upgrade'
        ..mockLastUrl = 'wss://claude-upgrade.test/socket';
      final provisionalTarget = SessionCatalogCacheTarget.fromBridge(
        logicalConnectionIdentity: bridge.mockLogicalConnectionIdentity,
        websocketUrl: bridge.mockLastUrl,
      );
      final authenticatedTarget = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: 'bridge-claude-authenticated',
      );
      final repository = _CountingSessionCatalogCacheRepository(
        SessionCatalogCacheDatabase(
          databasePath: 'unused-claude-upgrade-cache.db',
        ),
        snapshots: {
          provisionalTarget.fingerprint: _previewSnapshot(
            partitionId: provisionalTarget.fingerprint,
            provider: Provider.claude.value,
            providerSessionId: 'durable-claude-upgrade',
            revision: 'claude-provisional-revision',
            entryId: 'claude-provisional-entry',
            text: 'Claude provisional cached turn',
          ),
          authenticatedTarget.fingerprint: _previewSnapshot(
            partitionId: authenticatedTarget.fingerprint,
            provider: Provider.claude.value,
            providerSessionId: 'durable-claude-upgrade',
            revision: 'claude-authenticated-revision',
            entryId: 'claude-authenticated-entry',
            text: 'Claude authenticated cached turn',
          ),
        },
      );
      final sync = _ControllableConversationContentSyncService(
        bridge: BridgeServiceConversationContentSyncGateway(bridge),
        cache: repository,
      );
      final provisionalIdentity = bridge.dataSourceIdentity;

      try {
        await tester.pumpWidget(
          await buildTestClaudeSessionScreen(
            bridge: bridge,
            sessionId: 'pending-claude-upgrade-runtime',
            isPending: true,
            durableProviderSessionId: 'durable-claude-upgrade',
            dataSourceIdentity: provisionalIdentity,
            conversationContentSync: sync,
          ),
        );
        await tester.pump();
        await tester.pump();

        final inputFinder = find.byKey(const ValueKey('message_input'));
        final cubitBefore = BlocProvider.of<ChatSessionCubit>(
          tester.element(inputFinder),
        );
        await tester.enterText(inputFinder, 'Claude draft survives auth');

        bridge.authenticatedBridgeInstanceId = 'bridge-claude-authenticated';
        bridge.emitSessionList([
          const SessionInfo(
            id: 'runtime-claude-authenticated',
            provider: 'claude',
            projectPath: '/workspace/claude-upgrade',
            claudeSessionId: 'durable-claude-upgrade',
            status: 'idle',
            createdAt: '2026-08-01T00:00:00.000Z',
            lastActivityAt: '2026-08-01T00:00:00.000Z',
          ),
        ]);
        await tester.pump();
        await tester.pump();
        await tester.pump();

        final cubitAfter = BlocProvider.of<ChatSessionCubit>(
          tester.element(inputFinder),
        );
        expect(cubitAfter, same(cubitBefore));
        expect(find.text('Claude draft survives auth'), findsOneWidget);
        expect(find.text('Claude authenticated cached turn'), findsOneWidget);
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
    'returning to a durable route restores focus only for the same source',
    (tester) async {
      final bridge = MockBridgeService()
        ..authenticatedBridgeInstanceId = 'bridge-focus'
        ..authenticatedCodexSourceId = 'source-focus-a'
        ..mockLogicalConnectionIdentity = 'machine:focus'
        ..mockLastUrl = 'wss://focus.test/socket';
      final target = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: bridge.authenticatedBridgeInstanceId,
        codexSourceId: bridge.authenticatedCodexSourceId,
      );
      final repository = _CountingSessionCatalogCacheRepository(
        SessionCatalogCacheDatabase(databasePath: 'unused-focus-cache.db'),
        snapshots: {
          target.fingerprint: _previewSnapshot(
            partitionId: target.fingerprint,
            providerSessionId: 'durable-focus-thread',
            revision: 'focus-revision',
            entryId: 'focus-entry',
            text: 'Focused cached turn',
          ),
        },
      );
      final sync = _ControllableConversationContentSyncService(
        bridge: BridgeServiceConversationContentSyncGateway(bridge),
        cache: repository,
      );

      try {
        await tester.pumpWidget(
          await buildTestCodexSessionScreen(
            bridge: bridge,
            sessionId: 'pending-focus-runtime',
            isPending: true,
            durableProviderSessionId: 'durable-focus-thread',
            dataSourceIdentity: bridge.dataSourceIdentity,
            conversationContentSync: sync,
          ),
        );
        await tester.pump();
        await tester.pump();
        final navigator = Navigator.of(
          tester.element(find.byType(CodexSessionScreen)),
        );

        unawaited(
          navigator.push<void>(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('Cover route')),
            ),
          ),
        );
        await tester.pumpAndSettle();
        sync.setFocusedConversation(
          provider: Provider.codex.value,
          providerSessionId: 'other-thread',
        );
        navigator.pop();
        await tester.pumpAndSettle();
        expect(
          sync.focusedTargets.last?.providerSessionId,
          'durable-focus-thread',
        );

        unawaited(
          navigator.push<void>(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('Second cover')),
            ),
          ),
        );
        await tester.pumpAndSettle();
        sync.setFocusedConversation(
          provider: Provider.codex.value,
          providerSessionId: 'other-thread',
        );
        bridge.authenticatedCodexSourceId = 'source-focus-b';
        navigator.pop();
        await tester.pumpAndSettle();
        expect(sync.focusedTargets.last?.providerSessionId, 'other-thread');
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
    'returning to a Claude route does not restore focus across Bridges',
    (tester) async {
      final bridge = MockBridgeService()
        ..authenticatedBridgeInstanceId = 'bridge-claude-focus-a'
        ..mockLogicalConnectionIdentity = 'machine:claude-focus'
        ..mockLastUrl = 'wss://claude-focus.test/socket';
      final target = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: bridge.authenticatedBridgeInstanceId,
      );
      final repository = _CountingSessionCatalogCacheRepository(
        SessionCatalogCacheDatabase(
          databasePath: 'unused-claude-focus-cache.db',
        ),
        snapshots: {
          target.fingerprint: _previewSnapshot(
            partitionId: target.fingerprint,
            provider: Provider.claude.value,
            providerSessionId: 'durable-claude-focus',
            revision: 'claude-focus-revision',
            entryId: 'claude-focus-entry',
            text: 'Claude focused cached turn',
          ),
        },
      );
      final sync = _ControllableConversationContentSyncService(
        bridge: BridgeServiceConversationContentSyncGateway(bridge),
        cache: repository,
      );

      try {
        await tester.pumpWidget(
          await buildTestClaudeSessionScreen(
            bridge: bridge,
            sessionId: 'pending-claude-focus-runtime',
            isPending: true,
            durableProviderSessionId: 'durable-claude-focus',
            dataSourceIdentity: bridge.dataSourceIdentity,
            conversationContentSync: sync,
          ),
        );
        await tester.pump();
        await tester.pump();
        final navigator = Navigator.of(
          tester.element(find.byType(ClaudeSessionScreen)),
        );

        unawaited(
          navigator.push<void>(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('Claude cover')),
            ),
          ),
        );
        await tester.pumpAndSettle();
        sync.setFocusedConversation(
          provider: Provider.claude.value,
          providerSessionId: 'other-claude-thread',
        );
        navigator.pop();
        await tester.pumpAndSettle();
        expect(
          sync.focusedTargets.last?.providerSessionId,
          'durable-claude-focus',
        );

        unawaited(
          navigator.push<void>(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('Other Bridge')),
            ),
          ),
        );
        await tester.pumpAndSettle();
        sync.setFocusedConversation(
          provider: Provider.claude.value,
          providerSessionId: 'other-claude-thread',
        );
        bridge.authenticatedBridgeInstanceId = 'bridge-claude-focus-b';
        navigator.pop();
        await tester.pumpAndSettle();
        expect(
          sync.focusedTargets.last?.providerSessionId,
          'other-claude-thread',
        );
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

  testWidgets(
    'an open durable route rejects the same thread id from another Codex source',
    (tester) async {
      final bridge = MockBridgeService()
        ..authenticatedBridgeInstanceId = 'bridge-source-fence'
        ..authenticatedCodexSourceId = 'codex-source-a'
        ..mockLogicalConnectionIdentity = 'machine:source-fence'
        ..mockLastUrl = 'wss://source-fence.test/socket';
      final targetA = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: 'bridge-source-fence',
        codexSourceId: 'codex-source-a',
      );
      final targetB = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: 'bridge-source-fence',
        codexSourceId: 'codex-source-b',
      );
      final repository = _CountingSessionCatalogCacheRepository(
        SessionCatalogCacheDatabase(databasePath: 'unused-source-fence.db'),
        snapshots: {
          targetA.fingerprint: _previewSnapshot(
            partitionId: targetA.fingerprint,
            providerSessionId: 'same-thread-id',
            revision: 'source-a-revision',
            entryId: 'source-a-entry',
            text: 'Source A cached turn',
          ),
          targetB.fingerprint: _previewSnapshot(
            partitionId: targetB.fingerprint,
            providerSessionId: 'same-thread-id',
            revision: 'source-b-revision',
            entryId: 'source-b-entry',
            text: 'Source B must stay hidden',
          ),
        },
      );
      final sync = _ControllableConversationContentSyncService(
        bridge: BridgeServiceConversationContentSyncGateway(bridge),
        cache: repository,
      );

      try {
        await tester.pumpWidget(
          await buildTestCodexSessionScreen(
            bridge: bridge,
            sessionId: 'pending-source-a',
            isPending: true,
            durableProviderSessionId: 'same-thread-id',
            dataSourceIdentity: bridge.dataSourceIdentity,
            conversationContentSync: sync,
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(find.text('Source A cached turn'), findsOneWidget);
        expect(repository.loadConversationWindowCalls, 1);

        bridge.authenticatedCodexSourceId = 'codex-source-b';
        bridge.emitSessionList([
          const SessionInfo(
            id: 'runtime-source-b',
            provider: 'codex',
            projectPath: '/workspace/source-b',
            claudeSessionId: 'same-thread-id',
            status: 'idle',
            createdAt: '2026-08-01T00:00:00.000Z',
            lastActivityAt: '2026-08-01T00:00:00.000Z',
          ),
        ]);
        sync.emitTimelineCommit(
          provider: Provider.codex.value,
          providerSessionId: 'same-thread-id',
          revision: 'source-b-revision',
          targetFingerprint: targetB.fingerprint,
        );
        await tester.pump();
        await tester.pump();

        expect(repository.loadConversationWindowCalls, 1);
        expect(find.text('Source A cached turn'), findsOneWidget);
        expect(find.text('Source B must stay hidden'), findsNothing);
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
    'a route opened on another source recovers when its own source authenticates',
    (tester) async {
      final bridge = MockBridgeService()
        ..authenticatedBridgeInstanceId = 'bridge-source-recovery'
        ..authenticatedCodexSourceId = 'codex-source-b'
        ..mockLogicalConnectionIdentity = 'machine:source-recovery'
        ..mockLastUrl = 'wss://source-recovery.test/socket';
      final targetA = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: 'bridge-source-recovery',
        codexSourceId: 'codex-source-a',
      );
      final snapshots = <String, ConversationHotWindowSnapshot?>{
        targetA.fingerprint: _previewSnapshot(
          partitionId: targetA.fingerprint,
          providerSessionId: 'recovering-thread',
          revision: 'source-a-before-commit',
          entryId: 'source-a-before-entry',
          text: 'Source A after authentication',
        ),
      };
      final repository = _CountingSessionCatalogCacheRepository(
        SessionCatalogCacheDatabase(databasePath: 'unused-recovery.db'),
        snapshots: snapshots,
      );
      final sync = _ControllableConversationContentSyncService(
        bridge: BridgeServiceConversationContentSyncGateway(bridge),
        cache: repository,
      );
      final routeA = const BridgeDataSourceIdentity(
        bridgeInstanceId: 'bridge-source-recovery',
        codexSourceId: 'codex-source-a',
        legacyRouteIdentity: 'logical:machine:source-recovery',
      );

      try {
        await tester.pumpWidget(
          await buildTestCodexSessionScreen(
            bridge: bridge,
            sessionId: 'pending-source-a',
            isPending: true,
            durableProviderSessionId: 'recovering-thread',
            dataSourceIdentity: routeA,
            conversationContentSync: sync,
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(find.text('Source A after authentication'), findsNothing);
        expect(repository.loadConversationWindowCalls, 0);

        bridge.authenticatedCodexSourceId = 'codex-source-a';
        bridge.emitSessionList([
          const SessionInfo(
            id: 'runtime-source-a',
            provider: 'codex',
            projectPath: '/workspace/source-a',
            claudeSessionId: 'recovering-thread',
            status: 'idle',
            createdAt: '2026-08-01T00:00:00.000Z',
            lastActivityAt: '2026-08-01T00:00:00.000Z',
          ),
        ]);
        await tester.pump();
        await tester.pump();
        await tester.pump();
        expect(find.text('Source A after authentication'), findsOneWidget);
        expect(repository.loadConversationWindowCalls, 1);

        snapshots[targetA.fingerprint] = _previewSnapshot(
          partitionId: targetA.fingerprint,
          providerSessionId: 'recovering-thread',
          revision: 'source-a-after-commit',
          entryId: 'source-a-before-entry',
          text: 'Source A committed update',
        );
        sync.emitTimelineCommit(
          provider: Provider.codex.value,
          providerSessionId: 'recovering-thread',
          revision: 'source-a-after-commit',
          targetFingerprint: targetA.fingerprint,
        );
        await tester.pump();
        await tester.pump();

        expect(find.text('Source A committed update'), findsOneWidget);
        expect(find.text('Source A after authentication'), findsNothing);
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
}

ConversationHotWindowSnapshot _previewSnapshot({
  required String partitionId,
  required String providerSessionId,
  required String revision,
  required String entryId,
  required String text,
  String provider = 'codex',
}) {
  return ConversationHotWindowSnapshot(
    partitionId: partitionId,
    provider: provider,
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
  final List<ConversationContentTarget?> focusedTargets = [];

  @override
  Stream<ConversationContentCacheUpdate> get updates => _testUpdates.stream;

  @override
  void setFocusedConversation({String? provider, String? providerSessionId}) {
    focusedTargets.add(
      provider == null || providerSessionId == null
          ? null
          : ConversationContentTarget(
              provider: provider,
              providerSessionId: providerSessionId,
            ),
    );
    super.setFocusedConversation(
      provider: provider,
      providerSessionId: providerSessionId,
    );
  }

  void emitTimelineCommit({
    required String provider,
    required String providerSessionId,
    required String revision,
    String? targetFingerprint,
  }) {
    _testUpdates.add(
      ConversationContentCacheUpdate(
        targetFingerprint: targetFingerprint ?? currentCacheTargetFingerprint,
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

class _ProjectionSessionListCubit extends SessionListCubit {
  _ProjectionSessionListCubit({
    required super.bridge,
    required this.sourceFingerprint,
    required this.status,
    required this.metadata,
  });

  final StreamController<void> _changes = StreamController<void>.broadcast();
  String sourceFingerprint;
  ConversationSyncV2Status status;
  RecentSession metadata;

  @override
  Stream<void> get catalogSnapshotChanges => _changes.stream;

  @override
  String? get conversationSourceFingerprint => sourceFingerprint;

  @override
  Map<String, ConversationSyncV2Status> get conversationStatuses => {
    '${status.provider}\u0000${status.providerSessionId}': status,
  };

  @override
  RecentSession? conversationMetadataFor(
    String provider,
    String providerSessionId,
  ) => provider == metadata.provider && providerSessionId == metadata.sessionId
      ? metadata
      : null;

  void replace({
    required String sourceFingerprint,
    required ConversationSyncV2Status status,
    required RecentSession metadata,
  }) {
    this.sourceFingerprint = sourceFingerprint;
    this.status = status;
    this.metadata = metadata;
    _changes.add(null);
  }

  @override
  Future<void> close() async {
    await _changes.close();
    await super.close();
  }
}
