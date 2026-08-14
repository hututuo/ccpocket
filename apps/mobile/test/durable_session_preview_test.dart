import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ccpocket/features/claude_session/claude_session_screen.dart';
import 'package:ccpocket/features/chat_session/state/chat_session_cubit.dart';
import 'package:ccpocket/features/chat_session/state/chat_session_state.dart';
import 'package:ccpocket/features/chat_session/state/streaming_state_cubit.dart';
import 'package:ccpocket/features/chat_session/widgets/durable_session_preview.dart';
import 'package:ccpocket/features/chat_session/widgets/chat_input_with_overlays.dart';
import 'package:ccpocket/features/chat_session/widgets/session_mode_bar.dart';
import 'package:ccpocket/features/codex_action_broker/codex_action_broker_interaction_frame.dart';
import 'package:ccpocket/features/codex_action_broker/codex_action_broker_service.dart';
import 'package:ccpocket/features/codex_session/codex_session_screen.dart';
import 'package:ccpocket/features/conversation_content_sync/conversation_content_sync_service.dart';
import 'package:ccpocket/features/session_list/cache/session_catalog_cache_database.dart';
import 'package:ccpocket/features/session_list/cache/session_catalog_cache_repository.dart';
import 'package:ccpocket/features/session_list/state/session_list_cubit.dart';
import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:ccpocket/models/bridge_data_source_identity.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/draft_service.dart';
import 'package:ccpocket/theme/app_theme.dart';
import 'package:ccpocket/widgets/bubbles/ask_user_question_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chat_screen/helpers/chat_test_helpers.dart';

