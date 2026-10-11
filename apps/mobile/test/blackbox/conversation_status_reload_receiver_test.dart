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
            final statusFrames = <ConversationSyncV2EventMessage>[];
            ConversationSyncV2EventMessage? lastStatusBatch;
            ConversationSyncV2EventMessage? lastCompletedBatch;
            ConversationSyncCacheUpdate? lastCompletedCommit;
            String? lastCompletedSubscriptionId;
            final completionObserver = sync.syncUpdates.listen((update) {
              if (update.kind == ConversationSyncCacheUpdateKind.completed) {
                lastCompletedCommit = update;
                lastCompletedSubscriptionId =
                    sync.diagnosticSnapshot(
                          provider: 'codex',
                          providerSessionId: threadId,
                        )['activeSubscriptionId']
                        as String?;
              }
            });
            final wireObserver = bridge.messages.listen((message) {
              if (message is! ConversationSyncV2EventMessage) return;
              if (message.event == ConversationSyncV2EventKind.statusChanges) {
                statusFrames.add(message);
                if (message.statusChanges.any(
                  (status) =>
                      status.provider == 'codex' &&
                      status.providerSessionId == threadId,
                )) {
                  lastStatusBatch = message;
                }
              } else if (message.event ==
                  ConversationSyncV2EventKind.syncComplete) {
                lastCompletedBatch = message;
              }
            });
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

            Future<
              ({
                ConversationSyncV2Status sql,
                ConversationSyncV2Status catalog,
                String subscriptionId,
                int sequence,
              })
            >
            committedStatus(String authority) async {
              final changes = StreamController<void>();
              final observer = sync.syncUpdates.listen(
                (_) => changes.add(null),
              );
              final catalogObserver = sessionList.catalogSnapshotChanges.listen(
                (_) => changes.add(null),
              );
              final result = changes.stream
                  .asyncMap((_) async {
                    final statusBatch = lastStatusBatch;
                    final completedBatch = lastCompletedBatch;
                    if (statusBatch == null ||
                        completedBatch == null ||
                        (completedBatch.subscriptionId ==
                                statusBatch.subscriptionId &&
                            completedBatch.sequence <= statusBatch.sequence) ||
                        lastCompletedCommit?.sequence !=
                            completedBatch.sequence ||
                        lastCompletedSubscriptionId !=
                            completedBatch.subscriptionId ||
                        completedBatch.nextState?.statusState !=
                            statusBatch.statusState ||
                        sync.diagnosticSnapshot(
                              provider: 'codex',
                              providerSessionId: threadId,
                            )['activeSubscriptionId'] !=
                            completedBatch.subscriptionId) {
                      return null;
                    }
                    final sql = await repository.loadConversationStatus(
                      target: target(),
                      provider: 'codex',
                      providerSessionId: threadId,
                    );
                    final resume = await repository.loadConversationSyncState(
                      target(),
                    );
                    final catalog = sessionList
                        .conversationStatuses['codex\u0000$threadId'];
                    if (sql == null ||
                        catalog == null ||
                        !identical(statusBatch, lastStatusBatch) ||
                        !identical(completedBatch, lastCompletedBatch) ||
                        resume.statusState != statusBatch.statusState ||
                        sql.authorityGeneration != authority ||
                        jsonEncode(sql.toJson()) !=
                            jsonEncode(catalog.toJson())) {
                      return null;
                    }
                    return (
                      sql: sql,
                      catalog: catalog,
                      subscriptionId: completedBatch.subscriptionId,
                      sequence: completedBatch.sequence,
                    );
                  })
                  .firstWhere((sample) => sample != null)
                  .then((sample) => sample!)
                  .timeout(const Duration(seconds: 10));
              // SQL commit, catalog projection and sync completion have separate
              // notifications. Observe all of them before the first real read;
              // a matching business row alone does not prove resume is settled.
              changes.add(null);
              try {
                return await result;
              } finally {
                await observer.cancel();
                await catalogObserver.cancel();
                await changes.close();
              }
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
              // The real Updater expects its first revision to match the
              // Cubit's constructor history; subsequent revisions apply via
              // didUpdateWidget. Mount that actual initial SQL window first.
              await mount(initial, runtime.id);
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
              final sample = await committedStatus(event.authorityGeneration!);
              final live = sample.catalog;
              final stored = sample.sql;
              expect(stored.toJson(), live.toJson());
              expect(stored.commitReceipt, isNull);
              await mount(canonical, runtime.id);
              final mounted = tester.state(
                find.byType(DurableSessionPreviewUpdater),
              );
              expect(chat.canMutateAttachedRuntime, isTrue);
              expect(assistantIds(), ['assistant-status-reload']);
              expect(projection()['runtimeOverlayCount'], 0);
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
                if (update.kind == ConversationSyncCacheUpdateKind.status) {
                  retryStatusCommits.add(update);
                }
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
                final resumedSample = await committedStatus(
                  event.authorityGeneration!,
                );
                final retained = resumedSample.catalog;
                final newSubscription = sync.diagnosticSnapshot(
                  provider: 'codex',
                  providerSessionId: threadId,
                )['activeSubscriptionId'];
                expect(newSubscription, isNot(event.subscriptionId));
                expect(newSubscription, resumedSample.subscriptionId);
                // Resume may legitimately replay status when its token changed
                // during the preceding batch. Compare every committed page to
                // actual wire facts, rather than assuming the producer was idle.
                final replayFrames = statusFrames
                    .where(
                      (frame) =>
                          frame.subscriptionId == newSubscription &&
                          frame.sequence <= resumedSample.sequence,
                    )
                    .toList();
                final committedReplayPages = retryStatusCommits
                    .where(
                      (update) => update.sequence! <= resumedSample.sequence,
                    )
                    .toList();
                // This fixture has one catalog thread, hence one status page.
                // Multi-page aggregation is covered by the Service contracts.
                for (final frame in replayFrames) {
                  expect(frame.pageIndex, 0);
                  expect(frame.pageCount, 1);
                }
                expect(
                  committedReplayPages
                      .map(
                        (update) => [
                          update.sequence,
                          update.statusChanges
                              .map((status) => status.toJson())
                              .toList(),
                        ],
                      )
                      .toList(),
                  replayFrames
                      .map(
                        (frame) => [
                          frame.sequence,
                          frame.statusChanges
                              .map((status) => status.toJson())
                              .toList(),
                        ],
                      )
                      .toList(),
                );
                final replayedStatuses = committedReplayPages
                    .expand((update) => update.statusChanges)
                    .where(
                      (status) =>
                          status.provider == 'codex' &&
                          status.providerSessionId == threadId,
                    )
                    .toList();
                if (replayedStatuses.isEmpty) {
                  expect(retained.toJson(), live.toJson());
                  expect(chat.canMutateAttachedRuntime, !suspendBeforeRetry);
                } else {
                  final lastReplay = replayedStatuses.last;
                  expect(retained.toJson(), lastReplay.toJson());
                  expect(resumedSample.sql.toJson(), lastReplay.toJson());
                  expect(
                    lastReplay.authorityGeneration,
                    live.authorityGeneration,
                  );
                  expect(lastReplay.runtimeSessionId, runtime.id);
                  expect(
                    lastReplay.commitReceipt!.subscriptionId,
                    newSubscription,
                  );
                  expect(chat.canMutateAttachedRuntime, isTrue);
                }
                for (final update in committedReplayPages) {
                  for (final status in update.statusChanges) {
                    expect(
                      status.commitReceipt!.subscriptionId,
                      newSubscription,
                    );
                    expect(status.commitReceipt!.sequence, update.sequence);
                    expect(
                      status.commitReceipt!.sourceFingerprint,
                      target().fingerprint,
                    );
                  }
                }
                trace.add({
                  'stage': 'same-source-resume-actual-commits',
                  'subscription': newSubscription,
                  'oldSubscription': event.subscriptionId,
                  'status': retained.toJson(),
                  'statusCommits': committedReplayPages.length,
                  'completeSequence': resumedSample.sequence,
                  'replayedStatusCount': replayedStatuses.length,
                  'wireStatusSequences': replayFrames
                      .map((frame) => frame.sequence)
                      .toList(),
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

              // Stop and join this test's receiver before exercising cached-only
              // consumers. Runtime activity may keep advancing observedAt while
              // the live subscription runs; it is not a frozen SQL snapshot.
              await sync.dispose();
              final persistedStatus = await repository.loadConversationStatus(
                target: target(),
                provider: 'codex',
                providerSessionId: threadId,
              );
              expect(persistedStatus, isNotNull);
              expect(
                persistedStatus!.authorityGeneration,
                replaced['newAuthority'],
              );
              expect(persistedStatus.runtimeSessionId, runtime.id);
              expect(persistedStatus.commitReceipt, isNull);
              expect(
                statusFrames
                    .expand((frame) => frame.statusChanges)
                    .any(
                      (status) =>
                          jsonEncode(status.toJson()) ==
                          jsonEncode(persistedStatus.toJson()),
                    ),
                isTrue,
              );

              // Recreate the original SessionList consumer on the same SQL
              // partition. Its constructor actually reloads cached status;
              // same-target session_list notifications alone skip that reload.
              // The Updater binds the app's long-lived SessionList through
              // context.read, so recreating that consumer also recreates its
              // observer. The detached Cubit and its canonical history survive.
              await tester.pumpWidget(const SizedBox.shrink());
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
                expect(reread.toJson(), persistedStatus.toJson());
                expect(reread.commitReceipt, isNull);
                await mount(canonical, runtime.id);
                expect(
                  tester.state(find.byType(DurableSessionPreviewUpdater)),
                  isNot(same(mounted)),
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
              final persistedTarget = target();
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
                  target: persistedTarget,
                  provider: 'codex',
                  providerSessionId: threadId,
                );
                expect(cached, isNotNull);
                expect(cached!.toJson(), persistedStatus.toJson());
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
              await wireObserver.cancel();
              await completionObserver.cancel();
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
