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

/// This test is deliberately a transport replay. The loopback peer sends
/// fixed raw JSON frames and never runs Bridge normalization or a provider
/// implementation. All decoding, staging and projection below is the real
/// Mobile path.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  test(
    'transport replay -> real BridgeService -> real sync/SQLite/Cubits/layout',
    () async {
      SharedPreferences.setMockInitialValues(const {});
      final repositoryRoot = path.normalize(
        path.absolute(Directory.current.path, '..', '..'),
      );
      final scenariosFile = File(
        path.join(
          repositoryRoot,
          'test-fixtures',
          'conversation-chain',
          'scenarios.json',
        ),
      );
      expect(scenariosFile.existsSync(), isTrue);
      final scenarios =
          jsonDecode(await scenariosFile.readAsString())
              as Map<String, dynamic>;
      final windowSequence = (scenarios['windowSequence'] as List)
          .map((raw) => Map<String, dynamic>.from(raw as Map))
          .toList(growable: false);
      const expectedCommittedCounts = <int>[
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
      final wireFixture =
          scenarios['protocolWireFixture']! as Map<String, dynamic>;
      expect(windowSequence, hasLength(expectedCommittedCounts.length));

      final steps = _buildReplaySteps(windowSequence, expectedCommittedCounts);
      expect(steps.map((step) => step.complete), <bool>[
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
      ]);
      expect(
        steps.map((step) => step.expectedCommittedCount),
        expectedCommittedCounts,
      );
      final fixture = await _loadReplayFixture(
        File(path.join(repositoryRoot, wireFixture['path']! as String)),
        steps,
        expectedSha256: wireFixture['sha256']! as String,
        expectedFrameCount: wireFixture['frameCount']! as int,
        expectedV2FrameCount: wireFixture['v2FrameCount']! as int,
      );

      final runId =
          '${DateTime.now().toUtc().microsecondsSinceEpoch}-transport-replay';
      final traceRoot = Directory(
        path.join('/private', 'tmp', 'ccpocket-chain', runId),
      );
      await traceRoot.create(recursive: true);
      final bridgeFrameTrace = <Map<String, Object?>>[];
      final ackTrace = <Map<String, Object?>>[];
      final sqliteTrace = <Map<String, Object?>>[];
      final cubitTrace = <Map<String, Object?>>[];
      final layoutTrace = <Map<String, Object?>>[];

      Future<Database> openFfi(
        String databasePath,
        OpenDatabaseOptions options,
      ) => databaseFactoryFfi.openDatabase(databasePath, options: options);
      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'ccpocket_transport_replay_',
      );
      final repository = SessionCatalogCacheRepository(
        SessionCatalogCacheDatabase(
          databasePath: path.join(temporaryDirectory.path, 'cache.db'),
          openDatabase: openFfi,
        ),
      );
      final bridge = BridgeService(clientAppVersion: 'transport-replay-test');
      final sync = ConversationContentSyncService(
        bridge: BridgeServiceConversationContentSyncGateway(bridge),
        cache: repository,
      );
      final sessionList = SessionListCubit(
        bridge: bridge,
        catalogCache: repository,
        conversationSync: sync,
      );
      final streaming = StreamingStateCubit(coalesceInterval: Duration.zero);
      ChatSessionCubit? chat;
      final threadId = fixture.threadId;
      final server = _TransportReplayServer(
        sessionListFrame: fixture.sessionListFrame,
        frames: fixture.frames,
        onAck: (ack) async {
          final target = SessionCatalogCacheTarget.fromBridge(
            bridgeInstanceId: bridge.bridgeInstanceId,
            codexSourceId: bridge.codexSourceId,
            logicalConnectionIdentity: bridge.logicalConnectionIdentity,
            websocketUrl: bridge.lastUrl,
          );
          final snapshot = await repository.loadConversationWindow(
            target: target,
            provider: Provider.codex.value,
            providerSessionId: threadId,
          );
          final syncState = await repository.loadConversationSyncState(target);
          final rawFrame = ack.frame;
          final isTimeline = rawFrame['event'] == 'timeline_page';
          final completesTimeline =
              isTimeline && rawFrame['pageIndex'] == rawFrame['pageCount'] - 1;
          final step = ack.step;
          final committed = snapshot != null || syncState.updatedAt != null;
          ackTrace.add({
            'sequence': ack.sequence,
            'event': rawFrame['event'],
            'sqliteCommitted': committed,
            'syncStateCommitted': syncState.updatedAt != null,
            'entryCount': snapshot?.entries.length,
            'revision': snapshot?.revision,
          });
          if (!completesTimeline || step == null) return;
          expect(snapshot, isNotNull);
          expect(snapshot!.entries.length, step.expectedCommittedCount);
          expect(snapshot.revision, rawFrame['revision']);
          sqliteTrace.add({
            'step': step.index,
            'wireSequence': ack.sequence,
            'completeWindow': step.complete,
            'providerPayloadCount': step.providerPayloadCount,
            'expectedCount': step.expectedCommittedCount,
            'entryCount': snapshot.entries.length,
            'revision': snapshot.revision,
            'windowComplete': snapshot.windowComplete,
            'latestTurnComplete': snapshot.latestTurnComplete,
            'ackAfterSqliteCommit': true,
          });

          final messages = snapshot.entries
              .map((entry) => entry.decodeMessage())
              .toList(growable: false);
          chat ??= ChatSessionCubit(
            sessionId: threadId,
            provider: Provider.codex,
            bridge: bridge,
            streamingCubit: streaming,
            detachedPreview: true,
            // Start empty; the durable projection below is applied through
            // the production detached-preview reconciliation API rather
            // than injecting ChatEntry objects into Cubit state.
            initialHistoryMessages: const [],
            initialHistoryHasEarlier: snapshot.hasEarlier,
          );
          chat!.updateDetachedPreviewHistory(
            messages,
            hasEarlier: snapshot.hasEarlier,
          );
          if (sessionList.state.sessions.isEmpty) {
            await sessionList.stream
                .firstWhere((state) => state.sessions.isNotEmpty)
                .timeout(const Duration(seconds: 5));
          }
          final entries = chat!.visibleEntries;
          final users = entries.whereType<UserChatEntry>().toList();
          expect(users, hasLength(2));
          expect(users.map((entry) => entry.text), everyElement('1'));
          expect(
            users.map((entry) => entry.providerItemId),
            containsAll(<String?>['provider-user-one', 'provider-user-two']),
          );
          expect(
            entries.map(chatEntryHistoryTurnId).whereType<String>().toSet(),
            containsAll(<String>{'provider-turn-one', 'provider-turn-two'}),
          );
          final cubitState = sessionList.state;
          cubitTrace.add({
            'step': step.index,
            'expectedCount': step.expectedCommittedCount,
            'entryCount': entries.length,
            'userCount': users.length,
            'sessionCount': cubitState.sessions.length,
            'sessionIds': cubitState.sessions
                .map((session) => session.sessionId)
                .toList(growable: false),
            'turnIds': entries.map(chatEntryHistoryTurnId).toList(),
          });
          final layout = buildChatProcessLayout(
            entries,
            latestTurnIsActive: step.index == steps.length - 1,
          );
          expect(layout.latestTurnKey, 'turn:provider-turn-two');
          layoutTrace.add({
            'step': step.index,
            'latestTurnKey': layout.latestTurnKey,
            'latestIntermediateCount':
                layout.latestTurn?.intermediateEntryIndices.length ?? 0,
            'latestIsActive': layout.latestTurn?.isActive ?? false,
          });
        },
      );

      sync.start(initialLifecycleState: AppLifecycleState.resumed);
      await server.start();
      bridge.connect(
        server.url,
        logicalConnectionIdentity: 'transport-replay-loopback',
      );

      Object? failure;
      try {
        await bridge.connectionStatus
            .firstWhere((state) => state == BridgeConnectionState.connected)
            .timeout(const Duration(seconds: 10));
        await server.completed.future.timeout(const Duration(seconds: 45));
        expect(server.failure, isNull);
        expect(server.boundSubscriptionId, isNotNull);
        expect(server.windowCoverageAdvertised, isTrue);
        expect(server.receivedSubscribeCount, 1);
        expect(sqliteTrace, hasLength(steps.length));
        expect(cubitTrace, hasLength(steps.length));
        expect(layoutTrace, hasLength(steps.length));
        expect(
          sqliteTrace.map((row) => row['entryCount']),
          expectedCommittedCounts,
        );
        expect(
          sqliteTrace.map((row) => row['ackAfterSqliteCommit']),
          everyElement(true),
        );
        expect(
          ackTrace.map((row) => row['sqliteCommitted']),
          everyElement(true),
        );
        expect(cubitTrace.map((row) => row['sessionCount']), everyElement(1));
        expect(
          cubitTrace.map((row) => row['entryCount']),
          expectedCommittedCounts,
        );
        expect(
          layoutTrace.map((row) => row['latestTurnKey']),
          everyElement('turn:provider-turn-two'),
        );
      } catch (error, stackTrace) {
        failure = error;
        // Preserve the original failure and stack in the test result while
        // still closing the transport and flushing the replay traces below.
        Error.throwWithStackTrace(error, stackTrace);
      } finally {
        bridge.disconnect();
        await chat?.close();
        await streaming.close();
        await sessionList.close();
        await sync.dispose();
        await repository.close();
        await server.close();
        await _writeJsonl(
          path.join(traceRoot.path, 'bridge-frame.jsonl'),
          bridgeFrameTrace..addAll(server.bridgeFrames),
        );
        await _writeJsonl(path.join(traceRoot.path, 'ack.jsonl'), ackTrace);
        await _writeJsonl(
          path.join(traceRoot.path, 'sqlite.jsonl'),
          sqliteTrace,
        );
        await _writeJsonl(path.join(traceRoot.path, 'cubit.jsonl'), cubitTrace);
        await _writeJsonl(
          path.join(traceRoot.path, 'layout.jsonl'),
          layoutTrace,
        );
        await File(path.join(traceRoot.path, 'summary.json')).writeAsString(
          '${jsonEncode(<String, Object?>{'transport': 'replay', 'runId': runId, 'threadId': threadId, 'boundSubscriptionId': server.boundSubscriptionId, 'receivedSubscribeCount': server.receivedSubscribeCount, 'framesSent': server.bridgeFrames.length, 'acksReceived': server.acks.length, 'businessSteps': steps.length, 'committedCounts': sqliteTrace.map((row) => row['entryCount']).toList(growable: false), 'failure': failure?.toString()})}\n',
        );
      }
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}

