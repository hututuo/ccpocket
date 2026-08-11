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
import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  test(
    'fake app-server -> real Bridge -> real BridgeService/SQLite/Cubit/layout',
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
        'conversation-chain-bridge-harness.mjs',
      );
      final scenarios =
          jsonDecode(
                await File(
                  path.join(
                    repositoryRoot,
                    'test-fixtures',
                    'conversation-chain',
                    'scenarios.json',
                  ),
                ).readAsString(),
              )
              as Map<String, dynamic>;
      final providerScenario =
          scenarios['headlessProvider']! as Map<String, dynamic>;
      final expected = providerScenario['expected']! as Map<String, dynamic>;
      final providerWindows = (scenarios['windowSequence']! as List)
          .map((value) => Map<String, dynamic>.from(value as Map))
          .toList(growable: false);
      const expectedProviderCounts = <int>[
        71,
        1,
        72,
        1,
        72,
        2,
        73,
        3,
        91,
        47,
        126,
        47,
        126,
        9,
        120,
        9,
      ];
      const expectedComplete = <bool>[
        true,
        false,
        true,
        false,
        true,
        false,
        true,
        false,
        true,
        false,
        true,
        false,
        true,
        false,
        true,
        false,
      ];
      const expectedCounts = <int>[
        71,
        71,
        72,
        72,
        72,
        72,
        73,
        73,
        91,
        91,
        126,
        126,
        126,
        126,
        120,
        120,
      ];
      expect(
        providerWindows.map((window) => window['count']! as int),
        expectedProviderCounts,
      );
      expect(
        providerWindows.map((window) => window['complete'] == true),
        expectedComplete,
      );
      final expectedUserCounts = List<int>.filled(expectedCounts.length, 2);
      final expectedLatestActive = List<bool>.generate(
        expectedCounts.length,
        (index) => index == expectedCounts.length - 1,
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
      final traceRoot = ready['traceRoot']! as String;

      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'ccpocket_real_bridge_chain_mobile_',
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
        clientAppVersion: 'headless-real-bridge-chain',
      );
      final outgoing = <ClientMessage>[];
      bridge.onOutgoingMessage = outgoing.add;
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
      final sqliteTrace = <Map<String, Object?>>[];
      final cubitTrace = <Map<String, Object?>>[];
      final layoutTrace = <Map<String, Object?>>[];

      Future<ConversationHotWindowSnapshot> waitForTimelineCommit(
        int count, {
        bool inspectImmediately = false,
      }) async {
        final completer = Completer<ConversationHotWindowSnapshot>();
        late final StreamSubscription<ConversationSyncCacheUpdate> sub;
        Future<void> inspect() async {
          if (completer.isCompleted ||
              bridge.bridgeInstanceId?.isNotEmpty != true ||
              bridge.codexSourceId?.isNotEmpty != true) {
            return;
          }
          final target = SessionCatalogCacheTarget.fromBridge(
            bridgeInstanceId: bridge.bridgeInstanceId,
            codexSourceId: bridge.codexSourceId,
            logicalConnectionIdentity: bridge.logicalConnectionIdentity,
            websocketUrl: bridge.lastUrl,
          );
          final window = await repository.loadConversationWindow(
            target: target,
            provider: Provider.codex.value,
            providerSessionId: threadId,
          );
          if (window == null || window.entries.length != count) return;
          completer.complete(window);
        }

        sub = sync.syncUpdates.listen((update) {
          if (update.kind == ConversationSyncCacheUpdateKind.timeline &&
              update.provider == Provider.codex.value &&
              update.providerSessionId == threadId &&
              update.pageIndex == (update.pageCount ?? 1) - 1) {
            unawaited(inspect());
          }
        });
        if (inspectImmediately) unawaited(inspect());
        try {
          return await completer.future.timeout(const Duration(seconds: 15));
        } finally {
          await sub.cancel();
        }
      }

      void recordProjection(
        ConversationHotWindowSnapshot window,
        int step,
        int expectedUserCount,
        bool latestTurnIsActive,
      ) {
        final messages = window.entries
            .map((entry) => entry.decodeMessage())
            .toList(growable: false);
        if (chat == null) {
          streaming = StreamingStateCubit(coalesceInterval: Duration.zero);
          chat = ChatSessionCubit(
            sessionId: threadId,
            provider: Provider.codex,
            bridge: bridge,
            streamingCubit: streaming!,
            detachedPreview: true,
            initialHistoryMessages: messages,
            initialHistoryHasEarlier: window.hasEarlier,
          );
        } else {
          chat!.updateDetachedPreviewHistory(
            messages,
            hasEarlier: window.hasEarlier,
          );
        }
        final entries = chat!.visibleEntries;
        final layout = buildChatProcessLayout(
          entries,
          latestTurnIsActive: latestTurnIsActive,
        );
        final users = entries.whereType<UserChatEntry>().toList();
        expect(users, hasLength(expectedUserCount));
        expect(users.every((entry) => entry.text == '1'), isTrue);
        sqliteTrace.add({
          'step': step,
          'revision': window.revision,
          'windowComplete': window.windowComplete,
          'entryCount': window.entries.length,
          'entryIds': window.entries.map((entry) => entry.entryId).toList(),
          'entryIdsSha256': sha256
              .convert(
                utf8.encode(
                  window.entries.map((entry) => entry.entryId).join('\n'),
                ),
              )
              .toString(),
        });
        cubitTrace.add({
          'step': step,
          'entryCount': entries.length,
          'entryTypes': entries
              .map((entry) => entry.runtimeType.toString())
              .toList(),
          'turnIds': entries.map(chatEntryHistoryTurnId).toList(),
        });
        layoutTrace.add({
          'step': step,
          'latestTurnKey': layout.latestTurnKey,
          'latestIntermediateCount':
              layout.latestTurn?.intermediateEntryIndices.length ?? 0,
          'latestIsActive': layout.latestTurn?.isActive ?? false,
        });
      }

      try {
        final initialFuture = waitForTimelineCommit(
          expectedCounts[0],
          inspectImmediately: true,
        );
        bridge.connect(url, logicalConnectionIdentity: 'chain-harness');
        await bridge.connectionStatus
            .firstWhere((state) => state == BridgeConnectionState.connected)
            .timeout(const Duration(seconds: 10));
        final initial = await initialFuture;
        recordProjection(
          initial,
          0,
          expectedUserCounts[0],
          expectedLatestActive[0],
        );

        late ConversationHotWindowSnapshot finalWindow;
        for (var step = 1; step < expectedCounts.length; step += 1) {
          final committed = waitForTimelineCommit(expectedCounts[step]);
          harness.stdin.writeln(
            jsonEncode({'command': 'advance', 'step': step}),
          );
          await harness.stdin.flush();
          final window = await committed;
          recordProjection(
            window,
            step,
            expectedUserCounts[step],
            expectedLatestActive[step],
          );
          finalWindow = window;
        }

        final finalMessages = finalWindow.entries
            .map((entry) => entry.decodeMessage())
            .toList(growable: false);
        expect(
          finalMessages.whereType<UserInputMessage>().map(
            (message) => message.text,
          ),
          List<String>.from(expected['userTexts']! as List),
        );
        expect(
          finalMessages.whereType<AssistantServerMessage>().where(
            (message) => message.message.content.whereType<TextContent>().any(
              (content) => content.text == expected['assistantText'],
            ),
          ),
          hasLength(expected['assistantTextCount']! as int),
        );
        expect(
          finalMessages.whereType<ToolResultMessage>(),
          hasLength(expected['toolResultCount']! as int),
        );
        expect(
          chat!.visibleEntries
              .map(chatEntryHistoryTurnId)
              .where((turnId) => turnId != null)
              .toSet(),
          Set<String>.from(expected['turnIds']! as List),
        );
        expect(
          buildChatProcessLayout(
            chat!.visibleEntries,
            latestTurnIsActive: true,
          ).latestTurnKey,
          expected['latestTurnKey'],
        );
        expect(
          outgoing.where((message) => message.type == 'conversation_sync_ack'),
          isNotEmpty,
        );

        await Directory(traceRoot).create(recursive: true);
        await _writeJsonl(path.join(traceRoot, 'sqlite.jsonl'), sqliteTrace);
        await _writeJsonl(path.join(traceRoot, 'cubit.jsonl'), cubitTrace);
        await _writeJsonl(path.join(traceRoot, 'layout.jsonl'), layoutTrace);
      } finally {
        bridge.disconnect();
        await chat?.close();
        await streaming?.close();
        await sessionList.close();
        await sync.dispose();
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
        if (await temporaryDirectory.exists()) {
          await temporaryDirectory.delete(recursive: true);
        }
        expect(exitCode, 0, reason: 'Bridge harness stderr: $stderrBuffer');

        final providerReads = await _readJsonl(
          path.join(traceRoot, 'provider-read.jsonl'),
        );
        for (var step = 0; step < expectedProviderCounts.length; step += 1) {
          expect(
            providerReads.where(
              (entry) =>
                  entry['step'] == step &&
                  entry['rawMessageCount'] == expectedProviderCounts[step] &&
                  entry['windowComplete'] == expectedComplete[step],
            ),
            isNotEmpty,
            reason: 'Provider step $step was not actually read.',
          );
        }

        final bridgeFrames = await _readJsonl(
          path.join(traceRoot, 'bridge-frame.jsonl'),
        );
        final batches = _timelineBatches(bridgeFrames, threadId);
        expect(batches, hasLength(expectedProviderCounts.length));
        expect(
          batches.map((batch) => batch.payloadEntryCount),
          expectedProviderCounts,
        );
        expect(batches.map((batch) => batch.windowComplete), expectedComplete);
        for (var step = 0; step < batches.length; step += 1) {
          final batch = batches[step];
          if (expectedComplete[step]) {
            expect(batch.mode, anyOf('snapshot', 'patch'));
          } else {
            expect(batch.mode, 'patch');
            expect(batch.baseRevision, isNotEmpty);
            expect(batch.deleteCount, 0);
          }
          expect(batch.sourceEntryCount, expectedProviderCounts[step]);
        }
        final ackFrames = await _readJsonl(path.join(traceRoot, 'ack.jsonl'));
        final ackedSequences = ackFrames
            .where((entry) => entry['type'] == 'conversation_sync_ack')
            .map((entry) => entry['sequence'])
            .toSet();
        for (final batch in batches) {
          expect(
            ackedSequences,
            contains(batch.finalSequence),
            reason: 'Timeline batch was not ACKed after Mobile commit.',
          );
        }
      }
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}

