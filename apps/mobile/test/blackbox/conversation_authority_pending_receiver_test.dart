import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ccpocket/features/chat_session/state/chat_session_cubit.dart';
import 'package:ccpocket/features/chat_session/state/streaming_state_cubit.dart';
import 'package:ccpocket/features/chat_session/widgets/durable_session_preview.dart';
import 'package:ccpocket/features/conversation_content_sync/conversation_content_sync_service.dart';
import 'package:ccpocket/features/session_list/cache/session_catalog_cache_database.dart';
import 'package:ccpocket/features/session_list/cache/session_catalog_cache_repository.dart';
import 'package:ccpocket/features/session_list/state/session_list_cubit.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'harness_ready.dart';

class _AuthorityHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  testWidgets(
    'real authority committed before page observation releases a pending overlay once',
    (tester) async {
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          SharedPreferences.setMockInitialValues({});
          final root = path.normalize(
            path.absolute(Directory.current.path, '..', '..'),
          );
          expect(
            File(
              path.join(root, 'packages/bridge/dist/websocket.js'),
            ).existsSync(),
            isTrue,
            reason: 'Build the real Bridge before the receiver test.',
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
          final threadId = ready['threadId']! as String;
          final turnId = ready['turnId']! as String;
          final traceRoot = ready['traceRoot']! as String;
          var controlSequence = 0;
          Future<void> emitSegment() async {
            final requestId = 'authority-control-${++controlSequence}';
            final response = controls.stream
                .firstWhere((row) => row['requestId'] == requestId)
                .timeout(const Duration(seconds: 12));
            process.stdin.writeln(
              jsonEncode({
                'command': 'emit_segment',
                'requestId': requestId,
                'id': 'assistant-authority-pending',
                'text': 'Producer-authenticated pending commentary',
              }),
            );
            await process.stdin.flush();
            expect((await response)['ok'], isTrue);
          }

          final temporary = await Directory.systemTemp.createTemp(
            'ccpocket_authority_pending_',
          );
          Future<Database> openFfi(String file, OpenDatabaseOptions options) =>
              databaseFactoryFfi.openDatabase(file, options: options);
          final repository = SessionCatalogCacheRepository(
            SessionCatalogCacheDatabase(
              databasePath: path.join(temporary.path, 'cache.db'),
              openDatabase: openFfi,
            ),
          );
          final bridge = BridgeService(
            clientAppVersion: 'headless-authority-pending-receiver',
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
          final streaming = StreamingStateCubit(
            coalesceInterval: Duration.zero,
          );
          ChatSessionCubit? chat;
          final trace = <Map<String, Object?>>[];
          SessionCatalogCacheTarget target() =>
              SessionCatalogCacheTarget.fromBridge(
                bridgeInstanceId: bridge.bridgeInstanceId,
                codexSourceId: bridge.codexSourceId,
                logicalConnectionIdentity: bridge.logicalConnectionIdentity,
                websocketUrl: bridge.lastUrl,
              );
          Future<void> waitForProjection(bool Function() ready) async {
            if (ready()) return;
            await sessionList.catalogSnapshotChanges
                .firstWhere((_) => ready())
                .timeout(const Duration(seconds: 10));
          }

          List<String> assistantIds() => chat!.visibleEntries
              .whereType<ServerChatEntry>()
              .map((entry) => entry.message)
              .whereType<AssistantServerMessage>()
              .map((message) => message.message.id)
              .toList();
          Map<String, Object?> pendingProjection() =>
              chat!.diagnosticRuntimeProjection['timelineProjection']!
                  as Map<String, Object?>;

          Future<void> mount(
            ConversationHotWindowSnapshot window,
            String runtimeId,
          ) async {
            await tester.pumpWidget(
              BlocProvider<SessionListCubit>.value(
                value: sessionList,
                child: BlocProvider<ChatSessionCubit>.value(
                  value: chat!,
                  child: DurableSessionPreviewUpdater(
                    revision: window.revision,
                    messages: window.entries
                        .map((entry) => entry.decodeMessage())
                        .toList(growable: false),
                    hasEarlier: window.hasEarlier,
                    statusProvider: 'codex',
                    statusProviderSessionId: threadId,
                    expectedSourceFingerprint: target().fingerprint,
                    liveRuntimeSessionId: runtimeId,
                    child: const SizedBox.shrink(),
                  ),
                ),
              ),
            );
            await tester.pump();
          }

          try {
            sync.setFocusedConversation(
              provider: 'codex',
              providerSessionId: threadId,
            );
            final bootstrap = sync.syncUpdates
                .firstWhere(
                  (update) =>
                      update.kind == ConversationSyncCacheUpdateKind.completed,
                )
                .timeout(const Duration(seconds: 15));
            bridge.connect(
              ready['url']! as String,
              logicalConnectionIdentity: 'authority-pending-harness',
            );
            await bootstrap;
            final initial = await repository.loadConversationWindow(
              target: target(),
              provider: 'codex',
              providerSessionId: threadId,
            );
            expect(initial, isNotNull);
            expect(initial!.entries, hasLength(1));
            final runtimeFuture = bridge.sessionList
                .expand((rows) => rows)
                .firstWhere((row) => row.claudeSessionId == threadId)
                .timeout(const Duration(seconds: 10));
            bridge.send(
              ClientMessage.start(
                ready['projectPath']! as String,
                sessionId: threadId,
                continueMode: true,
                provider: 'codex',
              ),
            );
            final runtime = await runtimeFuture;
            // The gate is only the absence of the page status observer. All
            // producer, wire, Service and SQLite paths continue normally.
            chat = ChatSessionCubit(
              sessionId: threadId,
              provider: Provider.codex,
              bridge: bridge,
              streamingCubit: streaming,
              detachedPreview: true,
              initialLiveRuntimeSessionId: runtime.id,
              initialHistoryMessages: initial.entries
                  .map((entry) => entry.decodeMessage())
                  .toList(growable: false),
              detachedRuntimeOverlayStream: sync.runtimeOverlays,
            );
            final overlayFuture = sync.runtimeOverlays
                .firstWhere((event) {
                  final message = event.overlayMessage;
                  return message is AssistantServerMessage &&
                      message.message.id == 'assistant-authority-pending';
                })
                .timeout(const Duration(seconds: 10));
            await emitSegment();
            final overlay = await overlayFuture;
            await Future<void>.delayed(Duration.zero);
            await waitForProjection(() {
              final status =
                  sessionList.conversationStatuses['codex\u0000$threadId'];
              return sessionList.hasUsableCatalogForCurrentTarget &&
                  sessionList.conversationSourceFingerprint ==
                      target().fingerprint &&
                  status?.authorityGeneration == overlay.authorityGeneration &&
                  status?.activeTurnId == overlay.turnId;
            });
            final stored = await repository.loadConversationStatus(
              target: target(),
              provider: 'codex',
              providerSessionId: threadId,
            );
            expect(stored, isNotNull);
            expect(overlay.runtimeSessionId, runtime.id);
            expect(overlay.turnId, turnId);
            expect(overlay.authorityGeneration, isNotEmpty);
            expect(stored!.runtimeSessionId, overlay.runtimeSessionId);
            expect(stored.authorityGeneration, overlay.authorityGeneration);
            expect(stored.activeTurnId, overlay.turnId);
            expect(
              chat.diagnosticRuntimeProjection['authorityObserved'],
              isFalse,
            );
            expect(chat.canMutateAttachedRuntime, isFalse);
            expect(pendingProjection()['pendingRuntimeOverlayCount'], 1);
            expect(
              pendingProjection()['pendingRuntimeOverlayBytes'],
              greaterThan(0),
            );
            expect(assistantIds(), isEmpty);
            trace.add({
              'stage': 'sql-committed-page-unobserved',
              'sequence': overlay.sequence,
              'subscriptionId': overlay.subscriptionId,
              'overlayId': overlay.overlayId,
              'runtimeSessionId': overlay.runtimeSessionId,
              'authorityGeneration': overlay.authorityGeneration,
              'turnId': overlay.turnId,
              'eventObservedAt': overlay.observedAt,
              'statusObservedAt': stored.observedAt,
              'runtimeProjection': chat.diagnosticRuntimeProjection,
            });

            await mount(initial, runtime.id);
            final mounted = tester.state(
              find.byType(DurableSessionPreviewUpdater),
            );
            expect(
              chat.diagnosticRuntimeProjection['authorityGeneration'],
              overlay.authorityGeneration,
            );
            expect(pendingProjection()['pendingRuntimeOverlayCount'], 0);
            expect(pendingProjection()['pendingRuntimeOverlayBytes'], 0);
            expect(assistantIds(), ['assistant-authority-pending']);
            trace.add({
              'stage': 'original-page-status-applied',
              'assistantIds': assistantIds(),
              'runtimeProjection': chat.diagnosticRuntimeProjection,
            });
            final canonical = await repository.loadConversationWindow(
              target: target(),
              provider: 'codex',
              providerSessionId: threadId,
            );
            expect(canonical, isNotNull);
            expect(canonical!.entries, hasLength(2));
            await mount(canonical, runtime.id);
            expect(
              tester.state(find.byType(DurableSessionPreviewUpdater)),
              same(mounted),
            );
            expect(assistantIds(), ['assistant-authority-pending']);
            expect(pendingProjection()['pendingRuntimeOverlayCount'], 0);
            expect(pendingProjection()['runtimeOverlayCount'], 0);
            trace.add({
              'stage': 'canonical-takes-over-on-same-page',
              'assistantIds': assistantIds(),
              'runtimeProjection': chat.diagnosticRuntimeProjection,
            });
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            if (chat?.isClosed == false) await chat!.close();
            await streaming.close();
            await sessionList.close();
            await sync.dispose();
            bridge.disconnect();
            await repository.close();
            bridge.dispose();
            process.stdin.writeln(jsonEncode({'command': 'shutdown'}));
            await process.stdin.flush();
            final exit = await process.exitCode.timeout(
              const Duration(seconds: 10),
              onTimeout: () {
                process.kill(ProcessSignal.sigterm);
                return process.exitCode;
              },
            );
            await harness.dispose();
            await controls.close();
            await File(
              path.join(traceRoot, 'authority-pending-receiver.jsonl'),
            ).writeAsString('${trace.map(jsonEncode).join('\n')}\n');
            await temporary.delete(recursive: true);
            expect(exit, 0, reason: 'Bridge harness stderr: ${harness.stderr}');
          }
        }, _AuthorityHttpOverrides()),
      );
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