class _ReplayStep {
  const _ReplayStep({
    required this.index,
    required this.expectedCommittedCount,
    required this.providerPayloadCount,
    required this.complete,
  });

  final int index;
  final int expectedCommittedCount;
  final int providerPayloadCount;
  final bool complete;
}

List<_ReplayStep> _buildReplaySteps(
  List<Map<String, dynamic>> windowSequence,
  List<int> expectedCounts,
) {
  final steps = <_ReplayStep>[];
  for (var index = 0; index < windowSequence.length; index++) {
    final raw = windowSequence[index];
    final complete = raw['complete'] == true;
    steps.add(
      _ReplayStep(
        index: index,
        expectedCommittedCount: expectedCounts[index],
        providerPayloadCount: raw['count']! as int,
        complete: complete,
      ),
    );
  }
  return List.unmodifiable(steps);
}

class _ReplayFixture {
  const _ReplayFixture({
    required this.threadId,
    required this.sessionListFrame,
    required this.frames,
  });

  final String threadId;
  final Map<String, dynamic> sessionListFrame;
  final List<_ReplayWireFrame> frames;
}

Future<_ReplayFixture> _loadReplayFixture(
  File file,
  List<_ReplayStep> steps, {
  required String expectedSha256,
  required int expectedFrameCount,
  required int expectedV2FrameCount,
}) async {
  expect(file.existsSync(), isTrue, reason: 'Frozen wire fixture is missing.');
  final bytes = await file.readAsBytes();
  expect(sha256.convert(bytes).toString(), expectedSha256);
  final rawFrames = (await file.readAsLines())
      .where((line) => line.trim().isNotEmpty)
      .map((line) => Map<String, dynamic>.from(jsonDecode(line) as Map))
      .toList(growable: false);
  expect(rawFrames, hasLength(expectedFrameCount));
  final sessionLists = rawFrames
      .where((frame) => frame['type'] == 'session_list')
      .toList(growable: false);
  expect(sessionLists, hasLength(1));
  final threadFrames = rawFrames
      .where(
        (frame) =>
            frame['type'] == 'conversation_sync_v2' &&
            frame['event'] == 'timeline_page' &&
            frame['providerSessionId'] is String,
      )
      .toList(growable: false);
  expect(threadFrames, isNotEmpty);
  final threadId = threadFrames.first['providerSessionId']! as String;

  var completedStepIndex = 0;
  var timelinePayloadCount = 0;
  var timelineDeleteCount = 0;
  final frames = <_ReplayWireFrame>[];
  final v2Sequences = <int>[];
  for (final raw in rawFrames) {
    if (raw['type'] != 'conversation_sync_v2') continue;
    final sequence = raw['sequence'];
    expect(sequence, isA<int>());
    v2Sequences.add(sequence! as int);
    _ReplayStep? step;
    if (raw['event'] == 'timeline_page') {
      timelinePayloadCount += (raw['entries'] as List?)?.length ?? 0;
      timelineDeleteCount += (raw['deletes'] as List?)?.length ?? 0;
    }
    if (raw['event'] == 'timeline_page' &&
        raw['pageIndex'] == (raw['pageCount'] as int) - 1) {
      if (completedStepIndex >= steps.length) {
        fail('Frozen wire fixture contains extra completed timeline windows.');
      }
      step = steps[completedStepIndex++];
      expect(timelinePayloadCount, step.providerPayloadCount);
      expect(raw['windowComplete'] == true, step.complete);
      if (step.complete) {
        expect(raw['mode'], anyOf('snapshot', 'patch'));
      } else {
        expect(raw['mode'], 'patch');
        expect(raw['baseRevision'], isA<String>());
        expect(raw['revision'], raw['baseRevision']);
        expect(timelineDeleteCount, 0);
      }
      timelinePayloadCount = 0;
      timelineDeleteCount = 0;
    }
    frames.add(_ReplayWireFrame(step: step, raw: raw));
  }
  expect(completedStepIndex, steps.length);
  expect(timelinePayloadCount, 0);
  expect(frames, hasLength(expectedV2FrameCount));
  expect(
    v2Sequences,
    List<int>.generate(v2Sequences.length, (index) => index + 1),
  );
  return _ReplayFixture(
    threadId: threadId,
    sessionListFrame: sessionLists.single,
    frames: List.unmodifiable(frames),
  );
}