void main() {
  test('Claude identity ignores a retained catalog from another source', () {
    final retained = RecentSession(
      sessionId: 'shared-thread',
      provider: Provider.claude.value,
      firstPrompt: 'retained old source',
      created: '2026-08-10T00:00:00Z',
      modified: '2026-08-10T00:00:00Z',
      gitBranch: 'main',
      projectPath: '/tmp/project',
      isSidechain: false,
    );

    expect(
      isCurrentCatalogIdentityProof(
        hasUsableCatalogForCurrentTarget: false,
        session: retained,
      ),
      isFalse,
    );
    expect(
      isCurrentCatalogIdentityProof(
        hasUsableCatalogForCurrentTarget: true,
        session: retained,
      ),
      isTrue,
    );
  });

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
    'Codex and Claude show source-confirmed latest-turn recovery and retry it',
    (tester) async {
      for (final provider in [Provider.codex.value, Provider.claude.value]) {
        final harness = _LatestTurnRecoveryHarness(
          provider: provider,
          latestTurnComplete: false,
          entries: const [],
          repairResponses: [
            Future<ConversationTurnsPageLoadResult>.value(
              const ConversationTurnsPageLoadResult(
                loaded: true,
                hasMore: false,
              ),
            ),
          ],
        );
        try {
          await tester.pumpWidget(await harness.build());
          await tester.pump();
          await tester.pump();

          expect(
            find.byKey(const ValueKey('durable_latest_turn_recovery_banner')),
            findsOneWidget,
            reason: provider,
          );
          await tester.tap(
            find.byKey(const ValueKey('durable_latest_turn_recovery_retry')),
          );
          await tester.pump();
          await tester.pump();

          expect(harness.sync.latestTurnRepairCalls, 1, reason: provider);
          expect(
            find.byKey(const ValueKey('durable_latest_turn_recovery_banner')),
            findsOneWidget,
            reason: provider,
          );
        } finally {
          await harness.dispose(tester);
        }
      }
    },
  );

  testWidgets(
    'complete snapshots hide recovery while visible incomplete snapshots keep it available',
    (tester) async {
      for (final provider in [Provider.codex.value, Provider.claude.value]) {
        for (final scenario in [
          (
            latestTurnComplete: true,
            entries: const <ConversationContentWireEntry>[],
          ),
          (
            latestTurnComplete: false,
            entries: const <ConversationContentWireEntry>[
              ConversationContentWireEntry(
                entryId: 'visible-entry',
                index: 0,
                contentHash: 'hash-visible-entry',
                rawMessage: {
                  'type': 'user_input',
                  'text': 'Visible cached entry',
                  'userMessageUuid': 'visible-entry',
                },
              ),
            ],
          ),
        ]) {
          final harness = _LatestTurnRecoveryHarness(
            provider: provider,
            latestTurnComplete: scenario.latestTurnComplete,
            entries: scenario.entries,
            repairResponses: const [],
          );
          try {
            await tester.pumpWidget(await harness.build());
            await tester.pump();
            await tester.pump();
            expect(
              find.byKey(const ValueKey('durable_latest_turn_recovery_banner')),
              scenario.latestTurnComplete ? findsNothing : findsOneWidget,
              reason: '$provider ${scenario.latestTurnComplete}',
            );
          } finally {
            await harness.dispose(tester);
          }
        }
      }
    },
  );

  testWidgets(
    'latest-turn recovery stops loading after failure and can be retried',
    (tester) async {
      for (final provider in [Provider.codex.value, Provider.claude.value]) {
        final firstRepair = Completer<ConversationTurnsPageLoadResult>();
        final harness = _LatestTurnRecoveryHarness(
          provider: provider,
          latestTurnComplete: false,
          entries: const [],
          repairResponses: [
            firstRepair.future,
            Future<ConversationTurnsPageLoadResult>.value(
              const ConversationTurnsPageLoadResult(
                loaded: true,
                hasMore: false,
              ),
            ),
          ],
        );
        try {
          await tester.pumpWidget(await harness.build());
          await tester.pump();
          await tester.pump();
          final retry = find.byKey(
            const ValueKey('durable_latest_turn_recovery_retry'),
          );
          await tester.tap(retry);
          await tester.pump();
          expect(
            find.byKey(const ValueKey('durable_latest_turn_recovery_loading')),
            findsOneWidget,
            reason: provider,
          );

          firstRepair.complete(
            const ConversationTurnsPageLoadResult(
              loaded: false,
              hasMore: false,
            ),
          );
          await tester.pump();
          await tester.pump();
          expect(
            find.byKey(const ValueKey('durable_latest_turn_recovery_loading')),
            findsNothing,
            reason: provider,
          );
          expect(
            find.textContaining('Could not load this turn'),
            findsOneWidget,
            reason: provider,
          );
          expect(tester.widget<TextButton>(retry).onPressed, isNotNull);

          await tester.tap(retry);
          await tester.pump();
          await tester.pump();
          expect(harness.sync.latestTurnRepairCalls, 2, reason: provider);
          expect(
            find.byKey(const ValueKey('durable_latest_turn_recovery_banner')),
            findsOneWidget,
            reason: provider,
          );
        } finally {
          await harness.dispose(tester);
        }
      }
    },
  );

  testWidgets(
    'first send attaches a v2-only durable conversation absent from the legacy recent list',
    (tester) async {
      final bridge = MockBridgeService()
        ..authenticatedBridgeInstanceId = 'bridge-v2-only-resume'
        ..authenticatedCodexSourceId = 'source-v2-only-resume'
        ..advertisedBridgeCapabilities = const {
          conversationSyncV2Capability,
          sessionRequestCorrelationCapability,
        };
      final identity = bridge.dataSourceIdentity;
      final target = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: bridge.authenticatedBridgeInstanceId,
        codexSourceId: bridge.authenticatedCodexSourceId,
      );
      final metadata = const RecentSession(
        sessionId: 'thread-v2-only-resume',
        provider: 'codex',
        firstPrompt: 'Cached v2 conversation',
        created: '2026-08-01T00:00:00.000Z',
        modified: '2026-08-01T00:01:00.000Z',
        gitBranch: 'main',
        projectPath: '/workspace/v2-only',
        isSidechain: false,
        codexSourceId: 'source-v2-only-resume',
        codexModel: 'gpt-5.6-sol',
        codexModelReasoningEffort: 'ultra',
      );
      final sessionList = _ProjectionSessionListCubit(
        bridge: bridge,
        sourceFingerprint: target.fingerprint,
        status: const ConversationSyncV2Status(
          provider: 'codex',
          providerSessionId: 'thread-v2-only-resume',
          activity: 'idle',
          attention: 'none',
          result: 'none',
          runtimeAttachment: 'notLoaded',
          source: 'appServer',
          confidence: 'authoritative',
          observedAt: '2026-08-01T00:01:00.000Z',
          executionHost: 'unknown',
          controlState: 'writable',
        ),
        metadata: metadata,
      );
      final repository = _CountingSessionCatalogCacheRepository(
        SessionCatalogCacheDatabase(
          databasePath: 'unused-v2-only-resume-cache.db',
        ),
        snapshots: const {},
      );
      final sync = ConversationContentSyncService(
        bridge: BridgeServiceConversationContentSyncGateway(bridge),
        cache: repository,
      );

      try {
        await tester.pumpWidget(
          await buildTestCodexSessionScreen(
            bridge: bridge,
            sessionId: 'pending-v2-only-runtime',
            projectPath: metadata.projectPath,
            isPending: true,
            durableProviderSessionId: metadata.sessionId,
            dataSourceIdentity: identity,
            conversationContentSync: sync,
            sessionListCubit: sessionList,
          ),
        );
        await tester.pump();
        final composer = tester.widget<ChatInputWithOverlays>(
          find.byType(ChatInputWithOverlays),
        );
        final chatCubit = BlocProvider.of<ChatSessionCubit>(
          tester.element(find.byKey(const ValueKey('message_input'))),
        );
        expect(chatCubit.state.codexModel, metadata.codexModel);
        expect(
          chatCubit.state.codexModelReasoningEffort,
          ReasoningEffort.ultra,
        );
        expect(composer.onSubmit, isNotNull);
        expect(
          composer.onSubmit!.call((
            clientMessageId: 'client-v2-only-resume',
            text: 'Attach from the v2 projection',
            images: null,
            mentionablePaths: const [],
            additionalMentions: const [],
          )),
          isTrue,
        );
        for (var attempt = 0; attempt < 50; attempt++) {
          if (_sentWireMessages(
            bridge,
          ).any((message) => message['type'] == 'resume_session')) {
            break;
          }
          await tester.pump(const Duration(milliseconds: 10));
        }

        final resumeMessages = _sentWireMessages(
          bridge,
        ).where((message) => message['type'] == 'resume_session').toList();
        expect(resumeMessages, hasLength(1));
        expect(resumeMessages.single['sessionId'], metadata.sessionId);
        expect(
          resumeMessages.single['resumeRequestId'],
          isA<String>().having((value) => value.isNotEmpty, 'non-empty', true),
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await sync.dispose();
        await repository.close();
        bridge.dispose();
        unawaited(sessionList.close());
      }
    },
  );

  testWidgets(
    'restored Codex submission stays failed until an explicit retry',
    (tester) async {
      final bridge = MockBridgeService()
        ..authenticatedBridgeInstanceId = 'bridge-restored-resume'
        ..authenticatedCodexSourceId = 'source-restored-resume'
        ..advertisedBridgeCapabilities = const {
          conversationSyncV2Capability,
          sessionRequestCorrelationCapability,
        }
        ..emitSessionList(const []);
      final identity = bridge.dataSourceIdentity;
      final target = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: bridge.authenticatedBridgeInstanceId,
        codexSourceId: bridge.authenticatedCodexSourceId,
      );
      const metadata = RecentSession(
        sessionId: 'thread-restored-resume',
        provider: 'codex',
        firstPrompt: 'Restored pending message',
        created: '2026-08-01T00:00:00.000Z',
        modified: '2026-08-01T00:01:00.000Z',
        gitBranch: 'main',
        projectPath: '/workspace/restored-resume',
        isSidechain: false,
        codexSourceId: 'source-restored-resume',
      );
      final sessionList = _ProjectionSessionListCubit(
        bridge: bridge,
        sourceFingerprint: target.fingerprint,
        metadataAvailable: false,
        status: const ConversationSyncV2Status(
          provider: 'codex',
          providerSessionId: 'thread-restored-resume',
          activity: 'idle',
          attention: 'none',
          result: 'none',
          runtimeAttachment: 'notLoaded',
          source: 'appServer',
          confidence: 'authoritative',
          observedAt: '2026-08-01T00:01:00.000Z',
          executionHost: 'unknown',
          controlState: 'writable',
        ),
        metadata: metadata,
      );
      final prefs = await SharedPreferences.getInstance();
      final drafts = DraftService(prefs);
      final image = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47]);
      const clientMessageId = 'client-restored-resume';
      await drafts.savePendingSubmission(
        metadata.sessionId,
        PendingChatSubmissionDraft(
          clientMessageId: clientMessageId,
          text: 'Continue after reconnect',
          images: [(bytes: image, mimeType: 'image/png')],
        ),
      );
      final repository = _CountingSessionCatalogCacheRepository(
        SessionCatalogCacheDatabase(
          databasePath: 'unused-restored-resume-cache.db',
        ),
        snapshots: const {},
      );
      final sync = ConversationContentSyncService(
        bridge: BridgeServiceConversationContentSyncGateway(bridge),
        cache: repository,
      );

      try {
        await tester.pumpWidget(
          await buildTestCodexSessionScreen(
            bridge: bridge,
            sessionId: 'pending-restored-runtime',
            projectPath: metadata.projectPath,
            isPending: true,
            durableProviderSessionId: metadata.sessionId,
            dataSourceIdentity: identity,
            conversationContentSync: sync,
            sessionListCubit: sessionList,
            draftService: drafts,
            imagePayloadEncoder: (images) async => [
              for (final image in images)
                {
                  'base64': base64Encode(image.bytes),
                  'mimeType': image.mimeType,
                },
            ],
          ),
        );
        await tester.pump();
        final cubit = BlocProvider.of<ChatSessionCubit>(
          tester.element(find.byKey(const ValueKey('message_input'))),
        );
        expect(
          _sentWireMessages(
            bridge,
          ).where((message) => message['type'] == 'resume_session'),
          isEmpty,
        );
        expect(
          _sentWireMessages(
            bridge,
          ).where((message) => message['type'] == 'input'),
          isEmpty,
        );

        sessionList.replace(
          sourceFingerprint: target.fingerprint,
          status: sessionList.status,
          metadata: metadata,
          metadataAvailable: true,
        );
        // Runtime/catalog readiness is deliberately not an implicit recovery
        // trigger. Let all readiness callbacks settle before asserting that the
        // old v1 draft did not acquire a runtime or emit input.
        for (var attempt = 0; attempt < 50; attempt++) {
          await tester.pump(const Duration(milliseconds: 10));
        }

        expect(
          _sentWireMessages(
            bridge,
          ).where((message) => message['type'] == 'resume_session'),
          isEmpty,
        );
        expect(
          _sentWireMessages(
            bridge,
          ).where((message) => message['type'] == 'input'),
          isEmpty,
        );
        final restoredUsers = cubit.state.entries
            .whereType<UserChatEntry>()
            .toList();
        expect(restoredUsers, hasLength(1));
        expect(restoredUsers.single.text, 'Continue after reconnect');
        expect(restoredUsers.single.clientMessageId, clientMessageId);
        expect(restoredUsers.single.status, MessageStatus.failed);
        expect(restoredUsers.single.imageCount, 1);
        expect(restoredUsers.single.imageBytesList, hasLength(1));
        expect(restoredUsers.single.imageBytesList.single, image);
        expect(find.text('Tap to retry'), findsOneWidget);

        // Only the user's explicit retry may enter attachment. It must keep the
        // same optimistic bubble and client id; it must not send input before a
        // runtime is attached.
        bridge.connected = false;
        await tester.tap(find.text('Tap to retry'));
        await tester.pump();
        expect(
          _sentWireMessages(
            bridge,
          ).where((message) => message['type'] == 'resume_session'),
          isEmpty,
        );
        expect(
          cubit.state.entries.whereType<UserChatEntry>().single.status,
          MessageStatus.failed,
        );

        bridge.connected = true;
        await tester.tap(find.text('Tap to retry'));
        await tester.pump();
        for (var attempt = 0; attempt < 50; attempt++) {
          if (_sentWireMessages(
            bridge,
          ).any((message) => message['type'] == 'resume_session')) {
            break;
          }
          await tester.pump(const Duration(milliseconds: 10));
        }
        final explicitResumeMessages = _sentWireMessages(
          bridge,
        ).where((message) => message['type'] == 'resume_session').toList();
        expect(explicitResumeMessages, hasLength(1));
        expect(explicitResumeMessages.single['sessionId'], metadata.sessionId);
        expect(
          _sentWireMessages(
            bridge,
          ).where((message) => message['type'] == 'input'),
          isEmpty,
        );
        final usersAfterRetry = cubit.state.entries
            .whereType<UserChatEntry>()
            .toList();
        expect(usersAfterRetry, hasLength(1));
        expect(usersAfterRetry.single.clientMessageId, clientMessageId);
        expect(usersAfterRetry.single.imageBytesList.single, image);
        expect(usersAfterRetry.single.status, MessageStatus.sending);

        // Runtime attachment alone is not writable authority. Once the exact
        // source-scoped status arrives, the explicit retry continues once
        // with the original id and image payload.
        bridge.emitMessage(
          SystemMessage(
            subtype: 'session_created',
            sessionId: 'attached-restored-runtime',
            claudeSessionId: metadata.sessionId,
            provider: Provider.codex.value,
            projectPath: metadata.projectPath,
            resumeRequestId:
                explicitResumeMessages.single['resumeRequestId'] as String,
          ),
        );
        await tester.pump();
        bridge.emitSessionList(const [
          SessionInfo(
            id: 'attached-restored-runtime',
            provider: 'codex',
            projectPath: '/workspace/restored-resume',
            claudeSessionId: 'thread-restored-resume',
            status: 'idle',
            createdAt: '2026-08-14T05:29:59.000Z',
            lastActivityAt: '2026-08-14T05:30:00.000Z',
          ),
        ]);
        await tester.pump();
        expect(cubit.detachedLiveRuntimeSessionId, 'attached-restored-runtime');
        sessionList.replace(
          sourceFingerprint: target.fingerprint,
          status: const ConversationSyncV2Status(
            provider: 'codex',
            providerSessionId: 'thread-restored-resume',
            activity: 'idle',
            attention: 'none',
            result: 'none',
            runtimeAttachment: 'loaded',
            source: 'bridgeRuntime',
            confidence: 'authoritative',
            observedAt: '2026-08-14T05:30:00.000Z',
            executionHost: 'bridge',
            controlState: 'writable',
            authorityGeneration: 'authority-restored-retry',
          ),
          metadata: metadata,
          metadataAvailable: true,
        );
        for (var attempt = 0; attempt < 50; attempt++) {
          if (_sentWireMessages(
            bridge,
          ).any((message) => message['type'] == 'input')) {
            break;
          }
          await tester.pump(const Duration(milliseconds: 10));
        }
        final inputMessages = _sentWireMessages(
          bridge,
        ).where((message) => message['type'] == 'input').toList();
        expect(inputMessages, hasLength(1));
        expect(inputMessages.single['clientMessageId'], clientMessageId);
        expect(inputMessages.single['images'], [
          {'base64': 'iVBORw==', 'mimeType': 'image/png'},
        ]);
        expect(drafts.getPendingSubmission(metadata.sessionId), isNotNull);

        bridge.emitMessage(
          const InputAckMessage(
            sessionId: 'attached-restored-runtime',
            clientMessageId: clientMessageId,
            stage: InputAckStage.bridgeAccepted,
          ),
          sessionId: 'attached-restored-runtime',
        );
        for (var attempt = 0; attempt < 50; attempt++) {
          if (drafts.getPendingSubmission(metadata.sessionId) == null) break;
          await tester.pump(const Duration(milliseconds: 10));
        }
        expect(cubit.isClosed, isFalse);
        final mountedCubit = BlocProvider.of<ChatSessionCubit>(
          tester.element(find.byKey(const ValueKey('message_input'))),
        );
        expect(identical(mountedCubit, cubit), isTrue);
        expect(drafts.getPendingSubmission(metadata.sessionId), isNull);
        expect(
          tester
              .widget<DurableSessionPreviewUpdater>(
                find.byType(DurableSessionPreviewUpdater),
              )
              .onLiveRuntimeReady,
          isNull,
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await sync.dispose();
        await repository.close();
        bridge.dispose();
        unawaited(sessionList.close());
      }
    },
  );

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
    'mounted durable page rebinds user history loaders for a new revision',
    (tester) async {
      final bridge = MockBridgeService();
      final streaming = StreamingStateCubit();
      Future<({List<UserInputMessage> messages, bool complete})?>
      oldLoader() async => (
        messages: const [
          UserInputMessage(
            text: 'old indexed prompt',
            providerItemId: 'old-item',
            historyTurnId: 'old-turn',
          ),
        ],
        complete: true,
      );
      Future<({List<UserInputMessage> messages, bool complete})?>
      newLoader() async => (
        messages: const [
          UserInputMessage(
            text: 'new indexed prompt',
            providerItemId: 'new-item',
            historyTurnId: 'new-turn',
          ),
        ],
        complete: true,
      );
      final cubit = ChatSessionCubit(
        sessionId: 'loader-thread',
        provider: Provider.codex,
        bridge: bridge,
        streamingCubit: streaming,
        detachedPreview: true,
        detachedUserMessageIndexLoader: oldLoader,
      );
      final revision = ValueNotifier('revision-old');
      addTearDown(revision.dispose);
      addTearDown(cubit.close);
      addTearDown(streaming.close);
      addTearDown(bridge.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: BlocProvider<ChatSessionCubit>.value(
            value: cubit,
            child: ValueListenableBuilder<String>(
              valueListenable: revision,
              builder: (context, value, _) => DurableSessionPreviewUpdater(
                revision: 'preview',
                messages: const [],
                hasEarlier: false,
                durableHistoryLoaderRevision: value,
                durableHistoryLoaderSourceFingerprint: 'source-loader',
                detachedUserMessageIndexLoader: value == 'revision-old'
                    ? oldLoader
                    : newLoader,
                child: const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        (await cubit.loadAllUserMessagesForNavigation()).single.text,
        'old indexed prompt',
      );

      revision.value = 'revision-new';
      await tester.pump();
      await tester.pump();

      expect(
        (await cubit.loadAllUserMessagesForNavigation()).single.text,
        'new indexed prompt',
      );
    },
  );

  testWidgets('live runtime callback retries after exact authority arrives', (
    tester,
  ) async {
    final bridge = MockBridgeService()
      ..advertisedBridgeCapabilities = const {conversationSyncV2Capability};
    final streaming = StreamingStateCubit();
    final cubit = ChatSessionCubit(
      sessionId: 'authority-retry-thread',
      provider: Provider.codex,
      bridge: bridge,
      streamingCubit: streaming,
      detachedPreview: true,
    );
    final sessionList = _ProjectionSessionListCubit(
      bridge: bridge,
      sourceFingerprint: 'authority-retry-source',
      status: const ConversationSyncV2Status(
        provider: 'codex',
        providerSessionId: 'authority-retry-thread',
        activity: 'idle',
        attention: 'none',
        result: 'none',
        runtimeAttachment: 'loaded',
        source: 'bridgeRuntime',
        confidence: 'authoritative',
        observedAt: '2026-08-14T05:00:00.000Z',
        executionHost: 'bridge',
        controlState: 'writable',
      ),
      metadata: const RecentSession(
        sessionId: 'authority-retry-thread',
        provider: 'codex',
        firstPrompt: 'Authority retry',
        created: '2026-08-14T05:00:00.000Z',
        modified: '2026-08-14T05:00:00.000Z',
        gitBranch: 'main',
        projectPath: '/authority-retry',
        isSidechain: false,
      ),
    );
    var callbackCount = 0;
    final callbackTargets = <String?>[];
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
          child: Scaffold(
            body: DurableSessionPreviewUpdater(
              revision: 'authority-retry-preview',
              messages: const [],
              hasEarlier: false,
              statusProvider: 'codex',
              statusProviderSessionId: 'authority-retry-thread',
              expectedSourceFingerprint: 'authority-retry-source',
              liveRuntimeSessionId: 'authority-retry-runtime',
              onLiveRuntimeReady: (cubit) {
                callbackCount += 1;
                final target = cubit.runtimeSessionIdForMutation();
                callbackTargets.add(target);
                return target != null;
              },
              child: const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(callbackCount, 1);
    expect(callbackTargets, [isNull]);
    expect(cubit.runtimeSessionIdForMutation(), isNull);

    sessionList.replace(
      sourceFingerprint: 'authority-retry-source',
      status: const ConversationSyncV2Status(
        provider: 'codex',
        providerSessionId: 'authority-retry-thread',
        activity: 'idle',
        attention: 'none',
        result: 'none',
        runtimeAttachment: 'loaded',
        source: 'bridgeRuntime',
        confidence: 'authoritative',
        observedAt: '2026-08-14T05:00:01.000Z',
        executionHost: 'bridge',
        controlState: 'writable',
        authorityGeneration: 'authority-retry-generation',
      ),
      metadata: sessionList.metadata,
      metadataAvailable: true,
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(cubit.runtimeSessionIdForMutation(), 'authority-retry-runtime');
    expect(callbackCount, 2);
    expect(callbackTargets, [isNull, 'authority-retry-runtime']);
  });

  testWidgets(
    'focused settings hydrate an already mounted cold Codex page in place',
    (tester) async {
      final bridge = MockBridgeService()
        ..advertisedBridgeCapabilities = const {conversationSyncV2Capability};
      final streaming = StreamingStateCubit();
      final cubit = ChatSessionCubit(
        sessionId: 'cold-thread',
        provider: Provider.codex,
        bridge: bridge,
        streamingCubit: streaming,
        detachedPreview: true,
      );
      final sessionList = _ProjectionSessionListCubit(
        bridge: bridge,
        sourceFingerprint: 'source-cold',
        projectionReady: true,
        metadataAvailable: false,
        status: const ConversationSyncV2Status(
          provider: 'codex',
          providerSessionId: 'cold-thread',
          activity: 'idle',
          attention: 'none',
          result: 'none',
          runtimeAttachment: 'notLoaded',
          source: 'appServer',
          confidence: 'authoritative',
          observedAt: '2026-08-08T01:00:00.000Z',
          executionHost: 'unknown',
          controlState: 'writable',
          authorityGeneration: 'cold-authority',
        ),
        metadata: const RecentSession(
          sessionId: 'cold-thread',
          provider: 'codex',
          firstPrompt: 'Cold thread',
          created: '2026-07-26T01:00:00.000Z',
          modified: '2026-07-26T01:00:00.000Z',
          gitBranch: 'main',
          projectPath: '/cold',
          isSidechain: false,
        ),
      );
      addTearDown(cubit.close);
      addTearDown(streaming.close);
      addTearDown(sessionList.close);
      addTearDown(bridge.dispose);

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          theme: AppTheme.lightTheme,
          home: MultiBlocProvider(
            providers: [
              BlocProvider<ChatSessionCubit>.value(value: cubit),
              BlocProvider<SessionListCubit>.value(value: sessionList),
            ],
            child: const Scaffold(
              body: DurableSessionPreviewUpdater(
                revision: 'cold-preview',
                messages: [],
                hasEarlier: false,
                statusProvider: 'codex',
                statusProviderSessionId: 'cold-thread',
                expectedSourceFingerprint: 'source-cold',
                child: SessionModeBar(),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(cubit.codexModelSettingsKnown, isFalse);
      expect(cubit.state.codexPermissionStateKnown, isFalse);
      expect(find.text('Unknown · waiting for sync'), findsNWidgets(2));

      sessionList.replace(
        sourceFingerprint: 'source-cold',
        status: sessionList.status,
        metadataAvailable: true,
        metadata: const RecentSession(
          sessionId: 'cold-thread',
          provider: 'codex',
          firstPrompt: 'Cold thread',
          created: '2026-07-26T01:00:00.000Z',
          // Focused hydration adds settings without changing recency.
          modified: '2026-07-26T01:00:00.000Z',
          gitBranch: 'main',
          projectPath: '/cold',
          isSidechain: false,
          codexModel: 'gpt-5.6-sol',
          codexModelReasoningEffort: 'ultra',
          codexServiceTier: 'standard',
          codexApprovalPolicy: 'never',
          codexApprovalsReviewer: 'user',
          codexSandboxMode: 'danger-full-access',
          codexCollaborationMode: 'plan',
          codexSettingsSnapshotComplete: true,
        ),
      );
      await tester.pump();
      // The catalog event applies Cubit state during this frame; render the
      // following scheduled frame to prove the still-mounted toolbar updates.
      await tester.pump();

      expect(cubit.codexModelSettingsKnown, isTrue);
      expect(cubit.state.codexModel, 'gpt-5.6-sol');
      expect(cubit.state.codexModelReasoningEffort, ReasoningEffort.ultra);
      expect(cubit.state.codexPermissionStateKnown, isTrue);
      expect(cubit.state.planMode, isTrue);
      final modelChip = tester.widget<CodexModelChip>(
        find.byType(CodexModelChip),
      );
      expect(modelChip.model, 'gpt-5.6-sol');
      expect(modelChip.reasoningEffort, ReasoningEffort.ultra);
      expect(modelChip.settingsKnown, isTrue);
      expect(find.text('Plan On'), findsOneWidget);
      expect(find.text('Unknown · waiting for sync'), findsNothing);
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
        projectionReady: true,
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

  testWidgets(
    'transient route canonicalization preserves durable facts but suspends control',
    (tester) async {
      final bridge = MockBridgeService()
        ..advertisedBridgeCapabilities = const {
          conversationSyncV2Capability,
          codexDurableThreadSettingsCapability,
        }
        ..authenticatedBridgeInstanceId = 'bridge-a'
        ..authenticatedCodexSourceId = 'source-a'
        ..authoritativeSessionList = true;
      final streaming = StreamingStateCubit();
      final cubit = ChatSessionCubit(
        sessionId: 'stable-thread',
        provider: Provider.codex,
        bridge: bridge,
        streamingCubit: streaming,
        detachedPreview: true,
        initialLiveRuntimeSessionId: 'runtime-a',
      );
      final sessionList = _ProjectionSessionListCubit(
        bridge: bridge,
        sourceFingerprint: 'canonical-a',
        projectionReady: true,
        status: const ConversationSyncV2Status(
          provider: 'codex',
          providerSessionId: 'stable-thread',
          activity: 'working',
          attention: 'none',
          result: 'none',
          runtimeAttachment: 'loaded',
          source: 'bridgeRuntime',
          confidence: 'authoritative',
          observedAt: '2026-08-03T01:00:00.000Z',
          executionHost: 'bridge',
          activeTurnId: 'turn-a',
          controlState: 'steerable',
          authorityGeneration: 'authority-a',
        ),
        metadata: const RecentSession(
          sessionId: 'stable-thread',
          provider: 'codex',
          firstPrompt: 'Stable settings',
          created: '2026-08-03T00:00:00.000Z',
          modified: '2026-08-03T01:00:00.000Z',
          gitBranch: 'main',
          projectPath: '/stable',
          isSidechain: false,
          codexModel: 'gpt-stable',
          codexModelReasoningEffort: 'high',
          codexServiceTier: 'standard',
          codexApprovalPolicy: 'never',
          codexApprovalsReviewer: 'user',
          codexSandboxMode: 'danger-full-access',
          codexCollaborationMode: 'default',
          codexSettingsSnapshotComplete: true,
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
              revision: 'stable-route',
              messages: [],
              hasEarlier: false,
              statusProvider: 'codex',
              statusProviderSessionId: 'stable-thread',
              expectedSourceFingerprint: 'canonical-a',
              liveRuntimeSessionId: 'runtime-a',
              child: SizedBox.shrink(),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(cubit.state.status, ProcessStatus.running);
      expect(cubit.state.codexModel, 'gpt-stable');
      expect(cubit.state.codexModelReasoningEffort, ReasoningEffort.high);
      expect(
        cubit.codexSettingsActionability,
        CodexSettingsActionability.editable,
      );

      sessionList.replace(
        sourceFingerprint: 'provisional-tailnet-route',
        projectionReady: false,
        status: sessionList.status,
        metadata: sessionList.metadata,
      );
      await tester.pump();

      expect(cubit.state.status, ProcessStatus.running);
      expect(cubit.state.codexModel, 'gpt-stable');
      expect(cubit.state.codexModelReasoningEffort, ReasoningEffort.high);
      expect(
        cubit.codexSettingsActionability,
        CodexSettingsActionability.waitingForRuntime,
      );
      expect(cubit.canMutateAttachedRuntime, isFalse);

      sessionList.replace(
        sourceFingerprint: 'canonical-a',
        projectionReady: true,
        status: const ConversationSyncV2Status(
          provider: 'codex',
          providerSessionId: 'stable-thread',
          activity: 'idle',
          attention: 'none',
          result: 'completed',
          runtimeAttachment: 'loaded',
          source: 'bridgeRuntime',
          confidence: 'authoritative',
          observedAt: '2026-08-03T01:01:00.000Z',
          executionHost: 'unknown',
          controlState: 'writable',
          authorityGeneration: 'authority-b',
        ),
        metadata: sessionList.metadata,
      );
      await tester.pump();

      expect(cubit.state.status, ProcessStatus.idle);
      expect(cubit.state.codexModel, 'gpt-stable');
      expect(
        cubit.codexSettingsActionability,
        CodexSettingsActionability.editable,
      );

      sessionList.replace(
        sourceFingerprint: 'canonical-other-source',
        projectionReady: true,
        status: sessionList.status,
        metadata: sessionList.metadata,
      );
      await tester.pump();

      expect(cubit.state.status, ProcessStatus.unknown);
      expect(cubit.state.codexModel, 'gpt-stable');
      expect(
        cubit.codexSettingsActionability,
        CodexSettingsActionability.waitingForRuntime,
      );
      expect(cubit.canMutateAttachedRuntime, isFalse);
    },
  );

  testWidgets(
    'detached Desktop approval and guarded question stay on the exact broker wire',
    (tester) async {
      final harness = _BrokerScreenHarness(
        status: _brokerScreenStatus(activeTurnId: 'turn-1'),
      );
      try {
        await tester.pumpWidget(await harness.build());
        await tester.pump();
        await tester.pump();
        final cubit = BlocProvider.of<ChatSessionCubit>(
          tester.element(find.byKey(const ValueKey('message_input'))),
        );
        final sourceFingerprint = harness.sync
            .cacheTargetFingerprintForDataSource(harness.identity);
        cubit.updateDetachedProviderStatus(
          harness.initialStatus,
          sourceFingerprint: sourceFingerprint,
        );
        await tester.pump();

        harness.bridge.emitLocalFeatureMessage(
          CodexActionBrokerEventMessage(
            event: CodexActionBrokerEventKind.snapshot,
            health: _brokerScreenHealth(),
            requests: [
              _brokerScreenRequest(
                opaqueRequestId: 'approval-screen-1',
                turnId: 'turn-1',
              ),
            ],
          ),
        );
        await tester.pump();

        expect(find.text('Command Approval'), findsOneWidget);
        final approveButton = tester.widget<FilledButton>(
          find.byKey(const ValueKey('approve_button')),
        );
        expect(approveButton.onPressed, isNotNull);
        approveButton.onPressed!.call();
        await tester.pump();
        for (var attempt = 0; attempt < 20; attempt++) {
          if (_sentWireMessages(
            harness.bridge,
          ).any((message) => message['type'] == 'respond_codex_action')) {
            break;
          }
          await tester.pump(const Duration(milliseconds: 10));
        }

        final approvalWire = _sentWireMessages(harness.bridge);
        final approvalResponses = approvalWire
            .where((message) => message['type'] == 'respond_codex_action')
            .toList(growable: false);
        expect(approvalResponses, hasLength(1));
        expect(
          approvalResponses.single['opaqueRequestId'],
          'approval-screen-1',
        );
        expect(
          approvalResponses.single['codexSourceId'],
          'source-broker-screen',
        );
        expect(approvalResponses.single['threadId'], 'thread-1');
        expect(approvalResponses.single['turnId'], 'turn-1');
        expect(
          approvalResponses.single['authorityGeneration'],
          'cab:generation-1',
        );
        expect(approvalResponses.single['action'], 'approve');
        expect(
          approvalWire.where((message) => message['type'] == 'approve'),
          isEmpty,
        );

        harness.bridge.emitLocalFeatureMessage(
          CodexActionBrokerEventMessage(
            event: CodexActionBrokerEventKind.snapshot,
            health: _brokerScreenHealth(),
            requests: [
              _brokerScreenRequest(
                opaqueRequestId: 'question-screen-1',
                turnId: 'old-turn',
                kind: CodexActionBrokerRequestKind.userInput,
              ),
            ],
          ),
        );
        await tester.pump();

        final question = find.text('Continue?');
        expect(question, findsOneWidget);
        expect(
          tester
              .widget<CodexActionBrokerInteractionFrame>(
                find.byType(CodexActionBrokerInteractionFrame),
              )
              .phase,
          CodexActionBrokerInteractionPhase.stale,
        );
        expect(
          find.textContaining(
            'The turn or data source changed. Refreshing the request',
          ),
          findsOneWidget,
        );
        expect(
          tester
              .widget<IgnorePointer>(
                find.byKey(
                  const ValueKey('codex_action_broker_interaction_guard'),
                ),
              )
              .ignoring,
          isTrue,
        );
        expect(
          _sentWireMessages(
            harness.bridge,
          ).where((message) => message['type'] == 'respond_codex_action'),
          hasLength(1),
        );

        cubit.updateDetachedProviderStatus(
          _brokerScreenStatus(
            activeTurnId: 'old-turn',
            observedAt: '2026-08-01T00:02:00.000Z',
          ),
          sourceFingerprint: sourceFingerprint,
        );
        await tester.pump();
        await tester.pump();

        expect(
          tester
              .widget<CodexActionBrokerInteractionFrame>(
                find.byType(CodexActionBrokerInteractionFrame),
              )
              .phase,
          CodexActionBrokerInteractionPhase.actionable,
        );

        expect(
          tester
              .widget<IgnorePointer>(
                find.byKey(
                  const ValueKey('codex_action_broker_interaction_guard'),
                ),
              )
              .ignoring,
          isFalse,
        );
        final questionWidget = tester.widget<AskUserQuestionWidget>(
          find.byType(AskUserQuestionWidget),
        );
        expect(questionWidget.toolUseId, 'question-screen-1');
        questionWidget.onAnswer(questionWidget.toolUseId, 'continue');
        await tester.pump();
        for (var attempt = 0; attempt < 20; attempt++) {
          if (_sentWireMessages(harness.bridge)
                  .where((message) => message['type'] == 'respond_codex_action')
                  .length >=
              2) {
            break;
          }
          await tester.pump(const Duration(milliseconds: 10));
        }

        final wire = _sentWireMessages(harness.bridge);
        final responses = wire
            .where((message) => message['type'] == 'respond_codex_action')
            .toList(growable: false);
        expect(responses, hasLength(2));
        expect(responses.last['opaqueRequestId'], 'question-screen-1');
        expect(responses.last['codexSourceId'], 'source-broker-screen');
        expect(responses.last['threadId'], 'thread-1');
        expect(responses.last['turnId'], 'old-turn');
        expect(responses.last['authorityGeneration'], 'cab:generation-1');
        expect(responses.last['action'], 'answer');
        expect(responses.last['answer'], 'continue');
        expect(wire.where((message) => message['type'] == 'answer'), isEmpty);
      } finally {
        await harness.dispose(tester);
      }
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
            windowComplete: true,
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
    'different IP route authentication preserves the chat state subtree',
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
      final provisionalSnapshot = _previewSnapshot(
        partitionId: provisionalTarget.fingerprint,
        providerSessionId: 'durable-upgrade-thread',
        revision: 'provisional-revision',
        entryId: 'provisional-entry',
        text: 'Provisional cached turn',
      );
      final authenticatedSnapshot = _previewSnapshot(
        partitionId: authenticatedTarget.fingerprint,
        providerSessionId: 'durable-upgrade-thread',
        revision: 'authenticated-revision',
        entryId: 'authenticated-entry',
        text: 'Authenticated cached turn',
      );
      final authenticatedRead = Completer<ConversationHotWindowSnapshot?>();
      final repository = _CountingSessionCatalogCacheRepository(
        SessionCatalogCacheDatabase(databasePath: 'unused-upgrade-cache.db'),
        snapshots: {
          provisionalTarget.fingerprint: provisionalSnapshot,
          authenticatedTarget.fingerprint: authenticatedSnapshot,
        },
        queuedReads: [
          Future.value(provisionalSnapshot),
          authenticatedRead.future,
        ],
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
          ..authenticatedCodexSourceId = 'source-authenticated-upgrade'
          ..mockLogicalConnectionIdentity = 'machine:tailnet-upgrade'
          ..mockLastUrl = 'wss://100.94.144.77:8765';
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

        // The stable identity read is deliberately still blocked. The route
        // and authenticated source have already been confirmed, so the last
        // committed route-keyed cache must stay visible rather than flashing a
        // loader or an empty latest turn.
        expect(find.text('Provisional cached turn'), findsOneWidget);
        expect(find.text('Authenticated cached turn'), findsNothing);

        authenticatedRead.complete(authenticatedSnapshot);
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
    'open durable Codex page follows one current runtime and rejects ambiguity',
    (tester) async {
      final bridge = MockBridgeService()
        ..authenticatedBridgeInstanceId = 'bridge-runtime-rebind'
        ..authenticatedCodexSourceId = 'source-runtime-rebind'
        ..advertisedBridgeCapabilities = const {conversationSyncV2Capability};
      const durableThreadId = 'durable-runtime-rebind';

      const runtimeA = SessionInfo(
        id: 'runtime-rebind-a',
        provider: 'codex',
        projectPath: '/workspace/runtime-rebind',
        claudeSessionId: durableThreadId,
        status: 'idle',
        createdAt: '2026-08-01T00:00:00.000Z',
        lastActivityAt: '2026-08-01T00:00:00.000Z',
      );
      const runtimeB = SessionInfo(
        id: 'runtime-rebind-b',
        provider: 'codex',
        projectPath: '/workspace/runtime-rebind',
        claudeSessionId: durableThreadId,
        status: 'working',
        createdAt: '2026-08-01T00:01:00.000Z',
        lastActivityAt: '2026-08-01T00:01:00.000Z',
      );
      const runtimeC = SessionInfo(
        id: 'runtime-rebind-c',
        provider: 'codex',
        projectPath: '/workspace/runtime-rebind',
        claudeSessionId: durableThreadId,
        status: 'working',
        createdAt: '2026-08-01T00:02:00.000Z',
        lastActivityAt: '2026-08-01T00:02:00.000Z',
      );

      try {
        await tester.pumpWidget(
          await buildTestCodexSessionScreen(
            bridge: bridge,
            sessionId: 'pending-runtime-rebind',
            projectPath: '/workspace/runtime-rebind',
            isPending: true,
            durableProviderSessionId: durableThreadId,
            dataSourceIdentity: bridge.dataSourceIdentity,
          ),
        );
        await tester.pump();
        await tester.pump();

        final inputFinder = find.byKey(const ValueKey('message_input'));
        final cubit = BlocProvider.of<ChatSessionCubit>(
          tester.element(inputFinder),
        );
        expect(cubit.detachedLiveRuntimeSessionId, isNull);

        bridge.emitSessionList(const [runtimeA]);
        await tester.pump();
        await tester.pump();
        expect(cubit.detachedLiveRuntimeSessionId, runtimeA.id);

        bridge.emitMessage(
          const UserInputMessage(
            text: 'Runtime A live message',
            userMessageUuid: 'runtime-a-live-message',
          ),
          sessionId: runtimeA.id,
        );
        await tester.pump();
        expect(
          cubit.state.entries.whereType<UserChatEntry>().map(
            (entry) => entry.text,
          ),
          contains('Runtime A live message'),
        );

        bridge.emitSessionList(const [runtimeB]);
        await tester.pump();
        await tester.pump();
        expect(cubit.detachedLiveRuntimeSessionId, runtimeB.id);

        bridge.emitMessage(
          const UserInputMessage(
            text: 'Stale runtime A message',
            userMessageUuid: 'runtime-a-stale-message',
          ),
          sessionId: runtimeA.id,
        );
        bridge.emitMessage(
          const UserInputMessage(
            text: 'Runtime B live message',
            userMessageUuid: 'runtime-b-live-message',
          ),
          sessionId: runtimeB.id,
        );
        await tester.pump();
        final userTexts = cubit.state.entries
            .whereType<UserChatEntry>()
            .map((entry) => entry.text)
            .toList(growable: false);
        expect(userTexts, isNot(contains('Stale runtime A message')));
        expect(userTexts, contains('Runtime B live message'));

        bridge.emitSessionList(const [runtimeB, runtimeC]);
        await tester.pump();
        await tester.pump();
        expect(cubit.detachedLiveRuntimeSessionId, isNull);
        expect(cubit.canMutateAttachedRuntime, isFalse);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
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
      final secondRead = Completer<ConversationHotWindowSnapshot?>();
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
        queuedReads: [firstRead.future, secondRead.future],
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

        // The database commit epoch advances before its broadcast listener is
        // delivered. The in-flight stale read must still be rejected.
        sync.advanceCacheCommitEpoch(
          targetFingerprint: target.fingerprint,
          provider: Provider.codex.value,
          providerSessionId: 'durable-thread-race',
        );
        firstRead.complete(staleSnapshot);
        await tester.pump();
        expect(find.text('Stale cached turn'), findsNothing);
        expect(find.text('Committed cached turn'), findsNothing);

        for (
          var attempt = 0;
          attempt < 10 && repository.loadConversationWindowCalls < 2;
          attempt++
        ) {
          await tester.pump();
        }
        expect(repository.loadConversationWindowCalls, 2);

        secondRead.complete(committedSnapshot);
        for (
          var attempt = 0;
          attempt < 10 && find.text('Committed cached turn').evaluate().isEmpty;
          attempt++
        ) {
          await tester.pump();
        }

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
    'unrelated timeline commits do not starve a focused cache preview read',
    (tester) async {
      final bridge = MockBridgeService()
        ..authenticatedBridgeInstanceId = 'bridge-unrelated-commit'
        ..authenticatedCodexSourceId = 'codex-source-unrelated-commit'
        ..mockLogicalConnectionIdentity = 'machine:unrelated-commit'
        ..mockLastUrl = 'wss://unrelated-commit.test/socket';
      final target = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: bridge.authenticatedBridgeInstanceId,
        codexSourceId: bridge.authenticatedCodexSourceId,
      );
      final focusedRead = Completer<ConversationHotWindowSnapshot?>();
      final focusedSnapshot = _previewSnapshot(
        partitionId: target.fingerprint,
        providerSessionId: 'focused-thread',
        revision: 'focused-revision',
        entryId: 'focused-entry',
        text: 'Focused cached turn remains visible',
      );
      final repository = _CountingSessionCatalogCacheRepository(
        SessionCatalogCacheDatabase(databasePath: 'unused-unrelated-cache.db'),
        snapshots: const {},
        queuedReads: [focusedRead.future],
      );
      final sync = _ControllableConversationContentSyncService(
        bridge: BridgeServiceConversationContentSyncGateway(bridge),
        cache: repository,
      );

      try {
        await tester.pumpWidget(
          await buildTestCodexSessionScreen(
            bridge: bridge,
            sessionId: 'pending-focused-runtime',
            isPending: true,
            durableProviderSessionId: 'focused-thread',
            dataSourceIdentity: bridge.dataSourceIdentity,
            conversationContentSync: sync,
          ),
        );
        await tester.pump();
        expect(repository.loadConversationWindowCalls, 1);

        for (var index = 0; index < 20; index += 1) {
          sync.emitTimelineCommit(
            provider: Provider.codex.value,
            providerSessionId: 'background-thread-$index',
            revision: 'background-revision-$index',
            targetFingerprint: target.fingerprint,
          );
        }
        focusedRead.complete(focusedSnapshot);
        for (
          var attempt = 0;
          attempt < 10 &&
              find
                  .text('Focused cached turn remains visible')
                  .evaluate()
                  .isEmpty;
          attempt++
        ) {
          await tester.pump();
        }

        expect(
          find.text('Focused cached turn remains visible'),
          findsOneWidget,
        );
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
    'switching durable targets rebinds the preview while the old read is in flight',
    (tester) async {
      final bridge = MockBridgeService()
        ..authenticatedBridgeInstanceId = 'bridge-target-switch'
        ..authenticatedCodexSourceId = 'codex-source-target-switch'
        ..mockLogicalConnectionIdentity = 'machine:target-switch'
        ..mockLastUrl = 'wss://target-switch.test/socket';
      final target = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: bridge.authenticatedBridgeInstanceId,
        codexSourceId: bridge.authenticatedCodexSourceId,
      );
      final oldRead = Completer<ConversationHotWindowSnapshot?>();
      final oldSnapshot = _previewSnapshot(
        partitionId: target.fingerprint,
        providerSessionId: 'old-thread',
        revision: 'old-revision',
        entryId: 'old-entry',
        text: 'Old target must stay hidden',
      );
      final newSnapshot = _previewSnapshot(
        partitionId: target.fingerprint,
        providerSessionId: 'new-thread',
        revision: 'new-revision',
        entryId: 'new-entry',
        text: 'New target is visible',
      );
      final repository = _CountingSessionCatalogCacheRepository(
        SessionCatalogCacheDatabase(databasePath: 'unused-target-switch.db'),
        snapshots: const {},
        queuedReads: [oldRead.future, Future.value(newSnapshot)],
      );
      final sync = _ControllableConversationContentSyncService(
        bridge: BridgeServiceConversationContentSyncGateway(bridge),
        cache: repository,
      );

      Future<Widget> build(String durableId) => buildTestCodexSessionScreen(
        bridge: bridge,
        sessionId: 'pending-$durableId',
        isPending: true,
        durableProviderSessionId: durableId,
        dataSourceIdentity: bridge.dataSourceIdentity,
        conversationContentSync: sync,
      );

      try {
        await tester.pumpWidget(await build('old-thread'));
        await tester.pump();
        expect(repository.loadConversationWindowCalls, 1);

        await tester.pumpWidget(await build('new-thread'));
        for (
          var attempt = 0;
          attempt < 10 && find.text('New target is visible').evaluate().isEmpty;
          attempt++
        ) {
          await tester.pump();
        }
        expect(repository.loadConversationWindowCalls, 2);
        expect(find.text('New target is visible'), findsOneWidget);

        oldRead.complete(oldSnapshot);
        await tester.pump();
        await tester.pump();
        expect(find.text('Old target must stay hidden'), findsNothing);
        expect(find.text('New target is visible'), findsOneWidget);
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
    'a pending Codex preview cannot apply after the runtime attaches',
    (tester) async {
      final bridge = MockBridgeService()
        ..authenticatedBridgeInstanceId = 'bridge-codex-attach-race'
        ..authenticatedCodexSourceId = 'codex-source-attach-race'
        ..mockLogicalConnectionIdentity = 'machine:codex-attach-race'
        ..mockLastUrl = 'wss://codex-attach-race.test/socket';
      final target = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: bridge.authenticatedBridgeInstanceId,
        codexSourceId: bridge.authenticatedCodexSourceId,
      );
      final pendingRead = Completer<ConversationHotWindowSnapshot?>();
      final staleSnapshot = _previewSnapshot(
        partitionId: target.fingerprint,
        providerSessionId: 'codex-attach-thread',
        revision: 'codex-stale-revision',
        entryId: 'codex-stale-entry',
        text: 'Detached Codex preview must not overwrite attached runtime',
      );
      final repository = _CountingSessionCatalogCacheRepository(
        SessionCatalogCacheDatabase(databasePath: 'unused-codex-attach.db'),
        snapshots: const {},
        queuedReads: [pendingRead.future],
      );
      final sync = _ControllableConversationContentSyncService(
        bridge: BridgeServiceConversationContentSyncGateway(bridge),
        cache: repository,
      );
      final pendingSessionCreated = ValueNotifier<SystemMessage?>(null);

      Future<Widget> build() => buildTestCodexSessionScreen(
        bridge: bridge,
        sessionId: 'pending-codex-runtime',
        isPending: true,
        durableProviderSessionId: 'codex-attach-thread',
        pendingSessionCreated: pendingSessionCreated,
        dataSourceIdentity: bridge.dataSourceIdentity,
        conversationContentSync: sync,
      );

      try {
        await tester.pumpWidget(await build());
        await tester.pump();
        expect(repository.loadConversationWindowCalls, 1);

        pendingSessionCreated.value = const SystemMessage(
          subtype: 'session_created',
          sessionId: 'attached-runtime',
        );
        await tester.pump();
        pendingRead.complete(staleSnapshot);
        await tester.pump();
        await tester.pump();

        expect(repository.loadConversationWindowCalls, 1);
        expect(
          find.text(
            'Detached Codex preview must not overwrite attached runtime',
          ),
          findsNothing,
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await sync.dispose();
        await repository.close();
        pendingSessionCreated.dispose();
        bridge.dispose();
      }
    },
  );

  testWidgets(
    'an attached Claude runtime does not start the detached cache preview loop',
    (tester) async {
      final bridge = MockBridgeService()
        ..authenticatedBridgeInstanceId = 'bridge-active-claude'
        ..mockLogicalConnectionIdentity = 'machine:active-claude'
        ..mockLastUrl = 'wss://active-claude.test/socket';
      final target = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: bridge.authenticatedBridgeInstanceId,
      );
      final repository = _CountingSessionCatalogCacheRepository(
        SessionCatalogCacheDatabase(databasePath: 'unused-active-claude.db'),
        snapshots: {
          target.fingerprint: _previewSnapshot(
            partitionId: target.fingerprint,
            provider: Provider.claude.value,
            providerSessionId: 'active-claude-thread',
            revision: 'active-claude-cache',
            entryId: 'active-claude-entry',
            text: 'Detached cache must not replace the attached runtime',
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
            sessionId: 'active-claude-runtime',
            isPending: false,
            durableProviderSessionId: 'active-claude-thread',
            dataSourceIdentity: bridge.dataSourceIdentity,
            conversationContentSync: sync,
          ),
        );
        for (var index = 0; index < 5; index += 1) {
          await tester.pump();
        }

        expect(repository.loadConversationWindowCalls, 0);
        expect(
          find.text('Detached cache must not replace the attached runtime'),
          findsNothing,
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
    'a pending Claude preview cannot apply after the runtime attaches',
    (tester) async {
      final bridge = MockBridgeService()
        ..authenticatedBridgeInstanceId = 'bridge-claude-attach-race'
        ..mockLogicalConnectionIdentity = 'machine:claude-attach-race'
        ..mockLastUrl = 'wss://claude-attach-race.test/socket';
      final target = SessionCatalogCacheTarget.fromBridge(
        bridgeInstanceId: bridge.authenticatedBridgeInstanceId,
      );
      final pendingRead = Completer<ConversationHotWindowSnapshot?>();
      final staleSnapshot = _previewSnapshot(
        partitionId: target.fingerprint,
        provider: Provider.claude.value,
        providerSessionId: 'claude-attach-thread',
        revision: 'claude-stale-revision',
        entryId: 'claude-stale-entry',
        text: 'Detached preview must not overwrite attached runtime',
      );
      final repository = _CountingSessionCatalogCacheRepository(
        SessionCatalogCacheDatabase(databasePath: 'unused-claude-attach.db'),
        snapshots: const {},
        queuedReads: [pendingRead.future],
      );
      final sync = _ControllableConversationContentSyncService(
        bridge: BridgeServiceConversationContentSyncGateway(bridge),
        cache: repository,
      );

      Future<Widget> build({required bool pending}) =>
          buildTestClaudeSessionScreen(
            bridge: bridge,
            sessionId: pending ? 'pending-claude-runtime' : 'attached-runtime',
            isPending: pending,
            durableProviderSessionId: 'claude-attach-thread',
            dataSourceIdentity: bridge.dataSourceIdentity,
            conversationContentSync: sync,
          );

      try {
        await tester.pumpWidget(await build(pending: true));
        await tester.pump();
        expect(repository.loadConversationWindowCalls, 1);

        await tester.pumpWidget(await build(pending: false));
        await tester.pump();
        pendingRead.complete(staleSnapshot);
        await tester.pump();
        await tester.pump();

        expect(repository.loadConversationWindowCalls, 1);
        expect(
          find.text('Detached preview must not overwrite attached runtime'),
          findsNothing,
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
        // The wire contract advances contentHash whenever the normalized
        // message changes. Keep the fixture faithful so metadata-only commits
        // can be distinguished from actual presentation updates.
        contentHash: 'hash-$entryId-${text.hashCode}',
        rawMessage: {
          'type': 'user_input',
          'text': text,
          'userMessageUuid': entryId,
        },
      ),
    ],
    hasEarlier: false,
    turnsNextCursor: null,
    windowComplete: true,
    latestTurnComplete: true,
    latestTurnGap: null,
    latestTurnGapCursor: null,
    sourceEntryCount: 1,
    cachedAt: DateTime.utc(2026, 7, 31),
  );
}

class _LatestTurnRecoveryHarness {
  _LatestTurnRecoveryHarness({
    required this.provider,
    required bool latestTurnComplete,
    required List<ConversationContentWireEntry> entries,
    required this.repairResponses,
  }) {
    final id = ++_nextId;
    bridge = MockBridgeService()
      ..authenticatedBridgeInstanceId = 'bridge-latest-turn-$id'
      ..authenticatedCodexSourceId = provider == Provider.codex.value
          ? 'source-latest-turn-$id'
          : null
      ..advertisedBridgeCapabilities = const {conversationSyncV2Capability};
    identity = bridge.dataSourceIdentity;
    final target = SessionCatalogCacheTarget.fromBridge(
      bridgeInstanceId: bridge.authenticatedBridgeInstanceId,
      codexSourceId: bridge.authenticatedCodexSourceId,
    );
    providerSessionId = 'latest-turn-session-$id';
    repository = _CountingSessionCatalogCacheRepository(
      SessionCatalogCacheDatabase(databasePath: 'unused-latest-turn-$id.db'),
      snapshots: {
        target.fingerprint: ConversationHotWindowSnapshot(
          partitionId: target.fingerprint,
          provider: provider,
          providerSessionId: providerSessionId,
          revision: 'latest-turn-revision-$id',
          entries: entries,
          hasEarlier: false,
          turnsNextCursor: null,
          windowComplete: true,
          latestTurnComplete: latestTurnComplete,
          latestTurnGap: latestTurnComplete
              ? null
              : const ConversationSyncV2LatestTurnGap(
                  missingEntryCount: 1,
                  payloadOmitted: true,
                  repair: 'turns_page',
                ),
          latestTurnGapCursor: null,
          sourceEntryCount: entries.length,
          cachedAt: DateTime.utc(2026, 8, 7),
        ),
      },
    );
    sync = _LatestTurnRecoverySyncService(
      bridge: BridgeServiceConversationContentSyncGateway(bridge),
      cache: repository,
      repairResponses: repairResponses,
    );
  }

  static int _nextId = 0;

  final String provider;
  final List<Future<ConversationTurnsPageLoadResult>> repairResponses;
  late final String providerSessionId;
  late final MockBridgeService bridge;
  late final BridgeDataSourceIdentity identity;
  late final _CountingSessionCatalogCacheRepository repository;
  late final _LatestTurnRecoverySyncService sync;

  Future<Widget> build() {
    if (provider == Provider.codex.value) {
      return buildTestCodexSessionScreen(
        bridge: bridge,
        sessionId: 'pending-latest-turn-runtime',
        isPending: true,
        durableProviderSessionId: providerSessionId,
        dataSourceIdentity: identity,
        conversationContentSync: sync,
      );
    }
    return buildTestClaudeSessionScreen(
      bridge: bridge,
      sessionId: 'pending-latest-turn-runtime',
      isPending: true,
      durableProviderSessionId: providerSessionId,
      dataSourceIdentity: identity,
      conversationContentSync: sync,
    );
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await sync.dispose();
    await repository.close();
    bridge.dispose();
  }
}

class _LatestTurnRecoverySyncService extends ConversationContentSyncService {
  _LatestTurnRecoverySyncService({
    required super.bridge,
    required super.cache,
    required this.repairResponses,
  });

  final List<Future<ConversationTurnsPageLoadResult>> repairResponses;
  int latestTurnRepairCalls = 0;

  @override
  Future<ConversationTurnsPageLoadResult> repairLatestTurn({
    required String provider,
    required String providerSessionId,
    BridgeDataSourceIdentity? expectedDataSourceIdentity,
  }) {
    latestTurnRepairCalls++;
    if (repairResponses.isEmpty) {
      return Future<ConversationTurnsPageLoadResult>.value(
        const ConversationTurnsPageLoadResult(loaded: false, hasMore: false),
      );
    }
    return repairResponses.removeAt(0);
  }
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
  int _testCacheCommitEpoch = 0;
  final Map<String, int> _testCacheCommitEpochsByConversation = {};

  @override
  Stream<ConversationContentCacheUpdate> get updates => _testUpdates.stream;

  @override
  int get cacheCommitEpoch => _testCacheCommitEpoch;

  @override
  int cacheCommitEpochFor({
    required String targetFingerprint,
    required String provider,
    required String providerSessionId,
  }) =>
      _testCacheCommitEpochsByConversation['$targetFingerprint\u0000$provider\u0000$providerSessionId'] ??
      0;

  void advanceCacheCommitEpoch({
    required String targetFingerprint,
    required String provider,
    required String providerSessionId,
  }) {
    _testCacheCommitEpoch += 1;
    final key = '$targetFingerprint\u0000$provider\u0000$providerSessionId';
    _testCacheCommitEpochsByConversation[key] =
        (_testCacheCommitEpochsByConversation[key] ?? 0) + 1;
  }

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
    final fingerprint = targetFingerprint ?? currentCacheTargetFingerprint;
    advanceCacheCommitEpoch(
      targetFingerprint: fingerprint,
      provider: provider,
      providerSessionId: providerSessionId,
    );
    _testUpdates.add(
      ConversationContentCacheUpdate(
        targetFingerprint: fingerprint,
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
    this.metadataAvailable = true,
    this.projectionReady = false,
  });

  final StreamController<void> _changes = StreamController<void>.broadcast();
  String sourceFingerprint;
  ConversationSyncV2Status status;
  RecentSession metadata;
  bool metadataAvailable;
  bool projectionReady;

  @override
  bool get hasUsableCatalogForCurrentTarget => projectionReady;

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
  ) =>
      metadataAvailable &&
          provider == metadata.provider &&
          providerSessionId == metadata.sessionId
      ? metadata
      : null;

  void replace({
    required String sourceFingerprint,
    required ConversationSyncV2Status status,
    required RecentSession metadata,
    bool? metadataAvailable,
    bool? projectionReady,
  }) {
    this.sourceFingerprint = sourceFingerprint;
    this.status = status;
    this.metadata = metadata;
    this.metadataAvailable = metadataAvailable ?? this.metadataAvailable;
    this.projectionReady = projectionReady ?? this.projectionReady;
    _changes.add(null);
  }

  @override
  Future<void> close() async {
    await _changes.close();
    await super.close();
  }
}

class _BrokerScreenHarness {
  _BrokerScreenHarness({required ConversationSyncV2Status status}) {
    bridge = MockBridgeService()
      ..authenticatedBridgeInstanceId = 'bridge-broker-screen'
      ..authenticatedCodexSourceId = 'source-broker-screen'
      ..mockLogicalConnectionIdentity = 'machine:broker-screen'
      ..mockLastUrl = 'wss://broker-screen.test/socket'
      ..advertisedBridgeCapabilities = const {
        codexActionBrokerBridgeCapability,
      };
    identity = bridge.dataSourceIdentity;
    repository = _CountingSessionCatalogCacheRepository(
      SessionCatalogCacheDatabase(
        databasePath: 'unused-broker-screen-cache.db',
      ),
      snapshots: const {},
    );
    sync = ConversationContentSyncService(
      bridge: BridgeServiceConversationContentSyncGateway(bridge),
      cache: repository,
    );
    initialStatus = status;
  }

  late final MockBridgeService bridge;
  late final BridgeDataSourceIdentity identity;
  late final _CountingSessionCatalogCacheRepository repository;
  late final ConversationContentSyncService sync;
  late final ConversationSyncV2Status initialStatus;

  Future<Widget> build() => buildTestCodexSessionScreen(
    bridge: bridge,
    sessionId: 'runtime-thread-1',
    durableProviderSessionId: 'thread-1',
    dataSourceIdentity: identity,
    conversationContentSync: sync,
  );

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await sync.dispose();
    await repository.close();
    bridge.dispose();
  }
}

ConversationSyncV2Status _brokerScreenStatus({
  required String activeTurnId,
  String attention = 'approval',
  String observedAt = '2026-08-01T00:01:00.000Z',
}) => ConversationSyncV2Status(
  provider: 'codex',
  providerSessionId: 'thread-1',
  activity: 'working',
  attention: attention,
  result: 'none',
  runtimeAttachment: 'loaded',
  source: 'appServer',
  confidence: 'authoritative',
  observedAt: observedAt,
  executionHost: 'desktopAppServer',
  activeTurnId: activeTurnId,
  controlState: 'writable',
  authorityGeneration: 'daemon:runtime-uuid-1',
);

CodexActionBrokerHealth _brokerScreenHealth() => const CodexActionBrokerHealth(
  ready: true,
  controlReady: true,
  degraded: false,
  writerLeaseHeld: true,
  authorityGeneration: 'cab:generation-1',
);

CodexActionBrokerRequest _brokerScreenRequest({
  required String opaqueRequestId,
  required String turnId,
  CodexActionBrokerRequestKind kind =
      CodexActionBrokerRequestKind.commandApproval,
}) => CodexActionBrokerRequest(
  opaqueRequestId: opaqueRequestId,
  codexSourceId: 'source-broker-screen',
  threadId: 'thread-1',
  turnId: turnId,
  kind: kind,
  state: CodexActionBrokerRequestState.pending,
  observedAt: DateTime.utc(2026, 8, 1),
  expiresAt: DateTime.utc(2026, 8, 1, 0, 5),
  updatedAt: DateTime.utc(2026, 8, 1, 0, 0, 1),
  authorityGeneration: 'cab:generation-1',
  live: true,
  toolName: kind == CodexActionBrokerRequestKind.commandApproval
      ? 'Bash'
      : null,
  input: kind == CodexActionBrokerRequestKind.userInput
      ? const {
          'questions': [
            {
              'id': 'question-1',
              'question': 'Continue?',
              'header': 'Choice',
              'options': [
                {'label': 'Continue', 'value': 'continue'},
              ],
              'multiSelect': false,
            },
          ],
        }
      : const {'command': 'echo broker-screen'},
  allowedActions: kind == CodexActionBrokerRequestKind.userInput
      ? const {
          CodexActionBrokerDecision.answer,
          CodexActionBrokerDecision.reject,
        }
      : const {
          CodexActionBrokerDecision.approve,
          CodexActionBrokerDecision.reject,
        },
);

List<Map<String, dynamic>> _sentWireMessages(MockBridgeService bridge) => bridge
    .sentMessages
    .map((message) => jsonDecode(message.toJson()) as Map<String, dynamic>)
    .toList(growable: false);
