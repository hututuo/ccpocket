import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ccpocket/features/chat_session/state/chat_session_cubit.dart';
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
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_fonts/src/google_fonts_base.dart' as font_loader;
// Test only: exercise the plugin's documented native-channel mock context.
// ignore: depend_on_referenced_packages
import 'package:irondash_message_channel/irondash_message_channel.dart';
// ignore: depend_on_referenced_packages
import 'package:super_native_extensions/src/native/context.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../chat_screen/helpers/chat_test_helpers.dart'
    show buildTestCodexSessionScreen;
import 'harness_ready.dart';

class _PageHttpOverrides extends HttpOverrides {}

// Rendering uses a repository-bundled font for these asset aliases.
// Typeface metrics are not a visual/physical-device acceptance claim.
class _PageFontManifest extends Fake implements AssetManifest {
  @override
  List<String> listAssets() => [
    for (final family in ['IBMPlexSans', 'SpaceGrotesk'])
      for (final weight in [
        'Thin',
        'ExtraLight',
        'Light',
        'Regular',
        '',
        'Medium',
        'SemiBold',
        'Bold',
        'ExtraBold',
        'Black',
      ])
        for (final suffix in ['', 'Italic'])
          'page-test-fonts/$family-$weight$suffix.ttf',
  ];
}

Future<void> _installPagePlatformServices() async {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    const MethodChannel('dev.irondash.engine_context'),
    (call) async {
      if (call.method == 'getEngineHandle') return 1;
      throw MissingPluginException('Unexpected engine method: ${call.method}');
    },
  );
  final native = superNativeExtensionsContext as MockMessageChannelContext;
  native.registerMockMethodCallHandler('DropManager', (call) async {
    if (call.method == 'newContext' || call.method == 'registerDropFormats') {
      return null;
    }
    throw MissingPluginException('Unexpected drop method: ${call.method}');
  });
  native.registerMockMethodCallHandler('DragManager', (call) async {
    if (call.method == 'newContext') return null;
    throw MissingPluginException('Unexpected drag method: ${call.method}');
  });
  final font = File(
    path.join(
      Directory.current.path,
      'assets/fonts/code/JetBrainsMono-Regular.ttf',
    ),
  );
  expect(
    font.existsSync(),
    isTrue,
    reason: 'Use the repository-bundled test font.',
  );
  final bytes = (await font.readAsBytes()).buffer.asByteData();
  font_loader.assetManifest = _PageFontManifest();
  GoogleFonts.config.allowRuntimeFetching = false;
  messenger.setMockMessageHandler('flutter/assets', (message) async {
    if (message == null) return null;
    final name = utf8.decode(
      message.buffer.asUint8List(message.offsetInBytes, message.lengthInBytes),
    );
    if (name.startsWith('page-test-fonts/')) return bytes;
    return null;
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  testWidgets(
    'complete Codex page refreshes from real RPC commits and survives wire faults',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(430, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          SharedPreferences.setMockInitialValues({});
          await _installPagePlatformServices();
          final root = path.normalize(
            path.absolute(Directory.current.path, '..', '..'),
          );
          expect(
            File(
              path.join(root, 'packages/bridge/dist/websocket.js'),
            ).existsSync(),
            isTrue,
            reason: 'Build the real Bridge before running the full-page test.',
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
            environment: {'CCPOCKET_CHAIN_PROVIDER_MODE': 'stdio-json-rpc'},
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
          var stage = 'initial-page';
          var sequence = 0;
          ChatSessionCubit? mountedChat;
          State? mountedPage;
          State? mountedUpdater;

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
          Finder textOnPage(String text) => find.text(text, findRichText: true);
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
            final disclosure = tester.widget<ChatIntermediateOutputsDisclosure>(
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

          void pass(ConversationHotWindowSnapshot window) {
            trace.add({
              'stage': stage,
              'result': 'PASS',
              'revision': window.revision,
              'source': target().fingerprint,
              'rows': chatRows(),
              'renderedText': tester
                  .widgetList<RichText>(find.byType(RichText))
                  .map((widget) => widget.text.toPlainText())
                  .toList(),
              'sync': diagnostics(),
            });
          }

          try {
            bridge.connect(url, logicalConnectionIdentity: 'full-page-harness');
            await eventually(
              () =>
                  bridge.isConnected &&
                  bridge.bridgeInstanceId != null &&
                  bridge.codexSourceId != null,
              'real source identity handshake',
            );
            await openPage();
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
            stage = 'final-outside-collapsed-process';
            await collapsedFinal('Final answer');
            pass(window);
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
            final disclosure = tester.widget<ChatIntermediateOutputsDisclosure>(
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
                  .getTopLeft(textOnPage(expected['assistant-live-segment-a']!))
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
            bridge.connect(url, logicalConnectionIdentity: 'full-page-harness');
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
            trace.add({'stage': 'provider-rpc', 'result': 'PASS', ...provider});
          } catch (error, stack) {
            trace.add({
              'stage': stage,
              'result': 'FAIL',
              'error': '$error',
              'stack': '$stack',
              'sync': diagnostics(),
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
