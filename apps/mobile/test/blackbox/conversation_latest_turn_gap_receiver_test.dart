import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ccpocket/features/chat_session/state/chat_session_cubit.dart';
import 'package:ccpocket/features/chat_session/state/streaming_state_cubit.dart';
import 'package:ccpocket/features/chat_session/widgets/chat_process_layout.dart';
import 'package:ccpocket/features/conversation_content_sync/conversation_content_sync_service.dart';
import 'package:ccpocket/features/session_list/cache/session_catalog_cache_database.dart';
import 'package:ccpocket/features/session_list/cache/session_catalog_cache_repository.dart';
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
    'unsupported provider item paging still repairs oversized latest turn end to end',
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
      final harness = await Process.start(
        node,
        [harnessPath],
        workingDirectory: repositoryRoot,
        environment: {
          ...Platform.environment,
          'CCPOCKET_CHAIN_SCENARIO': 'latest-turn-gap',
        },
      );
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
      expect(ready['scenario'], 'latest-turn-gap');
      final url = ready['url']! as String;
      final threadId = ready['threadId']! as String;
      final traceRoot = ready['traceRoot']! as String;

      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'ccpocket_latest_turn_gap_receiver_',
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
        clientAppVersion: 'headless-latest-turn-gap-receiver',
      );
      final sync = ConversationContentSyncService(
        bridge: BridgeServiceConversationContentSyncGateway(bridge),
        cache: repository,
      )..start(initialLifecycleState: AppLifecycleState.resumed);

      try {
        sync.setFocusedConversation(
          provider: Provider.codex.value,
          providerSessionId: threadId,
        );
        bridge.connect(
          url,
          logicalConnectionIdentity: 'latest-turn-gap-harness',
        );
        await bridge.connectionStatus
            .firstWhere((state) => state == BridgeConnectionState.connected)
            .timeout(const Duration(seconds: 10));

        final repaired = Completer<ConversationHotWindowSnapshot>();
        late final StreamSubscription<ConversationContentCacheUpdate> updates;
        Future<void> inspect() async {
          if (repaired.isCompleted ||
              bridge.bridgeInstanceId?.isNotEmpty != true ||
              bridge.codexSourceId?.isNotEmpty != true) {
            return;
          }
          final snapshot = await repository.loadConversationWindow(
            target: SessionCatalogCacheTarget.fromBridge(
              bridgeInstanceId: bridge.bridgeInstanceId,
              codexSourceId: bridge.codexSourceId,
              logicalConnectionIdentity: bridge.logicalConnectionIdentity,
              websocketUrl: bridge.lastUrl,
            ),
            provider: Provider.codex.value,
            providerSessionId: threadId,
          );
          if (snapshot?.latestTurnComplete == true) {
            repaired.complete(snapshot!);
          }
        }

        updates = sync.updates.listen((update) {
          if (update.provider == Provider.codex.value &&
              update.providerSessionId == threadId) {
            unawaited(inspect());
          }
        });
        unawaited(inspect());
        final snapshot = await repaired.future.timeout(
          const Duration(seconds: 30),
        );
        await updates.cancel();

        final messages = snapshot.entries
            .map((entry) => entry.decodeMessage())
            .toList(growable: false);
        final assistantTexts = messages
            .whereType<AssistantServerMessage>()
            .expand(
              (message) => message.message.content.whereType<TextContent>(),
            )
            .map((content) => content.text)
            .toList(growable: false);
        final processTexts = messages
            .whereType<AssistantServerMessage>()
            .expand((message) => message.message.content)
            .map(
              (content) => switch (content) {
                TextContent(:final text) => text,
                ThinkingContent(:final thinking) => thinking,
                _ => null,
              },
            )
            .whereType<String>()
            .toList(growable: false);
        expect(
          assistantTexts.where(
            (text) => text == 'Commentary before oversized tool',
          ),
          hasLength(1),
        );
        expect(
          assistantTexts.where(
            (text) => text == 'Commentary after oversized tool',
          ),
          hasLength(1),
        );
        expect(
          processTexts.where(
            (text) => text == 'Reasoning after oversized tool',
          ),
          hasLength(1),
        );
        expect(
          processTexts.indexOf('Commentary before oversized tool'),
          lessThan(processTexts.indexOf('Reasoning after oversized tool')),
        );
        expect(
          processTexts.indexOf('Reasoning after oversized tool'),
          lessThan(processTexts.indexOf('Commentary after oversized tool')),
        );
        expect(
          processTexts.indexOf('Commentary after oversized tool'),
          lessThan(processTexts.indexOf('Final answer after oversized tool')),
        );
        expect(
          assistantTexts.where(
            (text) => text == 'Final answer after oversized tool',
          ),
          hasLength(1),
        );
        expect(snapshot.latestTurnGap, isNull);
        expect(
          messages
              .whereType<AssistantServerMessage>()
              .expand((message) => message.historyToolDetailGaps)
              .expand((gap) => gap.toolUseIds),
          contains('provider-oversized-tool'),
        );
        expect(
          snapshot.entries
              .map((entry) => utf8.encode(jsonEncode(entry.rawMessage)).length)
              .every((bytes) => bytes < 64 * 1024),
          isTrue,
        );

        final streaming = StreamingStateCubit(coalesceInterval: Duration.zero);
        final chat = ChatSessionCubit(
          sessionId: threadId,
          provider: Provider.codex,
          bridge: bridge,
          streamingCubit: streaming,
          detachedPreview: true,
          initialHistoryMessages: messages,
        );
        try {
          final layout = buildChatProcessLayout(
            chat.visibleEntries,
            latestTurnIsActive: false,
          );
          final visibleAssistantTexts = chat.visibleEntries
              .whereType<ServerChatEntry>()
              .map((entry) => entry.message)
              .whereType<AssistantServerMessage>()
              .expand(
                (message) => message.message.content.whereType<TextContent>(),
              )
              .map((content) => content.text)
              .toList(growable: false);
          expect(
            visibleAssistantTexts.where(
              (text) => text == 'Commentary before oversized tool',
            ),
            hasLength(1),
          );
          expect(
            visibleAssistantTexts.where(
              (text) => text == 'Commentary after oversized tool',
            ),
            hasLength(1),
          );
          expect(
            visibleAssistantTexts.where(
              (text) => text == 'Final answer after oversized tool',
            ),
            hasLength(1),
          );
          expect(layout.latestTurn, isNotNull);
          expect(layout.latestTurn?.intermediateOutputCount, 2);
          expect(layout.latestTurn?.segments.length, greaterThanOrEqualTo(3));
          expect(
            layout.latestTurn?.segments.fold<int>(
              0,
              (count, segment) => count + segment.thinkingBlocks,
            ),
            1,
          );
          expect(
            layout.latestTurn?.segments.fold<int>(
              0,
              (count, segment) => count + segment.toolCalls,
            ),
            greaterThanOrEqualTo(1),
          );
          expect(layout.latestTurn?.finalAssistantEntryIndex, isNotNull);
        } finally {
          await chat.close();
          await streaming.close();
        }
      } finally {
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
        final clientTrace = await File(
          path.join(traceRoot, 'client-frame.jsonl'),
        ).readAsString();
        expect(clientTrace, contains('conversation_items_page'));
        if (await temporaryDirectory.exists()) {
          await temporaryDirectory.delete(recursive: true);
        }
        expect(exitCode, 0, reason: 'Bridge harness stderr: $stderrBuffer');
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
