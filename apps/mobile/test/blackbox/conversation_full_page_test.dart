import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ccpocket/features/chat_session/state/chat_session_cubit.dart';
import 'package:ccpocket/features/chat_session/state/streaming_state_cubit.dart';
import 'package:ccpocket/features/chat_session/widgets/chat_intermediate_process_group.dart';
import 'package:ccpocket/features/chat_session/widgets/chat_process_disclosure.dart';
import 'package:ccpocket/features/chat_session/widgets/durable_session_preview.dart';
import 'package:ccpocket/features/codex_session/codex_session_screen.dart';
import 'package:ccpocket/features/conversation_content_sync/conversation_content_sync_service.dart';
import 'package:ccpocket/features/session_list/cache/session_catalog_cache_database.dart';
import 'package:ccpocket/features/session_list/cache/session_catalog_cache_repository.dart';
import 'package:ccpocket/features/session_list/state/session_list_cubit.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../chat_screen/helpers/chat_test_helpers.dart'
    show buildTestCodexSessionScreen;
import '../chat_screen/helpers/page_platform_services.dart';
import 'harness_ready.dart';

class _PageHttpOverrides extends HttpOverrides {}

/// Holds one already-accepted Service event at the presentation consumer.
/// Wire order, Service fences, SQLite commits and status reads stay original.
class _FinalCompletionGate {
  _FinalCompletionGate(this.threadId);

  final String threadId;
  final _release = Completer<void>();
  ConversationSyncV2EventMessage? held;
  bool returned = false;

  Future<ConversationSyncV2EventMessage> delay(
    ConversationSyncV2EventMessage event,
  ) async {
    final message = event.overlayMessage;
    if (held == null &&
        !_release.isCompleted &&
        event.providerSessionId == threadId &&
        message is AssistantServerMessage &&
        message.message.id == 'assistant-live-final') {
      held = event;
      await _release.future;
      returned = true;
    }
    return event;
  }

  void release() {
    if (!_release.isCompleted) _release.complete();
  }

  Map<String, Object?> snapshot() => {
    'held': held != null,
    'returned': returned,
    'sequence': held?.sequence,
    'subscriptionId': held?.subscriptionId,
    'originGeneration': held?.originGeneration,
    'runtimeSessionId': held?.runtimeSessionId,
    'authorityGeneration': held?.authorityGeneration,
    'turnId': held?.turnId,
    'observedAt': held?.observedAt,
  };
}

class _DelayedFinalCompletionSync extends ConversationContentSyncService {
  _DelayedFinalCompletionSync({
    required super.bridge,
    required super.cache,
    required this.gate,
  });

  final _FinalCompletionGate gate;
  Stream<ConversationSyncV2EventMessage>? _presentationOverlays;

