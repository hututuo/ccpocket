import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ccpocket/features/chat_session/state/chat_session_cubit.dart';
import 'package:ccpocket/features/chat_session/state/streaming_state.dart';
import 'package:ccpocket/features/chat_session/state/streaming_state_cubit.dart';
import 'package:ccpocket/features/chat_session/widgets/chat_process_layout.dart';
import 'package:ccpocket/features/chat_session/widgets/durable_session_preview.dart';
import 'package:ccpocket/features/conversation_content_sync/conversation_content_sync_service.dart';
import 'package:ccpocket/features/session_list/cache/session_catalog_cache_database.dart';
import 'package:ccpocket/features/session_list/cache/session_catalog_cache_repository.dart';
import 'package:ccpocket/features/session_list/state/session_list_cubit.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'harness_ready.dart';

// Use the SDK HTTP client for the isolated loopback WebSocket fixture.
class _ReceiverHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  testWidgets(
    'real receiver mounts the production updater and restores committed SQLite content',
    (tester) async {
      // Only this synthetic loopback fixture bypasses widget HTTP mocks. Real
      // async execution lets its sockets, SQLite isolate and timers progress.
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          SharedPreferences.setMockInitialValues(const {});
          final repositoryRoot = path.normalize(
            path.absolute(Directory.current.path, '..', '..'),
          );
          final harnessPath = path.join(
            repositoryRoot,
            'packages',
            'bridge',
            'scripts',
            'conversation-live-segment-harness.mjs',
          );
          final builtBridge = path.join(
            repositoryRoot,
            'packages',
            'bridge',
            'dist',
            'websocket.js',
          );
          expect(
            File(builtBridge).existsSync(),
            isTrue,
            reason: 'Run npm run bridge:build before the headless chain test.',
          );

          final node = Platform.environment['CCPOCKET_NODE'] ?? 'node';
          final harness = await Process.start(node, [
            harnessPath,
          ], workingDirectory: repositoryRoot);
          final harnessReady = await waitForHarnessReady(harness);
          final readyLine = harnessReady.readyLine;
          final ready =
              jsonDecode(readyLine.substring(6)) as Map<String, dynamic>;
          final url = ready['url']! as String;
          final threadId = ready['threadId']! as String;
          final turnId = ready['turnId']! as String;
          final projectPath = ready['projectPath']! as String;
          final traceRoot = ready['traceRoot']! as String;

          final temporaryDirectory = await Directory.systemTemp.createTemp(
            'ccpocket_live_segment_receiver_',
          );
          Future<Database> openFfi(
            String databasePath,
            OpenDatabaseOptions options,
          ) => databaseFactoryFfi.openDatabase(databasePath, options: options);
          final databasePath = path.join(temporaryDirectory.path, 'cache.db');
          final repository = SessionCatalogCacheRepository(
            SessionCatalogCacheDatabase(
              databasePath: databasePath,
              openDatabase: openFfi,
            ),
          );
          final bridge = BridgeService(
            clientAppVersion: 'headless-live-segment-receiver',
          );
          final sync = ConversationContentSyncService(
            bridge: BridgeServiceConversationContentSyncGateway(bridge),
            cache: repository,
          )..start(initialLifecycleState: AppLifecycleState.resumed);
          final sessionList = SessionListCubit(
            bridge: bridge,
            catalogCache: repository,
            conversationSync: sync,
          );
          StreamingStateCubit? streaming;
          ChatSessionCubit? chat;
          SessionCatalogCacheRepository? reopenedRepository;
          BridgeService? offlineBridge;
          var sessionListClosed = false;
          StreamSubscription<ServerMessage>? runtimeWireSub;
          StreamSubscription<StreamingState>? streamingTraceSub;
          final receiverTrace = <Map<String, Object?>>[];
          final runtimeWireTypes = <String>[];
          final streamingTransitions = <Map<String, Object?>>[];

          SessionCatalogCacheTarget cacheTarget() =>
              SessionCatalogCacheTarget.fromBridge(
                bridgeInstanceId: bridge.bridgeInstanceId,
                codexSourceId: bridge.codexSourceId,
                logicalConnectionIdentity: bridge.logicalConnectionIdentity,
                websocketUrl: bridge.lastUrl,
              );

          Future<ConversationHotWindowSnapshot> waitForTimelineCommit(
            int count, {
            required Map<String, String> expectedAssistants,
            required bool latestTurnComplete,
            String? previousRevision,
          }) async {
            final completer = Completer<ConversationHotWindowSnapshot>();
            Map<String, Object?>? lastObserved;
            Future<void> inspect(ConversationSyncCacheUpdate update) async {
              if (completer.isCompleted ||
                  update.revision == null ||
                  update.revision == previousRevision ||
                  update.targetFingerprint != cacheTarget().fingerprint) {
                return;
              }
              try {
                final window = await repository.loadConversationWindow(
                  target: cacheTarget(),
                  provider: Provider.codex.value,
                  providerSessionId: threadId,
                );
                lastObserved = {
                  'eventRevision': update.revision,
                  'storedRevision': window?.revision,
                  'count': window?.entries.length,
                  'windowComplete': window?.windowComplete,
                  'latestTurnComplete': window?.latestTurnComplete,
                };
                if (completer.isCompleted ||
                    window == null ||
                    window.revision != update.revision ||
                    !window.windowComplete ||
                    window.latestTurnComplete != latestTurnComplete ||
                    window.entries.length != count) {
                  return;
                }
                final assistants = window.entries
                    .map((entry) => entry.decodeMessage())
                    .whereType<AssistantServerMessage>()
                    .toList(growable: false);
                if (!listEquals(
                  assistants.map((message) => message.message.id).toList(),
                  expectedAssistants.keys.toList(),
                )) {
                  return;
                }
                for (final assistant in assistants) {
                  final text = assistant.message.content
                      .whereType<TextContent>()
                      .map((content) => content.text)
                      .join('\n');
                  if (text != expectedAssistants[assistant.message.id]) return;
                }
                receiverTrace.add({
                  'stage': 'sqlite-commit',
                  ...lastObserved!,
                  'assistantIds': expectedAssistants.keys.toList(),
                });
                completer.complete(window);
              } catch (error, stack) {
                if (!completer.isCompleted) {
                  completer.completeError(error, stack);
                }
              }
            }

            final sub = sync.syncUpdates.listen((update) {
              if (update.kind == ConversationSyncCacheUpdateKind.timeline &&
                  update.provider == Provider.codex.value &&
                  update.providerSessionId == threadId &&
                  update.pageIndex == (update.pageCount ?? 1) - 1) {
                unawaited(inspect(update));
              }
            });
            try {
              return await completer.future.timeout(
                const Duration(seconds: 15),
                onTimeout: () => throw TestFailure(
                  'No matching committed window: expected count=$count, '
                  'latestTurnComplete=$latestTurnComplete, '
                  'previousRevision=$previousRevision; observed=$lastObserved',
                ),
              );
            } finally {
              await sub.cancel();
            }
          }

          Future<void> mountPreview(
            ConversationHotWindowSnapshot window, {
            String? liveRuntimeSessionId,
            bool bindCatalog = true,
          }) async {
            Widget preview = BlocProvider<ChatSessionCubit>.value(
              value: chat!,
              child: DurableSessionPreviewUpdater(
                revision: window.revision,
                messages: window.entries
                    .map((entry) => entry.decodeMessage())
                    .toList(growable: false),
                hasEarlier: window.hasEarlier,
                statusProvider: bindCatalog ? Provider.codex.value : null,
                statusProviderSessionId: bindCatalog ? threadId : null,
                expectedSourceFingerprint: bindCatalog
                    ? cacheTarget().fingerprint
                    : null,
                liveRuntimeSessionId: liveRuntimeSessionId,
                child: const SizedBox.shrink(),
              ),
            );
            if (bindCatalog) {
              preview = BlocProvider<SessionListCubit>.value(
                value: sessionList,
                child: preview,
              );
            }
            await tester.pumpWidget(preview);
            await tester.pump();
          }

          Future<void> emitSegment({
            required String id,
            required String text,
            bool completeTurn = false,
          }) async {
            final boundary = Completer<void>();
            var sawStreaming = false;
            late final StreamSubscription sub;
            sub = streaming!.stream.listen((state) {
              if (state.isStreaming) sawStreaming = true;
              if (sawStreaming && !state.isStreaming && !boundary.isCompleted) {
                boundary.complete();
              }
            });
            harness.stdin.writeln(
              jsonEncode({
                'command': 'emit_segment',
                'id': id,
                'text': text,
                'completeTurn': completeTurn,
              }),
            );
            await harness.stdin.flush();
            try {
              await boundary.future.timeout(const Duration(seconds: 10));
            } finally {
              await sub.cancel();
            }
            expect(sawStreaming, isTrue);
            expect(streaming.state.isStreaming, isFalse);
            expect(streaming.state.text, isEmpty);
          }

          List<String> assistantIds(ChatSessionCubit value) => value
              .visibleEntries
              .whereType<ServerChatEntry>()
              .map((entry) => entry.message)
              .whereType<AssistantServerMessage>()
              .map((message) => message.message.id)
              .toList(growable: false);

          List<Map<String, Object?>> durableReceiverRows(
            List<Map<String, Object?>> rows,
          ) => rows
              .where(
                (row) =>
                    row['type'] == 'UserChatEntry' ||
                    row['assistantId'] != null,
              )
              .toList(growable: false);

          Future<void> waitForAcceptedUser(String clientMessageId) async {
            bool hasAcceptedUser() =>
                chat!.visibleEntries.whereType<UserChatEntry>().any(
                  (entry) =>
                      entry.clientMessageId == clientMessageId &&
                      entry.status == MessageStatus.bridgeAccepted,
                );
            if (hasAcceptedUser()) return;
            await chat!.stream
                .firstWhere((_) => hasAcceptedUser())
                .timeout(const Duration(seconds: 10));
          }

          Future<void> waitForWritableRuntime() async {
            bool isWritable() => chat!.runtimeSessionIdForMutation() != null;
            if (isWritable()) return;
            await chat!.stream
                .firstWhere((_) => isWritable())
                .timeout(const Duration(seconds: 10));
          }

          void recordReceiver(
            String stage, {
            required bool latestTurnIsActive,
          }) {
            final entries = chat!.visibleEntries;
            final layout = buildChatProcessLayout(
              entries,
              latestTurnIsActive: latestTurnIsActive,
              hasTransientCurrentOutput: streaming!.state.isStreaming,
            );
            final rows = <Map<String, Object?>>[];
            for (var index = 0; index < entries.length; index++) {
              final entry = entries[index];
              final turn = layout.turnForEntry(index);
              final segment = layout.segmentForEntry(index);
              final assistant = entry is ServerChatEntry ? entry.message : null;
              rows.add({
                'index': index,
                'type': entry.runtimeType.toString(),
                'turnId': chatEntryHistoryTurnId(entry),
                'assistantId': assistant is AssistantServerMessage
                    ? assistant.message.id
                    : null,
                'text': assistant is AssistantServerMessage
                    ? assistant.message.content
                          .whereType<TextContent>()
                          .map((content) => content.text)
                          .join('\n')
                    : entry is UserChatEntry
                    ? entry.text
                    : null,
                'segmentKey': segment?.key,
                'placement': turn?.isIntermediateEntry(index) == true
                    ? 'intermediate'
                    : turn?.isCurrentAssistantEntry(index) == true
                    ? 'current'
                    : turn?.finalAssistantEntryIndex == index
                    ? 'final'
                    : 'timeline',
              });
            }
            receiverTrace.add({
              'stage': stage,
              'streaming': streaming.state.isStreaming,
              'streamingText': streaming.state.text,
              'latestTurnKey': layout.latestTurnKey,
              'intermediateSegmentKeys':
                  layout.latestTurn?.intermediateSegments
                      .map((segment) => segment.key)
                      .toList(growable: false) ??
                  const [],
              'currentSegmentKey': layout.latestTurn?.currentSegment?.key,
              'rows': rows,
            });
          }

          try {
            // Formal runtime overlays are intentionally scoped to the focused
            // durable conversation. Mirror the production route, which focuses
            // the thread before attaching its live runtime.
            sync.setFocusedConversation(
              provider: Provider.codex.value,
              providerSessionId: threadId,
            );
            final initialWindowFuture = waitForTimelineCommit(
              1,
              expectedAssistants: const {},
              latestTurnComplete: true,
            );
            bridge.connect(
              url,
              logicalConnectionIdentity: 'live-segment-harness',
            );
            await bridge.connectionStatus
                .firstWhere((state) => state == BridgeConnectionState.connected)
                .timeout(const Duration(seconds: 10));
            final initialWindow = await initialWindowFuture;
            final runtimeFuture = bridge.sessionList
                .expand((sessions) => sessions)
                .firstWhere((session) => session.claudeSessionId == threadId)
                .timeout(const Duration(seconds: 10));
            bridge.send(
              ClientMessage.start(
                projectPath,
                sessionId: threadId,
                continueMode: true,
                provider: Provider.codex.value,
                model: 'gpt-5.6-sol',
                modelReasoningEffort: 'max',
                serviceTier: 'standard',
              ),
            );
            final runtime = await runtimeFuture;
            streaming = StreamingStateCubit(coalesceInterval: Duration.zero);
            runtimeWireSub = bridge.messagesForSession(runtime.id).listen((
              message,
            ) {
              runtimeWireTypes.add(message.runtimeType.toString());
            });
            streamingTraceSub = streaming.stream.listen((state) {
              streamingTransitions.add({
                'isStreaming': state.isStreaming,
                'text': state.text,
                'thinking': state.thinking,
              });
            });
            chat = ChatSessionCubit(
              sessionId: threadId,
              provider: Provider.codex,
              bridge: bridge,
              streamingCubit: streaming,
              detachedPreview: true,
              initialLiveRuntimeSessionId: runtime.id,
              detachedRuntimeOverlayStream: sync.runtimeOverlays,
              initialHistoryMessages: initialWindow.entries
                  .map((entry) => entry.decodeMessage())
                  .toList(growable: false),
            );
            await mountPreview(initialWindow, liveRuntimeSessionId: runtime.id);
            final mountedUpdater = tester.state(
              find.byType(DurableSessionPreviewUpdater),
            );
            recordReceiver('initial', latestTurnIsActive: false);

            var committed = waitForTimelineCommit(
              2,
              previousRevision: initialWindow.revision,
              expectedAssistants: const {
                'assistant-live-segment-a': 'First live commentary',
              },
              // Coverage is complete even while this provider turn is active.
              latestTurnComplete: true,
            );
            await emitSegment(
              id: 'assistant-live-segment-a',
              text: 'First live commentary',
            );
            expect(assistantIds(chat), ['assistant-live-segment-a']);
            recordReceiver('segment-a-live', latestTurnIsActive: true);
            var window = await committed;
            await mountPreview(window, liveRuntimeSessionId: runtime.id);
            expect(assistantIds(chat), ['assistant-live-segment-a']);
            expect(chat.diagnosticRuntimeProjection['activeTurnId'], turnId);
            recordReceiver('segment-a-sqlite', latestTurnIsActive: true);

            committed = waitForTimelineCommit(
              3,
              previousRevision: window.revision,
              expectedAssistants: const {
                'assistant-live-segment-a': 'First live commentary',
                'assistant-live-segment-b': 'Second live commentary',
              },
              latestTurnComplete: true,
            );
            await emitSegment(
              id: 'assistant-live-segment-b',
              text: 'Second live commentary',
            );
            expect(assistantIds(chat), [
              'assistant-live-segment-a',
              'assistant-live-segment-b',
            ]);
            recordReceiver('segment-b-live', latestTurnIsActive: true);
            window = await committed;
            await mountPreview(window, liveRuntimeSessionId: runtime.id);
            final activeLayout = buildChatProcessLayout(
              chat.visibleEntries,
              latestTurnIsActive: true,
            );
            expect(activeLayout.latestTurnKey, 'turn:$turnId');
            expect(activeLayout.latestTurn?.intermediateOutputCount, 1);
            expect(assistantIds(chat), [
              'assistant-live-segment-a',
              'assistant-live-segment-b',
            ]);
            recordReceiver('segment-b-sqlite', latestTurnIsActive: true);

            committed = waitForTimelineCommit(
              4,
              previousRevision: window.revision,
              expectedAssistants: const {
                'assistant-live-segment-a': 'First live commentary',
                'assistant-live-segment-b': 'Second live commentary',
                'assistant-live-final': 'Final answer',
              },
              latestTurnComplete: true,
            );
            await emitSegment(
              id: 'assistant-live-final',
              text: 'Final answer',
              completeTurn: true,
            );
            window = await committed;
            await mountPreview(window, liveRuntimeSessionId: runtime.id);
            final finalLayout = buildChatProcessLayout(
              chat.visibleEntries,
              latestTurnIsActive: false,
            );
            expect(finalLayout.latestTurn?.intermediateOutputCount, 2);
            expect(assistantIds(chat), [
              'assistant-live-segment-a',
              'assistant-live-segment-b',
              'assistant-live-final',
            ]);
            for (final message
                in chat.visibleEntries
                    .whereType<ServerChatEntry>()
                    .map((entry) => entry.message)
                    .whereType<AssistantServerMessage>()) {
              final text = message.message.content
                  .whereType<TextContent>()
                  .map((content) => content.text)
                  .join('\n');
              expect(
                text.split('live commentary').length - 1,
                lessThanOrEqualTo(1),
              );
            }
            recordReceiver('final-sqlite', latestTurnIsActive: false);

            // Change content without changing IDs or count: an old SQLite window
            // must not satisfy the next commit waiter or remain on the mounted page.
            final previousRevision = window.revision;
            committed = waitForTimelineCommit(
              4,
              previousRevision: previousRevision,
              expectedAssistants: const {
                'assistant-live-segment-a': 'First live commentary',
                'assistant-live-segment-b': 'Second live commentary',
                'assistant-live-final': 'Final answer revised',
              },
              latestTurnComplete: true,
            );
            harness.stdin.writeln(
              jsonEncode({
                'command': 'revise_segment',
                'id': 'assistant-live-final',
                'text': 'Final answer revised',
              }),
            );
            await harness.stdin.flush();
            window = await committed;
            expect(window.revision, isNot(previousRevision));
            await mountPreview(window, liveRuntimeSessionId: runtime.id);
            expect(
              identical(
                tester.state(find.byType(DurableSessionPreviewUpdater)),
                mountedUpdater,
              ),
              isTrue,
              reason:
                  'Cache updates must flow through the mounted production updater.',
            );
            final revised = chat.visibleEntries
                .whereType<ServerChatEntry>()
                .map((entry) => entry.message)
                .whereType<AssistantServerMessage>()
                .singleWhere(
                  (message) => message.message.id == 'assistant-live-final',
                );
            expect(
              revised.message.content.whereType<TextContent>().single.text,
              'Final answer revised',
            );
            recordReceiver('same-count-sqlite', latestTurnIsActive: false);

            const acceptedClientMessageId = 'client-accepted-before-reopen';
            await waitForWritableRuntime();
            expect(
              chat.sendMessage(
                'Newest accepted request',
                clientMessageId: acceptedClientMessageId,
              ),
              isTrue,
            );
            await waitForAcceptedUser(acceptedClientMessageId);
            expect(
              chat.visibleEntries.whereType<UserChatEntry>().where(
                (entry) => entry.clientMessageId == acceptedClientMessageId,
              ),
              hasLength(1),
            );
            recordReceiver(
              'accepted-user-before-reopen',
              latestTurnIsActive: false,
            );

            await tester.pumpWidget(const SizedBox.shrink());
            await chat.close();
            await streaming.close();
            streaming = StreamingStateCubit(coalesceInterval: Duration.zero);
            chat = ChatSessionCubit(
              sessionId: threadId,
              provider: Provider.codex,
              bridge: bridge,
              streamingCubit: streaming,
              detachedPreview: true,
              initialLiveRuntimeSessionId: runtime.id,
              detachedRuntimeOverlayStream: sync.runtimeOverlays,
              initialHistoryMessages: window.entries
                  .map((entry) => entry.decodeMessage())
                  .toList(growable: false),
            );
            expect(assistantIds(chat), [
              'assistant-live-segment-a',
              'assistant-live-segment-b',
              'assistant-live-final',
            ]);
            expect(streaming.state.isStreaming, isFalse);
            await mountPreview(window, liveRuntimeSessionId: runtime.id);
            recordReceiver('reopened', latestTurnIsActive: false);

            final before =
                receiverTrace.firstWhere(
                      (row) => row['stage'] == 'accepted-user-before-reopen',
                    )['rows']!
                    as List<Map<String, Object?>>;
            final after =
                receiverTrace.firstWhere(
                      (row) => row['stage'] == 'reopened',
                    )['rows']!
                    as List<Map<String, Object?>>;
            expect(
              durableReceiverRows(after),
              durableReceiverRows(before),
              reason:
                  'Reopening must preserve every user/assistant message and segment.',
            );

            // Independently reopen the committed cache with no live Bridge or sync
            // service able to refill it. The accepted outgoing overlay above is a
            // separate warm-page assertion, not proof that it is canonical history.
            final savedTarget = cacheTarget();
            final originalDatabase = await repository.database.database;
            await tester.pumpWidget(const SizedBox.shrink());
            await chat.close();
            await streaming.close();
            await sessionList.close();
            sessionListClosed = true;
            await sync.dispose();
            bridge.disconnect();
            await repository.close();
            expect(originalDatabase.isOpen, isFalse);
            reopenedRepository = SessionCatalogCacheRepository(
              SessionCatalogCacheDatabase(
                databasePath: databasePath,
                openDatabase: openFfi,
              ),
            );
            final restored = await reopenedRepository.loadConversationWindow(
              target: savedTarget,
              provider: Provider.codex.value,
              providerSessionId: threadId,
            );
            expect(restored, isNotNull);
            expect(restored!.revision, window.revision);
            expect(restored.windowComplete, isTrue);
            expect(restored.latestTurnComplete, isTrue);
            expect(restored.entries, hasLength(4));
            expect(
              identical(
                await reopenedRepository.database.database,
                originalDatabase,
              ),
              isFalse,
            );
            offlineBridge = BridgeService(
              clientAppVersion: 'offline-cache-reader',
            );
            streaming = StreamingStateCubit(coalesceInterval: Duration.zero);
            chat = ChatSessionCubit(
              sessionId: threadId,
              provider: Provider.codex,
              bridge: offlineBridge,
              streamingCubit: streaming,
              detachedPreview: true,
              initialHistoryMessages: restored.entries
                  .map((entry) => entry.decodeMessage())
                  .toList(growable: false),
            );
            await mountPreview(restored, bindCatalog: false);
            recordReceiver(
              'sqlite-reopened-offline',
              latestTurnIsActive: false,
            );
            final committedRows =
                receiverTrace.firstWhere(
                      (row) => row['stage'] == 'same-count-sqlite',
                    )['rows']!
                    as List<Map<String, Object?>>;
            final restoredRows =
                receiverTrace.last['rows']! as List<Map<String, Object?>>;
            expect(
              durableReceiverRows(restoredRows),
              durableReceiverRows(committedRows),
              reason:
                  'Offline reopening must read committed IDs, text and layout from disk.',
            );
          } finally {
            receiverTrace.add({
              'stage': 'wire-observation',
              'runtimeWireTypes': runtimeWireTypes,
              'streamingTransitions': streamingTransitions,
              'runtimeProjection': chat?.diagnosticRuntimeProjection,
            });
            await tester.pumpWidget(const SizedBox.shrink());
            await runtimeWireSub?.cancel();
            await streamingTraceSub?.cancel();
            await chat?.close();
            await streaming?.close();
            if (!sessionListClosed) await sessionList.close();
            await sync.dispose();
            bridge.disconnect();
            await repository.close();
            await reopenedRepository?.close();
            offlineBridge?.dispose();
            bridge.dispose();
            harness.stdin.writeln(jsonEncode({'command': 'shutdown'}));
            await harness.stdin.flush();
            final exitCode = await harness.exitCode.timeout(
              const Duration(seconds: 10),
              onTimeout: () {
                harness.kill(ProcessSignal.sigterm);
                return harness.exitCode;
              },
            );
            await harnessReady.dispose();
            await Directory(traceRoot).create(recursive: true);
            await File(
              path.join(traceRoot, 'receiver-timeline.jsonl'),
            ).writeAsString(
              receiverTrace.isEmpty
                  ? ''
                  : '${receiverTrace.map(jsonEncode).join(Platform.lineTerminator)}${Platform.lineTerminator}',
            );
            if (await temporaryDirectory.exists()) {
              await temporaryDirectory.delete(recursive: true);
            }
            expect(
              exitCode,
              0,
              reason:
                  'Bridge harness stdout: ${harnessReady.stdout}\n'
                  'Bridge harness stderr: ${harnessReady.stderr}',
            );
          }
        }, _ReceiverHttpOverrides()),
      );
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );
}
