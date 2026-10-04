import 'dart:async';

import 'package:ccpocket/features/chat_session/state/chat_session_cubit.dart';
import 'package:ccpocket/features/chat_session/state/streaming_state_cubit.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chat_session_cubit_test.dart' show MockBridgeService;

const _source = 'bridge-a/source-a';
const _time = '2026-10-04T00:00:01.000Z';
const _subscription = 'lifecycle-subscription';

ConversationSyncV2Status _status(
  String authority, {
  int? sequence,
  String subscription = _subscription,
}) {
  final value = ConversationSyncV2Status(
    provider: 'codex',
    providerSessionId: 'lifecycle-thread',
    activity: 'working',
    attention: 'none',
    result: 'none',
    runtimeAttachment: 'loaded',
    source: 'bridgeRuntime',
    confidence: 'authoritative',
    observedAt: _time,
    executionHost: 'bridge',
    activeTurnId: 'lifecycle-turn',
    controlState: 'steerable',
    authorityGeneration: authority,
    runtimeSessionId: 'lifecycle-runtime',
  );
  return sequence == null
      ? value
      : value.withCommitReceipt(
          ConversationSyncV2CommitReceipt(
            sourceFingerprint: _source,
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
      sessionId: 'lifecycle-thread',
      provider: Provider.codex,
      bridge: bridge,
      streamingCubit: streaming,
      detachedPreview: true,
      initialLiveRuntimeSessionId: 'lifecycle-runtime',
      initialHistoryMessages: const [
        UserInputMessage(
          text: 'Canonical user',
          providerItemId: 'lifecycle-user',
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

  void status(ConversationSyncV2Status value) =>
      chat.updateDetachedProviderStatus(value, sourceFingerprint: _source);
  void event(String authority, int sequence, {String sub = _subscription}) =>
      overlays.add(
        ConversationSyncV2EventMessage(
          event: ConversationSyncV2EventKind.runtimeOverlay,
          subscriptionId: sub,
          bridgeInstanceId: 'bridge-a',
          codexSourceId: 'source-a',
          batchId: 'lifecycle-batch',
          sequence: sequence,
          provider: 'codex',
          providerSessionId: 'lifecycle-thread',
          overlayId: '$sub-$authority-$sequence',
          observedAt: _time,
          originGeneration: 'runtime:lifecycle-runtime:$authority',
          runtimeSessionId: 'lifecycle-runtime',
          authorityGeneration: authority,
          turnId: 'lifecycle-turn',
          overlayMessage: ErrorMessage(message: authority),
        ),
      );
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

  for (final lane in ['cached', 'same-receipt', 'older-receipt']) {
    test('suspended $lane cannot restore its authority lease', () {
      status(_status('B', sequence: 30));
      expect(chat.canMutateAttachedRuntime, isTrue);
      chat.suspendDetachedProviderProjection();
      status(
        _status(
          'B',
          sequence: lane == 'cached'
              ? null
              : lane == 'same-receipt'
              ? 30
              : 29,
        ),
      );
      expect(chat.state.status, ProcessStatus.running);
      expect(chat.canMutateAttachedRuntime, isFalse);
      expect(chat.diagnosticRuntimeProjection['authorityObserved'], isFalse);
    });
  }
  test('a later identical commit restores a suspended authority lease', () {
    status(_status('B', sequence: 30));
    chat.suspendDetachedProviderProjection();
    expect(chat.canMutateAttachedRuntime, isFalse);
    status(_status('B', sequence: 31));
    expect(chat.canMutateAttachedRuntime, isTrue);
    expect(chat.diagnosticRuntimeProjection['authorityGeneration'], 'B');
    expect(chat.diagnosticRuntimeProjection['statusCommitSequence'], 31);
  });
  test('a current new subscription may start below the old sequence', () {
    status(_status('B', sequence: 300));
    chat.suspendDetachedProviderProjection();
    status(_status('B', sequence: 3, subscription: 'new-subscription'));
    expect(chat.canMutateAttachedRuntime, isTrue);
    expect(
      chat.diagnosticRuntimeProjection['statusCommitSubscriptionId'],
      'new-subscription',
    );
    expect(chat.diagnosticRuntimeProjection['statusCommitSequence'], 3);
  });
  test('cached equal-clock status cannot retire a quarantined event', () async {
    event('A', 20);
    await pumpEventQueue();
    status(_status('B'));
    expect(pending(), 1);
    expect(visible(), isEmpty);
  });
  test(
    'cache reread clears local order but a fresh commit can recheck',
    () async {
      status(_status('B', sequence: 30));
      status(ConversationSyncV2Status.fromJson(_status('B').toJson()));
      expect(chat.diagnosticRuntimeProjection['statusCommitSequence'], isNull);
      expect(chat.diagnosticRuntimeProjection['authorityGeneration'], 'B');
      event('A', 20);
      await pumpEventQueue();
      expect(pending(), 1);
      status(_status('B', sequence: 31));
      expect(pending(), 0);
      expect(visible(), isEmpty);
    },
  );
  test(
    'cross-subscription order stays unknown and future owner applies once',
    () async {
      event('A', 300, sub: 'old-subscription');
      await pumpEventQueue();
      status(_status('B', sequence: 3));
      expect(pending(), 1);
      event('C', 4);
      await pumpEventQueue();
      expect(pending(), 2);
      status(_status('C', sequence: 5));
      expect(pending(), 1);
      expect(visible(), ['C']);
      event('C', 4);
      await pumpEventQueue();
      expect(pending(), 1);
      expect(visible(), ['C']);
    },
  );
}