  @override
  Stream<ConversationSyncV2EventMessage> get runtimeOverlays =>
      _presentationOverlays ??= super.runtimeOverlays.asyncMap(gate.delay);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  for (final scenario in ['partial-summary', 'older-pages']) {
    final olderPages = scenario == 'older-pages';
    testWidgets(
      olderPages
          ? 'older turns pages advance cursors and refresh the mounted Codex page'
          : 'partial turns-page summary commits refresh the mounted Codex page',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(430, 1400));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.runAsync(
          () => HttpOverrides.runWithHttpOverrides(() async {
            SharedPreferences.setMockInitialValues({});
            await installPagePlatformServices();
            final root = path.normalize(
              path.absolute(Directory.current.path, '..', '..'),
            );
            expect(
              File(
                path.join(root, 'packages/bridge/dist/websocket.js'),
              ).existsSync(),
              isTrue,
              reason: 'Build the real Bridge before running this chain test.',
            );
            final process = await Process.start(
              Platform.environment['CCPOCKET_NODE'] ?? 'node',
              [
                path.join(
                  root,
                  'packages/bridge/scripts/conversation-live-segment-harness.mjs',
                ),
              ],
              workingDirectory: root,
              environment: {
                'CCPOCKET_CHAIN_PROVIDER_MODE': 'stdio-json-rpc',
                'CCPOCKET_CHAIN_SCENARIO': scenario,
              },
            );
            final controls = StreamController<Map<String, dynamic>>.broadcast();
            final harness = await waitForHarnessReady(
              process,
              onControl: controls.add,
            );
            final ready =
                jsonDecode(harness.readyLine.substring(6))
                    as Map<String, dynamic>;
            expect(ready['scenario'], scenario);
            expect(ready['providerMode'], 'stdio-json-rpc');
            final threadId = ready['threadId'] as String;
            final traceRoot = ready['traceRoot'] as String;
            final temporary = await Directory.systemTemp.createTemp(
              'ccpocket_partial_summary_',
            );
            final repository = SessionCatalogCacheRepository(
              SessionCatalogCacheDatabase(
                databasePath: path.join(temporary.path, 'cache.db'),
                openDatabase: (file, options) =>
                    databaseFactoryFfi.openDatabase(file, options: options),
              ),
            );
            final bridge = BridgeService(
              clientAppVersion: 'partial-summary-page-test',
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
            final trace = <Map<String, Object?>>[];
            var sequence = 0;
            Future<Map<String, dynamic>> control(
              String command, [
              Map<String, Object?> arguments = const {},
            ]) async {
              final requestId = 'summary-${++sequence}';
              final reply = controls.stream
                  .firstWhere((row) => row['requestId'] == requestId)
                  .timeout(const Duration(seconds: 10));
              process.stdin.writeln(
                jsonEncode({
                  'command': command,
                  'requestId': requestId,
                  ...arguments,
                }),
              );
              await process.stdin.flush();
              final response = await reply;
              expect(response['ok'], isTrue, reason: '$command: $response');
              return response;
            }

            Future<void> eventually(
              FutureOr<bool> Function() condition,
              String reason,
            ) async {
              final deadline = DateTime.now().add(const Duration(seconds: 15));
              do {
                await tester.pump();
                final error = tester.takeException();
                if (error != null) throw TestFailure('$reason: $error');
                if (await condition()) return;
                await Future<void>.delayed(const Duration(milliseconds: 10));
              } while (DateTime.now().isBefore(deadline));
              throw TestFailure(
                '$reason; sync=${sync.diagnosticSnapshot(provider: 'codex', providerSessionId: threadId)}',
              );
            }

            Future<ConversationHotWindowSnapshot?> cached() =>
                sync.loadCachedWindow(
                  provider: 'codex',
                  providerSessionId: threadId,
                );
            Finder onPage(String text) => find.text(text, findRichText: true);
            final prefix = olderPages
                ? 'Exercise live segment boundaries'
                : 'Retained readable prefix';
            final recovered = olderPages
                ? 'Older prompt one'
                : 'Latest prompt recovered from a partial summary';
            try {
              bridge.connect(
                ready['url'] as String,
                logicalConnectionIdentity: 'partial-summary-harness',
              );
              await eventually(
                () =>
                    bridge.isConnected &&
                    bridge.bridgeInstanceId != null &&
                    bridge.codexSourceId != null,
                'source handshake',
              );
              await tester.pumpWidget(
                await buildTestCodexSessionScreen(
                  bridge: bridge,
                  sessionId: 'pending-partial-summary',
                  projectPath: ready['projectPath'] as String,
                  isPending: true,
                  durableProviderSessionId: threadId,
                  dataSourceIdentity: bridge.dataSourceIdentity,
                  conversationContentSync: sync,
                  sessionListCubit: sessionList,
                ),
              );
              await eventually(
                () async =>
                    (await cached()) != null &&
                    onPage(prefix).evaluate().length == 1,
                'the actual page must first render the retained prefix',
              );
              await eventually(() async {
                final status = await control('provider_status');
                return olderPages
                    ? (status['heldOlderCursors'] as List).contains(
                        'older-page-1',
                      )
                    : status['heldSummaryRequests'] == 1;
              }, 'the page request must reach the real RPC path');
              final before = (await cached())!;
              expect(before.latestTurnComplete, olderPages);
              if (olderPages) {
                expect(before.turnsNextCursor, 'older-page-1');
                expect(before.hasEarlier, isTrue);
              } else {
                expect(before.latestTurnGap?.repair, 'turns_page');
              }
              expect(onPage(recovered), findsNothing);
              final mountedPage = tester.state(find.byType(CodexSessionScreen));
              final mountedUpdater = tester.state(
                find.byType(DurableSessionPreviewUpdater),
              );
              final mountedChat = BlocProvider.of<ChatSessionCubit>(
                tester.element(find.byKey(const ValueKey('message_input'))),
              );
              final target = SessionCatalogCacheTarget.fromBridge(
                bridgeInstanceId: bridge.bridgeInstanceId,
                codexSourceId: bridge.codexSourceId,
                logicalConnectionIdentity: bridge.logicalConnectionIdentity,
                websocketUrl: bridge.lastUrl,
              );
              int epoch() => sync.cacheCommitEpochFor(
                targetFingerprint: target.fingerprint,
                provider: 'codex',
                providerSessionId: threadId,
              );
              final beforeEpoch = epoch();
              // This releases an upstream reply. It never injects a cache window,
              // calls page refresh, or replaces the page/Cubit after the commit.
              await control(
                olderPages ? 'release_older_page' : 'release_summary',
                olderPages ? {'cursor': 'older-page-1'} : const {},
              );
              await eventually(
                () async =>
                    (await cached())?.entries.any(
                          (entry) =>
                              entry.rawMessage['providerItemId'] ==
                              (olderPages
                                  ? 'older-provider-user-1'
                                  : 'provider-user-live-segments'),
                        ) ==
                        true &&
                    onPage(recovered).evaluate().length == 1,
                'accepted page commit must propagate to the mounted page',
              );
              var after = (await cached())!;
              expect(after.revision, before.revision);
              expect(after.latestTurnComplete, olderPages);
              expect(after.windowComplete, olderPages);
              if (olderPages) {
                expect(after.turnsNextCursor, 'older-page-2');
              } else {
                expect(after.latestTurnGap?.repair, 'turns_page');
              }
              expect(epoch(), greaterThan(beforeEpoch));
              expect(
                tester.state(find.byType(CodexSessionScreen)),
                same(mountedPage),
              );
              expect(
                tester.state(find.byType(DurableSessionPreviewUpdater)),
                same(mountedUpdater),
              );
              expect(
                BlocProvider.of<ChatSessionCubit>(
                  tester.element(find.byKey(const ValueKey('message_input'))),
                ),
                same(mountedChat),
              );
              expect(
                mountedChat.visibleEntries.whereType<UserChatEntry>().map(
                  (entry) => entry.text,
                ),
                olderPages ? [recovered, prefix] : [prefix, recovered],
              );
              expect(
                after.entries.map(
                  (entry) => entry.rawMessage['providerItemId'],
                ),
                olderPages
                    ? ['older-provider-user-1', 'provider-user-live-segments']
                    : [
                        'provider-user-before-summary',
                        'provider-user-live-segments',
                      ],
              );
              expect(onPage(prefix), findsOneWidget);
              expect(onPage(recovered), findsOneWidget);
              if (olderPages) {
                // The short viewport drives the real page/Cubit older loader;
                // this test never calls SyncService.loadOlderTurns directly.
                await eventually(
                  () async =>
                      ((await control('provider_status'))['heldOlderCursors']
                              as List)
                          .contains('older-page-2'),
                  'the original page must request the next older cursor',
                );
                expect(onPage('Oldest prompt two'), findsNothing);
                expect(mountedChat.localHistoryPaging.value.loading, isTrue);
                await control('release_older_page', {'cursor': 'older-page-2'});
                await eventually(
                  () async =>
                      (await cached())?.hasEarlier == false &&
                      onPage('Oldest prompt two').evaluate().length == 1 &&
                      !mountedChat.localHistoryPaging.value.loading,
                  'the second page must reach SQLite and finish original page loading',
                );
                after = (await cached())!;
                expect(after.turnsNextCursor, isNull);
                expect(after.revision, before.revision);
                expect(
                  after.entries.map(
                    (entry) => entry.rawMessage['providerItemId'],
                  ),
                  [
                    'older-provider-user-2',
                    'older-provider-user-1',
                    'provider-user-live-segments',
                  ],
                );
                expect(
                  mountedChat.visibleEntries.whereType<UserChatEntry>().map(
                    (entry) => entry.text,
                  ),
                  ['Oldest prompt two', recovered, prefix],
                );
                expect(mountedChat.localHistoryPaging.value.error, isNull);
                expect(mountedChat.localHistoryPaging.value.hasMore, isFalse);
                expect(
                  tester.state(find.byType(CodexSessionScreen)),
                  same(mountedPage),
                );
                expect(onPage(prefix), findsOneWidget);
                expect(onPage(recovered), findsOneWidget);
              }
              trace.add({
                'stage': '$scenario-mounted-page',
                'result': 'PASS',
                'revision': after.revision,
                'beforeEpoch': beforeEpoch,
                'afterEpoch': epoch(),
                'latestTurnComplete': after.latestTurnComplete,
                'entries': [
                  for (final entry in after.entries)
                    {
                      'id': entry.entryId,
                      'index': entry.index,
                      'hash': entry.contentHash,
                      'message': entry.rawMessage,
                    },
                ],
                'pageUsers': mountedChat.visibleEntries
                    .whereType<UserChatEntry>()
                    .map((entry) => entry.text)
                    .toList(),
              });
            } catch (error, stack) {
              trace.add({
                'result': 'FAIL',
                'error': '$error',
                'stack': '$stack',
              });
              rethrow;
            } finally {
              await tester.pumpWidget(const SizedBox.shrink());
              await sessionList.close();
              await sync.dispose();
              bridge.disconnect();
              await repository.close();
              bridge.dispose();
              process.stdin.writeln(jsonEncode({'command': 'shutdown'}));
              await process.stdin.flush();
              final exitCode = await process.exitCode.timeout(
                const Duration(seconds: 10),
                onTimeout: () {
                  process.kill(ProcessSignal.sigterm);
                  return process.exitCode;
                },
              );
              await harness.dispose();
              await controls.close();
              await File(
                path.join(traceRoot, '$scenario-page.jsonl'),
              ).writeAsString(
                '${trace.map(jsonEncode).join(Platform.lineTerminator)}${Platform.lineTerminator}',
              );
              await GoogleFonts.pendingFonts();
              await temporary.delete(recursive: true);
              expect(exitCode, 0, reason: 'Harness stderr: ${harness.stderr}');
            }
          }, _PageHttpOverrides()),
        );
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  }

  for (final scenario in [
    'ordinary',
    'pending-focus',
    'delayed-final-completion',
  ]) {
    final holdInitialSyncBegin = scenario == 'pending-focus';
    final holdFinalCompletion = scenario == 'delayed-final-completion';
    testWidgets(
      switch (scenario) {
        'pending-focus' =>
          'complete Codex page catches up focus changed during pending subscribe',
        'delayed-final-completion' =>
          'complete Codex page retires streaming before delayed final completion',
        _ =>
          'complete Codex page refreshes from real RPC commits and survives wire faults',
      },
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(430, 1400));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.runAsync(
          () => HttpOverrides.runWithHttpOverrides(() async {
            SharedPreferences.setMockInitialValues({});
            await installPagePlatformServices();
            final root = path.normalize(
              path.absolute(Directory.current.path, '..', '..'),
            );
            expect(
              File(
                path.join(root, 'packages/bridge/dist/websocket.js'),
              ).existsSync(),
              isTrue,
              reason:
                  'Build the real Bridge before running the full-page test.',
            );
            final process = await Process.start(
              Platform.environment['CCPOCKET_NODE'] ?? 'node',
              [
                path.join(
                  root,
                  'packages/bridge/scripts/conversation-live-segment-harness.mjs',
                ),
              ],
              workingDirectory: root,
              environment: {
                'CCPOCKET_CHAIN_PROVIDER_MODE': 'stdio-json-rpc',
                'CCPOCKET_CHAIN_HOLD_INITIAL_SYNC_BEGIN': holdInitialSyncBegin
                    ? '1'
                    : '0',
              },
            );
            final controls = StreamController<Map<String, dynamic>>.broadcast();
            final harness = await waitForHarnessReady(
              process,
              onControl: controls.add,
            );
            final ready =
                jsonDecode(harness.readyLine.substring(6))
                    as Map<String, dynamic>;
            final threadId = ready['threadId'] as String;
            final traceRoot = ready['traceRoot'] as String;
            final url = ready['url'] as String;
            expect(ready['providerMode'], 'stdio-json-rpc');
            final temporary = await Directory.systemTemp.createTemp(
              'ccpocket_full_page_',
            );
            final repository = SessionCatalogCacheRepository(
              SessionCatalogCacheDatabase(
                databasePath: path.join(temporary.path, 'cache.db'),
                openDatabase: (file, options) =>
                    databaseFactoryFfi.openDatabase(file, options: options),
              ),
            );
            final bridge = BridgeService(
              clientAppVersion: 'full-page-chain-test',
            );
            final completionGate = holdFinalCompletion
                ? _FinalCompletionGate(threadId)
                : null;
            final sync = completionGate == null
                ? ConversationContentSyncService(
                    bridge: BridgeServiceConversationContentSyncGateway(bridge),
                    cache: repository,
                  )
                : _DelayedFinalCompletionSync(
                    bridge: BridgeServiceConversationContentSyncGateway(bridge),
                    cache: repository,
                    gate: completionGate,
                  );
            sync.start(initialLifecycleState: AppLifecycleState.resumed);
            final sessionList = SessionListCubit(
              bridge: bridge,
              catalogCache: repository,
              conversationSync: sync,
            );
            final trace = <Map<String, Object?>>[];
            var stage = 'initial-page';
            var sequence = 0;
            ChatSessionCubit? mountedChat;
            State? mountedPage;
            State? mountedUpdater;
            String? heldSubscriptionId;

            Future<Map<String, dynamic>> control(
              String command, [
              Map<String, Object?> arguments = const {},
            ]) async {
              final requestId = 'page-${++sequence}';
              final response = controls.stream
                  .firstWhere((value) => value['requestId'] == requestId)
                  .timeout(const Duration(seconds: 12));
              process.stdin.writeln(
                jsonEncode({
                  'command': command,
                  'requestId': requestId,
                  ...arguments,
                }),
              );
              await process.stdin.flush();
              final result = await response;
              expect(result['ok'], isTrue, reason: '$command: $result');
              return result;
            }

            Map<String, Object?> diagnostics() => sync.diagnosticSnapshot(
              provider: Provider.codex.value,
              providerSessionId: threadId,
            );
            SessionCatalogCacheTarget target() =>
                SessionCatalogCacheTarget.fromBridge(
                  bridgeInstanceId: bridge.bridgeInstanceId,
                  codexSourceId: bridge.codexSourceId,
                  logicalConnectionIdentity: bridge.logicalConnectionIdentity,
                  websocketUrl: bridge.lastUrl,
                );
            Future<Map<String, dynamic>> barrier() => control('wire_barrier', {
              'subscriptionId': diagnostics()['activeSubscriptionId'],
              'sequence': diagnostics()['highestV2CommittedSequence'],
            });
            Finder textOnPage(String text) =>
                find.text(text, findRichText: true);
            ChatSessionCubit pageChat() => BlocProvider.of<ChatSessionCubit>(
              tester.element(find.byKey(const ValueKey('message_input'))),
            );

            // Pump only frames. This never supplies history, revisions, or Cubit
            // state: CodexSessionScreen owns sync.updates and every SQLite read.
            Future<void> eventually(
              FutureOr<bool> Function() condition,
              String reason,
            ) async {
              final deadline = DateTime.now().add(const Duration(seconds: 15));
              do {
                await tester.pump();
                final error = tester.takeException();
                if (error != null) throw TestFailure('$stage: $error');
                if (await condition()) return;
                await Future<void>.delayed(const Duration(milliseconds: 10));
              } while (DateTime.now().isBefore(deadline));
              throw TestFailure('$stage: $reason; sync=${diagnostics()}');
            }

            Future<void> openPage() async {
              await tester.pumpWidget(
                await buildTestCodexSessionScreen(
                  bridge: bridge,
                  sessionId: 'pending-full-page',
                  projectPath: ready['projectPath'] as String,
                  isPending: true,
                  durableProviderSessionId: threadId,
                  dataSourceIdentity: bridge.dataSourceIdentity,
                  conversationContentSync: sync,
                  sessionListCubit: sessionList,
                ),
              );
              await eventually(
                () => find
                    .byKey(const ValueKey('message_input'))
                    .evaluate()
                    .isNotEmpty,
                'composer did not mount',
              );
              mountedChat = pageChat();
              mountedPage = tester.state(find.byType(CodexSessionScreen));
              mountedUpdater = tester.state(
                find.byType(DurableSessionPreviewUpdater),
              );
            }

            List<Map<String, Object?>> chatRows() => [
              for (final entry in pageChat().visibleEntries)
                if (entry is UserChatEntry)
                  {'kind': 'user', 'text': entry.text}
                else if (entry is ServerChatEntry &&
                    entry.message is AssistantServerMessage)
                  {
                    'kind': 'assistant',
                    'id': (entry.message as AssistantServerMessage).message.id,
                    'text': (entry.message as AssistantServerMessage)
                        .message
                        .content
                        .whereType<TextContent>()
                        .map((item) => item.text)
                        .join('\n'),
                  },
            ];
            final expected = <String, String>{};
            Future<ConversationHotWindowSnapshot> expectContent({
              String? previousRevision,
            }) async {
              ConversationHotWindowSnapshot? stored;
              final rows = <Map<String, Object?>>[
                {'kind': 'user', 'text': 'Exercise live segment boundaries'},
                for (final item in expected.entries)
                  {'kind': 'assistant', 'id': item.key, 'text': item.value},
              ];
              await eventually(
                () async {
                  stored = await repository.loadConversationWindow(
                    target: target(),
                    provider: Provider.codex.value,
                    providerSessionId: threadId,
                  );
                  if (stored == null ||
                      !stored!.windowComplete ||
                      !stored!.latestTurnComplete ||
                      stored!.revision == previousRevision ||
                      stored!.entries.length != rows.length) {
                    return false;
                  }
                  final assistants = stored!.entries
                      .map((entry) => entry.decodeMessage())
                      .whereType<AssistantServerMessage>()
                      .toList();
                  if (!listEquals(
                    assistants.map((item) => item.message.id).toList(),
                    expected.keys.toList(),
                  )) {
                    return false;
                  }
                  for (final item in assistants) {
                    if (item.message.content
                            .whereType<TextContent>()
                            .map((part) => part.text)
                            .join('\n') !=
                        expected[item.message.id]) {
                      return false;
                    }
                  }
                  return listEquals(
                    chatRows().map(jsonEncode).toList(),
                    rows.map(jsonEncode).toList(),
                  );
                },
                'SQLite and production page must agree on all IDs, text and order',
              );
              expect(
                pageChat(),
                same(mountedChat),
                reason: 'The page must update without replacing its Cubit.',
              );
              expect(
                tester.state(find.byType(CodexSessionScreen)),
                same(mountedPage),
              );
              expect(
                tester.state(find.byType(DurableSessionPreviewUpdater)),
                same(mountedUpdater),
              );
              return stored!;
            }

            Future<void> visible(String text) async {
              await eventually(
                () => textOnPage(text).evaluate().length == 1,
                'expected one visible copy of $text',
              );
              expect(textOnPage(text), findsOneWidget);
            }

            Future<void> collapsedFinal(String finalText) async {
              await visible(finalText);
              await eventually(
                () =>
                    find
                            .byType(ChatIntermediateOutputsDisclosure)
                            .evaluate()
                            .length ==
                        1 &&
                    tester
                            .widget<ChatIntermediateOutputsDisclosure>(
                              find.byType(ChatIntermediateOutputsDisclosure),
                            )
                            .turn
                            .intermediateOutputCount ==
                        2,
                'missing complete intermediate fold',
              );
              final disclosure = tester
                  .widget<ChatIntermediateOutputsDisclosure>(
                    find.byType(ChatIntermediateOutputsDisclosure),
                  );
              expect(disclosure.expanded, isFalse);
              expect(disclosure.turn.intermediateOutputCount, 2);
              expect(
                textOnPage(expected['assistant-live-segment-a']!),
                findsNothing,
              );
              expect(
                textOnPage(expected['assistant-live-segment-b']!),
                findsNothing,
              );
              expect(
                find.descendant(
                  of: find.byType(ChatIntermediateProcessGroup),
                  matching: textOnPage(finalText),
                ),
                findsNothing,
                reason:
                    'Final answer must be outside the intermediate process container.',
              );
            }

            Map<String, Object?> presentationSnapshot() {
              final chat = mountedChat;
              final input = find.byKey(const ValueKey('message_input'));
              final streaming = input.evaluate().isEmpty
                  ? null
                  : BlocProvider.of<StreamingStateCubit>(
                      tester.element(input),
                    ).state;
              return {
                'chatStatus': chat?.state.status.name,
                'externalDesktopTurnActive':
                    chat?.state.externalDesktopTurnActive,
                'runtimeProjection': chat?.diagnosticRuntimeProjection,
                'streaming': streaming == null
                    ? null
                    : {
                        'isStreaming': streaming.isStreaming,
                        'text': streaming.text,
                        'thinking': streaming.thinking,
                      },
                if (completionGate != null)
                  'completionGate': completionGate.snapshot(),
                'rows': chatRows(),
                'renderedText': tester
                    .widgetList<RichText>(find.byType(RichText))
                    .map((widget) => widget.text.toPlainText())
                    .toList(),
                'disclosures': [
                  for (final widget
                      in tester.widgetList<ChatIntermediateOutputsDisclosure>(
                        find.byType(ChatIntermediateOutputsDisclosure),
                      ))
                    {
                      'turnKey': widget.turn.key,
                      'isActive': widget.turn.isActive,
                      'hasTransientCurrentOutput':
                          widget.turn.hasTransientCurrentOutput,
                      'currentAssistantEntryIndex':
                          widget.turn.currentAssistantEntryIndex,
                      'finalAssistantEntryIndex':
                          widget.turn.finalAssistantEntryIndex,
                      'intermediateAssistantEntryIndices': widget
                          .turn
                          .intermediateAssistantEntryIndices
                          .toList(),
                      'expanded': widget.expanded,
                    },
                ],
              };
            }

            List<Map<String, Object?>> canonicalSnapshot(
              ConversationHotWindowSnapshot? window,
            ) => [
              for (final entry in window?.entries ?? const [])
                {
                  'id': entry.entryId,
                  'index': entry.index,
                  'hash': entry.contentHash,
                  'message': entry.rawMessage,
                },
            ];

            void pass(ConversationHotWindowSnapshot window) {
              trace.add({
                'stage': stage,
                'result': 'PASS',
                'revision': window.revision,
                'source': target().fingerprint,
                'canonical': canonicalSnapshot(window),
                ...presentationSnapshot(),
                'sync': diagnostics(),
              });
            }

            try {
              bridge.connect(
                url,
                logicalConnectionIdentity: 'full-page-harness',
              );
              await eventually(
                () =>
                    bridge.isConnected &&
                    bridge.bridgeInstanceId != null &&
                    bridge.codexSourceId != null,
                'real source identity handshake',
              );
              if (holdInitialSyncBegin) {
                stage = 'pending-subscription-focus';
                Map<String, dynamic>? held;
                await eventually(() async {
                  held = await control('wire_bootstrap_status');
                  return held!['state'] == 'holding';
                }, 'initial sync_begin was not held');
                final subscribes = held!['subscribeRequests'] as List;
                expect(subscribes, hasLength(1));
                final subscribe = subscribes.single as Map<String, dynamic>;
                expect(subscribe['focused'], isNull);
                heldSubscriptionId = subscribe['requestId'] as String;
                expect(held!['subscriptionId'], heldSubscriptionId);
                expect((held!['heldSequences'] as List).first, 1);
                trace.add({'stage': stage, 'result': 'HELD', 'wire': held});
              }
              await openPage();
              if (holdInitialSyncBegin) {
                expect(diagnostics()['focused'], {
                  'provider': Provider.codex.value,
                  'providerSessionId': threadId,
                });
                expect(diagnostics()['activeSubscriptionId'], isNull);
                expect(
                  diagnostics()['pendingSubscriptionId'],
                  heldSubscriptionId,
                );
                final held = await control('wire_bootstrap_status');
                expect(held['state'], 'holding');
                expect(held['subscribeRequests'] as List, hasLength(1));
                expect(held['focusRequests'] as List, isEmpty);
                final released = await control('wire_release_bootstrap');
                expect(released['subscriptionId'], heldSubscriptionId);
                expect(released['releasedCount'] as int, greaterThan(0));
                trace.add({
                  'stage': stage,
                  'result': 'RELEASED',
                  'wire': released,
                  'sync': diagnostics(),
                });
                stage = 'initial-page';
              }
              var window = await expectContent();
              await visible('Exercise live segment boundaries');
              pass(window);

              // A separate client-style start supplies the synthetic provider's
              // running session. The page receives its authority through Bridge.
              final runtimeFuture = bridge.sessionList
                  .expand((sessions) => sessions)
                  .firstWhere((session) => session.claudeSessionId == threadId)
                  .timeout(const Duration(seconds: 10));
              bridge.send(
                ClientMessage.start(
                  ready['projectPath'] as String,
                  sessionId: threadId,
                  continueMode: true,
                  provider: Provider.codex.value,
                  model: 'gpt-5.6-sol',
                  modelReasoningEffort: 'max',
                  serviceTier: 'standard',
                ),
              );
              await runtimeFuture;
              await eventually(
                () async =>
                    (await control('provider_status'))['runtimeReady'] == true,
                'provider runtime initialization',
              );
              for (final item in const {
                'assistant-live-segment-a': 'First live commentary',
                'assistant-live-segment-b': 'Second live commentary',
                'assistant-live-final': 'Final answer',
              }.entries) {
                stage = item.key;
                expected[item.key] = item.value;
                await control('emit_segment', {
                  'id': item.key,
                  'text': item.value,
                  'completeTurn': item.key == 'assistant-live-final',
                });
                window = await expectContent(previousRevision: window.revision);
                await visible(item.value);
                pass(window);
              }
              if (holdInitialSyncBegin) {
                final wire = await control('wire_bootstrap_status');
                final focuses = wire['focusRequests'] as List;
                expect(focuses, hasLength(1));
                expect(
                  (focuses.single as Map)['subscriptionId'],
                  heldSubscriptionId,
                );
                expect((focuses.single as Map)['focused'], {
                  'provider': Provider.codex.value,
                  'providerSessionId': threadId,
                });
                trace.add({
                  'stage': 'pending-focus-catch-up',
                  'result': 'PASS',
                  'wire': wire,
                });
              }
              stage = 'final-outside-collapsed-process';
              if (completionGate != null) {
                await eventually(
                  () =>
                      completionGate.held != null &&
                      mountedChat!.state.status == ProcessStatus.idle &&
                      mountedChat!
                              .diagnosticRuntimeProjection['activeTurnId'] ==
                          null,
                  'the actual terminal status must arrive before held completion',
                );
                trace.add({
                  'stage': 'terminal-before-completion',
                  'result': 'HELD',
                  ...presentationSnapshot(),
                  'sync': diagnostics(),
                });
              }
              await collapsedFinal('Final answer');
              pass(window);
              if (completionGate != null) {
                completionGate.release();
                await eventually(
                  () => completionGate.returned,
                  'held completion must return unchanged to the original consumer',
                );
                await collapsedFinal('Final answer');
                trace.add({
                  'stage': 'late-final-completion',
                  'result': 'PASS',
                  ...presentationSnapshot(),
                  'sync': diagnostics(),
                });
              }
              final beforeEdit = await barrier();
              final checkpoint = await control('wire_checkpoint', {
                'name': 'page-before-edit',
                'subscriptionId': beforeEdit['subscriptionId'],
                'sequence': beforeEdit['sequence'],
              });
              expect(checkpoint['count'] as int, greaterThan(0));

              stage = 'same-count-automatic-refresh';
              expected['assistant-live-final'] = 'Final answer revised';
              await control('revise_segment', {
                'id': 'assistant-live-final',
                'text': expected['assistant-live-final'],
              });
              window = await expectContent(previousRevision: window.revision);
              await collapsedFinal(expected['assistant-live-final']!);
              expect(textOnPage('Final answer'), findsNothing);
              pass(window);

              stage = 'expand-and-collapse';
              final disclosure = tester
                  .widget<ChatIntermediateOutputsDisclosure>(
                    find.byType(ChatIntermediateOutputsDisclosure),
                  );
              final toggle = find.byKey(
                ValueKey('chat_intermediate_disclosure_${disclosure.turn.key}'),
              );
              await tester.ensureVisible(toggle);
              await tester.tap(toggle);
              await visible(expected['assistant-live-segment-a']!);
              await visible(expected['assistant-live-segment-b']!);
              for (final id in [
                'assistant-live-segment-a',
                'assistant-live-segment-b',
              ]) {
                expect(
                  find.descendant(
                    of: find.byType(ChatIntermediateProcessGroup),
                    matching: textOnPage(expected[id]!),
                  ),
                  findsOneWidget,
                );
              }
              expect(
                tester
                    .getTopLeft(
                      textOnPage(expected['assistant-live-segment-a']!),
                    )
                    .dy,
                lessThan(
                  tester
                      .getTopLeft(
                        textOnPage(expected['assistant-live-segment-b']!),
                      )
                      .dy,
                ),
              );
              expect(
                find.descendant(
                  of: find.byType(ChatIntermediateProcessGroup),
                  matching: textOnPage(expected['assistant-live-final']!),
                ),
                findsNothing,
              );
              await tester.tap(toggle);
              await eventually(
                () => textOnPage(
                  expected['assistant-live-segment-a']!,
                ).evaluate().isEmpty,
                'collapse did not hide intermediate output',
              );
              await collapsedFinal(expected['assistant-live-final']!);
              pass(window);

              stage = 'leave-and-reenter';
              final previousChat = mountedChat;
              final beforeReopen = chatRows();
              await tester.pumpWidget(const SizedBox.shrink());
              await openPage();
              expect(mountedChat, isNot(same(previousChat)));
              window = await expectContent();
              expect(chatRows(), beforeReopen);
              await collapsedFinal(expected['assistant-live-final']!);
              pass(window);

              stage = 'duplicate-and-late-frames';
              final settled = await barrier();
              final replay = await control('wire_replay', {
                'name': 'page-before-edit',
                'reverse': true,
                'repeats': 2,
                'ackSequence': settled['sequence'],
              });
              expect(replay['acknowledged'], replay['count']);
              expect(replay['count'], (checkpoint['count'] as int) * 2);
              final storedRevision = window.revision;
              window = await expectContent();
              expect(window.revision, storedRevision);
              await collapsedFinal(expected['assistant-live-final']!);
              pass(window);

              stage = 'offline-page-and-reopen';
              final oldSubscription = diagnostics()['activeSubscriptionId'];
              final savedSource = target().fingerprint;
              bridge.reconnectDelayForTest = (_) => const Duration(days: 1);
              await control('wire_disconnect');
              await eventually(
                () => !bridge.isConnected,
                'socket did not disconnect',
              );
              await collapsedFinal(expected['assistant-live-final']!);
              await tester.pumpWidget(const SizedBox.shrink());
              await openPage();
              window = await expectContent();
              await collapsedFinal(expected['assistant-live-final']!);
              expect(bridge.isConnected, isFalse);
              pass(window);

              stage = 'reconnect-same-source';
              bridge.connect(
                url,
                logicalConnectionIdentity: 'full-page-harness',
              );
              await eventually(
                () =>
                    bridge.isConnected &&
                    diagnostics()['activeSubscriptionId'] != null &&
                    diagnostics()['activeSubscriptionId'] != oldSubscription,
                'new subscription generation',
              );
              await barrier();
              expect(target().fingerprint, savedSource);
              window = await expectContent();
              await collapsedFinal(expected['assistant-live-final']!);
              pass(window);

              stage = 'old-subscription-cannot-rewind-page';
              final frames = bridge.localFeatureMessages
                  .where(
                    (message) =>
                        message is ConversationSyncV2EventMessage &&
                        message.subscriptionId == beforeEdit['subscriptionId'],
                  )
                  .take(checkpoint['count'] as int)
                  .toList()
                  .timeout(const Duration(seconds: 10));
              await control('wire_replay', {
                'name': 'page-before-edit',
                'reverse': true,
              });
              expect(await frames, hasLength(checkpoint['count'] as int));
              await eventually(
                () => (diagnostics()['recentEvents'] as List).any(
                  (event) =>
                      event is Map &&
                      event['kind'] == 'eventIgnored' &&
                      event['result'] == 'subscription',
                ),
                'old frames must be rejected',
              );
              window = await expectContent();
              expect(window.revision, storedRevision);
              await collapsedFinal(expected['assistant-live-final']!);
              pass(window);

              for (final fault in ['reorder', 'drop']) {
                stage = '$fault-page-recovery';
                await barrier();
                final previousSubscription =
                    diagnostics()['activeSubscriptionId'];
                final text = 'Final answer after $fault recovery';
                expected['assistant-live-final'] = text;
                await control('wire_arm', {'kind': fault});
                await control('revise_segment', {
                  'id': 'assistant-live-final',
                  'text': text,
                });
                window = await expectContent(previousRevision: window.revision);
                await eventually(
                  () =>
                      diagnostics()['activeSubscriptionId'] !=
                      previousSubscription,
                  'gap must create a new subscription',
                );
                await barrier();
                await collapsedFinal(text);
                expect(textOnPage('Final answer revised'), findsNothing);
                pass(window);
              }
              final provider = await control('provider_status');
              expect(provider['mode'], 'stdio-json-rpc');
              expect(
                provider['requests'] as List,
                containsAll([
                  'initialize',
                  'thread/turns/list',
                  'thread/resume',
                  'turn/start',
                ]),
              );
              expect(
                provider['notifications'] as List,
                containsAll([
                  'item/started',
                  'item/agentMessage/delta',
                  'item/completed',
                  'turn/completed',
                ]),
              );
              trace.add({
                'stage': 'provider-rpc',
                'result': 'PASS',
                ...provider,
              });
            } catch (error, stack) {
              final snapshot = <String, Object?>{};
              // Diagnostics only: preserve the original assertion, deadline and
              // mounted page. A snapshot error must not replace the test failure.
              try {
                snapshot.addAll(presentationSnapshot());
                final window = await repository.loadConversationWindow(
                  target: target(),
                  provider: Provider.codex.value,
                  providerSessionId: threadId,
                );
                snapshot['revision'] = window?.revision;
                snapshot['canonical'] = canonicalSnapshot(window);
              } catch (snapshotError) {
                snapshot['snapshotError'] = '$snapshotError';
              }
              trace.add({
                'stage': stage,
                'result': 'FAIL',
                ...snapshot,
                'error': '$error',
                'stack': '$stack',
                'sync': diagnostics(),
              });
              rethrow;
            } finally {
              completionGate?.release();
              await tester.pumpWidget(const SizedBox.shrink());
              await sessionList.close();
              await sync.dispose();
              bridge.disconnect();
              await repository.close();
              bridge.dispose();
              process.stdin.writeln(jsonEncode({'command': 'shutdown'}));
              await process.stdin.flush();
              final exitCode = await process.exitCode.timeout(
                const Duration(seconds: 10),
                onTimeout: () {
                  process.kill(ProcessSignal.sigterm);
                  return process.exitCode;
                },
              );
              await harness.dispose();
              await controls.close();
              await Directory(traceRoot).create(recursive: true);
              await File(
                path.join(traceRoot, 'full-page-timeline.jsonl'),
              ).writeAsString(
                '${trace.map(jsonEncode).join(Platform.lineTerminator)}${Platform.lineTerminator}',
              );
              await GoogleFonts.pendingFonts();
              await temporary.delete(recursive: true);
              expect(exitCode, 0, reason: 'Harness stderr: ${harness.stderr}');
            }
          }, _PageHttpOverrides()),
        );
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );
  }
}
