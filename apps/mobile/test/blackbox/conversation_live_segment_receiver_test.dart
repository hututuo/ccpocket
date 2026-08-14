import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ccpocket/features/chat_session/state/chat_session_cubit.dart';
import 'package:ccpocket/features/chat_session/state/streaming_state_cubit.dart';
import 'package:ccpocket/features/chat_session/widgets/chat_process_layout.dart';
import 'package:ccpocket/features/conversation_content_sync/conversation_content_sync_service.dart';
import 'package:ccpocket/features/session_list/cache/session_catalog_cache_database.dart';
import 'package:ccpocket/features/session_list/cache/session_catalog_cache_repository.dart';
import 'package:ccpocket/features/session_list/state/session_list_cubit.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/services/bridge_service.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  test(
    'fake app-server items -> real Bridge -> real Mobile receiver keeps segment boundaries',
    () async {
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
      final stdoutLines = harness.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .asBroadcastStream();
      final stderrBuffer = StringBuffer();
      final stderrSub = harness.stderr
          .transform(utf8.decoder)
          .listen(stderrBuffer.write);
      final readyLine = await stdoutLines
          .firstWhere((line) => line.startsWith('READY '))
          .timeout(const Duration(seconds: 15));
      final ready = jsonDecode(readyLine.substring(6)) as Map<String, dynamic>;
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
      final repository = SessionCatalogCacheRepository(
        SessionCatalogCacheDatabase(
          databasePath: path.join(temporaryDirectory.path, 'cache.db'),
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
      final receiverTrace = <Map<String, Object?>>[];

      SessionCatalogCacheTarget cacheTarget() =>
          SessionCatalogCacheTarget.fromBridge(
            bridgeInstanceId: bridge.bridgeInstanceId,
            codexSourceId: bridge.codexSourceId,
            logicalConnectionIdentity: bridge.logicalConnectionIdentity,
            websocketUrl: bridge.lastUrl,
          );

      Future<ConversationHotWindowSnapshot> waitForWindowCount(
        int count,
      ) async {
        final completer = Completer<ConversationHotWindowSnapshot>();
        late final StreamSubscription<ConversationSyncCacheUpdate> sub;
        Future<void> inspect() async {
          if (completer.isCompleted ||
              bridge.bridgeInstanceId?.isNotEmpty != true ||
              bridge.codexSourceId?.isNotEmpty != true) {
            return;
          }
          final window = await repository.loadConversationWindow(
            target: cacheTarget(),
            provider: Provider.codex.value,
            providerSessionId: threadId,
          );
          if (window?.entries.length == count) completer.complete(window);
        }

        sub = sync.syncUpdates.listen((update) {
          if (update.kind == ConversationSyncCacheUpdateKind.timeline &&
              update.provider == Provider.codex.value &&
              update.providerSessionId == threadId &&
              update.pageIndex == (update.pageCount ?? 1) - 1) {
            unawaited(inspect());
          }
        });
        unawaited(inspect());
        try {
          return await completer.future.timeout(const Duration(seconds: 15));
        } finally {
          await sub.cancel();
        }
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

      List<String> assistantIds(ChatSessionCubit value) => value.visibleEntries
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
                row['type'] == 'UserChatEntry' || row['assistantId'] != null,
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

      void applyCurrentProviderProjection() {
        final key = '${Provider.codex.value}\u0000$threadId';
        final sourceFingerprint = sessionList.conversationSourceFingerprint;
        chat!
          ..updateDetachedProviderStatus(
            sessionList.conversationStatuses[key],
            sourceFingerprint: sourceFingerprint,
          )
          ..updateDetachedProviderSettings(
            sessionList.conversationMetadataFor(Provider.codex.value, threadId),
            sourceFingerprint: sourceFingerprint,
          );
      }

      void recordReceiver(String stage, {required bool latestTurnIsActive}) {
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
        final initialWindowFuture = waitForWindowCount(1);
        bridge.connect(url, logicalConnectionIdentity: 'live-segment-harness');
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
        recordReceiver('initial', latestTurnIsActive: false);

        var committed = waitForWindowCount(2);
        await emitSegment(
          id: 'assistant-live-segment-a',
          text: 'First live commentary',
        );
        expect(assistantIds(chat), ['assistant-live-segment-a']);
        recordReceiver('segment-a-live', latestTurnIsActive: true);
        var window = await committed;
        chat.updateDetachedPreviewHistory(
          window.entries
              .map((entry) => entry.decodeMessage())
              .toList(growable: false),
        );
        expect(assistantIds(chat), ['assistant-live-segment-a']);
        recordReceiver('segment-a-sqlite', latestTurnIsActive: true);

        committed = waitForWindowCount(3);
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
        chat.updateDetachedPreviewHistory(
          window.entries
              .map((entry) => entry.decodeMessage())
              .toList(growable: false),
        );
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

        committed = waitForWindowCount(4);
        await emitSegment(
          id: 'assistant-live-final',
          text: 'Final answer',
          completeTurn: true,
        );
        window = await committed;
        final finalMessages = window.entries
            .map((entry) => entry.decodeMessage())
            .toList(growable: false);
        chat.updateDetachedPreviewHistory(finalMessages);
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

        const acceptedClientMessageId = 'client-accepted-before-reopen';
        applyCurrentProviderProjection();
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
          initialHistoryMessages: finalMessages,
        );
        expect(assistantIds(chat), [
          'assistant-live-segment-a',
          'assistant-live-segment-b',
          'assistant-live-final',
        ]);
        expect(streaming.state.isStreaming, isFalse);
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
      } finally {
        await chat?.close();
        await streaming?.close();
        await sessionList.close();
        await sync.dispose();
        bridge.disconnect();
        await repository.close();
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
        await stderrSub.cancel();
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
        expect(exitCode, 0, reason: 'Bridge harness stderr: $stderrBuffer');
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
