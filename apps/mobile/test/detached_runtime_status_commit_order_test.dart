import 'dart:async';

import 'package:ccpocket/features/chat_session/state/chat_session_cubit.dart';
import 'package:ccpocket/features/chat_session/state/streaming_state_cubit.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chat_session_cubit_test.dart' show MockBridgeService;

const _time = '2026-10-03T00:00:01.000Z';
const _source = 'bridge-a/source-a';
const _subscription = 'commit-order-subscription';

ConversationSyncV2Status _status(
  String authority, {
  int? sequence,
  String source = _source,
  String subscription = _subscription,
}) {
  final status = ConversationSyncV2Status(
    provider: 'codex',
    providerSessionId: 'commit-order-thread',
    activity: 'working',
    attention: 'none',
    result: 'none',
    runtimeAttachment: 'loaded',
    source: 'bridgeRuntime',
    confidence: 'authoritative',
    observedAt: _time,
    executionHost: 'bridge',
    activeTurnId: 'commit-order-turn',
    controlState: 'steerable',
    authorityGeneration: authority,
    runtimeSessionId: 'commit-order-runtime',
  );
  return sequence == null
      ? status
      : status.withCommitReceipt(
          ConversationSyncV2CommitReceipt(
            sourceFingerprint: source,
            subscriptionId: subscription,
            sequence: sequence,
          ),
        );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MockBridgeService bridge;
  late StreamingStateCubit streaming;
  late StreamController<ConversationSyncV2EventMessage> overlays;
  late ChatSessionCubit chat;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    bridge = MockBridgeService()
      ..advertisedBridgeCapabilities = const {
        conversationSyncV2Capability,
        conversationRuntimeOverlayCapability,
      };
    streaming = StreamingStateCubit(coalesceInterval: Duration.zero);
    overlays = StreamController<ConversationSyncV2EventMessage>.broadcast();
    chat = ChatSessionCubit(
      sessionId: 'commit-order-thread',
      provider: Provider.codex,
      bridge: bridge,
      streamingCubit: streaming,
      detachedPreview: true,
      initialLiveRuntimeSessionId: 'commit-order-runtime',
      initialHistoryMessages: const [
        UserInputMessage(
          text: 'Canonical user',
          providerItemId: 'commit-order-user',
        ),
      ],
      detachedRuntimeOverlayStream: overlays.stream,
    );
  });
  tearDown(() async {
    await chat.close();
    await overlays.close();
    await streaming.close();
    bridge.dispose();
  });
  void event(String authority, int sequence) => overlays.add(
    ConversationSyncV2EventMessage(
      event: ConversationSyncV2EventKind.runtimeOverlay,
      subscriptionId: _subscription,
      bridgeInstanceId: 'bridge-a',
      codexSourceId: 'source-a',
      batchId: 'commit-order-batch',
      sequence: sequence,
      provider: 'codex',
      providerSessionId: 'commit-order-thread',
      overlayId: '$authority-$sequence',
      observedAt: _time,
      originGeneration: 'runtime:commit-order-runtime:$authority',
      runtimeSessionId: 'commit-order-runtime',
      authorityGeneration: authority,
      turnId: 'commit-order-turn',
      overlayMessage: ErrorMessage(message: authority),
    ),
  );
  void status(ConversationSyncV2Status value) =>
      chat.updateDetachedProviderStatus(value, sourceFingerprint: _source);
  int pending() =>
      (chat.diagnosticRuntimeProjection['timelineProjection']!
              as Map<String, Object?>)['pendingRuntimeOverlayCount']!
          as int;
  List<String> visible() => chat.visibleEntries
      .whereType<ServerChatEntry>()
      .map((entry) => entry.message)
      .whereType<ErrorMessage>()
      .map((message) => message.message)
      .toList();

  test(
    'equal clock old event retires only after later committed status',
    () async {
      event('A', 20);
      await pumpEventQueue();
      expect(pending(), 1);
      status(_status('B', sequence: 21));
      expect(pending(), 0);
      expect(visible(), isEmpty);
    },
  );
  test(
    'equal clock future authority stays pending and later applies once',
    () async {
      status(_status('B', sequence: 20));
      event('C', 21);
      await pumpEventQueue();
      expect(pending(), 1);
      status(_status('C', sequence: 22));
      expect(pending(), 0);
      expect(visible(), ['C']);
      event('C', 21);
      await pumpEventQueue();
      expect(visible(), ['C']);
    },
  );
  for (final lane in [
    'missing',
    'other-source',
    'other-subscription',
    'same-sequence',
  ]) {
    test('equal clock $lane provides no stale proof', () async {
      event('A', 20);
      await pumpEventQueue();
      status(
        _status(
          'B',
          sequence: lane == 'missing'
              ? null
              : lane == 'same-sequence'
              ? 20
              : 99,
          source: lane == 'other-source'
              ? 'bridge-other/source-other'
              : _source,
          subscription: lane == 'other-subscription'
              ? 'old-subscription'
              : _subscription,
        ),
      );
      expect(pending(), 1);
      expect(visible(), isEmpty);
    });
  }
  test(
    'identical status with later receipt rechecks its pending queue',
    () async {
      status(_status('B', sequence: 20));
      event('A', 21);
      await pumpEventQueue();
      expect(pending(), 1);
      status(_status('B', sequence: 22));
      expect(pending(), 0);
      expect(visible(), isEmpty);
    },
  );
  test(
    'an older same subscription receipt cannot replace current authority',
    () async {
      status(_status('B', sequence: 22));
      status(_status('A', sequence: 20));
      expect(chat.diagnosticRuntimeProjection['authorityGeneration'], 'B');
    },
  );
  test('null status retires its local commit proof', () async {
    status(_status('B', sequence: 30));
    chat.updateDetachedProviderStatus(null, sourceFingerprint: _source);
    event('A', 20);
    await pumpEventQueue();
    expect(pending(), 1);
  });
  test(
    'wire and cached JSON never create or retain a local commit receipt',
    () {
      final value = _status('B', sequence: 21);
      final plain = _status('B');
      expect(value.toJson(), plain.toJson());
      expect(
        ConversationSyncV2Status.fromJson({
          ...plain.toJson(),
          'commitReceipt': {
            'sourceFingerprint': _source,
            'subscriptionId': _subscription,
            'sequence': 100,
          },
        }).commitReceipt,
        isNull,
      );
    },
  );
}