Future<List<Map<String, dynamic>>> _readJsonl(String filePath) async {
  return (await File(filePath).readAsLines())
      .where((line) => line.trim().isNotEmpty)
      .map((line) => Map<String, dynamic>.from(jsonDecode(line) as Map))
      .toList(growable: false);
}

List<_TimelineBatch> _timelineBatches(
  List<Map<String, dynamic>> frames,
  String threadId,
) {
  final batches = <_TimelineBatch>[];
  var payloadEntryCount = 0;
  var deleteCount = 0;
  Map<String, dynamic>? first;
  for (final frame in frames) {
    if (frame['type'] != 'conversation_sync_v2' ||
        frame['event'] != 'timeline_page' ||
        frame['providerSessionId'] != threadId) {
      continue;
    }
    first ??= frame;
    payloadEntryCount += (frame['entries'] as List?)?.length ?? 0;
    deleteCount += (frame['deletes'] as List?)?.length ?? 0;
    final pageIndex = frame['pageIndex'] as int;
    final pageCount = frame['pageCount'] as int;
    if (pageIndex != pageCount - 1) continue;
    batches.add(
      _TimelineBatch(
        mode: first['mode']! as String,
        baseRevision: first['baseRevision'] as String?,
        windowComplete: first['windowComplete'] == true,
        sourceEntryCount: first['sourceEntryCount']! as int,
        payloadEntryCount: payloadEntryCount,
        deleteCount: deleteCount,
        finalSequence: frame['sequence']! as int,
      ),
    );
    first = null;
    payloadEntryCount = 0;
    deleteCount = 0;
  }
  expect(first, isNull, reason: 'Bridge trace ended inside a timeline batch.');
  return batches;
}

class _TimelineBatch {
  const _TimelineBatch({
    required this.mode,
    required this.baseRevision,
    required this.windowComplete,
    required this.sourceEntryCount,
    required this.payloadEntryCount,
    required this.deleteCount,
    required this.finalSequence,
  });

  final String mode;
  final String? baseRevision;
  final bool windowComplete;
  final int sourceEntryCount;
  final int payloadEntryCount;
  final int deleteCount;
  final int finalSequence;
}

Future<void> _writeJsonl(
  String filePath,
  List<Map<String, Object?>> values,
) async {
  await File(filePath).writeAsString(
    values.isEmpty
        ? ''
        : '${values.map(jsonEncode).join(Platform.lineTerminator)}${Platform.lineTerminator}',
  );
}
