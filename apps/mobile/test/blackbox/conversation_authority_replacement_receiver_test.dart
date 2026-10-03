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

class _ReplacementHttpOverrides extends HttpOverrides {}

Future<HarnessReadyResult> _waitForOwnedHarnessReady(
  Process process, {
  Duration timeout = const Duration(seconds: 15),
  void Function(Map<String, dynamic> response)? onControl,
}) async {
  HarnessReadyResult? harness;
  try {
    harness = await waitForHarnessReady(
      process,
      timeout: timeout,
      onControl: onControl,
    );
    final ready = jsonDecode(harness.readyLine.substring(6));
    if (ready is! Map<String, dynamic>) {
      throw const FormatException('READY must contain an object');
    }
    for (final field in [
      'url',
      'threadId',
      'turnId',
      'traceRoot',
      'projectPath',
    ]) {
      final value = ready[field];
      if (value is! String || value.isEmpty) {
        throw FormatException('READY requires a nonempty $field');
      }
    }
    return harness;
  } catch (_) {
    await harness?.dispose();
    process.kill(ProcessSignal.sigterm);
    await process.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return process.exitCode;
      },
    );
    rethrow;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  for (final emitNewItem in [false, true]) {
    testWidgets(
      'real same ID replacement retires received A with new B item=$emitNewItem',
      (tester) async {
        await tester.runAsync(
          () => HttpOverrides.runWithHttpOverrides(() async {
            SharedPreferences.setMockInitialValues({});
            final root = path.normalize(
              path.absolute(Directory.current.path, '..', '..'),
            );
            final process = await Process.start(
              Platform.environment['CCPOCKET_NODE'] ?? 'node',
              [
                '--import',
                'tsx',
                path.join(
                  root,
                  'packages/bridge/scripts/conversation-authority-receiver-harness.mjs',
                ),
              ],
              workingDirectory: root,
            );
            final controls = StreamController<Map<String, dynamic>>.broadcast();
            late final HarnessReadyResult harness;
            try {
              harness = await _waitForOwnedHarnessReady(
                process,
                onControl: controls.add,
              );
            } catch (_) {
              await controls.close();
              rethrow;
            }
            final ready =
                jsonDecode(harness.readyLine.substring(6))
                    as Map<String, dynamic>;
            final threadId = ready['threadId']! as String;
            final turnId = ready['turnId']! as String;
            final traceRoot = ready['traceRoot']! as String;
            var controlSequence = 0;
            Future<Map<String, dynamic>> control(
              String command, [
              Map<String, Object?> values = const {},
            ]) async {
              final requestId = 'replacement-control-${++controlSequence}';
              final response = controls.stream
                  .firstWhere((row) => row['requestId'] == requestId)
                  .timeout(const Duration(seconds: 12));
              process.stdin.writeln(
                jsonEncode({
                  'command': command,
                  'requestId': requestId,
                  ...values,
                }),
              );
              await process.stdin.flush();
              final result = await response;
              expect(result['ok'], isTrue, reason: '$result');
              return result;
            }

            final temporary = await Directory.systemTemp.createTemp(
              'ccpocket_authority_replacement_',
            );
            Future<Database> openFfi(
              String file,
              OpenDatabaseOptions options,
            ) => databaseFactoryFfi.openDatabase(file, options: options);
            final repository = SessionCatalogCacheRepository(
              SessionCatalogCacheDatabase(
                databasePath: path.join(temporary.path, 'cache.db'),
                openDatabase: openFfi,
              ),
            );
            final bridge = BridgeService(
              clientAppVersion: 'headless-authority-replacement-receiver',
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
            Map<String, Object?> projection() =>
                chat!.diagnosticRuntimeProjection['timelineProjection']!
                    as Map<String, Object?>;
            Future<ConversationHotWindowSnapshot> canonicalContaining(
              String id,
            ) => sync.syncUpdates
                .where(
                  (update) =>
                      update.kind == ConversationSyncCacheUpdateKind.timeline &&
                      update.provider == 'codex' &&
                      update.providerSessionId == threadId,
                )
                .asyncMap(
                  (_) => repository.loadConversationWindow(
                    target: target(),
                    provider: 'codex',
                    providerSessionId: threadId,
                  ),
                )
                .firstWhere(
                  (window) =>
                      window != null &&
                      window.entries.any((entry) {
                        final message = entry.decodeMessage();
                        return message is AssistantServerMessage &&
                            message.message.id == id;
                      }),
                )
                .then((window) => window!)
                .timeout(const Duration(seconds: 10));
            Future<ConversationSyncV2EventMessage> overlayFor(String id) => sync
                .runtimeOverlays
                .firstWhere((event) {
                  final message = event.overlayMessage;
                  return message is AssistantServerMessage &&
                      message.message.id == id;
                })
                .timeout(const Duration(seconds: 10));
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
                        update.kind ==
                        ConversationSyncCacheUpdateKind.completed,
                  )
                  .timeout(const Duration(seconds: 15));
              bridge.connect(
                ready['url']! as String,
                logicalConnectionIdentity: 'authority-replacement-harness',
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
              final initializedFuture = bridge.messages
                  .firstWhere(
                    (message) =>
                        message is SystemMessage &&
                        message.subtype == 'init' &&
                        message.provider == 'codex',
                  )
                  .timeout(const Duration(seconds: 10));
              final startup = Future.wait<Object>([
                runtimeFuture,
                initializedFuture,
              ]);
              bridge.send(
                ClientMessage.start(
                  ready['projectPath']! as String,
                  sessionId: threadId,
                  continueMode: true,
                  provider: 'codex',
                ),
              );
              final started = await startup;
              final runtime = started[0] as SessionInfo;
              expect((started[1] as SystemMessage).sessionId, runtime.id);
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
              // All listeners are joined before emitting raw Provider facts.
              final deliveredA = await Future.wait<Object>([
                control('emit_segment', {
                  'id': 'assistant-replaced-A',
                  'text': 'Already received old process commentary',
                }),
                overlayFor('assistant-replaced-A'),
                canonicalContaining('assistant-replaced-A'),
              ]);
              final a = deliveredA[1] as ConversationSyncV2EventMessage;
              await Future<void>.delayed(Duration.zero);
              await waitForProjection(
                () =>
                    sessionList
                        .conversationStatuses['codex\u0000$threadId']
                        ?.authorityGeneration ==
                    a.authorityGeneration,
              );
              final storedA = await repository.loadConversationStatus(
                target: target(),
                provider: 'codex',
                providerSessionId: threadId,
              );
              expect(storedA, isNotNull);
              expect(a.runtimeSessionId, runtime.id);
              expect(a.turnId, turnId);
              expect(storedA!.authorityGeneration, a.authorityGeneration);
              expect(
                chat.diagnosticRuntimeProjection['authorityObserved'],
                isFalse,
              );
              expect(chat.canMutateAttachedRuntime, isFalse);
              expect(projection()['pendingRuntimeOverlayCount'], 1);
              expect(
                projection()['pendingRuntimeOverlayBytes'],
                greaterThan(0),
              );
              expect(assistantIds(), isEmpty);
              trace.add({
                'stage': 'A-sql-committed-page-unobserved',
                'runtimeId': runtime.id,
                'overlayId': a.overlayId,
                'authority': a.authorityGeneration,
                'eventObservedAt': a.observedAt,
                'statusObservedAt': storedA.observedAt,
                'runtimeProjection': chat.diagnosticRuntimeProjection,
              });

              // The original replacement Promise resolves after B is ready and
              // owns the runtime map. Its bootstrap init is intentionally not
              // forwarded before that swap. V2/SQL below independently proves
              // Mobile received the actual B status, rather than trusting ACK.
              final replaced = await control('replace_runtime');
              final bAuthority = replaced['newAuthority']! as String;
              expect(replaced['runtimeId'], runtime.id);
              expect(replaced['oldAuthority'], a.authorityGeneration);
              expect(bAuthority, isNot(a.authorityGeneration));
              await waitForProjection(
                () =>
                    sessionList.hasUsableCatalogForCurrentTarget &&
                    sessionList.conversationSourceFingerprint ==
                        target().fingerprint &&
                    sessionList
                            .conversationStatuses['codex\u0000$threadId']
                            ?.authorityGeneration ==
                        bAuthority,
              );
              final storedB = await repository.loadConversationStatus(
                target: target(),
                provider: 'codex',
                providerSessionId: threadId,
              );
              expect(storedB, isNotNull);
              expect(storedB!.runtimeSessionId, runtime.id);
              expect(storedB.authorityGeneration, bAuthority);
              expect(projection()['pendingRuntimeOverlayCount'], 1);
              trace.add({
                'stage': 'B-replaced-without-new-notification',
                'runtimeId': runtime.id,
                'oldAuthority': a.authorityGeneration,
                'newAuthority': bAuthority,
                'eventObservedAtA': a.observedAt,
                'statusObservedAtB': storedB.observedAt,
                'producerBefore': replaced['before'],
                'producerAfter': replaced['after'],
                'runtimeProjection': chat.diagnosticRuntimeProjection,
              });
              ConversationHotWindowSnapshot? canonicalB;
              if (emitNewItem) {
                final deliveredB = await Future.wait<Object>([
                  control('emit_segment', {
                    'id': 'assistant-current-B',
                    'text': 'Unobserved new process commentary',
                  }),
                  overlayFor('assistant-current-B'),
                  canonicalContaining('assistant-current-B'),
                ]);
                final b = deliveredB[1] as ConversationSyncV2EventMessage;
                canonicalB = deliveredB[2] as ConversationHotWindowSnapshot;
                await Future<void>.delayed(Duration.zero);
                await waitForProjection(() {
                  final status =
                      sessionList.conversationStatuses['codex\u0000$threadId'];
                  return status?.authorityGeneration == bAuthority &&
                      status?.activeTurnId == b.turnId;
                });
                expect(b.runtimeSessionId, runtime.id);
                expect(b.authorityGeneration, bAuthority);
                expect(b.turnId, turnId);
                expect(projection()['pendingRuntimeOverlayCount'], 2);
                expect(chat.canMutateAttachedRuntime, isFalse);
                expect(assistantIds(), isEmpty);
                trace.add({
                  'stage': 'B-item-delivered-page-unobserved',
                  'runtimeId': runtime.id,
                  'authority': b.authorityGeneration,
                  'overlayId': b.overlayId,
                  'eventObservedAt': b.observedAt,
                  'runtimeProjection': chat.diagnosticRuntimeProjection,
                });
              }
              final beforeMountStatus =
                  sessionList.conversationStatuses['codex\u0000$threadId'];
              trace.add({
                'stage': 'B-status-before-original-page-mount',
                'authority': beforeMountStatus?.authorityGeneration,
                'statusObservedAt': beforeMountStatus?.observedAt,
                'pendingCount': projection()['pendingRuntimeOverlayCount'],
              });
              await mount(initial, runtime.id);
              final mounted = tester.state(
                find.byType(DurableSessionPreviewUpdater),
              );
              trace.add({
                'stage': 'B-status-applied-on-original-page',
                'statusObservedAt': sessionList
                    .conversationStatuses['codex\u0000$threadId']
                    ?.observedAt,
                'assistantIds': assistantIds(),
                'runtimeProjection': chat.diagnosticRuntimeProjection,
              });
              expect(
                chat.diagnosticRuntimeProjection['authorityGeneration'],
                bAuthority,
              );
              expect(
                projection()['pendingRuntimeOverlayCount'],
                0,
                reason:
                    'Already received retired A must not occupy the bounded queue after original page observes actual replacement B.',
              );
              expect(projection()['pendingRuntimeOverlayBytes'], 0);
              expect(
                assistantIds(),
                emitNewItem ? ['assistant-current-B'] : isEmpty,
              );
              if (emitNewItem) {
                await mount(canonicalB!, runtime.id);
                expect(
                  tester.state(find.byType(DurableSessionPreviewUpdater)),
                  same(mounted),
                );
                // A remains valid durable history; only its old runtime lease
                // retires. Canonical truth may include A and B exactly once.
                expect(assistantIds(), [
                  'assistant-replaced-A',
                  'assistant-current-B',
                ]);
                expect(projection()['runtimeOverlayCount'], 0);
                expect(projection()['pendingRuntimeOverlayCount'], 0);
                trace.add({
                  'stage': 'canonical-A-and-B-on-same-page',
                  'assistantIds': assistantIds(),
                  'runtimeProjection': chat.diagnosticRuntimeProjection,
                });
              }
            } catch (error) {
              trace.add({
                'stage': 'receiver-failure',
                'error': error.toString(),
                'runtimeProjection': chat?.diagnosticRuntimeProjection,
              });
              rethrow;
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
                  return process.exitCode.timeout(
                    const Duration(seconds: 10),
                    onTimeout: () {
                      process.kill(ProcessSignal.sigkill);
                      return process.exitCode;
                    },
                  );
                },
              );
              await harness.dispose();
              await controls.close();
              await File(
                path.join(traceRoot, 'authority-replacement-receiver.jsonl'),
              ).writeAsString('${trace.map(jsonEncode).join('\n')}\n');
              await temporary.delete(recursive: true);
              expect(
                exit,
                0,
                reason: 'Bridge harness stderr: ${harness.stderr}',
              );
            }
          }, _ReplacementHttpOverrides()),
        );
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );
  }
}
