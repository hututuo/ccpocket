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

class _ReloadHttpOverrides extends HttpOverrides {}

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

  for (final suspendBeforeRetry in [false, true]) {
    testWidgets(
      'real cached reload and same source retry recover suspended=$suspendBeforeRetry',
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
              'ccpocket_status_reload_',
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
              clientAppVersion: 'headless-status-reload-receiver',
            );
            final sync = ConversationContentSyncService(
              bridge: BridgeServiceConversationContentSyncGateway(bridge),
              cache: repository,
            )..start(initialLifecycleState: AppLifecycleState.resumed);
            var sessionList = SessionListCubit(
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
              final itemSyncCompleted = sync.syncUpdates
                  .where(
                    (update) =>
                        update.kind ==
                        ConversationSyncCacheUpdateKind.completed,
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
                        window?.entries.any((entry) {
                          final message = entry.decodeMessage();
                          return message is AssistantServerMessage &&
                              message.message.id == 'assistant-status-reload';
                        }) ==
                        true,
                  )
                  .then((window) => window!)
                  .timeout(const Duration(seconds: 10));
              final delivered = await Future.wait<Object>([
                control('emit_segment', {
                  'id': 'assistant-status-reload',
                  'text': 'Canonical commentary before same source retry',
                }),
                overlayFor('assistant-status-reload'),
                canonicalContaining('assistant-status-reload'),
                itemSyncCompleted,
              ]);
              final event = delivered[1] as ConversationSyncV2EventMessage;
              final canonical = delivered[2] as ConversationHotWindowSnapshot;
              await waitForProjection(() {
                final current =
                    sessionList.conversationStatuses['codex\u0000$threadId'];
                return current?.authorityGeneration ==
                    event.authorityGeneration;
              });
              final live =
                  sessionList.conversationStatuses['codex\u0000$threadId']!;
              final stored = await repository.loadConversationStatus(
                target: target(),
                provider: 'codex',
                providerSessionId: threadId,
              );
              expect(stored!.toJson(), live.toJson());
              expect(stored.commitReceipt, isNull);
              await mount(canonical, runtime.id);
              final mounted = tester.state(
                find.byType(DurableSessionPreviewUpdater),
              );
              expect(chat!.canMutateAttachedRuntime, isTrue);
              expect(assistantIds(), ['assistant-status-reload']);
              trace.add({
                'stage': 'live-commit-and-sql-receiptless',
                'status': live.toJson(),
                'receiptSubscription': live.commitReceipt?.subscriptionId,
                'receiptSequence': live.commitReceipt?.sequence,
                'runtimeProjection': chat.diagnosticRuntimeProjection,
              });
              if (suspendBeforeRetry) {
                // This is the original public owner withdrawal used by the
                // Updater during source reconciliation. Wire/SQL stay untouched.
                chat.suspendDetachedProviderProjection(
                  reason: 'receiver_source_reconciliation',
                );
                expect(chat.canMutateAttachedRuntime, isFalse);
                expect(chat.state.status, ProcessStatus.running);
              }
              final resumed = sync.syncUpdates
                  .firstWhere(
                    (update) =>
                        update.kind ==
                        ConversationSyncCacheUpdateKind.completed,
                  )
                  .timeout(const Duration(seconds: 10));
              final retryStatusCommits = <ConversationSyncCacheUpdate>[];
              final lifecycleObserver = sync.syncUpdates.listen((update) {
                if (update.kind == ConversationSyncCacheUpdateKind.status)
                  retryStatusCommits.add(update);
                if (update.kind == ConversationSyncCacheUpdateKind.started) {
                  final projected =
                      sessionList.conversationStatuses['codex\u0000$threadId'];
                  trace.add({
                    'stage': 'same-source-subscription-started',
                    'targetFingerprint': update.targetFingerprint,
                    'retainedReceiptSubscription':
                        projected?.commitReceipt?.subscriptionId,
                    'retainedReceiptSequence':
                        projected?.commitReceipt?.sequence,
                    'retainedStatus': projected?.toJson(),
                    'runtimeProjection': chat?.diagnosticRuntimeProjection,
                  });
                }
              });
              try {
                expect(
                  sync.retryBootstrap(reason: 'receiver_same_source_retry'),
                  isTrue,
                );
                await resumed;
                await tester.pump();
                final retained =
                    sessionList.conversationStatuses['codex\u0000$threadId']!;
                expect(retained.toJson(), live.toJson());
                expect(retryStatusCommits, isEmpty);
                expect(chat.canMutateAttachedRuntime, !suspendBeforeRetry);
                final newSubscription = sync
                    .diagnosticSnapshot()['activeSubscriptionId'];
                expect(newSubscription, isNot(event.subscriptionId));
                trace.add({
                  'stage': 'same-source-resume-without-status-replay',
                  'subscription': newSubscription,
                  'oldSubscription': event.subscriptionId,
                  'status': retained.toJson(),
                  'statusCommits': retryStatusCommits.length,
                  'runtimeProjection': chat.diagnosticRuntimeProjection,
                });
              } finally {
                await lifecycleObserver.cancel();
              }
              // An actual same-public-ID process replacement provides new
              // authority facts. No cross-subscription sequence comparison is
              // used by the page to obtain that current owner.
              final replaced = await control('replace_runtime');
              expect(replaced['runtimeId'], runtime.id);
              expect(replaced['oldAuthority'], live.authorityGeneration);
              expect(replaced['newAuthority'], isNot(live.authorityGeneration));
              await waitForProjection(() {
                final current =
                    sessionList.conversationStatuses['codex\u0000$threadId'];
                return current?.authorityGeneration ==
                        replaced['newAuthority'] &&
                    current?.commitReceipt != null;
              });
              final fresh =
                  sessionList.conversationStatuses['codex\u0000$threadId']!;
              expect(
                fresh.commitReceipt!.subscriptionId,
                isNot(event.subscriptionId),
              );
              expect(fresh.commitReceipt!.sequence, lessThan(event.sequence));
              await tester.pump();
              trace.add({
                'stage': 'actual-new-authority-on-new-subscription',
                'status': fresh.toJson(),
                'receiptSubscription': fresh.commitReceipt!.subscriptionId,
                'receiptSequence': fresh.commitReceipt!.sequence,
                'runtimeProjection': chat.diagnosticRuntimeProjection,
              });
              expect(chat.canMutateAttachedRuntime, isTrue);
              expect(
                chat.diagnosticRuntimeProjection['authorityGeneration'],
                replaced['newAuthority'],
              );
              expect(
                tester.state(find.byType(DurableSessionPreviewUpdater)),
                same(mounted),
              );
              expect(assistantIds(), ['assistant-status-reload']);

              // Recreate the original SessionList consumer on the same SQL
              // partition. Its constructor actually reloads cached status;
              // same-target session_list notifications alone skip that reload.
              final previousList = sessionList;
              sessionList = SessionListCubit(
                bridge: bridge,
                catalogCache: repository,
                conversationSync: sync,
              );
              try {
                await waitForProjection(
                  () =>
                      sessionList
                          .conversationStatuses['codex\u0000$threadId'] !=
                      null,
                );
                final reread =
                    sessionList.conversationStatuses['codex\u0000$threadId']!;
                expect(reread.toJson(), fresh.toJson());
                expect(reread.commitReceipt, isNull);
                await mount(canonical, runtime.id);
                expect(
                  tester.state(find.byType(DurableSessionPreviewUpdater)),
                  same(mounted),
                );
                expect(
                  chat.diagnosticRuntimeProjection['statusCommitSequence'],
                  isNull,
                );
                expect(chat.canMutateAttachedRuntime, isTrue);
                expect(assistantIds(), ['assistant-status-reload']);
                expect(projection()['runtimeOverlayCount'], 0);
                expect(projection()['pendingRuntimeOverlayCount'], 0);
                trace.add({
                  'stage': 'same-page-real-sql-cache-reread',
                  'status': reread.toJson(),
                  'runtimeProjection': chat.diagnosticRuntimeProjection,
                  'assistantIds': assistantIds(),
                });
              } finally {
                await previousList.close();
              }
              await tester.pumpWidget(const SizedBox.shrink());
              await sessionList.close();
              await sync.dispose();
              bridge.disconnect();
              await repository.close();
              final reopened = SessionCatalogCacheRepository(
                SessionCatalogCacheDatabase(
                  databasePath: path.join(temporary.path, 'cache.db'),
                  openDatabase: openFfi,
                ),
              );
              try {
                final cached = await reopened.loadConversationStatus(
                  target: target(),
                  provider: 'codex',
                  providerSessionId: threadId,
                );
                expect(cached, isNotNull);
                expect(cached!.toJson(), fresh.toJson());
                expect(cached.commitReceipt, isNull);
                trace.add({
                  'stage': 'sqlite-close-reopen',
                  'status': cached.toJson(),
                  'receiptAbsent': cached.commitReceipt == null,
                });
              } finally {
                await reopened.close();
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
              if (!sessionList.isClosed) await sessionList.close();
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
                path.join(traceRoot, 'status-reload-receiver.jsonl'),
              ).writeAsString('${trace.map(jsonEncode).join('\n')}\n');
              await temporary.delete(recursive: true);
              expect(
                exit,
                0,
                reason: 'Bridge harness stderr: ${harness.stderr}',
              );
            }
          }, _ReloadHttpOverrides()),
        );
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );
  }
}