class _ReplayWireFrame {
  const _ReplayWireFrame({required this.step, required this.raw});

  final _ReplayStep? step;
  final Map<String, dynamic> raw;
}

class _ReplayAck {
  const _ReplayAck({
    required this.sequence,
    required this.frame,
    required this.step,
  });

  final int sequence;
  final Map<String, dynamic> frame;
  final _ReplayStep? step;
}

class _TransportReplayServer {
  _TransportReplayServer({
    required this.sessionListFrame,
    required this.frames,
    required this.onAck,
  });

  final Map<String, dynamic> sessionListFrame;
  final List<_ReplayWireFrame> frames;
  final Future<void> Function(_ReplayAck ack) onAck;
  final bridgeFrames = <Map<String, Object?>>[];
  final acks = <Map<String, Object?>>[];
  final completed = Completer<void>();
  HttpServer? _server;
  WebSocket? _socket;
  Future<void> _incomingTail = Future<void>.value();
  List<_ReplayWireFrame> _boundFrames = const [];
  int _nextFrameIndex = 0;
  bool _waitingForAck = false;
  bool _sessionListSent = false;
  int receivedSubscribeCount = 0;
  bool windowCoverageAdvertised = false;
  String? boundSubscriptionId;
  Object? failure;

  String get url => 'ws://127.0.0.1:${_server!.port}/transport-replay';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((request) async {
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      _socket = socket;
      socket.listen(
        (data) {
          final raw = data is String ? data : utf8.decode(data as List<int>);
          _incomingTail = _incomingTail.then((_) => _handle(raw));
        },
        onError: (Object error, StackTrace stackTrace) {
          _recordFailure(error, stackTrace);
        },
      );
    });
  }

  Future<void> _handle(String raw) async {
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final type = json['type'];
      if (type == 'client_capabilities') {
        final supported = json['supportedServerMessages'];
        windowCoverageAdvertised =
            supported is List &&
            supported.contains('conversation_sync_window_coverage_v1');
        return;
      }
      if (type == 'list_sessions' && !_sessionListSent) {
        _sessionListSent = true;
        _sendRaw(sessionListFrame);
        return;
      }
      if (type == 'conversation_sync_subscribe') {
        final requestId = json['requestId'];
        if (requestId is! String || requestId.isEmpty) {
          throw StateError('transport replay subscribe requestId missing');
        }
        receivedSubscribeCount += 1;
        boundSubscriptionId = requestId;
        _boundFrames = frames
            .map(
              (frame) => _ReplayWireFrame(
                step: frame.step,
                raw: _bindFrame(frame.raw, requestId),
              ),
            )
            .toList(growable: false);
        _sendNext();
        return;
      }
      if (type == 'conversation_sync_ack') {
        final sequence = json['sequence'];
        if (sequence is! int || boundSubscriptionId == null) {
          throw StateError('transport replay ACK is malformed');
        }
        final frame = _boundFrames.firstWhere(
          (candidate) => candidate.raw['sequence'] == sequence,
          orElse: () => throw StateError('unexpected ACK sequence $sequence'),
        );
        if (!_waitingForAck) {
          throw StateError('transport replay received ACK without a frame');
        }
        _waitingForAck = false;
        final ack = _ReplayAck(
          sequence: sequence,
          frame: frame.raw,
          step: frame.step,
        );
        await onAck(ack);
        acks.add({
          'sequence': sequence,
          'event': frame.raw['event'],
          'step': frame.step?.index,
          'afterCommit': true,
        });
        _sendNext();
        return;
      }
      // The real BridgeService also sends client capabilities and may ask for
      // a legacy catalog. Transport replay deliberately ignores those frames.
    } catch (error, stackTrace) {
      _recordFailure(error, stackTrace);
      try {
        await _socket?.close(WebSocketStatus.protocolError, '$error');
      } catch (_) {
        // The test reports the original replay failure.
      }
    }
  }

  Map<String, dynamic> _bindFrame(
    Map<String, dynamic> raw,
    String subscriptionId,
  ) {
    final encoded = jsonEncode(raw)
        .replaceAll('__SUBSCRIPTION_ID__', subscriptionId)
        .replaceAll('__REQUEST_ID__', subscriptionId);
    return Map<String, dynamic>.from(jsonDecode(encoded) as Map);
  }

  void _sendNext() {
    if (_waitingForAck || _nextFrameIndex >= _boundFrames.length) {
      if (_nextFrameIndex >= _boundFrames.length && !completed.isCompleted) {
        completed.complete();
      }
      return;
    }
    final frame = _boundFrames[_nextFrameIndex++];
    _waitingForAck = true;
    _sendRaw(frame.raw);
  }

  void _sendRaw(Map<String, dynamic> raw) {
    bridgeFrames.add({
      'index': bridgeFrames.length,
      'transport': 'replay',
      'type': raw['type'],
      'event': raw['event'],
      'sequence': raw['sequence'],
      'subscriptionId': raw['subscriptionId'],
      'requestId': raw['requestId'],
      'raw': raw,
    });
    _socket?.add(jsonEncode(raw));
  }

  void _recordFailure(Object error, StackTrace stackTrace) {
    failure ??= error;
    if (!completed.isCompleted) completed.completeError(error, stackTrace);
  }

  Future<void> close() async {
    await _incomingTail;
    try {
      await _socket?.close(WebSocketStatus.normalClosure);
    } catch (_) {}
    await _server?.close(force: true);
  }
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
